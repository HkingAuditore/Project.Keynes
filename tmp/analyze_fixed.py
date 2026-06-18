import csv, collections, statistics, sys

PATH = sys.argv[1] if len(sys.argv)>1 else r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260619_015035.csv"

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

allrows=[]
with open(PATH, newline="") as f:
    rd=csv.DictReader(f)
    for row in rd: allrows.append(row)
N=len(allrows)
ci=[int(float(x["cell_index"])) for x in allrows]
ncells=max(ci)+1
# split snapshots by cell_index resetting to 0
starts=[i for i in range(N) if ci[i]==0]
print(f"total rows={N} distinct cells={ncells} snapshots={len(starts)} starts={starts[:8]}")
# take LAST full snapshot of length ncells
s0=starts[-1]
snap=allrows[s0:s0+ncells]
if len(snap)<ncells:
    # last snapshot incomplete; take previous
    s0=starts[-2]; snap=allrows[s0:s0+ncells]
print(f"using snapshot at row {s0}, len={len(snap)}")
rows=snap
n=len(rows)
def col(nm): return [x[nm] for x in rows]
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
cidx=[int(float(x)) for x in col("cell_index")]
height=max(rr)+1
width=n//height
print(f"grid: width={width} height={height}")
pos={cidx[i]:i for i in range(n)}
def index_for_qr(qq,rrr):
    c=qq+((rrr-(rrr&1))//2)
    if c<0 or c>=width or rrr<0 or rrr>=height: return -1
    return pos.get(rrr*width+c,-1)
DQ=[1,1,0,-1,-1,0]; DR=[0,-1,-1,0,1,1]
NB=[[index_for_qr(q[i]+DQ[d],rr[i]+DR[d]) for d in range(6)] for i in range(n)]
# sanity: avg valid neighbors
avgnb=statistics.mean(sum(1 for ni in row if ni>=0) for row in NB)
print(f"avg valid neighbors/cell = {avgnb:.2f} (should be ~5-6)")

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

land=comps_of(lambda i: isw[i]==0)
print(f"\n=== LAND masses: {len(land)} comps, sizes top: {land[:12]}")
cont=[s for s in land if s>=150]; mid=[s for s in land if 30<=s<150]
isl=[s for s in land if 5<=s<30]; tiny=[s for s in land if s<5]
print(f"  continents(>=150): {len(cont)} cells={sum(cont)}")
print(f"  mid-land(30-149):  {len(mid)} cells={sum(mid)}")
print(f"  islands(5-29):     {len(isl)} cells={sum(isl)}")
print(f"  tiny(<5):          {len(tiny)} cells={sum(tiny)}")

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
print(f"\n=== WATER: border-ocean cells={ocean_border}; inland bodies={len(inland)} sizes={inland[:10]}")
print(f"  inland single-cell water (mislabeled ocean): {sum(1 for s in inland if s==1)}")

print("\n=== TERRAIN ===")
for k,v in collections.Counter(terr).most_common(): print(f"  {TERR.get(k,k):14s}{v:5d} {100*v/n:5.1f}%")
print("\n=== LANDFORM ===")
for k,v in collections.Counter(lf).most_common(): print(f"  {LF.get(k,k):12s}{v:5d} {100*v/n:5.1f}%")

print("\n=== MACRO landform coherence (connected comp sizes, land only) ===")
for name,ids in [("MOUNTAIN+PEAK",{7,8}),("HILL",{6}),("PLAIN",{4}),("LOWLAND",{5}),
                 ("PLATEAU",{13}),("RIFT",{14}),("BADLANDS",{10})]:
    c=comps_of(lambda i: lf[i] in ids and isw[i]==0)
    big=[x for x in c if x>=8]
    print(f"  {name:16s} comps={len(c):4d} top={c[:6]} clusters(>=8):{len(big)}")

rc=sum(1 for x in hasriver if x>0.5)
print(f"\n=== RIVERS: has_river={rc} ({100*rc/n:.2f}%) ===")
rcomp=comps_of(lambda i: hasriver[i]>0.5)
print(f"  river network comps={len(rcomp)} top sizes={rcomp[:10]}")
par=sum(1 for p in parent if p>=0)
print(f"  hydro_parent>=0: {par} ({100*par/n:.1f}%)")

le=[elev[i] for i in range(n) if isw[i]==0]
ev=[e for e in elev if e==e]
print(f"\nelevation all: med={statistics.median(ev):.3f} max={max(ev):.3f}")
if le: print(f"land elev: min={min(le):.3f} med={statistics.median(le):.3f} max={max(le):.3f}")
sl=[]
for i in range(n):
    nbs=[abs(elev[i]-elev[ni]) for ni in NB[i] if ni>=0]
    sl.append(max(nbs) if nbs else 0.0)
print(f"max-neighbor |Δelev|: med={statistics.median(sl):.4f} p90={sorted(sl)[int(0.9*n)]:.4f} max={max(sl):.4f}")
mv=[m for m in moist if m==m]; tv=[t for t in temp if t==t]
print(f"moisture: med={statistics.median(mv):.3f}  temp: med={statistics.median(tv):.3f}")
