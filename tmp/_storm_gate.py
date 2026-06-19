import csv, sys
PATH = sys.argv[1] if len(sys.argv)>1 else r'Project.Keynes/tmp/tile_data_record_20260619_202707.csv'
C = {'ctemp':165,'cloud':161,'precip':163,'vapor':167,'conv':168,'inst':169,
     'tta':193,'lat':211,'terrain':213,'wt':220,'is_water':223}
def fv(s):
    try: return float(s)
    except: return 0.0
def iv(s):
    try: return int(float(s))
    except: return -1
def meaningful(p,cl,vp): return p>0.030 or (p>0.022 and cl>0.22 and vp>0.28)

# STORM gates (mid-season approximation): inst>0.53, precip>0.062, warm temp>0.55, humid vapor>0.28, lat_abs<0.70
gate_names=['warm(temp>0.55)','humid(vapor>0.28)','lat_abs<0.70','inst>0.53','precip>0.062']
def gates(temp,vapor,lat_abs,inst,precip):
    return [temp>0.55, vapor>0.28, lat_abs<0.70, inst>0.53, precip>0.062]

tot_precip=0; pass_all=0
pass_each=[0]*5
# among meaningful-precip cells: how many fail ONLY because of gate k (all others pass)
only_fail=[0]*5
temps=[]; vaps=[]; lats=[]
n=0
with open(PATH,encoding='utf-8-sig',newline='') as f:
    rd=csv.reader(f); next(rd)
    for row in rd:
        if len(row)<=C['is_water']: continue
        n+=1
        temp=fv(row[C['ctemp']]); cloud=fv(row[C['cloud']]); precip=fv(row[C['precip']])
        vapor=fv(row[C['vapor']]); inst=fv(row[C['inst']]); tta=fv(row[C['tta']])
        norm=fv(row[C['lat']]); lat_abs=abs(2.0*norm-1.0)
        if not meaningful(precip,cloud,vapor): continue
        tot_precip+=1
        g=gates(temp,vapor,lat_abs,inst,precip)
        for k in range(5):
            if g[k]: pass_each[k]+=1
        if all(g): pass_all+=1
        else:
            fails=[k for k in range(5) if not g[k]]
            if len(fails)==1: only_fail[fails[0]]+=1
        temps.append(temp); vaps.append(vapor); lats.append(lat_abs)

def pctl(a,ps=(5,25,50,75,95)):
    if not a: return 'n/a'
    a=sorted(a)
    return ' '.join(f"p{p}={a[min(len(a)-1,int(p/100*len(a)))]:.3f}" for p in ps)

print(f"total cells={n}, cells with meaningful_precip (RAIN pool)={tot_precip}")
print(f"would-be STORM (all gates pass, mid-season approx) = {pass_all} ({100.0*pass_all/max(tot_precip,1):.1f}% of RAIN pool, {100.0*pass_all/max(n,1):.1f}% of all)\n")
print("per-gate PASS rate within RAIN pool:")
for k in range(5):
    print(f"  {gate_names[k]:20s}: {100.0*pass_each[k]/max(tot_precip,1):.1f}%   (sole blocker for {100.0*only_fail[k]/max(tot_precip,1):.1f}% of RAIN pool)")
print()
print("RAIN-pool field distributions:")
print("  classification temp:", pctl(temps))
print("  vapor              :", pctl(vaps))
print("  lat_abs            :", pctl(lats))
