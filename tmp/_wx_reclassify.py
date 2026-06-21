"""离线验证天气分类重标: 用 v9 已导出的物理场(vapor/cloud/precip/temp/temp_anom)
套用 旧 vs 新 分类逻辑, 对比天气分布。物理场不变、只换分类阈值 → 预测重标效果。
注: STORM(2) 需 instability/ocean_an、BLIZZARD 过渡带需 wind, 部分缺失→降级处理(陆地 STORM/BLIZZARD
实跑本就≈0,不影响陆地结论)。先校验"重算旧分布≈实跑weather_type_arr",再看新分布。
"""
import numpy as np, sys
from collections import deque
NPZ = sys.argv[1] if len(sys.argv) > 1 else r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_wx_fields_v9.npz'
z = np.load(NPZ, allow_pickle=True)
NC = int(z['NC']); ND = int(z['ND']); NB = z['NB']; warm = 40 if ND >= 80 else max(2, ND // 4)
is_water = z['st_is_water_arr'] > 0.5; land = ~is_water
has_river = z['st_has_river_arr'] > 0.5
have = lambda k: ('dy_' + k) in z.files
dy = lambda k: np.nan_to_num(z['dy_' + k].astype(float))
vapor = dy('weather_vapor_arr')[warm:]; cloud = dy('weather_cloud_arr')[warm:]
precip = dy('weather_precip_arr')[warm:]; temp = dy('temp_arr')[warm:]
tanom = dy('temp_anomaly_arr')[warm:]
wt_real = np.nan_to_num(dy('weather_type_arr')[warm:]).astype(int)
inst = dy('weather_instability_arr')[warm:] if have('weather_instability_arr') else np.zeros_like(vapor)
T = vapor.shape[0]
isw = np.broadcast_to(is_water, vapor.shape)

def classify(NEW):
    warm_b = temp > 0.55; hot = temp > 0.64
    if NEW:
        hg = np.where(isw, 0.28, 0.07); mpc = np.where(isw, 0.22, 0.05); mpv = np.where(isw, 0.28, 0.05)
        mv = np.where(isw, 0.40, 0.12); mp_ = np.where(isw, 0.055, 0.035); mc = np.where(isw, 0.45, 0.10)
        fv = np.where(isw, 0.34, 0.07); fc = np.where(isw, 0.14, 0.05)
    else:
        hg = mpv = 0.28; mpc = 0.22; mv = 0.40; mp_ = 0.055; mc = 0.45; fv = 0.34; fc = 0.14
    humid = vapor > hg
    mp = (precip > 0.030) | ((precip > 0.022) & (cloud > mpc) & (vapor > mpv))
    out = np.zeros(temp.shape, np.int8); asg = np.zeros(temp.shape, bool)
    def setwt(mask, val):
        m = mask & ~asg; out[m] = val; asg[m] = True
    setwt(mp & (temp <= 0.24), 3)                                  # BLIZZARD(极冷分支)
    setwt(warm_b & humid & (inst > 0.55) & (precip > 0.060), 2)    # STORM(inst 缺则为0→陆地不触发)
    setwt(warm_b & (vapor > mv) & (precip > mp_) & (cloud > mc), 7)  # MONSOON
    setwt(mp, 1)                                                   # RAIN
    setwt((vapor > fv) & (cloud > fc) & (precip < 0.030) & (temp < 0.55), 5)  # FOG
    setwt(hot & (tanom > 0.0) & (cloud < 0.38) & (precip < 0.025), 6)         # HEATWAVE
    if NEW:
        setwt((temp > 0.55) & (tanom > 0.10) & (precip < 0.020) & (cloud < 0.22), 4)  # DROUGHT(新:异常驱动)
    else:
        setwt((cloud < 0.22) & (precip < 0.020) & (temp > 0.48) & (vapor < 0.34), 4)  # DROUGHT(旧)
    return out

old = classify(False); new = classify(True)
names = {0: 'CLEAR', 1: 'RAIN', 2: 'STORM', 3: 'BLIZZARD', 4: 'DROUGHT', 5: 'FOG', 6: 'HEATWAVE', 7: 'MONSOON'}
print(f'NPZ={NPZ.split(chr(92))[-1]} T={T} (inst{"有" if have("weather_instability_arr") else "缺→STORM降级"})')
print('\n=== 重算逼真度校验: 重算旧 vs 实跑weather_type(陆地) ===')
for k in [0, 1, 4, 6]:
    print(f'  {names[k]:>8}: 重算旧 {(old[:,land]==k).mean()*100:5.1f}%  实跑 {(wt_real[:,land]==k).mean()*100:5.1f}%')
print('\n=== 陆地天气分布: 旧 → 新 ===')
for k, nm in names.items():
    print(f'  {nm:>8}: {(old[:,land]==k).mean()*100:5.1f}% → {(new[:,land]==k).mean()*100:5.1f}%')
print('=== 海洋天气分布: 旧 → 新 (验证海洋不被破坏) ===')
for k, nm in names.items():
    fo = (old[:, is_water] == k).mean() * 100; fn = (new[:, is_water] == k).mean() * 100
    if fo > 0.3 or fn > 0.3:
        print(f'  {nm:>8}: {fo:5.1f}% → {fn:5.1f}%')

hop = np.full(NC, -1, int); dq = deque()
for c in range(NC):
    if is_water[c]: hop[c] = 0; dq.append(c)
while dq:
    c = dq.popleft()
    for k in range(6):
        nb = NB[c, k]
        if nb >= 0 and hop[nb] < 0: hop[nb] = hop[c] + 1; dq.append(nb)
do = (old == 4).mean(0); dn = (new == 4).mean(0)
print('\n=== DROUGHT频率 by hop: 旧 → 新 ===')
for h in range(1, 9):
    m = (hop == h) if h < 8 else (hop >= 8)
    if m.sum() < 3: continue
    print(f'  hop{h}: {do[m].mean()*100:5.1f}% → {dn[m].mean()*100:5.1f}%')
river = has_river & land
print(f'\n河流格 DROUGHT: 旧 {do[river].mean()*100:.1f}% → 新 {dn[river].mean()*100:.1f}%')
print(f'陆地>50%时间DROUGHT的格子占比: 旧 {(do[land]>0.5).mean()*100:.1f}% → 新 {(dn[land]>0.5).mean()*100:.1f}%')
