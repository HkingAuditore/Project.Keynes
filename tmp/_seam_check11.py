import csv

path = r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260803_112649.csv'
rows = list(csv.DictReader(open(path, encoding='utf-8')))

# 检查重复 cell（19200 行 vs 6400 cells）
from collections import Counter
key_count = Counter((r['q'], r['r']) for r in rows)
dups = [k for k, v in key_count.items() if v > 1]
print('unique cells:', len(key_count), ' duplicated:', len(dups), ' max dup:', max(key_count.values()))
# 看重复行的差异字段
if dups:
    k0 = dups[0]
    same = [r for r in rows if (r['q'], r['r']) == k0]
    print('sample dup cell %s: %d rows' % (k0, len(same)))
    diff_cols = [c for c in rows[0].keys() if len(set(r[c] for r in same)) > 1]
    print('  differing columns:', diff_cols[:20])
    for r in same:
        print('   tick_idx=%s slp=%s psi=%s' % (r['tick_idx'], r['slp_arr'], r['ocean_psi_arr']))

def f_(r, k):
    try:
        return float(r[k])
    except Exception:
        return 0.0

cells = {}
for r in rows:
    q, rr = int(r['q']), int(r['r'])
    col = q + (rr - (rr & 1)) // 2
    cells[(col, rr)] = r
W, H = 100, 64

# 每行接缝跳变 + 该行最大内部跳变，标出 kink 行分布
print()
print('row | seam_jump | max_interior_jump | seam_is_max')
kink_rows = []
for rr in range(H):
    seam = abs(f_(cells[(0, rr)], 'slp_arr') - f_(cells[(W-1, rr)], 'slp_arr'))
    best = max(abs(f_(cells[((c+1) % W, rr)], 'slp_arr') - f_(cells[(c, rr)], 'slp_arr')) for c in range(W-1))
    is_max = seam > best
    if is_max:
        kink_rows.append(rr)
print('rows where seam is max jump:', kink_rows)

# 接缝窗口数值（每 8 行）
print()
print('slp window cols 96-99 | 0-3:')
for rr in range(0, H, 8):
    vals = [f_(cells[(c, rr)], 'slp_arr') for c in [96, 97, 98, 99, 0, 1, 2, 3]]
    print('row %2d: %s | %s' % (rr,
          ' '.join('%+.3f' % v for v in vals[:4]),
          ' '.join('%+.3f' % v for v in vals[4:])))

# cell_pos_x 检查：col 99 与 col 0 的 pos_x 差
print()
r0 = cells[(0, 0)]; r99 = cells[(99, 0)]
print('row0: col0 pos_x=%.4f col99 pos_x=%.4f diff=%.4f (expect sqrt3=%.4f per col; wrap period should be %s)' % (
    f_(r0, 'cell_pos_x_arr'), f_(r99, 'cell_pos_x_arr'),
    f_(r99, 'cell_pos_x_arr') - f_(r0, 'cell_pos_x_arr'), 3**0.5, 'width*sqrt3*hex_size'))
# 奇数行
r0o = cells[(0, 1)]; r99o = cells[(99, 1)]
print('row1: col0 pos_x=%.4f col99 pos_x=%.4f' % (f_(r0o, 'cell_pos_x_arr'), f_(r99o, 'cell_pos_x_arr')))
