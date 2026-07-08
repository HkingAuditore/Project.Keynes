import json

with open("D:/Godot/ProjectKeynes/Project.Keynes/tmp/perf_analysis2b.json") as f:
    B = json.load(f)   # before (215611, before wrapper reduction)
with open("D:/Godot/ProjectKeynes/Project.Keynes/tmp/perf_analysis3.json") as f:
    A = json.load(f)   # after  (222750, after wrapper reduction)

def pct(a, b):
    if b == 0:
        return 0.0
    return 100.0 * (a - b) / b

def cls(delta):
    if delta > 1.0:
        return "#5fd98a"   # improved (lower ms)
    if delta < -1.0:
        return "#ff6b6b"   # worse
    return "#9aa3b0"       # noise

def dtxt(delta):
    if delta > 1.0:
        return "↓ 改善"
    if delta < -1.0:
        return "↑ 变差"
    return "≈ 噪声"

bud = A['frame_budget']
tsB, tsA = B['t_sus'], A['t_sus']
jb, ja = B['jobs'], A['jobs']

html = []
html.append("""<!doctype html><html lang="zh"><head><meta charset="utf-8">
<style>
body{background:#14161a;color:#e6e6e6;font-family:system-ui,'Segoe UI',sans-serif;margin:0;padding:24px;}
h1{font-size:22px;margin:0 0 4px} h2{font-size:17px;margin:28px 0 10px;color:#9ecbff;border-bottom:1px solid #2a2e35;padding-bottom:6px}
.sub{color:#8b93a0;font-size:13px;margin-bottom:18px}
.cards{display:flex;gap:12px;flex-wrap:wrap;margin-bottom:8px}
.card{background:#1c2026;border:1px solid #2a2e35;border-radius:8px;padding:12px 16px;min-width:118px}
.card .v{font-size:22px;font-weight:600} .card .l{font-size:12px;color:#8b93a0;margin-top:3px}
.warn{color:#ffb454}.bad{color:#ff6b6b}.good{color:#5fd98a}
table{border-collapse:collapse;width:100%;font-size:13px;margin-top:6px}
th,td{text-align:right;padding:5px 8px;border-bottom:1px solid #23272e}
th:first-child,td:first-child{text-align:left}
th{color:#9aa3b0;font-weight:500}
.note{background:#1c2026;border:1px solid #2a2e35;border-radius:8px;padding:14px 18px;margin-top:10px;line-height:1.65;font-size:13.5px}
.note b{color:#ffd479}
.tag{display:inline-block;padding:1px 7px;border-radius:4px;font-size:11px;margin-right:4px}
.tag.n{background:#23262b;color:#9aa3b0}.tag.w{background:#3a2a1a;color:#ffb454}.tag.g{background:#23314a;color:#9ecbff}
</style></head><body>""")

html.append('<h1>Project.Keynes 性能 A/B · wrapper 削减验证</h1>')
html.append('<div class="sub">基线 215611.csv（改之前，%d ticks） → 对照 222750.csv（改之后，%d ticks） · 帧预算 %g ms</div>'
            % (B['nrows'], A['nrows'], bud))

# ===== KPI cards: t_sus =====
ovB = sum(1 for lo, c in B['frame_hist'] if lo >= bud for _ in range(c))
ovA = sum(1 for lo, c in A['frame_hist'] if lo >= bud for _ in range(c))
html.append('<div class="cards">')
html.append('<div class="card"><div class="v">%.2f→%.2f</div><div class="l">t_sus 均值 ms</div></div>' % (tsB['mean'], tsA['mean']))
html.append('<div class="card"><div class="v">%.2f→%.2f</div><div class="l">t_sus p95 ms</div></div>' % (tsB['p95'], tsA['p95']))
html.append('<div class="card"><div class="v">%.2f→%.2f</div><div class="l">t_sus p99 ms</div></div>' % (tsB['p99'], tsA['p99']))
html.append('<div class="card"><div class="v bad">%.2f→%.2f</div><div class="l">t_sus 最大 ms</div></div>' % (tsB['max'], tsA['max']))
html.append('<div class="card"><div class="v warn">%.1f%%→%.1f%%</div><div class="l">tick 超 %g ms</div></div>' % (100.0*ovB/B['nrows'], 100.0*ovA/A['nrows'], bud))
html.append('</div>')

# ===== per-job share A/B =====
html.append('<h2>各作业耗时：基线 vs 对照（均值/帧 ms，占比）</h2>')
totB = sum(jb[j]['mean_per_frame'] for j in jb)
totA = sum(ja[j]['mean_per_frame'] for j in ja)
html.append('<table><tr><th>作业</th><th>改前 ms</th><th>改后 ms</th><th>Δ%</th><th>改前占比</th><th>改后占比</th></tr>')
order = sorted(jb, key=lambda x: -ja[x]['mean_per_frame'])
for j in order:
    mb, ma = jb[j]['mean_per_frame'], ja[j]['mean_per_frame']
    d = pct(ma, mb)
    sb, sa = 100.0*jb[j]['mean_per_frame']/totB, 100.0*ja[j]['mean_per_frame']/totA
    c = cls(-d)
    flag = ''
    if j == 'dynamic_visual_atlas_upload':
        flag = ' <span class="tag w">新增大涨</span>'
    html.append(f'<tr><td>{j}{flag}</td><td>{mb:.3f}</td><td>{ma:.3f}</td>'
                f'<td style="color:{c}">{d:.1f}%</td>'
                f'<td>{sb:.1f}%</td><td>{sa:.1f}%</td></tr>')
html.append('</table>')

# ===== ocean_currents per-stage A/B (the optimized job) =====
html.append('<h2>ocean_currents 各阶段 A/B（本次优化目标作业）</h2>')
sb_tbl, sa_tbl = B['stage_tables']['ocean_currents'], A['stage_tables']['ocean_currents']
amap = {r['stage']: r for r in sa_tbl}
html.append('<table><tr><th>阶段</th><th>改前均值</th><th>改后均值</th><th>Δ%</th><th>判定</th></tr>')
for r in sb_tbl:
    st = r['stage']
    if st not in amap:
        continue
    a = amap[st]['mean']
    d = pct(a, r['mean'])
    cc = cls(-d)
    html.append(f'<tr><td>{st}</td><td>{r["mean"]:.3f}</td><td>{a:.3f}</td>'
                f'<td style="color:{cc}">{d:.2f}%</td>'
                f'<td style="color:{cc}">{dtxt(-d)}</td></tr>')
html.append('</table>')

# ===== native_daily_sim per-stage A/B (CONTROL, untouched) =====
html.append('<h2>native_daily_sim 各阶段 A/B（对照组 · 未改动）</h2>')
sb2, sa2 = B['stage_tables']['native_daily_sim'], A['stage_tables']['native_daily_sim']
amap2 = {r['stage']: r for r in sa2}
html.append('<table><tr><th>阶段</th><th>改前均值</th><th>改后均值</th><th>Δ%</th><th>判定</th></tr>')
for r in sb2:
    st = r['stage']
    if st not in amap2:
        continue
    a = amap2[st]['mean']
    d = pct(a, r['mean'])
    cc = cls(-d)
    html.append(f'<tr><td>{st}</td><td>{r["mean"]:.3f}</td><td>{a:.3f}</td>'
                f'<td style="color:{cc}">{d:.2f}%</td>'
                f'<td style="color:{cc}">{dtxt(-d)}</td></tr>')
html.append('</table>')

# ===== conclusion =====
html.append('<h2>结论：wrapper 削减是否有效？</h2>')
html.append('<div class="note">')
html.append('<p><span class="tag n">事实</span> ocean_currents 五阶段均值全微降（phys_psi_init -0.8%%、phys_wind -1.8%%、phys_slp -3.1%%、daily_wind_prepass -2.3%%、phys_upwelling -4.6%%），作业均摊 1.158→1.132ms（-2.2%%）。</p>')
html.append('<p><span class="tag n">对照</span> 但<b>未改动的</b> native_daily_sim 同样整体下移：各阶段波动 <b>-10.4%% ~ +7.5%%</b>（ocean_land -10.4%%、ocean_water -8.2%%、weather +7.5%%），作业均摊 1.833→1.777ms（-3.1%%）。</p>')
html.append('<p><span class="tag w">判定</span> 优化作业的 -0~4.6%% 完全落在<b>未改作业的噪声带</b>内。即：<b>本次 wrapper 削减没有可归因的实测收益</b>——它安全、无回归，但也几乎没有省钱。</p>')
html.append('<p><span class="tag g">根因</span> 这印证了动手前的判断：耗时大头是 <b>C++ kernel + GDExtension 边界 marshaling 的固定成本</b>，不是 GDScript dict 构造。knob 字典缓存削掉的只是其中极薄一层（25 个 int/float 字段 + 一次 duplicate，约 μs 级），且本就被 run-to-run 噪声淹没。</p>')
html.append('<p><b>下一步（真正能动的杠杆）</b>：要把 ocean_currents 的 1.5–2.0ms 阶段压下去，必须走 <b>cutting_native_daily_ocean.md §7.3 的 C++ cell-range 重构</b>（让 phys_wind/phys_slp/phys_psi 接受 start_idx/end_idx，把单阶段摊到多 tick），或削减 C++ 内核本身——而非继续在 GDScript wrapper 上做文章。</p>')
html.append('<p><span class="tag w">新目标</span> <b>dynamic_visual_atlas_upload 从 4.9%%→11.2%% 占比、0.173→0.421ms/帧、运行 343→737 次（2.4×）</b>，已成第 3 大作业。它不是 sim 作业、与本次优化无关，但是下一处值得砍的常驻负载。</p>')
html.append('</div>')

html.append('</body></html>')
with open("D:/Godot/ProjectKeynes/Project.Keynes/tmp/perf_report3_ab.html", "w", encoding="utf-8") as f:
    f.write("\n".join(html))
print("wrote perf_report3_ab.html")
