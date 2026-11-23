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
CAPTURE_FRAMES = 240  # mobile_terrain_draw_capture.gd
RUN_FIELDS = ("godot", "os", "driver", "adapter", "engine_max_fps", "vsync_mode",
              "display_refresh_hz", "window_px")
VIEW_FIELDS = ("day", "speed", "camera_center", "camera_zoom")
WAIT_EVENTS = "observed_drawable_wait_event_ms"
PRESENTATION_DELTAS = "observed_presentation_delta_ms"


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
    minimum = 0 if key == WAIT_EVENTS else 1
    if type(samples) is not int or samples < minimum or (count is not None and samples != count):
        expected = f"expected {count}" if count is not None else "invalid sample count"
        raise ValueError(f"{key}: {expected}, observed {samples}")
    for name in ("mean", "median", "p95"):
        duration = summary.get(name)
        if samples == 0 and duration is None:
            continue
        if samples == 0 or not _number(duration) or duration < 0 or (duration == 0 and key != WAIT_EVENTS):
            raise ValueError(f"{key}: invalid {name} duration")
    if samples and summary["p95"] < summary["median"]:
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
    if (scene not in (*REQUIRED_SCENES, "fog-off") or type(scale) is not int
            or scale not in SCALES or layer not in ("", *LAYERS)):
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
    _timing(capture, "frame_interval_ms", CAPTURE_FRAMES)
    _timing(capture, "window_draw_cpu_ms", CAPTURE_FRAMES)
    if scale != 100:
        _timing(capture, "terrain_draw_cpu_ms", CAPTURE_FRAMES)


def _check_trace(capture, trace):
    _check_equal(capture, trace, ("scene", "scale_percent", "omitted_layer"))
    source = trace.get("source")
    if not isinstance(source, str) or not source.strip():
        raise ValueError("missing system trace source")
    if "trace" in capture and capture["trace"] != source:
        raise ValueError(f"wrong system trace source: expected {capture['trace']}, got {source}")
    frames = capture["frame_interval_ms"]["samples"]
    if type(trace.get("capture_frames")) is not int or trace["capture_frames"] != frames:
        raise ValueError(f"{source}: capture_frames differs from the draw capture")

    # Requests and post-draw callbacks mark different points in a frame. Allow
    # one boundary frame, then require GPU activity for every unique request.
    requests = trace.get("present_requests")
    if type(requests) is not int or abs(requests - frames) > 1:
        raise ValueError(f"{source}: {requests} present requests for {frames} draw samples")
    unmapped = trace.get("unmapped_request_buffers")
    if type(unmapped) is not int or unmapped != 0:
        raise ValueError(f"{source}: unmapped Metal present requests: {unmapped}")
    unique_frames = trace.get("requested_frame_ids")
    if type(unique_frames) is not int or unique_frames != requests:
        raise ValueError(f"{source}: missing or duplicate requested frame IDs ({unique_frames}/{requests})")
    _timing(trace, "gpu_work_ms", requests)
    if trace.get("frames_missing_gpu_activity") != []:
        raise ValueError(f"{source}: missing GPU activity for requested frames")

    # Presented-handler deltas form their own stream. A request near the edge
    # can complete outside the window, and a delta needs a prior presentation.
    observed = _timing(trace, PRESENTATION_DELTAS)["samples"]
    if not frames - 2 <= observed <= frames + 1:
        raise ValueError(f"{source}: {PRESENTATION_DELTAS}: {observed} deltas for {frames} draw samples")
    # A drawable may never wait, or have multiple wait events. Keep the event
    # distribution and its count without converting it to a per-frame cost.
    _timing(trace, WAIT_EVENTS)


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
    seen_captures = set()
    groups = defaultdict(list)
    for capture in captures:
        _check_capture(capture)
        _check_equal(captures[0], capture, RUN_FIELDS)
        scene = capture["scene"]
        _check_equal(views.setdefault(scene, capture), capture, VIEW_FIELDS)
        interval = _interval(capture)
        if interval in seen_captures:
            raise ValueError(f"duplicate windowed draw interval: {interval}")
        seen_captures.add(interval)
        trace = by_interval.pop(interval, None)
        if trace is None:
            raise ValueError(f"no matching system trace for process {interval[0]} at {interval[1]}")
        _check_trace(capture, trace)
        groups[scene, capture["scale_percent"]].append({"capture": capture, "trace": trace})

    if by_interval:
        raise ValueError("system trace summaries include intervals without draw captures")
    windows = sorted(seen_captures)
    for (pid, _, end), (next_pid, start, _) in zip(windows, windows[1:]):
        if pid == next_pid and end > start:
            raise ValueError(f"capture intervals overlap for process {pid}")
    scenes = (*REQUIRED_SCENES, "fog-off") if "fog-off" in views else REQUIRED_SCENES
    return [pair for scene in scenes for scale in SCALES for pair in _pairs(scene, scale, groups[scene, scale])]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    inputs = parser.add_mutually_exclusive_group(required=True)
    inputs.add_argument("--trace-summaries", type=Path, help="JSON array of system-trace summaries")
    inputs.add_argument("--evidence", type=Path, help="Portable JSON containing captures and trace_summaries")
    parser.add_argument("godot_logs", type=Path, nargs="*")
    args = parser.parse_args()
    if bool(args.godot_logs) != bool(args.trace_summaries):
        parser.error("provide Godot logs with --trace-summaries, or use --evidence by itself")
    try:
        if args.evidence:
            evidence = json.loads(args.evidence.read_text(encoding="utf-8"))
            if not isinstance(evidence, dict):
                raise ValueError("evidence must be a JSON object")
            captures = evidence.get("captures")
            traces = evidence.get("trace_summaries")
        else:
            captures = read_captures(args.godot_logs)
            traces = json.loads(args.trace_summaries.read_text(encoding="utf-8"))
        for name, records in (("windowed draw captures", captures), ("system-trace summaries", traces)):
            if not isinstance(records, list) or not all(isinstance(row, dict) for row in records):
                raise ValueError(f"{name} must be a JSON array of objects")
        report = json.dumps(build_report(captures, traces), indent=2, allow_nan=False)
    except (OSError, ValueError) as error:
        parser.exit(1, f"Mobile terrain baseline is incomplete: {error}\n")
    print(report)


if __name__ == "__main__":
    main()
