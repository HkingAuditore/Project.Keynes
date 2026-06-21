"""用 CSV 真实的 temp_baseline_arr(ptb,纯热惯性baseline)彻底分离海洋大振幅来源:
  假设A: baseline 热惯性失效 → baseline 本身海洋振幅≥陆地
  假设B: 洋流/气团异常放大 → baseline 海洋振幅<陆地(OK),但 (temp-baseline) 海洋振幅大
另: baseline振幅/season_offset振幅 = 热惯性滤波比(海洋应<<1,陆地≈1)。
"""
import numpy as np
z = np.load(r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_wx_fields_v7.npz', allow_pickle=True)
is_water = z['st_is_water_arr'] > 0.5
py = z['py'].astype(float)
warm = 40
g = lambda k: np.nan_to_num(z['dy_' + k].astype(float))[warm:]
T = g('temp_arr')
B = g('temp_baseline_arr')        # ptb: 纯 baseline + 热惯性(pass_a 写)
SO = g('temp_season_offset_arr')  # 季节强迫(target 的季节项)
ANOM = T - B                       # ocean_thermal + air_mass + local anomaly 合计
ny = (py - py.min()) / (py.max() - py.min() + 1e-9)


def amp(X, m):
    return (X[:, m].max(0) - X[:, m].min(0)).mean()


print('=== temp_baseline(纯热惯性) vs 异常项(temp-baseline) 海陆振幅 ===')
print(f'  {"ny带":>9}{"base_L":>8}{"base_S":>8}{"海/陆":>6}{"soff_L":>8}{"soff_S":>8}{"anom_L":>8}{"anom_S":>8}')
for b in range(10):
    lo, hi = b / 10.0, (b + 1) / 10.0
    mb = (ny >= lo) & (ny < hi)
    ml = mb & (~is_water); ms = mb & is_water
    if ml.sum() < 5 or ms.sum() < 5:
        continue
    bl, bs = amp(B, ml), amp(B, ms)
    print(f'  {lo:.1f}-{hi:.1f}{bl:>8.3f}{bs:>8.3f}{bs/max(bl,1e-4):>6.2f}'
          f'{amp(SO,ml):>8.3f}{amp(SO,ms):>8.3f}{amp(ANOM,ml):>8.3f}{amp(ANOM,ms):>8.3f}')
L = ~is_water; S = is_water
print(f'\n  全局 baseline振幅: land={amp(B,L):.3f} sea={amp(B,S):.3f}  海/陆={amp(B,S)/max(amp(B,L),1e-4):.2f}')
print(f'  全局 异常(temp-base): land={amp(ANOM,L):.3f} sea={amp(ANOM,S):.3f}  海/陆={amp(ANOM,S)/max(amp(ANOM,L),1e-4):.2f}')
print(f'  热惯性滤波比(base振幅/soff振幅): land={amp(B,L)/max(amp(SO,L),1e-4):.2f} sea={amp(B,S)/max(amp(SO,S),1e-4):.2f}')
print(f'    (海洋若<<1=热惯性强力压制OK; 海洋若≈1=baseline完全跟随季节=热惯性失效)')
print(f'\n判定:')
rb = amp(B, S) / max(amp(B, L), 1e-4)
ra = amp(ANOM, S) / max(amp(ANOM, L), 1e-4)
print(f'  baseline海/陆={rb:.2f} {"→A:baseline热惯性失效" if rb>=0.9 else "→baseline OK(海<陆)"}')
print(f'  异常项海/陆={ra:.2f} {"→B:洋流/气团异常放大海洋" if ra>=1.2 else ""}')
