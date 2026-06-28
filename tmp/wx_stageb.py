import csv, math
from collections import defaultdict, Counter

PATH = r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260628_164054.csv"
TYPE_NAMES=["CLEAR","RAIN","STORM","BLIZZARD","DROUGHT","FOG","HEATWAVE","MONSOON"]

def f(x):
    try: return float(x)
    except: return 0.0
def i(x):
    try: return int(float(x))
    except: return 0
def pct(a,p):
    if not a: return 0.0
    return a[min(len(a)-1,int(p*len(a)))]

class Corr:
    __slots__=("n","mx","my","sx","sy","sxy")
    def __init__(s): s.n=0;s.mx=0.0;s.my=0.0;s.sx=0.0;s.sy=0.0;s.sxy=0.0
    def add(s,x,y):
        s.n+=1;dx=x-s.mx;dy=y-s.my;s.mx+=dx/s.n;s.my+=dy/s.n
        s.sx+=dx*(x-s.mx);s.sy+=dy*(y-s.my);s.sxy+=dx*(y-s.my)
    def r(s):
        if s.n<2 or s.sx<=0 or s.sy<=0: return float('nan')
        return s.sxy/math.sqrt(s.sx*s.sy)

with open(PATH,"r",newline="") as fh:
    rdr=csv.reader(fh); header=next(rdr)
    ix={n:k for k,n in enumerate(header)}
    def c(n): return ix[n]

    type_hist=Counter(); cell_types=defaultdict(set); cell_last={}; cell_chg=defaultdict(int)
    # sea ice
    ice_water=[]                      # sea_ice_frac of water cells (sampled)
    ice_vs_temp=defaultdict(lambda:[0.0,0])   # temp bin -> [sum_ice, n]  (water only)
    ice_vs_lat=defaultdict(lambda:[0.0,0.0,0])# lat bin -> [sum_ice, sum_temp, n] (water)
    cell_ice_sum=defaultdict(float); cell_ice_sq=defaultdict(float); cell_ice_n=defaultdict(int)  # temporal
    ice_warm_count=0; water_count=0; ice_any_count=0
    ice_delta=[]                      # |ice-ice_prev| sampled (freeze/melt activity)
    # climate consistency
    temp_vs_lat=defaultdict(lambda:[0.0,0])   # lat bin -> [sum_temp, n] (land)
    cell_temp_sum=defaultdict(float); cell_temp_sq=defaultdict(float); cell_temp_n=defaultdict(int)
    # coupling correlations
    cor={k:Corr() for k in ["cloud_vapor","precip_vapor","precip_conv","precip_temp",
                            "precip_moist","precip_lat","ice_temp","ice_lat","temp_lat",
                            "precip_oceancur","cloud_moist"]}
    rows=0; ticks=set()
    for row in rdr:
        rows+=1
        t=i(row[c("tick_idx")]); ticks.add(t)
        ci=i(row[c("cell_index")])
        isw=i(row[c("is_water_arr")])==1
        wt=i(row[c("weather_type_arr")])
        temp=f(row[c("temp_arr")]); moi=f(row[c("moisture_arr")])
        lat=f(row[c("cell_lat_norm_arr")])
        ice=f(row[c("sea_ice_frac_arr")]); icep=f(row[c("sea_ice_frac_arr_prev")])
        vap=f(row[c("weather_vapor_arr")]); cld=f(row[c("weather_cloud_arr")])
        prc=f(row[c("weather_precip_arr")]); cnv=f(row[c("weather_convergence_arr")])
        ocx=f(row[c("ocean_current_x_arr")]); ocy=f(row[c("ocean_current_y_arr")])
        ocmag=math.hypot(ocx,ocy)

        type_hist[wt]+=1
        cell_types[ci].add(wt)
        if ci in cell_last and cell_last[ci]!=wt: cell_chg[ci]+=1
        cell_last[ci]=wt

        latbin=min(9,int(lat*10))
        if isw:
            water_count+=1
            if len(ice_water)<300000: ice_water.append(ice)
            tb=min(9,int(temp*10)); ib=ice_vs_temp[tb]; ib[0]+=ice; ib[1]+=1
            lb=ice_vs_lat[latbin]; lb[0]+=ice; lb[1]+=temp; lb[2]+=1
            cell_ice_sum[ci]+=ice; cell_ice_sq[ci]+=ice*ice; cell_ice_n[ci]+=1
            if ice>0.05: ice_any_count+=1
            if ice>0.10 and temp>0.45: ice_warm_count+=1
            if len(ice_delta)<300000: ice_delta.append(abs(ice-icep))
            cor["ice_temp"].add(ice,temp); cor["ice_lat"].add(ice,lat)
        else:
            tb=temp_vs_lat[latbin]; tb[0]+=temp; tb[1]+=1
            cell_temp_sum[ci]+=temp; cell_temp_sq[ci]+=temp*temp; cell_temp_n[ci]+=1
            cor["precip_vapor"].add(prc,vap); cor["cloud_vapor"].add(cld,vap)
            cor["precip_conv"].add(prc,cnv); cor["precip_temp"].add(prc,temp)
            cor["precip_moist"].add(prc,moi); cor["precip_lat"].add(prc,lat)
            cor["precip_oceancur"].add(prc,ocmag); cor["cloud_moist"].add(cld,moi)
        cor["temp_lat"].add(temp,lat)

print("rows=%d ticks=%d range=%d..%d cells=%d" % (rows,len(ticks),min(ticks),max(ticks),len(cell_last)))
tot=sum(type_hist.values())
print("\n=== WEATHER TYPE (post Stage A) ===")
for k in range(8):
    v=type_hist.get(k,0); print("  %-9s(%d): %9d  (%.2f%%)" % (TYPE_NAMES[k],k,v,100.0*v/max(1,tot)))
var=Counter(len(s) for s in cell_types.values())
never=sum(1 for ci in cell_last if cell_chg.get(ci,0)==0)
print("  per-cell variety:", dict(sorted(var.items())), " | never-changed=%d/%d (%.1f%%)" % (never,len(cell_last),100.0*never/max(1,len(cell_last))))

print("\n=== SEA ICE ===")
ice_water.sort(); ice_delta.sort()
print("  water cells: ice p50=%.3f p90=%.3f p99=%.3f mean=%.3f | ice>0.05 in %.1f%% | ICE-ON-WARM(temp>.45,ice>.1)=%d (%.2f%% of water)" % (
    pct(ice_water,.5),pct(ice_water,.9),pct(ice_water,.99), (sum(ice_water)/len(ice_water) if ice_water else 0),
    100.0*ice_any_count/max(1,water_count), ice_warm_count, 100.0*ice_warm_count/max(1,water_count)))
print("  |ice-ice_prev| (freeze/melt activity): p50=%.4f p90=%.4f p99=%.4f max=%.4f" % (
    pct(ice_delta,.5),pct(ice_delta,.9),pct(ice_delta,.99), ice_delta[-1] if ice_delta else 0))
# temporal std of ice per water cell
tstd=[]
for ci in cell_ice_n:
    n=cell_ice_n[ci]
    if n<2: continue
    m=cell_ice_sum[ci]/n; v=max(0.0,cell_ice_sq[ci]/n-m*m); tstd.append(math.sqrt(v))
print("  per-water-cell ice temporal_std: mean=%.4f (≈0 => frozen, no seasonal freeze/melt)" % (sum(tstd)/max(1,len(tstd))))
print("  ice vs TEMP bins (water): temp[bin] -> mean_ice")
for b in sorted(ice_vs_temp):
    s,n=ice_vs_temp[b]; print("    temp[%.1f-%.1f): mean_ice=%.3f (n=%d)" % (b/10.0,(b+1)/10.0,s/max(1,n),n))

print("\n=== CLIMATE SELF-CONSISTENCY ===")
print("  r(temp, lat)=%.3f   (lat 0..1; expect strong monotonic if 0/1=poles or 0.5=equator)" % cor["temp_lat"].r())
print("  temp vs LAT bins (land): lat[bin] -> mean_temp")
for b in sorted(temp_vs_lat):
    s,n=temp_vs_lat[b]; print("    lat[%.1f-%.1f): mean_temp=%.3f (n=%d)" % (b/10.0,(b+1)/10.0,s/max(1,n),n))
print("  ice vs LAT bins (water): lat[bin] -> mean_ice / mean_temp")
for b in sorted(ice_vs_lat):
    s,st,n=ice_vs_lat[b]; print("    lat[%.1f-%.1f): mean_ice=%.3f mean_temp=%.3f (n=%d)" % (b/10.0,(b+1)/10.0,s/max(1,n),st/max(1,n),n))
# temp seasonal swing
tts=[]
for ci in cell_temp_n:
    n=cell_temp_n[ci]
    if n<2: continue
    m=cell_temp_sum[ci]/n; v=max(0.0,cell_temp_sq[ci]/n-m*m); tts.append(math.sqrt(v))
print("  per-land-cell temp temporal_std (seasonal swing): mean=%.4f" % (sum(tts)/max(1,len(tts))))

print("\n=== WEATHER <-> CLIMATE COUPLING ===")
for k in ["cloud_vapor","precip_vapor","precip_conv","precip_temp","precip_moist","precip_lat","precip_oceancur","cloud_moist","ice_temp","ice_lat"]:
    print("  r(%-14s)=%+.3f" % (k,cor[k].r()))
