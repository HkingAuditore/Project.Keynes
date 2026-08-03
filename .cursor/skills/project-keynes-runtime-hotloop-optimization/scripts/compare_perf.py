"""Diff two perf_record_*.csv files.

Averaged ms columns plus per-day deltas of the cumulative bd_economy_scan_*
counters, which are deterministic for a fixed seed and therefore the only
reliable evidence of a hot-loop change.

Usage:
    python compare_perf.py BEFORE.csv AFTER.csv [--min-ms 0.05]
"""

import argparse
import csv
import statistics


def load(path):
    # Godot writes the CSV with a BOM.
    with open(path, newline="", encoding="utf-8-sig") as handle:
        return list(csv.DictReader(handle))


def to_float(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def mean_columns(rows, predicate):
    out = {}
    for key in rows[0]:
        if not predicate(key):
            continue
        values = [v for v in (to_float(r.get(key)) for r in rows) if v is not None]
        if values:
            out[key] = statistics.fmean(values)
    return out


def per_day_counters(rows):
    """Cumulative counters -> average increase per data row."""
    out = {}
    days = max(len(rows) - 1, 1)
    for key in rows[0]:
        if not (key.startswith("bd_economy_scan_") or key.endswith("_epoch")):
            continue
        first = to_float(rows[0].get(key))
        last = to_float(rows[-1].get(key))
        if first is None or last is None:
            continue
        out[key] = (last - first) / days
    return out


def emit(title, before, after, threshold, unit, top):
    keys = sorted(set(before) | set(after))
    lines = []
    for key in keys:
        b = before.get(key, 0.0)
        a = after.get(key, 0.0)
        if max(abs(b), abs(a)) < threshold:
            continue
        delta = a - b
        pct = (delta / b * 100.0) if b else float("inf")
        lines.append((abs(delta), key, b, a, delta, pct))
    if not lines:
        return
    lines.sort(reverse=True)
    hidden = max(len(lines) - top, 0)
    print(f"\n=== {title} ===")
    print(f"{'column':<52}{'before':>14}{'after':>14}{'delta':>14}{'%':>9}")
    for _, key, b, a, delta, pct in lines[:top]:
        pct_text = "  n/a" if pct == float("inf") else f"{pct:+8.1f}"
        print(f"{key:<52}{b:>14.3f}{a:>14.3f}{delta:>+14.3f}{pct_text}  {unit}")
    if hidden:
        print(f"... {hidden} more rows below the top-{top} cut (raise --top)")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("before")
    parser.add_argument("after")
    parser.add_argument("--min-ms", type=float, default=0.05)
    parser.add_argument("--top", type=int, default=40)
    args = parser.parse_args()

    before_rows = load(args.before)
    after_rows = load(args.after)
    print(f"before: {args.before}  ({len(before_rows)} rows)")
    print(f"after : {args.after}  ({len(after_rows)} rows)")

    is_ms = lambda k: k.endswith("_ms")
    emit(
        "timings (mean per row) -- treat +/-15% as noise",
        mean_columns(before_rows, is_ms),
        mean_columns(after_rows, is_ms),
        args.min_ms,
        "ms",
        args.top,
    )
    emit(
        "counters (per day) -- deterministic, this is the real evidence",
        per_day_counters(before_rows),
        per_day_counters(after_rows),
        1.0,
        "",
        args.top,
    )


if __name__ == "__main__":
    main()
