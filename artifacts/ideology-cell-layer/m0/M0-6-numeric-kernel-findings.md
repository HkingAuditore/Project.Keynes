# M0-6 numeric kernel & merge order — findings

| 项目 | 内容 |
|---|---|
| 里程碑 | [M0](../22-cell-program-cap-removal-plan-v3.md) |
| 任务 | §15.2 M0 task 6 / §5 |
| 日期 | 2026-10-26，Asia/Hong_Kong |
| 方法 | `gdext/src` 静态阅读 + 一个可执行数值样例 |
| 结论 | §5 的公式与 §6.6 的精确失效前提**在源码层面成立**；但发现一节方案未覆盖的**归并顺序风险** |

## 1. 统一公式已验证

`ModifierRuntime::effective_value`（`modifier_runtime.cpp:1405-1429`）：

```cpp
double add = 0.0;
double factor = 1.0;
const BucketKey keys[3] = {{sid, GLOBAL, 0}, {sid, GROUP, group_handle},
                           {sid, ENTITY, entity_handle}};
for (int i = 0; i < 3; ++i) {
    if (i == 1 && group_handle == 0 && domain != ECONOMY) continue;
    const auto it = store.buckets.find(keys[i]);
    if (it == store.buckets.end()) continue;
    add += it->second.sum_add;
    factor *= bucket_factor(it->second);
}
double value = (base_value + add) * factor;
if (!std::isfinite(value)) value = value < 0.0 ? min : max;
return std::clamp(value, min, max);
```

与方案 §5.1 逐项对应：

| §5.1 | 实现 |
|---|---|
| `add_total = add_global + add_group + add_entity + add_derived` | `add += sum_add` 三次 |
| `factor_total = factor_global × factor_group × factor_entity × factor_derived` | `factor *= bucket_factor(...)` 三次 |
| `effective = clamp((base + add_total) × factor_total, min, max)` | `clamp((base_value + add) * factor, min, max)` |
| 禁止二次包装 | 确认：clamp 在乘法之后只做一次 |

**§5.1 举的反例成立**：`base=1, factor=2, new ADD=0.1` → `(1+0.1)*2 = 2.2`。若在最终值上加 0.1 得 2.1，错。派生项必须是第 4 个 add/factor，不能碰最终值。

一个方案未提及的细节：**`i == 1 && group_handle == 0 && domain != ECONOMY` 时跳过 GROUP 桶**（`1419`）。即 ECONOMY 域的 `group_handle == 0` 是**合法的格 0**，而其他域视作「无 group」。方案 §8.5「保留 group=0 作为合法 cell 0 的既有语义」说的就是这个分支，实现正确。

## 2. term 折叠公式已验证

`modifier_runtime.cpp:768-784`：

```cpp
double scaled_add(term, stacks, magnitude_q16) {
    magnitude = magnitude_q16 / 65536.0;
    return term.add * stacks * magnitude;
}
double scaled_factor(term, stacks, magnitude_q16) {
    magnitude = magnitude_q16 / 65536.0;
    interpolated = 1.0 + (term.factor - 1.0) * magnitude;
    return std::pow(interpolated, stacks);
}
double bucket_factor(bucket) {
    return bucket.zero_factor_count > 0 ? 0.0 : bucket.product_nonzero;
}
```

与方案 §5.4 逐项对应，包括零因子的独立计数语义。

**方案 §5.4 的「固定单层可省去 pow」需要修正措辞**：`std::pow(x, 1.0)` 与 `x` 在 IEEE754 下对有限正常值等价，但对 `x < 0` 或 `x == 0` 且 `stacks` 为非整数时不成立。当前 `stacks` 恒为整数且 `interpolated >= 0`（factor 来自目录，min_value 限制），所以省 pow 目前安全，但这不是「边界测试证明一致」能覆盖的——它是**输入域约束**。M1 应写成断言：`stacks >= 1 && interpolated >= 0`，而不是测几个边界值。

## 3. 归并顺序：一个方案未覆盖的真实风险

方案 §5.5 规定规范顺序为「country slot 升序 → program dense id 升序 → origin → command index → term index」。但当前实现的桶聚合**不按这个顺序**：

`rebuild_bucket`（`modifier_runtime.cpp:787-881`）：

```cpp
std::vector<Contribution> live;
live.reserve(bucket.members.size());
for (const Contribution contribution : bucket.members) {   // ← members 的顺序
    ...
    bucket.sum_add += add;                                 // ← 顺序敏感（double 加法）
    ...
    bucket.product_nonzero *= factor;                      // ← 顺序敏感（double 乘法）
}
bucket.members.swap(live);                                 // ← 保留原顺序
```

`bucket.members` 的追加顺序由 `add_instance_to_buckets`（`:890`）的调用顺序决定，而那是**实例创建顺序**，即「哪个国家先 reconcile 完」——**不是**方案要求的 country slot 升序。

**影响：**

1. ADD 的 double 加法**不满足结合律**。同一组 term 以不同顺序相加，末位可能不同。
2. factor 的 double 乘法同理。
3. 因此方案 §5.6 要求的 `max_q16_delta = 0` **在当前实现上不可达**——不是新代码的问题，是旧实现本身没有规范顺序。

**这不是迁移引入的缺陷，但它会让 §5.6 的门禁无法通过。** 三种处理：

| 方案 | 代价 | 我的建议 |
|---|---|---|
| (a) 派生层自己按规范顺序算，旧路径不动；对照测试允许旧路径的末位差异 | 低，但 §5.6 的「0 差异」变成「仅新路径内部 0 差异」 | ✅ 推荐 |
| (b) 把旧路径的 `bucket.members` 排序后再聚合 | 中，会改变所有既有结果，需要全量回归 | 不建议在本次做 |
| (c) 派生层也沿用成员追加顺序 | 低，但主线程/worker 顺序不同，违反 §5.5 与 I10 | 禁止 |

方案 §5.6 已经预留了这条：「若旧增量 bucket 的历史顺序导致差异，M0 必须记录反例，选择经审查的统一归并方案并重跑旧路径混合测试」。**我现在就是在记录这个反例，并建议选 (a)。**

需要补充的是：选 (a) 时，§5.6 的「默认要求最终消费 `max_q16_delta=0`」应改为「**新路径内部**（主线程/worker/重载）`max_q16_delta=0`；新旧对照记录 double 差值与最终 Q16 差值分布，不设硬 0 门槛」。否则门禁无法通过且原因会被误判为派生层 bug。

## 4. §6.6 精确失效前提：已验证成立

方案 §6.6 说「连续 READ_METRIC 的 exact mask 优先：即使同一 metric 也被某张卡用作阈值条件，仍不能只看阈值桶」。

实现链路：

```
effect_runtime.h:345        MetricMask exact_metric_mask;      // FamilyEffectMetadataPod
ideology_runtime.cpp:2769   info.exact_mask |= metadata.exact_metric_mask;
ideology_runtime.cpp:2774   info.exact_mask.set(...)           // 阈值溢出也降级为 exact
ideology_runtime.cpp:2609   exact |= info.exact_mask;          // 跨 program 并集
ideology_runtime.cpp:2629-2632
    for each metric: if (exact.test(metric)) thresholds[metric].clear();
```

`thresholds[metric]` 为空 → `economy_runtime_family_buff.cpp:2267` 的 `if (!metric_thresholds.empty())` 不成立 → **`sampled` 保留原值**，摘要逐值敏感。

**结论：只要 `metadata.exact_metric_mask` 包含 22 与 24，C 类的连续输入就不会被阈值桶冻结。** 而 `effect_runtime.h:341-345` 的注释明确说明 `exact_metric_mask` 正是为 READ_METRIC 与溢出阈值而设。

方案 §6.6 的判断准确，M1 不需要新增这条机制——只需要**断言它被正确填充**。这是 §13.6「遗漏 continuous metric 会让测试失败」的注入点。

## 5. §6.3 的 source-count 缩放公式

方案 §6.3 第 5 步要求 `target_scale_q16 = units*65536/source_count_cap`。实现（`ideology_runtime.cpp:2067-2075` 附近）：

```cpp
int32_t scale_q16 = static_cast<int32_t>(Q16_ONE);
if (effective.target_selector_kind == SELECTOR_TAG_SOURCE_COUNT) {
    const SourceCountSelector selector = decode_source_count_selector(...);
    const int32_t count = ... source_counts[cell] ...;
```

需注意 `magnitude_scale_allowed_for_selector`（`effect_runtime.h:246-256`）对 SOURCE_COUNT 的下界：

```cpp
const int32_t cap = std::clamp(selector.cap, 1, 15);
return scale_q16 >= Q16_ONE / cap;
```

即**缩放下限是 `1/cap`，不是 0**。方案 §6.3 第 4 步「`units=min(source_count, source_count_cap)`」若 `source_count == 0`，`scale = 0`，但 `0 < Q16_ONE/cap` → 被目录校验拒绝。实际内容里 source_count 为 0 的格根本不会命中（BFS 只输出命中格），所以不触发；但 M4 实现派生路径时的**预检**必须保留这条下界，否则 0 源格会以 `scale=0` 通过而旧路径拒绝。

## 6. 提交 M1 的四条数值约束

1. **派生项并入 `add_derived` / `factor_derived`，不得触碰最终值。** §5.1 已验证。
2. **`.cut` 的符号由 term operation 决定，不由 magnitude 符号决定。** command magnitude 被 clamp 在 `[0,4]`（`538-540`），负效果靠 SUBTRACT term（`modifier_catalog.gd:552`）。
3. **归并顺序按 §5.5 实现，但新旧对照的门槛要按 §3 的建议放宽为「新路径内部 0 差异」。**
4. **`effect_runtime.h:246-256` 的 `scale_q16 >= Q16_ONE/cap` 下界必须在派生路径预检里保留。**
