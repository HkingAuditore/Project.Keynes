# -*- coding: utf-8 -*-
import json
data = json.load(open("D:/Godot/ProjectKeynes/Project.Keynes/tmp/econ_report_data.json", encoding="utf-8"))
DATA_JS = json.dumps(data, ensure_ascii=False)

HTML = r"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Project.Keynes 石器时代经济运行时深度分析</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js"></script>
<style>
:root{
 --bg:#0e1116; --panel:#161b22; --panel2:#1c232d; --border:#2b333d;
 --txt:#e6edf3; --mut:#9aa7b4; --accent:#58a6ff; --red:#f85149; --grn:#3fb950;
 --amber:#d29922; --purple:#bc8cff; --cyan:#39c5cf;
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--txt);font-family:-apple-system,"Segoe UI","Microsoft YaHei",Roboto,sans-serif;line-height:1.65;font-size:15px}
.wrap{max-width:1180px;margin:0 auto;padding:32px 22px 80px}
h1{font-size:30px;margin:0 0 6px;letter-spacing:.5px}
h2{font-size:22px;margin:44px 0 6px;padding-left:12px;border-left:4px solid var(--accent)}
h3{font-size:17px;margin:26px 0 10px;color:var(--cyan)}
.sub{color:var(--mut);font-size:14px;margin-bottom:18px}
.q{color:var(--accent);font-weight:600}
p{color:#d4dde6}
.verdict{background:linear-gradient(135deg,#2a1416,#1c232d);border:1px solid var(--red);border-radius:12px;padding:18px 22px;margin:20px 0}
.verdict b{color:var(--red)}
.grid{display:grid;gap:14px}
.kpis{grid-template-columns:repeat(4,1fr)}
@media(max-width:820px){.kpis{grid-template-columns:repeat(2,1fr)}}
.card{background:var(--panel);border:1px solid var(--border);border-radius:10px;padding:16px}
.kpi .v{font-size:26px;font-weight:700;line-height:1.2}
.kpi .l{font-size:12.5px;color:var(--mut);margin-top:4px}
.kpi .d{font-size:12px;margin-top:6px}
.up{color:var(--red)} .down{color:var(--grn)} .warn{color:var(--amber)}
.chartbox{background:var(--panel);border:1px solid var(--border);border-radius:10px;padding:16px 16px 10px;margin:16px 0}
.chartbox h4{margin:0 0 4px;font-size:15px}
.chartbox .cap{color:var(--mut);font-size:12.5px;margin:0 0 12px}
.cv{position:relative;height:300px}
.cv.tall{height:340px}
.two{display:grid;grid-template-columns:1fr 1fr;gap:16px}
@media(max-width:820px){.two{grid-template-columns:1fr}}
table{width:100%;border-collapse:collapse;font-size:13.5px;margin:8px 0}
th,td{border:1px solid var(--border);padding:7px 10px;text-align:right}
th{background:var(--panel2);color:var(--txt);text-align:right}
td:first-child,th:first-child{text-align:left}
.tag{display:inline-block;padding:1px 8px;border-radius:20px;font-size:11.5px;font-weight:600}
.t-bad{background:#3d1518;color:#ff9d96}
.t-ok{background:#123020;color:#5fd68a}
.t-warn{background:#3a2c0e;color:#ecc662}
ul{padding-left:20px} li{margin:5px 0;color:#d4dde6}
.chain{display:flex;flex-wrap:wrap;align-items:center;gap:8px;font-size:13px;margin:10px 0}
.node{background:var(--panel2);border:1px solid var(--border);border-radius:8px;padding:8px 12px;text-align:center}
.node.dead{border-color:var(--red);background:#2a1416}
.node.weak{border-color:var(--amber);background:#2a230e}
.node.ok{border-color:var(--grn);background:#12261a}
.node b{display:block;font-size:13.5px}
.node small{color:var(--mut);font-size:11px}
.arrow{color:var(--mut);font-size:18px}
.rec{background:var(--panel);border:1px solid var(--border);border-left:3px solid var(--grn);border-radius:8px;padding:14px 18px;margin:12px 0}
.rec h4{margin:0 0 6px;color:var(--grn);font-size:15.5px}
.pill{font-size:11px;color:var(--mut);border:1px solid var(--border);border-radius:12px;padding:1px 9px;margin-left:8px}
.foot{color:var(--mut);font-size:12px;margin-top:40px;border-top:1px solid var(--border);padding-top:16px}
code{background:var(--panel2);padding:1px 6px;border-radius:5px;font-size:12.5px;color:var(--amber)}
</style>
</head>
<body><div class="wrap">
<h1>Project.Keynes · 石器时代经济运行时深度分析</h1>
<div class="sub">数据集 <code>economy_record_20260717_114418_v5</code> · 选定格 cell 1031 (q3,r17) 逐周期记录 + 全局 runtime summary · 384 个周期 (day 15→1930)　审计误差：人口/货币/物资均为 0</div>

<div class="verdict">
<b>核心结论：这是一个正在缓慢死亡的经济。</b> 全局劳动力 384 周期内从 <b>13.27 万 → 5.85 万（-56%）</b>，选定格人口 133→78（-41%），6 个人群里 <b>猎人（48人）与工匠（3人）整族灭绝</b>。
根源不是"失业"，而是<b>产业链断裂 + 财富向商人单向抽血</b>：石器工具作坊（工匠）从第 1 天起就入不敷出 → 工具断供 → 狩猎瘫痪 → 肉/加工食品链崩溃 → 相关人群饿死。同时全体劳动者被商人/矿工吸走财富，选定格里 <b>7 个人（商人+矿工）到最后握有 99.9% 的存款</b>，而生产者被榨到接近零。
</div>

<div class="grid kpis" id="kpis"></div>

<!-- Q0 -->
<h2>0 · 当前经济体现出什么特点</h2>
<p>四个最鲜明的结构特征，逐一用数据支撑：</p>
<ul>
<li><b>单向"抽血式"财富分配。</b> 市场零售收入全部先归集到商人，商人几乎不再花出去（见 Q4 囤积图）。选定格精英（商人+矿工，共7人）财富占比从 <span class="q">18.7% 飙升到 99.9%</span>。</li>
<li><b>原料贱、成品贵的极端价格分裂。</b> 采集/初级品（gathered_plants、fish、flint、raw_hide）价格全部跌到<b>地板价</b>；加工品（processed_food、tools、game_meat、cloth）全部顶到<b>天花板价</b>且长期缺货率≈100%。</li>
<li><b>产业链单点脆断。</b> 关键中间品（石器工具）由仅 3 人的工匠族独家供给，一旦崩溃全链瘫痪，且无冗余、无替代、无转业。</li>
<li><b>"失业"表现为死亡而非闲置。</b> 失业人口常年≈0（全局峰值仅 332），因为下岗者被模型直接饿死，人口塌缩取代了失业堆积。</li>
</ul>
<div class="chartbox"><h4>全局劳动力构成（owner / employee / 失业）</h4><p class="cap">全局 summary：总劳动力从 13.27 万一路跌到 5.85 万；失业(红)几乎看不见——不是没失业，是失业者迅速死亡。</p><div class="cv" id="c_labor"></div></div>
<div class="chartbox"><h4>选定格财富集中度：精英(商人+矿工) 存款占比</h4><p class="cap">从 18.7% 单调升到 99.9%，是典型的分配失衡而非增长。</p><div class="cv" id="c_wealth"></div></div>

<!-- Q1 -->
<h2>1 · 这个经济运行是否健康？—— 不健康</h2>
<p>用三条独立证据判定为<b>系统性不健康、处于长期衰退轨道</b>：</p>
<div class="two">
<div class="chartbox"><h4>选定格人口（按职业堆叠）</h4><p class="cap">猎人(橙)与工匠先归零，渔民缓慢流失，仅采集者/商人/矿工存活。</p><div class="cv" id="c_pop"></div></div>
<div class="chartbox"><h4>各职业满意度（&lt;0.5 触发饥饿死亡线）</h4><p class="cap">工匠 day90 即跌破 0.1，猎人 day315 归零，渔民长期在死亡线附近震荡。</p><div class="cv" id="c_sat"></div></div>
</div>
<p>唯一"增长"的是货币总量与商人存款——但那是<b>补贴印钞 + 分配集中</b>制造的名义繁荣，实体（人口、产出、满意度）全面萎缩。健康的经济应当人口稳定、产业链闭合、满意度维持在生存线之上，本模型三者皆失。</p>

<!-- Q2 -->
<h2>2 · 为什么会产生大量"失业者"</h2>
<p>先厘清一个反直觉的事实：<span class="q">数据里的显性失业人口极小（全局峰值 332，选定格恒为 0）</span>。真正发生的是<b>大规模岗位毁灭 + 就地饿死</b>——全局 owner 岗位从 12.9 万跌到 5.6 万，等于 <b>7.3 万个岗位凭空消失</b>。之所以看不到"失业堆积"，是因为模型把失业者划入 <code>unemployed</code> 人群、只供给生存食物 → 满意度跌破 0.5 → 数个周期内饿死。<b>失业在这个模型里是通往死亡的过渡态，不是稳态。</b></p>
<h3>岗位为什么被毁灭：一条从 day1 就注定的崩溃链</h3>
<div class="chain">
<div class="node dead"><b>工匠 / 石器工坊</b><small>day1 收2/支8·day90 满意度0.07</small></div>
<div class="arrow">→</div>
<div class="node dead"><b>工具断供</b><small>tools 供给→0 缺货率100%</small></div>
<div class="arrow">→</div>
<div class="node dead"><b>狩猎营地瘫痪</b><small>产出 455→0.4</small></div>
<div class="arrow">→</div>
<div class="node dead"><b>猎人饿死</b><small>48→0 满意度归零</small></div>
<div class="arrow">→</div>
<div class="node weak"><b>火塘停产</b><small>缺肉→加工食品→0</small></div>
<div class="arrow">→</div>
<div class="node weak"><b>采集者/渔民贫困化</b><small>满意度 1.0→0.65</small></div>
</div>
<div class="chartbox"><h4>各类建筑日产出（选定格）</h4><p class="cap">狩猎营地(238)与石器工坊(90)最先归零，火塘(30)随后停摆；采集/采石维持但被贱卖。</p><div class="cv tall" id="c_bout"></div></div>
<p>换言之，"失业"的根因是<b>产业链上游断点 + 无转业机制</b>：当一个环节（工匠）崩溃，其下游（猎人）失去投入品与收入来源，既无法转去别的建筑（没有职位空缺匹配），也无法降级谋生，只能原地饿死。岗位随人口一起蒸发。</p>

<!-- Q3 -->
<h2>3 · 各建筑的原材料 / 产出设计是否科学？—— 存在结构性缺陷</h2>
<p>问题不在单个配方的数字，而在<b>供需规模的错配</b>与<b>关键节点缺乏冗余</b>。</p>
<h3>致命点：石器工具的供需比严重失衡</h3>
<table>
<tr><th>建筑</th><th>owner职业</th><th>投入/天</th><th>产出/天</th><th>下游需求</th><th>健康度</th></tr>
<tr><td>knapping_workshop 石器工坊</td><td>工匠×1</td><td>flint 3000</td><td>tools 4124</td><td>仅狩猎营地 5×24=120</td><td><span class="tag t-bad">产能过剩30倍·养不活工匠</span></td></tr>
<tr><td>stone_age_hunting_camp 狩猎营地</td><td>猎人×2</td><td>tools 5</td><td>meat 3728+hide+fur</td><td>火塘需 meat 500</td><td><span class="tag t-bad">依赖工具独家供给</span></td></tr>
<tr><td>communal_hearth 公共火塘</td><td>采集者×1</td><td>plants1000+meat500</td><td>processed_food 1804</td><td>全体主食</td><td><span class="tag t-warn">断肉即停产</span></td></tr>
<tr><td>gathering_ground 采集营地</td><td>采集者×2</td><td>—(占地)</td><td>gathered_plants 7000</td><td>火塘1000+口粮</td><td><span class="tag t-warn">严重过剩·贱卖</span></td></tr>
</table>
<p>核心缺陷：<b>石器工坊一天能造 4124 件工具，但整格真实需求只有约 120 件</b>——产能过剩 30 倍。工匠只能卖出极少量工具，收入（day1: 2）远不够养活 3 口人的食物开销（8），<b>从第一天起就是结构性赤字</b>，攒的老本耗尽即灭族。而这个"养不活的工匠"恰恰是整条肉食链的唯一咽喉。</p>
<div class="chartbox"><h4>关键职业周期收支（选定格，货币单位）</h4><p class="cap">工匠(红)、采集者(黄)长期支&gt;收；仅商人(紫)长期盈余。收支结构决定了谁生谁死。</p><div class="cv" id="c_inc"></div></div>
<p>设计建议方向（详见 Q6）：让工具<b>可库存、可跨格贸易、有多种下游用途</b>，或把工匠并入更大的通用制造人群；给关键中间品设置<b>多来源/替代品</b>，避免单点脆断。</p>

<!-- Q4 -->
<h2>4 · 市场机制 / 物价机制是否科学？—— 部分失灵</h2>
<p>价格公式本身（缺货/库存/成本锚 5 分量加权 + 涨跌限幅 + 硬上下限）设计是合理的，但在本场景暴露两个失灵：</p>
<div class="two">
<div class="chartbox"><h4>初级品价格：全部跌到地板</h4><p class="cap">gathered_plants、fish、flint、raw_hide 供过于求，价格被打到 min_price 后钉死。</p><div class="cv" id="c_praw"></div></div>
<div class="chartbox"><h4>加工品价格：全部顶到天花板</h4><p class="cap">processed_food、tools、game_meat、cloth 因供给物理归零，价格顶到 max_price 后钉死，缺货率≈100%。</p><div class="cv" id="c_pproc"></div></div>
</div>
<p><b>失灵一：价格触及硬轨后失去调节力。</b> 当加工品供给因建筑停产而物理归零，价格顶到天花板也换不来供给（没有生产者了）；此时高价只是惩罚消费者，无法激励供给——<b>价格信号与产能脱钩</b>。同理初级品跌到地板也止不住过剩。</p>
<div class="chartbox"><h4>商人采购：预算 vs 实际花费（全局）</h4><p class="cap">最后一个周期商人只花掉预算的 <b>0.18%</b>，累计囤积储备高达 367 万（货币单位）。钱进得来、出不去。</p><div class="cv" id="c_merch"></div></div>
<p><b>失灵二：商人做市成了单向蓄水池。</b> 商人收走全部零售收入，却因"库存目标"早已填满 + 留 25% 现金 + 下游需求萎缩，几乎不再采购。结果货币在商人手里越积越多（本格商人存款 850→18.3 万，×21），而生产者拿不到货款、买不起食物。<b>物价机制没有内建"再分配/资金回流"通道，商人利润无法回到实体循环。</b></p>

<!-- Q5 -->
<h2>5 · 各阶层的流动 / 消费 / 存款变化是否科学？—— 不科学</h2>
<div class="chartbox"><h4>各职业存款演变（选定格，货币单位）</h4><p class="cap">商人(紫)、矿工(青)指数级积累；采集者(黄)、渔民被榨到接近零；猎人/工匠归零即死亡。</p><div class="cv tall" id="c_funds"></div></div>
<table>
<tr><th>职业</th><th>day1 人口</th><th>day1 收/支(周期)</th><th>结局</th><th>问题</th></tr>
<tr><td>商人 merchant</td><td>3</td><td class="down">300 / 156</td><td><span class="tag t-ok">存款×21 独大</span></td><td>只进不出，垄断货币</td></tr>
<tr><td>矿工 miner</td><td>4</td><td class="down">29 / 11</td><td><span class="tag t-ok">存款×35</span></td><td>淘金雇员分享暴利</td></tr>
<tr><td>猎人 hunter</td><td>48</td><td class="down">200 / 89</td><td><span class="tag t-bad">全灭</span></td><td>初期最赚→工具断供后归零</td></tr>
<tr><td>工匠 artisan</td><td>3</td><td class="up">2 / 8</td><td><span class="tag t-bad">全灭</span></td><td>day1 即赤字</td></tr>
<tr><td>采集者 forager</td><td>51</td><td class="up">30 / 79</td><td><span class="tag t-warn">贫困存活</span></td><td>主粮贱卖·长期赤字·靠削减消费苟活</td></tr>
<tr><td>渔民 fisher</td><td>24</td><td class="down">45 / 43</td><td><span class="tag t-warn">缓慢流失 24→20</span></td><td>薄利·在死亡线震荡</td></tr>
</table>
<p><b>三大不合理：</b>(1) <b>阶层流动单向锁死</b>——职业绑定建筑，破产者不能转业，只能死；富者（商人/矿工）无天花板地积累。(2) <b>消费—生产错配</b>——生产者卖出的是被打到地板价的初级品，买入的是顶到天花板价的加工品，剪刀差持续放血。(3) <b>存款分化极端</b>——最终 99.9% 财富集中于 7 人，其余生产者存款趋零，货币彻底退出实体循环。这既不符合石器时代应有的低货币化、近平均的经济形态，也让系统丧失自我修复能力。</p>

<!-- Q6 -->
<h2>6 · 如何改进这个经济模型</h2>
<p>按"止血 → 修链 → 通渠 → 稳态"四层，从高到低优先级：</p>

<div class="rec"><h4>① 打通商人资金回流，堵住单向抽血 <span class="pill">最高优先级 · 市场机制</span></h4>
<ul>
<li>给商人设<b>目标现金上限</b>：超过阈值时强制提高采购意愿 / 降低买入压价 / 向本地人群分红，让利润回流实体。</li>
<li>把零售毛利<b>按生产贡献分配</b>给上游生产者，而非全额沉淀在商人；或引入税收-再分配/公共储备渠道。</li>
<li>价格触及天花板且供给=0 时，触发<b>紧急进口/跨格调运</b>或临时降低该链下游的消费权重，避免价格空转。</li>
</ul></div>

<div class="rec"><h4>② 修复产业链单点脆断 <span class="pill">高 · 建筑/配方</span></h4>
<ul>
<li>关键中间品（工具）改为<b>可库存 + 可跨格贸易 + 多下游用途</b>（采集、采石、建造都消耗工具），把工具需求量提高到能养活工匠。</li>
<li>为咽喉环节提供<b>替代/冗余</b>：工具可由多种建筑或家庭自制兜底（已有 <code>input_category_ids</code> 替代机制，但食物/工具链启用为 0，应启用）。</li>
<li>校准 <b>产能:需求 比例</b>——石器工坊 4124/天产能 vs 120/天需求（过剩 30 倍）应大幅下调产能或提高工具消耗率/损耗。</li>
</ul></div>

<div class="rec"><h4>③ 建立转业 / 劳动力再配置机制 <span class="pill">高 · 就业</span></h4>
<ul>
<li>破产建筑释放的工人应能<b>转入有空缺的其它职业</b>（forager/fisher 等低门槛岗位），而不是直接进 unemployed 等死。</li>
<li>失业人群的死亡应更慢、并保留<b>再就业窗口</b>；石器时代尤其应允许"回归采集"这一天然兜底。</li>
</ul></div>

<div class="rec"><h4>④ 修正价格调节的边界行为 <span class="pill">中 · 物价</span></h4>
<ul>
<li>初级品长期贴地板：应让<b>过剩→自动减产/减员迁移</b>（采集者过多时部分转业），而不是无限贱卖 + 靠补贴续命。</li>
<li>复核 <b>producer_support 补贴</b>：当前对滞销初级品按零售价 20% 印钞补贴，掩盖了过剩信号、还在向系统注入货币加剧通胀与集中；应设上限或改为消化过剩产能的定向调节。</li>
</ul></div>

<div class="rec"><h4>⑤ 资源可持续与初始平衡 <span class="pill">中 · 资源/初始化</span></h4>
<ul>
<li>wild_game 储量 384 周期跌 <b>92.5%</b>，虽非本次崩溃首因，但长期不可持续；应校准再生率或狩猎强度。</li>
<li>反常项：<b>timber 暴涨 12 万倍、salt ×31、fertile_soil ×2.4</b>——存在"只生成不消耗"的资源，疑似 generation_floor 配置问题，需排查。</li>
<li>初始人口配比应保证<b>每个职业 day1 收支为正或有足够缓冲</b>（当前工匠/采集者 day1 即赤字），并给关键小族群更大的初始规模/储蓄。</li>
</ul></div>

<div class="foot">
数据来源：选定格逐周期记录（cohorts/buildings/market/resources，cell 1031）+ 全局 runtime summary，共 384 周期。<br>
口径说明：summary 为全局聚合，其余 4 张表为选定格 cell 1031；货币单位 = 原始值 / 10000，物资单位 = 原始值 / 1000，Q16 = /65536。审计误差（人口/货币/物资）全程为 0，数据可信。<br>
逻辑依据：economy_runtime.cpp 价格压力/就业迁移/生产补贴/商人做市算法；建筑配方取自 data/economy/buildings/*.tres。
</div>

</div>
<script>
const D = __DATA__;
Chart.defaults.color='#9aa7b4'; Chart.defaults.borderColor='#2b333d';
Chart.defaults.font.family='-apple-system,Segoe UI,Microsoft YaHei,sans-serif';
const COL={red:'#f85149',grn:'#3fb950',blue:'#58a6ff',amber:'#d29922',purple:'#bc8cff',cyan:'#39c5cf',pink:'#f778ba',gray:'#7d8590',orange:'#e8863c'};
function mk(id,cfg){const c=document.getElementById(id);if(!c)return;cfg.options=cfg.options||{};cfg.options.responsive=true;cfg.options.maintainAspectRatio=false;new Chart(c,cfg);}
function line(day,dss,opt){return {type:'line',data:{labels:day,datasets:dss},options:Object.assign({interaction:{mode:'index',intersect:false},elements:{point:{radius:0}},plugins:{legend:{labels:{boxWidth:12,font:{size:11}}}},scales:{x:{ticks:{maxTicksLimit:9,font:{size:10}},title:{display:true,text:'day'}}}},opt||{})};}

// KPIs
const gk=D.global_kpi, ck=D.cell_kpi;
const kpis=[
 {v:'-56%',l:'全局劳动力 (13.27万→5.85万)',d:'<span class="up">▼ 系统性萎缩</span>'},
 {v:'-41%',l:'选定格人口 (133→78)',d:'<span class="up">▼ 2族灭绝</span>'},
 {v:'99.9%',l:'精英(7人)存款占比',d:'<span class="up">▲ 从18.7%</span>'},
 {v:'0.18%',l:'商人采购/预算 (末周期)',d:'<span class="warn">钱只进不出</span>'},
 {v:ck.wild_game_depleted_pct+'%',l:'wild_game 储量耗竭',d:'<span class="warn">不可持续</span>'},
 {v:gk.susp_last,l:'全局亏损停摆建筑组',d:'<span class="warn">从 0 增长</span>'},
 {v:'≈0',l:'显性失业人口',d:'<span class="down">失业=直接饿死</span>'},
 {v:'0',l:'审计误差(人口/币/物资)',d:'<span class="down">数据可信</span>'},
];
document.getElementById('kpis').innerHTML=kpis.map(k=>`<div class="card kpi"><div class="v">${k.v}</div><div class="l">${k.l}</div><div class="d">${k.d}</div></div>`).join('');

// Q0 labor stacked
mk('c_labor',line(D.global.day,[
 {label:'owner岗位',data:D.global.labor_owner,borderColor:COL.blue,backgroundColor:'rgba(88,166,255,.25)',fill:true,stack:'a',borderWidth:1.5},
 {label:'employee岗位',data:D.global.labor_employee,borderColor:COL.cyan,backgroundColor:'rgba(57,197,207,.4)',fill:true,stack:'a',borderWidth:1.5},
 {label:'失业',data:D.global.unemployed,borderColor:COL.red,backgroundColor:'rgba(248,81,73,.6)',fill:true,stack:'a',borderWidth:1.5},
],{scales:{x:{ticks:{maxTicksLimit:9,font:{size:10}}},y:{stacked:true,title:{display:true,text:'人数'}}}}));

mk('c_wealth',line(D.cell_wealth.day,[
 {label:'精英存款占比 %',data:D.cell_wealth.elite_share_pct,borderColor:COL.red,backgroundColor:'rgba(248,81,73,.15)',fill:true,borderWidth:2},
],{scales:{y:{min:0,max:100,title:{display:true,text:'%'}}}}));

// Q1 pop stacked by prof
const popColors={forager:COL.amber,hunter:COL.orange,fisher:COL.cyan,merchant:COL.purple,miner:COL.gray,artisan:COL.red,agri_worker:COL.grn,subsist_farmer:COL.grn};
const pp=D.cell_pop.by_prof;
mk('c_pop',{type:'line',data:{labels:D.cell_pop.day,datasets:Object.keys(pp).map(k=>({label:k,data:pp[k],borderColor:popColors[k]||COL.blue,backgroundColor:(popColors[k]||COL.blue)+'55',fill:true,stack:'a',borderWidth:1,pointRadius:0}))},
 options:{responsive:true,maintainAspectRatio:false,interaction:{mode:'index',intersect:false},plugins:{legend:{labels:{boxWidth:12,font:{size:11}}}},scales:{x:{ticks:{maxTicksLimit:9,font:{size:10}}},y:{stacked:true,title:{display:true,text:'人口'}}}}});

const sp=D.cell_sat_prof.sat;
mk('c_sat',line(D.cell_sat_prof.day,Object.keys(sp).map(k=>({label:k,data:sp[k],borderColor:popColors[k]||COL.blue,borderWidth:1.6,spanGaps:true})),
 {scales:{y:{min:0,max:1.05,title:{display:true,text:'满意度'}}},plugins:{legend:{labels:{boxWidth:12,font:{size:11}}},annotation:{}}}));

// Q2 building output
const bo=D.buildings.output;
const bKeys=['hunting_camp','knapping_workshop','communal_hearth','gathering_ground','fish_collector','stone_collector','placer_gold','subsistence_farm'];
const bCol={hunting_camp:COL.red,knapping_workshop:COL.pink,communal_hearth:COL.amber,gathering_ground:COL.grn,fish_collector:COL.cyan,stone_collector:COL.gray,placer_gold:COL.purple,subsistence_farm:COL.blue};
mk('c_bout',line(D.buildings.day,bKeys.filter(k=>bo[k]).map(k=>({label:k,data:bo[k],borderColor:bCol[k],borderWidth:1.6})),
 {scales:{y:{title:{display:true,text:'日产出(物资单位)'},type:'logarithmic'}}}));

// Q3 income/expense by prof
const inc=D.cell_income_prof.income, exp=D.cell_income_prof.expense;
const incKeys=['artisan','forager','hunter','merchant','fisher','miner'];
mk('c_inc',line(D.cell_income_prof.day, incKeys.flatMap(k=>[
 {label:k+' 收',data:inc[k],borderColor:popColors[k]||COL.blue,borderWidth:1.4,spanGaps:true},
]),{scales:{y:{title:{display:true,text:'周期收入(货币)'},type:'logarithmic'}}}));

// Q4 prices raw
const pr=D.prices.raw;
mk('c_praw',line(D.prices.day,Object.keys(pr).map((k,i)=>({label:k,data:pr[k],borderColor:[COL.grn,COL.cyan,COL.gray,COL.amber,COL.blue][i],borderWidth:1.5})),
 {scales:{y:{title:{display:true,text:'价格(货币)'}}}}));
const pc=D.prices.proc;
mk('c_pproc',line(D.prices.day,Object.keys(pc).map((k,i)=>({label:k,data:pc[k],borderColor:[COL.red,COL.pink,COL.orange,COL.amber,COL.purple,COL.cyan][i],borderWidth:1.5})),
 {scales:{y:{title:{display:true,text:'价格(货币)'}}}}));

// Q4 merchant hoarding
mk('c_merch',line(D.global.day,[
 {label:'采购预算',data:D.global.merch_budget,borderColor:COL.blue,borderWidth:1.6},
 {label:'实际花费',data:D.global.merch_spent,borderColor:COL.red,borderWidth:1.6},
 {label:'累计囤积储备',data:D.global.merch_reserved,borderColor:COL.amber,borderWidth:1.6,borderDash:[5,3]},
],{scales:{y:{title:{display:true,text:'货币单位'},type:'logarithmic'}}}));

// Q5 funds by prof
const fp=D.cell_funds.by_prof;
mk('c_funds',line(D.cell_funds.day,Object.keys(fp).map(k=>({label:k,data:fp[k],borderColor:popColors[k]||COL.blue,borderWidth:1.6})),
 {scales:{y:{title:{display:true,text:'存款(货币单位)'}}}}));
</script>
</body></html>"""

HTML = HTML.replace("__DATA__", DATA_JS)
open("D:/Godot/ProjectKeynes/Project.Keynes/tmp/经济运行时深度分析报告.html","w",encoding="utf-8").write(HTML)
print("written HTML, size", len(HTML))
