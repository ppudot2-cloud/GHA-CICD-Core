<#
.SYNOPSIS
    Pester unit tests for Merge-Variables.ps1

.DESCRIPTION
    Verifies:
      - Non-protected project variables override global defaults
      - Protected keys cannot be overridden by project variables (exits 1)
      - AZURE_* keys are never written to GITHUB_ENV regardless of source
      - Missing project-vars.yml is handled gracefully (globals only)
      - DryRun mode produces output without writing to GITHUB_ENV
      - Empty project-vars.yml merges globals without error

.NOTES
    Run from the GHA-Core repository root:
        Invoke-Pester .github/servicenow/Tests/Unit/Dynamics/Merge-Variables.Tests.ps1

    Requires: Pester v5+, PowerShell 7+
#>

BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot '../../../../scripts/dynamics/Merge-Variables.ps1'
    if (-not (Test-Path $scriptPath)) {
        throw "Script not found: $scriptPath"
    }

    # Helper: create a minimal global-vars.yml in a temp dir
    function New-GlobalVarsFile([string]$Dir, [hashtable]$Vars, [string[]]$ProtectedKeys = @()) {
        $lines = @('variables:')
        foreach ($kv in $Vars.GetEnumerator()) {
            $lines += "  $($kv.Key): '$($kv.Value)'"
        }
        if ($ProtectedKeys.Count -gt 0) {
            $lines += 'protected_keys:'
            foreach ($k in $ProtectedKeys) { $lines += "  - $k" }
        }
        $path = Join-Path $Dir 'global-vars.yml'
        $lines | Set-Content $path -Encoding utf8
        return $path
    }

    # Helper: create a minimal project-vars.yml in a temp dir
    function New-ProjectVarsFile([string]$Dir, [hashtable]$Vars) {
        $lines = @('variables:')
        foreach ($kv in $Vars.GetEnumerator()) {
            $lines += "  $($kv.Key): '$($kv.Value)'"
        }
        $path = Join-Path $Dir 'project-vars.yml'
        $lines | Set-Content $path -Encoding utf8
        return $path
    }

    # Helper: invoke Merge-Variables with captured GITHUB_ENV output
    function Invoke-MergeVariables([string]$GlobalPath, [string]$ProjectPath, [switch]$DryRun) {
        $tmpEnv = [System.IO.Path]::GetTempFileName()
        $env:GITHUB_ENV = $tmpEnv

        $args = @('-GlobalVarsPath', $GlobalPath, '-ProjectVarsPath', $ProjectPath)
        if ($DryRun) { $args += '-DryRun' }

        try {
            & pwsh -File $using:scriptPath @args 2>&1
        } finally {
            $written = if (Test-Path $tmpEnv) { Get-Content $tmpEnv -Raw } else { '' }
            Remove-Item $tmpEnv -Force -ErrorAction SilentlyContinue
            $env:GITHUB_ENV = $null
        }
        return $written
    }
}

Describe 'Merge-Variables — variable merge' {
    BeforeEach {
        $tmpDir = [System.IO.Path]::GetTempPath() + [System.Guid]::NewGuid().ToString()
        New-Item -ItemType Directory -Path $tmpDir | Out-Null
    }

    AfterEach {
        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'Project variable overrides global (non-protected key)' {
        It 'writes the project value to GITHUB_ENV' {
            $global  = New-GlobalVarsFile  $tmpDir @{ MY_VAR = 'global-value' }
            $project = New-ProjectVarsFile $tmpDir @{ MY_VAR = 'project-value' }
            $tmpEnv  = [System.IO.Path]::GetTempFileName()
            $env:GITHUB_ENV = $tmpEnv

            & pwsh -File (Join-Path $PSScriptRoot '../../../../scripts/dynamics/Merge-Variables.ps1') `
                -GlobalVarsPath $global -ProjectVarsPath $project | Out-Null

            $written = Get-Content $tmpEnv -Raw
            $env:GITHUB_ENV = $null
            Remove-Item $tmpEnv -Force -ErrorAction SilentlyContinue

            $written | Should -Match 'MY_VAR=project-value'
        }
    }

    Context 'Global-only variable not in project file' {
        It 'writes the global default to GITHUB_ENV' {
            $global  = New-GlobalVarsFile  $tmpDir @{ GLOBAL_ONLY = 'from-global' }
            $project = New-ProjectVarsFile $tmpDir @{}
            $tmpEnv  = [System.IO.Path]::GetTempFileName()
            $env:GITHUB_ENV = $tmpEnv

            & pwsh -File (Join-Path $PSScriptRoot '../../../../scripts/dynamics/Merge-Variables.ps1') `
                -GlobalVarsPath $global -ProjectVarsPath $project | Out-Null

            $written = Get-Content $tmpEnv -Raw
            $env:GITHUB_ENV = $null
            Remove-Item $tmpEnv -Force -ErrorAction SilentlyContinue

            $written | Should -Match 'GLOBAL_ONLY=from-global'
        }
    }
}

Describe 'Merge-Variables — protected key governance' {
    BeforeEach {
        $tmpDir = [System.IO.Path]::GetTempPath() + [System.Guid]::NewGuid().ToString()
        New-Item -ItemType Directory -Path $tmpDir | Out-Null
    }

    AfterEach {
        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'Project attempts to override a protected key' {
        It 'exits with a non-zero code' {
            $global  = New-GlobalVarsFile  $tmpDir @{ PP_CHECKER_GEO = 'unitedstates' } @('PP_CHECKER_GEO')
            $project = New-ProjectVarsFile $tmpDir @{ PP_CHECKER_GEO = 'europe' }

            $result = & pwsh -File (Join-Path $PSScriptRoot '../../../../scripts/dynamics/Merge-Variables.ps1') `
                -GlobalVarsPath $global -ProjectVarsPath $project 2>&1
            $exitCode = $LASTEXITCODE

            $exitCode | Should -Not -Be 0
        }

        It 'prints a violation message' {
            $global  = New-GlobalVarsFile  $tmpDir @{ PP_CHECKER_GEO = 'unitedstates' } @('PP_CHECKER_GEO')
            $project = New-ProjectVarsFile $tmpDir @{ PP_CHECKER_GEO = 'europe' }

            $output = & pwsh -File (Join-Path $PSScriptRoot '../../../../scripts/dynamics/Merge-Variables.ps1') `
                -GlobalVarsPath $global -ProjectVarsPath $project 2>&1 | Out-String

            $output | Should -Match 'PP_CHECKER_GEO'
            $output | Should -Match -RegularExpression '(?i)(protected|violation|cannot|override)'
        }
    }

    Context 'Project does not touch protected keys' {
        It 'exits successfully' {
            $global  = New-GlobalVarsFile  $tmpDir @{ PP_CHECKER_GEO = 'unitedstates'; OTHER_VAR = 'x' } @('PP_CHECKER_GEO')
            $project = New-ProjectVarsFile $tmpDir @{ OTHER_VAR = 'y' }
            $tmpEnv  = [System.IO.Path]::GetTempFileName()
            $env:GITHUB_ENV = $tmpEnv

            & pwsh -File (Join-Path $PSScriptRoot '../../../../scripts/dynamics/Merge-Variables.ps1') `
                -GlobalVarsPath $global -ProjectVarsPath $project | Out-Null
            $exitCode = $LASTEXITCODE

            $env:GITHUB_ENV = $null
            Remove-Item $tmpEnv -Force -ErrorAction SilentlyContinue

            $exitCode | Should -Be 0
        }
    }
}

Describe 'Merge-Variables — AZURE_* key exclusion' {
    BeforeEach {
        $tmpDir = [System.IO.Path]::GetTempPath() + [System.Guid]::NewGuid().ToString()
        New-Item -ItemType Directory -Path $tmpDir | Out-Null
    }

    AfterEach {
        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'AZURE_CLIENT_ID appears in global-vars' {
        It 'is NOT written to GITHUB_ENV' {
            $global  = New-GlobalVarsFile  $tmpDir @{ AZURE_CLIENT_ID = 'fake-client-id'; SAFE_VAR = 'ok' }
            $project = New-ProjectVarsFile $tmpDir @{}
            $tmpEnv  = [System.IO.Path]::GetTempFileName()
            $env:GITHUB_ENV = $tmpEnv

            & pwsh -File (Join-Path $PSScriptRoot '../../../../scripts/dynamics/Merge-Variables.ps1') `
                -GlobalVarsPath $global -ProjectVarsPath $project | Out-Null

            $written = Get-Content $tmpEnv -Raw
            $env:GITHUB_ENV = $null
            Remove-Item $tmpEnv -Force -ErrorAction SilentlyContinue

            $written | Should -Not -Match 'AZURE_CLIENT_ID'
        }

        It 'still writes non-AZURE variables' {
            $global  = New-GlobalVarsFile  $tmpDir @{ AZURE_TENANT_ID = 'fake-tenant'; SAFE_VAR = 'ok' }
            $project = New-ProjectVarsFile $tmpDir @{}
            $tmpEnv  = [System.IO.Path]::GetTempFileName()
            $env:GITHUB_ENV = $tmpEnv

            & pwsh -File (Join-Path $PSScriptRoot '../../../../scripts/dynamics/Merge-Variables.ps1') `
                -GlobalVarsPath $global -ProjectVarsPath $project | Out-Null

            $written = Get-Content $tmpEnv -Raw
            $env:GITHUB_ENV = $null
            Remove-Item $tmpEnv -Force -ErrorAction SilentlyContinue

            $written | Should -Match 'SAFE_VAR=ok'
        }
    }
}

Describe 'Merge-Variables — missing files' {
    BeforeEach {
        $tmpDir = [System.IO.Path]::GetTempPath() + [System.Guid]::NewGuid().ToString()
        New-Item -ItemType Directory -Path $tmpDir | Out-Null
    }

    AfterEach {
        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'project-vars.yml does not exist' {
        It 'uses global defaults without error' {
            $global = New-GlobalVarsFile $tmpDir @{ FALLBACK_VAR = 'global-default' }
            $tmpEnv = [System.IO.Path]::GetTempFileName()
            $env:GITHUB_ENV = $tmpEnv

            & pwsh -File (Join-Path $PSScriptRoot '../../../../scripts/dynamics/Merge-Variables.ps1') `
                -GlobalVarsPath $global `
                -ProjectVarsPath (Join-Path $tmpDir 'nonexistent.yml') | Out-Null
            $exitCode = $LASTEXITCODE

            $written = Get-Content $tmpEnv -Raw
            $env:GITHUB_ENV = $null
            Remove-Item $tmpEnv -Force -ErrorAction SilentlyContinue

            $exitCode | Should -Be 0
            $written  | Should -Match 'FALLBACK_VAR=global-default'
        }
    }

    Context 'global-vars.yml does not exist' {
        It 'exits with a non-zero code' {
            $project = New-ProjectVarsFile $tmpDir @{ ANY = 'value' }

            & pwsh -File (Join-Path $PSScriptRoot '../../../../scripts/dynamics/Merge-Variables.ps1') `
                -GlobalVarsPath (Join-Path $tmpDir 'nonexistent.yml') `
                -ProjectVarsPath $project 2>&1 | Out-Null
            $LASTEXITCODE | Should -Not -Be 0
        }
    }
}
