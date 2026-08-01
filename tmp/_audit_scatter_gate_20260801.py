# -*- coding: utf-8 -*-
"""临时审计: tile_data_record_20260801_145534.csv
目的: 复现"沙漠灌木长大树 / 雨林红树林无植被"的散布门禁条件。
按 shrub_layer.gd / world_ext_detail.cpp 的真实权重表, 用录制快照逐格重算
DETAIL_TREE / DETAIL_SHRUB 的 suitability 各因子, 找出哪个因子把目标格清零。
"""
import pandas as pd
import numpy as np

CSV = r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260801_145534.csv"

VEG = {0:"NONE",1:"POLAR_DESERT",2:"TUNDRA",3:"ALPINE_TUNDRA",4:"ALPINE_MEADOW",
5:"TAIGA",6:"BOREAL_SHRUB",7:"TEMP_DECID",8:"TEMP_CONIFER",9:"TEMP_GRASS",
10:"TEMP_STEPPE",11:"MED_SHRUB",12:"SUBTROP_FOREST",13:"SAVANNA",14:"RAINFOREST",
15:"TROP_DRY_FOREST",16:"DESERT_SCRUB",17:"XERIC_DESERT",18:"OASIS",19:"MANGROVE",
20:"SWAMP",21:"MARSH",22:"KELP",23:"CORAL",24:"CLOUD_FOREST",25:"MONSOON_FOREST",
26:"SEAGRASS",27:"PEAT_BOG"}

def tree_veg_weight(v):
    return {14:1.22,12:1.22,7:1.08,8:1.08,5:0.98,15:0.82,20:0.64,19:0.64,
            13:0.28,6:0.12,11:0.12,9:0.05,10:0.05,
            16:0.0,17:0.0,0:0.0,22:0.0,23:0.0}.get(v, 0.04)

def shrub_veg_weight(v):
    return {6:1.15,11:1.15,16:0.78,5:0.92,15:0.92,7:0.84,8:0.84,14:0.70,12:0.70,
            2:0.42,3:0.42,13:0.62,10:0.46,20:0.56,21:0.34,9:0.36,18:0.58,
            17:0.02,1:0.02,0:0.0,22:0.0,23:0.0}.get(v, 0.10)

# LandformType 猜测: 4=PLAIN? 需要确认。先打印 landform 实际取值分布再定。
def tree_land_weight(lf, water_lfs):
    if lf in (4,5): return 1.0
    if lf == 6: return 0.74
    if lf == 9: return 0.46
    if lf == 7: return 0.16
    if lf in (10,11,8,12): return 0.0
    return 0.0 if lf in water_lfs else 0.38

def cover_weight(c):
    if c in (2,3,6): return 0.0
    if c == 5: return 0.18
    if c == 1: return 0.48
    if c == 4: return 0.62
    return 1.0

df = pd.read_csv(CSV)
snap = df.sort_values("tick_idx").groupby("cell_index", as_index=False).tail(1).copy()
print("cells:", len(snap), "ticks:", sorted(df.tick_idx.unique())[:8])

land = snap[snap.is_water_arr == 0].copy()
print("land cells:", len(land), " water cells:", len(snap) - len(land))

print("\n=== vegetation_arr (land) ===")
for k, v in land.vegetation_arr.value_counts().sort_index().items():
    print(f"  {int(k):2d} {VEG.get(int(k),'?'):18s} {v:5d}  {100*v/len(land):5.1f}%")

print("\n=== landform_arr 取值 (land) ===")
for k, v in land.landform_arr.value_counts().sort_index().items():
    print(f"  lf={int(k):2d}  n={v:5d}")

print("\n=== cover_arr 取值 (land) ===")
for k, v in land.cover_arr.value_counts().sort_index().items():
    print(f"  cover={int(k):2d}  n={v:5d}")

# 地形语义核对: DESERT_SCRUB 格的地形/地貌
print("\n=== DESERT_SCRUB(16) 格画像 ===")
ds = land[land.vegetation_arr == 16]
print("n =", len(ds))
print("  terrain:", dict(ds.terrain_arr.value_counts().sort_index()))
print("  landform:", dict(ds.landform_arr.value_counts().sort_index()))
print("  cover:", dict(ds.cover_arr.value_counts().sort_index()))
print("  vitality: mean=%.3f p10=%.3f p90=%.3f" % (
    ds.vegetation_vitality_arr.mean(), ds.vegetation_vitality_arr.quantile(.1), ds.vegetation_vitality_arr.quantile(.9)))

# 关键: 沙漠灌木格的 tree 权重恒 0 —— 但快照里这些格在"生成期"是什么植被?
print("\n=== DESERT_SCRUB 格的 base_vegetation (生成期) ===")
for k, v in ds.base_vegetation_arr.value_counts().sort_index().items():
    print(f"  base={int(k):2d} {VEG.get(int(k),'?'):18s} {v:5d}")

print("\n=== RAINFOREST(14) 格画像 ===")
rf = land[land.vegetation_arr == 14]
print("n =", len(rf))
if len(rf):
    print("  terrain:", dict(rf.terrain_arr.value_counts().sort_index()))
    print("  landform:", dict(rf.landform_arr.value_counts().sort_index()))
    print("  cover:", dict(rf.cover_arr.value_counts().sort_index()))
    print("  vitality: mean=%.3f p10=%.3f p50=%.3f" % (
        rf.vegetation_vitality_arr.mean(), rf.vegetation_vitality_arr.quantile(.1),
        rf.vegetation_vitality_arr.quantile(.5)))
    print("  has_river:", dict(rf.has_river_arr.value_counts()))
    print("  base_vegetation:", {VEG.get(int(k),k): v for k,v in rf.base_vegetation_arr.value_counts().items()})

print("\n=== MANGROVE(19) 格画像 ===")
mg = snap[snap.vegetation_arr == 19]  # 含水域格, 红树林可能在 water 掩码里
print("n(all) =", len(mg), " is_water=1:", int((mg.is_water_arr==1).sum()))
if len(mg):
    print("  terrain:", dict(mg.terrain_arr.value_counts().sort_index()))
    print("  landform:", dict(mg.landform_arr.value_counts().sort_index()))
    print("  cover:", dict(mg.cover_arr.value_counts().sort_index()))
    print("  vitality: mean=%.3f" % mg.vegetation_vitality_arr.mean())

# ─── 门禁复算: 对每个陆地格算 tree suitability 的前置硬门 ───
print("\n=== 硬门复算 (land, DETAIL_TREE) ===")
# water landform 集合未知, 先打印所有出现在水域的 landform
water_lfs = set(snap[snap.is_water_arr==1].landform_arr.unique())
print("  水域格出现的 landform 值:", sorted(int(x) for x in water_lfs))

g = land.copy()
g["vw_tree"] = g.vegetation_arr.map(tree_veg_weight)
g["lw_tree"] = g.landform_arr.map(lambda lf: tree_land_weight(int(lf), water_lfs))
g["cw"] = g.cover_arr.map(cover_weight)
g["gate_vw0"] = g.vw_tree <= 0
g["gate_lw0"] = g.lw_tree <= 0
g["gate_cw0"] = g.cw <= 0
g["gate_vitlow"] = g.vegetation_vitality_arr < 0.12

for veg_id, name in [(14,"RAINFOREST"),(19,"MANGROVE"),(16,"DESERT_SCRUB"),(24,"CLOUD_FOREST"),(25,"MONSOON_FOREST")]:
    sub = g[g.vegetation_arr == veg_id]
    if not len(sub):
        print(f"  {name:16s}: n=0")
        continue
    print(f"  {name:16s}: n={len(sub):4d} | vw=0 {100*sub.gate_vw0.mean():5.1f}%  "
          f"lw=0 {100*sub.gate_lw0.mean():5.1f}%  cw=0 {100*sub.gate_cw0.mean():5.1f}%  "
          f"vit<0.12 {100*sub.gate_vitlow.mean():5.1f}%  "
          f"硬门任一命中 {100*((sub.gate_vw0)|(sub.gate_lw0)|(sub.gate_cw0)|(sub.gate_vitlow)).mean():5.1f}%")

# tree 权重为 0 但用户"看到大树"的格: 它们的生成期植被是不是森林?
print("\n=== 若散布用 base_vegetation 而非 vegetation 会怎样 ===")
g["vw_tree_base"] = g.base_vegetation_arr.map(tree_veg_weight)
now_scrub_was_forest = g[(g.vegetation_arr==16) & (g.vw_tree_base>=0.8)]
print("  当前 DESERT_SCRUB 但生成期是高树权重植被(>=0.8) 的格数:", len(now_scrub_was_forest),
      f"({100*len(now_scrub_was_forest)/max(1,(g.vegetation_arr==16).sum()):.1f}% of DESERT_SCRUB)")
now_rf_was_low = g[(g.vegetation_arr==14) & (g.vw_tree_base<=0.05)]
print("  当前 RAINFOREST 但生成期 tree 权重<=0.05 的格数:", len(now_rf_was_low),
      f"({100*len(now_rf_was_low)/max(1,(g.vegetation_arr==14).sum()):.1f}% of RAINFOREST)")
now_mg_was_low = g[(g.vegetation_arr==19) & (g.vw_tree_base<=0.05)]
print("  当前 MANGROVE 但生成期 tree 权重<=0.05 的格数:", len(now_mg_was_low),
      f"({100*len(now_mg_was_low)/max(1,(g.vegetation_arr==19).sum()):.1f}% of MANGROVE)")

# 反向: 当前 vs 生成期的植被变化总表(只列森林<->荒漠)
print("\n=== 演替矩阵 (base -> now) 主要流向 ===")
chg = g[g.vegetation_arr != g.base_vegetation_arr]
print("  总漂移格:", len(chg))
flow = chg.groupby([chg.base_vegetation_arr.map(VEG), chg.vegetation_arr.map(VEG)]).size().sort_values(ascending=False).head(12)
for (a,b), n in flow.items():
    print(f"  {a:16s} -> {b:16s}  {n}")
