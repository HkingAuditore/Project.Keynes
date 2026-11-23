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


def summarize(frames, daily, first_day, last_day):
    if first_day >= last_day or any(day not in daily for day in range(first_day, last_day + 1)):
        raise ValueError(f"missing contiguous daily records for {first_day} through {last_day}")
    first = next((i for i, row in enumerate(frames) if row["committed"] >= first_day), len(frames))
    last = next((i for i, row in enumerate(frames) if row["committed"] >= last_day), len(frames))
    sample = frames[first:last + 1]
    if len(sample) < 2 or last == len(frames):
        raise ValueError(f"missing continuous frame samples for {first_day} through {last_day}")
    if any(row["reason"] in {"player", "pause", "fault"} for row in sample):
        raise ValueError(f"{first_day} through {last_day} includes a pause or fault")
    values = sorted(row["frame_usec"] for row in sample[1:])
    elapsed = daily[last_day]["produced_at_us"] - daily[first_day]["produced_at_us"]
    if elapsed <= 0:
        raise ValueError(f"invalid publish timestamps for {first_day} through {last_day}")

    def positive_median(key):
        points = [row[key] for row in sample[1:] if row[key] > 0]
        return median(points) if points else 0

    consume = [row["consume_us"] for before, row in pairwise(sample)
               if row["consumed"] > before["consumed"]]
    return {"first_day": first_day, "last_day": last_day,
            "days_per_s": round((last_day - first_day) * 1_000_000 / elapsed, 3),
            "frames": len(values), "frame_p95_ms": values[math.ceil(0.95 * len(values)) - 1] / 1000,
            "calendar_wait_total_ms": (sample[-1]["wait_us"] - sample[0]["wait_us"]) / 1000,
            "input_retry_total_ms": (sample[-1]["retry_us"] - sample[0]["retry_us"]) / 1000,
            "observed_waits": observed_waits(sample),
            "admit_median_ms": positive_median("admit_us") / 1000,
            "consume_median_ms": median(consume) / 1000 if consume else 0,
            "visual_apply_median_ms": round(positive_median("visual_ms"), 3),
            "ui_median_ms": positive_median("ui_us") / 1000}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--window", metavar=("FIRST_DAY", "LAST_DAY"), type=int, nargs=2,
                        required=True, action="append")
    parser.add_argument("recordings", nargs="+", type=Path)
    args = parser.parse_args()
    for path in args.recordings:
        try:
            frames = read_rows(path)
            records = read_rows(path.with_name(path.name + ".days"))
            daily = {row["day"]: row for row in records}
            results = [summarize(frames, daily, first, last) for first, last in args.window]
        except (OSError, ValueError, KeyError) as error:
            parser.error(f"{path}: {error}")
        print(json.dumps({"recording": path.name, "windows": results}))


if __name__ == "__main__":
    main()
