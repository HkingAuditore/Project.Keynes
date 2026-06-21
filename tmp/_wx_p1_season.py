"""P1 验证: 分暖/冷季的同纬度陆海温差(季节反转?)。
- 用每格 insolation_dev 自身分布的上/下 1/3 分暖/冷季(自动处理南北半球+赤道,不依赖绝对量纲)。
- 用 temp_baseline>0.3 掩码排除导出离群/截断天。
- 真大陆性(季节反转)判据: 暖季Δ(陆-海)>0(夏陆更热) 且 冷季Δ<0(冬陆更冷)。修复前为恒负。
"""
import numpy as np, sys, warnings
warnings.filterwarnings('ignore')
NPZ = sys.argv[1] if len(sys.argv) > 1 else r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_wx_fields_v8.npz'
z = np.load(NPZ, allow_pickle=True)
NC = int(z['NC']); ND = int(z['ND'])
py = z['py'].astype(float)
is_water = z['st_is_water_arr'] > 0.5
warm = 40
dy = lambda k: z['dy_' + k].astype(float)
temp = dy('temp_arr')[warm:]            # (T,NC) 最终温度
dev  = dy('insolation_dev_arr')[warm:]  # (T,NC) 当地季节强迫(暖>0/冷<0)
base = dy('temp_baseline_arr')[warm:]   # (T,NC) baseline,用于离群掩码
T = temp.shape[0]

good = (base > 0.3) & np.isfinite(temp) & np.isfinite(dev)   # 排除导出离群/截断天
devg = np.where(good, dev, np.nan)
dlo = np.nanpercentile(devg, 33, axis=0)
dhi = np.nanpercentile(devg, 67, axis=0)
warm_mask = good & (dev >= dhi[None, :])
cold_mask = good & (dev <= dlo[None, :])

def seas_mean(m):
    den = m.sum(0)
    num = np.where(m, temp, 0.0).sum(0)
    return np.where(den > 5, num / np.maximum(den, 1), np.nan)

warmT = seas_mean(warm_mask)
coldT = seas_mean(cold_mask)
annT  = seas_mean(good)
ny = (py - py.min()) / (py.max() - py.min() + 1e-9)

print(f'NPZ={NPZ.split("/")[-1]}  T={T}  good天占比={np.nanmean(good)*100:.1f}%  暖季样本/格中位={np.median(warm_mask.sum(0)):.0f}')
print('=== P1: 同纬度带 暖季/冷季 陆海温差 (季节反转?) ===')
print(f'{"ny带":>9}{"nL":>5}{"nS":>5}{"暖陆":>7}{"暖海":>7}{"暖Δ":>7}{"冷陆":>7}{"冷海":>7}{"冷Δ":>7}{"年Δ":>7} 反转')
nrev = 0; nband = 0
for b in range(10):
    lo, hi = b/10, (b+1)/10
    mb = (ny >= lo) & (ny < hi)
    L = mb & ~is_water; S = mb & is_water
    if L.sum() < 5 or S.sum() < 5:
        continue
    wL, wS = np.nanmean(warmT[L]), np.nanmean(warmT[S])
    cL, cS = np.nanmean(coldT[L]), np.nanmean(coldT[S])
    aL, aS = np.nanmean(annT[L]),  np.nanmean(annT[S])
    wd, cd, ad = wL - wS, cL - cS, aL - aS
    nband += 1
    rev = ''
    if wd > 0 and cd < 0:
        nrev += 1; rev = 'YES'
    print(f'{lo:.1f}-{hi:.1f}{L.sum():>5}{S.sum():>5}{wL:>7.3f}{wS:>7.3f}{wd:>+7.3f}{cL:>7.3f}{cS:>7.3f}{cd:>+7.3f}{ad:>+7.3f} {rev}')

L, S = ~is_water, is_water
wL, wS = np.nanmean(warmT[L]), np.nanmean(warmT[S])
cL, cS = np.nanmean(coldT[L]), np.nanmean(coldT[S])
aL, aS = np.nanmean(annT[L]),  np.nanmean(annT[S])
print(f'\n全局: 暖Δ(陆-海)={wL-wS:+.3f}  冷Δ(陆-海)={cL-cS:+.3f}  年Δ={aL-aS:+.3f}  季节反转带={nrev}/{nband}')
print('判读: 暖Δ>0且冷Δ<0=真大陆性(夏陆热/冬陆冷); 暖Δ仍<0=大陆性不足→调高 temp_land_continentality')
