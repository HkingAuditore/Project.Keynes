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
<ol>
<li><b>Ocean is the only bottleneck worth attacking</b> (~65% of native graph, plus a separate ocean_currents job with 6.3ms spikes). The project already designed <code>Ocean physics cell-range slicing</code> (SLP/WIND/PSI/UPWELLING four leaf-pass slicing + GDScript cursor); it is currently design-state, disabled by default, pending local verification. Enabling and verifying it should spread the 6.3ms spikes across ticks and flatten sus_sim P95/max.</li>
<li><b>PSI full sweep is the spike root cause</b>: PSI currently does no cell-range, full Gauss-Seidel sweep. Samples show psi_iters_run=16, psi_residual_final=0.056. Introducing slicing or a higher early-exit residual threshold for PSI would sharply cut the 6.3ms peak.</li>
<li><b>Wind physics inside the native-graph ocean pass (~{f(wind_sum)}ms)</b>: if cell-range slicing covers this pass, the baseline compute (mean 2.45ms) can be pushed further toward budget, bringing steady state into compliance too.</li>
<li><b>Stagger weather-pass spikes</b>: weather active 1.7ms (duty ~25%) stacked with ocean spikes in the same tick amplifies the total peak; consider offsetting their cadences.</li>
<li><b>Main-thread j_native_daily_sim shell at 1.44ms/tick is high</b> for a "shell". Check marshalling/refresh overhead (native_call 0.27 + apply 0.33 + refresh 0.06). Main thread has headroom, but lowering this would cut fast_ms P95 (currently 6ms, max 10ms).</li>
<li><b>dynamic_visual_atlas_upload 0.83ms @50% duty</b>: visual upload boundary, can be batched/throttled to lower duty.</li>
</ol>

<h2>6 - Quantified optimization potential</h2>
<div class="panel">
<ul style="margin:0">
<li>If ocean_currents 6.3ms spikes are spread to <=3ms via slicing: sus_sim max {f(R['sus_max'])}->~3.5ms, P95 {f(R['sus_p95'])}->~3.3ms, back near budget.</li>
<li>If native-graph ocean pass drops 30% (slicing + PSI early-exit): baseline compute {f(R['comp_mean'])}->~2.0ms, steady-state compliant, ticks over 3ms {f(R['comp_over'],0)}%->near 0.</li>
<li>Just these two Ocean items turn "over budget" from chronic (mean already over) to occasional, without touching fps (already 60).</li>
</ul>
</div>

<h2>Method</h2>
<p class="note">Timing fields contain a -1 sentinel (tick did not run), dropped as missing. Periodic jobs report both active-mean (running ticks only) and duty (running ticks / total ticks) plus amortized value. "Native graph" = the native_daily_graph shared by climate/weather bundles. All numbers derived directly from the 327 sampled rows.</p>
</body></html>"""

with open('perf_report_20260708.html', 'w', encoding='utf-8') as fh:
    fh.write(html)
print("written perf_report_20260708.html", len(html), "bytes")
