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

obs70 = load(r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260803_112649.csv')
obs154 = load(r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260803_123739.csv')

row, col = np.mgrid[0:H, 0:W]
POSX = np.sqrt(3.0) * (col + 0.5 * (row & 1))
BOUNDS_X, BOUNDS_W = -2.0, np.sqrt(3.0) * 100.5 + 4.0
px_clamp = np.clip((POSX - BOUNDS_X) / BOUNDS_W, 0.0, 1.0)
px_wrap = (POSX / (np.sqrt(3.0) * W)) % 1.0
py_ = (1.5 * row + 2.0) / 100.5
ls = 1.0 - 2.0 * py_
ls_abs = np.abs(ls)

sa = SEED * 0.00011
sb = SEED * 0.00017
k1x_old = 0.90 + 0.40 * np.sin(sa)
k2x_old = 1.10 - 0.35 * np.cos(sb)
k1y = 0.70 + 0.40 * np.cos(sa)
k2y = 0.85 + 0.35 * np.sin(sb)
k1x_new = 1.0 + (SEED & 1)
k2x_new = 1.0 + ((SEED >> 1) & 1)

def syn_old(day):
    ph1 = day * 2 * np.pi / 6.0
    ph2 = ph1 * 0.66
    return (0.65 * np.sin(2*np.pi*(k1x_old*px_clamp + k1y*py_) + ph1 + ls*0.6)
            + 0.35 * np.cos(2*np.pi*(k2x_old*px_clamp - k2y*py_) - ph2 + ls_abs*0.9))

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

def ema_mix(fn, day_last, rate=0.55, depth=10):
    acc = np.zeros((H, W))
    wsum = 0.0
    w = 1.0
    for m in range(depth):
        d = day_last - 2 * m
        if d < 0:
            break
        acc += w * fn(d)
        wsum += w
        w *= (1.0 - rate)
    return acc / wsum * rate + 0.0  # 稳态近似: published ≈ rate*Σ(1-rate)^m F(d-2m) + 残差
    # 注: 真正的稳态即该加权序列本身（无需再乘 rate），下面拟合用相对系数，此处仅作形状

def ema_shape(fn, day_last, rate=0.55, depth=10):
    acc = np.zeros((H, W))
    wsum = 0.0
    w = 1.0
    for m in range(depth):
        d = day_last - 2 * m
        if d < 0:
            break
        acc += w * fn(d)
        wsum += w
        w *= (1.0 - rate)
    return acc / wsum

print('day_last | fit: obs ≈ a*mix_old + b*mix_new + c*mix_lows + d*ls + e  (R2)')
for obs, days in ((obs70, [68, 69, 70, 71, 72]), (obs154, [152, 153, 154, 155, 156])):
    for dl in days:
        mo = ema_shape(syn_old, dl)
        mn = ema_shape(syn_new, dl)
        ml = ema_shape(lows, dl)
        A = np.stack([mo.ravel(), mn.ravel(), ml.ravel(), ls.ravel(), np.ones(H * W)], axis=1)
        coef, *_ = np.linalg.lstsq(A, obs.ravel(), rcond=None)
        pred = A @ coef
        r2 = 1 - ((obs.ravel() - pred) ** 2).sum() / ((obs.ravel() - obs.mean()) ** 2).sum()
        print('  day_last=%3d  a_old=%+.3f b_new=%+.3f c_low=%+.3f d_ls=%+.3f  R2=%.3f' % (
            dl, coef[0], coef[1], coef[2], coef[3], r2))
    print()
