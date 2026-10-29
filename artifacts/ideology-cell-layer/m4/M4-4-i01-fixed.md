# M4-4 I01 修复成功：13 → 4 失败，全部数值分歧消失

| 项目 | 内容 |
|---|---|
| 里程碑 | [M4](../22-cell-program-cap-removal-plan-v3.md) §15.6 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 结果 | **`Sources` 下失败 13 → 4**，数值分歧全部消失 |
| 结论 | 找到并修复了 I01 的真实违例；剩余 4 个是断言迁移问题，不是数值问题 |

## 1. 根因：I01 被两个调用点破坏

```cpp
// 改前（:2206）
if (out_derived != nullptr &&                       // ★ 这个条件
    cell_program_rollout_enabled(metadata.target_selector_kind) &&
    backend.backend == CellProgramBackend::DerivedCell) {
    ... 派生路径 ...
    continue;   // no instance
}
// fall through: 创建实例
```

两个调用点：

| 调用点 | `out_derived` | 结果 |
|---|---|---|
| `reconcile_effect_activations`（`:2483`）| **`nullptr`** | 条件为假 → **创建实例** |
| `rebuild_derived_cell_layer`（`:6695`）| 有效 | 条件为真 → **产生派生 rows** |

**开启一个批次后，两条路径同时运行**：同一个 program 既创建实例，又贡献派生 rows。

这直接违反 **I01「one program, one backend」**（方案 §4.5 的硬不变量）。

## 2. 这也解释了 M4-3 的修复为何"没生效"

M4-3 我实现了 per-target scale 传播，但 `Sources` 下失败数不变（13 → 13）。

原因：**夹具读到的 1.23999 来自幸存的实例，不是派生 row。** 我的 scale 修复作用在一条没人读的路径上。

决定性证据是那行失败输出：

```json
{ "count": 4, "present": [1,1,1,1],
  "magnitude_scales": [32768, 32768, 32768, 32768] }
```

`present=[1,1,1,1]` —— 实例仍在。

## 3. 修复

```cpp
// 现在
const bool derive_this_program =
    cell_program_rollout_enabled(metadata.target_selector_kind) &&
    backend.backend == CellProgramBackend::DerivedCell;
if (derive_this_program && out_derived == nullptr) {
    continue;   // ★ 派生后端但本调用点不收 rows：什么都不发
}
if (derive_this_program) {
    ... 每 target 一个 contribution ...
    continue;
}
// 只有非派生 program 才走到这里
```

**判定依据从「调用方能力」改为「程序是否应该是派生」，调用方只决定「能否接收 rows」。**

## 4. 验证结果

| 配置 | 失败数 | 说明 |
|---|---:|---|
| `Continuous`（kind 16 未启用）| **0 / 142** | 无回归 |
| `Sources` + I01 修复前 | 13 | 含 12 个数值分歧 |
| **`Sources` + I01 修复后** | **4** | **数值分歧全部消失** |

剩余 4 个：

```
T1 target handles stay distinct per centre target ([])
T2 the centre target remains held with the halved scale (count: 0 ...)
T3 radius 3 returns 1..3 in the fixture ([])
T8 truncation keeps the 32-cell ceiling ([])
```

**全部是 `targets=[]` / `count=0`**——即「实例列表为空」。这是 I01 修复的正确结果：派生后端不再创建实例，而这些断言读的正是实例列表。

## 5. 两类失败的性质完全不同

| 类 | 数量 | 性质 |
|---|---:|---|
| 数值分歧（1.23999 vs 1.12）| 12 → **0** | **真缺陷**，已修复 |
| 实例句柄断言（`targets=[]`）| 12 → **4** | **测试需要迁移**，不是缺陷 |

M4-1 我把这两类混在一起报告为「13 个失败」，现在证明其中 12 个数值类已被 I01 修复解决。

## 6. M4 剩余工作（明确）

4 个断言需要改成读派生 front 而不是实例：

| 断言 | 当前读 | 应读 |
|---|---|---|
| `T1 target handles stay distinct` | 实例 `target_handles` | derived front 的 `cells` |
| `T2 the centre target remains held` | 实例列表 | front row |
| `T3 radius 3 returns 1..3` | 实例 handle | front cells |
| `T8 truncation keeps 32-cell ceiling` | 实例 | front（且 §12.4 要求 `truncated==0`）|

这需要一个新的测试桥暴露 front 内容（M3-4 加过 `get_derived_materialize_report`，但没有暴露逐格值）。

## 7. 当前状态

**`Sources` 目前是开启的**（4 个失败）。是否留在开启状态取决于：
- 留着：`Sources` 的 rollout 生效，但 4 个断言红；
- 回退：基线全绿，M4 未生效。

**我倾向于回退**，因为目标是「每个里程碑按门禁验收」，红着不算通过。**但这需要下轮决定。**

## 8. 局限

- 4 个断言未迁移。
- 未验证 I01 修复对 kind 12（194 个）的影响——`Continuous` 下 142/0 说明无回归，但那是同一个 fixture。
- 未跑完整 15 fixture 回归。
