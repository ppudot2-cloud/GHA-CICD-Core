# Changelog

All notable changes to GHA-Core are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
Versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Callers (GHA-Dynamics repos) should pin to a release tag. See [CONTRIBUTING.md](./CONTRIBUTING.md#6-release-process-and-versioning) for the recommended pinning strategy.

---

## [Unreleased]

Changes on `main` not yet tagged as a release.

### Changed

**Architecture — Azure identity inputs now passed explicitly from callers**

All four Azure identity values (`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `AZURE_KEY_VAULT_NAME`) are no longer read via `vars.*` inside GHA-Core reusable workflows. They are now declared as explicit `workflow_call` inputs (`azure_client_id`, `azure_tenant_id`, `azure_subscription_id`, `azure_key_vault_name`) on every workflow that calls `reveille`.

Affected workflows: `_stage-export.yml`, `_stage-build.yml`, `_job-build.yml`, `_stage-deploy-chain.yml`.

**Why:** `vars.*` in a reusable workflow resolves from the repo that *defines* the workflow (GHA-Core), not the repo that calls it. Storing these values in GHA-Core would couple the shared library to a specific project's Azure identity — violating the design principle that GHA-Core is project-agnostic.

**Migration for new callers:** Pass these four inputs explicitly in every `with:` block that calls an affected reusable:
```yaml
with:
  azure_client_id:        ${{ vars.AZURE_CLIENT_ID }}
  azure_tenant_id:        ${{ vars.AZURE_TENANT_ID }}
  azure_subscription_id:  ${{ vars.AZURE_SUBSCRIPTION_ID }}
  azure_key_vault_name:   ${{ vars.AZURE_KEY_VAULT_NAME }}
```
GHA-Dynamics `build-and-deploy.yml` already includes these. Any other caller repo must be updated accordingly.

### Added

**`reveille` — OIDC pre-login diagnostics**

Added a validation step before `azure/login@v2` that checks all three Azure identity inputs are non-empty and decodes the OIDC JWT to print the `sub` (subject) and `iss` (issuer) claims. Surfaces the exact federated credential subject needed to diagnose `AADSTS700016` ("Application not found") and `AADSTS70021` ("No matching federated identity record") without requiring Azure AD audit log access.

**Solution Checker — deterministic SARIF path and explicit artifact upload**

Replaced the `microsoft/powerplatform-actions/check-solution@v1` wrapper with direct `pac solution check --outputDirectory`. SARIF reports are written to a fixed path (`out/<SolutionName>/solution-checker/<SolutionName>-checker.sarif`) with a `sarif.path` sidecar file alongside it. An explicit `actions/upload-artifact@v4` step uploads the checker report as a separate artifact (`checker-<name>-run<N>`, 30-day retention). Pipeline 2 reads `sarif.path` from downloaded artifacts to locate and attach the report to ServiceNow change requests.

**`health-check.yml` — standalone credential expiry pipeline**

New reusable workflow (also callable via `workflow_dispatch` or `schedule`) that scans Azure Key Vault secrets, KV certificates, and App Registration client secrets for approaching expiry across multiple Azure identities. Configurable warning threshold (default 30 days), sorted by closest expiry first. Creates/updates/closes a GitHub Issue labelled `credential-expiry` with a summary table. Schedule reads config from `vars.HEALTH_CHECK_CONFIG` (JSON array of check contexts) and `vars.HEALTH_CHECK_WARN_DAYS`.

**`verify-deployment` composite action — post-deploy Dataverse health check**

New composite action at `.github/actions/dynamics/verify-deployment`. Confirms every deployed solution is live in Dataverse at the expected version after `import-solution` completes. Checks: solution present in `pac solution list`, version matches artifact version, no blocking async operations. In `mock_deploy` mode all checks are simulated. Wired into `deploy-all-solutions` as Step G, running immediately after the deployment loop on every environment. Exits 1 on any mismatch so the job fails visibly rather than silently accepting a partial deploy.

**`deploy-all-solutions` — structured JSON audit log (Step H)**

Every deploy job now writes a machine-readable `audit-log/<env>-run<N>-attempt<A>.json` record in CycloneDX-inspired structure: timestamp, actor, SHA, environment, solution list, deploy status, ServiceNow CR number, and run URL. Uploaded as a GitHub artifact (`audit-log-<env>-run<N>`, 90-day retention). Runs with `if: always()` so failed deploys are also captured. Satisfies audit trail requirements for regulated enterprise environments.

**`_job-build.yml` — CycloneDX SBOM generation (addresses DevSecOps finding F-06)**

Step 7b generates a CycloneDX v1.5 JSON SBOM for each packed solution, capturing solution name, version, PURL (`pkg:dynamics/<name>@<version>`), git SHA, ref, and run metadata. Written to `out/<SolutionName>/<artifact_name>-sbom.json`. Uploaded as a GitHub artifact (`sbom-<name>-run<N>`, 90-day retention). Runs in both real and mock mode for consistency.

**Pester unit tests — Dynamics PowerShell scripts**

Three new Pester v5 test files covering the governance-critical scripts (previously untested):
- `Merge-Variables.Tests.ps1` — variable merge, protected-key violation detection, AZURE_* exclusion, missing-file handling
- `Set-SolutionVersion.Tests.ps1` — version read, GITHUB_OUTPUT correctness, file immutability, error cases
- `Resolve-SolutionMatrix.Tests.ps1` — solutions.json source, deployOrder sorting, subset selection, filesystem fallback, PP_SOLUTION_NAME fallback, no-solutions error

Tests are located at `.github/servicenow/Tests/Unit/Dynamics/` and run automatically via `pipeline-test.yml` in GHA-Dynamics.

### Planned
- `strict_version_compare` input for Prod/Perf environments — fail pipeline when Dataverse version query returns N/A (addresses DevSecOps finding F-07)
- ServiceNow approval polling timeout — configurable max wait (addresses DevSecOps finding F-02)

---

## [v1.0.0] — 2026-05-20

Initial stable release. All features documented in this release were present before the versioning scheme was introduced; this tag marks the baseline from which callers should pin.

### Added

**Two-pipeline architecture**
- `_stage-export.yml` — export stage with `skip_export` support for source-committed workflows
- `_stage-build.yml` — matrix build stage fanning out to `_job-build.yml` per solution
- `_job-build.yml` — single-solution build: reveille → pac-install → pack → checker → config-data → JFrog upload
- `_stage-deploy-chain.yml` — 6-environment deployment chain with individual GitHub Environment gates

**Composite actions**
- `reveille` — Azure OIDC login, AKV secret fetch (PP, JFrog, MuleSoft, ServiceNow), variable merge
- `pac-install` — Power Platform CLI installation
- `pack-solution` — version stamp, `<Managed>` tag removal, ZIP pack
- `solution-checker` — PAC Solution Checker with SARIF output (always mandatory in non-mock mode)
- `export-solution` — unmanaged solution export from sandbox
- `export-config-data` — Configuration Migration data export
- `import-solution` — multi-pattern import: standard, managed, stage-and-upgrade
- `pre-deploy-checks` — blocking async check + version compare
- `post-deploy` — JFrog Prod tag + deploy summary
- `deploy-all-solutions` — main deploy orchestrator with per-solution pre-flight, import, backup, rollback, flow activation
- `servicenow-change` — full ServiceNow CR lifecycle (pre-deploy open + post-deploy close with `if: always()`)
- `jfrog-upload` — managed ZIP + unmanaged ZIP + SARIF upload to Artifactory

**PowerShell scripts** (`.github/scripts/dynamics/`)
- `Merge-Variables.ps1` — governance-enforced variable merge; protected keys cannot be overridden by project repos
- `Set-SolutionVersion.ps1` — read + stamp solution version from `Solution.xml`
- `Remove-ManagedTag.ps1` — strip `<Managed>0</Managed>` before managed pack
- `Compare-SolutionVersion.ps1` — prevent downgrade; skip import if version matches
- `Invoke-BlockingCheck.ps1` — detect in-progress Dataverse async operations
- `Invoke-JFrogAction.ps1` — JFrog upload and `prodDeployed` tag operations
- `New-MockSolutionZip.ps1` — mock ZIP creation for simulation mode
- `Invoke-SolutionCheckerSim.ps1` — mock SARIF generation
- `Export-ConfigDataSim.ps1` — mock config data export
- `Invoke-ExportCommitSim.ps1` — mock export-and-commit simulation
- `Resolve-SolutionMatrix.ps1` — read `solutions.json`, build GitHub Actions matrix JSON
- `Write-BuildSummary.ps1` — per-solution build result markdown table
- `Write-DeploySummary.ps1` — per-solution deploy result markdown table
- `Write-PipelineSummary.ps1` — consolidated pipeline summary across all solutions and environments

**ServiceNow PowerShell module** (`.github/servicenow/`)
- Full CR lifecycle: `New-ServiceNowChangeRequest`, `Add-ServiceNowAuditTrailArtifact`, `Set-ServiceNowChangeWindow`, `Get-ServiceNowConflict`, `Request-ServiceNowApproval`, `Get-ServiceNowApprovalStatus`, `Close-ServiceNowChangeRequest`
- Supporting functions: emergency change support, approver lookup, pipeline properties
- Pester unit tests for core module functions

**Governance**
- `global-vars.yml` — org-wide defaults and four protected keys: `PP_CHECKER_GEO`, `PP_CHECKER_ERROR_LEVEL`, `DEFAULT_SOLUTION_TYPE`, `ENABLE_BACKUP`
- Project repos cannot override protected keys — `Merge-Variables.ps1` exits 1 on violation

**Security**
- Zero long-lived secrets in GitHub — all PP credentials stored in Azure Key Vault, fetched via OIDC at runtime
- `::add-mask::` applied to all AKV-sourced credentials before writing to `GITHUB_ENV`
- Azure identity keys (`AZURE_*`) explicitly excluded from variable merge to prevent OIDC hijacking
- Solution Checker always mandatory in non-mock builds — no toggle to disable

**Mock / simulation mode**
- Complete simulation for every real operation — pipeline is fully testable without Dataverse or JFrog
- Mock indicators `[MOCK]` on all simulated steps
- `simulate-pipeline.py` script for local end-to-end dry-run

**Artifact management**
- GitHub artifacts: 7-day retention for solution ZIPs, 30-day for backup ZIPs
- JFrog Artifactory: long-term storage with property-based search
- Deterministic naming: `solution-{name}-run{N}[-a{A}]` — no collisions on re-runs
- `prodDeployed=true` + `deployedDate` tags applied after successful Prod deploy

**Documentation**
- `docs/QUICK_START.md` — first pipeline run guide
- `docs/PIPELINE_REFERENCE.md` — complete reference for all workflows, actions, scripts, configs
- `docs/PIPELINE_WALKTHROUGH.md` — end-to-end narrative flow
- `docs/ENTERPRISE_DEVSECOPS_GUIDE.md` — Azure OIDC, Key Vault, federated credentials, full enterprise setup
- `docs/ENTERPRISE_IMPLEMENTATION_GUIDE.md` — step-by-step production rollout
- `docs/SECRETS_SETUP_GUIDE.md` — secrets, variables, and environment configuration quick reference
- `docs/RUNBOOKS.md` — operational runbooks: break-glass, manual rollback, credential rotation, ServiceNow recovery
- `CONTRIBUTING.md` — development, testing, and release process for GHA-Core contributors
- `CHANGELOG.md` — this file

### Security

- OIDC + Azure Key Vault credential pattern — no static secrets in GitHub
- Protected governance keys enforced in `Merge-Variables.ps1`
- Solution Checker mandatory at build stage with configurable error threshold

---

## How to Read This Changelog

Each release section lists changes under these headings:

- **Added** — new features and capabilities
- **Changed** — changes to existing behaviour (backwards compatible)
- **Deprecated** — features that will be removed in a future MAJOR release
- **Removed** — features removed in this release (MAJOR version bump required)
- **Fixed** — bug fixes
- **Security** — security-relevant changes (patches, hardening)

Breaking changes are flagged with `⚠️ BREAKING` and include a migration guide.
