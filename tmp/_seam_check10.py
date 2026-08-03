import csv

path = r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260803_112649.csv'
f = open(path, encoding='utf-8')
rdr = csv.reader(f)
hdr = next(rdr)
print('columns:', len(hdr))
rows = list(csv.DictReader(open(path, encoding='utf-8')))
print('rows:', len(rows))

# 地图尺寸
qs = [int(r['q']) for r in rows]; rs = [int(r['r']) for r in rows]
print('q range:', min(qs), max(qs), ' r range:', min(rs), max(rs))

# 诊断头字段（取第一行）
diag_keys = [k for k in rows[0].keys() if k.startswith(('phys_', 'climate_', 'world', 'sim', 'tick', 'seed', 'wrap'))]
for k in diag_keys:
    print('  %s = %s' % (k, rows[0][k]))

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
W = max(c[0] for c in cells) + 1
H = max(c[1] for c in cells) + 1
print('inferred W x H =', W, 'x', H)

FIELDS = ['slp_arr', 'ocean_psi_arr', 'wind_x_arr', 'wind_y_arr',
          'ocean_current_x_arr', 'ocean_current_y_arr', 'temp_arr', 'moisture_arr',
          'weather_vapor_arr', 'sea_ice_frac_arr', 'snow_cover_arr']
print()
print('field | seam_jump(last,0) | interior_jump | ratio')
for k in FIELDS:
    seam, interior = [], []
    for rr in range(H):
        a = cells.get((W-1, rr)); b = cells.get((0, rr))
        if a is None or b is None: continue
        seam.append(abs(f_(a, k) - f_(b, k)))
        for c in range(W-1):
            aa = cells.get((c, rr)); bb = cells.get((c+1, rr))
            interior.append(abs(f_(aa, k) - f_(bb, k)))
    ms = sum(seam)/len(seam); mi = sum(interior)/len(interior)
    print('%-24s | %.4f | %.4f | %.1fx' % (k, ms, mi, ms/mi if mi > 1e-9 else float('inf')))

# 每行最大跳变位置统计（slp）
pos_hist = {}
for rr in range(H):
    best_pos, best_val = -1, -1.0
    for c in range(W):
        c2 = (c + 1) % W
        v = abs(f_(cells[(c2, rr)], 'slp_arr') - f_(cells[(c, rr)], 'slp_arr'))
        if v > best_val:
            best_val, best_pos = v, c
    pos_hist[best_pos] = pos_hist.get(best_pos, 0) + 1
top = sorted(pos_hist.items(), key=lambda kv: -kv[1])[:6]
print()
print('slp max-jump position histogram (top 6; %d = seam):' % (W-1))
for p, n in top:
    print('  col %3d: %d rows' % (p, n))
