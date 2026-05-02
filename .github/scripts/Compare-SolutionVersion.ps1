<#
.SYNOPSIS
    Compares the solution version in the built artifact vs the version deployed
    in the previous environment. Fails on version downgrade.

.PARAMETER ArtifactFolder
    Folder containing the solution ZIPs (e.g. out/MySolution).

.PARAMETER SolutionName
    Unique solution name.

.PARAMETER PreviousEnvironmentUrl
    URL of the prior pipeline environment to compare against.

.PARAMETER AppId
    Service principal application/client ID.

.PARAMETER ClientSecret
    Service principal client secret.

.PARAMETER TenantId
    Azure AD tenant ID.
#>
param(
    [Parameter(Mandatory)][string] $ArtifactFolder,
    [Parameter(Mandatory)][string] $SolutionName,
    [Parameter(Mandatory)][string] $PreviousEnvironmentUrl,
    [Parameter(Mandatory)][string] $AppId,
    [Parameter(Mandatory)][string] $ClientSecret,
    [Parameter(Mandatory)][string] $TenantId
)

$ErrorActionPreference = 'Stop'

Write-Host "🔄 Comparing solution version in artifact vs $PreviousEnvironmentUrl ..."

# ── Read version from artifact ZIP ────────────────────────────────────────────
$unmanZip = Get-ChildItem -Path $ArtifactFolder -Filter "*_unmanaged.zip" | Select-Object -First 1
if (-not $unmanZip) {
    Write-Error "No unmanaged ZIP found in $ArtifactFolder"
    exit 1
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive  = [System.IO.Compression.ZipFile]::OpenRead($unmanZip.FullName)
$solEntry = $archive.GetEntry('Other/Solution.xml')
if (-not $solEntry) {
    $archive.Dispose()
    Write-Error "Other/Solution.xml not found in $($unmanZip.Name)"
    exit 1
}
$reader      = New-Object System.IO.StreamReader($solEntry.Open())
$solXmlText  = $reader.ReadToEnd()
$reader.Close()
$archive.Dispose()

$artifactVersion = if ($solXmlText -match '<Version>([^<]+)</Version>') { $Matches[1] } else { '1.0.0.0' }
Write-Host "  Artifact version     : $artifactVersion"

# ── Query deployed version from previous environment ──────────────────────────
$tokenBody = @{
    client_id     = $AppId
    client_secret = $ClientSecret
    grant_type    = 'client_credentials'
    scope         = "$PreviousEnvironmentUrl/.default"
}
$tokenResponse = Invoke-RestMethod `
    -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
    -Method POST `
    -Body $tokenBody
$token = $tokenResponse.access_token

$apiUrl  = "$PreviousEnvironmentUrl/api/data/v9.2/solutions?`$filter=uniquename eq '$SolutionName'&`$select=version"
$headers = @{
    'Authorization'   = "Bearer $token"
    'Accept'          = 'application/json'
    'OData-MaxVersion'= '4.0'
    'OData-Version'   = '4.0'
}
$response    = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method GET
$prevVersion = if ($response.value.Count -gt 0) { $response.value[0].version } else { '0.0.0.0' }
Write-Host "  Previous env version : $prevVersion"

# ── Compare ───────────────────────────────────────────────────────────────────
function ConvertTo-VersionTuple([string]$v) {
    $parts = $v.Split('.')
    return [version]("$($parts[0]).$($parts[1]).$($parts[2]).$($parts[3])")
}

$av = ConvertTo-VersionTuple $artifactVersion
$pv = ConvertTo-VersionTuple $prevVersion

# Step summary
@"

### 🔢 Version Comparison
| Environment | Version |
| --- | --- |
| Artifact (to deploy) | ``$artifactVersion`` |
| Previous environment | ``$prevVersion`` |
"@ | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append

if ($av -lt $pv) {
    Write-Error "::error::Version downgrade detected! Artifact $artifactVersion < Previous env $prevVersion. Aborting."
    exit 1
} elseif ($av -eq $pv) {
    Write-Host "::warning::Same version $artifactVersion already deployed in previous environment. Proceeding anyway."
} else {
    Write-Host "✅ Version OK: $artifactVersion > $prevVersion"
}
