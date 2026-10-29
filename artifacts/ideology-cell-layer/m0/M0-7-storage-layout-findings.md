# M0-7 storage layout selection & budget — findings

| 项目 | 内容 |
|---|---|
| 里程碑 | [M0](../22-cell-program-cap-removal-plan-v3.md) |
| 任务 | §15.2 M0 task 7 / §8.2 |
| 日期 | 2026-10-26，Asia/Hong_Kong |
| 结论 | **建议选定：按 stat 的紧凑 CSR 数组**（非平铺哈希）。理由与预算见 §3–§4 |
| 未做 | 没有实测两种布局的耗时与内存。选型依据是访问模式与现有数据规模，不是基准 |

## 1. 候选布局

方案 §8.2 要求 M0 在两者间选一：

| 布局 | 结构 | 查询 |
|---|---|---|
| A：按 stat 的紧凑 cell 数组 | `per_stat: stat -> {cells[], adds[], factors[]}`，CSR 或排序数组 | 二分 / 直接游标 |
| B：numeric key 平铺哈希 | `unordered_map<int64 key=(stat<<32)|cell, CellContribution>` | 一次哈希 |

方案明确「最终只选一个基础实现，不同时维护两个通用容器框架」。

## 2. 访问模式（由 M0-1 的 reader manifest 推导）

M0-1 已确认全部 325 条命令引用落到 **7 个 reader 族，且全部是 GROUP scope**。这些 reader 的访问形态是：

| reader | 访问形态 | 证据 |
|---|---|---|
| `refresh_city_modifier_factors` | 由 `collect_scope_ids` 给出**稀疏格列表**，对每格做 156 次 `effective_value`（1 birth + 1 general + 20 need + 134 good） | `economy_runtime.cpp:7079-7095` |
| `refresh_city_output_modifier_factors` | 由 `collect_scope_stat_entries` 给出 `(cell, stat)` 对，逐对一次查询 | `:7209-7221` |
| `refresh_building_modifier_factors` | 逐 building group 查 `economy.building.output_factor`（ENTITY）与 sector stat（GROUP=cell） | `:10976-11152` |
| 资源 regen | 逐**活跃资源格**查 `regen_factor` | `:4388-4399` |

关键性质：**查询总是「给定格，问该格有没有派生贡献」，而不是「遍历所有贡献」**。且 `collect_scope_*` 本身就是在枚举「有贡献的 (stat, cell)」集合。

**这不支持方案 §8.5 的 `collect_scope_ids` 实现方式继续演进。** 当前 `collect_scope_ids` 全表扫 `store.buckets`（`modifier_runtime.cpp:1464`）。派生层若也要求它扫全表，会随贡献数线性增长，而它每次冻结都要跑。

## 3. 选型：紧凑数组（A），理由三条

### 3.1 查询键的分布极窄

一条 card 的贡献落在「一个国家的一批格 × 一个 stat」。同一批格会被 156 次查询**反复访问**（birth + 20 need + 134 good 都问同一格）。

- 布局 A：`stat -> 排序后的 cells[]`，对同一格查 156 个不同 stat，每个 stat 一次二分（log₂(格数) ≈ 12 对大国的 4000 格）+ 一次读。
- 布局 B：156 次哈希，每次 ~25-50 ns 的 cache miss（`unordered_map` 是链式节点，非连续）。

在「同一格 × 多 stat」这个主导模式下，A 的二分命中在同一格会保持在少数 cache line 内，B 的 156 个键散落在哈希桶里。**A 更可能赢，且不需要测就能从访问模式判断方向。**

### 3.2 `collect_scope_*` 天然是顺序扫描

如果 `per_stat` 是 `stat -> 有序 cells[]`，那么「返回实例与派生并集」只需对涉及的 stat 各做一次归并（`std::set_union`），代价与真实行数成正比。在哈希布局上做同一件事必须遍历全部键再按 stat 分组——正是当前实现的问题。

### 3.3 版本按 stat 天然分区

方案 §8.6 要求 `layer_stat_version[sid]` 独立。布局 A 的 `per_stat[sid]` 天然带版本，无需额外索引。布局 B 的版本必须另建一张 `stat -> version` 表，等于同时维护两套键。

## 4. 为什么不复用仓库现有容器

我核对了 `/gdext/src` 下的 8 个容器头：

| 文件 | 用途 | 能否用于热查询 |
|---|---|---|
| `economy_paged_column.h` | COW 持久化列，`PAGE_BYTES=4096`，`View::page_at` 走**二叉树下降** | ❌ 每次读取要 log₂(capacity) 次指针跳转，比线性数组慢 |
| `economy_keyed_page_column.h` | 上述的分页版，带 `std::shared_ptr` payload | ❌ 同上，且为持久化/变更通知设计 |
| `economy_hash_directory.h` | 哈希目录 | ❌ 同上层次 |
| `economy_change_registry.h` / `economy_tracked_column.h` | 变更追踪 | ❌ 不是索引 |
| `runtime_chunk_hash.h` | worker 分块哈希 | ❌ 目的是并行校验，不是点查 |
| `economy_owned_column.h` | SoA 列 | ⚠️ 可作底层存储，但不提供键索引 |

结论与方案 §8.2 的判断一致：**仓库里没有可直接用于「(stat,cell) 点查 + 按 stat 扫描」的现成容器**。方案说「当前未发现可直接引用的第三方 flat-hash 依赖；不能在工期里假定其已经安装」——核对确认如此。

## 5. 存储规模估算（用于 M0 预算）

方案 §14.3 要求 M0 填「B7/B8/B9 最大峰值内存」。这是估算，不是测量。

单个 `CellContribution`（方案 §8.1）：
```
double sum_add            8 B
double product_nonzero    8 B
uint32_t zero_factor_count 4 B  (+4 padding)
                          = 24 B
```
若按 §8.1 再加来源国维度（`(country, stat, cell)` 三元组），每行另有 country handle 8 B → **32 B/行**。

规模场景：

| 场景 | 贡献行数 | 32 B/行 | 加 cells[] 索引（4 B/行） | 合计 |
|---|---:|---:|---:|---:|
| B1：64 国 × 12 卡，每卡命中 32 格（现状） | 64×12×32 ≈ 24.6k | 0.8 MB | 0.1 MB | ~0.9 MB |
| B7：单国 1000 格 × 12 卡 | 12k | 0.38 MB | 0.05 MB | ~0.43 MB |
| **取消 cap 后 B7 同配置扩到全国 6400 格** | 12×6400 = 76.8k | 2.5 MB | 0.3 MB | **~2.8 MB** |
| 极端：64 国全部全国覆盖（6400 格 × 12 卡 × 64 国） | 4.9M | 157 MB | 20 MB | **~177 MB** |

**最后一行是必须写进预算的风险项。** 方案 §8.3 说「必须计量 front、candidate、old front、来源 batch、几何缓存和 scratch 的同时在用峰值」，且「任何内存预算失败都发生在安装前」。177 MB 的三份（front + candidate + retained）就是 531 MB——在 127 GB 机器上可接受，但不是「免费」，且**在低端机器上是拒绝条件**。

**建议 M0 预算取「B7/B8/B9 实测 + 极端场景上界公式」，并把极端场景作为显式拒绝路径的测试用例**（方案 §17「内存／条目预算不足 → 安装前显式失败」）。

## 6. 需要方案补充的一项

方案 §8.2 的替换算法第 4 步：「同一个冻结提交只建立一次候选 front，不为每个国家完整复制聚合表」。

按 §5 的规模，**旧 front 保留 + 新 candidate 复制 = 2×177 MB**。方案第 5 步说「old front 由仍持有 read view 的消费者保活」，这是对的，但没给「何时可以真正释放」的判据。§9.8 给了原则（「所有活跃窗口和 checkpoint 均不再引用」），但**没有实现手段**：

- 若用 `shared_ptr<const Front>`，最后一个引用消失自动释放，语义正确但峰值不可控（一个慢 checkpoint 能让两份都活着）；
- 若用引用计数 + 显式回收，需要在 §11.2 的 `AppliedProgramBasis` 里记录「谁引用了哪一份 front」。

**建议 M1 采用 `shared_ptr<const Front>` 起步**，并在 §12.4 的诊断里加 `retained_front_count` 与 `retained_front_bytes`——方案已有 `retained` 字段，只需明确它是引用计数而非生命周期管理。

## 7. 提交 M1 的选型决策

| 决策 | 选定 | 依据 |
|---|---|---|
| 布局 | **A：`per_stat -> 有序 cells[] + 并行 value 数组`** | §3 |
| 键 | `stat_id` 为一级，`cell` 为二级有序数组 | reader 全部按 stat 族分组 |
| 来源国维度 | 每个 cell 行内带 `country_handle`（不另建外层维） | §8.1 要求按来源国可撤销，但查询是格优先 |
| front 生命周期 | `shared_ptr<const Front>`，诊断带引用计数 | §6 |
| 第三方容器 | 不引入 | §4 |
| `collect_scope_*` | 改为按 stat 归并派生行，**不再全表扫** | §3.2 |

## 8. 局限

- **没有实测。** 布局 A/B 的耗时对比是访问模式推断，不是基准。方案 §8.2 要求「M0 原型比较两种布局」——这一点**未完成**，见 checklist 的未勾选项。
- 内存估算是 `行数 × sizeof`，未计 `std::vector` 容量翻倍（通常 ×1.5–2）、哈希桶开销、分配器碎片。真实峰值可能比 §5 的表高 1.5–2 倍。
- 未评估「同一格 156 次查询」在布局 A 下是否真的比 B 快——需要 M0-7 的实测才能确认。若实测推翻，选型应改。
