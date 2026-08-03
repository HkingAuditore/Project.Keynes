import csv
import numpy as np

SEED = 147556379
W, H = 100, 64
AMP = 0.18          # slp_synoptic_amp 默认
LOW_AMP = 0.16
SIG = 0.16
INV2S2 = 1.0 / (2.0 * SIG ** 2)
LOW_PERIOD = 16.0
SYN_PERIOD = 6.0

def load_slp(path):
    rows = list(csv.DictReader(open(path, encoding='utf-8')))
    cells = {}
    for r in rows:
        q, rr = int(r['q']), int(r['r'])
        col = q + (rr - (rr & 1)) // 2
        cells[(col, rr)] = float(r['slp_arr'])
    g = np.zeros((H, W))
    for (c, rr), v in cells.items():
        g[rr, c] = v
    return g

obs70 = load_slp(r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260803_112649.csv')
obs154 = load_slp(r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260803_123739.csv')

row, col = np.mgrid[0:H, 0:W]
POSX = np.sqrt(3.0) * (col + 0.5 * (row & 1))           # hex_size=1
# world_bounds: pos=(-2,-2), size=(sqrt3*(100.5)+4, 100.5)
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
print('seed=%d' % SEED)
print('OLD: k1x=%.4f k2x=%.4f k1y=%.4f k2y=%.4f' % (k1x_old, k2x_old, k1y, k2y))
print('NEW: k1x=%.1f k2x=%.1f (same k1y/k2y)' % (k1x_new, k2x_new))

def syn_old(day):
    ph1 = day * 2 * np.pi / SYN_PERIOD
    ph2 = ph1 * 0.66
    return AMP * (0.65 * np.sin(2*np.pi*(k1x_old*px_clamp + k1y*py_) + ph1 + ls*0.6)
                  + 0.35 * np.cos(2*np.pi*(k2x_old*px_clamp - k2y*py_) - ph2 + ls_abs*0.9))

def syn_new(day):
    ph1 = day * 2 * np.pi / SYN_PERIOD
    ph2 = ph1 * 0.66
    return AMP * (0.65 * np.sin(2*np.pi*(k1x_new*px_wrap + k1y*py_) + ph1 + ls*0.6 + sa)
                  + 0.35 * np.cos(2*np.pi*(k2x_new*px_wrap - k2y*py_) - ph2 + ls_abs*0.9 + sb))

def lows(day):
    out = np.zeros((H, W))
    cs = []
    for j in range(5):
        h = (SEED * 2654435761 + j * 40503 + 1013904223) & 0xFFFFFFFF
        h ^= h >> 16; h = (h * 2246822519) & 0xFFFFFFFF; h ^= h >> 13
        hx = (h & 0xFFFF) / 65535.0
        hy = ((h >> 16) & 0xFFFF) / 65535.0
        cx = (hx + day / LOW_PERIOD) % 1.0
        cy = 0.22 + 0.56 * hy + 0.05 * np.sin(day * 0.045 + j * 1.7)
        cy = min(max(cy, 0.04), 0.96)
        cs.append((cx, cy))
        dx = px_wrap - cx
        dx = np.where(dx > 0.5, dx - 1.0, np.where(dx < -0.5, dx + 1.0, dx))
        out += -LOW_AMP * np.exp(-(dx * dx + (py_ - cy) ** 2) * INV2S2)
    return out, cs

for day, obs, tag in ((70.0, obs70, 'day70/11:26'), (154.0, obs154, 'day154/12:37')):
    lo, centers = lows(day)
    so, sn = syn_old(day), syn_new(day)
    K_obs = obs[:, 0] - obs[:, -1]
    K_old = so[:, 0] - so[:, -1]
    K_new = sn[:, 0] - sn[:, -1]
    K_low = lo[:, 0] - lo[:, -1]
    print()
    print('=== %s ===' % tag)
    print('low centers:', ['(%.3f,%.3f)' % c for c in centers])
    print('seam step K: obs mean=%.4f std=%.4f' % (K_obs.mean(), K_obs.std()))
    print('  K_old: mean=%.4f std=%.4f  corr(obs,old)=%.3f' % (K_old.mean(), K_old.std(), np.corrcoef(K_obs, K_old)[0,1]))
    print('  K_new: mean=%.4f std=%.4f  corr(obs,new)=%.3f' % (K_new.mean(), K_new.std(), np.corrcoef(K_obs, K_new)[0,1]))
    print('  K_low: mean=%.4f std=%.4f' % (K_low.mean(), K_low.std()))
    # 每行拟合 obs ≈ a*syn_old + b*syn_new + c*lows + d*ls + e
    A = np.stack([so.ravel(), sn.ravel(), lo.ravel(), ls.ravel(), np.ones(H*W)], axis=1)
    coef, res, *_ = np.linalg.lstsq(A, obs.ravel(), rcond=None)
    pred = A @ coef
    r2 = 1 - ((obs.ravel() - pred) ** 2).sum() / ((obs.ravel() - obs.mean()) ** 2).sum()
    print('  full fit: a_old=%.3f b_new=%.3f c_low=%.3f d_ls=%.3f R2=%.3f' % (coef[0], coef[1], coef[2], coef[3], r2))
    # 只看接缝窗口列的拟合
    cols_win = list(range(92, 100)) + list(range(0, 8))
    msk = np.isin(col.ravel(), cols_win)
    A2 = A[msk]
    coef2, *_ = np.linalg.lstsq(A2, obs.ravel()[msk], rcond=None)
    pred2 = A2 @ coef2
    o2 = obs.ravel()[msk]
    r22 = 1 - ((o2 - pred2) ** 2).sum() / ((o2 - o2.mean()) ** 2).sum()
    print('  seam-window fit: a_old=%.3f b_new=%.3f c_low=%.3f R2=%.3f' % (coef2[0], coef2[1], coef2[2], r22))
