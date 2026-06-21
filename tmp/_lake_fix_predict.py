import csv, sys
from collections import Counter
PATH = sys.argv[1] if len(sys.argv)>1 else r'Project.Keynes/tmp/tile_data_record_20260619_230533.csv'
C={'cloud':161,'precip':163,'ctemp':165,'vapor':167,'inst':169,'tta':193,
   'terr':213,'lat':211,'wt':220}
WT={0:'CLEAR',1:'RAIN',2:'STORM',3:'BLIZZARD',4:'DROUGHT',5:'FOG',6:'HEATWAVE',7:'MONSOON'}
LAKE=18
def fv(s):
    try: return float(s)
    except: return 0.0
def iv(s):
    try: return int(float(s))
    except: return -1
OCEAN_SUPP=0.95

def classify(lat_norm, temp, vapor, cloud, precip, inst, ocean_an, season_idx=2):
    lat_signed=lat_norm*2.0-1.0; lat_abs=abs(lat_signed)
    north_summer={1:1.0,3:0.0}.get(season_idx,0.5)
    local_summer = north_summer if lat_signed<0.0 else (1.0-north_summer)
    warm=temp>0.55; humid=vapor>0.28
    meaningful = precip>0.030 or (precip>0.022 and cloud>0.22 and vapor>0.28)
    # cold-precip blizzard: only for cold; lakes warm so skip (temp>0.55 => not cold)
    if temp<0.42 and meaningful:  # rough blizzard guard
        return 3
    spg=0.068+(0.056-0.068)*local_summer; sig=0.56+(0.50-0.56)*local_summer
    woc = ocean_an>0.12 and inst>0.70 and precip>0.07 and cloud>0.28
    if warm and humid and lat_abs<0.70 and ((inst>sig and precip>spg) or woc): return 2
    if warm and humid and lat_abs<0.42 and local_summer>0.5 and precip>0.055: return 7
    if meaningful: return 1
    if vapor>0.34 and cloud>0.14 and precip<0.030 and temp<0.55: return 5
    if temp>0.70 and cloud<0.30 and precip<0.025 and lat_abs<0.62 and local_summer>0.35: return 6
    if cloud<0.22 and precip<0.020 and temp>0.48 and vapor<0.34: return 4
    return 0

# gather lake cells
rows=[]
with open(PATH,encoding='utf-8-sig',newline='') as f:
    rd=csv.reader(f); next(rd)
    for r in rd:
        if len(r)<=C['terr']: continue
        if iv(r[C['terr']])!=LAKE: continue
        rows.append((fv(r[C['lat']]),fv(r[C['ctemp']]),fv(r[C['vapor']]),fv(r[C['cloud']]),
                     fv(r[C['precip']]),fv(r[C['inst']]),fv(r[C['tta']]),iv(r[C['wt']])))
n=len(rows)
print(f"lake rows={n}")
# baseline self-check (no suppression) vs recorded
selfc=Counter(); rec=Counter()
for lat,t,v,cl,p,ins,oa,wt in rows:
    selfc[classify(lat,t,v,cl,p,ins,oa)]+=1; rec[wt]+=1
def dist(c):
    tt=sum(c.values()); return ', '.join(f"{WT[k]} {100.0*vv/tt:.1f}%" for k,vv in c.most_common())
print(f"recorded : {dist(rec)}")
print(f"replay(no supp): {dist(selfc)}")
# predict CALM baseline (drive=0) for various lake suppression factors
for fac in [0.76,0.78,0.80,0.82,0.85]:
    supp=OCEAN_SUPP*fac if fac<0.95 else OCEAN_SUPP  # fac here is absolute lake supp when <0.95? keep simple: treat fac as absolute supp
    cc=Counter()
    for lat,t,v,cl,p,ins,oa,wt in rows:
        np_=p*(1.0-fac)   # drive=0 => precip*(1-lake_supp); fac == lake_supp
        cc[classify(lat,t,v,cl,np_,ins,oa)]+=1
    print(f"lake_supp={fac:.2f} CALM(drive=0): {dist(cc)}")
