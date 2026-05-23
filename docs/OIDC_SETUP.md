# Per-Environment OIDC + Azure Key Vault Setup

This document walks through setting up a separate Azure identity (App Registration + Federated Credential + Key Vault) for each GitHub Environment. It is the definitive reference for the `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, and `AZURE_KEY_VAULT_NAME` variables used in GHA-Dynamics.

> **Why per-environment?**
> A single App Registration shared across all environments means a compromise in Dev gives an attacker prod-level Dataverse access. Separate identities limit the blast radius to the environment whose credential was stolen.

---

## Recommended Architecture

### Tier model (minimum viable)

For teams that cannot manage six App Registrations, two tiers provide the most critical isolation:

| Tier | Environments | App Registration | Key Vault |
|---|---|---|---|
| Non-prod | Dev, Intg, UAT, FRS, Perf | `sp-gha-nonprod` | `kv-pp-nonprod` |
| Prod | Prod | `sp-gha-prod` | `kv-pp-prod` |

### Full per-environment model (recommended for enterprise)

One App Registration and one Key Vault per environment. Each App Registration holds only the credentials for that environment; a compromised non-prod identity cannot touch Prod.

| Environment | App Registration | Key Vault |
|---|---|---|
| Dev | `sp-gha-dev` | `kv-pp-dev` |
| Intg | `sp-gha-intg` | `kv-pp-intg` |
| UAT | `sp-gha-uat` | `kv-pp-uat` |
| FRS | `sp-gha-frs` | `kv-pp-frs` |
| Perf | `sp-gha-perf` | `kv-pp-perf` |
| Prod | `sp-gha-prod` | `kv-pp-prod` |

Both models use the same workflow YAML — only the GitHub Environment-level variables change.

---

## Federated Credential Subject Matrix

GitHub generates an OIDC token for every workflow job. The token's `sub` (subject) claim identifies exactly which repo and environment the job is running in. Azure validates this claim against the federated credential before issuing an access token.

**Subject format:**
```
repo:<org>/<repo>:environment:<environment>
```

For GHA-Dynamics at `ppudot2-cloud/GHA-Dynamics`:

| Environment | Required Subject Claim |
|---|---|
| Dev | `repo:ppudot2-cloud/GHA-Dynamics:environment:Dev` |
| Intg | `repo:ppudot2-cloud/GHA-Dynamics:environment:Intg` |
| UAT | `repo:ppudot2-cloud/GHA-Dynamics:environment:UAT` |
| FRS | `repo:ppudot2-cloud/GHA-Dynamics:environment:FRS` |
| Perf | `repo:ppudot2-cloud/GHA-Dynamics:environment:Perf` |
| Prod | `repo:ppudot2-cloud/GHA-Dynamics:environment:Prod` |

> **Important:** Environment names in federated credentials are **case-sensitive**. `UAT` and `uat` are different subjects. The value here must match the GitHub Environment name exactly.

> **Diagnosing AADSTS70021** ("No matching federated identity credential"): the reveille OIDC diagnostics step prints the actual `sub` claim from the runner's JWT. Compare that value against what is configured in Azure AD. They must match character-for-character.

---

## Step-by-Step Setup

### 1. Create App Registrations

Run once per tier (or per environment for full isolation). Replace `<ENV>` with the environment name.

```bash
# Create App Registration
az ad app create --display-name "sp-gha-<ENV>"

# Note the Application (client) ID returned — this becomes AZURE_CLIENT_ID
APP_ID=$(az ad app list --display-name "sp-gha-<ENV>" --query "[0].appId" -o tsv)

# Create the Service Principal
az ad sp create --id $APP_ID
```

No client secret is created — authentication is via OIDC only.

### 2. Add Federated Credentials

One federated credential per GitHub Environment on each App Registration:

```bash
# For each environment (Dev / Intg / UAT / FRS / Perf / Prod)
ENV_NAME="Dev"   # Change for each environment
APP_ID="<app-id-for-this-tier>"

az ad app federated-credential create \
  --id $APP_ID \
  --parameters '{
    "name": "gha-dynamics-'"$ENV_NAME"'",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:ppudot2-cloud/GHA-Dynamics:environment:'"$ENV_NAME"'",
    "description": "GHA-Dynamics '"$ENV_NAME"' environment deployments",
    "audiences": ["api://AzureADTokenExchange"]
  }'
```

Verify the configured credentials:
```bash
az ad app federated-credential list --id $APP_ID --query "[].{name:name,subject:subject}"
```

### 3. Create Key Vaults

One Key Vault per tier (or environment). The Key Vault must be in the same subscription and tenant as the App Registration.

```bash
RG="rg-gha-pipeline"
LOCATION="uksouth"
ENV_NAME="dev"   # lowercase for resource names

az keyvault create \
  --name "kv-pp-$ENV_NAME" \
  --resource-group $RG \
  --location $LOCATION \
  --enable-rbac-authorization true
```

### 4. Grant Key Vault Access to the Service Principal

```bash
SP_OBJECT_ID=$(az ad sp show --id $APP_ID --query "id" -o tsv)
KV_ID=$(az keyvault show --name "kv-pp-$ENV_NAME" --resource-group $RG --query "id" -o tsv)

az role assignment create \
  --role "Key Vault Secrets User" \
  --assignee $SP_OBJECT_ID \
  --scope $KV_ID
```

### 5. Store PP Credentials in Each Key Vault

The secret names must exactly match what `reveille` expects:

```bash
KV_NAME="kv-pp-$ENV_NAME"

az keyvault secret set --vault-name $KV_NAME --name "pp-app-id"        --value "<PP service principal client ID>"
az keyvault secret set --vault-name $KV_NAME --name "pp-client-secret"  --value "<PP service principal client secret>"
az keyvault secret set --vault-name $KV_NAME --name "pp-tenant-id"      --value "<Azure AD tenant ID>"

# Optional — only if JFrog is used
az keyvault secret set --vault-name $KV_NAME --name "jfrog-api-key"     --value "<JFrog API key>"

# Optional — only on environments where ServiceNow is enabled
az keyvault secret set --vault-name $KV_NAME --name "snow-base-uri"            --value "<ServiceNow URL>"
az keyvault secret set --vault-name $KV_NAME --name "snow-oauth-client-id"     --value "<client ID>"
az keyvault secret set --vault-name $KV_NAME --name "snow-oauth-client-secret" --value "<client secret>"
```

### 6. Grant OIDC Permission on the Azure Subscription

The App Registration needs Reader on the subscription to validate OIDC tokens:

```bash
SUBSCRIPTION_ID="<your-subscription-id>"
az role assignment create \
  --role "Reader" \
  --assignee $SP_OBJECT_ID \
  --scope "/subscriptions/$SUBSCRIPTION_ID"
```

---

## GitHub Configuration

### Repository-level variables (fallback defaults)

Set these at **GHA-Dynamics → Settings → Secrets and variables → Actions → Variables**. They act as defaults for any environment that does not override them.

| Variable | Value |
|---|---|
| `AZURE_TENANT_ID` | Your Azure AD Tenant ID (same across all environments in a single tenant) |
| `AZURE_SUBSCRIPTION_ID` | Azure subscription ID (set repo-wide; override per-environment if environments span subscriptions) |
| `AZURE_CLIENT_ID` | Fallback App Registration client ID (override at environment level to achieve isolation) |
| `AZURE_KEY_VAULT_NAME` | Fallback Key Vault name (override at environment level) |

### Environment-level variable overrides

Navigate to **GHA-Dynamics → Settings → Environments → [Environment name] → Environment variables**.

Environment variables override repo-level variables when a job runs in that environment. This is the mechanism that makes per-environment OIDC work with no workflow YAML changes.

#### Tier model (non-prod / prod)

| Environment | Variable | Value |
|---|---|---|
| Dev | `AZURE_CLIENT_ID` | `<app-id of sp-gha-nonprod>` |
| Dev | `AZURE_KEY_VAULT_NAME` | `kv-pp-nonprod` |
| Intg | `AZURE_CLIENT_ID` | `<app-id of sp-gha-nonprod>` |
| Intg | `AZURE_KEY_VAULT_NAME` | `kv-pp-nonprod` |
| UAT | `AZURE_CLIENT_ID` | `<app-id of sp-gha-nonprod>` |
| UAT | `AZURE_KEY_VAULT_NAME` | `kv-pp-nonprod` |
| FRS | `AZURE_CLIENT_ID` | `<app-id of sp-gha-nonprod>` |
| FRS | `AZURE_KEY_VAULT_NAME` | `kv-pp-nonprod` |
| Perf | `AZURE_CLIENT_ID` | `<app-id of sp-gha-nonprod>` |
| Perf | `AZURE_KEY_VAULT_NAME` | `kv-pp-nonprod` |
| Prod | `AZURE_CLIENT_ID` | `<app-id of sp-gha-prod>` |
| Prod | `AZURE_KEY_VAULT_NAME` | `kv-pp-prod` |

#### Full per-environment model

| Environment | Variable | Value |
|---|---|---|
| Dev | `AZURE_CLIENT_ID` | `<app-id of sp-gha-dev>` |
| Dev | `AZURE_KEY_VAULT_NAME` | `kv-pp-dev` |
| Intg | `AZURE_CLIENT_ID` | `<app-id of sp-gha-intg>` |
| Intg | `AZURE_KEY_VAULT_NAME` | `kv-pp-intg` |
| UAT | `AZURE_CLIENT_ID` | `<app-id of sp-gha-uat>` |
| UAT | `AZURE_KEY_VAULT_NAME` | `kv-pp-uat` |
| FRS | `AZURE_CLIENT_ID` | `<app-id of sp-gha-frs>` |
| FRS | `AZURE_KEY_VAULT_NAME` | `kv-pp-frs` |
| Perf | `AZURE_CLIENT_ID` | `<app-id of sp-gha-perf>` |
| Perf | `AZURE_KEY_VAULT_NAME` | `kv-pp-perf` |
| Prod | `AZURE_CLIENT_ID` | `<app-id of sp-gha-prod>` |
| Prod | `AZURE_KEY_VAULT_NAME` | `kv-pp-prod` |

`AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID` typically stay at the repo level unless environments span tenants or subscriptions.

---

## How It Works at Runtime

When a deploy job runs in, for example, the `UAT` environment:

1. GitHub injects a short-lived OIDC JWT with `sub = repo:ppudot2-cloud/GHA-Dynamics:environment:UAT`.
2. The job reads `AZURE_CLIENT_ID` and `AZURE_KEY_VAULT_NAME` — the **environment-level** values win over repo defaults.
3. `reveille` calls `azure/login@v2` with those values. Azure validates the `sub` claim against the federated credential registered on that App Registration.
4. If the subject matches, Azure issues an access token scoped to `kv-pp-uat`.
5. `reveille` fetches `pp-app-id`, `pp-client-secret`, `pp-tenant-id` from `kv-pp-uat` and writes them to `GITHUB_ENV` with `::add-mask::`.
6. Subsequent steps use `${{ env.PP_APP_ID }}` etc. — the values are masked in all logs.

A Prod job goes through the same flow but uses `AZURE_CLIENT_ID` for `sp-gha-prod` and `kv-pp-prod`. The non-prod App Registration has no federated credential for `environment:Prod` and cannot authenticate to the Prod Key Vault.

---

## Verification Checklist

After setup, verify each environment with a `mock_deploy=false` run and check the reveille diagnostics step:

- [ ] OIDC JWT decoded — `sub` claim matches the expected subject for that environment
- [ ] `azure/login@v2` succeeds (no AADSTS error)
- [ ] All required AKV secrets fetched (`pp-app-id`, `pp-client-secret`, `pp-tenant-id`)
- [ ] PP credentials masked in logs (values show as `***`)
- [ ] `who-am-i` step succeeds with the correct Dataverse environment URL
- [ ] Repeat for: Dev, Intg, UAT, FRS, Perf, Prod

---

## Troubleshooting

| Error | Likely Cause | Fix |
|---|---|---|
| `AADSTS700016` — Application not found | Wrong `AZURE_CLIENT_ID`, or App Registration deleted | Verify the client ID in the environment variable matches the App Registration's Application ID in Entra |
| `AADSTS70021` — No matching federated identity | Subject mismatch | Compare the `sub` from the reveille diagnostic step against the federated credential configured in Entra — they must match exactly including case |
| `AADSTS700082` — Refresh token expired | Token TTL issue (rare with OIDC) | Re-run the workflow; OIDC tokens are always short-lived and freshly issued |
| Key Vault `403 Forbidden` | Service principal missing `Key Vault Secrets User` role | Re-run step 4 with the correct SP object ID and KV scope |
| Key Vault `404 Not Found` | Wrong `AZURE_KEY_VAULT_NAME` | Verify the environment-level variable value matches the Azure resource name exactly |
| Secret `pp-app-id` not found | Secret not created in KV | Run step 5 for the affected environment's Key Vault |
