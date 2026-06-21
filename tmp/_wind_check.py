import csv, sys
from collections import defaultdict
PATH = sys.argv[1] if len(sys.argv)>1 else r'Project.Keynes/tmp/tile_data_record_20260620_002413.csv'
C={'tick':1,'cell':144,'temp':148,'wtemp':165,'conv':168,'windx':202,'windy':203,'slp':204,'wspd':205,
   'windd_p95':118,'dailyd_p95':134,'slpd_p95':110}
def fv(s):
    try: return float(s)
    except: return 0.0
def iv(s):
    try: return int(float(s))
    except: return -1

FIELDS=['temp','wtemp','conv','windx','windy','slp','wspd']
mn=defaultdict(lambda:[9e9]*len(FIELDS))
mx=defaultdict(lambda:[-9e9]*len(FIELDS))
per_tick={}
with open(PATH,encoding='utf-8-sig',newline='') as f:
    rd=csv.reader(f); next(rd)
    for r in rd:
        if len(r)<=C['slp']: continue
        c=iv(r[C['cell']]); t=iv(r[C['tick']])
        vals=[fv(r[C[k]]) for k in FIELDS]
        a=mn[c]; b=mx[c]
        for k in range(len(FIELDS)):
            if vals[k]<a[k]: a[k]=vals[k]
            if vals[k]>b[k]: b[k]=vals[k]
        if t not in per_tick:
            per_tick[t]=(fv(r[C['windd_p95']]),fv(r[C['dailyd_p95']]),fv(r[C['slpd_p95']]))

cells=list(mn); N=len(cells)
def q(arr,p):
    arr=sorted(arr); return arr[min(len(arr)-1,int(p*len(arr)))]
print(f"cells={N}")
print("=== per-cell temporal RANGE (max-min over ticks) ===")
for k,name in enumerate(FIELDS):
    rng=[mx[c][k]-mn[c][k] for c in cells]
    nz=sum(1 for x in rng if x>1e-6)
    print(f"  {name:7s}: p50={q(rng,.5):.5f} p90={q(rng,.9):.5f} p99={q(rng,.99):.5f}  | varies(>1e-6): {100.0*nz/N:.1f}%")

ts=sorted(per_tick)
print("\n=== per-tick wind/slp DELTA p95 (how much field changed that update) ===")
vals_w=[per_tick[t][0] for t in ts]; vals_d=[per_tick[t][1] for t in ts]; vals_s=[per_tick[t][2] for t in ts]
print(f"  phys_wind_delta_p95:      min={min(vals_w):.5f} median={sorted(vals_w)[len(vals_w)//2]:.5f} max={max(vals_w):.5f}")
print(f"  phys_daily_wind_delta_p95:min={min(vals_d):.5f} median={sorted(vals_d)[len(vals_d)//2]:.5f} max={max(vals_d):.5f}")
print(f"  phys_slp_delta_p95:       min={min(vals_s):.5f} median={sorted(vals_s)[len(vals_s)//2]:.5f} max={max(vals_s):.5f}")
print("  sample (first 12 ticks): "+', '.join(f"{per_tick[t][0]:.3f}" for t in ts[:12]))
