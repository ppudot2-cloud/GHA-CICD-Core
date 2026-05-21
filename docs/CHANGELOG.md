# Changelog

All notable changes to GHA-Core are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
Versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Callers (GHA-Dynamics repos) should pin to a release tag. See [CONTRIBUTING.md](./CONTRIBUTING.md#6-release-process-and-versioning) for the recommended pinning strategy.

---

## [Unreleased]

Changes on `main` not yet tagged as a release.

### Planned
- `strict_version_compare` input for Prod/Perf environments — fail pipeline when Dataverse version query returns N/A (addresses DevSecOps finding F-07)
- ServiceNow approval polling timeout — configurable max wait (addresses DevSecOps finding F-02)
- SBOM generation (CycloneDX) at build stage (addresses DevSecOps finding F-06)

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
