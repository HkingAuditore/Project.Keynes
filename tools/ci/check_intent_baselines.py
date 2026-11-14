#!/usr/bin/env python3
"""Compare complete intent evidence across runs and optional refactor candidates."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess

from check_golden_determinism import (add_candidate_arguments, difference, fresh_logs,
                                      load_comparison, read_result, write_candidate)
from run_regression_checks import ROOT
from runtime_test_hygiene import trace_environment

FIXTURES = (
    ("fiscal_return_intent", "FISCAL_RETURN_RESULT="),
    ("procurement_intent", "PROCUREMENT_RESULT="),
    ("fiscal_cash_intent", "FISCAL_CASH_RESULT="),
    ("asset_transfer_intent", "ASSET_TRANSFER_RESULT="),
    ("research_intent", "RESEARCH_INTENT_RESULT="),
    ("treasury_spend_intent", "TREASURY_SPEND_RESULT="),
    ("colonization_intent", "COLONIZATION_INTENT_RESULT="),
)


def read_evidence(lines: list[str], prefix: str, exit_code: int) -> tuple[dict | None, list[str]]:
    return read_result(lines, prefix, exit_code)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default=os.environ.get("GODOT_BIN", "godot"))
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--log-dir", type=Path, required=True)
    add_candidate_arguments(parser)
    args = parser.parse_args()
    if args.runs < 2:
        parser.error("at least two runs are required")
    comparison = load_comparison(parser, args.compare_to)
    if comparison is not None and comparison.keys() != {name for name, _ in FIXTURES}:
        parser.error("candidate must contain exactly all seven intent fixtures")
    logs = fresh_logs(parser, args.log_dir)
    rows = []
    first = {}
    for name, prefix in FIXTURES:
        for run in range(1, args.runs + 1):
            environment = trace_environment(os.environ.copy(), logs, f"{name}-{run}")
            path = logs / f"{name}-{run}.log"
            command = [args.godot, "--headless", "--path", str(ROOT / "Project/project-keynes"),
                       "--script", f"res://tests/runtime/{name}_test.gd",
                       "--log-file", str(logs / f"engine-{name}-{run}.log")]
            with path.open("w") as output:
                process = subprocess.run(command, cwd=ROOT, env=environment, stdout=output,
                                         stderr=subprocess.STDOUT, check=False)
            evidence, errors = read_evidence(path.read_text(errors="replace").splitlines(),
                                             prefix, process.returncode)
            if name not in first and evidence is not None and not errors:
                first[name] = evidence
            repeated = difference(first.get(name), evidence, name)
            prior = difference(comparison[name], evidence, name) if comparison is not None else None
            diff = repeated or prior
            valid = not errors and evidence is not None and diff is None
            rows.append(dict(fixture=name, run=run, valid=valid, errors=errors,
                             repeat_difference=repeated, comparison_difference=prior,
                             first_difference=diff, log=str(path)))
            complete = len(rows) == len(FIXTURES) * args.runs
            (logs / "summary.json").write_text(json.dumps(dict(
                compare_to=str(args.compare_to) if args.compare_to else None, runs=args.runs,
                passed=complete and all(row["valid"] for row in rows), results=rows), indent=2) + "\n")
            print(f"{name} run {run}: valid={valid}; first_difference={diff}; errors={errors}", flush=True)
            if not valid:
                return 1
    write_candidate(args.write_candidate, first)
    print(f"PASS: {len(FIXTURES)} fixtures, {args.runs} runs each; summary={logs / 'summary.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
