#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Spatial/temporal checks for the 2026-06-10 climate tile dump."""

from __future__ import annotations

import csv
import json
import math
from collections import Counter, defaultdict
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CSV_PATH = ROOT / "tmp" / "tile_data_record_20260610_010152.csv"
OUT_PATH = ROOT / "tmp" / "analysis_output" / "climate_spatial_20260610.json"

NEIGHBORS = ((1, 0), (1, -1), (0, -1), (-1, 0), (-1, 1), (0, 1))


def fl(row, name, default=0.0):
    v = row.get(name, "")
    if v == "":
        return default
    try:
        return float(v)
    except ValueError:
        return default


def it(row, name, default=0):
    return int(round(fl(row, name, default)))


def bo(row, name):
    v = row.get(name, "0")
    return v in ("1", "true", "True", 1, True)


class Quant:
    def __init__(self):
        self.values = []

    def add(self, x):
        if math.isfinite(x):
            self.values.append(x)

    def merge(self, xs):
        self.values.extend(x for x in xs if math.isfinite(x))

    def summary(self):
        if not self.values:
            return {}
        xs = sorted(self.values)
        out = {"n": len(xs), "min": xs[0], "max": xs[-1]}
        for p in (0.5, 0.9, 0.95, 0.99, 0.999):
            idx = min(len(xs) - 1, max(0, int(round((len(xs) - 1) * p))))
            out[f"p{int(p * 1000) / 10:g}"] = xs[idx]
        out["mean"] = sum(xs) / len(xs)
        return out


class Acc:
    def __init__(self):
        self.n = 0
        self.s = 0.0

    def add(self, x):
        if math.isfinite(x):
            self.n += 1
            self.s += x

    def mean(self):
        return self.s / self.n if self.n else None


def corr_from_pairs(pairs):
    n = len(pairs)
    if n < 3:
        return None
    sx = sum(x for x, _ in pairs)
    sy = sum(y for _, y in pairs)
    sxx = sum(x * x for x, _ in pairs)
    syy = sum(y * y for _, y in pairs)
    sxy = sum(x * y for x, y in pairs)
    vx = sxx - sx * sx / n
    vy = syy - sy * sy / n
    if vx <= 0 or vy <= 0:
        return None
    return (sxy - sx * sy / n) / math.sqrt(vx * vy)


def finalize_tick(tick, rows, qr_to_cell, summaries, top_edges, row_profiles, prev_tick_rows):
    if not rows:
        return

    q_temp = []
    q_moist = []
    q_precip = []
    q_weather = []
    coast_temp = Quant()
    same_lat_temp = Quant()
    cross_lat_temp = Quant()
    large_edges = []

    cells = list(rows)
    for cell in cells:
        a = rows[cell]
        q = a["q"]
        r = a["r"]
        for dq, dr in NEIGHBORS:
            nb = qr_to_cell.get((q + dq, r + dr))
            if nb is None or nb <= cell or nb not in rows:
                continue
            b = rows[nb]
            dt = abs(a["temp"] - b["temp"])
            dm = abs(a["moisture"] - b["moisture"])
            dp = abs(a["precip"] - b["precip"])
            q_temp.append(dt)
            q_moist.append(dm)
            q_precip.append(dp)
            q_weather.append(0.0 if a["weather"] == b["weather"] else 1.0)
            if a["water"] != b["water"]:
                coast_temp.add(dt)
            if round(a["lat"], 6) == round(b["lat"], 6):
                same_lat_temp.add(dt)
            else:
                cross_lat_temp.add(dt)
            if dt >= 0.25:
                large_edges.append({
                    "tick": tick,
                    "a": cell,
                    "b": nb,
                    "dt": dt,
                    "a_temp": a["temp"],
                    "b_temp": b["temp"],
                    "a_lat": a["lat"],
                    "b_lat": b["lat"],
                    "a_qr": [a["q"], a["r"]],
                    "b_qr": [b["q"], b["r"]],
                    "a_water": a["water"],
                    "b_water": b["water"],
                    "a_elev": a["elev"],
                    "b_elev": b["elev"],
                    "a_weather": a["weather"],
                    "b_weather": b["weather"],
                })

    for name, vals in (
        ("neighbor_temp_delta", q_temp),
        ("neighbor_moisture_delta", q_moist),
        ("neighbor_precip_delta", q_precip),
        ("neighbor_weather_type_diff", q_weather),
    ):
        summaries[name].merge(vals)

    summaries["coast_neighbor_temp_delta"].merge(coast_temp.values)
    summaries["same_lat_neighbor_temp_delta"].merge(same_lat_temp.values)
    summaries["cross_lat_neighbor_temp_delta"].merge(cross_lat_temp.values)
    top_edges.extend(large_edges)
    top_edges.sort(key=lambda x: x["dt"], reverse=True)
    del top_edges[80:]

    # Exact latitude-row and screen-y-row profiles.
    lat_rows = defaultdict(lambda: {"temp": Acc(), "moist": Acc(), "precip": Acc(), "count": 0})
    y_rows = defaultdict(lambda: {"temp": Acc(), "moist": Acc(), "precip": Acc(), "count": 0})
    for row in rows.values():
        lat_key = round(row["lat"], 6)
        y_key = round(row["y"], 6)
        for bucket, key in ((lat_rows, lat_key), (y_rows, y_key)):
            bucket[key]["temp"].add(row["temp"])
            bucket[key]["moist"].add(row["moisture"])
            bucket[key]["precip"].add(row["precip"])
            bucket[key]["count"] += 1

    for label, grouped in (("lat", lat_rows), ("y", y_rows)):
        ordered = sorted(grouped.items())
        jumps = []
        for idx in range(len(ordered) - 1):
            k0, v0 = ordered[idx]
            k1, v1 = ordered[idx + 1]
            t0 = v0["temp"].mean()
            t1 = v1["temp"].mean()
            if t0 is None or t1 is None:
                continue
            jumps.append({
                "tick": tick,
                "axis": label,
                "from": k0,
                "to": k1,
                "dt": abs(t1 - t0),
                "temp0": t0,
                "temp1": t1,
                "count0": v0["count"],
                "count1": v1["count"],
            })
        if jumps:
            jumps.sort(key=lambda x: x["dt"], reverse=True)
            row_profiles[f"{label}_top_jumps"].extend(jumps[:5])

    if prev_tick_rows:
        wind_pairs = []
        ocean_pairs = []
        temp_pairs = []
        moist_pairs = []
        for cell, row in rows.items():
            prev = prev_tick_rows.get(cell)
            if prev is None:
                continue
            dtemp = abs(row["temp"] - prev["temp"])
            dmoist = abs(row["moisture"] - prev["moisture"])
            dwind = math.hypot(row["wx"] - prev["wx"], row["wy"] - prev["wy"])
            doc = math.hypot(row["ox"] - prev["ox"], row["oy"] - prev["oy"])
            temp_pairs.append((dwind, dtemp))
            moist_pairs.append((dwind, dmoist))
            ocean_pairs.append((doc, dtemp))
            wind_pairs.append((dwind, dmoist))
        row_profiles["tick_delta_correlations"].append({
            "tick": tick,
            "wind_delta_vs_temp_delta": corr_from_pairs(temp_pairs),
            "wind_delta_vs_moist_delta": corr_from_pairs(wind_pairs),
            "ocean_delta_vs_temp_delta": corr_from_pairs(ocean_pairs),
            "rows": len(temp_pairs),
        })


def main():
    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    qr_to_cell = {}
    current_tick = None
    current_rows = {}
    prev_tick_rows = {}
    summaries = defaultdict(Quant)
    top_edges = []
    row_profiles = defaultdict(list)
    tick_count = 0
    row_count = 0

    with CSV_PATH.open("r", newline="", encoding="utf-8") as fp:
        reader = csv.DictReader(fp)
        for row in reader:
            row_count += 1
            tick = it(row, "tick_idx")
            if current_tick is None:
                current_tick = tick
            if tick != current_tick:
                finalize_tick(current_tick, current_rows, qr_to_cell, summaries, top_edges, row_profiles, prev_tick_rows)
                prev_tick_rows = current_rows
                current_rows = {}
                current_tick = tick
                tick_count += 1
                if tick_count % 100 == 0:
                    print(f"finalized {tick_count} ticks")

            cell = it(row, "cell_index")
            q = it(row, "q")
            r = it(row, "r")
            qr_to_cell[(q, r)] = cell
            current_rows[cell] = {
                "q": q,
                "r": r,
                "lat": fl(row, "cell_lat_norm_arr"),
                "x": fl(row, "cell_pos_x_arr"),
                "y": fl(row, "cell_pos_y_arr"),
                "water": bo(row, "is_water_arr"),
                "elev": fl(row, "elevation_arr"),
                "temp": fl(row, "temp_arr"),
                "moisture": fl(row, "moisture_arr"),
                "precip": fl(row, "weather_precip_arr"),
                "vapor": fl(row, "weather_vapor_arr"),
                "cloud": fl(row, "weather_cloud_arr"),
                "weather": it(row, "weather_type_arr"),
                "wx": fl(row, "wind_x_arr"),
                "wy": fl(row, "wind_y_arr"),
                "ox": fl(row, "ocean_current_x_arr"),
                "oy": fl(row, "ocean_current_y_arr"),
            }

    if current_rows:
        finalize_tick(current_tick, current_rows, qr_to_cell, summaries, top_edges, row_profiles, prev_tick_rows)
        tick_count += 1

    for key in ("lat_top_jumps", "y_top_jumps"):
        row_profiles[key].sort(key=lambda x: x["dt"], reverse=True)
        row_profiles[key] = row_profiles[key][:60]

    result = {
        "source": str(CSV_PATH),
        "rows": row_count,
        "ticks": tick_count,
        "summaries": {name: q.summary() for name, q in summaries.items()},
        "top_neighbor_temp_edges": top_edges,
        "row_profile_top_jumps": {
            "lat": row_profiles["lat_top_jumps"],
            "y": row_profiles["y_top_jumps"],
        },
        "tick_delta_correlations_sample": row_profiles["tick_delta_correlations"][:20],
    }
    OUT_PATH.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"wrote {OUT_PATH}")


if __name__ == "__main__":
    main()
