"""v10(天气分类海陆分离重标后,实跑)验证 + 降水链路诊断。
A. 实跑天气分布(陆/海) + DROUGHT/FOG/RAIN by hop + 河流格 → 对比离线预测(DROUGHT~1.8%,FOG~5.5%)。
B. 降水链路 vapor→cloud_water→precip by hop: 定位"内陆雨少"瓶颈(输送/凝结/成雨哪一环)。
"""
import numpy as np, sys
from collections import deque
NPZ = sys.argv[1] if len(sys.argv) > 1 else r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_wx_fields_v10.npz'
z = np.load(NPZ, allow_pickle=True)
NC = int(z['NC']); ND = int(z['ND']); NB = z['NB']; warm = 40 if ND >= 80 else max(2, ND // 4)
is_water = z['st_is_water_arr'] > 0.5; land = ~is_water
has_river = z['st_has_river_arr'] > 0.5
elev = z['st_elevation_arr'].astype(float)
dy = lambda k: np.nan_to_num(z['dy_' + k].astype(float))
wt = np.nan_to_num(dy('weather_type_arr')[warm:]).astype(int)
vapor = dy('weather_vapor_arr')[warm:]; cloud = dy('weather_cloud_arr')[warm:]
cloudw = dy('weather_cloud_water_arr')[warm:]; precip = dy('weather_precip_arr')[warm:]
conv = dy('weather_convergence_arr')[warm:]
T = wt.shape[0]
names = {0: 'CLEAR', 1: 'RAIN', 2: 'STORM', 3: 'BLIZZARD', 4: 'DROUGHT', 5: 'FOG', 6: 'HEATWAVE', 7: 'MONSOON'}

print(f'NPZ={NPZ.split(chr(92))[-1]} T={T} land={int(land.sum())}')
print('\n=== A. 实跑天气分布 (陆地 / 海洋) ===')
for k, nm in names.items():
    fl = (wt[:, land] == k).mean() * 100; fs = (wt[:, is_water] == k).mean() * 100
    if fl > 0.2 or fs > 0.2:
        print(f'  {nm:>8}: 陆地{fl:6.1f}%   海洋{fs:6.1f}%')

hop = np.full(NC, -1, int); dq = deque()
for c in range(NC):
    if is_water[c]: hop[c] = 0; dq.append(c)
while dq:
    c = dq.popleft()
    for k in range(6):
        nb = NB[c, k]
        if nb >= 0 and hop[nb] < 0: hop[nb] = hop[c] + 1; dq.append(nb)

dfreq = (wt == 4).mean(0); ffreq = (wt == 5).mean(0); rfreq = (wt == 1).mean(0)
print('\n=== B1. DROUGHT / FOG / RAIN 频率 by hop ===')
print('  hop    DROUGHT   FOG    RAIN')
for h in range(1, 9):
    m = (hop == h) if h < 8 else (hop >= 8)
    if m.sum() < 3: continue
    print(f'  hop{h}: {dfreq[m].mean()*100:6.1f}% {ffreq[m].mean()*100:5.1f}% {rfreq[m].mean()*100:5.1f}%')
river = has_river & land
print(f'\n河流格: DROUGHT {dfreq[river].mean()*100:.1f}%  FOG {ffreq[river].mean()*100:.1f}%  RAIN {rfreq[river].mean()*100:.1f}%')

print('\n=== B2. 降水链路 by hop (时间均值): vapor → cloud_water → precip ===')
print('  hop      vapor   cloud_w    precip    conv |  cw/vapor  precip/cw  雨日%(p>.02)')
for h in range(0, 9):
    m = (hop == h) if h < 8 else (hop >= 8)
    if m.sum() < 3: continue
    v = vapor[:, m].mean(); cw = cloudw[:, m].mean(); pp = precip[:, m].mean(); cv = conv[:, m].mean()
    cwv = cw / v if v > 1e-6 else 0.0
    pcw = pp / cw if cw > 1e-6 else 0.0
    wetpct = (precip[:, m] > 0.02).mean() * 100
    tag = ' <海' if h == 0 else ''
    print(f'  hop{h}: {v:8.4f} {cw:8.4f} {pp:8.4f} {cv:7.3f} | {cwv:7.3f} {pcw:8.3f} {wetpct:7.1f}%{tag}')

print('\n=== B3. 内陆湿润事件能否成雨: 取陆地"高云水日"(cloud_water>p90)看其 precip ===')
land_cw = cloudw[:, land]
cw_p90 = np.percentile(land_cw, 90)
hi = land_cw > cw_p90
land_pp = precip[:, land]
print(f'  陆地 cloud_water p90={cw_p90:.4f};  高云水日 precip 均值={land_pp[hi].mean():.4f}  雨日%={ (land_pp[hi]>0.02).mean()*100:.1f}%')
print(f'  陆地 convergence: p50={np.percentile(conv[:,land],50):.3f} p90={np.percentile(conv[:,land],90):.3f}  (>0.38算强辐合占比 {(conv[:,land]>0.38).mean()*100:.1f}%)')
