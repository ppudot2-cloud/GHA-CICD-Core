# Enterprise DevSecOps Setup Guide
## Power Platform CI/CD — GHA-CICD-Core + GHA-Dynamics Architecture

> **Audience:** DevSecOps engineers setting up and maintaining the pipeline in an enterprise environment.
> **Scope:** Azure App Registration, OIDC / Workload Identity Federation, Azure Key Vault, GitHub configuration, two-pipeline wiring, and ongoing operations.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites](#2-prerequisites)
3. [Azure App Registration Setup](#3-azure-app-registration-setup)
4. [Azure Key Vault Setup](#4-azure-key-vault-setup)
5. [Federated Identity Credentials — OIDC](#5-federated-identity-credentials--oidc)
6. [Power Platform Service Principal](#6-power-platform-service-principal)
7. [GitHub Repository Configuration](#7-github-repository-configuration)
8. [GHA-CICD-Core Repository Setup](#8-gha-core-repository-setup)
9. [GHA-Dynamics Repository Setup](#9-gha-dynamics-repository-setup)
10. [solutions.json Configuration](#10-solutionsjson-configuration)
11. [Verification Checklist](#11-verification-checklist)
12. [Ongoing Operations](#12-ongoing-operations)
13. [Security Gap Analysis](#13-security-gap-analysis)

---

## 1. Architecture Overview

The pipeline uses a **two-repo, two-pipeline** architecture:

```
┌─────────────────────────────────────────────────────────────────────┐
│  GHA-CICD-Core  (reusable library — your org's shared pipeline library)  │
│                                                                     │
│  .github/workflows/              ← reusable workflows (_stage-*, _job-*)  │
│  .github/actions/dynamics/       ← composite actions (reveille, deploy-all-solutions, etc.) │
│  .github/scripts/dynamics/       ← PowerShell scripts                     │
│  .github/variables/dynamics/     ← global-vars.yml (org-wide defaults)    │
│  docs/                           ← all documentation                      │
└─────────────────────────────────────────────────────────────────────┘
         ↑ checked out to .ci/ on every runner by reveille

┌─────────────────────────────────────────────────────────────────────┐
│  GHA-Dynamics  (project caller — one per Power Platform project)   │
│                                                                     │
│  .github/workflows/       ← trigger workflows (build-and-deploy,   │
│                              deploy-prod, export-solution, etc.)    │
│  solutions.json           ← solution registry & deploy order       │
│  deployment-settings/     ← per-env variable overrides             │
│  config/                  ← data migration schemas                 │
│  src/solutions/           ← unpacked solution source               │
└─────────────────────────────────────────────────────────────────────┘

**Pipeline 1 (build-and-deploy) trigger modes:**
- **Normal (`workflow_dispatch`):** pipeline exports the solution from sandbox before building.
- **Manual export (`push` to `feature/**` OR `workflow_dispatch` with `skip_export=true`):** pipeline skips the sandbox export step and builds directly from the committed source in the branch.

**Pipeline 2 (deploy-prod) trigger:**
- **Automatic:** fires when `pipeline-context.json` is pushed to `main` (i.e., when a Pipeline 1 feature branch PR is merged).
- **Manual:** `workflow_dispatch` for ad-hoc re-runs.
```

**Authentication flow (zero long-lived secrets in GitHub):**

```
GitHub Actions Runner
  → GitHub OIDC Provider issues JWT
  → Azure AD validates JWT against Federated Identity Credential
  → Azure issues short-lived access token
  → az keyvault secret show fetches: pp-app-id, pp-client-secret, pp-tenant-id
  → PAC CLI uses PP credentials for all Dataverse operations
```

**Only one GitHub Secret is needed:** `GHA_CORE_PAT` — a Personal Access Token (or GitHub App token) with `repo` scope, used to check out the private GHA-CICD-Core repository and to create pull requests.

---

## 2. Prerequisites

- Azure CLI installed: `az login` with Owner or Contributor + User Access Administrator role
- Azure subscription with permission to create resources
- Power Platform Admin Center access
- GitHub organization admin (to set repo secrets/variables and environments)
- Both repos created in GitHub: `GHA-CICD-Core` and `GHA-Dynamics`

Set these shell variables before running any commands below — replace ALL placeholder values:

```bash
GITHUB_ORG="your-github-org"
GITHUB_REPO_DYNAMICS="GHA-Dynamics"
GITHUB_REPO_CORE="GHA-CICD-Core"

AZURE_SUBSCRIPTION_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
AZURE_TENANT_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"   # YOUR tenant, not Contoso
AZURE_LOCATION="eastus"
RESOURCE_GROUP="rg-pp-cicd"
KEY_VAULT_NAME="kv-pp-cicd"                               # must be globally unique
APP_REGISTRATION_NAME="pp-cicd-github-actions"

PP_SDBX_URL="https://yourorg-sdbx.crm.dynamics.com"
PP_DEV_URL="https://yourorg-dev.crm.dynamics.com"
PP_INTG_URL="https://yourorg-intg.crm.dynamics.com"
PP_UAT_URL="https://yourorg-uat.crm.dynamics.com"
PP_FRS_URL="https://yourorg-frs.crm.dynamics.com"
PP_PERF_URL="https://yourorg-perf.crm.dynamics.com"
PP_PROD_URL="https://yourorg.crm.dynamics.com"
```

---

## 3. Azure App Registration Setup

### 3.1 Create the App Registration

```bash
# Create the App Registration
APP_ID=$(az ad app create \
  --display-name "$APP_REGISTRATION_NAME" \
  --query appId -o tsv)

echo "App (client) ID: $APP_ID"

# Create a service principal for the app
az ad sp create --id $APP_ID
```

### 3.2 Create Resource Group and Key Vault

```bash
az group create \
  --name $RESOURCE_GROUP \
  --location $AZURE_LOCATION \
  --subscription $AZURE_SUBSCRIPTION_ID

az keyvault create \
  --name $KEY_VAULT_NAME \
  --resource-group $RESOURCE_GROUP \
  --location $AZURE_LOCATION \
  --subscription $AZURE_SUBSCRIPTION_ID \
  --enable-rbac-authorization true
```

### 3.3 Grant the App Registration access to Key Vault

```bash
SP_OBJECT_ID=$(az ad sp show --id $APP_ID --query id -o tsv)

az role assignment create \
  --assignee $SP_OBJECT_ID \
  --role "Key Vault Secrets User" \
  --scope "/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.KeyVault/vaults/$KEY_VAULT_NAME"
```

---

## 4. Azure Key Vault Setup

Store all pipeline credentials in Key Vault. Secret names must match exactly — the `reveille` action fetches by these exact names at the start of every deploy job.

```bash
# Get your PP service principal credentials first — see Section 6
# Then store them:

az keyvault secret set \
  --vault-name $KEY_VAULT_NAME \
  --name "pp-app-id" \
  --value "<PP service principal App ID>"

az keyvault secret set \
  --vault-name $KEY_VAULT_NAME \
  --name "pp-client-secret" \
  --value "<PP service principal client secret>"

az keyvault secret set \
  --vault-name $KEY_VAULT_NAME \
  --name "pp-tenant-id" \
  --value "$AZURE_TENANT_ID"

# Optional — only if JFrog Artifactory is used
az keyvault secret set \
  --vault-name $KEY_VAULT_NAME \
  --name "jfrog-api-key" \
  --value "<your JFrog API key>"

# Optional — only if Mulesoft connector references are used
az keyvault secret set \
  --vault-name $KEY_VAULT_NAME \
  --name "mulesoft-client-id" \
  --value "<Mulesoft connected app client ID>"

az keyvault secret set \
  --vault-name $KEY_VAULT_NAME \
  --name "mulesoft-client-secret" \
  --value "<Mulesoft connected app client secret>"

# Required for each environment where SERVICENOW_ENABLED=true
az keyvault secret set \
  --vault-name $KEY_VAULT_NAME \
  --name "snow-base-uri" \
  --value "https://yourorg.service-now.com"

az keyvault secret set \
  --vault-name $KEY_VAULT_NAME \
  --name "snow-oauth-client-id" \
  --value "<ServiceNow OAuth client ID>"

az keyvault secret set \
  --vault-name $KEY_VAULT_NAME \
  --name "snow-oauth-client-secret" \
  --value "<ServiceNow OAuth client secret>"
```

**Secret names in Key Vault:**

| Secret Name | Required | Fetched when | Env Var |
|---|---|---|---|
| `pp-app-id` | ✅ Always | Always | `PP_APP_ID` |
| `pp-client-secret` | ✅ Always | Always | `PP_CLIENT_SECRET` |
| `pp-tenant-id` | ✅ Always | Always | `PP_TENANT_ID` |
| `jfrog-api-key` | Optional | `JFROG_URL` is set | `JFROG_TOKEN` |
| `mulesoft-client-id` | Optional | `MULESOFT_ENABLED=true` | `MULESOFT_CLIENT_ID` |
| `mulesoft-client-secret` | Optional | `MULESOFT_ENABLED=true` | `MULESOFT_CLIENT_SECRET` |
| `snow-base-uri` | Optional | `SERVICENOW_ENABLED=true` | `SERVICENOWMURI` |
| `snow-oauth-client-id` | Optional | `SERVICENOW_ENABLED=true` | `SNOW_OAUTH_CLIENT_ID` |
| `snow-oauth-client-secret` | Optional | `SERVICENOW_ENABLED=true` | `SNOW_OAUTH_CLIENT_SECRET` |

---

## 5. Federated Identity Credentials — OIDC

This is what enables passwordless Azure login. You must create one federated credential for each GitHub environment and branch that runs the Azure login step.

**Azure Portal path:** Entra ID → App Registrations → `pp-cicd-github-actions` → Certificates & secrets → Federated credentials

Or use the CLI:

```bash
# Helper function
add_federated_credential() {
  local NAME=$1
  local SUBJECT=$2
  az ad app federated-credential create \
    --id $APP_ID \
    --parameters "{
      \"name\": \"${NAME}\",
      \"issuer\": \"https://token.actions.githubusercontent.com\",
      \"subject\": \"${SUBJECT}\",
      \"audiences\": [\"api://AzureADTokenExchange\"]
    }"
}

# Branch credential (for Pipeline 2 read-context job and any non-environment jobs)
add_federated_credential \
  "gha-dynamics-main" \
  "repo:${GITHUB_ORG}/${GITHUB_REPO_DYNAMICS}:ref:refs/heads/main"

# Environment credentials (one per environment that runs reveille)
for ENV in Dev Intg UAT FRS Perf Prod; do
  add_federated_credential \
    "gha-dynamics-env-${ENV}" \
    "repo:${GITHUB_ORG}/${GITHUB_REPO_DYNAMICS}:environment:${ENV}"
done
```

**Full list of required federated credentials:**

| Credential name | Subject | Used by |
|---|---|---|
| `gha-dynamics-main` | `repo:{org}/GHA-Dynamics:ref:refs/heads/main` | Pipeline 2 guard/read-context jobs |
| `gha-dynamics-env-Dev` | `repo:{org}/GHA-Dynamics:environment:Dev` | Pipeline 1 deploy-dev |
| `gha-dynamics-env-Intg` | `repo:{org}/GHA-Dynamics:environment:Intg` | Pipeline 1 deploy-intg |
| `gha-dynamics-env-UAT` | `repo:{org}/GHA-Dynamics:environment:UAT` | Pipeline 1 + Pipeline 2 deploy-uat |
| `gha-dynamics-env-FRS` | `repo:{org}/GHA-Dynamics:environment:FRS` | Pipeline 1 deploy-frs |
| `gha-dynamics-env-Perf` | `repo:{org}/GHA-Dynamics:environment:Perf` | Pipeline 1 deploy-perf |
| `gha-dynamics-env-Prod` | `repo:{org}/GHA-Dynamics:environment:Prod` | Pipeline 2 deploy-prod |

> **Important:** If you see `AADSTS700016: Application not found in directory 'Contoso'`, your `AZURE_TENANT_ID` GitHub variable is set to the wrong tenant. Verify it matches your Azure AD tenant ID exactly.

---

## 6. Power Platform Service Principal

### 6.1 Create a separate App Registration for Power Platform

This is separate from the Azure OIDC app above. It authenticates PAC CLI to Dataverse.

```bash
PP_APP_ID=$(az ad app create \
  --display-name "Power Platform CI/CD Service Principal" \
  --query appId -o tsv)

az ad sp create --id $PP_APP_ID

# Create a client secret (store in Key Vault as pp-client-secret)
PP_CLIENT_SECRET=$(az ad app credential reset \
  --id $PP_APP_ID \
  --display-name "GitHub Actions" \
  --years 2 \
  --query password -o tsv)

echo "PP App ID: $PP_APP_ID"
echo "PP Client Secret: $PP_CLIENT_SECRET"
```

Store these values in Azure Key Vault (see Section 4).

### 6.2 Register as Application User in each PP Environment

For every environment (Sandbox, Dev, Intg, UAT, FRS, Perf, Prod):

1. Go to **Power Platform Admin Center** → select environment → **Settings** → **Users + permissions** → **Application users**
2. Click **+ New app user**
3. Search for the App Registration by `$PP_APP_ID`
4. Assign **System Administrator** security role
5. Repeat for all environments

> The SPN must be a System Administrator (not just Environment Maker) to perform solution imports, flow activations, and publishing.

---

## 7. GitHub Repository Configuration

### 7.1 GitHub Environments

Create these environments in **GHA-Dynamics** → Settings → Environments:

| Environment | Required Reviewers | Notes |
|---|---|---|
| `Dev` | Optional | Auto-deploys; add reviewers to slow it down |
| `Intg` | Recommended | Integration lead |
| `UAT` | Recommended | QA lead |
| `FRS` | Optional | FRS team |
| `Perf` | Optional | Performance team |
| `Prod` | Required | Release manager — also gates rollbacks |

> Environment names are **case-sensitive** and must match exactly. The workflows reference `Dev`, `Intg`, `UAT`, `FRS`, `Perf`, `Prod`.

### 7.2 GitHub Secret

Set one secret on **GHA-Dynamics**:

| Secret | Value | Purpose |
|---|---|---|
| `GHA_CORE_PAT` | PAT or GitHub App token with `repo` scope | Check out the private GHA-CICD-Core repo on the runner; create pull requests |

> Replace with a **GitHub App** token for production — PATs are tied to an individual user account.

### 7.3 GitHub Variables — GHA-Dynamics

Settings → Secrets and variables → Actions → **Variables**:

| Variable | Required | Value |
|---|---|---|
| `AZURE_CLIENT_ID` | ✅ | Client ID of the OIDC App Registration (Section 3) |
| `AZURE_TENANT_ID` | ✅ | Your Azure AD Tenant ID |
| `AZURE_SUBSCRIPTION_ID` | ✅ | Azure subscription ID |
| `AZURE_KEY_VAULT_NAME` | ✅ | Key Vault name (e.g. `kv-pp-cicd`) |
| `PP_SDBX_URL` | ✅ | Sandbox environment URL |
| `PP_DEV_URL` | ✅ | Dev environment URL |
| `PP_INTG_URL` | ✅ | Intg environment URL |
| `PP_UAT_URL` | ✅ | UAT environment URL |
| `PP_FRS_URL` | ✅ | FRS environment URL |
| `PP_PERF_URL` | ✅ | Perf environment URL |
| `PP_PROD_URL` | ✅ | Prod environment URL |
| `JFROG_URL` | Optional | JFrog base URL |
| `JFROG_REPO` | Optional | JFrog repository name |
| `PP_BASE_SOLUTIONS` | Optional | Comma-separated base solution names that must exist before import |

---

## 8. GHA-CICD-Core Repository Setup

GHA-CICD-Core is the shared library. It does not run pipelines itself — it is checked out by every GHA-Dynamics runner.

### 8.1 Repository structure

```
GHA-CICD-Core/
├── .github/
│   ├── workflows/                  ← reusable workflows (MUST be at root — GitHub constraint)
│   │   ├── _job-build.yml
│   │   ├── _stage-build.yml
│   │   ├── _stage-deploy-chain.yml
│   │   └── _stage-export.yml
│   ├── actions/dynamics/           ← composite actions
│   │   ├── deploy-all-solutions/
│   │   ├── export-config-data/
│   │   ├── export-solution/
│   │   ├── import-solution/
│   │   ├── jfrog-upload/
│   │   ├── pac-install/
│   │   ├── pack-solution/
│   │   ├── post-deploy/
│   │   ├── pre-deploy-checks/
│   │   ├── reveille/
│   │   ├── servicenow-change/
│   │   └── solution-checker/
│   ├── scripts/dynamics/           ← PowerShell scripts
│   │   ├── Resolve-SolutionMatrix.ps1
│   │   ├── Set-SolutionVersion.ps1
│   │   └── ... (14 scripts total)
│   ├── variables/dynamics/         ← pipeline variable config
│   │   └── global-vars.yml        ← org-wide defaults + protected keys
│   └── servicenow/                 ← ServiceNow PowerShell module
│       ├── Classes/
│       ├── Private/
│       ├── Public/
│       └── Tests/
├── docs/                           ← all documentation
└── README.md
```

### 8.2 GHA_CORE_PAT access

The `GHA_CORE_PAT` secret in GHA-Dynamics must have **read access** to GHA-CICD-Core. If GHA-CICD-Core is a private repo in the same org, a classic PAT with `repo` scope on an org admin account works. Prefer a GitHub App for production.

### 8.3 Global variables

Edit `GHA-CICD-Core/.github/variables/dynamics/global-vars.yml` to set org-wide defaults and governance:

```yaml
# global-vars.yml — protected keys cannot be overridden by project-vars.yml
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
```

> **Governance:** `Merge-Variables.ps1` (called by `reveille`) enforces that project repos cannot override protected keys. If a project's `project-vars.yml` attempts to set a protected key, the pipeline fails immediately with a governance violation report.

---

## 9. GHA-Dynamics Repository Setup

Each Power Platform project gets its own GHA-Dynamics fork/copy.

### 9.1 Repository structure

```
GHA-Dynamics/
├── .github/
│   ├── workflows/
│   │   ├── build-and-deploy.yml    ← Pipeline 1
│   │   ├── deploy-prod.yml         ← Pipeline 2
│   │   ├── export-solution.yml     ← standalone export
│   │   ├── pr-validation.yml       ← PR build check
│   │   └── test-servicenow.yml     ← ServiceNow flow simulation
│   └── config/
│       └── project-vars.yml        ← project-specific variable overrides
├── solutions.json                  ← solution registry
├── pipeline-context.json           ← cross-pipeline handoff (written by Pipeline 1)
├── src/solutions/{SolutionName}/   ← unpacked solution source
├── config/{SolutionName}/
│   └── data-schema.xml             ← config migration schema
├── deployment-settings/
│   ├── dev/{SolutionName}.json
│   ├── intg/{SolutionName}.json
│   ├── uat/{SolutionName}.json
│   ├── frs/{SolutionName}.json
│   ├── perf/{SolutionName}.json
│   └── prod/{SolutionName}.json
└── scripts/
    └── simulate-pipeline.py        ← local dry-run
```

### 9.2 Project variables

Edit `.github/config/project-vars.yml` to override global defaults for this project:

```yaml
# project-vars.yml — overrides global-vars.yml
PP_SOLUTION_PREFIX: "myproject"
```

### 9.3 Deployment settings format

```json
{
  "EnvironmentVariables": [
    {
      "SchemaName": "new_ServiceEndpointUrl",
      "Value": "https://api.myorg.com/v1"
    }
  ],
  "ConnectionReferences": [
    {
      "LogicalName": "new_SharedDataverse",
      "ConnectionId": "#{PROD_DataverseConnectionId}#",
      "ConnectorId": "/providers/Microsoft.PowerApps/apis/shared_commondataservice"
    }
  ]
}
```

Token placeholders `#{TOKEN_NAME}#` are replaced at deploy time. Store actual connection IDs as GitHub Variables (non-sensitive) or Secrets (sensitive) on the GHA-Dynamics repo.

---

## 10. solutions.json Configuration

This file is the single source of truth for solution deployment configuration:

```json
{
  "solutions": [
    {
      "name": "CoreSolution",
      "folder": "src/solutions/CoreSolution",
      "deployOrder": 1,
      "dependsOn": [],
      "dataSchemaFile": "config/CoreSolution/data-schema.xml",
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

| Field | Required | Description |
|---|---|---|
| `name` | ✅ | Unique solution name matching the Power Platform unique name |
| `folder` | ✅ | Relative path to unpacked solution source |
| `deployOrder` | ✅ | Integer; controls sequential import order within each environment |
| `dependsOn` | No | Documentation only; does not affect deploy order |
| `dataSchemaFile` | No | Path to config migration schema XML; empty string if unused |
| `deploymentSettings` | No | Per-environment deployment settings JSON paths |

> **Single-solution repos:** Add exactly one entry with `deployOrder: 1`.

---

## 11. Verification Checklist

Run through this after initial setup:

```
Azure
  [ ] App Registration created (OIDC app)
  [ ] Service Principal created for the app
  [ ] Resource Group and Key Vault created
  [ ] Key Vault Secrets User role assigned to the SP
  [ ] Federated credentials created for: main branch + all 6 environments
  [ ] AKV secrets populated: pp-app-id, pp-client-secret, pp-tenant-id
  [ ] (Optional) jfrog-api-key in AKV
  [ ] (Optional) mulesoft-client-id, mulesoft-client-secret in AKV (if using Mulesoft connectors)
  [ ] (Optional) snow-base-uri, snow-oauth-client-id, snow-oauth-client-secret in AKV (if using ServiceNow)

Power Platform
  [ ] Separate PP App Registration created
  [ ] PP SP registered as Application User in every PP environment
  [ ] PP SP has System Administrator role in every environment

GitHub — GHA-Dynamics
  [ ] Environments created: Dev, Intg, UAT, FRS, Perf, Prod (exact names)
  [ ] Required reviewers set on Intg, UAT, FRS, Perf, Prod
  [ ] SERVICENOW_ENABLED=true set as Environment variable on UAT/FRS/Perf/Prod (if using ServiceNow)
  [ ] GHA_CORE_PAT secret set with repo scope
  [ ] AZURE_CLIENT_ID variable set (OIDC app client ID)
  [ ] AZURE_TENANT_ID variable set (your real tenant, not Contoso)
  [ ] AZURE_SUBSCRIPTION_ID variable set
  [ ] AZURE_KEY_VAULT_NAME variable set
  [ ] PP_*_URL variables set for all 7 environments

GHA-Dynamics repo
  [ ] solutions.json populated with at least one solution
  [ ] src/solutions/{Name}/ contains unpacked solution source
  [ ] deployment-settings/{env}/{Name}.json files present
  [ ] pipeline-context.json NOT pre-committed (auto-generated by the stage-export commit job on each run — never commit this file)
```

### 11.1 First run — mock mode

Validate everything is wired correctly without touching Dataverse:

1. Go to **GHA-Dynamics → Actions → build-and-deploy.yml → Run workflow**
2. Set `mock_deploy: true`
3. Watch all jobs turn green — this confirms OIDC, AKV, PAC install, build simulation, deploy simulation all work
4. Check the **Summary** tab for the consolidated pipeline report

---

## 12. Ongoing Operations

### Secret rotation

PP client secrets expire (typically 1–2 years). Set a calendar reminder and rotate:

```bash
# Generate new secret
NEW_SECRET=$(az ad app credential reset \
  --id <PP_APP_ID> \
  --display-name "GitHub Actions $(date +%Y)" \
  --years 2 \
  --query password -o tsv)

# Update Key Vault
az keyvault secret set \
  --vault-name $KEY_VAULT_NAME \
  --name "pp-client-secret" \
  --value "$NEW_SECRET"
```

No changes needed in GitHub — the pipeline always fetches fresh from Key Vault.

### PAT rotation

`GHA_CORE_PAT` — update in GHA-Dynamics Settings → Secrets before expiry. Or migrate to a GitHub App (no expiry).

### Adding a new environment

1. Create PP environment and register the application user (Section 6.2)
2. Add federated credential for the new environment (Section 5)
3. Add `PP_{ENV}_URL` GitHub variable to GHA-Dynamics
4. Create GitHub Environment with reviewers
5. Add deploy job for the environment in `build-and-deploy.yml`

### Adding a new solution

1. Get the solution source into the repo — choose one option:
   - **Option A — Use `export-solution.yml` workflow:** trigger the workflow from GitHub Actions; the pipeline connects to sandbox and exports directly, then opens a PR with the unpacked source.
   - **Option B — Manual export:** run `pac solution export` locally to download the solution, then `pac solution unpack` to unpack it, commit the unpacked files to a `feature/*` branch, and push. The pipeline auto-triggers via the `push` to `feature/**` trigger with `skip_export` mode (no sandbox connection required).
2. Add entry to `solutions.json` with `deployOrder` set correctly
3. Create deployment settings files under `deployment-settings/{env}/`
4. Add config schema under `config/{Name}/` if using config migration data

---

## 13. Security Gap Analysis

Current status of known security findings:

| # | Finding | Severity | Status |
|---|---|---|---|
| 1 | PP credentials stored as plain GitHub Secrets | 🔴 Critical | ✅ Fixed — moved to Azure Key Vault |
| 2 | Azure auth via long-lived client secret | 🔴 Critical | ✅ Fixed — OIDC / Workload Identity Federation |
| 3 | Single SPN for all PP environments | 🔴 Critical | ⚠️ Mitigated — AKV centralises; environment-specific SPNs recommended next |
| 4 | No `permissions:` blocks on jobs | 🟠 High | ✅ Fixed — `id-token: write, contents: read` on all jobs |
| 5 | Actions pinned by tag not SHA | 🟠 High | ⚠️ Migrate to SHA pins in production |
| 6 | No concurrency groups on deploy workflows | 🟠 High | ⚠️ Add `concurrency: group: deploy-{env}` to prevent parallel deploys |
| 7 | `GHA_CORE_PAT` is a personal access token | 🟡 Medium | ⚠️ Replace with GitHub App token |
| 8 | No retry logic for PP 429/503 errors | 🟡 Medium | ⚠️ Add retry loop around PAC import steps |
| 9 | No SBOM generation | 🟡 Medium | ⚠️ Add `anchore/sbom-action` to build job |
| 10 | No pipeline failure alerting | 🟡 Medium | ✅ Partially — email notification on pipeline failure |

### Recommended next hardening steps

**Pin actions to SHA:**
```yaml
# Instead of:
uses: actions/checkout@v4
# Use:
uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
```

**Add concurrency groups** to prevent parallel environment deploys:
```yaml
concurrency:
  group: deploy-${{ github.ref }}
  cancel-in-progress: false  # false = queue, not cancel
```

**GitHub App instead of PAT:**
Replace `GHA_CORE_PAT` with a GitHub App installation token generated at runtime. Apps don't expire and are not tied to a user account.
