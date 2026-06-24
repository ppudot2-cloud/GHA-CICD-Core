# Pipeline Walkthrough — Complete Step-by-Step Reference
## Every job, every step, every sub-step across both pipelines

> **How to use this document.**  Read top-to-bottom for a full mental walkthrough of a pipeline run.
> Each section is a job. Each numbered item is a named step visible in the GitHub Actions UI.
> Sub-bullets are the internal logic — what the step actually does when it runs.
> The [HTML flow diagram](./gha_cicd_e2e_flow.html) is the visual companion to this document.

---

## Table of Contents

- [Architecture at a Glance](#architecture-at-a-glance)
- [Pipeline 1 — build-and-deploy.yml](#pipeline-1--build-and-deployyml)
  - [Job: 🔍 Setup](#job--setup)
  - [Job: 📤 Export — per solution](#job--export--per-solution-matrix)
  - [Job: 📤 Commit pipeline context](#job--commit-pipeline-context)
  - [Job: 🏗️ Build — per solution](#job--build--per-solution-matrix)
  - [Job: 🏗️ Validate Pipeline Config](#job--validate-pipeline-config)
  - [Job: 🚀 Deploy | Dev](#job--deploy--dev)
  - [Job: 🚀 Deploy | Intg](#job--deploy--intg)
  - [Job: 🚀 Deploy | UAT](#job--deploy--uat)
  - [Job: 🚀 Deploy | FRS](#job--deploy--frs)
  - [Job: 🚀 Deploy | Perf](#job--deploy--perf)
  - [Job: 🔀 Open PR → main](#job--open-pr--main)
  - [Job: 📋 Pipeline Summary](#job--pipeline-summary)
- [Pipeline 2 — deploy-prod.yml](#pipeline-2--deploy-prodyml)
  - [Job: 🛡️ Verify trigger](#job--verify-trigger)
  - [Job: 📖 Read pipeline context](#job--read-pipeline-context)
  - [Job: 🚀 Deploy | UAT (re-validation)](#job--deploy--uat-re-validation)
  - [Job: 🚀 Deploy | Prod](#job--deploy--prod)
  - [Job: 📋 Pipeline 2 Summary](#job--pipeline-2-summary)
- [Shared Action Reference: Reveille](#shared-action-reference-reveille)
- [Shared Action Reference: Deploy All Solutions](#shared-action-reference-deploy-all-solutions)
- [Shared Action Reference: ServiceNow CR Lifecycle](#shared-action-reference-servicenow-cr-lifecycle)

---

## Architecture at a Glance

```
PIPELINE 1 — build-and-deploy.yml
═══════════════════════════════════════════════════════════════════════

  TRIGGER
  ├── push to feature/**  (paths-ignore: pipeline-context.json)
  └── workflow_dispatch   (inputs: solutions, skip_export, mock_deploy,
                           checker_error_level, base_solutions)

  JOBS (sequential unless noted)
  ┌─────────────────────────────────────────────────────────────────┐
  │  🔍 SETUP                                                       │
  │  Resolve solution matrix (topo sort)  •  Check secret presence │
  └────────────────────────────┬────────────────────────────────────┘
                               │
  ┌────────────────────────────▼────────────────────────────────────┐
  │  📤 STAGE-EXPORT                                                │
  │  ┌──────────────────────────────────────────────────────────┐  │
  │  │  Export | SolutionA  │  Export | SolutionB  │  …        │  │  ← parallel (skipped when skip_export)
  │  └──────────────────────────────────────────────────────────┘  │
  │  📤 Commit pipeline context                                    │  ← always runs
  └────────────────────────────┬────────────────────────────────────┘
                               │
  ┌────────────────────────────▼────────────────────────────────────┐
  │  🏗️ STAGE-BUILD                                                 │
  │  ┌──────────────────────────────────────────────────────────┐  │
  │  │  Build | SolutionA  │  Build | SolutionB  │  …         │  │  ← parallel
  │  └──────────────────────────────────────────────────────────┘  │
  │  🏗️ Validate Pipeline Config                                   │  ← runs after ALL builds pass
  └────────────────────────────┬────────────────────────────────────┘
                               │
  ┌────────────────────────────▼────────────────────────────────────┐
  │  🚀 STAGE-DEPLOY  (_stage-deploy-chain.yml — single call)      │
  │                                                                 │
  │  5 environment jobs start simultaneously (all gates open):     │
  │  ┌────────┐  ┌────────┐  ┌────────┐  ┌────────┐  ┌────────┐  │
  │  │  Dev   │  │  Intg  │  │  UAT   │  │  FRS   │  │  Perf  │  │
  │  └────────┘  └────────┘  └──┬─────┘  └────────┘  └────────┘  │
  │                              │ UAT success only                │
  │                    ┌─────────▼──────────┐                      │
  │                    │  🔀 Open PR → main │  ← inside chain;    │
  │                    └────────────────────┘    FRS/Perf continue │
  └─────────────────────────────────────────────────────────────────┘
  📋 Pipeline Summary  (if: always())


PIPELINE 2 — deploy-prod.yml
═══════════════════════════════════════════════════════════════════════

  TRIGGER
  ├── push to main where pipeline-context.json changed  (PR merge)
  └── workflow_dispatch   (inputs: mock_deploy, enable_backup)

  JOBS
  ┌────────────────────────────────────────────────────────────────┐
  │  🛡️ Verify trigger                                             │
  └────────────────────────┬───────────────────────────────────────┘
                           │
  ┌────────────────────────▼───────────────────────────────────────┐
  │  📖 Read pipeline context   (parse pipeline-context.json)      │
  └────────────────────────┬───────────────────────────────────────┘
                           │
  ┌────────────────────────▼───────────────────────────────────────┐
  │  🚀 Deploy | UAT  (re-validation gate)                         │
  └────────────────────────┬───────────────────────────────────────┘
                           │ UAT success only
  ┌────────────────────────▼───────────────────────────────────────┐
  │  🚀 Deploy | Prod  (requires Prod environment approval)        │
  └────────────────────────────────────────────────────────────────┘
  📋 Pipeline 2 Summary  (if: always())
```

**Key rules:**
- Solutions are deployed **in parallel across environments** but **sequentially within each environment** (Dataverse cannot process concurrent imports to the same org)
- Only `GHA_CORE_PAT` lives as a GitHub Secret — all PP/JFrog/ServiceNow credentials live in Azure Key Vault and are fetched at runtime via OIDC
- `mock_deploy=true` runs every step of every job but makes no Dataverse, Azure, or JFrog calls

---

## Pipeline 1 — build-and-deploy.yml

---

### Job: 🔍 Setup

**Runs on:** `ubuntu-latest`
**Purpose:** Resolve which solutions to build and deploy; check whether required secrets are present.
**Outputs:** `matrix`, `solution_list`, `solution_count`, `pp_app_id_set`, `pp_secret_set`, `pp_tenant_set`, `gha_core_pat_set`

#### Step 1 — Checkout repository
- `actions/checkout@v4` with `fetch-depth: 0` (full history)
- Checks out the GHA-Dynamics repo (the calling repo) onto the runner

#### Step 2 — Checkout GHA-CICD-Core CI scripts
- `actions/checkout@v4` targeting `ppudot2-cloud/GHA-CICD-Core` at `ref: main`
- Authenticated via `secrets.GHATOKEN`
- Checks out to path `.ci/` in the runner workspace
- Provides all PowerShell scripts, composite actions, global-vars.yml, and the ServiceNow module

#### Step 3 — Resolve solution matrix
- Calls `.ci/.github/scripts/dynamics/Resolve-SolutionMatrix.ps1`
- **Input:** `-InputSolutions` (from `inputs.solutions`, defaults to `'all'` via `|| 'all'` fallback if empty)
- **Input:** `-PpSolutionName` (from `vars.PP_SOLUTION_NAME` — for single-solution repos that don't use solutions.json)
- **Input:** `-SolutionsJsonPath 'solutions.json'`
- **What it does:**
  - Reads `solutions.json` from the GHA-Dynamics workspace
  - Validates requested solution names exist in the registry
  - Sorts by `deployOrder` (ascending)
  - Builds a GitHub Actions matrix JSON: `{"solution":[{"name":"CoreSolution","source_folder":"src/solutions/CoreSolution","deployOrder":1,...},...]}`
- **Outputs to `$GITHUB_OUTPUT`:**
  - `matrix` — JSON matrix string for `strategy.matrix` in build/deploy jobs
  - `solution_list` — comma-separated display string (e.g. `"CoreSolution, ExtensionA"`)
  - `solution_count` — integer count

#### Step 4 — Check credential presence
- Evaluates `secrets.*` references inside a `run:` step — the only place GitHub allows `secrets.*` to be read
- **Why:** `vars.*` and `secrets.*` cannot cross the reusable-workflow boundary; secrets must be pre-evaluated in the caller and passed as boolean inputs
- Checks `PP_APP_ID`, `PP_CLIENT_SECRET`, `PP_TENANT_ID`, `GHA_CORE_PAT` — writes `true`/`false` strings to `$GITHUB_OUTPUT`
- These flags are consumed by the Validate Pipeline Config job later in stage-build

---

### Job: 📤 Export — per solution (matrix)

**Defined in:** `GHA-CICD-Core/_stage-export.yml` → `jobs.export`
**Runs on:** `ubuntu-latest` (one runner per solution, in parallel)
**Condition:** `if: !inputs.skip_export` — skipped entirely when `skip_export=true` or triggered by push to `feature/**`
**Purpose:** Export the unmanaged solution from the Power Platform sandbox, unpack it, and upload the source tree as a GitHub artifact for the build stage to consume.

#### Step 1 — Reveille
Full details in [Shared Action Reference: Reveille](#shared-action-reference-reveille).
At this stage: `jfrog_enabled=false` (build hasn't run yet, no upload needed), `servicenow_enabled=false`.

#### Step 2 — Install PAC CLI
- Calls `ppudot2-cloud/GHA-CICD-Core/.github/actions/dynamics/pac-install@main`
- Runs `microsoft/powerplatform-actions/actions-install@v1`
- Adds PAC CLI to `$PATH` so subsequent steps can call `pac solution export`

#### Step 3 — Export Solution
- Calls `ppudot2-cloud/GHA-CICD-Core/.github/actions/dynamics/export-solution@main`
- **Real mode:** `pac solution export --name <solution_name> --path export-src/<name>.zip --environment <PP_SDBX_URL>`
  - Exports the unmanaged ZIP from the sandbox
  - Runs `pac solution unpack --zipfile export-src/<name>.zip --folder export-src/<name>/ --packageType Unmanaged`
  - Unpacks the ZIP into the versioned source tree
- **Mock mode:** logs what would have been exported; produces a stub source tree

#### Step 4 — Upload exported source
- `actions/upload-artifact@v4`
- **Artifact name:** `exported-source-<solution_name>`
- **Path:** `export-src/<solution_name>/` (the unpacked source tree)
- **Retention:** 1 day (short-lived; only needed within this pipeline run)
- The build stage downloads this artifact if `use_exported_source=true`

---

### Job: 📤 Commit pipeline context

**Defined in:** `GHA-CICD-Core/_stage-export.yml` → `jobs.commit`
**Condition:** `if: always() && (needs.export.result == 'success' || needs.export.result == 'skipped')`
**Runs on:** `ubuntu-latest`
**Purpose:** Create the feature branch (normal mode) or write to the existing branch (skip_export mode), copy exported sources, and write `pipeline-context.json` so Pipeline 2 can locate these build artifacts.

#### Step 1 — Checkout repository (full history)
- `actions/checkout@v4` with `fetch-depth: 0` and `token: secrets.GITHUB_TOKEN`
- Full history needed to create a branch from origin/main

#### Step 2 — Download all exported source artifacts
- **Condition:** `if: inputs.skip_export != true`
- `actions/download-artifact@v4` with `pattern: exported-source-*`
- Downloads all per-solution exported source artifacts into `_export-src/`

#### Step 3 — Commit source + write pipeline-context.json + push
**Normal mode (`skip_export=false`):**
1. `git config user.name/email` → set committer identity to `GitHub Actions`
2. `git fetch origin main`
3. `git checkout -b feature/pipeline-{run_number} origin/main` → creates fresh branch from main
4. For each solution: copies `_export-src/exported-source-<name>/` → `src/solutions/<name>/`
5. For each solution: writes `.pipeline-export.json` marker file inside the solution folder (contains runId, runNumber, exportMode, exportedAt, sandboxUrl)
6. Removes `_export-src/` staging folder
7. Writes `pipeline-context.json` to the workspace root (see fields below)
8. `git add src/solutions/ pipeline-context.json`
9. `git commit -m "chore: sandbox export — pipeline run #N [skip ci]"`
10. `git push origin feature/pipeline-{run_number}` (plain push, new branch)

**Skip-export mode (`skip_export=true` or push-triggered):**
1. Sets `$branch` to the current branch name (`github.ref_name`)
2. `git fetch origin`
3. Writes `pipeline-context.json` only
4. `git add pipeline-context.json`
5. `git commit -m "chore: manual export — pipeline run #N [skip ci]"` (if file changed)
6. `git push origin HEAD --force-with-lease` (existing branch, safe force)

**`pipeline-context.json` fields written:**
```json
{
  "runId":         "<github.run_id>",
  "runNumber":     "<github.run_number>",
  "runAttempt":    "<github.run_attempt>",
  "solutions":     ["CoreSolution", "ExtensionA"],
  "solutionList":  "CoreSolution, ExtensionA",
  "matrix":        "{\"solution\":[...]}",
  "featureBranch": "feature/pipeline-42",
  "triggeredBy":   "username",
  "triggeredAt":   "2026-05-18T10:30:00Z",
  "exportMode":    "real (exported from sandbox)",
  "mockDeploy":    false
}
```

---

### Job: 🏗️ Build — per solution (matrix)

**Defined in:** `GHA-CICD-Core/_stage-build.yml` → `jobs.build` → calls `_job-build.yml`
**Runs on:** `ubuntu-latest` (one runner per solution, in parallel via `strategy.matrix`)
**Purpose:** Version-stamp, pack, Solution Checker, config-data export, upload to GitHub artifacts, archive to JFrog.

#### Step 1 — Reveille
Full details in [Shared Action Reference: Reveille](#shared-action-reference-reveille).
`jfrog_enabled=true` if `JFROG_URL` is set (API key needed for JFrog upload step).

#### Step 2 — Install PAC CLI
- Same as export job — installs PAC CLI to `$PATH`

#### Step 3 — Download exported source artifact
- **Condition:** `if: inputs.use_exported_source == true`
- `actions/download-artifact@v4` targeting `exported-source-<solution_name>`
- Downloads to `export-src/<solution_name>/`
- Only runs in normal (sandbox export) mode; skipped in skip_export / push-triggered mode

#### Step 4 — Resolve source folder
- Shell: `bash`
- If `use_exported_source=true`: sets `folder=export-src/<solution_name>`
- Otherwise: sets `folder=<solution_source_folder>` (committed source, e.g. `src/solutions/CoreSolution`)
- Outputs `folder` to `$GITHUB_OUTPUT`

#### Step 5 — Pack Solution
Calls `ppudot2-cloud/GHA-CICD-Core/.github/actions/dynamics/pack-solution@main`. Internal steps:

**5a — Read solution version** (`Set-SolutionVersion.ps1`)
- Reads `<source_folder>/Other/Solution.xml`
- Extracts `<Version>Major.Minor.Build.Revision</Version>`
- Computes new version: `Major.Minor.{run_number}.{run_attempt}`
- Writes new version back to `Solution.xml`
- Outputs `version` to `$GITHUB_OUTPUT`

**5b — Set artifact and ZIP names**
- Computes all output paths deterministically from solution name + version + run number:
  - `out_dir` = `out/<solution_name>/`
  - `unmanaged_zip` = `out/<name>/<name>-<version>_unmanaged.zip`
  - `managed_zip` = `out/<name>/<name>-<version>_managed.zip`
  - `artifact_name` = `solution-<name>-run<run_number>` (or `-a<attempt>` if retry)
  - `checker_artifact_name` = `SolutionChecker-<name>-run<run_number>`
- Creates output directories: `out/<name>/`, `out/<name>/solution-checker/`, `out/<name>/config/`

**5c — Strip Managed tag** (`Remove-ManagedTag.ps1`)
- Removes `<Managed>0</Managed>` from `Solution.xml`
- Required because PAC CLI 1.40+ rejects `--packageType managed` when the tag is present
- Source-controlled solutions always have this tag after `pac solution unpack`

**5d — Pack Unmanaged ZIP**
- **Real mode:** `microsoft/powerplatform-actions/pack-solution@v1` with `solution-type: Unmanaged`
- **Mock mode:** `New-MockSolutionZip.ps1` creates a minimal valid ZIP with stub `Solution.xml`

**5e — Pack Managed ZIP**
- **Real mode:** `microsoft/powerplatform-actions/pack-solution@v1` with `solution-type: Managed`
- **Mock mode:** Second call to `New-MockSolutionZip.ps1` with `PackageType: Managed`

#### Step 6 — Solution Checker
Calls `ppudot2-cloud/GHA-CICD-Core/.github/actions/dynamics/solution-checker@main`. Internal steps:

**6a — Run Solution Checker — Real** (`if: mock_deploy != 'true'`)
- `microsoft/powerplatform-actions/check-solution@v1`
- Inputs: `app-id` (PP_APP_ID), `client-secret` (PP_CLIENT_SECRET), `tenant-id` (PP_TENANT_ID)
- `path`: unmanaged ZIP
- `geo: UnitedStates`
- `fail-on-analysis-error: true`
- `error-level`: from `checker_error_level` input (default `HighIssue`)
- Uploads checker report to GitHub artifact `<checker_artifact_name>`
- **Fails the build** if issues at or above `error-level` are found

**6b — Copy checker report to output folder** (`if: mock_deploy != 'true'`)
- Searches `$RUNNER_TEMP`, `$GITHUB_WORKSPACE`, and `.` for `*.sarif` / `*.sarif.json` files
- Copies all found files to `out/<name>/solution-checker/`
- If no SARIF found: writes a placeholder `checker-summary.txt` with a notice

**6c — Run Solution Checker — Simulation** (`if: mock_deploy == 'true'`)
- `Invoke-SolutionCheckerSim.ps1`
- Validates the ZIP file structure
- Generates a mock SARIF file in `out/<name>/solution-checker/`
- No PP connection required

#### Step 7 — Export Config Data
Calls `ppudot2-cloud/GHA-CICD-Core/.github/actions/dynamics/export-config-data@main`
- **Skipped if** `data_schema_file` input is empty
- **Real mode:** `microsoft/powerplatform-actions/export-data@v1` using the schema XML; outputs `config-data/<name>-data.zip`
- **Mock mode:** `Export-ConfigDataSim.ps1` — validates schema XML well-formedness, creates placeholder ZIP

#### Step 8 — Upload solution artifact for deploy
- `actions/upload-artifact@v4`
- **Artifact name:** `solution-artifact-<solution_name>`
- **Path:** `out/<name>/` + `config-data/<name>-data.zip`
- **Retention:** 7 days (long enough to cover multi-day approval chains)
- **Consumer:** All 5 deploy jobs download this artifact before calling `deploy-all-solutions`

#### Step 9 — JFrog Upload
- **Condition:** `if: inputs.jfrog_url != ''` (skipped if JFrog not configured)
- Calls `ppudot2-cloud/GHA-CICD-Core/.github/actions/dynamics/jfrog-upload@main`
- Calls `Invoke-JFrogAction.ps1 upload`
- Uploads managed ZIP, unmanaged ZIP, and SARIF to Artifactory path `{repo}/{name}/{version}/`
- Sets artifact properties: `solution.name`, `run.number`, `build.timestamp`
- **Mock mode:** logs what would have been uploaded; no network calls

#### Step 10 — Write build summary
- **Condition:** `if: always()` (writes summary even on failure)
- Calls `Write-BuildSummary.ps1`
- Writes markdown table to `$GITHUB_STEP_SUMMARY`: solution name, version, artifact name, run number, mock flag, config-data status, JFrog status
- Records a JSON file for later aggregation by `Write-PipelineSummary.ps1`

---

### Job: 🏗️ Validate Pipeline Config

**Defined in:** `GHA-CICD-Core/_stage-build.yml` → `jobs.validate`
**Condition:** `if: needs.build.result == 'success'` — runs after ALL build jobs pass
**Purpose:** Print all pipeline toggles, environment URLs, and secret/service-connection status to the GitHub Actions log and step summary.

#### Step 1 — Print toggles and validate config
- Prints a formatted table to stdout and `$GITHUB_STEP_SUMMARY`:
  - **Toggles:** `mock_deploy`, `enable_backup`, `checker_error_level`, `base_solutions`
  - **Solutions:** count and list
  - **Environment URLs:** Sandbox, Dev, Intg, UAT, FRS, Perf, Prod — ✅ set or ❌ NOT SET
  - **Service connections:** PP_APP_ID, PP_CLIENT_SECRET, PP_TENANT_ID, GHA_CORE_PAT — status flags (pre-evaluated in Setup job)
  - **JFrog:** URL and repo if set, otherwise warns archival is disabled
- **Fails the pipeline** in non-mock mode if any required secret or environment URL is missing

---

### Job: 🚀 Deploy | Dev

**Trigger:** starts as soon as `stage-build` succeeds (no approval gate by default)
**Environment:** `Dev` (GitHub Environment)
**Solution type:** `Unmanaged` — Dev is the only environment that receives an unmanaged import, so makers can continue editing solutions without a managed-layer lock
**Options:** `enable_blocking_check=false`, `enable_version_compare=false`, `import_config_data=false`

#### Step 1 — Reveille
Full details in [Shared Action Reference: Reveille](#shared-action-reference-reveille).

#### Step 2 — Install PAC CLI
Installs Power Platform CLI and adds to `$PATH`.

#### Step 3 — Download solution artifacts
- `actions/download-artifact@v4`
- `pattern: solution-artifact-*` — downloads all per-solution artifacts
- `merge-multiple: true` — all artifacts merged into the workspace root
- `run-id: github.run_id` — downloads from the current (Pipeline 1) run
- After this step: `out/<name>/` directories and `config-data/<name>-data.zip` files are present in the workspace

#### Step 4 — Deploy all solutions → Dev
Full details in [Shared Action Reference: Deploy All Solutions](#shared-action-reference-deploy-all-solutions).

**Dev-specific settings:**
- `solution_type: Unmanaged`
- `enable_blocking_check: false` (Dev is fast-cycle; blocking checks slow iteration)
- `enable_version_compare: false` (always re-import in Dev, even if version unchanged)
- `import_config_data: false`
- `previous_environment_url: ''` (no previous environment check)

---

### Job: 🚀 Deploy | Intg

**Environment:** `Intg` — parallel to Dev, UAT, FRS, Perf
**Solution type:** `Managed`
**Options:** `enable_blocking_check=true`, `enable_version_compare=false`, `import_config_data=false`

#### Steps 1–3
Identical to Dev: Reveille → Install PAC CLI → Download solution artifacts.

#### Step 4 — Deploy all solutions → Intg
**Intg-specific settings:**
- `solution_type: Managed`
- `enable_blocking_check: true` — checks for in-progress async operations before importing
- `enable_version_compare: false`
- `previous_environment_url: PP_DEV_URL` — Intg is the first managed environment after Dev

---

### Job: 🚀 Deploy | UAT

**Environment:** `UAT` — recommended to have Required Reviewers configured
**Solution type:** `Managed`
**Options:** `enable_blocking_check=true`, `enable_version_compare=true`, `import_config_data=false`
**Note:** UAT success gates the `create-pr` job inside `_stage-deploy-chain.yml`. FRS and Perf run independently and do not block PR creation.

#### Steps 1–3
Identical to Dev: Reveille → Install PAC CLI → Download solution artifacts.

#### Step 4 — Deploy all solutions → UAT
**UAT-specific settings:**
- `solution_type: Managed`
- `enable_blocking_check: true`
- `enable_version_compare: true` — compares artifact version against installed version in UAT. Uses `PP_INTG_URL` as the `previous_environment_url` to verify promotion.
- `import_config_data: false`
- `previous_environment_url: PP_INTG_URL`
- `servicenow_enabled: vars.SERVICENOW_ENABLED == 'true'` — full CR lifecycle if enabled

---

### Job: 🚀 Deploy | FRS

**Environment:** `FRS` — parallel to Dev, Intg, UAT, Perf
**Solution type:** `Managed`
**Options:** `enable_blocking_check=true`, `enable_version_compare=true`

#### Steps 1–3
Identical to Dev: Reveille → Install PAC CLI → Download solution artifacts.

#### Step 4 — Deploy all solutions → FRS
**FRS-specific settings:**
- `previous_environment_url: PP_UAT_URL`
- `enable_version_compare: true`
- `servicenow_enabled: vars.SERVICENOW_ENABLED == 'true'`

---

### Job: 🚀 Deploy | Perf

**Environment:** `Perf` — parallel to Dev, Intg, UAT, FRS
**Solution type:** `Managed`
**Options:** `enable_blocking_check=true`, `enable_version_compare=true`

#### Steps 1–3
Identical to Dev: Reveille → Install PAC CLI → Download solution artifacts.

#### Step 4 — Deploy all solutions → Perf
**Perf-specific settings:**
- `previous_environment_url: PP_FRS_URL`
- `enable_version_compare: true`
- `servicenow_enabled: vars.SERVICENOW_ENABLED == 'true'`

---

### Job: 🔀 Open PR → main

**Defined in:** `GHA-CICD-Core/_stage-deploy-chain.yml` → `jobs.create-pr` (runs **inside** the deploy chain, not as a separate job in `build-and-deploy.yml`)
**Condition:** `inputs.feature_branch != '' && needs.deploy-uat.result == 'success'`
**Purpose:** Create the PR that triggers Pipeline 2. Merging this PR lands `pipeline-context.json` on main, which fires `deploy-prod.yml`.

**Why it lives inside `_stage-deploy-chain.yml`:** GitHub Actions `needs:` at the caller level waits for all internal jobs of a reusable workflow to finish before a downstream job can start. If `create-pr` were a separate job in `build-and-deploy.yml` with `needs: [stage-deploy]`, it would have to wait for Dev, Intg, UAT, FRS, and Perf to all complete. Moving it inside the chain gives it a direct `needs: [deploy-uat]` dependency — it fires the moment UAT passes while FRS and Perf continue running in parallel.

#### Step 1 — Create PR feature → main
- Uses `GHA_CORE_PAT` (exposed as `GH_TOKEN`) to bypass the "Actions cannot create PRs" repository restriction
- `gh pr create --repo <repo> --head <feature_branch> --base <pr_base_branch>`
- **PR title:** `Release: pipeline run #N` (prefixed with `[MOCK]` if `pr_mock_deploy=true`)
- **PR body:** includes run link, branch, solution list, actor, mock flag, and a gate status checklist (`Dev ✅`, `Intg ✅`, `UAT ✅`, `FRS: running in parallel`, `Perf: running in parallel`)
- Logs the created PR URL to the Actions log
- Skipped entirely when `feature_branch` input is empty (Pipeline 2 and ad-hoc callers don't pass this input)

---

### Job: 📋 Pipeline Summary

**Condition:** `if: always()` — runs regardless of any job result
**Purpose:** Write the consolidated pipeline summary to GitHub Actions step summary and send a failure email if any stage failed.

#### Step 1 — Checkout repository
Standard checkout of GHA-Dynamics.

#### Step 2 — Checkout GHA-CICD-Core CI scripts
Checks out GHA-CICD-Core to `.ci/` to access `Write-PipelineSummary.ps1`.

#### Step 3 — Download job summary records
- `actions/download-artifact@v4` with `pattern: job-summary-*`
- `continue-on-error: true` (no failure if no summaries were uploaded)
- Downloads per-job JSON records produced by `Write-BuildSummary.ps1` into `job-summaries/`

#### Step 4 — Write pipeline summary
- Calls `Write-PipelineSummary.ps1`
- Aggregates all per-job JSON records from `job-summaries/`
- Writes a consolidated markdown table to `$GITHUB_STEP_SUMMARY`: all solutions × all environments, build results, deploy results, run metadata

#### Step 5 — Send failure notification
- **Condition:** any of export/build/dev/intg/uat/frs/perf result == `'failure'`
- `dawidd6/action-send-mail@v3`
- Sends email to `ppudot1@gmail.com` with subject `❌ Build and Deploy FAILED`
- Body includes repo, branch, actor, per-stage results, solution list, run URL

---

## Pipeline 2 — deploy-prod.yml

---

### Job: 🛡️ Verify trigger

**Purpose:** Log what fired this pipeline. No gating logic — the `push + paths` trigger on `pipeline-context.json` is the gate.

#### Step 1 — Confirm trigger
- If `push` event: logs `pipeline-context.json pushed to main` and the commit SHA and actor
- If `workflow_dispatch`: logs `Manual dispatch by @<actor>`

---

### Job: 📖 Read pipeline context

**Needs:** `guard`
**Outputs:** `run_id`, `run_number`, `run_attempt`, `matrix`, `solution_list`

#### Step 1 — Checkout main (merge commit)
- `actions/checkout@v4` with `ref: main`, `fetch-depth: 1`
- Checks out the state of main after the PR merge — this is where `pipeline-context.json` now lives

#### Step 2 — Parse pipeline-context.json
- Reads `pipeline-context.json` from the workspace
- **Fails immediately** if file is not found (means Pipeline 1 never completed or the PR was created manually)
- Logs all context fields: runId, runNumber, runAttempt, solutionList, featureBranch, triggeredBy
- Writes all parsed values to `$GITHUB_OUTPUT`:
  - `run_id` → used by deploy jobs to download artifacts from the correct Pipeline 1 run
  - `run_number`, `run_attempt` → passed into deploy-all-solutions for artifact naming
  - `matrix` → solution list in matrix format
  - `solution_list` → display string for logging and summaries

---

### Job: 🚀 Deploy | UAT (re-validation)

**Needs:** `read-context`
**Environment:** `UAT` (with Required Reviewers = final validation gate before Prod)
**Purpose:** Re-deploy UAT using the same artifacts from Pipeline 1. Ensures the build that is about to go to Prod is still healthy and approved by UAT gate owners.

#### Steps 1–3
Identical to Pipeline 1 deploy jobs. Key difference: `run-id` in the download-artifact step uses `needs.read-context.outputs.run_id` — downloads artifacts from the **original Pipeline 1 run**, not from this Pipeline 2 run.

#### Step 4 — Deploy all solutions → UAT
Same configuration as Pipeline 1's UAT deploy. `run_number` and `run_attempt` passed from `read-context` outputs (the Pipeline 1 values) so artifact names match.

---

### Job: 🚀 Deploy | Prod

**Needs:** `read-context`, `deploy-uat`
**Condition:** `needs.deploy-uat.result == 'success'`
**Environment:** `Prod` — **Required Reviewers must be configured here.** GitHub pauses the job until a named reviewer approves.

#### Steps 1–3
Identical to other deploy jobs. Downloads from Pipeline 1 run via `needs.read-context.outputs.run_id`.

#### Step 4 — Deploy all solutions → Prod
**Prod-specific settings that differ from all other environments:**
- `solution_type: Managed`
- `enable_blocking_check: true`
- `enable_version_compare: true`
- `import_config_data: true` — Prod is the only environment where config migration data is imported during deployment
- `previous_environment_url: PP_PERF_URL`
- `tag_prod_deployed: true` — after successful import, calls `Invoke-JFrogAction.ps1 tag-prod` to set `prodDeployed=true;deployedDate=<ISO>` on the JFrog artifact
- `servicenow_enabled: vars.SERVICENOW_ENABLED == 'true'` — full CR lifecycle if enabled on Prod environment

---

### Job: 📋 Pipeline 2 Summary

**Condition:** `if: always() && needs.read-context.result != 'skipped'`

#### Step 1 — Write summary
- Writes a markdown table to `$GITHUB_STEP_SUMMARY` with: Pipeline 1 run number, solution list, UAT result, Prod result, actor

#### Step 2 — Send failure notification
- **Condition:** `needs.deploy-uat.result == 'failure' || needs.deploy-prod.result == 'failure'`
- `dawidd6/action-send-mail@v3`
- Email subject: `❌ UAT/Prod Deployment FAILED (Pipeline 2) — run #N`
- Body includes Pipeline 1 run number, solution list, UAT/Prod results, actor, run URL

---

## Shared Action Reference: Reveille

**Path:** `.github/actions/dynamics/reveille/action.yml`
**Called by:** Every deploy job and every build job as their very first step.
**Purpose:** Wake the runner — get it bootstrapped, authenticated, and configured with all secrets and variables before any work begins.

### Internal steps (in order)

#### 1 — Checkout calling repository
- `actions/checkout@v4` with `fetch-depth: 0`
- Checks out the GHA-Dynamics repo so scripts can access `solutions.json`, `deployment-settings/`, etc.

#### 2 — Checkout GHA-CICD-Core CI scripts
- `actions/checkout@v4` targeting `ppudot2-cloud/GHA-CICD-Core@main`
- Authenticated via `env.GHA_CORE_PAT` (callers must expose this secret via `env: GHA_CORE_PAT`)
- **Path:** `.ci/` in the workspace
- Makes available:
  - `.ci/.github/scripts/dynamics/` — all 14 PowerShell scripts
  - `.ci/.github/variables/dynamics/global-vars.yml`
  - `.ci/.github/servicenow/` — ServiceNow PS module

#### 3 — Azure Login (OIDC)
- **Condition:** `if: inputs.mock_deploy != 'true'`
- `azure/login@v2` with `client-id`, `tenant-id`, `subscription-id`
- Uses OIDC (Workload Identity Federation) — no client secret stored in GitHub
- GitHub issues a short-lived JWT → Azure AD validates against the Federated Identity Credential → issues a temporary access token
- The token is valid only for the duration of the runner job

#### 4 — Fetch secrets from Azure Key Vault
- **Condition:** `if: inputs.mock_deploy != 'true'`
- Runs `az keyvault secret show --vault-name <kv> --name <secret>` for each required secret
- **Always fetched (PP credentials):**
  - `pp-app-id` → `PP_APP_ID` in `$GITHUB_ENV`
  - `pp-client-secret` → `PP_CLIENT_SECRET` in `$GITHUB_ENV`
  - `pp-tenant-id` → `PP_TENANT_ID` in `$GITHUB_ENV`
- **Fetched when `jfrog_enabled=true`:**
  - `jfrog-api-key` → `JFROG_TOKEN` in `$GITHUB_ENV`
- **Fetched when `mulesoft_enabled=true`:**
  - `mulesoft-client-id` → `MULESOFT_CLIENT_ID` in `$GITHUB_ENV`
  - `mulesoft-client-secret` → `MULESOFT_CLIENT_SECRET` in `$GITHUB_ENV`
- **Fetched when `servicenow_enabled=true`:**
  - `snow-base-uri` → `SERVICENOWMURI` in `$GITHUB_ENV`
  - `snow-oauth-client-id` → `SNOW_OAUTH_CLIENT_ID` in `$GITHUB_ENV`
  - `snow-oauth-client-secret` → `SNOW_OAUTH_CLIENT_SECRET` in `$GITHUB_ENV`
- Each fetched value is masked (`::add-mask::`) before writing to `$GITHUB_ENV` — it never appears in logs

#### 5 — Merge global and project variables
- Calls `Merge-Variables.ps1 -GlobalVarsPath .ci/.github/variables/dynamics/global-vars.yml -ProjectVarsPath .github/config/project-vars.yml`
- **What it does:**
  - Reads `global-vars.yml` (org-wide defaults from GHA-CICD-Core)
  - Reads `project-vars.yml` (project overrides from GHA-Dynamics)
  - Checks each project key against `protected_keys` list — **fails immediately if a project attempts to override a protected key**
  - Merges: project values override global values for non-protected keys
  - Azure identity keys (`AZURE_*`) excluded from merge (OIDC already set them)
  - Writes all merged `KEY=value` pairs to `$GITHUB_ENV`
- Result: subsequent steps see all pipeline variables as plain environment variables

#### 6 — Register JFrog as default PS module repository
- **Condition:** `if: mock_deploy != 'true' && jfrog_enabled == 'true'`
- Unregisters `PSGallery` (agents have no internet access in restricted environments)
- Registers JFrog Artifactory NuGet v2 feed as a trusted PowerShell repository named `"JFrog"`
- Uses `JFROG_TOKEN` and `JFROG_URL` + `JFROG_REPO` (set in step 4 and 5)
- From this point, any `Install-Module` calls resolve from JFrog instead of the public gallery

---

## Shared Action Reference: Deploy All Solutions

**Path:** `.github/actions/dynamics/deploy-all-solutions/action.yml`
**Called by:** Every deploy job (Dev, Intg, UAT, FRS, Perf, Prod) as their final step.
**Pre-conditions:** `reveille`, `pac-install`, and `download-artifact` must have already run.
**Purpose:** Deploy every solution in `solutions_json` to ONE environment, in `deployOrder` sequence.

### Pre-loop steps

#### ServiceNow — Pre-Deploy (Open CR + Approval Gate)
- **Condition:** `if: inputs.enable_servicenow == 'true'`
- Calls `servicenow-change@main` with `phase: pre-deploy`
- See [Shared Action Reference: ServiceNow CR Lifecycle](#shared-action-reference-servicenow-cr-lifecycle)
- **This step blocks the pipeline** until the SNOW change request is approved

#### PAC auth
- **Real mode:** `pac auth create --name target-<env> --url <env_url> --applicationId PP_APP_ID --clientSecret PP_CLIENT_SECRET --tenant PP_TENANT_ID`
  - Creates a named PAC auth profile for the target environment
  - `pac auth select --name target-<env>` activates it
- **Mock mode:** logs `[MOCK] Skipping PAC auth` and continues

### Per-solution deploy loop (for each solution in deployOrder)

All steps run inside a `try/catch` block. On exception, the catch block runs inline rollback (if `enable_backup=true` and a backup was taken) and re-throws.

#### Step 1 — Verify artifact present
- **Real:** checks `out/<name>/<name>-<version>_managed.zip` exists on disk
- Managed ZIP was downloaded by `actions/download-artifact` before this action ran
- **Fails immediately** with a descriptive error if ZIP is missing
- **Mock:** creates placeholder directory and stub ZIP file

#### Step 2 — Resolve deployment settings tokens
- Reads `deployment-settings/<env_lower>/<name>.json` (e.g. `deployment-settings/uat/CoreSolution.json`)
- Scans for `#{TOKEN_NAME}#` patterns using regex
- For each match: reads `$env:TOKEN_NAME` from the runner environment
- Replaces tokens in-memory; writes resolved JSON to `out/<name>/deployment-settings-resolved.json`
- **If no settings file:** sets resolved path to empty (import runs without settings)
- **Mock:** skips token resolution

#### Step 3 — Verify base solutions
- **Only if** `base_solutions` input is non-empty AND not mock mode
- Runs `pac solution list --environment <url>` for each base solution name
- **Fails** if a required base solution is not installed in the target environment
- Ensures solution dependencies are present before attempting import

#### Step 4 — Blocking check
- **Only if** `enable_blocking_check=true` AND not mock mode
- Calls `Invoke-BlockingCheck.ps1 -EnvironmentUrl <url>`
- Queries Dataverse for in-progress async operations (imports, upgrades, publishes)
- **Fails** if blocking operations found — prevents a new import from conflicting with an existing in-flight operation

#### Step 5 — Version compare
- **Only if** `enable_version_compare=true` AND not mock mode
- Calls `Compare-SolutionVersion.ps1 -ArtifactFolder out/<name> -PreviousEnvironmentUrl <prev_url> -TargetEnvironmentUrl <env_url>`
- **What it checks:**
  - Reads artifact version from `out/<name>/<name>-<version>_unmanaged.zip` (parses filename)
  - Calls Dataverse API on `previous_environment_url` to get the version installed there
  - Calls Dataverse API on `target_environment_url` to get the current installed version
  - Returns `'true'` (skip) if: artifact version ≤ target environment version
  - Returns `'0.0.0.0'` (non-fatal, log only) if previous environment has never been deployed to
- If `skip_import=true`: all subsequent import steps are skipped (solution already up-to-date)

#### Step 6 — Find solution in target environment
- Calls `pac solution list --environment <url> --json`
- Parses the JSON list to find if the solution exists (matches by `SolutionUniqueName` or `UniqueName`)
- If found: sets `$solutionExists=true`, captures `$installedVersion`
- Determines effective import mode: **UPGRADE** (holding pattern) vs **INSTALL** (standard)
- **Mock:** treats as first install (no environment query)

#### Step 7 — Backup
- **Only runs on upgrades** (`enable_backup=true` AND `$solutionExists=true` AND not `skip_import`)
- **First installs are skipped** — there is nothing to back up
- **Real:** `pac solution export --name <name> --path backup/<name>_<env>_backup.zip --managed --environment <url>`
- **Mock:** logs backup simulation
- The backup ZIP is used by the catch block for inline rollback if import fails

#### Step 8 — Import solution
- **If `skip_import=true`:** logs "version already current", skips
- **If UPGRADE (solution exists):**
  - Runs `pac solution import --path <managed_zip> --environment <url> --force-overwrite --import-as-holding` (with optional `--settings-file`)
  - Runs `pac solution upgrade --solution-name <name> --environment <url> --async`
- **If INSTALL (first time):**
  - Runs `pac solution import --path <managed_zip> --environment <url> --force-overwrite` (with optional `--settings-file`)
- **Mock:** logs simulated import with mode and settings file info

#### Step 9 — Config data
- **Only if** `import_config_data=true` AND not `skip_import` AND `config-data/<name>-data.zip` exists
- `pac data import --path config-data/<name>-data.zip --environment <url>`
- **Prod only** (callers set `import_config_data=true` only for Prod)

#### Step 10 — Publish customizations
- **Skipped if** `skip_import=true`
- **Skipped if** UPGRADE pattern (upgrade applies and publishes atomically via `apply-upgrade`)
- **Real:** `pac solution publish --environment <url>`
- **Mock:** logs simulation

#### Step 11 — Extract solution + activate flows & classic workflows
- **Skipped if** `skip_import=true` or `activate_flows=false`

**Part A — Extract solution ZIP:**
- `Expand-Archive` on the managed ZIP to `out/<name>/_extracted/`
- Reads `_extracted/Workflows/` directory for workflow definitions

**Part B — Power Automate cloud flows (`.json` files):**
- Scans `_extracted/Workflows/*.json` for Power Automate flow definitions
- Extracts flow GUID from filename (pattern: `{DisplayName}_{flowid}.json`)
- For each flow: calls `pac flow enable --id <guid> --environment <url>`
- Logs activated vs skipped counts

**Part C — Classic Dynamics 365 workflows (`.xaml` files):**
- Scans `_extracted/Workflows/*.xaml` for classic workflow definitions
- Reads each XAML to extract the workflow `Id` attribute
- For each workflow: calls Dataverse Web API `PATCH /api/data/v9.2/workflows(<id>)` with `{"statecode":1,"statuscode":2}`
- Authenticates using `PP_APP_ID`, `PP_CLIENT_SECRET`, `PP_TENANT_ID`
- Logs activated vs skipped counts

### Post-loop steps

#### Catch block — Inline rollback
- **Triggered when any step in the loop throws an exception**
- Writes `SNOW_DEPLOY_STATUS=failure` to `$GITHUB_ENV` (read by ServiceNow post-deploy step)
- If `enable_backup=true` AND a backup ZIP was taken (only on upgrades):
  - Runs `pac solution import --path backup/<name>_<env>_backup.zip --environment <url> --force-overwrite`
  - Logs "ROLLBACK: re-imported previous version"
- Adds solution name to `$failed` list
- After the loop: if `$failed.Count -gt 0`, exits with `exit 1`

#### Write SNOW_DEPLOY_STATUS=success
- After the loop completes successfully: writes `SNOW_DEPLOY_STATUS=success` to `$GITHUB_ENV`

#### ServiceNow — Post-Deploy (Find Approvers + Detect Status + Close CR)
- **Condition:** `if: always() && inputs.enable_servicenow == 'true'`
- `if: always()` ensures this runs even when the deploy loop failed
- See [Shared Action Reference: ServiceNow CR Lifecycle](#shared-action-reference-servicenow-cr-lifecycle)

#### Upload backup artifact
- **Condition:** `if: inputs.enable_backup == 'true' && inputs.mock_deploy != 'true'`
- `actions/upload-artifact@v4`
- **Artifact name:** `backup-<env>-v<run_number>`
- **Path:** `backup/` directory
- **Retention:** 30 days
- Uploaded after the deploy loop for audit purposes regardless of deploy outcome

---

## Shared Action Reference: ServiceNow CR Lifecycle

**Path:** `.github/actions/dynamics/servicenow-change/action.yml`
**Called by:** `deploy-all-solutions` when `enable_servicenow=true`
**Called twice:** once pre-deploy (phases 1–8, blocking) and once post-deploy (phases 12–14, `if: always()`)
**Credentials required in environment:** `SERVICENOWMURI`, `SNOW_OAUTH_CLIENT_ID`, `SNOW_OAUTH_CLIENT_SECRET` (set by reveille when `servicenow_enabled=true`)

### Pre-deploy phase (8 steps — blocks pipeline until SNOW approves)

#### SNOW Step 1 — Load ServiceNow PowerShell module
- `Import-Module .ci/.github/servicenow/ServiceNow.psd1`
- Makes all SNOW cmdlets available for subsequent steps

#### SNOW Step 2 — Set runtime environment variables
- Sets `BUILD_UNIQUE_IDENTIFIER` = `<repo>-<run_number>-<environment>`
- Sets `SERVICENOWSHORTDESCRIPTION` = `Deploy <solution_list> to <environment_name> — run #<N>`
- Calculates change window: today's preferred day of week (from `SERVICENOW_DESIRED_DAY` variable) + duration
- All written to `$GITHUB_ENV`

#### SNOW Step 3 — New-ServiceNowChangeRequest
- Creates a new Change Request in ServiceNow
- Fields populated from environment variables: `SERVICENOWCHANGETYPE`, `SERVICENOWASSIGNMENTGROUP`, `SERVICENOWJUSTIFICATION`, `SERVICENOWIMPLEMENTATIONPLAN`, `SERVICENOWBACKOUTPLAN`, `SERVICENOWRISKIMPACTANALYSIS`, `SERVICENOWRISKLEVEL`, `SERVICENOWIMPACTLEVEL`, `SERVICENOWCONFIGURATIONITEM`, `SERVICENOWCATEGORY`, `SERVICENOWSERVICENAME`
- Writes `SNOW_CHANGE_REQUEST_NUMBER` (e.g. `CHG0123456`) and `SNOW_CHANGE_REQUEST_ID` (sys_id GUID) to `$GITHUB_ENV`

#### SNOW Step 4 — Add-ServiceNowAuditTrailArtifact
- Attaches the Solution Checker SARIF file to the CR as an audit trail artifact
- Only runs if `sarif_path` input is non-empty

#### SNOW Step 5 — Set-ServiceNowChangeWindow
- Sets the planned start and end time on the CR using the calculated change window
- Satisfies ITSM governance requirements for scheduled change windows

#### SNOW Step 6 — Get-ServiceNowConflict
- Queries ServiceNow for scheduling conflicts with the planned change window
- Logs conflicts as warnings; does not block (conflict handling is a business process decision)

#### SNOW Step 7 — Request-ServiceNowApproval
- Moves the CR from `New` state to `Awaiting Approval` state
- Triggers notification to approvers in ServiceNow

#### SNOW Step 8 — Get-ServiceNowApprovalStatus
- **Polls ServiceNow on a configurable interval** until the CR is approved or rejected
- Poll interval and timeout controlled by `SERVICENOW_APPROVAL_TIMEOUT_MINUTES` (set in project-vars.yml)
- **Approved:** logs approval, writes approver info to env, continues pipeline
- **Rejected:** writes `SNOW_DEPLOY_STATUS=rejected` to `$GITHUB_ENV`, fails the step, blocks the deploy
- **Timeout:** fails the step after the configured timeout

### Post-deploy phase (3 steps — `if: always()`)

#### SNOW Step 12 — Find GitHub Environment approvers
- GitHub Actions REST API: `GET /repos/{owner}/{repo}/actions/runs/{run_id}/approvals`
- Reads the list of users who approved the GitHub Environment gate
- Falls back to `GITHUB_ACTOR` if no approvals found (e.g. no required reviewers configured)
- Writes approver list to env for use in the CR close call

#### SNOW Step 13 — Read SNOW_DEPLOY_STATUS
- Reads `SNOW_DEPLOY_STATUS` from `$GITHUB_ENV`
- This variable was written **before any `exit 1`** in the deploy loop, so it always reflects the true deploy outcome
- Value is `success`, `failure`, or `rejected`

#### SNOW Step 14 — Close-ServiceNowChangeRequest
- `Close-ServiceNowChangeRequest` with:
  - `close_code: successful` (if `SNOW_DEPLOY_STATUS=success`) or `unsuccessful` (if failure/rejected)
  - CR number from `SNOW_CHANGE_REQUEST_NUMBER`
  - CR sys_id from `SNOW_CHANGE_REQUEST_ID`
  - Approver information from Step 12
- Moves the CR to `Closed` state in ServiceNow with the appropriate close notes

---

*Generated from live YAML sources in GHA-CICD-Core + GHA-Dynamics. For the interactive visual companion, open [gha_cicd_e2e_flow.html](./gha_cicd_e2e_flow.html).*
