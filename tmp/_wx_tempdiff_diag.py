"""问题1(陆海温差)+问题3(河流干燥)诊断。
温差关键:控制纬度看同纬度带 land vs sea 的①年均温差 ②季节振幅(大陆性)。
  真实地球:同纬度陆地夏热冬冷(振幅大)、海洋温和(振幅小)、年均陆≈海或略有差。
  若同纬度陆海温差≈0 且季节振幅陆≈海 → 缺大陆性/热惯性(问题1根因)。
河流:has_river 格 vs 普通陆地的 vapor/precip/wet%(为何河流也标干燥)。
"""
import numpy as np
from collections import deque
import sys
NPZ = sys.argv[1] if len(sys.argv) > 1 else r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_wx_fields_v7.npz'
z = np.load(NPZ, allow_pickle=True)
NC = int(z['NC']); ND = int(z['ND']); NB = z['NB']
py = z['py'].astype(float)
is_water = z['st_is_water_arr'] > 0.5
has_river = z['st_has_river_arr'] > 0.5
warm = 40
dy = lambda k: np.nan_to_num(z['dy_' + k].astype(float))
temp = dy('temp_arr')[warm:]
vapor = dy('weather_vapor_arr')[warm:].mean(0)
precip = dy('weather_precip_arr')[warm:].mean(0)
wet = (dy('weather_precip_arr')[warm:] > 0.02).mean(0)
tmean = temp.mean(0)
tamp = temp.max(0) - temp.min(0)   # 季节(全年)振幅
ny = (py - py.min()) / (py.max() - py.min() + 1e-9)

print(f'NPZ={NPZ.split("/")[-1]}  ND={ND}')
print('=== 问题1: 同纬度带 land vs sea (温差 + 季节振幅 amp) ===')
print(f'  {"ny带":>10}{"n_land":>7}{"n_sea":>6}{"land_T":>8}{"sea_T":>8}{"ΔT":>7}{"land_amp":>9}{"sea_amp":>8}')
for b in range(10):
    lo, hi = b / 10.0, (b + 1) / 10.0
    mb = (ny >= lo) & (ny < hi)
    ml = mb & (~is_water); ms = mb & is_water
    if ml.sum() < 5 or ms.sum() < 5:
        continue
    lt, st = tmean[ml].mean(), tmean[ms].mean()
    print(f'  {lo:.1f}-{hi:.1f}  {ml.sum():>7}{ms.sum():>6}{lt:>8.3f}{st:>8.3f}{lt-st:>7.3f}'
          f'{tamp[ml].mean():>9.3f}{tamp[ms].mean():>8.3f}')
# 全局陆海
ml = ~is_water; ms = is_water
print(f'\n  全局: land_T={tmean[ml].mean():.3f} sea_T={tmean[ms].mean():.3f} ΔT={tmean[ml].mean()-tmean[ms].mean():.3f}'
      f'  | 季节振幅 land={tamp[ml].mean():.3f} sea={tamp[ms].mean():.3f} (陆/海比={tamp[ml].mean()/max(tamp[ms].mean(),1e-4):.2f})')

print('\n=== 问题3: 河流格 vs 普通陆地 (是否河流也干燥) ===')
river = has_river & (~is_water)
noriver = (~has_river) & (~is_water)
for label, m in [('有河流陆地', river), ('无河流陆地', noriver)]:
    if m.sum() < 3:
        continue
    print(f'  {label}: n={m.sum():>5} vapor={vapor[m].mean():.3f} precip={precip[m].mean():.4f} '
          f'wet%={wet[m].mean()*100:.1f} temp={tmean[m].mean():.3f}')
print(f'  河流格 wet%>0.02 占比={ (wet[river] > 0.02).mean()*100 if river.any() else 0:.1f}%  '
      f'河流格几乎全年无雨(wet<0.02)占比={ (wet[river] < 0.02).mean()*100 if river.any() else 0:.1f}%')
