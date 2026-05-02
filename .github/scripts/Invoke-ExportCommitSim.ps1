<#
.SYNOPSIS
    Simulates the git commit/push and PR creation steps in mock_deploy mode.

.DESCRIPTION
    Runs 'git add --all' and 'git diff --cached --stat' to show what would be
    committed, then prints the commit message and PR details without pushing
    or calling 'gh pr create'.

.PARAMETER SolutionName
    Unique solution name (used in commit message).

.PARAMETER BranchName
    Target branch name.

.PARAMETER CommitMessagePrefix
    The commit message prefix from workflow input.

.PARAMETER CreatePr
    Whether a PR would have been created.
#>
param(
    [Parameter(Mandatory)][string] $SolutionName,
    [Parameter(Mandatory)][string] $BranchName,
    [string] $CommitMessagePrefix = 'chore: export solution(s) from sandbox',
    [bool]   $CreatePr            = $true
)

$ErrorActionPreference = 'Stop'

# Stage all changes to show diff
git add --all 2>&1 | Write-Host

$diff = git diff --cached --stat 2>&1
$commitMsg = "$CommitMessagePrefix [$SolutionName] $(Get-Date -Format 'yyyy-MM-dd')"

@"
## 🧪 Git Commit — Dry Run ($SolutionName)
_mock_deploy=true — no changes pushed_

**Would commit message:** ``$commitMsg``
**Target branch:** ``$BranchName``

### Files that would be committed:
``````
$($diff -join "`n")
``````
"@ | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append

Write-Host "::notice::Commit DRY RUN — $($diff.Count) change(s) staged but not pushed."

if ($CreatePr) {
    $prTitle = "chore: export $SolutionName from sandbox"
    $prBody  = @"
## Auto-generated Export PR

**Solution:** $SolutionName
**Branch:** $BranchName
**Mode:** mock_deploy simulation (no actual changes pushed)

### What would be included:
$($diff -join "`n")

> This PR was simulated in mock_deploy mode. Re-run without mock_deploy=true to create a real PR.
"@

    @"

## 🧪 PR Creation — Simulated
| Field | Value |
| --- | --- |
| Title | $prTitle |
| Head branch | ``$BranchName`` |
| Base branch | ``main`` |

**PR Body preview:**
``````
$prBody
``````
"@ | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append

    Write-Host "::notice::PR creation SIMULATED. Re-run without mock_deploy=true to open a real PR."
}
