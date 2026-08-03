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

# 用离缝较远的列 [88..95] 与 [5..12] 做线性外推估计“应有平滑值”，窗口 [96..3] 内取异常
left = obs[:, 88:96]    # cols 88-95
right = obs[:, 5:13]    # cols 5-12
# 线性拟合每行: value = m*px + b, px 用归一化列坐标（包裹: 左窗口 x∈[0.88,0.95], 右窗口 x∈[1.05,1.12]）
xl = np.arange(88, 96) / W
xr = 1.0 + np.arange(5, 13) / W
X = np.concatenate([xl, xr])
Y = np.concatenate([left, right], axis=1)
A = np.stack([X, np.ones_like(X)], axis=1)
anom = np.zeros((H, 8))   # cols 96,97,98,99,0,1,2,3
xw = np.array([96, 97, 98, 99, 100, 101, 102, 103]) / W
for rr in range(H):
    coef, *_ = np.linalg.lstsq(A, Y[rr], rcond=None)
    pred = coef[0] * xw + coef[1]
    win = np.concatenate([obs[rr, 96:100], obs[rr, 0:4]])
    anom[rr] = win - pred

np.set_printoptions(linewidth=200, suppress=True)
print('12:37 接缝窗口异常（观测 - 线性外推背景），列序: 96 97 98 99 0 1 2 3')
for rr in range(0, H, 2):
    print('row %2d: %s' % (rr, ' '.join('%+.4f' % v for v in anom[rr])))

# 异常的纬度包络：取窗口内最小值列
print()
print('异常幅值包络 (max|anom| per row):')
env = np.abs(anom).max(axis=1)
for rr in range(0, H, 4):
    print('  row %2d: %.4f' % (rr, env[rr]))
