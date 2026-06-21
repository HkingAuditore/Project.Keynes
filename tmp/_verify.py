import csv, sys
from collections import defaultdict
PATH = sys.argv[1] if len(sys.argv)>1 else r'Project.Keynes/tmp/tile_data_record_20260620_004323.csv'
f=open(PATH,encoding='utf-8-sig',newline='')
rd=csv.reader(f); h=next(rd)
ci={n:i for i,n in enumerate(h)}
def col(name): return ci.get(name,-1)
# weather type column: fuzzy
wt=-1
for cand in ('weather_type','weather_type_arr','field_weather_type_arr','classified_weather_type'):
    if cand in ci: wt=ci[cand]; break
if wt<0:
    for n,i in ci.items():
        if 'weather' in n.lower() and 'type' in n.lower(): wt=i; break
TRACK=['temp_arr','temp_arr_prev','moisture_arr','moisture_arr_prev',
       'weather_classification_temp_arr','weather_classification_moisture_arr']
idx=[col(c) for c in TRACK]
C_cell=col('cell_index'); C_tick=col('tick_idx')
print('weather_type col:', h[wt] if wt>=0 else 'NOT FOUND', '(idx',wt,')')
print('tracked cols idx:', dict(zip(TRACK,idx)))
def fv(s):
    try: return float(s)
    except: return 0.0
mn=defaultdict(lambda:[9e9]*len(idx)); mx=defaultdict(lambda:[-9e9]*len(idx))
wt_set=defaultdict(set)         # cell -> set of weather types
wt_rain=defaultdict(lambda:[0,0])  # cell -> [rain_ticks, total_ticks]
RAINY={'RAIN','STORM','MONSOON','DRIZZLE','SNOW','BLIZZARD','SLEET','THUNDER','THUNDERSTORM'}
maxc=max(idx+[C_cell,C_tick,wt])
nrows=0
for r in rd:
    if len(r)<=maxc: continue
    nrows+=1
    try: c=int(float(r[C_cell]))
    except: continue
    a=mn[c]; b=mx[c]
    for k,j in enumerate(idx):
        v=fv(r[j])
        if v<a[k]: a[k]=v
        if v>b[k]: b[k]=v
    if wt>=0:
        w=r[wt].strip().upper()
        wt_set[c].add(w)
        tot=wt_rain[c]; tot[1]+=1
        if any(t in w for t in RAINY): tot[0]+=1
cells=list(mn); N=len(cells)
def q(arr,p):
    arr=sorted(arr); return arr[min(len(arr)-1,int(p*len(arr)))]
print(f'\nrows={nrows} cells={N}')
print('=== [FIX VERIFY] temporal range of _prev buffers (was 0.0 = frozen) ===')
for k,name in enumerate(TRACK):
    rng=[mx[c][k]-mn[c][k] for c in cells if mx[c][k]>-9e8]
    nz=sum(1 for x in rng if x>1e-6)
    print(f'  {name:38s}: p50={q(rng,.5):.5f} p90={q(rng,.9):.5f} varies={100.0*nz/N:.1f}%')
if wt>=0:
    dist=defaultdict(int)
    for c in cells: dist[len(wt_set[c])]+=1
    static=dist.get(1,0)
    print('\n=== weather TYPE temporal variation ===')
    for k in sorted(dist): print(f'  {k} type(s): {dist[k]} cells ({100.0*dist[k]/N:.1f}%)')
    print(f'  -> FULLY STATIC: {100.0*static/N:.1f}%')
    never=sum(1 for c in cells if wt_rain[c][0]==0)
    always=sum(1 for c in cells if wt_rain[c][0]==wt_rain[c][1] and wt_rain[c][1]>0)
    print(f'  never rain (always dry): {100.0*never/N:.1f}%   always rain: {100.0*always/N:.1f}%')
