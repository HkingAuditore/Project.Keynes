#!/usr/bin/env python3
"""Compare 50× and 1× handoff in two imported copies of the player project."""

import argparse
from dataclasses import dataclass
from itertools import pairwise, product
import json
import os
from pathlib import Path
import subprocess

if __package__:
    from .analyze_player_handoff import read_rows, summarize
else:
    from analyze_player_handoff import read_rows, summarize


PROBE = "tests/game/player_scene_handoff_probe.gd"
PROBE_TIMINGS = "tests/game/player_scene_handoff_timings.gd"
PROBE_DISPLAY_CHECKS = "tests/game/player_scene_display_checks.gd"
SCENARIOS = {
    50: (180, ((25, 75), (85, 135), (146, 175))),
    1: (8, ((2, 8),)),
}
FRAME_LIMITS = {"30": 30, "60": 60, "adaptive": -1}


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
    frames = read_rows(trace)
    if not frames:
        raise ValueError(f"{prefix.name}: window visibility was not recorded")
    for frame in frames:
        drawable = frame.get("window_drawable")
        # Godot can emit a callback to process render resources while the window is hidden.
        if drawable is False:
            raise ValueError(f"{prefix.name}: window could not draw at game day {frame['committed']}")
        if drawable is not True:
            raise ValueError(f"{prefix.name}: window visibility was not recorded")
    return Recording(config, frames, {row["day"]: row for row in records})


def run_sample(godot, project, prefix, speed, target, fps_mode, overload, macos_app=None,
               *, map_reads=False):
    arguments = ["--path", str(project), "--windowed", "--resolution", "1600x960",
               "--log-file", f"{prefix}.engine.log",
               "--script", f"res://{PROBE}", "--", f"--speed={speed}", f"--through={target}",
               "--answer-story", "--require-rendered", "--command-log", f"--frames={prefix}.jsonl"]
    if fps_mode:
        arguments.append(f"--fps={fps_mode}")
    if overload:
        arguments.append("--overload")
    if map_reads:
        arguments.append("--panel-clicks")
    paths = {"PK_SAVE_DIR": f"{prefix}.saves",
                        "PK_RUNTIME_WATERFALL_CSV": f"{prefix}.waterfall.csv"}
    logfile = prefix.with_suffix(".log")
    launch_log = logfile
    load_before = os.getloadavg()
    if macos_app is not None:
        stderr = prefix.with_suffix(".stderr.log")
        launch_log = prefix.with_suffix(".launch.log")
        logfile.touch()
        stderr.touch()
        command = ["/usr/bin/open", "-W", "-n", "-a", str(macos_app),
                   "--stdout", str(logfile), "--stderr", str(stderr)]
        for name, path in paths.items():
            command += ["--env", f"{name}={path}"]
        command += ["--args", *arguments]
        with launch_log.open("w") as output:
            result = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT)
    else:
        command = [godot, *arguments]
        with logfile.open("w") as stdout:
            result = subprocess.run(command, env=os.environ | paths, stdout=stdout, stderr=subprocess.STDOUT)
    metadata = {"command": command, "exit_code": result.returncode,
                "load_before": load_before, "load_after": os.getloadavg()}
    prefix.with_suffix(".run.json").write_text(json.dumps(metadata, indent=2) + "\n")
    if result.returncode:
        raise ValueError(f"{prefix.name} exited with {result.returncode}, see {launch_log}")
    recording = load_recording(prefix, speed, target)
    if recording.config["fps_mode"] != fps_mode or recording.config["overload"] != overload:
        raise ValueError(f"{prefix.name} did not apply the requested frame and load settings")
    if recording.config["window_size"] != "(1600, 960)" or recording.config["viewport_size"] != "(1600.0, 960.0)":
        raise ValueError(f"{prefix.name} did not draw the requested 1600×960 viewport")
    if fps_mode and recording.config["graphics"]["frame_rate_limit"] != FRAME_LIMITS[fps_mode]:
        raise ValueError(f"{prefix.name} did not select the requested frame rate mode")
    return recording


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
    fps_mode = baseline.config.get("fps_mode")
    results = []
    for low, high in windows:
        days = [day for day in common_days if low <= day <= high]
        if len(days) < 2:
            raise ValueError(f"no shared frame boundaries in days {low} through {high}")
        comparison = {
            "requested_days": [low, high],
            "baseline": summarize(baseline.frames, baseline.daily, days[0], days[-1], require_rendered=True),
            "candidate": summarize(candidate.frames, candidate.daily, days[0], days[-1], require_rendered=True),
        }
        if fps_mode:
            running_cap = 60 if fps_mode == "adaptive" else FRAME_LIMITS[fps_mode]
            for side in ("baseline", "candidate"):
                if comparison[side].get("effective_max_fps") != [running_cap]:
                    raise ValueError(f"{side} used the wrong frame limit in days {days[0]} through {days[-1]}")
        results.append(comparison)
    return results


def check_display_pacing(frames):
    held_day = -1
    held = False
    merged = False
    for before, frame in pairwise(frames):
        if (frame["overload_us"] > 0 and frame["consumed"] > before["consumed"]
                and frame["presented"] == before["presented"]
                and frame["view_updates"] == 0 and frame["received_batches"] > 0
                and frame["cell_refresh_us"] == 0 and frame["staged_publish_us"] == 0):
            held = True
            if held_day < 0:
                held_day = frame["consumed"]
        if frame["view_updates"] > 0 and held_day >= 0 and frame["presented"] >= held_day:
            merged |= frame["presented"] > held_day
            held_day = -1
        # The load injection ends at day 55, ahead of the next story pause.
        if (merged and 55 <= frame["consumed"] <= 75 and frame["overload_us"] == 0
                and frame["presented"] == frame["consumed"]):
            return
    if not held:
        raise ValueError("no overloaded frame received days while holding back the map")
    if not merged:
        raise ValueError("the map never merged a held batch with a newer batch")
    raise ValueError("the map did not catch up in the recovery interval")


def check_held_map_reads(frames, *, baseline):
    held = [frame for before, frame in pairwise(frames)
            if frame["overload_us"] > 0 and frame["consumed"] > before["consumed"]
            and frame["presented"] == before["presented"] and frame["view_updates"] == 0
            and frame["received_batches"] > 0 and frame["cell_refresh_us"] == 0]
    if not held:
        raise ValueError("need a busy frame that received days and deferred its map update")
    copies = [copy for frame in held for copy in frame["map_copies"]]
    if baseline and not copies:
        raise ValueError("the baseline did not copy map columns while holding map updates")
    if not baseline and copies:
        raise ValueError("the candidate copied map columns while holding map updates")
    return {"frames": len(held), "reads": len(copies), "bytes": sum(row["bytes"] for row in copies)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--output", required=True, type=Path, help="new directory for recordings")
    parser.add_argument("--godot", default="godot")
    parser.add_argument("--macos-app", type=Path, help="launch this Godot app from a macOS desktop session")
    parser.add_argument("--fps", choices=FRAME_LIMITS, action="append", help="frame rate modes to compare")
    parser.add_argument("--overload", action="store_true", help="inject main-thread delay in the 50× case")
    parser.add_argument("--expect-pacing", action="store_true", help="verify hold, merge and recovery on the candidate")
    parser.add_argument("--map-reads", action="store_true",
                        help="measure map copies and panel feedback at 50× with an instrumented baseline")
    args = parser.parse_args()
    if (args.overload and not args.fps) or (args.expect_pacing and not args.overload):
        parser.error("--overload requires --fps and --expect-pacing requires --overload")
    projects = {"baseline": args.baseline.resolve(), "candidate": args.candidate.resolve()}
    try:
        if projects["baseline"] == projects["candidate"]:
            raise ValueError("pass two separate imported project directories")
        for path in (PROBE, PROBE_TIMINGS, PROBE_DISPLAY_CHECKS):
            if (projects["baseline"] / path).read_bytes() != (projects["candidate"] / path).read_bytes():
                raise ValueError(f"use the same {path} in both projects")
        output = args.output.resolve()
        output.mkdir()
        trials = []
        expected_by_speed = {}
        for fps_mode, (speed, (target, windows)) in product(args.fps or [""], SCENARIOS.items()):
            if (args.overload or args.map_reads) and speed != 50:
                continue
            if args.map_reads:
                windows = ((25, 75), (41, 55)) if args.overload else ((25, 75),)
            for trial in range(1, 4):
                order = tuple(projects) if trial % 2 else tuple(reversed(projects))
                samples = {}
                for name in order:
                    mode = f"-{fps_mode}fps" if fps_mode else ""
                    prefix = output / f"{name}-{speed}x{mode}-{trial}"
                    print(f"Recording {prefix.name}", flush=True)
                    sample = run_sample(args.godot, projects[name], prefix, speed, target, fps_mode,
                                        args.overload, args.macos_app, map_reads=args.map_reads)
                    daily = fingerprint(sample, target)
                    if daily != expected_by_speed.setdefault(speed, daily):
                        raise ValueError(f"{prefix.name} has different daily hashes or receipts")
                    samples[name] = sample
                baseline, candidate = samples["baseline"], samples["candidate"]
                if args.expect_pacing:
                    check_display_pacing(candidate.frames)
                result = {"trial": trial, "config": baseline.config,
                          "windows": compare_recordings(baseline, candidate, windows)}
                if args.map_reads:
                    for window in result["windows"]:
                        for side in projects:
                            if window[side].get("panel_feedback", {}).get("samples", 0) == 0:
                                raise ValueError(f"{side} missing panel feedback in {window['requested_days']}")
                    if args.overload:
                        result["held_map_reads"] = {
                            side: check_held_map_reads(samples[side].frames, baseline=side == "baseline")
                            for side in projects
                        }
                trials.append(result)
        if 1 in expected_by_speed and expected_by_speed[1] != expected_by_speed[50][:SCENARIOS[1][0]]:
            raise ValueError("1× and 50× daily hashes or receipts differ on the shared days")
        summary = output / "summary.json"
        summary.write_text(json.dumps(trials, indent=2) + "\n")
        print(summary)
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
