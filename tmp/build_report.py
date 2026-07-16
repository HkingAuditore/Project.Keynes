# -*- coding: utf-8 -*-
import base64, os
OUT="charts"
def img(name):
    with open(os.path.join(OUT,name),"rb") as f:
        return "data:image/png;base64,"+base64.b64encode(f.read()).decode()

imgs={k:img(v) for k,v in {
 'emp':'01_employment.png','funds':'02_funds.png','sub':'03_subsidy.png',
 'price':'04_prices.png','bld':'05_buildings.png','ineq':'06_inequality.png'}.items()}

html=f"""<!DOCTYPE html><html lang="zh"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Project.Keynes 经济运行时诊断报告</title>
<style>
:root{{--bg:#0f1419;--panel:#1a2029;--panel2:#212a35;--fg:#e6e6e6;--mut:#93a1b0;--line:#2b3542;
--red:#ff5252;--grn:#4caf50;--blu:#42a5f5;--org:#ffa726;--yel:#ffee58;--cyn:#26c6da;}}
*{{box-sizing:border-box}}
body{{margin:0;background:var(--bg);color:var(--fg);font-family:"Microsoft YaHei","Segoe UI",system-ui,sans-serif;line-height:1.75;font-size:15px}}
.wrap{{max-width:960px;margin:0 auto;padding:36px 22px 80px}}
h1{{font-size:26px;font-weight:800;letter-spacing:.5px;margin:0 0 6px}}
.sub{{color:var(--mut);font-size:13px;margin-bottom:26px}}
h2{{font-size:20px;margin:38px 0 12px;padding-left:12px;border-left:4px solid var(--blu)}}
h2 .q{{color:var(--blu);font-weight:800;margin-right:8px}}
h3{{font-size:16px;margin:20px 0 8px;color:var(--cyn)}}
p{{margin:8px 0}}
.card{{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:18px 20px;margin:16px 0}}
.verdict{{display:inline-block;padding:3px 12px;border-radius:20px;font-weight:700;font-size:13px;margin-bottom:8px}}
.bad{{background:rgba(255,82,82,.15);color:var(--red);border:1px solid var(--red)}}
.warn{{background:rgba(255,167,38,.15);color:var(--org);border:1px solid var(--org)}}
.ok{{background:rgba(76,175,80,.15);color:var(--grn);border:1px solid var(--grn)}}
img{{width:100%;border-radius:10px;border:1px solid var(--line);margin:10px 0;display:block}}
ul{{margin:8px 0 8px 4px;padding-left:20px}}li{{margin:5px 0}}
code{{background:var(--panel2);padding:1px 6px;border-radius:5px;color:var(--yel);font-size:13px}}
.kpi{{display:grid;grid-template-columns:repeat(4,1fr);gap:12px;margin:20px 0}}
.kpi div{{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:14px;text-align:center}}
.kpi .n{{font-size:24px;font-weight:800}}.kpi .l{{font-size:12px;color:var(--mut);margin-top:4px}}
.r{{color:var(--red)}}.g{{color:var(--grn)}}.o{{color:var(--org)}}.b{{color:var(--blu)}}
table{{width:100%;border-collapse:collapse;margin:12px 0;font-size:13.5px}}
th,td{{border:1px solid var(--line);padding:7px 10px;text-align:left}}
th{{background:var(--panel2);color:var(--cyn)}}
.hl{{background:var(--panel2);border-left:3px solid var(--org);padding:10px 14px;border-radius:0 8px 8px 0;margin:12px 0}}
.foot{{color:var(--mut);font-size:12px;margin-top:40px;border-top:1px solid var(--line);padding-top:16px}}
</style></head><body><div class="wrap">
<h1>🕯️ Project.Keynes 经济运行时诊断报告</h1>
<div class="sub">样本：<code>cell501_q15_r12 · v5</code> ｜ 434 个结算周期（5天/周期，约 2170 天）｜ 单一 cell 本地市场 ｜ 生成于 2026-07-16</div>

<div class="kpi">
<div><div class="n r">~43%</div><div class="l">稳态失业率（峰值54%）</div></div>
<div><div class="n r">0</div><div class="l">雇员就业 / 工资发放全程为0</div></div>
<div><div class="n o">~78%</div><div class="l">产出靠铸币救济兜底</div></div>
<div><div class="n b">219</div><div class="l">人口冻结 · 无增长无崩溃</div></div>
</div>

<div class="card">
<div class="verdict bad">总体判断：不健康 · 已陷入"补贴维生"的伪稳态</div>
<p>会计层面完全守恒（<code>population_error / money_error / goods_error</code> 全程为 0，说明结算引擎正确），但<b>行为层面已经崩了</b>：雇佣劳动市场没有真正运转，近八成产出卖不出去、只能靠系统铸币"生产者救济"消化，居民存款单调膨胀，需求侧持续萎缩。系统没有死，但它是靠印钞在续命，而不是靠真实的生产-交换循环。</p>
</div>

<h2><span class="q">0.</span>当前经济运行体现出什么特点？</h2>
<div class="card">
<h3>特点一：静止的"僵尸稳态"</h3>
<p>人口 434 个周期一直卡在 <b>219</b>，无增长也无崩溃；满意度 <code>satisfaction≈0.99998</code> 常年满格，因此几乎没有饥饿死亡。表面平稳，实则是<b>被外部补贴强行冻结</b>的假平衡。</p>
<img src="{imgs['emp']}" alt="就业结构">
<h3>特点二：雇佣劳动市场"名存实亡"</h3>
<p>所有建筑的 <code>employee_required=0</code>、<code>building_wages_paid</code> 累计为 0、<code>employee_employed</code> 全程为 0。也就是说——<b>没有任何一个"雇员"岗位真正被填充</b>，全部就业都由"业主自雇（owner）"承担。这直接决定了后面的失业问题。</p>
<h3>特点三：靠印钞维生</h3>
<p>约 78% 的工业产出卖不掉，被 <code>producer_support_money_issued</code>（生产者救济，本质是铸币）吸收，累计注入 <b>≈635 亿</b>（÷10000 货币单位）。这笔凭空产生的钱流入体系，推动居民存款只涨不跌。</p>
</div>

<h2><span class="q">1.</span>经济运行是否健康？</h2>
<div class="card">
<div class="verdict bad">不健康</div>
<table>
<tr><th>维度</th><th>表现</th><th>健康?</th></tr>
<tr><td>会计守恒</td><td>pop/money/goods error 恒为 0</td><td class="g">✅ 健康</td></tr>
<tr><td>就业</td><td>失业率 43%，且结构性锁死</td><td class="r">❌ 病态</td></tr>
<tr><td>市场出清</td><td>78% 产出靠补贴消化，不是卖出</td><td class="r">❌ 失灵</td></tr>
<tr><td>货币</td><td>存款单调膨胀，无回收机制</td><td class="r">❌ 不可持续</td></tr>
<tr><td>价格</td><td>120种商品仅14种活跃，其余冻结</td><td class="r">❌ 市场极薄</td></tr>
<tr><td>人口动态</td><td>完全静止，无迁徙/转职调节</td><td class="o">⚠️ 缺乏弹性</td></tr>
</table>
<div class="hl">结论：这是一个"<b>会计正确但经济学失灵</b>"的系统。引擎没有 bug，但经济行为规则让系统退化成一台"印钱补贴 + 囤钱"的机器。</div>
<img src="{imgs['funds']}" alt="存款膨胀">
</div>

<h2><span class="q">2.</span>为什么会产生大量失业者？</h2>
<div class="card">
<p>这是本次数据里<b>最明确、最可定位</b>的问题。失业不是随机涌现的，而是被两个结构性缺陷锁死的：</p>
<h3>根因A：雇佣就业管线未生效（最关键）</h3>
<p>代码里建筑有 owner + employee 两类岗位（如煤矿 <code>miner×14 + manager×2</code>）。但数据显示所有建筑 <code>employee_required=0</code>、<code>building_wages_paid=0</code>。也就是说<b>建筑的"雇员招聘"这一步根本没跑起来</b>，只有 owner 自雇岗位在填。占岗位需求大头的 employee 席位全部落空 → 大量本应受雇的人口无处可去。</p>
<h3>根因B：岗位总量 &lt; 劳动人口，且无转职机制</h3>
<p>把失业按职业拆开看，全部失业只来自两个职业：</p>
<table>
<tr><th>职业</th><th>人口</th><th>owner岗</th><th>失业</th><th>说明</th></tr>
<tr><td>职业20</td><td>96</td><td>48</td><td class="r">48（恒定）</td><td>owner 岗只有48个，另一半永远没岗</td></tr>
<tr><td>职业31</td><td>46</td><td>0</td><td class="r">46（全员）</td><td>该职业在本cell无任何可填岗位</td></tr>
<tr><td>其余职业(2/8/9/12)</td><td>77</td><td>全就业</td><td class="g">0</td><td>岗位充足</td></tr>
</table>
<p>由于失业者<b>不会转去其他职业、也不会迁出这个 cell</b>（当前 runtime 未开放跨cell迁徙/转职），职业20/31 的过剩人口就永久卡在失业池里。48+46 = 94 ≈ 总失业 94，完全吻合。</p>
<div class="hl">一句话：<b>失业 = (雇员管线没通) +（岗位总量不足）+（人口不能转职/迁徙自我调节）</b>。前者是实现问题，后两者是内容/机制设计问题。</div>
</div>

<h2><span class="q">3.</span>各建筑的原材料 / 产出设计是否科学？</h2>
<div class="card">
<div class="verdict warn">部分不科学：产出严重过剩 + 上下游断链</div>
<img src="{imgs['sub']}" alt="补贴">
<ul>
<li><b>产能远超需求</b>：单个建筑 <code>output_quantities_per_day</code> 动辄上万（煤矿 coal 43526/天、面包 5101/天），而本地 219 人的消费盘子极小。结果 78% 产出没有买家，只能靠救济兜底或丢弃（累计丢弃 <code>163623</code>）。产出规模与本地市场容量严重不匹配。</li>
<li><b>上下游断链</b>：多数中高级商品（钢、机械、芯片…共106种）价格全程冻结在 default，<code>demand_ema=0</code>、无生产。说明产业链只有最底层（采集/初级食品）在跑，中游加工链没有被激活——原料造出来没有下游工厂消费。</li>
<li><b>投入-产出比缺乏跨建筑校准</b>：单看一个建筑 <code>target_operating_margin</code> 是合理的（如煤矿10%、面包坊15%），但缺少"全局物料平衡"约束，导致某商品被巨量生产、另一些完全不生产。</li>
</ul>
<div class="hl">建议：产出量应<b>按本地/可达市场的真实需求量级标定</b>，而不是给一个固定大数；并补齐中游加工链的建筑，让初级品有下游去处。</div>
</div>

<h2><span class="q">4.</span>市场机制 / 物价机制设计是否科学？</h2>
<div class="card">
<div class="verdict warn">框架合理，但在"薄市场 + 无买家"下失稳</div>
<img src="{imgs['price']}" alt="价格">
<p>价格机制本身设计不差：<code>price_pressure</code> 综合了短缺、库存偏离、供需差、成本锚、闲置回归五个分量，带弹性与涨跌幅 clamp。问题出在<b>运行环境</b>：</p>
<ul>
<li><b>120 种商品仅 14 种真正交易</b>，其余 106 种既无供给也无需求，价格永久冻结在 <code>default_price</code>——市场极度稀薄。</li>
<li><b>薄市场里价格两极分化</b>：需求塌陷的商品（cloth 22433→2400、lumber 18000→1800、raw_hide 24000→2400）被成本锚一路压到地板；而偶发短缺的商品失控暴涨（<code>processed_food</code> 冲到 16万、<code>chipped_stone_tools</code> 涨9倍且 <code>shortage=1.0</code>）。</li>
<li><b>商人机制被"救济"架空</b>：商人按 <code>buy_factor≈0.95</code> 进货、按市价清算的逻辑是对的，但当居民没有购买力（因失业）时，商人清不掉货，最终由铸币救济接盘，价格信号失真。</li>
</ul>
<div class="hl">核心问题不在物价公式，而在<b>需求侧塌陷</b>让价格信号失去意义。需先修复"就业→收入→消费"链条，价格机制才能正常工作。同时建议给薄市场（低成交量商品）增加价格阻尼，避免个别商品暴涨暴跌。</div>
</div>

<h2><span class="q">5.</span>各阶层的流动 / 消费 / 存款变化是否科学？</h2>
<div class="card">
<div class="verdict bad">不科学：只进不出的"存款黑洞" + 阶层无流动</div>
<img src="{imgs['ineq']}" alt="贫富分化">
<ul>
<li><b>存款只涨不跌</b>：总存款从初期到末期单调膨胀（见上图）。业主阶层（职业9）人均存款从 37万 涨到 604万，翻了16倍。这是因为铸币救济持续给生产者注钱，而<b>没有任何抽水机制</b>（税收、折旧、破产清算都不在本 runtime）。</li>
<li><b>失业者也在囤钱</b>：即便全员失业的职业31，人均存款也涨到 587万。因为消费退化为最低生存食物、支出极小，而某些历史结转让其净值仍在攀升——<b>失业毫无经济代价</b>，这消除了劳动力市场的出清压力。</li>
<li><b>阶层零流动</b>：各职业人口在 epoch 10 之后基本固化（职业20恒96、职业31恒46）。没有"失业→转行→再就业"或"破产→降级"的通道，阶层结构是死的。</li>
<li><b>消费严重不足</b>：满意度常年满格说明基本需求被廉价满足，但高级需求消费几乎不发生（106种商品零需求），消费结构极度扁平。</li>
</ul>
<div class="hl">健康经济里存款应随收支波动、阶层应能流动、失业应有代价。当前三者都不成立。</div>
</div>

<h2><span class="q">6.</span>如何改进这个经济模型？</h2>
<div class="card">
<h3>🔴 P0 — 修复雇佣就业管线（最高优先级）</h3>
<ul>
<li>排查为什么建筑 <code>employee_required</code> 始终为 0、<code>building_employment</code> 阶段没有真正给 employee 席位派人。这是失业和产出不足的共同源头。让 <code>building_wages_paid</code> 能真正 &gt; 0。</li>
<li>验收：<code>employee_employed</code> 应随建筑运营上升，失业率应显著回落。</li>
</ul>
<h3>🔴 P0 — 用"可破产出清"替代无限铸币救济</h3>
<ul>
<li>把 <code>producer_support_money_issued</code>（凭空印钱兜底）改为：卖不掉就<b>降价 / 减产 / 停业 / 破产</b>。让 78% 的过剩产出真正触发市场调节，而不是被补贴吸收。</li>
<li>引入货币回收机制（简单税 / 建筑折旧 / 维护成本），阻止存款单调膨胀。</li>
</ul>
<h3>🟠 P1 — 给劳动力和人口加"弹性"</h3>
<ul>
<li>开放<b>转职</b>：长期失业的职业20/31人口可按需求转向缺工职业。</li>
<li>让<b>失业有代价</b>：无业者存款应被消费/生存成本持续侵蚀，形成再就业压力。</li>
<li>（中期）开放<b>跨cell迁徙</b>，让劳动力向有岗位的地方流动。</li>
</ul>
<h3>🟠 P1 — 校准建筑产能与产业链</h3>
<ul>
<li>产出量按<b>本地可达市场需求量级</b>标定，而非固定大数。</li>
<li>补齐中游加工链，让 106 种冻结商品有真实的供需闭环。</li>
</ul>
<h3>🟡 P2 — 薄市场价格阻尼</h3>
<ul>
<li>对成交量极低的商品降低价格调整速率，避免 <code>processed_food</code>/<code>chipped_stone_tools</code> 式的暴涨暴跌。</li>
<li>成本锚在无供给时应停用，而非把价格压到地板。</li>
</ul>
<div class="hl"><b>改进顺序建议</b>：先修 P0（就业管线 + 去铸币救济）——这两个是系统失真的根，修好后 43% 的失业和 78% 的补贴大概率同时缓解；再做 P1 的人口弹性与产能校准；最后微调 P2 价格阻尼。</div>
</div>

<div class="foot">
数据来源：economy_record_20260716_162646_v5_cell501_q15_r12 五份 CSV（summary/cohorts/market/buildings/resources）。<br>
分析结合 <code>gdext/src/economy_runtime.{{h,cpp}}</code> 及 <code>data/economy/</code> 建筑/职业配置。所有结论均可回溯到具体列与代码路径。<br>
注：会计守恒无误（error 全程为 0），本报告所指"问题"均为经济行为设计层面，而非结算引擎 bug。
</div>
</div></body></html>"""

with open("econ_report.html","w",encoding="utf-8") as f:
    f.write(html)
print("report written: econ_report.html, size=", os.path.getsize("econ_report.html"))
