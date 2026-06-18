import csv, collections, math
PATH = r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260619_035313.csv"
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
q=[int(float(x["q"])) for x in rows]; rr=[int(float(x["r"])) for x in rows]
terr=[int(float(x["terrain_arr"])) for x in rows]
landf=[int(float(x["landform_arr"])) for x in rows]
veg=[int(float(x["vegetation_arr"])) for x in rows]
elev=col("elevation_arr"); temp=col("temp_arr"); moist=col("moisture_arr")
soil=col("soil_moisture_arr"); wb=col("water_balance_30d_arr"); gw=col("groundwater_storage_arr")
iw=[int(float(x["is_water_arr"])) for x in rows]
cidx=[int(float(x["cell_index"])) for x in rows]
height=max(rr)+1; width=n//height
print(f"snapshots={len(starts)} grid={width}x{height} n={n} (last tick={rows[0]['tick_idx']})")
# terrain / veg / landform distributions
def dist(a,name,topk=14):
    c=collections.Counter(a); tot=len(a)
    print(f"-- {name}: {len(c)} types")
    for k,v in c.most_common(topk):
        print(f"     {k:>3}: {v:5d} ({100*v/tot:4.1f}%)")
dist(terr,"terrain_arr")
dist(landf,"landform_arr")
dist(veg,"vegetation_arr")
# climate field ranges (for shader)
def stats(a,nm,landonly=True):
    vals=[a[i] for i in range(n) if (iw[i]==0 if landonly else True)]
    vals.sort()
    if not vals: print(f"   {nm}: (none)"); return
    p=lambda f:vals[min(len(vals)-1,int(f*len(vals)))]
    print(f"   {nm:24s} min={vals[0]:.3f} p10={p(.1):.3f} p50={p(.5):.3f} p90={p(.9):.3f} max={vals[-1]:.3f}")
print("=== CLIMATE FIELDS (land cells) ===")
for nm,a in [("temp_arr",temp),("moisture_arr",moist),("soil_moisture_arr",soil),("water_balance_30d_arr",wb),("groundwater_storage_arr",gw),("elevation_arr",elev)]:
    stats(a,nm)
# lakes
WATER={0,1,18,19,20,21}
pos={cidx[i]:i for i in range(n)}
DQ=[1,1,0,-1,-1,0]; DR=[0,-1,-1,0,1,1]
def idx_qr(qq,rrr):
    c=qq+((rrr-(rrr&1))//2)
    if c<0 or c>=width or rrr<0 or rrr>=height: return -1
    return pos.get(rrr*width+c,-1)
NB=[[idx_qr(q[i]+DQ[d],rr[i]+DR[d]) for d in range(6)] for i in range(n)]
seen=[False]*n; lakes=[]
for s in range(n):
    if terr[s]==18 and not seen[s]:
        comp=[s];seen[s]=True
        for c in comp:
            for ni in NB[c]:
                if ni>=0 and terr[ni]==18 and not seen[ni]: seen[ni]=True;comp.append(ni)
        lakes.append(len(comp))
print(f"=== LAKES (terrain==18): {len(lakes)} bodies sizes={sorted(lakes,reverse=True)}")
# "holes": filled pits -> land cells with elevation just above sea (0.43~0.45)
holes=[i for i in range(n) if iw[i]==0 and 0.425<=elev[i]<=0.46]
seenh=[False]*n; hcomp=[]
for s in holes:
    if not seenh[s]:
        comp=[s];seenh[s]=True
        for c in comp:
            for ni in NB[c]:
                if ni>=0 and iw[ni]==0 and 0.425<=elev[ni]<=0.46 and not seenh[ni]: seenh[ni]=True;comp.append(ni)
        hcomp.append(len(comp))
print(f"=== low-flat land 0.425-0.46 ('holes'): {len(holes)} cells, {len(hcomp)} patches sizes={sorted(hcomp,reverse=True)[:20]}")
htb=collections.Counter(terr[i] for i in holes)
print(f"     their terrain: {dict(htb.most_common(8))}")
# MACRO STRUCTURE: coarse-grid elevation variance vs fine
import statistics
land_e=[elev[i] for i in range(n) if iw[i]==0]
print(f"=== MACRO RELIEF ANALYSIS (land, sea={SEA}) ===")
print(f"   land elev std={statistics.pstdev(land_e):.4f}  mean={statistics.mean(land_e):.4f}")
# coarse blocks BS x BS, mean elevation; measure between-block vs within-block variance
for BS in (5,10,20):
    blocks=collections.defaultdict(list)
    for i in range(n):
        if iw[i]==0:
            blocks[(q[i]//BS, rr[i]//BS)].append(elev[i])
    bmeans=[statistics.mean(v) for v in blocks.values() if len(v)>=3]
    within=[statistics.pstdev(v) for v in blocks.values() if len(v)>=3]
    if bmeans:
        print(f"   block {BS:2d}: between-block std={statistics.pstdev(bmeans):.4f}  mean within-block std={statistics.mean(within):.4f}")
