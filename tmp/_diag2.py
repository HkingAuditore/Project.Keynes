import csv, sys, math
from collections import defaultdict
PATH=sys.argv[1] if len(sys.argv)>1 else r'Project.Keynes/tmp/tile_data_record_20260620_013108.csv'
def fv(s):
    try:return float(s)
    except:return 0.0
def iv(s):
    try:return int(float(s))
    except:return -1
f=open(PATH,encoding='utf-8-sig',newline='')
rd=csv.reader(f); h=next(rd)
print('cols0-5:', [(i,h[i]) for i in range(6)])
C={'tick':1,'lat':211,'tempc':165,'cloud':161,'precip':163,'vapor':167,'anom':157,'inst':169,'wt':220,'water':223}
# pick the LAST tick only, for clean same-time meridional spread
last_tick=None
f2=open(PATH,encoding='utf-8-sig',newline=''); rd2=csv.reader(f2); next(rd2)
for r in rd2:
    if len(r)>C['tick']: last_tick=r[C['tick']]
print('last_tick=',last_tick)
NB=24
band_temp=[[] for _ in range(NB)]
hw_cand=0; hw_anom=[]; hw_pass=0
mons_cand=0; mons_pass=0
heat_relaxed=0  # temp>0.62 & cloud<0.40 & precip<0.03 (no anom, no lat)
f=open(PATH,encoding='utf-8-sig',newline='')
rd=csv.reader(f); next(rd); row=0
for r in rd:
    if len(r)<=220: continue
    if r[C['tick']]!=last_tick: continue
    row+=1
    ln=fv(r[C['lat']]); b=int(min(.9999,max(0,ln))*NB)
    lat_abs=abs(ln*2-1)
    tc=fv(r[C['tempc']]); cl=fv(r[C['cloud']]); pp=fv(r[C['precip']]); an=fv(r[C['anom']]); vp=fv(r[C['vapor']])
    band_temp[b].append(tc)
    if tc>0.66 and cl<0.35 and pp<0.025 and lat_abs<0.62:
        hw_cand+=1; hw_anom.append(an)
        if an>0.04: hw_pass+=1
    if tc>0.62 and cl<0.40 and pp<0.03:
        heat_relaxed+=1
    if tc>0.55 and lat_abs<0.45 and vp>0.40 and pp>0.055 and cl>0.45:
        mons_pass+=1
def std(a):
    if len(a)<2: return 0.0
    m=sum(a)/len(a); return math.sqrt(sum((x-m)**2 for x in a)/len(a))
def q(a,p):
    if not a:return float('nan')
    a=sorted(a);return a[min(len(a)-1,int(p*len(a)))]
print('last-tick rows=%d'%row)
print('\n=== same-time meridional spread: temp std WITHIN each lat band ===')
print('(small std → temperature is nearly constant along a parallel → classification becomes horizontal bands)')
for b in range(NB):
    if not band_temp[b]: continue
    latN=(b+0.5)/NB
    a=band_temp[b]
    print('  band %2d latN=%.3f  n=%5d  temp mean=%.3f  std=%.4f  min=%.3f max=%.3f'%(
        b,latN,len(a),sum(a)/len(a),std(a),min(a),max(a)))
print('\n=== HEATWAVE diagnosis (last tick) ===')
print('  candidates [temp>0.66 & cloud<0.35 & precip<0.025 & lat_abs<0.62]: %d'%hw_cand)
if hw_anom:
    print('    their temp_anom: p50=%.3f p90=%.3f p99=%.3f  max=%.3f'%(q(hw_anom,.5),q(hw_anom,.9),q(hw_anom,.99),max(hw_anom)))
    print('    pass anom>0.04 → HEATWAVE: %d (%.1f%% of candidates)'%(hw_pass,100.0*hw_pass/max(1,hw_cand)))
print('  relaxed heat-ish [temp>0.62 & cloud<0.40 & precip<0.03]: %d'%heat_relaxed)
print('\n=== MONSOON pass (last tick) [temp>0.55 & lat_abs<0.45 & vapor>0.40 & precip>0.055 & cloud>0.45]: %d'%mons_pass)
