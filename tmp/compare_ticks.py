import csv, collections
PATH = r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260619_032716.csv"
allrows=[]
with open(PATH, newline="") as f:
    rd=csv.DictReader(f)
    for row in rd: allrows.append(row)
ci=[int(float(x["cell_index"])) for x in allrows]
ncells=max(ci)+1
starts=[i for i in range(len(allrows)) if ci[i]==0]
WATER={0,1,18,19,20,21}
def fnum(s):
    try:return float(s)
    except:return 0.0
def analyze(s0,label):
    rows=allrows[s0:s0+ncells]; n=len(rows)
    q=[int(float(x["q"])) for x in rows]; rr=[int(float(x["r"])) for x in rows]
    terr=[int(float(x["terrain_arr"])) for x in rows]
    cidx=[int(float(x["cell_index"])) for x in rows]
    tick=rows[0].get("tick_idx","?")
    height=max(rr)+1; width=n//height
    pos={cidx[i]:i for i in range(n)}
    DQ=[1,1,0,-1,-1,0]; DR=[0,-1,-1,0,1,1]
    def idx_qr(qq,rrr):
        c=qq+((rrr-(rrr&1))//2)
        if c<0 or c>=width or rrr<0 or rrr>=height: return -1
        return pos.get(rrr*width+c,-1)
    NB=[[idx_qr(q[i]+DQ[d],rr[i]+DR[d]) for d in range(6)] for i in range(n)]
    bc=[False]*n; st=[]
    for i in range(n):
        cc=q[i]+((rr[i]-(rr[i]&1))//2)
        if terr[i] in WATER and (rr[i] in(0,height-1) or cc in(0,width-1)):
            bc[i]=True; st.append(i)
    while st:
        c=st.pop()
        for ni in NB[c]:
            if ni>=0 and not bc[ni] and terr[ni] in WATER: bc[ni]=True; st.append(ni)
    inland=[i for i in range(n) if terr[i] in WATER and not bc[i]]
    tb=collections.Counter(terr[i] for i in inland)
    TN={0:"OCEAN",1:"COAST",18:"LAKE",20:"SEA_ICE"}
    print(f"[{label}] tick={tick} inland_water={len(inland)} {{{', '.join(f'{TN.get(k,k)}:{v}' for k,v in tb.most_common())}}}")
analyze(starts[0],"FIRST")
analyze(starts[len(starts)//2],"MID")
analyze(starts[-1],"LAST")
print(f"total snapshots={len(starts)}")
