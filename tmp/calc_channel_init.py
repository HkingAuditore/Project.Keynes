import csv, collections, sys
PATH = r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260619_024123.csv"
def fnum(s):
    try: return float(s)
    except: return float("nan")
allrows=[]
with open(PATH, newline="") as f:
    for row in csv.DictReader(f): allrows.append(row)
ci=[int(float(x["cell_index"])) for x in allrows]
ncells=max(ci)+1
starts=[i for i in range(len(allrows)) if ci[i]==0]
s0=starts[-1]
rows=allrows[s0:s0+ncells]
n=len(rows)
def col(nm): return [x[nm] for x in rows]
terr=[int(float(x)) for x in col("terrain_arr")]
parent=[int(float(x)) for x in col("hydro_parent_arr")]
cidx=[int(float(x)) for x in col("cell_index")]
rr=[int(float(x)) for x in col("r")]
elev=[fnum(x) for x in col("elevation_arr")]
height=max(rr)+1; width=n//height
WATER={0,1,18,19,20,21}
land=[i for i in range(n) if terr[i] not in WATER]
nland=len(land)
print(f"grid {width}x{height} n={n} land={nland} ({100*nland/n:.0f}%)")

# up_count via accumulation down hydro_parent, processing high-elev first (upstream first)
order=sorted(range(n), key=lambda i: -elev[i])
up=[0]*n
for i in land: up[i]=1
# need pos map for parent validity (parent is a cell index already, same indexing)
for i in order:
    if up[i]==0: continue
    p=parent[i]
    if p<0 or p>=n: continue
    up[p]+=up[i]

# how many LAND cells have up>=T  -> these would be river cells
for T in [8,12,16,20,24,28,32,40,50,64]:
    cnt=sum(1 for i in land if up[i]>=T)
    print(f"  channel_init={T:3d} -> river land cells={cnt:5d}  ({100*cnt/n:.2f}% of map, {100*cnt/nland:.1f}% of land)")

# distribution of up among land
ups=sorted((up[i] for i in land), reverse=True)
print(f"  up_count land: max={ups[0]} p99={ups[int(nland*0.01)]} p95={ups[int(nland*0.05)]} p90={ups[int(nland*0.10)]} median={ups[nland//2]}")
