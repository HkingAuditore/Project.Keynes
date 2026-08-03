import csv, math

rows = list(csv.DictReader(open(r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260803_103658.csv', encoding='utf-8')))

def f(r, k):
    try:
        return float(r[k])
    except Exception:
        return 0.0

W = 60
cells = {}
for r in rows:
    q, rr = int(r['q']), int(r['r'])
    col = q + (rr - (rr & 1)) // 2
    cells[(col, rr)] = r

# 1) 每列统计（offset col）
from collections import defaultdict
agg = defaultdict(lambda: defaultdict(list))
for (col, rr), r in cells.items():
    a = agg[col]
    a['wx'].append(f(r, 'wind_x_arr')); a['wy'].append(f(r, 'wind_y_arr'))
    a['ocx'].append(f(r, 'ocean_current_x_arr')); a['ocy'].append(f(r, 'ocean_current_y_arr'))
    a['slp'].append(f(r, 'slp_arr')); a['psi'].append(f(r, 'ocean_psi_arr'))
    a['water'].append(f(r, 'is_water_arr'))

def mag(xs, ys): return [math.hypot(x, y) for x, y in zip(xs, ys)]
def mean(v): return sum(v) / len(v) if v else 0.0

print('col | water% | ocmag(water) | psi_mean(water) | windmag | slp_mean')
for c in sorted(agg):
    a = agg[c]
    ow = [(m, p) for m, p in zip(mag(a['ocx'], a['ocy']), a['psi']) ]
    wm = [m for (m, p), w in zip(ow, a['water']) if w > 0.5]
    ps = [p for (m, p), w in zip(ow, a['water']) if w > 0.5]
    print('%3d | %.2f | %.4f | %+8.4f | %.3f | %+.4f' % (
        c, mean(a['water']), mean(wm), mean(ps), mean(mag(a['wx'], a['wy'])), mean(a['slp'])))

# 2) 逐行接缝对：col=59 vs col=0（互为回绕邻居）
print()
print('seam pairs per row: row | water(59,0) | psi59 psi0 | oc59 oc0 | slp59 slp0 | wind59 wind0')
for rr in range(40):
    a = cells.get((59, rr)); b = cells.get((0, rr))
    if a is None or b is None:
        continue
    wa, wb = f(a, 'is_water_arr'), f(b, 'is_water_arr')
    pa, pb = f(a, 'ocean_psi_arr'), f(b, 'ocean_psi_arr')
    oca = (f(a, 'ocean_current_x_arr'), f(a, 'ocean_current_y_arr'))
    ocb = (f(b, 'ocean_current_x_arr'), f(b, 'ocean_current_y_arr'))
    sa, sb = f(a, 'slp_arr'), f(b, 'slp_arr')
    wa_v = (f(a, 'wind_x_arr'), f(a, 'wind_y_arr'))
    wb_v = (f(b, 'wind_x_arr'), f(b, 'wind_y_arr'))
    print('%3d | %.0f/%.0f | %+7.3f %+7.3f | (%+.3f,%+.3f) (%+.3f,%+.3f) | %+.4f %+.4f | (%+.2f,%+.2f) (%+.2f,%+.2f)' % (
        rr, wa, wb, pa, pb, oca[0], oca[1], ocb[0], ocb[1], sa, sb, wa_v[0], wa_v[1], wb_v[0], wb_v[1]))
