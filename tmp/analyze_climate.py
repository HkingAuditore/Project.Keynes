# -*- coding: utf-8 -*-
import csv, math, sys, json
from collections import defaultdict

PATH = r"D:/Godot/ProjectKeynes/Project.Keynes/tmp/tile_data_record_20260608_184710.csv"

# column indices (0-based)
C = {
 'tick':1,'cell':9,'q':10,'r':11,'s':12,
 'temp':13,'moisture':15,'snow':17,'temp_base':19,
 'temp30':20,'temp365':21,'anom':22,'ice':23,
 'precip':27,'season_off':35,'insol':36,'insol_dev':37,'daylen':38,
 'veg_vit':43,'soil':46,'elev':49,
 'ocx':51,'ocy':52,'wx':53,'wy':54,'slp':55,'wspd':56,'upw':57,'psi':59,
 'px':60,'py':61,'lat':62,'temp_base_yr':63,
 'terrain':64,'landform':65,'veg':66,'cover':70,'wtype':71,'is_water':72,
}

def f(x):
    try: return float(x)
    except: return float('nan')

# accumulators
# per-tick hemispheric means
tick_data = {}  # tick -> dict
# field global stats
stats = {k:{'min':math.inf,'max':-math.inf,'sum':0.0,'n':0,'nan':0,'bad':0} for k in C if k not in ('tick','cell','q','r','s')}

# latitude-banded accumulators across whole run (for climatology)
NB=18
def band(ny):  # ny in [0,1], 0.5=equator -> band 0..NB-1
    b=int(ny*NB)
    return min(max(b,0),NB-1)
latband = defaultdict(lambda: defaultdict(float))
latband_n = defaultdict(int)

# wind by band (separate equator vs mid lat) using last 1/4 of run for steady state
wind_band = defaultdict(lambda:[0.0,0.0,0]) # band->[sumwx,sumwy,n]

# snapshot at specific ticks for lat profile
all_ticks=set()

# first pass: collect tick list min/max
maxtick=-1; mintick=1<<30
row_count=0

with open(PATH, 'r', encoding='utf-8-sig', newline='') as fh:
    rd = csv.reader(fh)
    header = next(rd)
    for row in rd:
        if len(row) < 73: 
            continue
        row_count+=1
        t = int(float(row[C['tick']]))
        all_ticks.add(t)
        if t>maxtick: maxtick=t
        if t<mintick: mintick=t
        lat = f(row[C['lat']])      # ny in [0,1], 0.5=equator
        lat_signed = (lat-0.5)*2.0  # [-1,+1]
        is_water = f(row[C['is_water']])
        temp = f(row[C['temp']])
        insol = f(row[C['insol']])
        ice = f(row[C['ice']])
        veg = f(row[C['veg_vit']])
        precip = f(row[C['precip']])
        elev = f(row[C['elev']])

        # global stats
        for k in stats:
            v=f(row[C[k]])
            if v!=v:
                stats[k]['nan']+=1; continue
            if abs(v)>1e6: stats[k]['bad']+=1
            s=stats[k]
            if v<s['min']: s['min']=v
            if v>s['max']: s['max']=v
            s['sum']+=v; s['n']+=1

        # per tick hemispheric
        d = tick_data.get(t)
        if d is None:
            d = {'nT':0,'sT':0,'nTemp':0.0,'sTemp':0.0,'nIns':0.0,'sIns':0.0,
                 'nIce':0.0,'sIce':0.0,'nSn':0.0,'sSn':0.0,
                 'nInsRaw':0.0,'sInsRaw':0.0,'maxInsLat':-2.0,'maxInsVal':-1.0}
            tick_data[t]=d
        if lat_signed>=0:
            d['nT']+=1; d['nTemp']+=temp; d['nIns']+=insol; d['nIce']+=ice; d['nSn']+=f(row[C['snow']])
        else:
            d['sT']+=1; d['sTemp']+=temp; d['sIns']+=insol; d['sIce']+=ice; d['sSn']+=f(row[C['snow']])
        # subsolar proxy: latitude(signed) with max insolation
        if insol>d['maxInsVal']:
            d['maxInsVal']=insol; d['maxInsLat']=lat_signed

        # lat band climatology (whole run)
        b=band(lat)
        lb=latband[b]
        lb['temp']+=temp; lb['ice']+=ice; lb['veg']+=veg; lb['precip']+=precip
        lb['insol']+=insol; lb['elev']+=elev; lb['water']+=is_water
        latband_n[b]+=1

print(f"rows={row_count} ticks={mintick}..{maxtick} nticks={len(all_ticks)}", file=sys.stderr)

out={}
out['row_count']=row_count
out['tick_min']=mintick; out['tick_max']=maxtick; out['ntick']=len(all_ticks)

# field stats
fs={}
for k,s in stats.items():
    if s['n']>0:
        fs[k]={'min':round(s['min'],4),'max':round(s['max'],4),'mean':round(s['sum']/s['n'],4),'nan':s['nan'],'bad':s['bad']}
out['field_stats']=fs

# seasonal cycle (sample 30 ticks evenly)
ticks_sorted=sorted(tick_data.keys())
season=[]
for t in ticks_sorted:
    d=tick_data[t]
    nT=d['nT'] or 1; sT=d['sT'] or 1
    season.append({
        't':t,
        'N_temp':round(d['nTemp']/nT,4),'S_temp':round(d['sTemp']/sT,4),
        'N_insol':round(d['nIns']/nT,4),'S_insol':round(d['sIns']/sT,4),
        'N_ice':round(d['nIce']/nT,4),'S_ice':round(d['sIce']/sT,4),
        'N_snow':round(d['nSn']/nT,4),'S_snow':round(d['sSn']/sT,4),
        'subsolar_lat':round(d['maxInsLat'],3),
    })
# downsample to ~40 points
step=max(1,len(season)//40)
out['season']=season[::step]

# lat band climatology
lbout=[]
for b in range(NB):
    n=latband_n[b]
    if n==0: continue
    lo=(b*(1.0/NB)-0.5)*2.0; hi=((b+1)*(1.0/NB)-0.5)*2.0  # signed lat edges
    lb=latband[b]
    lbout.append({
        'band':b,'lat_lo':round(lo,2),'lat_hi':round(hi,2),'n':n,
        'temp':round(lb['temp']/n,4),'ice':round(lb['ice']/n,4),
        'veg':round(lb['veg']/n,4),'precip':round(lb['precip']/n,4),
        'insol':round(lb['insol']/n,4),'elev':round(lb['elev']/n,4),
        'water_frac':round(lb['water']/n,3),
    })
out['lat_climatology']=lbout

print(json.dumps(out, ensure_ascii=False))
