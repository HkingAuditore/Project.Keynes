import json
import math
from pathlib import Path

import numpy as np
import pandas as pd


CSV_PATH = Path(r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260611_163535.csv")
OUT_PATH = Path(r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\analysis_output\tile_data_record_20260611_163535_wind_snapshot.json")

cols = [
    "tick_idx", "cell_index", "q", "r", "cell_pos_x_arr", "cell_pos_y_arr",
    "cell_lat_norm_arr", "is_water_arr", "wind_x_arr", "wind_y_arr",
    "wind_speed_arr", "slp_arr", "weather_convergence_arr",
    "weather_precip_arr", "temperature_transport_anomaly_arr",
    "air_mass_temp_anomaly_arr",
]

df = pd.read_csv(CSV_PATH, usecols=cols, nrows=2400, low_memory=False).sort_values("cell_index")
tick = int(df["tick_idx"].iloc[0])

q = df["q"].to_numpy(np.int32)
r = df["r"].to_numpy(np.int32)
x = df["cell_pos_x_arr"].to_numpy(float)
y = df["cell_pos_y_arr"].to_numpy(float)
lat = df["cell_lat_norm_arr"].to_numpy(float)
water = df["is_water_arr"].to_numpy(float) > 0.5
wx = df["wind_x_arr"].to_numpy(float)
wy = df["wind_y_arr"].to_numpy(float)
ws = df["wind_speed_arr"].to_numpy(float)
vmag = np.sqrt(wx * wx + wy * wy)
slp = df["slp_arr"].to_numpy(float)
conv = df["weather_convergence_arr"].to_numpy(float)

index_by_coord = {(int(q[i]), int(r[i])): i for i in range(len(q))}
dirs = [(1, 0), (1, -1), (0, -1), (-1, 0), (-1, 1), (0, 1)]
neighbors = [[] for _ in range(len(q))]
pairs = []
for i in range(len(q)):
    for dq, dr in dirs:
        j = index_by_coord.get((int(q[i]) + dq, int(r[i]) + dr), -1)
        if j >= 0:
            neighbors[i].append(j)
            if i < j:
                pairs.append((i, j))
pairs = np.array(pairs, dtype=np.int32)

i = pairs[:, 0]
j = pairs[:, 1]
den = vmag[i] * vmag[j]
ok = den > 1e-12
cos = np.full(i.shape, np.nan)
cos[ok] = (wx[i][ok] * wx[j][ok] + wy[i][ok] * wy[j][ok]) / den[ok]

grad_x = np.full(len(q), np.nan)
grad_y = np.full(len(q), np.nan)
div = np.full(len(q), np.nan)
curl = np.full(len(q), np.nan)
for idx, neigh in enumerate(neighbors):
    if len(neigh) < 2:
        continue
    neigh = np.array(neigh, dtype=np.int32)
    dx = x[neigh] - x[idx]
    dy = y[neigh] - y[idx]
    a00 = float(dx @ dx)
    a01 = float(dx @ dy)
    a11 = float(dy @ dy)
    det = a00 * a11 - a01 * a01
    if abs(det) < 1e-12:
        continue
    def fit(values):
        b = values[neigh] - values[idx]
        bx = float(dx @ b)
        by = float(dy @ b)
        return (a11 * bx - a01 * by) / det, (-a01 * bx + a00 * by) / det
    grad_x[idx], grad_y[idx] = fit(slp)
    du_dx, du_dy = fit(wx)
    dv_dx, dv_dy = fit(wy)
    div[idx] = du_dx + dv_dy
    curl[idx] = dv_dx - du_dy

grad_mag = np.sqrt(grad_x * grad_x + grad_y * grad_y)
den2 = grad_mag * vmag
ok2 = np.isfinite(den2) & (den2 > 1e-12)
down_cos = np.full(len(q), np.nan)
isobar_abs_cos = np.full(len(q), np.nan)
down_cos[ok2] = (wx[ok2] * (-grad_x[ok2]) + wy[ok2] * (-grad_y[ok2])) / den2[ok2]
isobar_abs_cos[ok2] = np.abs(wx[ok2] * (-grad_y[ok2]) + wy[ok2] * grad_x[ok2]) / den2[ok2]


def corr(a, b):
    a = np.asarray(a, float)
    b = np.asarray(b, float)
    ok = np.isfinite(a) & np.isfinite(b)
    if ok.sum() < 3:
        return None
    return float(np.corrcoef(a[ok], b[ok])[0, 1])


def stats(a):
    a = np.asarray(a, float)
    a = a[np.isfinite(a)]
    return {
        "min": float(a.min()),
        "mean": float(a.mean()),
        "p05": float(np.quantile(a, 0.05)),
        "p50": float(np.quantile(a, 0.50)),
        "p95": float(np.quantile(a, 0.95)),
        "max": float(a.max()),
        "std": float(a.std()),
    }


bands = {}
for lo, hi in [(0, .2), (.2, .4), (.4, .6), (.6, .8), (.8, 1.000001)]:
    mask = (lat >= lo) & (lat < hi)
    name = f"lat_{lo:.1f}_{hi:.1f}"
    bands[name] = {
        "n": int(mask.sum()),
        "wind_x_mean": float(wx[mask].mean()),
        "wind_y_mean": float(wy[mask].mean()),
        "vector_mag_mean": float(vmag[mask].mean()),
        "wind_speed_arr_mean": float(ws[mask].mean()),
        "slp_mean": float(slp[mask].mean()),
        "down_pressure_cos_mean": float(np.nanmean(down_cos[mask])),
        "isobar_abs_cos_mean": float(np.nanmean(isobar_abs_cos[mask])),
    }

out = {
    "tick_idx": tick,
    "wind_x": stats(wx),
    "wind_y": stats(wy),
    "wind_speed_arr": stats(ws),
    "vector_magnitude_from_xy": stats(vmag),
    "wind_speed_arr_vs_xy_magnitude_corr": corr(ws, vmag),
    "slp": stats(slp),
    "neighbor_vector_cos_mean": float(np.nanmean(cos)),
    "neighbor_vector_cos_p05": float(np.nanquantile(cos, 0.05)),
    "neighbor_speed_arr_diff_mean": float(np.mean(np.abs(ws[i] - ws[j]))),
    "pressure_gradient_mag": stats(grad_mag),
    "wind_vs_down_pressure_cos_mean": float(np.nanmean(down_cos)),
    "wind_vs_isobar_abs_cos_mean": float(np.nanmean(isobar_abs_cos)),
    "wind_speed_arr_vs_pressure_gradient_corr": corr(ws, grad_mag),
    "vector_mag_vs_pressure_gradient_corr": corr(vmag, grad_mag),
    "divergence_abs_p95": float(np.nanquantile(np.abs(div), 0.95)),
    "curl_abs_p95": float(np.nanquantile(np.abs(curl), 0.95)),
    "divergence_vs_weather_convergence_corr": corr(div, conv),
    "bands": bands,
    "water_land": {
        "water": {
            "n": int(water.sum()),
            "wind_speed_arr_mean": float(ws[water].mean()),
            "vector_mag_mean": float(vmag[water].mean()),
            "slp_mean": float(slp[water].mean()),
        },
        "land": {
            "n": int((~water).sum()),
            "wind_speed_arr_mean": float(ws[~water].mean()),
            "vector_mag_mean": float(vmag[~water].mean()),
            "slp_mean": float(slp[~water].mean()),
        },
    },
}

OUT_PATH.write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
print(json.dumps(out, ensure_ascii=False, indent=2))
