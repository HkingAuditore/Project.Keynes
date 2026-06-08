#!/usr/bin/env python3
"""
检查完整时间序列(6~442 tick)中是否有四季变化
"""
import pandas as pd
import numpy as np

print("=" * 80)
print("检查完整时间序列的四季变化")
print("=" * 80)
print()

# 策略：分块读取，每100000行一块，覆盖所有tick
chunk_size = 100000
n_chunks = 12  # 1045MB / 100MB ≈ 10-12 chunks

all_ticks = []
all_temps = []
all_moistures = []
all_offsets = []
all_vitality = []

print("[1] 分块读取数据，收集时间序列信息...")
for chunk_idx in range(n_chunks):
    skip = chunk_idx * chunk_size
    if skip > 0:
        # 大文件跳过前N行需要设置skiprows
        df_chunk = pd.read_csv('d:/Godot/ProjectKeynes/Project.Keynes/tmp/tile_data_record_20260527_142740.csv', 
                              skiprows=range(1, skip+1),
                              nrows=chunk_size,
                              usecols=['tick_idx', 'cell_index', 'cell_lat_norm_arr', 
                                       'temp_arr', 'moisture_arr', 'temp_season_offset_arr',
                                       'insolation_dev_arr', 'vegetation_vitality_arr'])
    else:
        df_chunk = pd.read_csv('d:/Godot/ProjectKeynes/Project.Keynes/tmp/tile_data_record_20260527_142740.csv', 
                              nrows=chunk_size,
                              usecols=['tick_idx', 'cell_index', 'cell_lat_norm_arr', 
                                       'temp_arr', 'moisture_arr', 'temp_season_offset_arr',
                                       'insolation_dev_arr', 'vegetation_vitality_arr'])
    
    if len(df_chunk) == 0:
        break
    
    print(f"  Chunk {chunk_idx}: 读取 {len(df_chunk)} 行, tick范围={df_chunk['tick_idx'].min()}-{df_chunk['tick_idx'].max()}")
    
    # 收集唯一tick
    ticks_in_chunk = df_chunk['tick_idx'].unique()
    all_ticks.extend(ticks_in_chunk.tolist())
    
    # 检查采样格子的温度变化（选前5个cell）
    for cell_id in df_chunk['cell_index'].unique()[:5]:
        cell_data = df_chunk[df_chunk['cell_index'] == cell_id].sort_values('tick_idx')
        if len(cell_data) > 10:
            all_temps.append(cell_data['temp_arr'].values)
            all_moistures.append(cell_data['moisture_arr'].values)
            all_offsets.append(cell_data['temp_season_offset_arr'].values if 'temp_season_offset_arr' in cell_data.columns else [])
            all_vitality.append(cell_data['vegetation_vitality_arr'].values if 'vegetation_vitality_arr' in cell_data.columns else [])
    
    # 如果已经覆盖到tick 442，可以提前停止
    if df_chunk['tick_idx'].max() >= 442:
        print(f"  已覆盖到tick 442，停止读取")
        break

all_ticks = sorted(set(all_ticks))
print(f"\n  总共覆盖 {len(all_ticks)} 个唯一tick")
print(f"  Tick范围: {min(all_ticks)}-{max(all_ticks)}")
print()

# 分析温度变化
print("[2] 分析温度变化（季节信号）")
if all_temps:
    for i, temps in enumerate(all_temps[:5]):
        if len(temps) > 50:
            temp_range = temps.max() - temps.min()
            temp_std = temps.std()
            print(f"  格子 {i}:")
            print(f"    温度范围: [{temps.min():.6f}, {temps.max():.6f}]")
            print(f"    温度标准差: {temp_std:.6f}")
            print(f"    前20个值: {temps[:20]}")
            
            if temp_std < 0.001:
                print(f"    [ERROR] 温度几乎不变！无季节变化")
            else:
                print(f"    [OK] 温度有变化，可能有季节信号")
            print()

# 分析season_offset变化
print("[3] 分析 temp_season_offset 变化")
if all_offsets:
    for i, offsets in enumerate(all_offsets[:3]):
        if len(offsets) > 50:
            offset_range = offsets.max() - offsets.min()
            offset_std = offsets.std()
            print(f"  格子 {i}:")
            print(f"    season_offset 范围: [{offsets.min():.6f}, {offsets.max():.6f}]")
            print(f"    season_offset 标准差: {offset_std:.6f}")
            print(f"    前20个值: {offsets[:20]}")
            
            if offset_std < 0.001:
                print(f"    [ERROR] season_offset几乎不变！直射点可能未移动")
            else:
                print(f"    [OK] season_offset有变化，直射点可能在移动")
            print()

# 分析植被活力变化
print("[4] 分析植被活力变化")
if all_vitality:
    for i, vit in enumerate(all_vitality[:3]):
        if len(vit) > 50:
            vit_range = vit.max() - vit.min()
            vit_std = vit.std()
            print(f"  格子 {i}:")
            print(f"    植被活力范围: [{vit.min():.6f}, {vit.max():.6f}]")
            print(f"    植被活力标准差: {vit_std:.6f}")
            
            if vit_std < 0.001:
                print(f"    [ERROR] 植被活力几乎不变！")
            else:
                print(f"    [OK] 植被活力有变化")
            print()

print("=" * 80)
print("检查完成")
print("=" * 80)
