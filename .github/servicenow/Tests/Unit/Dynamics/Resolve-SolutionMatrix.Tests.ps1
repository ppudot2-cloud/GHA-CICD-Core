<#
.SYNOPSIS
    Pester unit tests for Resolve-SolutionMatrix.ps1

.DESCRIPTION
    Verifies:
      - "all" selects every solution from solutions.json
      - Comma-separated subset selects only named solutions
      - Topological order follows deployOrder (not alphabetical)
      - Unknown solution name in subset → exits non-zero
      - Filesystem fallback when solutions.json is absent
      - PP_SOLUTION_NAME fallback when neither solutions.json nor src/ exists
      - Matrix JSON is valid and contains only { solution: name } items
      - GITHUB_OUTPUT receives matrix, solution_list, solution_count

.NOTES
    Run from the GHA-Core repository root:
        Invoke-Pester .github/servicenow/Tests/Unit/Dynamics/Resolve-SolutionMatrix.Tests.ps1

    Requires: Pester v5+, PowerShell 7+
#>

BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot '../../../../scripts/dynamics/Resolve-SolutionMatrix.ps1'
    if (-not (Test-Path $scriptPath)) {
        throw "Script not found: $scriptPath"
    }

    # Helper — write solutions.json in a temp dir and return the path
    function New-SolutionsJson([string]$Dir, [object[]]$Solutions) {
        $json = @{ solutions = $Solutions } | ConvertTo-Json -Depth 5
        $path = Join-Path $Dir 'solutions.json'
        $json | Set-Content $path -Encoding utf8
        return $path
    }

    # Helper — capture GITHUB_OUTPUT key/value pairs as a hashtable
    function Get-OutputVars([string]$OutputFile) {
        $ht = @{}
        if (Test-Path $OutputFile) {
            Get-Content $OutputFile | ForEach-Object {
                if ($_ -match '^([^=]+)=(.*)$') { $ht[$Matches[1]] = $Matches[2] }
            }
        }
        return $ht
    }

    # Helper — invoke the script with a specific working directory
    function Invoke-ResolveMatrix([string]$WorkDir, [string]$InputSolutions = 'all', [string]$PpSolutionName = '') {
        $tmpOutput = [System.IO.Path]::GetTempFileName()
        Push-Location $WorkDir
        try {
            $env:GITHUB_OUTPUT = $tmpOutput
            & pwsh -File $scriptPath `
                -InputSolutions $InputSolutions `
                -PpSolutionName $PpSolutionName 2>&1 | Out-Null
        } finally {
            Pop-Location
            $env:GITHUB_OUTPUT = $null
        }
        return $tmpOutput
    }
}

Describe 'Resolve-SolutionMatrix — solutions.json source' {
    BeforeEach {
        $tmpDir = [System.IO.Path]::GetTempPath() + [System.Guid]::NewGuid().ToString()
        New-Item -ItemType Directory -Path $tmpDir | Out-Null
    }

    AfterEach {
        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context '"all" selects every solution' {
        It 'solution_count matches the registry' {
            New-SolutionsJson $tmpDir @(
                @{ name = 'Alpha'; deployOrder = 1 }
                @{ name = 'Beta';  deployOrder = 2 }
                @{ name = 'Gamma'; deployOrder = 3 }
            ) | Out-Null

            $outFile = Invoke-ResolveMatrix $tmpDir 'all'
            $vars = Get-OutputVars $outFile
            Remove-Item $outFile -Force -ErrorAction SilentlyContinue

            $vars['solution_count'] | Should -Be '3'
        }

        It 'matrix JSON is valid and contains all solution names' {
            New-SolutionsJson $tmpDir @(
                @{ name = 'CoreSolution';      deployOrder = 1 }
                @{ name = 'ExtensionSolution'; deployOrder = 2 }
            ) | Out-Null

            $outFile = Invoke-ResolveMatrix $tmpDir 'all'
            $vars    = Get-OutputVars $outFile
            Remove-Item $outFile -Force -ErrorAction SilentlyContinue

            $matrix = $vars['matrix'] | ConvertFrom-Json
            $names  = $matrix.include | ForEach-Object { $_.solution }
            $names  | Should -Contain 'CoreSolution'
            $names  | Should -Contain 'ExtensionSolution'
        }
    }

    Context 'deployOrder controls sequence' {
        It 'solutions are ordered by deployOrder ascending' {
            New-SolutionsJson $tmpDir @(
                @{ name = 'Zebra';  deployOrder = 3 }
                @{ name = 'Alpha';  deployOrder = 1 }
                @{ name = 'Middle'; deployOrder = 2 }
            ) | Out-Null

            $outFile = Invoke-ResolveMatrix $tmpDir 'all'
            $vars    = Get-OutputVars $outFile
            Remove-Item $outFile -Force -ErrorAction SilentlyContinue

            $matrix = $vars['matrix'] | ConvertFrom-Json
            $names  = $matrix.include | ForEach-Object { $_.solution }
            $names[0] | Should -Be 'Alpha'
            $names[1] | Should -Be 'Middle'
            $names[2] | Should -Be 'Zebra'
        }
    }

    Context 'Comma-separated subset selection' {
        It 'selects only the named solutions' {
            New-SolutionsJson $tmpDir @(
                @{ name = 'Alpha'; deployOrder = 1 }
                @{ name = 'Beta';  deployOrder = 2 }
                @{ name = 'Gamma'; deployOrder = 3 }
            ) | Out-Null

            $outFile = Invoke-ResolveMatrix $tmpDir 'Alpha,Gamma'
            $vars    = Get-OutputVars $outFile
            Remove-Item $outFile -Force -ErrorAction SilentlyContinue

            $matrix = $vars['matrix'] | ConvertFrom-Json
            $names  = $matrix.include | ForEach-Object { $_.solution }
            $names  | Should -Contain 'Alpha'
            $names  | Should -Contain 'Gamma'
            $names  | Should -Not -Contain 'Beta'
            $vars['solution_count'] | Should -Be '2'
        }
    }

    Context 'Unknown solution name in subset' {
        It 'exits with a non-zero code' {
            New-SolutionsJson $tmpDir @(
                @{ name = 'Alpha'; deployOrder = 1 }
            ) | Out-Null

            $tmpOutput = [System.IO.Path]::GetTempFileName()
            Push-Location $tmpDir
            try {
                $env:GITHUB_OUTPUT = $tmpOutput
                & pwsh -File $scriptPath -InputSolutions 'NonExistentSolution' 2>&1 | Out-Null
                $exitCode = $LASTEXITCODE
            } finally {
                Pop-Location
                $env:GITHUB_OUTPUT = $null
                Remove-Item $tmpOutput -Force -ErrorAction SilentlyContinue
            }
            $exitCode | Should -Not -Be 0
        }
    }
}

Describe 'Resolve-SolutionMatrix — filesystem fallback' {
    BeforeEach {
        $tmpDir = [System.IO.Path]::GetTempPath() + [System.Guid]::NewGuid().ToString()
        New-Item -ItemType Directory -Path $tmpDir | Out-Null
        # Create src/solutions/ with two solution directories
        New-Item -ItemType Directory -Path (Join-Path $tmpDir 'src/solutions/SolutionA') | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $tmpDir 'src/solutions/SolutionB') | Out-Null
    }

    AfterEach {
        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'No solutions.json present' {
        It 'discovers solutions from src/solutions/ directory' {
            $outFile = Invoke-ResolveMatrix $tmpDir 'all'
            $vars    = Get-OutputVars $outFile
            Remove-Item $outFile -Force -ErrorAction SilentlyContinue

            [int]$vars['solution_count'] | Should -BeGreaterThan 0
        }

        It 'includes discovered solutions in the matrix' {
            $outFile = Invoke-ResolveMatrix $tmpDir 'all'
            $vars    = Get-OutputVars $outFile
            Remove-Item $outFile -Force -ErrorAction SilentlyContinue

            $matrix = $vars['matrix'] | ConvertFrom-Json
            $names  = $matrix.include | ForEach-Object { $_.solution }
            $names  | Should -Contain 'SolutionA'
            $names  | Should -Contain 'SolutionB'
        }
    }
}

Describe 'Resolve-SolutionMatrix — PP_SOLUTION_NAME fallback' {
    BeforeEach {
        $tmpDir = [System.IO.Path]::GetTempPath() + [System.Guid]::NewGuid().ToString()
        New-Item -ItemType Directory -Path $tmpDir | Out-Null
        # No solutions.json, no src/solutions/
    }

    AfterEach {
        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'PP_SOLUTION_NAME is provided when no other source exists' {
        It 'uses PP_SOLUTION_NAME as the single solution' {
            $outFile = Invoke-ResolveMatrix $tmpDir 'all' 'MySingleSolution'
            $vars    = Get-OutputVars $outFile
            Remove-Item $outFile -Force -ErrorAction SilentlyContinue

            $vars['solution_count'] | Should -Be '1'
            $vars['solution_list']  | Should -Match 'MySingleSolution'
        }
    }
}

Describe 'Resolve-SolutionMatrix — no solutions anywhere' {
    BeforeEach {
        $tmpDir = [System.IO.Path]::GetTempPath() + [System.Guid]::NewGuid().ToString()
        New-Item -ItemType Directory -Path $tmpDir | Out-Null
    }

    AfterEach {
        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'No solutions.json, no src/solutions/, no PP_SOLUTION_NAME' {
        It 'exits with a non-zero code' {
            $tmpOutput = [System.IO.Path]::GetTempFileName()
            Push-Location $tmpDir
            try {
                $env:GITHUB_OUTPUT = $tmpOutput
                & pwsh -File $scriptPath -InputSolutions 'all' -PpSolutionName '' 2>&1 | Out-Null
                $exitCode = $LASTEXITCODE
            } finally {
                Pop-Location
                $env:GITHUB_OUTPUT = $null
                Remove-Item $tmpOutput -Force -ErrorAction SilentlyContinue
            }
            $exitCode | Should -Not -Be 0
        }
    }
}
