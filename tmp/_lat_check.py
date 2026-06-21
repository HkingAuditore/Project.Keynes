import csv, sys
PATH = sys.argv[1] if len(sys.argv)>1 else r'Project.Keynes/tmp/tile_data_record_20260619_202707.csv'
C={'ctemp':165,'cloud':161,'precip':163,'vapor':167,'inst':169,'tta':193,
   'posx':209,'posy':210,'lat':211,'wt':220,'is_water':223}
WT={0:'CLEAR',1:'RAIN',2:'STORM',3:'BLIZZARD',4:'DROUGHT',5:'FOG',6:'HEATWAVE',7:'MONSOON'}
def fv(s):
    try: return float(s)
    except: return 0.0
def iv(s):
    try: return int(float(s))
    except: return -1

rows=[]
posys=[]
with open(PATH,encoding='utf-8-sig',newline='') as f:
    rd=csv.reader(f); next(rd)
    for row in rd:
        if len(row)<=C['is_water']: continue
        posy=fv(row[C['posy']]); latn=fv(row[C['lat']])
        rows.append((fv(row[C['ctemp']]),fv(row[C['vapor']]),fv(row[C['cloud']]),
                     fv(row[C['precip']]),fv(row[C['inst']]),fv(row[C['tta']]),
                     posy,latn,iv(row[C['wt']])))
        posys.append(posy)
n=len(rows)
ymin=min(posys); ymax=max(posys)
print(f"rows={n}  cell_pos_y range=[{ymin:.2f},{ymax:.2f}]")

# correlation posy_norm vs cell_lat_norm
import statistics
posn=[(p-ymin)/(ymax-ymin) if ymax>ymin else 0.0 for p in posys]
latn=[r[7] for r in rows]
mp=statistics.fmean(posn); ml=statistics.fmean(latn)
cov=sum((a-mp)*(b-ml) for a,b in zip(posn,latn))/n
sp=statistics.pstdev(posn); sl=statistics.pstdev(latn)
corr=cov/(sp*sl) if sp>0 and sl>0 else 0.0
print(f"corr(posy_norm, cell_lat_norm) = {corr:.3f}")
# for equatorial-by-latnorm cells, what is posy_norm?
eq=[pn for pn,(*_,ln,__) in zip(posn,rows) if 0.45<=ln<=0.55]
def q(a,p):
    if not a: return float('nan')
    a=sorted(a); return a[min(len(a)-1,int(p/100*len(a)))]
print(f"cells equatorial by cell_lat_norm(0.45-0.55): n={len(eq)}  their posy_norm p5/50/95 = {q(eq,5):.3f}/{q(eq,50):.3f}/{q(eq,95):.3f}")

COLD=True; MARG=0.03
def classify(season, t,vp,cl,pr,ins,oa, lat_signed):
    la=abs(lat_signed)
    ns=0.5
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

for name, latfn in [
    ('lat from cell_lat_norm(col211)', lambda posy,latn,pn: latn*2-1),
    ('lat from pos_y_norm(min/max)',   lambda posy,latn,pn: pn*2-1),
]:
    rep={}; agree=0
    for (t,vp,cl,pr,ins,oa,posy,latnv,rec),pn in zip(rows,posn):
        ls=latfn(posy,latnv,pn)
        w=classify(2,t,vp,cl,pr,ins,oa,ls)
        rep[w]=rep.get(w,0)+1
        if w==rec: agree+=1
    print(f"{name:34s}: agree={100.0*agree/n:.1f}%  STORM={100.0*rep.get(2,0)/n:.2f}%  MONSOON={100.0*rep.get(7,0)/n:.2f}%  HEATWAVE={100.0*rep.get(6,0)/n:.2f}%")
