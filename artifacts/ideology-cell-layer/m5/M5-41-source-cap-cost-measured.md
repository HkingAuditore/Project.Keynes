# M5-41 源格解封的成本测到了：收集更快，代价在下游

| 项目 | 内容 |
|---|---|
| 里程碑 | [M5-39](M5-39-kind14-uncap.md) 的「成本未测」项 |
| 日期 | 2026-10-28，Asia/Hong_Kong |
| 结果 | **测到了**，而且与直觉相反：`collect` 变快，代价在 50 倍的环形遍历 |
| 验证 | **4 checks / 0 failures** |

## 1. 为什么这次能测到

前两次都卡在「让一张 kind-14 卡的 tag 匹配上」，第二次还卡在 POD 解析（M5-40）。

**换了个问法就好了**：解封的成本不在卡片机制里，而在
`collect_effect_target_cells(anchor, OWN_TERRITORY, cap, tag, sources, ...)` 这一句——
它构建**源集**。而这句可以直接通过 M5-6 加的 `probe_fan_out_ownership` 桥调用，
**根本不需要卡片**：

| 参数 | 复现的行为 |
|---|---|
| `param0 = 32` | 旧的「32 个源」 |
| `param0 = 0` | 新的「整块领土」 |

`param1 = 0` 表示不过 tag 过滤——这是两种情形里更大的那个，正适合做成本上界。

## 2. 途中发现我的探针桥本身有 bug

第一次测出来 `cap=32` 与 `no cap` **都是 32 个源**：

```cpp
// probe_fan_out_ownership 里的原逻辑
const int32_t cap = pk::ownership_stripped_cap(p0) > 0
    ? pk::ownership_stripped_cap(p0) : 32;   // ← param0 = 0 被硬钳成 32
```

**这个桥根本测不到解封场景**，如果只看时间比值（1.06×），会得出
「去掉上限不花任何代价」的**假结论**。

生产路径用的是 `resolve_selector_cell_cap(OWN_TERRITORY, param0, cells)`。
把桥改成同一个调用后才测得出真东西。

**这是「断言抓到了工具 bug」的第四次**：`no cap yields the whole territory as sources`
这条断言（期望 1600，实得 32）是唯一让问题暴露的东西。

## 3. 实测（1600 格单国，5 次取中位数，含预热）

```
[cost] cap=32 : sources=32     collect_ms=0.2170
[cost] no cap : sources=1600   collect_ms=0.0610
[cost] time ratio = 0.28x   source ratio = 50.0x
[cost] ring walks per resolve: 32 -> 1600 (one per source)
```

| 指标 | cap=32 | 无上限 | 变化 |
|---|---:|---:|---:|
| 源格数 | 32 | **1600** | **50×** |
| 收集耗时 | 0.2170 ms | **0.0610 ms** | **0.28×（更快）** |

## 4. 为什么收集反而更快

`effect_stable_cap` 要在**全部候选**里按稳定哈希挑出 `cap` 个：哈希 1600 个元素再排序。
不封顶时这一步整个跳过。

**所以「拿到全部源」比「挑 32 个」更便宜。**

## 5. 真实代价在哪

在**下游**：每个源要做一次 R1/R2 环形遍历（`collect_effect_target_cells(source, ring_kind, ...)`
加一次归属过滤）。

**32 → 1600 意味着环形遍历变成 50 倍。**

我没有把环形遍历的耗时测出来——那需要在夹具里造出可用的 `_building_neighbors`
（`collect_effect_target_cells` 的径向分支要求邻接表与四个列都就位），
这是一个独立的工作量。

**我能说的是**：

| 项 | 有没有数字 |
|---|---|
| 源集收集 | ✅ 0.0610 ms（1600 源），**比封顶更快** |
| 环形遍历次数 | ✅ **32 → 1600（50×）** |
| 环形遍历耗时 | ❌ 没有 |
| **一次 resolve 的总耗时** | ❌ 没有（= 收集 + 50× 环形，缺后一项） |

## 6. 对发布说明的影响

原来的措辞「机制上界从 `32 × 环形` 变成 `领土格数 × 环形`，没有数字」现在可以更准：

> 去掉源上限后，**源集收集本身不变慢**（实测 1600 源 0.061 ms，比挑 32 个的 0.217 ms 更快，
> 因为跳过了稳定哈希截断）。代价在**环形遍历变成 50 倍**（1600 格国家从 32 次变 1600 次）。
> 单次 resolve 的总耗时**仍未测**（缺环形遍历那一半）。

## 7. 交付物

| 文件 | 说明 |
|---|---|
| `tests/ideology/ideology_source_cap_cost_test.gd` | **4 checks / 0**，含预热、5 次中位数、两条结构性断言 |
| `gdext/src/world_ext_modifier.cpp` | **修了探针桥的 cap 解析 bug**（改为与生产同一个 `resolve_selector_cell_cap`）|

## 8. 局限

- 只测了**收集**，没测环形遍历，所以没有「一次 resolve 总耗时」。
- 只测了单国 1600 格、无 tag 过滤（最坏情形）；带 tag 过滤会更便宜。
- 未测 release DLL 上的同一比较。
