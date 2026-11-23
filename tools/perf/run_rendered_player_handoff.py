#!/usr/bin/env python3
"""Compare 50× and 1× handoff in two imported copies of the player project."""

import argparse
from dataclasses import dataclass
import json
import os
from pathlib import Path
import subprocess

if __package__:
    from .analyze_player_handoff import read_rows, summarize
else:
    from analyze_player_handoff import read_rows, summarize


PROBE = "tests/game/player_scene_handoff_probe.gd"
SCENARIOS = {
    50: (180, ((25, 75), (85, 135), (146, 175))),
    1: (8, ((2, 8),)),
}


@dataclass
class Recording:
    config: dict
    frames: list
    daily: dict


def marker(lines, name):
    prefix = name + "="
    values = [json.loads(line[len(prefix):]) for line in lines if line.startswith(prefix)]
    if len(values) != 1:
        raise ValueError(f"expected one {name} record, found {len(values)}")
    return values[0]


def load_recording(prefix, speed, target):
    lines = prefix.with_suffix(".log").read_text().splitlines()
    config = marker(lines, "HANDOFF_CONFIG")
    if config["display"] in ("", "headless") or config["driver"] in ("", "dummy"):
        raise ValueError(f"{prefix.name} used no window renderer")
    if config["speed"] != speed:
        raise ValueError(f"{prefix.name} ran at {config['speed']}× instead of {speed}×")
    result = marker(lines, "HANDOFF_RESULT")
    if result["end"] != "target" or not result["contiguous"] or not result["written"]:
        raise ValueError(f"{prefix.name} did not finish the requested play interval")
    trace = prefix.with_suffix(".jsonl")
    records = read_rows(trace.with_suffix(".jsonl.days"))
    days = [row["day"] for row in records]
    if result["consumed_day"] < target or days != list(range(1, result["consumed_day"] + 1)):
        raise ValueError(f"{prefix.name} has incomplete daily records")
    return Recording(config, read_rows(trace), {row["day"]: row for row in records})


def run_sample(godot, project, prefix, speed, target):
    command = [godot, "--path", str(project), "--log-file", f"{prefix}.engine.log",
               "--script", f"res://{PROBE}", "--", f"--speed={speed}", f"--through={target}",
               "--answer-story", "--require-rendered", f"--frames={prefix}.jsonl"]
    env = os.environ | {"PK_SAVE_DIR": f"{prefix}.saves",
                        "PK_RUNTIME_WATERFALL_CSV": f"{prefix}.waterfall.csv"}
    load_before = os.getloadavg()
    with prefix.with_suffix(".log").open("w") as stdout:
        result = subprocess.run(command, env=env, stdout=stdout, stderr=subprocess.STDOUT)
    metadata = {"command": command, "exit_code": result.returncode,
                "load_before": load_before, "load_after": os.getloadavg()}
    prefix.with_suffix(".run.json").write_text(json.dumps(metadata, indent=2) + "\n")
    if result.returncode:
        raise ValueError(f"{prefix.name} exited with {result.returncode}, see {prefix}.log")
    return load_recording(prefix, speed, target)


def fingerprint(recording, target):
    return [(recording.daily[day]["business_hash"], recording.daily[day]["receipts"])
            for day in range(1, target + 1)]


def compare_recordings(baseline, candidate, windows):
    if baseline.config != candidate.config:
        settings = baseline.config.keys() | candidate.config.keys()
        changed = sorted(key for key in settings if baseline.config.get(key) != candidate.config.get(key))
        raise ValueError(f"actual player settings differ: {', '.join(changed)}")
    common_days = sorted({frame["committed"] for frame in baseline.frames}
                         & {frame["committed"] for frame in candidate.frames})
    results = []
    for low, high in windows:
        days = [day for day in common_days if low <= day <= high]
        if len(days) < 2:
            raise ValueError(f"no shared frame boundaries in days {low} through {high}")
        results.append({
            "requested_days": [low, high],
            "baseline": summarize(baseline.frames, baseline.daily, days[0], days[-1], require_rendered=True),
            "candidate": summarize(candidate.frames, candidate.daily, days[0], days[-1], require_rendered=True),
        })
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--output", required=True, type=Path, help="new directory for recordings")
    parser.add_argument("--godot", default="godot")
    args = parser.parse_args()
    projects = {"baseline": args.baseline.resolve(), "candidate": args.candidate.resolve()}
    try:
        if projects["baseline"] == projects["candidate"]:
            raise ValueError("pass two separate imported project directories")
        if (projects["baseline"] / PROBE).read_bytes() != (projects["candidate"] / PROBE).read_bytes():
            raise ValueError("use the same player handoff probe in both projects")
        output = args.output.resolve()
        output.mkdir()
        trials = []
        for speed, (target, windows) in SCENARIOS.items():
            expected = None
            for trial in range(1, 4):
                order = tuple(projects) if trial % 2 else tuple(reversed(projects))
                samples = {}
                for name in order:
                    prefix = output / f"{name}-{speed}x-{trial}"
                    print(f"Recording {prefix.name}", flush=True)
                    sample = run_sample(args.godot, projects[name], prefix, speed, target)
                    daily = fingerprint(sample, target)
                    if expected is None:
                        expected = daily
                    elif daily != expected:
                        raise ValueError(f"{prefix.name} has different daily hashes or receipts")
                    samples[name] = sample
                baseline, candidate = samples["baseline"], samples["candidate"]
                trials.append({"trial": trial, "config": baseline.config,
                               "windows": compare_recordings(baseline, candidate, windows)})
        summary = output / "summary.json"
        summary.write_text(json.dumps(trials, indent=2) + "\n")
        print(summary)
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
