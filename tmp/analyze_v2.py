import csv, collections, statistics, sys
PATH = sys.argv[1] if len(sys.argv)>1 else r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260619_041728.csv"
SEA=0.42
allrows=[]
with open(PATH, newline="") as f:
    rd=csv.DictReader(f)
    for row in rd: allrows.append(row)
ci=[int(float(x["cell_index"])) for x in allrows]
ncells=max(ci)+1
starts=[i for i in range(len(allrows)) if ci[i]==0]
s0=starts[-1]; rows=allrows[s0:s0+ncells]; n=len(rows)
def fnum(s):
    try:return float(s)
    except:return 0.0
def col(nm): return [fnum(x[nm]) for x in rows]
def icol(nm): return [int(float(x[nm])) for x in rows]
q=icol("q"); rr=icol("r")
terr=icol("terrain_arr"); landf=icol("landform_arr"); veg=icol("vegetation_arr")
elev=col("elevation_arr"); temp=col("temp_arr"); moist=col("moisture_arr")
iw=icol("is_water_arr"); cidx=icol("cell_index")
disch=col("river_discharge_arr"); hasriver=icol("has_river_arr")
snow=col("snow_cover_arr"); seaice=col("sea_ice_frac_arr")
height=max(rr)+1; width=n//height
pos={cidx[i]:i for i in range(n)}
DQ=[1,1,0,-1,-1,0]; DR=[0,-1,-1,0,1,1]
def idx_qr(qq,rrr):
    c=qq+((rrr-(rrr&1))//2)
    if c<0 or c>=width or rrr<0 or rrr>=height: return -1
    return pos.get(rrr*width+c,-1)
NB=[[idx_qr(q[i]+DQ[d],rr[i]+DR[d]) for d in range(6)] for i in range(n)]
print(f"grid={width}x{height} tick={rows[0]['tick_idx']} land={sum(1 for x in iw if x==0)} water={sum(1 for x in iw if x)}")
def dist(a,name,topk=12):
    c=collections.Counter(a); tot=len(a)
    print(f"-- {name}: {len(c)} types: "+", ".join(f"{k}:{100*v/tot:.1f}%" for k,v in c.most_common(topk)))
dist(terr,"terrain"); dist(veg,"veg"); dist(landf,"landform")
def stats(a,nm,mask=None):
    vals=[a[i] for i in range(n) if (mask is None or mask(i))]; vals.sort()
    if not vals: print(f"   {nm}: none"); return
    p=lambda f:vals[min(len(vals)-1,int(f*len(vals)))]
    print(f"   {nm:22s} min={vals[0]:.3f} p10={p(.1):.3f} p50={p(.5):.3f} p90={p(.9):.3f} max={vals[-1]:.3f}")
land=lambda i: iw[i]==0
print("=== CLIMATE (land) ===")
stats(temp,"temp",land); stats(moist,"moisture",land); stats(elev,"elevation",land)
# moisture buckets (需求2 干旱占比)
mb=collections.Counter()
for i in range(n):
    if iw[i]==0:
        m=moist[i]
        mb["arid<0.15" if m<0.15 else "semi0.15-0.3" if m<0.3 else "sub0.3-0.5" if m<0.5 else "humid>0.5"]+=1
print("   moisture buckets(land):", dict(mb))
# LAKES by size class (需求1)
WATER={0,1,18,19,20,21}
seen=[False]*n; lakes=[]
for s in range(n):
    if terr[s]==18 and not seen[s]:
        comp=[s];seen[s]=True
        for c in comp:
            for ni in NB[c]:
                if ni>=0 and terr[ni]==18 and not seen[ni]: seen[ni]=True;comp.append(ni)
        lakes.append(len(comp))
print(f"=== LAKES: {len(lakes)} bodies sizes={sorted(lakes,reverse=True)}")
# RIVERS discharge distribution (需求1)
rd_vals=sorted(disch[i] for i in range(n) if hasriver[i])
print(f"=== RIVERS: has_river={sum(hasriver)} cells")
if rd_vals:
    p=lambda f:rd_vals[min(len(rd_vals)-1,int(f*len(rd_vals)))]
    print(f"   discharge: min={rd_vals[0]:.3f} p25={p(.25):.3f} p50={p(.5):.3f} p75={p(.75):.3f} p90={p(.9):.3f} p99={p(.99):.3f} max={rd_vals[-1]:.3f}")
    print(f"   discharge ratio max/p50={rd_vals[-1]/max(p(.5),1e-6):.1f}")
# MOUNTAIN layering (需求4): high-elev cells slope
high=[i for i in range(n) if iw[i]==0 and elev[i]>0.66]
if high:
    slopes=[]
    for i in high:
        nbh=[elev[ni] for ni in NB[i] if ni>=0]
        if nbh: slopes.append(max(nbh)-min(nbh))
    he=sorted(elev[i] for i in high)
    ss=sorted(slopes)
    p=lambda a,f:a[min(len(a)-1,int(f*len(a)))]
    print(f"=== MOUNTAINS (elev>0.66): {len(high)} cells")
    print(f"   elev: p10={p(he,.1):.3f} p50={p(he,.5):.3f} p90={p(he,.9):.3f} max={he[-1]:.3f}")
    print(f"   local relief(max-min nb): p10={p(ss,.1):.4f} p50={p(ss,.5):.4f} p90={p(ss,.9):.4f}  (small=flat plateau)")
# SEA ICE vs SNOW (需求5)
print(f"=== ICE/SNOW: SEA_ICE(terr20)={sum(1 for t in terr if t==20)} cells; sea_ice_frac>0.1={sum(1 for v in seaice if v>0.1)}")
snowland=sorted(snow[i] for i in range(n) if iw[i]==0 and snow[i]>0.01)
if snowland:
    p=lambda f:snowland[min(len(snowland)-1,int(f*len(snowland)))]
    print(f"   land snow_cover>0.01: {len(snowland)} cells p50={p(.5):.3f} p90={p(.9):.3f} max={snowland[-1]:.3f}")
# MACRO relief
land_e=[elev[i] for i in range(n) if iw[i]==0]
print(f"=== MACRO: land elev std={statistics.pstdev(land_e):.4f}")
for BS in (10,20):
    blocks=collections.defaultdict(list)
    for i in range(n):
        if iw[i]==0: blocks[(q[i]//BS,rr[i]//BS)].append(elev[i])
    bm=[statistics.mean(v) for v in blocks.values() if len(v)>=3]
    wi=[statistics.pstdev(v) for v in blocks.values() if len(v)>=3]
    print(f"   block{BS}: between={statistics.pstdev(bm):.4f} within={statistics.mean(wi):.4f} (between>within → 宏观强)")
