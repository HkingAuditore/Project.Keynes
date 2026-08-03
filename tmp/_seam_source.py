import csv, math, collections

P = r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260803_200553.csv'
def cube_to_offset(q, r):
    return q + (r - (r & 1)) // 2, r

FIELDS = ['elevation_arr','base_moisture_arr','temp_baseline_arr','temp_arr','slp_arr',
          'cell_lat_norm_arr','cell_pos_x_arr','cell_pos_y_arr','wind_speed_arr',
          'wind_x_arr','wind_y_arr','ocean_current_x_arr','ocean_current_y_arr',
          'ocean_psi_arr','wind_stress_curl_arr','moisture_arr','snow_cover_arr',
          'local_thermal_anomaly_arr','air_mass_temp_anomaly_arr','ocean_thermal_anomaly_arr']

grid = {}
with open(P, encoding='utf-8-sig', newline='') as f:
    rd = csv.DictReader(f)
    for row in rd:
        col, rw = cube_to_offset(int(row['q']), int(row['r']))
        t = int(row['tick_idx'])
        d = {}
        for k in FIELDS:
            try: d[k] = float(row[k])
            except Exception: d[k] = float('nan')
        d['water'] = row['is_water_arr'] in ('1','true','True')
        d['terrain'] = row['terrain_arr']
        grid[(col, rw, t)] = d

W, H = 100, 64
ticks = sorted({k[2] for k in grid})
T = ticks[-1]

def mean(v):
    v=[x for x in v if x==x]
    return sum(v)/len(v) if v else float('nan')

print('=== 每个字段：跨列绝对差的 中位数 vs 接缝(99->0) ===')
print('%-30s %12s %12s %12s %12s %8s' % ('field','med_interior','d(98->99)','d(99->0)','d(0->1)','ratio'))
for k in FIELDS:
    per = []
    for c in range(W):
        c2 = (c+1) % W
        vs = []
        for rw in range(H):
            a = grid.get((c,rw,T)); b = grid.get((c2,rw,T))
            if a and b: vs.append(abs(a[k]-b[k]))
        per.append(mean(vs))
    interior = [per[c] for c in range(2, 97)]
    interior = [x for x in interior if x==x]
    med = sorted(interior)[len(interior)//2]
    ratio = per[99]/med if med else float('inf')
    print('%-30s %12.6f %12.6f %12.6f %12.6f %8.2f' % (k, med, per[98], per[99], per[0], ratio))

print()
print('=== POSX 逐列（row 0 与 row 1）===')
for c in list(range(0,4))+list(range(48,52))+list(range(96,100)):
    a = grid.get((c,0,T)); b = grid.get((c,1,T))
    print('col %3d  row0 posx=%10.4f  row1 posx=%10.4f  lat0=%.4f' % (c, a['cell_pos_x_arr'], b['cell_pos_x_arr'], a['cell_lat_norm_arr']))

print()
print('=== 接缝断面（tick %d）: row, col97..99 | col0..2 的 slp / windDir(deg) / windSpeed ===' % T)
print('%4s %-42s %-42s' % ('row','SLP  97 / 98 / 99 || 0 / 1 / 2','windDirDeg 97/98/99 || 0/1/2   WS 99/0'))
for rw in range(0, H, 4):
    cs = [97,98,99,0,1,2]
    g = [grid.get((c,rw,T)) for c in cs]
    if any(x is None for x in g): continue
    slp = ' '.join('%8.4f'%x['slp_arr'] for x in g)
    wd  = ' '.join('%6.1f'%(math.degrees(math.atan2(x['wind_y_arr'],x['wind_x_arr']))) for x in g)
    ws  = ' '.join('%5.2f'%x['wind_speed_arr'] for x in g)
    print('%4d %s | %s | %s' % (rw, slp, wd, ws))

print()
print('=== 列平均 windSpeed / |ocean| 剖面（找出异常列）===')
prof = []
for c in range(W):
    ws = mean([grid[(c,rw,T)]['wind_speed_arr'] for rw in range(H) if (c,rw,T) in grid])
    om = mean([math.hypot(grid[(c,rw,T)]['ocean_current_x_arr'],grid[(c,rw,T)]['ocean_current_y_arr'])
               for rw in range(H) if (c,rw,T) in grid and grid[(c,rw,T)]['water']])
    prof.append((c, ws, om))
mws = mean([p[1] for p in prof[2:97]])
for c, ws, om in prof:
    bar = '#' * int(max(0.0, (ws - 0.6)) * 60)
    print('%3d ws=%.4f (%.2fx) |ocean|=%.5f %s' % (c, ws, ws/mws, om, bar))
