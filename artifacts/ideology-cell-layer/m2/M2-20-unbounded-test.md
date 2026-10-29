# M2-20 §13.4 `unbounded` — real 32+ targets through the shipping selector

| 项目 | 内容 |
|---|---|
| 里程碑 | [M2](../22-cell-program-cap-removal-plan-v3.md) §13.4 `unbounded` 行 / §13.2 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 交付 | `economy_runtime_effect_selector_tests.cpp` 新增 unbounded 块（9 个断言）+ `ideology_cell_layer_unbounded_test.gd` |
| 结果 | **通过**；负向对照确认断言真的在执行 |
| 结论 | 31/32/33/200/1000+ 首次通过**真实选择器**验证，不再只有纯核证据 |

## 1. 为什么这条之前做不到

`collect_effect_target_cells` 的领土分支依赖 `_epoch_cell_country`，而它只在真实 epoch 内由 `capture_country_epoch` 填充（M1-13 定案）。

裸 `SceneTree` 里没有 epoch，所以「32 格以上能否命中」一直只有纯核算术证据。

## 2. 找到了正确的接口

`NativeEconomyRuntime` 声明了 `friend struct EconomyTargetSelectorTests`（`economy_runtime.h:179`），而已有的 `economy_runtime_effect_selector_tests.cpp` 正是用这个友谊**直接构造私有列**：

```cpp
rt->_cell_count = kCells;
rt->_building_neighbors = neighbors;
rt->_epoch_cell_country.assign(kCells, 0);
```

这个 self-test 通过 `runtime_economy_target_selector_self_test()` 暴露给 GDScript，所以断言可以写在 C++ 里验证真实选择器，再由一个 GDScript 夹具驱动它执行。

**这就是我前几轮一直缺的那块：不需要 worker 夹具，也能测真实领土选择器。**

## 3. 踩到的一个坑：`kCells` 只有 30

该夹具的网格是 `kCols(6) × kRows(5) = 30` 格，无法表达 200 或 1000。

unbounded 块因此**自建 2400 格网格**：

```cpp
constexpr int32_t kBigCells = 2400;
rt2->_cell_count = kBigCells;
rt2->_building_neighbors.assign(kBigCells * 6, -1);
rt2->_epoch_cell_country.assign(kBigCells, -1);
for (int32_t cell = 0; cell < n && cell < kBigCells; ++cell)
    rt2->_epoch_cell_country[cell] = 0;   // country 0 owns 0..n-1
rt2->_epoch_country_count = 1;
rt2->rebuild_country_territory_index();
```

## 4. 九个断言

对 `n ∈ {31, 32, 33, 200}` 各跑一遍：

| 断言 | 内容 |
|---|---|
| `unbounded_territory_count` | `param0=0` 时命中数 == n |
| `unbounded_explicit_cap` | 显式写 `param0=1000` 时命中数仍 == n（不被压到 32） |
| `unbounded_sorted` | 结果升序 |
| `unbounded_unique` | 结果无重复 |

1000 格额外：

| 断言 | 内容 |
|---|---|
| `unbounded_1000_count` | 恰好 1000 |
| `unbounded_includes_old_cap_boundary` | **包含第 33 格（index 32）** |
| `unbounded_includes_last_cell` | 包含 index 999 |
| `unbounded_explicit_32_respected` | **显式写 32 仍得 32**——删的是默认上限，不是表达能力 |
| `unbounded_map_is_outer_limit` | 写 5000 仍只得到领土内的 1000（地图是外层限制） |

## 5. 负向对照：断言真的在执行

第一次做负向对照时，我把 `== n` 改成 `== n+1`，测试**仍然通过**。一度以为断言没跑。

实际原因是我后续的 `Set-Content` 把那次编辑**覆盖掉了**——实验本身无效，不是测试无效。

重做一次干净的：

```
把 == n 改成 == n + 1 → 构建 → 运行
neg_exit=3
runtime_economy_target_selector_self_test: unbounded_territory_count
```

**错误码 3、错误名精确对上。** 这证明：

1. 断言确实执行；
2. 失败能正确上报；
3. 恢复后测试通过不是「没跑」的假象。

这一条值得单独记：**「测试通过」和「测试没跑」在输出上可能完全一样**，只有负向对照能区分。

## 6. GDScript 夹具的角色

`ideology_cell_layer_unbounded_test.gd` 只有 1 个 check：

```gdscript
var ok := bool(ext.runtime_economy_target_selector_self_test())
_expect("the native target-selector self-test passes", ok, ...)
```

看起来单薄，但它的作用不可替代：**没有调用者，self-test 就是死代码**。它编译进 DLL 却永不执行，正是 §13.1 禁止的「会自证的测试」形态。

## 7. 验证

| 项 | 值 |
|---|---|
| unbounded 夹具 | **1 check, 0 failures**（驱动 9 个 C++ 断言 × 4 个规模） |
| 负向对照 | exit 3，错误名 `unbounded_territory_count` |
| 纯核门禁 | oracle 735 / cap_removed 12 / eligibility 56 / materializer 65 / shard 56 / ceiling 35 / cost_model 28 |
| 覆盖率 | 6/6 |

## 8. 局限

- **GDScript 侧只看到 1 个 check**；9 个 C++ 断言的具体名字不会出现在 GDScript 的输出里，只在失败时从 `printerr` 冒出来。统计检查数时不能把它算成 9。
- 未验证「零实例」这一半——`unbounded` 行的原意包含「真实命中且**零实例**」，而这里只验证了命中，实例数为零需要 ideology 侧联动（与 rollout 同一缺口）。
- 用 `friend` 直接写私有列，与生产填充路径不同；它证明的是**选择器逻辑**，不是**领土捕获**。
- 未测 kind 14/15/16 的 32+ 行为。

## 9. 复算方式

```powershell
$exe = 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64.exe'
Start-Process -FilePath $exe -NoNewWindow -Wait -PassThru `
  -ArgumentList '--headless','--path','Project/project-keynes',
    '-s','tests/ideology/ideology_cell_layer_unbounded_test.gd'
# => 1 check, 0 failures
# 负向对照：把 economy_runtime_effect_selector_tests.cpp 的
#   got.size() == n  改成  == n + 1  → exit 3
```
