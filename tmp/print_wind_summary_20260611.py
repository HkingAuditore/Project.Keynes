from __future__ import annotations

import json
from pathlib import Path
from pprint import pp


P = Path(r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\analysis_output\wind_field_analysis_20260611_145934.json")
d = json.loads(P.read_text(encoding="utf-8"))

snap = d["selected_snapshots"]["252"]
print("TICK 252 SUMMARY")
print({k: snap["tick_summary"][k] for k in [
    "wind_x_mean", "wind_y_mean", "wind_direction_mean_deg", "wind_vector_coherence",
    "wind_speed_mean", "wind_speed_std", "slp_std", "temp_mean", "moisture_mean", "precip_mean",
]})

print("\nLAT SLICES")
for r in snap["lat_slices"]:
    print(
        r["lat_bin"], "n", r["count"],
        "dir", round(r["mean_direction_deg"], 2),
        "coh", round(r["vector_coherence"], 3),
        "wspd", round(r["wind_speed_mean"], 3),
        "slp", round(r["slp_mean"], 3),
        "temp", round(r["temp_mean"], 3),
        "moist", round(r["moisture_mean"], 3),
        "precip", round(r["precip_mean"], 3),
    )

print("\nWATER SLICES")
for r in snap["water_slices"]:
    print(r)

print("\nELEVATION SLICES")
for r in snap["elevation_slices"]:
    print(
        r["elevation_quantile"], "n", r["count"],
        "dir", round(r["mean_direction_deg"], 2),
        "coh", round(r["vector_coherence"], 3),
        "wspd", round(r["wind_speed_mean"], 3),
        "slp", round(r["slp_mean"], 3),
        "temp", round(r["temp_mean"], 3),
        "moist", round(r["moisture_mean"], 3),
        "precip", round(r["precip_mean"], 3),
    )

print("\nTERRAIN SLICES")
for r in snap["terrain_slices"]:
    print(
        r["terrain_arr"], "n", r["count"],
        "dir", round(r["mean_direction_deg"], 2),
        "coh", round(r["vector_coherence"], 3),
        "wspd", round(r["wind_speed_mean"], 3),
        "slp", round(r["slp_mean"], 3),
        "temp", round(r["temp_mean"], 3),
        "moist", round(r["moisture_mean"], 3),
        "precip", round(r["precip_mean"], 3),
    )

print("\nRAW CORRELATIONS ALL ROWS")
pp(d["raw_correlations_all_rows"])

print("\nRESIDUAL CORRELATIONS TICK 252")
pp(snap["residual_corr_after_lat_elev_water"])

print("\nGRADIENT TICK 252")
pp(snap["gradient_alignment"])
