<#
.SYNOPSIS
    Stamps a new version into a Power Platform Solution.xml file.

.PARAMETER SolutionXmlPath
    Relative path to the solution's Other/Solution.xml file.

.PARAMETER VersionStrategy
    'run_number'  – uses GitHub run_number as the BUILD component (Major.Minor.BUILD.0)
    'gittags'     – derives BUILD and REVISION from the latest git tag

.PARAMETER RunNumber
    GitHub Actions run number (used when VersionStrategy = run_number).

.OUTPUTS
    Sets GITHUB_OUTPUT: version=<new_version>
    Appends a version table to GITHUB_STEP_SUMMARY.
#>
param(
    [Parameter(Mandatory)][string] $SolutionXmlPath,
    [Parameter(Mandatory)][string] $VersionStrategy,
    [Parameter(Mandatory)][string] $RunNumber
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $SolutionXmlPath)) {
    Write-Error "::error file=$SolutionXmlPath::Solution.xml not found at expected path."
    exit 1
}

[xml]$xml = Get-Content $SolutionXmlPath -Encoding UTF8
$current = $xml.ImportExportXml.SolutionManifest.Version
if (-not $current) { $current = '1.0.0.0' }

$parts = $current.Split('.')
$major = $parts[0]
$minor = if ($parts.Length -gt 1) { $parts[1] } else { '0' }

if ($VersionStrategy -eq 'run_number') {
    $build    = $RunNumber
    $revision = '0'
} else {
    # gittags strategy: derive from latest git tag
    $tag = (git describe --tags --abbrev=0 2>$null) ?? '1.0.0.0'
    $tagParts = $tag.Split('.')
    $build    = if ($tagParts.Length -gt 2) { $tagParts[2] } else { $RunNumber }
    $revision = if ($tagParts.Length -gt 3) { $tagParts[3] } else { '0' }
}

$newVersion = "$major.$minor.$build.$revision"

# Update the XML in place
$xml.ImportExportXml.SolutionManifest.Version = $newVersion
$xml.Save((Resolve-Path $SolutionXmlPath))

# GitHub Actions outputs
"version=$newVersion" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append

# Step summary
@"
### 🏷️ Solution Version
| Parameter | Value |
| --- | --- |
| Previous | ``$current`` |
| New      | ``$newVersion`` |
"@ | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append

Write-Host "✅ Version stamped: $current → $newVersion"
