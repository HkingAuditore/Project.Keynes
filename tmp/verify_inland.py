import csv, collections, sys
PATH = r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260619_032716.csv"
allrows=[]
with open(PATH, newline="") as f:
    rd=csv.DictReader(f)
    cols=rd.fieldnames
    for row in rd: allrows.append(row)
print("has columns:", [c for c in cols if 'storage' in c or 'q30' in c or 'discharge' in c or 'tick' in c.lower()][:10])
ci=[int(float(x["cell_index"])) for x in allrows]
ncells=max(ci)+1
starts=[i for i in range(len(allrows)) if ci[i]==0]
print(f"snapshots in file: {len(starts)}  ncells={ncells}  total_rows={len(allrows)}")
s0=starts[-1]; rows=allrows[s0:s0+ncells]; n=len(rows)
def col(nm): return [x[nm] for x in rows]
def fnum(s):
    try:return float(s)
    except:return 0.0
q=[int(float(x)) for x in col("q")]; rr=[int(float(x)) for x in col("r")]
terr=[int(float(x)) for x in col("terrain_arr")]
elev=[fnum(x) for x in col("elevation_arr")]
cidx=[int(float(x)) for x in col("cell_index")]
height=max(rr)+1; width=n//height
pos={cidx[i]:i for i in range(n)}
DQ=[1,1,0,-1,-1,0]; DR=[0,-1,-1,0,1,1]
def idx_qr(qq,rrr):
    c=qq+((rrr-(rrr&1))//2)
    if c<0 or c>=width or rrr<0 or rrr>=height: return -1
    return pos.get(rrr*width+c,-1)
NB=[[idx_qr(q[i]+DQ[d],rr[i]+DR[d]) for d in range(6)] for i in range(n)]
avgnb=sum(1 for i in range(n) for ni in NB[i] if ni>=0)/n
print(f"grid {width}x{height} avg_neighbors={avgnb:.2f} (should be ~5.7-5.9)")
WATER={0,1,18,19,20,21}
# border-connected water
bc=[False]*n; st=[]
for i in range(n):
    cc=q[i]+((rr[i]-(rr[i]&1))//2)
    if terr[i] in WATER and (rr[i] in(0,height-1) or cc in(0,width-1)):
        bc[i]=True; st.append(i)
while st:
    c=st.pop()
    for ni in NB[c]:
        if ni>=0 and not bc[ni] and terr[ni] in WATER: bc[ni]=True; st.append(ni)
nbc=sum(1 for i in range(n) if bc[i])
nwater=sum(1 for i in range(n) if terr[i] in WATER)
print(f"water cells={nwater} border-connected={nbc} inland(not connected)={nwater-nbc}")
# inland water terrain + sizes
seen=[False]*n; comps=[]
for s in range(n):
    if terr[s] in WATER and not bc[s] and not seen[s]:
        stk=[s];seen[s]=True;cs=[]
        while stk:
            c=stk.pop();cs.append(c)
            for ni in NB[c]:
                if ni>=0 and terr[ni] in WATER and not bc[ni] and not seen[ni]: seen[ni]=True;stk.append(ni)
        comps.append(cs)
tb=collections.Counter()
for cs in comps:
    for c in cs: tb[terr[c]]+=1
TN={0:"OCEAN",1:"COAST",18:"LAKE",20:"SEA_ICE"}
print(f"inland bodies={len(comps)} terr={{{', '.join(f'{TN.get(k,k)}:{v}' for k,v in tb.most_common())}}}")
# for the COAST inland cells, how deep below sea? and are neighbors mostly land?
coast_inland=[i for i in range(n) if terr[i]==1 and not bc[i]]
if coast_inland:
    depths=sorted(0.64-elev[i] for i in coast_inland)
    landnb=sum(1 for i in coast_inland for ni in NB[i] if ni>=0 and terr[ni] not in WATER)/max(1,len(coast_inland))
    print(f"inland COAST={len(coast_inland)} depth_below_sea: min={depths[0]:.3f} med={depths[len(depths)//2]:.3f} max={depths[-1]:.3f}; avg land-neighbors={landnb:.1f}/6")
