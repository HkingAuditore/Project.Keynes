# -*- coding: utf-8 -*-
"""分析 230205 新数据（物理化后）：温带冬季极寒 + 海冰范围/空洞。"""
import csv, sys
from collections import defaultdict
sys.stdout.reconfigure(encoding="utf-8")
csv.field_size_limit(10**7)

PATH = r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260616_230205.csv"

want = ["tick_idx", "phys_daily_wind_season_phase", "cell_lat_norm_arr",
        "temp_arr", "temp_30d_arr", "temp_365d_arr", "temp_baseline_year_arr",
        "temp_season_offset_arr", "insolation_dev_arr", "insolation_now_arr",
        "sea_ice_frac_arr", "is_water_arr", "terrain_arr", "cover_arr",
        "elevation_arr", "cell_index", "temperature_transport_anomaly_arr",
        "air_mass_temp_anomaly_arr", "snow_cover_arr"]

rows_by_tick = defaultdict(list)
with open(PATH, "r", encoding="utf-8-sig", newline="") as f:
    rd = csv.reader(f)
    header = next(rd)
    idx = {name: header.index(name) for name in want}
    for r in rd:
        try:
            tick = int(r[idx["tick_idx"]])
        except (ValueError, IndexError):
            continue
        rec = {}
        ok = True
        for name in want:
            try:
                rec[name] = float(r[idx[name]])
            except (ValueError, IndexError):
                ok = False
                break
        if ok:
            rows_by_tick[tick].append(rec)

last_tick = max(rows_by_tick)
rows = rows_by_tick[last_tick]
phase = rows[0]["phys_daily_wind_season_phase"]
print(f"tick={last_tick}  season_phase={phase:.3f}  cells={len(rows)}  (ticks={sorted(rows_by_tick)[-4:]})")
print("ny: 0=北极(冬), 0.5=赤道, 1=南极(夏)\n")

# 纬度带
def band(ny):
    d = abs(ny - 0.5)
    if d < 0.10: return "0 热带"
    if d < 0.20: return "1 副热带"
    if d < 0.32: return "2 温带"
    if d < 0.42: return "3 副极地"
    return "4 极地"

def tband(t):
    if t < 0.06: return "极寒"
    if t < 0.20: return "严寒"
    if t < 0.30: return "寒冷"
    if t < 0.40: return "凉爽"
    if t < 0.55: return "温暖"
    if t < 0.75: return "炎热"
    return "酷热"

# 北/南半球分开（北=冬, 南=夏）
print("=== 陆地温度分布（按半球+纬度带）===")
for hemi, lo, hi in [("北(冬)", 0.0, 0.5), ("南(夏)", 0.5, 1.0)]:
    buckets = defaultdict(list)
    for rec in rows:
        if rec["is_water_arr"] != 0: continue
        ny = rec["cell_lat_norm_arr"]
        if not (lo <= ny < hi): continue
        buckets[band(ny)].append(rec)
    for b in sorted(buckets):
        ts = [r["temp_arr"] for r in buckets[b]]
        if not ts: continue
        n = len(ts)
        frigid = sum(1 for t in ts if t < 0.06)
        severe = sum(1 for t in ts if t < 0.20)
        avg = sum(ts) / n
        tmin, tmax = min(ts), max(ts)
        print(f"  {hemi} {b:8s} n={n:5d}  temp avg={avg:.3f} [{tmin:.3f},{tmax:.3f}]  "
              f"极寒(<0.06)={frigid:4d}({100*frigid/n:4.1f}%)  严寒(<0.20)={severe:4d}({100*severe/n:4.1f}%)")

print("\n=== 南半球(冬季)温带低海拔平原 ny∈[0.70,0.82] elev<0.5：温度构成拆解 ===")
samp = [r for r in rows if r["is_water_arr"] == 0 and 0.70 <= r["cell_lat_norm_arr"] < 0.82
        and r["elevation_arr"] < 0.5]
samp.sort(key=lambda r: r["temp_arr"])
print(f"  共 {len(samp)} 格（低海拔平原）；avg temp={sum(r['temp_arr'] for r in samp)/max(1,len(samp)):.3f}")
print(f"  极寒(<0.06)={sum(1 for r in samp if r['temp_arr']<0.06)}  样本（含最冷与中位）：")
show = samp[:5] + samp[len(samp)//2:len(samp)//2+3]
def altpen(e):
    lin = e * 0.40
    t = max(0.0, min(1.0, (e - 0.45) / 0.55))
    return lin + t*t*(3-2*t)*0.22
for r in show:
    ap = altpen(r["elevation_arr"])
    rt = max(0.0, min(1.0, r["temp_baseline_year_arr"] - ap + r["temp_season_offset_arr"]))
    print(f"    ny={r['cell_lat_norm_arr']:.3f} temp={r['temp_arr']:.3f} t30={r['temp_30d_arr']:.3f} "
          f"base={r['temp_baseline_year_arr']:.3f} altpen={ap:.3f} season_off={r['temp_season_offset_arr']:.3f} "
          f"→ target≈{rt:.3f} | transport={r['temperature_transport_anomaly_arr']:+.3f} "
          f"airmass={r['air_mass_temp_anomaly_arr']:+.3f} snow={r['snow_cover_arr']:.2f}")

print("\n=== 对照：南半球(冬季)副热带低海拔 ny∈[0.60,0.70] elev<0.5 ===")
samp2 = [r for r in rows if r["is_water_arr"] == 0 and 0.60 <= r["cell_lat_norm_arr"] < 0.70
         and r["elevation_arr"] < 0.5]
samp2.sort(key=lambda r: r["temp_arr"])
print(f"  共 {len(samp2)} 格；avg temp={sum(r['temp_arr'] for r in samp2)/max(1,len(samp2)):.3f}")
for r in samp2[:5]:
    rt = max(0.0, min(1.0, r["temp_baseline_year_arr"] + r["temp_season_offset_arr"]))
    print(f"    ny={r['cell_lat_norm_arr']:.3f} temp={r['temp_arr']:.3f} t365={r['temp_365d_arr']:.3f} "
          f"base_year={r['temp_baseline_year_arr']:.3f} season_off={r['temp_season_offset_arr']:.3f} "
          f"dev={r['insolation_dev_arr']:.3f} elev={r['elevation_arr']:.3f} → 预测target≈{rt:.3f}")

print("\n=== 海冰范围（水域 sea_ice_frac>0.5 的最赤道侧纬度）===")
ice_water = [r for r in rows if r["is_water_arr"] != 0 and r["sea_ice_frac_arr"] > 0.5]
if ice_water:
    for hemi, lo, hi in [("北", 0.0, 0.5), ("南", 0.5, 1.0)]:
        h = [r for r in ice_water if lo <= r["cell_lat_norm_arr"] < hi]
        if h:
            if hemi == "北":
                edge = max(r["cell_lat_norm_arr"] for r in h)   # 最大 ny = 最赤道侧
                lat_deg = (0.5 - edge) * 180
            else:
                edge = min(r["cell_lat_norm_arr"] for r in h)
                lat_deg = (edge - 0.5) * 180
            print(f"  {hemi}半球海冰边缘 ny={edge:.3f} (≈纬度 {lat_deg:.0f}°)  冰格数={len(h)}")

print("\n=== 极地冰盖空洞（北极 ny<0.12 水域：有冰 vs 空洞）===")
polar_water = [r for r in rows if r["is_water_arr"] != 0 and r["cell_lat_norm_arr"] < 0.12]
if polar_water:
    iced = [r for r in polar_water if r["sea_ice_frac_arr"] > 0.5]
    holes = [r for r in polar_water if r["sea_ice_frac_arr"] < 0.2]
    print(f"  北极水域 n={len(polar_water)}  有冰(>0.5)={len(iced)}  空洞(<0.2)={len(holes)}")
    if holes:
        print("  空洞样本（开阔水：temp/insol，看是否被太阳门控阻止结冰 form_thr=0.14, freeze_gate@insol>0.55）:")
        for r in sorted(holes, key=lambda r: r["cell_lat_norm_arr"])[:6]:
            print(f"    ny={r['cell_lat_norm_arr']:.3f} temp={r['temp_arr']:.3f} insol_now={r['insolation_now_arr']:.3f} "
                  f"sea_ice={r['sea_ice_frac_arr']:.3f}")
    if iced:
        print("  有冰样本:")
        for r in sorted(iced, key=lambda r: r["cell_lat_norm_arr"])[:4]:
            print(f"    ny={r['cell_lat_norm_arr']:.3f} temp={r['temp_arr']:.3f} insol_now={r['insolation_now_arr']:.3f} "
                  f"sea_ice={r['sea_ice_frac_arr']:.3f}")
