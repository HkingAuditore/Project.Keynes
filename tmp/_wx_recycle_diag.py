"""内陆水循环链诊断：按 hop(到海距离)分层，追踪 温度→vapor容量→相对湿度→凝结(cloud_water)→降水
每一环节，定位"内陆无雨"的真正瓶颈。
  rh = vapor / vapor_capacity，capacity = clip(0.18+0.82*temp-0.18*elev, 0.14, 1)  (镜像 world_ext 4163/4287)
  凝结需 rh>rh_condense(0.55) 或 lift 或 convergence；内陆三者皆缺则 cw≈0 → 无雨。
"""
import numpy as np
from collections import deque
import sys

NPZ = sys.argv[1] if len(sys.argv) > 1 else r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_wx_fields_v6.npz'
z = np.load(NPZ, allow_pickle=True)
NC = int(z['NC']); ND = int(z['ND']); NB = z['NB']
is_water = z['st_is_water_arr'] > 0.5
warm = 40
dy = lambda k: np.nan_to_num(z['dy_' + k].astype(float))
st = lambda k: np.nan_to_num(z['st_' + k].astype(float))
temp = dy('temp_arr')[warm:].mean(0)
vapor = dy('weather_vapor_arr')[warm:].mean(0)
cw = dy('weather_cloud_water_arr')[warm:].mean(0)
precip = dy('weather_precip_arr')[warm:].mean(0)
conv = dy('weather_convergence_arr')[warm:].mean(0)
wet = (dy('weather_precip_arr')[warm:] > 0.02).mean(0)
elev = st('elevation_arr'); soil = st('soil_moisture_arr')
base_m = st('moisture_arr'); has_river = st('has_river_arr'); veg = st('vegetation_arr')

cap = np.clip(0.18 + 0.82 * temp - 0.18 * elev, 0.14, 1.0)
rh = vapor / np.clip(cap, 0.001, None)
RH_CONDENSE = 0.55

hop = np.full(NC, -1, int); dq = deque()
for c in range(NC):
    if is_water[c]:
        hop[c] = 0; dq.append(c)
while dq:
    c = dq.popleft()
    for k in range(6):
        nb = NB[c, k]
        if nb >= 0 and hop[nb] < 0:
            hop[nb] = hop[c] + 1; dq.append(nb)

print(f'NPZ={NPZ.split("/")[-1]}  ND={ND}  (rh_condense={RH_CONDENSE})')
print(f'  {"hop":>4}{"n":>6}{"temp":>7}{"vapor":>7}{"cap":>7}{"rh":>7}{"rh>thr%":>8}'
      f'{"cw":>7}{"conv":>7}{"soil":>7}{"precip":>8}{"wet%":>6}')
for h in range(0, 8):
    m = (hop == h)
    if m.sum() < 3:
        continue
    rh_ok = (rh[m] > RH_CONDENSE).mean() * 100
    tag = 'SEA' if h == 0 else f' {h} '
    print(f'  {tag:>4}{m.sum():>6}{temp[m].mean():>7.3f}{vapor[m].mean():>7.3f}'
          f'{cap[m].mean():>7.3f}{rh[m].mean():>7.3f}{rh_ok:>7.0f}%'
          f'{cw[m].mean():>7.3f}{conv[m].mean():>7.3f}{soil[m].mean():>7.3f}'
          f'{precip[m].mean():>8.4f}{wet[m].mean()*100:>5.0f}%')

# 瓶颈判定：内陆(hop>=3)有 vapor 但 cw≈0 且 rh<<阈 → 凝结瓶颈(缺热力对流)
inl = (hop >= 3) & (~is_water)
print(f'\n[内陆 hop>=3] vapor={vapor[inl].mean():.3f} cw={cw[inl].mean():.4f} '
      f'rh={rh[inl].mean():.3f} (阈{RH_CONDENSE}) conv={conv[inl].mean():.3f} '
      f'rh达标占比={ (rh[inl]>RH_CONDENSE).mean()*100:.1f}%')
print(f'  → vapor/cw 比 = {vapor[inl].mean()/max(cw[inl].mean(),1e-4):.1f}  '
      f'(比值大=有水汽但凝结不出云水=凝结瓶颈; 小=本就没水汽=蒸散瓶颈)')
