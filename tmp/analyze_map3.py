import csv, collections
path = r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260618_213653.csv"
TERR = {0:"OCEAN",1:"COAST",2:"PLAIN",3:"GRASS",4:"FOREST",5:"HILL",6:"MTN",7:"DESERT",8:"TUNDRA",9:"SNOW",10:"SWAMP",11:"JUNGLE",12:"SAVANNA",13:"TAIGA",14:"STEPPE",15:"SHRUB",16:"MANGROVE",17:"GLACIER",18:"LAKE",19:"REEF",20:"SEAICE",21:"KELP",22:"DELTA",23:"OASIS",24:"SALT",25:"BAD"}
with open(path, newline='') as f:
    r=csv.reader(f); h=next(r); hi={n:i for i,n in enumerate(h)}
    cells={}; maxidx=-1
    for row in r:
        ci=int(row[hi["cell_index"]])
        if ci<=maxidx and maxidx>100: break
        maxidx=ci
        cells[(int(row[hi["q"]]),int(row[hi["r"]]))]=(int(row[hi["terrain_arr"]]),int(row[hi["is_water_arr"]]),int(row[hi["base_terrain_arr"]]),float(row[hi["elevation_arr"]]))
DQ=[1,1,0,-1,-1,0]; DR=[0,-1,-1,0,1,1]
def nbrs(q,r):
    for dq,dr in zip(DQ,DR): yield (q+dq,r+dr)
# find single-tile water bodies, classify neighbor make-up
seen=set(); allland=0; partial=0; samples=[]
neigh_terr=collections.Counter()
for key,v in cells.items():
    if not v[1] or key in seen: continue
    stack=[key]; seen.add(key); comp=[key]
    while stack:
        cur=stack.pop()
        for nb in nbrs(*cur):
            if nb in cells and cells[nb][1] and nb not in seen:
                seen.add(nb); stack.append(nb); comp.append(nb)
    if len(comp)==1:
        c=comp[0]; land_nb=0; water_nb=0; missing=0
        for nb in nbrs(*c):
            if nb not in cells: missing+=1
            elif cells[nb][1]: water_nb+=1
            else: land_nb+=1; neigh_terr[cells[nb][0]]+=1
        if water_nb==0 and missing==0:
            allland+=1
            if len(samples)<8: samples.append((c,cells[c],[ (nb,TERR.get(cells[nb][0])) for nb in nbrs(*c) if nb in cells]))
        else: partial+=1
print(f"single-tile water bodies: fully surrounded by land = {allland}, touching other water/edge = {partial}")
print("neighbor terrain types around fully-interior single water specks:")
for t,c in neigh_terr.most_common(): print(f"  {TERR.get(t,t):8} {c}")
print("\nsamples (cell, (terr,iw,baseterr,elev), neighbors):")
for s in samples:
    c,info,nb=s
    print(f"  q={c[0]} r={c[1]} terr={TERR.get(info[0])} base={TERR.get(info[2])} elev={info[3]:.3f}  nbrs={[x[1] for x in nb]}")
