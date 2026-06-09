#!/usr/bin/env python3
"""Climate simulation data analysis for Project Keynes.
Evaluates: ocean currents, wind fields, temperature, weather generation."""

import pandas as pd
import numpy as np
import sys
import os

CSV_PATH = r"D:/Godot/ProjectKeynes/Project.Keynes/tmp/tile_data_record_20260609_134137.csv"
OUT_DIR = r"D:/Godot/ProjectKeynes/Project.Keynes/tmp"

# ── Load data (stratified sample by latitude) ──
print("Loading CSV header...")
# Read just column names first
df_cols = pd.read_csv(CSV_PATH, nrows=0)
all_cols = list(df_cols.columns)
print(f"Total columns: {len(all_cols)}")

# Read the single tick snapshot — one row per cell
print("Reading data (this may take a while)...")
# Read in chunks, keep every Nth row to sample
sample_rate = 10  # 10% sample = ~500k rows
chunks = []
chunk_size = 50000
for i, chunk in enumerate(pd.read_csv(CSV_PATH, chunksize=chunk_size)):
    sampled = chunk.iloc[::sample_rate]
    chunks.append(sampled)
    if i % 20 == 0:
        print(f"  Chunk {i}...")
df = pd.concat(chunks, ignore_index=True)
print(f"Sampled data: {len(df)} rows")

tick_val = df['tick_idx'].iloc[0]
print(f"Tick index: {tick_val}")
print(f"Sample multiplier (inverse): {sample_rate}")

# ── Basic stats ──
print("\n" + "="*60)
print("BASIC STATISTICS")
print("="*60)

land_mask = df['is_water_arr'] == 0
water_mask = df['is_water_arr'] == 1
n_land = land_mask.sum()
n_water = water_mask.sum()
print(f"Land cells: {n_land} ({100*n_land/len(df):.1f}%)")
print(f"Water cells: {n_water} ({100*n_water/len(df):.1f}%)")

print(f"\nClimate global flags:")
print(f"  was_skipped_day: {df['was_skipped_day'].iloc[0]}")
print(f"  thermal_finalizer_applied: {df['climate_thermal_finalizer_applied'].iloc[0]}")
print(f"  max_temp_delta: {df['climate_max_temp_delta'].iloc[0]:.6f}")
print(f"  p99_temp_delta: {df['climate_p99_temp_delta'].iloc[0]:.6f}")
print(f"  max_transport_anomaly: {df['climate_max_transport_anomaly'].iloc[0]:.6f}")
print(f"  sea_ice_delta_max: {df['climate_sea_ice_delta_max'].iloc[0]:.6f}")
print(f"  precip_p95: {df['climate_precip_p95'].iloc[0]:.6f}")

print(f"\nTiming (ms):")
print(f"  simulation: {df['t_sus_ms'].iloc[0]:.2f}")
print(f"  render: {df['t_render_ms'].iloc[0]:.2f}")
print(f"  ui: {df['t_ui_ms'].iloc[0]:.2f}")
print(f"  fps: {df['fps'].iloc[0]:.0f}")

# ── 1. OCEAN CURRENTS ──
print("\n" + "="*60)
print("1. OCEAN CURRENTS ANALYSIS")
print("="*60)

water_df = df[water_mask].copy()

# Ocean current magnitude and direction
oc_x = water_df['ocean_current_x_arr'].values
oc_y = water_df['ocean_current_y_arr'].values
oc_mag = np.sqrt(oc_x**2 + oc_y**2)
oc_dir = np.arctan2(oc_y, oc_x) * 180 / np.pi

print(f"Ocean current magnitude:")
print(f"  Mean: {oc_mag.mean():.4f}")
print(f"  Median: {np.median(oc_mag):.4f}")
print(f"  Std: {oc_mag.std():.4f}")
print(f"  Max: {oc_mag.max():.4f}")
print(f"  P95: {np.percentile(oc_mag, 95):.4f}")
print(f"  P99: {np.percentile(oc_mag, 99):.4f}")
print(f"  P1: {np.percentile(oc_mag, 1):.4f}")

# Ocean current by latitude bands
water_df_temp = water_df.copy()
water_df_temp['lat_band'] = pd.cut(water_df_temp['cell_lat_norm_arr'], 
    bins=[-1.0, -0.6, -0.3, 0.0, 0.3, 0.6, 1.0],
    labels=['90S-54S', '54S-27S', '27S-0', '0-27N', '27N-54N', '54N-90N'])
water_df_temp['oc_mag'] = oc_mag
water_df_temp['oc_dir'] = oc_dir

print(f"\nOcean currents by latitude band:")
for band in ['90S-54S', '54S-27S', '27S-0', '0-27N', '27N-54N', '54N-90N']:
    b = water_df_temp[water_df_temp['lat_band'] == band]
    if len(b) == 0:
        continue
    # Compute mean direction (circular mean approximation)
    oc_x_b = b['ocean_current_x_arr'].values
    oc_y_b = b['ocean_current_y_arr'].values
    mean_x = oc_x_b.mean()
    mean_y = oc_y_b.mean()
    mean_dir = np.arctan2(mean_y, mean_x) * 180 / np.pi
    mean_mag = np.sqrt(mean_x**2 + mean_y**2)
    print(f"  {band}: n={len(b):6d}, |v|={mean_mag:.4f}, dir={mean_dir:+.1f}°")

# Upwelling
print(f"\nUpwelling strength:")
print(f"  Mean: {water_df['upwelling_strength_arr'].mean():.6f}")
print(f"  Max: {water_df['upwelling_strength_arr'].max():.6f}")
print(f"  P95: {np.percentile(water_df['upwelling_strength_arr'], 95):.6f}")

# Wind stress curl
print(f"\nWind stress curl:")
print(f"  Mean: {water_df['wind_stress_curl_arr'].mean():.6f}")
print(f"  Std: {water_df['wind_stress_curl_arr'].std():.6f}")
print(f"  Max: {water_df['wind_stress_curl_arr'].max():.6f}")
print(f"  Min: {water_df['wind_stress_curl_arr'].min():.6f}")

# Ocean psi (streamfunction)
print(f"\nOcean streamfunction (psi):")
psi = water_df['ocean_psi_arr']
print(f"  Mean: {psi.mean():.6f}")
print(f"  Range: [{psi.min():.6f}, {psi.max():.6f}]")

# ── 2. WIND FIELDS ──
print("\n" + "="*60)
print("2. WIND FIELDS ANALYSIS")
print("="*60)

all_df = df.copy()
all_df['lat_band'] = pd.cut(all_df['cell_lat_norm_arr'], 
    bins=[-1.0, -0.6, -0.3, 0.0, 0.3, 0.6, 1.0],
    labels=['90S-54S', '54S-27S', '27S-0', '0-27N', '27N-54N', '54N-90N'])

# Wind vectors
wx = all_df['wind_x_arr'].values
wy = all_df['wind_y_arr'].values
ws = np.sqrt(wx**2 + wy**2)
wd = np.arctan2(wy, wx) * 180 / np.pi
all_df['wind_speed'] = ws
all_df['wind_dir'] = wd

print(f"Wind speed:")
print(f"  Mean: {ws.mean():.4f}")
print(f"  Median: {np.median(ws):.4f}")
print(f"  Std: {ws.std():.4f}")
print(f"  Max: {ws.max():.4f}")
print(f"  P95: {np.percentile(ws, 95):.4f}")

print(f"\nWind by latitude band (all cells):")
for band in ['90S-54S', '54S-27S', '27S-0', '0-27N', '27N-54N', '54N-90N']:
    b = all_df[all_df['lat_band'] == band]
    if len(b) == 0:
        continue
    wx_b = b['wind_x_arr'].values.mean()
    wy_b = b['wind_y_arr'].values.mean()
    mag_b = np.sqrt(wx_b**2 + wy_b**2)
    dir_b = np.arctan2(wy_b, wx_b) * 180 / np.pi
    # Separate land/water
    b_land = b[b['is_water_arr'] == 0]
    b_water = b[b['is_water_arr'] == 1]
    wx_l = b_land['wind_x_arr'].values.mean() if len(b_land) > 0 else 0
    wy_l = b_land['wind_y_arr'].values.mean() if len(b_land) > 0 else 0
    wx_w = b_water['wind_x_arr'].values.mean() if len(b_water) > 0 else 0
    wy_w = b_water['wind_y_arr'].values.mean() if len(b_water) > 0 else 0
    dir_l = np.arctan2(wy_l, wx_l) * 180 / np.pi if (wx_l != 0 or wy_l != 0) else 0
    dir_w = np.arctan2(wy_w, wx_w) * 180 / np.pi if (wx_w != 0 or wy_w != 0) else 0
    print(f"  {band}: n={len(b):6d}, |v|={mag_b:.3f}, dir={dir_b:+6.1f}°  [land_dir={dir_l:+6.1f}°, water_dir={dir_w:+6.1f}°]")

# SLP (sea level pressure)
slp = all_df['slp_arr']
print(f"\nSea Level Pressure:")
print(f"  Mean: {slp.mean():.4f}")
print(f"  Std: {slp.std():.4f}")
print(f"  Range: [{slp.min():.4f}, {slp.max():.4f}]")

# Wind speed by latitude
print(f"\nSLP by latitude band:")
for band in ['90S-54S', '54S-27S', '27S-0', '0-27N', '27N-54N', '54N-90N']:
    b = all_df[all_df['lat_band'] == band]
    if len(b) == 0:
        continue
    print(f"  {band}: SLP={b['slp_arr'].mean():.4f}±{b['slp_arr'].std():.4f}, wind_spd={b['wind_speed'].mean():.4f}")

# ── 3. TEMPERATURE ANALYSIS ──
print("\n" + "="*60)
print("3. TEMPERATURE ANALYSIS")
print("="*60)

temp_now = all_df['temp_arr']
temp_prev = all_df['temp_arr_prev']
temp_baseline = all_df['temp_baseline_arr']
temp_30d = all_df['temp_30d_arr']
temp_365d = all_df['temp_365d_arr']
temp_anomaly = all_df['temp_anomaly_arr']
temp_season_offset = all_df['temp_season_offset_arr']

print(f"Current temperature (temp_arr):")
print(f"  Mean: {temp_now.mean():.4f}")
print(f"  Median: {np.median(temp_now):.4f}")
print(f"  Std: {temp_now.std():.4f}")
print(f"  Range: [{temp_now.min():.4f}, {temp_now.max():.4f}]")

print(f"\nPrevious temperature (temp_arr_prev):")
print(f"  Mean: {temp_prev.mean():.4f}")
print(f"  Range: [{temp_prev.min():.4f}, {temp_prev.max():.4f}]")

print(f"\nBaseline temperature (temp_baseline_arr):")
print(f"  Mean: {temp_baseline.mean():.4f}")
print(f"  Range: [{temp_baseline.min():.4f}, {temp_baseline.max():.4f}]")

print(f"\n30-day avg:")
print(f"  Mean: {temp_30d.mean():.4f}, Range: [{temp_30d.min():.4f}, {temp_30d.max():.4f}]")

print(f"\n365-day avg:")
print(f"  Mean: {temp_365d.mean():.4f}, Range: [{temp_365d.min():.4f}, {temp_365d.max():.4f}]")

print(f"\nTemperature anomaly:")
print(f"  Mean: {temp_anomaly.mean():.4f}")
print(f"  Std: {temp_anomaly.std():.4f}")
print(f"  Range: [{temp_anomaly.min():.4f}, {temp_anomaly.max():.4f}]")
print(f"  P95: {np.percentile(temp_anomaly, 95):.4f}")
print(f"  P5: {np.percentile(temp_anomaly, 5):.4f}")
print(f"  |anomaly|>0.5: {100*(np.abs(temp_anomaly.values) > 0.5).mean():.1f}%")

print(f"\nTemperature by latitude band:")
for band in ['90S-54S', '54S-27S', '27S-0', '0-27N', '27N-54N', '54N-90N']:
    b = all_df[all_df['lat_band'] == band]
    if len(b) == 0:
        continue
    b_land = b[b['is_water_arr'] == 0]
    b_water = b[b['is_water_arr'] == 1]
    print(f"  {band}: all={b['temp_arr'].mean():.2f}±{b['temp_arr'].std():.2f}, "
          f"land={b_land['temp_arr'].mean():.2f}±{b_land['temp_arr'].std():.2f} " if len(b_land) > 0 else f"  {band}: all={b['temp_arr'].mean():.2f}, ",
          f"water={b_water['temp_arr'].mean():.2f}±{b_water['temp_arr'].std():.2f}" if len(b_water) > 0 else "")

# Temperature seasonal offset
print(f"\nSeasonal offset (temp_season_offset):")
print(f"  Mean: {temp_season_offset.mean():.4f}")
print(f"  Range: [{temp_season_offset.min():.4f}, {temp_season_offset.max():.4f}]")

# Insolation
print(f"\nInsolation:")
ins_now = all_df['insolation_now_arr']
ins_dev = all_df['insolation_dev_arr']
day_len = all_df['day_length_arr']
print(f"  insolation_now: mean={ins_now.mean():.4f}, range=[{ins_now.min():.4f}, {ins_now.max():.4f}]")
print(f"  insolation_dev: mean={ins_dev.mean():.4f}, range=[{ins_dev.min():.4f}, {ins_dev.max():.4f}]")
print(f"  day_length: mean={day_len.mean():.4f}, range=[{day_len.min():.4f}, {day_len.max():.4f}]")

# Thermal energy and heat input
print(f"\nThermal budget:")
heat_in = all_df['heat_input_arr']
therm_en = all_df['thermal_energy_arr']
print(f"  heat_input: mean={heat_in.mean():.4f}, range=[{heat_in.min():.4f}, {heat_in.max():.4f}]")
print(f"  thermal_energy: mean={therm_en.mean():.4f}, range=[{therm_en.min():.4f}, {therm_en.max():.4f}]")

# Temperature transport anomaly
t_transport = all_df['temperature_transport_anomaly_arr']
print(f"\n  transport_anomaly: mean={t_transport.mean():.6f}, range=[{t_transport.min():.6f}, {t_transport.max():.6f}]")
print(f"  P95 transport anomaly: {np.percentile(np.abs(t_transport), 95):.6f}")

# Air mass temperature anomaly
air_mass = all_df['air_mass_temp_anomaly_arr']
print(f"\n  air_mass_temp_anomaly: mean={air_mass.mean():.6f}, range=[{air_mass.min():.6f}, {air_mass.max():.6f}]")

# Sea ice
sea_ice = all_df[water_mask]['sea_ice_frac_arr']
print(f"\nSea ice fraction (water cells):")
print(f"  Mean: {sea_ice.mean():.6f}")
print(f"  Max: {sea_ice.max():.6f}")
print(f"  P95: {np.percentile(sea_ice, 95):.6f}")
ice_present = (sea_ice > 0.01).sum()
print(f"  Cells with ice: {ice_present} ({100*ice_present/len(sea_ice):.2f}% of water)")

# Sea ice by latitude
print(f"\nSea ice by latitude band:")
for band in ['90S-54S', '54S-27S', '27S-0', '0-27N', '27N-54N', '54N-90N']:
    b = water_df_temp[water_df_temp['lat_band'] == band]
    if len(b) == 0:
        continue
    ice = b['sea_ice_frac_arr']
    print(f"  {band}: mean_ice={ice.mean():.4f}, ice_cells={(ice > 0.01).sum()}/{len(b)}")

# High-latitude temperature check
print(f"\nHigh-latitude temperature samples (<-0.7 lat):")
high_lat = all_df[all_df['cell_lat_norm_arr'].abs() > 0.7]
if len(high_lat) > 0:
    print(f"  n={len(high_lat)}, temp: {high_lat['temp_arr'].mean():.2f}±{high_lat['temp_arr'].std():.2f}, "
          f"range=[{high_lat['temp_arr'].min():.2f}, {high_lat['temp_arr'].max():.2f}]")
    h_land = high_lat[high_lat['is_water_arr'] == 0]
    h_water = high_lat[high_lat['is_water_arr'] == 1]
    if len(h_land) > 0:
        print(f"  High-lat land: {h_land['temp_arr'].mean():.2f}±{h_land['temp_arr'].std():.2f}")
    if len(h_water) > 0:
        print(f"  High-lat water: {h_water['temp_arr'].mean():.2f}±{h_water['temp_arr'].std():.2f}")

# ── 4. WEATHER ANALYSIS ──
print("\n" + "="*60)
print("4. WEATHER GENERATION ANALYSIS")
print("="*60)

# Weather types
print(f"Weather types distribution:")
weather_counts = all_df['weather_type_arr'].value_counts().sort_index()
for wtype, count in weather_counts.items():
    pct = 100 * count / len(all_df)
    print(f"  Type {wtype}: {count:8d} cells ({pct:5.2f}%)")

# Weather target types
target_counts = all_df['weather_target_type_arr'].value_counts().sort_index()
print(f"\nWeather target types:")
for wtype, count in target_counts.items():
    pct = 100 * count / len(all_df)
    print(f"  Type {wtype}: {count:8d} cells ({pct:5.2f}%)")

# Transition alpha
trans_alpha = all_df['weather_transition_alpha_arr']
print(f"\nWeather transition alpha:")
print(f"  Mean: {trans_alpha.mean():.4f}")
print(f"  Range: [{trans_alpha.min():.4f}, {trans_alpha.max():.4f}]")
transitioning = ((trans_alpha > 0.01) & (trans_alpha < 0.99)).sum()
print(f"  Cells in transition (0.01<alpha<0.99): {transitioning} ({100*transitioning/len(all_df):.2f}%)")

# Weather intensity
w_intensity = all_df['weather_intensity_arr']
print(f"\nWeather intensity:")
print(f"  Mean: {w_intensity.mean():.4f}")
print(f"  Range: [{w_intensity.min():.4f}, {w_intensity.max():.4f}]")
print(f"  P95: {np.percentile(w_intensity, 95):.4f}")

# Clouds
w_cloud = all_df['weather_cloud_arr']
w_cloud_water = all_df['weather_cloud_water_arr']
print(f"\nCloud cover:")
print(f"  Mean: {w_cloud.mean():.4f}, Range: [{w_cloud.min():.4f}, {w_cloud.max():.4f}]")
print(f"Cloud water:")
print(f"  Mean: {w_cloud_water.mean():.4f}, Range: [{w_cloud_water.min():.4f}, {w_cloud_water.max():.4f}]")

# Precipitation
w_precip = all_df['weather_precip_arr']
print(f"\nPrecipitation (weather_precip_arr):")
print(f"  Mean: {w_precip.mean():.6f}")
print(f"  Max: {w_precip.max():.6f}")
print(f"  P95: {np.percentile(w_precip, 95):.6f}")
print(f"  P99: {np.percentile(w_precip, 99):.6f}")
precip_cells = (w_precip > 0.001).sum()
print(f"  Cells with precip > 0.001: {precip_cells} ({100*precip_cells/len(all_df):.2f}%)")

# Vapor and convergence
w_vapor = all_df['weather_vapor_arr']
w_conv = all_df['weather_convergence_arr']
w_instab = all_df['weather_instability_arr']
print(f"\nAtmospheric moisture:")
print(f"  vapor: mean={w_vapor.mean():.4f}, range=[{w_vapor.min():.4f}, {w_vapor.max():.4f}]")
print(f"  convergence: mean={w_conv.mean():.4f}, range=[{w_conv.min():.4f}, {w_conv.max():.4f}]")
print(f"  instability: mean={w_instab.mean():.4f}, range=[{w_instab.min():.4f}, {w_instab.max():.4f}]")

# Weather field init
w_init = all_df['weather_field_init_arr']
print(f"\nWeather field init flag:")
init_count = (w_init == 1).sum()
print(f"  Initialized cells: {init_count} ({100*init_count/len(all_df):.2f}%)")

# Weather by latitude
print(f"\nWeather by latitude band:")
for band in ['90S-54S', '54S-27S', '27S-0', '0-27N', '27N-54N', '54N-90N']:
    b = all_df[all_df['lat_band'] == band]
    if len(b) == 0:
        continue
    print(f"  {band}: precip={b['weather_precip_arr'].mean():.6f}, "
          f"cloud={b['weather_cloud_arr'].mean():.3f}, "
          f"vapor={b['weather_vapor_arr'].mean():.3f}, "
          f"conv={b['weather_convergence_arr'].mean():.4f}, "
          f"instab={b['weather_instability_arr'].mean():.4f}")

# Moisture
print(f"\nGround moisture (land cells):")
land_df = all_df[land_mask]
l_moisture = land_df['moisture_arr']
l_moisture_prev = land_df['moisture_arr_prev']
l_soil = land_df['soil_moisture_arr']
print(f"  moisture_arr: mean={l_moisture.mean():.4f}, range=[{l_moisture.min():.4f}, {l_moisture.max():.4f}]")
print(f"  moisture_arr_prev: mean={l_moisture_prev.mean():.4f}")
print(f"  soil_moisture_arr: mean={l_soil.mean():.4f}, range=[{l_soil.min():.4f}, {l_soil.max():.4f}]")

# Snow cover
snow = all_df['snow_cover_arr']
snow_prev = all_df['snow_cover_arr_prev']
snowpack = all_df['snowpack_arr']
print(f"\nSnow cover:")
print(f"  snow_cover: mean={snow.mean():.4f}, range=[{snow.min():.4f}, {snow.max():.4f}]")
print(f"  snow_cover_prev: mean={snow_prev.mean():.4f}")
print(f"  snowpack: mean={snowpack.mean():.4f}, range=[{snowpack.min():.4f}, {snowpack.max():.4f}]")
snow_cells = (snow > 0.01).sum()
print(f"  Cells with snow > 0.01: {snow_cells} ({100*snow_cells/len(all_df):.2f}%)")

# Snow by latitude
print(f"\nSnow cover by latitude:")
for band in ['90S-54S', '54S-27S', '27S-0', '0-27N', '27N-54N', '54N-90N']:
    b = all_df[all_df['lat_band'] == band]
    if len(b) == 0:
        continue
    snow_b = b['snow_cover_arr']
    snow_cells_b = (snow_b > 0.01).sum()
    print(f"  {band}: mean_snow={snow_b.mean():.4f}, snow_cells={snow_cells_b}/{len(b)}, temp={b['temp_arr'].mean():.2f}")

# ── 5. VEGETATION ──
print("\n" + "="*60)
print("5. VEGETATION & STRESS ANALYSIS")
print("="*60)

v_vitality = land_df['vegetation_vitality_arr']
v_low = land_df['vitality_low_streak_arr']
v_high = land_df['vitality_high_streak_arr']
v_heat = land_df['vegetation_heat_stress_arr']
v_drought = land_df['vegetation_drought_stress_arr']
v_cold = land_df['vegetation_cold_stress_arr']
v_regen = land_df['vegetation_regen_score_arr']
v_pressure = land_df['vegetation_growth_pressure_arr']
wb_30d = land_df['water_balance_30d_arr']

print(f"Vegetation vitality: mean={v_vitality.mean():.4f}, range=[{v_vitality.min():.4f}, {v_vitality.max():.4f}]")
print(f"Growth pressure: mean={v_pressure.mean():.4f}, range=[{v_pressure.min():.4f}, {v_pressure.max():.4f}]")
print(f"Water balance 30d: mean={wb_30d.mean():.4f}, range=[{wb_30d.min():.4f}, {wb_30d.max():.4f}]")
print(f"Heat stress: mean={v_heat.mean():.4f}, max={v_heat.max():.4f}")
print(f"Drought stress: mean={v_drought.mean():.4f}, max={v_drought.max():.4f}")
print(f"Cold stress: mean={v_cold.mean():.4f}, max={v_cold.max():.4f}")
print(f"Regen score: mean={v_regen.mean():.4f}, max={v_regen.max():.4f}")

# ── 6. CROSS-CORRELATIONS ──
print("\n" + "="*60)
print("6. KEY CORRELATIONS")
print("="*60)

# We'll compute correlations on a subsample to be fast
sub = all_df[['cell_lat_norm_arr', 'temp_arr', 'temp_baseline_arr', 'temp_anomaly_arr',
    'sea_ice_frac_arr', 'insolation_now_arr', 'insolation_dev_arr', 'elevation_arr',
    'weather_precip_arr', 'weather_cloud_arr', 'weather_vapor_arr',
    'wind_speed', 'slp_arr', 'moisture_arr']].copy()
sub = sub.dropna()

corr = sub.corr()
print("Temperature vs latitude correlation:")
print(f"  corr(temp, |lat|): {sub['temp_arr'].corr(sub['cell_lat_norm_arr'].abs()):.4f}")
print(f"  corr(temp_baseline, |lat|): {sub['temp_baseline_arr'].corr(sub['cell_lat_norm_arr'].abs()):.4f}")
print(f"  corr(insolation, |lat|): {sub['insolation_now_arr'].corr(sub['cell_lat_norm_arr'].abs()):.4f}")

print(f"\nTemperature vs elevation:")
print(f"  corr(temp, elevation): {sub['temp_arr'].corr(sub['elevation_arr']):.4f}")

print(f"\nPrecip vs vapor:")
print(f"  corr(precip, vapor): {sub['weather_precip_arr'].corr(sub['weather_vapor_arr']):.4f}")

print(f"\nTemp vs sea ice:")
print(f"  corr(temp, sea_ice): {sub['temp_arr'].corr(sub['sea_ice_frac_arr']):.4f}")

print(f"\nWind vs SLP:")
print(f"  corr(wind_speed, SLP): {sub['wind_speed'].corr(sub['slp_arr']):.4f}")

# ── 7. PROFILE PARAMETER CHECKS ──
print("\n" + "="*60)
print("7. PROFILE / SOURCE CODE CROSS-REFERENCE")
print("="*60)
print("(Reading source files for parameter comparison...)")

# Save summary to file
summary_path = os.path.join(OUT_DIR, "climate_analysis_summary.txt")
with open(summary_path, 'w', encoding='utf-8') as f:
    f.write(f"Climate Analysis Summary - Tick {tick_val}\n")
    f.write(f"Sample rate: 1/{sample_rate}\n")
    f.write(f"Land: {n_land}, Water: {n_water}\n\n")
    f.write("Global flags:\n")
    for col in ['climate_max_temp_delta', 'climate_p99_temp_delta', 'climate_max_transport_anomaly',
                'climate_sea_ice_delta_max', 'climate_precip_p95', 'climate_thermal_finalizer_applied']:
        f.write(f"  {col}: {df[col].iloc[0]}\n")

print(f"\nAnalysis saved to: {summary_path}")
print("Done.")
