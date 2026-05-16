<#
.SYNOPSIS
    Compares solution versions across environments to prevent downgrades.

.DESCRIPTION
    Performs two categories of version checks:

    1. CURRENT SOLUTION  — Reads the version from the unmanaged artifact ZIP and
       compares it against the version already deployed in the previous environment.
       Fails if the artifact is older than what is already in the previous env.

    2. BASE SOLUTIONS    — For each solution listed in -BaseSolutions, queries the
       version deployed in the previous environment and the version deployed in the
       target environment. Fails if the previous-env version is older than what is
       already in the target env (i.e. the pipeline would take the target env
       backwards).

    A unified comparison table is written to the GitHub step summary.
    The script exits 1 if any check fails.

.PARAMETER ArtifactFolder
    Folder that contains the solution ZIPs for the current solution
    (e.g. out/MySolution). Must contain an *_unmanaged.zip file.

.PARAMETER SolutionName
    Unique name of the solution being deployed (e.g. nfCRMSolution).

.PARAMETER PreviousEnvironmentUrl
    Dataverse environment URL of the prior stage to compare against
    (e.g. https://myorg-dev.crm.dynamics.com).

.PARAMETER TargetEnvironmentUrl
    Dataverse environment URL of the environment being deployed into.
    Required when BaseSolutions is provided.

.PARAMETER BaseSolutions
    Comma-separated list of solution unique names to check for cross-environment
    version consistency (e.g. "nfBase,nfCustomizations,nfShared").
    Optional — omit or pass empty string to skip base-solution checks.

.PARAMETER AppId
    Service principal application / client ID.

.PARAMETER ClientSecret
    Service principal client secret.

.PARAMETER TenantId
    Azure AD tenant ID.
#>
param(
    [Parameter(Mandatory)][string] $ArtifactFolder,
    [Parameter(Mandatory)][string] $SolutionName,
    [Parameter(Mandatory)][string] $PreviousEnvironmentUrl,
    [string]                        $TargetEnvironmentUrl = '',
    [string]                        $BaseSolutions        = '',
    [Parameter(Mandatory)][string] $AppId,
    [Parameter(Mandatory)][string] $ClientSecret,
    [Parameter(Mandatory)][string] $TenantId
)

$ErrorActionPreference = 'Stop'

# ── Helper: parse a "major.minor.build.revision" string into [version] ─────────
function ConvertTo-Ver([string]$v) {
    if (-not $v -or $v -eq '0.0.0.0') { return [version]'0.0.0.0' }
    try {
        $parts = ($v.Trim().Split('.') + @('0','0','0','0'))[0..3]
        return [version]("$($parts[0]).$($parts[1]).$($parts[2]).$($parts[3])")
    } catch {
        return [version]'0.0.0.0'
    }
}

# ── Helper: obtain a Dataverse bearer token ────────────────────────────────────
function Get-DataverseToken([string]$EnvUrl) {
    $body = @{
        client_id     = $AppId
        client_secret = $ClientSecret
        grant_type    = 'client_credentials'
        scope         = "$EnvUrl/.default"
    }
    $resp = Invoke-RestMethod `
        -Uri     "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
        -Method  POST `
        -Body    $body
    return $resp.access_token
}

# ── Helper: query deployed solution version from a Dataverse environment ───────
function Get-DeployedVersion([string]$EnvUrl, [string]$Token, [string]$UniqueName) {
    $headers = @{
        'Authorization'    = "Bearer $Token"
        'Accept'           = 'application/json'
        'OData-MaxVersion' = '4.0'
        'OData-Version'    = '4.0'
    }
    $apiUrl  = "$EnvUrl/api/data/v9.2/solutions?`$filter=uniquename eq '$UniqueName'&`$select=version,uniquename"
    try {
        $resp = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method GET
        if ($resp.value.Count -gt 0) { return $resp.value[0].version }
        return '0.0.0.0'   # solution not found — treat as not yet deployed
    } catch {
        Write-Warning "  Could not query '$UniqueName' from $EnvUrl — $_"
        return 'N/A'
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 1 — Current solution: artifact ZIP vs previous environment
# ══════════════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
Write-Host "  🔍 CURRENT SOLUTION — $SolutionName"
Write-Host "     Artifact  →  $PreviousEnvironmentUrl"
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Read version from the unmanaged ZIP inside the artifact folder
$unmanZip = Get-ChildItem -Path $ArtifactFolder -Filter "*_unmanaged.zip" -Recurse |
            Select-Object -First 1

if (-not $unmanZip) {
    Write-Error "No *_unmanaged.zip found in '$ArtifactFolder'"
    exit 1
}

Write-Host "  Reading Solution.xml from: $($unmanZip.Name)"
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive  = [System.IO.Compression.ZipFile]::OpenRead($unmanZip.FullName)
$solEntry = $archive.GetEntry('Other/Solution.xml')
if (-not $solEntry) {
    $archive.Dispose()
    Write-Error "'Other/Solution.xml' not found inside $($unmanZip.Name)"
    exit 1
}
$reader     = New-Object System.IO.StreamReader($solEntry.Open())
$xmlText    = $reader.ReadToEnd()
$reader.Close()
$archive.Dispose()

$artifactVersion = if ($xmlText -match '<Version>([^<]+)</Version>') { $Matches[1].Trim() } else { '1.0.0.0' }
Write-Host "  Artifact version     : $artifactVersion"

# Query previous environment for current solution
$prevToken      = Get-DataverseToken -EnvUrl $PreviousEnvironmentUrl
$prevCurVersion = Get-DeployedVersion -EnvUrl $PreviousEnvironmentUrl -Token $prevToken -UniqueName $SolutionName
Write-Host "  Previous env version : $prevCurVersion"

# Evaluate
$artVer  = ConvertTo-Ver $artifactVersion
$prevCur = ConvertTo-Ver $prevCurVersion

$curResult  = ''
$curIcon    = ''
$curFail    = $false

if ($prevCurVersion -eq 'N/A') {
    $curResult = 'Query failed'
    $curIcon   = '⚠️'
} elseif ($prevCurVersion -eq '0.0.0.0') {
    $curResult = 'Not yet deployed in prev env'
    $curIcon   = 'ℹ️'
} elseif ($artVer -lt $prevCur) {
    $curResult = '❌ DOWNGRADE'
    $curIcon   = '❌'
    $curFail   = $true
} elseif ($artVer -eq $prevCur) {
    $curResult = 'Same version (re-deploy)'
    $curIcon   = '⚠️'
} else {
    $curResult = 'Version OK ✅'
    $curIcon   = '✅'
}

Write-Host "  Result               : $curIcon $curResult"

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 2 — Base solutions: previous environment vs target environment
# ══════════════════════════════════════════════════════════════════════════════
$baseResults = @()   # array of [hashtable]

$baseList = @($BaseSolutions.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })

if ($baseList.Count -gt 0) {
    if (-not $TargetEnvironmentUrl) {
        Write-Error "-TargetEnvironmentUrl is required when -BaseSolutions is provided."
        exit 1
    }

    Write-Host ""
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    Write-Host "  🔍 BASE SOLUTIONS — $PreviousEnvironmentUrl → $TargetEnvironmentUrl"
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Obtain tokens for both environments (reuse prevToken for prev env)
    $targetToken = Get-DataverseToken -EnvUrl $TargetEnvironmentUrl

    foreach ($sol in $baseList) {
        Write-Host ""
        Write-Host "  ── $sol"

        $prevVer   = Get-DeployedVersion -EnvUrl $PreviousEnvironmentUrl -Token $prevToken   -UniqueName $sol
        $targetVer = Get-DeployedVersion -EnvUrl $TargetEnvironmentUrl   -Token $targetToken -UniqueName $sol

        Write-Host "    Previous env  : $prevVer"
        Write-Host "    Target  env   : $targetVer"

        $pVer = ConvertTo-Ver $prevVer
        $tVer = ConvertTo-Ver $targetVer

        $result = ''
        $icon   = ''
        $fail   = $false

        if ($prevVer -eq 'N/A' -or $targetVer -eq 'N/A') {
            $result = 'Query failed'
            $icon   = '⚠️'
        } elseif ($prevVer -eq '0.0.0.0') {
            $result = 'Not in prev env'
            $icon   = 'ℹ️'
        } elseif ($targetVer -eq '0.0.0.0') {
            $result = 'Not yet in target env'
            $icon   = 'ℹ️'
        } elseif ($pVer -lt $tVer) {
            # Previous env has an older version than target — deploying would downgrade target
            $result = '❌ DOWNGRADE (prev env behind target)'
            $icon   = '❌'
            $fail   = $true
        } elseif ($pVer -eq $tVer) {
            $result = 'In sync ✅'
            $icon   = '✅'
        } else {
            # pVer > tVer — previous env is ahead, target will receive an upgrade
            $result = 'Upgrade ✅'
            $icon   = '✅'
        }

        Write-Host "    Result        : $icon $result"

        $baseResults += @{
            Solution     = $sol
            PreviousVer  = $prevVer
            TargetVer    = $targetVer
            Result       = $result
        }
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 3 — Unified Step Summary
# ══════════════════════════════════════════════════════════════════════════════
$summaryLines = @()
$summaryLines += ""
$summaryLines += "### 🔢 Solution Version Comparison"
$summaryLines += ""

# Current solution table
$summaryLines += "#### Current Solution"
$summaryLines += ""
$summaryLines += "| Check | Value |"
$summaryLines += "| --- | --- |"
$summaryLines += "| Solution | \`$SolutionName\` |"
$summaryLines += "| Artifact version | \`$artifactVersion\` |"
$summaryLines += "| Previous env (\`$($PreviousEnvironmentUrl.Split('/')[2])\`) | \`$prevCurVersion\` |"
$summaryLines += "| Result | $curIcon $curResult |"

# Base solutions table
if ($baseList.Count -gt 0) {
    $summaryLines += ""
    $summaryLines += "#### Base Solutions"
    $summaryLines += ""
    $summaryLines += "| Solution | Prev Env Version | Target Env Version | Result |"
    $summaryLines += "| --- | --- | --- | --- |"
    foreach ($r in $baseResults) {
        $icon = if ($r.Result -match '❌') { '❌' } elseif ($r.Result -match '⚠️') { '⚠️' } else { '✅' }
        $summaryLines += "| \`$($r.Solution)\` | \`$($r.PreviousVer)\` | \`$($r.TargetVer)\` | $($r.Result) |"
    }
}

$summaryLines -join "`n" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 4 — Final pass/fail determination
# ══════════════════════════════════════════════════════════════════════════════
$anyFail = $curFail

foreach ($r in $baseResults) {
    if ($r.Result -match '❌') { $anyFail = $true }
}

Write-Host ""
if ($anyFail) {
    Write-Host "::error::❌ One or more version checks failed. See the step summary for details."
    exit 1
} else {
    Write-Host "✅ All version checks passed."
}
