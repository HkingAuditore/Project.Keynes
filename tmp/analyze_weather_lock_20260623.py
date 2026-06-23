import csv
import math
import statistics
import sys
from collections import Counter, defaultdict


CSV_PATH = r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260623_005616.csv"
WET_TYPES = {1, 2, 3, 7}
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


def f(row, idx, default=0.0):
    try:
        s = row[idx]
        if s == "":
            return default
        return float(s)
    except Exception:
        return default


def i(row, idx, default=0):
    try:
        s = row[idx]
        if s == "":
            return default
        return int(float(s))
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


class CellStats:
    __slots__ = (
        "cell", "q", "r", "s", "x", "y", "terrain", "landform", "is_water",
        "has_river", "wet", "wet014", "total", "streak", "max_streak",
        "sum_precip", "sum_cloud_water", "sum_cloud", "sum_vapor",
        "sum_conv", "sum_inst", "sum_wind", "sum_temp", "sum_ocean_an",
        "sum_sea_ice", "sum_type", "types", "target_types", "prev_types",
        "first_wet_commit", "last_wet_commit",
    )

    def __init__(self, cell):
        self.cell = cell
        self.q = self.r = self.s = 0
        self.x = self.y = 0.0
        self.terrain = self.landform = self.is_water = self.has_river = 0
        self.wet = self.wet014 = self.total = self.streak = self.max_streak = 0
        self.sum_precip = self.sum_cloud_water = self.sum_cloud = 0.0
        self.sum_vapor = self.sum_conv = self.sum_inst = self.sum_wind = 0.0
        self.sum_temp = self.sum_ocean_an = self.sum_sea_ice = 0.0
        self.sum_type = 0
        self.types = Counter()
        self.target_types = Counter()
        self.prev_types = Counter()
        self.first_wet_commit = None
        self.last_wet_commit = None

    def update_static(self, row, col):
        self.q = i(row, col["q"])
        self.r = i(row, col["r"])
        self.s = i(row, col["s"])
        self.x = f(row, col["cell_pos_x_arr"])
        self.y = f(row, col["cell_pos_y_arr"])
        self.terrain = i(row, col["terrain_arr"])
        self.landform = i(row, col["landform_arr"])
        self.is_water = i(row, col["is_water_arr"])
        self.has_river = i(row, col["has_river_arr"])

    def update_weather(self, row, col, commit_tick, wet, wet014):
        wt = i(row, col["weather_type_arr"])
        target = i(row, col["weather_target_type_arr"])
        prev = i(row, col["weather_prev_type_arr"])
        precip = f(row, col["weather_precip_arr"])
        cloud_water = f(row, col["weather_cloud_water_arr"])
        cloud = f(row, col["weather_cloud_arr"])
        vapor = f(row, col["weather_vapor_arr"])
        conv = f(row, col["weather_convergence_arr"])
        inst = f(row, col["weather_instability_arr"])
        wind = f(row, col["wind_speed_arr"])
        temp = f(row, col["temp_arr"])
        ocean_an = f(row, col["temperature_transport_anomaly_arr"])
        sea_ice = f(row, col["sea_ice_frac_arr"])
        self.total += 1
        self.types[wt] += 1
        self.target_types[target] += 1
        self.prev_types[prev] += 1
        self.sum_precip += precip
        self.sum_cloud_water += cloud_water
        self.sum_cloud += cloud
        self.sum_vapor += vapor
        self.sum_conv += conv
        self.sum_inst += inst
        self.sum_wind += wind
        self.sum_temp += temp
        self.sum_ocean_an += ocean_an
        self.sum_sea_ice += sea_ice
        if wet:
            self.wet += 1
            self.streak += 1
            self.max_streak = max(self.max_streak, self.streak)
            if self.first_wet_commit is None:
                self.first_wet_commit = commit_tick
            self.last_wet_commit = commit_tick
        else:
            self.streak = 0
        if wet014:
            self.wet014 += 1

    def frac(self):
        return self.wet / self.total if self.total else 0.0

    def frac014(self):
        return self.wet014 / self.total if self.total else 0.0

    def avg(self, attr):
        return getattr(self, attr) / self.total if self.total else 0.0

    def type_summary(self, counter):
        return ",".join(
            f"{TYPE_NAMES.get(k, str(k))}:{v}" for k, v in counter.most_common(4)
        )


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else CSV_PATH
    required = [
        "tick_idx", "weather_last_commit_tick", "weather_commit_tick_delta",
        "cell_index", "q", "r", "s", "cell_pos_x_arr", "cell_pos_y_arr",
        "terrain_arr", "landform_arr", "is_water_arr", "has_river_arr",
        "weather_type_arr", "weather_prev_type_arr", "weather_target_type_arr",
        "weather_precip_arr", "weather_cloud_water_arr", "weather_cloud_arr",
        "weather_vapor_arr", "weather_convergence_arr",
        "weather_instability_arr", "wind_speed_arr", "temp_arr",
        "temperature_transport_anomaly_arr", "sea_ice_frac_arr",
        "weather_target_mismatch_count", "weather_transitioning_count",
        "weather_field_commit_path",
    ]
    cells = {}
    seen_commit_ticks = set()
    tick_commit_deltas = []
    commit_deltas = []
    commit_paths = Counter()
    mismatch_samples = []
    transitioning_samples = []
    terrain_counts = Counter()
    wet_jaccards = []
    wet_centroid_moves = []
    wet_counts = []
    water_counts = []
    river_wet_counts = []
    prev_wet_set = None
    prev_centroid = None
    current_tick = None
    current_commit_tick = None
    process_current_tick = False
    current_wet_set = set()
    current_centroid_sum = [0.0, 0.0, 0]
    current_water_count = 0
    current_river_wet_count = 0
    snapshots = 0
    duplicate_snapshots = 0
    rows = 0

    def finalize_tick():
        nonlocal prev_wet_set, prev_centroid, current_wet_set, current_centroid_sum
        nonlocal snapshots
        if current_tick is None or not process_current_tick:
            return
        snapshots += 1
        wet_counts.append(len(current_wet_set))
        water_counts.append(current_water_count)
        river_wet_counts.append(current_river_wet_count)
        if current_centroid_sum[2] > 0:
            centroid = (
                current_centroid_sum[0] / current_centroid_sum[2],
                current_centroid_sum[1] / current_centroid_sum[2],
            )
        else:
            centroid = None
        if prev_wet_set is not None:
            union = len(prev_wet_set | current_wet_set)
            inter = len(prev_wet_set & current_wet_set)
            wet_jaccards.append(inter / union if union else 1.0)
        if prev_centroid is not None and centroid is not None:
            dx = centroid[0] - prev_centroid[0]
            dy = centroid[1] - prev_centroid[1]
            wet_centroid_moves.append(math.sqrt(dx * dx + dy * dy))
        prev_wet_set = current_wet_set
        prev_centroid = centroid

    with open(path, "r", encoding="utf-8", newline="") as fh:
        reader = csv.reader(fh)
        header = next(reader)
        col = {name: idx for idx, name in enumerate(header)}
        missing = [name for name in required if name not in col]
        if missing:
            raise SystemExit(f"missing columns: {missing}")
        for row in reader:
            rows += 1
            tick = i(row, col["tick_idx"])
            if tick != current_tick:
                finalize_tick()
                current_tick = tick
                current_commit_tick = i(row, col["weather_last_commit_tick"], tick)
                tick_commit_deltas.append(i(row, col["weather_commit_tick_delta"]))
                commit_paths[row[col["weather_field_commit_path"]]] += 1
                mismatch_samples.append(i(row, col["weather_target_mismatch_count"]))
                transitioning_samples.append(i(row, col["weather_transitioning_count"]))
                process_current_tick = current_commit_tick not in seen_commit_ticks
                if process_current_tick:
                    seen_commit_ticks.add(current_commit_tick)
                    commit_deltas.append(i(row, col["weather_commit_tick_delta"]))
                else:
                    duplicate_snapshots += 1
                current_wet_set = set()
                current_centroid_sum = [0.0, 0.0, 0]
                current_water_count = 0
                current_river_wet_count = 0
            if not process_current_tick:
                continue
            cell = i(row, col["cell_index"])
            st = cells.get(cell)
            if st is None:
                st = CellStats(cell)
                cells[cell] = st
            st.update_static(row, col)
            terrain_counts[st.terrain] += 1
            wt = i(row, col["weather_type_arr"])
            precip = f(row, col["weather_precip_arr"])
            wet = wt in WET_TYPES and precip > 0.003
            wet014 = wt in WET_TYPES and precip > 0.014
            is_water = st.is_water == 1
            has_river = st.has_river == 1
            if is_water:
                current_water_count += 1
            if wet014 and is_water:
                current_wet_set.add(cell)
                current_centroid_sum[0] += st.x
                current_centroid_sum[1] += st.y
                current_centroid_sum[2] += 1
            if wet and has_river:
                current_river_wet_count += 1
            st.update_weather(row, col, current_commit_tick, wet, wet014)
    finalize_tick()

    total_commits = snapshots
    water_cells = [s for s in cells.values() if s.is_water == 1]
    ocean_cells = [s for s in water_cells if s.terrain != 18]
    lake_cells = [s for s in water_cells if s.terrain == 18]
    river_cells = [s for s in cells.values() if s.has_river == 1 and s.is_water == 0]
    locked_water = [s for s in water_cells if s.frac014() >= 0.90]
    locked_ocean = [s for s in ocean_cells if s.frac014() >= 0.90]
    locked_river = [s for s in river_cells if s.frac() >= 0.90]
    top_ocean = sorted(ocean_cells, key=lambda s: (s.frac014(), s.max_streak, s.avg("sum_precip")), reverse=True)[:20]
    top_river = sorted(river_cells, key=lambda s: (s.frac(), s.max_streak, s.avg("sum_precip")), reverse=True)[:20]

    print("=== Weather lock analysis ===")
    print(f"path={path}")
    print(f"rows={rows} unique_commit_snapshots={total_commits} duplicate_tick_snapshots={duplicate_snapshots} cells={len(cells)}")
    print(f"commit_delta p50={percentile(commit_deltas,0.50):.2f} p90={percentile(commit_deltas,0.90):.2f} p99={percentile(commit_deltas,0.99):.2f} max={max(commit_deltas) if commit_deltas else 0}")
    print(f"tick_delta p50={percentile(tick_commit_deltas,0.50):.2f} p90={percentile(tick_commit_deltas,0.90):.2f} p99={percentile(tick_commit_deltas,0.99):.2f} max={max(tick_commit_deltas) if tick_commit_deltas else 0}")
    print(f"commit_paths={dict(commit_paths.most_common())}")
    print(f"target_mismatch p50={percentile(mismatch_samples,0.50):.1f} p90={percentile(mismatch_samples,0.90):.1f} max={max(mismatch_samples) if mismatch_samples else 0}")
    print(f"transitioning p50={percentile(transitioning_samples,0.50):.1f} p90={percentile(transitioning_samples,0.90):.1f} max={max(transitioning_samples) if transitioning_samples else 0}")
    print(f"water_cells={len(water_cells)} ocean_cells={len(ocean_cells)} lake_cells={len(lake_cells)} river_land_cells={len(river_cells)}")
    print(f"terrain_counts={dict(terrain_counts.most_common(12))}")
    print(f"wet_ocean_count p50={percentile(wet_counts,0.50):.1f} p90={percentile(wet_counts,0.90):.1f} max={max(wet_counts) if wet_counts else 0}")
    print(f"wet_ocean_jaccard p50={percentile(wet_jaccards,0.50):.3f} p90={percentile(wet_jaccards,0.90):.3f} max={max(wet_jaccards) if wet_jaccards else 0:.3f}")
    print(f"wet_ocean_centroid_move p50={percentile(wet_centroid_moves,0.50):.2f} p90={percentile(wet_centroid_moves,0.90):.2f} max={max(wet_centroid_moves) if wet_centroid_moves else 0:.2f}")
    print(f"locked_water_90pct_precip014={len(locked_water)} locked_ocean_90pct_precip014={len(locked_ocean)} locked_river_90pct_precip003={len(locked_river)}")
    if total_commits:
        print(f"river_wet_count p50={percentile(river_wet_counts,0.50):.1f} p90={percentile(river_wet_counts,0.90):.1f} max={max(river_wet_counts) if river_wet_counts else 0}")
    print()
    print("=== Top ocean/water locked candidates ===")
    for s in top_ocean:
        print(
            f"cell={s.cell} qrs=({s.q},{s.r},{s.s}) pos=({s.x:.1f},{s.y:.1f}) terr={s.terrain} landform={s.landform} "
            f"wet014={s.frac014():.3f} wet003={s.frac():.3f} max_streak={s.max_streak}/{s.total} "
            f"precip={s.avg('sum_precip'):.4f} cloud_water={s.avg('sum_cloud_water'):.4f} cloud={s.avg('sum_cloud'):.4f} "
            f"vapor={s.avg('sum_vapor'):.4f} conv={s.avg('sum_conv'):.4f} inst={s.avg('sum_inst'):.4f} "
            f"wind={s.avg('sum_wind'):.4f} temp={s.avg('sum_temp'):.4f} ocean_an={s.avg('sum_ocean_an'):.4f} sea_ice={s.avg('sum_sea_ice'):.4f} "
            f"types={s.type_summary(s.types)} target={s.type_summary(s.target_types)}"
        )
    print()
    print("=== Top river locked candidates ===")
    for s in top_river:
        print(
            f"cell={s.cell} qrs=({s.q},{s.r},{s.s}) pos=({s.x:.1f},{s.y:.1f}) terr={s.terrain} landform={s.landform} "
            f"wet003={s.frac():.3f} wet014={s.frac014():.3f} max_streak={s.max_streak}/{s.total} "
            f"precip={s.avg('sum_precip'):.4f} cloud_water={s.avg('sum_cloud_water'):.4f} cloud={s.avg('sum_cloud'):.4f} "
            f"vapor={s.avg('sum_vapor'):.4f} conv={s.avg('sum_conv'):.4f} inst={s.avg('sum_inst'):.4f} "
            f"wind={s.avg('sum_wind'):.4f} temp={s.avg('sum_temp'):.4f} ocean_an={s.avg('sum_ocean_an'):.4f} "
            f"types={s.type_summary(s.types)} target={s.type_summary(s.target_types)}"
        )


if __name__ == "__main__":
    main()
