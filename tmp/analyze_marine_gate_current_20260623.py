import csv
import math
import sys
from collections import Counter, defaultdict


PRECIP_TYPES = {1, 2, 3, 7}


def f(row, col, name, default=0.0):
    idx = col.get(name)
    if idx is None:
        return default
    try:
        s = row[idx]
        return float(s) if s else default
    except Exception:
        return default


def i(row, col, name, default=0):
    idx = col.get(name)
    if idx is None:
        return default
    try:
        s = row[idx]
        return int(float(s)) if s else default
    except Exception:
        return default


def smoothstep(a, b, x):
    if b == a:
        return 1.0 if x >= b else 0.0
    t = max(0.0, min(1.0, (x - a) / (b - a)))
    return t * t * (3.0 - 2.0 * t)


def pct(values, q):
    if not values:
        return 0.0
    values = sorted(values)
    k = (len(values) - 1) * q
    lo = int(math.floor(k))
    hi = int(math.ceil(k))
    if lo == hi:
        return values[lo]
    return values[lo] + (values[hi] - values[lo]) * (k - lo)


def main():
    path = sys.argv[1]
    with open(path, "r", encoding="utf-8", newline="") as fh:
        reader = csv.reader(fh)
        header = next(reader)
        col = {name: idx for idx, name in enumerate(header)}

    seen_commits = set()
    current_tick = None
    process_tick = False
    vals = defaultdict(list)
    counts = Counter()
    by_tick = defaultdict(list)

    with open(path, "r", encoding="utf-8", newline="") as fh:
        reader = csv.reader(fh)
        next(reader)
        for row in reader:
            tick = i(row, col, "tick_idx")
            if tick != current_tick:
                current_tick = tick
                commit = i(row, col, "weather_last_commit_tick", tick)
                process_tick = commit not in seen_commits
                if process_tick:
                    seen_commits.add(commit)
            if not process_tick:
                continue
            if i(row, col, "is_water_arr") == 0:
                continue
            terrain = i(row, col, "terrain_arr")
            if terrain == 18:
                continue
            temp = f(row, col, "weather_classification_temp_arr", f(row, col, "temp_arr"))
            temp = max(0.0, min(1.0, temp + f(row, col, "air_mass_temp_anomaly_arr")))
            elev = f(row, col, "elevation_arr")
            vapor = f(row, col, "weather_vapor_arr")
            cloud_water = f(row, col, "weather_cloud_water_arr")
            precip = f(row, col, "weather_precip_arr")
            cloud = f(row, col, "weather_cloud_arr")
            conv = f(row, col, "weather_convergence_arr")
            inst = f(row, col, "weather_instability_arr")
            wind = f(row, col, "wind_speed_arr")
            wind_mag = max(0.0, min(1.0, wind / 1.2))
            ocean_an = f(row, col, "temperature_transport_anomaly_arr")
            sea_ice = f(row, col, "sea_ice_frac_arr")
            wt = i(row, col, "weather_type_arr")
            vapor_capacity = max(0.14, min(1.0, 0.18 + 0.82 * temp - 0.18 * elev))
            rh = max(0.0, vapor / max(0.001, vapor_capacity))
            open_water = max(0.0, min(1.0, 1.0 - sea_ice * 0.92))

            warm_humid_now = smoothstep(0.56, 0.76, temp) * smoothstep(0.50, 0.72, rh) * open_water
            seed_now = warm_humid_now * (0.16 + wind_mag * 0.30)
            drv_hc_now = (
                smoothstep(0.50, 0.72, rh)
                * smoothstep(0.050, 0.120, cloud_water)
                * smoothstep(0.56, 0.76, temp)
                * 0.55
            )
            drv_cv_now = max(0.0, min(1.0, (conv - 0.38) / 0.16))
            drv_in_now = max(0.0, min(1.0, (inst - 0.52) / 0.30))
            drv_an_now = max(0.0, min(1.0, ocean_an / 0.16))
            drive_now = max(drv_hc_now, drv_cv_now, drv_in_now, drv_an_now)

            warm_humid_candidate = smoothstep(0.54, 0.74, temp) * smoothstep(0.47, 0.69, rh) * open_water
            seed_candidate = warm_humid_candidate * (0.20 + wind_mag * 0.36)
            drv_hc_candidate = (
                smoothstep(0.47, 0.69, rh)
                * smoothstep(0.040, 0.105, cloud_water)
                * smoothstep(0.54, 0.74, temp)
                * 0.68
            )
            drv_cv_candidate = max(0.0, min(1.0, (conv - 0.32) / 0.18))
            drv_in_candidate = max(0.0, min(1.0, (inst - 0.48) / 0.32))
            drive_candidate = max(drv_hc_candidate, drv_cv_candidate, drv_in_candidate, drv_an_now)

            counts["samples"] += 1
            counts["wet_type"] += int(wt in PRECIP_TYPES)
            counts["precip014"] += int(precip > 0.014)
            counts["latent_now"] += int(seed_now > 0.12 and drive_now > 0.18 and precip <= 0.014)
            counts["latent_candidate"] += int(seed_candidate > 0.12 and drive_candidate > 0.18 and precip <= 0.014)
            counts["warm_humid_now"] += int(warm_humid_now > 0.20)
            counts["warm_humid_candidate"] += int(warm_humid_candidate > 0.20)
            counts["drive_now_gt020"] += int(drive_now > 0.20)
            counts["drive_candidate_gt020"] += int(drive_candidate > 0.20)
            by_tick[tick].append(1 if drive_candidate > 0.20 and seed_candidate > 0.12 else 0)

            for key, value in (
                ("temp", temp), ("rh", rh), ("cloud_water", cloud_water), ("cloud", cloud),
                ("precip", precip), ("conv", conv), ("inst", inst), ("wind", wind),
                ("seed_now", seed_now), ("drive_now", drive_now), ("drv_hc_now", drv_hc_now),
                ("seed_candidate", seed_candidate), ("drive_candidate", drive_candidate),
                ("drv_hc_candidate", drv_hc_candidate),
            ):
                vals[key].append(value)

    print(f"path={path}")
    print(f"samples={counts['samples']} commits={len(seen_commits)}")
    for key in (
        "wet_type", "precip014", "warm_humid_now", "drive_now_gt020",
        "latent_now", "warm_humid_candidate", "drive_candidate_gt020",
        "latent_candidate",
    ):
        print(f"{key}={counts[key]} frac={counts[key] / max(1, counts['samples']):.4f}")
    for key in (
        "temp", "rh", "cloud_water", "cloud", "precip", "conv", "inst", "wind",
        "seed_now", "drive_now", "drv_hc_now", "seed_candidate",
        "drive_candidate", "drv_hc_candidate",
    ):
        xs = vals[key]
        print(
            f"{key}: p50={pct(xs,0.50):.4f} p75={pct(xs,0.75):.4f} "
            f"p90={pct(xs,0.90):.4f} p95={pct(xs,0.95):.4f} p99={pct(xs,0.99):.4f}"
        )
    tick_candidates = [sum(v) for v in by_tick.values()]
    print(
        "candidate_cells_per_commit "
        f"p50={pct(tick_candidates,0.50):.1f} p90={pct(tick_candidates,0.90):.1f} "
        f"p99={pct(tick_candidates,0.99):.1f} max={max(tick_candidates) if tick_candidates else 0}"
    )


if __name__ == "__main__":
    main()
