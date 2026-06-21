import csv, sys
from collections import defaultdict, Counter
PATH = sys.argv[1] if len(sys.argv)>1 else r'Project.Keynes/tmp/tile_data_record_20260620_004323.csv'
NAMES={0:'CLEAR',1:'RAIN',2:'STORM',3:'BLIZZARD',4:'DROUGHT',5:'FOG',6:'HEATWAVE',7:'MONSOON'}
f=open(PATH,encoding='utf-8-sig',newline='')
rd=csv.reader(f); h=next(rd)
ci={n:i for i,n in enumerate(h)}
def find(*names):
    for n in names:
        if n in ci: return ci[n]
    return -1
C_wt=find('weather_type_arr'); C_lat=find('cell_lat_norm_arr','cell_lat_norm')
C_water=find('is_water_arr','is_water'); C_cell=find('cell_index'); C_tick=find('tick_idx')
C_terr=find('terrain_arr','terrain')
print('cols: wt',C_wt,'lat',C_lat,'water',C_water,'terrain',C_terr)
def fv(s):
    try: return float(s)
    except: return 0.0
def iv(s):
    try: return int(float(s))
    except: return -1
glob=Counter(); water=Counter(); land=Counter()
latband=defaultdict(Counter)  # band -> type counter
maxc=max(C_wt,C_lat,C_water,C_cell,C_tick)
n=0
for r in rd:
    if len(r)<=maxc: continue
    w=iv(r[C_wt])
    if w<0: continue
    n+=1
    glob[w]+=1
    isw = fv(r[C_water])>0.5 if C_water>=0 else False
    (water if isw else land)[w]+=1
    if C_lat>=0:
        lat=fv(r[C_lat])             # 0..1, 0.5=equator
        latabs=abs(lat-0.5)*2.0      # 0=equator,1=pole
        band=min(9,int(latabs*10))
        latband[band][w]+=1
def pct(cnt):
    t=sum(cnt.values()) or 1
    return '  '.join(f'{NAMES[k]}={100.0*cnt[k]/t:.1f}%' for k in sorted(cnt) if cnt[k]>0)
print(f'\nrows={n}')
print('=== GLOBAL type distribution ===\n  '+pct(glob))
print(f'\n=== WATER cells (n={sum(water.values())}) ===\n  '+pct(water))
print(f'=== LAND cells (n={sum(land.values())}) ===\n  '+pct(land))
print('\n=== by ABS latitude band (0=equator .. 9=pole) ===')
for b in range(10):
    if latband[b]:
        tot=sum(latband[b].values())
        dom=latband[b].most_common(2)
        doms=' '.join(f'{NAMES[k]}:{100.0*v/tot:.0f}%' for k,v in dom)
        print(f'  band{b} (n={tot:6d}): {pct(latband[b])}')
