# -*- coding: utf-8 -*-
"""临时审计:tile_data_record_20260801_033937.csv 植被分布 vs 气候场 (Whittaker 视角)"""
import pandas as pd
import numpy as np

CSV = r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260801_033937.csv"

VEG_NAMES = {
    0:"NONE",1:"POLAR_DESERT",2:"TUNDRA",3:"ALPINE_TUNDRA",4:"ALPINE_MEADOW",
    5:"TAIGA",6:"BOREAL_SHRUB",7:"TEMPERATE_DECIDUOUS",8:"TEMPERATE_CONIFER",
    9:"TEMPERATE_GRASSLAND",10:"TEMPERATE_STEPPE",11:"MEDITERRANEAN_SHRUB",
    12:"SUBTROPICAL_FOREST",13:"SAVANNA",14:"TROPICAL_RAINFOREST",15:"TROPICAL_DRY_FOREST",
    16:"DESERT_SCRUB",17:"XERIC_DESERT",18:"OASIS_VEG",19:"MANGROVE",20:"SWAMP",
    21:"MARSH",22:"KELP_FOREST",23:"CORAL_REEF",24:"CLOUD_FOREST",25:"MONSOON_FOREST",
    26:"SEAGRASS",27:"PEAT_BOG",
}

df = pd.read_csv(CSV)
print("rows:", len(df), "unique ticks:", sorted(df.tick_idx.unique()))
print("unique cells:", df.cell_index.nunique())

# 若同一 cell 多 tick,取最后一 tick 快照
snap = df.sort_values("tick_idx").groupby("cell_index", as_index=False).tail(1).copy()
print("snapshot cells:", len(snap))

land = snap[snap.is_water_arr == 0].copy()
water = snap[snap.is_water_arr == 1]
print(f"land cells: {len(land)}  water cells: {len(water)}")

def veg_table(sub, col, denom):
    vc = sub[col].value_counts().sort_index()
    rows = []
    for k, v in vc.items():
        rows.append((int(k), VEG_NAMES.get(int(k), "?"), v, 100.0 * v / denom))
    return rows

print("\n=== 当前植被 vegetation_arr (陆地, n=%d) ===" % len(land))
for k, name, v, pct in veg_table(land, "vegetation_arr", len(land)):
    print(f"  {k:2d} {name:22s} {v:5d}  {pct:5.1f}%")

print("\n=== 生成期植被 base_vegetation_arr (陆地) ===")
for k, name, v, pct in veg_table(land, "base_vegetation_arr", len(land)):
    print(f"  {k:2d} {name:22s} {v:5d}  {pct:5.1f}%")

# 草原+稀树草原合计
g_now = land.vegetation_arr.isin([9, 13]).mean() * 100
g_base = land.base_vegetation_arr.isin([9, 13]).mean() * 100
g_steppe_now = land.vegetation_arr.isin([9, 10, 13]).mean() * 100
print(f"\n草原(9)+稀树草原(13) 占比: 生成期 {g_base:.1f}% -> 当前 {g_now:.1f}%")
print(f"含干草原(10)合计: 当前 {g_steppe_now:.1f}%")

print("\n=== 陆地气候场统计 ===")
for c in ["temp_arr", "temp_baseline_arr", "temp_baseline_year_arr", "moisture_arr",
          "base_moisture_arr", "water_balance_30d_arr", "soil_moisture_arr",
          "cell_lat_norm_arr", "elevation_arr", "vegetation_vitality_arr"]:
    s = land[c]
    print(f"  {c:26s} mean={s.mean():.3f} p10={s.quantile(.1):.3f} p50={s.quantile(.5):.3f} "
          f"p90={s.quantile(.9):.3f} p95={s.quantile(.95):.3f} max={s.max():.3f}")

# Whittaker 带占位(按 pk_whittaker_vegetation 阈值, 用当前 temp/moist)
def whittaker_band(t, m):
    if t < 0.06: return "POLAR_DESERT"
    if t < 0.20: return "TUNDRA"
    if t < 0.40:
        if m > 0.40: return "TAIGA/CONIFER"
        if m > 0.20: return "BOREAL_SHRUB"
        return "STEPPE(cold-dry)"
    if t < 0.55:
        if m > 0.55: return "TEMP_DECIDUOUS"
        if m > 0.30: return "TEMP_GRASSLAND"
        return "STEPPE/BOREAL(dry)"
    if t < 0.66:
        if m > 0.36: return "SUBTROP_FOREST"
        if m > 0.22: return "TEMP_GRASSLAND(sub)"
        return "STEPPE(sub-dry)"
    if m > 0.58: return "RAINFOREST"
    if m > 0.38: return "TROP_DRY_FOREST"
    if m > 0.20: return "SAVANNA"
    if m < 0.10: return "XERIC_DESERT"
    return "DESERT_SCRUB"

land["wb"] = [whittaker_band(t, m) for t, m in zip(land.temp_arr, land.moisture_arr)]
print("\n=== 按当前 (temp,moist) 落入 Whittaker 带的陆地占比 ===")
wb = land.wb.value_counts(normalize=True) * 100
for k, v in wb.items():
    print(f"  {k:22s} {v:5.1f}%")

# 纬度带 × 植被
land["lat_abs"] = land.cell_lat_norm_arr.abs()
bins = [0, .2, .4, .6, .8, 1.01]
labels = ["|lat|<0.2(赤道)", "0.2-0.4(热带)", "0.4-0.6(温带)", "0.6-0.8(寒带)", ">0.8(极地)"]
land["lat_band"] = pd.cut(land.lat_abs, bins=bins, labels=labels, right=False)
print("\n=== 纬度带 × 当前植被 top3 ===")
for lb, sub in land.groupby("lat_band", observed=True):
    top = sub.vegetation_arr.map(VEG_NAMES).value_counts().head(3)
    tot = len(sub)
    s = ", ".join(f"{n} {c}({100*c/tot:.0f}%)" for n, c in top.items())
    print(f"  {lb:16s} n={tot:4d}: {s}")

# 温度带统计: 多少陆地 temp>=0.66(热带阈值) / 0.55-0.66(亚热带)
t = land.temp_arr
print(f"\n陆温度带: t<0.2 {(t<0.2).mean()*100:.1f}%  0.2-0.4 {((t>=0.2)&(t<0.4)).mean()*100:.1f}%  "
      f"0.4-0.55 {((t>=0.4)&(t<0.55)).mean()*100:.1f}%  0.55-0.66 {((t>=0.55)&(t<0.66)).mean()*100:.1f}%  "
      f">=0.66 {(t>=0.66).mean()*100:.1f}%")
m = land.moisture_arr
print(f"陆湿度带: m<0.1 {(m<0.1).mean()*100:.1f}%  0.1-0.2 {((m>=0.1)&(m<0.2)).mean()*100:.1f}%  "
      f"0.2-0.38 {((m>=0.2)&(m<0.38)).mean()*100:.1f}%  0.38-0.58 {((m>=0.38)&(m<0.58)).mean()*100:.1f}%  "
      f">=0.58 {(m>=0.58).mean()*100:.1f}%")

# 热带陆地里湿度分布 -> 为何是 SAVANNA 而非雨林
trop = land[t >= 0.66]
if len(trop):
    mt = trop.moisture_arr
    print(f"\n热带陆地(t>=0.66, n={len(trop)}): 湿度 p50={mt.quantile(.5):.3f} p90={mt.quantile(.9):.3f} "
          f"max={mt.max():.3f}; >0.58(雨林线)占比 {(mt>0.58).mean()*100:.1f}%  "
          f"0.38-0.58(季雨林) {( (mt>0.38)&(mt<=0.58) ).mean()*100:.1f}%  "
          f"0.2-0.38(稀树草原) {( (mt>0.2)&(mt<=0.38) ).mean()*100:.1f}%")
    print("  热带陆地当前植被 top5:",
          ", ".join(f"{VEG_NAMES.get(k,k)} {v}" for k, v in trop.vegetation_arr.value_counts().head(5).items()))

# 亚热带陆地
sub2 = land[(t >= 0.55) & (t < 0.66)]
if len(sub2):
    ms = sub2.moisture_arr
    print(f"亚热带陆地(0.55-0.66, n={len(sub2)}): 湿度 p50={ms.quantile(.5):.3f}; "
          f">0.36(亚热带森林线)占比 {(ms>0.36).mean()*100:.1f}%")
    print("  亚热带当前植被 top5:",
          ", ".join(f"{VEG_NAMES.get(k,k)} {v}" for k, v in sub2.vegetation_arr.value_counts().head(5).items()))

# 温带陆地
tmp = land[(t >= 0.4) & (t < 0.55)]
if len(tmp):
    mm = tmp.moisture_arr
    print(f"温带陆地(0.4-0.55, n={len(tmp)}): 湿度 p50={mm.quantile(.5):.3f}; "
          f">0.55(落叶林线)占比 {(mm>0.55).mean()*100:.1f}%")
    print("  温带当前植被 top5:",
          ", ".join(f"{VEG_NAMES.get(k,k)} {v}" for k, v in tmp.vegetation_arr.value_counts().head(5).items()))

# 演替漂移: 当前 vs 生成期 植被变化矩阵(草原/稀树草原来源)
chg = land[land.vegetation_arr != land.base_vegetation_arr]
print(f"\n发生植被演替的陆地格: {len(chg)} ({100*len(chg)/len(land):.1f}%)")
if len(chg):
    to_sav = chg[chg.vegetation_arr == 13].base_vegetation_arr.map(VEG_NAMES).value_counts().head(5)
    to_grs = chg[chg.vegetation_arr == 9].base_vegetation_arr.map(VEG_NAMES).value_counts().head(5)
    print("  变成 SAVANNA 的来源:", ", ".join(f"{k} {v}" for k, v in to_sav.items()))
    print("  变成 TEMP_GRASSLAND 的来源:", ", ".join(f"{k} {v}" for k, v in to_grs.items()))
    lost = chg[chg.base_vegetation_arr.isin([7, 8, 12, 14, 15, 25])].vegetation_arr.map(VEG_NAMES).value_counts().head(6)
    print("  森林类(7/8/12/14/15/25)退化去向:", ", ".join(f"{k} {v}" for k, v in lost.items()))

# vitality / stress 均值(按植被)
print("\n=== 各植被 vitality / stress 均值(陆地) ===")
g = land.groupby(land.vegetation_arr.map(VEG_NAMES)).agg(
    n=("cell_index", "count"),
    vit=("vegetation_vitality_arr", "mean"),
    drought=("vegetation_drought_stress_arr", "mean"),
    heat=("vegetation_heat_stress_arr", "mean"),
    cold=("vegetation_cold_stress_arr", "mean"),
    moist=("moisture_arr", "mean"),
    temp=("temp_arr", "mean"),
).sort_values("n", ascending=False).head(10)
print(g.round(3).to_string())
