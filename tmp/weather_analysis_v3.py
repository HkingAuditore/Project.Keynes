#!/usr/bin/env python3
"""
Comprehensive weather/climate simulation analysis v3.
Data format: tick-major, each row = 1 cell at 1 tick, 6400 cells/tick.
All _arr columns are scalars per cell per tick.
"""

import pandas as pd
import numpy as np
from collections import Counter, defaultdict
import warnings
warnings.filterwarnings('ignore')

CSV = r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260622_145049.csv'
N_CELLS = 6400
SIDE = int(np.sqrt(N_CELLS))  # should be 80
CHUNK_TICKS = 10  # read 10 ticks at a time
CHUNK_SIZE = N_CELLS * CHUNK_TICKS

print("=" * 70)
print(" 天气/气候模拟数据分析报告 v2")
print(" 文件: tile_data_record_20260622_145049.csv")
print("=" * 70)

# ── Columns to read ──
USE_COLS = [
    'row_idx','tick_idx','phys_sim_day',
    'weather_type_arr','weather_prev_type_arr','weather_target_type_arr',
    'temp_arr','temp_arr_prev','temp_baseline_arr','temp_30d_arr','temp_365d_arr','temp_anomaly_arr',
    'weather_precip_arr','weather_intensity_arr','weather_cloud_arr',
    'weather_cloud_water_arr','weather_vapor_arr',
    'weather_convergence_arr','weather_instability_arr',
    'weather_transition_alpha_arr','weather_classification_temp_arr','weather_classification_moisture_arr',
    'moisture_arr','moisture_arr_prev','soil_moisture_arr','base_moisture_arr',
    'snow_cover_arr','snow_cover_arr_prev','snowpack_arr',
    'sea_ice_frac_arr','sea_ice_frac_arr_prev',
    'vegetation_vitality_arr','vegetation_growth_pressure_arr',
    'vegetation_heat_stress_arr','vegetation_drought_stress_arr','vegetation_cold_stress_arr',
    'vegetation_regen_score_arr','vegetation_arr','base_vegetation_arr',
    'terrain_arr','base_terrain_arr',
    'wind_x_arr','wind_y_arr','wind_speed_arr','wind_stress_curl_arr',
    'heat_input_arr','temperature_transport_anomaly_arr','air_mass_temp_anomaly_arr',
    'weather_dirty_mask','climate_dirty_mask'
]
USE_COLS = list(dict.fromkeys(USE_COLS))

WEATHER_MAP = {0:'CLEAR',1:'RAIN',2:'STORM',3:'BLIZZARD',4:'DROUGHT',5:'FOG',6:'HEATWAVE',7:'MONSOON'}

# ── Pass 1: weather type distribution + basic stats ──
print("\n[1] 第一遍: 天气类型分布 & 基本统计...")
weather_counter = Counter()
all_ticks = []
per_tick_stats = defaultdict(list)  # tick -> {metric: value}

chunk_iter = pd.read_csv(CSV, chunksize=CHUNK_SIZE, usecols=USE_COLS)

for ci, chunk in enumerate(chunk_iter):
    # Weather type count
    wt = chunk['weather_type_arr'].dropna().astype(int)
    weather_counter.update(wt)
    
    # Per-tick stats
    for tick, grp in chunk.groupby('tick_idx'):
        all_ticks.append(tick)
        per_tick_stats['tick'].append(tick)
        for col in ['weather_precip_arr','temp_arr','weather_target_mismatch_count',
                     'weather_transitioning_count','weather_transition_alpha_mean',
                     'weather_transition_alpha_p95']:
            if col in grp.columns:
                v = grp[col].mean()
                per_tick_stats[col].append(v if pd.notna(v) else np.nan)
    
    if ci % 10 == 0:
        print(f"  已处理 {ci*CHUNK_TICKS} ticks...", end='\r')

all_ticks = sorted(set(all_ticks))
n_ticks = len(all_ticks)
print(f"\n  完成: {n_ticks} ticks, {n_ticks*N_CELLS:,} 行")
print(f"  tick 范围: {all_ticks[0]} ~ {all_ticks[-1]}")

print("\n  天气类型分布:")
total = sum(weather_counter.values())
for code, name in sorted(WEATHER_MAP.items()):
    cnt = weather_counter.get(code, 0)
    pct = cnt/total*100
    print(f"    {name:12s}: {cnt:>10,}  ({pct:6.2f}%)")
print()

# ── Pass 2: cell-level accumulation for perpetual regions ──
print("[2] 第二遍: Cell 级别累积统计...")

# Accumulators per cell (0..6399)
cell_precip_sum = np.zeros(N_CELLS, dtype=np.float64)
cell_precip_count = np.zeros(N_CELLS, dtype=np.int32)
cell_wet_count = np.zeros(N_CELLS, dtype=np.int32)  # precip > 0.02
cell_dry_count = np.zeros(N_CELLS, dtype=np.int32)   # precip == 0 or near zero
cell_temp_sum = np.zeros(N_CELLS, dtype=np.float64)
cell_temp_count = np.zeros(N_CELLS, dtype=np.int32)
cell_snow_sum = np.zeros(N_CELLS, dtype=np.float64)
cell_ice_sum = np.zeros(N_CELLS, dtype=np.float64)
cell_soil_sum = np.zeros(N_CELLS, dtype=np.float64)
cell_veg_sum = np.zeros(N_CELLS, dtype=np.float64)
cell_terrain_mode = np.zeros(N_CELLS)  # will track terrain
cell_veg_vital_sum = np.zeros(N_CELLS, dtype=np.float64)
cell_vg_pressure_sum = np.zeros(N_CELLS, dtype=np.float64)
cell_heat_stress_sum = np.zeros(N_CELLS, dtype=np.float64)
cell_drought_stress_sum = np.zeros(N_CELLS, dtype=np.float64)
cell_cold_stress_sum = np.zeros(N_CELLS, dtype=np.float64)
cell_wind_x_sum = np.zeros(N_CELLS, dtype=np.float64)
cell_wind_y_sum = np.zeros(N_CELLS, dtype=np.float64)
cell_wind_speed_sum = np.zeros(N_CELLS, dtype=np.float64)
cell_curl_sum = np.zeros(N_CELLS, dtype=np.float64)
cell_instab_sum = np.zeros(N_CELLS, dtype=np.float64)
cell_conv_sum = np.zeros(N_CELLS, dtype=np.float64)

# Per-cell weather type histogram
cell_weather_hist = {code: np.zeros(N_CELLS, dtype=np.int32) for code in WEATHER_MAP}

# Tick-level time series for mobility analysis
tick_wet_masks = []  # list of (tick_idx, wet_mask array of 6400 bools)
tick_type_masks = []  # list of (tick_idx, type array of 6400 ints)

PRECIP_THRESH = 0.02

chunk_iter = pd.read_csv(CSV, chunksize=CHUNK_SIZE, usecols=USE_COLS)
for ci, chunk in enumerate(chunk_iter):
    # Row indices within chunk map to cell positions
    # Since data is tick-major, rows within same tick map 0..6399
    for tick, grp in chunk.groupby('tick_idx'):
        # Sort by row_idx to ensure cell ordering
        grp = grp.sort_values('row_idx')
        n = len(grp)
        cell_idx = np.arange(n)
        
        # Accumulate
        for col, sum_arr, count_arr in [
            ('weather_precip_arr', cell_precip_sum, cell_precip_count),
            ('temp_arr', cell_temp_sum, cell_temp_count),
            ('snow_cover_arr', cell_snow_sum, None),
            ('sea_ice_frac_arr', cell_ice_sum, None),
            ('soil_moisture_arr', cell_soil_sum, None),
            ('vegetation_vitality_arr', cell_veg_vital_sum, None),
            ('vegetation_growth_pressure_arr', cell_vg_pressure_sum, None),
            ('vegetation_heat_stress_arr', cell_heat_stress_sum, None),
            ('vegetation_drought_stress_arr', cell_drought_stress_sum, None),
            ('vegetation_cold_stress_arr', cell_cold_stress_sum, None),
            ('wind_x_arr', cell_wind_x_sum, None),
            ('wind_y_arr', cell_wind_y_sum, None),
            ('wind_speed_arr', cell_wind_speed_sum, None),
            ('wind_stress_curl_arr', cell_curl_sum, None),
            ('weather_instability_arr', cell_instab_sum, None),
            ('weather_convergence_arr', cell_conv_sum, None),
        ]:
            if col in grp.columns:
                vals = grp[col].values[:n]
                mask = ~pd.isna(vals)
                if count_arr is not None:
                    count_arr[cell_idx[mask]] += 1
                sum_arr[cell_idx[mask]] += vals[mask].astype(float)
        
        # Wet/dry counts
        if 'weather_precip_arr' in grp.columns:
            precip_vals = grp['weather_precip_arr'].values[:n]
            wet_mask = precip_vals > PRECIP_THRESH
            cell_wet_count[cell_idx] += wet_mask.astype(int)
            cell_dry_count[cell_idx] += (~wet_mask).astype(int)
            
            # Save for mobility analysis (sample every N ticks to save memory)
            if len(tick_wet_masks) < 100 or ci % 5 == 0:
                tick_wet_masks.append((tick, wet_mask.copy()))
                if 'weather_type_arr' in grp.columns:
                    tick_type_masks.append((tick, grp['weather_type_arr'].values[:n].astype(int).copy()))
        
        # Weather histogram
        if 'weather_type_arr' in grp.columns:
            wt_vals = grp['weather_type_arr'].values[:n]
            for code in WEATHER_MAP:
                cell_weather_hist[code][cell_idx] += (wt_vals == code).astype(int)
        
        # Terrain (first valid value)
        if 'terrain_arr' in grp.columns and cell_terrain_mode.sum() == 0:
            tv = grp['terrain_arr'].values[:n]
            cell_terrain_mode = tv
    
    if ci % 10 == 0:
        print(f"  已处理 {ci*CHUNK_TICKS} ticks...", end='\r')

print(f"\n  完成: {n_ticks} ticks 的 cell 累积")
print()

# ── Analysis ──

print("[3] 永雨区 / 永旱区分析")
obs_per_cell = n_ticks  # each cell observed n_ticks times
wet_ratio = cell_wet_count / obs_per_cell

all_wet = (wet_ratio >= 1.0).sum()
very_wet = (wet_ratio > 0.8).sum()
all_dry = (wet_ratio <= 0.0).sum()
very_dry = (wet_ratio < 0.05).sum()

print(f"  降水阈值: >{PRECIP_THRESH}")
print(f"  全期湿润 (100%): {all_wet} ({all_wet/N_CELLS*100:.2f}%)")
print(f"  准永雨 (>80%):   {very_wet} ({very_wet/N_CELLS*100:.2f}%)")
print(f"  全期干燥 (0%):   {all_dry} ({all_dry/N_CELLS*100:.2f}%)")
print(f"  准永旱 (<5%):    {very_dry} ({very_dry/N_CELLS*100:.2f}%)")

# Terrain analysis
terrain_vals = cell_terrain_mode
land_mask = terrain_vals > 0.5
n_land = land_mask.sum()
n_water = N_CELLS - n_land
print(f"\n  陆地 cell: {n_land}, 水域 cell: {n_water}")
if n_land > 0:
    print(f"  陆地永旱 (<5%): {(wet_ratio[land_mask] < 0.05).sum()} ({((wet_ratio[land_mask] < 0.05).sum()/n_land)*100:.2f}%)")
    print(f"  陆地永雨 (>80%): {(wet_ratio[land_mask] > 0.8).sum()} ({((wet_ratio[land_mask] > 0.8).sum()/n_land)*100:.2f}%)")
print()

# ── Temperature latitudinal gradient ──
print("[4] 温度纬向梯度")

temp_mean = cell_temp_sum / np.maximum(cell_temp_count, 1)
temp_2d = temp_mean.reshape(SIDE, SIDE)
lat_profile = np.nanmean(temp_2d, axis=1)

equator_band = lat_profile[SIDE//2-3:SIDE//2+3]
pole_north = lat_profile[:3]
pole_south = lat_profile[-3:]

print(f"  网格: {SIDE}x{SIDE}")
print(f"  赤道带 (行{SIDE//2-3}~{SIDE//2+2}): mean={equator_band.mean():.4f}, range=[{equator_band.min():.4f}, {equator_band.max():.4f}]")
print(f"  北极带 (行0~2): mean={pole_north.mean():.4f}")
print(f"  南极带 (行{SIDE-3}~{SIDE-1}): mean={pole_south.mean():.4f}")

# Correlation with absolute latitude
abs_lat = np.abs(np.arange(SIDE) - SIDE//2)
lat_rep = np.repeat(abs_lat, SIDE)
valid = ~np.isnan(temp_mean) & (cell_temp_count > 0)
corr_temp_lat = np.corrcoef(lat_rep[valid], temp_mean[valid])[0,1]
print(f"  温度-绝对纬度相关: {corr_temp_lat:.4f}")

# Precipitation by latitude band
precip_mean = cell_precip_sum / np.maximum(cell_precip_count, 1)
precip_2d = precip_mean.reshape(SIDE, SIDE)
precip_lat = np.nanmean(precip_2d, axis=1)

print(f"\n  各纬度带降水分布:")
for i in range(0, SIDE, SIDE//10):
    lat_label = f"行{i}-{min(i+SIDE//10-1,SIDE-1)}"
    band = precip_lat[i:min(i+SIDE//10, SIDE)]
    wband = precip_2d[i:min(i+SIDE//10, SIDE), :]
    wet_ratio_band = (wband > PRECIP_THRESH).sum() / wband.size * 100
    print(f"    {lat_label:20s}: precip={band.mean():.4f}, wet_cell={wet_ratio_band:.1f}%")
print()

# ── Snow/Ice ──
print("[5] 冰雪分布")
snow_mean = cell_snow_sum / n_ticks
ice_mean = cell_ice_sum / n_ticks

valid_s = ~np.isnan(snow_mean) & (cell_temp_count > 0)
corr_snow_temp = np.corrcoef(snow_mean[valid_s], temp_mean[valid_s])[0,1]
valid_i = ~np.isnan(ice_mean) & (cell_temp_count > 0)
corr_ice_temp = np.corrcoef(ice_mean[valid_i], temp_mean[valid_i])[0,1]

print(f"  雪盖: mean={np.nanmean(snow_mean):.4f}, max={np.nanmax(snow_mean):.4f}")
print(f"  海冰: mean={np.nanmean(ice_mean):.4f}, max={np.nanmax(ice_mean):.4f}")
print(f"  雪盖-温度相关: {corr_snow_temp:.4f}")
print(f"  海冰-温度相关: {corr_ice_temp:.4f}")

snow_2d = snow_mean.reshape(SIDE, SIDE)
ice_2d = ice_mean.reshape(SIDE, SIDE)
print(f"  北极行平均雪盖: {np.nanmean(snow_2d[:3]):.4f}")
print(f"  北极行平均海冰: {np.nanmean(ice_2d[:3]):.4f}")
print(f"  南极行平均雪盖: {np.nanmean(snow_2d[-3:]):.4f}")
print(f"  南极行平均海冰: {np.nanmean(ice_2d[-3:]):.4f}")
print(f"  赤道行平均雪盖: {np.nanmean(snow_2d[SIDE//2-3:SIDE//2+3]):.4f}")
print()

# ── Weather mobility ──
print("[6] 天气移动性分析")
# Sort tick masks by tick_idx
tick_wet_masks.sort(key=lambda x: x[0])
tick_type_masks.sort(key=lambda x: x[0])

wet_jaccards = []
type_change_rates = []
for i in range(len(tick_wet_masks) - 1):
    t1, wm1 = tick_wet_masks[i]
    t2, wm2 = tick_wet_masks[i+1]
    wm1 = wm1[:N_CELLS]
    wm2 = wm2[:N_CELLS]
    inter = (wm1 & wm2).sum()
    union = (wm1 | wm2).sum()
    jac = inter / union if union > 0 else 1.0
    wet_jaccards.append(jac)

for i in range(len(tick_type_masks) - 1):
    t1, tm1 = tick_type_masks[i]
    t2, tm2 = tick_type_masks[i+1]
    tm1 = tm1[:N_CELLS]
    tm2 = tm2[:N_CELLS]
    changed = (tm1 != tm2).sum()
    type_change_rates.append(changed / N_CELLS)

if wet_jaccards:
    wj = np.array(wet_jaccards)
    print(f"  湿润区 Jaccard (相邻tick): mean={wj.mean():.4f}, median={np.median(wj):.4f}")
    print(f"    p5={np.percentile(wj,5):.4f}, p95={np.percentile(wj,95):.4f}, min={wj.min():.4f}")
    frozen = (wj == 1.0).sum()
    print(f"    完全不变对: {frozen}/{len(wj)} ({frozen/len(wj)*100:.1f}%)")

if type_change_rates:
    tcr = np.array(type_change_rates)
    print(f"  天气类型变化率: mean={tcr.mean():.4f}, median={np.median(tcr):.4f}")
    print(f"    p5={np.percentile(tcr,5):.4f}, p95={np.percentile(tcr,95):.4f}")
    frozen_t = (tcr == 0).sum()
    print(f"    完全无变化对: {frozen_t}/{len(tcr)} ({frozen_t/len(tcr)*100:.1f}%)")
print()

# ── Frontal analysis on last frame ──
print("[7] 锋面特征分析")

# Read last full tick
last_tick_chunks = []
chunk_iter = pd.read_csv(CSV, chunksize=CHUNK_SIZE, usecols=USE_COLS)
last_tick = all_ticks[-1]
for chunk in chunk_iter:
    lt_chunk = chunk[chunk['tick_idx'] == last_tick]
    if len(lt_chunk) > 0:
        last_tick_chunks.append(lt_chunk)

if last_tick_chunks:
    last_frame = pd.concat(last_tick_chunks).sort_values('row_idx')
    
    wt_2d = last_frame['weather_type_arr'].values[:N_CELLS].reshape(SIDE, SIDE)
    temp_2d = last_frame['temp_arr'].values[:N_CELLS].reshape(SIDE, SIDE)
    
    # Type boundaries (4-connected)
    wt_h = (wt_2d[:, :-1] != wt_2d[:, 1:]).sum()
    wt_v = (wt_2d[:-1, :] != wt_2d[1:, :]).sum()
    total_edges = SIDE*(SIDE-1)*2
    boundary_ratio = (wt_h+wt_v)/total_edges
    print(f"  天气类型边界: {wt_h+wt_v}/{total_edges} = {boundary_ratio:.4f}")
    
    # Temperature gradients
    temp_h = np.abs(temp_2d[:, :-1] - temp_2d[:, 1:])
    temp_v = np.abs(temp_2d[:-1, :] - temp_2d[1:, :])
    all_diffs = np.concatenate([temp_h.flatten(), temp_v.flatten()])
    all_diffs = all_diffs[~np.isnan(all_diffs)]
    print(f"  邻格温度梯度: p50={np.median(all_diffs):.4f}, p95={np.percentile(all_diffs,95):.4f}, p99={np.percentile(all_diffs,99):.4f}")
    
    # Wind field in last frame
    if 'wind_x_arr' in last_frame.columns:
        wx_2d = last_frame['wind_x_arr'].values[:N_CELLS].reshape(SIDE, SIDE)
        wy_2d = last_frame['wind_y_arr'].values[:N_CELLS].reshape(SIDE, SIDE)
        ws_2d = np.sqrt(wx_2d**2 + wy_2d**2)
        
        ws_h = np.abs(ws_2d[:, :-1] - ws_2d[:, 1:])
        ws_v = np.abs(ws_2d[:-1, :] - ws_2d[1:, :])
        all_ws = np.concatenate([ws_h.flatten(), ws_v.flatten()])
        all_ws = all_ws[~np.isnan(all_ws)]
        print(f"  风切变 (邻格): p95={np.percentile(all_ws,95):.4f}, p99={np.percentile(all_ws,99):.4f}")
    
    # Convergence
    if 'weather_convergence_arr' in last_frame.columns:
        conv_2d = last_frame['weather_convergence_arr'].values[:N_CELLS].reshape(SIDE, SIDE)
        conv_mean = np.nanmean(np.abs(conv_2d))
        print(f"  辐合场 |mean|: {conv_mean:.4f}")
        
        # Front-like: high temp gradient + high convergence
        temp_hi = all_diffs > np.percentile(all_diffs, 85)
        conv_hvals = np.abs(conv_2d[:, :-1] + conv_2d[:, 1:]) / 2
        conv_vvals = np.abs(conv_2d[:-1, :] + conv_2d[1:, :]) / 2
        all_conv = np.concatenate([conv_hvals.flatten(), conv_vvals.flatten()])
        conv_hi = all_conv > np.percentile(all_conv, 85)
        front_like = (temp_hi & conv_hi).sum()
        print(f"  类锋面边界 (高温度梯度+高辐合): {front_like}/{len(temp_hi)} ({front_like/len(temp_hi)*100:.2f}%)")
    
    # Instability (convective potential)
    if 'weather_instability_arr' in last_frame.columns:
        instab_2d = last_frame['weather_instability_arr'].values[:N_CELLS].reshape(SIDE, SIDE)
        print(f"  不稳定度: mean={np.nanmean(instab_2d):.4f}, p95={np.nanpercentile(instab_2d,95):.4f}, max={np.nanmax(instab_2d):.4f}")
print()

# ── Weather ←→ Soil / Vegetation ──
print("[8] 天气对土壤/植被的影响")
soil_mean = cell_soil_sum / n_ticks
veg_v_mean = cell_veg_vital_sum / n_ticks
precip_mean_all = cell_precip_sum / np.maximum(cell_precip_count, 1)

valid_ps = ~np.isnan(precip_mean_all) & ~np.isnan(soil_mean) & (cell_precip_count > 0)
if valid_ps.sum() > 1:
    corr_ps = np.corrcoef(precip_mean_all[valid_ps], soil_mean[valid_ps])[0,1]
    print(f"  降水-土壤湿度相关: {corr_ps:.4f}")

valid_sv = ~np.isnan(soil_mean) & ~np.isnan(veg_v_mean)
if valid_sv.sum() > 1:
    corr_sv = np.corrcoef(soil_mean[valid_sv], veg_v_mean[valid_sv])[0,1]
    print(f"  土壤湿度-植被活力相关: {corr_sv:.4f}")

valid_pv = ~np.isnan(precip_mean_all) & ~np.isnan(veg_v_mean) & (cell_precip_count > 0)
if valid_pv.sum() > 1:
    corr_pv = np.corrcoef(precip_mean_all[valid_pv], veg_v_mean[valid_pv])[0,1]
    print(f"  降水-植被活力直接相关: {corr_pv:.4f}")

vgp_mean = cell_vg_pressure_sum / n_ticks
hs_mean = cell_heat_stress_sum / n_ticks
ds_mean = cell_drought_stress_sum / n_ticks
cs_mean = cell_cold_stress_sum / n_ticks

valid_gp = ~np.isnan(precip_mean_all) & ~np.isnan(vgp_mean) & (cell_precip_count > 0)
if valid_gp.sum() > 1:
    corr_gp = np.corrcoef(precip_mean_all[valid_gp], vgp_mean[valid_gp])[0,1]
    print(f"  降水-生长压力相关: {corr_gp:.4f}")

valid_ds = ~np.isnan(precip_mean_all) & ~np.isnan(ds_mean) & (cell_precip_count > 0)
if valid_ds.sum() > 1:
    corr_ds = np.corrcoef(precip_mean_all[valid_ds], ds_mean[valid_ds])[0,1]
    print(f"  降水-干旱应力相关: {corr_ds:.4f}")

print(f"\n  植被活力分布: mean={veg_v_mean.mean():.4f}, med={np.median(veg_v_mean):.4f}, p25={np.percentile(veg_v_mean,25):.4f}, p75={np.percentile(veg_v_mean,75):.4f}")
print(f"  植被活力==0比例: {(veg_v_mean==0).sum()/N_CELLS*100:.1f}%")
print(f"  生长压力: mean={np.nanmean(vgp_mean):.4f}, p95={np.nanpercentile(vgp_mean,95):.4f}")
print(f"  热应力: mean={np.nanmean(hs_mean):.4f}, p95={np.nanpercentile(hs_mean,95):.4f}")
print(f"  干旱应力: mean={np.nanmean(ds_mean):.4f}, p95={np.nanpercentile(ds_mean,95):.4f}")
print(f"  冷应力: mean={np.nanmean(cs_mean):.4f}, p95={np.nanpercentile(cs_mean,95):.4f}")
print()

# ── Wind field ──
print("[9] 风场分析")
ws_mean = cell_wind_speed_sum / n_ticks
wx_mean = cell_wind_x_sum / n_ticks
wy_mean = cell_wind_y_sum / n_ticks
curl_mean = cell_curl_sum / n_ticks

ws_valid = ws_mean[~np.isnan(ws_mean)]
print(f"  风速: mean={ws_valid.mean():.4f}, med={np.median(ws_valid):.4f}, p95={np.percentile(ws_valid,95):.4f}, p99={np.percentile(ws_valid,99):.4f}")

wx_valid = wx_mean[~np.isnan(wx_mean)]
wy_valid = wy_mean[~np.isnan(wy_mean)]
print(f"  风x分量: mean={wx_valid.mean():.4f}, std={wx_valid.std():.4f}")
print(f"  风y分量: mean={wy_valid.mean():.4f}, std={wy_valid.std():.4f}")

# Wind direction by latitude band (check trade winds/westerlies)
wx_2d = wx_mean.reshape(SIDE, SIDE)
wy_2d = wy_mean.reshape(SIDE, SIDE)
print(f"\n  各纬度带平均风向:")
for i in range(0, SIDE, SIDE//8):
    end_i = min(i+SIDE//8, SIDE)
    wx_band = np.nanmean(wx_2d[i:end_i, :])
    wy_band = np.nanmean(wy_2d[i:end_i, :])
    direction = np.arctan2(wy_band, wx_band) * 180 / np.pi
    speed = np.sqrt(wx_band**2 + wy_band**2)
    print(f"    行{i:2d}-{end_i-1:2d}: dir={direction:7.1f}°, speed={speed:.4f}")

curl_valid = curl_mean[~np.isnan(curl_mean)]
print(f"\n  风应力旋度: mean={curl_valid.mean():.6f}, std={curl_valid.std():.4f}")
print(f"    p95={np.percentile(curl_valid,95):.4f}, p99={np.percentile(curl_valid,99):.4f}")
cyclone_regions = (curl_valid > 0.5).sum()
print(f"  气旋性区域 (旋度>0.5): {cyclone_regions}/{len(curl_valid)} ({cyclone_regions/len(curl_valid)*100:.2f}%)")
print()

# ── Per-weather-type metrics ──
print("[10] 各天气类型平均气象指标")

# We need to compute this per chunk and accumulate
type_accum = {code: {'precip':[],'temp':[],'cloud_w':[],'vapor':[],
                      'instab':[],'wind':[],'snow':[],'intensity':[],
                      'soil':[],'veg':[]} for code in WEATHER_MAP}

chunk_iter = pd.read_csv(CSV, chunksize=CHUNK_SIZE, usecols=USE_COLS)
for chunk in chunk_iter:
    wt = chunk['weather_type_arr'].values
    valid_wt = ~pd.isna(wt)
    if valid_wt.sum() == 0:
        continue
    wt_int = wt[valid_wt].astype(int)
    
    for code in WEATHER_MAP:
        mask = wt_int == code
        if mask.sum() == 0:
            continue
        idx = np.where(valid_wt)[0][mask]
        d = type_accum[code]
        
        field_map = {
            'precip': 'weather_precip_arr', 'temp': 'temp_arr',
            'cloud_w': 'weather_cloud_water_arr', 'vapor': 'weather_vapor_arr',
            'instab': 'weather_instability_arr', 'wind': 'wind_speed_arr',
            'snow': 'snow_cover_arr', 'intensity': 'weather_intensity_arr',
            'soil': 'soil_moisture_arr', 'veg': 'vegetation_vitality_arr'
        }
        for key, fname in field_map.items():
            if fname in chunk.columns:
                vals = chunk[fname].values[idx]
                d[key].extend(vals[~pd.isna(vals)].tolist())

print(f"  {'Weather':12s} {'Precip':>8s} {'Temp':>8s} {'CloudW':>8s} {'Vapor':>8s} {'Instab':>8s} {'Wind':>8s} {'Snow':>8s} {'Intens':>8s}")
print(f"  {'-'*12} {'-'*8} {'-'*8} {'-'*8} {'-'*8} {'-'*8} {'-'*8} {'-'*8} {'-'*8}")
for code, name in sorted(WEATHER_MAP.items()):
    d = type_accum[code]
    vals = []
    for k in ['precip','temp','cloud_w','vapor','instab','wind','snow','intensity']:
        arr = np.array(d[k])
        vals.append(f"{arr.mean():8.4f}" if len(arr)>0 else f"{'N/A':>8}")
    print(f"  {name:12s} {vals[0]} {vals[1]} {vals[2]} {vals[3]} {vals[4]} {vals[5]} {vals[6]} {vals[7]}")
print()

# ── Anomaly detection ──
print("[11] 异常检测")
# HEATWAVE land/water
hw_land_total = 0
hw_water_total = 0
drought_land_total = 0
land_obs = 0
water_obs = 0
drought_precips = []
hw_precips = []
fog_vapors = []

chunk_iter = pd.read_csv(CSV, chunksize=CHUNK_SIZE, usecols=USE_COLS)
for chunk in chunk_iter:
    wt = chunk['weather_type_arr'].values
    terrain = chunk['terrain_arr'].values
    precip = chunk['weather_precip_arr'].values
    vapor = chunk['weather_vapor_arr'].values
    
    valid = ~pd.isna(wt) & ~pd.isna(terrain)
    wt_v = wt[valid].astype(int)
    ter_v = terrain[valid]
    
    land = ter_v > 0.5
    water = ~land
    
    hw_land_total += ((wt_v == 6) & land).sum()
    hw_water_total += ((wt_v == 6) & water).sum()
    drought_land_total += ((wt_v == 4) & land).sum()
    land_obs += land.sum()
    water_obs += water.sum()
    
    # DROUGHT/HEATWAVE precip
    if pd.notna(precip).any():
        d_mask = wt_v == 4
        if d_mask.sum() > 0:
            dp = precip[valid][d_mask]
            drought_precips.extend(dp[~pd.isna(dp)].tolist())
        hw_mask = wt_v == 6
        if hw_mask.sum() > 0:
            hp = precip[valid][hw_mask]
            hw_precips.extend(hp[~pd.isna(hp)].tolist())
    
    # FOG vapor
    fog_mask = wt_v == 5
    if fog_mask.sum() > 0 and pd.notna(vapor).any():
        fv = vapor[valid][fog_mask]
        fog_vapors.extend(fv[~pd.isna(fv)].tolist())

print(f"  HEATWAVE: 陆地={hw_land_total} ({hw_land_total/land_obs*100:.4f}% of land obs), 水域={hw_water_total} ({hw_water_total/water_obs*100:.4f}% of water obs)" if water_obs > 0 else f"  HEATWAVE: land={hw_land_total}")
print(f"  DROUGHT: 陆地={drought_land_total} ({drought_land_total/land_obs*100:.4f}% of land obs)")

dp_arr = np.array(drought_precips)
hp_arr = np.array(hw_precips)
print(f"  DROUGHT 平均降水: {dp_arr.mean():.4f}" if len(dp_arr)>0 else "  DROUGHT 平均降水: N/A")
print(f"  HEATWAVE 平均降水: {hp_arr.mean():.4f}" if len(hp_arr)>0 else "  HEATWAVE 平均降水: N/A")
print(f"  FOG 平均水汽: {np.array(fog_vapors).mean():.4f}" if fog_vapors else "  FOG 平均水汽: N/A")

# STORM characteristics
storm_precips = []
storm_winds = []
storm_instabs = []
chunk_iter = pd.read_csv(CSV, chunksize=CHUNK_SIZE, usecols=USE_COLS)
for chunk in chunk_iter:
    wt = chunk['weather_type_arr'].values
    valid = ~pd.isna(wt)
    storm_mask = wt[valid].astype(int) == 2
    if storm_mask.sum() == 0:
        continue
    idx = np.where(valid)[0][storm_mask]
    for fname, lst in [('weather_precip_arr',storm_precips),('wind_speed_arr',storm_winds),('weather_instability_arr',storm_instabs)]:
        if fname in chunk.columns:
            vals = chunk[fname].values[idx]
            lst.extend(vals[~pd.isna(vals)].tolist())

sp = np.array(storm_precips) if storm_precips else np.array([])
sw = np.array(storm_winds) if storm_winds else np.array([])
si = np.array(storm_instabs) if storm_instabs else np.array([])
print(f"\n  STORM (台风特征):")
print(f"    平均降水: {sp.mean():.4f}" if len(sp)>0 else "    N/A")
print(f"    平均风速: {sw.mean():.4f}" if len(sw)>0 else "    N/A")
print(f"    平均不稳定度: {si.mean():.4f}" if len(si)>0 else "    N/A")

# STORM cluster size in last frame
if last_tick_chunks:
    last_frame = pd.concat(last_tick_chunks).sort_values('row_idx')
    storm_mask_2d = (last_frame['weather_type_arr'].values[:N_CELLS] == 2).reshape(SIDE, SIDE)
    storm_cells = storm_mask_2d.sum()
    print(f"    最后一帧 STORM cell 数: {storm_cells}")
print()

# ── Temporal analysis ──
print("[12] 时间变化与日际差")
# Type transitions between consecutive full ticks
# Read all ticks and compute daily changes
weather_types_by_tick = {}
chunk_iter = pd.read_csv(CSV, chunksize=CHUNK_SIZE, usecols=['row_idx','tick_idx','weather_type_arr','weather_prev_type_arr'])
for chunk in chunk_iter:
    for tick, grp in chunk.groupby('tick_idx'):
        if tick not in weather_types_by_tick:
            grp_sorted = grp.sort_values('row_idx')
            weather_types_by_tick[tick] = grp_sorted['weather_type_arr'].values[:N_CELLS].astype(int)

sorted_ticks = sorted(weather_types_by_tick.keys())
if len(sorted_ticks) > 1:
    transitions_per_tick = []
    type_diversity = []
    for tick in sorted_ticks:
        wt = weather_types_by_tick[tick]
        unique_types = len(np.unique(wt))
        type_diversity.append(unique_types)
    
    for i in range(len(sorted_ticks)-1):
        t1, t2 = sorted_ticks[i], sorted_ticks[i+1]
        changed = (weather_types_by_tick[t1] != weather_types_by_tick[t2]).sum()
        transitions_per_tick.append(changed)
    
    tr = np.array(transitions_per_tick)
    td = np.array(type_diversity)
    print(f"  每 tick 活跃天气种类: mean={td.mean():.1f}, min={td.min()}, max={td.max()}")
    print(f"  相邻 tick 天气转变 cell 数: mean={tr.mean():.1f}, med={np.median(tr):.1f}")
    print(f"    p5={np.percentile(tr,5):.0f}, p95={np.percentile(tr,95):.0f}, min={tr.min()}, max={tr.max()}")
    frozen = (tr == 0).sum()
    print(f"    完全无转变对: {frozen}/{len(tr)} ({frozen/len(tr)*100:.1f}%)")
print()

# ── MONSOON analysis ──
print("[13] 季风特征")
monsoon_precips = []
monsoon_winds = []
chunk_iter = pd.read_csv(CSV, chunksize=CHUNK_SIZE, usecols=USE_COLS)
for chunk in chunk_iter:
    wt = chunk['weather_type_arr'].values
    valid = ~pd.isna(wt)
    monsoon_mask = wt[valid].astype(int) == 7
    if monsoon_mask.sum() == 0:
        continue
    idx = np.where(valid)[0][monsoon_mask]
    if 'weather_precip_arr' in chunk.columns:
        vals = chunk['weather_precip_arr'].values[idx]
        monsoon_precips.extend(vals[~pd.isna(vals)].tolist())
    if 'wind_speed_arr' in chunk.columns:
        vals = chunk['wind_speed_arr'].values[idx]
        monsoon_winds.extend(vals[~pd.isna(vals)].tolist())

mp = np.array(monsoon_precips) if monsoon_precips else np.array([])
mw = np.array(monsoon_winds) if monsoon_winds else np.array([])
print(f"  MONSOON 平均降水: {mp.mean():.4f}" if len(mp)>0 else "  N/A")
print(f"  MONSOON 平均风速: {mw.mean():.4f}" if len(mw)>0 else "  N/A")
print()

# ── Summary and comparison with previous report ──
print("=" * 70)
print(" 分析完成")
print("=" * 70)
