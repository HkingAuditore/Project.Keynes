import csv
PATH = r'Project.Keynes/tmp/tile_data_record_20260619_184841.csv'
C={'temp':148,'air_anom':171,'cloud':161,'precip':163,'vapor':167,'lat_norm':211,'is_water':223}
def fv(s):
    if not s:return 0.0
    try:return float(s)
    except:return 0.0
# HEATWAVE precondition (after RAIN/FOG fail): temp>0.70 & precip<0.025 & lat_abs<0.62 & local_summer(0.5 autumn)>0.35
hot=0; cl=[0,0,0,0,0]  # cloud<0.30,<0.40,<0.45,<0.55,any
drought_ok=0; dr=[0,0,0]
for row in csv.reader(open(PATH,'r',encoding='utf-8-sig',newline='')):
    pass
# redo properly
hot=0; b=[0]*6
n=0
with open(PATH,'r',encoding='utf-8-sig',newline='') as f:
    rd=csv.reader(f); next(rd)
    for row in rd:
        if len(row)<=C['is_water']:continue
        if int(fv(row[C['is_water']]))==1: continue  # land only
        temp=fv(row[C['temp']])+fv(row[C['air_anom']])
        precip=fv(row[C['precip']]); lat=abs(fv(row[C['lat_norm']])*2-1)
        cloud=fv(row[C['cloud']]); vapor=fv(row[C['vapor']])+precip*0.70
        # must not be meaningful_precip (else RAIN earlier)
        meaningful = precip>0.030 or (precip>0.022 and cloud>0.22 and vapor>0.28)
        if temp>0.70 and precip<0.025 and lat<0.62 and not meaningful:
            hot+=1
            for j,thr in enumerate([0.30,0.40,0.45,0.55,0.65,1.01]):
                if cloud<thr: b[j]+=1
print("land cells passing temp>0.70 & precip<0.025 & lat<0.62 & !meaningful:",hot)
for j,thr in enumerate([0.30,0.40,0.45,0.55,0.65,1.01]):
    print(f"  of those, cloud<{thr}: {b[j]} ({100.0*b[j]/max(hot,1):.1f}%)")
