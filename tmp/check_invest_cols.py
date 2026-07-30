import csv

def load(path):
    return list(csv.DictReader(open(path, encoding='utf-8-sig')))

def avg(rows, col, lo=10, hi=170):
    vals = []
    for r in rows[lo:hi]:
        try:
            vals.append(float(r.get(col, '') or 0))
        except ValueError:
            pass
    return sum(vals) / len(vals) if vals else float('nan')

t2 = load(r'D:\Godot\ProjectKeynes\Project.Keynes\tmp\perf_record_20260730_210447.csv')
t1 = load(r'D:\Godot\ProjectKeynes\Project.Keynes\tmp\perf_record_20260730_202819.csv')

print('--- t2_new columns matching invest/sponsor (avg ms or count/day) ---')
for c in sorted(t2[0].keys()):
    cl = c.lower()
    if 'invest' in cl or 'sponsor' in cl or 'gate_capital' in cl:
        v = avg(t2, c)
        if v == v and abs(v) > 1e-9:
            print('%-64s %12.3f' % (c, v))

print()
print('--- stage wall columns (bd_economy_cont*/stage*) top 25 by avg ---')
cands = []
for c in t2[0].keys():
    cl = c.lower()
    if ('_ms' in cl) and ('econ' in cl or 'cont' in cl or 'stage' in cl):
        v = avg(t2, c)
        if v == v and v > 0.05:
            cands.append((v, c))
for v, c in sorted(cands, reverse=True)[:25]:
    v1 = avg(t1, c)
    d = (v - v1) / v1 * 100 if v1 and v1 == v1 else float('nan')
    print('%-64s t2=%9.3f t1=%9.3f d=%7.1f%%' % (c, v, v1, d))
