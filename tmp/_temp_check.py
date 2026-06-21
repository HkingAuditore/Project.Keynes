import csv, sys, statistics
PATH = sys.argv[1] if len(sys.argv)>1 else r'Project.Keynes/tmp/tile_data_record_20260619_202707.csv'
C={'t148':148,'ctemp':165,'air':171,'cloud':161,'precip':163,'vapor':167,'inst':169,'tta':193,'lat':211,'wt':220,'is_water':223}
def fv(s):
    try: return float(s)
    except: return 0.0
def iv(s):
    try: return int(float(s))
    except: return -1
def q(a,p):
    if not a: return float('nan')
    a=sorted(a); return a[min(len(a)-1,int(p/100*len(a)))]

# storm pool = my replay (col211 lat, col165 temp, recorded vapor/cloud/precip/inst) classifies STORM (autumn)
def is_storm(t,vp,cl,pr,ins,la):
    warm=t>0.55; humid=vp>0.28
    spg=0.062; sig=0.53  # autumn mid
    woc=ins>0.70 and pr>0.07 and cl>0.28  # (ocean_an omitted -> superset)
    return warm and humid and la<0.70 and ((ins>sig and pr>spg) or woc)

t165=[]; air=[]; t148=[]; sum_=[]; rec_in_pool={}
warm165=warm_sum=warm148=0; npool=0
# also global estimate of (t148 - t165) to gauge per-tick offset
glob_diff=[]
with open(PATH,encoding='utf-8-sig',newline='') as f:
    rd=csv.reader(f); next(rd)
    for row in rd:
        if len(row)<=C['is_water']: continue
        a=fv(row[C['ctemp']]); b=fv(row[C['air']]); c=fv(row[C['t148']])
        glob_diff.append(c-a)
        vp=fv(row[C['vapor']]); cl=fv(row[C['cloud']]); pr=fv(row[C['precip']]); ins=fv(row[C['inst']])
        norm=fv(row[C['lat']]); la=abs(2*norm-1)
        if not is_storm(a,vp,cl,pr,ins,la): continue
        npool+=1
        t165.append(a); air.append(b); t148.append(c); sum_.append(a+b)
        if a>0.55: warm165+=1
        if a+b>0.55: warm_sum+=1
        if c>0.55: warm148+=1
        rec=iv(row[C['wt']]); rec_in_pool[rec]=rec_in_pool.get(rec,0)+1

WT={0:'CLEAR',1:'RAIN',2:'STORM',3:'BLIZZARD',4:'DROUGHT',5:'FOG',6:'HEATWAVE',7:'MONSOON'}
print(f"would-be-STORM pool size = {npool}")
print(f"  TR/class_temp(col165) p5/50/95 = {q(t165,5):.3f}/{q(t165,50):.3f}/{q(t165,95):.3f}")
print(f"  air_anomaly(col171)   p5/50/95 = {q(air,5):.3f}/{q(air,50):.3f}/{q(air,95):.3f}")
print(f"  col165+air            p5/50/95 = {q(sum_,5):.3f}/{q(sum_,50):.3f}/{q(sum_,95):.3f}")
print(f"  cell_temp(col148)     p5/50/95 = {q(t148,5):.3f}/{q(t148,50):.3f}/{q(t148,95):.3f}")
print(f"  warm(>0.55): by col165={100.0*warm165/max(npool,1):.1f}%  by col165+air={100.0*warm_sum/max(npool,1):.1f}%  by col148={100.0*warm148/max(npool,1):.1f}%")
print(f"  what recorded wt are these pool cells? " + ', '.join(f"{WT[k]} {100.0*v/max(npool,1):.1f}%" for k,v in sorted(rec_in_pool.items(),key=lambda kv:-kv[1])))
print(f"global (col148 - col165) p5/50/95 = {q(glob_diff,5):.3f}/{q(glob_diff,50):.3f}/{q(glob_diff,95):.3f}  (gauge of temp drift+anomaly)")
