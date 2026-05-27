<#
.SYNOPSIS
    Discovers, validates, and orders the solution matrix for a pipeline run.

.DESCRIPTION
    1. Reads solutions.json (or falls back to src/solutions/ filesystem scan).
    2. Validates the requested solution subset.
    3. Orders solutions using Kahn's topological sort over the dependsOn graph,
       with deployOrder as the tiebreaker within the same dependency level.
       dependsOn IS enforced — declaring dependsOn: [A] guarantees A imports before B.
       deployOrder resolves ordering when solutions have no direct dependency relationship.
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
# Primary source: solutions.json (contains deployOrder, dataSchemaFile, deploymentSettings, etc.)
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

# ── 3. Order by dependsOn topology, then deployOrder as tiebreaker ────────────
#
# dependsOn is NOW enforced: if Solution B declares dependsOn: [A], A will always
# import before B regardless of deployOrder values. deployOrder is used as the
# tiebreaker when two solutions have no dependency relationship.
#
# Algorithm: Kahn's topological sort
#   1. Build adjacency list and in-degree count from dependsOn declarations
#   2. Seed the queue with nodes that have no unresolved dependencies, sorted by deployOrder
#   3. Process queue — each time a node is emitted, decrement in-degree of its dependents
#   4. If processing completes with nodes remaining → cycle detected → hard error

$selectedSet = [System.Collections.Generic.HashSet[string]]($selectedNames)
$selectedItems = $registry | Where-Object { $_.name -in $selectedNames }

# Build in-degree count and adjacency list (A → [nodes that depend on A])
$inDegree  = @{}   # name → count of unresolved dependencies
$outEdges  = @{}   # name → list of names that depend on this node

foreach ($sol in $selectedItems) {
    if (-not $inDegree.ContainsKey($sol.name)) { $inDegree[$sol.name] = 0 }
    if (-not $outEdges.ContainsKey($sol.name)) { $outEdges[$sol.name] = @() }

    foreach ($dep in ($sol.dependsOn ?? @())) {
        if ($dep -notin $selectedSet) {
            # Dependency is outside the selected set — warn but don't block
            Write-Host "::warning::[$($sol.name)] dependsOn '$dep' is not in the selected solution set — dependency ignored"
            continue
        }
        $inDegree[$sol.name]++
        if (-not $outEdges.ContainsKey($dep)) { $outEdges[$dep] = @() }
        $outEdges[$dep] += $sol.name
    }
}

# Kahn's BFS — seed queue with zero-in-degree nodes, sorted by deployOrder
$sortedByOrder = $selectedItems |
    Sort-Object { if ($null -ne $_.deployOrder) { [int]$_.deployOrder } else { [int]::MaxValue } }

# Use a simple ordered list as queue (small N, no need for heap)
$queue = [System.Collections.Generic.List[string]]::new()
foreach ($sol in $sortedByOrder) {
    if ($inDegree[$sol.name] -eq 0) { $queue.Add($sol.name) }
}

$topologicalOrder = [System.Collections.Generic.List[string]]::new()

while ($queue.Count -gt 0) {
    $current = $queue[0]
    $queue.RemoveAt(0)
    $topologicalOrder.Add($current)

    # Decrement in-degree for each node that depends on current
    foreach ($dependent in $outEdges[$current]) {
        $inDegree[$dependent]--
        if ($inDegree[$dependent] -eq 0) {
            # Insert in deploy-order position within the ready queue
            $depOrder = ($selectedItems | Where-Object { $_.name -eq $dependent } |
                         Select-Object -First 1).deployOrder
            $depOrder = if ($null -ne $depOrder) { [int]$depOrder } else { [int]::MaxValue }

            # Find insertion point (keep queue sorted by deployOrder)
            $insertAt = $queue.Count
            for ($qi = 0; $qi -lt $queue.Count; $qi++) {
                $qOrder = ($selectedItems | Where-Object { $_.name -eq $queue[$qi] } |
                           Select-Object -First 1).deployOrder
                $qOrder = if ($null -ne $qOrder) { [int]$qOrder } else { [int]::MaxValue }
                if ($depOrder -lt $qOrder) { $insertAt = $qi; break }
            }
            $queue.Insert($insertAt, $dependent)
        }
    }
}

# Cycle detection
if ($topologicalOrder.Count -lt $selectedNames.Count) {
    $cycleNodes = $inDegree.GetEnumerator() |
        Where-Object { $_.Value -gt 0 } | ForEach-Object { $_.Key }
    Write-Error "::error::Circular dependency detected in solutions.json among: $($cycleNodes -join ', ')"
    Write-Error "::error::Check dependsOn declarations — no solution may directly or transitively depend on itself."
    exit 1
}

$selectedEntries = $topologicalOrder | ForEach-Object {
    $sol = $registry | Where-Object { $_.name -eq $_ } | Select-Object -First 1
    # Guard: solution name must be non-empty (empty name produces src/solutions//Other/Solution.xml)
    if (-not $sol.name) {
        Write-Error "::error::A solution entry in solutions.json has an empty 'name' field. All solutions must have a non-empty unique name."
        exit 1
    }
    $rawFolder = if ($sol.folder) { $sol.folder } else { "src/solutions/$($sol.name)" }
    [PSCustomObject]@{
        name                       = $sol.name
        source_folder              = $rawFolder.TrimEnd('/')   # prevent double-slash path bugs
        data_schema_file           = if ($sol.dataSchemaFile) { $sol.dataSchemaFile } else { '' }
        deployment_settings_prefix = 'deployment-settings'
    }
}

Write-Host "ℹ️  Ordered by topology (dependsOn) with deployOrder as tiebreaker:"
for ($i = 0; $i -lt $selectedEntries.Count; $i++) {
    $entry = $registry | Where-Object { $_.name -eq $selectedEntries[$i].name }
    $order = if ($null -ne $entry.deployOrder) { $entry.deployOrder } else { '(none)' }
    $deps  = if ($entry.dependsOn -and $entry.dependsOn.Count -gt 0) { " → after: [$($entry.dependsOn -join ', ')]" } else { '' }
    Write-Host "   $($i+1). $($selectedEntries[$i].name)  [deployOrder=$order]$deps"
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
