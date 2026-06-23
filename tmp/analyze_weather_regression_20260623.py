import csv
import math
import sys
from collections import Counter, defaultdict


WET_TYPES = {1, 2, 3, 7}
SNOW_TYPES = {3}
RAIN_TYPES = {1, 2, 7}
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


def flt(row, col, name, default=0.0):
    idx = col.get(name)
    if idx is None:
        return default
    try:
        s = row[idx]
        return float(s) if s != "" else default
    except Exception:
        return default


def integer(row, col, name, default=0):
    idx = col.get(name)
    if idx is None:
        return default
    try:
        s = row[idx]
        return int(float(s)) if s != "" else default
    except Exception:
        return default


def pct(values, q, default=0.0):
    if not values:
        return default
    values = sorted(values)
    if len(values) == 1:
        return values[0]
    k = (len(values) - 1) * q
    lo = int(math.floor(k))
    hi = int(math.ceil(k))
    if lo == hi:
        return values[lo]
    return values[lo] + (values[hi] - values[lo]) * (k - lo)


class Cell:
    __slots__ = (
        "idx", "lat", "x", "y", "is_water", "terrain", "has_river",
        "total", "wet014", "wet003", "streak", "max_streak",
        "sum_precip", "sum_cloud_water", "sum_cloud", "sum_vapor",
        "sum_conv", "sum_inst", "sum_wind", "sum_temp", "sum_snow",
        "types",
    )

    def __init__(self, idx):
        self.idx = idx
        self.lat = 0.5
        self.x = 0.0
        self.y = 0.0
        self.is_water = 0
        self.terrain = 0
        self.has_river = 0
        self.total = 0
        self.wet014 = 0
        self.wet003 = 0
        self.streak = 0
        self.max_streak = 0
        self.sum_precip = 0.0
        self.sum_cloud_water = 0.0
        self.sum_cloud = 0.0
        self.sum_vapor = 0.0
        self.sum_conv = 0.0
        self.sum_inst = 0.0
        self.sum_wind = 0.0
        self.sum_temp = 0.0
        self.sum_snow = 0.0
        self.types = Counter()

    def wet_frac(self):
        return self.wet014 / self.total if self.total else 0.0

    def avg(self, field):
        return getattr(self, field) / self.total if self.total else 0.0


def lat_bin(lat_norm):
    lat_abs = abs((lat_norm - 0.5) * 2.0)
    return min(9, max(0, int(lat_abs * 10.0)))


def type_summary(counter):
    return ",".join(f"{TYPE_NAMES.get(k, k)}:{v}" for k, v in counter.most_common(4))


def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: analyze_weather_regression_20260623.py <csv>")
    path = sys.argv[1]
    required = [
        "tick_idx", "weather_last_commit_tick", "weather_commit_tick_delta",
        "weather_field_commit_path", "cell_index", "cell_pos_x_arr",
        "cell_pos_y_arr", "cell_lat_norm_arr", "terrain_arr", "is_water_arr",
        "has_river_arr", "weather_type_arr", "weather_precip_arr",
        "weather_cloud_water_arr", "weather_cloud_arr", "weather_vapor_arr",
        "weather_convergence_arr", "weather_instability_arr", "wind_speed_arr",
        "temp_arr", "weather_classification_temp_arr", "snow_cover_arr",
        "snowpack_arr", "heat_input_arr", "elevation_arr",
    ]

    cells = {}
    commit_seen = set()
    commit_deltas = []
    paths = Counter()
    rows = 0
    snapshots = 0
    current_tick = None
    current_commit = None
    process_tick = False

    tick_ocean_wet = []
    tick_ocean_wet_equator = []
    tick_ocean_jaccard = []
    tick_ocean_centroid_moves = []
    tick_ocean_centroid_y_moves = []
    wet_lat_counts = Counter()
    ocean_lat_counts = Counter()
    land_wet_lat_counts = Counter()
    land_lat_counts = Counter()
    snow_band_precip = Counter()
    cold_precip = Counter()
    snow_mismatch_examples = []
    equator_wet_sets_prev = None
    ocean_wet_prev = None
    centroid_prev = None
    y_move_signs = []

    ocean_wet_set = set()
    equator_ocean_wet_set = set()
    centroid_sum = [0.0, 0.0, 0]

    def finalize_tick():
        nonlocal ocean_wet_prev, centroid_prev, equator_wet_sets_prev
        if current_tick is None or not process_tick:
            return
        tick_ocean_wet.append(len(ocean_wet_set))
        tick_ocean_wet_equator.append(len(equator_ocean_wet_set))
        if centroid_sum[2] > 0:
            centroid = (centroid_sum[0] / centroid_sum[2], centroid_sum[1] / centroid_sum[2])
        else:
            centroid = None
        if ocean_wet_prev is not None:
            union = len(ocean_wet_prev | ocean_wet_set)
            inter = len(ocean_wet_prev & ocean_wet_set)
            tick_ocean_jaccard.append(inter / union if union else 1.0)
        if centroid_prev is not None and centroid is not None:
            dx = centroid[0] - centroid_prev[0]
            dy = centroid[1] - centroid_prev[1]
            tick_ocean_centroid_moves.append(math.sqrt(dx * dx + dy * dy))
            tick_ocean_centroid_y_moves.append(abs(dy))
            if abs(dy) > 0.15:
                y_move_signs.append(1 if dy > 0 else -1)
        ocean_wet_prev = set(ocean_wet_set)
        centroid_prev = centroid
        equator_wet_sets_prev = set(equator_ocean_wet_set)

    with open(path, "r", encoding="utf-8", newline="") as fh:
        reader = csv.reader(fh)
        header = next(reader)
        col = {name: i for i, name in enumerate(header)}
        missing = [name for name in required if name not in col]
        if missing:
            raise SystemExit(f"missing columns: {missing}")
        for row in reader:
            rows += 1
            tick = integer(row, col, "tick_idx")
            if tick != current_tick:
                finalize_tick()
                current_tick = tick
                current_commit = integer(row, col, "weather_last_commit_tick", tick)
                process_tick = current_commit not in commit_seen
                ocean_wet_set = set()
                equator_ocean_wet_set = set()
                centroid_sum = [0.0, 0.0, 0]
                if process_tick:
                    commit_seen.add(current_commit)
                    snapshots += 1
                    commit_deltas.append(integer(row, col, "weather_commit_tick_delta"))
                    paths[row[col["weather_field_commit_path"]]] += 1
            if not process_tick:
                continue

            idx = integer(row, col, "cell_index")
            st = cells.get(idx)
            if st is None:
                st = Cell(idx)
                cells[idx] = st
            st.lat = flt(row, col, "cell_lat_norm_arr", 0.5)
            st.x = flt(row, col, "cell_pos_x_arr")
            st.y = flt(row, col, "cell_pos_y_arr")
            st.is_water = integer(row, col, "is_water_arr")
            st.terrain = integer(row, col, "terrain_arr")
            st.has_river = integer(row, col, "has_river_arr")

            wt = integer(row, col, "weather_type_arr")
            precip = flt(row, col, "weather_precip_arr")
            cloud_water = flt(row, col, "weather_cloud_water_arr")
            cloud = flt(row, col, "weather_cloud_arr")
            vapor = flt(row, col, "weather_vapor_arr")
            conv = flt(row, col, "weather_convergence_arr")
            inst = flt(row, col, "weather_instability_arr")
            wind = flt(row, col, "wind_speed_arr")
            temp = flt(row, col, "temp_arr")
            cls_temp = flt(row, col, "weather_classification_temp_arr", temp)
            snow = flt(row, col, "snow_cover_arr")
            snowpack = flt(row, col, "snowpack_arr")
            b = lat_bin(st.lat)
            is_wet014 = wt in WET_TYPES and precip > 0.014
            is_wet003 = wt in WET_TYPES and precip > 0.003
            is_ocean = st.is_water == 1 and st.terrain != 18

            st.total += 1
            st.types[wt] += 1
            st.sum_precip += precip
            st.sum_cloud_water += cloud_water
            st.sum_cloud += cloud
            st.sum_vapor += vapor
            st.sum_conv += conv
            st.sum_inst += inst
            st.sum_wind += wind
            st.sum_temp += temp
            st.sum_snow += snow
            if is_wet014:
                st.wet014 += 1
                st.streak += 1
                st.max_streak = max(st.max_streak, st.streak)
            else:
                st.streak = 0
            if is_wet003:
                st.wet003 += 1

            if is_ocean:
                ocean_lat_counts[b] += 1
                if is_wet014:
                    wet_lat_counts[b] += 1
                    ocean_wet_set.add(idx)
                    centroid_sum[0] += st.x
                    centroid_sum[1] += st.y
                    centroid_sum[2] += 1
                    if b <= 1:
                        equator_ocean_wet_set.add(idx)
            elif st.is_water == 0:
                land_lat_counts[b] += 1
                if is_wet014:
                    land_wet_lat_counts[b] += 1

            meaningful_snow_zone = st.is_water == 0 and (snow >= 0.35 or snowpack >= 0.12 or cls_temp <= 0.24)
            meaningful_cold = st.is_water == 0 and cls_temp <= 0.31 and precip > 0.014
            meaningful_precip = precip > 0.014 and wt in WET_TYPES
            if meaningful_snow_zone and meaningful_precip:
                snow_band_precip[wt] += 1
                if wt in RAIN_TYPES and len(snow_mismatch_examples) < 20:
                    snow_mismatch_examples.append(
                        (idx, wt, precip, temp, cls_temp, snow, snowpack, st.lat, st.terrain)
                    )
            if meaningful_cold and meaningful_precip:
                cold_precip[wt] += 1
    finalize_tick()

    sign_flips = sum(1 for a, b in zip(y_move_signs, y_move_signs[1:]) if a != b)
    ocean_cells = [c for c in cells.values() if c.is_water == 1 and c.terrain != 18]
    locked_ocean = [c for c in ocean_cells if c.wet_frac() >= 0.90]
    equator_locked = [c for c in locked_ocean if lat_bin(c.lat) <= 1]
    top_locked = sorted(
        locked_ocean,
        key=lambda c: (c.wet_frac(), c.max_streak, c.avg("sum_precip")),
        reverse=True,
    )[:20]

    print("=== Weather regression analysis ===")
    print(f"path={path}")
    print(f"rows={rows} unique_commit_snapshots={snapshots} cells={len(cells)} paths={dict(paths)}")
    print(
        "commit_delta "
        f"p50={pct(commit_deltas,0.50):.2f} p90={pct(commit_deltas,0.90):.2f} "
        f"p99={pct(commit_deltas,0.99):.2f} max={max(commit_deltas) if commit_deltas else 0}"
    )
    print(
        "ocean wet014 count "
        f"p50={pct(tick_ocean_wet,0.50):.1f} p90={pct(tick_ocean_wet,0.90):.1f} "
        f"max={max(tick_ocean_wet) if tick_ocean_wet else 0}"
    )
    print(
        "equator ocean wet014 count "
        f"p50={pct(tick_ocean_wet_equator,0.50):.1f} p90={pct(tick_ocean_wet_equator,0.90):.1f} "
        f"max={max(tick_ocean_wet_equator) if tick_ocean_wet_equator else 0}"
    )
    print(
        "ocean wet-set persistence "
        f"jaccard_p50={pct(tick_ocean_jaccard,0.50):.3f} jaccard_p90={pct(tick_ocean_jaccard,0.90):.3f} "
        f"centroid_move_p50={pct(tick_ocean_centroid_moves,0.50):.2f} "
        f"centroid_y_abs_p50={pct(tick_ocean_centroid_y_moves,0.50):.2f} "
        f"y_sign_flips={sign_flips}/{max(len(y_move_signs)-1,0)}"
    )
    print(
        f"locked_ocean_90pct={len(locked_ocean)} equator_locked={len(equator_locked)} "
        f"ocean_cells={len(ocean_cells)}"
    )
    print()
    print("=== Ocean wet fraction by absolute latitude bin ===")
    for b in range(10):
        wet = wet_lat_counts[b]
        total = ocean_lat_counts[b]
        frac = wet / total if total else 0.0
        print(f"bin={b} wet014_frac={frac:.3f} wet_samples={wet} ocean_samples={total}")
    print()
    print("=== Land wet fraction by absolute latitude bin ===")
    for b in range(10):
        wet = land_wet_lat_counts[b]
        total = land_lat_counts[b]
        frac = wet / total if total else 0.0
        print(f"bin={b} wet014_frac={frac:.3f} wet_samples={wet} land_samples={total}")
    print()
    print("=== Snow/cold precipitation classification ===")
    print("snow_zone_precip_types=" + str({TYPE_NAMES.get(k, k): v for k, v in snow_band_precip.most_common()}))
    snow_total = sum(snow_band_precip.values())
    snow_wrong = sum(v for k, v in snow_band_precip.items() if k in RAIN_TYPES)
    print(f"snow_zone_rainlike_frac={snow_wrong / snow_total if snow_total else 0.0:.3f} total={snow_total}")
    print("cold_precip_types=" + str({TYPE_NAMES.get(k, k): v for k, v in cold_precip.most_common()}))
    cold_total = sum(cold_precip.values())
    cold_wrong = sum(v for k, v in cold_precip.items() if k in RAIN_TYPES)
    print(f"cold_rainlike_frac={cold_wrong / cold_total if cold_total else 0.0:.3f} total={cold_total}")
    print("snow_mismatch_examples=")
    for e in snow_mismatch_examples:
        idx, wt, precip, temp, cls_temp, snow, snowpack, lat, terrain = e
        print(
            f"  cell={idx} type={TYPE_NAMES.get(wt, wt)} precip={precip:.4f} temp={temp:.3f} "
            f"cls_temp={cls_temp:.3f} snow={snow:.3f} snowpack={snowpack:.3f} "
            f"lat_norm={lat:.3f} terrain={terrain}"
        )
    print()
    print("=== Top locked ocean cells ===")
    for c in top_locked:
        print(
            f"cell={c.idx} lat_norm={c.lat:.3f} bin={lat_bin(c.lat)} pos=({c.x:.1f},{c.y:.1f}) "
            f"wet014={c.wet_frac():.3f} streak={c.max_streak}/{c.total} "
            f"precip={c.avg('sum_precip'):.4f} cloud_water={c.avg('sum_cloud_water'):.4f} "
            f"cloud={c.avg('sum_cloud'):.4f} vapor={c.avg('sum_vapor'):.4f} "
            f"conv={c.avg('sum_conv'):.4f} inst={c.avg('sum_inst'):.4f} "
            f"wind={c.avg('sum_wind'):.4f} temp={c.avg('sum_temp'):.4f} "
            f"snow={c.avg('sum_snow'):.4f} types={type_summary(c.types)}"
        )


if __name__ == "__main__":
    main()
