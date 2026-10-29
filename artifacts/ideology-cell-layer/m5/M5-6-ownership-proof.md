# M5-6 归属筛选的端到端证据 + 负向对照

| 项目 | 内容 |
|---|---|
| 里程碑 | 新增目标项（「周围地块」归属筛选）|
| 日期 | 2026-10-28，Asia/Hong_Kong |
| 结果 | **真实环跨越国界已被测量**；谓词精确划分；**负向对照证明断言真的执行** |
| 验证 | 全回归 19/19、内核 85/0 |

## 1. 把过滤抽成共享实现

上一轮的过滤逻辑内联在 `resolve_effect_targets` 的扇出循环里。这轮抽成：

```cpp
void NativeIdeologyRuntime::apply_fan_out_ownership_filter(
        int32_t source_cell, int32_t ownership_scope,
        std::vector<int32_t> &cells) const;
```

生产路径与探针桥**调用同一个函数**。两份副本各自演化正是 32 上限当初漂移的方式。

## 2. 端到端证据：在哪里测到，为什么在那里

### 2.1 GDScript 路线失败（如实记录）

我写了双国 kind-16 夹具，两处受阻：

| 障碍 | 症状 |
|---|---|
| 领土按行主序前缀分配 | `source country slot=1`（源格落在 B 国，测错了一侧）|
| 环为空 | `OWN=0 FOREIGN=0 ANY=0 (raw=0)` |

第二点查到根因：`_building_neighbors` 只能由 **C++ 友元测试**赋值（`economy_runtime_effect_selector_tests.cpp:163`），GDScript 侧的 `MapStub` 无法填充它。

**顺带发现一个诊断缺陷**：我加的 `building_context_ready_for_test()` 报 `ready: true`，因为**它只校验四个列的长度，不校验内容**——而实际邻居全是 `-1`。这个「就绪」判定本身会误导人，已记录。

### 2.2 C++ 选择器测试：正确的位置

`economy_runtime_effect_selector_tests.cpp` 拥有：
- `build_hex_neighbors()` —— 真实六边形邻接
- `_epoch_cell_country` —— 真实归属数据
- 友元访问 —— 可以直接设置列

在这段测试里加了一组断言（`M5-6`）：

```cpp
// 把网格按列分成两国
rt->_epoch_cell_country[cell] = (cell % kCols) >= kTerrainSplitCol ? 1 : 0;
const int32_t border_source = kInteriorRow * kCols + (kTerrainSplitCol - 1);

std::vector<int32_t> ring;
rt->collect_effect_target_cells(border_source, ER::SELECTOR_NEIGHBORS_R2, 0, 0, ring);
```

| 断言 | 证明什么 |
|---|---|
| `ownership_ring_non_empty` | 环非空（前置） |
| **`ownership_ring_straddles_the_border`** | **真实 R2 环确实同时包含两国的格** |
| `ownership_predicate_matches_country_split` | 谓词结果与归属划分逐格一致 |
| `ownership_own_plus_foreign_partitions_any` | `OWN + FOREIGN == ANY == ring.size()` |
| **`ownership_own_drops_foreign_cells`** | **OWN 真的丢掉了格**（`own_kept < any_kept`）|
| `ownership_default_is_own` | `decode(32) == OWN` |

**这组断言串起了整条链**：真实 selector 输出 + 真实归属 + 生产谓词。

## 3. 负向对照（这次我做了）

前三轮我三次把「自己诊断工具的缺陷」当成产品证据。这次在宣布通过前先把一条断言翻转：

```cpp
// 临时改成 own_kept >= any_kept
if (!expect(own_kept >= any_kept, "NEGATIVE_CONTROL_ownership", error))
```

结果：

```
=== ideology x1b source count: 142 checks, 1 failures ===
runtime_economy_target_selector_self_test: NEGATIVE_CONTROL_ownership
ERROR: [FAIL] native kind-16 pack/decode matches GDScript
```

**断言确实在执行。** 恢复后回到 142/0。

**如果没有这一步，「x1b 仍 142/0」完全可以意味着「我加的断言从未被调用」。**

## 4. 默认值变更的影响评估（用户要求）

### 4.1 受影响的卡

| kind | 卡数 | `param0` 实测值 | 解码 |
|---|---:|---|---|
| 14 | 5 | 32 | OWN |
| 16 | 66 | 544 / 576 / 800 / 832 / 864 / 1568 | OWN |

**74 张卡没有一张写过归属位，全部落到新的 OWN 默认。**

### 4.2 影响方向

`ownership_own_drops_foreign_cells` 证明 OWN 会丢弃格。**方向明确：这些卡的作用范围变小了，即只在国境内生效。**

具体每张卡少覆盖多少格，取决于该国边境的 tag 命中格数——这需要真实地图，本轮未量化（记为开放项）。

### 4.3 恢复旧行为的路径

显式设 `OWNERSHIP_ANY`（bit12..13 = 2）。gds：
```gdscript
IdeologyEffectDefinitionScript.pack_source_count(cap, radius, src_cap, tag, 2)
```

## 5. 回归

| 项 | 结果 |
|---|---|
| 全回归 | **19 / 19** |
| 内核单测 | **85 / 0** |
| 选择器自测（含新断言）| x1b 142/0，负向对照 142/1 |

## 6. 交付物

| 文件 | 说明 |
|---|---|
| `ideology_runtime.cpp/.h` | `apply_fan_out_ownership_filter` 抽为共享成员 |
| `world_ext.h` / `world_ext_modifier.cpp` | `probe_fan_out_ownership` 探针桥 |
| `economy_runtime.h` / `_family_buff.cpp` | `building_context_ready_for_test()` |
| **`economy_runtime_effect_selector_tests.cpp`** | **6 条归属断言（含环跨境的实测）** |
| `ideology_ownership_scope_probe.gd` | GDScript 探针（**当前 4 项失败**，见 §2.1）|

## 7. 局限

- **每张卡少覆盖多少格未量化**（需真实地图）。
- GDScript 探针仍失败：`MapStub` 无法填充 `_building_neighbors`，所以那条路走不通；证据改由 C++ 自测提供。
- `building_context_ready_for_test()` 只校验长度不校验内容，会误报 `ready: true`。
- 未在 release DLL、未在真实生成世界上验证。
