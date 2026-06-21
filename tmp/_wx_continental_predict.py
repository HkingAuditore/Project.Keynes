"""robust 预测(median+排除baseline<0.3离群): 测多个 continentality,定能让夏季陆>海反转的取值。"""
import numpy as np
z = np.load(r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_wx_fields_v7.npz', allow_pickle=True)
is_water = z['st_is_water_arr'] > 0.5
py = z['py'].astype(float)
ny = (py - py.min()) / (py.max() - py.min() + 1e-9)
warm = 40
g = lambda k: np.nan_to_num(z['dy_' + k].astype(float))[warm:]
SO = g('temp_season_offset_arr')
B = g('temp_baseline_arr')
DEV = g('insolation_dev_arr')
mid = (ny > 0.4) & (ny < 0.6)
land = np.where(mid & (~is_water))[0]
sea = np.where(mid & is_water)[0]


def season_med(cells, summer, cont, apply_land):
    vals = []
    for c in cells:
        bc = B[:, c]
        if apply_land:
            bc = bc + (cont - 1.0) * SO[:, c]
        msk = (DEV[:, c] > 0.05) if summer else (DEV[:, c] < -0.05)
        msk = msk & (B[:, c] > 0.3)   # 排除离群天
        if msk.any():
            vals.append(np.median(bc[msk]))
    return np.median(vals) if vals else np.nan


sea_s = season_med(sea, True, 1.0, False)
sea_w = season_med(sea, False, 1.0, False)
print(f'海洋(不变): 夏={sea_s:.3f} 冬={sea_w:.3f}')
print(f'{"cont":>5}{"陆夏":>8}{"陆冬":>8}{"夏(陆-海)":>10}{"冬(陆-海)":>10}{"判定":>14}')
for cont in [1.0, 1.55, 1.9, 2.2, 2.5]:
    ls = season_med(land, True, cont, True)
    lw = season_med(land, False, cont, True)
    ds, dw = ls - sea_s, lw - sea_w
    verdict = '夏陆>海 反转OK' if ds > 0.01 else ('接近' if ds > -0.02 else '陆仍偏冷')
    print(f'{cont:>5.2f}{ls:>8.3f}{lw:>8.3f}{ds:>+10.3f}{dw:>+10.3f}{verdict:>14}')
print('\n注: 真实地球中纬夏季陆>海约+0.05~0.10(温标);目标 cont 让夏(陆-海)转正且冬保持负。')
