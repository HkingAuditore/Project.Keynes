#!/usr/bin/env python3
"""Summarize a PK_ECONOMY_COST_CSV probe file.

Usage:
    python tools/perf/analyze_economy_cost.py <economy_cost.csv> [--min-ms M] [--top K]

Contract (gdext/src/economy_cost_probe.h): columns `day,phase,work,ms`.
  * default mode: one aggregated row per (day, phase); `work` is the summed
    units and `ms` the summed wall clock.
  * PK_ECONOMY_COST_CSV_FULL=1: one row per probe call.
Both are supported: rows are summed per (day, phase) before rates are printed.

`work` meaning: 1 per call for timing probes, catalog size/market-cell count for
some stages, exact hit/miss counters for `*.memo_*` rows. ms/day is a CPU-sum
for probes that run in parallel worker tasks (it can exceed wall time).
"""
import argparse
import collections
import csv
import statistics
import sys


def summarize(path, min_ms=1.0, top=30):
    per_phase = collections.defaultdict(lambda: {"ms": 0.0, "work": 0.0, "days": set()})
    per_day_phase = collections.defaultdict(lambda: {"ms": 0.0, "work": 0.0})
    all_days = set()
    with open(path, "r", encoding="utf-8", errors="replace", newline="") as handle:
        for row in csv.DictReader(handle):
            phase = (row.get("phase") or "").strip()
            if not phase:
                continue
            try:
                day = int(row.get("day", "-1"))
            except ValueError:
                continue
            try:
                ms = float(row.get("ms", "0") or 0.0)
            except ValueError:
                ms = 0.0
            try:
                work = float(row.get("work", "0") or 0.0)
            except ValueError:
                work = 0.0
            entry = per_phase[phase]
            entry["ms"] += ms
            entry["work"] += work
            entry["days"].add(day)
            bucket = per_day_phase[(day, phase)]
            bucket["ms"] += ms
            bucket["work"] += work
            all_days.add(day)

    if not all_days:
        print("no rows")
        return 1

    ndays = max(1, len(all_days))
    print(f"rows(days)={len(all_days)} phases={len(per_phase)}")
    print()
    header = f"{'phase':<48}{'ms/day':>10}{'work/day':>11}{'ms/work':>10}{'days':>6}"
    print(header)
    print("-" * len(header))
    ordered = sorted(per_phase.items(), key=lambda kv: -kv[1]["ms"])
    shown = 0
    for phase, entry in ordered:
        ms = entry["ms"]
        if ms < min_ms and shown >= top:
            continue
        if ms < min_ms:
            continue
        rows = len(entry["days"])
        rate = ms / ndays
        work_rate = entry["work"] / ndays
        per_work = (ms / entry["work"]) if entry["work"] > 0 else 0.0
        print(f"{phase:<48}{rate:10.2f}{work_rate:11.1f}{per_work * 1000:9.1f}us{rows:6}")
        shown += 1
        if shown >= top:
            break

    print()
    print("counter phases (ms == 0, work = count):")
    for phase, entry in ordered:
        if entry["ms"] > 1e-9:
            continue
        rate = entry["work"] / ndays
        if rate < 0.01:
            continue
        print(f"  {phase:<46}{rate:12.2f}/day")

    # Memo hit ratio pairs where both sides exist.
    print()
    print("memo hit ratios (work/day):")
    memo_pairs = 0
    for phase in ordered:
        name = phase[0]
        if name.endswith(".memo_hit"):
            base = name[: -len(".memo_hit")]
        elif name.endswith(".memo_miss"):
            base = name[: -len(".memo_miss")]
        else:
            continue
        hit = per_phase.get(base + ".memo_hit")
        miss = per_phase.get(base + ".memo_miss")
        if hit is None or miss is None:
            continue
        hits = hit["work"] / ndays
        misses = miss["work"] / ndays
        total = hits + misses
        ratio = (100.0 * hits / total) if total > 0 else 0.0
        print(f"  {base:<44} hit={hits:9.2f}/day miss={misses:9.2f}/day ratio={ratio:5.1f}%")
        memo_pairs += 1
    if memo_pairs == 0:
        print("  (none)")

    # Top single-day spikes per phase (helps separate cadence/cold-start days).
    print()
    print("top per-(day,phase) spikes:")
    spikes = sorted(per_day_phase.items(), key=lambda kv: -kv[1]["ms"])[:12]
    for (day, phase), bucket in spikes:
        if bucket["ms"] <= 0.0:
            continue
        print(f"  day {day:>7} {phase:<44}{bucket['ms']:10.2f} ms")


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cost_csv")
    parser.add_argument("--min-ms", type=float, default=1.0)
    parser.add_argument("--top", type=int, default=30)
    args = parser.parse_args(argv)
    return summarize(args.cost_csv, args.min_ms, args.top)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
