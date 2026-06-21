"""天气分类阈值重标定: 采集海/陆各物理场的实际分位, 对照当前分类阈值,
判断哪些阈值与当前量级错位(advective 重构后 vapor/cloud 变小)。
当前关键阈值: humid vapor>0.28 | MONSOON vapor>0.40/cloud>0.45 | FOG vapor>0.34/cloud>0.14
            | meaningful_precip precip>0.030 或(>0.022&cloud>0.22&vapor>0.28)
            | STORM precip>0.060/instab>0.55 | DROUGHT vapor<0.34/cloud<0.22/precip<0.020/temp>0.48
"""
import numpy as np, sys
NPZ = sys.argv[1] if len(sys.argv) > 1 else r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_wx_fields_v9.npz'
z = np.load(NPZ, allow_pickle=True)
ND = int(z['ND']); warm = 40 if ND >= 80 else max(2, ND // 4)
is_water = z['st_is_water_arr'] > 0.5; land = ~is_water
dy = lambda k: np.nan_to_num(z['dy_' + k].astype(float))
fields = {'vapor': 'weather_vapor_arr', 'cloud': 'weather_cloud_arr', 'precip': 'weather_precip_arr',
          'temp': 'temp_arr', 'temp_anom': 'temp_anomaly_arr'}
ps = [50, 75, 90, 95, 99]
print(f'NPZ={NPZ.split(chr(92))[-1]}  分位 p50/75/90/95/99  (max)')
for nm, key in fields.items():
    a = dy(key)[warm:]
    print(f'\n{nm}:')
    for label, m in [('陆', land), ('海', is_water)]:
        v = a[:, m].ravel()
        qs = '  '.join(f'p{p}={np.percentile(v, p):.3f}' for p in ps)
        print(f'  {label}: {qs}  max={v.max():.3f}')

# 关键: 若想让某天气类型触发 X% 的时间, 阈值应设在 (100-X) 分位附近
print('\n=== 重标建议(让湿度类阈值落在实际分布内) ===')
vap = dy('weather_vapor_arr')[warm:]
cld = dy('weather_cloud_arr')[warm:]
prc = dy('weather_precip_arr')[warm:]
# 海洋是水汽主要来源,湿润天气应在海洋/沿海高分位触发
vap_sea = vap[:, is_water].ravel(); vap_land = vap[:, land].ravel()
print(f'vapor: 当前 humid门=0.28 → 海洋仅 {(vap_sea > 0.28).mean()*100:.1f}% / 陆地 {(vap_land > 0.28).mean()*100:.1f}% 超过(几乎打死湿润类)')
print(f'  若 humid门 设 海洋p75={np.percentile(vap_sea,75):.3f}: 海洋 {(vap_sea>np.percentile(vap_sea,75)).mean()*100:.0f}% / 陆地 {(vap_land>np.percentile(vap_sea,75)).mean()*100:.1f}% 触发')
cld_sea = cld[:, is_water].ravel(); cld_land = cld[:, land].ravel()
print(f'cloud: 当前 FOG门=0.14/DROUGHT<0.22 → 海洋 cloud>0.14 占 {(cld_sea>0.14).mean()*100:.1f}% / 陆地 {(cld_land>0.14).mean()*100:.1f}%')
