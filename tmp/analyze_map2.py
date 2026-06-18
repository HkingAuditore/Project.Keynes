import csv, collections

path = r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260618_213653.csv"
TERR = {0:"OCEAN",1:"COAST",2:"PLAIN",3:"GRASSLAND",4:"FOREST",5:"HILL",6:"MOUNTAIN",
7:"DESERT",8:"TUNDRA",9:"SNOW",10:"SWAMP",11:"JUNGLE",12:"SAVANNA",13:"TAIGA",14:"STEPPE",
15:"SHRUBLAND",16:"MANGROVE",17:"GLACIER",18:"LAKE",19:"REEF",20:"SEA_ICE",21:"KELP",
22:"DELTA",23:"OASIS",24:"SALT_FLAT",25:"BADLANDS"}

with open(path, newline='') as f:
    r = csv.reader(f); header=next(r); hi={n:i for i,n in enumerate(header)}
    cells={}; maxidx=-1
    temps=[]; moists=[]; elevs=[]
    for row in r:
        ci=int(row[hi["cell_index"]])
        if ci<=maxidx and maxidx>100: break
        maxidx=ci
        q=int(row[hi["q"]]); rr=int(row[hi["r"]])
        t=int(row[hi["terrain_arr"]]); iw=int(row[hi["is_water_arr"]])
        bt=int(row[hi["base_terrain_arr"]])
        temp=float(row[hi["temp_arr"]]); moist=float(row[hi["moisture_arr"]]); elev=float(row[hi["elevation_arr"]])
        lat=float(row[hi["cell_lat_norm_arr"]])
        cells[(q,rr)]=(t,iw,bt,temp,moist,elev,lat)
        temps.append(temp); moists.append(moist); elevs.append(elev)

n=len(cells)
DQ=[1,1,0,-1,-1,0]; DR=[0,-1,-1,0,1,1]
def nbrs(q,r):
    for dq,dr in zip(DQ,DR): yield (q+dq,r+dr)

# small water bodies: terrain breakdown
seen=set(); small_terr=collections.Counter(); small_baseterr=collections.Counter()
single_terr=collections.Counter()
for key,v in cells.items():
    if not v[1] or key in seen: continue
    stack=[key]; seen.add(key); comp=[key]
    while stack:
        cur=stack.pop()
        for nb in nbrs(*cur):
            if nb in cells and cells[nb][1] and nb not in seen:
                seen.add(nb); stack.append(nb); comp.append(nb)
    if len(comp)<=5:
        for c in comp:
            small_terr[cells[c][0]]+=1
            small_baseterr[cells[c][2]]+=1
        if len(comp)==1:
            single_terr[cells[comp[0]][0]]+=1
print("=== terrain of cells in small(<=5) water bodies ===")
for t,c in small_terr.most_common(): print(f"  {TERR.get(t,t):10} {c}")
print("=== base_terrain (generation-time) of those same cells ===")
for t,c in small_baseterr.most_common(): print(f"  {TERR.get(t,t):10} {c}")
print("=== terrain of SINGLE-tile water bodies ===")
for t,c in single_terr.most_common(): print(f"  {TERR.get(t,t):10} {c}")

# distributions
def pct(arr,bins):
    out=[]
    for lo,hi in bins:
        c=sum(1 for x in arr if lo<=x<hi)
        out.append((lo,hi,c,100*c/len(arr)))
    return out
print("\n=== temperature distribution (all cells) ===")
for lo,hi,c,p in pct(temps,[(0,0.05),(0.05,0.2),(0.2,0.4),(0.4,0.55),(0.55,0.7),(0.7,1.01)]):
    print(f"  [{lo:.2f},{hi:.2f}): {c:6} ({p:.1f}%)")
print("=== moisture distribution (all cells) ===")
for lo,hi,c,p in pct(moists,[(0,0.1),(0.1,0.2),(0.2,0.3),(0.3,0.4),(0.4,0.55),(0.55,0.65),(0.65,1.01)]):
    print(f"  [{lo:.2f},{hi:.2f}): {c:6} ({p:.1f}%)")

# land-only temp/moist
land_temp=[cells[k][3] for k in cells if not cells[k][1]]
land_moist=[cells[k][4] for k in cells if not cells[k][1]]
import statistics as st
print(f"\nland temp mean={st.mean(land_temp):.3f} median={st.median(land_temp):.3f}")
print(f"land moist mean={st.mean(land_moist):.3f} median={st.median(land_moist):.3f}")

# infer width/height
maxq=max(k[0] for k in cells); minq=min(k[0] for k in cells)
maxr=max(k[1] for k in cells); minr=min(k[1] for k in cells)
print(f"\nq range [{minq},{maxq}] r range [{minr},{maxr}]  -> ~{maxr-minr+1} rows")
