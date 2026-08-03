import csv
import numpy as np

def load(path):
    rows = list(csv.DictReader(open(path, encoding='utf-8')))
    cells = {}
    for r in rows:
        q, rr = int(r['q']), int(r['r'])
        col = q + (rr - (rr & 1)) // 2
        cells[(col, rr)] = r
    return cells

def f_(r, k):
    try:
        return float(r[k])
    except Exception:
        return 0.0

c_old = load(r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260803_112649.csv')
c_new = load(r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260803_123739.csv')
W, H = 100, 64

# 同一格在两次录制中的 SLP / 输入场对比
print('row | slp_seam(11:26) | slp_seam(12:37) | terrain(99) | terrain(0) | vapor_seam | cloud_seam | ice_seam | tempan_seam')
for rr in range(0, H, 2):
    s_old = f_(c_old[(0, rr)], 'slp_arr') - f_(c_old[(W-1, rr)], 'slp_arr')
    s_new = f_(c_new[(0, rr)], 'slp_arr') - f_(c_new[(W-1, rr)], 'slp_arr')
    t99 = int(f_(c_new[(W-1, rr)], 'terrain_arr'))
    t0 = int(f_(c_new[(0, rr)], 'terrain_arr'))
    dv = f_(c_new[(0, rr)], 'weather_vapor_arr') - f_(c_new[(W-1, rr)], 'weather_vapor_arr')
    dc = f_(c_new[(0, rr)], 'weather_cloud_arr') - f_(c_new[(W-1, rr)], 'weather_cloud_arr')
    di = f_(c_new[(0, rr)], 'sea_ice_frac_arr') - f_(c_new[(W-1, rr)], 'sea_ice_frac_arr')
    dt = f_(c_new[(0, rr)], 'temp_anomaly_arr') - f_(c_new[(W-1, rr)], 'temp_anomaly_arr')
    mark = ' <<<' if abs(s_new) > 0.02 else ''
    print('%3d | %+.4f | %+.4f | %2d | %2d | %+.3f | %+.3f | %+.3f | %+.4f%s' % (
        rr, s_old, s_new, t99, t0, dv, dc, di, dt, mark))

# 12:37 录制中，kink 行（|slp_seam|>0.02）的地形配对统计
print()
kink_terrain = {}
for rr in range(H):
    s_new = f_(c_new[(0, rr)], 'slp_arr') - f_(c_new[(W-1, rr)], 'slp_arr')
    if abs(s_new) > 0.02:
        key = (int(f_(c_new[(W-1, rr)], 'terrain_arr')), int(f_(c_new[(0, rr)], 'terrain_arr')))
        kink_terrain[key] = kink_terrain.get(key, 0) + 1
print('kink rows terrain pairs (col99, col0) -> count:', kink_terrain)

# 全部行的地形配对 vs 平均 |slp_seam|
pair_sum = {}
pair_cnt = {}
for rr in range(H):
    key = (int(f_(c_new[(W-1, rr)], 'terrain_arr')), int(f_(c_new[(0, rr)], 'terrain_arr')))
    s = abs(f_(c_new[(0, rr)], 'slp_arr') - f_(c_new[(W-1, rr)], 'slp_arr'))
    pair_sum[key] = pair_sum.get(key, 0.0) + s
    pair_cnt[key] = pair_cnt.get(key, 0) + 1
print()
print('all rows: (terrain99, terrain0) -> mean|slp_seam| (count)')
for k in sorted(pair_sum, key=lambda k: -pair_sum[k]/pair_cnt[k]):
    print('  %s -> %.4f (%d)' % (k, pair_sum[k]/pair_cnt[k], pair_cnt[k]))
