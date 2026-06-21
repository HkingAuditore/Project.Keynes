"""修正诊断: 用 robust 振幅(p95-p5)替代 max-min(被离群污染),重判海陆季节振幅。
并定位 baseline 跳0 的离群(哪些天/占比)。
"""
import numpy as np
z = np.load(r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_wx_fields_v7.npz', allow_pickle=True)
is_water = z['st_is_water_arr'] > 0.5
py = z['py'].astype(float)
days = z['days'].astype(float)
ny = (py - py.min()) / (py.max() - py.min() + 1e-9)
warm = 40
g = lambda k: np.nan_to_num(z['dy_' + k].astype(float))[warm:]
days_w = days[warm:]
T = g('temp_arr'); B = g('temp_baseline_arr')


def ramp(X, m):
    Xm = X[:, m]
    return (np.percentile(Xm, 95, axis=0) - np.percentile(Xm, 5, axis=0)).mean()


def mmamp(X, m):
    return (X[:, m].max(0) - X[:, m].min(0)).mean()


print('=== baseline 离群定位 ===')
print(f'  baseline<0.2 占全部 cell-day: {(B<0.2).mean()*100:.2f}%')
low_by_day = (B < 0.2).mean(1)
idx = np.argsort(low_by_day)[::-1][:6]
print('  baseline<0.2 占比最高的天:')
for i in idx:
    print(f'    day={days_w[i]:.0f}  low={low_by_day[i]*100:.1f}%  (前一记录day={days_w[i-1]:.0f}, dt={days_w[i]-days_w[i-1]:.0f})')

print('\n=== robust(p95-p5) vs max-min 海陆振幅 ===')
for lab, m in [('SEA ', is_water), ('LAND', ~is_water)]:
    print(f'  {lab}: temp robust={ramp(T,m):.3f} maxmin={mmamp(T,m):.3f} | base robust={ramp(B,m):.3f} maxmin={mmamp(B,m):.3f}')

print('\n=== 按纬度带 temp robust 振幅 海陆比 ===')
for b in range(2, 8):
    lo, hi = b / 10, (b + 1) / 10
    mb = (ny >= lo) & (ny < hi)
    ml = mb & (~is_water); ms = mb & is_water
    if ml.sum() < 5 or ms.sum() < 5:
        continue
    rl, rs = ramp(T, ml), ramp(T, ms)
    verdict = 'OK(海<陆)' if rs / max(rl, 1e-4) < 0.75 else '海≈/>陆'
    print(f'  {lo:.1f}-{hi:.1f} land={rl:.3f} sea={rs:.3f} 海/陆={rs/max(rl,1e-4):.2f}  {verdict}')

# 同时刻陆海温差(取中纬,看年均 + 季节摆动)
print('\n=== 同时刻陆海温差(中纬 0.4-0.6) ===')
mid = (ny > 0.4) & (ny < 0.6)
Tl = T[:, mid & (~is_water)].mean(1)
Ts = T[:, mid & is_water].mean(1)
diff = Tl - Ts
print(f'  陆-海 温差: mean={diff.mean():.3f} min={diff.min():.3f} max={diff.max():.3f} (真实应夏正冬负,振幅大)')
print(f'  陆地中纬temp robust振幅={np.percentile(Tl,95)-np.percentile(Tl,5):.3f} 海洋={np.percentile(Ts,95)-np.percentile(Ts,5):.3f}')
