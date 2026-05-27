import pandas as pd
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

# 读取数据
df = pd.read_csv('d:/Godot/ProjectKeynes/Project.Keynes/tmp/tile_data_record_20260527_142740.csv', nrows=20000)

print('='*60)
print('Complete Diagnosis Report')
print('='*60)
print()

# [Problem 1] Latitude normalization check
print('[Problem 1] cell_lat_norm_arr distribution check')
print('-'*60)
lat = df['cell_lat_norm_arr']
print(f'Latitude range: [{lat.min():.6f}, {lat.max():.6f}]')
print(f'Latitude mean: {lat.mean():.6f}')
print(f'Latitude median: {lat.median():.6f}')

# Check if latitude distribution is uniform
lat_hist, lat_bins = np.histogram(lat, bins=20)
print(f'Latitude distribution histogram:')
for i in range(len(lat_hist)):
    print(f'  [{lat_bins[i]:.2f}, {lat_bins[i+1]:.2f}]: {lat_hist[i]}')
print()

# [Problem 2] Temperature and latitude relationship verification
print('[Problem 2] Temperature formula verification')
print('-'*60)
print('Theoretical formula: temp_baseline = pow(cos((ny-0.5)*pi), 1.2)')
print()

# Calculate theoretical temperature for each cell
ny = df['cell_lat_norm_arr']
lat_signed = (ny - 0.5) * 2.0
temp_theoretical = np.power(np.cos(lat_signed * np.pi * 0.5), 1.2)
temp_theoretical = np.clip(temp_theoretical, 0, 1)

# Compare with actual temperature
temp_actual = df['temp_arr']
valid_mask = (temp_actual > 0) & (temp_theoretical > 0)

if valid_mask.sum() > 0:
    corr = np.corrcoef(temp_theoretical[valid_mask], temp_actual[valid_mask])[0,1]
    print(f'Theoretical vs Actual temperature correlation: {corr:.4f}')
    print(f'Theoretical temp range: [{temp_theoretical.min():.4f}, {temp_theoretical.max():.4f}]')
    print(f'Actual temp range: [{temp_actual[temp_actual>0].min():.4f}, {temp_actual.max():.4f}]')
    print()
    
    # Sample comparison
    print('Sample comparison (first 20 valid cells):')
    valid_idx = temp_actual[temp_actual > 0].index[:20]
    for idx in valid_idx:
        ny_val = ny.loc[idx]
        theo = temp_theoretical.loc[idx]
        actual = temp_actual.loc[idx]
        print(f'  ny={ny_val:.3f}, theoretical={theo:.4f}, actual={actual:.4f}, diff={abs(theo-actual):.4f}')
print()

# [Problem 3] Vegetation vitality anomaly diagnosis
print('[Problem 3] Vegetation vitality anomaly diagnosis')
print('-'*60)
vit = df['vegetation_vitality_arr']
print(f'Vegetation vitality range: [{vit.min():.6f}, {vit.max():.6f}]')
print(f'Vegetation vitality std: {vit.std():.6f}')
print(f'Vegetation vitality CV: {vit.std()/vit.mean():.6f}')

# Check if all values are close to a constant
print()
print('Vegetation vitality distribution (quantiles):')
print(f'  0% (min):   {vit.quantile(0.00):.6f}')
print(f'  5%:          {vit.quantile(0.05):.6f}')
print(f'  25%:         {vit.quantile(0.25):.6f}')
print(f'  50% (median):{vit.quantile(0.50):.6f}')
print(f'  75%:         {vit.quantile(0.75):.6f}')
print(f'  95%:         {vit.quantile(0.95):.6f}')
print(f'  100% (max):  {vit.quantile(1.00):.6f}')
print()

# Check vegetation-precipitation relationship
precip = df['weather_precip_arr']
valid_vit_precip = (vit > 0) & (precip > 0)
if valid_vit_precip.sum() > 10:
    corr = vit[valid_vit_precip].corr(precip[valid_vit_precip])
    print(f'Vegetation vs Precipitation correlation: {corr:.4f}')
    print('  Expected: Positive correlation (more precip -> better vegetation)')
    if corr < 0:
        print('  WARNING: Negative correlation detected!')
print()

# [Problem 4] Sea ice distribution check
print('[Problem 4] Sea ice distribution check')
print('-'*60)
sea_ice = df['sea_ice_frac_arr']
has_ice = sea_ice > 0.01
print(f'Cells with sea ice: {has_ice.sum()}')
if has_ice.sum() > 0:
    avg_lat = df.loc[has_ice, 'cell_lat_norm_arr'].mean()
    min_lat = df.loc[has_ice, 'cell_lat_norm_arr'].min()
    max_lat = df.loc[has_ice, 'cell_lat_norm_arr'].max()
    print(f'Sea ice average latitude: {avg_lat:.4f}')
    print(f'Sea ice latitude range: [{min_lat:.4f}, {max_lat:.4f}]')
    print('  Expected: Sea ice should be at high latitudes (>0.7 or <0.3)')
    if avg_lat < 0.6:
        print('  WARNING: Sea ice at mid-latitudes!')
print()

# [Problem 5] Wind field check
print('[Problem 5] Wind field data check')
print('-'*60)
wind_speed = df['wind_speed_arr']
print(f'Wind speed range: [{wind_speed.min():.4f}, {wind_speed.max():.4f}]')
print(f'Cells with wind speed > 1: {(wind_speed > 1).sum()}')
print(f'Percentage > 1: {(wind_speed > 1).sum()/len(wind_speed)*100:.1f}%')
print('  If normalized, wind speed should not exceed 1.0')
print()

# [Problem 6] Temperature-elevation relationship
print('[Problem 6] Temperature-elevation relationship')
print('-'*60)
valid = (df['temp_arr'] > 0) & (df['elevation_arr'] > 0)
if valid.sum() > 100:
    corr = df.loc[valid, 'elevation_arr'].corr(df.loc[valid, 'temp_arr'])
    print(f'Temperature-elevation correlation: {corr:.4f}')
    print('  Expected: Negative correlation (higher elevation -> lower temperature)')
    if corr > 0:
        print('  WARNING: Positive correlation detected!')
print()

# Generate scatter plots
print('Generating diagnostic plots...')

fig, axes = plt.subplots(2, 3, figsize=(15, 10))

# Plot 1: Latitude vs Temperature
ax1 = axes[0, 0]
valid = df['temp_arr'] > 0
scatter = ax1.scatter(df.loc[valid, 'cell_lat_norm_arr'], 
                      df.loc[valid, 'temp_arr'], 
                      alpha=0.3, s=5)
ax1.set_xlabel('Latitude (normalized)')
ax1.set_ylabel('Temperature')
ax1.set_title('Latitude vs Temperature')
ax1.grid(True, alpha=0.3)

# Plot 2: Elevation vs Temperature
ax2 = axes[0, 1]
valid = (df['temp_arr'] > 0) & (df['elevation_arr'] > 0)
scatter = ax2.scatter(df.loc[valid, 'elevation_arr'], 
                      df.loc[valid, 'temp_arr'], 
                      alpha=0.3, s=5)
ax2.set_xlabel('Elevation')
ax2.set_ylabel('Temperature')
ax2.set_title('Elevation vs Temperature')
ax2.grid(True, alpha=0.3)

# Plot 3: Precipitation vs Vegetation vitality
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

# Plot 4: Latitude distribution histogram
ax4 = axes[1, 0]
ax4.hist(df['cell_lat_norm_arr'], bins=50, edgecolor='black')
ax4.set_xlabel('Latitude (normalized)')
ax4.set_ylabel('Count')
ax4.set_title('Latitude Distribution')
ax4.grid(True, alpha=0.3)

# Plot 5: Vegetation vitality distribution histogram
ax5 = axes[1, 1]
ax5.hist(df['vegetation_vitality_arr'], bins=50, edgecolor='black')
ax5.set_xlabel('Vegetation Vitality')
ax5.set_ylabel('Count')
ax5.set_title('Vegetation Vitality Distribution')
ax5.grid(True, alpha=0.3)

# Plot 6: Sea ice latitude distribution
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
print('Plots saved to: d:/Godot/ProjectKeynes/Project.Keynes/tmp/diagnosis_plots.png')
print()

print('='*60)
print('Diagnosis complete')
print('='*60)
