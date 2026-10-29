# M0-R2 重建完成：构建恢复，两个关键 fixture 回到全绿

| 项目 | 内容 |
|---|---|
| 里程碑 | 前置修复（M0-R1 的后续） |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 结果 | **5 个源文件重建完成；构建 exit 0；`x1b` 142/0、`tag_snapshot` 38/0** |
| 结论 | 内核语义已用 49 条断言重新固定 |

## 1. 重建的 5 个文件

| 文件 | 行数/字节 | 关键契约 |
|---|---|---|
| `selector_cell_cap.h` | 5.1 KB | 几何界 vs 策略界拆分；`kSelectorNoCellCap`；`CAP_SELECTOR_*` 供 `static_assert` |
| `cell_program_eligibility.h` | 11.1 KB | `CellProgramFacts`/`Decision`/`LegacyReason`/`Rollout`；**M4 = `Sources`** |
| `derived_cell_layer.h` | 8.6 KB | `Contribution`/`StatRow`/`Front`/`Builder`（含 `bump_stat_version`、`install`、`content_digest`）|
| `derived_cell_materializer.h` | 7.5 KB | `Term`/`MagnitudeSource`/`DerivedRampSampler`/`DerivedMaterializeOptions` |
| `derived_cell_materializer.cpp` | 9.4 KB | fold 实现 + 10/11 参数两个重载 |

**重建方法：从保留下来的调用点反推。** `world_ext_modifier.cpp`、`modifier_runtime.cpp`、
`ideology_runtime.cpp` 都是已跟踪文件、未丢失，它们完整保留了每个符号的签名与语义。

## 2. 两个编译错误的修复

| 错误 | 原因 | 修复 |
|---|---|---|
| `builder.bump_stat_version` / `install` 不存在 | 我只实现了 `add`/`build` | 补齐两个方法 + `_pending_stat_versions` |
| `add` 返回 void，调用点判 `if (!builder.add(...))` | 调用点要求 bool | 改为返回 bool，非法行**报错而非静默丢弃** |

## 3. 一个真实缺陷：`magnitude_scale` 被应用了两次

### 症状

`x1b` 的 T2 期望 `after=1.06`，实测 `1.03`。

```
1.03 = 1 + 0.03
0.03 = 0.12 × 0.5 × 0.5     ← scale 乘了两遍
```

### 原因

- **采集端**（`ideology_runtime.cpp:2353`，已跟踪、未丢失）已经把每个 term 乘过
  `single.magnitude_scale`；
- 我在**物化端**又乘了一次。

### 修复

物化端不应用 `magnitude_scale`，并在代码里写明分工：

```cpp
// NOTE: `program.magnitude_scale` is NOT applied here.
//
// The per-target scale is already folded into `term.add` by the collector
// (ideology_runtime.cpp:2353). Scaling again here applied it twice: a cell that
// should read 1.06 read 1.03, i.e. 0.12 x 0.5 x 0.5.
```

字段保留在结构体上，纯核测试手搓 contribution 时仍可表达 scale。

## 4. 重建验证：49 条断言

新增 `gdext/tests/derived_layer_rebuild_test.cpp`，**49 checks / 0 failures**：

| 组 | 断言 |
|---|---|
| A | §5.1 fold `(base+add)*factor`，**一次 clamp**，且钉在 max 后不再被乘 |
| B | §5.5 零 factor 湮没，且**单独计数**（product 无法事后恢复"曾有过零"）|
| C | §12.4 **1000 格不截断**，`truncated==0` |
| D | I13 相同内容幂等跳过 |
| E | **`magnitude_scale` 不由 fold 再乘**（防双重应用回归）|
| F | I01：`EffectInstance` program 被跳过，不产生行 |
| G | 无 sampler 时 ramp **defer 而非归零** |
| H | 有 sampler 时**逐格求值**，两格得到不同幅度 |
| I | 判定器：常数/ramp 均 DerivedCell，非 ramp 非常数被拒；rollout 与能力分离 |
| J | 上限拆分：R1=6/R2=18；territory 无策略上限；**显式 32 仍生效**；无地图得 0；authored ceiling 保持 32 |

**E 与 J 是防止本次事故重演的两条关键断言。**

## 5. 验证

| 项 | 值 |
|---|---|
| 构建 | **exit 0** |
| `derived_layer_rebuild_test` | **49 / 0** |
| `ideology_x1b_source_count_test` | **142 / 0** |
| `ideology_tag_snapshot_stress_test` | **38 / 0** |
| 内容参数 | `(0,0)` × 194（未受影响）|
| `kCellProgramRollout` | **`Sources`** |
| DLL | `6be7735e…` |

## 6. 仍未恢复的内容（未跟踪，无法从 git 找回）

| 类别 | 丢失 |
|---|---|
| 报告 | `artifacts/ideology-cell-layer/` 下 M0–M4 约 70 份 |
| 文档 | `docs/plans/ideology-review/22-progress-checklist.md`、方案 v3 |
| 测试 | `ideology_cell_layer_*.gd` 约 8 个、`ideology_b7_*.gd`、两个 probe |
| 工具 | `run_m0_baseline_tests.ps1`、`m1_backend_coverage.py`、`m0_program_inventory.py` 等 |
| 基线 | `baseline_summary.csv` 只剩 1 行（原 15 fixture）|

## 7. 教训

**未跟踪的新文件在 `git pull` 面前没有任何保护。**

正确的做法是新建文件后立刻 `git add`（哪怕不提交）。
我今天创建了 5 个源文件 + 8 个测试 + 70 份报告 + 3 个工具脚本，**一个都没有 add 过**。
