#!/usr/bin/env python3
"""Final climate analysis with correct coordinate system."""
import pandas as pd
import numpy as np
import os

CSV = r"D:/Godot/ProjectKeynes/Project.Keynes/tmp/tile_data_record_20260609_134137.csv"
use_cols = [
    'cell_lat_norm_arr','temp_arr','temp_baseline_arr','temp_anomaly_arr',
    'insolation_now_arr','insolation_dev_arr',
    'wind_x_arr','wind_y_arr','wind_speed_arr','slp_arr',
    'is_water_arr','weather_type_arr','weather_precip_arr','weather_cloud_arr',
    'weather_vapor_arr','weather_convergence_arr','weather_instability_arr',
    'weather_intensity_arr','weather_transition_alpha_arr',
    'snow_cover_arr','sea_ice_frac_arr',
    'ocean_current_x_arr','ocean_current_y_arr',
    'upwelling_strength_arr','wind_stress_curl_arr','ocean_psi_arr',
    'elevation_arr','moisture_arr','soil_moisture_arr',
    'vegetation_vitality_arr','temperature_transport_anomaly_arr',
    'air_mass_temp_anomaly_arr',
]

# 5% sample
chunks = []
chunk_iter = pd.read_csv(CSV, usecols=use_cols, chunksize=100000)
for i, chunk in enumerate(chunk_iter):
    sampled = chunk.iloc[::20]
    chunks.append(sampled)
df = pd.concat(chunks, ignore_index=True)
print(f"Sample: {len(df)} rows")

# lat_norm convention: 0=pole_N, 0.5=equator, 1.0=pole_S
bins = [0, 0.15, 0.30, 0.45, 0.55, 0.70, 0.85, 1.0]
labels = ['Pole_N','High_N','Mid_N','Equator','Mid_S','High_S','Pole_S']
df['latband'] = pd.cut(df['cell_lat_norm_arr'], bins=bins, labels=labels)
land_mask = df['is_water_arr'] == 0
water_mask = df['is_water_arr'] == 1

sep = "=" * 78

# ── 1. LATITUDE BANDS ──
print(f"\n{sep}")
print(f"{'LATITUDE BAND OVERVIEW':^78}")
print(sep)
hdr = f"{'Band':>10s} {'n':>7s} {'land%':>6s} {'temp':>7s} {'baseline':>9s} {'anomaly':>8s} {'insol':>7s} {'insol_dev':>9s} {'snow%':>6s} {'ice%':>6s} {'precip':>7s} {'elev':>6s} {'vitality':>8s}"
print(hdr)
print("-" * len(hdr))
for b in labels:
    g = df[df['latband'] == b]
    if len(g) == 0:
        continue
    lpct = 100 * g[land_mask].shape[0] / len(g)
    snow_pct = 100 * (g['snow_cover_arr'] > 0.01).mean()
    ice_pct = 100 * (g['sea_ice_frac_arr'] > 0.01).mean()
    vit = g.loc[land_mask, 'vegetation_vitality_arr'].mean() if g[land_mask].shape[0] > 0 else 0
    row = (
        f"{b:>10s} {len(g):>7d} {lpct:>5.1f}% "
        f"{g['temp_arr'].mean():>6.3f} {g['temp_baseline_arr'].mean():>8.4f} "
        f"{g['temp_anomaly_arr'].mean():>7.4f} {g['insolation_now_arr'].mean():>6.4f} "
        f"{g['insolation_dev_arr'].mean():>8.4f} {snow_pct:>5.1f}% {ice_pct:>5.1f}% "
        f"{g['weather_precip_arr'].mean():>6.4f} {g['elevation_arr'].mean():>5.3f} "
        f"{vit:>7.4f}"
    )
    print(row)

# ── 2. WIND FIELD ──
print(f"\n{sep}")
print(f"{'WIND FIELD BY LATITUDE':^78}")
print(sep)
print(f"Wind vectors are normalized: {np.allclose(np.sqrt(df['wind_x_arr']**2 + df['wind_y_arr']**2), 1.0)}")
print(f"Wind speed (scalar): mean={df['wind_speed_arr'].mean():.3f}, std={df['wind_speed_arr'].std():.3f}, range=[{df['wind_speed_arr'].min():.3f}, {df['wind_speed_arr'].max():.3f}]")
print(f"SLP: mean={df['slp_arr'].mean():.4f}, std={df['slp_arr'].std():.4f}, range=[{df['slp_arr'].min():.4f}, {df['slp_arr'].max():.4f}]")
print()
print(f"{'Band':>10s} {'w_dir':>8s} {'w_spd':>8s} {'SLP':>8s} {'land_dir':>9s} {'wat_dir':>9s}")
for b in labels:
    g = df[df['latband'] == b]
    if len(g) == 0:
        continue
    wx_m, wy_m = g['wind_x_arr'].mean(), g['wind_y_arr'].mean()
    deg = np.arctan2(wy_m, wx_m) * 180 / np.pi
    gl = g[land_mask]
    gw = g[water_mask]
    wxl, wyl = (gl['wind_x_arr'].mean(), gl['wind_y_arr'].mean()) if len(gl) > 0 else (0, 0)
    wxw, wyw = (gw['wind_x_arr'].mean(), gw['wind_y_arr'].mean()) if len(gw) > 0 else (0, 0)
    deg_l = np.arctan2(wyl, wxl) * 180 / np.pi if (wxl != 0 or wyl != 0) else 0
    deg_w = np.arctan2(wyw, wxw) * 180 / np.pi if (wxw != 0 or wyw != 0) else 0
    print(f"{b:>10s} {deg:>+7.1f}  {g['wind_speed_arr'].mean():>7.3f} {g['slp_arr'].mean():>7.4f} {deg_l:>+8.1f}  {deg_w:>+8.1f}")

# ── 3. OCEAN CURRENTS ──
print(f"\n{sep}")
print(f"{'OCEAN CURRENTS BY LATITUDE':^78}")
print(sep)
wdf = df[water_mask].copy()
wdf['oc_mag'] = np.sqrt(wdf['ocean_current_x_arr']**2 + wdf['ocean_current_y_arr']**2)
wdf['oc_dir'] = np.arctan2(wdf['ocean_current_y_arr'], wdf['ocean_current_x_arr']) * 180 / np.pi
print(f"OC magnitude: mean={wdf['oc_mag'].mean():.4f}, median={wdf['oc_mag'].median():.4f}, max={wdf['oc_mag'].max():.4f}, p95={np.percentile(wdf['oc_mag'], 95):.4f}")
print(f"Upwelling: mean={wdf['upwelling_strength_arr'].mean():.6f}, range=[{wdf['upwelling_strength_arr'].min():.6f}, {wdf['upwelling_strength_arr'].max():.6f}]")
print(f"Ocean PSI: mean={wdf['ocean_psi_arr'].mean():.2f}, range=[{wdf['ocean_psi_arr'].min():.2f}, {wdf['ocean_psi_arr'].max():.2f}]")
print(f"Wind stress curl: range=[{wdf['wind_stress_curl_arr'].min():.4f}, {wdf['wind_stress_curl_arr'].max():.4f}]")
print()
print(f"{'Band':>10s} {'n_wtr':>7s} {'oc_mag':>7s} {'oc_dir':>8s} {'upwell':>8s} {'ice%':>6s} {'psi':>8s}")
for b in labels:
    g = wdf[wdf['latband'] == b]
    if len(g) == 0:
        continue
    ox_m = g['ocean_current_x_arr'].mean()
    oy_m = g['ocean_current_y_arr'].mean()
    omag = np.sqrt(ox_m**2 + oy_m**2)
    odeg = np.arctan2(oy_m, ox_m) * 180 / np.pi
    ice = 100 * (g['sea_ice_frac_arr'] > 0.01).mean()
    psi_m = g['ocean_psi_arr'].mean()
    print(f"{b:>10s} {len(g):>7d} {omag:>6.4f} {odeg:>+7.1f}  {g['upwelling_strength_arr'].mean():>7.4f} {ice:>5.1f}% {psi_m:>7.2f}")

# ── 4. WEATHER ──
print(f"\n{sep}")
print(f"{'WEATHER ANALYSIS':^78}")
print(sep)
wt_names = {0:'CLEAR', 1:'RAIN', 2:'STORM', 3:'BLIZZARD', 4:'DROUGHT', 5:'FOG', 6:'HEATWAVE', 7:'MONSOON'}
for wt in sorted(df['weather_type_arr'].unique()):
    n = int((df['weather_type_arr'] == wt).sum())
    name = wt_names.get(int(wt), f"UNK{wt}")
    bar = "#" * int(n / len(df) * 80)
    print(f"  WT{int(wt):1d} {name:>10s}: {n:>7d} ({100*n/len(df):5.2f}%) {bar}")

print()
print(f"Transition alpha: mean={df['weather_transition_alpha_arr'].mean():.4f}")
trans = ((df['weather_transition_alpha_arr'] > 0.01) & (df['weather_transition_alpha_arr'] < 0.99)).sum()
print(f"Cells in transition: {trans} ({100*trans/len(df):.1f}%)")
print(f"Weather intensity: mean={df['weather_intensity_arr'].mean():.4f}, max={df['weather_intensity_arr'].max():.4f}, p95={np.percentile(df['weather_intensity_arr'], 95):.4f}")

# ── 5. ATMOSPHERIC FIELDS ──
print(f"\n{sep}")
print(f"{'ATMOSPHERIC FIELDS BY LATITUDE':^78}")
print(sep)
print(f"{'Band':>10s} {'precip':>7s} {'cloud':>6s} {'vapor':>6s} {'converg':>7s} {'instab':>7s} {'intens':>7s}")
for b in labels:
    g = df[df['latband'] == b]
    if len(g) == 0:
        continue
    print(f"{b:>10s} {g['weather_precip_arr'].mean():>6.4f} {g['weather_cloud_arr'].mean():>5.3f} {g['weather_vapor_arr'].mean():>5.3f} {g['weather_convergence_arr'].mean():>6.4f} {g['weather_instability_arr'].mean():>6.4f} {g['weather_intensity_arr'].mean():>6.4f}")

# ── 6. CORRELATIONS ──
print(f"\n{sep}")
print(f"{'KEY CORRELATIONS':^78}")
print(sep)
df['dist_eq'] = np.abs(df['cell_lat_norm_arr'] - 0.5)
print(f"  temp ~ dist_from_equator: {df['temp_arr'].corr(df['dist_eq']):+.4f}")
print(f"  insolation ~ dist_from_equator: {df['insolation_now_arr'].corr(df['dist_eq']):+.4f}")
print(f"  temp ~ elevation: {df['temp_arr'].corr(df['elevation_arr']):+.4f}")
print(f"  temp ~ precip: {df['temp_arr'].corr(df['weather_precip_arr']):+.4f}")
print(f"  precip ~ vapor: {df['weather_precip_arr'].corr(df['weather_vapor_arr']):+.4f}")
print(f"  precip ~ convergence: {df['weather_precip_arr'].corr(df['weather_convergence_arr']):+.4f}")
print(f"  wind_speed ~ SLP_gradient (|slp|): {df['wind_speed_arr'].corr(df['slp_arr'].abs()):+.4f}")
print(f"  temp ~ sea_ice: {df['temp_arr'].corr(df['sea_ice_frac_arr']):+.4f}")
print(f"  temp_anomaly ~ transport_anomaly: {df['temp_anomaly_arr'].corr(df['temperature_transport_anomaly_arr']):+.4f}")
print(f"  elevation ~ snow: {df['elevation_arr'].corr(df['snow_cover_arr']):+.4f}")

# ── 7. THERMAL ──
print(f"\n{sep}")
print(f"{'THERMAL BUDGET':^78}")
print(sep)
print(f"  Temp anomaly: mean={df['temp_anomaly_arr'].mean():.4f}, std={df['temp_anomaly_arr'].std():.4f}, range=[{df['temp_anomaly_arr'].min():.4f}, {df['temp_anomaly_arr'].max():.4f}]")
print(f"  Transport anomaly: mean={df['temperature_transport_anomaly_arr'].mean():.6f}, range=[{df['temperature_transport_anomaly_arr'].min():.4f}, {df['temperature_transport_anomaly_arr'].max():.4f}]")
print(f"  Air mass anomaly: mean={df['air_mass_temp_anomaly_arr'].mean():.6f}, range=[{df['air_mass_temp_anomaly_arr'].min():.4f}, {df['air_mass_temp_anomaly_arr'].max():.4f}]")
lf = df[land_mask]
print(f"  Land moisture: mean={lf['moisture_arr'].mean():.4f}, range=[{lf['moisture_arr'].min():.4f}, {lf['moisture_arr'].max():.4f}]")
print(f"  Land soil moisture: mean={lf['soil_moisture_arr'].mean():.4f}, range=[{lf['soil_moisture_arr'].min():.4f}, {lf['soil_moisture_arr'].max():.4f}]")
print(f"  Land vegetation vitality: mean={lf['vegetation_vitality_arr'].mean():.4f}, std={lf['vegetation_vitality_arr'].std():.4f}")

print(f"\nDone.")
