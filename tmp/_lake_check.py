import csv, sys
from collections import Counter
PATH = sys.argv[1] if len(sys.argv)>1 else r'Project.Keynes/tmp/tile_data_record_20260619_230533.csv'
C={'cloud':161,'precip':163,'ctemp':165,'vapor':167,'inst':169,'tta':193,
   'hasriver':172,'terr':213,'lat':211,'wt':220,'iswater':223}
WT={0:'CLEAR',1:'RAIN',2:'STORM',3:'BLIZZARD',4:'DROUGHT',5:'FOG',6:'HEATWAVE',7:'MONSOON'}
OCEAN,COAST,LAKE=0,1,18
def fv(s):
    try: return float(s)
    except: return 0.0
def iv(s):
    try: return int(float(s))
    except: return -1
def q(a,p):
    if not a: return float('nan')
    a=sorted(a); return a[min(len(a)-1,int(p/100*len(a)))]

groups={'OCEAN':[],'COAST':[],'LAKE':[],'RIVER(land)':[],'LAND(dry)':[]}
wt_all=Counter(); wt_by={k:Counter() for k in groups}
# per-group field accumulators for LAKE
lake={'precip':[],'vapor':[],'cloud':[],'inst':[],'temp':[],'lat':[],'tta':[]}
ticks=set()
n=0
with open(PATH,encoding='utf-8-sig',newline='') as f:
    rd=csv.reader(f); next(rd)
    for row in rd:
        if len(row)<=C['iswater']: continue
        n+=1
        terr=iv(row[C['terr']]); wt=iv(row[C['wt']]); hasriver=iv(row[C['hasriver']])
        wt_all[wt]+=1
        if terr==OCEAN: g='OCEAN'
        elif terr==COAST: g='COAST'
        elif terr==LAKE: g='LAKE'
        elif hasriver==1: g='RIVER(land)'
        else: g='LAND(dry)'
        groups[g].append(1)
        wt_by[g][wt]+=1
        if g=='LAKE':
            lake['precip'].append(fv(row[C['precip']])); lake['vapor'].append(fv(row[C['vapor']]))
            lake['cloud'].append(fv(row[C['cloud']])); lake['inst'].append(fv(row[C['inst']]))
            lake['temp'].append(fv(row[C['ctemp']])); lake['tta'].append(fv(row[C['tta']]))
            norm=fv(row[C['lat']]); lake['lat'].append(abs(2*norm-1))

def dist(c):
    t=sum(c.values())
    return ', '.join(f"{WT[k]} {100.0*v/t:.1f}%" for k,v in c.most_common()) if t else '(none)'
print(f"rows={n}")
print(f"\n=== overall === {dist(wt_all)}")
for g in groups:
    cnt=sum(groups[g])
    print(f"\n=== {g} (n={cnt}, {100.0*cnt/n:.1f}% of all) ===\n  {dist(wt_by[g])}")
print(f"\n=== LAKE field distributions (p5/50/95) ===")
for k in ['temp','vapor','cloud','precip','inst','tta','lat']:
    a=lake[k]
    print(f"  {k:7s}: {q(a,5):.3f} / {q(a,50):.3f} / {q(a,95):.3f}")
# storm gate check on lakes (autumn mid gates)
ls=lake
ns=len(ls['precip'])
if ns:
    warm=sum(1 for t in ls['temp'] if t>0.55); humid=sum(1 for v in ls['vapor'] if v>0.28)
    lowlat=sum(1 for l in ls['lat'] if l<0.70)
    instok=sum(1 for x in ls['inst'] if x>0.53); precok=sum(1 for p in ls['precip'] if p>0.062)
    print(f"\n=== LAKE storm-gate pass rates ===")
    print(f"  warm>0.55={100.0*warm/ns:.1f}%  humid>0.28={100.0*humid/ns:.1f}%  lat<0.70={100.0*lowlat/ns:.1f}%  inst>0.53={100.0*instok/ns:.1f}%  precip>0.062={100.0*precok/ns:.1f}%")
