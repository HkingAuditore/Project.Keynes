import argparse
import json
import math
from collections import defaultdict
from pathlib import Path

import numpy as np
import pandas as pd


WT_NAMES = {
    0: "CLEAR",
    1: "RAIN",
    2: "STORM",
    3: "BLIZZARD",
    4: "DROUGHT",
    5: "FOG",
    6: "HEATWAVE",
    7: "MONSOON",
}

WET_TYPES = np.array([1, 2, 3, 7], dtype=np.int16)
DRY_TYPES = np.array([0, 4, 6], dtype=np.int16)


def qtile(a, qs):
    a = np.asarray(a)
    a = a[np.isfinite(a)]
    if a.size == 0:
        return {str(q): None for q in qs}
    vals = np.quantile(a, qs)
    return {str(q): float(v) for q, v in zip(qs, vals)}


def summary_stats(a):
    a = np.asarray(a)
    a = a[np.isfinite(a)]
    if a.size == 0:
        return {"n": 0}
    return {
        "n": int(a.size),
        "mean": float(np.mean(a)),
        "p50": float(np.quantile(a, 0.50)),
        "p75": float(np.quantile(a, 0.75)),
        "p90": float(np.quantile(a, 0.90)),
        "p95": float(np.quantile(a, 0.95)),
        "p99": float(np.quantile(a, 0.99)),
        "max": float(np.max(a)),
    }


def safe_ratio(num, den):
    return float(num) / float(den) if den else 0.0


def type_count_dict(counts):
    return {WT_NAMES.get(i, str(i)): int(counts[i]) for i in range(len(counts)) if int(counts[i]) != 0}


def band_name(lat_norm):
    lat_signed = (float(lat_norm) - 0.5) * 2.0
    a = abs(lat_signed)
    if a < 0.23:
        return "equatorial"
    if a < 0.50:
        return "subtropical"
    if a < 0.75:
        return "mid_latitude"
    return "polar"


def build_neighbors(q, r, s):
    dirs = [(1, -1, 0), (1, 0, -1), (0, 1, -1), (-1, 1, 0), (-1, 0, 1), (0, -1, 1)]
    lookup = {(int(q[i]), int(r[i]), int(s[i])): i for i in range(len(q))}
    nb = np.full((len(q), 6), -1, dtype=np.int32)
    for i in range(len(q)):
        key = (int(q[i]), int(r[i]), int(s[i]))
        for d, delta in enumerate(dirs):
            nb[i, d] = lookup.get((key[0] + delta[0], key[1] + delta[1], key[2] + delta[2]), -1)
    return nb


def temp_gradient(temp, neighbors):
    max_t = temp.copy()
    min_t = temp.copy()
    for d in range(neighbors.shape[1]):
        ni = neighbors[:, d]
        valid = ni >= 0
        vals = temp[np.where(valid, ni, np.arange(len(temp)))]
        max_t = np.maximum(max_t, vals)
        min_t = np.minimum(min_t, vals)
    return max_t - min_t


def finalize_runs(prev_type, current_type_run, duration_count, duration_sum, duration_max):
    for wt in range(8):
        mask = prev_type == wt
        if not np.any(mask):
            continue
        runs = current_type_run[mask]
        duration_count[wt] += int(runs.size)
        duration_sum[wt] += int(np.sum(runs))
        duration_max[wt] = max(duration_max[wt], int(np.max(runs)))


def analyze(csv_path: Path, out_path: Path, chunksize: int):
    usecols = [
        "tick_idx", "timestamp_ms", "was_skipped_day",
        "weather_dirty_count", "active_weather_ratio", "weather_diag_present",
        "weather_field_commit_path", "weather_refresh_convergence",
        "weather_field_solve_tick", "weather_convergence_refresh_stride",
        "weather_native_convergence_boost", "weather_convergence_dirty_count",
        "weather_convergence_delta_p95", "weather_convergence_published",
        "weather_target_mismatch_count", "weather_transitioning_count",
        "weather_transition_alpha_mean", "weather_transition_alpha_p95",
        "phys_stage_name", "phys_path", "phys_slp_delta_p95", "phys_wind_delta_p95",
        "phys_ocean_delta_p95", "phys_psi_path",
        "cell_index", "q", "r", "s",
        "temp_arr", "moisture_arr", "snow_cover_arr", "temp_baseline_arr",
        "temp_30d_arr", "temp_365d_arr", "temp_anomaly_arr",
        "weather_intensity_arr", "weather_cloud_arr", "weather_cloud_water_arr",
        "weather_precip_arr", "weather_transition_alpha_arr",
        "weather_classification_temp_arr", "weather_classification_moisture_arr",
        "weather_vapor_arr", "weather_convergence_arr", "weather_instability_arr",
        "water_balance_30d_arr", "vegetation_vitality_arr",
        "soil_moisture_arr", "vegetation_growth_pressure_arr",
        "temperature_transport_anomaly_arr", "vegetation_heat_stress_arr",
        "vegetation_drought_stress_arr", "vegetation_cold_stress_arr",
        "elevation_arr", "base_moisture_arr",
        "ocean_current_x_arr", "ocean_current_y_arr", "wind_x_arr", "wind_y_arr",
        "slp_arr", "wind_speed_arr", "upwelling_strength_arr",
        "cell_lat_norm_arr", "terrain_arr", "landform_arr", "vegetation_arr",
        "weather_type_arr", "weather_prev_type_arr", "weather_target_type_arr",
        "is_water_arr", "weather_dirty_mask",
    ]
    dtype = {
        "tick_idx": "int32", "timestamp_ms": "int64", "cell_index": "int32",
        "q": "int16", "r": "int16", "s": "int16",
        "weather_type_arr": "int16", "weather_prev_type_arr": "int16",
        "weather_target_type_arr": "int16", "is_water_arr": "int8",
        "terrain_arr": "int16", "landform_arr": "int16", "vegetation_arr": "int16",
        "weather_field_commit_path": "string", "phys_stage_name": "string", "phys_path": "string",
        "phys_psi_path": "string",
    }

    chunks = pd.read_csv(csv_path, usecols=usecols, dtype=dtype, chunksize=chunksize)
    carry = None

    n_cells = None
    static = {}
    neighbors = None
    lat_band_by_cell = None
    water_mask = None
    land_mask = None

    row_count = 0
    tick_count = 0
    min_tick = None
    max_tick = None
    tick_summaries = []
    commit_path_counts = defaultdict(int)
    convergence_true_ticks = 0
    skipped_day_ticks = 0

    type_counts_total = np.zeros(8, dtype=np.int64)
    type_counts_land = np.zeros(8, dtype=np.int64)
    type_counts_water = np.zeros(8, dtype=np.int64)
    transition_matrix = np.zeros((8, 8), dtype=np.int64)
    duration_count = np.zeros(8, dtype=np.int64)
    duration_sum = np.zeros(8, dtype=np.int64)
    duration_max = np.zeros(8, dtype=np.int64)

    prev_type_by_cell = None
    current_type_run = None
    current_wet_run = None
    current_dry_run = None
    max_wet_run = None
    max_dry_run = None
    wet_obs = None
    dry_obs = None
    significant_precip_obs = None
    no_precip_obs = None
    obs_by_cell = None
    unique_mask = None
    type_change_count = None
    sum_by_cell = None
    max_precip_by_cell = None

    global_samples = defaultdict(list)
    by_type_samples = {wt: defaultdict(list) for wt in range(8)}
    by_surface_samples = {"land": defaultdict(list), "water": defaultdict(list)}
    by_band_samples = defaultdict(lambda: defaultdict(list))
    front_tick_records = []
    cyclone_tick_records = []
    selected_tick_snapshots = {}

    numeric_cols = [
        "weather_precip_arr", "weather_cloud_arr", "weather_cloud_water_arr",
        "weather_vapor_arr", "weather_convergence_arr", "weather_instability_arr",
        "temp_arr", "moisture_arr", "soil_moisture_arr", "water_balance_30d_arr",
        "vegetation_vitality_arr", "vegetation_growth_pressure_arr",
        "vegetation_heat_stress_arr", "vegetation_drought_stress_arr",
        "vegetation_cold_stress_arr", "snow_cover_arr", "wind_speed_arr",
        "slp_arr", "temperature_transport_anomaly_arr",
    ]

    def process_tick(df):
        nonlocal n_cells, neighbors, static, lat_band_by_cell, water_mask, land_mask
        nonlocal row_count, tick_count, min_tick, max_tick, convergence_true_ticks, skipped_day_ticks
        nonlocal prev_type_by_cell, current_type_run, current_wet_run, current_dry_run
        nonlocal max_wet_run, max_dry_run, wet_obs, dry_obs, significant_precip_obs
        nonlocal no_precip_obs, obs_by_cell, unique_mask, type_change_count, sum_by_cell
        nonlocal max_precip_by_cell

        df = df.sort_values("cell_index", kind="stable")
        tick = int(df["tick_idx"].iloc[0])
        idx = df["cell_index"].to_numpy(np.int32)
        row_count += len(df)
        tick_count += 1
        min_tick = tick if min_tick is None else min(min_tick, tick)
        max_tick = tick if max_tick is None else max(max_tick, tick)

        if n_cells is None:
            n_cells = int(idx.max()) + 1
            static = {
                "q": np.full(n_cells, 0, dtype=np.int16),
                "r": np.full(n_cells, 0, dtype=np.int16),
                "s": np.full(n_cells, 0, dtype=np.int16),
                "lat": np.full(n_cells, np.nan, dtype=np.float32),
                "is_water": np.full(n_cells, 0, dtype=np.int8),
                "terrain": np.full(n_cells, 0, dtype=np.int16),
                "elevation": np.full(n_cells, np.nan, dtype=np.float32),
                "base_moisture": np.full(n_cells, np.nan, dtype=np.float32),
            }
            prev_type_by_cell = np.full(n_cells, -1, dtype=np.int16)
            current_type_run = np.zeros(n_cells, dtype=np.int32)
            current_wet_run = np.zeros(n_cells, dtype=np.int32)
            current_dry_run = np.zeros(n_cells, dtype=np.int32)
            max_wet_run = np.zeros(n_cells, dtype=np.int32)
            max_dry_run = np.zeros(n_cells, dtype=np.int32)
            wet_obs = np.zeros(n_cells, dtype=np.int32)
            dry_obs = np.zeros(n_cells, dtype=np.int32)
            significant_precip_obs = np.zeros(n_cells, dtype=np.int32)
            no_precip_obs = np.zeros(n_cells, dtype=np.int32)
            obs_by_cell = np.zeros(n_cells, dtype=np.int32)
            unique_mask = np.zeros(n_cells, dtype=np.int16)
            type_change_count = np.zeros(n_cells, dtype=np.int32)
            sum_by_cell = {c: np.zeros(n_cells, dtype=np.float64) for c in [
                "precip", "cloud", "cloud_water", "vapor", "moisture", "temp",
                "soil", "water_balance", "veg_vitality", "drought_stress",
                "heat_stress", "cold_stress",
            ]}
            max_precip_by_cell = np.zeros(n_cells, dtype=np.float32)

        static["q"][idx] = df["q"].to_numpy(np.int16)
        static["r"][idx] = df["r"].to_numpy(np.int16)
        static["s"][idx] = df["s"].to_numpy(np.int16)
        static["lat"][idx] = df["cell_lat_norm_arr"].to_numpy(np.float32)
        static["is_water"][idx] = df["is_water_arr"].to_numpy(np.int8)
        static["terrain"][idx] = df["terrain_arr"].to_numpy(np.int16)
        static["elevation"][idx] = df["elevation_arr"].to_numpy(np.float32)
        static["base_moisture"][idx] = df["base_moisture_arr"].to_numpy(np.float32)
        if neighbors is None and len(df) == n_cells:
            neighbors = build_neighbors(static["q"], static["r"], static["s"])
            water_mask = static["is_water"].astype(bool)
            land_mask = ~water_mask
            lat_band_by_cell = np.array([band_name(x) for x in static["lat"]], dtype=object)

        wt = np.clip(df["weather_type_arr"].to_numpy(np.int16), 0, 7)
        precip = df["weather_precip_arr"].to_numpy(np.float32)
        cloud = df["weather_cloud_arr"].to_numpy(np.float32)
        cloud_water = df["weather_cloud_water_arr"].to_numpy(np.float32)
        vapor = df["weather_vapor_arr"].to_numpy(np.float32)
        convergence = df["weather_convergence_arr"].to_numpy(np.float32)
        instability = df["weather_instability_arr"].to_numpy(np.float32)
        temp = df["temp_arr"].to_numpy(np.float32)
        moisture = df["moisture_arr"].to_numpy(np.float32)
        wind_speed = df["wind_speed_arr"].to_numpy(np.float32)
        slp = df["slp_arr"].to_numpy(np.float32)
        ocean_an = df["temperature_transport_anomaly_arr"].to_numpy(np.float32)
        is_water = df["is_water_arr"].to_numpy(np.int8).astype(bool)
        is_land = ~is_water

        counts = np.bincount(wt, minlength=8).astype(np.int64)
        type_counts_total[:] += counts
        type_counts_land[:] += np.bincount(wt[is_land], minlength=8)
        type_counts_water[:] += np.bincount(wt[is_water], minlength=8)

        wet = np.isin(wt, WET_TYPES)
        dry = np.isin(wt, DRY_TYPES) & (precip < 0.003)
        significant = precip >= 0.03
        no_precip = precip < 0.003
        obs_by_cell[idx] += 1
        wet_obs[idx] += wet.astype(np.int32)
        dry_obs[idx] += dry.astype(np.int32)
        significant_precip_obs[idx] += significant.astype(np.int32)
        no_precip_obs[idx] += no_precip.astype(np.int32)
        max_precip_by_cell[idx] = np.maximum(max_precip_by_cell[idx], precip)
        for c, arr in [
            ("precip", precip), ("cloud", cloud), ("cloud_water", cloud_water),
            ("vapor", vapor), ("moisture", moisture), ("temp", temp),
            ("soil", df["soil_moisture_arr"].to_numpy(np.float32)),
            ("water_balance", df["water_balance_30d_arr"].to_numpy(np.float32)),
            ("veg_vitality", df["vegetation_vitality_arr"].to_numpy(np.float32)),
            ("drought_stress", df["vegetation_drought_stress_arr"].to_numpy(np.float32)),
            ("heat_stress", df["vegetation_heat_stress_arr"].to_numpy(np.float32)),
            ("cold_stress", df["vegetation_cold_stress_arr"].to_numpy(np.float32)),
        ]:
            sum_by_cell[c][idx] += arr
        unique_mask[idx] |= (1 << wt).astype(np.int16)

        prev = prev_type_by_cell[idx]
        has_prev = prev >= 0
        if np.any(has_prev):
            np.add.at(transition_matrix, (prev[has_prev], wt[has_prev]), 1)
            changed = has_prev & (prev != wt)
            type_change_count[idx[changed]] += 1
            ended = changed
            if np.any(ended):
                ended_prev = prev[ended]
                ended_runs = current_type_run[idx[ended]]
                for t in range(8):
                    runs = ended_runs[ended_prev == t]
                    if runs.size:
                        duration_count[t] += int(runs.size)
                        duration_sum[t] += int(np.sum(runs))
                        duration_max[t] = max(duration_max[t], int(np.max(runs)))
        same = has_prev & (prev == wt)
        new_or_changed = ~same
        current_type_run[idx[same]] += 1
        current_type_run[idx[new_or_changed]] = 1
        prev_type_by_cell[idx] = wt

        current_wet_run[idx[wet]] += 1
        current_wet_run[idx[~wet]] = 0
        max_wet_run[idx] = np.maximum(max_wet_run[idx], current_wet_run[idx])
        current_dry_run[idx[dry]] += 1
        current_dry_run[idx[~dry]] = 0
        max_dry_run[idx] = np.maximum(max_dry_run[idx], current_dry_run[idx])

        first = df.iloc[0]
        commit_path = str(first.get("weather_field_commit_path", ""))
        commit_path_counts[commit_path] += 1
        if str(first.get("weather_refresh_convergence", "false")).lower() == "true":
            convergence_true_ticks += 1
        if str(first.get("was_skipped_day", "false")).lower() == "true":
            skipped_day_ticks += 1

        lat_bands = {}
        if lat_band_by_cell is not None:
            bands_for_tick = lat_band_by_cell[idx]
            for b in sorted(set(bands_for_tick)):
                bm = bands_for_tick == b
                lat_bands[b] = {
                    "n": int(np.sum(bm)),
                    "wet_ratio": safe_ratio(int(np.sum(wet[bm])), int(np.sum(bm))),
                    "significant_precip_ratio": safe_ratio(int(np.sum(significant[bm])), int(np.sum(bm))),
                    "type_counts": type_count_dict(np.bincount(wt[bm], minlength=8)),
                    "precip_mean": float(np.mean(precip[bm])) if np.any(bm) else 0.0,
                    "cloud_mean": float(np.mean(cloud[bm])) if np.any(bm) else 0.0,
                    "temp_mean": float(np.mean(temp[bm])) if np.any(bm) else 0.0,
                }

        tick_record = {
            "tick": tick,
            "rows": int(len(df)),
            "commit_path": commit_path,
            "active_weather_ratio": float(first.get("active_weather_ratio", 0.0)),
            "weather_dirty_count": int(first.get("weather_dirty_count", 0)),
            "transitioning_count": int(first.get("weather_transitioning_count", 0)),
            "type_counts": type_count_dict(counts),
            "land_counts": type_count_dict(np.bincount(wt[is_land], minlength=8)),
            "water_counts": type_count_dict(np.bincount(wt[is_water], minlength=8)),
            "wet_ratio": safe_ratio(int(np.sum(wet)), len(df)),
            "significant_precip_ratio": safe_ratio(int(np.sum(significant)), len(df)),
            "fog_ratio": safe_ratio(int(np.sum(wt == 5)), len(df)),
            "clear_ratio": safe_ratio(int(np.sum(wt == 0)), len(df)),
            "precip": summary_stats(precip),
            "cloud": summary_stats(cloud),
            "cloud_water": summary_stats(cloud_water),
            "vapor": summary_stats(vapor),
            "land_precip": summary_stats(precip[is_land]),
            "water_precip": summary_stats(precip[is_water]),
            "land_cloud": summary_stats(cloud[is_land]),
            "water_cloud": summary_stats(cloud[is_water]),
            "lat_bands": lat_bands,
        }
        tick_summaries.append(tick_record)

        for col, arr in [
            ("precip", precip), ("cloud", cloud), ("cloud_water", cloud_water),
            ("vapor", vapor), ("convergence", convergence), ("instability", instability),
            ("temp", temp), ("moisture", moisture), ("soil", df["soil_moisture_arr"].to_numpy(np.float32)),
            ("water_balance", df["water_balance_30d_arr"].to_numpy(np.float32)),
            ("veg_vitality", df["vegetation_vitality_arr"].to_numpy(np.float32)),
            ("drought_stress", df["vegetation_drought_stress_arr"].to_numpy(np.float32)),
            ("wind_speed", wind_speed), ("slp", slp), ("ocean_an", ocean_an),
        ]:
            global_samples[col].append(arr)
            by_surface_samples["land"][col].append(arr[is_land])
            by_surface_samples["water"][col].append(arr[is_water])
            for t in range(8):
                m = wt == t
                if np.any(m):
                    by_type_samples[t][col].append(arr[m])
            if lat_band_by_cell is not None:
                bands_for_tick = lat_band_by_cell[idx]
                for b in sorted(set(bands_for_tick)):
                    bm = bands_for_tick == b
                    by_band_samples[b][col].append(arr[bm])

        if neighbors is not None:
            full_temp = np.full(n_cells, np.nan, dtype=np.float32)
            full_conv = np.full(n_cells, 0.0, dtype=np.float32)
            full_cloud = np.full(n_cells, 0.0, dtype=np.float32)
            full_precip = np.full(n_cells, 0.0, dtype=np.float32)
            full_wt = np.full(n_cells, 0, dtype=np.int16)
            full_water = static["is_water"].astype(bool)
            full_temp[idx] = temp
            full_conv[idx] = convergence
            full_cloud[idx] = cloud
            full_precip[idx] = precip
            full_wt[idx] = wt
            grad = temp_gradient(full_temp, neighbors)
            front = (full_conv > 0.10) & (grad > 0.08) & (full_cloud > 0.15)
            wet_full = np.isin(full_wt, WET_TYPES)
            front_tick_records.append({
                "tick": tick,
                "front_candidate_count": int(np.sum(front)),
                "front_candidate_ratio": safe_ratio(int(np.sum(front)), n_cells),
                "front_wet_overlap_ratio": safe_ratio(int(np.sum(front & wet_full)), int(np.sum(front))),
                "front_grad_p95": float(np.quantile(grad[np.isfinite(grad)], 0.95)),
                "front_conv_p95": float(np.quantile(full_conv, 0.95)),
            })
            warm_ocean = full_water & (full_temp > 0.55)
            storm = full_wt == 2
            monsoon = full_wt == 7
            cyclone_like = warm_ocean & storm & (full_precip > 0.04) & (full_cloud > 0.28)
            cyclone_tick_records.append({
                "tick": tick,
                "storm_count": int(np.sum(storm)),
                "water_storm_count": int(np.sum(storm & full_water)),
                "cyclone_like_count": int(np.sum(cyclone_like)),
                "monsoon_count": int(np.sum(monsoon)),
                "water_monsoon_count": int(np.sum(monsoon & full_water)),
                "warm_ocean_count": int(np.sum(warm_ocean)),
            })
            if tick_count in (1, 2, 5) or tick % 50 == 0:
                selected_tick_snapshots[str(tick)] = {
                    "front_candidate_count": int(np.sum(front)),
                    "cyclone_like_count": int(np.sum(cyclone_like)),
                    "storm_count": int(np.sum(storm)),
                    "monsoon_count": int(np.sum(monsoon)),
                }

    for chunk in chunks:
        if carry is not None:
            chunk = pd.concat([carry, chunk], ignore_index=True)
            carry = None
        ticks = chunk["tick_idx"].to_numpy()
        last_tick = ticks[-1]
        split = len(chunk)
        while split > 0 and ticks[split - 1] == last_tick:
            split -= 1
        complete = chunk.iloc[:split]
        carry = chunk.iloc[split:].copy()
        if not complete.empty:
            for _, g in complete.groupby("tick_idx", sort=True):
                process_tick(g)
    if carry is not None and not carry.empty:
        for _, g in carry.groupby("tick_idx", sort=True):
            process_tick(g)

    if prev_type_by_cell is not None:
        finalize_runs(prev_type_by_cell, current_type_run, duration_count, duration_sum, duration_max)

    def concat_stats(samples):
        out = {}
        for k, parts in samples.items():
            if not parts:
                out[k] = {"n": 0}
            else:
                out[k] = summary_stats(np.concatenate(parts))
        return out

    global_stats = concat_stats(global_samples)
    type_stats = {WT_NAMES[t]: concat_stats(by_type_samples[t]) for t in range(8)}
    surface_stats = {k: concat_stats(v) for k, v in by_surface_samples.items()}
    band_stats = {b: concat_stats(v) for b, v in by_band_samples.items()}

    obs = np.maximum(obs_by_cell, 1)
    wet_frac = wet_obs / obs
    sig_frac = significant_precip_obs / obs
    no_precip_frac = no_precip_obs / obs
    unique_count = np.array([int(bin(int(m)).count("1")) for m in unique_mask], dtype=np.int16)
    mean_by_cell = {k: v / obs for k, v in sum_by_cell.items()}
    eternal_wet = wet_frac >= 0.90
    persistent_wet = wet_frac >= 0.60
    never_significant_rain = significant_precip_obs == 0
    persistent_dry = no_precip_frac >= 0.90
    low_moisture = mean_by_cell["moisture"] < 0.18
    eternal_dry = persistent_dry & never_significant_rain & low_moisture

    lifecycle = {
        "wet_fraction": summary_stats(wet_frac),
        "significant_precip_fraction": summary_stats(sig_frac),
        "no_precip_fraction": summary_stats(no_precip_frac),
        "unique_weather_types_per_cell": summary_stats(unique_count),
        "type_changes_per_cell": summary_stats(type_change_count),
        "max_consecutive_wet_ticks": summary_stats(max_wet_run),
        "max_consecutive_dry_ticks": summary_stats(max_dry_run),
        "persistent_wet_cells_ge_60pct": int(np.sum(persistent_wet)),
        "eternal_wet_cells_ge_90pct": int(np.sum(eternal_wet)),
        "persistent_dry_cells_no_precip_ge_90pct": int(np.sum(persistent_dry)),
        "eternal_dry_low_moisture_cells": int(np.sum(eternal_dry)),
        "never_significant_rain_cells": int(np.sum(never_significant_rain)),
    }
    lifecycle_by_surface = {}
    for name, mask in [("land", land_mask), ("water", water_mask)]:
        if mask is None:
            continue
        lifecycle_by_surface[name] = {
            "cells": int(np.sum(mask)),
            "wet_fraction": summary_stats(wet_frac[mask]),
            "significant_precip_fraction": summary_stats(sig_frac[mask]),
            "no_precip_fraction": summary_stats(no_precip_frac[mask]),
            "unique_weather_types_per_cell": summary_stats(unique_count[mask]),
            "persistent_wet_cells_ge_60pct": int(np.sum(persistent_wet & mask)),
            "eternal_wet_cells_ge_90pct": int(np.sum(eternal_wet & mask)),
            "eternal_dry_low_moisture_cells": int(np.sum(eternal_dry & mask)),
            "never_significant_rain_cells": int(np.sum(never_significant_rain & mask)),
        }

    run_duration = {}
    for t in range(8):
        cnt = int(duration_count[t])
        run_duration[WT_NAMES[t]] = {
            "runs": cnt,
            "mean_ticks": safe_ratio(int(duration_sum[t]), cnt),
            "max_ticks": int(duration_max[t]),
        }

    last_tick = tick_summaries[-1] if tick_summaries else {}
    first_tick = tick_summaries[0] if tick_summaries else {}
    window = tick_summaries[-min(30, len(tick_summaries)):]
    recent = {
        "ticks": len(window),
        "mean_wet_ratio": float(np.mean([x["wet_ratio"] for x in window])) if window else None,
        "mean_significant_precip_ratio": float(np.mean([x["significant_precip_ratio"] for x in window])) if window else None,
        "mean_fog_ratio": float(np.mean([x["fog_ratio"] for x in window])) if window else None,
        "mean_clear_ratio": float(np.mean([x["clear_ratio"] for x in window])) if window else None,
    }

    front_summary = {
        "front_candidate_count": summary_stats([x["front_candidate_count"] for x in front_tick_records]),
        "front_candidate_ratio": summary_stats([x["front_candidate_ratio"] for x in front_tick_records]),
        "front_wet_overlap_ratio": summary_stats([x["front_wet_overlap_ratio"] for x in front_tick_records if x["front_candidate_count"] > 0]),
        "front_grad_p95": summary_stats([x["front_grad_p95"] for x in front_tick_records]),
        "front_conv_p95": summary_stats([x["front_conv_p95"] for x in front_tick_records]),
    }
    cyclone_summary = {
        "storm_count": summary_stats([x["storm_count"] for x in cyclone_tick_records]),
        "water_storm_count": summary_stats([x["water_storm_count"] for x in cyclone_tick_records]),
        "cyclone_like_count": summary_stats([x["cyclone_like_count"] for x in cyclone_tick_records]),
        "monsoon_count": summary_stats([x["monsoon_count"] for x in cyclone_tick_records]),
        "water_monsoon_count": summary_stats([x["water_monsoon_count"] for x in cyclone_tick_records]),
        "warm_ocean_count": summary_stats([x["warm_ocean_count"] for x in cyclone_tick_records]),
    }

    corr_fields = ["precip", "cloud", "vapor", "moisture", "soil", "water_balance", "veg_vitality", "drought_stress", "heat_stress", "cold_stress"]
    corr = {}
    for a, b in [
        ("precip", "soil"),
        ("precip", "water_balance"),
        ("precip", "veg_vitality"),
        ("precip", "drought_stress"),
        ("cloud", "precip"),
        ("vapor", "cloud"),
        ("moisture", "veg_vitality"),
        ("water_balance", "veg_vitality"),
    ]:
        x = mean_by_cell[a]
        y = mean_by_cell[b]
        finite = np.isfinite(x) & np.isfinite(y)
        corr[f"{a}_vs_{b}"] = float(np.corrcoef(x[finite], y[finite])[0, 1]) if np.sum(finite) > 2 else None

    result = {
        "source": str(csv_path),
        "file_size_bytes": csv_path.stat().st_size,
        "rows": int(row_count),
        "ticks": int(tick_count),
        "min_tick": int(min_tick) if min_tick is not None else None,
        "max_tick": int(max_tick) if max_tick is not None else None,
        "n_cells": int(n_cells) if n_cells is not None else None,
        "commit_path_counts": dict(commit_path_counts),
        "convergence_true_ticks": int(convergence_true_ticks),
        "skipped_day_ticks": int(skipped_day_ticks),
        "total_type_counts": type_count_dict(type_counts_total),
        "land_type_counts": type_count_dict(type_counts_land),
        "water_type_counts": type_count_dict(type_counts_water),
        "first_tick": first_tick,
        "last_tick": last_tick,
        "recent_30_tick_summary": recent,
        "global_stats": global_stats,
        "surface_stats": surface_stats,
        "type_stats": type_stats,
        "band_stats": band_stats,
        "lifecycle": lifecycle,
        "lifecycle_by_surface": lifecycle_by_surface,
        "transition_matrix": {
            WT_NAMES[i]: {WT_NAMES[j]: int(transition_matrix[i, j]) for j in range(8) if int(transition_matrix[i, j])}
            for i in range(8)
        },
        "run_duration_by_type": run_duration,
        "front_proxy": front_summary,
        "cyclone_monsoon_proxy": cyclone_summary,
        "cell_mean_correlations": corr,
        "selected_tick_snapshots": selected_tick_snapshots,
    }
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("csv")
    parser.add_argument("--out", default="tmp/weather_analysis_summary.json")
    parser.add_argument("--chunksize", type=int, default=200000)
    args = parser.parse_args()
    result = analyze(Path(args.csv), Path(args.out), args.chunksize)
    print(json.dumps({
        "source": result["source"],
        "rows": result["rows"],
        "ticks": result["ticks"],
        "min_tick": result["min_tick"],
        "max_tick": result["max_tick"],
        "n_cells": result["n_cells"],
        "last_tick_counts": result["last_tick"].get("type_counts", {}),
        "lifecycle": result["lifecycle"],
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
