"""季节性诊断：辐合是季节抵消(夏 onshore/冬 offshore 年均抹平) 还是本身太弱？
按时间 4 分段(季度)，每段算 海岸 onshore% + 内陆(hop>=3) precip/vapor 均值。
若某段 onshore 远高 → 季节抵消(辐合夏季有效)；若各段都低 → 辐合本身弱。
"""
import numpy as np
from collections import deque
import sys

NPZ = sys.argv[1] if len(sys.argv) > 1 else r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_wx_fields_v4.npz'
z = np.load(NPZ, allow_pickle=True)
NC = int(z['NC']); ND = int(z['ND']); NB = z['NB']
px = z['px'].astype(float); py = z['py'].astype(float)
is_water = z['st_is_water_arr'] > 0.5
d = lambda k: np.nan_to_num(z['dy_' + k].astype(float))
wx = d('wind_x_arr'); wy = d('wind_y_arr')
precip = d('weather_precip_arr'); vapor = d('weather_vapor_arr')

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
coast = np.where(hop == 1)[0]

sea_dir = {}
for c in coast:
    sx = sy = 0.0; nw = 0
    for k in range(6):
        nb = NB[c, k]
        if nb >= 0 and is_water[nb]:
            sx += px[nb] - px[c]; sy += py[nb] - py[c]; nw += 1
    sl = (sx * sx + sy * sy) ** 0.5
    if nw > 0 and sl > 1e-6:
        sea_dir[c] = (sx / sl, sy / sl)


def onshore_frac(day_slice):
    wxm = wx[day_slice].mean(0); wym = wy[day_slice].mean(0)
    on = off = tot = 0
    for c, (sx, sy) in sea_dir.items():
        wl = (wxm[c] ** 2 + wym[c] ** 2) ** 0.5
        if wl < 1e-6:
            continue
        dot = (wxm[c] * sx + wym[c] * sy) / wl
        tot += 1
        if dot < -0.3:
            on += 1
        elif dot > 0.3:
            off += 1
    return on / max(tot, 1) * 100, off / max(tot, 1) * 100


inland = (hop >= 3) & (~is_water)
print(f'NPZ={NPZ.split("/")[-1]}  ND={ND}  海岸格={len(sea_dir)}  内陆(hop>=3)格={int(inland.sum())}')
print('按时间4分段(季度) onshore%/offshore% + 内陆precip/vapor:')
seg = max(ND // 4, 1)
for s in range(4):
    a = s * seg; b = (s + 1) * seg if s < 3 else ND
    if a >= b:
        continue
    sl = slice(a, b)
    onf, off = onshore_frac(sl)
    ip = precip[sl][:, inland].mean()
    iv = vapor[sl][:, inland].mean()
    print(f'  段{s + 1} day[{a:3d}:{b:3d}]  onshore={onf:5.1f}%  offshore={off:5.1f}%  内陆precip={ip:.4f}  内陆vapor={iv:.3f}')
