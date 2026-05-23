#!/usr/bin/env python3
"""
simulate-pipeline.py
====================
Local dry-run simulation of the GHA-Dynamics release pipeline.

Simulates every stage the GitHub Actions workflow would run:
  JOB 0  : Setup      — discover solutions, apply config order, build matrix
  JOB 1  : Build      — version stamp, pack (×2), BlackDuck skip, Checkmarx skip,
                        Solution Checker (mandatory mock), settings-file resolve, upload-artifact
  JOB 2  : Deploy Dev — sequential × N, settings-file resolve, mock import
  GATE   : Intg       — approval simulation
  JOB 3  : Deploy Intg — sequential × N, mock import
  GATE   : UAT
  JOB 4  : Deploy UAT
  GATE   : Perf
  JOB 5  : Deploy Perf
  GATE   : Prod
  JOB 6  : Deploy Prod
  JOB 7  : Pipeline Summary

Usage:
  python3 scripts/simulate-pipeline.py [--solutions all] [--run-number 42]
                                        [--lowcode-nocode] [--no-blackduck]
                                        [--no-checkmarx] [--target-envs all]
"""

import argparse
import json
import os
import re
import sys
import time
import xml.etree.ElementTree as ET
from datetime import datetime
from pathlib import Path

# ── Terminal colours ────────────────────────────────────────────────────────
RESET  = "\033[0m"
BOLD   = "\033[1m"
DIM    = "\033[2m"
RED    = "\033[91m"
GREEN  = "\033[92m"
YELLOW = "\033[93m"
BLUE   = "\033[94m"
CYAN   = "\033[96m"
WHITE  = "\033[97m"
PURPLE = "\033[95m"

def c(color, text):     return f"{color}{text}{RESET}"
def ok(msg):            print(f"  {c(GREEN,'✓')} {msg}")
def warn(msg):          print(f"  {c(YELLOW,'⚠')} {msg}")
def skip(msg):          print(f"  {c(DIM,'⏭')} {msg}")
def fail(msg):          print(f"  {c(RED,'✗')} {msg}"); sys.exit(1)
def info(msg):          print(f"  {c(BLUE,'ℹ')} {msg}")
def step(emoji, msg):   print(f"\n  {emoji}  {c(BOLD, msg)}")
def divider(char='─'):  print(c(DIM, f"  {'─'*70}"))

def job_header(title, subtitle=""):
    print()
    print(c(BOLD, f"  {'━'*70}"))
    print(c(BOLD+BLUE, f"  {title}"))
    if subtitle:
        print(c(DIM, f"  {subtitle}"))
    print(c(BOLD, f"  {'━'*70}"))

def gate_header(env, reviewer):
    print()
    print(c(BOLD+YELLOW, f"  {'─'*70}"))
    print(c(BOLD+YELLOW, f"  🔐 GATE — {env}  (approver: {reviewer})"))
    print(c(DIM,          f"  Simulating manual approval — auto-approved in dry-run mode"))
    print(c(BOLD+YELLOW, f"  {'─'*70}"))

def section(title):
    print(f"\n  {c(CYAN, '▸')} {c(BOLD, title)}")


# ── Repo root ────────────────────────────────────────────────────────────────
SCRIPT_DIR  = Path(__file__).resolve().parent
REPO_ROOT   = SCRIPT_DIR.parent
SOLUTIONS_DIR   = REPO_ROOT / "src" / "solutions"
CONFIG_FILE     = REPO_ROOT / ".github" / "solutions-config.json"
DEPLOY_SETTINGS = REPO_ROOT / "deployment-settings"
CONFIG_DIR      = REPO_ROOT / "config"
ARTIFACTS_DIR   = REPO_ROOT / ".sim-artifacts"   # simulated artifact store


# ── Arg parsing ─────────────────────────────────────────────────────────────
def parse_args():
    p = argparse.ArgumentParser(description="GHA-Dynamics pipeline dry-run simulator")
    p.add_argument("--solutions",       default="all",
                   help='Solutions to process: "all" or comma-separated names')
    p.add_argument("--run-number",      type=int, default=42,
                   help="Simulated GitHub run_number (default: 42)")
    p.add_argument("--lowcode-nocode",  action="store_true",
                   help="Enable lowcode-nocode mode (activates BlackDuck + Checkmarx toggles)")
    p.add_argument("--no-blackduck",    action="store_true",
                   help="Disable BlackDuck SCA (only relevant when --lowcode-nocode is set)")
    p.add_argument("--no-checkmarx",    action="store_true",
                   help="Disable Checkmarx SAST (only relevant when --lowcode-nocode is set)")
    p.add_argument("--target-envs",     default="all",
                   help='Environments: "all" | "dev" | "dev-intg" | "dev-intg-uat"')
    p.add_argument("--enable-backup",   action="store_true",
                   help="Simulate environment backups before each deploy")
    p.add_argument("--trigger-upgrade", action="store_true",
                   help="Use holding-solution upgrade pattern instead of in-place update")
    return p.parse_args()


# ══════════════════════════════════════════════════════════════════════════════
# JOB 0 — SETUP: discover + validate + order solutions
# ══════════════════════════════════════════════════════════════════════════════
def job_setup(args):
    job_header("JOB 0 — 🔍 Setup", "Discover solutions · Validate names · Apply config order · Build matrix")
    results = {}

    # ── Discover src/solutions/ ─────────────────────────────────────────────
    section("Discover src/solutions/")
    if not SOLUTIONS_DIR.is_dir():
        fail(f"src/solutions/ directory not found at {SOLUTIONS_DIR}")

    discovered = sorted([
        d.name for d in SOLUTIONS_DIR.iterdir()
        if d.is_dir() and not d.name.startswith(".")
    ])
    ok(f"Found {len(discovered)} solution(s) in src/solutions/: {', '.join(discovered)}")

    # ── Resolve requested set ────────────────────────────────────────────────
    section("Resolve requested solutions")
    input_val = args.solutions.strip()
    if input_val.lower() == "all":
        requested = discovered
        info("Input: 'all' → selecting all discovered solutions")
    else:
        requested = [s.strip() for s in input_val.split(",") if s.strip()]
        unknown = [s for s in requested if s not in discovered]
        if unknown:
            fail(f"Not found in src/solutions/: {', '.join(unknown)}\n"
                 f"       Available: {', '.join(discovered)}")
        ok(f"Requested subset validated: {', '.join(requested)}")

    # ── Apply solutions-config.json order ────────────────────────────────────
    section("Apply solutions-config.json ordering")
    selected = list(requested)
    if CONFIG_FILE.is_file():
        with open(CONFIG_FILE) as f:
            config = json.load(f)
        config_order = [
            e["name"] if isinstance(e, dict) else str(e)
            for e in config.get("solutions", [])
        ]
        requested_set = set(requested)
        ordered = []
        for name in config_order:
            if name in requested_set:
                ordered.append(name)
                requested_set.discard(name)
        ordered.extend(sorted(requested_set))   # unlisted ones appended alpha
        selected = ordered
        ok(f"Config order applied → {' → '.join(selected)}")
        for entry in config.get("solutions", []):
            if isinstance(entry, dict) and entry["name"] in selected:
                info(f"  {entry['name']}: {entry.get('description','')}")
    else:
        warn("No solutions-config.json found — using alphabetical order")

    # ── Build matrix output ─────────────────────────────────────────────────
    section("Matrix outputs")
    matrix        = {"solution": selected}
    solution_list = ", ".join(selected)
    solution_count = len(selected)

    ok(f"matrix         = {json.dumps(matrix)}")
    ok(f"solution-list  = \"{solution_list}\"")
    ok(f"solution-count = {solution_count}")

    results["matrix"]         = matrix
    results["solution-list"]  = solution_list
    results["solution-count"] = solution_count
    results["selected"]       = selected
    return results


# ══════════════════════════════════════════════════════════════════════════════
# JOB 1 — BUILD (parallel per solution)
# ══════════════════════════════════════════════════════════════════════════════
def build_one_solution(solution, args, run_number):
    """Simulate building a single solution. Returns artifact info."""
    job_header(
        f"JOB 1 — 🏗️  Build | {solution}",
        f"_reusable-build.yml · run #{run_number} · parallel (this is job {args.solutions.count(',') + 1 if args.solutions != 'all' else '?'} of N)"
    )
    sol_dir = SOLUTIONS_DIR / solution
    artifact = {}

    # ── actions-install ──────────────────────────────────────────────────────
    section("actions-install@v1")
    ok("PAC CLI and Power Platform Build Tools available in PATH [simulated]")

    # ── Version stamp ────────────────────────────────────────────────────────
    section("Stamp version")
    solution_xml = sol_dir / "Solution.xml"
    if not solution_xml.is_file():
        fail(f"Solution.xml not found at {solution_xml}")

    tree = ET.parse(solution_xml)
    root = tree.getroot()
    ns = ""
    ver_elem = root.find(".//Version")
    if ver_elem is None:
        fail(f"<Version> element not found in {solution_xml}")

    current_ver = ver_elem.text.strip()
    parts = current_ver.split(".")
    major, minor = parts[0], parts[1]
    new_version = f"{major}.{minor}.{run_number}.0"
    ok(f"Read existing version from Solution.xml : {current_ver}")
    ok(f"Stamped new version                     : {c(BOLD, new_version)}  (strategy: run_number)")
    info(f"  steps.stamp-version.outputs.version = \"{new_version}\"")
    artifact["version"] = new_version

    # ── pack-solution ×2 ────────────────────────────────────────────────────
    section("pack-solution@v1 ×2 (Unmanaged + Managed)")
    src_files = list(sol_dir.rglob("*"))
    xml_count  = len([f for f in src_files if f.suffix == ".xml"])
    json_count = len([f for f in src_files if f.suffix == ".json"])
    ok(f"Source tree: {len(src_files)} files ({xml_count} XML, {json_count} JSON)")
    ok(f"[SIMULATED] Packed → out/{solution}_unmanaged.zip")
    ok(f"[SIMULATED] Packed → out/{solution}_managed.zip")

    # ── BlackDuck SCA ────────────────────────────────────────────────────────
    section("BlackDuck SCA (synopsys-sig/detect-action@v1.3.1)")
    if args.lowcode_nocode and not args.no_blackduck:
        ok(f"[SIMULATED] BlackDuck RAPID scan started for {solution}")
        ok("[SIMULATED] No high/critical CVEs found in open-source components")
        ok("[SIMULATED] BlackDuck scan PASSED")
    else:
        reason = "lowcode-nocode=false" if not args.lowcode_nocode else "enable-blackduck=false"
        skip(f"BlackDuck SKIPPED — {reason}")

    # ── Checkmarx SAST ──────────────────────────────────────────────────────
    section("Checkmarx SAST (checkmarx/ast-github-action@main)")
    if args.lowcode_nocode and not args.no_checkmarx:
        ok(f"[SIMULATED] Checkmarx SAST scan started for project: {solution}")
        ok("[SIMULATED] No high/critical SAST findings in custom code")
        ok("[SIMULATED] Checkmarx scan PASSED")
    else:
        reason = "lowcode-nocode=false" if not args.lowcode_nocode else "enable-checkmarx=false"
        skip(f"Checkmarx SKIPPED — {reason}")

    # ── Solution Checker (MANDATORY) ─────────────────────────────────────────
    section("Solution Checker — check-solution@v1  🔴 MANDATORY")
    ok("[SIMULATED] Submitting solution to Power Apps Checker service ...")
    ok("[SIMULATED] Checker geo: UnitedStates")
    ok("[SIMULATED] Analysis complete — 0 critical, 0 high, 2 informational")
    ok(f"[SIMULATED] SARIF report → SolutionChecker-{solution}-{run_number}.sarif")
    ok("Solution Checker PASSED ✓ (fail-on-analysis-error: true)")

    # ── export-data (if schema exists) ───────────────────────────────────────
    section("export-data@v1 (if schema file exists)")
    schema_primary  = CONFIG_DIR / solution / "data-schema.xml"
    schema_fallback = CONFIG_DIR / "data-schema.xml"
    if schema_primary.is_file():
        ok(f"Schema found: config/{solution}/data-schema.xml")
        ok(f"[SIMULATED] Config data exported → out/config-data.zip")
    elif schema_fallback.is_file():
        ok(f"Schema found (fallback): config/data-schema.xml")
        ok(f"[SIMULATED] Config data exported → out/config-data.zip")
    else:
        skip("No data-schema.xml found — export-data step skipped")

    # ── JFrog upload ─────────────────────────────────────────────────────────
    section("JFrog Artifactory upload")
    jfrog_path = f"powerplatform-artifacts/{solution}/{new_version}/"
    ok(f"[SIMULATED] Uploading to JFrog: {jfrog_path}")
    ok(f"[SIMULATED]   → {solution}_unmanaged.zip")
    ok(f"[SIMULATED]   → {solution}_managed.zip")
    ok(f"[SIMULATED]   → SolutionChecker-{solution}-{run_number}.sarif")
    ok("Build info published to Artifactory")

    # ── upload-artifact ──────────────────────────────────────────────────────
    section("actions/upload-artifact@v4")
    artifact_name = f"solution-{solution}-{run_number}"
    ARTIFACTS_DIR.mkdir(exist_ok=True)
    artifact_file = ARTIFACTS_DIR / f"{artifact_name}.json"
    artifact_meta = {
        "artifact-name":     artifact_name,
        "solution-name":     solution,
        "solution-version":  new_version,
        "run-number":        run_number,
        "files":             [f"{solution}_unmanaged.zip", f"{solution}_managed.zip", "config-data.zip"],
        "created-at":        datetime.now().isoformat()
    }
    with open(artifact_file, "w") as f:
        json.dump(artifact_meta, f, indent=2)

    ok(f"Artifact published: {c(BOLD, artifact_name)}")
    info(f"  jobs.build.outputs.artifact-name    = \"{artifact_name}\"")
    info(f"  jobs.build.outputs.solution-version = \"{new_version}\"")
    artifact.update(artifact_meta)
    return artifact


# ══════════════════════════════════════════════════════════════════════════════
# _reusable-deploy — shared deploy logic
# ══════════════════════════════════════════════════════════════════════════════
def resolve_settings_file(env, solution):
    """Mirrors the bash settings-file resolve step in _reusable-deploy.yml."""
    primary  = DEPLOY_SETTINGS / env / f"{solution}.json"
    fallback = DEPLOY_SETTINGS / env / "deployment-settings.json"

    if primary.is_file():
        return str(primary.relative_to(REPO_ROOT)), True
    elif fallback.is_file():
        return str(fallback.relative_to(REPO_ROOT)), True
    else:
        return "", False


def deploy_one_solution(solution, env, solution_type, artifact, args, run_number,
                        enable_version_compare=False, prev_env=None):
    """Simulate deploying a single solution to one environment."""
    section(f"Deploying {c(BOLD, solution)} → {c(BOLD+PURPLE, env.upper())}  [{solution_type}]")

    # ── who-am-i ─────────────────────────────────────────────────────────────
    env_url_var = f"PP_{env.upper()}_URL"
    ok(f"who-am-i@v1 → {env_url_var} [SPN auth validated — simulated]")

    # ── backup-env ───────────────────────────────────────────────────────────
    if args.enable_backup:
        ok(f"backup-environment@v1 → label: \"Pre-deploy {env} #{run_number}\" [simulated]")
    else:
        skip("backup-environment skipped (enable-backup=false)")

    # ── blocking-check ───────────────────────────────────────────────────────
    ok("blocking-check: 0 in-progress async operations found [simulated]")

    # ── version-compare ──────────────────────────────────────────────────────
    if enable_version_compare and prev_env:
        ok(f"version-compare: {solution} v{artifact['solution-version']} in {prev_env} matches {env} [simulated]")
    else:
        skip(f"version-compare skipped (enable-version-compare=false)")

    # ── settings-file resolve ─────────────────────────────────────────────────
    settings_path, settings_exists = resolve_settings_file(env, solution)
    if settings_exists and "deployment-settings.json" not in settings_path:
        ok(f"settings-file → {c(BOLD, settings_path)}  [solution-specific ✓]")
    elif settings_exists:
        warn(f"settings-file → {settings_path}  [legacy fallback]")
    else:
        warn(f"settings-file → NOT FOUND — deploying without deployment settings")

    if settings_exists:
        # Parse and display token replacements
        with open(REPO_ROOT / settings_path) as f:
            ds = json.load(f)
        env_vars = ds.get("EnvironmentVariables", [])
        conn_refs = ds.get("ConnectionReferences", [])
        tokens = []
        for cr in conn_refs:
            cid = cr.get("ConnectionId", "")
            m = re.findall(r'#\{(.+?)\}#', cid)
            tokens.extend(m)
        info(f"  EnvironmentVariables: {len(env_vars)} variable(s)")
        for ev in env_vars:
            info(f"    {ev['SchemaName']} = {ev['Value']}")
        info(f"  ConnectionReferences: {len(conn_refs)} reference(s)")
        for cr in conn_refs:
            logical = cr.get("LogicalName", "?")
            token_match = re.findall(r'#\{(.+?)\}#', cr.get("ConnectionId", ""))
            token_str = f"  ← token: #{{{token_match[0]}}}#" if token_match else ""
            info(f"    {logical}{token_str}")

    # ── mock-deploy guard ─────────────────────────────────────────────────────
    info(f"mock-deploy=true → import-solution SKIPPED (dry run)")

    # ── import-solution SKIPPED (mock) ────────────────────────────────────────
    skip(f"import-solution ({solution_type}) — MOCK DEPLOY, no actual import")

    if args.trigger_upgrade and solution_type == "managed":
        skip(f"upgrade-solution (holding pattern) — MOCK DEPLOY, no actual upgrade")

    # ── publish-customizations ───────────────────────────────────────────────
    skip("publish-customizations — skipped when mock-deploy=true")

    # ── activate-workflows ───────────────────────────────────────────────────
    skip("activate-workflows — skipped when mock-deploy=true")

    # ── import-data ───────────────────────────────────────────────────────────
    skip("import-data — skipped when mock-deploy=true")

    ok(f"{c(GREEN+BOLD,'MOCK DEPLOY COMPLETE')} — {solution} → {env.upper()} (all checks passed, no changes made)")


def job_deploy(solutions, env, solution_type, artifacts, args, run_number,
               enable_version_compare=False, prev_env=None, reviewer=""):
    """Simulate the full deploy job for an environment (sequential × N)."""
    job_header(
        f"🚀  Deploy → {env.upper()}  [{solution_type}]  ×{len(solutions)} solutions",
        f"_reusable-deploy.yml · sequential · max-parallel:1 · environment: {env}"
    )
    for solution in solutions:
        deploy_one_solution(
            solution, env, solution_type,
            artifacts[solution], args, run_number,
            enable_version_compare=enable_version_compare,
            prev_env=prev_env
        )
        divider()


# ══════════════════════════════════════════════════════════════════════════════
# PIPELINE SUMMARY
# ══════════════════════════════════════════════════════════════════════════════
def pipeline_summary(selected, artifacts, envs_run, run_number, args, elapsed):
    job_header("📋  Pipeline Summary", f"run #{run_number} · {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")

    print(f"\n  {c(BOLD,'Solutions processed:')}  {', '.join(selected)}")
    print(f"  {c(BOLD,'Environments run:')}     {', '.join([e.upper() for e in envs_run])}")
    print(f"  {c(BOLD,'mock-deploy:')}          true  (no actual changes made to any environment)")
    print(f"  {c(BOLD,'lowcode-nocode:')}        {str(args.lowcode_nocode).lower()}")
    print()

    # Per-solution build summary
    print(f"  {c(BOLD,'Build artifacts:')}")
    for sol, art in artifacts.items():
        scan_line = ""
        if args.lowcode_nocode:
            bd = c(GREEN,"✓ BlackDuck") if not args.no_blackduck else c(DIM,"⏭ BlackDuck")
            cx = c(GREEN,"✓ Checkmarx") if not args.no_checkmarx else c(DIM,"⏭ Checkmarx")
            scan_line = f"  {bd}  {cx}"
        print(f"    {c(BOLD, sol):<22}  v{art['solution-version']}  "
              f"artifact: {art['artifact-name']}  "
              f"{c(GREEN,'✓ SolutionChecker')}{scan_line}")
    print()

    # Settings files used
    print(f"  {c(BOLD,'Deployment settings resolved:')}")
    for env in envs_run:
        for sol in selected:
            path, exists = resolve_settings_file(env, sol)
            if exists:
                tag = "[solution-specific]" if f"{sol}.json" in path else "[legacy fallback]"
                print(f"    {env.upper():<6} / {sol:<15} → {path}  {c(DIM, tag)}")
            else:
                print(f"    {env.upper():<6} / {sol:<15} → {c(YELLOW,'NOT FOUND — skipped')}")
    print()

    # Stage results
    print(f"  {c(BOLD,'Stage results:')}")
    stages = [("🔍 Setup", "success"), ("🏗️  Build", "success")]
    for env in envs_run:
        if env != "dev":
            stages.append((f"🔐 Gate-{env}", "✓ auto-approved (simulation)"))
        stages.append((f"🚀 Deploy/{env.upper()}", "success (mock-deploy)"))
    stages.append(("📋 Summary", "success"))
    for stage, result in stages:
        color = GREEN if "success" in result or "approved" in result else YELLOW
        print(f"    {stage:<28}  {c(color, result)}")

    print()
    print(c(BOLD+GREEN, f"  ✅  Pipeline simulation COMPLETE — {elapsed:.1f}s"))
    print(c(DIM, f"  Artifacts written to: .sim-artifacts/"))
    print(c(DIM, f"  To run a real pipeline, push to GitHub and trigger workflow_dispatch"))
    print(c(DIM, f"  with mock-deploy=true to safely validate without importing."))
    print()


# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════
def main():
    args = parse_args()
    start = time.time()

    # Banner
    print()
    print(c(BOLD+BLUE,  "  ╔══════════════════════════════════════════════════════════════════════╗"))
    print(c(BOLD+BLUE,  "  ║     GHA-Dynamics · Release Pipeline · Local Dry-Run Simulator       ║"))
    print(c(BOLD+BLUE,  "  ╠══════════════════════════════════════════════════════════════════════╣"))
    print(c(BOLD+BLUE, f"  ║  run #: {args.run_number:<5}  solutions: {args.solutions:<20}               ║"))
    print(c(BOLD+BLUE, f"  ║  mode:  mock-deploy=true  lowcode-nocode={str(args.lowcode_nocode).lower():<5}                  ║"))
    print(c(BOLD+BLUE,  "  ╚══════════════════════════════════════════════════════════════════════╝"))
    print()

    # ── Determine which envs to run ───────────────────────────────────────────
    env_map = {
        "all":            ["dev", "intg", "uat", "frs", "perf", "prod"],
        "dev":            ["dev"],
        "dev-intg":       ["dev", "intg"],
        "dev-intg-uat":   ["dev", "intg", "uat"],
    }
    envs_run = env_map.get(args.target_envs.lower(), ["dev", "intg", "uat", "frs", "perf", "prod"])
    info(f"Target environments: {', '.join([e.upper() for e in envs_run])}")

    # ── JOB 0: Setup ─────────────────────────────────────────────────────────
    setup_out = job_setup(args)
    selected   = setup_out["selected"]

    # ── JOB 1: Build (parallel per solution) ─────────────────────────────────
    print()
    print(c(BOLD, f"  {'━'*70}"))
    print(c(BOLD+GREEN, f"  BUILD PHASE — {len(selected)} solutions built in parallel"))
    print(c(DIM,         "  (In GitHub Actions each solution runs in a separate runner simultaneously)"))
    print(c(BOLD, f"  {'━'*70}"))

    artifacts = {}
    for sol in selected:
        art = build_one_solution(sol, args, args.run_number)
        artifacts[sol] = art

    # ── Deploy phases ─────────────────────────────────────────────────────────
    gate_reviewers = {
        "intg": "Integration Lead",
        "uat":  "QA Lead",
        "frs":  "FRS Test Lead",
        "perf": "Perf Team Lead",
        "prod": "Release Manager",
    }
    prev_env_map = {"intg": "dev", "uat": "intg", "frs": "uat", "perf": "frs", "prod": "perf"}

    for i, env in enumerate(envs_run):
        sol_type = "unmanaged" if env == "dev" else "managed"

        # Gate (not needed for dev in release-pipeline — env: Dev is on the deploy matrix)
        if env != "dev":
            gate_header(env.upper(), gate_reviewers.get(env, "Lead Approver"))
            ok(f"[SIMULATED] {gate_reviewers[env]} approved deployment to {env.upper()}")
            ok(f"All {len(selected)} solution(s) covered by this single approval")

        job_deploy(
            selected, env, sol_type, artifacts, args, args.run_number,
            enable_version_compare=(env != "dev"),
            prev_env=prev_env_map.get(env)
        )

    # ── Summary ───────────────────────────────────────────────────────────────
    elapsed = time.time() - start
    pipeline_summary(selected, artifacts, envs_run, args.run_number, args, elapsed)


if __name__ == "__main__":
    main()
