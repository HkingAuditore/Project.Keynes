import csv
from collections import defaultdict

PATH = r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260628_222157.csv"

def f(x):
    try: return float(x)
    except: return 0.0
def ii(x):
    try: return int(float(x))
    except: return 0

# sea ice thresholds (current climate_profile.gd, for annotation)
T_FORM = 0.08
T_MELT = 0.13

NB = 24            # season-phase bins (over a full year)
def fold(phase, span):
    # phase in [0, span); map to bin [0, NB)
    p = phase % span
    return min(NB - 1, int(p / span * NB))

# Two polar bands. Convention: lat_norm~0 = north pole, ~1 = south pole (anti-phase season).
BANDS = {
    "north_polar(lat<0.12)": lambda L: L < 0.12,
    "south_polar(lat>0.88)": lambda L: L > 0.88,
}

# per band: per-bin accumulators
acc = {b: {"ins": [0.0]*NB, "temp": [0.0]*NB, "t365": [0.0]*NB,
           "ice": [0.0]*NB, "n": [0]*NB} for b in BANDS}

sp_min = 1e9; sp_max = -1e9
tick_min = 1e18; tick_max = -1e18
rows = 0
with open(PATH, "r", newline="") as fh:
    rdr = csv.reader(fh); header = next(rdr)
    ix = {n: k for k, n in enumerate(header)}
    iSP  = ix["phys_daily_wind_season_phase"]
    iTk  = ix["tick_idx"]
    iLat = ix["cell_lat_norm_arr"]
    iW   = ix["is_water_arr"]
    iT   = ix["temp_arr"]
    iIce = ix["sea_ice_frac_arr"]
    iIns = ix["insolation_now_arr"]
    i365 = ix["temp_365d_arr"]
    for row in rdr:
        rows += 1
        if ii(row[iW]) != 1:
            continue
        sp = f(row[iSP])
        if sp <= 0.0:
            continue  # season phase not populated this row
        lat = f(row[iLat])
        band = None
        for b, pred in BANDS.items():
            if pred(lat):
                band = b; break
        if band is None:
            continue
        tk = f(row[iTk])
        if tk < tick_min: tick_min = tk
        if tk > tick_max: tick_max = tk
        if sp < sp_min: sp_min = sp
        if sp > sp_max: sp_max = sp

# Detect season-phase span (4 = 4 seasons, or 1 = normalized year)
SPAN = 4.0 if sp_max > 1.5 else 1.0

# second pass to accumulate (span now known)
with open(PATH, "r", newline="") as fh:
    rdr = csv.reader(fh); header = next(rdr)
    ix = {n: k for k, n in enumerate(header)}
    iSP=ix["phys_daily_wind_season_phase"]; iLat=ix["cell_lat_norm_arr"]
    iW=ix["is_water_arr"]; iT=ix["temp_arr"]; iIce=ix["sea_ice_frac_arr"]
    iIns=ix["insolation_now_arr"]; i365=ix["temp_365d_arr"]
    for row in rdr:
        if ii(row[iW]) != 1: continue
        sp = f(row[iSP])
        if sp <= 0.0: continue
        lat = f(row[iLat]); band=None
        for b,pred in BANDS.items():
            if pred(lat): band=b; break
        if band is None: continue
        k = fold(sp, SPAN)
        a = acc[band]
        a["ins"][k]  += f(row[iIns])
        a["temp"][k] += f(row[iT])
        a["t365"][k] += f(row[i365])
        a["ice"][k]  += f(row[iIce])
        a["n"][k]    += 1

est_days_per_year = None
# estimate days/tick from tick span & season span (assume run covers ~ (tick_span) ticks)
# (informational only)

def argext(arr, want_max):
    best=None; bi=-1
    for i,v in enumerate(arr):
        if best is None or (v>best if want_max else v<best):
            best=v; bi=i
    return bi, best

def cross_phase(arr, level, rising):
    # first bin index where arr crosses `level` in given direction (cyclic scan from min)
    out=[]
    for i in range(NB):
        a=arr[i]; b=arr[(i+1)%NB]
        if rising and a<level<=b: out.append(i)
        if (not rising) and a>level>=b: out.append(i)
    return out

print("rows=%d  season_phase range=[%.3f,%.3f] -> SPAN=%.1f  tick range=[%.0f,%.0f]" % (
    rows, sp_min, sp_max, SPAN, tick_min, tick_max))
print("bins=%d (each bin = %.1f%% of year ~= %.0f days if year=365)" % (NB, 100.0/NB, 365.0/NB))

for b in BANDS:
    a=acc[b]
    ins=[a["ins"][k]/max(1,a["n"][k]) for k in range(NB)]
    tmp=[a["temp"][k]/max(1,a["n"][k]) for k in range(NB)]
    t365=[a["t365"][k]/max(1,a["n"][k]) for k in range(NB)]
    ice=[a["ice"][k]/max(1,a["n"][k]) for k in range(NB)]
    ntot=sum(a["n"])
    print("\n=== %s  (n=%d cell-ticks) ===" % (b, ntot))
    print(" bin |  ins   temp  t365   ice   (phase=bin/%d*year)" % NB)
    for k in range(NB):
        bar = "#" * int(ice[k]*30)
        print("  %2d | %.3f %.3f %.3f %.3f  %s" % (k, ins[k], tmp[k], t365[k], ice[k], bar))
    ki_lo,_=argext(ins,False); ki_hi,_=argext(ins,True)
    kt_lo,_=argext(tmp,False); kt_hi,_=argext(tmp,True)
    kc_hi,_=argext(ice,True);  kc_lo,_=argext(ice,False)
    def to_days(bins):
        return bins*(365.0/NB)
    def lag(a_bin,b_bin):
        d=(b_bin-a_bin)%NB
        return d, to_days(d)
    print("  argmin insol @bin %d | argmin temp @bin %d | argmax ice @bin %d | argmin ice @bin %d" % (
        ki_lo,kt_lo,kc_hi,kc_lo))
    d1,dd1=lag(ki_lo,kt_lo); d2,dd2=lag(kt_lo,kc_hi)
    d3,dd3=lag(ki_hi,kt_hi); d4,dd4=lag(kt_hi,kc_lo)
    print("  LAG insol_min->temp_min = %d bins (~%.0f d)   temp_min->ice_max = %d bins (~%.0f d)" % (d1,dd1,d2,dd2))
    print("  LAG insol_max->temp_max = %d bins (~%.0f d)   temp_max->ice_min = %d bins (~%.0f d)" % (d3,dd3,d4,dd4))
    # ice onset/melt-out timing vs temp threshold crossings
    up=cross_phase(ice,0.5,True); dn=cross_phase(ice,0.5,False)
    tform_dn=cross_phase(tmp,T_FORM,False); tmelt_up=cross_phase(tmp,T_MELT,True)
    print("  ice rises through 0.5 @bins %s ; falls through 0.5 @bins %s" % (up,dn))
    print("  temp falls below t_form(%.2f) @bins %s ; temp rises above t_melt(%.2f) @bins %s" % (
        T_FORM,tform_dn,T_MELT,tmelt_up))
