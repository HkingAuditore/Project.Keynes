import csv
import json
import math
import os
import time
from collections import Counter


CSV_PATH = r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260611_205704.csv"
OUT_PATH = r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\analysis_output\wind_validation_205704.json"


NEIGHBOR_DIRS = (
    (1, 0, -1),
    (1, -1, 0),
    (0, -1, 1),
    (-1, 0, 1),
    (-1, 1, 0),
    (0, 1, -1),
)


def f(row, idx, default=0.0):
    try:
        s = row[idx]
        if s == "" or s is None:
            return default
        return float(s)
    except Exception:
        return default


def i32(row, idx, default=0):
    try:
        s = row[idx]
        if s == "" or s is None:
            return default
        return int(float(s))
    except Exception:
        return default


def bval(row, idx):
    if idx < 0:
        return None
    s = str(row[idx]).strip().lower()
    if s in ("true", "1", "yes"):
        return True
    if s in ("false", "0", "no"):
        return False
    return None


def pct(sorted_vals, p):
    n = len(sorted_vals)
    if n == 0:
        return None
    k = int(round((n - 1) * p))
    if k < 0:
        k = 0
    elif k >= n:
        k = n - 1
    return sorted_vals[k]


def stats(vals):
    vals = [v for v in vals if v is not None and math.isfinite(v)]
    if not vals:
        return {"n": 0}
    vals.sort()
    return {
        "n": len(vals),
        "min": vals[0],
        "p05": pct(vals, 0.05),
        "p25": pct(vals, 0.25),
        "mean": sum(vals) / len(vals),
        "p50": pct(vals, 0.50),
        "p75": pct(vals, 0.75),
        "p90": pct(vals, 0.90),
        "p95": pct(vals, 0.95),
        "p99": pct(vals, 0.99),
        "max": vals[-1],
    }


def circ_metrics(wx, wy):
    n = len(wx)
    if n == 0:
        return {"count": 0}
    ux = []
    uy = []
    angles = []
    for x, y in zip(wx, wy):
        m = math.hypot(x, y)
        if m > 1e-8:
            x /= m
            y /= m
        else:
            x, y = 1.0, 0.0
        ux.append(x)
        uy.append(y)
        angles.append(math.atan2(y, x))
    cx = sum(ux) / n
    cy = sum(uy) / n
    mean = math.atan2(cy, cx)
    r = math.hypot(cx, cy)
    within15 = 0
    within30 = 0
    for a in angles:
        d = abs(math.atan2(math.sin(a - mean), math.cos(a - mean)))
        if d <= math.radians(15):
            within15 += 1
        if d <= math.radians(30):
            within30 += 1
    return {
        "count": n,
        "mean_deg": (math.degrees(mean) + 360.0) % 360.0,
        "resultant_R": r,
        "circ_std_deg": math.degrees(math.sqrt(max(0.0, -2.0 * math.log(max(r, 1e-12))))),
        "within_mean_15deg_ratio": within15 / n,
        "within_mean_30deg_ratio": within30 / n,
    }


def pearson(xs, ys):
    vals = [(x, y) for x, y in zip(xs, ys) if math.isfinite(x) and math.isfinite(y)]
    n = len(vals)
    if n < 3:
        return None
    sx = sum(x for x, _ in vals)
    sy = sum(y for _, y in vals)
    mx = sx / n
    my = sy / n
    vx = 0.0
    vy = 0.0
    cov = 0.0
    for x, y in vals:
        dx = x - mx
        dy = y - my
        vx += dx * dx
        vy += dy * dy
        cov += dx * dy
    den = math.sqrt(vx * vy)
    if den <= 1e-12:
        return None
    return cov / den


def build_pairs(qs, rs, ss):
    by_cube = {(q, r, s): idx for idx, (q, r, s) in enumerate(zip(qs, rs, ss))}
    pairs = []
    for idx, (q, r, s) in enumerate(zip(qs, rs, ss)):
        for dq, dr, ds in NEIGHBOR_DIRS:
            j = by_cube.get((q + dq, r + dr, s + ds))
            if j is not None and idx < j:
                pairs.append((idx, j))
    return pairs


def subset_metrics(indices, wx, wy, wspd, slp, temp, precip, moisture):
    if not indices:
        return {"count": 0}
    return {
        "count": len(indices),
        "dir": circ_metrics([wx[k] for k in indices], [wy[k] for k in indices]),
        "wind_speed": stats([wspd[k] for k in indices]),
        "slp": stats([slp[k] for k in indices]),
        "temp": stats([temp[k] for k in indices]),
        "precip": stats([precip[k] for k in indices]),
        "moisture": stats([moisture[k] for k in indices]),
    }


def finalize_tick(tick, rows, idx, pairs_cache):
    n = len(rows)
    qs = [i32(r, idx["q"]) for r in rows]
    rs = [i32(r, idx["r"]) for r in rows]
    ss = [i32(r, idx["s"]) for r in rows]
    wx = [f(r, idx["wind_x_arr"]) for r in rows]
    wy = [f(r, idx["wind_y_arr"]) for r in rows]
    wspd = [f(r, idx["wind_speed_arr"]) for r in rows]
    slp = [f(r, idx["slp_arr"]) for r in rows]
    temp = [f(r, idx["temp_arr"]) for r in rows]
    precip = [f(r, idx["weather_precip_arr"]) for r in rows]
    cloud = [f(r, idx["weather_cloud_arr"]) for r in rows]
    vapor = [f(r, idx["weather_vapor_arr"]) for r in rows]
    convergence = [f(r, idx["weather_convergence_arr"]) for r in rows]
    moisture = [f(r, idx["moisture_arr"]) for r in rows]
    air_anom = [f(r, idx["air_mass_temp_anomaly_arr"]) for r in rows]
    transport_anom = [f(r, idx["temperature_transport_anomaly_arr"]) for r in rows]
    pos_x = [f(r, idx["cell_pos_x_arr"]) for r in rows]
    pos_y = [f(r, idx["cell_pos_y_arr"]) for r in rows]
    is_water = [i32(r, idx["is_water_arr"]) for r in rows]
    terrain = [i32(r, idx["terrain_arr"]) for r in rows]

    pairs = pairs_cache.get("pairs")
    if pairs is None or pairs_cache.get("n") != n:
        pairs = build_pairs(qs, rs, ss)
        pairs_cache["pairs"] = pairs
        pairs_cache["n"] = n

    cos_vals = []
    angle_diffs = []
    speed_diffs = []
    slp_diffs = []
    for a, b in pairs:
        ma = math.hypot(wx[a], wy[a])
        mb = math.hypot(wx[b], wy[b])
        if ma <= 1e-8 or mb <= 1e-8:
            continue
        ca = (wx[a] * wx[b] + wy[a] * wy[b]) / (ma * mb)
        if ca < -1.0:
            ca = -1.0
        elif ca > 1.0:
            ca = 1.0
        cos_vals.append(ca)
        angle_diffs.append(math.degrees(math.acos(ca)))
        speed_diffs.append(abs(wspd[a] - wspd[b]))
        slp_diffs.append(abs(slp[a] - slp[b]))

    y_min = min(pos_y) if pos_y else 0.0
    y_max = max(pos_y) if pos_y else 1.0
    x_min = min(pos_x) if pos_x else 0.0
    x_max = max(pos_x) if pos_x else 1.0
    y_span = max(1e-6, y_max - y_min)
    x_span = max(1e-6, x_max - x_min)
    ny = [(v - y_min) / y_span for v in pos_y]
    nx = [(v - x_min) / x_span for v in pos_x]

    lat_bins = {
        "north_polar_0_15": [k for k, v in enumerate(ny) if 0.00 <= v < 0.15],
        "north_mid_15_35": [k for k, v in enumerate(ny) if 0.15 <= v < 0.35],
        "north_tropic_35_47": [k for k, v in enumerate(ny) if 0.35 <= v < 0.47],
        "equator_47_53": [k for k, v in enumerate(ny) if 0.47 <= v < 0.53],
        "south_tropic_53_65": [k for k, v in enumerate(ny) if 0.53 <= v < 0.65],
        "south_mid_65_85": [k for k, v in enumerate(ny) if 0.65 <= v < 0.85],
        "south_polar_85_100": [k for k, v in enumerate(ny) if 0.85 <= v <= 1.00],
    }
    x_bins = {
        "west_0_33": [k for k, v in enumerate(nx) if v < 0.3333],
        "central_33_66": [k for k, v in enumerate(nx) if 0.3333 <= v < 0.6667],
        "east_66_100": [k for k, v in enumerate(nx) if v >= 0.6667],
    }
    land = [k for k, v in enumerate(is_water) if v == 0]
    water = [k for k, v in enumerate(is_water) if v != 0]

    first = rows[0]
    phys = {
        "phys_wind_cpp_done": bval(first, idx.get("phys_wind_cpp_done", -1)),
        "phys_wind_commit_ok": bval(first, idx.get("phys_wind_commit_ok", -1)),
        "phys_slp_path": first[idx["phys_slp_path"]] if "phys_slp_path" in idx else "",
        "phys_psi_path": first[idx["phys_psi_path"]] if "phys_psi_path" in idx else "",
        "phys_wind_rc_ms": f(first, idx.get("phys_wind_rc_ms", -1), None) if "phys_wind_rc_ms" in idx else None,
        "phys_wind_delta_p95": f(first, idx.get("phys_wind_delta_p95", -1), None) if "phys_wind_delta_p95" in idx else None,
        "phys_stage_name": first[idx["phys_stage_name"]] if "phys_stage_name" in idx else "",
        "phys_done": bval(first, idx.get("phys_done", -1)),
    }

    mags = [math.hypot(x, y) for x, y in zip(wx, wy)]
    summary = {
        "tick": tick,
        "n_rows": n,
        "phys": phys,
        "global": {
            "dir": circ_metrics(wx, wy),
            "wind_vec_mag": stats(mags),
            "wind_speed": stats(wspd),
            "slp": stats(slp),
            "temp": stats(temp),
            "precip": stats(precip),
            "cloud": stats(cloud),
            "vapor": stats(vapor),
            "moisture": stats(moisture),
            "air_mass_temp_anomaly": stats(air_anom),
            "temperature_transport_anomaly": stats(transport_anom),
        },
        "neighbor": {
            "pairs": len(pairs),
            "dir_cos": stats(cos_vals),
            "angle_diff_deg": stats(angle_diffs),
            "speed_abs_diff": stats(speed_diffs),
            "slp_abs_diff": stats(slp_diffs),
        },
        "correlation": {
            "wind_speed_vs_precip": pearson(wspd, precip),
            "wind_speed_vs_cloud": pearson(wspd, cloud),
            "wind_speed_vs_vapor": pearson(wspd, vapor),
            "wind_speed_vs_convergence": pearson(wspd, convergence),
            "wind_speed_vs_moisture": pearson(wspd, moisture),
            "wind_speed_vs_air_mass_temp_anomaly": pearson(wspd, air_anom),
            "wind_speed_vs_temperature_transport_anomaly": pearson(wspd, transport_anom),
            "wind_speed_vs_temp": pearson(wspd, temp),
        },
        "lat_groups": {
            name: subset_metrics(indices, wx, wy, wspd, slp, temp, precip, moisture)
            for name, indices in lat_bins.items()
        },
        "x_slices": {
            name: subset_metrics(indices, wx, wy, wspd, slp, temp, precip, moisture)
            for name, indices in x_bins.items()
        },
        "surface_groups": {
            "land": subset_metrics(land, wx, wy, wspd, slp, temp, precip, moisture),
            "water": subset_metrics(water, wx, wy, wspd, slp, temp, precip, moisture),
        },
        "terrain_counts": dict(Counter(terrain)),
    }
    return summary


def compact_tick(summary):
    g = summary["global"]
    n = summary["neighbor"]
    return {
        "tick": summary["tick"],
        "n_rows": summary["n_rows"],
        "phys": summary["phys"],
        "dir_R": g["dir"]["resultant_R"],
        "dir_mean_deg": g["dir"]["mean_deg"],
        "within15": g["dir"]["within_mean_15deg_ratio"],
        "within30": g["dir"]["within_mean_30deg_ratio"],
        "wind_vec_mag_mean": g["wind_vec_mag"]["mean"],
        "wind_speed_mean": g["wind_speed"]["mean"],
        "wind_speed_p05": g["wind_speed"]["p05"],
        "wind_speed_p50": g["wind_speed"]["p50"],
        "wind_speed_p95": g["wind_speed"]["p95"],
        "neighbor_cos_mean": n["dir_cos"]["mean"],
        "neighbor_angle_p50": n["angle_diff_deg"]["p50"],
        "neighbor_angle_p95": n["angle_diff_deg"]["p95"],
        "neighbor_speed_diff_p95": n["speed_abs_diff"]["p95"],
        "corr": summary["correlation"],
    }


def aggregate_time(ticks):
    def collect(path):
        vals = []
        for t in ticks:
            cur = t
            ok = True
            for key in path:
                if cur is None or key not in cur:
                    ok = False
                    break
                cur = cur[key]
            if ok and isinstance(cur, (int, float)) and cur is not None and math.isfinite(cur):
                vals.append(float(cur))
        return stats(vals)

    return {
        "tick_count": len(ticks),
        "rows_per_tick": stats([t["n_rows"] for t in ticks]),
        "dir_R": collect(["global", "dir", "resultant_R"]),
        "within15": collect(["global", "dir", "within_mean_15deg_ratio"]),
        "within30": collect(["global", "dir", "within_mean_30deg_ratio"]),
        "wind_speed_mean": collect(["global", "wind_speed", "mean"]),
        "wind_speed_p95": collect(["global", "wind_speed", "p95"]),
        "neighbor_cos_mean": collect(["neighbor", "dir_cos", "mean"]),
        "neighbor_angle_p50": collect(["neighbor", "angle_diff_deg", "p50"]),
        "neighbor_angle_p95": collect(["neighbor", "angle_diff_deg", "p95"]),
        "phys_wind_rc_ms": collect(["phys", "phys_wind_rc_ms"]),
        "phys_wind_delta_p95": collect(["phys", "phys_wind_delta_p95"]),
    }


def main():
    t0 = time.time()
    os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True)
    ticks = []
    pairs_cache = {}
    current_tick = None
    rows = []
    tick_stage = Counter()
    phys_done_counts = Counter()
    total_rows = 0

    with open(CSV_PATH, newline="", encoding="utf-8-sig") as fh:
        reader = csv.reader(fh)
        header = next(reader)
        idx = {name: n for n, name in enumerate(header)}

        needed = [
            "tick_idx", "q", "r", "s", "wind_x_arr", "wind_y_arr", "wind_speed_arr",
            "slp_arr", "temp_arr", "weather_precip_arr", "weather_cloud_arr",
            "weather_vapor_arr", "weather_convergence_arr", "moisture_arr",
            "air_mass_temp_anomaly_arr", "temperature_transport_anomaly_arr",
            "cell_pos_x_arr", "cell_pos_y_arr", "is_water_arr", "terrain_arr",
        ]
        missing = [name for name in needed if name not in idx]
        if missing:
            raise SystemExit(f"Missing columns: {missing}")

        for row in reader:
            total_rows += 1
            tick = i32(row, idx["tick_idx"])
            if current_tick is None:
                current_tick = tick
            if tick != current_tick:
                summary = finalize_tick(current_tick, rows, idx, pairs_cache)
                ticks.append(summary)
                tick_stage[summary["phys"].get("phys_stage_name", "")] += 1
                phys_done_counts[str(summary["phys"].get("phys_wind_cpp_done"))] += 1
                rows = []
                current_tick = tick
            rows.append(row)

        if rows:
            summary = finalize_tick(current_tick, rows, idx, pairs_cache)
            ticks.append(summary)
            tick_stage[summary["phys"].get("phys_stage_name", "")] += 1
            phys_done_counts[str(summary["phys"].get("phys_wind_cpp_done"))] += 1

    tick_ids = [t["tick"] for t in ticks]
    sample_positions = []
    if ticks:
        for frac in (0.0, 0.25, 0.50, 0.75, 1.0):
            sample_positions.append(int(round((len(ticks) - 1) * frac)))
    sample_positions = sorted(set(sample_positions))
    sample_ticks = [ticks[pos] for pos in sample_positions]

    result = {
        "csv": CSV_PATH,
        "elapsed_sec": time.time() - t0,
        "total_rows": total_rows,
        "tick_min": min(tick_ids) if tick_ids else None,
        "tick_max": max(tick_ids) if tick_ids else None,
        "time_aggregate": aggregate_time(ticks),
        "tick_stage_counts": dict(tick_stage),
        "phys_wind_cpp_done_counts": dict(phys_done_counts),
        "sample_ticks": [compact_tick(t) for t in sample_ticks],
        "sample_tick_details": {
            str(t["tick"]): {
                "global": t["global"],
                "neighbor": t["neighbor"],
                "correlation": t["correlation"],
                "lat_groups": t["lat_groups"],
                "x_slices": t["x_slices"],
                "surface_groups": t["surface_groups"],
                "phys": t["phys"],
            }
            for t in sample_ticks
        },
    }
    with open(OUT_PATH, "w", encoding="utf-8") as out:
        json.dump(result, out, ensure_ascii=False, indent=2)
    print(json.dumps({
        "out": OUT_PATH,
        "elapsed_sec": result["elapsed_sec"],
        "total_rows": total_rows,
        "tick_count": len(ticks),
        "tick_min": result["tick_min"],
        "tick_max": result["tick_max"],
        "aggregate": result["time_aggregate"],
        "sample_ticks": result["sample_ticks"],
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
