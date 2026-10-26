# 理念地块效果取消“32 格”限制 —— 加速精简版实施方案（v2）

| 项目 | 内容 |
|---|---|
| 日期 | 2026-10-26 |
| 状态 | 方案，尚未改运行时代码 |
| 取代关系 | 细化并替代 [20-cell-program-cap-removal-plan.md](20-cell-program-cap-removal-plan.md) 的实现路径；v1 的问题分析、不变量、测试矩阵仍然有效 |
| 前提 | 用户已接受“取消上限带来的数值平衡变化”，目标：尽快、尽早、高性能、稳健 |
| 一句话 | **把“逐格 Effect 实例”换成 ModifierRuntime 内的“派生地块层（Derived Cell Layer，DCL）”。所有 Economy 读者零改动，天然只有一个读者。** |

---

## 0. 相对 v1 的核心变更

| # | v1（doc 20） | v2 | 收益 |
|---|---|---|---|
| 1 | 新建 `CellStatOverlay` + 统一入口 `effective_cell_stat_q16`，所有读者改读它 | 平面落在 `ModifierRuntime` 内部，作为 `effective_value()` 的**第 4 个贡献源** | 读者完整性由构造保证，不需要逐个改读点，也不会漏读点 |
| 2 | Economy COMMIT 中 pending 表 + swap + effective_day 机制 | 复用 Modifier 既有“命令队列 → publish 阶段单写者”边界 | 不新建线程交接设施，生效日天然确定 |
| 3 | worker 权威需要专门交接面（Q1，最高风险） | **不需要**：理念 worker POD 不做实例 reconcile，实例调和一直在主线程（见 §1.4） | 删除整条高风险工作线 |
| 4 | 数值语义“镜像 Modifier 公式” | 直接复用 `scaled_add / scaled_factor` 与同一份 `(base+Σadd)×Πfactor` 聚合 | 数值天然逐位一致 |
| 5 | 全量 selector 同批设计 | 按**实测 program 分层**（§2），先切 56%，再切 SOURCE_COUNT/条件 | 首个玩家可见版本更早 |
| 6 | 新增 `plane_owned` 写入 Effect catalog | 资格由原生纯函数判定，GDScript/生成器读同一标记，**不动 Effect POD/ABI** | 少一次 ABI/PKEF 版本抬升 |
| 7 | v1 现有平面（`ideology_cell_program.h` + Economy 合并）继续改造 | **整体删除**（M3），净删代码 | 不留双语义 |

---

## 1. 本轮新增的代码事实（均已读源码核对）

### 1.1 受影响 program 的真实分布

对 `data/ideologies/default_ideology_effects.tres` 的 288 个 program 做脚本分类（域 2 = 地块域，共 272 个）：

| 桶 | 数量 | 特征 | 受 32 格影响 |
|---|---:|---|---|
| A. `OWN_TERRITORY`，无条件，无 ramp，常数 | **94** | 最简单 | 是 |
| B. `OWN_TERRITORY` + ramp | **59**（其中 35 个多命令） | 系数来自国家级标量 `country.*_cell_count`，每国一个数 | 是 |
| C. `OWN_TERRITORY` + 地块条件 | **34**（另 7 个同时带 ramp） | 条件按目标格求值 | 是 |
| D. `TAG_SOURCE_COUNT`（16） | **66** | 每格系数 = `min(count,cap)/cap` | 是 |
| E. `TAG_SOURCE_R1`（14） | **5** | 来源环并集 | 是 |
| F. kind 0（anchor 单格） | 2 | 只命中 1 格 | **否** |
| G. `family.city.*` 共 5 个（`v2_forge_ring`、`v3_vein_dominance`、`v4_iron_throne`、`v5_stacked_workshop`、`v6_guild_monopoly`），kind 6/7/8/11 | 5 | 生成器里标注为“诊断探针”（`generate_ideology_catalog.py:1999-2030`），`selector_cap` 显式为 8 / 18，由 `ideology_mechanism_matrix_test` 钉住 | **否**（本来就不是 32，也不是玩家平衡内容） |

**结论：265 个经济地块 program（A–E）全部可由 DCL 承载；其余 7 个地块域 program 不受 32 格影响，保持原样。不存在需要特殊处理的 selector。**

> 更正：上一版把 `family.city.*` 的 kind 8/11 描述为“可能超过 32 格”。核对生成器后发现它们的 `selector_cap` 显式是 8，并且是机制诊断探针，所以不构成例外。

所有 272 个地块 program 的 `lifecycle = 0`；`stack_policy` 只有 3 个 `REPLACE`、1 个 `ADD_STACK(5)`、1 个 `ADD_STACK(4)`。

### 1.2 它们写入的 stat 只有 6 个读取族

按命令行统计（`definition_key`）：

| stat 族 | 命令行数（约） | 读点（全部走 `ModifierRuntime::effective_value`，GROUP 域 = cell id） |
|---|---:|---|
| `economy.city.building.<type>_factor` | 132 | `economy_runtime.cpp:11137-11141`、`11301-11305` |
| `economy.city.output_factor` | 79 | `modifier_runtime.cpp:1785`（`economy_building_output_factor` 内部），调用点 `economy_runtime.cpp:11135`、`11309` |
| `economy.city.good.<g>.output_factor` | 42 | `economy_runtime.cpp:7183-7226`（`collect_scope_stat_entries` + `effective_value`） |
| `economy.city.birth_factor` | 30 | `economy_runtime.cpp:7085` |
| `economy.city.need.<n>.consumption_factor` | 29 | `economy_runtime.cpp:7088-7091` |
| `economy.city.resource.*.regen_factor` | 15 | `economy_runtime.cpp:4388-4397`（**worker 作业内**读取） |

> 修正 v1 §5.6：`economy.city.output_factor` **有** reader，只是走 `ModifierRuntime::economy_building_output_factor`，而不是 Economy 的逐格缓存。v1 的“统一入口”如果只改 Economy 侧会漏掉它。DCL 放在 `effective_value()` 内部则无此问题。

### 1.3 ModifierRuntime 的聚合语义（DCL 必须对齐）

`modifier_runtime.cpp:1405-1429`：

```text
value = (base + Σ sum_add) × Π bucket_factor     // 3 个桶：GLOBAL / GROUP(cell) / ENTITY
value = clamp(value, stat.min, stat.max)
```

- `scaled_add = term.add × stacks × magnitude`；`scaled_factor = (1 + (term.factor − 1) × magnitude) ^ stacks`（`:768-781`）。
- 每个 `(stat, scope, scope_id)` 一个 `Bucket`，增量维护 `sum_add` / `product_nonzero` / `zero_factor_count`。
- **每个 stat 有 `aggregate_policy`**：`SUM`、`MAX_SOURCE`、`TOP_N(source_cap)`（`:800-874`）。非 SUM 的 stat 需要逐来源去重，**不能用预折叠层表示**。
- 每次改桶都 `bump_stat_version(stat)`；所有 Economy 缓存（building 因子缓存的 `mod_version`、城市因子刷新、good 输出 CSR）都以 `stat_bucket_version` 做失效键。
- `collect_scope_ids / collect_scope_stat_entries` 遍历 `store.buckets` 找“哪些 cell 有覆盖”。

这意味着：**只要 DCL 在 `effective_value`、`collect_scope_*`、`stat_bucket_version` 三处接入，现有全部缓存与读者自动生效并自动失效。**

### 1.4 worker 权威不是障碍

- `runtime_ideology_pod.cpp` 不含实例 `activation`；`apply_pod_snapshot` 明确不 reconcile（`ideology_runtime.cpp:4926` 注释）。
- 实例调和只发生在主线程：`reconcile_effect_activations`（`:2256`），触发点 `:2997 / :3045 / :3258 / :3348`，脏标记 `_instance_refresh_dirty`（`:871 / :2967 / :6389`）。
- DCL 的“脏”标记挂在**同一批位置**，即可同时覆盖主线程权威与 worker 权威，无需 POD/ABI 改动。

### 1.5 硬截断不止一处

`SELECTOR_MAX_CELLS` 在理念侧共 5 处生效，M3 全部要处理：

1. `ideology_runtime.cpp:2017`（SOURCE_COUNT：`effect_stable_cap`）
2. `:2027-2030`、`:2043`、`:2056`（TAG_SOURCE R1/R2：source cap、ring cap、union cap）
3. `:2133-2134`（`collect_effect_activations`：`targets.resize(32)` —— 独立于 selector 的第二道截断）
4. `ideology_runtime.cpp:577`、`:1881`（校验与 `target_cap` 解码）
5. `economy_runtime.cpp:2389-2431`（`collect_effect_target_cells` 的 OWN_TERRITORY / TAG_ANY_CELL 分支）

保留不动（有状态实例与家族路径仍需要）：`effect_runtime.h:272` 常量本身、`effect_runtime.cpp:1008-1012` 校验、`economy_runtime_family_buff.cpp:2390-2495`。

### 1.6 激活倍率链（表构建器必须复用，不得重写）

`collect_effect_activations`（`:2093-2186`）对每个 program 计算：

```text
activation_scale = magnitude_scale_for(country, program)   // X5 卡改卡，synergy 乘积，[0.25, 4]
                 × copy_scale                               // copier 卡：level>=2 为 0.8
                 × school_strength_scale (除非 program 自己写学派强度)
clamp [0.25, 4]
target_scale = activation_scale × target.magnitude_scale_q16   // SOURCE_COUNT 为 min(count,cap)/cap
```

v1 的 `build_cell_program_table`（`:4933`）完全没有这条链、没有条件、没有 ramp。

---

## 2. 目标架构：Derived Cell Layer（DCL）

```mermaid
flowchart LR
    S["理念状态变化<br/>装卡/卸卡/升级/协同/学派/精神晋升"] --> D["Ideology: 标记 plane_dirty<br/>(与 _instance_refresh_dirty 同位置)"]
    D --> T["Ideology: 生成 PlaneProgramSet<br/>(纯函数, 复用激活倍率链)"]
    T --> M["Economy 物化器 (epoch 捕获阶段)<br/>tag/领土/邻接/metric -> 每国 LayerBatch"]
    M --> Q["ModifierRuntime 命令队列<br/>COMMAND_SET_CELL_LAYER"]
    Q --> P["Modifier publish 阶段 (单写者)<br/>替换该国层贡献, bump_stat_version"]
    P --> R["effective_value(GROUP=cell)<br/>多一个层贡献源"]
    R --> C["现有全部读者与缓存<br/>(零改动, 自动失效)"]
```

### 2.1 数据结构（Modifier 侧，热路径零 String/Variant）

```cpp
struct CellLayerEntry {            // 一个国家对一个 (stat, cell) 的已折叠贡献
    int32_t stat_id;
    int32_t cell;
    double  add;                   // Σ scaled_add
    double  factor;                // Π scaled_factor（零因子单独计数，沿用 bucket 规则）
    int32_t zero_factor_count;
};
struct CellLayerBatch {            // 不可变、按 (stat, cell) 升序
    uint32_t country_slot;
    uint64_t country_handle;       // 带 generation 的 handle，防 slot 复用
    uint64_t content_digest;       // 内容摘要，用于“摘要不变则跳过”
    std::vector<CellLayerEntry> entries;
};
```

- **聚合层**：`LayerTable`，key = `(stat_id << 32 | cell)`，开放寻址平铺哈希；value = 各国贡献之和。
- **快速旁路**：`layer_stat_mask[stat_id]`（1 字节/stat）。无层的 stat 在 `effective_value` 多花 **1 次字节读取**，其余行为不变。
- **更新方式**：每国一个 batch，替换时只重算受影响 stat 的聚合项；每个受影响 stat `bump_stat_version`。
- **确定性**：国家按 slot 升序、条目按 `(stat, cell)` 升序折叠；全部在 Modifier publish 阶段单线程完成。
- **读路径不写共享计数**：`effective_value` 现有的 `mutable query_count / bucket_reads` 是非原子计数（resource worker 并发读取时已经是良性竞态）；层读取不新增任何共享写。

### 2.2 为什么放在 Modifier 里（相对 Economy 侧包装）

| 维度 | DCL 在 Modifier 内 | Economy 侧包装 `economy_cell_stat()` |
|---|---|---|
| 读者完整性 | 构造保证（含 UI explain、`evaluate_modifier_stat`、测试） | 需逐点改并用 source-scan 防回退；`modifier_runtime.cpp:1785` 在 Modifier 内部，包装够不着 |
| 公式一致 | 同一函数 | 需要镜像，clamp 次序易偏 |
| 缓存失效 | `stat_versions` 自动 | 需要把层版本塞进每个缓存键 |
| 线程边界 | 复用 Modifier publish 单写者 | 需自建 |
| 代价 | 需要 Modifier owner 同意新增“派生只读层” | 无架构争议 |

**默认采用 DCL。** 若架构评审不通过，回退方案见 §8 R-fallback（M0 即可判定，不浪费后续工作：物化器与理念侧表构建器两者通用）。

### 2.3 层的边界（防止滥用）

- 只允许 **ECONOMY 域、GROUP(cell) 域、`aggregate_policy == SUM`** 的 stat 使用层；其余在目录编译期拒绝（fail closed）。
- 层不入档、不进 PKCM、不产生 Modifier 句柄/事件/ACK；`report()` 中单独列计数。
- 层条目是**派生量**：来源 = 理念状态 + Economy tag/领土/邻接/metric。重建函数是纯函数。
- 理念仍是唯一状态权威，层不可被 GM/其他系统直接写入。

### 2.4 物化器（Economy 侧，只读 epoch 快照）

输入：某国的 `PlaneProgramSet`（program 描述 + 已含倍率链的 magnitude）、tag 快照、领土 CSR、邻接图、（条件 program）metric 采样。输出：该国 `CellLayerBatch`。

| 桶 | 物化方式 | 复杂度 |
|---|---|---|
| A | 遍历本国领土，tag 位过滤（param1=0 为全部），写 `(stat, cell)` | O(领土) |
| B | 同 A，但 magnitude 按国家标量求值一次（ramp：READ_METRIC→MIN→MUL）。标量变化才重建 | O(领土)，标量按国家缓存 |
| C | 同 A，再对每个命中格按 program 的 metric mask 采样并求值条件 | O(命中格 × 条件数) |
| D | 对来源 tag 格做 BFS 半径 r，累计 `source_counts[cell]`（`ideology_runtime.cpp:1990-2010` 现成逻辑），`mag = base × min(count,cap)/cap` | O(S×6×r + N) |
| E | 来源格取并集环，去重 | O(S×6×r) |

- **同 stat 多 program 先折叠再输出**，一国一 stat 一格最多一条。
- 折叠调用 `ModifierRuntime` 的 `scaled_add / scaled_factor`（提取为静态纯函数 `fold_term(term, stacks, magnitude_q16)`），不重新推导公式。
- **去掉全部 target cap**；`source_cap`（每格最多计入 N 个来源）是玩法语义，保留且与 target cap 分开。
- 只扫描**脏国家**，且只重算依赖变化的 program（见 §2.5）。

### 2.5 失效与依赖（性能核心）

| 事件 | 触发 | 重建范围 |
|---|---|---|
| 装卡/卸卡/升级/协同翻转/学派强度/精神晋升/X5 倍率变化/读档 | 理念 `plane_dirty` | 该国 `PlaneProgramSet`，随后该国全部 program |
| tag 位翻转 | tag 快照构建时按 tag 计算 per-tag 修订号（逐 64 位字比较，O(cells/64×tags)） | 仅依赖该 tag 的国家 × program |
| 领土归属变化 | `cell_country` 差异 | 新旧两国 |
| 国家标量（ramp）变化 | 国家级 tag 计数修订号 | B 桶对应 program |
| 条件 metric 量化桶跨阈值 | 沿用 `07-metric-quanta` 的量化 | 仅 C 桶对应 program 的命中格 |
| 邻接图变化 | 邻接版本号 | D/E 桶 |
| 空闲日 | — | **0 次物化、0 次命令、0 次 bump** |

每个 program 编译出 `tag_dep_mask / metric_dep_mask / needs_territory / needs_neighbors`，用于上表过滤。

### 2.6 生效日与写入边界

```text
第 D 天 Economy epoch 捕获：物化 → 入 Modifier 命令队列
Modifier publish（按 (effective_day, producer, sequence) 排序，沿用既有规则）：应用 → bump 版本
第 D+1 天 Economy 读取：看到新层
```

- 新增 `COMMAND_SET_CELL_LAYER`（producer 使用独立常量，sequence 单调）。
- 生效日规则与 v1 D6 一致，不依赖 worker 到达时刻。
- **M0 必须核实**：daily graph 中 `MODIFIER_GRAPH publish` 与 Economy epoch 捕获的相对顺序、以及 Modifier 在 Economy worker 作业期间是否严格只读。若与上图不符，调整“入队点”，不改 DCL 结构。

### 2.7 读档

- DCL 与物化器输出不入档。
- 恢复顺序沿用 PKTR → PKEF → PKID → PKCM；**PKID 恢复后立即 `plane_dirty=true`，在首个 Economy 读取之前完成物化并 flush**。
- 否则读档后第 1 天会丢失加成，造成“连续运行”与“存档重载”结果分叉。M1 必须有专门的黄金测试（§5.3）。

---

## 3. 实施分层与里程碑

> 估算是有效开发日（单人，含测试与构建），**不是承诺**。M0 结束后按实测重估。

### 并行泳道（M0 之后）

| 泳道 | 内容 | 依赖 |
|---|---|---|
| L1 原生层 | Modifier DCL、物化器、理念侧表构建器 | M0 |
| L2 内容层 | 生成器 `plane` 标记、卡面文案、预算计算 | M0 的资格判定 |
| L3 验证层 | 双跑 harness、>32 fixture、黄金测试 | L1 接口冻结后即可并行写 |

### M0 —— 基线与 5 项必须先证实的事实（1–2 日）

产出一份“M0 基线报告”，包含机器、DLL 时间戳、commit、catalog hash，以及：

1. **线程/顺序**：Modifier publish 与 Economy epoch、resource worker 作业的先后与读写互斥（加调试断言）。
2. **聚合策略**：§1.2 六个 stat 族涉及的全部 stat 是否都是 `AGGREGATE_SUM`；不是的从资格里剔除并记录。
3. **ACK 门控**：`reconcile_effect_activations` 现在以“意图状态”还是“ACK 确认状态”创建实例；DCL 的表构建必须使用**完全相同**的门控，避免 ACK 回滚时出现一天的错误加成。
4. **tag 修订号**：tag 快照是否已有 per-tag 变化信息；没有则在快照构建中补（O(cells/64×tags)）。
5. **实例预算基线**：当前每国 `max_concurrent_instances` 实际占用、`ideology_instance_budget_test` 的 9×32 假设、B1–B6 现状。

退出标准：以上 5 项都有结论；DCL（默认）或 Economy 侧包装（回退）二选一已定；>32 格 fixture 能稳定复现旧路径截断。

### M1 —— DCL 内核 + A/B 桶（4–6 日）→ 约 56% 内容

范围：A（94）+ B（59）= **153 个 program**。

任务：
- `ModifierRuntime`：`CellLayerBatch`、`LayerTable`、`layer_stat_mask`、`COMMAND_SET_CELL_LAYER`、`effective_value / collect_scope_* / stat_bucket_version` 接入、`fold_term` 提取。
- `NativeIdeologyRuntime`：
  - 抽取 `activation_scale_q16(country, state, templ)` 供**实例收集器与表构建器共用**；
  - `build_plane_program_set(country)`：复用 `copy_source_programs` / `effective_selector_metadata`；
  - `collect_effect_activations` 对 plane-owned program `continue`（唯一的实例路径改动）；
  - `plane_dirty` 与 `_instance_refresh_dirty` 同位置置位。
- Economy 物化器（A/B 桶）+ 国家级标量缓存。
- 资格判定纯函数 `program_plane_eligible()`：域=cell、selector ∈ 已支持集、stat ∈ 白名单且 SUM、`lifecycle=0`、`stacks=1`、条件可编译。
- 三态开关 `plane_mode`：`OFF`（全实例，旧行为）/ `SHADOW`（实例照常，同时物化但**不应用**，只记差异计数）/ `ON`（plane-owned 不创建实例）。每个 tier 单独的启用掩码。
- 计数器：`cell_layer_builds / skips / commands / entries / countries_rebuilt / cells_visited / unsupported / legacy_caps / truncated(必须 0) / effect_instances_avoided`。

测试（均为新增）：
- `ideology_cell_plane_parity_test.gd`：双世界逐格比较；31/32/33/200+/全国。
- `ideology_cell_plane_invalidation_test.gd`：装卸卡、升级、协同、学派、tag 翻转、领土变化。
- `ideology_cell_plane_save_golden_test.gd`：连续运行 vs 存档重载，D+1 世界状态哈希相等。
- `ideology_cell_plane_idle_test.gd`：空闲 30 天各计数为 0。
- `runtime_modifier_pod_test.gd` 扩展：层对 `effective_value` 的聚合与 clamp、SUM 以外策略被拒。

退出标准：A/B 桶在 `SHADOW` 下 32 格内逐位一致；`ON` 下逐格实例数为 0；>32 格完整覆盖；空闲日计数为 0；基线对比无回退。

### M2 —— C/D/E 桶（5–7 日）→ 100% 经济地块 program

范围：C（41）、D（66）、E（5）= **112 个 program**。

任务：
- C：物化器接入 program 的 `metric_mask` 采样（复用现有地块 metric 采样函数）与条件求值；条件作用于**目标格**，source 只按 tag 过滤；用 metric 量化桶限制重算。
- D：复用 `source_counts` BFS，`mag = base × min(count,cap)/cap`，`source_cap` 保留；target cap 彻底不适用。
- E：来源环并集，去重，不排序截断。
- 失败处理：邻接缺失时物化 **fail closed 并计数**，不退化为“没有效果”也不静默走实例。

测试补充：
- source 满足 / target 不满足、反之（条件方向）。
- 100+ 来源格、半径 1–4、`source_cap` 1/3/15、来源环重叠。
- 邻接缺失 → 明确错误码，不是空结果。
- 一个必须有的“空跑防护”：fixture 里 `bind_map_data()` + 至少一次 economy 切片（见 skill：无邻接则所有环为空，测试会假通过）。

### M3 —— 切换、清理与呈现（2–3 日）

- 生成器（唯一内容源）：plane-owned program 不再写 `selector_cap`，卡面去掉“最多影响 32 个目标地块”，改为“影响全部符合条件的本国地块”；SOURCE_COUNT 继续显示“每个目标地块最多计入 N 个来源”。重新生成 `.tres`，**不手改**。
- 预算：`_program_live_target_cap()` 对 plane-owned 返回 0；`ideology_profile.gd`、`ideology_effect_report.gd`、`ideology_instance_budget_test.gd` 同步；`max_concurrent_instances` 只统计真实实例。
- 删除理念侧 `target.resize(SELECTOR_MAX_CELLS)`（`:2133-2134`）对 plane-owned 的约束与 §1.5 其余理念侧截断；常量改名 `LEGACY_INSTANCE_SELECTOR_MAX_CELLS` 并写清用途（Effect 实例与家族路径仍用）。
- **删除 v1 平面**：`ideology_cell_program.h`、`build_cell_program_table`、`publish_ideology_cell_programs`、`set_ideology_cell_plane_enabled`、`economy_runtime.cpp` 中 `refresh_city_output_modifier_factors` 的平面合并段与 `set_ideology_cell_programs`。
- UI 命中数：新增只读 native explain（`matched_total` 为真实命中数；UI 采样上限只截断返回列表，不影响效果），仅面板打开时调用；`effect_instance_report` 不再被当作命中依据。
- 文档：`docs/cpp-dots-runtime/native-ideology-runtime.md`、本 skill、`05-implementation-status.md` 同步。

### 测试迁移（贯穿 M1–M3，计入工期）

约 15–20 个理念测试通过 `list_modifiers`、`effect_instance_report`、`city_output_factor_for_test`、`evaluate_modifier_stat` 断言“逐格实例/Modifier 行存在”，例如 `ideology_card_content_worker_test`、`ideology_tag_snapshot_stress_test`、`ideology_country_ramp_worker_test`、`ideology_card_content_test`、`ideology_effect_worker_forward_test`、`ideology_effect_instance_test`、`ideology_cell_card_worker_test`、`ideology_tag_source_selector_test`、`ideology_x1b_source_count_test` 等。plane-owned program 不再有实例，这些断言要改成读新增的 `explain_cell_layer(stat, cell)` / `effective_value`。这是真实工作量，v2 初稿漏算。

- 先提供 `explain_cell_layer(stat, cell)`（返回该国各 program 对该 `(stat, cell)` 的 add/factor/magnitude 来源），再批量迁移断言；不允许删断言了事。
- skill 中“用 `list_modifiers(...).magnitude_q16` 断言幅度”的约定，对 plane-owned program 改为 `explain_cell_layer`。

### 总工期与里程碑价值

| 里程碑 | 累计估算 | 累计覆盖（经济地块 265） | 玩家可见 |
|---|---:|---:|---|
| M0 | 1–2 日 | 0 | 否 |
| M1 | 6–9 日 | 153（58%） | 已确认允许在 M1 末对 A/B 桶打开 `ON`（配合 M3 的文案） |
| M2 | 12–17 日 | 265（100%） | — |
| M3 | 14–20 日 | 265 | 全量发布 |

> 比 v1 的 20–35 日更短，原因：删除 worker 交接线、删除逐读者改造线、复用现成 BFS/倍率链/聚合公式。已把测试迁移计入。仍需 M0 实测后修正。

---

## 4. 发布策略（保持稳健的同时尽快）

1. M1 完成后先以 `SHADOW` 跑一轮全量内容（含 64/512 国 fixture）：差异计数必须为 0。
2. 按 tier 打开 `ON`：A → B → C → D → E，每一档单独回归。任何一档出现差异，只回退该档的启用掩码，不回退代码。
3. 所有 tier 通过后，在 M3 默认 `ON`，旧实例路径只剩下 F/G 与非地块效果。
4. catalog hash 因卡面文案/预算变化而改变，旧 PKID / PKEF / PKCM 按现有规则 **fail closed**（用户已接受；发布说明里写明一次）。

---

## 5. 验证设计

### 5.1 金标准双跑

同一 seed、同一固定地图（含 >1000 格国家、100+ 来源格、200+ 条件格）：

| 世界 | `plane_mode` |
|---|---|
| W0 | `OFF`（全实例） |
| W1 | `ON` |

逐 `(cell, stat)` 比较 `effective_value`（Q16 取整后）：
- 32 格内：**逐位相等**（同一 `fold_term`；允许值域靠近舍入边界的 fixture 单独审计，报告 `max_q16_delta`，要求 0）。
- 32 格以上：W0 是 W1 的子集，且子集部分相等。
- ADD、MULTIPLY、cut（SUBTRACT）、ramp、copier、X5 倍率、学派强度、SOURCE_COUNT、条件各一个样例。

### 5.2 敏感性反向验证（证明测试不是空转）

| 故意破坏 | 应失败的测试 |
|---|---|
| 恢复 target 截断 | >32 覆盖测试 |
| plane-owned 仍创建实例 | 零实例测试 |
| 层未 `bump_stat_version` | 失效测试（building 因子缓存应读到旧值） |
| 层对非 SUM stat 生效 | 资格测试 |
| 条件作用在 source 而非 target | 方向测试 |
| 用 `source_cap` 当 target cap | SOURCE_COUNT 测试 |
| 读档后不立即物化 | 存档黄金测试 |
| 同一国家重复提交同一 batch | 摘要跳过 / 零 bump 测试 |

### 5.3 必须有的黄金测试

- **存档分叉测试**：连续跑到 D+N 与（D → 存档 → 读档 → D+N）的 Economy 逐格因子哈希相等。
- **空闲日**：30 天无任何结构事件时 `layer_builds / commands / stat_version_bumps` 增量为 0。
- **ACK 回滚**：装卡后拒绝 ACK，层中不得残留该卡贡献（依赖 M0 第 3 项结论）。
- **精神晋升**：晋升不重放一次性效果，层贡献连续。

### 5.4 构建与命令纪律（沿用 skill）

- 仅当 stdout 含 `scons: done building targets.` 才算构建成功。
- 测试逐个运行；每次改 C++ 后记录 DLL 时间戳，测试前后不变。
- `git diff --check`。

---

## 6. 性能设计

### 6.1 复杂度

| 操作 | 复杂度 | 说明 |
|---|---|---|
| `effective_value` 增量 | 无层 stat：+1 字节读；有层 stat：+1 次平铺哈希探测 | 仅 `GROUP` 域 |
| 国家物化（A/B） | O(领土 + 条目数) | tag 位图判断 |
| 国家物化（C） | O(命中格 × 条件数) | 量化桶限制重算 |
| 国家物化（D/E） | O(S×6×r + N) | 与目标数无关 |
| 层替换 | O(该国条目 + 受影响 stat 的聚合项) | 每国一次 |
| 空闲日 | 0 | 由依赖掩码保证 |
| Effect 实例 | 与命中格数**无关** | 恒为 0 |

### 6.2 门槛（提议值，M0 基线后由用户确认；未实测前不得声明达标）

沿用 skill 既有门槛：64 国×12 张卡 p95 ≤ 0.35 ms、512 国续跑 p95 ≤ 0.42 ms、单次 native ≤ 1 ms、6400 格 class-opinion 中位数 < 1 ms，并新增：

| 场景 | 门槛 |
|---|---|
| B7：单国 >1000 格，目标数 32 → 全国 | p95 增幅在预算内（实例数恒 0） |
| B8：100+ 来源格 | 物化耗时与来源数近似线性 |
| B9：200+ 格条件过滤 | 单日条件重算耗时记录 p50/p95/p99 |
| B5：空闲 30 天 | `layer_builds = 0`、`layer_commands = 0`、`effect_transactions_created = 0` |
| 缓存连带失效 | 记录每次层变化触发的 building 因子缓存 miss 数，作为后续优化（O1）输入 |

### 6.3 已知可后置的优化

- **O1**：层暴露 `drain_dirty_cells(stat)`，让 building 因子缓存只失效被触及的建筑组，而不是 stat 级全局失效（当前实例路径同样是全局失效，所以不是回退，只是进一步优化）。
- **O2**：A 桶且全领土无 tag 的 program 可存为“国家统一层”（每国每 stat 一条），读时按 `cell_country_slot` 命中。仅当 M1 实测显示条目数/内存成为瓶颈才做。

---

## 7. 不变量（实现者自查清单）

1. plane-owned program **从不**创建逐格 Effect 实例，也不以 cap 兜底。
2. 层只接受 ECONOMY / GROUP / SUM；其余目录编译失败。
3. 表构建器与实例收集器**共用同一个** `activation_scale_q16`；只有 plane-owned 判定不同。
4. 层写入只发生在 Modifier publish 阶段；读路径不写共享计数。
5. 层与物化结果不入档；读档后首个 Economy 读取之前必须已重建。
6. 物化遍历顺序固定：国家 slot ↑ → program dense id ↑ → `(stat, cell)` ↑；全部整数/同一 `fold_term`。
7. `source_cap` 与 target 覆盖分开；`target_cap == 0 → 32` 的旧解释只存在于实例路径。
8. 物化缺邻接/缺 tag/缺 reader 时 fail closed、计数、不静默。
9. `effect_instance_report` 只表示实例；命中数来自 native explain。
10. 不引入 GDScript 侧选择器逻辑、不引入第二个 Modifier 实例写入方。

---

## 8. 风险与缓解

| 风险 | 缓解 |
|---|---|
| 架构评审不接受 Modifier 内置派生层（R-fallback） | M0 判定。回退为 Economy 侧 `economy_cell_stat()` 包装：改 §1.2 的 5 组读点 + `modifier_runtime.cpp:1785` 的内部读取，缓存键加入层版本；物化器、表构建器、测试全部复用。额外工期约 +3–5 日 |
| 非 SUM stat 混入 | 目录编译资格检查 + M0 第 2 项清单 |
| ACK 回滚时层残留 | M0 第 3 项；表构建使用与实例调和完全相同的门控；专项测试 |
| 读档后第 1 天分叉 | §2.7 与黄金测试 |
| 条件 program 每日重算过重 | metric 量化桶 + 依赖掩码；B9 测量；必要时对条件重算按 `cadence_days` 错峰（需用户确认语义） |
| 层变化导致 building 因子缓存整体失效 | 与旧路径同量级；O1 可后置优化；M1 记录 miss 计数 |
| 精度边界 | 与旧路径共用 `fold_term`；双跑报告 `max_q16_delta` |
| 迁移期双语义 | 三态 `plane_mode` + tier 启用掩码；M3 删除 v1 平面 |
| 平衡突变（已接受） | 发布说明；可在 M1 末输出“各卡实际放大倍数”表供设计复核，不阻塞开发 |
| 测试用小地图掩盖问题 | 固定 >32、>1000 格 fixture；邻接缺失必须报错 |

---

## 9. 待你确认的决策

| 编号 | 问题 | 推荐 |
|---|---|---|
| D1 | 是否同意在 `ModifierRuntime` 内新增“派生地块层”（理念仍是唯一状态权威，层只读、不入档、无句柄） | 同意（否则走 R-fallback，+3–5 日） |
| D2 | ~~H 桶 `family.city.*`~~ | **已关闭**：5 个诊断探针 `selector_cap` 显式为 8/18，不受 32 影响，保持原样 |
| D3 | 是否允许 M1 末对 A/B 桶先行 `ON`（153/265），其余保留旧行为直到 M2 | **已确认允许** |
| D4 | 条件 program 性能不达标时，是否接受“按 `cadence_days` 错峰重算” | M0/M2 实测后再定 |

---

## 10. 完成定义（DoD）

**功能**
- [ ] 265 个经济地块 program 全部 plane-owned，逐格实例数为 0。
- [ ] 32 格内与旧路径逐位一致；32 格以上覆盖全部符合条件格。
- [ ] `source_cap` 保持玩法语义；target cap 不再存在于 plane 路径。
- [ ] 装卡/卸卡/升级/协同/学派/tag/领土/ACK 回滚/精神晋升/读档均正确失效。
- [ ] 主线程权威与 worker 权威结果一致。

**内容与 UI**
- [ ] `.tres` 由生成器重建；卡面不再出现永久地块卡的 32 文案。
- [ ] 命中数来自 native explain，`matched_total` 不受 UI 采样影响。
- [ ] 覆盖率报表：每个地块 program 为 `plane_owned` 或带明确 `legacy_reason`。

**存档**
- [ ] 层与物化输出未入档；读档黄金测试通过；旧档 fail-closed 已验证。

**性能**
- [ ] M0 基线 + 改动后同机同 DLL 同 seed 对比；空闲 30 天各计数为 0；无未实测的性能声明。

**工程**
- [ ] 构建 stdout 含 `scons: done building targets.`；相关测试逐个通过；`git diff --check` 通过。
- [ ] v1 平面代码已删除；文档与 skill 已同步。

---

## 11. 附：关键源码定位（行号会漂移，实现前需重新搜索）

| 内容 | 位置 |
|---|---|
| 聚合与读取 | `gdext/src/modifier_runtime.cpp`：`effective_value`(1405)、`scaled_add/scaled_factor`(768-781)、`rebuild_bucket`(787)、`add/remove_instance_to_buckets`(890-957)、`collect_scope_*`(1451-1504)、`stat_bucket_version`(1506)、`economy_building_output_factor`(1780) |
| 桶结构 | `gdext/src/modifier_runtime.h`：`Bucket`、`Store`(267-338) |
| Economy 读点 | `economy_runtime.cpp`：4388-4397、7081-7095、7183-7226、11135-11141、11301-11311 |
| 理念激活/调和 | `ideology_runtime.cpp`：`resolve_effect_targets`(1852)、`collect_effect_activations`(2093)、`reconcile_effect_activations`(2256)、`build_cell_program_table`(4933，将删除) |
| v1 平面 | `ideology_cell_program.h`；`world_ext_ideology.cpp`：`publish_ideology_cell_programs`(322)、开关(422)；`economy_runtime.cpp`：`set_ideology_cell_programs`(7138) |
| 32 格常量与镜像 | `effect_runtime.h:272`、`ideology_effect_definition.gd:93`、`ideology_catalog.gd:_program_live_target_cap`、`generate_ideology_catalog.py`（`Prog.selector_cap`、卡面文案） |
