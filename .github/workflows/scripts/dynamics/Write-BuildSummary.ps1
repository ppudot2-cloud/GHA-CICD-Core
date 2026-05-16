<#
.SYNOPSIS
    Writes the final build step summary table to GITHUB_STEP_SUMMARY.

.PARAMETER SolutionName
    Unique solution name.

.PARAMETER SolutionVersion
    Stamped version string (e.g. 1.0.42.0).

.PARAMETER ArtifactName
    GitHub Actions artifact name.

.PARAMETER RunNumber
    GitHub run number.

.PARAMETER MockDeploy
    Whether this was a mock_deploy run.

.PARAMETER CheckerGeo
    Solution Checker geography used.

.PARAMETER DataSchemaFile
    Path to data schema file (empty string = not used).

.PARAMETER EnableJFrogUpload
    Whether JFrog upload was enabled.

.PARAMETER JFrogUrl
    JFrog base URL (for display in summary).

.PARAMETER JFrogRepo
    JFrog repository name.

.NOTES
    JFrog upload fires AFTER Solution Checker passes during the build job.
    After Prod deploy, the artifact is tagged with prodDeployed=true;deployedDate=<date>.

#>
param(
    [Parameter(Mandatory)][string] $SolutionName,
    [Parameter(Mandatory)][AllowEmptyString()][string] $SolutionVersion,
    [Parameter(Mandatory)][AllowEmptyString()][string] $ArtifactName,
    [Parameter(Mandatory)][string] $RunNumber,
    [bool]   $MockDeploy        = $false,
    [string] $CheckerGeo        = 'UnitedStates',
    [string] $DataSchemaFile    = '',
    [bool]   $EnableJFrogUpload = $true,
    [string] $JFrogUrl          = '',
    [string] $JFrogRepo         = '',
    # Path to write a JSON record for the consolidated pipeline summary.
    # Leave blank to skip JSON output.
    [string] $JsonOutputPath    = ''
)

$checkerRow = if ($MockDeploy) {
    "| Solution Checker | mock_deploy | 🧪 Simulated (ZIP + XML validation) |"
} else {
    "| Solution Checker | live (always on) | ✅ Real (geo: ``$CheckerGeo``) |"
}

$dataRow = if (-not $DataSchemaFile) {
    "| Export config data | — | ⏭️ No schema file provided |"
} elseif ($MockDeploy) {
    "| Export config data | mock_deploy | 🧪 Simulated (schema parse + placeholder ZIP) |"
} else {
    "| Export config data | live | ✅ Real (schema: ``$DataSchemaFile``) |"
}

$jfrogRow = if (-not $EnableJFrogUpload) {
    "| JFrog upload | — | ⏭️ Disabled |"
} elseif ($MockDeploy) {
    "| JFrog upload | mock_deploy | 🧪 Simulated (no network call) |"
} else {
    $dest = if ($JFrogUrl) { "``$JFrogUrl/$JFrogRepo``" } else { "Artifactory" }
    "| JFrog upload | after checker | ✅ Package uploaded → $dest |"
}

@"

## 🏗️ Build Results — $SolutionName
| Step | Mode | Status |
| --- | --- | --- |
| Version stamp | Always | ``$SolutionVersion`` |
| Pack Unmanaged | Always | ✅ $(if ($MockDeploy) { 'Mock (no PAC CLI)' } else { 'Real (PAC CLI)' }) |
| Pack Managed | Always | ✅ $(if ($MockDeploy) { 'Mock (no PAC CLI)' } else { 'Real (PAC CLI)' }) |
$checkerRow
$dataRow
$jfrogRow
| Prod tag | After Prod deploy | ⏳ ``prodDeployed=true;deployedDate=<date>`` set on success |

| Artifact | ``$ArtifactName`` |
| Run # | $RunNumber |
"@ | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append

# ── Write JSON record for consolidated pipeline summary ───────────────────
if ($JsonOutputPath) {
    $dir = Split-Path $JsonOutputPath -Parent
    if ($dir) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    @{
        job_type         = 'build'
        solution         = $SolutionName
        version          = $SolutionVersion
        artifact_name    = $ArtifactName
        run_number       = $RunNumber
        mock_deploy      = $MockDeploy
        checker_geo      = $CheckerGeo
        data_schema_file = $DataSchemaFile
        jfrog_enabled    = $EnableJFrogUpload
        jfrog_url        = $JFrogUrl
        timestamp        = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')
    } | ConvertTo-Json -Depth 5 | Set-Content -Path $JsonOutputPath -Encoding UTF8

    Write-Host "📄 Job summary record written → $JsonOutputPath"
}
