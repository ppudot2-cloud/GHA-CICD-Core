<#
.SYNOPSIS
    Discovers, validates, and orders the solution matrix for a pipeline run.

.DESCRIPTION
    1. Scans src/solutions/ for available solution directories.
    2. Validates the requested solution subset against discovered solutions.
    3. Applies deploy ordering from .github/solutions-config.json if present.
    4. Writes the matrix JSON, solution list, and count to GITHUB_OUTPUT.

.PARAMETER InputSolutions
    The 'solutions' workflow input: "all" or comma-separated solution names.

.PARAMETER PpSolutionName
    Fallback single-solution name from PP_SOLUTION_NAME repo variable.

.PARAMETER SolutionsDir
    Base directory containing unpacked solution folders (default: src/solutions).

.PARAMETER ConfigFile
    Path to solutions-config.json (default: .github/solutions-config.json).
#>
param(
    [string] $InputSolutions  = 'all',
    [string] $PpSolutionName  = '',
    [string] $SolutionsDir    = 'src/solutions',
    [string] $ConfigFile      = '.github/solutions-config.json'
)

$ErrorActionPreference = 'Stop'

# ── 1. Discover solutions from filesystem ─────────────────────────────────────
$discovered = @()
if (Test-Path $SolutionsDir) {
    $discovered = Get-ChildItem -Path $SolutionsDir -Directory |
        Where-Object { -not $_.Name.StartsWith('.') } |
        Sort-Object Name |
        Select-Object -ExpandProperty Name
}

# ── 2. Determine selected solution set ────────────────────────────────────────
$input = $InputSolutions.Trim()

if ($input.ToLower() -eq 'all') {
    if ($discovered.Count -gt 0) {
        $selected = $discovered
        Write-Host "ℹ️  Resolved all $($discovered.Count) solution(s) from $SolutionsDir/"
    } elseif ($PpSolutionName) {
        $selected = @($PpSolutionName)
        Write-Host "ℹ️  No src/solutions/ dirs found — using PP_SOLUTION_NAME: $PpSolutionName"
    } else {
        Write-Error "::error::No solutions found in $SolutionsDir/ and PP_SOLUTION_NAME is not set."
        exit 1
    }
} else {
    $selected = $input.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    if ($selected.Count -eq 0) {
        Write-Error "::error::The 'solutions' input is empty after parsing."
        exit 1
    }
    if ($discovered.Count -gt 0) {
        $unknown = $selected | Where-Object { $_ -notin $discovered }
        if ($unknown.Count -gt 0) {
            Write-Error "::error::Solution(s) not found in ${SolutionsDir}/: $($unknown -join ', ')"
            Write-Error "::error::Available: $($discovered -join ', ')"
            exit 1
        }
    }
}

# ── 3. Apply ordering from solutions-config.json ──────────────────────────────
if (Test-Path $ConfigFile) {
    try {
        $config      = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        $selectedSet = [System.Collections.Generic.HashSet[string]]::new($selected)
        $ordered     = [System.Collections.Generic.List[string]]::new()

        foreach ($entry in $config.solutions) {
            $name = if ($entry -is [string]) { $entry } else { $entry.name }
            if ($selectedSet.Contains($name)) {
                $ordered.Add($name)
                $selectedSet.Remove($name) | Out-Null
            }
        }
        foreach ($rem in ($selectedSet | Sort-Object)) { $ordered.Add($rem) }
        $selected = $ordered.ToArray()
        Write-Host "ℹ️  Applied deploy ordering from $ConfigFile"
    } catch {
        Write-Host "::warning::Could not parse $ConfigFile`: $_. Using alphabetical order."
    }
}

# ── 4. Write outputs ──────────────────────────────────────────────────────────
$matrix       = ConvertTo-Json @{ solution = $selected } -Compress
$solutionList = $selected -join ', '
$count        = $selected.Count

"matrix=$matrix"             | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
"solution_list=$solutionList"| Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
"solution_count=$count"      | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append

Write-Host ""
Write-Host "✅ $count solution(s) in deploy order:"
for ($i = 0; $i -lt $selected.Count; $i++) {
    Write-Host "   $($i+1). $($selected[$i])"
}

# ── 5. Setup step summary ──────────────────────────────────────────────────────
@"

## 🔍 Resolved Solutions
| # | Solution | Deploy Order |
| --- | --- | --- |
"@ | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append

for ($i = 0; $i -lt $selected.Count; $i++) {
    "| $($i+1) | ``$($selected[$i])`` | Sequential ($($i+1) of $count) |" |
        Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
}
