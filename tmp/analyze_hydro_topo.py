import csv, collections, statistics, sys
PATH = sys.argv[1] if len(sys.argv)>1 else r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260619_015035.csv"
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
if len(rows)<ncells: rows=allrows[starts[-2]:starts[-2]+ncells]
n=len(rows)
def col(nm): return [x[nm] for x in rows]
q=[int(float(x)) for x in col("q")]; rr=[int(float(x)) for x in col("r")]
terr=[int(float(x)) for x in col("terrain_arr")]
isw=[int(float(x)) for x in col("is_water_arr")]
elev=[fnum(x) for x in col("elevation_arr")]
hasriver=[fnum(x) for x in col("has_river_arr")]
disch=[fnum(x) for x in col("river_discharge_arr")]
parent=[int(float(x)) for x in col("hydro_parent_arr")]
cidx=[int(float(x)) for x in col("cell_index")]
height=max(rr)+1; width=n//height
print(f"grid {width}x{height}, n={n}")
pos={cidx[i]:i for i in range(n)}
DQ=[1,1,0,-1,-1,0]; DR=[0,-1,-1,0,1,1]
def idx_qr(qq,rrr):
    c=qq+((rrr-(rrr&1))//2)
    if c<0 or c>=width or rrr<0 or rrr>=height: return -1
    return pos.get(rrr*width+c,-1)
NB=[[idx_qr(q[i]+DQ[d],rr[i]+DR[d]) for d in range(6)] for i in range(n)]

def comps(pred):
    seen=[False]*n; out=[]
    for s in range(n):
        if pred(s) and not seen[s]:
            st=[s];seen[s]=True;cs=[]
            while st:
                c=st.pop();cs.append(c)
                for ni in NB[c]:
                    if ni>=0 and pred(ni) and not seen[ni]: seen[ni]=True;st.append(ni)
            out.append(cs)
    return out

# ---- LAKES ----
lakes=comps(lambda i: terr[i]==18)
ls=sorted([len(c) for c in lakes],reverse=True)
print(f"\n=== LAKES (terrain==18): {len(lakes)} components, total {sum(ls)} cells ===")
print(f"  sizes: {ls[:20]}")
print(f"  size buckets: 1={sum(1 for s in ls if s==1)} 2-3={sum(1 for s in ls if 2<=s<=3)} 4-8={sum(1 for s in ls if 4<=s<=8)} 9+={sum(1 for s in ls if s>=9)}")

# ---- ALL inland water (lake+ocean not connected to border) ----
TERR = {0:"OCEAN",1:"COAST",18:"LAKE",19:"REEF",20:"SEA_ICE",21:"KELP"}
wt=lambda i: terr[i] in (0,1,18,19,20,21)
seen=[False]*n; inland=[]; inland_terr=collections.Counter(); inland_below_sea=0
sea_level=0.64
for s in range(n):
    if wt(s) and not seen[s]:
        st=[s];seen[s]=True;cs=[];border=False
        while st:
            c=st.pop();cs.append(c)
            cc=q[c]+((rr[c]-(rr[c]&1))//2)
            if rr[c] in (0,height-1) or cc in (0,width-1): border=True
            for ni in NB[c]:
                if ni>=0 and wt(ni) and not seen[ni]: seen[ni]=True;st.append(ni)
        if not border:
            inland.append(len(cs))
            for c in cs:
                inland_terr[terr[c]]+=1
                if elev[c]<sea_level: inland_below_sea+=1
inland.sort(reverse=True)
print(f"\n=== inland water bodies (any terrain, not border): {len(inland)} sizes={inland[:15]}")
print(f"  inland water terrain breakdown: {{ {', '.join(f'{TERR.get(k,k)}:{v}' for k,v in inland_terr.most_common())} }}")
print(f"  inland water cells below sea_level({sea_level}): {inland_below_sea} / {sum(inland_terr.values())}")

# ---- RIVER TOPOLOGY ----
isriver=[hasriver[i]>0.5 for i in range(n)]
nriv=sum(isriver)
print(f"\n=== RIVERS: {nriv} cells ({100*nriv/n:.2f}%) ===")
# downstream via hydro_parent
def downstream(i):
    p=parent[i]
    return p if (p>=0 and p<n) else -1
# build upstream count (how many river cells point to this one)
indeg=[0]*n
for i in range(n):
    if isriver[i]:
        d=downstream(i)
        if d>=0 and isriver[d]: indeg[d]+=1
# headwaters = river cell with no river upstream
heads=[i for i in range(n) if isriver[i] and indeg[i]==0]
print(f"  headwaters (no upstream river): {len(heads)}")
# trace each head downstream to terminus, measure length + terminus type
lengths=[]; term_lake=0; term_ocean=0; term_other=0; term_dryup=0
longest=0; longest_path=None
for h in heads:
    cur=h; L=0; seen_path=set()
    while cur>=0 and cur not in seen_path:
        seen_path.add(cur); 
        if isriver[cur]: L+=1
        d=downstream(cur)
        if d<0: term_dryup+=1; break
        td=terr[d]
        if td==18: term_lake+=1; break
        if td in (0,1,19,20,21): term_ocean+=1; break
        if not isriver[d]:
            # river ends but parent is land (shouldn't draw further)
            term_other+=1; break
        cur=d
    lengths.append(L)
    if L>longest: longest=L; longest_path=h
lengths.sort(reverse=True)
print(f"  head-to-terminus river path lengths: top={lengths[:15]}")
print(f"  mean={statistics.mean(lengths):.1f} median={statistics.median(lengths):.1f} max={longest}")
print(f"  terminus: ocean={term_ocean} lake={term_lake} dryup={term_dryup} other={term_other}")

# Strahler order approximation
# compute order bottom-up: order = max child order, +1 if >=2 children share max
order=[0]*n
# topological: process by elevation descending (upstream first)
riv_cells=[i for i in range(n) if isriver[i]]
riv_cells.sort(key=lambda i: -elev[i])
children=collections.defaultdict(list)
for i in riv_cells:
    d=downstream(i)
    if d>=0 and isriver[d]: children[d].append(i)
for i in riv_cells:
    ch=children.get(i,[])
    if not ch: order[i]=1
    else:
        mx=max(order[c] for c in ch)
        cntmx=sum(1 for c in ch if order[c]==mx)
        order[i]=mx+1 if cntmx>=2 else mx
from collections import Counter
oc=Counter(order[i] for i in riv_cells)
print(f"  Strahler order distribution: {dict(sorted(oc.items()))}")
print(f"  max Strahler order: {max(order[i] for i in riv_cells) if riv_cells else 0}  (>=3 means real main-stem+tributaries)")

# discharge distribution along rivers (width proxy)
rd=sorted([disch[i] for i in riv_cells if disch[i]==disch[i]],reverse=True)
if rd:
    print(f"  river discharge: max={rd[0]:.3f} p50={rd[len(rd)//2]:.3f} p90={rd[len(rd)//10]:.3f} min={rd[-1]:.3f}")

# how many river cells are adjacent to a lake (rivers fragmented by lakes)
adj_lake=sum(1 for i in riv_cells if any(ni>=0 and terr[ni]==18 for ni in NB[i]))
print(f"  river cells adjacent to a lake: {adj_lake} ({100*adj_lake/max(nriv,1):.0f}%)")

# MOUNTAIN macro
mt=comps(lambda i: terr[i]==6)
mts=sorted([len(c) for c in mt],reverse=True)
print(f"\n=== MOUNTAIN terrain comps: {len(mt)} top={mts[:10]} ===")
