# M2-5 the 32-cap is removed — findings

| 项目 | 内容 |
|---|---|
| 里程碑 | [M2](../22-cell-program-cap-removal-plan-v3.md) §1.1 核心目标 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 交付 | `param0 == 0` 语义改为「无策略上限」；**194 个内容参数 `(32,0)` → `(0,0)`**；`selector_cap_removed_test.cpp` |
| 证据 | 新测试 **12 checks 0 failures**；回归 **零判定变化** |
| 结论 | **32 格限制在代码与内容两层都真正消失** |

## 1. 最后一块：内容

前几轮把代码侧准备好后，限制仍存在，因为 194 个 kind-12 program 全部写着 `target_selector_param = (32, 0)`。

本轮把它改成 `(0, 0)`，其中 `0` 的语义是「用运行时默认」，而对领地问句来说默认现在是**整片领土**。

| 项 | 改前 | 改后 |
|---|---|---|
| 内容参数 | 194 × `(32, 0)` | 194 × `(0, 0)` |
| 涉及文件 | — | **1 个**（`default_ideology_effects.tres`） |

改动集中在一个文件，这是运气好；若分散在多个文件，回归归因会困难得多。

## 2. 还有一处代码必须同步让路

只改内容不够。原代码是：

```cpp
param0 > 0 ? param0 : EffectRuntime::SELECTOR_MAX_CELLS
```

`param0 == 0` 会被替换成 **32**，于是内容写 0 仍然得 32。改成：

```cpp
resolve_selector_cell_cap(EffectRuntime::SELECTOR_OWN_TERRITORY, param0, cells)
```

即 `param0 == 0` 一路传下去，由 `resolve` 返回地图大小。

**这正是 M2-1 说的「三层联动」的最后一层。** 只改内容、只改常量、或只改这里任何一处，限制都会以某种方式存活。

## 3. 直接证据：不再依赖推断

新增 `gdext/tests/selector_cap_removed_test.cpp`（**12 checks**），断言的不是「代码看起来对」，而是行为：

| 断言 | 内容 |
|---|---|
| **D** | **200 格的国得到 200 个目标**（旧上限 32） |
| **D** | **33 格——刚好超过旧上限一格——全部保留** |
| D | 32 格仍得 32；1 格仍得 1 |
| A | 领土种类报告无上限 |
| **C** | **直接读取 `.tres`，确认没有任何 kind-12 program 还写着 32** |
| C | 194 个全部为 `(0, 0)` |
| C | 地图大小仍是外层限制（9000 格国在 6400 地图上得 6400） |

**C 组读真实内容文件而不是信运行时。** 若哪天有人把内容改回 32，代码侧全部正确、限制仍会复活——这正是 M2-1 记录的三层陷阱，所以必须有测试盯着数据本身。

## 4. 一个刻意的保留

作者**显式**写 32 仍得到 32：

```
simulate_targets(32, 200, 6400) == 32     ✓
simulate_targets(100, 200, 6400) == 100   ✓
```

删除的是**默认上限**，不是「作者不能要求上限」。这样一张确实只该影响 32 格的卡仍然可以表达，而绝大多数卡的意图是「我的全部领土」。

## 5. 回归：零判定变化

15 个 fixture 逐项与 M0 基线比对，**changed verdicts = 0**，包括失败项也一致（`ideology_content_test` 仍是 70/3）。

这是本轮最重要的安全证据：**194 个内容参数 + 一处代码语义改动，没有破坏任何既有断言。**

原因不难理解：现有测试夹具世界都很小（256/512 格），且多数卡在夹具里只覆盖少数格，所以从 32 放宽到「全部领土」在这些世界里结果相同。**这不代表在生产规模上等价**——那需要 §14 的性能验证。

## 6. 验证

| 项 | 值 |
|---|---|
| 构建 | `scons: done building targets.`，exit 0 |
| 上限移除测试 | **12 checks, 0 failures** |
| C++ 纯核上限测试 | 35 checks, 0 failures |
| GDScript 上限测试 | 19 checks, 0 failures |
| materializer / eligibility / shard / layer | 65 / 56 / 56 / 51 |
| 回归 | **changed verdicts = 0** |
| 新 DLL | `9a81088b…` |

## 7. 局限与下一步

- **性能完全未验证。** 194 个 program 的目标集从「最多 32 格」变成「整片领土」。§14.1 的成本模型是 `covered_cells × 156`，`covered_cells` 现在是真实覆盖数而非 32 截断值。**M1-5 测的是 32 格规模；现在需要重测。**
- **未验证生产规模的世界。** 夹具世界（256/512 格）里 32 与「全部」差别不大，所以零回归不能外推到 6400 格地图。
- **`kCellProgramRollout` 仍是 `Off`。** 派生层本身还没启用，所以本轮改变的是**选择器返回多少格**，而不是「这些格是否走派生路径」。限制在**目标解析层**已消失；在**实例层**仍然存在（最多 32 个实例），要等 rollout ON。
- 内容侧 `TAG_SOURCE_*` / `TAG_ANY_CELL` 的参数未同步调整（它们本就不受 32 限制的同一问题影响）。
- 未更新任何面向作者文档说明「0 = 整片领土」。

## 8. 复算方式

```powershell
cd gdext
$vcvars = 'C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat'
cmd /c "call `"$vcvars`" >nul 2>&1 && cl /std:c++17 /O2 /EHsc /W4 /I src tests\selector_cap_removed_test.cpp /Fe:..\.codex-tmp\cap_removed.exe /Fo:..\.codex-tmp\"
cd ..
& .\.codex-tmp\cap_removed.exe    # => 12 checks, 0 failures
```
