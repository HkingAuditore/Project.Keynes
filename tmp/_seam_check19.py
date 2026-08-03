import csv
import numpy as np

def load_slp(path):
    rows = list(csv.DictReader(open(path, encoding='utf-8')))
    H = max(int(r['r']) for r in rows) + 1
    W = 0
    cells = {}
    for r in rows:
        q, rr = int(r['q']), int(r['r'])
        col = q + (rr - (rr & 1)) // 2
        cells[(col, rr)] = float(r['slp_arr'])
        W = max(W, col + 1)
    g = np.zeros((H, W))
    for (c, rr), v in cells.items():
        g[rr, c] = v
    return g, W, H

obs70, W70, H70 = load_slp(r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260803_112649.csv')
obs154, W154, H154 = load_slp(r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260803_123739.csv')
assert W70 == W154 == 100 and H70 == H154 == 64
W, H = 100, 64

row, col = np.mgrid[0:H, 0:W]
px_wrap = ((col + 0.5 * (row & 1)) / W) % 1.0          # 新代码 wrap px
px_clamp = (col + 0.5 * (row & 1)) / W                  # 旧代码 clamp px（bounds=满宽时相同，但语义 clamp）
py_ = row / (H - 1.0)
ls = 1.0 - 2.0 * py_

DAY70, DAY154 = 70.0, 154.0
INV2S2 = 1.0 / (2.0 * 0.16 ** 2)

def syn_new(seed, day):
    sa = np.sin(seed * 12.9898) * 43758.5453
    sa -= np.floor(sa)
    sb = np.sin(seed * 78.233) * 12543.2837
    sb -= np.floor(sb)
    k1x = 1 + int(np.floor(sa * 2.0))      # {1,2}
    k2x = 1 + int(np.floor(sb * 2.0))
    k1y = 0.70 + 0.40 * np.cos(sa * 6.283185307179586)
    k2y = 0.85 + 0.35 * np.sin(sb * 6.283185307179586)
    ph1 = (day * 6.283185307179586) / 6.0
    ph2 = (day * 6.283185307179586) / 9.0
    return (0.65 * np.sin(6.283185307179586 * (k1x * px_wrap + k1y * py_) + ls * 0.6 + sa * 6.283185307179586 + ph1)
            + 0.35 * np.cos(6.283185307179586 * (k2x * px_wrap + k2y * py_) + ls * 0.6 + sb * 6.283185307179586 + ph2))

def syn_old(seed, day):
    sa = np.sin(seed * 12.9898) * 43758.5453
    sa -= np.floor(sa)
    sb = np.sin(seed * 78.233) * 12543.2837
    sb -= np.floor(sb)
    k1x = np.sin(sa * 6.283185307179586) * 0.80 + 0.35
    k2x = np.cos(sb * 6.283185307179586) * 0.65 + 0.35
    k1y = 0.70 + 0.40 * np.cos(sa * 6.283185307179586)
    k2y = 0.85 + 0.35 * np.sin(sb * 6.283185307179586)
    ph1 = (day * 6.283185307179586) / 6.0
    ph2 = (day * 6.283185307179586) / 9.0
    return (0.65 * np.sin(6.283185307179586 * (k1x * px_clamp + k1y * py_) + ls * 0.6 + sa * 6.283185307179586 + ph1)
            + 0.35 * np.cos(6.283185307179586 * (k2x * px_clamp + k2y * py_) + ls * 0.6 + sb * 6.283185307179586 + ph2))

def lows_wrapped(seed, day):
    out = np.zeros((H, W))
    for j in range(5):
        h = (int(seed) * 2654435761 + j * 40503 + 1013904223) & 0xFFFFFFFF
        h ^= h >> 16; h = (h * 2246822519) & 0xFFFFFFFF; h ^= h >> 13
        hx = (h & 0xFFFF) / 65535.0
        hy = ((h >> 16) & 0xFFFF) / 65535.0
        cx = (hx + day / 16.0) % 1.0
        cy = 0.22 + 0.56 * hy + 0.05 * np.sin(day * 0.045 + j * 1.7)
        dx = px_wrap - cx
        dx = np.where(dx > 0.5, dx - 1.0, np.where(dx < -0.5, dx + 1.0, dx))
        out += -np.exp(-(dx * dx + (py_ - cy) ** 2) * INV2S2)
    return out

def lows_unwrapped(seed, day):
    out = np.zeros((H, W))
    for j in range(5):
        h = (int(seed) * 2654435761 + j * 40503 + 1013904223) & 0xFFFFFFFF
        h ^= h >> 16; h = (h * 2246822519) & 0xFFFFFFFF; h ^= h >> 13
        hx = (h & 0xFFFF) / 65535.0
        hy = ((h >> 16) & 0xFFFF) / 65535.0
        cx = (hx + day / 16.0) % 1.0
        cy = 0.22 + 0.56 * hy + 0.05 * np.sin(day * 0.045 + j * 1.7)
        dx = px_wrap - cx          # 不包裹
        out += -np.exp(-(dx * dx + (py_ - cy) ** 2) * INV2S2)
    return out

def fit_r2(obs, regs):
    # 每行独立最小二乘: obs[row] ≈ Σ a_k * reg_k[row]
    H_, W_ = obs.shape
    ss_res = 0.0
    ss_tot = 0.0
    coefs = []
    for rr in range(H_):
        A = np.stack([reg[rr] for reg in regs] + [np.ones(W_)], axis=1)
        coef, res, _, _ = np.linalg.lstsq(A, obs[rr], rcond=None)
        pred = A @ coef
        ss_res += float(((obs[rr] - pred) ** 2).sum())
        mu = obs[rr].mean()
        ss_tot += float(((obs[rr] - mu) ** 2).sum())
        coefs.append(coef)
    return 1.0 - ss_res / max(ss_tot, 1e-12), np.array(coefs)

best = {}   # family -> (r2sum, seed)
N_SEEDS = 6000
for seed in range(N_SEEDS):
    l70 = lows_wrapped(seed, DAY70)
    l154 = lows_wrapped(seed, DAY154)
    sn70, sn154 = syn_new(seed, DAY70), syn_new(seed, DAY154)
    so70, so154 = syn_old(seed, DAY70), syn_old(seed, DAY154)
    # 家族: 用 syn_new + lows / syn_old + lows 双录制联合 R2
    r2n70, _ = fit_r2(obs70, [sn70, l70])
    r2n154, _ = fit_r2(obs154, [sn154, l154])
    r2o70, _ = fit_r2(obs70, [so70, l70])
    r2o154, _ = fit_r2(obs154, [so154, l154])
    for fam, sc in (('new+wrapL', r2n70 + r2n154), ('old+wrapL', r2o70 + r2o154)):
        if fam not in best or sc > best[fam][0]:
            best[fam] = (sc, seed, r2n70 if fam == 'new+wrapL' else r2o70,
                         r2n154 if fam == 'new+wrapL' else r2o154)
    if seed % 1000 == 0:
        print('... seed %d done' % seed)

print()
for fam, (sc, seed, r1, r2) in best.items():
    print('%-10s best seed %d: R2(day70)=%.3f R2(day154)=%.3f' % (fam, seed, r1, r2))

# 对最优家族做含未包裹低压的对比拟合
for fam in ('new+wrapL', 'old+wrapL'):
    seed = best[fam][1]
    sn = syn_new if fam.startswith('new') else syn_old
    for low_fam, lf in (('wrapL', lows_wrapped), ('unwrapL', lows_unwrapped)):
        r2a, ca = fit_r2(obs70, [sn(seed, DAY70), lf(seed, DAY70)])
        r2b, cb = fit_r2(obs154, [sn(seed, DAY154), lf(seed, DAY154)])
        print('%s seed=%d %s: R2(70)=%.3f R2(154)=%.3f | mean|coef_syn|=%.2f mean|coef_low|=%.3f' % (
            fam, seed, low_fam, r2a, r2b,
            np.abs(ca[:, 0]).mean(), np.abs(ca[:, 1]).mean()))
