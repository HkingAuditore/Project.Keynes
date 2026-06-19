import csv
from collections import Counter, defaultdict

PATH = r'Project.Keynes/tmp/tile_data_record_20260619_184841.csv'
C = {'tick':1,'temp':148,'moisture':150,'sea_ice':158,'intensity':160,'cloud':161,
     'cloud_water':162,'precip':163,'vapor':167,'convergence':168,'instability':169,
     'field_init':170,'wind_speed':205,'terrain':213,'wtype':220,'is_water':223,
     'commit_path':46}

def fval(s):
    if not s: return 0.0
    try: return float(s)
    except: return 0.0

# reservoir-free percentile via coarse histogram (0..1, 200 bins) for selected fields
FIELDS = ['temp','vapor','cloud','cloud_water','precip','instability','convergence','wind_speed','moisture']
BINS = 1000
hist_w = {f:[0]*(BINS+2) for f in FIELDS}
hist_l = {f:[0]*(BINS+2) for f in FIELDS}
cnt_w = 0; cnt_l = 0
commit_paths = Counter()

# cloud band counts on water
cloud_band_w = Counter()
# for water RAIN cells: precip source check (precip>0.03 vs the OR-branch)
water_rain_precip_gt030 = 0
water_rain_or_branch = 0
water_rain_total = 0

def addh(h,v):
    if v<0: v=0.0
    b=int(v*BINS)
    if b>BINS: b=BINS+1
    h[b]+=1

with open(PATH,'r',encoding='utf-8-sig',newline='') as f:
    rd=csv.reader(f); next(rd)
    for row in rd:
        if len(row)<=C['is_water']: continue
        isw=int(fval(row[C['is_water']]))
        commit_paths[row[C['commit_path']]]+=1
        vals={f:fval(row[C[f]]) for f in FIELDS}
        if isw==1:
            cnt_w+=1
            for f in FIELDS: addh(hist_w[f],vals[f])
            c=vals['cloud']
            cloud_band_w[round(min(c,1.0),1)]+=1
            if int(fval(row[C['wtype']]))==1:
                water_rain_total+=1
                p=vals['precip']
                if p>0.030: water_rain_precip_gt030+=1
                elif p>0.022 and vals['cloud']>0.22 and vals['vapor']>0.28: water_rain_or_branch+=1
        else:
            cnt_l+=1
            for f in FIELDS: addh(hist_l[f],vals[f])

def pct(h,n,q):
    target=q*n; acc=0
    for b in range(len(h)):
        acc+=h[b]
        if acc>=target:
            return b/BINS
    return 1.0

def line(f,h,n):
    return f"  {f:12s} p10={pct(h,n,.10):.3f} p50={pct(h,n,.50):.3f} p90={pct(h,n,.90):.3f} p99={pct(h,n,.99):.3f}"

print("commit_path:",dict(commit_paths))
print(f"\n=== WATER field percentiles (n={cnt_w}) ===")
for f in FIELDS: print(line(f,hist_w[f],cnt_w))
print(f"\n=== LAND field percentiles (n={cnt_l}) ===")
for f in FIELDS: print(line(f,hist_l[f],cnt_l))

print("\n=== WATER cloud bands (rounded 0.1) ===")
for k in sorted(cloud_band_w): print(f"  cloud~{k}: {cloud_band_w[k]} ({100.0*cloud_band_w[k]/max(cnt_w,1):.1f}%)")

print("\n=== WATER RAIN cells precip trigger ===")
print(f"  total water-RAIN={water_rain_total}")
print(f"   via precip>0.030      : {water_rain_precip_gt030} ({100.0*water_rain_precip_gt030/max(water_rain_total,1):.1f}%)")
print(f"   via OR(cloud&vapor)   : {water_rain_or_branch} ({100.0*water_rain_or_branch/max(water_rain_total,1):.1f}%)")

# HEATWAVE/DROUGHT feasibility on land: cloud<0.30 / cloud<0.22 counts
ld_cloud_lt030 = sum(hist_l['cloud'][:int(0.30*BINS)])
ld_cloud_lt022 = sum(hist_l['cloud'][:int(0.22*BINS)])
print("\n=== LAND cloud feasibility ===")
print(f"  land cells cloud<0.30 (HEATWAVE gate): {ld_cloud_lt030} ({100.0*ld_cloud_lt030/max(cnt_l,1):.1f}%)")
print(f"  land cells cloud<0.22 (DROUGHT gate) : {ld_cloud_lt022} ({100.0*ld_cloud_lt022/max(cnt_l,1):.1f}%)")
