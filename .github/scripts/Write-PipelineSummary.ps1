<#
.SYNOPSIS
    Writes the final pipeline summary table to GITHUB_STEP_SUMMARY.

.PARAMETER SolutionList
    Comma-separated list of solutions that were processed.

.PARAMETER SolutionCount
    Number of solutions.

.PARAMETER RunNumber
    GitHub run number.

.PARAMETER RefName
    Git ref name (branch or tag).

.PARAMETER CommitSha
    Full commit SHA.

.PARAMETER SetupResult / BuildResult
    GitHub job outcomes for setup and build.

.PARAMETER GateDevResult / DeployDevResult
    GitHub job outcomes for the Dev gate and deploy.

.PARAMETER GateIntgResult / DeployIntgResult / etc.
    GitHub job outcomes for each gate and deploy stage.
#>
param(
    [string] $SolutionList      = '',
    [string] $SolutionCount     = '0',
    [string] $RunNumber         = '',
    [string] $RefName           = '',
    [string] $CommitSha         = '',
    [string] $SetupResult       = 'skipped',
    [string] $BuildResult       = 'skipped',
    [string] $GateDevResult     = 'skipped',
    [string] $DeployDevResult   = 'skipped',
    [string] $GateIntgResult    = 'skipped',
    [string] $DeployIntgResult  = 'skipped',
    [string] $GateUatResult     = 'skipped',
    [string] $DeployUatResult   = 'skipped',
    [string] $GatePerfResult    = 'skipped',
    [string] $DeployPerfResult  = 'skipped',
    [string] $GateProdResult    = 'skipped',
    [string] $DeployProdResult  = 'skipped',
    # Directory containing job-summary JSON records emitted by build/deploy jobs.
    # Pass the path where all job-summary-* artifacts were downloaded.
    # Leave blank to skip the per-job detail section.
    [string] $JobSummariesDir   = ''
)

function Get-Icon([string]$outcome) {
    switch ($outcome) {
        'success'   { return '✅' }
        'warning'   { return '⚠️' }
        'skipped'   { return '⏭️' }
        'cancelled' { return '🚫' }
        default     { return '❌' }
    }
}

function Get-StepIcon([string]$outcome) {
    switch ($outcome) {
        'success'  { return '✅' }
        'failure'  { return '❌' }
        'warning'  { return '⚠️' }
        'skipped'  { return '⏭️' }
        'disabled' { return '—' }
        'mock'     { return '🧪' }
        default    { return '—' }
    }
}

# ── Consolidated pipeline status table ────────────────────────────────────────
@"
# 🏭 Release Pipeline Summary — Run #$RunNumber

**Solutions:** ``$SolutionList``  **Ref:** ``$RefName``  **Commit:** ``${CommitSha.Substring(0, [Math]::Min(7, $CommitSha.Length))}``

| Stage | Environment | Result |
| --- | --- | --- |
| 🔍 Resolve | — | $(Get-Icon $SetupResult) |
| 🏗️ Build (×$SolutionCount) | — | $(Get-Icon $BuildResult) |
| 🔐 Gate | Dev | $(Get-Icon $GateDevResult) |
| 🚀 Deploy | Dev | $(Get-Icon $DeployDevResult) |
| 🔐 Gate | Intg | $(Get-Icon $GateIntgResult) |
| 🚀 Deploy | Intg | $(Get-Icon $DeployIntgResult) |
| 🔐 Gate | UAT | $(Get-Icon $GateUatResult) |
| 🚀 Deploy | UAT | $(Get-Icon $DeployUatResult) |
| 🔐 Gate | Perf | $(Get-Icon $GatePerfResult) |
| 🚀 Deploy | Perf | $(Get-Icon $DeployPerfResult) |
| 🔐 Gate | Prod | $(Get-Icon $GateProdResult) |
| 🚀 Deploy | Prod | $(Get-Icon $DeployProdResult) |

"@ | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append

# ── Per-job detail (from collected job summary JSON records) ──────────────────
if ($JobSummariesDir -and (Test-Path $JobSummariesDir)) {
    $jsonFiles = Get-ChildItem -Path $JobSummariesDir -Filter '*.json' -Recurse | Sort-Object Name
    if ($jsonFiles.Count -gt 0) {

        # ── Build details ─────────────────────────────────────────────────
        $buildFiles = $jsonFiles | Where-Object { $_.Name -like 'build-*.json' }
        if ($buildFiles) {
            @"
---
## 🏗️ Build Details

| Solution | Version | Artifact | Checker Geo | JFrog | Mock |
| --- | --- | --- | --- | --- | --- |
"@ | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append

            foreach ($f in $buildFiles) {
                $rec = Get-Content $f.FullName -Raw | ConvertFrom-Json
                $jfrogIcon = if ($rec.jfrog_enabled) { '✅' } else { '—' }
                $mockIcon  = if ($rec.mock_deploy)   { '🧪' } else { '—' }
                "| ``$($rec.solution)`` | ``$($rec.version)`` | ``$($rec.artifact_name)`` | $($rec.checker_geo) | $jfrogIcon | $mockIcon |" |
                    Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
            }
            "" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
        }

        # ── Deploy details ─────────────────────────────────────────────────
        $deployFiles = $jsonFiles | Where-Object { $_.Name -like 'deploy-*.json' }
        if ($deployFiles) {
            @"
---
## 🚀 Deployment Details

| Environment | Solution | Auth | Async Ops | Version Cmp | Backup | Import |
| --- | --- | --- | --- | --- | --- | --- |
"@ | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append

            foreach ($f in $deployFiles) {
                $rec = Get-Content $f.FullName -Raw | ConvertFrom-Json
                $env     = $rec.environment
                $sol     = $rec.solution
                $whoAmI  = Get-StepIcon $rec.steps.who_am_i
                $block   = Get-StepIcon $rec.steps.blocking_check
                $ver     = Get-StepIcon $rec.steps.version_compare
                $bak     = Get-StepIcon $rec.steps.backup
                $imp     = Get-StepIcon $rec.steps.import
                "| **$env** | ``$sol`` | $whoAmI | $block | $ver | $bak | $imp |" |
                    Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
            }
            "" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
        }
    }
}
