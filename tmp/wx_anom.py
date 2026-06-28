import csv, math
from collections import Counter

PATH = r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260628_012555.csv"

def f(x):
    try: return float(x)
    except: return 0.0
def i(x):
    try: return int(float(x))
    except: return 0

def pct(a, p):
    if not a: return 0.0
    a = sorted(a)
    return a[min(len(a)-1, int(p*len(a)))]

with open(PATH,"r",newline="") as fh:
    rdr=csv.reader(fh); header=next(rdr)
    ix={n:k for k,n in enumerate(header)}
    def c(n): return ix[n]
    all_an=[]; land_an=[]
    heat_an=[]      # temp_anomaly of cells currently HEATWAVE(6)
    drought_cand_an=[]  # warm bone-dry low-cloud land cells (would-be drought)
    heat_cond_meta=Counter()  # how many heatwave cells pass warm/dry sub-gates
    n_heat=0; n_clear=0
    # sample to keep memory bounded
    for ri,row in enumerate(rdr):
        an=f(row[c("temp_anomaly_arr")])
        isw=i(row[c("is_water_arr")])==1
        wt=i(row[c("weather_type_arr")])
        tmp=f(row[c("temp_arr")])
        prc=f(row[c("weather_precip_arr")])
        cld=f(row[c("weather_cloud_arr")])
        vap=f(row[c("weather_vapor_arr")])
        if len(all_an)<400000: all_an.append(an)
        if (not isw) and len(land_an)<400000: land_an.append(an)
        if wt==6:
            n_heat+=1
            if len(heat_an)<400000: heat_an.append(an)
        if wt==0: n_clear+=1
        # would-be drought candidate: land, warm, bone dry, low cloud
        if (not isw) and tmp>0.55 and prc<0.006 and cld<0.18:
            if len(drought_cand_an)<400000: drought_cand_an.append(an)

print("temp_anomaly percentiles (ALL):  p50=%.4f p75=%.4f p90=%.4f p95=%.4f p99=%.4f max=%.4f" % (
    pct(all_an,.50),pct(all_an,.75),pct(all_an,.90),pct(all_an,.95),pct(all_an,.99),max(all_an)))
print("temp_anomaly percentiles (LAND): p50=%.4f p75=%.4f p90=%.4f p95=%.4f p99=%.4f max=%.4f" % (
    pct(land_an,.50),pct(land_an,.75),pct(land_an,.90),pct(land_an,.95),pct(land_an,.99),max(land_an)))
print()
print("HEATWAVE cells: n=%d" % n_heat)
if heat_an:
    print("  their temp_anomaly: p10=%.4f p50=%.4f p90=%.4f mean=%.4f" % (
        pct(heat_an,.10),pct(heat_an,.50),pct(heat_an,.90), sum(heat_an)/len(heat_an)))
    for g in [0.03,0.04,0.05,0.06,0.08,0.10]:
        survive=sum(1 for a in heat_an if a>g)
        print("    if HEATWAVE gate temp_anom>%.2f : %d/%d survive (%.1f%%)  -> heatwave count x%.2f" % (
            g, survive, len(heat_an), 100.0*survive/len(heat_an), survive/len(heat_an)))
print()
print("would-be DROUGHT candidates (land warm bonedry lowcloud): n_sampled=%d" % len(drought_cand_an))
if drought_cand_an:
    for g in [0.03,0.05,0.06,0.10]:
        q=sum(1 for a in drought_cand_an if a>g)
        print("    drought gate temp_anom>%.2f : %d (%.1f%%) qualify" % (g,q,100.0*q/len(drought_cand_an)))
