"""分解温度各分量的海陆季节振幅，定位海洋大振幅来源(baseline热惯性失效? 还是异常项放大?)。
温度链(component_ids): cell_temp = baseline(有热惯性α) + ocean_thermal_anom + local_anom + air_mass_anom
CSV 可见: temp(最终), air_mass_temp_anomaly, temperature_transport_anomaly, temp_anomaly。
"""
import numpy as np
z = np.load(r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_wx_fields_v7.npz', allow_pickle=True)
is_water = z['st_is_water_arr'] > 0.5
warm = 40
g = lambda k: np.nan_to_num(z['dy_' + k].astype(float))[warm:]
T = g('temp_arr')
A = g('air_mass_temp_anomaly_arr')
TT = g('temperature_transport_anomaly_arr')


def amp(X, m):
    return (X[:, m].max(0) - X[:, m].min(0)).mean()


def absm(X, m):
    return np.abs(X[:, m]).mean()


L = ~is_water
S = is_water
print('=== 温度分量「海陆季节振幅」(per-cell 全年 max-min 再平均) ===')
print(f'  最终 temp:                land={amp(T,L):.3f}  sea={amp(T,S):.3f}  (sea>land 即反物理)')
print(f'  air_mass_temp_anomaly:    land={amp(A,L):.3f}  sea={amp(A,S):.3f}')
print(f'  temperature_transport:    land={amp(TT,L):.3f}  sea={amp(TT,S):.3f}')
print(f'  temp 扣掉两异常(≈baseline): land={amp(T-A-TT,L):.3f}  sea={amp(T-A-TT,S):.3f}  <== 看 baseline 热惯性是否生效')
print('\n=== 各异常分量幅度(海洋) ===')
print(f'  air_mass_anom  |mean|: sea={absm(A,S):.4f}  land={absm(A,L):.4f}')
print(f'  transport_anom |mean|: sea={absm(TT,S):.4f}  land={absm(TT,L):.4f}')
print(f'\n判定: 若"扣异常后"sea振幅<<land → baseline热惯性其实生效，是异常项把海洋摆幅顶上去；')
print(f'      若"扣异常后"sea振幅仍≈/>land → baseline本身热惯性失效(thermal_dt放大α 或 absorbed_factor)')
