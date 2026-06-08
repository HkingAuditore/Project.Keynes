#!/usr/bin/env python3
"""
检查完整时间序列(6~442 tick = 1.2年)中是否有四季变化
策略：读取足够多的行以覆盖所有tick
"""
import pandas as pd
import numpy as np
import os

print("=" * 80)
print("检查完整时间序列的四季变化 (tick 6~442)")
print("=" * 80)
print()

file_path = 'd:/Godot/ProjectKeynes/Project.Keynes/tmp/tile_data_record_20260527_142740.csv'
file_size_mb = os.path.getsize(file_path) / (1024 * 1024)
print(f"[0] 文件信息")
print(f"  文件大小: {file_size_mb:.1f} MB")
print(f"  预计总行数: ~{int(file_size_mb * 1024 * 1024 / 100)} 行")  # 粗略估计
print()

# 策略：读取1500000行以确保覆盖所有tick（436 ticks × 2400 rows ≈ 1,046,400行）
print("[1] 读取数据（最多1500000行以覆盖所有tick）...")
try:
    df = pd.read_csv(file_path, 
                     nrows=1500000,
                     usecols=['tick_idx', 'cell_index', 'cell_lat_norm_arr', 
                              'temp_arr', 'moisture_arr', 'temp_season_offset_arr',
                              'insolation_dev_arr', 'vegetation_vitality_arr',
                              'snow_cover_arr', 'sea_ice_frac_arr'])
    print(f"  实际读取: {len(df)} 行")
    print(f"  Tick范围: {df['tick_idx'].min()} - {df['tick_idx'].max()}")
    print(f"  唯一tick数: {df['tick_idx'].nunique()}")
    print()
    
    # 检查是否覆盖了所有tick
    expected_ticks = set(range(6, 443))  # 6~442
    actual_ticks = set(df['tick_idx'].unique())
    missing_ticks = expected_ticks - actual_ticks
    if missing_ticks:
        print(f"  [WARNING] 未覆盖的tick: {sorted(missing_ticks)[:10]}... (共{len(missing_ticks)}个)")
    else:
        print(f"  [OK] 已覆盖所有tick 6~442")
    print()
    
except Exception as e:
    print(f"  [ERROR] 读取失败: {e}")
    print("  尝试读取较少行...")
    df = pd.read_csv(file_path, 
                     nrows=500000,
                     usecols=['tick_idx', 'cell_index', 'cell_lat_norm_arr', 
                              'temp_arr', 'moisture_arr', 'temp_season_offset_arr',
                              'insolation_dev_arr', 'vegetation_vitality_arr'])
    print(f"  实际读取: {len(df)} 行")
    print(f"  Tick范围: {df['tick_idx'].min()} - {df['tick_idx'].max()}")
    print()

# 检查时间跨度
ticks = df['tick_idx'].unique()
tick_span = ticks.max() - ticks.min()
print(f"[2] 时间跨度分析")
print(f"  起始tick: {ticks.min()}")
print(f"  结束tick: {ticks.max()}")
print(f"  时间跨度: {tick_span} ticks ({tick_span/365:.2f} 年)")
print()

# 检查是否有季节性变化：选几个样本格子，绘制温度随时间的变化
print("[3] 检查固定格子的温度变化（季节响应）")
sample_cells = df['cell_index'].unique()[:10]
found_variation = False

for cell_id in sample_cells[:5]:
    cell_data = df[df['cell_index'] == cell_id].sort_values('tick_idx')
    if len(cell_data) > 100:  # 至少有100个tick的数据
        temps = cell_data['temp_arr'].values
        ticks_cell = cell_data['tick_idx'].values
        lat = cell_data['cell_lat_norm_arr'].iloc[0]
        
        temp_range = temps.max() - temps.min()
        temp_std = temps.std()
        
        print(f"  格子 {cell_id} (纬度={lat:.4f}):")
        print(f"    数据点数: {len(cell_data)}")
        print(f"    Tick范围: {ticks_cell.min()}-{ticks_cell.max()}")
        print(f"    温度范围: [{temps.min():.6f}, {temps.max():.6f}]")
        print(f"    温度标准差: {temp_std:.6f}")
        
        # 显示前30个tick的温度
        print(f"    前30个tick温度: {temps[:30]}")
        
        # 判断是否有季节变化
        if temp_std < 0.001:
            print(f"    [ERROR] 温度几乎无变化！无季节信号")
        else:
            print(f"    [OK] 温度有变化！可能有季节信号")
            found_variation = True
        
        # 检查周期性：计算自相关
        if len(temps) > 365:
            # 简化：检查是否每年有类似的变化模式
            year1 = temps[:365]
            year2 = temps[365:730] if len(temps) > 730 else None
            if year2 is not None:
                # 计算相关系数
                corr = np.corrcoef(year1, year2[:365])[0, 1]
                print(f"    第1年 vs 第2年温度相关系数: {corr:.6f}")
                if corr > 0.5:
                    print(f"    [OK] 温度有年周期性！季节系统在工作")
                else:
                    print(f"    [INFO] 温度年周期性弱")
        
        print()

if not found_variation:
    print("[ERROR] 所有样本格子的温度都几乎无变化！")
    print("[ERROR] 季节系统可能完全未工作")
    print()

# 检查直射点是否移动
print("[4] 检查太阳直射点是否移动（insolation_dev 应该随季节变化）")
if 'insolation_dev_arr' in df.columns:
    for cell_id in sample_cells[:3]:
        cell_data = df[df['cell_index'] == cell_id].sort_values('tick_idx')
        if len(cell_data) > 100:
            devs = cell_data['insolation_dev_arr'].values
            offsets = cell_data['temp_season_offset_arr'].values
            
            print(f"  格子 {cell_id}:")
            print(f"    insolation_dev 范围: [{devs.min():.6f}, {devs.max():.6f}]")
            print(f"    insolation_dev 标准差: {devs.std():.6f}")
            print(f"    season_offset 范围: [{offsets.min():.6f}, {offsets.max():.6f}]")
            print(f"    season_offset 标准差: {offsets.std():.6f}")
            print(f"    前30个tick的insolation_dev: {devs[:30]}")
            print(f"    前30个tick的season_offset: {offsets[:30]}")
            
            if devs.std() < 0.001:
                print(f"    [ERROR] insolation_dev几乎无变化！直射点可能未移动")
            else:
                print(f"    [OK] insolation_dev有变化，直射点可能在移动")
            print()

# 检查植被是否有季节变化
print("[5] 检查植被活力是否有季节变化")
if 'vegetation_vitality_arr' in df.columns:
    for cell_id in sample_cells[:3]:
        cell_data = df[df['cell_index'] == cell_id].sort_values('tick_idx')
        if len(cell_data) > 100:
            vit = cell_data['vegetation_vitality_arr'].values
            
            print(f"  格子 {cell_id}:")
            print(f"    植被活力范围: [{vit.min():.6f}, {vit.max():.6f}]")
            print(f"    植被活力标准差: {vit.std():.6f}")
            print(f"    前30个tick的植被活力: {vit[:30]}")
            
            if vit.std() < 0.001:
                print(f"    [ERROR] 植被活力几乎无变化！")
            else:
                print(f"    [OK] 植被活力有变化")
            print()

print("=" * 80)
print("检查完成")
print("=" * 80)
