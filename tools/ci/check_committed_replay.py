#!/usr/bin/env python3
"""Replay a nonempty command log twice; optionally compare a PKSV continuation.

No golden baselines are written. On checkpoint divergence, retain evidence and
stop; do not normalize away generations, state dates or entire domains.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
from check_golden_determinism import difference, records
from run_regression_checks import ROOT, SHUTDOWN_LEAK

def continuation_scan(expected, actual):
    """Report every observed domain/day; a passing subset never passes the run."""
    if not isinstance(expected, dict) or not isinstance(actual, dict):
        return {"valid_payloads": False, "rows": []}
    reference = {row["day"]: row for row in expected.get("rows", [])}
    rows = []
    for row in actual.get("rows", []):
        before = reference.get(row["day"], {})
        domains = {}
        for name in sorted(set(before.get("domains", {})) | set(row.get("domains", {}))):
            left = before.get("domains", {}).get(name)
            right = row.get("domains", {}).get(name)
            domains[name] = {"equal": left == right, "expected": left, "actual": right,
                             "first_difference": difference(left, right)}
        extras = {key: {"equal": before.get(key) == row.get(key),
                        "first_difference": difference(before.get(key), row.get(key))}
                  for key in ("whole_economy_hash", "military", "resources")}
        rows.append({"day": row["day"], "domains": domains, "other": extras})
    return {"valid_payloads": True, "rows": rows}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True)
    parser.add_argument("--log-dir", type=Path, required=True)
    parser.add_argument("--checkpoint", action="store_true")
    parser.add_argument("--days", type=int, default=4, help="total days")
    parser.add_argument("--scenario", choices=["standard", "mixed", "calendar", "multicountry", "military"], default="standard")
    parser.add_argument("--save-day", type=int, default=2)
    parser.add_argument("--trace", action="store_true",
                        help="retain existing native per-field/stage traces for each process")
    parser.add_argument("--autosave", action="store_true",
                        help="keep the real annual coordinator enabled in the calendar fixture")
    parser.add_argument("--year-days", type=int, help="calendar length (default 8; autosave 365)")
    parser.add_argument("--slot", default="autosave",
                        help="resume slot; useful with --autosave (default: manual_3)")
    parser.add_argument("--project", type=Path, default=ROOT / "Project/project-keynes")
    args = parser.parse_args()
    if not 1 <= args.save_day < args.days:
        parser.error("save-day must be >= 1 and < days")
    args.log_dir.mkdir(parents=True, exist_ok=False)
    command = [args.godot, "--headless", "--path", str(args.project.resolve()),
               "--script", "res://tests/runtime/committed_view_replay_test.gd"]
    modes = ["original", "replay"] + (["checkpoint", "resume"] if args.checkpoint else [])
    reference = None
    results = []
    for mode in modes:
        env = os.environ.copy()
        env["PK_COMMITTED_REPLAY_MODE"] = mode
        env["PK_COMMITTED_REPLAY_SCENARIO"] = args.scenario
        env["PK_COMMITTED_REPLAY_SAVE_DAY"] = str(args.save_day)
        env["PK_COMMITTED_REPLAY_DAYS"] = str(args.days)
        if args.year_days is not None:
            env["PK_COMMITTED_REPLAY_YEAR_DAYS"] = str(args.year_days)
        if args.autosave:
            env["PK_COMMITTED_REPLAY_AUTOSAVE"] = "1"
            env["PK_COMMITTED_REPLAY_SLOT"] = args.slot
            env["PK_COMMITTED_REPLAY_YEAR_DAYS"] = str(args.year_days or 365)
            if mode == "resume":
                import shutil
                shutil.copyfile(args.log_dir / "saves/annual-checkpoint.pksv", args.log_dir / "saves/autosave.pksv")
        env["PK_SAVE_DIR"] = str(args.log_dir.resolve() / "saves")
        if args.trace:
            env["PK_SIM_DAY_TRACE"] = str(args.log_dir.resolve() / (mode + ".trace"))
            env["PK_GOLDEN_COUNTRY_TRACE"] = str(args.log_dir.resolve() / (mode + ".country"))
        log = args.log_dir / (mode + ".log")
        with log.open("w") as stream:
            process = subprocess.run(command, env=env, stdout=stream, stderr=subprocess.STDOUT)
        lines = log.read_text(errors="replace").splitlines()
        errors = [line for line in lines if "SCRIPT ERROR:" in line or "[FAIL]" in line or
                  line.startswith("ERROR:") or SHUTDOWN_LEAK.search(line)]
        payloads = records(lines, "COMMITTED_REPLAY_RESULT=")
        actual = payloads[0] if len(payloads) == 1 else None
        if reference is None: reference = actual
        expected = reference
        if mode == "resume" and reference:
            expected = dict(reference, rows=[row for row in reference["rows"] if row["day"] > args.save_day])
        diff = difference(expected, actual)
        if mode == "resume":
            (args.log_dir / "continuation-scan.json").write_text(
                json.dumps(continuation_scan(expected, actual), indent=2) + "\n")
        valid = process.returncode == 0 and not errors and actual is not None and diff is None
        results.append(dict(mode=mode, valid=valid, exit=process.returncode,
                            errors=errors, first_difference=diff, actual=actual))
        (args.log_dir / "summary.json").write_text(json.dumps(results, indent=2) + "\n")
        print(f"{mode}: valid={valid}; first_difference={diff}", flush=True)
        if not valid: return 1
    return 0
if __name__ == "__main__":
    raise SystemExit(main())
