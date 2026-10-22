# 指标量纲表与 digest 门控的正确形状

针对 06 §3「P1-A digest 粒度过粗」。

## 1. 量纲普查（31 个指标，枚举值 37–67）

| 值 | 指标 | 量纲 | 变化形态 |
|---|---|---|---|
| 37–41 | `CELL_SECTOR_OUTPUT_SHARE_{AGRICULTURE,EXTRACTIVE,MANUFACTURING,ENERGY,KNOWLEDGE}_Q16` | Q16 份额 0..65536 | 连续 |
| 42 | `CELL_DOMINANT_SECTOR_OUTPUT_SHARE_Q16` | Q16 份额 | 连续 |
| 43 | `CELL_DOMINANT_RESOURCE_ID` | **类别 id** | 离散跳变 |
| 44 | `CELL_DOMINANT_RESOURCE_STOCK_SHARE_Q16` | Q16 份额 | 连续 |
| 45 | `CELL_DOMINANT_OUTPUT_GOOD_ID` | **类别 id** | 离散跳变 |
| 46 | `CELL_TOP_OUTPUT_GOOD_SHARE_Q16` | Q16 份额 | 连续 |
| 47 | `COUNTRY_POPULATION_Q16` | 人口（×65536） | 连续，量级跨两个数量级 |
| 48 | `COUNTRY_BUILDINGS_INSTALLED` | 计数 | 离散 |
| 49 | `COUNTRY_TRADE_BASE_VALUE_Q16` | 货币（×65536） | 连续，量级极大 |
| 50 | `CELL_TERRAIN` | **类别 id** | 离散跳变 |
| 51 | `CELL_DOMINANT_PROFESSION_ID` | **类别 id** | 离散跳变 |
| 52 | `CELL_DOMINANT_PROFESSION_SHARE_Q16` | Q16 份额 | 连续 |
| 53 | `CELL_PROFESSION_COUNT` | 计数 | 离散 |
| 54 | `CELL_NEIGHBOR_POPULATION_Q16` | 人口 | 连续 |
| 55 | `COUNTRY_INCOME_TAX_BURDEN_BP` | 基点上界（0..10000） | 连续，窄域 |
| 56–66 | `COUNTRY_*_CELL_COUNT`（11 个） | 格数 | 离散 |
| 67 | `COUNTRY_DISTINCT_SPECIALIZED_GOOD_COUNT` | 计数 | 离散 |

## 2. 结论：**固定步长对一半的指标是错的**

我在 `economy_runtime.cpp` 里先加的是「每指标一个绝对步长 `quantum`」，混入 `value / quantum`。
对着这张表看，它对一半指标不成立：

- **类别 id（43/45/50/51）**：只能精确。任何步长都会把「草原」和「平原」混进同一个桶。
- **计数（48/53/56–67）**：一格的差异就可能翻转「≥ N」，只能精确。
- **人口（47/54）**：绝对步长没法选。同一张卡在 500 人的村落和 50 万人的帝国上，
  1% 对应的绝对数差三个数量级——写死任何一个数，要么在村落里粗到吞掉真实变化，
  要么在帝国里细到等于没做。

固定步长只在**窄域连续量**上成立：份额（0..65536）和基点（0..10000）。
这两类占 31 个里的 12 个。

## 3. 正确的形状：按**卡的阈值**分桶，不按指标分桶

06 §3 原话是「指标变化按阈值分桶判定」。阈值不在指标上，在**卡的条件里**——
`EffectCondition.arg0`（指标）+ `value_q16`（阈值）。

所以该混进 digest 的不是「值/步长」，而是：

```
bucket(value) = 满足 thresholds[m] ≤ value 的阈值个数
```

即**「这张卡的条件有没有可能因此翻转」**。它天然满足：

- 类别 id：阈值集合为空 → bucket 恒为 0 → 等价于精确比较（id 变了值也变了，
  但 id 指标本来就走不到这里，见下）；
- 计数：阈值就是内容写的 N，跨过 N 才变 bucket；
- 人口：阈值随内容走，村落和帝国自动适配，不需要选数。

## 4. 需要补的东西（按依赖顺序）

1. **阈值集合的来源**：`EffectCondition` 在 domain catalog 编译期已展开，
   但 Economy 的 `set_effect_input_consumers(mask, tags)` 只传了掩码，没传阈值。
   需要在同一处把「每指标的阈值数组（排序去重）」一起传下来。
2. **ideology 侧的阈值**：卡片条件同样是 `metric + value_q16`，编译期汇总一次即可。
3. **`bucket()` 用二分**，阈值数量是个位数到几十，`upper_bound` 足够。
4. **类别 id 指标**：不参与 bucket（阈值集合为空即自然正确），但要确认没有卡
   拿它做大小比较——若有，那本身就是内容错误。

## 4b. 更正：**不需要升 ABI**（作者原判断有误）

前文曾判断「给 `FamilyEffectMetadataPod` 加字段等于升 ABI」。**这是错的**：

- 该结构里有 `std::string target_selector_id`，本来就不是 memcpy-friendly；
- 它的注释写明「Computed ... on every request」；
- 全仓 `runtime_effect_pod.cpp` / `effect_instance_forwarder.cpp` **没有任何序列化点**。

即它只是一个**每次请求重算的查询结果**，名字里的 "Pod" 是历史用词。
加字段零 ABI 成本。因此 §4 的四步已经按这个前提实现（见 §6）。

## 4c. 为什么先前的判断会停在这里

阈值目前只存在于程序条件里，而 `rebuild_level_managed_if_needed()` 拿到的
`EffectRuntime::FamilyEffectMetadataPod` **只带 `metric_mask`，不带阈值**
（`ideology_runtime.cpp:1944`）。

要把阈值带下来只有两条路：

1. 给 `FamilyEffectMetadataPod` 加字段 —— 它是 POD，跨存档 / 跨 worker，
   加字段等于**升 ABI 版本**，是一扇单向门（旧档按 PKEF 规则 fail-closed）。
2. 在 catalog 配置期另建一张「指标 → 阈值数组」的表，不碰 POD。

两条都不是「顺手加一下」。第 2 条明显更安全，但它需要效果目录在编译期把
条件展开成阈值表并能被 Economy 读到——那是 06 §6 第 3 步之外的一小段独立工作，
应该单独做、单独验。

> **已过时（同日后续）：** 上面的 ABI 顾虑是错的（见 §4b），阈值分桶已经实现（见 §6），
> 固定步长那条路已被取代并删除代码。本节保留作为当时的判断记录。

## 6f. 第一组实测数字（64 / 512 / 2048 格）

`_test_digest_cost`：每次 commit 一次 digest，掩码内 1 个指标，50 趟取平均。

| 格数 | wall / 趟 | 内部计数器 / 趟 |
|---|---|---|
| 64 | 0.0069 ms | 0.0061 ms |
| 512 | 0.0446 ms | 0.0439 ms |
| 2048 | 0.1554 ms | 0.1547 ms |

**线性，约 76 ns/格/指标**（0.1554 / 2048）。wall 与内部计数器一致，说明计数器可信。

### 这个数字意味着什么

按 76 ns/格/指标推到满规模（4096 格 × 7 个被读指标）：

```
0.1554 ms × 2 × 7 ≈ 2.2 ms / 次 commit
```

而 06 §2 给单日预算的量级是 **0.35 ms**。也就是说：

- 今天的 digest **在满规模下会超出日预算约 6 倍**；
- 阈值分桶减少了「revision 变化的次数」，但**每次 commit 仍然要全量采样**，
  这一项开销与分桶无关。

结论：06 §3 第 4 条（按国家记录变化格子列表）和 2.7 的「预编译 + 按国家增量」
不是优化项，**是让 digest 能进预算的必要条件**。

## 6. 已实现（阈值分桶，无 ABI 变更）

1. `FamilyEffectMetadataPod` 增加 `metric_threshold_ids[8]` / `metric_threshold_values[8]` /
   `metric_threshold_count`，在 `family_effect_metadata_pod()` 里从
   `Condition{op∈METRIC_*, arg0, value}` 收集。超过 8 条只影响该 metric 的完整性，
   不会错——它退化为精确比较。
2. `LevelManagedInfo` 同样带一份（运行时缓存，不序列化），`rebuild_level_managed_if_needed()`
   从 metadata 拷过来。
3. `publish_effect_input_consumers()` 把所有层级的阈值合并成
   **每指标一个排序去重的 `vector<int64_t>`**，随 `set_effect_input_consumers(mask, tags, thresholds)`
   一起交给 Economy。
4. `refresh_effect_input_digest()`：阈值集合非空时，混入
   `upper_bound(thresholds, value) - begin`（跨过了几个阈值）；为空时仍混原值。

**语义**：digest 变化 ⟺ 某张卡的条件**可能**翻转。不依赖量纲、不需要选步长，
类别 id / 计数 / 人口一视同仁。

**回归**：`tests/ideology/` 20 个文件全绿（metric 182/0、stress 81/0 …），
`family_buff_runtime_test` **4**（= 基线，无新增）。

### 6b. 第二半：每卡签名只混入它读的指标

- Economy 侧新增 `_effect_metric_revision[68]` / `_effect_metric_published[68]`：
  digest 循环里先按指标各自累积一个 digest，再折进全局的（全局语义不变，
  既有 refresh / should_run 门控照旧），并对每个真正变化的指标 `++revision`。
- `compute_activation_signature()`：有 `consumer_mask` 的卡混
  `max(revision[m] for m in mask)`；没有掩码的卡仍混全局 revision —
  **改动只会收窄，不会让原本会刷新的卡停止刷新**。

效果：一个指标变化，只有读它的卡重新签名，其余 `uses_economy_inputs` 的卡不动。

### 6c. 三路 revision 已完成

`refresh_effect_input_digest()` 现在分别累积 `territory_digest` 与 `tag_digest`，
各自与上次发布值比较后 `++revision`；全局 revision 仍是三者与各指标的并集。
`compute_activation_signature()` 按卡实际读取的输入混合：

| 卡读了什么 | 混入什么 |
|---|---|
| `consumer_mask` 非空 | `max(revision[m]) for m in mask` |
| `uses_tags` | tag revision |
| `uses_economy_inputs` | territory revision |

导出 `get_effect_input_revisions()`（global / territory / tag / 68 个指标）与
`refresh_effect_input_digest_for_test()`。

### 6e. 阈值门控测试（§3 的核心证据）

新增测试钩子 `set_effect_metric_override_for_test(metric, value, has_value)`：
把某个指标在所有格上强制为指定值。**没有它就无法确定性地测阈值边界**——
模拟推不动那么精确。

`_test_threshold_gate`：卡的条件是「人口 ≥ 1000」。

| 注入值 | 期望 | 实测 |
|---|---|---|
| 100 | 建立基线 | revision = r |
| 900 | 同桶（<1000）→ 不变 | r ✅ |
| 1000 | 跨阈值 → 恰好 +1 | r+1 ✅ |
| 5000 | 更远，仍同一桶 → 不变 | r+1 ✅ |

这条是 §3 的判定性证据：**桶内漂移不换 revision，跨阈值才换**。

### 6d. 测试：已有 5 条，缺 2 条

`ideology_effect_metric_publish_test::_test_input_revision_split`（198/0）：

1. 刷新钩子跑通；
2. digest 确实计算过至少一次（`effect_input_digest_computations >= 1`）；
3. 报告含 68 个指标槽；
4. **卡读的指标（9 = 人口）涨了，没人读的（55 = 税负）仍是 0** —— 这条是拆分是否真在起作用的正证据；
5. **二次刷新输入不变 → 一个 revision 都不涨**（幂等）。

**仍缺一条**（不属于 §3 的判定条件）：
- 空闲窗口 `instance_refresh_visits` / `cell_plane_rebuilds` 为 0 —— 这是 06 §2.1 给**平面**定的
  门槛（需要 `city_output_plane_merges` 计数器），不是 §3 digest 的门控条件。

> **已过时：** 该缺口已由 §6e 的阈值门控测试补上（100/900 同桶不变、1000 跨桶 +1）。
构造它需要能精确制造两次 commit 的小幅人口变化，现有夹具做不到——与 §3 原报告的缺口相同。

## 5. 当前代码状态

> **已过时：** 固定步长机制已在第二轮 review 后**整段删除**（它是被阈值分桶取代的死代码）。
> 现行实现见 §6。
