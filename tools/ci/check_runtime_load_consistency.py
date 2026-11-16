#!/usr/bin/env python3
"""Compare production days, dated commands and saved continuation under CPU load.

Run the current implementation, preserve every observation, never retry a failure.
No golden baseline is written and no runtime timing is injected in the daily case.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import select
import shutil
import subprocess
import sys
import time

from check_committed_replay import EXPECTED_DOMAINS, continuation_scan, coverage_errors
from check_golden_determinism import candidate_path, difference, read_result, records
from run_regression_checks import ROOT

PROJECT = ROOT / "Project/project-keynes"
DAILY_DAYS, COMMAND_DAYS, SAVE_DAY = 30, 35, 5


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def identity():
    roots = ["gdext/src", "Project/project-keynes/scripts", "Project/project-keynes/data",
             "Project/project-keynes/scenes", "Project/project-keynes/tests", "tools/ci"]
    paths = subprocess.check_output(["rg", "--files", *roots], cwd=ROOT, text=True).splitlines()
    paths = [p for p in paths if Path(p).suffix not in {".uid", ".pyc"}]
    mapping = PROJECT / "addons/dots_ext/dots_ext.gdextension"
    feature = {"Darwin": "macos", "Linux": "linux", "Windows": "windows"}[platform.system()]
    arch = "arm64" if platform.machine().lower() in {"arm64", "aarch64"} else "x86_64"
    key = f"{feature}.debug.{arch}"
    value = next(line.split("=", 1)[1].strip().strip('"') for line in mapping.read_text().splitlines()
                 if line.split("=", 1)[0].strip() == key)
    library = PROJECT / value.removeprefix("res://")
    paths += [str(p.relative_to(ROOT)) for p in (mapping, PROJECT / "project.godot", library)]
    paths += ["gdext/SConstruct"]
    return {"files": {p: sha256(ROOT / p) for p in sorted(set(paths))},
            "library": str(library), "library_sha256": sha256(library),
            "head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()}


def load_snapshot():
    # Process names only: unrelated command arguments may contain private data.
    output = subprocess.check_output(["ps", "-Ao", "pid,ppid,pcpu,comm", "-r"], text=True)
    return {"monotonic": time.monotonic(), "load_average": os.getloadavg(),
            "top_processes": output.splitlines()[:21]}


def pressure_worker(ready_fd):
    iterations = 0
    digest = bytes(32)
    def emit(kind):
        print(json.dumps({"kind": kind, "pid": os.getpid(), "monotonic": time.monotonic(),
                          "cpu_seconds": time.process_time(), "iterations": iterations}), flush=True)
    emit("ready")
    os.write(ready_fd, b"1")
    os.close(ready_fd)
    previous = time.monotonic()
    while not select.select([sys.stdin], [], [], 0)[0]:
        for _ in range(4096):
            digest = hashlib.sha256(digest).digest()
        iterations += 4096
        if time.monotonic() - previous >= 1.0:
            emit("working")
            previous = time.monotonic()
    emit("finished")
    return 0


def pressure_errors(workers, start, end, count):
    errors = []
    if len(workers) != count:
        errors.append("missing pressure workers")
    for worker in workers:
        rows = worker.get("samples", [])
        name = f"pressure worker {worker.get('pid')}"
        if worker.get("exit") != 0 or not rows or rows[0].get("kind") != "ready" or rows[-1].get("kind") != "finished":
            errors.append(name + ": incomplete lifetime")
            continue
        if rows[0]["monotonic"] > start or rows[-1]["monotonic"] < end:
            errors.append(name + ": did not cover the whole Godot process")
        inside = [row for row in rows if start <= row["monotonic"] <= end]
        if len(inside) < 2 or inside[-1]["cpu_seconds"] <= inside[0]["cpu_seconds"] or inside[-1]["iterations"] <= inside[0]["iterations"]:
            errors.append(name + ": no measured work inside Godot's observation window")
    return errors


class Pressure:
    def __init__(self, directory, count):
        self.directory, self.count, self.children = directory, count, []

    def start(self):
        for number in range(self.count):
            path = self.directory / f"pressure-{number}.jsonl"
            stream = path.open("w")
            ready_read, ready_write = os.pipe()
            try:
                process = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "--pressure-worker", str(ready_write)],
                                           stdin=subprocess.PIPE, stdout=stream, stderr=stream, pass_fds=(ready_write,))
            finally:
                os.close(ready_write)
            self.children.append((process, stream, path))
            # Read the explicit readiness handshake before launching the game.
            try:
                ready = os.read(ready_read, 1)
            finally:
                os.close(ready_read)
            if ready != b"1":
                raise RuntimeError("CPU worker failed before its readiness handshake")

    def stop(self):
        # Only our children are stopped; no unrelated process is touched.
        for process, _, _ in self.children:
            process.stdin.close()
        results = []
        for process, stream, path in self.children:
            process.wait()
            stream.close()
            try:
                samples = [json.loads(line) for line in path.read_text().splitlines()]
            except ValueError:
                samples = []
            results.append({"pid": process.pid, "exit": process.returncode, "samples": samples})
        return results


def daily_coverage(payload, lines):
    days = list(range(1, DAILY_DAYS + 1))
    rows = payload.get("days", [])
    errors = []
    if [row.get("day") for row in rows] != days:
        errors.append("missing or unordered production days")
    for row in rows:
        domains = row.get("domain_hashes", {})
        if set(domains) != EXPECTED_DOMAINS:
            errors.append(f"day {row.get('day')}: incomplete production domains")
        for name, domain in domains.items():
            if not isinstance(domain, dict) or not domain.get("hash") or not domain.get("scope") or "state_day" not in domain:
                errors.append(f"day {row.get('day')}: incomplete {name} summary")
        values = row.get("values", [])
        if len(values) != 13 or values[0] != row.get("day") or values[2] <= 0 or values[3:6] != [0, 0, 0] or not values[-1] or not values[-2]:
            errors.append(f"day {row.get('day')}: incomplete raw population/market or nonconserving ledger")
    setup = records(lines, "LOAD_CONSISTENCY_SETUP=")
    if setup != [{"cadence": "production", "seed": 20260727, "days": DAILY_DAYS}]:
        errors.append("production cadence setup is missing or differs")
    bootstrap = records(lines, "GOLDEN_BOOTSTRAP=")
    diagnostics = records(lines, "GOLDEN_DIAGNOSTIC=")
    if len(bootstrap) != 1 or not bootstrap[0] or [row.get("day") for row in diagnostics] != days:
        errors.append("incomplete bootstrap or daily diagnostics")
    if [row.get("whole_economy_hash") for row in diagnostics] != [row.get("whole_economy_hash") for row in rows] or any(
            not isinstance(row.get("whole_economy_hash"), str) or not row["whole_economy_hash"].isdigit() for row in rows):
        errors.append("invalid whole economy diagnostic hashes")
    return errors


def command_coverage(payload, expected_days):
    errors = coverage_errors(payload, expected_days)
    commands = payload.get("commands", [])
    if [row.get("day") for row in commands] != list(range(1, COMMAND_DAYS + 1)) or any(
            row.get("operation") != "military_target" or row.get("value") != row.get("day", -1) + 1 for row in commands):
        errors.append("missing or different ordered command input")
    for row in payload.get("rows", []):
        day = row.get("day", -1)
        name = f"Replay day {day - 2}" if day >= 3 else "Committed View Replay"
        if (row.get("country_name") != name or not row.get("gm_receipt", {}).get("ok")
                or row.get("gm_receipt", {}).get("effective_day") != day + 2):
            errors.append(f"day {day}: rename did not land on its requested day")
        if not row.get("whole_economy_hash") or not row.get("military") or not row.get("resources"):
            errors.append(f"day {day}: incomplete whole economy/military/resource evidence")
    return errors


def compare(reference, actual, resume=False):
    if reference is None or actual is None:
        return {"path": "result", "error": "comparison requires both complete payloads"}
    if resume:
        reference = dict(reference, rows=[row for row in reference["rows"] if row["day"] > SAVE_DAY])
    return difference(reference, actual)


def run_case(godot, directory, name, count, mode=None, saves=None):
    run = directory / name
    run.mkdir()
    home = run / "home"
    home.mkdir()
    environment = {k: v for k, v in os.environ.items() if not k.startswith("PK_")}
    environment.update(HOME=str(home), PK_GOLDEN_DOMAINS="1", PK_GOLDEN_DIAGNOSTICS="1",
                       PK_SIM_DAY_TRACE=str(run / "day.trace"), PK_GOLDEN_COUNTRY_TRACE=str(run / "country.trace"),
                       PK_SAVE_DIR=str(saves or run / "saves"))
    daily = mode is None
    fixture = "runtime_load_daily_test" if daily else "committed_view_replay_test"
    if not daily:
        environment.update(PK_COMMITTED_REPLAY_MODE=mode, PK_COMMITTED_REPLAY_SCENARIO="mixed",
                           PK_COMMITTED_REPLAY_SAVE_DAY=str(SAVE_DAY), PK_COMMITTED_REPLAY_DAYS=str(COMMAND_DAYS),
                           PK_COMMITTED_REPLAY_PRODUCTION_CADENCE="1")
    command = [godot, "--headless", "--path", str(PROJECT), "--script", f"res://tests/runtime/{fixture}.gd",
               "--log-file", str(run / "engine.log")]
    write_json(run / "invocation.json", {"command": command, "environment": {k: v for k, v in environment.items()
               if k.startswith("PK_") or k == "HOME"}, "load_before": load_snapshot(), "workers": count})
    pressure = Pressure(run, count)
    print(f"START {name}: pressure_workers={count}", flush=True)
    try:
        pressure.start()
        start = time.monotonic()
        with (run / "stdout.log").open("w") as output:
            process = subprocess.run(command, cwd=ROOT, env=environment, stdout=output, stderr=subprocess.STDOUT)
        end = time.monotonic()
    finally:
        workers = pressure.stop()
        write_json(run / "pressure.json", workers)
    lines = (run / "stdout.log").read_text(errors="replace").splitlines()
    payload, errors = read_result(lines, "GOLDEN_RESULT=" if daily else "COMMITTED_REPLAY_RESULT=", process.returncode)
    workload_errors = pressure_errors(workers, start, end, count) if count else []
    try:
        if payload:
            errors += daily_coverage(payload, lines) if daily else command_coverage(
                payload, range(SAVE_DAY + 1 if mode == "resume" else 1, COMMAND_DAYS + 1))
        bootstrap = records(lines, "GOLDEN_BOOTSTRAP=")
    except (ValueError, TypeError, KeyError, AttributeError) as error:
        errors.append(f"invalid evidence: {error}")
        bootstrap = []
    result = {"name": name, "mode": mode, "exit": process.returncode, "seconds": end - start,
              "evidence_errors": errors, "pressure_errors": workload_errors, "actual": payload, "bootstrap": bootstrap,
              "load_after": load_snapshot(), "valid_observation": payload is not None and not errors and not workload_errors}
    if mode == "checkpoint":
        saved = (saves or run / "saves") / "manual_3.pksv"
        receipts = records(lines, "REPLAY_SAVE=")
        if len(receipts) != 1 or not receipts[0].get("ok") or not saved.exists() or not saved.stat().st_size:
            result["evidence_errors"].append("checkpoint did not produce a successful nonempty save")
            result["valid_observation"] = False
        else:
            result["save_sha256"] = sha256(saved)
    write_json(run / "result.json", result)
    print(f"DONE {name}: evidence_errors={len(errors)}, pressure_errors={len(workload_errors)}, seconds={end-start:.1f}", flush=True)
    return result


def run_save_goal(godot, directory, workers, report, publish):
    saves = directory / "checkpoint-saves"
    reference = report["goals"]["command_days"]["runs"][0]
    checkpoint = run_case(godot, directory, "save-checkpoint", 0, "checkpoint", saves)
    checkpoint["first_difference"] = compare(reference["actual"], checkpoint["actual"])
    runs = [checkpoint]
    report["goals"]["save_continuation"] = {"runs": runs}
    publish()
    if checkpoint.get("save_sha256"):
        for index in (1, 2):
            result = run_case(godot, directory, f"save-resume-load-{index}", workers, "resume", saves)
            result["first_difference"] = compare(reference["actual"], result["actual"], resume=True)
            result["checkpoint_continuation_difference"] = compare(checkpoint["actual"], result["actual"], resume=True)
            result["save_unchanged"] = sha256(saves / "manual_3.pksv") == checkpoint["save_sha256"]
            write_json(directory / f"save-resume-load-{index}" / "continuation-scan.json",
                       continuation_scan(reference["actual"], result["actual"]))
            runs.append(result)
            publish()
    report["goals"]["save_continuation"]["passed"] = reference["valid_observation"] and len(runs) == 3 and all(
        row["valid_observation"] and not row.get("first_difference") and not row.get("checkpoint_continuation_difference")
        and row.get("save_unchanged", True) for row in runs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default="godot")
    parser.add_argument("--log-dir", type=candidate_path, required=True)
    parser.add_argument("--workers", type=int, default=7)
    parser.add_argument("--goals", nargs="+", choices=["production_daily", "command_days", "save_continuation"],
                        default=["production_daily", "command_days", "save_continuation"])
    args = parser.parse_args()
    if args.workers < 1:
        parser.error("at least one pressure worker is required")
    if "save_continuation" in args.goals and "command_days" not in args.goals:
        parser.error("save_continuation requires command_days as its uninterrupted reference")
    args.log_dir.mkdir(parents=True, exist_ok=False)
    godot = shutil.which(args.godot)
    if not godot:
        parser.error("Godot executable not found")
    before = identity()
    before["godot"] = {"path": godot, "sha256": sha256(Path(godot)),
                       "version": subprocess.check_output([godot, "--version"], text=True).strip()}
    write_json(args.log_dir / "identity-before.json", before)
    report = {"scope": "targeted_same_binary_load_consistency", "reference_is_idle": False,
              "source_unchanged": None, "goals": {}, "passed": False}
    def publish():
        write_json(args.log_dir / "summary.json", report)
    for goal, mode in (("production_daily", None), ("command_days", "original")):
        if goal not in args.goals:
            continue
        runs = []
        report["goals"][goal] = {"runs": runs}
        reference = run_case(godot, args.log_dir, goal + "-reference", 0, mode)
        runs.append(reference)
        publish()
        for index in (1, 2):
            result = run_case(godot, args.log_dir, f"{goal}-load-{index}", args.workers, mode)
            result["first_difference"] = compare(reference["actual"], result["actual"])
            result["bootstrap_difference"] = difference(reference["bootstrap"], result["bootstrap"], "bootstrap")
            runs.append(result)
            publish()
        report["goals"][goal]["passed"] = all(row["valid_observation"] and not row.get("first_difference")
                                             and not row.get("bootstrap_difference") for row in runs)
        publish()
    # Save creation has its own observation; its complete continuation is compared too.
    if "save_continuation" in args.goals:
        run_save_goal(godot, args.log_dir, args.workers, report, publish)
    after = identity()
    write_json(args.log_dir / "identity-after.json", after)
    report["identity_difference"] = difference({k: v for k, v in before.items() if k != "godot"}, after)
    report["source_unchanged"] = report["identity_difference"] is None and sha256(Path(godot)) == before["godot"]["sha256"]
    report["passed"] = report["source_unchanged"] and all(goal["passed"] for goal in report["goals"].values())
    publish()
    for name, goal in report["goals"].items():
        print(f"{name}: passed={goal['passed']}", flush=True)
    print(f"Evidence: {args.log_dir / 'summary.json'}", flush=True)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(pressure_worker(int(sys.argv[2])) if sys.argv[1:2] == ["--pressure-worker"] else main())
