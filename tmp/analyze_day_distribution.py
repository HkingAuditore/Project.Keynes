# -*- coding: utf-8 -*-
"""Per-day (all attempts summed) wall distribution for PK economy replay waterfall CSVs."""
import csv
import json
import statistics
from collections import defaultdict


def pct(values, q):
    ordered = sorted(values)
    if not ordered:
        return 0.0
    pos = (len(ordered) - 1) * q
    low = int(pos)
    high = min(low + 1, len(ordered) - 1)
    frac = pos - low
    return ordered[low] * (1.0 - frac) + ordered[high] * frac


def load(path):
    per_day = defaultdict(lambda: {"total": 0.0, "formulas": 0.0, "attempts": 0})
    with open(path, encoding="utf-8", newline="") as handle:
        for row in csv.DictReader(handle):
            day = int(row["day"])
            bucket = per_day[day]
            bucket["total"] += float(row["total"])
            bucket["formulas"] += float(row.get("econ.formulas") or 0.0)
            bucket["attempts"] += 1
    return per_day


def summarize(label, path):
    per_day = load(path)
    totals = [v["total"] for v in per_day.values()]
    formulas = [v["formulas"] for v in per_day.values()]
    attempts = [v["attempts"] for v in per_day.values()]
    stats = {
        "label": label,
        "n": len(totals),
        "mean": statistics.fmean(totals),
        "p50": pct(totals, 0.50),
        "p90": pct(totals, 0.90),
        "p95": pct(totals, 0.95),
        "p99": pct(totals, 0.99),
        "max": max(totals),
        "min": min(totals),
        "stdev": statistics.pstdev(totals),
        "formulas_mean": statistics.fmean(formulas),
        "formulas_p95": pct(formulas, 0.95),
        "formulas_max": max(formulas),
        "attempts_mean": statistics.fmean(attempts),
        "attempts_max": max(attempts),
    }
    print(
        "== {label}: n={n} total mean={mean:.2f} p50={p50:.2f} p90={p90:.2f} "
        "p95={p95:.2f} p99={p99:.2f} max={max:.2f} min={min:.2f} "
        "sd={stdev:.2f}".format(**stats)
    )
    print(
        "   formulas mean={formulas_mean:.2f} p95={formulas_p95:.2f} "
        "max={formulas_max:.2f} | attempts/day mean={attempts_mean:.2f} "
        "max={attempts_max}".format(**stats)
    )
    buckets20 = defaultdict(list)
    buckets4 = defaultdict(list)
    buckets5 = defaultdict(list)
    for day, value in per_day.items():
        buckets20[day % 20].append(value["total"])
        buckets4[day % 4].append(value["total"])
        buckets5[day % 5].append(value["total"])
    if buckets20.get(0):
        others = [x for k, vals in buckets20.items() if k for x in vals]
        stats["mod20_0_mean"] = statistics.fmean(buckets20[0])
        stats["mod20_other_mean"] = statistics.fmean(others)
        print(
            "   mod20=0 mean={:.2f} others={:.2f}".format(
                stats["mod20_0_mean"], stats["mod20_other_mean"]
            )
        )
    stats["mod4"] = {k: round(statistics.fmean(v), 2) for k, v in sorted(buckets4.items())}
    stats["mod5"] = {k: round(statistics.fmean(v), 2) for k, v in sorted(buckets5.items())}
    print("   mod4:", stats["mod4"])
    print("   mod5:", stats["mod5"])
    top = sorted(per_day.items(), key=lambda kv: -kv[1]["total"])[:6]
    stats["heaviest"] = [
        {"day": day, "total": round(v["total"], 1), "attempts": v["attempts"]}
        for day, v in top
    ]
    print("   heaviest:", stats["heaviest"])
    return stats


def main():
    paths = {
        "base": r"tmp\perf_runs\r29_dist_base\waterfall.csv",
        "trackb": r"tmp\perf_runs\r29_dist_tb\waterfall.csv",
        "exact": r"tmp\perf_runs\r29_dist_exact\waterfall.csv",
    }
    stats = {label: summarize(label, path) for label, path in paths.items()}
    print("\n== ratios vs base (per-day sum across attempts) ==")
    base = stats["base"]
    for label in ("trackb", "exact"):
        cur = stats[label]
        print(
            "{}: mean {:.3f}x p50 {:.3f}x p90 {:.3f}x p95 {:.3f}x max {:.3f}x".format(
                label,
                cur["mean"] / base["mean"],
                cur["p50"] / base["p50"],
                cur["p90"] / base["p90"],
                cur["p95"] / base["p95"],
                cur["max"] / base["max"],
            )
        )
    with open("tmp/perf_runs/day_distribution_summary.json", "w", encoding="utf-8") as handle:
        json.dump(stats, handle, ensure_ascii=False, indent=2)


if __name__ == "__main__":
    main()
