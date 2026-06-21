"""离线预测【海陆连续海风】(重编前验证)。用 v4 实机风场(海风前)作基线 dir，叠加:
  陆地侧: + W*cpw*(-coast_sea)   朝内陆，cpw=1-(hop-1)/5 沿海强
  海洋侧: + W*sea_pw*(sea_land)  朝陆， sea_pw=1-(sea_dist-1)/5 近岸强
看陆地 hop / 海洋 sea_dist 两侧 onshore 比例。实机 W 加在 |v_sum| 上 → breeze_eff≈W。
关键验证: 海洋侧风能否从断链的 26%(v5实测) 转为朝陆，拼成连续输送带。
"""
import numpy as np
from collections import deque

z = np.load(r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_wx_fields_v4.npz', allow_pickle=True)
NC = int(z['NC']); NB = z['NB']
px = z['px'].astype(float); py = z['py'].astype(float)
is_water = z['st_is_water_arr'] > 0.5
d = lambda k: np.nan_to_num(z['dy_' + k].astype(float))
wx = d('wind_x_arr')[40:].mean(0); wy = d('wind_y_arr')[40:].mean(0)

# 陆地 hop(到海距离, 海=0 陆>=1) + 海洋 sea_dist(到陆距离, 陆=0 海>=1)
def bfs(seed_is_water):
    dist = np.full(NC, -1, int); dq = deque()
    for c in range(NC):
        if is_water[c] == seed_is_water:
            dist[c] = 0; dq.append(c)
    while dq:
        c = dq.popleft()
        for k in range(6):
            nb = NB[c, k]
            if nb >= 0 and dist[nb] < 0:
                dist[nb] = dist[c] + 1; dq.append(nb)
    return dist
hop = bfs(True)          # 海=0, 陆地>=1
sea_dist = bfs(False)    # 陆=0, 海洋>=1

def grad_dir(dist, cond):  # 指向 dist 减小方向(陆地→朝海, 海洋→朝陆)
    out = np.zeros((NC, 2))
    for c in range(NC):
        if not cond[c]:
            continue
        gx = gy = 0.0
        for k in range(6):
            nb = NB[c, k]
            if nb < 0:
                continue
            dd = dist[c] - dist[nb]
            if dd <= 0:
                continue
            dx = px[nb] - px[c]; dy = py[nb] - py[c]; dl = (dx * dx + dy * dy) ** 0.5
            if dl < 1e-6:
                continue
            gx += dd * dx / dl; gy += dd * dy / dl
        gl = (gx * gx + gy * gy) ** 0.5
        if gl > 1e-6:
            out[c] = [gx / gl, gy / gl]
    return out
coast_sea = grad_dir(hop, (~is_water) & (hop >= 1))      # 陆地朝海
sea_land = grad_dir(sea_dist, is_water & (sea_dist >= 1))  # 海洋朝陆

cpw = np.clip(1 - (hop - 1) / 5.0, 0, 1) * ((hop >= 1) & (~is_water))
spw = np.clip(1 - (sea_dist - 1) / 5.0, 0, 1) * ((sea_dist >= 1) & is_water)
base = np.stack([wx, wy], 1)
base_dir = base / np.clip(np.linalg.norm(base, axis=1, keepdims=True), 1e-6, None)
has_cs = np.linalg.norm(coast_sea, axis=1) > 0.5
has_sl = np.linalg.norm(sea_land, axis=1) > 0.5

def report(wn, label):
    parts = []
    for h in range(1, 6):  # 陆地 onshore = dir·(-coast_sea)>0.3
        m = (hop == h) & (~is_water) & has_cs
        if m.sum() >= 3:
            parts.append(f'L{h}={((wn[m] * -coast_sea[m]).sum(1) > 0.3).mean()*100:.0f}%')
    sea = []
    for s in range(1, 6):  # 海洋朝陆 = dir·sea_land>0.3
        m = (sea_dist == s) & is_water & has_sl
        if m.sum() >= 3:
            sea.append(f'S{s}={((wn[m] * sea_land[m]).sum(1) > 0.3).mean()*100:.0f}%')
    print(f'  {label:>22}:  陆地朝内陆[{" ".join(parts)}]  海洋朝陆[{" ".join(sea)}]')

print('（L=陆地 hop 朝内陆%，S=海洋 sea_dist 朝陆%；S1=紧邻陆地海洋）')
report(base_dir, 'baseline(v4,无海风)')
for W in [0.5, 1.0, 1.5]:
    wn = base_dir + W * cpw[:, None] * (-coast_sea) + W * spw[:, None] * sea_land
    wn = wn / np.clip(np.linalg.norm(wn, axis=1, keepdims=True), 1e-6, None)
    report(wn, f'海陆连续 W={W}')
