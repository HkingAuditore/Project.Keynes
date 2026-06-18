import csv, collections, math, sys

PATH = r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260618_231047.csv"

TERR = {0:"OCEAN",1:"COAST",2:"PLAIN",3:"GRASSLAND",4:"FOREST",5:"HILL",6:"MOUNTAIN",
7:"DESERT",8:"TUNDRA",9:"SNOW",10:"SWAMP",11:"JUNGLE",12:"SAVANNA",13:"TAIGA",14:"STEPPE",
15:"SHRUBLAND",16:"MANGROVE",17:"GLACIER",18:"LAKE",19:"REEF",20:"SEA_ICE",21:"KELP",
22:"DELTA",23:"OASIS",24:"SALT_FLAT",25:"BADLANDS",26:"COLD_DESERT",27:"CHAPARRAL",
28:"MOOR",29:"FLOODPLAIN",30:"MESA"}
LF = {0:"DEEP_OCEAN",1:"OCEAN",2:"COAST",3:"LAKE",4:"PLAIN",5:"LOWLAND",6:"HILL",
7:"MOUNTAIN",8:"PEAK",9:"DELTA",10:"BADLANDS",11:"SALT_FLAT",12:"VOLCANO",13:"PLATEAU",14:"RIFT_VALLEY"}
VEG = {0:"NONE",1:"POLAR_DESERT",2:"TUNDRA",3:"ALPINE_TUNDRA",4:"ALPINE_MEADOW",5:"TAIGA",
6:"BOREAL_SHRUB",7:"TEMP_DECID",8:"TEMP_CONIFER",9:"TEMP_GRASS",10:"TEMP_STEPPE",
11:"MED_SHRUB",12:"SUBTROP_FOREST",13:"SAVANNA",14:"TROP_RAINFOREST",15:"TROP_DRY_FOREST",
16:"DESERT_SCRUB",17:"XERIC_DESERT",18:"OASIS_VEG",19:"MANGROVE",20:"SWAMP",21:"MARSH",
22:"KELP",23:"CORAL",24:"CLOUD_FOREST",25:"MONSOON_FOREST",26:"SEAGRASS",27:"PEAT_BOG"}

def fnum(s):
    try: return float(s)
    except: return float("nan")

rows = []
with open(PATH, newline="") as f:
    r = csv.DictReader(f)
    cols = r.fieldnames
    for row in r:
        rows.append(row)
n = len(rows)
print("rows:", n)

terr = [int(float(x["terrain_arr"])) for x in rows if x["terrain_arr"] not in ("","nan")]
baseterr = [int(float(x["base_terrain_arr"])) for x in rows if x["base_terrain_arr"] not in ("","nan")]
lf = [int(float(x["landform_arr"])) for x in rows if x["landform_arr"] not in ("","nan")]
veg = [int(float(x["vegetation_arr"])) for x in rows if x["vegetation_arr"] not in ("","nan")]
isw = [int(float(x["is_water_arr"])) for x in rows if x["is_water_arr"] not in ("","nan")]
elev = [fnum(x["elevation_arr"]) for x in rows]
moist = [fnum(x["moisture_arr"]) for x in rows]
basem = [fnum(x["base_moisture_arr"]) for x in rows]
temp = [fnum(x["temp_arr"]) for x in rows]
lat = [fnum(x["cell_lat_norm_arr"]) for x in rows]
hasriver = [fnum(x["has_river_arr"]) for x in rows]
disch = [fnum(x["river_discharge_arr"]) for x in rows]

N = len(terr)
def dist(label, arr, names):
    c = collections.Counter(arr)
    print(f"\n=== {label} (N={len(arr)}) ===")
    for k,v in c.most_common():
        print(f"  {names.get(k,k):16s} {v:6d}  {100.0*v/len(arr):5.1f}%")

water = sum(1 for x in isw if x==1)
print(f"\nwater cells: {water} ({100.0*water/len(isw):.1f}%)  land: {len(isw)-water} ({100.0*(len(isw)-water)/len(isw):.1f}%)")

dist("TERRAIN", terr, TERR)
dist("BASE_TERRAIN", baseterr, TERR)
dist("LANDFORM", lf, LF)
dist("VEGETATION", veg, VEG)

# rivers
rc = sum(1 for x in hasriver if x and x>0.5)
print(f"\nhas_river cells: {rc} ({100.0*rc/len(hasriver):.2f}%)")
dpos = [d for d in disch if d==d and d>0]
print(f"river_discharge>0: {len(dpos)}  max={max(dpos) if dpos else 0:.3f}")

# elevation distribution
import statistics
ev = [e for e in elev if e==e]
print(f"\nelevation: min={min(ev):.3f} med={statistics.median(ev):.3f} max={max(ev):.3f} mean={statistics.mean(ev):.3f}")
# histogram
bins=[0]*11
for e in ev:
    b=min(10,int(e*10))
    bins[b]+=1
print("elev hist (0.0-1.0 by 0.1):", bins)

mv=[m for m in moist if m==m]
print(f"moisture: min={min(mv):.3f} med={statistics.median(mv):.3f} max={max(mv):.3f} mean={statistics.mean(mv):.3f}")
bmv=[m for m in basem if m==m]
print(f"base_moisture: min={min(bmv):.3f} med={statistics.median(bmv):.3f} max={max(bmv):.3f} mean={statistics.mean(bmv):.3f}")
tv=[t for t in temp if t==t]
print(f"temp: min={min(tv):.3f} med={statistics.median(tv):.3f} max={max(tv):.3f} mean={statistics.mean(tv):.3f}")

# sea level inference: water vs elevation
# print elevation by water status
ew=[elev[i] for i in range(N) if isw[i]==1 and elev[i]==elev[i]]
el=[elev[i] for i in range(N) if isw[i]==0 and elev[i]==elev[i]]
if ew: print(f"\nwater elev: med={statistics.median(ew):.3f} max={max(ew):.3f}")
if el: print(f"land  elev: med={statistics.median(el):.3f} min={min(el):.3f}")

# biome entropy on land
landterr=[terr[i] for i in range(N) if isw[i]==0]
c=collections.Counter(landterr)
ent=0.0
for k,v in c.items():
    p=v/len(landterr); ent-=p*math.log2(p)
print(f"\nland terrain entropy: {ent:.3f} bits, distinct={len(c)}")
