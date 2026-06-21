"""问题2(雨云不动)诊断。核心指标:precip 场的时间自相关随 lag 衰减速度。
  移动的天气系统:lag 几天后自相关应显著下降(雨带移走了)。
  静止/永雨永旱:lag 很大仍高自相关(雨型钉死不动)。
另:perma_rain/dry 占比 + wet 区质心逐日位移(雨带整体是否平移)。
"""
import numpy as np
import sys
NPZ = sys.argv[1] if len(sys.argv) > 1 else r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_wx_fields_v7.npz'
z = np.load(NPZ, allow_pickle=True)
NC = int(z['NC']); ND = int(z['ND'])
px = z['px'].astype(float); py = z['py'].astype(float)
is_water = z['st_is_water_arr'] > 0.5
warm = 40
P = np.nan_to_num(z['dy_weather_precip_arr'].astype(float))[warm:]   # (T,NC)
W = np.nan_to_num(z['dy_wind_speed_arr'].astype(float))[warm:].mean()
T = P.shape[0]


def scorr(a, b):
    am = a - a.mean(); bm = b - b.mean()
    den = np.sqrt((am * am).sum() * (bm * bm).sum())
    return (am * bm).sum() / den if den > 1e-9 else 0.0


print(f'NPZ={NPZ.split("/")[-1]}  T={T}  mean_wind_speed={W:.3f}')
print('=== 问题2: precip 场时间自相关(lag 天) — 高=雨型静止, 快降=雨带移动 ===')
for lag in [1, 3, 7, 15, 30, 60, 120]:
    if lag >= T:
        break
    cs = [scorr(P[t], P[t + lag]) for t in range(0, T - lag, 3)]
    print(f'  lag={lag:>3}天: 自相关={np.mean(cs):.3f}')

# perma rain/dry
wetfreq = (P > 0.02).mean(0)
print(f'\nperma_rain(全年wet>80%)={ (wetfreq > 0.80).mean()*100:.1f}%   '
      f'perma_dry(全年wet<5%)={ (wetfreq < 0.05).mean()*100:.1f}%   '
      f'中间(会变化)={ ((wetfreq>=0.05)&(wetfreq<=0.80)).mean()*100:.1f}%')

# wet 区质心逐日位移(整体雨带是否平移)
cxs = []; cys = []
for t in range(T):
    w = P[t]
    s = w.sum()
    if s < 1e-6:
        continue
    cxs.append((w * px).sum() / s); cys.append((w * py).sum() / s)
cxs = np.array(cxs); cys = np.array(cys)
if len(cxs) > 2:
    disp = np.sqrt(np.diff(cxs)**2 + np.diff(cys)**2)
    span_x = px.max() - px.min()
    print(f'雨带质心: 逐日位移均值={disp.mean():.4f} (地图宽{span_x:.1f}, 占比{disp.mean()/span_x*100:.2f}%/天)  '
          f'质心x范围={cxs.max()-cxs.min():.3f} y范围={cys.max()-cys.min():.3f}')

# 海洋 vs 陆地分别看自相关(海上永雨停滞?)
print('\n海陆分别 lag=30 自相关:')
for label, m in [('海洋', is_water), ('陆地', ~is_water)]:
    Pm = P[:, m]
    cs = [scorr(Pm[t], Pm[t + 30]) for t in range(0, T - 30, 3)]
    print(f'  {label}: lag30自相关={np.mean(cs):.3f} (高→该区雨型钉死)')
