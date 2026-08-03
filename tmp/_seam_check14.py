import csv, math
try:
    import numpy as np
    HAVE_NP = True
except ImportError:
    HAVE_NP = False
print('numpy:', HAVE_NP)

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
obs = np.zeros((H, W)) if HAVE_NP else None
for (c, rr), r in cells.items():
    obs[rr, c] = f_(r, 'slp_arr')

# 观测特征：逐行接缝跳变、逐行最大内部跳变
def seam_stats(field):
    seam = np.abs(field[:, -1] - field[:, 0])
    interior = np.abs(np.diff(field, axis=1)).max(axis=1)
    anchored = int((seam > interior).sum())
    return anchored, seam

anch_obs, seam_obs = seam_stats(obs)
print('OBSERVED: anchored rows = %d/64, mean seam = %.4f' % (anch_obs, seam_obs.mean()))

# 网格
col_idx = np.arange(W)[None, :]
row_idx = np.arange(H)[:, None]
PX = (col_idx + 0.5 * (row_idx % 2)) / W          # wrap path
NY = row_idx / (H - 1)
LS = (NY - 0.5) * 2.0
LSA = np.abs(LS)
PY = NY
# clamp path 用 px（POSX 跨度 [0, 99.5·sqrt3]）
PX_CLAMP = (col_idx + 0.5 * (row_idx % 2)) / 99.5

phase1 = SIM_DAY * (2 * math.pi / SYN_PERIOD)
phase2 = phase1 * 0.66

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
        base_y = 0.22 + 0.56 * hy
        wob = 0.05 * math.sin(SIM_DAY * 0.045 + j * 1.7)
        cy = min(0.96, max(0.04, base_y + wob))
        out.append((cx, cy))
    return out

def field_new(seed, px):
    sa = seed * 0.00011
    sb = seed * 0.00017
    k1x = 1.0 + (seed & 1)
    k2x = 1.0 + ((seed >> 1) & 1)
    k1y = 0.70 + 0.40 * math.cos(sa)
    k2y = 0.85 + 0.35 * math.sin(sb)
    syn = SYN_AMP * (0.65 * np.sin(2*np.pi*(k1x*px + k1y*PY) + phase1 + LS*0.6 + sa)
                   + 0.35 * np.cos(2*np.pi*(k2x*px - k2y*PY) - phase2 + LSA*0.9 + sb))
    ml = np.zeros_like(syn)
    inv2s2 = 1.0 / (2.0 * LOW_SIGMA * LOW_SIGMA)
    for cx, cy in mlows_centers(seed):
        dx = px - cx
        dx = np.where(dx > 0.5, dx - 1.0, np.where(dx < -0.5, dx + 1.0, dx))
        dy = NY - cy
        ml -= LOW_AMP * np.exp(-(dx*dx + dy*dy) * inv2s2)
    return syn + ml

def field_old(seed, px):
    sa = seed * 0.00011
    sb = seed * 0.00017
    k1x = 0.90 + 0.40 * math.sin(sa)
    k1y = 0.70 + 0.40 * math.cos(sa)
    k2x = 1.10 - 0.35 * math.cos(sb)
    k2y = 0.85 + 0.35 * math.sin(sb)
    syn = SYN_AMP * (0.65 * np.sin(2*np.pi*(k1x*px + k1y*PY) + phase1 + LS*0.6)
                   + 0.35 * np.cos(2*np.pi*(k2x*px - k2y*PY) - phase2 + LSA*0.9))
    ml = np.zeros_like(syn)
    inv2s2 = 1.0 / (2.0 * LOW_SIGMA * LOW_SIGMA)
    for cx, cy in mlows_centers(seed):
        dx = px - cx
        dx = np.where(dx > 0.5, dx - 1.0, np.where(dx < -0.5, dx + 1.0, dx))
        dy = NY - cy
        ml -= LOW_AMP * np.exp(-(dx*dx + dy*dy) * inv2s2)
    return syn + ml

# 扫描种子：统计新代码（wrap）在新地图上的 anchoring 上限
best_new = (0, -1)
best_old = (0, -1)
for seed in range(4000):
    fn = field_new(seed, PX)
    a_new, _ = seam_stats(fn)
    if a_new > best_new[0]:
        best_new = (a_new, seed)
    fo = field_old(seed, PX_CLAMP)
    a_old, _ = seam_stats(fo)
    if a_old > best_old[0]:
        best_old = (a_old, seed)
print('NEW code (wrap px, integer k): max anchored rows over seeds 0..3999 = %d (seed %d)' % best_new)
print('OLD code (clamp px, non-integer k): max anchored rows = %d (seed %d)' % best_old)

# 找与观测 seam 剖面最相关的种子（新旧两族）
def corr(a, b):
    a = a - a.mean(); b = b - b.mean()
    d = (np.sqrt((a*a).sum()) * np.sqrt((b*b).sum()))
    return float((a*b).sum() / d) if d > 0 else 0.0
best_corr_new = (-2, -1)
best_corr_old = (-2, -1)
for seed in range(4000):
    _, s_new = seam_stats(field_new(seed, PX))
    c1 = corr(s_new, seam_obs)
    if c1 > best_corr_new[0]:
        best_corr_new = (c1, seed)
    _, s_old = seam_stats(field_old(seed, PX_CLAMP))
    c2 = corr(s_old, seam_obs)
    if c2 > best_corr_old[0]:
        best_corr_old = (c2, seed)
print('best seam-profile corr: NEW = %.3f (seed %d) | OLD = %.3f (seed %d)' % (
    best_corr_new[0], best_corr_new[1], best_corr_old[0], best_corr_old[1]))
