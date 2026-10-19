#!/usr/bin/env python3
"""Summarize a PK_RUNTIME_WATERFALL_CSV (one row per worker day attempt).

Usage:
    python tools/perf/analyze_waterfall.py <waterfall.csv> [--min-day N] [--top K]

Contract (gdext/src/runtime_day_waterfall.h): the first columns are
`day,attempt,committed,mask`, then one column per contiguous segment, then
`total,residual`. Segments are contiguous so `residual` is ~0 by construction.
Numbers are wall-clock ms per day attempt on the simulation worker.
"""
import argparse
import csv
import statistics
import sys


def summarize(path, min_day=None, top=10):
    rows = []
    with open(path, "r", encoding="utf-8", errors="replace", newline="") as handle:
        reader = csv.DictReader(handle)
        for raw in reader:
            try:
                day = int(raw["day"])
            except (KeyError, ValueError):
                continue
            if min_day is not None and day < min_day:
                continue
            rows.append(raw)
    if not rows:
        print("no rows (or all filtered)")
        return 1

    columns = list(rows[0].keys())
    fixed = {"day", "attempt", "committed", "mask", "total", "residual"}
    segments = [c for c in columns if c not in fixed]
    committed = [r for r in rows if r.get("committed", "0") == "1"]
    failed = [r for r in rows if r.get("committed", "0") != "1"]

    def num(row, key):
        try:
            return float(row[key])
        except (KeyError, ValueError):
            return 0.0

    def ms_stats(values):
        if not values:
            return "n=0"
        vals = sorted(values)
        p90 = vals[min(len(vals) - 1, int(len(vals) * 0.9))]
        return (
            f"n={len(vals)} median={statistics.median(vals):.2f} "
            f"p90={p90:.2f} max={vals[-1]:.2f}"
        )

    days = sorted({int(r["day"]) for r in committed})
    print(f"rows={len(rows)} committed={len(committed)} failed={len(failed)} days={len(days)}")
    print(f"attempts/day={(len(rows) / max(1, len(days))):.2f}")
    if committed:
        print("committed-day total:", ms_stats([num(r, "total") for r in committed]))
    if failed:
        print("failed-attempt total:", ms_stats([num(r, "total") for r in failed]))

    denominator = max(1, len(committed))
    segment_ms = {seg: sum(num(r, seg) for r in committed) for seg in segments}
    total_ms = sum(num(r, "total") for r in committed)
    residual = sum(num(r, "residual") for r in committed)
    print()
    print(f"{'segment':<28}{'ms/day':>10}{'share':>9}{'total_ms':>12}")
    for seg, value in sorted(segment_ms.items(), key=lambda kv: -kv[1]):
        if value <= 0.0:
            continue
        share = 100.0 * value / total_ms if total_ms > 0 else 0.0
        print(f"{seg:<28}{value / denominator:10.2f}{share:8.1f}%{value:12.1f}")
    print(f"{'TOTAL':<28}{total_ms / denominator:10.2f}{100.0:8.1f}%{total_ms:12.1f}")
    print(f"{'RESIDUAL':<28}{residual / denominator:10.2f}{'':>8}{residual:12.1f}")

    if failed:
        print()
        print("failed-attempt segments (ms total):")
        fail_ms = {seg: sum(num(r, seg) for r in failed) for seg in segments}
        for seg, value in sorted(fail_ms.items(), key=lambda kv: -kv[1])[: top]:
            if value <= 0.0:
                continue
            print(f"  {seg:<26}{value:10.2f}")
        masks = {}
        for row in failed:
            key = int(row.get("mask", "0"))
            masks[key] = masks.get(key, 0) + 1
        missing = {mask: [bit for bit in range(12) if not (mask >> bit) & 1] for mask in masks}
        print(f"  failed masks: {masks} missing_domain_bits={missing}")

    print()
    print("slowest committed days:")
    ranked = sorted(committed, key=lambda r: -num(r, "total"))[:top]
    for row in ranked:
        top_segments = sorted(
            ((seg, num(row, seg)) for seg in segments), key=lambda kv: -kv[1]
        )[:4]
        detail = ", ".join(f"{seg}={value:.2f}" for seg, value in top_segments)
        print(f"  day {row['day']:>7} attempt={row.get('attempt', '?')} "
              f"total={num(row, 'total'):8.2f} | {detail}")
    return 0


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("waterfall")
    parser.add_argument("--min-day", type=int, default=None)
    parser.add_argument("--top", type=int, default=10)
    args = parser.parse_args(argv)
    return summarize(args.waterfall, args.min_day, args.top)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
