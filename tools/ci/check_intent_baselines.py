#!/usr/bin/env python3
"""Check complete transaction/save evidence, or collect repeatable candidates.

Capture never changes the reviewed files. It still rejects failed assertions,
script errors, leaks, missing evidence, and differences between repeated runs.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess

from check_golden_determinism import difference
from run_regression_checks import ROOT, SHUTDOWN_LEAK
from runtime_test_hygiene import trace_environment

FIXTURES = (
    ("fiscal_return_intent", "FISCAL_RETURN_RESULT=", "PK_FISCAL_RETURN_CAPTURE"),
    ("procurement_intent", "PROCUREMENT_RESULT=", "PK_PROCUREMENT_CAPTURE"),
    ("fiscal_cash_intent", "FISCAL_CASH_RESULT=", "PK_FISCAL_CASH_CAPTURE"),
    ("asset_transfer_intent", "ASSET_TRANSFER_RESULT=", "PK_ASSET_TRANSFER_CAPTURE"),
    ("research_intent", "RESEARCH_INTENT_RESULT=", "PK_RESEARCH_INTENT_CAPTURE"),
    ("treasury_spend_intent", "TREASURY_SPEND_RESULT=", "PK_TREASURY_SPEND_CAPTURE"),
    ("colonization_intent", "COLONIZATION_INTENT_RESULT=", "PK_COLONIZATION_INTENT_CAPTURE"),
)


def read_evidence(lines: list[str], prefix: str, exit_code: int) -> tuple[dict | None, list[str]]:
    errors = [line for line in lines if line.startswith("ERROR:") or
              "SCRIPT ERROR:" in line or "[FAIL]" in line or SHUTDOWN_LEAK.search(line)]
    if exit_code:
        errors.append(f"exit={exit_code}")
    payloads = [line[len(prefix):] for line in lines if line.startswith(prefix)]
    if len(payloads) != 1:
        return None, errors + [f"expected one {prefix} record; found {len(payloads)}"]
    try:
        evidence = json.loads(payloads[0])
    except json.JSONDecodeError as error:
        return None, errors + [f"invalid evidence JSON: {error}"]
    if not isinstance(evidence, dict) or not evidence:
        return None, errors + ["evidence must be a nonempty object"]
    return evidence, errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default=os.environ.get("GODOT_BIN", "godot"))
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--log-dir", type=Path, required=True)
    parser.add_argument("--capture-candidate", action="store_true")
    args = parser.parse_args()
    if args.runs < 2:
        parser.error("at least two runs are required")
    logs = args.log_dir.resolve()
    logs.mkdir(parents=True, exist_ok=False)
    rows = []
    for name, prefix, capture_env in FIXTURES:
        baseline = ROOT / f"Project/project-keynes/tests/runtime/{name}_baseline.json"
        reference = None if args.capture_candidate else json.loads(baseline.read_text())
        for run in range(1, args.runs + 1):
            environment = os.environ.copy()
            environment[capture_env] = "1" if args.capture_candidate else "0"
            environment = trace_environment(environment, logs, f"{name}-{run}")
            path = logs / f"{name}-{run}.log"
            command = [args.godot, "--headless", "--path", str(ROOT / "Project/project-keynes"),
                       "--script", f"res://tests/runtime/{name}_test.gd"]
            with path.open("w") as output:
                process = subprocess.run(command, cwd=ROOT, env=environment, stdout=output,
                                         stderr=subprocess.STDOUT, check=False)
            evidence, errors = read_evidence(path.read_text(errors="replace").splitlines(),
                                             prefix, process.returncode)
            if reference is None and evidence is not None and not errors:
                reference = evidence
                (logs / f"{name}_candidate.json").write_text(json.dumps(evidence, indent=2) + "\n")
            diff = difference(reference, evidence)
            valid = not errors and evidence is not None and diff is None
            rows.append(dict(fixture=name, run=run, valid=valid, errors=errors,
                             first_difference=diff, log=str(path)))
            complete = len(rows) == len(FIXTURES) * args.runs
            (logs / "summary.json").write_text(json.dumps(dict(
                capture_candidate=args.capture_candidate, runs=args.runs,
                passed=complete and all(row["valid"] for row in rows), results=rows), indent=2) + "\n")
            print(f"{name} run {run}: valid={valid}; first_difference={diff}", flush=True)
            if not valid:
                return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
