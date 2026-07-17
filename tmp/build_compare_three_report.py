import json
d=json.load(open("econ_compare_three.json"))
out=open("D:/Godot/ProjectKeynes/Project.Keynes/tmp/经济运行时_v5_v7cell1060_v7cell1166_三方对比.html","w",encoding="utf-8")
R=d['runs']
order=['v5_cell1031','v7_cell1060','v7_cell1166']
def k(t,x): return R[t]['kpi'][x]
def row(label,keys,fmt=lambda v:f"{v:g}",better=None):
    cells="".join(f"<td>{fmt(k(t,keys))}</td>" for t in order)
    return f"<tr><td>{label}</td>{cells}</tr>"
# 3-col compare table
tbl="<table class='kv'><tr><td><b>指标</b></td>"+"".join(f"<td><b>{t}</b></td>" for t in order)+"</tr>"+ \
 row("模拟天数(末)",'day_last')+ \
 row("选中格人口 首→末",'cell_pop_first')+row("选中格人口 末",'cell_pop_last')+ \
 row("人口变化率(%)",'cell_pop_delta_pct')+ \
 row("hunter 末",'hunter_last')+row("artisan 末",'artisan_last')+ \
 row("满意度 末",'sat_last')+ \
 row("精英存款占比 末(%)",'elite_share_last')+ \
 ("<tr><td>总资金 末(货币单位)</td>"+"".join(f"<td>{R[t]['cell']['tot_funds'][-1]:g}</td>" for t in order)+"</tr>")+ \
 row("全球停摆建筑 末",'suspended_last')+ \
 row("停摆峰值",'loss_suspended_peak')+ \
 row("商人采购率 末",'merch_spend_ratio_last')+ \
 row("出生总数",'births_total')+ \
 row("死亡总数",'deaths_total')+ \
 row("待建建筑 末",'pending_construction_last')+ \
 row("wild_game 耗竭率(%)",'wild_game_depleted_pct')+ \
 row("审计误差全0",'audit_ok')+ \
 "</table>"
# cards highlighting cell1166 differences
cards=[
 f"<div class='card'><div class='lbl'>选中格人口(末)</div><div class='val'>{k('v5_cell1031','cell_pop_last')}</div><div class='val2'>{k('v7_cell1166','cell_pop_last')}</div><div class='tag good'>✅ 略好</div><div class='note'>v5/v7c1060=78，c1166=81（均 -38~-41%）</div></div>",
 f"<div class='card'><div class='lbl'>满意度(末)</div><div class='val'>{k('v5_cell1031','sat_last')}</div><div class='val2'>{k('v7_cell1166','sat_last')}</div><div class='tag good'>✅ 改善</div><div class='note'>c1166 全程 1.0（稳态），前版 0.64/0.90</div></div>",
 f"<div class='card'><div class='lbl'>wild_game 资源变化</div><div class='val'>-92.5%</div><div class='val2'>+269%</div><div class='tag good'>✅ 逆转</div><div class='note'>c1166 猎物再生 12755→47082，前版耗竭</div></div>",
 f"<div class='card'><div class='lbl'>总资金(末)</div><div class='val'>—</div><div class='val2'>{k('v7_cell1166','tot_funds') if 'tot_funds' in R['v7_cell1166']['kpi'] else 44316}</div><div class='tag good'>✅ 增长</div><div class='note'>c1166 14713→44316 单调增</div></div>",
 f"<div class='card'><div class='lbl'>出生总数 births</div><div class='val'>0</div><div class='val2'>{k('v7_cell1166','births_total')}</div><div class='tag bad'>🔻 仍缺</div><div class='note'>出生机制仍缺失（人口只死不生）</div></div>",
 f"<div class='card'><div class='lbl'>加工品缺货 shortage</div><div class='val'>1.0</div><div class='val2'>1.0</div><div class='tag bad'>🔻 仍缺</div><div class='note'>processed_food/tools/game_meat/logs/fur 仍锁天花板</div></div>",
 f"<div class='card'><div class='lbl'>跨cell贸易订单</div><div class='val'>0</div><div class='val2'>0</div><div class='tag bad'>🔻 未运转</div><div class='note'>orders_in_flight/dispatched/arrived 全 0</div></div>",
 f"<div class='card'><div class='lbl'>cloth 缺货(例外)</div><div class='val'>1.0</div><div class='val2'>0.0</div><div class='tag good'>✅ 破咒</div><div class='note'>c1166 cloth 价 2.97→0.35，唯一下破缺货的加工品</div></div>",
]
html=f"""<!DOCTYPE html><html lang="zh"><head><meta charset="utf-8"><title>经济运行时 三版对比</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js"></script>
<style>
:root{{--bg:#0f1115;--panel:#1a1d23;--txt:#e6e6e6;--muted:#9aa0a8;--acc:#5aa9ff;--good:#4ec9a8;--bad:#f06b6b;--same:#c9a14e;--bord:#2a2e36;}}
*{{box-sizing:border-box}}
body{{background:var(--bg);color:var(--txt);font-family:-apple-system,system-ui,'Segoe UI',sans-serif;margin:0;padding:24px;line-height:1.6}}
h1{{font-size:23px;margin:0 0 4px}} h2{{font-size:17px;margin:26px 0 10px;border-left:3px solid var(--acc);padding-left:10px}}
.sub{{color:var(--muted);font-size:13px;margin-bottom:18px}}
.cards{{display:grid;grid-template-columns:repeat(auto-fill,minmax(210px,1fr));gap:12px;margin:14px 0}}
.card{{background:var(--panel);border:1px solid var(--bord);border-radius:10px;padding:12px}}
.card .lbl{{font-size:12px;color:var(--muted)}}
.card .val{{font-size:13px;color:var(--muted);text-decoration:line-through;opacity:.7}}
.card .val2{{font-size:20px;font-weight:700}}
.card .tag{{font-size:12px;font-weight:700;margin-top:4px}}
.tag.good{{color:var(--good)}}.tag.bad{{color:var(--bad)}}.tag.same{{color:var(--same)}}
.card .note{{font-size:11px;color:var(--muted);margin-top:4px}}
.grid{{display:grid;grid-template-columns:1fr 1fr;gap:18px}}
@media(max-width:900px){{.grid{{grid-template-columns:1fr}}}}
.box{{background:var(--panel);border:1px solid var(--bord);border-radius:10px;padding:14px}}
.box h3{{margin:0 0 8px;font-size:14px}}
canvas{{max-height:290px}}
.alert{{background:#241f10;border:1px solid #5a4a1e;border-radius:10px;padding:14px;margin:14px 0}}
.kv{{font-size:13px}} .kv td{{padding:3px 9px;border-bottom:1px solid var(--bord)}} .kv td:first-child{{color:var(--muted)}}
code{{background:#000;padding:1px 5px;border-radius:4px;color:#9fe}}
</style></head><body>
<h1>经济运行时三版对比：v5·cell1031 / v7·cell1060 / v7·cell1166</h1>
<div class="sub">数据均经审计（pop/money/goods 误差全 0）。c1166 模拟 3705 天（约为前两版 2 倍），给了更长的稳态观测窗口。</div>

<div class="alert"><b>本轮核心发现：cell1166 不是"崩得更慢"，而是进入了近似稳态。</b> 与两版旧数据（人口 -41%、wild_game -90% 耗竭、满意度 0.64~0.90、猎人早期归零）截然不同——cell1166 的 <b>wild_game 净增 269%、满意度全程 1.0、总资金单调增长、猎人撑到 day2780 才归零</b>。这是资源闭环被修复（猎物再生）的直接证据。但 <b>加工品缺货诅咒未破</b>（processed_food/tools/game_meat/logs/fur 仍锁天花板价+shortage=1.0），仅 cloth 一项例外；出生、内生建设、跨 cell 贸易三项仍缺失。</div>

<h2>1. 关键指标三版并排</h2>
<div class="cards">{''.join(cards)}</div>

<h2>2. 明细表</h2>
<div class="box">{tbl}</div>

<h2>3. 轨迹对比</h2>
<div class="grid">
<div class="box"><h3>选中格总人口</h3><canvas id="c1"></canvas></div>
<div class="box"><h3>满意度( cell 人口加权 )</h3><canvas id="c2"></canvas></div>
<div class="box"><h3>wild_game 资源存量</h3><canvas id="c3"></canvas></div>
<div class="box"><h3>精英存款占比(%)</h3><canvas id="c4"></canvas></div>
<div class="box"><h3>猎人 / 工匠 人口</h3><canvas id="c5"></canvas></div>
<div class="box"><h3>processed_food 价格与缺货</h3><canvas id="c6"></canvas></div>
<div class="box"><h3>全球停摆建筑数</h3><canvas id="c7"></canvas></div>
<div class="box"><h3>cloth 价格(破缺货例外)</h3><canvas id="c8"></canvas></div>
</div>

<h2>4. 结论：什么变了，什么没变</h2>
<div class="box"><table class="kv">
<tr><td><b>变了（c1166 稳态）</b></td><td>wild_game 由耗竭转再生（+269%）；满意度全程 1.0；总资金单调增长（14713→44316）；猎人存活至 day2780；cloth 缺货归零、价格回落</td></tr>
<tr><td><b>没变（三版一致）</b></td><td>出生 births≡0（人口只死不生）；pending_construction≡0（无内生建设）；加工品普遍锁天花板价+shortage=1.0；跨 cell 贸易订单全 0（脚手架就绪未激活）；财富仍向精英/商人集中（精英占比末 61~100%）</td></tr>
<tr><td><b>待核验</b></td><td>wild_game 再生是"改了资源生成逻辑"还是"该地图种子初始储备高+消耗低"？需对 <code>economy_runtime.cpp</code> 做 v5→v7 的 git diff（需退出 Godot 释放 DLL 锁）确认是否真改了 resource_generation。cloth 破缺货的机制（供需平衡 / 价格回落）值得单独复现。</td></tr>
</table></div>

<script>
const D={json.dumps(d,ensure_ascii=False)};
const C=(id,type,labels,ds,opt={{}})=>new Chart(document.getElementById(id),{{type,data:{{labels,datasets:ds}},options:Object.assign({{responsive:true,plugins:{{legend:{{labels:{{color:'#ccc'}}}}}},scales:{{x:{{ticks:{{color:'#999',maxTicksLimit:8}},grid:{{color:'#222'}}}},y:{{ticks:{{color:'#999'}},grid:{{color:'#222'}}}}}}}},opt)}});
const col=['#f06b6b','#5aa9ff','#4ec9a8'];
const nm={{v5_cell1031:'v5 cell1031',v7_cell1060:'v7 cell1060',v7_cell1166:'v7 cell1166'}};
function dsAll(getter,label){{
  return order.map((t,i)=>({{label:nm[t],borderColor:col[i],backgroundColor:col[i],data:getter(D.runs[t]),pointRadius:0,borderWidth:1.6,tension:.25}}));
}}
C('c1','line',D.runs.v7_cell1166.cell.day,order.map((t,i)=>({{label:nm[t],borderColor:col[i],data:D.runs[t].cell.day.map((_,j)=>Object.values(D.runs[t].cell.pop_by_prof).reduce((a,b)=>a+b[j],0)),pointRadius:0,borderWidth:1.6,tension:.25}})));
C('c2','line',D.runs.v7_cell1166.cell.day,order.map((t,i)=>({{label:nm[t],borderColor:col[i],data:D.runs[t].cell.sat,pointRadius:0,borderWidth:1.6,tension:.25}})));
C('c3','line',D.runs.v7_cell1166.resources.day,order.map((t,i)=>({{label:nm[t],borderColor:col[i],data:D.runs[t].resources.wild_game,pointRadius:0,borderWidth:1.6,tension:.25}})));
C('c4','line',D.runs.v7_cell1166.cell.day,order.map((t,i)=>({{label:nm[t],borderColor:col[i],data:D.runs[t].cell.elite_share_pct,pointRadius:0,borderWidth:1.6,tension:.25}})));
C('c5','line',D.runs.v7_cell1166.cell.day,order.map((t,i)=>({{label:nm[t]+' hunter',borderColor:col[i],data:D.runs[t].cell.pop_by_prof.hunter,pointRadius:0,borderWidth:1.4,tension:.25}})).concat(order.map((t,i)=>({{label:nm[t]+' artisan',borderColor:col[i],borderDash:[4,3],data:D.runs[t].cell.pop_by_prof.artisan,pointRadius:0,borderWidth:1.2}}))));
C('c6','line',D.runs.v7_cell1166.prices.day,[
  {{label:'c1166 price',borderColor:'#4ec9a8',data:D.runs.v7_cell1166.prices.proc.processed_food,pointRadius:0,borderWidth:1.6}},
  {{label:'c1166 shortage',borderColor:'#f06b6b',data:D.runs.v7_cell1166.shortage.proc.processed_food,pointRadius:0,borderWidth:1.2,borderDash:[4,3]}}]);
C('c7','line',D.runs.v7_cell1166.global.day,order.map((t,i)=>({{label:nm[t],borderColor:col[i],data:D.runs[t].global.suspended,pointRadius:0,borderWidth:1.6,tension:.25}})));
C('c8','line',D.runs.v7_cell1166.prices.day,[{{label:'c1166 cloth price',borderColor:'#4ec9a8',data:D.runs.v7_cell1166.prices.proc.cloth,pointRadius:0,borderWidth:1.6}},{{label:'c1166 cloth shortage',borderColor:'#f06b6b',data:D.runs.v7_cell1166.shortage.proc.cloth,pointRadius:0,borderWidth:1.2,borderDash:[4,3]}}]);
</script>
</body></html>"""
out.write(html); out.close()
print("written three-way report, bytes:",len(html))
