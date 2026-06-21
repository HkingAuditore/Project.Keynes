"""离线预测几何海风效果 + 定标 WIND_SEA_BREEZE_W（重编前验证，避免无效重编）。
用 v4 实机风场(海风前)作基线 dir，叠加几何海风 breeze*cpw*(-sea_dir)，看各 hop onshore 比例。
  sea_dir = 朝 hop 减小方向(朝海)；cpw = 1-(hop-1)/5 沿海强、内陆 5 格衰减到 0。
注：breeze 加在归一化 dir 上；实机加在 v_sum(量级~2-3) 上，故实机 WIND_SEA_BREEZE_W ≈ breeze_eff×|v_sum|。
"""
import numpy as np
from collections import deque

z = np.load(r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_wx_fields_v4.npz', allow_pickle=True)
NC = int(z['NC']); ND = int(z['ND']); NB = z['NB']
px = z['px'].astype(float); py = z['py'].astype(float)
is_water = z['st_is_water_arr'] > 0.5
d = lambda k: np.nan_to_num(z['dy_' + k].astype(float))
wx = d('wind_x_arr')[40:].mean(0); wy = d('wind_y_arr')[40:].mean(0)

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

sea = np.zeros((NC, 2))
for c in range(NC):
    if is_water[c] or hop[c] < 1:
        continue
    sx = sy = 0.0
    for k in range(6):
        nb = NB[c, k]
        if nb < 0:
            continue
        dh = hop[c] - hop[nb]
        if dh <= 0:
            continue
        dx = px[nb] - px[c]; dy = py[nb] - py[c]; dl = (dx * dx + dy * dy) ** 0.5
        if dl < 1e-6:
            continue
        sx += dh * dx / dl; sy += dh * dy / dl
    sl = (sx * sx + sy * sy) ** 0.5
    if sl > 1e-6:
        sea[c] = [sx / sl, sy / sl]

cpw = np.clip(1 - (hop - 1) / 5.0, 0, 1) * ((hop >= 1) & (~is_water))
base = np.stack([wx, wy], 1)
bn = np.linalg.norm(base, axis=1, keepdims=True)
base_dir = base / np.clip(bn, 1e-6, None)
has_sea = np.linalg.norm(sea, axis=1) > 0.5


def onshore_by_hop(wn):
    dot = (wn * sea).sum(1)
    res = {}
    for h in range(1, 6):
        m = (hop == h) & (~is_water) & has_sea
        if m.sum() < 3:
            continue
        res[h] = (dot[m] < -0.3).mean() * 100
    return res


def fmt(r):
    return ' '.join(f'hop{h}={v:.0f}%' for h, v in r.items())


print(f'baseline (v4 actual, pre-breeze):  {fmt(onshore_by_hop(base_dir))}')
for breeze in [0.5, 1.0, 1.5, 2.0, 3.0, 4.0]:
    wn = base_dir + breeze * cpw[:, None] * (-sea)
    nn = np.linalg.norm(wn, axis=1, keepdims=True)
    wn = wn / np.clip(nn, 1e-6, None)
    print(f'  breeze_eff={breeze:>3}:  {fmt(onshore_by_hop(wn))}')
