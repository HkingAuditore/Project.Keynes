#!/usr/bin/env python3
# 全年平均 SLP 纬向剖面：跨所有 tick 平均，让 landsea 季节项相互抵消。
# 若副高(45°N/S 高压)在年均中回归 -> 证明单tick(6月)是季节假象；
# 若年均仍单调 -> base_lat 副高项真未生效。
import csv, sys, math

CSV = "tile_data_record_20260608_184710.csv"
# 0-based indices
I_TICK = 1
I_SLP  = 55
I_LAT  = 62
I_TERR = 64

NB = 18  # 纬度带数
def band(ny):
    b = int(ny * NB)
    return min(max(b, 0), NB - 1)

# 陆地/水体判定：terrain 整数。沿用项目里 water 的判断——
# 先统计 terrain 取值分布，再用阈值。这里先把 0 当深海/水，其余暂存分类。
# 为稳妥：按 terrain 值聚合 SLP，输出时再人工判断哪些是水。
# 全年平均：每个纬度带累加 slp 与计数（全部 + 仅陆 + 仅水）。

all_sum = [0.0]*NB; all_n = [0]*NB
# 我们不预设 water 编码，先按 "season-averaged" 全体平均给纬度剖面，
# 同时单独累计每个 terrain code 的计数以便判断水陆。
terr_count = {}

# 同时也抓单个代表 tick（tick=66）做对照，验证与之前一致。
TICK_SNAP = 66
snap_sum = [0.0]*NB; snap_n = [0]*NB

rows = 0
with open(CSV, newline='', encoding='utf-8', errors='replace') as fh:
    rdr = csv.reader(fh)
    header = next(rdr)
    for row in rdr:
        rows += 1
        try:
            ny  = float(row[I_LAT])
            slp = float(row[I_SLP])
        except (ValueError, IndexError):
            continue
        if slp != slp:  # nan
            continue
        b = band(ny)
        all_sum[b] += slp; all_n[b] += 1
        try:
            tk = int(row[I_TICK])
            if tk == TICK_SNAP:
                snap_sum[b] += slp; snap_n[b] += 1
        except (ValueError, IndexError):
            pass

def lat_edges(b):
    lo = (b*(1.0/NB) - 0.5)*2.0
    hi = ((b+1)*(1.0/NB) - 0.5)*2.0
    return lo, hi

print(f"rows={rows}")
print()
print("=== ANNUAL-MEAN SLP by latitude band (all 983 ticks) ===")
print(f"{'lat_band':>16s} {'|lat|deg':>8s} {'annual_slp':>11s} {'tick66_slp':>11s}  note")
for b in range(NB):
    lo, hi = lat_edges(b)
    mid = (lo+hi)/2.0
    a = all_sum[b]/all_n[b] if all_n[b] else float('nan')
    s = snap_sum[b]/snap_n[b] if snap_n[b] else float('nan')
    note = ""
    deg = abs(mid)*90.0
    if 0.28 <= abs(mid) <= 0.55:
        note = "<- 副热带(应高压)"
    elif abs(mid) <= 0.12:
        note = "<- 赤道(应低压)"
    print(f"{lo:+.2f}~{hi:+.2f} {deg:8.1f} {a:11.4f} {s:11.4f}  {note}")
