# Comprehensive weather-simulation analysis. Loads wx_arrays.npz, prints a
# structured report, and renders spatial/temporal figures to wx_figs/.
import numpy as np, os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

d = np.load("wx_arrays.npz")
R, COL, C, T = 64, 100, 6400, 412
def f32(k): return d["f32_"+k]
def i8(k):  return d["i8_"+k]
def sc(k):  return d["sc_"+k]
def st(k):  return d["st_"+k]
ticks = d["ticks"]
os.makedirs("wx_figs", exist_ok=True)

WT_NAMES = {0:"CLEAR",1:"RAIN",2:"STORM",3:"BLIZZARD",4:"DROUGHT",5:"FOG",6:"HEATWAVE",7:"MONSOON"}
WET = {1,2,3,7}        # precipitating types (incl blizzard=snow, monsoon)
LIQUID = {1,2,7}       # liquid rain types

lat  = st("cell_lat_norm_arr")        # 0=south pole,0.5=eq,1=north pole
water= st("is_water_arr").astype(bool)
elev = st("elevation_arr")
river= st("has_river_arr")>0.5
land = ~water

precip = f32("weather_precip_arr")    # [T,C]
inten  = f32("weather_intensity_arr")
vapor  = f32("weather_vapor_arr")
cloud  = f32("weather_cloud_arr")
cloudw = f32("weather_cloud_water_arr")
conv   = f32("weather_convergence_arr")
instab = f32("weather_instability_arr")
temp   = f32("temp_arr")
moist  = f32("moisture_arr")
snow   = f32("snow_cover_arr")
snowpk = f32("snowpack_arr")
seaice = f32("sea_ice_frac_arr")
veg    = f32("vegetation_vitality_arr")
wt     = i8("weather_type_arr")       # [T,C]
prevt  = i8("weather_prev_type_arr")
tgtt   = i8("weather_target_type_arr")

def line(s=""): print(s)
def hdr(s): print("\n"+"="*78+"\n"+s+"\n"+"="*78)

# abs latitude band index (0=equator .. ) for zonal stats
abslat = np.abs(lat-0.5)*2.0   # 0 at equator, 1 at pole
latdeg = (lat-0.5)*180.0       # -90..+90 pseudo-degrees

hdr("0. STRUCTURE / TIME AXIS")
line(f"ticks: {T} consecutive ({int(ticks[0])}..{int(ticks[-1])})  cells: {C} (grid {R}x{COL})")
line(f"water cells: {int(water.sum())}  land cells: {int(land.sum())}  river cells: {int(river.sum())}")
day = sc("phys_sim_day")
line(f"phys_sim_day across ticks: min={np.nanmin(day):.0f} max={np.nanmax(day):.0f} (non-monotonic; tick is the clock)")
# weather recompute cadence: cells changing type between consecutive ticks
chg = (wt[1:]!=wt[:-1]).sum(axis=1)
line(f"per-tick weather_type changes: mean={chg.mean():.0f} median={np.median(chg):.0f} "
     f"min={chg.min()} max={chg.max()}  ticks-with-zero-change={(chg==0).sum()}")
line(f"  -> weather updates effectively every tick" if (chg==0).sum()<T*0.2 else
     "  -> weather updates intermittently (commit cadence > 1 tick)")

hdr("1. WEATHER-TYPE DIVERSITY (global, all ticks x cells)")
flat = wt.ravel()
tot = flat.size
for t in range(8):
    cnt = int((flat==t).sum())
    line(f"  {t} {WT_NAMES[t]:9s}: {cnt:10d}  {100.0*cnt/tot:6.3f}%")
present = sorted(set(int(x) for x in np.unique(flat)))
line(f"types ever present: {[WT_NAMES[t] for t in present]}")
line(f"types ABSENT: {[WT_NAMES[t] for t in range(8) if t not in present]}")
# Shannon entropy of type mix per tick (diversity over time)
ent = []
for ti in range(T):
    c = np.bincount(wt[ti], minlength=8).astype(float)
    p = c/c.sum(); p = p[p>0]
    ent.append(-(p*np.log2(p)).sum())
ent = np.array(ent)
line(f"per-tick type Shannon entropy: mean={ent.mean():.3f} bits min={ent.min():.3f} max={ent.max():.3f} (0=monoculture, ~3=even 8-way)")

hdr("2. PERMANENT RAIN / DROUGHT ZONES")
wet_mask = np.isin(wt, list(WET))
wet_frac = wet_mask.mean(axis=0)             # per-cell fraction of ticks raining (by type)
precip_wet = (precip>0.02)
precip_frac = precip_wet.mean(axis=0)        # per-cell fraction with meaningful precip
line("Per-cell fraction-of-time RAINING (precip>0.02):")
for thr,lbl in [(0.999,"=100% (PERMA-RAIN)"),(0.95,">=95%"),(0.90,">=90%"),(0.75,">=75%"),(0.50,">=50%")]:
    m = precip_frac>=thr
    line(f"  {lbl:20s}: {int(m.sum()):5d} cells ({100*m.sum()/C:.2f}%)  of which land={int((m&land).sum())} ocean={int((m&water).sum())}")
line("Distribution of per-cell wet-fraction (histogram, 10 bins 0..1):")
h,_=np.histogram(precip_frac,bins=10,range=(0,1))
for i,b in enumerate(h):
    line(f"  [{i/10:.1f}-{(i+1)/10:.1f}): {b:5d} cells {'#'*int(60*b/max(h.max(),1))}")
# land-only desert (permanent drought) vs always-wet
land_dry = land & (precip_frac<0.01)
land_perma_wet = land & (precip_frac>0.9)
line(f"LAND cells essentially never raining (<1% of time): {int(land_dry.sum())} ({100*land_dry.sum()/land.sum():.1f}% of land)")
line(f"LAND cells raining >90% of time (perma-wet suspect): {int(land_perma_wet.sum())} ({100*land_perma_wet.sum()/land.sum():.1f}% of land)")
ocean_perma_wet = water & (precip_frac>0.9)
line(f"OCEAN cells raining >90% of time: {int(ocean_perma_wet.sum())} ({100*ocean_perma_wet.sum()/water.sum():.1f}% of ocean)")
# DROUGHT weather type stuck?
dr_frac = (wt==4).mean(axis=0)
line(f"DROUGHT-type: cells ever DROUGHT={int((dr_frac>0).sum())}, max per-cell DROUGHT fraction={dr_frac.max():.3f}")

hdr("3. PRECIP LIFECYCLE: spell lengths (generation->dissipation)")
# per-cell run lengths of consecutive raining ticks
def run_lengths(boolmat):
    out=[]
    for c in range(boolmat.shape[1]):
        col=boolmat[:,c];
        if not col.any(): continue
        idx=np.where(np.diff(np.concatenate(([0],col.view(np.int8),[0])))!=0)[0]
        runs=idx[1::2]-idx[0::2]
        out.extend(runs.tolist())
    return np.array(out)
rl = run_lengths(precip_wet)
if rl.size:
    line(f"rain-spell count={rl.size}  length ticks: mean={rl.mean():.1f} median={np.median(rl):.0f} p90={np.percentile(rl,90):.0f} max={rl.max()} (T={T})")
    line(f"  spells lasting entire window (==T): {int((rl>=T).sum())}  (>=0.9T): {int((rl>=0.9*T).sum())}")
    h,_=np.histogram(rl,bins=[1,2,4,8,16,32,64,128,256,T+1])
    edges=[1,2,4,8,16,32,64,128,256,T]
    for i,b in enumerate(h):
        line(f"  spell {edges[i]:3d}-{edges[i+1]:<3d} ticks: {b:6d} {'#'*int(50*b/max(h.max(),1))}")
# global precip pulsing over time
gp = precip.mean(axis=1); npre=(precip>0.02).sum(axis=1)
line(f"global mean precip over time: min={gp.min():.4f} max={gp.max():.4f} cv={gp.std()/gp.mean():.2f}")
line(f"precipitating-cell count over time: min={npre.min()} max={npre.max()} mean={npre.mean():.0f}")

print("\n[section 0-3 done]")
np.savez("wx_derived.npz", wet_frac=wet_frac, precip_frac=precip_frac, abslat=abslat, latdeg=latdeg)
