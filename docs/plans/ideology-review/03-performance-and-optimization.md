# 理念系统 Review（三）：性能判断与优化方法

> 问题：现在的实现方法能不能保证最高性能？
> 答案：**不能。** 每格卡现在走的是「每格一个 Effect 实例 + 整块 metric slab + 事务 + ACK」，这是一条重路径。内容规模一上来，它会同时撞上容量上限、主线程时延和事务膨胀。
> 本文给出：成本模型、热点证据、短期优化（在现有架构内可以做的）、目标架构（系数平面）、线程模型，以及基准测试与门槛。
> 前置阅读：`01-issues-and-fixes.md`（P1-A/B/C 和性能直接相关）。还要加载 skill：`project-keynes-headless-perf`、`project-keynes-runtime-hotloop-optimization`。
> 行号仅供参考，动手前用 `rg` 复核。

---

## 0. 结论

1. **现在没有任何基准数据**（设计文档 §38.5 自己也承认了）。stress 测试里没有每格 program。所以「已经优化过」这个说法没有依据。**先建基准（§6），再优化。**
2. **容量先于速度出问题。** `max_instances = 4096`。按设计文档的规模估算：64 国 × 12 张在场卡 × 每张卡 32 格 = 24576 个实例，是上限的 6 倍。平均下来，每国只够放 2 张满编的每格卡。
3. **现在空闲成本不为 0**：P1-B 让 worker 每应用一个快照就全量 reconcile；P1-C 让 metric 每天前进，进而触发事务。而 P1-A 修好之后会多出每日刷新，如果不配合修订号门控，空闲成本反而会涨。
4. **最优解是「位图 + 派生列 + 系数平面」（§4）。** 每格效果不再做成实例，改成 Economy 读 stat 时的一次稠密乘加。这样空闲成本为 0，没有 32 上限，没有每格 ACK，tag 变化会自动生效。
5. **过渡期按 §3 的 O1~O10 做。** 先把空闲成本压到 0，把单次 reconcile 的常数压下来。

---

## 1. 成本模型（当前实现）

记号：

| 符号 | 含义 |
|---|---|
| `C` | 国家数 |
| `A` | 每国在场、带托管 program 的卡数 |
| `K` | 每张卡解析出的目标格数，≤ 32 |
| `M` | `FAMILY_METRIC_COUNT`，现在是 68 |
| `N` | 全图格数 |
| `T` | tag 数 |
| `S` | 协同数 |

**单张卡一次 reconcile 的成本：**

| 阶段 | 复杂度 | 说明 |
|---|---|---|
| 字符串查 program | O(串长) × 模板数 | `effect_program_key`（约 1335 行）、`family_effect_metadata_pod`（`effect_runtime.cpp` 约 2772 行） |
| 解析目标 | `OWN_TERRITORY`：O(领土格)；`TAG_ANY_CELL`：**O(N)** | 每次都全量扫一遍 |
| 倍率 | O(S) | `magnitude_scale_for`（约 2102 行）线性扫描全部协同 |
| retire / added 对比 | O(K²) | 约 1568~1597 行是双重循环 |
| 批量提交 | O(K)，但常数大 | 约 1601~1666 行用 Dictionary/Packed 数组组装，要分配内存 |
| metric 采样 | O(K × M) + **首次触发 O(N × T)** | `all_declared` mask 会触发 X7 的国家计数 → 全图 tag 位图重建 |
| metric 发布 | O(K × 卡声明的 metric 数) 次 `set_metric_pod` | 每次调用都执行 `advance_committed_generation` |
| 下游 | 每个 revision 前进的实例 1 笔事务 + Modifier 移除/重加 + ACK | P1-C |

**触发频率：**

- **主线程权威**：只在过渡时触发，所以现在很便宜。但这是因为它压根没做每日刷新（P1-A），不是真的快。
- **worker 权威**：每个新快照都会对全部 C × 全部 idea 触发一次 → O(C × A × (K² + K·M)) + 全量重提交。这些全部发生在**主线程**。

**代入数据粗估**（C = 64，A = 12，K = 32，M = 68）：

- 实例数 24576，超过 4096 的上限，实际会被拒绝。
- metric slab 为 4096 × 68 × 8 B ≈ 2.2 MB（按上限算）。每次全量发布最多要调用十万级次 `set_metric_pod`，每次都有哈希查 instance、写 present、推进 generation。
- 这远远超出 skill 的门槛：64 国 p95 ≤ 0.35 ms，单次 native 调用 ≤ 1 ms。

---

## 2. 热点清单

| # | 热点 | 位置 | 性质 | 对应优化 |
|---|---|---|---|---|
| H1 | worker 快照触发全量 reconcile | `apply_pod_snapshot` 约 778/807 行 | 空闲成本、主线程 | O1 |
| H2 | revision 无条件前进导致事务重放 | `ideology_runtime.cpp` 约 1697 行、`effect_runtime.cpp` 约 2747 行 | 空闲成本、下游放大 | O2 |
| H3 | `all_declared` mask 触发 X7 全图重建 | 约 1715 行 → `economy_runtime.cpp` 约 16314 行 → `family_buff.cpp` 约 1007 行 | O(N·T)，在主线程 | O3 |
| H4 | metric 缓存只在单次 reconcile 内有效 | 约 1698 行 `sampled_by_cell` 是局部变量 | 重复采样 | O4 |
| H5 | 字符串查找 | 约 1305/1335/1453/1527 行 | 常数大 | O5 |
| H6 | O(K²) 对比 | 约 1568~1597 行 | K = 32 时约 1000 次比较/卡 | O6 |
| H7 | Dictionary/Packed 批量组装 | 约 1601~1666 行 | 堆分配、Variant | O7 |
| H8 | `magnitude_scale_for` 扫描全部协同 | 约 2102 行 | O(S)/卡 | O8 |
| H9 | `TAG_ANY_CELL` 扫描全图 | Economy 选择器 | O(N)/卡 | O9 |
| H10 | tag 位图惰性全量重建 | `family_buff.cpp` 约 1007/1063 行 | O(N·T)/epoch，并且线程不安全 | O10 |
| H11 | 非 SUM Modifier 桶每次增删都全量重建 | 设计文档 §38.3 | 只要理念不用就不触发 | 禁用（P2-A） |
| H12 | 每个实例都带 M 列 slab | Effect 实例布局 | 内存和带宽 | §4 |

---

## 3. 短期优化（在现有架构内）

按下面的顺序做。每做完一项，跑一次 §6 的基准并记录。

### O1：签名/修订号门控 + 切片刷新（对应 H1；实现见 Doc 01 P1-A/P1-B）

- 不变量：**输入不变 ⇒ 没有任何卡被访问。**
- 计数器：`instance_refresh_visits`、`instance_submit_batches`、`instance_signature_skips`。
- 切片预算按计数切（比如每次 64 个 idea），保证确定性。
- 预算不要用毫秒。如果想自适应，可以按「待处理队列长度」分档，分档本身也是确定的。

### O2：只在值变化时推进 revision（对应 H2；实现见 Doc 01 P1-C）

- 理念侧用 `metric_digest` 去重，整行跳过。
- Effect 侧做值比较，并把 `metric_observed_revision` 和 `input_revision` 分开。
- 只有值变化时才调用 `advance_committed_generation()`。
- 预期效果：稳定状态下事务数 ≈ 0。

### O3：按需的 metric mask，国家级 metric 和格级分开（对应 H3）

现在的代码为了让 `sampled_by_cell` 缓存能被多张卡共用，用了 `all_declared`。代价是每次采样都要算全部 68 列，其中 X7 的 56..67 是国家级计数。改法：

```cpp
// 1) 先遍历 desired，按格求 mask 并集
std::unordered_map<int32_t, MetricMask> mask_by_cell;   // 或者用 O4 的稠密 scratch
for (auto &a : desired) if (is_cell_domain(a)) mask_by_cell[cell(a)] |= a.metric_mask & CELL_METRICS;
// 2) 每格只采样并集内的列
_economy_runtime->sample_effect_metrics(cell, M, values, mask_by_cell[cell]);
// 3) 国家级 metric（56..67，以及 47..49 等国家标量）每个国家每个 epoch 只取一次
const CountryMetricRow &row = country_metric_row(country.handle, epoch); // 缓存，按修订号失效
```

- `CELL_METRICS` 和 `COUNTRY_METRICS` 两个掩码由生成器或一张 C++ 常量表声明，并在 Economy 里用 `static_assert` 和 metric 枚举对齐。
- 只要没有卡声明 X7 metric，就不会触发全图 tag 位图重建。

### O4：按天共享的每格 metric 缓存（对应 H4）

- 把 `sampled_by_cell` 从局部变量提升为成员变量 `_metric_cache`，用 `effect_input_revision` 做 key。修订号变了就整体清空。
- 数据结构用稠密数组：`cell -> slot` 的 `std::vector<int32_t>`（长度 N，初始化为 -1），再加一个 `values` 池。清空时只重置用过的 slot。不要用 `unordered_map`。
- 掩码采用「已采样列」位图，需要哪列就补采哪列。这样多张卡可以共享缓存，又不必用 `all_declared`。

### O5：用稠密 program id 替代字符串（对应 H5）

- 配置目录时，把 `templ.definition_key` 解析成 `program_dense_id`，并把 Effect 侧的 metadata 指针或索引一起缓存到 Ideology 的模板里。
- `effect_program_key()` 只在配置阶段调用；reconcile、emit、collect 一律使用 dense id。
- Effect 侧提供 `family_effect_metadata_by_dense(int32_t)`。
- 目录重新配置时，连同这些缓存一起重建。

### O6：用排序归并或哈希做 held/desired 对比（对应 H6）

```cpp
// 两个序列都按 instance_id 排序（desired 按解析顺序生成后 sort 一次，held 保持有序存放）
auto h = held.begin(); auto d = desired.begin();
while (h != held.end() || d != desired.end()) {
    if (d == desired.end() || (h != held.end() && h->instance_id < d->ref.instance_id)) retire(*h++);
    else if (h == held.end() || d->ref.instance_id < h->instance_id) add(*d++);
    else { if (h->generation != d->ref.generation || h->scale != d->scale) add(*d); ++h; ++d; }
}
```

- 复杂度从 O(K²) 降到 O(K log K)。
- 注意：要保持「先退役、后提交」的顺序（约 1566 行的注释要求这一点）。具体做法是先把 retire 和 add 分别收集起来，然后按顺序执行。

### O7：可复用的 scratch，去掉 Variant（对应 H7）

- Ideology 持有 `struct ReconcileScratch { std::vector<EffectActivation> desired; std::vector<int64_t> ids, handles; std::vector<int32_t> scales; ... }`，每次 `clear()` 后复用容量。
- 对 `EffectRuntime` 和 forwarder 增加一个 POD 接口 `submit_instances_pod(const SubmitBatchView &)`，只接受 span/指针加长度。Dictionary 版本只留给 GDScript 调试入口。
- `runtime_worker_source_scan_test` 会检查 worker 代码里不能出现 Godot 类型。新接口正好满足这个要求。

### O8：倍率查表（对应 H8）

- 目录编译时生成 `program_dense_id -> [synergy_id, scale_q16]` 的 CSR。
- `magnitude_scale_for(country, program)` 只遍历这个 program 自己的那一小段，用 `active_synergy_bits` 测位。复杂度从 O(S) 降到 O(影响该 program 的协同数)，通常 ≤ 3。
- 这张 CSR 和 Doc 01 P1-D 的反向索引是同一张表的两个方向，一起生成。

### O9：按 tag 的格列表（对应 H9）

- 在 COMMIT 构建不可变快照时，顺带生成 `tag -> 格列表` 的 CSR。只为目录里被 `TAG_ANY_CELL` 引用的 tag 生成。
- 选择器从 O(N) 变成 O(命中数)。再配合 P2-B 的稳定哈希截断，用 `nth_element`。

### O10：不可变的 tag 快照，增量构建（对应 H10，同时解决 P3-B）

- 在 Economy worker 的 COMMIT 末尾构建。
- 按 tag 的输入依赖做增量：只有「输入 metric 在本期变化过的格」才重新求值谓词。Economy 本来就知道哪些格的人口、产出、建筑有变化，可以打一个 dirty cell 位图。
- 发布方式是 `std::atomic<std::shared_ptr<const EffectInputSnapshot>>`（C++20），或者一把 mutex 守护的 shared_ptr 交换。读者全程无锁。
- 快照内容：

```cpp
struct EffectInputSnapshot {
    uint64_t revision;                       // = effect_input_revision
    int32_t  cell_count, tag_words;          // tag_words = ceil(T / 64)
    std::vector<uint64_t> tag_bits;          // cell-major: [cell * tag_words + w]
    std::vector<uint64_t> tag_bits_by_tag;   // tag-major: [tag * cell_words + w]，供位图运算
    std::vector<int32_t>  tag_cells_offsets, tag_cells;   // O9 的 CSR
    std::vector<int32_t>  country_tag_counts;              // [country * T + tag]
    // 派生列（Doc 02 §3.2）：SoA，每列一个连续数组
    std::vector<DerivedColumn> columns;
};
```

- 两种布局都保留。tag-major 用于整图位运算（AND/OR、popcount）和系数平面。内存估算：N = 8192、T = 64 时每种布局约 64 KB，可以接受。

---

## 4. 目标架构：位图 + 派生列 + 系数平面

### 4.1 思路

每格卡的本质就是一个函数：`对本国每个格 c：stat[c] += coef × f(列[c]) × [过滤位图[c]]`。它不需要生命周期、事务、ACK。Effect 的重机制只留给国家级效果，以及确实需要状态的效果（计时、锁存、少量 X4）。

### 4.2 数据布局

```cpp
// Ideology 发布（只在结构变化时：过渡 ACK、协同翻转、X7/X10/X14 标量变化、X4 层数变化）
struct CellProgramTable {                 // 不可变，带 generation
    uint64_t generation;
    // 稀疏：只列出有活动 program 的国家
    std::vector<int32_t> country_offsets;   // CSR over country slot
    struct Entry {
        int32_t program_dense_id;
        int32_t stat_slot;                   // 目标每格 stat 的索引
        int32_t filter_tag;                  // -1 = 无过滤（全领土）
        int32_t filter_tag2;                 // X5 附加条件，-1 = 无
        int32_t column;                      // -1 = 常数 1；否则派生列索引
        int32_t cap_units;                   // min(column, cap)
        int32_t coef_q16;                    // 已乘上等级、X5 倍率、c 类标量
        uint8_t op;                          // ADD / MUL
    };
    std::vector<Entry> entries;
};
```

### 4.3 读取路径（Economy）

- 照搜 `_city_output_*`（`economy_runtime.cpp` 约 6555~6625 行）的做法：每种每格 stat 各有一个缓存列 `ideology_cell_stat[stat_slot][cell]`。
- 缓存的版本键为 `(CellProgramTable.generation, EffectInputSnapshot.revision)`，两者任一变化就重建。
- 重建算法，按国家和 entry 遍历，只访问本国领土格：

```cpp
for country with entries:
  for cell in territory_csr[country]:               // 领土 CSR 已存在（L1-4a）
    for e in entries[country]:
      if (e.filter_tag >= 0 && !bit(snapshot, cell, e.filter_tag)) continue;
      if (e.filter_tag2 >= 0 && !bit(snapshot, cell, e.filter_tag2)) continue;
      int32_t units = e.column < 0 ? 1 : std::min<int32_t>(col(e.column)[cell], e.cap_units);
      acc[e.stat_slot][cell] += units * e.coef_q16;   // MUL 分量放在另一个累加器
```

- 复杂度：O(Σ_country |领土| × |entries|)。一般不超过 N × 12，N = 8192 时约 10 万次简单运算，属于微秒级。而且**只在版本变化时发生**。
- 如果当天只有少数格的 tag 或列变化，可以进一步做增量：只重算 dirty 格。前提是快照里带上 dirty cell 位图。
- 这一步在 Economy worker 上执行，不占主线程。
- 结果接入现有的 stat 读取，组合顺序是 `(base + modifier_add + ideology_add) × modifier_mul × ideology_mul`，最后做 soft cap clamp（P2-D）。组合顺序要写进 skill。

### 4.4 发布路径（Ideology）

- 触发点：过渡 ACK 成功、协同翻转、c 类标量变化、X4 层数变化。这些都是稀疏事件。
- 只重建受影响国家的 entries 段，然后整表换成新的不可变版本，generation +1。如果表很大，可以按国家分块做 copy-on-write。
- worker 权威下，由理念 worker 生成这张表，通过跨线程队列交给 Economy worker。主线程完全不参与。如果理念 worker 和 Economy worker 是同一个调度图里的两个阶段，就放在图里作为显式依赖，参考 `project-keynes-dots-deepening`。

### 4.5 存档

- `CellProgramTable` 和缓存列都是派生量，不存。
- 读档时由 PKID（卡、等级、协同、X4 层环）和 Economy 状态重建，是确定的。
- 每格卡迁移到平面后，Effect 存档里不再有这些实例。PKEF 布局不变，只是内容变少。但目录 hash 会变，旧存档按规则 fail-closed。

### 4.6 显示链路（L6）

- 「命中哪些格」不再从实例列表读取，改为按需计算：给定 `(country, program)`，用领土 CSR 和过滤位图当场算出格列表和每格数值。
- 只有 UI 打开时才调用，不占仿真预算。
- 设计文档 §31/§32 的接口保留签名，内部实现换掉。

### 4.7 迁移步骤（可以分提交）

1. 实现 O10 的不可变快照和 P1-A 的修订号。这是前提。
2. 实现 `CellProgramTable` + Economy 读取，先只支持「常数 + 过滤 tag」。加一个开关 `ideology_cell_plane_enabled`，默认关闭。
3. **双跑对照测试**：同一个世界先走实例路径、再走平面路径，逐格比较 stat。对已上线的卡要求完全一致。例外是超过 32 格的情况，平面路径会覆盖更多格，测试里单独处理。
4. 生成器把所有无状态的每格 program 标记为 `plane = true`。Ideology 对这类 program 不再创建 Effect 实例。
5. 开关默认打开，删除每格实例路径里不再需要的代码：metric 发布和选择器截断。有状态的少数效果继续走 Effect。
6. 再加派生列（Doc 02 §4）和 X5 覆盖。

---

## 5. 线程模型与确定性

| 数据 | 写者 | 读者 | 同步方式 |
|---|---|---|---|
| `EffectInputSnapshot` | Economy worker（COMMIT） | Ideology（任意线程）、Economy 读取 | 不可变 + 原子 shared_ptr |
| `CellProgramTable` | Ideology（权威侧） | Economy worker | 不可变 + 原子 shared_ptr，或者调度图依赖 |
| 每格 stat 缓存 | Economy worker | Economy | 只在 worker 内部使用 |
| Effect 实例（国家级） | 现状不变 | — | 现有 forwarder |

**确定性规则：**

- 系数表对 Economy 的生效时刻必须是确定的。推荐：第 D 天发布的表，在第 D+1 天的 COMMIT 读取时生效。不要用「恰好在哪个 tick 到达」来决定。
- 实现方式：Economy 读取时只接受 `table.effective_day <= current_day` 的最新表。
- 所有累加都用定点整数（Q16），按固定顺序进行：国家 slot 升序 → entry 顺序 → 领土 CSR 顺序。禁止用浮点累加。

---

## 6. 基准测试与门槛

### 6.1 场景（固定 seed，使用同一个 template_debug DLL）

| 场景 | 规模 | 模式 |
|---|---|---|
| B1 | 64 国 × 12 张在场卡，其中 6 张每格卡，每张命中上限 | 主线程权威 |
| B2 | 同 B1 | worker 权威 |
| B3 | 512 国续跑 | worker 权威 |
| B4 | B1 + 每天对 1% 的格做 tag 翻转（人口扰动） | 两种模式 |
| B5 | B1 + 空闲 30 天（不改任何输入） | 两种模式 |
| B6 | 6400 格 class-opinion | — |

把 B1~B5 的场景生成加进现有 stress 测试：当前的 stress 测试没有每格 program，必须补。

### 6.2 门槛（来自 skill）

- 64 国每日 p95 ≤ 0.35 ms。
- 512 国续跑 p95 ≤ 0.42 ms。
- 单次 native 调用 ≤ 1 ms，包括 `apply_pod_snapshot`。
- 6400 格 class-opinion 中位数 < 1 ms。
- **空闲计数器必须为 0**（B5）：
  - 现有：`sparse_idea_scan_count`、`dormant_scan_count`、`command_queue_resorts`、`command_queue_shift_steps`。
  - 新增：`instance_refresh_visits`、`instance_submit_batches`、`metric_publish_count`、`effect_transactions_created`、`cell_plane_rebuilds`。
- B4 的额外门槛：每日工作量和翻转格数呈线性关系，不允许和 N 成线性。验证方法：翻转率取 0.1%/1%/10%，画出曲线。

### 6.3 工具

- `economy/hardware_bench`、`runtime_*_soak`。
- `project-keynes-headless-perf` skill 里的生产路径记录方式。
- 每次记录都要带上 commit、DLL 时间戳、seed、场景编号、p50/p95/p99、计数器快照。结果追加到设计文档 §38 的表格里。
- 做性能对比时不要同时跑其他 Godot 进程。

### 6.4 执行顺序

1. 先在修复前跑 B1~B6，建立基线。如果 B1 因为 4096 上限而失败，把失败本身记录下来，它就是容量问题的证据。
2. O1 + O2 完成后，B5 的计数器应该全部为 0。
3. O3~O10 逐项完成，B1/B2 的 p95 应该单调下降。哪一项做完没有收益，就记录下来并说明原因，不要硬留。
4. 系数平面上线后，重跑全部场景，并把 B1 的规模提高到设计文档的目标规模：每国 12 张卡全部是每格卡，且不设 32 上限。

---

## 7. 一页纸清单

- [ ] 建立基准 B1~B6 和基线（要先做）
- [ ] O1 修订号/签名门控 + 切片刷新
- [ ] O2 值变化才推进 revision
- [ ] O3 按需 mask，国家级 metric 和格级分开
- [ ] O4 按天共享的稠密 metric 缓存
- [ ] O5 稠密 program id
- [ ] O6 排序归并对比
- [ ] O7 可复用 scratch + POD 提交接口
- [ ] O8 协同倍率 CSR
- [ ] O9 按 tag 的格 CSR
- [ ] O10 不可变、增量构建的 tag 快照（同时关闭 P3-B）
- [ ] §4 系数平面：开关 → 双跑对照 → 默认开启 → 清理旧代码
- [ ] 每一步的基准结果都写入设计文档 §38
