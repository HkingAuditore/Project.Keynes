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

FIELDS = ['snow_cover_arr', 'weather_vapor_arr', 'weather_cloud_arr', 'sea_ice_frac_arr',
          'temp_anomaly_arr', 'air_mass_temp_anomaly_arr', 'local_thermal_anomaly_arr',
          'ocean_thermal_anomaly_arr', 'weather_convergence_arr', 'weather_instability_arr',
          'weather_classification_temp_arr', 'weather_classification_moisture_arr',
          'insolation_now_arr', 'insolation_dev_arr', 'temp_season_offset_arr',
          'weather_intensity_arr', 'temp_arr', 'weather_type_arr', 'terrain_arr', 'landform_arr']
print('field | seam_jump(59,0) | interior_jump | ratio')
for k in FIELDS:
    seam, interior = [], []
    for rr in range(40):
        a = cells.get((59, rr)); b = cells.get((0, rr))
        seam.append(abs(f(a, k) - f(b, k)))
        for c in range(59):
            aa = cells.get((c, rr)); bb = cells.get((c + 1, rr))
            interior.append(abs(f(aa, k) - f(bb, k)))
    ms = sum(seam)/len(seam); mi = sum(interior)/len(interior)
    print('%-34s | %.4f | %.4f | %.1fx' % (k, ms, mi, ms/mi if mi > 1e-9 else float('inf')))

# 看 slp 输入项在接缝两行（row 0 全水，row 31 大部分水）的逐列值
print()
for rr in [0, 31]:
    print('=== row %d cols 57,58,59,0,1,2 ===' % rr)
    for c in [57, 58, 59, 0, 1, 2]:
        r = cells[(c, rr)]
        print('col %2d: snow=%.3f ice=%.3f vapor=%.3f cloud=%.3f temp_an=%.4f slp=%+.4f wvtype=%.0f terrain=%.0f' % (
            c, f(r,'snow_cover_arr'), f(r,'sea_ice_frac_arr'), f(r,'weather_vapor_arr'),
            f(r,'weather_cloud_arr'), f(r,'temp_anomaly_arr'), f(r,'slp_arr'),
            f(r,'weather_type_arr'), f(r,'terrain_arr')))
