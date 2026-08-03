import csv, math

rows = list(csv.DictReader(open(r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260803_103658.csv', encoding='utf-8')))

def f(r, k):
    try:
        return float(r[k])
    except Exception:
        return 0.0

cells = {}
for r in rows:
    q, rr = int(r['q']), int(r['r'])
    col = q + (rr - (rr & 1)) // 2
    cells[(col, rr)] = r

# 纬向占比 = mean(|vx| / (|vx|+|vy|))：1 = 纯东西向，0 = 纯南北向
def zonal_ratio(vx, vy):
    s = abs(vx) + abs(vy)
    return abs(vx) / s if s > 1e-9 else 0.5

for name, kx, ky, water_only in [('wind', 'wind_x_arr', 'wind_y_arr', False),
                                 ('ocean', 'ocean_current_x_arr', 'ocean_current_y_arr', True)]:
    print('=== %s: zonal ratio (|x|/(|x|+|y|)) per column band ===' % name)
    bands = [('seam cols 0,59', [0, 59]), ('near-seam 1-3,56-58', [1, 2, 3, 56, 57, 58]),
             ('mid 10-20', list(range(10, 21))), ('mid 25-45', list(range(25, 46)))]
    for label, cols in bands:
        vals = []
        for (col, row), r in cells.items():
            if col not in cols:
                continue
            if water_only and f(r, 'is_water_arr') < 0.5:
                continue
            vals.append(zonal_ratio(f(r, kx), f(r, ky)))
        print('  %-18s n=%4d  zonal=%.3f' % (label, len(vals), sum(vals)/len(vals) if vals else 0.0))
    print()

# 接缝列按纬度带分
print('=== wind zonal ratio at seam cols (0,59) by latitude band ===')
for label, rband in [('north r=0-9', range(0, 10)), ('mid-n r=10-19', range(10, 20)),
                     ('mid-s r=20-29', range(20, 30)), ('south r=30-39', range(30, 40))]:
    vals_seam, vals_int = [], []
    for (col, row), r in cells.items():
        if row not in rband:
            continue
        v = zonal_ratio(f(r, 'wind_x_arr'), f(r, 'wind_y_arr'))
        if col in (0, 59):
            vals_seam.append(v)
        elif 20 <= col <= 39:
            vals_int.append(v)
    print('  %-14s seam=%.3f (n=%d)  interior=%.3f (n=%d)' % (
        label, sum(vals_seam)/len(vals_seam) if vals_seam else 0, len(vals_seam),
        sum(vals_int)/len(vals_int) if vals_int else 0, len(vals_int)))

print()
print('=== ocean zonal ratio at seam cols (0,59) by latitude band (water only) ===')
for label, rband in [('north r=0-9', range(0, 10)), ('mid-n r=10-19', range(10, 20)),
                     ('mid-s r=20-29', range(20, 30)), ('south r=30-39', range(30, 40))]:
    vals_seam, vals_int = [], []
    for (col, row), r in cells.items():
        if row not in rband or f(r, 'is_water_arr') < 0.5:
            continue
        v = zonal_ratio(f(r, 'ocean_current_x_arr'), f(r, 'ocean_current_y_arr'))
        if col in (0, 59):
            vals_seam.append(v)
        elif 20 <= col <= 39:
            vals_int.append(v)
    print('  %-14s seam=%.3f (n=%d)  interior=%.3f (n=%d)' % (
        label, sum(vals_seam)/len(vals_seam) if vals_seam else 0, len(vals_seam),
        sum(vals_int)/len(vals_int) if vals_int else 0, len(vals_int)))
