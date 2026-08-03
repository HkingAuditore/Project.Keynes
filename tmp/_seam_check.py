import csv, math
from collections import defaultdict

rows = list(csv.DictReader(open(r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260803_103658.csv', encoding='utf-8')))
print('rows:', len(rows))
qs = [int(r['q']) for r in rows]
rs = [int(r['r']) for r in rows]
print('q range:', min(qs), max(qs), 'r range:', min(rs), max(rs))
print('ticks:', sorted(set(r['tick_idx'] for r in rows)))

def f(r, k):
    try:
        return float(r[k])
    except Exception:
        return 0.0

agg = defaultdict(lambda: defaultdict(list))
for r in rows:
    q = int(r['q'])
    a = agg[q]
    a['wx'].append(f(r, 'wind_x_arr')); a['wy'].append(f(r, 'wind_y_arr'))
    a['wsp'].append(f(r, 'wind_speed_arr'))
    a['ocx'].append(f(r, 'ocean_current_x_arr')); a['ocy'].append(f(r, 'ocean_current_y_arr'))
    a['slp'].append(f(r, 'slp_arr')); a['psi'].append(f(r, 'ocean_psi_arr'))
    a['water'].append(f(r, 'is_water_arr'))

def mag(xs, ys):
    return [math.hypot(x, y) for x, y in zip(xs, ys)]

def mean(v):
    return sum(v) / len(v) if v else 0.0

print('q | n | water% | windmag | wsp | wx_mean | ocmag | ocx_mean | slp_mean | psi_mean')
for q in sorted(agg):
    a = agg[q]
    print('%3d | %3d | %.2f | %.4f | %.3f | %+.3f | %.4f | %+.4f | %+.4f | %+.4f' % (
        q, len(a['wx']), mean(a['water']), mean(mag(a['wx'], a['wy'])), mean(a['wsp']),
        mean(a['wx']), mean(mag(a['ocx'], a['ocy'])), mean(a['ocx']), mean(a['slp']), mean(a['psi'])))

# 水cell-only 看洋流（陆地 ocx=0 会稀释）
print()
print('water-only: q | nw | ocmag | ocx_mean | ocy_mean | psi_mean')
for q in sorted(agg):
    a = agg[q]
    om = [m for m, w in zip(mag(a['ocx'], a['ocy']), a['water']) if w > 0.5]
    ox = [x for x, w in zip(a['ocx'], a['water']) if w > 0.5]
    oy = [y for y, w in zip(a['ocy'], a['water']) if w > 0.5]
    ps = [p for p, w in zip(a['psi'], a['water']) if w > 0.5]
    print('%3d | %3d | %.4f | %+.4f | %+.4f | %+.4f' % (q, len(om), mean(om), mean(ox), mean(oy), mean(ps)))
