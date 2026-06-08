#!/usr/bin/env python3
# 验证：SLP 是否随 tick(季节)变化？
# 对固定纬度带(45°N, band索引13)，逐 tick 统计平均 SLP，看是否恒定。
import csv
CSV = "tile_data_record_20260608_184710.csv"
I_TICK=1; I_SLP=55; I_LAT=62
NB=18
def band(ny): 
    b=int(ny*NB); return min(max(b,0),NB-1)

TARGET_BAND = 13  # +0.44~+0.56 = 45°N
per_tick = {}  # tick -> [sum, n]
ticks_seen = set()
with open(CSV, newline='', encoding='utf-8', errors='replace') as fh:
    rdr=csv.reader(fh); next(rdr)
    for row in rdr:
        try:
            tk=int(row[I_TICK]); ny=float(row[I_LAT]); slp=float(row[I_SLP])
        except (ValueError,IndexError): continue
        ticks_seen.add(tk)
        if band(ny)==TARGET_BAND:
            e=per_tick.setdefault(tk,[0.0,0]); e[0]+=slp; e[1]+=1

print(f"unique ticks = {len(ticks_seen)}  range {min(ticks_seen)}..{max(ticks_seen)}")
ks=sorted(per_tick)
vals=[per_tick[k][0]/per_tick[k][1] for k in ks]
print(f"45N band: across {len(ks)} ticks  min={min(vals):.5f} max={max(vals):.5f} spread={max(vals)-min(vals):.6f}")
print("sample (every ~100th tick):")
for i in range(0,len(ks),max(1,len(ks)//12)):
    print(f"  tick={ks[i]:4d}  slp45N={vals[i]:.5f}")
