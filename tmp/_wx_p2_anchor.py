"""P2 根因: 陆地雨带钉死被什么锚定?
- convergence 场时间自相关: 高=辐合带固定(雨带跟着固定不动)。
- precip(时间均值) vs elevation 相关: 高正=地形雨主导(地形不动→雨带不动,加风无效)。
- precip vs convergence(时间均值) 相关: 高=降水锚定在固定辐合区(加 synoptic 打散辐合有效)。
- 高wet vs 低wet 陆地格的 elev/conv 对比, 判断锚定来源。
"""
import numpy as np, sys
NPZ = sys.argv[1] if len(sys.argv) > 1 else r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_wx_fields_v8.npz'
z = np.load(NPZ, allow_pickle=True)
NC = int(z['NC']); ND = int(z['ND']); warm = 40
is_water = z['st_is_water_arr'] > 0.5; land = ~is_water
elev = z['st_elevation_arr'].astype(float)
d = lambda k: np.nan_to_num(z['dy_' + k].astype(float))
precip = d('weather_precip_arr')[warm:]; conv = d('weather_convergence_arr')[warm:]
T = precip.shape[0]
pm = precip.mean(0); cm = conv.mean(0); wet = (precip > 0.02).mean(0)


def scorr(a, b):
    am = a - a.mean(); bm = b - b.mean()
    den = np.sqrt((am * am).sum() * (bm * bm).sum())
    return (am * bm).sum() / den if den > 1e-9 else 0.0


print(f'NPZ={NPZ.split("/")[-1]} T={T} land={int(land.sum())}')
print('=== convergence 场时间自相关 (高=辐合带固定→雨带钉死) ===')
for lag in [7, 30, 60]:
    if lag >= T:
        break
    cs = [scorr(conv[t][land], conv[t + lag][land]) for t in range(0, T - lag, 3)]
    print(f'  conv lag={lag:>3}: {np.mean(cs):.3f}')

lm = land
print(f'\n陆地 precip(时间均值) ~ elevation 相关 = {np.corrcoef(pm[lm], elev[lm])[0, 1]:+.3f}  (高正=地形雨主导)')
print(f'陆地 precip(时间均值) ~ convergence(时间均值) 相关 = {np.corrcoef(pm[lm], cm[lm])[0, 1]:+.3f}  (高=锚定固定辐合)')
print(f'陆地 wet频率 ~ elevation 相关 = {np.corrcoef(wet[lm], elev[lm])[0, 1]:+.3f}')

thr = np.percentile(wet[lm], 80)
hi = lm & (wet >= thr)
lo = lm & (wet < 0.05)
print(f'\n高wet陆地格(top20% wet>={thr:.2f}, n={int(hi.sum())}): elev均={elev[hi].mean():.3f} conv均={cm[hi].mean():+.4f} precip均={pm[hi].mean():.4f}')
print(f'全陆地              (n={int(lm.sum())}): elev均={elev[lm].mean():.3f} conv均={cm[lm].mean():+.4f} precip均={pm[lm].mean():.4f}')
print(f'低wet陆地格(wet<5%  n={int(lo.sum())}): elev均={elev[lo].mean():.3f} conv均={cm[lo].mean():+.4f} precip均={pm[lo].mean():.4f}')
print('\n判读: conv自相关高+precip~conv高 → synoptic加强有效; precip~elev高 → 地形雨钉死,需机制改动')
