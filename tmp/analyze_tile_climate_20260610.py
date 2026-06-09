#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Streaming climate slice analysis for tile_data_record_20260610_010152.csv.

The script intentionally uses only the Python standard library so it can run in
the bundled project environment without installing pandas/numpy.
"""

from __future__ import annotations

import csv
import json
import math
from collections import Counter, defaultdict
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CSV_PATH = ROOT / "tmp" / "tile_data_record_20260610_010152.csv"
OUT_PATH = ROOT / "tmp" / "analysis_output" / "climate_slices_20260610.json"


FIELDS = [
    "tick_idx",
    "cell_index",
    "q",
    "r",
    "temp_arr",
    "temp_arr_prev",
    "moisture_arr",
    "moisture_arr_prev",
    "temp_baseline_arr",
    "temp_30d_arr",
    "temp_365d_arr",
    "temp_anomaly_arr",
    "sea_ice_frac_arr",
    "weather_intensity_arr",
    "weather_cloud_arr",
    "weather_cloud_water_arr",
    "weather_precip_arr",
    "weather_vapor_arr",
    "weather_convergence_arr",
    "weather_instability_arr",
    "air_mass_temp_anomaly_arr",
    "has_river_arr",
    "soil_moisture_arr",
    "water_balance_30d_arr",
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
    "terrain_arr",
    "landform_arr",
    "vegetation_arr",
    "weather_type_arr",
    "weather_prev_type_arr",
    "weather_target_type_arr",
    "is_water_arr",
    "climate_max_temp_delta",
    "climate_p99_temp_delta",
    "climate_max_transport_anomaly",
    "climate_sea_ice_delta_max",
    "climate_precip_p95",
    "climate_slp_delta_p95",
    "climate_wind_delta_p95",
    "climate_ocean_delta_p95",
    "weather_dirty_count",
    "water_budget_error",
    "active_weather_ratio",
]


NUMERIC_FIELDS = set(FIELDS) - {"is_water_arr"}


def f(row, name, default=0.0):
    try:
        value = row[name]
    except KeyError:
        return default
    if value == "":
        return default
    try:
        return float(value)
    except ValueError:
        return default


def i(row, name, default=0):
    return int(round(f(row, name, default)))


def b(row, name):
    v = row.get(name, "0")
    return v == "true" or v == "True" or v == "1" or v == 1


class Stats:
    __slots__ = ("n", "sum", "sum2", "mn", "mx")

    def __init__(self):
        self.n = 0
        self.sum = 0.0
        self.sum2 = 0.0
        self.mn = float("inf")
        self.mx = float("-inf")

    def add(self, x):
        if x is None or not math.isfinite(x):
            return
        self.n += 1
        self.sum += x
        self.sum2 += x * x
        if x < self.mn:
            self.mn = x
        if x > self.mx:
            self.mx = x

    def mean(self):
        return self.sum / self.n if self.n else None

    def std(self):
        if self.n <= 1:
            return 0.0 if self.n == 1 else None
        m = self.mean()
        return math.sqrt(max(0.0, self.sum2 / self.n - m * m))

    def to_dict(self):
        return {
            "n": self.n,
            "mean": self.mean(),
            "std": self.std(),
            "min": None if self.n == 0 else self.mn,
            "max": None if self.n == 0 else self.mx,
        }


class Corr:
    __slots__ = ("n", "sx", "sy", "sxx", "syy", "sxy")

    def __init__(self):
        self.n = 0
        self.sx = 0.0
        self.sy = 0.0
        self.sxx = 0.0
        self.syy = 0.0
        self.sxy = 0.0

    def add(self, x, y):
        if not (math.isfinite(x) and math.isfinite(y)):
            return
        self.n += 1
        self.sx += x
        self.sy += y
        self.sxx += x * x
        self.syy += y * y
        self.sxy += x * y

    def value(self):
        if self.n < 3:
            return None
        vx = self.sxx - self.sx * self.sx / self.n
        vy = self.syy - self.sy * self.sy / self.n
        if vx <= 0.0 or vy <= 0.0:
            return None
        return (self.sxy - self.sx * self.sy / self.n) / math.sqrt(vx * vy)


class Quantiles:
    def __init__(self):
        self.values = []

    def add(self, x):
        if math.isfinite(x):
            self.values.append(x)

    def to_dict(self, probs=(0.5, 0.9, 0.95, 0.99)):
        if not self.values:
            return {}
        xs = sorted(self.values)
        out = {"n": len(xs), "min": xs[0], "max": xs[-1]}
        for p in probs:
            idx = min(len(xs) - 1, max(0, int(round((len(xs) - 1) * p))))
            out[f"p{int(p * 100)}"] = xs[idx]
        return out


def lat_band(lat_norm):
    # lat_norm appears to run from -0.5 (north) to +0.5 (south).
    if lat_norm <= -0.35:
        return "N_polar"
    if lat_norm <= -0.15:
        return "N_temperate"
    if lat_norm < 0.15:
        return "tropics"
    if lat_norm < 0.35:
        return "S_temperate"
    return "S_polar"


def elev_band(e):
    if e < 0.05:
        return "low_or_sea"
    if e < 0.30:
        return "lowland"
    if e < 0.60:
        return "upland"
    return "mountain"


def time_window(tick, min_tick, max_tick):
    span = max(1, max_tick - min_tick + 1)
    p = (tick - min_tick) / span
    if p < 0.25:
        return "Q1"
    if p < 0.50:
        return "Q2"
    if p < 0.75:
        return "Q3"
    return "Q4"


def rounded_lat_bin(lat_norm, bins=80):
    z = max(-0.5, min(0.5, lat_norm))
    return int(math.floor((z + 0.5) * bins))


def rounded_y_bin(y, y_min, y_max, bins=80):
    if y_max <= y_min:
        return 0
    return int(max(0, min(bins - 1, math.floor((y - y_min) / (y_max - y_min) * bins))))


def quantize(x, q=1e-6):
    return round(x / q) * q


def first_pass():
    rows = 0
    ticks = Counter()
    y_min = float("inf")
    y_max = float("-inf")
    cells = set()
    with CSV_PATH.open("r", newline="", encoding="utf-8") as fp:
        reader = csv.DictReader(fp)
        for row in reader:
            rows += 1
            tick = i(row, "tick_idx")
            ticks[tick] += 1
            cells.add(i(row, "cell_index"))
            y = f(row, "cell_pos_y_arr")
            y_min = min(y_min, y)
            y_max = max(y_max, y)
    return rows, ticks, cells, y_min, y_max


def main():
    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    rows, tick_counts, cells, y_min, y_max = first_pass()
    sorted_ticks = sorted(tick_counts)
    min_tick, max_tick = sorted_ticks[0], sorted_ticks[-1]

    by_lat_time = defaultdict(lambda: defaultdict(Stats))
    by_land_lat = defaultdict(lambda: defaultdict(Stats))
    by_terrain = defaultdict(lambda: defaultdict(Stats))
    by_elev = defaultdict(lambda: defaultdict(Stats))
    by_time = defaultdict(lambda: defaultdict(Stats))
    by_weather_type = defaultdict(lambda: defaultdict(Stats))
    by_cell_class = defaultdict(lambda: defaultdict(Stats))

    latbin_tick_temp = defaultdict(lambda: defaultdict(Stats))
    latbin_tick_moist = defaultdict(lambda: defaultdict(Stats))
    ybin_tick_temp = defaultdict(lambda: defaultdict(Stats))

    tick_stats = defaultdict(lambda: defaultdict(Stats))
    tick_weather_types = defaultdict(Counter)
    tick_diag = defaultdict(lambda: defaultdict(Stats))

    q_temp_delta = Quantiles()
    q_moist_delta = Quantiles()
    q_precip_delta = Quantiles()
    q_vapor_delta = Quantiles()
    q_cloud_delta = Quantiles()
    q_wind_delta = Quantiles()
    q_ocean_delta = Quantiles()
    q_slp_delta = Quantiles()
    q_temp_neighbor = Quantiles()
    q_moist_neighbor = Quantiles()

    corr = defaultdict(Corr)
    weather_transition = Counter()
    weather_type_counts = Counter()
    impossible = Counter()

    per_cell_prev = {}
    per_tick_row_order = defaultdict(list)
    sampled_cells = {}
    sample_step = max(1, rows // 250000)

    with CSV_PATH.open("r", newline="", encoding="utf-8") as fp:
        reader = csv.DictReader(fp)
        for n, row in enumerate(reader, start=1):
            tick = i(row, "tick_idx")
            cell = i(row, "cell_index")
            tw = time_window(tick, min_tick, max_tick)
            lat = f(row, "cell_lat_norm_arr")
            lb = lat_band(lat)
            water = b(row, "is_water_arr")
            land_key = "water" if water else "land"
            terrain = str(i(row, "terrain_arr"))
            elev = f(row, "elevation_arr")
            eb = elev_band(elev)
            wt = str(i(row, "weather_type_arr"))
            wt_prev = str(i(row, "weather_prev_type_arr"))
            wt_tgt = str(i(row, "weather_target_type_arr"))
            wmag = math.hypot(f(row, "wind_x_arr"), f(row, "wind_y_arr"))
            omag = math.hypot(f(row, "ocean_current_x_arr"), f(row, "ocean_current_y_arr"))
            temp = f(row, "temp_arr")
            temp_prev_field = f(row, "temp_arr_prev")
            moist = f(row, "moisture_arr")
            moist_prev_field = f(row, "moisture_arr_prev")
            precip = f(row, "weather_precip_arr")
            vapor = f(row, "weather_vapor_arr")
            cloud = f(row, "weather_cloud_arr")
            conv = f(row, "weather_convergence_arr")
            inst = f(row, "weather_instability_arr")
            slp = f(row, "slp_arr")
            tta = f(row, "temperature_transport_anomaly_arr")
            base_m = f(row, "base_moisture_arr")
            soil = f(row, "soil_moisture_arr")
            wb30 = f(row, "water_balance_30d_arr")
            air_anom = f(row, "air_mass_temp_anomaly_arr")
            sea_ice = f(row, "sea_ice_frac_arr")
            snow = f(row, "snow_cover_arr")
            intensity = f(row, "weather_intensity_arr")
            cloud_water = f(row, "weather_cloud_water_arr")
            upwelling = f(row, "upwelling_strength_arr")
            curl = f(row, "wind_stress_curl_arr")

            temp_d_field = abs(temp - temp_prev_field)
            moist_d_field = abs(moist - moist_prev_field)
            q_temp_delta.add(temp_d_field)
            q_moist_delta.add(moist_d_field)

            if temp_d_field > 0.08:
                impossible["large_temp_vs_prev_field"] += 1
            if moist_d_field > 0.08:
                impossible["large_moist_vs_prev_field"] += 1
            if water and omag < 1e-5:
                impossible["water_ocean_current_zero"] += 1
            if (not water) and omag > 1e-4:
                impossible["land_ocean_current_nonzero"] += 1
            if precip > 0.3 and vapor < 0.35:
                impossible["heavy_precip_low_vapor"] += 1
            if precip > 0.25 and cloud < 0.25:
                impossible["heavy_precip_low_cloud"] += 1
            if water and temp > 0.55 and sea_ice > 0.05:
                impossible["warm_water_with_sea_ice"] += 1
            if (not water) and snow > 0.5 and temp > 0.65 and elev < 0.45:
                impossible["warm_lowland_snow"] += 1

            for group_key, bucket in (
                ((lb, tw), by_lat_time),
                ((land_key, lb), by_land_lat),
                ((terrain, land_key), by_terrain),
                ((eb, land_key), by_elev),
                ((tw,), by_time),
                ((wt,), by_weather_type),
                ((land_key, lb, eb), by_cell_class),
            ):
                stats = bucket[group_key]
                for name, val in (
                    ("temp", temp),
                    ("moisture", moist),
                    ("precip", precip),
                    ("vapor", vapor),
                    ("cloud", cloud),
                    ("intensity", intensity),
                    ("wind_mag", wmag),
                    ("ocean_mag", omag),
                    ("slp", slp),
                    ("tta", tta),
                    ("air_anom", air_anom),
                    ("sea_ice", sea_ice),
                    ("snow", snow),
                    ("soil", soil),
                    ("water_balance_30d", wb30),
                ):
                    stats[name].add(val)

            ts = tick_stats[tick]
            for name, val in (
                ("temp", temp),
                ("moisture", moist),
                ("precip", precip),
                ("vapor", vapor),
                ("cloud", cloud),
                ("wind_mag", wmag),
                ("ocean_mag", omag),
                ("slp", slp),
                ("tta", tta),
                ("sea_ice", sea_ice),
                ("snow", snow),
                ("water_budget_error", f(row, "water_budget_error")),
                ("active_weather_ratio", f(row, "active_weather_ratio")),
            ):
                ts[name].add(val)

            diag = tick_diag[tick]
            for name in (
                "climate_max_temp_delta",
                "climate_p99_temp_delta",
                "climate_max_transport_anomaly",
                "climate_sea_ice_delta_max",
                "climate_precip_p95",
                "climate_slp_delta_p95",
                "climate_wind_delta_p95",
                "climate_ocean_delta_p95",
                "weather_dirty_count",
            ):
                diag[name].add(f(row, name))

            tick_weather_types[tick][wt] += 1
            weather_type_counts[wt] += 1
            if wt != wt_prev:
                weather_transition[(wt_prev, wt)] += 1
            if wt != wt_tgt:
                weather_transition[(wt, "target_" + wt_tgt)] += 1

            lat_bin = rounded_lat_bin(lat)
            y_bin = rounded_y_bin(f(row, "cell_pos_y_arr"), y_min, y_max)
            latbin_tick_temp[tick][lat_bin].add(temp)
            latbin_tick_moist[tick][lat_bin].add(moist)
            ybin_tick_temp[tick][y_bin].add(temp)

            corr["temp_vs_lat_abs"].add(abs(lat), temp)
            corr["temp_vs_elevation_land"].add(elev, temp) if not water else None
            corr["precip_vs_vapor"].add(vapor, precip)
            corr["precip_vs_cloud"].add(cloud, precip)
            corr["precip_vs_convergence"].add(conv, precip)
            corr["precip_vs_instability"].add(inst, precip)
            corr["moisture_vs_base_moisture"].add(base_m, moist)
            corr["moisture_vs_precip"].add(precip, moist)
            corr["soil_vs_precip"].add(precip, soil)
            corr["tta_vs_ocean_mag_water"].add(omag, tta) if water else None
            corr["tta_vs_wind_mag"].add(wmag, tta)
            corr["air_anom_vs_wind_mag"].add(wmag, air_anom)
            corr["upwelling_vs_temp_water"].add(upwelling, temp) if water else None
            corr["curl_vs_ocean_mag_water"].add(curl, omag) if water else None

            prev = per_cell_prev.get(cell)
            if prev is not None:
                prev_tick, p_temp, p_moist, p_precip, p_vapor, p_cloud, p_wx, p_wy, p_ox, p_oy, p_slp = prev
                if tick != prev_tick:
                    q_precip_delta.add(abs(precip - p_precip))
                    q_vapor_delta.add(abs(vapor - p_vapor))
                    q_cloud_delta.add(abs(cloud - p_cloud))
                    q_wind_delta.add(math.hypot(f(row, "wind_x_arr") - p_wx, f(row, "wind_y_arr") - p_wy))
                    q_ocean_delta.add(math.hypot(f(row, "ocean_current_x_arr") - p_ox, f(row, "ocean_current_y_arr") - p_oy))
                    q_slp_delta.add(abs(slp - p_slp))
            per_cell_prev[cell] = (
                tick, temp, moist, precip, vapor, cloud,
                f(row, "wind_x_arr"), f(row, "wind_y_arr"),
                f(row, "ocean_current_x_arr"), f(row, "ocean_current_y_arr"), slp,
            )

            # Keep a sparse deterministic sample for possible per-cell spot checks.
            if n % sample_step == 0:
                sampled_cells.setdefault(str(cell), []).append({
                    "tick": tick,
                    "lat": lat,
                    "water": water,
                    "terrain": terrain,
                    "elev": elev,
                    "temp": temp,
                    "moisture": moist,
                    "precip": precip,
                    "vapor": vapor,
                    "wind_mag": wmag,
                    "ocean_mag": omag,
                    "weather": wt,
                })

            if n % 1000000 == 0:
                print(f"processed {n:,}/{rows:,} rows")

    def serialize_grouped(d):
        return {
            "|".join(map(str, key)): {name: stat.to_dict() for name, stat in val.items()}
            for key, val in sorted(d.items(), key=lambda kv: str(kv[0]))
        }

    def band_gradient(src):
        max_jump = {"tick": None, "from_bin": None, "to_bin": None, "delta": 0.0}
        per_tick = {}
        for tick, bins in src.items():
            means = {k: st.mean() for k, st in bins.items() if st.n > 0 and st.mean() is not None}
            jumps = []
            for k in sorted(means):
                if k + 1 in means:
                    d = abs(means[k + 1] - means[k])
                    jumps.append(d)
                    if d > max_jump["delta"]:
                        max_jump = {"tick": tick, "from_bin": k, "to_bin": k + 1, "delta": d}
            if jumps:
                jumps_sorted = sorted(jumps)
                per_tick[tick] = {
                    "mean_adjacent_delta": sum(jumps) / len(jumps),
                    "p95_adjacent_delta": jumps_sorted[int(0.95 * (len(jumps_sorted) - 1))],
                    "max_adjacent_delta": jumps_sorted[-1],
                }
        vals = [v["max_adjacent_delta"] for v in per_tick.values()]
        vals_sorted = sorted(vals)
        return {
            "max_jump": max_jump,
            "per_tick_max_delta": {
                "n": len(vals_sorted),
                "mean": sum(vals_sorted) / len(vals_sorted) if vals_sorted else None,
                "p95": vals_sorted[int(0.95 * (len(vals_sorted) - 1))] if vals_sorted else None,
                "max": vals_sorted[-1] if vals_sorted else None,
            },
        }

    tick_summary = {}
    for tick in sorted_ticks:
        tick_summary[str(tick)] = {
            "rows": tick_counts[tick],
            "stats": {name: st.to_dict() for name, st in tick_stats[tick].items()},
            "weather_types": dict(tick_weather_types[tick]),
            "diag": {name: st.to_dict() for name, st in tick_diag[tick].items()},
        }

    result = {
        "source": str(CSV_PATH),
        "rows": rows,
        "unique_cells": len(cells),
        "tick_count": len(sorted_ticks),
        "tick_min": min_tick,
        "tick_max": max_tick,
        "tick_first_10": sorted_ticks[:10],
        "tick_last_10": sorted_ticks[-10:],
        "tick_count_distribution": {
            "min": min(tick_counts.values()),
            "max": max(tick_counts.values()),
            "unique_counts": dict(Counter(tick_counts.values())),
        },
        "groups": {
            "lat_time": serialize_grouped(by_lat_time),
            "land_lat": serialize_grouped(by_land_lat),
            "terrain": serialize_grouped(by_terrain),
            "elevation": serialize_grouped(by_elev),
            "time": serialize_grouped(by_time),
            "weather_type": serialize_grouped(by_weather_type),
            "cell_class": serialize_grouped(by_cell_class),
        },
        "tick_summary": tick_summary,
        "quantiles": {
            "temp_vs_prev_field_abs_delta": q_temp_delta.to_dict(),
            "moisture_vs_prev_field_abs_delta": q_moist_delta.to_dict(),
            "precip_tick_delta": q_precip_delta.to_dict(),
            "vapor_tick_delta": q_vapor_delta.to_dict(),
            "cloud_tick_delta": q_cloud_delta.to_dict(),
            "wind_vector_tick_delta": q_wind_delta.to_dict(),
            "ocean_vector_tick_delta": q_ocean_delta.to_dict(),
            "slp_tick_delta": q_slp_delta.to_dict(),
            "temp_neighbor_delta": q_temp_neighbor.to_dict(),
            "moist_neighbor_delta": q_moist_neighbor.to_dict(),
        },
        "gradients": {
            "latbin_temp": band_gradient(latbin_tick_temp),
            "latbin_moisture": band_gradient(latbin_tick_moist),
            "ybin_temp": band_gradient(ybin_tick_temp),
        },
        "correlations": {name: {"n": c.n, "r": c.value()} for name, c in corr.items()},
        "weather_type_counts": dict(weather_type_counts),
        "weather_transition_top": [
            {"from": a, "to": b, "count": count}
            for (a, b), count in weather_transition.most_common(30)
        ],
        "flags": dict(impossible),
        "sampled_cells": sampled_cells,
    }

    OUT_PATH.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"wrote {OUT_PATH}")


if __name__ == "__main__":
    main()
