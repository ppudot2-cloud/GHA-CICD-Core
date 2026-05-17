<#
.SYNOPSIS
    Simulates the Power Platform Solution Checker in mock_deploy mode.

.DESCRIPTION
    Validates the structural integrity of both packed ZIPs without requiring
    PP credentials or network access. Fails the build if ZIPs are missing or
    key manifests are absent. Writes detailed results to GITHUB_STEP_SUMMARY.

.PARAMETER SolutionName
    Unique solution name (used to locate ZIP files).

.PARAMETER OutputFolder
    Folder containing the packed ZIPs (e.g. out/MySolution).

.PARAMETER UnmanagedZip
    Full path to the unmanaged ZIP.

.PARAMETER ManagedZip
    Full path to the managed ZIP.

.PARAMETER ErrorLevel
    Minimum severity level that would fail the checker (informational in simulation).
    Valid values: CriticalIssue, HighIssue, MediumIssue, LowIssue, InformationalIssue
#>
param(
    [Parameter(Mandatory)][string] $SolutionName,
    [Parameter(Mandatory)][string] $UnmanagedZip,
    [Parameter(Mandatory)][string] $ManagedZip,
    [string] $ErrorLevel   = 'HighIssue'
)

$ErrorActionPreference = 'Stop'

# Ensure unzip utility is available
$hasUnzip = $null -ne (Get-Command unzip -ErrorAction SilentlyContinue)

$fail = $false

@"
## 🧪 Solution Checker — Simulation
_mock_deploy=true — validating ZIP structure locally, no PP credentials used_
**Geography:** UnitedStates
**Error Level threshold:** ``$ErrorLevel``

| Check | ZIP | Result |
| --- | --- | --- |
"@ | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append

foreach ($entry in @(
    @{ Label = 'Unmanaged'; Path = $UnmanagedZip },
    @{ Label = 'Managed';   Path = $ManagedZip   }
)) {
    $label = $entry.Label
    $zip   = $entry.Path

    # ── Existence + size ──────────────────────────────────────────────────
    if (-not (Test-Path $zip)) {
        Write-Host "::error::$zip not found — pack step may have failed."
        "| ❌ ZIP exists | $label | File not found: ``$zip`` |" |
            Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
        $fail = $true
        continue
    }
    $sizeMB = [math]::Round((Get-Item $zip).Length / 1MB, 2)
    "| ✅ ZIP exists | $label | ``$zip`` ($sizeMB MB) |" |
        Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append

    # ── Solution.xml ──────────────────────────────────────────────────────
    if ($hasUnzip) {
        $solXml = (& unzip -p $zip "Other/Solution.xml" 2>$null) -join "`n"
    } else {
        # PowerShell native
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
        $entry2  = $archive.GetEntry('Other/Solution.xml')
        if ($entry2) {
            $reader = New-Object System.IO.StreamReader($entry2.Open())
            $solXml = $reader.ReadToEnd()
            $reader.Close()
        } else { $solXml = $null }
        $archive.Dispose()
    }

    if (-not $solXml) {
        Write-Host "::error::Could not extract Other/Solution.xml from $zip"
        "| ❌ Solution.xml | $label | Not found in ZIP |" |
            Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
        $fail = $true
    } else {
        $uniqueName = if ($solXml -match '<UniqueName>([^<]+)</UniqueName>') { $Matches[1] } else { 'unknown' }
        $version    = if ($solXml -match '<Version>([^<]+)</Version>') { $Matches[1] } else { 'unknown' }
        "| ✅ Solution.xml | $label | UniqueName=``$uniqueName`` Version=``$version`` |" |
            Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
    }

    # ── Customizations.xml ────────────────────────────────────────────────
    if ($hasUnzip) {
        $custXml = (& unzip -p $zip "Other/Customizations.xml" 2>$null)
    } else {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
        $entry2  = $archive.GetEntry('Other/Customizations.xml')
        $custXml = if ($entry2) { 'present' } else { $null }
        $archive.Dispose()
    }
    if (-not $custXml) {
        Write-Host "::error::Could not extract Other/Customizations.xml from $zip"
        "| ❌ Customizations.xml | $label | Not found in ZIP |" |
            Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
        $fail = $true
    } else {
        "| ✅ Customizations.xml | $label | Present and readable |" |
            Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
    }

    # ── [Content_Types].xml ───────────────────────────────────────────────
    if ($hasUnzip) {
        $ctCount = (& unzip -l $zip 2>$null | Select-String '\[Content_Types\]').Count
    } else {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
        $ctCount = ($archive.Entries | Where-Object { $_.Name -eq '[Content_Types].xml' }).Count
        $archive.Dispose()
    }
    if ($ctCount -eq 0) {
        Write-Host "::warning::$zip is missing [Content_Types].xml"
        "| ⚠️ [Content_Types].xml | $label | Missing — warning only |" |
            Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
    } else {
        "| ✅ [Content_Types].xml | $label | Present |" |
            Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
    }
}

@"

### Simulated Rule Categories
| Rule Category | Simulated Result |
| --- | --- |
| AppSource Package Compliance | 🧪 Would run against geo: UnitedStates |
| Managed Solution Accessibility | 🧪 Simulated — no issues |
| Usage Telemetry | 🧪 Simulated — no issues |
| Performance | 🧪 Simulated — no issues |
| Design | 🧪 Simulated — no issues |
| Supportability | 🧪 Simulated — no issues |

> Error level threshold (live run): ``$ErrorLevel``
> Re-run without mock_deploy=true for a full live analysis.
"@ | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append

Write-Host "::notice::Solution Checker SIMULATED. Re-run without mock_deploy=true for live analysis."

if ($fail) {
    Write-Error "::error::Simulated Solution Checker failed — one or more ZIPs have structural issues."
    exit 1
}
