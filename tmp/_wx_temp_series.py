"""中纬海陆各取1格,看 baseline/season_offset/dev/365d/temp 时间序列,搞清 baseline 大振幅来源。"""
import numpy as np
z = np.load(r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_wx_fields_v7.npz', allow_pickle=True)
is_water = z['st_is_water_arr'] > 0.5
py = z['py'].astype(float)
days = z['days'].astype(float)
ny = (py - py.min()) / (py.max() - py.min() + 1e-9)
warm = 40
g = lambda k: np.nan_to_num(z['dy_' + k].astype(float))
B = g('temp_baseline_arr'); SO = g('temp_season_offset_arr'); DEV = g('insolation_dev_arr')
T = g('temp_arr'); Y = g('temp_365d_arr')
mid = (ny > 0.47) & (ny < 0.53)
bamp = B[warm:].max(0) - B[warm:].min(0)
sea_cells = np.where(mid & is_water)[0]
land_cells = np.where(mid & (~is_water))[0]
sc = sea_cells[np.argmax(bamp[sea_cells])]
lc = land_cells[np.argmax(bamp[land_cells])]
print(f'SEA  cell={sc} ny={ny[sc]:.2f}   LAND cell={lc} ny={ny[lc]:.2f}')
print(f'{"day":>5} | {"S.dev":>6}{"S.soff":>7}{"S.base":>7}{"S.365d":>7}{"S.temp":>7} | {"L.dev":>6}{"L.soff":>7}{"L.base":>7}{"L.365d":>7}{"L.temp":>7}')
for t in range(warm, len(days), 14):
    print(f'{days[t]:>5.0f} | {DEV[t,sc]:>6.2f}{SO[t,sc]:>7.3f}{B[t,sc]:>7.3f}{Y[t,sc]:>7.3f}{T[t,sc]:>7.3f} | '
          f'{DEV[t,lc]:>6.2f}{SO[t,lc]:>7.3f}{B[t,lc]:>7.3f}{Y[t,lc]:>7.3f}{T[t,lc]:>7.3f}')
print(f'\n振幅(全年max-min): SEA base={B[warm:,sc].max()-B[warm:,sc].min():.3f} soff={SO[warm:,sc].max()-SO[warm:,sc].min():.3f} '
      f'365d={Y[warm:,sc].max()-Y[warm:,sc].min():.3f} | LAND base={B[warm:,lc].max()-B[warm:,lc].min():.3f} '
      f'soff={SO[warm:,lc].max()-SO[warm:,lc].min():.3f} 365d={Y[warm:,lc].max()-Y[warm:,lc].min():.3f}')
