import csv, math
from collections import defaultdict

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

FIELDS = ['temp_arr', 'moisture_arr', 'temp_anomaly_arr', 'slp_arr', 'ocean_psi_arr',
          'weather_vapor_arr', 'weather_cloud_arr', 'sea_ice_frac_arr', 'wind_x_arr', 'wind_y_arr',
          'ocean_current_x_arr', 'ocean_current_y_arr', 'elevation_arr', 'base_moisture_arr',
          'soil_moisture_arr', 'weather_precip_arr', 'vegetation_vitality_arr']

# 接缝跳变：|col59 - col0|（同 row 两者均值差）
# 对照：内部相邻列跳变 |col(c+1)-col(c)| 的均值（c=20..39，避开地形差异？不行，得同 cell 对比）
# 更公平的对照：每行 |col(c+1)-col(c)| 对所有 c 取平均 vs c=59->0 那一跳
print('field | seam_jump(mean|59-0|) | interior_jump(mean|c+1-c|) | ratio')
for k in FIELDS:
    seam = []
    interior = []
    for rr in range(40):
        a = cells.get((59, rr)); b = cells.get((0, rr))
        if a is not None and b is not None:
            seam.append(abs(f(a, k) - f(b, k)))
        for c in range(59):
            a = cells.get((c, rr)); b = cells.get((c + 1, rr))
            if a is not None and b is not None:
                interior.append(abs(f(a, k) - f(b, k)))
    ms = sum(seam) / len(seam)
    mi = sum(interior) / len(interior)
    print('%-26s | %.4f | %.4f | %.1fx' % (k, ms, mi, ms / mi if mi > 1e-9 else float('inf')))

# 只在水 cell 对上看洋流/psi
print()
print('water-only seam pairs (rows where both col59 & col0 are water):')
for k in ['ocean_psi_arr', 'ocean_current_x_arr', 'ocean_current_y_arr', 'slp_arr', 'temp_arr']:
    seam, interior = [], []
    for rr in range(40):
        a = cells.get((59, rr)); b = cells.get((0, rr))
        if a is not None and b is not None and f(a, 'is_water_arr') > 0.5 and f(b, 'is_water_arr') > 0.5:
            seam.append(abs(f(a, k) - f(b, k)))
        for c in range(59):
            a = cells.get((c, rr)); b = cells.get((c + 1, rr))
            if a is not None and b is not None and f(a, 'is_water_arr') > 0.5 and f(b, 'is_water_arr') > 0.5:
                interior.append(abs(f(a, k) - f(b, k)))
    ms = sum(seam) / len(seam) if seam else 0.0
    mi = sum(interior) / len(interior) if interior else 0.0
    print('%-26s | seam %.4f (n=%d) | interior %.4f | %.1fx' % (k, ms, len(seam), mi, ms / mi if mi > 1e-9 else float('inf')))
