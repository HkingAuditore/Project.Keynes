import csv, sys
from collections import defaultdict
PATH=sys.argv[1] if len(sys.argv)>1 else r'Project.Keynes/tmp/tile_data_record_20260620_013108.csv'
NAMES={0:'CLEAR',1:'RAIN',2:'STORM',3:'BLIZZARD',4:'DROUGHT',5:'FOG',6:'HEATWAVE',7:'MONSOON'}
C={'tick':1,'wt':220,'lat':211,'water':223,'precip':163,'temp':165}
def fv(s):
    try:return float(s)
    except:return 0.0
def iv(s):
    try:return int(float(s))
    except:return -1
ticks=set()
gcount=defaultdict(int); gtot=0
NB=40
band_wt=[defaultdict(int) for _ in range(NB)]
band_tot=[0]*NB
band_precip=[0.0]*NB; band_precip_n=[0]*NB
maxc=max(C.values())
f=open(PATH,encoding='utf-8-sig',newline='')
rd=csv.reader(f); next(rd); row=0
for r in rd:
    if len(r)<=maxc: continue
    row+=1
    ticks.add(r[C['tick']])
    if row%3: continue
    w=iv(r[C['wt']])
    if w<0: continue
    ln=fv(r[C['lat']]); ln=min(0.99999,max(0.0,ln))
    b=int(ln*NB)
    gcount[w]+=1; gtot+=1
    band_wt[b][w]+=1; band_tot[b]+=1
    p=fv(r[C['precip']]); band_precip[b]+=p; band_precip_n[b]+=1
print('ticks=%d  rows=%d  sampled=%d'%(len(ticks),row,gtot))
print('\n=== GLOBAL weather_type distribution ===')
for w in sorted(gcount,key=lambda k:-gcount[k]):
    print('  %-9s %6.2f%%'%(NAMES.get(w,w),100.0*gcount[w]/gtot))
print('\n=== per latitude band (lat_norm 0=N pole .. 1=S pole), %% of each type + mean precip ===')
print('  band  latN   lat_abs  n      CLEAR  RAIN  STORM  BLIZ  DRGHT  FOG   HEAT  MONS  | precip')
for b in range(NB):
    if band_tot[b]==0: continue
    latN=(b+0.5)/NB; lat_abs=abs(latN*2-1)
    d=band_wt[b]; t=band_tot[b]
    def pc(w): return 100.0*d.get(w,0)/t
    mp=band_precip[b]/max(1,band_precip_n[b])
    print('  %3d  %.3f  %.3f  %6d  %5.1f %5.1f %5.1f %5.1f %5.1f %5.1f %5.1f %5.1f | %.4f'%(
        b,latN,lat_abs,t,pc(0),pc(1),pc(2),pc(3),pc(4),pc(5),pc(6),pc(7),mp))
