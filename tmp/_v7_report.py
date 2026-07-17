# -*- coding: utf-8 -*-
import json
with open(r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\_v7_data.json","r",encoding="utf-8") as f:
    data=f.read()

HTML=r"""<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>Project.Keynes 经济运行时 v7 复诊报告</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js"></script>
<style>
:root{--bg:#0d1117;--panel:#161b22;--panel2:#1c2230;--border:#2d3542;--txt:#e6edf3;--dim:#9aa7b4;--accent:#58a6ff;--red:#f85149;--green:#3fb950;--amber:#d29922;--purple:#bc8cff;--cyan:#39c5cf;--pink:#f778ba}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--txt);font-family:-apple-system,"Segoe UI","Microsoft YaHei",sans-serif;line-height:1.7;font-size:15px}
.wrap{max-width:1180px;margin:0 auto;padding:32px 24px 80px}
header{border-bottom:1px solid var(--border);padding-bottom:24px;margin-bottom:28px}
h1{font-size:29px;font-weight:700;letter-spacing:-.5px;background:linear-gradient(90deg,#3fb950,#58a6ff);-webkit-background-clip:text;background-clip:text;-webkit-text-fill-color:transparent}
.sub{color:var(--dim);margin-top:10px;font-size:14px}
.meta{display:flex;gap:20px;flex-wrap:wrap;margin-top:14px;font-size:13px;color:var(--dim)}
.meta span b{color:var(--accent)}
h2{font-size:22px;margin:44px 0 8px;padding-left:12px;border-left:4px solid var(--accent);font-weight:650}
h3{font-size:17px;margin:24px 0 10px;color:var(--cyan)}
p{margin:10px 0;color:#d7dee6}
.card{background:var(--panel);border:1px solid var(--border);border-radius:12px;padding:20px 22px;margin:18px 0}
.verdict{display:flex;align-items:center;gap:14px;background:linear-gradient(135deg,#12210f,#0e1a10);border:1px solid #2c5c26;border-radius:12px;padding:18px 22px;margin:20px 0}
.verdict.mix{background:linear-gradient(135deg,#211d0f,#1a160e);border-color:#5c5226}
.verdict .big{font-size:34px}.verdict .t b{font-size:18px}
.verdict .t b.g{color:var(--green)}.verdict .t b.a{color:var(--amber)}
.kpis{display:grid;grid-template-columns:repeat(4,1fr);gap:14px;margin:22px 0}
.kpi{background:var(--panel);border:1px solid var(--border);border-radius:10px;padding:16px}
.kpi .v{font-size:24px;font-weight:700}.kpi .l{color:var(--dim);font-size:12.5px;margin-top:4px}.kpi .d{font-size:12px;margin-top:6px}
.down{color:var(--red)}.up{color:var(--green)}.flat{color:var(--amber)}
.chart-box{background:var(--panel);border:1px solid var(--border);border-radius:12px;padding:18px 20px;margin:20px 0}
.chart-box .cap{font-size:13px;color:var(--dim);margin-bottom:12px}.chart-box .cap b{color:var(--txt)}
.grid2{display:grid;grid-template-columns:1fr 1fr;gap:20px}
canvas{max-height:290px}
ul{margin:10px 0 10px 4px;list-style:none}
li{margin:8px 0;padding-left:22px;position:relative;color:#d7dee6}
li:before{content:"▸";position:absolute;left:0;color:var(--accent)}
.bad:before{content:"✕";color:var(--red)}.good:before{content:"✓";color:var(--green)}.warn:before{content:"!";color:var(--amber);font-weight:700}
table{width:100%;border-collapse:collapse;margin:14px 0;font-size:13px}
th,td{padding:8px 10px;text-align:right;border-bottom:1px solid var(--border)}
th{color:var(--dim);font-weight:600}th:first-child,td:first-child{text-align:left}
tr:hover td{background:var(--panel2)}
.tag{display:inline-block;padding:2px 8px;border-radius:6px;font-size:12px;font-weight:600}
.tag.stop{background:#3d1518;color:#f85149}.tag.ok{background:#132d1c;color:#3fb950}.tag.idle{background:#2d2410;color:#d29922}
.callout{border-left:3px solid var(--amber);background:#1e1a10;padding:12px 16px;border-radius:0 8px 8px 0;margin:14px 0;color:#e8dcc0;font-size:14px}
.callout.red{border-color:var(--red);background:#1e1012;color:#f0c9c9}
.callout.green{border-color:var(--green);background:#101e13;color:#c9f0d2}
.callout.blue{border-color:var(--accent);background:#0f1826;color:#c4d8f0}
code{background:#22283180;padding:1px 6px;border-radius:5px;font-family:Consolas,monospace;font-size:13px;color:var(--pink)}
.ref{color:var(--dim);font-size:12px}
.fix{background:var(--panel);border:1px solid var(--border);border-left:4px solid var(--green);border-radius:0 10px 10px 0;padding:14px 18px;margin:14px 0}
.fix .h{font-weight:650;color:var(--green);margin-bottom:6px}
.pri{display:inline-block;font-size:11px;padding:1px 7px;border-radius:5px;margin-right:8px;font-weight:700}
.p0{background:#3d1518;color:#f85149}.p1{background:#2d2410;color:#d29922}.p2{background:#0f2233;color:#58a6ff}
.cmp{display:grid;grid-template-columns:2fr 1fr 1fr 1fr;gap:0;font-size:13.5px;border:1px solid var(--border);border-radius:10px;overflow:hidden;margin:18px 0}
.cmp>div{padding:10px 14px;border-bottom:1px solid var(--border)}
.cmp .hd{background:var(--panel2);color:var(--dim);font-weight:600}
.cmp .rowh{text-align:left}
.foot{margin-top:50px;padding-top:20px;border-top:1px solid var(--border);color:var(--dim);font-size:12.5px}
@media(max-width:820px){.kpis{grid-template-columns:repeat(2,1fr)}.grid2{grid-template-columns:1fr}.cmp{grid-template-columns:2fr 1fr 1fr}}
</style></head><body><div class="wrap">
<header>
<h1>经济运行时 v7 复诊报告 · 与 v5 对比</h1>
<div class="sub">石器时代单格经济（cell 1060）· 364 个采样周期 · 游戏日 5 → 1820（约 5 游戏年）</div>
<div class="meta"><span>数据源 <b>v7_140702_cell1060</b></span><span>对照 <b>v5_114418_cell1031</b></span><span>守恒误差 <b>全 0</b></span><span>新增 <b>births/deaths·贸易系统·贵金属货币</b> 字段</span></div>
</header>

<div class="verdict mix">
<div class="big">⚖️</div>
<div class="t"><b class="a">总体：方向正确，部分见效，但三大 P0 中仅"防榨干"生效，"出生"与"贸易"两大新框架仍是空转。</b><br>
<span style="color:var(--dim)">v7 明显改善了财富极化与满意度，生产者不再被榨干到 0；但人口仍只死不生，产业链断裂原样复现，跨格贸易一单未成。</span></div>
</div>

<div class="kpis">
<div class="kpi"><div class="v flat">133→78</div><div class="l">cell 总人口</div><div class="d flat">与 v5 完全相同 · 无改善</div></div>
<div class="kpi"><div class="v up">61.8%</div><div class="l">生产者财富占比(末)</div><div class="d up">v5 仅 0.1% → 大幅改善</div></div>
<div class="kpi"><div class="v up">0.90</div><div class="l">满意度(末)</div><div class="d up">v5 0.64 · 后期回升</div></div>
<div class="kpi"><div class="v down">0 / 0</div><div class="l">累计出生 / 贸易到货</div><div class="d down">两大新框架未生效</div></div>
</div>

<h2>一、v5 → v7 关键指标对照</h2>
<div class="cmp">
<div class="hd rowh">指标</div><div class="hd">v5 (cell1031)</div><div class="hd">v7 (cell1060)</div><div class="hd">结论</div>
<div class="rowh">cell 总人口 首→末</div><div>133 → 78</div><div>133 → 78</div><div style="color:var(--amber)">持平 · 未改善</div>
<div class="rowh">全局在岗人口 首→末</div><div>12.94万 → 5.59万</div><div>12.96万 → 6.95万</div><div style="color:var(--green)">↑ 末期高 24%</div>
<div class="rowh">生产者财富占比 首→末</div><div>81.3% → 0.1%</div><div>87.6% → 61.8%</div><div style="color:var(--green)">✓ 极化大幅缓解</div>
<div class="rowh">满意度 首→末</div><div>1.00 → 0.64（跌）</div><div>0.76 → 0.90（升）</div><div style="color:var(--green)">✓ 逆转为回升</div>
<div class="rowh">出生机制</div><div>无字段</div><div>有字段, births≡0</div><div style="color:var(--red)">✕ 逻辑未接通</div>
<div class="rowh">跨格贸易</div><div>无</div><div>有框架, 0 成交</div><div style="color:var(--red)">✕ 空转</div>
<div class="rowh">产业链成品(石器/肉/布)</div><div>断供顶格</div><div>断供顶格</div><div style="color:var(--red)">✕ 原样复现</div>
</div>

<h2>二、明显改善的地方 ✓</h2>
<div class="card">
<ul>
<li class="good"><b>财富极化被有效遏制</b>：v5 生产者财富占比崩到 0.1%（被彻底榨干），v7 稳定在 <b>61.8%</b>。末期生产者阶层（prof8）甚至持有 1.3 亿资金。说明本轮针对"货币单向虹吸"的改动起作用了——生产者的钱不再被商人全部抽走。</li>
<li class="good"><b>满意度从单调恶化逆转为回升</b>：v5 是 1.0→0.64 一路跌；v7 前期跌到 0.67 后<b>持续回升到 0.90</b>。活下来的人口生活质量在改善，worst_need 稳定在 produce（果蔬）而非恶化到主食。</li>
<li class="good"><b>全局在岗人口末期更高</b>：v7 末期 6.95 万 vs v5 的 5.59 万，衰减更慢。</li>
<li class="good"><b>核算体系更完整</b>：新增 births/deaths、producer_revenue、贵金属发行、cycle_flow、贸易统计等字段，可观测性大幅提升，守恒误差仍全 0。</li>
</ul>
</div>
<div class="chart-box"><div class="cap"><b>图 1｜生产者财富占比：v7(绿) vs v5(灰虚)</b> —— 最显著的改善，生产者不再归零</div><canvas id="c_fpct"></canvas></div>
<div class="grid2">
<div class="chart-box"><div class="cap"><b>图 2｜满意度：v7 逆转回升 vs v5 持续恶化</b></div><canvas id="c_sat"></canvas></div>
<div class="chart-box"><div class="cap"><b>图 3｜三大阶层财富占比(v7)</b>：生产者(绿)守住六成</div><canvas id="c_fpct3"></canvas></div>
</div>

<h2>三、仍未解决 / 新暴露的问题 ✕</h2>

<h3>① 出生机制：字段就位，逻辑与数据双缺失（P0 未解）</h3>
<div class="card">
<p>v7 加了 <code>births</code>/<code>deaths</code> 统计列，也把 <code>signature_birth_rate_q32</code> 编译进了 signature 数据结构（economy_catalog.gd:214, economy_runtime.cpp:2355），但：</p>
<ul>
<li class="bad"><b>没有任何地方计算 <code>market_result.births</code></b>：全 .cpp 仅在 :9637 累加它，却没有一处 <code>.births = ...</code> 的赋值 —— 出生数永远是初始值 0。</li>
<li class="bad"><b>profession 的 .tres 根本没配 birth_rate 值</b>：grep 无结果，即默认 0。即便逻辑写了也生不出人。</li>
</ul>
<p>结果：<code>births 累计 = 0</code>，<code>deaths 累计 = 62697</code>。人口守恒式 <code>closing = opening + 0 - deaths + migration</code> 依旧只减不增 —— <b>这就是"人口仍 133→78、与 v5 完全相同"的根本原因</b>。</p>
<div class="callout red">出生是整个萎缩螺旋的总开关。v7 搭好了脚手架却没接线：<b>需要 ①在人口清算里写 birth_rate_q32 × 满意度权重 → market_result.births 的计算；②给各 profession 的 .tres 配置合理的 birth_rate_q32 与族群 birth_rate_factor。</b></div>
</div>
<div class="chart-box"><div class="cap"><b>图 4｜出生 vs 死亡</b>：deaths 持续（红），births 全程贴地为 0（绿）——即使满意度已回升到 0.90</div><canvas id="c_bd"></canvas></div>

<h3>② 跨格贸易：框架启动，但一单未成（P0 未解）</h3>
<div class="card">
<p>v7 引入了完整的贸易系统字段（topology / routes / orders / candidates）。但数据显示它<b>完全空转</b>：</p>
<ul>
<li class="bad"><code>trade_topology_ready = True</code>、<code>trade_scan_total = 288000</code>（有扫描配额），但 <code>trade_completed_scans = 0</code>、<code>trade_candidates_generated = 0</code>、<code>trade_orders_arrived = 0</code> —— <b>扫描从未完成，一个候选订单都没生成</b>。</li>
<li class="warn">所有 <code>trade_rejected_*</code> 也全 0，说明不是"生成后被拒"，而是<b>根本没进入生成阶段</b>。</li>
</ul>
<div class="callout">贸易本应是打通产业链断裂的关键——本地缺石器工具/兽肉，可从邻格进口。但它没跑起来，于是 cell 1060 依旧是个封闭市场，产业链断裂无法靠贸易缓解。需排查 trade 扫描游标/调度是否被实际驱动（completed_scans 恒 0 是最可疑的线索）。</div>
</div>

<h3>③ 产业链断裂：原样复现（P0 未解）</h3>
<div class="card">
<p>与 v5 一模一样的断裂链条再次上演：</p>
<table>
<tr><th>建筑</th><th>owner需求</th><th>在岗</th><th>状态</th><th>成品</th></tr>
<tr><td>打制石器工坊 (artisan)</td><td>1</td><td>0</td><td><span class="tag stop">停产</span></td><td>chipped_stone_tools 断供</td></tr>
<tr><td>狩猎营地 (hunter)</td><td>0</td><td>0</td><td><span class="tag stop">operating_state=1</span></td><td>game_meat/fur 断供</td></tr>
<tr><td>织布棚 (artisan)</td><td>2</td><td>0</td><td><span class="tag stop">停产</span></td><td>cloth 断供</td></tr>
<tr><td>采集地 (forager)</td><td>48</td><td>48</td><td><span class="tag ok">满配</span></td><td>gathered_plants(仍卖不动)</td></tr>
</table>
<ul>
<li class="bad">成品（石器/兽肉/毛皮/加工食品/原木/布）全部 <b>stock=0、供给=0、shortage=65535、价格顶格</b>，涨幅 +698%~+835%。</li>
<li class="bad">原料（raw_stone/raw_hide/flint）仍暴跌 -89%~-90%，堆积无人加工。</li>
<li class="warn"><b>gathered_plants 出现新怪象</b>：demand_ema=23320（有强需求）、供给 156996（有产出），但 stock=0、shortage 仍 16720 —— 需求方有钱却买不到/清算不匹配，值得单独排查。</li>
<li class="warn"><code>loss_suspended_building_groups</code> 从 0 涨到 <b>2206</b>，大量建筑因持续亏损被挂起停产。</li>
</ul>
</div>
<div class="grid2">
<div class="chart-box"><div class="cap"><b>图 5｜建筑 owner 在岗(v7)</b>：打石工坊/狩猎营地照旧归零</div><canvas id="c_own"></canvas></div>
<div class="chart-box"><div class="cap"><b>图 6｜关键商品价格(v7)</b>：成品顶格、原料贴地，与 v5 同构</div><canvas id="c_price"></canvas></div>
</div>

<h2>四、下一步改进建议（按优先级）</h2>
<div class="fix"><div class="h"><span class="pri p0">P0</span>接通出生逻辑 + 配置 birth_rate（最高优先）</div>
<p>在人口清算中实现 <code>market_result.births = f(population, birth_rate_q32, satisfaction)</code>（满意度越高出生越多），并给各 profession .tres 配置非零 <code>birth_rate_q32</code>。满意度已能回升到 0.90，只要接上出生，人口就有望止跌回升——这是把"缓慢死亡"转为"可持续"的唯一总开关。</p></div>

<div class="fix"><div class="h"><span class="pri p0">P0</span>让贸易真正跑起来</div>
<p>排查 <code>trade_completed_scans</code> 恒为 0 的原因：扫描游标是否被调度驱动、topology 是否真的生成了可用路由、候选生成阶段的前置条件是否卡死。贸易打通后，本地断供的石器/肉食可由邻格进口，直接缓解产业链断裂。</p></div>

<div class="fix"><div class="h"><span class="pri p1">P1</span>打破产业链刚性单点依赖</div>
<p>石器工具仍是唯一由单一 artisan 建筑生产、且是狩猎营地的硬投入。给 hunting_camp 增加"无工具降级运作"模式，或让 <code>input_category_ids</code> 替代路径在工具/食物链上真正启用；给 wild_game 等消耗型资源加 <code>resource_generation</code> 再生。</p></div>

<div class="fix"><div class="h"><span class="pri p1">P1</span>排查 gathered_plants「有供有需却零成交」</div>
<p>末期 demand=23320、供给=156996，但 stock=0、shortage=16720。疑似清算时序或预算约束导致有效需求无法落地，需单独复盘该商品的清算路径。</p></div>

<div class="callout green"><b>一句话总结：</b>v7 证明了"防止生产者被榨干"的改动是对的（财富占比 0.1%→61.8%、满意度回升到 0.90）。但决定生死的两个总开关——<b>出生</b>与<b>贸易</b>——都只搭了架子没接线，产业链断裂也照旧。把这两根线接上，经济才可能从"优雅地慢性死亡"转为"能自我维持"。</div>

<div class="foot">
本报告基于 v7 五份 CSV（cell1060，6.1 万行全时序）与 v5（cell1031）对照分析，交叉验证 economy_runtime.cpp（12530 行）与 economy_catalog.gd 的 births/trade/catalog 实现。所有数值来自实际采样，机制结论带源码行号。id 语义：need/profession/building 按 data/economy/* 文件名字母序 0-based。<br>
砚灯 · Project.Keynes 经济复诊 · 2026-07-17
</div>
</div>
<script>
const D=__DATA__;const v7=D.v7,v5=D.v5;
Chart.defaults.color='#9aa7b4';Chart.defaults.borderColor='#2d354233';Chart.defaults.font.family="'Segoe UI','Microsoft YaHei',sans-serif";
const C={red:'#f85149',green:'#3fb950',blue:'#58a6ff',amber:'#d29922',purple:'#bc8cff',cyan:'#39c5cf',pink:'#f778ba',gray:'#6e7681'};
const thin={pointRadius:0,borderWidth:2,tension:.25};
function opt(ex){return Object.assign({responsive:true,maintainAspectRatio:false,interaction:{mode:'index',intersect:false},plugins:{legend:{labels:{boxWidth:12,font:{size:11}}}},scales:{x:{ticks:{maxTicksLimit:8,font:{size:10}},grid:{display:false}},y:{ticks:{font:{size:10}},grid:{color:'#2d354233'}}}},ex||{});}
function mk(id,labels,ds,ex){new Chart(document.getElementById(id),{type:'line',data:{labels:labels,datasets:ds},options:opt(ex)});}

// 图1 生产者财富占比 v7 vs v5(用各自day轴, 以v7为准labels, v5按比例映射)
mk('c_fpct',v7.days,[
 {label:'v7 生产者',data:v7.fpct.producer,borderColor:C.green,backgroundColor:C.green+'22',fill:true,...thin},
 {label:'v5 生产者',data:v5.fpct.producer.slice(0,v7.days.length),borderColor:C.gray,borderDash:[5,4],...thin},
],{scales:{y:{title:{display:true,text:'财富占比 %'},min:0,max:100}}});

// 图2 满意度 v7 vs v5
mk('c_sat',v7.days,[
 {label:'v7',data:v7.sat,borderColor:C.amber,backgroundColor:C.amber+'22',fill:true,...thin},
 {label:'v5',data:v5.sat.slice(0,v7.days.length),borderColor:C.gray,borderDash:[5,4],...thin},
],{scales:{y:{min:0,max:1}}});

// 图3 v7三阶层财富
mk('c_fpct3',v7.days,[
 {label:'生产者',data:v7.fpct.producer,borderColor:C.green,...thin},
 {label:'商人',data:v7.fpct.merchant,borderColor:C.red,...thin},
 {label:'精英',data:v7.fpct.elite,borderColor:C.purple,...thin},
],{scales:{y:{title:{display:true,text:'%'}}}});

// 图4 出生死亡
mk('c_bd',v7.days,[
 {label:'死亡/周期',data:v7.deaths,borderColor:C.red,backgroundColor:C.red+'22',fill:true,...thin},
 {label:'出生/周期',data:v7.births,borderColor:C.green,borderWidth:3,...thin},
]);

// 图5 建筑owner
const oc={'采集地':C.green,'狩猎营地':C.purple,'打制石器工坊':C.red,'海鱼采集点':C.cyan,'织布棚':C.pink};
mk('c_own',v7.days,Object.keys(v7.build_own).filter(k=>oc[k]).map(k=>({label:k,data:v7.build_own[k],borderColor:oc[k],...thin})));

// 图6 价格
const pc={flint:C.gray,chipped_stone_tools:C.red,game_meat:C.purple,fur:C.pink,cloth:C.cyan,gathered_plants:C.green,raw_stone:C.blue};
const pn={flint:'燧石(料)',chipped_stone_tools:'石器(成)',game_meat:'兽肉(成)',fur:'毛皮(成)',cloth:'布(成)',gathered_plants:'采集植物(料)',raw_stone:'原石(料)'};
mk('c_price',v7.days,['flint','chipped_stone_tools','game_meat','cloth','gathered_plants','raw_stone'].map(g=>({label:pn[g],data:v7.price[g],borderColor:pc[g],...thin})));
</script>
</body></html>"""
HTML=HTML.replace("__DATA__",data)
out=r"D:\Godot\ProjectKeynes\Project.Keynes\经济运行时v7复诊报告.html"
with open(out,"w",encoding="utf-8") as f:f.write(HTML)
print("written",out,len(HTML))
