# 理念支持度：从作者常量改为利益归宿计算

状态：设计提案，尚未实现。
日期：2026-11-13。
关联：[理念构建重设计](ideology-build-redesign.md)、[理念文本核对](../ideology-text-audit-2026-10-25.md)。

## 1. 问题

当前 `支持度` 不是算出来的，是作者写的常量：

- 每张卡对每个政治阶层写三个 Q16 立场（`adopt/repeal/promote_stance_q16`），
  全库只有 7 套模板（6 个流派 + 军事），132 张卡共享。
- 支持分 = `Σ(阶层影响力 × 作者立场) / Σ(阶层影响力)`，
  与门槛比较，只用于卡三道操作：推行、撤回、晋升。
- 阶层影响力 = `人口 + 2×业主 + 现金/100万`，也只看结构，不看这张卡让人变富还是变穷。

结果是数值上可以被逐个证伪：

| 现象 | 现值表算出来的事实 |
| --- | --- |
| 推行几乎不卡人 | 132 张里 123 张只要"一般阶层"立场就过线 |
| 撤回是隐形陷阱 | 67 张需要某个专门阶层恰好占 50% 才撤得掉 |
| 晋升大面积锁死 | 20 张要 100% 单阶层；5 张调和传世卡的立场上限 0.3125 < 门槛 0.375，数学上不可达 |

所以问题不是"数字调得不准"，而是**被测量的对象不对**：它测的是"作者认为这个阶层喜不喜欢这张卡"，
而不是"这张卡会让这个阶层变富还是变穷"。

## 2. 目标模型：利益归宿（incidence）

沿用公共财政学与投入产出分析里的**归宿分析**：一项政策的名义落点（谁被课税、谁被补贴、
哪个系数被乘）不等于经济归宿（谁的real income 变了）。在这里：

```
一次支持度评估 =
    (1) 阶层是谁          —— 人口、职业、业主/雇员、收入与支出结构
  × (2) 这张卡改变了什么  —— 它写的 stat key、幅度、目标地块/部门、生效条件
  → (3) 每个阶层的实际收入变化 ΔY_c
  → (4) 立场 s_c = saturate(κ · ΔY_c / Y_c)
  → (5) 支持度 = Σ influence_c · s_c / Σ influence_c      ← 聚合与门槛完全不变
```

第 (5) 步沿用现有公式（`ideology_runtime.cpp:1363-1387`），
所以 `support_gate`、三个拒绝码、`explain` 的返回结构都不动；只换第 (4) 步的输入。

### 2.1 第一层：阶层是谁

已有，无需新数据：

- 每个 cohort 有职业、地块、族裔、业主/雇员人数、人口、现金、`epoch_income`、`epoch_expense`、
  `composite_satisfaction`（`runtime_economy_population_store.h`）。
- 职业 → 政治阶层走 `profession_class_id`（`profession_profile.gd:10`）。
  现状 50 个职业：一般 36、学者 9、农民 2、工人 2、军事 1。
- 阶层影响力沿用 `人口 + 2×业主 + 现金/100万`（`ideology_profile.gd:47-48`）。

### 2.2 第二层：卡片改变了什么

已编译好，无需解析卡面文案：

- 每级卡的每条效果都是 `(stat_key, op, value_q16, selector, conditions)`
  （`data/ideologies/default_ideology_effects.tres`，360 条指令行）。
- 实际出现的 stat key 只有约 60 个，其中真正的经济通道约 25 个：
  `output_factor`（部门/商品/地块）、`consumption_factor`（需求）、`birth_factor`、
  `death_factor`、`resource.*.regen_factor`、`construction.cost_factor`、
  `research.cost_factor`、`trade.capacity_factor`、`input_factor` 等。
- 目标范围（哪些地块、哪个部门、哪个商品）已经由 selector 明确（`OWN_TERRITORY` +
  `cell.sector.*` 标签等）。

### 2.3 第三层：归宿规则

每个 stat key 归到一条**通道**，通道决定"谁收钱、谁付钱"：

| 通道 | 触发键（示例） | 受益 | 受损 | v1 弹性 |
| --- | --- | --- | --- | --- |
| 部门产出 | `economy.city.building.<sector>_output_factor` | 该部门业主利润、雇员工资 | — | 利润 1.0 / 工资 0.25 |
| 商品产出 | `economy.city.good.<good>.output_factor` | 该商品生产者 | 替代品生产者（v1 忽略） | 同上 |
| 地块总产出 | `economy.city.output_factor` | 该地块全部业主与雇员 | — | 同上 |
| 需求消费 | `economy.city.need.<need>.consumption_factor` | 该需求的消费者（实物消费增加）、该需求商品的供给者 | — | 消费 1.0 |
| 出生 | `economy.city.birth_factor` | 长期人口；短期抚养比 | — | 0.2 |
| 死亡 | `ideology.country.population.death_factor` | 全员（期望寿命） | — | 0.2 |
| 资源再生 | `economy.city.resource.<res>.regen_factor` | 该资源地块的业主与雇员 | — | 0.5 |
| 建设成本 | `ideology.country.construction.cost_factor` | 出资建设者（资本） | 建材供给者 | 1.0 |
| 研究成本 | `ideology.country.research.cost_factor` | 学者阶层、国家 | — | 1.0 |
| 贸易容量 | `ideology.country.trade.capacity_factor` | 商人 | — | 1.0 |
| 生产投入 | `*.input_factor` | 投入品供给者 | 全部生产者（成本） | 1.0 |

`:xxx.cut` / `:xxx.gain` 后缀是同一条通道的符号变体，映射到同一行、取相反/相同符号，
不需要单独授权重。

**明确写进文档的近似**：固定价格、一阶线性、无一般均衡、无财政反馈。
`|Δstat| ≤ 20%` 时误差可接受；更大的用饱和函数而不是线性外推。

### 2.4 第三层公式（Q16）

对每个国家、每个阶层 `c`：

```
ΔY_c = Σ_g [ R_c,g · ρ_output_g · ε_profit
           + W_c,g · ρ_output_g · ε_wage
           − I_c,g · ρ_input_g
           + C_c,n · ρ_consume_n
           + ... 其余通道 ]
Δu_c = ΔY_c / max(Y_c, 1)
s_c  = saturate(κ · Δu_c)          // κ 默认 10，即 +10% 收入 ≈ 立场 +1.0
```

其中 `R_c,g` 是 c 阶层从 g 部门分到的业主利润，`W_c,g` 是工资，`I_c,g` 是它拥有的
建筑付的投入成本，`C_c,n` 是它对需求 n 的消费额，`Y_c` 是它的人均收入。

聚合不变：

```
support = Σ_c (流行影响_c · s_c) / Σ_c 影响力_c
```

`critical_min` 从手写常量改成派生规则：任何阶层 `Δu_c < -0.20` 自动否决
（等价于今天的"关键阶层"机制，但不再逐卡授权重）。

### 2.5 地块口径

门槛继续用全国加权（避免"只讨好首都"的退化玩法），但额外发布一份**地块支持度**：

```
local_support(cell) = Σ_c influence_c(cell) · s_c(cell) / Σ_c influence_c(cell)
```

`s_c(cell)` 与全国 `s_c` 只在"这张卡是否命中该地块"上不同：命中的地块按通道算，
未命中的为 0。数据已有（每格的阶层构成 + selector 已能解出目标格），
成本是每张卡 ≤ 32 格的一次求和。用途：

- 地图高亮从"效果命中在哪"升级成"谁在这里得利"；
- 后续可以让本地支持度影响推行速度或维护成本，而不是再加一道硬门槛。

## 3. 数据缺口与归属

| 数据 | 现状 | 归属 | 新增成本 |
| --- | --- | --- | --- |
| 建筑组收入/投入/工资/维护/营业税 | 已有（`BuildingGroup.last_*`） | Economy | 0 |
| 建筑组业主签名、员工职业与人数 | 已有 | Economy | 0 |
| cohort 收入/支出/满意度 | 已有 | Economy | 0 |
| 每（国，阶层）工资/利润/毛利/税/消费 | **缺** | Economy 提交末端聚合 | 一次遍历，约 30 个数字/国 |
| 每（国，阶层，部门）暴露 | **缺** | 同上 | 6 部门 × 5 阶层 |
| 每（国，需求）消费篮子 | **缺**（可由消费计划推出，不必实测） | Economy 或内容侧 | 20 需求 × 5 阶层 |
| stat key → 通道表 | **缺** | Ideology 目录（内容） | ~25 行 + 60 key 归类 |
| 职业 → 要素暴露（M1 回退） | **缺** | 内容 | 50 行，可选 |

所有权与交接按现行架构：Economy 在自己的提交末端把上述聚合**发布**成已提交视图的一部分；
Ideology 只读，不反向访问 Economy 内部容器。现有唯一转换点在
`gdext/src/ideology_opinion_bridge.h`，扩字段只改这里一处，两个权威（主线程 runtime 与
worker POD）才不会再分叉。

## 4. 实现位置

- 新文件 `gdext/src/ideology_support_incidence.{h,cpp}`：通道表、矩阵乘、饱和与解释串。
  **不要**写进 `ideology_runtime.cpp`：它已经 8302 行，超过 2000 行闸门，只允许变短。
- `NativeIdeologyRuntime::evaluate_support()` 只把 `stance.stance_q16[direction]`
  换成 `incidence::stance_q16(...)`，其余不动。
- **必须同步** `RuntimeIdeologyPodAuthority::support_allows()`
  （`runtime_ideology_pod.cpp:749-779`）。主线程与 worker 是两个权威，只改一边会让 parity
  退化成业务差异，而不是崩溃——这是最难查的一类回归。
- 缓存：`(country, snapshot.revision, card, level, equipped_mask)`。纯派生，不入存档、
  不入 state hash；`revision` 变了就重算。
- GDScript 只做展示：`explain_ideologies` 增发每阶层 `Δu`、通道明细、受益/受损标签。

## 5. 验证方案

这是把"另一种拍脑袋"变成"科学"的关键环节，必须可证伪：

1. **符号回测**：在既有存档上，记录每张卡推行前后 30 个模拟日的各阶层真实
   `epoch_income / composite_satisfaction` 变化，与预测立场比较符号。
   验收：符号一致率 ≥ 70%；"预测 ≥ +0.5 而实际收入下降 > 5%"的假阳性必须为 0。
2. **三方案消融**：现有常量 / M1 要素暴露 / M2 现金流归宿，在同一批存档上比较
   上面两个指标。
3. **可达性回归**：新模型下重跑 132 张卡的三道门可达性，确认"调和传世卡不可晋升"这类
   结构性死门消失，且没有新增死门。
4. **A/B 长跑**：8 国 30 年，对比卡池多样性、推行停滞率、阶层收入差距。
5. **护栏**：同种子同结果（状态哈希不变，因为支持度是派生量）、账本守恒不变、
   提交末端新增耗时 < 0.5 ms/国、面板查询走缓存。

## 6. 风险

| 风险 | 处理 |
| --- | --- |
| 变成"谁发钱谁通过" | 保留作者写的**价值项**作为少数权重（建议 30%），并保留自动否决 |
| 玩家把某阶层人口清零以绕过否决 | 设最小影响力占比（如 2%），低于视为不存在 |
| 一阶线性在极端卡上失真 | `saturate` + 通道弹性上限，禁用 > 50% 的线性外推 |
| 自我引用（卡自身效果进入自己的支持度） | 明确定义为"如果推行它"，并在文案里写清 |
| 每次 explain 都重算 | 按 revision 缓存；面板只在 revision 变化时刷新 |
| 两个权威分叉 | 单一 kernel + parity 测试（沿用现有 SHADOW 机制） |

## 7. 分期

| 阶段 | 内容 | 产出 | 估时 |
| --- | --- | --- | --- |
| P0 | 不改运行时，用现有 stat key + 归宿表做**一致性审计** | 132 张卡的"作者立场 vs 实际受益者"不一致清单 | 0.5–1 天 |
| P1 | Economy 提交末端聚合 + snapshot 扩字段 + bridge | 每国阶层现金流暴露 | 2–3 天 |
| P2 | incidence kernel + `evaluate_support` 替换 + 缓存 + 单测 | 新支持度跑通 | 2–3 天 |
| P3 | 面板四列 + explain 明细 + 文案 | 玩家能读懂"谁赞成、为什么" | 1–2 天 |
| P4 | 回测与调参，修结构性死门 | 验收数据 + 平衡表 | 2–3 天 |

P0 不需要任何运行时改动，却能立刻回答"现在的立场和效果是否自相矛盾"，
建议先做它再决定是否投入 P1–P4。

### 7.1 P0 已跑的一次审计（2026-11-13）

只用内容表做符号级审计：卡 → 等级 → 效果程序 → `stat key`，按"谁在这个部门/需求里就业与
持股"折算受益阶层，再与作者写的立场比较符号。暴露度由建筑配方推出（业主职业 + 雇员岗位 ×
职业→阶层），未使用运行时数据，也未计价格与规模。

| | 现状阶层映射 | 修好阶层映射后（草案） |
| --- | --- | --- |
| 农业岗位的阶层归属 | 一般 98%、农民 2% | 农民 65%、工人 18%、一般 10%、学者 6% |
| 制造业 | 一般 99% | 工人 80%、学者 10%、一般 9% |
| 知识业 | 学者 75%、一般 25% | 学者 95% |
| "最受益阶层 = 立场最高阶层" | 9/89（10%） | 47/89（53%） |
| 立场与自身效果方向相反 | 13 处 | 47 处 |

两个结论：

1. **阶层映射是前置条件。** 现状下 98% 的农业岗位算"一般阶层"，任何利益模型都会退化成
   "一切归一般阶层"，这也是上一轮支持度看不出阶层差异的根因。不先修映射，做归宿模型没有意义。
2. **修好映射后，一半的卡对不上。** 典型是农商系：卡牌给全国产出加成，农民作为 65% 的农业
   劳动力与 12% 的业主实际受益（+0.67），作者却统一写 −0.25。这不是数值大小问题，而是
   "作者在断言一个机制没有实现的因果"（价格效应）。要么补价格归宿，要么改立场。

审计脚本为一次性工具，未入库；口径与阈值见本节正文。

## 7.2 实施状态（2026-11-13，第一版已落地）

已实现，且与本节前面的设计有三处**有意偏离**（都写在下面，避免文档与代码分叉）：

| 层 | 内容 |
| --- | --- |
| P0.5 阶层映射 | 50 个职业全部显式归属：`general` 7 / `farmer` 12 / `worker` 18 / `technology` 12 / `military` 1。类 id 集合不变，因此 `class_hash` 与旧档不因这一项失效。 |
| P1 Economy | `CountryClassOpinionSnapshot` 新增 `incidence_channel_count`、`incidence_measured[country]`、`class_incidence_q16`；在 `publish_country_development_facts()` 复用建筑组与 cohort 遍历累加绝对金额，末端归一化为 Q16 份额；`profession_need_weight_q16` 由 `EconomyCatalog` 从消费计划编译（20 项/职业，行和 65526–65532）。 |
| P1 传输 | `publication_codec` 追加三条 lane；**ECP2 schema 60→61、ABI 3→4**；`ideology_opinion_bridge.h` 单点复制；`RuntimeIdeologyOpinionSnapshot` 扩字段，**IDP2 ABI 11→12**；host 与 pod 两侧形状校验。 |
| P1 目录 | `IdeologyProfile` 新增 `support_model / incidence_gain_q16 / incidence_veto_q16 / incidence_veto_min_influence_q16`；`IdeologyCatalog` 编译 `incidence_level_channels_q16`（每级一行稠密通道表）。旧式 `ideology.<card>` 行通过 Modifier 目录的 terms 反解，不再整卡丢失。 |
| P2 内核 | 新增 `runtime_ideology_incidence.h`（纯算术，双侧共用）与 `ideology_support_incidence.{h,cpp}`（查表、评估、面板分解）；`evaluate_support` 与 worker `support_allows` 都改调同一 kernel；自动否决取代 `critical_min`。 |
| P3 展示 | 详情浮层新增"阶层损益"：每阶层 `收入 ±x% / 立场 / 影响力`；卡片 tooltip 换成一行公式说明；新增五个拒绝原因的中文。 |

**与 2.x 设计的三处偏离**：

1. **通道 31 个，不是 34**：`[0..5]` 部门收入、`[6]` 投入成本、`[7]` 业主利润、`[8]` 商人毛利、`[9]` 出生、`[10]` 死亡、`[11..]` 20 个需求。部门成本并入单一 `input_cost` 通道，因为内容里的 `input_factor` 是国家级的；出生/死亡是结构通道（份额恒为 1.0，目录侧乘 0.15 权重）。
2. **份额是 int32 Q16，不是 int16 Q15**：`class_incidence_q16`。340 B/国 → 约 620 B/国，换来免去定点缩放的精度陷阱。若日后要压传输量，降到 Q15 只需改 `publication_codec` 一行。
3. **`support_model=0` 已退役**：`configure` 直接以 `ideology_support_model_retired` 拒绝。回滚靠 git，不靠运行时开关；这样不会出现"配置写着 0、实际按材料算"的静默分叉。

**这一版还没做的**（按计划顺序）：

- 通道 Top-4 明细（面板目前给到每阶层损益 + 地块支持，没给"哪条通道贡献了多少"）。
- 与生成器 `player_program_summary()` 的逐条幅度一致性测试仍未写。
- 地图着色（地块支持度只进详情浮层，还没有换成地块高亮色）。

### 7.2.1 地块支持度（已实现，仅显示）

- Economy 的 `get_cell_situation_snapshot` 多发布一列 `class_population`（请求格 × 政治阶层，
  行主序）与 `class_count`。它本来就是按请求格遍历的受限查询，不是新的全图扫描。
- 纯函数在 `scripts/ideology/ideology_local_support.gd`：
  `local_support(cell) = Σ_c 人口_c(cell) × 立场_c / Σ_c 人口_c(cell)`。
- 门面 `IdeologyFacade.local_support(handle, id, cells, direction)` 组合
  `explain_ideology_support` 与那列人口；详情浮层显示"命中 N 格：平均 / 最低"。
- 门槛仍然只看全国：地块口径只做客舱仪表，避免"讨好首都即可推行"。
- 单测 `tests/ideology/ideology_local_support_test.gd`：14 项断言，覆盖单阶层、双格异质构成、
  零人口、列长不足、汇总极值。


### 7.3 校准与可达性（2026-11-13）

`tests/ideology/ideology_incidence_calibration_probe.gd` 用 5 个合成原型国家（全一般 / 农业 /
工业 / 知识 / 军事）跑与原生相同的公式，结果（132 张卡，按 0 级效果）：

| κ | 全一般 | 农业 | 工业 | 知识 | 军事 |
| --- | --- | --- | --- | --- | --- |
| 5 | 48 | 38 | 39 | 37 | 40 |
| 8 | 60 | 47 | 47 | 47 | 49 |
| **10（当前）** | **62** | **49** | **50** | **50** | **52** |
| 12 | 65 | 50 | 50 | 50 | 53 |

- 采用 κ=10：+10% 相对收入读作满格立场。推行通过率 37%–47%，晋升 21%–29%。
- **26 张卡的效果全部落在未映射的 stat 族上**（`family.city.*`、复合键等），通道行全零。
  这类卡不再参与门槛（目录发 `incidence_level_measured`，0 表示"模型无法表达"，放行），
  否则它们会变成不可推行的死卡。
- 另有 15 张有通道但任何原型都过不了门槛；`never_adopt` 合计 41（含上述 26 张）。
- 计划里 55%–75% 的目标没达到，**瓶颈是通道覆盖不是 κ**：把 653 处未映射行补上比继续加 κ
  更有效。继续加 κ 只会让"全一般"国家过度通过、拉不开区分度。

### 7.3.1 门槛标定（2026-11-13 第二轮）

生成器写的三档门槛是针对旧立场（0.125–0.625）标定的；材料立场的量级小一个数量级（一个阶层只
占被影响流量的一部分），直接用原始门槛会挡掉大部分卡。为此新增一个**只作用于比较**的标定系数
`incidence_threshold_scale_q16`（默认 **0.35**），主线程与 worker 都读同一份：

| 系数 | 全一般 | 农业 | 工业 | 知识 | 军事 |
| --- | --- | --- | --- | --- | --- |
| 1.00 | 62 | 49 | 50 | 50 | 52 |
| 0.50 | 70 | 54 | 59 | 56 | 59 |
| **0.35（当前）** | **70** | **55** | **60** | **59** | **60** |
| 0.25 | 72 | 57 | 62 | 63 | 62 |

再往下压收益消失：26 张卡没有任何已映射通道，另有约 15 张卡的效果幅度小到任何门槛都过不去。
标定系数不写进内容，因此不需要重新生成 132 张卡的 `.tres`。


### 7.4 回归环境的已知阻塞（2026-11-13）

本 checkout 跑不了整套 fixture，原因**不在本次改动**：
- `addons/0_fmod_bootstrap` 缺 windows.x86_64 的 GDExtension 库，Godot 启动即报错。
- `scripts/ui/cell_inspector_view_model.gd:6172`（`var politics := summary.get(...)`）在
  "inference from Variant 当作错误"的策略下是硬失败，连带 `country_view_model` →
  `player_controller` → `ideology_workspace` 整条依赖链编译失败。该文件在 HEAD 上就是 7817 行、
  超出自身 7672 的基线，属于既有债务。
- 因此本轮用三个不依赖世界启动的探针取证：`ideology_incidence_probe.gd`（目录 + 原生 configure）、
  `ideology_incidence_calibration_probe.gd`（κ 与可达性）、`ideology_local_support_test.gd`（地块数学）。
  全部通过。重型 fixture 需要在修好上面两点后再跑。






### 7.5 测试钩子与套件现状（2026-11-13 第三轮）

材料模型会让一部分卡在特定国家里**真的过不了门槛**。这对玩法是设计意图，但对那些只想要
"先把卡装上再测别的"的 fixture 是噪音。为此提供唯一的测试钩子：

```gdscript
IdeologyCatalog.support_gate_enabled = false   # 进程级，必须在生成世界之前设置
```

`load_default()` 会据此把 profile 的 `support_gate_enabled` 置 false，原生
`configure_table` 于是按"无模型"配置，门槛不再拦截任何操作。生产默认 true，游戏代码从不设置。
18 个非门槛类 fixture 已接入；`ideology_scalar_worker_test` 的检查数从 10 升到 29，门槛相关
失败消失。

全量 ideology 套件（100 个文件）当前的失败分三类：

| 类别 | 数量 | 说明 |
| --- | --- | --- |
| 门槛拒绝 | ~16 | 已用上述钩子处理，待重跑确认 |
| 既有内容漂移 | ~10 | holdout 卡（mandate_of_heaven / petition_box / land_value / progressive_tax）、卡面文案、科技索引假设、`ideology_synergy_override_tag_unknown` 等，与本次改动无关 |
| 真实回归 | 0 | 目前没有证据指向材料模型本身的算术或状态问题 |

另外：本轮期间 `gdext/src` 被另一个进程同时修改（国家 `capital_cell` 特性，PKCN 头随之变化），
`ideology_scalar_worker_test` 剩下的唯一失败是 `country_checkpoint_pkcn_header_mismatch`，
属于那次并行改动的半成品，不在本计划的范围内。

### 7.6 工作区事故与当前红绿（2026-11-13 第四轮）

**事故**：本轮中途发现有 **2404 个已跟踪文件从工作区消失**（`assets/icons` 468、`assets/military`
462、`assets/ui` 367、`scenes/ui` 153、`assets/audio` 79、`addons/dots_ext` 570 等），
其中包含 `assets/fonts/swei/*.ttf`。`ui_tokens.gd` 在 `preload` 里引用这些字体，缺失即整条 UI
依赖链解析失败，任何加载 UI 的 fixture 都报 `Preload file ... does not exist`。
用 `git status --porcelain` 取出 ` D ` 列表后 `git checkout --pathspec-from-file` 全量恢复，
复查剩余删除为 0，字体与核心用例恢复（content 67/0、runtime 92/0、opinion 22/0、workspace 17/0）。
这不是本计划产生的改动，但会影响任何一次回归，需持续留意。

**门槛钩子效果**（18 个 fixture 接入后）：

| fixture | 结果 |
| --- | --- |
| `ideology_boundary_lock_reachability_test` | 5 failures → **0**（42 checks） |
| `ideology_save_worker_authority_test` | 15 failures → **0**（91 checks） |
| `ideology_scalar_worker_test` | 10 → 29 checks，仅剩 PKCN 头不匹配（并行改动的半成品） |

**剩余失败的性质**（全部与材料模型无关，逐条读过断言）：

- `cell_layer_e2e_realworld`：世界生成后 `widest=1`，而用例要求存在 >32 格的国家。
- `card_content_worker`：`terrace_farming` 的 discover 被拒 + 期望的 stat key 已不存在。
- `gate_chain`：12 个"settlement"格全部没有被 `cell.settlement` 标签命中。
- `pool_mechanics`：fixture 目录里的羁绊改写引用了未注册标签（`ideology_synergy_override_tag_unknown`）。
- `social_media`：`country_worker_peer_stall_timeout`，worker 健康问题。
- `mechanism_equip_level` C2/C3：断言的是**旧模型**的否决语义（关键阶层否决 / 负支持），需按材料模型重写。
- holdout 卡引用（`mandate_of_heaven / petition_box / land_value / progressive_tax`）、卡面文案、
  科技索引假设：内容侧漂移。

下一轮从"机制性可修"的开始：`mechanism_equip_level` 的 C2/C3 重写、`pool_mechanics` 的标签注册、
`gate_chain` 的 settlement 标签；内容漂移类（holdout 卡）需要内容侧决策。

**本轮已修**：

- `ideology_mechanism_equip_level_test`：C2 改为校验材料模型"逐阶层立场发布 + 撤回 = 取反"，
  C3 改为 `promote` 的确定性拒绝（等级不足），保留"被拒 = 无半成品转移"的覆盖。
  **160 checks / 0 failures**。
- `ideology_pool_mechanics_test`：改用真实的 `EffectDomainCatalog`，羁绊改写标签得以解析。
  **6 → 20 checks / 0 failures**。
- 复验无回归：`boundary_lock` 42/0、`save_worker_authority` 91/0、`instance_budget` 25/0、
  `content` 67/0、`runtime` 92/0、`opinion` 22/0、`workspace` 17/0。

**剩余（约 20 个文件）**：`card_content_worker`、`gate_chain`、`scalar_worker`（并行 PKCN 改动）、
`worker_authority_parity`、`worker_derived_pump`、`worker_managed_lifecycle`、`restart_mask`、
`x12`、`x13a`、`x1b`、`social_media`、`draw_flow`、`d4_multi_cell`、`cell_layer_e2e_realworld`、
`m0_realworld_cost`、`card_face_semantics`、`x10`、`mechanism_matrix`、`effect_scale_override`、
`cell_card_worker`，以及 4 个 holdout 卡引用。

### 7.7 当前回归被并行改动阻塞（2026-11-13 第五轮）

**证据**：非理念域用例 `tests/runtime/runtime_economy_worker_restart_test.gd` 现在也失败——
`29 checks, 3 failures`，日志为 `[country][active] day=3 failed=country_worker_peer_results_pending`
与 `[runtime-day-wait] day=3 ... stall=0x6`。同一环境下 `ideology_x10_worker_test` 从"仅剩科技索引
假设"退化为 `day_wait_peer_stall_timeout`，`ideology_social_media_worker_test` 亦同。

**结论**：`gdext/src` 上正在进行的国家 `capital_cell` 特性（PKCN/POD 协议）让 worker 图在换日时
挂起。凡是走 worker 权威的 fixture（x10/x12/x13a/x1b/social_media/parity/derived_pump/scalar 等）
当前都**不可诊断**，测到的是那个半成品的状态，不是材料支持模型的行为。

本轮能做的两件事已经做完：

- `ideology_x10_worker_test`：把硬编码的 `tech.composite_tools`（今天索引 48，已跌回第一个 64 位字）
  改成"取目录里最后一个科技"，该断言不再失败（随后被 worker 挂起掩盖）。
- `ideology_gate_chain_test`：补了一次完整经济日（`run_economy_slice` 直到 `done`），让
  `cell.population` 指标有机会发布；结果仍是 0 个目标格，且该指标在经济提交末端发布，
  提交又依赖同一套被挂起的国家/worker 路径，因此同样需要等并行改动落定后再判。

**下一步**：等国家 `capital_cell` 特性提交完毕、`runtime_economy_worker_restart_test` 恢复绿色之后，
再重跑 ideology 套件；那时剩下的才是需要修的 fixture 腐蚀。在那之前不修改 worker 相关 fixture，
避免把别人的半成品当成自己的回归来"修"。

### 7.8 干净重跑（2026-11-13 第六轮）

`runtime_economy_worker_restart_test` 已恢复绿色（并行改动落定），于是**独占运行**（不再与任何
其他 Godot 进程并发）重跑 100 个 ideology 文件：

| 结果 | 数量 |
| --- | --- |
| 通过（summary 里 `0 failures`） | **67** |
| 真实失败（summary 里 failures > 0） | **24** |
| 无 summary | 9 |

注意两点方法论问题，否则数字会被误读：

1. **退出码不可信**：`0x_fmod_bootstrap` 缺 windows 库会让进程以非零码退出，而 summary 是
   `0 checks, 0 failures` 或 `N checks, 0 failures`。判定必须读 summary 的 failures 数，不能看 exit code。
2. **无 summary 多为读取时序**：`Start-Process` + 重定向时，快测试的 stdout 还没落盘就被读走。
   单独重跑后 `b5_idle`（12/0）、`tag_snapshot_stress`（38/0）、`x1b_source_count`（142/0）
   全部通过。真正的无 summary 只剩：`school_strength_worker`（TIMEOUT）、`x6b_worker`（TIMEOUT）、
   `x5_worker`（挂起 >8 分钟）、`social_media`、`worker_authority_parity`、`restart_mask`。

**24 个真实失败**（按性质）：

- 内容漂移：`card_face_semantics`(11)、`mechanism_matrix`(10)、`country_ramp / x14 / x16`（holdout 卡）、
  `card_content_worker`(3)、`effect_scale_override`(3)。
- 世界/选择器假设：`gate_chain`、`cell_layer_e2e_realworld`、`m0_realworld_cost`、`d4_multi_cell`、`draw_flow`、`x3b_cards`。
- 门槛/边界：`boundary_lock_reachability`（同步腿 48 次调用 0 次拿到边界锁）、`x1b_worker`、`x13a_worker`。
- worker 健康：`scalar_worker`（PKCN 头）、`worker_derived_pump`、`worker_managed_lifecycle`。

本轮还修了 `ideology_effect_scale_override_test` 的本地卡 `school_id`（13→20 checks），
其剩余 3 处是 override 语义断言漂移，未动。

### 7.9 第七轮：两个真实修复与一个"假回归"

- **`ideology_draw_flow_test`（16/1 → 16/0）**：抽卡被原生拒绝时，`ideology_player_reason` 对
  `ideology_offer_pool_insufficient` / `ideology_offer_weight_invalid` 返回**空字符串**，于是"拒绝后
  解锁、恢复时钟并说明原因"的断言拿不到 message。这是一个真实的 UX 缺陷（玩家看到抽卡失败却没
  有原因），改成一句合并文案，行数不变。
- **`ideology_boundary_lock_reachability_test` 不是回归**：套件里它报 1，独占运行时 42/0。
  该用例断言"同步腿 48 次背靠背调用 0 次拿到边界锁"，对机器负载敏感；判定必须在独占环境跑。
- `ideology_d4_multi_cell_country_test` 与 `ideology_cell_layer_e2e_realworld_test` 同源：
  生成世界后 `widest=1`，48 次 claim 被接受但领土没有增长。`tests/country/country_runtime_test.gd`
  同时也有 1 处失败，指向国家域本身，不在本计划范围。
- `ideology_gate_chain_test` 仍是 `cells=0`：已确认 fixture 的人口（400）与
  `SETTLEMENT_POPULATION`（400）刚好相等，所以问题确实在 `cell.population` 指标没有发布；
  补一次完整经济日和一次 `refresh_effect_input_digest_for_test()` 都无效，指向指标发布依赖
  经济提交末端（与上面国家/领土那条同源），暂不继续投入。

### 7.10 第八轮：worker 装备簇缩小到"转移不结算"

- `ideology_x1b_worker_test`：discover 与 equip 都被接受，但 slots 在 20 秒驱动里始终为 0，
  即 **ACK 门控的转移没有结算**。它的 `_drive_days` 只服务 `service_country_worker_peer_adapter`
  与 `publish_ideology_worker_inputs`，没有显式驱动 Effect/Modifier 原生适配器（`gate_chain` 那类
  主线程 fixture 是手写 `run_effect_daily` + `dispatch_effect_native_modifier` + `ack` 才结算的）。
  这条线索可用于 `x1b / x12 / managed_lifecycle / draw_flow` 这一簇，但尚未证实是唯一原因。
- `ideology_gate_chain_test`：把 `refresh_effect_input_digest_for_test()` 移到
  `configure_effects` 之后（它由 EFFECT runtime 消费，之前那次放在经济日之后无效），仍然 cells=0。
  结论不变：`cell.population` 指标在这套 fixture 里没有进入选择器可见的通道。
- `ideology_mechanism_matrix_test` 的 10 处失败是**程序结构快照**断言（cooperative 的 20%/15%
  门槛与农业标签、军事系程序的 CONST+EMIT 形状），属于内容/生成器漂移。
- `ideology_d4_multi_cell_country_test` / `cell_layer_e2e_realworld_test` 同源于国家领土不增长。

### 7.11 第九轮：worker 装备簇的收据证据

给 `ideology_x1b_worker_test` 的 `_drive_days` 补上 Effect/Modifier 适配器服务
（`run_effect_daily` → `dispatch_effect_native_modifier` → `run_modifier_daily` → `ack`）后，
**slots 仍然是 0**，说明不是"没人驱动适配器"。

收据（`poll_ideology_receipts`）给出了更硬的证据：

| 运行 | 收据 |
| --- | --- |
| 第一次 | `opcodes:[1,5] reasons:["ideology_discovery_not_allowed","ideology_unknown"]` |
| 第二次 | `opcodes:[5] reasons:["ideology_unknown"]`（discover 的收据不见了） |

两次运行的差别说明 discover 有时落地、有时不落地，而 equip 在**另一侧**被判定为
`ideology_unknown`（该侧看不到 discover）。同一张卡 `acquisition=3`（已打印确认），所以不是卡面
配置问题。结论：这是 worker/主线程**状态路由**的问题——发现落在一边、装备在另一边校验。

这条与 `x12 / managed_lifecycle / social_media / parity` 的表象一致，属于并行 worker 改动带来的
环境问题，不在材料支持模型范围内。所有临时探针改动已回滚，`ideology_x1b_worker_test` 只剩
`support_gate_enabled` 测试钩子三行。

### 7.12 第十轮：内容漂移的归因与一个被推翻的结论

- 试过用 `build_ideology_catalog()` 直接把生成的卡面文本与线上 `.tres` 对比（只读，不落盘）。
  它报 `terms: excise needs exactly 3 levels`——但这是**我的调用方式**跳过了 `main()` 里的
  前置装配（`LEVEL_TERMS["excise"]` 在 8009-8016 处才被填入），**不是生成器坏了**。结论撤回。
- 因此"线上 `.tres` 是否相对生成器陈旧"仍未判定；`全社会` 只出现在
  `render_ideology_review.py`（评审渲染器），线上 `.tres` 里却有，倾向于陈旧，但要判定必须真正
  跑一次 `main()` 并 diff 四个输出文件，属于内容侧决策，未执行。
- `ideology_cell_layer_m0_realworld_cost_test` 的根因拿到了：pod 报告
  `ideology ready=false reason=ideology_opinion_snapshot_missing`，同时
  `player owned cells=-2`。没有阶层意见快照 → 任何卡都不能装备 → 4 条花费断言连带失败。
  这与 `gate_chain`（`cell.population` 未发布）同族：**经济发布阶段没有产出理念/效果层需要的东西**。

### 7.13 第十一轮：内核防御 + 权威套件基线

**内核加固**：`evaluate_material_support` / `explain_breakdown` 现在校验快照的 `class_count`
与理念侧阶层列表一致。份额行是按**快照的**阶层数跨步的；若两侧在阶层目录变更后不一致，用另一
个跨步去读会得到"看起来合理但完全错误"的立场，而不是缺数据。现在这种情况直接按"无数据"处理
（走既有旁路），不会静默算出错值。pod 侧本来就有 `opinion.class_count == _catalog.class_count`
校验，这条是主线程路径的第二道。

**权威套件（独占运行、按 summary 判读）**：

| 结果 | 数量 |
| --- | --- |
| 通过 | **71** |
| 真实失败 | 24 |
| 超时/无 summary | 5（`school_strength`、`social_media`、`x5`、`x6b`、`x6c`，全是 worker） |

相比上一轮（67 / 24 / 9）：`draw_flow` 转绿，测量噪声减少。24 个失败的性质与 §7.8/§7.12 一致，
没有一项指向材料支持模型。

重建后复验（含新增的 class_count 守卫）：content 67/0、runtime 92/0、opinion 22/0、
local_support 14/0、mechanism_equip_level 160/0、cell_situation_snapshot 19/0。

### 7.14 第十二轮：门槛钩子的边界（实验并回滚）

假设：剩下几个 worker fixture（`x3b_cards / x8 / x9a / x9b / x10 / x14 / x16 / x6x`）也在装配阶段
被门槛拒绝。给这 10 个文件加上 `support_gate_enabled = false` 后逐一实测：

| fixture | 加钩子前 | 加钩子后 |
| --- | --- | --- |
| `x10_worker` | 39–45 checks / 2–3 failures | **52 checks / 17 failures**（明显变差） |
| `x8_worker` | 30 / 1 | 54 / 2 |
| `x9b_family_target` | 26 / 8 | 2 / 1（提前中止） |
| `x3b_cards / x14 / x16 / x6a` | 不变 | 不变 |

结论：这些 fixture **不是**被门槛挡住的——它们要么依赖门槛的真实行为（`x10`），要么失败在别处。
10 个文件全部回滚，`x10` 恢复到 45 / 2。门槛钩子只适用于"前提是装上卡、且不测门槛"的那 18 个文件。

至此可以确认：剩下 24 个失败里没有一个是材料支持模型的回归。

### 7.15 第十四轮：解开一个"两个 fixture 互相矛盾"

`ideology_card_face_semantics_test` 的 11 处失败不是一个问题，而是两个：

1. **禁用表与内容契约矛盾**。禁用表列了 12 个 stat 标签（`全社会`、`国内贸易容量`、`贸易速度`、
   `*部门产出`、`*领域研究效率`），但 `ModifierCatalog.IDEOLOGY_PLAIN_STAT_NAMES` 正是把它们定为
   理念卡面的**专用措辞**（注释说明这张表就是为了让卡面独立于共享 stat 标签），
   `ideology_content_test` 又逐字断言 `"农业部门产出 +6%"` 是期望文案。两条 fixture 不可能同时成立，
   过期的是禁用表。移除这 12 条（其余保留）后 **2101 checks / 0 failures**。
2. **程序数被钉成快照**。`program_count == 280` 让任何内容新增都打断这个卡面语义测试，
   改成 `>= 280` 的下界护栏。

这条经验值得记住：**当两个 fixture 对同一份文案给出相反断言时，不要急着改内容**——先确认哪一条
还在被别的契约引用。这里的证据（专用标签表的注释 + content 测试的逐字断言）指向禁用表过期。

### 7.16 第十七轮：`m0_realworld_cost` 与 `gate_chain` 同源

先排除了一个假线索：`[realworld-cost] player owned cells=-2` 里的 `-2` 是 fixture **故意**的
哨兵值（"territory exists, exact count unavailable"，见 `_player_cell_count()` 注释），不是 bug。

真正的因在 economy 的提交：

```
[sim/graph-barrier/econ] day=1 fatal=false stage=fiscal_settlement ... last_committed_day=-1
[sim/graph-barrier/pods] ideology ready=false reason=ideology_opinion_snapshot_missing
```

阶层意见快照在**经济提交**时发布；这个 fixture 里 `last_committed_day` 一直是 -1，说明这一天的
经济阶段根本没有走到 `done`。我另加了一段"循环 `run_economy_slice` 直到 done"的排空逻辑，
**2048 次切片仍未 done**，因此排空也不是缺的那一步。

结论：`m0_realworld_cost`（4 处）与 `gate_chain`（1 处）的失败都是"经济日在这类世界里跑不完"的
下游表现，属于经济运行时/并行改动范围。探针已回滚，fixture 只剩门槛钩子三行。

### 7.17 第十八轮：discover 命令在传输中丢失（收据级证据）

前几轮一直在猜 `ideology_discovery_not_allowed` 的来源（卡的 acquisition？科技门槛？门槛钩子？）。
这轮把两个权威的 `apply_command` DISCOVER 分支都插了 stderr 探针，结论出人意料：

**两侧探针都没有触发**——主线程 `NativeIdeologyRuntime` 和 worker `RuntimeIdeologyPodAuthority`
都没有收到这条命令。

对照收据更清楚：

```
submit_ideology_commands(...)  -> ok: true          （批次已被接受）
poll_ideology_receipts(0, 32)  -> receipt_ids:[1]   （只有 1 号收据）
                                  sequences:[2]     （对应第 2 条命令，即 equip）
```

**第 1 条命令（discover）没有产生任何收据**：既没有成功回执，也没有拒绝回执。随后 equip 因为
"卡未 discover" 被拒为 `ideology_unknown`。

也就是说：命令在 `submit_ideology_commands` 之后、进入任一权威之前**被静默丢弃**。这解释了这个簇
"有时成功有时失败"的表象（我之前两次运行收到的收据条数不同）。

两个探针已回滚，`ideology_x1b_worker_test` 恢复原状（只剩门槛钩子三行），重新构建通过。下一步要查的是
worker 命令队列在 IDEOLOGY 域上的投递路径（`submit_ideology_commands` 的 worker-authoritative 分支
→ pod 命令队列 → 每日消费），这是那 7 个 worker fixture 的共同上游。

### 7.18 第十九轮：命令入队成功，但从未被应用

上一轮确认 discover 没有收据。这一轮把投递链逐段走了一遍：

1. `submit_ideology_commands` 的 worker 分支返回
   `{ "ok": true, "path": "IDEOLOGY_WORKER", "accepted": 1, "worker_shadow_mirrored": true }`
   —— 命令**确实进了 pod 队列**，不是被 `submit` 吞掉的。
2. `NativeSimulationHost::queue_ideology_pod_commands` 只做形状校验后入队，不按天过滤。
3. `RuntimeIdeologyPodAuthority::queue_command` 有一个**静默 dedup** 分支：
   `command.sequence <= producer_high_watermark(producer)` 时 `return true` 但**不入队**。
   这本来是幂等语义（同一条命令重复提交），但对"序号落后于已应用水位"的新命令来说就是静默丢失。
4. 给 fixture 换一条**独立 producer lane**（避开 annual reward / effect bridge 占用的 producer 1）
   后重跑：**没有变化**，仍是 slots=0。所以第 3 条不是本例的原因。

结论：命令入队成功、dedup 不是原因，那么丢失点在**队列入队之后**——pod 的每日计划没有把这些命令
应用掉。这与"大量 worker fixture 超时"是同一件事：这些世界里理念 pod 的每日阶段没有真正推进，
命令永远停在队列里，所以既没有回执也没有状态变化。

探针与 producer 实验已全部回滚，`ideology_x1b_worker_test` 恢复为只有门槛钩子三行。

### 7.19 第二十轮：x1b 的五个 fixture 侧假设全部排除

为了不重复劳动，把试过的都记下来（每次都是改完实测、无效即回滚）：

| 假设 | 依据 | 结果 |
| --- | --- | --- |
| 提交前先 `publish_ideology_worker_inputs()` | pod 可能还不知道目录/输入 | 无效 |
| 先 `_drive_days(1)` 让 grant 生效再 discover | gate/signal 位可能还没写 | 无效 |
| 换独立 producer lane（避开 producer 1 的水位） | `queue_command` 的水位去重分支 | 无效（仍 slots=0） |
| 每日补 `_service_runtime_liveness()` | 通过的 `save_worker_authority` 就这么做 | 无效 |
| `runtime_parity_forcing = false` | 通过用例常用 false | 无效 |

结论：这些 fixture 的失败**不能从 fixture 侧修**。已知事实是——提交返回
`worker_shadow_mirrored: true`、命令入队、但没有任何回执、状态也不变，说明 pod 的每日计划没有把
队列里的命令应用掉。要修就得动 `NativeSimulationHost` 的 ideology 阶段与
`RuntimeIdeologyPodAuthority` 的计划/应用路径，那是并行改动正在维护的核心。

### 7.20 第二十一轮：653 处未映射的性质（不是遗漏，是维度不匹配）

新增 `tests/ideology/ideology_incidence_unmapped_probe.gd`：它打开编译器里一个
**probe-only** 的收集槽（`debug_unmapped_keys`，生产为 `null`，不进目录字典所以不改哈希），
编译真实目录后把 653 条未映射按族群聚合。结果：

| 族群 | 条数 | 能不能映射 |
| --- | --- | --- |
| `country.output.terrain.*` | 72 | 需要"地形"维度，现有通道只有 国×部门×需求 |
| `country.research.society_efficiency` | 33 | 需要"研究领域"维度 |
| `country.ideology.point_gain_factor` | 30 | **不该映射**（不是材料收益） |
| `country.trade.speed_factor` | 27 | 只能近似到商贩收入 |
| `country.output.good.*` | 24 | 需要逐商品→部门的映射表 |
| `country.household.consumption_factor` | 24 | 需要"消费成本"维度 |
| `country.output.landform.*` | 21 | 同 terrain |
| `country.military.*`（wage/rule/organization/barracks…） | 60+ | 军事侧，通道里没有对应收入项 |
| `country.resource.<good>.managed_generation_factor` | 40+ | 只能近似到采掘部门 |
| `economy.profession.<job>.*` | 50+ | 需要"职业"维度（阶层份额是另一回事） |

**结论**：这 653 条的主体是**结构性缺口**——它们描述的是"地形/地貌/商品/职业/研究领域"这些现有
通道布局里不存在的维度，而不是编译器忘了分类。硬把它们近似到某个部门通道，会让立场变成
"看起来合理但来源错误"的数字，比留空更糟。

要真正提升区分度，需要扩展通道模型（例如给每个阶层加"自有部门份额"或引入商品维度），那是设计
层面的改动，不是补映射表。这条推翻了计划 §7.2 里"补覆盖是提升区分度第一手段"的乐观假设：
**能补的只剩零头，主体需要新维度。**

### 7.21 第二十二轮：holdout 卡 fixture 改为显式跳过

`x14 / x16 / country_ramp / school_strength` 四个 worker fixture 的唯一失败都是
"`<card>` absent from the compiled catalog"。查证后确认这不是回归：这四张卡
（`petition_box`、`land_value`、`progressive_tax`、`mandate_of_heaven`）就在
`ideology_content_test.EXPECTED_HOLDOUT_CARDS` 里——**它们被刻意排除在出货目录之外**。
给不存在的内容长期标红，下一个读者从中得不到任何信息。

改成显式跳过（保留可解析的 summary，而不是静默通过）：

```
SKIP petition_box: holdout card is not in the shipped catalog
=== ideology x14 worker: 28 checks, 0 failures ===
```

四例结果：`x14` 28/0、`x16` 15/0、`country_ramp` 5/0、`school_strength` 14/0。
跳过前各自还有 5–34 项检查在跑，所以不是"整例空转"。

判定口径：这类 skip 只用于**内容确实不在出货目录**的情形，且必须打印卡名与原因；卡只要还在目录里，
就不允许用跳过掩盖失败。

### 7.22 第二十三轮：`mechanism_matrix` 10 处失败全部清掉

两件事，都不是内容回退：

1. **cooperative 三处**：`idea.cooperative` 是 holdout，程序也随卡片一起不在出货目录里
   （`cooperative_l1` 在 `default_ideology_catalog.tres` 和 `default_ideology_effects.tres` 里
   出现次数都是 0）。按 §7.21 的口径改成显式跳过。
2. **军事程序七处 "has a CONST+EMIT program"**：这条断言要求 `instructions` 里同时有
   `CONST` 和 `EMIT_COMMAND`。实际内容是 `instructions` 只有 `CONST`，**发射写成可执行的
   `commands` 行**（`command_key = &"ideology.cell"`），运行时直接执行命令列表。
   断言只认指令形式，把接线正确的内容判成失败。改为"有 CONST，且 EMIT 指令**或** commands 非空"。

结果：`ideology_mechanism_matrix_test` 1150/10 → **1147 checks / 0 failures**。

### 7.23 第二十三轮（续）：`effect_scale_override` 3 处失败，含一个真 bug

1. **`ideology_synergy_definition.gd` 的去重键漏了 target**（真 bug）：

```gdscript
# 修改前
var row_key := "%d:%s:%d" % [match_kind, match_value, field]
```

两条改写**不同**程序的 override 行（`&"a"` 与 `&"b"`）会被判成重复。键里补上
`target_definition_key` 后，"两条不同目标都应通过"这条断言通过；同一目标的重复改写仍然会被拒
（那才是注释里写的意图："Scale rows of different magnitudes on one target would multiply twice"）。

2. **空目标的拒绝码**：现在报 `ideology_effect_parameter_match_value_missing`（更具体），
   断言只接受两种旧码。把新码加入可接受集合——它同样是拒绝。

3. **"out-of-band scale 被原生拒绝"之前是假通过**：测试篡改的是**遗留列**
   `synergy_override_scales`，而目录带 `match_kinds` 时原生读的是 `synergy_override_values`，
   篡改遗留列不产生任何影响。改成按目录实际的列去篡改后，原生校验
   （`value >= Q16/4 && value <= 4*Q16`）如期拒绝。

结果：20 checks / 0 failures。回归无碍（content 67/0、runtime 92/0、card_face 2101/0、
pool 20/0、opinion 22/0）。

### 7.24 第二十四轮：`cell_layer_e2e_realworld` 的前提本身是错的

这条 fixture 断言"真实生成世界里至少有一个国家拥有 >32 格"，失败时 `widest=1`。
查证后确认这不是回归，而是**前提错误**：

- 新生成的世界每个国家只有 1 格；领土靠 claim 增长。`ideology_cell_layer_realworld_over32_test`
  和 `ideology_d4_multi_cell_country_test` 就是专门**主动长地**的用例（前者注释里明确写了
  "widest=1 是测量假象，不是没有产量"）。
- 在 e2e 这条里直接断言 `widest > 32`，测的是 bootstrap 状态，与地块层正确性无关，**永远不可能过**。

改成校验这条 fixture 真正能负责的契约（两个读者一致、总数与地图相符），并打印实测值；增长本身
留给 D4/over32。结果：10 checks / **0 failures**。

顺带记录一个**没修成**的：给 `d4_multi_cell_country` 补 `sync_country_territory_to_map()`
（over32 就是这么做的）之后，同步确实报 `ok=true cells=40000`，但
`get_country_territory_counts()` 仍报 `3 国 / widest=1 / total=3`——说明 48 次被接受的 claim
根本没有进入国家运行时的 CSR，不是读取时机问题。该改动已回滚，D4 的 1 处失败保持原状。

### 7.25 第二十五轮：`gate_chain` 的 `cells=0` 不是标签问题

之前的判断是"`cell.settlement` 依赖经济提交才发布的 `cell.population`，所以匹配不到"。这轮直接
把标签摘掉验证（`target_selector_param[1] = 0` = 不做标签过滤，own-territory 应命中全部 12 格）：

**结果仍然是 `cells=0`。** 而且同一 fixture 里后两条断言
（实例数 == 目标数、每格两条命令）在 `cells=0` 时是**空真**通过的，所以它们一直没有提供信息。

结论要修正：`cells=0` 不是"标签匹配不到"，而是**这张卡根本没有产生任何 Effect 实例**——门槛链在
选择器之前就断了。摘标签的改动已回滚（`ideology_gate_chain_test` 恢复 50 checks / 1 failure）。

这条同时暴露一个测试设计问题：用 `cells` 当基准的三条断言，在 `cells=0` 时会连锁变成"0==0"。
下次改这里应把第一条断言改成硬前置（`cells > 0` 先失败并中止），避免下两条空真掩盖问题。

### 7.26 第二十六轮：`m0_realworld_cost` 的 4 处失败是已知经济缺陷的下游

§7.16 我把这条归因成"经济日跑不完 → 意见快照缺失"。这轮按"直接证伪"的方式看日志，看到了真正
的致命行：

```
[economy-fatal] day=4 stage=aggregate_publish reason=money_conservation_failed
```

经济**确实在跑**，只是第 4 天在 `aggregate_publish` 阶段因**货币守恒失败**而致命。这正是 fixture
自己注释里写的既有缺陷（"The economy dies at day 4 with `money_conservation_failed`(a pre-existing
defect recorded in M0-7c)"）。三条 tier 各要 8 天，任何一条都跨过第 4 天，所以四条断言必然全灭：

```
FAIL loaded A (2000 cells): economy still healthy
FAIL loaded B (2000 cells): economy still healthy
FAIL idle (no cards): economy still healthy
FAIL both tiers produced samples
```

试过让它在这种情形下打印显式 SKIP 并 exit 0（保留"缺陷修好后自动恢复断言"的写法），但 flag 分支
没有按预期触发（SKIP 行打出来了、汇总行没出来、进程还继续跑了 forensics dump），已整体回滚到 HEAD
并重新加回门槛钩子，fixture 恢复 4 处失败原状。

结论：这 4 条不是理念/地块层的问题，是 M0-7c 经济缺陷的直接后果；修它要先解决货币守恒。

### 7.27 第二十七轮：权威基线（全部独占运行，无超时）

第 21 轮基线是 71 通过 / 24 失败 / 5 超时。经过第 22–26 轮的修复，独占重跑 100 个文件：

| | 第 21 轮 | **第 27 轮** |
| --- | --- | --- |
| 通过 | 71 | **79** |
| 真实失败 | 24 | **21** |
| 超时/无 summary | 5 | **0** |

变化来自：`mechanism_matrix` 10、`card_face_semantics` 11、`effect_scale_override` 3、
`cell_layer_e2e_realworld` 1、四个 holdout fixture、`pool_mechanics`、`draw_flow` 等。
超时归零说明之前那批 `TIMEOUT` 多数是**串行跑时的资源竞争**，单独跑能完成（`x5` 15/2、
`x6b` 12/1、`x6c` 17/1 现在都给得出 summary）。

**剩余 21 个文件的构成**：

- **worker pod 不应用命令（17 个）**：`card_content_worker`、`scalar_worker`、`social_media`、
  `parity`、`derived_pump`、`managed_lifecycle`、`restart_mask`、`x1b`、`x12`、`x13a`、
  `x3b_cards`、`x5`、`x6a`、`x6b`、`x6c`、`x8`、`x9a`、`x9b`。
- **非 worker（4 个）**：`m0_realworld_cost`（M0-7c 货币守恒缺陷）、`d4_multi_cell`（claim 不落
  CSR）、`gate_chain`（卡片不产生实例）。

这三类都不在材料支持模型范围内，需要 pod 计划路径、经济守恒或国家领土提交的修复才能推进。

### 7.28 第二十八轮：命令其实被应用了，卡在 ACK 链（拿到授权后首次深入 pod）

拿到"可以改 pod"的授权后，在 pod 计划路径上加了临时探针（`queue_command` 入库、每日 drain、
plan 的消费位点、水位跳过），跑 `ideology_x1b_worker`，输出把整条链摊开了：

```
[pod-queue] op=1 seq=1 producer=1 day=7 size=1     ← discover 入队（第 7 天）
[pod-drain] day=7 swapped=1                        ← 当天被 drain 到 pod
[pod-plan] day=7 cmds=1 cursor=0 round=7 committed=6  ← 被消费（无 skip、无 wait）
[pod-queue] op=5 seq=2 producer=1 day=9 size=1     ← equip 入队（第 9 天）
[pod-plan] day=9 cmds=1 cursor=0 ...               ← 同样被消费
... 之后 pod 一路推进到 day=14，slots 始终是 0
```

**结论必须修正**：前几轮我判断的"命令入队后从未被应用"是错的——两条命令都被 drain、都被 plan
消费、都没有触发水位跳过。真正没发生的是**装备转移的结算**：equip 建立了 pending transition，
而它需要 Effect/Modifier 的 ACK 才会落到槽位；ACK 一直没回来。

这也解释了"discover 有时有收据有时没有"：收据在 `plan_day` 里按消费顺序写入，而收据数组是
per-day 的，测试读到的窗口不同就会看到不同的条数。

同一轮还测了另一件事：把 fixture 的等待上限从 20s 提到 180s，pod 能推进到 day=14，`slots` 仍是 0
——**不是等得不够久**。该改动已回滚。

探针全部移除（`fprintf`/`cstdio` 计数归零），重新构建通过，`ideology_runtime_test` 复跑 92/0。

**下一步**（真正需要改 pod 的地方）：查 equip 建立的 pending transition 在
`ideology_modifier_bridge_active()` 分支下的 ACK 回传路径——`_ideology_modifier_inflight`
把转移留在 worker 内，等 Modifier pod 应用其 rows 后回 ACK；这条回传在这个世界里没有发生。

### 7.29 第二十九轮：ACK 链的缺口在"修饰符阶段从没拿到行"

按 §7.28 的线索往 ACK 链上查，读到的结构是：

1. 理念阶段把转移留在 `_ideology_modifier_inflight`（`ideology_modifier_bridge_active()` 为真时）；
2. `stage_ideology_modifier_commands()` 把 inflight 的行批量塞进 `_ideology_day_modifier_batches`，
   并把 `submitted` 置 1；
3. 修饰符阶段消费这些 batch，应用后调 `settle_ideology_modifier_acks(batch_ok, committed)`
   生成 ACK。

给第 2 步插了每日常量探针，x1b 的结果是：

```
[mod-stage] day=1..7 bridge=1 inflight=0 loose=0 configured=1 mask=0xfff
```

- `bridge=1`：worker 桥接是**生效**的（不是走进了 GDScript 分支）；
- `inflight=0`：理念阶段**从来没有把转移登记进来**；
- 世界在第 7 天之后就不再推进（探针只到 day=7，即使把等待上限提到 240s 也一样）。

也就是说：equip 之后图谱卡在一个**跨域硬屏障**上，理念阶段不再运行，修饰符阶段自然拿不到行、
也就发不出 ACK——两边互为前提。这与"命令没被应用"是两件事，也和"等得不够久"无关（240s 仍然停在
同一天）。

**尚未确定的部分**：这个屏障是谁立的。候选是理念阶段发布的 intent 等待 Effect 侧消费，而 Effect
侧的消费依赖图谱推进——需要在屏障处打断点/加计数才能定论。因为**原因还不够确定**，本轮没有改任何
行为代码；探针与等待上限的改动全部回滚，重新构建通过。

### 7.30 第三十轮：找到并修掉一个真实的测试侧 bug（序列被水位吞掉）

第 29 轮卡在"equip 后图谱停在 day 7"。这轮把屏障的数字看全了：

```
[runtime-day-wait] day=7 missing=0x4 stall=0x6 country=country_worker_peer_results_pending
[day-stall-fault] day=7 stall=0x6 peer_ms=5007 code=country_worker_peer_stall_timeout
WARNING: [runtime-worker] FAULTED code=country_worker_peer_stall_timeout
```

worker 整体 **FAULTED**（country peer 5s 超时），理念 pod 随之停摆。用运行时开关
`PK_PEER_STALL_TIMEOUT_MS=60000`（注册表里明确写着"测试机可调大"）避开故障后，世界能继续推进，
失败重新变成"discover 被拒"，收据是：

```
st=[3, 3]  rs=["ideology_discovery_not_allowed", "ideology_unknown"]
```

**根因**（`ideology_x1b_worker_test.gd` 自己的 bug）：

```gdscript
var _next_sequence := 1          # 本 fixture 的命令从 1 开始编号
...
var sequence := 900000           # 但发放门槛用的是 900000 起的号段
```

pod 对每个 producer 维护已应用水位，`sequence <= 水位` 的命令**静默不入队**。发放门槛把水位推到
900000 之后，fixture 自己的 discover(1)/equip(2) 全被判为陈旧丢弃——而发现被丢弃后，equip 自然
是 `ideology_unknown`。

修法两步：
1. fixture 自己的序列从 **1000000** 起（高于发放号段）；
2. 发放门槛之后先 `_drive_days(1)`，让门槛真正落地再发 discover。

结果：**discover 与 equip 都成功，卡占用了槽位**，检查数 16 → 20，失败点从"没占槽"前移到
"逐源加成没生效（got 1.00000 / expected 1.10000）"与"卸下没有释放槽位"——也就是 §7.29 那条
修饰符/ACK 链。这一轮修的是一个**确定性 bug**，不是猜测。

### 7.31 第三十一轮：修饰符行确实落地并 ACK，但表达不了"地块"作用域

续 §7.30 继续插探针（plan 输出、修饰符阶段、ack），拿到完整的一天：

```
[pod-plan-out] day=9 rows=1 intents=1 consumed=1 completed=1   ← equip 产出一行 + 一个 intent
[mod-stage]    day=9 bridge=1 inflight=1 loose=0               ← 行被登记
[mod-ack]      settled=1 committed=1                           ← 修饰符阶段应用并回 ACK
```

链路是通的。但 fixture 读目标地块仍是 `1.00000`（`source_count_evaluations=4`，说明派生的
source-count 采样确实跑了）。看行结构就明白了：

```cpp
struct RuntimeIdeologyPodModifierRow {
    uint64_t transition_id, country_handle;
    uint32_t country_generation;
    uint16_t opcode, domain;
    uint64_t definition_key_hash, source_id;
    int32_t magnitude_q16;
    uint32_t ordinal;
    int64_t effective_day;
};
```

**这个结构里没有 cell/scope 字段**。理念 pod 的修饰符行只能表达"国家级"作用域，而
`iron_smelting` 的程序是 `SEL_NEIGHBORS_R1`（地块级）——行被应用到了国家作用域，fixture 用
cell 作用域 `evaluate_modifier_stat(..., 0, cell, ...)` 去读，自然读到 1.0。

这是**能力缺口**而不是 bug：要把地块作用域带过 POD 边界，需要给行加 scope/scope_id 并让
`make_command` 透传。这属于功能扩展，不是"原因确定就可以改"的范畴，本轮没有动。

探针已全部移除、重新构建通过；`x1b` 稳定在 20 checks / 2 failures（占槽已通，取值与卸下未通）。

### 7.32 第三十二轮：worker 侧 EFFECT 的 intent 消费者不存在（代码注释就是契约）

上一轮判定"修饰符行没有地块作用域"。这轮找到了更上游的解释——看
`world_runtime_daily_adapter_part2.gd:353` 的脚本消费者：

```gdscript
if (granted_mask & 0x020) != 0:
    # EFFECT belongs to the worker: it ACKs in-worker, and a second reply from
    # here would report a commit nobody verified.
    return
```

x1b 的 mask 是 `0xfff`，**EFFECT 在 worker 上**，所以脚本这条路径**主动让位**，把 ACK 交给
"worker 内的 EFFECT"。但全仓搜索 `poll_ideology_pod_intent` 只有两处：

- `native_simulation_host_ideology.cpp:650`（队列出队）
- `world_ext_ideology.cpp:369`（给 GDScript 的绑定）

**没有任何 C++ 消费者**。也就是说：当 EFFECT 归 worker 时，脚本按契约退出，而本该在 worker 内消费
intent 并回 ACK 的那段实现并不存在。

这就同时解释了两件事：

1. intent 里带着 `target_handle`（地块），但没人消费 → 地块级效果永远不落地；
2. 唯一真正落地的行是走修饰符桥的国家级行（§7.31），所以 fixture 读到 1.0。

**修法有两条，都超出"改一个错误"的范畴**：
(a) 给 pod 修饰符行补 scope/target（行是每模板一行，要支持地块得改成每目标一行，涉及模板、行、
命令、目录编译四层）；
(b) 在 worker 内实现 EFFECT 侧的 intent 消费者（出队 → 按 `target_handle` 应用 → 回 ACK），
补上注释所承诺的那段。

本轮没有动其中任何一条：这是功能实现，不是修 bug。文档留档，等排期。

### 7.33 第三十三轮：边界在"pod 拿不到地块标签"，不是缺一行代码

继续追 §7.32 的两条修法，先确认"能不能让行带地块"这件事到底卡在哪。三处证据合起来给出结论：

1. **修饰符命令被硬编码成国家作用域**（`native_simulation_host_ideology.cpp:1060`）：

```cpp
command.scope = 2; // ENTITY: the country handle
command.entity_handle = row.country_handle;
```

2. **intent 里没有地块信息**：`plan.intents` 是"每转移一个"，`target_handle` 就是国家句柄
   （`runtime_ideology_pod.cpp:904`），`payload` 只有理念 id / 目标等级 / 目标位置 / 已进入等级。
   所以即使把 intent 的 target 透传给命令，也只能得到国家。

3. **pod 有领土但没有地块标签**：`RuntimeCountryPodSnapshot` 里有 `cell_country_slot`、
   `territory_offsets/territory_cells`、`capital_cell`——**归属有，标签没有**。而
   `iron_smelting` 的 `SEL_NEIGHBORS_R1 + cell.produces.iron_ore` 恰恰需要逐格标签。

所以 worker 侧"能把行落到哪一格"的问题是：**归属能算、筛选条件算不出来**。要在 pod 内展开
地块级效果，必须把地块标签表也送过 worker 边界——这是一次输入契约扩展（新增一份 cell→tag 位图
并纳入快照哈希），不是补几行。

这条把之前三轮的猜测收敛成了一个明确的设计缺口，也解释了为什么国家级效果（修饰符桥）能落地、
地块级效果始终不能。本轮没有改任何行为代码；文档留档。

### 7.34 第三十四轮：`d4` 的 claim 提交后没有任何国家收据

按"先拿数字"的办法查 `d4_multi_cell_country`（claim 不落 CSR）。给 fixture 加了临时诊断，读
`poll_country_command_receipts(0, 128)`：

```
[d4] claim attempts: accepted=48 rejected=22
[d4] country day advances completed: 3 (last_error=)
[d4] country receipts count=0          ← 一条收据都没有
[d4] after: countries=3 widest=1
```

`accepted` 只代表"提交成功"（命令是 staged 的），而三天推进后**国家侧一条收据都没产生**。对照
`ideology_cell_layer_realworld_over32_test`（同样的 `run_country_slice` 驱动、同样的
`submit_country_commands(TRANSFER_TERRITORY)`，它是绿的），差别只在命令内容与选区：
over32 提交的是相邻格 transfer，d4 是"从己方格里向外按偏移扫描"的 claim。

也试过把 claim 的 `effective_day` 从 1 改成 3（对齐 over32 的提交日），收据数仍是 0——不是
"命令过期被丢"。

诊断代码已回滚（`d4` 恢复为只有门槛钩子三行），因为 `poll_country_command_receipts` 本身也可能
按 `request_id > 0` 过滤，而这个读数不足以定论。**下一步**应看
`submit_country_commands` 在 claim 分支上是否真的入队（对照 transfer 分支），这需要读
`world_ext_country.cpp` 的两个 opcode 处理。

### 7.35 第三十五轮：权威基线与阻塞点清单

独占重跑 100 个文件（带 `PK_PEER_STALL_TIMEOUT_MS=60000`，避免 worker 因 5s 超时整体 FAULTED）：

| | 第 27 轮 | **第 35 轮** |
| --- | --- | --- |
| 通过 | 79 | **79** |
| 真实失败 | 21 | **21** |
| 超时/无 summary | 0 | **0** |

第 30 轮修掉的 x1b 序列 bug 让该 fixture 的检查数从 16 涨到 20（占槽已通），但它仍卡在地块作用域
（§7.33），所以通过数没变。

**21 个失败只依赖三件事，全部需要设计层决定**：

1. **pod 缺 cell→tag 位图**（约 6 个：`x1b/x12/x13a/x3b_cards/x9a/x8` 一类的地块级效果）。
   证据：`make_command` 硬编码 `scope = 2`；pod 输入只有领土归属、没有地块标签。
2. **M0-7c 货币守恒缺陷**（`m0_realworld_cost` 4 条）。证据：`[economy-fatal] day=4
   money_conservation_failed`。
3. **国家 claim 分支**（`d4_multi_cell` 1 条）。证据：48 次 claim 提交成功但国家侧收据数为 0。

其余（`card_content_worker`、`gate_chain`、`scalar/social_media/parity/derived_pump/
managed_lifecycle/restart_mask/x5/x6a-c/x9b`）都落在这三条的上游或同一 worker 图形里。

### 7.36 第三十六轮：可行性复核（两处判断被修正）

**修正一：country pod 状态是存档的一部分。** 上一轮我说 `RuntimeCountryPodSnapshot` "不落存档"，
依据是文件名里带 persist/save/codec 的都没有引用。这轮发现 `runtime_country_pod.cpp:1546-1584`
就是它的**存档段编解码**（`COUNTRY_SECTION_MARKER/ABI` + 逐字段 `append_vector`）。所以"给 pod
加地块标签"会改存档格式，不是纯内存变更。**上一轮那句判断作废。**

**修正二：pod 的修饰符模板里没有选择器信息。**

```cpp
struct RuntimeIdeologyPodModifierTemplate {
    uint64_t definition_key_hash;
    int32_t domain;
    int32_t magnitude_q16;
};
```

没有 selector kind、没有 tag id。所以要让 pod 展开地块级效果，除"输入加标签"外，**还要给编译出的
pod 目录加列**（GDScript 编译器 → pod 目录）。这就是四层：目录列 + 输入位图 + 逐格展开 + 命令
作用域。工作量比我上轮估计的更大。

**另有一处尝试并回滚**：给 18 个 worker fixture 在 `_init` 里加
`OS.set_environment("PK_PEER_STALL_TIMEOUT_MS", "60000")`，希望消除 worker 整体 FAULT 的抖动。
实测**无效**（x1b 仍报 2 次 FAULTED、回到 16 checks）——该开关必须在**父进程启动 Godot 之前**
设置（`$env:PK_PEER_STALL_TIMEOUT_MS`），fixture 内设置不生效。18 个文件已全部回滚。

**结论**：worker 用例要在稳定的环境下跑，必须由**运行器**带
`PK_PEER_STALL_TIMEOUT_MS=60000` 启动；这也解释了同一个 fixture 在不同批次里 checks 数会变
（有 FAULT 就走不到后面）。

### 7.37 第三十七轮：`d4` 的"0 收据"是读数错位，不是缺收据

查 `poll_country_command_receipts` 的实现（`world_ext_country.cpp:310`）：

```cpp
_runtime_host->poll_country_command_receipts(after_request_id, limit, receipts);
```

它读的是 **host 队列的回执环**。`d4` 用的是同步 `ext.submit_country_commands(batch)`（没有
worker 域授权），命令直接落到 country runtime，**根本不经过 host 队列**——所以收据数必然是 0。
上一轮把 `count=0` 当作"命令没入队"的证据是**错的**，这条作废。

同时确认 claim 与 transfer 在批处理里是同一段代码（`country_runtime.cpp:3586-3613`），唯一差别是
claim 要求 `old_owner == NEUTRAL_SLOT`：

```cpp
if (command.opcode == COMMAND_CLAIM_UNOWNED_TERRITORY &&
    old_owner != NEUTRAL_SLOT) { error = "country_claim_target_not_unowned"; break; }
```

也就是说 claim 本身没被特殊对待，`ok=true` 同步返回就意味着已应用。那 `d4` 的 `widest=1` 就只能
是**读数平面**的问题：它读 `get_country_territory_counts()`（经济纪元平面），而
`ideology_cell_layer_realworld_over32_test` 读的是国家运行时的 CSR + `sync_country_territory_to_map()`
之后的口径，后者是绿的。补 sync 无效说明经济平面要**新纪元**才刷新。

结论：`d4` 剩下的 1 条属于"经济纪元刷新时机"，不是 claim 逻辑缺陷。**这一项也从"可能一次修好"
里划掉**，归到需要排期的清单。

### 7.38 第三十八轮：`d4` 转绿——读错了平面

上一轮推断"经济纪元刷新时机"，这轮直接量了两边：

```
[d4] scan: countries=3 widest=49 total=51 slots={ 0: 49, 2: 1, 1: 1 }
[d4] after: countries=3 widest=1  above_old_cap=0  total=3
```

**同一个世界里，逐格读所有权是 49 格，经济平面读出来是 1 格。** 48 次 claim 全部落地了，是
`get_country_territory_counts()` 这个读者没刷新（它的注释里也写着只在纪元开合时更新）。

修法：`after` 改用权威的逐格所有权副本（`capture_country_runtime_snapshot()` +
`get_country_cell_summary()` 逐格统计），也就是 `over32` 一直在用的那个读者；`before` 保留平面读数
（它的语义是"生成时每国 1 格"，平面读数足够）。

**结果：`ideology_d4_multi_cell_country_test` 9 checks / 0 failures。** 回归无碍
（e2e 10/0、runtime 92/0、content 67/0）。

这也解释了为什么我前面"补 sync 无效"：`sync_country_territory_to_map()` 同步的是地图镜像，
不是这个读者用的副本；正确的刷新入口是 `capture_country_runtime_snapshot()`。

### 7.39 第三十九轮：`x9b` 4 → 1，reason 就在收据里

按 d4 同款"先拿读数"的办法查 `x9b_family_target_worker`（22 checks / 4 failures）。给它加了两个
临时打印：装备快照与收据。

```
[x9b] equip submit={ "ok": true, "path": "IDEOLOGY_WORKER", "worker_shadow_mirrored": true }
[x9b] st=[2, 3]  rs=["", "ideology_support_threshold_not_met"]  ops=[1, 5]
[x9b] slots=0 loc=[0] known=[42] pending=[0]
```

命令**入队了、被消费了、被支持门槛拒了**（`ideology_support_threshold_not_met`）。也就是说这三条
失败（+6% 输出没生效、没有 ENTITY 行、槽位为空）是同一个原因：装备根本没成功，全被门槛挡住。

修法就是给这个 fixture 加门槛钩子（它测的是家族目标，不是门槛）：

```gdscript
IdeologyCatalog.support_gate_enabled = false
```

**结果 4 → 1**，只剩 "applying the family target advances the family revision 2 -> 2"。这条是
effect-input 版本号契约，和门槛无关，留待下一轮。

顺带把同样的钩子复测到另外六个 worker fixture（`x3b_cards / x9a / x8 / x6a / x6b / x6c`）：
**全部无变化**（x3b_cards 6→6、x9a 6→6），已全部回滚，只在 `x9b` 保留。

### 7.40 第四十轮：`derived_pump` 的 8 条全部源自"worker 腿的 equip 没落地"

`ideology_worker_derived_pump` 是失败最多的一条（55 checks / 8 failures），但 8 条全部挂在第一条上：

```
FAIL W: idea.public_hygiene is live (location=1) :: location=0 last_error='' snapshot_levels=[0]
```

其余七条（层未安装、generation 0→0、首装日 -1、9.3 时点、幅度、两条 PARITY）都是"层没安装"的下游。

加探针读了两处的差别，这是本轮最有价值的一组数：

| 腿 | equip submit |
| --- | --- |
| W（worker） | `{ ok, path: IDEOLOGY_WORKER, accepted: 1, pending: 0, mirrored: true }` |
| S（主线程） | `{ ok, accepted: 1, pending: 1, mirrored: true }` |

W 腿 `pending: 0` 说明命令只是入队（异步），而**它始终没有产生收据**——收据里只有
`ops=[2,1,8]`（授点/发现/理解）三条，全部 SETTLED，没有 `op=5`。S/M 腿 `pending: 1` 则当场就建了
转移。

也就是说：主线程腿一路正常，worker 腿的 equip 命令**入队后没有被消费**。这和 x1b 的形态不同
（x1b 的 equip 是被消费后才被门槛拒），所以不是同一个原因。没有 fault、没有 budget 提示，进程是
正常跑完的。

探针已回滚，`derived_pump` 只剩门槛钩子三行。**这条留给下一轮**：需要看 W 腿的
`_drive_day` 是否真的推动了 ideology pod 的日（x1b 会 `service_country_worker_peer_adapter` +
等 `ideology_pod_committed_day`，这里没有）。

### 7.41 第四十一轮：`derived_pump` 的 equip 根本没进 pod 队列

按上一轮的计划，先在 fixture 里量了 pod 的提交日与快照状态：

```
[W] diag pod_day=9 tick=10 pending=[0] loc=[0] known=[95] state=PAUSED
```

pod 已经推进到第 9 天、卡也已知（`known=[95]`），但没有待结算的转移。接着在原生侧给
`plan_day` 的 COMMANDS 阶段加了每日一行探针（`day / 队列长度 / 消费位点`）：

```
[pod-cmds] day=2 n=0  cur=0
[pod-cmds] day=4 n=3  cur=0     ← 前言三条（授点/发现/理解）
[pod-cmds] day=6 n=1  cur=0
[pod-cmds] day=7 n=0  cur=489626271744   ← 位点是个荒谬值
[pod-cmds] day=8..27 n=0 cur=0
```

**equip 从来没有出现在队列里**（提交时 `worker_shadow_mirrored: true`，但 `n` 从未因它 +1），
而且 day=7 的消费位点出现了 `489626271744` 这种越界值——两者都指向 pod 状态被写坏，不是"命令被拒"。

探针已全部回滚（`fprintf`/`cstdio` 计数归零），重新构建通过；`derived_pump` 只剩门槛钩子三行。

**下一步**：`489626271744 = 0x7200000000`，高位像某个 id 被当成位点写进去了。要在
`commit_day` / `plan_day` 的 `state.command_cursor` 赋值处加断言（`cursor <= commands.size()`），
把越界写点定位出来——这类断言本身也值得留在代码里。

### 7.42 第四十二轮：equip 确实入队并被消费，缺的还是 ACK

上一轮的"equip 没进队列"是**探针读数不全**——当时只看到 `n` 的值，没有排队瞬间。这轮在
`queue_ideology_pod_commands` 里加了一行入队打印，三条腿的完整序列就出来了：

```
[pod-queue] op=2 seq=2  day=4 size=1     ← 授点
[pod-queue] op=1 seq=3  day=4 size=2     ← 发现
[pod-queue] op=8 seq=4  day=4 size=3     ← 理解
[pod-queue] op=5 seq=5  day=6 size=1     ← equip（第一条腿）
... 第二、三条腿同构，equip 分别是 seq=10 / seq=15
```

**equip 入队了，也在 day=6 被消费了。** 结合上一轮的
`[pod-cmds] day=6 n=1`（消费 1 条）与 `pending=1`（主线程腿当场建转移），可以确定：
worker 腿的 equip 建了待结算转移，但**没有人回 ACK**，所以 `location` 永远不变成 1（
`_location_of` 在 pending 时返回 -1/0）。S/M 腿能过，是因为 fixture 自己扮演 acker 做了
`poll → preflight → commit → ack`。

这与 §7.32 是**同一个缺口**：EFFECT 归 worker 时，脚本消费者主动让位，而 worker 内的 intent
消费者并不存在。

本轮还留了一处**永久不变量**（不是探针）：

```cpp
if (state.command_cursor > state.commands.size() ||
    state.pending_cursor > state.commands.size()) {
    error = "ideology_pod_cursor_out_of_range";
    return false;
}
```

越界的位点会让整个会话跳过所有待处理命令，表现就是"命令凭空消失"。这条守卫让它在第一现场变成
具名错误。构建通过，`ideology_runtime_test` 92/0。

### 7.43 第四十三轮：`derived_pump` 8 → 0（又是"镜像没刷新"）

上一轮确认 equip 入队、被消费、ACK 也为 OK。这轮顺着 ACK 一路读到写入点：

```
[ack-apply] pend=1 tid=1667…962 rid=1434…794 day=6      ← ack 与待结算转移完全匹配
[ack-ok]    idea=95 loc=1 desired=1 lvl=0                ← pod 把 location 写成 1（IDEOLOGY）
```

**pod 的状态是对的**，但 fixture 通过 `get_ideology_snapshot` 读到的还是 `loc=[0]`。也就是说：
worker 侧已经把卡装上了，**主线程镜像没有刷新**——和 `d4` 是同一类"读错平面"，只是这次错在
"读的镜像过期"。

修法（fixture 侧，一行）：

```gdscript
if w["host"].has_method("_service_runtime_liveness"):
    w["host"]._service_runtime_liveness(Time.get_ticks_usec(), false)
```

放在"等到 pod 提交日"之后——那是**每帧 UI 都会跑的交接入口**，等 pod day 只证明 worker 提交了，
不证明镜像看到了。

**结果：`ideology_worker_derived_pump` 55 checks / 8 failures → 55 / 0。**

顺带把同一个交接补到 `ideology_worker_authority_parity_test`：3 → 1。剩下的那条是 fixture 自己
声明的 **FINDING**（"39 张卡在线，但 worker 世界的派生 front 一格都没覆盖，按实测记录"），属于
已知产品缺口，不是测试错误。

回归：content 67/0、runtime 92/0、e2e 10/0、d4 9/0。`x9b` 在 1～3 之间抖动（家族版本号那条与
时序有关），需要单独再查。

### 7.44 第四十四轮：把"镜像交接"推广到 8 个 worker fixture

上一轮在 `derived_pump` 里发现"等 pod day ≠ 镜像已刷新"。这轮把同一处交接
（`host._service_runtime_liveness`）加到其余 8 个 worker fixture 的日循环里（紧跟
`_wait_pod_day(...)` 之后）：

| fixture | 之前 | 现在 |
| --- | --- | --- |
| `x6a_worker` | 7 / 1 | **10 / 0** |
| `social_media_worker` | 21 / 1 | **32 / 0** |
| `x5_worker` | 15 / 2 | 15 / 1 |
| `x12_worker` | 42 / 2 | 42 / 2（无变化） |
| `managed_lifecycle` | 13 / 1 | 13 / 1（无变化） |
| `x6c_worker` | 17 / 1 | 17 / 1（无变化） |
| `x6b_worker` | 12 / 1 | 12 / 1（无变化） |
| `scalar_worker` | 29 / 1 | 22 / 1（失败点换成"卸下未释放槽位"） |

两个新转绿（`x6a`、`social_media`）。`scalar` 的检查数下降不是退化：它现在的失败点是**卸下**路径
（`unequip releases the slot`），说明装备已经通了、后面的清理还没通。`restart_mask` 没有
`_host` 成员，没打补丁。

回归：runtime 92/0、content 67/0、card_face 2101/0、derived_pump 55/0、d4 9/0。

### 7.45 第四十五轮：权威基线 82 / 18

独占重跑 100 个文件（带父进程 `PK_PEER_STALL_TIMEOUT_MS=60000`）：

| | 第 27 轮 | 第 35 轮 | **第 45 轮** |
| --- | --- | --- | --- |
| 通过 | 79 | 79 | **82** |
| 真实失败 | 21 | 21 | **18** |
| 超时/无 summary | 0 | 0 | **0** |

新转绿的四个：`ideology_worker_derived_pump`（55/0）、`ideology_social_media_worker`（32/0）、
`ideology_x6a_worker`（10/0）、`ideology_d4_multi_cell_country`（9/0）。

剩余 18 个：

- **内容/经济既有缺陷（3）**：`card_content_worker` 3、`m0_realworld_cost` 4、`gate_chain` 1。
- **fixture 自声明的 FINDING（1）**：`worker_authority_parity` 的"worker 世界派生 front 覆盖 0 格"。
- **worker 其余（14）**：`scalar`(1)、`managed_lifecycle`(1)、`restart_mask`(2)、`x10`(2)、
  `x12`(2)、`x13a`(3)、`x1b`(2)、`x3b_cards`(6)、`x5`(1)、`x6b`(1)、`x6c`(1)、`x8`(1)、
  `x9a`(6)、`x9b`(3，抖动 1–3)。

### 7.46 第四十六轮：`x9a` 转绿（整例都是 holdout 卡）

`ideology_x9a_worker` 的 6 处失败逐条读下来，全是同一件事：

- `ancestral_hall / clan_fields / family_enterprise / merchant_houses` 都**在 holdout 清单里**；
- 它们的分支用的是复合标签（`cell.eminent_clan&cell.sector.agriculture`、
  `cell.clan&cell.diversified` 等），这些标签来自 holdout 卡的编译程序，**出货目录里不存在**；
- 于是 `set_cell_tag_override_for_test` 报 `cell_tag_override_rejected`，`_dense_card` 报
  "not published"——两个症状同一个根。

按 §7.21 的口径给这五段加 `_skip_if_holdout(card)`（打印卡名与原因，不出红）：**199/6 → 50/0**。

顺带把 `x3b_cards` 里 cooperative 那一段也 guard 掉（cooperative 同样是 holdout）：6 → 5。
它剩下的 5 条是 trade_unions 的**条件求值**问题——见下。

### 7.47 第四十七轮：剩余四例逐条定性（都不是 holdout 类）

| fixture | 失败 | 定性 |
| --- | --- | --- |
| `x10` | 2 | `v10_technology_gate` 期望值差 0.01（1.00999）；"local card releases its slot" 是卸下未释放 |
| `x13a` | 3 | `T4 save schema is 60` 落后于当前 **62**；另两条 `[]` 的标签（dry-spell / cold）没产生 |
| `restart_mask` | 2 | flip 后 `location=-1`（卡丢失），与 §7.29 的状态路由同族 |
| `x8` | 1 | `bronze_casting occupies an ideology slot` 未占槽 |

**`x13a` 的 T4 有一部分是真问题**：把 canary 从 60 改到 62 之后，后面的断言继续失败——

```
FAIL T4 resave remains schema 58
FAIL T4 schema-56 stream migrates  {"ok": false, "reason": "save_chunk_record_count_mismatch"}
```

也就是说**旧档迁移路径已经跟不上当前 schema**：`schema-56` 的遗留流在现在的读取器下报
`save_chunk_record_count_mismatch`。这条 canary 的 60/58/56 三个数字是同一段契约的一部分，
需要同时更新并确认迁移语义（是否要为老档补 incidence 两列），属于存档契约的 owner 决定。
本轮把 62 的改动**已回滚**，避免只改一半把 canary 变成"半新半旧"。

### 7.48 第四十八轮：`x13a` 的迁移 canary 需要按当前布局重算

读了 `x13a` 的 T4 与 `_downgrade_cells_to_schema56()`，把它的假设摊开了：

```gdscript
var schema56_record_bytes := record_bytes - 9   # 56 的每条记录比当前少 9 字节
...
chunk.encode_u16(4, 56)                          # 改版本号 + 截短记录
```

它有三处硬编码与当前状态不符：

1. `save schema is 60` —— 当前是 **62**；
2. `resave remains schema 58`（标签写 58、断言 60）—— 同一处；
3. `record_bytes - 9` —— 这个 9 是 X13a 那两列（dry streak / days since hazard）的字节数，
   如果 61/62 又在**地块记录尾部**加了列，差值就不是 9，于是截短后的记录数与读取器期望不符，
   报 `save_chunk_record_count_mismatch`。

第 3 条不能靠猜：必须对着 `economy_runtime_persistence_read.cpp` 的地块记录读写逐列核对，
确认 61/62 是否动了地块记录、以及迁移到 56 时应该截掉多少。这是存档契约的 owner 活，不是测试口径
能绕过的。本轮**没有改** `x13a`（半新半旧的 canary 比落后的 canary 更危险）。

顺带确认：读取器本身是 `schema >= N` 的阶梯式迁移（`economy_runtime_persistence_read.cpp:176+`），
旧档按缺失字段取默认值——**迁移机制没坏，是 canary 的数字过期**。

### 7.49 第四十九轮：`x8` 的 equip 被门槛拒（`opinion_unavailable`），钩子后露出下一层

给 `x8` 加了收据探针，答案很直接：

```
[x8] slots=0 loc=[0] pending=[0] known=[14]
[x8] st=[2, 3] rs=["", "ideology_class_opinion_unavailable"] ops=[1, 5]
```

discover 成功、equip 被 `ideology_class_opinion_unavailable` 拒——这个 fixture 从不发布阶层意见，
而门槛在 `available == false` 时一律拒绝（`ideology_runtime.cpp:1405`）。

加上门槛钩子后（`support_gate_enabled = false` → `configure_table` 置 channel_count=0 →
`level_has_effect` 为假 → 在 `:1384` 直接放行）：

| | 之前 | 之后 |
| --- | --- | --- |
| 检查数 | 30 | **54** |
| 失败 | 1 | 2：`bronze_casting applies the upstream +15% only at the workshop (1.00000)`、`re-equipping restores the upstream bonus` |

也就是说：**门槛这一层通了，露出的是下一层**——`bronze_casting` 的"只在作坊格加成"属于
目标筛选/条件，正是 pod 表达不了的那类（§7.33）。

钩子保留（这个 fixture 测的是卡的效果，不是门槛；继续卡在门槛只会掩盖真实进度），
剩下的 2 条归入 pod 能力缺口。

`x10` 没有动：它的失败名是 `v10_technology_gate turns off at zero ...`，说明它**本身就在测门槛**，
加钩子会破坏被测语义。

### 7.50 第五十轮：把剩余项写成可执行计划 + 落了阶段 A 的第一步

剩余 17 个失败经过 §7.43–§7.49 的逐条定性后，14 条指向同一个能力缺口。这轮把它写成一份可执行
计划：`docs/plans/ideology-worker-pod-conditions-plan.md`（四阶段、每阶段独立提交与回滚点、
每阶段验收命令）。不在计划内的四项（存档 canary、货币守恒、flip 丢卡、fixture 的 FINDING）也
在文件末尾标了归属。

并落了**阶段 A 的第 1 步**（不改行为）：

```cpp
struct RuntimeIdeologyPodModifierTemplate {
    ...
    int32_t selector_kind = 0;      // 阶段 A 追加，暂无人读取
    uint32_t tag_begin = 0, tag_count = 0;
    uint32_t condition_begin = 0, condition_count = 0;
};
```

验证：构建通过；六个已知绿用例全部保持 —— `runtime` 92/0、`content` 67/0、`derived_pump` 55/0、
`x9a` 50/0、`x6a` 10/0、`social_media` 32/0。

第 2 步（GDScript 侧填这三组列）需要先定位 pod 目录 `level_modifiers` 的实际产出点，留给下一轮。

## 8. 待定

1. 立场是否保留作者"价值项"（建议保留 30%）。
2. 门槛口径：全国（建议）还是地块。
3. 自动否决阈值：`Δu < -20%` 是否合适，是否按阶层分档。
4. 是否把地块支持度接到推行成本/速度，还是先只做显示。
