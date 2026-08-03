import csv, math, collections

P = r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260803_200553.csv'

def cube_to_offset(q, r):
    return q + (r - (r & 1)) // 2, r

rows = collections.defaultdict(list)  # cell -> list of (tick, wx, wy, ox, oy, ws, slp, psi, water, curl)
meta = {}

with open(P, encoding='utf-8-sig', newline='') as f:
    rd = csv.DictReader(f)
    for row in rd:
        ci = int(row['cell_index'])
        t = int(row['tick_idx'])
        q, r = int(row['q']), int(row['r'])
        col, rw = cube_to_offset(q, r)
        meta[ci] = (col, rw)
        def g(k):
            v = row[k]
            try:
                return float(v)
            except Exception:
                return float('nan')
        rows[ci].append((t, g('wind_x_arr'), g('wind_y_arr'), g('ocean_current_x_arr'),
                         g('ocean_current_y_arr'), g('wind_speed_arr'), g('slp_arr'),
                         g('ocean_psi_arr'), row['is_water_arr'], g('wind_stress_curl_arr'),
                         g('upwelling_strength_arr')))

W = max(c for c, _ in meta.values()) + 1
H = max(r for _, r in meta.values()) + 1
print('grid', W, 'x', H, 'cells', len(rows))

def ang(x, y):
    return math.atan2(y, x)

def circ_std(angles):
    if not angles:
        return float('nan')
    s = sum(math.sin(a) for a in angles) / len(angles)
    c = sum(math.cos(a) for a in angles) / len(angles)
    R = math.hypot(s, c)
    R = min(1.0, R)
    return math.sqrt(max(0.0, -2.0 * math.log(R))) if R > 1e-12 else float('inf')

# per column aggregates
col_wind_std = collections.defaultdict(list)
col_ocean_std = collections.defaultdict(list)
col_align = collections.defaultdict(list)   # cos between wind and ocean
col_wmag = collections.defaultdict(list)
col_omag = collections.defaultdict(list)
col_wx = collections.defaultdict(list)
col_slp_std = collections.defaultdict(list)
col_psi = collections.defaultdict(list)
col_curl = collections.defaultdict(list)
water_cols = collections.defaultdict(int)
tot_cols = collections.defaultdict(int)

for ci, recs in rows.items():
    recs.sort()
    col, rw = meta[ci]
    tot_cols[col] += 1
    is_water = recs[-1][8] in ('1', 'true', 'True')
    if is_water:
        water_cols[col] += 1
    wangs = [ang(a[1], a[2]) for a in recs if not math.isnan(a[1]) and (a[1] or a[2])]
    oangs = [ang(a[3], a[4]) for a in recs if not math.isnan(a[3]) and (a[3] or a[4])]
    col_wind_std[col].append(circ_std(wangs))
    if is_water:
        col_ocean_std[col].append(circ_std(oangs))
    for a in recs:
        wm = math.hypot(a[1], a[2]); om = math.hypot(a[3], a[4])
        col_wmag[col].append(wm)
        col_wx[col].append(a[1])
        if is_water:
            col_omag[col].append(om)
            col_psi[col].append(a[7])
            col_curl[col].append(a[9])
            if wm > 1e-9 and om > 1e-9:
                col_align[col].append((a[1] * a[3] + a[2] * a[4]) / (wm * om))
    slps = [a[6] for a in recs]
    col_slp_std[col].append(max(slps) - min(slps))

def mean(v):
    v = [x for x in v if x == x and abs(x) != float('inf')]
    return sum(v) / len(v) if v else float('nan')

print()
print('col  n  water  windDirStd  oceanDirStd  align(cos)  |wind|  |ocean|  slpTimeRange  psiMeanAbs  curlMeanAbs')
for col in range(W):
    print('%3d %4d %5d  %10.4f %11.4f %10.4f %8.4f %8.5f %12.6f %11.5f %11.6f' % (
        col, tot_cols[col], water_cols[col],
        mean(col_wind_std[col]), mean(col_ocean_std[col]), mean(col_align[col]),
        mean(col_wmag[col]), mean(col_omag[col]), mean(col_slp_std[col]),
        mean([abs(x) for x in col_psi[col]]), mean([abs(x) for x in col_curl[col]])))
