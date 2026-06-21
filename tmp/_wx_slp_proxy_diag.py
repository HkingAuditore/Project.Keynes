"""分季度确诊辐合方向(修正版)：
用绝对温度 temp_arr 去掉纬度带趋势 → 海陆温度距平(夏季陆地系统暖于同纬度海洋)，
这才对应实机 SLP 的 landsea 项(暖→低压)。SLP_proxy = base_lat - K·temp_dev，归一化 p95=0.32。
每季算海岸 grad_mag + 辐合(-grad slp)指向内陆比例。
  夏季 conv-to-inland 高/冬季低 → landsea 系统指向内陆(季节性海风)，辐合方向对 → 实机需增强 converge
  各季都 ~50% → 海陆梯度被纬度基线/噪声淹没，方向不可靠 → 需改用几何海风(朝内陆)
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
TEMP = d('temp_arr')

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

ny = (py - py.min()) / max(py.max() - py.min(), 1e-6)
ls_abs = np.abs((ny - 0.5) * 2.0)
base_lat = -0.26 * np.cos(ls_abs * np.pi * 3.0)
# 纬度分带(去趋势用)
NBIN = 32
band = np.clip((ny * NBIN).astype(int), 0, NBIN - 1)


def detrend_lat(temp_field):
    dev = temp_field.copy()
    for b in range(NBIN):
        m = band == b
        if m.sum() > 0:
            dev[m] = temp_field[m] - temp_field[m].mean()
    return dev


def analyze(temp_q, K=1.0):
    temp_dev = detrend_lat(temp_q)
    # 归一化温度距平到 ~单位量级，避免 K 量级敏感
    sd = np.std(temp_dev)
    if sd > 1e-6:
        temp_dev = temp_dev / sd * 0.2
    slp = base_lat - K * temp_dev
    slp = slp - slp.mean()
    p95 = np.percentile(np.abs(slp), 95)
    if p95 > 1e-5:
        slp = slp * float(np.clip(0.32 / p95, 0.75, 3.6))
    onin = tot = 0; mags = []
    for c in coast:
        sx = sy = 0.0; nw = 0
        gx = gy = 0.0; ng = 0
        for k in range(6):
            nb = NB[c, k]
            if nb < 0:
                continue
            dx = px[nb] - px[c]; dy = py[nb] - py[c]
            dl = (dx * dx + dy * dy) ** 0.5
            if dl < 1e-6:
                continue
            gx += (slp[nb] - slp[c]) * dx / dl
            gy += (slp[nb] - slp[c]) * dy / dl
            ng += 1
            if is_water[nb]:
                sx += dx; sy += dy; nw += 1
        if ng > 0:
            gx /= 3.0; gy /= 3.0
        sl = (sx * sx + sy * sy) ** 0.5
        gm = (gx * gx + gy * gy) ** 0.5
        if nw == 0 or sl < 1e-6 or gm < 1e-9:
            continue
        sx /= sl; sy /= sl
        mags.append(gm)
        dot = (gx * sx + gy * sy) / gm
        tot += 1
        if dot > 0.3:
            onin += 1
    mags = np.array(mags)
    return np.median(mags), (mags > 0.055).mean() * 100, onin / max(tot, 1) * 100


# 同时检验：陆地是否真的比海洋暖(海陆温差是否存在)
print(f'ND={ND}  coast={len(coast)}')
seg = max(ND // 4, 1)
for s in range(4):
    a = s * seg; b = (s + 1) * seg if s < 3 else ND
    tq = TEMP[a:b].mean(0)
    land_t = tq[~is_water].mean(); sea_t = tq[is_water].mean()
    print(f'  Q{s+1}[{a:3d}:{b:3d}] land_T={land_t:.3f} sea_T={sea_t:.3f} diff(land-sea)={land_t-sea_t:+.3f}')
print(f'{"quarter":>8}{"grad_med":>10}{"grad>.055%":>12}{"conv-to-inland%":>17}')
for s in range(4):
    a = s * seg; b = (s + 1) * seg if s < 3 else ND
    md, full, inl = analyze(TEMP[a:b].mean(0))
    print(f'  Q{s+1}{md:>11.4f}{full:>11.0f}%{inl:>16.0f}%')
