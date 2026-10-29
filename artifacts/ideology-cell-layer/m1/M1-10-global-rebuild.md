# M1-10 global rebuild & multi-country correctness — findings

| 项目 | 内容 |
|---|---|
| 里程碑 | [M1](../22-cell-program-cap-removal-plan-v3.md) §4.2 / §8.1 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 交付 | `rebuild_derived_cell_layer()`、`run_daily` 挂点、移除 per-country 物化、三条多国测试 |
| 证据 | 物化器 **65 checks 0 failures**（新增 12 条）；回归见 §6 |
| 结论 | **修复了一个会静默丢失整国贡献的正确性缺陷** |

## 1. 上轮留下的缺陷：最后一国抹掉所有其他国家

M1-9 把物化放在 `reconcile_effect_activations` 里：

```cpp
// 上轮（错误）
std::vector<DerivedProgramContribution> derived;
collect_effect_activations(country, state, desired, &derived);
build_derived_cell_front(derived, ...);      // 只用这一个国家的数据
install_derived_cell_layer(std::move(front));
```

而 `reconcile_effect_activations` 在**四个调用点**被按 `(country, idea)` 逐次调用（`ideology_runtime.cpp:3151 / 3199 / 3412 / 3502`）。

后果：**最后一个 reconcile 的国家会把 front 整体替换成只有它自己贡献的版本**，其他国家的地块效果全部消失。

这是本迁移最危险的一类缺陷：

- 不报错、不崩溃；
- 单国测试完全正常；
- 只有两国以上同时持有派生卡时才显现，而那时表现为「某些国家的地块效果时有时无」。

## 2. 修法：全局操作要有全局入口

派生 front 是按 `(stat, cell)` 索引的**单一共享对象**，所以它的构造天然是全局操作。移出 per-country 路径，改为：

```cpp
bool NativeIdeologyRuntime::rebuild_derived_cell_layer(int64_t day, std::string &error) {
    std::vector<DerivedProgramContribution> derived;
    for (const CountryState &country : _countries)          // 所有国家
        for (const IdeaState &state : country.ideas)
            collect_effect_activations(country, state, throwaway, &derived);
    build_derived_cell_front(derived, ...);                  // 一份 front
    install_derived_cell_layer(std::move(front), ...);
}
```

挂在 `run_daily`（在 `run_daily_slices` 之后），每天一次，而不是每张卡一次。

**为什么挂在 `run_daily` 而不是 `run_daily_slices`：** 切片是分国家推进的，切到一半时其他国家这一天的状态还没定稿，此时物化会得到一份「半天的世界」。整日结束后物化，输入才是完整的。

## 3. 测试（新增 12 条，共 65）

| 断言 | 内容 |
|---|---|
| **J** | 两国各占不同格时，**两国的格同时存在**（6 行） |
| **J2** | 只传一国贡献时，另一国的格**确实消失**——证明 builder 是输入的纯函数，因此调用方**必须**传全部国家 |
| **J3** | 两国影响同一格时**相乘**（2×3=6），不是相加 |

**J2 的写法值得说明。** 它断言的是缺陷本身。常理下不该为错误行为写测试，但这里的价值在于：它把「builder 是纯函数」这件事固定下来。将来若有人再次在 per-country 路径上调它，J2 会提醒「这样会丢数据」，而不是让缺陷重新悄悄出现。

## 4. `_execution_contract_hash` 与身份字段

`rebuild_derived_cell_layer` 使用三个新成员：

| 成员 | 用途 |
|---|---|
| `_derived_world_identity` | 世界身份，供 §9.6 拒绝陈旧候选 |
| `_derived_map_generation` | 地图代次 |
| `_derived_epoch_id` | epoch 身份 |

`_execution_contract_hash`（§11.5）也进 front 身份。

## 5. 构建

| 项 | 值 |
|---|---|
| 构建 | `scons: done building targets.`，exit 0 |
| 物化器 | 65 checks, 0 failures |
| 判定器 | 56 checks, 0 failures |
| 分片 | 56 checks, 0 failures |
| 派生层 | 51 checks, 0 failures |

## 6. 回归

见 `artifacts/ideology-cell-layer/m1/regression-global/baseline_summary.csv`。

因 `kCellProgramRollout = Off`，`rebuild_derived_cell_layer` 遍历后得到空贡献集，物化器返回空 front，`install_derived_cell_layer` 不接受空内容安装——所以生产行为应与 M0 逐位一致。

## 7. 局限

- **`rollout = Off` 仍意味着运行时未取消 32 格限制。** 本轮的修复让「一旦 ON 就是正确的」，但 ON 本身尚未发生。
- **每国遍历 `_countries × state.ideas` 是 O(卡数)**，每天一次。大国多卡时这笔开销未测。
- **逐来源国撤销仍未实现。** front 里 `source_country` 被折成 0，两国影响同一格时算术正确（相乘）但无法单独撤掉其中一国——只能整份重建。整份重建正是当前做法，所以**行为正确**，只是代价是 O(全部卡) 而非 O(改动卡)。这属于性能而非正确性问题，M2 再优化。
- **`collect_effect_activations` 被调用两次**（reconcile 一次建实例，rebuild 一次收派生），做了一份丢弃的 `throwaway`。重复计算未测。
- 未测 `rebuild_derived_cell_layer` 在 `_countries` 很大时的耗时。

## 8. 复算方式

```powershell
cd gdext
$vcvars = 'C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat'
cmd /c "call `"$vcvars`" >nul 2>&1 && cl /std:c++17 /O2 /EHsc /W4 /I src tests\derived_cell_materializer_test.cpp src\derived_cell_materializer.cpp /Fe:..\.codex-tmp\materializer_test.exe /Fo:..\.codex-tmp\"
& ..\.codex-tmp\materializer_test.exe    # => 65 checks, 0 failures
```
