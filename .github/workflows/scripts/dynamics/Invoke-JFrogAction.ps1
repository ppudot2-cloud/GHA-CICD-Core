<#
.SYNOPSIS
    Executes a JFrog Artifactory action: upload, download, or tag.

.DESCRIPTION
    Centralises all JFrog interactions for Power Platform solution artifacts.
    Artifactory path convention:
        {repo}/{repo_name}/{solution_name}/{run_number}/{run_attempt}/{filename}

.PARAMETER Action
    'upload'   – pushes local ZIPs to Artifactory
    'download' – pulls ZIPs from Artifactory to a local folder
    'tag'      – sets item properties (metadata) on remote artifacts

.PARAMETER JFrogUrl
    Artifactory base URL (e.g. https://company.jfrog.io/artifactory).

.PARAMETER JFrogRepo
    Artifactory repository name (e.g. powerplatform-solutions).

.PARAMETER JFrogToken
    JFrog API key / OIDC token (X-JFrog-Art-Api header).
    Pass $env:JFROG_TOKEN — sourced from the jfrog/setup-jfrog-cli OIDC exchange
    or from Azure Key Vault when using a static API key.

.PARAMETER SolutionName
    Unique solution name.

.PARAMETER RepoName
    GitHub repository name (without owner) — used as first path segment.

.PARAMETER RunNumber
    GitHub Actions run number.

.PARAMETER RunAttempt
    GitHub Actions run attempt.

.PARAMETER LocalPath
    For upload: local folder containing the ZIPs to upload.
    For download: local destination folder.

.PARAMETER TagProperties
    For tag action: semicolon-separated key=value pairs
    (e.g. "pipeline=release;approved=true").

.PARAMETER MockDeploy
    If $true, prints what would happen without making network calls.
#>
param(
    [Parameter(Mandatory)][ValidateSet('upload','download','tag')][string] $Action,
    [Parameter(Mandatory)][string] $JFrogUrl,
    [Parameter(Mandatory)][string] $JFrogRepo,
    [Parameter(Mandatory)][string] $JFrogToken,
    [Parameter(Mandatory)][string] $SolutionName,
    [Parameter(Mandatory)][string] $RepoName,
    [Parameter(Mandatory)][string] $RunNumber,
    [Parameter(Mandatory)][string] $RunAttempt,
    [string] $LocalPath      = '.',
    [string] $TagProperties  = '',
    [bool]   $MockDeploy     = $false
)

$ErrorActionPreference = 'Stop'

# Base remote path: {repo}/{repo_name}/{solution_name}/{run_number}/{run_attempt}/
$remotePath = "$JFrogRepo/$RepoName/$SolutionName/$RunNumber/$RunAttempt"
$baseUrl    = "$JFrogUrl/$remotePath"

$headers = @{
    'X-JFrog-Art-Api' = $JFrogToken
}

switch ($Action) {

    # ── UPLOAD ────────────────────────────────────────────────────────────────
    'upload' {
        $zips = Get-ChildItem -Path $LocalPath -Filter "*.zip" -File
        if ($zips.Count -eq 0) {
            Write-Host "::warning::No ZIP files found in $LocalPath — nothing to upload."
            exit 0
        }

        @"
## 📦 JFrog Artifactory Upload
**Repository path:** ``$remotePath``

| File | Size | URL | Status |
| --- | --- | --- | --- |
"@ | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append

        $fail = $false
        foreach ($zip in $zips) {
            $targetUrl = "$baseUrl/$($zip.Name)"
            $sizeMB    = [math]::Round($zip.Length / 1MB, 2)

            if ($MockDeploy) {
                Write-Host "🧪 [MOCK] Would upload: $($zip.Name) → $targetUrl"
                "| ``$($zip.Name)`` | $sizeMB MB | ``$targetUrl`` | 🧪 Simulated |" |
                    Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
                continue
            }

            Write-Host "📦 Uploading $($zip.Name) ($sizeMB MB) → $targetUrl"
            try {
                $response = Invoke-WebRequest `
                    -Uri $targetUrl `
                    -Method PUT `
                    -Headers $headers `
                    -InFile $zip.FullName `
                    -UseBasicParsing

                if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) {
                    Write-Host "✅ Uploaded: $($zip.Name) (HTTP $($response.StatusCode))"
                    "| ``$($zip.Name)`` | $sizeMB MB | ``$targetUrl`` | ✅ HTTP $($response.StatusCode) |" |
                        Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
                } else {
                    Write-Host "::error::Upload failed for $($zip.Name) (HTTP $($response.StatusCode))"
                    "| ``$($zip.Name)`` | $sizeMB MB | ``$targetUrl`` | ❌ HTTP $($response.StatusCode) |" |
                        Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
                    $fail = $true
                }
            } catch {
                Write-Host "::error::Upload exception for $($zip.Name): $_"
                "| ``$($zip.Name)`` | $sizeMB MB | ``$targetUrl`` | ❌ Exception |" |
                    Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
                $fail = $true
            }
        }
        if ($fail) { exit 1 }
    }

    # ── DOWNLOAD ──────────────────────────────────────────────────────────────
    'download' {
        if (-not (Test-Path $LocalPath)) {
            New-Item -ItemType Directory -Path $LocalPath -Force | Out-Null
        }

        if ($MockDeploy) {
            Write-Host "🧪 [MOCK] Would download from: $baseUrl → $LocalPath"
            exit 0
        }

        # List files at remote path using AQL or folder listing
        $listUrl  = "$JFrogUrl/api/storage/$remotePath"
        $listing  = Invoke-RestMethod -Uri $listUrl -Headers $headers -Method GET
        $children = $listing.children | Where-Object { $_.uri -like '/*.zip' }

        if (-not $children) {
            Write-Error "::error::No ZIP files found at Artifactory path: $remotePath"
            exit 1
        }

        @"
## 📥 JFrog Artifactory Download
**Repository path:** ``$remotePath``
**Local destination:** ``$LocalPath``

| File | Status |
| --- | --- |
"@ | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append

        foreach ($child in $children) {
            $fileName  = $child.uri.TrimStart('/')
            $sourceUrl = "$baseUrl/$fileName"
            $destFile  = Join-Path $LocalPath $fileName

            Write-Host "📥 Downloading $fileName ← $sourceUrl"
            Invoke-WebRequest -Uri $sourceUrl -Headers $headers -OutFile $destFile -UseBasicParsing
            Write-Host "✅ Downloaded: $fileName"
            "| ``$fileName`` | ✅ Downloaded to ``$destFile`` |" |
                Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
        }
    }

    # ── TAG ───────────────────────────────────────────────────────────────────
    'tag' {
        if (-not $TagProperties) {
            Write-Host "::warning::tag action called with no TagProperties — nothing to set."
            exit 0
        }

        # Convert semicolon-separated key=value to Artifactory properties query string
        # e.g. "pipeline=release;approved=true" → ?properties=pipeline=release;approved=true
        $propsQuery = $TagProperties.Replace(';', ';')  # already correct format

        # List remote ZIPs and apply properties
        $listUrl  = "$JFrogUrl/api/storage/$remotePath"
        $listing  = Invoke-RestMethod -Uri $listUrl -Headers $headers -Method GET
        $children = $listing.children | Where-Object { $_.uri -like '/*.zip' }

        @"
## 🏷️ JFrog Artifactory Tag
**Repository path:** ``$remotePath``
**Properties:** ``$TagProperties``

| File | Status |
| --- | --- |
"@ | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append

        foreach ($child in $children) {
            $fileName = $child.uri.TrimStart('/')
            $propsUrl = "$JFrogUrl/api/storage/$remotePath/$fileName`?properties=$propsQuery"

            if ($MockDeploy) {
                Write-Host "🧪 [MOCK] Would tag: $fileName with $TagProperties"
                "| ``$fileName`` | 🧪 Simulated tag: ``$TagProperties`` |" |
                    Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
                continue
            }

            $response = Invoke-WebRequest -Uri $propsUrl -Headers $headers -Method PUT -UseBasicParsing
            Write-Host "🏷️ Tagged $fileName (HTTP $($response.StatusCode))"
            "| ``$fileName`` | ✅ Tagged (HTTP $($response.StatusCode)) |" |
                Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
        }
    }
}
