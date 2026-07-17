import json
d=json.load(open("econ_compare_v5_v7.json"))
out=open("D:/Godot/ProjectKeynes/Project.Keynes/tmp/经济运行时_v5_v7_对比报告.html","w",encoding="utf-8")
v5,k5=d['runs']['v5'],d['runs']['v5']['kpi']
v7,k7=d['runs']['v7'],d['runs']['v7']['kpi']
def cmp_card(label,va,vb,unit='',better_high=True,note='',is_str=False):
    if is_str:
        if str(va)==str(vb): tag,cls='➖ 持平','same'
        else:
            tag,cls=('✅ 改善','good') if bool(vb)==better_high else ('🔻 恶化','bad')
        vaf,vbf=str(va),str(vb)
    else:
        ka,kb=float(va),float(vb)
        if abs(ka-kb)<1e-9: tag,cls='➖ 持平','same'
        else:
            improved=(kb>ka)==better_high
            tag=('✅ 改善' if improved else '🔻 恶化'); cls='good' if improved else 'bad'
        vaf=f"{va:g}{unit}"; vbf=f"{vb:g}{unit}"
    return f"<div class='card'><div class='lbl'>{label}</div><div class='val'>{vaf}</div><div class='val2'>{vbf}</div><div class='tag {cls}'>{tag}</div><div class='note'>{note}</div></div>"

cards=[
 cmp_card("选中格人口(首→末)",k5['cell_pop_first'],k5['cell_pop_last'],"→","同款崩塌",note="v5/v7 同 133→78"),
 cmp_card("人口变化率(%)",k5['cell_pop_delta_pct'],k7['cell_pop_delta_pct'],"%",note="完全一致 -41.4%"),
 cmp_card("出生总数(births)",k5['births_total'],k7['births_total'],"",better_high=True,note="仍恒为 0 — 出生机制未实现"),
 cmp_card("待建建筑(pending)",k5['pending_construction_last'],k7['pending_construction_last'],"",better_high=True,note="仍 0 — 无内生建设"),
 cmp_card("wild_game 耗竭(%)",k5['wild_game_depleted_pct'],k7['wild_game_depleted_pct'],"%",better_high=False,note="消耗型资源仍不可持续"),
 cmp_card("全球停摆建筑(loss_suspended)",k5['suspended_last'],k7['suspended_last'],"",better_high=False,note="v7 多格崩塌放大 42 倍"),
 cmp_card("精英存款占比(末)",k5['elite_share_last'],k7['elite_share_last'],"%",better_high=False,note="v7 降因建筑停摆抽干基数,非健康回流"),
 cmp_card("商人采购率(末)",k5['merch_spend_ratio_last'],k7['merch_spend_ratio_last'],"",better_high=True,note="v7 明显回升 0.18%→10%"),
 cmp_card("商人囤积(末,货币单位)",k5['merch_reserved_last'],k7['merch_reserved_last'],"",better_high=False,note="v7 囤积略降"),
 cmp_card("审计误差(pop/money/goods)",str(k5['audit_pop_ok']),str(k7['audit_pop_ok']),'',better_high=True,note="两版均全 0 — 数据可信",is_str=True),
]
html=f"""<!DOCTYPE html><html lang="zh"><head><meta charset="utf-8"><title>经济运行时 v5 vs v7 对比报告</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js"></script>
<style>
:root{{--bg:#0f1115;--panel:#1a1d23;--txt:#e6e6e6;--muted:#9aa0a8;--acc:#5aa9ff;--good:#4ec9a8;--bad:#f06b6b;--same:#c9a14e;--bord:#2a2e36;}}
*{{box-sizing:border-box}}
body{{background:var(--bg);color:var(--txt);font-family:-apple-system,system-ui,'Segoe UI',sans-serif;margin:0;padding:24px;line-height:1.6}}
h1{{font-size:24px;margin:0 0 4px}} h2{{font-size:18px;margin:28px 0 10px;border-left:3px solid var(--acc);padding-left:10px}}
.sub{{color:var(--muted);font-size:13px;margin-bottom:18px}}
.cards{{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:12px;margin:14px 0}}
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
canvas{{max-height:300px}}
.alert{{background:#2a1d1d;border:1px solid #5a2e2e;border-radius:10px;padding:14px;margin:14px 0}}
.alert.warn{{background:#241f10;border-color:#5a4a1e}}
.kv{{font-size:13px}} .kv td{{padding:3px 10px;border-bottom:1px solid var(--bord)}}
code{{background:#000;padding:1px 5px;border-radius:4px;color:#9fe}}
</style></head><body>
<h1>经济运行时：v5 → v7 修改后对比分析</h1>
<div class="sub">数据：v5=cell1031(q3,r17, day5→1930) ｜ v7=cell1060(q32,r17, day5→1820) ｜ 审计误差全 0，数据可信</div>
<div class="alert"><b>核心结论：v7 并未修复经济核心逻辑。</b> 选中格的人口崩塌轨迹与 v5 <b>逐点相同</b>（133→78，hunter/artisan 归零，births 仍 0，wild_game 仍 -90%）。v7 新增的是<b>世界级多格模拟框架</b>与<b>跨 cell 贸易脚手架</b>，但二者均未改变 cell 级经济行为：贸易订单全 0（未实际运转），出生/内生建设仍缺失。</div>

<h2>1. 关键指标对比（v5 → v7）</h2>
<div class="cards">{''.join(cards)}</div>

<h2>2. 趋势对比</h2>
<div class="grid">
<div class="box"><h3>全局劳动力（owner+employee）</h3><canvas id="c1"></canvas></div>
<div class="box"><h3>全球停摆建筑数 loss_suspended</h3><canvas id="c2"></canvas></div>
<div class="box"><h3>选中格人口（按职业）</h3><canvas id="c3"></canvas></div>
<div class="box"><h3>精英存款占比(%)</h3><canvas id="c4"></canvas></div>
<div class="box"><h3>商人采购：预算 vs 花费(货币单位)</h3><canvas id="c5"></canvas></div>
<div class="box"><h3>加工品价格（processed_food / game_meat）</h3><canvas id="c6"></canvas></div>
<div class="box"><h3>初级品价格（gathered_plants / fish）</h3><canvas id="c7"></canvas></div>
<div class="box"><h3>wild_game 资源存量</h3><canvas id="c8"></canvas></div>
</div>

<h2>3. v7 新增：跨 cell 贸易（脚手架已建，未运转）</h2>
<div class="box"><table class="kv">
<tr><td>trade_runtime_mode</td><td>{v7['trade']['trade_runtime_mode'][-1]}</td></tr>
<tr><td>trade_topology_ready</td><td>{v7['trade']['trade_topology_ready'][-1]}</td></tr>
<tr><td>trade_topology_generation</td><td>{v7['trade']['trade_topology_generation'][-1]}</td></tr>
<tr><td>trade_country_generation</td><td>{v7['trade']['trade_country_generation'][-1]}</td></tr>
<tr><td>trade_orders_in_flight</td><td>{v7['trade']['trade_orders_in_flight'][-1]}</td></tr>
<tr><td>trade_orders_dispatched</td><td>{v7['trade']['trade_orders_dispatched'][-1]}</td></tr>
<tr><td>trade_orders_arrived</td><td>{v7['trade']['trade_orders_arrived'][-1]}</td></tr>
<tr><td>trade_candidates_accepted</td><td>{v7['trade']['trade_candidates_accepted'][-1]}</td></tr>
<tr><td>trade_capacity_available</td><td>{v7['trade']['trade_capacity_available'][-1]:.3e}</td></tr>
</table>
<div class="sub">所有订单/在途指标全程为 0 —— 拓扑与国家已生成，但没有任何贸易订单被派发或到达。贸易系统处于"就绪但未激活"状态。</div>
</div>

<h2>4. 与 v5 对比：改了什么，没改什么</h2>
<div class="box"><table class="kv">
<tr><td><b>未改变（cell 级经济逻辑）</b></td><td>人口 -41.4% 同款；births 恒 0；pending_construction 恒 0；wild_game -90% 耗竭；加工品锁天花板价 + shortage=1.0；初级品压地板价；hunter/artisan 归零</td></tr>
<tr><td><b>新出现（v7 框架层面）</b></td><td>世界级多格模拟 → 全局停摆建筑 52→2206；跨 cell 贸易脚手架（拓扑/国家就绪，但 0 订单）；精英占比终点降到 38.2%（因建筑停摆抽干生产者存款基数，非健康回流）；商人采购率升到 10%</td></tr>
<tr><td><b>源码层面印证</b></td><td><code>economy_runtime.cpp:7782</code> <code>_births=0</code> 且 <code>market_result.births</code> 从未被赋值 → 出生机制仍缺失；贸易订单 <code>dispatch_trade_candidates</code> 虽存在但 candidates_accepted=0</td></tr>
</table></div>

<div class="alert warn"><b>建议使用本报告的下一步：</b>若你期望 v7 是"修复版"，那么从数据看修复未生效（cell 级轨迹与 v5 逐点重合）。需要落实的三项根因仍原样存在：① 出生机制（births 恒 0，人口只死不生）；② 内生建设（pending_construction 恒 0，产能塌缩不可自修复）；③ 财富单向虹吸 + 价格无刹车。第 ④ 跨 cell 贸易需先让其真正派发订单（当前 0 成交）。</div>

<script>
const D={json.dumps(d,ensure_ascii=False)};
const C=(id,type,labels,ds,opt={{}})=>new Chart(document.getElementById(id),{{type,data:{{labels,datasets:ds}},options:Object.assign({{responsive:true,plugins:{{legend:{{labels:{{color:'#ccc'}}}}}},scales:{{x:{{ticks:{{color:'#999'}},grid:{{color:'#222'}}}},y:{{ticks:{{color:'#999'}},grid:{{color:'#222'}}}}}}}},opt)}});
function ds(name,color,arr){{return {{label:name,borderColor:color,backgroundColor:color,data:arr,pointRadius:0,borderWidth:1.5,tension:.3}}}}
const v5d=D.runs.v5.global.day, v7d=D.runs.v7.global.day;
const v5c=D.runs.v5.cell, v7c=D.runs.v7.cell;
C('c1','line',v5d,[ds('v5 劳动力','#f06b6b',D.runs.v5.global.labor_total),ds('v7 劳动力','#5aa9ff',D.runs.v7.global.labor_total)]);
C('c2','line',v5d,[ds('v5 停摆','#7a3a3a',D.runs.v5.global.suspended),ds('v7 停摆','#f06b6b',D.runs.v7.global.suspended)]);
const profs=['forager','fisher','hunter','artisan','merchant','miner'];
C('c3','line',v7c.day,profs.map((p,i)=>ds('v7 '+p,['#5aa9ff','#4ec9a8','#f06b6b','#c9a14e','#b48cff','#e0a96d'][i],v7c.pop_by_prof[p])));
C('c4','line',v7c.day,[ds('v5 精英%','#f06b6b',v5c.elite_share_pct),ds('v7 精英%','#5aa9ff',v7c.elite_share_pct)]);
C('c5','line',v7d,[ds('v7 预算','#c9a14e',D.runs.v7.global.merch_budget),ds('v7 花费','#4ec9a8',D.runs.v7.global.merch_spent)]);
C('c6','line',D.runs.v7.prices.day,[ds('v5 processed_food','#f06b6b',D.runs.v5.prices.proc.processed_food),ds('v7 processed_food','#5aa9ff',D.runs.v7.prices.proc.processed_food),ds('v7 game_meat','#4ec9a8',D.runs.v7.prices.proc.game_meat)]);
C('c7','line',D.runs.v7.prices.day,[ds('v7 gathered_plants','#5aa9ff',D.runs.v7.prices.raw.gathered_plants),ds('v7 fish','#4ec9a8',D.runs.v7.prices.raw.fish)]);
C('c8','line',D.runs.v7.resources.day,[ds('v5 wild_game','#f06b6b',D.runs.v5.resources.wild_game),ds('v7 wild_game','#5aa9ff',D.runs.v7.resources.wild_game)]);
</script>
</body></html>"""
out.write(html); out.close()
print("written compare report, bytes:",len(html))
