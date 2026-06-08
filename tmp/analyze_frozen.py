#!/usr/bin/env python3
# 测多个场的 tick 间变异：固定纬度带(45N)，看每个场跨983 tick 是否变化。
# temp 作对照(已知随季节变)。若 slp/wind/ocean spread=0 -> 这些场静态烘焙一次。
import csv
CSV="tile_data_record_20260608_184710.csv"
NB=18
def band(ny):
    b=int(ny*NB); return min(max(b,0),NB-1)

# 0-based 列索引（由 header nl 推断，slp=55,lat=62 已确认）
COLS={"temp":13,"slp":55,"windx":None,"windy":None,"ocx":None,"ocy":None,"ice":None}
# 先读 header 自动定位
with open(CSV,encoding='utf-8',errors='replace') as fh:
    hdr=next(csv.reader(fh))
def find(name):
    for i,h in enumerate(hdr):
        if h.strip()==name: return i
    return None
# 探测真实列名
cand={
 "temp":["cell_temp_arr","temp_arr","cell_temp_now_arr"],
 "slp":["slp_arr"],
 "windx":["wind_x_arr","windx_arr","wind_u_arr"],
 "windy":["wind_y_arr","windy_arr","wind_v_arr"],
 "ocx":["ocean_current_x_arr","ocx_arr","ocean_x_arr"],
 "ocy":["ocean_current_y_arr","ocy_arr","ocean_y_arr"],
 "ice":["sea_ice_frac_arr","ice_frac_arr","sea_ice_arr"],
}
IDX={}
for k,names in cand.items():
    for nm in names:
        j=find(nm)
        if j is not None: IDX[k]=j; break
I_TICK=find("tick_idx"); I_LAT=find("cell_lat_norm_arr")
print("resolved cols:",{k:(hdr[v] if v is not None else None) for k,v in IDX.items()},"lat=",I_LAT,"tick=",I_TICK)

TB=13  # 45N
acc={k:{} for k in IDX}  # field -> {tick:[sum,n]}
with open(CSV,newline='',encoding='utf-8',errors='replace') as fh:
    rdr=csv.reader(fh); next(rdr)
    for row in rdr:
        try:
            tk=int(row[I_TICK]); ny=float(row[I_LAT])
        except: continue
        if band(ny)!=TB: continue
        for k,j in IDX.items():
            try: v=float(row[j])
            except: continue
            if v!=v: continue
            e=acc[k].setdefault(tk,[0.0,0]); e[0]+=v; e[1]+=1

print("\n=== per-field tick-to-tick variation at 45N band ===")
print(f"{'field':>8s} {'min':>10s} {'max':>10s} {'spread':>10s}  verdict")
for k in IDX:
    ks=sorted(acc[k])
    if not ks: 
        print(f"{k:>8s}  (no data)"); continue
    vals=[acc[k][t][0]/acc[k][t][1] for t in ks]
    sp=max(vals)-min(vals)
    verdict="FROZEN (静态!)" if sp<1e-6 else "varies (随季节)"
    print(f"{k:>8s} {min(vals):10.5f} {max(vals):10.5f} {sp:10.6f}  {verdict}")
