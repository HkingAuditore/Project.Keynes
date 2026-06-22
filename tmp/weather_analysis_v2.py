#!/usr/bin/env python3
"""Comprehensive weather/climate simulation analysis for tile_data_record."""

import pandas as pd
import numpy as np
from collections import Counter
import warnings
warnings.filterwarnings('ignore')

CSV = r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260622_145049.csv'

# ── Helper: parse array columns ──
def parse_arr(s):
    """Parse space-separated float array string like '-0.5 0.2 1.0'"""
    if pd.isna(s) or s == '':
        return np.array([])
    return np.array([float(x) for x in str(s).strip().split()])

# ── Read data in chunks ──
print("=" * 70)
print(" 天气/气候模拟数据分析报告 v2")
print("=" * 70)
print()

chunk_size = 50000
chunks = []
total_rows = 0

arr_cols = ['temp_arr','temp_arr_prev','moisture_arr','moisture_arr_prev',
            'snow_cover_arr','snow_cover_arr_prev','sea_ice_frac_arr','sea_ice_frac_arr_prev',
            'weather_type_arr','weather_prev_type_arr','weather_target_type_arr',
            'weather_precip_arr','weather_intensity_arr','weather_cloud_arr',
            'weather_cloud_water_arr','weather_vapor_arr','weather_convergence_arr',
            'weather_instability_arr','weather_transition_alpha_arr',
            'weather_classification_temp_arr','weather_classification_moisture_arr',
            'weather_field_init_arr','air_mass_temp_anomaly_arr',
            'temp_baseline_arr','temp_30d_arr','temp_365d_arr','temp_anomaly_arr',
            'temp_season_offset_arr','heat_input_arr','snowpack_arr',
            'vegetation_vitality_arr','soil_moisture_arr','vegetation_growth_pressure_arr',
            'temperature_transport_anomaly_arr','vegetation_heat_stress_arr',
            'vegetation_drought_stress_arr','vegetation_cold_stress_arr',
            'vegetation_regen_score_arr','base_moisture_arr',
            'wind_x_arr','wind_y_arr','wind_speed_arr','wind_stress_curl_arr',
            'temp_baseline_year_arr','terrain_arr','vegetation_arr',
            'base_terrain_arr','base_vegetation_arr','weather_dirty_mask','climate_dirty_mask']

# Also read some scalar cols
scalar_cols = ['tick_idx','row_idx','phys_sim_day',
               'weather_dirty_count','active_weather_ratio',
               'weather_convergence_published','weather_refresh_convergence',
               'weather_target_mismatch_count','weather_transitioning_count',
               'weather_transition_alpha_mean','weather_transition_alpha_p95',
               'climate_p95_temp_delta','climate_precip_p95',
               'climate_slp_delta_p95','climate_wind_delta_p95',
               'climate_ocean_delta_p95','climate_slp_abs_p95',
               'climate_wind_mag_p95','climate_ocean_mag_p95',
               'climate_max_temp_delta','climate_max_transport_anomaly',
               'climate_transport_nonzero_ratio','climate_sea_ice_delta_max']

all_cols = scalar_cols + arr_cols
# dedup
all_cols = list(dict.fromkeys(all_cols))

print("[1] 读取数据...")
first_chunk = True
for chunk in pd.read_csv(CSV, chunksize=chunk_size, usecols=all_cols):
    if first_chunk:
        print(f"  列数: {len(chunk.columns)}")
        print(f"  第一块行数: {len(chunk)}")
        first_chunk = False
    total_rows += len(chunk)
    # Parse array columns in this chunk
    for c in arr_cols:
        if c in chunk.columns:
            chunk[c + '_parsed'] = chunk[c].apply(parse_arr)
    chunks.append(chunk)

print(f"  总行数: {total_rows:,}")

# Get unique ticks
all_ticks = sorted(pd.concat([c['tick_idx'] for c in chunks]).unique())
n_ticks = len(all_ticks)
print(f"  唯一 tick 数: {n_ticks}")
print(f"  tick 范围: {all_ticks[0]} ~ {all_ticks[-1]}")
print()

# Determine if each row is one cell or one tick
# If a row has arrays of length > 1, it's one tick
sample_arr_len = 0
for c in chunks:
    col_name = 'temp_arr_parsed'
    if col_name in c.columns:
        non_empty = c[col_name].dropna()
        if len(non_empty) > 0:
            sample_arr_len = len(non_empty.iloc[0])
            break

n_cells = sample_arr_len if sample_arr_len > 1 else total_rows // n_ticks
is_tick_level = sample_arr_len > 1
print(f"[2] 数据结构")
print(f"  {'tick 级数据 (每行 = 1 tick, 数组内含所有 cell)' if is_tick_level else 'cell 级数据 (每行 = 1 cell × 1 tick)'}")
print(f"  总 tick: {n_ticks}")
print(f"  总 cell: {n_cells}")
print()

# ── Build cell-level arrays if tick-level ──
if is_tick_level:
    print("[3] 重组为 cell 级数据（按 tick 采样）...")
    # Sample every 10 ticks for analysis (too many ticks otherwise)
    sample_ticks = all_ticks[::max(1, n_ticks // 100)]
    n_sample = len(sample_ticks)
    print(f"  采样 {n_sample} 个 tick（共 {n_ticks} 个）")
    
    # Map tick_idx to chunk row
    tick_to_data = {}
    for chunk in chunks:
        for _, row in chunk.iterrows():
            tick_to_data[row['tick_idx']] = row
    
    # Extract cell-level arrays for sampled ticks
    cell_data = {c: [] for c in arr_cols}
    tick_ids = []
    for t in sample_ticks:
        if t in tick_to_data:
            row = tick_to_data[t]
            tick_ids.append(t)
            for c in arr_cols:
                parsed_col = c + '_parsed'
                if parsed_col in row.index:
                    val = row[parsed_col]
                    if hasattr(val, '__len__') and len(val) == n_cells:
                        cell_data[c].append(val)
                    else:
                        cell_data[c].append(np.full(n_cells, np.nan))
    
    # Stack: (n_sample, n_cells)
    for c in arr_cols:
        if cell_data[c]:
            cell_data[c] = np.array(cell_data[c])
        else:
            cell_data[c] = np.full((n_sample, n_cells), np.nan)
else:
    # Cell-level: each row is one cell at one tick
    # Need to pivot to (n_ticks, n_cells) arrays
    print("[3] 重组为 (tick × cell) 矩阵...")
    cell_data = {}
    # Getting all data into memory might be too large
    # Sample approach: process tick by tick
    pass

print()
print("[4] 天气类型分布分析")

# Collect weather types across all data
weather_types_all = []
if is_tick_level:
    for c in chunks:
        for _, row in c.iterrows():
            parsed = row.get('weather_type_arr_parsed')
            if parsed is not None and len(parsed) > 0:
                weather_types_all.extend(parsed.astype(int).tolist())
else:
    for c in chunks:
        parsed = c['weather_type_arr_parsed'].dropna()
        for arr in parsed:
            if len(arr) > 0:
                weather_types_all.append(int(arr[0]))

# Map weather type codes
WEATHER_MAP = {0:'CLEAR',1:'RAIN',2:'STORM',3:'BLIZZARD',4:'DROUGHT',5:'FOG',6:'HEATWAVE',7:'MONSOON'}

wc = Counter(weather_types_all)
total = sum(wc.values())
print(f"  总观测数: {total:,}")
print(f"  天气类型分布:")
for code, name in sorted(WEATHER_MAP.items()):
    cnt = wc.get(code, 0)
    pct = cnt / total * 100 if total > 0 else 0
    print(f"    {name:12s} (code={code}): {cnt:>12,}  ({pct:6.2f}%)")
print()

# ── Weather type correlations with other variables ──
print("[5] 各天气类型的平均气象指标")
if is_tick_level:
    # For tick-level data, compute per-type statistics
    type_metrics = {code: {
        'precip':[], 'temp':[], 'cloud_water':[], 'vapor':[],
        'instability':[], 'wind_speed':[], 'snow':[], 'intensity':[],
        'soil_moisture':[], 'veg_vitality':[]
    } for code in WEATHER_MAP.keys()}
    
    for c in chunks:
        for _, row in c.iterrows():
            wt = row.get('weather_type_arr_parsed')
            if wt is None or len(wt) == 0:
                continue
            wt = wt.astype(int)
            for code in WEATHER_MAP.keys():
                mask = wt == code
                if mask.sum() == 0:
                    continue
                d = type_metrics[code]
                for field, arr_name in [
                    ('precip','weather_precip_arr_parsed'),
                    ('temp','temp_arr_parsed'),
                    ('cloud_water','weather_cloud_water_arr_parsed'),
                    ('vapor','weather_vapor_arr_parsed'),
                    ('instability','weather_instability_arr_parsed'),
                    ('wind_speed','wind_speed_arr_parsed'),
                    ('snow','snow_cover_arr_parsed'),
                    ('intensity','weather_intensity_arr_parsed'),
                    ('soil_moisture','soil_moisture_arr_parsed'),
                    ('veg_vitality','vegetation_vitality_arr_parsed')
                ]:
                    arr = row.get(arr_name)
                    if arr is not None and len(arr) == len(wt):
                        d[field].extend(arr[mask].tolist())
    
    print(f"  {'Weather':12s} {'Precip':>10s} {'Temp':>10s} {'CloudW':>10s} {'Vapor':>10s} {'Instab':>10s} {'WindSpd':>10s} {'SnowCov':>10s} {'Intens':>10s}")
    print(f"  {'-'*12} {'-'*10} {'-'*10} {'-'*10} {'-'*10} {'-'*10} {'-'*10} {'-'*10} {'-'*10}")
    for code, name in sorted(WEATHER_MAP.items()):
        d = type_metrics[code]
        vals = []
        for k in ['precip','temp','cloud_water','vapor','instability','wind_speed','snow','intensity']:
            arr = np.array(d[k])
            vals.append(f"{arr.mean():10.4f}" if len(arr) > 0 else f"{'N/A':>10}")
        print(f"  {name:12s} {vals[0]} {vals[1]} {vals[2]} {vals[3]} {vals[4]} {vals[5]} {vals[6]} {vals[7]}")
else:
    print("  (需 cell 级数据)")
print()

# ── Perpetual rain / drought regions ──
print("[6] 永雨区 / 永旱区分析")
if is_tick_level:
    # Use sampled data
    precip = cell_data.get('weather_precip_arr')
    weather_type = cell_data.get('weather_type_arr')
    
    if precip is not None and precip.shape[0] > 0:
        # Rainy: precip > 0.02
        PRECIP_THRESH = 0.02
        rainy_t = (precip > PRECIP_THRESH).astype(float)
        
        # Per cell stats
        rainy_ratio = rainy_t.mean(axis=0)  # across ticks
        
        all_wet = (rainy_ratio == 1.0).sum()
        very_wet = (rainy_ratio > 0.8).sum()
        all_dry = (rainy_ratio == 0.0).sum()
        very_dry = (rainy_ratio < 0.05).sum()
        total_c = rainy_ratio.shape[0]
        
        print(f"  降水阈值: >{PRECIP_THRESH}")
        print(f"  总 cell 数: {total_c}")
        print(f"  全期湿润 (100%): {all_wet} ({all_wet/total_c*100:.2f}%)")
        print(f"  准永雨 (>80%):   {very_wet} ({very_wet/total_c*100:.2f}%)")
        print(f"  全期干燥 (0%):   {all_dry} ({all_dry/total_c*100:.2f}%)")
        print(f"  准永旱 (<5%):    {very_dry} ({very_dry/total_c*100:.2f}%)")
        
        # By terrain type
        terrain = cell_data.get('terrain_arr')
        if terrain is not None and terrain.shape[0] > 0:
            land_mask = terrain.mean(axis=0) > 0.5  # simplified
            n_land = land_mask.sum()
            if n_land > 0:
                print(f"\n  陆地 cell: {n_land}")
                print(f"  陆地准永旱 (<5%降水): {(rainy_ratio[land_mask] < 0.05).sum()} ({(rainy_ratio[land_mask] < 0.05).sum()/n_land*100:.2f}%)")
                print(f"  陆地准永雨 (>80%降水): {(rainy_ratio[land_mask] > 0.8).sum()} ({(rainy_ratio[land_mask] > 0.8).sum()/n_land*100:.2f}%)")
    
    # Also check weather_type perpetuity
    if weather_type is not None and weather_type.shape[0] > 0:
        print(f"\n  按天气类型的永续性:")
        for code, name in sorted(WEATHER_MAP.items()):
            is_type = (weather_type == code)
            always = (is_type.all(axis=0)).sum()
            frequent = (is_type.mean(axis=0) > 0.5).sum()
            if always > 0 or frequent > 0:
                print(f"    {name:12s}: 始终={always}, 频繁(>50%)={frequent}")
else:
    print("  (需 cell 级数据)")
print()

# ── Temperature by latitude ──
print("[7] 温度纬向梯度")
if is_tick_level:
    temp_arr = cell_data.get('temp_arr')
    if temp_arr is not None and temp_arr.shape[0] > 0 and temp_arr.shape[1] > 0:
        # Assume grid is laid out row-major (rows = latitude bands)
        side = int(np.sqrt(n_cells))
        if side * side == n_cells:
            temp_mean = np.nanmean(temp_arr, axis=0).reshape(side, side)
            # Average by row (latitude band)
            lat_profile = np.nanmean(temp_mean, axis=1)
            print(f"  网格: {side}x{side}")
            print(f"  赤道行 (行{side//2-2}~{side//2+2}) 平均温度: {lat_profile[side//2-2:side//2+3].mean():.4f}")
            print(f"  极地行 (行0~2) 平均温度: {lat_profile[:3].mean():.4f}")
            print(f"  极地行 (行{side-3}~{side-1}) 平均温度: {lat_profile[-3:].mean():.4f}")
            
            # Correlation with absolute latitude
            abs_lat = np.abs(np.arange(side) - side//2)
            lat_repeat = np.repeat(abs_lat, side)
            temp_flat = temp_mean.flatten()
            valid = ~np.isnan(temp_flat)
            if valid.sum() > 0:
                corr = np.corrcoef(abs_lat.repeat(side)[valid], temp_flat[valid])[0,1]
                print(f"  温度与绝对纬度相关系数: {corr:.4f}")
        else:
            print(f"  非正方形网格 ({n_cells} cells)")
else:
    print("  (需 cell 级数据)")
print()

# ── Snow/Ice analysis ──
print("[8] 冰雪分布")
if is_tick_level:
    snow = cell_data.get('snow_cover_arr')
    sea_ice = cell_data.get('sea_ice_frac_arr')
    temp_arr = cell_data.get('temp_arr')
    
    if snow is not None and sea_ice is not None and temp_arr is not None:
        snow_mean = np.nanmean(snow, axis=0)
        ice_mean = np.nanmean(sea_ice, axis=0)
        temp_mean = np.nanmean(temp_arr, axis=0)
        
        valid = ~np.isnan(snow_mean) & ~np.isnan(temp_mean)
        corr_snow_temp = np.corrcoef(snow_mean[valid], temp_mean[valid])[0,1] if valid.sum() > 1 else 0
        
        valid_i = ~np.isnan(ice_mean) & ~np.isnan(temp_mean)
        corr_ice_temp = np.corrcoef(ice_mean[valid_i], temp_mean[valid_i])[0,1] if valid_i.sum() > 1 else 0
        
        print(f"  雪盖均值: {np.nanmean(snow_mean):.4f}, 最大值: {np.nanmax(snow_mean):.4f}")
        print(f"  海冰均值: {np.nanmean(ice_mean):.4f}, 最大值: {np.nanmax(ice_mean):.4f}")
        print(f"  雪盖-温度相关: {corr_snow_temp:.4f}")
        print(f"  海冰-温度相关: {corr_ice_temp:.4f}")
        
        # Grid analysis for lat bands
        side = int(np.sqrt(n_cells))
        if side * side == n_cells:
            snow_2d = snow_mean.reshape(side, side)
            ice_2d = ice_mean.reshape(side, side)
            print(f"  极地行平均雪盖: {np.nanmean(snow_2d[:3]):.4f}")
            print(f"  极地行平均海冰: {np.nanmean(ice_2d[:3]):.4f}")
            print(f"  赤道行平均雪盖: {np.nanmean(snow_2d[side//2-3:side//2+3]):.4f}")
            print(f"  赤道行平均海冰: {np.nanmean(ice_2d[side//2-3:side//2+3]):.4f}")
else:
    print("  (需 cell 级数据)")
print()

# ── Weather transition / mobility ──
print("[9] 天气移动性分析")
if is_tick_level:
    weather_type = cell_data.get('weather_type_arr')
    precip = cell_data.get('weather_precip_arr')
    
    if weather_type is not None and weather_type.shape[0] > 1:
        n_t = weather_type.shape[0]
        n_c = weather_type.shape[1]
        
        # Type change per cell between consecutive ticks
        type_changes = []
        wet_jaccards = []
        for t in range(n_t - 1):
            changed = (weather_type[t] != weather_type[t+1]).sum()
            type_changes.append(changed / n_c)
            
            if precip is not None:
                wet_t = precip[t] > 0.02
                wet_t1 = precip[t+1] > 0.02
                intersection = (wet_t & wet_t1).sum()
                union = (wet_t | wet_t1).sum()
                jac = intersection / union if union > 0 else 1.0
                wet_jaccards.append(jac)
        
        type_changes = np.array(type_changes)
        print(f"  天气类型变化率 (tick 间): 均值={type_changes.mean():.4f}, 中位数={np.median(type_changes):.4f}")
        print(f"  天气类型变化率: p95={np.percentile(type_changes,95):.4f}, max={type_changes.max():.4f}")
        
        if wet_jaccards:
            wj = np.array(wet_jaccards)
            print(f"  湿润区 Jaccard (相邻 tick): 均值={wj.mean():.4f}, 中位数={np.median(wj):.4f}")
            print(f"  湿润区 Jaccard: p5={np.percentile(wj,5):.4f}, max={wj.max():.4f}")
            unchanged_count = (wj == 1.0).sum()
            print(f"  湿润区完全不变的相邻 tick 对数: {unchanged_count}/{len(wj)} ({unchanged_count/len(wj)*100:.1f}%)")
else:
    print("  (需 cell 级数据)")
print()

# ── Frontal analysis ──
print("[10] 锋面特征分析")
if is_tick_level:
    weather_type = cell_data.get('weather_type_arr')
    temp_arr = cell_data.get('temp_arr')
    wind_x = cell_data.get('wind_x_arr')
    wind_y = cell_data.get('wind_y_arr')
    convergence = cell_data.get('weather_convergence_arr')
    
    if weather_type is not None and temp_arr is not None:
        side = int(np.sqrt(n_cells))
        if side * side == n_cells:
            last_t = -1
            wt_2d = weather_type[last_t].reshape(side, side)
            temp_2d = temp_arr[last_t].reshape(side, side)
            
            # Count adjacent boundaries (4-connected)
            # Horizontal boundaries
            wt_h = (wt_2d[:, :-1] != wt_2d[:, 1:]).sum()
            wt_v = (wt_2d[:-1, :] != wt_2d[1:, :]).sum()
            total_edges = side*(side-1)*2
            type_boundary_ratio = (wt_h + wt_v) / total_edges
            print(f"  最后一帧天气类型边界比例: {type_boundary_ratio:.4f} ({wt_h+wt_v}/{total_edges})")
            
            # Temperature gradients (adjacent difference)
            temp_h_diff = np.abs(temp_2d[:, :-1] - temp_2d[:, 1:])
            temp_v_diff = np.abs(temp_2d[:-1, :] - temp_2d[1:, :])
            all_temp_diffs = np.concatenate([temp_h_diff.flatten(), temp_v_diff.flatten()])
            all_temp_diffs = all_temp_diffs[~np.isnan(all_temp_diffs)]
            print(f"  邻格温度梯度: p50={np.percentile(all_temp_diffs,50):.4f}, p95={np.percentile(all_temp_diffs,95):.4f}, p99={np.percentile(all_temp_diffs,99):.4f}, max={all_temp_diffs.max():.4f}")
            
            # Front-like: high temp gradient + convergence/precip
            if convergence is not None:
                conv_2d = convergence[last_t].reshape(side, side)
                conv_h = np.abs(conv_2d[:, :-1] + conv_2d[:, 1:]) / 2
                conv_v = np.abs(conv_2d[:-1, :] + conv_2d[1:, :]) / 2
                high_grad = all_temp_diffs > np.percentile(all_temp_diffs, 90)
                # correct indices
                high_conv_mask = np.concatenate([conv_h.flatten(), conv_v.flatten()]) > 0.1
                front_like = high_grad & high_conv_mask
                print(f"  类锋面边界比例 (高温度梯度+高辐合): {front_like.sum()}/{len(front_like)} ({front_like.sum()/len(front_like)*100:.2f}%)")
            
            # Wind shear
            if wind_x is not None and wind_y is not None:
                wx_2d = wind_x[last_t].reshape(side, side)
                wy_2d = wind_y[last_t].reshape(side, side)
                ws_2d = np.sqrt(wx_2d**2 + wy_2d**2)
                ws_h = np.abs(ws_2d[:, :-1] - ws_2d[:, 1:])
                ws_v = np.abs(ws_2d[:-1, :] - ws_2d[1:, :])
                all_ws = np.concatenate([ws_h.flatten(), ws_v.flatten()])
                all_ws = all_ws[~np.isnan(all_ws)]
                print(f"  风切变 (邻格风速差): p95={np.percentile(all_ws,95):.4f}, p99={np.percentile(all_ws,99):.4f}")
else:
    print("  (需 cell 级数据)")
print()

# ── Weather ←→ Soil / Vegetation ──
print("[11] 天气对土壤/植被的影响")
if is_tick_level:
    precip = cell_data.get('weather_precip_arr')
    soil = cell_data.get('soil_moisture_arr')
    veg = cell_data.get('vegetation_vitality_arr')
    veg_growth = cell_data.get('vegetation_growth_pressure_arr')
    veg_heat = cell_data.get('vegetation_heat_stress_arr')
    veg_drought = cell_data.get('vegetation_drought_stress_arr')
    veg_cold = cell_data.get('vegetation_cold_stress_arr')
    
    if precip is not None and soil is not None:
        precip_flat = precip.flatten()
        soil_flat = soil.flatten()
        valid = ~np.isnan(precip_flat) & ~np.isnan(soil_flat)
        if valid.sum() > 1:
            corr_ps = np.corrcoef(precip_flat[valid], soil_flat[valid])[0,1]
            print(f"  降水-土壤湿度相关: {corr_ps:.4f}")
        
        if veg is not None:
            veg_flat = veg.flatten()
            valid2 = ~np.isnan(soil_flat) & ~np.isnan(veg_flat)
            if valid2.sum() > 1:
                corr_sv = np.corrcoef(soil_flat[valid2], veg_flat[valid2])[0,1]
                print(f"  土壤湿度-植被活力相关: {corr_sv:.4f}")
            valid3 = ~np.isnan(precip_flat) & ~np.isnan(veg_flat)
            if valid3.sum() > 1:
                corr_pv = np.corrcoef(precip_flat[valid3], veg_flat[valid3])[0,1]
                print(f"  降水-植被活力直接相关: {corr_pv:.4f}")
        
        if veg_drought is not None:
            vd_flat = veg_drought.flatten()
            valid4 = ~np.isnan(precip_flat) & ~np.isnan(vd_flat)
            if valid4.sum() > 1:
                corr_pd = np.corrcoef(precip_flat[valid4], vd_flat[valid4])[0,1]
                print(f"  降水-干旱应力相关: {corr_pd:.4f}")
        
        if veg_heat is not None:
            vh_flat = veg_heat.flatten()
            valid5 = ~np.isnan(precip_flat) & ~np.isnan(vh_flat)
            if valid5.sum() > 1:
                corr_ph = np.corrcoef(precip_flat[valid5], vh_flat[valid5])[0,1]
                print(f"  降水-热应力相关: {corr_ph:.4f}")
        
        print(f"\n  植被活力分布:")
        if veg is not None:
            vf = veg.flatten()
            vf = vf[~np.isnan(vf)]
            print(f"    mean={vf.mean():.4f}, median={np.median(vf):.4f}")
            print(f"    p25={np.percentile(vf,25):.4f}, p75={np.percentile(vf,75):.4f}")
            print(f"    zero_ratio={(vf==0).sum()/len(vf)*100:.2f}%")
else:
    print("  (需 cell 级数据)")
print()

# ── Anomaly detection ──
print("[12] 异常检测")
if is_tick_level:
    weather_type = cell_data.get('weather_type_arr')
    precip = cell_data.get('weather_precip_arr')
    temp_arr = cell_data.get('temp_arr')
    terrain = cell_data.get('terrain_arr')
    
    # Check HEATWAVE on land vs water
    if weather_type is not None and terrain is not None:
        wt_flat = weather_type.flatten()
        ter_flat = terrain.flatten()
        valid = ~np.isnan(wt_flat) & ~np.isnan(ter_flat)
        wt_v = wt_flat[valid]
        ter_v = ter_flat[valid]
        
        land_mask = ter_v > 0.5
        water_mask = ter_v < 0.5
        
        hw_land = ((wt_v == 6) & land_mask).sum()
        hw_water = ((wt_v == 6) & water_mask).sum()
        total_land = land_mask.sum()
        total_water = water_mask.sum()
        
        print(f"  HEATWAVE (code=6):")
        print(f"    陆地出现: {hw_land} (陆地总观测: {total_land}, 比例: {hw_land/total_land*100:.4f}%)" if total_land > 0 else "    (无陆地)")
        print(f"    水域出现: {hw_water} (水域总观测: {total_water}, 比例: {hw_water/total_water*100:.4f}%)" if total_water > 0 else "    (无水域)")
        
        # DROUGHT on land
        drought_land = ((wt_v == 4) & land_mask).sum()
        print(f"  DROUGHT (code=4):")
        print(f"    陆地出现: {drought_land} ({drought_land/total_land*100:.4f}%)" if total_land > 0 else "    (无陆地)")
        print(f"    水域出现: {((wt_v == 4) & water_mask).sum()} ({((wt_v == 4) & water_mask).sum()/total_water*100:.4f}%)" if total_water > 0 else "")
        
        # DROUGHT precipitation check
        if precip is not None:
            precip_flat = precip.flatten()
            drought_mask = wt_v == 4
            drought_precip = precip_flat[valid][drought_mask]
            if len(drought_precip) > 0:
                print(f"    DROUGHT类型平均降水: {drought_precip.mean():.4f}")
            
            hw_precip = precip_flat[valid][wt_v == 6]
            if len(hw_precip) > 0:
                print(f"    HEATWAVE类型平均降水: {hw_precip.mean():.4f}")
        
        # FOG vapor check
        fog_vapor = None
        vapor = cell_data.get('weather_vapor_arr')
        if vapor is not None:
            vapor_flat = vapor.flatten()
            fog_mask = wt_v == 5
            fog_vapor = vapor_flat[valid][fog_mask].mean() if fog_mask.sum() > 0 else 0
            print(f"    FOG类型平均水汽: {fog_vapor:.4f}")
else:
    print("  (需 cell 级数据)")
print()

# ── Wind field analysis ──
print("[13] 风场分析")
if is_tick_level:
    wind_x = cell_data.get('wind_x_arr')
    wind_y = cell_data.get('wind_y_arr')
    
    if wind_x is not None and wind_y is not None:
        ws = np.sqrt(wind_x**2 + wind_y**2)
        ws_flat = ws.flatten()
        ws_flat = ws_flat[~np.isnan(ws_flat)]
        print(f"  风速: mean={ws_flat.mean():.4f}, median={np.median(ws_flat):.4f}")
        print(f"  风速: p95={np.percentile(ws_flat,95):.4f}, p99={np.percentile(ws_flat,99):.4f}, max={ws_flat.max():.4f}")
        
        # Wind direction consistency (check if trade winds / westerlies exist)
        wx_flat = wind_x.flatten()
        wy_flat = wind_y.flatten()
        wx_flat = wx_flat[~np.isnan(wx_flat)]
        wy_flat = wy_flat[~np.isnan(wy_flat)]
        print(f"  风x分量: mean={wx_flat.mean():.4f}, std={wx_flat.std():.4f}")
        print(f"  风y分量: mean={wy_flat.mean():.4f}, std={wy_flat.std():.4f}")
        
        # Average wind direction (radians)
        wind_dir = np.arctan2(wy_flat, wx_flat)
        print(f"  平均风向(弧度): {wind_dir.mean():.4f}")
        
        # Wind-stress curl (cyclonic activity indicator)
        curl = cell_data.get('wind_stress_curl_arr')
        if curl is not None:
            curl_flat = curl.flatten()
            curl_flat = curl_flat[~np.isnan(curl_flat)]
            print(f"  风应力旋度: mean={curl_flat.mean():.6f}, std={curl_flat.std():.4f}")
            print(f"  风应力旋度: p95={np.percentile(curl_flat,95):.4f}, p99={np.percentile(curl_flat,99):.4f}")
            # Cyclonic activity = significant positive curl
            cyclone_like = (curl_flat > 0.5).sum()
            print(f"  气旋性旋度(>0.5) 出现次数: {cyclone_like} / {len(curl_flat)}")
else:
    print("  (需 cell 级数据)")
print()

# ── Temporal variation ──
print("[14] 时间变化分析")
if is_tick_level:
    weather_type = cell_data.get('weather_type_arr')
    
    if weather_type is not None:
        # Count unique weather types per tick
        types_per_tick = []
        active_cells = []
        for t in range(weather_type.shape[0]):
            wt = weather_type[t]
            wt_v = wt[~np.isnan(wt)]
            types_used = len(np.unique(wt_v))
            types_per_tick.append(types_used)
            active_cells.append((wt_v >= 0).sum())

        types_per_tick = np.array(types_per_tick)
        active_cells = np.array(active_cells)
        
        print(f"  每 tick 活跃天气种类数: mean={types_per_tick.mean():.1f}, min={types_per_tick.min()}, max={types_per_tick.max()}")
        print(f"  活跃 cell 数: mean={active_cells.mean():.0f}, 范围: {active_cells.min():.0f}~{active_cells.max():.0f}")
        
        # Weather type transitions
        if weather_type.shape[0] > 1:
            transitions = []
            for t in range(weather_type.shape[0] - 1):
                transition_cells = (weather_type[t] != weather_type[t+1]).sum()
                transitions.append(transition_cells)
            transitions = np.array(transitions)
            print(f"  每 tick 天气转变 cell 数: mean={transitions.mean():.1f}, median={np.median(transitions):.1f}")
            print(f"  转变 cell 变化: p95={np.percentile(transitions,95):.0f}, p5={np.percentile(transitions,5):.0f}")
            
            # Stuck ticks (no change at all)
            frozen = (transitions == 0).sum()
            print(f"  完全无变化的 tick 对数: {frozen} / {len(transitions)} ({frozen/len(transitions)*100:.1f}%)")
else:
    print("  (需 cell 级数据)")
print()

# ── Scalar diagnostics summary ──
print("[15] 标量诊断指标汇总")
print("  (从所有可用行汇总)")
scalar_sums = {}
for chunk in chunks:
    for col in scalar_cols:
        if col in chunk.columns:
            vals = chunk[col].dropna()
            if col not in scalar_sums:
                scalar_sums[col] = []
            scalar_sums[col].extend(vals.tolist())

for col, vals in scalar_sums.items():
    if vals:
        arr = np.array(vals)
        print(f"  {col}: mean={arr.mean():.4f}, median={np.median(arr):.4f}, min={arr.min():.4f}, max={arr.max():.4f}")
print()

print("=" * 70)
print(" 分析完成")
print("=" * 70)
