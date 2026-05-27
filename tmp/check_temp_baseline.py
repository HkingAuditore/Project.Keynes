#!/usr/bin/env python3
"""
检查温度基准场是否正确
"""
import pandas as pd
import numpy as np

print("=" * 80)
print("检查 temp_baseline_year_arr 是否正确")
print("=" * 80)
print()

# 读取最新tick的数据
print("[1] 读取最新tick的温度和纬度数据...")
df = pd.read_csv('d:/Godot/ProjectKeynes/Project.Keynes/tmp/tile_data_record_20260527_142740.csv', 
                  usecols=['tick_idx', 'cell_index', 'cell_lat_norm_arr', 
                           'temp_baseline_year_arr', 'temp_arr', 'elevation_arr'],
                  nrows=10000)
df_latest = df[df['tick_idx'] == df['tick_idx'].max()].copy()
print(f"  最新tick: {df_latest['tick_idx'].iloc[0]}")
print(f"  格子数: {len(df_latest)}")
print()

# 检查纬度-温度关系
print("[2] 纬度 vs 温度（应该负相关！）")
corr_temp = df_latest['cell_lat_norm_arr'].corr(df_latest['temp_arr'])
corr_base = df_latest['cell_lat_norm_arr'].corr(df_latest['temp_baseline_year_arr'])
print(f"  temp_arr 与 lat 的相关性: {corr_temp:.6f}  (应该≈-0.8)")
print(f"  temp_baseline_year_arr 与 lat 的相关性: {corr_base:.6f}  (应该≈-0.8)")
print()

# 显示一些样本
print("[3] 样本数据（按纬度排序）")
df_sorted = df_latest.sort_values('cell_lat_norm_arr').head(20)
print("  纬度(ny) | temp_base | temp_arr | 海拔")
for _, row in df_sorted.iterrows():
    ny = row['cell_lat_norm_arr']
    t_base = row['temp_baseline_year_arr']
    t_arr = row['temp_arr']
    elev = row['elevation_arr']
    print(f"  {ny:.4f}    | {t_base:.6f}  | {t_arr:.6f}  | {elev:.4f}")
print()

# 计算理论值
print("[4] 理论值 vs 实际值对比")
print("  ny  | 理论temp_base        | 实际temp_base        | 差异")
for ny in [0.0, 0.25, 0.5, 0.75, 1.0]:
    # 理论：pow(cos((ny-0.5)*pi), 1.2)
    theory = pow(abs(np.cos((ny - 0.5) * np.pi)), 1.2)
    # 从数据中找最接近的ny
    idx = (df_latest['cell_lat_norm_arr'] - ny).abs().idxmin()
    actual = df_latest.loc[idx, 'temp_baseline_year_arr']
    diff = actual - theory
    print(f"  {ny:.2f} | {theory:.6f}              | {actual:.6f}              | {diff:+.6f}")
print()

# 诊断：temp_baseline_year_arr 的公式可能错了
print("[5] 诊断：temp_baseline_year_arr 可能使用了错误的公式")
print("  正确公式: pow(cos((ny-0.5)*pi), 1.2)")
print("  如果相关性为正，可能：")
print("    - 使用了 pow(sin(...)) 而不是 pow(cos(...))")
print("    - ny 的定义反了（0=赤道, 1=极点 而不是 0=北极, 1=南极）")
print("    - 功率 1.2 变成了 -1.2")
print()

print("=" * 80)
print("检查完成")
print("=" * 80)
