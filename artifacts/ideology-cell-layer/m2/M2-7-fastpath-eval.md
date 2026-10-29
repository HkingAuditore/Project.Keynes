# M2-7 fast-path evaluation — findings

| 项目 | 内容 |
|---|---|
| 里程碑 | [M2](../22-cell-program-cap-removal-plan-v3.md) §14.1 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 交付 | `gdext/tests/cell_factor_fastpath_bench.cpp`（测量，**未改产品代码**） |
| 结论 | 快路径**正确但收益有限**：1.38x–1.89x，大地图最差。**不建议现在实施** |

## 1. 想解决什么

M2-6 算出全国单程序 38.4 ms。读者结构是：

```cpp
// 一次性：156 次查询，取 GLOBAL + ENTITY（group 用不可匹配的句柄）
const auto shared_factor = [&](int32_t stat_id) { ... };
// 逐格：covered_cells × 156 次
const auto cell_factor = [&](int32_t stat_id, uint64_t scope) { ... };
```

每次 `effective_value` 做 3 次哈希查找（GLOBAL / GROUP / ENTITY）。对**派生专用格**：
- GLOBAL、ENTITY 与 shared 那一遍**完全相同**（不依赖格）；
- GROUP 桶不存在（派生行在前端结构里，不在 store 里）；
- 只有派生槽逐格不同。

所以直觉上可以「共享行解析一次 + 每格只折派生槽」，省掉 2/3 的查找。

## 2. 实测结果

| 场景 | 现状 ms | 快路径 ms | 加速 | 结果一致 |
|---|---:|---:|---:|---|
| 32 格 × 156 stat | 0.098 | 0.052 | **1.89x** | 是 |
| 900 格 × 156 stat | 4.289 | 2.485 | 1.73x | 是 |
| 6400 格 × 156 stat | 48.906 | 35.518 | **1.38x** | 是 |

**「结果一致」是逐样本比对的 double 相等**，不是抽样。快路径在算术上确实等价（严格符合 §5.1：先加后乘，零因子吞没）。

但收益随规模**下降**：小世界 1.89x，全国 1.38x。

## 3. 为什么大地图收益最小

省掉的是 2 次哈希查找，剩下的是：

```
front.row_for_stat(sid)  → 在 156 个 stat 上二分 ≈ 7-8 次比较
row->find(cell)          → 在 6400 个格上二分   ≈ 13 次比较
```

**约 21 次比较，与是否用快路径无关。** 规模越大，这部分占比越高，所以加速比越低。

## 4. 判断：现在不做

三个理由：

1. **收益不足以改变结论。** 全国场景 38.4 ms → 约 27.8 ms，仍是 28 倍于 §14.3 的 1 ms 单 slice 目标——分片无论如何都是必需的，快路径只是把 slice 数从 100 降到约 72，**不改变设计**。

2. **它触碰的是正确性最敏感的那段代码。** §5.1 的合并顺序（先 add 后 factor、零因子吞没、单次 clamp）是整个迁移反复强调的不变量。为一个 1.38x 的收益去改写热路径，风险与回报不成比例。

3. **当前 rollout 是 `Off`。** 这个成本**还没有在生产生效**。为一个尚未上线的路径做激进优化，等于在没有真实反馈的情况下改核心代码。

## 5. 更值得做的两件事

按收益排序，都比快路径更值得：

| 优先级 | 事项 | 理由 |
|---|---|---|
| 1 | **真实 in-situ 测量** | 38.4 ms 是 O2 微基准外推，生产运行时含 cache miss / 锁 / 校验，可能差一个量级。没有这个数字，所有优化决策都建在沙上 |
| 2 | **per-stat CSR 或按格索引** | 若将来确实要压这 21 次比较，需要把 `DerivedCellFront` 改成按格可查，那是**结构改动**，不是局部优化 |

## 6. 顺带确认的一件事

`collect_scope_ids` 的派生并集（M1-4）确实会让派生格进入工作集：

```cpp
// modifier_runtime.cpp:1506-1517
// Without this, a cell that ONLY has a derived contribution is invisible to the
// caller ... The layer would look installed and change nothing.
```

这验证了 M1-4 的设计意图仍然成立，也确认 38.4 ms 的估算前提（`covered_cells` 含派生格）是对的。

## 7. 局限

- 基准用的是**复刻**的 `effective_value`（内联展开），不是真实运行时。它包含的校验逻辑比真实版本少。
- 只测了派生专用格（无 GROUP 桶）。混合场景（部分格既有实例桶又有派生行）未测。
- 未测 cache 行为。6400 格的 front 约 1.5 MB，超出 L2，真实运行时的 miss 率会明显更高。
- 「结果一致」只覆盖本基准构造的数据分布，未覆盖零因子、负值、极端 magnitude。

## 8. 复算方式

```powershell
cd gdext
$vcvars = 'C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat'
cmd /c "call `"$vcvars`" >nul 2>&1 && cl /std:c++17 /O2 /EHsc /W4 /I src tests\cell_factor_fastpath_bench.cpp /Fe:..\.codex-tmp\fastpath.exe /Fo:..\.codex-tmp\"
cd ..
& .\.codex-tmp\fastpath.exe
```
