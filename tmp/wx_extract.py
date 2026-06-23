# Stream the 3.2GB tile_data CSV once, extract weather-relevant columns into
# dense [T, C] numpy arrays (T=412 ticks, C=6400 cells), save to .npz.
# Vectorized: no per-row Python loops in the hot path.
import numpy as np, pandas as pd, time, sys

CSV = sys.argv[1] if len(sys.argv) > 1 else "tile_data_record_20260623_101851.csv"
OUT = sys.argv[2] if len(sys.argv) > 2 else "wx_arrays.npz"

SCALAR = ["tick_idx","phys_sim_day","weather_cold_front_count","weather_warm_front_count",
          "active_weather_ratio","weather_dirty_count","weather_transitioning_count",
          "weather_transition_alpha_mean","climate_precip_p95"]
STATIC = ["cell_lat_norm_arr","is_water_arr","elevation_arr","cell_pos_x_arr","cell_pos_y_arr",
          "has_river_arr","base_moisture_arr"]
F32 = ["weather_precip_arr","weather_intensity_arr","weather_vapor_arr","weather_cloud_arr",
       "weather_cloud_water_arr","weather_convergence_arr","weather_instability_arr",
       "weather_transition_alpha_arr","weather_classification_temp_arr",
       "weather_classification_moisture_arr","air_mass_temp_anomaly_arr",
       "temp_arr","moisture_arr","snow_cover_arr","snowpack_arr","sea_ice_frac_arr",
       "vegetation_vitality_arr","soil_moisture_arr",
       "wind_x_arr","wind_y_arr","wind_speed_arr","slp_arr"]
I8  = ["weather_type_arr","weather_prev_type_arr","weather_target_type_arr"]
USECOLS = ["cell_index"] + SCALAR + STATIC + F32 + I8

C = 6400
t0 = time.time()
# pre-scan tick_idx (one column) to size T exactly
_ticks_pre = pd.read_csv(CSV, usecols=["tick_idx"], encoding="utf-8-sig")["tick_idx"].to_numpy()
T = int(np.unique(_ticks_pre).size)
print(f"pre-scan: {len(_ticks_pre)} rows, T={T} ticks, C={C}", flush=True)
del _ticks_pre
tick_to_ord, ord_list = {}, []
def ord_of(t):
    o = tick_to_ord.get(t)
    if o is None:
        o = len(ord_list); tick_to_ord[t] = o; ord_list.append(t)
    return o

f32  = {k: np.full((T, C), np.nan, np.float32) for k in F32}
i8   = {k: np.full((T, C), -1,   np.int8)   for k in I8}
scal = {k: np.full(T, np.nan, np.float64) for k in SCALAR}
stat = {k: np.full(C, np.nan, np.float64) for k in STATIC}        # last-write-wins (final tick)
stat0= {k: np.full(C, np.nan, np.float64) for k in STATIC}        # first-write-wins (first tick)
scal_set = np.zeros(T, bool)
seen = np.zeros(C, bool)

reader = pd.read_csv(CSV, usecols=USECOLS, chunksize=300_000, encoding="utf-8-sig",
                     dtype="float64", low_memory=False)
nrows = 0
for cidx, chunk in enumerate(reader):
    tk = chunk["tick_idx"].to_numpy()
    cells = chunk["cell_index"].to_numpy().astype(np.int32)
    ords = np.fromiter((ord_of(int(t)) for t in tk), np.int32, len(tk))
    valid = (cells >= 0) & (cells < C) & (ords >= 0) & (ords < T)
    o, c = ords[valid], cells[valid]
    for k in F32:
        f32[k][o, c] = chunk[k].to_numpy()[valid].astype(np.float32)
    for k in I8:
        v = chunk[k].to_numpy()[valid]
        i8[k][o, c] = np.where(np.isnan(v), -1, v).astype(np.int8)
    # scalars: one value per ord (first row seen for that ord)
    uo, first_idx = np.unique(o, return_index=True)
    need = ~scal_set[uo]
    if need.any():
        sel_ord = uo[need]; sel_row = first_idx[need]
        for k in SCALAR:
            scal[k][sel_ord] = chunk[k].to_numpy()[valid][sel_row]
        scal_set[sel_ord] = True
    # static cols: first-write-wins (stat0) + last-write-wins (stat), vectorized
    newmask = ~seen[c]
    for k in STATIC:
        col = chunk[k].to_numpy()[valid]
        stat[k][c] = col                      # later chunks/rows overwrite -> final tick
        if newmask.any():
            stat0[k][c[newmask]] = col[newmask]
    seen[c] = True
    nrows += len(chunk)
    print(f"  chunk {cidx}: rows={nrows} ords={len(ord_list)} {time.time()-t0:.1f}s", flush=True)

ticks_arr = np.array(ord_list, np.int64)
print("Saving npz ...", flush=True)
save = {}
for k in F32: save["f32_"+k] = f32[k]
for k in I8:  save["i8_"+k]  = i8[k]
for k in SCALAR: save["sc_"+k] = scal[k]
for k in STATIC:
    save["st_"+k] = stat[k]; save["st0_"+k] = stat0[k]
save["ticks"] = ticks_arr
np.savez_compressed(OUT, **save)
print(f"DONE rows={nrows} T={len(ord_list)} C={C} -> {OUT}  {time.time()-t0:.1f}s")
print("tick range:", int(ticks_arr[0]), "..", int(ticks_arr[-1]))
for k in ["cell_lat_norm_arr","is_water_arr","elevation_arr"]:
    d = int(np.nansum(np.abs(stat0[k]-stat[k])>1e-6))
    print(f"  static drift {k}: {d} cells changed first->last")
