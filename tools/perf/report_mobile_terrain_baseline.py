#!/usr/bin/env python3
"""Check and report the windowed draw and system-trace pairs for ticket #54."""

import argparse
import json
import math
from collections import defaultdict
from pathlib import Path


DRAW_PREFIX = "[mobile-terrain-draw] "
LAYERS = ("land", "water", "vegetation")
SCALES = (100, 75)
REQUIRED_SCENES = ("opening", "explored")
RUN_FIELDS = ("godot", "os", "driver", "adapter", "engine_max_fps", "vsync_mode",
              "display_refresh_hz", "window_px")
VIEW_FIELDS = ("day", "speed", "camera_center", "camera_zoom")
TRACE_TIMINGS = ("present_wait_ms", "gpu_work_ms", "present_interval_ms")


def read_captures(paths):
    captures = []
    for path in paths:
        with path.open(encoding="utf-8") as handle:
            for line in handle:
                if line.startswith(DRAW_PREFIX):
                    capture = json.loads(line[len(DRAW_PREFIX):])
                    if not isinstance(capture, dict):
                        raise ValueError(f"invalid windowed draw record in {path}")
                    captures.append(capture)
    if not captures:
        raise ValueError("no windowed draw captures in the supplied logs")
    return captures


def _number(value):
    return type(value) is int or (type(value) is float and math.isfinite(value))


def _interval(record):
    pid, start, end = (record.get(key) for key in ("process_id", "start_unix_s", "end_unix_s"))
    if type(pid) is not int or pid <= 0 or not all(map(_number, (start, end))) or not 0 < start < end:
        raise ValueError("expected a process_id and an ordered sampling interval")
    return pid, start, end


def _timing(record, key, count=None):
    summary = record.get(key)
    if not isinstance(summary, dict):
        raise ValueError(f"{key}: missing timing summary")
    samples = summary.get("samples")
    if type(samples) is not int or samples <= 0 or (count is not None and samples != count):
        raise ValueError(f"{key}: missing or incomplete samples")
    for name in ("mean", "median", "p95"):
        duration = summary.get(name)
        # A measured zero drawable wait is valid.
        if not _number(duration) or duration < 0 or (duration == 0 and key != "present_wait_ms"):
            raise ValueError(f"{key}: invalid {name} duration")
    if summary["p95"] < summary["median"]:
        raise ValueError(f"{key}: p95 is below the median")
    return summary


def _check_equal(first, second, fields):
    for key in fields:
        if key not in first or key not in second or first[key] != second[key]:
            raise ValueError(f"capture conditions differ or are missing: {key}")


def _check_capture(capture):
    if not all(capture.get(key) is True for key in ("ok", "sizes_ok", "fixed_view")):
        raise ValueError("expected a successful fixed-view capture with measured pixel sizes")
    scene, scale, layer = (capture.get(key) for key in ("scene", "scale_percent", "omitted_layer"))
    if scene not in (*REQUIRED_SCENES, "fog-off") or scale not in SCALES or layer not in ("", *LAYERS):
        raise ValueError("unexpected scene, terrain scale or omitted layer")
    window = capture.get("window_px")
    if not isinstance(window, list) or len(window) != 2 or not all(type(n) is int and n > 0 for n in window):
        raise ValueError("invalid window_px")
    expected_sizes = {
        "land_water_px": [n * scale // 100 for n in window],
        "vegetation_px": window,
        "fog_px": None if scene == "fog-off" else [n // 2 for n in window],
    }
    for key, value in expected_sizes.items():
        if key not in capture or capture[key] != value:
            raise ValueError(f"invalid {key} for window_px and terrain scale")
    count = _timing(capture, "frame_interval_ms")["samples"]
    _timing(capture, "window_draw_cpu_ms", count)
    if scale != 100:
        _timing(capture, "terrain_draw_cpu_ms", count)


def _pairs(scene, scale, runs):
    runs.sort(key=lambda run: run["capture"]["start_unix_s"])
    for previous, current in zip(runs, runs[1:]):
        if previous["capture"]["end_unix_s"] > current["capture"]["start_unix_s"]:
            raise ValueError(f"{scene} at {scale}%: capture intervals overlap")
    complete = [run for run in runs if not run["capture"]["omitted_layer"]]
    omissions = [run for run in runs if run["capture"]["omitted_layer"]]
    if not complete:
        raise ValueError(f"{scene} at {scale}%: missing full capture")
    measured_layers = {run["capture"]["omitted_layer"] for run in omissions}
    missing = [layer for layer in LAYERS if layer not in measured_layers]
    if missing:
        raise ValueError(f"{scene} at {scale}%: missing paired captures for {', '.join(missing)}")

    for omitted in omissions:
        omitted_start = omitted["capture"]["start_unix_s"]
        full = min(complete, key=lambda run: abs(run["capture"]["start_unix_s"] - omitted_start))
        layer = omitted["capture"]["omitted_layer"]
        viewport = "window" if scale == 100 or layer == "vegetation" else "terrain"
        cpu_key = f"{viewport}_draw_cpu_ms"
        yield {
            "scene": scene, "scale_percent": scale, "layer": layer, "draw_cpu_viewport": viewport,
            "full": full, "omitted": omitted,
            "full_minus_omitted_mean_ms": {
                "draw_cpu": full["capture"][cpu_key]["mean"] - omitted["capture"][cpu_key]["mean"],
                "gpu_work": full["trace"]["gpu_work_ms"]["mean"] - omitted["trace"]["gpu_work_ms"]["mean"],
                "present_wait": full["trace"]["present_wait_ms"]["mean"]
                - omitted["trace"]["present_wait_ms"]["mean"],
            },
        }


def build_report(captures, traces):
    if not captures:
        raise ValueError("no windowed draw captures")
    by_interval = {}
    for trace in traces:
        interval = _interval(trace)
        if interval in by_interval:
            raise ValueError(f"duplicate system trace interval: {interval}")
        by_interval[interval] = trace

    views = {}
    groups = defaultdict(list)
    for capture in captures:
        _check_capture(capture)
        _check_equal(captures[0], capture, RUN_FIELDS)
        scene = capture["scene"]
        _check_equal(views.setdefault(scene, capture), capture, VIEW_FIELDS)
        interval = _interval(capture)
        trace = by_interval.pop(interval, None)
        if trace is None:
            raise ValueError(f"no matching system trace for process {interval[0]} at {interval[1]}")
        if not isinstance(trace.get("source"), str) or not trace["source"].strip():
            raise ValueError(f"missing system trace source for process {interval[0]}")
        for key in TRACE_TIMINGS:
            _timing(trace, key)
        groups[scene, capture["scale_percent"]].append({"capture": capture, "trace": trace})

    if by_interval:
        raise ValueError("system trace summaries include intervals without draw captures")
    scenes = (*REQUIRED_SCENES, "fog-off") if "fog-off" in views else REQUIRED_SCENES
    return [pair for scene in scenes for scale in SCALES for pair in _pairs(scene, scale, groups[scene, scale])]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--trace-summaries", type=Path, required=True, help="JSON array of system-trace summaries")
    parser.add_argument("godot_logs", type=Path, nargs="+")
    args = parser.parse_args()
    try:
        captures = read_captures(args.godot_logs)
        traces = json.loads(args.trace_summaries.read_text(encoding="utf-8"))
        if not isinstance(traces, list) or not all(isinstance(row, dict) for row in traces):
            raise ValueError("system-trace summaries must be a JSON array of objects")
        report = json.dumps(build_report(captures, traces), indent=2, allow_nan=False)
    except (OSError, ValueError) as error:
        parser.exit(1, f"Mobile terrain baseline is incomplete: {error}\n")
    print(report)


if __name__ == "__main__":
    main()
