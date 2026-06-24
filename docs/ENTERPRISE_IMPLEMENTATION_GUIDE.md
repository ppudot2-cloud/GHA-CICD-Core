# Enterprise Implementation Guide
## Taking GHA-CICD-Core + GHA-Dynamics from Development to Production

> **Who this is for:** Platform / DevSecOps engineers standing up this pipeline system for the first time in an enterprise environment.
> **What this covers:** Every configuration step, every simulation to retire, every integration to wire up — in the order you should do them.

---

## Table of Contents

1. [Architecture Recap](#1-architecture-recap)
2. [Repository Setup](#2-repository-setup)
3. [Azure Infrastructure Setup](#3-azure-infrastructure-setup)
4. [GitHub Configuration](#4-github-configuration)
5. [Power Platform Configuration](#5-power-platform-configuration)
6. [First Project Setup (GHA-Dynamics)](#6-first-project-setup-gha-dynamics)
7. [Optional Integrations](#7-optional-integrations)
   - 7a. [JFrog Artifactory](#7a-jfrog-artifactory)
   - 7b. [ServiceNow Change Management](#7b-servicenow-change-management)
   - 7c. [MuleSoft Connectors](#7c-mulesoft-connectors)
8. [Retiring Simulations — What to Remove and When](#8-retiring-simulations--what-to-remove-and-when)
9. [Global Governance (global-vars.yml)](#9-global-governance-global-varsyml)
10. [Production Hardening Checklist](#10-production-hardening-checklist)
11. [Onboarding Additional Projects](#11-onboarding-additional-projects)
12. [Troubleshooting Reference](#12-troubleshooting-reference)

---

## 1. Architecture Recap

```
┌──────────────────────────────────────────────────────────┐
│  GHA-CICD-Core  (org-wide shared library — ONE per org)       │
│                                                          │
│  .github/workflows/     ← reusable workflows            │
│  .github/actions/       ← composite actions             │
│  .github/scripts/       ← PowerShell scripts            │
│  .github/variables/     ← global-vars.yml (org defaults)│
│  .github/servicenow/    ← ServiceNow PS module          │
│  docs/                  ← ALL documentation (this file) │
└──────────────────────────────────────────────────────────┘
         ↑ checked out to .ci/ on every runner by reveille

┌──────────────────────────────────────────────────────────┐
│  GHA-Dynamics  (per-project caller — ONE per PP project) │
│                                                          │
│  .github/workflows/     ← trigger workflows              │
│  solutions.json         ← solution registry              │
│  deployment-settings/   ← per-env variable overrides    │
│  src/solutions/         ← unpacked solution source       │
└──────────────────────────────────────────────────────────┘
```

**Two-pipeline flow:**
```
Pipeline 1 (build-and-deploy.yml)
  feature/* branch push OR workflow_dispatch
  → Export → Build → Dev → Intg → UAT → FRS → Perf → PR to main

Pipeline 2 (deploy-prod.yml)
  feature/* PR merged to main
  → UAT re-validation → Prod
```

**Rule of thumb:** GHA-CICD-Core owns the logic. GHA-Dynamics owns the config. Never put logic in GHA-Dynamics — if something needs to change for all projects, change it in GHA-CICD-Core.

---

## 2. Repository Setup

### 2.1 Fork or mirror GHA-CICD-Core into your GitHub organisation

GHA-CICD-Core must live in your own GitHub org — callers reference it as `your-org/GHA-CICD-Core`.

```bash
# If starting from this repo:
git clone https://github.com/ppudot2-cloud/GHA-CICD-Core.git
cd GHA-CICD-Core
git remote set-url origin https://github.com/YOUR-ORG/GHA-CICD-Core.git
git push origin main
```

Make GHA-CICD-Core **private** — it contains org-wide pipeline logic and the ServiceNow PS module.

### 2.2 Update caller references in GHA-CICD-Core

Every `uses:` reference inside GHA-CICD-Core workflows and actions points to itself. After forking, update the org name:

```bash
# In GHA-CICD-Core — update all self-references
grep -r "ppudot2-cloud/GHA-CICD-Core" .github/ --include="*.yml" -l
# For each file found, replace ppudot2-cloud with YOUR-ORG
```

### 2.3 Create a GHA-Dynamics repository for your first project

```bash
# Either copy the template or create fresh
gh repo create YOUR-ORG/GHA-Dynamics --private
```

Update all `uses:` in GHA-Dynamics workflows to point to `YOUR-ORG/GHA-CICD-Core`:

```bash
cd GHA-Dynamics
sed -i 's|ppudot2-cloud/GHA-CICD-Core|YOUR-ORG/GHA-CICD-Core|g' .github/workflows/*.yml
```

### 2.4 Create the GHA_CORE_PAT

Create a Personal Access Token (or GitHub App) with `repo` scope that has read access to GHA-CICD-Core. This is used by `reveille` to check out GHA-CICD-Core on every runner.

Prefer a **GitHub App** over a PAT in production — Apps have no expiry and are not tied to a person's account. See [GitHub Apps documentation](https://docs.github.com/en/apps/creating-github-apps).

Store as a **repository secret** on GHA-Dynamics (and every future GHA-Dynamics project):

```
GHA-Dynamics → Settings → Secrets and variables → Actions → Secrets
Secret name: GHA_CORE_PAT
```

---

## 3. Azure Infrastructure Setup

### 3.1 Set shell variables

```bash
GITHUB_ORG="your-github-org"
GITHUB_REPO="GHA-Dynamics"   # update per project

AZURE_SUBSCRIPTION_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
AZURE_TENANT_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
AZURE_LOCATION="eastus"
RESOURCE_GROUP="rg-pp-cicd"
KEY_VAULT_NAME="kv-pp-cicd"                # must be globally unique
OIDC_APP_NAME="pp-cicd-github-actions"
```

### 3.2 Create the OIDC App Registration

This is the identity GitHub Actions uses to authenticate to Azure — no stored passwords.

```bash
# Create App Registration
APP_ID=$(az ad app create \
  --display-name "$OIDC_APP_NAME" \
  --query appId -o tsv)
echo "OIDC App ID: $APP_ID"

# Create Service Principal
az ad sp create --id $APP_ID
SP_OBJECT_ID=$(az ad sp show --id $APP_ID --query id -o tsv)
```

### 3.3 Create Resource Group and Key Vault

```bash
az group create \
  --name $RESOURCE_GROUP \
  --location $AZURE_LOCATION

az keyvault create \
  --name $KEY_VAULT_NAME \
  --resource-group $RESOURCE_GROUP \
  --location $AZURE_LOCATION \
  --enable-rbac-authorization true

# Grant the OIDC app read access to Key Vault
az role assignment create \
  --assignee $SP_OBJECT_ID \
  --role "Key Vault Secrets User" \
  --scope "/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.KeyVault/vaults/$KEY_VAULT_NAME"
```

### 3.4 Store Power Platform credentials in Key Vault

```bash
# Core PP credentials (always required)
az keyvault secret set --vault-name $KEY_VAULT_NAME --name "pp-app-id"        --value "<PP App ID>"
az keyvault secret set --vault-name $KEY_VAULT_NAME --name "pp-client-secret" --value "<PP client secret>"
az keyvault secret set --vault-name $KEY_VAULT_NAME --name "pp-tenant-id"     --value "$AZURE_TENANT_ID"

# JFrog — add only if JFROG_URL is set (see Section 7a)
az keyvault secret set --vault-name $KEY_VAULT_NAME --name "jfrog-api-key"    --value "<JFrog API key>"

# MuleSoft — add only if MULESOFT_ENABLED=true (see Section 7c)
az keyvault secret set --vault-name $KEY_VAULT_NAME --name "mulesoft-client-id"     --value "<MuleSoft client ID>"
az keyvault secret set --vault-name $KEY_VAULT_NAME --name "mulesoft-client-secret" --value "<MuleSoft secret>"

# ServiceNow — add only for environments where SERVICENOW_ENABLED=true (see Section 7b)
az keyvault secret set --vault-name $KEY_VAULT_NAME --name "snow-base-uri"            --value "https://yourorg.service-now.com"
az keyvault secret set --vault-name $KEY_VAULT_NAME --name "snow-oauth-client-id"     --value "<SNOW OAuth client ID>"
az keyvault secret set --vault-name $KEY_VAULT_NAME --name "snow-oauth-client-secret" --value "<SNOW OAuth secret>"
```

**Complete AKV secrets reference:**

| Secret Name | Required | When fetched | Mapped to env var |
|---|---|---|---|
| `pp-app-id` | ✅ Always | Every job | `PP_APP_ID` |
| `pp-client-secret` | ✅ Always | Every job | `PP_CLIENT_SECRET` |
| `pp-tenant-id` | ✅ Always | Every job | `PP_TENANT_ID` |
| `jfrog-api-key` | Optional | `vars.JFROG_URL` is non-empty | `JFROG_TOKEN` |
| `mulesoft-client-id` | Optional | `vars.MULESOFT_ENABLED == 'true'` | `MULESOFT_CLIENT_ID` |
| `mulesoft-client-secret` | Optional | `vars.MULESOFT_ENABLED == 'true'` | `MULESOFT_CLIENT_SECRET` |
| `snow-base-uri` | Optional | `vars.SERVICENOW_ENABLED == 'true'` | `SERVICENOWMURI` |
| `snow-oauth-client-id` | Optional | `vars.SERVICENOW_ENABLED == 'true'` | `SNOW_OAUTH_CLIENT_ID` |
| `snow-oauth-client-secret` | Optional | `vars.SERVICENOW_ENABLED == 'true'` | `SNOW_OAUTH_CLIENT_SECRET` |

### 3.5 Create Federated Identity Credentials (OIDC)

One federated credential per GitHub Environment (and one for the main branch). These are what allow GitHub Actions to authenticate to Azure without any stored secrets.

```bash
add_federated_credential() {
  local NAME=$1
  local SUBJECT=$2
  az ad app federated-credential create \
    --id $APP_ID \
    --parameters "{
      \"name\": \"$NAME\",
      \"issuer\": \"https://token.actions.githubusercontent.com\",
      \"subject\": \"$SUBJECT\",
      \"audiences\": [\"api://AzureADTokenExchange\"]
    }"
  echo "  ✔ Created: $NAME → $SUBJECT"
}

# Branch credential (used by setup/build jobs and create-main-pr)
add_federated_credential "gha-dynamics-main" \
  "repo:${GITHUB_ORG}/${GITHUB_REPO}:ref:refs/heads/main"

# Feature branch credential (used by deploy jobs when triggered from feature/*)
add_federated_credential "gha-dynamics-feature" \
  "repo:${GITHUB_ORG}/${GITHUB_REPO}:ref:refs/heads/feature/*"

# Per-environment credentials (deploy jobs run in these GitHub Environments)
for ENV in Dev Intg UAT FRS Perf Prod; do
  add_federated_credential \
    "gha-dynamics-env-${ENV}" \
    "repo:${GITHUB_ORG}/${GITHUB_REPO}:environment:${ENV}"
done
```

> **One app registration per project vs. shared:** For non-prod environments, sharing one app registration across projects is acceptable. For Prod, consider a dedicated app registration with access only to the production Key Vault. This limits blast radius if any project's GHA_CORE_PAT is compromised.

---

## 4. GitHub Configuration

### 4.1 Repository-level Variables

Navigate to: **GHA-Dynamics → Settings → Secrets and variables → Actions → Variables**

| Variable | Value |
|---|---|
| `AZURE_CLIENT_ID` | `$APP_ID` from Section 3.2 |
| `AZURE_TENANT_ID` | Your Azure AD Tenant ID |
| `AZURE_SUBSCRIPTION_ID` | Your Azure subscription ID |
| `AZURE_KEY_VAULT_NAME` | `$KEY_VAULT_NAME` from Section 3.3 |
| `PP_SDBX_URL` | `https://yourorg-sandbox.crm.dynamics.com` |
| `PP_DEV_URL` | `https://yourorg-dev.crm.dynamics.com` |
| `PP_INTG_URL` | `https://yourorg-intg.crm.dynamics.com` |
| `PP_UAT_URL` | `https://yourorg-uat.crm.dynamics.com` |
| `PP_FRS_URL` | `https://yourorg-frs.crm.dynamics.com` |
| `PP_PERF_URL` | `https://yourorg-perf.crm.dynamics.com` |
| `PP_PROD_URL` | `https://yourorg.crm.dynamics.com` |

Optional:

| Variable | Value | When needed |
|---|---|---|
| `JFROG_URL` | `https://yourorg.jfrog.io/artifactory` | JFrog integration |
| `JFROG_REPO` | `powerplatform-solutions` | JFrog integration |
| `MULESOFT_ENABLED` | `true` | Solutions use MuleSoft connectors |
| `PP_BASE_SOLUTIONS` | `BaseSolution,SharedComponents` | Prerequisite solutions |

### 4.2 GitHub Environments

Navigate to: **GHA-Dynamics → Settings → Environments**

Create each environment with the exact name shown (case-sensitive):

| Environment | Required Reviewers | Notes |
|---|---|---|
| `Dev` | None | Auto-deploys on every successful build |
| `Intg` | 1 — integration lead | Gates integration deployment |
| `UAT` | 1 — QA lead | UAT success triggers PR to main |
| `FRS` | Optional | Full regression team |
| `Perf` | Optional | Performance team |
| `Prod` | **Required** — release manager | Final gate; no bypass |

### 4.3 Per-Environment Variables

For each environment, click into the environment settings and add variables under **Environment variables**. These override repository-level variables for jobs that run in that environment.

**`SERVICENOW_ENABLED`** — controls ServiceNow CR lifecycle per environment:

| Environment | Value |
|---|---|
| Dev | `false` (or omit) |
| Intg | `false` (or omit) |
| UAT | `true` |
| FRS | `true` |
| Perf | `true` |
| Prod | `true` |

**`AZURE_KEY_VAULT_NAME`** — set per environment if you use separate Key Vaults for non-prod and prod:

| Environment | Value |
|---|---|
| Dev, Intg, UAT, FRS, Perf | `kv-pp-nonprod` |
| Prod | `kv-pp-prod` |

### 4.4 Branch Protection for `main`

Navigate to: **GHA-Dynamics → Settings → Branches → Add rule for `main`**

```
✅ Require a pull request before merging
✅ Require at least 1 approval
✅ Dismiss stale pull request approvals when new commits are pushed
✅ Require status checks to pass before merging
    → Add: "Build and Deploy / 🏗️ Build" (or the build stage name)
✅ Require branches to be up to date before merging
✅ Do not allow bypassing the above settings
✅ Restrict who can push to matching branches (add release managers only)
```

> The `main` branch merge is what triggers Pipeline 2. This protection ensures Pipeline 1's build + UAT must pass before anything reaches Prod.

---

## 5. Power Platform Configuration

### 5.1 Create a dedicated PP Application User

This is separate from the OIDC app — it is a Power Platform service principal that PAC CLI uses to connect to environments.

```bash
# In Azure — create a separate App Registration for Power Platform
PP_APP_NAME="pp-dataverse-service-account"
PP_APP_ID=$(az ad app create --display-name "$PP_APP_NAME" --query appId -o tsv)
az ad sp create --id $PP_APP_ID

# Create a client secret (store in Key Vault as pp-client-secret)
PP_SECRET=$(az ad app credential reset --id $PP_APP_ID --query password -o tsv)
echo "PP_APP_ID: $PP_APP_ID"
echo "PP_SECRET: $PP_SECRET (store in AKV as pp-client-secret)"
```

### 5.2 Register as Application User in every PP environment

For each environment (Sandbox, Dev, Intg, UAT, FRS, Perf, Prod):

1. Navigate to [Power Platform Admin Center](https://admin.powerplatform.microsoft.com)
2. Select the environment → **Settings → Users + permissions → Application users**
3. Click **New app user** → Select your `$PP_APP_ID` app
4. Assign role: **System Administrator**
5. Repeat for all 7 environments

### 5.3 Solution Checker Geography

Set the correct geography in `global-vars.yml` in GHA-CICD-Core:

```yaml
PP_CHECKER_GEO: "UnitedStates"  # or Europe, Asia, etc.
```

The Solution Checker must run in the same geography as your PP tenant to avoid latency timeouts.

---

## 6. First Project Setup (GHA-Dynamics)

### 6.1 Configure solutions.json

```json
{
  "solutions": [
    {
      "name": "YourSolution",
      "folder": "src/solutions/YourSolution",
      "deployOrder": 1,
      "dependsOn": [],
      "dataSchemaFile": "",
      "deploymentSettings": {
        "dev":  "deployment-settings/dev/YourSolution.json",
        "intg": "deployment-settings/intg/YourSolution.json",
        "uat":  "deployment-settings/uat/YourSolution.json",
        "frs":  "deployment-settings/frs/YourSolution.json",
        "perf": "deployment-settings/perf/YourSolution.json",
        "prod": "deployment-settings/prod/YourSolution.json"
      }
    }
  ]
}
```

### 6.2 Create deployment settings files

Create a minimal file at each path listed in `deploymentSettings`:

```json
{
  "EnvironmentVariables": [],
  "ConnectionReferences": []
}
```

For environments that need real overrides:

```json
{
  "EnvironmentVariables": [
    { "SchemaName": "new_ServiceEndpointUrl", "Value": "https://api.contoso.com/v1" }
  ],
  "ConnectionReferences": [
    {
      "LogicalName": "new_SharedDataverseConnection",
      "ConnectionId": "#{PROD_DataverseConnectionId}#",
      "ConnectorId": "/providers/Microsoft.PowerApps/apis/shared_commondataservice"
    }
  ]
}
```

Token substitution: any `#{TOKEN_NAME}#` value is replaced at deploy time. Store `TOKEN_NAME` as a GitHub Variable or Secret on GHA-Dynamics.

### 6.3 Validate with mock mode first

Before touching any real environment, run the full pipeline in mock mode:

1. Go to **GHA-Dynamics → Actions → Build and Deploy → Run workflow**
2. Set `mock_deploy: true`
3. Watch all jobs complete — this validates OIDC, AKV fetch, PAC install, build chain, and deploy chain work end-to-end
4. Check the **Summary** tab for the consolidated pipeline report

Mock mode skips: Azure login, AKV fetch, PAC CLI, Dataverse connection, JFrog upload, ServiceNow API calls. It does run: git operations, artifact creation, GitHub environment gates.

### 6.4 Run the first real deploy

Once mock mode is fully green:

1. Go to **Build and Deploy → Run workflow**
2. Leave `mock_deploy: false`
3. Watch each environment gate pause — approve as needed
4. After UAT succeeds, merge the auto-created PR to trigger Pipeline 2
5. Approve the Prod environment gate when prompted

---

## 7. Optional Integrations

### 7a. JFrog Artifactory

JFrog is used for long-term artifact storage (beyond GitHub's 7-day artifact retention), SARIF archival, and as a private PowerShell module registry for air-gapped agents.

**Step 1 — Create a JFrog repository**

In JFrog Artifactory:
- Create a **Generic repository** named `powerplatform-solutions` (or your preferred name)
- Create a local NuGet repository named `ps-modules` for PowerShell modules

**Step 2 — Create an API key or access token**

In JFrog → User Management → Access Tokens → Generate token with `write` scope on your repository.

**Step 3 — Store in Key Vault**

```bash
az keyvault secret set \
  --vault-name $KEY_VAULT_NAME \
  --name "jfrog-api-key" \
  --value "<your JFrog API key or token>"
```

**Step 4 — Set GitHub Variables on GHA-Dynamics**

```
JFROG_URL  = https://yourorg.jfrog.io/artifactory
JFROG_REPO = powerplatform-solutions
```

**Step 5 — Configure global-vars.yml**

In GHA-CICD-Core `/.github/variables/dynamics/global-vars.yml`:

```yaml
variables:
  JFROG_UPLOAD_ENABLED: "true"
  JFROG_REPO: "powerplatform-solutions"
```

**What JFrog enables:**
- `reveille` registers JFrog as the default PowerShell module source (replaces PSGallery — essential for air-gapped agents)
- `jfrog-upload` action uploads managed ZIP, unmanaged ZIP, and SARIF after every successful build
- `post-deploy` action tags the artifact in JFrog with `prodDeployed=true` after Prod deployment
- All deploy jobs download artifacts from JFrog instead of GitHub artifact storage

**Simulation to retire:** Once JFrog is configured and `JFROG_URL` is set, the `jfrog-upload` and `Invoke-JFrogAction.ps1` mock paths are automatically bypassed — no code changes needed.

---

### 7b. ServiceNow Change Management

ServiceNow integration opens a CR before each deployment in enabled environments, waits for SNOW approval before allowing the import to proceed, and closes the CR after deployment — recording success or failure.

**Step 1 — Create a ServiceNow OAuth Application Registry**

In ServiceNow (as admin):
1. Navigate to **System OAuth → Application Registry → New**
2. Select **Create an OAuth API endpoint for external clients**
3. Fill in: Name, Redirect URL (not used — any valid URL works), Token Lifetime `3600`
4. Note the **Client ID** and **Client Secret**

**Step 2 — Store in Key Vault**

```bash
az keyvault secret set \
  --vault-name $KEY_VAULT_NAME \
  --name "snow-base-uri" \
  --value "https://yourorg.service-now.com"

az keyvault secret set \
  --vault-name $KEY_VAULT_NAME \
  --name "snow-oauth-client-id" \
  --value "<Client ID from Step 1>"

az keyvault secret set \
  --vault-name $KEY_VAULT_NAME \
  --name "snow-oauth-client-secret" \
  --value "<Client Secret from Step 1>"
```

**Step 3 — Set SERVICENOW_ENABLED per environment**

In GHA-Dynamics → Settings → Environments → [Environment name] → Environment variables:

| Environment | `SERVICENOW_ENABLED` |
|---|---|
| Dev | omit / `false` |
| Intg | omit / `false` |
| UAT | `true` |
| FRS | `true` |
| Perf | `true` |
| Prod | `true` |

**Step 4 — Configure ServiceNow variables**

In GHA-CICD-Core `/.github/variables/service-now/` (create a `global-vars.yml` or add to project-vars):

```yaml
SERVICENOWCHANGETYPE:         "standard"
SERVICENOWASSIGNMENTGROUP:    "Power Platform Deployments"
SERVICENOWJUSTIFICATION:      "Automated deployment via CI/CD pipeline"
SERVICENOWIMPLEMENTATIONPLAN: "Deploy Power Platform solution via PAC CLI"
SERVICENOWBACKOUTPLAN:        "Re-import previous version from JFrog backup artifact"
SERVICENOWRISKLEVEL:          "Low"
SERVICENOWIMPACTLEVEL:        "3 - Low"
SERVICENOWCATEGORY:           "Software"
SERVICENOWSERVICENAME:        "Power Platform"
```

**Step 5 — Validate with test-servicenow.yml first**

Before enabling on real environments, run the self-contained simulation:

1. Go to **Actions → Test ServiceNow Flow → Run workflow**
2. Select `environment_name: UAT`, set `simulate_outcome: success`
3. Confirm all 14 steps appear in the logs and the CR number is read back in post-deploy
4. Run again with `simulate_outcome: failure` — confirm CR closes with `unsuccessful`

**Step 6 — Enable on UAT first**

Set `SERVICENOW_ENABLED=true` only on UAT. Run a real pipeline and verify:
- CR opens before import
- Pipeline blocks until SNOW approves
- CR closes correctly after import

Roll out to FRS, Perf, and Prod after UAT is stable.

**Simulation to retire:** Once real ServiceNow is working on all enabled environments, delete `test-servicenow.yml` from GHA-Dynamics (see Section 8).

---

### 7c. MuleSoft Connectors

If any solutions use MuleSoft connection references, their client credentials need to be injected via deployment settings token substitution.

**Step 1 — Store in Key Vault**

```bash
az keyvault secret set \
  --vault-name $KEY_VAULT_NAME \
  --name "mulesoft-client-id" \
  --value "<MuleSoft connected app client ID>"

az keyvault secret set \
  --vault-name $KEY_VAULT_NAME \
  --name "mulesoft-client-secret" \
  --value "<MuleSoft connected app client secret>"
```

**Step 2 — Set the variable**

On GHA-Dynamics (repository-level or per-environment):

```
MULESOFT_ENABLED = true
```

**Step 3 — Reference in deployment settings**

In your `deployment-settings/{env}/YourSolution.json`:

```json
{
  "ConnectionReferences": [
    {
      "LogicalName": "new_MuleSoftConnection",
      "ConnectionId": "#{MULESOFT_CLIENT_ID}#",
      "ConnectorId": "/providers/Microsoft.PowerApps/apis/shared_mulesoft"
    }
  ]
}
```

The `deploy-all-solutions` action performs token substitution — `#{MULESOFT_CLIENT_ID}#` is replaced with the value of `$MULESOFT_CLIENT_ID` (which `reveille` fetched from AKV).

---

## 8. Retiring Simulations — What to Remove and When

The pipeline ships with simulation code that lets you validate the full end-to-end flow without requiring real Azure credentials, Dataverse environments, or third-party services. This section tells you exactly what each simulation is, where it lives, and when to remove it.

### Overview of all simulation touchpoints

| Simulation | Location | How activated | Safe to keep? |
|---|---|---|---|
| `mock_deploy=true` mode | All workflows and actions | `inputs.mock_deploy == true` | ✅ Keep forever — useful for CI validation |
| `New-MockSolutionZip.ps1` | `pack-solution/action.yml` | `mock_deploy=true` | ✅ Keep forever |
| `Invoke-SolutionCheckerSim.ps1` | `solution-checker/action.yml` | `mock_deploy=true` | ✅ Keep forever |
| `Export-ConfigDataSim.ps1` | `export-config-data/action.yml` | `mock_deploy=true` | ✅ Keep forever |
| `Invoke-ExportCommitSim.ps1` | `export-solution.yml` (export workflow) | `mock_deploy=true` | ✅ Keep forever |
| `Invoke-BlockingCheck.ps1` mock path | `deploy-all-solutions/action.yml` | `mock_deploy=true` | ✅ Keep forever |
| `Invoke-JFrogAction.ps1` mock path | `jfrog-upload/action.yml`, `post-deploy/action.yml` | `mock_deploy=true` | ✅ Keep forever |
| `servicenow-change` mock path | `servicenow-change/action.yml` | `mock_deploy=true` | ✅ Keep forever |
| **`test-servicenow.yml`** | `GHA-Dynamics/.github/workflows/test-servicenow.yml` | Manual dispatch | ❌ **Delete once SNOW is validated** |

### The key distinction

**`mock_deploy` mode is not a simulation to "retire"** — it is a permanent, intentional feature that provides a safe dry-run path for developers, CI testing, and onboarding new projects. It must remain in the code indefinitely.

**`test-servicenow.yml` is the only file to retire** — it is a one-time validation scaffold that bypasses all external dependencies to let you observe the ServiceNow flow shape before wiring up real credentials.

### When to delete test-servicenow.yml

Delete it when all of the following are true:

- [ ] AKV secrets `snow-base-uri`, `snow-oauth-client-id`, `snow-oauth-client-secret` are populated
- [ ] `SERVICENOW_ENABLED=true` is set on at least UAT
- [ ] A real pipeline run completed with ServiceNow active — CR opened, SNOW approval obtained, CR closed
- [ ] The SNOW CR lifecycle has been validated on failure path (deploy failed → CR closed with `unsuccessful`)

```bash
# In GHA-Dynamics
git rm .github/workflows/test-servicenow.yml
git commit -m "chore: retire test-servicenow simulation — real SNOW validated"
git push origin main
```

### mock_deploy usage policy for production teams

Establish a team policy around `mock_deploy`:

- `mock_deploy=false` is the default on all `workflow_dispatch` inputs — no accidental simulation in prod
- `mock_deploy=true` is permitted in Dev and Intg by convention (useful for fast iteration)
- `mock_deploy=true` is **forbidden** in UAT, FRS, Perf, Prod — enforce via GitHub Environment protection rules or org-level policy
- Code review gates (PR checks) always run with `mock_deploy=false` equivalent (`pr-validation.yml` has no mock_deploy input)

---

## 9. Global Governance (global-vars.yml)

`GHA-CICD-Core/.github/variables/dynamics/global-vars.yml` is the org-wide policy file. Settings here apply to every GHA-Dynamics project that consumes GHA-CICD-Core.

### Protected keys

These keys are declared in `protected_keys` and **cannot be overridden** by individual project `project-vars.yml` files. `Merge-Variables.ps1` silently ignores any attempt to override them.

| Key | Current value | Why protected |
|---|---|---|
| `PP_CHECKER_GEO` | `UnitedStates` | Org-wide consistency in Solution Checker results |
| `PP_CHECKER_ERROR_LEVEL` | `HighIssue` | Security gate — prevents teams from lowering the bar |
| `DEFAULT_SOLUTION_TYPE` | `managed` | Ensures upper environments always receive managed solutions |
| `ENABLE_BACKUP` | `true` | Automatic rollback on failure — cannot be disabled |

### Recommended additions to protect

Consider protecting these additional keys for enterprise environments:

```yaml
protected_keys:
  - PP_CHECKER_GEO
  - PP_CHECKER_ERROR_LEVEL
  - DEFAULT_SOLUTION_TYPE
  - ENABLE_BACKUP
  - ENABLE_BLOCKING_CHECK      # add: prevents async-conflict skipping
  - SOLUTION_IMPORT_MAX_WAIT_MINUTES  # add: consistent timeout policy
```

### Adding an org-wide variable

Add to the `variables` section in `global-vars.yml`. All GHA-Dynamics projects pick it up on the next run automatically (no project-side changes needed):

```yaml
variables:
  MY_NEW_ORG_VARIABLE: "org-default-value"
```

### Project-level override

Projects add overrides to `GHA-Dynamics/.github/config/project-vars.yml`:

```yaml
# Only keys NOT in protected_keys can be overridden
MY_NEW_ORG_VARIABLE: "project-specific-value"
PP_MAX_WAIT_MINUTES: "180"
```

---

## 10. Production Hardening Checklist

Work through this checklist before calling the pipeline production-ready.

### Azure

- [ ] Dedicated App Registration for OIDC (separate from PP App Registration)
- [ ] App Registration client secret **not** stored anywhere — OIDC only, no secrets in GitHub
- [ ] Key Vault RBAC: only OIDC service principal has `Key Vault Secrets User`; no humans have `Key Vault Secrets Officer` on prod KV
- [ ] Separate Key Vaults for non-prod and prod (`AZURE_KEY_VAULT_NAME` set per environment)
- [ ] Federated credentials created for: `main` branch, `feature/*` branch, and all 6 GitHub Environments
- [ ] All AKV secrets populated (pp-*, jfrog-api-key if JFrog used, snow-* if SNOW used, mulesoft-* if MuleSoft used)
- [ ] Key Vault soft-delete and purge protection enabled
- [ ] Key Vault diagnostic logs enabled (audit who fetched what)

### GitHub — GHA-CICD-Core

- [ ] Repository is **private**
- [ ] Only DevSecOps team has write access; all other teams have read
- [ ] `main` branch protection: require PRs + required reviewers for changes to `global-vars.yml`
- [ ] Automated tests or review for changes to `protected_keys` in `global-vars.yml`
- [ ] `GHA_CORE_PAT` secret is a GitHub App token, not a personal PAT
- [ ] No `mock_deploy=true` hard-coded anywhere in GHA-CICD-Core workflows

### GitHub — GHA-Dynamics

- [ ] Repository is **private**
- [ ] `main` branch protection rules applied (Section 4.4)
- [ ] All 6 Environments created with correct names (case-sensitive)
- [ ] Required reviewers set on Intg, UAT, FRS, Perf, Prod
- [ ] `GHA_CORE_PAT` secret set
- [ ] All `AZURE_*` and `PP_*_URL` variables set
- [ ] `SERVICENOW_ENABLED=true` set on UAT, FRS, Perf, Prod environment variables (if SNOW in use)
- [ ] `test-servicenow.yml` deleted after SNOW validation
- [ ] `solutions.json` populated with real solutions
- [ ] Deployment settings files present for all solutions × all environments
- [ ] No hardcoded credentials in `deployment-settings/` JSON files (use `#{TOKEN_NAME}#` tokens)

### Power Platform

- [ ] Dedicated PP Application User registered in all 7 environments (Sandbox + 6)
- [ ] PP Application User has System Administrator role in each environment
- [ ] PP environments are not shared with other projects (isolation)
- [ ] Solution Checker geography matches PP tenant geography

### ServiceNow (if enabled)

- [ ] OAuth Application Registry created in SNOW
- [ ] Credentials stored in AKV
- [ ] Assignment group exists and has capacity to review CRs
- [ ] Change window configuration tested in non-prod first
- [ ] Post-deploy close behaviour validated: success path AND failure path
- [ ] `test-servicenow.yml` deleted

### Monitoring

- [ ] Failure notification email configured (MAIL_SERVER, MAIL_PORT, MAIL_USERNAME, MAIL_PASSWORD secrets)
- [ ] GitHub Actions usage monitored (minutes consumed) — reusable workflows and composite actions minimise duplication
- [ ] Pipeline summary tab reviewed after every run
- [ ] JFrog artifact retention policy configured (minimum 90 days recommended for Prod artifacts)

---

## 11. Onboarding Additional Projects

Each new Power Platform project gets its own GHA-Dynamics repository. GHA-CICD-Core is shared — no changes needed.

### Steps for each new project

1. **Create a new GHA-Dynamics repo** from the template (or copy an existing one)
2. **Update all `uses:` references** to point to `YOUR-ORG/GHA-CICD-Core`
3. **Create GitHub Environments** (Dev, Intg, UAT, FRS, Perf, Prod) with appropriate reviewers
4. **Create federated credentials** for the new repo in Azure (use the same or a new App Registration depending on isolation requirements)
5. **Set repository variables** (`AZURE_*`, `PP_*_URL`)
6. **Set environment variables** (`SERVICENOW_ENABLED` on UAT/FRS/Perf/Prod)
7. **Set `GHA_CORE_PAT` secret** (same token if using a GitHub App; new PAT if using PATs)
8. **Configure `solutions.json`** and create deployment settings files
9. **Run mock mode** to validate end-to-end wiring
10. **Run first real deploy**

### Using different AKV per project

Each project can point to a different Key Vault by setting `AZURE_KEY_VAULT_NAME` as a repository-level variable. This lets projects have different PP service principal credentials (e.g. if they target different PP tenants).

### Sharing a Key Vault across projects

If projects share one Key Vault, one OIDC App Registration is sufficient. All projects set:
- Same `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`
- Same `AZURE_KEY_VAULT_NAME`

But they must share the same AKV secrets (`pp-app-id`, etc.). This works when all projects target the same PP tenant with the same service account. If projects target different tenants or need different PP credentials, use separate Key Vaults.

### When to fork GHA-CICD-Core

Do **not** fork GHA-CICD-Core per project. Fork it only if:
- You are a separate organisation that needs full ownership
- You need to pin to a specific version (create a versioned tag strategy instead)
- You have fundamental pipeline logic differences that cannot be handled via `global-vars.yml`

For project-specific variation, use `project-vars.yml` overrides and deployment settings.

---

## 12. Troubleshooting Reference

| Symptom | Root cause | Fix |
|---|---|---|
| `AADSTS700016: Application not found in directory 'Contoso'` | `AZURE_TENANT_ID` variable points to wrong tenant | Update `AZURE_TENANT_ID` GitHub variable to your real Azure AD Tenant ID |
| `Login failed: AADSTS70011` | Federated credential subject mismatch | Federated credential subject must exactly match the repo/environment/branch. Check subject strings in Azure Entra ID → App Registrations → Federated credentials |
| `Failed to fetch AKV secret 'pp-app-id'` | OIDC app lacks Key Vault Secrets User role | Add `Key Vault Secrets User` role assignment on the Key Vault for the OIDC SP |
| `fatal: could not read Username` | `GHA_CORE_PAT` secret missing or expired | Renew the PAT or GitHub App token; update the `GHA_CORE_PAT` secret |
| `who-am-i step failed` | PP Application User not registered in target environment | Add the PP App Registration as Application User with System Administrator in Power Platform Admin Center |
| `Pipeline 2 does not trigger after PR merge` | PR head branch does not start with `feature/` | Confirm the PR was created by `create-main-pr` (head is `feature/pipeline-N`) and `pipeline-context.json` was committed to the feature branch |
| `ServiceNow CR never opens` | `SERVICENOW_ENABLED` not set on the environment | Add `SERVICENOW_ENABLED=true` as an Environment variable in Settings → Environments → [Name] |
| `Failed to fetch AKV secret 'snow-base-uri'` | ServiceNow AKV secrets missing | Add `snow-base-uri`, `snow-oauth-client-id`, `snow-oauth-client-secret` to Key Vault |
| `Get-ServiceNowApprovalStatus: timeout` | SNOW approval took longer than the configured timeout | Increase timeout or pre-approve the CR in SNOW before running the pipeline. Check `SERVICENOW_APPROVAL_TIMEOUT_MINUTES` in project-vars.yml |
| `Solution package type did not match requested type` | `<Managed>0</Managed>` tag not stripped | `Remove-ManagedTag.ps1` should handle this automatically in `pack-solution` — check if the pack step completed |
| `mock_deploy=true but real deploy happened` | Caller passed string `'true'` as boolean; comparison failed | Ensure callers use `${{ inputs.mock_deploy == true }}` (boolean comparison), not the string `'true'` directly |
| Protected key overridden silently | `Merge-Variables.ps1` ignores project overrides of protected keys | Check `protected_keys` in `global-vars.yml`. If the key needs to be project-overridable, remove it from `protected_keys` |
| JFrog upload fails: `401 Unauthorized` | `jfrog-api-key` in AKV is expired or wrong | Rotate the JFrog API key, update AKV secret, rerun |
| MuleSoft token substitution missing | `#{MULESOFT_CLIENT_ID}#` in deployment settings not replaced | Ensure `MULESOFT_ENABLED=true` is set on the environment variable, and `mulesoft-client-id` exists in AKV |
| `workflow_dispatch` UI shows empty `solutions` field instead of `all` | Missing `type: string` on the `solutions` input declaration | The `build-and-deploy.yml` `solutions` input must include `type: string` — GitHub only pre-fills `default` values when the type is declared explicitly. The runtime fallback `\|\| 'all'` still works even when the field is submitted empty. |
| `Compare-SolutionVersion.ps1` fails at UAT with connection error to previous environment | `PP_INTG_URL` not set, or Intg environment was never deployed to | Ensure `PP_INTG_URL` is set as a GitHub repository variable. If Intg has never been deployed to, `Compare-SolutionVersion.ps1` returns version `0.0.0.0` (non-fatal — logs "Not yet deployed in prev env" and continues). If it is throwing a hard error, check the `previous_environment_url` input passed to `pre-deploy-checks`. |
| UAT deploy fails: `Failed to fetch AKV secret 'snow-base-uri'` | `SERVICENOW_ENABLED=true` set on UAT environment but ServiceNow AKV secrets not yet added to Key Vault | Either add `snow-base-uri`, `snow-oauth-client-id`, `snow-oauth-client-secret` to Key Vault, or set `SERVICENOW_ENABLED=false` (or remove the variable) on the UAT environment until ServiceNow is ready |
