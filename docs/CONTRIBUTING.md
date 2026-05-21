# Contributing to GHA-Core

> GHA-Core is the shared CI/CD library consumed by every Power Platform project in the organisation. Changes here affect **all downstream pipelines simultaneously.** Please read this guide fully before making changes.

---

## Table of Contents

1. [Who can contribute](#1-who-can-contribute)
2. [Repo structure at a glance](#2-repo-structure-at-a-glance)
3. [Local development setup](#3-local-development-setup)
4. [How to test a change](#4-how-to-test-a-change)
5. [Branch strategy and PR process](#5-branch-strategy-and-pr-process)
6. [Release process and versioning](#6-release-process-and-versioning)
7. [Breaking changes policy](#7-breaking-changes-policy)
8. [Code standards](#8-code-standards)
9. [Contributor checklist before opening a PR](#9-contributor-checklist-before-opening-a-pr)
10. [What NOT to change here](#10-what-not-to-change-here)

---

## 1. Who Can Contribute

| Role | Can do |
|---|---|
| Platform Engineering | All changes — workflows, actions, scripts, docs |
| DevSecOps | Security-related changes — `reveille`, `Merge-Variables.ps1`, `global-vars.yml` |
| Project teams (GHA-Dynamics owners) | Documentation suggestions only — raise an issue; do not modify GHA-Core directly |
| External contractors | Issues and documentation only — no code changes without platform engineering review |

All PRs require **at least one approval** from a Platform Engineering team member. Changes to `reveille/action.yml`, `Merge-Variables.ps1`, or `global-vars.yml` require **two approvals** (one must be DevSecOps).

---

## 2. Repo Structure at a Glance

```
GHA-Core/
├── .github/
│   ├── workflows/          # Reusable workflows — called via `uses: ...@<tag>`
│   ├── actions/dynamics/   # Composite actions — called inside steps
│   ├── scripts/dynamics/   # PowerShell scripts — sourced at .ci/ on runners
│   ├── variables/dynamics/ # global-vars.yml — org-wide defaults + protected keys
│   └── servicenow/         # ServiceNow PowerShell module (Classes/Private/Public/Tests)
├── docs/                   # All documentation
├── CONTRIBUTING.md         # This file
├── CHANGELOG.md            # Version history
└── README.md
```

The `reveille` action checks out GHA-Core to `.ci/` on every runner. Changes to `actions/` and `scripts/` take effect on the **next pipeline run** for any caller. Callers that are pinned to a tag are **insulated** from live changes until they update their pin.

---

## 3. Local Development Setup

### Required tools

```bash
# PowerShell 7+ (for running PS scripts locally)
brew install --cask powershell          # macOS
sudo snap install powershell --classic  # Linux

# Power Platform CLI
pac install latest

# Python 3 (for local simulation)
python3 --version  # 3.9+

# GitHub CLI (for branch/PR operations)
gh --version
```

### Run the local simulation

The quickest way to validate a change is to run the full pipeline simulation locally. No Dataverse, JFrog, or GitHub Actions required.

```bash
# Clone both repos as siblings
git clone https://github.com/YOUR_ORG/GHA-Core
git clone https://github.com/YOUR_ORG/GHA-Dynamics

# Full simulation — every stage
cd GHA-Dynamics
python3 scripts/simulate-pipeline.py --solutions all --run-number 99

# Test a specific solution
python3 scripts/simulate-pipeline.py --solutions CoreSolution --run-number 99

# Test specific environments only
python3 scripts/simulate-pipeline.py --solutions all --target-envs dev,intg --run-number 99
```

A successful simulation produces output like:

```
[MOCK] Stage: Export         ✅ Simulated export of 3 solutions
[MOCK] Stage: Build          ✅ Packed 3 solutions, checker passed, JFrog upload simulated
[MOCK] Stage: Deploy Dev     ✅ 3 solutions deployed (simulated)
[MOCK] Stage: Deploy Intg    ✅ 3 solutions deployed (simulated)
...
Pipeline simulation complete ✅
```

### Run the PowerShell unit tests

The ServiceNow module has Pester unit tests:

```powershell
cd GHA-Core
Invoke-Pester .github/servicenow/Tests/ -Output Detailed
```

---

## 4. How to Test a Change

### Level 1 — Local simulation (always required)

Run `simulate-pipeline.py` as shown in §3. This catches: broken PowerShell syntax, incorrect output variable names, wrong file paths, logic errors in scripts.

### Level 2 — Mock pipeline run (required for action/workflow changes)

Push your feature branch to GHA-Core. Then, in a **test GHA-Dynamics repo** (not a production project repo), temporarily update the `uses:` references to point at your branch:

```yaml
# In your test GHA-Dynamics repo — NEVER commit this to a production caller
uses: YOUR_ORG/GHA-Core/.github/workflows/_stage-build.yml@your-feature-branch
```

Dispatch `build-and-deploy.yml` with `mock_deploy: true`. All stages should complete successfully with `[MOCK]` indicators on every step.

**Checklist for mock run:**
- [ ] `reveille` step: checkout, variable merge, no errors
- [ ] `pack-solution`: version stamped correctly, ZIP created
- [ ] `solution-checker`: mock SARIF produced, no failures
- [ ] `deploy-all-solutions`: all solutions deployed in order, correct summary written
- [ ] `servicenow-change` (if changed): CR lifecycle simulated end-to-end

### Level 3 — Real pipeline run on a non-production environment (required for deploy-path changes)

After Level 2 passes, run a real build against a **Dev** environment only:

```bash
# In your test GHA-Dynamics repo:
# Dispatch build-and-deploy.yml
# Set mock_deploy: false
# Set environments filter to 'Dev' only (if the workflow supports it)
```

Verify:
- The PAC CLI auth succeeds (`who-am-i` step)
- Solution Checker runs and produces a real SARIF
- The solution imports successfully to Dev
- The JFrog upload (or skip) behaves as expected

### Level 4 — Full run including UAT/Prod (required for changes to approval gates or ServiceNow)

Coordinate with the release manager. Run `test-servicenow.yml` before touching a real SNOW-enabled environment.

---

## 5. Branch Strategy and PR Process

### Branches

| Branch | Purpose | Who creates it |
|---|---|---|
| `main` | Production — what every caller at `@main` receives | Never commit directly |
| `feature/{description}` | New feature or bug fix | Contributor |
| `hotfix/{description}` | Urgent fix for a production issue | Platform Engineering only |
| `release/v{N}` | Release preparation | Platform Engineering only |

### PR requirements

- All PRs must target `main`
- Title format: `feat: ...`, `fix: ...`, `docs: ...`, `refactor: ...`, `test: ...`, `chore: ...` (conventional commits)
- Include a description of **what changed and why**, plus a link to the relevant issue
- Link to the Level 1 simulation output (paste the last 20 lines as a code block)
- Fill in the [pre-PR checklist](#9-contributor-checklist-before-opening-a-pr)
- At least one reviewer must approve
- All status checks must pass before merging

### What triggers a mandatory review

The following files always require two approvals (one from DevSecOps):
- `.github/actions/dynamics/reveille/action.yml`
- `.github/scripts/dynamics/Merge-Variables.ps1`
- `.github/variables/dynamics/global-vars.yml`

This is enforced via GitHub CODEOWNERS (see `.github/CODEOWNERS`).

---

## 6. Release Process and Versioning

GHA-Core uses **semantic versioning**: `vMAJOR.MINOR.PATCH`.

| Version bump | When |
|---|---|
| `MAJOR` | Breaking change — existing callers must update their `uses:` references |
| `MINOR` | New feature — backwards compatible |
| `PATCH` | Bug fix or documentation update — backwards compatible |

### How to cut a release

1. Ensure all intended changes are merged to `main`
2. Update `CHANGELOG.md` — add a new `## [vX.Y.Z] — YYYY-MM-DD` section at the top
3. Create and push a tag:

```bash
git checkout main
git pull origin main
git tag v1.2.0 -m "Release v1.2.0 — add strict_version_compare mode"
git push origin v1.2.0
```

4. Create a GitHub Release from the tag (Releases → Draft a new release → Choose the tag)
5. Copy the relevant CHANGELOG section into the release notes
6. Announce the release in the platform engineering channel

### Notifying callers of a new release

After tagging, send a message to all GHA-Dynamics project owners:

```
GHA-Core v1.2.0 has been released.

Breaking changes: None.
New features: [list]
To update: change @main to @v1.2.0 in your workflow uses: references.

Changelog: https://github.com/YOUR_ORG/GHA-Core/blob/main/CHANGELOG.md
```

### Recommended ref for callers

Callers should pin to a release tag, not `@main`:

```yaml
# ✅ Pinned to a release tag — insulated from breaking changes
uses: YOUR_ORG/GHA-Core/.github/workflows/_stage-build.yml@v1.2.0

# ⚠️ @main — receives all changes immediately, including breaking ones
uses: YOUR_ORG/GHA-Core/.github/workflows/_stage-build.yml@main
```

For maximum immutability (recommended for production), pin to a commit SHA:

```yaml
# ✅ Maximum immutability — requires explicit SHA update
uses: YOUR_ORG/GHA-Core/.github/workflows/_stage-build.yml@abc123def456
```

---

## 7. Breaking Changes Policy

A **breaking change** is any modification that requires callers (GHA-Dynamics repos) to update their workflow YAML before their pipeline continues to work. Examples:

- Renaming or removing a workflow input
- Changing the type of an existing input (e.g., boolean → string)
- Renaming or removing a composite action
- Moving a script to a different path
- Adding a required (non-default) input to an existing workflow or action

### Rules for breaking changes

1. **Never merge a breaking change directly to `main`** — always go through a `release/vN` branch
2. **Communicate with all GHA-Dynamics owners before releasing** — give at least 5 business days notice
3. **Maintain backwards compatibility for one release cycle when possible** — add the new parameter alongside the old one, deprecate (don't remove) the old one
4. **Document the migration path in CHANGELOG.md** — show exactly what callers must change
5. **Bump the MAJOR version**

### Deprecation process (for non-breaking removal)

When removing a feature that is currently used:

1. Mark it deprecated in the current release (add a `::warning::` annotation in the action, add `# DEPRECATED` comment)
2. List it in CHANGELOG under `### Deprecated`
3. Remove it in the next MAJOR release

---

## 8. Code Standards

### YAML (workflows and actions)

- Use 2-space indentation
- Always add a `description:` to every input and output
- Always add `default:` values where the parameter is optional
- Prefer `${{ inputs.xxx }}` over env vars for action inputs
- Use `if: always()` only for post-cleanup steps that must run even on failure
- Never hardcode URLs, tokens, or org names — use inputs or variables

### PowerShell

- Set `$ErrorActionPreference = 'Stop'` at the top of every script
- Use `Write-Host "::error:: ..."` for errors and `Write-Host "::warning:: ..."` for warnings
- Use `Write-Host "::notice:: ..."` for informational output that should be highlighted in the UI
- Append to `$env:GITHUB_OUTPUT` using `"key=value" >> $env:GITHUB_OUTPUT` — never `echo`
- Append to `$env:GITHUB_STEP_SUMMARY` for markdown step summaries
- All scripts must support a `-MockDeploy` switch that skips real API calls
- Add comments explaining the **why**, not the **what** — the what is visible in the code

### Documentation

- Use tables for configuration references (inputs, outputs, variables)
- Use code blocks with language hints for all commands
- Link between documents — never duplicate content
- Update `CHANGELOG.md` for every PR that changes behaviour

---

## 9. Contributor Checklist Before Opening a PR

```
## Pre-PR Checklist

### Testing
- [ ] Local simulation passes (`python3 scripts/simulate-pipeline.py --solutions all`)
- [ ] Pester tests pass (`Invoke-Pester .github/servicenow/Tests/`)
- [ ] Mock pipeline run passes in a test GHA-Dynamics repo (for action/workflow changes)
- [ ] Real Dev deploy succeeds (for deploy-path changes)

### Code Quality
- [ ] No hardcoded URLs, tokens, or org names
- [ ] All new inputs have descriptions and defaults
- [ ] All scripts have `-MockDeploy` support
- [ ] `$ErrorActionPreference = 'Stop'` present in all modified PS1 files
- [ ] No `echo` for GITHUB_OUTPUT — uses `>>` redirect

### Documentation
- [ ] `CHANGELOG.md` updated (new feature / fix / breaking change)
- [ ] Relevant docs in `docs/` updated if behaviour changed
- [ ] PR description explains the change and references an issue

### Breaking Changes
- [ ] Not a breaking change — OR —
- [ ] Breaking change documented in CHANGELOG with migration guide
- [ ] Notified all GHA-Dynamics owners at least 5 business days before planned release
- [ ] MAJOR version bump planned
```

---

## 10. What NOT to Change Here

These concerns belong in the GHA-Dynamics project repo, **not** GHA-Core:

| Concern | Where it lives |
|---|---|
| `solutions.json` — solution registry | GHA-Dynamics root |
| `deployment-settings/` — per-env variable overrides | GHA-Dynamics |
| `config/` — data migration schemas | GHA-Dynamics |
| `.github/config/project-vars.yml` — project variable overrides | GHA-Dynamics |
| Trigger workflows (`build-and-deploy.yml`, `deploy-prod.yml`) | GHA-Dynamics |
| GitHub Environments and approval gate configuration | GHA-Dynamics Settings |
| GitHub Secrets and Variables (`AZURE_*`, `PP_*_URL`) | GHA-Dynamics Settings |

If you find yourself wanting to add project-specific logic to GHA-Core, it almost certainly belongs in a new input/variable exposed by the relevant action or workflow — not hardcoded here.
