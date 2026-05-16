<#
.SYNOPSIS
    Reads the solution version from Solution.xml. Does NOT modify the file.

.DESCRIPTION
    The version in Solution.xml is the source of truth. Developers own the
    version number — the pipeline never auto-stamps it.

    Artifact uniqueness is handled at the artifact-name level (run_number +
    run_attempt), not by changing the solution version.

.PARAMETER SolutionXmlPath
    Relative path to the solution's Other/Solution.xml file.

.OUTPUTS
    Sets GITHUB_OUTPUT: version=<current_version>
    Appends a version table to GITHUB_STEP_SUMMARY.
#>
param(
    [Parameter(Mandatory)][string] $SolutionXmlPath
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $SolutionXmlPath)) {
    Write-Error "::error file=$SolutionXmlPath::Solution.xml not found at expected path."
    exit 1
}

[xml]$xml = Get-Content $SolutionXmlPath -Encoding UTF8
$version  = $xml.ImportExportXml.SolutionManifest.Version
$solName  = $xml.ImportExportXml.SolutionManifest.UniqueName

if (-not $version) {
    Write-Error "::error::Version element not found in $SolutionXmlPath. Ensure <Version> exists under SolutionManifest."
    exit 1
}

# Validate format (Major.Minor.Build.Revision)
if ($version -notmatch '^\d+\.\d+\.\d+\.\d+$') {
    Write-Warning "::warning::Version '$version' does not match Major.Minor.Build.Revision format. Proceeding anyway."
}

# GitHub Actions output
"version=$version" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append

# Step summary
@"
### 🏷️ Solution Version (from Solution.xml)
| Field | Value |
| --- | --- |
| Solution | ``$solName`` |
| Version  | ``$version`` |

> ℹ️ Version is read directly from `Other/Solution.xml` and is **not modified by the pipeline**.
> Update the version in `Solution.xml` to release a new version.
"@ | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append

Write-Host "✅ Solution version: $version (read from $SolutionXmlPath — file not modified)"
