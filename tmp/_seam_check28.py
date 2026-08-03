import csv
import numpy as np

W, H = 100, 64
WATER = {0, 1, 19, 21}

def load(path):
    rows = list(csv.DictReader(open(path, encoding='utf-8')))
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
        offs = [(0, 1), (-1, 0), (-1, -1), (0, -1), (1, -1), (1, 0)] if not (rr & 1) else \
               [(0, 1), (-1, 1), (-1, 0), (0, -1), (1, 0), (1, 1)]
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
    row, col = np.mgrid[0:H, 0:W]
    px = ((col + 0.5 * (row & 1)) / W) % 1.0
    bs = []
    for rr in range(H):
        A = np.stack([cls[rr], np.cos(np.pi * px[rr]), np.sin(np.pi * px[rr]), np.ones(W)], axis=1)
        coef, *_ = np.linalg.lstsq(A, slp[rr], rcond=None)
        bs.append(coef[0])
    bs = np.array(bs)
    print('=== %s ===' % tag)
    print('landsea coef b(r) (=-solar_heat*0.55 if active): mean=%.4f median=%.4f min=%.4f max=%.4f' % (
        bs.mean(), np.median(bs), bs.min(), bs.max()))
    print('b by latitude bands:')
    for lo in range(0, H, 8):
        print('  rows %2d-%2d: %.4f' % (lo, lo + 7, bs[lo:lo + 8].mean()))
