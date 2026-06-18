import csv, collections
PATH = r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260619_032716.csv"
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
terr=[int(float(x["terrain_arr"])) for x in rows]
elev=[fnum(x["elevation_arr"]) for x in rows]
SEA=0.42
WATER={0,1,18,19,20,21}
TN={0:"OCEAN",1:"COAST",18:"LAKE",19:"REEF",20:"SEA_ICE",21:"KELP",2:"PLAIN",3:"GRASS",4:"FOREST",5:"HILL",6:"MOUNTAIN",7:"DESERT",8:"TUNDRA",9:"SNOW"}
# elevation of water cells: distribution
water_e=sorted(elev[i] for i in range(n) if terr[i] in WATER)
land_e=sorted(elev[i] for i in range(n) if terr[i] not in WATER)
print(f"sea_level={SEA}")
print(f"water cells: n={len(water_e)} E: min={water_e[0]:.3f} p50={water_e[len(water_e)//2]:.3f} max={water_e[-1]:.3f}")
print(f"land  cells: n={len(land_e)} E: min={land_e[0]:.3f} p50={land_e[len(land_e)//2]:.3f} max={land_e[-1]:.3f}")
# land cells below sea? (drained-to-land signature: terrain=land but E<sea)
land_below=[i for i in range(n) if terr[i] not in WATER and elev[i] < SEA]
print(f"LAND cells with E<sea({SEA}): {len(land_below)}  (these = drained-to-land, terrain=land at low E)")
if land_below:
    tb=collections.Counter(terr[i] for i in land_below)
    print("   their terrain:", {TN.get(k,k):v for k,v in tb.most_common()})
    es=sorted(elev[i] for i in land_below)
    print(f"   their E: min={es[0]:.3f} med={es[len(es)//2]:.3f} max={es[-1]:.3f}")
# COAST cells exact elevation histogram
coast_e=collections.Counter(round(elev[i],3) for i in range(n) if terr[i]==1)
print("COAST elevation histogram (top values):", coast_e.most_common(8))
ocean_e=collections.Counter(round(elev[i],3) for i in range(n) if terr[i]==0)
print("OCEAN distinct elev count:", len(ocean_e), " sample:", ocean_e.most_common(4))
