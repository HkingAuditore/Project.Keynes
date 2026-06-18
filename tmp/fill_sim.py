import csv, collections
PATH = r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260619_032716.csv"
SEA=0.42; LAKE_MIN=8
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
q=[int(float(x["q"])) for x in rows]; rr=[int(float(x["r"])) for x in rows]
elev=[fnum(x["elevation_arr"]) for x in rows]
cidx=[int(float(x["cell_index"])) for x in rows]
height=max(rr)+1; width=n//height
pos={cidx[i]:i for i in range(n)}
DQ=[1,1,0,-1,-1,0]; DR=[0,-1,-1,0,1,1]
def idx_qr(qq,rrr):
    c=qq+((rrr-(rrr&1))//2)
    if c<0 or c>=width or rrr<0 or rrr>=height: return -1
    return pos.get(rrr*width+c,-1)
NB=[[idx_qr(q[i]+DQ[d],rr[i]+DR[d]) for d in range(6)] for i in range(n)]
# replicate base-pass fill: border BFS over E<sea -> ocean_e
ocean=[False]*n; st=[]
for i in range(n):
    cc=q[i]+((rr[i]-(rr[i]&1))//2)
    if elev[i]<SEA and (rr[i] in(0,height-1) or cc in(0,width-1)):
        ocean[i]=True; st.append(i)
while st:
    c=st.pop()
    for ni in NB[c]:
        if ni>=0 and not ocean[ni] and elev[ni]<SEA: ocean[ni]=True; st.append(ni)
# inland below-sea components
seen=[False]*n; filled_bodies=0; filled_cells=0; kept_bodies=0; kept_cells=0; kept_sizes=[]
for s in range(n):
    if elev[s]>=SEA or ocean[s] or seen[s]: continue
    comp=[s]; seen[s]=True
    for c in comp:
        for ni in NB[c]:
            if ni>=0 and not seen[ni] and not ocean[ni] and elev[ni]<SEA:
                seen[ni]=True; comp.append(ni)
    if len(comp)<LAKE_MIN:
        filled_bodies+=1; filled_cells+=len(comp)
    else:
        kept_bodies+=1; kept_cells+=len(comp); kept_sizes.append(len(comp))
print(f"=== FILL SIMULATION (sea={SEA}, lake_min={LAKE_MIN}) ===")
print(f"BEFORE: inland below-sea bodies would be {filled_bodies+kept_bodies}")
print(f"FILLED (raised to land): {filled_bodies} bodies, {filled_cells} cells  <-- the '零碎湖' eliminated")
print(f"KEPT  (become inland LAKE): {kept_bodies} bodies, {kept_cells} cells  sizes={sorted(kept_sizes,reverse=True)}")
