import csv
from collections import Counter

PATH = r'Project.Keynes/tmp/tile_data_record_20260619_184841.csv'
C = {'temp':148,'air_anom':171,'cloud':161,'precip':163,'vapor':167,'instability':169,
     'transport_anom':193,'lat_norm':211,'terrain':213,'wtype':220,'is_water':223}
WT={0:'CLEAR',1:'RAIN',2:'STORM',3:'BLIZZARD',4:'DROUGHT',5:'FOG',6:'HEATWAVE',7:'MONSOON'}

SEASON_IDX = 2  # autumn (season_phase=2.47)
COLD_PRECIP_AS_BLIZZARD = True
SNOW_MARGIN = 0.03

def fval(s):
    if not s: return 0.0
    try: return float(s)
    except: return 0.0

def classify(lat_signed, temp, vapor, cloud, precip, instability, ocean_an):
    lat_abs = abs(lat_signed)
    if SEASON_IDX==1: north_summer=1.0
    elif SEASON_IDX==3: north_summer=0.0
    else: north_summer=0.5
    local_summer = north_summer if lat_signed<0 else (1.0-north_summer)
    warm = temp>0.55
    humid = vapor>0.28
    meaningful_precip = precip>0.030 or (precip>0.022 and cloud>0.22 and vapor>0.28)
    cold_precip_snow = COLD_PRECIP_AS_BLIZZARD and meaningful_precip and (
        temp<=0.24 or (temp<0.31+SNOW_MARGIN and cloud>0.18 and vapor>0.20 and precip>0.04))
    if cold_precip_snow: return 3
    storm_precip_gate = 0.068 + (0.056-0.068)*local_summer
    storm_inst_gate = 0.56 + (0.50-0.56)*local_summer
    warm_ocean_core = ocean_an>0.12 and instability>0.70 and precip>0.07 and cloud>0.28
    if warm and humid and lat_abs<0.70 and ((instability>storm_inst_gate and precip>storm_precip_gate) or warm_ocean_core):
        return 2
    if warm and humid and lat_abs<0.42 and local_summer>0.5 and precip>0.055:
        return 7
    if meaningful_precip: return 1
    if vapor>0.34 and cloud>0.14 and precip<0.030 and temp<0.55: return 5
    if temp>0.70 and cloud<0.30 and precip<0.025 and lat_abs<0.62 and local_summer>0.35: return 6
    if cloud<0.22 and precip<0.020 and temp>0.48 and vapor<0.34: return 4
    return 0

orig = Counter(); replay = Counter()
replay_water = Counter(); replay_land = Counter()
n=0
with open(PATH,'r',encoding='utf-8-sig',newline='') as f:
    rd=csv.reader(f); next(rd)
    for row in rd:
        if len(row)<=C['is_water']: continue
        n+=1
        temp = fval(row[C['temp']]) + fval(row[C['air_anom']])
        if temp>1.0: temp=1.0
        precip = fval(row[C['precip']])
        # reconstruct pre-sink vapor used by classifier (published = vapor - precip*0.70)
        vapor = fval(row[C['vapor']]) + precip*0.70
        if vapor>1.0: vapor=1.0
        cloud = fval(row[C['cloud']]); inst = fval(row[C['instability']])
        isw = int(fval(row[C['is_water']]))
        ocean_an = fval(row[C['transport_anom']]) if isw==1 else 0.0
        lat = fval(row[C['lat_norm']]); lat_signed = lat*2.0-1.0
        orig[int(fval(row[C['wtype']]))]+=1
        wt = classify(lat_signed, temp, vapor, cloud, precip, inst, ocean_an)
        replay[wt]+=1
        (replay_water if isw==1 else replay_land)[wt]+=1

def show(c,title):
    tot=sum(c.values())
    print(f"\n{title} (n={tot})")
    for k,v in sorted(c.items(),key=lambda x:-x[1]):
        print(f"  {WT[k]:9s}: {v:8d} ({100.0*v/max(tot,1):5.2f}%)")

print("season_idx=%d (local_summer=0.5)"%SEASON_IDX)
show(orig, "=== ORIGINAL recorded weather_type (stale 18:48 build) ===")
show(replay, "=== REPLAY with CURRENT classification logic ===")
show(replay_water, "=== REPLAY (water cells) ===")
show(replay_land, "=== REPLAY (land cells) ===")
