import csv, sys
PATH = sys.argv[1] if len(sys.argv)>1 else r'Project.Keynes/tmp/tile_data_record_20260619_202707.csv'
C={'t148':148,'ctemp':165,'air':171,'cloud':161,'precip':163,'vapor':167,'inst':169,'tta':193,'lat':211,'wt':220,'is_water':223,'commit':None}
WT={0:'CLEAR',1:'RAIN',2:'STORM',3:'BLIZZARD',4:'DROUGHT',5:'FOG',6:'HEATWAVE',7:'MONSOON'}
def fv(s):
    try: return float(s)
    except: return 0.0
def iv(s):
    try: return int(float(s))
    except: return -1
COLD=True; MARG=0.03
def classify(season,t,vp,cl,pr,ins,oa,lat_signed):
    la=abs(lat_signed); ns=0.5
    if season==1: ns=1.0
    elif season==3: ns=0.0
    ls_=ns if lat_signed<0 else (1.0-ns)
    warm=t>0.55; humid=vp>0.28
    mean=pr>0.030 or (pr>0.022 and cl>0.22 and vp>0.28)
    if COLD and mean and (t<=0.24 or (t<0.31+MARG and cl>0.18 and vp>0.20 and pr>0.04)): return 3
    spg=0.068+(0.056-0.068)*ls_; sig=0.56+(0.50-0.56)*ls_
    woc=oa>0.12 and ins>0.70 and pr>0.07 and cl>0.28
    if warm and humid and la<0.70 and ((ins>sig and pr>spg) or woc): return 2
    if warm and humid and la<0.42 and ls_>0.5 and pr>0.055: return 7
    if mean: return 1
    if vp>0.34 and cl>0.14 and pr<0.030 and t<0.55: return 5
    if t>0.70 and cl<0.30 and pr<0.025 and la<0.62 and ls_>0.35: return 6
    if cl<0.22 and pr<0.020 and t>0.48 and vp<0.34: return 4
    return 0
from collections import Counter
conf=Counter()
n=0
for tempcol,label in [(165,'col165(TR)'),(148,'col148(cell_temp)')]:
    conf=Counter(); n=0
    with open(PATH,encoding='utf-8-sig',newline='') as f:
        rd=csv.reader(f); next(rd)
        for row in rd:
            if len(row)<=C['is_water']: continue
            n+=1
            t=fv(row[tempcol]); vp=fv(row[C['vapor']]); cl=fv(row[C['cloud']])
            pr=fv(row[C['precip']]); ins=fv(row[C['inst']]); oa=fv(row[C['tta']])
            norm=fv(row[C['lat']]); ls=2*norm-1
            pred=classify(2,t,vp,cl,pr,ins,oa,ls)
            rec=iv(row[C['wt']])
            conf[(pred,rec)]+=1
    print(f"\n=== confusion with temp={label}  (rows={n}) ===")
    preds=sorted(set(p for p,_ in conf))
    recs=sorted(set(r for _,r in conf))
    hdr='pred\\rec '+' '.join(f"{WT[r][:5]:>7}" for r in recs)
    print(hdr)
    for p in preds:
        line=f"{WT[p][:8]:8s} "+' '.join(f"{100.0*conf.get((p,r),0)/n:6.2f}%" for r in recs)
        print(line)
    # specifically: predicted STORM -> recorded as?
    ps=sum(v for (p,r),v in conf.items() if p==2)
    if ps>0:
        dist={WT[r]:f"{100.0*sum(v for (p,rr),v in conf.items() if p==2 and rr==r)/ps:.1f}%" for r in recs}
        print(f"  predicted STORM ({100.0*ps/n:.1f}% of all) actually recorded as: {dist}")
