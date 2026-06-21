import csv, sys, math
from collections import defaultdict
try: sys.stdout.reconfigure(encoding='utf-8')
except Exception: pass
PATH = sys.argv[1]
NAMES = {0:'CLEAR',1:'RAIN',2:'STORM',3:'BLIZZARD',4:'DROUGHT',5:'FOG',6:'HEATWAVE',7:'MONSOON'}
RAINY={1,2,3,7}; DRYY={0,4}
f=open(PATH,encoding='utf-8-sig',newline='')
rd=csv.reader(f); header=next(rd)
col={n:i for i,n in enumerate(header)}
TICK=col['tick_idx']; CID=col['cell_index']
WT=col['weather_type_arr']; PRE=col['weather_precip_arr']; CLD=col['weather_cloud_arr']
VAP=col['weather_vapor_arr']; WATER=col['is_water_arr']; LAT=col['cell_lat_norm_arr']
def fv(s):
    try: return float(s)
    except Exception: return 0.0
def iv(s):
    try: return int(float(s))
    except Exception: return -1
maxcell=0
prev_wt={}; trans=defaultdict(int); rainy_n=defaultdict(int); dryy_n=defaultdict(int)
pn=defaultdict(int); psum=defaultdict(float); psq=defaultdict(float); water_of={}
gwt=defaultdict(int); clouds=[]; precs=[]; vaps=[]; mat=[[0]*8 for _ in range(8)]
band_type=[[0]*8 for _ in range(10)]
rows=0; sample=0; ticks=set()
for r in rd:
    if len(r)<=WT: continue
    rows+=1
    cid=iv(r[CID])
    if cid<0: continue
    if cid>maxcell: maxcell=cid
    ticks.add(r[TICK])
    wt=iv(r[WT]); p=fv(r[PRE]); cl=fv(r[CLD]); w=iv(r[WATER])
    gwt[wt]+=1; sample+=1
    if sample%4==0: clouds.append(cl); precs.append(p); vaps.append(fv(r[VAP]))
    pv=prev_wt.get(cid,-1)
    if pv>=0 and wt!=pv:
        trans[cid]+=1
        if 0<=pv<8 and 0<=wt<8: mat[pv][wt]+=1
    prev_wt[cid]=wt
    if wt in RAINY: rainy_n[cid]+=1
    if wt in DRYY: dryy_n[cid]+=1
    pn[cid]+=1; psum[cid]+=p; psq[cid]+=p*p; water_of[cid]=w
    if w!=1 and 0<=wt<8:
        bi=min(9,max(0,int(fv(r[LAT])*10))); band_type[bi][wt]+=1
ncells=maxcell+1; nticks=len(ticks)
def q(a,pp):
    if not a: return float('nan')
    a=sorted(a); return a[min(len(a)-1,int(pp*len(a)))]
gt=sum(gwt.values())
print('rows=%d cells=%d ticks=%d'%(rows,ncells,nticks))
print('\n=== cloud/precip/vapor (sampled) ===')
print('  cloud  p10=%.3f p50=%.3f p90=%.3f'%(q(clouds,.1),q(clouds,.5),q(clouds,.9)))
print('  precip p10=%.4f p50=%.4f p90=%.4f'%(q(precs,.1),q(precs,.5),q(precs,.9)))
print('  vapor  p10=%.3f p50=%.3f p90=%.3f'%(q(vaps,.1),q(vaps,.5),q(vaps,.9)))
print('\n=== GLOBAL weather_type ===')
for w in sorted(gwt,key=lambda k:-gwt[k]):
    print('  %-9s %6.2f%%'%(NAMES.get(w,w),100.0*gwt[w]/gt))
buckets={'0':0,'1-5':0,'6-20':0,'21-100':0,'>100':0}
perma_rain=perma_dry=pstd_small=cnt=tr_sum=0
for c in range(ncells):
    if pn[c]<5: continue
    cnt+=1; tr=trans[c]; tr_sum+=tr
    if tr==0: buckets['0']+=1
    elif tr<=5: buckets['1-5']+=1
    elif tr<=20: buckets['6-20']+=1
    elif tr<=100: buckets['21-100']+=1
    else: buckets['>100']+=1
    if rainy_n[c]>0.9*pn[c]: perma_rain+=1
    if dryy_n[c]>0.9*pn[c]: perma_dry+=1
    m=psum[c]/pn[c]; sd=math.sqrt(max(0.0,psq[c]/pn[c]-m*m))
    if sd<0.006: pstd_small+=1
print('\n=== TIME continuity (transitions/cell over %d ticks) ==='%nticks)
for k in ['0','1-5','6-20','21-100','>100']:
    print('  %-7s: %5.1f%%'%(k,100.0*buckets[k]/max(1,cnt)))
print('  avg transitions/cell=%.1f  (0=恒定不变; 高=频繁横跳)'%(tr_sum/max(1,cnt)))
print('\n=== SPATIAL extremes ===')
print('  永雨(>90%% RAIN/STORM/BLIZ/MONSOON): %5.1f%%'%(100.0*perma_rain/max(1,cnt)))
print('  永旱(>90%% CLEAR/DROUGHT):           %5.1f%%'%(100.0*perma_dry/max(1,cnt)))
print('  precip 时间std<0.006 (近恒定格):      %5.1f%%'%(100.0*pstd_small/max(1,cnt)))
tot=sum(sum(row) for row in mat)
pairs=[(mat[a][b],a,b) for a in range(8) for b in range(8) if a!=b and mat[a][b]>0]
pairs.sort(reverse=True)
print('\n=== TOP transitions A->B (total=%d) ==='%tot)
for c,a,b in pairs[:12]:
    print('  %-8s -> %-8s %7d (%.1f%%)'%(NAMES[a],NAMES[b],c,100.0*c/max(1,tot)))
print('\n=== 纬度带 × 主导类型 (仅陆地; lat 0.0=地图顶 .. 1.0=底) ===')
for i in range(10):
    row=band_type[i]; s=sum(row)
    if s==0: continue
    top=sorted(range(8),key=lambda k:-row[k])[:3]
    desc='  '.join('%s=%.0f%%'%(NAMES[t],100.0*row[t]/s) for t in top if row[t]>0)
    print('  lat[%.1f-%.1f] %s'%(i/10.0,(i+1)/10.0,desc))
