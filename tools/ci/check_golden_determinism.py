#!/usr/bin/env python3
"""Repeat the golden and compare full daily results and diagnostic economy hashes.

Never writes baselines or changes production knobs. Candidate capture is explicit.
Runs serially, retains initialization/report evidence, and stops immediately if
the reviewed ledger changes or a Godot check fails.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess

from run_regression_checks import ROOT, SHUTDOWN_LEAK


def require_fixed_replay_cadence() -> None:
    """Golden entry points must pin the runtime cadence before advancing days."""
    required = [
        ROOT / "Project/project-keynes/tests/runtime/golden_day_hash_test.gd",
        ROOT / "Project/project-keynes/tests/runtime/golden_external_advancers_test.gd",
        ROOT / "Project/project-keynes/tests/runtime/committed_view_replay_test.gd",
    ]
    marker = 'replay_cadence.gd").install'
    missing = [str(path) for path in required if marker not in path.read_text()]
    if missing:
        raise SystemExit("fixed replay cadence missing from: " + ", ".join(missing))


def records(lines: list[str], prefix: str) -> list[dict]:
    return [json.loads(line[len(prefix):]) for line in lines if line.startswith(prefix)]


def difference(expected, actual, path="result"):
    """Name the first differing day/domain/field; never suppress a changed domain."""
    if type(expected) is not type(actual):
        return {"path": path, "expected": expected, "actual": actual}
    if isinstance(expected, dict):
        if expected.keys() != actual.keys():
            return {"path": path, "expected_keys": sorted(expected), "actual_keys": sorted(actual)}
        for key in sorted(expected, key=lambda key: (key != "domain_hashes", key.endswith("chain"), key)):
            found = difference(expected[key], actual[key], f"{path}.{key}")
            if found: return found
    elif isinstance(expected, list):
        if len(expected) != len(actual):
            return {"path": path, "expected_length": len(expected), "actual_length": len(actual)}
        for index, (left, right) in enumerate(zip(expected, actual)):
            found = difference(left, right, f"{path}[{index}]")
            if found: return found
    elif expected != actual:
        return {"path": path, "expected": expected, "actual": actual}
    return None


def run_external(args, logs: Path) -> int:
    baseline_path = ROOT / "Project/project-keynes/tests/runtime/golden_external_advancers_baseline.v5.json"
    expected = None if args.capture_candidate else json.loads(baseline_path.read_text())
    command = [args.godot, "--headless", "--path", str(ROOT / "Project/project-keynes"),
               "--script", "res://tests/runtime/golden_external_advancers_test.gd"]
    runs = []
    for index in range(1, args.runs + 1):
        environment = os.environ.copy()
        environment["PK_GOLDEN_DIAGNOSTICS"] = "1"
        environment["PK_GOLDEN_EXTERNAL_CAPTURE"] = "1" if args.capture_candidate else "0"
        log = logs / f"run-{index}.log"
        with log.open("w") as output:
            process = subprocess.run(command, env=environment, stdout=output,
                                     stderr=subprocess.STDOUT, check=False)
        lines = log.read_text(errors="replace").splitlines()
        errors = [line for line in lines if line.startswith("ERROR:") or "SCRIPT ERROR:" in line
                  or "[FAIL]" in line or SHUTDOWN_LEAK.search(line)]
        results = records(lines, "GOLDEN_EXTERNAL_RESULT=")
        actual = results[0] if len(results) == 1 else None
        if expected is None and actual is not None:
            expected = actual
            (logs / "candidate.json").write_text(json.dumps(expected, indent=2) + "\n")
        diff = difference(expected, actual)
        valid = process.returncode == 0 and not errors and actual is not None and diff is None
        runs.append({"run": index, "valid": valid, "exit": process.returncode, "errors": errors,
                     "first_difference": diff, "chain": actual["days"][-1]["chain"] if actual and actual["days"] else None})
        passed = len(runs) == args.runs and all(row["valid"] for row in runs)
        (logs / "summary.json").write_text(json.dumps({"command": command,
            "capture_candidate": args.capture_candidate, "requested_runs": args.runs,
            "completed_runs": len(runs), "passed": passed, "runs": runs}, indent=2) + "\n")
        print(f"v5 run {index}: valid={valid} chain={runs[-1]['chain']} first_difference={diff}", flush=True)
        if not valid:
            return 1
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default=os.environ.get("GODOT_BIN", "godot"))
    parser.add_argument("--runs", type=int, default=10)
    parser.add_argument("--log-dir", type=Path, required=True)
    parser.add_argument("--capture-candidate", action="store_true",
                        help="compare runs to the first candidate, without accepting a baseline")
    parser.add_argument("--legacy-only", action="store_true",
                        help="disable domain diagnostics and compare the preserved v2 baseline")
    parser.add_argument("--external-only", action="store_true", help="run the independent v5 advancer fixture")
    args = parser.parse_args()
    require_fixed_replay_cadence()
    if args.runs < 2:
        parser.error("--runs must be at least 2")
    logs = args.log_dir.resolve()
    logs.mkdir(parents=True, exist_ok=True)
    if any(logs.glob("run-*.log")) or (logs / "summary.json").exists():
        parser.error("use a fresh log directory to preserve previous evidence")
    if args.external_only:
        if args.legacy_only:
            parser.error("--external-only and --legacy-only are separate fixtures")
        return run_external(args, logs)
    filename = "golden_day_hash_baseline.v2.json" if args.legacy_only else "golden_day_hash_baseline.json"
    baseline = json.loads((ROOT / "Project/project-keynes/tests/runtime" / filename).read_text())
    expected_days = [row["day"] for row in baseline["days"]]
    expected_result = None if args.capture_candidate else baseline
    runs: list[dict] = []
    first_difference = None
    first_hashes = None
    first_excluded = None
    excluded_difference = None
    failed = False
    command = [args.godot, "--headless", "--path", str(ROOT / "Project/project-keynes"),
               "--script", "res://tests/runtime/golden_day_hash_test.gd"]
    for index in range(1, args.runs + 1):
        environment = os.environ.copy()
        environment.pop("PK_GOLDEN_CAPTURE", None)
        environment["PK_GOLDEN_LEGACY_ONLY"] = "1" if args.legacy_only else "0"
        if args.capture_candidate:
            environment["PK_GOLDEN_CAPTURE"] = "1"
        environment["PK_GOLDEN_DIAGNOSTICS"] = "1"
        environment["PK_SIM_DAY_TRACE"] = str((logs / f"trace-{index}.log").resolve())
        log = logs / f"run-{index}.log"
        with log.open("w") as output:
            process = subprocess.run(command, cwd=ROOT, env=environment,
                                     stdout=output, stderr=subprocess.STDOUT, check=False)
        lines = log.read_text(errors="replace").splitlines()
        errors = [line for line in lines if line.startswith("ERROR:")
                  or "SCRIPT ERROR:" in line or "[FAIL]" in line or SHUTDOWN_LEAK.search(line)]
        try:
            golden = records(lines, "GOLDEN_RESULT=")
            diagnostics = records(lines, "GOLDEN_DIAGNOSTIC=")
            bootstrap = records(lines, "GOLDEN_BOOTSTRAP=")
            excluded = records(lines, "GOLDEN_DOMAIN_EXCLUDED=")
            if first_excluded is None:
                first_excluded = excluded
            elif excluded_difference is None:
                excluded_difference = difference(first_excluded, excluded, "excluded_domains")
            if expected_result is None and len(golden) == 1:
                expected_result = golden[0]
                (logs / "candidate.json").write_text(json.dumps(expected_result, indent=2) + "\n")
            ledger_matches = golden == [expected_result]
            if not ledger_matches and len(golden) == 1 and first_difference is None:
                first_difference = difference(expected_result, golden[0])
            shape_ok = ([row["day"] for row in diagnostics] == expected_days
                        and len(bootstrap) == 1
                        and all(isinstance(row.get("whole_economy_hash"), str)
                                and row["whole_economy_hash"].isdigit() for row in diagnostics))
        except (ValueError, KeyError, TypeError) as error:
            errors.append(f"invalid diagnostic JSON: {error}")
            diagnostics, bootstrap = [], []
            ledger_matches = shape_ok = False
        hashes = [row["whole_economy_hash"] for row in diagnostics] if shape_ok else []
        valid = process.returncode == 0 and not errors and ledger_matches and shape_ok
        row = {"run": index, "exit": process.returncode, "valid": valid,
               "ledger_matches": ledger_matches, "economy_hashes": hashes, "errors": errors}
        if valid:
            row["ledger_chain"] = golden[0]["days"][-1]["chain"]
            row["whole_economy_chain"] = golden[0]["days"][-1]["whole_economy_chain"]
            row["domain_chain"] = golden[0]["days"][-1].get("domain_chain")
            row["country_chain"] = golden[0]["days"][-1].get("country_chain")
            row["domain_hashes"] = [day.get("domain_hashes", {}) for day in golden[0]["days"]]
            row["resource_columns"] = bootstrap[0]["resource_columns"]
            if first_hashes is None:
                first_hashes = hashes
            elif first_difference is None and hashes != first_hashes:
                day = next(i for i, pair in enumerate(zip(first_hashes, hashes)) if pair[0] != pair[1])
                first_difference = {"run": index, "day": expected_days[day],
                                    "reference": first_hashes[day], "actual": hashes[day]}
        runs.append(row)
        failed = failed or not valid
        summary = {"command": command, "capture_candidate": args.capture_candidate, "requested_runs": args.runs, "completed_runs": len(runs),
                   "first_difference": first_difference, "excluded_domain_first_difference": excluded_difference, "runs": runs,
                   "passed": len(runs) == args.runs and not failed and first_difference is None}
        (logs / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        print(f"run {index}: valid={valid} baseline_matches={ledger_matches} "
              f"domains={row.get('domain_chain')} first_difference={first_difference}", flush=True)
        if not valid:
            print("Stopped: ledger mismatch, missing evidence, or Godot failure.")
            return 1
    print(f"{'PASS' if summary['passed'] else 'FAIL'}: {len(runs)} runs; "
          f"first_difference={first_difference}; summary={logs / 'summary.json'}")
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
