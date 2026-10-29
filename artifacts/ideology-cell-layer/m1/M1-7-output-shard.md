# M1-7 output reader sharding — findings

| 项目 | 内容 |
|---|---|
| 里程碑 | [M1](../22-cell-program-cap-removal-plan-v3.md) §14.3 / §15.3 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 交付 | `refresh_city_output_modifier_factors` 独立分片、双游标、`_city_output_shard_partial`、状态机测试扩展 |
| 证据 | 状态机 **56 checks 0 failures**；构建成功；回归见 §5 |
| 结论 | 两个读者现在各有独立游标；上一轮的时序副作用已消除 |

## 1. 修的是什么

M1-6 把 city 因子读者分片后，调用点写成了：

```cpp
const bool city_factors_done = refresh_city_modifier_factors();
if (city_factors_done) {
    refresh_city_output_modifier_factors();   // ← 只在最后一片才跑
}
```

后果：若 city 因子跨 3 片，**output 因子在第 2 片完全不更新**。生产因子在中间几片读到旧值，而这类不一致不会报错——读到的数字看起来始终合理。

这正是方案反复警告的失效形态：数值「看起来对」，但基于过期输入。

## 2. 修法：两个独立游标，而不是链式等待

```cpp
const bool city_factors_done = refresh_city_modifier_factors();
const bool output_factors_done = refresh_city_output_modifier_factors();
if (!city_factors_done || !output_factors_done) { /* park */ }
```

两个读者各自按 `CITY_FACTOR_SHARD_CELLS = 64` 推进，互不阻塞。总工作量不变，只是不再互相等待。

## 3. output 读者的分片比 city 读者难在哪

164 行的函数里只有一段能分片：

| 段 | 行数 | 可分片 |
|---|---:|---|
| `collect_scope_stat_entries`（枚举） | 5 | 否（O(1) 次调用） |
| **per-cell 查询循环** | **18** | **是** |
| 旧平面合并（`_ideology_cell_programs`） | ~65 | 否（整体语义） |
| 排序 + CSR 重建 | 15 | 否（必须一次性） |

所以 per-cell 循环可以停在任意格，但**它产生的 `overrides` 必须跨片保留**——否则每片都从空开始，最后一无所得。

新增成员 `_city_output_shard_partial`（`std::vector<CityOutputOverrideRow>`）承载这个中间结果，在最后一片转成 `overrides` 再走排序与 CSR 重建。

**同一处还有一个必须配套的细节：版本门。**

```cpp
if (_city_output_shard_cursor < 0 && _epoch_city_output_factor_valid && ...)
    return true;
```

`_city_output_shard_cursor < 0` 这个前置条件不能少。上一轮在 city 读者上踩过同一个坑：部分绘制后 `_epoch_city_output_factor_valid` 仍是旧值、版本也没变，版本门直接早退，**未完成的分片永远停住**，只有前几片被应用。

## 4. 状态机测试扩展（56 checks）

新增两组：

| 用例 | 断言 |
|---|---|
| `test_independent_cursors` | output 读者在自己的**第一片**就完成，不等 city 的四片；两者游标独立归位 |
| `test_one_reader_empty_other_busy` | city 工作集为空时立即完成，而 output 有三个分片时仍按片推进 |

第一条正是本 bug 的回归测试。若将来有人把两个读者重新串成链式，这条会失败。

## 5. 构建与回归

| 项 | 值 |
|---|---|
| 构建 | `scons: done building targets.`，exit 0 |
| 状态机 | 56 checks, 0 failures |
| 回归 | 见 `artifacts/ideology-cell-layer/m1/regression-output-shard/baseline_summary.csv` |

## 6. 局限

- **仍未做端到端验证。** 与 M1-6 同一个原因：集成夹具卡在 `needs_environment_capture`（`capture ok=false, reason=""`），真实 epoch 路径在裸 `SceneTree` 里走不通。所以「真实 epoch 打开时两个读者确实各自按 64 格 yield」尚未观测到，正确性仍来自状态机测试。
- **`_city_output_shard_partial` 是一份额外的暂存拷贝**，规模等于 `overrides` 的大小。大图上这是几千行 × 12 字节，可接受，但未测峰值内存。
- **`refresh_city_output_modifier_factors` 的旧平面合并段（~65 行）仍未分片。** 当 `_ideology_cell_programs` 非空时它是一次 O(国家 × 格子 × 条目) 的遍历，且 `_ideology_cell_plane_enabled` 默认关闭（`world_ext.h:3307`），所以当前不触发。但 M5 删除旧平面时必须连带处理这段，否则会出现一个新的未分片热点。
- 未测分片对 output 因子缓存失效的影响。

## 7. 复算方式

```powershell
cd gdext
$vcvars = 'C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat'
cmd /c "call `"$vcvars`" >nul 2>&1 && cl /std:c++17 /O2 /EHsc /W4 /I src tests\city_factor_shard_test.cpp /Fe:..\.codex-tmp\shard_test.exe /Fo:..\.codex-tmp\"
& ..\.codex-tmp\shard_test.exe    # => 56 checks, 0 failures
```
