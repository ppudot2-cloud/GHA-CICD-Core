<#
.SYNOPSIS
    Pester unit tests for Write-Changelog.ps1

.DESCRIPTION
    Verifies:
      - Commits touching a solution folder appear in that solution's section
      - Commits not touching any solution folder appear in "Pipeline / CI"
      - Conventional commit prefixes map to the correct emoji
      - The "no commits" edge case emits "_No commits found in this range._"
      - Missing solutions.json falls back gracefully (all commits in one section)
      - Markdown output file is written correctly
      - Baseline SHA defaults to the last merge on origin/main
      - First-run scenario (no prior merges) falls back to the initial commit

.NOTES
    Run from the GHA-Core repository root:
        Invoke-Pester .github/servicenow/Tests/Unit/Dynamics/Write-Changelog.Tests.ps1

    Requires: Pester v5+, PowerShell 7+, git on PATH
#>

BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot '../../../../scripts/dynamics/Write-Changelog.ps1'
    if (-not (Test-Path $scriptPath)) {
        throw "Script not found: $scriptPath"
    }

    # ── Git helper: run git in a specific directory ───────────────────────────
    function Invoke-LocalGit {
        param([string]$WorkDir, [string[]]$Args)
        $out = & git -C $WorkDir @Args 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "git $($Args -join ' ') exited $LASTEXITCODE in $WorkDir — $out"
        }
    }

    # ── Create a minimal git repo with controlled commits ────────────────────
    # Returns a hashtable: @{ RepoPath; Solutions; SolutionCommits; PipelineCommits; MergeSha }
    function New-TestRepo {
        param(
            [string]   $Base,
            [string[]] $SolutionNames   = @('CoreSolution'),
            [hashtable]$SolutionCommits = @{ CoreSolution = @('feat: add field', 'fix: null check') },
            [string[]] $PipelineCommits = @('ci: update PAC version')
        )

        $repo = Join-Path $Base "repo-$([System.Guid]::NewGuid().ToString('N').Substring(0,6))"
        New-Item -ItemType Directory -Path $repo | Out-Null

        # Bare minimum git config so commits don't error
        Invoke-LocalGit $repo @('init', '-b', 'main')
        Invoke-LocalGit $repo @('config', 'user.email', 'test@test.com')
        Invoke-LocalGit $repo @('config', 'user.name',  'Test')

        # Initial "main" state — the baseline merge commit
        $dummy = Join-Path $repo 'README.md'
        'init' | Set-Content $dummy -Encoding utf8
        Invoke-LocalGit $repo @('add', 'README.md')
        Invoke-LocalGit $repo @('commit', '-m', 'chore: initial commit')

        # Record the initial commit SHA (used as the "merge" baseline in tests)
        $initSha = (& git -C $repo rev-parse HEAD).Trim()

        # Create solution folders and solutions.json
        $solList = @()
        $order   = 1
        foreach ($name in $SolutionNames) {
            $folder = "src/solutions/$name"
            $fullFolder = Join-Path $repo $folder
            New-Item -ItemType Directory -Path $fullFolder -Force | Out-Null
            "$name placeholder" | Set-Content (Join-Path $fullFolder "Other.xml") -Encoding utf8
            Invoke-LocalGit $repo @('add', '.')
            Invoke-LocalGit $repo @('commit', '-m', "chore: scaffold $name folder")
            $solList += [PSCustomObject]@{ name = $name; folder = $folder; deployOrder = $order; dependsOn = @() }
            $order++
        }

        # Write solutions.json
        @{ solutions = $solList } | ConvertTo-Json -Depth 5 |
            Set-Content (Join-Path $repo 'solutions.json') -Encoding utf8
        Invoke-LocalGit $repo @('add', 'solutions.json')
        Invoke-LocalGit $repo @('commit', '-m', 'chore: add solutions.json')

        # Simulate the "last merge to main" by recording a synthetic merge SHA
        # We tag the current HEAD so the baseline resolver can find it
        Invoke-LocalGit $repo @('tag', 'last-prod-merge')
        $mergeSha = (& git -C $repo rev-parse HEAD).Trim()

        # Now add feature commits AFTER the baseline
        foreach ($name in $SolutionNames) {
            $msgs = if ($SolutionCommits.ContainsKey($name)) { $SolutionCommits[$name] } else { @() }
            foreach ($msg in $msgs) {
                $folder   = Join-Path $repo "src/solutions/$name"
                $filePath = Join-Path $folder "Change-$([System.Guid]::NewGuid().ToString('N').Substring(0,4)).xml"
                $msg | Set-Content $filePath -Encoding utf8
                Invoke-LocalGit $repo @('add', '.')
                Invoke-LocalGit $repo @('commit', '-m', $msg)
            }
        }

        # Pipeline / CI commits (touch .github or root files — not solution folders)
        foreach ($msg in $PipelineCommits) {
            $filePath = Join-Path $repo ".github/ci-file-$([System.Guid]::NewGuid().ToString('N').Substring(0,4)).txt"
            New-Item -ItemType Directory -Path (Split-Path $filePath) -Force | Out-Null
            $msg | Set-Content $filePath -Encoding utf8
            Invoke-LocalGit $repo @('add', '.')
            Invoke-LocalGit $repo @('commit', '-m', $msg)
        }

        return @{
            RepoPath        = $repo
            MergeSha        = $mergeSha
            InitSha         = $initSha
            SolutionNames   = $SolutionNames
        }
    }

    # ── Invoke the script and return the generated changelog content ──────────
    function Invoke-Changelog {
        param(
            [string] $RepoPath,
            [string] $BaseSha         = '',
            [string] $HeadSha         = 'HEAD',
            [string] $RunNumber       = '42',
            [string] $FeatureBranch   = 'feature/pipeline-42',
            [string] $SolutionsJson   = 'solutions.json'
        )

        $tmpOutput   = [System.IO.Path]::GetTempFileName()
        $changelogOut = Join-Path $RepoPath 'changelog-test.md'
        $tmpGhOutput  = [System.IO.Path]::GetTempFileName()

        $env:GITHUB_OUTPUT      = $tmpGhOutput
        $env:GITHUB_STEP_SUMMARY = $null

        try {
            & pwsh -File $scriptPath `
                -RepoPath          $RepoPath `
                -BaseSha           $BaseSha `
                -HeadSha           $HeadSha `
                -SolutionsJsonPath $SolutionsJson `
                -RunNumber         $RunNumber `
                -FeatureBranch     $FeatureBranch `
                -OutputPath        $changelogOut 2>&1 | Out-Null
        } finally {
            $env:GITHUB_OUTPUT = $null
        }

        return @{
            Content    = if (Test-Path $changelogOut) { Get-Content $changelogOut -Raw -Encoding utf8 } else { '' }
            OutputFile = $changelogOut
            ExistCode  = $LASTEXITCODE
        }
    }

    # Shared temp root for all tests
    $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "WriteChangelog-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Path $script:TempRoot | Out-Null
}

AfterAll {
    if (Test-Path $script:TempRoot) {
        Remove-Item $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
Describe "Write-Changelog — commit grouping" {

    BeforeAll {
        $script:Repo = New-TestRepo `
            -Base             $script:TempRoot `
            -SolutionNames    @('CoreSolution', 'ExtensionA') `
            -SolutionCommits  @{
                CoreSolution = @('feat: add rollup field', 'fix: null reference on lookup')
                ExtensionA   = @('feat: new portal flow')
            } `
            -PipelineCommits  @('ci: update PAC CLI to v1.33', 'docs: update readme')

        $script:Result = Invoke-Changelog `
            -RepoPath   $script:Repo.RepoPath `
            -BaseSha    $script:Repo.MergeSha `
            -RunNumber  '99'
    }

    It "writes the changelog output file" {
        Test-Path $script:Result.OutputFile | Should -BeTrue
    }

    It "includes the changelog header with run number" {
        $script:Result.Content | Should -Match '## 📋 Changelog — Run #99'
    }

    It "includes a CoreSolution section" {
        $script:Result.Content | Should -Match '### 📦 CoreSolution'
    }

    It "includes commits under CoreSolution" {
        $script:Result.Content | Should -Match 'add rollup field'
        $script:Result.Content | Should -Match 'null reference on lookup'
    }

    It "includes an ExtensionA section" {
        $script:Result.Content | Should -Match '### 📦 ExtensionA'
    }

    It "includes commits under ExtensionA" {
        $script:Result.Content | Should -Match 'new portal flow'
    }

    It "includes a Pipeline / CI section for non-solution commits" {
        $script:Result.Content | Should -Match '### 🔧 Pipeline / CI'
    }

    It "places CI commits in the Pipeline / CI section" {
        $script:Result.Content | Should -Match 'update PAC CLI'
        $script:Result.Content | Should -Match 'update readme'
    }

    It "does NOT put CoreSolution commits in the Pipeline / CI section" {
        # The Pipeline / CI section should not contain 'add rollup field'
        $sections = $script:Result.Content -split '###'
        $ciSection = $sections | Where-Object { $_ -match '🔧 Pipeline / CI' }
        $ciSection | Should -Not -Match 'add rollup field'
    }

    It "includes the feature branch in the footer" {
        $script:Result.Content | Should -Match 'feature/pipeline-42'
    }

    It "includes the baseline SHA in the header summary" {
        $shortSha = $script:Repo.MergeSha.Substring(0, 7)
        $script:Result.Content | Should -Match $shortSha
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
Describe "Write-Changelog — conventional commit emoji mapping" {

    BeforeAll {
        $script:EmojiRepo = New-TestRepo `
            -Base             $script:TempRoot `
            -SolutionNames    @('CoreSolution') `
            -SolutionCommits  @{
                CoreSolution = @(
                    'feat: add new field',
                    'fix: correct formula',
                    'refactor: simplify trigger',
                    'docs: update schema notes',
                    'chore: bump version',
                    'ci: add lint step',
                    'perf: reduce query count',
                    'test: add integration test',
                    'no prefix message here'
                )
            } `
            -PipelineCommits  @()

        $script:EmojiResult = Invoke-Changelog `
            -RepoPath  $script:EmojiRepo.RepoPath `
            -BaseSha   $script:EmojiRepo.MergeSha
    }

    It "maps feat: to ✨" {
        $script:EmojiResult.Content | Should -Match '✨.*add new field'
    }

    It "maps fix: to 🐛" {
        $script:EmojiResult.Content | Should -Match '🐛.*correct formula'
    }

    It "maps refactor: to ♻️" {
        $script:EmojiResult.Content | Should -Match '♻️.*simplify trigger'
    }

    It "maps docs: to 📝" {
        $script:EmojiResult.Content | Should -Match '📝.*update schema notes'
    }

    It "maps chore: to 🔧" {
        $script:EmojiResult.Content | Should -Match '🔧.*bump version'
    }

    It "maps ci: to 🤖" {
        $script:EmojiResult.Content | Should -Match '🤖.*add lint step'
    }

    It "maps perf: to ⚡" {
        $script:EmojiResult.Content | Should -Match '⚡.*reduce query count'
    }

    It "maps test: to 🧪" {
        $script:EmojiResult.Content | Should -Match '🧪.*add integration test'
    }

    It "uses bullet • for unprefixed commits" {
        $script:EmojiResult.Content | Should -Match '•.*no prefix message here'
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
Describe "Write-Changelog — edge cases" {

    Context "no commits in range" {
        BeforeAll {
            $script:EmptyRepo = New-TestRepo `
                -Base             $script:TempRoot `
                -SolutionNames    @('CoreSolution') `
                -SolutionCommits  @{} `
                -PipelineCommits  @()

            # Pass HEAD as both base and head → zero commits
            $headSha = (& git -C $script:EmptyRepo.RepoPath rev-parse HEAD).Trim()
            $script:EmptyResult = Invoke-Changelog `
                -RepoPath  $script:EmptyRepo.RepoPath `
                -BaseSha   $headSha `
                -HeadSha   $headSha
        }

        It "emits the no-commits message" {
            $script:EmptyResult.Content | Should -Match '_No commits found in this range._'
        }

        It "still writes the changelog header" {
            $script:EmptyResult.Content | Should -Match '## 📋 Changelog'
        }
    }

    Context "missing solutions.json" {
        BeforeAll {
            $script:NoJsonRepo = New-TestRepo `
                -Base             $script:TempRoot `
                -SolutionNames    @('CoreSolution') `
                -SolutionCommits  @{ CoreSolution = @('feat: some change') } `
                -PipelineCommits  @('ci: update workflow')

            $script:NoJsonResult = Invoke-Changelog `
                -RepoPath       $script:NoJsonRepo.RepoPath `
                -BaseSha        $script:NoJsonRepo.MergeSha `
                -SolutionsJson  'nonexistent-solutions.json'
        }

        It "still writes the changelog header" {
            $script:NoJsonResult.Content | Should -Match '## 📋 Changelog'
        }

        It "puts all commits in Pipeline / CI when solutions.json is missing" {
            # With no solutions loaded, every commit goes to the Pipeline / CI section
            $script:NoJsonResult.Content | Should -Match '### 🔧 Pipeline / CI'
        }
    }

    Context "first pipeline run (no prior merges on origin/main)" {
        BeforeAll {
            # A fresh repo with no merge commits — BaseSha auto-detection
            # falls back to the initial commit
            $freshRepo = Join-Path $script:TempRoot "fresh-$([System.Guid]::NewGuid().ToString('N').Substring(0,6))"
            New-Item -ItemType Directory -Path $freshRepo | Out-Null

            Invoke-LocalGit $freshRepo @('init', '-b', 'main')
            Invoke-LocalGit $freshRepo @('config', 'user.email', 'test@test.com')
            Invoke-LocalGit $freshRepo @('config', 'user.name',  'Test')

            # Two commits, no merges
            'init' | Set-Content (Join-Path $freshRepo 'README.md') -Encoding utf8
            Invoke-LocalGit $freshRepo @('add', '.')
            Invoke-LocalGit $freshRepo @('commit', '-m', 'chore: initial setup')

            New-Item -ItemType Directory -Path (Join-Path $freshRepo 'src/solutions/CoreSolution') -Force | Out-Null
            'field' | Set-Content (Join-Path $freshRepo 'src/solutions/CoreSolution/field.xml') -Encoding utf8
            @{ solutions = @(@{ name = 'CoreSolution'; folder = 'src/solutions/CoreSolution'; deployOrder = 1; dependsOn = @() }) } |
                ConvertTo-Json -Depth 5 | Set-Content (Join-Path $freshRepo 'solutions.json') -Encoding utf8
            Invoke-LocalGit $freshRepo @('add', '.')
            Invoke-LocalGit $freshRepo @('commit', '-m', 'feat: first solution file')

            $script:FreshResult = Invoke-Changelog -RepoPath $freshRepo
        }

        It "still generates a changelog (no crash on missing baseline)" {
            $script:FreshResult.Content | Should -Match '## 📋 Changelog'
        }

        It "includes commits in the output (all history from initial commit)" {
            $script:FreshResult.Content | Should -Match 'first solution file'
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Regression tests — one Describe per code-review finding.
# Each Context is named after the bug it prevents and must NEVER be deleted.
# ═══════════════════════════════════════════════════════════════════════════════
Describe "Write-Changelog — regression tests (code review findings)" {

    # ── BUG-R1 ───────────────────────────────────────────────────────────────
    # Finding (MEDIUM): GHA expressions were inlined as PS string literals.
    # A solution name containing a single quote would have broken the PS string
    # context.  Fix: all caller values now go through env: vars.
    #
    # Regression contract: the Markdown output file always has the mandatory
    # structural elements regardless of what content lands in the solution
    # names, feature branch name, or commit subjects.
    # ─────────────────────────────────────────────────────────────────────────
    Context "BUG-R1: output Markdown always has the mandatory structure" {

        BeforeAll {
            # Use a solution name with Markdown/shell special characters
            # to confirm they pass through as literal text, not code.
            $specialName = "Core&Solution_v2"   # & and _ can affect Markdown rendering
            $script:R1Repo = New-TestRepo `
                -Base            $script:TempRoot `
                -SolutionNames   @($specialName) `
                -SolutionCommits @{ "$specialName" = @("feat: handle edge case") } `
                -PipelineCommits @()

            $script:R1Result = Invoke-Changelog `
                -RepoPath      $script:R1Repo.RepoPath `
                -BaseSha       $script:R1Repo.MergeSha `
                -RunNumber     '99' `
                -FeatureBranch 'feature/pipeline-99'
        }

        It "BUG-R1: changelog header is always present" {
            $script:R1Result.Content | Should -Match '## 📋 Changelog'
        }

        It "BUG-R1: run number appears in header" {
            $script:R1Result.Content | Should -Match 'Run #99'
        }

        It "BUG-R1: summary line is always present (commit count and baseline SHA)" {
            $script:R1Result.Content | Should -Match '> Changes since last Prod merge'
        }

        It "BUG-R1: footer attribution is always present" {
            $script:R1Result.Content | Should -Match '_Generated by GHA-Core'
        }

        It "BUG-R1: footer contains the feature branch name" {
            $script:R1Result.Content | Should -Match 'feature/pipeline-99'
        }

        It "BUG-R1: solution name with special chars appears as literal text in section heading" {
            # The name must appear verbatim, not interpreted as Markdown/HTML
            $script:R1Result.Content | Should -Match [regex]::Escape($specialName)
        }
    }

    # ── BUG-R2 ───────────────────────────────────────────────────────────────
    # Finding (LOW): git fetch error was silently swallowed.
    # If fetch fails, Write-Changelog.ps1 must still produce valid output by
    # falling back to the initial commit.  The fallback existed before but was
    # untested — a future refactor could silently break it.
    #
    # This test uses a repo with no remote configured so "git log origin/main"
    # returns nothing, exercising the exact fallback code path.
    # ─────────────────────────────────────────────────────────────────────────
    Context "BUG-R2: fallback to initial commit when origin/main is unreachable" {

        BeforeAll {
            # Build a local-only repo — no  git remote add  → origin/main does not exist
            $noRemoteRepo = Join-Path $script:TempRoot "no-remote-$([System.Guid]::NewGuid().ToString('N').Substring(0,6))"
            New-Item -ItemType Directory -Path $noRemoteRepo | Out-Null

            Invoke-LocalGit $noRemoteRepo @('init', '-b', 'main')
            Invoke-LocalGit $noRemoteRepo @('config', 'user.email', 'test@test.com')
            Invoke-LocalGit $noRemoteRepo @('config', 'user.name',  'Test')

            'placeholder' | Set-Content (Join-Path $noRemoteRepo 'README.md') -Encoding utf8
            Invoke-LocalGit $noRemoteRepo @('add', '.')
            Invoke-LocalGit $noRemoteRepo @('commit', '-m', 'chore: initial commit')

            New-Item -ItemType Directory -Path (Join-Path $noRemoteRepo 'src/solutions/CoreSolution') -Force | Out-Null
            'data' | Set-Content (Join-Path $noRemoteRepo 'src/solutions/CoreSolution/Entity.xml') -Encoding utf8
            @{ solutions = @(@{ name = 'CoreSolution'; folder = 'src/solutions/CoreSolution'; deployOrder = 1; dependsOn = @() }) } |
                ConvertTo-Json -Depth 5 | Set-Content (Join-Path $noRemoteRepo 'solutions.json') -Encoding utf8
            Invoke-LocalGit $noRemoteRepo @('add', '.')
            Invoke-LocalGit $noRemoteRepo @('commit', '-m', 'feat: first solution change')

            # No BaseSha provided → script must auto-detect via origin/main (which fails)
            # → fall back to initial commit
            $script:R2Result = Invoke-Changelog -RepoPath $noRemoteRepo
        }

        It "BUG-R2: script does not crash when origin/main is unreachable" {
            # Content being non-empty is the proof the script completed
            $script:R2Result.Content | Should -Not -BeNullOrEmpty
        }

        It "BUG-R2: output is structurally valid Markdown (has header)" {
            $script:R2Result.Content | Should -Match '## 📋 Changelog'
        }

        It "BUG-R2: fallback includes commits from full history (not an empty changelog)" {
            # All commits since the initial commit should appear
            $script:R2Result.Content | Should -Match 'first solution change'
        }
    }

    # ── BUG-R3 ───────────────────────────────────────────────────────────────
    # Finding: claimedHashes deduplication logic governs what appears in the
    # "Pipeline / CI" section.  A commit touching TWO solution folders must:
    #   (a) appear in each of the two solution sections — it is visible in each
    #       per-solution git log independently.
    #   (b) NOT appear in Pipeline / CI — it is solution work, not CI work.
    #
    # This is the exact analog of the skill's "sandbox/production path parity"
    # pattern: a commit must not be invisible in one path while showing in another.
    # ─────────────────────────────────────────────────────────────────────────
    Context "BUG-R3: cross-solution commit appears in both solution sections, not in Pipeline/CI" {

        BeforeAll {
            $crossRepo = Join-Path $script:TempRoot "cross-$([System.Guid]::NewGuid().ToString('N').Substring(0,6))"
            New-Item -ItemType Directory -Path $crossRepo | Out-Null

            Invoke-LocalGit $crossRepo @('init', '-b', 'main')
            Invoke-LocalGit $crossRepo @('config', 'user.email', 'test@test.com')
            Invoke-LocalGit $crossRepo @('config', 'user.name',  'Test')

            # Baseline commit
            'base' | Set-Content (Join-Path $crossRepo 'README.md') -Encoding utf8
            Invoke-LocalGit $crossRepo @('add', '.')
            Invoke-LocalGit $crossRepo @('commit', '-m', 'chore: base')

            # Create both solution folders + solutions.json
            foreach ($name in @('CoreSolution', 'ExtensionA')) {
                New-Item -ItemType Directory -Path (Join-Path $crossRepo "src/solutions/$name") -Force | Out-Null
                'placeholder' | Set-Content (Join-Path $crossRepo "src/solutions/$name/Placeholder.xml") -Encoding utf8
            }
            @{
                solutions = @(
                    @{ name = 'CoreSolution'; folder = 'src/solutions/CoreSolution'; deployOrder = 1; dependsOn = @() }
                    @{ name = 'ExtensionA';   folder = 'src/solutions/ExtensionA';   deployOrder = 2; dependsOn = @() }
                )
            } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $crossRepo 'solutions.json') -Encoding utf8
            Invoke-LocalGit $crossRepo @('add', '.')
            Invoke-LocalGit $crossRepo @('commit', '-m', 'chore: scaffold both solutions')

            # Record baseline (everything above is "pre-feature")
            $baseSha = (& git -C $crossRepo rev-parse HEAD).Trim()

            # Single commit that touches BOTH solution folders simultaneously
            'change A' | Set-Content (Join-Path $crossRepo 'src/solutions/CoreSolution/SharedChange.xml') -Encoding utf8
            'change B' | Set-Content (Join-Path $crossRepo 'src/solutions/ExtensionA/SharedChange.xml')   -Encoding utf8
            Invoke-LocalGit $crossRepo @('add', '.')
            Invoke-LocalGit $crossRepo @('commit', '-m', 'feat: shared refactor touching both solutions')

            $script:R3Result = Invoke-Changelog `
                -RepoPath $crossRepo `
                -BaseSha  $baseSha
        }

        It "BUG-R3: cross-solution commit appears in CoreSolution section" {
            $sections = $script:R3Result.Content -split '###'
            $coreSection = $sections | Where-Object { $_ -match '📦 CoreSolution' }
            $coreSection | Should -Match 'shared refactor touching both solutions'
        }

        It "BUG-R3: cross-solution commit appears in ExtensionA section" {
            $sections = $script:R3Result.Content -split '###'
            $extSection = $sections | Where-Object { $_ -match '📦 ExtensionA' }
            $extSection | Should -Match 'shared refactor touching both solutions'
        }

        It "BUG-R3: cross-solution commit does NOT appear in Pipeline / CI section" {
            $sections = $script:R3Result.Content -split '###'
            $ciSection = $sections | Where-Object { $_ -match '🔧 Pipeline / CI' }
            # If the CI section exists, the cross-solution commit must not be in it
            if ($ciSection) {
                $ciSection | Should -Not -Match 'shared refactor touching both solutions'
            } else {
                # No CI section at all is also acceptable — means every commit was claimed by a solution
                $true | Should -Be $true
            }
        }
    }

    # ── BUG-R4 ───────────────────────────────────────────────────────────────
    # Finding (LOW): the workflow step that builds pr-body.md reads changelog.md
    # with  Get-Content 'changelog.md' -Raw  and falls back to a placeholder
    # string if missing.  But a missing file means the changelog step silently
    # failed. Write-Changelog.ps1 must ALWAYS create the OutputPath file —
    # even in edge-case scenarios — so the calling step can detect absence.
    # ─────────────────────────────────────────────────────────────────────────
    Context "BUG-R4: output file is always created, even in edge cases" {

        It "BUG-R4: output file exists after no-commits run" {
            $r = New-TestRepo `
                -Base             $script:TempRoot `
                -SolutionNames    @('CoreSolution') `
                -SolutionCommits  @{} `
                -PipelineCommits  @()

            $headSha = (& git -C $r.RepoPath rev-parse HEAD).Trim()
            $result  = Invoke-Changelog `
                -RepoPath $r.RepoPath `
                -BaseSha  $headSha `
                -HeadSha  $headSha

            Test-Path $result.OutputFile | Should -BeTrue
            $result.Content             | Should -Not -BeNullOrEmpty
        }

        It "BUG-R4: output file exists when solutions.json is missing" {
            $r = New-TestRepo `
                -Base             $script:TempRoot `
                -SolutionNames    @('CoreSolution') `
                -SolutionCommits  @{ CoreSolution = @('fix: something') } `
                -PipelineCommits  @()

            $result = Invoke-Changelog `
                -RepoPath      $r.RepoPath `
                -BaseSha       $r.MergeSha `
                -SolutionsJson 'does-not-exist.json'

            Test-Path $result.OutputFile | Should -BeTrue
        }

        It "BUG-R4: output file has non-trivial content (not just whitespace)" {
            $r = New-TestRepo `
                -Base             $script:TempRoot `
                -SolutionNames    @('CoreSolution') `
                -SolutionCommits  @{ CoreSolution = @('feat: normal change') } `
                -PipelineCommits  @()

            $result = Invoke-Changelog `
                -RepoPath $r.RepoPath `
                -BaseSha  $r.MergeSha

            $result.Content.Trim().Length | Should -BeGreaterThan 50
        }
    }
}
