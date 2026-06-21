"""内陆无雨诊断：按到最近海洋的 hop 距离分层，看 vapor/cloud_water/precip 衰减。
区分两种根因：
  (A) vapor 随 hop 衰减→0       = 水汽没能平流到内陆 (蒸发源/平流强度问题)
  (B) vapor 维持但 cw/precip→0  = 水汽到了却不凝结/不降水 (凝结阈值/trig 触发问题)
"""
import numpy as np, sys
from collections import deque

NPZ = sys.argv[1] if len(sys.argv) > 1 else r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_wx_fields_new.npz'

z = np.load(NPZ, allow_pickle=True)
NC = int(z['NC']); ND = int(z['ND']); NB = z['NB']
is_water = z['st_is_water_arr'] > 0.5
terrain = z['st_terrain_arr'].astype(int)
elev = z['st_elevation_arr']
d = lambda k: np.nan_to_num(z['dy_' + k].astype(np.float64))
precip = d('weather_precip_arr'); vapor = d('weather_vapor_arr'); cw = d('weather_cloud_water_arr')

# 多源 BFS：每格到最近水格的 hop 距离 (水格=0)
hop = np.full(NC, -1, dtype=int)
dq = deque()
for c in range(NC):
    if is_water[c]:
        hop[c] = 0; dq.append(c)
while dq:
    c = dq.popleft()
    for k in range(6):
        nb = NB[c, k]
        if nb >= 0 and hop[nb] < 0:
            hop[nb] = hop[c] + 1; dq.append(nb)

warm = 40 if ND >= 80 else max(2, ND // 4)
tmean = lambda M: M[warm:].mean(0)
pm = tmean(precip); vm = tmean(vapor); cm = tmean(cw)
wet = (precip[warm:] > 0.02).mean(0)

print(f'ND={ND} NC={NC} warm={warm}  water={int(is_water.sum())} land={int((~is_water).sum())} '
      f'unreached={int((hop < 0).sum())}')
print(f'{"hop":>4}{"n":>6}{"precip":>9}{"vapor":>8}{"cw":>9}{"wet%":>7}{"elev":>7}')
bins = [0, 1, 2, 3, 4, 5, 6, 7, 8, 999]
for lo in range(len(bins) - 1):
    a, b = bins[lo], bins[lo + 1]
    m = (hop >= a) & (hop < b)
    if not m.any():
        continue
    tag = f'{a}' if b - a == 1 else f'{a}+'
    print(f'{tag:>4}{int(m.sum()):>6}{pm[m].mean():>9.4f}{vm[m].mean():>8.3f}'
          f'{cm[m].mean():>9.4f}{wet[m].mean() * 100:>6.1f}%{elev[m].mean():>7.3f}')

land = ~is_water
print(f'[land] perma_dry(wet<5%)={(wet[land] < 0.05).mean():.3f}  '
      f'perma_rain(wet>80%)={(wet[land] > 0.80).mean():.3f}  mean_precip={pm[land].mean():.4f}')
deep = land & (hop >= 4)
if deep.any():
    print(f'[deep inland hop>=4] n={int(deep.sum())} mean_precip={pm[deep].mean():.4f} '
          f'mean_vapor={vm[deep].mean():.3f} mean_cw={cm[deep].mean():.4f} wet%={wet[deep].mean() * 100:.1f}')

try:
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    xs = []; H = []
    for h in range(0, int(hop.max()) + 1):
        m = hop == h
        if m.sum() < 3:
            continue
        xs.append(h); H.append([pm[m].mean(), vm[m].mean(), cm[m].mean(), wet[m].mean()])
    H = np.array(H); xs = np.array(xs)
    fig, ax = plt.subplots(1, 2, figsize=(13, 5))
    ax[0].plot(xs, H[:, 0], 'b-o', label='precip')
    ax[0].plot(xs, H[:, 2], 'c-s', label='cloud_water')
    ax[0].set_xlabel('hops from nearest ocean'); ax[0].set_ylabel('time-mean precip / cw')
    ax[0].set_title('NEW advective: precip & cloud_water vs inland distance')
    ax[0].legend(loc='upper right')
    ax2 = ax[0].twinx()
    ax2.plot(xs, H[:, 1], 'r--^', label='vapor')
    ax2.set_ylabel('vapor', color='r'); ax2.legend(loc='center right')
    ax[1].plot(xs, H[:, 3] * 100, 'g-o')
    ax[1].set_xlabel('hops from nearest ocean'); ax[1].set_ylabel('wet-day %')
    ax[1].set_title('wet-day ratio vs inland distance')
    fig.tight_layout()
    out = NPZ.replace('.npz', '_inland.png')
    fig.savefig(out, dpi=110)
    print(f'[图] {out}')
except Exception as e:
    print(f'[图跳过] {e}')
