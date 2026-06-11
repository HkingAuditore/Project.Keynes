import csv
import hashlib
import json
import math
import time
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np
import pandas as pd


CSV_PATH = Path(r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260611_163535.csv")
OUT_DIR = Path(r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\analysis_output")
OUT_DIR.mkdir(parents=True, exist_ok=True)
OUT_JSON = OUT_DIR / "tile_data_record_20260611_163535_analysis.json"

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
    "ocean_psi_arr",
]
CLIMATE_COLS = [
    "climate_max_temp_delta", "climate_p99_temp_delta",
    "climate_max_transport_anomaly", "climate_precip_p95",
    "climate_slp_delta_p95", "climate_wind_delta_p95",
    "climate_ocean_delta_p95", "weather_dirty_count",
    "water_budget_error", "active_weather_ratio",
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
            ok &= mask
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
        if vx <= 1e-30 or vy <= 1e-30:
            corr = None
        else:
            corr = cov / math.sqrt(vx * vy)
        return {
            "n": self.n,
            "corr": corr,
            "mean_x": self.sx / n,
            "mean_y": self.sy / n,
        }


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
    if a.size == 0:
        return 0.0
    return float(np.quantile(a, 0.95))


def hash_float_array(a):
    b = np.asarray(a, dtype=np.float32)
    return hashlib.blake2b(b.tobytes(), digest_size=12).hexdigest()


def mean_safe(a, mask):
    if mask is None:
        v = a[np.isfinite(a)]
    else:
        v = a[mask & np.isfinite(a)]
    if v.size == 0:
        return None
    return float(v.mean())


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
        neighbor_speed_diff_mean = float(np.nanmean(speed_diff))
    else:
        neighbor_angle_cos_mean = None
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
        dx = x[neigh] - x[idx]
        dy = y[neigh] - y[idx]
        a00 = float(np.dot(dx, dx))
        a01 = float(np.dot(dx, dy))
        a11 = float(np.dot(dy, dy))
        det = a00 * a11 - a01 * a01
        if abs(det) < 1e-12:
            continue
        b_slp = slp[neigh] - slp[idx]
        bx = float(np.dot(dx, b_slp))
        by = float(np.dot(dy, b_slp))
        grad_x[idx] = (a11 * bx - a01 * by) / det
        grad_y[idx] = (-a01 * bx + a00 * by) / det

        b_wx = wx[neigh] - wx[idx]
        b_wy = wy[neigh] - wy[idx]
        bx_u = float(np.dot(dx, b_wx))
        by_u = float(np.dot(dy, b_wx))
        bx_v = float(np.dot(dx, b_wy))
        by_v = float(np.dot(dy, b_wy))
        du_dx = (a11 * bx_u - a01 * by_u) / det
        du_dy = (-a01 * bx_u + a00 * by_u) / det
        dv_dx = (a11 * bx_v - a01 * by_v) / det
        dv_dy = (-a01 * bx_v + a00 * by_v) / det
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

    return {
        "neighbor_angle_cos_mean": neighbor_angle_cos_mean,
        "neighbor_speed_diff_mean": neighbor_speed_diff_mean,
        "pressure_gradient_mag_mean": mean_safe(grad_mag, None),
        "pressure_gradient_mag_p95": p95_abs(grad_mag),
        "wind_vs_down_pressure_mean_cos": float(np.nanmean(down_dot)),
        "wind_vs_isobar_abs_mean_cos": float(np.nanmean(geo_abs)),
        "wind_speed_vs_pressure_gradient_corr": corr_np(wind_mag, grad_mag),
        "computed_divergence_abs_p95": p95_abs(div),
        "computed_curl_abs_p95": p95_abs(curl),
        "divergence_vs_weather_convergence_corr": corr_np(div, conv),
    }


with CSV_PATH.open("r", encoding="utf-8-sig", newline="") as f:
    header = next(csv.reader(f))

usecols = [c for c in BASE_COLS + PHYS_COLS + FIELD_COLS + CLIMATE_COLS if c in header]
missing = [c for c in BASE_COLS + PHYS_COLS + FIELD_COLS if c not in header]

tick_stats = []
slice_series = []
snapshot_metrics = []
phys_counter = Counter()
phys_path_counter = Counter()
slp_commit_counter = Counter()
wind_commit_counter = Counter()
row_counts = Counter()
field_hashes = defaultdict(set)
field_change_counts = Counter()
field_delta_summary = defaultdict(lambda: {"max": 0.0, "mean_sum": 0.0, "n": 0})
correlations = defaultdict(CorrAcc)
slice_correlations = defaultdict(CorrAcc)

static = {}
prev = {}
seq_idx = 0
first_tick = None
last_snapshot = None
stage_seen = set()
start_time = time.time()


def process_group(tick, g):
    global seq_idx, first_tick, last_snapshot
    if g.empty:
        return
    tick = int(tick)
    if not g["cell_index"].is_monotonic_increasing:
        g = g.sort_values("cell_index", kind="stable")
    n = len(g)
    row_counts[n] += 1
    if first_tick is None:
        first_tick = tick
        static["q"] = arr(g, "q").astype(np.int32)
        static["r"] = arr(g, "r").astype(np.int32)
        for c in ["cell_pos_x_arr", "cell_pos_y_arr", "cell_lat_norm_arr", "elevation_arr", "is_water_arr", "terrain_arr"]:
            static[c] = arr(g, c)
        static["neighbors"], static["pairs"] = build_neighbors(static["q"], static["r"])
        lat = static["cell_lat_norm_arr"]
        water = static["is_water_arr"] > 0.5
        static["masks"] = {
            "all": np.ones(n, dtype=bool),
            "water": water,
            "land": ~water,
            "lat_00_20": (lat >= 0.0) & (lat < 0.2),
            "lat_20_40": (lat >= 0.2) & (lat < 0.4),
            "lat_40_60": (lat >= 0.4) & (lat < 0.6),
            "lat_60_80": (lat >= 0.6) & (lat < 0.8),
            "lat_80_100": (lat >= 0.8) & (lat <= 1.0),
        }

    arrays = {c: arr(g, c) for c in FIELD_COLS if c in g.columns}
    first = g.iloc[0]
    phys = {c: py_value(first[c]) for c in PHYS_COLS if c in g.columns}
    stage_name = str(phys.get("phys_stage_name", ""))
    phys_counter[stage_name] += 1
    phys_path_counter[str(phys.get("phys_path", ""))] += 1
    slp_commit_counter[str(phys.get("phys_slp_commit_ok", ""))] += 1
    wind_commit_counter[str(phys.get("phys_wind_commit_ok", ""))] += 1

    for f in ["wind_x_arr", "wind_y_arr", "wind_speed_arr", "slp_arr", "ocean_current_x_arr", "ocean_current_y_arr"]:
        field_hashes[f].add(hash_float_array(arrays[f]))

    delta_stats = {}
    if prev:
        for f in ["wind_x_arr", "wind_y_arr", "wind_speed_arr", "slp_arr", "temp_arr", "moisture_arr", "weather_precip_arr", "weather_cloud_arr"]:
            d = np.abs(arrays[f] - prev[f])
            mx = float(np.nanmax(d))
            mn = float(np.nanmean(d))
            delta_stats[f + "_max_abs_delta"] = mx
            delta_stats[f + "_mean_abs_delta"] = mn
            field_delta_summary[f]["max"] = max(field_delta_summary[f]["max"], mx)
            field_delta_summary[f]["mean_sum"] += mn
            field_delta_summary[f]["n"] += 1
            if mx > 1e-7:
                field_change_counts[f] += 1

        dtemp = arrays["temp_arr"] - prev["temp_arr"]
        dmoist = arrays["moisture_arr"] - prev["moisture_arr"]
        dprecip = arrays["weather_precip_arr"] - prev["weather_precip_arr"]
        dcloud = arrays["weather_cloud_arr"] - prev["weather_cloud_arr"]
        correlations["dtemp_vs_prev_wind_speed"].add(prev["wind_speed_arr"], dtemp)
        correlations["dtemp_vs_prev_wind_y"].add(prev["wind_y_arr"], dtemp)
        correlations["dtemp_vs_transport_anomaly"].add(arrays["temperature_transport_anomaly_arr"], dtemp)
        correlations["dtemp_vs_air_mass_anomaly"].add(arrays["air_mass_temp_anomaly_arr"], dtemp)
        correlations["dmoist_vs_prev_wind_speed"].add(prev["wind_speed_arr"], dmoist)
        correlations["dmoist_vs_prev_vapor"].add(prev["weather_vapor_arr"], dmoist)
        correlations["dmoist_vs_prev_convergence"].add(prev["weather_convergence_arr"], dmoist)
        correlations["dprecip_vs_prev_wind_speed"].add(prev["wind_speed_arr"], dprecip)
        correlations["dprecip_vs_prev_convergence"].add(prev["weather_convergence_arr"], dprecip)
        correlations["dcloud_vs_prev_convergence"].add(prev["weather_convergence_arr"], dcloud)

        for name, mask in static["masks"].items():
            slice_correlations[f"{name}:dtemp_vs_transport_anomaly"].add(arrays["temperature_transport_anomaly_arr"], dtemp, mask)
            slice_correlations[f"{name}:dmoist_vs_prev_convergence"].add(prev["weather_convergence_arr"], dmoist, mask)
            slice_correlations[f"{name}:dprecip_vs_prev_convergence"].add(prev["weather_convergence_arr"], dprecip, mask)

    correlations["precip_vs_vapor"].add(arrays["weather_vapor_arr"], arrays["weather_precip_arr"])
    correlations["precip_vs_cloud"].add(arrays["weather_cloud_arr"], arrays["weather_precip_arr"])
    correlations["precip_vs_convergence"].add(arrays["weather_convergence_arr"], arrays["weather_precip_arr"])
    correlations["precip_vs_wind_speed"].add(arrays["wind_speed_arr"], arrays["weather_precip_arr"])
    correlations["transport_anomaly_vs_wind_speed"].add(arrays["wind_speed_arr"], arrays["temperature_transport_anomaly_arr"])
    correlations["air_mass_anomaly_vs_wind_y"].add(arrays["wind_y_arr"], arrays["air_mass_temp_anomaly_arr"])

    tick_record = {
        "tick_idx": tick,
        "seq_idx": seq_idx,
        "rows": n,
        "phys": phys,
        "wind_speed_mean": float(np.nanmean(arrays["wind_speed_arr"])),
        "wind_speed_p95": float(np.nanquantile(arrays["wind_speed_arr"], 0.95)),
        "wind_speed_max": float(np.nanmax(arrays["wind_speed_arr"])),
        "wind_x_mean": float(np.nanmean(arrays["wind_x_arr"])),
        "wind_y_mean": float(np.nanmean(arrays["wind_y_arr"])),
        "slp_mean": float(np.nanmean(arrays["slp_arr"])),
        "slp_std": float(np.nanstd(arrays["slp_arr"])),
        "slp_min": float(np.nanmin(arrays["slp_arr"])),
        "slp_max": float(np.nanmax(arrays["slp_arr"])),
        "temp_mean": float(np.nanmean(arrays["temp_arr"])),
        "moisture_mean": float(np.nanmean(arrays["moisture_arr"])),
        "precip_mean": float(np.nanmean(arrays["weather_precip_arr"])),
        "precip_p95": float(np.nanquantile(arrays["weather_precip_arr"], 0.95)),
        "cloud_mean": float(np.nanmean(arrays["weather_cloud_arr"])),
        "vapor_mean": float(np.nanmean(arrays["weather_vapor_arr"])),
        "convergence_mean": float(np.nanmean(arrays["weather_convergence_arr"])),
        "transport_anomaly_abs_p95": p95_abs(arrays["temperature_transport_anomaly_arr"]),
        "air_mass_anomaly_abs_p95": p95_abs(arrays["air_mass_temp_anomaly_arr"]),
    }
    tick_record.update(delta_stats)
    tick_stats.append(tick_record)

    masks = static["masks"]
    for name in ["all", "water", "land", "lat_00_20", "lat_20_40", "lat_40_60", "lat_60_80", "lat_80_100"]:
        mask = masks[name]
        slice_series.append({
            "tick_idx": tick,
            "seq_idx": seq_idx,
            "slice": name,
            "n": int(mask.sum()),
            "temp_mean": mean_safe(arrays["temp_arr"], mask),
            "moisture_mean": mean_safe(arrays["moisture_arr"], mask),
            "precip_mean": mean_safe(arrays["weather_precip_arr"], mask),
            "cloud_mean": mean_safe(arrays["weather_cloud_arr"], mask),
            "vapor_mean": mean_safe(arrays["weather_vapor_arr"], mask),
            "wind_speed_mean": mean_safe(arrays["wind_speed_arr"], mask),
            "wind_x_mean": mean_safe(arrays["wind_x_arr"], mask),
            "wind_y_mean": mean_safe(arrays["wind_y_arr"], mask),
            "slp_mean": mean_safe(arrays["slp_arr"], mask),
            "transport_anomaly_mean": mean_safe(arrays["temperature_transport_anomaly_arr"], mask),
            "air_mass_anomaly_mean": mean_safe(arrays["air_mass_temp_anomaly_arr"], mask),
        })

    do_snapshot = seq_idx < 3 or seq_idx % 120 == 0 or stage_name not in stage_seen
    if stage_name:
        stage_seen.add(stage_name)
    snapshot = {
        "tick_idx": tick,
        "seq_idx": seq_idx,
        "stage_name": stage_name,
        **{f: arrays[f].copy() for f in [
            "wind_x_arr", "wind_y_arr", "wind_speed_arr", "slp_arr",
            "weather_convergence_arr", "temp_arr", "moisture_arr",
            "weather_precip_arr", "weather_cloud_arr",
        ]},
    }
    last_snapshot = snapshot
    if do_snapshot:
        m = wind_pressure_metrics(snapshot, static)
        m.update({"tick_idx": tick, "seq_idx": seq_idx, "stage_name": stage_name})
        snapshot_metrics.append(m)

    for f in ["wind_x_arr", "wind_y_arr", "wind_speed_arr", "slp_arr", "temp_arr", "moisture_arr", "weather_precip_arr", "weather_cloud_arr", "weather_vapor_arr", "weather_convergence_arr", "temperature_transport_anomaly_arr", "air_mass_temp_anomaly_arr"]:
        prev[f] = arrays[f].copy()
    seq_idx += 1


chunksize = 2400 * 100
carry = pd.DataFrame()
for chunk_i, chunk in enumerate(pd.read_csv(CSV_PATH, usecols=usecols, chunksize=chunksize, low_memory=False)):
    if not carry.empty:
        chunk = pd.concat([carry, chunk], ignore_index=True)
        carry = pd.DataFrame()
    last_tick_in_chunk = int(chunk["tick_idx"].iloc[-1])
    complete = chunk[chunk["tick_idx"] != last_tick_in_chunk]
    carry = chunk[chunk["tick_idx"] == last_tick_in_chunk].copy()
    for tick, g in complete.groupby("tick_idx", sort=False):
        process_group(tick, g)
    if chunk_i % 10 == 0:
        print(f"processed_chunks={chunk_i + 1} ticks={seq_idx} elapsed_s={time.time() - start_time:.1f}", flush=True)

if not carry.empty:
    for tick, g in carry.groupby("tick_idx", sort=False):
        process_group(tick, g)

if last_snapshot is not None and (not snapshot_metrics or snapshot_metrics[-1]["tick_idx"] != last_snapshot["tick_idx"]):
    m = wind_pressure_metrics(last_snapshot, static)
    m.update({"tick_idx": int(last_snapshot["tick_idx"]), "seq_idx": int(last_snapshot["seq_idx"]), "stage_name": last_snapshot["stage_name"]})
    snapshot_metrics.append(m)

tick_count = len(tick_stats)
row_total = int(sum(k * v for k, v in row_counts.items()))
first_tick_idx = tick_stats[0]["tick_idx"] if tick_stats else None
last_tick_idx = tick_stats[-1]["tick_idx"] if tick_stats else None

time_samples = []
if tick_stats:
    desired = [0, tick_count // 4, tick_count // 2, (tick_count * 3) // 4, tick_count - 1]
    desired = sorted(set(max(0, min(tick_count - 1, i)) for i in desired))
    for i in desired:
        t = tick_stats[i]["tick_idx"]
        rows = [s for s in slice_series if s["tick_idx"] == t]
        time_samples.append({
            "tick_idx": t,
            "seq_idx": i,
            "phys": tick_stats[i]["phys"],
            "global": {k: tick_stats[i].get(k) for k in [
                "wind_speed_mean", "wind_speed_p95", "wind_x_mean", "wind_y_mean",
                "slp_std", "temp_mean", "moisture_mean", "precip_mean",
                "cloud_mean", "transport_anomaly_abs_p95",
            ]},
            "slices": rows,
        })

field_delta_out = {}
for f, d in field_delta_summary.items():
    field_delta_out[f] = {
        "max_abs_delta_observed": d["max"],
        "mean_abs_delta_avg_over_transitions": d["mean_sum"] / max(1, d["n"]),
        "changed_transition_count": int(field_change_counts[f]),
        "transition_count": int(d["n"]),
    }

result = {
    "file": str(CSV_PATH),
    "missing_expected_columns": missing,
    "row_total": row_total,
    "tick_count": tick_count,
    "first_tick": first_tick_idx,
    "last_tick": last_tick_idx,
    "row_counts_per_tick": dict(row_counts),
    "cell_count": max(row_counts.keys()) if row_counts else None,
    "phys_stage_counts": dict(phys_counter),
    "phys_path_counts": dict(phys_path_counter),
    "phys_slp_commit_counts": dict(slp_commit_counter),
    "phys_wind_commit_counts": dict(wind_commit_counter),
    "field_unique_hash_counts": {k: len(v) for k, v in field_hashes.items()},
    "field_delta_summary": field_delta_out,
    "correlations": {k: v.result() for k, v in correlations.items()},
    "slice_correlations": {k: v.result() for k, v in slice_correlations.items()},
    "tick_stats_head": tick_stats[:5],
    "tick_stats_tail": tick_stats[-5:],
    "time_samples": time_samples,
    "snapshot_metrics": snapshot_metrics,
    "elapsed_seconds": time.time() - start_time,
}

OUT_JSON.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
print(json.dumps({
    "out": str(OUT_JSON),
    "ticks": tick_count,
    "rows": row_total,
    "elapsed_seconds": result["elapsed_seconds"],
    "field_unique_hash_counts": result["field_unique_hash_counts"],
    "phys_stage_counts": result["phys_stage_counts"],
}, ensure_ascii=False, indent=2))
