# 军事系统策划案 v1.3（兵种与装备 · 兵营与兵员 · 部队 · 自动后勤 · 战争 · 战线 · 占领 · 和议与吞并 · 军工与火药 · 理念 · 家族 · 事件）

> 状态：设计提案，尚未实现。基线为 2026-11-02 的代码现状。实现时如果改变 runtime 机制，
> 必须按 `project-keynes-runtime-architecture` 同步 `docs/cpp-dots-runtime/*` 与 `references/system-map.md`。
> 本文是计划文档，不代表当前事实。家族军事内容表单独放在
> [military-family-content.md](./military-family-content.md)。

## v1.4 修订记录（2026-11-02）

| # | 反馈 | 处理 | 章节 |
| --- | --- | --- | --- |
| 1 | 采购不必扫描所有市场，扫描 3 格内本国地块即可 | 废弃按类别的全国最近市场场；需求者只从 3 格内本国拥有且控制的市场采购，无货记为未满足需求，不做全局回退 | §9.3、§21.4 |

## v1.3 修订记录（2026-11-02）

| # | 反馈 | v1.3 的处理 | 章节 |
| --- | --- | --- | --- |
| 1 | 士兵的口粮来自军队补给，日常消费品来自当地消费 | 主食、蛋白质两项需求改为「军供需求」：由军需口粮按实物满足，国库付款，不进市场购买。其余需求（衣着、住房、日用品等）由士兵用军饷在所在地市场购买。军饷的 AUTO 公式改为只计非食品生活成本 | §5.1、§5.7、§9.2、§9.6、§10 |
| 2 | 全境沦陷不自动吞并，必须经过议和 | 删除自动吞并。吞并只有一种途径：和约割让了受害国的最后一格领土。全境沦陷只提高受害国接受和议的倾向 | §11.1、§12.3、§12.5 |
| 3 | 统帅只留特殊任务空位，具体效果下一版做 | 部队保留空的统帅位（数据字段与 UI 空位），v1 不开放任命命令，统帅不产生任何效果。依赖统帅的家族效果改写为不依赖统帅的版本 | §6.4、§18 |
| 4 | 家族代码由你实现，这边先设计效果 | 家族表维持纯内容设计，按现行校验器格式交付 | §18 |
| 5 | 补充火药的科技与建筑体系，蒸汽、原子时代不能还只有早期生产方式 | 新增「发射药」品质族（黑火药 → 无烟火药 → 现代发射药）和中间品硝酸；黑火药 4 档、无烟火药 2 档、现代发射药 3 档，另有硝田与合成硝酸厂，共 10 座建筑；新增 6 项火药科技 | §15.3、§16.2 |

## v1.2 修订记录（2026-11-02）

| # | 反馈 | v1.2 的处理 | 章节 |
| --- | --- | --- | --- |
| 1 | 不做行军干粮，专注武器、弹药和军工中间品；不做军用罐头，复用现有食物产业 | 删除干粮和军粮罐头。士兵吃饭走普通居民消费，使用现有食物产业 | §4、§9、§15 |
| 2 | 吞并灭国要做 | 一国失去全部自有领土的控制权后，次日被占领方吞并；和议也可以割让全部领土 | §12.5 |
| 3 | 兵营只区分训练容量，训练时间由军校决定 | 兵营各档只有「兵额」不同，兵额同时就是训练容量；训练速度只来自军校 | §5.3 |
| 4 | 入伍后没有指派兵种时，默认是战斗力较低的「民兵」 | 新增兵种「民兵」：无需装备、无需训练，入伍即可编成部队 | §4.3、§5.6 |
| 5 | 不做远程、防御兵种，兵种只区分攻防速，可以有无视工事的炮兵 | 兵种只分三类：步兵、机动（骑兵/装甲）、炮兵（无视部分工事）。删除兵种地形修正和崎岖系数 | §4、§7 |
| 6 | 不作战也要吃补给，作战时吃得更多 | 补给分「日常」和「作战附加」两部分；弹药、维护、燃料在作战时成倍消耗 | §9.2 |
| 7 | 军人会在当地进行个人消费 | 驻防士兵就是驻地格的真实 cohort，照常在本地市场消费；部队中的士兵作为「客籍消费者」在部队所在格的市场消费 | §5.1、§5.7 |
| 8 | 士兵不能主动转职；其他职业在当兵收入更高时按现有转职逻辑主动当兵 | 兵营是官营建筑，士兵岗位是普通雇员岗；招聘走现有就业比较，士兵禁止向外转职 | §5.4 |
| 9 | 新增部队命令「军事控制」 | 划定区域后，部队自动在区域内寻找敌军或敌方控制的城市作战 | §6.3 |
| 10 | 需要更高性能的实现 | 新增高性能章节：稠密格索引、A*、按物资类别的多源最近市场场、威胁场、增量战线、计划后回放的并行、GPU 插值棋子 | §21 |
| 11 | 对接现有事件系统 | 定义军事 GameplayEvent、Trigger 选择器、Effect 事件叠层类型、叙事事实事件、年报和音乐 | §19 |
| 12 | 车队被截率应与沿途敌军战力相关，而不是看路段占全程的比例 | 每日按车队当日途经格的「敌方威胁 / 我方护卫」计算被截概率；补给线越长、越靠近敌军，风险越高 | §9.5 |
| 13 | 暂时不做战争疲劳 | 删除疲劳及其所有效果 | — |
| 14 | 分期赔款：总额是一次性赔款的 n 倍，每 30 日交一期 | 每期金额等于一次性赔款额 A，共 n 期，总额 n×A | §12.3 |
| 15 | 石矛和弓箭分开；弓箭可由不同时代的不同建筑以不同效率生产；武器做成品质族，品质影响战力 | 武器分为兵器、弓箭、护具、火器、火炮、弹药、装甲车辆等类别，各有 Q1–Q5 品质；「弓箭」是单一物资，由三代建筑以递增效率生产 | §4.2、§15 |
| 16 | 暂不做投降，并入战争分：分差越大越容易接受条件 | 删除投降，接受倾向随战争分差增长 | §12.3 |
| 17 | 火药应成为物资和产业链的一环 | **新增**物资「火药」（不改名「炸药」）。炸药厂改用火药作原料，火器、弹药也用火药 | §15.3 |
| 18 | 暂不做疾病减员 | 删除；只保留积雪、冰川、极旱沙漠的恶劣环境减员 | §7.1 |
| 19 | 军事理念需要有深度联动和构筑 | 新增三条联动通道：慢变量地块光环、快变量部队规则、会战事件叠层；设计 20 张卡和 3 个羁绊 | §17 |
| 20 | 给家族补充军事特性和效果 | 新增 10 条偏好和 14 条效果，已通过家族设计校验器 | §18 |

---

## 0. 一页摘要

| 主题 | 设计 |
| --- | --- |
| 兵种 | 三类兵种（步兵、机动、炮兵），只区分攻、防、速，炮兵无视部分工事。另有默认兵种「民兵」 |
| 装备与品质 | 训练兵种时消耗装备。装备按类别填充，可用更高品质的物资代替（与工具族相同的机制）；品质越高战力越高 |
| 士兵 | 普通职业 `soldier`。口粮（主食、蛋白质）由军需补给按实物供给；衣着、住房、日用品等日常消费由士兵用军饷在所在地市场购买。驻防士兵是驻地格的真实 cohort；编入部队后进入「随军人口」，在部队所在格作为客籍消费者消费。不记录来源地 |
| 兵营 | 官营建筑，只能由玩家或 AI 建造和拆除。兵额 = 当地最多容纳的本国士兵，也是训练容量。外地部队进驻也会占用兵额 |
| 招兵 | 兵营岗位参与现有就业比较：军饷有吸引力时，其他职业会主动转职为士兵。达到目标兵力（按人数或按预算设定）后停止招兵；缺员时可以自动征召。士兵不能主动转出 |
| 部队 | 由驻防兵编成，可指定目标格自动寻路前进，也可执行「军事控制」区域任务；保留一个统帅空位，留给后续版本 |
| 地形 | 地貌、植被、覆盖三类成本相加，所有兵种同一套。除高峰和火山外的陆地都可通行 |
| 后勤 | 全自动：从所在格 3 格内的本国控制区市场就近采购，按贸易速度运抵。被截概率取决于沿途敌方战力 |
| 补给 | 口粮加装备补给，均分日常与作战附加，国库付款；军饷由国库支付，只覆盖非食品生活成本 |
| 战争 | 宣战形成交战段，日结算加会战，进攻方进度满 100% 夺取一格；控制权与所有权分离 |
| 和议 | 割地、一次性赔款、分期赔款、赔物资，全部按战争分定价，分差越大越容易被接受 |
| 吞并 | 只能通过和议：和约割让了一国的最后一格领土时，该国被吞并。全境沦陷不会自动吞并，只会大幅提高其接受和议的倾向 |
| 火药 | 发射药品质族：黑火药（帝国）→ 无烟火药（蒸汽）→ 现代发射药（原子），每代都有对应的生产建筑和科技 |
| 内容 | 33 种军需物资、42 座私营军工建筑、3 类官营建筑、35 项军事科技、20 张理念卡、24 条家族内容 |
| 性能 | 标准图（60×40）战时 Military 日阶段 p95 ≤ 0.5 ms；100k 格、2048 支部队的压测 p95 ≤ 2 ms |

结构决定：

1. 新增 **`NativeMilitaryRuntime`**，存档段 `pkmi`。它在 Host 的 COUNTRY stage 尾部运行，采用「读 D 日已提交数据、产出 D+1 命令」的模式，不新增 runtime domain bit。
2. Military **只写自己的 store**。其他域只通过命令或冻结快照修改：
   - Country：领土、控制权、国库、吞并；
   - Economy：入伍、征召、编入部队、拆编、退伍、伤亡、军需采购；
   - Modifier：军事修正值；
   - GameplayEvent：战斗事实。
3. **不铸币、不凭空造物。** 军饷是国库到士兵的转移；士兵的日常消费是普通市场交易；口粮和装备从市场采购进入 Military 托管，消耗、缴获和退回都有显式账目。

---

## 1. 设计目标、非目标与不变量

**目标**
- 军事和经济是同一张账。
- 大战略层级的操作：玩家决定建兵营、定兵力与兵种配置、指挥部队或下达区域任务、议和；招兵、训练、补员、补给全部自动完成。
- 跨 11 个时代的装备演进。

**v1 非目标**
- 海战与海军单位、独立空军（只做海运运兵）。
- 同盟、通行权、附庸。
- 投降、自动吞并（吞并必须经过和议）。
- 统帅效果（v1 只保留空位）。
- 战争疲劳。
- 疾病。
- 叛乱实体。

**必须遵守的现有不变量**（与 v1.1 相同）
1. 人口、货币、物资审计误差恒为 0。
2. 水格永不归属任何国家。活跃国家至少有 1 格领土；吞并时国家与其全部领土在同一个 Country 批次内同时失效。
3. 领土和控制变化走唯一广播 `country_committed`。经济在 epoch 开始时冻结。
4. 每个 `(cell, signature)` 只有一个 cohort；有人口的格必须有活商人；出生一律进入 `unemployed`。
5. 热循环不使用 Dictionary、Variant、String，不在循环内分配内存；随机数一律由世界种子派生（SplitMix64）；worker 与 scalar 的 state hash 必须相等。
6. 新命令要同时实现 worker POD 路径和同步 staged 路径；未开放的命令返回 gate-closed，不能伪成功。

---

## 2. 权威划分

| 状态 | 唯一权威 | 存档 |
| --- | --- | --- |
| 兵种、装备类别、品质目录 | `UnitTypeCatalog`（GDScript 编译 → native dense） | catalog hash |
| 驻防士兵（`(cell, soldier\|eth)` cohort） | Economy | PKEC v59 |
| **随军人口**（每支部队一条 lane：人口、资金、满意度、家族归属子账、重要人物句柄） | Economy（`ArmyPersonnelStore`） | PKEC v59 |
| 官营建筑（兵营、城防、军校） | Economy（建筑组，业主为 STATE 哨兵） | PKEC v59 |
| 士兵登记批次（位置 × 兵种 × 装备品质 → 人数）、训练订单、兵种配置、目标兵力 | Military | PKMI |
| 部队、路径、任务（目标格或军事控制区域）、统帅空位、组织度 | Military | PKMI |
| 部队与驻防的军需库存（含口粮）、在途车队 | Military（托管） | PKMI |
| 交战段、战争、战争分、分期赔款 | Military | PKMI |
| `cell_controller_slot`、吞并 | Country | PKCN v14 |
| 军事修正值 | Modifier | PKCM |

对账不变量（每个经济 commit 校验）：

```text
Σ_{登记批次 位于 GARRISON(c)} count + pending(c) == pop(c, soldier|*)
Σ_{登记批次 位于 ARMY(a)}     count + pending(a) == ArmyPersonnel(a).population
```

---

## 3. 兵员与装备的两层模型

- **人**由 Economy 管：谁当了兵、住在哪里、有多少钱、吃什么、是否满意、属于哪个家族。
- **兵种和装备**由 Military 管：这些人被训练成什么、拿着什么品质的武器、编在哪支部队。

两者通过登记批次对账，互不越权。

---

## 4. 兵种与装备

### 4.1 兵种类别

| 类别 | 说明 |
| --- | --- |
| 步兵 `line` | 基础类别 |
| 机动 `mobile` | 骑兵、战车、装甲、无人机，速度高 |
| 炮兵 `artillery` | `fortification_ignore_q16 > 0`，攻击时无视对方部分工事 |

兵种之间**只有攻、防、速和炮兵无视工事的差别**，不做地形克制、远程或防御的特殊玩法。

### 4.2 装备类别与品质（与「工具」族相同的机制）

每个装备类别是一组可以互相替代的物资，物资的 `production_quality_level` 是 Q1–Q5。兵种为每个装备槽声明「类别 + 最低品质」，训练时可以用不低于最低品质的任意候选物资。

| 类别 id | 名称 | Q1 | Q2 | Q3 | Q4 | Q5 |
| --- | --- | --- | --- | --- | --- | --- |
| `melee_arms` | 兵器 | 石矛（石器） | 青铜兵器（农耕） | 铁制兵器（王国） | 钢刃（帝国） | — |
| `missile_arms` | 弓箭 | 弓箭（单一物资，见 §15.2） | — | — | — | — |
| `body_armor` | 护具 | 皮甲（农耕） | 铁甲（王国） | 板甲（帝国） | 防弹护具（原子） | — |
| `firearms` | 火器 | 火绳枪（探索） | 燧发枪（启蒙） | 步枪（蒸汽） | 自动步枪（电气） | 智能单兵武器（智能） |
| `ordnance` | 火炮 | 攻城器械（帝国） | 铜炮（探索） | 钢炮（蒸汽） | 榴弹炮（原子） | 导弹发射系统（信息） |
| `ammunition` | 弹药 | 火药弹丸（探索） | 定装弹药（蒸汽） | 现代弹药（原子） | 制导弹药（信息） | — |
| `armored_vehicles` | 装甲车辆 | 早期坦克（电气） | 现代坦克（原子） | — | — | — |
| `mounts` | 坐骑与战车 | 马匹（现有物资） | 战车（农耕） | — | — | — |
| `drones` | 作战无人机 | 作战无人机（智能） | — | — | — | — |

**品质倍率**：Q1 1.00 / Q2 1.20 / Q3 1.45 / Q4 1.75 / Q5 2.10。

```text
equip_factor(lot) = Σ_slot w_slot × qmult(实际品质_slot) / qmult(最低品质_slot) / Σ w_slot
```

- 登记批次记录训练时实际装备的平均品质（`equip_quality_q8`）。
- 用更好的武器装备同一兵种可以获得最多约 +75% 的战力，例如铁甲步兵换上钢刃。这就是「换装」的意义。

**装备耗损**：日常维护补给（§9.2）不足时，批次的装备完好度 `condition` 每日下降 0.5%，最低 50%。补足后每日回升 1%。战力乘以 `0.5 + 0.5 × condition`。

### 4.3 兵种表（装备按每 100 人计）

日常补给与作战附加见 §9.2。

| 时代 | id | 名称 | 类别 | 攻 | 防 | 速 | 装备槽（类别≥最低品质 数量） | 解锁 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 全时代 | `militia` | 民兵 | 步兵 | 0.5 | 0.6 | 1.0 | 无 | 默认兵种。攻防另乘时代系数 `1.35^era_index` |
| 石器 | `tribal_warriors` | 部落战士 | 步兵 | 1.0 | 1.0 | 1.0 | 兵器≥Q1 10，弓箭 6 | 开局 |
| 农耕 | `bronze_spearmen` | 青铜矛兵 | 步兵 | 1.6 | 2.2 | 1.0 | 兵器≥Q2 12，护具≥Q1 6，弓箭 4 | tech.bronze_casting |
| 农耕 | `chariot_troops` | 战车兵 | 机动 | 2.6 | 1.2 | 1.6 | 坐骑：战车 8 + 马匹 20，兵器≥Q2 6 | tech.military.chariot_warfare |
| 王国 | `iron_infantry` | 铁甲步兵 | 步兵 | 2.4 | 3.2 | 1.0 | 兵器≥Q3 12，护具≥Q2 8，弓箭 6 | tech.military.standing_army |
| 王国 | `cavalry` | 骑兵 | 机动 | 3.4 | 1.8 | 2.0 | 马匹 25，兵器≥Q3 8，护具≥Q1 4 | tech.military.mounted_warfare |
| 帝国 | `legionaries` | 军团步兵 | 步兵 | 3.6 | 4.6 | 1.0 | 兵器≥Q3 12，护具≥Q3 12，弓箭 6 | tech.military.legion_logistics |
| 帝国 | `heavy_cavalry` | 甲骑具装 | 机动 | 5.0 | 3.6 | 1.6 | 马匹 30，护具≥Q3 15，兵器≥Q3 8 | tech.military.heavy_cavalry |
| 帝国 | `siege_train` | 攻城营 | 炮兵（无视工事 60%） | 4.0 | 1.0 | 0.6 | 火炮≥Q1 20 | tech.military.siegecraft |
| 探索 | `musketeers` | 火枪兵 | 步兵 | 6.0 | 4.0 | 1.0 | 火器≥Q1 10，兵器≥Q3 4 | tech.gunpowder_weapons |
| 探索 | `field_artillery` | 野战炮兵 | 炮兵（50%） | 8.5 | 2.0 | 0.7 | 火炮≥Q2 6，马匹 10 | tech.military.field_artillery |
| 启蒙 | `line_infantry` | 线列步兵 | 步兵 | 8.0 | 6.5 | 1.0 | 火器≥Q2 12 | tech.military.drill_regulations |
| 启蒙 | `dragoons` | 龙骑兵 | 机动 | 8.5 | 5.0 | 2.0 | 马匹 25，火器≥Q2 8 | tech.military.drill_regulations |
| 蒸汽 | `riflemen` | 步枪兵 | 步兵 | 12 | 10 | 1.0 | 火器≥Q3 10 | tech.military.rifled_weapons |
| 蒸汽 | `heavy_artillery` | 重炮兵 | 炮兵（70%） | 18 | 3 | 0.7 | 火炮≥Q3 12 | tech.military.rifled_weapons |
| 电气 | `machine_gunners` | 机枪步兵 | 步兵 | 16 | 16 | 1.0 | 火器≥Q4 14 | tech.military.machine_guns |
| 电气 | `early_armor` | 早期装甲 | 机动 | 26 | 18 | 1.3 | 装甲车辆≥Q1 4 | tech.military.armored_warfare |
| 原子 | `mechanized_infantry` | 机械化步兵 | 步兵 | 24 | 24 | 2.5 | 火器≥Q4 10，汽车 6，护具≥Q4 6 | tech.military.mechanization |
| 原子 | `tank_corps` | 坦克部队 | 机动 | 40 | 32 | 2.2 | 装甲车辆≥Q2 8 | tech.military.main_battle_tanks |
| 原子 | `sp_artillery` | 自行火炮 | 炮兵（75%） | 45 | 12 | 2.0 | 火炮≥Q4 8，汽车 4 | tech.military.mechanization |
| 信息 | `combined_arms` | 合成部队 | 步兵 | 45 | 45 | 2.5 | 装甲车辆≥Q2 4，火器≥Q4 8，军用电子设备 6 | tech.military.network_centric |
| 信息 | `missile_artillery` | 导弹炮兵 | 炮兵（80%） | 60 | 15 | 2.5 | 火炮≥Q5 4，军用电子设备 4 | tech.military.precision_guidance |
| 智能 | `exo_infantry` | 外骨骼步兵 | 步兵 | 60 | 70 | 1.5 | 火器≥Q5 10，护具≥Q4 10，电池 4 | tech.military.autonomous_warfare |
| 智能 | `drone_swarm` | 无人作战集群 | 机动 | 80 | 50 | 3.0 | 作战无人机 10 | tech.military.autonomous_warfare |

### 4.4 数据结构

```gdscript
class_name UnitTypeProfile extends Resource
@export var id: StringName
@export var display_name: String
@export_multiline var description: String
@export var icon: Texture2D
@export_enum("line", "mobile", "artillery") var unit_class: String = "line"
@export var era_id: StringName
@export var technology_tags: PackedStringArray
@export var is_default_militia: bool = false
@export var attack: float
@export var defense: float
@export var speed: float
@export var fortification_ignore_q16: int = 0
@export var training_days: int = 30
# 装备槽（每 100 人）
@export var equipment_category_ids: PackedStringArray
@export var equipment_min_quality_levels: PackedInt32Array
@export var equipment_quantities_per_100: PackedFloat32Array
@export var equipment_power_weights_q16: PackedInt32Array
# 补给（每 100 人 / 日）：日常 + 作战附加
@export var supply_category_ids: PackedStringArray     # fodder/ammunition/fuel/upkeep
@export var supply_idle_per_100_day: PackedFloat32Array
@export var supply_combat_extra_per_100_day: PackedFloat32Array
```

- 装备类别是 GoodProfile 的 `substitution_category_ids`，与工具相同；候选物资 CSR 和品质在目录编译时生成。
- 兵种数量至多 64 个，dense id 按稳定 ID 排序。
- 必须恰好有一个 `is_default_militia = true` 的兵种。

---

## 5. 兵员：士兵职业、官营兵营、招募、民兵、训练、随军人口

### 5.1 士兵职业

新增 `data/economy/professions/soldier.tres`：

- `display_name = "士兵"`，`profession_class_id = &"military"`，`entry_savings_days = 0`；
- 满意度权重偏向生存、收入、储蓄：`(65536, 39322, 13107, 6554, 52429, 32768, 13107, 6554)`；
- 默认消费计划为新增的 `soldier_household`，按 `industrial_worker_household` 配置，覆盖全部基本需求；
- 新增字段 `state_service_only = true`：这个职业只能作为官营兵营的雇员岗出现，目录编译时校验；
- 新增字段 `state_supplied_need_ids = ["staple_food", "protein"]`：这两项需求是**军供需求**，见下文。

**口粮军供，日常消费自理。**

- **军供需求（主食、蛋白质）**：由 Military 托管的口粮按实物满足，不进入市场购买。
  - 口粮由 §9 的就近采购从市场买入，**国库付款**；
  - 每日按人头在士兵所在位置消耗（驻防格的驻防库存，或部队库存）；
  - Economy 在居民清算时把这两项需求的满足率直接设为「口粮满足率」，并跳过它们的市场购买与支出；
  - 满足率进入满意度的生存维度，所以口粮断供会直接打击士气，也会让生存维度驱动的死亡生效。
- **其余需求（衣着、住房、日用品、卫生、能源、文化、奢侈等）**：士兵用自己的军饷和存款，按 `soldier_household` 计划在**所在地市场**购买，与普通居民完全相同。

驻防士兵是驻地格的 `(cell, soldier|eth)` cohort，除了军供需求，其他方面与普通 cohort 完全一样：

- 在本地市场按消费计划购买衣着、住房维护、日用品等（**普通居民消费**）；
- 计算满意度、缴纳所得税；
- 可以属于显赫家族，家族成员的转职、迁移规则全部适用。

### 5.2 官营建筑（经济侧的通用新能力）

- `BuildingProfile.building_kind` 新增 `"state"`，并新增 `state_role`（`barracks` / `fortification` / `war_college`）。
- 业主签名是保留哨兵 `STATE_OWNER_SIGNATURE`，归属国 = 所在格的 owner。
- **只能用命令 `STATE_BUILD` / `STATE_DEMOLISH` 建造和拆除。**
  - 不参与投资评审、恢复期清算、亏损停业、家族产业和商人借贷。
  - `STATE_BUILD` 的结算复用 `TREASURY_SPONSORED_BUILD`：国库物资优先，不足部分从本格市场补，现金由国库按本期零售价支付，预检通过才扣款，然后进入 `pending_construction`。
  - `STATE_DEMOLISH` 在下个采样日执行，不退还建材。
- **维护费**每个 epoch 由国库支付，经 `coordinate_country_treasury_spend`，计入非税支出 `military_upkeep`。国库实付率低于 50% 时建筑「失修」，效果减半。
- 预检：本国**拥有且控制**该格，科技已解锁。
- 割让后，官营建筑随领土归新 owner。

### 5.3 官营建筑目录

**兵营**（升级家族 `barracks`）：各档只有兵额不同。兵额 = 本格最多容纳的本国士兵 = 本格训练容量。

| 时代 | id | 名称 | 兵额/栋 | 建材 | 工期 | 维护/栋·日 | 解锁 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 石器 | `warrior_lodge` | 战士营地 | 4 | logs 20, turf_block 10 | 10 日 | 0.02 | 开局 |
| 农耕 | `palisade_barracks` | 木栅兵营 | 10 | lumber 30, adobe_brick 20 | 20 日 | 0.05 | tech.military.earthen_ramparts |
| 王国 | `garrison_barracks` | 戍卫营 | 25 | bricks 40, lumber 30, wrought_iron 5 | 30 日 | 0.15 | tech.military.standing_army |
| 帝国 | `legion_fort` | 军团营寨 | 50 | bricks 80, raw_stone 60 | 45 日 | 0.4 | tech.military.legion_logistics |
| 启蒙 | `drill_depot` | 操练营 | 100 | bricks 120, glass 20 | 45 日 | 1.0 | tech.military.drill_regulations |
| 蒸汽 | `army_depot` | 兵站 | 200 | steel 40, cement 60 | 60 日 | 2.5 | tech.military.general_staff |
| 原子 | `military_base` | 军事基地 | 400 | concrete 100, steel 60, electrical_equipment 10 | 75 日 | 6 | tech.military.mechanization |
| 信息 | `training_complex` | 联合训练中心 | 800 | concrete 150, computers 10, telecom_equipment 10 | 90 日 | 15 | tech.military.network_centric |

**城防**（升级家族 `fortification`，每格最多 1 栋）：提高本格工事系数 `fort(b)`。

| 时代 | id | 名称 | 工事加成 | 建材 | 解锁 |
| --- | --- | --- | --- | --- | --- |
| 农耕 | `earthen_rampart` | 夯土城垣 | +0.3 | turf_block 40, logs 30 | tech.military.earthen_ramparts |
| 王国 | `stone_walls` | 石砌城墙 | +0.6 | raw_stone 120, bricks 60 | tech.masonry |
| 帝国 | `citadel` | 城堡要塞 | +1.0 | raw_stone 200, bricks 120 | tech.military.siegecraft |
| 探索 | `star_fort` | 棱堡 | +1.4 | bricks 250, raw_stone 150, bronze_cannon 4 | tech.military.star_forts |
| 电气 | `bunker_line` | 碉堡防线 | +1.8 | concrete 200, steel 60 | tech.military.machine_guns |
| 智能 | `hardened_defense_network` | 加固防御网 | +2.4 | concrete 300, military_electronics 20 | tech.military.ai_defense_grid |

**军校**（升级家族 `war_college`）：训练速度只来自这里。

- 本格训练速度取本格最高档军校的倍率；
- 全国效果可叠加，但每栋边际递减；
- 没有军校的格训练速度为 ×1.0。

| 时代 | id | 名称 | 本格训练速度 | 全国效果（每栋，上限） | 解锁 |
| --- | --- | --- | --- | --- | --- |
| 王国 | `martial_academy` | 武学馆 | ×1.5 | 组织度恢复 +5%（+25%） | tech.military.standing_army |
| 启蒙 | `military_academy` | 军事学院 | ×2.0 | 组织度恢复 +8%，攻击 +2%（+10%） | tech.military.drill_regulations |
| 信息 | `war_simulation_center` | 兵棋推演中心 | ×3.0 | 攻防 +3%（+12%） | tech.military.network_centric |

### 5.4 招募：普通转职、目标兵力、缺员征召

**兵营岗位是普通雇员岗。** 兵营建筑组的雇员角色是 `soldier`，工资政策为新值 `"state_payroll"`，工资 = 国家军饷（§9.6），由国库支付。

**自愿入伍**：直接复用现有 `building_employment`。
- 失业者和其他职业的 cohort 比较「税后军饷 − 生活成本」与当前的机会收益，军饷更有吸引力时就转职为士兵。
- 存款门槛、家族偏好（职业轴，见 J023/J025）全部照旧生效。

**士兵不能主动转出**：soldier cohort 不参与雇员↔雇员、雇员→业主、失业回流、家族开拓抽人、迁徙等全部**向外**转职路径。

**超编不裁员**：`soldier 人口 > 本格兵额` 时，就业对账**不会**把士兵打回失业池，只是不再招人。例如兵营被拆除、外地部队进驻都会造成超编。

**招兵配额**：Military 在 epoch 开始前冻结每格配额，Economy 按配额填岗。

```text
present(cell) = pop(cell, soldier) + Σ 位于 cell 的部队随军人口（不论从哪里开来）
open(cell)    = max(0, posts(cell) − present(cell) − pending(cell))   # owner = controller = 本国才 > 0
deficit       = target − (全国士兵 + 全国 pending)
quota(cell)   = 把 deficit 按 open(cell) 比例分配到各格，最大余数按 cell 升序
兵营本期可招人数 = min(open(cell), quota(cell))
```

- **外地部队进驻**：大部队开进一个兵营格、`present ≥ posts` 时，这个格的招兵配额为 0，本地停止招兵。
- **目标兵力**：

  ```text
  military.force.set_target {mode: HEADCOUNT, value: N}
  military.force.set_target {mode: BUDGET, value: 每日军费上限}
  ```

  BUDGET 模式下 `target = floor(budget / per_soldier_cost)`，其中 `per_soldier_cost` = 军饷 + 人均国库补给的 30 日均值 + 均摊的兵营维护费。每个经济 commit 重算一次，变化超过 ±2% 才生效。

- **缺员自动征召**：`military.force.set_levy {enabled}`，默认开。
  - 本期自愿入伍填不满配额时，在下一个采样日发出 `MILITARY_LEVY {cell, count}`，强制把剩余配额从本格失业池转为士兵；
  - 失业池不足时按非商人、非业主雇员 cohort 的比例抽取；
  - 永不抽走最后一个活商人，不让本格人口低于 5；
  - 单格单次征召上限为 `max(1, 本格人口 × country.military.levy_rate)`，默认 3%；
  - 被征召的人当期士气 −0.10。
- **暂停**：`military.barracks.pause {cell, paused}` 让该格配额为 0。

### 5.5 退伍、伤亡与对账

| 命令 | 规则 |
| --- | --- |
| `MILITARY_DISCHARGE {cell, count}` | soldier cohort 转为本格 `unemployed\|eth`，资金和家族归属随人走。需要本国拥有且控制该格 |
| `MILITARY_CASUALTY {cell \| army, count}` | 人口减少，资金留在 cohort 或随军 lane |
| 超编自动退伍（`military.force.set_auto_discharge`，默认关） | 全国士兵超过目标时，按「民兵 → 后方驻防 → 过时兵种」的顺序退伍。部队中的士兵永远不会被自动退伍 |
| 逃兵 | 军饷实付率的 30 日均值低于 50% 时，每日 `0.5% × (1 − pay_ratio)` 的驻防士兵退伍；部队中的士兵在部队回到本国控制格前不会逃散 |

- 自然死亡由 Economy 结算。Military 对账时按各批次人数比例扣减，记为「非战斗减员」。
- 割让或吞并时，位于被割格的驻防士兵转为一支撤退部队返回本国（§12.4）。

### 5.6 民兵、兵种配置、训练与改训

**民兵**
- 入伍的人一律先成为**民兵**：不需要装备，不需要训练，可以立即编成部队，攻防较低。
- 玩家没有给出兵种配置，或配置份额没有覆盖时，士兵保持民兵。

**兵种配置**：`military.config.set {shares: {unit_id: bp}}`，份额合计 ≤ 10000，未分配的部分保持民兵。

**自动训练**：新兵（民兵）在入伍格排队，训练成配置中缺口最大的兵种：

```text
缺口_u = share_u × target − (现有_u + 训练中→u)
```

**训练规则**

| 项 | 规则 |
| --- | --- |
| 训练格 | 本国拥有且控制、建有未失修兵营的格 |
| 容量 | 同时在训人数 ≤ 本格兵额 |
| 时长 | `ceil(to.training_days × kind_factor × country.military.training_time_factor / 训练速度(cell))`；训练速度只看军校（§5.3）。`kind_factor`：民兵→兵种 1.0；同类别改训 0.4；跨类别改训 0.8；**同兵种换装** 0.25 |
| 装备 | 按 §9 的自动采购送到训练格，到货才开训。同类别改训可以沿用部分装备（物资 ×0.6）；同兵种换装只补差额 |
| 品质选择 | 自动选择库存中品质最高的候选物资；`military.config.set_quality_policy {BEST \| CHEAPEST}` |
| 在训状态 | 不能编入部队；守备按原兵种的 50% 计算；照常领饷、消费 |
| 取消 | 已到货或已消耗的装备不退 |

**手动训练**：`military.train {cell, from, to, count}`。外地开来的部队在兵营格拆编后，也可以就地改训。

**自动换装**：`military.config.auto_retrain {enabled}`，默认开。
- 后方驻防兵中份额超出配置的兵种，会按缺口改训；
- 品质低于当前可得最高品质的批次，会安排「同兵种换装」；
- 优先级低于新兵训练；前线部队不会被自动改训。

### 5.7 随军人口与客籍消费

**编入部队**（`ARMY_EMBARK {cell, army, count}`）：驻防 cohort 的人口、资金、家族归属、重要人物句柄转入该部队的 `ArmyPersonnel` lane。lane 结构参照家族开拓队的在途载荷。

**拆编**（`ARMY_DISEMBARK {army, cell, count}`）：转回该格的 soldier cohort。需要本国控制该格；如果是占领格，士兵会成为该格的居民 cohort。

这两种转换只在编成和拆编时发生，**部队每天行军不搬运人口**。

**口粮**：无论在哪里，随军士兵的主食、蛋白质需求都由部队库存中的口粮满足（§5.1 军供需求）。口粮由 §9 的就近采购运来，国库付款。

**客籍消费（日常消费品）**：部队所在格由本国控制、并且有活商人时，Economy 在该格的居民清算中把这条随军 lane 当作一个临时 cohort：
- 用 `soldier_household` 计划中的非军供需求、lane 的资金，在当地市场购买衣着、日用品等；
- 满意度用同一个内核计算，结果写回 lane。

部队位于野外、敌境或没有商人的格时，买不到日常消费品：这些需求暂时得不到满足，满意度缓慢下降。口粮照常由部队库存供给。

**家族**
- lane 带有家族归属子账和重要人物句柄，所以「家族子弟从军、随军、退伍回族」都成立。
- 随军的重要人物是 §6.4 统帅空位将来的候选人。

---

## 6. 部队

### 6.1 数据（SoA，容量上限 2048）

```text
ArmyStore (handle = gen<<32 | slot)
  owner_country, cell, next_cell, move_points_q16, stance(HOLD/ADVANCE/ASSAULT/RETREAT/EMBARKED)
  mission_kind(NONE/MOVE/AREA_CONTROL), target_cell, area_id
  organization_q16, path_offset/len, comp_offset/len (lot 引用), template_offset, reinforce_enabled
  commander_slot（v1 恒为空，见 §6.4）, supply_offset, supply_ratio_q16, morale_q16, pay_ratio_q16
  cached_attack/defense/headcount, engagement, name_seed
```

```text
headcount = Σ lots
attack    = Σ count × atk_u × equip_factor × condition_factor
defense   = 同理
speed     = min_u(speed_u) × country.military.speed_factor
```

### 6.2 命令

| 命令 | 说明 |
| --- | --- |
| `military.army.create {cell, units}` | 从该格的驻防兵中编成，同时发出 `ARMY_EMBARK` |
| `military.army.station {army, units?}` | 拆编为该格驻防，同时发出 `ARMY_DISEMBARK` |
| `military.army.transfer / merge / split` | 只能在同一格内 |
| `military.army.set_template / reinforce` | 补员模板与开关（§6.5） |
| `military.army.move {target_cell}` | 自动寻路前进 |
| `military.army.area_control {cells[] \| center, radius}` | 军事控制（§6.3） |
| `military.army.stop / stance` | 停止；切换姿态 |
| `military.army.rename` | 冷路径 |

命令在下一游戏日生效，只有 `stop` 当日生效。

### 6.3 军事控制（区域任务）

玩家在地图上框选一组格（上限 256 格），或给出「中心格 + 半径」（半径 ≤ 6）。部队就在区域内自动作战：

```text
每当（任务开始 | 当前目标失效 | 区域内出现新敌军 | 距上次评估 5 日）时重新选目标：
  候选 A：区域内可见的敌方部队
          score = 威胁值 × 1.5 − 路程天数 × 2 − max(0, 敌方强度/本部强度 − 0.8) × 100
  候选 B：区域内由敌国控制、聚落等级 ≥ 村庄的格
          score = 格价值 − 路程天数 × 2 − 守备强度/本部强度 × 50
  候选 C：区域内其余敌控格，score 同 B，但没有聚落加成
  候选 D：没有候选时，返回区域内离敌方最近的本国控制格，转为 HOLD 防守
  选择 score 最高、且预计强度比 ≥ 0.9 的候选（候选 A 可以接受 0.8）；都不满足时选 D
多支部队在同一区域：按部队强度降序贪心分配，已被预订的目标对后续部队 −30 分，避免一窝蜂扑向同一点
部队被逼出区域时自动返回；组织度 < 30% 时自动退到区域内的本国控制格休整，恢复到 70% 后继续
```

- 区域保存为 PKMI 中的排序格表，每个区域对应一个 bitset 视图。
- 候选只扫区域内的格和格 → 部队索引，复杂度 O(区域格数)。
- 评估由事件触发，每日每国最多 32 次。
- 「威胁值」与「格价值」复用 §9.5 的威胁场和 §12.2 的格价值缓存。
- AI 也通过这个命令管理战线。

### 6.4 统帅（v1 只保留空位）

- 每支部队有一个 `commander_slot` 字段，v1 恒为空，存档也只存空值。部队卡和编制器里显示一个灰色的「统帅（待开放）」空位，留作后续特殊任务的入口。
- v1 不开放任命命令，统帅不产生任何数值或规则效果，也不参与事件、叙事和家族效果。
- 下一版计划：随军的家族重要人物可以被任命为统帅，承担特殊任务（突袭、坚守、远征等），统帅效果与家族效果在那时一起设计。

### 6.5 自动补员

部队开启补员后，Military 每日比较 `template − 现有编成`：

- 从能与部队连通的本国控制格的驻防兵中，就近抽取**已训练好的同兵种**士兵；
- 他们组成补员队，按行军速度前往部队，到达后合并；
- 抽离和合并使用 `ARMY_EMBARK` 与 lane 之间的合并，均为守恒转移；
- 不会抽空兵营格最后 10% 的驻防，也不会抽调在训士兵。

---

## 7. 移动、地形与寻路

### 7.1 统一的地形成本（所有兵种相同）

`step_cost(u→v) = flat(v) + rough(v) + 渡河 + 运河修正`

| 地貌 | 平坦 | 崎岖 | 补给倍率 | 恶劣环境减员/日 | 防御 | 战斗宽度 |
| --- | --- | --- | --- | --- | --- | --- |
| 平原 / 低地 | 1 | 0 | ×1.0 | 0 | ×1.0 | ×1.0 |
| 三角洲 | 1 | 1 | ×1.1 | 0 | ×1.1 | ×0.8 |
| 盐滩 | 2 | 0 | ×1.3 | 0.05% | ×0.9 | ×1.0 |
| 丘陵 | 1 | 1 | ×1.1 | 0 | ×1.3 | ×0.9 |
| 高原 | 2 | 0 | ×1.2 | 0 | ×1.2 | ×1.0 |
| 裂谷 | 1 | 1 | ×1.1 | 0 | ×1.2 | ×0.7 |
| 荒原 | 2 | 1 | ×1.3 | 0.05% | ×1.3 | ×0.8 |
| 峡谷 | 2 | 1 | ×1.2 | 0 | ×1.6 | ×0.5 |
| 山地 | 2 | 2 | ×1.4 | 0.05% | ×1.8 | ×0.6 |
| 高峰 / 火山 | 不可通行 | — | — | — | — | — |

| 植被（叠加） | 崎岖 | 补给 | 防御 |
| --- | --- | --- | --- |
| 草原类、灌丛、苔原 | +0 | ×1.0 | — |
| 各类森林 | +1 | ×1.0 | ×1.2 |
| 热带雨林、云雾林、沼泽、湿地、泥炭沼、红树林 | +2 | ×1.1 | ×1.2 |
| 极旱沙漠、极地荒漠 | +0 | ×1.4 | —（另有恶劣环境减员 +0.10%） |

| 覆盖（随季节变化） | 平坦 | 补给 | 恶劣环境减员 |
| --- | --- | --- | --- |
| 积雪 | +1 | ×1.3 | +0.10% |
| 洪泛 | +2 | ×1.1 | — |
| 冰川 | +3 | ×1.6 | +0.30% |

- 渡河成本 +1；有军道科技后为 +0.5。经运河边成本减半。
- 自有领土内的成本 ÷ `country.military.logistics_move_factor`（军道、铁路）。
- 节奏（步兵速度 1.0）：平原 1 日，丘陵 2 日，林地丘陵 3 日，山地 4 日，积雪山地 5 日。机动兵种按速度成比例更快。
- 规划好的路径不因季节变化而重算；每一步实际推进时读取当前成本，所以积雪只会让行军变慢，不会让部队改道。

### 7.2 寻路

- 单目标寻路用 **A\***：启发函数是环绕感知的 cube 距离 × 最小单步成本 1，可采纳。
- 区域任务的候选评估用一次有界 Dijkstra，从部队出发，扩展上限 512，同时得到区域内全部候选的路程。
- 可通行规则：本国控制格、无主陆地、交战国控制格（进入即开战）可走；未交战的他国格不可走；水体需要海运能力。
- 详细实现见 §21.3。

### 7.3 每日推进与 ZOC

```text
mp += speed × 补给修正（<50% ×0.8）× 组织修正（<30% ×0.7）
while 下一格可进入 且 mp ≥ step_cost：
    下一格敌控或有敌军 → 建立交战段，停止
    ZOC：已与敌军相邻时，不能直接进入另一个与敌军相邻的格
    进入；mp −= step_cost
日终：按所在格的恶劣环境减员率扣人（计入伤亡）
```

### 7.4 海运（v1 简化）

- 近海运兵需要「渔舟」科技（最多跨 3 个水格），远洋需要「远洋运兵」科技。
- 航行期间为 `EMBARKED` 状态：不交战，不接收补给，组织度每日 −2%。登陆敌方控制格时攻击 ×0.7。

---

## 8. 视野

- 己方部队和驻防格是视野源。部队换格后，当日最多做一次局部增量重算（§21.6）。
- 外国部队、交战标记、敌方车队只在 `FOG_VISIBLE` 格显示；已探索但不可见的格只保留「最后目击」的淡色标记。
- AI 只使用本国控制格及部队周围距离 ≤ 3 格内的敌情。

---

## 9. 自动后勤

### 9.1 原则

没有补给基地。部队、驻防、训练订单需要的物资，都从**最近、有货的本国控制区市场**购买，再按贸易速度运过去。采购逻辑照搬政府采购和国内贸易，玩家不需要任何操作。

### 9.2 补给类别：日常 + 作战附加（每 100 人 / 日）

**补给类别**

| 类别 | 候选物资 | 付款方 |
| --- | --- | --- |
| `ration` 口粮 | 不单独列候选表，直接沿用 `soldier_household` 中主食（staple_food）与蛋白质（protein）两项需求的变体与组件表（见下文「口粮折算」）。当前候选：主食 = prepared_staples, bread, grain, wheat_grain, rice_grain, corn_grain, potatoes, gathered_plants；蛋白质 = game_meat, meat, fish, canned_fish, dairy_products | **国库**。所有士兵（驻防与随军）的主食、蛋白质需求都由口粮实物满足（§5.1） |
| `fodder` 草料 | grain, wheat_grain, corn_grain, gathered_plants | 国库 |
| `ammunition` 弹药 | 弹药类别（火药弹丸 → 制导弹药） | 国库 |
| `fuel` 燃料 | refined_fuel；无人兵种用 batteries | 国库 |
| `upkeep` 装备维护 | 该兵种主装备槽所在类别的物资 | 国库 |

**口粮折算：直接复用士兵消费计划的替代表**

口粮不新建营养表。主食、蛋白质两项需求在 `soldier_household` 里已经有完整的变体（variant）与组件（component）数据：每个变体对应一种物资，`component_qty_per_need` 给出「满足 1 单位需求所需的该物资数量」。口粮直接按这个口径换算：

```text
需求量（需求单位）:
  need_staple(人·日)  = soldier_household.staple_food 的冻结每日人均需求量（含财富弹性、时代口径）
  need_protein(人·日) = soldier_household.protein     的冻结每日人均需求量
  作战当日两者 ×1.25

满足 1 单位需求所需的物资:
  goods_needed(g) = 需求单位 × component_qty_per_need(variant(g))
  例：现行配置中 1 单位主食 = 0.65 bread 或 0.8 grain 或 1.0 gathered_plants；1 单位蛋白质 = 1.0 meat
```

- **库存与消耗**：驻防库存和部队库存按物资实物保存。每日按库存中的物资折算成需求单位后扣减；多种物资同时在库时，按变体表中的 `variant_preference_q16` 从高到低优先消耗，与居民消费选择变体的顺序一致。
- **采购**（§9.3）：
  - 口粮需求以需求单位冻结；
  - 3 格内各市场按需求单位计算「可售余量」，即各候选物资余量 × 折算系数之和；
  - 买入时按「每需求单位价格 = 物资零售价 × component_qty_per_need」从低到高选购，相当于买当地最便宜的营养。
- **满足率**：`口粮满足率 = 实际扣减的需求单位 / 当日需求单位`，主食、蛋白质分别计算，再按两项需求在 `soldier_household` 中的生活成本权重加权。这个值直接写成这两项需求在 cohort / 随军 lane 上的满足度，进入满意度的生存维度。
- **好处**：
  - 口粮自动跟随消费计划的调整：新增主食物资或改替代效率时，只需改消费计划，口粮无需另配；
  - 士兵与普通居民用同一套营养口径，满意度和生存判定一致；
  - 时代演进时，加工食品（面包、罐头、加工食品）因折算系数更低，自然成为更高效的军粮。
- 新建的 `soldier_household` 应完整覆盖 staple_food 与 protein 的变体（与 `industrial_worker_household` 相同），目录编译时校验这两项需求至少各有 1 个组件。

**口粮消耗**：每名士兵每日消耗 `need_staple + need_protein` 个需求单位（作战当日 ×1.25），按上式折算为实物。驻防士兵的口粮从驻地格的驻防库存中扣，随军士兵从部队库存中扣。

**各兵种消耗**

| 兵种组 | 日常 | 作战附加（处于交战段或会战当日） |
| --- | --- | --- |
| 民兵、冷兵器步兵 | 维护 0.05 | 维护 +0.10 |
| 弓箭部队（含弓箭槽的兵种） | 维护 0.05，弓箭 0.02 | 弓箭 +0.3 |
| 骑兵、战车 | 草料 2，维护 0.05 | 草料 +1，维护 +0.15 |
| 火器步兵 | 弹药 0.05，维护 0.03 | 弹药 +0.8 ~ +1.5（随时代递增），维护 +0.1 |
| 炮兵 | 弹药 0.1，维护 0.05 | 弹药 +3 ~ +5，维护 +0.2 |
| 装甲、机械化 | 燃料 1，维护 0.05 | 燃料 +2，弹药 +1.5，维护 +0.2 |
| 无人机 | 电池 1，维护 0.05 | 电池 +1.5，弹药 +0.5 |

最终消耗再乘以地形补给倍率 × `country.military.supply_consumption_factor` × 地块光环（§17）。

### 9.3 就近采购（3 格内本国市场）

> 2026-11-02 决定：不再维护全国「最近市场场」，也不扫描全部市场。

**来源范围**：需求者（驻防、部队、训练订单）只从**所在格 3 格以内（最多 19 格）、本国拥有且控制、有活商人**的市场采购。

- 每个军事日把 digest 中的市场行按格建一次 CSR（格 → 该格可售行），O(市场行)。
- 每个需求按预计算的环偏移（东西环绕）遍历半径 3 的格，O(19 × 每格行数)。
- 选「每需求单位价格」最低的行；单个市场单日最多卖出可售余量的 50%；每个需求最多 4 个市场。
- 3 格内无货时记为未满足需求（写入需求信号，供 UI 与 AI 使用），**不做全局回退扫描**。
- 车队路程 ≤ 3 格；被截判定仍按途经格计算（§9.5）。

<details><summary>旧方案（已废弃）：按类别的多源最近市场场</summary>

**场的计算**：对每个国家、每个补给类别 k，Economy 在 `EPOCH_BEGIN` 跑一次**多源整数 Dijkstra**：

- 图：贸易拓扑（陆邻 + 水运门户），只允许 epoch 冻结的 controller == 该国的格；
- 源：该国控制、有活商人、类别 k 的「可售余量」> 0 的市场，初始距离 0；
- 输出两个数组：`near_market_k[cell]`（最近源的格号）、`near_cost_k[cell]`（路程）；
- 只在国家控制区内展开，复杂度 O(控制格 × log)。每国约 6 个类别（口粮、草料、弹药、燃料、维护、装备）。

可售余量 = 市场库存 − 商人营运底线（复用国内贸易的 12.5%）。单个市场单周期最多卖出余量的 50%。

**采购**：每个需求者按优先级查 `near_market_k[需求者所在格]`，O(1) 得到最近的有货市场：
- 买够就结束；
- 不够时，把该市场在本周期场内标记为「已售罄」，需求者沿 `near_cost` 降序查邻格的源，最多回溯 4 个源；
- 国库库存视为位于首都、价格为 0 的源，参与同一个场。

</details>

**交易**：
- 现金从国库付给当地商人（按商人人口分账）。口粮也由国库付款，士兵的随军资金只用于客籍日常消费；
- 物资进入军需派送，记 sink `military_goods_dispatched`；
- 结算复用 Country↔Economy 资产协调器，新增资产操作 `GOOD_FROM_MARKET_TO_MILITARY`。

**驻防口粮的捷径**：驻防格自身有活商人、且口粮可售余量足够时，直接在本格采购，不生成车队（路程为 0、当日入库）。

**需求信号**：未满足的部分写入需求者所在格（或 3 格内最近的本国市场）的 `epoch_procurement_demand_daily`。效果：
- 前线附近的市场涨价；
- 商人进货、进口目标随之提高；
- 国内贸易把货运向前线；
- 投资评审看到持续缺口后新建军工建筑。

**预算**：国家采购政策新增 `military_share_bp`，与研究、时代收购、派遣储备共享 `national_daily`。

### 9.4 车队

```text
eta = departure + ceil(route_cost(origin → consumer.cell) / (trade_speed × country.military.supply_transport_factor))
```

- 部队移动时，到期日按部队当前所在格重算剩余路程（计入每日寻路预算）。
- 部队与本国控制区断联时，车队原地等待；30 日仍不通，货物退回国库。
- 表现层复用 `TradeActivityLayer` 的载具，用军需色调区分。

### 9.5 车队拦截：取决于沿途敌方战力

**威胁场**：Military 每日为每个交战国维护 `threat_c[cell]`。只累加敌方部队周围距离 ≤ 1 的 7 个格：

```text
threat_c[x] = Σ_{敌军 a, dist(a,x) ≤ 1} strength(a) × (dist == 0 ? 1.0 : 0.6)
```

复杂度 O(部队 × 7)，用 stamp 清零。

**我方护卫场**：同样累加本国部队和驻防。

**每日判定**：车队当日途经的每个格 x：

```text
p_x = clamp(0.5 × T / (T + G + E), 0, 0.5)
  T = threat_c[x]
  G = guard[x]
  E = escort_base(时代) × 车队货值档
p_day = 1 − Π(1 − p_x)
```

- 判定结果由确定性 RNG 决定，种子为 `(shipment_id, day)`。
- 截获后：货物进入截获方国库（守恒转移，Country 新增 transient source），发出事件 `CONVOY_INTERCEPTED`。
- 效果：路线越靠近敌军，每天的风险越高；路线越长，暴露的天数越多。不会出现「线越长越安全」的情况。

### 9.6 军饷

- 政策 `military.policy.set_wage {mode: AUTO|ABSOLUTE, value}`。
  - AUTO：日军饷 = 全国人口加权的 `soldier_household` **非军供需求**人均生活成本 × `country.military.wage_factor`（默认 1.3）。主食与蛋白质已由口粮实物供给，不计入军饷。
  - ABSOLUTE：每人每日固定金额。
- 军饷用于士兵在所在地市场的日常消费和储蓄；士兵的存款不会被用来买口粮。
- 驻防士兵的军饷就是兵营雇员岗工资（`state_payroll`），在该格的 epoch 结算；部队随军 lane 按 `army_handle % 5` 分桶，每 5 日结算一次。
- 资金来自 `prepare_fiscal_budgets` 为每国追加的 `MILITARY_PAYROLL` 托管：国库不足时同比例缩减，未用部分在 `commit_fiscal` 退回。
- 实付率写入 digest。
- 非税支出新增 `military_payroll`、`military_procurement`（含口粮）、`military_upkeep` 三个槽位。
- 玩家可以对 `soldier` 职业设所得税率。

### 9.7 征发与退回

- **征发**：部队在占领格可以无偿取走当地商人的补给类物资，上限为当日需求，且不超过该格库存的 10%（Economy 命令 `MARKET_GOOD_TO_MILITARY`）。
  - 部队与本国控制区断联时自动开启。
  - 代价：该格 30 日消费惩罚；和议时割让该格的价格 +20%。
- **退回**：解散、停战、车队超时退回的货物经 Country `MILITARY_GOODS_TO_TREASURY` 入库。
- **Military 账本**（每日校验，误差必须为 0）：

  ```text
  Σ收到 = 库存 + 在途 + 已消耗 + 被截出 − 截获入 + 已退回
  ```

---

## 10. 士气

```text
morale = 0.30 × 军饷实付率（30 日均值）
       + 0.25 × 口粮满足率（3 日均值）       # 军供需求的实物满足率，驻防与随军相同
       + 0.10 × 日常消费满足度               # 非军供需求在 cohort / lane 上已提交的满足度
       + 0.10 × 储蓄分                       # 人均存款 / 90 日非食品生活成本，封顶 1
       + 0.15 × 驻地民心                     # 所在格居民 composite；占领格取 0.3
       + 0.10 × 全国人口加权满意度
       + country.military.morale_add + 地块光环
```

驻防士兵读自己 cohort 已提交的满意度；随军士兵读 lane 已提交的满意度。口粮满足率由 Military 每日计算，不需要等经济周期。

---

## 11. 战争、交战与会战

### 11.1 状态机

```text
PEACE ─declare→ WAR(D+1)
WAR ─和约→ PEACE + TRUCE(365 日)
WAR ─和约割让了一方的最后一格领土→ 该方被吞并，战争结束（§12.5）
```

- 宣战预检：目标是活跃国家；双方未交战；不在停战期；本国至少有 1 名士兵。
- 被宣战方获得「保家卫国」：30 日内防御 +10%。
- **全境沦陷**：一国所有自有领土的 controller 都不是它自己时，进入「全境沦陷」状态。战争照常继续，不会自动结束或吞并；只是这个国家接受和议的倾向大幅提高（§12.3），并且它仍可以用残余部队尝试夺回领土。

### 11.2 控制权

- 默认 `controller = owner`。部队离开后控制权保留，直到被夺回或和约生效。
- 控制权由 Country 命令 `SET_CELL_CONTROL`（opcode 22）在 D+1 提交，并触发 `country_committed`。

### 11.3 交战段

交战段 = 一条相邻边，键规范化为 `(min, max)`。

- 进攻方：边一侧处于 ADVANCE/ASSAULT 姿态、下一格指向对侧的部队。
- 防守方：对侧格的部队 + 驻防兵 + 地方守备。
- 进度 `p` 初始为 0.5。
- 结束条件：
  - 进攻方的 `p` 到达 1.0 → 夺格；
  - `p` 到达 0.0 且防守方没有进攻姿态 → 击退；
  - 连续 3 日没有进攻方 → 关闭。

### 11.4 日结算

```text
W   = frontage(era) × terrain_width(b) × country.military.frontage_factor
N'  = min(N, W)
F   = F_tech × F_equip × F_supply × F_pay × F_morale × F_org × 光环，clamp [0.05, 4]
T_b = terrain_def(b) × fort(b)^(1 − fort_ignore_a) × river_penalty
S_a = Σ N'_a,u × atk_u × F_a
S_b = Σ N'_b,u × def_u × F_b × T_b + local_def(b)
C_b = Σ N'_b,u × atk_u × F_b × 0.5 × sqrt(T_b)
P_a = Σ N'_a,u × def_u × F_a × 0.5
Δp  = 6% × (S_a − S_b)/(S_a + S_b) × (1 + noise±15%)
L_b = 0.8% × N_b' × S_a/(S_a + S_b) × casualty_factor(B)
L_a = 0.8% × N_a' × C_b/(C_b + P_a) × casualty_factor(A)
组织度：每方 −4% × 对方强度占比
```

- `fort_ignore_a` 只取攻方炮兵类兵种按人数加权后的值。
- 节奏：兵力 2:1 时约 25 日拿下一格。

### 11.5 会战

```text
触发概率 = 1.5% + 4% × intensity；ASSAULT 姿态至少每 5 日一次（组织度 −10%）
r = S_a/(S_a+S_b) + gauss(σ = 0.18)
Δp = ±(12% + 40% × |r − 0.5|)
伤亡：败方 4–8%，胜方 1.5–3%
组织度：败方 −30%，胜方 −10%
战争分：胜方 +(2 + 6 × 规模占比)，单场上限 8
```

### 11.6 夺格、撤退与歼灭

1. 发出 `SET_CELL_CONTROL`。
2. 守方部队和驻防撤到相邻的己方控制格，组织度 −25%。
3. 无路可退时**歼灭**：40% 阵亡；60% 溃散为散兵，组织度为 0，退往最近的本国控制格。歼灭方缴获被歼部队的军需库存。
4. 驻防 cohort 撤退时：先转为一支 RETREAT 部队（`ARMY_EMBARK`），到达后拆编。
5. 进攻方中组织度最高的一支进入该格，其余部队留在原格。
6. 该格的在训订单作废。

### 11.7 地方守备与伤亡落账

```text
local_def(b) = population(b) × 2% × best_infantry_def(controller 时代) × terrain_def × fort × fortification_factor
fort(b)      = 1 + 聚落等级加成（村 0 / 镇 0.3 / 城 0.7 / 首都 1.2）+ 城防加成
```

伤亡当日从登记批次扣除，每个采样日发出 `MILITARY_CASUALTY` 落账到 cohort 或随军 lane。

---

## 12. 占领、战争分、和议与吞并

### 12.1 占领的经济效果

Economy 同时冻结 owner 与 controller。

| 机制 | 依据 | 结果 |
| --- | --- | --- |
| 税收方 | controller | 占领者以其全国默认税率 × `occupation_tax_efficiency`（默认 50%）征收 |
| 补贴 | controller | 停发 |
| 贸易区、政府采购范围、军需采购范围 | controller | 归占领者 |
| 科技门控、建筑所有权、人口 | owner / — | 不变 |
| 兵营、城防 | owner | 不能招兵或训练；城防为当前 controller 提供防守 |
| 战区 | — | 交战两端格产出 ×0.75（N 日 Modifier） |

### 12.2 战争分

```text
score = clamp(battle(±40) + occupation(状态量 ±60，首都 ±15) + annihilation(±25) + attrition(±10), −100, 100)
cell_value = population + 5 × building_count + tier_bonus     # 每个经济 commit 刷新
```

### 12.3 和议：分差越大越容易接受

**条款价格**

| 条款 | 价格（分） | 约束 |
| --- | --- | --- |
| 白和平 | 0 | — |
| 割地（每格） | `max(2, 100 × 格价值 / 败方总价值)`；首都 ×2；被征发格 ×1.2 | 只能割接收方**当前控制**的格 |
| 割让全部剩余领土（吞并） | 等于各格价格之和 | 败方所有剩余领土都由接收方控制（全境沦陷，且唯一占领者是接收方）时才可选。和约生效后败方被吞并（§12.5） |
| 一次性赔款 A | `p(A) = 25 × A / max(败方年财政收入, 1)` | A ≤ 败方国库 |
| **分期赔款**：每期 A，共 n 期（n ∈ 2..12），每 30 日一期，总额 n×A | `p(A) × n × 0.75`（延期支付打折） | A ≤ 败方年财政收入 / 6。某期国库不足时按余额支付并记欠款；累计欠款超过 3×A 时和约破裂，自动恢复战争 |
| 赔物资 | `25 × 数量 × 参考价 / 年财政收入` | ≤ 败方国库该物资 |
| 归还占领 | 负价格 | — |

**接受倾向**（替代投降和疲劳）：

```text
gap            = 发起方战争分 − 接受方战争分     # 范围 [−200, 200]
willing(接受方) = max(0, gap/2) × (1 + 0.5 × clamp((战争天数 − 365)/730, 0, 1))
                 + 强度比加成（接受方总战力 < 发起方 50% 时 +10）
                 + 全境沦陷加成（接受方处于全境沦陷状态时 +60，且每持续 30 日再 +10）
                 − 性格固执度
接受条件：条款总价 ≤ willing
```

- 分差越大，愿意让出的越多。
- 全境沦陷的国家通常会接受吞并条款，但这仍然要由占领方主动提出，并以和约形式生效。
- 面板只显示「接受倾向：高 / 中 / 低」。被拒绝后 30 日内不能对同一方再提。
- 玩家作为接受方时由玩家决定。玩家国全境沦陷时，AI 会提出吞并和约；玩家可以拒绝并继续抵抗，但只要残余部队无法夺回任何领土，AI 每 30 日会再次提出。

### 12.4 和约执行（原子 Country 批次，D+1）

批次依次包含：

1. `TRANSFER_TERRITORY` × k；
2. `TRANSFER_CASH_BETWEEN_COUNTRIES`（opcode 23）；
3. `TRANSFER_GOODS_BETWEEN_COUNTRIES`（opcode 24）× m；
4. 未割让的占领格 `SET_CELL_CONTROL` 归还。

- 任一预检失败，整批拒绝，战争继续。
- 成功后，位于对方领土的部队和割让格的驻防转为 RETREAT 部队返回本国。
- 分期赔款登记为 `ReparationSchedule`（PKMI），每期由 Military 发出 opcode 23。

### 12.5 吞并灭国（只能经由和议）

**触发**：唯一途径是和约中包含「割让全部剩余领土」条款，并被接受。全境沦陷本身不会触发吞并。

**多国占领**：一国全境沦陷、但领土被多个国家分别控制时，任何一个占领方都不能单独吞并它。各占领方只能各自通过普通割地条款拿走自己控制的格。当受害国只剩一格时，控制这一格的国家才可以提出吞并和约。

**执行**：和约生效日（D+1），Country 新命令 `ANNEX_COUNTRY {victim, annexer}` 与和约其他条款在**同一个批次**内完成：

1. 受害国剩余领土全部转给吞并方（`TRANSFER_TERRITORY`）。
2. 受害国国库的现金和物资全部转给吞并方（opcode 23/24）。
3. 受害国 `active = false`，generation +1，领土计数为 0。由于同一批次内国家同时失效，「活跃国家必须有领土」的检查不会拒绝这次提交。
4. 受害国的科技不转移。吞并方获得一次研究信号：对受害国已完成、而吞并方未完成的科技，研究证据 +1。

**连带处理**
- 受害国与其他国家的战争全部结束；与其他占领方之间未签和约的占领格，所有权随吞并转给吞并方，controller 保持原占领方，这些格的归属在吞并方与该占领方之间的战争或和议中解决。
- 受害国的部队解散：随军人口在所在格拆编为当地失业者（资金随人）；军需库存归该格的新 owner 国库。
- 受害国的驻防士兵成为所在格的失业者。
- 受害国的分期赔款债权、债务作废。
- 受害国的 AI 记忆、研究队列、理念状态、Modifier 来源全部 retire。句柄失效，以 generation 防止陈旧引用。

**玩家国被吞并**：玩家接受吞并和约后，进入「国家覆灭」结局界面，可选择读档或旁观（时钟继续，玩家命令关闭）。

**事件**：`COUNTRY_ANNEXED`（§19）。

---

## 13. 战斗力修正汇总

```text
F_tech   = country.military.attack_factor / defense_factor × 兵种精确系数
F_equip  = equip_factor × (0.5 + 0.5 × condition)          # §4.2
F_supply = 0.30 + 0.70 × 补给满足率（3 日均值）
F_pay    = 0.40 + 0.60 × 实付率
F_morale = 0.60 + 0.80 × morale
F_org    = 0.50 + 0.50 × organization
F_aura   = 地块光环 × 部队规则 × 事件叠层                      # §17
F_total  = clamp(Π, 0.05, 4.0)
```

组织度：未交战时每日 `+3% × 补给满足率 × organization_recovery_factor`；低于 20% 时自动脱离交战。

---

## 14. 地图表现与 UI

### 14.1 图层（z 序均低于迷雾层 12）

| 层 | z | 实现 |
| --- | --- | --- |
| `OccupationLayer` | 5 | 复用 DataOverlay 的 cell-index atlas + RG8 per-cell LUT，画占领者国色斜纹。只在控制有变化时上传 |
| `MilitaryAreaLayer` | 6 | 选中部队的军事控制区域：复用 `CountryBorderLayer` 的逐边 ribbon 算法，判定条件为「在区域内 / 不在」，用虚线 shader |
| `FrontLineLayer` | 8 | 增量战线（§21.5），用锯齿 shader，颜色按进度渐变 |
| `BattleMarkerLayer` | 9 | 交战边中点画双色进度环；会战时播放 `play_activity` 特效 |
| 军需车队 | 9 | 复用 `TradeActivityLayer` 的 MultiMesh 和路径纹理 |
| `ArmyTokenLayer` | 10 | GPU 插值棋子（§21.7）：兵种类别图标 + 兵力 + 补给/口粮/军饷/士气警示点 |
| `ArmyRouteLayer` | 11 | 复用 `ColonizationRouteLayer` |

外国部队、交战标记、敌方车队只在可见格显示。

部队编队视觉原型见 `docs/plans/military-formation-visual.md`。它验证“四套动作骨架 + 1–5 可见成员 +
三级 LOD”，当前为独立只读 harness；生产 `ArmyTokenLayer` 在原生快照补齐前三兵种配比与攻击/受击 cue 前
继续使用纸片 token fallback。

### 14.2 地图交互

- **部队卡**：兵力、编成与装备品质、攻防、速度、补给天数（按类别，口粮单列）、在途车队、军饷、士气分解、组织度、统帅空位（灰色「待开放」）、任务。
- **移动**：选中部队后点地图格，显示路径预览，再次点击确认。
- **军事控制**：按住修饰键拖选区域，或点中心格后用滚轮调半径，确认后下达。
- **交战卡**：双方兵力、进度、伤亡、会战记录；可以增援或撤出。
- **Inspector 新增「军事」页签**：兵额、在驻（本地驻防 / 外地部队）、空额、本期配额、征召情况、训练队列、城防、控制者。玩家领土格提供「建造 / 拆除 兵营、城防、军校」按钮。

### 14.3 军事面板（`MilitaryWorkspace`）

- 把 `country_action_bar.gd` 和 `country_panel.gd` 中 military 的 `available` 改为 true。
- 在 SectionHost 下挂 `MilitaryWorkspace`，实现 `set_model`、`refresh_model`（200ms 合并刷新）、`set_compact`、`set_player_controller`。
- 修改 `player_country_ui_smoke_test.gd` 中「military 不可用」的断言。

| 页 | 内容 |
| --- | --- |
| 总览 | 兵力（民兵 / 已训练 / 训练中 / 驻防 / 部队）、目标与差额、军费构成、实付率、士气；一行「进行中的战争 N 场 → 战争详情」指路（不再重复战争卡片） |
| 兵力规划 | 目标模式与滑块（按人数 / 按每日预算，实时显示预估军费）；**兵种编制名册**：只列国家已解锁、现在真的能编成的兵种（科技闸门取 `CountryFacade.snapshot()["technology_ids"]`，与原生 digest 的 per-country unlock bitset 同源），每张卡给中文名、攻/防/速迷你条与原值、军饷（金币/百人日）、供给类别、装备最低品质、成军天数，右端份额与 ±5% 步进；**民兵作为兵种排在名册末尾**，吞下未分配的份额且没有 ±（那一份不能单独加）；份额条只做构成总览；品质策略；自动换装、征召、自动退伍开关；全国兵营列表（兵额、在驻、外地部队、空额、配额、失修），每行可暂停、定位、升级 |
| 训练 | 训练队列（格、从 → 到、人数、品质、等待装备 / 进度）；手动改训 |
| 部队与后勤 | 野战部队索引（部队 / 兵力 / 攻防 / 士气 / 补给 + 每行「定位」「档案」），点击行打开右侧**军务档案**；在途军需车队与被截风险。编成、补给天数、移动 / 军事控制 / 停止 / 解散等单支部队操作都在军务档案面板里，本页不重复 |
| 战争 | 战争分四项拆解（每张战争卡一个「议和」按钮）、战线索引（点行打开**战线档案**，镜头同时落到该扇区）、宣战表。条款编辑、占领格勾选、会战记录都在议和面板 / 军务档案里 |
| 议和窗口 | 独立面板（`MilitaryPeaceWindow`）：条款编辑（割地可在地图上框选；分期赔款设置 A 与 n，显示总额 n×A）、总价、可用分、接受倾向 |

---

## 15. 军需物资与军工产业链

### 15.1 新增物资（33 种，`category_id = &"military"`，可贸易，不进入居民消费计划）

| 类别 | 物资 id（显示名，品质，时代） |
| --- | --- |
| 兵器 | stone_spears（石矛，Q1，石器）、bronze_weapons（青铜兵器，Q2，农耕）、iron_weapons（铁制兵器，Q3，王国）、steel_blades（钢刃，Q4，帝国） |
| 弓箭 | bows（弓箭，石器起） |
| 护具 | hide_armor（皮甲，Q1，农耕）、iron_armor（铁甲，Q2，王国）、plate_armor（板甲，Q3，帝国）、ballistic_armor（防弹护具，Q4，原子） |
| 坐骑与战车 | war_chariots（战车，农耕）；马匹复用现有物资 |
| 火器 | matchlocks（火绳枪，Q1，探索）、flintlocks（燧发枪，Q2，启蒙）、rifles（步枪，Q3，蒸汽）、automatic_rifles（自动步枪，Q4，电气）、smart_rifles（智能单兵武器，Q5，智能） |
| 火炮 | siege_engines（攻城器械，Q1，帝国）、bronze_cannon（铜炮，Q2，探索）、steel_artillery（钢炮，Q3，蒸汽）、howitzers（榴弹炮，Q4，原子）、missile_launchers（导弹发射系统，Q5，信息） |
| 弹药 | powder_shot（火药弹丸，Q1，探索）、cartridges（定装弹药，Q2，蒸汽）、modern_munitions（现代弹药，Q3，原子）、guided_munitions（制导弹药，Q4，信息） |
| 发射药（§15.3） | **black_powder（黑火药，Q1，帝国）**、**smokeless_powder（无烟火药，Q2，蒸汽）**、**modern_propellant（现代发射药，Q3，原子）** |
| 装甲车辆 | early_tanks（早期坦克，Q1，电气）、modern_tanks（现代坦克，Q2，原子） |
| 军工中间品 | **nitric_acid（硝酸，电气）**、armor_plate（装甲钢板，电气）、military_electronics（军用电子设备，原子）、combat_drones（作战无人机，智能） |

### 15.2 私营军工建筑（42 座：本表 32 座 + §15.3 火药链 10 座）

数量为每栋每日的显示单位；技术栏是 `technology_tags`。火药、发射药相关建筑集中列在 §15.3。

| 时代 | id | 名称 | 业主 / 雇员 | 投入 | 产出 | 科技 |
| --- | --- | --- | --- | --- | --- | --- |
| 石器 | `spear_knapper` | 石矛作坊 | artisan / — | flint 2, logs 1 | stone_spears 2 | tech.stone_knapping |
| 石器 | `bowyer_camp` | 弓箭营地 | hunter / — | logs 1.5, raw_hide 0.3 | **bows 1.0** | tech.composite_tools |
| 农耕 | `bronze_armory` | 青铜兵器坊 | artisan / apprentice | copper 1, tin 0.3, charcoal 1 | bronze_weapons 1.5 | tech.bronze_casting |
| 农耕 | `hide_armorer` | 皮甲作坊 | artisan / apprentice | leather 2 | hide_armor 1.5 | tech.hide_tanning |
| 农耕 | `chariot_wright` | 战车作坊 | artisan / apprentice | lumber 3, bronze_tools 0.5, leather 1 | war_chariots 0.2 | tech.military.chariot_warfare |
| 王国 | `armory` | 兵器坊 | artisan / apprentice | wrought_iron 1, charcoal 1, lumber 0.5 | iron_weapons 1.5 | tech.iron_smelting |
| 王国 | `bow_workshop` | 弓弩坊 | artisan / apprentice | lumber 1, leather 0.3, wrought_iron 0.2 | **bows 3.0** | tech.military.standing_army |
| 王国 | `iron_armorer` | 铁甲坊 | artisan / apprentice | wrought_iron 1.5, leather 0.8 | iron_armor 1.0 | tech.military.standing_army |
| 帝国 | `bladesmith` | 坩埚钢刃坊 | guild_master / journeyman | wrought_iron 1.5, charcoal 2 | steel_blades 1.0 | tech.crucible_steel |
| 帝国 | `plate_armorer` | 板甲坊 | guild_master / journeyman | wrought_iron 2.5, charcoal 2 | plate_armor 0.8 | tech.crucible_steel |
| 帝国 | `arsenal_workshop` | 军械工场 | guild_master / journeyman, apprentice | lumber 1, wrought_iron 0.3, leather 0.3 | **bows 6.0** | tech.military.legion_logistics |
| 帝国 | `siege_workshop` | 攻城器械坊 | guild_master / journeyman | lumber 6, wrought_iron 1, flax_fiber 1 | siege_engines 0.5 | tech.military.siegecraft |
| 探索 | `gunsmithy` | 火枪坊 | guild_master / journeyman, apprentice | wrought_iron 1.5, lumber 0.5, tools 0.2 | matchlocks 0.6 | tech.gunpowder_weapons |
| 探索 | `shot_foundry` | 弹丸作坊 | guild_master / journeyman | 发射药≥Q1 1, wrought_iron 0.4, paper 0.1 | powder_shot 2 | tech.gunpowder_weapons |
| 探索 | `cannon_foundry` | 铸炮厂 | guild_master / journeyman | copper 3, tin 0.5, charcoal 3 | bronze_cannon 0.15 | tech.military.field_artillery |
| 启蒙 | `flintlock_works` | 燧发枪工场 | guild_master / journeyman, apprentice | wrought_iron 1.5, lumber 0.5, precision_tools 0.1 | flintlocks 1.0 | tech.military.drill_regulations |
| 蒸汽 | `rifle_works` | 步枪厂 | industrialist / industrial_worker, machinist, manager | steel 3, tools 0.5, lumber 0.5 | rifles 2 | tech.military.rifled_weapons |
| 蒸汽 | `cartridge_works` | 子弹厂 | industrialist / industrial_worker, chemist, manager | 发射药≥Q1 0.8, copper 0.6, industrial_chemicals 0.3 | cartridges 10 | tech.military.rifled_weapons |
| 蒸汽 | `steel_ordnance_works` | 钢炮厂 | industrialist / industrial_worker, metallurgist, manager | steel 6, coke 3, tools 1 | steel_artillery 1 | tech.military.rifled_weapons |
| 电气 | `automatic_arms_works` | 自动武器厂 | industrialist / industrial_worker, machinist, manager | steel 3, machine_parts 0.5 | automatic_rifles 2 | tech.military.machine_guns |
| 电气 | `armor_plate_mill` | 装甲钢板厂 | industrialist / industrial_worker, metallurgist, manager | steel 4, coke 2 | armor_plate 2 | tech.military.armored_warfare |
| 电气 | `tank_works` | 坦克厂 | industrialist / industrial_worker, machinist, engineer, manager | armor_plate 6, machine_parts 3, electric_motor 0.5 | early_tanks 0.25 | tech.military.armored_warfare |
| 原子 | `munitions_plant` | 现代弹药厂 | industrialist / industrial_worker, chemist, technician, manager | 发射药≥Q2 1, explosives 2, copper 1, steel 1 | modern_munitions 12 | tech.military.mechanization |
| 原子 | `howitzer_works` | 榴弹炮厂 | industrialist / industrial_worker, machinist, engineer, manager | steel 6, machine_parts 2, electronic_components 0.5 | howitzers 1 | tech.military.mechanization |
| 原子 | `body_armor_works` | 防弹护具厂 | industrialist / industrial_worker, chemist, manager | synthetic_fiber 2, plastics 1 | ballistic_armor 2 | tech.synthetic_fiber_engineering |
| 原子 | `defense_electronics_plant` | 军用电子厂 | industrialist / industrial_worker, technician, engineer, manager | electronic_components 2, radio_equipment 1, plastics 1 | military_electronics 0.4 | tech.military.main_battle_tanks |
| 原子 | `mbt_works` | 主战坦克厂 | industrialist / industrial_worker, machinist, engineer, manager | armor_plate 8, machine_parts 3, military_electronics 0.5 | modern_tanks 0.25 | tech.military.main_battle_tanks |
| 信息 | `guided_munitions_plant` | 制导弹药厂 | industrialist / industrial_worker, technician, engineer, manager | 发射药≥Q3 1, explosives 3, electronic_components 2, computers 0.2 | guided_munitions 1 | tech.military.precision_guidance |
| 信息 | `missile_systems_plant` | 导弹系统厂 | industrialist / technician, engineer, manager | military_electronics 2, steel 4, petrochemicals 1 | missile_launchers 0.3 | tech.military.precision_guidance |
| 智能 | `smart_arms_plant` | 智能单兵武器厂 | industrialist / technician, engineer, manager | steel 2, advanced_chips 0.1, batteries 0.5 | smart_rifles 1 | tech.military.autonomous_warfare |
| 智能 | `drone_factory` | 无人机工厂 | industrialist / technician, engineer, researcher, manager | autonomous_systems 0.5, batteries 1, advanced_chips 0.2 | combat_drones 0.3 | tech.military.autonomous_warfare |

- 「弓箭」由三代建筑生产，人均效率从 1.0 提高到 3.0、再到 6.0，正对应「不同时代用不同效率生产同一种物资」。
- 每种新物资的 `technology_tags` 必须精确等于其全部生产建筑的直接科技集合（现有规则）。新建筑都要在 `technology_network.json` 中有对应的 `app.*` 应用或直接解锁。
- 产业链 id：`military.melee_arms`、`military.missile_arms`、`military.body_armor`、`military.firearms`（升级家族 `small_arms_making`）、`military.ordnance`、`military.ammunition`（升级家族 `ammunition_making`）、`military.propellant`（§15.3）、`military.vehicles`、`military.electronics`。
- 投入中写作「发射药≥Qn」的，是按 §15.3 的发射药类别填充：可以用不低于 Qn 的任意发射药，品质越高投入效率越高。
- 全部军工建筑的 `semantic_tags` 都包含 `industry.military`，供家族投资偏好和理念卡选择。

### 15.3 火药与发射药体系

**结论**
- 不把「炸药」改名。现有「炸药」(`explosives`) 已经是蒸汽到智能时代 8 座矿山的投入品，继续作为工业爆破材料与弹头装药。
- 新增**发射药**类别（`propellant`），三种物资按品质递进，每个时代都有更先进的生产方式：

| 品质 | 物资 | 时代 | 主要原料 | 说明 |
| --- | --- | --- | --- | --- |
| Q1 | 黑火药 `black_powder` | 帝国 | 硝石、硫磺、木炭 | 最早的火药。到蒸汽时代仍用于采矿和低端弹药，但生产方式逐代升级 |
| Q2 | 无烟火药 `smokeless_powder` | 蒸汽 | 棉纤维、工业化学品（硝化） | 枪炮发射药的主力，从蒸汽时代起替代黑火药 |
| Q3 | 现代发射药 `modern_propellant` | 原子 | 石化产品、硝酸 | 现代枪炮与导弹的发射药 |

另新增中间品**硝酸** `nitric_acid`（电气时代，由合成工艺生产），让电气时代以后的无烟火药和现代发射药不再受限于硝石矿藏。

**用发射药作投入的建筑**按「类别 + 最低品质」填充，可用更高品质替代，效率随品质提高：

| 投入物资 | 投入效率（相对黑火药） |
| --- | --- |
| 黑火药 | ×1.0 |
| 无烟火药 | ×2.0 |
| 现代发射药 | ×2.6 |

例如子弹厂（最低 Q1）用黑火药也能开工，但同样产量要消耗 2 倍的量；换成无烟火药后成本明显下降。这样新式火药在军工上有清楚的经济价值，同时不会让旧建筑突然停产。

**产业链**

```text
                  ┌ 硝石矿（现有，需硝石矿藏）
硝石 ─────────────┤
                  └ 硝田（探索，用畜产品发酵制硝，无需矿藏）
硫磺（现有硫矿）
木炭（现有木炭窑）
   └─→ 黑火药：火药坊(帝国) → 火药局(探索) → 水力火药厂(启蒙) → 蒸汽火药厂(蒸汽)
                └→ 炸药厂（现有，改为以黑火药为原料）→ 炸药 → 矿山
棉纤维 + 工业化学品 ─→ 无烟火药：无烟火药厂(蒸汽) → 连续硝化火药厂(电气，改用硝酸)
天然气/煤 + 电力 ─→ 硝酸：合成硝酸厂(电气)
石化产品 + 硝酸 ─→ 现代发射药：现代发射药厂(原子) → 数控发射药厂(信息) → 智能发射药厂(智能)
发射药 ─→ 弹丸作坊 / 子弹厂 / 现代弹药厂 / 制导弹药厂
```

**火药链建筑（10 座）**

| 时代 | id | 名称 | 升级家族 | 业主 / 雇员 | 投入（每日） | 产出 | 科技 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 帝国 | `powder_mill` | 火药坊 | `black_powder_making` 1 档 | guild_master / journeyman | saltpeter 2, sulfur 1, charcoal 1 | black_powder 3 | tech.gunpowder_formulation |
| 探索 | `powder_works` | 火药局 | `black_powder_making` 2 档 | guild_master / journeyman, apprentice | saltpeter 2, sulfur 1, charcoal 1, tools 0.1 | black_powder 4.2 | tech.military.corned_powder |
| 启蒙 | `water_powder_mill` | 水力火药厂 | `black_powder_making` 3 档 | guild_master / journeyman, apprentice | saltpeter 2, sulfur 1, charcoal 1, tools 0.2 | black_powder 6 | tech.military.powder_milling |
| 蒸汽 | `steam_powder_works` | 蒸汽火药厂 | `black_powder_making` 4 档 | industrialist / industrial_worker, chemist, manager | saltpeter 2, sulfur 1, charcoal 1, coal 0.5, machine_parts 0.05 | black_powder 9 | tech.military.powder_milling + tech.steam_power |
| 探索 | `nitre_beds` | 硝田 | — | pastoralist / worker | livestock_products 1.5, raw_stone 0.5 | saltpeter 1.2 | tech.military.nitre_beds |
| 电气 | `nitric_acid_plant` | 合成硝酸厂 | — | industrialist / industrial_worker, chemist, technician, manager | natural_gas 2, electricity 3（或 coal 3 替代 natural_gas，效率 0.7） | nitric_acid 4 | tech.synthetic_fertilizer |
| 蒸汽 | `smokeless_powder_works` | 无烟火药厂 | `smokeless_powder_making` 1 档 | industrialist / industrial_worker, chemist, manager | cotton_fiber 1, industrial_chemicals 1.5 | smokeless_powder 3 | tech.military.smokeless_powder |
| 电气 | `continuous_nitration_works` | 连续硝化火药厂 | `smokeless_powder_making` 2 档 | industrialist / industrial_worker, chemist, technician, manager | cotton_fiber 1, nitric_acid 1, electricity 1 | smokeless_powder 6 | tech.military.continuous_nitration |
| 原子 | `propellant_plant` | 现代发射药厂 | `propellant_making` 1 档 | industrialist / industrial_worker, chemist, technician, manager | petrochemicals 1, nitric_acid 1.5, industrial_chemicals 0.5 | modern_propellant 4 | tech.military.modern_propellants |
| 信息 | `method_propellant_plant_r9` | 数控发射药厂 | `propellant_making` 2 档 | industrialist / technician, chemist, engineer, manager | petrochemicals 1, nitric_acid 1.5, computers 0.05, electricity 1 | modern_propellant 7 | tech.digital_control |
| 智能 | `method_propellant_plant_r10` | 智能发射药厂 | `propellant_making` 3 档 | industrialist / technician, engineer, manager | petrochemicals 1, nitric_acid 1.5, autonomous_systems 0.05, electricity 1 | modern_propellant 10 | tech.robotic_manufacturing |

**现有内容的改动**
- `explosives_plant`（炸药厂，探索）：投入从 `saltpeter, sulfur, tools` 改为 `发射药≥Q1 2, tools`。
- `method_explosives_plant_r8/_r10`（现代、自动化炸药厂）：投入中的 `saltpeter` 改为 `nitric_acid`，保留 `sulfur`。这样后期炸药也走合成硝酸，不再受硝石矿藏限制。
- 现有硝石矿三档（`saltpeter_collector` / `_r8` / `_r10`）保留，继续是黑火药的原料来源，也供硝田之外没有合成条件的国家使用。
- 每种新物资的 `technology_tags` 必须精确等于其全部生产建筑的直接科技集合：
  - 黑火药 = `tech.gunpowder_formulation`、`tech.military.corned_powder`、`tech.military.powder_milling`、`tech.steam_power`；
  - 无烟火药 = `tech.military.smokeless_powder`、`tech.military.continuous_nitration`；
  - 现代发射药 = `tech.military.modern_propellants`、`tech.digital_control`、`tech.robotic_manufacturing`；
  - 硝酸 = `tech.synthetic_fertilizer`。
  - 硝石新增生产者硝田，所以硝石的标签要追加 `tech.military.nitre_beds`。

**火药科技（6 项，详见 §16.2）**

| 时代 | 节点 | 名称 | 前置 | 解锁 |
| --- | --- | --- | --- | --- |
| 探索 | `tech.military.corned_powder` | 粒状火药 | gunpowder_formulation, water_power | 火药局 |
| 探索 | `tech.military.nitre_beds` | 硝田制硝 | gunpowder_formulation, fermentation | 硝田 |
| 启蒙 | `tech.military.powder_milling` | 机械制药 | corned_powder（军事分支）, standardization | 水力火药厂；与蒸汽动力共同解锁蒸汽火药厂 |
| 蒸汽 | `tech.military.smokeless_powder` | 无烟火药 | industrial_chemistry | 无烟火药厂 |
| 电气 | `tech.military.continuous_nitration` | 连续硝化 | smokeless_powder（军事分支）, electrochemistry | 连续硝化火药厂 |
| 原子 | `tech.military.modern_propellants` | 现代发射药 | petrochemical_industry, synthetic_materials | 现代发射药厂 |

---

## 16. 军事科技

### 16.1 新增 Modifier stat

**Country 域**（追加到 `TECHNOLOGY_STATS` 末尾）：

- 攻防：`attack_factor`、`defense_factor`，以及按兵种的精确系数 `unit.<id>.attack/defense_factor`；
- 移动与后勤：`speed_factor`、`logistics_move_factor`、`supply_transport_factor`、`supply_consumption_factor`；
- 兵员：`barracks_capacity_factor`、`levy_rate`、`wage_factor`、`training_time_factor`、`desertion_factor`；
- 战斗：`casualty_factor`、`attrition_factor`、`organization_recovery_factor`、`morale_add`、`fortification_factor`、`frontage_factor`、`militia_factor`；
- 其他：`occupation_tax_efficiency`、`naval_transport_factor`、`vision_add`、`convoy_escort_factor`；
- 部队规则参数：`rule.<name>`（§17.2）。

以上均以 `country.military.` 为前缀。范围与 v1.1 相同；新增项为 `militia_factor` [0.5, 4]、`convoy_escort_factor` [0.25, 8]、`rule.*` [0, 4]。

**Economy 域地块层**（DerivedCellFront，`group_handle = cell`）：

- `military.cell.attack_factor`、`military.cell.defense_factor`
- `military.cell.organization_recovery_factor`
- `military.cell.supply_consumption_factor`
- `military.cell.barracks_capacity_factor`
- `military.cell.training_speed_factor`

### 16.2 节点（`branch.military_affairs`，分布在现有四个领域）

| 时代 | 节点 | 名称 | 领域 | 硬前置 | 效果与解锁 |
| --- | --- | --- | --- | --- | --- |
| 石器 | `tech.military.war_bands` | 战团组织 | society | communal_specialization | 兵额 +25%；民兵攻防 +20% |
| 石器 | `tech.military.ambush_tactics` | 伏击战术 | science | animal_tracking | 本国部队在森林、沼泽格防御 +15% |
| 农耕 | `tech.military.chariot_warfare` | 战车战法 | engineering | horse_domestication, animal_traction | 战车兵、战车作坊、战车 |
| 农耕 | `tech.military.earthen_ramparts` | 夯土城垣 | engineering | permanent_settlements, earth_building | 木栅兵营、夯土城垣 |
| 王国 | `tech.military.standing_army` | 常备军 | society | state_bureaucracy | 铁甲步兵、戍卫营、武学馆、弓弩坊、铁甲坊 |
| 王国 | `tech.military.mounted_warfare` | 骑兵战术 | agriculture | horse_domestication, pastoralism | 骑兵 |
| 王国 | `tech.military.military_roads` | 军道 | engineering | road_engineering | 本土行军 +25%、车队 +15%、浮桥 |
| 帝国 | `tech.military.legion_logistics` | 军需体系 | society | regional_granaries | 军团步兵、军团营寨、军械工场；补给消耗 −15% |
| 帝国 | `tech.military.heavy_cavalry` | 重骑兵 | engineering | crucible_steel | 甲骑具装 |
| 帝国 | `tech.military.siegecraft` | 攻城术 | engineering | masonry, blast_furnace | 攻城营、攻城器械坊、城堡要塞 |
| 探索 | `tech.military.field_artillery` | 野战火炮 | engineering | gunpowder_weapons | 野战炮兵、铸炮厂 |
| 探索 | `tech.military.star_forts` | 棱堡 | engineering | gunpowder_weapons, masonry | 棱堡 |
| 探索 | `tech.military.naval_transport` | 远洋运兵 | science | oceanic_navigation | 远洋运兵 |
| 探索 | `tech.military.corned_powder` | 粒状火药 | engineering | gunpowder_formulation, water_power | 火药局（黑火药 2 档） |
| 探索 | `tech.military.nitre_beds` | 硝田制硝 | agriculture | gunpowder_formulation, fermentation | 硝田 |
| 启蒙 | `tech.military.powder_milling` | 机械制药 | engineering | tech.military.corned_powder, standardization | 水力火药厂（黑火药 3 档）；与「蒸汽动力」共同解锁蒸汽火药厂（4 档） |
| 启蒙 | `tech.military.drill_regulations` | 操典 | society | standardization | 线列步兵、龙骑兵、操练营、军事学院、燧发枪工场 |
| 启蒙 | `tech.military.military_cartography` | 军事测绘 | science | cartography, property_cadastre | 视野 +10；恶劣环境减员 −30% |
| 启蒙 | `tech.military.military_medicine` | 军医制度 | science | public_health | 伤亡 −15% |
| 蒸汽 | `tech.military.rifled_weapons` | 线膛枪炮 | engineering | interchangeable_parts, machine_tools | 步枪兵、重炮兵、步枪厂、子弹厂、钢炮厂 |
| 蒸汽 | `tech.military.rail_mobilization` | 铁路动员 | engineering | rail_logistics | 车队 ×2，本土行军 +50% |
| 蒸汽 | `tech.military.general_staff` | 总参谋部 | society | managerial_hierarchy | 兵站；战斗宽度 +25% |
| 蒸汽 | `tech.military.smokeless_powder` | 无烟火药 | science | industrial_chemistry | 无烟火药厂、无烟火药 |
| 电气 | `tech.military.machine_guns` | 机枪 | engineering | mass_production | 机枪步兵、自动武器厂、碉堡防线 |
| 电气 | `tech.military.armored_warfare` | 装甲战 | engineering | internal_combustion | 早期装甲、装甲钢板厂、坦克厂 |
| 电气 | `tech.military.radio_command` | 无线电指挥 | science | radio | 攻击 +10%；车队护卫 +25% |
| 电气 | `tech.military.continuous_nitration` | 连续硝化 | engineering | tech.military.smokeless_powder, electrochemistry | 连续硝化火药厂（无烟火药 2 档） |
| 原子 | `tech.military.mechanization` | 机械化 | engineering | global_logistics | 机械化步兵、自行火炮、军事基地、现代弹药厂、榴弹炮厂 |
| 原子 | `tech.military.main_battle_tanks` | 主战坦克 | engineering | advanced_metallurgy, electronic_control | 坦克部队、军用电子厂、主战坦克厂 |
| 原子 | `tech.military.combat_medicine` | 战地医疗体系 | science | public_health_systems | 伤亡 −15% |
| 原子 | `tech.military.modern_propellants` | 现代发射药 | science | petrochemical_industry, synthetic_materials | 现代发射药厂、现代发射药 |
| 信息 | `tech.military.network_centric` | 网络中心战 | science | networked_computing | 合成部队、联合训练中心、兵棋推演中心 |
| 信息 | `tech.military.precision_guidance` | 精确制导 | engineering | digital_control, satellite_observation | 导弹炮兵、制导弹药厂、导弹系统厂 |
| 智能 | `tech.military.autonomous_warfare` | 自主作战 | engineering | autonomous_systems | 外骨骼步兵、无人作战集群、智能单兵武器厂、无人机工厂 |
| 智能 | `tech.military.ai_defense_grid` | 智能防御网 | science | machine_learning, sensor_networks | 加固防御网；防御 +10% |

现有节点追加的内容消费者：

| 节点 | 新增消费者 |
| --- | --- |
| `tech.stone_knapping` | 石矛作坊 |
| `tech.composite_tools` | 弓箭营地 |
| `tech.bronze_casting` | 青铜矛兵、青铜兵器坊 |
| `tech.hide_tanning` | 皮甲作坊 |
| `tech.iron_smelting` | 兵器坊 |
| `tech.crucible_steel` | 坩埚钢刃坊、板甲坊 |
| `tech.gunpowder_formulation` | 火药坊、黑火药 |
| `tech.steam_power` | 蒸汽火药厂（与机械制药共同解锁） |
| `tech.synthetic_fertilizer` | 合成硝酸厂、硝酸 |
| `tech.digital_control` | 数控发射药厂（现代发射药 2 档） |
| `tech.robotic_manufacturing` | 智能发射药厂（现代发射药 3 档） |
| `tech.gunpowder_weapons` | 火枪兵、火枪坊、弹丸作坊 |
| `tech.masonry` | 石砌城墙 |
| `tech.synthetic_fiber_engineering` | 防弹护具厂 |

校验器需要识别新的内容消费者类型 `unit_unlock` 与 `state_building_unlock`，并把军事 stat 归入 `military` 类。

---

## 17. 军事理念：深度联动与构筑

### 17.1 三条联动通道

| 通道 | 适合的效果 | 实现 | 刷新 |
| --- | --- | --- | --- |
| **A 地块光环（慢变量）** | 「有兵营 / 城防 / 城镇的格及其周围 N 格」「边境格」「有家族的格」 | 复用现有托管效果程序（选择器 12/13/16，`TAG_SOURCE_COUNT` 的半径与 per_source）写 `military.cell.*` 派生地块层，Military 每日读取部队所在格的值 | 随经济 commit 刷新，与现有地块理念一致 |
| **B 部队规则（快变量）** | 「周围 2 格内每有一支友军」「被包围的部队」「交战开始后 5 日内」「处于防守中的部队」 | 卡牌只写 Country 域参数 stat `country.military.rule.<name>`，规则内核在 Military 内**原生、每日**计算，使用格 → 部队索引 | 每日 |
| **C 会战事件叠层** | 「每赢 / 输一场会战」「每占领 / 失去一格」「每歼灭一支部队」 | 现有 X4 叠层框架，新增事件种类与国家级目标 `EVENT_COUNTRY` | 事件驱动 |

通道 B 的规则是**封闭集合**，每条规则是一个固定的整数内核，没有脚本求值：

| 规则 | 计算 |
| --- | --- |
| `mutual_support` | 部队周围距离 2 内的其他本国部队数（上限 3）× 参数 → 防御 |
| `last_stand` | 部队与本国控制区不连通（复用补给连通标签）时 × 参数 → 攻防；同时不因低组织度自动脱离 |
| `blitz` | 部队速度 ≥ 2、交战段开始不足 5 日时 × 参数 → 攻击 |
| `hold_the_line` | 部队姿态为 HOLD、且所在格被攻击时 × 参数 → 防御 |
| `encirclement` | 被攻击的敌方部队所在格的 6 个邻格中，本国控制或有本国部队的格 ≥ 4 时 × 参数 → 攻击 |
| `home_ground` | 部队位于本国**自有**领土时 × 参数 → 攻防 |

**新增 tag / metric / 事件**

| 类型 | 内容 |
| --- | --- |
| tag | `cell.barracks`、`cell.fortified`、`cell.military_industry`（有 `industry.military` 建筑）、`cell.occupied_by_us`、`cell.occupied_by_enemy` |
| metric | `country.at_war`（0/1）、`country.soldier_share_q16`（士兵占人口比例）、`cell.garrison_soldiers` |
| X4 事件种类 | `BATTLE_WON`、`BATTLE_LOST`（事件格 = 会战格）、`CELL_CAPTURED`、`CELL_LOST`、`ARMY_DESTROYED`（歼灭敌部队）、`WAR_DECLARED`（国家级） |

### 17.2 卡牌

数值为初识级；通晓 ×1.6，化育 ×2.2（现有规则）。

| key | 名称 | 流派 | 稀有 | 时代 | 互斥组 | 通道 | 效果 | 代价 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `militia_tradition` | 兵民一体 | 动员 | 寻常 | 石器 | — | 国家 | 民兵攻防 +30%；征召不再降低士气 | 全国制造业产出 −2% |
| `levy_system` | 府兵制 | 动员 | 寻常 | 农耕 | military_order | 国家 | 兵额 +20%，军饷 −15% | 单格征召上限 +1%；士气 −0.05 |
| `volunteer_army` | 募兵制 | 商贸 | 珍稀 | 王国 | military_order | 国家 | 兵营岗位在就业比较中视为额外 +20% 收入；训练时间 −20% | 军饷 +20% |
| `professional_army` | 职业常备军 | 动员 | 传世 | 启蒙 | military_order | 国家 | 攻防 +10%，组织度恢复 +25% | 兵额 −20%，军饷 +25% |
| `mutual_support` | 犄角之势 | 动员 | 寻常 | 王国 | — | B | 周围 2 格内每有 1 支其他本国部队（最多 3 支），防御 +3% | 补给消耗 +5% |
| `fortress_city` | 坚城 | 调和 | 珍稀 | 王国 | — | A | 城镇及以上聚落格的本国部队防御 +8%，距离 1 内的邻格 +4% | 建设成本 +2% |
| `wrath_of_the_fallen` | 哀兵必胜 | 动员 | 珍稀 | 帝国 | — | C | 每输掉一场会战，全国部队攻击 +4%，持续 60 日，最多 5 层 | 会战胜利获得的战争分 −10% |
| `pursuit` | 乘胜追击 | 动员 | 寻常 | 农耕 | — | C | 每赢得一场会战，全国部队速度 +5%、攻击 +2%，持续 20 日，最多 3 层 | 组织度恢复 −5% |
| `war_feeds_war` | 以战养战 | 商贸 | 珍稀 | 帝国 | — | C | 每占领一格，占领税效率 +3%，持续 90 日，最多 10 层；征发上限 10% → 15% | 被征发格的消费惩罚加倍 |
| `merit_ranks` | 军功爵制 | 动员 | 珍稀 | 王国 | — | C | 每赢得一场会战，士兵职业满意度 +2%（`economy.profession.soldier.satisfaction_bp`），持续 90 日，最多 5 层 | 军饷 +5% |
| `military_farms` | 屯田 | 农本 | 寻常 | 王国 | — | A | 有兵营的格及距离 1 内邻格农业产出 +3%；这些格的驻防补给消耗 −10% | 这些格的制造业产出 −2% |
| `border_garrison`（扩写现有「戍边」） | 戍边 | 动员 | 寻常 | 王国 | — | A | 保留原效果；新增：边境格兵营兵额 +20%，驻防防御 +10% | 保留原代价 |
| `arsenal_city` | 武库 | 工造 | 寻常 | 王国 | — | A | 军工建筑产出 +4%；有军工建筑的格及距离 1 内邻格兵营兵额 +10% | 全国消费需求 +1% |
| `last_stand` | 背水一战 | 动员 | 传世 | 帝国 | — | B | 被包围的部队攻防 +25%，且不会因组织度过低自动脱离交战 | 部队撤退时组织度额外 −15% |
| `hold_the_line` | 寸土不让 | 调和 | 寻常 | 探索 | — | B | 处于 HOLD 姿态、正被攻击的部队防御 +10% | 处于 ADVANCE 姿态的部队速度 −5% |
| `encirclement_doctrine` | 合围 | 学识 | 珍稀 | 启蒙 | — | B | 攻击 6 个邻格中至少 4 格由我方控制或有我方部队的敌军时，攻击 +15% | 战斗宽度 −10% |
| `blitzkrieg` | 闪击 | 工造 | 传世 | 电气 | — | B | 速度 ≥ 2 的部队在交战开始后 5 日内攻击 +20% | 燃料消耗 +15% |
| `scorched_earth` | 焦土 | 调和 | 珍稀 | 探索 | — | C | 每失去一格，敌方在该格的征发与税收归零 60 日 | 该格的全部产量 −20%，持续 60 日 |
| `total_war` | 总体战 | 工造 | 传世 | 电气 | — | 国家 + metric | 战时：军工建筑产出 +15%，兵额 +25% | 战时：家庭消费 −5%，出生 −3% |
| `deterrence` | 威慑 | 学识 | 传世 | 原子 | — | 国家 | 防御 +8%；外国 AI 对本国的宣战评分 −30% | 军饷 +10% |

### 17.3 羁绊与共鸣

| 羁绊 | 组成 | 效果 |
| --- | --- | --- |
| **屯戍一体** | 屯田 + 戍边 | 边境且有兵营的格：驻防补给消耗再 −20%，出生 +3% |
| **兵工复合体** | 武库 + 总体战 | 战时军工建筑投资需求 ×1.5；和平时军工产出 +5% |
| **置之死地** | 哀兵必胜 + 背水一战 | 被包围的部队每输掉一场会战获得 2 层「哀兵」；层数上限 +3 |

动员流派共鸣：2 档追加「士气 +0.03」，4 档追加「兵额 +10%」。

### 17.4 构筑示例

| 构筑 | 组合 | 玩法 |
| --- | --- | --- |
| 「堡垒网」 | 坚城 + 屯田 + 戍边 + 寸土不让 | 在边境城镇集中建兵营和城防，防守强、后勤省 |
| 「运动战」 | 乘胜追击 + 闪击 + 合围 | 机动兵种快速穿插，赢得会战后越打越快 |
| 「以战养战」 | 以战养战 + 军功爵制 + 募兵制 | 进攻带来税收，胜利提升士气，降低军饷压力 |
| 「绝境」 | 哀兵必胜 + 背水一战（置之死地）+ 焦土 | 劣势翻盘的高风险构筑 |

---

## 18. 家族军事内容

完整表格见 [military-family-content.md](./military-family-content.md)。按 `project-keynes-family-content-design` 的五表格式编写，编号接续现有目录：

- 偏好：C039–C040、I039–I043、J023–J025；
- 效果：E049–E062（携带 E049–E056，独立 E057–E062）。

已通过校验器：errors = 0。剩余 4 条警告是「编号不从 001 开始」，属于扩展表的预期情况。

| 内容 | 挂接 |
| --- | --- |
| 就业偏好「将门子弟」「避役」、独立效果「将门」 | 兵营岗位是普通雇员岗（§5.4），直接走现有职业偏好 |
| 投资偏好（军械世家、硝火商帮、铸炮门第、军需承办、战争财阀） | 私营军工建筑的 `industry.military` 语义标签 |
| 携带效果（乡勇守土、军户之乡、箪食壶浆、坚壁清野、军械世作、战后复兴、驿路护粮、乡里练兵） | 新 metric、`military.cell.*` 地块层、威胁场、军事事件 |
| 独立效果「将门锐士」「家风严整」「坚守不退」「军功赏银」 | 以「部队中有该家族成员随军」为条件（随军 lane 的家族归属子账，§5.7），不依赖统帅。「军功赏银」是国库到随军家族成员的守恒现金转移，余额不足时按余额转移 |
| 独立效果「战争红利」 | 战时家族自有军工建筑产出加成 |

> 注：家族运行时现已支持按威望Ⅰ–Ⅴ逐档精确编译数值、门槛与持续时间（见 `tools/generate_family_official_buffs.py` 与 `family_official_buffs.json`），军事家族效果应同样按逐档精确值配置。

---

## 19. 对接现有事件系统

### 19.1 新增 GameplayEvent

现有类型号 1–17 已占用（另外 Economy 内部的 16 与 Trigger 的 16 有冲突）。军事使用 **40–49**，payload schema 使用 **20–25**，均在 `gameplay_event_bus.gd`、`trigger_catalog.gd` 和 C++ 头文件中登记。

| 类型 | 号 | payload | 主要字段（i0..i3 / value） | 频率上限 |
| --- | --- | --- | --- | --- |
| `MILITARY_WAR_DECLARED` | 40 | `WAR_V1`(20) | 攻方 slot、守方 slot、war_id | 每场一次 |
| `MILITARY_WAR_ENDED` | 41 | `WAR_V1` | 胜方、结果（和约 / 吞并 / 破裂）、割地数；value = 赔款总额 | 每场一次 |
| `MILITARY_BATTLE_RESOLVED` | 42 | `BATTLE_V1`(21) | 胜方、负方、格、规模档；value = 敌方伤亡；flags 保留（v1 恒为 0，留给统帅） | 每日 ≤ 64 |
| `MILITARY_CELL_CONTROL_CHANGED` | 43 | `CONTROL_V1`(22) | 新 controller、旧 controller、owner、聚落等级 | 每日 ≤ 128 |
| `MILITARY_ARMY_DESTROYED` | 44 | `BATTLE_V1` | 歼灭方、被歼方、格；value = 人数 | — |
| `MILITARY_COUNTRY_ANNEXED` | 45 | `ANNEX_V1`(23) | 受害国、主要吞并方、格数 | — |
| `MILITARY_CONVOY_INTERCEPTED` | 46 | `CONVOY_V1`(24) | 截获方、被截方、格；value = 货值 | 每日 ≤ 32 |
| `MILITARY_LEVY_APPLIED` | 47 | `LEVY_V1`(25) | 国家、格；value = 人数 | 每 epoch 每格 1 次 |

- 发布点是 Military 日阶段的 commit 尾部，进入 GameplayEventBus 的 journal。
- worker 路径下沿用 Economy 事件的 `APPEND_BATCH` 打包方式，经 `forward_committed_events_to_trigger` 转发给 Trigger。
- 超过频率上限时合并为汇总事件，计数器 `military_event_coalesced`。

### 19.2 消费方

| 消费方 | 接入 |
| --- | --- |
| Trigger | 新 `EventSelector` 支持 40–47；现有聚合器（COUNT / WINDOW_COUNT / DISTINCT_COUNT / STATE_LEVEL）直接可用，例如「十年内赢得 10 场会战」 |
| Effect（X4 叠层） | 新事件种类 §17.1，`EVENT_CELL` / `EVENT_RING1` / `EVENT_COUNTRY` 目标；军事事件不在「玩家可零成本重复」白名单，冷却可以为 0 |
| 家族 | `trigger_definition_keys_by_tier` 引用军事事件（E051、E054、E058、E059、E061 等）；动态分支绑定以 `(source, event_type, cell)` 稀疏索引 |
| 叙事 | `NarrativeEventDefinition.trigger_channel = FACT_DRIVEN`，`fact_event_type` = 40–45。首批事件链：「战端初启」「城池陷落 / 光复」「全境沦陷」「国破」（吞并和约）；新增条件 `Op.AT_WAR`、`Op.CELL_OCCUPIED`、`Op.FULLY_OCCUPIED` |
| 年度报告 | 新增「战争」章：会战胜负、得失格数、军费、伤亡 |
| 音乐 | `music_situation_aggregator` 的 Tension：宣战 +，会战 +，和约 − |
| UI 提示 | 宣战、城池易手、车队被截、吞并：HUD toast 与地图特效 |

---

## 20. Country AI：军事议程

PKAI 升到 v3。

- **新输入**（追加在末尾）：兵力比、接壤格数、战争分、目标兵力差额、兵营空额、可用军工产能。
- **新议程**：`defend`、`conquer`。
- **动作**（全部为玩家同款命令）：
  - 目标兵力用 BUDGET 模式：和平时占财政收入 8%，戒备 20%，战争 40%；
  - 兵种配置：取已解锁兵种中「攻防 / 装备价」最优的前三，并保留 10% 炮兵；
  - 建兵营与城防；
  - 每条战线用 `area_control` 下达区域任务；
  - 议和：每 30 日按 §12.3 评估；
  - 宣战：至少 3 年一次的冷却，并受难度系数约束。

---

## 21. 高性能实现

### 21.1 原则

- 全部状态为 SoA、定点数、dense id。
- 只处理「活跃集合」：移动中的部队、活跃交战段、在途车队、有空额的兵营格。
- 没有工作时零 slice，`should_run = false`。
- 所有 O(全图) 的工作只在拓扑或控制变化时触发。

### 21.2 空间索引

- 格 → 部队：稠密 `cell_head[cell]`（int32，100k 格约 400KB）加 `army_next[]` 侵入链，插入和移除 O(1)。部队换格时更新。
- 格 → 交战段：`cell_engagement_mask[cell]`（u8，6 方向位）加稀疏表。
- 国家补给连通标签：在控制格上做并查集或 BFS，只在控制变化时重算受影响国家。

### 21.3 寻路

- 单目标用 A\*：环绕感知的 cube 距离启发；整数开放表用 4-ary heap；generation stamp 避免清空数组。
- 路径缓存键 `(src, dst, country, control_revision_bucket)`，固定容量开放寻址，只存路径偏移。
- 区域任务：一次有界 Dijkstra 同时评估全部候选。
- 每日每国寻路请求 ≤ 32，超出部分顺延，UI 显示「规划中」。

### 21.4 后勤

- 3 格内就近采购（§9.3）：每日按格建一次市场 CSR，O(市场行)；每个需求 O(19 格 × 每格行数)，无全局扫描、无每国场。
- 威胁场、护卫场：每日 O(部队 × 7)，stamp 清零。
- 车队：按到期日放入最小堆；每日只处理到期和途经判定的车队，途经判定 O(当日推进的格数)。

### 21.5 战斗与战线

**交战结算并行化（计划后回放）**
- worker 按交战段并行计算 `Δp`、伤亡、组织度、会战判定，写入线程局部的意图缓冲，不改全局状态；
- 主线程按 engagement key 升序回放：扣减批次、夺格、撤退、事件；
- 随机数只由 `(seed, key, day)` 派生，与线程无关，worker 与 scalar 的 hash 一致。

**增量战线**
- 维护「接触边」稀疏集合，键为 `min*6+dir`；
- 只在某格的控制或部队存在性变化时，重算该格的 6 条边，并 bump `front_revision`；
- 渲染层按 revision 重建 ribbon。

### 21.6 视野

- 部队视野源变化时不做全图重解。对旧格和新格周围半径 R（约 6）的局部补丁运行 bucket-Dijkstra，并与「领土源」的缓存结果合并。
- 一日内的所有部队移动合并为一次补丁批。

### 21.7 渲染

- `ArmyTokenLayer` 的每个实例上传 `(from_xy, to_xy, t0_day, t1_day, style)`，由 shader 按 `visual_day` 插值位置和朝向。
- CPU 只在部队换格或换状态时更新实例，不做每帧动画。
- 缩小到 0.35 以下时按格聚合为一个棋子。
- 编队视觉的 4 动作原型、1–5 成员档位与 aggregate/representative/formation 三级 LOD 先在
  `tests/military/military_formation_visual_harness.tscn` 验证，详见 `docs/plans/military-formation-visual.md`。

### 21.8 Economy 侧增量

| 项 | 成本 |
| --- | --- |
| 客籍消费 | 只对「位于有商人的本国控制格」的部队 lane 执行，复用居民清算内核；每格多 0–3 个虚拟 cohort |
| 招兵配额 | 稀疏 `(cell, quota)` 表，只覆盖兵营格 |
| 军需采购 | 每日一次市场 CSR + 每需求 19 格 |
| 军饷 | 走既有 fiscal mask，只访问有 soldier 的格 |
| 回归门槛 | 经济 < 3%，以确定性 `scan_steps_*` 计数判定 |

### 21.9 诊断计数

Military report 提供：

- `military_day_ms`、`armies_moving`、`engagements_active`、`astar_expansions`、`area_evals`；
- `threat_field_cells`、`convoys_due`、`convoy_hops`、`front_edges_touched`；
- `vision_patch_cells`、`event_coalesced`、`reconcile_delta`。

### 21.10 预算目标

| 场景 | p95 |
| --- | --- |
| 标准图 60×40、5 国战争、400 部队 | Military 日阶段 ≤ 0.5 ms |
| 合成压测 100k 格、2048 部队、4096 交战段 | ≤ 2 ms |
| 和平且无移动 | ≈ 0 |

---

## 22. 存档

| 段 | 版本 | 内容 |
| --- | --- | --- |
| PKCN | v13 → **v14** | `cell_controller` 稀疏表；opcode 22–26；`ANNEX_COUNTRY`（opcode 27）以及失效国家的 generation |
| **PKMI** | v1（新） | 兵种 catalog hash；兵种配置、目标、政策；登记批次（含品质、完好度）；训练订单；部队、路径、区域任务、补员模板、统帅空位；车队；口粮与装备库存；交战段；战争、停战、全境沦陷状态、分期赔款；会战日志 64 条；待发命令；RNG 游标；Military 账本 |
| PKEC | v58 → **v59** | soldier 职业与 `state_service_only`；官营建筑哨兵；`state_payroll` 工资政策；`ArmyPersonnelStore`（含家族子账与人物句柄）；入伍、征召、编入、拆编、伤亡的 pending；军需派送 pending；非税支出 +3 槽 |
| PKAI | v2 → v3 | 军事输入与议程 |
| PKCM / PKID / PKEF / PKTR | 随 catalog hash 变化 | 新 stat、新理念卡、新 X4 事件种类、新 Trigger 选择器 |

- PKMI 的 provider 注册在 pkcn 之后、pkef/ecp2 之前。
- 派生缓存（市场 CSR、威胁场、战线、路径缓存、视野补丁、格索引）不进存档或 hash。
- **新开局才可用**：新职业、物资、建筑、科技、stat、理念卡、事件种类都会改变 catalog hash。

---

## 23. 实施里程碑

| 阶段 | 内容 | 验收 |
| --- | --- | --- |
| **M0 目录与骨架** | 兵种、装备类别与品质；33 种物资（含发射药三档与硝酸；炸药厂改为以发射药为原料）；soldier 职业与军供需求字段；stat；Military 空壳 + PKMI；事件类型登记 | catalog hash 稳定；PKMI 往返；空世界零 slice |
| **M1 兵营与兵员** | 官营建筑三类；兵营岗位与 `state_payroll`；配额与外地部队抑制；目标兵力（两种模式）；缺员征召；民兵；兵种配置、训练、改训、换装、品质；退伍与对账；面板的总览、兵力规划、训练、图鉴页；Inspector 军事页签 | 守恒 0/0/0；士兵不被裁回失业池、不主动转出；外地部队进驻后本地停止招兵；达到目标后停止招兵；worker 与 scalar hash 相等 |
| **M2 部队、地形、后勤** | 编成与拆编（随军 lane）、口粮军供、客籍日常消费、补员、统帅空位；A\*；统一地形；视野补丁；3 格就近采购；车队、威胁场拦截；日常与作战补给；军工与火药链建筑；图层；后勤页 | 物资账本误差 0；口粮断供时士气和生存维度下降；前线需求把价格和商路拉向前线；标准图 400 部队 p95 < 0.5 ms |
| **M3 战争与占领** | 宣战；controller；交战与会战（并行回放）；夺格、撤退、歼灭；守备与城防；占领经济；增量战线；军事控制任务；海运；事件 40–47 接入 Trigger、叙事、年报、音乐 | 控制变更经 `country_committed`；伤亡守恒；事件不超过频率上限 |
| **M4 和议、吞并与 AI** | 条款定价与接受倾向（含全境沦陷加成）；分期赔款 n×A；原子和约；吞并和约与 `ANNEX_COUNTRY`；国家覆灭结局；征发；AI 军事议程 | 和约失败整批回滚；全境沦陷不会自动吞并；吞并后句柄失效、无残留引用；AI 对 AI 50 年 soak 无 fault、无守恒误差 |
| **M5 内容与平衡** | 科技节点与校验器；20 张理念卡、3 个羁绊、通道 B 规则、X4 军事事件种类；家族 24 条内容；数值调参 | 理念与家族校验通过；平衡指标见 §24 |

每个阶段都同步更新 `docs/cpp-dots-runtime/military-runtime.md`、`runtime-authority-matrix.md`、`scheduling-and-job-graph.md`、`references/system-map.md`，并新建仓库 skill `project-keynes-military-runtime`。

---

## 24. 验证

- **确定性与守恒**：同 v1.1，另外覆盖客籍消费、随军 lane、征召、吞并、截获、分期赔款。
- **兵营行为**：
  - 兵营只随命令增减；
  - 外地部队使 `present ≥ posts` 时本地配额为 0；
  - 达到目标后不再入伍；
  - 士兵 cohort 从不出现向外转职。
- **后勤行为**：
  - 需求者只从 3 格内的本国控制区市场选择来源；
  - 被包围的部队不能采购，可以征发；
  - 敌军靠近补给线时被截概率上升，远离时下降。
- **吞并**：全境沦陷后战争继续、不会自动吞并；只有吞并和约被接受才会吞并；多国占领时只能各自割地，最后一格的控制方才能提出吞并；所有句柄失效；玩家国接受吞并和约后进入结局界面。
- **口粮**：士兵的主食与蛋白质需求只由口粮满足，不出现在市场购买中；日常消费品在所在地市场购买。
- **性能**：`tests/military_runtime_bench.gd` 报告 avg/p95/max 和 §21.9 的计数器。
- **平衡（AI 对 AI soak，50 年、默认 5 个外国）**：

| 指标 | 目标 |
| --- | --- |
| 战争频率 | 每国每 20–40 年 1 场 |
| 平均战争时长 | 1–3 年 |
| 军费占国家支出 | 和平 5–15%，战时 25–50% |
| 士兵占人口 | 和平 1–3%，战时 5–10% |
| 吞并 | 50 年内每局 0–2 次 |
| 推进节奏 | 优势方每月 1–3 格；山地战线明显更慢 |

---

## 25. 已确认的决定与剩余开放项

**已确认（v1.3）**

1. **口粮军供，日常消费自理**：主食、蛋白质由军需口粮实物供给（国库付款）；衣着、日用品等由士兵用军饷在所在地市场购买。
2. **吞并必须经过和议**：全境沦陷只提高接受倾向，不会自动吞并。
3. **统帅只保留空位**：效果留到下一版。
4. **家族**：本文只给内容设计，运行时实现由你负责。
5. **火药体系**：黑火药 4 档、无烟火药 2 档、现代发射药 3 档；新增硝田和合成硝酸两条硝源；炸药保留，并改用发射药和硝酸作原料。
6. **地形对所有兵种一视同仁**；**只能新开局**。
7. **口粮折算**：直接沿用 `soldier_household` 主食、蛋白质两项需求的变体与组件表（`component_qty_per_need` 作折算系数，`variant_preference_q16` 作消耗优先级），不另建营养表（§9.2）。

**剩余开放项**

1. **多国瓜分**：一国被多个国家分别占领时，v1 只允许最后一格的控制方提出吞并和约，其余占领方只能各自割地。是否需要「多方共同和约」放到下一版。
