# Pipeline Reference — GHA-Core + GHA-Dynamics
## Complete guide to every workflow, action, script, and config file

> This document is the single source of truth for what every component in the pipeline does.
> For setup instructions see [ENTERPRISE_DEVSECOPS_GUIDE.md](./ENTERPRISE_DEVSECOPS_GUIDE.md).
> For a visual flow diagram see [gha_cicd_e2e_flow.html](./gha_cicd_e2e_flow.html).

---

## Table of Contents

1. [GHA-Dynamics Workflows](#1-gha-dynamics-workflows)
2. [GHA-Core Reusable Workflows](#2-gha-core-reusable-workflows)
3. [GHA-Core Composite Actions](#3-gha-core-composite-actions)
4. [GHA-Core PowerShell Scripts](#4-gha-core-powershell-scripts)
5. [Configuration Files](#5-configuration-files)
6. [Deployment Settings](#6-deployment-settings)
7. [Variable Files](#7-variable-files)

---

## 1. GHA-Dynamics Workflows

These are the entry-point workflows — the ones you trigger or that fire automatically. All business logic is delegated to GHA-Core.

### `build-and-deploy.yml` — Pipeline 1

**Path:** `.github/workflows/build-and-deploy.yml`
**Trigger:** `workflow_dispatch` (manual) or `push` to any `feature/**` branch (paths-ignore: pipeline-context.json)
**Purpose:** Full build pipeline for non-production environments. Exports from sandbox, builds all solutions, deploys to Dev/Intg/UAT/FRS/Perf in parallel, then creates a PR to main.

**Inputs:**

| Input | Type | Default | Description |
|---|---|---|---|
| `mock_deploy` | boolean | false | Skip all Dataverse/JFrog operations; simulate the entire pipeline |
| `enable_backup` | boolean | false | Take a pre-import backup at each environment before upgrading. If the import fails, the pipeline automatically re-imports the backup to restore the previous version. Recommended: `true` for UAT, FRS, Perf, Prod. |
| `solutions` | string | `all` | "all" or comma-separated solution names to build and deploy. Must be declared with `type: string` in the workflow — GitHub only pre-fills `default` values when the type is explicitly set. |
| `skip_export` | boolean | false | Skip sandbox export — build from source already committed to the current branch. Set automatically when triggered by a push event. |
| `checker_error_level` | choice | `HighIssue` | Minimum severity that fails Solution Checker |
| `base_solutions` | string | `''` | Comma-separated base solution names to verify are installed before deployment |

> **ServiceNow:** Controlled per environment via `vars.SERVICENOW_ENABLED` (GitHub Environment variable), not a workflow input. Set to `true` on any environment to activate the full CR lifecycle. See [SECRETS_SETUP_GUIDE.md](./SECRETS_SETUP_GUIDE.md).

**Job flow:**
```
setup → stage-export → stage-build → deploy-dev    ┐
                                  → deploy-intg   │ parallel
                                  → deploy-uat    │
                                  → deploy-frs    │
                                  → deploy-perf   ┘
       → create-main-pr (after deploy-uat succeeds)
       → pipeline-summary (always)
```

**Key behaviours:**
- `setup` runs `Resolve-SolutionMatrix.ps1` to read `solutions.json` and build the GitHub Actions matrix
- `stage-export` calls `_stage-export.yml`; when triggered by a push event or when `skip_export=true`, the export jobs are skipped — the commit job still runs to write `pipeline-context.json` to the existing branch
- `stage-build` calls `_stage-build.yml` which fans out to `_job-build.yml` per solution
- All 5 deploy jobs run in parallel; each internally deploys solutions **sequentially** (Dataverse constraint)
- `pipeline-context.json` is written by **stage-export's commit job** during the export stage
- `create-main-pr` opens a PR to main via `gh pr create` after UAT deploy succeeds
- `pipeline-summary` calls `Write-PipelineSummary.ps1` and sends failure email if any job failed

---

### `deploy-prod.yml` — Pipeline 2

**Path:** `.github/workflows/deploy-prod.yml`
**Trigger:** `push` to `main` where `pipeline-context.json` changed (i.e., when a Pipeline 1 feature branch PR is merged and `pipeline-context.json` lands on main) + `workflow_dispatch` (for manual re-runs or ad-hoc Prod promotion)
**Purpose:** Final promotion to UAT (re-validation) and Production. Downloads build artifacts from Pipeline 1 run.

> Using `push` + `paths` is more reliable than `pull_request: closed` because it fires on the actual push event, not the PR event.

**Inputs (workflow_dispatch only):**

| Input | Type | Default | Description |
|---|---|---|---|
| `mock_deploy` | boolean | false | Simulate UAT + Prod without touching Dataverse |
| `enable_backup` | boolean | false | Take pre-import backups at UAT and Prod |

> **ServiceNow:** Controlled per environment via `vars.SERVICENOW_ENABLED` (GitHub Environment variable). Set to `true` on the UAT and Prod environments to activate ServiceNow for those deployments.

**Job flow:**
```
guard → read-context → deploy-uat → deploy-prod → pipeline-summary
```

**Key behaviours:**
- `guard` job confirms the trigger type (push vs manual dispatch) and logs the commit/actor — no branch name filtering is needed because the `push` + `paths` trigger already ensures only `pipeline-context.json` changes fire this workflow
- `read-context` checks out main (the merge commit), parses `pipeline-context.json`, outputs `run_id` used to download artifacts from the original Pipeline 1 run
- `deploy-uat` uses `environment: UAT` — pauses for approval if UAT has required reviewers configured
- `deploy-prod` uses `environment: Prod` — pauses for Prod approval; only runs if UAT succeeded
- Both jobs download artifacts from Pipeline 1's run using `actions/download-artifact` with `run-id`
- Prod deploy sets `import_config_data: true` and `tag_prod_deployed: true`
- `pipeline-summary` sends failure notification email on failure

---

### `export-solution.yml` — Standalone Export

**Path:** `.github/workflows/export-solution.yml`
**Trigger:** `workflow_dispatch` only
**Purpose:** Export one or all solutions from sandbox, unpack into `src/solutions/`, commit to a feature branch, optionally create a PR to main.

**Inputs:**

| Input | Type | Default | Description |
|---|---|---|---|
| `solution_name` | string | `''` | Specific solution to export; empty = all from solutions.json |
| `commit_message` | string | `'chore: export'` | Git commit message prefix |
| `create_pr` | boolean | true | Create a PR to main after export |
| `mock_deploy` | boolean | false | Simulate export without connecting to PP sandbox |

**Job flow:**
```
setup → export (matrix, max-parallel:1) → create-pr
```

**Key behaviours:**
- `setup` resolves the feature branch name (format: `feature/pipeline-{run_number}`) and creates/switches to it
- `export` matrix runs each solution sequentially (`max-parallel: 1`) to avoid git commit conflicts
- Each export iteration: PAC export → PAC unpack → `git pull --rebase` → `git commit` → `git push`
- In mock mode, calls `Invoke-ExportCommitSim.ps1` to create stub solution files and commit without PAC CLI
- `create-pr` only runs if `create_pr=true` and not mock mode

---

### `pr-validation.yml` — PR Build Check

**Path:** `.github/workflows/pr-validation.yml`
**Trigger:** Pull request events (opened, synchronize, reopened) targeting `main`
**Purpose:** Validate that a PR builds successfully before merge. Build only — no deploy.

**Key behaviours:**
- Skips if PR is from a `feature/*` branch (those are Pipeline 1 PRs; only human code changes need validation)
- Runs the full build chain (`_stage-build.yml`) including Solution Checker
- Writes a build summary via `Write-PipelineSummary.ps1`
- Failure blocks the PR merge (configure as a required status check in branch protection)

---

### `test-servicenow.yml` — ServiceNow Flow Simulation

**Path:** `.github/workflows/test-servicenow.yml`
**Trigger:** `workflow_dispatch` only
**Purpose:** Fully self-contained simulation of the ServiceNow change management lifecycle. No Azure login, no Dataverse connection, no real SNOW API calls — every step is simulated with realistic output and timing. Use this to verify the 14-step ServiceNow CR flow and confirm env var handoff between pre-deploy and post-deploy phases before enabling ServiceNow on a real environment.

**Inputs:**

| Input | Type | Default | Description |
|---|---|---|---|
| `environment_name` | choice | `UAT` | Target environment to simulate (Dev / Intg / UAT / FRS / Perf / Prod) |
| `solution_list` | string | `CoreSolution` | Comma-separated list of solution names to simulate deploying |
| `simulate_outcome` | choice | `success` | Force deployment to succeed or fail — lets you test both the successful close and unsuccessful close CR paths |

**Simulated steps:**

| Phase | Step | Action |
|---|---|---|
| Reveille | 1–6 | Checkout, GHA-Core checkout, Azure login, AKV fetch (6 secrets), merge variables, JFrog register |
| Pre-Deploy | 1 | Load ServiceNow PS module |
| Pre-Deploy | 2 | Set runtime env vars (description, build ID, change window) |
| Pre-Deploy | 3 | `New-ServiceNowChangeRequest` → generates fake `CHG#######` CR number and sys_id GUID |
| Pre-Deploy | 4 | `Add-ServiceNowAuditTrailArtifact` → attaches SARIF |
| Pre-Deploy | 5 | `Set-ServiceNowChangeWindow` |
| Pre-Deploy | 6 | `Get-ServiceNowConflict` |
| Pre-Deploy | 7 | `Request-ServiceNowApproval` |
| Pre-Deploy | 8 | `Get-ServiceNowApprovalStatus` → polls and approves after short delay |
| Deploy | 1–11 | Full per-solution deploy simulation (11 sub-steps), writes `SNOW_DEPLOY_STATUS` before any exit |
| Post-Deploy | 12 | `GET /repos/{owner}/{repo}/actions/runs/{id}/approvals` → find GitHub Environment approvers |
| Post-Deploy | 13 | Read `SNOW_DEPLOY_STATUS` |
| Post-Deploy | 14 | `Close-ServiceNowChangeRequest` with `close_code: successful` or `unsuccessful` |

**Key behaviours:**
- Generates a real-looking CR number (`CHG1234567`) and sys_id UUID, written to `$GITHUB_ENV` in pre-deploy and read back in post-deploy
- Post-deploy step uses `if: always()` — it runs and closes the CR even if the simulated deploy "fails"
- `SNOW_DEPLOY_STATUS` is written to `$GITHUB_ENV` **before** `exit 1` so post-deploy always sees it
- Final step writes a full table to `$GITHUB_STEP_SUMMARY` listing all 14 steps and their simulated outcomes

---


## 2. GHA-Core Reusable Workflows

These workflows are called via `uses: ppudot2-cloud/GHA-Core/.github/workflows/{name}@main`. They must live in `.github/workflows/` root (GitHub constraint — subdirectories not supported for reusable workflows).

> **Architecture principle — Azure identity inputs**
>
> GHA-Core is a shared library and **never reads `vars.AZURE_*` directly**. Every reusable workflow that needs Azure OIDC authentication declares `azure_client_id`, `azure_tenant_id`, `azure_subscription_id`, and `azure_key_vault_name` as explicit `workflow_call` inputs. The caller (GHA-Dynamics) reads its own `vars.AZURE_*` repository variables and passes them as `with:` inputs. This keeps GHA-Core free of project-specific configuration and ensures that `vars.*` always resolve from the repo that owns them.

### `_stage-export.yml`

**Path:** `.github/workflows/_stage-export.yml`
**Called by:** `build-and-deploy.yml` stage-export job
**Purpose:** Export stage — exports solutions from sandbox and commits to the feature branch. Supports a `skip_export` input.

Supports two modes: **normal** (exports from sandbox, creates `feature/pipeline-{N}` branch) and **skip_export** (source already committed; the commit job only writes `pipeline-context.json` to the existing branch). Outputs the feature branch name for downstream jobs.

**Key inputs:** `matrix`, `solution_list`, `source_environment_url`, `mock_deploy`, `skip_export`, `azure_client_id`, `azure_tenant_id`, `azure_subscription_id`, `azure_key_vault_name`

**Outputs:** `feature_branch`

---

### `_stage-build.yml`

**Path:** `.github/workflows/_stage-build.yml`
**Called by:** `build-and-deploy.yml`, `pr-validation.yml`
**Purpose:** Build stage — fans out to `_job-build.yml` using a matrix strategy, one job per solution. Runs in parallel.

**Key inputs:** `matrix`, `mock_deploy`, `jfrog_url`, `jfrog_repo`, `use_exported_source`, `checker_error_level`, `azure_client_id`, `azure_tenant_id`, `azure_subscription_id`, `azure_key_vault_name`

**Outputs:** Per-solution: `solution_version`, `artifact_name`, `unmanaged_zip`, `managed_zip`

---

### `_job-build.yml`

**Path:** `.github/workflows/_job-build.yml`
**Called by:** `_stage-build.yml` (one instance per solution in the matrix)
**Purpose:** Single-solution build job. Orchestrates: reveille → pac-install → optional artifact download → pack-solution → solution-checker → export-config-data → upload artifact → jfrog-upload → write summary.

**Key inputs:** `solution_name`, `solution_source_folder`, `use_exported_source`, `checker_error_level`, `data_schema_file`, `source_environment_url`, `mock_deploy`, `jfrog_url`, `jfrog_repo`, `azure_client_id`, `azure_tenant_id`, `azure_subscription_id`, `azure_key_vault_name`

**Outputs:** `solution_version`, `artifact_name`, `unmanaged_zip`, `managed_zip`, `checker_artifact_name`

---

### `_stage-deploy-chain.yml`

**Path:** `.github/workflows/_stage-deploy-chain.yml`
**Called by:** Any caller that needs multi-environment deployment with approval gates
**Purpose:** Parallel deploy across all environments (Dev, Intg, UAT, FRS, Perf, Prod) with individual GitHub Environment approval gates. Each environment has its own explicit job so GitHub renders a distinct "Waiting for review" gate node. All gates open simultaneously — approve all at once or selectively.

Accepts an `environments` filter input (comma-separated) to deploy only a subset of environments. Per-environment config is passed as compact JSON objects (`dev_config`, `intg_config`, etc.).

**Key inputs:** `matrix`, `mock_deploy`, `environments`, `source_run_id`, `base_solutions`, `jfrog_url`, `jfrog_repo`, `run_number`, `run_attempt`, `azure_client_id`, `azure_tenant_id`, `azure_subscription_id`, `azure_key_vault_name`, plus per-env config objects (`dev_config`, `intg_config`, `uat_config`, `frs_config`, `perf_config`, `prod_config`)

---


## 3. GHA-Core Composite Actions

All actions live in `.github/actions/dynamics/` and are referenced as `ppudot2-cloud/GHA-Core/.github/actions/dynamics/{name}@main`.

### `reveille`

**Path:** `.github/actions/dynamics/reveille/action.yml`
**Used by:** Every deploy job in every workflow as the first step.
**Purpose:** Wakes the runner — checks out repos, authenticates to Azure via OIDC, fetches all required secrets from Key Vault, merges global + project variables, and (optionally) registers JFrog as the PowerShell module source.

Steps performed:
1. `actions/checkout@v4` — checks out the **calling repository** (GHA-Dynamics) with full history
2. `actions/checkout@v4` — checks out **GHA-Core** to `.ci/` using `GHA_CORE_PAT`
3. `azure/login@v2` — OIDC login (skipped if `mock_deploy=true`)
4. **Fetch secrets from Azure Key Vault** — always fetches `pp-app-id`, `pp-client-secret`, `pp-tenant-id`. Conditionally adds:
   - `jfrog-api-key` → `JFROG_TOKEN` (when `jfrog_enabled=true`)
   - `mulesoft-client-id`, `mulesoft-client-secret` → `MULESOFT_CLIENT_ID`, `MULESOFT_CLIENT_SECRET` (when `mulesoft_enabled=true`)
   - `snow-base-uri`, `snow-oauth-client-id`, `snow-oauth-client-secret` → `SERVICENOWMURI`, `SNOW_OAUTH_CLIENT_ID`, `SNOW_OAUTH_CLIENT_SECRET` (when `servicenow_enabled=true`)
5. `Merge-Variables.ps1` — merges `global-vars.yml` + `project-vars.yml` into `$GITHUB_ENV`
6. **Register JFrog as PS module repository** — unregisters PSGallery, registers JFrog NuGet v2 feed as trusted `Install-Module` source (when `jfrog_enabled=true`, skipped in mock mode)

**Inputs:**

| Input | Default | Description |
|---|---|---|
| `mock_deploy` | `false` | Skip Azure login and AKV fetch; simulate locally |
| `jfrog_enabled` | `false` | Fetch `jfrog-api-key` from AKV; register JFrog as PS module source |
| `mulesoft_enabled` | `false` | Fetch Mulesoft credentials from AKV (for solutions using Mulesoft connectors) |
| `servicenow_enabled` | `false` | Fetch ServiceNow credentials from AKV. Driven by `vars.SERVICENOW_ENABLED` on each environment. |
| `azure_client_id` | `''` | OIDC App Registration client ID — passed by the caller from `vars.AZURE_CLIENT_ID` |
| `azure_tenant_id` | `''` | Azure AD tenant ID — passed by the caller from `vars.AZURE_TENANT_ID` |
| `azure_subscription_id` | `''` | Azure subscription ID — passed by the caller from `vars.AZURE_SUBSCRIPTION_ID` |
| `azure_key_vault_name` | `''` | Key Vault name — passed by the caller from `vars.AZURE_KEY_VAULT_NAME`; set per environment if using separate KVs for non-prod/prod |

> **Composite action limitation:** composite actions cannot access `${{ secrets.* }}` or `${{ vars.* }}` from the caller's context directly. The caller must:
> - Expose `GHA_CORE_PAT` via `env: GHA_CORE_PAT` on the step
> - Pass `vars.AZURE_*` values explicitly as `azure_*` inputs
>
> This is by design — GHA-Core owns no project variables. All identity configuration lives in the caller repo.

---

### `pac-install`

**Path:** `.github/actions/dynamics/pac-install/action.yml`
**Purpose:** Installs Microsoft Power Platform CLI using `microsoft/powerplatform-actions/actions-install@v1` and adds it to PATH. No inputs.

---

### `servicenow-change`

**Path:** `.github/actions/dynamics/servicenow-change/action.yml`
**Used by:** `deploy-all-solutions` action (when `enable_servicenow=true`)
**Purpose:** Manages the full ServiceNow change request lifecycle. Called twice per deployment — once before importing solutions (pre-deploy) and once after (post-deploy).

**Pre-deploy phase** (`phase=pre-deploy`):
1. Load ServiceNow PowerShell module from `.ci/.github/servicenow/`
2. Set dynamic runtime env vars (`BUILD_UNIQUE_IDENTIFIER`, `SERVICENOWSHORTDESCRIPTION`, change window)
3. `New-ServiceNowChangeRequest` — opens CR, writes `SNOW_CHANGE_REQUEST_NUMBER` and `SNOW_CHANGE_REQUEST_ID` to `$GITHUB_ENV`
4. `Add-ServiceNowAuditTrailArtifact` — attaches Solution Checker SARIF to the CR
5. `Set-ServiceNowChangeWindow` — sets planned start/end time
6. `Get-ServiceNowConflict` — checks for scheduling conflicts
7. `Request-ServiceNowApproval` — moves CR to awaiting approval state
8. `Get-ServiceNowApprovalStatus` — polls until approved (blocks pipeline). Fails on rejection or timeout.

**Post-deploy phase** (`phase=post-deploy`) — uses `if: always()` so it runs even if deployment failed:
12. GitHub Actions REST API — `GET /repos/{owner}/{repo}/actions/runs/{run_id}/approvals` to find environment approvers; falls back to `GITHUB_ACTOR`
13. Read `SNOW_DEPLOY_STATUS` env var (written by the deploy loop before any `exit 1`)
14. `Close-ServiceNowChangeRequest` — `close_code: successful` or `unsuccessful` based on deploy status

**Required env vars** (populated by `reveille` when `servicenow_enabled=true`):

| Env Var | AKV Secret | Description |
|---|---|---|
| `SERVICENOWMURI` | `snow-base-uri` | ServiceNow instance base URL |
| `SNOW_OAUTH_CLIENT_ID` | `snow-oauth-client-id` | OAuth client ID |
| `SNOW_OAUTH_CLIENT_SECRET` | `snow-oauth-client-secret` | OAuth client secret |

**Optional SNOW vars** (configure in `global-vars.yml` or `project-vars.yml`):

| Variable | Default | Description |
|---|---|---|
| `SERVICENOWCHANGETYPE` | `standard` | Change type |
| `SERVICENOWASSIGNMENTGROUP` | — | Assignment group |
| `SERVICENOWJUSTIFICATION` | — | Business justification |
| `SERVICENOWIMPLEMENTATIONPLAN` | — | Implementation plan |
| `SERVICENOWBACKOUTPLAN` | — | Backout / rollback plan |
| `SERVICENOWRISKIMPACTANALYSIS` | — | Risk and impact narrative |
| `SERVICENOWRISKLEVEL` | `Low` | Risk level |
| `SERVICENOWIMPACTLEVEL` | `3 - Low` | Impact level |
| `SERVICENOWCONFIGURATIONITEM` | — | CMDB CI linked to this change |
| `SERVICENOWCATEGORY` | — | Change category |
| `SERVICENOWSERVICENAME` | — | Business service name |
| `SERVICENOW_DESIRED_DAY` | today | Preferred day of week for change window |

**Inputs:**

| Input | Required | Description |
|---|---|---|
| `phase` | ✅ | `pre-deploy` or `post-deploy` |
| `environment_name` | ✅ | Target environment name (e.g. `UAT`, `Prod`) |
| `solution_list` | — | Comma-separated solution names (used in CR description) |
| `sarif_path` | — | Path to Solution Checker SARIF file (attached to CR) |
| `mock_deploy` | — | When `true`, logs what would have happened without calling SNOW APIs |

---

### `pack-solution`

**Path:** `.github/actions/dynamics/pack-solution/action.yml`
**Purpose:** Read solution version, stamp new version, strip `<Managed>` tag, pack ZIPs.

Steps:
1. `Set-SolutionVersion.ps1` — reads version from `Solution.xml`, computes `Major.Minor.RunNumber.Attempt`, writes back
2. Set artifact name outputs: `solution-artifact-{name}`, paths for unmanaged and managed ZIPs
3. `Remove-ManagedTag.ps1` — strips `<Managed>0</Managed>` from `Solution.xml`
4. PAC solution pack (unmanaged) — or `New-MockSolutionZip.ps1` in mock mode
5. PAC solution pack (managed) — or second mock ZIP

**Inputs:** `solution_name`, `solution_source_folder`, `mock_deploy`, `run_number`, `run_attempt`
**Outputs:** `version`, `artifact_name`, `unmanaged_zip`, `managed_zip`, `out_dir`, `checker_artifact_name`

---

### `solution-checker`

**Path:** `.github/actions/dynamics/solution-checker/action.yml`
**Purpose:** Run PAC Solution Checker against the unmanaged ZIP. Always mandatory in real mode.

Real mode: `microsoft/powerplatform-actions/check-solution@v1` → generates SARIF → uploads checker artifact
Mock mode: `Invoke-SolutionCheckerSim.ps1` → validates ZIP structure → generates mock SARIF

**Inputs:** `solution_name`, `unmanaged_zip`, `managed_zip`, `checker_error_level`, `checker_artifact_name`, `mock_deploy`, `out_dir`

---

### `export-config-data`

**Path:** `.github/actions/dynamics/export-config-data/action.yml`
**Purpose:** Export Configuration Migration data from source PP environment.

Real mode: `microsoft/powerplatform-actions/export-data@v1` → `config-data/{name}-data.zip`
Mock mode: `Export-ConfigDataSim.ps1` → validates schema XML → creates placeholder ZIP
Skip: if `data_schema_file` is empty

**Inputs:** `solution_name`, `data_schema_file`, `source_environment_url`, `run_number`, `mock_deploy`

---

### `export-solution`

**Path:** `.github/actions/dynamics/export-solution/action.yml`
**Purpose:** Export an unmanaged solution from a PP environment using PAC CLI. Used by `_stage-export.yml`.

**Inputs:** `solution_name`, `environment_url`, `mock_deploy`

---

### `import-solution`

**Path:** `.github/actions/dynamics/import-solution/action.yml`
**Purpose:** Wraps PAC solution import for all solution types and import patterns.

Handles three variants:
- **Unmanaged** (Dev only): `pac solution import` without managed flag
- **Managed standard**: `pac solution import --managed`
- **Stage-and-upgrade** (auto-selected when solution already exists): `pac solution stage-and-upgrade` → `pac solution apply-upgrade`

**Inputs:** `solution_name`, `solution_file`, `environment_url`, `solution_type`, `enable_upgrade`, `deployment_settings_file`, `mock_deploy`

---

### `deploy-all-solutions`

**Path:** `.github/actions/dynamics/deploy-all-solutions/action.yml`
**Purpose:** Main deploy orchestrator. Deploys ALL solutions in `solutions_json` to ONE environment, in `deployOrder` sequence.

For each solution (in order):
1. Verify artifact present
2. Token substitution in deployment settings
3. Base solutions check (PAC solution list)
4. Blocking async check (`Invoke-BlockingCheck.ps1`)
5. Version compare (`Compare-SolutionVersion.ps1`) — sets `skip_import` if already at version
6. Find solution — detect first install vs upgrade (auto-selects import pattern)
7. Backup — `pac solution export` to `backup/{name}_{env}_backup.zip`. **Only runs on upgrades** (solution already exists in the environment). First installs are skipped — there is no previous version to back up.
8. Import — PAC import (holding/upgrade pattern if solution exists, standard if new install)
9. Config data import — PAC data import if `import_config_data=true` and data ZIP exists
10. Publish customizations — PAC publish (skipped for upgrades — upgrade pattern publishes automatically)
11. Activate Cloud Flows — PAC flow list + PAC flow enable per inactive flow
12. JFrog Prod tag — `Invoke-JFrogAction.ps1 tag-prod` (Prod environment only)
13. Deploy summary — `Write-DeploySummary.ps1`

On failure (catch block): if `enable_backup=true` and a backup ZIP was taken (i.e. this was an upgrade), the pipeline **immediately re-imports the backup** to restore the previous version — no manual intervention required. First-install failures are not rolled back (nothing to restore to).

After loop: uploads `backup-{env}-v{run_number}` GitHub artifact (30-day retention) for audit purposes.

**Key inputs:** `solutions_json`, `environment_name`, `environment_url`, `solution_type`, `enable_backup`, `enable_blocking_check`, `enable_version_compare`, `import_config_data`, `tag_prod_deployed`, `activate_flows`, `mock_deploy`, `base_solutions`, `jfrog_url`, `jfrog_repo`, `run_number`, `run_attempt`, `enable_servicenow`, `solution_list`, `sarif_path`

**ServiceNow inputs:**

| Input | Default | Description |
|---|---|---|
| `enable_servicenow` | `false` | When `true`, calls `servicenow-change` before and after the deploy loop. Driven by `vars.SERVICENOW_ENABLED` from the caller environment. |
| `solution_list` | `''` | Comma-separated solution names for the CR description |
| `sarif_path` | `''` | Solution Checker SARIF path — attached to the CR as an audit trail artifact |

The deploy loop writes `SNOW_DEPLOY_STATUS=success` or `SNOW_DEPLOY_STATUS=failure` to `$GITHUB_ENV` **before** any `exit 1` call, so the post-deploy step always sees the correct status even when the import failed.

---

### `pre-deploy-checks`

**Path:** `.github/actions/dynamics/pre-deploy-checks/action.yml`
**Purpose:** Pre-import validation for a single solution.

Steps:
1. `Invoke-BlockingCheck.ps1` — abort if in-progress async operations in target environment
2. `Compare-SolutionVersion.ps1` — compare artifact version vs installed version

**Inputs:** `solution_name`, `environment_url`, `artifact_version`, `previous_environment_url`, `mock_deploy`

---

### `post-deploy`

**Path:** `.github/actions/dynamics/post-deploy/action.yml`
**Purpose:** Post-import tasks.

Steps:
1. JFrog tag — `Invoke-JFrogAction.ps1 tag-prod` sets `prodDeployed=true;deployedDate={date}` (Prod only)
2. `Write-DeploySummary.ps1` — writes deploy result markdown table to step summary

**Inputs:** `solution_name`, `solution_version`, `environment_name`, `environment_url`, `artifact_name`, `mock_deploy`, `skip_import`, `jfrog_url`, `jfrog_repo`, `run_number`, `run_attempt`

---

### `jfrog-upload`

**Path:** `.github/actions/dynamics/jfrog-upload/action.yml`
**Purpose:** Upload solution ZIPs and SARIF to JFrog Artifactory. Runs once per build (not per environment).

Calls `Invoke-JFrogAction.ps1 upload` with the managed ZIP, unmanaged ZIP, and SARIF. Artifact path in JFrog: `{repo}/{solution_name}/{version}/`

**Inputs:** `solution_name`, `artifact_name`, `unmanaged_zip`, `managed_zip`, `checker_artifact_name`, `jfrog_url`, `jfrog_repo`, `run_number`, `run_attempt`, `mock_deploy`

---

## 4. GHA-Core PowerShell Scripts

All scripts are in `.github/scripts/dynamics/`. On the runner they are at `.ci/.github/scripts/dynamics/` after `reveille` runs. All scripts support mock mode.

### `Resolve-SolutionMatrix.ps1`

**Called by:** `setup` jobs in `build-and-deploy.yml`, `export-solution.yml`, `pr-validation.yml`
**Purpose:** Reads `solutions.json`, sorts by `deployOrder`, builds the GitHub Actions matrix JSON.

Outputs to `$GITHUB_OUTPUT`:
- `matrix` — JSON array for strategy.matrix: `[{"name":"CoreSolution","folder":"src/...","deployOrder":1,...}]`
- `solution_list` — comma-separated display string: `"CoreSolution, ExtensionA, ExtensionB"`
- `solution_count` — integer

---

### `Set-SolutionVersion.ps1`

**Called by:** `pack-solution` action
**Purpose:** Reads `Solution.xml`, extracts `<Version>`, computes new version as `{Major}.{Minor}.{RunNumber}.{Attempt}`, writes it back to `Solution.xml`. Outputs the new version string to `$GITHUB_OUTPUT`.

---

### `Remove-ManagedTag.ps1`

**Called by:** `pack-solution` action
**Purpose:** Strips `<Managed>0</Managed>` from `Solution.xml`. PAC CLI 1.40+ rejects a managed pack if the `<Managed>` tag is present, because it conflicts with the `--packageType managed` argument. Source-controlled solutions always have `<Managed>0</Managed>` after an unpack.

---

### `New-MockSolutionZip.ps1`

**Called by:** `pack-solution` action (mock mode only)
**Purpose:** Creates a minimal valid ZIP containing a stub `Solution.xml`. Used in mock mode to produce realistic-looking output files without running PAC CLI. Both unmanaged and managed ZIPs are produced this way.

---

### `Invoke-SolutionCheckerSim.ps1`

**Called by:** `solution-checker` action (mock mode only)
**Purpose:** Validates the ZIP file structure, generates a mock SARIF file. Produces a realistic checker artifact without connecting to the Power Platform Solution Checker service.

---

### `Export-ConfigDataSim.ps1`

**Called by:** `export-config-data` action (mock mode only)
**Purpose:** Parses the schema XML to verify it is well-formed, then creates a placeholder `config-data/{name}-data.zip`. No connection to a PP environment.

**Parameters:** `-SchemaFile`, `-OutputZipPath`, `-RunNumber`

---

### `Invoke-ExportCommitSim.ps1`

**Called by:** `export-solution.yml` (mock mode only)
**Purpose:** Simulates the full export-and-commit workflow. Creates stub solution files in `src/solutions/{name}/`, stages them, creates a git commit, pushes to the feature branch. No PAC CLI required.

**Parameters:** `-SolutionName`, `-BranchName`, `-CommitMessagePrefix`, `-CreatePr`

---

### `Invoke-BlockingCheck.ps1`

**Called by:** `pre-deploy-checks` action, `deploy-all-solutions` action
**Purpose:** Uses PAC CLI to query in-progress async operations on the target environment. Exits non-zero if blocking operations found, preventing imports that could create conflicts.

In mock mode: logs a simulated "no blocking operations" result.

---

### `Compare-SolutionVersion.ps1`

**Called by:** `pre-deploy-checks` action, `deploy-all-solutions` action
**Purpose:** Compares the version of the solution in the build artifact against the version currently installed in the target environment. Sets `skip_import=true` if versions match (prevents redundant imports). Can optionally verify the version was already promoted from the previous environment.

In mock mode: simulates the comparison without connecting to PP.

---

### `Merge-Variables.ps1`

**Called by:** `reveille` composite action (at the start of every build and deploy job)
**Purpose:** Reads `GHA-Core/.github/variables/dynamics/global-vars.yml` then `GHA-Dynamics/.github/config/project-vars.yml`. Enforces governance — if a project variable key appears in `protected_keys`, the pipeline fails with a violation report. For non-protected keys, project values override global values. Azure identity keys (`AZURE_*`) are excluded from the merge to prevent shadowing the OIDC-provided identity. Writes all merged key=value pairs to `$GITHUB_ENV`.

**Parameters:** `-GlobalVarsPath`, `-ProjectVarsPath`, `-DryRun` (switch)

---

### `Invoke-JFrogAction.ps1`

**Called by:** `jfrog-upload` action, `post-deploy` action
**Purpose:** Handles two JFrog operations:

- **`upload`** — Uploads managed ZIP, unmanaged ZIP, and SARIF to Artifactory. Sets properties: `solution.name`, `run.number`, `build.timestamp`
- **`tag-prod`** — Sets `prodDeployed=true;deployedDate={ISO-date}` property on an existing artifact in Artifactory (Prod deploy only)

In mock mode: logs what would have been uploaded/tagged without making network calls.

**Parameters:** `-Action`, `-SolutionName`, `-ArtifactName`, `-JFrogUrl`, `-JFrogRepo`, `-RunNumber`, `-RunAttempt`, `-MockDeploy`, `-JFrogToken`

---

### `Write-BuildSummary.ps1`

**Called by:** `_job-build.yml` write-build-summary step
**Purpose:** Writes a markdown table to `$GITHUB_STEP_SUMMARY` summarising the build job: version stamped, pack mode, Solution Checker mode, config data mode, JFrog upload status. Optionally writes a JSON record file for later aggregation by `Write-PipelineSummary.ps1`.

**Parameters:** `-SolutionName`, `-SolutionVersion`, `-ArtifactName`, `-RunNumber`, `-MockDeploy`, `-DataSchemaFile`, `-EnableJFrogUpload`, `-JFrogUrl`, `-JFrogRepo`, `-JsonOutputPath`

---

### `Write-DeploySummary.ps1`

**Called by:** `post-deploy` action, `deploy-all-solutions` action
**Purpose:** Writes a per-solution deploy result table to `$GITHUB_STEP_SUMMARY`: environment, solution version, import outcome, backup status, config data import, flow activation. Includes a note if `skip_import` was set.

**Parameters:** `-SolutionName`, `-SolutionVersion`, `-EnvironmentName`, `-EnvironmentUrl`, `-MockDeploy`, `-SkipImport`

---

### `Write-PipelineSummary.ps1`

**Called by:** `pipeline-summary` jobs in `build-and-deploy.yml` and `pr-validation.yml`
**Purpose:** Aggregates all per-job JSON records from `JobSummariesDir` and writes the final consolidated pipeline summary to `$GITHUB_STEP_SUMMARY`. Shows all solutions, all environments, build results, and deploy results in a single table.

**Parameters:** `-SolutionList`, `-SolutionCount`, `-RunNumber`, `-RefName`, `-CommitSha`, `-ExportResult`, `-BuildResult`, `-DeployResult`, `-JobSummariesDir`

---

## 5. Configuration Files

### `solutions.json`

**Path:** `GHA-Dynamics/solutions.json`
**Purpose:** Single source of truth for solution registry. Read by `Resolve-SolutionMatrix.ps1`.

```json
{
  "solutions": [
    {
      "name": "CoreSolution",             // Unique solution name in PP
      "folder": "src/solutions/CoreSolution",  // Path to unpacked source
      "deployOrder": 1,                   // Sequential deploy position (1 = first)
      "dependsOn": [],                    // Documentation only, no functional effect
      "dataSchemaFile": "config/CoreSolution/data-schema.xml",  // Empty = skip
      "deploymentSettings": {
        "dev":  "deployment-settings/dev/CoreSolution.json",
        "intg": "deployment-settings/intg/CoreSolution.json",
        "uat":  "deployment-settings/uat/CoreSolution.json",
        "frs":  "deployment-settings/frs/CoreSolution.json",
        "perf": "deployment-settings/perf/CoreSolution.json",
        "prod": "deployment-settings/prod/CoreSolution.json"
      }
    }
  ]
}
```

**Rules:**
- Solutions are deployed in ascending `deployOrder` within each environment
- Every solution in `src/solutions/` should have an entry; unlisted solutions are ignored
- `dependsOn` is metadata for documentation — it does NOT control deploy order; use `deployOrder` for that
- `dataSchemaFile: ""` skips config data export/import for that solution

---

### `pipeline-context.json`

**Path:** `GHA-Dynamics/pipeline-context.json`
**Purpose:** Cross-pipeline handoff. Written by Pipeline 1, read by Pipeline 2.

```json
{
  "runId": "123456789",
  "runNumber": "42",
  "runAttempt": "1",
  "solutions": ["CoreSolution", "ExtensionA", "ExtensionB"],
  "solutionList": "CoreSolution, ExtensionA, ExtensionB",
  "matrix": "{\"solution\":[{\"name\":\"CoreSolution\",...}]}",
  "featureBranch": "feature/pipeline-42",
  "triggeredBy": "username",
  "triggeredAt": "2026-05-17T10:30:00Z",
  "exportMode": "real (exported from sandbox)",
  "mockDeploy": false
}
```

**Lifecycle:**
- Pipeline 1's **stage-export commit job** writes this file to the feature branch during the export stage
- When the PR is merged, `pipeline-context.json` lands on `main` as part of the merge commit
- Pipeline 2's `push` trigger fires (paths filter: `pipeline-context.json`)
- Pipeline 2's `read-context` job checks out `main`, parses `runId`, and downloads build artifacts from Pipeline 1

---

## 6. Deployment Settings

### Format

**Path:** `GHA-Dynamics/deployment-settings/{env}/{SolutionName}.json`

```json
{
  "EnvironmentVariables": [
    {
      "SchemaName": "new_ServiceEndpointUrl",
      "Value": "https://api.contoso.com/v1"
    },
    {
      "SchemaName": "new_FeatureToggleEnabled",
      "Value": "true"
    }
  ],
  "ConnectionReferences": [
    {
      "LogicalName": "new_SharedDataverseConnection",
      "ConnectionId": "#{PROD_DataverseConnectionId}#",
      "ConnectorId": "/providers/Microsoft.PowerApps/apis/shared_commondataservice"
    },
    {
      "LogicalName": "new_Office365Connection",
      "ConnectionId": "#{PROD_Office365ConnectionId}#",
      "ConnectorId": "/providers/Microsoft.PowerApps/apis/shared_office365"
    }
  ]
}
```

### Token substitution

Any `Value` containing `#{TOKEN_NAME}#` is replaced at deploy time by `deploy-all-solutions`. The script looks for a GitHub Variable or Secret named `TOKEN_NAME` and substitutes the value.

```json
"ConnectionId": "#{PROD_DataverseConnectionId}#"
```

Store `PROD_DataverseConnectionId` as a GitHub Variable (non-sensitive) or Secret (sensitive) on the GHA-Dynamics repository.

### File resolution

`deploy-all-solutions` resolves the settings file path from `solutions.json` → `deploymentSettings.{env}`. If the file path is empty or the file doesn't exist, the solution is deployed without deployment settings overrides.

---

## 7. Variable Files

### `global-vars.yml`

**Path:** `GHA-Core/.github/variables/dynamics/global-vars.yml`
**Purpose:** Org-wide default variable values and governance. Applied to every pipeline run across all GHA-Dynamics repos. Contains two sections:

- `protected_keys` — keys that project repos (GHA-Dynamics) **cannot** override. Enforced by `Merge-Variables.ps1`.
- `variables` — default values used when no project-level override exists.

```yaml
protected_keys:
  - PP_CHECKER_GEO
  - PP_CHECKER_ERROR_LEVEL
  - DEFAULT_SOLUTION_TYPE
  - ENABLE_BACKUP

variables:
  PP_CHECKER_GEO:         "UnitedStates"
  PP_CHECKER_ERROR_LEVEL: "HighIssue"
  JFROG_REPO:             "powerplatform-solutions"
  DEFAULT_SOLUTION_TYPE:  "managed"
  ENABLE_BACKUP:          "true"
  ENABLE_BLOCKING_CHECK:  "true"
  MOCK_DEPLOY:            "false"
  SOLUTION_IMPORT_MAX_WAIT_MINUTES: "60"
  SOLUTION_CHECKER_TIMEOUT_MINUTES: "10"
  JFROG_UPLOAD_ENABLED:   "true"
```

### `project-vars.yml`

**Path:** `GHA-Dynamics/.github/config/project-vars.yml`
**Purpose:** Project-specific overrides. Values here take precedence over `global-vars.yml` for non-protected keys. Attempting to override a protected key causes a governance violation and the pipeline fails.

```yaml
# project-vars.yml — overrides global-vars.yml (non-protected keys only)
variables:
  SOLUTION_IMPORT_MAX_WAIT_MINUTES: "180"  # override global default of 60
  MY_PROJECT_FEATURE_FLAG: "true"
```

`Merge-Variables.ps1` (called by the `reveille` composite action at the start of every job) merges both files, enforces governance, and writes the result to `$GITHUB_ENV`, making all values available as environment variables for subsequent steps.
