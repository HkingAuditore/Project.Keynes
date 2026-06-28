import csv, sys, math
from collections import defaultdict, Counter

PATH = r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260628_012555.csv"

NEED = [
    "tick_idx","cell_index","is_water_arr","elevation_arr",
    "temp_arr","temp_anomaly_arr","moisture_arr",
    "weather_intensity_arr","weather_cloud_arr","weather_cloud_water_arr",
    "weather_precip_arr","weather_vapor_arr","weather_convergence_arr",
    "weather_instability_arr","weather_classification_temp_arr",
    "weather_classification_moisture_arr",
    "wind_x_arr","wind_y_arr","wind_speed_arr",
    "ocean_thermal_anomaly_arr","temperature_transport_anomaly_arr",
    "weather_type_arr","weather_prev_type_arr","weather_target_type_arr",
]

def f(x):
    try: return float(x)
    except: return 0.0
def i(x):
    try: return int(float(x))
    except: return 0

with open(PATH, "r", newline="") as fh:
    rdr = csv.reader(fh)
    header = next(rdr)
    idx = {name: k for k, name in enumerate(header)}
    col = {n: idx[n] for n in NEED if n in idx}
    missing = [n for n in NEED if n not in idx]
    if missing:
        print("MISSING COLS:", missing)

    type_hist = Counter()
    target_hist = Counter()
    cell_types = defaultdict(set)         # cell -> set of weather_type seen
    cell_type_changes = defaultdict(int)  # cell -> count of type changes over time
    cell_last_type = {}
    ticks = set()
    ncells = set()

    # field temporal variation: per-cell mean & sumsq for a few fields to get temporal std
    fields = ["weather_cloud_arr","weather_precip_arr","weather_vapor_arr",
              "weather_intensity_arr","weather_convergence_arr","wind_speed_arr",
              "temp_arr","moisture_arr","temp_anomaly_arr"]
    cell_sum = {fld: defaultdict(float) for fld in fields}
    cell_sumsq = {fld: defaultdict(float) for fld in fields}
    cell_cnt = defaultdict(int)

    # global accumulators for correlation (precip vs moisture/temp/conv, etc.)
    n_obs = 0
    sums = defaultdict(float)
    sumsqs = defaultdict(float)
    cross = defaultdict(float)

    def acc_corr(a, av, b, bv):
        sums[a]+=av; sumsqs[a]+=av*av
        sums[b]+=bv; sumsqs[b]+=bv*bv
        cross[(a,b)]+=av*bv

    wind_zero = 0
    wind_total = 0
    row_count = 0
    for row in rdr:
        row_count += 1
        if len(row) <= max(col.values()):
            continue
        t = i(row[col["tick_idx"]])
        c = i(row[col["cell_index"]])
        ticks.add(t); ncells.add(c)
        wt = i(row[col["weather_type_arr"]])
        tgt = i(row[col["weather_target_type_arr"]])
        type_hist[wt]+=1
        target_hist[tgt]+=1
        cell_types[c].add(wt)
        if c in cell_last_type and cell_last_type[c]!=wt:
            cell_type_changes[c]+=1
        cell_last_type[c]=wt

        vals = {fld: f(row[col[fld]]) for fld in fields}
        for fld in fields:
            v=vals[fld]
            cell_sum[fld][c]+=v
            cell_sumsq[fld][c]+=v*v
        cell_cnt[c]+=1

        ws = vals["wind_speed_arr"]
        wind_total+=1
        if abs(ws)<1e-6: wind_zero+=1

        # correlations (global, all cells/ticks)
        moi=vals["moisture_arr"]; tmp=vals["temp_arr"]; pr=vals["weather_precip_arr"]
        cl=vals["weather_cloud_arr"]; vap=vals["weather_vapor_arr"]; conv=vals["weather_convergence_arr"]
        ta=vals["temp_anomaly_arr"]
        acc_corr("precip",pr,"moisture",moi)
        acc_corr("precip",pr,"temp",tmp)
        acc_corr("precip",pr,"conv",conv)
        acc_corr("precip",pr,"vapor",vap)
        acc_corr("cloud",cl,"vapor",vap)
        acc_corr("cloud",cl,"moisture",moi)
        acc_corr("type",float(wt),"temp",tmp)
        acc_corr("type",float(wt),"moisture",moi)
        n_obs+=1

print("="*70)
print("rows=%d  distinct_ticks=%d  distinct_cells=%d" % (row_count, len(ticks), len(ncells)))
print("tick range: %d..%d" % (min(ticks), max(ticks)))
print()
print("--- GLOBAL weather_type histogram (current) ---")
tot=sum(type_hist.values())
for k,v in sorted(type_hist.items(), key=lambda x:-x[1]):
    print("  type %3d : %10d  (%.1f%%)" % (k, v, 100.0*v/tot))
print("--- GLOBAL weather_target_type histogram ---")
tt=sum(target_hist.values())
for k,v in sorted(target_hist.items(), key=lambda x:-x[1]):
    print("  tgt  %3d : %10d  (%.1f%%)" % (k, v, 100.0*v/tt))
print()
print("--- per-cell weather_type VARIETY (distinct types over whole run) ---")
variety=Counter(len(s) for s in cell_types.values())
for k in sorted(variety):
    print("  cells with %d distinct types: %d" % (k, variety[k]))
print()
print("--- per-cell type CHANGES over time ---")
chg=[cell_type_changes.get(c,0) for c in ncells]
chg.sort()
print("  mean changes/cell=%.2f  median=%d  max=%d  cells_never_changed=%d" % (
    sum(chg)/len(chg), chg[len(chg)//2], chg[-1], sum(1 for x in chg if x==0)))
print()
print("--- field TEMPORAL std per cell (mean across cells) : ~0 means field frozen ---")
for fld in fields:
    tstds=[]
    for c in ncells:
        n=cell_cnt[c]
        if n<2: continue
        m=cell_sum[fld][c]/n
        var=max(0.0, cell_sumsq[fld][c]/n - m*m)
        tstds.append(math.sqrt(var))
    if tstds:
        gm=sum(cell_sum[fld][c] for c in ncells)/max(1,sum(cell_cnt[c] for c in ncells))
        print("  %-28s temporal_std(mean)=%.5f  global_mean=%.5f" % (fld, sum(tstds)/len(tstds), gm))
print()
print("--- wind ---")
print("  wind_speed==0 fraction: %.1f%% (%d/%d)" % (100.0*wind_zero/max(1,wind_total), wind_zero, wind_total))
print()
print("--- correlations (Pearson r) ---")
def corr(a,b):
    n=n_obs
    if n<2: return float('nan')
    ma=sums[a]/n; mb=sums[b]/n
    va=sumsqs[a]/n-ma*ma; vb=sumsqs[b]/n-mb*mb
    if va<=0 or vb<=0: return float('nan')
    cov=cross[(a,b)]/n-ma*mb
    return cov/math.sqrt(va*vb)
for (a,b) in [("precip","moisture"),("precip","temp"),("precip","conv"),("precip","vapor"),
              ("cloud","vapor"),("cloud","moisture"),("type","temp"),("type","moisture")]:
    print("  r(%s, %s) = %.3f" % (a,b,corr(a,b)))
print("="*70)
