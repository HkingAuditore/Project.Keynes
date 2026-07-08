#!/usr/bin/env python3
"""Streaming aggregator for perf_record CSV.

Goal: baseline the pre-Item-2 (>cell-range slicing) per-slice spike profile so
we know which slice paths blow the per-slice budget and therefore what
cell-range slicing must fix.

Memory-safe: we never hold all rows. Per group we keep a reservoir sample
(Algorithm R) for percentile estimation; max/sum/count are exact.
"""
import csv, math, random, sys

SRC = r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\perf_record_20260707_202818.csv"
OUT = r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\perf_report_20260707.md"
R = 32768
random.seed(12345)

def fnum(s):
    if s is None: return None
    s = s.strip()
    if s == "" or s.lower() in ("nan", "none", "null"): return None
    try: return float(s)
    except ValueError: return None

class Group:
    __slots__ = ("count", "sum", "mx", "mn", "res", "cells_sum", "cur_sum")
    def __init__(self):
        self.count = 0; self.sum = 0.0; self.mx = -1e18; self.mn = 1e18
        self.res = []; self.cells_sum = 0.0; self.cur_sum = 0.0
    def add(self, v, idx, cells=None, cur=None):
        if v is None: return
        self.count += 1; self.sum += v
        if v > self.mx: self.mx = v
        if v < self.mn: self.mn = v
        n = self.count
        if len(self.res) < R: self.res.append(v)
        else:
            j = random.randint(0, n - 1)
            if j < R: self.res[j] = v
        if cells is not None: self.cells_sum += cells
        if cur is not None: self.cur_sum += cur
    def pct(self, q):
        if not self.res: return None
        s = sorted(self.res)
        L = len(s)
        i = min(L - 1, max(0, int(q * L)))
        return s[i]
    def mean(self): return (self.sum / self.count) if self.count else None

def stats_line(g):
    mean = g.mean()
    p50 = g.pct(0.50); p95 = g.pct(0.95); p99 = g.pct(0.99)
    cells = (g.cells_sum / g.count) if g.count and g.cells_sum else None
    cur = (g.cur_sum / g.count) if g.count and g.cur_sum else None
    return (f"count={g.count} mean={mean:.3f} p50={p50:.3f} p95={p95:.3f} "
            f"p99={p99:.3f} max={g.mx:.3f}" + (f" avg_cells={cells:.0f}" if cells is not None else "")
            + (f" avg_cursor_span={cur:.0f}" if cur is not None else ""))

# groups
by_path = {}      # largest_slice_path -> Group
by_stage = {}     # largest_slice_stage -> Group
ocean_path = {}   # j_ocean_currents_path -> Group
native_path = {}  # j_native_daily_sim_path -> Group
fps_g = Group(); sus_p95_g = Group(); sus_max_g = Group()
sim_budget_vals = []
over_budget = 0
total = 0
jobs_seen = {}
native_tick = 0

with open(SRC, newline='', encoding='utf-8', errors='replace') as f:
    r = csv.DictReader(f)
    for row in r:
        total += 1
        lms = fnum(row.get('largest_slice_ms'))
        path = row.get('largest_slice_path') or '(none)'
        stage = row.get('largest_slice_stage') or '(none)'
        cells = fnum(row.get('largest_slice_processed_cells'))
        c0 = fnum(row.get('largest_slice_cursor_start'))
        c1 = fnum(row.get('largest_slice_cursor_end'))
        cur_span = (c1 - c0) if (c0 is not None and c1 is not None) else None
        by_path.setdefault(path, Group()).add(lms, total, cells, cur_span)
        by_stage.setdefault(stage, Group()).add(lms, total, cells, cur_span)

        oms = fnum(row.get('j_ocean_currents_ms'))
        opath = row.get('j_ocean_currents_path') or '(none)'
        ocells = fnum(row.get('j_ocean_currents_processed_cells'))
        oc0 = fnum(row.get('j_ocean_currents_cursor_start'))
        oc1 = fnum(row.get('j_ocean_currents_cursor_end'))
        ocur = (oc1 - oc0) if (oc0 is not None and oc1 is not None) else None
        ocean_path.setdefault(opath, Group()).add(oms, total, ocells, ocur)

        nms = fnum(row.get('j_native_daily_sim_ms'))
        npath = row.get('j_native_daily_sim_path') or '(none)'
        native_path.setdefault(npath, Group()).add(nms, total)

        fps = fnum(row.get('fps')); fps_g.add(fps, total)
        sp95 = fnum(row.get('sus_sim_p95_300')); sus_p95_g.add(sp95, total)
        smax = fnum(row.get('sus_sim_max_300')); sus_max_g.add(smax, total)
        b = fnum(row.get('sim_slice_budget_ms'))
        if b is not None: sim_budget_vals.append(b)
        budget = b if b is not None else 1.0
        if lms is not None and lms > budget: over_budget += 1
        jn = row.get('largest_slice_job') or '(none)'
        jobs_seen[jn] = jobs_seen.get(jn, 0) + 1

# budget
bmean = (sum(sim_budget_vals) / len(sim_budget_vals)) if sim_budget_vals else None

# top 25 by max ms among slice paths
top = sorted(by_path.items(), key=lambda kv: kv[1].mx, reverse=True)[:25]

def fmt_group_table(d, title):
    lines = [f"\n### {title}\n", "| path/stage | count | mean(ms) | p50 | p95 | p99 | max | avg_cells | avg_cursor_span |",
             "|---|---|---|---|---|---|---|---|---|"]
    for k, g in sorted(d.items(), key=lambda kv: kv[1].mx, reverse=True):
        mean = g.mean(); p50 = g.pct(0.50); p95 = g.pct(0.95); p99 = g.pct(0.99)
        cells = (g.cells_sum / g.count) if g.count and g.cells_sum else None
        cur = (g.cur_sum / g.count) if g.count and g.cur_sum else None
        lines.append(f"| `{k}` | {g.count} | {mean:.3f} | {p50:.3f} | {p95:.3f} | {p99:.3f} | {g.mx:.3f} |"
                     + (f" {cells:.0f} |" if cells is not None else " - |")
                     + (f" {cur:.0f} |" if cur is not None else " - |"))
    return "\n".join(lines)

with open(OUT, 'w', encoding='utf-8') as out:
    out.write("# Perf baseline — pre-Item-2 cell-range slicing\n\n")
    out.write(f"Source: `perf_record_20260707_202818.csv`\n")
    out.write(f"Rows (ticks): {total}\n\n")
    out.write("## Frame-level\n")
    out.write(f"- fps: mean={fps_g.mean():.2f} p50={fps_g.pct(0.5):.2f} p5={fps_g.pct(0.05):.2f} min={fps_g.mn:.2f}\n")
    out.write(f"- sus_sim_p95_300 (ms): mean={sus_p95_g.mean():.3f} p95={sus_p95_g.pct(0.95):.3f} max={sus_p95_g.mx:.3f}\n")
    out.write(f"- sus_sim_max_300 (ms): mean={sus_max_g.mean():.3f} p95={sus_max_g.pct(0.95):.3f} max={sus_max_g.mx:.3f}\n")
    out.write(f"- sim_slice_budget_ms: mean={bmean:.3f}\n")
    out.write(f"- largest-slice over budget: {over_budget}/{total} = {100.0*over_budget/total:.1f}%\n\n")
    out.write("## Jobs observed as largest-slice source\n")
    for j, c in sorted(jobs_seen.items(), key=lambda kv: kv[1], reverse=True):
        out.write(f"- `{j}`: {c}\n")
    out.write(fmt_group_table(by_stage, "By largest_slice_stage"))
    out.write(fmt_group_table(by_path, "By largest_slice_path (all)"))
    out.write("\n### Top 25 slice paths by MAX ms\n")
    out.write("| # | path | count | mean | p95 | max | avg_cells | avg_cursor_span |\n")
    out.write("|---|---|---|---|---|---|---|---|\n")
    for i, (k, g) in enumerate(top, 1):
        mean = g.mean(); p95 = g.pct(0.95)
        cells = (g.cells_sum / g.count) if g.count and g.cells_sum else None
        cur = (g.cur_sum / g.count) if g.count and g.cur_sum else None
        out.write(f"| {i} | `{k}` | {g.count} | {mean:.3f} | {p95:.3f} | {g.mx:.3f} |"
                  + (f" {cells:.0f} |" if cells is not None else " - |")
                  + (f" {cur:.0f} |" if cur is not None else " - |") + "\n")
    out.write(fmt_group_table(ocean_path, "Ocean job by j_ocean_currents_path"))
    out.write(fmt_group_table(native_path, "Native daily sim by j_native_daily_sim_path"))

print(f"total rows={total}")
print(f"fps mean={fps_g.mean():.2f} p5={fps_g.pct(0.05):.2f}")
print(f"over_budget={over_budget} ({100.0*over_budget/total:.1f}%) budget_mean={bmean:.3f}")
print(f"top slice path by max: {top[0][0]} max={top[0][1].mx:.3f}")
print(f"ocean paths: {len(ocean_path)}  native paths: {len(native_path)}")
print(f"report -> {OUT}")
