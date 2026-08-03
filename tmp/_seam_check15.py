import csv, math
import numpy as np

W, H = 100, 64
SIM_DAY = 70
SYN_AMP = 0.18
LOW_AMP, LOW_SIGMA, LOW_PERIOD, LOW_COUNT = 0.16, 0.16, 16.0, 5
SYN_PERIOD = 6.0

path = r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260803_112649.csv'
rows_csv = list(csv.DictReader(open(path, encoding='utf-8')))
def f_(r, k):
    try:
        return float(r[k])
    except Exception:
        return 0.0
cells = {}
for r in rows_csv:
    q, rr = int(r['q']), int(r['r'])
    col = q + (rr - (rr & 1)) // 2
    cells[(col, rr)] = r
obs = np.zeros((H, W))
for (c, rr), r in cells.items():
    obs[rr, c] = f_(r, 'slp_arr')

def seam_stats(field):
    seam = np.abs(field[:, -1] - field[:, 0])
    interior = np.abs(np.diff(field, axis=1)).max(axis=1)
    return int((seam > interior).sum()), seam

anch_obs, seam_obs = seam_stats(obs)

col_idx = np.arange(W)[None, :]
row_idx = np.arange(H)[:, None]
PX = (col_idx + 0.5 * (row_idx % 2)) / W
PX_CLAMP = (col_idx + 0.5 * (row_idx % 2)) / 99.5
NY = row_idx / (H - 1)
LS = (NY - 0.5) * 2.0
LSA = np.abs(LS)
PY = NY
phase1 = SIM_DAY * (2 * math.pi / SYN_PERIOD)
phase2 = phase1 * 0.66
inv2s2 = 1.0 / (2.0 * LOW_SIGMA * LOW_SIGMA)

def mlows_centers(seed):
    out = []
    for j in range(LOW_COUNT):
        h = (seed * 2654435761 + j * 40503 + 1013904223) & 0xFFFFFFFF
        h ^= h >> 16
        h = (h * 2246822519) & 0xFFFFFFFF
        h ^= h >> 13
        hx = (h & 0xFFFF) / 65535.0
        hy = ((h >> 16) & 0xFFFF) / 65535.0
        cx = (hx + SIM_DAY / LOW_PERIOD) % 1.0
        cy = min(0.96, max(0.04, 0.22 + 0.56 * hy + 0.05 * math.sin(SIM_DAY * 0.045 + j * 1.7)))
        out.append((cx, cy))
    return out

def field_new(seed):
    sa = seed * 0.00011; sb = seed * 0.00017
    k1x = 1.0 + (seed & 1); k2x = 1.0 + ((seed >> 1) & 1)
    k1y = 0.70 + 0.40 * math.cos(sa); k2y = 0.85 + 0.35 * math.sin(sb)
    syn = SYN_AMP * (0.65 * np.sin(2*np.pi*(k1x*PX + k1y*PY) + phase1 + LS*0.6 + sa)
                   + 0.35 * np.cos(2*np.pi*(k2x*PX - k2y*PY) - phase2 + LSA*0.9 + sb))
    ml = np.zeros_like(syn)
    for cx, cy in mlows_centers(seed):
        dx = PX - cx
        dx = np.where(dx > 0.5, dx - 1.0, np.where(dx < -0.5, dx + 1.0, dx))
        ml -= LOW_AMP * np.exp(-((dx)**2 + (NY - cy)**2) * inv2s2)
    return syn + ml

def field_old(seed):
    sa = seed * 0.00011; sb = seed * 0.00017
    k1x = 0.90 + 0.40 * math.sin(sa)
    k1y = 0.70 + 0.40 * math.cos(sa)
    k2x = 1.10 - 0.35 * math.cos(sb)
    k2y = 0.85 + 0.35 * math.sin(sb)
    syn = SYN_AMP * (0.65 * np.sin(2*np.pi*(k1x*PX_CLAMP + k1y*PY) + phase1 + LS*0.6)
                   + 0.35 * np.cos(2*np.pi*(k2x*PX_CLAMP - k2y*PY) - phase2 + LSA*0.9))
    ml = np.zeros_like(syn)
    for cx, cy in mlows_centers(seed):
        dx = PX_CLAMP - cx
        dx = np.where(dx > 0.5, dx - 1.0, np.where(dx < -0.5, dx + 1.0, dx))
        ml -= LOW_AMP * np.exp(-((dx)**2 + (NY - cy)**2) * inv2s2)
    return syn + ml

def corr(a, b):
    a = a - a.mean(); b = b - b.mean()
    d = (np.sqrt((a*a).sum()) * np.sqrt((b*b).sum()))
    return float((a*b).sum() / d) if d > 0 else 0.0

# 混合假设：field = w·old + (1-w)·new，同一 seed
print('blend test: seed | anchored | seam-corr | mix-ratio')
results = []
for w in [0.3, 0.45, 0.6]:
    best = (-2, -1, 0)
    for seed in range(4000):
        f = w * field_old(seed) + (1 - w) * field_new(seed)
        a, s = seam_stats(f)
        c = corr(s, seam_obs)
        score = c + 0.01 * a
        if score > best[0]:
            best = (score, seed, a, c)
    print('w_old=%.2f: seed=%d anchored=%d corr=%.3f' % (w, best[1], best[2], best[3]))
    results.append((w,) + best[1:])

# 纯旧场（存档原样、未衰减）：anchoring 应接近观测
best_pure = (-2, -1, 0, 0)
for seed in range(4000):
    a, s = seam_stats(field_old(seed))
    c = corr(s, seam_obs)
    score = c + 0.01 * a
    if score > best_pure[0]:
        best_pure = (score, seed, a, c)
print('pure OLD field: seed=%d anchored=%d corr=%.3f (observed anchored=38)' % best_pure[1:])
