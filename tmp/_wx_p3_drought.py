"""P3 真问题(用户澄清): 天气类型频繁显示 DROUGHT(旱灾)。
DROUGHT 判定(C++ world_ext.cpp:3628 / gd weather_system.gd:2420):
  cloud<0.22 & precip<0.020 & temp>0.48 & vapor<0.34  → DROUGHT(分类树最后一档)
诊断: 各 weather_type 占比、DROUGHT by hop、河流格 DROUGHT、4条件在陆地的满足率
      (找出哪个阈值因内陆天然低而'形同虚设',据此设计收紧/相对化)。
"""
import numpy as np, sys
from collections import deque
NPZ = sys.argv[1] if len(sys.argv) > 1 else r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_wx_fields_v9.npz'
z = np.load(NPZ, allow_pickle=True)
NC = int(z['NC']); ND = int(z['ND']); NB = z['NB']; warm = 40 if ND >= 80 else max(2, ND // 4)
is_water = z['st_is_water_arr'] > 0.5; land = ~is_water
has_river = z['st_has_river_arr'] > 0.5
dy = lambda k: z['dy_' + k].astype(float)
wt = np.nan_to_num(dy('weather_type_arr')[warm:], nan=0.0)
vapor = np.nan_to_num(dy('weather_vapor_arr')[warm:])
cloud = np.nan_to_num(dy('weather_cloud_arr')[warm:])
precip = np.nan_to_num(dy('weather_precip_arr')[warm:])
temp = np.nan_to_num(dy('temp_arr')[warm:])
T = wt.shape[0]
DROUGHT = 4
names = {0: 'CLEAR', 1: 'RAIN', 2: 'STORM', 3: 'BLIZZARD', 4: 'DROUGHT', 5: 'FOG', 6: 'HEATWAVE', 7: 'MONSOON'}

print(f'NPZ={NPZ.split(chr(92))[-1]} T={T} land={int(land.sum())}')
print('=== weather_type 时间占比 (陆地 vs 海洋) ===')
for k, nm in names.items():
    fl = (wt[:, land] == k).mean() * 100
    fs = (wt[:, is_water] == k).mean() * 100
    print(f'  {nm:>9}: 陆地{fl:6.1f}%   海洋{fs:6.1f}%')

drought_freq = (wt == DROUGHT).mean(0)

hop = np.full(NC, -1, int); dq = deque()
for c in range(NC):
    if is_water[c]:
        hop[c] = 0; dq.append(c)
while dq:
    c = dq.popleft()
    for k in range(6):
        nb = NB[c, k]
        if nb >= 0 and hop[nb] < 0:
            hop[nb] = hop[c] + 1; dq.append(nb)

print('\n=== DROUGHT 频率 by hop(离海) ===')
for h in range(0, 9):
    m = (hop == h) if h < 8 else (hop >= 8)
    if m.sum() < 3:
        continue
    print(f'  hop{h}: n={int(m.sum()):>5} DROUGHT频率={drought_freq[m].mean()*100:5.1f}%')

river = has_river & land
plain = land & (~has_river)
print(f'\n河流格 DROUGHT频率={drought_freq[river].mean()*100:.1f}%   普通陆地={drought_freq[plain].mean()*100:.1f}%')
print(f'陆地 全年>50%时间是DROUGHT 的格子占比={ (drought_freq[land] > 0.5).mean()*100:.1f}%')

print('\n=== DROUGHT 4条件在陆地的满足率(高=该阈值形同虚设) ===')
L = land
c1 = (cloud[:, L] < 0.22).mean() * 100
c2 = (precip[:, L] < 0.020).mean() * 100
c3 = (temp[:, L] > 0.48).mean() * 100
c4 = (vapor[:, L] < 0.34).mean() * 100
call = ((cloud[:, L] < 0.22) & (precip[:, L] < 0.020) & (temp[:, L] > 0.48) & (vapor[:, L] < 0.34)).mean() * 100
print(f'  cloud<0.22 : {c1:5.1f}%')
print(f'  precip<0.02: {c2:5.1f}%')
print(f'  temp>0.48  : {c3:5.1f}%   <- 唯一真正起区分作用的条件?')
print(f'  vapor<0.34 : {c4:5.1f}%')
print(f'  全部4条件  : {call:5.1f}%')
print('\n陆地 vapor 分布: ' + '  '.join(f'p{p}={np.percentile(vapor[:, L], p):.3f}' for p in [10, 50, 90]))
print('陆地 cloud 分布: ' + '  '.join(f'p{p}={np.percentile(cloud[:, L], p):.3f}' for p in [10, 50, 90]))
print('陆地 precip分布: ' + '  '.join(f'p{p}={np.percentile(precip[:, L], p):.4f}' for p in [10, 50, 90]))
