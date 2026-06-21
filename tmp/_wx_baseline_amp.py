"""决定性验证: 控制纬度后, baseline(扣异常) 振幅的海陆比。
设计目标: 海洋 baseline 振幅 ≈ 陆地的 0.49×(热惯性压制)。
若同纬度海洋 baseline 振幅 ≈/> 陆地 → baseline 热惯性失效(加速 dt 放大 α)。
"""
import numpy as np
z = np.load(r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_wx_fields_v7.npz', allow_pickle=True)
is_water = z['st_is_water_arr'] > 0.5
py = z['py'].astype(float)
warm = 40
g = lambda k: np.nan_to_num(z['dy_' + k].astype(float))[warm:]
T = g('temp_arr'); A = g('air_mass_temp_anomaly_arr'); TT = g('temperature_transport_anomaly_arr')
B = T - A - TT   # ≈ baseline + local_anomaly(热惯性主导项)
bamp = B.max(0) - B.min(0)   # per-cell baseline 季节振幅
ny = (py - py.min()) / (py.max() - py.min() + 1e-9)
print('=== baseline(扣异常) 季节振幅 海陆比 (控制纬度) ===')
print(f'  {"ny带":>9}{"n_land":>7}{"n_sea":>6}{"land_amp":>9}{"sea_amp":>9}{"海/陆比":>8}  判定')
ratios = []
for b in range(10):
    lo, hi = b / 10.0, (b + 1) / 10.0
    mb = (ny >= lo) & (ny < hi)
    ml = mb & (~is_water); ms = mb & is_water
    if ml.sum() < 5 or ms.sum() < 5:
        continue
    la, sa = bamp[ml].mean(), bamp[ms].mean()
    ratio = sa / max(la, 1e-4)
    ratios.append(ratio)
    verdict = 'OK(海<陆)' if ratio < 0.65 else ('!!失效(海≈陆)' if ratio < 1.0 else '!!!反物理(海>陆)')
    print(f'  {lo:.1f}-{hi:.1f} {ml.sum():>7}{ms.sum():>6}{la:>9.3f}{sa:>9.3f}{ratio:>8.2f}  {verdict}')
print(f'\n  中纬(0.3-0.7)平均 海/陆 振幅比 = {np.mean([r for r in ratios]):.2f}  (设计应 ≈0.49; >1 = 热惯性完全失效)')
