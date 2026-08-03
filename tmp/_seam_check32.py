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
    rm = slp.mean(axis=1)
    py = (1.5 * np.arange(H) + 2.5) / 100.0
    ls = 1.0 - 2.0 * py
    base_lat = -0.16 * np.cos(np.abs(ls) * np.pi * 3.0)
    c = np.corrcoef(rm, base_lat)[0, 1]
    A = np.stack([base_lat, np.ones(H)], axis=1)
    coef, *_ = np.linalg.lstsq(A, rm, rcond=None)
    print('=== %s ===  corr(rowmean, base_lat)=%.3f  fit: rowmean ≈ %.3f*base_lat + %.4f' % (tag, c, coef[0], coef[1]))
    for lo in range(0, H, 8):
        print('  rows %2d-%2d: rowmean=%+.4f  base_lat=%+.4f' % (lo, lo + 7, rm[lo:lo + 8].mean(), base_lat[lo:lo + 8].mean()))
    print()
