#!/usr/bin/env python3
"""Streaming aggregator for Project.Keynes per-tick perf CSV.

Extracts the columns we care about, accumulates per-(stage,path) spike
statistics (max/mean/count/p95), job-level ms/slices/fallback, fps stats,
and the global largest-slice distribution. Writes a markdown report.
"""
import csv
import sys
from collections import defaultdict

PATH = sys.argv[1] if len(sys.argv) > 1 else r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\perf_record_20260708_150133.csv"
OUT  = sys.argv[2] if len(sys.argv) > 2 else r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\perf_report_20260708.md"

def f(x):
    try:
        return float(x)
    except Exception:
        return None

def i(x):
    try:
        return int(x)
    except Exception:
        return None

# per-(stage,path) accumulation
stage_max   = defaultdict(float)
stage_sum   = defaultdict(float)
stage_cnt   = defaultdict(int)
stage_vals  = defaultdict(list)   # for p95
stage_keys  = []                  # preserve first-seen order

# job-level
job_ms   = defaultdict(list)
job_slc  = defaultdict(list)
job_fb   = defaultdict(int)       # fallback count
job_skip = defaultdict(int)

fps_vals = []
sim_avg, sim_p95, sim_max = [], [], []
slice_budget_vals = []
over1_ticks = 0
total_ticks = 0

# global largest-slice distribution
largest_vals = []

# fallback reason counters (parse last segment of path)
fb_reasons = defaultdict(int)

with open(PATH, newline='', encoding='utf-8', errors='replace') as fh:
    r = csv.DictReader(fh)
    for row in r:
        total_ticks += 1
        # fps
        v = f(row.get('fps'))
        if v is not None:
            fps_vals.append(v)
        # sim 300
        for key, acc in (('sus_sim_avg_300', sim_avg), ('sus_sim_p95_300', sim_p95), ('sus_sim_max_300', sim_max)):
            x = f(row.get(key))
            if x is not None:
                acc.append(x)
        # slice budget
        sb = f(row.get('sim_slice_budget_ms'))
        if sb is not None:
            slice_budget_vals.append(sb)
        # largest slice
        st = row.get('largest_slice_stage') or ''
        pa = row.get('largest_slice_path') or ''
        ms = f(row.get('largest_slice_ms'))
        if st or pa:
            key = (st, pa)
            if key not in stage_keys:
                stage_keys.append(key)
            if ms is not None:
                if ms > stage_max[key]:
                    stage_max[key] = ms
                stage_sum[key] += ms
                stage_cnt[key] += 1
                stage_vals[key].append(ms)
                largest_vals.append(ms)
                if ms > 1.0:
                    over1_ticks += 1
        # job-level
        for j in ('j_ocean_currents', 'j_native_daily_sim', 'j_season_refresh',
                  'j_natural_resource_daily', 'j_enum_atlas_upload',
                  'j_dynamic_visual_atlas_upload'):
            m = f(row.get(j + '_ms'))
            if m is not None:
                job_ms[j].append(m)
            s = i(row.get(j + '_slices'))
            if s is not None:
                job_slc[j].append(s)
            fb = i(row.get(j + '_fallback'))
            if fb is not None and fb > 0:
                job_fb[j] += 1
            sk = i(row.get(j + '_skip'))
            if sk is not None and sk > 0:
                job_skip[j] += 1
        # bd climate / weather fallback reasons
        for b in ('bd_climate_fallback_reason', 'bd_weather_fallback_reason', 'bd_dynamic_visual_atlas_fallback'):
            rv = row.get(b)
            if rv and rv.strip() and rv.strip() != 'none':
                fb_reasons[rv.strip()] += 1

def pct(vals, p):
    if not vals:
        return None
    s = sorted(vals)
    k = max(0, min(len(s) - 1, int(round((p / 100.0) * (len(s) - 1)))))
    return s[k]

def mean(vals):
    return sum(vals) / len(vals) if vals else None

# ---- build report ----
L = []
L.append(f"# Perf Report — {OUT.split('/')[-1].replace('perf_report_','').replace('.md','')}\n")
L.append(f"- ticks = {total_ticks}")
L.append(f"- columns = 462 (fixed-width payload CSV)")
L.append("")

# fps
if fps_vals:
    L.append("## FPS")
    L.append(f"- mean = {mean(fps_vals):.2f} | median = {pct(fps_vals,50):.2f} | p5 = {pct(fps_vals,5):.2f} | min = {min(fps_vals):.2f} | max = {max(fps_vals):.2f}")
    L.append("")

# sim
L.append("## Simulation cost (rolling 300-tick, ms)")
if sim_avg:
    L.append(f"- avg  = {mean(sim_avg):.3f}")
    L.append(f"- p95  = {pct(sim_p95,95):.3f}")
    L.append(f"- max  = {max(sim_max):.3f}")
if slice_budget_vals:
    L.append(f"- sim_slice_budget_ms mean = {mean(slice_budget_vals):.3f} | min = {min(slice_budget_vals):.3f}")
L.append(f"- ticks with largest_slice_ms > 1.0ms: **{over1_ticks} / {total_ticks}** ({100.0*over1_ticks/total_ticks:.1f}%)")
L.append("")

# job-level
L.append("## Job-level (ms / slices / fallback ticks)")
for j in ('j_ocean_currents', 'j_native_daily_sim', 'j_season_refresh',
          'j_natural_resource_daily', 'j_enum_atlas_upload',
          'j_dynamic_visual_atlas_upload'):
    if job_ms[j]:
        m = job_ms[j]
        sl = job_slc[j]
        L.append(f"- **{j}**: ms mean={mean(m):.3f} p95={pct(m,95):.3f} max={max(m):.3f}"
                 + (f" | slices mean={mean(sl):.1f} max={max(sl)}" if sl else "")
                 + (f" | fallback ticks={job_fb[j]}" if job_fb[j] else "")
                 + (f" | skip ticks={job_skip[j]}" if job_skip[j] else ""))
L.append("")

# per-stage spikes, sorted by max desc
L.append("## Largest-slice spikes by stage / path")
L.append("| rank | stage | path | count | max(ms) | mean(ms) | p95(ms) |")
L.append("|---|---|---|---|---|---|---|")
ranked = sorted(stage_keys, key=lambda k: stage_max[k], reverse=True)
for rank, k in enumerate(ranked[:30], 1):
    c = stage_cnt[k]
    mx = stage_max[k]
    av = stage_sum[k] / c if c else 0
    p95 = pct(stage_vals[k], 95) or 0
    L.append(f"| {rank} | {k[0]} | {k[1]} | {c} | {mx:.2f} | {av:.2f} | {p95:.2f} |")
L.append("")

# top paths by max regardless of stage
L.append("## Top-25 largest_slice_path by max(ms)")
L.append("| rank | path | stage | count | max(ms) | mean(ms) |")
L.append("|---|---|---|---|---|---|")
by_path = defaultdict(lambda: {'mx':0.0,'sum':0.0,'cnt':0,'st':''})
for k in stage_keys:
    d = by_path[k[1]]
    d['mx'] = max(d['mx'], stage_max[k])
    d['sum'] += stage_sum[k]
    d['cnt'] += stage_cnt[k]
    d['st'] = k[0]
ranked_p = sorted(by_path.items(), key=lambda kv: kv[1]['mx'], reverse=True)
for rank, (pa, d) in enumerate(ranked_p[:25], 1):
    L.append(f"| {rank} | {pa} | {d['st']} | {d['cnt']} | {d['mx']:.2f} | {d['sum']/d['cnt']:.2f} |")
L.append("")

# fallback reasons
if fb_reasons:
    L.append("## Fallback reasons (bd climate/weather/atlas)")
    for rv, c in sorted(fb_reasons.items(), key=lambda kv: -kv[1]):
        L.append(f"- {rv}: {c}")
    L.append("")

txt = "\n".join(L)
with open(OUT, 'w', encoding='utf-8') as out:
    out.write(txt)
print("WROTE", OUT)
print("ticks", total_ticks, "over1", over1_ticks)
print("top stage:", ranked[0] if ranked else None, "max", stage_max[ranked[0]] if ranked else None)
