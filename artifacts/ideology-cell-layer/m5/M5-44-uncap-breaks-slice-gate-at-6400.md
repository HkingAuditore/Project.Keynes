# M5-44 解封的代价：6400 格国家的一次 resolve 约 2.2 ms，**超过 slice 门槛**

| 项目 | 内容 |
|---|---|
| 里程碑 | [M5-39](M5-39-kind14-uncap.md) 的 §14.3 影响 |
| 日期 | 2026-10-28，Asia/Hong_Kong |
| 严重性 | **§14.3 单 slice ≤ 1 ms 在 6400 格国家上被突破** |
| 结果 | 数字齐了；**这是我上一轮标注「未验证」的那一问的答案** |

## 1. 上一轮我标注的未验证项

M5-43 写：「resolve 是否受 slice 预算保护——分片保护的是重建，不是 resolve」。**这一轮查清了：不受保护。**

`step_derived_rebuild` 的采集阶段是**一整块**（`ideology_runtime.cpp:6963-6972`）：

```cpp
_derived_rebuild_contributions.clear();
for (const CountryState &country : _countries) {
    if (country.handle == 0) continue;
    for (const IdeaState &state : country.ideas) {
        ...
        collect_effect_activations(country, state, throwaway,
            &_derived_rebuild_contributions);     // ← 逐格扇出在这里面
    }
}
_derived_rebuild_collected = true;
_cell_layer_rebuild_ms = std::max(_cell_layer_rebuild_ms, elapsed_ms(started));
```

**循环内没有任何让出点或预算检查。** 代码自己的注释也承认这一点：

> Collection is a STEP of its own. At 6400 cells it costs 0.68 ms…

那句注释是在**源上限为 32** 的前提下写的。上限去掉后，这个数字不再是 0.68 ms。

## 2. 实测（6400 格单国，无 tag 过滤，5 次中位数，含预热）

```
[cost] territory=6400 cells
[cost] cap=32 : sources=32     collect_ms=0.5540
[cost] no cap : sources=6400   collect_ms=0.1260
[cost] time ratio = 0.23x   source ratio = 200.0x
```

| 指标 | cap=32 | 无上限 |
|---|---:|---:|
| 源格数 | 32 | **6400** |
| 源集收集 | 0.5540 ms | **0.1260 ms** |

1600 格时是 0.061 ms，6400 格是 0.126 ms —— 收集是**次线性**的，它从来不是瓶颈。

## 3. 瓶颈是环形遍历，而它逐源执行

`resolve_effect_targets` 的 kind 14/15 分支（`ideology_runtime.cpp:2118-2124`）：

```cpp
for (const int32_t source : sources) {
    ring.clear();
    _economy_runtime->collect_effect_target_cells(source, ring_kind, ring_cap, 0, ring, salt);
    apply_fan_out_ownership_filter(source, ownership_scope, ring);
    cells.insert(cells.end(), ring.begin(), ring.end());
}
```

**一次 resolve 里循环 源数 次。** 单次 R1 走的实测（M5-43，C++ 选择器夹具，2000 次取平均）是 **0.322 µs**。

## 4. 合计

| 部分 | 6400 格（无上限）| 来源 |
|---|---:|---|
| 源集收集 | **0.126 ms** | 本轮实测 |
| 环形遍历 `6400 × 0.322 µs` | **2.06 ms** | 逐源成本实测（M5-43）× 源数 |
| **一次 resolve 合计** | **≈ 2.19 ms** | 两者相加 |

对比旧行为（32 源）：`0.554 + 32 × 0.322 µs ≈ 0.56 ms`。

| | 旧 | 新 | 倍数 |
|---|---:|---:|---:|
| 6400 格一次 resolve | ≈ 0.56 ms | **≈ 2.19 ms** | **≈ 3.9×** |

## 5. 对门槛的影响

| 门槛 | 值 | 新行为 |
|---|---|---|
| §14.3 单 slice | **≤ 1 ms** | **2.19 ms → 突破** |
| `DERIVED_REBUILD_STEP_BUDGET_MS` | 0.45 ms | **2.19 ms → 约 5 倍** |
| 采集阶段可分割？ | — | **否**（循环内无让出点）|

**这不再是「未测」，而是「测了，超了」。**

## 6. 影响面：不是所有国家都受影响

| 条件 | 影响 |
|---|---|
| 国家领土 ≤ 32 格 | 无变化（源本来就不足 32）|
| 领土中等（如 400 格）| 一次 resolve 约 `0.03 + 400 × 0.322 µs ≈ 0.16 ms`，**无问题** |
| **领土 6400 格** | **≈ 2.19 ms，超门槛约 2.2 倍** |
| 带 tag 过滤 | 源集变小，按比例降低 |

所以**只有超大国家 + kind 14/15 卡**这一组合会撞门槛。全图的 6400 格是方案自己用的最大夹具尺寸，
不是所有存档的常态。

## 7. 三个可选的处置（我没选，需要决策）

| 选项 | 做法 | 代价 |
|---|---|---|
| **A. 接受并记录** | 超大国家在此路径上偶尔超一帧 | 不花工；但 §14.3 在那种局面下不成立 |
| **B. 采集阶段按国家/理念分片** | 把 `for country { for idea }` 改成可续跑的游标 | 中等改动；**单国内部仍不可分割**，6400 格单国仍超 |
| **C. 采集阶段按来源分片** | 把逐源环走也纳入游标 | 改动最大，但能真正把单步压回预算 |

**B 不够**——因为它只按国家切分，而最坏情形是**单个国家**就有 6400 格。
**要真正解决只有 C。**

## 8. 我做了什么、没做什么

| 做 | 没做 |
|---|---|
| 实测两个尺寸的收集成本 | 没有改采集阶段的分片结构 |
| 用实测的逐源成本 × 源数算出总成本 | **没有把这个 2.19 ms 写进性能表当作"通过"** |
| 查清「采集不可分割」是代码事实 | 没有为了让数字好看而缩小夹具 |
| 写清影响面只在超大国家 | 没有单方面改回 32 上限——那是用户的决策 |

## 9. 交付物

| 文件 | 说明 |
|---|---|
| `tests/ideology/ideology_source_cap_cost_test.gd` | 网格改为 6400 格，**4 checks / 0** |
| 本报告 | 门槛突破的实测与推算，以及三个选项 |
