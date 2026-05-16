<#
.SYNOPSIS
    Strips the <Managed> tag from a Power Platform Solution.xml file.

.DESCRIPTION
    PAC CLI 1.40+ validates that the <Managed> flag in Solution.xml matches the
    requested --packageType. Exports from Dataverse always produce <Managed>0</Managed>
    (unmanaged source), which causes the managed pack to fail with
    "Solution package type did not match requested type."
    Removing the tag lets PAC CLI use --packageType alone to decide the output
    format — this is the standard practice for dual unmanaged+managed builds.

.PARAMETER SolutionXmlPath
    Relative path to the solution's Other/Solution.xml file.
#>
param(
    [Parameter(Mandatory)][string] $SolutionXmlPath
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $SolutionXmlPath)) {
    Write-Error "Solution.xml not found at: $SolutionXmlPath"
    exit 1
}

$content = Get-Content $SolutionXmlPath -Raw -Encoding UTF8

if ($content -match '<Managed>') {
    # Remove the <Managed>...</Managed> line entirely
    $updated = $content -replace '\s*<Managed>[^<]*</Managed>', ''
    # Remove any resulting blank lines
    $updated = $updated -replace '(?m)^\s*$\n', ''
    Set-Content -Path $SolutionXmlPath -Value $updated -Encoding UTF8 -NoNewline
    Write-Host "✅ Stripped <Managed> tag from $SolutionXmlPath"
} else {
    Write-Host "ℹ️  No <Managed> tag found in $SolutionXmlPath — nothing to strip"
}
