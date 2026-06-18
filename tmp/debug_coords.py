import csv, statistics
PATH = r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260619_015035.csv"
rows=[]
with open(PATH, newline="") as f:
    r=csv.DictReader(f)
    for row in r: rows.append(row)
n=len(rows)
ci=[int(float(x["cell_index"])) for x in rows]
q=[int(float(x["q"])) for x in rows]
rr=[int(float(x["r"])) for x in rows]
print("n=",n)
print("cell_index: min",min(ci),"max",max(ci),"contiguous?",sorted(ci)==list(range(min(ci),min(ci)+n)))
print("q range",min(q),max(q),"  r range",min(rr),max(rr))
# first 8 and check ordering
print("\nfirst 10 (pos: cell_index q r):")
for i in range(10): print(f"  {i}: ci={ci[i]} q={q[i]} r={rr[i]}")
# is csv sorted by cell_index?
print("\ncsv sorted by cell_index?", ci==sorted(ci))
# guess height: count distinct r, and how many cells per r
from collections import Counter
rc=Counter(rr)
print("distinct r:",len(rc)," cells per r (first 5):",[rc[k] for k in sorted(rc)[:5]])
qc=Counter(q)
print("distinct q:",len(qc)," cells per q (first 5):",[qc[k] for k in sorted(qc)[:5]])
# Try: width from cells-per-row
import statistics as st
heights=len(rc); widths=n//heights
print(f"\nimplied height(distinct r)={heights} width={widths}")
# verify cell_index == r*width + col  where col = q + (r-(r&1))//2
ok=0; bad=0; badsamples=[]
for i in range(n):
    col=q[i]+((rr[i]-(rr[i]&1))//2)
    lin=rr[i]*widths+col
    if lin==ci[i]: ok+=1
    else:
        bad+=1
        if len(badsamples)<5: badsamples.append((ci[i],q[i],rr[i],col,lin))
print(f"cell_index == r*width+col : ok={ok} bad={bad}")
print("bad samples (ci,q,r,col,lin):",badsamples)
# alt: maybe col = q + (r - (r&1))//2 but offset differently, or index = col*height + r
ok2=0
for i in range(n):
    col=q[i]+((rr[i]-(rr[i]&1))//2)
    if col*heights+rr[i]==ci[i]: ok2+=1
print("cell_index == col*height+r :",ok2)
# alt: offset coords directly: maybe q already is col
ok3=0
for i in range(n):
    if rr[i]*widths+q[i]==ci[i]: ok3+=1
print("cell_index == r*width+q :",ok3)
