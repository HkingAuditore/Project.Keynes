import csv
import numpy as np

path = r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260803_123739.csv'
rows = list(csv.DictReader(open(path, encoding='utf-8')))
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

print('12:37 slp window cols 94-99 | 0-5 (every 4 rows):')
for rr in range(0, H, 4):
    vals = [f_(cells[(c, rr)], 'slp_arr') for c in list(range(94, 100)) + list(range(0, 6))]
    print('row %2d: %s | %s' % (rr,
          ' '.join('%+.3f' % v for v in vals[:6]),
          ' '.join('%+.3f' % v for v in vals[6:])))

# 完整行剖面：row 30（同前对比）
print()
rr = 30
vals = [f_(cells[(c, rr)], 'slp_arr') for c in range(W)]
m = sum(vals)/W
prof = [v - m for v in vals]
print('row 30 mean-subtracted profile (12:37):')
for g in range(10):
    print('  cols %2d-%2d: %s' % (g*10, g*10+9, ' '.join('%+.3f' % v for v in prof[g*10:(g+1)*10])))

# 找全图 SLP 极小值（移动低压候选）位置：每行最小值列
print()
print('per-row SLP min column (mobile low x-positions):')
for rr in range(0, H, 4):
    vals = [f_(cells[(c, rr)], 'slp_arr') for c in range(W)]
    mc = min(range(W), key=lambda c: vals[c])
    print('  row %2d: min at col %2d (%.3f)' % (rr, mc, vals[mc]))
