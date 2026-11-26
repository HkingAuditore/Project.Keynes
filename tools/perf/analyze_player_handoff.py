#!/usr/bin/env python3
"""Summarize continuous play from player_scene_handoff_probe.gd."""

import argparse
from itertools import pairwise
import json
import math
from pathlib import Path
from statistics import median


def read_rows(path):
    with path.open() as source:
        return [json.loads(line) for line in source]


def observed_waits(frames):
    """Measure waits on frame boundaries. A new admission can split two waits."""
    episodes = {"calendar_wait": [], "domain_wait": []}
    elapsed = 0
    for before, after in pairwise(frames):
        reason = before["reason"]
        if reason not in episodes:
            continue
        elapsed += after["usec"] - before["usec"]
        if after["reason"] != reason or after["admitted"] > before["admitted"]:
            episodes[reason].append(elapsed)
            elapsed = 0
    # A wait that continues beyond the last sampled frame has no observed end.
    return {reason: {"count": len(waits), "max_ms": round(max(waits, default=0) / 1000, 3)}
            for reason, waits in episodes.items()}


def frame_boundary(frames, day):
    previous = None
    for index, frame in enumerate(frames):
        observed = frame["committed"]
        if observed == day:
            return index
        if observed > day:
            if previous is None:
                raise ValueError(f"day {day} precedes the first frame at day {observed}")
            raise ValueError(f"day {day} was skipped between frame samples at days {previous} and {observed}")
        previous = observed
    raise ValueError(f"no frame reached committed day {day}")


def p95_ms(intervals):
    return sorted(intervals)[math.ceil(0.95 * len(intervals)) - 1] / 1000


def timing_stats(values):
    if not values:
        return {"samples": 0, "median_ms": None, "p95_ms": None, "range_ms": None}
    return {"samples": len(values), "median_ms": median(values) / 1000,
            "p95_ms": p95_ms(values), "range_ms": [min(values) / 1000, max(values) / 1000]}


def display_stats(sample, draw_intervals):
    measured = sample[1:]
    lag = []
    for row in measured:
        if len(row["draw_lag_days"]) != len(row["draw_times"]):
            raise ValueError("each completed draw must have a display age")
        lag.extend(row["draw_lag_days"])
    steps = ("receive_us", "climate_install_us", "vision_install_us", "cell_refresh_us", "cell_encode_us",
             "staged_publish_us", "immediate_texture_us")
    elapsed_us = sample[-1]["usec"] - sample[0]["usec"]
    updates = sum(row["view_updates"] for row in measured)
    return {
        "effective_max_fps": sorted({row["effective_max_fps"] for row in measured}),
        "overload_frames": sum(row["overload_us"] > 0 for row in measured),
        "received_batches": sum(row["received_batches"] for row in measured),
        "display_updates": updates,
        "display_updates_per_s": round(updates * 1_000_000 / elapsed_us, 3),
        "draw_timing": timing_stats(draw_intervals),
        "draw_display_lag_days": {"samples": len(lag), "median": median(lag),
                                  "range": [min(lag), max(lag)]} if lag else None,
        "step_timings": {key: timing_stats([row[key] for row in measured if row[key] > 0])
                         for key in steps},
    }


def map_read_stats(sample, *, recording_frames=None):
    copies = [copy for row in sample for copy in row["map_copies"]]
    # A held window can have zero copies. A timed copy elsewhere in the same
    # recording proves that the instrument was enabled for that run.
    recorded = copies if recording_frames is None else [
        copy for row in recording_frames for copy in row["map_copies"]]
    if not recorded or any(copy["ns"] < 0 or copy["bytes"] <= 0 for copy in recorded):
        raise ValueError("map copy timing requires an instrumented baseline and candidate")
    if any(len(row["map_draw_times"]) != len(row["map_draw_lag_days"]) for row in sample):
        raise ValueError("each actual map draw must have a corresponding published-day lag")
    draws = [usec for row in sample for usec in row["map_draw_times"]]
    lags = sorted(lag for row in sample for lag in row["map_draw_lag_days"])
    feedback = [click["usec"] for row in sample for click in row["panel_feedback"]]
    return {
        "map_reads": len(copies),
        "map_copied_bytes": sum(copy["bytes"] for copy in copies),
        "map_copy_total_ms": sum(copy["ns"] for copy in copies) / 1_000_000,
        "map_copy": timing_stats([copy["ns"] / 1000 for copy in copies]),
        "panel_feedback": timing_stats(feedback),
        "map_draw": timing_stats([after - before for before, after in pairwise(draws)]),
        "map_draw_lag": {"samples": len(lags), "median": median(lags),
                         "p95": lags[math.ceil(0.95 * len(lags)) - 1],
                         "range": [lags[0], lags[-1]]} if lags else None,
    }


def summarize(frames, daily, first_day, last_day, *, require_rendered=False):
    if first_day >= last_day or any(day not in daily for day in range(first_day, last_day + 1)):
        raise ValueError(f"missing contiguous daily records for {first_day} through {last_day}")
    # A frame can observe several commits at once. Daily records prove the
    # days ran, but cannot assign frame costs to either side of a skipped edge.
    first = frame_boundary(frames, first_day)
    last = frame_boundary(frames, last_day)
    sample = frames[first:last + 1]
    if len(sample) < 2:
        raise ValueError(f"missing continuous frame samples for {first_day} through {last_day}")
    if any(row["reason"] in {"player", "pause", "fault"} for row in sample):
        raise ValueError(f"{first_day} through {last_day} includes a pause or fault")
    values = [row["frame_usec"] for row in sample[1:]]
    draws = [timestamp for row in sample[1:] for timestamp in row.get("draw_times", [])]
    draw_intervals = [end - start for start, end in pairwise(draws)]
    if require_rendered and not draw_intervals:
        raise ValueError(f"{first_day} through {last_day} has fewer than two completed draws")
    elapsed = daily[last_day]["produced_at_us"] - daily[first_day]["produced_at_us"]
    if elapsed <= 0:
        raise ValueError(f"invalid publish timestamps for {first_day} through {last_day}")

    def positive_median(key):
        points = [row[key] for row in sample[1:] if row[key] > 0]
        return median(points) if points else 0

    consume = [row["consume_us"] for before, row in pairwise(sample)
               if row["consumed"] > before["consumed"]]
    result = {"first_day": first_day, "last_day": last_day,
            "days_per_s": round((last_day - first_day) * 1_000_000 / elapsed, 3),
            "frames": len(values), "frame_p95_ms": p95_ms(values),
            "draw_intervals": len(draw_intervals),
            "draw_p95_ms": p95_ms(draw_intervals) if draw_intervals else None,
            "calendar_wait_total_ms": (sample[-1]["wait_us"] - sample[0]["wait_us"]) / 1000,
            "input_retry_total_ms": (sample[-1]["retry_us"] - sample[0]["retry_us"]) / 1000,
            "observed_waits": observed_waits(sample),
            "admit_median_ms": positive_median("admit_us") / 1000,
            "consume_median_ms": median(consume) / 1000 if consume else 0,
            "visual_apply_median_ms": round(positive_median("visual_ms"), 3),
            "ui_median_ms": positive_median("ui_us") / 1000}
    if "view_updates" in sample[0]:
        result.update(display_stats(sample, draw_intervals))
    if require_rendered and any(row.get("panel_feedback") for row in sample[1:]):
        result.update(map_read_stats(sample[1:], recording_frames=frames))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--window", metavar=("FIRST_DAY", "LAST_DAY"), type=int, nargs=2,
                        required=True, action="append")
    parser.add_argument("--require-rendered", action="store_true",
                        help="refuse windows with no completed draw interval")
    parser.add_argument("recordings", nargs="+", type=Path)
    args = parser.parse_args()
    for path in args.recordings:
        try:
            frames = read_rows(path)
            if frames and frames[0].get("end") == "startup_failed":
                raise ValueError(f"startup failed: {frames[0]['failure']}")
            records = read_rows(path.with_name(path.name + ".days"))
            daily = {row["day"]: row for row in records}
            results = [summarize(frames, daily, first, last, require_rendered=args.require_rendered)
                       for first, last in args.window]
        except (OSError, ValueError, KeyError) as error:
            parser.error(f"{path}: {error}")
        print(json.dumps({"recording": path.name, "windows": results}))


if __name__ == "__main__":
    main()
