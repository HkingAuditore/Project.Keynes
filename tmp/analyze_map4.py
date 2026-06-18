import csv, collections
path = r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260618_213653.csv"
with open(path, newline='') as f:
    r=csv.reader(f); h=next(r); hi={n:i for i,n in enumerate(h)}
    cells={}; maxidx=-1; rawelev={}
    for row in r:
        ci=int(row[hi["cell_index"]])
        if ci<=maxidx and maxidx>100: break
        maxidx=ci
        key=(int(row[hi["q"]]),int(row[hi["r"]]))
        cells[key]=(int(row[hi["terrain_arr"]]),int(row[hi["is_water_arr"]]),float(row[hi["elevation_arr"]]))
elevs=[v[2] for v in cells.values()]
# how many cells share the exact value seen on specks
from collections import Counter
ec=Counter(round(e,4) for e in elevs)
print("most common exact elevation values:")
for e,c in ec.most_common(8): print(f"  elev={e}  count={c}")
# specks
DQ=[1,1,0,-1,-1,0]; DR=[0,-1,-1,0,1,1]
def nbrs(q,r):
    for dq,dr in zip(DQ,DR): yield(q+dq,r+dr)
seen=set(); speck_elevs=[]
for key,v in cells.items():
    if not v[1] or key in seen: continue
    stack=[key]; seen.add(key); comp=[key]
    while stack:
        cur=stack.pop()
        for nb in nbrs(*cur):
            if nb in cells and cells[nb][1] and nb not in seen:
                seen.add(nb); stack.append(nb); comp.append(nb)
    if len(comp)==1: speck_elevs.append(cells[comp[0]][2])
print(f"\nsingle-speck elevations: count={len(speck_elevs)} unique={set(round(e,4) for e in speck_elevs)}")
# big-ocean cells elevation range
water_elev=[v[2] for v in cells.values() if v[1]]
land_elev=[v[2] for v in cells.values() if not v[1]]
print(f"\nwater elev: min={min(water_elev):.3f} max={max(water_elev):.3f}")
print(f"land  elev: min={min(land_elev):.3f} max={max(land_elev):.3f}")
print(f"sea_level config = 0.64")
print(f"land cells below 0.64: {sum(1 for e in land_elev if e<0.64)} (land that is below sea level!)")
print(f"water cells above 0.64: {sum(1 for e in water_elev if e>0.64)}")
