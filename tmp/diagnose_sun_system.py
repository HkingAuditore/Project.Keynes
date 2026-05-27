#!/usr/bin/env python3
"""
诊断太阳直射点系统是否正常工作
"""
import pandas as pd
import numpy as np

print("=" * 80)
print("太阳直射点系统诊断")
print("=" * 80)
print()

# 1. 检查数据中是否有季节变化
print("【检查1】数据中是否有多个 tick（时间点）？")
df = pd.read_csv('d:/Godot/ProjectKeynes/Project.Keynes/tmp/tile_data_record_20260527_142740.csv', nrows=10000)
ticks = df['tick_idx'].unique()
print(f"  CSV 中的 tick 数量: {len(ticks)}")
print(f"  tick 范围: {ticks.min()} - {ticks.max()}")
print(f"  tick 列表: {ticks[:10]}...")

if len(ticks) <= 1:
    print("  ⚠️ 数据只有1个时间点！无法判断季节变化。")
    print("  ⚠️ 需要录制多个连续tick的数据才能验证季节系统。")
    print()
else:
    print("  ✓ 数据包含多个时间点，可以检查季节变化。")
    print()

# 2. 检查同一格子在不同tick的温度变化
print("【检查2】同一格子的温度是否随tick变化？")
if len(ticks) > 1:
    # 选几个样本格子
    sample_cells = df['cell_id'].unique()[:5]
    for cell_id in sample_cells:
        cell_data = df[df['cell_id'] == cell_id].sort_values('tick_idx')
        if len(cell_data) > 1:
            temps = cell_data['temp_arr'].values
            lat = cell_data['cell_lat_norm_arr'].iloc[0]
            print(f"  格子 {cell_id} (纬度={lat:.4f}):")
            print(f"    温度范围: [{temps.min():.6f}, {temps.max():.6f}]")
            print(f"    温度标准差: {temps.std():.6f}")
            if temps.std() < 0.001:
                print(f"    [ERROR] 温度几乎无变化！季节系统可能未工作。")
            else:
                print(f"    [OK] 温度有变化，季节系统可能在工作。")
            print()

# 3. 检查 temp_baseline_year_arr 是否正确
print("【检查3】temp_baseline_year_arr（年基准温度）是否合理？")
if 'temp_baseline_year_arr' in df.columns:
    sample = df.iloc[0]
    lat = sample['cell_lat_norm_arr']
    temp_base = sample['temp_baseline_year_arr']
    
    # 理论值：pow(cos((ny-0.5)*pi), 1.2)
    ny = lat
    theory = pow(abs(np.cos((ny - 0.5) * np.pi)), 1.2)
    
    print(f"  样本格子: lat_norm={lat:.4f}")
    print(f"  实际 temp_baseline_year_arr = {temp_base:.6f}")
    print(f"  理论值 = {theory:.6f}")
    if abs(temp_base - theory) < 0.01:
        print(f"  [OK] 基准温度计算正确")
    else:
        print(f"  [ERROR] 基准温度计算错误！差异 = {temp_base - theory:.6f}")
    print()

# 4. 检查 temp_season_offset 是否非零
print("【检查4】temp_season_offset（季节偏移）是否非零？")
if 'temp_season_offset_arr' in df.columns:
    offsets = df['temp_season_offset_arr'].values
    print(f"  season_offset 范围: [{offsets.min():.6f}, {offsets.max():.6f}]")
    print(f"  season_offset 均值: {offsets.mean():.6f}")
    print(f"  season_offset 标准差: {offsets.std():.6f}")
    if offsets.std() < 0.001:
        print(f"  [ERROR] season_offset 几乎为零！季节系统未工作。")
    else:
        print(f"  [OK] season_offset 有变化，季节系统在工作。")
    print()

# 5. 模拟太阳直射点计算
print("【检查5】模拟太阳直射点计算（验证代码逻辑）")
def subsolar_lat_rad(season_phase, axial_tilt_deg=23.5):
    year_progress = (season_phase % 4.0) / 4.0
    return np.deg2rad(axial_tilt_deg) * np.cos(2 * np.pi * year_progress)

def compute_insolation(ny, season_phase, axial_tilt_deg=23.5, amp=0.35):
    lat_rad = (ny - 0.5) * np.pi
    subsolar = subsolar_lat_rad(season_phase, axial_tilt_deg)
    cos_zenith = max(np.cos(lat_rad - subsolar), 0.0)
    year_progress = (season_phase % 4.0) / 4.0
    lat_sign = np.sign(lat_rad)
    daylen_factor = 1.0 + amp * np.cos(2 * np.pi * year_progress) * lat_sign
    return np.clip(cos_zenith * daylen_factor, 0.0, 1.0)

# 测试不同季节的日射
test_ny = 0.5  # 赤道
for phase in [0, 1, 2, 3]:  # 春夏秋冬
    insol = compute_insolation(test_ny, phase)
    print(f"  赤道, phase={phase}: insolation={insol:.4f}")

print()
print("=" * 80)
print("诊断完成")
print("=" * 80)
