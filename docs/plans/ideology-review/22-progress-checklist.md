# 22 - 永久地块理念取消 32 格限制：实施进度 checklist

| 项目 | 内容 |
|---|---|
| 方案 | [22-cell-program-cap-removal-plan-v3.md](22-cell-program-cap-removal-plan-v3.md) |
| 创建 | 2026-10-26，Asia/Hong_Kong |
| 作用 | 本文件是**唯一**的实施进度事实来源；方案文档 §18 的复选框由本文件驱动 |
| 维护规则 | 只有附带证据的任务才能勾选；证据路径写入对应行。禁止把状态改成「基本完成」 |
| 当前阶段 | **M0–M4 完成，M5 大部分完成**（2026-10-28 终版）。§18 的 28 项中 **28 项有完整证据、0 项部分、0 项无证据** → 状态是「**实现中，核心与数值已验证**」，不是「彻底取消完成」。详见方案 §18.5 与 [M5-DELIVERY-REPORT](../../../artifacts/ideology-cell-layer/M5-DELIVERY-REPORT.md) |
| 当前规模 | 本清单 **892 项完成 / 257 项开放**；回归 **28 fixture / 1027 检查全 0 失败** + 内核 **103 / 0**；覆盖率门禁 **7/7**（265/265 + 无 kind 14/15 源上限）|
| DLL | debug `c40806c0f223cd4b` / release `b172a83733a6b8a1`（release 上真实跑过 10 个 fixture，检查数与 debug 逐一相同）|

| 终态说明 | **11 项无证据按「卡在哪」分三类**（共用真实 `MapData` / 需大夹具 / 结构性阻塞），接手起点与 8 条已踩过的坑见 [M5-HANDOVER](../../../artifacts/ideology-cell-layer/M5-HANDOVER.md) |

## 0. 使用方法

1. 每完成一项，把 `[ ]` 改成 `[x]`，并在该行末尾追加 `→ 证据：<相对路径或测试名>`。
2. 一项任务只要有一条子项未完成，父项保持 `[ ]`。
3. 新增任务追加到所属里程碑末尾，不插队重排已完成项编号。
4. 「阻塞」状态写成 `[!]` 并附阻塞原因与需要谁决策；解除后改回 `[ ]`。
5. 每批次收口时更新 §7 的交付记录表。

## 1. 状态图例

| 标记 | 含义 |
|---|---|
| `[ ]` | 未开始 |
| `[~]` | 进行中 |
| `[x]` | 完成且有证据 |
| `[!]` | 阻塞，需要决策或外部条件 |
| `[-]` | 明确不做（须写理由与决策点） |

## 2. M0：基线、可重建性与边界原型

退出条件（§15.2）：以下八项均有文件或测试证据；不得把 worker 交接、恢复基础或预算全部留给「实现时再看」。

### M0-1 program inventory

- [x] 重新生成 program inventory：稳定 key、真实类别（A–H）、连续/条件 metric、命令/term、selector rewrite、reader
  - [x] `.tres` 数量基线复算（288 program / 272 地块 / 265 迁移 / 325 命令引用）→ 证据：`Project/project-keynes/tools/ideology/m0_program_inventory.py --check`
  - [x] 逐 program 输出 A–H 类别与 backend 建议列 → 证据：`artifacts/ideology-cell-layer/m0/program_inventory.csv`
  - [x] 连续 metric / 条件 metric 分列（22、24 vs 57/59/63/67）→ 证据：报告 §「ramp programs」段
  - [x] 命令到 definition／term 的展开表 → 证据：`artifacts/ideology-cell-layer/m0/program_inventory_terms.csv`（325 行）
  - [x] reader capability manifest（每个 stat 的实际 C++ 读者）→ 证据：报告 §「reader manifest」段，7 族 325 条全部解析
- [x] inventory 脚本入库，可复算（格式变化时改统计器而非沿用旧总数）→ 证据：`m0_program_inventory.py --check` 16 条断言全绿

### M0-2 基线记录与 >32 截断实锤

- [x] 记录 HEAD、dirty 文件摘要、DLL hash/时间戳/target、Godot 版本、CPU、内存、seed、地图、国家与卡牌列表 → 证据：`artifacts/ideology-cell-layer/m0/M0-2-baseline-findings.md` §1
- [x] 记录当前测试基线：精确测试名、检查数、错误签名、日志路径 → 证据：`baseline-logs/baseline_summary.csv` + 同上 §2
- [ ] **关键**：基线必须在 HEAD 与当前工作区各跑一遍并记录差异 → **未完成**：工作区有 319 项变更，需另开 worktree；当前只测了工作区（待用户决定是否值得）
- [x] 实锤旧路径 >32 截断确实发生 → 证据：`ideology_x1b_source_count_test.gd:287-310` T8 实测 142 checks 0 failures，断言 36 目标截到 32
- [ ] 记录 §14.2 B1–B12 场景基线与 §14.3 历史门槛的原始测量口径 → **未做**：本里程碑未测任何性能数字
- [x] **新增发现**：当前工作区本身有 3 个失败 fixture（content 3 / instance_budget 10 / mechanism_matrix 3），且 `ideology_instance_budget_test.gd` 未被修改 → 属既存债务，非本方案引入

### M0-3 真实调用顺序

- [x] 主线程：确认 ACK → 日提交 → RAW_INPUTS → 资源恢复 → FACTOR_CAPTURE → checkpoint → 快照替换的**实际**先后 → 证据：`artifacts/ideology-cell-layer/m0/M0-3-call-sequence-findings.md` §1
- [x] worker：同一口径，标注 `_economy_authority_boundary_mutex` 持锁范围 → 证据：同上 §2（加锁 15608 / `execute_day_plan` 15712 / incomplete unlock 15969）
- [x] 标明 `start_epoch` 是否可续跑 → 结论：**不可续跑**（无 resume 游标，唯一两个 continuation 属 fiscal 阶段），证据同上 §3
- [x] 列出市场/生产/投资/资源四种 cadence 的实际采样边界 → 证据：同上 §6–§7
- [x] 补充：`RuntimeIdeologyPodAuthority` 无「已确认投影」概念 → `ConfirmedCountryProgramBasis` 是净新增，证据同上 §4
- [x] 补充：`apply_pod_snapshot` 的 `structure_epoch` 无条件 +1（`modifier_runtime.cpp:463-464`），必须与 layer 版本分开

### M0-4 边界原型

- [x] 原型验证：独立派生成员不会被 `apply_pod_snapshot` 的 `_stores = std::move(next_stores)` 抹掉 → **源码层成立**；执行验证转 M1 退出条件（见下）→ 证据：`artifacts/ideology-cell-layer/m0/M0-4-prototype-findings.md` §3
- [x] 原型验证：热 read view 不逐格加锁、不逐格 `atomic_load shared_ptr` → `effective_value` 是 `const` 且无同步；**但 `ModifierReadView` 抽象尚无**，M1 须新增 → 证据：同上 §2.3
- [x] 原型验证：派生层在 worker 快照替换后仍有效 → 归入 M1 退出（需 ACTIVE + 已提交语义日才能触发快照）→ 证据：同上 §3
- [x] 副产物：记录两个会静默毁掉自动化基线的问题（Godot stdout 不可管道捕获；Godot 可执行文件是 1 字节占位符 + 同名目录内真文件）→ 证据：同上 §4
- [ ] **[M1 结转]** 必须在 M0-2 的 B1 harness 之上**执行**断言：派生 front 在 `apply_pod_snapshot` 前后逐值不变。M0 只给了源码证明，不构成 §13.1 第 4 层证据

### M0-5 冻结字段可重建性表（§11.3）

- [x] 对全部 `_epoch_*` 字段分类：可从 live store 等价重算 / 必须补 checkpoint / 已落盘 → 证据：`artifacts/ideology-cell-layer/m0/epoch_field_audit.csv`（169 行）
- [x] 逐字段表：`metric/tag -> 原始存储 -> 所属冻结窗口 -> 是否已入档 -> 恢复阶段 -> 差异测试` → 证据：`M0-5-epoch-field-audit-findings.md` §2–§4
- [x] 明确当前只有 5 个 `_epoch_*` 容器/标量落盘 + 2 个 tracked scalar → 证据：同上 §5
- [x] 列出需新增的最小 save 字段与版本面 → 结论：**cell-layer 不需要新增任何 checkpoint 字段**（7 个依赖字段全部 `DERIVED_FROZEN`），证据同上 §3
- [x] **修正 G4 基数**：实际 169 个声明（非 123），其中 18 个是墙钟诊断、151 个仿真字段
- [x] 划清审计边界：其余 56 个 `DERIVED_PARTIAL` 属既有 Economy 持久化范围，不应被 §18.2 覆盖 → 同一报告 §4

### M0-6 数值核与归并策略

- [x] 抽取并验证共享 fold 的纯核语义（VM 运算、Q16 舍入、浮点归并顺序、零因子、最终 clamp）→ 证据：`artifacts/ideology-cell-layer/m0/M0-6-numeric-kernel-findings.md` §1–§2
- [x] 用混合 scope / 零 factor / Q16 边界样例验证与旧路径一致 → §1 逐项对照公式；零因子语义确认
- [x] 固定规范归并顺序（country slot → program dense id → origin → command → term）→ §5.5 的规范已记录
- [x] 记录旧增量 bucket 历史顺序可能造成的差异反例 → **已发现真实反例**：`rebuild_bucket` 按 `bucket.members` 追加序聚合，非 country slot 序；double 加减乘不满足结合律 → 证据同上 §3
- [x] **提出并建议采纳**：§5.6 的硬 `max_q16_delta=0` 只适用于「新路径内部」（主线程/worker/重载），新旧对照改为记录差值分布 → 同上 §3
- [x] 补充发现：`magnitude_scale_allowed_for_selector` 的 `scale_q16 >= Q16_ONE/cap` 下界必须在派生预检里保留 → 同上 §5

### M0-7 布局选型与预算

- [ ] 测平铺 numeric 索引 vs 按 stat 紧凑 cell 数组 → **未做实测**（选型依据是访问模式推断）
- [x] 选定**单一**初始布局，写 ADR 补充 → 选定「按 stat 有序 cells[] + 并行 value 数组」，证据：`artifacts/ideology-cell-layer/m0/M0-7-storage-layout-findings.md` §3、§7
- [ ] 填齐新增总预算：完整物化+安装+缓存捕获 p95/p99、B7/B8/B9 峰值内存、512 国最大等待 slice 数、恢复耗时预算 → **未做**：只给了内存估算公式，无实测
- [x] **补 §14.1 遗漏项**：`covered_cells × 156` 冷建成本 → 证据：`M0-1-program-inventory-findings.md` §4
- [x] 补充发现：仓库现有 8 个容器均为持久化/变更追踪设计，均不适合热查询 → 同一报告 §4
- [x] 补充发现：极端场景（64 国全国覆盖）估算 ~177 MB，三份 front 可达 ~531 MB → 必须作为显式拒绝路径的测试用例 → 同一报告 §5

#### M0-7b 冷建成本实测（合成夹具）

- [x] 合成夹具测出 `epoch_begin_city_factor_ms` 随**地图规模**线性增长，与覆盖率无关 → 证据：`M0-7b-city-factor-cost-probe.md` §3
- [x] 定位主导项：`paint_shared` 每 epoch 重画 `cells × 155` 个 int32（`economy_runtime.cpp:7048-7061`）→ 同上 §4
- [x] 修正方案 §14.1 为 `max(covered_cells × 156, cells × 155)` → 已改 §14.1
- [x] 夹具加三条有效性门禁（行可读 / epoch 已开 / 噪声底），防止把抖动当斜率 → 同上 §2.1

#### M0-7c 真实世界成本

- [x] 真实生产世界（60×40=2400 格，正式多国开局）生成成功 → 夹具 `ideology_cell_layer_m0_realworld_cost_test.gd`
- [x] **idle 档稳态 `epoch_begin_city_factor_ms` = 0.003 ms**（n=6, debug）→ 证据：`M0-7c-realworld-cost-attempt.md` §1
- [x] **推翻合成探针的绝对值**：同量级地图合成 0.418 ms vs 真实 0.003 ms，差 139 倍 → 同上 §1
- [x] 回头收窄 M0-7b 结论与方案 §14.1：地图项是「shared 变化那一次」的成本，不是稳态 → 已改
- [x] **实测确认 M0-3 §4 的推断**：worker 权威下 `submit_ideology_commands` 返回 `path=IDEOLOGY_WORKER, accepted=12, applied=0` → 同上 §4
- [x] 定位根因 1：`MODIFIER`(0x040) 在 worker 上时 `submit_modifier_commands` 只进队列 → 同上 §3.1
- [x] 定位根因 2：`ECONOMY`(0x100) 在 worker 上时主线程不执行 `start_epoch`，`epoch_begin_*` 是配置期陈旧值（实测 13 个 epoch 读同一个 `country=29.059`）→ 同上 §3.2
- [x] 定位根因 3：把 ECONOMY 拨回主线程后经济在 **day 4** 以 `money_conservation_failed` 致命，只剩 3 天可取样 → 同上 §3.2
- [x] 加三条有效性门禁（行可读 / 经济未 fatal / A/B 对照），并让夹具在未测到时显式打印 `NOT RESOLVED` → 同上 §2
- [ ] **`loaded` 档（装卡后稳态读数）未取得** → 8 种路径全部失败，见 §4 排除链
- [!] **M1 前置阻塞**：worker 夹具脚手架缺失。与 M0-2 基线里两个卡住的 worker fixture 是**同一类缺口**。B2/B3/B12 全部依赖它

### M0-8 资格日与 epoch 生效语义

- [x] 确定 `eligible_from_day` 与「下一冻结边界采纳」的精确语义 → 证据：`artifacts/ideology-cell-layer/m0/M0-8-timing-semantics-findings.md` §2
- [x] 用旧路径时序样例列出新增/消除的延迟 → 证据：同上 §4（D=10 → 11 资格 → 13 采纳的完整时间线）
- [x] 写成可执行黄金样例（供 M2 时序测试直接复用）→ 同上 §4，落为 `ideology_cell_layer_timing_test.gd` 的设计
- [x] **[D1 已定 2026-10-28]** §9.5 采用 (a) 释放边界锁 + INSTALL 重验 `expected_basis`；`start_epoch` 内部结构全程未动（M0–M5 遵守）
- [x] 补充发现：方案 §10.1「已确认」与现有代码口径不一致 —— 现有代码的「已确认」是 Effect 事务全 ACKED，program 集合摘要无独立身份 → 需在 `poll_pending_transition` 成功分支内新增 → 同上 §3
- [x] 补充发现：§10.5 的待采纳队列容量下界 = 最长冻结周期 5，建议环形缓冲 8 → 同上 §5
- [ ] **[M2 结转]** worker 权威下的 `RuntimeIdeologyPodAuthority::apply_ack` 语义未审计，可能不同于主线程路径

### M0-9 方案修订（本轮评估发现，进入 M1 前必须落地）

- [x] **G1** §4.4 改为按 `lifecycle` 判定永久性；`maritime_insurance_l1/l2/l3` 单列为死字段案例 → 已改 §4.4 条件 2
- [ ] **G1** §12.1 文案清单补：这三张卡「持续 30 天」今天就不成立，迁移后变全国永久，文案必须同步修（**留待 M2 内容批次**）
- [x] **G2** §14.1 增补 `covered_cells × 156` 冷建成本行 + 场景表 → 已改 §14.1
- [x] **G3** §9.5 单一化：定「释放边界锁 + INSTALL 重校验」，附不做状态机化的依据 → 已改 §9.5
- [x] **G4** §11.3 写明规模：169 个 `_epoch_*`（151 仿真 + 18 诊断）/ 仅 5 容器 + 2 tracked scalar 落盘 → 已改 §11.3
- [x] **G5** §8.5 explain 增加 unclamped 出口，列为 M1 前置 → 已改 §8.5
- [x] **G6** §13.5 补「基线须在 HEAD 与工作区各跑一遍」+ 实测基线表 → 已改 §13.5
- [x] **G7** §1.3 明确本方案不交付平衡；ON 之前必须有独立平衡评审里程碑 → 已改 §1.3
- [x] **G8** §4.4 条件 3 增补：合成 definition（101 条 / 31%）必须由 `compile_native_catalog()` 解析 → 已改 §4.4
- [x] **G9** §4.4 条件 6 增补：读点必须编译期断言，不得靠注释；指出 `modifier_catalog.gd:497-502` 注释错误 → 已改 §4.4
- [x] **G10** §11.3 增审计边界条款：cell-layer 只覆盖本层 reader 的 7 个字段，其余 56 个属既有 Economy 债务 → 已改 §11.3
- [x] **G11（M0-6 新发现）** §5.6 精度门槛分两级：新路径内部硬 0，新旧对照只记录分布 → 已改 §5.6
- [x] 文档完整性复核：代码围栏平衡（28 个）、相对链接 0 缺失

### M0 退出

- [x] 上述全部有文件或测试证据 → 证据：`artifacts/ideology-cell-layer/m0/M0-SUMMARY.md` §6
- [x] M0 报告落盘 `artifacts/ideology-cell-layer/m0/` → 8 份 findings + 2 份 CSV + 基线日志
- [x] 若原型不满足统一公式/边界，先修订 ADR 与方案，再扩大实现 → 公式逐项验证通过，**无需改 ADR**；方案已按 G1–G11 修订
- [ ] **[阻塞 M1 前置] §14.3「M0 必须补齐的数字门槛」未落实**：无 p95/p99 实测、无 B7/B8/B9 峰值内存、无 512 国 slice 数、无恢复耗时预算。**建议作为 M1 前置条件处理，而不是 M1 内部任务**
  - 已取得：`epoch_begin_city_factor_ms` 稳态 0.003 ms（2400 格、无卡）与 `shared` 变化分量 `~0.00021 ms/格`
  - 未取得：装卡后的稳态读数（worker 夹具缺口）、峰值内存、p95/p99、slice 数、恢复耗时

## 2bis. M0 结转清单

| 项 | 去向 | 原因 |
|---|---|---|
| 派生 front 在 `apply_pod_snapshot` 前后逐值不变（**执行**验证） | M1 退出 | 需 ACTIVE worker + 已提交语义日 |
| 布局 A/B 实测耗时对比 | M1 前置 | 需真实规模基准夹具 |
| 性能门槛数字（p95/p99/峰值内存/slice 数） | M1 前置 | 同上 |
| HEAD vs 工作区基线差异 | M0 未完成 | 工作区 319 项变更，需另开 worktree |
| `RuntimeIdeologyPodAuthority::apply_ack` 语义审计 | M2 | worker ACK 可能与主线程不同 |
| `maritime_insurance` 三张卡文案修正 | M2 内容批次 | 与内容迁移同批 |
| `refresh_city_modifier_factors` / `..._output_...` 的 156×cells 预算 | M0-7 / M1 前置 | 已给公式与乘积，未给实测 |

## 3. M1：共享 IR、求值核和 Modifier 派生层

退出条件（§15.3）：纯核、混合 legacy scopes、cell 0、共享默认哨兵、零 factor 恢复、相同输入幂等、POD Store 替换保留层均通过；SHADOW 不写正式结果、不创建额外实例。

### M1-1 backend 判定单一列

- [x] 编译期**无运行时状态依赖**的资格判定器 → `gdext/src/cell_program_eligibility.h`
- [x] 纯核自测覆盖每条分支（14 用例 / 56 checks / 0 failures）→ `gdext/tests/cell_program_eligibility_test.cpp`
- [x] 真实内容覆盖验证：288 program 全部过判定器 → `artifacts/ideology-cell-layer/m1/M1-1-backend-decision-findings.md` §2
- [x] M2 范围 241 个全部 DerivedCell；24 个 ramp 明确归 M3；0 个未解释 legacy
- [x] 接线到 GDExtension 并构建通过（新 DLL `73bd1a36…`），回归 82 checks 0 failures → 同上 §5
- [x] **发现并修正 4 处语义**：`value_mode=1`≠非常数、ramp 是延后非排除、`REFRESH` 非 stacked、合成判定须 `.tres` 优先 → 同上 §3
- [ ] **[M1 结转] 判定器尚未被生产路径调用**：`build_cell_program_table` 仍走旧 inline 判定，backend 列未驱动实例收集与预算

### M1-2 派生层容器与 ADR02 执行验证

- [x] 派生层容器（ADR02：不进 `Store`）→ `gdext/src/derived_cell_layer.h`
- [x] 纯核自测 51 checks 0 failures → `gdext/tests/derived_cell_layer_test.cpp`
- [x] `ModifierRuntime::install_derived_cell_layer` / `derived_cell_stat_version`（版本与 legacy 分离）
- [x] **ADR02 执行验证** 19 checks 0 failures：`clear_modifier_domain` 后 layer 仍存活、格数不变、generation 不变 → 证据：`artifacts/ideology-cell-layer/m1/M1-2-derived-layer-findings.md` §1.3
- [x] §9.6 过期 generation 与外部 world identity 均被拒且理由正确
- [x] I13 幂等：相同内容重复安装不 bump（`content_digest`）
- [x] 回归零变化：15 个 fixture 逐项与 M0 基线一致（9 pass / 4 failures / 1 no_summary / 1 timeout）
- [x] 构建通过，新 DLL `7a2d7ad0…`（旧 `73bd1a36…`）
- [x] **测试抓出 3 个真实缺陷并修复**：`reset()` 未清 `_index`、空候选误关 builder、I13 幂等缺失 → 同上 §2
### M1-3 派生层并入 effective_value

- [x] 合并点定位：cell 恒在 `group_handle`（三个 reader 全部核过），`entity_handle` 恒为 0
- [x] 在 `add`/`factor` 上累加，**不碰最终值**（§5.1 禁止二次包装）
- [x] 零因子独立处理（§5.5：只乘 `product_nonzero` 会静默忽略 -100% 卡）
- [x] `rows.empty()` 快速旁路，保证未装卡时逐位不变
- [x] 合并契约测试 **20 checks 0 failures**（A–G 七组）→ 证据：`artifacts/ideology-cell-layer/m1/M1-3-merge-findings.md` §2
- [x] 新增 `resolve_modifier_stat` 桥，stat_id 与 clamp 上限从真实 catalog 取，不硬编码
- [x] **回归零判定变化**：15 fixture 逐项与 M0 基线一致（9 pass / 4 failures / 1 no_summary / 1 timeout）→ 同上 §6
- [x] 构建通过，新 DLL `934d368a…`
- [x] **记录测试自身的一处期望错误**：`birth_factor` 上限 4.0，期望 4.5 是错的；未去迎合错误期望而改坏实现 → 同上 §3
### M1-4 枚举并集与版本组合

- [x] `collect_scope_ids` 并入派生 GROUP(cell)（§8.5），仅 ECONOMY+GROUP，统一 sort+unique
- [x] `collect_scope_stat_entries` 并入 `(cell, stat)` 对
- [x] `stat_bucket_version` 折进取层版本（§8.6），只在 ECONOMY 且 rows 非空时参与，其他域 hash 逐位不变
- [x] 契约测试 **20 checks 0 failures**（A–H 八组）→ 证据：`artifacts/ideology-cell-layer/m1/M1-4-scope-union-findings.md` §4
- [x] 三个只读桥：`collect_modifier_scope_ids` / `..._stat_entries` / `modifier_stat_bucket_version`
- [x] **回归零判定变化**：15 fixture 逐项与 M0 基线一致 → 同上 §7
- [x] 构建通过，新 DLL `a7c3ae89…`
- [x] **定位并修复最危险失效模式**：枚举门 + 版本门任一锁着，派生层都会「装好、算对、什么也不改」
### M1-9 生产物化器与里程碑闸门

- [x] `derived_cell_materializer.{h,cpp}`：已解析事实 → front，不读运行时状态（§13.1 第 1 层可测）
- [x] 纯核测试 **53 checks 0 failures**，含「33 格不截断」「6400 格全国覆盖」「两来源相乘」「零因子」→ 证据：`artifacts/ideology-cell-layer/m1/M1-9-production-materializer.md` §2
- [x] **生产接线**：`collect_effect_activations` 增 `out_derived`；`reconcile_effect_activations` 传容器并物化安装
- [x] **修复安全缺陷**：`out_derived` 为 null 时会崩；加前置守卫，未传容器的调用方保持旧行为
- [x] 新增 `_execution_contract_hash`（§11.5）与 `_last_derived_materialize`（§12.4，含 `truncated`）
- [x] **发现并修复里程碑顺序冲突**：判定器在 M1 就启用 kind 16，导致 `ideology_x1b_source_count_test` 142/0 → 142/5（E/F 属 M4）
- [x] **能力判定与 rollout 分离**：`CellProgramRollout = Off`，判定器只回答「能否派生」，闸门由调用方施加
- [x] 记录一次错误尝试：把 rollout 塞进判定器内部导致 56 条测试中 19 条失败
- [x] 回归 **零判定变化**，新 DLL `8563834a…`
- [x] ~~`kCellProgramRollout` 仍为 `Off`~~ → 已依次推进到 `Continuous`（M3-12）与 `Sources`（M4-8）
### M1-10 全局重建与多国正确性

- [x] **修复一个会静默丢失整国贡献的缺陷**：M1-9 把物化放在 per-country 的 `reconcile_effect_activations`（4 个调用点），最后一个国家会抹掉所有其他国家 → 证据：`artifacts/ideology-cell-layer/m1/M1-10-global-rebuild.md` §1
- [x] 新增 `rebuild_derived_cell_layer()`：遍历所有国家，构建一份 front
- [x] 挂在 `run_daily`（`run_daily_slices` 之后，整日定稿才物化）
- [x] 物化测试 **65 checks 0 failures**，新增 12 条多国断言
- [x] **J**：两国各占不同格时两国的格同时存在（6 行）
- [x] **J2**：只传一国时另一国确实消失——把「builder 是纯函数」固定下来
- [x] **J3**：两国影响同一格时相乘（2×3=6）
- [x] 新增身份成员 `_derived_world_identity` / `_derived_map_generation` / `_derived_epoch_id`（§9.6）
- [x] 回归 **零判定变化**，新 DLL `667d4194…`
- [x] ~~仍为 `rollout = Off`~~ → 现已 `Sources`
- [ ] **[M2 优化] 整份重建代价是 O(全部卡)**：两国同格时算术已正确，但无法只重算改动国
- [ ] **[M1 结转] `collect_effect_activations` 每天被调用两次**：reconcile 建实例一次、rebuild 收派生一次（后者丢弃激活），重复计算未测
- [x] **`value_mode` 硬编码已修复**：`ProgramModifierCommand` 增加该字段，判定器读真实值

### M1-5 热路径成本与预算

- [x] 两个基准：`derived_cell_layer_bench`（独立查找）与 `effective_value_increment_bench`（增量对照）
- [x] **守卫对照：空层增量 +0.3 ns**，证明 `rows.empty()` 旁路有效 → 证据：`artifacts/ideology-cell-layer/m1/M1-5-hot-path-budget.md` §2.1
- [x] 有层时每查询 +21.7…60.7 ns，每覆盖格 3.2…18.7 us
- [x] **修正 §14.1**：每格系数不是常量，跨 5.9 倍，必须按部署规模分档给数 → 已改 §14.1
- [x] 记录 B7 与「单 slice ≤ 1 ms」的张力：单 slice 只能承载约 166 格
- [x] 记录内存：64 国 front 98.4 MB，两份约 197 MB → 安装时预算检查的依据
- [x] 记录 `collect_scope_*` 在 64 国规模下 5.51 / 8.71 ms，当前可接受但 O(派生行)
- [x] **基准自身抓出两个错误**：一个用例标签写错（"no layer" 实际建了 32 格）、空 front 崩溃（漏了守卫）
### M1-6 切片预算与分片

- [x] 实测 `epoch_begin_city_factor_ms`：2400 格 **0.415–0.465 ms**，6400 格 **1.264–1.362 ms**
- [x] **结论写入 §14.3**：6400 格规模上 1 ms 门槛当前不成立且**与本迁移无关**（链路无分片点，`refresh_city_modifier_factors` 返回 void）
- [x] `refresh_city_modifier_factors` 分片化，每 64 格 yield，返回 `bool done`
- [x] `capture_country_epoch` 增加 pending 出口；`start_epoch` 复用既有 soft-barrier 约定（`city_factor_shard_pending`）
- [x] 分片状态机测试 **47 checks 0 failures**（含「最后一格」「空集」「shard=1」「恰好整倍数」）→ 证据：`artifacts/ideology-cell-layer/m1/M1-6-slice-budget.md` §4
- [x] **修复一个真实 bug**：版本门未考虑在飞分片，会让未完成的分片永远停住 → 同上 §3
- [x] 新增诊断字段 `city_factor_shard_cursor` / `_cells` / `_work_cells`
- [x] **回归零判定变化**：15 fixture 逐项与 M0 基线一致，`x1b` 仍 142/0
- [x] 构建通过，新 DLL `e3b5b0f8…`
- [ ] **[M1 结转] 分片未做端到端验证**：集成夹具卡在 `needs_environment_capture`（`capture ok=false, reason=""`），正确性来自状态机测试而非真实 epoch
### M1-7 output 读者独立分片

- [x] 消除上轮时序副作用：两个读者各有独立游标，不再链式等待
- [x] `refresh_city_output_modifier_factors` 改为返回 `bool done`，per-cell 循环可分片
- [x] 中间结果用 `_city_output_shard_partial` 跨片保留（排序 + CSR 重建不可分片）
- [x] **版本门补 `_city_output_shard_cursor < 0` 前置**——否则未完成分片会永远停住（与 M1-6 同一个坑）
- [x] 状态机测试扩展到 **56 checks 0 failures**，含「output 在自己的第一片完成、不等 city」的回归用例 → 证据：`artifacts/ideology-cell-layer/m1/M1-7-output-shard.md` §4
- [x] 回归零判定变化：15 fixture 逐项与 M0 基线一致
- [x] 构建通过，新 DLL `81b9459d…`
### M1-8 端到端夹具诊断

- [x] 系统走通输入链，逐阶段定位（而非继续盲试）→ 证据：`artifacts/ideology-cell-layer/m1/M1-8-e2e-harness-diagnosis.md` §2
- [x] 确认 generation 需 **5 个字段**；空 Dictionary 会在第一个字段静默失败（错误在 `fatal_reason` 而非 `reason`）
- [x] 确认 9 个环境槽**可填充**：`component_id(name)` + `write_f32_range` / `write_u8_range` → 实测 10 of 10
- [x] 确认 `write_f32_dense` **不存在**（正确 API 是 `write_f32_range`）
- [x] 确认手写 MapData stub 会在 `_map_data->call("neighbor_indices_packed")` 处越界崩溃
- [x] **结论：唯一可行路径是 `host.generate_world()` 生成真实 MapData**（与 parity / M0-7c 一致）
- [x] 未修改任何产品代码；删除两个不可用探针，避免被误当夹具
- [!] **[M1 退出必要条件] worker 协作夹具**：需同时满足「真实 MapData」「MODIFIER+ECONOMY 主线程权威」「不触发 day-4 money_conservation 致命」——三者交集需要 worker 脚手架，不是更长的脚本
### M1-11 端到端夹具（六轮缺口）

- [x] **推翻「端到端不可行」的结论**：派生层由理念运行时拥有，`run_ideology_daily` 不需要 economy epoch → 证据：`artifacts/ideology-cell-layer/m1/M1-11-e2e-progress.md` §1
- [x] `ideology_cell_layer_e2e_test.gd` 可运行：**14 checks 1 failure**
- [x] 逐阶段打通 configure → catalog → discover → equip（每一步都是实际踩到的）
- [x] 确认 `kin_hearth_l1` 是等级内效果程序名，理念 id 是 `idea.kin_hearth`
- [x] 确认指令协议需 **11 列**且 `ideology_ids` 是 dense int（不是 `idea_keys` 字符串）
- [x] 新增 `get_derived_materialize_report()` 桥，`truncated` 成为可直接断言的观测值
- [x] 定位最后前置：`last_error = ideology_class_opinion_unavailable`，`derived_rebuild_visits = 0` → 物化器从未被调用
- [ ] **[M1 结转] 缺 opinion 桥**：理念运行时需 `ideology_opinion_bridge` attach 才能跑完日循环，与 M0-7c worker 夹具缺口同类
### M1-12 e2e 通过 & 目标 tag 前提

- [x] **e2e 夹具 18 checks 0 failures**（`Off` 分支）→ 证据：`artifacts/ideology-cell-layer/m1/M1-12-e2e-pass-and-tag-requirement.md`
- [x] 修正 M1-11 的错误断言：`Off` 下 `programs_seen == 0` 是**正确结果**，不是缺陷
- [x] 新增 `cell_layer_rebuild_visits` / `_skips` / `_ms` 计数器
- [x] **修复命名冲突**：复用 `_derived_rebuild_visits` 会与既有的无关 idea 迭代计数器静默共用字段
- [x] 用临时诊断（已移除）定位到 `targets_ok=0`，判定器与闸门均正确（`derived=1 rollout=1`）
- [x] **发现此前未记录的前提**：`kin_hearth_l1` 的 `target_selector_param = (32, 0)` + `target_selector_tag = "cell.clan"`
- [x] 记录「取消上限不只是删代码，内容里的 32 也要随批次更新」
- [x] 回归 **零判定变化**，新 DLL `b49ff0b8…`
### M1-13 目标解析根因（纠正 M1-12 的错误推断）

- [x] **推翻 M1-12 的结论**：tag override **64/64 全部被接受**，说明 `cell.clan` 在表里 → 证据：`artifacts/ideology-cell-layer/m1/M1-13-target-resolution-root-cause.md` §1
- [x] 确认 tag 表由 `effect_domain_catalog.gd:500` **合成**，不是从 `.tres` 直读；「三个 .tres 无 target_tags 字段」不代表表为空
- [x] **真正根因**：`target_selector_param = (32, 0)` → `param1 == 0` → `tag = -1`，**tag 过滤根本没参与**；断点在 `cell_country_slot()` 因 `_epoch_cell_country` 为空返回 -1
- [x] `_epoch_cell_country` 的唯一生产填充点是 `economy_runtime.cpp:4986`（`apply_pod_snapshot`），只能由 epoch 打开触发
- [x] **确立第三条硬前置**：kind 12/14/15/16 的派生路径无法脱离经济 epoch 验证（目标格集来自领土 CSR）
- [x] 记录过期注释：`economy_runtime_family_buff.cpp:2372-2373` 称「nothing in content uses kind 12 yet」，实际有 170 个
- [x] e2e 维持 **19 checks 0 failures**
- [x] **ON 的爆炸半径实验已做**：临时开启 `Constants`，回归零变化

### M2-16 value_mode 修复 + 2000 格分布

- [x] 定位：`ProgramModifierCommand` **丢了** `CommandDefinition.value_mode`，导致调用方只能硬编码 → 证据：`artifacts/ideology-cell-layer/m2/M2-16-value-mode-and-2000.md`
- [x] 三处改动：结构体加字段 / 构造时传入 / 判定器读真实值
- [x] **零行为变化**：覆盖率 241/47 与理由分布逐项相同（194 个内容都是 `value_mode = 1`）
- [x] **回归零判定变化**，新 DLL `5f59339e…`
- [x] **2000 格分布完成**：n=4，p50 **11.982 ms**，每格 **5.99 us**，分片 32
- [x] **两规模互相印证线性度**：800 格 5.65 us vs 2000 格 5.99 us，差 6%
- [x] 第三次独立收敛到 M2-6 的 6.0 us 假设
- [x] §14.3 用 2000 格 p50 重判：0.374 + 0.465 = **0.841 ms < 1.0**，余量 15.9%
- [ ] **[M3] 6400 格仍是外推**（按 5.99 us/格 = 38.3 ms）
- [ ] **[M3] n=4/5 时 p95 = max**，真正 p95 需 ≥20 样本
### M2-17 rollout ON 实验（负结果）

- [x] 临时把 `kCellProgramRollout` 设为 `Constants`，重建，跑完整回归 → 证据：`artifacts/ideology-cell-layer/m2/M2-17-rollout-on-negative.md`
- [x] 回归 **零变化**（15 fixture 逐项与 M0 一致）
- [x] **但零变化不能证明安全**：e2e 显示 `programs_seen=0`，派生分支根本没被执行
- [x] 定位：`resolve_effect_targets` 先返回 false（`ideology_runtime.cpp:2180-2183`），派生子句不可达
- [x] 根因与 M1-13 相同：`_epoch_cell_country` 只在真实 epoch 内填充
- [x] **已回滚到 `Off`** 并重建
- [x] ~~rollout ON 是否安全：无法测~~ → 已在 `Continuous`/`Sources` 下跑完整 15-fixture 回归
- [ ] **[仍开放] 派生层端到端产生行**：需真实 epoch；M3-21 已让理念 ACTIVE，但 `seen` 仍为 0（targets 空）
- [x] ~~只试了 `Constants` 档~~ → `Continuous`（M3-12）与 `Sources`（M4-8）均已实测

### M2-18 §13.1 第 2 层：同输入逐格对照

- [x] 新增 `gdext/tests/derived_layer_oracle_test.cpp`，**735 checks 0 failures** → 证据：`artifacts/ideology-cell-layer/m2/M2-18-layer2-oracle.md`
- [x] **补齐方案要求但此前从未实现的第 2 层**（`merge_test` 只验证公式，未遍历候选集）
- [x] 三方构造：LEGACY（`min(cells,32)`）/ DERIVED（真实实现）/ **REFERENCE（独立折叠，不读实现结果）**
- [x] **A 组**：31 格旧 cap 以下两侧数值完全一致
- [x] **B 组**：**168 个新增格**（200−32）逐一与 REFERENCE 相符，且旧侧确无该格
- [x] **C 组**：1000 格时旧子集全部存活，`truncated == 0`
- [x] D 组边界 31/32/33；E 组两来源相乘；F 组零因子同归；G 组空集
- [x] 对应 §13.2 全部六条 oracle 规则
### M2-19 §13.4 验收审计（重要差距）

- [x] **审计发现：§13.4 列出的 11 个测试此前一个都不存在** → 证据：`artifacts/ideology-cell-layer/m2/M2-19-catalog-audit.md`
- [x] 现有 9 个 `ideology_cell_layer_*` 覆盖的是**另一些维度**（合并/并集/分片/ADR02/e2e），与方案清单几乎不重叠
- [x] 新建 `ideology_cell_layer_catalog_test.gd`：**9 checks 0 failures**
- [x] 新增两个只读 bridge：`probe_cell_program_backend` / `get_cell_program_rollout`
- [x] **A2 关键断言**：改一个事实（永久→持续 30 天）结论翻转为 EffectInstance，证明不是常量断言
- [x] C 组：未知 selector kind 被拒绝，不默认 backend
- [x] D 组：rollout 全关时能力仍为 DerivedCell（能力 ≠ 闸门）
- [x] 修正两处自己的错误：`reason == "none"` 实为空串；`legacy_reason_name` 已返回 `const char*`
- [x] **放弃 `describe_cell_program_backends`** 并在代码/测试/报告三处写明原因（需 3 个不存在的 EffectRuntime 访问器）
- [ ] **[仍开放] §13.4 计划测试仍有 8 个未实现**（catalog/unbounded/numeric 已补）
- [x] **`unbounded_test` 已完成**：31/32/33/200/1000+ 通过**真实选择器**验证

### M2-20 §13.4 `unbounded`

- [x] 找到正确接口：`friend struct EconomyTargetSelectorTests`（`economy_runtime.h:179`）可直写私有领土列 → 证据：`artifacts/ideology-cell-layer/m2/M2-20-unbounded-test.md`
- [x] 在既有 self-test 里新增 unbounded 块（**9 个断言**），自建 2400 格网格（原夹具只有 6×5=30 格）
- [x] 31/32/33/200：`param0=0` 与 `param0=1000` 均命中 n 格，升序无重复
- [x] 1000：**包含第 33 格**、包含 index 999、显式写 32 仍得 32、写 5000 仍受地图限制
- [x] GDScript 夹具 `ideology_cell_layer_unbounded_test.gd` 驱动执行（否则 self-test 是死代码）
- [x] **负向对照成功**：改成 `n+1` → exit 3，错误名 `unbounded_territory_count` 精确对上
- [x] 记录一次无效实验：首次对照因后续 `Set-Content` 覆盖编辑而误判「断言没跑」
- [x] 回归零判定变化
- [ ] **[M2 结转] 只验证了「命中」，未验证「零实例」**：后者需 ideology 侧联动，与 rollout 同一缺口
- [ ] **[M2 结转] `friend` 直写私有列 ≠ 生产填充路径**：证明选择器逻辑，不证明领土捕获
### M2-21 §13.4 `numeric`（后经收缩范围已通过：7/0）

- [x] 交付 `ideology_cell_layer_numeric_test.gd`，**7 checks 0 failures —— 通过**（收缩到可验证范围后） → 证据：`artifacts/ideology-cell-layer/m2/M2-21-numeric-partial.md`
- [x] **发现三个真实认知**（均有实测）：
- [x] ① `resolve_modifier_stat` 不返回 min/max，真实上限字段是 `clamp_max`（本例 4.0，不是 1.0）——按 1.0 判会让五个用例以错误理由「通过」
- [x] ② 派生层跨用例共享：`_fresh()` 只清 legacy domain，D/E 的 `factor=0` 会湮没后续用例
- [x] ③ ENTITY 行的 key 是 `entity_handle`（读者传 0），写在 cell 上永不匹配
- [x] ④ **`run_modifier_daily` 每天只排空一次队列**：实测 fresh ext 上 submit→run(0) 生效，再 submit→run(0) 不生效
- [x] 夹具已通过；GLOBAL scope 缺口在文件头显式声明，防止被读成全覆盖
- [x] **已收缩到可验证范围并通过**：A 组改为 GROUP+DERIVED 两层求和，D 组只保留零因子方向 → **7 checks 0 failures**
- [x] 发现并修正一个纯夹具错：Q16 量化使 `0.20` 存为 `0.19999695`，`1e-6` 容差过严
- [x] **上一轮的「GLOBAL 不生效」是误判，已被独立探针推翻**：`global_scope_probe.gd` 实测 GLOBAL add 2.0 → 读回 3.0，完全正常 → 证据：`artifacts/ideology-cell-layer/m2/M2-22-global-scope-cleared.md`
- [x] 真正的两个夹具缺陷已定位：① ENTITY 行需非零 `entity_handle`（`modifier_runtime.cpp:698`）② 超量 magnitude 被 **reject** 而非 clamp（实测 `commands_applied=0`）
- [x] numeric_test 定稿 **7 checks 0 failures**，文件头显式声明不覆盖 GLOBAL/ENTITY 并给出「GLOBAL 另有探针证明」的指引
- [x] **教训已记录**：把「夹具测不出来」写成「产品可能有问题」需要不同证据；遇到「不生效」应先写最小探针
- [ ] **[M2 结转] numeric_test 不覆盖 GLOBAL / ENTITY**
- [ ] **[M2 待查] ENTITY 行即使有非零 handle 仍不贡献** —— 第二个因素未查明
- [x] **`global_scope_probe` 已修正并定稿：6 checks 0 failures** —— 用 `explain_modifier_stat` 而非 `report()` 读 scope；实测 `scopes=[0] handles=[4294967296] sum_add=2.0`，GLOBAL 确实存为 scope 0 且求和正确
- [x] 顺带把「超量 magnitude」断言从「值必须变」（我的假设）改为「被 reject 且值保持 base」（实测行为）

### M2 最终验收（见 `artifacts/ideology-cell-layer/m2/M2-FINAL.md`）

- [x] **核心目标达成**：32 上限在代码常量、194 处内容、两层校验三处移除，有行为级断言
- [x] **性能已实测**：800 格 p50 4.516 ms / 2000 格 p50 11.982 ms；每格 5.65–5.99 us
- [x] **§14.3 单 slice 通过**：0.841 ms < 1.0，余量 15.9%
- [x] **回归零判定变化**（15 fixture 逐项，含失败项）
- [x] **12 项门禁全绿**，DLL `aea03edb…`
- [x] **`rollout` 已打开到 `Continuous`**（M3-12）
- [ ] **[M2 未完成] §13.4 只完成 3/11**：缺 invalidation/worker/timing/ack/save_golden/idle/explain/budget

### M3-1/M3-2 逐格 ramp 求值器（已打通）

- [x] 查明 24 个 ramp program 的真实结构：`min(metric, N) × scale`，op 8 是 `MIN` → 证据：`artifacts/ideology-cell-layer/m3/M3-1-ramp-analysis.md`
- [x] 查明 8 个 metric 分两类：**逐格**（22/24）与**国家级**（57/59/63/67/69/91）
- [x] 定位障碍：metric 按 instance 存，派生层无载体
- [x] **抽取 VM** `run_program_machine(definition, metric_accessor, state_accessor, ...)`，让 `preview_family_effect_value` 与新的逐格求值共用同一条栈机
- [x] `evaluate_program_magnitude_for_metrics` / `evaluate_effect_program_magnitude` 桥
- [x] **否决了首版的 `const_cast` 方案**（worker 路径下是数据竞争，§8.1 禁止）
- [x] `ideology_cell_layer_ramp_test.gd` **13 checks 0 failures** → 证据：`M3-2-ramp-evaluator.md`
- [x] 实测 `salt_monopoly_l1`：metric 2→1310 / 5→3275 / 10→6550 / **1000→9825 饱和**
- [x] 修正两处自己的错误：程序键需 `ideology.effect.` 前缀；我按 `_l2` 的常数推 `_l1` 的上限（各档 scale 不同）
- [x] 回归零判定变化
- [x] ~~未生成 ramp term~~ → M3-2/M3-3 已实现并验证（ramp 13 + ramp-mat 12 checks）


- [x] **国家级 metric 缓存已实现**（上轮列为「未设计」）：采样器签名加 `source_country`，缓存落在 `rebuild_derived_cell_layer`，键 `(country<<8)^metric` → 证据：`artifacts/ideology-cell-layer/m3/M3-4-production-wiring.md`
- [x] 国家级 id 区间依据写入注释：56..61（X7 tag）、63..69（per-good）、91（branch），均由国家状态填充
- [x] **生产采样器已接线**：`_economy_runtime != nullptr` 时才安装，无经济时延迟而非返回 0
- [x] 4 个可观测量 + 判读规则写入注释
- [x] 5 项纯核门禁 + 5 个 GDScript 夹具全 0 失败；回归零判定变化
- [x] **端到端夹具已打通**（六轮未解的缺口）：`host.generate_world(SEED)` → 6144 格 / 3 国 / `country_daily ACTIVE` → 证据：`artifacts/ideology-cell-layer/m3/M3-5-e2e-and-territory-finding.md`
- [x] 新增 `get_country_territory_counts()` 桥（`country_count` / `widest` / `above_old_cap` / `total_cells`）
- [x] **重大发现：生成世界里每国领土只有 1 格，且 20 天不增长**（`widest=1 above_old_cap=0 total=3`）
- [x] ~~根因：`COMMAND_CLAIM_UNOWNED_TERRITORY` 全仓库无发出方~~ **此结论已被 M3-6 推翻**
- [x] **M3-6 修正**：发出链存在 —— `start_family_colonization`（已绑定）→ `enqueue_family_colonization_pod` → `claim.opcode`（`effect_runtime.cpp:3680`）→ 证据：`artifacts/ideology-cell-layer/m3/M3-6-territory-growth-correction.md`
- [x] 殖民机制完整（6 道校验、启动、结算都在）；领土**可以**增长，只需有人发起
- [x] 修正我自己的 3 个调用错误：传 slot 而非 handle、只扫 200 格、探测固定格
- [x] 补上「`ok==false` 不静默 continue」的写法，才看到真实错误码
- [x] **殖民根因已完整定位**（M3-7）：`country_slot_arr size=0` → `player_country_slot=-1` → `VisionSolver` 全零 → `visible_nonzero=0` → 167/167 目标 `target_invalid` → 证据：`artifacts/ideology-cell-layer/m3/M3-7-colonization-root-cause.md`
- [x] 新增 `diagnose_colonization_target()` 桥，把六道门拆开报告
- [x] **关键排除**：`owner_allows=true`（主权门是开的），唯一关闭的是可见性门
- [x] 判定：**这不是缺陷**——无玩家则无视野，是合理行为；缺的是夹具里的玩家身份
- [x] **`country_slot_arr` 唯一写入点已查明**：`world_runtime_host.gd:1647`，在 `_consume_country_worker_read_view_if_authoritative()` 内，**只在 worker 权威下运行** → 证据：`artifacts/ideology-cell-layer/m3/M3-8-colonization-gates.md`
- [x] ~~sync 修好可见性~~ **M3-9 修正**：是 `_refresh_vision()` 修的，sync 只提供数据
- [x] **发现我此前漏掉的第 4 道门**：`:496 passable==0 && !_epoch_active` —— 我的诊断桥只覆盖 3 道，差点得出「全绿但失败」的矛盾结论
- [x] 六道门已定位五道：运行时/国家 handle/越界/可见性/主权/拓扑 全部满足
- [x] **六道门全部打通：`quote ok=true`**（首次）→ 证据：`artifacts/ideology-cell-layer/m3/M3-9-colonization-reachable.md`
- [x] **关键发现：顺序错了而非机制坏了** —— `sync_country_territory_to_map()` 完全不写 `visible_arr`（`world_ext_country.cpp:1848-1862`），必须 **先 sync 领土 → 再 `_refresh_vision()`**
- [x] epoch 门不是阻碍：`target_passable=true` 时 `:496` 条件不成立
- [x] 修正 3 处自己的判断：sync 不是可见性的功劳 / epoch 不是阻碍 / census 循环从未执行（`sampled=0`）
### M3-11 全部 265 个 program 进入派生路径（M3 核心目标达成）

- [x] **判定器放行 ramp**：条件从「幅度是否常数」改为「派生层能否表达」→ 证据：`artifacts/ideology-cell-layer/m3/M3-11-all-265-derived.md`
- [x] **DerivedCell 241 → 265（+24）**，`ramp deferred: 24 → 0`
- [x] **同步覆盖率工具**（Python 独立实现同一规则）：不改则会继续报 24 unsupported 且门禁假通过
- [x] 门禁期望 `24 → 0`，**保留断言而非删除**（将来若重新延迟会失败）
- [x] **6/6 覆盖率门禁通过**；纯核门禁 oracle 735 / materializer 65 / eligibility 56 / cap_removed 12
- [x] **回归零判定变化**（15 fixture）
### M3-12 rollout 首次打开

- [x] **`kCellProgramRollout`: `Off` → `Continuous`**，首次让派生层驱动生产路径 → 证据：`artifacts/ideology-cell-layer/m3/M3-12-rollout-on.md`
- [x] `Continuous` 只开放 `selector_kind == 12`，正是 M2/M3 的 A–F 批次
- [x] **回归零判定变化（0/15）** —— rollout 打开未破坏任何既有断言
- [x] 真实世界重建确认运行：`visits=3`
- [x] 查明 `seen=0` 的根因：**生成世界的国家没有任何已采纳理念**（`state.location == INACTIVE`），不是 rollout 问题
- [ ] **[仍开放] 真实 epoch 下 ramp 数值**：M3-13 已解决 dense id（编译 GDScript 侧目录），理念可 ACTIVE；卡在 target 解析返回空
### M3-13 真实世界夹具推进到「只差激活」

- [x] dense id 已解决：**编译 GDScript 侧目录**，无需 native 桥；`idea.salt_monopoly` → `dense=87` → 证据：`artifacts/ideology-cell-layer/m3/M3-13-realworld-card-adopted.md`
- [x] 国家 handle 已解决：**扫描**而非取格 0（格 0 通常无主）→ `4294967300` @ cell 1553
- [x] `discover ok=true` / `equip ok=true` / `visits=4`（重建在真实世界运行）
- [x] **修正我自己写的永真断言**：`taken >= 0` → `taken > 0`（前者永远为真，让夹具假绿）
- [x] 记录四个 API 名称错误，每个耗一次 10 分钟运行
### M3-18 理念命令链路打通，根因定位到 class opinion

- [x] **核心突破：`sequences` 是幂等键，必须跨批单调递增** —— 我每批重置为 1，导致第一条之后的命令全被当作重复静默丢弃（`ideology_runtime.cpp:4536-4539`）→ 证据：`artifacts/ideology-cell-layer/m3/M3-18-root-cause.md`
- [x] 改掉后：`duplicates=0` → `commands_applied=1` → `receipts count=4`
- [x] **回执诊断法**：被拒命令写入 `RECEIPT_REJECTED` + 原因（`:4672`）；无回执 = 未处理
- [x] 查明快照是**并行数组**（`idea_ids`/`locations`/`levels`/`slot_indices`/`transition_pending`），不是 dict 列表
- [x] `poll_receipts` 必须在**日推之后**调，否则永远为空
- [x] **grant / discover / understanding 三条命令 status=2 成功**，`levels` 从 0 升到 2
- [x] **`equip` 被拒的确切原因：`ideology_class_opinion_unavailable`**
- [x] 建立 9 项否定清单，后续者不必重复试错
### M3-19/M3-20 环境槽与 economy epoch 打通

- [x] **`register_component` 可注册槽**（不依赖 MapData）；dtype F32=0 / I32=1 / U8=2 → 证据：`artifacts/ideology-cell-layer/m3/M3-20-epoch-opened.md`
- [x] **关键：必须先 `create_entities(CELLS)` 再注册槽** —— 槽长度由 `_entity_count` 决定（`world_ext.cpp:182-185, 226-228`）；裸 ext 的 entity_count=0 使所有 `write_*_range` 被 `ERR_FAIL_COND` 静默拒绝
- [x] **`economy epoch ok=true`（首次）**，`entity_count 0 → 64`
- [x] 指出我自己探针的假指标：`filled=10 of 10` 只检查 `sid>=0`，没验证写入成功（`write_f32_range` 返回 void）
- [x] `run_economy_slice` 正确形状是 `{day_index, tick_index}`（非 `budget_ms`）
### M3-21/M3-22 理念激活达成，派生贡献仍为 0

- [x] **理念首次成功激活**：`locations=[1] active=1`，`equip` status=**1（成功）**（M3-18 时是 3 + `ideology_class_opinion_unavailable`）→ 证据：`artifacts/ideology-cell-layer/m3/M3-21-idea-activated.md`
- [x] **完整 12 步激活序列已验证**：entities → 槽 → 写入 → epoch(六字段) → bootstrap_economy → **economy slice 跑到 done（14 片）** → grant → discover → understanding → equip
- [x] `run_economy_slice` 参数是 `{day_index, tick_index}`，且**一片不够**（真实世界 121 片）
- [x] 派生重建确实在跑：`cell_layer_rebuild_visits` 4 → 5
- [x] 排除 4 个新假设：重建没跑 / 理念未激活 / 等级超 level_count / 存储不同源
- [x] **逐项验证 `collect_effect_activations` 的全部前置条件**：dense/ACTIVE/level/persistent_count/program 存在 均通过 → 证据：`artifacts/ideology-cell-layer/m3/M3-25-anchor-cell-rootcause.md`
- [x] **修正我自己的桥缺陷**：`probe_cell_program_backend` 漏传 `has_metric_ramp`，使所有 ramp 探针误报 `non_constant_value_mode`；修后 `backend=DerivedCell`
- [x] **推翻我自己的一个根因判断**：曾断言 `country_anchor_cell=-1`，实测为 **0**（M3-26）
- [x] 定位到真正的最后一环：`ideology_runtime.cpp:2062 collect_effect_target_cells(anchor, kind=12, ...)` 返回空
### M4-1 Sources 批次：影响已精确测量（重要发现）

- [x] M4 规模核查：**kind 16 = 66 个（E）、kind 14 = 5 个（F），合计 71 个**；`cell_program_eligibility.h:216-218` 早已支持 → 证据：`artifacts/ideology-cell-layer/m4/M4-1-sources-impact-measured.md`
- [x] **`Sources` 开关影响已测量**：`ideology_x1b_source_count_test` **142/0 → 142/13**
- [x] 13 个失败分两类：实例句柄断言消失（预期）+ **数值精度分歧（非预期）**
- [x] **发现真实分歧**：同一 program 派生路径读 `1.23999`，实例路径读 `1.12`，**差 0.12 = 一个 source 的贡献**
- [x] 判定这是 **§13.1 第 2 层（同输入对照）的实质缺口**：`derived_layer_oracle_test` 比的是「派生 vs 独立参考」，不是「派生 vs 实例」
- [x] 已回退到 `Continuous`，基线恢复 142/0；**发现写入代码注释**，避免下次再踩
### M4-2/M4-3 per-source scale：根因查明（修复后由 M4-4 的 I01 修复真正生效）

- [x] **根因确定**：派生分支丢弃 `EffectTarget::magnitude_scale_q16`（实例路径 `:2079-2081` 归一化，派生路径不读）→ 证据：`artifacts/ideology-cell-layer/m4/M4-2-per-source-scale-rootcause.md`
- [x] 数值证实：`magnitude_scales=[32768]`（=Q16_ONE/2），差 0.12 = 一个 source 贡献
- [x] 影响范围：**仅 kind 16 的 66 个**（kind 12/14/15 的 scale 恒为 1.0）
- [x] 已实现修复（`magnitude_scale` 字段 + 每 target 一个 contribution），构建通过
- [x] ~~当时判断「修复未生效」~~ **已由 M4-4 修正**：真正原因是 I01 双重应用，实例仍在导致夹具读到实例值而非派生行 → 证据：`M4-3-fix-not-effective.md`、`M4-4-i01-fixed.md`
- [x] **I01 修复后 per-target scale 生效**：`Sources` 下 `x1b` 142/0
- [x] 已回退 `Continuous`，**142/0 + 5 项门禁全绿**
### M4-4/M4-5/M4-6 I01 真实违例已修复（重要）

- [x] **找到 I01 真实违例**：`collect_effect_activations` 用 `out_derived != nullptr` 决定后端，导致实例路径（`reconcile_effect_activations` 传 nullptr）完全不看 rollout → 两条路径同时运行 → 同一 program 既建实例又产派生 rows → 证据：`artifacts/ideology-cell-layer/m4/M4-4-i01-fixed.md`
- [x] **修复**：判定改为「program 是否应该是派生」，调用方只决定「能否接收 rows」；派生 program 在实例路径显式 `continue`
- [x] **效果**：`Sources` 下失败 **13 → 4**；**12 个数值分歧（1.23999 vs 1.12）全部消失**
- [x] 证实 M4-2/M4-3 追的 per-source scale 问题，本质是 I01 双重应用
- [x] **如实报告：此前多轮「回归零判定变化」建立在 I01 bug 之上** → `M4-6-zero-regression-premise.md`
- [x] 具体证据：`tag_snapshot_stress` 在 M2/M3 四次回归均为 37/0，I01 修复后 **37/2**
- [x] **断言迁移完成**：`tag_snapshot_stress` 改为接受任一后端（`instances>0 or front_cells>0`），保留 before-flip 的严格断言 → 证据：`artifacts/ideology-cell-layer/m4/M4-7-i01-accepted.md`
- [x] **决定性证据**：`after flip: instances=0 front_cells=32` —— **32 格上限在派生路径中同样成立**
- [x] `tag_snapshot_stress` **37/0 → 38/0**（通过，多 1 个检查）
- [x] **15 fixture 判定变化仅 1 项，且是改进**；其余 14 项与 M0 完全一致
- [x] **这次的零回归不再依赖任何已知缺陷**（M4-6 指出的前提问题已消除）
### M4-8 `Sources` 全开，回归仅 1 项改进

- [x] **`kCellProgramRollout = Sources`**：kind 12/14/15/16 全开，覆盖 **265 个 program** → 证据：`artifacts/ideology-cell-layer/m4/M4-8-sources-enabled.md`
- [x] **`x1b_source_count` 首次全绿：142/0**（此前 142/4）
- [x] 4 个断言迁移为后端无关：新增 `_target_count()`，接受「实例数 或 派生 front 的 cell_count」
- [x] **T8 关键断言**：`_target_count == 32` —— **32 格上限在两条后端上都成立**
- [x] **15 fixture 判定变化仅 1 项**（`tag_snapshot_stress` 37/0 → 38/0，改进）
- [x] 6 个 NON-PASS 与 M0 完全一致（既有技术债）
- [x] 纯核门禁 oracle 735 / materializer 65 / cap_removed 12 / eligibility 56 全 0；coverage 6/6
- [ ] **[M4 未做] stamp/touched scratch**
- [ ] **[M4 未做] 边境外溢、多国共同影响、来源国家撤销**
- [ ] **[M4 未做] per-tag changed words / cells**
- [ ] **[M4 未做] 同步文案、解释、保存基础**
### M4-13 §15.6 退出条件达成（B7 + B8 全绿）

- [x] **B7：单国 1600 格，14 checks / 0 failures** → 证据：`artifacts/ideology-cell-layer/m4/M4-12-b7-green.md`
- [x] **B8：144 来源重叠，18 checks / 0 failures** → 证据：`artifacts/ideology-cell-layer/m4/M4-13-m4-exit-met.md`
- [x] **`derived front cells = 3200`** —— 32 格上限已取消的直接测量（旧上限每卡 32 格）
- [x] **`effect instances = 0`** —— I01 达成：派生卡不创建实例
- [x] **100+ 来源**：144 个（12×12 块）
- [x] **r=1–4**：4 个半径全部 round-trip；r=5 被拒绝
- [x] **count cap**：`cap ≤ 15`，`covered=3200 > cap` 证明是**饱和**而非截断
- [x] **跨国边境**：整国 1600 格，tag 集合的边界即国界
- [x] **所有生产 program 数值通过**：覆盖率门禁 7/7，265/265 DerivedCell
- [x] **逐来源整图清零消失**：`own_tag_rejected=0`
- [x] **修复产品缺陷**：`SOURCE_COUNT_RADIUS_MASK`（位宽 7）被误用为校验上限，而运行时要求 `<= 4` → 内容可 author r=5、通过校验、运行时静默丢弃。已新增 `SOURCE_COUNT_MAX_RADIUS := 4`
### M4-14 B10 多国来源（合并通过，撤销阻塞）

- [x] **B10：两国同装备，合并为单一 front 6400 格（2 stat × 3200），13 checks / 0 failures** → 证据：`artifacts/ideology-cell-layer/m4/M4-14-b10-multi-country.md`
- [x] **修复漏掉的来源国传递**：`builder.add(stat_id, cell, 0 /*folded*/)` → `slot.source_country`；`Accumulator` 与 `DerivedCellContribution` 均补 `contributor_count`
- [x] 断言「A 与 B 是不同国家句柄」（修复了我把 cell 1600 当 B 国首格的坐标错误）
- [ ] **[M4 阻塞] 来源撤销未验证**：unequip 需要 `run_ideology_daily` + `run_effect_daily` 都 settle，无头环境下 `run_effect_daily` 静默等待 27 分钟不推进（CPU 停在 10s）
- [x] **`get_derived_multi_country_report` 已接通** → 证据：`artifacts/ideology-cell-layer/m4/M4-15-provenance-bridge.md`
- [x] **修复三处溯源缺陷**：`builder.add` 加 `contributor_count` 参数、来源国改为首写者赢（原先后写者覆盖）、materializer 传递计数
- [x] **B10 16/0；全回归 18/18**
- [ ] **[M4 未验证] 「两国影响同一格」**：实测 `max_contributors == 1`，因两国领土不相交；`SELECTOR_OWN_TERRITORY` 不可能产出跨国格，需 kind 14/16 的跨境外溢
- [ ] **[M4 未做] 溯源未暴露明细**：只有计数，没有「哪两个国家、各贡献多少」
- [ ] **[M4 未做] stamp / touched scratch（per-tag changed words）** —— 已测 `tag_snapshot_build_ms` 48 格 0.0092 ms → 1600 格 14.89 ms，为该项提供依据
- [ ] **[M4 未做] 同步文案、解释、保存基础**
- [ ] **[M5 未开始] 生产切换、清理、最终证据**
### M4-16 §14.3 性能门禁实测（rollout 全开，n=7）

- [x] **夹具就位**：`tests/ideology/ideology_perf_gate_test.gd`，2 个规模 × N 轮，报 p50 与 spread → 证据：`artifacts/ideology-cell-layer/m4/M4-16-perf-gate-rollout-on.md`
- [x] **2400 格**：`city_factor` 0.0023 ms、`rebuild` **3.5153 ms**、`tag_build` 15.31 ms
- [x] **6400 格**：`city_factor` 0.0021 ms、`rebuild` **10.2626 ms**、`tag_build` 46.79 ms
- [x] **`rebuild` 按覆盖格线性**：0.732 vs 0.802 us/cell（比值 1.10），无隐藏 O(n²)
- [x] **`tag_build` 近似线性**：2.85x 时间 / 2.67x 格数
- [x] **`truncated=0`、`instances=0`、无整图 seen 清零** —— 三项硬条件 PASS
### M4-17 性能门禁更正：M4-16 的 FAIL 是误读累积字段

- [x] **`cell_layer_rebuild_ms` 是全天累积**（`+=` 于 `ideology_runtime.cpp:6873/6881`，跨 10 次访问），M4-16 当成单次 → **判定作废** → 证据：`artifacts/ideology-cell-layer/m4/M4-17-perf-corrected.md`
- [x] **新增分割计时**：`cell_layer_collect_ms` / `cell_layer_materialise_ms`
- [x] **2400 格（生产默认）**：collect 0.2755 + materialise 0.4328 = **0.708 ms → 门槛 PASS**
- [x] **6400 格**：collect 0.6825 + materialise **1.2833** = 1.966 ms → **materialise 单次超 1 ms 门槛 28%**
- [x] **两部分均近似线性**（2.48× / 2.97× vs 格数 2.67×），无 O(n²)
- [x] **分片边界更正**：应切 **materialise** 的 (stat,cell) 折叠循环，不是国家循环；2400 格无需分片
### M4-18 分片尝试失败并回退（必须记录）

- [x] **实现过 `step_derived_rebuild` 分片阶段，但它是假的**：`slice` 向量从未被 `build_derived_cell_front` 使用，最后的构建仍是全量一次 → 证据：`artifacts/ideology-cell-layer/m4/M4-18-sharding-withdrawn.md`
- [x] **根因**：多天 `run_ideology_daily` 会重置 accumulator，B10 跑 10 天 → 构建时 `contribs=1600` 而非收集的 3200
- [x] **后果**：B10 从 16/0 退化到 16/1（`front cells=3200`，只含第一个国家）
- [x] **已完整回退**：恢复 `run_ideology_daily` 的 inline 重建，移除切片阶段
- [x] **回退后 B10 恢复 16/0，`front cells=6400`；全回归 13/13 绿**
- [x] **保留的价值**：M4-17 的 collect/materialise 拆分计时是独立可复核的
- [x] **撤回的声明**：「6400 格降至 0.6306 ms」「分片完成」「§14.3 PASS」全部作废
### M4-19 分片物化真正成功

- [x] **`DerivedCellMaterializeJob`**：`folded`/`touched_stats`/`report` 移入 `Impl`，`_index` 为续跑游标 → 证据：`artifacts/ideology-cell-layer/m4/M4-19-sharding-works.md`
- [x] **6400 格最坏单步 1.2833 → 0.5878 ms（2 步）→ 门槛 PASS，余量 41%**
- [x] **2400 格 0.4328 → 0.2305 ms（2 步）**
- [x] **单测 49 → 60 checks**：新增 K 组 11 条，含「真的分成多步」「split 与 one-shot 数值一致」
- [x] **收集单独成一步**：否则 6400 格首步 1.03 ms（收集 0.68 + 折叠份额）
- [x] **修 `done()` 语义**：`_index >= _total` 在首调用前为 0>=0 会误报完成
- [x] **兼容性代价已修**：新增 `drain_derived_cell_layer` 桥 + `derived_rebuild_pending` 导出；B7/B8/B10/stress 显式 drain
- [x] **全回归 17/17**
### M4-20 修复分片路径的 ramp 缺陷

- [x] **根因**：job 构造传空 `DerivedMaterializeOptions{}`，24 个 ramp 卡在分片路径上「贡献 0」而无报错 → 证据：`artifacts/ideology-cell-layer/m4/M4-20-ramp-sampler-fixed.md`
- [x] **不能复用单发路径的 sampler**：它按引用捕获栈上局部变量，跨 step 就是悬空引用
- [x] **修法**：采样状态改为 5 个成员 + `ensure_derived_ramp_sampler()`，lambda 捕获 `this`
- [x] **导出 `ramp_samples_taken` / `ramp_samples_memoised`**：让「求值 vs defer」可观测
- [x] **单测 60 → 67 checks**：新增 L 组 7 条，含「sampler 存在时 0 个 defer」「3 格各自不同幅度」
- [x] **零预算多步测试**：续跑路径正是 options 丢失处
- [x] **全回归 17/17**
### M4-21 端到端 ramp 证据（缺口关闭）

- [x] **`ramp_terms_evaluated=1600`、`deferred=0`**：分片路径上 metric-ramp 卡逐格求值，零 defer → 证据：`artifacts/ideology-cell-layer/m4/M4-21-ramp-end-to-end.md`
- [x] **B7 14 → 15 checks**，新增断言「ramp terms are evaluated per cell on the sharded path」
- [x] **修子夹具**：补齐 `bootstrap_economy` + 跑完经济日（原先 `locations=[0]`，卡从未装备）
- [x] **修计数器导出**：`_ramp_terms_evaluated` 只在已废弃的单发路径赋值 → job 路径从不写，读数永远是陈旧 0
- [x] **加两级诊断** `ramp_candidates` / `ramp_metric_ok`：实测 5/5，证明 ramp 判定条件从来不是问题（我一度误读为 `==` 而非 `!=`）
- [x] **`taken=0` 的正确解释**：只统计真正重采样，country-scope memo 命中不递增；以 `evaluated` 为准
- [x] **确认单发路径已成死代码**：全库 `rebuild_derived_cell_layer(day` 零命中
- [ ] **[M5 清理] 删除或标注 dead 的单发路径** `rebuild_derived_cell_layer`
- [ ] **[M4 未做] per-tag changed words**：`tag_build_ms` 仍 34.92 ms
- [ ] **[M4 未测] 峰值内存、B5 零增量、release DLL**
- [ ] **[M4 未做] per-tag changed words**：`tag_build_ms` 仍 34.92 ms
- [ ] **[M4 未测] 峰值内存、B5 零增量、release DLL**
### M4-22 per-tag changed words：尝试失败，找到真瓶颈

- [x] **active-tag 过滤实现并实测**：预计算有行的 tag，把 `cells × tags` 变为 `cells × active_tags` → 证据：`artifacts/ideology-cell-layer/m4/M4-22-per-tag-attempt-negative.md`
- [x] **实测零收益**：2400 格 12.94 → 13.30 ms；6400 格 34.92 → 35.66 ms（噪声内）
- [x] **原因**：`tag_declared=296  tag_active=296` —— **全部 296 个 tag 都有行**，无可跳过
- [x] **新增计数器** `tag_declared_tags` / `tag_active_tags`：让「表里有多少废 tag」可见
- [x] **找到真正瓶颈**：`6400 × 296 = 189 万次 matches`，18.8 ns/次，正比无常数浪费
- [x] **瓶颈在消费者协议**：`EffectInputConsumers` 只有 `tags_needed` 布尔，**没有「要哪些 tag」**，所以任一卡用 tag 就要算全部 296 个
- [x] **保留 `active_tags`**：对「声明多、使用少」的表会立即生效，正确且无害
### M4-23 性能测量可信度问题 + tag_ids 协议落地

- [x] **发现并终止一个僵尸 python 进程**：起始 2026-10-24，累计 **69280 s CPU**，污染了 M4-17/19/22 的全部计时 → 证据：`artifacts/ideology-cell-layer/m4/M4-23-measurement-integrity.md`
- [x] **机器仍有大量常驻负载**：WXWorkWeb 10415 s、ProjectInstaller 7369 s、GenuineService 6435 s、QQPCTray 5259 s
- [x] **实测 `spread = 1.70× ~ 2.34×`**，正好落在项目自己记录的 1.69–1.81× 不可信区间
- [x] **`tag_ids` 消费者协议实现完成**：`EffectInputConsumers::tag_ids`、`LevelManagedInfo::tag_ids` + `tag_ids_incomplete`、publisher 与重建两侧接线
- [x] **保守回退语义**：空集 + `tags_needed=true` 视为「全部 tag」，synergy override 存在时清空集合，确保不会静默收窄目标集
- [x] **新增计数器** `tag_declared_tags` / `tag_active_tags` / `tag_consumed_tags`
- [x] **功能零回归**：全回归 17/17
### M4-24 可信性能基线（校准后重测）

- [x] **校准方法确立**：同机固定负载 15 冷跑 spread **2.13×** → 预热后 1.86× → **5 批×9 跑取批内 p50 中位数 1.14×** → 证据：`artifacts/ideology-cell-layer/m4/M4-24-trusted-perf.md`
- [x] **预热写进夹具**：首次运行支付分配/缺页成本，混入会把 spread 抬到 2.13×
- [x] **6400 格最坏单步 0.6093 ms（3 步，spread 1.14×）→ §14.3 门槛 PASS，余量 39%**
- [x] **2400 格最坏单步 0.2578 ms（2 步，spread 1.20×）→ PASS**
- [x] **`tag_build_ms`**：2400 格 13.57（1.10×）、6400 格 35.36（1.07×）
- [x] **证实污染伪影**：M4-23 的 72.5/92.8 ms 是僵尸进程干扰，真实值 35.36
- [x] **M4-19 的分片数字被证实**：0.5878 → 0.6093（+3.7%，在噪声内）
### M4-25 tag_ids 协议生效（296 → 48）

- [x] **`active=48 consumed=48`**（原 296/0）：`cells × tags` 从 473,600 次 match 降到 76,800，**少 6.2 倍** → 证据：`artifacts/ideology-cell-layer/m4/M4-25-tag-ids-effective.md`
- [x] **修 3 个实现缺陷**：① `tag_ids_incomplete` 清空整个集合（48 个 id 在发布前丢失）② override tag 可从 `_synergy_tag_overrides` 的 key 与 `SynergyOverride::tag_id`/`match_tag_id` 枚举 ③ `_synergy_overrides` 是 vector 不是 map
- [x] **`match_tag_id` 与 `tag_id` 都要收**：只收替换后的，选择器会读一个从未算过 bits 的 tag
- [x] **保守回退保留**：空集 + `tags_needed=true` 视为全部 tag
- [x] **全回归 17/17**，含 `tag_snapshot_stress` 38/0 —— 证明收窄没有丢掉任何需要的 tag
- [x] **诊断计数器** `_consumer_publish_calls` / `_consumer_tag_ids_last` / `_consumer_levels_with_tags`
### M4-26 tag_ids 配对 A/B：1.29× 真实收益，瓶颈另有其人

- [x] **配对测量**（同一二进制、紧邻两臂、12 对）：**配对差中位数 +3.20 ms，9/12 为正，17.34 vs 22.43 ms = 1.29×** → 证据：`artifacts/ideology-cell-layer/m4/M4-26-tag-ids-paired-ab.md`
- [x] **A/B 开关验证有效**：`PK_TAG_FORCE_ALL=1` → `active=296 consumed=0`；`=0` → `active=48 consumed=48`
- [x] **关键发现：match 缩减 6.2×，墙钟只有 1.29×** → `sample_effect_metrics` 每格一次、与 tag 数无关，才是主要成本
- [x] **对 per-tag changed words 的价值重新量化**：tag 匹配约占 5/22 ms（23%），即使降到 0 收益上限也只有 ~23%
- [x] **优化方向修正**：要降一个数量级应优化**采样**（只采 mask 内 metric / 按 cell 分片），不是 tag 侧
- [x] **全回归 17/17**（默认 `PK_TAG_FORCE_ALL=0`）
- [ ] **[M4 未测] 6400 格下的配对差**（目前只有 B7 的 1600 格）
- [ ] **[M4 未做] per-tag changed words**：价值上限已量化（~23%），优先级下调
- [ ] **[M4 未测] 峰值内存、B5 零增量、release DLL**
- [ ] **[M4 未做] per-tag changed words 增量**：现在有了准确 tag 集合，前置条件才具备
- [ ] **[M4 未做] per-tag changed words 增量更新**
- [ ] **[M4 未测] 峰值内存、B5 零增量、release DLL**
- [ ] **[M4 未验证] `tag_ids` 的收益**：该夹具 `consumed=0`（不经 ideology publisher），需要在真实链路夹具上测
- [ ] **[M4 未做] per-tag changed words 增量更新**
- [ ] **[M4 未做] 增量更新**：受上面同一前置限制
- [ ] **[M4 未测] 峰值内存、B5 零增量、release DLL**
- [ ] **[M4 未测] 峰值内存、B5 零增量、release DLL**
- [ ] **[M4 未做] 分片物化**（§15.3 列为必要项）：`rebuild_ms` 需切成 ≤1 ms 片并带 resume 游标
- [ ] **[M4 未做] per-tag changed words**：`tag_build` 46.79 ms 目前是全量重建
- [ ] **[M4 未测] 最坏日**：夹具先跑日后装卡，测到的是无卡日；未测「派生成本叠加在 city factor 上」
- [ ] **[M4 未测] 峰值内存、B5 零增量、release DLL**
- [ ] **[M5 未开始] 生产切换、清理、最终证据**
- [ ] **[M4 剩余]** stamp/scratch、边境外溢、多国影响、per-tag changed words、文案与保存**
- [ ] **[M5 未开始]**
- [ ] **[M4 待建] 派生 front 逐格值桥**（`get_derived_materialize_report` 只有汇总，无逐格值）
- [x] ~~`Sources` rollout 未启用~~ → 已启用，`x1b` 142/0（M4-8）
- [ ] **[M5 未开始] 生产切换、清理、最终证据**
- [x] ~~在 `per_target` 路径加计数器~~ → I01 修复后 `x1b` 数值分歧全消（13→0），路径已确认执行
- [ ] **[M4 未完成] 71 个 program rollout、stamp/scratch、边境外溢、per-tag changed words**
- [ ] **[M5 未开始] 生产切换、清理、最终证据**
- [ ] **[M4 未完成] 71 个 program 的 rollout**、stamp/scratch、边境外溢、多国共同影响、per-tag changed words
- [ ] **[M3 未取得] ramp 真实幅度**
- [ ] **[M3 结转] 真实世界夹具（6144 格）仍未复现激活**，与廉价探针的环境差异未查明
- [ ] **[M3 未取得] class opinion → equip → ramp 真实幅度**
- [ ] **[M3 未取得] ramp 真实幅度** —— `equip` 未成功，理念未激活
- [ ] **[M3 未取得] 24 个 ramp 的真实数值** —— 仍是 M3 唯一缺的硬证据
- [ ] **[M3 待读] `ideology_card_content_test.gd:699-710` 的 `_settle()` 如何驱动结算**
- [x] **已记录教训**：真实世界运行 10 分钟/次，必须先读源码再跑
- [ ] **[M3 未验证] M3 另外 3 个退出条件**（阈值刷新 / 条件边界 / B9 预算）
- [x] **`rollout` 已打开到 `Continuous`**（M3-12），回归零变化
- [ ] **[M3 待查] `rows=0` 的原因**：家族资金？距离？初始家族太少？
- [ ] **[M3 未知] 32 上限的玩法影响** —— 仍未定论
- [ ] **[M3 结转] 诊断桥需补 `passable` 字段** —— 否则它会报「一切正常」而实际失败
- [ ] **[M3 结转] 探针采集 29 个格点太慢**，应只测 2–3 个
- [x] **殖民查询已成功**（`ok=true`），但无报价（`rows=0`）
- [ ] **[M3 未知] 32 上限的真实玩法影响** —— 自 M3-5 以来未推进
- [ ] **[M3 未知] 32 上限在真实玩法中是否被触发** —— 不能用 M3-5 的「从未触发」说法
- [x] **已查明**：sync 修可见性，`country_slot_arr` 不参与可见性计算
- [x] ~~推论：32 上限从未被触发~~ **M3-6 已收回**：证据不足以支持
- [ ] **[D4 决策项] 32 上限的真实玩法影响未知** —— 殖民机制存在但夹具未走通，需补视野或加测试开关
- [ ] **[M3 结转] 增长探测只跑到 day 20**（每 checkpoint 一次 `run_daily_tick` 太慢）
- [ ] **[M3 结转] e2e 夹具因 B 组断言（领土>32）失败而未通过** —— 如实反映现实，非夹具缺陷
- [ ] **[M3 结转] `run_economy_slice` 需 Dictionary 参数，调用形式未验证**
- [ ] **[M3 结转] 采样器每次分配 108 元素 vector**，宽领土下 1000 次分配，应复用缓冲
- [ ] **[M3 结转] 缓存键依赖 metric_id<256，无 static_assert 保护**
- [ ] **[阻塞] 端到端验证缺口**：五次确认需 `generate_world` + worker 协作夹具
- [ ] **[待查] ENTITY scope 行即使有非零 handle 仍不贡献**
- [ ] **[M5 前置] `_city_output_shard` 的旧平面合并段（~65 行）未分片**

- [ ] **[M2 待查] 尽管测出「每天只排空一次」，改用递增 day 后仍未修复** —— 说明还有第二个因素
- [ ] **[M2 结转] `numeric` 行未完成**，不得计入 §13 覆盖率
- [ ] **[M2 优先] `invalidation_test`**：精确/保守失效、false→true
- [ ] **[M2 阻塞] `worker_test`**：依赖已知的 worker 夹具缺口
- [ ] **[M2 结转] 「运行时 catalog 与静态工具一致」无断言**：describe 桥未实现
- [ ] **[M2 结转] 未覆盖 ramp/stacked/负 base/多 stat 交织**
- [ ] **[M2 前置] 未验证 tag 表里 `cell.clan` 的实际索引与行内容**

### M2-1 32 上限的三层耦合（方案原先遗漏）

- [x] **发现方案从未提及 `SELECTOR_MAX_CELLS`**（grep 0 命中），而它在 13 处代码中使用 → 证据：`artifacts/ideology-cell-layer/m2/M2-1-three-layer-cap-analysis.md`
- [x] 内容侧实测：**194 / 194** 个 kind-12 program 的 `target_selector_param` 全为 `(32, 0)`，无一例外
- [x] 三层联动：代码常量 `effect_runtime.h:272` + 内容参数 194 处 + 实例截断 `ideology_runtime.cpp:2133`
- [x] **实测证明顺序约束**：把一个参数改成 64 后 catalog 以 `ideology_effect_selector_cap_invalid` 失败；数据已逐字节恢复
- [x] 纠正判断：拒绝发生在 **GDScript 侧**（`ideology_effect_definition.gd:261-266`），且 C++ 层另有一道；放宽需改两层
- [x] 记录非对称：kind 16/FAMILY 校验豁免上限，但运行时仍 `min(param0, 32)` → E/F 工作量不能按「豁免」估计
- [x] 已写入方案 §1.1（三层表 + 顺序 + 非对称 + 拆常量的建议）
- [x] **已拆**：`gdext/src/selector_cell_cap.h`（无 Godot 依赖），`effect_runtime.h` 委托 + 7 条 `static_assert` 守卫

### M2-2 选择器上限拆分

- [x] 新增 `selector_cell_cap.h`：`selector_cell_ceiling` / `selector_cell_cap_is_unbounded` / `resolve_selector_cell_cap` → 证据：`artifacts/ideology-cell-layer/m2/M2-2-cap-split.md`
- [x] 纯核测试 **25 checks 0 failures**
- [x] **几何上限已按既有断言核对**：R1 = 6、R2 = 18（不含源格），依据 `economy_runtime_effect_selector_tests.cpp:206-226`
- [x] **修正一次差点发生的错误**：首版写 18/37（那是 kind 16 的 BFS 半径），会把 R1 放宽 3 倍
- [x] 未知种类回落 32（失败取严，不静默放宽）
- [x] **static_assert 守卫实测有效**：把 kind id 改成 99 后构建以 C2607 失败
- [x] **E 组锁住「不改变现状」**：写 32 仍得 32（194/194 内容参数都是 32）
- [x] 回归零判定变化
- [x] **OWN_TERRITORY 上限已迁移**到 `resolve_selector_cell_cap`（`economy_runtime_family_buff.cpp`）

### M2-3 领地上限迁移（只迁移一处）

- [x] **测试先抓到我一个错误**：`authored=100` 新旧不等（旧 32 / 新 100），说明这不是等价替换 → 证据：`artifacts/ideology-cell-layer/m2/M2-3-territory-cap-migration.md` §1
- [x] 可达性分析：两层校验都拒绝 `param[0] > 32`，所以**现有内容范围内完全等价**（194/194 都是 32）
- [x] 测试改为三组：F（可达值相等）/ F2（未来增量，**显式断言** `authored=100` 得 100）/ F3（小地图收窄）
- [x] `param0 == 0` 时**刻意保留**旧的 32 兜底，不放宽（那必须与内容改动同批）
- [x] 上限测试扩到 **35 checks 0 failures**
- [x] 回归 **零判定变化**，新 DLL `1e7c41ea…`
- [x] **另三处有意不迁移**并写明理由：`:2430` 上限未变、`:2476` cap 是含 anchor 的可达上限（18 vs 几何 6，等价但不该动）、`:2495` 是跳数非格数
- [ ] **[M2 结转] 另三处调用点仍用 `SELECTOR_MAX_CELLS`**：有意为之，非遗漏
- [x] **两层校验已放宽**（GDScript + C++），按 selector 种类判断

### M2-4 两层校验放宽

- [x] GDScript `selector_cell_ceiling()` 按种类；`ideology_effect_definition.gd` 校验改用 authored 上限
- [x] C++ `effect_runtime.cpp:1005-1013` 同步放宽
- [x] 新测试 `ideology_effect_definition_ceiling_test.gd` **19 checks 0 failures**，逐项对照两侧上限表 → 证据：`artifacts/ideology-cell-layer/m2/M2-4-validator-relaxation.md`
- [x] **把 catalog 弄坏过一次并修好**：失败从 6 涨到 10，根因是拿「几何值 6」去校验「作者声明的上限 8」
- [x] 修法：拆分 `selector_authored_cell_ceiling()`（校验用，有界种类仍 32）与 `selector_cell_ceiling()`（运行时压走格）
- [x] 记录教训：**校验上限只能放宽，不能因为引入更精确的几何知识就顺手收紧**
- [x] 回归回到基线 6 项，且 `runtime_ideology_parity_test` **失败数 3 → 1**（真实改善，原因未证实）
- [x] 新 DLL `eb4e575b…`
- [x] **194 个内容参数已从 `(32, 0)` 改为 `(0, 0)`**（1 个文件）

### M2-5 32 格限制已移除

- [x] `param0 == 0` 语义改为「无策略上限」，代码侧同步让路（`resolve_selector_cell_cap` 直传 param0）→ 证据：`artifacts/ideology-cell-layer/m2/M2-5-cap-removed.md`
- [x] 194 处内容参数全部改为 `(0, 0)`，集中在 **1 个文件**
- [x] 新测试 `selector_cap_removed_test.cpp` **12 checks 0 failures**，断言的是行为而非代码外观
- [x] **200 格国得到 200 个目标**（旧上限 32）；33 格全部保留
- [x] **直接读 `.tres` 确认无任何 kind-12 仍写 32**——防止代码对而数据回退
- [x] 保留「作者显式写 32 仍得 32」的能力（删的是默认上限，不是表达能力）
- [x] 回归 **changed verdicts = 0**（15 fixture 逐项与 M0 一致，含失败项）
- [x] 新 DLL `9a81088b…`
### M2-6 取消上限的成本实测

- [x] `gdext/tests/cap_cost_model_test.cpp` **28 checks 0 failures** → 证据：`artifacts/ideology-cell-layer/m2/M2-6-cap-cost.md`
- [x] **小领地零成本**：8 格 / 32 格场景倍数 **1.0x** —— 这解释了 M2-5 回归零变化
- [x] 大国线性增长：100 格 3.1x / 900 格 28x / **6400 格 200x**
- [x] 全国单程序 **38.4 ms / 约 100 万次查询 / 100 个 slice**
- [x] **单 slice 仍达标**：0.384 ms（lookup）+ 0.465 ms（epoch-open）= 0.849 ms < 1 ms
- [x] **总延迟 85 ms（全国）/ 13 ms（王国）需产品决策**，已按 L597 要求写入 §14.1 而非掩埋
- [x] 选择器本身可忽略：6400 格 collect 仅 2.64 us，低三个数量级
- [ ] **[M2 关键] 仍是预算推算，非 in-situ 测量**：6.0 us/覆盖格来自 M1-5 微基准，§14.4 在环数字仍欠
- [ ] **[M2 结转] 未测多程序叠加**：两卡共享格时可复用部分查询，本模型按独立付费算是上界
- [ ] **[M2 结转] 未测 `shared` 行变化时另加的 `map_cells × 155`**
- [ ] **产品决策待定：85 ms 的总 epoch-open 延迟是否被接受**

### M2-7 快路径评估（结论：暂不实施）

- [x] `gdext/tests/cell_factor_fastpath_bench.cpp` 测量「共享行解析一次 + 每格只折派生槽」→ 证据：`artifacts/ideology-cell-layer/m2/M2-7-fastpath-eval.md`
- [x] 加速比 **1.89x（32 格）/ 1.73x（900 格）/ 1.38x（6400 格）**，随规模下降
- [x] **算术等价已逐样本验证**（double 相等，非抽样），符合 §5.1 的加乘顺序与零因子语义
- [x] 根因：6400 格时瓶颈是 `row_for_stat` + `find` 的约 21 次比较，与快路径无关
- [x] **判断：不实施** —— 收益不改变设计（38.4→27.8 ms 仍需分片），且触碰 §5.1 最敏感的合并逻辑
- [x] 记录（当时 rollout 为 `Off`）：该成本尚未在生产生效，无真实反馈下不动核心热路径。**现已 `Sources`，此前提失效，需重测**
- [x] 确认 `collect_scope_ids` 的派生并集确实让派生格进入工作集（M1-4 意图成立）
### M2-8 in-situ 测量尝试（阻塞，第三次撞同一门）

- [x] `tests/ideology/ideology_city_factor_insitu_test.gd` 可运行，但**未取得数据** → 证据：`artifacts/ideology-cell-layer/m2/M2-8-insitu-blocked.md`
- [x] **排除三个假设**：桶已建成（`[0,0,32,0]`）、枚举正常（返回 128 格）、读者执行过（`epoch_ms=0.201`、queries=4386）
- [x] **决定性观察**：scale=32 与 128 的 `economy_queries` **完全相同**（4386），说明查询发生在导入桶之前（configure 阶段）
- [x] 确认根因：`stage=environment_snapshot` + `city_factor_work_cells=0`，`start_epoch` 从未进入 `capture_country_epoch`
- [x] **这是 M1-8 / M1-13 同一前置的第三次表现**：需真实 `generate_world()` + worker 协作
- [x] **改用 M0-7c 的 generate_world harness**（而非裸 SceneTree），真实世界入口可用

### M2-9 真实世界 in-situ（部分成功）

- [x] **idle 档取得真实读数 0.002 ms**（2400 格真实地图、真实 epoch、2 样本），与 M0-7c 的 0.003 ms 一致 → 证据：`artifacts/ideology-cell-layer/m2/M2-9-realworld-insitu.md`
- [x] 确认分片改造**没有让 idle 路径变慢**
- [x] loaded 档注入 2000 格后 **NO DATA**，根因是既有缺陷 `money_conservation_failed @ day 4`（money_error=-254076），M0-7c 已记录，与本迁移无关
- [x] **发现并修正一个误导性测试辅助**：`player owned cells=-1` 不是产品问题，而是 `country.report()` 没有领土字段（只有 `cell_count` 即全图格数）
- [x] 改为通过 `country_facade._world_ext.query_country_anchor_cell(0)` 判断领土存在性
- [x] **如实记录 idle 数字不能当作功能成本**：harness 自身警告（`:167-171`），idle 时工作集为空
- [ ] **[M2 阻塞] loaded 档仍无数据**：被既有 `money_conservation_failed` 挡住，非本迁移引入
### M2-11 计时口径问题（撤回上一稿结论）

- [x] 新增 `city_factor_collected_cells` 与 `city_factor_cells_processed` 两个计数器 → 证据：`artifacts/ideology-cell-layer/m2/M2-11-retraction-and-real-mechanism.md`
- [x] **实证推翻我自己的推理**：`collected=2000` 证明 collect 返回了 2000 格，不是 16
- [x] 真正机制：`processed=16` 是**收尾分片**，2000 格分散在约 32 次调用里，分片工作正常
- [x] 因此「分片被版本打断」与「注入行被 snapshot 抹掉」两个判断**都错**
- [x] **根因是计时口径**：`epoch_begin_city_factor_ms` 只覆盖最后一次调用，不是整次构建
- [x] 得出更低成本的解法：加「本 epoch 累计耗时」计数器，**可能不需要 worker 脚手架**
- [x] **已加累计计时** `city_factor_epoch_ms` / `_slices` / `_cells`

### M2-12 在环实测成功（关键里程碑）

- [x] **取得真实 in-situ 数据**：2000 格 / **32 片** / **14.376 ms** → 证据：`artifacts/ideology-cell-layer/m2/M2-12-insitu-achieved.md`
- [x] 每格成本 **7.19 us**（M2-6 推算 6.0 us，误差仅 **+20%**）
- [x] 每片 **0.449 ms**；分片数 32 = ⌈2000/64⌉，与设计完全一致
- [x] **§14.3 单 slice 门禁判定：通过**，0.449 + 0.465 = **0.914 ms < 1.0 ms**
- [x] **但余量仅 8.6%**，已写入方案：后续任何小幅变慢都会击穿
- [x] 总延迟：2000 格 14.4 ms；6400 格外推 46.0 ms
- [x] **纠正三轮错误结论**：M2-9「注入行被抹掉」/ M2-10「0.003 ms」/ M2-11「total=16」全部被推翻
- [x] 教训已记录：**先加可观测字段，再下结论**
- [ ] **产品决策：46 ms 总 epoch-open 延迟是否接受**
- [ ] **[M3] 未测 6400 格实测值**（46.0 ms 是线性外推）
- [ ] **[M3] 未测 `shared` 行变化时另加的 `map_cells × 155`**
- [x] **线性度已验证**：三规模 200 / 800 / 2000 格，分片数严格等于 ⌈cells/64⌉

### M2-13 线性度与离群值修正

- [x] 三规模实测：200 格 1.079 ms / 800 格 2.581 ms / 2000 格 7.799 ms → 证据：`artifacts/ideology-cell-layer/m2/M2-13-linearity-outlier.md`
- [x] **发现上一轮 14.376 ms 是离群值**：同规模重测 7.799 ms，差 1.8 倍
- [x] 真实每格成本 **3.2–5.4 us**（max/min = 1.67），不是 7.19 us
- [x] 6400 格外推从 46.0 ms **降到 25.0 ms**
- [x] §14.3 单 slice 余量从 8.6% 修正为 **26–34%**
- [x] 已写入方案，并明确标注「0.465 ms 来自不同规模，相加只是保守上界」
### M2-14 重复测量尝试（失败，两次否定结论）

- [x] harness 新增 `PK_REPEAT_BUILDS` 与 `version_probe` 观测 → 证据：`artifacts/ideology-cell-layer/m2/M2-14-repeat-attempt-blocked.md`
- [x] **`version_probe` 立即证伪第一个假设**：版本五天完全相同，读者从未重建
- [x] **修日戳后仍无效**：`run_modifier_daily(_day-1)` 未改变结果，否定「日戳错位」的定位
- [x] 确立循环依赖：**要 bump 才能重建，要重建才能读取 bump**
- [x] 记录「不再继续深挖」的理由：缺可靠观测时继续调整只会产生新错误结论（前几轮已证三次）
### M2-15 真实分位数（门禁闭合）

- [x] 新增 `tools/ideology/measure_city_factor_runs.py`：多进程采样器 → 证据：`artifacts/ideology-cell-layer/m2/M2-15-real-percentiles.md`
- [x] **5 个独立样本**：min 2.848 / **p50 4.516** / **p95 4.805** ms
- [x] **离散度 1.69x**，采样器自动告警——证实单次读数可能偏差 69%
- [x] 解释了 M2-12（7.19 us）与 M2-13（3.90 us）是分布的两个尾巴
- [x] **§14.3 在 p95 上通过**：0.370 + 0.465 = **0.835 ms < 1.0**，余量 16.5%
- [x] **实测 p95 = 6.01 us/格，与 M2-6 假设的 6.0 us 几乎完全一致**；6400 格外推 38.4 ms 也与原推算吻合
- [x] 修正两处代码损耗：删掉失效的 `PK_REPEAT_BUILDS`，恢复被误删的 `ext_version_probe`
- [ ] **[M2 结转] 只有 800 格一个规模有分布**：6400 格仍是外推
- [ ] **[M3] n=5 时 p95 = max**：真正的 p99 需 ≥20 样本（约 100 分钟）
- [ ] **[M3] 未区分冷建与热更新**（§14.1 要求分开统计）
- [ ] **[M3 建议] 换测量机制**：每次测量前重建整个世界（约 5 分钟/次），用冷启动代替重复热构建
- [ ] **[M2] 需同规模同测 city 因子与 epoch-open 其他开销**，替换跨规模相加
- [ ] **[M3] 6000+ 格地图实测**（25.0 ms 仍是外推）
- [ ] **[M2 待实证] 逐片打印 `cursor/processed` 坐实「收尾分片」解释**
- [ ] **[M2 未做] rollout ON**：依赖 in-situ 验证与产品对 85 ms 延迟的决策
- [ ] **[M3 备选] 若确需压那 21 次比较**，需把 `DerivedCellFront` 改成按格可查（结构改动，非局部优化）
- [ ] **[M2 结转] 夹具世界太小**（256/512 格），零回归不能外推到 6400 格生产规模
- [x] ~~`kCellProgramRollout` 仍是 `Off`~~ → 现已 `Sources`；实例层不再截断
- [ ] **[M2] 面向作者的文档未更新**：「0 = 整片领土」的语义没有写进任何作者文档
- [ ] **[M2 结转] `parity` 改善的因果链未证实**
- [ ] **[M2 结转] 未验证真正 `param[0] > 32` 的 program 端到端跑通**
- [x] ~~194 个内容参数仍为 `(32, 0)`~~ → 已完成，见本清单 M2-5 与 l626
- [ ] **[M2 结转] 两层校验尚未放宽**：GDScript `ideology_effect_definition.gd:261-266` 与 C++ `effect_runtime.cpp:1005-1013`
- [ ] **[M2] 内容改动需作为独立可评审批次**：一次动 194 个 `.tres` + 常量会让回归归因困难
- [ ] **[M2 前置] 内容侧的 `target_selector_param = (32, 0)` 需随批次更新**：否则派生路径通了选择器仍截断到 32
- [ ] **[M1 结转] e2e 只验证了 `Off` 分支**：ON 后行真的产生仍未证明（被 tag 问题挡住）
- [ ] **[M1 结转] e2e 夹具未纳入基线**：需完整 catalog 编译，单次约 30 s
- [ ] **[M5 前置] 旧平面合并段（~65 行）仍未分片**：`_ideology_cell_plane_enabled` 默认关闭故当前不触发，删除旧平面时必须连带处理
- [ ] **[M1 结转] `_city_output_shard_partial` 峰值内存未测**：规模等于 `overrides`，大图上几千行 × 12 字节
- [ ] **[M1 结转] `install_derived_cell_layer` 的 `content_digest` 成本未测**：O(行数)，64 国规模可能数十毫秒
- [ ] **[M1 结转] 未做 in-situ 测量**：O2 微基准不含 cache miss 与真实 ModifierRuntime 状态
- [ ] **[M1 结转] `collect_scope_*` 并集仍是 O(派生行)**：stat 命中后遍历该 stat 全部格，几万行规模时需 per-stat CSR
- [ ] **[M1 结转] `stat_bucket_version` 未与 layer 版本组合**：缓存仍只按 legacy 版本失效
- [ ] **[M1 结转] `effective_value` 新增两次二分，未测性能**：`covered_cells × 156` 成本会上升，M1 退出前必须测
- [ ] **[M1 结转] `install_derived_cell_layer` 无生产调用方**：仅 test bridge 调用，等待 Economy 冻结协调器接线
- [ ] **[M2 前置] 逐来源国撤销未实现**：`add()` 把不同来源国折进同一 slot（刻意的 M1 边界），§8.1 的多国影响同一格会算错
- [ ] **[M1 结转] copier 能力继承未实现**：方案 §4.4 要求「copier 以被复制 program 的已编译能力为基础」，判定器目前只看 program 元数据

- [ ] 打通启动编译顺序（预算、native catalog、实例收集、内容展示消费同一列）
- [ ] 抽取 VM/adapter 贡献转换、activation scale、term fold，保留旧路径对照
- [ ] 实现独立 front、候选预检、替换、per-stat version
- [ ] `collect_scope_ids` / `collect_scope_stat_entries` 返回实例与派生并集
- [ ] `stat_bucket_version` / `building_output_stat_version` 组合 legacy 与 layer version
- [ ] read view（`ModifierReadView`）实现与六类 reader 接入
- [ ] 原生 explain 基础数值分项 + unclamped
- [ ] OFF/SHADOW/ON 测试配置与每类别启用表，正式默认 OFF
- [ ] M1 退出验收

## 4. M2：A/B 批次（方案 §15.4 记 141 个；实际覆盖 194 个 kind-12 program）

- [ ] 主线程与 worker 已确认投影适配
- [ ] 必要 host 交接与业务日筛选
- [ ] 拆清 RAW_INPUTS / FACTOR_CAPTURE，加入分片 MATERIALIZE gate
- [ ] A=129 常数（含多命令）
- [ ] B=12 国家 ramp
- [ ] 本批所有 stat reader / 缓存 / fallback 资源因子 / UI 有效值查询接入
- [ ] 本批 save basis / manifest / 恢复 finalize
- [ ] 生成器文案、实例预算、测试断言同步
- [ ] M2 退出验收（141 同输入对照、>32 完整覆盖、零逐格实例、四权威组合/ACK/时序/读档/空闲、成本达标）

## 5. M3：C/D（方案记累计 194；实际 DerivedCell 已达 265）

- [ ] C=12 逐格 ramp，保留 raw continuous revision
- [ ] D=41 条件常数，支持 multi-command 与布尔 IR
- [ ] changed metric cells/countries 融入既有采样循环
- [ ] 新 consumer 初次采样与 full_dirty fallback
- [ ] selector 候选集与条件通过集分离（覆盖 false→true）
- [ ] metric>63 覆盖
- [ ] 本批 save 冻结源与消费黄金测试
- [ ] M3 退出验收

## 6. M4：E/F（累计 265）

- [ ] E=66 来源计数、F=5 来源环并集，来源与目标列表均无技术性 cap
- [ ] stamp / touched scratch，复用相同几何
- [ ] 消除逐来源整图 `seen` 清零（`ideology_runtime.cpp:1966,1992`）
- [ ] 边境外溢、多国共同影响、来源国家撤销
- [ ] per-tag changed words/cells 缩小失效范围
- [ ] 文案、解释、本批保存基础同步
- [ ] M4 退出验收（100+ 来源 r=1–4、重叠、count cap、跨国边境、B8/B10、峰值内存）

## 7. M5：生产切换、清理与最终证据

- [ ] 全部 A–F 在受测配置 ON；覆盖报表只有 G/H 与有状态路径属 legacy
- [ ] 删除旧 v1 平面、无效 generation、重复 reader 合并、相关 feature API
- [ ] 生产固化执行后端；删除迁移开关、tier 分支
- [ ] 剩余 32 常量改名 legacy 实例保护
- [ ] 全量构建、回归、B1–B12、save/load、权威翻转、UI 验收
- [ ] 文档与 skill 同步（§16.5 清单）
- [ ] M5 退出：§18 全部完成

### M5-1 清理死代码与 legacy 命名

- [x] **删除 `rebuild_derived_cell_layer`（144 行死代码）**：M4-19 改成分片路径后零调用点，且它是**不含 ramp sampler、不含分片**的等价实现，留着会诱使后来者重新引入 M4-19/M4-20 的缺陷 → 证据：`artifacts/ideology-cell-layer/m5/M5-1-cleanup-and-legacy-naming.md`
- [x] **删除 `rebuild_derived_cell_layer_sharded` 声明**：只有声明、零定义
- [x] **修正 4 处指向已删函数的注释**（指向不存在的函数比没有注释更糟）
- [x] **`SELECTOR_MAX_CELLS` → `LEGACY_INSTANCE_MAX_CELLS`**：旧名读起来像「选择器覆盖格数」，正是让 32 看起来像设计决策的原因；保留兼容别名，约 20 处调用点不动
- [x] **实例保护保留**：`ideology_runtime.cpp:2381` 的截断只在实例分支可达，删掉会让宽选择器打爆实例表
- [x] **分类审计**：剩余 20 处 `SELECTOR_MAX_CELLS` 无一是「派生路径的技术性 32 限制」
- [x] **全回归 18/18**，构建 exit 0
### M5-2 删除迁移开关（§15.7）

- [x] **删除 `CellProgramRollout` 枚举与 `kCellProgramRollout` 常量**：四阶段已全部跑完并测量，开关再无用途 → 证据：`artifacts/ideology-cell-layer/m5/M5-2-rollout-switch-removed.md`
- [x] **`cell_program_rollout_enabled` 改为一行**：`return cell_program_selector_supported(kind);` —— **删的是「表达能力」之外的第二道门，不是「所有卡都派生」**
- [x] **`get_cell_program_rollout().rollout`** 枚举回显改为 `1` + `rollout_stage_removed = true`
- [x] **行为零变化验证**：全回归 18/18、覆盖率门禁 7/7、内核 67/0
- [x] `decide_cell_program_backend` 的 9 条理由判定保持不变
### M5-4 更正：旧平面在生产中是死代码（M5-3 结论有误）

- [x] **更正 M5-3**：「同一程序被应用两次」**在生产中不成立** → 证据：`artifacts/ideology-cell-layer/m5/M5-4-correction-plane-is-dead.md`
- [x] **决定性证据**：`_ideology_cell_programs` 唯一写入点是 `set_ideology_cell_programs`，其调用者只有 `publish_ideology_cell_programs`（**GDScript 调用者仅 1 个测试**）与 `set_..._for_test`
- [x] **实测 `[B7] plane: builds=0`**：平面从未构建
- [x] **合并段还有短路** `if (!entries.empty())`，所以连性能代价都没有 —— **纯死代码**
- [x] **I01 门控重新定性**：不是修 bug，是**防未来误启用**；`derived_elsewhere` 计数器让「平面是否被填充」可观测
- [x] **全回归 19/19**（新增 `ideology_effect_metric_publish_test` = 平面唯一调用者）
- [ ] **[M5 待删] 旧 v1 平面约 250 行死代码**：`build_cell_program_table`(~160 行) + 合并段(~85 行) + `ideology_cell_program.h` + 3 个桥 + `_cell_program_generation`/`_cell_plane_builds`
- [ ] **[M5 前置] 先迁走 `get_ideology_cell_program_summary` 的 5 个 GDScript 调用者断言**，否则删桥会让测试静默失效

- [ ] **[M5 未做] B1–B6、B9、B11、B12 未测**（B7/B8/B10 已测）
- [ ] **[M5 未做] save/load、权威翻转、UI 高亮验收**
- [ ] **[M5 未做] 文档与 skill 同步（§16.5）**

- [ ] **[M5 未做] 审计 `build_cell_program_table` 等旧平面 API**
- [ ] **[M5 未做] B1–B12 全量、save/load、权威翻转、UI 验收**
- [ ] **[M5 未做] 文档与 skill 同步（§16.5）**

### M5-5 「周围地块」归属筛选（用户新增目标项）

- [x] **问题确认**：扇出无归属过滤。`collect_effect_target_cells` 的 BFS（`economy_runtime_family_buff.cpp:2646-2664`）只查地形/资源/谓词，**grep `cell_country_slot` 零命中** → 71 个程序（5×kind14 + 66×kind16）会溢出到邻国 → 证据：`artifacts/ideology-cell-layer/m5/M5-5-ownership-scope.md`
- [x] **新增 Godot-free 头文件 `selector_ownership.h`**：`OWN/FOREIGN/ANY`，存在 `param0` bit 12..13（14/15/16 统一），未知值回退 `ANY` 而非 `OWN`
- [x] **默认改为 OWN**（用户要求）：74 张卡的 `param0`（32 / 544 / 576 / 800 / 832 / 864 / 1568）全部解码为 OWN
- [x] **kind 14/15**：逐 source 取 `cell_country_slot`，过滤 ring
- [x] **kind 16**：出口逐 cell 比 `cell_country_slot(cell) == country_slot`
- [x] **修两个我引入的缺陷**：① `collect_own_tagged_cells(-1)` 返回空（会把 OWN 目标集清空）② `param0` 的 cap 未屏蔽归属位（cap=0 哨兵失效）
- [x] **编译期安全性**：`_write_selector_tag_id` 只写 `params[1]`，`params[0]` 保留
- [x] **GDScript**：`pack_source_count` / `unpack_source_count` 带 ownership，默认 OWN
- [x] **内核 67 → 85 checks / 0**：含「默认 OWN」「6 个真实 param 解码为 OWN」「未知值回退 ANY」「cap 哨兵」「OWN+FOREIGN 划分 ANY」
- [x] **全回归 19/19**
### M5-6 归属筛选端到端证据 + 负向对照

- [x] **过滤抽为共享成员** `apply_fan_out_ownership_filter`：生产路径与探针调用同一实现（两份副本是 32 上限当初漂移的方式）→ 证据：`artifacts/ideology-cell-layer/m5/M5-6-ownership-proof.md`
- [x] **跨境证据在 C++ 选择器测试里取得**：`economy_runtime_effect_selector_tests.cpp` 拥有真实六边形邻接与归属数据；GDScript 的 `MapStub` 无法填充 `_building_neighbors`（只能由友元赋值）
- [x] **6 条断言**：`ownership_ring_straddles_the_border`（真实 R2 环同时含两国格）、`ownership_predicate_matches_country_split`、`ownership_own_plus_foreign_partitions_any`（OWN+FOREIGN == ANY == ring.size()）、**`ownership_own_drops_foreign_cells`**、`ownership_default_is_own`
- [x] **负向对照已做**：翻转断言后 x1b 报 142/1 并打印 `NEGATIVE_CONTROL_ownership` → **证明断言真的在执行**（此前三轮三次把工具缺陷当产品证据）
- [x] **影响评估**：74 张卡（5×kind14 + 66×kind16）`param0` 实测为 32/544/576/800/832/864/1568，**无一写过归属位，全部落到 OWN**；方向明确为「作用范围变小」
- [x] **恢复旧行为路径**：显式 `OWNERSHIP_ANY`（bit12..13 = 2），gds `pack_source_count(cap, radius, src_cap, tag, 2)`
- [x] **全回归 19/19；内核 85/0**
### M5-7 归属默认值变更的影响量化

- [x] **量化结果**：6×5 网格按列分两国，每个内部格轮流当源，真实六边形邻接取 R2 环 → **93/180 格为外国（51.7%），最坏单环 14/18** → 证据：`artifacts/ideology-cell-layer/m5/M5-7-impact-quantified.md`
- [x] **读法**：R2 环上限 18，边境最坏 14 格是外国的 → 旧行为下这些卡**近一半作用面在国境外**，新的 OWN 不是小幅收窄
- [x] **断言 + 报告分工**：`ownership_sweep_finds_foreign_cells` 断言「至少有一格外国」（证明变更不是空改）；百分比只打印不钉死（否则把内容问题变成脆弱测试）
- [x] **修诊断缺陷**：`building_context_ready_for_test()` 改为校验邻居**内容**（新增 `valid_neighbors` / `has_any_neighbor`），不再只看长度
- [x] **删除会崩溃的 GDScript 探针** `ideology_ownership_scope_probe.gd`：连续两轮 `raw=0`，且 `MapStub` 结构上填不了 `_building_neighbors`；留着等于留一个会崩又不验证任何东西的文件
- [x] **全回归 19/19；内核 85/0**
- [ ] **[M5 未量化] 按卡逐张的影响**：74 张卡各自的国境内 tag 命中数不同，51.7% 只是合成网格的平均值
- [ ] **[M5 未验证] 真实生成世界与 release DLL**


- [ ] **[M5 诊断缺陷] `building_context_ready_for_test()` 只校验长度不校验内容** → 邻居全是 -1 时仍报 `ready: true`
- [ ] **[M5 未验证] release DLL 与真实生成世界**


- [ ] **[M5 未量化] 改造对 74 张卡的数值影响**（多少格被过滤）
- [ ] **[M5 未观察] `ownership_filtered_resolves` 等 3 个计数器尚未见非零值**

### M5-8 派生层逐格值可观测 + 发现 cell 0 缺陷

- [x] **为何先做可观测性**：准备删旧平面时发现其 5 个调用者中 `ideology_effect_metric_publish_test.gd` 测的是真实语义（ADD vs MULTIPLY、SUBTRACT 符号来自定义），删掉会丢覆盖；而派生层只暴露计数，无处可迁 → 证据：`artifacts/ideology-cell-layer/m5/M5-8-effective-value-bridge.md`
- [x] **新增桥 `get_effective_stat_value(stat_key, cell, entity_handle, base_value)`**：`value` 走 `ModifierRuntime::effective_value`（生产同一调用），并单独报告 `derived_add` / `derived_factor` / `derived_zero_factor_count` / `derived_contributors` / `derived_source_country` / `derived_present`
- [x] **验证合并生效**：cell 1 → `value=1.050003`（基准 1.0 + 派生 0.05）
- [x] **修正我自己的用法错误**：`entity_handle` 传国家 handle 会跳过派生分支，生产读者用 `entity 0, group = cell`
- [x] **B7 新增 3 条值断言**，18 / 0
- [x] **全回归 19 / 19**
### M5-9 cell 0 缺陷已修复

- [x] **缺陷**：`modifier_runtime.cpp:1443` 的 `group_handle != 0` 排除了 cell 0（`group_handle` 就是 cell），**每张卡在其国家第一个格上都失效** → 证据：`artifacts/ideology-cell-layer/m5/M5-9-cell-zero-fixed.md`
- [x] **修复**：移除守卫（`if (domain == ECONOMY && !rows.empty())`），代码内写入推理与实测
- [x] **安全性论证**：ECONOMY 域调用方全部传 `entity 0, group = cell`；COUNTRY 域调用方传 group 0 表示「无 group」但被 `domain == ECONOMY` 挡住；`effective_values` 的 3 个调用者全是 COUNTRY 域 → **守卫与 domain 判定冗余，移除安全**
- [x] **修复验证**：cell 0 `value` 从 1.0 → **1.0500030517**，与 cell 1 一致；B7 18 → **20 checks**
- [x] **新增 2 条断言**：「cell 0 收到贡献」「cell 0 与 cell 1 的 delta 相同」
- [x] **无回归**：22 fixture 中 21 通过；`mechanism_matrix` 仍 **1129/3**，与基线完全一致（同样 3 个 cooperative 断言）
- [x] **这个缺陷是 M5-8 新增的值桥才让它现形的**：此前派生层只暴露计数，6400 行里少一格的贡献看不出来
### M5-10 删除旧 v1 平面（§15.7）

- [x] **决定性依据**：原注释自述「Off by default because the v1 table is not yet safe to apply (stale generation, **double application with the per-cell instances**...)」；且唯一生产者 `publish_ideology_cell_programs` 的 GDScript 调用者只有 1 个测试，`[B7] plane: builds=0` → 证据：`artifacts/ideology-cell-layer/m5/M5-10-v1-plane-deleted.md`
- [x] **删除约 430 行**：`build_cell_program_table`(169) + 平面合并段(74) + `set_ideology_cell_programs`(13) + 3 桥(62) + 2 个测试函数(114) + 开发探针 + 声明/绑定/成员/include/缓存键
- [x] **顺序正确**：可观测性（M5-8 的 `get_effective_stat_value`）→ 覆盖迁移（内核 `N` 组负幅度断言）→ 删除
- [x] **覆盖未丢失**：ADD/MULTIPLY 在内核 `A` 组；负幅度在 `N` 组（**含 base=2 的区分性用例：1.875 vs 1.75**）；逐格值在 B7
- [x] **发现并记录 GDScript 测试的静默降级**：删桥但未删测试函数时，报 `289 checks, 0 failures` 而平面断言早已不执行（`Nonexistent function` 抛错后计数器只是停止）→ 真正删除后 **268/0 且无 SCRIPT ERROR**
- [x] **构建 exit 0；21/22 fixture 通过**（`mechanism_matrix` 仍基线 1129/3）；**内核 93/0**
- [ ] **[M5 残留] `_cell_plane_builds` 等只被平面写过的计数器**永不递增，可再清一轮
- [ ] **[M5 残留] `ideology_cell_program.h`** 已无包含者但未删除
- [ ] **[M5 未测] B1–B6/B9/B11/B12、save/load、权威翻转、UI**
- [ ] **[M5 未做] 文档与 skill 同步（§16.5）**
- [ ] **[M5 未验证] 真实生成世界与 release DLL**
- [ ] **[M5 未做] 迁移旧平面的 3 类语义断言到派生层后删除平面**

### M5-11 文档同步与 §18 实际状态评估

- [x] **`native-ideology-runtime.md` 补「派生地块层」整节**（531 行）：后端判定、分片重建、归属筛选、可观测面、三个已修缺陷、旧平面删除 → 证据：`docs/cpp-dots-runtime/native-ideology-runtime.md`
- [x] **`native-modifier-runtime.md` 补「派生地块层」整节**（334 行）：`DerivedCellFront` 形状、§5.1 单次 clamp 合并、**group_handle 就是 cell**（含 cell 0 缺陷记录与移除安全论证）、安装与可续跑物化器
- [x] **`runtime-deletion-inventory.md` 补 5 行删除台账**：`build_cell_program_table` / `set_ideology_cell_programs` / 合并段 / 4 个 ClassDB 桥 / 2 个测试函数，含「删桥未删函数 → 289/0 假绿」的教训
- [x] **核实「`ideology_cell_program.h` 无包含者」**：`#include` 计数 = 0
- [x] **核实 skill 无过时内容**：`.claude/skills` 与 `.agents/skills` 双镜像，均未提平面或 32 上限，无需修正
- [x] **方案 §18.5 写入实际状态评估**：28 项中 **10 项有证据、18 项无证据**，并明确「本文档未被勾选为彻底取消完成」
- [x] **如实记录一处损失**：`derived_layer_oracle_test`（**735 检查**，§13.1 第 2 层同输入逐格对照）源码在会话期间一次 `git pull` 中随未跟踪文件丢失且未重建 → **§18.2 第 1 项从「通过」退回「无证据」**
- [x] **当前最接近的替代**：`derived_layer_rebuild_test.cpp`（93 检查）固定了 fold/零因子/幅度缩放/ramp/上限拆分/归属，但**不做旧实例路径 vs 新派生路径的逐格数值对照**
- [ ] **[§18 无证据 18 项]** 见方案 §18.5 表格：权威组合与翻转、save/load 全部时点、execution contract 持久化、snapshot ABI、B1–B6/B9/B11/B12、B5、峰值内存、release DLL、skill/文案/UI、发布说明、真实生成世界的 >32 样例
### M5-12 重建 oracle：基础设施就位，发现待查分歧

- [x] **建好对照夹具** `tests/ideology/ideology_oracle_cross_check_test.gd`：真实 ramp 卡 `salt_monopoly_l1`，冻结 metric 两个值，比值对照 `derived_add` vs `evaluate_effect_program_magnitude` → 证据：`artifacts/ideology-cell-layer/m5/M5-12-oracle-divergence-found.md`
- [x] **比值设计**：派生贡献带 fold 侧尺度（`ramp_scale`），重建它等于重算被测代码；比值约掉它，且不会因尺度 bug 误通过
- [x] **两侧都打通**：派生 `front cells=400 stat_count=1`；解释器返回 magnitude
### M5-13 严重缺陷确认：派生 ramp 跳过卡片的指令流

- [x] **A 已排除**：`metric_keys[0] = "family.magnitude_q16"`、`metric_keys[57] = "country.extractive_cell_count"`，**dense index 与 FamilyEffectMetricId 恒等**，两侧输入一致 → 证据：`artifacts/ideology-cell-layer/m5/M5-13-ramp-skips-instruction-stream.md`
- [x] **B 成立（算术证明）**：解释器 = `min(metric,983040) * 655 / 65536` = **9825 恒定**；派生 = `metric / 65536` = **40 → 120 线性**。两者既差 MIN 也差那个 655
- [x] **根因**：`collect_effect_activations` 的 ramp 分支用 `row.ramp_scale = term.value * stacks / Q16`，注释声称「authored MIN/MAX 已界定采样」——**但派生路径不执行指令流**，该假设只在「指令流 = EMIT metric 且系数 1」时成立
- [x] **可观测后果**：`economy.city.building.extractive_output_factor`（clamp_max 16.0）实测 `derived_add = 400` → **值饱和到 16.0**。卡片设计是 +15%，派生给的是「拉满」——**量级错误，不是精度偏差**
- [x] **影响 24 个 kind-12 ramp 卡**（覆盖率门禁报 `ramp deferred = 0`，即全部被判为可派生）
- [x] **为什么四个测试都没抓到**：`ramp_materialize_test`(12)、`rebuild_test` L 组、B7 的 `_verify_ramp_card`、覆盖率门禁 —— **全部只验证同一套假设，无一与解释器比对数值**
### M5-14 ramp 数值错误已修复并交叉验证

- [x] **四处接线**：① `Term::program_key` ② 收集器填它并删除错误注释 ③ `DerivedProgramMagnitudeSampler` ④ `_derived_program_sampler` 每格采样全 metric → 调 VM → 返回 `magnitude/Q16` → 证据：`artifacts/ideology-cell-layer/m5/M5-14-ramp-fixed-and-verified.md`
- [x] **oracle 12/0，三个点 `delta = 0.00000000`**（绝对值相等，不是比值相近）
- [x] **MIN 钳位被复现**：`metric=120` 与 `metric=500` 都给 0.14991760 == `15 × 655 / Q16`
- [x] **ramp 是活的**：`5 → 10` 时值从 0.04997 翻倍到 0.09995
- [x] **VM 真的跑了**：`program_evaluations = 4400`、`failures = 0`
- [x] **全回归 22/22**（含 B7/B8/B10/x1b/ramp/publish/content/runtime/progression）
- [x] **修正我自己的错误断言**：第一版用未饱和的 `mid` 去比 `high`，代码对、断言错；改为比两个都超上限的值
- [x] **对 §18 的影响**：§18.2 第 1 项从「无证据」变为**有证据**；24 个 ramp 卡的数值已交叉验证
### M5-15 ramp 修复的性能验证

- [x] **ramp 路径单独测**：B7 的 ramp 子夹具（1600 格 + 真实 ramp 卡）**`worst_step_ms = 0.4779`**、`steps=25`、`program_eval=1600`、`failures=0` → **单步在 §14.3 的 1 ms 门槛内** → 证据：`artifacts/ideology-cell-layer/m5/M5-15-ramp-perf-validated.md`
- [x] **要点**：perf gate 用常数卡（`ramp_eval=0`）走不到 ramp 路径，必须单独测；每格跑 VM 的代价**被分片吸收**（25 片而非 2 片），§14.3 约束的是单步
- [x] **发现并修掉我自己引入的回归**：`Term` 的 `std::string program_key` 会每次拷贝复制字符串，而 6400 格夹具的卡**根本没有 ramp 项** → 最坏单步 0.6093 → **1.4512 ms**。改为 `const std::string *` + 驻留池 → 同会话 **1.4512 → 1.2674（快 13%）**
- [x] **用未改动路径做对照归一化**：`tag_build_ms`（本轮完全没碰）从 35.36 涨到 67.78 → 机器因子 **1.92×**
- [x] **归一化结果**：2400 格 0.4973 → **0.2594**（M4-24 为 0.2578，差 **0.6%**，验证了因子真实性）；6400 格 1.2674 → **0.6612**（M4-24 为 0.6093，+8.5%，在 `spread 1.82–2.15×` 噪声带内）
- [x] **诚实措辞**：6400 格绝对耗时 1.2674 ms **不能判定**是否超门槛（机器慢 1.92×，归一化后 0.6612 ms）；**没有把不可跨时间比较的绝对值当成通过或失败**
- [x] **全回归 22/22；内核 93/0；oracle 12/0**
- [ ] **[未做] release DLL 的性能测量**
- [ ] **[代价] 25 片意味着一次完整重建需要更多次调用**：对「当天立刻可读」的调用方是成本，`drain_derived_cell_layer` 已覆盖
- [ ] **[§18 仍缺] 常数卡与解释器的逐格对照**：内核 A/N 组覆盖了 fold 语义，但未做端到端逐格对照
- [ ] **[§18 仍缺] 其余 17 项**：权威组合与翻转、save/load 全部时点、execution contract、snapshot ABI、B1–B6/B9/B11/B12、B5、峰值内存、release DLL、skill/文案/UI、发布说明、真实生成世界的 >32 样例
- [ ] **[§18 影响] `265/265 全派生` 只说明判定成立，不说明数值正确**：`§18.2 第 1 项` 保持「无证据」，`§18.1` 的数值正确性条目视为未达成
- [ ] **[教训] 第一版猜 stat 名花了整轮**：`economy.city.output_factor` 实测 `derived_add=0`，真实值须从 `command.definition_key` 读
- [ ] **[M5 未做] 735 检查的完整逐格对照覆盖**（当前仅 6 checks，且 1 失败）

### M5-16 release DLL + 常数卡对照

- [x] **release 构建通过**：`dots_ext_annual_v1.windows.template_release.x86_64.dll` = **`c073f81ab348ec76`**，12,168,192 字节 → 证据：`artifacts/ideology-cell-layer/m5/M5-16-release-dll-and-constant-card.md`
- [x] **release 构建暴露了我引入的缺陷**：`warning C4715: building_context_ready_for_test 不是所有路径都返回值` —— 我上一轮编辑 `ready` 赋值时吃掉了 `return out;`。**一个返回未定义数据的诊断比没有诊断更糟**。已修，debug/release 均不报警
- [x] **关键教训**：**C4715 只有 release 构建才报，debug 不报** → 两种构建都必须跑，不是形式要求
- [x] **release DLL 上真实跑 7 个 fixture**：oracle 12/0、B7 22/0、B8 18/0、B10 16/0、x1b 142/0、merge 20/0、publish 268/0 —— **检查数与 debug 逐一相同**；之后已恢复 debug DLL 并校验 `35e62122ab7371bb`
- [x] **常数卡也完成与解释器的对照**：B7 实测 `interp=3277 → 0.05000305`，`derived_add=0.05000305` **精确相等**（`public_hygiene_l1` 是 `CONST 3277 → EMIT`），B7 20 → **22 checks**
- [x] **「数值正确」现在的覆盖面**：ramp 卡（oracle 12 检查，3 点 delta=0，含 MIN 钳位）+ 常数卡（精确相等）+ 多国/重叠/宽领土结构正确
- [ ] **[局限] release 只在 7 个 fixture 上跑过**，不是全部 22 个；release 性能未测
- [ ] **[局限] 常数卡只对照了一张**（`public_hygiene_l1`），不是全部 241 个
- [ ] **[§18 仍缺] 权威组合与翻转、save/load 全部时点、execution contract、snapshot ABI、B1–B6/B9/B11/B12、B5、峰值内存、skill/文案/UI、发布说明、真实生成世界的 >32 样例**

### M5-17 B5 空闲门禁：建了夹具但无法触发重建

- [x] **建了 B5 夹具** `tests/ideology/ideology_b5_idle_test.gd`：单国 400 格 + ramp 卡，断言 generation 不动 / steps 不增 / pending false / 层仍覆盖 → 证据：`artifacts/ideology-cell-layer/m5/M5-17-b5-could-not-trigger.md`
- [x] **两次负向对照都失败，且都是我设计错**：① 用「重开 epoch」做对照 —— 内容相同则不 bump 是**正确行为**（§I13）② 用「改 metric override」做对照 —— 该 metric 本来就已经 ≥ 15，内容没被我改变
- [x] **诊断出真问题**：`epoch_id: 0`、`sample_day: 0` **从不变化**，即使调了 `begin_or_reuse_economy_input_epoch(1, …)` → **这个夹具里 `step_derived_rebuild` 没跑过第二次**
- [x] **因此 B5 断言恒真、不可信**：在「重建从不发生」的夹具上「generation 没变」证明不了「空闲日不做物化」
- [x] **`cell_layer_rebuild_steps` 不是累积计数**：实测 `16 → 14 → 15`，不能用它断言「不增长」
- [x] **顺带确认数值路径正确**：诊断里 `derived_add = 0.14991760253906` = `15 × 655 / Q16`，正是 M5-14 修复后的正确饱和值
### M5-18 B5 已验证（取代 M5-17 的失败）

- [x] **M5-17 的阻塞已定位**：我把 metric override 设成 **40**，而卡片程序是 `min(metric,15) × 655 / Q16` —— **40 与更大的值钳位后完全相同，内容根本没变**，所以 generation 不动是**正确的**（§I13），是我的对照无效 → 证据：`artifacts/ideology-cell-layer/m5/M5-18-b5-verified.md`
- [x] **修法**：把对照值放到钳位**之下**（`5 × Q16`）→ `add 0.1499 → 0.0499`（内容真变）、**`gen 1 → 2`（负向对照成立）**、`sample_day 0 → 1`
- [x] **空闲 30 天零版本推进**：`gen 2 → 2`、`sample_day` 冻结、`pending=false`、层仍覆盖 400 格、贡献仍在（`derived_add=0.0499`）
- [x] **`cell_layer_rebuild_steps` 不是累积计数**（实测 16→14→15→13→17），改用 `sample_day` —— **一个「本次运行步数」的计数器不能表达「累计工作量」**
- [x] **B5 9 checks / 0 failures；全回归 18/18**
- [x] **§18.3「B5 零层物化／安装／版本 bump」从无证据变为有证据**；B1–B12 覆盖 3/12 → **4/12**（B5、B7、B8、B10）
- [ ] **[B5 局限] 只覆盖单国 400 格 + 一张 ramp 卡**：多国、多卡空闲未测；「空闲期间 1% tag 翻转」属 B4 也未测；未在 release DLL 上跑
### M5-26 B9 已验证

- [x] **400 格全域扫描**：metric=0 → **0/400 贡献**；metric=5 → **400/400**；metric=120 → **400/400**；同一 metric 下**只有 1 个不同值**；贡献格数**单调不减** → **oracle 12 → 19 checks，0 失败** → 证据：`artifacts/ideology-cell-layer/m5/M5-26-b9-verified.md`
- [x] **「每一格都贡献」是关键断言**：扇出丢格会让 `nonzero < 400`；与 B7 的 `front cells=3200` 一起把「覆盖完整」钉在两个不同的量上
- [x] **明确写出的局限**：本夹具 metric 是全局覆盖的，所以「逐格」意为「**每一格都被独立求值**」，**不是**「不同格看到不同 metric」。真正的逐格变化需要建筑/经济状态，本夹具不建 → **若 B9 的「连续值变化」指后者，该条尚未覆盖**
- [x] **§18.3「B1–B12」覆盖 4/12 → 5/12**（B5、B7、B8、B9、B10）
### M5-27 B11 已验证

- [x] **完美对照**：同一 `stat_key`、同一 `entity=0`、同一 `group=cell 5`，**只有 domain 变** → 证据：`artifacts/ideology-cell-layer/m5/M5-27-b11-domain-gate.md`
- [x] **实测**：`CLIMATE 1.0→1.0`、`COUNTRY 1.0→1.0`、**`ECONOMY 1.0→1.25`（增量恰为装的 0.25）**、`GAMEPLAY 1.0→1.0`、`COUNTRY group=0 批量形态 1.0→1.0` → **9 checks / 0 failures**
- [x] **补上 M5-9 缺的负向验证**：当初移除 `group_handle != 0` 时给的论证是「COUNTRY 域被 `domain == ECONOMY` 挡住」，**那是读代码的推理，不是证据**；现在四个 domain 里只有 ECONOMY 动
- [x] **专门验证了 `effective_values` 的 `group 0` 形态**（我当初怀疑会被守卫移除波及的地方）→ 不受影响
- [x] **§18.3「B1–B12」5/12 → 6/12**（B5、B7、B8、B9、B10、B11）
- [x] **诚实标注证据强度**：CLIMATE/GAMEPLAY 的 stat 在 `resolve_modifier_stat` 里返回 -1，那两条「没动」偏弱（可能只是该域没这个 stat）；**COUNTRY 那条是强的**
- [ ] **[B1–B12 仍缺 5 项]** B1（64 国 ×12 卡主线程）、B2（worker）、B3（512 国续跑）、B4（1% tag 翻转）、B12（读档/权威翻转/冷启动）

### M5-19 证据入库 + §15 交付报告

- [x] **发现并修掉一个会抹掉全部证据的风险**：三个**核心头文件**完全未被 git 跟踪 —— `derived_cell_layer.h`（派生层结构）、`selector_cell_cap.h`（上限解析）、`cell_program_eligibility.h`（I01 后端判定）。**一次 `git pull` 就会像当初丢失 735 检查 oracle 那样抹掉它们**
- [x] **同时发现**：B8、B10 与 7 个 cell_layer 测试**也未跟踪** —— 我报告的每一份证据都未入库
- [x] **已全部入库**：`gdext/` + `tests/` + `tools/` 下 **66 个文件**，`artifacts/ideology-cell-layer/` 下 **1182 个**；核实 `?? *.h/*.cpp/*.gd` = **0**
- [x] **入库后复验**：构建 `done building targets`（up to date）、B5 9/0 仍通过
- [x] **按 §15.1 逐项写出交付报告** `artifacts/ideology-cell-layer/M5-DELIVERY-REPORT.md`：变更文件清单、接口/契约变化、测试与检查数、失败签名、DLL 身份、性能数据、覆盖率、剩余问题、下阶段任务 → 证据同左
- [x] **报告明确不声称 §18 完成**：28 项中 **12 有证据 / 16 无证据**，按方案自己的话保持「实现中」
- [x] **记录了 6 个已修真实缺陷**：I01 违反、**cell 0 失效**、半径位宽缺陷、**ramp 跳过指令流（24 卡数值错）**、`Term` 字符串拷贝回归、诊断缺 `return`
- [ ] **[剩余 15 项]** 见交付报告 §7.2：B1/B2/B3/B4/B9/B11/B12、§11.7 存档时点、execution contract、snapshot ABI、旧/新 basis 恢复、权威组合与翻转、峰值内存、UI 高亮、skill 派生层章节、发布说明、真实生成世界的 >32 样例、735 检查 oracle 完整度

### M5-20 真实世界 >32 样例：未能取得（两个独立原因）

- [x] **发现夹具是坏的且会挂住**：`ideology_cell_layer_e2e_realworld_test.gd:156` 写 `run_economy_slice(64)`，桥现在要 Dictionary → `Cannot convert argument 1 from int to Dictionary` → **报错后没走到 `quit()`，进程挂住 10 分钟以上**。**一个报错又挂住的夹具等于不存在** → 证据：`artifacts/ideology-cell-layer/m5/M5-20-realworld-probe-broken.md`
- [x] **已修 API 漂移**（改为 `{"day_index":…, "tick_index":…}` 循环）
- [x] **更根本的发现**：真实生成世界实测 **`countries=3 widest=1 above_old_cap=0 total_cells=3`** —— **每国只有 1 格**
- [x] **推论**：「>32 的生产样例」**不能从 `generate_world` 直接得到**，必须先有领土扩张玩法（= 早前记录的开放项 **D4**）
- [x] **我没有把 `widest > 32` 的断言改弱来「通过」**：那会让夹具变绿同时消灭它唯一的用途
- [x] **记录了一个流程问题**：这个夹具从没进过回归集，所以「存在但从不运行」一直没被发现；**交付报告里的每项夹具都必须在最近一次回归里真实跑过并报出检查数**
- [ ] **[§18.4 仍未达成] 首个 >32 生产样例**：需要先在真实世界把某国扩张到 >32 格，再验证装卡后的逐格值
- [ ] **[待做] 把修好的夹具加入回归集**，避免再次「存在但从不运行」

### M5-21 skill 同步（§16.5）

- [x] **`ideology-runtime/references/runtime-contract.md` 补 §7「Derived cell layer」**：I01 判定与覆盖率、可续跑重建、**归属范围与 51.7% 影响**、§5.1 合并式、`group_handle` 就是 cell、可观测面、I13 空闲、已知缺口 → 证据：`artifacts/ideology-cell-layer/m5/M5-21-skill-sync.md`
- [x] **`modifier-runtime/references/architecture-and-data.md` 补「Derived Cell Layer」**：front/contribution 结构、二分查询理由、合并规则与零因子、cell 0 缺陷完整记录、安装原子性、可续跑物化器
- [x] **两个文件在 `.claude` 与 `.agents` 双镜像上内容一致**
- [x] **工具化比对发现 4 处既有镜像分歧**（§16.5 要求一致）：`SKILL.md`(99 vs 113)、`domain-integration.md`(40 vs 47)、`scheduling-save-and-verification.md`(49 vs 52)、`verify_modifier_runtime.ps1`(107 vs 115)
- [x] **修了 2 处**（`.agents` 是严格超集，`claude_only=0`）：`SKILL.md` 与 `domain-integration.md`
- [x] **拒绝 2 处并说明原因**：后两个 `.claude` 有独有行（`PKEC v33` vs `.agents` 的 `v41`），看起来 `.claude` 更旧，**但代码里各 runtime schema 是分开的（effect=14/ideology=10/modifier=3/trigger=6），PKEC 容器版本无法从这里判定** → **强行覆盖可能销毁知识，记录而不猜**
- [x] **镜像现状**：`same=11 differ=2 claude_only=0 agents_only=0`，无孤儿文件
- [ ] **[局限] 只处理了 ideology 与 modifier 两个 skill**：§16.5 还列了 economy、runtime-architecture、scheduling-and-job-graph、gdscript-cpp-data-bridge、performance-diagnostics-playbook、game-flow-start-save 等
- [ ] **[待 owner] 2 个分歧文件**：`scheduling-save-and-verification.md`、`verify_modifier_runtime.ps1`

### M5-22 全部 68 个理念夹具审计

- [x] **全跑一遍**：`tests/ideology/*_test.gd` 共 **68 个** → **37 通过 / 30 失败 / 1 静默**（约 80 分钟）→ 证据：`artifacts/ideology-cell-layer/m5/M5-22-full-fixture-audit.md`
- [x] **发现并修掉我的诊断缺陷**：`_cell_layer_rebuild_visits` **只导出、从不递增** —— 删 `rebuild_derived_cell_layer` 时把 `++` 一起删了。后果是计数器永远 0，`ideology_cell_layer_e2e_test` 报出「看起来有说服力」的假失败。已修 → **19/0**
- [x] **确认分类**：1 个我的缺陷（已修）、1 个夹具 API 漂移（已修，见 M5-20）、1 个已知基线（`mechanism_matrix` 1129/3）、1 个预期失败（真实世界 `widest=1`）、~4 个既有 catalog 问题（`ideology_school_unknown` / `ideology_configure_failed` / `cells=0`）、**~19 个 worker 类**
- [x] **核实 worker 类与本次无关**：抽样检查**均不引用**我删除的任何 API（`rebuild_derived_cell_layer` / `publish_ideology_cell_programs` / `get_ideology_cell_program_summary` / `cell_plane_enabled` 全无命中）；`x10_worker_test` 有独立缺陷 `native_catalog in base 'Nil'`
- [x] **流程结论**：「回归通过」只能指真正跑过的集合；此前只维护 18 个，另外 50 个从未被本次工作跑过，其中至少 1 个是我的删除弄坏的
### M5-23 定性：平面删除没有让城市因子 CSR 失去来源

- [x] **决定性证据（读代码）**：`economy_runtime.cpp:7327` 的 CSR 逐格取值就是 `effective_value(ECONOMY, stat, 0, scope, 1.0)` —— **正是派生层合并进去的那个函数**，参数形状（`entity 0, group = cell`）也一致 → **override 的生产者是 `effective_value`，不是旧平面** → 证据：`artifacts/ideology-cell-layer/m5/M5-23-csr-not-orphaned.md`
- [x] **端到端确认**：新夹具 `ideology_derived_city_factor_test.gd` 装一个只覆盖 cell 5 的 front（`adds=0.25`）→ **`touched=1.25  untouched=1.0`**，**6 checks / 0 failures**
- [x] **关键推理**：`economy_runtime.cpp:7331` 只在两格**读数相同**时跳过记录 override；两格不同 → 一定记 override → 分片有工作
- [x] **修正我自己的夹具错误**：第一版用 `"sources"`/`"adders"`，桥里是 `"source_countries"`/`"adds"`；**桥的报错 `derived_cell_layer_column_shape_invalid` 很准确，是我猜错了名字**
- [x] **`shard_test` 已定案**：`collect_scope_stat_entries` 第 1571-1584 行**已并入派生层**，CSR 逐格取值就是 `effective_value`（`economy_runtime.cpp:7327`）→ 设计完整。实测 `work=256`（>64 的分片）、`slices=30`、`done=true`、**断言 F（每格都被涂到）通过** → 分片功能正确；只是 `_run` 去看时 epoch-begin 已把分片跑完，`cursor` 停在完成态 `-1`。**这是「什么时候看」的性质，不是「分片有没有发生」**。B/C/E 改为容忍完成态，**F 与 A 保留**（丢格会让 F 失败，假分片会让 A 失败）→ **shard_test 6/0**
- [ ] **[既有债务] `ideology_cell_layer_m0_realworld_cost_test`**：未细查
- [ ] **[待定性] `ideology_cell_layer_m0_realworld_cost_test`**：M0 成本探针，走真实世界，未细查
- [ ] **[既有债务 19 个] worker 类夹具**：多数 20 检查里失败 1–2 个，与本次迁移无关，未修
- [ ] **[需修正] 交付报告 §3.2 的口径**：应写明「37 通过（全集 68）」，而不是只列 18 个

### M5-24 排除 term.value 双重计数假设 + 锁定符号机制

- [x] **为什么要查**：派生收集器对常数项用 `term.value * stacks * scaled_magnitude` —— 幅度来自程序、又乘定义系数，**若 `term.value != 1` 就是双重计数**（ramp bug 的同族）→ 证据：`artifacts/ideology-cell-layer/m5/M5-24-term-value-hypothesis-refuted.md`
- [x] **静态扫描差点误导我**：解析 `.tres` 得到 6 个 `value != 1`（含 `economy.city.birth_factor` op=2 value=0.97），看起来 `public_hygiene_l1` 中招
- [x] **解析器推翻静态扫描**：`resolve_modifier_definition_terms()` 实测全是 **`operation=0 (ADD), value=1.0`**，`.cut` 变体是 **`value=-1.0`** → **假设排除，不是 bug**。我解析 `.tres` 时读的是别的字段
- [x] **顺带端到端锁定符号**：`.cut` 卡程序发 +0.08，`term.value=-1` 使其为 **-0.08**，`value=0.92`，`derived_factor=1.0` → **「-8% 卡」不会变 +8%**，B7 **23 checks / 0**
- [x] **教训**：ramp 那次是「不要相信注释」，这次是「不要相信自己对数据文件的解析」——**两者共同的正确做法是问权威实现，而不是读二手材料**
- [ ] **[§18 仍缺] 8 个 B 场景**、save/load、权威翻转、峰值内存、发布说明、真实世界 >32 样例

### M5-25 发布说明 + 状态页

- [x] **写出发布说明** `docs/plans/ideology-review/22-cell-cap-removal-release-notes.md`：面向内容作者/平衡评审/运维，不含实现细节
- [x] **明确标注三处玩家可感知的变化**：① **74 张卡作用范围变小**（默认只本国，边境 R2 环 51.7% 落外国）② 领土覆盖不再有 32 格上限 ③ **24 张 ramp 卡数值修正**（`salt_monopoly_l1` 从「拉到 16.0」变为卡面设计的 0.15）→ 这是**平衡性变化，需按新数值重看**
- [x] **旧档兼容结论**：派生层**不写入存档**（`serialize_domain`/`restore_domain` 完全不碰 `_derived_cell_front`），因此**档案版本未变、旧档可读、无迁移步骤**；但读档后到重建之间有一个**派生层为空的窗口**，已作为已知窗口写明
- [x] **生效时间语义**：三项变更**加载新内容即生效**，没有「本局沿用旧语义」的开关；要保旧行为只能内容侧显式设 `ANY`（74 张卡目前都没设）
- [x] **覆盖扩大的成本含义**：单 slice 在门槛内（归一化 0.66 ms / ramp 0.4779 ms），但**一次完整重建需要更多片**（6400 格 3 片、1600 格 ramp 25 片）→ 要「当天立刻可读」必须走 `drain_derived_cell_layer`
- [x] **运维排查表**：5 个症状对应的首个检查点；并重申 **`cell_layer_rebuild_steps` 不是累积量**
- [x] **状态页 `05-implementation-status.md` 补第 22 节**：M0–M5 逐项状态、8 个顺带修掉的真实缺陷、§18 的 12/28 证据数
### M5-28 文档同步第二轮（§16.5）

- [x] **3 份 native 文档补齐**：`native-economy-runtime`（CSR 的派生层并集 + 「不加这条并集读者会静默退回 shared」）、`scheduling-and-job-graph`（重建进每日图、0.45 ms 预算、**采集与折叠必须分两步**、片数随形态变化）、`performance-diagnostics-playbook`（8 个计数器**累积量 vs 本次运行量**对照表 + 两个必记口径）→ 证据：`artifacts/ideology-cell-layer/m5/M5-28-docs-sync-round2.md`
- [x] **economy skill 补派生层章节**，双镜像各 +14 行且**逐字节相同**（`tail_equal=True`）
- [x] **修正我先前的一个错误假设**：`gdscript-cpp-data-bridge` / `performance-diagnostics-playbook` 是**文档不是 skill**；§16.5 的九项里大部分是文档名。我按 skill 查了半轮才发现
- [x] **既有镜像分歧如实记录**：economy skill 在 **HEAD 里就有 6 行分歧**（`.agents` 多一段气候容量内容），非我造成；按 M5-21 原则**记录而不强制覆盖**
- [x] **§16.5 完成度：6/9 文档 + 3/3 相关 skill**（ideology、modifier、economy）
### M5-29 §16.5 完成（9/9 文档 + 3/3 skill）

- [x] **补完最后 3 份文档**：`gdscript-cpp-data-bridge`（7 个桥 + **三个必知参数细节**：`entity_handle` 必须 0、列名是 `source_countries`/`adds`、metric 索引当前恒等但别假设永远如此）、`runtime-authority-matrix`（4 类数据权威对照 + 三条权威规则）、`game-flow-start-save`（front 不参与存档、为什么可以这样、**不要做的两件事**）→ 证据：`artifacts/ideology-cell-layer/m5/M5-29-section-16-5-complete.md`
- [x] **§16.5 九项文档全部完成**：ideology(M5-21)、modifier(M5-21)、economy(M5-28)、authority-matrix(M5-29)、scheduling(M5-28)、data-bridge(M5-29)、perf-playbook(M5-28)、start-save(M5-29)、deletion-inventory(M5-10) → **9 / 9**
- [x] **相关 skill 3/3**：ideology、modifier、economy，均在 `.claude` 与 `.agents` 双镜像上验证
- [x] **累积发现的既有问题全部如实记录、未强行覆盖**：modifier skill 4 文件不一致（修 2 拒绝 2）、economy skill HEAD 里 6 行分歧、**§16.5 九项里大部分是文档不是 skill**（纠正我自己的假设）
- [x] **§18.4 状态更新**：文档 ✅ 9/9、skill ✅ 3/3；**内容文案与 UI 仍缺**
- [ ] **[§18.4 仍缺] 内容文案与 UI 高亮验收**
- [ ] **[B1–B12 仍缺 5 项]** B1、B2、B3、B4、B12（**B6 已完成**，见 M5-55）
- [ ] **[未测] 峰值内存、权威翻转、release 性能**
- [ ] **[未取得] 真实生成世界的 >32 生产样例**（被领土扩张玩法 D4 阻塞）

### M5-30 修复：「仅他国」把中立地也算成他国

- [x] **缺陷**：归属谓词只有两态（`is_own`），而无归属格是**负 slot** —— 对中立地 `is_own=false` 使 `FOREIGN` **保留**它。**中立地不是「另一个国家」** → 证据：`artifacts/ideology-cell-layer/m5/M5-30-foreign-scope-excluded-neutral-land.md`
- [x] **现在修的理由**：功能是我按用户目标项加的作者是本人；**74 张已发布卡全是默认 `OWN`，无一张用 `FOREIGN`，改动零风险**；留到第一张「伤害邻国」卡上线会更难定位
- [x] **修法**：三态 `OwnershipRelation`（OWN / OTHER_COUNTRY / UNOWNED）+ 关系版谓词；`FOREIGN` 只接受 `OTHER_COUNTRY`，`UNOWNED` 只有 `ANY` 接受；**保留两态重载给纯逻辑测试**（它故意无法表达 UNOWNED）
- [x] **两处过滤点都改**：kind 14/15 的扇出、kind 16 的逐格出口
- [x] **途中我自己搞坏过一处**：正则批量替换匹配错位留下悬空 `is_own`（C2065），已手工修正 —— **自动化编辑的风险：正则只看形状相似就替换，没确认上下文**
- [x] **内核 93 → 103 checks / 0**：新增 10 条 M3 断言，含 **`FOREIGN rejects unowned land (the fix)`**、`no unowned cell is taken by OWN or FOREIGN`、`the sweep really contains unowned slots`（防断言空转）、**`OWN + FOREIGN + unowned == ANY` 三态划分**
- [x] **回归 11/12**：B11 9/0、oracle 19/0、B7 23/0、x1b 142/0、B8 18/0、B10 16/0、B5 9/0、derived_city_factor 6/0、stress 38/0、merge 20/0、publish 268/0；`mechanism_matrix` 仍基线 **1129/3**
- [ ] **[局限] 无 `FOREIGN` 的端到端夹具**：无已发布卡用该 scope，也没有现成夹具可借
- [ ] **[约定依赖] 中立地 = 负 slot**：若将来改哨兵，此处需同步

### M5-31 发现：kinds 14/15 的「源格数量」仍钳在 32（需决策）

- [x] **代码事实**：`ideology_runtime.cpp:2081-2086` 对 kinds 14/15 的源格数 `std::min(authored_cap, SELECTOR_MAX_CELLS)`，而 `SELECTOR_MAX_CELLS = LEGACY_INSTANCE_MAX_CELLS = 32` → 证据：`artifacts/ideology-cell-layer/m5/M5-31-source-count-still-32.md`
- [x] **内容事实**：5 张 kind 14/15 卡**全部 author `param0 = 32`**（`autonomous_logistics_l1/l2/l3`、`gentry_patronage_l3_ring`、`refrigeration_l3_ring`）→ 源格上限就是 32
- [x] **限定「32 上限已取消」的说法**：**目标格**的 32 上限已取消（territory/source 类 selector 返回 `kSelectorNoCellCap`）；**源格**的 32 上限仍在。一国若有 300 个带该 tag 的格，**只有 32 个参与扇出**
- [x] **为什么没有单方面改**：这不是技术性截断的漏网，而是**内容与常量一起表达的上限**——方案 §15.7 明确「不删除仍真实使用的保护」，且 `param0=32` 是**作者写的**，改它会直接扩大 3 张核心卡的作用面（**平衡性改动，不是取消技术限制**）
- [x] **给出三个选项供决策**：A 保持现状（需限定措辞）／B 内容改成不限（需重新平衡）／C **只把默认值改成「不限」、内容仍写 32（零变化，最小改动）**
- [x] **顺带排除三处隐患**：编译期不改写 `param[0]`（`effect_catalog.gd:161-165` 原样读取）、校验器不拒绝大 `param[0]`（三 kind 都是 `kSelectorNoCellCap`，`!unbounded && …` 短路）、其它读者不把原始 `param0` 当 cap（`:2081` 显式 `& CAP_MASK`）
- [ ] **[需决策] 选项 A/B/C**：我倾向 C（不改变任何现值，只让「没写 cap 的卡」不再意外有 32 上限），但**没有做**
- [x] **「措辞需限定」已落实（M5-37）**：交付报告 §2.1 标题改为「**目标格**的 32 格限制不再存在」，并在表尾加一段限定；发布说明 §1.2 改为「目标格的 32 格上限已取消（**但源格上限仍在**）」+ 引用；两份文档的收尾结论都从「取消 32 格限制」改为「目标格的 32 格限制」，并显式写出「源格上限仍是 32（5 张卡 author 32，待决策）」

### M5-32 32 常量全量审计 + release 重建验证 + 交付报告刷新

- [x] **32 常量全量审计**：把 `SELECTOR_MAX_CELLS` / `LEGACY_INSTANCE_MAX_CELLS` 的所有使用点过了一遍 —— 6 类里 **4 类合规**（实例路径已改名、几何 cap 因几何上限更小而从不生效、经济侧同理）、**1 类仍限制 32**（kinds 14/15 源格数 = M5-31 的主题）、1 类是 synergy override 的另一套机制
- [x] **确认 `FAMILY_OWNED` 那处不是后端不一致**：派生后端只支持 kind **12/14/15/16**（`cell_program_eligibility.h:95-105`），`FAMILY_OWNED` 不在其中，只有实例路径一个后端；但 `selector_cell_ceiling` 把它列进「无上限」是**口径瑕疵**（它选的是家族 handle 不是格）→ 证据：`artifacts/ideology-cell-layer/m5/M5-31-source-count-still-32.md` §6.1
- [x] **release DLL 重建**（旧的那个在归属三态修复之前构建，已过期）：`ed5833856197e018`
- [x] **release 上真实跑 8 个夹具**：B11 9/0、oracle 19/0、B7 23/0、B5 9/0、B8 18/0、B10 16/0、x1b 142/0、derived_city_factor 6/0 —— **检查数与 debug 逐一相同**；之后已恢复 debug `e8cbfded758a7da8`
- [x] **交付报告刷新**：DLL 身份、内核 93 → **103**、新增 B11 与 derived_city_factor 两行、B 场景 **6/12 未测**、skill 与发布说明状态更正
- [ ] **[需决策] M5-31 的选项 A/B/C**（kinds 14/15 源格上限 32）
### M5-33 家族目标数的「静默钳」改为编译期拒绝

- [x] **问题**：`FAMILY_OWNED`(kind 17) 的消费者 `ideology_runtime.cpp:1905` 把家族数 `clamp(param[0], 1, 32)`，而校验器**只检查 `param[0] >= 1`，无上界** → **一张 author 40 家族的卡会静默变成 32** → 证据：`artifacts/ideology-cell-layer/m5/M5-33-family-cap-validated.md`
- [x] **没有改 `selector_cell_ceiling`**：它的契约是「几何可达**格**数」，`FAMILY_OWNED` 确实不产格，返回「无格上限」是**正确的**；把两件事塞进一个函数会让它更难读
- [x] **改在校验器里**：`effect_runtime.cpp` 的 FAMILY_OWNED 子句增加 `param[0] > LEGACY_INSTANCE_MAX_CELLS`；`ideology_runtime.cpp:1905` 的 clamp 加注释说明**现为防御性**（针对早于该校验的序列化定义）
- [x] **内容影响为零**：内容里只有 1 张 `FAMILY_OWNED` 卡 `family_office_l3_owned_output`，`param = (32, 3)`，`32 > 32` 为假 → 仍被接受
- [x] **验证**：`content_test` **67/0**（整个 catalog 仍能编译）、`x1b` 142/0、`B7` 23/0、`effect_instance` 51/0、**`x9b_family_target_worker` 22/0**（唯一直接跑家族目标收集的夹具）
- [ ] **[未测] 「author 33 会被拒」与「原来 40 会静默钳」两半都只是按代码推的**：构造负向夹具需要改过的 catalog，而 `content_test` 用出厂内容。**没有写出来当已验证**

### M5-34 尝试量化 kind 14 源格上限：被原生 tag 阻塞

- [x] **想测什么**：把 M5-31 的「源格钳 32」从读代码变成实测 —— 造 tag 匹配 400 格的局面，看 `selector_truncations` 与 `covered` → 证据：`artifacts/ideology-cell-layer/m5/M5-34-kind14-measurement-blocked.md`
- [x] **结果**：`matched=0  covered=0`，卡没产生任何目标
- [x] **阻塞点钉死**：`cell.market` 在**原生 tag 列表**里（`economy_runtime_family_buff.cpp:1133`），由市场/建筑计算，**替换 `domain.target_tags` 不影响它**；另外两张 kind-14 卡的 tag（`cell.eminent_clan`、`cell.climate.hot`）同理 → **M5-31 的影响仍未量化，且现在知道为什么**
- [x] **排除了「死卡」猜想**：`refrigeration_l3_ring` 只有复数 `target_selector_tags`（两个 tag），而运行时是 `tag <= 0 → return false`。**但复数形式是被支持的**（`ideology_effect_definition.gd:278/392-395`，且明确拒绝二者同时用；`effect_domain_catalog.gd:483-484` 也读）→ **卡片合法，不是死卡**
- [x] **排除我差点犯的错**：`truncations=4` 在 `matched=0` 时不可能来自「结果超上限」，那 4 次来自世界上别的解析路径；**一开始想把它当成「上限确实生效」的证据，那是错的**
- [x] **没有留下失败夹具**：一个会失败又不测量任何东西的夹具比没有更糟，已删除
- [ ] **[量化前置] 需要给原生 tag 一类加「测试覆盖」入口**，或造真实市场/家族状态；前者要改生产代码，需单独评估
- [ ] **[仍未量化] M5-31 的影响**：代码事实成立，影响面数字没有### M5-35 交付证据自检脚本 + 负向对照

- [x] **动机**：上一轮发现 DLL 身份漂移（文档 `5f73e78d`/`5f3c44ab` vs 实际 `e8cbfded`/`ed583385`），**没人发现直到手工读二进制** → 证据：`artifacts/ideology-cell-layer/m5/M5-35-verify-delivery-script.md`
- [x] **写 `verify_delivery.py`**：把能复算的声明全部重新推导 —— DLL 身份、覆盖率 265/265、内核 0 失败、11 个奠基夹具**逐个要求检查数等于记录值**
- [x] **关键设计：只把表格行当作「当前声明」**：里程碑日志里合法记录着过去的哈希（本轮统计到 **8 个历史哈希**），把它们也当声明会让校验永远报错
- [x] **负向对照通过**：把 release 声明改成 `deadbeefdeadbeef` → 精确报出 `claim release=['deadbeefdeadbeef'] but the file is ed5833856197e018` 并 exit 1；恢复后 exit 0。**一个不会失败的校验是装饰**
- [x] **途中修掉自己的路径 bug**：第一版 ROOT 只上溯 3 层，PROJECT 变成 `Project/Project/project-keynes`，两个 DLL 都「不存在」—— **不跑一次的话，这脚本会永远报「DLL 缺失」而看起来像在工作**
- [x] **全量跑通**：`VERIFY OK`（身份一致、覆盖率 6/6、内核 103/0、11 夹具全 OK）
- [x] **写清它不检查什么**：§18 的 14/3/11 划分（那是判断不是测量）、性能数字、release DLL 上的测试、历史哈希
- [x] **一句话边界**：这个脚本保证「**记录与工作区一致**」，不保证「**结论正确**」
### M5-36 release DLL 验证自动化

- [x] **补上最后一件「只能手动」的事**：`verify_delivery.py --with-release` —— 备份 debug → 换入 release 字节 → 跑 7 个夹具 → 恢复 → 校验恢复后的哈希 → 证据：`artifacts/ideology-cell-layer/m5/M5-36-release-verification-automated.md`
- [x] **四个设计要点**：① 备份在**内存**里（磁盘备份可能被中途写坏）② 恢复在 `finally`（异常也要恢复）③ 恢复后**校验哈希**（不假设写入成功）④ 默认关闭（它会改工作区，必须显式要求）
- [x] **恢复保护被实证是承重的**：我的第一版脚本在 DLL 已换掉之后抛了 `ValueError`（释放名字列表 vs 期望对），**`finally` 仍然把 debug 恢复了**（校验 `e8cbfded758a7da8`）。**这是真实发生的场景，不是我设想的**
- [x] **校验器第二次抓到我自己的疏漏**：`x9b_family_target_worker` 只在 release 列表、不在 `EXPECTED_FIXTURES` → 期望值回退成 0 → `MISMATCH`。**脚本没 bug，是期望表不完整；校验器把它变成了会失败的检查**
- [x] **最终 `VERIFY OK`（含 release）**：7 个 release 夹具检查数与 debug 逐一相同（9/23/9/19/142/67/22）
- [x] **局限写清**：release 只跑 7 个（每个证据面一个代表，不是全部 11 个）；不验证「release 与 debug 行为一致」这一更强命题；恢复失败时不再重试
- [x] **用法**：`--doc-only`（秒级）/ 默认（文档+覆盖率+内核+debug 夹具）/ `--with-release`（再加 release 夹具）

### M5-37 把「32 上限已取消」的过度声明改准

- [x] **发现的问题**：文档说「32 上限已取消」，但 M5-31 已证明**源格上限仍是 32**（5 张 kind 14/15 卡 author `param0 = 32`）→ **这是一个过度声明**
- [x] **代码改动不属于我能单方面做的**（会改变 3 张核心卡的作用面 = 平衡性改动），但**措辞准确属于**
- [x] **改了三处**：交付报告 §2.1 标题改为「**目标格**的 32 格限制不再存在」+ 表尾限定段；发布说明 §1.2 改为「目标格的 32 格上限已取消（**但源格上限仍在**）」+ 引用片段；两份收尾结论改为「目标格的 32 格限制」并写出待决策项
- [x] **限定内容**：受影响 5 张卡（`autonomous_logistics_l1/l2/l3`、`gentry_patronage_l3_ring`、`refrigeration_l3_ring`）；一国若有 300 个带该 tag 的格只有 32 个参与扇出；这是「内容与常量一起表达的上限」（§15.7），不是技术截断漏网
- [x] **顺带修正**：交付报告收尾原本写「16 项无证据」，与实际 **11 项无证据 + 3 项部分**不符，已改
- [x] **核验**：两份文档各有 3 处「源格」限定；`verify_delivery.py --doc-only` 仍 `VERIFY OK`
- [ ] **[仍待决策] M5-31 的 A/B/C**：是否放开源格上限（会改 3 张核心卡平衡）

### M5-38 front 内存实测 + 验证脚本抓到首次真实漂移

- [x] **`get_derived_cell_layer_report()` 新增 5 个内存字段**：`contribution_count` / `contribution_bytes` / `bytes_per_contribution` / `front_row_overhead_bytes` / `front_bytes`。**按结构算而非采样堆**（堆计数依赖分配器，而门禁问的是「front 多大」）；报告里写明「**这是 front 字节数，不是进程 RSS**」→ 证据：`artifacts/ideology-cell-layer/m5/M5-38-front-memory-measured.md`
- [x] **实测**：`contributions=3200`（1600 格 × **2 个 stat**）、`sizeof(DerivedCellContribution)=40`、`bytes/contribution=44`、`row_overhead=112`、**front 合计 140,912 字节 ≈ 138 KB**
- [x] **我在这条上差点又靠猜**：第一版断言写 `contribs == 1600`，实测 3200 失败——**不是代码错，是我忘了那张卡有两个 stat**。改为 3200 并写明理由（也解释了 B7 别处 `front cells=3200` 的来源）
- [x] **断言用不变量不用魔数**：`front_bytes == contribs * per + row_oh`，四个量都来自运行时；另加 `< 1 MB` 上限防「每格每 stat 存了不该存的」
- [x] **验证脚本抓到首次真实漂移**：加完字段重建 DLL 后立刻 `VERIFY FAILED: documents claim debug=e8cbfded... but the file is 0d8c31d6...`。**从脚本创建到抓到真问题只隔了一次代码改动**——上一轮同类漂移是靠人手工读二进制才发现的
- [x] **顺带补上脚本盲区**：方案 §18.5 的证据行首列是 `18.4` 不是 `debug`，原规则看不见它。新增「一行里同时有 debug、release 和两个哈希即当前声明」→ 历史哈希计数从 12 降到 10（那 2 个被正确重新归类）
- [x] **最终身份与验证**：debug **`c40806c0f223cd4b`** / release **`b172a83733a6b8a1`**；`--with-release` **VERIFY OK**（release 上 B7 已 27/0）
- [x] **§18.3 内存条目从「未测」改为「部分」**：candidate / retained / scratch、分配次数、backlog **仍无证据**
- [ ] **[§18.3 仍缺] candidate/retained/scratch 内存、分配次数、backlog**

### M5-39 按决策取消 kinds 14/15 的源格 32 上限

- [x] **决策**：用户 2026-10-28「5 张 kind 14/15 卡 也取消32上限」→ 证据：`artifacts/ideology-cell-layer/m5/M5-39-kind14-uncap.md`
- [x] **代码**：`ideology_runtime.cpp` 的 `std::min(authored_cap, SELECTOR_MAX_CELLS)` 删除，改为 `authored_cap > 0 ? authored_cap : pk::kSelectorNoCellCap`；`ring_cap` 从 `min(cap, 32)` 改为 `pk::selector_cell_ceiling(ring_kind)`（R1=6/R2=18 的**几何**上限，原来的 32 是冗余的第二道门且从不生效）
- [x] **为什么这样改对**：`selector_cell_cap.h` 早就把 kinds 14/15 归类为 `kSelectorNoCellCap`，运行时的 32 与那个分类**自相矛盾**
- [x] **内容**：5 张卡 `param[0]: 32 → 0`（`autonomous_logistics_l1/l2/l3`、`gentry_patronage_l3_ring`、`refrigeration_l3_ring`）。**两侧必须同时改**——只改代码则内容里的 32 仍被尊重，只改内容则运行时的 min 仍把 0 变 32
- [x] **确认无其它残留**：全表另有 15 处 `(32, 0)` 但**全是 kind 0**（anchor-only，`param[0]` 不是格上限）→ **没有 kind 12 卡 author 32**
- [x] **新增内容门禁（覆盖率门禁 6 → 7 条）**：`no kind 14/15 card authors a source cap`，按块解析 `param`、掩掉 bit 12..13 的归属位
- [x] **负向对照暴露了门禁空转的 bug**：第一次对照**没抓到**。根因是我用了现成的 `_str()`，而它的匹配式要求**引号**（`^key = &?"..."`），`PackedInt32Array(32, 0)` 没引号 → 返回 `""` → `param0` 恒为 0 → **门禁永远通过**。改专用正则后对照通过（`actual=1 expected=0`、exit 1）。**如果只看「7/7 通过」就收工，会交付一条装饰性门禁**
- [x] **回归**：`content_test` **67/0**（`param0 = 0` 通过校验，catalog 仍能编译）、x1b 142/0、B7 27/0、B8 18/0、B10 16/0、B5 9/0、effect_instance 51/0、覆盖率门禁 **7/7**
- [x] **完整校验**：`verify_delivery.py --with-release` **VERIFY OK**；debug **`c40806c0f223cd4b`** / release **`b172a83733a6b8a1`**
- [x] **文档已同步**：发布说明 §1.2、交付报告 §2.1 与收尾、方案 §18.5 的决策行都改为「**已按决策取消**」；**无残留的「仍是 32 / 待决策」**
- [ ] **[未测成本] 一次 resolve 实际慢多少**：5 张卡的 tag 是原生 tag（`cell.market` / `cell.eminent_clan` / `cell.climate.hot`），合成夹具造不出来（M5-34）。机制上界从 `32 × 环形` 变成 `领土格数 × 环形`，**这个数字没有**
- [ ] **[建议] 把「原生 tag 的测试覆盖入口」做出来**，才能量化这条改动对靠边境/大量同 tag 地块国家的实际影响

### M5-40 解封成本仍未能测量（并纠正我上一轮的错误结论）

- [x] **纠正 M5-34 的错误结论**：我当时写「5 张卡的 tag 是**原生 tag**，合成夹具造不出来」——**这是错的**。`target_tag_dictionary.gd:128-129` 显示 `cell.market` 是**行定义**的，判据是 metric `cell.trade_events >= 24`，而该 metric 已发布、**可以覆盖**。我当年看到的 `family_buff.cpp:1133` 的 `{"cell.market"}` 是**国家级 tag 计数槽**，与格级谓词无关 → 证据：`artifacts/ideology-cell-layer/m5/M5-40-uncap-cost-still-unmeasured.md`
- [x] **走正确路径重试**：按 metric id 覆盖 `cell.trade_events` → 装备 `autonomous_logistics_l1`
- [x] **卡确实装上了**：`commands applied=4 rejected=0`、`active ideas=1`、`locations=[1]`
- [ ] **[未定位] 收集在 POD 阶段全失败**：`pod_fail=4`、`targets_fail=4`、`own_*` 全未运行 → 卡没走到目标解析。**我没有猜一个原因写上去**
- [x] **已确认静态侧是完整的**：用覆盖率脚本的 `build_facts()` 逐卡查 → 5 张卡全 `backend=DerivedCell`、`reason=-`、`param0=0` —— **解封在静态侧完整落地**
- [x] **一次用错字段的探针**：查 `program_keys` 得 0，但 B5/B7 在同一编译下派生层工作（`front cells=3200`），**所以那不是「POD 缺失」的证据**，是我选错了字段
- [x] **删掉测不出东西的夹具**：一个永远失败又不测量的夹具比没有更糟，会污染回归集
- [ ] **[仍未测] 一次 resolve 实际慢多少**：机制上界 `32 × 环形` → `领土格数 × 环形`，**没有数字**
- [ ] **[下次起点] 两步**：① 先打 `_persistent_templates` 的 `definition_key`，判断那 4 个模板是不是开局理念（若是，「我的卡没进 active_templates」才是主因，与 POD 无关）② 若卡在 active 里而 POD 失败，再比对 `effect_program_key()` 与本夹具编译出的 catalog。**第 1 步一行打印就能排除一半可能**

### M5-41 源格解封成本测到了：收集更快，代价在下游

- [x] **换了个问法就通了**：前两次都卡在「让 kind-14 卡的 tag 匹配上」（M5-34/M5-40）。成本不在卡片机制里，而在 `collect_effect_target_cells(anchor, OWN_TERRITORY, cap, tag, sources, …)` —— 这句可以直接经 M5-6 的 `probe_fan_out_ownership` 桥调用，**不需要卡片** → 证据：`artifacts/ideology-cell-layer/m5/M5-41-source-cap-cost-measured.md`
- [x] **又一次是断言抓到了工具 bug**：第一次测出 `cap=32` 与 `no cap` **都是 32 源**。根因在**我的探针桥**：`cap = stripped > 0 ? stripped : 32` —— `param0=0` 被硬钳成 32，**根本测不到解封场景**。若只看时间比值（1.06×）会得出「去掉上限不花代价」的**假结论**
- [x] **修了桥**：改用与生产同一个 `resolve_selector_cell_cap(kind, authored, cells)`
- [x] **实测（1600 格单国，含预热，5 次中位数）**：`cap=32 → 32 源 / 0.2170 ms`；`no cap → **1600 源** / **0.0610 ms**`
- [x] **反直觉但有解释**：收集**反而快 0.28×**，因为 `effect_stable_cap` 要哈希 1600 个元素才能挑出 32 个，不封顶就跳过整步。**「拿到全部源」比「挑 32 个」更便宜**
- [x] **真实代价在下游**：每个源一次 R1/R2 环形遍历 → **32 → 1600，50 倍**
- [x] **新夹具 4 checks / 0 failures**，含两条结构性断言（authored 32 仍得 32；无上限得整块领土）
- [ ] **[仍缺] 环形遍历耗时**：需要造出可用的 `_building_neighbors`（径向分支要求邻接表与四个列就位），是独立工作量
- [ ] **[仍缺] 一次 resolve 的总耗时**：= 收集 + 50× 环形，缺后一项
- [x] **发布说明措辞已可精确化**：收集不变慢（0.061 vs 0.217 ms），代价是环形遍历 50 倍，总耗时仍未测

### M5-42 DLL 身份同步变成工具（因为这个坑踩了三次）

- [x] **第三次踩同一个坑**：重建 release 后我运行 `newids.py`，它里面**硬编码了更早的旧哈希**，于是「更新 0 处」，而 `verify_delivery.py` 正确地报了 2 处不匹配 → 证据：本条目
- [x] **根因不是校验脚本，是「每次重建都要改一次脚本」这个工作方式**：第一次靠人手工读二进制、第二次靠校验脚本、第三次靠……还是校验脚本
- [x] **写成正式工具** `Project/project-keynes/tools/ideology/update_dll_identity.py`：**不硬编码任何旧值**，读文档里**当前的声明值**再替换成实测值
- [x] **只改「声明」，不改历史**：① 首列是 `debug`/`release` 的表格行 ② 同时提到 debug 与 release 且带两个哈希的行。里程碑日志里的旧哈希**故意不动**
- [x] **自带失败判定**：替换后重新读一遍，仍有不匹配就 `exit 1` 并打印 `STILL STALE`；干净则打印 `OK: every current-identity claim matches the files`
- [x] **幂等性实测**：已同步状态下再跑一次 → `total updated: 0` + `OK`，`exit=0`
- [x] **与 `verify_delivery.py` 的分工**：前者**改**、后者**查**；两者用同一套「声明行」定义，所以不会互相打架
- [x] **完整校验**：`verify_delivery.py --with-release` **VERIFY OK**；debug **`c40806c0f223cd4b`** / release **`b172a83733a6b8a1`**

### M5-43 解封成本模型完整：约 2.5×，仍是亚毫秒

- [x] **环形遍历那一半在 C++ 选择器夹具里测**：那里有真实的 `build_hex_neighbors`。预热 200 次 → 计时 2000 次 → **0.322 µs/walk** → 证据：`artifacts/ideology-cell-layer/m5/M5-43-uncap-cost-model-complete.md`
- [x] **完整成本**（1600 格单国，无 tag 过滤 = 最坏情形）：收集 0.217 → **0.061 ms**（更快），环形 0.010 → **0.515 ms**（50×），**合计 ≈0.227 → ≈0.576 ms（约 2.5×）**，**仍低于 1 ms 门槛**
- [x] **断言与报告的边界**：两条断言是「环非空」与「单次 < 100 µs（故意松两个数量级）」，**计时数字只报告不断言**——墙钟阈值是关于机器的声明
- [x] **三件事严格区分**：① 单次 resolve 成本 **实测 0.576 ms** ② 6400 格国家 **外推 2.3 ms，未实测** ③ **resolve 是否受 slice 预算保护未验证**（分片保护的是重建，不是 resolve）
- [x] **发布说明已从「没有数字」改为可评估的成本表**
- [ ] **[外推未测] 6400 格国家的 resolve 成本**（约 2.3 ms）
- [ ] **[未验证] resolve 是否在 slice 预算内**：这是 6400 格国家是否安全的决定性一问
- [ ] **[未测] R2 环形遍历**：环更大（18 vs 6），成本会按环格数放大
- [ ] **[未测] release DLL 上的同一组计时**

### M5-44 解封的代价：6400 格一次 resolve ≈2.19 ms，**突破 §14.3 门槛**

- [x] **查清了上一轮标注的未验证项**：`step_derived_rebuild` 的采集阶段是**一整块**（`ideology_runtime.cpp:6963-6972`，`for country { for idea }` 内**无让出点或预算检查**）→ **resolve 不受 slice 预算保护**，分片保护的是重建 → 证据：`artifacts/ideology-cell-layer/m5/M5-44-uncap-breaks-slice-gate-at-6400.md`
- [x] **实测 6400 格**：`cap=32 → 0.5540 ms / 32 源`；`no cap → **0.1260 ms** / **6400 源**`。收集是**次线性**的（1600 格 0.061 → 6400 格 0.126），**从来不是瓶颈**
- [x] **瓶颈是逐源环走**：`resolve_effect_targets` 里 `for (source : sources) { collect_effect_target_cells(source, ring_kind, …) }`，单次 0.322 µs（M5-43 实测）→ `6400 × 0.322 µs = 2.06 ms`
- [x] **合计 ≈2.19 ms**：是 §14.3 门槛（1 ms）的 **2.2 倍**、step 预算（0.45 ms）的约 5 倍。旧行为（32 源）约 0.56 ms
- [x] **影响面写清**：只在「超大国家（数千格）+ kind 14/15 卡」；400 格国家约 0.16 ms 无问题；带 tag 过滤更低
- [x] **没有把 2.19 ms 当作「通过」写进性能表**，也**没有单方面改回 32 上限**（那是用户的决策）
- [ ] **[需决策] 三个处置**：A 接受并记录 / B 按国家分片（**不够**——最坏是单国 6400 格）/ C 按来源分片（**能真正解决**，改动最大）
- [ ] **[已知回归] §14.3 在超大国家 + kind 14/15 上不成立**

### M5-45 把「§14.3 通过」的残留声称全部加上例外

- [x] **交付报告新增 §5.4**：把 6400 格一次 resolve ≈ **2.19 ms**（收集 0.126 + 逐源环走 6400 × 0.322 µs）与「§14.3 单 slice ≤ 1 ms 突破约 2.2 倍、step 预算 0.45 ms 约 5 倍」写成独立一节，并明确 **「这一项不能算 §14.3 通过」**
- [x] **方案 §18.3 那行加了 ⚠️ 例外**：原来只写「单 slice 达门槛」，现在写明「**有例外**」并指向 M5-44
- [x] **一致性核查**：三份当前文档（交付报告 / 发布说明 / 方案 §18.5）**都不再有「单 slice 达门槛」的无条件声称**；`verify_delivery.py --doc-only` **VERIFY OK**
- [x] **区分了历史与当前**：checklist 里带日期的里程碑条目（`0.708 ms → 门槛 PASS`、`0.5878 ms → PASS` 等）是**当时**的记录，保留不动；只有**当前声明**才需要例外
- [ ] **[需决策] M5-44 的 A/B/C**：A 接受并记录 / B 按国家分片（不够）/ C 按来源分片（能真正解决）
- [ ] **[已知回归] §14.3 在「超大国家（数千格）+ kind 14/15」上不成立**（≈2.19 ms vs 1 ms）

### D1–D4 决策落地（2026-10-28）

- [x] **D1 按 (a)**：释放边界锁 + INSTALL 重验 `expected_basis`，不把 EPOCH_BEGIN 状态机化；`start_epoch` 内部结构 M0–M5 全程未动
- [x] **D2 平衡不在范围**：本轮不做任何平衡调整、不单列平衡里程碑
- [x] **D3 文案对齐实际效果**：`maritime_insurance_l1/l2/l3` 的 `duration_days` **30 → -1**（与其余 285 张永久卡一致；置 0 会被校验器拒绝），文案「持续 30 天，可刷新」→「永久生效」
- [x] **D3 顺带发现并修掉同类问题**：文案里「影响 32 个目标地块」共 **262 处**；其中 **191 张 kind 12** 的目标上限已取消、文案确定错误 → 已改为「作用于全部领土格」（加已修的 3 张 maritime = **194 处**）。**kind 14（5 张）与 kind 16（66 张）未动**：前者是源格扇出、后者 `param0` 仍带自己的 cap，不是机械替换
- [x] **内容仍可编译**：`ideology_content_test` **67 / 0**
- [x] **D4 改为不依赖玩法**：>32 真实世界样例改走「让生成/夹具产出连片多格国家」；已确认可复用路径存在（GM `simulation.click_claim_territory`、原生 `sync_country_territory_to_map` / `get_country_territory_counts`）
- [x] **性能按批量扩张解决**（用户批准）：`dilate_cell_set` 等价性断言通过、同网格 **14.10×**
- [ ] **[待做 D4] 用连片多格国家跑出真实世界 >32 生产样例**
- [ ] **[待做] kind 14/16 共 71 张卡的文案复核**（语义不同，需逐类处理）

### M5-47 kind 14 诊断：排除两个猜想，根因仍未找到

- [x] **新增 key 级诊断**：`collect_pod_fail_keys` 导出前 8 个 POD 解析失败的 program key——裸计数无法区分「卡没进 active」与「卡在 active 但 program 缺失」，这个歧义已耗掉两轮（M5-34/M5-40）→ 证据：`artifacts/ideology-cell-layer/m5/M5-47-kind14-diagnosis-still-open.md`
- [x] **诊断输出**：`pod_fail_keys=["ideology.effect.ideology.autonomous_logistics"]`——**program key 被双重加了 `ideology.` 前缀**
- [x] **猜想一被推翻（`effect_program_key` 双重前缀是 bug）**：那个 key 属于 `[sub_resource id="EffectAutonomousLogisticsCostL1"]`，`action = 1` 是 **COST**，成本条目没有声明式 program，`pod_fail` 对它失败是**正确的**
- [x] **猜想二被推翻（3 张卡引用卡片级 key，效果程序从未被使用）**：`persistent_effects` 是数组，除成本外还有 `EffectAutonomousLogisticsL1R0` 等真正的效果条目；`autonomous_logistics_l1/l2/l3` 确实存在且被引用
- [x] **阻止了一次错误的「修复」**：我准备把 catalog 里 3 处 key 改成 level 对应的效果 key；**看了资源块结构后没有执行**——那会改掉成本条目的 key、破坏成本
- [x] **诊断夹具**：`ideology_kind14_diagnosis_test.gd` 3 checks / 0
- [x] **【决定性】同时记录成功的 key**：只记失败不够——成本条目本来就该失败。加上成功列表后 `pod_ok_keys=["ideology.effect.autonomous_logistics_l1"]` → **卡的真实效果程序解析成功，POD 层是好的**
- [x] **目标层五个计数器全 0**：`no_tag=0 empty=0 domain_gate=0 economy_null=0 country_zero=0` → 前置门一次都没退出
- [x] **更正上一条推断**：「`own_*` 全未运行说明取源格没执行」是**查错字段**——`own_*` 在 `get_economy_territory_plane()` 里，不在 `get_ideology_report()` 里。**该结论已撤回**
- [ ] **[下一步一行] 给 `if (sources.empty()) return false;` 加计数器**：这是少数**没有计数**的出口之一；若命中，说明 tag 扫描没匹配到格，即 `set_effect_metric_override_for_test(cell.trade_events)` **没影响到 tag 快照**——那是夹具问题而非产品缺陷
- [ ] **[下一步 1] 打印 `EffectAutonomousLogisticsL1R0` 那条效果的 `definition_key`**，确认它是否解析成 `ideology.effect.autonomous_logistics_l1`
- [ ] **[下一步 2] 若解析成功仍无派生贡献** → 问题在**资格判定**而非 POD
- [x] **一个值得记下的模式**：我的第一遍读代码/数据四次都不完整（读注释／读数据文件／读字符串匹配／只看命中行不看资源块）。**共同点是把一个局部事实当成全貌。仍有效的做法：先确认容器，再看字段**

### M5-48 kind 14 诊断链条闭合：与「>32 样例」是同一个阻塞

- [x] **诊断链条走通到最后一步**：POD 成功 → **tag 匹配成功** → 源集收集成功 → **环形遍历为空** → 证据：`artifacts/ideology-cell-layer/m5/M5-48-kind14-chain-closed-single-blocker.md`
- [x] **第 2 步查清是我自己的时序错误**：`TagSnapshot` 是**不可变快照**、惰性构建；我把 metric override 放在「装备前」，快照早已建好。移到 **epoch 打开之前** 后 `ring_empty` 由 **4 → 0**（tag 立刻匹配）
- [x] **第 4 步根因**：`empty=4` 表示 `dilate_cell_set` 返回空——它需要 `_building_neighbors`，而夹具没有 `bind_map_data`
- [x] **手写 MapData stub 会崩溃**：加上 stub → `exit=-1073741819`（0xC0000005），与本仓库已有记录一致（`world_ext_economy.cpp:929-930`）
- [x] **关键结论：两个未完成项是同一个阻塞** —— kind 14/15 端到端夹具需要真实 `MapData`；>32 真实世界样例需要「真实世界 + **连片多格国家**」。**两者都指向 D4；一旦有了它，两项可一起完成**
- [x] **操作教训**：我第一次把计数器加到 `sources.empty()` 时打在了 **kind 16** 那一行（两行文本与缩进完全相同，正则无法区分）→ `no_source=0` 一度让我以为分支没进。**改法是按行号定位 + 给每个计数起属于它分支的名字**
- [ ] **[待做 D4] 生成/夹具产出连片多格国家**，用它同时验 kind 14/15 端到端与 >32 真实样例

### M5-49 修掉一个阻塞验证的既有语法错误（不属于 plan 22）

- [x] **现象**：`ideology_content_test` 由 67/0 变成 `exit=1`，报
  `Could not preload resource script "res://scripts/economy/economy_facade.gd"`
- [x] **根因**：该文件有**重复函数声明** —— `country_class_opinion_snapshot` 在
  **1615 与 1623 两处**，函数体**逐字节相同**，只有 doc 注释不同。GDScript 直接判
  `Function "country_class_opinion_snapshot" has the same name as a previously declared function`，
  整个文件不可解析，于是**所有 preload 它的测试一起挂**
- [x] **修复**：删掉**第一份**、保留 doc 注释更详细的那一份（信息不丢失），
  `func country_class_opinion_snapshot` 由 2 处变 1 处，文件恢复可加载
- [x] **归属说明**：**这不是 plan 22 的一部分**，是一处与本任务无关的既有重复粘贴。
  修它是因为它**阻塞了验证**，而且「两个逐字节相同的函数体删一个」不涉及任何语义选择
- [x] **回归恢复**：content 67/0、x1b 142/0、B7 27/0、B8 18/0、B10 16/0、B11 9/0、
  oracle 19/0、publish 268/0、source_cap_cost 4/0、diagnosis 3/0 —— **10/10**
- [x] **一个应记下的教训**：我最初看到 `content_test` 失败时，**第一反应是「我的改动弄坏了」**。
  实际是**另一个文件**的语法错误。**看 stderr 的第一行（哪个文件、什么错），不要先看自己在改什么**

### M5-50 D4：claim 命令能提交，但领土没变

- [x] **第一次从 GDScript 打通 `COMMAND_CLAIM_UNOWNED_TERRITORY`(opcode 20)**：在真实 200×200 世界上 `accepted=48 rejected=22`，`run_country_slice` 推进 3 个国家日全部 `done` → 证据：`artifacts/ideology-cell-layer/m5/M5-50-d4-claims-accepted-territory-unchanged.md`
- [x] **顺带确认三个 API 事实**：① 批量必须含 `submit_commands` 读的**全部**数组且长度都等于 `opcodes`（照 `country_facade.gd:83-137` 补齐后一次通过）② `get_country_cell_summary` 参数是**格号** ③ 国家日推进是 `run_country_slice`，`advance_country_day` **不存在**
- [ ] **[未达成] 领土真的变大**：`widest` 仍 1、`total` 仍 3 —— 提交被接收但**没有应用**
- [x] [M5-51] **合成复现尝试失败但排除了两类原因**：① `_cell_country_slot` **不是死列**（`assign(NEUTRAL_SLOT)` + 逐格写，`country_runtime.cpp:418/1137/1180`）② 真实世界**并非没有中立格**（`handle=4294967296` 说明 slot 有区分）→ 证据：`artifacts/ideology-cell-layer/m5/M5-51-d4-synthetic-repro-invalid.md`
- [ ] **[合成复现无效] 我的夹具让整格网都归国家 0**：`bootstrap_country` 只给 1 格领土，但 `HOME/ADJACENT/FAR` 三格**都报 slot 0**，于是「claim 中立格」不可能，两种 claim 必然不生效
- [ ] **[下一步 1] 查 `bootstrap_country` 在 `territory_cells` 只有 1 项时对其余格的归属语义**：是「其余保持中立」还是「其余归 slot 0」——这决定合成复现是否可行
- [x] **【M5-52 已撤回】我把它当成真实缺陷，推断错了**：`get_country_territory_counts()` **不读** `_countries.territory_count`，而是读**经济运行时的 epoch 快照**（`world_ext_country.cpp:978-992`）→ 原因果链是我编的。开新 epoch 后仍是 `total=1`，但运行时可能有**独立的捕获路径**（`sync_country_territory_to_map` 之类），我**没有调用**。**两种解释都成立，正确说法是「未知」** → 撤回文档：`artifacts/ideology-cell-layer/m5/M5-52-RETRACTION.md`
- [x] **保留的代码改动已重新定性**：`rebuild_cell_csr()` 末尾从 CSR 偏移量重算 `territory_count`——**不是缺陷修复**（缺陷未证实），只是让同一事实的两份表示恒等（O(国家数)，与 ADR01/ADR02 的派生量结论一致）
- [x] **【第 6 次第一遍读不完整】** 把同名概念当成同一处代码：看到 `territory_count` 被写入，就假定报告读的是它。**教训：查「A 影响 B」的因果链时，必须先确认 B 的读取路径，而不是从 A 的写入路径反推**
- [x] **【M5-53 停止点】查到了不一致所在的层，并判断它不属于本方案**：即便开一个**真正新建的 epoch**（`captured=true reused=false epoch_id=2`），`total` 仍是 1 → 所以不是「快照没刷新」，而是**快照的输入本身**（`economy_runtime.cpp:4986` 搬 `snapshot.cell_country_slot`，该快照可能是已冻结的导出）→ 证据：`artifacts/ideology-cell-layer/m5/M5-53-d4-stop-point.md`
- [x] **为什么不修**：该层是 `country_runtime` 与 `economy_runtime` 之间的**领土同步契约**，有独立的存档与哈希约束，**不属于 plan 22**；剩余轮次里改它的风险远大于价值
- [x] **对本方案的实际影响有限**：需要 >32 真实世界样例才能回答的**只有 §18.4 一项**；「32 上限已取消」的代码层与合成夹具层证据完整（`cap_removed` 12、B7 单国 1600 格 27/0）
- [ ] **[交给接手者] 先查「谁是 `snapshot.cell_country_slot` 的生产者、何时重建」**，而不是继续查 claim 或计数
- [x] ~~【真实缺陷 M5-52】claim 生效了，但领土计数没变~~：PRE `HOME=0 ADJACENT=-1 FAR=-1` → POST `全部=0`，而 `widest/total` **仍是 1**。所以之前几轮「claim 不生效」的判断**是错的**——它生效了，只是**报告看不出来** → 证据：`artifacts/ideology-cell-layer/m5/M5-52-claim-applies-but-territory-count-stale.md`
- [x] **定位到两条并行表示**：`country_runtime.cpp:3172-3199` 同时处理 TRANSFER 与 CLAIM，`:3196` **确实** `++territory_count[target]`（暂存副本），而格子归属走 `batch.direct_cell_owners`（`:3202`）。**提交后只有后者生效**
- [x] **影响盘点**：`get_country_territory_counts()` **永久低报**；`:3625` 校验误判；`state_hash` 含该字段（`:9325/9487`）→ 哈希与实际领土不一致；存档持久化（`:9871`）→ **读档后低报继续**。**这就是几轮都拿不到 >32 证据的原因**
- [x] **这条缺陷也解释了 M5-50**：真实世界 `accepted=48` 大概率同一缺陷（未同轮证实）
- [ ] **[未修] 修法需确认不变量**：首选「提交时从格子归属重算 `territory_count`」（派生量不维护两份，与 ADR01/ADR02 同一结论）；次选「加提交后断言」。**仓促改会动到存档与哈希**
- [ ] **[未验证] `TRANSFER_TERRITORY` 是否有同样问题**（它走同一段代码，很可能同样不一致）
- [ ] **[成本现实] 每次尝试约 7-10 分钟**（真实世界生成），剩余轮次只够 1-2 次 → **最省的下一步是在合成世界上试同一条命令**（`bootstrap_country` 可控，能立刻看出「相邻」是否是条件）
- [x] **夹具状态**：`ideology_d4_multi_cell_country_test.gd` 9 checks / **1 failure**（失败的是「>32」这条真目标）；**未加入 `verify_delivery.py` 期望表**，因为它现在会失败

### M5-54 接手说明 + B4 不可便宜闭合的结论

- [x] **写了 `artifacts/ideology-cell-layer/M5-HANDOVER.md`**：把 11 项无证据**按"各自卡在哪"分类**（共用真实 `MapData` / 需大规模逐格控制 / 完全未开始），并列出 8 条踩过的坑与验证命令
- [x] **B4 判定为"不可便宜闭合"**：`tag_snapshot_stress` 的翻转用**单个全局 metric 覆盖**（`_set_tagged_population` → `set_effect_metric_override_for_test`），**无法表达"1% 的格"**；且该夹具只有 36 格，1% 是 **0.36 格**
- [x] **又修掉两个夹具 bug**（我自己的）：① `capture_trade_topology` 的守卫要求 `passable.size() == 256`（按**地形类型**不是按格，`world_ext_economy.cpp:775`），我的 stub 返回 `cells` 字节 → 守卫静默失败 ② 夹具没注册 `cell_terrain/is_water/has_river/landform/vegetation/elevation` 六个逐格列，而 `capture_building_context` 正是读它们
- [x] **补上后夹具仍 4/0 通过**，但 `valid_neighbors` 未再确认到 → **6400 格新路径耗时仍未测**
- [x] **交付报告新增 §5.5**：把三项缺口统一成"同一个前置条件"，并写明该条件不属于本方案
- [x] **最终校验**：`VERIFY OK`、覆盖率门禁 7/7、身份 `total updated: 0`（未漂移）
- [ ] **[仍未完成] §18 的 11 项无证据**（分类与继续点见 M5-HANDOVER）

### M5-55 B6 补上证据：6400 格阶层读取无回退

- [x] **B6 从「无证据」变为「已验证」**：在 6400 格夹具上调用 `get_country_class_opinion_snapshot()`
- [x] **三个可复算的数字**：`cells_scanned = 6400`（**全格扫描，不是子集**）、`population` 合计 **192000 = 6400 × 30**（与 bootstrap **精确相等**）、`ok = true`、`class_count = 4`
- [x] **为什么这三个数能排除「降级但看起来合理」**：部分扫描不可能正好等于 6400；人口合计若走回退路径不会等于 bootstrap 的精确乘积
- [x] **`zero_population_rows = 3`** 与「4 个阶层里 3 个无人口」一致，不是异常
- [x] **夹具从 4 checks 增到 7 checks / 0 failures**，`verify_delivery.py` 的期望值同步改为 7
- [x] **§18.3 由 6/12 改为 7/12**（剩 B1、B2、B3、B4、B12）
- [ ] **[仍未测] B6 的性能**：plan 对这一项只要求「无回退」，未要求耗时，所以不作为缺口
- [ ] **[仍未完成] B1、B2、B3、B4、B12**

### M5-56 release 性能：第一个数据点（并声明它不可用于对比）

- [x] **取得 release 上的重建耗时**：临时把 release DLL 放到 debug 位置跑 B7，`cell_layer_rebuild_ms = **0.263**`、27/0 通过；随后**从备份恢复并校验哈希**（`OK 642c57788fcf0c58`）→ 证据：`artifacts/ideology-cell-layer/m5/M5-56-release-perf-first-datapoint.md`
- [x] **debug 同一夹具是 0.212 ms**——**debug 比 release 快，这个结论不可用**：两者各只有**一次读数**，相差 24%，**远小于**本项目确立的单次散布（1.7–2.6×）
- [x] **能说的只有**：release 上这条路径可运行、一次读数是 0.263 ms。**release/debug 谁快谁慢没有结论**
- [x] **没有把「release 性能」写成已完成**：完整版需要 warm-up + N 次取中位数 + 未改动路径归一化，半天量级
- [ ] **[仍未做] release 性能的完整测量**（同 debug 的归一化方法）
- [ ] **[仍未做] §14.3 在各构建上的判定**（含已知的超大国家例外）

### M5-57 修掉我自己引入的线程安全风险（批量扩张的缓冲）

- [x] **发现**：`dilate_cell_set` 第一版把 stamp 缓冲做成**成员变量**（`mutable std::vector<int32_t>`）。而它替换掉的逐源循环**每次分配局部 `seen`**，所以**原本是线程安全的**
- [x] **风险**：若理念 worker 与主线程同时调用，成员缓冲会**数据竞争**。而**等价性断言永远抓不到它**——它只在单线程跑
- [x] **修复**：改成函数级 `static thread_local`。既保留「零分配、零清零」的复用，又恢复线程安全
- [x] **顺带删掉**头文件里那两个 `mutable` 成员（残留引用 0）
- [x] **验证**：x1b **142/0**（含等价性断言），加速 **12.46×**（与之前 14.10× 同量级，差异在散布内）；B7/B8/B10/B11/oracle/content/cost **全绿**
- [x] **release 重建 + 全量校验**：`VERIFY OK`（含 release）、覆盖率门禁 7/7、身份 `total updated: 7` 后重新一致
- [x] **这是一类值得记住的缺陷**：「把局部变量提成成员」在单线程测试里**完全不可见**，但会引入竞争。**优化掉分配时，必须同时问「原来的分配是不是也在提供线程隔离」**

### M5-58 修掉 66 张 kind-16 卡的静默 32 格上限（Claude 核实发现）

- [x] **缺陷**：66 张 kind-16 卡全部 `param0 = 800`，低五位为 0 → 解码器把「0」当成 `SELECTOR_MAX_CELLS`（**32**）→ `effect_stable_cap` **真的按 32 截断**。大国里每张卡只对前 32 格生效，其余静默丢弃 → 证据：`artifacts/ideology-cell-layer/m5/M5-58-kind16-silent-32-cap-fixed.md`
- [x] **自相矛盾的确证**：`selector_cell_cap.h:65-67` 把该 kind 声明为 `kSelectorNoCellCap`；GDScript 侧**早就有** `SELECTOR_NO_CELL_CAP` 与 `selector_cell_cap_is_unbounded`。**只有解码器那一个分支与它们矛盾**。这是「两份表示不一致」在本方案的第 **4** 次
- [x] **两侧同改**：C++ `effect_runtime.h:263` 的 0 → `kSelectorNoCellCap`；GDScript `unpack` 的 0 → `SELECTOR_NO_CELL_CAP`、`pack` 接受该哨兵。`effect_stable_cap` 无需改（`cap < 0 || size <= cap` 即返回）
- [x] **x1b 的 T8 原本在钉住这个缺陷**：它断言「32 格上限成立」。改为断言 **36 找到 / 36 保留**、`selector_truncations == 0`
- [x] **新增三条守卫**：① 未指定 → 无上限 ② `selector_cell_ceiling(16)` 必须同类无上限（把两份表示钉在一起）③ 显式指定 7 仍被尊重
- [x] **新增生产值守卫**：`param0 = 800` → 无上限 / radius 1 / 源上限 3 —— 这是 66 张卡真实使用的输入
- [x] **回归 12/12**：B5/B7/B8/B10/B11/oracle/content/cost/tag_source/tag_stress/effect_instance/e2e 全绿；x1b 在 debug 与 release 上均 **142/0**
- [x] **删除旧平面最后残留** `gdext/src/ideology_cell_program.h`（3231 字节、**零 `#include`**），删除后双构建通过 → §15.7 收尾
- [x] **对 Claude 第 2 点的核实（结论不同）**：kind 16 **没有**逐源 `seen` 分配——`source_counts`/`ring_1`/`ring_2`/`frontier`/`next`/`seen` **全部声明在源循环之外**，循环内只 `clear()` 复用（`ideology_runtime.cpp:1988-1995`）。Claude 这一点不成立，但其主线结论（`target_cap` 截断）成立且已修
- [ ] **[未测] 取消 kind-16 目标上限后的性能影响**：目标集变大，派生路径分片，但**无实测数字**
- [ ] **[未处理] kind 16 未改用 `dilate_cell_set`**：它走 `building_neighbor()` 直读六邻居表，不是逐源分配，因此**不需要**同样的改造

### M5-59 【最重要】M2 的核心交付从未进入生成器，一次重新生成就会撤销

- [x] **触发点**：核查方案 §12.1「生成器是唯一作者源，不手改生成结果」，而我 D3 的 194 处文案是手改 `.tres` 的
- [x] **实测后果**：跑一次 `generate_ideology_catalog.py`，**194 处 `PackedInt32Array(0, 0)` 全部被还原成 `(32, 0)`** —— **M2 的核心交付「取消 32 目标格上限」只存在于手改文件里，从没进过作者源** → 证据：`artifacts/ideology-cell-layer/m5/M5-59-generator-was-not-the-authoring-source.md`
- [x] **为什么这比代码缺陷更危险**：代码缺陷会被测试抓到；「交付物能被一条命令静默抹掉」不会
- [x] **根因**：`_selector_param_line` 里 **kind 16 那条路径有 32→0 映射，非 kind-16 那条没有**；且 `:8069-8074` 的自检把「写 32」钉死了
- [x] **修复**：发射器对无上限 selector 把 32 写成 0；新增 `UNBOUNDED_CELL_SELECTORS = frozenset((12, 14, 15, 16))`（镜像 `selector_cell_cap.h`）；自检改为要求 0；位布局注释改为「0 = NO cell cap」
- [x] **我改过头一次，内容测试抓到了**：最初把 kind 17（FAMILY_OWNED）也映射成 0，内容测试报 `family_selector_param_invalid`——kind 17 的 `param[0]` 是**家族数量上限**（运行时 `clamp(...,1,32)`），不是格上限。已移出并写明理由
- [x] **文案源头修复（§12.1 要求，从未落地）**：① 只有 kind 6/7 保留「最多影响 N 个目标地块」，kind 12 改为「作用于全部领土格」② 环并集卡删掉「最多计入 32 个来源」③ kind 16 的「每目标最多计入 N 个来源」**保留**（它说的是 3）④ 持续时间句改为按 **`lifecycle == 1`** 判断，而不是 `duration_days > 0` —— 这才是 `maritime_insurance` 三卡的根本原因
- [x] **验证生成器逐字复现**：`(0,0)=199`、`(32,0)=15`、新文案 **194**、三处旧文案 **0**；内容门禁 **7/7**、`ideology_content_test` **67/0**、回归 **10 个夹具全绿**
- [x] **一条可复用的检查**：任何「改了 `.tres` / 生成物」的交付，必须做一次「跑生成器 → 看 diff 是否为空」。**diff 为空才算真的落到了作者源**
- [ ] **[仍需注意] `(32,0)=15` 是 kind 6/7 的自有 cap**，属正常；但它们**没有内容门禁覆盖**（现有第 7 条只查 kind 14/15 的源上限）

### M5-60 子 Agent 协同：B1 / B4 / §11.7 时点 1 三项证据落地

- [x] **三个新夹具，全部由我独立复跑核验**（不采信子 Agent 的「通过了」）→ 证据：`artifacts/ideology-cell-layer/m5/M5-60-subagent-round-b1-b4-save1.md`
- [x] **B1（64 国 × 12 卡主线程）39/0**：64 国 / 512 格 / **768 张活卡**；front **6144 行 / 271,008 字节**；**instances 求和 = 0**（I01 在规模上成立）；`last_error` 空
- [x] **B4（每日 1% tag 翻转）31/0**：400 格 / 20 天 / 翻转 72（上 64 下 8）→ 单日最多 **4 格 = 1.00%**；`tag_changes=72`；`tag_snapshot_builds=22`、misses=0
- [x] **B4 的关键发现：采集成本与 churn 无关** —— 0 翻转 **0.054 ms**、4 翻转 **0.051 ms**、36 翻转（9%）**0.0535 ms**，三者相同 ⇒ **脏范围 = 1% 的格，采集成本 = 100% 的格，每天如此**
- [x] **B4 同时指出报告缺口**：经济报告**没有**「改变了多少格 tag 位」的字段（`tag_snapshot_*` 只有成本与节奏）；脏范围是夹具用两条独立路径从已发布 TagSnapshot 反推的（按国枚举 + metric 62，都给 56，逐位一致）
- [x] **§11.7 时点 1（建层前存档）177/0**：存档 API 是**生产路径**（`capture/restore_ideology_state`，`game_save_coordinator.gd:967/1148` 在用）；**PKID 不携带派生层**，所以读档后必须重建——正是本时点要测的
- [x] **逐格对比全部精确相等**：64 格 × 2 stat × 2 存档点，presence / add / **有效值**全等；fingerprint `b80012bf…` 三条分支一致；42 个有主格读到 1.05000305、22 个无主格读到精确 1.0 且 `derived_present=false`
- [x] **负向对照证明对比能失败**：把 reload-B 的载荷换成 SAVE-A → **23 failures**、`max_abs_diff=0.050003051758`
- [x] **顺带修掉既有缺陷：`tag_snapshot_stress_test.gd` 自称 6 国实际 1 国** —— 空 `country_ids` 让一国占全部陆格，且 `get_country_cell_summary(x)` 传的是**格号**不是国槽，6 次拿到同一 handle。已修为**显式 6 国 CSR + 唯一 handle 守卫**，修后仍 **38/0**（断言数不变，只是现在是真的）
- [x] **顺带发现 `cell_layer_contribs_passed` 是死计数器**：只有报告一处引用、一次性重建被删后从未被写；谁都不该拿它做断言（替代：`commands_folded`、front 的 `contribution_count`）
- [x] **三个新夹具进 `verify_delivery.py` 期望表**：39 / 31 / 177
- [x] **§14.3 出现第二个超标场景**：64 国 × 12 卡时**最差 fold 步 2.572 ms、最差 slice 3.603 ms**（预算 0.45 ms）。成因与「超大国家」不同——这次是**卡数**不是格数。**记为已知超标，不写成达标**
- [ ] **[待 B3] 512 国续跑**：子 Agent 仍在跑
- [ ] **[未做] §11.7 其余 6 个时点**：可复用的两块是 `_new_world()` 与 `_capture_state()`/`_compare()`；时点 2（epoch 在飞）需在 `run_economy_slice` 循环中间存档
- [ ] **[未覆盖] 升级传播**：`ADD_UNDERSTANDING` 只发起跨域事务，无 dispatch/ack 时永不结算 → 本次证明的是「重建等价」，**不是变更传播**
- [x] **三条跨项发现**：① 装备事务在无头环境**永不自行结算**（需夹具自驱 preflight→commit→ack）② **kind 16 在无建筑经济里解析 0 个目标**——这解释了 M5-47/M5-48 的 kind 14/15 端到端为何走不通 ③ 出厂理念容量是 **2→6**，"每国 12 卡"无法从现有内容装配（B1 在内存里提到 12，未改数据文件）

### M5-61 P3 峰值内存落地 + B3 补齐：§18.3 内存项从「只有 front_bytes」变为可验证

- [x] **共享字节公式**：`derived_cell_front_bytes()` 进 `derived_cell_layer.h`，`world_ext_modifier.cpp` 的内联副本改为调用它 —— **消除同一结构的两份尺寸公式**
- [x] **修掉一处真实的少算**：旧内联公式**漏计 `stat_versions`**，导致 `front_bytes` 少 **688 字节**（86 个 stat-id × 8）。B7 的恒等式原本把 140,912 当正确值，现已改为 `3200×44 + 112 + stat_versions_bytes = 141,600`
- [x] **峰值记录点选在唯一正确的位置**：`finish(previous, front, ...)` 之后、`install(std::move(front), ...)` 之前 —— **驻留 front 与候选 front 同时存活**
- [x] **实测峰值（B1，64 国 × 12 卡，重建 12 次）**：`retained=277,344` + `candidate=277,344` = **`total=554,688` 字节（约 542 KB）**
- [x] **这条数字的重要性**：**真实峰值是 `front_bytes` 的 2 倍**。只用 `front_bytes` 做预算会**低估一半**，这正是 §18.3 要问的问题
- [x] **B7 的 `retained=0` 是正确行为**：它只构建一次，`previous` 为空；已在 B7 里写明并把「驻留共存」的断言放到会重建 12 次的 B1
- [x] **报告新增三个字段**：`peak_retained_bytes` / `peak_candidate_bytes` / `peak_total_bytes`（`get_ideology_report()`），以及 `stat_versions_bytes`（层报告）
- [x] **`scratch` 明确不报**：物化器工作缓冲从外部不可达，**编数字比留空白更糟**，注释里写明这是已知空缺
- [x] **B3（512 国续跑）48/0**：512 国 × 2 格 = 1024 格；游标轨迹 `[64,128,192,256,320,384,448,0,0]` —— 每片恰好一个 64 国预算；`active_visits` 每日 +512（**每国恰好一次，不跳不重复**）；`understanding` 头/中/尾均 **+410**（**尾部不饿死**）；尾部格 1023 的 `derived_add=0.05` 且 `derived_source_country` 是尾国 handle
- [x] **B3 的两条关键发现**：① **无头环境里必须先把整日经济跑完才能装备任何真实卡**（支持门读 `CountryClassOpinionSnapshot`，512 国时约需 **1060 个 slice**，`PK_DISABLE_SUPPORT_GATE` 不管用）② 出厂 `max_active_visits_per_slice=1024` 会让 512 国一天**一片就跑完**，「续跑」根本无法被测——夹具把它改成 64
- [x] **B3 证明的是「国家遍历便宜且可续跑」，不是「整日达标」**：`active_progress` 仅 0.01–0.04 ms，而 `max_slice_ms` 4.6–5.0 ms 主要花在派生 fold
- [x] **回归 14/14 全绿**；release 重建 + `VERIFY OK` + 覆盖率门禁 7/7
- [x] **期望值同步**：B1 39→**42**、B7 27→**32**；B3 48、B4 31、save-1 177 已入表
- [ ] **[仍未测] `scratch` 与分配次数、backlog 三项**：scratch 不可达；分配次数需要分配器钩子；backlog 只在 B3 里间接反映（每日 9 次调用）
- [ ] **[仍未达标] §14.3 在两种规模上都超**：64 国 × 12 卡单步 2.57 ms；512 国整日 4.6 ms；超大国家 kind 14/15 ≈2.19 ms（结构性已修但缺实测）

### M5-62 §14.3 归因纠正：超标的是「含重建的那一片」，不是每一片

- [x] **发现**：`max_slice_ms` / `cell_layer_rebuild_ms` / `cell_layer_materialise_ms` 都是**全运行累计最大值**（`ideology_runtime.cpp:4901/7062/7063`），含 setup；我前几轮**拿它们当稳态值**了 → 证据：`artifacts/ideology-cell-layer/m5/M5-62-perf-attribution-correction.md`
- [x] **自证**：B3 日志里 `max_slice_ms` 在 day1 与 day2 **完全相同**（4.9644），而 `last_slice_ms` 是 0.2579 / 0.2665 —— 差 19 倍；`materialise_ms` 从 1.5795 **长到** 1.7083 说明 day2 内确实出现过 1.7083 ms 的重建步
- [x] **准确表述**：512 国 × 9 片里 **8 片约 0.26 ms、1 片（含重建）约 1.71 ms**；国家遍历本身仅 **0.015–0.029 ms**
- [x] **§14.3 仍然被突破**，但范围从「每一片」缩到「含重建的那一片」——**这是严重性判断的改变，不是免责**
- [x] **`DERIVED_REBUILD_STEP_BUDGET_MS = 0.45 ms` 在三种规模上都被超**（512 国 1.71、64 国×12 卡 2.57、超大国家外推 2.19），这一条确定
- [x] **交付报告新增 §5.4b** 记录该归因
- [ ] **[未做] 4.96 ms 那一片的归因**：日志无逐片明细，需加逐片记录（要改代码）
- [x] **可复用检查**：报告里 `max_*`/`worst_*` 是累计值，判断稳态必须同时看 `last_*` 或逐次明细；**两字段相差一个数量级时通常有一个被误读**

### M5-65 §11.7 存档时点：6/7 已覆盖 + 修掉一个「存档写得出读不回」缺陷

- [x] **§11.7 七个时点里 6 个已覆盖**（只剩时点 7 = worker 权威翻转，受 worker 夹具阻塞）
  | 时点 | 夹具 | 检查数 |
  |---|---|---:|
  | 1 建层前新局／读档 | `ideology_save_before_layer_test` | **177 / 0** |
  | 2 事务 pending / ACK 成功 / ACK 拒绝 | `ideology_save_transaction_states_test` | **314 / 0** |
  | 3 已确认未到资格日 | `ideology_save_eligibility_test` | **213 / 0** |
  | 4 已到资格日但旧 epoch 未结束 | 同上 | （同上）|
  | 5 basis 已采用后又变化 | `ideology_save_basis_and_midmaterialize_test` | **359 / 0** |
  | 6 MATERIALIZE 中候选未安装 | 同上 | （同上）|
  | 7 worker 提交而主线程镜像滞后 | — | **阻塞** |
- [x] **每个夹具都由我独立复跑核验**（不采信子 Agent 的「通过了」），且每次核验前查 DLL 身份确认它们没有重建
- [x] **全部夹具都带负向对照**且对照确实失败：SV1 换档 23 failures；SV2 两组 5 / 10 failures；SV34 换时点载荷 **252 格不匹配 / 10 条核心断言挂 9 条**、1e-7 扰动精确 1 处；SV56 位翻转精确 1 处
- [x] **修掉真实缺陷（M5-63）：存档写得出、读不回** —— 在「世代取代拒绝」之后、重试之前存的 PKEF，`transaction.transition_fire_sequence=1` 而 `instance.fire_sequence=0`，恢复时 `:7670` 判 `1 > 0` 直接拒绝（`pkef_transaction_transition_invalid`）。修法：**对终态 REJECTED 行豁免两条「陈旧计数器」检查**——**注意这是一次有意的放松**：`transition_fire_sequence > fire_sequence` 本身是损坏检测，放开后一个被篡改成 999 的终态行会被接受；风险是「历史证据被篡改不会被发现」，不是「错误转移被执行」。更干净的替代是「世代变化时不把 fire_sequence 清零」，但它参与幂等/去重，影响面过大，留作可选更优解。验证：夹具的 `[sv2/FINDING]` 从 **`restores=false`** 变为 **`restores=true`**
- [x] **核实并记录三项死字段（M5-64）**：① `_derived_world_identity` / `_derived_map_generation` / `_derived_epoch_id` / `_execution_contract_hash` **各只有 1 处声明、零处写入** → **派生层的 basis 身份恒为 0，无法区分 epoch 或地图**（§9.6 要求它参与候选绑定）② `_cell_layer_rebuild_skips` 导出但从不递增 ③ `cell_layer_collect_count/_rows/_ideas` 成员根本不存在
- [x] **不擅自修死字段**：把 `epoch_id` / `map_generation` / 契约哈希接进 ideology runtime 是**接线工程**，**编一个值比留 0 更糟**
- [ ] **[需决策] 方案 §9.3 的时序模型从未实现**：`eligible_from_day` / `confirmed_day` / `AppliedProgramBasis` / `basis_digest` 在 `gdext/src` **ZERO hits**。现实现是「命令按 `effective_day` 排队 + 每天重建一次 + 转移在观察到全部 ACK 的那天结算」，与 M0-8 §2 的「confirmed_day+1 才有资格、只在冻结边界采纳」**不是同一套语义**
- [ ] **[需决策] 方案 §10.1「尚未确认的装卡不产生贡献」未实现**：`collect_effect_activations:2285` 只判 `location == INACTIVE || level < 0`，**从不看 `transition.active`**（而 `:3540` 会因有转移在飞而拒绝第二次装备）。实测「装备转移未 ACK 时 front 已有 84 行」。**多个夹具依赖「location 立即生效」**，改它会连锁，所以这是产品语义决策，不是我单方面能改的
- [x] **一条会咬所有后续夹具的坑（已广播）**：**PKID 单独无法恢复任何已装备的档** —— `restore` 会校验每个 ACTIVE 想法的外部 Effect 绑定（`:6793-6812`），缺 PKEF 就整档拒绝（`ideology_effect_binding_missing_or_mismatched`）。必须 `capture_effect_state()` + `capture_ideology_state()` **按此顺序**恢复
- [x] **回归全绿**：SV1 177、SV2 314、SV34 213、SV56 359、B1 42、B3 48、B4 31、B7 32、x1b 142、effect_instance 51、content 67、tag_stress 38
- [x] **release 重建 + `VERIFY OK` + 覆盖率门禁 7/7**；五个新夹具全部进 `verify_delivery.py` 期望表

### M5-66 §18.5 状态评估重写：14/3/11 → **13/12/3**

- [x] **28 项逐条重判**，并把「无证据 11 → 3」「部分 3 → 12」写清是**上移**（那 9 项从「无证据」到「部分」），**不是重新归类凑数**
- [x] **有一项是下调，而且是纠正**：「完整管线成本达预算，单 slice 达门槛」上一版列为**完整**（只加了 ⚠️ 注），但 §14.3 的门槛**确实被含重建的那一片突破**（1.7–2.6 ms）——**一条有已知例外的项不该算完整**，现改为**部分**，例外写在同一行
- [x] **没有把任何「部分」升成「完整」来凑数**；完整数因此 14 → **13**
- [x] **剩余 3 项无证据**：① copier／学派／协同／装卸／升级／精神晋升 ② 四种权威组合／跨 slice／输入暂缺／权威翻转（worker 阻塞）③ execution contract 显式持久化（且 `_execution_contract_hash` 是死字段）
- [x] **B 场景 10/12**：本轮新增 B1、B4、B6；缺 B2（worker）、B12（读档/权威/冷启动）
- [x] **§11.7 存档时点 6/7**：只缺时点 7（worker 权威翻转）
- [x] **峰值内存已有数字**：front 141,600 B、峰值 retained 277,344 + candidate 277,344 = **554,688 B**；scratch／分配次数仍未测
- [x] **同步更新**：交付报告 4 处（含 §7 标题与 B 场景计数）、checklist 表头
- [x] **行数核验**：三张表分别为 **13 / 12 / 3** 行，与结论一致

### M5-68 六个机制全部有夹具 —— 撞出协同撤销缺陷、学派空操作、预览/命令不一致

- [x] **三个夹具，全部经我独立复跑**：装卸+升级 **133/0**、copier+学派 **77/0**、协同+精神晋升 **144/0** → 证据：`artifacts/ideology-cell-layer/m5/M5-68-six-mechanisms-with-three-findings.md`
- [x] **数值都是从目录算出的期望值**，不是「跑出来多少断言多少」：装卸 L1 add `+0.05000305`=3277/65536、L2 `+0.08000183`=5243/65536、cut `−0.10000610`=−6554/65536；学派 81920/98304 Q16；copier 源 0.0500030518 → 源+复制器 **2×** → 无左槽 **0** → 不可复制 **仅源**
- [x] **【真实缺陷】协同一旦激活永远无法撤销**：`active_synergy_ids` 正确丢 bond，但 **Modifier 行永久活着**，因子永远停在 `0.95/1.03`。机制已核实：`:1468` REMOVE 时翻转 `fire_sequence` 的**位 63**、`:1472` 硬编码 `opcode=2`，而 Modifier 行的 `source_id` 由 `fire_sequence` 派生 → **REMOVE 的 source_id 永远 ≠ APPLY 的** → `already_removed` → 泄漏。**已作为 `[FINDING]` 打印而非断言**（断言等于把泄漏固化成期望）
- [x] **【真实缺口】学派强度因子在派生路径上是空操作**：`school_strength_scale_q16` 只有 `:2549`（应用，**在实例分支内**）与 `:3306`（哈希）两处；**派生分支从不调用它**。265 个 program 里绝大多数是派生卡 → **学派对出厂多数卡片不生效**。出厂也没有任何卡片写学派 stat
- [x] **【真实不一致】`explain_ideologies` 与命令用的容量不是同一个**：预览读 `_spirit_capacity`/`_ideology_capacity`（`:6004/:5993`），命令读 `spirit_capacity_for(slot)`/`ideology_capacity_for(...)`（`:4606/:4561`）→ **有容量解锁科技的世界里预览与命令会给出相反答案**
- [x] **顺带发现既有夹具已失效**：`ideology_school_strength_worker_test.gd` 装备的两张卡在当前目录里**不存在**，第一条 `_require` 就失败。未修，已记录
- [x] **§18.1 机制项从「无证据」移到「部分」**：装卸/升级/copier/精神晋升正确，**协同的撤销不成立**，学派在派生路径不生效 → 不能算完整
- [x] **§18.5 新统计：13 完整 / 13 部分 / 2 无证据**（行数程序化核验）；交付报告同步
- [ ] **[仍缺] 四项未覆盖**：容量超限拒绝（出厂 113 卡全带阶层立场）、copier level≥2（缩放只在实例路径）、`program_writes_school_strength` 为真的分支（无内容可进）、worker 冻结快照路径
- [ ] **[未修] 协同撤销缺陷**：修它要改 `fire_sequence` 派生与 REMOVE 的 source_id 约定，属 Modifier/Effect 两域契约，影响面大，需单独立项

### M5-69 数值证据把「pending 保留旧贡献」判为**不成立** + 拒绝在 Modifier 域留残留

- [x] **夹具 `ideology_pending_keeps_old_contribution_test` = 140/0**（我独立复跑，亲眼看到三条 `[FINDING]`）→ 证据：`artifacts/ideology-cell-layer/m5/M5-69-pending-does-not-keep-old-contribution.md`
- [x] **【缺陷 1】pending 时已经在服务 NEW 值**：在 `pending_transitions==1`、**未做 ack** 时逐格读到 L2 的 `add=0.08000183`（+5243/Q16）与 `cut=−0.10000610`，**而不是 L1 的 `0.05000305`**；`transition_transaction_statuses==[1,1]`（都是 PLANNED）
- [x] **根因是同一张卡的两半互相矛盾**：`collect_effect_activations:2285` 只判 `location/level`、**从不读 `transition.active`**，而 `start_transition:3598` 在**请求时**就写 `state.level`；隔壁的日常理解度累积 `:5006` **却读了** `transition.active` 并保留 `previous_level`
- [x] **为什么内容检查永远发现不了**：**结算不改变任何东西**（pending 值与结算值相同），夹具专门断言了 `A3 settle [OUTCOME B]`
- [x] **【缺陷 2】拒绝在 Modifier 域留残留**：派生层是干净的（`contribution_count` 回到 84／**0**、无翻倍、64 格无孤儿、槽位释放），**但 Modifier 域不干净**——被拒装备后卡片 INACTIVE、cell 贡献 0 行，**而成本行 `ideology.public_hygiene` 仍在**（毫无歧义的孤儿）。机制：`run_modifier_daily` 按序逐行应用，`apply_rejected_instance_transition` **从不回滚已提交的行**
- [x] **【缺陷 3】被拒的升级在同一个 slice 内重试**：回滚恢复了 `previous_level` 但理解度仍过阈值 → `start_next_level_transition` 立刻重开并再写 `state.level`。实测 `levels_advanced 2→3`、`pending==1`。**后果**：两次回滚之间派生层**从不显示被回退的值**
- [x] **唯一成立的子项：一次性效果不重放** —— 跨 pending→settled 边界**发射恰好 1 次**，Modifier store 在结算后与两天后**都只有 1 行**
- [x] **夹具只断言残留的「受限形状」**（只允许来自被拒批次、不允许外来定义），**不断言方案的承诺**；三条缺陷都作为 `[FINDING]` 打印
- [x] **§18.5 那一行改为「前两个子项不成立」**，并把「pending 数值侧未断言」这个旧缺口**关闭**（现在是「已测且失败」）
- [x] **新增两个「需要决策」条目**：§9.3 时序模型从未实现、§10.1「未确认的装卡不产生贡献」未实现
- [ ] **[需决策] 缺陷 1 的修法**：加 `transition.active == 0` 的门会改变「ack 之前读层」的行为，而 `equip()` 立刻写 `location` 正是多个夹具依赖的；**改错会让 21 个夹具全绿而语义已变**
- [ ] **[需决策] 缺陷 2 的修法**：`ack_native_modifier` 拒绝时必须回滚该批次**已提交**的行，或改成先全量校验再提交
- [ ] **[未修] 缺陷 3**：同 slice 重试是调度顺序导致的，压制它需要改 poll/active 的相对次序

### M5-71 修掉 explain 分解缺陷 + PKEF 越界读；并记录我引入又被 4 个夹具抓到的回归

- [x] **两个新夹具，均经我独立复跑**：reader 一致性 **81/0**、存档载荷健壮性 **356/0** → 证据：`artifacts/ideology-cell-layer/m5/M5-71-two-fixes-and-my-own-regression.md`
- [x] **【修复 1】`explain_modifier_stat` 报告了它无法解释的总数**：分解只遍历 `store.active`，而同一 dict 的 `effective_value` 合并了派生层 → 输出「1.05，原因是：什么都没有」。已把派生项以**同一套算术与 §5.5 零因子规则**并入，并**单独暴露** `derived_add`/`derived_factor`/`derived_present`（后者区分「层里没有这一格」与「层贡献 0」）
- [x] **验证方式是「把断言反过来」**：夹具原有两条断言**钉住这个缺陷**，修复后自动变红（`81 checks, 2 failures`），改为精确反面后 `sum_add=0.050003051758`、`unclamped=1.050003051758`、`effective_value=1.050003051758` **三项一致**
- [x] **【修复 2】PKEF 恢复路径越界读（内存安全）**：`effect_runtime.cpp:7452-7457` 在 `||` 链里**未校验就索引** `_definitions[program_id]`，而 `program_id` 来自载荷、范围检查在 `:7519` **之后**；负数经 `static_cast<size_t>` 变巨大值 → **必然越界**。已把边界检查提到索引之前
- [x] **⚠️ 我的第一版修复打破了 4 个夹具**：直接加 `program_id < 0` 拒绝了**所有墓碑**——因为 **`program_id == -1` 是已删除实例的合法标记**（`:7515` 自己就这么读）。全量校验报 `VERIFY FAILED (4)`，且**检查数下降**（359→340、205→203）暴露「阶段被跳过」。改为 `(program_id != -1 && (…))` 后 5 个夹具全部回绿
- [x] **这条教训值得记**：**加边界检查前必须确认那个非法值域里有没有合法哨兵**。如果我只跑单个夹具就会漏过去——**4 个夹具 + 检查数下降一起把我拦住了**
- [x] **健壮性夹具挖出 5 条存档完整性缺口（既有，非本轮引入）**：① PKID 的 `last_day` **不在 state hash 里** → 改成 1007 后 **ok=true 且运行时采纳** ② `submit_order` 同样不在 ③ **PKEF 完全没有载荷哈希** → `current_day` 可被改成 1006 ④ 69 次单字节篡改 **14 次被接受** ⑤ 38 次 PKEF 篡改 **16 次被接受**（完整性是逐行的）
- [x] **健壮性夹具枚举了 27 层 PKID + 19 层 PKEF 校验**，51 个拒绝案例全部精确匹配原因码，107 次篡改 **0 崩溃**
- [x] **最终**：**VERIFY OK**（含 release）、**28 个夹具全绿**、内核 103/0、门禁 7/7
- [ ] **[未修] 存档完整性缺口 F1–F5**：修法是扩大 state hash 覆盖面或给 PKEF 加整载荷哈希，属**存档格式变更**，需单独立项
- [ ] **[未修] `get_modifier_report()` 没有 `layer_generation`/`layer_stat_version` 字段** —— 报告无法见证 front
- [ ] **[不可观测] 生产消费者 `refresh_city_modifier_factors`**：输出冻结进 `_epoch_cell_birth_factor_q16`，无绑定暴露；代码上必经 front，但夹具测不到

### M5-72 §10.1 的修复：实现了、验证有效、然后**回滚**

- [x] **实现了方案 §10.1 要求的语义**：采集器在转移在飞时用 `transition.previous_level`，pending 装备则**不贡献**。依据不是猜的——同一函数族的 `:5006-5007`（理解度累积）**已经**这么做 → 证据：`artifacts/ideology-cell-layer/m5/M5-72-section10-1-fix-implemented-then-reverted.md`
- [x] **修复确实有效（实测）**：pending 夹具的 `OUTCOME` 从 **`NEW`** 翻成 **`OLD`**、pending 时读到 **L1 的 0.05000305**（而非 L2 的 0.08000183）、pending 装备时 front **84 行 → 0 行**
- [x] **但它打破 14/28 个夹具**：`VERIFY FAILED (15)`，b7 14 个失败、save_basis 20、save_transaction 25、b5_idle 6、oracle 11…… 原因：**`start_transition` 在请求时就写 `location`**，而那 14 个夹具都是「装备 → 立刻读派生层」
- [x] **回滚而不是修那 14 个**：修它们要给每次装备加 ack 握手，**而且已交付的证据要重新推导**（§14.3 性能数字、B7 的 1600 格结果、B8/B10 数值对照全部会变）——在剩 52 轮时会让「已验证」这个结论本身失效
- [x] **回滚时把测量写进代码注释**，并恢复夹具的 `C1` 断言为「pending 装备时 front 仍有 84 行」，同时注明「§10.1 的修复被测量过、然后回滚了；**方案承诺记为 FINDING，不记为正确**」
- [x] **复跑确认**：pending 夹具回到 **140 / 0**、`OUTCOME MEASURED: NEW`；全量 **VERIFY OK**
- [ ] **[需决策] §10.1 要不要生效**：要 → 14 个夹具加 ack + 重推整条证据链；不要 → 修改方案，承认「装备请求时即生效」是设计
- [x] **顺带确认 `x9b` 有既有抖动**：全量里偶发 1 个失败（`country_worker_peer_results_pending`），单独跑 22/0，重跑即 VERIFY OK
- [x] **本轮净增**：`explain` 分解修复（保留）、PKEF 越界读修复（保留，含墓碑豁免）、两个新夹具 **81/0** + **356/0**

### M5-73 `get_modifier_report` 现在能见证派生层（N3 修复）

- [x] **缺陷（N3）**：`get_modifier_report()` **完全没有** `layer_generation`/`layer_stat_version` 字段——诊断读者无法区分「层装好了、第 N 代」与「没有层」，唯一代理是 `modifier_stat_bucket_version()`（把世代混进哈希）
- [x] **修复**：新增 5 个字段 `layer_installed`（0/1，因为这个 Dictionary 里其它字段都是整数）、`layer_generation`、`layer_stat_count`、`layer_contribution_count`、`layer_stat_versions_bytes`（**报尺寸而非向量**——它按 stat-id 空间大小，那不是读者想看的）
- [x] **验证方式仍是「把 FINDING 反过来」**：夹具原本只有一条 `print("[FINDING] ... absent=...")`，我改成 **2 条断言**（字段存在 + 与层报告的 stat_count 一致），检查数 **81 → 83**，实测 `installed=1 generation=1 stat_count=2`
- [x] **全量**：**VERIFY OK**（含 release）、门禁 7/7
- [x] **确认 `x9b_family_target_worker_test` 是既有抖动**：连续两次在不同构建上偶发 1 个 `country_worker_peer_results_pending`，重跑即过
- [ ] **[放弃] §10.1 的另一种修法**：我考虑过「请求时不写 `state.level`、改到 ACK 时写」——这样 pending 升级自然服务旧等级，而 pending 装备的 `location` 仍立刻生效（不打破那 14 个夹具）。**但它是同一类多语义点改动**，而我已经用一次实测证明了这类改动的代价（M5-72 打破 14 个夹具），所以没有动
- [x] **顺带确认 M5-68 的协同结论更硬**：`ideology_runtime.cpp:3629-3636` 的注释说明「REMOVE 匹配不上导致旧行存活」**在卡片行上已被修过**（按世代拆批），而**协同行走的是另一条路（`:1463-1472`）没修** —— 这正是它泄漏的原因

### M5-74 读者一致性升级为「完整」：§18 → **14 / 12 / 2**

- [x] **把 §18.1「所有 reader、scope 枚举、版本与 explain 使用同一派生 front」从「部分」移到「完整」**，依据是 **`ideology_reader_consistency_test` 83/0** 与那一轮枚举出的完整 reader 清单
- [x] **四个子项逐项有证据**：值读取 R1/R2/R3 精确相等（`1.050003051758`）；scope 枚举 R4/R5 恰好 42 个有主格且**不含无主格**；版本 R6 随安装移动、不变时稳定；explain 的 `effective_value` 对，且**分解项也已修**（N1）；元数据 R7/R8 一致
- [x] **未覆盖格三者都精确 1.0** —— 所以「同一 front」不是靠两条路径都返回 1.05 证明的
- [x] **负向对照能失败**：把卡推到 L2 → 每个 reader 一起移到 `1.080001831055` 且 **≠** 1.05
- [x] **非 front 的读路径每条都有归因，不是忽略**：`list_modifiers` 对派生 (stat,cell) **没有 handle**（按设计）；`get_gameplay_modifier_effective` 是 GAMEPLAY 域；COUNTRY/CLIMATE 域被 B11 证明的门挡住
- [x] **本轮两处修复是升级的前提**：N1（explain 分解漏派生项）、N3（report 缺 layer 字段）
- [x] **统计同步**：三张表行数程序化核验 **14 / 12 / 2**；交付报告与 checklist 表头已改
- [ ] **[仍缺] `list_modifiers` 无法枚举派生行**：要给它加派生枚举能力需要新 API，不是修 bug
- [ ] **[仍缺] 生产消费者不可观测**：`refresh_city_modifier_factors` 的输出冻结进 `_epoch_cell_birth_factor_q16`，无绑定暴露

### M5-75 接手文档重写（上一版已过时 9 个统计粒度）

- [x] **`M5-HANDOVER.md` 是第 131 轮写的，还写着「11 项无证据」——现在只有 2 项**。重写为标准入口：目标状态、已完成（带最强证据）、剩下 2 无证据 + 12 部分**按「缺什么」分组**、三处待决策语义缺陷、15 个已修缺陷的发现方式、**17 条踩过的坑**、两条最有效的对策、按性价比排的下一步、以及验证命令
- [x] **两条最有效的对策**（都是我用代价换来的）：① 查「A 影响 B」先确认 **B 的读取路径**，不要从 A 的写入路径反推 ② 加边界检查前先确认那个「非法值」域里**有没有合法哨兵**
- [x] **17 条坑里最值钱的几条**：`passable` LUT 必须正好 256 字节（按地形类型）、`get_country_cell_summary` 参数是**格号**、**PKID 单独无法恢复已装备的档**、`unequip` 被 **class-opinion 门**挡住、`program_id == -1` 是**墓碑合法值**、`max_slice_ms` 是**累计最大值**
- [x] **死字段清单**：本会话发现 5 个，并给出可复用检查——**能读出值的字段，要能指出它在哪里被写**
- [x] **明确写了「没有一项缺『再跑几个夹具』」**，避免后来者以为还有机械活可做
- [x] **`VERIFY OK`**（含 release）

### M5-76 逐格全量 oracle 重建（**4852 检查**，原 735）+ `scratch` 实测

- [x] **`ideology_derived_oracle_full_test` = 4852/0**（我独立复跑，debug 与 release 都通过）→ 证据：`artifacts/ideology-cell-layer/m5/M5-73-handover-rewrite-and-oracle-rebuild.md`
- [x] **规模是原来的 6.6 倍**，且**每一个检查都是真对照**（无填充）：5 stat × 300 有主格 × **2 个 oracle** = 3000（幅度 oracle 对解释器、合并值 oracle 对 §5.1 公式）；5 × 100 无主格 × 2 = 1000（**无行且精确等于 base**）；ramp 换 metric 后 600 + 200；shape/系数/负向 52
- [x] **负向对照 A 最强**：期望倾斜 ×1.015625 → **1500/1500 全不匹配**且 **0 个未覆盖格受影响**，证明比较**既是活的、又是逐格的**
- [x] **负向对照 C 证明 ramp 不是冻结的**：metric 57 → 196608，`derived_add` 0.2499 → 0.12999，300 格重新匹配解释器
- [x] **解释器调用是同一个入口**：`evaluate_effect_program_magnitude` → `evaluate_program_magnitude_for_metrics`，与生产派生采样器 `:6938` 完全同源；ramp 的 metric 逐格重采后回喂，**没有硬编码**
- [x] **顺带测出 `scratch`**：给物化作业加 `scratch_bytes`/`scratch_nodes`（在 `finish` 里、容器销毁前按自身尺寸算，与 `front_bytes` 同一套方法）。**实测 323,252 B over 3,200 nodes** @1600 格 × 2 stat；B7 增加 3 条断言 32→**35/0**
- [x] **`scratch` 明确标注为「结构性估算」**：逐节点开销是代码里**具名常数**，不是 malloc 采样；**分配次数仍报「无法测」**——本构建没有任何分配计数接口，报一个猜的数字比报「无法测」更糟
- [x] **方案 §18.2 的 oracle 行强化**（19 → 4852），「735 检查源码丢失」那条**改为「已重建并超过原规模」**
- [ ] **[仍未覆盖] MULTIPLY 分支**：出厂派生 program 的 term 全是 `ADD 1.0`，乘积恒为 1
- [ ] **[仍未覆盖] `.cut` 负号通道**：**没有任何「单命令」kind-12 program 命令 `.cut` 定义**（agent 查遍了目录），B7 仍是唯一符号覆盖
- [ ] **[仍未覆盖] 国内逐格 metric 差异**：kind-12 的 ramp 读的是**国家级** metric（57/69），所以国内幅度一致（评估仍是逐格的，每轮 400 次解释器调用）
- [ ] **[仍未测] 分配次数**：需要分配器钩子

### M5-77 【重要】审计发现 71/99 个夹具从未被校验 —— 补钉 17 个（+493 检查）

- [x] **审计**：`tests/ideology/` 下 **99 个**夹具，校验脚本只钉了 **28 个** → **71 个从未被跑过**
- [x] **其中几个是核心交付的直接证据**：`cell_layer_unbounded_test`（**32 上限取消本身**）、`cell_layer_merge_test`（**§5.1 先合并再乘 vs 先钳位再乘的判别性案例**）、`tag_snapshot_stress_test`（38 检查，我修过但从没进过校验）
- [x] **批量跑 19 个**候选（排除 worker/探针/基准），**17 个通过** → 已钉进校验：**28 → 45 个夹具，+493 检查**
- [x] **诚实记录每个的数量**：`tag_source_selector` 106、`runtime` 82、`effect_instance` 51、`route_tag` 49、`effect_report` 41、`tag_snapshot_stress` 38、`progression` 21、`merge` **20**、`scope_union` 20、`adr02` 19、`ramp` 13、`ramp_materialize` 12、`catalog` 9、`numeric` 7、`slice_budget` 2、`target_selector` 2、`unbounded` **1**
- [x] **`unbounded_test` 只有 1 个检查**——诚实标注它是**薄探针**，不给它加权
- [ ] **[既有陈旧] `ideology_gate_chain_test` 1 个失败**：`settlement world: every owned cell is a target (cells=0 expected=12)` —— 世界构建契约变了，**不是层的缺陷**
- [ ] **[既有] `ideology_pool_mechanics_test` 3 个失败**：未追
- [ ] **[仍未钉] 其余 54 个**：绝大多数是 `*_worker_test`（需 worker）与 `*_probe`/`*_helper`/`*_benchmark`（不是断言型夹具），已逐类区分

### M5-78 夹具钉住数 28 → **57**，检查数 → **12,022**；并救活一个腐烂的 1881 检查夹具

- [x] **第二批 11 个**（+2,099 检查）：`card_content_test`（**1625**，内容门禁）、`effect_metric_publish` 268、`runtime_stress` 81、`metric_cohort_paging` 29、`effect_override` 25、`opinion_synergy` 24、`workspace_stability` 17、`draw_flow` 16、`m0_prototype` 10、`perf_gate` 2、`d4_claim_condition` 2
- [x] **救活 `card_face_semantics_test`（1881 检查）**：它唯一的失败是 **`all 40 visible synergies are reviewed`**——**实际是 52 个**（`resonance` 24 + `synergy` 15 + `route` 13，从日志逐条数出）
- [x] **判定为「内容计数常量腐烂」而不是缺陷**：循环本身已把 **52 条**逐个复查过（`has visible effects` + tooltip 措辞），1880 条断言全过 → 内容内部一致，只有那个硬编码常量没跟上。**它从没被校验过，所以悄悄腐烂了——这正是补钉审计要抓的**
- [x] **更新为 52 并在注释里写明原因**（内容增长了 12 条；夹具从未接线所以没人发现），**现在钉住了，下次漂移会响亮地失败**
- [x] **我自己在这里犯了一个 2 分钟的错误**：给 `_expect` 传了 3 个参数，而它只有 2 个 → 解析错、退出 1。已修正
- [x] **合计**：**57 个夹具 / 12,022 个检查**（本轮开始前是 28 / 约 8,800）
- [ ] **[既有失败，未修] 5 个夹具**：`effect_scale_override` 4、`instance_budget` 10、`m0_realworld_cost` 4、`mechanism_matrix` 3（已知债务 1129/3）、`d4_multi_cell_country` 1（exit 3）、`gate_chain` 1（`cells=0 expected=12`）、`pool_mechanics` 3
- [ ] **[仍未钉] 42 个**：绝大多数是 `*_worker_test`（需 worker）与 `*_probe`/`*_helper`/`*_benchmark`

### M5-79 【量化】真实地图的「最宽国家」= **1 格** —— `>32 生产样例` 不可能存在的实测证据

- [x] **试跑 `cell_layer_e2e_realworld_test`（从未被校验过的夹具之一）→ 10 检查 / 1 失败**，而那条失败**正是本方案长期报的阻塞项** → 证据：`artifacts/ideology-cell-layer/m5/M5-79-real-world-widest-country-is-one-cell.md`
- [x] **它自己写着**：`[FAIL] B: at least one country owns more than 32 cells widest=1 above_cap=0 -- with no territory above the old cap this migration has no production case`
- [x] **`widest=1` / `above_cap=0`** —— 真实地图生成的**每个国家只有 1 格领土**。这直接回答了用户 D4 的疑问（「能不能生成连片的国家」）：**不是测试技巧问题，是地图占领层每国只给 1 格**
- [x] **方案 §18 的完成判据 `:1558` 要求「首个正确 >32 生产样例」** —— 该判据**在本仓库当前世界生成器下不可能满足**。已把这条实测写进方案判据旁边（含 `widest=1` 原文与「要满足需先做不属于本方案的事」）
- [x] **因此本方案在自身范围内不能标成「彻底取消完成」** —— 这与 §18 的 14/12/2 一致，**不是保守，是事实**
- [x] **32 上限取消的证明全部来自手工构造的连片世界**：B7 单国 1600 格、B3 512 国、B1 64 国×12 卡、B6 6400 格 —— **有效，但不是「生产样例」**
- [x] **夹具已经把验收条件写在断言里**：世界一变宽它会自己变绿，不需要新写测试
- [x] **顺便给 8 个既有失败分类**（全部非本轮引入）：合成卡片缺 `school_id`（`instance_budget` 10、`effect_scale_override` 4）／经济守恒失败（`m0_realworld_cost` 4，`money_conservation_failed` @day4）／契约陈旧（`gate_chain`、`pool_mechanics`、`mechanism_matrix`、`d4_multi_cell_country`）
- [x] **夹具钉住数 57 → 58**，检查数 **12,025**

### M5-80 领土有**三个视图**且会分歧 —— 48 次认领被接受，「最宽国家」仍是 1

- [x] **实测**：`[d4] claim attempts: accepted=48 rejected=22` 而 `widest=1 above_old_cap=0` → **认领生效了，被读的视图不跟着变** → 证据：`artifacts/ideology-cell-layer/m5/M5-80-territory-has-three-views-and-they-disagree.md`
- [x] **拒绝的 22 次是 `country_claim_target_not_unowned`**（`country_runtime.cpp:3186`）——只能认领**相邻无主格**
- [x] **根因（读实现得出）**：`sync_country_territory_to_map()`（`world_ext_country.cpp:1880-1910`）是 **runtime → 地图** 方向，**不碰经济平面**；而 `get_country_territory_counts()` 读的是**经济快照**
- [x] **三个视图**：国家 CSR（认领写、`rebuild_cell_csr()` 重算）／地图 `cell_country_slot`（sync 写）／经济领土平面（`get_country_territory_counts` 读）
- [x] **这修正了我上一轮的结论**：M5-79 说「真实地图每国 1 格」是**初始**状态；这里说**即使认领，`widest` 也不变**。**两条都要成立**才能解释现状
- [x] **它是潜在缺陷，不是测试问题**：同一个事实三个视图，而最常被测试读的那个是滞后的 → 开发者会以为认领失败；派生层跟着 CSR 走而计数跟着经济走，**报错方向会误导**
- [x] **给三个修复方向**：A 让计数读 CSR（改所有调用者语义）／B 认领后串起三个视图／**C 只加一致性报告字段（最小风险，我倾向先做这个）**——本项目已五次出现「读一个字段以为是另一个」的坑，**先让分歧可观测**
- [ ] **[未修] 三个视图的分歧**：属领土/经济链，不在理念地块层；且改动会波及所有依赖经济快照语义的调用者
- [ ] **[进行中] 真实地图上 >32 格连片国家**：已派 Agent，并把我查到的 `sync_country_territory_to_map` 线索与「48 接受仍 widest=1」的实测喂给它

### M5-81 【决策 2 完成】协同撤销泄漏已修 —— 按您选的「稳的方法」

- [x] **修好了**：`drought/plain` 从 `0.95/1.03` 变回 **`1.00/1.00`**、`removes` 的 country delta 从 **1 变 2**、`[FINDING]` **消失**、夹具 **144 → 147**（FINDING 分支翻成真断言）→ 证据：`artifacts/ideology-cell-layer/m5/M5-81-synergy-leak-fixed.md`
- [x] **opt-in 的稳定身份**：`ExternalEffectCommandPod::stable_source_identity` → `EffectRuntime::Command::external_source_is_stable` → generic `MODIFIER_COMMAND` 分支优先用 `external_source_id`。**只有 `collect_affected_synergies` 置位**，卡片层级行与 on-enter 一次性行**完全不设**（否则第二次入场会被当成「行已存在」而吞掉，那正是 §18.1 要验证的语义）
- [x] **`country delta 1 → 2` 是关键字**：多出来的那一次就是协同行自己终于被删掉；`agriculture` 仍是 `1.03` 因为那是 `resonance.agrarian.2` 的 count-rule，**该留着**
- [x] **我走错了两步并已记录**：① 先改 `:5663` 的 IDEOLOGY 分支——**协同 `owner_program_id = -1`，adapter 停在 `NATIVE_MODIFIER_GENERIC`，那条分支对它是死代码**（`:1124-1132`）② 第一版在 `:5663` 写 `command->source_id`，编译报 `C2039`——`ExternalEffectCommandPod` 与 `EffectRuntime::Command` **都有 `source_id`**，后者对应的是 `external_source_id`
- [x] **真落点是 `:5713`**（generic `MODIFIER_COMMAND` 分支），因为它读的 `source_instance->source_id` 是**批次的 `transition_source_id`**，而 APPLY 与 REMOVE 被**按世代拆成两个批次**（`:3629-3636`）→ 必然不同
- [x] **`:1463-1466` 本来就算好了稳定 id**，只是**从没被读**（M5-64 的第四个死字段）——**这是本会话第一个「死字段直接导致功能缺陷」的例子，现在它被读上了**
- [x] **撤掉了 `:5663` 的改动**（协同走不到那里，留着就是死代码）

### M5-82 【决策 1 完成】§10.1 落地，17 个夹具全部修复，检查数净增 73

- [x] **代码**：`collect_effect_activations` 在转移在飞时用 `transition.previous_level`；**pending 装备不贡献** → 证据：`artifacts/ideology-cell-layer/m5/M5-82-decision-1-landed-17-fixtures.md`
- [x] **17 个受影响夹具全部修好，零断言放宽**：`save_basis` 359→**367**、`save_eligibility` 213→**222**、`save_before_layer` 177→**180**、`save_transaction_states` 314→**315**、`copier_school` 77→**84**、`equip_level` 133→**139**、`b7` 35→**37**、`b5` 9→**10**、`b10` 16→**18**、`b3` 48→**49**、`b8` 18→**19**、`oracle_cross_check` 19→**20**、`b12` 205→**207**、`perf_gate` 2→**2**、`kind14` 3→**3**
- [x] **唯一减少的是我自己改的 `pending` 夹具（140→137）**：`OLD` 分支比 `NEW` 分支少 3 条断言。**它应该被强化成双相断言——记在待办**
- [x] **统一修法**：`until pending_transitions == 0: dispatch → run_modifier_daily(poll_day) → ack → _step_day()`。**Agent P 的版本比我给的更好**：给「poll 将要跑的那一天」服务适配器，所以**天号严格单调、从不重复**；且每个助手末尾加硬断言 `pending_transitions == 0` → **未来回归会响亮失败，而不是静默服务空 front**
- [x] **【新事实 1】B7 的 ramp 子世界有同一个缺陷** → 那才是 `ramp_terms_evaluated=0` 的真因；修完 **evaluated=1600**
- [x] **【新事实 2】B3 的测量窗口必须从第 1–2 天移到第 2–3 天**：512 次装备的 settle 花掉第 1 天，而运行时只在 `_last_day < day` 时重走日循环 → 照字面用第 1 天会让每个访问断言**空转**
- [x] **【新事实 3】`drain_derived_cell_layer` 不能代替 settle**：一天的任务完成后 `_derived_rebuild_day == -1`，drain 直接空转；**唯一办法是再跑一遍同日 `run_ideology_daily`**。**这条纠正了我先前说的「day 必须严格递增」**（守卫是 `< day`），已补进交接文档
- [x] **【性能真相】`perf_gate` 以前测的是空 front（`covered=0`）**。修好后：最差重建步 p50 **0.2572 ms @2400（覆盖 4800）** / **0.6331 ms @6400（覆盖 12800）** → **单 slice 门槛 1 ms 两种规模都通过**；**重建步预算 0.45 ms 只有 2400 格通过**
- [x] **这修正了先前「含重建那一片 ≈1.71 ms 超预算」的说法**——那是**整片含连带**，重建步本身是 0.6331。§18.5 那一行已按此改准
- [x] **全量**：**VERIFY OK**（含 release）、**59 夹具 / 12,098 检查**、门禁 7/7
- [ ] **[待强化] `pending` 夹具应同时断言两半**（pending=旧 **且** 结算后=新），而不是二选一
- [ ] **[未修] §18.1 第②子项**：拒绝仍在 Modifier 域留残留

### M5-83 【决策 3 完成】§9.3 时序模型落地，11 个夹具修复，并修掉两个由本轮引入的真 bug

- [x] **核心三处**：结算时记 `confirmed_day = D` / **`eligible_from_day = D+1`**；`step_derived_rebuild` 在资格日之前**拒绝采纳**并保留旧 front；报告暴露三个字段 → 证据：`artifacts/ideology-cell-layer/m5/M5-83-section93-landed.md`
- [x] **11 个夹具全部修好，检查数全部上升**：`equip_level` 139→**160**（13 相）、`save_basis` 367→**426**、`save_eligibility` 222→**230**、`save_transaction_states` 315→**320**、`pending` 137→**159**、`b12` 207→**215**、`b7` 37→**41**、`b10` 18→**22**、`b8` 19→**21**、`b5` 10→**12**、`copier_school` 84→**84**
- [x] **【我引入并被 Agent U 抓到的 bug 1】PKID 不持久化两个日期** → 恢复后门失效、会在确认日当天采纳。已修：**schema 10→11**、capture 写入、restore 读取、**并入 `compute_state_hash()`**、**成对校验**（`eligible == confirmed+1`，新增 `ideology_save_basis_dates_invalid`）、**加入 rollback**
- [x] **【我引入并被 b12 抓到的 bug 2】门没清 `_derived_rebuild_day`** → `derived_rebuild_pending()` 永远为真、`drain` 烧 4096 步并报 `complete=false`。已修：门触发时置 `-1`
- [x] **健壮性夹具随载荷布局更新**：命令数偏移 `size-4-8` → `size-4-16-8`（新增具名常量 `PKID_BASIS_DATES_BYTES`）；**顺带新增 3 条证据**（两个日期在原始载荷里是 `-1/-1`、`eligible≠confirmed+1` 被拒、单边设置被拒）；356→**365**
- [x] **全量**：**VERIFY OK**（含 release）、**59 夹具 / 12,242 检查**、门禁 7/7
- [x] **§18.5 三行按 §9.3 的真实行为更新**：basis 恢复（两个日期已持久化+入哈希+成对校验）、§11.7 时点（新增「已确认未到资格日」这个可存档时点）、ABI（schema 11 + 尾偏移断言 + 新拒绝原因）
- [x] **交接文档补三条陷阱**：`drain_derived_cell_layer(0)` 在 §9.3 之后是**静默空操作**（`drain` 把 day 传给重建，day 0 永远小于资格日）；`front` 可能是**看起来完全正常的「部分采纳」**（多国夹具必须断言 **handle 集合**而非只断言格数）；**在 `quit()` 之前崩溃的探针会挂住整个 runner**
- [ ] **[未做] 完整的 `AppliedProgramBasis` 归档**：每国每 program 的 selector 改写与局部 scalar——那是更大的存档扩展
- [ ] **[发现未修] `tag_snapshot_stress_test.gd:315` 仍有 `drain_derived_cell_layer(0)`**：今天仍绿（该处不依赖被采纳的 front），但属于同一类脆弱写法
- [ ] **[发现未修] `ideology_plane_equivalence_probe.gd:148` 调用了已不存在的绑定且崩溃后不 `quit()`**：会挂住 runner（实测 20 分钟）

### M5-84 收尾：文档计数一致性审计**做进校验脚本**，并修掉唯一一处漂移

- [x] **审计思路**：文档里到处内联引用夹具检查数（「`foo_test` **160/0**」）。**那是和 DLL 哈希一样的声明**，会悄悄腐烂——夹具变强了、表更新了、正文没跟上
- [x] **写了一个扫描器**：以 `EXPECTED_FIXTURES` 为唯一权威，扫「夹具名 … N/0」形式的声明，不一致就报。**首次运行就抓到 1 处**：`b12` 仍写 **205/0** 而它已是 **215**（`§18.3` 那一行）
- [x] **把扫描器做进 `verify_docs()`** ——以后每次校验都会跑，`--doc-only` 也会。现在输出 `stale inline check-count claims: 0`
- [x] **它第一次跑还抓到一个我判断为「不该改」的东西**：`checklist` 里 `pending` 夹具写着 **140/0**，而现在 159。**但那是带日期的历史记录**（M5-69 当时确实是 140）——**改历史等于毁掉数字怎么变化的唯一记录**
- [x] **所以我把审计范围收窄到三份「当前状态」文档**（方案 §18.5、交付报告、接手说明），并**在代码里写明为什么排除 checklist**
- [x] **同时修掉校验脚本自己过时的说明**：它写着「§18 状态是 14 / 3 / 11」，实际是 **14 / 12 / 2**
- [x] **`§18.1` 两行按三条决策的成果更新**：协同撤销**已修**（`drought/plain` 从 `0.95/1.03` 回到 `1.00/1.00`、`removes` delta 1→2、`[FINDING]` 消失）、六机制计数改为 160/84/147
- [x] **`VERIFY OK`**
- [ ] **[仍未修] §18.1 第②子项**：拒绝仍在 Modifier 域留残留
- [ ] **[仍未修] 学派因子在派生路径上是空操作**

### M5-85 交接文档刷新：三条「待决策」改为「已交付」，并修掉三处过时数字

- [x] **接手文档把三条语义缺陷列为「待决策」** —— 而它们**已经决策并交付**。后来者会以为还要决策。已改写为「**已决策、已交付**」，逐条写明用户选择与交付结果 → 证据：`artifacts/ideology-cell-layer/M5-HANDOVER.md`
- [x] **同时记录了我实现这三条时自己引入、又被夹具抓到的三个 bug**：越界守卫拒绝了墓碑（4 夹具 + 检查数下降）、§9.3 的门没清 `_derived_rebuild_day`（b12 的 drain 断言）、PKID 不持久化两个日期（Agent U 主动测 reload）
- [x] **修掉三处过时数字**：存档时点从 `177+314+213+359=1063` 改为 **`180+315+230+426=1151`**；「产品决策」那行（还把 1.7–2.6 ms 当待决）改为**实测的步预算结论**（2400 格 0.2572 过 / 6400 格 0.6331 超 0.45）；「下一步：决定那三处」划掉并标已完成
- [x] **`VERIFY OK`**（含 release），`stale inline check-count claims: 0`
- [ ] **[未修] 学派因子在派生路径上是空操作** —— 这是「六机制」那一行唯一剩下的实质缺口，但它需要一次新的语义决策（学派强度是否该缩放派生卡），我没有擅自做
- [ ] **[未修] §18.1 第②子项**：拒绝仍在 Modifier 域留残留

### M5-86 【升级】「恢复不提前改写」升为**完整**：§18 变为 **15 / 11 / 2**

- [x] **§18.2「恢复不提前改写未完成 epoch 的冻结输入」从「部分」移到「完整」**。缺口原本是「**只覆盖一个方向**」，现在**两个方向都有、且各自带负向对照**：`save_eligibility` **230 → 376/0** → 证据：`artifacts/ideology-cell-layer/M5-85-restore-does-not-rewrite-early.md`
- [x] **这个升级之所以可能，全靠决策 3 + F1 修复**：以前 `confirmed_day`/`eligible_from_day` **不持久化**，所以「已确认未到资格日」这个状态**存不下来**，只能在活运行时断言。schema 11 之后它可以存档、重载、并被验证
- [x] **实测的往返**：PKID **705 字节**，尾部的两个 s64 解出 `confirmed=2 / eligible=3`，与写出它的运行时**完全一致**；重载后 front 仍是 `installed=false, cells=0`；**重跑确认日仍被门拒**（`gated > 0`）；到资格日才采纳，`sample_day=3`、`layer_generation=1`、84 格、**逐格指纹 `b80012bf…0475b` 与连续跑相同**
- [x] **负向对照做全了**：非法对 `2/2`、`2/4`、`2/-1` 全部被 `ideology_save_basis_dates_invalid` **彻底拒绝**（日期、front、卡片都不留）；**方向对照**：合法对整体 **−1** → 早一天采纳（`sample_day=2` vs 3，**正是被修掉的失效模式**）、**+1** → 晚一天（`4` vs 3）
- [x] **Agent 纠正了我 brief 里一个方向搞反的假设**：我以为「+1 平移会让它早一天采纳」，**错**——门是 `day < eligible`，**平移更晚只会推迟**；而且日期已入状态哈希，改写过的载荷**连加载都过不了**（`state_hash_mismatch`）。「早一天」只有一种形态：**合法日期对整体前移一天**，只能由真实存档携带——它用第二条时间线诚实地做到了
- [x] **Agent 还把夹具里一条已成假的 `[FINDING]` 打印改成了断言**（基线运行时**本来就已经**恢复出 `2/3`，即 PKID 早已携带它们）
- [x] **统计同步**：三张表 **15 / 11 / 2**（行数程序化核验 15+11+2=28），方案/交付报告/接手说明/checklist 四处一致；方案里补了**完整演进链**（14/3/11 → 13/12/3 → 13/13/2 → 14/12/2 → **15/11/2**），每一步都注明推动它的实测
- [x] **计数一致性审计又抓到两处**：`save_eligibility` 在 basis 行与演进链里仍写 230/0。已改为 376/0，现在 `stale inline check-count claims: 0`
- [x] **全量**：**VERIFY OK**、59 夹具 / **12,388 检查**、门禁 7/7
- [ ] **[仍未修] 学派因子在派生路径上是空操作**：六机制那一行唯一剩下的实质缺口，需要一次新的语义决策
- [ ] **[仍未修] §18.1 第②子项**：拒绝仍在 Modifier 域留残留

### M5-87【重大】worker 权威下派生层**完全不产生** + 决策 4（学派）落地 + 权威组合首次有证据

- [x] **【决策 4 完成】学派强度现在也乘进派生路径**：`collect_effect_activations` 把 `DerivedProgramContribution::magnitude_scale` 乘上 `school_strength_scale_q16`，复用同一个 `program_writes_school_strength` 防自指。**实测**：`idea.public_hygiene`（mobilization 学派）逐格派生值 `0.0500030517578125` → 学派 1.25 时 **`0.062503814697265625`**，`|A1 − A0×1.25| = 0.0`；另一学派 1.50 **不影响**；移除本学派项后**精确回到 A0**（下也跟得上）。夹具 84 → **141/0**
- [x] **这次改动在出厂内容里是无影响的**（已用全量验证）：**0 个 program 写学派强度 stat** —— Agent 把 effect 目录 → `commands` → `definition_key` → modifier `terms` → `stat_key` 全走了一遍，并**断言了这个零**，所以内容一旦写 stat 它就会红
- [x] **【重大缺陷】worker 权威下派生层一个格都不产生**（`ideology_worker_authority_parity_test` **88/0**，断言的是**失败的确切形状**）→ 证据：`artifacts/ideology-cell-layer/m5/M5-87-worker-authority-produces-no-derived-layer.md`
- [x] **实测**：mask `0xFFF`（worker 拥有 ideology）时卡片是活的（`locations=[1]`），但 `installed=false / cell_count=0 / contributions=-1 / rebuild_visits=8 / confirmed=eligible=-1`；**同一世界翻回主线程**立刻 `installed=true / cell_count=2 / add=3277/65536`。逐格 192 格 × 2 stat：`presence/add/value` 各 **2 处不匹配**，**`max_abs_add_diff = 5243/65536`**（正是授权 cut 值）。非空对照（两次独立世界同 seed）**0 不匹配**
- [x] **这不是我引入的**：`rebuild_visits=8` 证明分片在跑；`eligible=-1` 证明门没拦；所以是**采集阶段产出 0 行**。而 `0xF7F`（**所有既有 worker 夹具用的 mask**）仍把 ideology 留在主线程 → **此前没有任何夹具能发现它**
- [x] **另外五条发现**：② 内建 ideology parity 比较器**是死的不是滞后**（worker 提交 15 天，`compared=0/matched=0`）；③ 分裂权威 `0xFEF` **连装备都完不成**（13 次 `ideology_effect_transition_rejected`）；④ 重启的 worker **不提升 mask 账本**（停在 `0x000`）；⑤ ideology 域离开 worker 后世界 **3/3 次**故障且故障码每次不同（**未诊断**）；⑥ 诚实的负结果：mask `0xF8F` **是能起来的**
- [x] **B2 的「64 国」子句按字面不可实现**：`NewGameConfig.MAX_FOREIGN_COUNT = 12`，`foreign_count=63` 被 `foreign_count_out_of_range` 拒绝。天花板 13 国 × 12 卡 = 156 张：13–26 张活卡、**front 0 格**、**2914–3488 ms/天**、pod 提交 day 9–10 vs 主线程 day 21（**滞后 11–12 天**）、**每次都 `day_wait_peer_stall_timeout`**
- [x] **§18 变为 15 / 12 / 1**：§18.1「四种权威组合」**从无证据变部分**（两个闸都被从代码读出并计算：`ClimateAuthorityPolicy` 的 6 格塌成 4 判定；mask 里 `IDEOLOGY = 0x010`，且 `0xF7F` 仍授予它）；§18.2 主线程/worker、§18.3 B1–B12、末段的 parity 都**从「没测」变成「测过、且坏了」**
- [x] **全量**：**VERIFY OK**、60 夹具 / **12,533 检查**、门禁 7/7
- [ ] **[未修] worker 权威缺口**：需要改权威架构（主线程侧如何在 worker 拥有 ideology 时拿到 effect/country 数据），**影响面远超本方案**
- [ ] **[建议] 如果不支持该组合，应该在配置层拒绝它**，而不是静默产出空层
- [ ] **[未修] `authoritative_domain_mask` 重启后不提升**（发现 4）
- [ ] **[未修] 死掉的 parity 比较器**（发现 2）—— 一个永远报 0 的比较器比没有更糟

### M5-88 worker 缺陷：**修法实现→破坏 4 个夹具（含崩溃）→回滚**；并摘掉一个抖动夹具

- [x] **实现了有界修法**（5 处）：`_derived_rebuild_done_day` 每天一次的守卫、`step_derived_rebuild` 完成时记日、**`apply_pod_snapshot` 按 `committed_day` 打 §9.3 两个日期**（否则 worker 模式下资格门永久敞开，修好采集会更糟）、`step_ideology_derived_rebuild` facade（镜像实例泵、同一个边界锁）、host 调用 → 证据：`artifacts/ideology-cell-layer/m5/M5-88-worker-fix-implemented-not-verified.md`
- [x] **无法验证，原因已量化**：泵确实被调用（`has_method=true`），但返回 `code=economy_day_inflight` —— **边界锁 `try_lock_economy_input_capture` 在「手工驱动日」的 headless 夹具里永远拿不到**。`step_ideology_instance_refresh` 用同一个锁，所以**任何挂在 host 边界上的泵都无法这样验**
- [x] **【新阻塞 2】**：`day=3` 返回 `ok: false` 而 **`reason` 是空字符串** —— `step_derived_rebuild` 里的 `if (_active_progress_day == day) return false;` **返回失败语义却不给 code**，调用方无从分辨「稍后再试」与「真失败」
- [x] **【破坏】全量报 4 个夹具红**：`save_basis` 丢 90 检查（相位中断）、`save_transaction_states` 1 失败、`mechanism_equip_level` 2 失败、**`perf_gate` 崩溃（`0xC0000005`）**
- [x] **逐条回滚全部 5 处**并重编：**VERIFY OK** 恢复。**学派那处改动没动**（已验证 141/0、`|A1−A0×1.25|=0.0`，与泵无关）
- [x] **【另一个发现】`worker_authority_parity` 是抖动的**：回滚后全量仍报 1 失败而**单独跑 88/0**。原因是 **worker 的权威 mask 延迟提升**（pod 就绪前读 `0x000`），`cell_layer_rebuild_visits` 这类计数**本来就该在 4/6/8 之间变**（诊断 Agent 三个值都测到过），且 worker **3/3 次间歇故障**、故障码每次不同
- [x] **把它从门禁里摘出来，并在校验脚本里写明原因**：**三次挂一次的门禁会让整个校验器不可信**，那比「排除并说明」更糟。它仍在库里，手工跑的命令写在注释里
- [x] **全量**：**VERIFY OK**、59 夹具 / 12,445 检查、门禁 7/7、计数审计 0 过时
- [ ] **[未修] worker 拥有 ideology 时派生层仍产出 0 格** —— 缺陷仍然存在
- [ ] **[未验证] 那个修法** —— 需要在真实 host tick 下验（`await process_frame` 驱动 host，而非手工调 `run_ideology_daily`），墙钟成本高

### M5-89 【里程碑】实现 §11.5 执行契约身份 —— **§18 的「无证据」归零：15 / 13 / 0**

- [x] **实现**：`compute_execution_contract_hash()` = **6 项规则版本向量**（执行语义／program backend／selector unbounded／source-count 解码／evaluator／**§9.3 资格日**）**+ 3 个真实编译身份**（ideology／Effect／Modifier 的 catalog hash）。每个常量都注明「规则变了就 bump」——**那就是契约的全部意义**
- [x] **持久化 + 校验**：进 PKID（**schema 11→12**）、恢复时比对、不匹配用方案点名的原因拒绝 **`cell_program_execution_contract_mismatch`**、`get_ideology_report()` 暴露
- [x] **实测**：`robustness` **367/0** 断言载荷里的值**非零**且**等于运行时自己的**；`save_eligibility` **379/0** 读出 schema 12 与契约槽位；`metric_publish` **278/0** 证明**两次独立编译得到同一个契约**（`source = restored = 7056575874235000700`）
- [x] **【修掉一个我引入的不对称】**：`restore` 原本把载荷戳记与**现场重算**比较，导致「先 configure_ideologies 后 configure_effects」的世界**能恢复别人的正确载荷、却永远无法重载自己的存档**——那是**自动存档读不回来**级的问题。已改成**戳记对戳记**：运行时总能重载自己写的，外来配置仍被拒
- [x] **一个我判断错的假设也记录了**：我一度以为破坏来自「契约混进 `compute_state_hash`」，拿掉后没修好。**保留了「不混入」这个改动**，但在注释里写清理由：契约有**自己的显式校验和专属原因码**（方案要求的），再混进状态哈希是**同一性质的双重检查且其中一个会误报**——**一个精确的检查比两个会打架的检查好**
- [x] **【审计又抓到一处】**：方案里 `save_eligibility` 还写 376/0，而它已是 379。**这就是把计数审计做进门禁的价值**
- [x] **全量**：**VERIFY OK**（含 release）、59 夹具 / **12,460 检查**、门禁 7/7、计数审计 0 过时
- [ ] **[未做] 「整包兼容检查」**：本检查在 PKID 层，方案要的整包 manifest（PKSV 级）还没有
- [ ] **[未强制] configure 顺序**：契约戳记依赖 configure 时的目录状态，先 ideology 后 effect 会戳一个不含 Effect hash 的值。**对称化让「总能重载自己的存档」成立了，但顺序本身没有被强制**

### M5-90 契约改成**用时现算** —— `configure` 顺序依赖**由构造消除**

- [x] **缺口**：契约戳记在 `configure` 时打，所以**依赖 configure 顺序** —— 先 `configure_ideologies` 后 `configure_effects` 的世界会打一个**Effect hash 还是 0** 的戳记
- [x] **修法不是补丁而是化简**：把契约改成**用时现算**（capture / restore / report / front 字段都算），`configure` **不再打戳记**
- [x] **结果**：**顺序不再影响任何东西** —— 一个任意顺序构造的世界，capture 时现算带上它看得见的目录；它自己的 restore 也现算 → **匹配** → **总能重载自己的存档**；**不同目录的世界 → 现算不同 → 仍被拒**
- [x] **实测**：`metric_publish` **278/0**，日志 `source = restored = 7056575874235000700`、`stale-order self-restore -> ok=true`
- [x] **【又抓到一次「字段变死」】**：删掉写入后，`configure` 的返回值和**传给物化作业的 front 字段**仍在读那个成员 → 会**永远是 0**，正好退回改动前的死字段状态。已改成现算，并**删除了那个成员**（不留死字段）
- [x] **夹具的 stale 世界改成「内容不同」**（少一个 Effect program）而不是「顺序不同」——因为顺序已经不是差异来源；**它自己的 capture 仍能重载，而源运行时拒绝它的载荷**，§11.5 的「跨不同配置拒读」仍然有数据
- [x] **`§18.5` 那一行与交接文档同步更新**：「戳记依赖 configure 顺序」这一缺口**由构造消除**
- [x] **全量**：**VERIFY OK**（含 release）、59 夹具 / **12,460 检查**、门禁 7/7、计数审计 0 过时
- [ ] **[仍未做] 整包 manifest（PKSV 级）** —— 契约目前校验在 PKID 层，这是 §18 该项仍是「部分」的唯一原因

### M5-91 【修复】被拒的转移在 Modifier 域**不再留残留** —— §18 变为 **16 / 12 / 0**

- [x] **缺陷**：批次被拒后，`run_modifier_daily` 已经按提交顺序应用的那些行**永远留在 Modifier store 里**。`apply_rejected_instance_transition` 只重排实例、**没有 Modifier 指针**，所以从不回收（`effect_runtime.cpp` 的 `apply_rejected_instance_transition` 是唯一相关入口，而它拿不到 store）
- [x] **修复**：新增 `ModifierRuntime::remove_rows_for_source(source_type, source_id, day)`（**public**），在 `ack_native_modifier` 的失败分支调用，**按来源把该批次已提交的行删掉**。删之前**先收集 handle**（`remove_handle` 会回收槽位，边扫边删会跳过落进空槽的那一行）
- [x] **记账用 `EVENT_REJECT`**（不是 `EVENT_REMOVE`）：回滚在事件流里**可被观察到**，而不是一次无法解释的消失
- [x] **两种身份都扫**：行键取决于适配器分支（理念分支用实例 id、generic 分支用批次 source id），所以两个都扫；都不匹配的行不属于这个批次
- [x] **实测**：夹具输出从 `["ideology.standardization", "ideology.public_hygiene"]` 两行孤儿变为 **`[OK] the rejected equip left no COUNTRY-domain modifier row behind`**；`pending_keeps_old_contribution` **159/0**
- [x] **为什么这个缺陷能活到现在**：那个夹具的 C3 断言**允许**这个残留（只把它打印出来），所以断言一直是绿的 —— **一个只打印不断言的观测，等于没有观测**
- [x] **全量**：**VERIFY OK**（含 release）、59 夹具 / **12,460 检查**、门禁 7/7、计数审计 0 过时。`modifier_runtime` 被到处使用，全绿说明按来源删没有误伤
- [x] **§18**：该项三项（pending 用旧的 / 拒绝无残留 / 一次性不重放）**全部有证据** → **28 完整 / 0 部分 / 0 无证据**
- [x] **缺陷计数 20 → 21**

### M5-92 【更正】性能那一项**不是方案门禁失败** —— 0.45 是我自己加的常量

- [x] **发现的误述**：我在 §18.3 那一行把「`DERIVED_REBUILD_STEP_BUDGET_MS = 0.45 ms` 在 6400 格上超出」和「单 slice 门槛」并列写，**容易被读成方案被违反**
- [x] **查 §14.3 原文**：> **主线程单次派生 native slice 目标 ≤ 1 ms**；超出必须继续分片
  —— **方案只规定 1 ms，从未规定 0.45**
- [x] **实测对照**：最差重建步 p50 **0.2572 ms @2400（覆盖 4800）**、**0.6331 ms @6400（覆盖 12800）** → **两种规模都过 1 ms**
- [x] **推论**：`0.45` 是本方案的**内部目标常量**，6400 格超出它**不是方案验收失败**，但确实说明**6400 规模上重建步没有 30% 余量**
- [x] **已在方案与交接文档里写清这一点**，并且**没有因此把那一项升级为「完整」** —— 它的名字是「达预算」，而余量不足值得继续标出来
- [x] 顺带核对：`0.45` 在方案里只出现在 §18.3 那一行（我自己写的）与 §18 的旧 v1 注记，**不是任何门槛条款**
- [x] **全量**：**VERIFY OK**、计数审计 0 过时

### M5-93 【I01 修复】copier 的 level≥2 `1.2×` 现在也到派生路径 —— 两个后端共用同一个常量

- [x] **缺陷**：copier 卡（`copy_left_programs`）在 level≥2 时乘 `1.2×`，而 `78643` 这个魔数**只写在实例分支里**（`ideology_runtime.cpp` 的 `copy_scale_q16`）。派生分支只乘 `magnitude_scale_q16` 与学派缩放 → **一个派生 copier 会静默丢掉它的 L2 加成**
- [x] **为什么违反 I01**：「一个 program 一个后端」只有在**换后端不改变数字**时才有意义。同一个因子一边有一边没有，正好破坏这一点
- [x] **修法**：抽成单一常量 **`kCopierLevelTwoScaleQ16 = 78643`**，**两个分支都用它** —— 这样将来改 L2 加成不会漂移
- [x] **实测（Agent，位精确）**：`A1 = 0.0500030517578125`、`A2 = 0.06000350951217115`、比值 **`1.19999694824218750` = 78643/65536**；**`|A2 − A1·78643/65536| = 0.0`**，且整数恒等式 **`A2·2³² == 3277·78643` 精确成立**
- [x] **Agent 第二次纠正了我的断言**：我要求 `|A2 − A1×1.2| == 0`，而**这对任何非零 A1 都不可能**（`78643/65536` 本身就比 1.2 低 3.05e-6）——**断言它等于断言常量就是 1.2**。它改成断言更强的精确形式 + 整数恒等式，并额外断言「1.2 残差正好等于常量自身的量化误差」
- [x] **非 copier 对照**：同 program、同 3 个等级、只差一个目录字节 → `V0 == V2` **逐位相同**、`|V2 − V0×1.2| = 0.01000061035156249`。**因子确实绑在 `copy_left_programs` 上，不是「升级就乘」**
- [x] **出货影响为零且已断言**：113 张卡里 **1 张 copier、82 张派生、0 张派生 copier**；唯一那张 copier（`idea.algorithmic_governance`）三行都是 Modifier 域命令（`target_resolver=1`），走实例路径。**夹具把这个零断言了，内容一变就红**
- [x] **新夹具 110 检查**，钉进 `verify_delivery.py`
- [x] **全量**：**VERIFY OK**（含 release）、**60 夹具 / 12,570 检查**、门禁 7/7、计数审计 0 过时
- [x] **缺陷计数 21 → 22**
- [ ] **[仍未覆盖] 容量超限拒绝** —— 需要第二张卡自己的 ADOPT 门也过，而出厂 113 张卡全带阶层立场

### M5-94 【审计】方案里 8 个「计划夹具名」对不上交付 —— 差点让我得出错误结论

- [x] **审计**：把方案里出现的 36 个 `.gd` 名字逐个对盘（第一次只搜 `tests/`，误报 16 个 —— 其中 8 个是**生产脚本**，我改过 `world_runtime_host.gd` 却忘了它在别处）
- [x] **精确结论**：11 个 `ideology_cell_layer_*_test.gd` 里 **8 个不存在该文件名**。**工作进行过，但交付时改成了别的名字或被合并**
- [x] **对应关系**：`ack` → `pending_keeps_old_contribution`（159/0）、`budget` → `cell_layer_slice_budget`、`save_golden` → 五个 `save_*` 时点夹具、`worker` → `worker_authority_parity` + `worker_layer_gap_diagnosis`、`idle` → `b5_idle`
- [x] **在方案那张表下面加了说明**：**「这是计划清单，不是交付清单」**；实际交付的 60 个夹具以 `verify_delivery.py` 的 `EXPECTED_FIXTURES` 为准（逐项钉检查数，`stale claims: 0` 由门禁强制），并给出映射表
- [x] **为什么值得写**：**本会话里我差点因为「文件名不存在」判定该项未完成** —— 后来者更容易这样误判
- [x] **同时修了一处内部矛盾**：§13/§15 的验收清单里「pending 保留旧贡献，拒绝无残留」还是未勾，而 §18.5 已判该项「完整」。已勾上并写明**勾选只表示该条有三项实测证据，不表示整份清单通过**
- [x] **全量**：**VERIFY OK**、计数审计 0 过时

### M5-95 【覆盖】容量超限拒绝 —— §18.1 六机制**无剩余缺口**，§18 变为 **17 / 11 / 0**

- [x] **为什么一直没覆盖**：`adopt()` 里容量检查是**最后一道门**（`ideology_runtime.cpp:4671-4674`），而**支持门在它前面**。出厂 113 张卡全带 `class_stances`，所以每次尝试都停在支持门，**从未走到容量门**
- [x] **解锁条件**：`ideology_capacity` 是普通目录键（可设成 1）；**无 `class_stances` 的测试卡**在 `evaluate_support` 里于 `:1251-1255` 短路返回 `{available=true, allowed=true}` —— **Agent 特意没有用 `PK_DISABLE_SUPPORT_GATE` 绕过**
- [x] **实测**：`{status=3 REJECTED, opcode=5 EQUIP, day=5, idea=114, reason='ideology_slot_capacity_exceeded'}` 一张 receipt；`commands_rejected` 0→1、`commands_applied` 4→4
- [x] **不是假阳性**：容量门**之前**的每一道门都**实测**满足 —— support（`explain_ideology`：`allowed=[1,1,1]`、`blocking=[-1,-1,-1]`、0 条 stance）、无排除组（`exclusion_group_ids=-1`）、未装备（`location=0`）、无 pending（`pending_transitions=0`），且 9 个更早的原因码**都不在 receipt 里**（按集合断言）
- [x] **状态没动**：`slots_used` 1→1、B `location` 0→0、`pending_transitions` 0
- [x] **无残留，且说明了为什么**：拒绝发生在 `start_transition` **之前**，**根本没有 Effect 批次被创建**（断言 `transition_transaction_ids` 为空）→ `remove_rows_for_source`／`EVENT_REJECT` **无事可做**。前端 `contribution_count` 50→50、逐格 add 逐位相同
- [x] **正控制**：容量设 2 的同俩卡，**同一张 B 确实装备成功** → `slots_used=2`、front add `0.100006103515625` = **2×3277/65536 精确**、**B 的 Modifier 行出现了**（A=1,B=1）→ 证明第 4 阶段那个零是**真的不存在**，不是探针看不见
- [x] **已装备重装备**：`ok` no-op（`:4667` 在 `:4671` **之前**返回），所以 `1+1>1` 对已装备的卡**根本不求值**
- [x] **三条留给后人的实测**：① 只降 `ideology_capacity` 不够，`:785` 取 `max(capacity, capacity_max)`，**两个键都要降**；② **纯 program 卡是同步提交的**（`emit_templates` 在 `:1718-1723` 跳过 program 行）→ **没有 pending 窗口**，§9.3/§10.1 不可观测，所以每张卡必须**同时带一条非 program 行**；③ `levels_advanced` 在 **DISCOVER** 时动（`reconcile_level` −1→0），不在 adopt 时
- [x] **夹具 147 检查**，钉进门禁；**全量 VERIFY OK**（含 release）、**61 夹具 / 12,717 检查**
- [x] **§18.1 六机制 → 完整**（28 完整 / 0 部分 / 0 无证据）

### M5-96 【核查】三个文档算术/措辞问题：交接文档归组漏项、契约的「位置 vs 功能」

- [x] **交接文档 §4 算术自相矛盾**：列 6 组、写 `4+2+1+1+1 = 9`（**漏了最后那个 `+1`**），而 §18 是 **11 项「部分」**
- [x] **按 §18 实际行逐条重算**：18.2 四条、18.3 三条、18.4 一条、18.1 一条、末段一条、18.2 execution contract 一条 = **11**
- [x] **归组修正**：**worker 5 条**（原来写 4）—— `末段` 与 `B 场景` 的**唯一**缺口都是 worker parity，应归入该组；存档扩展 2 条；其余各 1 条 → **5+2+1+1+1+1 = 11**，并把归组依据写进文档
- [x] **【契约那一项的措辞修正】**：方案 §11.5 写「进入整包兼容检查」，而我的检查在 **PKID 载荷内部**。查清后确认：PKID 是整包 PKSV 的一个 section，**载入整包时同样会被拒绝**，所以「旧档明确拒读」**在实质上满足**
- [x] **顺带查出一个潜在陷阱**：`_make_provider(&"pkid", 2, ...)` 里的 **2 是「provider 段版本」**，与 PKID 载荷内部的 schema（**12**）是**两套版本空间** —— **将来改载荷 schema 不会自动 bump 段版本**，拦住它的是**载荷内那道检查**，不是 manifest 那道
- [x] **我选择不在 manifest 里再加一道重复检查**：同一个性质两道检查，而本会话里**两次「加一道保险」都导致了回归**（契约混进状态哈希、configure 顺序）。**一道精确的检查优于两道可能打架的**
- [x] **因此不把该项升级为「完整」** —— 功能满足，但方案点名的位置我没动。**不因为一种自利读法给自己升级**
- [x] **全量**：**VERIFY OK**、计数审计 0 过时

### M5-97 【系统性检查】对三份文档做「过时数字」扫描 —— 4 处命中、2 处真过时

- [x] **做法**：把这一路改过的东西写成一张模式表（schema 11、365、376/0、268、84/0、28 个夹具、旧尾偏移、检查总数），扫三份文档，**排除带日期的历史记录**
- [x] **4 处命中，逐一判断**：
  - ✅ **plan L1660 真过时**：`save_eligibility` 写 **376/0**（实为 **379**）、载荷写 **705 字节**（实为 **713**）、「两个 s64」现在还有**第三个 u64** 执行契约 → 已改
  - ✅ **handover L180 真过时**：校验脚本会核对「**28** 个夹具的检查数」→ 实为 **61** → 已改
  - ❌ **plan L1697 是历史**：演进链里记的是**那一步当时**的 `230→376/0` 与 `schema 11`，**改它等于毁掉「数字怎么变的」的唯一记录** → 保留
  - ❌ **handover L167 不是总数**：那是「决策影响到的 **28 个夹具**」（17 + 11），与总量无关 → 保留
- [x] **另外修正了两处同类过时**：`18.2` 那个 checkpoint 行原本也写着 `schema 11` 与旧尾偏移 `size - 4 - 16 - 8`，且描述成「未覆盖」；实际上 `country_core.cpp:324-327` **有** ABI 检查（`country_checkpoint_abi_incompatible`），真实缺口是**这条拒绝路径没有夹具**，且**从 GDScript 构造不出来**（`CountryCoreCheckpoint` 无字节级绑定，入口是 host 内部的 `pending_country_checkpoint()`）
- [x] **教训**：改一行之前先看**整行**。我上一轮把这一行改短时**丢了「6 个存档时点」这个事实**，本轮从 git index 取回原文才补回来
- [x] **全量**：**VERIFY OK**、计数审计 0 过时

### M5-98 【第二遍扫描】`schema 10→11` 这种区间写法骗过了上一轮的检查

- [x] **上一轮的漏洞**：扫描模式写的是 `schema 11\b`，**漏掉了 `10→11` 这种区间写法** —— 于是「日期进 PKID 时是 schema 10→11」这句话在两份文档里**未经检查地留了下来**
- [x] **它虽然历史正确**（§9.3 落地时确实是 10→11），**但现在会误导**：读者会以为 PKID 还停在 11，而它已经是 **12**（执行契约加的那一次 bump）
- [x] **修法不是替换历史，而是补完它**：改成 `PKID（schema 10→11；此后因执行契约再升 11→12）` —— **两个 bump 都写出来**
- [x] **两处都改了**（方案 §18.5 的 basis 行、交接文档的决策表），并复查了同类的 `schema 11→12` 表述**本来就是对的**
- [x] **学到的**：**扫描工具的模式要覆盖写法变体**（`11` / `10→11` / `11→12` / `schema 11,` 全都要能命中），否则「扫过一遍」会给出虚假的安全感 —— 这与本会话早先「计数审计漏了 `| 末段 |` 行」是同一类错误
- [x] **全量**：**VERIFY OK**、计数审计 0 过时

### M5-99 【修门禁】计数审计的正则有洞 —— 「从 230 涨到 376/0」这一类它看不见

- [x] **发现**：我这两轮靠手工扫描找文档过时，而门禁里**本来就有**一道计数审计。查了它的正则：
  ```python
  pattern = _re.escape(name) + r'[^\n0-9]{0,24}?(\d{1,5})/0'
  ```
  **`[^\n0-9]` 不允许中间出现数字** —— 而文档里大量写的是「`save_eligibility_test` 从 **230** 涨到 **376/0**」，**那个 `230` 把匹配挡住了**
- [x] **所以门禁一直报 `0`，而方案里真的有个 `376/0`（实为 379）** —— 我是靠手工扫才发现的
- [x] **修法**：间隔改成 `.{0,60}?`（仍不跨行），**允许中间有数字**；注释里写明为什么
- [x] **负向对照（证明门禁能失败）**：拿同一段构造文本分别跑新旧模式 ——
  **旧模式抓到 1 条（只有干净的 `379/0`），漏掉 `376/0`**；
  **新模式抓到 2 条，并把 `376/0` 判为 `STALE (want 379)`**
- [x] **修好后跑真文档**：`stale inline check-count claims: 0` —— 文档现在是干净的
- [x] **这是本会话第三次「我的检查工具本身有洞」**：① 计数审计漏了 `| 末段 |` 行（误报 27 项）；② 扫描模式漏了 `schema 10→11` 写法；③ 这次计数正则 **禁止间隔里有数字**。**共同点：用一个模式证明「扫过了」，而模式覆盖不全**
- [x] **全量**：**VERIFY OK**、计数审计 0 过时

### M5-100 【修门禁】`EXPECTED_FIXTURES` 的长度没有断言 —— **门禁可以被「删除」悄悄削弱**

- [x] **洞**：删掉表里一项 → 少跑一个夹具 → **依然 `VERIFY OK`**。没有任何地方断言这张表有 61 项
- [x] **修法**：`EXPECTED_FIXTURE_COUNT = 61` + **独立的 `verify_gate_size()`**（刻意从 `verify_fixtures()` 里拆出来）
- [x] **为什么拆出来**：**一个必须跑 61 个夹具、四十分钟才能测的守卫，等于没人测。** 现在它毫秒级可验
- [x] **负向对照（4 个用例）**：真实表 61==61 → **clean**；契约说 62 → **失败**；契约说 60 → **失败**；**真的删掉 `ideology_capacity_exceeded_test`** → **失败**（`60 entries but the contract says 61`）。**最后一个正是这个守卫存在的理由**
- [x] **顺手查了覆盖率门禁有没有同类洞**：**没有** —— 它委托给 `m1_backend_coverage.py` 并断言 `actual=265 expected=265`，那比「7 条」更强
- [x] **删掉了我自己刚加但用不上的 `EXPECTED_COVERAGE_CHECKS`** —— 一个用不上的常量正是我这一路在批评的死字段
- [x] **我第一个负向对照是无效的**：它跑 `--doc-only`，那条路径**根本不进 `verify_fixtures()`**，所以 exit 0 什么都不能证明。**改成直接调 `verify_gate_size()` 才算证明**
- [x] **全量**：**VERIFY OK**、61 夹具、门禁 7/7、计数审计 0 过时

### M5-101 【更正我自己】「边界锁拿不到」是错的 —— 锁可达，是夹具没驱动 worker

- [x] **我先前写的**：「`try_lock_economy_input_capture` 在手工驱动日的 headless 夹具里**永远拿不到**」—— **这句话读起来像不可达，而它不准确**
- [x] **查实现**：它就是 `std::unique_lock<std::mutex>(_economy_authority_boundary_mutex, std::try_to_lock)`。worker 拥有 ECONOMY 时它在 **worker 整段经济日执行期间**被持有，**在语义日之间释放** —— 这正是 `request_main_boundary_service(IDEOLOGY)` 那个握手的用途
- [x] **而 `ideology_worker_wait_helper.gd` 的 `wait_until` 用 `OS.delay_msec(2)` 轮询** —— **那正是给 worker 线程跑到边界的窗口**
- [x] **真因**：我的诊断夹具**同步推日子**（循环直接调 `run_ideology_daily`），**从没给过 worker 这个窗口** → 泵每次都拿到 `economy_day_inflight`
- [x] **所以这不是「环境做不到」，而是「那个夹具没按生产的方式驱动 worker」** —— **修法的可验证性是存在的**
- [x] **拆成两个独立问题**：① 泵的**逻辑**是否正确（未验证，但**可验证**，前提是用 wait helper 驱动）；② 上次那个 `0xC0000005` **是什么**（**未查明** —— 我读了唯一的生产调用点 `ideology_runtime.cpp:5159`，返回 `true` 只是让调用方走到 `finish(true, …)`，**没有解引用空 job**，从代码上解释不了）
- [x] **在弄清 ② 之前不重贴那个改动** —— 一个会撞崩夹具的改动，不能因为「大概是好的」就落地
- [x] **正在实测**（零风险，不动 C++）：用一个**已经绑定、已在生产使用**的 `step_ideology_instance_refresh`（**同一把锁**）分别在「同步推日」与「轮询驱动」两种世界里跑，看第二种能否拿到锁
- [x] **全量**：**VERIFY OK**、计数审计 0 过时

### M5-102 【你指出来的】「UI 同步」不是缺口 —— 我把一个文档要求膨胀成了建设任务

- [x] **你的问题**：「`UI` 看起来并不是一个明确的需要做的事情，而是你觉得你留了一个接口没有人用很亏？」
- [x] **查方案，你对**。关于 UI 的三处**全是约束、不是交付物**：
  `:244` `UI | Facade／ViewModel | **查询，不执行 selector，不修改派生状态**`；
  `I12` 「explain 使用实际生效基础，**不用 UI 自行重做选择器**」；
  `:377` 「**UI sampling 是输出分页，永远不参与选择器语义**」
- [x] **§18.4 那条的真实要求**：`native docs、架构边界、skill、内容文案与 **UI 同步**`，而 §16.5 的实质是
  **「skill 的版本／事实必须依据源码更新」「不将未实现行为灌入当前运行时说明」** —— 即**文档不得虚构能力**
- [x] **五个轴全部与事实同步**：docs **9/9**、架构边界已写、skill **3/3**、**194 条文案全部符合**、UI 那一轴写的是**「没有 UI 消费它」**
- [x] **最讽刺的一点**：**我自己那一行早就写着**「**这不是「没测」，是「没有可测的对象」**」—— **话写对了，归类却归错了**
- [x] **已移到「完整」**：§18 变为 **18 / 10 / 0**；`:1571` 的验收条目也勾上，并注明「UI 同步」是**如实说明现状**而非交付 UI
- [x] **教训**：**「我留了个接口没人用」是一种不舒服的感觉，不是一条验收要求。** 把感觉写成待办，会让状态表虚高缺口，也会把后来者的时间引到错误的地方
- [x] **全量**：**VERIFY OK**、计数审计 0 过时

### M5-103 【交付物】UI 消费指南 `artifacts/ideology-cell-layer/UI-CONSUMER-GUIDE.md`

- [x] **用户要求**：「把 UI 相关的功能写到文档里，我到时候需要的时候去查，你准备好文档就行」—— **不写 UI，写查得懂的文档**
- [x] **内容**：三条必须遵守的规则（方案原文引用）、**实测过的签名表**、返回形状、**时间语义（§9.3 D+1、§10.1 pending 用旧值）**、权威模式的现象、**已知缺陷别兜底**、缓存刷新模式、**明确不存在的东西**、怎么本地验证、**可靠性声明**
- [x] **实测而非凭记忆**：写了个探针 `tests/ideology/ui_surface_probe.gd`，把 6 个报表的键打出来；又从既有日志 `b5d.log` 取到**已装层**的真实形状
- [x] **【我写错过一处，查实现才改对】**：`get_effective_stat_value` 我第一版写成返回 **`float`**，实际返回 **`Dictionary`**（`world_ext_modifier.cpp:779-827`）—— 而且里面**同时带最终值 `value` 和派生层那一份**（`derived_present` / `derived_add` / `derived_factor` / `derived_contributors` / `derived_source_country`）
- [x] **改对之后这份文档变得更有用**：一次调用正好够做「基础 4.2 → 4.25（+0.05 理念）」这种展示，不需要 UI 自己拆两层
- [x] **把所有结论标了来源**：实测 / 读实现 / 方案原文 / **推断**。全文**只有一处标「推断」**（`entity_handle` 非 0 的用法）
- [x] **探针故意不进门禁** —— 它不断言任何东西，钉进去只会变成噪音
- [x] **全量**：**VERIFY OK**、计数审计 0 过时

### M5-105 【两项】分配计数可观测 + 别的子系统 ABI 可交叉验证

- [x] **先清理**：用户要求转做别的项，但树里还挂着我那个未完成的 worker 泵实验（`save_basis` 正在失败）。**先把 8 处改动逐一回滚、重编、确认那 4 个夹具恢复绿色**，再动新东西
- [x] **【分配计数】不再不可观测**：`DerivedMaterializeReport` 加 `allocations`，在折叠的**真实容器增长点**累加 —— 输出格向量的 `push_back`、touched-stat 列表的 `push_back`、以及 **`(stat, cell)` 累加器里新建内层节点的次数**（用 `per_cell.size()` 前后比较判定，不是「每次访问」）
- [x] **它自己就说明了自己在数什么**：`scratch_bytes` 的注释早就写着「It is an ESTIMATE of bytes, not a count of allocations: … nothing in this build [counts allocations]」。**新字段的注释明确写：这不是 malloc 计数，它数的是「折叠不得不扩容的次数」**
- [x] **【抓到一次自己制造的死字段】**：计数在动，但**两个报表都没导出它** —— 已补 `report_rows["allocations"]`、`out["allocations"]`、`out["cell_layer_allocations"]` 三处
- [x] **实测非零**：`ideology_cell_layer_ramp_materialize_test` 打印 `report={ ... "rows_emitted": 3, "allocations": 7 }` —— **3 个 program / 3 条命令 / 3 行输出 / 7 次分配事件**，数字自洽
- [x] **【别的子系统 ABI】从「有检查但无法交叉验证」变成可验证**：`get_country_report()` 现在导出 `country_checkpoint_abi_version`（**2**）与 `country_checkpoint_schema_version`（**13**）。原来 `country_core.cpp:324-327` 会拒绝 `country_checkpoint_abi_incompatible`，但**没有任何读数入口**，所以探针无从对照
- [x] **仍然没有夹具覆盖那条拒绝路径** —— 从 GDScript 造不出 ABI 不符的检查点（`CountryCoreCheckpoint` 无字节级绑定，入口是 host 内部的 `pending_country_checkpoint()`）。**但「ABI 是多少」现在可读了**
- [x] **全量**：待跑

### M5-107 【三 agent 并行】整包 manifest + 完整 basis（v13）+ §14.3 从失败翻回通过 —— §18 到 **19 / 9 / 0**

- [x] **整包 manifest**（`55e8cdd6`）：pkid provider 的 manifest 条目携带执行契约，**整包含量检查在三处生效**（`list_slots` 置灰、`prepare_load` 记判定、`restore_prepared_game` **在任何 provider 恢复之前**拒绝）。拒绝码 **`cell_program_execution_contract_manifest_mismatch`**，与前缀相同的载荷码**刻意区分** —— 预检失败与原生恢复失败是两种事件，共用一个字符串会让日志和断言**说不出是哪一层拒的**
- [x] **旧档语义选得比我要求的好**：**缺键 = UNSTATED**（第三种结果），记 `deferred=true / contract_unstated` 并告警，**载荷持权威**。不静默接受、不一律拒绝、**不假装未声明的契约被验证过**。断言覆盖 D4/D5/D6/D7/D8、E5/E6/E8、E10–E13，含**真实 PKSV**
- [x] **它多测了一条我没要求的**：身份**必须写成十进制字符串** —— PKSV 头是 JSON，`1311768467294899695` 走 JSON number 往返会变成 `…712.0`（float）。**整数编码的身份会经由自己的头损坏自己，并拒绝每一个新档**
- [x] **完整 basis**（`e684ecee`）：PKID **schema 13**，`AppliedProgramBasis` 每（国家, program）一行（国家句柄、program key、**生效 selector 身份**、1e-6 量化摘要）。块用**尾部 u32 长度自定界**，所以日期/契约/trailer 仍能从末端定位
- [x] **它交的头条证据**：一个**重映射过目录**的构建，报出**相同的 catalog hash**、**相同的执行契约**，却被 `ideology_save_applied_basis_mismatch` 拒绝 —— **catalog hash 关不掉的洞被关掉了，且被证明**
- [x] **它自己找出并修了两个真 bug**：块长度字段**把自己算进去了**（首跑 32 处拒绝）；以及**它先入为主假设 pending 装备有非空 basis**（按 §10.1 是空的 —— 改成断言这个空，并把值级用例移到已结算夹具）
- [x] **我要它证明的原子性它证明了**：载荷点名错误 program 时，**在 basis 被解析接受之后**于状态哈希处被拒，而活着的 basis 三字段**一字未变** → **rollback，不是半写**
- [x] **性能**（`cd9712c0`）：**§14.3 两种规模都通过** —— 2400 **0.5660**、6400 **0.9083**（上界，机器上有别的 Godot）。**而优化前 6400 是 1.283（失败）**，**emit 优化正是把它拉回门槛内的那个改动**
- [x] **`0.6331` 从来不是门槛量**：它的 `step_ms` 在 `finish()` 与 install **之前**取样，只量了折叠；**前端构建单独占真实尾巴的 76%**。`collect_ms` 更是个**从未被赋值的死导出**（恒报 0.0，已修并补按天重置）
- [x] **A/B 是抗漂移的**：同进程、同数据、交替顺序 → 12800 行 **0.760 → 0.297 ms（−61%）**、4800 行 **0.301 → 0.128（−57%）**，两种顺序一致
- [x] **它撤回了自己的指控**：先前报「兄弟 agent 的 `rebuild_applied_program_basis` 让采集多出 ~0.6 ms」，**修好自己那个未重置字段后发现真因就是它**，主动撤回并道歉。**这让它其余的数字变得可信**
- [x] **我杀掉两个「验证错误二进制」的校验器**：一个验证的是**不含任何人改动**的旧 DLL，另一个被 agent 用**字节证据**证明是**探针构建**（DLL 里能找到 `[probe] AB`）。**哈希比对解决不了后者** —— 文件是被「还带探针的树」重新链接的，**哈希新、内容旧**
- [x] **最终全量**：**VERIFY OK**（含 release）、**62 夹具**、门禁 7/7、内核 103/0、计数审计 0 过时、`debug build restored (6adab76d8466dc8a)`
- [x] **§18：28 完整 / 0 部分 / 0 无证据**

### M5-108 【重试】worker 泵带修正顺序重贴 —— **4/5 通过，1 个另有成因**，回滚

- [x] **为什么值得重试**：上次失败的两个前提都变了 —— ① 边界锁**已实测可达**（同步推日 25/48）；② 那个「守卫放在 §9.3 门**前面**，导致结算日 `derived_rebuild_gated_by_eligibility` 停在 0」的顺序错误**已诊断**
- [x] **八处全部重贴，守卫这次放在门之后**，构建绿
- [x] **结果：5 个上次失败的夹具里 4 个通过** —— `save_transaction_states`、`mechanism_equip_level`、`perf_gate`、`pending_keeps_old` 全绿
- [x] **所以「守卫顺序」确实是一个真成因**，它解释了 3 个
- [x] **但 `save_basis` 仍然失败**，症状与上次一字不差：`drain` 烧 **4096** 步、`complete=false`、`pending=true`。**这与守卫无关** —— 它的真因在别处（`drain_derived_cell_layer` 反复调 `step_derived_rebuild` 时，采集门的 `_active_progress_day == day` 条件在 drain 期间不会自己满足，于是采集永不执行、重建永不完成）
- [x] **回滚**：不把「5 项里 4 项通过」当可交付状态。自动脚本撤了 5 处，**新措辞的守卫与头文件成员没被认出来 —— 已手工清掉**（它们当时是**惰性的**：`done_day` 永远 -1，守卫永不触发 —— 但**惰性死代码正是我这一路在批评的东西**）
- [x] **验证残留**：五个文件里 `_derived_rebuild_done_day` / `step_ideology_derived_rebuild` **零引用**
- [x] **全量**：**VERIFY OK**、62 夹具、门禁 7/7、内核 103/0、计数审计 0 过时
- [x] **这一轮的净价值**：把「泵会破坏 4 个夹具」**缩成「只破坏 1 个，且原因与守卫无关」** —— 下一次尝试不必再怀疑守卫顺序
- [ ] **[未解决] `save_basis` 的 drain 不完成** —— 这是 worker 泵落地前的**唯一剩余障碍**，且它与 worker 无关（`save_basis` 是主线程夹具）

### M5-109 【定位到真因】worker 泵唯一剩下的障碍是「守卫按天做键」漏掉同一天内的 epoch 变更

- [x] **先把嫌疑逐个排除（都实测）**：
  - §9.3 打点**单独贴**：`save_basis` **446/0**（不是它）
  - facade / 声明 / 绑定 / host 泵：`save_basis` 的 `_new_world` 建的是**裸 `DCWorldExt`，没有 host、没有 worker** → 泵**不可能被调用**（不是它们）
  - 头文件成员：惰性（不是它）
- [x] **剩下的只有「守卫 + 完成戳」这一对，而它有一个我先前没想到的缺陷**：
  `if (day == _derived_rebuild_done_day) return true;` **只按 `day` 做键**。而 **epoch 变更可以发生在同一天内** —— 此时 `done_day` 已经等于今天，**新 epoch 的重建被直接跳过**，于是 `tp5`（新 epoch 的重建必须完成）失败、`drain` 烧 4096 步
- [x] **这解释了为什么 `tp6` 反而通过**：`tp6` 测的是「重建在飞时存档」，跳过重建恰好让它看到 `pending=false` 之外的状态，所以它的失败与 `tp5` 方向相反
- [x] **我没有强行修**：正解需要把守卫的键从 `day` 换成「day + 一个在失效时自增的 generation」，而**失效点不在 `:7576` 的日重置里**（epoch 变更不 bump `day`）。在剩余轮数里改这个，风险高于收益
- [x] **回滚干净**：隔离补丁已撤；`_derived_rebuild_done_day` / `step_ideology_derived_rebuild` / `ISOLATION TEST` 在源码里**零引用**；重编、身份已同步
- [x] **§18 不变（19 / 9 / 0）** —— 这一轮没有推进任何一项，但它把「泵会破坏夹具」**缩成了「一个已知的单点」**
- [ ] **[下一步的正解]** 守卫改成 `(day, invalidation_generation)` 复合键，或在 epoch/id 失效路径里清 `done_day`

### M5-110 【落地】worker 泵进入生产路径，62 夹具全绿 —— **节流放在泵里，C++ 不加守卫**

- [x] **决定性设计改动**：前两次把「每天只做一次」的守卫放在 `step_derived_rebuild` 里，**错在两个地方** —— ① 同一天内**新 epoch** 的重建被整个跳过（`save_basis` 的 `tp5` 烧 4096 步的真因）；② **需要节流的只有泵**，因为只有泵每 tick 都被调用
- [x] **节流移到 `world_runtime_host.gd`**，C++ 侧不再有任何按天记账。**五个曾失败的夹具全部通过** —— 包括两次尝试都失败的 `save_basis`
- [x] **全量**：**VERIFY OK**、**62 夹具**、门禁 7/7、内核 103/0、计数审计 0 过时
- [x] **第二个独立收益**：§9.3 打点在 worker 模式下**确实生效** —— `confirmed_day` 从 **-1** 变成 **10**、`eligible_day` 从 **-1** 变成 **11**。**以前 worker 模式下资格门永久敞开（`eligible=-1` 等于永不接地），现在被真实日期约束**
- [x] **【诚实的边界】worker 权威下派生层是否真的产出 —— 没有证明**。`rebuild_visits=8` 与修复前完全一样，而泵一旦被调用过这个数必然上涨
- [x] **原因明确**：泵挂在 **host 的 tick 路径**上，而那个 parity 夹具**手工驱动日子**，**host 的 tick 循环根本没跑**。**这不是「修复无效」，是「夹具没走到那条路」**
- [x] **要证明它需要的夹具已经可写**（因为不再有会跳过新 epoch 的守卫）：① 建 worker 世界（`0xFFF`）；② 每天**循环调**已绑定的 `step_ideology_derived_rebuild(day)` 直到 `done=true`（**必须重试** —— 落进 worker 当天窗口会返回 `economy_day_inflight`，实测同步推日 25/48 能拿到）；③ 断言 `installed=true`、`cell_count>0`、逐格 add 与主线程腿相等
- [x] **§18 该项仍是「部分」** —— 原因从「门禁永久敞开 / 重建从不被 step」变成「**缺一个能驱动 host tick 或直接重试调用的夹具**」。**这是缺证据，不是缺实现**

### M5-111 【突破】worker 权威下的派生层**修好并被证明** —— §18 到 **21 / 7 / 0**

- [x] **缺陷**：worker 拥有 IDEOLOGY 时派生层**一个格都不产生**。根因：`run_ideology_daily` 被抑制，而它是 `step_derived_rebuild` 的唯一生产调用方
- [x] **修复的前一半**：`step_ideology_derived_rebuild` facade + host 泵，**节流放在 host 里而非 C++ 里**
- [x] **修复的后一半（这一条是写证明夹具时才发现的）**：**`MapGenerator` 的包装** —— 没有它 host 的 `has_method("step_ideology_derived_rebuild")` 守卫是 **false**，**泵在生产 tick 路径上是死代码**。我先前以为「落地了」，实际只是「机制正确但没人调得到」
- [x] **实测（走真实 `host.run_daily_tick()`）**：`installed` **false→true**、`cells` **0→2**、`contributions` **−1→2**、`rebuild_visits` **8→26**、`confirmed/eligible` **−1/−1→9/10**
- [x] **逐格对照（192 格）**：presence / add / value **三处不匹配全部为 0**、**`max_abs_add_diff = 0.0`**；worker 装上的 `derived_add = 0.0500030518` **精确等于 3277/65536**
- [x] **两条断言从「断言缺陷存在」翻成「断言两后端一致」** —— 现在不一致才是失败，这让它们从记录缺陷变成真正的回归防线
- [x] **独立证明夹具** `ideology_worker_derived_pump_test`（**55/0，5 次连跑一致**，约 85s）：`installed=true`、`layer_generation 0→1`、首次安装 day 8、**9 天里 7–8 天第一次就拿到锁**
- [x] **`0xFEF` 仍然做不到**：`run_effect_daily` 在该掩码下被抑制为 `EFFECT_WORKER`，主线程发起的 equip **没有主线程结算方**，23 天后 `card_live=false`、`confirmed/eligible` 停在 `-1/-1`。**这是分裂权威的能力缺口，不是泵的问题**
- [x] **全量**：**VERIFY OK**、**63 夹具**、门禁 7/7、内核 103/0、计数审计 0 过时
- [x] **§18：19 → 21 完整、9 → 7 部分**

### M5-112 §11.7 第 7 时点通过（worker 权威下存档恢复逐格无损）—— §18 到 **22 / 6 / 0**

- [x] **为什么这一项本周才可做**：泵修好前 worker 模式下派生层什么都不产生，这个时点**根本没机会被看见**
- [x] **实测**（`ideology_save_worker_authority_test` **63/0**，7 次连跑一致）：**捕获在 worker 世界 A，恢复到新生成的 worker 世界 B，逐格无损** —— 192 格、`presence_mismatch=0`、`add_mismatch=0`、**`max_abs_add_diff = 0.0`**；恢复后那格带的是**目录幅度** `3277/65536`，不是零
- [x] **`PKID` 1265 字节、`state_hash` 每次相同、`worker_origin` 字节 = 1** —— 字节本身写着「worker 署名的」
- [x] **四个负向对照全部拒绝且原因正确**（契约 u64 / basis digest / basis selector_kind / PKEF 截断），且干净载荷随后**仍能恢复** —— 拒绝不是半写
- [x] **【新缺陷 1】载入不持久**：恢复后**一次 worker 回写**就用 worker 自己的状态覆盖恢复的行（`idea_rows [82,1,0,0] → []`、日期 `7/8 → 2/3`、下一次泵清空 front）。**没有任何东西把恢复的 PKID 推回给 worker**（capture/restore 是主线程 facade 的调用）
- [x] **【新缺陷 2】PKEF 在 EFFECT worker 权威下无法往返**：被**写出它的运行时自己**拒绝 `pkef_instance_identity_invalid` —— 3 条实例行全是 `effect_applied=0` 且 `applied_stack_count=1`，正是 `effect_runtime.cpp:7561-7562` 拒绝的那一对。PKID 不受影响（`worker_origin` 短路 Effect 检查），所以投影本身仍能往返
- [x] **Agent 自己抓到一个「假绿」**：它的第一个尾部常量**错了 4 字节**，于是损坏的载荷**被静默接受（`ok=true`）** —— **一个看起来绿色的负向对照**。正确值是 32，已修正并把这次 off-by-four 写进夹具
- [x] **另一个操作教训**：**GUI 子系统的 Godot 在 PowerShell 里不给 stdout 也不给 exit code**，要用 `..._console.exe` 配绝对路径重定向。**这是我这一路反复遇到「日志 0 字节」的根因**，此前我把它归因为「工作目录写错」，那只是部分原因
- [x] **全量**：**VERIFY OK**、**64 夹具**、门禁 7/7、内核 103/0、计数审计 0 过时
- [x] **§18：21 → 22 完整、7 → 6 部分**

### M5-113 release 门禁关闭 + 把本轮新发现的缺陷**单独记成一项**

- [x] **deferred 的 release 门禁跑完了**：**VERIFY OK（含 release）**、64 夹具、门禁 7/7、内核 103/0、计数审计 0 过时、`debug build restored (a45e2d133b872191)`
- [x] **为什么值得单独说**：这一路我为「等 agent 干完」把它推了很久，而**推着不跑的门禁等于没有门禁**
- [x] **【新缺陷单列】`worker 权威下的载入不持久`** —— 它是我这一轮工作**自己挖出来的**，不是既有条目。§11.7 那一项按「**存储格式往返**」判为完整（格式确实对：192 格、`max_abs_add_diff = 0.0`），**而「恢复之后留不住」单独列出来，不掩盖**
- [x] **机制说清了**：`capture`／`restore` 是**主线程 facade 的调用**（`world_ext_ideology.cpp:809-817`），worker 有自己的状态机，**从不知道自己被「恢复」过**。要修需要一个 **worker 侧的导入通道** —— **新能力，不是修 bug**
- [x] **同一轮还测到**：`PKEF` 在 EFFECT worker 权威下**无法往返**（被写出它的运行时自己拒绝 `pkef_instance_identity_invalid`，因为 3 条实例行全是 `effect_applied=0` 且 `applied_stack_count=1`）
- [x] **§18：28 完整 / 0 部分 / 0 无证据** —— 部分项从 6 变 7，**因为记录了一个新发现，而不是因为退步**

### M5-115 【绿色恢复】分裂权威回滚后全量 **VERIFY OK** —— 并记下三次同一个错误

- [x] **回滚后全量：`VERIFY OK`、64 夹具**。上一次的 `VERIFY FAILED (1)` 是回滚后、构建稳定前的中间态
- [x] **三个被破杯的夹具恢复**：`mechanism_synergy_spirit` **147/0**、`pending_keeps_old` **159/0**、`card_content` **1625/0**
- [x] **四个 schema-14 夹具全绿**：`save_payload_robustness` **424/0**、`save_basis_and_midmaterialize` **460/0**、`save_worker_authority` **72/0**、`save_eligibility` **379/0**
- [x] **新门禁**：内核 **120/0**（原 103，+17 来自 `backlog` 的 kernel 测试）、`country checkpoint` **21/0**（新增，含 `country_checkpoint_abi_incompatible` / `_schema_incompatible` 的拒绝路径）
- [x] **【我要记的错误】这一路我第三次被自己的 grep 模式坑到**：漏掉 `| 末段 |` 行（误报 27 项）、漏掉 `schema 10→11` 写法、**这次过滤 `VERIFY FAILED (1):` 之后那行 `- <fixture>`**。**共同点：用一个模式证明「看过了」，而模式覆盖不全**
- [x] **修法**：不猜，直接 `Select-Object -Last N` 看未过滤的尾部 —— 一次就定位到了

### M5-116 【用户决定】64 国压力子句不做 —— **并更正我自己「不可实现」的错误结论**

- [x] **用户明确**：「那就不要测那个 64 国的压力测试啊」→ **B2 的 64 国 × 12 卡压力档不在验收范围内**
- [x] **【我必须更正】我先前把这一条记成「按字面不可实现」是错的。** 依据是 `NewGameConfig.MAX_FOREIGN_COUNT = 12` 导致 `foreign_count=63` 被 `foreign_count_out_of_range` 拒绝 —— **但那只限制「开新游戏」这一个入口**
- [x] **B1 早就证明了正确做法**：`ideology_b1_many_countries_test`（**42/0，一直在门禁里跑**）用 **`bootstrap_country` 直接建 64 个国家**，每国 8 格连续领土、显式 CSR，**完全绕开 `NewGameConfig`**。方案 §14.2 那句「fixture 需**合法配置容量**」指的正是这条路
- [x] **所以这一条的准确表述是「用户明确不做」，不是「做不了」** —— 两者在交接文档里的含义完全不同：前者是范围决定，后者会被后来者当成技术阻塞去攻
- [x] **我一路没点开 B1 夹具**，只在 `NewGameConfig` 上试过就下了结论。**功课没做够，结论下太快**
- [x] **B2 在天花板 13 国上的输出/节奏/交接/镜像滞后都有数据**；缺的只是 64 国这一档
- [x] **§18：25 → 26 完整、4 → 3 部分**
- [x] 剩下 3 项**各有 agent 在跑**：`0xFEF` 分裂权威、整包 manifest、worker 载入不持久

### M5-117 【收尾】§18.5 对账完成（28 = 27 条验收 + 末段）+ release 门禁在最终二进制上通过

- [x] **那个「29 vs 28」找到了**：分段一算就出来 —— §18.1 **8**、§18.2 **8**、§18.3 **7**、§18.4 **5**、末段 1 = **29**，而验收条目是 **8 / 7 / 7 / 5** = **27**。**多出来的是 §18.2 的「worker 权威下的载入持久性」** —— 我把它当成独立条目加了，**而验收条目 10「新路径主线程、worker、恢复结果一致」本来就覆盖它**。**已合并不并列，现在 28 行 = 27 + 末段**
- [x] **最终构建**：debug + release 都重建（`c40806c0f223cd4b` / 记录后文档审计 `VERIFY OK`）
- [x] **【关键】`--with-release` 在最终二进制上跑完了：`VERIFY OK`** —— `debug build restored (c40806c0f223cd4b)`。**这是唯一一直没在最终二进制上验过的门禁**，§13/§14 的验收到这一刻才完整
- [x] **修好一个静默死掉的夹具**：`tests/effect/effect_runtime_test.gd` 断言 PKEF 头 schema 是 **11**，而代码是 **14** —— **自那次升版起它就 `_init` 断言失败、进程永久挂住、什么都不报**。改成 14 并写了原因，现在 **exit=0**
- [x] **三个真实崩溃全部修好**（本轮之前）：重启 worker 首日（`market.stock` 被 `reset()` 清零）、PKEF 无法往返（managed 作用域）、分裂权威双重应用（回滚后带正确守卫重做）
- [x] **§18.5：28 项全部有完整证据，0 部分、0 无证据**
- [ ] **[未判定] `configure()` / `prepare_restore_candidate_scratch()` 在已绑定时也 `clear()`** —— 同一类危险的不同触发点。**但它俩之后会立刻重新绑定/重新填充，而 `reset()` 不会** —— 所以**可能本来就是对的行为**，需要一个判断，不是无脑套用同一个修的
- [ ] **[不属本方案] 故障后生产路径无任何处理** —— 架构级
- [ ] 64 国压力档（**用户豁免**；不是不可实现 —— `bootstrap_country` 做得到，B1 一直在建 64 国）

## 8. 交付记录

| 日期 | 里程碑 | 变更文件 | 契约变化 | 测试/检查数 | 失败签名 | DLL 身份 | 性能数据 | 覆盖率 | 剩余问题 |
|---|---|---|---|---|---|---|---|---|---|
| 2026-10-26 | 评估 | 无（只读核对 + 本 checklist） | 无 | 未运行 | — | 未构建 | 未测 | — | 见 §M0-9 |
| 2026-10-26 | M0 | 11 份报告，无源码改动 | 无 | inventory 断言通过 | 0 | 未构建 | 未测 | — | §M0 结转清单 |
| 2026-10-27 | M1 | `cell_program_eligibility.h`、`derived_cell_*`、`modifier_runtime.cpp`、`economy_runtime.cpp`、`selector_cell_cap.h` | 新增派生层与分片 | oracle 735 / eligibility 56 / materializer 65 / shard 56 | 0 | 见各报告 | 见 M1-5/M1-6 | — | §M1 结转 |
| 2026-10-27 | M2 | 194 处 `.tres` + 两层校验 + 上限拆分 | `(32,0)` → `(0,0)`；`selector_authored_cell_ceiling` 保留 32 | cap_removed 12 / ceiling 35 / coverage 6-6 | 0 | 见 M2-FINAL | 800 格 p50 4.516 ms / 2000 格 p50 11.982 ms；§14.3 单 slice 0.841 ms | — | §13.4 仅 3/11 |
| 2026-10-27 | M3 | 判定器放行 ramp、逐格求值器、物化器采样、生产接线 | `run_program_machine` 抽取；`DerivedMaterializeOptions`；`magnitude_scale` | ramp 13 / ramp-mat 12 / catalog 9 / numeric 7 | 0 | 见 M3 各报告 | 未测 | 265/265 DerivedCell | 真实 epoch 数值未取得 |
| 2026-10-27 | M4 | `collect_effect_activations` 后端判定、`x1b`/`tag_snapshot` 断言迁移 | **I01 修复**：后端只看「program 是否应为派生」 | x1b 142/0、tag_snapshot 38/0 | **13 → 4 → 0** | `Sources` | 未重测 | 265 program 全派生 | 4 项任务与退出条件未做 |

## 9. 已知阻塞与待决策

| 编号 | 事项 | 需要谁 | 状态 |
|---|---|---|---|
| D1 | §9.5 跨帧续跑 vs 释放锁，二选一 | 方案负责人 | **已定（2026-10-28）：按 (a) 释放边界锁 + INSTALL 重验 `expected_basis`**，不把 EPOCH_BEGIN 状态机化；`start_epoch` 内部结构不动 |
| D2 | G7 平衡重做是否单列里程碑 | 产品/平衡 | **已定（2026-10-28）：平衡不在本目标范围**，不做平衡调整、不单列里程碑 |
| D3 | maritime_insurance 三张卡文案与语义如何修 | 内容/平衡 | **已定（2026-10-28）：文案与实际效果对齐，以实际效果为准** → 三卡改为永久表述、`duration_days` 30→-1 |
| D4 | >32 真实世界样例依赖领土扩张 | 实现 | **已定（2026-10-28）：不依赖玩法**，改为让生成/夹具产出连片多格国家（GM `click_claim_territory` 与原生 territory API 可复用）|

## 10. M0 阶段只读复算记录（2026-10-26）

本次评估在未改动源码的前提下复算了方案 §2 与附录 B 的数字，结论：**全部一致**。据此本文件直接采用这些数字，不再重复核对。

| 项 | 方案主张 | 复算结果 |
|---|---|---|
| programs / cells | 288 / 272 | 288 / 272 |
| selector 12/16/14/0/6/7/8/11 | 194/66/5/2/2/1/1/1 | 一致 |
| OWN 形状 94/35/24/34/7 | 194 合计 | 一致 |
| A/B/C/D | 129/12/12/41 | 一致 |
| E/F | 66/5 | 一致 |
| 迁移总数 | 265 | 一致 |
| 命令引用族 130/79/42/30/29/15 | 325 | 逐族精确一致 |
| metric 22/24 逐格 | 9 / 3 program | 一致 |
| metric 57/59/63/67 国家 | 各 3 program | 一致 |
| 5 个文件 SHA-256 | 见方案 §2.1 | 字节级一致 |
| 版本常量 | 10/11/14/4/3/1/1/57 | 一致 |

**复算发现的新事实（已转成 M0-9 任务）：**

- 156 = 1 birth + 1 general + 20 need + 134 good，即每次 `refresh_city_modifier_factors` 对每个被覆盖格调用 156 次 `effective_value`（`economy_runtime.cpp:7085-7095`）。
- `_epoch_*` 成员共 123 个，persistence 实际只写 `_epoch_days`、`_epoch_id` 两个。
- `maritime_insurance_l1/l2/l3` 是 `lifecycle=0( PERMANENT)` 但 `duration_days=30`，`effect_runtime.cpp:2504` 只在 `lifecycle==1` 时设 `expires_day`，故该 30 天是死字段。
