import json
R = json.load(open('tmp_report_data.json'))

def f(x, n=2):
    return f"{x:.{n}f}"

def hbar_chart(title, bars, unit="ms", ref=None, reflabel=None, w=640, xmax=None, color_fn=None):
    if xmax is None:
        xmax = max([b[1] for b in bars] + ([ref] if ref else [])) * 1.12
    rowh = 30; top = 34; h = top + len(bars) * rowh + 14
    parts = [f'<svg viewBox="0 0 {w} {h}" width="100%" style="max-width:{w}px;font-family:inherit">']
    parts.append(f'<text x="0" y="20" fill="#e6e6e6" font-size="14" font-weight="600">{title}</text>')
    scale = (w - 220) / xmax
    if ref is not None:
        rx = 200 + ref * scale
        parts.append(f'<line x1="{rx}" y1="{top-6}" x2="{rx}" y2="{h-6}" stroke="#ff5c7a" stroke-width="1.5" stroke-dasharray="4 3"/>')
        parts.append(f'<text x="{rx+4}" y="{top-2}" fill="#ff8aa0" font-size="11">{reflabel or str(ref)+unit}</text>')
    for i, b in enumerate(bars):
        y = top + i * rowh
        label, val, sub = b[0], b[1], (b[2] if len(b) > 2 else "")
        bw = max(2, val * scale)
        col = color_fn(label) if color_fn else "#4aa3ff"
        parts.append(f'<text x="0" y="{y+15}" fill="#c8ccd6" font-size="12.5">{label}</text>')
        parts.append(f'<rect x="200" y="{y+3}" width="{bw}" height="18" rx="3" fill="{col}"/>')
        parts.append(f'<text x="{200+bw+6}" y="{y+16}" fill="#e6e6e6" font-size="12">{f(val)}</text>')
        if sub:
            parts.append(f'<text x="200" y="{y+28}" fill="#8b90a0" font-size="10.5">{sub}</text>')
    parts.append('</svg>')
    return "".join(parts)

def barcolor(label):
    m = {'ocean':"#4aa3ff",'climate':"#ffb454",'weather':"#c792ea",'hydrology':"#7fdbca",
         'wind':"#4aa3ff",'wind_air':"#6fb6ff",'wind_surface':"#9ecbff",'ocean_water':"#36c2cf",
         'ocean_land':"#3ad6a0",'sea_ice':"#a0e8ff",'transp':"#7fdbca",'cyclone':"#ff9bd0"}
    return m.get(label.split(' (')[0], "#9aa0b5")

nat_bars = [
    ("ocean", R['ocean_m']*0.945, f"占原生图 ~65%  -  活跃时 {f(R['ocean_m'])}ms, 占空比 94.5%"),
    ("climate", R['climate_m']*0.972, f"活跃时 {f(R['climate_m'])}ms, 占空比 97.2%"),
    ("weather", R['weather_a']*R['weather_duty'], f"活跃时 {f(R['weather_a'])}ms, 占空比 {f(R['weather_duty']*100,1)}%  (单次尖峰 1.7ms)"),
    ("hydrology", R['hydro_a']*R['hydro_duty'], f"活跃时 {f(R['hydro_a'])}ms, 占空比 {f(R['hydro_duty']*100,1)}%"),
]
c1 = hbar_chart("原生日仿真图 - 各子系统每tick摊销耗时 (mean, ms)", nat_bars, ref=R['bud_slice'], reflabel="3.0 预算", color_fn=barcolor)

oc_bars = [
    ("wind", R['wind'], "风场求解 (Gauss-Seidel 主扫掠)"),
    ("wind_air", R['wind_air'], "空气侧风"),
    ("wind_surface", R['wind_surf'], "海表风应力"),
    ("ocean_water", R['ocean_water'], "海水环流"),
    ("ocean_land", R['ocean_land'], "近岸/陆架"),
    ("sea_ice", R['sea_ice'], "海冰"),
]
c2 = hbar_chart("Ocean pass 内部拆分 (活跃时 mean, ms)", oc_bars, color_fn=barcolor)
wind_sum = R['wind'] + R['wind_air'] + R['wind_surf']

ex_bars = [
    ("sus_sim mean(300)", R['sus_avg']),
    ("sus_sim P95(300)", R['sus_p95']),
    ("sus_sim max(300)", R['sus_max']),
    ("native compute P95", R['comp_p95']),
    ("native compute max", R['comp_max']),
    ("ocean_currents max", R['ocjob_max']),
    ("single-tick max slice", R['ls_max']),
]
c3 = hbar_chart("key metrics vs 3.0ms slice budget (red line)", ex_bars, ref=R['bud_slice'], reflabel="3.0 budget",
                color_fn=lambda l: "#ff8a5c" if (l.startswith('sus') or 'ocean' in l or 'slice' in l) else "#9aa0b5")

mt_bars = [
    ("j_native_daily_sim (shell)", R['nds_mean'], "every tick 100%"),
    ("j_ocean_currents", R['ocjob_mean'], f"active 1.60ms, duty {f(R['ocjob_duty']*100,1)}%"),
    ("j_dynamic_visual_atlas_upload", R['dvau_a']*R['dvau_duty'], f"active 0.83ms, duty {f(R['dvau_duty']*100,1)}%"),
    ("j_natural_resource_daily", R['nrd_mean'], "every tick 100%"),
    ("j_enum_atlas_upload", R['eau_a']*R['eau_duty'], f"active 0.22ms, duty {f(R['eau_duty']*100,1)}%"),
    ("j_season_refresh", R['sr_mean'], "every tick 100%"),
    ("climate/weather apply", 0.666, "GDScript result writeback (~0.33x2)"),
]
c4 = hbar_chart("main-thread sim composition (fast_ms amortized, ms)", mt_bars, xmax=1.6, color_fn=lambda l: "#7fd1ff")

html = f"""<!doctype html><html lang="zh"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Project.Keynes performance report</title>
<style>
 body{{background:#14161c;color:#e6e6e6;font-family:-apple-system,'Segoe UI',Roboto,'Microsoft YaHei',sans-serif;margin:0;padding:28px 32px;line-height:1.55}}
 h1{{font-size:22px;margin:0 0 4px}} .sub{{color:#8b90a0;font-size:13px;margin-bottom:22px}}
 h2{{font-size:16px;margin:30px 0 10px;border-left:3px solid #4aa3ff;padding-left:10px}}
 .cards{{display:flex;flex-wrap:wrap;gap:12px;margin:14px 0}}
 .card{{background:#1d212c;border:1px solid #2a2f3d;border-radius:10px;padding:12px 16px;min-width:150px}}
 .card .k{{font-size:12px;color:#8b90a0}} .card .v{{font-size:21px;font-weight:700;margin-top:2px}}
 .card .v.warn{{color:#ff8a5c}} .card .v.ok{{color:#5fd38a}} .card .v.bad{{color:#ff5c7a}}
 .panel{{background:#1a1e27;border:1px solid #262b38;border-radius:10px;padding:14px 16px;margin:12px 0}}
 table{{border-collapse:collapse;width:100%;font-size:13px;margin-top:6px}}
 th,td{{text-align:left;padding:7px 10px;border-bottom:1px solid #262b38}}
 th{{color:#8b90a0;font-weight:600}} td.num{{text-align:right;font-variant-numeric:tabular-nums}}
 .warn{{color:#ff8a5c}} .ok{{color:#5fd38a}} .mut{{color:#8b90a0}}
 .note{{font-size:12.5px;color:#9aa0b5;margin:8px 0}}
 ol li{{margin:9px 0}} code{{background:#232838;padding:1px 5px;border-radius:4px;color:#9ecbff;font-size:12.5px}}
</style></head><body>
<h1>Project.Keynes - Compute Time Distribution & Optimization</h1>
<div class="sub">source: perf_record_20260708_202413.csv - {R['n']} ticks - fps locked at {f(R['fps'],0)} - generated 2026-07-08</div>

<div class="cards">
 <div class="card"><div class="k">frame budget / sim-frame budget</div><div class="v ok">{f(1000/60,1)} / {f(R['bud_frame'],1)} ms</div></div>
 <div class="card"><div class="k">per-slice budget</div><div class="v">{f(R['bud_slice'],1)} ms</div></div>
 <div class="card"><div class="k">main-thread fast_ms (mean/P95/max)</div><div class="v ok">{f(R['fast_mean'])} / {f(R['fast_p95'],0)} / {f(R['fast_max'],0)}</div></div>
 <div class="card"><div class="k">sus_sim (mean/P95/max)</div><div class="v warn">{f(R['sus_avg'])} / {f(R['sus_p95'])} / {f(R['sus_max'])}</div></div>
 <div class="card"><div class="k">native compute (mean/P95/max)</div><div class="v warn">{f(R['comp_mean'])} / {f(R['comp_p95'])} / {f(R['comp_max'])}</div></div>
 <div class="card"><div class="k">native over 3ms share</div><div class="v bad">{f(R['comp_over'],0)}%</div></div>
</div>

<h2>1 - Summary</h2>
<div class="panel">
<p style="margin:0">Render overhead is tiny (t_render {f(R['trender'])}ms). Main-thread sim fast_ms mean {f(R['fast_mean'])}ms / P95 {f(R['fast_p95'],0)}ms is well within the 8ms sim-frame budget (and 16.7ms frame budget); fps is steady at 60. The real pressure is on the <b>native worker thread's daily simulation</b>: its sim_slice_budget is 3.0ms, yet the rolling sus_sim mean is already {f(R['sus_avg'])}ms (+5%), P95 {f(R['sus_p95'])}ms (+58%), max {f(R['sus_max'])}ms (+128%); native compute_ms exceeds 3ms in <b>{f(R['comp_over'],0)}%</b> of ticks. Optimization should target the native sim's P95/max, not the main thread.</p>
</div>

<h2>2 - Compute distribution (native worker daily graph)</h2>
<p class="note">climate and weather bundles are two instrumented views of the <b>same native graph</b> (identical compute values), so the table below counts one native graph. Each pass "amortized" = active-mean x duty.</p>
{c1}
<p class="note">Ocean pass is ~<b>65%</b> of the native graph (amortized ~1.60ms). Within it, wind physics (wind + wind_air + wind_surface) totals ~<b>{f(wind_sum)}ms</b> - about 65% of ocean, ~45% of the whole native graph - the single largest hotspot.</p>
{c2}

<h2>3 - Budget compliance (red line = 3.0ms slice budget)</h2>
{c3}
<table>
<tr><th>metric</th><th class="num">mean</th><th class="num">P95</th><th class="num">max</th><th>verdict</th></tr>
<tr><td>sus_sim (300-window)</td><td class="num">{f(R['sus_avg'])}</td><td class="num">{f(R['sus_p95'])}</td><td class="num">{f(R['sus_max'])}</td><td class="warn">mean already over budget, P95/max far over</td></tr>
<tr><td>native compute</td><td class="num">{f(R['comp_mean'])}</td><td class="num">{f(R['comp_p95'])}</td><td class="num">{f(R['comp_max'])}</td><td class="warn">{f(R['comp_over'],0)}% ticks over 3ms</td></tr>
<tr><td>ocean_currents job</td><td class="num">{f(R['ocjob_mean'])}</td><td class="num">{f(R['ocjob_a'])}</td><td class="num warn">{f(R['ocjob_max'])}</td><td class="warn">periodic 6.3ms spike, largest-slice source {R['ls_ocean']}/{R['n']}</td></tr>
<tr><td>single-tick max slice</td><td class="num">-</td><td class="num">-</td><td class="num warn">{f(R['ls_max'])}</td><td class="warn">native_daily_sim {R['ls_native']} times / ocean_currents {R['ls_ocean']} times alternate as largest slice</td></tr>
</table>
<p class="note">In the rolling window, over_1ms_count_300 = {f(R['over1'],0)}/300, i.e. ~72% of sim slices &gt;1ms.</p>

<h2>4 - Main-thread sim composition (reference only, has headroom)</h2>
{c4}
<p class="note">Main-thread items sum to ~ fast_ms mean {f(R['fast_mean'])}ms, far below the 8ms sim-frame budget - not the bottleneck; listed to locate future cuts.</p>

<h2>5 - Optimization opportunities</h2>
<div class="panel" style="border-color:#3a4a2a">
<p style="margin:0"><b>与既有结论对齐（对比 2026-07-08 15:01 capture 的同口径分析）：</b>早前分析已确认 <code>ocean_currents</code> 四 leaf pass 切片（Item 1/2）基本到位、单 pass 已 &lt;3ms、<b>非主瓶颈</b>；当时真正的 fps 杠杆被定位为 <b><code>native_daily_sim</code> 节点级 cell-range（cutting_native_daily_ocean.md &sect;7）</b>——即本报告中 climate/weather 原生图这一整块。本 CSV 的细分进一步坐实：原生图内 <b>ocean pass 占均值 ~65%</b>、<b>weather pass 是最大单次激活尖峰</b>，因此 &sect;7 的节点级切片应优先覆盖 ocean pass（压均值）与 weather/climate_pass_a 峰值。独立 <code>ocean_currents</code> job 的 6.3ms 尖峰属次要、可顺带收口。</p>
</div>
<ol>
<li><b>主杠杆：原生图（native_daily_sim）节点级 cell-range（&sect;7）</b>。这是既有结论认定的真正瓶颈（早前占 sim ~51.5%、7.44ms 段落尖峰）。本数据把它拆开：ocean pass 摊销 ~1.60ms（均值 65%），weather pass 活跃 1.7ms（占空比 ~25%，为最大单次激活），climate_pass_a 峰值亦显著。对该原生图做节点级切片，优先级 ocean &gt; weather &gt; climate，可同时压低均值与 P95/峰值。</li>
<li><b>顺带收口 ocean_currents job 的 6.3ms 尖峰</b>（160/327 的最大切片来源）。项目已设计该 job 的 cell-range 切片（SLP/WIND/PSI/UPWELLING + GDScript 游标），但默认关闭、待本地验收；当前该 job 仍近乎单切片运行。按验收门槛（bit-equal + fallback==0 + 每切片 p95/max&lt;1ms）启用验证后，可削平这些尖峰。注意：既有结论认为此 job 已非主瓶颈，故它是"顺手优化"而非首要目标。</li>
<li><b>PSI 全扫掠是 ocean_currents 尖峰主因</b>：PSI 当前不做 cell-range、Gauss-Seidel 全扫掠。采样显示 <code>psi_iters_run=16</code>、<code>psi_residual_final=0.056</code>。对 PSI 引入切片或提高早退残差阈值，可显著削减 6.3ms 峰值。这与 &sect;7 节点级切片的思路一致。</li>
<li><b>风场物理（原生图 ocean pass 内 wind+wind_air+wind_surface ~{f(wind_sum)}ms）</b>：若 &sect;7 节点级切片覆盖该 pass，基线 compute（均值 2.45ms）可进一步压向 3ms 预算，使稳态也达标。</li>
<li><b>weather pass 尖峰错峰</b>：weather 活跃 1.7ms（占空比 ~25%），与原生图其余尖峰同 tick 叠加会放大总峰；考虑错开其 cadence，避免峰值堆叠。</li>
<li><b>主线程 j_native_daily_sim 调度壳 1.44ms/tick 偏高</b>（相对"壳"角色）。检查 marshalling/refresh 开销（native_call 0.27 + apply 0.33 + refresh 0.06）。主线程有余量，但降低它可压低 <code>fast_ms</code> P95（当前 6ms、峰 10ms）。</li>
<li><b>dynamic_visual_atlas_upload 0.83ms @50% 占空比</b>：视觉上传边界，可批量/节流以降低占空比。</li>
</ol>

<h2>6 - Quantified optimization potential</h2>
<div class="panel">
<ul style="margin:0">
<li><b>主杠杆 &sect;7 节点级切片（覆盖原生图 ocean+weather）</b>：把原生图 compute 峰值 {f(R['comp_max'])}ms / P95 {f(R['comp_p95'])}ms 摊薄到预算内，可使超 3ms 的 tick 占比从 {f(R['comp_over'],0)}% 降到接近 0，sus_sim P95 {f(R['sus_p95'])}→~3.x ms。这是既有结论认定的真正 fps 杠杆。</li>
<li><b>顺带：ocean_currents job 切片启用</b>：若该 job 6.3ms 尖峰经切片摊薄至 &le;3ms，sus_sim 峰值 {f(R['sus_max'])}→~3.5ms，但按既有结论此 job 已非主瓶颈，收益次于 &sect;7。</li>
<li><b>组合效果</b>：仅 &sect;7 一项即可把"超预算"从常态化（均值即超）变为偶发，且不损 fps（本就 60）。PSI 早退 / weather 错峰作为 &sect;7 内部的低风险的子优化，可进一步压峰值。</li>
</ul>
</div>

<h2>Method</h2>
<p class="note">Timing fields contain a -1 sentinel (tick did not run), dropped as missing. Periodic jobs report both active-mean (running ticks only) and duty (running ticks / total ticks) plus amortized value. "Native graph" = the native_daily_graph shared by climate/weather bundles. All numbers derived directly from the 327 sampled rows.</p>
</body></html>"""

with open('perf_report_20260708.html', 'w', encoding='utf-8') as fh:
    fh.write(html)
print("written perf_report_20260708.html", len(html), "bytes")
