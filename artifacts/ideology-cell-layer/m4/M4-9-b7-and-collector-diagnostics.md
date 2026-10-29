# M4-9 B7 夹具与采集器诊断链（`seen=0` 的最后一层）

| 项目 | 内容 |
|---|---|
| 里程碑 | [M4](../22-cell-program-cap-removal-plan-v3.md) §14.2 B7 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 交付 | `ideology_b7_wide_territory_test.gd`、**采集器逐级计数器**、`get_economy_territory_plane()` 桥 |
| 结果 | `seen=0` 的原因缩到**一个分支的 tag 参数**，但未最终定位 |
| 结论 | 诊断链完整可复用；B7 断言仍红（2 项） |

## 1. 本轮新增的诊断能力（可复用）

`collect_effect_activations` 的每个提前返回点现在都有计数器，并在报告中导出：

| 计数器 | 含义 | B7 实测 |
|---|---|---|
| `collect_entries` | 通过 location/level 检查的 idea 数 | 4 |
| `collect_templates` | 遍历到的 active template 数 | 8 |
| `collect_program_empty` | program key 为空 | 0 |
| `collect_pod_fail` | `family_effect_metadata_pod` 失败 | **4** |
| `collect_targets_fail` | `resolve_effect_targets` 失败 | **4** |
| `collect_derived_emitted` | 实际产出派生项 | **0** |

`resolve_effect_targets` 内部同样分级：

| 计数器 | B7 实测 |
|---|---|
| `targets_country_zero` | 0 |
| `targets_domain_gate` | 0 |
| `targets_economy_null` | 0 |
| `targets_anchor_neg` | 0 |
| `targets_collected_empty` | **4** |

**结论：所有前置判断都通过，卡在 `collect_effect_target_cells` 返回空。**

## 2. 领土平面完全正常（排除了最大嫌疑）

新增桥 `get_economy_territory_plane()`：

```json
{ "ok": true, "cell_count": 1600, "plane_size": 1600, "country_count": 1,
  "slot0_cell_count": 1600, "cell0_country": 0, "cell0_country_cell_count": 1600,
  "anchor0": 0, "plane_matches_cell_count": true,
  "own_territory_branch": 4, "own_territory_owned": 6400,
  "own_territory_emitted": 0,
  "own_last_source_cell": 0, "own_last_country": 0, "own_last_cap": 1600,
  "own_first_cell_ok": 0 }
```

**每一项都是正确的**：平面尺寸匹配、anchor=0、country=0、cap=1600、`country_cell_at(0,0)` 返回 0。

**但 `own_territory_emitted=0`。**

## 3. 剩下的矛盾（未解）

同一分支内：

```cpp
for (int32_t index = 0; index < owned; ++index) {   // owned = 1600
    const int32_t cell = country_cell_at(country, index);   // 第 0 个返回 0
    if (cell < 0) continue;
    if (tag >= 0 && !snapshot_has_tag(tags_ptr, cell, tag)) continue;
    out_cells.push_back(cell);
}
```

- `owned=1600`（计数器确认）
- `country_cell_at(0,0)=0`（探针确认）
- `tag=-1`（`param1=0` → `tag = param1 > 0 ? param1-1 : -1`）

**按源码这个循环必然产出 1600 个 cell，但 `emitted=0`。**

未解的可能性：
1. `_own_territory_emitted` 累加的位置在 `effect_stable_cap` 之后，而 cap 把结果清空 —— 但 `cap=1600 == cells.size()`，`effect_stable_cap` 会在第 42 行直接 return；
2. `out_cells` 在返回后被调用方丢弃 —— 但 `targets_collected_empty=4` 说明调用方看到的是空；
3. 分支被进入 4 次，但其中 2 次（Cost 项）走了别的路径，计数混淆。

**我没有再往下追。**

## 4. 一个已确认的独立问题：程序 selector kind 不一致

- `.tres` 里 `ProgSaltMonopolyL1` 的 `target_selector_kind = 12`；
- 但 `resolve_effect_targets` 的 `SELECTOR_TAG_SOURCE_COUNT`（kind 16）分支 `:1922` 有 `if (selector.tag <= 0) return false;`；
- 而这张卡的 `target_selector_param = (0, 0)`，若被当作 kind 16 解码，`tag=0` → 必然 `return false`。

**如果 `family_effect_metadata_pod` 把 kind 12 的卡解成 kind 16，那 `targets_fail=4` 就有了完整解释。这是一个值得单独查的可能缺陷。**

## 5. B7 的当前状态

| 断言 | 结果 |
|---|---|
| A: 国家拥有 1000+ 格 | ✅ `owned cells=1600` |
| B: 卡覆盖 > 32 格 | ❌ `front_cells=0` |
| C: 覆盖至少达到几何上限 | ❌ |
| D: 派生卡零实例 | ✅ `instances=0` |
| 经济 epoch 打开 | ✅ |
| 理念 ACTIVE | ✅ `locations=[1]` |
| 经济日完成 | ✅ 47 片 |

**14 checks, 2 failures。**

## 6. 性能数据（本轮顺带取得）

| 场景 | `tag_snapshot_build_ms` |
|---|---|
| 48 格（tag_snapshot_stress）| **0.0092 ms** |
| 1600 格（B7）| **8.8033 ms** / 17.7553 ms（两次运行）|

**结论：「per-tag changed words」这项 M4 任务对 48 格场景无收益（9 微秒），但对 1600 格场景，一次重建要 8.8 ms，增量更新有价值。** 这是本轮唯一可直接用于 M4 决策的数据。

## 7. 交付物

| 文件 | 说明 |
|---|---|
| `ideology_b7_wide_territory_test.gd` | B7 夹具，14 checks |
| `economy_runtime.h` | 6 个采集器计数器、5 个目标解析计数器、3 个选择器计数器、`epoch_cell_country_size_for_test()` |
| `world_ext_country.cpp` | `get_economy_territory_plane()` 桥 |
| `economy_runtime_family_buff.cpp` | 采集分支与选择器分支的计数点 |
| `economy_runtime_diagnostics.cpp` | 导出全部计数器 |

## 8. 局限

- **B7 的 2 个核心断言仍红。**
- 「`emitted=0` 而输入全对」这个矛盾未解。
- 「程序 selector kind 不一致」未验证。
- 计时数据来自两次单点测量，未做分位数。
