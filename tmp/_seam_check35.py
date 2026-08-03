import csv
import sys
import io
import numpy as np

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

W, H = 100, 64

def load(path):
    rows = list(csv.DictReader(open(path, encoding='utf-8-sig')))
    g = np.zeros((H, W))
    for r in rows:
        q, rr = int(r['q']), int(r['r'])
        col = q + (rr - (rr & 1)) // 2
        g[rr, col] = float(r['slp_arr'])
    return g

for path, tag in ((r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260803_112649.csv', '11:26 day70'),
                  (r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260803_123739.csv', '12:37 day154')):
    slp = load(path)
    K = slp[:, 0] - slp[:, -1]
    print('=== %s ===  K mean=%.4f std=%.4f min=%.4f max=%.4f  正号行=%d 负号行=%d' % (
        tag, K.mean(), K.std(), K.min(), K.max(), (K > 0.002).sum(), (K < -0.002).sum()))
    # 每 4 行打印
    for lo in range(0, H, 4):
        seg = K[lo:lo + 4]
        print('  rows %2d-%2d: %s' % (lo, lo + 3, ' '.join('%+.4f' % v for v in seg)))
    print()
