# M4 完成：`Sources` 全部启用，回归仅 1 项改进

| 项目 | 内容 |
|---|---|
| 里程碑 | [M4](../22-cell-program-cap-removal-plan-v3.md) §15.6 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 结果 | **`kCellProgramRollout = Sources`；71 个 program 启用；回归 15 fixture 仅 1 项变化（改进）** |
| 结论 | M4 的 rollout 已交付；其余 5 项任务仍未做 |

## 1. 本轮成果

### 1.1 rollout 全开

```cpp
inline constexpr CellProgramRollout kCellProgramRollout =
    CellProgramRollout::Sources;   // kind 12 / 14 / 15 / 16
```

覆盖：194（kind 12）+ 5（kind 14）+ 66（kind 16）= **265 个 program 全部走派生路径**。

### 1.2 x1b 首次全绿

```
=== ideology x1b source count: 142 checks, 0 failures ===
```

此前（I01 修复后、断言未迁移）是 142/4。

## 2. 断言迁移：从「实例数」到「被寻址的格数」

4 个断言改造，全部走同一个语义：

```gdscript
## Target count for a fixture, accepting EITHER backend.
##
## With I01 fixed a kind-12/16 program is DerivedCell and creates no instances, so
## `fixture["targets"]` is legitimately empty for those. The derived front carries
## the same information as `cell_count` over all stats.
func _target_count(fixture: Dictionary) -> int:
    var inst := (fixture["targets"] as PackedInt64Array).size()
    if inst > 0: return inst
    return int(e.get_derived_cell_layer_report().get("cell_count", 0))
```

| 原断言 | 迁移后 |
|---|---|
| `T1 target handles stay distinct`（size==2）| `T1 two distinct targets are addressed`（`_target_count == 2`）|
| `T2 the centre target remains held`（`handles.size()>0 and value`）| `T2 the centre target keeps the halved scale`（**只查 value**）|
| `T3 radius 3 returns 1..3`（size==3）| `T3 radius 3 addresses three cells`（`_target_count == 3`）|
| **`T8 truncation keeps the 32-cell ceiling`**（size==32）| **`T8 the 32-cell ceiling holds`**（`_target_count == 32`）|

**T8 最重要**：32 格上限现在在两条后端上都成立，且断言不再绑定实现。

## 3. 回归结果

| 项 | 值 |
|---|---|
| 15 fixture 判定变化 | **1 项** |
| 该变化 | `tag_snapshot_stress`: pass/37/0 → **pass/38/0** |
| 6 个 NON-PASS | 与 M0 完全一致的 6 个既有技术债 |
| 纯核门禁 | oracle 735 / materializer 65 / cap_removed 12 / eligibility 56 全 0 |
| coverage | 6/6 |

**这是本次会话中第一次在 rollout 全开状态下得到的绿灯，且不依赖任何已知缺陷。**

## 4. M4 的完成度（诚实评估）

| §15.6 任务 | 状态 |
|---|---|
| **E=66 / F=5 的 rollout** | ✅ **本轮完成** |
| **I01 单一后端** | ✅ M4-4/7 完成 |
| **目标列表无技术性 cap** | ✅ `SELECTOR_MAX_CELLS` 作为几何界保留，默认 cap 已移除 |
| stamp / touched scratch | ❌ 未做 |
| 边境外溢、多国共同影响、来源国家撤销 | ❌ 未做 |
| per-tag changed words / cells | ❌ 未做 |
| 同步文案、解释、保存基础 | ❌ 未做 |
| **退出条件：100+ 来源与 r=1–4、重叠、count cap、跨国边境、所有生产 program 数值通过** | ❌ **未验证** |

**M4 的 rollout 与 I01 已交付；§15.6 的其他 5 项与退出条件未完成。**

## 5. 验证

| 项 | 值 |
|---|---|
| `kCellProgramRollout` | **`Sources`** |
| `x1b_source_count` | **142/0** |
| `tag_snapshot_stress` | **38/0** |
| 15 fixture 判定变化 | **1（改进）** |
| 构建 | exit 0 |
| DLL | `8332c713…` |

## 6. 局限

- **未验证 100+ 来源场景**：M4 的退出条件明确要求它，而现有 fixture 最多 48 格。
- 未做 stamp/scratch、边境外溢、多国影响、per-tag changed words、文案与保存。
- M5 完全未开始。
- 巡航性能（B8/B10）在 rollout 全开下未重测。

## 7. 本次会话的最终边界

| 里程碑 | 状态 |
|---|---|
| M0 / M1 | ✅ 完成 |
| M2 | 32 上限三处移除、性能实测、rollout 打开 |
| M3 | 265/265 DerivedCell、ramp 求值器、物化器、理念激活 |
| **M4** | **rollout 全开 + I01 修复 + 回归绿**；5 项任务与退出条件未做 |
| M5 | ❌ 未开始 |

**目标要求做到 M5。实际完成 M0–M3 + M4 的核心交付（rollout + I01），但 M4 的退出条件与 M5 未完成。**
