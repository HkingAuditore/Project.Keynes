"""定位 baseline<0.2 离群本质: 高纬/高山物理寒冷? 还是 bug(随机/全图跳0)?"""
import numpy as np
z = np.load(r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_wx_fields_v7.npz', allow_pickle=True)
is_water = z['st_is_water_arr'] > 0.5
py = z['py'].astype(float)
days = z['days'].astype(float)
elev = z['st_elevation_arr'].astype(float)
ny = (py - py.min()) / (py.max() - py.min() + 1e-9)
warm = 40
B = np.nan_to_num(z['dy_temp_baseline_arr'].astype(float))[warm:]
T = np.nan_to_num(z['dy_temp_arr'].astype(float))[warm:]
days_w = days[warm:]

# 排除末日(导出截断)
last = days_w.max()
keep = days_w < last
B2 = B[keep]
print(f'全部 baseline<0.2: {(B<0.2).mean()*100:.2f}%   排除末日(day={last:.0f})后: {(B2<0.2).mean()*100:.2f}%')

# 每 cell 的 low 频率
low_freq = (B2 < 0.2).mean(0)
always = low_freq > 0.8
often = (low_freq > 0.3) & (low_freq <= 0.8)
never = low_freq < 0.05
print(f'\ncell 分类(按 baseline<0.2 时间占比):')
print(f'  常年low(>80%): {always.mean()*100:.1f}%  ny[{ny[always].min() if always.any() else 0:.2f}-{ny[always].max() if always.any() else 0:.2f}] elev均={elev[always].mean() if always.any() else 0:.2f} 水占{is_water[always].mean()*100 if always.any() else 0:.0f}%')
print(f'  偶发low(30-80%): {often.mean()*100:.1f}%  ny[{ny[often].min() if often.any() else 0:.2f}-{ny[often].max() if often.any() else 0:.2f}] elev均={elev[often].mean() if often.any() else 0:.2f} 水占{is_water[often].mean()*100 if often.any() else 0:.0f}%')
print(f'  几乎不low(<5%): {never.mean()*100:.1f}%')

# 偶发low是否对应"最终temp也低"(真低温) 还是"仅baseline低,temp正常"(bug:baseline没更新)
if often.any():
    oc = np.where(often)[0]
    lowdays = B2[:, oc] < 0.2
    # 这些cell在low时,最终temp均值
    t_when_low = T[keep][:, oc][lowdays].mean() if lowdays.any() else np.nan
    t_when_hi = T[keep][:, oc][~lowdays].mean() if (~lowdays).any() else np.nan
    print(f'\n偶发low cell: baseline<0.2 时最终temp均={t_when_low:.3f}; baseline>=0.2 时最终temp均={t_when_hi:.3f}')
    print(f'  (若两者接近→baseline跳0但temp正常=显示/dirty bug; 若low时temp也低→真实寒潮)')

# 看一个偶发low cell 的 baseline 时间序列(是否突跳)
if often.any():
    c = oc[np.argmax(low_freq[oc])]
    bs = B2[:, c]
    print(f'\n样本cell={c} ny={ny[c]:.2f} elev={elev[c]:.2f}: baseline min={bs.min():.3f} max={bs.max():.3f} p50={np.median(bs):.3f}')
    print(f'  <0.2占{(bs<0.2).mean()*100:.0f}%, 序列突跳次数(相邻|Δ|>0.3)={int((np.abs(np.diff(bs))>0.3).sum())}')
