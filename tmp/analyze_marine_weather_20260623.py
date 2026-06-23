import csv
import math
import sys
from collections import Counter, defaultdict


TYPE_NAMES = {
    0: "CLEAR",
    1: "RAIN",
    2: "STORM",
    3: "BLIZZARD",
    4: "DROUGHT",
    5: "FOG",
    6: "HEATWAVE",
    7: "MONSOON",
}
PRECIP_TYPES = {1, 2, 3, 7}
NEIGHBORS = ((1, 0), (1, -1), (0, -1), (-1, 0), (-1, 1), (0, 1))


def f(row, idx, default=0.0):
    try:
        s = row[idx]
        return float(s) if s != "" else default
    except Exception:
        return default


def i(row, idx, default=0):
    try:
        s = row[idx]
        return int(float(s)) if s != "" else default
    except Exception:
        return default


def percentile(values, p, default=0.0):
    if not values:
        return default
    values = sorted(values)
    if len(values) == 1:
        return values[0]
    k = (len(values) - 1) * p
    lo = int(math.floor(k))
    hi = int(math.ceil(k))
    if lo == hi:
        return values[lo]
    return values[lo] + (values[hi] - values[lo]) * (k - lo)


class Stat:
    __slots__ = ("n", "vals")

    def __init__(self):
        self.n = 0
        self.vals = defaultdict(list)

    def add(self, **kwargs):
        self.n += 1
        for key, value in kwargs.items():
            self.vals[key].append(value)

    def line(self, key):
        vals = self.vals.get(key, [])
        return (
            f"{key}: p50={percentile(vals, 0.50):.4f} "
            f"p75={percentile(vals, 0.75):.4f} "
            f"p90={percentile(vals, 0.90):.4f} "
            f"p95={percentile(vals, 0.95):.4f} "
            f"p99={percentile(vals, 0.99):.4f}"
        )


def build_static(path, col):
    cells = {}
    by_qr = {}
    first_tick = None
    with open(path, "r", encoding="utf-8", newline="") as fh:
        reader = csv.reader(fh)
        next(reader)
        for row in reader:
            tick = i(row, col["tick_idx"])
            if first_tick is None:
                first_tick = tick
            elif tick != first_tick:
                break
            cell = i(row, col["cell_index"])
            q = i(row, col["q"])
            r = i(row, col["r"])
            water = i(row, col["is_water_arr"]) != 0
            cells[cell] = (q, r, water)
            by_qr[(q, r)] = (cell, water)
    coast_water = set()
    for cell, (q, r, water) in cells.items():
        if not water:
            continue
        near_land = False
        for dq, dr in NEIGHBORS:
            nb = by_qr.get((q + dq, r + dr))
            if nb is not None and not nb[1]:
                near_land = True
                break
        if near_land:
            coast_water.add(cell)
    return cells, coast_water


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260623_021536.csv"
    with open(path, "r", encoding="utf-8", newline="") as fh:
        reader = csv.reader(fh)
        header = next(reader)
    col = {name: idx for idx, name in enumerate(header)}
    required = [
        "tick_idx",
        "weather_last_commit_tick",
        "weather_commit_tick_delta",
        "cell_index",
        "q",
        "r",
        "temp_arr",
        "elevation_arr",
        "is_water_arr",
        "weather_type_arr",
        "weather_precip_arr",
        "weather_cloud_water_arr",
        "weather_cloud_arr",
        "weather_vapor_arr",
        "weather_convergence_arr",
        "weather_instability_arr",
        "wind_speed_arr",
        "temperature_transport_anomaly_arr",
        "sea_ice_frac_arr",
    ]
    missing = [name for name in required if name not in col]
    if missing:
        raise SystemExit(f"missing columns: {missing}")

    static_cells, coast_water = build_static(path, col)
    seen_commit_ticks = set()
    current_tick = None
    current_commit_tick = None
    process_tick = False
    commit_count = 0
    tick_count = 0
    commit_deltas = []
    groups = {name: Stat() for name in ("land", "all_water", "coast_water", "open_water")}
    type_counts = {name: Counter() for name in groups}
    thresholds = {name: Counter() for name in groups}
    per_commit = defaultdict(list)

    with open(path, "r", encoding="utf-8", newline="") as fh:
        reader = csv.reader(fh)
        next(reader)
        water_precip014 = 0
        water_precip003 = 0
        water_wet_type = 0
        coast_precip014 = 0
        open_precip014 = 0
        for row in reader:
            tick = i(row, col["tick_idx"])
            if tick != current_tick:
                if current_tick is not None and process_tick:
                    per_commit["water_precip014_count"].append(water_precip014)
                    per_commit["water_precip003_count"].append(water_precip003)
                    per_commit["water_wet_type_count"].append(water_wet_type)
                    per_commit["coast_precip014_count"].append(coast_precip014)
                    per_commit["open_precip014_count"].append(open_precip014)
                current_tick = tick
                tick_count += 1
                current_commit_tick = i(row, col["weather_last_commit_tick"], tick)
                process_tick = current_commit_tick not in seen_commit_ticks
                water_precip014 = water_precip003 = water_wet_type = 0
                coast_precip014 = open_precip014 = 0
                if process_tick:
                    seen_commit_ticks.add(current_commit_tick)
                    commit_count += 1
                    commit_deltas.append(i(row, col["weather_commit_tick_delta"]))
            if not process_tick:
                continue
            cell = i(row, col["cell_index"])
            water = i(row, col["is_water_arr"]) != 0
            wt = i(row, col["weather_type_arr"])
            precip = f(row, col["weather_precip_arr"])
            cloud_water = f(row, col["weather_cloud_water_arr"])
            cloud = f(row, col["weather_cloud_arr"])
            vapor = f(row, col["weather_vapor_arr"])
            conv = f(row, col["weather_convergence_arr"])
            inst = f(row, col["weather_instability_arr"])
            temp = f(row, col["temp_arr"])
            elev = f(row, col["elevation_arr"])
            wind = f(row, col["wind_speed_arr"])
            ocean_an = f(row, col["temperature_transport_anomaly_arr"])
            sea_ice = f(row, col["sea_ice_frac_arr"])
            vapor_capacity = max(0.14, min(1.0, 0.18 + 0.82 * temp - 0.18 * elev))
            rh = max(0.0, vapor / max(0.001, vapor_capacity))
            drv_an = max(0.0, min(1.0, ocean_an / 0.16))
            drv_in = max(0.0, min(1.0, (inst - 0.52) / 0.30))
            drv_cv = max(0.0, min(1.0, (conv - 0.38) / 0.16))
            drv_hc = (
                max(0.0, min(1.0, (rh - 0.44) / (0.68 - 0.44))) ** 2
                * max(0.0, min(1.0, (cloud_water - 0.035) / (0.090 - 0.035))) ** 2
                * max(0.0, min(1.0, (temp - 0.52) / (0.74 - 0.52))) ** 2
                * 0.55
            )
            ocean_drive_proxy = max(drv_an, drv_in, drv_cv, drv_hc)
            names = ["all_water"] if water else ["land"]
            if water:
                if cell in coast_water:
                    names.append("coast_water")
                else:
                    names.append("open_water")
            for name in names:
                groups[name].add(
                    precip=precip,
                    cloud_water=cloud_water,
                    cloud=cloud,
                    vapor=vapor,
                    rh=rh,
                    conv=conv,
                    inst=inst,
                    temp=temp,
                    wind=wind,
                    ocean_an=ocean_an,
                    ocean_drive_proxy=ocean_drive_proxy,
                    sea_ice=sea_ice,
                )
                type_counts[name][wt] += 1
                thresholds[name]["precip_gt_003"] += int(precip > 0.003)
                thresholds[name]["precip_gt_014"] += int(precip > 0.014)
                thresholds[name]["cloud_water_gt_008"] += int(cloud_water > 0.08)
                thresholds[name]["cloud_water_gt_012"] += int(cloud_water > 0.12)
                thresholds[name]["vapor_gt_028"] += int(vapor > 0.28)
                thresholds[name]["rh_gt_046"] += int(rh > 0.46)
                thresholds[name]["ocean_drive_proxy_gt_020"] += int(ocean_drive_proxy > 0.20)
                thresholds[name]["wet_type"] += int(wt in PRECIP_TYPES)
                thresholds[name]["latent_marine"] += int(water and cloud_water > 0.08 and vapor > 0.28 and precip <= 0.014)
            if water:
                if precip > 0.014:
                    water_precip014 += 1
                    if cell in coast_water:
                        coast_precip014 += 1
                    else:
                        open_precip014 += 1
                if precip > 0.003:
                    water_precip003 += 1
                if wt in PRECIP_TYPES:
                    water_wet_type += 1
        if current_tick is not None and process_tick:
            per_commit["water_precip014_count"].append(water_precip014)
            per_commit["water_precip003_count"].append(water_precip003)
            per_commit["water_wet_type_count"].append(water_wet_type)
            per_commit["coast_precip014_count"].append(coast_precip014)
            per_commit["open_precip014_count"].append(open_precip014)

    print("=== Marine weather distribution ===")
    print(f"path={path}")
    print(f"ticks={tick_count} unique_commit_snapshots={commit_count}")
    print(
        "commit_delta "
        f"p50={percentile(commit_deltas, 0.50):.2f} "
        f"p90={percentile(commit_deltas, 0.90):.2f} "
        f"max={max(commit_deltas) if commit_deltas else 0}"
    )
    water_cells = sum(1 for _, _, water in static_cells.values() if water)
    print(
        f"static cells={len(static_cells)} water={water_cells} "
        f"coast_water={len(coast_water)} open_water={water_cells - len(coast_water)}"
    )
    for key in (
        "water_precip003_count",
        "water_precip014_count",
        "water_wet_type_count",
        "coast_precip014_count",
        "open_precip014_count",
    ):
        vals = per_commit[key]
        print(
            f"{key}: p50={percentile(vals, 0.50):.1f} "
            f"p90={percentile(vals, 0.90):.1f} "
            f"p99={percentile(vals, 0.99):.1f} max={max(vals) if vals else 0}"
        )
    for name, stat in groups.items():
        print(f"\n[{name}] samples={stat.n}")
        for key in ("precip", "cloud_water", "cloud", "vapor", "rh", "conv", "inst", "temp", "wind", "ocean_an", "ocean_drive_proxy"):
            print("  " + stat.line(key))
        print("  types=" + ", ".join(f"{TYPE_NAMES.get(k, k)}:{v / max(1, stat.n):.3f}" for k, v in type_counts[name].most_common()))
        print("  fractions=" + ", ".join(f"{k}:{v / max(1, stat.n):.3f}" for k, v in thresholds[name].items()))


if __name__ == "__main__":
    main()
