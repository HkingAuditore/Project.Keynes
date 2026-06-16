import csv, math
from collections import defaultdict

path = r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260616_211345.csv"
with open(path, "r", encoding="utf-8", newline="") as f:
    reader = csv.reader(f); header = next(reader)
idx = {n:i for i,n in enumerate(header)}
def gf(row,name):
    try: return float(row[idx[name]])
    except: return float("nan")

NB=10
def band(lat): return min(NB-1,max(0,int(lat*NB)))

# 累加器：按 (band, is_water) 统计
# 用于相关性：sum_x(soff), sum_y(temp), sum_xy, sum_x2, sum_y2, n
# 用于偏差：sum(temp-target), sum(baseline-target), sum(temp-baseline)
acc = defaultdict(lambda: dict(n=0, sx=0.0,sy=0.0,sxy=0.0,sx2=0.0,sy2=0.0,
                               d_tt=0.0,d_bt=0.0,d_tb=0.0, st=0.0,sb=0.0,starg=0.0,
                               s_air=0.0,s_tta=0.0))
def altpen(elev):
    lin=elev*0.40; t=max(0.0,min(1.0,(elev-0.45)/0.55)); hi=t*t*(3-2*t)*0.22; return lin+hi

with open(path,"r",encoding="utf-8",newline="") as f:
    reader=csv.reader(f); next(reader)
    for row in reader:
        lat=gf(row,"cell_lat_norm_arr"); w=1 if gf(row,"is_water_arr")>0.5 else 0
        temp=gf(row,"temp_arr"); baseln=gf(row,"temp_baseline_arr")
        byr=gf(row,"temp_baseline_year_arr"); soff=gf(row,"temp_season_offset_arr")
        elev=gf(row,"elevation_arr"); air=gf(row,"air_mass_temp_anomaly_arr"); tta=gf(row,"temperature_transport_anomaly_arr")
        if any(math.isnan(v) for v in (lat,temp,baseln,byr,soff,elev)): continue
        ty=max(0.0,min(1.0,byr-altpen(elev))); targ=max(0.0,min(1.0,ty+soff))
        a=acc[(band(lat),w)]
        a["n"]+=1
        a["sx"]+=soff; a["sy"]+=temp; a["sxy"]+=soff*temp; a["sx2"]+=soff*soff; a["sy2"]+=temp*temp
        a["d_tt"]+=temp-targ; a["d_bt"]+=baseln-targ; a["d_tb"]+=temp-baseln
        a["st"]+=temp; a["sb"]+=baseln; a["starg"]+=targ
        a["s_air"]+=air if not math.isnan(air) else 0.0
        a["s_tta"]+=tta if not math.isnan(tta) else 0.0

def corr(a):
    n=a["n"]
    if n<2: return float("nan")
    cov=a["sxy"]/n-(a["sx"]/n)*(a["sy"]/n)
    vx=a["sx2"]/n-(a["sx"]/n)**2; vy=a["sy2"]/n-(a["sy"]/n)**2
    if vx<=0 or vy<=0: return float("nan")
    return cov/math.sqrt(vx*vy)

for w,wname in [(0,"陆地"),(1,"海洋")]:
    print(f"\n================= {wname} =================")
    print(f"{'band':>4} {'lat':>5} {'纬度':>5} {'n':>6} {'corr(T,季节)':>11} {'mean(T-目标)':>11} {'mean(base-目标)':>13} {'mean(T-base)':>11} {'meanT':>6} {'meanTarg':>7} {'air均':>6} {'tta均':>6}")
    for b in range(NB):
        a=acc[(b,w)]
        if a["n"]==0: continue
        n=a["n"]; lat_mid=(b+0.5)/NB; absd=abs(lat_mid-0.5)*2
        tag="极" if absd>0.7 else ("赤" if absd<0.2 else "中")
        print(f"{b:>4} {lat_mid:>5.2f} {tag:>5} {n:>6} {corr(a):>11.3f} {a['d_tt']/n:>11.3f} {a['d_bt']/n:>13.3f} {a['d_tb']/n:>11.3f} {a['st']/n:>6.3f} {a['starg']/n:>7.3f} {a['s_air']/n:>6.3f} {a['s_tta']/n:>6.3f}")

print("\n说明: corr(T,季节)=温度与季节偏移的相关性(应接近+1表示跟随太阳);")
print("      mean(T-目标)>0 表示比辐射目标偏暖; air均/tta均=热输运异常的平均(>0=暖偏).")
