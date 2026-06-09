#!/usr/bin/env python3
"""Project Keynes 气候模拟数据综合分析
横向分析 (cross-section): 多tick截面 → 温度/洋流/风场/天气/海冰空间分布
纵向分析 (time-series): 代表cell时间序列 → 季节周期/天气演变/海冰变迁
"""

import pandas as pd
import numpy as np
import json, os, sys, warnings
from collections import defaultdict
warnings.filterwarnings('ignore')

CSV_PATH = r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260609_180011.csv"
OUT_DIR  = r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\analysis_output"
os.makedirs(OUT_DIR, exist_ok=True)

# ─── 关键列索引 (0-based) ───
COL_TICK      = 1
COL_CELL      = 15
COL_Q         = 16
COL_R         = 17
COL_LAT       = 74  # cell_lat_norm_arr
COL_TEMP      = 19  # temp_arr
COL_TEMP_PREV = 20
COL_TEMP_BASE = 25  # temp_baseline_arr
COL_TEMP_365D = 27
COL_TEMP_ANOM = 28
COL_SEA_ICE   = 29
COL_ELEV      = 61
COL_OCEAN_X   = 63
COL_OCEAN_Y   = 64
COL_WIND_X    = 65
COL_WIND_Y    = 66
COL_SLP       = 67
COL_WIND_SPD  = 68
COL_INSOL_NOW = 44
COL_INSOL_DEV = 45
COL_HEAT_IN   = 47
COL_MOISTURE  = 21
COL_PRECIP    = 34
COL_WEATHER   = 83  # weather_type_arr
COL_IS_WATER  = 86
COL_WEATHER_INTENSITY = 31
COL_WEATHER_CLOUD      = 32
COL_VEG_VITALITY = 51
COL_OCEAN_PSI = 71

NUMERIC_COLS = [
    COL_TEMP, COL_TEMP_PREV, COL_TEMP_BASE, COL_TEMP_365D, COL_TEMP_ANOM,
    COL_SEA_ICE, COL_ELEV, COL_OCEAN_X, COL_OCEAN_Y, COL_WIND_X, COL_WIND_Y,
    COL_SLP, COL_WIND_SPD, COL_INSOL_NOW, COL_INSOL_DEV, COL_HEAT_IN,
    COL_MOISTURE, COL_PRECIP, COL_WEATHER_INTENSITY, COL_WEATHER_CLOUD,
    COL_VEG_VITALITY, COL_LAT, COL_OCEAN_PSI, COL_WEATHER
]

print("=" * 70)
print("  Project Keynes 气候模拟数据分析")
print("=" * 70)

# ─── 第一遍: 采样关键 tick ───
print("\n[1/5] 第一遍扫描: 获取 tick 列表...")
chunk_iter = pd.read_csv(
    CSV_PATH, header=0, chunksize=50000, dtype={COL_TICK: int, COL_CELL: int},
    encoding='utf-8-sig'
)
all_ticks = set()
for chunk in chunk_iter:
    all_ticks.update(chunk.iloc[:, COL_TICK].unique())

all_ticks = sorted(all_ticks)
n_ticks = len(all_ticks)
print(f"  Ticks: {n_ticks} 个, 范围 [{all_ticks[0]}, {all_ticks[-1]}]")

# 选代表性 ticks
if n_ticks <= 5:
    sample_ticks = all_ticks
else:
    indices = [0, n_ticks // 4, n_ticks // 2, 3 * n_ticks // 4, n_ticks - 1]
    sample_ticks = [all_ticks[i] for i in indices]
print(f"  截面采样 ticks: {sample_ticks}")

# ─── 第二遍: 提取截面数据 + 全量统计 ───
print("\n[2/5] 第二遍扫描: 提取截面 + 统计...")

# 截面数据存储
cross_sections = {t: defaultdict(list) for t in sample_ticks}

# 全局统计
global_stats = {
    'temp': [], 'sea_ice': [], 'wind_speed': [], 'precip': [],
    'insolation': [], 'temp_anomaly': [], 'ocean_x': [], 'ocean_y': [],
    'wind_x': [], 'wind_y': [], 'slp': [], 'vegetation': [],
    'lat_temp_pairs': [],  # (lat, temp) for latitudinal profile
}

# 纵向: 候选 cell 列表 (等间距采样)
cell_candidates = set()
target_cell_count = 20  # 取20个代表cell做纵向

chunk_iter2 = pd.read_csv(
    CSV_PATH, header=0, chunksize=100000, dtype={COL_TICK: int, COL_CELL: int},
    encoding='utf-8-sig'
)

total_rows = 0
for chunk in chunk_iter2:
    total_rows += len(chunk)
    tick_vals = chunk.iloc[:, COL_TICK].values
    cell_vals = chunk.iloc[:, COL_CELL].values

    # 全局统计抽样 (每 10 行取 1)
    mask_sample = np.arange(len(chunk)) % 10 == 0
    for col_idx, key in [
        (COL_TEMP, 'temp'), (COL_SEA_ICE, 'sea_ice'), (COL_WIND_SPD, 'wind_speed'),
        (COL_PRECIP, 'precip'), (COL_INSOL_NOW, 'insolation'),
        (COL_TEMP_ANOM, 'temp_anomaly'), (COL_OCEAN_X, 'ocean_x'),
        (COL_OCEAN_Y, 'ocean_y'), (COL_WIND_X, 'wind_x'), (COL_WIND_Y, 'wind_y'),
        (COL_SLP, 'slp'), (COL_VEG_VITALITY, 'vegetation')
    ]:
        vals = pd.to_numeric(chunk.iloc[:, col_idx], errors='coerce').values
        global_stats[key].extend(vals[mask_sample].tolist())

    # lat-temp pairs
    lats = pd.to_numeric(chunk.iloc[:, COL_LAT], errors='coerce').values
    temps = pd.to_numeric(chunk.iloc[:, COL_TEMP], errors='coerce').values
    global_stats['lat_temp_pairs'].extend(
        [(l, t) for l, t in zip(lats[mask_sample], temps[mask_sample]) if not np.isnan(l) and not np.isnan(t)]
    )

    # 截面提取
    for t in sample_ticks:
        mask = tick_vals == t
        if mask.any():
            for col_idx in [COL_TEMP, COL_TEMP_BASE, COL_TEMP_365D, COL_SEA_ICE,
                           COL_ELEV, COL_LAT, COL_OCEAN_X, COL_OCEAN_Y, COL_WIND_X,
                           COL_WIND_Y, COL_SLP, COL_WIND_SPD, COL_INSOL_NOW,
                           COL_MOISTURE, COL_PRECIP, COL_WEATHER, COL_IS_WATER,
                           COL_WEATHER_INTENSITY, COL_WEATHER_CLOUD,
                           COL_VEG_VITALITY, COL_Q, COL_R, COL_OCEAN_PSI]:
                vals = pd.to_numeric(chunk.iloc[:, col_idx], errors='coerce').values[mask]
                cross_sections[t][col_idx].extend(vals.tolist())
            cross_sections[t]['cell'].extend(cell_vals[mask].tolist())

    # 纵向候选
    if len(cell_candidates) < target_cell_count:
        for i in range(0, len(chunk), max(1, len(chunk) // 10)):
            cell_candidates.add(cell_vals[i])

    if total_rows % 1000000 == 0:
        print(f"  ... 已处理 {total_rows:,} 行")

cell_candidates = sorted(list(cell_candidates))[:target_cell_count]
print(f"  总行数: {total_rows:,}")
print(f"  纵向采样 cells: {cell_candidates}")

# ─── 第三遍: 提取纵向时间序列 ───
print("\n[3/5] 第三遍扫描: 提取时间序列...")
time_series = {c: defaultdict(list) for c in cell_candidates}

chunk_iter3 = pd.read_csv(
    CSV_PATH, header=0, chunksize=100000, dtype={COL_TICK: int, COL_CELL: int},
    encoding='utf-8-sig'
)

for chunk in chunk_iter3:
    cell_vals = chunk.iloc[:, COL_CELL].values
    tick_vals = chunk.iloc[:, COL_TICK].values

    for ci in cell_candidates:
        mask = cell_vals == ci
        if mask.any():
            for col_idx, key in [
                (COL_TICK, 'tick'), (COL_TEMP, 'temp'), (COL_TEMP_BASE, 'temp_base'),
                (COL_TEMP_365D, 'temp_365d'), (COL_SEA_ICE, 'sea_ice'),
                (COL_INSOL_NOW, 'insolation'), (COL_PRECIP, 'precip'),
                (COL_MOISTURE, 'moisture'), (COL_WIND_SPD, 'wind_speed'),
                (COL_WEATHER, 'weather'), (COL_WEATHER_INTENSITY, 'weather_intensity'),
                (COL_WEATHER_CLOUD, 'weather_cloud'), (COL_LAT, 'lat'),
                (COL_IS_WATER, 'is_water'), (COL_ELEV, 'elev'),
                (COL_OCEAN_X, 'ocean_x'), (COL_OCEAN_Y, 'ocean_y'),
                (COL_WIND_X, 'wind_x'), (COL_WIND_Y, 'wind_y'),
                (COL_VEG_VITALITY, 'vegetation')
            ]:
                vals = pd.to_numeric(chunk.iloc[:, col_idx], errors='coerce').values[mask]
                time_series[ci][key].extend(vals.tolist())

# ─── 第四遍: 生成分析报告 ───
print("\n[4/5] 生成分析...")

report_lines = []
def rpt(s):
    report_lines.append(s)
    print(s)

rpt("=" * 70)
rpt("  Project Keynes 气候模拟综合评估报告")
rpt("=" * 70)
rpt(f"\n数据规模: {total_rows:,} 行, {n_ticks} ticks, {len(cell_candidates)} 个纵向采样cell")
rpt(f"时间范围: tick {all_ticks[0]} → {all_ticks[-1]}")

# ─── 全局统计 ───
rpt("\n" + "─" * 50)
rpt("【A】全局统计摘要")
rpt("─" * 50)

for key, label in [
    ('temp', '温度 (°C)'), ('sea_ice', '海冰比例'),
    ('wind_speed', '风速'), ('precip', '降水量'),
    ('insolation', '太阳辐射'), ('temp_anomaly', '温度异常'),
    ('ocean_x', '洋流 X'), ('ocean_y', '洋流 Y'),
    ('wind_x', '风 X'), ('wind_y', '风 Y'),
    ('slp', '海平面气压 SLP'), ('vegetation', '植被活力')
]:
    arr = np.array([v for v in global_stats[key] if not np.isnan(v) and np.isfinite(v)])
    if len(arr) == 0:
        rpt(f"  {label:12s}: (无有效数据)")
        continue
    rpt(f"  {label:12s}: mean={np.mean(arr):.4f}, std={np.std(arr):.4f}, "
        f"min={np.min(arr):.4f}, max={np.max(arr):.4f}, "
        f"p5={np.percentile(arr,5):.4f}, p95={np.percentile(arr,95):.4f}")

# ─── 温度-纬度剖面 ───
rpt("\n" + "─" * 50)
rpt("【B】温度-纬度剖面 (横向分析)")
rpt("─" * 50)

lat_temp = np.array(global_stats['lat_temp_pairs'])
if len(lat_temp) > 0:
    lat_bins = np.linspace(-1, 1, 21)  # 20个纬度带
    for i in range(len(lat_bins) - 1):
        lo, hi = lat_bins[i], lat_bins[i+1]
        mask = (lat_temp[:, 0] >= lo) & (lat_temp[:, 0] < hi)
        if np.sum(mask) > 0:
            avg_t = np.mean(lat_temp[mask, 1])
            rpt(f"  纬度 [{lo:+.2f}, {hi:+.2f}): avg_temp={avg_t:.2f}°C, n={np.sum(mask)}")

# ─── 各 tick 截面分析 ───
rpt("\n" + "─" * 50)
rpt("【C】多Tick截面比较 (横向分析)")
rpt("─" * 50)

for t in sample_ticks:
    sec = cross_sections[t]
    temps = np.array([v for v in sec[COL_TEMP] if not np.isnan(v) and np.isfinite(v)])
    sea_ice = np.array([v for v in sec[COL_SEA_ICE] if not np.isnan(v) and np.isfinite(v)])
    precip = np.array([v for v in sec[COL_PRECIP] if not np.isnan(v) and np.isfinite(v)])
    wind_spd = np.array([v for v in sec[COL_WIND_SPD] if not np.isnan(v) and np.isfinite(v)])
    insolation = np.array([v for v in sec[COL_INSOL_NOW] if not np.isnan(v) and np.isfinite(v)])
    lats = np.array([v for v in sec[COL_LAT] if not np.isnan(v) and np.isfinite(v)])
    weathers = np.array([v for v in sec[COL_WEATHER] if not np.isnan(v) and np.isfinite(v)])
    is_water = np.array([v for v in sec[COL_IS_WATER] if not np.isnan(v) and np.isfinite(v)])

    rpt(f"\n  Tick {t}:")
    rpt(f"    温度: mean={np.mean(temps):.2f}°C, std={np.std(temps):.2f}, "
        f"min={np.min(temps):.2f}, max={np.max(temps):.2f}")
    rpt(f"    海冰: mean={np.mean(sea_ice):.4f}, max={np.max(sea_ice):.4f}, "
        f"nonzero_ratio={np.mean(sea_ice > 0.01):.3%}")
    rpt(f"    降水: mean={np.mean(precip):.4f}, p95={np.percentile(precip,95):.4f}")
    rpt(f"    风速: mean={np.mean(wind_spd):.2f}, max={np.max(wind_spd):.2f}")
    rpt(f"    辐射: mean={np.mean(insolation):.4f}")

    # 天气类型分布
    if len(weathers) > 0:
        weather_counts = {}
        for w in weathers:
            weather_counts[int(w)] = weather_counts.get(int(w), 0) + 1
        weather_str = ", ".join(f"type={k}:{v} ({v/len(weathers):.1%})"
                                for k, v in sorted(weather_counts.items())[:8])
        rpt(f"    天气类型: {weather_str}")

    # 水陆对比
    if len(is_water) == len(temps):
        land_mask = is_water < 0.5
        water_mask = is_water >= 0.5
        if np.sum(land_mask) > 0 and np.sum(water_mask) > 0:
            rpt(f"    陆地温度: {np.mean(temps[land_mask]):.2f}°C, "
                f"水体温度: {np.mean(temps[water_mask]):.2f}°C")

    # 按纬度带分组的温度
    if len(lats) == len(temps) and len(lats) > 0:
        rpt(f"    纬度带温度分布:")
        for lo, hi in [(-1.0, -0.5), (-0.5, -0.2), (-0.2, 0.2), (0.2, 0.5), (0.5, 1.0)]:
            mask = (lats >= lo) & (lats < hi)
            if np.sum(mask) > 5:
                rpt(f"      [{lo:+.1f},{hi:+.1f}): {np.mean(temps[mask]):.1f}°C "
                    f"(n={np.sum(mask)})")

# ─── 洋流场分析 ───
rpt("\n" + "─" * 50)
rpt("【D】洋流场分析 (横向分析)")
rpt("─" * 50)

for t in sample_ticks[:3]:  # 只取前3个tick
    sec = cross_sections[t]
    ox = np.array([v for v in sec[COL_OCEAN_X] if not np.isnan(v) and np.isfinite(v)])
    oy = np.array([v for v in sec[COL_OCEAN_Y] if not np.isnan(v) and np.isfinite(v)])
    is_water = np.array([v for v in sec[COL_IS_WATER] if not np.isnan(v) and np.isfinite(v)])
    lats_arr = np.array([v for v in sec[COL_LAT] if not np.isnan(v) and np.isfinite(v)])
    ocean_psi = np.array([v for v in sec[COL_OCEAN_PSI] if not np.isnan(v) and np.isfinite(v)])

    min_len = min(len(ox), len(oy), len(is_water), len(lats_arr))
    ox, oy, is_water, lats_arr = ox[:min_len], oy[:min_len], is_water[:min_len], lats_arr[:min_len]

    water_mask = is_water > 0.5
    ox_w, oy_w = ox[water_mask], oy[water_mask]

    rpt(f"\n  Tick {t}:")
    rpt(f"    水体cell数: {np.sum(water_mask)}/{len(ox)}")
    if len(ox_w) > 0:
        mag = np.sqrt(ox_w**2 + oy_w**2)
        rpt(f"    洋流大小: mean={np.mean(mag):.4f}, max={np.max(mag):.4f}, "
            f"p95={np.percentile(mag,95):.4f}")
        rpt(f"    洋流方向: X mean={np.mean(ox_w):.4f}, Y mean={np.mean(oy_w):.4f}")

        # 按纬度分析洋流方向
        for lo, hi in [(-1.0, -0.5), (-0.5, -0.2), (-0.2, 0.2), (0.2, 0.5), (0.5, 1.0)]:
            mask = (lats_arr[water_mask] >= lo) & (lats_arr[water_mask] < hi)
            if np.sum(mask) > 3:
                rpt(f"      [{lo:+.1f},{hi:+.1f}): X={np.mean(ox_w[mask]):.4f}, "
                    f"Y={np.mean(oy_w[mask]):.4f}, mag={np.mean(np.sqrt(ox_w[mask]**2+oy_w[mask]**2)):.4f}")

    if len(ocean_psi) > 0:
        rpt(f"    海洋流函数 psi: mean={np.mean(ocean_psi):.4f}, std={np.std(ocean_psi):.4f}")

# ─── 风场分析 ───
rpt("\n" + "─" * 50)
rpt("【E】风场分析 (横向分析)")
rpt("─" * 50)

for t in sample_ticks[:3]:
    sec = cross_sections[t]
    wx = np.array([v for v in sec[COL_WIND_X] if not np.isnan(v) and np.isfinite(v)])
    wy = np.array([v for v in sec[COL_WIND_Y] if not np.isnan(v) and np.isfinite(v)])
    slp = np.array([v for v in sec[COL_SLP] if not np.isnan(v) and np.isfinite(v)])
    ws = np.array([v for v in sec[COL_WIND_SPD] if not np.isnan(v) and np.isfinite(v)])
    lats_arr = np.array([v for v in sec[COL_LAT] if not np.isnan(v) and np.isfinite(v)])

    min_len = min(len(wx), len(wy), len(slp), len(ws), len(lats_arr))
    wx, wy, slp, ws, lats_arr = wx[:min_len], wy[:min_len], slp[:min_len], ws[:min_len], lats_arr[:min_len]

    rpt(f"\n  Tick {t}:")
    rpt(f"    风速: mean={np.mean(ws):.4f}, std={np.std(ws):.4f}, "
        f"max={np.max(ws):.4f}")
    rpt(f"    SLP: mean={np.mean(slp):.4f}, std={np.std(slp):.4f}, "
        f"min={np.min(slp):.4f}, max={np.max(slp):.4f}")

    # 按纬度分析风向
    for lo, hi in [(-1.0, -0.5), (-0.5, -0.2), (-0.2, 0.2), (0.2, 0.5), (0.5, 1.0)]:
        mask = (lats_arr >= lo) & (lats_arr < hi)
        if np.sum(mask) > 5:
            avg_wx = np.mean(wx[mask])
            avg_wy = np.mean(wy[mask])
            avg_ws = np.mean(ws[mask])
            avg_slp = np.mean(slp[mask])
            # 计算风向角度
            angle = np.degrees(np.arctan2(avg_wy, avg_wx))
            rpt(f"      [{lo:+.1f},{hi:+.1f}]: WS={avg_ws:.4f}, "
                f"Wdir={angle:+.1f}°, SLP={avg_slp:.4f}")

# ─── 纵向分析: 代表 cell 时间序列 ───
rpt("\n" + "─" * 50)
rpt("【F】纵向时间序列分析 (代表Cell)")
rpt("─" * 50)

# 输出 JSON 格式的详细数据用于后续绘图
ts_json = {}
for ci in cell_candidates:
    ts = time_series[ci]
    if len(ts.get('tick', [])) < 10:
        continue

    ticks_arr = np.array(ts['tick'])
    temps = np.array(ts['temp'], dtype=float)
    temps = temps[~np.isnan(temps)]
    sea_ice = np.array(ts['sea_ice'], dtype=float)
    sea_ice = sea_ice[~np.isnan(sea_ice)]
    insolation = np.array(ts['insolation'], dtype=float)
    insolation = insolation[~np.isnan(insolation)]
    weather = np.array(ts['weather'])
    weather = weather[weather != None]
    lat = np.array(ts['lat'], dtype=float)
    lat = lat[~np.isnan(lat)]
    is_water = np.array(ts['is_water'], dtype=float)
    is_water = is_water[~np.isnan(is_water)]
    elev = np.array(ts['elev'], dtype=float)
    elev = elev[~np.isnan(elev)]
    moisture = np.array(ts['moisture'], dtype=float)
    moisture = moisture[~np.isnan(moisture)]
    precip = np.array(ts['precip'], dtype=float)
    precip = precip[~np.isnan(precip)]

    avg_lat = np.mean(lat) if len(lat) > 0 else np.nan
    avg_is_water = np.mean(is_water) if len(is_water) > 0 else np.nan
    avg_elev = np.mean(elev) if len(elev) > 0 else np.nan

    water_label = "水体" if avg_is_water > 0.5 else "陆地"

    rpt(f"\n  Cell #{ci}: 纬度={avg_lat:+.3f}, {water_label}, 海拔={avg_elev:.2f}")

    if len(temps) > 0:
        rpt(f"    温度: mean={np.mean(temps):.2f}°C, std={np.std(temps):.2f}, "
            f"min={np.min(temps):.2f}, max={np.max(temps):.2f}, "
            f"range={np.max(temps)-np.min(temps):.2f}°C")
        # 季节性检测: 计算自相关
        if len(temps) > 50:
            temps_detrend = temps - np.convolve(temps, np.ones(30)/30, mode='same')[:len(temps)]
            autocorr = np.correlate(temps_detrend, temps_detrend, mode='full')
            autocorr = autocorr[len(autocorr)//2:]
            autocorr = autocorr / autocorr[0] if autocorr[0] != 0 else autocorr
            # 找第一个峰值 (周期)
            peaks = []
            for i in range(2, min(len(autocorr)//2, 500)):
                if autocorr[i] > autocorr[i-1] and autocorr[i] > autocorr[i+1] and autocorr[i] > 0.1:
                    peaks.append(i)
            if peaks:
                rpt(f"    周期性: 首峰在 lag={peaks[0]}ticks, 自相关={autocorr[peaks[0]]:.3f}")

    if len(sea_ice) > 0:
        rpt(f"    海冰: mean={np.mean(sea_ice):.4f}, max={np.max(sea_ice):.4f}, "
            f"nonzero_ratio={np.mean(sea_ice > 0.01):.1%}")

    if len(insolation) > 0 and len(temps) > 0:
        min_len = min(len(insolation), len(temps))
        if min_len > 10:
            corr = np.corrcoef(insolation[:min_len], temps[:min_len])[0, 1]
            rpt(f"    辐射-温度相关系数: {corr:.3f}")

    if len(precip) > 0:
        rpt(f"    降水: mean={np.mean(precip):.4f}, max={np.max(precip):.4f}")
        rpt(f"    moisture: mean={np.mean(moisture):.4f}" if len(moisture) > 0 else "    moisture: N/A")

    # 天气类型演变
    if len(weather) > 5:
        weather_types = [int(w) for w in weather if not np.isnan(float(w))]
        if weather_types:
            transitions = sum(1 for i in range(1, len(weather_types))
                            if weather_types[i] != weather_types[i-1])
            rpt(f"    天气类型数: {len(set(weather_types))}, "
                f"转换次数: {transitions}/{len(weather_types)-1}")

    # 保存到 JSON
    ts_json[f"cell_{ci}"] = {
        "lat": float(avg_lat),
        "is_water": bool(avg_is_water > 0.5),
        "elevation": float(avg_elev),
        "n_ticks": int(len(ticks_arr)),
        "temp": {"mean": float(np.mean(temps)), "std": float(np.std(temps)),
                 "min": float(np.min(temps)), "max": float(np.max(temps))}
        if len(temps) > 0 else None,
        "sea_ice": {"mean": float(np.mean(sea_ice)), "max": float(np.max(sea_ice))}
        if len(sea_ice) > 0 else None,
    }

# ─── 海冰-纬度分布 ───
rpt("\n" + "─" * 50)
rpt("【G】海冰-纬度分布 (横向分析)")
rpt("─" * 50)

for t in sample_ticks:
    sec = cross_sections[t]
    sea_ice = np.array([v for v in sec[COL_SEA_ICE] if not np.isnan(v) and np.isfinite(v)])
    lats_arr = np.array([v for v in sec[COL_LAT] if not np.isnan(v) and np.isfinite(v)])
    min_len = min(len(sea_ice), len(lats_arr))
    if min_len == 0:
        continue
    sea_ice, lats_arr = sea_ice[:min_len], lats_arr[:min_len]

    rpt(f"\n  Tick {t}:")
    for lo, hi in [(-1.0, -0.8), (-0.8, -0.5), (-0.5, -0.2), (-0.2, 0.2),
                   (0.2, 0.5), (0.5, 0.8), (0.8, 1.0)]:
        mask = (lats_arr >= lo) & (lats_arr < hi)
        if np.sum(mask) > 3:
            avg_ice = np.mean(sea_ice[mask])
            ice_ratio = np.mean(sea_ice[mask] > 0.01)
            rpt(f"    [{lo:+.1f},{hi:+.1f}): avg_ice={avg_ice:.4f}, "
                f"ice_fraction={ice_ratio:.1%}, n={np.sum(mask)}")

# ─── 综合评估 ───
rpt("\n" + "─" * 50)
rpt("【H】综合评估")
rpt("─" * 50)

# 温度合理性检查
all_temps = np.array([v for v in global_stats['temp'] if not np.isnan(v) and np.isfinite(v)])
all_sea_ice = np.array([v for v in global_stats['sea_ice'] if not np.isnan(v) and np.isfinite(v)])
all_insolation = np.array([v for v in global_stats['insolation'] if not np.isnan(v) and np.isfinite(v)])
all_wind = np.array([v for v in global_stats['wind_speed'] if not np.isnan(v) and np.isfinite(v)])

issues = []
warnings_list = []
oks = []

# 1. 温度范围
if len(all_temps) > 0:
    t_min, t_max = np.min(all_temps), np.max(all_temps)
    if t_min < -60:
        issues.append(f"温度过低: min={t_min:.1f}°C < -60°C")
    elif t_min < -50:
        warnings_list.append(f"温度偏低: min={t_min:.1f}°C")
    else:
        oks.append(f"温度范围合理: [{t_min:.1f}, {t_max:.1f}]°C")

    if t_max > 60:
        issues.append(f"温度过高: max={t_max:.1f}°C > 60°C")
    elif t_max > 50:
        warnings_list.append(f"温度偏高: max={t_max:.1f}°C")
    else:
        oks.append(f"最高温度合理: {t_max:.1f}°C")

# 2. 海冰检查
if len(all_sea_ice) > 0:
    ice_nonzero = np.mean(all_sea_ice > 0.01)
    if ice_nonzero > 0.5:
        issues.append(f"海冰覆盖过高: {ice_nonzero:.1%} cells有冰")
    elif ice_nonzero > 0.3:
        warnings_list.append(f"海冰覆盖偏高: {ice_nonzero:.1%} cells有冰")
    else:
        oks.append(f"海冰覆盖合理: {ice_nonzero:.1%}")

# 3. 赤道海冰检查
lat_temp_all = np.array(global_stats['lat_temp_pairs'])
if len(lat_temp_all) > 0:
    eq_mask = np.abs(lat_temp_all[:, 0]) < 0.2
    eq_temps = lat_temp_all[eq_mask, 1]
    if len(eq_temps) > 0:
        eq_avg = np.mean(eq_temps)
        if eq_avg < 10:
            issues.append(f"赤道温度过低: {eq_avg:.1f}°C")
        elif eq_avg < 15:
            warnings_list.append(f"赤道温度偏低: {eq_avg:.1f}°C")
        else:
            oks.append(f"赤道温度合理: {eq_avg:.1f}°C")

# 4. 太阳辐射检查
if len(all_insolation) > 0:
    insol_min, insol_max = np.min(all_insolation), np.max(all_insolation)
    if insol_max <= 0:
        issues.append(f"太阳辐射全为负值: max={insol_max:.4f}")
    oks.append(f"太阳辐射范围: [{insol_min:.4f}, {insol_max:.4f}]")

# 5. 风速检查
if len(all_wind) > 0:
    w_max = np.max(all_wind)
    if w_max > 100:
        issues.append(f"风速过高: max={w_max:.1f}")
    elif w_max > 80:
        warnings_list.append(f"风速偏高: max={w_max:.1f}")
    else:
        oks.append(f"风速合理: max={w_max:.1f}")

# 输出
if issues:
    rpt("\n  [ISSUE] 问题 (需修复):")
    for item in issues:
        rpt(f"    - {item}")

if warnings_list:
    rpt("\n  [WARNING] 警告 (需关注):")
    for item in warnings_list:
        rpt(f"    - {item}")

if oks:
    rpt("\n  [OK] 通过检查:")
    for item in oks:
        rpt(f"    - {item}")

if not issues and not warnings_list:
    rpt("\n  [PASS] 所有检查通过! 气候模拟运行正常。")

# ─── 保存 ───
rpt("\n" + "─" * 50)
rpt("【输出】")
rpt("─" * 50)

# 保存文本报告
report_path = os.path.join(OUT_DIR, "climate_analysis_report.txt")
with open(report_path, 'w', encoding='utf-8') as f:
    f.write('\n'.join(report_lines))
rpt(f"  文本报告: {report_path}")

# 保存 JSON 数据
json_path = os.path.join(OUT_DIR, "time_series_data.json")
with open(json_path, 'w', encoding='utf-8') as f:
    json.dump(ts_json, f, indent=2, ensure_ascii=False)
rpt(f"  时序数据: {json_path}")

print("\n分析完成!")
print(f"\n完整报告请查看: {report_path}")
