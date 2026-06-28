import csv, math
from collections import Counter, defaultdict

PATH = r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260628_164054.csv"
TYPE_NAMES=["CLEAR","RAIN","STORM","BLIZZARD","DROUGHT","FOG","HEATWAVE","MONSOON"]

def f(x):
    try: return float(x)
    except: return 0.0
def ii(x):
    try: return int(float(x))
    except: return 0
def pct(a,p):
    if not a: return 0.0
    a_=a; return a_[min(len(a_)-1,int(p*len(a_)))]

def smoothstep(e0,e1,x):
    if e1==e0: return 0.0
    t=(x-e0)/(e1-e0)
    if t<0: t=0.0
    elif t>1: t=1.0
    return t*t*(3.0-2.0*t)

# Faithful replay of wf_classify_field_weather_at (world_ext_internal.h:702-792)
def classify(temp,vapor,cloud,cloud_water,precip,instability,ocean_an,wind_speed,
             temp_anom,monsoon_flux,is_water,snow_cover,
             cold_precip_as_blizzard=True, snow_margin=0.05):
    warm = temp>0.55
    humid_gate    = 0.28 if is_water else 0.09
    mp_cloud_gate = 0.22 if is_water else 0.12
    mp_vapor_gate = 0.28 if is_water else 0.09
    monsoon_vapor = 0.40 if is_water else 0.14
    monsoon_precip= 0.055 if is_water else 0.065
    monsoon_cloud = 0.45 if is_water else 0.24
    fog_vapor     = 0.22 if is_water else 0.16
    fog_cloud     = 0.085 if is_water else 0.10
    humid = vapor>humid_gate
    effective_cloud = cloud if cloud>cloud_water*1.25 else cloud_water*1.25
    precip_cloud_mass = cloud_water if cloud_water>precip*0.70 else precip*0.70
    precip_gate      = 0.032 if is_water else 0.040
    weak_precip_gate = 0.022 if is_water else 0.030
    meaningful_precip = (precip>precip_gate) or (precip>weak_precip_gate and effective_cloud>mp_cloud_gate
                          and precip_cloud_mass>mp_cloud_gate*0.35 and vapor>mp_vapor_gate)
    if cold_precip_as_blizzard and meaningful_precip:
        if temp<=0.24: return 3
        if (not is_water) and snow_cover>=0.25 and temp<0.31+snow_margin: return 3
        if temp<0.31+snow_margin and effective_cloud>0.18 and vapor>0.20 and precip>0.04 and wind_speed>1.0: return 3
    warm_ocean_core = is_water and ocean_an>0.05 and instability>0.64 and precip>0.060 and effective_cloud>0.24 and precip_cloud_mass>0.045
    if warm and humid and ((instability>0.70 and precip>0.065 and precip_cloud_mass>0.050) or warm_ocean_core):
        return 2
    monsoon_driver = smoothstep(monsoon_vapor*0.78, monsoon_vapor+0.06, vapor)*0.24
    if monsoon_flux>monsoon_driver: monsoon_driver=monsoon_flux
    sustained_precip = precip>monsoon_precip*0.82 and precip_cloud_mass>monsoon_cloud*0.38
    monsoon_flux_gate = 0.08 if is_water else 0.13
    inland_monsoon_plume = (not is_water) and vapor>0.24 and wind_speed>0.75 and precip>monsoon_precip and precip_cloud_mass>monsoon_cloud*0.45
    monsoon_flow_gate = monsoon_driver>monsoon_flux_gate or inland_monsoon_plume
    if warm and sustained_precip and effective_cloud>monsoon_cloud*0.82 and monsoon_flow_gate:
        return 7
    if meaningful_precip: return 1
    if vapor>fog_vapor and effective_cloud>fog_cloud and precip<0.030 and temp<0.55: return 5
    if (not is_water) and temp>0.55 and temp_anom>0.05 and precip<0.006 and effective_cloud<0.18: return 4
    if (not is_water) and warm and temp_anom>0.04 and precip<0.012 and effective_cloud<0.24 and vapor<0.12: return 6
    return 0

with open(PATH,"r",newline="") as fh:
    rdr=csv.reader(fh); header=next(rdr)
    ix={n:k for k,n in enumerate(header)}
    def c(n): return ix[n]
    cols=["temp_arr","weather_vapor_arr","weather_cloud_arr","weather_cloud_water_arr",
          "weather_precip_arr","weather_instability_arr","ocean_thermal_anomaly_arr",
          "wind_speed_arr","temp_anomaly_arr","snow_cover_arr","is_water_arr",
          "weather_type_arr","weather_convergence_arr"]
    cidx={n:c(n) for n in cols}

    # distributions land/water
    dist={ (w,k):[] for w in (0,1) for k in ["vapor","cloud","cw","precip","instab","tanom","conv","effcloud"] }
    # gate counters land/water
    gate=defaultdict(int); tot=defaultdict(int)
    recorded=Counter(); replayed=Counter(); confusion=Counter()
    rows=0
    SAMPLE_CAP=400000
    for row in rdr:
        rows+=1
        isw = ii(row[cidx["is_water_arr"]])==1
        w = 1 if isw else 0
        temp=f(row[cidx["temp_arr"]]); vapor=f(row[cidx["weather_vapor_arr"]])
        cloud=f(row[cidx["weather_cloud_arr"]]); cw=f(row[cidx["weather_cloud_water_arr"]])
        precip=f(row[cidx["weather_precip_arr"]]); instab=f(row[cidx["weather_instability_arr"]])
        ocean_an=f(row[cidx["ocean_thermal_anomaly_arr"]]); wspd=f(row[cidx["wind_speed_arr"]])
        tanom=f(row[cidx["temp_anomaly_arr"]]); snow=f(row[cidx["snow_cover_arr"]])
        conv=f(row[cidx["weather_convergence_arr"]])
        wt_rec=ii(row[cidx["weather_type_arr"]])
        effcloud = cloud if cloud>cw*1.25 else cw*1.25

        if len(dist[(w,"vapor")])<SAMPLE_CAP:
            dist[(w,"vapor")].append(vapor); dist[(w,"cloud")].append(cloud)
            dist[(w,"cw")].append(cw); dist[(w,"precip")].append(precip)
            dist[(w,"instab")].append(instab); dist[(w,"tanom")].append(tanom)
            dist[(w,"conv")].append(conv); dist[(w,"effcloud")].append(effcloud)

        tot[w]+=1
        if instab>0.70: gate[(w,"instab>0.70")]+=1
        if instab>0.64: gate[(w,"instab>0.64")]+=1
        if tanom>0.05: gate[(w,"tanom>0.05")]+=1
        if tanom>0.04: gate[(w,"tanom>0.04")]+=1
        if temp>0.55: gate[(w,"warm")]+=1
        if precip>(0.065 if isw else 0.065): gate[(w,"precip>0.065")]+=1
        # FOG condition
        fog_vapor=0.22 if isw else 0.16; fog_cloud=0.085 if isw else 0.10
        if vapor>fog_vapor and effcloud>fog_cloud and precip<0.030 and temp<0.55: gate[(w,"FOG_cond")]+=1
        # combined STORM precondition
        if temp>0.55 and vapor>(0.28 if isw else 0.09) and instab>0.70 and precip>0.065: gate[(w,"STORM_all")]+=1

        wt_rep=classify(temp,vapor,cloud,cw,precip,instab,ocean_an,wspd,tanom,0.0,isw,snow)
        recorded[wt_rec]+=1; replayed[wt_rep]+=1
        confusion[(wt_rec,wt_rep)]+=1

print("rows=%d" % rows)
print("\n=== FIELD PERCENTILES (land=0 / water=1) ===")
for w in (0,1):
    lab="LAND " if w==0 else "WATER"
    print("  [%s]" % lab)
    for k in ["vapor","cloud","cw","precip","instab","tanom","conv","effcloud"]:
        a=sorted(dist[(w,k)])
        print("    %-9s p10=%.4f p50=%.4f p75=%.4f p90=%.4f p99=%.4f max=%.4f" % (
            k, pct(a,.10),pct(a,.50),pct(a,.75),pct(a,.90),pct(a,.99), a[-1] if a else 0))

print("\n=== GATE PASS RATES (%% of land/water cell-ticks) ===")
for key in ["warm","instab>0.64","instab>0.70","precip>0.065","STORM_all","tanom>0.04","tanom>0.05","FOG_cond"]:
    l = 100.0*gate.get((0,key),0)/max(1,tot[0])
    wv= 100.0*gate.get((1,key),0)/max(1,tot[1])
    print("  %-14s land=%.3f%%  water=%.3f%%" % (key,l,wv))

print("\n=== CLASSIFIER REPLAY (on recorded field values) ===")
t=sum(recorded.values())
print("  %-9s  recorded     replayed" % "TYPE")
for k in range(8):
    print("  %-9s  %8d(%5.2f%%)  %8d(%5.2f%%)" % (TYPE_NAMES[k],
        recorded.get(k,0),100.0*recorded.get(k,0)/max(1,t),
        replayed.get(k,0),100.0*replayed.get(k,0)/max(1,t)))
print("\n=== CONFUSION (recorded -> replayed), top mismatches ===")
mism=[(v,a,b) for (a,b),v in confusion.items() if a!=b]
mism.sort(reverse=True)
for v,a,b in mism[:12]:
    print("  %-9s -> %-9s : %d (%.2f%%)" % (TYPE_NAMES[a],TYPE_NAMES[b],v,100.0*v/max(1,t)))
agree=sum(v for (a,b),v in confusion.items() if a==b)
print("  AGREE: %d/%d (%.2f%%)" % (agree,t,100.0*agree/max(1,t)))
