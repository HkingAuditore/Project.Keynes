import pandas as pd, numpy as np, base64, io, matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter

BASE="D:/Godot/ProjectKeynes/Project.Keynes/tmp"
PREF="economy_record_20260717_104150_v5_cell1110_q21_r18"
BLD_DIR="D:/Godot/ProjectKeynes/Project.Keynes/Project/project-keynes/data/economy/buildings"
def rd(n): return pd.read_csv(f"{BASE}/{PREF}_{n}.csv",low_memory=False)
def b64(fig):
    buf=io.BytesIO(); fig.savefig(buf,format="png",dpi=110,bbox_inches="tight"); plt.close(fig)
    return base64.b64encode(buf.getvalue()).decode()
PROF={2:"artisan",9:"forager",12:"hunter",20:"merchant",22:"miner"}

# ---------- load ----------
s=rd("summary"); c=rd("cohorts"); b=rd("buildings"); m=rd("market"); r=rd("resources")

# ============ CHART 1: population decline (normalized) ============
cell_pop=c.groupby("epoch_row_id").population.sum()
world_cohorts=s.set_index("epoch_row_id").cohort_count
# align on common epoch index
common=cell_pop.index.intersection(world_cohorts.index)
cidx=cell_pop.loc[common].iloc[0]; widx=world_cohorts.loc[common].iloc[0]
fig,ax=plt.subplots(figsize=(7,3.4))
ax.plot(cell_pop.loc[common].index, cell_pop.loc[common].values/cidx*100, color="#2a9d8f", lw=2, label="Cell 1110 pop (start=100)")
ax.plot(world_cohorts.loc[common].index, world_cohorts.loc[common].values/widx*100, color="#e76f51", lw=2, label="World cohorts (start=100)")
ax.set_xlabel("epoch"); ax.set_ylabel("index (start=100)")
ax.set_title("Population / cohort scale: both halve over ~8660 days")
ax.legend(); ax.grid(alpha=.3)
ch1=b64(fig)

# ============ CHART 2: price divergence ============
raw_goods=["flint","raw_stone","raw_hide"]
fin_goods=["processed_food","cloth","fur","game_meat","chipped_stone_tools","logs"]
mp=m.pivot_table(index="epoch_row_id",columns="good_id",values="price")
fig,ax=plt.subplots(figsize=(7,3.8))
for g in raw_goods:
    if g in mp.columns: ax.plot(mp.index, mp[g].values, lw=1.6, label=g, color="#457b9d", ls="--")
for g in fin_goods:
    if g in mp.columns: ax.plot(mp.index, mp[g].values, lw=1.6, label=g, color="#d62828")
ax.set_yscale("log"); ax.set_xlabel("epoch"); ax.set_ylabel("price (log)")
ax.set_title("Price divergence: raw mats -> floor, finished goods -> ceiling")
ax.legend(ncol=2,fontsize=7); ax.grid(alpha=.3,which="both")
ch2=b64(fig)

# ============ CHART 3: wealth per person by profession ============
c["fp"]=c.funds/10000.0/c.population.replace(0,np.nan)
wpc=c.groupby("profession_id").apply(lambda d: d.funds.sum()/10000.0/max(1,d.population.sum()))
order=[9,12,2,20,22]
labels=[PROF[i] for i in order]; vals=[wpc.get(i,0) for i in order]
fig,ax=plt.subplots(figsize=(7,3.4))
bars=ax.bar(labels,vals,color=["#264653","#2a9d8f","#8ab17d","#e9c46a","#e76f51"])
ax.set_yscale("log"); ax.set_ylabel("money units / person (log)")
ax.set_title("Wealth per person by profession (cell 1110)")
for bar,v in zip(bars,vals): ax.text(bar.get_x()+bar.get_width()/2, v*1.1, f"{v:.1f}", ha="center", fontsize=8)
ax.grid(alpha=.3,which="both",axis="y")
ch3=b64(fig)

# ============ CHART 4: unemployment rate (world) ============
work=s.filled_owner_jobs+s.filled_employee_jobs+s.unemployed_population
rate=s.unemployed_population/work.replace(0,np.nan)*100
fig,ax=plt.subplots(figsize=(7,3.0))
ax.plot(s.epoch_row_id, rate.values, color="#6a4c93", lw=1.8)
ax.fill_between(s.epoch_row_id, rate.values, color="#6a4c93", alpha=.15)
ax.set_xlabel("epoch"); ax.set_ylabel("unemployment %")
ax.set_title("Measured unemployment rate (world): peaks at 0.39%")
ax.set_ylim(0,0.6); ax.grid(alpha=.3)
ch4=b64(fig)

# ============ CHART 5: construction stagnation & building loss ============
fig,ax=plt.subplots(figsize=(7,3.2))
ax.plot(s.epoch_row_id, s.pending_construction_count.values, color="#1d3557", lw=2, label="pending construction (world)")
ax2=ax.twinx()
ax2.plot(s.epoch_row_id, s.loss_suspended_building_groups.values, color="#c1121f", lw=1.8, label="loss-suspended buildings")
ax.set_ylabel("pending construction"); ax2.set_ylabel("suspended buildings")
ax.set_xlabel("epoch")
ax.set_title("Zero capital formation: no construction, buildings lost to losses")
ax.legend(loc="upper left"); ax2.legend(loc="lower right"); ax.grid(alpha=.3)
ch5=b64(fig)

# ============ supporting numbers ============
cell_first=c.groupby("epoch_row_id").population.sum().iloc[0]
cell_last=c.groupby("epoch_row_id").population.sum().iloc[-1]
world_first=s.cohort_count.iloc[0]; world_last=s.cohort_count.iloc[-1]
n_ep=len(s)
unem_max=rate.max()
waste_max=(s.production_output_discarded/(s.production_output_stock+s.production_output_discarded+s.production_output_retained).replace(0,np.nan)*100).max()
# active goods last epoch
ml=m[m.epoch_row_id==m.epoch_row_id.max()]
active=ml[ml.stock>0].good_id.tolist()
# resource change
r0=r[r.epoch_row_id==r.epoch_row_id.min()].set_index("resource_id").reserve
r1=r[r.epoch_row_id==r.epoch_row_id.max()].set_index("resource_id").reserve

HTML=f"""<!doctype html><html lang="zh"><head><meta charset="utf-8">
<style>
body{{font-family:-apple-system,'Segoe UI','Microsoft YaHei',sans-serif;max-width:960px;margin:0 auto;padding:28px;color:#1d2330;line-height:1.7;background:#fbfbfd}}
h1{{font-size:25px;border-bottom:3px solid #2a9d8f;padding-bottom:8px}}
h2{{font-size:20px;margin-top:34px;color:#264653;border-left:5px solid #2a9d8f;padding-left:10px}}
h3{{font-size:16px;color:#3a506b;margin-top:20px}}
.img{{text-align:center;margin:16px 0}}
.img img{{max-width:100%;border:1px solid #e0e0e8;border-radius:8px}}
.kpi{{display:flex;flex-wrap:wrap;gap:10px;margin:14px 0}}
.kpi div{{flex:1;min-width:150px;background:#eef6f4;border:1px solid #cfe6e0;border-radius:8px;padding:10px 12px}}
.kpi b{{font-size:20px;color:#2a9d8f;display:block}}
table{{border-collapse:collapse;width:100%;font-size:13px;margin:10px 0}}
th,td{{border:1px solid #ddd;padding:6px 8px;text-align:left}}
th{{background:#eef2f6}}
.tag{{display:inline-block;background:#ffe8cc;color:#9c5400;border-radius:4px;padding:1px 7px;font-size:12px;margin:2px}}
.warn{{background:#fff3f3;border:1px solid #f3c0c0;padding:10px 14px;border-radius:8px}}
.ok{{background:#eefaf2;border:1px solid #bfe6cb;padding:10px 14px;border-radius:8px}}
small{{color:#777}}
</style></head><body>
<h1>石器时代单元经济体诊断报告 · Cell 1110 (q21,r18,s-39)</h1>
<p><small>数据源：<code>economy_record_20260717_104150_v5_cell1110_q21_r18_*.csv</code> · {n_ep} 个 epoch（5 天市场周期，day 5 → 8665，约 8660 天 / 24 年）。<br>
<b>口径说明：</b><code>summary.csv</code> 为<b>世界级聚合</b>（cohort_count 峰值 6620、building_group 12495、production_output ~9×10⁸）；<code>cohorts/buildings/market/resources</code> 四个文件均为<b>本单元</b>（cell 1110，约 130–255 人、10 栋建筑、11 种成交货物）。论述中凡未注明“世界”的均为本单元。</small></p>

<div class="kpi">
<div><b>{cell_first}→{cell_last}</b>本单元人口（腰斩）</div>
<div><b>{world_first}→{world_last}</b>世界群落数（腰斩）</div>
<div><b>{unem_max:.2f}%</b>失业率峰值（世界）</div>
<div><b>0</b>pending construction（全程）</div>
<div><b>0</b>population/money/goods 误差</div>
</div>

<h2>0 · 当前经济运行体现出的特点</h2>
<ul>
<li><b>自给自足的“家庭作坊”经济。</b>本单元 10 栋建筑里，食物/燧石/布/石料链（forager、artisan 业主）<b>零雇员</b>；唯一的工资岗位是商人拥有的金/银矿（miner×2）。人口 95% 是 forager(123)/hunter(120) 的自雇 subsistence 生产者。</li>
<li><b>货币化被锁死在金银。</b><code>good_profile.gd:37-38</code> 规定 <code>monetary_issue_value&gt;0</code> 仅 gold、silver 可配置。其余货物不能铸币 → 其生产者停留在实物/自给状态，缺乏现金，无法进入市场。</li>
<li><b>价格极度分化（见图表2）。</b>原材料（flint、raw_stone、raw_hide）跌到价格地板、零需求；成品（processed_food、cloth、fur、game_meat、chipped_stone_tools）顶在价格天花板且 <code>shortage_q16=65535</code>（销量≈0）。</li>
<li><b>守恒完美。</b>三个审计误差（人口/货币/货物）全程为 0；运行时数值上完全健全。</li>
<li><b>完全停滞。</b>1733 个 epoch 内 <code>pending_construction_count</code> 恒为 0，建筑集合固定；人口与世界群落规模同步腰斩。</li>
</ul>
<div class="img"><img src="data:image/png;base64,{ch1}"></div>

<h2>1 · 这个经济运行是否健康？</h2>
<div class="warn"><b>不健康。</b>尽管数值守恒无误，但经济体在结构上在萎缩与失灵：
<table>
<tr><th>健康信号</th><th>本单元表现</th><th>判定</th></tr>
<tr><td>人口可持续</td><td>255→130（约 -49%）；世界群落 6620→3400</td><td>❌ 崩塌式衰退</td></tr>
<tr><td>产能可扩张</td><td>pending_construction 全程=0</td><td>❌ 零资本形成</td></tr>
<tr><td>供需可出清</td><td>成品 shortage=65535、原材料地板价</td><td>❌ 供给侧堵塞</td></tr>
<tr><td>生产无浪费</td><td>discarded 全程≈0</td><td>✅ 无实物浪费</td></tr>
<tr><td>数值守恒</td><td>三类误差=0</td><td>✅ 实现正确</td></tr>
<tr><td>建筑盈利</td><td>本单元无 severe_loss、无 wage_suspended</td><td>✅ 局部可盈利</td></tr>
</table>
</div>
<p><b>结论：</b>“算得对”但“长得歪”。经济是一台<b>不增长、不投资、需求无法满足、财富高度集中</b>的稳态机器。生产商（猎人/匠人）把产出<b>留存自用</b>（<code>_owner_retained_outputs</code>），市场只见到金银——于是消费者货物永远“缺货”，而缺货又因<b>没有建设响应</b>而永久化。</p>

<h2>2 · 为什么会产生“大量失业者”？</h2>
<div class="ok"><b>数据更正：本 dump 并不支持“大量失业”。</b></div>
<ul>
<li><b>本单元：</b>失业人口 1 → 0；5 个 cohort 全部为 forager/hunter/artisan/merchant/miner，<b>profession=31（unemployed）从未出现</b>。</li>
<li><b>世界：</b>失业率峰值仅 <b>{unem_max:.2f}%</b>（未就业 1222 / 劳动力 31.5 万）。</li>
</ul>
<div class="img"><img src="data:image/png;base64,{ch4}"></div>
<p><b>机制（代码层面，<code>economy_runtime.cpp:4328-4784</code>）：</b>失业是派生量 <code>unemployed = population − owner_employed − employee_employed</code>。采用“A1 增量迁移”：当某 cohort 人口超过建筑 <code>planned_utilization</code> 所需岗位时，盈余人口迁入 <code>unemployed|eth</code> 池；该池只消费 survival food → 满意度下降 → 饥荒死亡上升（马尔萨斯式自矫正）。招工按 <code>(利润,利用率,group_index)</code> 排序，亏损/停工建筑招不满。</p>
<p><b>所以你若在其他存档看到“大量失业”，根因是：人口增速 &gt; 建筑岗位数（建筑数×岗位槽）。</b>而<b>本单元恰好相反——人口在萎缩</b>，岗位反而“过剩”，于是失业≈0，代价是人口本身崩塌。另一种常见误会：把“非工资就业”误认为失业。本单元 95% 人口是<b>自雇业主</b>（owner_employed），模型正确地把他们算作就业；若你的 UI 把“就业”窄化为“领工资”，那 126/130 人会被误标为失业。</p>

<h2>3 · 各建筑的原材料 / 产出设计是否科学？</h2>
<p>本单元 10 栋建筑的 IO（来自 <code>data/economy/buildings/*.tres</code>）：</p>
<table>
<tr><th>建筑</th><th>业主</th><th>输入/天</th><th>输出/天</th><th>资源消耗</th><th>雇员</th></tr>
<tr><td>communal_hearth</td><td>forager</td><td>gathered_plants 1000 + game_meat 500</td><td>processed_food 1804</td><td>—</td><td>0</td></tr>
<tr><td>flint_quarry</td><td>forager</td><td>—</td><td>flint 3927</td><td>flint 196</td><td>0</td></tr>
<tr><td>stone_age_hunting_camp</td><td>hunter</td><td>chipped_stone_tools 5(q≥1)</td><td>game_meat 3728 + raw_hide 45 + fur 23</td><td>wild_game 715(邻格)</td><td>0</td></tr>
<tr><td>gathering_ground</td><td>forager</td><td>—</td><td>gathered_plants 7000</td><td>fertile_soil 1000(cap)</td><td>0</td></tr>
<tr><td>knapping_workshop</td><td>artisan</td><td>flint 3000</td><td>chipped_stone_tools 4124</td><td>—</td><td>0</td></tr>
<tr><td>household_weaving_shelter</td><td>artisan</td><td>—</td><td>cloth 900</td><td>fertile_soil 1000(cap)</td><td>0</td></tr>
<tr><td>placer_gold_working</td><td>merchant</td><td>—</td><td>gold 100</td><td>gold_ore 50</td><td>miner×2</td></tr>
<tr><td>surface_silver_working</td><td>merchant</td><td>—</td><td>silver 2500</td><td>silver_ore 500</td><td>miner×2</td></tr>
<tr><td>stone_collector</td><td>forager</td><td>tools 100(q≥1)</td><td>raw_stone 1808</td><td>stone 180</td><td>0</td></tr>
<tr><td>merchant_post</td><td>merchant</td><td>(做市商)</td><td>(无)</td><td>—</td><td>0</td></tr>
</table>
<h3>评价</h3>
<ul>
<li><b>单栋“物理账”基本合理：</b>狩猎 715 wild_game→3796 产出的料肉比≈5.3；打制 3000 flint→4124 工具（含损耗）；采集 7000 植物←fertile_soil 产能约束。量级自洽。</li>
<li><b>系统性失衡 1 — 上游产能过剩、无下游出清：</b>flint_quarry 产 3927/天，knapping 仅耗 3000 → 盈余 927/天累积（flint 库存 30 万、价跌地板）；stone_collector 产 1808 raw_stone，但 <code>demand_ema=0</code>（无人买）→ 库存 6.6 万、价跌地板；raw_hide 45/天、需求 0、库存 104 万。<b>这些货物没有消费/建设 sink，纯属积压。</b></li>
<li><b>系统性失衡 2 — 成品不上市场：</b>processed_food / cloth / fur / game_meat 的 <code>offered_supply_ema=0</code>、<code>shortage=65535</code>。生产者（业主）把产出<b>留存自用</b>，市场见不到供应，价格被顶到天花板。IO 表“设计了产出”，但<b>留存机制让产出脱离市场</b>。</li>
<li><b>系统性失衡 3 — 雇佣结构极端倾斜：</b>10 栋建筑仅 2 栋（金银矿）雇人，且业主是商人。subsistence 链零工资岗位 → 工资市场极小、财富向商人集中（见 Q5）。</li>
</ul>

<h2>4 · 市场机制 / 物价机制设计是否科学？</h2>
<p>价格由 <code>price_pressure()</code>（<code>economy_runtime.cpp:3883</code>）综合超额需求、目标库存缺口、短缺、成本锚、闲置回归五种压力，按 <code>demand_price_elasticity</code> 缩放、夹在每日涨跌幅内、再乘 N 做一次线性更新，最后夹在 <code>[min_price, max_price]</code>。机制本身<b>数学上健全</b>，但<b>在本经济体中失灵</b>：</p>
<div class="img"><img src="data:image/png;base64,{ch2}"></div>
<ul>
<li><b>价格信号在“尖叫”但无人应答。</b>成品 <code>demand_ema&gt;0</code> 而 <code>offered_supply_ema=0</code> → 价格被推到天花板（processed_food 20062→160000，cloth 25774→240000，fur/game_meat 12539→100000）。原材料 <code>demand=0</code>、<code>supply&gt;0</code> → 跌到地板（flint 3688→400，raw_stone 10000→1000，raw_hide 24000→2400）。</li>
<li><b>没有价格→生产的反馈。</b>涨到天花板本应诱导新建产能，但 <code>pending_construction</code> 恒为 0（建设是外生/地图生成的，非由利润信号触发）。于是短缺永久化——这是<b>最致命的市场设计缺口</b>。</li>
<li><b>商人采购受现金上限与买因子约束</b>（<code>merchant_buy_price_factor_q16=62259</code>=95% 零售；采购额≤开盘现金×(1−现金储备率)）。当生产商留存产出、金银又由商人自产自销时，商人几乎只在“自己→自己”的内部循环里铸币，外部消费者货物循环稀薄。</li>
<li><b>价格上限过高、弹性不足区分度：</b>默认 <code>max_price=1e8</code>，实际成品停在 1e5–2.4e5，说明远未触顶、只是持续上涨；而真正需要的“供应响应”机制缺席，使价格在高位空转。</li>
</ul>
<div class="img"><img src="data:image/png;base64,{ch5}"></div>

<h2>5 · 各阶层的流动 / 消费 / 存款变化是否科学？</h2>
<p>财富按职业（资金/人口，货币单位）：</p>
<div class="img"><img src="data:image/png;base64,{ch3}"></div>
<table>
<tr><th>阶层</th><th>人口</th><th>人均财富(货币单位)</th><th>角色</th></tr>
<tr><td>forager</td><td>123</td><td>≈0.9</td><td>自给、近乎无现金</td></tr>
<tr><td>hunter</td><td>120</td><td>≈5.0</td><td>自给、肉食不上市</td></tr>
<tr><td>artisan</td><td>5</td><td>≈7.0</td><td>工具/布不上市</td></tr>
<tr><td>merchant</td><td>4</td><td>≈11,881</td><td>拥有金银矿+商栈</td></tr>
<tr><td>miner</td><td>4</td><td>≈8,104</td><td>工资劳动者(金银)</td></tr>
</table>
<ul>
<li><b>阶层极化极端：</b>forager 人均 ≈0.9 货币单位，merchant/miner 约 1–1.2×10⁴ —— 差距约 <b>1.3 万倍</b>。根因不是“剥削”，而是<b>货币发行仅限金银</b>：subsistence 多数被锁在实物经济，只有金银链能积累现金。</li>
<li><b>消费分层：</b>forager/hunter/artisan 自产自消（<code>_owner_retained_outputs</code>），对市场化货物的需求因缺现金+缺供应而双重受抑；merchant/miner 有钱却买不到（成品 shortage=65535）。结果是<b>两边都“不满足”</b>。</li>
<li><b>存款/储蓄：</b>forager 几乎零储蓄且无法投资（无建设）；金银链储蓄极高但同样无投资出口 → 现金沉淀。储蓄不能转化为资本，经济失去内生增长引擎。</li>
<li><b>阶层流动：</b>数据中看不到跨职业迁移（profession 固定）。A1 迁移模型只把盈余人口推入 unemployed 池（饿死），<b>没有“穷人→工匠→商人”的上升通道</b>；在本单元甚至没有失业池，只有人口净流失。</li>
</ul>
<p><small>注：satisfaction_q16 均值≈0.82（不饿死），但人口仍腰斩，说明衰退主因是<b>出生/外迁 &lt; 死亡</b>而非饥荒——与“无投资、无就业扩张、subsistence 内卷”一致。</small></p>

<h2>6 · 如何改进这个经济模型？</h2>
<h3>① 让价格信号驱动资本形成（最高优先）</h3>
<p>当前建设是外生的。应在运行时实现<b>内生建设</b>：当某 good 的 <code>realized_profit_margin</code> 持续高于 <code>target_operating_margin</code> 或价格触顶+短缺，自动由富余现金（商人/群落）发起 <code>PendingConstruction</code>。参考 <code>economy_runtime.cpp:4261</code> 的入队接口与 <code>:6065-6145</code> 的提交逻辑。这样成品短缺会新建产能，原材料积压会停建——价格机制才真正闭环。</p>
<h3>② 解除“货币仅限金银”的锁</h3>
<p><code>good_profile.gd:37-38</code> 的 <code>monetary_issue_value</code> 只允许金银。建议扩展为：任何被商人采购并进入流通的货物都可形成购买力（商人采购即向生产者支付现金），使 forager/hunter/artisan 的售出行为产生现金，打通 subsistence→市场的循环，缓解阶层极化。</p>
<h3>③ 修正“留存即脱离市场”的副作用</h3>
<p><code>_owner_retained_outputs</code> 让业主吃掉全部产出。应设定<b>留存上限</b>（仅满足自身 need），超出部分强制挂市，使 processed_food/cloth/fur 等进入供应、下拉价格天花板、满足外部需求。</p>
<h3>④ 给上游产能加 sink 或减产</h3>
<p>flint/raw_stone/raw_hide 积压到地板价且无需求。要么为它们设计建设/制造消耗（如石器工具、建材），要么让采集建筑按 <code>demand_ema</code> 自适应减产（<code>planned_utilization</code> 应纳入下游需求信号），避免无效开采。</p>
<h3>⑤ 平衡雇佣结构，建立上升通道</h3>
<p>subsistence 链零工资岗导致工资市场过小。可：(a) 让部分 subsistence 建筑引入 employee 岗（如狩猎营雇帮工）；(b) 在就业模型里加入<b>职业迁移</b>（穷人→受训工匠→商人），而非只能迁入 unemployed 饿死池，形成真实的阶层流动。</p>
<h3>⑥ 人口/出生率与产能挂钩</h3>
<p>人口腰斩说明出生率不足以维持。建议出生率随（人均财富、食物剩余、就业率）正向调整，使“经济好→人多→需更多建筑→价格信号触发建设”形成正反馈，而非当前单向萎缩。</p>
<h3>⑦ 资源稀缺性真实化</h3>
<p>stone/coal/iron_ore 储备 4×10⁸ 且 0 变化（<code>building_resource_net_delta</code> 常年为负但不耗尽）。非可再生资源应随开采单调下降并抬升成本锚，让“资源约束”成为生产的真实边界，而非当前无限供给。</p>

<h2>附：关键数据口径与方法</h2>
<ul>
<li>所有比率/满意度为 Q16（÷65536）；价格单位为“每整货单位的货币子单位”（÷10000 为货币单位）；资金为货币子单位（÷10000 为货币单位）；货物为整单位×1000 子单位。</li>
<li>“活跃货物”= 本单元末 epoch 中 stock&gt;0 的 11 种；其余 109 种为目录占位（stock=0、价格=默认）。</li>
<li>失业率 = unemployed / (owner_employed + employee_employed + unemployed)，世界级。</li>
<li>留存续航判定：summary 三类审计误差全程=0 → 运行时数值守恒已验证。</li>
</ul>
<p><small>生成于经济模拟 dump 分析；代码引用基于仓库当前 <code>gdext/src/economy_runtime.cpp</code> 与 <code>data/economy/buildings/*.tres</code>、<code>good_profile.gd</code>。</small></p>
</body></html>"""

with open(BASE+"/economy_diagnosis.html","w",encoding="utf-8") as f:
    f.write(HTML)
print("written economy_diagnosis.html", len(HTML), "bytes")
print("cell pop", cell_first, "->", cell_last, "| world cohorts", world_first, "->", world_last)
print("unem max %", round(unem_max,3), "| active goods", len(active))
print("wpc:", {PROF[i]:round(wpc.get(i,0),1) for i in order})
