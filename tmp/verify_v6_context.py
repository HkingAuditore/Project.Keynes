"""验证：
1) 同一 cell 在连续 tick 中 weather_type / weather_prev_type / weather_target_type 的关系
2) cell 1539 在 tick 975-985 的温度上下文
"""
import pandas as pd, os
CSV = r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/tile_data_record_20260612_130635.csv'
USECOLS = ['tick_idx','cell_index','temp_arr','temp_arr_prev','weather_type_arr',
           'weather_prev_type_arr','weather_target_type_arr','weather_transition_alpha_arr',
           'weather_precip_arr','cell_lat_norm_arr','is_water_arr','insolation_now_arr']

# 找 cell 1539 (max delta) 与 cell 69 (ping-pong 例子)，tick 范围内的全部记录
target_cells = {1539, 69, 70, 130, 131}
target_tick_lo, target_tick_hi = 515, 535
rows_a = []
target_tick_lo2, target_tick_hi2 = 970, 990
rows_b = []

for chunk in pd.read_csv(CSV, usecols=USECOLS, chunksize=400000):
    sub = chunk[chunk['cell_index'].isin(target_cells)]
    a = sub[(sub['tick_idx']>=target_tick_lo)&(sub['tick_idx']<=target_tick_hi)]
    b = sub[(sub['tick_idx']>=target_tick_lo2)&(sub['tick_idx']<=target_tick_hi2)]
    if len(a): rows_a.append(a)
    if len(b): rows_b.append(b)

if rows_a:
    A = pd.concat(rows_a).sort_values(['cell_index','tick_idx'])
    print('=== ping-pong 上下文 (cells 69,70,130,131; tick 515..535) ===')
    print(A.to_string(index=False))
if rows_b:
    B = pd.concat(rows_b).sort_values(['cell_index','tick_idx'])
    print()
    print('=== max-jump 上下文 (cell 1539; tick 970..990) ===')
    print(B[B['cell_index']==1539].to_string(index=False))
