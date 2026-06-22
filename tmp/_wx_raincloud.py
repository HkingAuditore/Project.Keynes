"""诊断'雨云驱动'缺失:降水弥漫(大面积小雨)+停滞(海上永雨不动)。
真实降水=移动的雨云(生成/运动/消减),空间集中、时间有周期、雨过转晴。
"""
import numpy as np, sys
NPZ = sys.argv[1] if len(sys.argv) > 1 else r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_wx_fields_v13.npz'
z = np.load(NPZ, allow_pickle=True)
NC = int(z['NC']); ND = int(z['ND']); warm = 40 if ND >= 80 else max(2, ND // 4)
is_water = z['st_is_water_arr'] > 0.5; land = ~is_water
px = z['px']; py = z['py']
dy = lambda k: np.nan_to_num(z['dy_' + k].astype(float))[warm:]
precip = dy('weather_precip_arr'); cloud = dy('weather_cloud_arr')
vapor = dy('weather_vapor_arr'); wt = dy('weather_type_arr').astype(int)
T = precip.shape[0]
print(f'NPZ={NPZ.split(chr(92))[-1]} T={T} water={int(is_water.sum())} land={int(land.sum())}')

def autocorr(a2d, mask, lag):
    a = a2d[:, mask]
    if T <= lag: return float('nan')
    x = a[:-lag]; y = a[lag:]
    xs = x.std(0); ys = y.std(0)
    valid = (xs > 1e-6) & (ys > 1e-6)
    if valid.sum() == 0: return float('nan')
    cov = ((x - x.mean(0)) * (y - y.mean(0))).mean(0)
    r = cov / (xs * ys + 1e-12)
    return float(np.nanmean(r[valid]))

print('\n=== [1] precip时间自相关(停滞度;1=永远不变,0=每天换) ===')
for nm, mask in [('海洋', is_water), ('陆地', land)]:
    print(f'  {nm}: lag1={autocorr(precip,mask,1):.3f} lag7={autocorr(precip,mask,7):.3f} lag30={autocorr(precip,mask,30):.3f}')

print('\n=== [2] 永雨/永晴区(precip>0.02的时间占比) ===')
for nm, mask in [('海洋', is_water), ('陆地', land)]:
    frac = (precip[:, mask] > 0.02).mean(0)
    print(f'  {nm}: 永雨格(雨日>80%)={(frac>0.8).mean()*100:5.1f}%  永晴格(雨日<5%)={(frac<0.05).mean()*100:5.1f}%  中位雨日比={np.median(frac)*100:.1f}%')

print('\n=== [3] 弥漫 vs 集中(空间;弱降水占比高+强降水占比低=大面积小雨) ===')
for nm, mask in [('海洋', is_water), ('陆地', land)]:
    p = precip[:, mask]
    print(f'  {nm}: precip>0.005={ (p>0.005).mean()*100:5.1f}% >0.02={(p>0.02).mean()*100:5.1f}% >0.05={(p>0.05).mean()*100:4.1f}% >0.08={(p>0.08).mean()*100:4.1f}%')

print('\n=== [4] 雨区移动性(precip加权质心日位移;越大越会动,~0=钉死) ===')
for nm, mask in [('海洋', is_water), ('陆地', land)]:
    idx = np.where(mask)[0]; pxm = px[idx]; pym = py[idx]; p = precip[:, mask]
    cx = np.zeros(T); cy = np.zeros(T)
    for t in range(T):
        w = p[t]; s = w.sum()
        if s > 1e-6: cx[t] = (w * pxm).sum() / s; cy[t] = (w * pym).sum() / s
    d = np.sqrt(np.diff(cx) ** 2 + np.diff(cy) ** 2)
    spacing = float(z['d_nb'])
    print(f'  {nm}: 质心日位移 中位={np.median(d):.4f} 均值={d.mean():.4f} (格距={spacing:.3f},即≈{d.mean()/spacing:.2f}格/天)')

print('\n=== [5] 单格"一次降水事件"持续天数(雨过该转晴;过长=停滞永雨) ===')
for nm, mask in [('海洋', is_water), ('陆地', land)]:
    p = precip[:, mask] > 0.02  # (T,M) bool
    runs = []
    for j in range(p.shape[1]):
        col = p[:, j]; c = 0
        for v in col:
            if v: c += 1
            elif c > 0: runs.append(c); c = 0
        if c > 0: runs.append(c)
    if runs:
        runs = np.array(runs)
        print(f'  {nm}: 连续降水段 中位={np.median(runs):.0f}天 p90={np.percentile(runs,90):.0f}天 最长={runs.max()}天 (现实雨团应几天内消减)')
