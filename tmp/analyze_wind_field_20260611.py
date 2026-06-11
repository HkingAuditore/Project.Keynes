from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Dict, Iterable, List, Tuple

import numpy as np
import pandas as pd


ROOT = Path(r"D:\Godot\ProjectKeynes\Project.Keynes")
CSV = ROOT / "tmp" / "tile_data_record_20260611_145934.csv"
OUT_DIR = ROOT / "tmp" / "analysis_output"
OUT_JSON = OUT_DIR / "wind_field_analysis_20260611_145934.json"
OUT_MD = OUT_DIR / "wind_field_analysis_20260611_145934.md"

CHUNKSIZE = 2400 * 50

USECOLS = [
    "tick_idx",
    "timestamp_ms",
    "was_skipped_day",
    "cell_index",
    "q",
    "r",
    "s",
    "climate_precip_p95",
    "climate_slp_delta_p95",
    "climate_wind_delta_p95",
    "climate_ocean_delta_p95",
    "climate_slp_abs_p95",
    "climate_wind_mag_p95",
    "active_weather_ratio",
    "weather_dirty_count",
    "temp_arr",
    "temp_arr_prev",
    "moisture_arr",
    "moisture_arr_prev",
    "snow_cover_arr",
    "sea_ice_frac_arr",
    "weather_intensity_arr",
    "weather_cloud_arr",
    "weather_cloud_water_arr",
    "weather_precip_arr",
    "weather_vapor_arr",
    "weather_convergence_arr",
    "weather_instability_arr",
    "air_mass_temp_anomaly_arr",
    "insolation_now_arr",
    "day_length_arr",
    "heat_input_arr",
    "thermal_energy_arr",
    "soil_moisture_arr",
    "vegetation_growth_pressure_arr",
    "temperature_transport_anomaly_arr",
    "elevation_arr",
    "base_moisture_arr",
    "ocean_current_x_arr",
    "ocean_current_y_arr",
    "wind_x_arr",
    "wind_y_arr",
    "slp_arr",
    "wind_speed_arr",
    "upwelling_strength_arr",
    "wind_stress_curl_arr",
    "ocean_psi_arr",
    "cell_pos_x_arr",
    "cell_pos_y_arr",
    "cell_lat_norm_arr",
    "temp_baseline_year_arr",
    "terrain_arr",
    "landform_arr",
    "vegetation_arr",
    "base_terrain_arr",
    "cover_arr",
    "weather_type_arr",
    "is_water_arr",
]

FLOAT_COLS = [c for c in USECOLS if c not in {
    "tick_idx", "timestamp_ms", "was_skipped_day", "cell_index", "q", "r", "s",
    "terrain_arr", "landform_arr", "vegetation_arr", "base_terrain_arr", "cover_arr",
    "weather_type_arr", "is_water_arr", "weather_dirty_count",
}]

DTYPES = {c: "float32" for c in FLOAT_COLS}
DTYPES.update({
    "tick_idx": "int32",
    "timestamp_ms": "int64",
    "cell_index": "int32",
    "q": "int16",
    "r": "int16",
    "s": "int16",
    "terrain_arr": "uint8",
    "landform_arr": "uint8",
    "vegetation_arr": "uint8",
    "base_terrain_arr": "uint8",
    "cover_arr": "uint8",
    "weather_type_arr": "uint8",
    "is_water_arr": "uint8",
    "weather_dirty_count": "int32",
})


def f(x):
    if x is None:
        return None
    try:
        v = float(x)
    except Exception:
        return None
    if math.isnan(v) or math.isinf(v):
        return None
    return v


def corr(a: np.ndarray, b: np.ndarray) -> float | None:
    a = np.asarray(a, dtype=np.float64)
    b = np.asarray(b, dtype=np.float64)
    m = np.isfinite(a) & np.isfinite(b)
    if int(m.sum()) < 3:
        return None
    a = a[m]
    b = b[m]
    sa = float(a.std())
    sb = float(b.std())
    if sa <= 1e-12 or sb <= 1e-12:
        return None
    return float(np.corrcoef(a, b)[0, 1])


def angle_deg(x: float, y: float) -> float | None:
    if abs(x) < 1e-12 and abs(y) < 1e-12:
        return None
    return float(math.degrees(math.atan2(y, x)))


def describe(v: np.ndarray) -> Dict[str, float | int | None]:
    v = np.asarray(v, dtype=np.float64)
    v = v[np.isfinite(v)]
    if v.size == 0:
        return {"n": 0}
    return {
        "n": int(v.size),
        "mean": f(np.mean(v)),
        "std": f(np.std(v)),
        "min": f(np.min(v)),
        "p05": f(np.quantile(v, 0.05)),
        "p50": f(np.quantile(v, 0.50)),
        "p95": f(np.quantile(v, 0.95)),
        "max": f(np.max(v)),
    }


class PairCorr:
    def __init__(self, xs: List[str], ys: List[str]):
        self.xs = xs
        self.ys = ys
        self.n = np.zeros((len(xs), len(ys)), dtype=np.int64)
        self.sx = np.zeros_like(self.n, dtype=np.float64)
        self.sy = np.zeros_like(self.n, dtype=np.float64)
        self.sxx = np.zeros_like(self.n, dtype=np.float64)
        self.syy = np.zeros_like(self.n, dtype=np.float64)
        self.sxy = np.zeros_like(self.n, dtype=np.float64)

    def update(self, xvals: Dict[str, np.ndarray], yvals: Dict[str, np.ndarray]) -> None:
        for i, xname in enumerate(self.xs):
            x = np.asarray(xvals[xname], dtype=np.float64)
            for j, yname in enumerate(self.ys):
                y = np.asarray(yvals[yname], dtype=np.float64)
                m = np.isfinite(x) & np.isfinite(y)
                if int(m.sum()) == 0:
                    continue
                xx = x[m]
                yy = y[m]
                self.n[i, j] += xx.size
                self.sx[i, j] += float(xx.sum())
                self.sy[i, j] += float(yy.sum())
                self.sxx[i, j] += float(np.dot(xx, xx))
                self.syy[i, j] += float(np.dot(yy, yy))
                self.sxy[i, j] += float(np.dot(xx, yy))

    def result(self) -> Dict[str, Dict[str, float | None]]:
        out: Dict[str, Dict[str, float | None]] = {}
        for i, xname in enumerate(self.xs):
            row: Dict[str, float | None] = {}
            for j, yname in enumerate(self.ys):
                n = int(self.n[i, j])
                if n < 3:
                    row[yname] = None
                    continue
                cov = self.sxy[i, j] - self.sx[i, j] * self.sy[i, j] / n
                vx = self.sxx[i, j] - self.sx[i, j] * self.sx[i, j] / n
                vy = self.syy[i, j] - self.sy[i, j] * self.sy[i, j] / n
                den = math.sqrt(max(vx, 0.0) * max(vy, 0.0))
                row[yname] = None if den <= 1e-12 else float(cov / den)
            out[xname] = row
        return out


def grouped_summary(df: pd.DataFrame, by: str, max_rows: int = 40) -> List[Dict[str, object]]:
    out: List[Dict[str, object]] = []
    work = df.copy()
    work["wind_vec_mag"] = np.sqrt(work["wind_x_arr"] ** 2 + work["wind_y_arr"] ** 2)
    for key, g in work.groupby(by, observed=False):
        if len(g) == 0:
            continue
        wx = float(g["wind_x_arr"].mean())
        wy = float(g["wind_y_arr"].mean())
        vmag = np.sqrt(g["wind_x_arr"].to_numpy(np.float64) ** 2 + g["wind_y_arr"].to_numpy(np.float64) ** 2)
        row = {
            str(by): str(key),
            "count": int(len(g)),
            "wind_x_mean": f(wx),
            "wind_y_mean": f(wy),
            "mean_direction_deg": angle_deg(wx, wy),
            "vector_coherence": f(math.sqrt(wx * wx + wy * wy) / max(float(np.mean(vmag)), 1e-12)),
            "wind_vec_mag_mean": f(np.mean(vmag)),
            "wind_vec_mag_std": f(np.std(vmag)),
            "wind_speed_mean": f(g["wind_speed_arr"].mean()),
            "wind_speed_std": f(g["wind_speed_arr"].std(ddof=0)),
            "slp_mean": f(g["slp_arr"].mean()),
            "slp_std": f(g["slp_arr"].std(ddof=0)),
            "temp_mean": f(g["temp_arr"].mean()),
            "moisture_mean": f(g["moisture_arr"].mean()),
            "precip_mean": f(g["weather_precip_arr"].mean()),
            "vapor_mean": f(g["weather_vapor_arr"].mean()),
            "cloud_mean": f(g["weather_cloud_arr"].mean()),
            "elevation_mean": f(g["elevation_arr"].mean()),
        }
        out.append(row)
    return out[:max_rows]


def build_gradients(df: pd.DataFrame, field: str) -> Tuple[np.ndarray, np.ndarray, np.ndarray]:
    # Hex neighbor offsets in q/r axial coordinates. s is redundant because q+r+s=0.
    offsets = [(1, -1), (1, 0), (0, 1), (-1, 1), (-1, 0), (0, -1)]
    key_to_i = {(int(q), int(r)): i for i, (q, r) in enumerate(zip(df["q"], df["r"]))}
    x = df["cell_pos_x_arr"].to_numpy(np.float64)
    y = df["cell_pos_y_arr"].to_numpy(np.float64)
    val = df[field].to_numpy(np.float64)
    gx = np.full(len(df), np.nan, dtype=np.float64)
    gy = np.full(len(df), np.nan, dtype=np.float64)
    used = np.zeros(len(df), dtype=np.int16)
    qr = list(zip(df["q"].astype(int), df["r"].astype(int)))
    for i, (q, r) in enumerate(qr):
        rows = []
        rhs = []
        for dq, dr in offsets:
            j = key_to_i.get((q + dq, r + dr))
            if j is None:
                continue
            rows.append([x[j] - x[i], y[j] - y[i]])
            rhs.append(val[j] - val[i])
        if len(rows) < 3:
            continue
        a = np.asarray(rows, dtype=np.float64)
        b = np.asarray(rhs, dtype=np.float64)
        try:
            sol, *_ = np.linalg.lstsq(a, b, rcond=None)
        except np.linalg.LinAlgError:
            continue
        gx[i] = sol[0]
        gy[i] = sol[1]
        used[i] = len(rows)
    return gx, gy, used


def gradient_alignment(df: pd.DataFrame) -> Dict[str, object]:
    work = df.sort_values("cell_index").reset_index(drop=True)
    gx, gy, used = build_gradients(work, "slp_arr")
    wx = work["wind_x_arr"].to_numpy(np.float64)
    wy = work["wind_y_arr"].to_numpy(np.float64)
    ws = work["wind_speed_arr"].to_numpy(np.float64)
    vmag = np.sqrt(wx * wx + wy * wy)
    gmag = np.sqrt(gx * gx + gy * gy)
    m = np.isfinite(gmag) & (gmag > 1e-9) & (vmag > 1e-9)
    pgx = -gx[m] / gmag[m]
    pgy = -gy[m] / gmag[m]
    wux = wx[m] / vmag[m]
    wuy = wy[m] / vmag[m]
    direct = wux * pgx + wuy * pgy
    # Both rotations are reported because the sign convention for lat_norm is project-specific.
    rot_cw = wux * pgy + wuy * (-pgx)
    rot_ccw = wux * (-pgy) + wuy * pgx
    # Local gradients of wind for divergence/vorticity.
    ux, uy, _ = build_gradients(work.assign(__u=wx), "__u")
    vx, vy, _ = build_gradients(work.assign(__v=wy), "__v")
    divergence = ux + vy
    vorticity = vx - uy
    return {
        "cells_with_slp_gradient": int(m.sum()),
        "neighbor_count": describe(used.astype(float)),
        "slp_gradient_mag": describe(gmag[m]),
        "wind_vs_pressure_gradient_dot": describe(direct),
        "wind_vs_geostrophic_cw_dot": describe(rot_cw),
        "wind_vs_geostrophic_ccw_dot": describe(rot_ccw),
        "best_abs_geostrophic_dot_mean": (
            f(max(abs(float(np.nanmean(rot_cw))), abs(float(np.nanmean(rot_ccw)))))
            if m.any() else None
        ),
        "corr_wind_speed_vs_slp_gradient_mag": corr(ws[m], gmag[m]),
        "corr_wind_vec_mag_vs_slp_gradient_mag": corr(vmag[m], gmag[m]),
        "wind_divergence": describe(divergence[np.isfinite(divergence)]),
        "wind_vorticity": describe(vorticity[np.isfinite(vorticity)]),
    }


def residual_corr_by_bins(df: pd.DataFrame, xcols: List[str], ycols: List[str]) -> Dict[str, Dict[str, float | None]]:
    work = df.copy()
    work["wind_vec_mag"] = np.sqrt(work["wind_x_arr"] ** 2 + work["wind_y_arr"] ** 2)
    work["lat_bin"] = pd.cut(work["cell_lat_norm_arr"], bins=np.linspace(0.0, 1.0, 9), include_lowest=True)
    try:
        work["elev_bin"] = pd.qcut(work["elevation_arr"], q=5, duplicates="drop")
    except Exception:
        work["elev_bin"] = "all"
    keys = ["lat_bin", "elev_bin", "is_water_arr"]
    resids: Dict[str, np.ndarray] = {}
    for col in sorted(set(xcols + ycols)):
        means = work.groupby(keys, observed=False)[col].transform("mean")
        resids[col] = (work[col] - means).to_numpy(np.float64)
    out: Dict[str, Dict[str, float | None]] = {}
    for x in xcols:
        out[x] = {}
        for y in ycols:
            out[x][y] = corr(resids[x], resids[y])
    return out


def mode_counts(s: pd.Series, limit: int = 12) -> Dict[str, int]:
    vc = s.value_counts(dropna=False).head(limit)
    return {str(k): int(v) for k, v in vc.items()}


def compact_tick_metrics(g: pd.DataFrame) -> Dict[str, object]:
    wx = g["wind_x_arr"].to_numpy(np.float64)
    wy = g["wind_y_arr"].to_numpy(np.float64)
    vmag = np.sqrt(wx * wx + wy * wy)
    mean_x = float(np.mean(wx))
    mean_y = float(np.mean(wy))
    return {
        "tick": int(g["tick_idx"].iloc[0]),
        "timestamp_ms": int(g["timestamp_ms"].iloc[0]),
        "rows": int(len(g)),
        "skipped_day_ratio": f(g["was_skipped_day"].astype(bool).mean()),
        "wind_x_mean": f(mean_x),
        "wind_x_std": f(np.std(wx)),
        "wind_y_mean": f(mean_y),
        "wind_y_std": f(np.std(wy)),
        "wind_vec_mag_mean": f(np.mean(vmag)),
        "wind_vec_mag_std": f(np.std(vmag)),
        "wind_vec_mag_min": f(np.min(vmag)),
        "wind_vec_mag_p95": f(np.quantile(vmag, 0.95)),
        "wind_vec_mag_max": f(np.max(vmag)),
        "wind_speed_mean": f(g["wind_speed_arr"].mean()),
        "wind_speed_std": f(g["wind_speed_arr"].std(ddof=0)),
        "wind_speed_min": f(g["wind_speed_arr"].min()),
        "wind_speed_p95": f(g["wind_speed_arr"].quantile(0.95)),
        "wind_speed_max": f(g["wind_speed_arr"].max()),
        "wind_direction_mean_deg": angle_deg(mean_x, mean_y),
        "wind_vector_coherence": f(math.sqrt(mean_x * mean_x + mean_y * mean_y) / max(float(np.mean(vmag)), 1e-12)),
        "slp_mean": f(g["slp_arr"].mean()),
        "slp_std": f(g["slp_arr"].std(ddof=0)),
        "slp_min": f(g["slp_arr"].min()),
        "slp_max": f(g["slp_arr"].max()),
        "temp_mean": f(g["temp_arr"].mean()),
        "moisture_mean": f(g["moisture_arr"].mean()),
        "precip_mean": f(g["weather_precip_arr"].mean()),
        "cloud_mean": f(g["weather_cloud_arr"].mean()),
        "vapor_mean": f(g["weather_vapor_arr"].mean()),
        "climate_wind_delta_p95": f(g["climate_wind_delta_p95"].iloc[0]),
        "climate_slp_delta_p95": f(g["climate_slp_delta_p95"].iloc[0]),
        "climate_wind_mag_p95": f(g["climate_wind_mag_p95"].iloc[0]),
        "active_weather_ratio": f(g["active_weather_ratio"].iloc[0]),
    }


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    header = pd.read_csv(CSV, nrows=0)
    missing = [c for c in USECOLS if c not in header.columns]
    if missing:
        raise RuntimeError(f"missing columns: {missing}")

    rows = 0
    ticks_seen: set[int] = set()
    cells_seen: set[int] = set()
    tick_metrics: List[Dict[str, object]] = []
    fixed_rows: List[Dict[str, object]] = []
    first_tick_snapshot: pd.DataFrame | None = None
    last_tick_snapshot: pd.DataFrame | None = None

    lag_x = [
        "prev_wind_x", "prev_wind_y", "prev_wind_vec_mag", "prev_wind_speed",
        "prev_slp", "prev_precip", "prev_vapor", "prev_temp", "prev_moisture",
    ]
    lag_y = [
        "delta_temp", "delta_moisture", "delta_precip", "delta_cloud", "delta_vapor",
        "delta_soil_moisture", "delta_temp_transport", "delta_air_mass_anom",
    ]
    lag_corr = PairCorr(lag_x, lag_y)

    raw_x = ["wind_x_arr", "wind_y_arr", "wind_vec_mag", "wind_speed_arr", "slp_arr"]
    raw_y = [
        "temp_arr", "moisture_arr", "weather_precip_arr", "weather_cloud_arr",
        "weather_vapor_arr", "weather_instability_arr", "weather_convergence_arr",
        "air_mass_temp_anomaly_arr", "temperature_transport_anomaly_arr",
        "soil_moisture_arr", "vegetation_growth_pressure_arr", "elevation_arr",
        "base_moisture_arr", "insolation_now_arr",
    ]
    raw_corr = PairCorr(raw_x, raw_y)

    prev_tick_vals: Dict[str, np.ndarray] | None = None
    delta_tick_rows: List[Dict[str, object]] = []
    per_cell_count = None
    per_cell_sum = None
    per_cell_sumsq = None
    per_cell_vars = ["wind_x_arr", "wind_y_arr", "wind_vec_mag", "wind_speed_arr", "slp_arr"]

    for chunk in pd.read_csv(CSV, usecols=USECOLS, dtype=DTYPES, chunksize=CHUNKSIZE):
        chunk["wind_vec_mag"] = np.sqrt(chunk["wind_x_arr"] ** 2 + chunk["wind_y_arr"] ** 2)
        rows += len(chunk)
        ticks_seen.update(int(t) for t in chunk["tick_idx"].unique())
        cells_seen.update(int(c) for c in chunk["cell_index"].unique())
        raw_corr.update({x: chunk[x].to_numpy(np.float64) for x in raw_x},
                        {y: chunk[y].to_numpy(np.float64) for y in raw_y})

        for tick, g0 in chunk.groupby("tick_idx", sort=True):
            g = g0.sort_values("cell_index").reset_index(drop=True)
            tick_metrics.append(compact_tick_metrics(g))
            fixed_rows.append({
                "tick": int(tick),
                "climate_wind_delta_p95": f(g["climate_wind_delta_p95"].iloc[0]),
                "climate_slp_delta_p95": f(g["climate_slp_delta_p95"].iloc[0]),
                "climate_ocean_delta_p95": f(g["climate_ocean_delta_p95"].iloc[0]),
                "climate_precip_p95": f(g["climate_precip_p95"].iloc[0]),
                "active_weather_ratio": f(g["active_weather_ratio"].iloc[0]),
                "weather_dirty_count": int(g["weather_dirty_count"].iloc[0]),
            })

            if first_tick_snapshot is None:
                first_tick_snapshot = g.copy()
            last_tick_snapshot = g.copy()

            max_cell = int(g["cell_index"].max()) + 1
            if per_cell_count is None:
                per_cell_count = np.zeros(max_cell, dtype=np.int64)
                per_cell_sum = np.zeros((max_cell, len(per_cell_vars)), dtype=np.float64)
                per_cell_sumsq = np.zeros((max_cell, len(per_cell_vars)), dtype=np.float64)
            idx = g["cell_index"].to_numpy(np.int64)
            vals = np.column_stack([
                g["wind_x_arr"].to_numpy(np.float64),
                g["wind_y_arr"].to_numpy(np.float64),
                g["wind_vec_mag"].to_numpy(np.float64),
                g["wind_speed_arr"].to_numpy(np.float64),
                g["slp_arr"].to_numpy(np.float64),
            ])
            per_cell_count[idx] += 1
            per_cell_sum[idx, :] += vals
            per_cell_sumsq[idx, :] += vals * vals

            cur = {
                "wind_x": g["wind_x_arr"].to_numpy(np.float64),
                "wind_y": g["wind_y_arr"].to_numpy(np.float64),
                "wind_vec_mag": g["wind_vec_mag"].to_numpy(np.float64),
                "wind_speed": g["wind_speed_arr"].to_numpy(np.float64),
                "slp": g["slp_arr"].to_numpy(np.float64),
                "temp": g["temp_arr"].to_numpy(np.float64),
                "moisture": g["moisture_arr"].to_numpy(np.float64),
                "precip": g["weather_precip_arr"].to_numpy(np.float64),
                "cloud": g["weather_cloud_arr"].to_numpy(np.float64),
                "vapor": g["weather_vapor_arr"].to_numpy(np.float64),
                "soil_moisture": g["soil_moisture_arr"].to_numpy(np.float64),
                "temp_transport": g["temperature_transport_anomaly_arr"].to_numpy(np.float64),
                "air_mass_anom": g["air_mass_temp_anomaly_arr"].to_numpy(np.float64),
            }
            if prev_tick_vals is not None and len(prev_tick_vals["wind_x"]) == len(cur["wind_x"]):
                deltas = {
                    "delta_temp": cur["temp"] - prev_tick_vals["temp"],
                    "delta_moisture": cur["moisture"] - prev_tick_vals["moisture"],
                    "delta_precip": cur["precip"] - prev_tick_vals["precip"],
                    "delta_cloud": cur["cloud"] - prev_tick_vals["cloud"],
                    "delta_vapor": cur["vapor"] - prev_tick_vals["vapor"],
                    "delta_soil_moisture": cur["soil_moisture"] - prev_tick_vals["soil_moisture"],
                    "delta_temp_transport": cur["temp_transport"] - prev_tick_vals["temp_transport"],
                    "delta_air_mass_anom": cur["air_mass_anom"] - prev_tick_vals["air_mass_anom"],
                }
                lag_corr.update({
                    "prev_wind_x": prev_tick_vals["wind_x"],
                    "prev_wind_y": prev_tick_vals["wind_y"],
                    "prev_wind_vec_mag": prev_tick_vals["wind_vec_mag"],
                    "prev_wind_speed": prev_tick_vals["wind_speed"],
                    "prev_slp": prev_tick_vals["slp"],
                    "prev_precip": prev_tick_vals["precip"],
                    "prev_vapor": prev_tick_vals["vapor"],
                    "prev_temp": prev_tick_vals["temp"],
                    "prev_moisture": prev_tick_vals["moisture"],
                }, deltas)
                delta_tick_rows.append({
                    "tick": int(tick),
                    "wind_x_abs_delta_p95": f(np.quantile(np.abs(cur["wind_x"] - prev_tick_vals["wind_x"]), 0.95)),
                    "wind_y_abs_delta_p95": f(np.quantile(np.abs(cur["wind_y"] - prev_tick_vals["wind_y"]), 0.95)),
                    "wind_vec_mag_abs_delta_p95": f(np.quantile(np.abs(cur["wind_vec_mag"] - prev_tick_vals["wind_vec_mag"]), 0.95)),
                    "wind_speed_abs_delta_p95": f(np.quantile(np.abs(cur["wind_speed"] - prev_tick_vals["wind_speed"]), 0.95)),
                    "slp_abs_delta_p95": f(np.quantile(np.abs(cur["slp"] - prev_tick_vals["slp"]), 0.95)),
                    "temp_abs_delta_p95": f(np.quantile(np.abs(deltas["delta_temp"]), 0.95)),
                    "moisture_abs_delta_p95": f(np.quantile(np.abs(deltas["delta_moisture"]), 0.95)),
                    "precip_abs_delta_p95": f(np.quantile(np.abs(deltas["delta_precip"]), 0.95)),
                    "cloud_abs_delta_p95": f(np.quantile(np.abs(deltas["delta_cloud"]), 0.95)),
                    "vapor_abs_delta_p95": f(np.quantile(np.abs(deltas["delta_vapor"]), 0.95)),
                })
            prev_tick_vals = cur

    tick_df = pd.DataFrame(tick_metrics).sort_values("tick").reset_index(drop=True)
    fixed_df = pd.DataFrame(fixed_rows).drop_duplicates("tick").sort_values("tick").reset_index(drop=True)
    delta_df = pd.DataFrame(delta_tick_rows).sort_values("tick").reset_index(drop=True)

    tick_list = tick_df["tick"].astype(int).to_list()
    selected_ticks = sorted({tick_list[0], tick_list[len(tick_list) // 4], tick_list[len(tick_list) // 2],
                             tick_list[(len(tick_list) * 3) // 4], tick_list[-1]})

    snapshots: Dict[int, pd.DataFrame] = {}
    for chunk in pd.read_csv(CSV, usecols=USECOLS, dtype=DTYPES, chunksize=CHUNKSIZE):
        m = chunk["tick_idx"].isin(selected_ticks)
        if not bool(m.any()):
            continue
        for tick, g in chunk.loc[m].groupby("tick_idx"):
            snapshots[int(tick)] = g.sort_values("cell_index").reset_index(drop=True).copy()
        if len(snapshots) == len(selected_ticks):
            break

    snapshot_results: Dict[str, object] = {}
    for tick in selected_ticks:
        df = snapshots[tick].copy()
        df["wind_vec_mag"] = np.sqrt(df["wind_x_arr"] ** 2 + df["wind_y_arr"] ** 2)
        df["lat_bin"] = pd.cut(df["cell_lat_norm_arr"], bins=np.linspace(0.0, 1.0, 11), include_lowest=True)
        df["pos_x_bin"] = pd.cut(df["cell_pos_x_arr"], bins=8, include_lowest=True)
        try:
            df["elevation_quantile"] = pd.qcut(df["elevation_arr"], q=5, duplicates="drop")
        except Exception:
            df["elevation_quantile"] = "all"
        snapshot_results[str(tick)] = {
            "tick_summary": compact_tick_metrics(df),
            "lat_slices": grouped_summary(df, "lat_bin"),
            "elevation_slices": grouped_summary(df, "elevation_quantile"),
            "water_slices": grouped_summary(df, "is_water_arr"),
            "terrain_slices": grouped_summary(df, "terrain_arr"),
            "pos_x_slices": grouped_summary(df, "pos_x_bin"),
            "weather_type_counts": mode_counts(df["weather_type_arr"]),
            "terrain_counts": mode_counts(df["terrain_arr"]),
            "gradient_alignment": gradient_alignment(df),
            "residual_corr_after_lat_elev_water": residual_corr_by_bins(
                df,
                ["wind_x_arr", "wind_y_arr", "wind_vec_mag", "wind_speed_arr", "slp_arr"],
                ["temp_arr", "moisture_arr", "weather_precip_arr", "weather_cloud_arr",
                 "weather_vapor_arr", "weather_instability_arr",
                 "air_mass_temp_anomaly_arr", "temperature_transport_anomaly_arr",
                 "soil_moisture_arr"],
            ),
        }

    per_cell_stats: Dict[str, object] = {}
    if per_cell_count is not None and per_cell_sum is not None and per_cell_sumsq is not None:
        means = per_cell_sum / np.maximum(per_cell_count[:, None], 1)
        vars_ = per_cell_sumsq / np.maximum(per_cell_count[:, None], 1) - means * means
        stds = np.sqrt(np.maximum(vars_, 0.0))
        for j, name in enumerate(per_cell_vars):
            per_cell_stats[name] = describe(stds[:, j])

    result = {
        "source": str(CSV),
        "rows": int(rows),
        "ticks": {
            "count": int(len(ticks_seen)),
            "min": int(min(ticks_seen)),
            "max": int(max(ticks_seen)),
            "selected": selected_ticks,
        },
        "cells": {
            "count": int(len(cells_seen)),
            "min": int(min(cells_seen)),
            "max": int(max(cells_seen)),
            "rows_per_tick_expected": int(len(cells_seen)),
            "row_count_mod_cells": int(rows % max(len(cells_seen), 1)),
        },
        "tick_level": {
            "wind_x_mean": describe(tick_df["wind_x_mean"].to_numpy()),
            "wind_y_mean": describe(tick_df["wind_y_mean"].to_numpy()),
            "wind_vec_mag_mean": describe(tick_df["wind_vec_mag_mean"].to_numpy()),
            "wind_vec_mag_std": describe(tick_df["wind_vec_mag_std"].to_numpy()),
            "wind_speed_mean": describe(tick_df["wind_speed_mean"].to_numpy()),
            "wind_speed_std": describe(tick_df["wind_speed_std"].to_numpy()),
            "wind_vector_coherence": describe(tick_df["wind_vector_coherence"].to_numpy()),
            "slp_std": describe(tick_df["slp_std"].to_numpy()),
            "temp_mean": describe(tick_df["temp_mean"].to_numpy()),
            "moisture_mean": describe(tick_df["moisture_mean"].to_numpy()),
            "precip_mean": describe(tick_df["precip_mean"].to_numpy()),
            "cloud_mean": describe(tick_df["cloud_mean"].to_numpy()),
            "vapor_mean": describe(tick_df["vapor_mean"].to_numpy()),
        },
        "fixed_tick_columns": {
            "climate_wind_delta_p95": describe(fixed_df["climate_wind_delta_p95"].to_numpy()),
            "climate_slp_delta_p95": describe(fixed_df["climate_slp_delta_p95"].to_numpy()),
            "climate_ocean_delta_p95": describe(fixed_df["climate_ocean_delta_p95"].to_numpy()),
            "climate_precip_p95": describe(fixed_df["climate_precip_p95"].to_numpy()),
            "active_weather_ratio": describe(fixed_df["active_weather_ratio"].to_numpy()),
            "weather_dirty_count": describe(fixed_df["weather_dirty_count"].to_numpy()),
            "nonzero_wind_delta_ticks": int((fixed_df["climate_wind_delta_p95"].abs() > 1e-8).sum()),
            "nonzero_slp_delta_ticks": int((fixed_df["climate_slp_delta_p95"].abs() > 1e-8).sum()),
        },
        "actual_tick_to_tick_deltas": {
            col: describe(delta_df[col].to_numpy()) for col in delta_df.columns if col != "tick"
        },
        "per_cell_temporal_std": per_cell_stats,
        "raw_correlations_all_rows": raw_corr.result(),
        "lag_correlations_prev_wind_vs_next_delta": lag_corr.result(),
        "selected_snapshots": snapshot_results,
        "sample_tick_metrics": {
            "first": tick_df.head(3).to_dict(orient="records"),
            "middle": tick_df.iloc[max(0, len(tick_df)//2 - 1):len(tick_df)//2 + 2].to_dict(orient="records"),
            "last": tick_df.tail(3).to_dict(orient="records"),
        },
    }

    OUT_JSON.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")

    def fmt_stat(path: List[str], key: str = "mean", digits: int = 6) -> str:
        obj = result
        for p in path:
            obj = obj[p]
        v = obj.get(key)
        return "n/a" if v is None else f"{float(v):.{digits}g}"

    md_lines = [
        "# Wind Field Analysis 20260611_145934",
        "",
        f"Source: `{CSV}`",
        f"Rows: {rows:,}; ticks: {min(ticks_seen)}..{max(ticks_seen)} ({len(ticks_seen)}); cells: {len(cells_seen)}",
        "",
        "## High-Signal Metrics",
        "",
        f"- Nonzero `climate_wind_delta_p95` ticks: {result['fixed_tick_columns']['nonzero_wind_delta_ticks']} / {len(ticks_seen)}",
        f"- Actual tick-to-tick wind_x p95 abs delta mean: {fmt_stat(['actual_tick_to_tick_deltas', 'wind_x_abs_delta_p95'])}",
        f"- Actual tick-to-tick wind_y p95 abs delta mean: {fmt_stat(['actual_tick_to_tick_deltas', 'wind_y_abs_delta_p95'])}",
        f"- Actual tick-to-tick wind_speed p95 abs delta mean: {fmt_stat(['actual_tick_to_tick_deltas', 'wind_speed_abs_delta_p95'])}",
        f"- Per-cell temporal std wind_x p95: {fmt_stat(['per_cell_temporal_std', 'wind_x_arr'], 'p95')}",
        f"- Per-cell temporal std wind_y p95: {fmt_stat(['per_cell_temporal_std', 'wind_y_arr'], 'p95')}",
        f"- Tick-level mean wind vector coherence mean: {fmt_stat(['tick_level', 'wind_vector_coherence'])}",
        f"- Tick-level wind vector magnitude mean: {fmt_stat(['tick_level', 'wind_vec_mag_mean'])}",
        f"- Tick-level wind vector magnitude std mean: {fmt_stat(['tick_level', 'wind_vec_mag_std'])}",
        f"- Tick-level scalar wind_speed mean: {fmt_stat(['tick_level', 'wind_speed_mean'])}",
        f"- Tick-level scalar wind_speed std mean: {fmt_stat(['tick_level', 'wind_speed_std'])}",
        "",
        "## Selected Tick SLP Alignment",
        "",
    ]
    for tick in selected_ticks:
        ga = result["selected_snapshots"][str(tick)]["gradient_alignment"]
        md_lines.append(
            f"- Tick {tick}: direct dot mean={ga['wind_vs_pressure_gradient_dot'].get('mean')}, "
            f"cw geo dot mean={ga['wind_vs_geostrophic_cw_dot'].get('mean')}, "
            f"ccw geo dot mean={ga['wind_vs_geostrophic_ccw_dot'].get('mean')}, "
            f"corr speed~|grad SLP|={ga['corr_wind_speed_vs_slp_gradient_mag']}"
        )
    md_lines += [
        "",
        "## Lag Correlations",
        "",
        "Rows are previous-tick variables; columns are next-tick deltas.",
        "",
        "```json",
        json.dumps(result["lag_correlations_prev_wind_vs_next_delta"], ensure_ascii=False, indent=2),
        "```",
        "",
        "Full JSON:",
        f"`{OUT_JSON}`",
    ]
    OUT_MD.write_text("\n".join(md_lines), encoding="utf-8")
    print(f"Wrote {OUT_JSON}")
    print(f"Wrote {OUT_MD}")


if __name__ == "__main__":
    main()
