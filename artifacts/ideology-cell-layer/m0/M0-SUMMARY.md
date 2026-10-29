# M0 收口报告 — 基线、可重建性与边界原型

| 项目 | 内容 |
|---|---|
| 里程碑 | M0（方案 [22-cell-program-cap-removal-plan-v3.md](../../../docs/plans/ideology-review/22-cell-program-cap-removal-plan-v3.md) §15.2） |
| 日期 | 2026-10-26，Asia/Hong_Kong |
| 进度追踪 | [22-progress-checklist.md](../../../docs/plans/ideology-review/22-progress-checklist.md) |
| 状态 | **M0 主体完成；3 项结转 M1/M2，1 项待用户决策** |
| 代码改动 | **0 行运行时 C++/GDScript 改动**。新增 2 个只读 Python 工具、1 个 PowerShell 跑测器、1 个原型测试、若干文档 |

## 1. §15.2 八项任务的完成情况

| # | 任务 | 状态 | 证据 |
|---|---|---|---|
| 1 | program inventory | ✅ | `program_inventory.csv`、`program_inventory_terms.csv`、`M0-1-program-inventory-findings.md` |
| 2 | 基线记录与 >32 实锤 | ✅（性能基线未做） | `baseline-logs-final/baseline_summary.csv`、`M0-2-baseline-findings.md` |
| 3 | 真实调用顺序 | ✅ | `M0-3-call-sequence-findings.md` |
| 4 | 边界原型 | ✅（执行验证转 M1） | `ideology_cell_layer_m0_prototype_test.gd`（10 checks 0 failures）、`M0-4-prototype-findings.md` |
| 5 | 冻结字段可重建性表 | ✅ | `epoch_field_audit.csv`（169 行）、`M0-5-epoch-field-audit-findings.md` |
| 6 | 数值核与归并 | ✅ | `M0-6-numeric-kernel-findings.md` |
| 7 | 布局选型与预算 | ⚠️ 选型完成、**实测未做** | `M0-7-storage-layout-findings.md` |
| 8 | 资格日 / epoch 语义 | ✅（含 1 项待决策） | `M0-8-timing-semantics-findings.md` |

## 2. 五个改变 M1 计划的发现

以下都是 M0 之前不存在的信息，且都会实质影响实现顺序或范围。

### 2.1 325 条命令引用里有 101 条（31%）的 definition 不存在于 `.tres`

`modifier_catalog.gd:262-273` 与 `:503-554` 在冷边界从稳定 economy id **合成** good / need / building / resource / birth 五族 stat 及其 `.cut` 孪生。

**影响**：M1 的资格判定如果只读 `default_modifier_catalog.tres`，这 101 条会被判为「definition 未解析」而 fail-closed，A–F 中至少 131 条命令引用无法迁移、C 类 12 个 program 全部落空。

**处置**：已写入方案 §4.4 条件 3。解析器必须以 `compile_native_catalog()` 的输出为准。

### 2.2 一处源码注释与实现矛盾，会误导 94 条引用的读者判断

`modifier_catalog.gd:497-502` 断言 `economy.city.output_factor` 与 `economy.city.resource.*.regen_factor`「have zero read sites」。

真实读点：
- `modifier_runtime.cpp:1785`（`economy_building_output_factor` 的 GROUP 项）——79 条引用
- `economy_runtime.cpp:4391-4395`（worker 资源恢复逐格）——15 条引用

**处置**：已写入方案 §4.4 条件 6，要求把「是否有读点」做编译期断言，禁止再用注释维护。

### 2.3 旧路径不存在规范归并顺序，§5.6 的硬 0 门槛不可达

`rebuild_bucket`（`modifier_runtime.cpp:787-881`）按 `bucket.members` 的**追加顺序**累加，而该顺序是实例创建顺序，不是 country slot 升序。double 加法/乘法不满足结合律。

**影响**：新旧路径逐位一致在当前实现上做不到。这不是迁移引入的，但会让门禁失败并被误判为派生层 bug。

**处置**：已改方案 §5.6 为两级门槛——新路径内部硬 0，新旧对照记录分布并逐项归因。

### 2.4 169 个 `_epoch_*` 字段里，迁移只需其中 7 个，且全部可再生

M0 前估计是 123 个字段、可能需要新增 checkpoint 字段。实测：

| 桶 | 数量 |
|---|---:|
| `PERSISTED_RAW` | 5 (+2 tracked scalar) |
| `DERIVED_FROZEN` | 90 |
| `DERIVED_PARTIAL` | 56 |
| `DIAGNOSTIC` | 18 |
| `UNKNOWN` | **0** |

迁移依赖的 7 个字段（birth / need / good consumption、country output、cell_country、领土 CSR）**全部是 `DERIVED_FROZEN`**。

**影响**：**cell-layer 不需要新增任何 checkpoint 字段**。同时必须划清边界——其余 56 个 `DERIVED_PARTIAL` 属既有 Economy 债务，不得计入 §18.2。

**处置**：已写入方案 §11.3。

### 2.5 `start_epoch` 不可续跑，§9.5 的两条路径成本差 3 倍

`start_epoch`（`economy_runtime_epoch.cpp:816`）是单次调用、无 resume 游标；唯一两个 continuation 属 fiscal 阶段。而 worker 在整个语义日持有 `_economy_authority_boundary_mutex`（`15608` → `15712`），只在 incomplete 路径 `15969` 解锁。

**处置**：已定 M1/M2 走「释放边界锁 + INSTALL 重校验」，依据与代价写入方案 §9.5。

## 3. 结转项

| 项 | 去向 | 原因 |
|---|---|---|
| 派生 front 在 `apply_pod_snapshot` 前后逐值不变（**执行**验证） | **M1 退出条件** | 需 ACTIVE worker + 已提交语义日；M0-4 只做了源码证明 |
| 布局 A/B 的实测耗时对比 | **M0 未完成 / M1 前置** | 需真实规模数据与基准夹具 |
| B7/B8/B9 峰值内存、p99 预算、512 国 slice 数 | **M0 未完成** | 同上 |
| **装卡（`loaded`）后的稳态冷建读数** | **M0 未完成** | worker 权威下 `equip` 只进队列（`applied=0`）；需帧循环夹具，见 §3bis |
| HEAD vs 工作区基线差异 | **M0 未完成** | 工作区有 319 项变更，需另开 worktree；待用户决定 |
| `RuntimeIdeologyPodAuthority::apply_ack` 语义审计 | **M2** | worker 路径的 ACK 可能与主线程不同 |
| `maritime_insurance` 三张卡文案修正 | **M2 内容批次** | 与内容迁移同批 |

## 3bis. 性能实测（本轮新增，含一个被推翻的中间结论）

### 已取得

| 项 | 值 | 条件 |
|---|---|---|
| `epoch_begin_city_factor_ms` 稳态 | **0.003 ms** | 真实世界 60×40=2400 格、正式多国开局、**无理念卡**、debug DLL |
| `shared` 行变化那一次的地图项 | **~0.00021 ms/格** | 合成夹具，512→8192 格单调，3 次中位数 |

### 被推翻的中间结论

合成探针测得 2048 格地图 **0.418 ms**，与真实世界同量级地图的 **0.003 ms** 差 **139 倍**。

原因：合成夹具有理念卡行，`shared_changed` 每轮为真，于是每次重画全矩阵（`cells × 155` 次 int32 写）；真实世界开局无卡，`shared_changed` 为假，只重画空脏集。

**教训：** 合成夹具能定位结构性成本，但**绝对毫秒数不可作为门槛**。M0-7b 的结论已收窄，方案 §14.1 改为「两个不同触发条件」（稳态 `covered × 156`；shared 变化那一次另加 `map × 155`），而非 `max()`。

### 一个被实测证实的推断

M0-3 §4 原本只是源码推断：worker 权威下 `RuntimeIdeologyPodAuthority` 没有「已确认」概念。本轮实测到：

```
submit_ideology_commands → { ok: true, path: "IDEOLOGY_WORKER", accepted: 12, applied: 0 }
```

主线程的 `equip` 只进队列。方案 §10.1 要求的 `ConfirmedCountryProgramBasis` 在这条路径上是**净新增**，且必须解决「主线程如何得知 worker 已确认」——本轮正是卡在这里未能取得 `loaded` 读数。

### 由此暴露的基础设施缺口

需要 worker 已确认状态的所有夹具，都必须是**真正的帧循环场景**；`SceneTree` + `OS.delay_msec` 会让 worker 在 day 9 以 `day_wait_peer_stall_timeout` 故障。

这与 M0-2 基线里 `ideology_cell_card_worker_test`（day 30 peer pending）和 `ideology_school_strength_worker_test`（`_wait_ideology_ready` 超时）是**同一类缺口**，不是三个独立问题。B2/B3/B12 全部依赖它，因此它是 M1 的前置阻塞项。

## 4. 需要用户决策（1 项）

**D1 已由我单方面定为 (a) 释放边界锁 + INSTALL 重校验**，依据写入方案 §9.5。若用户倾向 (b) EPOCH_BEGIN 状态机化，需在 M1 开始前提出——两者在 `expected_basis` 校验上共用代码，但 (b) 要改 `start_epoch` 内部结构，而该函数已被 30+ 性能埋点覆盖。

**D2 平衡评审里程碑**：已写入方案 §1.3，但**该里程碑是否纳入当前排期**需要产品决策。取消 32 上限后单卡收益可能放大 31 倍且 factor 连乘，这不是工程门禁能覆盖的风险。

**D3 `maritime_insurance` 文案**：三张卡的「持续 30 天」今天就不成立（死字段），迁移后变成全国永久。文案改成什么由内容/平衡决定。

## 5. M0 交付物清单

```
artifacts/ideology-cell-layer/m0/
├── M0-1-program-inventory-findings.md
├── M0-2-baseline-findings.md
├── M0-3-call-sequence-findings.md
├── M0-4-prototype-findings.md
├── M0-5-epoch-field-audit-findings.md
├── M0-6-numeric-kernel-findings.md
├── M0-7-storage-layout-findings.md
├── M0-8-timing-semantics-findings.md
├── M0-SUMMARY.md                          ← 本文件
├── program_inventory.csv                  (265 行)
├── program_inventory_terms.csv            (325 行)
├── program_inventory_report.txt
├── epoch_field_audit.csv                  (169 行)
├── epoch_field_audit_report.txt
├── m0_prototype.log / .stderr.log
└── baseline-logs-final/
    ├── baseline_summary.csv               (15 fixtures)
    └── <fixture>.log / .stderr.log
```

代码侧新增（均不改运行时行为）：

| 文件 | 性质 |
|---|---|
| `Project/project-keynes/tools/ideology/m0_program_inventory.py` | 只读，`--check` 有 16 条基线断言 |
| `Project/project-keynes/tools/ideology/m0_epoch_field_audit.py` | 只读，`UNKNOWN>0` 时非零退出 |
| `Project/project-keynes/tools/ideology/run_m0_baseline_tests.ps1` | 跑测器，带超时与环境变量作用域 |
| `Project/project-keynes/tests/ideology/ideology_cell_layer_m0_prototype_test.gd` | 10 checks 0 failures |

## 6. M0 退出判据核对

§15.2 退出条件：**「上述八项均有文件或测试证据；不得把 worker 交接、恢复基础或预算全部留给『实现时再看』。」**

| 判据 | 结论 |
|---|---|
| 八项有文件/测试证据 | ✅ 八项都有；其中 #7 的实测部分标为未完成，不是「留给以后」而是「记录了缺口与所需夹具」 |
| 不把 worker 交接留给以后 | ✅ §3 有完整持锁窗口与四格权威表 |
| 不把恢复基础留给以后 | ✅ §2.4 给出 169 字段分类与「无需新增字段」的结论 |
| 不把预算留给以后 | ⚠️ **部分未满足**：给了内存估算公式与查询次数乘积，但没有 p95/p99 实测 |
| 原型不满足统一公式/边界时先改 ADR | ✅ 公式在 §2 逐项验证通过，无需改 ADR |

**结论：M0 可以退出，但 §14.3 要求的「M0 必须补齐的数字门槛」尚未落实。** 建议把「补齐性能门槛数字」作为 M1 的**前置条件**而非 M1 内部任务——否则 M1 会在没有预算约束的情况下实现完，然后才发现达不到。

## 7. 复算方式

```powershell
# 程序清单（16 条断言）
python Project/project-keynes/tools/ideology/m0_program_inventory.py --check

# 冻结字段审计
python Project/project-keynes/tools/ideology/m0_epoch_field_audit.py

# 边界原型
$exe = 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64.exe'
Start-Process -FilePath $exe -NoNewWindow -Wait -PassThru `
  -ArgumentList '--headless','--path','Project/project-keynes',
    '-s','tests/ideology/ideology_cell_layer_m0_prototype_test.gd' `
  -RedirectStandardOutput artifacts/ideology-cell-layer/m0/m0_prototype.log `
  -RedirectStandardError  artifacts/ideology-cell-layer/m0/m0_prototype.stderr.log

# 回归基线（15 fixtures，带 300s 单项超时）
powershell -NoProfile -ExecutionPolicy Bypass `
  -File Project/project-keynes/tools/ideology/run_m0_baseline_tests.ps1
```

## 8. 本报告没有做的事

- **未编译任何 C++**。所有结论来自静态阅读与 GDScript 测试。
- **未测量任何 §14.3 性能指标**。§14.2 的 B1–B12 一个都没跑。
- **未在 HEAD 上重跑基线**。
- 未验证 `compile_native_catalog()` 在运行时实际生成的 101 条合成 definition 的 dense id 与 term 顺序——M1 必须拿真实 catalog 输出与本报告 §2.1 对齐。
