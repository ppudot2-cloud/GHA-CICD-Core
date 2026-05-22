<#
.SYNOPSIS
    Pester unit tests for Set-SolutionVersion.ps1

.DESCRIPTION
    Verifies:
      - Version is read correctly from a valid Solution.xml
      - GITHUB_OUTPUT receives version=<value>
      - Solution.xml is NOT modified (read-only operation)
      - Missing Solution.xml exits with non-zero code
      - Missing <Version> element exits with non-zero code
      - Non-standard version format emits a warning but does not fail

.NOTES
    Run from the GHA-Core repository root:
        Invoke-Pester .github/servicenow/Tests/Unit/Dynamics/Set-SolutionVersion.Tests.ps1

    Requires: Pester v5+, PowerShell 7+
#>

BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot '../../../../scripts/dynamics/Set-SolutionVersion.ps1'
    if (-not (Test-Path $scriptPath)) {
        throw "Script not found: $scriptPath"
    }

    # Helper — create a minimal Solution.xml with given version
    function New-SolutionXml([string]$Dir, [string]$Version, [string]$UniqueName = 'TestSolution') {
        $xmlContent = @"
<?xml version="1.0" encoding="utf-8"?>
<ImportExportXml>
  <SolutionManifest>
    <UniqueName>$UniqueName</UniqueName>
    <Version>$Version</Version>
    <Managed>0</Managed>
  </SolutionManifest>
</ImportExportXml>
"@
        $path = Join-Path $Dir 'Solution.xml'
        $xmlContent | Set-Content $path -Encoding utf8
        return $path
    }
}

Describe 'Set-SolutionVersion — happy path' {
    BeforeEach {
        $tmpDir = [System.IO.Path]::GetTempPath() + [System.Guid]::NewGuid().ToString()
        New-Item -ItemType Directory -Path $tmpDir | Out-Null
        $tmpOutput = [System.IO.Path]::GetTempFileName()
        $tmpSummary = [System.IO.Path]::GetTempFileName()
        $env:GITHUB_OUTPUT       = $tmpOutput
        $env:GITHUB_STEP_SUMMARY = $tmpSummary
    }

    AfterEach {
        $env:GITHUB_OUTPUT       = $null
        $env:GITHUB_STEP_SUMMARY = $null
        Remove-Item $tmpDir      -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $tmpOutput   -Force         -ErrorAction SilentlyContinue
        Remove-Item $tmpSummary  -Force         -ErrorAction SilentlyContinue
    }

    Context 'Standard Major.Minor.Build.Revision version' {
        It 'writes version=1.2.3.4 to GITHUB_OUTPUT' {
            $xmlPath = New-SolutionXml $tmpDir '1.2.3.4'
            & pwsh -File $scriptPath -SolutionXmlPath $xmlPath | Out-Null
            $output = Get-Content $tmpOutput -Raw
            $output | Should -Match 'version=1\.2\.3\.4'
        }

        It 'exits with code 0' {
            $xmlPath = New-SolutionXml $tmpDir '1.0.0.0'
            & pwsh -File $scriptPath -SolutionXmlPath $xmlPath | Out-Null
            $LASTEXITCODE | Should -Be 0
        }

        It 'does NOT modify the Solution.xml file' {
            $xmlPath  = New-SolutionXml $tmpDir '3.1.4.1'
            $before   = Get-Content $xmlPath -Raw
            & pwsh -File $scriptPath -SolutionXmlPath $xmlPath | Out-Null
            $after    = Get-Content $xmlPath -Raw
            $after | Should -Be $before
        }
    }

    Context 'Solution name is included in GITHUB_STEP_SUMMARY' {
        It 'summary contains the solution unique name' {
            $xmlPath = New-SolutionXml $tmpDir '2.0.0.0' 'MyCRMSolution'
            & pwsh -File $scriptPath -SolutionXmlPath $xmlPath | Out-Null
            $summary = Get-Content $tmpSummary -Raw
            $summary | Should -Match 'MyCRMSolution'
        }
    }
}

Describe 'Set-SolutionVersion — error cases' {
    BeforeEach {
        $tmpDir = [System.IO.Path]::GetTempPath() + [System.Guid]::NewGuid().ToString()
        New-Item -ItemType Directory -Path $tmpDir | Out-Null
        $env:GITHUB_OUTPUT       = [System.IO.Path]::GetTempFileName()
        $env:GITHUB_STEP_SUMMARY = [System.IO.Path]::GetTempFileName()
    }

    AfterEach {
        $env:GITHUB_OUTPUT       = $null
        $env:GITHUB_STEP_SUMMARY = $null
        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'Solution.xml does not exist' {
        It 'exits with a non-zero code' {
            $missing = Join-Path $tmpDir 'doesnotexist.xml'
            & pwsh -File $scriptPath -SolutionXmlPath $missing 2>&1 | Out-Null
            $LASTEXITCODE | Should -Not -Be 0
        }
    }

    Context 'Solution.xml has no <Version> element' {
        It 'exits with a non-zero code' {
            $xmlPath = Join-Path $tmpDir 'Solution.xml'
            @'
<?xml version="1.0" encoding="utf-8"?>
<ImportExportXml>
  <SolutionManifest>
    <UniqueName>NoVersionSolution</UniqueName>
  </SolutionManifest>
</ImportExportXml>
'@ | Set-Content $xmlPath -Encoding utf8

            & pwsh -File $scriptPath -SolutionXmlPath $xmlPath 2>&1 | Out-Null
            $LASTEXITCODE | Should -Not -Be 0
        }
    }
}

Describe 'Set-SolutionVersion — non-standard version format' {
    BeforeEach {
        $tmpDir = [System.IO.Path]::GetTempPath() + [System.Guid]::NewGuid().ToString()
        New-Item -ItemType Directory -Path $tmpDir | Out-Null
        $env:GITHUB_OUTPUT       = [System.IO.Path]::GetTempFileName()
        $env:GITHUB_STEP_SUMMARY = [System.IO.Path]::GetTempFileName()
    }

    AfterEach {
        $env:GITHUB_OUTPUT       = $null
        $env:GITHUB_STEP_SUMMARY = $null
        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'Version is "1.0" (only two parts)' {
        It 'still exits 0 (warning only, not failure)' {
            $xmlPath = New-SolutionXml $tmpDir '1.0'
            & pwsh -File $scriptPath -SolutionXmlPath $xmlPath 2>&1 | Out-Null
            $LASTEXITCODE | Should -Be 0
        }

        It 'still writes the version to GITHUB_OUTPUT' {
            $xmlPath = New-SolutionXml $tmpDir '1.0'
            & pwsh -File $scriptPath -SolutionXmlPath $xmlPath | Out-Null
            $output = Get-Content $env:GITHUB_OUTPUT -Raw
            $output | Should -Match 'version=1\.0'
        }
    }
}
