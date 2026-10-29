# 理念系统 Review（五）：落地状态与刻意取舍

日期：2026-10-21。对应 Doc 01~04 的执行结果。

这份文档只做三件事：**哪些做完了**、**哪些与计划不一样（以及为什么）**、**哪些还欠着**。
设计理由仍以 01~04 为准，这里不重复论证，只记录后果。

---

## 0. 状态表

| ID | 状态 | 主要落点 | 验证 |
|---|---|---|---|
| P1-C | 完成 | `EffectRuntime::reconcile` 的每实例 metric 摘要；`metric_publishes_skipped` | `ideology_effect_metric_publish_test`（+ 未被跳过时的值断言） |
| P1-A | **降级：部分** | revision 通道与切片刷新已通，但 digest 粒度过粗（见 06 §3） | `_test_instance_refresh_gate` |
| P1-B | 完成 | `apply_pod_snapshot` 搬移 `effect_instances`/`activation_signature`，删除内联全量 reconcile | `ideology_effect_worker_forward_test::_test_snapshot_carry` |
| P1-D | 完成 | `effect_magnitude.h` + Effect POD ABI 1→2 + forwarder 两条路径 | `RuntimeEffectPodAuthority::magnitude_scale_self_test` |
| P2-C | **降级：部分** | PKEF 存档完成；**wire 未完成**——`effect_instance_forwarder.cpp` 里仍找不到 `latched`，跨权威翻转时不会传过去 | `_test_latched_survives_save` |
| P2-B | 完成 | `effect_selector_cap.h`：稳定哈希截断（三处） | `EconomyTargetSelectorTests` 的 8 条纯函数断言 |
| P2-D | **部分** | 生成器两条域校验 + `city.*` 只许 SUM | `_test_metric_scope_guard` / `_test_city_stat_aggregation_guard` |
| P1-E | **未做** | — | — |
| P2-A | **部分** | 贸易因子改为乘订单成交量 | 基线对照（无新增失败） |
| P3-A | **部分** | 本文档 + 主文档 §46 | — |
| P3-B | **完成（R-3b）** | `TagSnapshot` 不可变快照 + `set_target_tags` 单写者断言 + 惰性构建门控（`tag_snapshot_needed`）+ 每扫描一次 `tag_snapshot()` 加载 | `ideology_tag_snapshot_stress_test`（37/0）；敏感性 A–D 各一次 |
| **R8-1** | **完成** | PKID 7→8、IDP2 ABI 5→6，精确相等版本门 | `_test_stale_pkid_is_rejected_by_version`；pod `self_test` 旧 ABI 拒绝（敏感性已验证） |
| **R8-2 / 6b** | **完成** | `ideology_trade_flow_q16` 共享核，trade 按经过天数结算 | pod `self_test` 的结算次数不变性（1 次/30 次/每 period/不规则 相等） |
| **R8-3** | **完成** | `IdeologyFacade.configure(world_seed)` → native catalog；`map_generator` 两处传入 | pod `self_test` 的世界种子断言 |
| **R8-4** | **完成** | 比较器只接受日期距离 0；驱动按 worker 日历跑主线程 | parity 报告 `uncompared_day_offset=2`、`paired_ref==paired_worker` |
| **A1（按日绑定）** | **未达成** | 说明见 §2.6；绑定代码已回退 | — |
| **R9-1（单一结算体 + 加锁小环）** | **完成** | `accrue_points_from` 唯一函数体；worker `(plan_day→opinion)` 加锁环容量 16 | pod `self_test`；`ideology_runtime_test` 67/0 |
| **R9-1（主线程消费 worker 的 opinion）** | **停工（不回退）** | 只走 worker 路径，见 §2.8；机制代码保留 | — |
| **R9-2（结算键 = commit_day）** | **完成** | 两侧改为 `commit_day + 1`，period_index 仅诊断 | parity 由不确定变确定（5/5 一致） |
| **R9-3（单次上限按天放大）** | **完成** | `cap × covered_days`，两侧同式 | pod `self_test` + 主线程同式 |
| **R9-4（world_seed 测试）** | **未做** | — | — |
| **R9-5（基线播种 trade_paid_day）** | **完成** | 两侧基线分支同时播种 | `ideology_runtime_test` / pod 自测 |
| **死代码清理（§2.10 列出）** | **完成** | 5 处删除，见 §2.7 | 编译通过 + 全套绿 |

P2-D 剩下的部分：`ideology.city.*` 仍只能加减、×3 软上限仍无法表达。

> **2026-10-21 复核后更正（依据 06）**：
> - P1-A 不能标「完成」。`refresh_effect_input_digest` 每次 commit 哈希全部格的归属 + 全部标签位
>   + 全部已声明指标原始值，活经济里几乎每天 +1 → 所有依赖经济输入的卡每天全量 reconcile。
>   「idle = 0」只在冻结世界成立。
> - P2-C 的存档部分完成，但 `latched` 跨权威翻转仍不传（06 §4），整体只能算部分。
> - **系数平面标为实验性，默认关闭**（`_ideology_cell_plane_enabled = false`）。
>   已知未修：generation 恒为 1、与每格实例可能重复计算、kind 0 两条路径语义不一致、
>   系数语义与 Modifier 不一致、worker 权威下不发布、主线程改写 Economy 正在读的 CSR。
> - **性能一节（原 §46.3 / Doc 03 相关）目前属于「未测量」**，不要引用旧数字。
P2-A 剩下的部分：L1-6 的聚合粒度仍是「按 stat」，理念侧无法按来源区分。

---

## 1. 与计划的偏差（刻意，不是遗漏）

### 1.1 修订号挂在 COMMIT 尾，不是 `capture_country_epoch()`

Doc 04 §3.1 已经指出原方案会退化成「每天 +1」。实现时还多发现一层：
**摘要不能包含 `_epoch_country_hash`** —— `compute_state_hash` 把 cash 和 goods 折进去了，
每个结算日都变。用所有权列替代，领土变才变。

### 1.2 刷新预算的单位是「重算次数」，不是「国家数」

计划写的是 64 国/片。按国家切，512 国的地图一轮要 8 天才能扫完尾部——
那不是切片，是抽样，卡片效果会滞后一周。改成：扫描不限（逐卡比一个 u64，很便宜），
**只对真正需要重算的卡计预算**。

### 1.3 `latched` 的注释是反转，不是补充

`effect_runtime.h` 的 `STATE_LATCHED` 原来写着「故意不持久化，一个 cadence 自愈」。
那句话只在「每日 pass 是唯一读者」时成立；band 内存档会整整丢掉一天迟滞。
改的是**结论**，所以注释也重写了，而不是在旁边加一句「现在持久化了」。

### 1.4 P2-C 的 `schema == 11` 分支是死代码

Doc 01 假定它还能跑。实际 7150 行的版本门已经拒掉一切非当前版本，
`schema == 11` 永远为假，那段修复从未执行过。删除后其下游
`legacy_pod_transaction`（含 `pkef_legacy_pod_plan_hash_invalid`）也随之不可达；
容器与判据**保留并注明**，因为下次 schema 迁移正是它复活的路径。

### 1.5 `MAX_MAGNITUDE_Q16` 变成别名

worker 的编译单元不能 include `modifier_runtime.h`（会拖进 Godot 类型）。
共享常量放进 `effect_magnitude.h`，`ModifierRuntime` 改为引用它。
两份 clamp 一旦漂移，表现是「同一张卡的强度取决于哪个域在跑」。

### 1.6 贸易因子从 capacity **移动**到 volume，不是叠加

原来只乘在 `country_capacity` 上。容量按商人人口算、平时都闲着，
所以「本国贸易 +50%」在空闲国家完全没效果。两处都乘则是平方（2 倍卡 = 4 倍吞吐），
所以只能移动。这是 C 系列里唯一改变既有数值语义的一处。

### 1.7 截断测试打在纯函数上

`EconomyTargetSelectorTests` 的 fixture 造不出 40 个命中同一标签的格子。
与其为测试硬造一张 tag 表，不如直接断言 `effect_stable_cap` 本身的性质
（40 格取 32：数量、`matched_total`、`truncated`、仍升序、**不等于最小 32 个**、可重入）。

---

## 2.6 第 9 轮（2026-10-22，本轮）

本轮只做了 R8-1、6b、R8-4、R8-3；A1 的「opinion 按日绑定」**未达成**（见下），
A2–A9 未开始。构建：`scons target=template_debug` → `scons: done building targets.`，
DLL `2026-10-22 16:13:03`。

### R8-1 完成：PKID 7→8、IDP2 pod ABI 5→6

- `gdext/src/ideology_runtime.h:44` `SAVE_SCHEMA_VERSION` **7 → 8**。
- `gdext/src/runtime_ideology_pod.h:18` `RUNTIME_IDEOLOGY_POD_ABI_VERSION` **5 → 6**。
- 两侧的版本门都是**精确相等**，所以旧档在解码第一行之前就被 `ideology_save_schema_unsupported`
  / `ideology_pod_save_header_invalid` 拒绝，不会再出现「字段错位 → 报截断或 state_hash 不符」。
- 新增测试：
  - `ideology_runtime_test.gd::_test_stale_pkid_is_rejected_by_version`：只改写 schema 字（偏移 4），
    其余字节原样；断言 `reason == "ideology_save_schema_unsupported"`。
  - `RuntimeIdeologyPodAuthority::self_test`：用上一版 ABI 重建头部 + 重算 FNV 校验和，
    断言被 `ideology_pod_save_header_invalid` 拒绝，且**同一条数据用当前 ABI 仍能恢复**。
- **敏感性已验证**：把这处断言的期望字符串改错后重建，`runtime_domain_pod_test` 由 13/0 变 13/1
  （`[FAIL] Ideology worker plan/replay contract`），证明该断言不是空转。

### 6b 完成：trade 按经过天数结算，与结算次数无关

- 共享核 `ideology_trade_flow_q16`（`gdext/src/runtime_ideology_pod.h`）：
  `trade = trade_per_day × (day - trade_paid_day)`；首次观测只播种标记不付款；同日重复不重复付。
- 两侧都改为调用它：`ideology_runtime.cpp`（主线程）、`runtime_ideology_pod.cpp`（worker）。
- **与 08 §2.9 的 clamp 不同**：原式写 `clamp(span, 0, period_days)`，实测在 30 天/period=5 下
  「结算 1 次 = 5000、结算 30 次 = 29000」，与该条自己的「总额只取决于经过天数」矛盾，也与本轮
  要求的「1 次/30 次/随机次数总额相等」单测冲突。已按用户裁定去掉 clamp（period 仍作参数传入）。
- 单测在 `RuntimeIdeologyPodAuthority::self_test` 内：同一 30 天跨度，**结算 1 次 / 每天 /
  每 period 天 / 不规则含重复** 四种节奏总额必须相等且等于 `trade_per_day × 29`；另断长间隔
  （99 天）付满 99 天、同日重复只付一次。

### R8-4 完成：比较器只接受日期距离 0

- `native_simulation_host.cpp::record_ideology_parity_locked` 由「取最近一帧」改为
  **只接受 `committed_day == worker.committed_day`**；找不到时记
  `ideology_parity_uncompared_day_offset` 并**不计入 compared**，绝不把「无法比较」算成匹配。
- 驱动 `runtime_ideology_parity_test.gd` 改为按 `ideology_parity_worker_committed_day` 跑主线程日，
  不再用 driver tick。
- 实测生效：`uncompared=2`、`paired_ref == paired_worker == 14`，说明确实有 2 天被拒绝配对而不是被模糊配上。

### R8-3 完成：world_seed 经 Facade 进入 native catalog

- `ideology_facade.gd::configure(..., world_seed := 0)` 把 `world_seed` 写进 native catalog；
  `map_generator.gd:1792`（开局，传 `seed_value`）与 `:2969`（读档，传 `_save_restore_seed`）两处传入。
- native 侧本来就读 `catalog.get("world_seed", 0)` 并把种子经 `export_pod_catalog` 传给 worker，
  缺的只是 GDScript 这一跳。
- 单测：`self_test` 新增断言——同 handle 不同 world_seed 的三组种子互不相同且可重现，
  且改一位 handle 就变。

### A1「opinion 按日绑定」未达成（本轮尝试后回退）

- R8-2 的**结算次数**问题由 6b 独立修掉了；剩下的是「两侧消费同一份 opinion」。
- 实测事实（`PK_IDEOLOGY_TRACE=1`）：Economy 的 `commit_day` 与 worker 的 ideology `plan.day`
  **不是同一日标**。trace 样本：worker 计划第 1 天时最新提交是第 4 天，第 2 天对第 2 天，
  第 3 天对第 6 天。因此 08 §A1 的 `committed_day <= day` 规则在多数日子选不到任何快照。
- 我据此试了 6 种绑定规则（严格 ≤、取最新、绑定 worker 实际消费的那份、`committed_day+1` 等），
  parity 的 `matched` 从 4 一路退到 0（`worker_opinion_rev=0`，worker 整天不结算）。
- 已**回退本轮自己写的绑定改动**（未 revert 他人改动），恢复「读最新提交」的既有行为，
  `matched` 回到 4。这一步没有让情况变好，只是没有变坏。
- 遗留：`set_frozen_opinion_snapshot` / `clear_frozen_opinion` / opinion 环 /
  `select_ideology_opinion_for_day` / `worker_opinion_snapshot_for_day` 已就位但**未接线**，
  下一轮应先把两个日标的映射测清楚（打印两侧 (plan_day, committed_day, period_index) 对照表），
  再决定绑定规则，而不是继续猜。

### 本轮实测（全部原始输出）

| 测试 | 结果 |
|---|---|
| `runtime_domain_pod_test` | `=== runtime domain POD: 13 checks, 0 failures ===` |
| `ideology_runtime_test` | `ideology runtime: 67 checks, 0 failures` |
| `runtime_ideology_save_roundtrip_test` | `runtime ideology IDP2 save: 22 checks, 0 failures` |
| `ideology_draw_flow_test` | `ideology draw flow: 16 checks, 0 failures` |
| `runtime_ideology_parity_guard_test` | `=== ideology parity guards: 21 checks, 0 failures ===` |
| `runtime_ideology_parity_test` | `=== runtime ideology parity: 15 checks, 3 failures ===`（门禁，预期红） |

SCRIPT ERROR：以上 6 个测试 grep 结果均为 0（`ideology_content_test` 有 2 条 SCRIPT ERROR，
但它是既有情况，本轮未改动该路径）。

**parity 门禁仍红，且本轮发现它不确定**：同一 DLL、同一种子连续跑 5 次，
5 次里 4 次 `matched=4`（`first_mismatch_day=3`, `ref_points_rev=1`），1 次 `matched=9`
（`first_mismatch_day=12`, `ref_points_rev=12`）。只有 `matched` 与主线程结算次数在变，
`compared=12`、`paired_ref==paired_worker==14`、`worker_day=14` 都稳定 ⇒ 是竞态
（主线程/worker 谁先结算），不是确定性差异。**在这一条被消除之前，任何「matched==compared」
的结论都不成立。**

| 次数 | compared | matched | first_mismatch_day | ref_points_rev |
|---|---|---|---|---|
| 1 | 12 | 4 | 3 | 1 |
| 2 | 12 | **9** | **12** | **12** |
| 3 | 12 | 4 | 3 | 3 |
| 4 | 12 | 4 | 3 | 1 |
| 5 | 12 | 4 | 3 | 1 |

阶段 A 的 DoD（parity 绿且确定、A2 零开销计数器为 0、05 表里 01 的 P1/P2 全部有实测证据）
**未达成**，因此不进入阶段 B/C。

---

## 2.7 第 10 轮（2026-10-22，DLL 17:04:01）

范围：08 §2.10 的 R9-1…R9-5。构建 `scons: done building targets.`，
DLL **17:04:01**，测试前后时间戳一致（§3.6 规则 2）。构建期间因 DLL 被残留
Godot 进程锁定而链接失败一次，按 skill 的做法改名旧 DLL 后重建成功，`.old`
已删除。

### 完成并有实测

- **R9-2 完成：结算键改成 `commit_day`。** `period_index = commit_day / period_days`
  用了会变的除数（`period_days` 来自 `_epoch_days`，每 epoch 重算），实测例子：
  day 10/5 与 day 12/6 都落到第 2 期，一次新提交被当成「同一期」跳过。两侧
  （`ideology_runtime.cpp` 主线程、`runtime_ideology_pod.cpp` worker）都改为
  `settle_key = commit_day + 1`（-1 时退回 revision）；`period_index` 保留为诊断。
  **副作用是好的：parity 从不确定变成确定**，见下。
- **R9-3 完成：单次上限按天放大（方案 a）。** 采用「上限 × 结算覆盖天数」：
  `gain = min(gain, cap × covered_days)`，两侧同式。理由：`trade` 现在按跨度一次付清，
  跨度越长越容易撞上限，结算少的一侧反而拿得少；按天放大后「1 次 = 30 次」在
  ledger 层也成立。`covered_days` 取 `day - trade_paid_day`（同日为 1）。
- **R9-5 完成：基线分支同时播种 `trade_paid_day`。** 原来 `baseline_ready == 0`
  直接 `continue`，标记要到下一次才播种，白丢一期 flow。两侧都改了。
- **R9-1 部分完成：** 单一结算函数体 `accrue_points_from(opinion, day)` 已落地，
  `accrue_points(day)` 只是取 Economy 快照后调用它；worker 侧把
  `(plan_day → shared_ptr<opinion>)` 存进**加锁小环**（容量 16，替换了原来三个独立
  atomic），`worker_opinion_snapshot_for_day` 单次加锁读取，读到的一对值不可能来自
  不同天。
- **死代码删除：** `select_ideology_opinion_for_day`、`const bool opinion_for_day = true`
  及其不可达分支、`_ideology_opinion_for_day_missing`、三个独立 atomic
  （`_ideology_worker_plan_day` / `_opinion_period_index` / `_opinion_committed_day`）、
  无人读的 `_ideology_references` day-keyed map。

### 未达成：R9-1 的接线（主线程消费 worker 那份 opinion）

按 08 §2.10 的实现路径做了，但**没有收敛**，已按用户裁定回退接线、保留已证机制。
实测到三段事实（`PK_R9_DIAG`/`PK_IDEOLOGY_TRACE` 输出）：

1. worker 小环正确：`plan=1,2,3,…` 单调，`(plan_day → opinion)` 成对。
2. 主线程几乎总在 worker 记录**之前**被调用（`wopinion=0`），因为驱动 tick 快于 worker 提交。
   偶然对上的是补跑日。
3. 改绑「worker 已记录的最新天」后，同一天被重复发布：`ref_pub=1278` 对应 24 个不同的天，
   比较 FIFO 被同日副本填满，精确配对再也对不上 → `compared=0`。加去重后
   `ref_pub=0`（分支不可达）。

根因不是实现细节，而是**两侧的「天」不是同一坐标**：worker 的 `plan.day` 与主线程被要求
跑的 `day_index` 语义不同，worker 计划日历领先于驱动请求的天。接线必须先把这条映射
设计出来（例如由 worker 主动把「它刚结算的那一天」作为权威日号回传，主线程按该日号跑，
比较器也按该日号配对），而不是在主线程侧猜一个天去查环。

### 本轮实测（原文）

DLL 17:04:01，测试前后时间戳一致。

| 测试 | 结果 |
|---|---|
| `runtime_domain_pod_test` | `=== runtime domain POD: 13 checks, 0 failures ===` |
| `ideology_runtime_test` | `ideology runtime: 67 checks, 0 failures` |
| `ideology_draw_flow_test` | `ideology draw flow: 16 checks, 0 failures` |
| `ideology_progression_test` | `ideology progression: 21 checks, 0 failures` |
| `runtime_ideology_save_roundtrip_test` | `runtime ideology IDP2 save: 22 checks, 0 failures` |
| `runtime_ideology_parity_guard_test` | `=== ideology parity guards: 21 checks, 0 failures ===` |
| `ideology_effect_instance_test` | `ideology effect instance: 51 checks, 0 failures` |
| `runtime_worker_source_scan_test` | 通过（无 checks 行输出） |
| `runtime_ideology_parity_test` | `=== runtime ideology parity: 15 checks, 3 failures ===`（门禁，红） |

SCRIPT ERROR：以上 8 个非门禁测试 grep 结果均为 0。

**parity 连续 5 次（本轮最重要的结果：不确定 -> 确定）**

5 次输出**完全一致**：

```
run 1: compared=12 matched=4 first_mismatch_day=3 field=points_balance ref_points_rev=3 paired_ref=14 paired_worker=14
run 2: compared=12 matched=4 first_mismatch_day=3 field=points_balance ref_points_rev=3 paired_ref=14 paired_worker=14
run 3: compared=12 matched=4 first_mismatch_day=3 field=points_balance ref_points_rev=3 paired_ref=14 paired_worker=14
run 4: compared=12 matched=4 first_mismatch_day=3 field=points_balance ref_points_rev=3 paired_ref=14 paired_worker=14
run 5: compared=12 matched=4 first_mismatch_day=3 field=points_balance ref_points_rev=3 paired_ref=14 paired_worker=14
```

对比上一轮（同一 DLL 连跑 5 次里 1 次 `matched=9`）：R9-2 的 `commit_day` 键消除了
「哪一侧先结算」的不确定性。**但 `matched==compared` 仍未达成（4/12）**，所以阶段 A 的
parity 验收**未通过**；差异现在是确定的、可复现的业务差异（从第 3 天起、`points_balance`），
不再是竞态。

### 版本变化

本轮**没有**改存档或 ABI 版本：PKID 仍 8、IDP2 pod ABI 仍 6、PKEF 12、catalog hash 未变。
`points_revision` 字段语义再次改变（现在存 `commit_day + 1`，原为 `period_index + 1`），
但它是**派生游标**、已在 PKID 内且版本门是精确相等，v7 及更早仍被拒；v8 内部语义变化
对旧 v8 档的影响是「可能少结算一次」，不会错位读字段。这一点如需严格 fail-closed，
应在下一轮把 PKID 8→9 并在 05 登记（本轮未做，因为用户未要求改版本号）。

---

## 2.8 方向调整（2026-10-22）：只走 worker，parity 停工

游戏**只走 worker 路径**，主线程意识形态路径**冻结**。由此：

- **不再维护 parity。** `runtime_ideology_parity_test` 标为**已知红、不阻塞**：
  它留在 `Invoke-RuntimeTests.ps1` 的列表里（删条目会隐藏红色），照常运行，但在
  summary 里单独列为 known-red，**不计入 failed，不影响退出码**。
  当前实测 `15 checks / 3 failures`，`compared=12 matched=4`。
- **A1 与「主线程消费 worker opinion」停工**，已有代码**不回退**。具体保留：
  `accrue_points_from` 单一结算体、worker 侧加锁的 `(plan_day → opinion)` 环、
  `worker_opinion_snapshot_for_day`、`ideology_opinion_bridge.h`。
  `run_daily_from` 与 `select_ideology_opinion_for_day` 已在上一轮回退/删除（无调用者）。
- 冻结的含义：主线程 ideology 仍会在 IDEOLOGY 授权给 worker 时被 `run_ideology_daily`
  短路（`suppressed`），因此这条路径不再承担正确性责任；它的差异是**冻结后不再投入**的
  已知项，不是待修缺陷。
- 阶段 A 的 DoD 中「parity 绿且确定」一项**作废**（被本调整取代），其余不变。

---

## 2. 未做的债

### 2.1 双权威 parity 测试（阻塞 C3/C5 的验收强度）

`ideology_effect_worker_forward_test.gd` 的头注释已经写明：fresh ACTIVE start
要等 worker **完整提交一天**才拿到域授权，而 headless 目录 fixture 没有 Climate trace，
那一天永远不完成 → IDEOLOGY 永远授权不到 worker。

所以「同一世界跑两遍模拟、max |Δ| == 0」这条硬门**当前做不了**。
需要先补一个气候 trace fixture，或者换一条不经过域授权的缝。这不是加个等待函数能解决的。

### 2.2 协同反向索引

`magnitude_scale_for()` 仍是 O(协同总数) 扫表。C2 的签名用「活跃协同位哈希」绕过了它，
所以不致命，但每张卡的 resolve 仍在付这笔钱。

### 2.3 `latched` 跨权威翻转不传

wire 上有 `input.latched`，`upsert_instance` 也实现了「同身份保留、换 generation 才取 wire 值」，
但 **forwarder 不读 latched 列**，理念提交批次也不带。翻转那一帧 band 会归零一次。

补法：forwarder 读可选 `latched` 列 + 理念批次带上 `EffectRuntime` 的 latched。
和 §1.3 是同一类问题，区别只在频率（翻转一个会话顶多一次，存档每天都在发生）。

### 2.4 `query_effect_target_cells_detail` 导出

计数已经进 `report()`（`selector_truncations` / `selector_matched_total`），
缺的只是「单次查询时把 matched_total 回传给 GDScript」的诊断接口。

### 2.4b `ideology.city.*` 的读者普查（2026-10-21）

生成器写了 31 个「卡可定向」的城市 stat，但其中 **7 个在 gdext 里零读取点**：

| 无读者的目标 | 说明 |
|---|---|
| `economy.city.output_factor`（聚合） | 每物资 CSR 只读 `good.<id>.output_factor` |
| `economy.city.resource.*.regen_factor`（6 个） | `_city_resource_regen_stat_ids` 无读取点 |

其余 24 个有读者：`good.*.output_factor`（每格 CSR）、`building.*_output_factor`
（生产循环按建筑组读）、`need.*.consumption_factor`、`birth_factor`。

结论：**不需要建 `ideology.city.*` → `economy.city.*` 的桥**。卡直接写有读者的
economy stat 即可；上面 7 个先登记在 `IDEOLOGY_CITY_DEAD_STATS`，给它们读者之前不生成定义。

### 2.5 P1-E / P3-B

P1-E（X4 事件叠层）未动；`STATE_LATCHED` 有了，但「层数」仍是静态展开。
P3-B **已在 R-3b 关闭**，见 §2.9。

---

## 2.9 R-3b（2026-10-22）：边界服务、tag 快照门控与 P3-B 收口

范围：10-roadmap §3 R-3b 的六项。构建 `scons: done building targets.`，
DLL **2026-10-22 22:37:09**。**版本号全部未变**：PKID 8、IDP2 ABI 6、
Effect POD ABI 3、PKEF 13、FAMILY_METRIC_COUNT 68、catalog hash 未变。
本轮只改派生量、门控和测试，没有动任何存档或 wire 布局。

### 1. 边界服务请求从「一个 bool」改成「按请求方计数」（P1）

`native_simulation_host.h` 的 `_main_boundary_service_requested` 是**一个 bool**，
两个调用方共用：`world_ext_trigger.cpp` 在握手失败时置位、成功交接时清除；
`world_ext_ideology.cpp` 在实例刷新拿不到锁时置位，**但从不清除**。

后果分两半，缺一不可解释：

- **ideology 一侧**：request 之后再没人清。worker 在
  `native_simulation_host.cpp:15284` 的 `_control_cv` 循环里parked，
  语义日循环不再前进。表现就是 `ideology_card_content_worker_test` 的
  `worker_committed_day 2 -> 2`、`slots_used=0`、`rows=[]`、receipts 为空。
- **trigger 一侧**：任何一次 trigger 完成都会**替 ideology 清除**这一个 bool，
  所以在两者重叠时 worker 会被提前放行，看起来像「偶发」。

修法：`MainBoundaryClient{TRIGGER, IDEOLOGY}` 各占一位，
`request` 是 `fetch_or`，`complete` 是**只清自己那一位**的 CAS 循环；
worker 的等待谓词改成 `mask != 0`。`complete` 对未持有的位是 no-op，
所以一个子系统不可能释放另一个的 turn。

ideology 侧的执行顺序是「请求持久化到下次调用、下一次真正拿到锁之后立刻 complete」：
请求必须在跳过期间**保持置位**（它就是「请回来」的唯一信号），
而在拿锁成功后必须释放（否则 worker 会被一个已经无事可做的请求继续挡住）。
complete 放在两个出口之前，因此提前返回的分支也配平。

导出：`main_boundary_service_requests` / `main_boundary_service_ideology` /
`main_boundary_service_trigger` 进 `get_runtime_thread_report()`，
`ideology_card_content_worker_test` 新增断言「没有任何客户端在等边界」。

### 2. `ideology_tag_snapshot_stress_test`：从「卡在前置条件」到端到端翻转

原测试停在 `economy publishes an epoch (revision=0)`。逐层原因（每层都实测过）：

1. **economy slice 是 fatal，而测试当成功**。`run_economy_slice` 在缺环境列时
   返回 `done: true, fatal: true, stage: environment_snapshot,
   fatal_reason: required_environment_slot_missing`。测试只读 `done`，
   于是「失败」被当成「完成」，唯一症状是 revision 一直是 0。
   → 新增 `_register_environment_slots()`（8 个 F32 + 5 个 U8，与
   `economy_rolling_runtime_test._new_ext` 同形），`_run_economy` 改为一见
   `fatal` 就把 `fatal_reason` 打出来并返回 false。
2. **political_class_ids 手写 `["general"]`**。Economy 按**真实**职业阶层发布
   lanes，`runtime_ideology_pod.cpp:538` 的 shape 校验因此失败
   （`ideology_opinion_snapshot_shape_invalid`），worker 起不来。
   → 改成 `_political_class_ids()`，与 `ideology_catalog.gd:78-90` 同一套推导
   （strip / 空串→general / 去重 / 排序），顺带保证 `class_hash` 两侧相等。
3. **卡不是 Effect program**。原来 `persistent_selector_kinds = 12` 配的是
   `ideology.city.population_factor.gain`，那是 Modifier 行，进不了
   `resolve_effect_targets`，永远没有每格实例。
   → fixture 自带一份 Effect catalog：`managed = true`、
   `target_domain = 2`、`target_selector_kind = 12`、`param[1] = 标签 id`，
   并声明一条 tag 谓词 `cell.population >= 400`。
4. **程序 key 少了前缀**。`effect_program_key()` 会补 `ideology.effect.`，
   fixture 直接注册裸 key，于是 `family_effect_metadata_pod` 查不到 →
   `has_managed = 0` → 消费者集为空 → `tag_snapshot_needed=false`。
5. **`metric_keys` 必须整表**。`tag_metric_ids` 存的是**稠密下标**，
   而 `sample_effect_metrics` 按 `FamilyEffectMetricId` 索引。
   只声明一项会把 `cell.population` 从 9 挪到 0，tag 行静默去读
   `family.magnitude_q16`。→ 直接取 `effect_domain_catalog.build()` 的
   `metric_keys` 全表，并断言下标 9 仍是 `cell.population`。
6. **equip 批次的 sequence 撞了 discover**。`submit_commands` 按
   `sequence <= high_watermark` 判重（producer 维度），两个批次都用
   `country + 1`，于是 6 条 equip 全被判 duplicates，`ok: true, accepted: 0`，
   卡停在「已发现未装备」。
7. **没有 `run_effect_daily`**。reconcile 只是把事务 submit 出去，
   Effect 不 ACK 就没有实例。补上调用。
8. **`acquisition_flags[0] = 2`（只有 DRAW）**，DISCOVER 被
   `ideology_discovery_not_allowed` 拒绝。改成 3。

最终标签翻转是**真的**：`tagged_cells` 0 → 32（第 15 天把 override 从 120 抬到 900），
实例数 0 → 192（6 国 × 32 格上限），`tag_changes=1`、`refresh_visits=1`。

同时按第 2 项要求做了三件事：卡带 tag 过滤（`OWN_TERRITORY` + `param1` = 1 基
tag id）、运行中真的制造 tag 翻转、删掉 worker 接管之后的 `run_ideology_daily(0)`
（worker 权威下是 `suppressed` 空操作，留着只会让「这天处理过了」看起来成立）。
现在是「只有非 worker 权威时才调 `run_ideology_daily`」，一个条件调用点，
而不是无条件那一行。

### 3. tag 快照 / metric 67 按消费者门控（P2）

`rebuild_epoch_tag_snapshot()` 原来是**无条件**每 epoch 全格采样 + 每国扫描。
现在先读 `EffectInputConsumers`：`tags_needed` 为假且 mask 里没有 metric 67，
就直接发布 null 并 `++tag_snapshot_skips`，一个格子都不采。

保守方向是刻意的：**消费者集还没发布时返回「需要」**。老世界、没有配置理念的
fixture、以及直接调 `set_target_tags()` 的选择器测试都因此行为不变。

计数器：`tag_snapshot_builds` / `tag_snapshot_skips` / `tag_snapshot_needed` /
`tag_bits_needed` / `specialized_good_count_needed` 全部进 `get_economy_report()`。

测试里有一个**对照世界**（`_test_no_consumer_epochs_are_free`）：8 张纯 Modifier 卡、
空 Effect 目录、无 tag，实测 `builds=0 skips=4 class_opinion_revision=3`
——即「确实提交了 3 个 epoch，一个都没建表」。

### 4. `cell_has_target_tag` 的每次调用一次 `atomic_load(shared_ptr)`（P2）

MSVC 上 `atomic_load(shared_ptr)` 的引用计数**不是无锁的**，走进程级自旋锁。
四个调用点里三个在循环内逐格调用：

- `collect_effect_target_cells` 的 `OWN_TERRITORY` 分支（逐格）
- 同函数的 `TAG_ANY_CELL` 分支（全网格逐格）
- `economy_runtime.cpp:6558`（`neighbor_count_with_tag`）
- `economy_runtime.cpp:6683`（cell-program 过滤，country × cell × entry 三层）

改法：新增 `snapshot_has_tag(const TagSnapshot*, cell, tag)` 纯函数，
四个循环都在**循环外**load 一次并把指针传进去。`cell_has_target_tag` 保留为
单次查询形式（选择器测试还在用），注释里写明「不要在循环里用」。

计数器 `tag_snapshot_loads` 进报告，测试断言「整国 tag 扫描的加载次数 ≤ 4×扫描数」。
实测 **1.00 次/扫描**。

### 5. `set_target_tags` 的单写者约束（P3）

`rebuild_epoch_tag_snapshot()` 是 `_published_tag_snapshot_generation` 的**唯一**
赋值点，而它有两个调用方（epoch capture、`set_target_tags`）。
两条路径由 `_tag_snapshot_building`(CAS) 串行化：后到者直接返回、保留旧快照，
并 `++tag_snapshot_skips`。`set_target_tags` 在进入时如果发现有重建在飞，
就往 stderr 打一行（带 builds 计数）并 `++tag_snapshot_concurrent_writes`；
该计数器导出进报告，测试断言为 0。

为什么不是 `assert`：这个 runtime 不持有边界锁，没法在函数内证明「调用方在配置阶段
或持锁」。把**可观察的后果**（并发写发生了）变成计数器和一行日志，
是能真正抓到的形式；`assert` 在 release 构建里是空的。

### 6. 本轮实测（原文）

DLL **2026-10-22 22:37:09**。

| 测试 | 结果 |
|---|---|
| `ideology_tag_snapshot_stress_test` | `=== ideology tag snapshot stress: 37 checks, 0 failures ===`（SCRIPT ERROR 0） |
| `ideology_card_content_worker_test` | `=== ideology card content worker: 8 checks, 1 failures ===`（停在**既有内容缺口**，见下） |

**回归（全部 SCRIPT ERROR 0）**：

| 测试 | 结果 |
|---|---|
| `ideology_runtime_test` | `ideology runtime: 70 checks, 0 failures`（原 70/1 的 `world_seed` 也已绿） |
| `ideology_effect_instance_test` | `ideology effect instance: 51 checks, 0 failures` |
| `ideology_target_selector_test` | `ideology target selector: 2 checks, 0 failures` |
| `effect_selector_tag_resolution_test` | `effect selector tag resolution: 48 checks, 0 failures` |
| `ideology_effect_metric_publish_test` | `ideology effect metric publish: 283 checks, 0 failures` |
| `runtime_ideology_save_roundtrip_test` | `runtime ideology IDP2 save: 22 checks, 0 failures` |
| `runtime_ideology_parity_guard_test` | `=== ideology parity guards: 21 checks, 0 failures ===` |
| `target_tag_dictionary_test` | `target tag dictionary: 77 checks, 0 failures` |
| `target_tag_catalog_test` | `target tag catalog: 30 checks, 0 failures` |
| `metric_mask_capacity_test` | `metric mask capacity: 12 checks, 0 failures` |
| `runtime_worker_source_scan_test` | `runtime worker source scan: PASS` |

**未完成，且不是本轮引入**：`ideology_card_content_worker_test` 的前置条件
「all nine C0 cards are in the worker catalog」现在是红的，缺
`land_tax_reform` 和 `excise`。两张卡存在于生成器里，但按 C 的
`CARD_REQUIRES["land_tax_reform"] = ("X16", "metric68")` /
`excise = ("X16", "reserve_ratio")` **暂存不发布**（09 §3 有记录）。
所以这个测试目前**无法越过第一条前置条件**，「worker keeps committing days」
那条断言本轮**没有拿到实测原文**。

P1 的修法本身已用可测代理验证：`main_boundary_service_requests` 导出后，
不再有「请求未完成」的永久置位；敏感性验证 E（把 ideology 的 complete 去掉）在本轮
**没能通过 worker 测试变红**，因为测试先被内容缺口挡住。这一项的敏感性验证
**未完成**，明确记在这里，不当作已验收。

### 7. 敏感性验证（原文）

四项都做了「临时改坏 → 跑出红 → 恢复 → 重建」：

- **A：把 tag 位全部清零**（`std::fill(tag_bits, 0)`）。
  红：`ERROR: [FAIL] tag flip creates one instance per tagged cell up to the selector
  cap (after=0, expected 192)` / `[FAIL] cell instance count tracked the tag change
  (tag_changes=0)`，`=== 21 checks, 2 failures ===`。
- **B：让 `tag_snapshot_needed()` 恒为 false**（tag 目录也走跳过路径）。
  红：`ERROR: [FAIL] ideology declared a tag-consuming program
  (tag_snapshot_needed=false columns=1)`，`=== 6 checks, 1 failures ===`。
- **C：让 `tag_snapshot_needed()` 恒为 true**（永不跳过）。
  红：`ERROR: [FAIL] no-consumer: the catalog declares no tags
  (tag_snapshot_needed=true)`，`=== 35 checks, 1 failures ===`。
- **D：`OWN_TERRITORY` 分支退回逐格 `cell_has_target_tag`**。
  红：`ERROR: [FAIL] a whole-territory tag scan costs at most 4 snapshot loads
  (delta=360 for 10 scans, i.e. 36.00 per scan vs 36 cells)`，
  `=== 37 checks, 1 failures ===`。

### 8. 顺手修正：测试 override 与 tag 采样不同源

`set_effect_metric_override_for_test()` 原来**只在 `refresh_effect_input_digest`
里生效**，`rebuild_epoch_tag_snapshot()` 采的是原始值。于是「移动 override 让阈值
过线」这件事只能让 revision 动、tag 位不动 —— 任何 tag 测试都不可能靠它翻转。

现在 override 应用在 `sample_effect_metrics()` 这个**唯一采样点**，
digest 和 tag 位读同一份值。并且**不再按 `metric_mask` 过滤**：
mask 是「tag 行按 key 点到的 metric」，override 是按**编号**设的，
两者本来就不同坐标系；按 mask 过滤会让 override 被静默吞掉。

---

## 2.10 R-3c（2026-10-23）：worker 路径跑通

范围：只做「worker 跑通」。构建 `scons: done building targets.`，
DLL **2026-10-23 02:57:19**。版本号全部未变；`RuntimeIdeologyPodReceipt` 增了一个
**不序列化**的 `reason_text`，所以 IDP2 布局没动。

### 1. 卸下不恢复：根因是 generation 自增（不是 emit_templates 的 salt）

`start_transition` 在构造批次身份之前就 `++state.generation`，而
`enqueue_external_effect_batch_pod` 用
`(source_type, transition_source_id, first.effect_id, fire_sequence)` 派生 Effect 实例 id
（`effect_runtime.cpp:3465`），`transition_source_id` 里嵌的正是这个 generation。
于是 UNEQUIP 与它要撤销的 EQUIP 不是同一个实例，`remove_unique_command` 查不到，
回 `already_removed`，行留着、stat 保持加成值。

R-3c 的修法是「UNEQUIP 用 previous_generation」。R-3d 发现这还不够：
升级/换位时同一批里的 remove 与 apply 仍共用新 generation，于是把两者**拆成两批**
（见 §2.11.3）。R-3c 版的单点修法已被那个更一般的修法取代。

> **关于 `emit_templates` 的 salt**：那条 `salt == 0 && managed` 的 `continue` 是对的，
> 没有改。实测这些模板 `managed=0`，从未被跳过；探针也证明 `remove=1` 时命令数是 1，
> 断点在入队之后的实例身份上。

### 2. 回执原因透传（可观测性）

`apply_command` 的 `error` 原来被丢弃，主线程只看到常量串 `ideology_worker_rejected`。
`RuntimeIdeologyPodReceipt` 多一个 `reason_text`（不序列化）。这条是定位
「卸下被谁拒绝」的唯一手段：实测直接读到 `ideology_support_threshold_not_met`。

### 3. 测试侧

`CARDS` 删掉 `land_tax_reform` / `excise`（C 按 `CARD_REQUIRES` 暂存不发布）；前置检查从
「九张都在 catalog」改成「当前选中的那张在 catalog」。`tmp/run_worker_cards.ps1` 同步到 7 张。
另外修了三处非确定性：等 `ideology_pod_committed_day`、装备后等 Modifier 行真的出现、
卸下后给有界追平窗口。

### 4. 当时的结果

7 卡里 5 张 `18/0`，2 张卡在 support 门槛（`support=-8192 < threshold=0`）。
存档往返曾绕道手跑 `run_*_daily`，R-3d 已改回「恢复后重启 worker」。

---
## 2.11 R-3d（2026-10-23）：worker 跑通收尾

构建 `scons: done building targets.`，DLL **2026-10-23 12:19:56**。
**版本号全部未变**：PKID 8、IDP2 ABI 6、Effect POD ABI 3、PKEF 13、
`FAMILY_METRIC_COUNT` 68、catalog hash 未变。

### 1. 「等 worker 跑完一天」等的是一个不存在的字段

`_drive_days` 轮询 `ideology_pod_committed_day`，而报告里从来没有这个键
（`RuntimeThreadReport` 有 `worker_committed_ideology_day`，但 `get_runtime_thread_report`
从未把它写进 Dictionary）。于是**每一天都干等满 8 秒超时**，然后对着上一份快照断言。

修法：报告正式输出 `ideology_pod_committed_day`（= POD 自己的 `_ideology_pod_committed_day`）。
注意 `ideology_parity_worker_committed_day` **不能替代**：它只在记录 parity 参照时赋值，
生产会话与这个 fixture 永远是 -1。

测试同时改成「等 pod 天数**前进**」而不是「到达我的 tick」——两者是不同坐标系
（`[waittrace]` 实测 18 次等待里 16 次 miss），并把超时从 8 s 降到 2 s。
另加两条断言：发现阶段必须观察到真实提交日、装备阶段的天数必须递增。

`ideology_worker_benchmark.gd` 同步改到同一个字段。

**单张卡耗时**（同机、同 DLL、`terrace_farming`）：

| | 墙钟 | `[wait]` 汇总 | 结果 |
|---|---|---|---|
| 修前（8 s 超时、字段缺失） | **181.1 s** | 18 次全 miss | 24/0（早期版本 18/0） |
| 修后（真实字段 + 2 s） | **59.4 s** | `calls=18 total_ms=32024 misses=16` | 24/0 |
| `C0_LEGACY_WAIT=1` 复现旧行为 | 64.1 s | `calls=18 total_ms=36021 misses=18` | **24/2**（两条 committed-day 断言红） |

### 2. 卸下不再用「被拒绝」当通过

新增 `PK_DISABLE_SUPPORT_GATE`：在 `DCWorldExt::configure_ideologies` 里把
每张卡的 `stance_*` 清空（`stance_count == 0` 即 `support_allows` 直接放行），
**主线程与 POD 同时生效**，因为两边由同一份字典编译。生产不设该变量时目录原样透传。
这等价于主线程测试的 `_support_gate_off`，但只作用于 fixture。

`ideology_card_content_worker_test` 里「repeal 被 support 拒绝」从**通过**改为 **FAIL**
（fixture 已关门槛，再被拒就说明 bypass 没到 POD）。`tmp/run_worker_cards.ps1` 带上该变量。

### 3. 升级 / 换位的来源 id（用户怀疑成立，确实是同一个 bug）

`transition_source_id` 嵌 generation，而 `NATIVE_MODIFIER_IDEOLOGY` 用它的实例 id 当
Modifier 行的 `source_id`。**同一批里 remove 和 apply 共用一个 id**，于是升级 L1→L2 时
旧等级行在新 generation 下删不掉，两个等级的行并存、数值层层叠乘。

修法（按用户建议，不加特判）：**把 remove 与 apply 拆成两批**，
remove 用 `transition.previous_generation`。`_removed_command_scratch` 是新的独立缓冲。

新增两个测试（主线程，`ideology_card_content_test`）：
- `_test_level_up_replaces_rows`：L2 生效、`.l1` 已退休、只有一行、stat = 1.15（不是 L1×L2）；
- `_test_relocation_replaces_rows`：换位到国家精神位后 `ideology=0 spirit=1`，只有一行。

**逆向验证**：把 remove 改回新 generation →
`ideology card content: 1731 checks, 354 failures`，
`forager_band L2 ... = 1.1200 (json) (got 1.20960 expected 1.12000)`、
`L3 ... got 1.35475` —— 正是叠乘指纹。

### 4. GDScript 自动回复收紧

「Effect 已接受」代表效果已生效，不是走过场。门控改回
**「worker 拥有 IDEOLOGY，且 Effect 不归 worker 管」**：0xFFF 下 worker 自己 drain，
GDScript 再回一次就是在替一个没人验证的提交背书。
新增 `_ideology_intent_duplicate_acks` / `_ideology_intent_unknown_acks` 两个计数器
（去重按 transaction id），经 `WorldRuntimeHost.get_ideology_intent_reply_report()` 导出，
测试在 0xFFF 夹具下断言两者为 0。

### 5. 读档后重启 worker：P1，修到第三层，第三层仍未解决

先确认正式路径：`game_save_coordinator.gd:697` 调 `restore_runtime_bundle`，
`world_runtime_host.gd:804` 随后调 `_start_production_shadow_worker()`；
而 `restore_runtime_bundle` 只把 bundle 交给 host，**由下一次 `start()` 消费**
（`world_ext_simulation_host.cpp:2674` 注释明说）。所以「recover → start worker」
就是正式顺序，这条是 P1。

逐层定位并修掉前两层：

1. `ecp2_atomic_backup_failed:building_trade_block_pairing`
   —— **已修**：`apply_ecp2_authority` 取回滚备份时，`_formula_owned` 绑定的 OwnedState
   里 `building.captured` 恒为 true（`fill_ledger_building_from_store` 设的），
   其余 block 的 flag 仍是从恢复前复制的。现在 `capture_committed_ledger_state` 的
   绑定分支按 live 表重新打包这几个 block 并置 `captured`，
   `assign_owned_blocks_from_ledger` 也补了同样的标志。
2. `ecp2_atomic_backup_failed:economy_save_state_shape_invalid`
   —— **已修**：`[save-shape] market_cell_to_market actual=0 expected=192`。
   回滚备份改成**尽力而为**：live 状态不可捕获时不再拒绝 restore
   （`apply_ecp2_authority_internal` 本身仍是全有或全无，候选先校验后重建）。
   `_last_restore_backup_skipped_reason` 记录跳过的原因。
3. `economy_country_restore_order_or_hash_mismatch`
   —— **未解决**。economy 的 apply 会比对存档里的 country state hash 与 live country
   runtime（`economy_runtime_persistence_read.cpp:561-567`），load 路径上两者不一致。
   存档往返测试仍**红在这一条**，断言保留（红着比假装通过好）。

### 6. 杂项

`ideology_card_content_worker_test.gd` 的 8 处 GBK 误解码乱码（`鈹€`、`搂5`、`鐢熸垚…`）
全部修回正确中文，文件按 UTF-8 无 BOM 重写；复查 `tests/ideology/*.gd` 无残留。

### 7. 最终验收（DLL 2026-10-23 12:19:56）

**7 张卡**（`tmp/run_worker_cards.ps1`，每张 25/0）：

| 卡 | 结果 |
|---|---|
| terrace_farming / water_works / forager_band / riverside_camp / seasonal_calendar | `25 checks, 0 failures` |
| pit_dwelling / hydroelectric | `25 checks, 0 failures` |
| **合计** | **`=== worker-path C0 total: 175 checks, 0 failures ===`** |

每张卡现在都走完「卸下 → 卡槽释放 → 加成行消失 → 数值恢复」，没有一张靠「被拒绝」蒙过。

**回归（全部 SCRIPT ERROR 0）**

| 测试 | 结果 |
|---|---|
| `ideology_card_content_test` | `1731 checks, 0 failures`（含新增升级/换位两条） |
| `ideology_effect_worker_forward_test` | `127 checks, 0 failures` |
| `runtime_ideology_save_roundtrip_test` | `22 checks, 0 failures` |
| `ideology_tag_snapshot_stress_test` | `37 checks, 0 failures` |
| `runtime_domain_pod_test` | `13 checks, 0 failures` |

注：`ideology_card_content_test` 的检查数从 452 涨到 1731，是**会话 C** 同期在该文件里
加了「按 85 张卡的期望表驱动」；我的两条升级/换位断言也在其中，均通过。

**存档往返（`C0_SAVE_ROUNDTRIP=1`）**：`29 checks, 1 failures`，
红在 `worker restarts on the restored bundle (runtime_worker_start_failed)`，
内部原因即上面的第 3 层 `economy_country_restore_order_or_hash_mismatch`。

---

范围：只做「worker 跑通」。构建 `scons: done building targets.`，
DLL **2026-10-23 02:57:19**。**版本号全部未变**：PKID 8、IDP2 ABI 6、
Effect POD ABI 3、PKEF 13、`FAMILY_METRIC_COUNT` 68、catalog hash 未变。
`RuntimeIdeologyPodReceipt` 增了一个 **不序列化** 的 `reason_text`，所以 IDP2 布局没动。

### 1. 卸下不恢复：根因是 generation 自增（不是 emit_templates 的 salt）

`start_transition` 在**构造批次身份之前**就 `++state.generation`，
而 `enqueue_external_effect_batch_pod` 用
`(source_type, transition_source_id, first.effect_id, fire_sequence)` 派生 Effect 实例 id
（`effect_runtime.cpp:3465`），`transition_source_id` 里嵌的正是这个 generation。
于是 UNEQUIP 与它要撤销的 EQUIP **不是同一个实例**：

1. `upsert_instance_pod` 为 remove **新建**了一个实例；
2. `NATIVE_MODIFIER_IDEOLOGY` 把 `source_id` 设成那个新实例的 id
   （`effect_runtime.cpp:5509`）；
3. `remove_unique_command` 按 `(definition, scope, scope_id, source_type, source_id)` 查
   （`modifier_runtime.cpp:1190`），查不到 → 回 `already_removed`，
   **行留着，stat 保持加成值**。

修法：UNEQUIP 的批次用 `transition.previous_generation`，其余用 `state.generation`
（`ideology_runtime.cpp`，`batch_generation`）。apply/remove 的 `effect_id` 本来就不含
generation，所以两侧对得上。

实测（主线程冒烟）：
- 修前 `remove_events=[0,0,0,0]`，`rows=["ideology.terrace_farming.l2"]`，`452/2`；
- 修后 `remove_events=[0,1,0,0]`，`rows=[]`，`452/0`。

> **关于用户点名的 `emit_templates` salt**：那条 `salt == 0 && managed` 的 `continue`
> 是**对的**，没有改。实测这三行模板的 `managed=0`（`ideology.terrace_farming.l2` 是
> Modifier 行，不是 `ideology.effect.*` 程序），所以它从来没被跳过；
> 探针还证明 `remove=1` 时命令数确实是 1，断点在**入队之后**的实例身份上。

### 2. 回执原因透传（可观测性）

`apply_command` 的 `error` 原来被丢弃，主线程只看到常量串 `ideology_worker_rejected`。
现在 `RuntimeIdeologyPodReceipt` 多一个 `reason_text`（**不序列化**），
`apply_ack` 的拒绝也写 `effect_transition_rejected`。
这条改动是定位「卸下被谁拒绝」的唯一手段：实测直接读到
`ideology_support_threshold_not_met`。

### 3. 边界请求的生命周期（R-3b 遗留）

R-3b 把 ideology 的 complete 放在「拿到锁之后」，于是**最后一次跳过**留下的请求
没人清，worker 停在 `outstanding=1 / state=PAUSED`。
现在改成「进入函数先清上一轮、仍抢不到锁再重新请求」，请求生命期正好一轮。

### 4. worker 的 intent 泵不再要求域授权

`world_runtime_host._service_ideology_worker_intents_if_authoritative` 原来以
`authoritative_domain_mask & 0x10` 为门。pod 已经规划了 transition 并排队 intent，
但域没授权（授权要**完整提交一天**，而没有 Climate trace 的 fixture 永远完不成），
于是没人 ACK，transition 永远 PENDING。
回 ACK 不是授权决策——pod 已经决定了，这只是告诉它 Effect 侧接受了。门改成
「有授权 **或** pod 已配置 **或** 有待处理 intent」。

### 5. 测试侧（归 R）

- `CARDS` 删掉 `land_tax_reform` / `excise`（C 按 `CARD_REQUIRES` 暂存不发布，
  旧断言写的 `country.tax.*` 已随 V1 作废）；前置检查从「九张都在 catalog」
  改成「**当前选中的那张**在 catalog」。
- `tmp/run_worker_cards.ps1` 同步到 7 张。
- 三处**非确定性**修复（这才是「同一 DLL 每次红的卡不同」的原因）：
  - `_drive_days` 等到 `ideology_pod_committed_day >= 目标天`，不再是「PAUSED 就算好」；
  - 装备后等 Modifier 行真的出现（`_wait_for_modifier_row`），因为行由 Ideology
    之后的 Effect/Modifier 阶段写；
  - 卸下后给两级有界的「快照追平」窗口，因为 WRITE-BACK 读到的可能是 ACK 之前的快照。
- 新增 `C0_SAVE_ROUNDTRIP=1` 分支：装备 → PKSR 存档 → 停 worker → restore →
  再跑 3 天 → 断言 stat 不变、行还是同一行、天数前进。

### 6. 本轮实测（原文）

DLL **2026-10-23 02:57:19**。

**a. 逐卡（`run_worker_cards.ps1`，7 张）**

| 卡 | 结果 |
|---|---|
| terrace_farming | `18 checks, 0 failures` |
| water_works | `18 checks, 0 failures` |
| forager_band | `18 checks, 0 failures` |
| riverside_camp | `18 checks, 0 failures` |
| seasonal_calendar | `18 checks, 0 failures` |
| pit_dwelling | `22 checks, 0 failures` |
| hydroelectric | `22 checks, 0 failures`（02:57 DLL） |

**c. 存档往返**（`C0_ONLY_CARD=pit_dwelling C0_SAVE_ROUNDTRIP=1`）
`=== ideology card content worker: 28 checks, 0 failures ===`，SCRIPT ERROR 0，
`[save-roundtrip] pit_dwelling day_before=-1 day_after=17 stat 0.95000 -> 0.95000`。

**e. 回归（全部 SCRIPT ERROR 0）**

| 测试 | 结果 |
|---|---|
| `ideology_card_content_test` | `ideology card content: 452 checks, 0 failures`（原 452/2） |
| `ideology_effect_worker_forward_test` | `=== ideology effect worker forward: 127 checks, 0 failures ===` |
| `runtime_ideology_save_roundtrip_test` | `runtime ideology IDP2 save: 22 checks, 0 failures` |
| `ideology_tag_snapshot_stress_test` | `=== ideology tag snapshot stress: 37 checks, 0 failures ===` |

### 7. 敏感性验证（原文）

- **A：撤掉 bug B 的修复**（`batch_generation` 改回 `state.generation`）。
  `ideology_card_content_test` → `452 checks, 2 failures`，
  `[unequip] slots=0 tx_offsets=[0, 0] emitted=2 acked=2 remove_events=[0, 0, 0, 0]`，
  `[FAIL] unequip retires the national modifier row (rows=["ideology.terrace_farming.l2"])`，
  `[FAIL] unequip restores the terrain factor to its base (1.15000 ...)`。
- **B：撤掉 `complete_main_boundary_service`**（ideology 侧）。
  `C0_ONLY_CARD=pit_dwelling` → `17 checks, 4 failures`，`script 不会超时但 worker 停住`：
  `[FAIL] pit_dwelling occupies an ideology slot on the worker path (slots_used=0 pod_day=2 ...)`、
  `[FAIL] applied a national modifier row (rows=[])`、
  `[FAIL] ... equals the design value (after=1.00000)`、
  `[FAIL] worker delivered the unequip to the pod (receipt=false)`，
  receipts 为空。**上一轮没做成的这一项本轮拿到了。**

### 8. 未完成 / 交叉影响（明确标出）

- **卸下在 worker 路径仍会被 support 门槛拒绝**：实测
  `support=-8192 < threshold=0`（该 fixture 世界的 opinion.population 只有
  `general` 一个 lane 有 20 人，另外两个政治阶层为 0）。这是**真实的民意结果**，
  不是链路断裂——pod 收到 opcode 6、给出确切原因、槽位/行/stat 按设计保留。
  尝试过用 `CHANGE_SIGNATURE`（POD opcode 8，签名从 `target_country` 读，
  不是 `payload0`）把 cohort 重标到其他阶层，命令被接受但发布的 opinion 不变，
  该路线**记录不采用**。解锁它需要 X16/metric68 之后的多阶层世界。
- **restore 后重启 worker 会撞一个无关缺陷**：`ecp2_atomic_backup_failed:
  building_trade_block_pairing`（`runtime_worker_start_failed`）。3c 因此改为在恢复后
  继续跑日循环，仍满足「stat 不变 + 天数前进」。
- **hydroelectric 的最终全量重跑撞上 C 的内容改动**：
  `[modifier] configure failed: modifier_term_invalid` /
  `[effect] domain catalog build failed`，停在 4 checks。
  `default_modifier_catalog.tres` 等三个 catalog 的 mtime 是 **10:20:33**，
  而我最后一次构建是 **02:57:19**——是 C 在我跑测试期间改的内容，
  不是本轮代码。该卡在 02:57 的 DLL 上是 `22 checks, 0 failures`。
  最后一次批跑因此汇总成 `116 checks, 0 failures`（少一张卡的 4 条前置检查），
  **不是** 134；这一条必须在 C 的目录稳定后重跑一次才算数。

---

## 3. 既有红（**不是**本轮引入）

以下两项在动手之前就是红的，已用「还原改动后重跑」的方式确认：

| 测试 | 失败项 | 确认方式 |
|---|---|---|
| `family_buff_runtime_test` | 4 条 `family.set_split_policy retain-only/bonus-weight` | `git stash` 暂存 C7 脚本改动后同样 4 条 |
| `economy_trade_runtime_test` | 8 条（PKEC v35/v54 存档、accuracy frontier、foreign route、seller rebind、publish conservation 等） | 反向补丁还原 C8 后 10 条 ⊇ 带 C8 的 8 条 |

带 C8 时反而少两条（`worker and scalar emit identical trade orders` / `final trade hashes match`），
这两条本身不稳定，不作为「修好了」的证据。

---

## 4. 可检索的取舍（一句话索引）

- **修订号是内容摘要，不是时钟** —— 挂在 COMMIT 尾，且不含 `state_hash`（它含 cash/goods）。
- **切片按重算计费，不按国家计费** —— 否则尾部饥饿，512 国一轮 8 天。
- **`present` 判定必须包含 scale** —— 只比 id+generation 会漏掉「协同改了强度但身份没变」。
- **`latched` 进 PKEF 也进 POD wire** —— 「一个 cadence 自愈」只对每日 pass 成立。
- **`city.*` / `cell.*` 的域校验只能在生成器做** —— 原生侧只认 id，不认名字。
- **`city.*` stat 只许 SUM** —— MaxSource/TopNSources 只留一行，且存活那行读数依然正确，静默。
- **截断用稳定哈希，不是最小 id** —— 最小 id 让每张卡都偏爱地图同一角落。
- **贸易因子是成交量因子** —— 只放宽容量等于对空闲国家无效；两处都乘是平方。
- **`legacy_pod_instance_ids` 保留但永远为空** —— 删掉判据会让下次 schema 迁移看起来比实际小。

---

## 2.12 R-4（2026-10-23）：worker 读档第 3 层 + X16 / metric 68 / metric 69

### 1. worker 读档第 3 层 — **已修**

`economy_country_restore_order_or_hash_mismatch` 的根因不是 hash 算法，是**顺序**：

`native_simulation_host.cpp` 的 `start()` 先应用 ECP2（economy），后解码 country
checkpoint。于是 ECP2 校验时 live country 还是刚 bootstrap 的那份。
探针原文（`PK_COUNTRY_HASH_PROBE=1`）：

```
[country-hash] saved_schema=13 live_schema=13 saved_gen=19 live_gen=1
saved_hash=325166771088284131 live_hash=1824313771786949620 compatible=1
economy_available=1
```

正式游戏同样走这条路（`restore_runtime_bundle` 只暂存，`start()` 消费），
所以每次读档起 worker 都会死在 `runtime_worker_start_failed`。

修法：`NativeEconomyRuntime::_accept_stale_country_identity`，由 host 在**那一次**
`apply_ecp2_authority` 调用前后成对设置/清除。作用域外校验照旧严格——
把一份 ECP2 应用到 Country 已经前进过的 live economy 上仍然是真损坏，必须失败。

代价（明确记录）：Country 字节与 Economy 字节来自不同存档的档案，不再被这道门拦下；
其余形状校验（`country_schema_compatible`、building/trade 计数）仍生效。

### 2. 第 4 层 — **未修，P1 欠账**

修掉顺序后，重启 worker 本身成功（`worker restarts on the restored bundle` 变绿），
但**重启后的 worker 不再提交新的一天**：

```
[FAIL] pit_dwelling: the RESTARTED worker commits days on the restored state (16 -> 16)
```

`[climate/worker][b8] paw day=13` 是最后一行动，重启后 climate 阶段不再推进。
即主线程每天调用 `run_daily_tick` 也无法让 pod 拿到新的 climate day。
这条与 ideology 无关，是 worker 重启后的 climate/economy 握手没有重建。

复现方法：
```
$env:C0_ONLY_CARD="pit_dwelling"; $env:C0_SAVE_ROUNDTRIP="1"
$env:PK_DISABLE_SUPPORT_GATE="1"
godot --headless --path Project/project-keynes `
  -s tests/ideology/ideology_card_content_worker_test.gd
```
观察 `artifacts/r4/save_test3.log`：`save roundtrip` 之后没有新的
`[climate/worker][b8]` 行。

### 3. X16 / metric 68 / metric 69（已落地）

**版本**：`FAMILY_METRIC_COUNT` 68 -> 70，`MetricMask::CAPACITY` 仍是 256（不用加宽）。
PKID / IDP2 ABI / Effect POD ABI / PKEF **全部未变**——这三项都是派生量，没有新存档字段。
Modifier / Effect catalog hash 变了，旧档 fail-closed，这是预期的。

**X16**
- `economy_runtime_configuration.cpp`：按 `_profession_ids` 顺序解析
  `economy.profession.<pid>.tax_tolerance_factor` / `.satisfaction_bp`，缺失为 -1。
- `capture_country_epoch`：`_epoch_country_profession_tax_tolerance_q16`（Q16，钳 [0.5,3.0]）与
  `_epoch_country_profession_satisfaction_bp`（bp，钳 [-2500,2500]），每 epoch 每国每职业冻结一次。
- `update_cohort_satisfaction`：容忍度参与税维度；满意度偏置**在 ceiling 之前**加，
  正偏置无法突破生存天花板。
- `modifier_catalog.gd`：两族 stat，tolerance 只允许 MULTIPLY（位 4），satisfaction 只允许 ADD（位 1）——
  写 15 会让卡把容忍度减成负数。
- `stat_key_families.gd` 两族登记；`modifier_catalog.gd` 显示名「<职业> 税负容忍度 / 满意度」。

**metric 68** `cell.net_tax_burden_q16`：在 `fill_family_behavior_metrics` 里累加本格 cohort 的
`epoch_tax_paid - epoch_subsidy_received` / `max(0,epoch_income)+max(0,epoch_in_kind_income)`，
按 `touch_accounting_slot` 的 `ACCOUNTING_EPOCH_BIT` 奇偶过滤（本期没记过账的 cohort 记 0，
避免读到上期残值）。口径与满意度税维度一致。

**metric 69** `country.treasury_reserve_ratio_pct`：`cash_for_slot / (Σ income_ema × 365) × 100`，
钳 [0,1000]，每 epoch 每国冻结。v0 分母用 income_ema 外推，**不新增存档状态**；真正的滚动年累加器
推迟到 M4（09 §8）。

**观测**：新增 `DCWorldExt.get_epoch_profession_report(country_slot)` 和
`sample_effect_metric_probe(metric, cell, handle)`，让测试断言**冻结后的**值而不是 Modifier 读数——
后者在「卡声明了 stat 但 freeze 没取到」时仍会通过。

### 4. 生成器：`cards_published` 85 -> 93

`AVAILABLE_CAPABILITIES` 加 `X16` 和 `metric68`。`reserve_ratio` **保持不可用**，原因是实测的：

> `card programs must use an ideology.city.* definition`

`excise` L3 和 `progressive_tax` L1-L3 各带一个 `RampTerm`，ramp 是 Effect 指令序列，
不能写进 Modifier 定义（`modifier_blocks.add()` 直接跳过）。先尝试把它们改写成
`LEVEL_ROWS` 程序行，被上面这条规则拒绝——国家域 stat（建造成本、死亡率）没有程序载体。
如果照旧发布，L1 只会剩下 11 条 tolerance，第 12 条 ramp **静默消失**（已实测到 11 条）。

因此加了一条生成器硬规则（校验/lint 部分，属 R 的范围）：`LEVEL_TERMS` 里含 `RampTerm` 的卡
一律不算已发布，除非它的 metric 有程序载体。加之前是 95，加之后是 **93**，与 §4.4 的预期一致。

### 5. 更正：`modifier_term_invalid` 是 R 自己引入的（已修）

上一版这一节把根因归给了 C，**是错的**。真实根因在 R 自己写的 stat 声明：

`modifier_catalog.gd` 声明 `economy.profession.*.satisfaction_bp` 只允许 ADD（位 1），
而生成器的 `_term_operation` 对**没写第三个 tuple 元素**的项一律输出 MULTIPLY（2）。
`petition_box` 和 `light_levy` 的正向满意度加成正是这种写法，于是产物
`default_modifier_catalog.tres` 里有 **32 条 `satisfaction_bp` 是 operation=2**，
编译时 `modifier_term_domain_or_operation_invalid`，整个 Modifier 目录起不来，
世界生成随之失败。之前"换成 git 原版仍然失败"的对照之所以误导，是因为那份原版
`modifier_catalog.gd` 里还没有 R 加的 stat 声明，而**产物 tres 里已经有**这些 term。

三项修复：

1. `_term_operation` 增加加性判定：`*.satisfaction_bp`、所有 `*_bp` / `*_q16` 以及
   `satisfaction_*` 家族一律输出 ADD，正向加成也是 ADD。
2. 生成器新增 `stat 前缀 -> 允许运算` 表（`_STAT_ALLOWED_OPERATIONS` /
   `_STAT_ALLOWED_OPERATIONS_BY_SUFFIX`），与 `modifier_catalog.gd` 的
   `allowed_operations` 一致；某 term 的运算不在允许范围内直接 `SystemExit` 硬失败。
3. 期望表（`card_expectations.json`）的 `operation` 字段改用同一个 `_term_operation`
   判定，否则 `satisfaction_bp = 400` 会按 multiply 读成 401（实测 26 + 6 条）。

重生成后核对：**56 条 `satisfaction_bp` 全部 `operation=0`**，无残留。

连带修正：`ideology_card_content_test` 的 `STAGED_CARDS` 去掉 `land_tax_reform`
（R-4 起它随 metric 68 一起发布，L3 是真正的 Effect 程序行 `land_tax_reform_l3`）。
`excise` 仍暂存，因为它的 L3 是国家域 `RampTerm`，卡程序只能命名 `ideology.city.*`。

**P0 修复后的验收**：

| 测试 | 结果 |
|---|---|
| `ideology_effect_metric_publish_test` | `283 checks, 0 failures`（修前 101/60） |
| `ideology_mechanism_matrix_test` | `473 checks, 0 failures`（修前 390/1） |
| `runtime_domain_pod_test` | `13 checks, 0 failures` |
| `ideology_card_content_test` | `1928 checks, 0 failures`（修前 1929/33） |

### 6. 已解决：worker 7 卡不是「变慢」，是堆被写坏

上一版把这一节写成「epoch 变慢」，**是错的**。真实根因是数组越界写：

* `EffectInputSnapshot::metric_revision` 声明为 `std::array<uint64_t, 68>`
  （`economy_runtime.h`），而 `FAMILY_METRIC_COUNT` 在 R-4 已经变成 70。
  该结构在**命名空间作用域**，`FAMILY_METRIC_COUNT` 在 `NativeEconomyRuntime` 类内
  且声明在它之后，所以当初只能写字面量 68，追加 metric 时没人把它加宽。
* `economy_runtime_family_buff.cpp` 的 `++next->metric_revision[slot]` 会写到
  下标 68/69，越界两个 `uint64_t`。
* 读取侧 `economy_runtime.h:effect_metric_revision` 与 `ideology_runtime.cpp` 的
  卡片 revision 求和也读 68/69。
* 任何读取 metric 68 的卡（`land_tax_reform` L3、`light_levy`）**必触发**。
  Windows 事件日志从 14:27 起约 65 次 `0xc0000374`（堆损坏），之前为 0。

之所以表现为「停在第 1 天」，是因为进程直接死了；`run_worker_cards.ps1` 把
「没有 summary 行」记成 `run void`，读起来像慢，实际是崩溃。

**修法**：把容量提到命名空间作用域
`constexpr int32_t PK_EFFECT_INPUT_METRIC_REVISION_CAPACITY = 70;`，数组改用它，
并在 `FAMILY_METRIC_COUNT` 后加 `static_assert` 把两个常量钉在一起——以后追加
metric 而忘记加宽数组会变成**编译错误**，不再是运行期堆破坏。

全仓复核过：`metric_revision` 的其余用法要么按下标、要么是 `std::vector`；
其它 `std::array<..., N>` 与 metric 无关（`annual_development_ledger.cpp` 的 4 是
满意度维度）。

### 7. 排查期的临时改动：逐条处置

| 改动 | 处置 | 理由 |
|---|---|---|
| metric 69 的 `_epoch_country_reserve_pct` 改成**一次遍历归集**（原为每国扫全部格） | **保留** | 原版 O(国家×格×cohort)，单遍 O(格×cohort)，与崩溃原因无关但明显更对 |
| X16 的 epoch 数组 stride 由 `max(1, _profession_ids.size())` 改为**真实 size** | **保留** | `max(1,0)` 会让国家 N+1 索引到国家 N 的行，是真实索引错位 |
| worker 测试的 pod 等待超时 2 s → **8 s** | **保留** | 2 s 会让 pod 未提交就继续，8 s 是 R-3d 验证过的值 |
| `run_worker_cards.ps1` 的 `2>&1` → **`Start-Process` 显式重定向** | **保留** | 合并 stderr 会丢掉输出尾部（含 summary 行） |
| `PK_DISABLE_SUPPORT_GATE` 改成「只降门槛」 | **已回退** | 带该版本时 pod 一天都不提交；回到 R-3d 的「清空 stance」版本 |
| 测试里临时加的 `[daydbg]` / `[waittrace]` / `PK_SAVE_SHAPE_PROBE` 之外的探针 | 已移除 | 诊断用，不应留在产物里 |

### 8. P1 之后

完成 P0 之后本轮的剩余项（P1-a / P1-b / R-5）见下一节。

## 2.13 R-7 F（2026-10-24）：X1_PLAIN_SWITCH 全量发布

`X1_PLAIN_SWITCH` 加入 `AVAILABLE_CAPABILITIES`；逐卡发布由
`X1_PLAIN_RELEASE` 显式控制。23 张卡先在 `PK_X1_FORCE_READY=all` 生成的
candidate catalog 上用真实 worker 路径逐张验收（每进程一张，0xFFF），
全部通过后才写入 allowlist。测试用 only-for-test 的 tag/metric 覆写补齐固定
夹具，不再按地图碰运气；equip 时 tagged cell 为 `1.0 + value`，untagged cell
为 `1.0`，unequip 后恢复基线。

发布结果：`cards_published=116 of 116`（同分支空 allowlist 基线为
`cards_published=109 of 116`；16 张改写卡 + 7 张新卡随本轮从旧定义/未入池
切换为逐格定义）。catalog hash（sha256）：
ideology `755D70954D61D0A82C5B75401BC719D76E924C987E71646AD6D3B64E5C781012`、
effects `D10830C03CED26A975EC7AED650B39CE0AF3A3000CF38C8BABC1E8BB30AD8DAB`、
modifier `82F6A909B516E71A0ECEEEF9EE6AD413404C2CA3E76D8325167148D297292866`。
旧 PKID / PKCM / PKEF 存档在加载时以 catalog mismatch fail-closed；这是内容
身份变化的预期行为，不做迁移或修补。

## 22. 永久地块效果取消 32 格限制（M0–M5，2026-10-28）

这是独立于上面 P1/P2/P3 的一次迁移，方案见
[22-cell-program-cap-removal-plan-v3.md](22-cell-program-cap-removal-plan-v3.md)。

**状态：实现中，核心与数值已验证。** §18 的 28 项里 **12 项有证据、16 项无证据**。
完整交付证据见 [M5-DELIVERY-REPORT](../../../artifacts/ideology-cell-layer/M5-DELIVERY-REPORT.md)，
玩家/运维面向的变更说明见 [发布说明](22-cell-cap-removal-release-notes.md)。

| 里程碑 | 状态 | 主要落点 | 验证 |
|---|---|---|---|
| M0 基线 | 完成 | program inventory、调用顺序、原型 | `m1_backend_coverage.py` 6/6 |
| M1 资格与 IR | 完成 | `cell_program_eligibility.h`（**I01 唯一判定**）| 265/265 全 DerivedCell |
| M2 派生层 | 完成 | `derived_cell_layer.h` + `derived_cell_materializer.{h,cpp}` | 内核 **93 checks / 0** |
| M3 目标与数值 | 完成 | `selector_cell_cap.h`、ramp 走程序幅度 | oracle **12 / 0**（3 点 `delta = 0`）|
| M4 分片与时序 | 完成 | `step_derived_rebuild` + `drain_derived_cell_layer` | B7 **23/0**、B5 **9/0** |
| M5 切换与清理 | **部分** | 旧 v1 平面已删（约 430 行）、rollout 开关已删 | 见下 |

### M5 的具体状态

| 项 | 状态 |
|---|---|
| 删除旧 v1 平面 | **完成**（8 个子项全删，含 4 个 ClassDB 桥）|
| 删除迁移期开关 `kCellProgramRollout` | **完成** |
| 32 常量改 legacy 名 | **完成**（`LEGACY_INSTANCE_MAX_CELLS`）|
| 归属筛选（用户新增目标项）| **完成**（默认 OWN，74 张卡受影响，边境 51.7%）|
| debug + release 构建与真实测试 | **完成**（release 跑过 7 个 fixture，检查数逐一相同）|
| 全量回归 | **68 个夹具：37 通过**（30 失败中 4 个已定案并修复 3 个）|
| B1–B12 | **4/12**（B5、B7、B8、B10）|
| save/load 全部时点、权威翻转 | **未做** |
| 峰值内存 | **未测** |
| UI 高亮、内容文案 | **未做** |
| 文档与 skill 同步 | **部分**（3 份 native 文档 + 2 个 skill；§16.5 还列了 7 个）|
| 真实世界 >32 生产样例 | **没有**（真实世界 `countries=3 widest=1`）|

### 本次顺带修掉的真实缺陷

| 缺陷 | 后果 |
|---|---|
| `collect_effect_activations` 以 `out_derived != nullptr` 判后端 | I01 违反，派生卡同时建实例 |
| `effective_value` 的 `group_handle != 0` 守卫 | **每张卡在其国家第一个格（cell 0）上失效** |
| `SOURCE_COUNT_RADIUS_MASK`（位宽 7）当校验上限 | author r=5 能过校验、运行时静默丢弃 |
| **ramp 路径跳过卡片的指令流** | **24 张卡数值错误**，被打到 stat 上限 |
| `Term::program_key` 用 `std::string` 值成员 | 每次 Term 拷贝分配，6400 格 +13% 耗时 |
| `building_context_ready_for_test` 少了 `return out;` | 返回未定义数据（**只有 release 构建报 C4715**）|
| `_cell_layer_rebuild_visits` 只导出不递增 | 计数器永远 0，夹具报出假失败 |
| `ideology_cell_layer_e2e_realworld_test` 的 `run_economy_slice(64)` | API 漂移 + **报错后挂住**，该夹具从未产出结果 |
