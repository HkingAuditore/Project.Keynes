#!/usr/bin/env python3
"""Strict continuation scenarios. Default includes bounded and military continuation cases; --full adds save dates."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]


def require_fixed_replay_cadence() -> None:
    entry = ROOT / "Project/project-keynes/tests/runtime/committed_view_replay_test.gd"
    if 'replay_cadence.gd").install' not in entry.read_text():
        raise SystemExit("replay matrix entry point must install fixed cadence")

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True)
    parser.add_argument("--log-dir", type=Path, required=True)
    parser.add_argument("--full", action="store_true")
    parser.add_argument("--multicountry", action="store_true", help="two AI countries, checkpoint day5")
    parser.add_argument("--military", action="store_true", help="nonzero army and war, checkpoint day20")
    parser.add_argument("--military-annual", action="store_true", help="nonzero army/war, real annual autosave")
    parser.add_argument("--annual", action="store_true", help="real 365-day year, annual autosave at 365")
    parser.add_argument("--annual-neighbors", action="store_true", help="manual checkpoints 364 and 366 in a 365-day year")
    args = parser.parse_args()
    require_fixed_replay_cadence()
    args.log_dir.mkdir(parents=True, exist_ok=False)
    cases = [("save1", "standard", 1), ("calendar5", "calendar", 5),
             ("multicountry5", "multicountry", 5), ("military20", "military", 20)]
    # military365 is opt-in (--military-annual): whether the day-365 Effect->
    # Country command reaches Country before the annual save checks for an
    # idle Effect depends on wall-clock timing (docs/architecture/migration.md,
    # known issues), so it is not a reliable default gate.
    if args.full:
        cases += [("save2", "standard", 2), ("save5", "standard", 5),
                  ("save9", "standard", 9), ("mixed5", "mixed", 5)]
    if args.annual:
        cases = [("annual365", "calendar", 365)]
    if args.annual_neighbors:
        cases = [("annual364", "calendar", 364), ("annual366", "calendar", 366)]
    if args.multicountry:
        cases = [("multicountry5", "multicountry", 5)]
    if args.military:
        cases = [("military20", "military", 20)]
    if args.military_annual:
        cases = [("military365", "military", 365)]
    results = []
    for name, scenario, day in cases:
        command = [sys.executable, str(ROOT / "tools/ci/check_committed_replay.py"),
                   "--godot", args.godot, "--checkpoint", "--trace", "--scenario", scenario,
                   "--save-day", str(day), "--days", str(day + 8),
                   "--log-dir", str(args.log_dir / name)]
        if args.annual or args.annual_neighbors or name == "military365":
            command += ["--year-days", "365"]
        if (args.annual and not args.annual_neighbors) or name == "military365":
            command += ["--autosave"]
        start = time.monotonic()
        result = subprocess.run(command, check=False)
        results.append(dict(name=name, scenario=scenario, save_day=day, observed_days=8,
                            exit=result.returncode, seconds=time.monotonic() - start))
        (args.log_dir / "matrix.json").write_text(json.dumps(results, indent=2) + "\n")
        if result.returncode: return result.returncode
    return 0
if __name__ == "__main__": raise SystemExit(main())
