import csv, math
def i(x):
    try: return int(x)
    except: return 0
rows=list(csv.DictReader(open("economy_record_20260722_101856_v16_cell622_q17_r10_market.csv",encoding="utf-8-sig")))
from collections import defaultdict
byep=defaultdict(dict)
for r in rows:
    byep[int(r["epoch_row_id"])][r["good_id"]]=(i(r["price"]),i(r["cost_anchor_price"]))
keys=sorted(byep)
def series(good):
    xs=[];ys=[];ya=[]
    for k in keys:
        if good in byep[k]:
            p,a=byep[k][good]
            xs.append(k); ys.append(max(1,p)); ya.append(a)
    return xs,ys,ya

W,H=920,420
def xmap(k): return 60+(k-keys[0])/(keys[-1]-keys[0])*(W-90)
LO,HI=0,9.5
def ymap(v):
    lg=math.log10(v)
    return (H-40)-(lg-LO)/(HI-LO)*(H-60)
def poly(xs,ys):
    pts=[]
    for x,y in zip(xs,ys):
        if y<=0: continue
        pts.append("%s,%s"%(round(xmap(x),1),round(ymap(y),1)))
    return " ".join(pts)

goods=["logs","chipped_stone_tools","cloth","fur"]
colors={"logs":"#ff4d4f","chipped_stone_tools":"#ff9f40","cloth":"#40a9ff","fur":"#52c41a"}
svg=['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" font-family="monospace" font-size="11">'%(W,H)]
svg.append('<rect x="0" y="0" width="%d" height="%d" fill="#0e1116"/>'%(W,H))
svg.append('<text x="%d" y="20" fill="#e6e6e6" text-anchor="middle" font-size="13">price runaway trajectory (cell 622, log10 price vs epoch_row)</text>'%(W/2))
for e in range(0,10):
    yy=ymap(10**e)
    svg.append('<line x1="60" y1="%.1f" x2="%d" y2="%.1f" stroke="#222" />'%(yy,W-30,yy))
    svg.append('<text x="8" y="%.1f" fill="#888">%d</text>'%(yy+3,10**e))
for k in [1,500,1000,1500,1915]:
    if k in keys or k==keys[-1]:
        xx=xmap(k)
        svg.append('<line x1="%.1f" y1="40" x2="%.1f" y2="%d" stroke="#1a1a1a"/>'%(xx,xx,H-40))
        svg.append('<text x="%.1f" y="%d" fill="#888" text-anchor="middle">%d</text>'%(xx,H-22,k))
for g in goods:
    xs,ys,ya=series(g)
    svg.append('<polyline points="%s" fill="none" stroke="%s" stroke-width="2"/>'%(poly(xs,ys),colors[g]))
    if g in ("logs","chipped_stone_tools"):
        svg.append('<polyline points="%s" fill="none" stroke="%s" stroke-width="1" stroke-dasharray="3,3" opacity="0.6"/>'%(poly(xs,ya),colors[g]))
ly=40
for g in goods:
    svg.append('<rect x="%d" y="%d" width="10" height="10" fill="%s"/>'%(W-200,ly,colors[g]))
    svg.append('<text x="%d" y="%d" fill="#ccc">%s</text>'%(W-185,ly+9,g))
    ly+=16
svg.append('<text x="%d" y="%d" fill="#888" font-size="10">dashed = cost_anchor (production cost floor);</text>'%(W-200,ly+6))
svg.append('<text x="%d" y="%d" fill="#888" font-size="10">anchor rises with inflation -> positive feedback</text>'%(W-200,ly+18))
svg.append('</svg>')
open("price_runaway_cell622.svg","w").write("\n".join(svg))
print("wrote price_runaway_cell622.svg")
s=series("logs")[1]
print("logs price: ep1=%d ep400=%d ep600=%d ep800=%d end=%d"%(s[0],s[2],s[3],s[4],s[-1]))
print("chipped end=%d (INT32_MAX=%d)"%(series("chipped_stone_tools")[1][-1],2147483647))
