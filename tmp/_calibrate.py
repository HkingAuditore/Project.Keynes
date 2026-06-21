import csv, sys
from collections import defaultdict
PATH = sys.argv[1] if len(sys.argv)>1 else r'Project.Keynes/tmp/tile_data_record_20260620_004323.csv'
NAMES={0:'CLEAR',1:'RAIN',2:'STORM',3:'BLIZZARD',4:'DROUGHT',5:'FOG',6:'HEATWAVE',7:'MONSOON'}
C={'wt':220,'lat':211,'water':223,'temp':165,'vapor':167,'cloud':161,'precip':163,'inst':169,'anom':171,'wind':205}
METRICS=['temp','vapor','cloud','precip','inst','anom','wind']
def fv(s):
    try: return float(s)
    except: return 0.0
def iv(s):
    try: return int(float(s))
    except: return -1
glob={m:[] for m in METRICS}
bywt=defaultdict(lambda:{m:[] for m in METRICS})
CAP=120000
f=open(PATH,encoding='utf-8-sig',newline='')
rd=csv.reader(f); next(rd)
maxc=max(C.values())
row=0
for r in rd:
    if len(r)<=maxc: continue
    row+=1
    if row % 4 != 0: continue          # uniform 1/4 subsample
    w=iv(r[C['wt']])
    if w<0: continue
    for m in METRICS:
        v=fv(r[C[m]])
        if len(glob[m])<CAP*4: glob[m].append(v)
        if len(bywt[w][m])<CAP: bywt[w][m].append(v)
def q(a,p):
    if not a: return float('nan')
    a=sorted(a); return a[min(len(a)-1,int(p*len(a)))]
print('=== GLOBAL physics quantiles (p10/p50/p90) ===')
for m in METRICS:
    a=glob[m]; print(f'  {m:6s}: p10={q(a,.1):+.3f}  p50={q(a,.5):+.3f}  p90={q(a,.9):+.3f}')
print('\n=== per weather_type: median of each metric (n=sample) ===')
print(f'  {"TYPE":9s} {"n":>7s}  '+'  '.join(f'{m:>6s}' for m in METRICS))
for w in sorted(bywt):
    d=bywt[w]; n=len(d['temp'])
    print(f'  {NAMES.get(w,w):9s} {n:7d}  '+'  '.join(f'{q(d[m],.5):+6.3f}' for m in METRICS))
print('\n=== KEY: BLIZZARD vs RAIN  temp & wind (for snow gate) ===')
for w in (3,1):
    d=bywt[w]
    print(f'  {NAMES[w]:9s} temp[p10/50/90]={q(d["temp"],.1):.3f}/{q(d["temp"],.5):.3f}/{q(d["temp"],.9):.3f}  '
          f'wind[p10/50/90]={q(d["wind"],.1):.3f}/{q(d["wind"],.5):.3f}/{q(d["wind"],.9):.3f}')
print('\n=== KEY: air_mass_temp_anomaly distribution (for heatwave gate) ===')
a=glob['anom']
print(f'  global anom p50={q(a,.5):+.3f} p90={q(a,.9):+.3f} p95={q(a,.95):+.3f} p99={q(a,.99):+.3f}')
for w in (0,4,6):
    d=bywt[w]['anom']
    if d: print(f'  {NAMES[w]:9s} anom p50={q(d,.5):+.3f} p90={q(d,.9):+.3f}')
