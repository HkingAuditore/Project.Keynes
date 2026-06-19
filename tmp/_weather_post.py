import csv, os, statistics, sys

PATH = sys.argv[1] if len(sys.argv) > 1 else r'Project.Keynes/tmp/tile_data_record_20260619_201314.csv'
C = {'tick':1,'commit':46,'cloud':161,'cloud_water':162,'precip':163,'vapor':167,
     'conv':168,'inst':169,'tta':193,'wind':205,'lat':211,'terrain':213,
     'wt':220,'is_water':223,'moisture':150}
WT = {0:'CLEAR',1:'RAIN',2:'STORM',3:'BLIZZARD',4:'DROUGHT',5:'FOG',6:'HEATWAVE',7:'MONSOON'}

def fv(s):
    if s is None or s=='' : return 0.0
    try: return float(s)
    except: return 0.0

def iv(s):
    try: return int(float(s))
    except: return -1

def clamp01(x): return 0.0 if x<0 else (1.0 if x>1 else x)

# committed candidate-C drive (no frontogenesis term here -> conservative lower bound on release)
def new_drive(oan,inst,conv):
    return max(clamp01(oan/0.16), clamp01((inst-0.90)/0.10), clamp01((conv-0.38)/0.16))

n=0
ticks=set()
commit=set()
wt_all={}; wt_water={}; wt_land={}
water_precip=[]; water_conv=[]; water_inst=[]; water_cloud=[]; water_vapor=[]; water_tta=[]
water_rain_n=0; water_n=0; land_n=0; land_rain_n=0
# for water RAIN cells, what is the drive and its dominant component
rain_drive=[]; rain_conv=[]; rain_inst=[]; rain_tta=[]; rain_precip=[]; rain_cloud=[]
# calm water (low drive) precip to check suppression efficacy
calm_precip=[]; calm_n=0; calm_rain=0
# precip raining share by drive bucket
buckets={'drive=0(calm)':[0,0],'0<drive<0.5':[0,0],'drive>=0.5':[0,0]}

with open(PATH,encoding='utf-8-sig',newline='') as f:
    rd=csv.reader(f); next(rd)
    for row in rd:
        if len(row)<=C['is_water']: continue
        n+=1
        ticks.add(row[C['tick']])
        commit.add(row[C['commit']])
        wt=iv(row[C['wt']])
        isw=iv(row[C['is_water']])==1
        terr=iv(row[C['terrain']])
        precip=fv(row[C['precip']]); conv=fv(row[C['conv']]); inst=fv(row[C['inst']])
        cloud=fv(row[C['cloud']]); vapor=fv(row[C['vapor']]); tta=fv(row[C['tta']])
        nm=WT.get(wt,'?')
        wt_all[nm]=wt_all.get(nm,0)+1
        if isw:
            water_n+=1
            wt_water[nm]=wt_water.get(nm,0)+1
            water_precip.append(precip); water_conv.append(conv); water_inst.append(inst)
            water_cloud.append(cloud); water_vapor.append(vapor); water_tta.append(tta)
            israin = (nm=='RAIN' or nm=='STORM')
            if israin: water_rain_n+=1
            drv=new_drive(tta,inst,conv)
            if drv<=1e-6:
                b='drive=0(calm)'; calm_precip.append(precip); calm_n+=1
                if israin: calm_rain+=1
            elif drv<0.5: b='0<drive<0.5'
            else: b='drive>=0.5'
            buckets[b][1]+=1
            if israin: buckets[b][0]+=1
            if nm=='RAIN':
                rain_drive.append(drv); rain_conv.append(conv); rain_inst.append(inst)
                rain_tta.append(tta); rain_precip.append(precip); rain_cloud.append(cloud)
        else:
            land_n+=1
            wt_land[nm]=wt_land.get(nm,0)+1
            if nm=='RAIN' or nm=='STORM': land_rain_n+=1

def pct(d,tot):
    return ', '.join(f"{k} {100.0*v/max(tot,1):.1f}%" for k,v in sorted(d.items(), key=lambda kv:-kv[1]))

def pctl(a,ps=(5,25,50,75,95)):
    if not a: return 'n/a'
    a=sorted(a)
    def q(p):
        i=min(len(a)-1,int(p/100.0*len(a)))
        return a[i]
    return ' '.join(f"p{p}={q(p):.3f}" for p in ps)

print(f"rows={n}  ticks={len(ticks)} ({min(ticks) if ticks else '-'}..{max(ticks) if ticks else '-'})  commit_path={commit}")
print(f"water cells={water_n}  land cells={land_n}\n")
print("=== weather_type ALL ===")
print(" ", pct(wt_all,n)); print()
print("=== weather_type WATER ===")
print(" ", pct(wt_water,water_n))
print(f"  water RAIN+STORM = {100.0*water_rain_n/max(water_n,1):.1f}%")
print()
print("=== weather_type LAND ===")
print(" ", pct(wt_land,land_n))
print(f"  land RAIN+STORM = {100.0*land_rain_n/max(land_n,1):.1f}%")
print()
print("=== WATER field percentiles ===")
print("  precip:", pctl(water_precip))
print("  conv  :", pctl(water_conv))
print("  inst  :", pctl(water_inst))
print("  cloud :", pctl(water_cloud))
print("  vapor :", pctl(water_vapor))
print("  tta   :", pctl(water_tta))
print()
print("=== suppression efficacy: water raining(RAIN/STORM) share by ocean_drive bucket ===")
for k,(w,t) in buckets.items():
    print(f"  {k}: {100.0*w/max(t,1):.1f}% raining  (n={t}, {100.0*t/max(water_n,1):.1f}% of water)")
print(f"  calm-water precip percentiles:", pctl(calm_precip))
print(f"  calm-water mean precip = {statistics.fmean(calm_precip) if calm_precip else 0:.4f}")
print()
print("=== WATER RAIN cells: what drives them ===")
print(f"  count={len(rain_drive)}")
print("  drive :", pctl(rain_drive))
print("  conv  :", pctl(rain_conv))
print("  inst  :", pctl(rain_inst))
print("  tta   :", pctl(rain_tta))
print("  precip:", pctl(rain_precip))
print("  cloud :", pctl(rain_cloud))
# how many water RAIN cells have drive==0 (i.e., rain leaking through the 0.05 floor)?
leak = sum(1 for d in rain_drive if d<=1e-6)
print(f"  water RAIN with ocean_drive==0 (leak through 1-supp floor): {leak} ({100.0*leak/max(len(rain_drive),1):.1f}% of water RAIN)")
