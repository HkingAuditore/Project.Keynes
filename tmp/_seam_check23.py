import csv
import numpy as np

SEED = 147556379
W, H = 100, 64
AMP = 0.18
LOW_AMP = 0.16
SIG = 0.16
INV2S2 = 1.0 / (2.0 * SIG ** 2)

FIELDS = ['slp_arr', 'terrain_arr', 'temp_anomaly_arr', 'sea_ice_frac_arr',
          'weather_vapor_arr', 'weather_cloud_arr', 'ocean_psi_arr']

def load(path):
    rows = list(csv.DictReader(open(path, encoding='utf-8')))
    data = {k: np.zeros((H, W)) for k in FIELDS}
    for r in rows:
        q, rr = int(r['q']), int(r['r'])
        col = q + (rr - (rr & 1)) // 2
        for k in FIELDS:
            try:
                data[k][rr, col] = float(r[k])
            except Exception:
                pass
    return data

d70 = load(r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260803_112649.csv')
d154 = load(r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260803_123739.csv')

row, col = np.mgrid[0:H, 0:W]
POSX = np.sqrt(3.0) * (col + 0.5 * (row & 1))
BOUNDS_X, BOUNDS_W = -2.0, np.sqrt(3.0) * 100.5 + 4.0
px_clamp = np.clip((POSX - BOUNDS_X) / BOUNDS_W, 0.0, 1.0)
px_wrap = (POSX / (np.sqrt(3.0) * W)) % 1.0
py_ = (1.5 * row + 2.0) / 100.5
ls = 1.0 - 2.0 * py_
ls_abs = np.abs(ls)

sa = SEED * 0.00011
sb = SEED * 0.00017
k1x_old = 0.90 + 0.40 * np.sin(sa)
k2x_old = 1.10 - 0.35 * np.cos(sb)
k1y = 0.70 + 0.40 * np.cos(sa)
k2y = 0.85 + 0.35 * np.sin(sb)
k1x_new = 1.0 + (SEED & 1)
k2x_new = 1.0 + ((SEED >> 1) & 1)

def syn_old(day):
    ph1 = day * 2 * np.pi / 6.0
    ph2 = ph1 * 0.66
    return (0.65 * np.sin(2*np.pi*(k1x_old*px_clamp + k1y*py_) + ph1 + ls*0.6)
            + 0.35 * np.cos(2*np.pi*(k2x_old*px_clamp - k2y*py_) - ph2 + ls_abs*0.9))

def syn_new(day):
    ph1 = day * 2 * np.pi / 6.0
    ph2 = ph1 * 0.66
    return (0.65 * np.sin(2*np.pi*(k1x_new*px_wrap + k1y*py_) + ph1 + ls*0.6 + sa)
            + 0.35 * np.cos(2*np.pi*(k2x_new*px_wrap - k2y*py_) - ph2 + ls_abs*0.9 + sb))

def lows(day):
    out = np.zeros((H, W))
    for j in range(5):
        h = (SEED * 2654435761 + j * 40503 + 1013904223) & 0xFFFFFFFF
        h ^= h >> 16; h = (h * 2246822519) & 0xFFFFFFFF; h ^= h >> 13
        hx = (h & 0xFFFF) / 65535.0
        hy = ((h >> 16) & 0xFFFF) / 65535.0
        cx = (hx + day / 16.0) % 1.0
        cy = 0.22 + 0.56 * hy + 0.05 * np.sin(day * 0.045 + j * 1.7)
        cy = min(max(cy, 0.04), 0.96)
        dx = px_wrap - cx
        dx = np.where(dx > 0.5, dx - 1.0, np.where(dx < -0.5, dx + 1.0, dx))
        out += -np.exp(-(dx * dx + (py_ - cy) ** 2) * INV2S2)
    return out

# water 判定：用 ocean_psi 非零的 terrain 集合
psi = d154['ocean_psi_arr']
terr = d154['terrain_arr'].astype(int)
water_ids = set()
for t in np.unique(terr):
    m = terr == t
    if np.median(np.abs(psi[m])) > 1e-6 or np.abs(psi[m]).mean() > 0.01:
        water_ids.add(int(t))
print('water terrain ids (by psi):', sorted(water_ids))
water = np.isin(terr, list(water_ids))

# coast: 陆地格有任一水邻居（用 hex 奇偶偏移邻居，东西包裹）
def neighbors(rr, cc):
    if rr & 1:
        offs = [(0, -1), (0, 1), (-1, 0), (-1, 1), (1, 0), (1, 1)]
    else:
        offs = [(0, -1), (0, 1), (-1, -1), (-1, 0), (1, -1), (1, 0)]
    for dr, dc in offs:
        nr, nc = rr + dr, (cc + dc) % W
        if 0 <= nr < H:
            yield nr, nc

coast = np.zeros((H, W), bool)
for rr in range(H):
    for cc in range(W):
        if water[rr, cc]:
            continue
        if any(water[nr, nc] for nr, nc in neighbors(rr, cc)):
            coast[rr, cc] = True

# 半整数候选：k=0.5 正交对
ramp_c = np.cos(np.pi * px_wrap)
ramp_s = np.sin(np.pi * px_wrap)

def decompose(obs, day, tag):
    landsea_cls = np.where(water, 1.0, np.where(coast, 2.0, 3.0))  # 1=water 2=coast 3=interior
    # 每行拟合: obs ≈ a*syn_new + b*syn_old + c*lows + d*ramp_c + e*ramp_s + 类别哑变量 + g*thermal + h*moist + i*ice
    sn, so, lo = syn_new(day), syn_old(day), lows(day)
    thermal = d154['temp_anomaly_arr'] * np.where(water, 0.55, 1.0)
    moist = d154['weather_vapor_arr'] * 0.65 + d154['weather_cloud_arr'] * 0.35
    ice = d154['sea_ice_frac_arr']
    dc_water = (landsea_cls == 1).astype(float)
    dc_coast = (landsea_cls == 2).astype(float)
    dc_int = (landsea_cls == 3).astype(float)
    ramps_c, ramps_s, ks = [], [], []
    resid_seam = []
    for rr in range(H):
        A = np.stack([sn[rr], so[rr], lo[rr], ramp_c[rr], ramp_s[rr],
                      dc_water[rr], dc_coast[rr], dc_int[rr],
                      thermal[rr], moist[rr], ice[rr], np.ones(W)], axis=1)
        coef, *_ = np.linalg.lstsq(A, obs[rr], rcond=None)
        pred = A @ coef
        resid = obs[rr] - pred
        ramps_c.append(coef[3]); ramps_s.append(coef[4])
        ks.append(resid[0] - resid[-1])
        resid_seam.append(np.abs(resid[0] - resid[-1]))
    ramps_c = np.array(ramps_c); ramps_s = np.array(ramps_s)
    amp = np.sqrt(ramps_c ** 2 + ramps_s ** 2)
    print()
    print('=== %s (day %d) ===' % (tag, day))
    print('k=0.5 ramp amplitude per row: mean=%.4f median=%.4f max=%.4f' % (amp.mean(), np.median(amp), amp.max()))
    print('ramp phase spread: cos mean=%.4f sin mean=%.4f' % (ramps_c.mean(), ramps_s.mean()))
    print('residual seam step after removing all terms: mean=%.4f max=%.4f' % (np.mean(ks), np.max(np.abs(ks))))
    return ramps_c, ramps_s

rc70, rs70 = decompose(d70['slp_arr'], 70.0, '11:26 day70')
rc154, rs154 = decompose(d154['slp_arr'], 154.0, '12:37 day154')
print()
print('ramp coef means: day70 (%.4f, %.4f) day154 (%.4f, %.4f)' % (rc70.mean(), rs70.mean(), rc154.mean(), rs154.mean()))
