# Quick Start Guide
## Power Platform CI/CD — First Pipeline Run

> This guide takes you from zero to a running pipeline. For full enterprise setup (Azure OIDC, Key Vault, multi-environment hardening) see [ENTERPRISE_DEVSECOPS_GUIDE.md](./ENTERPRISE_DEVSECOPS_GUIDE.md).

---

## Prerequisites

Before starting you need:

- Two GitHub repositories in your org: `GHA-Core` and `GHA-Dynamics`
- Azure subscription with an App Registration (for OIDC + Key Vault)
- Azure Key Vault containing `pp-app-id`, `pp-client-secret`, `pp-tenant-id`
- Power Platform environments: Dev, Intg, UAT, FRS, Perf, Prod (and optionally a Sandbox)
- Power Platform application user registered in each environment

For instructions on creating all of the above see [ENTERPRISE_DEVSECOPS_GUIDE.md](./ENTERPRISE_DEVSECOPS_GUIDE.md).

---

## Step 1 — Create GitHub Environments

Navigate to **GHA-Dynamics → Settings → Environments** and create these six environments (names are case-sensitive):

| Environment | Required Reviewers | Notes |
|---|---|---|
| `Dev` | Optional | Auto-deploys without approval |
| `Intg` | Recommended | Integration/QA lead |
| `UAT` | Recommended | QA lead |
| `FRS` | Optional | Functional review team |
| `Perf` | Optional | Performance team |
| `Prod` | Required | Release manager |

For each environment, you can also set **Environment variables** (Settings → Environments → [Name] → Environment variables). The most important per-environment variable is `SERVICENOW_ENABLED`:

| Environment | `SERVICENOW_ENABLED` |
|---|---|
| Dev | `false` (or omit) |
| Intg | `false` (or omit) |
| UAT | `true` |
| FRS | `true` |
| Perf | `true` |
| Prod | `true` |

Setting `SERVICENOW_ENABLED=true` activates the full ServiceNow CR lifecycle (open CR → await SNOW approval → deploy → close CR) for that environment. Leave it unset or `false` to skip ServiceNow entirely. Requires ServiceNow AKV secrets — see Step 3.

---

## Step 2 — Set GitHub Secret

**GHA-Dynamics → Settings → Secrets and variables → Actions → Secrets**

| Secret | Value |
|---|---|
| `GHATOKEN` | Personal Access Token with `repo` scope (needs access to the private GHA-Core repo) |

---

## Step 3 — Set GitHub Variables

**GHA-Dynamics → Settings → Secrets and variables → Actions → Variables**

| Variable | Example Value | Required |
|---|---|---|
| `AZURE_CLIENT_ID` | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` | ✅ |
| `AZURE_TENANT_ID` | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` | ✅ (your real tenant, not Contoso) |
| `AZURE_SUBSCRIPTION_ID` | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` | ✅ |
| `AZURE_KEY_VAULT_NAME` | `kv-pp-cicd` | ✅ |
| `PP_SDBX_URL` | `https://yourorg-sdbx.crm.dynamics.com` | ✅ |
| `PP_DEV_URL` | `https://yourorg-dev.crm.dynamics.com` | ✅ |
| `PP_INTG_URL` | `https://yourorg-intg.crm.dynamics.com` | ✅ |
| `PP_UAT_URL` | `https://yourorg-uat.crm.dynamics.com` | ✅ |
| `PP_FRS_URL` | `https://yourorg-frs.crm.dynamics.com` | ✅ |
| `PP_PERF_URL` | `https://yourorg-perf.crm.dynamics.com` | ✅ |
| `PP_PROD_URL` | `https://yourorg.crm.dynamics.com` | ✅ |
| `JFROG_URL` | `https://yourorg.jfrog.io/artifactory` | Optional |
| `JFROG_REPO` | `powerplatform-solutions` | Optional |

> **ServiceNow AKV secrets:** If you set `SERVICENOW_ENABLED=true` on any environment, you must also add these three secrets to your Azure Key Vault before running the pipeline: `snow-base-uri` (your ServiceNow instance URL), `snow-oauth-client-id`, and `snow-oauth-client-secret`. The `reveille` action fetches them when `SERVICENOW_ENABLED=true`. To test the ServiceNow flow without real credentials, use `test-servicenow.yml` (a fully self-contained simulation).

---

## Step 4 — Configure solutions.json

Edit `solutions.json` in the root of GHA-Dynamics to describe your solutions:

```json
{
  "solutions": [
    {
      "name": "MySolution",
      "folder": "src/solutions/MySolution",
      "deployOrder": 1,
      "dependsOn": [],
      "dataSchemaFile": "",
      "deploymentSettings": {
        "dev":  "deployment-settings/dev/MySolution.json",
        "intg": "deployment-settings/intg/MySolution.json",
        "uat":  "deployment-settings/uat/MySolution.json",
        "frs":  "deployment-settings/frs/MySolution.json",
        "perf": "deployment-settings/perf/MySolution.json",
        "prod": "deployment-settings/prod/MySolution.json"
      }
    }
  ]
}
```

Create deployment settings files at the paths listed. Minimum valid content:

```json
{
  "EnvironmentVariables": [],
  "ConnectionReferences": []
}
```

---

## Step 5 — Run the Pipeline (Mock Mode First)

Always run mock mode first to validate the entire wiring without touching Dataverse.

1. Go to **GHA-Dynamics → Actions → build-and-deploy.yml**
2. Click **Run workflow**
3. Set `mock_deploy: true`
4. Click **Run workflow**

Watch the jobs:
- `setup` — reads solutions.json, builds matrix
- `stage-export` — simulates export (or skips export entirely if `skip_export=true` or triggered by push to feature branch)
- `stage-build` — simulates build per solution (no PAC CLI)
- `deploy-dev`, `deploy-intg`, `deploy-uat`, `deploy-frs`, `deploy-perf` — all run in parallel, all simulated
- `create-main-pr` — creates a real PR on GitHub (this step runs for real even in mock mode)

Check the **Summary** tab for the consolidated pipeline report.

> **Note:** To skip sandbox export entirely (manual export mode), set `skip_export: true` — the pipeline will build from source already committed to the branch.

---

## Step 6 — Approve the PR and Trigger Pipeline 2

After Pipeline 1 succeeds and creates a PR:

1. Navigate to the PR created by `create-main-pr`
2. Review and merge it into `main`
3. Pipeline 2 (`deploy-prod.yml`) triggers automatically — it fires when `pipeline-context.json` is pushed to `main` as part of the merge commit
4. Watch `deploy-uat` — approve if an environment gate is configured
5. Watch `deploy-prod` — approve when prompted

Both `deploy-uat` and `deploy-prod` are simulated in mock mode (if `mock_deploy` was set in Pipeline 1, the `pipeline-context.json` carries that setting — but Pipeline 2 has its own `mock_deploy` input for manual triggers).

---

## Step 7 — Run a Real Deploy

Once mock mode is green, run a real deploy:

1. Go to **build-and-deploy.yml → Run workflow**
2. Leave `mock_deploy: false` (the default)
3. Click **Run workflow**
4. Approve environment gates as they pause

Each environment gate pauses the pipeline and sends an email/notification to the configured required reviewers. One approval covers all solutions in that environment.

---

## Running the Export Workflow

To export solutions from your sandbox:

1. Go to **export-solution.yml → Run workflow**
2. Leave `solution_name` empty to export all, or enter a specific solution name
3. Set `mock_deploy: true` for a dry-run (no sandbox connection)
4. The workflow commits the exported source to a feature branch and optionally creates a PR

---

## Manual Export Workflow (skip_export)

Use this when you want to export a solution locally and commit the source yourself, bypassing the sandbox-to-pipeline connection.

**Option A — Auto-trigger via push:**
```bash
# 1. Install PAC CLI
pac install latest

# 2. Authenticate to your sandbox
pac auth create --url https://yourorg-sdbx.crm.dynamics.com

# 3. Export the solution as unmanaged
pac solution export --name MySolution --path MySolution.zip --managed false

# 4. Unpack into the repo
pac solution unpack --zipfile MySolution.zip --folder src/solutions/MySolution --processCanvasApps

# 5. Commit and push to a feature branch — pipeline fires automatically
git checkout -b feature/my-manual-export
git add src/solutions/MySolution
git commit -m "chore: export MySolution"
git push origin feature/my-manual-export
```
The push to `feature/*` triggers `build-and-deploy.yml` automatically with skip_export mode. The pipeline skips the sandbox export stage, writes `pipeline-context.json` to your branch, then builds and deploys normally.

**Option B — Manual dispatch:**
Dispatch `build-and-deploy.yml` from your feature branch with `skip_export: true`. Identical result, but you control exactly when the pipeline fires.

**Branch naming:** Any `feature/*` branch works. The `create-main-pr` job and Pipeline 2 both accept any `feature/*` branch.

---

## Automatic Rollback on Failure

Rollback is fully automatic — no manual workflow required.

When `enable_backup: true` is set on a workflow run, the pipeline exports the currently installed solution from the target environment **before** importing the new version. If the import then fails, the pipeline immediately re-imports that backup to restore the previous version — all within the same GitHub Actions job.

**What gets rolled back automatically:** any failed upgrade where a backup was taken (solution already existed in the environment).

**What is not rolled back:** first-time installs — there is no previous version to restore to. The environment simply remains without the solution.

**Recommended configuration:** leave `enable_backup: false` for Dev and Intg (failures there are expected and a re-run is sufficient), and set `enable_backup: true` for UAT, FRS, Perf, and Prod where environment stability matters.

---

## Local Dry-Run Simulation

Simulate the pipeline locally without GitHub Actions or Dataverse access:

```bash
# Full simulation — all solutions, all environments
python3 scripts/simulate-pipeline.py --solutions all --run-number 42

# Specific solutions
python3 scripts/simulate-pipeline.py --solutions CoreSolution,ExtensionA --run-number 99

# Target specific environments
python3 scripts/simulate-pipeline.py --solutions all --target-envs DEV,INTG --run-number 42
```

---

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `AADSTS700016: Application not found in directory 'Contoso'` | `AZURE_TENANT_ID` variable is wrong — pointing to demo tenant | Update `AZURE_TENANT_ID` GitHub variable to your real Azure AD Tenant ID |
| `The term '.ci/templates/steps/dynamics/...' is not recognized` | Old script path reference | Verify all scripts reference `.ci/.github/scripts/dynamics/` |
| `fatal: could not read Username for 'https://github.com'` | `GHATOKEN` not set or expired | Update the `GHATOKEN` secret |
| `Login failed: The process '/usr/bin/az' failed` | Azure OIDC misconfigured | Check federated credentials on App Registration match your repo/environment names exactly |
| `who-am-i` step fails | PP service principal not registered in the target environment | Add the App Registration as Application User with System Administrator role |
| `Solution package type did not match requested type` | `<Managed>0</Managed>` tag present in Solution.xml | Handled automatically by `Remove-ManagedTag.ps1` — check the pack step ran |
| Pipeline 2 does not trigger after PR merge | PR head branch does not start with `feature/` | Confirm `create-main-pr` job succeeded and the feature branch starts with `feature/`. Also confirm `pipeline-context.json` was committed to the feature branch by the stage-export commit job. |
| `Push to feature branch did not trigger the pipeline` | Branch name does not match `feature/**` pattern | Rename to `feature/your-name` — the push trigger only watches branches starting with `feature/`. Also check that `paths-ignore: pipeline-context.json` is not interfering (only `.json` context file is ignored). |
| ServiceNow CR is never opened | `SERVICENOW_ENABLED` not set on the environment | Add `SERVICENOW_ENABLED=true` as an Environment variable in Settings → Environments → [Name] → Environment variables |
| `Failed to fetch AKV secret 'snow-base-uri'` | ServiceNow AKV secrets missing | Add `snow-base-uri`, `snow-oauth-client-id`, `snow-oauth-client-secret` to your Azure Key Vault |
| Want to test ServiceNow flow before using real credentials | N/A | Run `test-servicenow.yml` from Actions → Test ServiceNow Flow — it's a fully self-contained simulation with no Azure or SNOW dependencies. Set `simulate_outcome: failure` to test the unsuccessful CR close path. |
