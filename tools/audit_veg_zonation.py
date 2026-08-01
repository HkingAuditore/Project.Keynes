# -*- coding: utf-8 -*-
"""audit_veg_zonation.py — Project.Keynes 植被/生物群系纬度格局审计工具。

输入 tile_data_record_*.csv（per-cell 记录，可含多 tick），输出：
  - 植被族系占比（当前 vs 生成期）
  - base_moisture / temp 纬度带统计（赤道/副热带/中纬/极地）
  - Whittaker 带占位（与 C++ pk_whittaker_vegetation 2026-08-01 zonal-envelope 阈值同步）
  - 赤道核心森林 vs 草原、演替漂移矩阵、各植被 vitality 均值
  - 验收硬指标核对（赤道湿于副热带、荒漠≥2%、草原系<30%、森林25-35%等）

用法:
  python tools/audit_veg_zonation.py <tile_csv> [--tick last]
"""
import argparse
import sys

import numpy as np
import pandas as pd

VEG_NAMES = {
    0: "NONE", 1: "POLAR_DESERT", 2: "TUNDRA", 3: "ALPINE_TUNDRA", 4: "ALPINE_MEADOW",
    5: "TAIGA", 6: "BOREAL_SHRUB", 7: "TEMPERATE_DECIDUOUS", 8: "TEMPERATE_CONIFER",
    9: "TEMPERATE_GRASSLAND", 10: "TEMPERATE_STEPPE", 11: "MEDITERRANEAN_SHRUB",
    12: "SUBTROPICAL_FOREST", 13: "SAVANNA", 14: "TROPICAL_RAINFOREST", 15: "TROPICAL_DRY_FOREST",
    16: "DESERT_SCRUB", 17: "XERIC_DESERT", 18: "OASIS_VEG", 19: "MANGROVE", 20: "SWAMP",
    21: "MARSH", 22: "KELP_FOREST", 23: "CORAL_REEF", 24: "CLOUD_FOREST", 25: "MONSOON_FOREST",
    26: "SEAGRASS", 27: "PEAT_BOG",
}
FOREST = [5, 7, 8, 12, 14, 15, 24, 25]
GRASS = [9, 10, 13]
DESERT = [1, 16, 17]


def whittaker_band(t: float, m: float) -> str:
    """与 C++ pk_whittaker_vegetation（zonal-envelope 2026-08-01）同步的阈值镜像。"""
    if t < 0.06:
        return "POLAR_DESERT"
    if t < 0.20:
        return "TUNDRA"
    if t < 0.40:
        if m > 0.40:
            return "TAIGA/CONIFER"
        if m > 0.20:
            return "BOREAL_SHRUB"
        return "STEPPE(cold-dry)"
    if t < 0.55:
        if m > 0.48:
            return "TEMP_DECIDUOUS"
        if m > 0.26:
            return "TEMP_GRASSLAND"
        return "STEPPE/BOREAL(dry)"
    if t < 0.80:
        if m > 0.40:
            return "SUBTROP_FOREST"
        if m > 0.22:
            return "TEMP_GRASSLAND(sub)"
        if m < 0.12:
            return "DESERT_SCRUB(sub)"
        return "STEPPE(sub-dry)"
    if m > 0.56:
        return "RAINFOREST"
    if m > 0.38:
        return "TROP_DRY_FOREST"
    if m > 0.24:  # [zonal-envelope 二轮] 0.20→0.24
        return "SAVANNA"
    if m < 0.10:
        return "XERIC_DESERT"
    return "DESERT_SCRUB"


def family_share(veg: pd.Series, ids: list[int]) -> float:
    return float(veg.isin(ids).mean() * 100.0)


def main() -> int:
    ap = argparse.ArgumentParser(description="Project.Keynes 植被纬度格局审计")
    ap.add_argument("csv", help="tile_data_record_*.csv 路径")
    ap.add_argument("--tick", default="last", help="使用的 tick（默认 last 取最后快照）")
    args = ap.parse_args()

    df = pd.read_csv(args.csv)
    print("rows:", len(df), "unique ticks:", sorted(df.tick_idx.unique())[:8], "...")
    if args.tick != "last":
        df = df[df.tick_idx == int(args.tick)]
        snap = df.copy()
    else:
        snap = df.sort_values("tick_idx").groupby("cell_index", as_index=False).tail(1).copy()
    print("snapshot cells:", len(snap))

    land = snap[snap.is_water_arr == 0].copy()
    print(f"land cells: {len(land)}  water cells: {int((snap.is_water_arr == 1).sum())}")

    print("\n=== 当前植被 vegetation_arr (陆地, n=%d) ===" % len(land))
    vc = land.vegetation_arr.value_counts().sort_index()
    for k, v in vc.items():
        print(f"  {int(k):2d} {VEG_NAMES.get(int(k), '?'):22s} {v:5d}  {100.0 * v / len(land):5.1f}%")

    f_now = family_share(land.vegetation_arr, FOREST)
    g_now = family_share(land.vegetation_arr, GRASS)
    d_now = family_share(land.vegetation_arr, DESERT)
    print(f"\n族系占比: 森林系 {f_now:.1f}%  草原系 {g_now:.1f}%  荒漠系 {d_now:.1f}%")
    if "base_vegetation_arr" in land.columns:
        f0 = family_share(land.base_vegetation_arr, FOREST)
        g0 = family_share(land.base_vegetation_arr, GRASS)
        d0 = family_share(land.base_vegetation_arr, DESERT)
        print(f"  生成期: 森林系 {f0:.1f}%  草原系 {g0:.1f}%  荒漠系 {d0:.1f}%")

    print("\n=== 陆地气候场统计 ===")
    for c in ["temp_arr", "temp_365d_arr", "moisture_arr", "base_moisture_arr",
              "water_balance_30d_arr", "soil_moisture_arr", "cell_lat_norm_arr",
              "elevation_arr", "vegetation_vitality_arr"]:
        if c not in land.columns:
            continue
        s = land[c]
        print(f"  {c:26s} mean={s.mean():.3f} p10={s.quantile(.1):.3f} p50={s.quantile(.5):.3f} "
              f"p90={s.quantile(.9):.3f} max={s.max():.3f}")

    # eq_dist 纬带（0=赤道 1=极）
    eq = (land.cell_lat_norm_arr * 2.0 - 1.0).abs()
    bands = [("eq<0.2(0-18°)", eq < 0.2), ("subtrop 0.2-0.45(18-40°)", (eq >= 0.2) & (eq < 0.45)),
             ("midlat 0.45-0.7(40-63°)", (eq >= 0.45) & (eq < 0.7)), ("polar>0.7(63°+)", eq >= 0.7)]
    print("\n=== 纬度带 × base_moisture / 植被族系 ===")
    band_median = {}
    for name, mask in bands:
        sub = land[mask]
        if len(sub) == 0:
            continue
        bm = sub.base_moisture_arr if "base_moisture_arr" in sub.columns else sub.moisture_arr
        band_median[name] = float(bm.quantile(0.5))
        eqf = family_share(sub.vegetation_arr, FOREST)
        eqg = family_share(sub.vegetation_arr, GRASS)
        eqd = family_share(sub.vegetation_arr, DESERT)
        print(f"  {name:26s} n={len(sub):5d} bm_med={bm.quantile(.5):.3f} bm_p10={bm.quantile(.1):.3f} "
              f"bm_min={bm.min():.3f} | F{eqf:.0f}% G{eqg:.0f}% D{eqd:.0f}%")
        top = sub.vegetation_arr.map(VEG_NAMES).value_counts().head(3)
        print("      top3:", ", ".join(f"{n} {c}({100 * c / len(sub):.0f}%)" for n, c in top.items()))

    land["wb"] = [whittaker_band(t, m) for t, m in zip(land.temp_arr, land.moisture_arr)]
    print("\n=== 按当前 (temp,moist) 落入 Whittaker 带的陆地占比 ===")
    for k, v in (land.wb.value_counts(normalize=True) * 100).items():
        print(f"  {k:22s} {v:5.1f}%")

    chg = land[land.vegetation_arr != land.base_vegetation_arr] if "base_vegetation_arr" in land.columns else land.iloc[0:0]
    if len(land) and "base_vegetation_arr" in land.columns:
        print(f"\n发生植被演替的陆地格: {len(chg)} ({100 * len(chg) / len(land):.2f}%)")
        if len(chg):
            mat = chg.groupby([chg.base_vegetation_arr.map(VEG_NAMES),
                               chg.vegetation_arr.map(VEG_NAMES)]).size().sort_values(ascending=False).head(10)
            for (src, dst), n in mat.items():
                print(f"    {src:22s} -> {dst:22s} {n}")

    if "vegetation_vitality_arr" in land.columns:
        print("\n=== 各植被 vitality 均值 top10 ===")
        g = land.groupby(land.vegetation_arr.map(VEG_NAMES)).agg(
            n=("cell_index", "count"),
            vit=("vegetation_vitality_arr", "mean"),
            moist=("moisture_arr", "mean"),
            temp=("temp_arr", "mean"),
        ).sort_values("n", ascending=False).head(10)
        print(g.round(3).to_string())

    # ── 验收硬指标核对 ────────────────────────────────────────────────
    print("\n=== 验收硬指标（zonal-envelope 2026-08-01 方案） ===")
    eq_med = band_median.get("eq<0.2(0-18°)", np.nan)
    sub_med = band_median.get("subtrop 0.2-0.45(18-40°)", np.nan)
    mid_med = band_median.get("midlat 0.45-0.7(40-63°)", np.nan)
    sub_mask = (eq >= 0.2) & (eq < 0.45)
    bm_all = land.base_moisture_arr if "base_moisture_arr" in land.columns else land.moisture_arr
    sub_dry_cells = int((bm_all[sub_mask] < 0.2).sum())
    eq_core = land[eq < 0.15]
    eq_f = family_share(eq_core.vegetation_arr, FOREST)
    eq_g = family_share(eq_core.vegetation_arr, GRASS)
    checks = [
        ("赤道带 bm 中位数 > 副热带带", eq_med > sub_med, f"eq={eq_med:.3f} sub={sub_med:.3f}"),
        ("副热带带存在 bm<0.2 格（荒漠可达）", sub_dry_cells > 0, f"cells={sub_dry_cells}"),
        ("中纬带 bm 中位数 > 副热带带", mid_med > sub_med, f"mid={mid_med:.3f} sub={sub_med:.3f}"),
        ("赤道核心(eq<0.15) 森林系 > 草原系", eq_f > eq_g, f"F={eq_f:.1f}% G={eq_g:.1f}%"),
        ("全图森林系 25-35%", 25.0 <= f_now <= 35.0, f"{f_now:.1f}%"),
        ("全图草原系 <30%", g_now < 30.0, f"{g_now:.1f}%"),
        ("全图荒漠系 >=2%", d_now >= 2.0, f"{d_now:.1f}%"),
    ]
    n_fail = 0
    for label, ok, detail in checks:
        mark = "PASS" if ok else "FAIL"
        if not ok:
            n_fail += 1
        print(f"  [{mark}] {label}  ({detail})")
    print(f"\n硬指标: {len(checks) - n_fail}/{len(checks)} 通过")
    return 1 if n_fail else 0


if __name__ == "__main__":
    sys.exit(main())
