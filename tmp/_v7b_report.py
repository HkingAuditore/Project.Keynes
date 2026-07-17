# -*- coding: utf-8 -*-
import json
with open(r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\_v7b_data.json","r",encoding="utf-8") as f:
    data=f.read()

HTML=r"""<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>Project.Keynes 经济运行时 v7 第三次复诊报告</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js"></script>
<style>
:root{--bg:#0d1117;--panel:#161b22;--panel2:#1c2230;--border:#2d3542;--txt:#e6edf3;--dim:#9aa7b4;--accent:#58a6ff;--red:#f85149;--green:#3fb950;--amber:#d29922;--purple:#bc8cff;--cyan:#39c5cf;--pink:#f778ba}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--txt);font-family:-apple-system,"Segoe UI","Microsoft YaHei",sans-serif;line-height:1.7;font-size:15px}
.wrap{max-width:1180px;margin:0 auto;padding:32px 24px 80px}
header{border-bottom:1px solid var(--border);padding-bottom:24px;margin-bottom:28px}
h1{font-size:29px;font-weight:700;letter-spacing:-.5px;background:linear-gradient(90deg,#f85149,#d29922);-webkit-background-clip:text;background-clip:text;-webkit-text-fill-color:transparent}
.sub{color:var(--dim);margin-top:10px;font-size:14px}
.meta{display:flex;gap:20px;flex-wrap:wrap;margin-top:14px;font-size:13px;color:var(--dim)}
.meta span b{color:var(--accent)}
h2{font-size:22px;margin:44px 0 8px;padding-left:12px;border-left:4px solid var(--accent);font-weight:650}
h3{font-size:17px;margin:24px 0 10px;color:var(--cyan)}
p{margin:10px 0;color:#d7dee6}
.card{background:var(--panel);border:1px solid var(--border);border-radius:12px;padding:20px 22px;margin:18px 0}
.verdict{display:flex;align-items:center;gap:14px;background:linear-gradient(135deg,#211d0f,#1a160e);border:1px solid #5c5226;border-radius:12px;padding:18px 22px;margin:20px 0}
.verdict .big{font-size:34px}.verdict .t b{font-size:18px}
.verdict .t b.g{color:var(--green)}.verdict .t b.a{color:var(--amber)}.verdict .t b.r{color:var(--red)}
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
.flow{display:flex;align-items:center;gap:6px;flex-wrap:wrap;margin:14px 0;font-size:13px}
.flow .node{padding:6px 12px;border-radius:8px;border:1px solid var(--border);background:var(--panel2)}
.flow .node.ok{border-color:#2c5c26;background:#132d1c;color:#7ee89a}
.flow .node.dead{border-color:#5c2226;background:#2d1518;color:#f8918a}
.flow .arr{color:var(--dim)}
.small{font-size:12.5px;color:var(--dim)}
</style></head><body><div class="wrap">
<header>
<h1>经济运行时 v7 · 第三次复诊报告</h1>
<div class="sub">采样 <code>economy_record_20260717_152531_v7_cell1166_q17_r19</code> — 对比前两次 v7 采样，检验「出生」「贸易」两大 P0 开关是否接线</div>
<div class="meta" id="meta"></div>
</header>

<div class="verdict">
<div class="big">🕯️</div>
<div class="t"><b class="a">结论：改动方向对，防榨干持续有效；但决定生死的两个总开关——出生、贸易——第三次采样仍然<b class="r">整条链路空转</b>，且这次数据把「卡在哪一环」暴露得一清二楚。</b>
<div class="small" style="margin-top:6px">人口 130→81，births 全程 ≡0；21.3 亿次贸易扫描换来 0 个候选、0 单成交。这两条不接通，经济就永远只有下坡。</div></div>
</div>

<div class="kpis" id="kpis"></div>

<h2>一、三次 v7 采样趋势对照</h2>
<p>这是同一套 v7 代码的第三个采样点（cell1166，跑满 3705 天，是三次里最长的）。把三次并排看，能分清「哪些是真改善」「哪些是没动过的老病」。</p>
<div class="card">
<table>
<tr><th>维度</th><th>v5 基线(cell1031)</th><th>v7-①(cell1060)</th><th>v7-②本次(cell1166)</th><th>判定</th></tr>
<tr><td>选中格人口 首→末</td><td>133→75</td><td>133→78</td><td>130→81</td><td><span class="tag stop">仍下滑 -38%</span></td></tr>
<tr><td>births 累计</td><td>0</td><td>0</td><td>0</td><td><span class="tag stop">未接线</span></td></tr>
<tr><td>deaths 累计</td><td>—</td><td>—</td><td>29198</td><td><span class="tag stop">只死不生</span></td></tr>
<tr><td>producer 财富占比(末)</td><td>0.1%</td><td>61.8%</td><td>39.6%</td><td><span class="tag ok">远好于v5</span></td></tr>
<tr><td>worst-need 满意度(末)</td><td>0.64↓</td><td>0.90↑</td><td>1.00↑ (最低0.63)</td><td><span class="tag ok">健康</span></td></tr>
<tr><td>贸易扫描 / 成交</td><td>无系统</td><td>28.8万 / 0</td><td>21.3亿 / 0</td><td><span class="tag idle">空转</span></td></tr>
<tr><td>贸易候选生成</td><td>—</td><td>0</td><td>0</td><td><span class="tag stop">链路第1环就断</span></td></tr>
<tr><td>产业链断裂</td><td>雪崩</td><td>复现</td><td>复现(day2405拐点)</td><td><span class="tag stop">机理不变</span></td></tr>
<tr><td>守恒误差 pop/money/goods</td><td>0/0/0</td><td>0/0/0</td><td>0/0/0</td><td><span class="tag ok">账本可信</span></td></tr>
</table>
<div class="callout green">值得肯定：<b>防榨干机制持续生效</b>。producer 末期仍保有 39.6% 财富（v5 是 0.1%），满意度全程健康（末 1.0，最低才 0.63）。你对货币回流/留存的那刀砍得准，三次采样都印证了。</div>
</div>

<h2>二、P0-A 出生机制：字段就位，逻辑仍缺（三重缺失照旧）</h2>
<p>这是最致命的一条。<code>births</code> 在 741 个周期里<b>全部为 0</b>，而 deaths 累计 29198。人口只能单调向下。我核对了源码，问题定位到源头——不是配置问题，是<b>转换逻辑根本没写</b>。</p>
<div class="chart-box"><div class="cap"><b>图1</b> · 出生 vs 死亡 vs 人口总数（births 贴地为 0，deaths 持续消耗，cohort 单调下滑）</div><canvas id="c_birth"></canvas></div>
<div class="card">
<h3>源码链路核对（economy_runtime.cpp）</h3>
<div class="flow">
<span class="node ok">.tres 出生率配置<br><span class="small">signature_birth_rate_q32</span></span>
<span class="arr">→</span>
<span class="node ok">读入 signature<br><span class="small">:2365 packed_i64<br>:2388 _signatures[i].birth_rate</span></span>
<span class="arr">→</span>
<span class="node dead">✕ 转换为出生数<br><span class="small">market_result.births<br>无任何赋值点</span></span>
<span class="arr">→</span>
<span class="node ok">累加进 _births<br><span class="small">:9695 saturating_add</span></span>
<span class="arr">→</span>
<span class="node ok">守恒式<br><span class="small">:9378 pop += births - deaths</span></span>
</div>
<div class="callout red">关键证据：全 <code>economy_runtime.cpp</code> 中 <code>market_result.births</code> 只在 <code>:9695</code> 被<b>读取</b>（累加），<b>没有任何一处写入它</b> → 它永远是默认值 0。<code>_signatures[i].birth_rate</code>（:2388 已存入）到 <code>market_result.births</code> 之间那一步「按出生率×人口算出这周期新生儿」的计算<b>不存在</b>。链路两头都通，中间断了一节。</div>
<p><b>要接通需要三步：</b></p>
<ul>
<li class="warn">在 profession/ethnicity 的 <code>.tres</code> 里填上真实的 <code>birth_rate</code>（当前默认 0，即便逻辑写了也生不出人）</li>
<li class="warn">在市场结算处新增：<code>market_result.births += 按 _signatures[i].birth_rate × cohort.population 算出的新生儿数</code>（这是缺失的核心一步）</li>
<li class="good">守恒式（:9378/:9695）已就绪，接上即可生效，无需改</li>
</ul>
</div>

<h2>三、P0-B 贸易系统：拓扑就绪、信号登记，但候选生成为 0</h2>
<p>这次的 trade 诊断字段最全，能精确断言卡在哪。系统扫描了 <b>21.3 亿次</b>（累计），源信号 114、汇信号 350 都登记了，<code>trade_runtime_mode=ACTIVE</code>、拓扑 ready——<b>但候选生成 = 0，连"被拒绝"的计数都全是 0</b>。这说明流程在「扫描 → 生成候选」这第一环之前就返回了，根本没进入撮合。</p>
<div class="chart-box"><div class="cap"><b>图2</b> · 贸易链路漏斗：每一环的累计量（scan 巨大，candidate 之后全断）</div><canvas id="c_trade"></canvas></div>
<div class="card">
<div class="flow">
<span class="node ok">scan_total<br><span class="small">21.3 亿次</span></span><span class="arr">→</span>
<span class="node ok">source/dest signals<br><span class="small">114 / 350</span></span><span class="arr">→</span>
<span class="node dead">✕ candidates_generated<br><span class="small">0</span></span><span class="arr">→</span>
<span class="node dead">✕ accepted<br><span class="small">0</span></span><span class="arr">→</span>
<span class="node dead">✕ orders_dispatched<br><span class="small">0</span></span><span class="arr">→</span>
<span class="node dead">✕ orders_arrived<br><span class="small">0</span></span>
</div>
<div class="callout red">决定性判据：所有 <code>trade_rejected_*</code>（profit/capacity/stock/cash/route/order_cap）<b>累计全为 0</b>。如果是「生成了候选但被门槛拒了」，rejected 会有数字。现在 rejected 全 0，说明<b>候选压根没进入评估环节</b>——bug 在 candidate 生成逻辑本身（可能提前 return、或供需信号没被正确配对成候选）。</div>
<p>更扎心的是：per-good 层面 119 个 good 的 <code>trade_enabled=1</code>（开关开了），但 import/export/inbound/outbound <b>全部为 0</b>。而这一格恰恰有 <code>chipped_stone_tools/game_meat/logs/processed_food</code> 短缺顶到天花板（shortage=65535）——<b>正是贸易本该救命的场景，却一单进口都没触发</b>。</p>
</div>

<h2>四、产业链断裂：机理与前两版完全一致，这次断点更清晰</h2>
<p>cell1166 前 2000 天所有建筑 owner 都稳（人口 126 不动）。<b>day2405 是拐点</b>：打制石器工坊（type90，chipped_stone_tools 唯一来源）先停产 → 狩猎营地（type238）失去工具硬投入，从 owner=48 一路饿死到 day3605 归零 → producer 人口同步从 126 崩到 77。</p>
<div class="grid2">
<div class="chart-box"><div class="cap"><b>图3</b> · 关键建筑 owner 轨迹（打石工坊先死，狩猎营地随后雪崩）</div><canvas id="c_bld"></canvas></div>
<div class="chart-box"><div class="cap"><b>图4</b> · 人口分组（producer 在 day2400 后断崖，elite/merchant 岿然不动）</div><canvas id="c_pop"></canvas></div>
</div>
<div class="flow">
<span class="node dead">打制石器工坊 type90<br><span class="small">day2405 停产</span></span><span class="arr">→ 工具断供 →</span>
<span class="node dead">狩猎营地 type238<br><span class="small">48 → 0 (day3605)</span></span><span class="arr">→ 肉/皮断供 →</span>
<span class="node dead">game_meat/fur<br><span class="small">shortage 顶格</span></span><span class="arr">→</span>
<span class="node dead">producer 饿死<br><span class="small">126 → 77</span></span>
</div>
<div class="callout blue">这条链和 v5/v7-① 逐点吻合：<code>chipped_stone_tools</code> 单点来源 + <code>wild_game</code> 无再生 + 无跨格补给（贸易空转）= 必然雪崩。区别只是这次跑得久（3705天），拐点来得晚（day2405），因为初始库存缓冲更厚。</div>

<h2>五、价格/短缺：只有加速器、没有刹车（老问题）</h2>
<div class="chart-box"><div class="cap"><b>图5</b> · 关键成品短缺率（断供后长期锁定 shortage=1.0）</div><canvas id="c_short"></canvas></div>
<div class="chart-box"><div class="cap"><b>图6</b> · 财富占比演化（producer 缓慢流失到 elite/merchant）</div><canvas id="c_fw"></canvas></div>
<p>末期 <code>chipped_stone_tools/game_meat/fur/logs/processed_food</code> 全部 offered_supply=0、shortage=65535、价格顶天花板。断供后价格失去意义——没有供给，再高的价也换不来货，跨格贸易又没跑，于是永久锁死。</p>

<h2>六、改进建议（按优先级）</h2>
<div class="card">
<h3><span class="tag stop">P0</span> 接通出生逻辑（决定人口能否止跌）</h3>
<ul>
<li class="bad">在市场结算处补上 <code>market_result.births</code> 的赋值：遍历 cohort，<code>births += _signatures[sig].birth_rate × population</code>（Q32 定点，注意右移）</li>
<li class="bad">给 profession/ethnicity 的 <code>.tres</code> 填真实 <code>birth_rate</code>（当前默认 0）</li>
<li class="good">守恒式 :9378/:9695 已就绪，无需改动</li>
</ul>
<h3><span class="tag idle">P0</span> 修复贸易候选生成（让 21.3 亿次扫描不白跑）</h3>
<ul>
<li class="bad">重点排查 candidate 生成函数：为何 source(114)/dest(350) 信号都在，却 0 候选、0 rejected —— 大概率提前 return 或信号配对逻辑没跑</li>
<li class="warn">加断言/日志：candidate 生成入口打点，确认是否被调用；若被调用则打印每个 source×dest 配对的过滤原因</li>
<li class="warn">验收标准：短缺顶格的 <code>chipped_stone_tools</code> 应触发 <code>trade_inbound&gt;0</code></li>
</ul>
<h3><span class="tag ok">P1</span> 打破产业链单点依赖</h3>
<ul>
<li class="warn"><code>chipped_stone_tools</code> 增加第二来源，或降低 <code>hunting_camp</code> 对工具的硬依赖（改为软性效率加成）</li>
<li class="warn"><code>wild_game</code> 加 <code>resource_generation</code> 再生率，避免不可逆耗竭</li>
</ul>
<h3><span class="tag ok">P1</span> 给物价加"刹车"</h3>
<ul>
<li class="warn">供给=0 时不应无限顶价；当 shortage 持续顶格应触发外部补给（建设/贸易）而非仅涨价</li>
</ul>
</div>

<div class="card" style="margin-top:30px">
<p class="small">数据来源：<code>economy_record_20260717_152531_v7_cell1166_q17_r19_*.csv</code>（summary/buildings/cohorts/market/resources）。summary 为世界级聚合，其余为 cell1166 局部。守恒误差 pop/money/goods 全 0，数据可信。源码核对基于 <code>gdext/src/economy_runtime.cpp</code>。</p>
</div>

</div>
<script>
const D=__DATA__;
const gc=getComputedStyle(document.documentElement);
const C={txt:gc.getPropertyValue('--txt').trim(),dim:gc.getPropertyValue('--dim').trim(),grid:'#2d354233',
 red:'#f85149',green:'#3fb950',amber:'#d29922',blue:'#58a6ff',purple:'#bc8cff',cyan:'#39c5cf',pink:'#f778ba'};
Chart.defaults.color=C.dim;Chart.defaults.font.family='Segoe UI,Microsoft YaHei,sans-serif';Chart.defaults.font.size=11;
Chart.defaults.plugins.legend.labels.color=C.txt;Chart.defaults.plugins.legend.labels.boxWidth=12;
const days=D.days;
// meta
document.getElementById('meta').innerHTML=
 `<span>格 <b>#${D.meta.cell}</b></span><span>天数 <b>${D.meta.day_min}–${D.meta.day_max}</b></span>`+
 `<span>采样点 <b>${D.meta.rows}</b></span><span>守恒误差 <b>${D.meta.err_pop}/${D.meta.err_money}/${D.meta.err_goods}</b></span>`+
 `<span>贸易成交 <b>${D.trade.orders_arrived}</b></span><span>births <b>${D.births.reduce((a,b)=>a+b,0)}</b></span>`;
// kpis
const kpis=[
 {v:'130→81',l:'cell1166 人口',d:'<span class="down">▼ -37.7%</span>',cls:''},
 {v:'0',l:'births 累计 (741周期)',d:'<span class="down">出生逻辑未接线</span>'},
 {v:'21.3亿→0',l:'贸易扫描→成交',d:'<span class="flat">候选生成=0</span>'},
 {v:'1.00',l:'worst-need 满意度(末)',d:'<span class="up">▲ 健康 (最低0.63)</span>'},
 {v:'39.6%',l:'producer 财富占比(末)',d:'<span class="up">远优于 v5 的 0.1%</span>'},
 {v:'day2405',l:'产业链雪崩拐点',d:'<span class="flat">打石工坊先停产</span>'},
 {v:'29198',l:'deaths 累计',d:'<span class="down">只死不生</span>'},
 {v:'674',l:'loss_suspended 建筑组(末)',d:'<span class="flat">全局停摆规模</span>'},
];
document.getElementById('kpis').innerHTML=kpis.map(k=>
 `<div class="kpi"><div class="v">${k.v}</div><div class="l">${k.l}</div><div class="d">${k.d}</div></div>`).join('');
const thin={borderWidth:2,pointRadius:0,tension:.25};
const noG={scales:{x:{grid:{color:C.grid},ticks:{maxTicksLimit:9}},y:{grid:{color:C.grid}}}};
function mk(id,cfgData,opt){new Chart(document.getElementById(id),{type:'line',data:{labels:days,datasets:cfgData},options:Object.assign({responsive:true,interaction:{mode:'index',intersect:false}},noG,opt||{})});}
// 图1 出生死亡
mk('c_birth',[
 {label:'births',data:D.births,borderColor:C.green,backgroundColor:'#3fb95022',fill:true,...thin},
 {label:'deaths',data:D.deaths,borderColor:C.red,...thin},
 {label:'cohort_count(右)',data:D.cohort_count,borderColor:C.blue,yAxisID:'y1',...thin},
],{scales:{x:{grid:{color:C.grid},ticks:{maxTicksLimit:9}},y:{grid:{color:C.grid},title:{display:true,text:'出生/死亡'}},y1:{position:'right',grid:{display:false},title:{display:true,text:'cohort'}}}});
// 图2 贸易漏斗 (bar)
new Chart(document.getElementById('c_trade'),{type:'bar',data:{
 labels:['scan_total','source_sig','dest_sig','candidates','accepted','dispatched','arrived'],
 datasets:[{label:'累计量(对数)',data:[D.trade.scan_total_sum,D.trade.source_signals,D.trade.dest_signals,D.trade.candidates_generated,D.trade.candidates_accepted,D.trade.orders_dispatched,D.trade.orders_arrived],
   backgroundColor:[C.blue,C.cyan,C.cyan,C.red,C.red,C.red,C.red]}]},
 options:{responsive:true,plugins:{legend:{display:false}},scales:{x:{grid:{color:C.grid}},y:{type:'logarithmic',grid:{color:C.grid},title:{display:true,text:'累计(log)'}}}}});
// 图3 建筑
const bcolors={'打制石器工坊':C.red,'狩猎营地':C.amber,'采集地':C.green,'海鱼采集点':C.cyan,'织布棚':C.purple,'公共炉灶':C.blue,'燧石采石场':C.pink};
mk('c_bld',Object.keys(D.bld).filter(k=>['打制石器工坊','狩猎营地','采集地','海鱼采集点','织布棚'].includes(k)).map(k=>({label:k,data:D.bld[k],borderColor:bcolors[k]||C.dim,...thin})));
// 图4 人口分组
mk('c_pop',[
 {label:'producer',data:D.pop_producer,borderColor:C.green,...thin},
 {label:'merchant',data:D.pop_merchant,borderColor:C.amber,...thin},
 {label:'elite',data:D.pop_elite,borderColor:C.purple,...thin},
]);
// 图5 短缺
const pn={chipped_stone_tools:'石器工具',game_meat:'兽肉',fur:'毛皮',logs:'原木',processed_food:'加工食品',cloth:'布',gathered_plants:'采集植物',raw_stone:'原石',flint:'燧石'};
const pc={chipped_stone_tools:C.red,game_meat:C.amber,fur:C.pink,logs:C.cyan,processed_food:C.purple,cloth:C.blue,gathered_plants:C.green,raw_stone:C.dim,flint:'#8b949e'};
mk('c_short',['chipped_stone_tools','game_meat','fur','logs','processed_food'].filter(g=>D.shortage[g]).map(g=>({label:pn[g],data:D.shortage[g],borderColor:pc[g],...thin})));
// 图6 财富占比
mk('c_fw',[
 {label:'producer%',data:D.fw_producer,borderColor:C.green,...thin},
 {label:'merchant%',data:D.fw_merchant,borderColor:C.amber,...thin},
 {label:'elite%',data:D.fw_elite,borderColor:C.purple,...thin},
]);
</script>
</body></html>"""

out=r"D:\Godot\ProjectKeynes\Project.Keynes\经济运行时v7第三次复诊报告.html"
HTML=HTML.replace("__DATA__",data)
open(out,"w",encoding="utf-8").write(HTML)
print("written",out,len(HTML))
