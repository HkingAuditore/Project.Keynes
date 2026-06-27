#!/usr/bin/env python3
"""Analyze Project.Keynes tile-data climate CSV exports.

The recorder stores ``cell_lat_norm_arr`` as ny in [0, 1].  For climate
diagnostics, use absolute latitude ``abs(2 * ny - 1)``; treating ny itself as
absolute latitude swaps equator/pole interpretation.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Any

import numpy as np
import pandas as pd


CORE_COLUMNS = [
    "tick_idx",
    "cell_index",
    "q",
    "r",
    "s",
    "cell_lat_norm_arr",
    "cell_pos_x_arr",
    "cell_pos_y_arr",
    "temp_arr",
    "moisture_arr",
    "base_moisture_arr",
    "sea_ice_frac_arr",
    "is_water_arr",
    "wind_x_arr",
    "wind_y_arr",
    "wind_speed_arr",
    "ocean_current_x_arr",
    "ocean_current_y_arr",
    "upwelling_strength_arr",
    "phys_ocean_current_clamp_ratio",
    "phys_ocean_current_max_magnitude",
    "phys_daily_wind_delta_p95",
    "phys_daily_wind_dir_delta_p95",
    "phys_daily_wind_dir_flip_count",
]


def _qstats(values: pd.Series | np.ndarray) -> dict[str, float | int]:
    s = pd.to_numeric(pd.Series(values), errors="coerce").replace([np.inf, -np.inf], np.nan).dropna()
    if s.empty:
        return {}
    q = s.quantile([0, 0.01, 0.05, 0.25, 0.5, 0.75, 0.95, 0.99, 1.0])
    return {
        "count": int(s.size),
        "mean": float(s.mean()),
        "std": float(s.std(ddof=0)),
        "min": float(q.loc[0]),
        "p01": float(q.loc[0.01]),
        "p05": float(q.loc[0.05]),
        "p25": float(q.loc[0.25]),
        "p50": float(q.loc[0.5]),
        "p75": float(q.loc[0.75]),
        "p95": float(q.loc[0.95]),
        "p99": float(q.loc[0.99]),
        "max": float(q.loc[1.0]),
    }


def _corr(a: pd.Series, b: pd.Series) -> float | None:
    aa = pd.to_numeric(a, errors="coerce")
    bb = pd.to_numeric(b, errors="coerce")
    mask = aa.notna() & bb.notna()
    if int(mask.sum()) < 3:
        return None
    out = float(np.corrcoef(aa[mask], bb[mask])[0, 1])
    return None if math.isnan(out) else out


def _ratio(mask: pd.Series | np.ndarray, denom: int | None = None) -> float:
    if denom is None:
        denom = len(mask)
    return 0.0 if denom <= 0 else float(np.asarray(mask).sum() / denom)


def _neighbor_pairs(tick_df: pd.DataFrame) -> tuple[np.ndarray, np.ndarray]:
    coord_to_row = {
        (int(row.q), int(row.r), int(row.s)): i
        for i, row in enumerate(tick_df[["q", "r", "s"]].itertuples(index=False))
    }
    dirs = [(1, -1, 0), (1, 0, -1), (0, 1, -1)]
    left: list[int] = []
    right: list[int] = []
    for i, row in enumerate(tick_df[["q", "r", "s"]].itertuples(index=False)):
        q, r, s = int(row.q), int(row.r), int(row.s)
        for dq, dr, ds in dirs:
            j = coord_to_row.get((q + dq, r + dr, s + ds))
            if j is not None:
                left.append(i)
                right.append(j)
    return np.array(left, dtype=np.int64), np.array(right, dtype=np.int64)


def _spatial_neighbor_stats(df: pd.DataFrame, ticks: list[int]) -> dict[str, Any]:
    fields = ["temp_arr", "moisture_arr", "sea_ice_frac_arr", "wind_speed_arr", "ocean_current_mag"]
    out: dict[str, Any] = {}
    for tick in ticks:
        tdf = df[df["tick_idx"] == tick].drop_duplicates("cell_index").reset_index(drop=True)
        if tdf.empty:
            continue
        left, right = _neighbor_pairs(tdf)
        if left.size <= 0:
            continue
        item: dict[str, Any] = {"edges": int(left.size)}
        for field in fields:
            vals = np.abs(tdf[field].to_numpy()[left] - tdf[field].to_numpy()[right])
            item[field] = _qstats(vals)
        out[str(tick)] = item
    return out


def analyze(path: Path) -> dict[str, Any]:
    header = pd.read_csv(path, nrows=0).columns.tolist()
    cols = [c for c in CORE_COLUMNS if c in header]
    df = pd.read_csv(path, usecols=cols, low_memory=False)
    for col in cols:
        df[col] = pd.to_numeric(df[col], errors="coerce")

    df["abs_lat"] = (df["cell_lat_norm_arr"] * 2.0 - 1.0).abs().clip(0.0, 1.0)
    df["wind_dir_mag"] = np.hypot(df["wind_x_arr"], df["wind_y_arr"])
    df["ocean_current_mag"] = np.hypot(df["ocean_current_x_arr"], df["ocean_current_y_arr"])

    df = df.sort_values(["cell_index", "tick_idx"]).reset_index(drop=True)
    df["td_wind_vec"] = np.hypot(df.groupby("cell_index")["wind_x_arr"].diff(), df.groupby("cell_index")["wind_y_arr"].diff())
    df["td_ocean_vec"] = np.hypot(
        df.groupby("cell_index")["ocean_current_x_arr"].diff(),
        df.groupby("cell_index")["ocean_current_y_arr"].diff(),
    )
    df["td_sea_ice"] = df.groupby("cell_index")["sea_ice_frac_arr"].diff().abs()
    df["td_moisture"] = df.groupby("cell_index")["moisture_arr"].diff().abs()
    df["td_temp"] = df.groupby("cell_index")["temp_arr"].diff().abs()

    water = df["is_water_arr"].fillna(0).astype(int) == 1
    land = ~water
    ticks = sorted(int(t) for t in df["tick_idx"].dropna().unique())
    sample_ticks = [ticks[0], ticks[len(ticks) // 2], ticks[-1]] if ticks else []

    wind_flip_gt_120 = df["td_wind_vec"] > (2.0 * math.sin(math.radians(120.0) * 0.5))
    out: dict[str, Any] = {
        "source": str(path),
        "rows": int(len(df)),
        "tick_count": int(len(ticks)),
        "cell_count": int(df["cell_index"].nunique()),
        "lat_semantics": "abs_lat = abs(2 * cell_lat_norm_arr - 1)",
        "field_stats": {
            "temp_arr": _qstats(df["temp_arr"]),
            "moisture_arr": _qstats(df["moisture_arr"]),
            "sea_ice_frac_arr": _qstats(df["sea_ice_frac_arr"]),
            "wind_dir_mag": _qstats(df["wind_dir_mag"]),
            "wind_speed_arr": _qstats(df["wind_speed_arr"]),
            "ocean_current_mag": _qstats(df["ocean_current_mag"]),
        },
        "temporal_delta_stats": {
            "td_temp": _qstats(df["td_temp"]),
            "td_moisture": _qstats(df["td_moisture"]),
            "td_sea_ice": _qstats(df["td_sea_ice"]),
            "td_wind_vec": _qstats(df["td_wind_vec"]),
            "td_ocean_vec": _qstats(df["td_ocean_vec"]),
        },
        "issue_counters": {
            "equatorial_sea_ice_gt_005_rows_abs_lat_lt_035": int(((df["abs_lat"] < 0.35) & (df["sea_ice_frac_arr"] > 0.05)).sum()),
            "land_sea_ice_gt_005_rows": int((land & (df["sea_ice_frac_arr"] > 0.05)).sum()),
            "water_ocean_current_eq_zero_ratio": _ratio(water & (df["ocean_current_mag"] <= 1e-6), int(water.sum())),
            "land_ocean_current_gt_001_rows": int((land & (df["ocean_current_mag"] > 0.001)).sum()),
            "sea_ice_binary_ratio": _ratio((df["sea_ice_frac_arr"] <= 1e-6) | ((df["sea_ice_frac_arr"] - 1.0).abs() <= 1e-6)),
            "moisture_exact_one_ratio": _ratio((df["moisture_arr"] - 1.0).abs() <= 1e-6),
            "wind_flip_gt_120deg_ratio": _ratio(wind_flip_gt_120.dropna()),
        },
        "correlations": {
            "temp_vs_abs_lat": _corr(df["temp_arr"], df["abs_lat"]),
            "sea_ice_vs_abs_lat": _corr(df["sea_ice_frac_arr"], df["abs_lat"]),
            "sea_ice_vs_temp": _corr(df["sea_ice_frac_arr"], df["temp_arr"]),
            "moisture_vs_base_moisture": _corr(df["moisture_arr"], df["base_moisture_arr"]),
        },
        "spatial_neighbor_stats": _spatial_neighbor_stats(df, sample_ticks),
    }
    if "phys_ocean_current_clamp_ratio" in df:
        per_tick = df.drop_duplicates("tick_idx")
        out["global_tick_stats"] = {
            "phys_ocean_current_clamp_ratio": _qstats(per_tick["phys_ocean_current_clamp_ratio"]),
            "phys_ocean_current_max_magnitude": _qstats(per_tick["phys_ocean_current_max_magnitude"]),
            "phys_daily_wind_delta_p95": _qstats(per_tick["phys_daily_wind_delta_p95"]),
            "phys_daily_wind_dir_delta_p95": _qstats(per_tick["phys_daily_wind_dir_delta_p95"])
            if "phys_daily_wind_dir_delta_p95" in per_tick else {},
            "phys_daily_wind_dir_flip_count": _qstats(per_tick["phys_daily_wind_dir_flip_count"])
            if "phys_daily_wind_dir_flip_count" in per_tick else {},
        }
    return out


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("csv", type=Path, help="tile_data_record_*.csv path")
    parser.add_argument("-o", "--output", type=Path, help="JSON output path")
    args = parser.parse_args()

    result = analyze(args.csv)
    payload = json.dumps(result, ensure_ascii=False, indent=2)
    if args.output:
        args.output.write_text(payload, encoding="utf-8")
    print(payload)


if __name__ == "__main__":
    main()
