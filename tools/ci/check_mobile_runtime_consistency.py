#!/usr/bin/env python3
"""Compare the real mobile-selected worker with inline days, including CPU load."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time

from check_golden_determinism import difference, read_result
from check_runtime_load_consistency import (
    PROJECT, ROOT, Pressure, daily_coverage, identity, pressure_errors, write_json,
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True)
    parser.add_argument("--log-dir", type=Path, required=True)
    parser.add_argument("--workers", type=int, default=2)
    args = parser.parse_args()
    if args.workers < 1:
        parser.error("--workers must be positive for the load comparison")
    args.log_dir = args.log_dir.resolve()
    args.log_dir.mkdir(parents=True, exist_ok=False)
    before = identity()
    write_json(args.log_dir / "identity-before.json", before)
    runs = []
    reference = None
    cases = [("inline", ["--reference-inline"], 0), ("android", [], 0),
             ("ios", ["--platform=ios"], 0),
             ("android-load-1", [], args.workers),
             ("android-load-2", [], args.workers)]
    for name, switches, count in cases:
        directory = args.log_dir / name
        directory.mkdir()
        environment = {k: v for k, v in os.environ.items() if not k.startswith("PK_")}
        environment["PK_GOLDEN_DIAGNOSTICS"] = "1"
        command = [args.godot, "--headless", "--path", str(PROJECT), "--script",
                   "res://tests/runtime/mobile_runtime_worker_test.gd",
                   "--log-file", str(directory / "engine.log"), "--", *switches]
        write_json(directory / "invocation.json", {"command": command, "workers": count})
        pressure = Pressure(directory, count)
        try:
            pressure.start()
            start = time.monotonic()
            with (directory / "stdout.log").open("w") as stream:
                process = subprocess.run(command, cwd=ROOT, env=environment,
                                         stdout=stream, stderr=subprocess.STDOUT)
            end = time.monotonic()
        finally:
            workers = pressure.stop()
            write_json(directory / "pressure.json", workers)
        lines = (directory / "stdout.log").read_text(errors="replace").splitlines()
        result, errors = read_result(lines, "GOLDEN_RESULT=", process.returncode)
        if result:
            errors += daily_coverage(result, lines)
        timing = [json.loads(line.split("=", 1)[1]) for line in lines
                  if line.startswith("MOBILE_EXECUTION=")]
        if len(timing) != 1 or timing[0].get("inline") != (name == "inline"):
            errors.append("missing or incorrect execution-path evidence")
        if name == "inline":
            reference = result
        mismatch = difference(reference, result) if reference and result else {"missing": True}
        load_errors = pressure_errors(workers, start, end, count) if count else []
        row = {"name": name, "exit": process.returncode, "evidence_errors": errors,
               "pressure_errors": load_errors, "first_difference": mismatch,
               "seconds": end - start, "execution": timing}
        runs.append(row)
        write_json(directory / "result.json", result)
        write_json(args.log_dir / "runs.json", runs)
        print(f"{name}: errors={len(errors)}, load_errors={len(load_errors)}, "
              f"equal={mismatch is None}", flush=True)
    after = identity()
    unchanged = before == after
    passed = unchanged and all(not row["evidence_errors"] and not row["pressure_errors"]
                               and row["first_difference"] is None for row in runs)
    write_json(args.log_dir / "identity-after.json", after)
    write_json(args.log_dir / "summary.json",
               {"passed": passed, "source_unchanged": unchanged, "runs": runs})
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
