#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""二次核查：风速真实字段、温度跳变时间结构、海冰极地温度"""
import pandas as pd, numpy as np

CSV='d:/Godot/ProjectKeynes/Project.Keynes/tmp/tile_data_record_20260608_184710.csv'
cols=['tick_idx','cell_index','temp_arr','temp_arr_prev','wind_speed_arr','wind_x_arr','wind_y_arr',
      'cell_lat_norm_arr','is_water_arr','sea_ice_frac_arr','temp_30d_arr','temp_365d_arr',
      'temp_season_offset_arr','elevation_arr']

# 跳变按 tick 统计
jump_by_tick={}
windspeed=[]
polar_water_temp=[]  # 高纬水体温度
chunk=pd.read_csv(CSV,usecols=cols,chunksize=500000)
for ch in chunk:
    dd=(ch['temp_arr']-ch['temp_arr_prev']).abs()
    big=ch[dd>0.1]
    for tk,g in big.groupby('tick_idx'):
        jump_by_tick[tk]=jump_by_tick.get(tk,0)+len(g)
    windspeed.extend(ch['wind_speed_arr'].iloc[::200].tolist())
    w=ch[(ch['is_water_arr']==True)|(ch['is_water_arr']==1)]
    pw=w[(w['cell_lat_norm_arr']<0.12)|(w['cell_lat_norm_arr']>0.88)]
    for _,r in pw.iloc[::50].iterrows():
        polar_water_temp.append((r['cell_lat_norm_arr'],r['temp_arr'],r['sea_ice_frac_arr']))

print("="*60)
print("【风速真实字段 wind_speed_arr】")
ws=np.array(windspeed)
print(f"  范围[{ws.min():.4f},{ws.max():.4f}] 均值{ws.mean():.4f} 标准差{ws.std():.4f}")
print(f"  非零占比{(ws>1e-4).mean()*100:.1f}%")

print("\n【温度跳变的时间分布 top20 tick】")
items=sorted(jump_by_tick.items(),key=lambda x:-x[1])[:20]
for tk,c in items:
    print(f"  tick {tk}: {c} 次跳变")
# 跳变是否集中在少数tick
total=sum(jump_by_tick.values())
top20=sum(c for _,c in items)
print(f"  跳变总数{total}, top20 tick占{top20/total*100:.1f}%, 有跳变的tick数{len(jump_by_tick)}")

print("\n【极地水体温度 & 海冰】")
pw=np.array(polar_water_temp)
if len(pw)>0:
    print(f"  极地水体格采样{len(pw)}个")
    print(f"  温度 范围[{pw[:,1].min():.3f},{pw[:,1].max():.3f}] 均值{pw[:,1].mean():.3f}")
    print(f"  海冰 均值{pw[:,2].mean():.3f} 最大{pw[:,2].max():.3f}")
    print(f"  极地水体有冰(>0.05)占比{(pw[:,2]>0.05).mean()*100:.1f}%")
    cold=pw[:,1]<0.15
    print(f"  极冷(<0.15)极地水体占比{cold.mean()*100:.1f}% 其中有冰占比{(pw[cold,2]>0.05).mean()*100:.1f}%" if cold.sum()>0 else "  无极冷水体")
