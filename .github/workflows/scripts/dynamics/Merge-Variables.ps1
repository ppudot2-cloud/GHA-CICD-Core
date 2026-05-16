<#
.SYNOPSIS
    Merges global (GHA-Core) and project (GHA-Dynamics) pipeline variables with
    governance enforcement: project variables cannot override protected global keys.

.DESCRIPTION
    Called at the start of every reusable workflow (build, deploy, rollback).
    Reads two YAML config files:
      1. GHA-Core/.github/config/global-vars.yml  — global defaults + protected_keys
      2. <caller>/.github/config/project-vars.yml — project-specific values

    Merge rules:
      • Global variables are loaded first.
      • Project variables are layered on top (they can override non-protected keys).
      • If a project variable key appears in global protected_keys → exit 1 with
        a clear violation report (the pipeline stops before any work is done).
      • All merged variables are written to $GITHUB_ENV for use by subsequent steps.

    Azure identity variables (AZURE_*) are intentionally EXCLUDED from GITHUB_ENV
    output — they are sourced from GitHub repository variables (vars.*) and the
    azure/login OIDC step, not from this YAML merge. This prevents accidental
    shadowing of the OIDC-provided identity.

.PARAMETER GlobalVarsPath
    Absolute or relative path to global-vars.yml (GHA-Core checkout).

.PARAMETER ProjectVarsPath
    Absolute or relative path to project-vars.yml (caller repo checkout).

.PARAMETER DryRun
    If set, prints what would be written to GITHUB_ENV without actually writing.

.EXAMPLE
    pwsh .ci/.github/scripts/Merge-Variables.ps1 `
        -GlobalVarsPath ".ci/.github/config/global-vars.yml" `
        -ProjectVarsPath ".github/config/project-vars.yml"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$GlobalVarsPath,

    [Parameter(Mandatory)]
    [string]$ProjectVarsPath,

    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Helpers ───────────────────────────────────────────────────────────────────
function Write-Header([string]$msg) {
    Write-Host "`n$('─' * 70)"
    Write-Host "  $msg"
    Write-Host "$('─' * 70)"
}

function Parse-SimpleYaml([string]$path, [string]$section) {
    <#
    Minimal YAML parser for the specific structure used in global-vars.yml and
    project-vars.yml. Handles:
      - Top-level sections (protected_keys:, variables:)
      - Quoted and unquoted scalar values
      - List items under protected_keys (- item)
    Does NOT require external modules (powershell-yaml is optional but preferred).
    #>
    if (-not (Test-Path $path)) {
        Write-Error "YAML file not found: $path"
        exit 1
    }

    # ── Prefer powershell-yaml if available ──────────────────────────────────
    if (Get-Module -ListAvailable -Name powershell-yaml -ErrorAction SilentlyContinue) {
        Import-Module powershell-yaml -ErrorAction SilentlyContinue
        $doc = Get-Content -Raw $path | ConvertFrom-Yaml
        if ($section -eq 'protected_keys') {
            return [System.Collections.Generic.List[string]]($doc.protected_keys ?? @())
        }
        $ht = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($kv in ($doc.variables ?? @{}).GetEnumerator()) {
            $ht[$kv.Key] = $kv.Value
        }
        return $ht
    }

    # ── Fallback: line-by-line parser ────────────────────────────────────────
    $lines         = Get-Content $path
    $inSection     = $false
    $result        = $null

    if ($section -eq 'protected_keys') {
        $result = [System.Collections.Generic.List[string]]::new()
    } else {
        $result = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
    }

    foreach ($line in $lines) {
        # Skip comments and blank lines
        if ($line -match '^\s*#' -or $line -match '^\s*$') { continue }

        # Detect section header
        if ($line -match '^(\w[\w_-]*):\s*$') {
            $inSection = ($Matches[1] -eq $section)
            continue
        }

        if (-not $inSection) { continue }

        if ($section -eq 'protected_keys') {
            # List item:  - SomeKey
            if ($line -match '^\s+-\s+(\S+)') {
                $result.Add($Matches[1].Trim()) | Out-Null
            }
        } else {
            # Key: "value"  or  Key: value
            if ($line -match '^\s+([\w_-]+)\s*:\s*"?([^"]*)"?\s*$') {
                $result[$Matches[1].Trim()] = $Matches[2].Trim()
            }
        }
    }

    return $result
}

# Keys whose values come from OIDC / GitHub vars — never write to GITHUB_ENV
$AZURE_IDENTITY_KEYS = @(
    'AZURE_TENANT_ID', 'AZURE_CLIENT_ID', 'AZURE_SUBSCRIPTION_ID', 'AZURE_KEY_VAULT_NAME'
)

# ── Load global vars ──────────────────────────────────────────────────────────
Write-Header "Loading global variables from GHA-Core"
Write-Host "  Path: $GlobalVarsPath"

$protectedKeys = Parse-SimpleYaml -path $GlobalVarsPath -section 'protected_keys'
$globalVars    = Parse-SimpleYaml -path $GlobalVarsPath -section 'variables'

Write-Host "  Protected keys  : $($protectedKeys.Count)"
Write-Host "  Global variables: $($globalVars.Count)"

# ── Load project vars ─────────────────────────────────────────────────────────
Write-Header "Loading project variables"

$projectVars = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)

if (Test-Path $ProjectVarsPath) {
    Write-Host "  Path: $ProjectVarsPath"
    $projectVars = Parse-SimpleYaml -path $ProjectVarsPath -section 'variables'
    Write-Host "  Project variables: $($projectVars.Count)"
} else {
    Write-Host "  ⚠️  project-vars.yml not found — using global defaults only."
    Write-Host "     Expected: $ProjectVarsPath"
}

# ── Governance check: no project key may override a protected global key ──────
Write-Header "Enforcing variable governance"

$violations = [System.Collections.Generic.List[string]]::new()
foreach ($key in $projectVars.Keys) {
    if ($protectedKeys -contains $key) {
        $globalValue  = $globalVars[$key]
        $projectValue = $projectVars[$key]
        $violations.Add(
            "  ❌  '$key' is protected (global='$globalValue', project attempted='$projectValue')"
        )
    }
}

if ($violations.Count -gt 0) {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════════════╗"
    Write-Host "║  VARIABLE GOVERNANCE VIOLATION                                       ║"
    Write-Host "╠══════════════════════════════════════════════════════════════════════╣"
    Write-Host "║  The following keys in project-vars.yml conflict with protected       ║"
    Write-Host "║  global variables defined in GHA-Core/global-vars.yml.               ║"
    Write-Host "║  Remove these keys from project-vars.yml to proceed.                 ║"
    Write-Host "╚══════════════════════════════════════════════════════════════════════╝"
    foreach ($v in $violations) { Write-Host $v }
    Write-Host ""
    Write-Host "Protected keys: $($protectedKeys -join ', ')"
    exit 1
}

Write-Host "  ✅ No governance violations — all project keys are permitted."

# ── Merge: global first, then project (project wins for non-protected keys) ───
Write-Header "Merging variables"

$merged = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($kv in $globalVars.GetEnumerator())  { $merged[$kv.Key] = $kv.Value }
foreach ($kv in $projectVars.GetEnumerator()) { $merged[$kv.Key] = $kv.Value }

# ── Write to GITHUB_ENV (skip Azure identity keys — they come from OIDC) ──────
Write-Header "Writing variables to GITHUB_ENV"

$written  = 0
$skipped  = 0
$envFile  = $env:GITHUB_ENV

foreach ($kv in ($merged.GetEnumerator() | Sort-Object Key)) {
    if ($AZURE_IDENTITY_KEYS -contains $kv.Key) {
        Write-Host "  ⏭  $($kv.Key)  [skipped — sourced from OIDC/GitHub vars]"
        $skipped++
        continue
    }
    $displayValue = if ($kv.Value -match '<set in') { '<placeholder>' } else { $kv.Value }
    Write-Host "  ✔  $($kv.Key) = $displayValue"

    if (-not $DryRun -and $envFile) {
        "$($kv.Key)=$($kv.Value)" | Out-File -FilePath $envFile -Append -Encoding utf8
    }
    $written++
}

Write-Header "Summary"
Write-Host "  Global variables : $($globalVars.Count)"
Write-Host "  Project variables: $($projectVars.Count)"
Write-Host "  Merged total     : $($merged.Count)"
Write-Host "  Written to env   : $written"
Write-Host "  Skipped (OIDC)   : $skipped"
Write-Host "  Protected keys   : $($protectedKeys -join ', ')"
if ($DryRun) {
    Write-Host ""
    Write-Host "  ⚠️  DRY RUN — nothing written to GITHUB_ENV"
}
Write-Host ""
