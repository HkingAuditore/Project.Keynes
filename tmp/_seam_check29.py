import csv
import numpy as np

SEED = 147556379
W, H = 100, 64
INV2S2 = 1.0 / (2.0 * 0.16 ** 2)

def load(path):
    rows = list(csv.DictReader(open(path, encoding='utf-8')))
    g = np.zeros((H, W))
    for r in rows:
        q, rr = int(r['q']), int(r['r'])
        col = q + (rr - (rr & 1)) // 2
        g[rr, col] = float(r['slp_arr'])
    return g

obs = load(r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260803_123739.csv')

row, col = np.mgrid[0:H, 0:W]
POSX = np.sqrt(3.0) * (col + 0.5 * (row & 1))
px_wrap = (POSX / (np.sqrt(3.0) * W)) % 1.0
py_ = (1.5 * row + 2.0) / 100.5
ls = 1.0 - 2.0 * py_
ls_abs = np.abs(ls)

sa = SEED * 0.00011
sb = SEED * 0.00017
k1y = 0.70 + 0.40 * np.cos(sa)
k2y = 0.85 + 0.35 * np.sin(sb)
k1x_new = 1.0 + (SEED & 1)
k2x_new = 1.0 + ((SEED >> 1) & 1)
A_LAT = 0.16

def syn_new(day):
    ph1 = day * 2 * np.pi / 6.0
    ph2 = ph1 * 0.66
    return (0.65 * np.sin(2*np.pi*(k1x_new*px_wrap + k1y*py_) + ph1 + ls*0.6 + sa)
            + 0.35 * np.cos(2*np.pi*(k2x_new*px_wrap - k2y*py_) - ph2 + ls_abs*0.9 + sb))

def lows(day):
    out = np.zeros((H, W))
    for j in range(5):
        h = (SEED * 2654435761 + j * 40503 + 1013904223) & 0xFFFFFFFF
        h ^= h >> 16; h = (h * 2246822519) & 0xFFFFFFFF; h ^= h >> 13
        hx = (h & 0xFFFF) / 65535.0
        hy = ((h >> 16) & 0xFFFF) / 65535.0
        cx = (hx + day / 16.0) % 1.0
        cy = 0.22 + 0.56 * hy + 0.05 * np.sin(day * 0.045 + j * 1.7)
        cy = min(max(cy, 0.04), 0.96)
        dx = px_wrap - cx
        dx = np.where(dx > 0.5, dx - 1.0, np.where(dx < -0.5, dx + 1.0, dx))
        out += -np.exp(-(dx * dx + (py_ - cy) ** 2) * INV2S2)
    return out

# EMA 混合 day_last 152/154 两天写入 + base_lat，拟合行截距与幅度
mix_syn = 0.55 * syn_new(154.0) + 0.45 * (0.55 * syn_new(152.0) + 0.45 * syn_new(150.0)) / (0.55 + 0.45) * 0.0
mix_syn = (0.55 * syn_new(154.0) + 0.2475 * syn_new(152.0) + 0.1114 * syn_new(150.0)) / (0.55 + 0.2475 + 0.1114)
mix_low = (0.55 * lows(154.0) + 0.2475 * lows(152.0) + 0.1114 * lows(150.0)) / (0.55 + 0.2475 + 0.1114)
base_lat = -A_LAT * np.cos(ls_abs * np.pi * 3.0)

for rr in (10, 30, 50):
    A = np.stack([mix_syn[rr], mix_low[rr], base_lat[rr], np.ones(W)], axis=1)
    coef, *_ = np.linalg.lstsq(A, obs[rr], rcond=None)
    pred = A @ coef
    resid = obs[rr] - pred
    print('row %d: coef syn=%.3f low=%.3f lat=%.3f int=%.3f | resid std=%.4f | resid seam step=%.4f' % (
        rr, coef[0], coef[1], coef[2], coef[3], resid.std(), resid[0] - resid[-1]))
    # 打印观测与残差的接缝窗口
    print('  obs   cols 96-99|0-3: %s | %s' % (' '.join('%+.3f' % v for v in obs[rr, 96:100]),
                                                 ' '.join('%+.3f' % v for v in obs[rr, 0:4])))
    print('  resid cols 96-99|0-3: %s | %s' % (' '.join('%+.3f' % v for v in resid[96:100]),
                                                 ' '.join('%+.3f' % v for v in resid[0:4])))
