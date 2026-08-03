import csv
import numpy as np

W, H = 100, 64
FIELDS = ['slp_arr', 'wind_x_arr', 'wind_y_arr']

def load(path):
    rows = list(csv.DictReader(open(path, encoding='utf-8')))
    data = {k: np.zeros((H, W)) for k in FIELDS}
    for r in rows:
        q, rr = int(r['q']), int(r['r'])
        col = q + (rr - (rr & 1)) // 2
        for k in FIELDS:
            data[k][rr, col] = float(r[k])
    return data

d = load(r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260803_123739.csv')
slp, wx, wy = d['slp_arr'], d['wind_x_arr'], d['wind_y_arr']

# hex 奇偶偏移邻居（东西包裹），与 C++ NB 一致
NB_DIR = [(1, 0), (0.5, -0.8660254), (-0.5, -0.8660254), (-1, 0), (-0.5, 0.8660254), (0.5, 0.8660254)]
def neighbors(rr, cc):
    if rr & 1:
        offs = [(0, 1), (-1, 1), (-1, 0), (0, -1), (1, 0), (1, 1)]
    else:
        offs = [(0, 1), (-1, 0), (-1, -1), (0, -1), (1, -1), (1, 0)]
    out = []
    for dr, dc in offs:
        nr, nc = rr + dr, (cc + dc) % W
        out.append((nr, nc) if 0 <= nr < H else None)
    return out

grad_mag = np.zeros((H, W))
gx = np.zeros((H, W)); gy = np.zeros((H, W))
for rr in range(H):
    for cc in range(W):
        g_x = g_y = 0.0
        cnt = 0
        for d, nb in enumerate(neighbors(rr, cc)):
            if nb is None:
                continue
            nr, nc = nb
            ds = slp[nr, nc] - slp[rr, cc]
            g_x += ds * NB_DIR[d][0]
            g_y += ds * NB_DIR[d][1]
            cnt += 1
        if cnt:
            g_x /= 3.0; g_y /= 3.0
        gx[rr, cc] = g_x; gy[rr, cc] = g_y
        grad_mag[rr, cc] = np.hypot(g_x, g_y)

seam_cols = [0, 1, 98, 99]
mid_cols = list(range(3, 96))
print('grad_mag mean: seam cols %.5f | interior %.5f | ratio %.1fx' % (
    grad_mag[:, seam_cols].mean(), grad_mag[:, mid_cols].mean(),
    grad_mag[:, seam_cols].mean() / grad_mag[:, mid_cols].mean()))

# 风与 -∇slp 的夹角（grad 显著处）
def angle_stats(cols):
    diffs = []
    for rr in range(H):
        for cc in cols:
            gm = grad_mag[rr, cc]
            wm = np.hypot(wx[rr, cc], wy[rr, cc])
            if gm < 1e-6 or wm < 1e-6:
                continue
            dot = (-gx[rr, cc] * wx[rr, cc] + -gy[rr, cc] * wy[rr, cc]) / (gm * wm)
            diffs.append(np.degrees(np.arccos(np.clip(dot, -1, 1))))
    return np.mean(diffs), np.median(diffs)

m_seam = angle_stats(seam_cols)
m_mid = angle_stats(mid_cols)
print('angle(wind, -grad_slp): seam mean=%.1f° median=%.1f° | interior mean=%.1f° median=%.1f°' % (
    m_seam[0], m_seam[1], m_mid[0], m_mid[1]))

# 逐列 grad_mag 剖面（接缝附近）
print()
print('per-column grad_mag (cols 95-99, 0-4) vs interior mean:')
im = grad_mag[:, mid_cols].mean()
for cc in list(range(95, 100)) + list(range(0, 5)):
    print('  col %2d: %.5f (%.1fx interior)' % (cc, grad_mag[:, cc].mean(), grad_mag[:, cc].mean() / im))

# 风的 zonal 分量在接缝列 vs 内部
print()
print('wind_x mean abs: seam %.4f interior %.4f' % (np.abs(wx[:, seam_cols]).mean(), np.abs(wx[:, mid_cols]).mean()))
print('wind_y mean abs: seam %.4f interior %.4f' % (np.abs(wy[:, seam_cols]).mean(), np.abs(wy[:, mid_cols]).mean()))
