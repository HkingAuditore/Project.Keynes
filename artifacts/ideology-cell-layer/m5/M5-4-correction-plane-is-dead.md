# M5-4 更正 M5-3：旧平面在生产中是**死代码**，不是双算

| 项目 | 内容 |
|---|---|
| 里程碑 | [M5](../22-cell-program-cap-removal-plan-v3.md) §15.7 |
| 日期 | 2026-10-28，Asia/Hong_Kong |
| **更正** | M5-3 说「同一程序被应用两次」——**在生产中不成立** |
| 真实结论 | 旧 v1 平面**从未在生产中被填充**，是纯死代码 |

## 1. M5-3 错在哪

我当时看到：

```
build_cell_program_table()   从不调用 decide_cell_program_backend
economy_runtime.cpp:7394     热路径读取 _ideology_cell_programs
```

就推断「同一个程序被两个机制应用两次」。**这一步推理漏了一个前提**：
`_ideology_cell_programs` 必须**先被填充**，才可能被读到。

## 2. 决定性证据

`_ideology_cell_programs` 只有一个写入点：

```cpp
// economy_runtime.cpp:7237
void NativeEconomyRuntime::set_ideology_cell_programs(CellProgramTable table) {
    _ideology_cell_programs = std::move(table);
```

它的调用者只有 2 处，都在 `world_ext_ideology.cpp`：

| 调用点 | 桥 | GDScript 调用者数 |
|---|---|---|
| `:325` | `publish_ideology_cell_programs()` | **1（测试）** |
| `:447` | `set_ideology_cell_program_entry_for_test()` | 2（测试）|

那唯一的 1 处 GDScript 调用：

```
tests/ideology/ideology_effect_metric_publish_test.gd:617
```

**生产脚本（`scripts/` 全目录）零调用。**

实测确认：B7 里 `[B7] plane: builds=0 derived_elsewhere=0` —— 平面从未构建。

## 3. 因此真实结论是

**旧 v1 平面在生产中从不被填充，永远不会贡献任何值。**

而且 `refresh_city_output_modifier_factors` 的合并段有短路：

```cpp
// economy_runtime.cpp:7371
if (!_ideology_cell_programs.entries.empty() && good_count > 0) { ... }
```

所以它连性能代价都没有——**是纯死代码 + 混淆来源**。

## 4. 我加的 I01 门控怎么评价

**仍然正确，但性质变了**：

| 原判断 | 更正后 |
|---|---|
| 「修掉真实双算 bug」 | 「让死代码在被误启用时也不会双算」|

它不是修 bug，是**防未来**。价值仍在：
- 如果有人重新接上 `publish_ideology_cell_programs`，平面会立刻和派生层打架，而这正是 §15.7 要删它的理由
- `derived_elsewhere` 计数器让「平面被填充了吗」变成可观测事实

**但它不构成 M5 的进展**——真正的进展是下面这条。

## 5. §15.7 的真正目标

> 「删除旧 v1 平面、无效 generation、重复 reader 合并和相关 feature API。」

现在有了确凿依据：**这三样全是死代码**。

| 项 | 位置 | 规模 |
|---|---|---|
| `build_cell_program_table` | `ideology_runtime.cpp:5292-5450+` | ~160 行 |
| 合并段 | `economy_runtime.cpp:7371-7455` | ~85 行 |
| `CellProgramTable` / `CellProgramEntry` | `ideology_cell_program.h` | 整个头文件 |
| 3 个桥 | `world_ext_ideology.cpp:325/447/627` | — |
| 相关状态 | `_cell_program_generation` / `_cell_plane_builds` | — |

**约 250+ 行生产代码在做无用功，并且让任何读 `refresh_city_output_modifier_factors` 的人以为存在第二个 cell 效果来源。**

## 6. 我这次没删的原因

删除面很大（3 个桥还绑在 ClassDB 上、一个测试依赖 `publish_...`、`get_ideology_cell_program_summary` 有 5 个 GDScript 调用者）。

**需要单独一轮**：先迁走 5 个 summary 调用者的断言，再删桥与实现。仓促删会让测试静默失效——那正是我今天反复踩的坑。

## 7. 验证（本轮改动）

| 项 | 结果 |
|---|---|
| 全回归 | **19 / 19**（新增 `ideology_effect_metric_publish_test`，即平面唯一调用者）|
| 构建 | exit 0 |
| B7 平面计数 | `builds=0 derived_elsewhere=0`（证实未填充）|

## 8. 教训

**「A 读 B」+「B 从不调用判定函数」不等于「A 应用了两次」——还要问 B 是否被填充。**

我和 M5-3 一样，只验证了链条的前两环就下了结论。这次的 `builds=0` 是反证，而它来自我自己加的计数器——**加计数器这个动作本身救回了这个错误**。
