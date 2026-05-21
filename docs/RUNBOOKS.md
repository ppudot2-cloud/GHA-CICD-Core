# Runbooks — GHA-Core + GHA-Dynamics Pipeline Operations

> **Audience:** Platform engineers and release managers who operate the Power Platform CI/CD pipeline.
> **Use this when:** A pipeline is stuck, a deployment failed, an environment needs emergency attention, or a credential must be rotated urgently.

---

## Table of Contents

1. [Quick Reference — What Is Failing?](#1-quick-reference--what-is-failing)
2. [Cancel a Stuck or Hung Pipeline Run](#2-cancel-a-stuck-or-hung-pipeline-run)
3. [Manual Rollback — Restore a Previous Solution Version](#3-manual-rollback--restore-a-previous-solution-version)
4. [ServiceNow Change Request Recovery](#4-servicenow-change-request-recovery)
5. [Break-Glass Emergency Production Deploy](#5-break-glass-emergency-production-deploy)
6. [Dataverse Blocking Operations — Force-Proceed](#6-dataverse-blocking-operations--force-proceed)
7. [Version Mismatch — Override Version Compare](#7-version-mismatch--override-version-compare)
8. [JFrog Artifactory Unavailable](#8-jfrog-artifactory-unavailable)
9. [Credential Rotation — GHA_CORE_PAT](#9-credential-rotation--gha_core_pat)
10. [Credential Rotation — Power Platform Service Principal](#10-credential-rotation--power-platform-service-principal)
11. [Feature Branch Cleanup After Failed Pipeline](#11-feature-branch-cleanup-after-failed-pipeline)
12. [Onboard a New GHA-Dynamics Project](#12-onboard-a-new-gha-dynamics-project)
13. [Restore a Deleted or Corrupted Environment](#13-restore-a-deleted-or-corrupted-environment)
14. [GitHub Actions Runner Diagnostics](#14-github-actions-runner-diagnostics)

---

## 1. Quick Reference — What Is Failing?

Use this table to jump directly to the relevant runbook.

| Symptom | Runbook |
|---|---|
| Pipeline job has been "In progress" for > 2 hours | [§2 Cancel a Stuck Run](#2-cancel-a-stuck-or-hung-pipeline-run) |
| ServiceNow approval polling never completes | [§4 ServiceNow CR Recovery](#4-servicenow-change-request-recovery) |
| Import failed, environment is in broken state | [§3 Manual Rollback](#3-manual-rollback--restore-a-previous-solution-version) |
| Need to deploy to Prod right now, bypassing normal gates | [§5 Break-Glass Deploy](#5-break-glass-emergency-production-deploy) |
| Pre-deploy check says "blocking async operations" | [§6 Blocking Operations](#6-dataverse-blocking-operations--force-proceed) |
| Version compare says version is N/A or wrong environment | [§7 Version Override](#7-version-mismatch--override-version-compare) |
| JFrog is unreachable, pipeline cannot upload/download | [§8 JFrog Unavailable](#8-jfrog-artifactory-unavailable) |
| `GHA_CORE_PAT` expired, checkout steps failing | [§9 Rotate GHA_CORE_PAT](#9-credential-rotation--gha_core_pat) |
| `pp-client-secret` expired, PAC CLI auth failing | [§10 Rotate PP Service Principal](#10-credential-rotation--power-platform-service-principal) |
| Orphaned `feature/pipeline-*` branches after cancelled run | [§11 Feature Branch Cleanup](#11-feature-branch-cleanup-after-failed-pipeline) |
| Need to add a new Power Platform project | [§12 Onboard New Project](#12-onboard-a-new-gha-dynamics-project) |

---

## 2. Cancel a Stuck or Hung Pipeline Run

### When to use
A job has been running for an unexpectedly long time. Common causes:
- ServiceNow approval polling waiting indefinitely (SNOW outage or missed notification)
- A PAC CLI import waiting on a Dataverse timeout
- A runner VM that silently lost connectivity

### Steps

**Option A — GitHub UI**

1. Go to **GHA-Dynamics → Actions**
2. Find the in-progress run
3. Click **Cancel workflow** (top right of the run detail page)
4. Confirm cancellation
5. If the run has a ServiceNow CR open (check the job logs for a `CHG#` number), follow [§4.3 Force-Close a CR](#43-force-close-a-cr-when-pipeline-cannot-close-it)

**Option B — GitHub CLI**

```bash
# List recent in-progress runs
gh run list --repo YOUR_ORG/GHA-Dynamics --status in_progress

# Cancel by run ID
gh run cancel RUN_ID --repo YOUR_ORG/GHA-Dynamics
```

**After cancellation**

- Check the target environment. If the import was mid-flight, the Dataverse solution may be in an inconsistent state. Run a quick manual check:

```bash
pac auth create --url https://yourorg-env.crm.dynamics.com --applicationId $PP_APP_ID --clientSecret $PP_CLIENT_SECRET --tenant $PP_TENANT_ID
pac solution list
```

- If the solution is listed but in a "Pending" or "Installed" state with an older version, proceed to [§3 Manual Rollback](#3-manual-rollback--restore-a-previous-solution-version).

---

## 3. Manual Rollback — Restore a Previous Solution Version

### When to use
- Automatic rollback did not trigger (e.g., first-time install that failed, or `enable_backup=false`)
- Automatic rollback itself failed (check logs for the backup re-import step)
- You need to roll back to a version older than the most recent backup

### Prerequisites
- PAC CLI installed (`pac install latest`)
- Power Platform service principal credentials (`PP_APP_ID`, `PP_CLIENT_SECRET`, `PP_TENANT_ID`) from AKV
- The target environment URL

### 3.1 Automatic Rollback Backup (First Choice)

If `enable_backup=true` was set for the run, the pipeline uploaded a `backup-{env}-v{run_number}` GitHub artifact (30-day retention).

1. Go to **GHA-Dynamics → Actions → [the failed run]**
2. Scroll to **Artifacts** at the bottom
3. Download `backup-{env}-v{run_number}.zip`
4. Unzip — you will find `backup/{solution_name}_{env}_backup.zip`

Then import using PAC CLI:

```bash
pac auth create \
  --url https://yourorg-env.crm.dynamics.com \
  --applicationId $PP_APP_ID \
  --clientSecret $PP_CLIENT_SECRET \
  --tenant $PP_TENANT_ID

pac solution import \
  --path ./backup/CoreSolution_prod_backup.zip \
  --managed \
  --force-overwrite \
  --publish-changes
```

### 3.2 Rollback from JFrog Artifactory (Second Choice)

JFrog holds all uploaded artifacts indefinitely. Use this if the GitHub artifact has expired (> 30 days) or if you need a specific historical version.

1. Log into JFrog: `https://yourorg.jfrog.io/artifactory`
2. Navigate to the `powerplatform-solutions` repository
3. Find the artifact: `{solution_name}/run{run_number}/attempt{run_attempt}/{solution_name}-run{N}-a{A}-managed.zip`
4. Download it, or use the JFrog API:

```bash
curl -H "X-JFrog-Art-Api: $JFROG_TOKEN" \
  -o CoreSolution-managed.zip \
  "https://yourorg.jfrog.io/artifactory/powerplatform-solutions/CoreSolution/run42/attempt1/CoreSolution-run42-a1-managed.zip"
```

5. Import with PAC CLI as shown in §3.1.

### 3.3 To search for the last production-deployed artifact in JFrog

```bash
curl -H "X-JFrog-Art-Api: $JFROG_TOKEN" \
  "https://yourorg.jfrog.io/artifactory/api/search/prop?prodDeployed=true&solution.name=CoreSolution"
```

This returns the artifact with `prodDeployed=true`, which is the one that last successfully deployed to production.

### Post-Rollback Steps

1. Verify the correct version is now installed:

```bash
pac solution list
```

2. If ServiceNow is enabled on the environment, open a manual change request in SNOW documenting the emergency rollback.
3. Notify affected teams.
4. Investigate root cause before attempting to redeploy.

---

## 4. ServiceNow Change Request Recovery

### 4.1 Approval Polling Times Out

**Symptoms:** The `servicenow-change (pre-deploy)` step has been running for an extended time. The CR is open in ServiceNow but no approval has come through.

**Diagnosis:**
1. Check the ServiceNow instance for the CR (the `CHG#` number is in the job logs)
2. Verify the assignment group has received the approval request
3. Check for a SNOW outage: `https://yourorg.service-now.com/stats.do`

**Options:**

| Option | When | Action |
|---|---|---|
| Approve in SNOW | Assignment group missed the notification | Ask the approver to navigate to the CR in ServiceNow and approve it — the pipeline will detect it on the next polling cycle |
| Cancel and re-run | CR window has passed or SNOW is down | Cancel the pipeline run (§2), force-close the CR (§4.3), then re-run the pipeline |
| Extend the change window | CR was approved too late | Update the CR's planned end time in SNOW before approving |

### 4.2 Pipeline Cancelled Mid-Deploy — CR Left Open

If a pipeline was cancelled or failed after the CR was opened but before the post-deploy step closed it, the CR will remain in "In Progress" state in ServiceNow.

**Steps:**
1. Find the CR number in the GitHub Actions logs (search for `SNOW_CHANGE_REQUEST_NUMBER`)
2. Navigate to the CR in ServiceNow
3. Close it manually:
   - If deployment was ultimately successful: set Close Code to `Successful`
   - If deployment did not complete: set Close Code to `Unsuccessful`, add a close note explaining the cancellation

### 4.3 Force-Close a CR When Pipeline Cannot Close It

Use this when the post-deploy step itself failed before the close call.

```powershell
# Load the ServiceNow module
. .ci/.github/servicenow/Classes/ServiceNow.Class.ps1
Get-ChildItem .ci/.github/servicenow/Private/ -Filter *.ps1 | ForEach-Object { . $_.FullName }
Get-ChildItem .ci/.github/servicenow/Public/  -Filter *.ps1 | ForEach-Object { . $_.FullName }

# Set credentials (from AKV or your local env)
$env:SERVICENOWMURI              = "https://yourorg.service-now.com"
$env:SNOW_OAUTH_CLIENT_ID        = "your-client-id"
$env:SNOW_OAUTH_CLIENT_SECRET    = "your-client-secret"
$env:SNOW_CHANGE_REQUEST_ID      = "the-sys_id-from-the-logs"

# Close as unsuccessful
Close-ServiceNowChangeRequest -CloseCode "unsuccessful" -CloseNotes "Closed manually — pipeline cancelled. Run ID: $env:GITHUB_RUN_ID"
```

### 4.4 SNOW Is Completely Down

1. Cancel the pipeline run (§2)
2. Manually perform the deployment using PAC CLI (see §5 for the command sequence)
3. When SNOW recovers, open a manual CR retroactively documenting the emergency action, attaching the SARIF from the JFrog artifact
4. Notify the change management team

---

## 5. Break-Glass Emergency Production Deploy

### When to use
A critical bug fix must reach production immediately and cannot wait for the normal multi-environment approval chain. Requires explicit authorisation from a designated authority (engineering manager, release manager, or VP Engineering).

> ⚠️ **This procedure bypasses ServiceNow, GitHub Environment gates, and pre-flight checks. Document all actions. Notify the change management team immediately.**

### Prerequisites
- Written authorisation from a named authority (Slack message, email, or Teams approval)
- PAC CLI installed and authenticated
- Access to the managed solution ZIP (from JFrog or a local build)
- PP service principal credentials

### Steps

**Option A — Use the pipeline with reduced gates (preferred)**

1. Build the fix branch normally with `build-and-deploy.yml` (mock_deploy=false)
2. Identify the Pipeline 1 run ID from the GitHub Actions run page
3. Dispatch `deploy-prod.yml` manually:
   - Go to **GHA-Dynamics → Actions → deploy-prod.yml → Run workflow**
   - Check **mock_deploy: false**, **enable_backup: true**
   - Approve the `Prod` environment gate when prompted (one approver required)
4. The ServiceNow CR will open as normal — ask the SNOW approver to fast-track approval

**Option B — Direct PAC CLI import (true break-glass)**

Use only if GitHub Actions is itself unavailable.

```bash
# 1. Authenticate to target environment
pac auth create \
  --url https://yourorg.crm.dynamics.com \
  --applicationId $PP_APP_ID \
  --clientSecret $PP_CLIENT_SECRET \
  --tenant $PP_TENANT_ID

# 2. Export current version as backup FIRST
pac solution export \
  --name CoreSolution \
  --path ./emergency-backup-CoreSolution-$(date +%Y%m%d%H%M%S).zip \
  --managed

# 3. Import the fix
pac solution import \
  --path ./CoreSolution-managed.zip \
  --managed \
  --force-overwrite \
  --publish-changes \
  --settings-file ./deployment-settings/prod/CoreSolution.json

# 4. Verify
pac solution list | grep CoreSolution
```

### Post-Action Checklist

- [ ] Open a manual ServiceNow CR documenting the emergency action
- [ ] Tag the deployed artifact in JFrog as prodDeployed (see §3.3)
- [ ] Notify affected teams
- [ ] Create a post-mortem issue in the project tracker
- [ ] Schedule a blameless post-mortem within 48 hours

---

## 6. Dataverse Blocking Operations — Force-Proceed

### When to use
The pre-deploy check (`Invoke-BlockingCheck.ps1`) detected in-progress async operations on the target environment and is warning that a solution import may conflict. The pipeline currently issues a warning but does not block.

### Diagnosis

Check the job logs for `Invoke-BlockingCheck.ps1` output. Look for entries like:

```
⚠️  Blocking operation detected: BulkOperationRequest (State: InProgress)
```

### Options

| Severity | Recommendation |
|---|---|
| Single minor async op (e.g., a dormant flow run from hours ago) | Proceed — these rarely cause import conflicts |
| Active bulk data import or flow activation wave | Wait 15-30 minutes and re-run the pipeline |
| Scheduled maintenance window (flows deliberately paused) | Coordinate with the environment owner before proceeding |

### Waiting for Blocking Operations to Clear

```bash
pac auth create --url https://yourorg-env.crm.dynamics.com ...

# Poll until no async jobs are in progress
while true; do
  pac asyncoperation list --environment https://yourorg-env.crm.dynamics.com
  echo "---"; sleep 60
done
```

### If You Must Proceed Anyway

1. Cancel the async operation through the Power Platform admin centre:
   - `https://admin.powerplatform.microsoft.com` → Environments → [Environment] → Settings → Audit and logs → System jobs
   - Locate and cancel the blocking job

2. Re-run the pipeline.

---

## 7. Version Mismatch — Override Version Compare

### When to use
`Compare-SolutionVersion.ps1` returned `N/A` (Dataverse query failed) and you want to force the import, or the script shows the wrong installed version and you need to bypass the check.

### Understanding the flags

In `build-and-deploy.yml` and `deploy-prod.yml`, the `enable_version_compare` input controls whether `Compare-SolutionVersion.ps1` runs. Setting it to `false` skips the comparison entirely and always imports.

**To skip version compare for a single run:**
1. Dispatch the workflow manually (`workflow_dispatch`)
2. Set `enable_version_compare: false` if this input is exposed (check the workflow YAML)

If the input is not exposed, temporarily set the variable in `project-vars.yml`:

```yaml
variables:
  ENABLE_VERSION_COMPARE: "false"
```

> Revert `project-vars.yml` after the run completes.

### If the Dataverse query is consistently returning N/A

The service principal may have lost its System Administrator role on the environment:

```bash
# Check who-am-i
pac auth create --url https://yourorg-env.crm.dynamics.com ...
pac org who
```

If the output shows a different user or an error, re-add the App Registration as an Application User with System Administrator role in the Power Platform admin centre.

---

## 8. JFrog Artifactory Unavailable

### Impact

| Stage | Impact when JFrog is down |
|---|---|
| Build | `jfrog-upload` step fails (non-blocking if `JFROG_UPLOAD_ENABLED=false`) |
| Deploy | Artifact download from GitHub Actions storage is used (not JFrog) — works for 7 days |
| Rollback | Cannot search by `prodDeployed=true` tag; use GitHub artifact or local copy |

### Temporary Workaround — Disable JFrog Upload

To allow builds to succeed without JFrog:

1. Set in `project-vars.yml` (GHA-Dynamics):

```yaml
variables:
  JFROG_UPLOAD_ENABLED: "false"
```

2. Merge to the feature branch. Builds will upload only to GitHub artifacts (7-day retention).

3. Revert once JFrog is back.

### Rollback Without JFrog

Follow §3.1 (GitHub artifact backup) or use a locally held managed ZIP from a previous successful build.

### After JFrog Recovers

Re-upload missing artifacts using `Invoke-JFrogAction.ps1 upload` directly:

```powershell
& .ci/.github/scripts/dynamics/Invoke-JFrogAction.ps1 `
  -Action upload `
  -SolutionName CoreSolution `
  -ArtifactName solution-CoreSolution-run42 `
  -UnmanagedZip "./CoreSolution-unmanaged.zip" `
  -ManagedZip "./CoreSolution-managed.zip" `
  -JFrogUrl $env:JFROG_URL `
  -JFrogRepo powerplatform-solutions `
  -RunNumber 42 `
  -RunAttempt 1 `
  -JFrogToken $env:JFROG_TOKEN
```

---

## 9. Credential Rotation — GHA_CORE_PAT

### When to use
- `GHA_CORE_PAT` has expired (checkout steps fail with `fatal: could not read Username`)
- Planned rotation (recommended: every 90 days, or switch to a GitHub App)
- The owner of the PAT account is leaving the organisation

### Steps

**Option A — Personal Access Token (PAT)**

1. Go to GitHub → **Settings → Developer settings → Personal access tokens → Tokens (classic)**
2. Generate a new token with `repo` scope (select the `ppudot2-cloud/GHA-Core` repo specifically if using fine-grained tokens)
3. Navigate to **GHA-Dynamics → Settings → Secrets and variables → Actions → Secrets → GHA_CORE_PAT**
4. Click **Update** and paste the new token
5. Verify: trigger a mock run (`mock_deploy: true`) and confirm the checkout step passes

**Option B — GitHub App (recommended for production)**

Using a GitHub App produces short-lived tokens (1-hour TTL) that rotate automatically:

1. Create a GitHub App in your organisation (Settings → Developer settings → GitHub Apps)
2. Grant `Contents: Read` and `Pull requests: Write` repository permissions on `GHA-Core` and `GHA-Dynamics`
3. Install the App on both repositories
4. Store the App ID and private key in Azure Key Vault (`github-app-id`, `github-app-private-key`)
5. Modify `reveille/action.yml` to generate an installation token using `actions/create-github-app-token@v1` before the checkout steps

---

## 10. Credential Rotation — Power Platform Service Principal

### When to use
- `pp-client-secret` in Azure Key Vault is approaching its expiry date
- Security team has requested emergency rotation
- The `who-am-i` step shows auth failure in pipeline logs

### Steps

**Rotate the client secret:**

```bash
# 1. Get the App Registration object ID
az ad app list --display-name "pp-cicd-github-actions" --query "[0].id" -o tsv

# 2. Add a new client secret (note the new secret value immediately — it is shown only once)
az ad app credential reset \
  --id $APP_ID \
  --append \
  --years 1

# 3. Update Azure Key Vault with the new secret
az keyvault secret set \
  --vault-name kv-pp-cicd \
  --name pp-client-secret \
  --value "NEW_SECRET_VALUE"

# 4. Verify the new secret works
pac auth create \
  --url https://yourorg-dev.crm.dynamics.com \
  --applicationId $PP_APP_ID \
  --clientSecret "NEW_SECRET_VALUE" \
  --tenant $PP_TENANT_ID
pac org who

# 5. Remove the old secret (IMPORTANT — do this after verification)
az ad app credential delete --id $APP_ID --key-id OLD_KEY_ID
```

**Verify end-to-end:**

Run a mock pipeline to confirm reveille fetches the updated secret successfully:
- Dispatch `build-and-deploy.yml` with `mock_deploy: true`
- Check that the `reveille` step succeeds and no `AADSTS` errors appear

---

## 11. Feature Branch Cleanup After Failed Pipeline

When a pipeline is cancelled mid-run, orphaned branches of the form `feature/pipeline-{N}` may remain in the repository.

### Find orphaned branches

```bash
# List all feature/pipeline-* branches older than 14 days
git fetch --prune
git branch -r | grep "feature/pipeline-" | while read branch; do
  age=$(git log -1 --format="%ar" origin/${branch#origin/})
  echo "$age  $branch"
done
```

### Delete orphaned branches

```bash
# Delete a specific orphaned branch
git push origin --delete feature/pipeline-42

# Bulk delete all feature/pipeline-* branches (use with care)
git branch -r | grep "origin/feature/pipeline-" | sed 's/origin\///' | \
  xargs -I{} git push origin --delete {}
```

### Check for orphaned PRs

Cancelled pipelines may also leave open PRs created by `create-main-pr`. Check:

```bash
gh pr list --repo YOUR_ORG/GHA-Dynamics --state open --label "pipeline-auto"
```

Close any PRs that correspond to cancelled runs.

---

## 12. Onboard a New GHA-Dynamics Project

Use this checklist when a new Power Platform project team wants to use the pipeline.

### Prerequisites

- GHA-Dynamics repository created in the GitHub org
- Solutions already exported or ready to be committed
- Project team has read [QUICK_START.md](./QUICK_START.md)

### Checklist

**GitHub Configuration:**
- [ ] Create six environments in GHA-Dynamics: `Dev`, `Intg`, `UAT`, `FRS`, `Perf`, `Prod`
- [ ] Set required reviewers on `UAT` and `Prod` at minimum
- [ ] Set `SERVICENOW_ENABLED=true` on UAT, FRS, Perf, Prod (if using ServiceNow)
- [ ] Add `GHA_CORE_PAT` secret
- [ ] Add all `AZURE_*` variables (or confirm they're at org level)
- [ ] Add all `PP_*_URL` variables (environment URLs for this project's Power Platform environments)
- [ ] Register the App Registration's OIDC federated credentials for this new repo + each environment

**Power Platform:**
- [ ] Register the pipeline service principal as Application User with System Administrator role in each PP environment
- [ ] Verify `pac auth create` succeeds for each environment

**GHA-Dynamics Repository:**
- [ ] Create `solutions.json` at the root
- [ ] Create `deployment-settings/{env}/{SolutionName}.json` for each solution + environment
- [ ] Create `config/{SolutionName}/data-schema.xml` if using config data migration
- [ ] Create `.github/config/project-vars.yml` with project-specific overrides
- [ ] Copy the four workflow files from an existing GHA-Dynamics repo (or template)

**Validation:**
- [ ] Run `build-and-deploy.yml` with `mock_deploy: true` — all jobs should pass
- [ ] Run `test-servicenow.yml` if ServiceNow is enabled — all 14 simulated steps should pass
- [ ] Run a real build (`mock_deploy: false`) and approve the Dev gate

---

## 13. Restore a Deleted or Corrupted Environment

### When to use
A Power Platform environment was accidentally deleted, restored from backup by Microsoft Support, or is in a state where the solution registry no longer matches the expected state.

### Rebuild an environment from scratch

```bash
# 1. Authenticate to the environment
pac auth create --url https://yourorg-env.crm.dynamics.com ...

# 2. List currently installed solutions
pac solution list

# 3. Install base solutions first (if any are declared in PP_BASE_SOLUTIONS)
# Download each base solution managed ZIP from JFrog and import in order

# 4. Import each project solution in deployOrder sequence
for solution in CoreSolution ExtensionA ExtensionB; do
  pac solution import \
    --path ./artifacts/${solution}-managed.zip \
    --managed \
    --force-overwrite \
    --publish-changes \
    --settings-file ./deployment-settings/dev/${solution}.json
done
```

### Re-register the service principal

After an environment is restored, the Application User registration may have been lost:

1. Navigate to **Power Platform Admin Centre → Environments → [Environment] → Settings → Users + permissions → Application users**
2. Click **New app user**
3. Select the pipeline App Registration (`pp-cicd-github-actions`)
4. Assign **System Administrator** role
5. Save

---

## 14. GitHub Actions Runner Diagnostics

### Enable runner diagnostics

Add `ACTIONS_RUNNER_DEBUG: true` and `ACTIONS_STEP_DEBUG: true` as repository secrets to enable verbose runner output for all workflows. Remove after diagnosis.

### Common runner errors

| Error | Cause | Fix |
|---|---|---|
| `The term '.ci/.github/scripts/dynamics/...' is not recognized` | `reveille` checkout of GHA-Core to `.ci/` failed | Check `GHA_CORE_PAT` is valid; verify repo name in reveille action.yml |
| `Error: Process completed with exit code 1` on PAC install | GitHub Actions runner has transient network issue | Re-run the job — PAC CLI download from NuGet is intermittently flaky |
| `Login failed: The process '/usr/bin/az' failed` | Azure OIDC misconfigured | Verify federated credential subject matches exactly: `repo:YOUR_ORG/GHA-Dynamics:environment:Dev` |
| `AADSTS700016: Application 'xxx' was not found` | Wrong `AZURE_TENANT_ID` | Ensure `AZURE_TENANT_ID` is YOUR tenant, not the Contoso demo tenant |
| Runner memory exhausted (large solution pack) | Solution ZIP > 500MB | Split solution into sub-solutions or request larger runner via `runs-on: ubuntu-latest-16-cores` |
| `error: failed to push some refs` | Concurrent export jobs writing to same branch | Export jobs always run with `max-parallel: 1` — if this error appears, check for a manually triggered conflicting run |

### Check which version of GHA-Core is running

The `reveille` action logs the GHA-Core commit SHA during checkout. Check the "Set up job" step output in any workflow run:

```
Checking out ppudot2-cloud/GHA-Core to .ci/ ...
Cloned at: abc123def456...
```

This is the actual commit that ran. Cross-reference against `https://github.com/YOUR_ORG/GHA-Core/commits/main` to confirm you are on the expected version.

---

## Escalation Path

| Issue | First contact | Escalation |
|---|---|---|
| Pipeline stuck / GitHub Actions down | Platform Engineering on-call | GitHub Support: https://support.github.com |
| ServiceNow CR stuck | Release Manager | ServiceNow Admin |
| Dataverse environment corrupted | Power Platform team | Microsoft Support via Power Platform Admin Centre |
| Azure Key Vault unreachable | Cloud Engineering | Azure Support |
| JFrog unreachable | DevOps Engineering | JFrog Support |
| Security incident (credentials compromised) | Security Operations Centre | Immediate — follow incident response process |
