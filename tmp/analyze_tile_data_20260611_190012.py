import csv
import hashlib
import json
import math
import sys
import time
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np
import pandas as pd


CSV_PATH = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260611_190012.csv")
OUT_DIR = Path(r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\analysis_output")
OUT_DIR.mkdir(parents=True, exist_ok=True)
OUT_JSON = OUT_DIR / f"{CSV_PATH.stem}_analysis.json"

BASE_COLS = [
    "tick_idx", "cell_index", "q", "r", "cell_pos_x_arr", "cell_pos_y_arr",
    "cell_lat_norm_arr", "elevation_arr", "is_water_arr", "terrain_arr",
]
PHYS_COLS = [
    "phys_phase_locked", "phys_sim_day", "phys_stage", "phys_stage_name",
    "phys_next_stage", "phys_next_stage_name", "phys_path", "phys_done",
    "phys_round_active", "phys_pending_commit", "phys_need_pixel",
    "phys_run_ocean", "phys_phase_int_seen", "phys_ticks_per_slice",
    "phys_wind_period_ticks", "phys_ocean_period_ticks", "phys_slice_count",
    "phys_next_pixel_idx", "phys_total_pixels", "phys_pixel_quota",
    "phys_progress_ratio", "phys_processed_pixels", "phys_cursor_start", "phys_cursor_end",
    "phys_raster_requested_start", "phys_raster_requested_end",
    "phys_raster_returned_start", "phys_raster_returned_end",
    "phys_raster_pixels", "phys_raster_wall_ms", "phys_raster_native_ms",
    "phys_raster_used_cpp", "phys_raster_atlas_updated",
    "phys_raster_fallback_reason", "phys_raster_progress_guard_fired",
    "phys_slp_path", "phys_slp_native_ms", "phys_slp_rc_ms",
    "phys_slp_out_size", "phys_slp_published_to_slot", "phys_slp_commit_ok",
    "phys_slp_thermal_p95", "phys_slp_delta_p95", "phys_wind_cpp_done",
    "phys_wind_rc_ms", "phys_wind_wx_size", "phys_wind_wy_size",
    "phys_wind_speed_out_size", "phys_wind_map_speed_size",
    "phys_wind_commit_ok", "phys_wind_delta_p95", "phys_psi_path",
    "phys_psi_native_ms", "phys_ocean_delta_p95", "phys_thermal_current_p95",
]
FIELD_COLS = [
    "temp_arr", "temp_arr_prev", "moisture_arr", "moisture_arr_prev",
    "weather_type_arr", "weather_intensity_arr", "weather_cloud_arr",
    "weather_precip_arr", "weather_vapor_arr", "weather_convergence_arr",
    "weather_instability_arr", "wind_x_arr", "wind_y_arr", "wind_speed_arr",
    "slp_arr", "ocean_current_x_arr", "ocean_current_y_arr",
    "upwelling_strength_arr", "temperature_transport_anomaly_arr",
    "air_mass_temp_anomaly_arr", "temp_anomaly_arr", "soil_moisture_arr",
    "base_moisture_arr", "sea_ice_frac_arr", "wind_stress_curl_arr",
    "ocean_psi_arr", "climate_dirty_mask", "weather_dirty_mask",
]
CLIMATE_COLS = [
    "climate_max_temp_delta", "climate_p99_temp_delta",
    "climate_max_transport_anomaly", "climate_precip_p95",
    "climate_slp_delta_p95", "climate_wind_delta_p95",
    "climate_ocean_delta_p95", "climate_slp_abs_p95",
    "climate_wind_mag_p95", "climate_ocean_mag_p95",
    "weather_dirty_count", "water_budget_error", "active_weather_ratio",
]


class CorrAcc:
    def __init__(self):
        self.n = 0
        self.sx = 0.0
        self.sy = 0.0
        self.sxx = 0.0
        self.syy = 0.0
        self.sxy = 0.0

    def add(self, x, y, mask=None):
        x = np.asarray(x, dtype=np.float64)
        y = np.asarray(y, dtype=np.float64)
        ok = np.isfinite(x) & np.isfinite(y)
        if mask is not None:
            ok &= np.asarray(mask, dtype=bool)
        if not np.any(ok):
            return
        xv = x[ok]
        yv = y[ok]
        self.n += int(xv.size)
        self.sx += float(xv.sum())
        self.sy += float(yv.sum())
        self.sxx += float(np.dot(xv, xv))
        self.syy += float(np.dot(yv, yv))
        self.sxy += float(np.dot(xv, yv))

    def result(self):
        if self.n < 3:
            return {"n": self.n, "corr": None}
        n = float(self.n)
        cov = self.sxy - self.sx * self.sy / n
        vx = self.sxx - self.sx * self.sx / n
        vy = self.syy - self.sy * self.sy / n
        corr = None if vx <= 1e-30 or vy <= 1e-30 else cov / math.sqrt(vx * vy)
        return {"n": self.n, "corr": corr, "mean_x": self.sx / n, "mean_y": self.sy / n}


def py_value(v):
    if isinstance(v, np.generic):
        return v.item()
    if pd.isna(v):
        return None
    return v


def arr(g, col):
    return g[col].to_numpy(dtype=np.float64, copy=False)


def p95_abs(a):
    a = np.asarray(a, dtype=np.float64)
    a = np.abs(a[np.isfinite(a)])
    return 0.0 if a.size == 0 else float(np.quantile(a, 0.95))


def stats(a):
    a = np.asarray(a, dtype=np.float64)
    a = a[np.isfinite(a)]
    if a.size == 0:
        return {"n": 0}
    return {
        "n": int(a.size),
        "min": float(a.min()),
        "mean": float(a.mean()),
        "p05": float(np.quantile(a, 0.05)),
        "p50": float(np.quantile(a, 0.50)),
        "p95": float(np.quantile(a, 0.95)),
        "max": float(a.max()),
        "std": float(a.std()),
    }


def hash_float_array(a):
    b = np.asarray(a, dtype=np.float32)
    return hashlib.blake2b(b.tobytes(), digest_size=12).hexdigest()


def corr_np(x, y):
    acc = CorrAcc()
    acc.add(x, y)
    return acc.result()["corr"]


def build_neighbors(q, r):
    index_by_coord = {(int(q[i]), int(r[i])): i for i in range(len(q))}
    dirs = [(1, 0), (1, -1), (0, -1), (-1, 0), (-1, 1), (0, 1)]
    neighbors = [[] for _ in range(len(q))]
    pairs = []
    for i in range(len(q)):
        qi = int(q[i])
        ri = int(r[i])
        for dq, dr in dirs:
            j = index_by_coord.get((qi + dq, ri + dr), -1)
            if j >= 0:
                neighbors[i].append(j)
                if i < j:
                    pairs.append((i, j))
    return neighbors, np.array(pairs, dtype=np.int32)


def wind_pressure_metrics(snapshot, static):
    wx = snapshot["wind_x_arr"]
    wy = snapshot["wind_y_arr"]
    ws = snapshot["wind_speed_arr"]
    slp = snapshot["slp_arr"]
    conv = snapshot["weather_convergence_arr"]
    x = static["cell_pos_x_arr"]
    y = static["cell_pos_y_arr"]
    lat = static["cell_lat_norm_arr"]
    water = static["is_water_arr"] > 0.5
    neighbors = static["neighbors"]
    pairs = static["pairs"]

    if pairs.size > 0:
        i = pairs[:, 0]
        j = pairs[:, 1]
        denom = ws[i] * ws[j]
        ok = denom > 1e-8
        angle_cos = np.full(i.shape, np.nan, dtype=np.float64)
        angle_cos[ok] = (wx[i][ok] * wx[j][ok] + wy[i][ok] * wy[j][ok]) / denom[ok]
        speed_diff = np.abs(ws[i] - ws[j])
        neighbor_angle_cos_mean = float(np.nanmean(angle_cos))
        neighbor_angle_cos_p05 = float(np.nanquantile(angle_cos, 0.05))
        neighbor_speed_diff_mean = float(np.nanmean(speed_diff))
    else:
        neighbor_angle_cos_mean = None
        neighbor_angle_cos_p05 = None
        neighbor_speed_diff_mean = None

    n = len(wx)
    grad_x = np.full(n, np.nan, dtype=np.float64)
    grad_y = np.full(n, np.nan, dtype=np.float64)
    div = np.full(n, np.nan, dtype=np.float64)
    curl = np.full(n, np.nan, dtype=np.float64)

    for idx in range(n):
        neigh = neighbors[idx]
        if len(neigh) < 2:
            continue
        neigh = np.array(neigh, dtype=np.int32)
        dx = x[neigh] - x[idx]
        dy = y[neigh] - y[idx]
        a00 = float(np.dot(dx, dx))
        a01 = float(np.dot(dx, dy))
        a11 = float(np.dot(dy, dy))
        det = a00 * a11 - a01 * a01
        if abs(det) < 1e-12:
            continue

        def fit(values):
            b = values[neigh] - values[idx]
            bx = float(np.dot(dx, b))
            by = float(np.dot(dy, b))
            return (a11 * bx - a01 * by) / det, (-a01 * bx + a00 * by) / det

        grad_x[idx], grad_y[idx] = fit(slp)
        du_dx, du_dy = fit(wx)
        dv_dx, dv_dy = fit(wy)
        div[idx] = du_dx + dv_dy
        curl[idx] = dv_dx - du_dy

    grad_mag = np.sqrt(grad_x * grad_x + grad_y * grad_y)
    wind_mag = np.sqrt(wx * wx + wy * wy)
    denom = grad_mag * wind_mag
    ok = np.isfinite(denom) & (denom > 1e-8)
    down_dot = np.full(n, np.nan, dtype=np.float64)
    geo_abs = np.full(n, np.nan, dtype=np.float64)
    down_dot[ok] = (wx[ok] * (-grad_x[ok]) + wy[ok] * (-grad_y[ok])) / denom[ok]
    geo_abs[ok] = np.abs(wx[ok] * (-grad_y[ok]) + wy[ok] * grad_x[ok]) / denom[ok]

    bands = {}
    for lo, hi in [(0, .2), (.2, .4), (.4, .6), (.6, .8), (.8, 1.000001)]:
        mask = (lat >= lo) & (lat < hi)
        name = f"lat_{lo:.1f}_{hi:.1f}"
        bands[name] = {
            "n": int(mask.sum()),
            "wind_x_mean": float(np.nanmean(wx[mask])),
            "wind_y_mean": float(np.nanmean(wy[mask])),
            "wind_speed_mean": float(np.nanmean(ws[mask])),
            "slp_mean": float(np.nanmean(slp[mask])),
            "down_pressure_cos_mean": float(np.nanmean(down_dot[mask])),
            "isobar_abs_cos_mean": float(np.nanmean(geo_abs[mask])),
            "moisture_mean": float(np.nanmean(snapshot["moisture_arr"][mask])),
            "precip_mean": float(np.nanmean(snapshot["weather_precip_arr"][mask])),
            "temp_mean": float(np.nanmean(snapshot["temp_arr"][mask])),
        }

    return {
        "wind_x": stats(wx),
        "wind_y": stats(wy),
        "wind_speed_arr": stats(ws),
        "vector_magnitude_from_xy": stats(wind_mag),
        "wind_speed_arr_vs_xy_magnitude_corr": corr_np(ws, wind_mag),
        "slp": stats(slp),
        "neighbor_vector_cos_mean": neighbor_angle_cos_mean,
        "neighbor_vector_cos_p05": neighbor_angle_cos_p05,
        "neighbor_speed_arr_diff_mean": neighbor_speed_diff_mean,
        "pressure_gradient_mag": stats(grad_mag),
        "wind_vs_down_pressure_cos_mean": float(np.nanmean(down_dot)),
        "wind_vs_isobar_abs_cos_mean": float(np.nanmean(geo_abs)),
        "wind_speed_vs_pressure_gradient_corr": corr_np(wind_mag, grad_mag),
        "computed_divergence_abs_p95": p95_abs(div),
        "computed_curl_abs_p95": p95_abs(curl),
        "divergence_vs_weather_convergence_corr": corr_np(div, conv),
        "bands": bands,
        "water_land": {
            "water": {
                "n": int(water.sum()),
                "wind_speed_mean": float(np.nanmean(ws[water])),
                "slp_mean": float(np.nanmean(slp[water])),
                "moisture_mean": float(np.nanmean(snapshot["moisture_arr"][water])),
                "precip_mean": float(np.nanmean(snapshot["weather_precip_arr"][water])),
            },
            "land": {
                "n": int((~water).sum()),
                "wind_speed_mean": float(np.nanmean(ws[~water])),
                "slp_mean": float(np.nanmean(slp[~water])),
                "moisture_mean": float(np.nanmean(snapshot["moisture_arr"][~water])),
                "precip_mean": float(np.nanmean(snapshot["weather_precip_arr"][~water])),
            },
        },
    }


with CSV_PATH.open("r", encoding="utf-8-sig", newline="") as f:
    header = next(csv.reader(f))

requested = BASE_COLS + PHYS_COLS + FIELD_COLS + CLIMATE_COLS
usecols = [c for c in requested if c in header]
missing = [c for c in requested if c not in header]

row_count = 0
tick_stats = []
tick_diag = []
snapshot_metrics = []
field_hashes = defaultdict(set)
field_change_counts = Counter()
field_delta_summary = defaultdict(lambda: {"max": 0.0, "mean_sum": 0.0, "n": 0})
phys_stage_counter = Counter()
phys_path_counter = Counter()
phys_bool_counters = defaultdict(Counter)
phys_reason_counter = Counter()
phase_values = set()
sim_day_values = set()
raster_guard_samples = []
raster_return_mismatch_samples = []
cursor_series = []
rounds = []
current_round = None

static = None
prev_snapshot = None
first_tick = None
last_tick = None

influence_corrs = {
    "wind_speed_vs_temp": CorrAcc(),
    "wind_speed_vs_moisture": CorrAcc(),
    "wind_speed_vs_precip": CorrAcc(),
    "wind_speed_vs_cloud": CorrAcc(),
    "wind_speed_vs_vapor": CorrAcc(),
    "wind_speed_vs_convergence": CorrAcc(),
    "wind_speed_vs_temp_transport": CorrAcc(),
    "ocean_mag_vs_temp_transport": CorrAcc(),
    "upwelling_vs_temp": CorrAcc(),
    "wind_speed_prev_vs_delta_temp": CorrAcc(),
    "wind_speed_prev_vs_delta_moisture": CorrAcc(),
    "wind_speed_prev_vs_delta_precip": CorrAcc(),
    "convergence_prev_vs_delta_moisture": CorrAcc(),
    "temp_transport_prev_vs_delta_temp": CorrAcc(),
}

sample_ticks_target = 9
sample_interval = None

t0 = time.time()
for chunk in pd.read_csv(CSV_PATH, usecols=usecols, chunksize=2400 * 20, low_memory=False):
    row_count += len(chunk)
    for tick, g in chunk.groupby("tick_idx", sort=True):
        tick = int(tick)
        g = g.sort_values("cell_index")
        if first_tick is None:
            first_tick = tick
            q = g["q"].to_numpy(np.int32)
            r = g["r"].to_numpy(np.int32)
            neighbors, pairs = build_neighbors(q, r)
            static = {
                "q": q,
                "r": r,
                "cell_pos_x_arr": arr(g, "cell_pos_x_arr"),
                "cell_pos_y_arr": arr(g, "cell_pos_y_arr"),
                "cell_lat_norm_arr": arr(g, "cell_lat_norm_arr"),
                "elevation_arr": arr(g, "elevation_arr"),
                "is_water_arr": arr(g, "is_water_arr"),
                "neighbors": neighbors,
                "pairs": pairs,
            }
        last_tick = tick

        snapshot = {c: arr(g, c) for c in FIELD_COLS if c in g.columns}
        first = g.iloc[0]

        for c in FIELD_COLS:
            if c in snapshot:
                field_hashes[c].add(hash_float_array(snapshot[c]))

        if prev_snapshot is not None:
            for c in FIELD_COLS:
                if c in snapshot and c in prev_snapshot:
                    d = np.abs(snapshot[c] - prev_snapshot[c])
                    finite = d[np.isfinite(d)]
                    if finite.size:
                        m = float(finite.max())
                        mean = float(finite.mean())
                        if m > 1e-12:
                            field_change_counts[c] += 1
                        item = field_delta_summary[c]
                        item["max"] = max(item["max"], m)
                        item["mean_sum"] += mean
                        item["n"] += 1

            influence_corrs["wind_speed_prev_vs_delta_temp"].add(
                prev_snapshot["wind_speed_arr"], snapshot["temp_arr"] - prev_snapshot["temp_arr"])
            influence_corrs["wind_speed_prev_vs_delta_moisture"].add(
                prev_snapshot["wind_speed_arr"], snapshot["moisture_arr"] - prev_snapshot["moisture_arr"])
            influence_corrs["wind_speed_prev_vs_delta_precip"].add(
                prev_snapshot["wind_speed_arr"], snapshot["weather_precip_arr"] - prev_snapshot["weather_precip_arr"])
            influence_corrs["convergence_prev_vs_delta_moisture"].add(
                prev_snapshot["weather_convergence_arr"], snapshot["moisture_arr"] - prev_snapshot["moisture_arr"])
            influence_corrs["temp_transport_prev_vs_delta_temp"].add(
                prev_snapshot["temperature_transport_anomaly_arr"], snapshot["temp_arr"] - prev_snapshot["temp_arr"])

        ocean_mag = np.sqrt(snapshot["ocean_current_x_arr"] ** 2 + snapshot["ocean_current_y_arr"] ** 2)
        influence_corrs["wind_speed_vs_temp"].add(snapshot["wind_speed_arr"], snapshot["temp_arr"])
        influence_corrs["wind_speed_vs_moisture"].add(snapshot["wind_speed_arr"], snapshot["moisture_arr"])
        influence_corrs["wind_speed_vs_precip"].add(snapshot["wind_speed_arr"], snapshot["weather_precip_arr"])
        influence_corrs["wind_speed_vs_cloud"].add(snapshot["wind_speed_arr"], snapshot["weather_cloud_arr"])
        influence_corrs["wind_speed_vs_vapor"].add(snapshot["wind_speed_arr"], snapshot["weather_vapor_arr"])
        influence_corrs["wind_speed_vs_convergence"].add(snapshot["wind_speed_arr"], snapshot["weather_convergence_arr"])
        influence_corrs["wind_speed_vs_temp_transport"].add(snapshot["wind_speed_arr"], snapshot["temperature_transport_anomaly_arr"])
        influence_corrs["ocean_mag_vs_temp_transport"].add(ocean_mag, snapshot["temperature_transport_anomaly_arr"])
        influence_corrs["upwelling_vs_temp"].add(snapshot["upwelling_strength_arr"], snapshot["temp_arr"])

        stage_name = str(first.get("phys_stage_name", ""))
        path = str(first.get("phys_path", ""))
        phys_stage_counter[stage_name] += 1
        phys_path_counter[path] += 1
        for b in [
            "phys_done", "phys_round_active", "phys_pending_commit", "phys_need_pixel",
            "phys_run_ocean", "phys_slp_commit_ok", "phys_wind_commit_ok",
            "phys_raster_used_cpp", "phys_raster_atlas_updated",
            "phys_raster_progress_guard_fired",
        ]:
            if b in g.columns:
                phys_bool_counters[b][str(bool(first.get(b)))] += 1
        reason = str(first.get("phys_raster_fallback_reason", ""))
        if reason:
            phys_reason_counter[reason] += 1
        if "phys_phase_locked" in g.columns:
            phase_values.add(round(float(first.get("phys_phase_locked", 0.0)), 6))
        if "phys_sim_day" in g.columns:
            sim_day_values.add(int(first.get("phys_sim_day", -1)))

        diag = {
            "tick_idx": tick,
            "phys_phase_locked": py_value(first.get("phys_phase_locked", None)),
            "phys_sim_day": py_value(first.get("phys_sim_day", None)),
            "phys_stage_name": stage_name,
            "phys_path": path,
            "phys_done": bool(first.get("phys_done", False)),
            "phys_pending_commit": bool(first.get("phys_pending_commit", False)),
            "phys_next_pixel_idx": py_value(first.get("phys_next_pixel_idx", None)),
            "phys_total_pixels": py_value(first.get("phys_total_pixels", None)),
            "phys_pixel_quota": py_value(first.get("phys_pixel_quota", None)),
            "phys_progress_ratio": py_value(first.get("phys_progress_ratio", None)),
            "phys_processed_pixels": py_value(first.get("phys_processed_pixels", None)),
            "phys_cursor_start": py_value(first.get("phys_cursor_start", None)),
            "phys_cursor_end": py_value(first.get("phys_cursor_end", None)),
            "phys_raster_requested_start": py_value(first.get("phys_raster_requested_start", None)),
            "phys_raster_requested_end": py_value(first.get("phys_raster_requested_end", None)),
            "phys_raster_returned_start": py_value(first.get("phys_raster_returned_start", None)),
            "phys_raster_returned_end": py_value(first.get("phys_raster_returned_end", None)),
            "phys_raster_pixels": py_value(first.get("phys_raster_pixels", None)),
            "phys_raster_used_cpp": bool(first.get("phys_raster_used_cpp", False)),
            "phys_raster_progress_guard_fired": bool(first.get("phys_raster_progress_guard_fired", False)),
            "phys_raster_fallback_reason": reason,
            "climate_wind_delta_p95": py_value(first.get("climate_wind_delta_p95", None)),
            "climate_ocean_delta_p95": py_value(first.get("climate_ocean_delta_p95", None)),
            "climate_slp_delta_p95": py_value(first.get("climate_slp_delta_p95", None)),
            "climate_wind_mag_p95": py_value(first.get("climate_wind_mag_p95", None)),
            "active_weather_ratio": py_value(first.get("active_weather_ratio", None)),
        }
        tick_diag.append(diag)
        cursor_series.append({
            "tick_idx": tick,
            "stage_name": stage_name,
            "next_pixel_idx": diag["phys_next_pixel_idx"],
            "total_pixels": diag["phys_total_pixels"],
            "progress_ratio": diag["phys_progress_ratio"],
            "processed_pixels": diag["phys_processed_pixels"],
            "used_cpp": diag["phys_raster_used_cpp"],
            "guard": diag["phys_raster_progress_guard_fired"],
            "reason": reason,
        })
        if diag["phys_raster_progress_guard_fired"] and len(raster_guard_samples) < 20:
            raster_guard_samples.append(diag)
        if (diag["phys_raster_used_cpp"]
                and diag["phys_raster_returned_start"] != diag["phys_raster_requested_start"]
                and len(raster_return_mismatch_samples) < 20):
            raster_return_mismatch_samples.append(diag)

        npx = diag["phys_next_pixel_idx"]
        total = diag["phys_total_pixels"]
        if stage_name in ("phys_slp", "phys_wind", "phys_psi_init", "phys_upwelling") or current_round is None:
            if current_round is None or (npx == 0 and stage_name != "ocean_pixel_slice"):
                if current_round is not None:
                    rounds.append(current_round)
                current_round = {
                    "start_tick": tick,
                    "end_tick": tick,
                    "max_progress": 0.0,
                    "max_next_pixel_idx": 0,
                    "total_pixels": total,
                    "stages": Counter(),
                    "guard_count": 0,
                    "commit_seen": False,
                    "raster_done_seen": False,
                }
        if current_round is not None:
            current_round["end_tick"] = tick
            current_round["max_progress"] = max(current_round["max_progress"], float(diag["phys_progress_ratio"] or 0.0))
            current_round["max_next_pixel_idx"] = max(current_round["max_next_pixel_idx"], int(npx or 0))
            current_round["stages"][stage_name] += 1
            current_round["guard_count"] += 1 if diag["phys_raster_progress_guard_fired"] else 0
            current_round["commit_seen"] = current_round["commit_seen"] or (stage_name == "ocean_pixel_commit_deferred")
            current_round["raster_done_seen"] = current_round["raster_done_seen"] or (stage_name == "ocean_pixel_raster_done")

        if sample_interval is None and first_tick is not None:
            sample_interval = 240
        should_sample = (
            len(snapshot_metrics) == 0
            or tick == last_tick
            or (sample_interval and (tick - first_tick) % sample_interval == 0)
        )
        if should_sample and len(snapshot_metrics) < sample_ticks_target:
            wm = wind_pressure_metrics(snapshot, static)
            wm["tick_idx"] = tick
            wm["stage_name"] = stage_name
            wm["phase_locked"] = diag["phys_phase_locked"]
            snapshot_metrics.append(wm)

        tick_stats.append({
            "tick_idx": tick,
            "wind_speed_mean": float(np.nanmean(snapshot["wind_speed_arr"])),
            "wind_speed_p95": float(np.nanquantile(snapshot["wind_speed_arr"], 0.95)),
            "slp_mean": float(np.nanmean(snapshot["slp_arr"])),
            "slp_p95": float(np.nanquantile(snapshot["slp_arr"], 0.95)),
            "ocean_mag_mean": float(np.nanmean(ocean_mag)),
            "temp_mean": float(np.nanmean(snapshot["temp_arr"])),
            "moisture_mean": float(np.nanmean(snapshot["moisture_arr"])),
            "precip_mean": float(np.nanmean(snapshot["weather_precip_arr"])),
            "temp_transport_mean": float(np.nanmean(snapshot["temperature_transport_anomaly_arr"])),
        })
        prev_snapshot = snapshot

if current_round is not None:
    rounds.append(current_round)

field_delta_out = {}
for k, v in field_delta_summary.items():
    n = v["n"]
    field_delta_out[k] = {
        "ticks_with_any_change": int(field_change_counts[k]),
        "adjacent_comparisons": int(n),
        "max_abs_delta": v["max"],
        "mean_abs_delta_mean": None if n == 0 else v["mean_sum"] / n,
    }

rounds_out = []
for r in rounds:
    item = dict(r)
    item["stages"] = dict(r["stages"])
    rounds_out.append(item)

out = {
    "csv": str(CSV_PATH),
    "elapsed_sec": time.time() - t0,
    "rows": row_count,
    "ticks": len(tick_diag),
    "tick_min": first_tick,
    "tick_max": last_tick,
    "missing_columns": missing,
    "field_hash_unique_counts": {k: len(v) for k, v in sorted(field_hashes.items())},
    "field_delta_summary": field_delta_out,
    "phys": {
        "phase_unique_count": len(phase_values),
        "phase_first_last": [min(phase_values), max(phase_values)] if phase_values else [],
        "sim_day_unique_count": len(sim_day_values),
        "sim_day_first_last": [min(sim_day_values), max(sim_day_values)] if sim_day_values else [],
        "stage_counts": dict(phys_stage_counter),
        "path_counts": dict(phys_path_counter),
        "bool_counts": {k: dict(v) for k, v in phys_bool_counters.items()},
        "raster_fallback_reason_counts": dict(phys_reason_counter),
        "guard_samples": raster_guard_samples,
        "return_mismatch_samples": raster_return_mismatch_samples,
        "cursor_head": cursor_series[:12],
        "cursor_tail": cursor_series[-12:],
        "rounds": rounds_out[:20],
    },
    "tick_diag_head": tick_diag[:12],
    "tick_diag_tail": tick_diag[-12:],
    "tick_stats_head": tick_stats[:12],
    "tick_stats_tail": tick_stats[-12:],
    "snapshot_metrics": snapshot_metrics,
    "influence_correlations": {k: v.result() for k, v in influence_corrs.items()},
}

OUT_JSON.write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
print(json.dumps({
    "out": str(OUT_JSON),
    "rows": out["rows"],
    "ticks": out["ticks"],
    "field_hash_unique_counts": out["field_hash_unique_counts"],
    "stage_counts": out["phys"]["stage_counts"],
    "bool_counts": out["phys"]["bool_counts"],
    "reason_counts": out["phys"]["raster_fallback_reason_counts"],
    "guard_samples": out["phys"]["guard_samples"][:3],
    "cursor_tail": out["phys"]["cursor_tail"],
}, ensure_ascii=False, indent=2))
