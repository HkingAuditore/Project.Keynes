import csv
import sys
import io
import numpy as np

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

W, H = 100, 64
INPUTS = ['temp_anomaly_arr', 'air_mass_temp_anomaly_arr', 'sea_ice_frac_arr', 'snow_cover_arr',
          'weather_vapor_arr', 'weather_cloud_arr', 'temp_arr', 'insolation_dev_arr', 'moisture_arr']

def load(path):
    rows = list(csv.DictReader(open(path, encoding='utf-8-sig')))
    data = {}
    for r in rows:
        q, rr = int(r['q']), int(r['r'])
        col = q + (rr - (rr & 1)) // 2
        for k in ['slp_arr'] + INPUTS:
            if k not in data:
                data[k] = np.zeros((H, W))
            data[k][rr, col] = float(r[k])
    return data

for path, tag in ((r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260803_112649.csv', '11:26 day70'),
                  (r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260803_123739.csv', '12:37 day154')):
    d = load(path)
    K = d['slp_arr'][:, 0] - d['slp_arr'][:, -1]
    print('=== %s ===  K_obs mean=%.4f' % (tag, K.mean()))
    for k in INPUTS:
        DK = d[k][:, 0] - d[k][:, -1]
        c = np.corrcoef(K, DK)[0, 1]
        print('  Δ(col0-col99) %-30s mean=%+.4f std=%.4f  corr(K,Δ)=%+.3f' % (k, DK.mean(), DK.std(), c))
    # 联合线性模型: K ≈ Σ w_i Δ_i
    A = np.stack([d[k][:, 0] - d[k][:, -1] for k in INPUTS] + [np.ones(H)], axis=1)
    coef, *_ = np.linalg.lstsq(A, K, rcond=None)
    resid = K - A @ coef
    print('  联合拟合残差 std=%.5f (K std=%.5f)' % (resid.std(), K.std()))
    for i, k in enumerate(INPUTS):
        if abs(coef[i]) > 0.005:
            print('    w[%s] = %+.4f' % (k, coef[i]))
    print()
