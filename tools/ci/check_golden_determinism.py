#!/usr/bin/env python3
"""Check repeated daily results and optional temporary refactor evidence."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess

from run_regression_checks import ROOT, SHUTDOWN_LEAK, is_engine_error


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


def candidate_path(value: str) -> Path:
    """Resolve symlinks too, so a path outside cannot alias a tracked file."""
    path = Path(value)
    if not path.is_absolute():
        raise argparse.ArgumentTypeError("candidate path must be absolute")
    path = path.resolve()
    if path.is_relative_to(ROOT.resolve()):
        raise argparse.ArgumentTypeError("candidate path must be outside the repository")
    return path


def add_candidate_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--write-candidate", type=candidate_path,
                        help="write the first valid result outside the repository")
    parser.add_argument("--compare-to", type=candidate_path,
                        help="also compare every field with earlier refactor evidence")


def load_comparison(parser, path: Path | None) -> dict | None:
    if path is None:
        return None
    try:
        value = json.loads(path.read_text())
        if not isinstance(value, dict) or not value:
            raise ValueError("candidate must be a nonempty object")
        return value
    except (OSError, ValueError) as error:
        parser.error(f"cannot read candidate: {error}")


def fresh_logs(parser, path: Path) -> Path:
    logs = path.resolve()
    logs.mkdir(parents=True, exist_ok=True)
    if any(logs.iterdir()):
        parser.error("use a fresh empty log directory to preserve previous evidence")
    return logs


def write_candidate(path: Path | None, result: dict) -> None:
    if path is not None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(result, indent=2) + "\n")


def read_result(lines: list[str], prefix: str, exit_code: int) -> tuple[dict | None, list[str]]:
    errors = [line for line in lines if is_engine_error(line) or "SCRIPT ERROR:" in line
              or "[FAIL]" in line or SHUTDOWN_LEAK.search(line)]
    if exit_code:
        errors.append(f"exit={exit_code}")
    try:
        values = records(lines, prefix)
        if len(values) != 1 or not isinstance(values[0], dict) or not values[0]:
            return None, errors + [f"expected one nonempty {prefix} object; found {len(values)}"]
        return values[0], errors
    except (ValueError, TypeError) as error:
        return None, errors + [f"invalid evidence JSON: {error}"]


def daily_evidence_errors(actual: dict, lines: list[str], external: bool) -> list[str]:
    days = actual.get("days")
    expected_days = list(range(1, 5 if external else 9))
    if not isinstance(days, list) or [row.get("day") for row in days] != expected_days:
        return ["missing or unordered daily evidence"]
    if external:
        domains = {"MILITARY", "NATURAL_RESOURCE", "FAMILY", "PERSON", "VISION"}
        if any(set(row.get("hashes", {})) != domains for row in days):
            return ["missing external domain evidence"]
        return []
    domains = {"CLIMATE", "TRIGGER_INPUT", "IDEOLOGY", "EFFECT", "MODIFIER", "ECONOMY", "EVENTS", "COUNTRY"}
    if any(set(row.get("domain_hashes", {})) != domains for row in days):
        return ["missing daily domain evidence"]
    diagnostics = records(lines, "GOLDEN_DIAGNOSTIC=")
    bootstrap = records(lines, "GOLDEN_BOOTSTRAP=")
    if len(bootstrap) != 1 or [row.get("day") for row in diagnostics] != expected_days:
        return ["missing initialization or daily diagnostics"]
    if any(not isinstance(row.get("whole_economy_hash"), str)
           or not row["whole_economy_hash"].isdigit()
           or row["whole_economy_hash"] != day.get("whole_economy_hash")
           for row, day in zip(diagnostics, days)):
        return ["invalid diagnostic economy hash"]
    return []


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default=os.environ.get("GODOT_BIN", "godot"))
    parser.add_argument("--runs", type=int, default=10)
    parser.add_argument("--log-dir", type=Path, required=True)
    add_candidate_arguments(parser)
    parser.add_argument("--external-only", action="store_true", help="run the independent external advancer fixture")
    args = parser.parse_args()
    if args.runs < 2:
        parser.error("--runs must be at least 2")
    comparison = load_comparison(parser, args.compare_to)
    logs = fresh_logs(parser, args.log_dir)
    require_fixed_replay_cadence()
    name = "golden_external_advancers" if args.external_only else "golden_day_hash"
    prefix = "GOLDEN_EXTERNAL_RESULT=" if args.external_only else "GOLDEN_RESULT="
    command = [args.godot, "--headless", "--path", str(ROOT / "Project/project-keynes"),
               "--script", f"res://tests/runtime/{name}_test.gd"]
    first = None
    first_bootstrap = None
    runs = []
    for index in range(1, args.runs + 1):
        environment = os.environ.copy()
        environment["PK_GOLDEN_DIAGNOSTICS"] = "1"
        environment["PK_SIM_DAY_TRACE"] = str(logs / f"trace-{index}.log")
        log = logs / f"run-{index}.log"
        with log.open("w") as output:
            process = subprocess.run(command + ["--log-file", str(logs / f"engine-{index}.log")],
                                     cwd=ROOT, env=environment, stdout=output,
                                     stderr=subprocess.STDOUT, check=False)
        lines = log.read_text(errors="replace").splitlines()
        actual, errors = read_result(lines, prefix, process.returncode)
        try:
            if actual is not None:
                errors.extend(daily_evidence_errors(actual, lines, args.external_only))
            bootstrap = records(lines, "GOLDEN_BOOTSTRAP=")
        except (ValueError, TypeError, KeyError, AttributeError) as error:
            errors.append(f"invalid daily evidence: {error}")
            bootstrap = []
        if first is None and actual is not None and not errors:
            first = actual
            first_bootstrap = bootstrap
            write_candidate(args.write_candidate, first)
        repeated = difference(first, actual)
        prior = difference(comparison, actual) if comparison is not None else None
        bootstrap_diff = difference(first_bootstrap, bootstrap, "bootstrap")
        diff = repeated or prior or bootstrap_diff
        valid = actual is not None and not errors and diff is None
        runs.append(dict(run=index, valid=valid, exit=process.returncode, errors=errors,
                         repeat_difference=repeated, comparison_difference=prior,
                         first_difference=diff))
        summary = dict(command=command, requested_runs=args.runs, completed_runs=len(runs),
                       compare_to=str(args.compare_to) if args.compare_to else None,
                       passed=len(runs) == args.runs and all(row["valid"] for row in runs), runs=runs)
        (logs / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        print(f"run {index}: valid={valid}; first_difference={diff}; errors={errors}", flush=True)
        if not valid:
            return 1
    print(f"PASS: {len(runs)} runs; summary={logs / 'summary.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
