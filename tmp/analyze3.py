# -*- coding: utf-8 -*-
import csv, math, sys
from collections import defaultdict
PATH=r"D:/Godot/ProjectKeynes/Project.Keynes/tmp/tile_data_record_20260608_184710.csv"
C={'tick':1,'temp':13,'elev':49,'ocx':51,'ocy':52,'psi':59,'px':60,'py':61,'lat':62,'is_water':72,'wx':53,'wy':54,'upw':57}
def f(x):
    try:return float(x)
    except:return float('nan')

# continentality: land vs ocean seasonal temp amplitude in mid-lat band ny in [0.65,0.80]
# track per-cell min/max temp over run, then average over land vs ocean
cell_minmax={}  # (need cell id) use px,py rounded as key proxy -> better use cell index col 9
Ccell=9
landamp=[0.0,0]; oceanamp=[0.0,0]
cmm=defaultdict(lambda:[1e9,-1e9,0,0.0,0])  # cell->[min,max,is_water,sum_elev?,n]
band_lo,band_hi=0.62,0.82
with open(PATH,'r',encoding='utf-8-sig',newline='') as fh:
    rd=csv.reader(fh); next(rd)
    for row in rd:
        if len(row)<73:continue
        ny=f(row[C['lat']])
        if not (band_lo<=ny<=band_hi):continue
        cid=row[Ccell]; t=f(row[C['temp']]); iw=f(row[C['is_water']])
        r=cmm[cid]
        if t<r[0]:r[0]=t
        if t>r[1]:r[1]=t
        r[2]=iw; r[4]+=1
for cid,r in cmm.items():
    if r[4]<10:continue
    amp=r[1]-r[0]
    if r[2]>0.5: oceanamp[0]+=amp;oceanamp[1]+=1
    else: landamp[0]+=amp;landamp[1]+=1
print(f"CONTINENTALITY (mid-lat ny~0.62-0.82): land seasonal temp amp={landamp[0]/max(landamp[1],1):.3f} (n={landamp[1]}), ocean amp={oceanamp[0]/max(oceanamp[1],1):.3f} (n={oceanamp[1]})")

# ocean gyre spatial: take one tick=546, bin ocean current by (ny band, x-third) to see east/west
import collections
TICK=546
NB=10; NX=3
gy=collections.defaultdict(lambda:[0.0,0.0,0,0.0]) # (b,xi)->[sumocx,sumocy,n,sumpsi]
xs=[]
rows=[]
with open(PATH,'r',encoding='utf-8-sig',newline='') as fh:
    rd=csv.reader(fh); next(rd)
    for row in rd:
        if len(row)<73:continue
        if int(f(row[C['tick']]))!=TICK:continue
        rows.append(row)
        xs.append(f(row[C['px']]))
xmin,xmax=min(xs),max(xs)
for row in rows:
    ny=f(row[C['lat']]); px=f(row[C['px']])
    if f(row[C['is_water']])<0.5: continue
    b=min(int(ny*NB),NB-1)
    xi=min(int((px-xmin)/(xmax-xmin+1e-9)*NX),NX-1)
    g=gy[(b,xi)]; g[0]+=f(row[C['ocx']]); g[1]+=f(row[C['ocy']]); g[2]+=1; g[3]+=f(row[C['psi']])
print(f"\n=== OCEAN CURRENT spatial structure at tick {TICK} (NB={NB} lat x NX={NX} lon-thirds, ocean only) ===")
print("ny_band |   West third       |   Mid third        |   East third      (ocx,ocy)")
for b in range(NB):
    lo=(b/NB-0.5)*2
    cells=[]
    for xi in range(NX):
        g=gy.get((b,xi))
        if g and g[2]>0:
            cells.append(f"({g[0]/g[2]:+.2f},{g[1]/g[2]:+.2f})")
        else:
            cells.append("    .       ")
    print(f"{lo:+.2f}  | "+" | ".join(cells))
