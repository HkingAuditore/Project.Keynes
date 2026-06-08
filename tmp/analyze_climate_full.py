#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
综合气候自洽性分析（针对 907MB CSV，分块读取）
验证：太阳轨迹/南北半球季节、气温-纬度、海冰/降水/雪盖/植被、风场/洋流/SLP、地形影响、时间平滑性
"""
import pandas as pd
import numpy as np

CSV = 'd:/Godot/ProjectKeynes/Project.Keynes/tmp/tile_data_record_20260608_184710.csv'

USECOLS = [
    'tick_idx','cell_index','temp_arr','temp_arr_prev','temp_baseline_arr',
    'temp_baseline_year_arr','temp_season_offset_arr','insolation_now_arr',
    'insolation_dev_arr','day_length_arr','snow_cover_arr','snowpack_arr',
    'sea_ice_frac_arr','weather_precip_arr','weather_vapor_arr','weather_cloud_arr',
    'weather_type_arr','vegetation_vitality_arr','vegetation_arr','soil_moisture_arr',
    'water_balance_30d_arr','elevation_arr','cell_lat_norm_arr','is_water_arr',
    'wind_x_arr','wind_y_arr','wind_speed_arr','slp_arr',
    'ocean_current_x_arr','ocean_current_y_arr','ocean_psi_arr','upwelling_strength_arr',
    'wind_stress_curl_arr','base_moisture_arr','temp_30d_arr','temp_365d_arr',
    'air_mass_temp_anomaly_arr',
]

print("读取数据（分块）...")
# 累加器
ticks = set()
n_rows = 0
# 按 tick 聚合：用于季节/时间序列
tick_agg = {}  # tick -> dict of lists for N/S hemisphere temps, subsolar proxy
# 纬度-温度散点（采样）
lat_temp = []  # (lat, temp, is_water, elev)
# 跳变统计
jump_count = 0
max_jump = 0.0
# 海冰 vs 温度 vs 纬度
ice_rows = []
# 植被活力分布
veg_vit = []
# 地形 vs 雪盖
elev_snow = []
# 降水分布
precip_vals = []
# 风/洋流量级
wind_mag = []
ocean_mag = []

chunk_iter = pd.read_csv(CSV, usecols=USECOLS, chunksize=500000)
for ci, chunk in enumerate(chunk_iter):
    n_rows += len(chunk)
    ticks.update(chunk['tick_idx'].unique().tolist())

    # 跳变（同 cell 内 temp vs temp_prev）
    d = (chunk['temp_arr'] - chunk['temp_arr_prev']).abs()
    jump_count += int((d > 0.1).sum())
    mj = float(d.max())
    if mj > max_jump:
        max_jump = mj

    # 纬度-温度采样（每块取前 2000）
    s = chunk.iloc[::max(1, len(chunk)//2000)]
    for _, row in s.iterrows():
        lat_temp.append((row['cell_lat_norm_arr'], row['temp_arr'], row['is_water_arr'], row['elevation_arr']))

    # 按 tick 聚合南北半球温度（lat<0.5 北, >0.5 南，取决于约定；这里 lat_norm 0..1）
    for tk, grp in chunk.groupby('tick_idx'):
        if tk not in tick_agg:
            tick_agg[tk] = {'n_temp':[], 's_temp':[], 'eq_temp':[], 'subsolar_proxy':[],
                            'season_off_n':[], 'season_off_s':[], 'insol_n':[], 'insol_s':[],
                            'daylen_n':[], 'daylen_s':[]}
        north = grp[grp['cell_lat_norm_arr'] < 0.35]
        south = grp[grp['cell_lat_norm_arr'] > 0.65]
        eq = grp[(grp['cell_lat_norm_arr']>=0.45)&(grp['cell_lat_norm_arr']<=0.55)]
        tick_agg[tk]['n_temp'].append(north['temp_arr'].mean())
        tick_agg[tk]['s_temp'].append(south['temp_arr'].mean())
        tick_agg[tk]['eq_temp'].append(eq['temp_arr'].mean())
        tick_agg[tk]['season_off_n'].append(north['temp_season_offset_arr'].mean())
        tick_agg[tk]['season_off_s'].append(south['temp_season_offset_arr'].mean())
        tick_agg[tk]['insol_n'].append(north['insolation_now_arr'].mean())
        tick_agg[tk]['insol_s'].append(south['insolation_now_arr'].mean())
        tick_agg[tk]['daylen_n'].append(north['day_length_arr'].mean())
        tick_agg[tk]['daylen_s'].append(south['day_length_arr'].mean())

    # 海冰：水体格子
    w = chunk[chunk['is_water_arr']==True] if chunk['is_water_arr'].dtype==bool else chunk[chunk['is_water_arr']==1]
    ws = w.iloc[::max(1,len(w)//1000)] if len(w)>0 else w
    for _, row in ws.iterrows():
        ice_rows.append((row['cell_lat_norm_arr'], row['temp_arr'], row['sea_ice_frac_arr']))

    veg_vit.extend(chunk['vegetation_vitality_arr'].iloc[::max(1,len(chunk)//1000)].tolist())
    precip_vals.extend(chunk['weather_precip_arr'].iloc[::max(1,len(chunk)//1000)].tolist())

    for _, row in s.iterrows():
        elev_snow.append((row['elevation_arr'], row['snow_cover_arr'], row['temp_arr'], row['cell_lat_norm_arr']))
        wind_mag.append(np.hypot(row['wind_x_arr'], row['wind_y_arr']))
        ocean_mag.append(np.hypot(row['ocean_current_x_arr'], row['ocean_current_y_arr']))

    if ci % 5 == 0:
        print(f"  已处理 {n_rows} 行, {len(ticks)} ticks...")

print("\n" + "="*70)
print(f"数据规模: {n_rows} 行, {len(ticks)} 个 tick, 范围 {min(ticks)}~{max(ticks)}")
print("="*70)

import pickle
with open('d:/Godot/ProjectKeynes/Project.Keynes/tmp/_agg.pkl','wb') as f:
    pickle.dump({
        'ticks':sorted(ticks),'n_rows':n_rows,'jump_count':jump_count,'max_jump':max_jump,
        'tick_agg':tick_agg,'lat_temp':lat_temp,'ice_rows':ice_rows,'veg_vit':veg_vit,
        'elev_snow':elev_snow,'precip_vals':precip_vals,'wind_mag':wind_mag,'ocean_mag':ocean_mag,
    }, f)
print("聚合数据已保存到 _agg.pkl")
