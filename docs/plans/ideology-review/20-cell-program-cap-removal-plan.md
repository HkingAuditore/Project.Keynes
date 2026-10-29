# 理念地块效果移除“最多影响 32 个地块”限制

> **已由 v3 取代（2026-10-26）**：统一实施依据为 [22-cell-program-cap-removal-plan-v3.md](22-cell-program-cap-removal-plan-v3.md)。本文保留历史分析；分桶、聚合公式、worker 交接、存档恢复及工期判断须以 v3 为准。

> **2026-10-26 更新**：实现路径已由 [21-cell-program-cap-removal-plan-v2.md](21-cell-program-cap-removal-plan-v2.md) 细化并加速（Derived Cell Layer 内置于 ModifierRuntime、按实测 program 分层、删除 worker 交接线）。本文的问题分析、不变量、测试矩阵仍然有效；§5 架构、§8 发布时序、§13 阶段划分以 v2 为准。

## 完整设计、迁移与验收计划

| 项目 | 内容 |
|---|---|
| 日期 | 2026-10-26 |
| 状态 | 方案与实施计划，尚未修改运行时代码 |
| 范围 | 理念系统地块效果、Effect 实例预算、Economy 每格 stat 读取、UI/explain、存档兼容、测试与性能验收 |
| 目标读者 | 实现者、 reviewer、内容作者、测试与性能负责人 |
| 结论 | 可以移除玩家可见的 32 格限制，但不能只删除常量。正确方向是把无状态地块效果迁移到不可变、按国家与 program 聚合的系数平面 |

---

## 0. 执行摘要

### 0.1 为什么现在会有 32 格限制

当前地块域 program 采用“一个命中地块 = 一个 Effect 实例”的模型：

```text
一张卡
  -> 一个或多个地块域 program
  -> selector 解析出 N 个目标地块
  -> 每个目标地块创建一个 Effect 实例
  -> 每个实例带 metric、事务、Modifier 行与 ACK
```

Effect Runtime 的并发实例预算为 4096。若取消 32 格上限，实例数会随着“在场卡数 × program 数 × 命中地块数 × 叠层数”增长，先撞容量，再撞事务、ACK、内存与主线程时延。

因此，`SELECTOR_MAX_CELLS = 32` 是容量保护，不是平衡参数。

### 0.2 为什么不能只删除常量

以下做法都不够：

1. 只删除 `SELECTOR_MAX_CELLS`。
2. 只把 `max_concurrent_instances` 从 4096 调大。
3. 只把生成器默认值从 32 改成 0 或 -1。
4. 只删掉卡面文案。
5. 保留逐格实例，同时再叠加现有实验性系数平面。

这些做法要么重新撞容量上限，要么产生重复计算，要么让卡面和实际行为不一致。

### 0.3 推荐目标架构

把无状态、永久、地块域的 program 改为“每国每 program 一条描述，每个受影响 stat/cell 只保存派生系数”：

```text
理念目录
  -> 预编译 program 元数据
  -> 根据当前理念状态生成不可变 CellProgramTable
  -> Economy 在 COMMIT 中构建派生 CellStatOverlay
  -> 所有每格 stat 读取点查询同一份 overlay
```

平面内的实例成本不再随命中格数增长。命中 40 格、400 格或全国所有格，Effect 实例数都保持不变。

### 0.4 工作量判断

| 交付范围 | 批次估计 | 粗估有效开发日 | 风险 |
|---|---:|---:|---|
| 只迁移常见的“本国领土 + 常数列 + 无生命周期”地块卡 | 1–2 个功能批次 | 7–12 日 | 中 |
| 含基线与最终清理的常见卡完整交付 | 2–3 个批次 | 10–17 日 | 中高 |
| 覆盖径向、来源计数、连通块、距离、全部 stat、worker、UI | 4–6 个批次 | 20–35 日 | 高 |

时间不是承诺值。真正的大头不是删 32，而是：

- 所有相关每格 stat 都要有统一、可证明完整的读者；
- worker 权威下要安全发布；
- 条件、来源展开和 ramp 要与旧路径逐位一致；
- UI 命中高亮必须使用同一套选择器；
- 存档 hash、worker ABI 和回归测试要一起收口。

### 0.5 推荐交付策略

先做“常见无状态地块卡”的完整迁移，确认数值、存档、worker 和性能后，再覆盖特殊选择器。不要一次性重写整个理念系统。

---

## 1. 问题定义

### 1.1 玩家看到的现象

许多理念卡显示：

```text
本国海岸的地块：全部产出提高 15%；
最多影响 32 个目标地块
```

玩家会自然理解为：

- 国家只有 10 个海岸地块时，10 个全部受影响；
- 国家有 100 个海岸地块时，只有 32 个受影响；
- 哪些地块被选中没有可解释的游戏规则。

这不是设计上想要的“最多影响 32 个”，而是引擎容量上限泄露到了卡面。

### 1.2 32 的代码来源

核心常量：

```text
gdext/src/effect_runtime.h
EffectRuntime::SELECTOR_MAX_CELLS = 32
```

相关镜像与消费者：

| 位置 | 作用 |
|---|---|
| `gdext/src/effect_runtime.h` | 主线程选择器硬上限 |
| `gdext/src/runtime_effect_pod.h` | worker selector kind 镜像 |
| `Project/project-keynes/scripts/effect/effect_catalog.gd` | GDScript POD selector kind 镜像 |
| `Project/project-keynes/scripts/ideology/ideology_effect_definition.gd` | 创作层 32 格校验 |
| `Project/project-keynes/scripts/ideology/ideology_catalog.gd` | 并发实例预算的最坏情况计算 |
| `Project/project-keynes/tests/ideology/ideology_instance_budget_test.gd` | 9 × 32 实例预算测试 |
| `tools/ideology/generate_ideology_catalog.py` | `Prog.selector_cap = 32` 默认值与卡面文案 |

### 1.3 为什么很多卡都有这个限制

生成器的 program 默认值就是 32：

```python
selector_cap: int = 32
```

卡面渲染函数又统一追加：

```text
最多影响 {selector_cap} 个目标地块
```

所以看起来像“很多卡都专门做了同样的平衡决定”，实际上是同一项基础设施限制被批量写进了内容。

### 1.4 直接取消会发生的后果

假设：

- 64 个国家；
- 每国 12 张在场的地块卡；
- 每张平均命中 100 个地块。

实例数量级为：

```text
64 × 12 × 100 = 76,800
```

而当前并发预算只有：

```text
4,096
```

即使把预算提高 20 倍，仍会带来：

- 每个实例一组 metric slab；
- 每次状态变化都可能产生大批 remove/apply；
- 每个实例进入 Modifier、事务和 ACK；
- worker 快照搬运量增大；
- 主线程在权威翻转或刷新时承担全量 reconcile；
- 存档中保存大量可由理念状态推导出的实例引用；
- UI 命中列表与地图高亮遍历大量实例。

因此，“调大预算”只是把问题推迟，不是解决方案。

### 1.5 需要区分三种“上限”

| 上限 | 含义 | 是否应直接取消 |
|---|---|---|
| 目标地块上限 | 一个 selector 最多返回多少目标格 | 平面 program 应取消；有状态旧实例可暂时保留安全上限 |
| 来源地块上限 | source selector 最多扫描/展开多少来源格 | 来源展开本身应有稳定规则，但目标覆盖不应被 32 截断 |
| 每格来源计数上限 | 如“每格最多计入 3 个来源” | 这是玩法语义，应保留并与“目标格上限”分开 |

统一删除所有 32 会误伤第三类玩法语义。实现时必须把“目标覆盖上限”和“来源计数上限”拆清楚。

---

## 2. 当前内容与运行时基线

### 2.1 内容规模

基于当前 planning baseline 的只读统计：

| 项目 | 数量 |
|---|---:|
| `default_ideology_effects.tres` 中的效果 program | 288 |
| 地块域 program | 272 |
| `OWN_TERRITORY(12)` | 194 |
| `TAG_SOURCE_COUNT(16)` | 66 |
| `TAG_SOURCE_R1(14)` | 5 |
| `NEIGHBORS_R1(6)` | 2 |
| `OWNER(0)` | 2 |
| `NEIGHBORS_R2(7)` | 1 |
| 同地形/资源连通块 | 1 |
| `DISTANCE_N(11)` | 1 |
| `lifecycle = 0` 的地块 program | 272 |
| `max_stacks = 1` | 270 |
| `max_stacks = 5` | 1 |
| `max_stacks = 4` | 1 |

这组数据的含义：

1. 绝大多数是永久、无生命周期效果，适合平面。
2. 194 张 `OWN_TERRITORY` 是最值得先迁移的主体。
3. 66 张 `TAG_SOURCE_COUNT` 不是普通 tag filter，需要每格来源计数列。
4. 径向、连通块、距离等特殊选择器只有少数生产内容，但不能假装它们不存在。
5. 叠层生产内容极少，仍应在全量计划中有明确处理。

### 2.2 已有系数平面骨架

代码中已经存在：

```text
gdext/src/ideology_cell_program.h
CellProgramTable
CellProgramEntry
```

源码注释明确说明：“一个目标格一个 Effect 实例”正是撞上 4096 上限并导致 32 格限制的原因，而系数表没有这个问题。

当前 v1 支持：

- 单标签过滤；
- `CONSTANT` 列；
- `NEIGHBOR_COUNT` 列的初步结构；
- `ADD/MULTIPLY` 的初步表达；
- 按国家 CSR 组织 program 条目。

当前 v1 不支持或存在明确问题：

- generation 固定为 1；
- 可能与逐格 Effect 实例重复计算；
- selector kind 0 在两条路径语义不一致；
- 系数语义尚未完全对齐 Modifier；
- worker 权威下不会正式发布；
- 主线程可能直接修改 Economy 正在读取的 CSR；
- 只支持单标签，不能表达多条件；
- `cap_units` 和 MUL 累加器尚未完整使用；
- Economy 当前主要把平面合并进 `economy.city.good.*.output_factor`；
- 其他每格 stat 即使被收进表，也可能没有平面读者。

现有平面已通过 feature flag 关闭：

```text
_ideology_cell_plane_enabled = false
```

因此不能把“已有 CellProgramTable”误认为“功能已完成”。

### 2.3 当前 Effect 路径的成本模型

单张卡一次 reconcile 的主要成本：

| 阶段 | 复杂度或问题 |
|---|---|
| program key 查找 | 字符串和映射查找 |
| selector 解析 | `OWN_TERRITORY` 与领土格数相关，全图 selector 与 N 相关 |
| 协同倍率 | 可能扫描全部协同 |
| retire/added 对比 | 目标数较大时出现平方级比较 |
| 批量提交 | 大量 Dictionary/Packed 数组与 Variant 组装 |
| metric 采样 | 与目标格数 × 声明 metric 数相关 |
| metric 发布 | 每个实例都有 generation 推进和下游事务 |
| 下游 | Modifier remove/apply、ACK、存档引用 |

平面的目标不是“把这些步骤优化 10%”，而是让永久地块卡根本不进入这条路径。

### 2.4 现有性能目标

设计文档已有以下门槛：

| 场景 | 门槛 |
|---|---|
| 64 国、12 张在场卡、主线程权威 | p95 ≤ 0.35 ms |
| 512 国续跑、worker 权威 | p95 ≤ 0.42 ms |
| 单次 native 调用 | ≤ 1 ms |
| 6400 格 class-opinion | 中位数 < 1 ms |
| 空闲日 | 相关重建、刷新、事务、重排计数为 0 |

这些数字只能在同机器、同 debug DLL、固定 seed、固定场景下引用。没有实测证据前，不得写“已达标”。

---

## 3. 目标、非目标与验收原则

### 3.1 目标

1. 永久、无状态的地块理念效果不再受 32 格目标上限限制。
2. 取消限制后，Effect 实例数量不随命中格数增长。
3. 32 格以内，新旧路径逐格数值一致。
4. 32 格以上，新路径覆盖全部符合条件的目标，不再稳定裁掉一部分。
5. 主线程与 worker 权威的结果一致。
6. 标签、领土、metric 条件变化后，结果按确定日期生效。
7. UI 命中数、地图高亮、卡面文案与实际效果使用同一套语义。
8. 空闲日零重建、零事务、零逐格实例刷新。
9. 存档兼容策略明确，不静默修补、不重放效果。
10. 目录编译期能拒绝“看似上了平面，其实没有读者”的 stat。

### 3.2 非目标

本轮不以以下事项为目标：

- 重新平衡每张卡的数值；
- 取消有持续时间、一次性、锁存类效果的 Effect 事务；
- 把国家级效果迁移到地块平面；
- 把 family-owned selector 改成地块平面；
- 为所有历史存档做无损迁移；
- 在 GDScript 中复制一份理念模拟；
- 用多线程竞速时“谁最后写入”决定效果生效日；
- 只为了文本好看而删除尚未真正迁移的限制。

### 3.3 核心验收原则

1. **单一读者**：同一 stat/cell 的平面贡献只能被一个权威读取路径消费。
2. **单一判定**：一个 program 是否由平面承载，只由目录编译结果决定，运行时不得猜。
3. **无实例化**：plane-owned program 不得再创建逐格 Effect 实例。
4. **失败关闭**：plan-owned program 若缺 stat reader、缺 selector 实现或缺定义，目录编译失败，不得静默退化为“没有效果”。
5. **确定性**：所有累加使用整数和固定顺序。
6. **不可变交接**：发布表不可被修改；Economy 在拥有状态和快照的线程交换。
7. **按需显示**：UI 命中列表不在每日仿真路径中构建。
8. **实测收口**：性能结论必须有基线、改动后数据和固定场景证据。

---

## 4. 关键设计决策

### D1：用 program 平面承载，不用更多实例

永久地块卡的本质是一个函数：

```text
对本国每个格 c：
stat[c] += coef × column[c] × condition[c] × selector_mask[c]
```

它不需要：

- 逐格持久 Effect 身份；
- 逐格事务；
- 逐格 ACK；
- 逐格 metric slab；
- 逐格存档引用。

### D2：目录描述与派生 overlay 分离

需要两个不同层次：

| 层次 | 内容 | 何时变化 |
|---|---|---|
| `CellProgramTable` | 当前国家、卡、等级、协同产生的 program 描述 | 装卡、卸卡、升级、协同翻转、学派强度变化 |
| `CellStatOverlay` | 根据 tag、领土、metric、column 计算出的每格 stat 增量/倍率 | 表、标签、领土、条件 metric 变化 |

把两者混成一个表会导致每天因经济指标变化而重建目录描述。

### D3：plan-owned program 不使用目标格 cap

plan-owned program 的目标覆盖由 selector 语义决定，不再被 32 截断。

旧的 32 格 cap 只保留给：

- 尚未迁移的瞬时/有状态 Effect；
- 由 Effect 实例承载且确实需要安全上限的边缘效果。

### D4：无静默回退

若某个 program 标记为 plan-owned，但运行时不支持它的 selector、stat、条件或列：

- 目录编译失败；
- 或该 program 从一开始就不标记为 plan-owned。

不允许“plane 失败后偷偷走实例路径”，因为那会让不同机器、不同权威路径产生不同覆盖范围。

### D5：状态拥有者构建表，Economy 在自己的提交阶段消费

- Ideology 状态拥有者构建不可变 `CellProgramTable`；
- 通过 pending slot 交给 Economy；
- Economy 在 COMMIT 或 epoch begin 交换；
- 主线程不得直接修改 Economy 正在读取的 CSR；
- 不在发布瞬间重建所有格子。

### D6：确定性生效日

建议规则：

```text
第 D 天发布且通过结构确认的表，从第 D+1 天 COMMIT 起生效。
```

不得使用“worker 恰好在哪个 tick 到达”作为效果生效时刻。

### D7：固定点与固定遍历顺序

所有贡献使用 Q16 定点，按以下顺序归并：

```text
country slot 升序
  -> program dense id 升序
  -> entry 原始顺序
  -> cell id 升序
```

禁止使用无序容器迭代顺序决定最终数值。

### D8：存档先 fail-closed

第一版推荐：

- `CellProgramTable` 与 overlay 均为派生量，不入档；
- 目录 hash 变化后，旧 PKID/PKEF 按现有规则 fail-closed；
- 不做自动删除旧实例的迁移器。

如果有兼容需求，另开迁移项目，不能混在性能改造中。

### D9：UI 不读实例报告推断命中

`effect_instance_report` 表示实例归属，不等于平面效果命中。plane-owned program 的命中列表必须由 selector explain 接口按需计算。

### D10：保留“有状态效果”的安全边界

如果未来仍有逐格瞬时、持续时间、叠层锁存效果，它们可以继续使用 Effect 实例，并保留有限的实例安全上限。这里保留的是运行时保护，不是玩家卡面上的永久地块限制。

---

## 5. 目标架构

### 5.1 分层

```text
[1] 生成器 / IdeologyEffectCatalog
        |
        | 预编译 selector、condition、term、reader 完整性
        v
[2] Native catalog / Program IR
        |
        | 根据在场理念状态选活跃 program
        v
[3] Immutable CellProgramTable
        |
        | pending + effective_day
        v
[4] Economy COMMIT: CellStatOverlay
        |
        | 每格 stat 的统一读取入口
        v
[5] production / birth / need / consume / resource / UI explain
```

### 5.2 目录编译产物

每个地块 program 预编译为类似以下结构。字段名可在实现时调整，但语义必须齐全：

```cpp
struct PlaneProgramTemplate {
    int32_t program_dense_id;
    int32_t stat_id;
    int32_t operation;                 // ADD / MULTIPLY
    int64_t add_q16;                   // 已乘等级、学派、协同
    int32_t factor_q16;                // MULTIPLY 的稳定表达
    int32_t column_kind;               // CONSTANT / SOURCE_COUNT / ...
    int32_t column_tag;
    int32_t cap_units;

    int32_t selector_kind;
    int32_t selector_param[2];
    bool unbounded_targets;

    int32_t condition_begin;
    int32_t condition_count;
    uint64_t tag_dependency_mask;
    uint64_t metric_dependency_mask;
};
```

实际实现可以使用更紧凑的 SoA/CSR 布局。关键约束：

- 热路径不出现 String、Variant、Dictionary；
- stat 和 definition 在编译期解析成 dense id；
- 条件在编译期验证运算符、metric id、阈值；
- 每个 term 都必须通过 reader 完整性检查。

### 5.3 每国 program 表

```cpp
struct CellProgramEntry {
    int32_t program_dense_id;
    int32_t stat_id;
    int32_t operation;
    int32_t add_q16;
    int32_t factor_q16;
    int32_t column_kind;
    int32_t column_tag;
    int32_t cap_units;
    int32_t selector_kind;
    int32_t selector_param[2];
    int32_t condition_begin;
    int32_t condition_count;
};

struct CellProgramTable {
    uint64_t generation;
    uint64_t content_digest;
    int64_t effective_day;
    std::vector<int32_t> country_offsets;
    std::vector<uint64_t> country_handles;
    std::vector<CellProgramEntry> entries;
    std::vector<CompiledCondition> conditions;
    Diagnostics diagnostics;
};
```

国家使用带 generation 的 handle，不直接信任 Ideology slot 与 Economy slot 永远相同。Economy 在消费时解析 handle，失败则 fail-closed 并计数。

### 5.4 每格 overlay

为兼顾常见内容和性能，建议支持两层表达：

```cpp
struct CountryStatUniform {
    int32_t add_q16;
    int32_t factor_q16;
};

struct CellStatOverride {
    int32_t cell;
    int32_t add_q16;
    int32_t factor_q16;
};

struct CellStatLayer {
    std::vector<CountryStatUniform> uniform_by_country;
    std::vector<int32_t> override_offsets;  // CSR over country
    std::vector<CellStatOverride> overrides;
};
```

适用规则：

- `OWN_TERRITORY + 常数列 + 无逐格条件` 可以进入“国家 uniform”层；
- 单标签、多标签、逐格条件、来源计数、邻格数进入稀疏 override；
- `TAG_ANY_CELL` 这类全图 selector 可用全局层或专用全局 override；
- 若某个 stat 的稀疏 override 太密，可退化为在该 COMMIT 内使用临时 dense scratch，但对外仍保持统一读取接口。

常见卡不应对每张卡都分配一整张 `cells × stats` 稠密矩阵。

### 5.5 统一读取入口

新增类似：

```cpp
int32_t effective_cell_stat_q16(int32_t stat_id, int32_t cell) const;
```

语义：

```text
base = ModifierRuntime 现有的每格有效值
effective =
    clamp(
        (base + sum_plane_add) × product_plane_factor,
        stat_min,
        stat_max
    )
```

所有允许上平面的 stat 都必须通过这个入口。禁止某些读者继续只读 Modifier，而另一些读者读平面。

### 5.6 Reader 完整性清单

在 native 目录编译时维护：

```text
stat_id -> has_complete_plane_reader
```

只有值为 true 的 stat 才允许被 plan-owned program 使用。

已知需要审计的每格读取族：

| stat 族 | 典型消费者 | 迁移要求 |
|---|---|---|
| `economy.city.good.*.output_factor` | `city_good_output_factor_q16`、建筑产出 | 已有部分平面合并，改造成统一入口 |
| `economy.city.building.*_output_factor` | 建筑组产出因子冻结 | 必须读统一入口 |
| `economy.city.birth_factor` | 人口出生路径 | 必须读统一入口 |
| `economy.city.need.*.consumption_factor` | family need 消费 | 必须读统一入口 |
| `economy.city.good.*.consumption_factor` | family good 消费 | 必须读统一入口 |
| `economy.city.resource.*.regen_factor` | resource worker | 必须读统一入口 |
| `economy.city.output_factor` | 聚合产出，需先确认真实读点 | 若无 reader，禁止上平面 |
| 其他 `economy.city.*` | 逐项审计 | 无完整 reader 一律拒绝 |

注意：目录声明存在不等于运行时真的有消费者。`economy.city.trade_output_factor` 一类“声明了但没有读点”的 stat 不能仅凭目录通过验收。

---

## 6. Selector 迁移设计

### 6.1 迁移分组

| selector | 样本文档数量 | 第一阶段 | 最终状态 |
|---|---:|---|---|
| `OWN_TERRITORY(12)` | 194 | 主要迁移对象 | 平面，无目标格 cap |
| `TAG_SOURCE_COUNT(16)` | 66 | 第二阶段 | 平面，按每格来源计数生成贡献 |
| `TAG_SOURCE_R1(14)` | 5 | 第二阶段 | 平面，展开所有来源 R1 后 union |
| `NEIGHBORS_R1(6)` | 2 | 第二阶段 | 先保持 anchor 语义，再平面化 |
| `OWNER(0)` | 2 | 暂不决定 | 明确 anchor 或 whole territory 后再迁移 |
| `NEIGHBORS_R2(7)` | 1 | 第三阶段 | 平面，保留 anchor 语义 |
| 连通块 | 1 | 第三阶段 | 组件缓存或按 program mask |
| `DISTANCE_N(11)` | 1 | 第三阶段 | 平面 BFS，保留距离语义 |
| `TAG_ANY_CELL(13)` | 当前生产少 | 最后 | 明确全图语义，允许全图 mask |
| `FAMILY_OWNED(17)` | 非地块 | 不做 | 继续 Effect 路径 |

### 6.2 `OWN_TERRITORY`

语义：

```text
遍历该国领土 CSR
  -> 若 param1 == 0，全部自有格命中
  -> 若 param1 != 0，只保留带该 tag 的自有格
  -> 再应用 target condition
```

平面实现：

- 直接遍历 Economy COMMIT 中的不可变领土快照；
- 不在主线程调用 Economy 的惰性缓存；
- 每国按 program 生成 uniform 或 sparse override；
- 不再调用实例 cap。

### 6.3 `TAG_SOURCE_R1/R2`

语义必须保持现有 X1：

1. 在本国领土中选择带 source tag 的来源格；
2. 每个来源展开 R1 或 R2；
3. 所有 ring union、排序、去重；
4. target condition 作用于目标格，不作用于来源格；
5. 不再对 union 结果做 32 截断。

平面实现可以复用现有 `building_neighbor` 和 ring 遍历原语，但输出的是位图或 cell list，而不是实例列表。

### 6.4 `TAG_SOURCE_COUNT`

当前语义：

```text
对每个目标格统计半径内有多少个本国 source tag 格
  -> 每个目标格最多计入 source_cap 个来源
  -> 贡献按 count / source_cap 缩放
```

平面实现：

- 用临时 count scratch 计算；
- 生成 `units = min(count, source_cap)`；
- 按 program 的系数得到最终 ADD 或 factor；
- 不创建每格实例；
- target cap 不再适用；
- source_cap 是玩法上限，继续保留。

### 6.5 target cap 编码问题

`TAG_SOURCE_COUNT` 的 `param[0]` 目前是 bit-packed：

- bits 0..4：target cap；
- bits 5..7：radius；
- bits 8..11：source count cap。

其中 `target_cap == 0` 代表默认 32。

要支持“无目标上限”，不能直接把 `0` 改成 unbounded，因为这会改变旧 selector 的语义。

推荐：

1. 为 plan-owned program 增加显式 `unbounded_targets` 元数据；
2. plane 路径忽略 target cap 字段；
3. legacy 实例路径继续把 `0` 解释成 32；
4. 若将来彻底删除旧路径，再清理 bit 布局和版本。

### 6.6 selector kind 0 的语义争议

现有 v1 平面把 kind 0 解释为“整个领土”，实例路径解释为 anchor 单格。这是明确的不兼容。

在迁移前必须决定：

- 保留 kind 0 = anchor；
- 需要全领土的内容继续显式使用 kind 12；
- v1 平面的错误解释删除。

不得用隐式语义变更作为“顺手修复”。

---

## 7. 条件、列与数值语义

### 7.1 条件编译

现有条件需要编译为紧凑谓词：

```cpp
struct CompiledCondition {
    int32_t metric_id;
    int32_t op;
    int32_t value_q16;
    int32_t lhs_condition;
    int32_t rhs_condition;
};
```

可以是表达式树、DNF 或小型字节码。推荐先做 DNF 或固定节点树，因为：

- 节点数可控；
- 便于生成 tag/metric 依赖 mask；
- 可以在目录编译期拒绝未知节点；
- 不需要运行期字符串或 Variant。

### 7.2 条件作用对象

必须固定规则：

- `TAG_SOURCE_*` 的 source 过滤只看 tag；
- target condition 在目标格上求值；
- 全国标量 metric 对所有目标格相同；
- 每格 metric 按 cell 求值。

现有测试必须增加“source 满足但 target 不满足”和“target 满足但 source 不满足”两类反例，防止方向写反。

### 7.3 依赖 mask

每个 program 编译出：

```text
territory_dependency
tag_dependency_mask
metric_dependency_mask
```

用途：

- 只有相关 tag 变化才重建；
- 只有条件 metric 跨过阈值桶才重建；
- 纯人口小幅波动不能导致所有地块卡每日全量重建；
- 空闲日所有 rebuild 计数必须为 0。

### 7.4 ramp

现有 `Ramp` 会生成：

```text
READ_METRIC
  -> MIN(cap)
  -> MUL(per)
  -> EMIT
```

平面编译后应成为 entry 的一次系数求值，而不是每个目标格重复读标量 metric。

约束：

- ramp 读取的 metric 进入 dependency mask；
- ramp 不支持的情况在目录编译期拒绝；
- 全国 ramp 可按国家缓存；
- 每格 ramp 必须按 cell 进入稀疏 override。

### 7.5 叠层

第一版：

- `lifecycle != 0` 继续 Effect；
- 只有一层、永久效果进入平面；
- `ADD_STACK + DURATION` 不进入平面。

第二阶段可支持：

- 永久 program 的固定 stacks；
- ADD：`add × stacks`；
- MULTIPLY：按 Modifier 的插值公式计算后再处理 stacks；
- 如果 stacks 会随时间或事件变化，先保留 Effect 路径。

### 7.6 Modifier 语义对齐

必须复用或严格镜像现有 Modifier 计算，不允许平面自行发明近似公式：

```text
ADD term:
    term.add × stacks × magnitude

MULTIPLY term:
    (1 + (term.factor - 1) × magnitude) ^ stacks

stat:
    (base + Σadd) × Πfactor
```

还要处理：

- SUBTRACT 在 resolver 中如何折叠；
- cut 定义的负增量；
- school strength scale；
- synergy magnitude scale；
- magnitude clamp；
- stat min/max 和 soft cap；
- Q16 rounding。

建议把 Modifier 的 term 求值抽成小型的、无 Godot 依赖的共享核，平面在表构建时调用一次，Economy 读取时不再做浮点 pow 或字符串解析。

### 7.7 金标准：双跑逐位比较

同一个 fixture 分别使用：

1. legacy 实例路径；
2. plane 路径。

在目标格集合的交集上逐格比较。要求：

- 32 格以内结果逐位一致；
- 32 格以上，旧路径是截断后的子集，新路径必须包含旧的 32 格并扩展到全部命中格；
- ADD、MULTIPLY、cut、ramp、stacks、condition 各有独立样例；
- 浮点转 Q16 的边界值必须有测试。

---

## 8. 发布、线程与生效时序

### 8.1 触发构建的事件

以下事件使 program 描述表变脏：

- 装卡；
- 卸卡；
- 升级；
- 国家精神晋升导致活跃 program 变化；
- 协同翻转；
- 学派强度变化；
- X5 改写的 selector/倍率发生变化；
- worker 业务快照被采纳；
- 读档恢复后重建。

以下事件不重建描述表，只重建 overlay：

- 领土归属变化；
- tag 位变化；
- 条件 metric 跨阈值；
- 邻接/组件缓存版本变化；
- Economy 的首个有效 epoch 建立。

### 8.2 主线程权威时序

```text
Ideology transition
  -> Effect/Modifier ACK
  -> mark cell program table dirty
  -> owner thread builds immutable table
  -> set effective_day = current_day + 1
  -> stage pending table
  -> Economy COMMIT:
       swap table
       build/refresh overlay using immutable tag/territory snapshot
       publish generation
```

### 8.3 worker 权威时序

优先级最高的方案：

```text
Ideology worker
  -> builds derived program descriptors
  -> exports only on content digest change
  -> host stages as immutable pending table
  -> Economy COMMIT consumes
```

如果现有 host 没有合适的跨 worker 交接面，可退而使用：

```text
worker commits business snapshot
  -> main/host uses the same pure table builder
  -> stages table for Economy
```

这个退路仍要求：

- 使用同一份纯 builder；
- 不镜像可变理念状态；
- 不扫描 Economy 的可变数组；
- 两个权威的 digest 和格子结果 parity 一致。

### 8.4 禁止事项

- 主线程调用 `set_ideology_cell_programs()` 后立刻重建 CSR；
- 发布线程读取 Economy 的 mutable lazy cache；
- 用“最新到达的表”替代 `effective_day`；
- 在 Economy step 中途替换表；
- 从 GDScript 每帧推送整张表；
- 将 plan-owned program 仍然写入 per-cell Effect 实例。

### 8.5 线程断言与测试

建议增加：

- 表构建线程断言；
- pending 表的单写者断言；
- COMMIT swap 次数计数；
- 旧 generation 读取失效计数；
- worker/main digest parity 报告。

---

## 9. Effect 所有权与预算

### 9.1 `plane_owned` 元数据

在 Effect catalog 编译产物中加入：

```text
plane_owned = true
```

判定由生成器/目录编译完成，条件至少包括：

- 目标域为 cell；
- selector 已支持；
- 所有 command term 的 stat 有完整 reader；
- lifecycle 支持；
- stacks 支持；
- 条件可编译；
- 不是 family/country/climate 域。

### 9.2 实例收集路径

`collect_effect_activations` 或等价路径遇到 `plane_owned`：

- 不创建逐格 Effect 实例；
- 不生成逐格 metric slab；
- 不提交逐格事务；
- 不进入 `effect_instance_report` 的活跃实例列表；
- 不参与 PKEF 实例绑定审计。

国家级效果和 stateful 效果保持原样。

### 9.3 并发预算

当前 `max_concurrent_instances` 只应统计 Effect 实例。

规则：

- plane-owned program 的 Effect 实例贡献为 0；
- 目录声明行预算仍然独立计算；
- 不再使用 `9 × 32` 估算永久地块卡；
- 如果希望防止运行期表无限增长，增加“活跃 country × program 条目数”预算，而不是“命中格数”预算。

必须更新 `_program_live_target_cap()` 及其测试，避免 plane program 仍被按 32 格计费。

### 9.4 失败策略

若 plan-owned program 在运行期缺表：

- 不得静默创建 32 格实例；
- 记录明确错误；
- 保留上一份已验证的 generation，或将世界标记为需要重建；
- 目录编译和启动自检应尽量在进入游戏前发现该问题。

---

## 10. 如何真正取消“32 格”设定

### 10.1 分三步走

#### 第一步：内部支持无目标 cap

- plane 路径显式 `unbounded_targets`；
- 结果不再走 `effect_stable_cap`；
- 旧实例路径保留 32 作为安全上限；
- 卡面暂时保留说明，等待真实切换。

#### 第二步：按 program 切换

- plan-owned program 不再创建实例；
- 卡面文案只对已切换 program 删除“最多影响 32 个目标地块”；
- UI 命中数改为真实 selector explain；
- 双跑确认无重复计算。

#### 第三步：清理全局呈现与旧默认值

- 生成器不再给 plan-owned program 写目标 cap；
- 卡面统一不再显示永久地块卡的 32；
- 旧实例路径若只剩有状态效果，把常量改名为 `LEGACY_INSTANCE_SELECTOR_MAX_CELLS` 或同类明确名称；
- 所有镜像常量的用途写清楚；
- 若未来完全没有实例型地块效果，再决定是否彻底删除。

### 10.2 为什么不建议立刻删除所有镜像

32 同时被用于：

- Effect selector；
- worker POD kind 校验；
- GDScript 创作校验；
- 并发预算；
- family-owned cap；
- 测试；
- 文本生成。

一次性删除会扩大改动面，并让尚未迁移的有状态效果失去保护。

### 10.3 最终的玩家语义

迁移完成后：

- 卡面不再出现“最多影响 32 个目标地块”；
- 只有当玩法本身有来源计数上限时才显示该上限；
- 卡面可以显示“影响全部符合条件的本国地块”；
- 具体命中数由 UI 现算；
- 实际效果与显示使用同一份 selector 解释。

---

## 11. 存档、版本与目录 hash

### 11.1 派生量不入档

以下数据不新增持久化：

- `CellProgramTable`；
- `CellStatOverlay`；
- program 的每格命中列表；
- overlay generation；
- UI 命中缓存。

读档后由以下内容确定性重建：

- PKID 中的国家理念状态；
- 目录中的卡、等级、协同；
- Effect/Modifier catalog；
- Economy 领土与 tag 快照；
- 当前日期和已提交 revision。

### 11.2 会变化的版本面

实现前必须从源码读取当前版本常量，不得照抄旧文档：

| 文件 | 常量 |
|---|---|
| `gdext/src/ideology_runtime.h` | PKID save schema |
| `gdext/src/runtime_ideology_pod.h` | IDP2 POD ABI |
| `gdext/src/effect_runtime.h` / Effect POD | Effect catalog / POD ABI |
| PKEF 实现 | PKEF schema |
| Modifier catalog | Modifier schema |

若只增加目录元数据而不改二进制布局，save schema 可能不变，但 catalog hash 仍会改变。任何 hash 变化都必须按现有 fail-closed 规则处理。

### 11.3 推荐兼容策略

第一版：

- 旧 PKID/PKEF/PKCM 在 catalog mismatch 时 fail-closed；
- 不自动修补缺失绑定；
- 不重放效果；
- 不尝试从旧 32 格实例推导新平面。

可能的后续迁移器：

1. 识别旧版本 catalog；
2. 校验旧实例集合确实是旧 selector 的 32 格子集；
3. 在同一个事务中退役旧实例；
4. 构建新平面；
5. 只在新旧世界状态 hash 对齐时提交。

该迁移风险高，不建议与首次平面迁移同时做。

### 11.4 测试

至少覆盖：

- 当前版本 save/load roundtrip；
- 旧 schema fail-closed；
- catalog hash 变化 fail-closed；
- plane 表未入档；
- load 后正确重建；
- load 后不重放一次性效果；
- worker 与主线程读档后的 digest/格子值一致。

---

## 12. UI、explain 与诊断

### 12.1 卡面文案

生成器是唯一内容源。不得手改 `.tres`。

渲染规则：

- plan-owned program：不追加目标格 cap；
- legacy stateful program：如仍有实例 cap，明确显示；
- source count cap：继续显示“每个目标格最多计入 N 个来源”；
- 全图 selector：明确写“全图”，不能误导成“本国”。

### 12.2 命中数与高亮

新增 native explain 接口，建议输入：

```text
country_handle
idea_id / program_id
level
可选：cell sample limit
```

输出：

```text
ok
selector_kind
matched_total
returned_count
cell_ids
per-cell sample values
truncated_for_ui_only
```

规则：

- `matched_total` 是真实命中数；
- UI 采样上限只影响返回列表，不影响游戏效果；
- 禁止为了 UI 返回而重新引入 32 格效果 cap；
- explain 只读，不修改权威状态；
- 只有面板打开或用户请求高亮时调用；
- GDScript 不复制 selector 逻辑。

### 12.3 `effect_instance_report`

必须重新定义其展示语义：

- 它只表示 Effect 实例；
- plane-owned program 不在这里出现；
- 不能再用“效果 N 处”直接推断地块命中；
- UI 应新增“命中地块”来源，而不是复用实例列表。

### 12.4 诊断计数器

建议新增：

| 计数器 | 含义 |
|---|---|
| `cell_plane_builds` | 表构建次数 |
| `cell_plane_publish_skips` | digest 未变而跳过次数 |
| `cell_plane_commit_swaps` | Economy 实际换表次数 |
| `cell_plane_country_rebuilds` | 重建 overlay 的国家数 |
| `cell_plane_cells_visited` | selector/overlay 扫描格数 |
| `cell_plane_condition_evaluations` | 条件求值次数 |
| `cell_plane_entries` | 当前活跃 program entry 数 |
| `cell_plane_unsupported` | 不支持项，生产应为 0 |
| `cell_plane_effect_instances_avoided` | 因平面而没有创建的实例数估算或精确值 |
| `cell_plane_legacy_caps` | legacy 实例路径仍触发的 cap 次数 |
| `cell_plane_truncated` | plane 路径被截断次数，必须为 0 |

UI 或调试报告应能区分子：

- 没有命中；
- 表未发布；
- 表已发布但 Economy 未到 effective day；
- stat reader 缺失；
- selector 不支持；
- 条件无法编译。

---

## 13. 分阶段实施计划

每个阶段应独立构建、独立测试、可回退。不要把所有改动压在一个提交或一个批次中。

### Phase 0：基线与护栏

#### 任务

- 记录当前 commit、DLL 时间戳、catalog hash；
- 跑 B1–B6 或当前可运行的最小替代基线；
- 记录现有测试失败数，区分既有红；
- 统计 272 个地块 program 的 selector、condition、stat、stacks 分布；
- 固定一个超过 32 格的地图 fixture；
- 固定一个 512 国续跑 fixture；
- 建立“既知失败”清单。

#### 交付

- 基线报告；
- 机器、DLL、seed、场景；
- 当前实例数、reconcile 次数、空闲计数器；
- 迁移覆盖率报表。

#### 退出标准

- 后续改动能与基线比较；
- 不再使用旧的“未测量”性能数字；
- >32 格 fixture 能稳定复现旧路径截断。

### Phase 1：目录元数据与静态判定

#### 任务

- 给 program 增加 `plane_owned` 元数据；
- 生成器输出 plane 资格；
- 实现 reader 完整性清单；
- 把 selector、condition、stat term 预编译为 dense IR；
- 增加“为什么这个 program 不能上平面”的编译诊断；
- 暂不改变运行时数值。

#### 文件

- `tools/ideology/generate_ideology_catalog.py`
- `scripts/ideology/ideology_effect_definition.gd`
- `scripts/ideology/ideology_effect_catalog.gd`
- `scripts/effect/effect_catalog.gd`
- `gdext/src/effect_runtime.h/.cpp`
- 可能的 Effect POD 元数据文件

#### 测试

- 每个 selector 的资格判定；
- 不支持 stat 的拒绝；
- unsupported condition 的拒绝；
- `.tres` 重新生成一致性；
- catalog hash 变化检测；
- plane 标签不会误覆盖国家域/family 域。

#### 退出标准

- 生成器能输出完整覆盖矩阵；
- 运行时仍走旧实例路径；
- 无玩家可见变化；
- 不支持的 program 有明确原因。

### Phase 2：不可变表与线程安全交接

#### 任务

- 重写 `CellProgramTable` 为不可变发布对象；
- 增加 content digest、generation、effective day；
- 增加 pending table；
- Economy 只在 COMMIT 交换；
- 删除主线程发布后立即重建 CSR 的行为；
- 增加单写者/线程断言；
- 仍采用 shadow 模式，不改变关卡数值。

#### 文件

- `gdext/src/ideology_cell_program.h`
- `gdext/src/ideology_runtime.h/.cpp`
- `gdext/src/world_ext_ideology.cpp`
- `gdext/src/economy_runtime.h/.cpp`
- worker POD / host 交接文件

#### 测试

- digest 不变时发布跳过；
- generation 递增；
- effective day 门控；
- COMMIT 前旧表继续可用；
- COMMIT 后新表生效；
- 主线程发布不直接改 Economy CSR；
- worker 和主线程 digest 一致。

#### 退出标准

- 平面可以 shadow 计算；
- 没有数据竞争型路径；
- 空闲日 swap/rebuild 为 0；
- 旧实例路径仍保持玩家数值。

### Phase 3：双跑对照与差异门槛

#### 任务

- 对同一 program 同时计算 legacy targets 和 plane overlay；
- 对交集逐格比较；
- 对 >32 格单独验证“新增覆盖”；
- 记录第一个差异 program、cell、stat、expected、actual；
- 对 ADD/MUL/cut/ramp 建专门样例；
- 对条件 true/false 建边界样例。

#### 测试

- 32 格边界：31、32、33；
- 200 格以上领土；
- 同 tag 200 格以上；
- tag 0、未知 tag、重复 cell；
- 来源 ring 重叠；
- source count 0、source_cap、超过 source_cap；
- condition 在 source 与 target 上的方向；
- Q16 rounding、负数、clamp。

#### 退出标准

- 所有计划迁移内容双跑一致；
- 任何差异都有解释，不能以“浮点误差”带过；
- >32 格差异只体现为旧路径截断；
- 不通过的内容不进入 plane-owned allowlist。

### Phase 4：常见 `OWN_TERRITORY` 卡切换

#### 范围

- `OWN_TERRITORY(12)`；
- 常数列；
- 单标签、多标签；
- 可编译 target condition；
- 有完整 reader 的 stat；
- 永久、单层效果。

#### 任务

- plan-owned 卡跳过逐格 Effect 实例；
- Economy 统一读取入口接入所有已开放 stat；
- 卡面移除这批卡的 32 格文案；
- UI explain 计算精确命中；
- 增加覆盖率和零实例断言。

#### 测试

- 每张已切换卡至少一个内容 fixture；
- 装卡/卸卡恢复；
- 升级替换；
- 协同倍率；
- 学派强度；
- 标签变化；
- 领土变化；
- >32 格全国覆盖；
- Effect 实例数为 0；
- save/load 后效果恢复。

#### 退出标准

- 常见卡不再受 32 限制；
- 逐格实例数为 0；
- 32 格内数值与旧路径一致；
- 32 格以上覆盖完整；
- UI 命中数与 actual 一致。

### Phase 5：来源、径向与派生列

#### 范围

- `TAG_SOURCE_R1/R2`；
- `TAG_SOURCE_COUNT`；
- `NEIGHBORS_R1/R2`；
- 常数列之外的 column kinds；
- ramp；
- 永久固定 stacks。

#### 任务

- 把来源展开改为 mask/list，不再实例化；
- 用来源计数 scratch 生成每格 units；
- ring union 去重；
- 组件/邻接缓存接入不可变 epoch 快照；
- 增加 column dependency；
- 对来源上限和目标上限彻底分开。

#### 测试

- 多来源重叠；
- 一个国家 100 个以上 source；
- 半径 1、2、3、4；
- source count cap 1、3、15；
- 目标覆盖超过 32；
- source tag 0 拒绝；
- 邻接缺失时 fail-closed；
- ring 不包含 source 自身（按现有语义）。

#### 退出标准

- 66 个 source-count program 与 5 个 source-ring program 可迁；
- target cap 不再截断；
- source count cap 保留；
- 性能随来源数有界增长，不随目标数创建实例。

### Phase 6：特殊 selector 与全量覆盖

#### 范围

- 同地形/资源连通块；
- `DISTANCE_N`；
- `TAG_ANY_CELL`；
- 剩余允许上平面的 stat；
- 必要的永久 multi-stack。

#### 任务

- 组件缓存与 program mask；
- BFS 结果缓存；
- 全图 mask 的全局层；
- 明确 selector kind 0；
- 处理任何剩余 reader；
- 把生产内容中所有可平面 program 纳入 allowlist，或记录明确例外。

#### 退出标准

- 覆盖率报表中每个 program 都有 `plane_owned` 或明确 `legacy_reason`；
- 不存在“忘了迁移所以仍有 32”的内容；
- 特殊 selector 的数值与旧路径一致；
- 没有隐藏的 stat 死读点。

### Phase 7：默认开启、清理与发布

#### 任务

- 默认启用平面；
- 删除常见卡的逐格实例路径；
- 删除卡面 32 文案；
- 把剩余常量重命名为 legacy 语义；
- 清理实验性 flag 和无效代码；
- 更新 native 文档、skill、内容说明；
- 跑完整性能与回归；
- 记录存档兼容结果。

#### 退出标准

- 玩家不再看到永久地块卡的 32 限制；
- Effect 实例预算不再按 9×32 估算常见卡；
- 空闲计数器为 0；
- B1–B6 或等效场景达到门槛；
- 存档版本策略明确；
- 文档与代码一致。

---

## 14. 建议的代码落点

### 14.1 原生

| 文件 | 预期改动 |
|---|---|
| `gdext/src/ideology_cell_program.h` | 扩展不可变表、descriptor、diagnostics、overlay 结构 |
| 可能新增 `ideology_cell_plane.cpp/.h` | selector/condition/table 构建与测试接缝 |
| `gdext/src/ideology_runtime.h/.cpp` | plane 资格、构建触发、digest、effective day |
| `gdext/src/effect_runtime.h/.cpp` | selector 语义、plane metadata、legacy cap 用途 |
| `gdext/src/runtime_effect_pod.h/.cpp` | 若不改业务 snapshot，至少保持 selector kind 校验一致 |
| `gdext/src/world_ext_ideology.cpp` | 发布/交接/测试入口 |
| `gdext/src/world_ext.h` | pending 表、feature flag、explain API |
| `gdext/src/economy_runtime.h/.cpp` | pending swap、overlay、统一 stat reader |
| `gdext/src/economy_runtime_configuration.cpp` | stat reader 注册/校验 |
| 建筑产出、人口、消费、资源相关 cpp | 改为统一读取入口 |
| `gdext/src/modifier_runtime.cpp` | 共享 term 求值核或只读 helper |

### 14.2 GDScript / 内容

| 文件 | 预期改动 |
|---|---|
| `scripts/ideology/ideology_effect_definition.gd` | 表征 unbounded/plane，不再误用 32 默认 |
| `scripts/ideology/ideology_effect_catalog.gd` | 编译前校验、覆盖率、diagnostics |
| `scripts/ideology/ideology_catalog.gd` | 并发预算、allowlist、内容校验 |
| `scripts/ideology/ideology_profile.gd` | plane 不按格数计 Effect 实例 |
| `scripts/effect/effect_catalog.gd` | plane metadata 和 POD 镜像 |
| `scripts/ideology/ideology_effect_report.gd` | 不再把实例数当命中数 |
| `scripts/ui/components/ideology_*` | explain 命中、tooltip、高亮 |
| `tools/ideology/generate_ideology_catalog.py` | `Prog` 默认、卡面文本、资格、校验 |
| `data/ideologies/default_ideology_effects.tres` | 只由生成器重建 |

### 14.3 测试

建议新增：

```text
tests/ideology/ideology_cell_plane_parity_test.gd
tests/ideology/ideology_cell_plane_invalidation_test.gd
tests/ideology/ideology_cell_plane_worker_parity_test.gd
tests/ideology/ideology_cell_plane_unbounded_selector_test.gd
tests/ideology/ideology_cell_plane_explain_test.gd
```

需要扩展：

```text
tests/ideology/ideology_effect_metric_publish_test.gd
tests/ideology/ideology_runtime_test.gd
tests/ideology/ideology_content_test.gd
tests/ideology/ideology_card_content_test.gd
tests/ideology/ideology_effect_instance_test.gd
tests/ideology/ideology_effect_override_test.gd
tests/ideology/ideology_instance_budget_test.gd
tests/runtime/runtime_ideology_save_roundtrip_test.gd
tests/ideology/ideology_runtime_stress_test.gd
tests/runtime/runtime_worker_source_scan_test.gd
```

---

## 15. 测试矩阵

### 15.1 Selector × 数值 × 条件

| 维度 | 必测值 |
|---|---|
| selector | OWN_TERRITORY、SOURCE_R1、SOURCE_R2、SOURCE_COUNT、NEIGHBORS_R1/R2、TAG_ANY_CELL、component、distance |
| 目标数 | 0、1、31、32、33、200+、全国 |
| tag | 无 tag、单 tag、多 tag、未知 tag、tag 变化 |
| 条件 | 无、单条件、AND、OR、每格 metric、全国 scalar metric |
| operation | ADD、MULTIPLY、cut、ramp |
| stack | 1、固定 2、生命周期叠层（应拒绝或保留 Effect） |
| 权威 | 主线程、worker |
| 世界状态 | 新局、读档、装卡、卸卡、升级、协同翻转 |

### 15.2 不变量

1. plane-owned program 的逐格 Effect 实例数恒为 0。
2. 平面目标集合不因 32 被截断。
3. 同一格同一 program 只贡献一次。
4. 同一 stat 的平面贡献只被一个读取入口消费。
5. `matched_total` 不受 UI 采样上限影响。
6. 未命中、缺表、缺 reader、缺 selector 有不同的错误码。
7. 相同 seed、相同状态、相同日期得到相同 digest。
8. 空闲日不重建 overlay。
9. 表在 effective day 之前不生效。
10. worker 与主线程在同一业务状态下得到相同格子值。

### 15.3 敏感性与反向验证

为了证明测试不是空转，至少做以下一次：

| 故意破坏 | 应失败的测试 |
|---|---|
| 恢复 32 截断 | >32 格覆盖测试 |
| plane-owned 仍创建实例 | 零实例测试 |
| 删除某个 stat 的 reader | reader 完整性测试 |
| generation 不递增 | 失效测试 |
| source 与 target condition 对调 | 方向测试 |
| 使用“最新到达”而非 effective day | 时序测试 |
| 允许主线程直接改 Economy CSR | 线程断言/测试 |
| 将 source_cap 当 target cap | 来源计数测试 |

### 15.4 构建与命令

原生构建只有 stdout 含以下行才算成功：

```text
scons: done building targets.
```

测试逐个运行，避免批量长 fixture 超时。典型命令：

```powershell
godot --headless --path Project/project-keynes `
  -s tests/ideology/ideology_cell_plane_parity_test.gd
```

每次涉及 C++ 的改动都必须：

- 成功后记录 DLL 时间戳；
- 对比测试前后 DLL 未变化；
- 记录实际通过/失败数；
- 运行 `git diff --check`。

---

## 16. 性能设计与验收

### 16.1 复杂度目标

设：

- `C`：国家数；
- `A`：每国平均活跃 plane program 数；
- `E`：活跃 entry 数；
- `N`：地图格数；
- `S`：source cell 数；
- `R`：ring 半径；
- `K`：条件节点数。

目标复杂度：

| 操作 | 目标 |
|---|---|
| 表构建 | 只在结构变化时，约 O(C × E) |
| `OWN_TERRITORY` overlay | O(领土格 + E) |
| tag filter | O(领土格 + E) 或位图扫描 |
| source ring | O(S × 6 × R) |
| source count | O(S × 6 × R + N) |
| 条件 | O(受影响格 × K) |
| stat 读取 | O(1) 或 O(log overrides) |
| 空闲日 | 0 次表重建、0 次 overlay 重建、0 次事务 |

### 16.2 内存目标

不使用逐格 Effect 实例后，主要内存是：

```text
program descriptors
+ uniform country layers
+ sparse cell overrides
+ 临时 tag/count scratch
```

常见 `OWN_TERRITORY + 常数` 卡应进入 uniform 层，占用与国家数和 program 数相关，而不是国家数 × 格数。

需要记录：

- 最大活跃 entry 数；
- uniform 条目数；
- sparse override 数；
- 临时 scratch 峰值；
- Effect 实例数变化；
- pending 表生命周期。

### 16.3 基准场景

沿用或扩展设计文档 B1–B6：

| 场景 | 规模与目的 |
|---|---|
| B1 | 64 国 × 12 张在场卡，主线程权威 |
| B2 | 同 B1，worker 权威 |
| B3 | 512 国续跑 |
| B4 | 每日 1% tag 翻转 |
| B5 | 空闲 30 天，验证所有空闲计数为 0 |
| B6 | 6400 格 class-opinion |
| B7 | 单国 >1000 格，验证 >32 覆盖 |
| B8 | 100+ 来源格，验证 source count/ring |
| B9 | 200+ 格条件过滤，验证 per-cell condition |

### 16.4 性能门槛

沿用现有门槛，并新增：

- plane-owned 地块卡不再产生逐格 Effect 实例；
- 空闲 30 天 `cell_plane_rebuilds = 0`；
- 空闲 30 天 `cell_plane_commit_swaps = 0`；
- 空闲 30 天 `effect_transactions_created = 0`；
- B7 的 p95 不因目标从 32 扩到全国而超过约定预算；
- B8 的成本与 source 数近似线性，不随目标数创建实例；
- B9 的条件变化只重建受影响国家/格。

### 16.5 测量纪律

- 同一机器；
- 同一 debug DLL；
- 固定 seed；
- 记录 commit 和 DLL 时间戳；
- 对比前后场景一致；
- 不同时运行其他 Godot 进程；
- 记录 p50/p95/p99；
- 记录计数器快照；
- 任何“应该更快”的判断不能代替实测。

---

## 17. 风险与缓解

| 风险 | 后果 | 缓解 |
|---|---|---|
| 平面和实例双算 | 数值翻倍 | `plane_owned` 单一判定；双跑；零实例断言 |
| stat 无真实 reader | 卡在 UI 上存在但不生效 | 编译期 reader manifest；禁止静默通过 |
| generation 恒为 1 | 装卡/卸卡后使用旧表 | content digest + generation；失效测试 |
| 主线程直接写 CSR | 与 worker 读竞争 | pending + COMMIT swap |
| worker 模式不发布 | 两权威结果不同 | worker digest parity；专用交接面 |
| cap sentinel 重载 | 0 既可表示默认 32 又可表示无上限 | 显式 `unbounded_targets` |
| source cap 与 target cap 混淆 | 玩法数值错误 | 独立字段、独立测试、独立文案 |
| 条件方向写反 | source 满足但 target 不满足也生效 | source/target 反例 fixture |
| metric 每日漂移 | 每天全量 overlay | 阈值桶 + per-metric revision |
| 组件/BFS 扫描过重 | p95 超门槛 | 只对特殊 program 启用；epoch 缓存；分帧/按需 |
| 稀疏层退化过密 | 内存和访问变慢 | uniform 层 + 稠密度阈值 + 临时 scratch |
| UI explain 重新实现逻辑 | 显示与效果不一致 | native 单一 explain 接口 |
| 旧档误加载 | 实例引用错位 | catalog hash fail-closed |
| 测试只用小地图 | 32 限制无法被发现 | >32 格固定 fixture |
| 旧路径保留太久 | 双语义长期存在 | 明确 allowlist 和移除阶段 |

---

## 18. 回退方案

### 18.1 开发期

- 保持 feature flag；
- 先 shadow，不改变玩家数值；
- 只允许通过双跑的 program 进入 allowlist；
- 每个 phase 可独立 revert；
- 若 plane 发布失败，保留上一份已验证 generation；
- 不在尚未稳定时修改存档二进制布局。

### 18.2 发布前

- 若性能不达标，不启用默认；
- 若某个 stat reader 不完整，从 allowlist 移除该 stat；
- 若 worker 无法安全交接，先只开放主线程路径，但这只能作为临时限制；
- 不得通过重新加 32 来掩盖未完成的 selector。

### 18.3 发布后

一旦目录 hash 已进入玩家存档：

- 不能简单回退为旧实例路径并期望旧档继续可用；
- 必须保持 catalog hash/版本 fail-closed；
- 回退版本要明确不能读取新档；
- 或者提供独立迁移器。

发布前必须确定这一策略，不能等事故后补。

---

## 19. 待确认决策

| 编号 | 问题 | 推荐默认 |
|---|---|---|
| Q1 | worker 权威下表如何交接 | worker 生成派生 descriptor，host 通过 immutable pending 交给 Economy |
| Q2 | 无上限如何编码 | 显式 `unbounded_targets`，不要复用 0 |
| Q3 | 旧存档是否迁移 | 第一版 fail-closed |
| Q4 | kind 0 语义 | 保留 anchor；全领土使用 kind 12 |
| Q5 | 聚合 `economy.city.output_factor` 是否上平面 | 先确认真实 reader；没有就禁止 |
| Q6 | 永久 multi-stack 是否本轮支持 | 先保留 Effect；内容极少，不阻塞主体 |
| Q7 | 32 常量是否最终删除 | 先改名为 legacy 实例安全上限；所有实例型地块效果消失后再删 |
| Q8 | UI 命中列表最大返回数 | 只限制显示采样，不影响 `matched_total` 和效果 |
| Q9 | 连通块与 distance 是否本轮支持 | 可以后置，但必须保留在覆盖率报表中 |
| Q10 | 全图 selector 是否允许永久全国卡 | 允许则必须内容 lint 和明确文案，不能误称为本国 |

---

## 20. Definition of Done

### 20.1 功能

- [ ] plan-owned program 不再创建逐格 Effect 实例。
- [ ] 所有已迁移 selector 不再使用 32 目标截断。
- [ ] source count cap 仍然按玩法语义生效。
- [ ] 32 格以内结果与旧路径逐位一致。
- [ ] 32 格以上覆盖所有符合条件目标。
- [ ] 装卡、卸卡、升级、协同、学派强度、标签、领土变化正确失效。
- [ ] 主线程和 worker 结果一致。

### 20.2 UI 与内容

- [ ] 卡面只对真正无上限的 program 删除 32 文案。
- [ ] UI 命中数和地图高亮来自 native explain。
- [ ] `.tres` 由生成器重建，没有手改。
- [ ] 覆盖率报表列出 plane-owned 与 legacy reason。
- [ ] 全图 selector 文案明确。

### 20.3 存档

- [ ] plane 表和 overlay 不入档。
- [ ] 读档后确定性重建。
- [ ] 旧档策略明确并测试。
- [ ] catalog hash 变化与 fail-closed 已验证。
- [ ] 没有重放一次性效果。

### 20.4 性能

- [ ] 记录改动前基线。
- [ ] 记录改动后同场景数据。
- [ ] 空闲 30 天相关计数为 0。
- [ ] >32 格场景没有实例爆炸。
- [ ] 512 国续跑没有退化。
- [ ] 没有未实测的性能声明。

### 20.5 工程收口

- [ ] C++ 构建 stdout 含 `scons: done building targets.`
- [ ] 相关测试逐个通过，失败数与基线一致。
- [ ] `git diff --check` 通过。
- [ ] native 文档更新。
- [ ] `project-keynes-ideology-runtime` skill 更新。
- [ ] 相关 review/roadmap 文档记录完成状态与例外。

---

## 21. 代码证据索引

| 证据 | 位置 |
|---|---|
| 32 格主常量 | `gdext/src/effect_runtime.h:269` |
| 稳定哈希截断 | `gdext/src/effect_selector_cap.h` |
| selector 解析和截断 | `gdext/src/ideology_runtime.cpp` 的 `resolve_effect_targets` |
| 现有平面结构 | `gdext/src/ideology_cell_program.h` |
| 平面表构建 | `gdext/src/ideology_runtime.cpp` 的 `build_cell_program_table` |
| 平面默认关闭 | `gdext/src/world_ext_ideology.cpp` |
| Economy 平面合并 | `gdext/src/economy_runtime.cpp` 的 `refresh_city_output_modifier_factors` |
| Economy 设置平面 | `gdext/src/economy_runtime.cpp` 的 `set_ideology_cell_programs` |
| 出生率每格因子 | `gdext/src/economy_runtime_market.cpp` |
| need 消费每格因子 | `gdext/src/economy_runtime.cpp` 的 family consumption 路径 |
| 建筑产出因子 | `gdext/src/economy_runtime.cpp`、`economy_runtime_building_production.cpp` |
| 资源恢复因子 | `gdext/src/economy_runtime.cpp` 的 worker resource 路径 |
| 生成器默认 cap | `Project/project-keynes/tools/ideology/generate_ideology_catalog.py:1612` |
| 卡面 32 文案 | `Project/project-keynes/tools/ideology/generate_ideology_catalog.py:1836` |
| GDScript 32 镜像 | `Project/project-keynes/scripts/ideology/ideology_effect_definition.gd:93` |
| 并发预算 | `Project/project-keynes/scripts/ideology/ideology_catalog.gd` 的 `_program_live_target_cap` |
| 已记录平面缺陷 | `docs/plans/ideology-review/05-implementation-status.md` |
| 第一轮复核问题 | `docs/plans/ideology-review/06-round1-review.md` |
| 性能目标架构 | `docs/plans/ideology-review/03-performance-and-optimization.md` |

行号会漂移，实际实现前必须用代码搜索重新定位。

---

## 22. 最终建议

### 22.1 最稳妥的第一步

只做：

1. 目录 `plane_owned` 判定；
2. reader 完整性清单；
3. 不可变表与 COMMIT 交接；
4. `OWN_TERRITORY + 常数列 + 无逐格条件` 的 shadow 双跑。

这一步不会立刻改变玩家数值，但会回答三个关键问题：

- 常见的 194 个 program 中有多少能一次覆盖？
- 平面是否真的能把实例成本降为零？
- 哪些 stat 其实没有完整 reader？

### 22.2 不建议的第一步

不要先做以下任一动作：

- 直接把 `SELECTOR_MAX_CELLS` 改大；
- 直接删除所有 32；
- 打开现有 v1 平面并发布；
- 在平面尚未双跑前从生成器移除实例；
- 先删卡面文案，再慢慢补效果。

### 22.3 判断标准

如果第一阶段能证明：

- 32 格内逐位一致；
- >32 格完整覆盖；
- 逐格实例为 0；
- 空闲日重建为 0；
- worker/main 一致；

那么取消 32 格限制就是一个可控的迁移项目，而不是一次不可预测的全局重构。

如果以上任一条无法证明，就不应把“删除 32”作为性能改造的副产品发布。
