#!/usr/bin/env python3
"""
检查是否有明显的四季变化
"""
import pandas as pd
import numpy as np

print("=" * 80)
print("检查四季变化")
print("=" * 80)
print()

# 读取多个tick的数据（100000行，覆盖约40个tick）
print("[1] 读取时间序列数据...")
df = pd.read_csv('d:/Godot/ProjectKeynes/Project.Keynes/tmp/tile_data_record_20260527_142740.csv', 
                  usecols=['tick_idx', 'cell_index', 'cell_lat_norm_arr', 
                           'temp_arr', 'moisture_arr', 'temp_season_offset_arr',
                           'insolation_dev_arr', 'vegetation_vitality_arr',
                           'snow_cover_arr', 'sea_ice_frac_arr'],
                  nrows=200000)
print(f"  读取行数: {len(df)}")
print(f"  Tick范围: {df['tick_idx'].min()} - {df['tick_idx'].max()}")
print(f"  唯一tick数: {df['tick_idx'].nunique()}")
print()

# 检查时间跨度
ticks = df['tick_idx'].unique()
tick_span = ticks.max() - ticks.min()
print(f"  时间跨度: {tick_span} ticks ({tick_span/365:.1f} 年)")
print()

# 按纬度分组，检查每个纬度带的温度变化
print("[2] 按纬度带检查温度变化")
df['lat_band'] = pd.cut(df['cell_lat_norm_arr'], bins=10, labels=['北极', '高纬北', '中纬北', '低纬北', 
                                                                   '赤道', '低纬南', '中纬南', '高纬南', '亚南极', '南极'])
temp_by_lat = df.groupby(['tick_idx', 'lat_band'])['temp_arr'].mean().unstack(fill_value=np.nan)
print("  各纬度带的平均温度变化（前10个tick）:")
print(temp_by_lat.head(10).to_string())
print()

# 检查温度是否随时间变化
print("[3] 检查温度是否随时间变化（季节信号）")
# 选几个样本格子
sample_cells = df['cell_index'].unique()[:10]
for cell_id in sample_cells[:5]:
    cell_data = df[df['cell_index'] == cell_id].sort_values('tick_idx')
    if len(cell_data) > 50:
        temps = cell_data['temp_arr'].values
        ticks_cell = cell_data['tick_idx'].values
        lat = cell_data['cell_lat_norm_arr'].iloc[0]
        
        print(f"  格子 {cell_id} (纬度={lat:.3f}):")
        print(f"    温度范围: [{temps.min():.4f}, {temps.max():.4f}]")
        print(f"    温度标准差: {temps.std():.6f}")
        
        # 检查是否有周期性
        if len(temps) > 100:
            # 计算自相关（简化）
            temp_diff = np.diff(temps)
            sign_changes = np.sum((temp_diff[:-1] * temp_diff[1:]) < 0)
            print(f"    温度方向变化次数: {sign_changes}")
            
            if temps.std() < 0.01:
                print(f"    [ERROR] 温度几乎不变！无季节变化")
            else:
                print(f"    [OK] 温度有变化，可能有季节信号")
        
        # 显示前20个tick的温度
        print(f"    前20个tick温度: {temps[:20]}")
        print()

# 检查季节偏移是否变化
print("[4] 检查 temp_season_offset 是否随季节变化")
sample_cell = df['cell_index'].unique()[0]
cell_data = df[df['cell_index'] == sample_cell].sort_values('tick_idx')
if len(cell_data) > 50:
    offsets = cell_data['temp_season_offset_arr'].values
    devs = cell_data['insolation_dev_arr'].values
    print(f"  格子 {sample_cell}:")
    print(f"    season_offset 范围: [{offsets.min():.6f}, {offsets.max():.6f}]")
    print(f"    insolation_dev 范围: [{devs.min():.6f}, {devs.max():.6f}]")
    print(f"    前20个tick的season_offset: {offsets[:20]}")
    print(f"    前20个tick的insolation_dev: {devs[:20]}")
    
    if offsets.std() < 0.001:
        print(f"    [ERROR] season_offset几乎不变！直射点可能未移动")
    else:
        print(f"    [OK] season_offset有变化，直射点可能在移动")
    print()

# 检查植被是否有季节变化
print("[5] 检查植被是否有季节变化")
for cell_id in sample_cells[:3]:
    cell_data = df[df['cell_index'] == cell_id].sort_values('tick_idx')
    if len(cell_data) > 50:
        vit = cell_data['vegetation_vitality_arr'].values
        lat = cell_data['cell_lat_norm_arr'].iloc[0]
        print(f"  格子 {cell_id} (纬度={lat:.3f}):")
        print(f"    植被活力范围: [{vit.min():.6f}, {vit.max():.6f}]")
        print(f"    植被活力标准差: {vit.std():.6f}")
        if vit.std() < 0.001:
            print(f"    [ERROR] 植被活力几乎不变！")
        else:
            print(f"    [OK] 植被活力有变化")
        print()

print("=" * 80)
print("检查完成")
print("=" * 80)
