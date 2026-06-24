<#
.SYNOPSIS
    Bootstraps a new project repo from GHA-CICD-Core templates.

.DESCRIPTION
    Called by onboard-project.yml. Reads templates from .github/templates/,
    substitutes tokens, pushes all files to the target repository via GitHub API,
    and opens a Pull Request with a setup checklist.

    Two operations:
      new_project  — scaffolds all pipeline files + first solution source stubs
      add_solution — adds a new solution to an existing project repo

.PARAMETER TargetRepo     org/repo of the project to onboard (must exist)
.PARAMETER Operation       new_project | add_solution
.PARAMETER SolutionName    Power Platform unique solution name
.PARAMETER DeployOrder     Deploy sequence position (1 = first)
.PARAMETER DependsOn       Comma-separated prerequisite solution names (blank = none)
.PARAMETER GhaCoreRef      GHA-CICD-Core ref to embed in generated workflows (e.g. v1, main)
.PARAMETER NotificationEmail  Email for pipeline failure notifications
.PARAMETER PublisherPrefix PP publisher prefix used in Solution.xml (default: new)
.PARAMETER TemplatesPath   Path to templates folder (default: .github/templates)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $TargetRepo,
    [Parameter(Mandatory)] [ValidateSet('new_project', 'add_solution')] [string] $Operation,
    [Parameter(Mandatory)] [string] $SolutionName,
    [string] $DeployOrder        = '1',
    [string] $DependsOn          = '',
    [string] $GhaCoreRef         = 'v1',
    [Parameter(Mandatory)] [string] $NotificationEmail,
    [string] $PublisherPrefix    = 'new',
    [string] $TemplatesPath      = '.github/templates'
)

$ErrorActionPreference = 'Stop'

$apiBase = 'https://api.github.com'
$headers = @{
    Authorization          = "Bearer $env:GH_TOKEN"
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
}

# ── Helper: call GitHub REST API ──────────────────────────────────────────────
function Invoke-GhApi {
    param([string]$Method, [string]$Path, [hashtable]$Body = $null)
    $params = @{
        Method  = $Method
        Uri     = "$apiBase$Path"
        Headers = $headers
    }
    if ($Body) {
        $params.Body        = ($Body | ConvertTo-Json -Depth 10 -Compress)
        $params.ContentType = 'application/json'
    }
    Invoke-RestMethod @params
}

# ── Helper: push a file to the target repo (create or update) ─────────────────
function Push-RepoFile {
    param([string]$FilePath, [string]$Content, [string]$CommitMessage)
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Content))
    $body = @{
        message = $CommitMessage
        content = $b64
        branch  = $script:BranchName
    }
    try {
        $existing = Invoke-GhApi 'GET' "/repos/$TargetRepo/contents/$FilePath`?ref=$script:BranchName"
        $body.sha = $existing.sha
    } catch { }
    Invoke-GhApi 'PUT' "/repos/$TargetRepo/contents/$FilePath" $body | Out-Null
    Write-Host "  ✅ $FilePath"
}

# ── Helper: expand template tokens ───────────────────────────────────────────
function Expand-Template {
    param([string]$TemplatePath, [hashtable]$Tokens)
    $content = Get-Content $TemplatePath -Raw -Encoding UTF8
    foreach ($key in $Tokens.Keys) {
        $content = $content.Replace("{{$key}}", $Tokens[$key])
    }
    return $content
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: Verify repository exists
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "Checking repository: $TargetRepo"
try {
    $repo = Invoke-GhApi 'GET' "/repos/$TargetRepo"
    Write-Host "✅ Repository found: $($repo.full_name) (default branch: $($repo.default_branch))"
} catch {
    $status = $_.Exception.Response.StatusCode.value__
    switch ($status) {
        401 { Write-Error "::error::GHATOKEN is missing or invalid (HTTP 401). Go to GHA-CICD-Core → Settings → Secrets → Actions and verify the GHATOKEN secret is set and has not expired." }
        403 { Write-Error "::error::GHATOKEN does not have permission to access '$TargetRepo' (HTTP 403). Ensure the token has 'repo' scope and that the token owner has access to this repository." }
        404 { Write-Error "::error::Repository '$TargetRepo' not found (HTTP 404). Create the repository first, then re-run this workflow." }
        default { Write-Error "::error::Unexpected error accessing '$TargetRepo' (HTTP $status). Check GHATOKEN permissions and network connectivity." }
    }
    exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Create onboarding branch in target repo
# ─────────────────────────────────────────────────────────────────────────────
$defaultBranch = $repo.default_branch
$headRef       = Invoke-GhApi 'GET' "/repos/$TargetRepo/git/ref/heads/$defaultBranch"
$headSha       = $headRef.object.sha
$date          = Get-Date -Format 'yyyyMMdd'
$script:BranchName = "onboard/$SolutionName-$date"

try {
    Invoke-GhApi 'POST' "/repos/$TargetRepo/git/refs" @{
        ref = "refs/heads/$script:BranchName"
        sha = $headSha
    } | Out-Null
    Write-Host "✅ Created branch: $script:BranchName"
} catch {
    $status = $_.Exception.Response.StatusCode.value__
    if ($status -eq 422) {
        Write-Host "⚠️  Branch '$script:BranchName' already exists — pushing to it"
    } else {
        throw
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: Prepare tokens
# ─────────────────────────────────────────────────────────────────────────────
$displayName = $SolutionName -replace '([A-Z])', ' $1' -replace '^\s', ''
$dependsOnJson = ''
if ($DependsOn.Trim()) {
    $dependsOnJson = ($DependsOn.Split(',') | ForEach-Object { '"' + $_.Trim() + '"' }) -join ', '
}

$tokens = @{
    GHA_CORE_REF        = $GhaCoreRef
    NOTIFICATION_EMAIL  = $NotificationEmail
    SOLUTION_NAME       = $SolutionName
    DEPLOY_ORDER        = $DeployOrder
    DEPENDS_ON          = $dependsOnJson
    SOLUTION_DISPLAY_NAME = $displayName
    PUBLISHER_PREFIX    = $PublisherPrefix
    PROJECT_NAME        = ($TargetRepo -split '/')[-1]
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: Push files
# ─────────────────────────────────────────────────────────────────────────────
if ($Operation -eq 'new_project') {
    Write-Host ""
    Write-Host "── Pipeline config files ────────────────────────────────────"
    Push-RepoFile '.github/config/project-vars.yml' `
        (Expand-Template "$TemplatesPath/project-vars.yml.tmpl" $tokens) `
        "chore: add project-vars.yml [onboard]"

    Push-RepoFile '.github/workflows/build-and-deploy.yml' `
        (Expand-Template "$TemplatesPath/build-and-deploy.yml.tmpl" $tokens) `
        "chore: add build-and-deploy.yml [onboard]"

    Push-RepoFile '.github/workflows/deploy-prod.yml' `
        (Expand-Template "$TemplatesPath/deploy-prod.yml.tmpl" $tokens) `
        "chore: add deploy-prod.yml [onboard]"

    Push-RepoFile '.github/workflows/export-solution.yml' `
        (Expand-Template "$TemplatesPath/export-solution.yml.tmpl" $tokens) `
        "chore: add export-solution.yml [onboard]"

    Push-RepoFile '.github/workflows/validate-setup.yml' `
        (Expand-Template "$TemplatesPath/validate-setup.yml.tmpl" $tokens) `
        "chore: add validate-setup.yml [onboard]"

    Push-RepoFile 'solutions.json' `
        (Expand-Template "$TemplatesPath/solutions.json.tmpl" $tokens) `
        "chore: add solutions.json [$SolutionName] [onboard]"
}

if ($Operation -eq 'add_solution') {
    Write-Host ""
    Write-Host "── Updating solutions.json ──────────────────────────────────"
    try {
        $existing    = Invoke-GhApi 'GET' "/repos/$TargetRepo/contents/solutions.json`?ref=$script:BranchName"
        $currentJson = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($existing.content -replace '\s', ''))
        $registry    = $currentJson | ConvertFrom-Json

        $newEntry = [pscustomobject]@{
            name          = $SolutionName
            folder        = "src/solutions/$SolutionName"
            deployOrder   = [int]$DeployOrder
            dependsOn     = @(($DependsOn.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }))
            dataSchemaFile = "src/solutions/$SolutionName/config-data-schema.xml"
            deploymentSettings = [pscustomobject]@{
                dev  = "src/solutions/$SolutionName/DeploymentSettings-Dev.json"
                intg = "src/solutions/$SolutionName/DeploymentSettings-Intg.json"
                uat  = "src/solutions/$SolutionName/DeploymentSettings-Uat.json"
                frs  = "src/solutions/$SolutionName/DeploymentSettings-Frs.json"
                perf = "src/solutions/$SolutionName/DeploymentSettings-Perf.json"
                prod = "src/solutions/$SolutionName/DeploymentSettings-Prod.json"
            }
        }

        $registry.solutions += $newEntry
        $updatedJson = $registry | ConvertTo-Json -Depth 10
        Push-RepoFile 'solutions.json' $updatedJson "chore: add $SolutionName to solutions.json [onboard]"
    } catch {
        Write-Error "::error::Failed to update solutions.json — does it exist on the $script:BranchName branch?"
        exit 1
    }
}

# ── Solution source stubs (both operations) ───────────────────────────────────
Write-Host ""
Write-Host "── Solution source stubs ────────────────────────────────────────"
$envs = @(
    @{ Title = 'Dev';  Upper = 'DEV'  }
    @{ Title = 'Intg'; Upper = 'INTG' }
    @{ Title = 'Uat';  Upper = 'UAT'  }
    @{ Title = 'Frs';  Upper = 'FRS'  }
    @{ Title = 'Perf'; Upper = 'PERF' }
    @{ Title = 'Prod'; Upper = 'PROD' }
)
foreach ($env in $envs) {
    $envTokens = $tokens + @{ ENV_TITLE = $env.Title; ENV_UPPER = $env.Upper }
    Push-RepoFile "src/solutions/$SolutionName/DeploymentSettings-$($env.Title).json" `
        (Expand-Template "$TemplatesPath/DeploymentSettings.json.tmpl" $envTokens) `
        "chore: add DeploymentSettings-$($env.Title).json [$SolutionName] [onboard]"
}
Push-RepoFile "src/solutions/$SolutionName/config-data-schema.xml" `
    (Get-Content "$TemplatesPath/config-data-schema.xml.tmpl" -Raw -Encoding UTF8) `
    "chore: add config-data-schema.xml [$SolutionName] [onboard]"
Push-RepoFile "src/solutions/$SolutionName/Other/Customizations.xml" `
    (Get-Content "$TemplatesPath/customizations.xml.tmpl" -Raw -Encoding UTF8) `
    "chore: add Customizations.xml [$SolutionName] [onboard]"
Push-RepoFile "src/solutions/$SolutionName/Other/Solution.xml" `
    (Expand-Template "$TemplatesPath/solution.xml.tmpl" $tokens) `
    "chore: add Solution.xml [$SolutionName] [onboard]"

# ─────────────────────────────────────────────────────────────────────────────
# Step 5: Create Pull Request
# ─────────────────────────────────────────────────────────────────────────────
$prTitle = if ($Operation -eq 'new_project') {
    "chore: onboard project — $SolutionName [GHA-CICD-Core $GhaCoreRef]"
} else {
    "chore: add solution $SolutionName [deploy order $DeployOrder]"
}

$fileList = if ($Operation -eq 'new_project') {
    @(
        '- `.github/config/project-vars.yml` — **update PP environment URLs before merging**'
        '- `.github/workflows/build-and-deploy.yml`'
        '- `.github/workflows/deploy-prod.yml`'
        '- `.github/workflows/export-solution.yml`'
        '- `.github/workflows/validate-setup.yml`'
        '- `solutions.json`'
        "- ``src/solutions/$SolutionName/DeploymentSettings-{Dev,Intg,Uat,Frs,Perf,Prod}.json``"
        "- ``src/solutions/$SolutionName/config-data-schema.xml``"
        "- ``src/solutions/$SolutionName/Other/Customizations.xml``"
        "- ``src/solutions/$SolutionName/Other/Solution.xml``"
    ) -join "`n"
} else {
    @(
        "- ``solutions.json`` — updated with new solution entry (deploy order $DeployOrder)"
        "- ``src/solutions/$SolutionName/DeploymentSettings-{Dev,Intg,Uat,Frs,Perf,Prod}.json``"
        "- ``src/solutions/$SolutionName/config-data-schema.xml``"
        "- ``src/solutions/$SolutionName/Other/Customizations.xml``"
        "- ``src/solutions/$SolutionName/Other/Solution.xml``"
    ) -join "`n"
}

$azureSteps = if ($Operation -eq 'new_project') {
    @"
- [ ] **Azure App Registration** — create one per project; note the Client ID
- [ ] **Azure Federated Credentials** — add one per GitHub Environment with exact subjects:
  - ``repo:$TargetRepo:environment:Dev``
  - ``repo:$TargetRepo:environment:Intg``
  - ``repo:$TargetRepo:environment:UAT``
  - ``repo:$TargetRepo:environment:FRS``
  - ``repo:$TargetRepo:environment:Perf``
  - ``repo:$TargetRepo:environment:Prod``
- [ ] **Azure Key Vault** — create one, add IAM role ``Key Vault Secrets User`` to the App Registration, then add secrets:
  - ``PP-APP-ID`` = your App Registration Application (Client) ID
  - ``PP-CLIENT-SECRET`` = a client secret from the App Registration
  - ``PP-TENANT-ID`` = your Azure AD Tenant ID
- [ ] **GitHub Environments** — create: Dev, Intg, UAT, FRS, Perf, Prod (Settings → Environments)
  - Add required reviewers on Intg, UAT, FRS, Perf, Prod for approval gates
- [ ] **GitHub Variables** (Settings → Secrets and variables → Actions → Variables):
  - ``AZURE_CLIENT_ID``, ``AZURE_TENANT_ID``, ``AZURE_SUBSCRIPTION_ID``, ``AZURE_KEY_VAULT_NAME``
  - PP environment URLs are already in ``.github/config/project-vars.yml`` (update to real values)
- [ ] **GitHub Secrets**: ``GHATOKEN`` — PAT with ``repo`` scope on this repo and GHA-CICD-Core
"@
} else {
    '- [ ] Verify `deploy_order` and `depends_on` in solutions.json are correct for the pipeline sequence'
}

$prBody = @"
## $prTitle

Generated by ``GHA-CICD-Core / onboard-project.yml`` | GHA-CICD-Core ref: ``$GhaCoreRef``

### Files added
$fileList

---

### Setup checklist

#### 1. Update configuration (do before merging)
- [ ] **``.github/config/project-vars.yml``** — replace ``cicd-*`` placeholder URLs with actual Power Platform environment URLs
- [ ] **``src/solutions/$SolutionName/DeploymentSettings-*.json``** — update ``EnvironmentVariables`` and ``ConnectionReferences`` with real values for each environment

#### 2. Azure & GitHub setup (one-time, do before running the pipeline)
$azureSteps

#### 3. Verify the setup
- [ ] **Merge this PR**
- [ ] Run **validate-setup.yml** (Actions → Validate Setup → Run workflow) — confirms OIDC + Key Vault works for all environments
- [ ] Run **export-solution.yml** with ``mock_deploy=true`` — dry-run validates source structure without touching Dataverse
- [ ] Run **build-and-deploy.yml** with ``mock_deploy=true`` — first full pipeline smoke test

---
> Onboarded by @$env:GITHUB_ACTOR on $(Get-Date -Format 'yyyy-MM-dd')
"@

Write-Host ""
Write-Host "── Creating Pull Request ─────────────────────────────────────────"
$pr = Invoke-GhApi 'POST' "/repos/$TargetRepo/pulls" @{
    title = $prTitle
    body  = $prBody
    head  = $script:BranchName
    base  = $defaultBranch
}
Write-Host "✅ Pull Request created: $($pr.html_url)"

"pr_url=$($pr.html_url)"     | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
"branch=$script:BranchName"  | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append

Write-Host ""
Write-Host "🎉 Onboarding complete!"
Write-Host "   PR    : $($pr.html_url)"
Write-Host "   Branch: $script:BranchName"
Write-Host "   Next  : Follow the checklist in the PR description"
