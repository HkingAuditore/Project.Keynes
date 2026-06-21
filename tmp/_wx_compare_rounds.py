"""对比第一轮调参前后，按到海 hop 分层并排看 vapor/cw/precip/wet%，定位"为什么更干"。
  R1 = _wx_fields_new.npz  (154003, 平流式调参前: rh0.55 / base0.20 / auto0.12)
  R2 = _wx_fields_v2.npz   (205247, 第一轮调参后: rh0.32 / base0.50 / auto0.16)
关键看：调参后内陆 vapor 是否被上游过度凝结抽干(雨影/截流)；海岸降水是否暴增。
"""
import numpy as np
from collections import deque

R1 = r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_wx_fields_new.npz'
R2 = r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_wx_fields_v2.npz'


def load(path):
    z = np.load(path, allow_pickle=True)
    NC = int(z['NC']); ND = int(z['ND']); NB = z['NB']
    is_water = z['st_is_water_arr'] > 0.5
    d = lambda k: np.nan_to_num(z['dy_' + k].astype(np.float64))
    P = d('weather_precip_arr'); V = d('weather_vapor_arr'); C = d('weather_cloud_water_arr')
    hop = np.full(NC, -1, dtype=int); dq = deque()
    for c in range(NC):
        if is_water[c]:
            hop[c] = 0; dq.append(c)
    while dq:
        c = dq.popleft()
        for k in range(6):
            nb = NB[c, k]
            if nb >= 0 and hop[nb] < 0:
                hop[nb] = hop[c] + 1; dq.append(nb)
    return dict(NC=NC, ND=ND, is_water=is_water, hop=hop, P=P, V=V, C=C)


def report(tag, z):
    w = 40
    P, V, C, hop, land = z['P'], z['V'], z['C'], z['hop'], ~z['is_water']
    wet = (P[w:] > 0.02).mean(0)
    pm = P[w:].mean(0); vm = V[w:].mean(0); cm = C[w:].mean(0)
    print(f'== {tag}  ND={z["ND"]} ==')
    print(f'   land_dry(wet<5%)={(wet[land] < 0.05).mean():.3f}  perma_rain(wet>80%)={(wet > 0.80).mean():.3f}  '
          f'land_precip={pm[land].mean():.4f}  ocean_precip={pm[z["is_water"]].mean():.4f}')
    print(f'   {"hop":>4}{"n":>6}{"precip":>9}{"vapor":>8}{"cw":>9}{"wet%":>7}')
    for h in [0, 1, 2, 3, 4, 5]:
        m = hop == h
        if m.sum() < 3:
            continue
        print(f'   {h:>4}{int(m.sum()):>6}{pm[m].mean():>9.4f}{vm[m].mean():>8.3f}{cm[m].mean():>9.4f}{wet[m].mean() * 100:>6.1f}')


a = load(R1)
b = load(R2)
report('R1 调参前 (154003: rh0.55/base0.20/auto0.12)', a)
print()
report('R2 调参后 (205247: rh0.32/base0.50/auto0.16)', b)
print()
print('--- Δ(R2-R1) 各 hop precip / vapor / cw ---')
for h in [0, 1, 2, 3, 4, 5]:
    ma = a['hop'] == h; mb = b['hop'] == h
    if ma.sum() < 3 or mb.sum() < 3:
        continue
    pa = a['P'][40:].mean(0)[ma].mean(); pb = b['P'][40:].mean(0)[mb].mean()
    va = a['V'][40:].mean(0)[ma].mean(); vb = b['V'][40:].mean(0)[mb].mean()
    ca = a['C'][40:].mean(0)[ma].mean(); cb = b['C'][40:].mean(0)[mb].mean()
    print(f'   hop{h}  Δprecip={pb - pa:+.4f}  Δvapor={vb - va:+.3f}  Δcw={cb - ca:+.4f}')
