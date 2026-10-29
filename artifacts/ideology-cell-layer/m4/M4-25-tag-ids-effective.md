# M4-25 tag_ids 协议生效：296 → 48 个 tag，扫描缩窄 6.2×

| 项目 | 内容 |
|---|---|
| 里程碑 | [M4](../22-cell-program-cap-removal-plan-v3.md) §15.6 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 结果 | **`active=48 consumed=48`**（原 296/0）；全回归 17/17 |
| 结论 | `tag_ids` 协议打通并生效；绝对耗时待校准重测 |

## 1. 决定性数据

```
[B7] consumer: publishes=3  tag_ids=48  levels_with_tags=245
[B7] tag_build_ms=15.2577  builds=2  declared=296  active=48  consumed=48
```

**`active` 从 296 降到 48，`consumed` 从 0 升到 48。**

`cells × tags` 从 `1600 × 296 = 473,600` 次 match 降到 `1600 × 48 = 76,800`，**少 6.2 倍**。

## 2. 打通的三个障碍（都是我的实现缺陷）

### 2.1 `consumed=0`：48 个 id 在发布前被清空

```cpp
// 我最初的保守回退
if (tag_ids_incomplete) tag_ids.clear();
```

`_synergy_overrides` 非空时我把整个集合标为「不完整」并清空，于是 publisher 里明明已经收集到 **48** 个 id，economy 收到的却是空集。

**诊断数据是关键**：`publishes=3 / tag_ids=48 / levels_with_tags=245` —— publisher 明明跑过并有值，问题只能在传递处。

### 2.2 override 的 tag 是可枚举的，不该放弃

改为从 `_synergy_overrides` 直接收集：

- `_synergy_tag_overrides` 的 **key 就是 tag 索引**
- `SynergyOverride::match_tag_id` 是选择器读的 tag，`tag_id` 是改写后应用的 tag

**两个都要收**：只收替换后的，选择器会去读一个从未计算过 bits 的 tag。

### 2.3 `_synergy_overrides` 是 vector 不是 map

我第一次写成 `_synergy_overrides.find(synergy_id)`，编译报 `"find" 不是 std::vector 的成员`。改为按下标访问并做边界检查。

## 3. 这一条为什么重要

`levels_with_tags=245` 说明**几乎所有等级都声明用 tag**，但它们只涉及 **48 个不同的 tag id**。

也就是说：`tags_needed` 这个布尔在过去把「48 个真的要用」放大成「296 个全算」。

**这正是 M4-22 找不到收益的原因**：当时我以为「没有废 tag 可跳」，实际是**协议根本没把集合传下来**。

## 4. 保守回退仍然保留

```cpp
// 空集 + tags_needed=true 视为「全部 tag」
if (consumed != nullptr && !consumed->empty()) { ...narrow... }
else { ...all tags... }
```

这条必须留：synergy override 若引入一个无法枚举的 tag，收窄会静默丢掉目标格。现在 override 可枚举，回退只在真正的异常情况下触发。

## 5. 回归

**17 / 17 全绿**，含：

| fixture | 结果 |
|---|---|
| B7 | 15 / 0 |
| B8 | 18 / 0 |
| B10 | 16 / 0 |
| x1b | 142 / 0 |
| tag_snapshot_stress | 38 / 0 |
| 其余 12 个 | 全 0 |

**收窄没有丢掉任何需要的 tag** —— 这是最关键的验证：如果漏收一个 tag，`tag_snapshot_stress`（专门测 tag 翻转）会立刻失败。

## 6. 局限

- **绝对耗时未按 M4-24 的校准协议重测**。单次 `15.26 ms` 与之前的 `16.98/15.77/29.31` 不能直接比（spread 太大）。
- match 次数的 6.2× 减少是**确定的**（计数，不是计时），但毫秒数需要预热 + 多批中位数重测。
- per-tag changed words（增量）仍未做——现在有了准确的 tag 集合，增量更新的前置条件才真正具备。

## 7. 交付物

| 文件 | 说明 |
|---|---|
| `ideology_runtime.cpp` | override tag 收集（`match_tag_id` + `tag_id`）、vector 下标访问、publisher 诊断 |
| `ideology_runtime.h` | `_consumer_publish_calls` / `_consumer_tag_ids_last` / `_consumer_levels_with_tags` |
| `ideology_b7_wide_territory_test.gd` | consumer 诊断输出 |
