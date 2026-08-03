import csv
import numpy as np

def load_slp(path):
    rows = list(csv.DictReader(open(path, encoding='utf-8')))
    cells = {}
    W = H = 0
    for r in rows:
        q, rr = int(r['q']), int(r['r'])
        col = q + (rr - (rr & 1)) // 2
        cells[(col, rr)] = float(r['slp_arr'])
        W = max(W, col + 1); H = max(H, rr + 1)
    g = np.zeros((H, W))
    for (c, rr), v in cells.items():
        g[rr, c] = v
    return g

obs = load_slp(r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260803_123739.csv')
H, W = obs.shape
DAY = 154.0

# ny 映射（compute_world_bounds: pos_y=-2s, size_y=(1.5*64+4.5)s）
def ny_of_row(rr):
    return (1.5 * rr + 2.0) / 100.5

def px_of(col, rr):
    return ((col + 0.5 * (rr & 1)) / W) % 1.0

# 去行均值 + 去纬度剖面（用每行均值已够），找 5 个最深的分离极小
dem = obs - obs.mean(axis=1, keepdims=True)

cands = []
for rr in range(2, H - 2):
    for cc in range(W):
        v = dem[rr, cc]
        # 3x3 邻域最小（含环绕 x）
        ok = True
        for dr in (-1, 0, 1):
            for dc in (-1, 0, 1):
                if dem[rr + dr, (cc + dc) % W] < v:
                    ok = False
        if ok:
            cands.append((v, rr, cc))
cands.sort()
picked = []
for v, rr, cc in cands:
    if all(abs(rr - r2) > 6 or min(abs(cc - c2), W - abs(cc - c2)) > 10 for _, r2, c2 in picked):
        picked.append((v, rr, cc))
    if len(picked) == 5:
        break

print('low centers (value, row, col):')
lows = []
for v, rr, cc in picked:
    ny = ny_of_row(rr)
    px = px_of(cc, rr)
    lows.append((px, ny))
    print('  row %2d col %2d -> px=%.3f ny=%.3f val=%.4f' % (rr, cc, px, ny, v))

# 反推 hx, hy: cx = (hx + day/16) mod 1 ; cy = 0.22+0.56*hy + 0.05*sin(day*0.045+1.7j)
# j 未知，先按幅度排序后试 j 分配；直接在种子扫描中处理：对每种 j 分配计算误差
target = sorted(lows, key=lambda t: t[1])

def hash_xy(seed, j):
    h = (int(seed) * 2654435761 + j * 40503 + 1013904223) & 0xFFFFFFFF
    h ^= h >> 16; h = (h * 2246822519) & 0xFFFFFFFF; h ^= h >> 13
    hx = (h & 0xFFFF) / 65535.0
    hy = ((h >> 16) & 0xFFFF) / 65535.0
    return hx, hy

def model_xy(seed, j, day):
    hx, hy = hash_xy(seed, j)
    cx = (hx + day / 16.0) % 1.0
    cy = 0.22 + 0.56 * hy + 0.05 * np.sin(day * 0.045 + j * 1.7)
    cy = min(max(cy, 0.04), 0.96)
    return cx, cy

import itertools
best = None
for seed in list(range(20260101, 20261232)) + list(range(0, 200000)):
    m = [model_xy(seed, j, DAY) for j in range(5)]
    # 最优二分匹配 5x5
    for perm in itertools.permutations(range(5)):
        err = 0.0
        for t, (px, ny) in zip(perm, target):
            cx, cy = m[t]
            dx = abs(px - cx); dx = min(dx, 1 - dx)
            err += dx * dx + (ny - cy) ** 2
        if best is None or err < best[0]:
            best = (err, seed, perm)
    if best is not None and best[0] < 1e-6:
        break

err, seed, perm = best
print()
print('best seed = %d, err = %.5f' % (seed, err))
m = [model_xy(seed, j, DAY) for j in range(5)]
for t, (px, ny) in zip(perm, target):
    print('  target px=%.3f ny=%.3f  <- low j=%d model cx=%.3f cy=%.3f' % (px, ny, t, m[t][0], m[t][1]))
