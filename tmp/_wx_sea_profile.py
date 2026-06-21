"""确认"海洋→海岸水汽断链"：海洋侧按 sea_dist(到最近陆地格数)分层，
看近岸海洋 vapor 是否高(堆积) + 风是否朝陆(land_dir)。
若近岸海洋 vapor 高但风不朝陆 → 断链证实：海风只在陆地侧抽，海洋水汽补不进来。
"""
import numpy as np
from collections import deque
import sys

NPZ = sys.argv[1] if len(sys.argv) > 1 else r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_wx_fields_v5.npz'
z = np.load(NPZ, allow_pickle=True)
NC = int(z['NC']); ND = int(z['ND']); NB = z['NB']
px = z['px'].astype(float); py = z['py'].astype(float)
is_water = z['st_is_water_arr'] > 0.5
d = lambda k: np.nan_to_num(z['dy_' + k].astype(float))
warm = 40
vapor = d('weather_vapor_arr')[warm:].mean(0)
cw = d('weather_cloud_water_arr')[warm:].mean(0)
precip = d('weather_precip_arr')[warm:].mean(0)
wet = (d('weather_precip_arr')[warm:] > 0.02).mean(0)
wx = d('wind_x_arr')[warm:].mean(0); wy = d('wind_y_arr')[warm:].mean(0)

# sea_dist：陆地=0，向海洋 BFS
sea_dist = np.full(NC, -1, int); dq = deque()
for c in range(NC):
    if not is_water[c]:
        sea_dist[c] = 0; dq.append(c)
while dq:
    c = dq.popleft()
    for k in range(6):
        nb = NB[c, k]
        if nb >= 0 and sea_dist[nb] < 0:
            sea_dist[nb] = sea_dist[c] + 1; dq.append(nb)

# 海洋格朝陆方向 = 朝 sea_dist 减小（指向陆地）
def land_dot_frac(cells):
    on = tot = 0
    for c in cells:
        lx = ly = 0.0
        for k in range(6):
            nb = NB[c, k]
            if nb < 0:
                continue
            dd = sea_dist[c] - sea_dist[nb]   # >0: nb 更靠陆
            if dd <= 0:
                continue
            dx = px[nb] - px[c]; dy = py[nb] - py[c]; dl = (dx * dx + dy * dy) ** 0.5
            if dl < 1e-6:
                continue
            lx += dd * dx / dl; ly += dd * dy / dl
        ll = (lx * lx + ly * ly) ** 0.5
        wl = (wx[c] ** 2 + wy[c] ** 2) ** 0.5
        if ll < 1e-6 or wl < 1e-6:
            continue
        dot = (wx[c] * lx / ll + wy[c] * ly / ll) / wl  # 风·朝陆
        tot += 1
        if dot > 0.3:
            on += 1
    return on / max(tot, 1) * 100, tot

print(f'NPZ={NPZ.split("/")[-1]}  ND={ND}')
print('海洋侧 sea_dist 剖面 (sea_dist=1 紧邻陆地, 越大越深海):')
print(f'  {"sea_d":>6}{"n":>6}{"vapor":>8}{"cw":>8}{"precip":>9}{"wet%":>7}{"wind->land%":>12}')
for sd in range(1, 7):
    m = (sea_dist == sd) & is_water
    cells = np.where(m)[0]
    if len(cells) < 3:
        continue
    ldf, _ = land_dot_frac(cells)
    print(f'  {sd:>6}{len(cells):>6}{vapor[m].mean():>8.3f}{cw[m].mean():>8.3f}'
          f'{precip[m].mean():>9.4f}{wet[m].mean()*100:>6.1f}{ldf:>11.0f}%')
# 海上永雨：sea_dist>=2 的海洋里 wet>0.8 的比例 + 它们的平均 cw
deep = (sea_dist >= 2) & is_water
pr = wet > 0.80
print(f'\n海上(sea_dist>=2) 永雨格(wet>0.80)占比={ (pr[deep]).mean()*100:.1f}%  '
      f'这些永雨格 vapor={vapor[deep & pr].mean() if (deep&pr).any() else 0:.3f} cw={cw[deep & pr].mean() if (deep&pr).any() else 0:.3f}')
