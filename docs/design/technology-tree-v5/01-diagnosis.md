# 科技树 v5 设计方案 · 第一部分：现状诊断

> 诊断基准：`Project/project-keynes/data/technology/technology_network.json`（schema 4.0，**416 节点 / 11 时代 / 4 主干 / 24 专业支线**）
> 交叉核验：`data/economy/buildings/*.tres`（459）、`data/goods/*.tres`（167）、`data/resources/*.tres`（31）、
> `data/economy/professions/*.tres`（46）、`data/military/military_catalog.json`（24 兵种 / 17 军事建筑）、
> `scripts/economy/technology_catalog.gd`、`scripts/modifier/modifier_catalog.gd`、`scripts/modifier/stat_key_families.gd`、
> `scripts/research/research_signal_catalog.gd`、`scripts/research/development_achievement_catalog.gd`、
> `gdext/src/economy_runtime_building_commit.cpp`、`gdext/src/military_core_war.cpp`
>
> 本文档**不修改任何代码或数据**，只给出设计方案。

---

## 0. 一句话结论

这一版科技树的**骨架是合格的，肉体是空心的**：

- **骨架合格**：416 节点、655 条硬前置、0 环、0 悬空引用、成本逐代单调平滑、里程碑候选池 2.0–2.8 倍于必需数、11 个里程碑构成清晰的时代门。这已经优于大多数 4X 游戏的科技 DAG。
- **肉体空心**：92 个可用修饰符通道里，**118 次用在"建筑家族产出 +x%"这一条最钝的通道上**；**225 个"地形×行业 / 地貌×行业"地理通道只有 3 个节点在用**；**15 个意识形态通道、5 个税制通道、2 个营造成本通道、2 个科研节奏通道、6 个战术条令通道一次都没用**。
- **最致命的是聚合倍率失控**：一个研究到终局的农业建筑，产出倍率是 **×51**（全局 3.90 × 行业 4.18 × 家族 3.12）。单看每个科技只是 "+8%"，合起来是一个能抹掉全部经济平衡的数字。

所以问题不是"科技不够多"，而是**科技的效果几乎全部投在了同一条已经过饱和的通道上**。

---

## 1. 结构现状（已核实）

### 1.1 规模与分布

| 项 | 值 |
|---|---|
| 节点 | 416 |
| 时代 | 11（stone / agrarian / kingdom / empire / exploration / enlightenment / steam / electrical / atomic / information / intelligent） |
| 域 | 4（agriculture 75 / engineering 165 / science 83 / society 93） |
| 主干 backbone | 4 条，61 节点 |
| 专业支线 branch_family | 24 条，355 节点 |
| 硬前置边 | 655（**0 环**，**0 悬空**） |
| 里程碑候选边 | 143 |
| 应用交叉点 `app.*` | 301 |
| 起始科技 | 7：hunting / gathering / early_trade / deadwood_collection / gold_panning / surface_silver_collection / hide_scraping |

**每代节点数**：

```
stone 56 | agrarian 51 | kingdom 57 | empire 43 | exploration 35 | enlightenment 31
steam 33 | electrical 30 | atomic 30 | information 26 | intelligent 24
```

前 4 代 207 节点（50%），后 4 代 110 节点（26%）。**头重脚轻属实**，但比上一版诊断（369 节点时）已有改善。

### 1.2 成本曲线

| 时代 | 节点 | 最低 | p25 | 中位 | p75 | 最高 | 合计 | 较上代 |
|---|---|---|---|---|---|---|---|---|
| stone | 56 | 0 | 3,000 | 3,400 | 3,900 | 5,000 | 173,200 | — |
| agrarian | 51 | 3,400 | 7,500 | 8,600 | 9,360 | 12,000 | 410,100 | ×2.37 |
| kingdom | 57 | 3,900 | 18,000 | 20,400 | 20,400 | 30,000 | 1,106,120 | ×2.70 |
| empire | 43 | 28,300 | 36,100 | 47,600 | 47,600 | 70,000 | 1,901,660 | ×1.72 |
| exploration | 35 | 44,200 | 108,800 | 108,800 | 108,800 | 160,000 | 3,635,200 | ×1.91 |
| enlightenment | 31 | 192,000 | 216,000 | 244,800 | 244,800 | 360,000 | 7,557,600 | ×2.08 |
| steam | 33 | 320,000 | 544,000 | 544,000 | 544,000 | 800,000 | 17,376,000 | ×2.30 |
| electrical | 30 | 640,000 | 1,080,000 | 1,224,000 | 1,224,000 | 1,800,000 | 34,924,000 | ×2.01 |
| atomic | 30 | 1,152,000 | 2,400,000 | 2,720,000 | 2,720,000 | 4,000,000 | 76,528,000 | ×2.19 |
| information | 26 | 2,048,000 | 6,120,000 | 6,120,000 | 6,120,000 | 9,000,000 | 152,776,000 | ×2.00 |
| intelligent | 24 | 3,200,000 | 12,000,000 | 13,600,000 | 13,600,000 | 20,000,000 | 304,000,000 | ×1.99 |

**关键缺陷：同代内 p25 = 中位 = p75。**
从探索时代起，一代之内**绝大多数节点价格完全相同**（探索时代 108,800、蒸汽 544,000、信息 6,120,000）。
这意味着「解锁整条石化产业」和「某建筑家族 +8%」**卖同一个价**。玩家不存在"贵但质变"的取舍，也不存在"便宜的先垫一垫"的战术。

### 1.3 里程碑候选（重要：它与时代推进无关）

| 时代 | 节点 | candidate_required | 候选池 | 池/必需 |
|---|---|---|---|---|
| stone | 56 | 4 | 8 | 2.00 |
| agrarian | 51 | 4 | 9 | 2.25 |
| kingdom | 57 | 4 | 10 | 2.50 |
| empire | 43 | 4 | 11 | 2.75 |
| exploration | 35 | 5 | 12 | 2.40 |
| enlightenment | 31 | 5 | 13 | 2.60 |
| steam | 33 | 5 | 14 | 2.80 |
| electrical | 30 | 6 | 15 | 2.50 |
| atomic | 30 | 6 | 16 | 2.67 |
| information | 26 | 7 | 17 | 2.43 |
| intelligent | 24 | 7 | 18 | 2.57 |

比例看起来健康（可跳过一半候选）。**但它不决定你能不能进代。**

### 1.3b 时代推进的真实规则：**80% 科技完成率**（本次诊断的定论性发现）

（已核验 `scripts/era/era_advancement_catalog.gd:22` 与 `scripts/era/era_advancement_service.gd:456–462, 758–793`）

```gdscript
const TECH_COMPLETION_RATIO := 0.8
var tech_target := int(ceil(float(tech.total) * TECH_COMPLETION_RATIO))
out[out.size()-1]["mandatory"] = true          # ← 科技条件是强制项
```

`tech.total` = **该时代全部非里程碑科技**（`_era_technologies()` 明确跳过 `FLAG_MILESTONE` 与 `app.*`）。
另需在「人口 / 建筑数 / 贸易次数」三项中满足**任意两项**（`CONDITIONS_REQUIRED = 3`，即四选三中的"科技 + 另两项"）。

**每代强制完成数**：

| 时代 | 非里程碑节点 | 必须完成（⌈0.8n⌉） | **可放弃** | 放弃比例 |
|---|---|---|---|---|
| stone | 55 | 44 | 11 | 20% |
| agrarian | 50 | 40 | 10 | 20% |
| kingdom | 56 | 45 | 11 | 20% |
| empire | 42 | 34 | 8 | 19% |
| exploration | 34 | 28 | 6 | 18% |
| enlightenment | 30 | 24 | 6 | 20% |
| steam | 32 | 26 | 6 | 19% |
| electrical | 29 | 24 | 5 | 17% |
| atomic | 29 | 24 | 5 | 17% |
| information | 25 | 20 | 5 | 20% |
| **合计** | **382** | **328（78.8%）** | **73** | **19%** |

**这条规则几乎单枪匹马决定了整棵树的性质：**

1. **"科技树构筑"在集合维度上不存在。** 玩家无法"选择走哪条支线"—— 他必须点掉每代 80% 的节点。24 条支线不是 24 个选项，而是 24 段必经路段。
2. **`candidate_required`（4→7）沦为装饰**：它只控制"目标时代的里程碑节点何时可研究"，不影响进代。此前所有基于"候选池/必需数 = 2.0–2.8 倍所以健康"的判断，**全部无效**。
3. **"全点"不再是玩家的最优策略，而是系统的强制结果**（上一轮审查认为"没有互斥导致全点占优"——实际比那更彻底：全点是被要求的）。
4. **真正的决策空间 = 每代那 5–11 个可放弃节点，全局只有 73 个**。而这 73 个位置里，还要扣掉 24 个"只给全局 +4~8%"的无差别节点 —— 真实的**构筑决策点约 50 个 / 416 个节点（12%）**。
5. **因此"文明特色"不可能来自"研究了什么"，只能来自"运营了什么"。** 这是本方案全部设计的出发点（见第二部分）。

> 单行改动 `TECH_COMPLETION_RATIO` 是这份设计里**杠杆最大的一个平衡旋钮**（0.80 → 0.65 会把决策空间从 73 个扩到 133 个）。它不属于纯数据改动，需要明确批准，本方案把它列为"待决"，并在设计上同时准备"保持 0.80"的兜底路线。

---

## 2. 效果通道现状（本次诊断最核心的发现）

### 2.1 可用通道 vs 实际用法

运行时已实现、科技可直接引用的修饰符统计如下。

> **勘误**：早期版本写的是"全部 92 个 stat 都有真实 consumer，0 个假效果"。
> 进一步核查后必须修正：**军事域有 9 个 stat 只有枚举声明，没有进入战斗解算**（见 6.3）。其余 83 个确有 consumer。

| 通道族 | 可用 stat 数 | 科技使用次数 | 累计值 |
|---|---|---|---|
| `country.output.family.<家族>_factor` | 每建筑家族 1 个 | **118** | 部分家族 ×3.25 |
| `country.output.<行业>_factor` | 5 | 70 | agriculture **+3.18** / extractive **+3.11** |
| `country.economy_output_factor`（全局） | 1 | **42** | **+2.90** |
| `country.output.good.<物资>_factor` | 每物资 1 个 | 38 | 最高 ×2.63 |
| `country.climate.profile.<档案>.<灾害>_loss_factor` | 6×4 = 24 | 38 | 最低 ×0.30 |
| `country.resource.<资源>.use_factor` | 31 | 12 | 合计 −0.08 |
| `country.input.good.<物资>_factor` | 167 | 9 | — |
| `country.output.terrain.<地形>.<行业>_factor` | **30 × 5 = 150** | **2** | — |
| `country.output.landform.<地貌>.<行业>_factor` | **15 × 5 = 75** | **2** | — |
| `country.research.<域>_efficiency` | 4 | 43 | 合计 +4.69 |
| `country.military.*` | 28（**9 个无 consumer**） | 35 | 见 6.3 |
| `country.ideology.*` | **15** | **0** | — |
| `country.construction.cost_factor / time_factor` | 2 | **0** | — |
| `country.research.cost_factor / institution_output_factor` | 2 | **0** | — |
| `country.tax.*`（5 个族） | 5 族 | **0** | — |
| `economy.profession.<职业>.satisfaction_bp / tax_tolerance_factor` | 46 × 2 | **0** | — |
| `country.military.rule.*`（战术条令） | **6** | **0** | — |

**算子的重要澄清（勘误）**：`modifier_terms[].operation` 的枚举是 `ADD=0 / SUBTRACT=1 / MULTIPLY=2 / DIVIDE=3`（`modifier_runtime.cpp:263–266`），合成公式为 `(base + Σadd) × Πfactor`，再 clamp。
全树 480 条 term 中 **473 条是 ADD、7 条是 MULTIPLY，且 7 条 MULTIPLY 全部是军事 stat**。
所以前面各表的"求和→1+sum"对民用 stat 成立；军事的 `casualty_factor 0.85`（×0.85）与 `supply_transport_factor 2.0`（×2.0）应读作乘数，不是 +85%/+200%。

**读法**：几乎全部科技效果挤在表格前三行。最后六行 —— 恰恰是最能改变玩家决策的通道 —— 一次都没用。

### 2.2 聚合倍率失控（P0 级数值问题）

`economy_runtime_building_commit.cpp:1073` 的产出倍率是连乘：

```
输出倍率 = 全局 × 行业 × 科研机构 × 建筑家族 × 具体建筑 × 地形×行业 × 地貌×行业 × 城市 × 精确建筑
```

把全树研究完的求和值代进去：

| 行业 | 全局 | 行业 | 家族（代表值） | 最终倍率 |
|---|---|---|---|---|
| 农业 | ×3.90 | ×4.18 | specialty_commodity_crops ×3.25 / livestock ×3.12 / staple_prep ×2.94 | **×41 – ×51** |
| 采掘 | ×3.90 | ×4.11 | copper ×1.88 / iron ×1.74 | **×27 – ×30** |
| 制造 | ×3.90 | ×2.31 | cloth_weaving ×3.10 / steelmaking ×1.86 | **×13 – ×19** |
| 能源 | ×3.90 | ×1.77 | — | ×6.9 |
| 知识 | ×3.90 | ×1.53 | research_institution ×1.63 | ×9.7 |

作为参照，修饰符表的自身上限是 `max = 8.0`（即 +700%）。也就是说**这些倍率全部"合法"，问题不在 clamp，在求和**。

而 `country.economy_output_factor`（+2.90，42 次）**没有出现在任何界面语义里**：玩家看到的是 42 个不同科技各写一句"全社会经济产出 +4%"，实际是把整个经济乘了 3.9 倍，并且它还会和每个行业的独立加成再次相乘。这是本项目最钝、最重复、最破坏平衡的一条通道。

### 2.3 已经撞顶的通道

| stat | 使用次数 | 求和 | 下限 | 允许下行空间 | 利用率 |
|---|---|---|---|---|---|
| `country.population.death_factor` | 15 | **−1.25** | 0.3333 | 0.667 | **187%（已撞顶）** |

15 个科技各写「死亡率 −x%」，合计已经超过 2 倍允许空间。**其中约 9 个科技实际一点作用都没有**（被 clamp 吃掉）。同类风险通道：`flood_loss_factor` 75%、`drought_loss_factor` 57%、`input_factor` 60%。

### 2.4 零效果科技

> **勘误**：早期版本列了 6 个"零效果"节点并称两台是黑洞。逐一核查运行时后修正如下：
> `magnetic_navigation` 有 `runtime_capability_tags: [research.observe_visible_foreign]`（远程观测开关，`world_runtime_visual_adapter.gd:651–663`）；
> `coastal_transport` 被 `military_catalog.json:unlock_tech_ids[0]` 引用为水路通行开关。
> 它们的真实问题是**效果没有写进 `effect_summary` / `content_effects`，玩家在卡上看到的是空白**，而不是没有效果。

**真正的纯研究点黑洞（`content_effects` / `modifier_terms` / `runtime_capability_tags` 三者全空、`effect_summary` 为空串）**：

| 科技 | 时代 | 成本 | 备注 |
|---|---|---|---|
| `tech.reed_identification` 芦苇辨识 | stone | 3,400 | 子节点 `reed_harvesting` 才是真正解锁建筑的 |
| `tech.copper_ore_roasting` 铜矿焙烧 | kingdom | 7,400 | 模板文案还串到"石器时代" |
| `tech.irrigation_surveying` 灌溉测量 | kingdom | 20,400 | 是 `flood_recession_*` 的唯一入口 |
| `tech.military.radio_command` 无线电指挥 | electrical | 640,000 | 两条 modifier 都在上面的死 stat 名单里 |
| `tech.cartography` 地图学 | exploration | 96,000 | 探索代候选池最低价 + 4 个下游，**"买最贵的沉默"** |

**合计 767,200 研究点买不到任何可感知的东西**；其中 `cartography` 与 `radio_command` 最恶劣（贵、且在必经路径上）。

**另有 2 个"效果未声明"节点**（有真实运行时效果但卡片空白）：`tech.magnetic_navigation`（47,600）、`tech.military.coastal_transport`（28,300）。
处置：补 `kind:"runtime"` 的 `content_effects` 条目 + 重写 `effect_summary`。树内已有 4 条 `kind:"runtime"` 先例（如 `tech.celestial_navigation` 的 `shallow_sea_corridor`）。

---

## 3. 内容覆盖现状

### 3.1 解锁节奏

| 时代 | 节点 | 新建筑 | 新物资 | 建筑累计 |
|---|---|---|---|---|
| stone | 56 | 37 | 29 | 37 |
| agrarian | 51 | 43 | 19 | 80 |
| kingdom | 57 | 64 | 26 | 144 |
| empire | 43 | 45 | 13 | 189 |
| exploration | 35 | 25 | 8 | 214 |
| enlightenment | 31 | 18 | **6** | 232 |
| steam | 33 | 52 | 15 | 284 |
| electrical | 30 | 42 | 18 | 326 |
| atomic | 30 | 39 | 23 | 365 |
| information | 26 | 42 | **6** | 407 |
| intelligent | 24 | 52 | **4** | 459 |

- **建筑曲线是后置的**（前 6 代 232 座，后 5 代 227 座）—— 这反而合理，说明"工程建设"没被前置榨干。
- **物资曲线在后三分之一崩塌**：启蒙 6、信息 6、智能 4。这三代的 18 / 42 / 52 座新建筑**全部复用更早时代的材料**。玩家在信息时代盖「智能研究院」，材料还是钢+混凝土+玻璃。**"新物质文明"的实感缺失**。
- 探索时代 8、蒸汽 15 也偏低。

### 3.2 重复解锁

661 个不同的解锁目标里，**133 个被 2 个以上科技重复解锁**：

- `technology_points` ×19（可接受，每个时代的科研设施都"解锁"它）
- `corn_grain` ×10、`wheat_grain` ×10、`potatoes` ×10、`rice_grain` ×10、`spices` ×8、`bast_fiber` ×8、`seed_cotton` ×7、`medicinal_herbs` ×7、`cloth` ×7、`grain` ×7、`vegetables` ×7……

这些物资在石器/农耕时代就已解锁，后续 7–10 个科技重复列出它们，**对运行时零贡献，只污染效果列表**（上一版诊断已指出 106 个，现在仍是 133 个）。

### 3.3 产业链

- 建筑 459 座全部能解析出所属时代（0 游离）。静态谱系是干净的：**167 种物资 0 个无生产者、0 个纯废物**。
- 但 **155 个科技节点既无建筑也无物资绑定**（其中 137 个只有修饰符）。
- 21 座产 `technology_points` 的建筑产能从 **2,000/日（石器）阶梯上升到 6,708,000/日（智能）** —— 有阶梯，这一点是健康的。真正的问题是**其中 17 座没有任何地理/资源条件**：`tide_observation_hut`（19,143/日）、`seasonal_observation_shelter`（14,857）、`oral_memory_circle`（10,571）在内陆高原也能照建。**知识在政治上被设计成"可移植产业"，不参与生态分工。**
- 研究建筑产能每代约 ×2，而成本每代约 ×2.22–2.53，**成本跑得比产能快**；`exploration` 与 `steam` 两代**没有任何新增研究建筑**（产能原地踏步），而成本照涨。

---

## 4. 触发与揭示现状

### 4.1 三层门的真实结构（本节含一项推翻常识的核实结果）

（已核验 `technology_catalog.gd:655–756` 与 `country_runtime.cpp:7497–7574`）

每个科技的**实际研究资格**是：

```
ALL_OF(
    全部 hard_prerequisite_ids,                        ← ① 知识底座
    AT_LEAST(milestone_candidate_ids, required),        ← ② 时代里程碑
    上一代 entry_milestone,                             ← ③ 时代准入
    ANY_OF(research_routes 的条件)                      ← ④ 实践能力（强制）
)
```

**关键事实：`reveal_condition` 几乎不是门槛。**

`country_runtime.cpp:7542–7574` 的发现逻辑是：

1. 若该科技**有** `reveal_condition` 且不满足 → 直接 return（不发现）；
2. 但只要**任意一个硬前置已完成** → `reveal = true` → **绕过 reveal 条件，直接发现**（`7567–7574`）；
3. 里程碑节点则只要**任意一个候选完成** → 直接发现（`7560–7565`）。

推论（已验算）：

- 有硬前置的科技（394 个）**父节点一完成就会自动出现**，`reveal_condition` 只是"提前预览"。
- 只有 **22 个无前置根节点** 真正被 reveal 拦住 —— 其中 11 个是时代里程碑（本来就不该拦）、4 个是起始科技、**真正受地理/资源信号限制的只有 8 个辨识根**（clay / spice / gold_placer / silver_vein / reed / flint / natural_copper / rubber）。
- 因此：**"我见过这个东西才能研究它"在这套系统里 95% 不成立**。`reveal_condition` 的 311 条信号条件，实际是 311 条"提前亮牌"，不是 311 道门。

| 层次 | 字段 | 实际作用 | 覆盖 |
|---|---|---|---|
| ① 可见 | `reveal_condition` | **仅对 22 个根节点是硬门**；对其余 394 个是提前预览 | 311 有信号 / 105 空 |
| ② 知识 | `hard_prerequisite_ids` | 真正的第一道硬门 | 655 边 |
| ③ 实践 | `research_routes` | **真正的差异化硬门**（315 节点） | 101 节点豁免 |
| ④ 时代 | `milestone_candidate_ids` | 时代准入 | 每代 8–18 候选 |

**这是本次诊断最重要的结论**：如果想让"地理/气候/实践"真正决定"你能研究什么"，唯一的现成落点不是 `reveal_condition`，而是 **`research_routes`**（它的条件支持 `SIGNAL_PRESENT` / `SIGNAL_COUNT`，见 `technology_catalog.gd:901–914`，属于已实现算子，**不需要新运行时**）。

### 4.2 `research_routes` 全变成了同一句话

315 个节点的 route 条件，句式高度统一：

```
ALL_OF(某科技, development.<某个行业指标>)
```

route_type 分布：`professional_knowledge` 264 / `institutional_capacity` 228 / `industrial_practice` 187（其余 12 种各 1–35）。

举例（`tech.terrace_farming` 梯田农业）：

```
route.grounded_knowledge  = ALL_OF(tech.grain_threshing, development.employment.agriculture.10_90d)
route.grounded_capacity   = ALL_OF(tech.record_keeping,  development.output.agriculture.100_180d)
```

**精确结论（已逐条复算）：**

- **38 个节点**满足"所有 route 只能由**同一个行业**的 `development.*` 指标满足，且没有任何 `tech + 通用指标` 的逃生路线"。
  分布：agrarian 1 / kingdom 农业 11 · 采掘 2 · 制造 5 / empire 农业 6 · 采掘 5 · 制造 4 / enlightenment 知识 1 / steam 采掘 1 · 制造 2。其中农业系 18 个。
- 这 38 个**不是永久死锁**，而是**"重慢锁"**：首都资源 top-up 保证任何生态都有肥沃土壤，可以建采集营把农业就业拉到 10 人，`output.agriculture.100_180d` 也能凑出来（约 27 座采集营）—— 也就是说，一个纯矿业文明要研究「梯田农业」，得先在自己的一亩三分地上硬堆农业。
- 后果不是"做不到"，而是**"要做一件与本文明完全无关的事"**：它把跨支线研究变成一种惩罚，而不是一种取舍。玩家体验上等价于"这条线对你关门"。

### 4.3 揭示信号的退化

**每代信号类别引用次数**（`reveal_condition` 内）：

```
era            bio  breakthrough contact development landform resource weather | 有信号 无信号
stone           17        2        9        0          0        22      0     |   29     27
agrarian        17        6        3        2          9        19      9     |   33     18
kingdom         15       11        1       13         16        24     11     |   49      8
empire           2        2        0       21         13        16      6     |   35      8
exploration      3        0        6       24          6         8      1     |   26      9
enlightenment    0        0        0       23          1         1      3     |   23      8
steam            2        0        2       21          1         0      1     |   19     14
electrical       0        0        0       21          0         2      2     |   20     10
atomic           4        2        0       29          1        14      1     |   29      1
information      4        5        0       18         11         5     15     |   25      1
intelligent      4       10        0       20          2         2      8     |   23      1
```

**结论**：从探索时代起，`landform` / `weather` / `contact` / `bio` 基本消失，`development.*`（纯国家经济指标）垄断了发现过程。
「我见过这个东西，所以能研究它」的发现感，在后期退化成「我的 GDP 到了，所以弹出一张卡」。

### 4.4 地理在"研究资格"层完全缺席（最硬的证据）

把 **743 条 `research_routes`** 全部展开，统计其中出现的信号原子：

| 类别 | 在 routes 中出现的不同原子数 | 出现在几个节点 |
|---|---|---|
| `development.*`（国家经济指标） | **78** | 300+ |
| `breakthrough.*`（实践突破） | 23 | 60+ |
| `resource.*`（资源） | 27 | — |
| `landform.*`（地貌） | **8** | — |
| `weather.*`（天气） | **1** | — |
| `bio.*`（物种） | **0** | 0 |
| `contact.*`（跨文明接触） | **0** | 0 |

而所有 `landform` / `weather` / `resource` 类的 route 原子，**只集中出现在 3 个节点上**：

```
tech.coastal_fishing            (landform.coast / landform.coastal_estuary)
tech.freshwater_fishing         (landform.freshwater_access)
tech.early_knowledge_institution (石器时代的通用研究机构, 一次性列了 10 个地理原子)
```

**结论：416 个节点里，只有 3 个节点的"能不能研究"与地理有关，其中 2 个是石器时代渔业，1 个是石器通用机构。**

配合 4.1 的结论（`reveal_condition` 对 394 个有前置的节点不构成门槛），可以下一个非常确定的判断：

> **当前科技树里，"地理/气候"对"你能研究什么"的影响约等于 0.7%（3/416）。**
> 它只影响"你多早**看见**这张卡"，不影响"你能不能用它"。

这是"科技树与玩家地理气候发展强相关"这条要求上最大的缺口，也是本方案第三部分优先级最高的工作。

### 4.5 实践突破信号：其实是活的（此处修正一处早期误判）

对 743 条 route 与 311 条 reveal 同时统计后：

- `breakthrough.*` 共 **23 个原子在用**：`seed_saving`（route 10 次）、`chemical_process_control`（route 9 次）、`assembly_line`（route 6）、`automation`（6）、`digital_control`（5）、`kiln_temperature`（reveal 9）、`motor_winding`（reveal 4）、`mine_drainage`（route 4）、`energy_control`（3）、`industrial_organization`（3）、`electrification`（3）、`rainfed_adaptation`（3）、`maritime_operations`（3）、`watershed_management`（3）等。
- 并且编译期有**强制校验**：`economy_runtime_catalog.cpp:1653–1666` 要求每个 practice 位都必须有 publisher 建筑，否则 catalog 编译失败 —— 也就是说**只要能启动游戏，这 28 个实践突破一定有发射源**。

所以实践通道"基础设施完备、接线零散"：**不是不能做，是没做够**。全树 743 条 route 里只有约 60 条用到实践原子，占比 8%。

**真死信号（4 个，需要代码修复，属 `blocked`）**：

| 信号 | 问题 |
|---|---|
| `weather.heatwave` | 无 rule 号、无 publisher 分支（已被 8 个节点当作可选路径 → 假路径） |
| `weather.prolonged_wet_season` | 同上 |
| `weather.freeze_thaw` | 同上 |
| `contact.bast_fiber` | `economy_runtime_trade.cpp:1758` 的 `bast_fiber‖flax_fiber → rule 5` 把 rule 10 完全吃掉（1 行代码可修） |

**免费资产**：`weather.storm_surge` 是活的但 0 引用。
**不可达**：`development.trade.partners_8` 要求 8 个贸易伙伴，而默认局总国家数 = 1+5 = 6（`new_game_config.gd` `DEFAULT_FOREIGN_COUNT = 5`）→ 污染 2 个揭示与 1 条 route。

### 4.6 过松：开局资源校验让 21 个节点的条件退化为恒真

`start_location_policy.gd:510–534` 会用起始科技的 `reveal_condition` 校验出生点，于是：

- `resource.wild_game`、`resource.fertile_soil`、`resource.timber`、`resource.gold_ore`、`resource.silver_ore` **在开局恒为真**。
- 任何 `ANY_OF(...)` 里包含这 5 个之一，**整个条件退化为 TRUE**。
- 受影响：**21 个节点**（`food_storage`、`fur_sewing`、`controlled_burning`、`currency`、`fermentation`、`forest_management`、`hide_tanning`、`mine_timbering`、`parchment_making` 等），其中 **19 个没有其它门**。

这比"信号复用"严重得多：它让石器-农耕两代的"发现"直接失效。

### 4.7 从未被使用的信号资产

信号词表里**已登记、但科技树（reveal + routes 合计）从未引用**的：

- **生物**：`bio.camel`、`bio.yak`、`bio.silkworm`、`bio.dye_plant`（4 个，且都是可做"地域特化"的资产）
- **资源**：`resource.limestone`、`resource.phosphate_rock`、`resource.lead_ore`、`resource.zinc_ore`
- **地貌**：`landform.volcanic`、`landform.marsh`、`landform.grassland`(仅在 1 个石器节点的 route 里)、`landform.monsoon_basin`、`landform.tundra`、`landform.oasis`
- **天气**：`weather.storm_surge`（活的，0 引用）
- **满意度指标**：`development.satisfaction.*`（5 档，reveal 0 次 / route 4 次）

另有一批 `breakthrough.*` 已接入但用量极低（`print_calibration`、`steam_sealing`、`printing`、`maize_selection`、`hide_working`、`hydraulic_engineering` 各 ≤1 次）。

**判定**：实践通道的**基础设施完备**（编译期强制校验保证有发射源），**接线率仅 8%**。这不是能力缺失，是设计未做。

---

## 5. 支线健康度

### 5.1 时代跨度与终止

| 支线 | 节点 | 首末时代 | 跨度 | 状态 |
|---|---|---|---|---|
| 玉米与园圃农业 | 13 | stone→information | 6 | 中间王国→电气断裂 |
| 小麦谷物雨养 | 18 | stone→atomic | 8 | 健康 |
| 水稻水田灌溉 | 13 | stone→intelligent | 7 | 中间多代断裂 |
| **块茎高地农业** | 9 | stone→**kingdom** | 3 | **死于第 3 代** |
| 草原畜牧 | 20 | stone→atomic | 7 | 健康 |
| **热带商品农业** | 16 | stone→**exploration** | 4 | **死于第 4 代** |
| **森林木材造纸** | 7 | stone→**steam** | 5 | **死于第 6 代** |
| 海运物流 | 16 | stone→intelligent | 9 | 健康 |
| **纤维纺织** | 14 | stone→**atomic** | 6 | 后段单薄 |
| **建材公共工程** | 19 | stone→**steam** | 6 | **死于第 6 代** |
| **有色金属** | 14 | stone→**atomic** | 6 | 后段单薄 |
| 重工业 | 31 | kingdom→intelligent | 7 | 健康（最厚） |
| **工业化学** | 17 | stone→**atomic** | 7 | 后段单薄 |
| **石油石化** | 10 | electrical→atomic | 2 | **只活 2 代** |
| **水风水务** | 8 | stone→**empire** | 4 | **死于第 3 代** |
| 电力智能能源 | 10 | electrical→intelligent | 3 | 单薄 |
| **土地制度** | 12 | agrarian→**enlightenment** | 5 | **死于第 5 代** |
| 商业金融 | 14 | stone→information | 9 | 健康 |
| 劳工管理 | 25 | stone→intelligent | 10 | 最厚 |
| **测量仪器** | 10 | agrarian→**electrical** | 6 | 后段单薄 |
| 自然史育种 | 18 | stone→intelligent | 9 | 健康 |
| **公共卫生** | **6** | empire→atomic | 4 | **最薄（全树 6 个节点）** |
| 地学遥感 | 11 | exploration→intelligent | 5 | 前段单薄 |
| 计算控制 | 21 | electrical→intelligent | 4 | 健康 |

**7 条支线在游戏中期直接死亡**（块茎高地、热带商品、森林生物质、建材、水风水务、土地制度、石油石化过短）。选了这些路线的玩家，会发现自己投入的那条线在三代之后没有下文，只能转线 —— 之前的投入变成沉没成本。

### 5.2 主干断档

```
backbone.food_storage          5 3 2 2 2 1 1 2 · · 1     ← atomic / information 两代空
backbone.tools_machinery       1 1 1 1 · 2 2 · 1 · ·     ← exploration / information 两代空
backbone.knowledge_computation 2 1 2 3 1 2 2 1 1 · ·
backbone.institutions_exchange 1 5 2 2 1 2 1 1 2 3 1
```

`tools_machinery`（工具 / 机械 / 自动控制）这条主干在**探索时代和信息时代完全没有节点**，而智能时代的主题就是自动化。这不是"内容缺失"，是**主干断裂**：一条号称贯穿全史的能力线，中间断了两代。

`food_storage` 主干在原子时代和信息时代也空着 —— 而这两个时代恰好是罐头、冷冻链、食品工业、冷链物流该爆发的时代。

---

## 6. 军事体系现状

36 个 `tech.military.*` 节点，散落在 **11 个不同的 branch_family** 里（畜牧、建材、工业化学、劳工管理、公共卫生、地学、自然史、海运、重工业、石化、计算控制）。**没有独立的军事支线或军事主干。**

**每代军事节点数**：

```
stone 2 | agrarian 0 | kingdom 3 | empire 5 | exploration 5 | enlightenment 4
steam 5 | electrical 4 | atomic 5 | information 3 | intelligent 3
```

**农耕时代完全没有军事科技** —— 从石器的「战团/伏击」直接跳到王国的「常备军/战车/夯土城垣」，中间跨过整个青铜时代。

**效果高度同质**：
- `attack_factor` 7 次（ADD 合计 +0.64）
- `defense_factor` 3 次 +0.28
- `fortification_factor` 3 次 +0.45
- `casualty_factor` 2 次，均为 **MULTIPLY ×0.85**（两次累计 ×0.7225，即 −27.75%）
- `supply_transport_factor` 2 次：`military_roads` ADD +0.15 与 `rail_mobilization` **MULTIPLY ×2.0**，叠加后 **(1+0.15)×2.0 = ×2.30**，是全树最强的单一乘数

### 6.3 军事修饰符 51.4% 是死代码（最严重的集成缺陷）

（已核验 `modifier_runtime.cpp:263–266` 与 `military_core_war.cpp:147–165, 301–352`）

战斗值 `sum_lot_value()` 只计算 `单位攻防 × 状态系数 × 装备品质`，**不含任何国家修饰符**；`refresh_army_cache()` 同样不含。
由此，下列 9 个 stat **只有枚举声明（`military_core.h:163–170`），没有进入解算**：

| stat | 科技使用次数 | 结论 |
|---|---|---|
| `attack_factor` | **7** | 无 consumer |
| `defense_factor` | 3 | 无 consumer |
| `fortification_factor` | 3 | 无 consumer |
| `barracks_capacity_factor` | 2 | 无 consumer |
| `militia_factor` | 1 | 无 consumer（民兵战力实际由 `era_factor_militia` 决定） |
| `convoy_escort_factor` | 1 | 无 consumer |
| `vision_add` | 1 | 无 consumer（且 effect_summary 渲染成"视野 +1000%"） |
| `desertion_factor` | 0 | 无 consumer（逃兵率硬编码 0.5%） |
| `occupation_tax_efficiency` | 0 | 无 consumer |

**35 条军事 modifier term 中 18 条空转（51.4%）**。完全无效的军事节点 2 个（`tech.military.radio_command`、`tech.military.ambush_tactics`），半无效 4 个。

**这是集成缺陷，不是设计取舍**，标记为 `blocked`（需 bug fix），不是重设计。

### 6.4 真正有效的军事通道：6 个战术条令

`military_core_war.cpp:301–352` 的 `evaluate_rules()` 已实现 6 条**完全条件化**的战术规则，参数经 `rule_param_q16()` 从 `country.military.rule.*` 读取（base 0、clamp [0,4]），并通过 `mul_q` 真正作用于战果：

| 条令 | 触发条件 | 作用 | 建议语义 |
|---|---|---|---|
| `rule.mutual_support` | 2 格内友军（≤3 支） | 每支友军给防御 | 方阵 / 连坐 |
| `rule.last_stand` | 断补给时 | 攻防加成且禁止自动脱战 | 死守 / 焦土 |
| `rule.blitz` | 进攻且开战 5 日内且 speed ≥ 2.0 | 攻击加成 | 闪击 |
| `rule.hold_the_line` | HOLD 姿态被攻 | 防御加成 | 坚守 |
| `rule.encirclement` | 目标格 ≥4 邻为我方 | 攻击加成 | 合围 |
| `rule.home_ground` | 本国领土 | 攻防加成 | 卫国 |

**36 个军事科技一次都没用过这 6 个通道。** 这是军事设计最大的一块空地，也是"科技改变战术形态"唯一现成的落点。

### 6.5 其他军事结构问题

| 问题 | 证据 |
|---|---|
| 兵种解锁在科技树里**无法表达** | `content_effects.kind` 只有 good/building/resource/runtime 四种，**没有 `unit`**；416 节点 0 次提及 24 个兵种 id。19 个军事科技里 11 个的真实价值玩家看不见 |
| 军事节点在图上没有任何链 | 36 个节点全部 `branch_successor_ids=[]`、`application_target_ids=[]` |
| agrarian 军事空白 | 0 节点，而 era=1 的兵种却绑 kingdom 科技 |
| 没有远程 class | `class` 枚举只有 `LINE / MOBILE / ARTILLERY`；`missile_arms` 只有一个档位 |
| 海军/空军整链缺失 | 24 兵种全陆军；`aircraft` 0 物资 0 建筑；`warship` 不存在 |
| 兵种级口粮不可实现 | `supply_idle.ration` 24 个兵种全 0 且字段被忽略（全国统一） |
| `mechanized_infantry` / `sp_artillery` 要求 `mounts`（马匹） | 复制粘贴 bug，有真实经济后果 |
| 军事成本恒为该代最低档 | empire 之后 7 个时代全部钉在最低价位，军事从不是投资决策 |
| `coastal_transport` 有真实效果但未声明 | `military_catalog.json:unlock_tech_ids[0]` → 水路通行硬开关（≤3 连续水格可过）。属"效果未声明"，补一条 `kind:"runtime"` 的 content_effect 即可 |

**最大的浪费**：`gdext/src/military_core_war.cpp:300–352` 已经实现 6 套**战术条令内核**（`mutual_support` 友军互援、`last_stand` 断补给死守、`blitz` 前 5 日突袭、`hold_the_line` 坚守反击、`encirclement` 四邻合围、`home_ground` 本土作战），每个都是条件触发的实战修正 —— **而 36 个军事科技一次都没用过这 6 个通道**。

**已具备但未使用的内容能力**：`data/military/military_catalog.json` 的 `units` 是**数据驱动**的（字段含 `era` / `tech` / `attack` / `defense` / `speed` / `training_days` / `equipment` / `class` / `militia`），共 24 个兵种、9 类装备、17 座军事建筑。**新增兵种属于 `new_content`，不需要新运行时。**

---

## 7. 出生点现状

（细节见 `06-review-findings.md` 与 04 章）

- 7 个起始科技**全员相同**，`is_starter_eligible` + `starter_capability_tags`（11 节点、标签如 `starter.food`）**没有任何代码读取** —— 这套"起手能力标签"是设计留白。
- 由于 4.2 的 route 门槛全是行业指标，**出生点通过"你能先发展哪个行业"间接决定你能研究哪条支线**。这是差异化的真实来源，但它是**隐性的、玩家无法预期的**，也不受玩家选择控制。
- 6 个 `production_climate_profile`：`dryland_crop` / `paddy_crop` / `plantation_crop` / `pasture_livestock` / `foraging_plants` / `phenology_observation`。
  **缺**：高原/冷凉作物、水产/海洋、林业、设施农业（温室）。所以"高地""海洋""森林"三种生态**没有专属气候档案可被科技强化**。

---

## 8. 与上一版诊断的对照

`docs/plans/technology-tree-diagnosis.md`（369 节点版）提出的问题，本版的处理进度：

| 上一版问题 | 现状 | 结论 |
|---|---|---|
| 成本断崖（探索 3000 < 帝国 42000） | 已修复，逐代单调 | ✅ |
| 硬前置跨 ≥3 时代 67 条 | 现为跨 >1 时代 97 条 | ⚠️ 仍偏多 |
| 6 个支线族中途死亡 | 现为 7 个 | ❌ 未改善 |
| `food_storage` 主干断 4 代 | 现断 2 代（atomic/information） | ⚠️ 改善 |
| 21 个叶子节点 | 现"裸叶子"12 个 | ✅ 改善 |
| 4 个零前置主干节点 | 仍在（settled_knowledge / agrarian_society / kingdom_administration / imperial_integration 及后续里程碑） | ⚠️ |
| 物资重复解锁 106 | 现 133 | ❌ 恶化 |
| 后期 reveal 100% `development.*` | 仍然如此 | ❌ 未改善 |
| `industry.*` 混入 technology_tags | 仍有 3 座建筑（computing_research_center / machine_intelligence_institute / national_laboratory） | ⚠️ |
| 效果列表展示全生命周期 | 需要 presentation 层修复 | 未验证 |

**新增问题（上一版未发现）**：
1. **聚合倍率 ×41–×51 失控**（第 2.2 节）
2. **`population.death_factor` 已撞顶 187%**（第 2.3 节）
3. **225 个地理通道几乎零使用**（第 2.1 节）
4. **`research_routes` 全部退化为行业阈值，形成隐性行业互斥**（第 4.2 节）
5. **军事 6 个战术条令通道零使用 + 农耕时代军事空白**（第 6 章）
6. **21 座研究建筑产能恒定 64/日，与 ×4000 的成本增长不匹配**（第 3.3 节）
7. **6 个零效果科技，203,100 研究点黑洞**（第 2.4 节）

---

## 9. 诊断评分

| 维度 | 评分 | 一句话理由 |
|---|---|---|
| 前置逻辑关系 | 5.5 / 10 | 无环、0 悬空、逐代单调；但 7 个火器节点的祖先闭包里没有火药，97 条跨代边里有相当比例是"产业链上下游"冒充"核心知识" |
| 触发条件可达性 | 5 / 10 | 四层门结构精巧，但 route 层退化成 5 个部门指标，4 个天气信号是死的，28 个实践突破只接了 8% |
| 地理气候相关性 | **3 / 10** | 235 个地形杠杆用了 3 个；315 个资格门里 3 个含地理；79.6% 节点对地形无感 |
| 自由构筑与独特性 | **3 / 10** | **80% 强制完成率**让"选哪条路"变成"必须走完全部路段" |
| 内容覆盖完整性 | 5 / 10 | 静态谱系干净，但 71% 的链只有 1–2 环、蒸汽后 4 代 0 新建材、最后两代 79% 是克隆 |
| 解锁循序渐进 | 4 / 10 | 成本曲线数学平滑、体验呈 U 形；里程碑候选 30% 零内容；同代价格齐平 |
| 出生点产业特色 | 4 / 10 | 开局同构；差异化只来自 route 门槛的副作用，不可预期、不可选择 |
| 军事体系 | 4 / 10 | 36 节点散落 11 族、agrarian 空档、51.4% 修饰符是死代码、6 个战术条令零使用 |
| **总评** | **4.3 / 10** | **工程骨架优秀，玩法表达失败** —— 地理在资格层缺席，身份在强制研究下无法产生，效果全挤在同一条百分比通道上 |
