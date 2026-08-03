import csv

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

for rr in [5, 7, 31, 33]:
    print('=== row %d ===' % rr)
    line_slp = []
    line_psi = []
    line_w = []
    for c in range(60):
        r = cells.get((c, rr))
        if r is None:
            continue
        line_slp.append('%+.3f' % f(r, 'slp_arr'))
        p = f(r, 'ocean_psi_arr')
        w = f(r, 'is_water_arr')
        line_psi.append('%+.2f%s' % (p, '' if w > 0.5 else 'L'))
        line_w.append('%.0f' % w)
    print('water :', ' '.join(line_w))
    print('slp   :', ' '.join(line_slp))
    print('psi   :', ' '.join(line_psi))
    print()

# 接缝两侧各 4 列的细节（row 31/33）
for rr in [31, 33]:
    print('=== row %d seam detail (cols 56,57,58,59 | 0,1,2,3) ===' % rr)
    for c in [56, 57, 58, 59, 0, 1, 2, 3]:
        r = cells.get((c, rr))
        slp = f(r, 'slp_arr'); psi = f(r, 'ocean_psi_arr')
        ocx = f(r, 'ocean_current_x_arr'); ocy = f(r, 'ocean_current_y_arr')
        wx = f(r, 'wind_x_arr'); wy = f(r, 'wind_y_arr'); w = f(r, 'is_water_arr')
        print('col %2d w=%.0f slp=%+.4f psi=%+7.3f oc=(%+.3f,%+.3f) wind=(%+.2f,%+.2f)' % (c, w, slp, psi, ocx, ocy, wx, wy))
    print()
