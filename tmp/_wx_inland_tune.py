"""内陆降水调参 sweep — 在 NEW 实机驱动场上用离线平流式 solver 试参数。
诊断已定位 (B) 类根因：内陆 vapor/cw 充足，但 base_frac 太低→trig 触发不出→内陆永旱。
目标：land_dry 49%→~25%、inland_wet% 3%→~18%，同时 perma_rain 守 <15%、jaccard 不回升。
"""
import numpy as np, time
from collections import deque
from _wx_advect_0621 import simulate_advect, metrics

NPZ = r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_wx_fields_new.npz'
z = np.load(NPZ, allow_pickle=True)
ND = int(z['ND']); NC = int(z['NC']); NB = z['NB']
px = z['px'].astype(np.float64); py = z['py'].astype(np.float64)
hex_size = float(z['hex_size'])
pxn = (px - px.min()) / max(px.max() - px.min(), 1e-9)
pyn = (py - py.min()) / max(py.max() - py.min(), 1e-9)
g = lambda k: np.nan_to_num(z['st_' + k].astype(np.float64))
terrain = z['st_terrain_arr'].astype(np.int64)
elev = g('elevation_arr'); base_m = g('moisture_arr'); veg = z['st_vegetation_arr'].astype(np.int64)
soil = g('soil_moisture_arr'); vita = g('vegetation_vitality_arr')
has_river = z['st_has_river_arr'].astype(np.int64); river_q30 = g('river_discharge_30d_arr')
sea_ice = g('sea_ice_frac_arr')
is_water = z['st_is_water_arr'] > 0.5
d = lambda k: np.nan_to_num(z['dy_' + k].astype(np.float64))
dy_temp = d('temp_arr'); dy_air = np.zeros_like(dy_temp); dy_TA = d('temperature_transport_anomaly_arr')
dy_wx = d('wind_x_arr'); dy_wy = d('wind_y_arr'); dy_wspd = d('wind_speed_arr')
init_vapor = d('weather_vapor_arr')[0].copy(); init_cw = d('weather_cloud_water_arr')[0].copy()
init_precip = d('weather_precip_arr')[0].copy()
advect_steps = 4

hop = np.full(NC, -1, dtype=int); dq = deque()
for c in range(NC):
    if is_water[c]:
        hop[c] = 0; dq.append(c)
while dq:
    c = dq.popleft()
    for k in range(6):
        nb = NB[c, k]
        if nb >= 0 and hop[nb] < 0:
            hop[nb] = hop[c] + 1; dq.append(nb)
land = ~is_water; inland = land & (hop >= 3)

K = dict(ocean_evap_gain=1.30, land_evap_gain=1.00, lake_evap_scale=0.45,
         advect_vapor=0.82, advect_cw=0.94, diffusion=0.05,
         cap_base=0.20, cap_temp=0.80, cap_elev=0.20,
         rh_cond=0.55, sup_w=1.00, cond_rate=0.45, lift_cond=0.80, conv_cond=1.00, rain_shadow=0.50,
         autoconv=0.12, base_frac=0.20, trig_lift=0.25, trig_conv=1.80, oro_precip_gain=0.10, instab_gain=0.30,
         ocean_keep=0.65, cw_reevap=0.06, precip_inertia=0.40,
         wet_terrain_damp=0.45, lake_precip_damp=0.55, soft_cap=0.18, softness=0.35,
         mlow_count=6, mlow_sigma=0.16, mlow_period=20.0, mlow_wind_amp=0.0, mlow_tang=1.00, mlow_inflow=0.60,
         world_seed=10086)
order = ['ocean_evap_gain', 'land_evap_gain', 'lake_evap_scale', 'advect_vapor', 'advect_cw', 'diffusion',
         'cap_base', 'cap_temp', 'cap_elev', 'rh_cond', 'sup_w', 'cond_rate', 'lift_cond', 'conv_cond', 'rain_shadow',
         'autoconv', 'base_frac', 'trig_lift', 'trig_conv', 'oro_precip_gain', 'instab_gain',
         'ocean_keep', 'cw_reevap', 'precip_inertia', 'wet_terrain_damp', 'lake_precip_damp', 'soft_cap', 'softness',
         'mlow_count', 'mlow_sigma', 'mlow_period', 'mlow_wind_amp', 'mlow_tang', 'mlow_inflow', 'world_seed']


def run(**ov):
    k = dict(K); k.update(ov); args = [k[n] for n in order]
    op = np.zeros((ND, NC)); oc = np.zeros((ND, NC)); ocl = np.zeros((ND, NC)); ovv = np.zeros((ND, NC))
    simulate_advect(ND, NC, NB, px, py, pxn, pyn, hex_size, advect_steps,
                    terrain, elev, base_m, veg, soil, vita, has_river, river_q30, sea_ice,
                    dy_temp, dy_air, dy_TA, dy_wx, dy_wy, dy_wspd,
                    init_vapor, init_cw, init_precip, *args, op, oc, ocl, ovv)
    return op, oc, ocl, ovv  # precip, cloud_water, cloud, vapor


warm = 40


def score(tag, res):
    op = res[0]
    m = metrics(op, px, py)
    wet = (op[warm:] > 0.02).mean(0)
    inl_wet = wet[inland].mean() * 100
    inl_pre = op[warm:][:, inland].mean()
    land_dry = (wet[land] < 0.05).mean()
    print(f'{tag:24s} perma_rain={m["perma_rain"]:.3f} land_dry={land_dry:.3f} jacc={m["jaccard"]:.3f} '
          f'mean_pre={m["mean_precip"]:.4f} | inland_wet%={inl_wet:4.1f} inland_pre={inl_pre:.4f}')
    return m


def layers(tag, P, V, C):
    print(f'-- {tag} 距海分层 (hop: precip / vapor / cw / wet%) --')
    for h in [0, 1, 2, 3, 4, 5]:
        msk = hop == h
        if msk.sum() < 3:
            continue
        pp = P[warm:][:, msk]; vv = V[warm:][:, msk]; cc = C[warm:][:, msk]
        print(f'   hop{h} n={int(msk.sum()):4d}  precip={pp.mean():.4f}  vapor={vv.mean():.3f}  '
              f'cw={cc.mean():.4f}  wet%={(pp > 0.02).mean() * 100:4.1f}')


ref = d('weather_precip_arr'); refv = d('weather_vapor_arr'); refc = d('weather_cloud_water_arr')
rwet = (ref[warm:] > 0.02).mean(0)
print(f'[实机NEW参考] perma_rain={metrics(ref, px, py)["perma_rain"]:.3f} '
      f'land_dry={(rwet[land] < 0.05).mean():.3f} inland_wet%={rwet[inland].mean() * 100:.1f}')
layers('实机NEW', ref, refv, refc)
print('=' * 96)
t0 = time.time()
b = run()
score('baseline(当前默认)', b)
layers('离线baseline', b[0], b[3], b[1])   # P=precip(b0) V=vapor(b3) C=cw(b1)
print('=' * 96)
score('base_frac=0.60', run(base_frac=0.60))
score('bf=0.55,autoconv=0.16', run(base_frac=0.55, autoconv=0.16))
score('bf=0.85,ac=0.18,cond=0.55', run(base_frac=0.85, autoconv=0.18, cond_rate=0.55))
print(f'[sweep done {time.time() - t0:.1f}s]')
