<#
.SYNOPSIS
    Creates a simulation ZIP for a Power Platform solution without invoking PAC CLI.

.DESCRIPTION
    Used in mock_deploy mode to bypass PAC CLI pack (which requires valid Dataverse
    solution source). Creates a structurally valid solution ZIP containing the key
    manifests (Solution.xml, Customizations.xml, [Content_Types].xml) so that
    downstream validation steps (Solution Checker sim, JFrog sim) find the file.

.PARAMETER SolutionFolder
    Path to the unpacked solution source folder.

.PARAMETER OutputZipPath
    Full path for the output ZIP file (including filename).

.PARAMETER PackageType
    'Unmanaged' or 'Managed'
#>
param(
    [Parameter(Mandatory)][string] $SolutionFolder,
    [Parameter(Mandatory)][string] $OutputZipPath,
    [Parameter(Mandatory)][ValidateSet('Unmanaged','Managed')][string] $PackageType
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $SolutionFolder)) {
    Write-Error "Solution source folder not found: $SolutionFolder"
    exit 1
}

# Ensure output directory exists
$outDir = Split-Path $OutputZipPath -Parent
if ($outDir -and -not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

# Remove existing ZIP if present
if (Test-Path $OutputZipPath) { Remove-Item $OutputZipPath -Force }

# Compress the solution folder
Compress-Archive -Path "$SolutionFolder/*" -DestinationPath $OutputZipPath -Force

$size = [math]::Round((Get-Item $OutputZipPath).Length / 1KB, 1)
Write-Host "✅ Mock $PackageType ZIP created: $OutputZipPath ($size KB)"

# Step summary entry
@"

| 🧪 Pack $PackageType | Mock (no PAC CLI) | ``$OutputZipPath`` ($size KB) |
"@ | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
