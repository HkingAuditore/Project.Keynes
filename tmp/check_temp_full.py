#!/usr/bin/env python3
"""
检查temp_baseline_year_arr的全局正确性
"""
import pandas as pd
import numpy as np

print("=" * 80)
print("检查 temp_baseline_year_arr 全局正确性")
print("=" * 80)
print()

# 读取更多数据（500000行，覆盖多个tick和更多格子）
print("[1] 读取500000行数据...")
df = pd.read_csv('d:/Godot/ProjectKeynes/Project.Keynes/tmp/tile_data_record_20260527_142740.csv', 
                  usecols=['tick_idx', 'cell_index', 'cell_lat_norm_arr', 
                           'temp_baseline_year_arr', 'temp_arr', 'elevation_arr'],
                  nrows=500000)
print(f"  读取行数: {len(df)}")
print(f"  唯一tick数: {df['tick_idx'].nunique()}")
print(f"  唯一cell数: {df['cell_index'].nunique()}")
print()

# 检查纬度覆盖范围
print("[2] 纬度覆盖范围")
lats = df['cell_lat_norm_arr']
print(f"  纬度范围: [{lats.min():.4f}, {lats.max():.4f}]")
print(f"  唯一纬度值数量: {lats.nunique()}")
print()

# 如果是全图，检查纬度-温度相关性
if lats.nunique() > 10:
    print("[3] 纬度-温度相关性（全图快照）")
    # 取最后一个tick的快照
    max_tick = df['tick_idx'].max()
    df_snap = df[df['tick_idx'] == max_tick]
    print(f"  快照tick: {max_tick}")
    print(f"  快照格子数: {len(df_snap)}")
    
    if len(df_snap) > 100:
        corr_temp = df_snap['cell_lat_norm_arr'].corr(df_snap['temp_arr'])
        corr_base = df_snap['cell_lat_norm_arr'].corr(df_snap['temp_baseline_year_arr'])
        print(f"  temp_arr 与 lat 相关性: {corr_temp:.6f} (应该≈-0.8)")
        print(f"  temp_baseline_year_arr 与 lat 相关性: {corr_base:.6f} (应该≈-0.8)")
        print()
        
        if corr_base > 0:
            print("  [ERROR] temp_baseline_year_arr 与纬度正相关！")
            print("  [ERROR] 基准温度场完全错误！")
            print()
        
        # 显示不同纬度的温度
        print("  [4] 不同纬度的平均温度")
        df_snap['lat_bin'] = pd.cut(df_snap['cell_lat_norm_arr'], bins=20)
        lat_stats = df_snap.groupby('lat_bin', observed=False).agg({
            'temp_baseline_year_arr': ['mean', 'std'],
            'temp_arr': ['mean', 'std'],
            'cell_lat_norm_arr': 'mean'
        }).reset_index()
        lat_stats.columns = ['lat_bin', 'base_mean', 'base_std', 'temp_mean', 'temp_std', 'lat_center']
        print("  纬度区间 | base_mean | temp_mean")
        for _, row in lat_stats.iterrows():
            print(f"  {row['lat_center']:.4f}    | {row['base_mean']:.6f} | {row['temp_mean']:.6f}")
        print()

# 检查temp_baseline_year_arr的计算公式
print("[5] 验证 temp_baseline_year_arr 计算公式")
print("  理论公式: pow(cos((ny-0.5)*pi), 1.2)")
print()

# 取样一些格子，对比理论和实际
sample = df.sample(min(100, len(df))).copy()
sample['theory'] = sample['cell_lat_norm_arr'].apply(
    lambda ny: pow(abs(np.cos((ny - 0.5) * np.pi)), 1.2)
)
sample['diff'] = sample['temp_baseline_year_arr'] - sample['theory']
print(f"  理论值范围: [{sample['theory'].min():.6f}, {sample['theory'].max():.6f}]")
print(f"  实际值范围: [{sample['temp_baseline_year_arr'].min():.6f}, {sample['temp_baseline_year_arr'].max():.6f}]")
print(f"  平均差异: {sample['diff'].mean():.6f}")
print(f"  最大差异: {sample['diff'].max():.6f}")
print()

if sample['diff'].abs().max() > 0.01:
    print("  [ERROR] temp_baseline_year_arr 计算公式错误！")
    print("  [ERROR] 实际值与理论值差异巨大！")
else:
    print("  [OK] temp_baseline_year_arr 计算公式正确")

print()
print("=" * 80)
print("检查完成")
print("=" * 80)
