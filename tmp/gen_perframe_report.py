import json
with open('D:/Godot/ProjectKeynes/Project.Keynes/tmp/perframe.json') as f:
    d=json.load(f)

layers=d['layers']; n=d['n']; budget=d['budget']
W,H=940,300; mL,mR,mT,mB=46,12,12,26
x0=mL; x1=W-mR; y0=H-mB; y1=mT
ymax=13.0
def sx(i): return x0+(x1-x0)*i/(n-1)
def sy(v): return y0-(y0-y1)*min(v,ymax)/ymax

ORDER=['native','ocean','natres','dynatlas','enumatlas','season','rem']
COL={'native':'#ff6b6b','ocean':'#4e9bff','natres':'#3ddc97','dynatlas':'#f0a23b',
     'enumatlas':'#b06bff','season':'#8a98b5','rem':'#39435c'}
LAB={'native':'native_daily_sim','ocean':'ocean_currents','natres':'natural_resource',
     'dynatlas':'dyn_visual_atlas','enumatlas':'enum_atlas','season':'season_refresh','rem':'编排/未归并'}

# stacked polygons
cum=[0.0]*n
polys=[]
for k in ORDER:
    top=[cum[i]+layers[i][k] for i in range(n)]
    pts=[]
    for i in range(n): pts.append((sx(i),sy(top[i])))
    for i in range(n-1,-1,-1): pts.append((sx(i),sy(cum[i])))
    path='M'+' L'.join(f'{x:.1f},{y:.1f}' for x,y in pts)+' Z'
    polys.append((k,path))
    cum=top

# legend
leg=''.join(f'<span style="display:inline-block;margin-right:14px"><i style="background:{COL[k]};width:11px;height:11px;display:inline-block;border-radius:2px;margin-right:5px"></i>{LAB[k]}</span>' for k in ORDER)

# timeline (t_sus line)
line_pts=[(sx(i),sy(layers[i]['sus'])) for i in range(n)]
line_path='M'+' L'.join(f'{x:.1f},{y:.1f}' for x,y in line_pts)
budget_y=sy(budget)

avg=d['avg']
# dominant cost
dom=d['domcount']
dom_total=sum(dom.values())

# worst frames table
worst=d['worst']
wt=''
for w in worst:
    wt+=(f"<tr><td>{w['tick']}</td><td>{w['sus']:.2f}</td><td>{w['lslice']}</td>"
         f"<td>{w['native']:.2f}</td><td>{w['ocean']:.2f}</td><td>{w['enumatlas']:.2f}</td>"
         f"<td>{w['natres']:.2f}</td><td>{w['rem']:.2f}</td></tr>")

# job percentile bars
jobtab=d['jobtab']
def jobbar(name,mn,mean,p50,p90,p95,mx,nz):
    wbar=520; xoff=150
    scale=lambda v: xoff + wbar*(v/8.0)  # scale to 8ms reference
    return (f'<div style="margin:6px 0"><span style="display:inline-block;width:140px;color:#cdd6e4">{name}</span>'
            f'<svg width="{wbar+60}" height="22" style="vertical-align:middle">'
            f'<line x1="{xoff}" y1="11" x2="{xoff+wbar}" y2="11" stroke="#2a3250"/>'
            f'<rect x="{scale(0):.0f}" y="4" width="{scale(mx)-xoff:.0f}" height="14" rx="2" fill="#23304d"/>'
            f'<line x1="{scale(p50):.0f}" y1="2" x2="{scale(p50):.0f}" y2="20" stroke="#9be3b0" stroke-width="2"/>'
            f'<line x1="{scale(p90):.0f}" y1="2" x2="{scale(p90):.0f}" y2="20" stroke="#f0a23b" stroke-width="2"/>'
            f'<line x1="{scale(p95):.0f}" y1="2" x2="{scale(p95):.0f}" y2="20" stroke="#ff6b6b" stroke-width="2"/>'
            f'<text x="{scale(mx)+6:.0f}" y="15" fill="#e6edf6" font-size="11">max {mx:.2f}</text>'
            f'<text x="{xoff-4:.0f}" y="15" fill="#8b97ad" font-size="10" text-anchor="end">nz {nz}</text>'
            f'</svg></div>'
            f'<div style="margin:-2px 0 4px 140px;color:#8b97ad;font-size:10px">'
            f'均值 {mean:.2f} · p50 <span style="color:#9be3b0">{p50:.2f}</span> · p90 <span style="color:#f0a23b">{p90:.2f}</span> · p95 <span style="color:#ff6b6b">{p95:.2f}</span></div>')
jobbars=''.join(jobbar(*j) for j in jobtab)

# dominant cost summary
dom_html=''.join(f'<tr><td>{LAB.get(k,k)}</td><td>{v}</td><td>{v/dom_total*100:.1f}%</td></tr>' for k,v in sorted(dom.items(),key=lambda x:-x[1]))

cards=f"""
<div class="cards">
  <div class="card"><div class="k">FPS p95 / max</div><div class="v">{d and ''}</div></div>
</div>
"""
# rebuild cards properly
fps_p95='60'; fps_max='60'
cards=f"""
<div class="cards">
  <div class="card"><div class="k">FPS (p95/max)</div><div class="v">{fps_p95}/{fps_max}</div><div class="s">锁 60 帧</div></div>
  <div class="card"><div class="k">t_sus 均值 / p95 / 最大</div><div class="v">{d['sus_mean']:.2f} / {d['sus_p95']:.2f} / {d['sus_max']:.2f}</div><div class="s">ms / 帧</div></div>
  <div class="card"><div class="k">帧预算 / 越界帧</div><div class="v">{budget:.0f}ms / {d['over_budget']}</div><div class="s">{d['over_budget']}/{n} 帧越界</div></div>
  <div class="card"><div class="k">native+ocean 均值</div><div class="v">{avg['native']+avg['ocean']:.2f}ms</div><div class="s">占仿真 { (avg['native']+avg['ocean'])/avg['sus']*100:.0f}%</div></div>
</div>
"""

html=f"""<!doctype html><html lang="zh"><head><meta charset="utf-8"><style>
body{{background:#0f1320;color:#e6edf6;font-family:-apple-system,Segoe UI,Roboto,sans-serif;margin:0;padding:28px 34px;line-height:1.6}}
h1{{font-size:22px;margin:0 0 4px}} .sub{{color:#8b97ad;font-size:13px;margin-bottom:18px}}
h2{{font-size:16px;margin:26px 0 10px;border-left:3px solid #4e9bff;padding-left:10px}}
.cards{{display:flex;gap:14px;flex-wrap:wrap}} .card{{background:#171c2e;border:1px solid #252c42;border-radius:10px;padding:14px 18px;min-width:180px;flex:1}}
.card .k{{color:#8b97ad;font-size:12px}} .card .v{{font-size:20px;font-weight:600;margin:4px 0}} .card .s{{color:#8b97ad;font-size:12px}}
table{{border-collapse:collapse;width:100%;font-size:13px;margin-top:8px}} th,td{{border:1px solid #252c42;padding:6px 10px;text-align:left}}
th{{background:#171c2e;color:#8b97ad;font-weight:500}} tr:nth-child(even) td{{background:#141a2a}}
.warn{{background:#2a1f14;border:1px solid #6b4a1f;color:#f0c98b;padding:12px 16px;border-radius:8px;font-size:13px;margin:14px 0}}
.good{{background:#13251c;border:1px solid #2c5a40;color:#9be3b0;padding:12px 16px;border-radius:8px;font-size:13px;margin:14px 0}}
.rec{{background:#171c2e;border:1px solid #252c42;border-radius:8px;padding:12px 16px;margin:10px 0}} .rec b{{color:#4e9bff}}
code{{background:#0b0f1a;padding:1px 5px;border-radius:4px;color:#9bd0ff}}
.note{{color:#8b97ad;font-size:13px;margin:6px 0}}
</style></head><body>
<h1>逐帧耗时分布 · 弱机/移动端优化导向</h1>
<div class="sub">perf_record_20260707_202818.csv · {n} 帧 · 帧预算 {budget:.0f}ms · 目标：压低单帧仿真耗时以兼容更弱设备</div>

{cards}

<div class="good">单帧仿真（t_sus）均值 4.23ms，但弱机/移动端真正的风险是<b>尾部</b>：p95 5.88ms、最大 11.29ms。每帧时间 91% 由 <code>native_daily_sim</code>+<code>ocean_currents</code> 主导，其余作业与渲染占比极小。</div>

<h2>① 逐帧时间线（t_sus，红线=8ms 预算）</h2>
<svg viewBox="0 0 {W} {H}" width="100%" style="max-width:{W}px;background:#11162400">
<line x1="{x0}" y1="{budget_y:.0f}" x2="{x1}" y2="{budget_y:.0f}" stroke="#ff6b6b" stroke-dasharray="5 4" stroke-width="1.5"/>
<text x="{x1-4}" y="{budget_y-5:.0f}" fill="#ff6b6b" font-size="11" text-anchor="end">预算 {budget:.0f}ms</text>
<path d="{line_path}" fill="none" stroke="#f0a23b" stroke-width="1.2"/>
</svg>
<div class="note">横轴=连续 tick。多数帧贴近底部（&lt;6ms），少数尖峰击穿预算——这些尖峰是移动端掉帧/卡顿的根因。</div>

<h2>② 逐帧堆叠构成（每帧高度=该帧 t_sus，分段=各作业耗时）</h2>
<div style="margin:6px 0 10px">{leg}</div>
<svg viewBox="0 0 {W} {H}" width="100%" style="max-width:{W}px;background:#11162400">
<line x1="{x0}" y1="{budget_y:.0f}" x2="{x1}" y2="{budget_y:.0f}" stroke="#ff6b6b" stroke-dasharray="5 4" stroke-width="1.2"/>
{''.join(f'<path d="{p}" fill="{COL[k]}" fill-opacity="0.85"/>' for k,p in polys)}
</svg>
<div class="note">红段（native_daily_sim）与蓝段（ocean_currents）占满大部分帧；紫段（enum_atlas）只在零星帧突然拔高——即尖峰来源。</div>

<h2>③ 最重 14 帧明细</h2>
<table><tr><th>tick</th><th>t_sus</th><th>最大切片</th><th>native</th><th>ocean</th><th>enum_atlas</th><th>nat_res</th><th>其他</th></tr>{wt}</table>

<h2>④ 各作业尾部分布（绿=p50 橙=p90 红=p95，横轴 0–8ms）</h2>
{jobbars}
<div class="note">native_daily_sim 的 p90 已达 ~3ms、最大 7.79ms，是单帧上限的主要决定者；enum_atlas_upload 平时为 0，偶发 7.5ms 纯尖峰。</div>

<h2>⑤ 每帧"主导成本"归属</h2>
<table><tr><th>主导作业</th><th>帧数</th><th>占比</th></tr>{dom_html}</table>
<div class="note">449/491 帧的最重切片来自 native 或 ocean → 优化这两个即覆盖 91% 的帧。</div>

<h2>⑥ 弱机 / 移动端优化建议</h2>

<div class="rec"><b>1. 解耦仿真频率（最大的移动端杠杆）</b><br>
当前重仿真（native_daily_sim、ocean_currents）每帧全量跑。对弱机可改为 <code>60Hz 渲染 / 30Hz 仿真</code>：渲染帧跳过仿真、复用上一帧结果。这直接把单帧仿真预算需求砍半，是移动端保 60 渲染帧的首选。</div>

<div class="rec"><b>2. 主攻 native_daily_sim（单帧均值 1.65ms，尾部 7.79ms）</b><br>
其物理传递段 <code>phys_psi_init / phys_upwelling / phys_slp / phys_wind / wind_air</code> 是重核。弱机策略：① 远处/离大陆单元格用更粗网格或跳步（空间 LOD）；② 输入未变则跳过整段重算；③ 把单段再切成更小切片以压低 p95，避免单帧突刺。</div>

<div class="rec"><b>3. ocean_currents（单帧均值 1.06ms，p95 2.35ms）</b><br>
同属物理求解器，与②共用 LOD/跳步/缓存。两者合计占仿真 ~69%（按均值）、且是 91% 帧的主导项，是性价比最高的两个优化点。</div>

<div class="rec"><b>4. 熨平 atlas 上传尖峰</b><br>
<code>enum_atlas_upload</code> 平时 0ms、偶发 7.5ms，属事件型 GPU atlas 重建——单帧 7.5ms 足以在移动端造成可见卡顿。建议：预分配 atlas 容量避免重建、或把重建拆成多帧小 chunk、或挪到独立线程/延迟提交。</div>

<div class="rec"><b>5. 建立"画质档位"开关</b><br>
用本数据作基线，定义三档：桌面（当前）、弱机（仿真 30Hz + 远处 LOD）、移动（30Hz + 跳过非关键物理段 + atlas 节流）。把 <code>sim_slice_budget_ms</code>(3) 与 <code>sim_frame_budget_ms</code>(8) 设为随档位可调，而非硬编码。</div>

<div class="rec"><b>6. 先修埋点 aliasing（阻塞性）</b><br>
<code>bd_climate_*</code> 与 <code>bd_weather_*</code> 两列族数值完全相同，气候/天气真实拆分不可信。在投入束内微优化前，先让 weather 读取自身计时器，否则优化目标将是盲的。</div>

<div class="note" style="margin-top:24px">附注：渲染 0.10ms、UI 0.38ms 占比极小，弱机瓶颈在仿真而非渲染；但移动端 GPU atlas 上传（enum_atlas/dyn_atlas）属 CPU↔GPU 同步，仍是风险点。</div>
</body></html>
"""
with open('D:/Godot/ProjectKeynes/Project.Keynes/tmp/perf_perframe_report.html','w',encoding='utf-8') as f:
    f.write(html)
print("written perf_perframe_report.html bytes=",len(html))
