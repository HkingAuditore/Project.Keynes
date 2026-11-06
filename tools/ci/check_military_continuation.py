#!/usr/bin/env python3
"""Opt-in nonzero synchronous pay and pending D+1 PKMI continuation comparison."""
import argparse
import json
import os
from pathlib import Path
import subprocess
from check_golden_determinism import difference, records
from run_regression_checks import ROOT, SHUTDOWN_LEAK

def projection(trace):
    native = next(row["result"] for row in trace if row["stage"] == "native_production_methods")
    # Compare all money/receipt rows, not diagnostic report timing.
    daily = [dict(row, report={k: v for k, v in row["report"].items()
                              if k not in ("capture_ms", "day_ms")})
             for row in trace if row["stage"] == "actual_deferred_bridge"]
    return dict(native=native.get("trace"), continuation=native.get("continuation"),
                checks=native.get("checks"), deferred_checks=native.get("deferred_checks"),
                daily=daily)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True)
    parser.add_argument("--military-fiscal-probe", type=Path, required=True)
    parser.add_argument("--log-dir", type=Path, required=True)
    args = parser.parse_args()
    args.log_dir.mkdir(parents=True, exist_ok=False)
    reference = None
    results = []
    for mode in ("continuous", "restored"):
        env = os.environ.copy()
        env["PK_MILITARY_CHECKPOINT"] = "1" if mode == "restored" else "0"
        log = args.log_dir / (mode + ".log")
        with log.open("w") as stream:
            run = subprocess.run([args.godot, "--headless", "--path", str(ROOT / "Project/project-keynes"),
                "--script", "res://tests/runtime/military_fiscal_semantics_test.gd", "--",
                "--native-probe=" + str(args.military_fiscal_probe.resolve())], env=env,
                stdout=stream, stderr=subprocess.STDOUT)
        lines = log.read_text().splitlines()
        errors = [line for line in lines if "SCRIPT ERROR:" in line or "[FAIL]" in line
                  or line.startswith("ERROR:") or SHUTDOWN_LEAK.search(line)]
        traces = records(lines, "MILITARY_FISCAL_TRACE=")
        actual = projection(traces[0]) if len(traces) == 1 else None
        if reference is None: reference = actual
        diff = difference(reference, actual)
        valid = run.returncode == 0 and not errors and actual is not None and diff is None
        results.append(dict(mode=mode, valid=valid, exit=run.returncode, errors=errors,
                            first_difference=diff, actual=actual))
        (args.log_dir / "summary.json").write_text(json.dumps(results, indent=2) + "\n")
        print(f"{mode}: valid={valid}; first_difference={diff}", flush=True)
        if not valid: return 1
    return 0
if __name__ == "__main__": raise SystemExit(main())
