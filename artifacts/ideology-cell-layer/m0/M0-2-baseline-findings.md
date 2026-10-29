# M0-2 baseline & >32 truncation — findings

| 项目 | 内容 |
|---|---|
| 里程碑 | [M0](../22-cell-program-cap-removal-plan-v3.md) |
| 任务 | §15.2 M0 task 2 |
| 日期 | 2026-10-26，Asia/Hong_Kong |
| 机器 | 13th Gen Intel i9-13900K / 127.6 GB / Windows 11 专业版 |
| 工具 | `Project/project-keynes/tools/ideology/run_m0_baseline_tests.ps1` |
| 产物 | `baseline-logs/`（逐 fixture 日志 + `baseline_summary.csv`） |

## 1. 代码与二进制身份

| 项 | 值 |
|---|---|
| HEAD | `f52c5b9a7f59d9dc39f0ef266a3654ad32d9c446` |
| branch | `master` |
| 工作区未提交变更 | **319 项** |
| Godot | `4.6.2.stable.official.71f334935` |
| Godot 可执行文件 | `D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64.exe`（172,388,360 B） |
| Python | 3.13.3 |
| 扩展 DLL | `dots_ext_annual_v1.windows.template_debug.x86_64.dll` |
| DLL SHA-256 | `1d0eba7ae4c4b2b0bf6094db4a865ee846bff5b0f6e1ff3901c8fbec56ddf559` |
| DLL 大小 | 14,013,952 B |
| DLL mtime (UTC) | 2026-10-26T06:18:19Z |

`.gdextension` 的 debug 库指向 `dots_ext_annual_v1.windows.template_debug.x86_64.dll`，与实际存在的最新构建一致。

**注意：本里程碑没有重新编译 DLL。** 上述 hash 是既存工作区产物的身份；任何后续性能或行为结论都必须重新记录 DLL hash，并且**不能**假设它与本次相同。

## 2. 测试基线（首次实测）

§13.5 指定的 15 个 fixture，最终一次完整运行结果（`baseline-logs-final/baseline_summary.csv`）：

| fixture | 状态 | checks | failures | 秒 |
|---|---|---:|---:|---:|
| ideology_runtime_test | **pass** | 82 | 0 | 16.8 |
| ideology_opinion_synergy_test | **pass** | 24 | 0 | 12.3 |
| ideology_content_test | failures | 70 | **3** | 14.9 |
| ideology_effect_instance_test | **pass** | 51 | 0 | 12.0 |
| ideology_effect_override_test | **pass** | 25 | 0 | 13.7 |
| ideology_instance_budget_test | failures | 14 | **10** | 6.6 |
| ideology_mechanism_matrix_test | failures | 1129 | **3** | 13.7 |
| ideology_x1b_source_count_test | **pass** | 142 | 0 | 91.1 |
| ideology_cell_card_worker_test | no_summary | 0 | 0 | 43.2 |
| ideology_school_strength_worker_test | **timeout** | 0 | 0 | 305.1 |
| ideology_tag_snapshot_stress_test | **pass** | 37 | 0 | 150.3 |
| runtime_ideology_save_roundtrip_test | **pass** | 24 | 0 | 14.9 |
| runtime_ideology_parity_test | failures | 15 | **3** | 26.0 |
| runtime_modifier_pod_test | **pass** | 13 | 0 | 7.2 |
| runtime_worker_source_scan_test | **pass** | 1 | 0 | 5.2 |

**9 pass / 4 failures / 1 no_summary / 1 timeout = 15。**

### 2.1 既知失败签名（M0 交付物，按名比对）

```
ideology_content_test        70 checks,  3 failures
  [FAIL] collection rarity 1 loads its authored landscape frame
  [FAIL] collection rarity 2 loads its authored landscape frame
  [FAIL] collection rarity 3 loads its authored landscape frame

ideology_instance_budget_test 14 checks, 10 failures
  [FAIL] a wide catalog compiles (ideology_school_unknown:)
  [FAIL] a country-domain program compiles (ideology_school_unknown:)
  [FAIL] the rejection is the declaration budget, not concurrency (ideology_school_unknown:)
  [FAIL] the rejection names the concurrency budget (ideology_school_unknown:)
  [FAIL] the rejection carries the numbers and the slot decomposition (ideology_school_unknown:)
  [FAIL] a catalog exactly at the budget compiles
  [FAIL] a multi-level card compiles (ideology_school_unknown:)
  [FAIL] a capped program compiles (ideology_school_unknown:)
  [FAIL] a grown-capacity catalog compiles (ideology_school_unknown:)
  [FAIL] the rejection reports the grown slot count (ideology_school_unknown:)

ideology_mechanism_matrix_test 1129 checks, 3 failures
  [FAIL] cooperative L1/L2 gate cooperative share at 20%
  [FAIL] cooperative L3 lowers the share gate to 15%
  [FAIL] cooperative programs use agriculture tags

runtime_ideology_parity_test  15 checks,  3 failures
  [FAIL] every compared ideology day matched (matched=4 compared=12)
         (first_mismatch_day=3 field=points_balance)
  [FAIL] no ideology day was skipped for calendar misalignment (uncompared=2)
  [FAIL] a matched run has no first mismatch day

ideology_cell_card_worker_test   0 checks, no summary
  runs to day 30 then reports: [country][active] day=30 failed=country_worker_peer_results_pending

ideology_school_strength_worker_test  0 checks, TIMEOUT @305s (~0 CPU)
  GDScript backtrace: _drive_days (:446) -> _wait_ideology_ready (:125) -> _run (:70)
```

### 2.2 归因：这些失败与本方案无关

| fixture | 测试文件是否被工作区修改 | 根因 | 与 32 格限制的关系 |
|---|---|---|---|
| `ideology_instance_budget_test` | **未修改** | `ideology_catalog.gd:353` 拒绝空 `school_id`；该测试构造的定义没填 school | 无关 |
| `ideology_content_test` | 已修改 | 三档稀有度的 landscape frame 资源缺失 | 无关 |
| `ideology_mechanism_matrix_test` | **未修改** | cooperative 协同的 share gate 期望值不符 | 无关（是协同规则，不是覆盖范围） |
| `runtime_ideology_parity_test` | **未修改** | 主线程与 worker 的 `points_balance` 在第 3 天起分叉，且两者 catalog hash 不同（`8451053719376848311` vs `-7597083906950457924`） | 无关（是既有 parity 缺陷） |
| `ideology_cell_card_worker_test` | **未修改** | 需 `CELL_ONLY_CARD`；设置后仍卡在 day 30 的 `country_worker_peer_results_pending` | 无关 |
| `ideology_school_strength_worker_test` | **未修改** | 挂起于 `_wait_ideology_ready` | 无关 |

**`runtime_ideology_parity_test` 的失败值得单独注意**。失败转储显示主线程与 worker 在 `points_balance` 上从第 3 天起分叉：

```
matched=4 compared=12
reference_points_q16=0     worker_points_q16=91804
reference_revision=3       worker_revision=7
reference_published_day=17 worker_committed_day=3 / worker_round_day=-1
```

转储里 `reference_catalog_hash=8451053719376848311` 与 `worker_catalog_hash=-7597083906950457924` **不一致**，但要注意：这两个字段只出现在**诊断转储**里，测试本身**没有断言它们相等**（`grep catalog_hash` 在 `runtime_ideology_parity_test.gd` 零命中）。所以它不是失败的直接原因。

真正的信号是 `worker_round_day=-1` 与 `reference_published_day=17` 的落差，以及 `uncompared=2`——**两个权威跑在不同的日历上，有 2 天根本没比**。这在 M2 会直接冲突：方案 I10 要求「主线程与 worker 在相同业务输入下产生相同贡献」，而当前 parity harness 本身就存在日历错位。M2 必须先解决这个错位，否则任何 parity 断言都无法隔离派生层的贡献。

**这印证了我在评估阶段 G6 的判断，且比预想严重**：不能只跑 HEAD 做基线，当前工作区**本身**就有 4 个失败 fixture + 1 个 no_summary + 1 个 timeout。§13.5 现在有了具体内容。

## 3. >32 截断的实锤

**已在既有测试中用第一手执行证据确认。**

`tests/ideology/ideology_x1b_source_count_test.gd:287-310` 的 T8：

```gdscript
## T8: 72 cells alternate source/target, so 36 targets are found but only 32 may
## be retained.
func _test_stable_truncation(tag_id: int) -> void:
    ...
    _expect("T8 truncation keeps the 32-cell ceiling", first_targets.size() == 32, ...)
    _expect("T8 report records truncation", int(report.get("selector_truncations", 0)) > 0, ...)
    _expect("T8 matched_total records the pre-cap set",
        int(report.get("selector_matched_total", 0)) > 32, ...)
```

本次实测该 fixture：**142 checks, 0 failures** —— 即「36 个目标被截到 32 个」「truncation 计数 > 0」「matched_total > 32」三条断言在当前构建上成立。

这满足 §15.2 M0 task 2「确认旧路径 >32 截断实际发生」，并且**不是我构造的新证据，而是既有测试的既有断言**，所以不受「测试自证」质疑。

补充：报告字段 `selector_truncations` 与 `selector_matched_total` **已经存在**，方案 §12.4 要求的诊断计数器里这两项无需新增。

## 4. 与方案 §14.3 历史门槛的关系

方案列了三条「已有历史目标，尚未由本文实测」：

- 64 国理念 p95 ≤ 0.35 ms
- 512 国续跑 p95 ≤ 0.42 ms
- 6400 格 class-opinion 中位数 < 1 ms

本里程碑**没有测量任何一条**。上面所有时间（如 `ideology_x1b_source_count_test` 的 74.7 s）是**测试墙钟**，包含 Godot 启动、fixture 构建、断言开销，与 §14.3 的指标不同量纲，不可引用为性能数据。

## 5. 对 M0-7 / M1 的输入

1. **回归基线已建立**：`baseline_summary.csv` 是 M2/M5 逐名比对的依据。每个里程碑结束时重跑同一脚本即可得到可比结果。
2. **3 个既存失败需要在 M1 之前决定归属**：是列为「本方案不修」的已知债务，还是顺带修掉。我倾向列债务——`ideology_school_unknown` 是测试构造问题，与 cell-layer 无关，混进来会让 M5 的证据链变浑。
3. **DLL 未重编译**：M1 的第一批 C++ 改动必须记录新 hash，并与本表的 `1d0eba7a...` 对照说明「改动前后 DLL 必然不同」（§14.4 明确允许且要求如此）。

## 6. 复算方式

```powershell
# 全量
powershell -NoProfile -ExecutionPolicy Bypass `
  -File Project/project-keynes/tools/ideology/run_m0_baseline_tests.ps1

# 单个
... -Only ideology_runtime_test
```

脚本退出码：全部 pass 时为 0，任一非 pass 时为 1，并把非 pass 清单打到 stdout。

## 7. 局限

- **未在 HEAD 上重跑**。§13.5 的「HEAD vs 工作区各跑一遍」尚未完成：当前只测了工作区。要做必须在另一个 worktree 上跑（不能 stash 319 项变更），这需要用户决定是否值得。
- `ideology_content_test` 的 3 个失败与 `mechanism_matrix` 的 3 个失败**未逐个归因**，只确认了它们不是本次引入的。
- 未记录 `runtime_worker_source_scan_test` 等 6 个 fixture 的单条结果（以 CSV 为准）。
- 未测量任何内存峰值。
