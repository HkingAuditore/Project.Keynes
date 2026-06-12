#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
v7 增量分析：
  - 用 stage_delta_summary 已经表明温度 Δ 集中在 pass_a/pass_b/wind_surface
  - 这一脚本进一步证明 ping-pong 是 stage 周期驱动 (而非物理震荡)：
      * 按 (lat_band, hydro_group, stage) 切片 ΔT
      * 找 30 个 stage 周期内 ΔT 符号最稳定 vs 翻转最多的 cell
      * 抽样若干 cell 的 7-tick window，并显示每 tick 对应的 stage
"""
import pandas as pd, numpy as np, json, os, time, sys

CSV = r'D:/Godot/ProjectKeynes/Project.Keynes/tmp/tile_data_record_20260612_192816.csv'
OUT = r'D:/Godot/ProjectKeynes/Project.Keynes/tmp/analysis_v7_after_fix'
os.makedirs(OUT, exist_ok=True)

USECOLS = [
    'tick_idx','cell_index','cell_lat_norm_arr','is_water_arr',
    'temp_arr','temp_arr_prev','moisture_arr','moisture_arr_prev',
    'weather_precip_arr','weather_type_arr',
    'climate_pass_stage','climate_pass_path','climate_pass_status',
    'climate_partial','climate_progress_ratio',
]

def lat_band(v):
    a = abs(v - 0.5) * 2.0  # 0 equator → 1 pole
    if a < 0.30: return 'equatorial'
    if a < 0.60: return 'subtropical'
    if a < 0.85: return 'mid_latitude'
    return 'polar'

t0 = time.time()
print(f"[*] 读取 {CSV}")
# 抽样：仅取前 300 个 cell × 全部 tick，把 stage 与 ΔT 对齐
df = pd.read_csv(CSV, usecols=USECOLS)
print(f"  raw rows={len(df):,}, ticks={df['tick_idx'].nunique()}, cells={df['cell_index'].nunique()}, t={time.time()-t0:.1f}s")
# 计算 ΔT = temp - temp_prev
df['dT'] = df['temp_arr'] - df['temp_arr_prev']
df['adT'] = df['dT'].abs()
df['dM'] = df['moisture_arr'] - df['moisture_arr_prev']
df['adM'] = df['dM'].abs()
df['lat_band'] = df['cell_lat_norm_arr'].apply(lat_band)
df['hydro'] = np.where(df['is_water_arr']==1, 'water', 'land')

# --- Stage × geo 切片 ---
sg = df.groupby(['climate_pass_stage','lat_band','hydro']).agg(
    n=('dT','size'),
    dT_mean_abs=('adT','mean'),
    dT_p95=('adT', lambda s: float(np.percentile(s,95))),
    dT_p99=('adT', lambda s: float(np.percentile(s,99))),
    dT_max=('adT','max'),
    dT_pos_ratio=('dT', lambda s: float((s>0.001).mean())),
    dT_neg_ratio=('dT', lambda s: float((s<-0.001).mean())),
    dM_p95=('adM', lambda s: float(np.percentile(s,95))),
    dM_max=('adM','max'),
).reset_index()
sg.to_csv(os.path.join(OUT,'stage_geo_delta.csv'), index=False)
print(f"  stage_geo_delta saved, rows={len(sg)}")

# --- Per-tick stage sequence ---
tick_stage = df.drop_duplicates('tick_idx')[['tick_idx','climate_pass_stage','climate_pass_path','climate_pass_status']].sort_values('tick_idx')
tick_stage.to_csv(os.path.join(OUT,'tick_stage_seq.csv'), index=False)

# --- 8 周期窗口 sample of high-pingpong cells ---
# 在所有 cell 中找 dT 符号翻转 (|dT|>0.02) 计数最多的 12 个
df_s = df.sort_values(['cell_index','tick_idx']).reset_index(drop=True)
df_s['sign_change'] = 0
g = df_s.groupby('cell_index')
prev_sign = g['dT'].shift(1)
mask = (df_s['adT']>0.02) & (prev_sign.abs()>0.02) & (np.sign(df_s['dT']) != np.sign(prev_sign))
df_s.loc[mask,'sign_change'] = 1
pp_counts = df_s.groupby('cell_index')['sign_change'].sum().sort_values(ascending=False)
top_cells = pp_counts.head(12).index.tolist()
print(f"  top pingpong cells: {top_cells} counts={pp_counts.head(12).tolist()}")

# 给这些 cell 抽 24-tick (≈ 3 个 stage 周期) 窗口
samples = []
for ce in top_cells:
    sub = df_s[df_s['cell_index']==ce].sort_values('tick_idx')
    # 找一个 sign_change 密集区域
    if sub['sign_change'].sum() == 0:
        continue
    pp_ticks = sub[sub['sign_change']==1]['tick_idx'].tolist()
    pivot = pp_ticks[len(pp_ticks)//2]
    win = sub[(sub['tick_idx']>=pivot-12) & (sub['tick_idx']<=pivot+12)]
    win_records = []
    for _, r in win.iterrows():
        win_records.append({
            'tick': int(r['tick_idx']),
            'stage': r['climate_pass_stage'],
            'path': r['climate_pass_path'],
            'status': r['climate_pass_status'],
            'partial': bool(r['climate_partial']),
            'progress': float(r['climate_progress_ratio']) if pd.notna(r['climate_progress_ratio']) else None,
            'temp': float(r['temp_arr']),
            'dT': float(r['dT']),
            'moisture': float(r['moisture_arr']),
            'dM': float(r['dM']),
            'precip': float(r['weather_precip_arr']),
            'weather_type': int(r['weather_type_arr']),
        })
    samples.append({
        'cell_index': int(ce),
        'lat_norm': float(sub['cell_lat_norm_arr'].iloc[0]),
        'lat_band': str(sub['lat_band'].iloc[0]),
        'hydro': str(sub['hydro'].iloc[0]),
        'pingpong_count': int(pp_counts[ce]),
        'window': win_records,
    })

# --- 时间切片：每 64 tick (≈ 9 个 stage 周期) 的 precip 集中度 ---
df['time_window'] = pd.cut(df['tick_idx'], bins=[373,437,502,566,631,696,760,825,890], labels=[
    'W1:374-437','W2:438-502','W3:503-566','W4:567-631','W5:632-696','W6:697-760','W7:761-825','W8:826-890'
])
tw = df.groupby(['time_window','lat_band','hydro'], observed=True).agg(
    n=('weather_precip_arr','size'),
    precip_mean=('weather_precip_arr','mean'),
    precip_p95=('weather_precip_arr', lambda s: float(np.percentile(s,95))),
    precip_max=('weather_precip_arr','max'),
    wet_ratio_gt_0p10=('weather_precip_arr', lambda s: float((s>0.10).mean())),
    weather_active=('weather_type_arr', lambda s: float((s!=0).mean())),
).reset_index()
tw.to_csv(os.path.join(OUT,'time_geo_precip.csv'), index=False)

# 输出 sample
with open(os.path.join(OUT,'pingpong_windows.json'),'w',encoding='utf-8') as f:
    json.dump({'samples': samples}, f, ensure_ascii=False, indent=2, default=float)

# 总结：每 stage 的 ΔT 在 (lat_band, hydro=land) 上的均值
sum_land = sg[sg['hydro']=='land'].pivot_table(index='climate_pass_stage', columns='lat_band', values='dT_mean_abs')
print('\n=== Stage × Lat (LAND) mean |ΔT| ===')
print(sum_land.to_string())

sum_water = sg[sg['hydro']=='water'].pivot_table(index='climate_pass_stage', columns='lat_band', values='dT_mean_abs')
print('\n=== Stage × Lat (WATER) mean |ΔT| ===')
print(sum_water.to_string())

print(f"\n[OK] 完成, 用时 {time.time()-t0:.1f}s")
