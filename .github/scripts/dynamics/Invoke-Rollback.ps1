<#
.SYNOPSIS
    Restores solutions in a target environment from backup ZIPs.

.DESCRIPTION
    Called by rollback.yml. Reads solutions.json, finds the corresponding
    backup ZIP for each solution in deployOrder sequence, and imports them
    using PAC CLI. The backup ZIPs are expected to already be downloaded
    to -BackupDir by actions/download-artifact before this script runs.

    Backup ZIP naming convention (set by deploy-all-solutions):
        {BackupDir}/{SolutionName}_{EnvironmentName}_backup.zip

.PARAMETER BackupDir
    Local directory containing the backup ZIPs (downloaded from the artifact).

.PARAMETER EnvironmentUrl
    Dataverse environment URL to restore to.

.PARAMETER EnvironmentName
    Friendly name of the environment (Dev, Intg, UAT, FRS, Perf, Prod).
    Used for logging and backup file name matching.

.PARAMETER SolutionsJson
    Raw JSON string from solutions.json — used to read solution names and deployOrder.

.PARAMETER MockDeploy
    When true, logs what would happen without making PAC CLI calls.
#>

param(
    [Parameter(Mandatory)] [string] $BackupDir,
    [Parameter(Mandatory)] [string] $EnvironmentUrl,
    [Parameter(Mandatory)] [string] $EnvironmentName,
    [Parameter(Mandatory)] [string] $SolutionsJson,
    [switch] $MockDeploy
)

$ErrorActionPreference = 'Stop'

# ── Parse solutions.json ──────────────────────────────────────────────────────
$registry  = $SolutionsJson | ConvertFrom-Json
$solutions = $registry.solutions | Sort-Object deployOrder

Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host "  ROLLBACK → $EnvironmentName" -ForegroundColor Cyan
Write-Host "  Solutions : $($solutions.Count)  |  Backup dir : $BackupDir" -ForegroundColor Cyan
Write-Host "  Target    : $EnvironmentUrl" -ForegroundColor Cyan
if ($MockDeploy) { Write-Host "  ⚠️  MOCK MODE — no real imports will be made" -ForegroundColor Yellow }
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host ""

# ── Authenticate PAC CLI ──────────────────────────────────────────────────────
if (-not $MockDeploy) {
    Write-Host "Authenticating PAC CLI to $EnvironmentUrl ..."
    pac auth create `
        --url            $EnvironmentUrl `
        --applicationId  $env:PP_APP_ID `
        --clientSecret   $env:PP_CLIENT_SECRET `
        --tenant         $env:PP_TENANT_ID | Out-Null
    Write-Host "  ✅ Authenticated"
} else {
    Write-Host "  [MOCK] Skipping PAC CLI auth" -ForegroundColor Cyan
}

# ── Per-solution restore loop ─────────────────────────────────────────────────
$results = @()

foreach ($sol in $solutions) {
    $name        = $sol.name
    $backupFile  = Join-Path $BackupDir "${name}_${EnvironmentName}_backup.zip"

    Write-Host ""
    Write-Host "  [$name] Restoring backup ..." -ForegroundColor Yellow

    # ── Verify backup file exists ─────────────────────────────────────────────
    if (-not (Test-Path $backupFile)) {
        # Try case-insensitive search (env name may be cased differently in the file)
        $found = Get-ChildItem $BackupDir -Filter "${name}_*_backup.zip" | Select-Object -First 1
        if ($found) {
            $backupFile = $found.FullName
            Write-Host "  [$name] Found backup at: $backupFile (case-variant)" -ForegroundColor Yellow
        } else {
            Write-Host "  [$name] ❌ Backup file not found: $backupFile" -ForegroundColor Red
            Write-Host "  [$name]    Contents of ${BackupDir}:"
            Get-ChildItem $BackupDir | ForEach-Object { Write-Host "    $_" }
            Write-Host "::error::[$name] Backup ZIP not found. The backup artifact may not have included this solution, or the environment name in the filename does not match."
            $results += [PSCustomObject]@{ Solution = $name; Result = '❌ Backup not found'; File = $backupFile }
            continue
        }
    }

    Write-Host "  [$name] Backup file : $backupFile"

    # ── Import ────────────────────────────────────────────────────────────────
    if ($MockDeploy) {
        Write-Host "  [$name] [MOCK] pac solution import --path $backupFile --managed --force-overwrite --publish-changes" -ForegroundColor Cyan
        $results += [PSCustomObject]@{ Solution = $name; Result = '🧪 Simulated'; File = (Split-Path $backupFile -Leaf) }
    } else {
        try {
            Write-Host "  [$name] Importing backup — force-overwrite ..."
            pac solution import `
                --path          $backupFile `
                --environment   $EnvironmentUrl `
                --managed `
                --force-overwrite `
                --publish-changes

            Write-Host "  [$name] ✅ Restored successfully" -ForegroundColor Green
            $results += [PSCustomObject]@{ Solution = $name; Result = '✅ Restored'; File = (Split-Path $backupFile -Leaf) }
        } catch {
            Write-Host "  [$name] ❌ Import failed: $_" -ForegroundColor Red
            Write-Host "::error::[$name] Rollback import failed: $_"
            $results += [PSCustomObject]@{ Solution = $name; Result = "❌ Failed: $_"; File = (Split-Path $backupFile -Leaf) }
            # Continue restoring remaining solutions even if one fails
        }
    }
}

# ── Step summary ──────────────────────────────────────────────────────────────
$ts = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' UTC'

$summaryRows = $results | ForEach-Object {
    "| $($_.Solution) | $($_.File) | $($_.Result) |"
}

$summary = @"
## Rollback — $EnvironmentName

**Environment:** $EnvironmentUrl
**Completed:** $ts
**Mock mode:** $($MockDeploy.ToString())

| Solution | Backup File | Result |
|---|---|---|
$($summaryRows -join "`n")
"@

$summary | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8

# ── Exit with error if any solution failed ────────────────────────────────────
$failures = $results | Where-Object { $_.Result -like '❌*' }
if ($failures.Count -gt 0) {
    Write-Host ""
    Write-Host "❌ Rollback completed with $($failures.Count) failure(s):" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "   $($_.Solution): $($_.Result)" -ForegroundColor Red }
    exit 1
} else {
    Write-Host ""
    Write-Host "✅ Rollback complete — $($results.Count) solution(s) restored to $EnvironmentName" -ForegroundColor Green
}
