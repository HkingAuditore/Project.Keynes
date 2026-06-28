import csv, math
from collections import defaultdict, Counter

PATH = r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260628_012555.csv"

def f(x):
    try: return float(x)
    except: return 0.0
def i(x):
    try: return int(float(x))
    except: return 0

# Welford co-moment for stable Pearson r
class Corr:
    def __init__(s): s.n=0; s.mx=0.0; s.my=0.0; s.sx=0.0; s.sy=0.0; s.sxy=0.0
    def add(s,x,y):
        s.n+=1; dx=x-s.mx; dy=y-s.my
        s.mx+=dx/s.n; s.my+=dy/s.n
        s.sx+=dx*(x-s.mx); s.sy+=dy*(y-s.my); s.sxy+=dx*(y-s.my)
    def r(s):
        if s.n<2 or s.sx<=0 or s.sy<=0: return float('nan')
        return s.sxy/math.sqrt(s.sx*s.sy)

with open(PATH,"r",newline="") as fh:
    rdr=csv.reader(fh); header=next(rdr)
    ix={n:k for k,n in enumerate(header)}
    def c(n): return ix[n]

    # per-tick diagnostics (same across cells): store once per tick
    tick_diag={}
    DIAG=["active_weather_ratio","weather_dirty_count","weather_field_solve_tick",
          "weather_commit_tick_delta","weather_last_commit_tick","weather_cold_front_count",
          "weather_warm_front_count","weather_transitioning_count","weather_target_mismatch_count",
          "climate_precip_p95","climate_wind_mag_p95"]

    corr={k:Corr() for k in ["precip_moist","precip_temp","precip_conv","precip_vapor",
                             "cloud_vapor","cloud_moist","vapor_moist","precip_wind",
                             "vapor_dist_water"]}
    # land/water field accumulators
    land_sum=defaultdict(float); land_n=0
    water_sum=defaultdict(float); water_n=0
    FIELDS=["weather_vapor_arr","weather_cloud_arr","weather_precip_arr",
            "weather_convergence_arr","weather_instability_arr","moisture_arr",
            "temp_arr","temp_anomaly_arr","wind_speed_arr"]
    land_vapor=[]
    # transition counts into each type (prev->cur)
    trans=Counter()
    cell_prev={}
    row_count=0
    for row in rdr:
        row_count+=1
        t=i(row[c("tick_idx")])
        if t not in tick_diag:
            tick_diag[t]={d:f(row[c(d)]) for d in DIAG}
        is_water=i(row[c("is_water_arr")])==1
        vap=f(row[c("weather_vapor_arr")]); cl=f(row[c("weather_cloud_arr")])
        pr=f(row[c("weather_precip_arr")]); conv=f(row[c("weather_convergence_arr")])
        moi=f(row[c("moisture_arr")]); tmp=f(row[c("temp_arr")])
        ws=f(row[c("wind_speed_arr")])
        vals={k:f(row[c(k)]) for k in FIELDS}
        if is_water:
            for k in FIELDS: water_sum[k]+=vals[k]
            water_n+=1
        else:
            for k in FIELDS: land_sum[k]+=vals[k]
            land_n+=1
            if len(land_vapor)<200000: land_vapor.append(vap)
        corr["precip_moist"].add(pr,moi); corr["precip_temp"].add(pr,tmp)
        corr["precip_conv"].add(pr,conv); corr["precip_vapor"].add(pr,vap)
        corr["cloud_vapor"].add(cl,vap); corr["cloud_moist"].add(cl,moi)
        corr["vapor_moist"].add(vap,moi); corr["precip_wind"].add(pr,ws)
        cidx=i(row[c("cell_index")]); wt=i(row[c("weather_type_arr")])
        if cidx in cell_prev and cell_prev[cidx]!=wt:
            trans[(cell_prev[cidx],wt)]+=1
        cell_prev[cidx]=wt

print("rows=%d ticks=%d" % (row_count,len(tick_diag)))
print()
print("--- LAND vs WATER field means ---")
print("  %-26s %10s %10s" % ("field","LAND","WATER"))
for k in FIELDS:
    lm=land_sum[k]/max(1,land_n); wm=water_sum[k]/max(1,water_n)
    print("  %-26s %10.5f %10.5f" % (k,lm,wm))
print("  land_cells_obs=%d water_cells_obs=%d" % (land_n,water_n))
print()
land_vapor.sort()
def pct(a,p): return a[min(len(a)-1,int(p*len(a)))] if a else 0
print("--- LAND vapor percentiles --- p10=%.4f p50=%.4f p90=%.4f p99=%.4f max=%.4f" % (
    pct(land_vapor,.10),pct(land_vapor,.50),pct(land_vapor,.90),pct(land_vapor,.99),land_vapor[-1] if land_vapor else 0))
print()
print("--- correlations (stable Welford) ---")
for k,v in corr.items():
    print("  r(%-14s)=%.3f  (n=%d)" % (k,v.r(),v.n))
print()
print("--- per-tick weather cadence/activity (first 10 + summary) ---")
tks=sorted(tick_diag)
for t in tks[:10]:
    d=tick_diag[t]
    print("  tick %d: active_ratio=%.3f dirty=%d solve_tick=%d commit_delta=%d last_commit=%d transitioning=%d cold_fr=%d warm_fr=%d" % (
        t,d["active_weather_ratio"],d["weather_dirty_count"],d["weather_field_solve_tick"],
        d["weather_commit_tick_delta"],d["weather_last_commit_tick"],d["weather_transitioning_count"],
        d["weather_cold_front_count"],d["weather_warm_front_count"]))
# how many distinct commit ticks (=actual field updates)
commit_ticks=set(int(tick_diag[t]["weather_last_commit_tick"]) for t in tks)
solve_ticks=set(int(tick_diag[t]["weather_field_solve_tick"]) for t in tks)
ar=[tick_diag[t]["active_weather_ratio"] for t in tks]
print("  distinct last_commit_tick values=%d  distinct solve_tick=%d over %d ticks" % (len(commit_ticks),len(solve_ticks),len(tks)))
print("  active_weather_ratio: min=%.3f mean=%.3f max=%.3f" % (min(ar),sum(ar)/len(ar),max(ar)))
fr=[tick_diag[t]["weather_cold_front_count"]+tick_diag[t]["weather_warm_front_count"] for t in tks]
print("  total fronts/tick: min=%.0f mean=%.1f max=%.0f" % (min(fr),sum(fr)/len(fr),max(fr)))
print()
print("--- top weather TYPE transitions (prev->cur), 0=CLR 1=RAIN 2=STORM 3=BLIZ 4=DRGT 5=FOG 6=HEAT 7=MON ---")
for (a,b),cnt in trans.most_common(15):
    print("  %d -> %d : %d" % (a,b,cnt))
