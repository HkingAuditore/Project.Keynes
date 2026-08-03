import csv
import sys
import io
import numpy as np

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

W, H = 100, 64
WATER = {0, 1, 19, 21}  # OCEAN, COAST, REEF, KELP

def load(path):
    rows = list(csv.DictReader(open(path, encoding='utf-8-sig')))
    slp = np.zeros((H, W)); terr = np.zeros((H, W), int)
    for r in rows:
        q, rr = int(r['q']), int(r['r'])
        col = q + (rr - (rr & 1)) // 2
        slp[rr, col] = float(r['slp_arr'])
        terr[rr, col] = int(float(r['terrain_arr']))
    return slp, terr

def build_cls(terr):
    water = np.isin(terr, list(WATER))
    cls = np.where(water, 0.20, 1.30)
    for rr in range(H):
        offs = [(0,1),(-1,0),(-1,-1),(0,-1),(1,-1),(1,0)] if not (rr & 1) else \
               [(0,1),(-1,1),(-1,0),(0,-1),(1,0),(1,1)]
        for cc in range(W):
            if water[rr, cc]:
                continue
            for dr, dc in offs:
                nr, nc = rr + dr, (cc + dc) % W
                if 0 <= nr < H and water[nr, nc]:
                    cls[rr, cc] = 0.60
                    break
    return cls, water

for path, tag in ((r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260803_112649.csv', '11:26 day70'),
                  (r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260803_123739.csv', '12:37 day154')):
    slp, terr = load(path)
    cls, water = build_cls(terr)
    K = slp[:, 0] - slp[:, -1]
    D = cls[:, 0] - cls[:, -1]
    # 东西相邻对（内部列 + 接缝对）的 SLP 差，按"类是否相同"分组
    pairs_same, pairs_diff = [], []
    for rr in range(H):
        for cc in range(W):
            c2 = (cc + 1) % W
            dv = abs(slp[rr, cc] - slp[rr, c2])
            if abs(cls[rr, cc] - cls[rr, c2]) > 0.05:
                pairs_diff.append(dv)
            else:
                pairs_same.append(dv)
    seam_dv = np.abs(K)
    ps, pd = np.array(pairs_same), np.array(pairs_diff)
    print('=== %s ===' % tag)
    print('K mean=%.4f  D=cls(0)-cls(99) mean=%.3f  corr(K,D)=%.3f' % (K.mean(), D.mean(), np.corrcoef(K, D)[0, 1]))
    print('D 分布: 全同号行数=%d/64  D>0.9 行数=%d  D<-0.9 行数=%d' % ((np.abs(D) > 0.9).sum(), (D > 0.9).sum(), (D < -0.9).sum()))
    print('|dSLP| 同类东西对: n=%d mean=%.4f p95=%.4f' % (ps.size, ps.mean(), np.percentile(ps, 95)))
    print('|dSLP| 跨类东西对(内部海岸线): n=%d mean=%.4f p50=%.4f p95=%.4f max=%.4f' % (
        pd.size, pd.mean(), np.percentile(pd, 50), np.percentile(pd, 95), pd.max()))
    print('|dSLP| 接缝对: mean=%.4f max=%.4f  位于跨类内部分位的 %.0f%%' % (
        seam_dv.mean(), seam_dv.max(), 100.0 * (pd < seam_dv.mean()).mean()))
    print()
