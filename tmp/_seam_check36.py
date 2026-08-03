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
        for k in ('cell_pos_x_arr', 'cell_pos_y_arr', 'cell_lat_norm_arr', 'slp_arr'):
            if k not in data:
                data[k] = np.zeros((H, W))
            data[k][rr, col] = float(r[k])
    return data

for path, tag in ((r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260803_123739.csv', '12:37 day154'),):
    d = load(path)
    px, py, latn = d['cell_pos_x_arr'], d['cell_pos_y_arr'], d['cell_lat_norm_arr']
    print('=== %s ===' % tag)
    print('cell_pos_y_arr: min=%.4f max=%.4f' % (py.min(), py.max()))
    print('  每行均值 (row: mean, std):')
    for rr in (0, 1, 2, 16, 32, 48, 62, 63):
        print('    row %2d: mean=%.4f std=%.5f' % (rr, py[rr].mean(), py[rr].std()))
    print('cell_pos_x_arr: min=%.4f max=%.4f' % (px.min(), px.max()))
    for rr in (0, 1, 2, 32, 63):
        print('    row %2d: px[0..3]=%s px[96..99]=%s' % (rr, np.round(px[rr, :4], 3), np.round(px[rr, 96:], 3)))
    print('cell_lat_norm_arr: min=%.4f max=%.4f' % (latn.min(), latn.max()))
    for rr in (0, 16, 32, 48, 63):
        print('    row %2d: mean=%.4f std=%.5f' % (rr, latn[rr].mean(), latn[rr].std()))
