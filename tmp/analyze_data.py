import pandas as pd
import numpy as np

df = pd.read_csv('d:/Godot/ProjectKeynes/Project.Keynes/tmp/tile_data_record_20260527_142740.csv', nrows=5000)

print('=== 数据质量诊断报告 ===')
print()

# 1. 纬度-温度关系（关键物理约束）
print('【问题1】纬度与温度关系')
print('期望：赤道(低纬度)温度高，极点(高纬度)温度低')
print()
lat_groups = df.groupby(pd.cut(df['cell_lat_norm_arr'], bins=5))
for name, group in lat_groups:
    avg_temp = group['temp_arr'].mean()
    print(f'  纬度区间 {name}: 平均温度={avg_temp:.4f}, 格子数={len(group)}')
print()

# 2. 海拔-温度关系
print('【问题2】海拔与温度关系')
print('期望：海拔越高，温度越低')
print()
elev_groups = df.groupby(pd.cut(df['elevation_arr'], bins=5))
for name, group in elev_groups:
    avg_temp = group['temp_arr'].mean()
    print(f'  海拔区间 {name}: 平均温度={avg_temp:.4f}, 格子数={len(group)}')
print()

# 3. 植被活力异常
print('【问题3】植被活力分布异常')
vit = df['vegetation_vitality_arr']
print(f'  最小值: {vit.min():.6f}')
print(f'  最大值: {vit.max():.6f}')
print(f'  标准差: {vit.std():.6f}')
print(f'  变异系数: {vit.std()/vit.mean():.6f}')
print('  期望: 植被活力应该有显著空间差异(森林>草原>沙漠)')
print()

# 4. 降水-植被关系
print('【问题4】降水与植被关系')
valid = df[(df['weather_precip_arr'] > 0) & (df['vegetation_vitality_arr'] > 0)]
if len(valid) > 10:
    corr = valid['weather_precip_arr'].corr(valid['vegetation_vitality_arr'])
    print(f'  相关系数: {corr:.4f}')
    print('  期望: 正相关(降水多->植被好)')
print()

# 5. 海冰分布
print('【问题5】海冰纬度分布')
sea_ice = df[df['sea_ice_frac_arr'] > 0.1]
if len(sea_ice) > 0:
    print(f'  有海冰的格子数: {len(sea_ice)}')
    print(f'  平均纬度: {sea_ice["cell_lat_norm_arr"].mean():.4f}')
    print('  期望: 海冰应在高纬度(>0.7)')
print()

# 6. 温度范围
print('【问题6】温度数值范围')
temp = df['temp_arr'][df['temp_arr'] > 0]
print(f'  温度范围: [{temp.min():.4f}, {temp.max():.4f}]')
print(f'  温度均值: {temp.mean():.4f}')
print('  如果归一化到[0,1]，期望赤道~0.8-1.0，极点~0.0-0.2')
print()

# 7. 风场检查
print('【问题7】风场数据')
wind = df['wind_speed_arr']
print(f'  风速范围: [{wind.min():.4f}, {wind.max():.4f}]')
print(f'  风速>1的格子: {(wind > 1).sum()}')
print('  如果归一化，风速不应超过1.0')
print()

# 8. 地形与植被
print('【问题8】地形-植被关系')
land = df[df['is_water_arr'] == 0]
if len(land) > 0:
    terrain_vit = land.groupby('terrain_arr')['vegetation_vitality_arr'].mean()
    print('  不同地形的平均植被活力:')
    print(terrain_vit)
    print('  期望: 平原>山地，沿海>内陆')
