<#
.SYNOPSIS
    Writes the deployment step summary to GITHUB_STEP_SUMMARY.

.PARAMETER EnvironmentName
    Display name of the environment (e.g. Dev, Intg, UAT).

.PARAMETER EnvironmentUrl
    Target environment URL.

.PARAMETER SolutionName
    Unique solution name.

.PARAMETER RunNumber
    GitHub run number.

.PARAMETER MockDeploy
    Whether this was a mock_deploy run.

.PARAMETER SolutionType
    'managed' or 'unmanaged'.

.PARAMETER WhoAmIOutcome
    'success', 'failure', or 'skipped'.

.PARAMETER BlockingCheckOutcome
    'success', 'failure', 'skipped', or 'disabled'.

.PARAMETER VersionCompareOutcome
    'success', 'failure', 'skipped', or 'disabled'.

.PARAMETER BackupOutcome
    'success', 'failure', 'skipped', or 'disabled'.

.PARAMETER ImportOutcome
    'success', 'failure', 'skipped', or 'mock'.
#>
param(
    [Parameter(Mandatory)][string] $EnvironmentName,
    [Parameter(Mandatory)][string] $EnvironmentUrl,
    [Parameter(Mandatory)][string] $SolutionName,
    [Parameter(Mandatory)][string] $RunNumber,
    [bool]   $MockDeploy            = $false,
    [string] $SolutionType          = 'managed',
    [string] $WhoAmIOutcome         = 'skipped',
    [string] $BlockingCheckOutcome  = 'skipped',
    [string] $VersionCompareOutcome = 'skipped',
    [string] $BackupOutcome         = 'skipped',
    [string] $ImportOutcome         = 'skipped',
    # Path to write a JSON record for the consolidated pipeline summary.
    # Leave blank to skip JSON output.
    [string] $JsonOutputPath        = ''
)

function Get-Icon([string]$outcome) {
    switch ($outcome) {
        'success'  { return '✅' }
        'failure'  { return '❌' }
        'warning'  { return '⚠️ Warning' }   # blocking-check: ops found but pipeline continued
        'skipped'  { return '⏭️' }
        'disabled' { return '⏭️ Off' }
        'mock'     { return '🧪 Mock' }
        default    { return '—' }
    }
}

@"

## 📊 Deployment Summary — $EnvironmentName
| Step | Toggle | Result |
| --- | --- | --- |
| Auth (who-am-i) | Always | $(Get-Icon $WhoAmIOutcome) |
| Blocking check | $(if ($BlockingCheckOutcome -ne 'disabled') {'On'} else {'Off'}) | $(Get-Icon $BlockingCheckOutcome) |
| Version compare | $(if ($VersionCompareOutcome -ne 'disabled') {'On'} else {'Off'}) | $(Get-Icon $VersionCompareOutcome) |
| Solution Checker | ✅ Always On (enforced at build) | ✅ |
| Backup | $(if ($BackupOutcome -ne 'disabled') {'On'} else {'Off'}) | $(Get-Icon $BackupOutcome) |
| Import | $(if ($MockDeploy) {'MOCK'} else {$SolutionType}) | $(Get-Icon $ImportOutcome) |

**Environment:** ``$EnvironmentUrl``
**Solution:** ``$SolutionName``
**Run:** ``#$RunNumber``
"@ | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append

# ── Write JSON record for consolidated pipeline summary ───────────────────
if ($JsonOutputPath) {
    $dir = Split-Path $JsonOutputPath -Parent
    if ($dir) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    # Determine overall import success for the record
    $overallImport = $ImportOutcome

    @{
        job_type              = 'deploy'
        environment           = $EnvironmentName
        environment_url       = $EnvironmentUrl
        solution              = $SolutionName
        solution_type         = $SolutionType
        run_number            = $RunNumber
        mock_deploy           = $MockDeploy
        timestamp             = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')
        steps = @{
            who_am_i        = $WhoAmIOutcome
            blocking_check  = $BlockingCheckOutcome
            version_compare = $VersionCompareOutcome
            backup          = $BackupOutcome
            import          = $overallImport
        }
    } | ConvertTo-Json -Depth 5 | Set-Content -Path $JsonOutputPath -Encoding UTF8

    Write-Host "📄 Job summary record written → $JsonOutputPath"
}
