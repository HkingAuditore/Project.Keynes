import csv
import math
import statistics
import sys

NEW = r'tmp/tile_data_record_20260803_205759.csv'
OLD = r'tmp/tile_data_record_20260803_200553.csv'
SQRT3 = math.sqrt(3.0)


def cube_to_offset(q, r):
    return q + (r - (r & 1)) // 2, r


def load(path):
    """returns tick -> {(col,row) -> {field: value}}, and field list"""
    per_tick = {}
    numeric_fields = None
    with open(path, newline='', encoding='utf-8-sig') as f:
        rd = csv.DictReader(f)
        for row in rd:
            try:
                q, r = int(row['q']), int(row['r'])
            except (KeyError, TypeError, ValueError):
                continue
            tick = row.get('tick') or row.get('day') or '0'
            col, rw = cube_to_offset(q, r)
            if numeric_fields is None:
                numeric_fields = []
                for k, v in row.items():
                    if k in ('q', 'r', 'tick', 'day'):
                        continue
                    try:
                        float(v)
                    except (TypeError, ValueError):
                        continue
                    numeric_fields.append(k)
            rec = {}
            for k in numeric_fields:
                try:
                    rec[k] = float(row[k])
                except (TypeError, ValueError):
                    rec[k] = float('nan')
            per_tick.setdefault(tick, {})[(col, rw)] = rec
    return per_tick, numeric_fields


def seam_ratio(per_tick, fields, width, height):
    """对每个字段：接缝列差分绝对值均值 / 内部列差分绝对值均值"""
    out = {}
    for fld in fields:
        seam_vals = []
        inner_vals = []
        for tick, cells in per_tick.items():
            for rw in range(height):
                # 接缝：col width-1 -> col 0
                a = cells.get((width - 1, rw))
                b = cells.get((0, rw))
                if a and b:
                    va, vb = a[fld], b[fld]
                    if not (math.isnan(va) or math.isnan(vb)):
                        seam_vals.append(abs(vb - va))
                # 内部：所有 col c -> c+1
                for c in range(width - 1):
                    a = cells.get((c, rw))
                    b = cells.get((c + 1, rw))
                    if a and b:
                        va, vb = a[fld], b[fld]
                        if not (math.isnan(va) or math.isnan(vb)):
                            inner_vals.append(abs(vb - va))
        if len(seam_vals) < 4 or len(inner_vals) < 40:
            continue
        s = statistics.mean(seam_vals)
        n = statistics.mean(inner_vals)
        if n < 1e-12:
            continue
        out[fld] = (s / n, s, n)
    return out


def grid_dims(per_tick):
    keys = set()
    for cells in per_tick.values():
        keys |= set(cells.keys())
    return max(k[0] for k in keys) + 1, max(k[1] for k in keys) + 1


results = {}
for label, path in (('OLD (fix前)', OLD), ('NEW (fix后)', NEW)):
    per_tick, fields = load(path)
    w, h = grid_dims(per_tick)
    print('%s: %s  ticks=%d  grid=%dx%d  numeric fields=%d'
          % (label, path, len(per_tick), w, h, len(fields)))
    results[label] = seam_ratio(per_tick, fields, w, h)

print()
print('%-34s %12s %12s' % ('field', 'OLD ratio', 'NEW ratio'))
print('-' * 60)
old = results['OLD (fix前)']
new = results['NEW (fix后)']
allf = sorted(set(old) | set(new), key=lambda f: -max(old.get(f, (0,))[0], new.get(f, (0,))[0]))
for f in allf[:28]:
    o = old.get(f)
    n = new.get(f)
    print('%-34s %12s %12s' % (
        f,
        ('%.2fx' % o[0]) if o else '   -',
        ('%.2fx' % n[0]) if n else '   -'))
