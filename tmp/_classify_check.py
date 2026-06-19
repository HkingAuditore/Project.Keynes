import csv, sys
PATH = sys.argv[1] if len(sys.argv)>1 else r'Project.Keynes/tmp/tile_data_record_20260619_202707.csv'
C = {'ctemp':165,'cloud':161,'precip':163,'vapor':167,'inst':169,'tta':193,
     'lat':211,'wt':220,'is_water':223,'sphase':121,'temp':148,'air':171}
WT={0:'CLEAR',1:'RAIN',2:'STORM',3:'BLIZZARD',4:'DROUGHT',5:'FOG',6:'HEATWAVE',7:'MONSOON'}
def fv(s):
    try: return float(s)
    except: return 0.0
def iv(s):
    try: return int(float(s))
    except: return -1

COLD_AS_BLIZ=True; SNOW_MARGIN=0.03
def classify(season_idx, temp,vapor,cloud,precip,inst,oan,lat_signed):
    lat_abs=abs(lat_signed)
    north_summer=0.5
    if season_idx==1: north_summer=1.0
    elif season_idx==3: north_summer=0.0
    local_summer = north_summer if lat_signed<0 else (1.0-north_summer)
    warm=temp>0.55; humid=vapor>0.28
    meaningful = precip>0.030 or (precip>0.022 and cloud>0.22 and vapor>0.28)
    if COLD_AS_BLIZ and meaningful and (temp<=0.24 or (temp<0.31+SNOW_MARGIN and cloud>0.18 and vapor>0.20 and precip>0.04)):
        return 3
    spg=0.068+(0.056-0.068)*local_summer
    sig=0.56+(0.50-0.56)*local_summer
    woc = oan>0.12 and inst>0.70 and precip>0.07 and cloud>0.28
    if warm and humid and lat_abs<0.70 and ((inst>sig and precip>spg) or woc):
        return 2
    if warm and humid and lat_abs<0.42 and local_summer>0.5 and precip>0.055:
        return 7
    if meaningful: return 1
    if vapor>0.34 and cloud>0.14 and precip<0.030 and temp<0.55: return 5
    if temp>0.70 and cloud<0.30 and precip<0.025 and lat_abs<0.62 and local_summer>0.35: return 6
    if cloud<0.22 and precip<0.020 and temp>0.48 and vapor<0.34: return 4
    return 0

def cl01(x): return 0.0 if x<0 else (1.0 if x>1 else x)
rows=[]
sphase_vals=set()
with open(PATH,encoding='utf-8-sig',newline='') as f:
    rd=csv.reader(f); next(rd)
    for row in rd:
        if len(row)<=C['is_water']: continue
        t165=fv(row[C['ctemp']]); cloud=fv(row[C['cloud']]); precip=fv(row[C['precip']])
        vapor=fv(row[C['vapor']]); inst=fv(row[C['inst']]); oan=fv(row[C['tta']])
        t148=fv(row[C['temp']]); air=fv(row[C['air']])
        norm=fv(row[C['lat']]); ls=2.0*norm-1.0
        rec=iv(row[C['wt']])
        sphase_vals.add(row[C['sphase']])
        rows.append((t165,t148,air,vapor,cloud,precip,inst,oan,ls,rec))

print(f"rows={len(rows)}  season_phase distinct sample={list(sphase_vals)[:4]}")
rdist={}
for r in rows: rdist[r[9]]=rdist.get(r[9],0)+1
n=len(rows)
print("recorded:", ', '.join(f"{WT[k]} {100.0*v/n:.1f}%" for k,v in sorted(rdist.items(),key=lambda kv:-kv[1])))
print()
# temp variants to find the true classifier temp input
tempdefs = {
 'T=col165(prev snapshot)': lambda t165,t148,air: t165,
 'T=col148(temp_arr)':      lambda t165,t148,air: t148,
 'T=clamp(148+air)':        lambda t165,t148,air: cl01(t148+air),
}
season=2  # autumn (season_phase~2.5)
for tname,tf in tempdefs.items():
    agree=0; rep={}; storm_pool=0
    for (t165,t148,air,vp,cld,pr,ins,oa,ls,rec) in rows:
        t=tf(t165,t148,air)
        w=classify(season,t,vp,cld,pr,ins,oa,ls)
        rep[w]=rep.get(w,0)+1
        if w==rec: agree+=1
    print(f"{tname:26s}: agree={100.0*agree/n:.1f}%  STORM={100.0*rep.get(2,0)/n:.1f}%  RAIN={100.0*rep.get(1,0)/n:.1f}%  CLEAR={100.0*rep.get(0,0)/n:.1f}%  FOG={100.0*rep.get(5,0)/n:.1f}%  BLIZ={100.0*rep.get(3,0)/n:.1f}%")
