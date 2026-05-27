import pandas as pd
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

# 读取数据
df = pd.read_csv('d:/Godot/ProjectKeynes/Project.Keynes/tmp/tile_data_record_20260527_142740.csv', nrows=20000)

print('='*60)
print('完整诊断报告')
print('='*60)
print()

# ══════════════════════════════════════════════════════════
# 问题1：纬度归一化检查
# ══════════════════════════════════════════════════════════
print('【问题1】cell_lat_norm_arr 分布检查')
print('-'*60)
lat = df['cell_lat_norm_arr']
print(f'纬度范围: [{lat.min():.6f}, {lat.max():.6f}]')
print(f'纬度均值: {lat.mean():.6f}')
print(f'纬度中位数: {lat.median():.6f}')

# 检查纬度分布是否均匀
lat_hist, lat_bins = np.histogram(lat, bins=20)
print(f'纬度分布直方图:')
for i in range(len(lat_hist)):
    print(f'  [{lat_bins[i]:.2f}, {lat_bins[i+1]:.2f}]: {lat_hist[i]}')
print()

# ══════════════════════════════════════════════════════════
# 问题2：温度与纬度的理论关系验证
# ══════════════════════════════════════════════════════════
print('【问题2】温度公式计算验证')
print('-'*60)
print('理论公式: temp_baseline = pow(cos((ny-0.5)*π), 1.2)')
print()

# 计算每个格子的理论温度
ny = df['cell_lat_norm_arr']
lat_signed = (ny - 0.5) * 2.0
temp_theoretical = np.power(np.cos(lat_signed * np.pi * 0.5), 1.2)
temp_theoretical = np.clip(temp_theoretical, 0, 1)

# 与实际温度比较
temp_actual = df['temp_arr']
valid_mask = (temp_actual > 0) & (temp_theoretical > 0)

if valid_mask.sum() > 0:
    corr = np.corrcoef(temp_theoretical[valid_mask], temp_actual[valid_mask])[0,1]
    print(f'理论温度 vs 实际温度 相关系数: {corr:.4f}')
    print(f'理论温度范围: [{temp_theoretical.min():.4f}, {temp_theoretical.max():.4f}]')
    print(f'实际温度范围: [{temp_actual[temp_actual>0].min():.4f}, {temp_actual.max():.4f}]')
    print()
    
    # 采样比较
    print('采样比较（前20个有效格子）:')
    valid_idx = temp_actual[temp_actual > 0].index[:20]
    for idx in valid_idx:
        ny_val = ny.loc[idx]
        theo = temp_theoretical.loc[idx]
        actual = temp_actual.loc[idx]
        print(f'  ny={ny_val:.3f}, 理论={theo:.4f}, 实际={actual:.4f}, 差异={abs(theo-actual):.4f}')
print()

# ══════════════════════════════════════════════════════════
# 问题3：植被活力异常诊断
# ══════════════════════════════════════════════════════════
print('【问题3】植被活力异常诊断')
print('-'*60)
vit = df['vegetation_vitality_arr']
print(f'植被活力范围: [{vit.min():.6f}, {vit.max():.6f}]')
print(f'植被活力标准差: {vit.std():.6f}')
print(f'植被活力变异系数: {vit.std()/vit.mean():.6f}')

# 检查是否所有值都接近某个常数
print()
print('植被活力分布（分位数）:')
print(f'  0% (min):   {vit.quantile(0.00):.6f}')
print(f'  5%:          {vit.quantile(0.05):.6f}')
print(f'  25%:         {vit.quantile(0.25):.6f}')
print(f'  50% (median):{vit.quantile(0.50):.6f}')
print(f'  75%:         {vit.quantile(0.75):.6f}')
print(f'  95%:         {vit.quantile(0.95):.6f}')
print(f'  100% (max):  {vit.quantile(1.00):.6f}')
print()

# 检查植被活力与降水的关系
precip = df['weather_precip_arr']
valid_vit_precip = (vit > 0) & (precip > 0)
if valid_vit_precip.sum() > 10:
    corr = vit[valid_vit_precip].corr(precip[valid_vit_precip])
    print(f'植被活力 vs 降水 相关系数: {corr:.4f}')
    print('  期望: 正相关（降水多→植被好）')
    if corr < 0:
        print('  ⚠️ 异常: 负相关！')
print()

# ══════════════════════════════════════════════════════════
# 问题4：海冰分布检查
# ══════════════════════════════════════════════════════════
print('【问题4】海冰分布检查')
print('-'*60)
sea_ice = df['sea_ice_frac_arr']
has_ice = sea_ice > 0.01
print(f'有海冰的格子数: {has_ice.sum()}')
if has_ice.sum() > 0:
    avg_lat = df.loc[has_ice, 'cell_lat_norm_arr'].mean()
    min_lat = df.loc[has_ice, 'cell_lat_norm_arr'].min()
    max_lat = df.loc[has_ice, 'cell_lat_norm_arr'].max()
    print(f'海冰平均纬度: {avg_lat:.4f}')
    print(f'海冰纬度范围: [{min_lat:.4f}, {max_lat:.4f}]')
    print('  期望: 海冰应在高纬度（>0.7 或 <0.3）')
    if avg_lat < 0.6:
        print('  ⚠️ 异常: 海冰在中低纬度！')
print()

# ══════════════════════════════════════════════════════════
# 问题5：风场检查
# ══════════════════════════════════════════════════════════
print('【问题5】风场数据检查')
print('-'*60)
wind_speed = df['wind_speed_arr']
print(f'风速范围: [{wind_speed.min():.4f}, {wind_speed.max():.4f}]')
print(f'风速>1的格子数: {(wind_speed > 1).sum()}')
print(f'风速>1的比例: {(wind_speed > 1).sum()/len(wind_speed)*100:.1f}%')
print('  如果归一化，风速不应超过1.0')
print()

# ══════════════════════════════════════════════════════════
# 生成散点图
# ══════════════════════════════════════════════════════════
print('生成诊断图表...')

fig, axes = plt.subplots(2, 3, figsize=(15, 10))

# 图1：纬度 vs 温度
ax1 = axes[0, 0]
valid = df['temp_arr'] > 0
scatter = ax1.scatter(df.loc[valid, 'cell_lat_norm_arr'], 
                      df.loc[valid, 'temp_arr'], 
                      alpha=0.3, s=5)
ax1.set_xlabel('Latitude (normalized)')
ax1.set_ylabel('Temperature')
ax1.set_title('Latitude vs Temperature')
ax1.grid(True, alpha=0.3)

# 图2：海拔 vs 温度
ax2 = axes[0, 1]
valid = (df['temp_arr'] > 0) & (df['elevation_arr'] > 0)
scatter = ax2.scatter(df.loc[valid, 'elevation_arr'], 
                      df.loc[valid, 'temp_arr'], 
                      alpha=0.3, s=5)
ax2.set_xlabel('Elevation')
ax2.set_ylabel('Temperature')
ax2.set_title('Elevation vs Temperature')
ax2.grid(True, alpha=0.3)

# 图3：降水 vs 植被活力
ax3 = axes[0, 2]
valid = (df['weather_precip_arr'] > 0) & (df['vegetation_vitality_arr'] > 0)
if valid.sum() > 10:
    scatter = ax3.scatter(df.loc[valid, 'weather_precip_arr'], 
                          df.loc[valid, 'vegetation_vitality_arr'], 
                          alpha=0.3, s=5)
    ax3.set_xlabel('Precipitation')
    ax3.set_ylabel('Vegetation Vitality')
    ax3.set_title('Precipitation vs Vegetation')
    ax3.grid(True, alpha=0.3)

# 图4：纬度分布直方图
ax4 = axes[1, 0]
ax4.hist(df['cell_lat_norm_arr'], bins=50, edgecolor='black')
ax4.set_xlabel('Latitude (normalized)')
ax4.set_ylabel('Count')
ax4.set_title('Latitude Distribution')
ax4.grid(True, alpha=0.3)

# 图5：植被活力分布直方图
ax5 = axes[1, 1]
ax5.hist(df['vegetation_vitality_arr'], bins=50, edgecolor='black')
ax5.set_xlabel('Vegetation Vitality')
ax5.set_ylabel('Count')
ax5.set_title('Vegetation Vitality Distribution')
ax5.grid(True, alpha=0.3)

# 图6：海冰纬度分布
ax6 = axes[1, 2]
has_ice = df['sea_ice_frac_arr'] > 0.01
if has_ice.sum() > 0:
    ax6.scatter(df.loc[has_ice, 'cell_lat_norm_arr'], 
                df.loc[has_ice, 'sea_ice_frac_arr'], 
                alpha=0.5, s=10, c='blue')
    ax6.set_xlabel('Latitude (normalized)')
    ax6.set_ylabel('Sea Ice Fraction')
    ax6.set_title('Sea Ice Distribution')
    ax6.grid(True, alpha=0.3)

plt.tight_layout()
plt.savefig('d:/Godot/ProjectKeynes/Project.Keynes/tmp/diagnosis_plots.png', dpi=150)
print('图表已保存到: d:/Godot/ProjectKeynes/Project.Keynes/tmp/diagnosis_plots.png')
print()

print('='*60)
print('诊断完成')
print('='*60)
