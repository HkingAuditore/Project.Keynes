# -*- coding: utf-8 -*-
import json
with open(r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\_econ_data.json","r",encoding="utf-8") as f:
    data = f.read()

HTML = r"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Project.Keynes 石器时代经济运行时深度诊断报告</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js"></script>
<style>
:root{
  --bg:#0d1117; --panel:#161b22; --panel2:#1c2230; --border:#2d3542;
  --txt:#e6edf3; --dim:#9aa7b4; --accent:#58a6ff; --red:#f85149; --green:#3fb950;
  --amber:#d29922; --purple:#bc8cff; --cyan:#39c5cf; --pink:#f778ba;
}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--txt);font-family:-apple-system,"Segoe UI","Microsoft YaHei",sans-serif;line-height:1.7;font-size:15px}
.wrap{max-width:1180px;margin:0 auto;padding:32px 24px 80px}
header{border-bottom:1px solid var(--border);padding-bottom:24px;margin-bottom:32px}
h1{font-size:30px;font-weight:700;letter-spacing:-.5px;background:linear-gradient(90deg,#58a6ff,#bc8cff);-webkit-background-clip:text;background-clip:text;-webkit-text-fill-color:transparent}
.sub{color:var(--dim);margin-top:10px;font-size:14px}
.meta{display:flex;gap:20px;flex-wrap:wrap;margin-top:14px;font-size:13px;color:var(--dim)}
.meta span b{color:var(--accent)}
h2{font-size:22px;margin:44px 0 8px;padding-left:12px;border-left:4px solid var(--accent);font-weight:650}
h2 .q{color:var(--dim);font-size:14px;font-weight:400;margin-left:8px}
h3{font-size:17px;margin:26px 0 10px;color:var(--cyan)}
p{margin:10px 0;color:#d7dee6}
.lead{font-size:15px}
.card{background:var(--panel);border:1px solid var(--border);border-radius:12px;padding:20px 22px;margin:18px 0}
.verdict{display:flex;align-items:center;gap:14px;background:linear-gradient(135deg,#2a1215,#1a0e10);border:1px solid #5c2626;border-radius:12px;padding:18px 22px;margin:20px 0}
.verdict .big{font-size:34px}
.verdict .t b{color:var(--red);font-size:18px}
.kpis{display:grid;grid-template-columns:repeat(4,1fr);gap:14px;margin:22px 0}
.kpi{background:var(--panel);border:1px solid var(--border);border-radius:10px;padding:16px}
.kpi .v{font-size:26px;font-weight:700}
.kpi .l{color:var(--dim);font-size:12.5px;margin-top:4px}
.kpi .d{font-size:12px;margin-top:6px}
.down{color:var(--red)} .up{color:var(--green)}
.chart-box{background:var(--panel);border:1px solid var(--border);border-radius:12px;padding:18px 20px;margin:20px 0}
.chart-box .cap{font-size:13px;color:var(--dim);margin-bottom:12px}
.chart-box .cap b{color:var(--txt)}
.grid2{display:grid;grid-template-columns:1fr 1fr;gap:20px}
canvas{max-height:300px}
ul{margin:10px 0 10px 4px;list-style:none}
li{margin:8px 0;padding-left:22px;position:relative;color:#d7dee6}
li:before{content:"▸";position:absolute;left:0;color:var(--accent)}
.bad:before{content:"✕";color:var(--red)}
.good:before{content:"✓";color:var(--green)}
.warn:before{content:"!";color:var(--amber);font-weight:700}
table{width:100%;border-collapse:collapse;margin:14px 0;font-size:13px}
th,td{padding:8px 10px;text-align:right;border-bottom:1px solid var(--border)}
th{color:var(--dim);font-weight:600;text-align:right}
th:first-child,td:first-child{text-align:left}
tr:hover td{background:var(--panel2)}
.tag{display:inline-block;padding:2px 8px;border-radius:6px;font-size:12px;font-weight:600}
.tag.stop{background:#3d1518;color:#f85149} .tag.ok{background:#132d1c;color:#3fb950} .tag.idle{background:#2d2410;color:#d29922}
.flow{background:var(--panel2);border:1px dashed var(--border);border-radius:10px;padding:16px 20px;margin:16px 0;font-family:"Cascadia Code",Consolas,monospace;font-size:13px;line-height:2;color:var(--cyan);overflow-x:auto;white-space:pre}
.callout{border-left:3px solid var(--amber);background:#1e1a10;padding:12px 16px;border-radius:0 8px 8px 0;margin:14px 0;color:#e8dcc0;font-size:14px}
.callout.red{border-color:var(--red);background:#1e1012;color:#f0c9c9}
.callout.blue{border-color:var(--accent);background:#0f1826;color:#c4d8f0}
code{background:#22283180;padding:1px 6px;border-radius:5px;font-family:Consolas,monospace;font-size:13px;color:var(--pink)}
.ref{color:var(--dim);font-size:12px}
.fix{background:var(--panel);border:1px solid var(--border);border-left:4px solid var(--green);border-radius:0 10px 10px 0;padding:14px 18px;margin:14px 0}
.fix .h{font-weight:650;color:var(--green);margin-bottom:6px}
.pri{display:inline-block;font-size:11px;padding:1px 7px;border-radius:5px;margin-right:8px;font-weight:700}
.p0{background:#3d1518;color:#f85149} .p1{background:#2d2410;color:#d29922} .p2{background:#0f2233;color:#58a6ff}
.foot{margin-top:50px;padding-top:20px;border-top:1px solid var(--border);color:var(--dim);font-size:12.5px}
@media(max-width:820px){.kpis{grid-template-columns:repeat(2,1fr)}.grid2{grid-template-columns:1fr}}
</style>
</head>
<body>
<div class="wrap">
<header>
  <h1>Project.Keynes 经济运行时深度诊断报告</h1>
  <div class="sub">石器时代单格经济（cell 1031）· 385 个采样周期 · 游戏日 15 → 1930（约 5.2 游戏年）</div>
  <div class="meta">
    <span>数据源 <b>economy_record_20260717_114418_v5</b></span>
    <span>周期 <b>5 日/commit</b></span>
    <span>模式 <b>ACTIVE / trade_planning</b></span>
    <span>守恒误差 <b>pop/money/goods = 0</b></span>
  </div>
</header>

<div class="verdict">
  <div class="big">🩸</div>
  <div class="t"><b>总体诊断：不健康 —— 一个正在缓慢死亡的"萎缩型经济"</b><br>
  <span style="color:var(--dim)">这不是"失业问题"，而是产业链断裂 + 货币单向虹吸 + 人口只死不生三重机制叠加导致的结构性崩溃。</span></div>
</div>

<div class="kpis">
  <div class="kpi"><div class="v down">-55%</div><div class="l">全局在岗人口</div><div class="d down">13.3万 → 5.9万</div></div>
  <div class="kpi"><div class="v down">-100%</div><div class="l">生产者阶层财富占比</div><div class="d down">81.3% → 0.1%</div></div>
  <div class="kpi"><div class="v up">+352%</div><div class="l">商人阶层财富占比</div><div class="d up">13% → 59%</div></div>
  <div class="kpi"><div class="v down">0.639</div><div class="l">人口加权满意度</div><div class="d down">1.00 → 0.64</div></div>
</div>

<div class="callout red">
<b>先厘清一个关键误解：这个模型并没有"大量失业者"。</b>
全局失业人口从 0 缓慢升到约 330 人，失业率始终 &lt;0.5%；cell 1031 内部失业恒为 0。真正发生的是 —— <b>人口在持续死亡而非失业</b>。经查源码，运行时<b>根本没有实现出生机制</b>（<code>births</code> 恒为 0），人口只减不增，任何饥饿死亡都不可逆。所谓"失业感"来自建筑用工的严重错配（下详）。
</div>

<!-- ============ Q0 ============ -->
<h2>0. 当前经济运行的特点 <span class="q">Q0 — 它是什么样子的？</span></h2>
<div class="card">
<ul>
<li><b>单调萎缩</b>：在岗人口、生产总值、货币周转全线单调下滑，5 游戏年腰斩，无任何反弹周期。</li>
<li><b>财富极端极化</b>：货币 100% 虹吸到商人 + 少数精英（manager/metallurgist），生产者（forager/hunter/artisan/fisher）现金彻底归零。</li>
<li class="warn"><b>"原料贱、成品贵"的畸形价格结构</b>：燧石/采集植物/鱼/生皮等原料跌到价格地板；石器工具/兽肉/毛皮/布匹等成品全部顶到价格天花板并<b>断供</b>。</li>
<li class="bad"><b>加工业全面停摆</b>：11 类建筑中，打制石器工坊、织布棚、狩猎营地先后停产至 0 产出；只剩"资源直采"型（采石/采集/砂金/采银）苟活。</li>
<li><b>资源不可持续</b>：消耗型资源 <code>wild_game</code>（猎物）从 3349 枯竭到 353（-89%），<code>clay</code> -68%，且无再生配置。</li>
</ul>
</div>
<div class="chart-box"><div class="cap"><b>图 0-1｜三大阶层财富占比逆转</b>：生产者（绿）被榨干，商人（红）通吃 —— 货币的单向流动是整个模型的病根</div><canvas id="c_fpct"></canvas></div>
<div class="grid2">
  <div class="chart-box"><div class="cap"><b>图 0-2｜全局在岗人口崩塌</b>（summary 口径）</div><canvas id="c_glob"></canvas></div>
  <div class="chart-box"><div class="cap"><b>图 0-3｜人口加权满意度</b>：跌破 0.65，生产者仅 0.4~0.5</div><canvas id="c_sat"></canvas></div>
</div>

<!-- ============ Q1 ============ -->
<h2>1. 经济是否健康？ <span class="q">Q1</span></h2>
<div class="card">
<p class="lead"><b>不健康，且处于不可逆的下行螺旋。</b>判断依据：</p>
<ul>
<li class="bad">总量指标全线单调下滑，无自我修复能力（生产总值 8.5亿 → 1.5亿，-82%）。</li>
<li class="bad">分配严重失衡：生产者财富占比 81%→0.1%，基尼系数事实上逼近 1。</li>
<li class="bad">需求满足恶化：worst_need 从 <code>produce</code>(果蔬) 一路恶化到 <code>protein</code>(蛋白)、<code>staple_food</code>(主食) —— 连生存需求都开始崩。</li>
<li class="warn">唯一"稳定"的是砂金/采银建筑（利润率顶格），但它们只服务货币囤积、不解决温饱，反而加剧极化。</li>
</ul>
<div class="callout">健康的经济应有：出生↔死亡的动态平衡、货币的循环回流、价格围绕成本波动而非顶格/触底。此模型三者皆缺。</div>
</div>
<div class="chart-box"><div class="cap"><b>图 1-1｜宏观生产与生产者补贴（百万单位）</b>：output 与 support 同步崩溃，两者互为因果</div><canvas id="c_macro"></canvas></div>

<!-- ============ Q2 ============ -->
<h2>2. 为什么会产生"大量失业者"？ <span class="q">Q2 — 真相是用工错配 + 只死不生</span></h2>
<div class="card">
<p>数据层面失业率极低，但用户的直觉并非错觉，其根源是两个机制缺陷：</p>
<h3>① 就业分配算法把人堆到高利润建筑，饿死低优先级建筑</h3>
<p class="ref">源码 <code>assign_building_employment</code>（economy_runtime.cpp:4402-4730）</p>
<p>招募优先级 = <code>利润率↓ → 利用率↓ → group_index↑</code>。同一 owner_signature（职业+族群）的人口被<b>整体分给最赚钱的 group</b>，导致：</p>
<table>
<tr><th>建筑</th><th>owner需求</th><th>实际在岗</th><th>状态</th></tr>
<tr><td>采集地 gathering_ground</td><td>7</td><td>48</td><td><span class="tag idle">超配 6.8×</span></td></tr>
<tr><td>海鱼采集点</td><td>3</td><td>20</td><td><span class="tag idle">超配</span></td></tr>
<tr><td>狩猎营地 hunting_camp</td><td>48</td><td>0</td><td><span class="tag stop">完全空置</span></td></tr>
<tr><td>打制石器工坊</td><td>1</td><td>0</td><td><span class="tag stop">停产</span></td></tr>
</table>
<p>结果：一边是建筑"塞满了用不完的人"（虚高就业），一边是关键建筑"招不到人"（隐性失业）。这种<b>错配</b>让玩家看到"很多人挤在采集地却没肉吃"，主观感受就是"经济里全是闲人"。</p>
<h3>② 人口模型只有死亡、没有出生（最根本）</h3>
<p class="ref">源码验证：<code>Signature::birth_rate_q32</code>、<code>MarketResult::births</code> 在整个 .cpp 中<b>从未被写入</b>；人口守恒式 <code>closing = opening + births - deaths + migration</code> 中 births≡0（economy_runtime.cpp:9085）</p>
<p>饥饿死亡（<code>survival_q16 &lt; 0.5</code> 触发，economy_runtime.cpp:8603-8615）不断削减生产者，却没有新生人口补充。生产者一旦破产 → 买不起食物 → 饿死 → 永久消失。这是"人口从 13 万崩到 5.9 万"的直接原因。</p>
</div>
<div class="chart-box"><div class="cap"><b>图 2-1｜各建筑 owner 在岗人数</b>：狩猎营地(紫)从 48 一路归 0，打石工坊(红)开局即死；只有采集地(绿)被塞满 48 人</div><canvas id="c_own"></canvas></div>

<!-- ============ Q3 ============ -->
<h2>3. 各建筑的原材料 / 产出设计是否科学？ <span class="q">Q3 — 局部合理，全局链条脆弱</span></h2>
<div class="card">
<p>单个建筑的配方本身尚属合理（燧石→石器、猎物→兽肉毛皮），但<b>产业链的拓扑结构存在致命的单点依赖</b>：</p>
<div class="flow">资源:燧石 ──▶ [燧石采石场] ──▶ flint ──▶ [打制石器工坊·artisan] ──▶ chipped_stone_tools(石器工具)
                                                                          │
                          ┌───────────────────────────────────────────────┘  ← 唯一来源，单点！
                          ▼
资源:wild_game ─┐
              ├──▶ [狩猎营地·hunter] ──▶ game_meat / raw_hide / fur ──▶ 满足 protein 需求
石器工具(投入)─┘        （投入品断供则整条链停摆）</div>
<p class="lead">崩溃的第一张多米诺骨牌 —— <b>打制石器工坊在 day 15~215 之间就停产了</b>（artisan 阶层最先破产退出）。连锁反应：</p>
<ul>
<li class="bad"><b>工具断供</b>：chipped_stone_tools 供给归零，价格 9253→90000 顶格，库存→1。</li>
<li class="bad"><b>狩猎营地失去投入品</b>：owner 从 48 一路萎缩到 0，game_meat/fur 断供、价格顶格。</li>
<li class="bad"><b>肉食链彻底断裂</b>：protein 需求无法满足 → 生产者满意度崩 → 饿死。</li>
</ul>
<div class="callout red"><b>设计缺陷定性：</b>①关键中间品（石器工具）<b>唯一生产者</b>，无冗余、无替代路径实际生效；②生产建筑之间存在<b>刚性投入依赖</b>，任一环破产即全链雪崩；③消耗型资源（猎物）<b>无再生机制</b>，即使有猎人也会耗尽。</div>
</div>
<div class="grid2">
  <div class="chart-box"><div class="cap"><b>图 3-1｜关键商品价格</b>：成品(石器/兽肉/布)顶到天花板，原料(燧石/采集植物)贴地板</div><canvas id="c_price"></canvas></div>
  <div class="chart-box"><div class="cap"><b>图 3-2｜关键商品库存</b>：原料堆积(燧石↑)、成品清零 —— 典型的产业链断裂</div><canvas id="c_stock"></canvas></div>
</div>
<div class="chart-box"><div class="cap"><b>图 3-3｜消耗型资源枯竭（相对初始值%）</b>：猎物剩 10%、黏土剩 32%，且无再生</div><canvas id="c_res"></canvas></div>

<!-- ============ Q4 ============ -->
<h2>4. 市场机制 / 物价机制是否科学？ <span class="q">Q4 — 机制自洽，但缺乏稳定器</span></h2>
<div class="card">
<p>价格由多因子压力合成（供需 excess + 库存 inventory + 短缺 shortage + 成本锚 cost + 闲置回归 idle），随后被 <code>[min_price, max_price]</code> 夹逼（economy_runtime.cpp:3935-3949, 6635-6649）。机制设计本身是合理的，但存在几个稳定性缺陷：</p>
<ul>
<li class="bad"><b>缺乏"停产即断供→价格顶格→更买不起"的负反馈熔断</b>：供给归零时 excess/inventory/shortage 三重正压叠加，价格瞬间冲到 max 并锁死，没有任何机制拉它回来。</li>
<li class="warn"><b>成本锚（cost_anchor）在断供时失效</b>：其置信度 <code>confidence = supply/demand</code>，供给→0 时置信度→0，成本地板托不住暴涨。</li>
<li class="bad"><b>冻结期价格变动被 ×epoch_days 放大</b>（6638 行），5 日一次的调整让价格在一个周期内就能从底冲到顶，波动过猛。</li>
<li class="warn"><b>货币分配机制单向</b>：家庭消费与生产投入采购的钱<b>全额流入本地商人</b>（8484-8524），商人再以 25% 现金留存 + 折价收购的方式囤钱，缺乏向生产者回流的通道（税收/再分配/借贷皆无）。</li>
</ul>
<div class="callout">物价机制的数学是对的，但它<b>只有加速器没有刹车</b>。真实经济里，价格暴涨会刺激供给、抑制需求形成回归；此模型中供给端已死，价格信号无法转化为产量，于是价格永久卡在极值。</div>
</div>

<!-- ============ Q5 ============ -->
<h2>5. 各阶层的流动 / 消费 / 存款变化是否科学？ <span class="q">Q5 — 部分合理，但缺回流与再生</span></h2>
<div class="card">
<table>
<tr><th>阶层</th><th>人口变化</th><th>财富变化</th><th>评价</th></tr>
<tr><td>生产者 (forager/hunter/artisan/fisher)</td><td>126 → 71</td><td class="down">占比 81%→0.1%（归零）</td><td><span class="tag stop">被榨干</span></td></tr>
<tr><td>商人 (merchant)</td><td>3 → 3</td><td class="up">占比 13%→59%（暴涨）</td><td><span class="tag idle">通吃</span></td></tr>
<tr><td>精英 (manager/metallurgist)</td><td>4 → 4</td><td class="up">占比 5.7%→40%</td><td><span class="tag idle">囤积</span></td></tr>
</table>
<h3>消费机制（合理的部分）</h3>
<p>消费需求随人均财富弹性变化（<code>wealth_factor = (funds/pop / 参考值)^弹性</code>，economy_runtime.cpp:894-908），按 need 优先级分级预算 —— 穷了先砍奢侈品、保生存需求，这个设计是<b>科学的</b>。</p>
<h3>存款与流动（不合理的部分）</h3>
<ul>
<li class="bad"><b>没有"消费↔生产"的闭环</b>：生产者赚的钱花给商人，商人的钱却不会通过工资/采购流回生产者。财富是<b>单向漏斗</b>而非循环。</li>
<li class="bad"><b>阶层流动是单向死亡</b>：破产的生产者只能饿死消失，不能转职、不能被救济、不能重新创业（无出生/无转化通道）。</li>
<li class="warn"><b>精英/商人的巨额存款是"死钱"</b>：1.8 亿囤在商人手里既不投资也不消费，对经济毫无拉动，纯粹是记账上的堰塞湖。</li>
</ul>
</div>
<div class="chart-box"><div class="cap"><b>图 5-1｜三大阶层人口</b>：生产者(绿)持续流失，商人/精英(红/紫)人数纹丝不动却越来越富</div><canvas id="c_pop"></canvas></div>

<!-- ============ Q6 ============ -->
<h2>6. 如何改进这个经济模型？ <span class="q">Q6 — 按优先级排序的处方</span></h2>

<div class="fix"><div class="h"><span class="pri p0">P0 致命</span>实现人口出生 / 补充机制</div>
<p>当前 <code>births≡0</code> 是萎缩的总开关。至少实现：满意度/富裕度驱动的出生率（<code>Signature::birth_rate_q32</code> 已有字段悬空，接上写入路径即可），或跨 cell 人口迁入。<b>没有这一条，任何其他修复都只是延缓死亡。</b></p></div>

<div class="fix"><div class="h"><span class="pri p0">P0 致命</span>打破产业链单点依赖 + 给消耗型资源加再生</div>
<ul>
<li>为 chipped_stone_tools 这类关键中间品<b>增加冗余生产者</b>，或让 <code>input_category_ids</code> 的替代路径真正在食物/工具链上启用（当前食物链 0 栋建筑启用替代）。</li>
<li>为 hunting_camp 增加"无工具也能低效运作"的降级模式（工具作为效率加成而非硬投入）。</li>
<li>给 wild_game 等消耗型资源配置 <code>resource_generation</code>（自然再生），或把 extract 改为 capacity 型上限约束。</li>
</ul></div>

<div class="fix"><div class="h"><span class="pri p0">P0 致命</span>建立货币回流通道，切断商人单向虹吸</div>
<p>这是极化的根源。可选方案：①商人利润按比例<b>再投资/雇佣</b>本地生产者；②引入<b>税收→公共补贴</b>把商人囤积的钱转移给贫困阶层；③把生产者补贴（producer_support）从当前的 1/5 市价折价、且随停产消失，改为<b>逆周期兜底</b>（越困难补贴越强），并让补贴资金来自商人存量而非凭空铸币。</p></div>

<div class="fix"><div class="h"><span class="pri p1">P1 重要</span>修复就业分配错配</div>
<p><code>assign_building_employment</code> 的"利润优先"策略应加入<b>基本盘约束</b>：先保证食物/工具等民生建筑的最低用工，再把剩余劳力按利润分配。避免出现"48 个岗位 0 人 / 7 个岗位 48 人"的荒诞配置。</p></div>

<div class="fix"><div class="h"><span class="pri p1">P1 重要</span>给物价加"刹车"与熔断</div>
<ul>
<li>当某商品供给持续为 0，<b>抑制其价格继续顶格</b>（既然买不到，涨价无意义且伤害需求方）。</li>
<li>降低冻结期 <code>×epoch_days</code> 的价格放大，或对单周期价格变动幅度设更紧的上限，避免一周期从地板冲天花板。</li>
<li>断供时用 <b>历史成交价 / 默认价</b> 兜底成本锚，而非让 confidence 归零后失锚。</li>
</ul></div>

<div class="fix"><div class="h"><span class="pri p2">P2 优化</span>激活"死钱"与阶层转化</div>
<ul>
<li>允许破产生产者<b>转职</b>（forager↔hunter↔artisan）而非直接死亡，给劳动力再配置的弹性。</li>
<li>让商人/精英的巨额存款产生<b>投资/建筑扩张</b>行为，把堰塞湖变成活水。</li>
</ul></div>

<div class="callout blue"><b>改进优先级总结：</b>先接上"出生"止住人口失血（P0）→ 再打破产业链单点 + 资源再生让生产可持续（P0）→ 再建货币回流切断极化（P0）→ 最后修用工分配与物价刹车（P1）。前三条任缺其一，经济仍会缓慢死亡。</div>

<div class="foot">
本报告基于 5 个 CSV（summary / buildings / cohorts / market / resources 共 6.4 万行）的全时间序列分析，并交叉验证 <code>economy_runtime.cpp</code>（12530 行）的就业、消费、物价、生产、人口机制实现。所有数值均来自实际采样数据，机制结论均带源码行号引用。id 语义映射：need/profession/building 均按 <code>data/economy/*</code> 目录文件名字母序 0-based 索引（economy_catalog.gd:864 <code>paths.sort()</code>）。<br>
砚灯 · Project.Keynes 经济诊断 · 生成于 2026-07-17
</div>
</div>

<script>
const DATA = __DATA__;
Chart.defaults.color = '#9aa7b4';
Chart.defaults.borderColor = '#2d354233';
Chart.defaults.font.family = "'Segoe UI','Microsoft YaHei',sans-serif";
const days = DATA.days;
const C = {red:'#f85149',green:'#3fb950',blue:'#58a6ff',amber:'#d29922',purple:'#bc8cff',cyan:'#39c5cf',pink:'#f778ba',gray:'#6e7681'};
function baseOpt(extra){return Object.assign({responsive:true,maintainAspectRatio:false,interaction:{mode:'index',intersect:false},
  plugins:{legend:{labels:{boxWidth:12,font:{size:11}}}},
  scales:{x:{ticks:{maxTicksLimit:8,font:{size:10}},grid:{display:false}},y:{ticks:{font:{size:10}},grid:{color:'#2d354233'}}}},extra||{});}
function line(id,ds,extra){new Chart(document.getElementById(id),{type:'line',data:{labels:days,datasets:ds},options:baseOpt(extra)});}
const thin={pointRadius:0,borderWidth:2,tension:.25};

// 0-1 财富占比
line('c_fpct',[
 {label:'生产者',data:DATA.fpct.producer,borderColor:C.green,backgroundColor:C.green+'22',fill:true,...thin},
 {label:'商人',data:DATA.fpct.merchant,borderColor:C.red,backgroundColor:C.red+'22',fill:true,...thin},
 {label:'精英',data:DATA.fpct.elite,borderColor:C.purple,backgroundColor:C.purple+'22',fill:true,...thin},
],{scales:{y:{stacked:false,title:{display:true,text:'财富占比 %'}}}});

// 0-2 全局就业
line('c_glob',[
 {label:'业主岗',data:DATA.glob.owner,borderColor:C.blue,...thin},
 {label:'雇员岗',data:DATA.glob.emp,borderColor:C.cyan,...thin},
 {label:'失业',data:DATA.glob.unemp,borderColor:C.red,...thin},
]);

// 0-3 满意度
line('c_sat',[{label:'满意度',data:DATA.sat,borderColor:C.amber,backgroundColor:C.amber+'22',fill:true,...thin}],
 {scales:{y:{min:0,max:1}}});

// 1-1 宏观
line('c_macro',[
 {label:'生产总值(百万)',data:DATA.macro.output,borderColor:C.blue,...thin},
 {label:'生产者补贴(百万)',data:DATA.macro.support,borderColor:C.amber,...thin},
 {label:'建筑工资(百万)',data:DATA.macro.wages,borderColor:C.green,...thin},
]);

// 2-1 建筑owner
const ownColors={'采集地':C.green,'狩猎营地':C.purple,'打制石器工坊':C.red,'海鱼采集点':C.cyan,'织布棚':C.pink,'砂金开采':C.amber,'地表采银':C.gray};
line('c_own',Object.keys(DATA.build_own).filter(k=>['采集地','狩猎营地','打制石器工坊','海鱼采集点','织布棚'].includes(k)).map(k=>(
 {label:k,data:DATA.build_own[k],borderColor:ownColors[k]||C.gray,...thin}
)));

// 3-1 价格
const pcolor={flint:C.gray,chipped_stone_tools:C.red,game_meat:C.purple,fur:C.pink,cloth:C.cyan,gathered_plants:C.green,fish:C.blue};
const pname={flint:'燧石(料)',chipped_stone_tools:'石器工具(成)',game_meat:'兽肉(成)',fur:'毛皮(成)',cloth:'布匹(成)',gathered_plants:'采集植物(料)',fish:'鱼(料)'};
line('c_price',['flint','chipped_stone_tools','game_meat','fur','cloth','gathered_plants'].map(g=>(
 {label:pname[g],data:DATA.price[g],borderColor:pcolor[g],...thin}
)));

// 3-2 库存
line('c_stock',['flint','chipped_stone_tools','game_meat','cloth','gathered_plants'].map(g=>(
 {label:pname[g],data:DATA.stock[g],borderColor:pcolor[g],...thin}
)));

// 3-3 资源
const rcolor={wild_game:C.red,clay:C.amber,fertile_soil:C.green,flint:C.gray,marine_fish:C.blue};
const rname={wild_game:'猎物',clay:'黏土',fertile_soil:'肥沃土壤',flint:'燧石',marine_fish:'海鱼'};
line('c_res',Object.keys(DATA.res).map(r=>(
 {label:rname[r]||r,data:DATA.res[r],borderColor:rcolor[r]||C.gray,...thin}
)),{scales:{y:{title:{display:true,text:'剩余 % (相对初始)'}}}});

// 5-1 人口
line('c_pop',[
 {label:'生产者',data:DATA.pop.producer,borderColor:C.green,...thin},
 {label:'商人',data:DATA.pop.merchant,borderColor:C.red,...thin},
 {label:'精英',data:DATA.pop.elite,borderColor:C.purple,...thin},
]);
</script>
</body>
</html>"""

HTML = HTML.replace("__DATA__", data)
out = r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\经济运行时深度诊断报告.html"
with open(out,"w",encoding="utf-8") as f:
    f.write(HTML)
print("written:", out, len(HTML), "chars")
