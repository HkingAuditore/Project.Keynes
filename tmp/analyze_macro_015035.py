import csv, collections, math, statistics

PATH = r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260619_015035.csv"

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
def col(n_): return [x[n_] for x in rows]
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
ci=[int(float(x)) for x in col("cell_index")]
maxr=max(rr); height=maxr+1; width=n//height
print(f"rows={n} grid={width}x{height}")
idxpos={ci[i]:i for i in range(n)}
def index_for_qr(qq,rrr):
    c=qq+((rrr-(rrr&1))//2)
    if c<0 or c>=width or rrr<0 or rrr>=height: return -1
    return idxpos.get(rrr*width+c,-1)
DQ=[1,1,0,-1,-1,0]; DR=[0,-1,-1,0,1,1]
NB=[[index_for_qr(q[i]+DQ[d],rr[i]+DR[d]) for d in range(6)] for i in range(n)]

def comps_of(pred):
    seen=[False]*n; out=[]
    for s in range(n):
        if pred(s) and not seen[s]:
            st=[s]; seen[s]=True; cells=0
            while st:
                c=st.pop(); cells+=1
                for ni in NB[c]:
                    if ni>=0 and pred(ni) and not seen[ni]:
                        seen[ni]=True; st.append(ni)
            out.append(cells)
    out.sort(reverse=True); return out

wat=sum(1 for i in range(n) if isw[i]==1)
print(f"\nwater={wat} ({100*wat/n:.1f}%)  land={n-wat} ({100*(n-wat)/n:.1f}%)")

# ---- LAND masses: continents vs islands vs archipelago ----
land=comps_of(lambda i: isw[i]==0)
print(f"\n=== LAND masses: {len(land)} components ===")
print(f"  sizes top: {land[:12]}")
cont=[s for s in land if s>=200]; mid=[s for s in land if 30<=s<200]
isl=[s for s in land if 5<=s<30]; tiny=[s for s in land if s<5]
print(f"  continents(>=200): {len(cont)} cells={sum(cont)}")
print(f"  mid-land(30-199):  {len(mid)} cells={sum(mid)}")
print(f"  islands(5-29):     {len(isl)} cells={sum(isl)}")
print(f"  tiny(<5):          {len(tiny)} cells={sum(tiny)}")

# ---- WATER bodies: ocean vs inland single cells ----
water_terr=lambda i: terr[i] in (0,1,18,19,20,21)
seen=[False]*n; ocean_border=0; inland=[]
for s in range(n):
    if water_terr(s) and not seen[s]:
        st=[s]; seen[s]=True; cells=[]; border=False
        while st:
            c=st.pop(); cells.append(c)
            cc=q[c]+((rr[c]-(rr[c]&1))//2)
            if rr[c]==0 or rr[c]==height-1 or cc==0 or cc==width-1: border=True
            for ni in NB[c]:
                if ni>=0 and water_terr(ni) and not seen[ni]:
                    seen[ni]=True; st.append(ni)
        if border: ocean_border+=len(cells)
        else: inland.append(len(cells))
inland.sort(reverse=True)
print(f"\n=== WATER: border-ocean cells={ocean_border}; inland water bodies={len(inland)} sizes={inland[:10]}")
print(f"  inland single-cell water: {sum(1 for s in inland if s==1)}")

print("\n=== TERRAIN ===")
for k,v in collections.Counter(terr).most_common(): print(f"  {TERR.get(k,k):14s}{v:6d} {100*v/n:5.1f}%")
print("\n=== LANDFORM ===")
for k,v in collections.Counter(lf).most_common(): print(f"  {LF.get(k,k):12s}{v:6d} {100*v/n:5.1f}%")

# ---- MACRO landform coherence: connected component sizes ----
print("\n=== MACRO landform coherence (connected component sizes) ===")
for name,ids in [("MOUNTAIN+PEAK(lf6/7/8)",{6,7,8}),("HILL(lf6)",{6}),
                 ("PLAIN(lf4)",{4}),("LOWLAND(lf5)",{5}),("PLATEAU(lf13)",{13}),
                 ("RIFT(lf14)",{14})]:
    c=comps_of(lambda i: lf[i] in ids and isw[i]==0)
    if c:
        big=[x for x in c if x>=10]
        print(f"  {name:24s} comps={len(c):4d} top={c[:6]} clusters>=10:{len(big)}")
    else:
        print(f"  {name:24s} none")
# terrain MOUNTAIN clusters
cm=comps_of(lambda i: terr[i]==6)
print(f"  TERRAIN MOUNTAIN(6)      comps={len(cm)} top={cm[:6]}")

# ---- RIVERS ----
rc=sum(1 for x in hasriver if x and x>0.5)
print(f"\n=== RIVERS: has_river={rc} ({100*rc/n:.2f}%) ===")
dpos=[d for d in disch if d==d and d>0]
print(f"  discharge>0: {len(dpos)} max={max(dpos) if dpos else 0:.3f}")
par=sum(1 for p in parent if p>=0)
print(f"  hydro_parent>=0: {par} ({100*par/n:.1f}%)")
# river connected comps (visualize as networks)
rcomp=comps_of(lambda i: hasriver[i]>0.5)
print(f"  river network comps={len(rcomp)} top sizes={rcomp[:8]}")

# ---- elevation structure ----
ev=[e for e in elev if e==e]
le=[elev[i] for i in range(n) if isw[i]==0]
print(f"\nelevation all: med={statistics.median(ev):.3f} mean={statistics.mean(ev):.3f} max={max(ev):.3f}")
if le: print(f"land elev: min={min(le):.3f} med={statistics.median(le):.3f} max={max(le):.3f}")
# neighbor slope
sl=[]
for i in range(n):
    mx=0.0
    for ni in NB[i]:
        if ni>=0: mx=max(mx,abs(elev[i]-elev[ni]))
    sl.append(mx)
print(f"max-neighbor |Δelev|: med={statistics.median(sl):.4f} p90={sorted(sl)[int(0.9*n)]:.4f} max={max(sl):.4f}")
# low vs high freq: compare cell elev to 5x5-ish neighborhood mean (2-ring)
def ring2(i):
    seen2={i}; frontier=[i]
    for _ in range(2):
        nf=[]
        for c in frontier:
            for ni in NB[c]:
                if ni>=0 and ni not in seen2:
                    seen2.add(ni); nf.append(ni)
        frontier=nf
    return seen2
hf=[]
for i in range(0,n,7):  # sample
    rg=ring2(i); m=statistics.mean(elev[j] for j in rg)
    hf.append(abs(elev[i]-m))
print(f"high-freq residual (|elev - 2ring mean|) sampled: med={statistics.median(hf):.4f} mean={statistics.mean(hf):.4f}")

mv=[m for m in moist if m==m]
print(f"\nmoisture: med={statistics.median(mv):.3f} mean={statistics.mean(mv):.3f}")
tv=[t for t in temp if t==t]
print(f"temp: med={statistics.median(tv):.3f} mean={statistics.mean(tv):.3f}")
