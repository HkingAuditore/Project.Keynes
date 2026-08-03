import csv
import numpy as np

W, H = 100, 64
FIELDS = ['slp_arr', 'weather_vapor_arr', 'weather_cloud_arr']

def load(path):
    rows = list(csv.DictReader(open(path, encoding='utf-8')))
    data = {k: np.zeros((H, W)) for k in FIELDS}
    for r in rows:
        q, rr = int(r['q']), int(r['r'])
        col = q + (rr - (rr & 1)) // 2
        for k in FIELDS:
            data[k][rr, col] = float(r[k])
    return data

for path, tag, day in ((r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260803_112649.csv', '11:26', 70),
                       (r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260803_123739.csv', '12:37', 154)):
    d = load(path)
    slp, vap, cld = d['slp_arr'], d['weather_vapor_arr'], d['weather_cloud_arr']
    K_obs = slp[:, 0] - slp[:, -1]
    py_ = (1.5 * np.arange(H) + 2.0) / 100.5
    ls = 1.0 - 2.0 * py_
    w_lat = 0.45 + 0.55 * (1.0 - np.abs(ls))

    # 无位移: K_moist = -0.12*w*(0.65*dV + 0.35*dC), dV = vap(0)-vap(99)
    dV0 = vap[:, 0] - vap[:, -1]
    dC0 = cld[:, 0] - cld[:, -1]
    K_m0 = -0.12 * w_lat * (0.65 * dV0 + 0.35 * dC0)

    # +1 索引位移: used(i)=stored(i+1): used(0,r)=vap(r,1); used(99,r)=vap(r+1,0) (r=H-1 时绕到 row0)
    vap_p1 = np.roll(vap, -1, axis=0)   # vap_p1[r] = vap[r+1]
    cld_p1 = np.roll(cld, -1, axis=0)
    dVp1 = vap[:, 1] - vap_p1[:, 0]
    dCp1 = cld[:, 1] - cld_p1[:, 0]
    K_mp1 = -0.12 * w_lat * (0.65 * dVp1 + 0.35 * dCp1)

    # -1 索引位移: used(i)=stored(i-1): used(0,r)=vap(r-1,99); used(99,r)=vap(r,98)
    vap_m1 = np.roll(vap, 1, axis=0)
    cld_m1 = np.roll(cld, 1, axis=0)
    dVm1 = vap_m1[:, -1] - vap[:, 98 - 0]
    dCm1 = cld_m1[:, -1] - cld[:, 98 - 0]
    K_mm1 = -0.12 * w_lat * (0.65 * dVm1 + 0.35 * dCm1)

    print('=== %s (day %d) ===' % (tag, day))
    print('K_obs mean=%.4f std=%.4f' % (K_obs.mean(), K_obs.std()))
    for name, K in (('no-shift', K_m0), ('+1 shift', K_mp1), ('-1 shift', K_mm1)):
        c = np.corrcoef(K_obs, K)[0, 1]
        print('  %s: mean=%.4f std=%.4f corr=%.3f' % (name, K.mean(), K.std(), c))
    # 最佳线性组合 K_obs ≈ a*K_m0 + b
    A = np.stack([K_m0, np.ones(H)], axis=1)
    coef, *_ = np.linalg.lstsq(A, K_obs, rcond=None)
    print('  K_obs ≈ %.3f*K_m0 + %.4f (residual std %.4f)' % (coef[0], coef[1], (K_obs - A @ coef).std()))
    print()
