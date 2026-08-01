# -*- coding: utf-8 -*-
"""临时审计②: 验证 vegetation_arr 与 cell_pos/lat 的空间对齐。
若数组与坐标发生行翻转, 则雨林会出现在高纬、沙漠灌木出现在赤道。"""
import pandas as pd
import numpy as np

CSV = r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260801_145534.csv"
VEG = {0:"NONE",1:"POLAR_DESERT",2:"TUNDRA",3:"ALPINE_TUNDRA",4:"ALPINE_MEADOW",
5:"TAIGA",6:"BOREAL_SHRUB",7:"TEMP_DECID",8:"TEMP_CONIFER",9:"TEMP_GRASS",
10:"TEMP_STEPPE",11:"MED_SHRUB",12:"SUBTROP_FOREST",13:"SAVANNA",14:"RAINFOREST",
15:"TROP_DRY_FOREST",16:"DESERT_SCRUB",17:"XERIC_DESERT",18:"OASIS",19:"MANGROVE",
20:"SWAMP",21:"MARSH",22:"KELP",23:"CORAL",24:"CLOUD_FOREST",25:"MONSOON_FOREST",
26:"SEAGRASS",27:"PEAT_BOG"}

df = pd.read_csv(CSV)
snap = df.sort_values("tick_idx").groupby("cell_index", as_index=False).tail(1).copy()
land = snap[snap.is_water_arr == 0].copy()

# 维度推断
w = int(snap.q.max() - snap.q.min() + 1)
h = int(snap.r.max() - snap.r.min() + 1)
print(f"map approx {w}x{h}, cells={len(snap)}")

# cell_lat_norm vs 行号
land["row"] = land.r - land.r.min()
print("\n=== lat_norm 统计 by row 四分位 ===")
land["row_q"] = pd.qcut(land.row, 4, labels=["top0-25%", "25-50%", "50-75%", "bot75-100%"])
for rq, sub in land.groupby("row_q", observed=True):
    print(f"  {rq:12s} lat_norm mean={sub.cell_lat_norm_arr.mean():+.3f} "
          f"min={sub.cell_lat_norm_arr.min():+.3f} max={sub.cell_lat_norm_arr.max():+.3f}")

# 植被 vs 纬度: 雨林/沙漠灌木/泰加的纬度重心
print("\n=== 关键植被的 |lat_norm| 与 temp 重心 ===")
for vid in [14, 25, 15, 13, 16, 17, 5, 7, 19, 20]:
    sub = land[land.vegetation_arr == vid]
    if not len(sub):
        continue
    print(f"  {VEG[vid]:16s} n={len(sub):4d} |lat| mean={sub.cell_lat_norm_arr.abs().mean():.3f} "
          f"lat mean={sub.cell_lat_norm_arr.mean():+.3f} temp mean={sub.temp_arr.mean():.3f} "
          f"row mean={sub.row.mean():.1f}")

# 按纬度带统计植被构成（检验 Whittaker 结构）
land["lat_abs"] = land.cell_lat_norm_arr.abs()
bands = [(0, .15, "eq<0.15"), (.15, .35, "trop .15-.35"), (.35, .55, "subtrop .35-.55"),
         (.55, .75, "temp .55-.75"), (.75, 1.01, "polar>.75")]
print("\n=== 纬度带 × 植被 top4 ===")
for lo, hi, name in bands:
    sub = land[(land.lat_abs >= lo) & (land.lat_abs < hi)]
    if not len(sub):
        continue
    top = sub.vegetation_arr.map(VEG).value_counts().head(4)
    s = ", ".join(f"{n} {c}({100*c/len(sub):.0f}%)" for n, c in top.items())
    print(f"  {name:16s} n={len(sub):4d}: {s}")

# cell_pos 与 lat 的关系: pos_y 应随纬度单调
print("\n=== pos_y vs lat_norm 相关性 ===")
print("  corr(pos_y, lat_norm) =", np.corrcoef(snap.cell_pos_y_arr, snap.cell_lat_norm_arr)[0,1])
print("  corr(r,      lat_norm) =", np.corrcoef(snap.r, snap.cell_lat_norm_arr)[0,1])

# 温度场结构 sanity: 赤道热两极度冷
print("\n=== temp vs |lat| ===")
for lo, hi, name in bands:
    sub = land[(land.lat_abs >= lo) & (land.lat_abs < hi)]
    if len(sub):
        print(f"  {name:16s} temp mean={sub.temp_arr.mean():.3f} moist mean={sub.moisture_arr.mean():.3f}")
