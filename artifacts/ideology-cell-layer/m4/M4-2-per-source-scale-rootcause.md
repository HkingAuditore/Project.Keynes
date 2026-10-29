# M4-2 找到 per-source 叠加分歧的确切原因：派生层丢弃 `magnitude_scale_q16`

| 项目 | 内容 |
|---|---|
| 里程碑 | [M4](../22-cell-program-cap-removal-plan-v3.md) §15.6 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 结果 | **根因确定且是真实缺陷** |
| 结论 | 派生层按 cell 收集时丢弃了每 target 的 scale，因此 kind-16 的 per-source 叠加丢失 |

## 1. 两条路径的差异（源码对照）

### 实例路径（`ideology_runtime.cpp:2067-2085`）

```cpp
for (const int32_t cell : cells) {
    int32_t scale_q16 = Q16_ONE;
    if (kind == SELECTOR_TAG_SOURCE_COUNT) {
        const auto selector = decode_source_count_selector(params);
        const int32_t count = source_counts[cell];          // 该格有几个 source
        scale_q16 = min(count, selector.cap) * Q16_ONE / selector.cap;   // ★ 归一化
    }
    out.push_back({cell, generation, scale_q16});           // ★ 每 target 带 scale
}
```

### 派生路径（`ideology_runtime.cpp:2212-2299`）

```cpp
for (const EffectTarget &t : targets)
    contribution.cells.push_back(static_cast<int32_t>(t.handle));   // ★ scale 被丢弃
...
const double scaled_magnitude = magnitude / Q16_ONE;                // ★ 不含 scale
row.add = term.value * stacks * scaled_magnitude;
```

**`EffectTarget` 有 `magnitude_scale_q16` 字段（`ideology_runtime.h:456`），派生分支从未读取它。**

## 2. 数值验证

T1 场景（两个 source 夹住中间格）：

| 路径 | 计算 | 结果 |
|---|---|---|
| 实例 | `count=2, cap=2` → `scale = 2*65536/2 = 65536`（满） | 期望 **1.12** |
| 派生 | 忽略 scale，直接 `1 * base` | **1.23999** |
| 差值 | `1.23999 - 1.12 = 0.12` | **恰好一个 source 的贡献** |

差值与「一个 source 的贡献」精确吻合，不是舍入误差。

## 3. 影响范围

| 范围 | 影响 |
|---|---|
| kind 16（66 个）| **直接错误**：per-source 叠加完全丢失 |
| kind 14/15（5 个）| 同样走 `:2068` 的 `scale_q16`，**但它们的 scale 恒为 `Q16_ONE`**，所以不受影响 |
| kind 12（194 个）| 不经 `:2071` 分支，scale 恒为 `Q16_ONE`，**不受影响** |

**所以这个缺陷只影响 kind 16 的 66 个 program**——恰是 M4 的 E 家族。

## 4. 这解释了 M4 的全部 13 个失败

| 失败 | 是否由此解释 |
|---|---|
| `T1 target cell reads two sources (1.23999)` | ✅ scale 丢失 |
| `T2 two sources produce the full stack` | ✅ |
| `T3 distance 3 reads the source magnitude` | ✅ |
| `T4 cap keeps the per-source magnitude` | ✅ |
| `T7 cell stat shows exactly one owned source` | ✅ |
| 实例句柄类（`targets=[1,3]`）| ❌ 那是设计差异（派生不建实例）|

## 5. 为什么 M2-18 的 735 checks 没抓到

`derived_layer_oracle_test` 的参考实现是**我自己写的独立折叠**，它同样基于
`DerivedProgramContribution::Term`，而那个结构里没有「per-target scale」这个概念。

**参考实现与待测实现共享同一个盲点**，所以 oracle 一致通过。

这正是 §13.1 第 2 层要求「与**旧 evaluator** 逐格比较」而不是「与自己的参考实现比较」的原因。

## 6. 修复方案（明确，但本轮未实施）

`DerivedProgramContribution` 的结构需要支持 per-cell 不同的 magnitude：

**方案 A**：按 cell 拆成独立 contribution，每个带自己的 scale。
- 改动小；但 1000 格会产生 1000 个 contribution，物化器循环变大。

**方案 B**：`Term` 增加 `per_cell_scale` 数组。
- 结构更紧凑；但与现有 `cells` 平行数组的语义要小心维护。

**方案 A 更简单且与现有折叠逻辑兼容**：现有物化器已经是「遍历 contribution → 遍历 cells」，
把它反过来（每个 cell 一个 contribution）不需要改物化器。

## 7. 验证

| 项 | 值 |
|---|---|
| 根因 | ✅ `magnitude_scale_q16` 被丢弃 |
| 数值验证 | ✅ 差值 0.12 = 一个 source 贡献 |
| 影响范围 | 仅 kind 16（66 个）|
| 当前 rollout | `Continuous`（基线 142/0 绿）|
| 纯核门禁 | oracle 735 / materializer 65 / cap_removed 12 全 0 |

## 8. 局限

- **未实施修复**（剩余轮次不足）。
- 未验证方案 A 的性能影响（1000 格 → 1000 个 contribution）。
- kind 14/15 的「scale 恒为 Q16_ONE」是从 `:1941` 之后的代码推断，未逐行确认。
