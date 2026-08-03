import csv
import sys
import io
import numpy as np

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

W, H = 100, 64

def load(path):
    rows = list(csv.DictReader(open(path, encoding='utf-8-sig')))
    data = {}
    for r in rows:
        q, rr = int(r['q']), int(r['r'])
        col = q + (rr - (rr & 1)) // 2
        for k in ('slp_arr', 'wind_x_arr', 'wind_y_arr'):
            if k not in data:
                data[k] = np.zeros((H, W))
            data[k][rr, col] = float(r[k])
    return data

for path, tag in ((r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260803_112649.csv', '11:26 day70'),
                  (r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260803_123739.csv', '12:37 day154')):
    d = load(path)
    wx = d['wind_x_arr'].mean(axis=1)
    wy = d['wind_y_arr'].mean(axis=1)
    slp = d['slp_arr'].mean(axis=1)
    print('=== %s ===' % tag)
    print('row-band  wind_x_mean  wind_y_mean  slp_mean')
    for lo in range(0, H, 4):
        print('  %2d-%2d:  %+.4f   %+.4f   %+.4f' % (lo, lo + 3, wx[lo:lo + 4].mean(), wy[lo:lo + 4].mean(), slp[lo:lo + 4].mean()))
    print()
