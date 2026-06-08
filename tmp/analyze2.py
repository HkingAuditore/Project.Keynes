# -*- coding: utf-8 -*-
import csv, math, sys, json
from collections import defaultdict

PATH = r"D:/Godot/ProjectKeynes/Project.Keynes/tmp/tile_data_record_20260608_184710.csv"
C = {'tick':1,'temp':13,'insol':36,'daylen':38,'elev':49,'wx':53,'wy':54,'slp':55,
     'wspd':56,'ocx':51,'ocy':52,'upw':57,'lat':62,'is_water':72,'precip':27}
def f(x):
    try: return float(x)
    except: return float('nan')

NB=24
def band(ny):
    return min(max(int(ny*NB),0),NB-1)

# wind & ocean by lat band, water vs land separated, whole run
wb=defaultdict(lambda: defaultdict(float)); wbn=defaultdict(int)
# elevation-temp bins for lapse check (only land), within tropics band to control latitude
elev_bins=defaultdict(lambda:[0.0,0]) # round(elev,1)->[sumtemp,n]
# insolation lat profile at 4 representative ticks (solstices/equinoxes proxy)
target_ticks={186,450,354,618}  # pick from season table: N-summer, S-summer-ish
ins_profile=defaultdict(lambda: defaultdict(lambda:[0.0,0]))  # tick->band->[sumins,n]

# zonal wind sign check: for each band compute mean wy (north-south) and wx (east-west)
with open(PATH,'r',encoding='utf-8-sig',newline='') as fh:
    rd=csv.reader(fh); next(rd)
    for row in rd:
        if len(row)<73: continue
        t=int(float(row[C['tick']]))
        ny=f(row[C['lat']]); b=band(ny)
        wx=f(row[C['wx']]); wy=f(row[C['wy']]); ws=f(row[C['wspd']])
        wb[b]['wx']+=wx; wb[b]['wy']+=wy; wb[b]['ws']+=ws
        wb[b]['ocx']+=f(row[C['ocx']]); wb[b]['ocy']+=f(row[C['ocy']])
        wb[b]['slp']+=f(row[C['slp']]); wbn[b]+=1
        # lapse: tropics only |ny-0.5|<0.15, land only
        if abs(ny-0.5)<0.15 and f(row[C['is_water']])<0.5:
            e=round(f(row[C['elev']]),1); eb=elev_bins[e]
            eb[0]+=f(row[C['temp']]); eb[1]+=1
        if t in target_ticks:
            ip=ins_profile[t][b]; ip[0]+=f(row[C['insol']]); ip[1]+=1

print("=== WIND/OCEAN BY LATITUDE BAND (whole-run mean) ===", file=sys.stderr)
print(f"{'lat':>7s} {'wx(E+)':>7s} {'wy(N+)':>7s} {'wspd':>6s} {'slp':>7s} {'ocx':>7s} {'ocy':>7s}")
for b in range(NB):
    n=wbn[b]
    if n==0: continue
    lo=(b/NB-0.5)*2; 
    w=wb[b]
    print(f"{lo:+.2f}   {w['wx']/n:+7.3f} {w['wy']/n:+7.3f} {w['ws']/n:6.3f} {w['slp']/n:+7.3f} {w['ocx']/n:+7.3f} {w['ocy']/n:+7.3f}")

print("\n=== LAPSE RATE (tropics land: elev vs temp) ===")
print(f"{'elev':>5s} {'temp':>6s} {'n':>7s}")
for e in sorted(elev_bins):
    s,n=elev_bins[e]
    if n>50: print(f"{e:5.1f} {s/n:6.3f} {n:7d}")

print("\n=== INSOLATION LAT PROFILE at sample ticks ===")
hdr="lat    "+ "  ".join(f"t{t}" for t in sorted(target_ticks))
print(hdr)
for b in range(NB):
    lo=(b/NB-0.5)*2
    vals=[]
    for t in sorted(target_ticks):
        ip=ins_profile[t].get(b)
        vals.append(f"{ip[0]/ip[1]:.2f}" if ip and ip[1]>0 else " . ")
    print(f"{lo:+.2f}  "+"  ".join(vals))
