import csv
import math
import statistics
import sys
from collections import Counter, defaultdict

PATH = r"d:/Godot/ProjectKeynes/Project.Keynes/tmp/tile_data_record_20260622_133648.csv"
MAX_TICKS = int(sys.argv[1]) if len(sys.argv) > 1 else 300

WT = {"0":"CLEAR", "1":"RAIN", "2":"STORM", "3":"BLIZZARD", "4":"DROUGHT", "5":"FOG", "6":"HEATWAVE", "7":"MONSOON"}


def fnum(row, idx, name, default=0.0):
    try:
        s = row[idx[name]]
        return float(s) if s != "" else default
    except Exception:
        return default


def pct(vals, q):
    if not vals:
        return float("nan")
    vals = sorted(vals)
    k = (len(vals) - 1) * q
    lo = int(math.floor(k))
    hi = int(math.ceil(k))
    if lo == hi:
        return vals[lo]
    return vals[lo] * (hi - k) + vals[hi] * (k - lo)


def fmt(x):
    if isinstance(x, float):
        if math.isnan(x):
            return "nan"
        return f"{x:.6g}"
    return str(x)

land_wt = Counter()
water_wt = Counter()
all_wt = Counter()
land_precip = []
water_precip = []
land_cloud = []
water_cloud = []
land_cw = []
water_cw = []
land_vapor = []
water_vapor = []
land_rain_precip = []
land_rain_intensity = []
water_fog_precip = []
water_rain_precip = []
precip_bins_land = Counter()
precip_bins_water = Counter()
per_tick = {}
tick_order = []
first_tick_cells = []
current_tick = None
unique_ticks = 0
rows = 0

with open(PATH, newline="", encoding="utf-8-sig", errors="replace") as fp:
    reader = csv.reader(fp)
    header = next(reader)
    idx = {c: i for i, c in enumerate(header)}
    for row in reader:
        t = row[idx["tick_idx"]]
        if t != current_tick:
            current_tick = t
            unique_ticks += 1
            if unique_ticks > MAX_TICKS:
                break
            tick_order.append(t)
            per_tick[t] = {
                "land": Counter(), "water": Counter(),
                "water_event_n": 0, "water_event_x": 0.0, "water_event_y": 0.0,
                "water_event_w": 0.0,
                "water_rain_n": 0, "water_fog_n": 0,
                "land_rain_n": 0, "land_n": 0, "water_n": 0,
            }
        rows += 1
        is_water = int(float(row[idx["is_water_arr"]] or 0)) != 0
        wt = row[idx["weather_type_arr"]]
        all_wt[wt] += 1
        precip = fnum(row, idx, "weather_precip_arr")
        cloud = fnum(row, idx, "weather_cloud_arr")
        cw = fnum(row, idx, "weather_cloud_water_arr")
        vapor = fnum(row, idx, "weather_vapor_arr")
        inten = fnum(row, idx, "weather_intensity_arr")
        if unique_ticks == 1:
            first_tick_cells.append((int(float(row[idx["cell_index"]])), int(float(row[idx["q"]])), int(float(row[idx["r"]])), int(float(row[idx["s"]])), fnum(row, idx, "temp_arr"), fnum(row, idx, "weather_convergence_arr"), is_water, wt))
        pt = per_tick[t]
        if is_water:
            water_wt[wt] += 1
            pt["water"][wt] += 1
            pt["water_n"] += 1
            water_precip.append(precip); water_cloud.append(cloud); water_cw.append(cw); water_vapor.append(vapor)
            if wt == "1":
                water_rain_precip.append(precip); pt["water_rain_n"] += 1
            if wt == "5":
                water_fog_precip.append(precip); pt["water_fog_n"] += 1
            if precip <= 0.003: precip_bins_water["<=0.003"] += 1
            elif precip < 0.022: precip_bins_water["0.003-0.022"] += 1
            elif precip < 0.030: precip_bins_water["0.022-0.030"] += 1
            elif precip < 0.060: precip_bins_water["0.030-0.060"] += 1
            else: precip_bins_water[">=0.060"] += 1
            if wt in ("1", "2", "5", "7"):
                x = fnum(row, idx, "cell_pos_x_arr")
                y = fnum(row, idx, "cell_pos_y_arr")
                w = max(inten, precip, cloud * 0.25, 0.001)
                pt["water_event_n"] += 1
                pt["water_event_x"] += x * w
                pt["water_event_y"] += y * w
                pt["water_event_w"] += w
        else:
            land_wt[wt] += 1
            pt["land"][wt] += 1
            pt["land_n"] += 1
            land_precip.append(precip); land_cloud.append(cloud); land_cw.append(cw); land_vapor.append(vapor)
            if wt == "1":
                land_rain_precip.append(precip); land_rain_intensity.append(inten); pt["land_rain_n"] += 1
            if precip <= 0.003: precip_bins_land["<=0.003"] += 1
            elif precip < 0.022: precip_bins_land["0.003-0.022"] += 1
            elif precip < 0.030: precip_bins_land["0.022-0.030"] += 1
            elif precip < 0.060: precip_bins_land["0.030-0.060"] += 1
            else: precip_bins_land[">=0.060"] += 1

# First-tick front proxy: neighbor temp gradient + convergence thresholds.
coord_to_cell = {(q, r, s): (temp, conv, is_water, wt) for _, q, r, s, temp, conv, is_water, wt in first_tick_cells}
dirs = [(1,-1,0),(1,0,-1),(0,1,-1),(-1,1,0),(-1,0,1),(0,-1,1)]
grad = []
front_proxy = []
for _, q, r, s, temp, conv, is_water, wt in first_tick_cells:
    vals = [temp]
    for dq, dr, ds in dirs:
        nb = coord_to_cell.get((q+dq, r+dr, s+ds))
        if nb:
            vals.append(nb[0])
    g = max(vals) - min(vals)
    grad.append(g)
    # Approx same gates as code: convergence smoothstep .14-.46 and gradient .04-.16.
    def smooth(edge0, edge1, x):
        tt = max(0.0, min(1.0, (x-edge0)/(edge1-edge0)))
        return tt*tt*(3-2*tt)
    front_proxy.append(smooth(0.14, 0.46, conv) * smooth(0.04, 0.16, g) * 0.42)

centers = []
for t in tick_order:
    pt = per_tick[t]
    if pt["water_event_w"] > 0:
        centers.append((pt["water_event_x"] / pt["water_event_w"], pt["water_event_y"] / pt["water_event_w"], pt["water_event_n"], pt["water_rain_n"], pt["water_fog_n"], pt["land_rain_n"]))
xs = [c[0] for c in centers]
ys = [c[1] for c in centers]

print("sample_ticks", len(tick_order), "rows", rows, "cells_per_tick", (rows // max(1, len(tick_order))))
print("land_wt", {WT.get(k,k): v for k,v in land_wt.items()})
print("water_wt", {WT.get(k,k): v for k,v in water_wt.items()})
print("all_wt", {WT.get(k,k): v for k,v in all_wt.items()})
print("land_precip_bins", dict(precip_bins_land))
print("water_precip_bins", dict(precip_bins_water))
for name, vals in [("land_precip", land_precip), ("water_precip", water_precip), ("land_cloud", land_cloud), ("water_cloud", water_cloud), ("land_cloud_water", land_cw), ("water_cloud_water", water_cw), ("land_vapor", land_vapor), ("water_vapor", water_vapor), ("land_RAIN_precip", land_rain_precip), ("land_RAIN_intensity", land_rain_intensity), ("water_FOG_precip", water_fog_precip), ("water_RAIN_precip", water_rain_precip), ("first_tick_temp_gradient", grad), ("first_tick_front_proxy", front_proxy)]:
    print(name, "n", len(vals), "mean", fmt(sum(vals)/len(vals) if vals else float("nan")), "p50", fmt(pct(vals,0.5)), "p75", fmt(pct(vals,0.75)), "p90", fmt(pct(vals,0.9)), "p95", fmt(pct(vals,0.95)), "p99", fmt(pct(vals,0.99)), "max", fmt(max(vals) if vals else float("nan")))
if centers:
    print("water_event_center_ticks", len(centers), "x_std", fmt(statistics.pstdev(xs)), "y_std", fmt(statistics.pstdev(ys)), "x_range", fmt(max(xs)-min(xs)), "y_range", fmt(max(ys)-min(ys)))
    print("water_event_counts_first_mid_last", centers[0][2:], centers[len(centers)//2][2:], centers[-1][2:])
print("per_tick_land_rain_ratio_first_mid_last", [fmt(per_tick[t]["land_rain_n"] / max(1, per_tick[t]["land_n"])) for t in (tick_order[0], tick_order[len(tick_order)//2], tick_order[-1])])
print("per_tick_water_fog_ratio_first_mid_last", [fmt(per_tick[t]["water_fog_n"] / max(1, per_tick[t]["water_n"])) for t in (tick_order[0], tick_order[len(tick_order)//2], tick_order[-1])])
