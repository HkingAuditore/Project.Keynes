"""实机平流式重构验证器 — 诊断式(OLD) vs 平流式(NEW)。

直接读【实机导出 CSV 提取的】真实降水序列 weather_precip_arr [ND,NC]，
对其计算时空 metrics，量化重构前后"永雨/永旱/雨区移动性"的真实变化。
不跑离线模拟，纯读实机结果 —— 这是落地后真正要看的东西。

用法:
  1) 重编 gdext (scons platform=windows target=template_debug / _release)
  2) 实机跑一段 (>~80 模拟日更佳) + 导出新 CSV
  3) 提取新 CSV -> NPZ:
       复制 _wx_extract_0621.py，把开头两行改成
         CSV=<新csv路径>
         OUT=<TMP>/_wx_fields_new.npz
       然后运行它 (pandas 读 ~分钟级)
  4) python _wx_verify_realsim.py     # 自动对比 OLD vs NEW + 出图

指标(对实机 weather_precip_arr，warm 预热日已跳过):
  perma_rain  永雨格比例 (湿天>80%)        ↓ 越低越好  ← 用户核心诉求
  perma_dry   永旱格比例 (湿天<5%)          适度即可，不应满图
  jaccard     相邻日雨区重叠                ↓ 越低 = 雨区越在移动
  hov_t/lon   Hovmoller 时间/经度方差比     ↑ 通常伴随移动的天气系统
  mean_wet    平均湿天比例                  健康区间，不塌缩到 0 也不饱和到 1
"""
import os
import numpy as np

TMP = r'd:/Godot/ProjectKeynes/Project.Keynes/tmp'
OLD_NPZ = os.path.join(TMP, '_wx_fields_0621.npz')   # 旧实机(诊断式降水) — 重构前基线
NEW_NPZ = os.path.join(TMP, '_wx_fields_new.npz')    # 新实机(平流式湿团) — 重编后导出


def _warm_for(nd: int) -> int:
    if nd >= 80:
        return 40
    return max(2, nd // 4)


def metrics(precip: np.ndarray, px: np.ndarray, warm: int, wet_th: float = 0.02) -> dict:
    nd, nc = precip.shape
    P = precip[warm:]
    if P.shape[0] < 2:
        P = precip
    wet = (P > wet_th).mean(0)
    perma_rain = float((wet > 0.80).mean())
    perma_dry = float((wet < 0.05).mean())
    extreme = float(((wet < 0.1) | (wet > 0.9)).mean())
    js = []
    for d in range(1, P.shape[0]):
        a = P[d - 1] > wet_th
        b = P[d] > wet_th
        u = (a | b).sum()
        if u > 0:
            js.append((a & b).sum() / u)
    jacc = float(np.mean(js)) if js else 1.0
    LB = 24
    span = max(px.max() - px.min(), 1e-9)
    lonb = np.clip(((px - px.min()) / span * LB).astype(int), 0, LB - 1)
    hov = np.zeros((P.shape[0], LB))
    for b in range(LB):
        m = lonb == b
        if m.any():
            hov[:, b] = P[:, m].mean(1)
    tvar = hov.var(0).mean()
    lvar = hov.var(1).mean()
    return dict(perma_rain=perma_rain, perma_dry=perma_dry, extreme_bins=extreme, jaccard=jacc,
                hov_t_over_lon=float(tvar / max(lvar, 1e-9)),
                mean_wet=float(wet.mean()), mean_precip=float(P.mean()),
                ND=nd, NC=nc, warm=warm)


def load(path: str):
    if not os.path.exists(path):
        return None
    z = np.load(path, allow_pickle=True)
    if 'dy_weather_precip_arr' not in z.files:
        print(f'[!] {os.path.basename(path)} 缺 dy_weather_precip_arr (extract 时需含 weather_precip_arr)')
        return None
    P = np.nan_to_num(z['dy_weather_precip_arr'].astype(np.float64))
    px = z['px'].astype(np.float64)
    return P, px


def run_one(tag: str, path: str):
    r = load(path)
    if r is None:
        print(f'[--] {tag:<10} 缺 {os.path.basename(path)} (跳过 — 重编+实机导出后再提取)')
        return None
    P, px = r
    warm = _warm_for(P.shape[0])
    m = metrics(P, px, warm)
    print(f'[{tag}] ND={m["ND"]} NC={m["NC"]} warm={warm}')
    print(f'     perma_rain={m["perma_rain"]:.3f}  perma_dry={m["perma_dry"]:.3f}  extreme={m["extreme_bins"]:.3f}')
    print(f'     jaccard={m["jaccard"]:.3f}  hov_t/lon={m["hov_t_over_lon"]:.3f}  '
          f'mean_wet={m["mean_wet"]:.3f}  mean_precip={m["mean_precip"]:.4f}')
    return m, P, px, warm


def main():
    print('=' * 66)
    print(' 实机平流式重构验证 — 直接读实机 weather_precip_arr 时间序列')
    print('=' * 66)
    old = run_one('OLD 诊断式', OLD_NPZ)
    new = run_one('NEW 平流式', NEW_NPZ)

    if old and new:
        mo, mn = old[0], new[0]
        print('-' * 66)
        print(f'{"指标":<14}{"OLD":>10}{"NEW":>10}{"Δ":>11}   目标')

        def row(k, name, good):
            print(f'{name:<14}{mo[k]:>10.3f}{mn[k]:>10.3f}{mn[k] - mo[k]:>+11.3f}   {good}')

        row('perma_rain', '永雨比例', '↓ 越低越好')
        row('perma_dry', '永旱比例', '↓/适度')
        row('jaccard', '雨区重叠', '↓ 更动')
        row('mean_wet', '平均湿比', '健康区间')
        row('hov_t_over_lon', 'Hov时/经', '↑ 移动')
    elif old:
        print('-' * 66)
        print('[基线] 上面是【重构前 诊断式】实机基线。重编+实机导出新 CSV、提取为')
        print('       _wx_fields_new.npz 后再次运行本脚本，即可看到 NEW 对比与改善幅度。')

    try:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
        panels = [(t, r) for t, r in [('OLD 诊断式', old), ('NEW 平流式', new)] if r is not None]
        if panels:
            fig, axes = plt.subplots(2, len(panels), figsize=(6 * len(panels), 9), squeeze=False)
            etag = {'OLD 诊断式': 'OLD (diagnostic)', 'NEW 平流式': 'NEW (advective)'}
            for j, (tag, res) in enumerate(panels):
                m, P, px, warm = res
                en = etag.get(tag, tag)
                Pw = P[warm:]
                LB = 24
                span = max(px.max() - px.min(), 1e-9)
                lonb = np.clip(((px - px.min()) / span * LB).astype(int), 0, LB - 1)
                H = np.zeros((Pw.shape[0], LB))
                for b in range(LB):
                    msk = lonb == b
                    if msk.any():
                        H[:, b] = Pw[:, msk].mean(1)
                ax = axes[0][j]
                ax.imshow(H, aspect='auto', origin='lower', cmap='Blues',
                          vmin=0, vmax=max(H.max(), 1e-3))
                ax.set_title(f'{en}  Hovmoller (diagonal = moving rain belt)')
                ax.set_xlabel('longitude bin')
                ax.set_ylabel('sim day')
                ax = axes[1][j]
                wet = (P[warm:] > 0.02).mean(0)
                ax.hist(wet, bins=30, range=(0, 1), color='steelblue')
                ax.axvline(0.80, color='r', ls='--', label='perma-rain 0.80')
                ax.axvline(0.05, color='orange', ls='--', label='perma-dry 0.05')
                ax.set_title(f'{en}  wet-ratio dist (U-shape = lots of perma rain/dry)')
                ax.set_xlabel('wet-day ratio')
                ax.set_ylabel('cells')
                ax.legend()
            fig.tight_layout()
            out = os.path.join(TMP, '_wx_verify_realsim.png')
            fig.savefig(out, dpi=110)
            print(f'[图] {out}')
    except Exception as e:
        print(f'[图跳过] {e}')


if __name__ == '__main__':
    main()
