#!/usr/bin/env python3
"""
分析1000+ tick的时间序列数据，检查季节系统是否工作
"""
import pandas as pd
import numpy as np

print("=" * 80)
print("时间序列诊断：检查季节系统是否工作")
print("=" * 80)
print()

# 由于文件很大(1045MB)，只读取需要的列和采样数据
print("[1] 读取数据基本信息...")
# 先读前1000行看看结构
df_sample = pd.read_csv('d:/Godot/ProjectKeynes/Project.Keynes/tmp/tile_data_record_20260527_142740.csv', nrows=50000)
print(f"  采样行数: {len(df_sample)}")
print(f"  总列数: {len(df_sample.columns)}")
print(f"  Tick范围: {df_sample['tick_idx'].min()} - {df_sample['tick_idx'].max()}")
print()

# 检查有多少唯一的tick
ticks = df_sample['tick_idx'].unique()
print(f"[2] Tick分析")
print(f"  唯一tick数: {len(ticks)}")
print(f"  Tick列表(前10个): {ticks[:10]}")
print()

# 每个tick有多少格子？
tick_counts = df_sample['tick_idx'].value_counts().sort_index()
print(f"[3] 每个tick的格子数")
print(f"  最小: {tick_counts.min()}")
print(f"  最大: {tick_counts.max()}")
print(f"  均值: {tick_counts.mean():.1f}")
print()

# 检查几个固定格子的温度变化
print("[4] 检查固定格子的温度变化（季节响应）")
sample_cells = df_sample['cell_id'].unique()[:5]
for cell_id in sample_cells:
    cell_data = df_sample[df_sample['cell_id'] == cell_id].sort_values('tick_idx')
    if len(cell_data) > 100:  # 至少有100个tick的数据
        temps = cell_data['temp_arr'].values
        moistures = cell_data['moisture_arr'].values
        tick_range = f"{cell_data['tick_idx'].min()}-{cell_data['tick_idx'].max()}"
        lat = cell_data['cell_lat_norm_arr'].iloc[0]
        elevation = cell_data['elevation_arr'].iloc[0]
        
        print(f"  格子 {cell_id}:")
        print(f"    纬度={lat:.4f}, 海拔={elevation:.4f}")
        print(f"    Tick范围: {tick_range}")
        print(f"    温度: [{temps.min():.6f}, {temps.max():.6f}], 标准差={temps.std():.6f}")
        print(f"    湿度: [{moistures.min():.6f}, {moistures.max():.6f}], 标准差={moistures.std():.6f}")
        
        # 检查是否有周期性
        if len(temps) > 365:
            # 计算自相关（简化版）
            temp_diff = np.diff(temps[:365])
            sign_changes = np.sum(temp_diff[:-1] * temp_diff[1:] < 0)
            print(f"    >365tick温度符号变化次数: {sign_changes} (高=有周期)")
        
        # 判断季节系统是否工作
        temp_range = temps.max() - temps.min()
        if temp_range < 0.01:
            print(f"    [ERROR] 温度几乎无变化! 季节系统可能未工作")
        else:
            print(f"    [OK] 温度有变化(范围={temp_range:.6f})，季节系统可能在工作")
        print()

# 检查直射点是否在移动
print("[5] 检查太阳直射点是否在移动")
if 'insolation_dev_arr' in df_sample.columns:
    for cell_id in sample_cells[:3]:
        cell_data = df_sample[df_sample['cell_id'] == cell_id].sort_values('tick_idx')
        if len(cell_data) > 100:
            devs = cell_data['insolation_dev_arr'].values
            print(f"  格子 {cell_id}:")
            print(f"    insolation_dev 范围: [{devs.min():.6f}, {devs.max():.6f}]")
            print(f"    insolation_dev 标准差: {devs.std():.6f}")
            if devs.std() < 0.01:
                print(f"    [ERROR] insolation_dev几乎无变化! 直射点可能未移动")
            else:
                print(f"    [OK] insolation_dev有变化，直射点可能在移动")
            print()

# 检查纬度-温度相关性（跨所有tick）
print("[6] 纬度-温度相关性（跨所有tick）")
# 只取最后一个tick的数据做快照对比
max_tick = df_sample['tick_idx'].max()
df_latest = df_sample[df_sample['tick_idx'] == max_tick]
if len(df_latest) > 100:
    corr = df_latest['cell_lat_norm_arr'].corr(df_latest['temp_arr'])
    print(f"  最新tick({max_tick})的纬度-温度相关系数: {corr:.6f}")
    print(f"  期望: 强负相关(-0.7~-0.9)")
    if corr > -0.3:
        print(f"  [ERROR] 相关性太弱! 温度场可能完全错误")
    else:
        print(f"  [OK] 相关性合理")

print()
print("=" * 80)
print("诊断完成")
print("=" * 80)
