"""Summarize a perf_record CSV for the performance-refactor plan.

Prints the core timing distribution, which scheduling path actually ran, and the
top per-day millisecond columns so a stage can be judged against a baseline.
"""
import csv
import statistics
import sys


def num(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def stats(values):
    values = [v for v in values if v is not None]
    if not values:
        return None
    values_sorted = sorted(values)
    n = len(values_sorted)
    return {
        "mean": statistics.fmean(values_sorted),
        "p50": values_sorted[n // 2],
        "p95": values_sorted[min(n - 1, int(n * 0.95))],
        "max": values_sorted[-1],
        "sum": sum(values_sorted),
    }


def main(path):
    with open(path, newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    print(f"rows={len(rows)} file={path}")

    core = ["t_sus_ms", "fast_ms", "t_ui_ms", "t_render_ms", "frame_wall_ms",
            "clock_loop_ms", "clock_pulse_ms", "largest_slice_ms",
            "continuation_max_slice_ms", "render_residual_ms"]
    print("\n-- core timings (ms) --")
    for key in core:
        if key not in rows[0]:
            continue
        s = stats([num(r.get(key)) for r in rows])
        if s:
            print(f"{key:28s} mean={s['mean']:8.3f} p50={s['p50']:8.3f} "
                  f"p95={s['p95']:8.3f} max={s['max']:8.3f}")

    print("\n-- scheduling path --")
    for key in ["runtime_graph_pulse_count", "runtime_graph_abi_calls",
                "runtime_graph_gdscript_callbacks", "runtime_graph_work_done",
                "runtime_graph_budget_yields", "continuation_slices",
                "continuation_frames"]:
        if key not in rows[0]:
            continue
        s = stats([num(r.get(key)) for r in rows])
        if s:
            print(f"{key:34s} total={s['sum']:12.0f} mean={s['mean']:9.3f} max={s['max']:9.0f}")
    for key in ["runtime_graph_last_status", "largest_slice_job",
                "largest_slice_stage", "bio_slice_fallback_reason"]:
        if key not in rows[0]:
            continue
        seen = {}
        for r in rows:
            seen[r.get(key, "")] = seen.get(r.get(key, ""), 0) + 1
        top = sorted(seen.items(), key=lambda kv: -kv[1])[:5]
        print(f"{key:34s} {top}")

    print("\n-- top per-day ms columns --")
    scored = []
    for key in rows[0]:
        if not key.endswith("_ms"):
            continue
        s = stats([num(r.get(key)) for r in rows])
        if s and s["mean"] > 0.01:
            scored.append((s["mean"], key, s))
    for mean, key, s in sorted(scored, reverse=True)[:22]:
        print(f"{key:44s} mean={mean:8.3f} p95={s['p95']:8.3f} max={s['max']:8.3f}")

    print("\n-- growth: first vs last quintile of t_sus_ms --")
    q = max(1, len(rows) // 5)
    head = stats([num(r.get("t_sus_ms")) for r in rows[:q]])
    tail = stats([num(r.get("t_sus_ms")) for r in rows[-q:]])
    if head and tail:
        print(f"first {q} days mean={head['mean']:.3f}  last {q} days mean={tail['mean']:.3f}  "
              f"ratio={tail['mean'] / max(head['mean'], 1e-9):.2f}x")


if __name__ == "__main__":
    main(sys.argv[1])
