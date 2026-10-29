# M2-2 selector cell ceiling split — findings

| 项目 | 内容 |
|---|---|
| 里程碑 | [M2](../22-cell-program-cap-removal-plan-v3.md) 前置 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 交付 | `gdext/src/selector_cell_cap.h`（纯头文件）、`effect_runtime.h` 委托 + `static_assert` 守卫、`selector_cell_cap_test.cpp` |
| 证据 | **25 checks 0 failures**；static_assert 守卫生效（故意改坏后构建失败）|
| 结论 | 32 的语义已拆开；**改变行为的前置已就位，但行为本身尚未改变** |

## 1. 拆的是什么

`SELECTOR_MAX_CELLS = 32` 一个常量承担了两种无关语义：

| 语义 | 含义 | 是否应保留 |
|---|---|---|
| **几何** | 径向走格物理上最多能到多少格 | 保留（否则无法表达 R1/R2） |
| **内容策略** | 一张卡最多覆盖本国多少格 | **本方案要删除** |

这个混用正是「取消 32 上限」看起来像一行改动、实际要改三层的根因（M2-1）。

## 2. 实现

新增 `gdext/src/selector_cell_cap.h`，**无 Godot 依赖**：

```cpp
selector_cell_ceiling(kind)          // 该种类的上限
selector_cell_cap_is_unbounded(kind) // 是否「无策略上限」
resolve_selector_cell_cap(kind, authored, map_cells)  // 实际该用多少
```

| 种类 | 上限 |
|---|---|
| `NEIGHBORS_R1` | **6**（六边形第一环，不含源格） |
| `NEIGHBORS_R2` | **18**（第 1+2 环，不含源格） |
| `OWN_TERRITORY` / `TAG_SOURCE_R1/R2/COUNT` / `FAMILY_OWNED` | **无策略上限** |
| 未知种类 | 回落 32（**失败取严**，不静默放宽） |

`effect_runtime.h` 改为委托，并用 7 条 `static_assert` 保证两处种类 id 一致。

## 3. 为什么单独成头文件

原计划直接在 `effect_runtime.h` 里写，但**编译失败**：

```
fatal error C1083: 无法打开包括文件: "godot_cpp/variant/dictionary.hpp"
```

`effect_runtime.h` 依赖 godot_cpp，无法独立单测。把纯逻辑移出后：

- 可以用 25 条纯核断言直接验证；
- 暴露了一个设计事实：**这段决策从来不需要 Godot**，它一直被埋在需要重依赖的头里，所以没被测过。

这不是重构洁癖，是「让该被测的东西可测」。

## 4. 关键约束：拆分不改变任何现有行为

`resolve_selector_cell_cap` 对无上限种类返回 `min(authored, map_cells)`，所以：

```
authored = 32  →  min(32, 6400) = 32      ← 仍是 32
```

194/194 个 kind-12 program 都写 `(32, 0)`，**当前有效目标集完全没变**。这是刻意的：拆分只准备好前置，行为改变必须与内容更新同批进行（否则一次提交同时动常量和 194 个 `.tres`，回归归因会失控）。

测试 E 组专门锁住这一点：若将来有人误把 `resolve` 写成「无上限就返回 map_cells」，E 会立即失败。

## 4.1 一次差点发生的错误：几何上限取错了

首版我把 `NEIGHBORS_R1` 写成 18、`NEIGHBORS_R2` 写成 37，依据是方案里「半径 3/4 需要 37/61 格」的注释。

**那是 `TAG_SOURCE_COUNT` 的 BFS 半径，不是 R1/R2 的扇出。** 既有测试写得很清楚：

```
economy_runtime_effect_selector_tests.cpp:207-214
  R1 == 6        (selector_r1_count)
  R1 不含源格    (selector_r1_excludes_source)
:225-226
  R2 <= 18       (selector_r2_cap)
```

即六边形环 6 / 18，**都不含源格**。若按首版实现，R1 的上限会从 6 放宽到 18（**3 倍**），而 R2 从 18 放宽到 37，两者都是静默的行为扩大。

这个错误说明一件事：**拆分常量时，新的数字必须从既有断言里读出来，而不是从方案的散文描述里推断。** 我已在代码注释里写明出处，避免下一个人重新推一遍。

## 5. static_assert 守卫是验证过的，不是假设

种类 id 在纯头文件里重复声明了一次（为了让纯头文件不依赖 `effect_runtime.h`）。这是有风险的做法，所以加了守卫并**实测**：

- 把 `CAP_SELECTOR_OWN_TERRITORY` 从 12 改成 99；
- 构建失败：`effect_runtime.h(322): error C2607: 静态断言失败`；
- 恢复后构建成功。

**一个从未被触发过的守卫等于没有守卫**，所以这一步值得做。

## 6. 测试（25 checks）

| 组 | 内容 |
|---|---|
| A | R1 = 18、R2 = 37；径向种类有界；超量作者被压回几何上限；未写值的径向种类用几何默认 |
| B | 五个领土/来源种类均报告无上限 |
| C | **哨兵值不是可用计数**：未写值时覆盖地图而非 INT32_MAX；写 1000 在 6400 地图得 1000，在 256 地图得 256；0 格地图得 0 |
| D | 未知/越界种类回落 32，且不被当作无上限 |
| **E** | **写 32 仍是 32**（三个种类）；小地图仍向下压 |
| — | 遗留常量仍是 32；纯头文件确实无 Godot 依赖 |

## 7. 局限

- **行为未改变。** 本轮只准备前置。`collect_effect_target_cells` 与 `ideology_runtime.cpp` 的四处调用仍用旧的 `SELECTOR_MAX_CELLS`，尚未改用 `resolve_selector_cell_cap`。这是刻意的分步：先让新语义可测且可验证「不改变现状」，再逐处迁移。
- **两处校验（GDScript `ideology_effect_definition.gd:261-266` 与 C++ `effect_runtime.cpp:1005-1013`）尚未放宽。** 所以内容参数现在仍不能写 >32。
- ~~`NEIGHBORS_R1 = 18` 未核对~~ **已核对并修正**：`economy_runtime_effect_selector_tests.cpp:206-226` 明确断言 `selector_r1_count == 6`、`selector_r1_excludes_source`、`selector_r2_cap <= 18`。首版写的 18/37 来自方案里「半径 3/4 需 37/61」的注释，那是 **kind 16 的 BFS 半径**，不是 R1/R2 扇出。**差点把 R1 放宽 3 倍**（18/6）。已改为 6/18。
- 未统计是否有其它地方（GDScript 或工具链）独立硬编码 32。

## 8. 复算方式

```powershell
cd gdext
$vcvars = 'C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat'
cmd /c "call `"$vcvars`" >nul 2>&1 && cl /std:c++17 /O2 /EHsc /W4 /I src tests\selector_cell_cap_test.cpp /Fe:..\.codex-tmp\ceiling_test.exe /Fo:..\.codex-tmp\"
& ..\.codex-tmp\ceiling_test.exe    # => 25 checks, 0 failures
```
