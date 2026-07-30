# Economy-side perf breakdown for perf_record_20260730_170332.csv (headless 180d @50x, 100x64).
import csv, json, sys
from collections import defaultdict

PATH = r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\perf_record_20260730_170332.csv"

rows = []
with open(PATH, "r", encoding="utf-8") as f:
    r = csv.DictReader(f)
    cols = r.fieldnames
    for row in r:
        rows.append(row)

print(f"rows={len(rows)} cols={len(cols)}")

def num(row, key, default=0.0):
    v = row.get(key, "")
    if v is None or v == "":
        return default
    try:
        return float(v)
    except ValueError:
        return default

# 1) discover economy-related columns
econ_cols = [c for c in cols if "economy" in c.lower() or "continuation" in c.lower()]
ms_cols = [c for c in econ_cols if c.endswith("_ms") or c.endswith("_ms_max")]

def seg_avg(seg, key):
    vals = [num(r, key) for r in seg]
    return sum(vals) / max(1, len(vals)), max(vals) if vals else 0.0

third = len(rows) // 3
segs = {"early(0-59)": rows[:third], "mid(60-119)": rows[third:2*third], "late(120-179)": rows[2*third:]}

KEY_COLS = [
    "fps", "fast_ms", "t_sus_ms", "t_render_ms", "t_ui_ms",
    "clock_pulse_ms", "clock_loop_ms", "clock_full_ms",
    "j_economy_daily_ms", "j_native_daily_sim_ms", "j_ocean_currents_ms",
    "j_country_daily_ms", "j_trigger_runtime_ms",
    "continuation_wall_ms", "continuation_max_slice_ms",
]
print("\n== overall frame/econ columns (avg | max) by segment ==")
print(f"{'col':34s} " + " ".join(f"{name:>20s}" for name in segs))
for c in KEY_COLS:
    if c not in cols:
        continue
    parts = []
    for name, seg in segs.items():
        a, m = seg_avg(seg, c)
        parts.append(f"{a:8.2f}|{m:8.2f}    ")
    print(f"{c:34s} " + " ".join(parts))

# 2) per-job columns
job_cols = [c for c in cols if c.startswith("j_") and c.endswith("_ms")]
job_avg = []
for c in job_cols:
    a, m = seg_avg(rows[2*third:], c)
    job_avg.append((a, m, c))
job_avg.sort(reverse=True)
print("\n== SUS jobs late-segment avg|max (top 15) ==")
for a, m, c in job_avg[:15]:
    print(f"  {c:36s} {a:8.2f} | {m:8.2f}")

# 3) economy report breakdown columns (bd_economy_*_ms style)
econ_ms = [c for c in cols if ("economy" in c.lower() and ("_ms" in c))]
econ_ms_avg = []
late = rows[2*third:]
for c in econ_ms:
    a, m = seg_avg(late, c)
    if a > 0.01:
        econ_ms_avg.append((a, m, c))
econ_ms_avg.sort(reverse=True)
print("\n== economy *_ms columns late-segment avg|max (>0.01ms) ==")
for a, m, c in econ_ms_avg[:40]:
    print(f"  {c:52s} {a:8.3f} | {m:8.2f}")

# 4) continuation stage wall (JSON per row) summed over late segment
stage_wall = defaultdict(float)
stage_cnt = defaultdict(int)
substage_wall = defaultdict(float)
for r in late:
    for col, tgt in (("continuation_stage_wall_ms", stage_wall),):
        raw = r.get(col, "")
        if not raw:
            continue
        try:
            d = json.loads(raw)
            for k, v in d.items():
                tgt[k] += float(v)
                stage_cnt[k] += 1
        except Exception:
            pass
    raw = r.get("continuation_substage_wall_ms", "")
    if raw:
        try:
            d = json.loads(raw)
            for k, v in d.items():
                substage_wall[k] += float(v)
        except Exception:
            pass
n = max(1, len(late))
print(f"\n== continuation stage wall avg/day over late segment ({n} rows) ==")
for k, v in sorted(stage_wall.items(), key=lambda kv: -kv[1])[:15]:
    print(f"  {k:44s} {v/n:8.3f} ms/day")
print(f"\n== continuation substage wall avg/day (top 20) ==")
for k, v in sorted(substage_wall.items(), key=lambda kv: -kv[1])[:20]:
    print(f"  {k:56s} {v/n:8.3f} ms/day")

# 5) scale counters late segment
for c in ["bd_economy_cohort_count", "bd_economy_market_count", "bd_economy_good_count",
          "bd_economy_building_group_count", "bd_economy_active_building_cell_count",
          "bd_economy_population", "tick_idx"]:
    if c in cols:
        v0 = rows[third].get(c, "?")
        v1 = rows[-1].get(c, "?")
        print(f"scale {c:44s} mid={v0} final={v1}")

# 6) barrier/continuation occupancy
barrier_rows = sum(1 for r in rows if num(r, "clock_pulse_ms") > 0.05)
print(f"\npulse-active rows: {barrier_rows}/{len(rows)}")
late_pulse = [num(r, "clock_pulse_ms") for r in late]
print(f"late pulse avg={sum(late_pulse)/len(late_pulse):.2f} max={max(late_pulse):.2f}")
