<#
.SYNOPSIS
    Discovers, validates, and orders the solution matrix for a pipeline run.

.DESCRIPTION
    1. Reads solutions.json (or falls back to src/solutions/ filesystem scan).
    2. Validates the requested solution subset.
    3. Orders solutions by the deployOrder integer field (ascending).
       deployOrder controls the sequential import sequence — lowest number imports first.
       dependsOn in solutions.json is informational metadata only and does NOT affect order.
    4. Writes matrix JSON, solution list, and count to GITHUB_OUTPUT.

.PARAMETER InputSolutions
    The 'solutions' workflow input: "all" or comma-separated solution names.

.PARAMETER PpSolutionName
    Fallback single-solution name from PP_SOLUTION_NAME repo variable.

.PARAMETER SolutionsJsonPath
    Path to solutions.json (default: solutions.json in repo root).

.PARAMETER SolutionsDir
    Fallback directory scan path when solutions.json is absent (default: src/solutions).
#>
param(
    [string] $InputSolutions   = 'all',
    [string] $PpSolutionName   = '',
    [string] $SolutionsJsonPath = 'solutions.json',
    [string] $SolutionsDir     = 'src/solutions'
)

$ErrorActionPreference = 'Stop'

# ── 1. Load solution registry ─────────────────────────────────────────────────
# Primary source: solutions.json (contains deployOrder, checkerGeo, etc.)
# Fallback: filesystem scan of src/solutions/ (order = alphabetical)

$registry = @()   # array of objects with at least .name and .deployOrder

if (Test-Path $SolutionsJsonPath) {
    try {
        $json     = Get-Content $SolutionsJsonPath -Raw | ConvertFrom-Json
        $registry = $json.solutions
        Write-Host "ℹ️  Loaded $($registry.Count) solution(s) from $SolutionsJsonPath"
    } catch {
        Write-Warning "Could not parse $SolutionsJsonPath`: $_. Falling back to filesystem scan."
        $registry = @()
    }
}

if ($registry.Count -eq 0) {
    # Filesystem fallback — assign deployOrder by alphabetical position
    if (Test-Path $SolutionsDir) {
        $dirs = Get-ChildItem -Path $SolutionsDir -Directory |
                Where-Object { -not $_.Name.StartsWith('.') } |
                Sort-Object Name
        $i = 1
        foreach ($d in $dirs) {
            $registry += [PSCustomObject]@{ name = $d.Name; deployOrder = $i++ }
        }
        Write-Host "ℹ️  No solutions.json — discovered $($registry.Count) solution(s) from $SolutionsDir/"
    }
}

if ($registry.Count -eq 0 -and $PpSolutionName) {
    $registry = @([PSCustomObject]@{ name = $PpSolutionName; deployOrder = 1 })
    Write-Host "ℹ️  No solutions found in filesystem — using PP_SOLUTION_NAME: $PpSolutionName"
}

if ($registry.Count -eq 0) {
    Write-Error "::error::No solutions found in $SolutionsJsonPath or $SolutionsDir/ and PP_SOLUTION_NAME is not set."
    exit 1
}

# ── 2. Determine selected solution set ────────────────────────────────────────
$input = $InputSolutions.Trim()
$allNames = $registry | ForEach-Object { $_.name }

if ($input.ToLower() -eq 'all') {
    $selectedNames = $allNames
    Write-Host "ℹ️  Selecting all $($registry.Count) solution(s)"
} else {
    $selectedNames = $input.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    if ($selectedNames.Count -eq 0) {
        Write-Error "::error::The 'solutions' input is empty after parsing."
        exit 1
    }
    # Validate each requested name exists in the registry
    $unknown = $selectedNames | Where-Object { $_ -notin $allNames }
    if ($unknown.Count -gt 0) {
        Write-Error "::error::Solution(s) not found in registry: $($unknown -join ', ')"
        Write-Error "::error::Available: $($allNames -join ', ')"
        exit 1
    }
}

# ── 3. Order by deployOrder (ascending) ───────────────────────────────────────
# deployOrder is the sole sequencing mechanism.
# dependsOn in solutions.json is documentation metadata only — not used here.
# Solutions without a deployOrder field sort after those that have one.

$selectedEntries = $registry |
    Where-Object { $_.name -in $selectedNames } |
    Sort-Object { if ($null -ne $_.deployOrder) { [int]$_.deployOrder } else { [int]::MaxValue } } |
    ForEach-Object {
        [PSCustomObject]@{
            name                       = $_.name
            source_folder              = if ($_.folder) { $_.folder } else { "src/solutions/$($_.name)" }
            checker_geo                = if ($_.checkerGeo) { $_.checkerGeo } else { 'UnitedStates' }
            data_schema_file           = if ($_.dataSchemaFile) { $_.dataSchemaFile } else { '' }
            deployment_settings_prefix = 'deployment-settings'
        }
    }

Write-Host "ℹ️  Ordered by deployOrder:"
for ($i = 0; $i -lt $selectedEntries.Count; $i++) {
    $entry = $registry | Where-Object { $_.name -eq $selectedEntries[$i].name }
    $order = if ($null -ne $entry.deployOrder) { $entry.deployOrder } else { '(none)' }
    Write-Host "   $($i+1). $($selectedEntries[$i].name)  [deployOrder=$order]"
}

# ── 4. Write outputs ──────────────────────────────────────────────────────────
$matrix       = ConvertTo-Json @{ solution = @($selectedEntries) } -Compress
$solutionList = ($selectedEntries | ForEach-Object { $_.name }) -join ', '
$count        = $selectedEntries.Count

"matrix=$matrix"              | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
"solution_list=$solutionList" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
"solution_count=$count"       | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append

Write-Host ""
Write-Host "✅ $count solution(s) resolved in deploy order:"
for ($i = 0; $i -lt $selectedEntries.Count; $i++) {
    Write-Host "   $($i+1). $($selectedEntries[$i].name)"
}

# ── 5. Step summary ───────────────────────────────────────────────────────────
@"

## 🔍 Resolved Solutions
| # | Solution | Deploy Order |
| --- | --- | --- |
"@ | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append

for ($i = 0; $i -lt $selectedEntries.Count; $i++) {
    $entry = $registry | Where-Object { $_.name -eq $selectedEntries[$i].name }
    $order = if ($null -ne $entry.deployOrder) { $entry.deployOrder } else { 'n/a' }
    "| $($i+1) | ``$($selectedEntries[$i].name)`` | $order |" |
        Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
}
