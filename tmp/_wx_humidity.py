"""定位用户说的"湿度0.3": 列出各候选湿度字段在 陆地/海边(hop1)/河边 的值,找谁≈0.3。
+ 降雨成因: 各 weather_type 的降水贡献(看是不是只有对流/单一来源在下雨)。
"""
import numpy as np, sys
from collections import deque
NPZ = sys.argv[1] if len(sys.argv) > 1 else r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_wx_fields_v11.npz'
z = np.load(NPZ, allow_pickle=True)
NC = int(z['NC']); ND = int(z['ND']); NB = z['NB']; warm = 40 if ND >= 80 else max(2, ND // 4)
is_water = z['st_is_water_arr'] > 0.5; land = ~is_water
has_river = z['st_has_river_arr'] > 0.5
print(f'NPZ={NPZ.split(chr(92))[-1]} ND={ND} land={int(land.sum())}')
print('npz字段:', [k for k in z.files if k.startswith('st_')])

hop = np.full(NC, -1, int); dq = deque()
for c in range(NC):
    if is_water[c]: hop[c] = 0; dq.append(c)
while dq:
    c = dq.popleft()
    for k in range(6):
        nb = NB[c, k]
        if nb >= 0 and hop[nb] < 0: hop[nb] = hop[c] + 1; dq.append(nb)
coast = land & (hop == 1)
river = land & has_river

st_moist = z['st_moisture_arr'].astype(float)
dy = lambda k: np.nan_to_num(z['dy_' + k].astype(float))
soil = dy('soil_moisture_arr')[warm:]            # 距平场
vapor = dy('weather_vapor_arr')[warm:]
cloudw = dy('weather_cloud_water_arr')[warm:]

def stat_static(name, arr):
    print(f'  {name:28}: 陆地 p10/50/90={np.percentile(arr[land],10):.3f}/{np.percentile(arr[land],50):.3f}/{np.percentile(arr[land],90):.3f}  海边={arr[coast].mean():.3f}  河边={arr[river].mean():.3f}  海洋={arr[is_water].mean():.3f}')

def stat_daily(name, arr2d):
    a = arr2d.mean(0)  # 每格时间均值
    stat_static(name, a)

print('\n=== 候选"湿度"字段 (找谁海边/河边≈0.3) ===')
stat_static('moisture_arr (地块湿度,静态)', st_moist)
stat_daily('soil_moisture (距平原值)', soil)
stat_daily('soil_moisture 实际(0.5+距平)', 0.5 + soil)
stat_daily('weather_vapor (大气水汽)', vapor)
stat_daily('weather_cloud_water', cloudw)

print('\n=== 降雨成因: 各天气类型的降水贡献(陆地) ===')
wt = np.nan_to_num(dy('weather_type_arr')[warm:]).astype(int)
precip = dy('weather_precip_arr')[warm:]
names = {0: 'CLEAR', 1: 'RAIN', 2: 'STORM', 3: 'BLIZZARD', 4: 'DROUGHT', 5: 'FOG', 6: 'HEATWAVE', 7: 'MONSOON'}
wtL = wt[:, land]; ppL = precip[:, land]
tot_precip = ppL.sum()
print(f'  陆地总降水量(相对) 占比 + 各类型时占比 + 该类型平均precip:')
for k, nm in names.items():
    m = wtL == k
    occ = m.mean() * 100
    contrib = ppL[m].sum() / tot_precip * 100 if tot_precip > 0 else 0
    mean_pp = ppL[m].mean() if m.any() else 0
    if occ > 0.2 or contrib > 0.5:
        print(f'    {nm:>8}: 时占比{occ:5.1f}%  降水贡献{contrib:5.1f}%  平均precip={mean_pp:.4f}')

# 内陆雨日(对流雨增强后) by hop, 验证上一轮效果
print('\n=== (验证对流雨增强) 内陆雨日%(precip>0.02) by hop ===')
for h in range(1, 9):
    m = (hop == h) if h < 8 else (hop >= 8)
    if m.sum() < 3: continue
    wet = (precip[:, m] > 0.02).mean() * 100
    print(f'  hop{h}: 雨日 {wet:5.1f}%  precip均值={precip[:,m].mean():.4f}')
