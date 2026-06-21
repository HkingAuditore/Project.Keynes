import csv, sys
from collections import defaultdict
PATH = sys.argv[1] if len(sys.argv)>1 else r'Project.Keynes/tmp/tile_data_record_20260619_234914.csv'
C={'tick':1,'cell':144,'cloud':161,'precip':163,'ctemp':165,'vapor':167,'inst':169,'terr':213,'wt':220}
WT={0:'CLEAR',1:'RAIN',2:'STORM',3:'BLIZZARD',4:'DROUGHT',5:'FOG',6:'HEATWAVE',7:'MONSOON'}
def fv(s):
    try: return float(s)
    except: return 0.0
def iv(s):
    try: return int(float(s))
    except: return -1

# per-cell min/max of field values + wt set + tick count
mn=defaultdict(lambda:[9,9,9,9,9])   # precip,vapor,cloud,inst,temp mins
mx=defaultdict(lambda:[-9,-9,-9,-9,-9])
wtset=defaultdict(set)
terr={}
cnt=defaultdict(int)
FI=['precip','vapor','cloud','inst','ctemp']
with open(PATH,encoding='utf-8-sig',newline='') as f:
    rd=csv.reader(f); next(rd)
    for r in rd:
        if len(r)<=C['terr']: continue
        c=iv(r[C['cell']])
        vals=[fv(r[C['precip']]),fv(r[C['vapor']]),fv(r[C['cloud']]),fv(r[C['inst']]),fv(r[C['ctemp']])]
        a=mn[c]; b=mx[c]
        for k in range(5):
            if vals[k]<a[k]: a[k]=vals[k]
            if vals[k]>b[k]: b[k]=vals[k]
        wtset[c].add(iv(r[C['wt']]))
        if c not in terr: terr[c]=iv(r[C['terr']])
        cnt[c]+=1

cells=list(mn)
N=len(cells)
print(f"cells={N}")
# range distribution per field
import statistics
def summarize(idx,name,thresh):
    ranges=[mx[c][idx]-mn[c][idx] for c in cells]
    ranges.sort()
    p=lambda q: ranges[min(N-1,int(q*N))]
    static=sum(1 for x in ranges if x<thresh)
    print(f"  {name:7s} temporal range  p10={p(.10):.4f} p50={p(.50):.4f} p90={p(.90):.4f} p99={p(.99):.4f}  | range<{thresh}: {100.0*static/N:.1f}% (near-static)")
print("=== per-cell temporal RANGE (max-min over 249 ticks) of underlying field values ===")
summarize(0,'precip',0.015)
summarize(1,'vapor',0.03)
summarize(2,'cloud',0.05)
summarize(3,'inst',0.05)
summarize(4,'temp',0.03)

# cross-tab: cells static in TYPE but how much precip varies?
n_type_static=sum(1 for c in cells if len(wtset[c])==1)
# among type-static cells, precip range
prng_static=[mx[c][0]-mn[c][0] for c in cells if len(wtset[c])==1]
prng_dyn=[mx[c][0]-mn[c][0] for c in cells if len(wtset[c])>1]
def med(a): 
    a=sorted(a); return a[len(a)//2] if a else float('nan')
print(f"\n=== type-static vs type-dynamic cells ===")
print(f"  type-static cells: {n_type_static} ({100.0*n_type_static/N:.1f}%), their precip range median={med(prng_static):.4f}")
print(f"  type-dynamic cells: {N-n_type_static}, their precip range median={med(prng_dyn):.4f}")

# always-rain & never-rain regions: their precip range
PRE={1,2,3,7}
always=[c for c in cells if wtset[c]<=PRE]
never=[c for c in cells if not (wtset[c]&PRE)]
print(f"\n  ALWAYS-precip cells={len(always)} precip range median={med([mx[c][0]-mn[c][0] for c in always]):.4f}  precip min median={med([mn[c][0] for c in always]):.4f}")
print(f"  NEVER-precip cells={len(never)} precip range median={med([mx[c][0]-mn[c][0] for c in never]):.4f}  vapor max median={med([mx[c][1] for c in never]):.4f}")
