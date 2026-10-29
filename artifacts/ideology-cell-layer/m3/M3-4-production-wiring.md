# M3-4 生产链路接通 + 国家级 metric 缓存

| 项目 | 内容 |
|---|---|
| 里程碑 | [M3](../22-cell-program-cap-removal-plan-v3.md) §15.5 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 交付 | 生产采样器接线、国家级 metric 每国缓存、4 个可观测量 |
| 结果 | 构建通过；5 项纯核门禁 + 5 个 GDScript 夹具全 0 失败 |
| 结论 | **M3 的 C 类（ramp）生产链路已闭环**，上轮指出的性能隐患已消除 |

## 1. 上轮指出的隐患

> 国家级 metric 当前每格重复采样。1000 格领土会算 1000 次同一个国家级计数。

**本轮修掉了。**

## 2. 修复方式

### 2.1 采样器签名加入国家

```cpp
// 之前：只能拿到 (metric, cell)
using DerivedRampSampler = std::function<double(int32_t, int32_t)>;

// 现在
using DerivedRampSampler = std::function<double(
    int32_t metric_id, int32_t cell, uint64_t source_country)>;
```

**为什么把 `source_country` 放进签名，而不是在物化器里缓存：** 只有调用方知道哪些 metric 是国家级。物化器无从判断，硬编码 id 区间会把「哪些 metric 是国家级」这个知识复制到第二个地方。

### 2.2 缓存落在 `rebuild_derived_cell_layer`

```cpp
const bool country_scope =
    (metric_id >= 56 && metric_id <= 61) ||
    (metric_id >= 63 && metric_id <= 69) || metric_id == 91;
if (country_scope) {
    const uint64_t key = (source_country << 8U) ^ metric_id;
    ... 命中则直接返回
}
```

缓存生命周期仅限一次 build——采样按定义是 epoch 冻结的，跨 build 复用会拿到过期值。

### 2.3 国家级 id 区间依据

`fill_family_behavior_metrics` 中这些 id 由**国家状态**填充而非格状态（`economy_runtime_family_buff.cpp:1079` 的 X7 计数、per-good 计数、分支计数），因此按构造与 cell 无关。

## 3. 可观测量（让改进可验证）

| 字段 | 含义 |
|---|---|
| `ramp_samples_taken` | 真实调用 `sample_effect_metrics` 的次数 |
| `ramp_samples_memoised` | 国家级缓存命中次数 |
| `ramp_terms_evaluated` | 逐格求值的 ramp 项数 |
| `ramp_terms_deferred` | 因无采样器而延迟的项数 |

**判读规则写进了代码注释：** 若某国家级 metric 在宽领土上 `taken` 增长而 `memoised` 恒为 0，说明缓存键或 id 区间错了。

## 4. 一个失败模式被我显式排除

没有经济运行时，我**不安装采样器**，而不是装一个返回 0 的：

```cpp
if (_economy_runtime != nullptr) {
    sampler = ...;
    options.ramp_sampler = &sampler;
}
```

理由与 M3-3 相同：无根据的 0 会让效果静默消失。延迟至少留下 `ramp_terms_deferred` 计数。

## 5. 验证

| 项 | 值 |
|---|---|
| 构建 | exit 0 |
| 纯核门禁 | oracle 735 / materializer 65 / eligibility 56 / cap_removed 12 / coverage 6-of-6 |
| ramp 求值器 | **13 checks, 0 failures** |
| ramp 物化 | **12 checks, 0 failures** |
| numeric | 7 checks, 0 failures |
| catalog | 9 checks, 0 failures |
| unbounded | 1 check, 0 failures |

## 6. 仍未验证的

| 项 | 说明 |
|---|---|
| 生产采样器的真实取值 | 需要活 epoch；**这是第 6 次撞上同一缺口** |
| 缓存命中率的实测数字 | 诊断字段已就位，但没有真实宽领土场景可跑 |
| 国家级 metric 的正确性 | 只验证了缓存机制，未验证 `sample_effect_metrics` 对 id 56..69 返回的值合理 |
| D=41 条件常数 | 完全未动 |
| 阈值不变但 ramp 输入变化仍刷新 | 未验证 |
| 更新成本与 B9 预算 | 未测 |

## 7. M3 完成度

| 退出条件 | 状态 |
|---|---|
| 同国不同格的 ramp 数值不同且正确 | ✅ M3-3 |
| 阈值不变但 ramp 输入变化仍正确刷新 | ❌ |
| 条件边界与反向失效完整 | ❌ |
| 更新成本与 B9 预算相符 | ❌ |

**1/4 达成。** C 类（ramp，12 个程序）的机制已通；D 类（41 个条件常数）未开始。

## 8. 局限

- 缓存键用 `(source_country << 8) ^ metric_id`；metric_id < 256 所以不会碰撞，但这个前提没有 `static_assert` 保护。
- 未验证 id 56..69 / 91 之外是否还有国家级 metric。
- 生产采样器每次仍分配一个 108 元素的 `std::vector`；宽领土下这是 1000 次分配，应该复用缓冲。
- 未测真实性能影响。

## 9. 复算方式

```powershell
# 诊断字段（需真实 epoch 才有非零值）
# get_ideology_report()["ramp_samples_taken" / "ramp_samples_memoised"]
$exe = 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64.exe'
Start-Process -FilePath $exe -NoNewWindow -Wait -PassThru `
  -ArgumentList '--headless','--path','Project/project-keynes',
    '-s','tests/ideology/ideology_cell_layer_ramp_materialize_test.gd'
# => 12 checks, 0 failures
```
