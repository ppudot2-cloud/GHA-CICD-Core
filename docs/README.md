# GHA-Core — Power Platform CI/CD Reusable Library

Shared GitHub Actions library for Power Platform pipelines. Contains all reusable workflows, composite actions, and PowerShell scripts. Called by [GHA-Dynamics](https://github.com/ppudot2-cloud/GHA-Dynamics) project repos.

> **Do not trigger pipelines from this repo.** All workflows here are `workflow_call` reusables — they have no triggers of their own.

---

## Structure

```
GHA-Core/
├── .github/
│   ├── workflows/                  # Reusable workflows (MUST be at root — GitHub constraint)
│   │   ├── _job-build.yml          # Single-solution build job
│   │   ├── _job-deploy.yml         # Single-environment deploy job (used by Pipeline 2)
│   │   ├── _stage-build.yml        # Build stage (matrix per solution) + validate config
│   │   ├── _stage-deploy-chain.yml # Parallel deploy across all pre-prod envs + PR creation after UAT
│   │   └── _stage-export.yml       # Export stage (sandbox export or skip_export mode)
│   ├── actions/dynamics/           # Composite actions
│   │   ├── deploy-all-solutions/   # Main deploy orchestrator for one environment
│   │   ├── export-config-data/     # Config migration data export
│   │   ├── export-solution/        # PAC solution export
│   │   ├── import-solution/        # PAC solution import (all variants)
│   │   ├── jfrog-upload/           # JFrog Artifactory upload
│   │   ├── pac-install/            # Install PAC CLI
│   │   ├── pack-solution/          # Version stamp + pack ZIPs
│   │   ├── post-deploy/            # JFrog Prod tag + deploy summary
│   │   ├── pre-deploy-checks/      # Blocking check + version compare
│   │   ├── reveille/               # CI bootstrap — checkout, OIDC login, AKV secrets, merge vars
│   │   ├── servicenow-change/      # ServiceNow change request lifecycle (pre/post deploy)
│   │   └── solution-checker/       # PAC Solution Checker + SARIF
│   ├── scripts/dynamics/           # PowerShell scripts (14 scripts)
│   │   ├── Resolve-SolutionMatrix.ps1
│   │   ├── Set-SolutionVersion.ps1
│   │   ├── Remove-ManagedTag.ps1
│   │   ├── New-MockSolutionZip.ps1
│   │   ├── Invoke-SolutionCheckerSim.ps1
│   │   ├── Export-ConfigDataSim.ps1
│   │   ├── Invoke-ExportCommitSim.ps1
│   │   ├── Invoke-BlockingCheck.ps1
│   │   ├── Compare-SolutionVersion.ps1
│   │   ├── Merge-Variables.ps1
│   │   ├── Invoke-JFrogAction.ps1
│   │   ├── Write-BuildSummary.ps1
│   │   ├── Write-DeploySummary.ps1
│   │   └── Write-PipelineSummary.ps1
│   ├── variables/dynamics/         # Pipeline variable config
│   │   └── global-vars.yml        # Org-wide default variables + protected keys
│   └── servicenow/                 # ServiceNow PowerShell module
│       ├── Classes/
│       ├── Private/
│       ├── Public/
│       └── Tests/
├── docs/                           # Documentation
│   ├── PIPELINE_REFERENCE.md
│   ├── ENTERPRISE_DEVSECOPS_GUIDE.md
│   ├── ENTERPRISE_IMPLEMENTATION_GUIDE.md
│   ├── QUICK_START.md
│   ├── SECRETS_SETUP_GUIDE.md
│   ├── gha_cicd_e2e_flow.html
│   └── pipeline-architecture.html
└── README.md
```

---

## How callers use this repo

1. `reveille` checks out GHA-Core to `.ci/` on every runner using `GHA_CORE_PAT`, then performs Azure OIDC login, fetches AKV secrets, and merges pipeline variables
2. Workflows are called via `uses: ppudot2-cloud/GHA-Core/.github/workflows/{name}@main`
3. Actions are called via `uses: ppudot2-cloud/GHA-Core/.github/actions/dynamics/{name}@main`
4. Scripts are called via `& .ci/.github/scripts/dynamics/{Script}.ps1`

---

## Rollback

Rollback is handled **inline** by the `deploy-all-solutions` composite action. When `enable_backup=true`, it exports the currently installed solution before importing the new version. If the import fails, the pipeline automatically re-imports the backup — no separate rollback workflow is needed.

---

## Documentation

All documentation lives in [`docs/`](docs/) — this is the single authoritative source. GHA-Dynamics project repos link here rather than maintaining their own copies.

| Document | Audience | Description |
|---|---|---|
| [QUICK_START.md](docs/QUICK_START.md) | All | First pipeline run — mock mode through to real deploy |
| [PIPELINE_REFERENCE.md](docs/PIPELINE_REFERENCE.md) | All | Every workflow, action, script, and config file explained |
| [PIPELINE_WALKTHROUGH.md](docs/PIPELINE_WALKTHROUGH.md) | All | End-to-end narrative walkthrough of the full pipeline flow |
| [SECRETS_SETUP_GUIDE.md](docs/SECRETS_SETUP_GUIDE.md) | Platform Eng | All GitHub secrets, variables, AKV secrets, and per-environment variables |
| [ENTERPRISE_DEVSECOPS_GUIDE.md](docs/ENTERPRISE_DEVSECOPS_GUIDE.md) | DevSecOps | Azure OIDC, Key Vault, federated credentials, full enterprise setup |
| [ENTERPRISE_IMPLEMENTATION_GUIDE.md](docs/ENTERPRISE_IMPLEMENTATION_GUIDE.md) | Platform Eng | Step-by-step production rollout — repo setup, integrations (JFrog / SNOW / MuleSoft), simulation retirement, governance, hardening checklist |
| [RUNBOOKS.md](docs/RUNBOOKS.md) | On-call / Release Mgr | Operational runbooks — stuck pipelines, manual rollback, ServiceNow recovery, break-glass deploy, credential rotation |
| [gha_cicd_e2e_flow.html](docs/gha_cicd_e2e_flow.html) | All | Interactive end-to-end pipeline flow diagram |

See also: [CONTRIBUTING.md](./CONTRIBUTING.md) — how to develop, test, and release changes to GHA-Core. [CHANGELOG.md](./CHANGELOG.md) — version history.
