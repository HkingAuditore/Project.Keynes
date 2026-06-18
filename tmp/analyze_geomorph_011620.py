import csv, collections, math, statistics

PATH = r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260619_011620.csv"

TERR = {0:"OCEAN",1:"COAST",2:"PLAIN",3:"GRASSLAND",4:"FOREST",5:"HILL",6:"MOUNTAIN",
7:"DESERT",8:"TUNDRA",9:"SNOW",10:"SWAMP",11:"JUNGLE",12:"SAVANNA",13:"TAIGA",14:"STEPPE",
15:"SHRUBLAND",16:"MANGROVE",17:"GLACIER",18:"LAKE",19:"REEF",20:"SEA_ICE",21:"KELP",
22:"DELTA",23:"OASIS",24:"SALT_FLAT",25:"BADLANDS",26:"COLD_DESERT",27:"CHAPARRAL",
28:"MOOR",29:"FLOODPLAIN",30:"MESA"}
LF = {0:"DEEP_OCEAN",1:"OCEAN",2:"COAST",3:"LAKE",4:"PLAIN",5:"LOWLAND",6:"HILL",
7:"MOUNTAIN",8:"PEAK",9:"DELTA",10:"BADLANDS",11:"SALT_FLAT",12:"VOLCANO",13:"PLATEAU",14:"RIFT_VALLEY"}

def fnum(s):
    try: return float(s)
    except: return float("nan")

rows=[]
with open(PATH, newline="") as f:
    r=csv.DictReader(f)
    for row in r: rows.append(row)
n=len(rows)
print("rows:", n)

def col(name): return [x[name] for x in rows]
ci=[int(float(x)) for x in col("cell_index")]
q=[int(float(x)) for x in col("q")]
rr=[int(float(x)) for x in col("r")]
terr=[int(float(x)) for x in col("terrain_arr")]
lf=[int(float(x)) for x in col("landform_arr")]
isw=[int(float(x)) for x in col("is_water_arr")]
elev=[fnum(x) for x in col("elevation_arr")]
moist=[fnum(x) for x in col("moisture_arr")]
temp=[fnum(x) for x in col("temp_arr")]
hasriver=[fnum(x) for x in col("has_river_arr")]
disch=[fnum(x) for x in col("river_discharge_arr")]
parent=[int(float(x)) for x in col("hydro_parent_arr")]

# derive grid dims
maxr=max(rr)
height=maxr+1
width=n//height
print(f"grid: width={width} height={height}  (w*h={width*height} vs n={n})")

# build index map by cell_index (assume cell_index == row*width+col)
idxpos={}
for i in range(n):
    idxpos[ci[i]]=i
# map from (row,col)
def index_for_qr(qq,rrr):
    c=qq+((rrr-(rrr&1))//2)
    if c<0 or c>=width or rrr<0 or rrr>=height: return -1
    li=rrr*width+c
    return idxpos.get(li,-1)
DQ=[1,1,0,-1,-1,0]; DR=[0,-1,-1,0,1,1]

# ---- water connectivity (terrain OCEAN==0) ----
water_ocean=[1 if terr[i]==0 else 0 for i in range(n)]
visited=[False]*n
comps=[]
for start in range(n):
    if water_ocean[start] and not visited[start]:
        stack=[start]; visited[start]=True; cells=[]
        touches_border=False
        while stack:
            cur=stack.pop(); cells.append(cur)
            if rr[cur]==0 or rr[cur]==height-1:
                touches_border=True
            cc=q[cur]+((rr[cur]-(rr[cur]&1))//2)
            if cc==0 or cc==width-1: touches_border=True
            for d in range(6):
                ni=index_for_qr(q[cur]+DQ[d], rr[cur]+DR[d])
                if ni>=0 and water_ocean[ni] and not visited[ni]:
                    visited[ni]=True; stack.append(ni)
        comps.append((len(cells),touches_border))
comps.sort(reverse=True)
print(f"\n=== OCEAN(terrain==0) connected components: {len(comps)} ===")
big=[c for c in comps if c[1]]
small=[c for c in comps if not c[1]]
print(f"  border-connected (true ocean) comps: {len(big)}  total cells={sum(c[0] for c in big)}")
print(f"  INLAND ocean comps (NOT border, mislabeled): {len(small)}  total cells={sum(c[0] for c in small)}")
sizehist=collections.Counter()
for sz,brd in small:
    b="1" if sz==1 else ("2-4" if sz<=4 else ("5-16" if sz<=16 else "17+"))
    sizehist[b]+=1
print(f"  inland-ocean size buckets: {dict(sizehist)}")
print(f"  largest comps (size,border): {comps[:6]}")

# ---- water cells overall ----
wat=sum(1 for i in range(n) if isw[i]==1)
print(f"\nwater(is_water)={wat} ({100*wat/n:.1f}%)  land={n-wat} ({100*(n-wat)/n:.1f}%)")
tc=collections.Counter(terr)
print("\n=== TERRAIN ===")
for k,v in tc.most_common(): print(f"  {TERR.get(k,k):14s}{v:6d} {100*v/n:5.1f}%")
lc=collections.Counter(lf)
print("\n=== LANDFORM ===")
for k,v in lc.most_common(): print(f"  {LF.get(k,k):12s}{v:6d} {100*v/n:5.1f}%")

# ---- rivers ----
rc=sum(1 for x in hasriver if x and x>0.5)
print(f"\nhas_river: {rc} ({100*rc/n:.2f}%)")
dpos=[d for d in disch if d==d and d>0]
print(f"discharge>0: {len(dpos)}  max={max(dpos) if dpos else 0:.3f}  med={statistics.median(dpos) if dpos else 0:.4f}")
par=sum(1 for p in parent if p>=0)
print(f"hydro_parent>=0: {par} ({100*par/n:.1f}%)")

# ---- elevation macro structure: variogram-ish (mean abs diff at lag k along rows) ----
ev=[e for e in elev if e==e]
print(f"\nelevation: min={min(ev):.3f} med={statistics.median(ev):.3f} max={max(ev):.3f} mean={statistics.mean(ev):.3f}")
landidx=[i for i in range(n) if isw[i]==0]
le=[elev[i] for i in landidx]
if le: print(f"land elev: min={min(le):.3f} med={statistics.median(le):.3f} max={max(le):.3f}")
# slope distribution (max neighbor elevation diff) -> ruggedness
slopes=[]
for i in range(n):
    mx=0.0
    for d in range(6):
        ni=index_for_qr(q[i]+DQ[d], rr[i]+DR[d])
        if ni>=0:
            mx=max(mx, abs(elev[i]-elev[ni]))
    slopes.append(mx)
sl=[s for s in slopes if s==s]
print(f"max-neighbor-slope: med={statistics.median(sl):.4f} p90={sorted(sl)[int(0.9*len(sl))]:.4f} max={max(sl):.4f}")
# spatial autocorrelation of elevation at lag along row (macro coherence)
def lag_diff(k):
    diffs=[]
    for i in range(n):
        ni=index_for_qr(q[i]+k, rr[i])  # k cells east (approx via q shift won't be pure east but ok)
        if ni>=0: diffs.append(abs(elev[i]-elev[ni]))
    return statistics.mean(diffs) if diffs else float('nan')
print("mean |Δelev| at lag (cells):", {k:round(lag_diff(k),3) for k in (1,2,4,8,16)})

mv=[m for m in moist if m==m]
print(f"\nmoisture: min={min(mv):.3f} med={statistics.median(mv):.3f} max={max(mv):.3f} mean={statistics.mean(mv):.3f}")
tv=[t for t in temp if t==t]
print(f"temp: min={min(tv):.3f} med={statistics.median(tv):.3f} max={max(tv):.3f} mean={statistics.mean(tv):.3f}")
