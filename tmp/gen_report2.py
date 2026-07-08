import json

with open("D:/Godot/ProjectKeynes/Project.Keynes/tmp/perf_analysis2.json") as f:
    d = json.load(f)

ts = d['t_sus']
bud = d['frame_budget']
jobs = d['jobs']
st = d['stage_tables']
hist = d['frame_hist']
lc = d['largest']['counter']
worst = d['largest']['worst_ms']

# prior-session reference numbers (from 20260707_202818.csv analysis)
prior = dict(t_sus_mean=4.23, t_sus_p95=5.88, t_sus_max=11.29,
             native_mean=1.65, ocean_mean=1.06,
             enum_max=7.5, over8=0.4)

def bar(pct, color="#4aa3ff"):
    return ('<div style="background:%s;height:14px;border-radius:3px;width:%s%%"></div>'
            % (color, max(0.5, min(100, pct))))

html = []
html.append("""<!doctype html><html lang="zh"><head><meta charset="utf-8">
<style>
body{background:#14161a;color:#e6e6e6;font-family:system-ui,'Segoe UI',sans-serif;margin:0;padding:24px;}
h1{font-size:22px;margin:0 0 4px} h2{font-size:17px;margin:28px 0 10px;color:#9ecbff;border-bottom:1px solid #2a2e35;padding-bottom:6px}
.sub{color:#8b93a0;font-size:13px;margin-bottom:18px}
.cards{display:flex;gap:12px;flex-wrap:wrap;margin-bottom:8px}
.card{background:#1c2026;border:1px solid #2a2e35;border-radius:8px;padding:12px 16px;min-width:120px}
.card .v{font-size:24px;font-weight:600}
.card .l{font-size:12px;color:#8b93a0;margin-top:3px}
.warn{color:#ffb454}.bad{color:#ff6b6b}.good{color:#5fd98a}
table{border-collapse:collapse;width:100%;font-size:13px;margin-top:6px}
th,td{text-align:right;padding:5px 8px;border-bottom:1px solid #23272e}
th:first-child,td:first-child{text-align:left}
th{color:#9aa3b0;font-weight:500}
.hist{display:flex;align-items:flex-end;gap:2px;height:120px;margin-top:8px}
.hb{flex:1;background:#4aa3ff;border-radius:2px 2px 0 0;position:relative}
.hb.o{background:#ff6b6b}
.note{background:#1c2026;border:1px solid #2a2e35;border-radius:8px;padding:14px 18px;margin-top:10px;line-height:1.6;font-size:13.5px}
.note b{color:#ffd479}
.tag{display:inline-block;padding:1px 7px;border-radius:4px;font-size:11px;margin-right:4px}
.tag.d{background:#23314a;color:#9ecbff}.tag.o{background:#3a2a1a;color:#ffb454}
</style></head><body>""")

html.append('<h1>Project.Keynes 性能分析 · 新数据</h1>')
html.append('<div class="sub">数据源：tmp/perf_record_20260707_215611.csv · %d ticks · 帧预算 %g ms · 生成于分析脚本</div>'
            % (d['nrows'], bud))

# KPI cards
over8 = sum(1 for lo, c in hist if lo >= bud and c > 0)
over8_ticks = sum(c for lo, c in hist if lo >= bud)
html.append('<div class="cards">')
html.append('<div class="card"><div class="v">%.2f</div><div class="l">t_sus 均值 ms</div></div>' % ts['mean'])
html.append('<div class="card"><div class="v">%.2f</div><div class="l">t_sus p95 ms</div></div>' % ts['p95'])
html.append('<div class="card"><div class="v">%.2f</div><div class="l">t_sus p99 ms</div></div>' % ts['p99'])
html.append('<div class="card"><div class="v bad">%.2f</div><div class="l">t_sus 最大 ms</div></div>' % ts['max'])
html.append('<div class="card"><div class="v">59.6</div><div class="l">fps 均值 (min 54)</div></div>')
html.append('<div class="card"><div class="v warn">%.1f%%</div><div class="l">tick 超 %g ms 预算</div></div>' % (100.0*over8_ticks/d['nrows'], bud))
html.append('</div>')

# histogram
html.append('<h2>每帧仿真耗时分布 (t_sus_ms)</h2>')
maxc = max(c for _, c in hist) or 1
html.append('<div class="hist">')
for lo, c in hist:
    h = 100.0 * c / maxc
    cls = 'hb o' if lo >= bud else 'hb'
    html.append('<div class="%s" style="height:%g%%" title="%g–%g ms: %d ticks"></div>' % (cls, h, lo, lo+0.5, c))
html.append('</div>')
html.append('<div class="sub">横轴 0.5ms/桶；红桶 = 超过 %g ms 帧预算。>8ms: %d ticks (%.1f%%)，无 >12ms。</div>'
            % (bud, over8_ticks, 100.0*over8_ticks/d['nrows']))

# per-job share
html.append('<h2>各作业耗时占比 (占 job-ms 总量)</h2>')
# compute share from job summary via mean_per_frame
tot = sum(jobs[j]['mean_per_frame'] for j in jobs) or 1
html.append('<table><tr><th>作业</th><th>均摊/帧 ms</th><th>运行均值 ms</th><th>p95</th><th>max</th><th>占比</th></tr>')
for j in sorted(jobs, key=lambda x: -jobs[x]['mean_per_frame']):
    s = jobs[j]
    share = 100.0 * s['mean_per_frame'] / tot
    html.append('<tr><td>%s</td><td>%.3f</td><td>%.3f</td><td>%.3f</td><td>%.3f</td><td>%.1f%% %s</td></tr>'
                % (j, s['mean_per_frame'], s['ran_mean'], s['p95'], s['max'], share, bar(share)))
html.append('</table>')

# largest slice attribution
html.append('<h2>单帧最大切片归属 (largest_slice)</h2>')
html.append('<div class="note">')
html.append('每帧最重切片的作业分布：')
for j, c in sorted(lc.items(), key=lambda x: -x[1]):
    html.append('<div>%s — %d ticks (%.1f%%)</div>' % (j, c, 100.0*c/d['nrows']))
html.append('<div style="margin-top:6px">全局最重单切片：<b class="bad">%.3f ms</b>（%s / %s）</div>'
            % (worst, 'native_daily_sim', 'native_daily_complete'))
html.append('<div>trailing-300 窗口内 &gt;1ms 切片数：均值 252.7 / 最大 258（≈每 tick 都有 &gt;1ms 切片）</div>')
html.append('</div>')

# per-stage tables
for j in ['native_daily_sim', 'ocean_currents']:
    html.append('<h2>%s · 各阶段耗时 (ms, 仅运行行)</h2>' % j)
    rows = st[j]
    maxt = max(r['max'] for r in rows) or 1
    html.append('<table><tr><th>阶段</th><th>n</th><th>均值</th><th>p95</th><th>max</th><th>占比</th><th></th></tr>')
    for r in rows:
        w = 100.0 * r['max'] / maxt
        col = '#ff6b6b' if r['max'] > bud else ('#ffb454' if r['max'] > 3 else '#4aa3ff')
        html.append('<tr><td>%s</td><td>%d</td><td>%.3f</td><td>%.3f</td><td>%.3f</td><td>%.1f%%</td><td style="width:160px">%s</td></tr>'
                    % (r['stage'], r['n'], r['mean'], r['p95'], r['max'], r['share'], bar(w, col)))
    html.append('</table>')

# comparison / takeaways
html.append('<h2>对比上一轮 (20260707_202818) 与优化指向</h2>')
html.append('<div class="note">')
html.append('<p>%s <b>enum_atlas_upload 的 7.5ms 偶发尖峰已消失</b>（本轮 max 仅 1.7ms，运行 86 次）——上一轮最大的尾部风险已修复。但基线被新系统抬高：<b>natural_resource_daily 每 tick 跑 0.255ms（占 7.2%%）</b>、dynamic_visual_atlas_upload 0.173ms，两者是上一轮没有的常驻负载。</p>' % '<span class="tag d">修复</span>')
html.append('<p>%s native_daily_sim 的 <b>weather 尖峰从 7.79→4.13ms 收敛</b>，但 <b>native_daily_complete 收尾片反而变重（3.89→6.44ms max）</b>，成为新的全局最重单切片。ocean_currents 各阶段基本不变（phys_wind 1.88→2.03、phys_slp 1.71→1.83）——符合预期：本轮为桌面捕获，period-scale 改动默认 scale=1.0 为 no-op（仅移动端 / ocean_period_scale_weak&gt;1 生效）。</p>' % '<span class="tag o">变化</span>')
html.append('<p><b>结论：</b>两作业仍占 job-ms 的 <b>84%%</b>（native 51.5%% + ocean 32.5%%），且每个阶段切片 1.1–3.6ms 全部 &gt;&gt; 1.0ms 切片预算，仍是「节点/阶段粒度、不可抢占」的老问题。真正杠杆仍是 <b>cutting_native_daily_ocean.md §7</b> 的：① 削 native_daily_complete 收尾 flush/publish；② 削 GDScript wrapper 开销（复用 knob dict / 缓存 neighbor / 直接 slot 写）；③ 弱机/移动端 period-scale（已落地，待你本地构建后 PROBE 验收）。</p>')
html.append('<p class="sub">上一轮参考：t_sus 均值 %.2f / p95 %.2f / max %.2f；native 均摊 %.2f；ocean 均摊 %.2f；enum_atlas max %.1f×61tick。</p>'
            % (prior['t_sus_mean'], prior['t_sus_p95'], prior['t_sus_max'], prior['native_mean'], prior['ocean_mean'], prior['enum_max']))
html.append('</div>')

html.append('</body></html>')

with open("D:/Godot/ProjectKeynes/Project.Keynes/tmp/perf_report2.html", "w", encoding="utf-8") as f:
    f.write("\n".join(html))
print("wrote perf_report2.html")
