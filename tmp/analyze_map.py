import csv, sys, collections

path = r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260618_213653.csv"

TERR = {0:"OCEAN",1:"COAST",2:"PLAIN",3:"GRASSLAND",4:"FOREST",5:"HILL",6:"MOUNTAIN",
7:"DESERT",8:"TUNDRA",9:"SNOW",10:"SWAMP",11:"JUNGLE",12:"SAVANNA",13:"TAIGA",14:"STEPPE",
15:"SHRUBLAND",16:"MANGROVE",17:"GLACIER",18:"LAKE",19:"REEF",20:"SEA_ICE",21:"KELP",
22:"DELTA",23:"OASIS",24:"SALT_FLAT",25:"BADLANDS"}
LF = {0:"DEEP_OCEAN",1:"OCEAN",2:"COAST",3:"LAKE",4:"PLAIN",5:"LOWLAND",6:"HILL",7:"MOUNTAIN",8:"PEAK",9:"DELTA",10:"BADLANDS",11:"SALT_FLAT",12:"VOLCANO"}

with open(path, newline='') as f:
    r = csv.reader(f)
    header = next(r)
    hi = {name:i for i,name in enumerate(header)}
    need = ["cell_index","q","r","s","terrain_arr","landform_arr","vegetation_arr","is_water_arr","elevation_arr","moisture_arr","has_river_arr","temp_arr","cell_lat_norm_arr"]
    idx = {k:hi[k] for k in need}
    # read only first tick snapshot: rows are ordered cell 0..N for tick 49; stop when cell_index resets
    cells = {}  # (q,r) -> dict
    terr_count = collections.Counter()
    lf_count = collections.Counter()
    veg_count = collections.Counter()
    water = 0; land = 0; river = 0
    first_tick = None
    maxidx = -1
    for row in r:
        ci = int(row[idx["cell_index"]])
        # detect snapshot boundary: once we've passed and ci wraps to 0 again after >0
        if ci <= maxidx and maxidx > 100:
            break
        maxidx = ci
        q = int(row[idx["q"]]); rr = int(row[idx["r"]])
        t = int(row[idx["terrain_arr"]])
        lf = int(row[idx["landform_arr"]])
        veg = int(row[idx["vegetation_arr"]])
        iw = int(row[idx["is_water_arr"]])
        elev = float(row[idx["elevation_arr"]])
        moist = float(row[idx["moisture_arr"]])
        hr = int(row[idx["has_river_arr"]])
        cells[(q,rr)] = (t,iw,elev)
        terr_count[t]+=1; lf_count[lf]+=1; veg_count[veg]+=1
        if iw: water+=1
        else: land+=1
        if hr: river+=1

n = len(cells)
print(f"total cells in snapshot: {n}, max cell_index={maxidx}")
print(f"water={water} ({100*water/n:.1f}%)  land={land} ({100*land/n:.1f}%)  river_cells={river} ({100*river/n:.2f}%)")
print("\n=== terrain distribution ===")
for t,c in terr_count.most_common():
    print(f"  {TERR.get(t,t):12} {c:6} ({100*c/n:.2f}%)")
print(f"distinct terrain types present: {len(terr_count)} / 26")
print("\n=== landform distribution ===")
for t,c in lf_count.most_common():
    print(f"  {LF.get(t,t):12} {c:6} ({100*c/n:.2f}%)")
print("distinct landforms:", len(lf_count))
print("\n=== vegetation distinct:", len(veg_count), "===")
for t,c in veg_count.most_common(30):
    print(f"  veg{t:3} {c:6} ({100*c/n:.2f}%)")

# neighbor adjacency for single-tile water detection (hex offset via cube q,r)
DQ=[1,1,0,-1,-1,0]; DR=[0,-1,-1,0,1,1]
def nbrs(q,r):
    for dq,dr in zip(DQ,DR):
        yield (q+dq, r+dr)

# count connected components of water; report tiny isolated water bodies
seen=set()
comp_sizes=[]
isolated_single=0
ocean_like = {0,1,18,19,20,21}
for key,(t,iw,elev) in cells.items():
    if not iw or key in seen: continue
    # BFS
    stack=[key]; seen.add(key); size=0
    while stack:
        cur=stack.pop(); size+=1
        for nb in nbrs(*cur):
            if nb in cells and cells[nb][1] and nb not in seen:
                seen.add(nb); stack.append(nb)
    comp_sizes.append(size)
comp_sizes.sort()
print(f"\n=== water bodies (connected components of is_water) ===")
print(f"total water components: {len(comp_sizes)}")
size_hist=collections.Counter(comp_sizes)
for sz in sorted(size_hist):
    if sz<=10 or size_hist[sz]>0 and sz in (max(comp_sizes),):
        print(f"  size {sz:5}: {size_hist[sz]} bodies")
singles=sum(1 for s in comp_sizes if s==1)
tiny=sum(1 for s in comp_sizes if s<=3)
print(f"single-tile water bodies: {singles}")
print(f"<=3-tile water bodies: {tiny}")
print(f"largest water body: {max(comp_sizes)} ({100*max(comp_sizes)/water:.1f}% of all water)")

# how many single/tiny water bodies are INTERIOR (all land/water neighbors but not connected to the big ocean)
big = max(comp_sizes)
# recompute marking big-ocean membership
seen2=set(); interior_small=0; small_water_total=0
for key,(t,iw,elev) in cells.items():
    if not iw or key in seen2: continue
    stack=[key]; seen2.add(key); comp=[key]
    while stack:
        cur=stack.pop()
        for nb in nbrs(*cur):
            if nb in cells and cells[nb][1] and nb not in seen2:
                seen2.add(nb); stack.append(nb); comp.append(nb)
    if len(comp) <= 5:
        small_water_total+=1
        # interior if no neighbor missing (edge) -> surrounded
        touches_edge=False
        for c in comp:
            for nb in nbrs(*c):
                if nb not in cells:
                    touches_edge=True
        if not touches_edge:
            interior_small+=1
print(f"small(<=5) water bodies: {small_water_total}, of which fully interior (lakes/ponds): {interior_small}")

# land components (continents)
seen3=set(); land_comps=[]
for key,(t,iw,elev) in cells.items():
    if iw or key in seen3: continue
    stack=[key]; seen3.add(key); size=0
    while stack:
        cur=stack.pop(); size+=1
        for nb in nbrs(*cur):
            if nb in cells and not cells[nb][1] and nb not in seen3:
                seen3.add(nb); stack.append(nb)
    land_comps.append(size)
land_comps.sort(reverse=True)
print(f"\n=== land masses (continents/islands) ===")
print(f"total land components: {len(land_comps)}; sizes top10: {land_comps[:10]}")
tiny_islands=sum(1 for s in land_comps if s<=2)
print(f"tiny islands(<=2): {tiny_islands}")
