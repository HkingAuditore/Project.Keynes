import csv
import math

path = r'tmp/tile_data_record_20260803_200553.csv'
xs = {}
with open(path, newline='', encoding='utf-8-sig') as f:
    rd = csv.DictReader(f)
    cols = rd.fieldnames
    xcol = next((c for c in cols if c.strip() in ('cell_pos_x_arr', 'cell_pos_x', 'pos_x')), None)
    qcol = next((c for c in cols if c.strip() in ('q', 'cell_q')), None)
    rcol = next((c for c in cols if c.strip() in ('r', 'cell_r')), None)
    print('pos_x col =', xcol, '| q col =', qcol, '| r col =', rcol)
    if xcol is None:
        print('candidate cols:', [c for c in cols if 'pos' in c.lower()])
        raise SystemExit
    for row in rd:
        try:
            cid = int(row.get('cell_index') or row.get('cell_id') or row.get('idx'))
        except (TypeError, ValueError):
            continue
        if cid in xs:
            continue
        xs[cid] = (float(row[xcol]),
                   int(row[qcol]) if qcol else None,
                   int(row[rcol]) if rcol else None)

vals = sorted(v[0] for v in xs.values())
print('n distinct cells:', len(xs))
print('pos_x min = %.4f  max = %.4f' % (vals[0], vals[-1]))
uniq = sorted(set(round(v, 4) for v in vals))
diffs = sorted(set(round(b - a, 4) for a, b in zip(uniq, uniq[1:]) if b - a > 1e-4))
print('smallest positive spacings:', diffs[:6])
print('sqrt(3) = %.4f   sqrt(3)/2 = %.4f' % (math.sqrt(3), math.sqrt(3) / 2))
for w in (100, 120, 128):
    print('  width=%d -> width*sqrt(3) = %.3f' % (w, w * math.sqrt(3)))

# 用 q,r 直接验证公式 x = sqrt(3)*(q + r/2)
bad = 0
checked = 0
for cid, (x, q, r) in list(xs.items())[:500]:
    if q is None or r is None:
        break
    exp = math.sqrt(3) * (q + r / 2.0)
    checked += 1
    if abs(exp - x) > 1e-3:
        bad += 1
        if bad <= 3:
            print('  MISMATCH cell %d q=%d r=%d pos_x=%.4f expected(size=1)=%.4f' % (cid, q, r, x, exp))
if checked:
    print('formula x = sqrt(3)*(q + r/2) with size=1.0 -> checked %d, mismatched %d' % (checked, bad))
