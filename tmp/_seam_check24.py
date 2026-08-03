import csv
import numpy as np

W, H = 100, 64

def load(path):
    rows = list(csv.DictReader(open(path, encoding='utf-8')))
    g = np.zeros((H, W))
    for r in rows:
        q, rr = int(r['q']), int(r['r'])
        col = q + (rr - (rr & 1)) // 2
        g[rr, col] = float(r['slp_arr'])
    return g

for path, tag in ((r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260803_112649.csv', '11:26'),
                  (r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260803_123739.csv', '12:37')):
    g = load(path)
    g = g - g.mean(axis=1, keepdims=True)
    # 奇数行半格 stagger：功率谱不受影响
    F = np.fft.rfft(g, axis=1)
    P = (np.abs(F) ** 2).mean(axis=0)
    total = P[1:].sum()
    print('=== %s ===' % tag)
    for k in range(0, 11):
        bar = '#' * int(60 * P[k] / max(P[1:].max(), 1e-12))
        print('  k=%2d  P=%10.2f (%5.1f%%) %s' % (k, P[k], 100.0 * P[k] / total, bar))
    # 相位 of k=1,2
    ph1 = np.angle(F[:, 1]).mean()
    ph2 = np.angle(F[:, 2]).mean()
    print('  mean phase k1=%.2f k2=%.2f' % (ph1, ph2))
