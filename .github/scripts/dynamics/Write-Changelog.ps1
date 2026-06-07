#Requires -Version 7
<#
.SYNOPSIS
    Generate a Markdown changelog from git log between two commits, grouped by solution.

.DESCRIPTION
    Reads solutions.json to enumerate known solutions and their source folders.
    For each solution, runs  git log --oneline <base>..<head> -- <folder>  to collect
    commits that touch that solution's files.
    Commits that do NOT touch any solution folder appear in a "Pipeline / CI" section.
    Outputs a Markdown string suitable for injection into a GitHub PR body.

    Baseline SHA strategy (in order of preference):
      1. Explicit -BaseSha parameter.
      2. Last merge commit on origin/main  (git log --merges -n 1 origin/main).
      3. Repository initial commit         (first-run, no prior merges).

.PARAMETER BaseSha
    Exclusive lower-bound commit SHA. If empty, auto-detected from origin/main.

.PARAMETER HeadSha
    Inclusive upper-bound commit SHA or branch ref. Defaults to HEAD.

.PARAMETER SolutionsJsonPath
    Path to solutions.json (relative to RepoPath). Falls back gracefully if missing.

.PARAMETER RunNumber
    GitHub Actions run number — shown in the changelog header.

.PARAMETER FeatureBranch
    Feature branch name — shown in the changelog footer.

.PARAMETER OutputPath
    If set, the Markdown is also written to this file path (UTF-8, no BOM).
    The script always writes to $env:GITHUB_STEP_SUMMARY when that variable is set.

.PARAMETER RepoPath
    Filesystem path to the git repository. Defaults to current directory.

.OUTPUTS
    Writes Markdown to stdout.
    Writes the file at OutputPath (when specified).
    Appends to GITHUB_STEP_SUMMARY (when env var is set).
    Writes  changelog_path=<OutputPath>  to GITHUB_OUTPUT (when env var is set).

.EXAMPLE
    # Called from a GitHub Actions step after checking out the caller repo at '.'
    & .ci/.github/scripts/dynamics/Write-Changelog.ps1 `
        -SolutionsJsonPath 'solutions.json' `
        -RunNumber         '42' `
        -FeatureBranch     'feature/pipeline-42' `
        -OutputPath        'changelog.md'
#>
[CmdletBinding()]
param(
    [string] $BaseSha           = '',
    [string] $HeadSha           = 'HEAD',
    [string] $SolutionsJsonPath = 'solutions.json',
    [string] $RunNumber         = '',
    [string] $FeatureBranch     = '',
    [string] $OutputPath        = 'changelog.md',
    [string] $RepoPath          = '.'
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

# ── Helper: run git command in RepoPath, return output lines ──────────────────
function Invoke-Git {
    [OutputType([string[]])]
    param([string[]] $GitArgs)

    $out = & git -C $RepoPath @GitArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "::warning::git $($GitArgs -join ' ') → exit $LASTEXITCODE : $out"
        return @()
    }
    return @($out | Where-Object { $_ -and $_.ToString().Trim() })
}

# ── Helper: map a conventional commit subject to an emoji ────────────────────
function Get-CommitEmoji {
    param([string] $Subject)
    $prefixMap = [ordered]@{
        'feat'     = '✨'
        'fix'      = '🐛'
        'refactor' = '♻️'
        'perf'     = '⚡'
        'test'     = '🧪'
        'docs'     = '📝'
        'ci'       = '🤖'
        'build'    = '📦'
        'chore'    = '🔧'
        'style'    = '💄'
        'revert'   = '⏪'
    }
    foreach ($type in $prefixMap.Keys) {
        if ($Subject -match "^$type(\([^)]+\))?[!]?:") {
            return $prefixMap[$type]
        }
    }
    return '•'
}

# ── Helper: format a single "git log --oneline" line as a Markdown list item ──
function Format-CommitLine {
    param([string] $OneLine)
    # git --oneline format: "<short-sha> <subject>"
    if ($OneLine -match '^([0-9a-f]{6,})\s+(.+)$') {
        $sha     = $Matches[1].Substring(0, [Math]::Min(7, $Matches[1].Length))
        $subject = $Matches[2].Trim()
        $emoji   = Get-CommitEmoji $subject
        return "- $emoji ``$sha`` $subject"
    }
    return "- $($OneLine.Trim())"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Step 1 — Resolve baseline SHA
# ═══════════════════════════════════════════════════════════════════════════════
if (-not $BaseSha) {
    # Prefer the last merge commit on origin/main — that marks the previous release
    $mergeLog = Invoke-Git @('log', '--merges', '--format=%H', '-n', '1', 'origin/main')
    if ($mergeLog.Count -gt 0 -and $mergeLog[0]) {
        $BaseSha = $mergeLog[0].Trim()
        Write-Host "ℹ️  Baseline: last merge on origin/main → $($BaseSha.Substring(0, 7))"
    } else {
        # First pipeline run ever — include all history from the initial commit
        $rootLog = Invoke-Git @('rev-list', '--max-parents=0', 'HEAD')
        if ($rootLog.Count -gt 0 -and $rootLog[0]) {
            $BaseSha = $rootLog[0].Trim()
            Write-Host "ℹ️  No prior merges found — baseline: initial commit $($BaseSha.Substring(0, 7))"
        } else {
            Write-Host "::warning::Could not determine a baseline commit — changelog may be empty."
            $BaseSha = ''
        }
    }
}

$baseShort = if ($BaseSha.Length -ge 7) { $BaseSha.Substring(0, 7) } else { $BaseSha }
$range     = if ($BaseSha) { "$BaseSha..$HeadSha" } else { $HeadSha }

Write-Host "📋 Generating changelog: $($baseShort ? $baseShort : '(all)') → $HeadSha"

# ═══════════════════════════════════════════════════════════════════════════════
# Step 2 — Load solutions.json
# ═══════════════════════════════════════════════════════════════════════════════
$solutions = @()
$solJsonFull = Join-Path $RepoPath $SolutionsJsonPath
if (Test-Path $solJsonFull) {
    try {
        $reg = Get-Content $solJsonFull -Raw -Encoding utf8 | ConvertFrom-Json
        $solutions = @($reg.solutions | Sort-Object deployOrder)
        Write-Host "✅ Loaded $($solutions.Count) solution(s) from $SolutionsJsonPath"
    } catch {
        Write-Host "::warning::Could not parse $SolutionsJsonPath — all commits will appear in one section. Error: $_"
    }
} else {
    Write-Host "::warning::$SolutionsJsonPath not found — all commits will appear in one section."
}

# ═══════════════════════════════════════════════════════════════════════════════
# Step 3 — Collect all commits in range (for the "Pipeline / CI" residual)
# ═══════════════════════════════════════════════════════════════════════════════
$allCommitLines = Invoke-Git @('log', '--oneline', $range)
$totalCommits   = $allCommitLines.Count

# Build a set of short SHAs that belong to at least one solution section
$claimedHashes  = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

# ═══════════════════════════════════════════════════════════════════════════════
# Step 4 — Build per-solution commit lists
# ═══════════════════════════════════════════════════════════════════════════════
$solutionSections = [System.Collections.Generic.List[hashtable]]::new()

foreach ($sol in $solutions) {
    $folder = if ($sol.PSObject.Properties['folder'] -and $sol.folder) {
        $sol.folder
    } else {
        "src/solutions/$($sol.name)"
    }

    $commits = Invoke-Git @('log', '--oneline', $range, '--', $folder)

    if ($commits.Count -gt 0) {
        $formatted = @($commits | ForEach-Object { Format-CommitLine $_ })
        $solutionSections.Add(@{
            Name    = $sol.name
            Commits = $formatted
            Count   = $commits.Count
        })

        # Mark these SHAs as claimed so they don't appear in "Pipeline / CI"
        foreach ($line in $commits) {
            if ($line -match '^([0-9a-f]+)\s') {
                [void] $claimedHashes.Add($Matches[1])
            }
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Step 5 — Pipeline / CI residual (commits not touching any solution folder)
# ═══════════════════════════════════════════════════════════════════════════════
$pipelineCommits = @($allCommitLines | Where-Object {
    if ($_ -match '^([0-9a-f]+)\s') { -not $claimedHashes.Contains($Matches[1]) }
    else { $true }
})

# ═══════════════════════════════════════════════════════════════════════════════
# Step 6 — Build Markdown
# ═══════════════════════════════════════════════════════════════════════════════
$changedSols   = $solutionSections.Count
$runLabel      = if ($RunNumber)     { " — Run #$RunNumber" }          else { '' }
$branchLabel   = if ($FeatureBranch) { [char]0x60 + $FeatureBranch + [char]0x60 } else { 'feature branch' }

$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine("## 📋 Changelog$runLabel")
[void]$sb.AppendLine("")
if ($baseShort) {
    [void]$sb.AppendLine("> Changes since last Prod merge ``$baseShort`` · $totalCommits commit$(if ($totalCommits -ne 1) { 's' }) across $changedSols solution$(if ($changedSols -ne 1) { 's' })")
} else {
    [void]$sb.AppendLine("> $totalCommits commit$(if ($totalCommits -ne 1) { 's' }) across $changedSols solution$(if ($changedSols -ne 1) { 's' })")
}
[void]$sb.AppendLine("")

if ($solutionSections.Count -eq 0 -and $pipelineCommits.Count -eq 0) {
    [void]$sb.AppendLine("_No commits found in this range._")
    [void]$sb.AppendLine("")
} else {
    # Per-solution sections (in deployOrder — already sorted)
    foreach ($section in $solutionSections) {
        [void]$sb.AppendLine("### 📦 $($section.Name)")
        [void]$sb.AppendLine("")
        foreach ($line in $section.Commits) {
            [void]$sb.AppendLine($line)
        }
        [void]$sb.AppendLine("")
    }

    # Pipeline / CI section (commits not touching any solution)
    if ($pipelineCommits.Count -gt 0) {
        [void]$sb.AppendLine("### 🔧 Pipeline / CI")
        [void]$sb.AppendLine("")
        foreach ($line in $pipelineCommits) {
            [void]$sb.AppendLine((Format-CommitLine $line))
        }
        [void]$sb.AppendLine("")
    }
}

[void]$sb.AppendLine("---")
[void]$sb.Append("_Generated by GHA-Core · $branchLabel_")

$markdown = $sb.ToString()

# ═══════════════════════════════════════════════════════════════════════════════
# Step 7 — Write outputs
# ═══════════════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host $markdown
Write-Host ""

# File output
if ($OutputPath) {
    $markdown | Out-File -FilePath $OutputPath -Encoding utf8 -NoNewline
    Write-Host "✅ Changelog written to $OutputPath"
}

# GitHub Step Summary
if ($env:GITHUB_STEP_SUMMARY) {
    $markdown | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
}

# GITHUB_OUTPUT: expose the file path for downstream steps
if ($env:GITHUB_OUTPUT -and $OutputPath) {
    "changelog_path=$OutputPath" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
    Write-Host "✅ changelog_path=$OutputPath written to GITHUB_OUTPUT"
}

Write-Host "📋 Changelog: $totalCommits commits · $changedSols solutions changed"
