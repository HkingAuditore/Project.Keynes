import numpy as np, collections
z = np.load(r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_wx_fields_v7.npz', allow_pickle=True)
days = z['days'].astype(float)
d = np.diff(days)
print(f'phys_sim_day: min={days.min():.0f} max={days.max():.0f} ND={len(days)} span={days.max()-days.min():.0f}')
print(f'记录间隔 dt: median={np.median(d):.2f} mean={d.mean():.2f} max={d.max():.0f} min={d.min():.0f}')
print('间隔分布(top):', collections.Counter(np.round(d).astype(int).tolist()).most_common(8))
print(f'\n若 dt>1 → 气候 pass 可能也按此 dt 放大海洋 α(热惯性失效)。')
print(f'海洋 α=0.008 在不同 dt 下的 α_eff(τ_eff天):')
for dt in [1, 2, 5, 10, 20, 30]:
    aeff = 1 - (1 - 0.008) ** dt
    tau = 1.0 / aeff
    print(f'  dt={dt:>2}: α_eff={aeff:.4f}  τ_eff≈{tau:.0f}天  (设计要 τ≈125天)')
