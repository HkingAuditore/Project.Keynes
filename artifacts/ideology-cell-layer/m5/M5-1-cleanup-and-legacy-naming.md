# M5-1 清理死代码与 legacy 命名（§15.7 前两项）

| 项目 | 内容 |
|---|---|
| 里程碑 | [M5](../22-cell-program-cap-removal-plan-v3.md) §15.7 |
| 日期 | 2026-10-28，Asia/Hong_Kong |
| 结果 | **删除 144 行死代码**；`SELECTOR_MAX_CELLS` 改为 `LEGACY_INSTANCE_MAX_CELLS` |
| 验证 | 构建 exit 0；全回归 **18 / 18** |

## 1. 删除的死代码

### 1.1 `rebuild_derived_cell_layer`（144 行）

M4-19 把重建改成基于 job 的分片路径后，单发版本就再没有调用点了：

```
全库 rebuild_derived_cell_layer : 仅剩定义 + 4 处注释，0 处调用
```

**保留它是危险的**：它是一份语义等价但**不含 ramp sampler、不含分片**的实现，
后来的读者很可能照它写新代码，然后重新引入 M4-19/M4-20 的缺陷。

### 1.2 `rebuild_derived_cell_layer_sharded`（1 行声明）

**声明了但从未实现**（全库 `.cpp` 零定义）。这是 M4-19 中途换方案留下的残骸。

### 1.3 4 处指向已删函数的注释

| 位置 | 原注释 | 改为 |
|---|---|---|
| `:2218` | `` (`rebuild_derived_cell_layer`) honoured it `` | `step_derived_rebuild` |
| `:2233` | `` `rebuild_derived_cell_layer` `` | `step_derived_rebuild` |
| `:2516` | `` `rebuild_derived_cell_layer()` `` | `step_derived_rebuild()` |
| `:6086` | `counts CALLS to rebuild_derived_cell_layer` | `counts calls to the sharded rebuild` |

**注释指向不存在的函数，比没有注释更糟**——它会让人以为可以调用。

## 2. `SELECTOR_MAX_CELLS` → `LEGACY_INSTANCE_MAX_CELLS`

§15.7 要求：「将剩余 32 常量改为明确 legacy 实例保护名称并更新引用，**不删除仍真实使用的保护**」。

### 2.1 为什么这个常量必须保留

```cpp
// ideology_runtime.cpp —— 只有实例分支会走到这里
if (static_cast<int32_t>(targets.size()) > EffectRuntime::LEGACY_INSTANCE_MAX_CELLS)
    targets.resize(...);
```

派生卡在上面已经 `continue` 了。所以这里的 32 **只限制「一张卡能创建多少个 Effect 实例」**，不限制覆盖多少格。

如果删掉它，一张无法派生的宽选择器卡会把实例表打爆。**这是真实的保护。**

### 2.2 为什么必须改名

旧名 `SELECTOR_MAX_CELLS` 读起来像「选择器能覆盖多少格」——**这正是最初让 32 看起来像设计决策的原因**。

新名 `LEGACY_INSTANCE_MAX_CELLS` 直接说明：这是实例数的 legacy 上限。

### 2.3 保留兼容别名

```cpp
static constexpr int32_t LEGACY_INSTANCE_MAX_CELLS = 32;
// Deprecated alias.
static constexpr int32_t SELECTOR_MAX_CELLS = LEGACY_INSTANCE_MAX_CELLS;
```

约 20 处调用点仍在用旧名（含选择器几何测试）。**一次性重命名会制造大片 diff 而收益有限**，
所以别名保留，新代码用新名，几何问题用 `selector_cell_ceiling(kind)`。

## 3. 剩余的 `SELECTOR_MAX_CELLS` 分类

| 类别 | 处数 | 处置 |
|---|---:|---|
| 实例侧（截断、按卡上限）| 1 | **已改名为 legacy** |
| 模式/几何选择器（`family_buff` 的 `param0` 上限）| 4 | 保留，属选择器几何 |
| 选择器几何测试（`+100` 边界）| 4 | 保留，测的就是几何 |
| `SourceCountSelector::target_cap` 默认值 | 2 | 保留，kind 16 的 target 上限 |
| 注释与文档 | 9 | 部分已更新 |

**没有一处是「派生路径的技术性 32 限制」**——那一条在 M2 已经移除。

## 4. 验证

| 项 | 结果 |
|---|---|
| 构建 | exit 0 |
| B7 / B8 / B10 | 15/0、18/0、16/0 |
| x1b / tag_snapshot_stress | 142/0、38/0 |
| cell_layer 各 fixture | 9/7/13/12/19/20/20/1/2 全 0 |
| 其余 | exit 0 |
| **合计** | **18 PASS / 0 FAIL** |

## 5. §15.7 进度

| 任务 | 状态 |
|---|---|
| 全部 A–F 在受测配置 ON | ✅ rollout `Sources`，265/265 派生 |
| 删除旧 v1 平面 | ✅ 本次删除 144 行死代码 |
| 生产固化后端、删除迁移开关 | ⬜ `kCellProgramRollout` 仍是编译期常量，未删 |
| 32 常量改 legacy 名 | ✅ `LEGACY_INSTANCE_MAX_CELLS` |
| 全量构建、回归、B1–B12、save/load、权威翻转、UI | ⬜ 仅做了 18 fixture 回归 |
| 文档与 skill 同步 | ⬜ 未做 |

## 6. 局限

- 只删了 `ideology_runtime` 内的死代码；`CellProgramTable` 相关（`build_cell_program_table`）等旧平面未审计。
- `kCellProgramRollout` 开关本身仍是迁移期产物，按 §15.7 应删除，未做。
- 未跑 B1–B12 全量、未测 save/load、未测权威翻转。
