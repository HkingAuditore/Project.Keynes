"""重算 rh / convective(热力对流) / 各凝结项贡献,定位'遍地雾+小雨'真凶。
镜像 world_ext.cpp: vapor_capacity=clamp(0.18+0.82*temp-0.18*elev,0.14,1);
rh=vapor/vcap; convective=smoothstep(0.45,0.72,temp)*clamp(rh*5,0,1) (仅陆地);
sup=max(rh-0.55,0); cond_force=sup*static_cond_w(1) + ... + convective*thermal_conv_cond(1.9)。
"""
import numpy as np, sys
NPZ = sys.argv[1] if len(sys.argv) > 1 else r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_wx_fields_v14.npz'
z = np.load(NPZ, allow_pickle=True)
NC = int(z['NC']); ND = int(z['ND']); warm = 40 if ND >= 80 else max(2, ND // 4)
is_water = z['st_is_water_arr'] > 0.5; land = ~is_water
dy = lambda k: np.nan_to_num(z['dy_' + k].astype(float))[warm:]
vapor = dy('weather_vapor_arr'); temp = dy('temp_arr')
conv = dy('weather_convergence_arr'); precip = dy('weather_precip_arr')
cw = dy('weather_cloud_water_arr'); cloud = dy('weather_cloud_arr')
elev = np.nan_to_num(z['st_elevation_arr'].astype(float))
T = vapor.shape[0]; L = land
print(f'NPZ={NPZ.split(chr(92))[-1]} T={T} land={int(land.sum())}')
print(f'  temp  range={temp.min():.3f}..{temp.max():.3f} 陆地中位={np.median(temp[:,L]):.3f}')
print(f'  elev  range={elev.min():.3f}..{elev.max():.3f} 陆地中位={np.median(elev[L]):.3f}')
print(f'  vapor 陆地中位={np.median(vapor[:,L]):.4f}')

def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)

vcap = np.clip(0.18 + 0.82 * temp - 0.18 * elev[None, :], 0.14, 1.0)
rh = vapor / np.maximum(vcap, 0.001)
convective = np.where(is_water[None, :], 0.0, smoothstep(0.45, 0.72, temp) * np.clip(rh * 5.0, 0, 1))
sup = np.maximum(rh - 0.55, 0.0)

print('\n=== [1] 陆地 rh 分布 (静力凝结 sup=rh-0.55 是否触发) ===')
rl = rh[:, L]
print(f'  rh p10/25/50/75/90 = {np.percentile(rl,10):.3f}/{np.percentile(rl,25):.3f}/{np.percentile(rl,50):.3f}/{np.percentile(rl,75):.3f}/{np.percentile(rl,90):.3f}')
print(f'  rh>0.55 占比(静力凝结能触发) = {(rl>0.55).mean()*100:.1f}%   => 若≈0,静力凝结=死,static_cond_w/rh_condense 改了无效')

print('\n=== [2] 陆地 convective(热力对流) 分布 ===')
cl = convective[:, L]
print(f'  convective p10/25/50/75/90 = {np.percentile(cl,10):.3f}/{np.percentile(cl,25):.3f}/{np.percentile(cl,50):.3f}/{np.percentile(cl,75):.3f}/{np.percentile(cl,90):.3f}')
print(f'  >0.05={ (cl>0.05).mean()*100:.1f}%  >0.2={(cl>0.2).mean()*100:.1f}%  >0.35={(cl>0.35).mean()*100:.1f}%  >0.5={(cl>0.5).mean()*100:.1f}%')

print('\n=== [3] cond_force 各项贡献(陆地均值;谁产云水) ===')
st = (sup * 1.0)[:, L].mean()
cv = (convective * 1.9)[:, L].mean()
cg = (conv * 0.5)[:, L].mean()  # conv_cond_gain 估值,仅看量级
tot = st + cv + cg
print(f'  静力 sup*1.0          = {st:.4f}  ({st/max(tot,1e-9)*100:.0f}%)')
print(f'  对流 convective*1.9   = {cv:.4f}  ({cv/max(tot,1e-9)*100:.0f}%)  <- 若占绝大多数=真凶')
print(f'  辐合 convergence*~0.5 = {cg:.4f}  ({cg/max(tot,1e-9)*100:.0f}%)')

print('\n=== [4] 降水格(precip>0.02)的 convective 分布 ===')
rain_mask = precip[:, L] > 0.02
cl_rain = convective[:, L][rain_mask]
if cl_rain.size > 0:
    print(f'  雨格 convective p10/50/90 = {np.percentile(cl_rain,10):.3f}/{np.percentile(cl_rain,50):.3f}/{np.percentile(cl_rain,90):.3f}')
    print(f'  雨格中 convective<0.35 占比(弱对流小雨) = {(cl_rain<0.35).mean()*100:.1f}%')

print('\n=== [5] 若 convective<阈值则归零, 损失降水量占比(评估副作用) ===')
pL = precip[:, L]; tot_p = pL[pL > 0.02].sum()
for thr in [0.15, 0.2, 0.25, 0.3, 0.35, 0.4]:
    killed = (convective[:, L] < thr) & (pL > 0.02)
    print(f'  阈值 {thr}: 被砍雨格占陆地降水量 {pL[killed].sum()/max(tot_p,1e-9)*100:5.1f}%  (砍掉的格数占雨格 {killed.sum()/max((pL>0.02).sum(),1)*100:.1f}%)')
