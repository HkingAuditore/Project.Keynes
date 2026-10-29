# M2-3 migrating the territory cap site — findings

| 项目 | 内容 |
|---|---|
| 里程碑 | [M2](../22-cell-program-cap-removal-plan-v3.md) 前置 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 交付 | `economy_runtime_family_buff.cpp` 的 OWN_TERRITORY 上限改用 `resolve_selector_cell_cap`；测试扩到 **35 checks** |
| 证据 | 35 checks 0 failures；回归 **零判定变化**；新 DLL `1e7c41ea…` |
| 结论 | 只迁移了一处，**另三处有意不迁移**（理由见 §4） |

## 1. 测试先抓到我一个错误

我原本只想做「等价替换」，但测试立刻失败：

```
FAIL F: the migrated call site computes the same cap as before
  authored=100 old=32 new=100
```

原因：我把该处改用了 `SELECTOR_OWN_TERRITORY`，而它现在**无策略上限**，所以 `authored=100` 会真的得到 100，而不是被压到 32。

**这不是等价替换，行为已经变了。** 我必须判断这是否可接受。

## 2. 判断：可达性分析

关键在于「`authored > 32` 能不能出现」：

| 校验 | 位置 | 反应 |
|---|---|---|
| GDScript | `ideology_effect_definition.gd:261-266` | `param[0] > 32` → `ideology_effect_selector_cap_invalid` |
| C++ | `effect_runtime.cpp:1005-1013` | 同条件 → `effect_family_metadata_invalid` |

**两层都会拒绝，所以任何已编译的 catalog 都不可能含有 `authored > 32`。** 于是：

- 对现有全部内容（194/194 都是 32），新表达式与旧表达式**逐一相同**；
- 放宽只在两层校验被放开之后才可观测——而那是**另一次可评审改动**（M2-1 §3 要求的顺序）。

结论：迁移**在可达范围内完全等价**。我的测试用例把「不可达的值」当成「必须相等」，是测试写错了，不是实现错了。

修正后的测试把两件事分开：

| 用例 | 断言 |
|---|---|
| F（可达值） | `authored ∈ {0,1,16,32}` 时新旧逐一相同 |
| F2（未来增量） | `authored=100` 会得到 100 —— **显式记录这个差异**，而不是藏起来 |
| F3（今日唯一可达差异） | 地图小于 authored 时会收窄到地图大小（旧式无地图知识） |

**F2 的写法是有意的。** 把这个差异写成一条断言，比写在注释里更难被忽略；将来校验放宽时它会自然从「未来」变成「现状」，而不是悄悄改变别处行为。

## 3. 实际改动

`economy_runtime_family_buff.cpp` 的 OWN_TERRITORY 分支：

```cpp
// 迁移前
const int32_t cap = param0 > 0
    ? std::min(param0, EffectRuntime::SELECTOR_MAX_CELLS)
    : EffectRuntime::SELECTOR_MAX_CELLS;

// 迁移后
const int32_t cap = resolve_selector_cell_cap(
    EffectRuntime::SELECTOR_OWN_TERRITORY,
    param0 > 0 ? param0 : EffectRuntime::SELECTOR_MAX_CELLS, cells);
```

`param0 == 0` 时仍显式传 `SELECTOR_MAX_CELLS`，**刻意保留旧的兜底语义**。若改成传 0，`resolve` 会返回整张地图的格数，那才是真正的行为扩大。这一步必须是内容改动批的一部分，不能顺手做。

## 4. 另外三处**有意不迁移**

| 位置 | 种类 | 为什么不改 |
|---|---|---|
| `:2430-2431` | `TAG_ANY_CELL`（13） | 上限未变（仍回落 32），迁移无收益 |
| `:2476-2478` | 径向/泛化种类 | 上限未变，且该处 `cap` 是**可达上限**语义（含 anchor），与几何值不等价 |
| `:2495` | `DISTANCE_N` 的 `max_depth` | 是**跳数**不是格数，语义不同 |

第 2 行值得展开：该处 `default_cap` 是 18，而 `selector_cell_ceiling(R1)` 是 6。**6 是正确的几何值（R1 不含源格只有 6 格），但 18 是「宽松但不绑定」的包络**——两者对最终结果等价，可一旦把 `param0 == 0` 的兜底从 18 换成 6，`cap` 这个变量本身的值就变了，而它同时被用作循环提前退出条件（`:2534`、`:2546`）。在没测过的情况下改它，是拿正确的动机做多余的冒险。

**所以：只改真正需要放宽的那一处，其余保持原样并写明理由。** 这不是遗漏，是范围控制。

## 5. 验证

| 项 | 值 |
|---|---|
| 构建 | `scons: done building targets.`，exit 0 |
| 上限测试 | **35 checks, 0 failures** |
| 回归 | **changed verdicts = 0**（15 fixture 逐项与 M0 基线一致） |
| 其它门禁 | materializer 65 / eligibility 56 / shard 56 / layer 51 / coverage 6-of-6 |
| 新 DLL | `1e7c41ea…` |

## 6. 局限

- **行为仍未改变。** 194/194 内容仍写 32，所以有效目标集仍是 32 格。本轮只是把代码侧准备好。
- 未迁移三处调用点（§4），它们仍用 `SELECTOR_MAX_CELLS`。
- 两层校验仍未放宽，所以内容参数仍不能写 >32。
- `resolve_selector_cell_cap` 对无上限种类依赖调用方传 `cells`；若某个调用点传 0 会得到 0（测试 C 覆盖了这一点，但生产调用点只有一处，未逐一核对）。
- 未测放宽后 `effect_stable_cap` 的分布行为。

## 7. 复算方式

```powershell
cd gdext
$vcvars = 'C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat'
cmd /c "call `"$vcvars`" >nul 2>&1 && cl /std:c++17 /O2 /EHsc /W4 /I src tests\selector_cell_cap_test.cpp /Fe:..\.codex-tmp\ceiling_test.exe /Fo:..\.codex-tmp\"
& ..\.codex-tmp\ceiling_test.exe    # => 35 checks, 0 failures
```
