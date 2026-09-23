# 运行时权威迁移：目标、设计框架、当前状态与任务

2026-09-22 cohort cash 边界停机修复 + 事故取证与复现入口。三件事一起落地，它们是
同一个缺口的三面：

1. **止血**。`prepare_worker_cohort_cash()` 过去把四个拒绝条件合成一个
   `country_worker_cohort_cash_boundary_invalid`，其中 `_country_pod_plan_active`
   只是"Country 当天的 plan 窗口还开着"这一时序状态。窗口开着是 continuation 的正常
   形态（`execute_country_worker_stage` 在 `country_economy_asset_results_pending`
   等出口保留 plan 不 discard，下个 pulse 继续），但 Economy 侧的 fast path 拿到拒绝
   后直接 `return false` → `fail()` → 整个经济运行时进 FATAL。玩家表现为扩张领地或
   研究科技时模拟停摆。现在按类拆开：线程/授权/操作非法仍是
   `country_worker_cohort_cash_boundary_invalid`（契约违反，必须 fatal）；plan 窗口
   返回 `country_economy_asset_country_plan_pending`，归入既有的 asset backpressure
   集合。`LEDGER_APPLY` 与 `STRUCTURAL_COMMIT` 两条游标 drain（StageOps 与 compact
   各一份）遇到该原因时不推进游标、不调用 `fail()`，而是 park 并让同一条命令在下个
   pulse 重放；park 前顺带 `service_country_economy_asset_peer(64)`，保证 Country 的
   终态继续落地，plan 窗口能够关闭。
2. **取证**。`fail()` 现在捕获 `FatalContext`（stage / executed_substage / 命令游标 /
   opcode / target·subject handle / amount / `_d7_operation_gate_mask` /
   Country 权威位），经 `report()` 与 `compact_report()` 以 `fatal_context` 暴露。
   同时新增 `audit_incomplete`：`fail()` 会把 `_epoch_active` 置 false，而
   `population_error/money_error/goods_error` 此前只按 `!_epoch_active` 计算，于是
   半开 epoch 里"已记 mint、未刷 closing"的差值被当成真实守恒失衡上报——day 2744 那次
   `money_error=-639200` 恰好等于当天金银铸币额，就是这么来的。现在只有
   `PublishPhase::VERIFY` 真正重算过 closing 才报这三项，否则一律 0 并给出
   `audit_incomplete_reason`。
3. **复现**。新增 `tests/headless_save_replay.gd` + `tools/runtime/Invoke-SaveReplay.ps1`：
   给一个槽位或任意 `.pksv`，走生产 `GameFlow.begin_load_game` 恢复路径无头续跑 N 天，
   fatal / 单日卡死 / 恢复失败三种结果都落 forensics JSON。`WorldRuntimeHost` 另加
   stall watchdog（权威日停在同一天超过 `stall_watchdog_threshold_msec` 即取证）与
   通用 fatal 落盘（此前只有 `money_conservation_failed` 会落盘，且字段集是钱专用的）。

同日发现的存档/读档阻塞项已于 2026-09-23 修复，见 4.4「存档链路」与
`game-flow-start-save.md`「Save/load under worker authority」。

2026-09-20 所得税停机修复：`commit_fiscal()` 在 Country 财政转账前补齐
“未用补贴 + 实收税款”的国家 escrow 汇总，消除正税结算误报
`country_fiscal_peer_escrow_insufficient`。正式玩家 `PlayerController` 调整全国所得税到
10% 后，`income_tax_player_regression.tscn` 验证 StageOps 持续提交 50 日、实际入库且
人口/货币/商品误差为零。定额所得税另测 50 提交日通过；财政终态通过
`finish_worker_country_asset()` 先提交 Country 并刷新只读余额，再进入 Economy 审计，
且转账与总现金查询均按实际 Country grant 选路。该项是财政回归证据，不替代下文其他迁移验收条件。

2026-09-21 财政 continuation 修复：`FiscalSettlementContinuation` 持久保留当前国家的
RETURN 完成状态。若 RETURN 已收到终态而 COLLECT 在下一 pulse 才完成，续跑直接进入
COLLECT，不会复用旧 request id 重放 RETURN；混合消费补贴与所得税 ACTIVE 场景已连续
提交 50 日并保持 `fatal=false`、三项守恒误差为零。

> **2026-09-19 生产路径核对：尚未完成迁移验收。** 当前玩家路径实际为 StageOps writer，
> 玩家入口已恢复自动 POD_ACTIVE；显式开启的 90 秒 soak 已验证 `owned_state`、切换一次、零 worker fault。
> 两轮 90 秒严格 50 倍速配置分别测得 44.98、36.25 权威日/秒，均未通过 49 日/秒门槛；
> 后一轮使用玩家默认配置，最大提交间隔 1.07 秒，性能尚不稳定。
> 本文下方部分 compact-slice、Events、ECP 状态段落混合历史切片，不能当作当前放行结论。
> 详见 [设计与代码对照审计](authority-design-audit-20260919.md)。

更新时间：2026-09-16（M5/M6 机制已落地；M7 仍受 building 回归与完整证据链阻断）

> 事实校正（2026-09-18）：`implemented_domain_mask()` 现为完整图 `0xFFF`（十二域均有
> POD handler）。INPUT_CAPTURE、GAMEPLAY_EFFECT、VISUAL 的生产 ACTIVE 证据与 M7 顺序
> gate 仍可能阻断整图放行；不得把 partial evidence 写成 full ACTIVE。M6 切换入口已有
> 边界与 fault 拒绝逻辑，长期双 hash/audit soak 仍待完成。

**M0–M3 当前执行状态（2026-09-16）**：M0 尚未关闭；`building_runtime_test.gd` 在当前工作树当前复现为 24 个真实回归失败，不能以迁移代码或测试降级代替修复。M1 已接入 D7 typed transport、全 gate 开启路径、request/sequence/effective-day 以及 Host transaction journal；D7 scoped ACTIVE gate 已通过 4/0，Country peer bridge 通过 106/0；九类 operation 的 continuation/late-ACK 长程验证仍未全部形成绿证据。M2 的 ECP2 capture/restore、resource wire、resume cursor、原子事务回滚和独立 OwnedState SoA (`OSOA` v1) 已落地；focused Economy cadence/POD/parity 测试在 debug/release 均通过，并验证 mid-epoch restore 后继续到 commit。PKEC v52 仍作为明确保留的兼容 decoder/writer，长期 60/730/3650 日 soak、公开 save coordinator 的 ECP2-only 切换与 E10 默认切换仍待后续门禁。M3 的 Events ACTIVE journal/ACK 已与 legacy deque 和 consumer cursor 隔离，poll/replay/save 读取 worker snapshot；GameplayEffect typed worker packet 现在严格解码并在同一 sealed day 生成 Events APPEND_BATCH，Events 失败会阻止 COMMIT。新增 GMP1 transaction section 及 checksum/pending 交叉校验，并保留 native Effect ACK → Events committed snapshot 的端到端 self-test；GAMEPLAY_EFFECT bit 仍等待 M5 的真实 catalog/长期 ACTIVE soak 后才能放行。因而本轮交付是 M1/M2/M3 的可验证代码边界，M0 与 M1/M2/M3 的发布门禁仍未全部关闭。

**M4–M7 当前执行状态（2026-09-18）**：M4 的 input manifest 与 visual refresh 机制已接入 day barrier。M5 的 fail-closed completion gate 已接入；`implemented_domain_mask` 为 `0xFFF`，但 `INPUT_CAPTURE|GAMEPLAY_EFFECT|VISUAL` 的完整 ACTIVE 端到端证据与 M0 回归绿灯仍可能阻断整图放行。M6 的 `switch_economy_authority()` 已实现边界、in-flight、STOPPING/SAVE_PENDING 与 FAULTED 拒绝，并记录 before/after/audit hash、generation、latency；长期 soak 尚未形成发布门禁。M7 脚本已按 PROBE→逐域 parity→`0xFFF` parity→`0xFFF` ACTIVE→PERFORMANCE 顺序 fail-closed 接线，真实 runner 仍待补齐。

**一句话现状**：十二个 domain 均已进入 `implemented_domain_mask = 0xFFF`（含
`INPUT_CAPTURE|CLIMATE|COUNTRY|TRIGGER_INPUT|IDEOLOGY|EFFECT|MODIFIER|GAMEPLAY_EFFECT|ECONOMY|EVENTS|VISUAL|COMMIT`）。
Climate 滞后一日回灌；Economy ACTIVE 经 `worker_run_compact_slice` 推进同一
`NativeEconomyRuntime` 公式 owner。`runtime_climate_authority_enabled` 为真时生产
请求 `authoritative_domain_mask=0xFFF`。关掉该开关则退回 SHADOW。整图 ACTIVE 仍受
evidence/completion gate 约束，放行仍是 **逐域 + M7 顺序**的。

**Events I8 的边界必须读清楚**：EVENTS 的授予只表示 worker 侧 POD store 拥有 EVENTS
stage 位与自己的 snapshot ring，是 committed journal 的**镜像**。legacy
`GameplayEventBus` journal 仍是生产消费源（Trigger ingest、UI、存档都还读它），主线程的
append/ACK 一条都没有抑制。消费者迁移是后续 PR，在那之前不要把 EVENTS 的 grant 位当成
"journal 已经搬到 worker"。

2026-09-10 纠正：仓库内已不存在 `country_worker_command_unsupported`。Country worker 授权下
`submit_country_commands()` 对 opcode 1–20 一律编码进 Host packet，不会按 CREATE/RENAME/税务
提前拒绝。真正缺口从来不是缺 opcode case，而是生产 `run_slice_core()` 的大规模 staged SoA
apply 与 worker snapshot apply 曾是两套公式；现已把 worker apply 收口到 CountryCore，同步
路径在热路径上仍用 staged SoA（100k 格领土批），并以 core apply 做小批量 parity。

2026-09-09 协议切片仍有效：`enqueue_batch()` 整批容量预检与单调 `submit_order`；peer intent
按 typed opcode / target domain 校验。该切片仍不改变正式能力 mask。

同日后续切片已补齐 Country 命令生命周期的终态出口：ACTIVE admission 返回显式
`status=Accepted` / `receipt_code=1`，`poll_country_command_receipts(after_request_id, limit)`
按 request-id 游标返回 `Committed` 或 `RejectedAtExecution`，ACK 等待期间不提前终结。
Host 自测同时覆盖“批内首条已进入 POD pending、后续 packet malformed”的整批拒绝；失败时
按 request id 清除本批 pending，避免已经发布终态的请求被下一边界重放。同步 SUS
`country_daily`、`run_country_slice()` 和 native runtime graph Country stage 也都改为根据实际
granted `authoritative_domain_mask & 0x004` 抑制同步写者。以上协议/门控切片在当时仍挂在
测试授权下；**D12（2026-09-11）** 已把正式 `implemented_domain_mask()` 与生产 request
提升为 `CLIMATE|COUNTRY|COMMIT = 0x806`。Host receipt/request state 的 CPD2/PKSR 恢复安装
仍单独存在，不能与 handoff 测试授权混为一谈。

财政 continuation 追加验证：`NativeEconomyRuntime` 的财政 reserve 已按 Country 拆成可续跑
的 epoch-open barrier。请求计划先冻结为 `requested_by_country`，之后每个 Economy slice
最多处理一个 Country；reserve 未完成时保持 `epoch_begin_post_fiscal_pending`，不执行
research demand、bullion quota 或后续 Economy stage。保存和恢复在此中间态明确拒绝，并返回
cursor/count/day/phase 诊断。`economy_fiscal_reservation_continuation_test.gd` 专项回归为
**failures=0**（断言数含循环，运行时打印 `checks/failures`，不要写死 N）。Host 已有
Country/Economy 内存 transport、`D7T1` transaction journal 编解码/恢复和 Economy-owned
fiscal peer journal；PKEC v52 已持久化 fiscal escrow、terminal request result 与 state hash。
但这只完成 M1 fiscal reservation/return/collect 的 peer 基础，不等于 D7 已经完成：cohort、market、
research、treasury 的跨线程 continuation、reservation reconciliation、逐 operation gate
和长程守恒/恢复证据仍未完成。D7 与 D12 Country ACTIVE 正交。

---

## 如何使用这份文档

本文是这轮迁移的**总纲**：目标、框架、状态、任务四类分开，每类先总后分。它不复述架构细节，
细节在 `docs/cpp-dots-runtime/` 下的专项文档里，本文只负责给出准确的当前状态和指路。

| 你想知道 | 看 |
| --- | --- |
| 为什么做这件事、做到什么算完 | 第一部分 |
| 整体架构长什么样、调度怎么跑、某个模块具体怎么运行 | 第二部分 |
| 完整迁移一共要做哪些事、哪些已经做完了 | 第三部分（工作分解 A–L） |
| 现在到哪一步了、某个域什么状态 | 第四部分（对着第三部分的条目讲） |
| 我要动 worker / 跨边界接线，有哪些坑 | 第五部分（**动手前必读**） |
| 某个符号在哪个文件 | 附录 A |
| 某个开关叫什么、默认值 | 附录 B |

**第三部分与第四部分是配套的**：任务表说"要做什么"，当前状态说"到哪了"，后者的每个结论都能
追到前者的具体条目（如 B8、D7）。

与其他文档的关系：

- `architecture-overview.md` / `gdscript-cpp-data-bridge.md` / `scheduling-and-job-graph.md`：
  讲**架构怎么运作**，不讲迁移进度。本文引用它们。
- `runtime-authority-matrix.md`：按**系统**（climate daily / weather / ocean…）列 owner 与
  blocker，粒度比本文 3.2 的**域**更细。查具体 pass 归属看它。
- `full-authoritative-runtime-status.md`：本文的前身，**已降为历史归档**。它按时间顺序记录了
  迁移过程中每一次调查与反复，前后文互相矛盾是正常的（那是过程记录）。要考古某个决定为什么
  这么定，去那里；要知道现状，看本文。
- 各域专项文档（`native-economy-runtime.md`、`native-country-runtime.md` 等）：讲该域的业务
  实现，与它的 POD 迁移进度是两回事。

---

# 第一部分：目标

## 1.1 为什么做

把 gameplay 模拟从 GDScript/主线程同步 daily 搬到 C++ POD worker，要的是三样东西：

1. **帧延迟**：模拟不再占主线程，长节点不再表现为帧尖峰。这是玩家能直接感知的收益。
2. **吞吐**：50 倍速目标为 **50 个权威模拟日/秒**。
3. **确定性与可存档**：POD state 无 Godot 对象引用，可整份哈希、整份序列化、整份重放。

注意 1 和 2 是**两个不同的收益**，可以只拿到一个。Climate 实测就是这样：主线程 climate job
时间降 49%，但 SUS 总均值不动——CPU 总需求没变，只是换了个线程跑。搬迁只在"主线程是瓶颈"
时改善延迟，只在"有空闲核心"时改善吞吐。

## 1.2 最终边界（成功长什么样）

```text
主线程输入捕获
  → immutable native input snapshot
  → worker-owned POD state
  → 固定顺序 plan/replay
  → typed intent / ACK barrier
  → immutable committed snapshot
  → 主线程视觉和 UI 消费
```

硬约束，逐条可验证：

| 约束 | 怎么验 |
| --- | --- |
| worker 不调用任何 Godot API | 源码扫描（`source scan = 0`） |
| worker 不访问 MapData / 场景树 / renderer / GPU / Godot 对象 | 同上 |
| 主线程不读取 worker store | 代码审查 + 竞态测试 |
| 主线程不等待 simulation / mutex / 任务 / 保存编码 | `main_wait_on_sim_us = 0` |
| 权威模拟不跳过日期 | soak 的 `writeback_days` 连续性 |
| worker 停顿不造成 UI 帧尖峰 | 真实客户端会话帧统计（**目前无法测量，见 4.4 与任务 C1**） |
| 50 权威模拟日/秒 | headless perf record |

三种模式的定位：**OFF** 是同步参考权威（也是 parity 的参照系）；**SHADOW** 是后台对拍权威，
不驱动画面；**ACTIVE** 是生产权威。

## 1.3 明确不做的

- **不追求消灭 Godot 边界对象**。WeatherFront、ImageTexture、RID、MultiMesh、atlas 上传仍在
  主线程，`graph_coverage_state=complete` 不要求消灭它们。它们是"保留边界"，不是 blocker。
- **不追求整图一次性 ACTIVE**。放行按域进行，见 2.2。
- **不追求 1000 日 bit-identical 作为放行硬指标**。理由见 2.5。

---

# 第二部分：设计框架

先讲整体架构和调度怎么跑（2.1–2.2），再讲权威是怎么定义的（2.3–2.4）、每日执行序与数据契约
（2.5–2.6），然后逐个模块讲它具体怎么运行（2.7），最后是放行标准（2.8）。

## 2.1 总体架构

五层，自上而下。**每一层只对下一层负责，跨层直连是缺陷**：

```text
Godot 层        WorldClock / 场景树 / renderer / UI
    │            （day_changed 信号是仿真的唯一心跳）
编排层          MapGenerator.sus_tick_daily / WorldRuntimeHost
    │            （生命周期、bundle 打包、fallback、finalizer、Godot 边界）
调度层          DCSystemScheduler → SusSchedulerExt
    │            （注册、拓扑、预算、跳过、统计；不拥有业务状态）
执行层          DCSystem / SusJob  ←→  C++ pass / native 图 / POD worker
    │            （真正算东西的地方）
数据层          DCWorld（GDScript mirror） / DCWorldExt（C++ SoA slots） / MapData
                 （MapData 是给 GDScript、debug、CSV、baker、renderer 看的可见镜像）
```

三条角色约定，违反了就会出现难查的问题：

- **`SusSchedulerExt` 只调度，不拥有气候/经济业务状态。**
- **`MapGenerator` 负责生命周期与 Godot 边界，不该重新承接全图数学 hot loop。**
- **`ClimateProfile` 及其 `.tres` 决定 feature gate、cadence、budget、物理 knob 与 owner gate。**
  这意味着**同一份代码在不同 profile 下是不同的系统**——见 2.2 末尾的警告。

## 2.2 调度机制

### 2.2.1 两个调度器的分工

| 职责 | 归属 | 证据 |
| --- | --- | --- |
| 注册 system、reads/writes 拓扑、重写 priority | `DCSystemScheduler` | `dc_system_scheduler.gd` 拓扑 rebuild |
| tick 入口、同步 budget 配置 | `DCSystemScheduler` | `tick()` |
| **决定跑不跑**（policy / `should_run` / deadline_critical） | `SusSchedulerExt` | `sus_scheduler_ext.cpp` |
| 决定顺序 | 拓扑定 priority → Ext 内 `stable_sort` | `dc_system_scheduler.gd:357+`；`sus_scheduler_ext.cpp` |
| 管预算（frame gate + 每 job slice 循环） | `SusSchedulerExt` | `sus_scheduler_ext.cpp` |

> **坑**：拓扑 rebuild 后必须刷新 Ext 侧 descriptor，否则 C++ 仍按旧顺序跑
> （`dc_system_scheduler.gd:364-369`）。

### 2.2.2 调度概念的实际语义

这几个词的含义与直觉不完全一致：

| 概念 | 实际语义 |
| --- | --- |
| `frame_budget_ms` | 单 tick 墙钟预算。**只阻止启动新 job / 新 slice，不会中断已经在跑的 native pass**——所以一个长 C++ pass 照样会超预算 |
| `slice_budget_ms` | job 级软预算。一次 visit 内可连跑多个 slice，直到 job 内 elapsed ≥ 该值 |
| `must_run` | 绕过 `frame_budget_exhausted`，**但仍受 policy 与 depends_on 约束**。不是"一定会跑" |
| `depends_on` | 依赖 job 仍 `in_flight` 或本 tick 未完成 → skip，reason=`dep_pending:*` |
| `policy_gated` | 注册的 policy 或 job 自己的 `should_run(ctx)` 返回 false |
| `strict_budget_one_job` | strict 模式下本 tick 已有 optional job 跑过，则跳过后续 optional job |
| `skipped[frame_budget_exhausted]` | tick 已耗尽预算，且该 job 非 must_run / starving / deadline_critical |

**两个不同层的 budget 容易混**：`ClimateProfile.sim_frame_budget_ms`（生产 `earth_like.tres:28`
= 8.0）是 SUS 的每 tick 预算；`WorldClock.sim_frame_budget_ms`（默认 8.0）是**日推进时间盒**，
两者不是一回事。

### 2.2.3 一个 tick 的完整调用链

```text
WorldClock._process
  → _advance_one_sim_day() → day_changed.emit(day)        world_clock.gd（geography）
main.gd::_on_day_changed
  → MapGenerator.sus_tick_daily(clock, day_idx, season_phase)
MapGenerator.sus_tick_daily
  → SusTickContext.make(...) → DCSystemScheduler.tick(ctx)      map_generator.gd:7699+
DCSystemScheduler.tick
  → _sus.tick(ctx)  →  SusSchedulerExt::tick                    dc_system_scheduler.gd:388
SusSchedulerExt::tick
  → 逐 job：budget / policy / dep gate → job.run_slice(ctx) 循环 sus_scheduler_ext.cpp
DCSystem.run_slice → tick(ctx) → C++ pass
```

tick 结束后经 `report_last_tick()` 出报告（Ext 侧写 `_last_report`）。

**跨帧续跑**：遇到硬 barrier 时 `WorldClock` 发 `simulation_backpressure_pulse`，
`MapGenerator._continue_economy_inflight` 调 `DCSystemScheduler.continue_system` 补跑
（`world_clock.gd`；`map_generator.gd:3103+`）。

### 2.2.4 注册了哪些 job

`MapGenerator._setup_sus()`（`:3510+`）。**注册是有条件的**，同一份代码在不同 profile 下注册
出的 job 集合不同：

| job | 注册条件 |
| --- | --- |
| `effect_runtime` / `gameplay_effect` | `configure_effects` 成功 |
| `modifier_daily` / `trigger_daily` / `ideology_runtime` | 对应 facade 已配置 |
| `country_daily` / `economy_daily` | 对应 facade 已配置 |
| `season_refresh` / `ocean_currents` / `natural_resource_daily` / `bio_occupancy_daily` | 无条件 |
| `native_daily_sim` + 视觉上传 job | **`native_daily_sim_mode==ACTIVE` 且 native slice API 就绪**，注册后 early-return |
| `refresh_climate_daily` / `sea_ice_daily` / `weather_refresh` / `enum_atlas_upload` | 上一条不成立时的 legacy 分叉 |

### 2.2.5 native daily 的 slice 续跑

`DCWorldExt::run_native_daily_slice()` 单次调用跑若干节点后返回 `done=false`，cursor 存在
`DCWorldExt` 成员里：图节点游标 `_native_daily_slice_node_index`（`world_ext.h:2868`）、节点内
cell range 游标 `_native_daily_slice_cell_cursor`、round 活跃标志 `_native_daily_slice_active`。

> **坑**：SUS 因预算跳过 native 首 slice 时会设 `_native_daily_day_pending`，靠 pulse 补跑
> （`map_generator.gd` 的 `sus_tick_daily` 路径）。所以"这一天 native 没跑"未必是缺陷，可能只是被推迟了。

### ⚠ 2.2.6 脚本默认值 ≠ 生产配置

`ClimateProfile` 里的 `@export` 默认值**几乎全是 false / OFF**，生产靠 `earth_like.tres` 覆盖。
最容易踩的是 `native_daily_sim_mode`：脚本默认 `OFF(0)`，而生产 `earth_like.tres:9` = `2
(ACTIVE)`，且 `native_daily_legacy_daily_production_retired = true`（`:27`）。

**只看 `climate_profile.gd` 会得出"生产气候走 legacy `ClimateDailySystem`"的结论，那是错的。**
（写这份文档时的一次独立调查就是这么栽的。）任何不加载 `earth_like.tres` 的 fixture 拿到的
是一套完全不同的系统——这解释过好几次"测试里复现不出来"。完整覆盖清单见附录 B.2。

## 2.3 权威模型：不要用单一 "native=true" 概括

判断"某个东西是不是 DOTS 权威"要拆成七个维度分别回答。这是全套判断的基础，3.2 逐域状态也
按它组织。

| 维度 | 问题 |
| --- | --- |
| Formula authority | 哪个实现决定数值公式？其他实现是否只是 SAME_SOURCE fallback？ |
| Slot authority | 哪个 pass 写 C++ slot？slot 是否是 schema 单一字段？ |
| Stage authority | 谁持有 round active、cursor、phase lock、reset/abort？ |
| Tick authority | 谁决定本日执行哪些节点、何时提交？ |
| Visible authority | MapData、CSV、renderer 是否看到同一提交态？ |
| Object authority | WeatherFront、ImageTexture、RID、MultiMesh 由谁管理？ |
| Worker authority | 是否由 POD worker 在后台线程算、经回灌进 MapData？主线程写者是否已被抑制？ |

只有 native 同时拥有 state、slot、tick/cursor、graph report 和发布契约时，才称
DOTS-authoritative。`published_to_slot=true` 只证明该 pass 的 slot publish，**不证明**
front/LUT/GPU 可见。

Worker 权威下还要多问两层，这两层各让 Climate 栽过一次：

- **这个场有回灌写者吗？** worker 算了但没有 store 成员、也没进 writeback 的场，MapData 会
  停在世界生成值且不报错。表现是"字段冻结"，不是数值分叉。
- **主线程还有第二个写者吗？** 抑制门漏掉的写者会和回灌打架，表现为单 tick 跳变。

## 2.4 域模型与三个 mask

`RuntimeDomainId` 共 **12 个域**（`runtime_pod_protocol.h:358`），`RUNTIME_ALL_DOMAIN_MASK = 0xFFF`：

| 域 | 值 | bit | 域 | 值 | bit |
| --- | ---: | ---: | --- | ---: | ---: |
| INPUT_CAPTURE | 1 | 0x001 | GAMEPLAY_EFFECT | 8 | 0x080 |
| CLIMATE | 2 | 0x002 | ECONOMY | 9 | 0x100 |
| COUNTRY | 3 | 0x004 | EVENTS | 10 | 0x200 |
| TRIGGER_INPUT | 4 | 0x008 | VISUAL | 11 | 0x400 |
| IDEOLOGY | 5 | 0x010 | COMMIT | 12 | 0x800 |
| EFFECT | 6 | 0x020 | | | |
| MODIFIER | 7 | 0x040 | | | |

**三个 mask 是不同的东西，混淆过一次就会误判现状**：

| mask | 在哪 | 语义 | 当前值 |
| --- | --- | --- | --- |
| `implemented_domain_mask()` | **编译期 constexpr**（`native_simulation_host.h`） | 该域**有真实 POD handler**，不代表它是权威 | 十二域完整图 `0xFFF`（含 `INPUT_CAPTURE`/`GAMEPLAY_EFFECT`/`VISUAL`/`ECONOMY`） |
| `authoritative_domain_mask` | 启动配置键，由 GDScript 传入（`world_runtime_host.gd`） | 本次会话**实际要 worker 承担权威**的域 | 生产 request `0xFFF`（按域可缩小） |
| `completed_domain_mask` | 每日报告 | 当天实际跑完的域 | ACTIVE 下按请求域完成；输入未就绪日按域走 soft-complete |

准入逻辑（`native_simulation_host.cpp` 的 `start()` / ACTIVE 分支）：ACTIVE 要求
`authoritative_domain_mask & ~implemented_domain_mask() == 0` 且 `graph_coverage_complete`。
**整图 ACTIVE**（request `0xFFF`）在实现掩码上已可启动；仍须通过 completion/evidence gate
与 M7 顺序证据，不得把 partial `active_evidence_mask` 写成 full ACTIVE。

这三者的区别就写在 `implemented_domain_mask()` 的注释里（2026-09-08 重写；此前它说
"Climate POD handler is live in SHADOW，ACTIVE 还需要剩下十个 gameplay domain"，那是
per-domain 放行之前的语义）。

**放行是逐域的**——一个域通过就加一个 bit，其余不受影响。这是这轮迁移最重要的结构决定，它把
"十二个域全部就绪才能开 ACTIVE"的死锁拆开了。

代价是要维护混合状态，最麻烦的是**跨域读取**：主线程的域读 Climate 字段时，读到的是滞后一日
的回灌值。目前 Climate 的下游（经济的 plant water / temp30d）走 slot 冻结输入，本来就不要求
当日值，所以没暴露问题。**后续每个域放行前必须逐个确认这一点。**

## 2.5 每日执行序：两条路径

**主线程路径**（Climate 之外的全部域）：

```text
WorldClock._process() → day_changed
  → WorldRuntimeHost.run_daily_tick()
  → 同步 SUS / native daily graph
  → MapData / 视觉状态修改
```

**Worker 路径**（Climate 与 Country 已进入生产 ACTIVE）：

```text
WorldClock._process() → day_changed
  → apply_runtime_climate_writeback(day N 的 worker 结果 → MapData)
  → season refresh
  → capture_runtime_inputs(day N+1 的输入)
  → 主线程该域节点被抑制门跳过
  → worker 后台算 day N+1，明天回灌
```

两条语义差异，后续每个域放行时都会再遇到一次：

- **滞后一日**：玩家在 day N+1 看到 worker 算的 day N。
- **顺序钉死**：回灌必须在主线程的同域改写（如 season refresh）之前。反过来的话，主线程那次
  写入会被次日回灌整体覆盖，且没有任何报错。

## 2.6 数据契约

四条通路，各有各的失效方式：

| 通路 | 载体 | 主要风险 |
| --- | --- | --- |
| 主线程 → worker（每日） | environment 快照 + scalars + stage knobs + static knobs | **缺失是静默的**：缺 lane 被填成等长全零，缺 knob 落到结构默认值 |
| worker → 主线程（次日） | store 字段 + snapshot 独立字段 | 没有回灌写者的场会冻结在旧值 |
| 存档 | 每域一个 section（Climate 是 CLM2，Country 是 CPD2） | 加字段进 store 会动存档格式 |
| parity | 两侧共用 `parity_hash()`，按 canonical 字段表逐字段比 | 字段表与实际 store 不同步时，比较的是子集 |

两条通用规则：

- **store 内 / store 外要分清**。需要跨天累积、需要存档的进 store；只是要让 MapData 看见的
  走 snapshot 独立字段（Climate 的 `soil_moisture` 和 pass_a 五条输出就是这么处理的），这样
  不动存档格式。
- **枚举跨边界必须给字符串**。Godot 4 的 `String()` 构造函数不接受 int，给序号会在 GDScript
  侧抛构造错误并打断整个字段收集，表现成 parity 全 0 而不是某字段分叉。

## 2.7 各模块具体怎么跑

前面讲的是共性框架。三个主要模块的运行方式差别很大，**它们不是同一套机制的三个实例**。

### 2.7.1 Climate

**生产形态**（`earth_like.tres`：`native_daily_sim_mode=2`、`stride=10`、legacy 已退役）：

```text
SUS job `native_daily_sim`
  → MapGenerator.run_native_daily_slice_from_job
  → DCWorldExt::run_native_daily_slice(tick_knobs)     跨帧续跑，cursor 在 DCWorldExt
  → NATIVE_DAILY_SLICE_GRAPH（21 节点，含 weather 拆分）
```

两张图不要混：**slice 路径走 21 节点的 `NATIVE_DAILY_SLICE_GRAPH`**
（`world_ext_daily_sim.cpp:65+`）；一次性全量 tick 走 15 节点的 `SCHEDULE_GRAPH`
（`system_schedule.cpp:308+`）。后者是节点顺序的权威定义，`native_daily_graph_order_test`
校验的就是它。

15 节点顺序及其理由：

```text
1 climate_pass_a   2 climate_pass_b   3 ocean_water   4 ocean_land
5 wind_air         6 wind_surface     7 sea_ice       8 transpiration
9 albedo          10 vegetation_dynamics  11 climate_feedback
12 stage_b        13 weather         14 runtime_hydrology  15 stage_b_after_hydrology
```

- pass_b 读 round-start TTA，**必须在当天 ocean 更新之前**，否则当天新 TTA 立刻反馈进当天湿度。
- `wind_surface` 汇总 baseline/ocean/air/local anomaly 后发布 `cell_temp`。
- sea ice 必须读 wind-surface 之后的有效温度。
- hydrology 读当天有效 precip，且要在 stage_b 读 soil/WB30 之前完成；开启时用
  `stage_b_after_hydrology`，不能同时跑普通 `stage_b`。

**`season_refresh` 不在这两张图里**——它是独立 SUS job（priority 50），按 `period_ticks` 自驱
的慢变量轮（`season_refresh_system.gd`）。这是 Climate worker 化时最大的一个坑：它是
主线程写者，且必须排在回灌之后。

**Worker ACTIVE 形态**：`climate_worker_authoritative()` 为真时，主线程**整张**
`NATIVE_DAILY_SLICE_GRAPH` / `SCHEDULE_GRAPH` 被跳过（不是逐节点门控；见
`world_ext_daily_sim.cpp` / `system_schedule.cpp` 的 `climate_authority_suppressed`），由 POD
worker 跑同一份共享纯内核，执行序见 2.5。worker 侧 round 内八个 pass + 五个 `stage_knobs`
stage，hydrology 两侧都不跑。

### 2.7.2 Economy

**与 Climate 完全不同的机制**：Economy 有自己的内部状态机 `ECONOMY_GRAPH`
（`economy_runtime_diagnostics.cpp` 报告 `path=ECONOMY_GRAPH`），**独立于** SUS 图和 native daily 图。

驱动路径有两条，生产走第二条：

```text
① SUS job `economy_daily`  —— runtime_graph_active() 时 should_run 直接返回 false
② DCWorldExt::advance_runtime_pulse → run_economy_slice_compact   ← 生产路径
   （native_runtime_graph_mode=ACTIVE，earth_like.tres:10）
```

**冻结 epoch 是它的核心机制**：`start_epoch(day)` 冻结当日 environment/building 上下文，并
`capture_country_epoch` 复制 country 的领土/科技/税表/国库快照。目的是在整个周期内隔离 live
country。**新 cycle 必须等 country 当日命令已 commit**——`country_runtime->should_run(day)` 为
真时 economy 不启动新 cycle（`economy_runtime.cpp:7860+`）。

冻结周期内的 stage 主序（`run_slice_internal`，`economy_runtime.cpp:9672+`）：

```text
BUILDING_PLAN → TRADE_SETTLE → LEDGER_APPLY
→ BUILDING_EMPLOYMENT → BUILDING_PRODUCTION → HOUSEHOLD_MARKET
→ GOVERNMENT_RESEARCH_PROCUREMENT → TRADE_DISPATCH → STRUCTURAL_COMMIT
→ BUILDING_COMMIT → FAMILY_COMMIT → PERSON_COMMIT → AGGREGATE_PUBLISH
```

2026-09-22：StageOps 的 `GOVERNMENT_RESEARCH_PROCUREMENT` drain 已修正为在返回
stage result 前完成已封存的 research-purchase continuation。compact-slice 可以在事务阶段
之间让出，但 StageOps 不能把这个正常 continuation 误报为
`government_research_peer_pending` fatal；否则会在下一 sample day 前把 Economy epoch
永久停在 `fatal`。

**它自己的 worker 不是 POD worker**：`economy_profile.worker_enabled`（默认 true）开启的是
`NativeParallelExecutor` + `parallel_for_range` 的按 cell 分 task 并行
（`parallel_dispatcher.h:64+`），与 `NativeSimulationHost` 的 POD worker 是两个东西。这一点
直接影响 E1 的决策：**Economy 已经是并行的了**，搬进 POD worker 的增量收益需要单独论证。

**守恒审计**在 `aggregate_publish` 的 `PublishPhase::VERIFY`
（`economy_runtime_publish.cpp:322+`）。失败 → `_fatal=true`、`_stage=FATAL`，GDScript 侧
`EconomyDailySystem` 收到 `fatal` 后清 barrier 并 **`world_clock.pause(true)`**
（`economy_daily_system.gd`）。生产路径的审计字段是 `population_error` /
`money_error` / `goods_error`，**不是** `ledger_failures`（后者只在 POD 诊断适配层里）。

### 2.7.3 Country

驱动路径与 Economy 同构：SUS job `country_daily` 在 `runtime_graph_active()` 时不跑，生产由
`advance_runtime_pulse` 驱动（`country_daily_system.gd`；`world_ext_runtime_graph.cpp`）。
当 `runtime_climate_authority_enabled=true` 且 Country grant 成功时，生产写者是
`NativeSimulationHost` worker；主线程只消费 immutable Country read-view。关闭开关、启动失败
或未获得 `authoritative_domain_mask & 0x004` 时，才回退同步 `NativeCountryRuntime`。
`RuntimeCountryPodAuthority` 是 worker 的 Host adapter/read-view 组件，不是第二套同步生产权威。

**命令屏障**是它区别于其他模块的地方：

```text
命令入队 _pending_commands
  → slice 开头：无 active batch 时 open_implicit_boundary + begin_reference_boundary
  → 按 seal watermark 过滤出 admitted_and_due，装入 _command_batch
  → 批内 preflight + apply
  → peer ACK 未完成 → NeedPeerResults / country_day_barrier
  → GDScript 侧 world_clock.request_simulation_backpressure
```

（`country_runtime.cpp`；`country_daily_system.gd`）

K2-A 已把研究完成路径拆成 `CountryPeerContext → typed intent → typed result → 同日
continuation`，并接通真实 `Effect -> Modifier -> gameplay publication -> Country` ACK 链；已验证
request/session/generation、重复 ACK 幂等、拒绝重试和保存 barrier。`runtime_country_peer_bridge_test.gd`
专项以 **failures=0** 为准。D12 已接通 Country granted-mask、唯一写者和 ACTIVE read-view；
Country–Economy D7 的完整跨线程 continuation、事务级持久化和 Economy 正式 ACTIVE 接管仍未完成。

2026-09-09 继续实施已把 Host 的 peer rejection 从“停在 active plan”改为可续跑语义：Country
侧先提交当日命令、研究资源消耗和 pending technology，业务 generation 不增加；Host 清理旧
intent/result，记录 `rejected_intents/has_unreported_rejection/retry_day/rejected_request_id`，
并把同一语义边界标记为已封口。保存在该 rejection retry barrier 存在时明确返回
`country_worker_save_barrier`；同日不会重复发出 intent，次日用新的 day 参与 request identity
生成新 intent，ACK 成功后才清除 barrier。`runtime_country_host_rejection_self_test()` 已直接
覆盖这条 Host stage 路径；它不是 Country ACTIVE 放行证明。

已完成的 Host 协议切片（2026-09-09）：`DCWorldExt::submit_country_commands()` 只有在实际
`authoritative_domain_mask` 含 COUNTRY 时才进入 Host admission；未授权继续走同步参考路径。
当前 worker packet 支持 POD 可表达的 TRANSFER、GRANT、RESEARCH、CLAIM 数值命令，并保留
生产的 `(effective_day, sequence, submit_order)` 排序。整批容量不足、day 已过或 opcode 尚
未表达时返回明确拒绝。入队成功返回显式 `Accepted`，终态通过
`poll_country_command_receipts(after_request_id, limit)` 游标读取；整批执行失败发布
`RejectedAtExecution`，成功发布 `Committed`，等待 peer ACK 时不提前发布终态。Host 自测覆盖
批内 malformed packet 后按 request id 清除已排入 POD pending 的同批命令，防止终态请求重放。
Host receipt history 已在 2026-09-09 接入 CPD2/PKSR 保存恢复：保存边界会合并 Host 的
Accepted request state、Committed/RejectedAtExecution terminal receipt，并在恢复启动时恢复
receipt cursor 和 request-id 水位；pending Country packet 必须对应 Accepted，错误协议整体拒绝。
worker 仍只表达部分 opcode，因此不能作为完整
20 opcode 或生产 ACTIVE 的完成证明。

**与 Economy 的边界**：国库/科技/领土在 Country worker ACTIVE 后由 worker 提交；同步
facade 停写。Economy 通过 `capture_country_epoch`（`copy_economy_snapshot`）冻结快照消费，
且 live 路径的 `has_technology` / `country_slot_for_cell` 同样钉 worker
`country_asset_snapshot`，避免出现「科技面板已掌握、建筑检视仍技术停用」。税率在 epoch
begin 从 country + modifier 快照冻结；研究采购在 Economy 的
`GOVERNMENT_RESEARCH_PROCUREMENT` stage 消费冻结的 country 政策。
科研采购、财政 escrow、Country↔cohort 现金、Country↔market 商品以及建筑/运河 treasury 支出
都已具备统一 typed asset bridge；`research_purchase`、财政三类操作、cohort cash、market goods
以及 construction/canal 的生产调用方已升级为 Economy-owned coordinator，其中
`treasury_spend` 和 `research_purchase` 已升级为真正可跨调用续跑
的事务：Country 侧 reservation 不修改已提交余额，等待 peer prepared ACK，记录 commit decision，
再等待 peer applied ACK，并以原 transaction ID 幂等重试。当前这些 coordinator 仍在同步 Economy
stage 内完成 peer prepare/commit/apply/ACK，尚未迁移到持久 Host 的可续跑 outbox/inbox，因此
K2-B 跨线程闭环和 Country ACTIVE 仍是硬阻塞项。

**`country_committed` 信号**：由 `CountryFacade.dispatch_committed_events` 在领土/country 变更
时发出，`WorldRuntimeHost`（视野/边界）、`PlayerController`、`GameUIManager` 监听。
注意顺序要求——runtime graph 路径下必须**先 `sync_country_territory_to_map` 再 dispatch**
（`map_generator.gd:3398+`），否则监听方读到的 `cell.country_slot` 是旧的。

### 2.7.4 其余模块

`modifier_daily` / `trigger_daily` / `ideology_runtime` / `effect_runtime` / `gameplay_effect`
都是 SUS job + 各自的 native runtime；其中 legacy ModifierRuntime 仍是生产主线程 authority。
Modifier 另有接入 `NativeSimulationHost` 的完整 SHADOW POD stage，用于 plan/replay、ACK 和
snapshot 对照，但尚未取得 ACTIVE authority；其它域的 POD 状态见 4.2。

## 2.8 放行门（gate）

原定的准入清单是七条：1000 日逐日 parity、save/restore parity、`fallback_count=0`、
`fatal=false`、`source scan=0`、worker 不访问 Godot 类型、`main_wait_on_sim_us=0`。

**Climate 实际放行时改了两条，这个改动本身是框架的一部分**：

- **"1000 日逐日 parity" 降为"分叉矩阵逐条归因"**。理由是生产 round 按 stride 跑，30 日窗口
  只含约 4 个有效比较日，1000 日也只含约 130 个——加长窗口买不到多少信息量。判据换成了：
  每一条分叉都能一对一映射到某个具体原因（已知语义差 / 未实现 stage / 真实缺陷）。
- **"save/restore parity" 只做到 roundtrip 绿**，没做 restore 后继续长跑对拍。

**并且这份清单被证明不充分**：它全是 headless 指标，而 Climate 放行后在真实客户端又暴露了
四个 headless 没抓到的缺陷。**后续域放行必须补第八条：真实客户端会话下的字段录制对照。**

**第九条（2026-09-22 追加）：fail-closed 出口清单。** 一个域转 ACTIVE 之前，必须列出它在
生产路径上引入的**所有** fail-closed 点，逐个回答两个问题：

1. 这个拒绝是契约违反还是时序窗口？两类混用同一个 reason 字符串的，先拆开。
2. 时序窗口类的拒绝，调用方有没有回退（异步 enqueue / park 重放 / 软跳过）？没有回退
   的，要么补上，要么证明该窗口在生产路径上不可达。

D7 的 cohort cash sync fast path 就是没过这一关的反例：它把 Country plan 窗口当成契约
违反，且失败后够不到紧邻其下的软回退，于是每次撞上 continuation 都把整个经济运行时打进
FATAL（day 2744 停机）。这一条不是事后补的形式主义 —— 它是迄今唯一一类在 headless 全绿、
soak 全绿之后仍然在玩家侧稳定复现的停机。

推荐的放行流程（Climate 走通的那条）：

```text
1. SHADOW 接线   → 每个 stage 单独接，接一个验一个（stage-days 计数）
2. 分叉矩阵归因 → 每条分叉写明原因，不允许"暂时未知"
3. ACTIVE soak  → 对着 PK_SOAK_AUTHORITY=0 的同 seed 基准读逐场 nz/mean/max
4. 回归全绿
5. fail-closed 出口清单（第九条）← D7 cohort cash 漏的就是这一步
6. 真实客户端录制对照  ← Climate 是在这一步之后才发现四个缺陷的
7. 翻默认开关
```

---

# 第三部分：任务表（完整迁移的工作分解）

这是**完整迁移的工作分解**，阶段 A–L，含已完成项。每条子任务标状态：`[x]` 完成、
`[~]` 部分、`[ ]` 未开始、`[-]` 已取消（附原因）。没有验收标准的条目不该进这张表。

**目标是全量迁移**：十二个域全部进入 `implemented_domain_mask`（`0xFFF`），整图 ACTIVE。所以
下面没有"要不要迁"的决策项，只有"怎么迁、按什么顺序迁"。

进度概览：

| 阶段 | 内容 | 状态 |
| --- | --- | --- |
| **A** | 基础设施：协议、线程、快照、存档骨架 | ✅ 完成 |
| **B** | CLIMATE 垂直切片：第一个域走通全流程 | ✅ 完成（B8 于 2026-09-12 收口） |
| **C** | 测量能力：证明收益、抓住 headless 抓不到的问题 | 🔶 C1/C3 已采集；C2 Country pass；`weather_field_init` 已补 extras 回灌，其余 Climate 差异已按 B8/滞后声明 |
| **D** | COUNTRY | ✅ D1–D12 完成（生产 ACTIVE，`0x806`） |
| **E** | MODIFIER | ✅ E2–E8 完成（生产 ACTIVE，`0x846`） |
| **F** | EFFECT | ✅ F2–F8 完成（生产 ACTIVE，`0x866`→`0x876`） |
| **G** | IDEOLOGY | ✅ G2–G8 完成（生产 ACTIVE，`0x876`） |
| **H** | TRIGGER_INPUT | ✅ H2–H8 完成（生产 ACTIVE，`0x876`→`0x87E`） |
| **I** | EVENTS | ✅ I1–I8 完成（生产 ACTIVE，`0x87E`→`0xFFF`；worker 镜像，legacy journal 仍是消费源） |
| **J** | ECONOMY（最大工程） | ⬜ 仅 store |
| **K** | GAMEPLAY_EFFECT / VISUAL / INPUT_CAPTURE：确认语义而非搬状态 | ⬜ 未开始 |
| **L** | 整图收尾：`0xFFF` + 整图 ACTIVE | ⬜ 未开始 |

E–J 的顺序由依赖决定（见"每个域的通用七步"末尾的依赖图），不是按工作量排的。

---

## 阶段 A：基础设施 ✅

一次性地基，后续每个域共用。

- [x] **A1 Runtime Domain ABI v3**：`RuntimeDomainId` 12 域、mask、stage 顺序
      → 验收：`runtime_protocol_guard_test` 绿
- [x] **A2 命令 / intent / ACK 协议**：`RuntimeDomainAck`、跨域屏障语义
- [x] **A3 Snapshot ring**：三缓冲提交 → `runtime_snapshot_ring_test`
- [x] **A4 Worker 生命周期**：`start_runtime_worker`、OFF/SHADOW/ACTIVE 模式机
- [x] **A5 线程隔离门禁**：worker 不得依赖 Godot/MapData
      → `runtime_worker_source_scan_test`、`runtime_thread_isolation_test`
- [x] **A6 存档骨架**：PKSR envelope + 每域 section 机制
- [x] **A7 并行执行器**：`NativeParallelExecutor`（修过一次屏障竞态：需同时等
      `_remaining_tasks==0` 与 `_active_workers==0`）
- [x] **A8 逐域放行机制**：`authoritative_domain_mask` 与 `implemented_domain_mask` 分离，
      解除"全部就绪才能开 ACTIVE"的死锁

## 阶段 B：Climate 垂直切片 ✅

第一个域，也是给后续域趟路的样板。

### B1 共享内核提取 ✅
- [x] 九个 pass 提取为共享纯内核（`runtime_climate_passes.{h,cpp}`），生产与 worker 同一份
- [x] round 编排 `run_climate_round_passes`（passes_mask 门控 + 逐 pass in←out 接力）
- [x] 消除生产侧三份重复的 albedo 主循环
- [x] `passes_ran` / `passes_starved` 两个 bit mask 插桩——**此前 pass 被跳过时完全静默**

### B2 对拍能力 ✅
- [x] 统一比较器：两侧共用 `parity_hash()`（此前两侧哈希函数/字段集/framing 全不同，
      `matched` 只能靠 2⁻⁵⁶ 碰撞成立）
- [x] 分叉矩阵：按 canonical 字段表逐字段累积，mismatch 填 field/cell/stage/两侧 bit
- [x] `climate_parity_probe.gd` harness
- [x] 首帧 `adopt_reference_baseline`（worker store 全零 vs reference 带世界生成结果；SHADOW 用 environment day 收基线，日不对齐时不放行 worker 日）

### B3 输入边界 ✅
- [x] environment 快照全 lane（补齐过 12 条缺失 lane）
- [x] 生产 round 输入分层 overlay（`overlay_production_pass_a`）
- [x] `ClimateRoundStaticKnobs`（catalog 表、`water_terrain_ids`、`neighbor_indices`）
- [x] `climate_round_scalars` 整套传递（复用生产构建函数）
- [x] `climate_stage_knobs` 通道
- [x] CSR 形式下 `neighbor_indices` 的回填

### B4 stage 接线 ✅
- [x] round 内八个 pass（`pass_a`..`transpiration`）
- [x] albedo / vegetation_dynamics / climate_feedback / weather_distribute / weather_field
- [-] runtime_hydrology —— **取消**：`runtime_hydrology_enabled=false` 时生产侧返回 `{}`，
      两侧都不跑
- [x] 跨天状态自持：`own_snow_state`、`own_field_state`、`climate_worker_authoritative`

### B5 回灌通路 ✅
- [x] store 内字段回灌
- [x] store 外字段（`soil_moisture`、pass_a 五条输出）走 snapshot 独立字段，不动 PKEC 格式
- [x] 执行序钉死：回灌 → season refresh → capture
- [x] 存档 CLM2 + roundtrip 测试

### B6 转 ACTIVE ✅
- [x] 按域授权门
- [x] 主线程 Climate 抑制门：`climate_worker_authoritative()` 为真时跳过整张
      native daily / schedule graph（不是历史文档里的“逐节点 14 门”）
- [x] `runtime_climate_authority_enabled` 默认 true
- [x] 回退路径（一个开关）

### B7 客户端暴露的缺陷 ✅
- [x] scalars 缺失（`insol_amp` 默认 0.20 vs profile 0.32，季节振幅只剩 62.5%）
- [x] pass_a 五条输出无回灌写者
- [x] 海冰累积（lane 被填零 → 每天从零冰起算）
- [x] weather field solve 从未运行（湿度跳变）

### B8 遗留（转入 P2） ✅（2026-09-12 收口）
- [x] ~~stage 重排：`feedback` 移到 `weather`/`distribute` 之后~~（2026-09-11，B8-1）
- [x] ~~ψ / cyclone / monsoon 自持推进~~（2026-09-11 + P2 物理内核/ABI 7）
- [x] ~~量级偏差归因~~（2026-09-11：declared_gap；headless A/B 非数值 oracle）
- [x] ~~按格数的启用阈值~~（2026-09-12：C1/C3 阶梯实测无一档可负担；
      `ClimateAuthorityPolicy` 落地 `threshold_source=
      c1_c3_ladder_20260911_no_affordable_size_at_x50_keep_on`，
      `threshold_cells=0` + 诊断
      `auto_measured_keep_on_no_affordable_size`；产品保持 AUTO 开启，
      FORCE_OFF 为性能逃生口）
- [x] ~~大地图回灌跟不上节拍~~（2026-09-12：B8 P3 环境 FIFO ring 深度 4；
      主线程 `wait_climate_consumed(0)` 等空位而非串行等消费；
      ACTIVE 满环拒绝、SHADOW force 计 `dropped`；`serial_wait` 下
      `superseded=0`。吞吐仍受 worker 单日成本限制，但丢天/单槽覆盖已消除）
- [x] ~~清理 `RuntimeClimateCommand` 5 个悬空 opcode~~（2026-09-11）
- [x] ~~修 `implemented_domain_mask()` 过期注释~~（2026-09-08）
- [x] ~~terrain/cover 迁入 worker~~（2026-09-12：CLM2 ABI 8 + parity v4 + writeback）
- [x] ~~环境有界 ring~~（2026-09-12：`RuntimeEnvironmentInputRing`）
- [x] ~~C5 场景表门禁~~（`tests/runtime_climate_c5_scenarios_test.gd`）

#### B8 修复进展（2026-09-11，按计划 P0/P1/P3 部分）

已完成并随本 PR 落地：

- **P0 交付游标与丢天计数**：`RuntimeThreadReport` 新增
  `climate_committed_day`、`climate_consumed_generation`、
  `environment_published_days/consumed_days/superseded_days/dropped_days`、
  `climate_wait_total/last/max_ms`；`get_runtime_thread_report()` 与
  `WorldRuntimeHost.climate_authority_diagnostics()` 全部透传。
  `superseded` 的定义是"已发布但被下一天顶掉、worker 从未 plan 过"，这正是
  单槽 latest-value 的静默丢天；它现在是一个可读数字，不再是推断。
- **P0 回灌分段耗时**：`apply_runtime_climate_writeback()` 返回
  `memcpy_ms` / `flush_map_ms` / `total_ms` / `dirty_fields`，把"worker 慢"
  与"回灌写回慢"分开。
- **P0 stage 顺序契约**：`runtime_climate_kernel.h` 新增
  `RUNTIME_CLIMATE_CANONICAL_ORDER`（声明序即执行序）与
  `runtime_climate_stage_order_self_test()`；kernel 的 `run_stage` 记录真实执行序
  (`RuntimeClimateKernelReport::stage_sequence`)，self-test 校验它与声明序一致。
  生产侧由 `DCWorldExt::runtime_climate_stage_order_contract_test()` 核对
  `NATIVE_DAILY_SLICE_GRAPH` 的无条件执行链（round 8 段 → weather_field →
  commit → distribute → summary → cyclone → hydrology → stage_b_after_hydrology），
  并报告 `weather_stage_b` 等条件宿主。新增测试
  `tests/runtime_climate_stage_order_contract_test.gd`（538 项断言）。
- **P0 字段写入权台账**：`tools/runtime/climate_field_ownership.json` 为 parity 表
  的 35 个字段逐一记录生产写者、ACTIVE 抑制项与回灌归属，并与
  `authority-stage-c-field-policy.json` 交叉校验；测试在字段表漂移、台账过期或
  抑制 token 非法时失败。
- **P1 stage 重排（B8-1）**：worker kernel 的
  `albedo → vegetation_dynamics → climate_feedback` 从 weather 之前移到
  weather/distribute/hydrology 之后（生产 `weather_stage_b` /
  `stage_b_after_hydrology` 的落点）；诊断近似回退路径同样按 canonical 顺序执行。
  vegetation/feedback 的 `weather_type/intensity/field_init` 输入改为读 worker
  当天 store（`_weather_field_init_scratch` 只在真的被 seed/写过时启用），生产记录
  仅在 worker 当天没算出该场时兜底。
- **P3 背压等待（B8-5 的结构部分）**：
  `DCWorldExt::wait_climate_consumed(after_environment_generation, timeout_ms)` +
  `NativeSimulationHost::wait_climate_consumed()`（条件变量，非忙等）。
  `WorldRuntimeHost.wait_for_climate_consumed()` 在切片之间 pump
  Country/Economy peer 服务，避免两个边界互锁；`_on_clock_day_changed` 已把
  "回灌 → 等 worker 消费上一份环境 → capture" 串成同一调用栈。终止条件只有
  worker 故障/停止、权威撤销、接口缺失三类 —— 无性能超时（按计划的"无限等"选择）。
- **B8 证据工具**：`tools/runtime/Invoke-ClimateB8Soak.ps1`（单次 soak +
  `soak.json` 摘要）、`Compare-ClimateB8Soak.ps1` + `climate_b8_soak_policy.json`
  （按字段 nz/mean/min/max 判定 pass / declared_gap / regression）；
  `climate_authority_soak_probe.gd` 新增 `PK_SOAK_DRIVE=serial_wait` 与
  `[soak/delivery]`、结构化 samples（stage_b_after_hydrology 也补进 stage 名单）。

  **首轮 smoke 证据**（2026-09-11，40x32 / 12 天 / x50 / `serial_wait`，
  `artifacts/runtime/climate-b8/ab/`）：

  | 指标 | OFF | ACTIVE |
  | --- | --- | --- |
  | `first_bad_tick` | -1 | -1 |
  | `environment_published_days` | — | 12 |
  | `environment_consumed_days` | — | 11 |
  | `environment_superseded_days` | — | **0** |
  | `environment_dropped_days` | — | 0 |
  | `writeback_days` | 0 | 8（含固定的一日交接滞后） |
  | `writeback memcpy_ms` / `flush_ms` | — | 0.14 / 0.10 |
  | `climate_wait_total_ms` / `max_ms` | — | 90 / 10 |

  结论：单槽丢天已被等待消除（superseded=0）；回灌 memcpy/flush 都是亚毫秒级，
  不是瓶颈；剩余差距集中在 worker 单日成本（由 `climate_wait_total_ms` 体现）与
  B8-3 量级偏差。同一轮 A/B 由 `Compare-ClimateB8Soak.ps1` 判定为
  `declared_gap`：7 条已知 B8 偏差带 run-id 与原因，0 条未声明回归。

本轮又补上的两项：

- **B8-2 子项：worker 自持 synoptic ψ**。生产侧只剩"冷启动播种"：capture 把
  `DCWorldExt::_wx_synoptic` / `_wx_synoptic_prev` 当天 solve 读到的那一帧传给
  worker（`WeatherFieldInput::psi/psi_prev`），worker 第一次见齐长 lane 时拷进
  `RuntimeClimateKernel::_synoptic_psi`，之后用当天风场 + 归一化温度调用共享的
  `synoptic_advance_pure` 自己推进。SHADOW 不自己推进（直接用生产那一帧，保持
  复刻语义，避免把"节拍差"记成算法分叉），ACTIVE 用自己的单调 tick。
  `PK_CLIMATE_SYNOPTIC_OFF=1` 复现 B8 之前的"无 ψ"路径，用于 E6 归因 A/B。
  存档：**CLM2 ABI 3→4**，ψ/ψ_prev 进 store lane 与 `state_hash`，随存档持久化；
  ABI 3 旧档按旧 lane 顺序读取、新增两条留全零，并跳过 ABI 4 才有的 state_hash
  校验（旧档的 hash 不含这两条）。`RuntimeClimateAuthority::self_test()` 内置
  迁移自检：把 ABI 4 payload 剪掉 ψ 两条 lane、改写 header 后走正式 restore，
  验证成功且 ψ 全零。
- **交付等待的自旋缺陷修复**。新计数器一上来就抓到：`environment_consumed_days`
  在 50 天里涨到 3200 万。根因是 worker 消费环境后在 `_control_cv` 上
  `notify_all`，而它自己的 preflight 重试也挂在同一个 CV 上——自唤醒自旋。
  现在等待用专用 `_climate_wait_cv`，并且只有"第一次看到某个代次"才计入
  delivered，失败天的重试不再把计数撑成重试次数。修复后同一组 60x40/50 天：
  `published=50 consumed=50 superseded=0 dropped=0`。

**SHADOW parity（30 天，`parity-30d-parity30.json`）**：`compared=30 matched=28`
（回到并保持文档基线 28/30）；天气组（precipitation/vapor/cloud/instability）
从 3 天分歧降到 1 天（day 7），`snow_cover` 0 天分歧。

**E1 归因（stage 顺序单因子，80 天 / 40x32 / ACTIVE，`artifacts/runtime/climate-b8/e1-80/`）**：
canonical vs legacy 顺序，其它变量完全不动：

| 场 | 最大 mean 差 | nz 差 | 结论 |
| --- | --- | --- | --- |
| `plant_available_water_arr` | — | 847（tick 5 一次性） | 顺序改变 PAW 初值，随后收敛 |
| `moisture_arr` | 0.016 | 0 | 早期偏移，随后收敛 |
| `snow_cover_arr` | — | ≤5 | 顺序几乎不解释 snow_cover |
| `vegetation_growth_pressure_arr` | ≤0.0013 | 0 | **顺序不是 VGP 反号的成因** |

结论：B8-1 的 stage 重排把 worker 顺序对齐到生产语义（正确性/一致性），但
它不是 snow_cover +25% / VGP 反号的成因；这两个必须继续查 E2（输入所有权）、
E5（succession）与 E6（ψ）。

**E6 归因（ψ 自持 on/off，30 天 / 40x32 / ACTIVE，`artifacts/runtime/climate-b8/psi-own/`）**：
`PK_CLIMATE_SYNOPTIC_OFF=1` 复现 B8 之前的"无 ψ"路径：

| 场 | ψ on | ψ off |
| --- | --- | --- |
| `weather_vapor_arr` mean | 0.18039 | 0.18077 |
| `weather_cloud_arr` nz | 1280 | 1280 |
| `weather_precip_arr` nz | 171 | 167 |

结论：ψ 自持在 30 天窗口里对天气只造成 <0.5% 的差异；它是正确性补齐（worker 不再
丢 syn_base_lift 这条驱动），**不是** B8 量级偏差的成因。

**顺带两处修正**：

- **weather 在 ACTIVE 下确实是活的**。C++ 一次性诊断
  `[climate/writeback][b8] day=5 vapor store0=0.110427 map0=0.110427` 证明
  worker→writeback→MapData 链路完好；此前"天气全零"是 soak 的 `CONTESTED` 清单
  没包含天气数组、PowerShell 读缺失 key 拿到 0 的假象。天气组已加入结构化采样，
  实测 `vapor nz=1280 / cloud nz=1275 / precip nz=171` 且随 ψ 推进逐日增长。
- **主线程 weather job 的唯一写者门**。`WeatherRefreshJob.should_run()` 与
  `run_slice()` 在 Climate worker 权威时返回抑制（`MapGenerator.climate_authority_suppressed()`）。
  原先它不在任何抑制门内：DCSystemScheduler 路径直接走 policy + run_slice，
  主线程 weather 链可以在 writeback 之后用一份不再推进的 field state 覆盖天气场。

**B8-P1：succession 写入权迁入 worker（CLM2 ABI 5）**

- store 新增 `vegetation` / `base_vegetation` 两条 u8 lane，进 `state_hash`；
  `CLIMATE_U8_LANES_V4` 保留了 ABI<=4 的旧 lane 集合，restore 现在同时支持
  ABI 3/4/5（`self_test` 对 ABI 3 与 ABI 4 各造一份旧 payload 走正式 restore，
  验证新 lane 全零、metadata 一致）。
- worker 在 `vegetation_dynamics_apply_pure` 之后直接应用演替 emit，规则与
  `_apply_vegetation_succession_candidates` 逐条对齐：`vegetation`/`base_vegetation`
  同步换档、降级用 `vegetation_degrade_reset_target`（新增 knob）、升级用固定 0.7、
  vitality 取中点；streak 冷却由纯内核写入。冷启动从 capture 的 vegetation lane 播种。
- 两条 lane 进了 parity 表（`RUNTIME_CLIMATE_PARITY_VERSION` 2→3）与写入权台账，
  所以它们既出现在分叉矩阵里，也走 writeback 回灌 MapData（不再靠 extras 旁路）。
- **发现并修掉一个真 bug**：`copy_store_lanes` 是手写清单，新增 lane 不在里面时
  双缓冲之间状态不连续 —— 实测 `vegetation_arr` 在 0/679 之间逐日翻转，ψ 也从未
  真正进 store（save/restore 表面通过、实际存空 lane）。补上四条 lane 后：
  ACTIVE 120 天 `vegetation nz=679 mean=8.559` 与 OFF 基线 `8.5586` 一致且稳定；
  SHADOW parity 仍是 `matched=28/30`，新增的 vegetation / base_vegetation
  在 30 天里 **0 天分歧**。

**B8-3 归因：一日滞后 vs 真实分歧（12 天逐日采样，`artifacts/runtime/climate-b8/lag/`）**

把采样改成逐日，并让 ACTIVE 的 tick T 对齐 OFF 的 T-1（权威回灌固定滞后一日）：

| tick | PAW on(T) vs off(T-1) | VGP on(T) vs off(T-1) | moisture on(T) vs off(T-1) |
| --- | --- | --- | --- |
| 2 | 0.8337 vs 0.8337 | 0.1965 vs 0.1965 | 0.8404 vs 0.8404 |
| 4 | 0.8337 vs 0.8337 | 0.0000 vs 0.1965 | 0.8632 vs 0.8404 |
| 6 | **0.2386 vs 0.8337** | 0.0000 vs 0.1965 | 0.8790 vs 0.8404 |
| 12 | 0.2471 vs 0.8337 | 0.1144 vs 0.1965 | 0.8897 vs 0.8538 |

结论（这是目前最强的一条归因证据）：

1. **tick 2–5 的差异 100% 是滞后**：PAW/VGP/moisture 三个场逐位相同，说明 P1/P2 的
   顺序、输入所有权、ψ 都没有引入早期偏差。
2. **tick 6 起出现真实分歧**：ACTIVE 的 PAW 从 0.8337 崩到 0.2386（-71%），VGP
   同期掉到 0，moisture 随后单向偏高。分界点落在 PAW/soil_moisture/WB30 这条链上，
   而不是天气、ψ、stage 顺序或演替。
3. 结合上面的 E1/E2/E6 三个负结果（顺序、植被三 lane 所有权、ψ 各自都不是成因），
   剩余 B8 量级偏差的排查面已经收敛到**一条链**：PAW 重算所消费的
   `cell_soil_moisture` / `water_balance_30d` 在 ACTIVE 下由谁在什么时点写、
   以及 distribute 缺席日这两个 lane 取到什么值。

#### 收尾：PAW 链已归因，headless soak A/B 不是数值 oracle

PAW 逐日诊断（`artifacts/runtime/climate-b8/paw-diag2/`，12 天，每图第一个陆地格）：

```
day=3..12  zeros(water=847 land=0) nonzero=433
probe cell=70 moisture≈0.845 wb30∈[0,-0.00039] soil∈[0,-0.00094] paw≈0.844
```

- **PAW 的"collapse"是水域规则**：worker 每图把 847 个水域格 PAW 清零、陆地 0 个
  清零；OFF 侧在这个 headless harness 里从不跑同一条 clearing stage，于是水格保留
  世界生成时的种子值。mean 从 0.8337 掉到 0.2386 = 847/1280 格按设计归零，
  不是公式或权重错误（陆地 probe 全程 0.84）。
- **tick 2–5 与 OFF(T-1) 逐位相同**：这一段差异 100% 是一日权威滞后。
- 因此 headless soak A/B 对 **cadence 门控 + 主线程伴随写者**的场（PAW / WB30 /
  VGP / snow_cover / soil_moisture）不是有效数值 oracle：两侧跑的不是同一批
  writer。它的正确用途是**稳定性/回归**（NaN、丢天、大幅漂移），数值对拍交给
  SHADOW parity（生产与 worker 同日并行）与 C2 客户端全量录制。
- E1（stage 顺序）、E2（植被三 lane 输入所有权）、E6（ψ）三个单因子实验均已实测为
  **非成因**；PAW/VGP/WB30/snow 在 soak policy 里已从"待查偏差"改写为"已归因 +
  引用证据 run-id"。

**B8-2：cyclone 自持（CLM2 ABI 6）**

- **纯内核**：`pk_async_climate::cyclone_advance_and_stamp_pure` 把
  `DCWorldExt::_advance_and_stamp_cyclones` 逐行搬成不依赖 Godot 类型的实现
  （`Vector2` → 标量对、Dictionary knobs → POD、条目表指向调用方 vector）。
  公式、阈值、步数、BFS stamping 顺序均未改动。
- **worker 状态**：kernel 持有 `_cyclone_entries`（跨天）+ 当天派生 lane
  （tag/visit/x/y/lift）+ generation；每个 weather 日在 field solve 之前推进/衰减/
  stamp，并把 stamp 结果喂给 `WeatherFieldState`（与生产同一位置、同一顺序）。
  冷启动先看 store blob（存档恢复），再看 capture 的生产种子。
- **持久化**：CLM2 ABI 6。条目表是可变长，编码成不透明 blob
  （`cyclone_state_encode/decode`：magic+version+count+next_stable_id+记录表），
  追加在 lane 之后；ABI ≤ 5 的旧档读完后 `cyclone_state` 保持空。迁移自检新增
  ABI 5 用例（只缺 blob）并断言旧档不会解出 blob。
- **验证**：kernel self_test 覆盖"推进改变 intensity/age + stamp 写出 tag/x/y/lift +
  encode/decode 往返"；`PK_CLIMATE_CYCLONE_FORCE=1` soak 的
  `[climate/worker][b8] cyclone day=4/12 entries=0 alive=0 touched=0 gen=2/3`
  证明接线按 weather 节拍运行。
- **cyclone genesis 也迁入 worker**（同 CLM2 ABI 6）。生产的是
  `cyclone_wake_step` 的 native-entity 分支：从 WeatherFront 列表里挑
  `type == STORM && intensity ≥ 0.8` 的前沿，按其 center 反查格子、过物理闸、
  以切向向量注入条目。ACTIVE 下没有 front 对象（summary 段被抑制），所以这条
  路径必须换成 worker 自己的格子态判据：
  - `pk_async_climate::cyclone_genesis_pure`：水陆 LUT、纬度带、`temp ≥ 0.58`、
    `precip ≥ 0.05`、`cloud ≥ 0.22`、`instability ≥ 0.40 or convergence ≥ 0.30`、
    风切变 ≤ `max_shear`、强度门、`capacity` / `births_per_commit` 全部与生产逐条
    一致；唯一键从 `q*10000+r` 换成 cell_idx（worker 内等价），同键覆盖
    （replaced）不吃出生预算，只有新条目才消耗 `births_per_commit`。
  - **前沿等价物 = `weather_intensity` lane**：生产 front 的 intensity 就是
    cluster 内最大 cell intensity（`world_ext_weather.cpp` summary 段
    `std::clamp(c.max_intensity, 0, 1)`），两者同源。**不能**再要求
    `weather_type == STORM`：field solve 只有在已有 stamp（`cyclone_lift ≥ 0.58`）
    时才把类型写成 STORM，拿它当出生条件就是闭锁 —— `require_storm_type` 只留给
    A/B 复现旧闭锁。
  - **纬度带用规范 `cell_lat_norm`**：生产公式 `abs((pos_y-wb_y)/wb_h*2-1)` 里
    `_world_bounds` 是世界矩形、`cell_pos_y` 是格子局部坐标，两者尺度不一致
    （实测 50x48 地图 water_ny ∈ [0.026,0.068] ⇒ abs_lat ≈ 0.95，恒出带）。
    worker 侧改用 `cell_lat_norm`（赤道 0.5，与 `temp_baseline` 同源）；lane
    缺席时退回生产公式，`CycloneLanes::lat_norm` 空指针语义即对拍/单测路径。
  - **profile 常量入 capture**：`stage_weather` 原来不带 cyclone 常量，host 只能按
    `cyclone_storm_type_id=-1` 兜底 ⇒ genesis 永不触发。现在
    `MapGenerator._build_runtime_climate_stage_knobs()` 显式注入
    `cyclone_storm_type_id` / `cyclone_wake_days` /
    `native_tropical_cyclone_enabled` / `tropical_cyclone_{capacity,births_per_commit,
    min_temp,min_instability,max_shear,min_lat,max_lat,max_radius_cells}`。
  - **门控现状**：`ClimateProfile.native_tropical_cyclone_enabled` 的脚本默认是
    false，但生产 profile `data/world/earth_like.tres` 把它打开 —— 也就是说 cyclone
    子系统在这张图上本来就每天在跑（`cyclone_gate ... input_enabled=1`）。迁移只换
    所有权，不改这个门。
  - **验证（160 天 / 50x48 / ACTIVE / `serial_wait`）**：
    `PK_CLIMATE_CYCLONE_GENESIS_GATE=0.6` 是**证据用覆盖**：默认世界里热带水格的
    intensity 年峰值只有 0.76（`max_int` 漏斗实测），压在生产的 0.8 门之下，不降门
    就拿不到"出生→推进→衰减→淘汰"的实证（`PK_CLIMATE_CYCLONE_FORCE=1` 只在
    profile 关掉气旋时才需要）。日志
    `artifacts/runtime/climate-b8/soak/cyclone-genesis-gate06/soak.log`：
    day=52/76/116 `injected=1`（出生），day=60/84 `decayed=1` 且
    `int(before/after)=0.625/0.000`（推进读的是 worker 自己那份 store 条目），
    全程 `first_bad_tick=-1` / `drops=0`。
  - **默认门 0.8 在默认世界不可达是生产事实**，不是 worker 回归：同一份阈值、
    同一条 intensity 定义；本项迁移只换所有权与输入来源。`storm_type` 漏斗
    （`type_storm` 计数）证明 worker 分类确实会产出 STORM 格（一年内最多 7 格同
    时），只是强度还没到 0.8。

仍未完成（后续阶段）：无。B8 清单于 2026-09-12 收口。

已关闭的 P2/P1/P3/P4 摘要：

- **P2 物理环流**：共享纯内核 + `RuntimeClimatePhysicsState` + `physics_prepass` +
  `climate_physics_authoritative` / `get_climate_physics_read_view` + CLM2 ABI 7。
- **P1 succession**：vegetation/base_vegetation（ABI 5）+ terrain/cover（ABI 8）。
- **P3 环境 ring**：`RuntimeEnvironmentInputRing` 深度 4；ACTIVE 满环拒绝；
  `wait_climate_consumed(0)` 等空位。
- **P4 阈值**：实测无一档可负担；策略落地 keep-on + 显式诊断。

历史展开（保留证据，不再是开放项）：
  - 新增 `gdext/src/runtime_climate_physics.{h,cpp}`（namespace `pk_async_physics`，
    Godot 无依赖，已进 `runtime_worker_source_scan_test` 的守护清单）。
  - **SLP 已迁**：`run_slp_field_pass` 的 Pass A（逐 cell 基线）与 Pass B/norm
    （Jacobi 平滑 → recenter+p95 → 响应混合 → 再 recenter → delta）改调
    `slp_pass_a_range` / `slp_pass_b_pure`。生产保留 `pk::parallel_for_range`
    分段（逐 cell 独立 ⇒ 分段 bit-equal），worker 侧单线程整段调用。
  - **wind field 已迁**：`run_wind_field_pass` 的主循环（纬度基线 → ∇SLP/科氏 →
    沿海权重 → 海风/热力季风 → synoptic 波 → 地形绕流 → 响应混合 + NS Phase 1
    动量自平流/扩散 → 转向限幅）改调 `wind_field_range`；季风/flip 统计按区间
    返回后在生产合并（整数加法的合并顺序无关）。几何/风带常量（`NB_DIR_*`、
    `WIND_*`、`COAST_INF`、`pk_wind_*` helper）同时收进
    `runtime_climate_physics.h` 作为**唯一来源**，`world_ext_physical.cpp` 改用
    `using` 声明，杜绝两份常量漂移。旧的内联实现已整体删除（不是注释掉）。
  - **psi SOR 已迁**：`run_psi_solver_pass` 的三段全部走共享内核 ——
    `psi_topology_build_pure`（水域 CSR：cell↔water 互逆映射 + `nb_w`，生产保留
    自己的 FNV 指纹缓存外壳）与 `psi_solve_pure`（tau/curl/源项 → SOR
    Gauss-Seidel（含 warm-start 与提前退出）→ grad ψ → 洋流 + 密度/地形/高纬项 +
    响应混合 + 限幅）。scratch（tau/ny/ls/curl/beta/r/source/psi 共 9 条 n_water
    缓冲）由调用方持有：生产用局部 vector，worker 侧将来用常驻缓冲；诊断
    （iters/residual/early_exit/clamp_count/preclamp_max/thermal p95）逐项对齐原
    输出键。
  - **upwelling 与 wind traj 已迁**：`run_physical_circulation_pass(stage=upwelling)`
    的主循环改调 `upwelling_range`（离岸 Ekman + 高纬冷沉，逐 cell 独立）；私有
    `_phys_build_wind_traj` 的内部循环改调 `wind_traj_build_range`（半拉格朗日回溯 +
    六分扇形 barycentric 权重）。为让后者能被 worker 复用，
    `pk_hex_sextant_barycentric` 与 `pk_wind_state_fp` 从 `world_ext_internal.h` 的匿名
    namespace **搬到** `runtime_climate_pass_math.h`（namespace `pk`，Godot 无依赖），
    成为唯一来源。
  - **coast/sea BFS 已迁**：`_phys_ensure_wind_coast` 的两次 BFS 改调
    `wind_coast_build_pure`（Pass 0 陆地→海岸 + Pass 0b 水面→岸线；生产保留 FNV
    指纹缓存与 build_ms 计时外壳，scratch 队列由调用方持有）。
  - **至此 §4.1 的共享纯内核清单全部落地**：slp / wind / psi(SOR) / upwelling /
    monsoon（在 wind 内核内）/ wind_traj / cyclone（此前完成）。
    worker 侧还额外需要 coast/sea BFS 缓存，也已一并提供（生产同源）。
  - **等价性证据**：同一配置（50x48 / ACTIVE / `serial_wait` / 30 天 /
    `PK_CLIMATE_CYCLONE_GENESIS_GATE=0.6`）在迁移前后的 `[soak/live]` 第 25 tick
    快照**逐位相同**（moisture/snow/VGP/PAW/WB30/temp/insolation/sea_ice/weather
    全组 mean、nz、min、max 一致）—— SLP、wind、psi、upwelling+traj、coast BFS
    五次迁移各自独立复核过；
    SHADOW parity 30 天仍 28/30；25/25 测试全绿。
  - 自检：`pk_async_physics::self_test()` 随 `RuntimeClimateAuthority::self_test()`
    跑（SLP：Pass A 有限性/水陆差异、Pass B Jacobi 平均手算比对、recenter 零均值、
    `response_rate=0` 保持 prev；wind：方向单位化/速度范围、季风 onshore 触发、
    季风关闭时 `monsoon_thermal` 归零且计数为 0；psi：CSR 互逆/不泄漏到陆地、
    SOR 迭代数与残差下降、warm-start 不劣化、`early_exit` 在 `min_iters` 处退出、
    洋流模长不超 `oc_max_mag`；upwelling 的陆地格归零/值域/邻陆非零、
    wind traj 的权重归一/索引域内/静止风 own-cell 退化）。
  - **物理标量链路已通（2026-09-12）**：`RuntimeClimatePhysicsKnobs` POD +
    `MapBaker.runtime_physics_knobs()` 标量投影 + capture 下发 + host 解析 +
    kernel readiness 诊断。soak 实测 `[climate/worker][b8] physics_knobs
    day=3..6 ready=1 missing=`（day1–2 为 bake 未完成的正常窗口）。过程中修掉两个
    真实缺陷：base dict 只在第一次物理求解时才建（ACTIVE 下物理被策略门挡住 ⇒
    永远拿不到标量）、以及物理标量被 weather 不到期的提前返回吞掉（readiness 随
    节拍 1/0 抖动）。详见 gdscript-cpp-data-bridge.md 同名小节。
  - **`RuntimeClimatePhysicsState` 已落地（2026-09-12，P2 §4.2）**：worker 侧物理
    常驻状态成型，SoA 全量 + shape/generation 校验：
    * 场：`slp/slp_prev/slp_thermal/slp_scratch`、`wind_x/y/speed/speed_out/delta/
      dir_delta`、`ocean_current_x/y`、`ocean_psi/ocean_psi_prev`、`upwelling`、
      `wind_stress_curl`、`ocean_thermal_anomaly`、`synoptic_psi/psi_prev`、
      `monsoon_thermal`；
    * 派生缓存：coast/sea 距离 + 朝海/朝陆单位向量 + 锚格 + BFS 队列；水域 CSR
      （`cell_to_water`/`water_to_cell`/`nb_w`）；回溯轨迹表（`wind_traj_idx/w`）；
      三者各带指纹 + valid（生产同款语义）；
    * scratch：`psi_solve_pure` 的 9 条 + 两条诊断（preclamp/thermal）；
    * API：`resize(cell_count)`（整份重建 + 派生缓存失效 + generation++）、
      `resize_water(n_water)`、`validate(error)`（形状/水域长度）、`state_hash()`
      （FNV-1a 按位，供读视图游标与存档段校验）。
    * 接线：kernel 持 `_physics`；`plan_day` 按当日 shape 自动重建；`reset()` 整份
      丢弃；原 kernel 的 synoptic ψ 四个成员已搬进该 state（rename 无行为变化）。
      cyclone 条目表仍留在 kernel —— `CycloneEntry` 属 climate 库类型，避免 physics
      反向依赖 climate 头（文档已注明）。
    * 验证：`physics_state_self_test` 随 authority 自检（resize 形状/generation、
      水域未定形必须拒绝、hash 稳定且随数据变化、缩尺寸不留残留）；50x48 ACTIVE
      30 天 soak 的 `[soak/live]` 第 25 tick 与迁移前**逐位相同**。
  - 待做（P2 后半段的下一段）：worker 侧
    `RuntimeClimatePhysicsState` + 日序接线
    （`physics_prepass → synoptic ψ → cyclone stamp → round → …`）、
    `climate_physics_authority` 开关、`get_climate_physics_read_view()` 与 CLM2 ABI 7。
- **P1 succession 纳入 worker**：`terrain_arr/vegetation_arr/base_vegetation_arr/cover_arr`
  —— `vegetation` / `base_vegetation` 已完成（CLM2 ABI 5 + parity + writeback）；
  `terrain_arr` / `cover_arr` 仍由主线程（演替后处理本身不改这两条，保留为主线程
  succession 的伴随写入）。
- **P1 量级偏差归因（B8-3）**：snow_cover / moisture / WB30 / VGP 的单因子实验
  矩阵（E1..E6）与 run-id 证据。
- **P4 按格数启用阈值**：C1/C3 尺寸阶梯实测 + `ClimateAuthorityPolicy`
  的 auto/force 三态与 GM 入口已落地（`climate_authority_policy.gd`、
  `simulation.climate_worker_authority_auto` GM 开关、
  `climate_authority_diagnostics().authority_policy`）；但阈值常量仍是
  `threshold_cells=0` + `auto_threshold_not_measured`，即 auto 保持历史默认、
  不静默改变行为。**剩余工作是 C1/C3 尺寸阶梯实测与常量落地**，判据为
  "worker p95 单日成本 ≤ 日预算且 `climate_wait_ms` p95 ≈ 0 的最大 cell 数"。

  **阈值实测结果（2026-09-11）**：

  | 尺寸 | cells | OFF adjusted days/s | ACTIVE adjusted days/s | 结论 |
  | --- | --- | --- | --- | --- |
  | 60x40 | 2400 | 28.23 | 4.97（lower bound 5.04） | ACTIVE 明显负收益 |
  | 120x80 | 9600 | 未完成 | 未完成 | OFF 基线本身在 tick 29 因 ocean frame-budget 停滞，停止 |
  | 180x120 | 21600 | 6.02（历史 sus_sim_avg） | 6.08（历史） | 吞吐中性，但 worker 跟不上（writeback 30/50） |

  60x40 的 ACTIVE 慢约 5.7×，但 `environment_superseded_days=0`、回灌
  memcpy/flush 均为亚毫秒级 —— 损失来自 worker 与主线程抢 CPU，不是回灌路径。
  **实测阶梯里没有任何一档在 x50 下满足"worker 单日成本 ≤ 日预算"**：小图明确为负，
  大图 worker 跟不上。因此 `threshold_cells` 保持 0（历史默认、不静默改变行为），
  诊断明确报 `auto_threshold_not_measured`；真正的阈值要等 P2 把 worker 单日成本
  降下来（或把目标速度调低）之后才有实测依据。这也意味着"21600 格 auto 开启"
  这条原定验收在当前证据下不成立，需要按 P2 的结果重定。
- **P4 阈值实测已做（结论见上）**：机制完整、证据齐备；常量待 P2。
- **P3 环境有界 ring**：目前仍是单槽 + 等待；`environment_dropped_days` 已就位，
  ring 深度与溢出语义待接线。
- **P5 悬空 opcode 清理已完成**（2026-09-11）：`RuntimeClimateCommand`
  （5 个）与同样无消费者的 `RuntimeClimateIntentOpcode`（2 个）已删除；
  Climate 的策略输入唯一来源是环境快照 knobs，脏信号走 day commit
  dirty families，跨域通知走既有 `RuntimeDomainIntent`/ACK ring。

## 阶段 C：测量能力 🔶 **C1/C3 无稳定收益；C2 已过 field policy（Climate 数值对拍未关）**

**为什么排在 Country 前面**：worker 化的主要卖点是帧延迟，而这个收益至今一次都没测到过；
同时 Climate 四个缺陷全部是真实客户端抓到的，headless 全绿。**不补上这两条，后续每个域都会
重复 Climate 的弯路。**

- [x] **C1 真实客户端帧统计工具**：Debug-only detached runner 走正式 `GameFlow` 会话，
      固定 `60x40` / seed `20260718` / 双大陆 / 3 foreign / x50 / `1600x960` 高画质，
      `Invoke-AuthorityStageCClient.ps1` 按 `OFF->ACTIVE`、`ACTIVE->OFF`、`OFF->ACTIVE`
      启动六个干净进程并汇总全帧、fast-tick 帧、非 fast-tick 帧。只有三个方向一致，且
      三对 p50 中位差同时达到 `0.25ms` 与 `3%` 才下稳定结论。Debug 数字不作为 Release 验收。
- [x] **C2 客户端字段录制对照 SOP 与比较器**：`TileDataRecorder` sidecar 固定记录 schema、
      session、全量字段、tick/cell coverage、authority/worker mode 和 committed/writeback day；
      `Start-AuthorityStageCManual.ps1` 启动单个干净客户端，
      `Compare-AuthorityStageCTiles.ps1` 校验元数据后按 `tick_idx + cell_index` 对齐，报告
      缺失键、非有限值、逐字段 max/mean/p95、首差异和 `-2..+2` tick 最佳滞后。      默认 field
      policy 只声明有理由的已知差异，任何未声明差异都是 release blocker。2026-09-10 起全量录制明确包含
      `country_slot_arr`；sidecar 的 `CountryClientEvidence` 同 tick 记录 reference/worker hash、
      territory/cash/goods/technology/research 与 terminal receipt。比较器对 Country 行缺失、
      业务字段或 receipt 不同直接报 `country_client_evidence_mismatch`。启动器支持可见客户端
      自动 full-SoA 录制，并可用绝对起始 tick + 固定 tick 数消除墙钟录制的覆盖漂移。
- [x] **C3 排除 harness 开销的性能口径**：保留原始 `run_ms`，增加 writeback window、
      consume、idle wait、idle-adjusted 和 whole-window lower-bound 两套口径以及轮询数；
      `Invoke-AuthorityStageCHeadless.ps1` 用六个干净进程汇总调整后吞吐。C3 只回答吞吐，
      帧延迟结论只来自 C1。
- [ ] **阶段 C 正式证据包**：运行默认六次 C1、ACTIVE/OFF 各一份人工 C2 全量录制并比较、
      默认六次 C3；产物必须位于 `artifacts/runtime/authority-stage-c/<run-id>`。
      - 2026-09-09 Debug C1：`stage-c1-default-20260909-v2`，三对全帧 p50 差为
        `-0.802ms / -6.40%`、`-0.056ms / -0.45%`、`+0.132ms / +1.09%`，结论为
        `mixed_or_no_material_evidence`；ACTIVE 三轮 writeback lag 均为 2 天，worker fault 为 0。
      - 2026-09-09 C3：`stage-c3-default-20260909`，三对 adjusted days/s 差为
        `+12.33%`、`-24.44%`、`-9.09%`，结论为
        `mixed_or_no_material_throughput_evidence`。
      - 2026-09-10 C2：先有 `stage-c2-country-fixed100-20260910`（Country 证据 pass，
        66 个未声明 Climate 差异）。修完 `weather_field_init` extras 后重录
        `stage-c2-fieldinit-20260910`：同 seed/config、tick 121–220、各 100 ticks /
        240,000 行；`weather_field_init_arr` 0 差异；`country_slot_arr` 与
        `CountryClientEvidence` 仍 pass；ACTIVE writeback_applied_fields=40。
        其余 65 个气候场按一日滞后 / sliced weather / B8 ψ·风场 / 主线程 succession
        未回灌声明于 `tools/runtime/authority-stage-c-field-policy.json`
        （15% 余量，基线为本轮重录）。比较器 status=`pass`。这不是 Climate 数值对拍，
        也不是 D12。C1/C3 仍无稳定收益结论，阶段 C 正式证据包未关。

## 阶段 D：Country 接入 🔶

旧判断“POD 实现完整，只缺 Host 接线”已被生产语义盘点替代。D12 已完成 Country 后台
ACTIVE authority；当前剩余缺口集中在 Country–Economy D7 跨域事务闭环。

- [x] **D1 / K0-A 生产参考边界**：固定命令水位、边界、hash、receipt、intent/ACK 和首差异
      定位；`country_reference_trace_test.gd` 为 **failures=0**。
- [x] **D2 / K0-B 唯一生产核心**：同步 `NativeCountryRuntime::run_slice_core()` 仍是生产编排
      （大规模领土批走 staged SoA）。worker 命令公式收口到 `country_core_apply_command()`；
      `RuntimeCountryPodAuthority` 只做排队/plan/commit 适配，不再自持第二套 opcode switch。
- [x] **D3 / K1 完整命令核心**：20 类生产 opcode、`effective_day/sequence/submit_order`
      排序、seal 水位、批次 preflight/原子提交已进入共享核心；Host transport/receipt 见 D8
      （协议切片已有，完整 ACTIVE 仍未完成）。
- [x] **D4 / K2-E 基础 checkpoint**：PKCN v13 canonical payload、CPD2 ABI v2、PKSR v2
      Country section 已能 roundtrip；`runtime_country_save_roundtrip_test.gd` 为 **failures=0**。
      2026-09-09 又补齐 Host request lifecycle 的 CPD2 合并与恢复：Accepted pending state、
      terminal receipt、重复 request-id 防线所需的 request-id 水位随同一份 canonical PKCN
      generation/day/hash 保存；恢复 prepare 会校验 pending/terminal 与 request state 的一致性。
- [x] **D5 / K2-A 研究 peer 协议**：`CountryPeerContext/Intent/Result`、
      `PENDING/READY/APPLIED/REJECTED`、同日 continuation、重复 ACK 幂等、拒绝后重试和
      保存 barrier 已完成黑盒验证；`runtime_country_peer_bridge_test.gd` 为 **failures=0**。
      2026-09-09 新增 Host rejection continuation self-test：拒绝日提交 Country 侧语义、保持
      generation、设置次日 retry barrier；同日不重发，次日 request identity 改变，成功 ACK 后
      barrier 清零。
- [x] **D6 / K2-A 真实 peer adapter**：已在现有 Effect、Modifier 和 gameplay publication
      安全提交点消费 Country intent，并沿用原 request/idempotency identity 返回结果；SHADOW
      测试只回放结果，不产生真实副作用。Host ACTIVE adapter 已接线，但只有显式 ACTIVE + Country
      请求且实际授权后才可执行；D12 已将 Country 加入生产 `0x806`，因此 Country core ACTIVE
      与 D7 Economy 事务状态必须分别判断。
- [~] **D7 / K2-B Country/Economy 资产事务桥**：九条 typed path 与同步 Economy-owned
      coordinator 仍是生产路径。Host 已有内存 request/result transport、
      `enqueue_economy_origin_country_asset()`、`D7T1` transaction journal 编解码/恢复、
      identity 校验和 terminal 幂等缓存；Country plan 可发布请求，Economy 也可发布
      Economy-origin request。**2026-09-20**：补上同日闭环
      `prepare_economy_origin_country_assets()`——Economy stage 遇到
      `country_economy_asset_host_pending` / fiscal peer pending 时就地 prepare+retry，
      日等待前再 drain 一次；修复「Economy enqueue 后等次日 Country stage → Climate
      输入环满 → `climate_input_capacity_day_barrier` 永久钉日历」的 ACTIVE 死锁。
      **2026-09-22**：prepare 改为逐条出队；资源不足等失败发 `REJECTED` 终态而非
      清空队列留下 `CREATED` 孤儿；仍 pending 时 soft-complete ECONOMY，避免 research
      peer 把日历钉在 climate barrier 上。
      当前仅 fiscal 三种 operation 进入 M1 bridge gate，
      `country_economy_operation_gate_closed` 会明确拒绝其它未迁移 operation，不再伪造
      成功或静默切换第二个同步写者。Economy-owned fiscal peer journal 已完成，并在 PKEC v52
      独立 section 持久化 request identity 与 terminal result；fiscal escrow 与 journal
      都纳入 state hash。完整跨线程续跑仍只覆盖 M1，cohort/market/research/treasury 的 peer
      journal、reservation reconciliation、逐 operation gated rollout 和长程守恒/恢复证据仍未完成。D7T1
      恢复时，dispatched 但无 terminal 的请求会按固定排序重新入队并换绑新 session；
      旧 session 的迟到结果会被拒绝。D7 未因接线完成而放行。
- [x] **D7a / K2-B fiscal reserve continuation**：`prepare_fiscal_budgets()` 冻结按国家请求
      计划，`advance_fiscal_reservation()` 跨 Economy slice 逐国推进；保存/恢复中间态明确
      拒绝，专项回归 `economy_fiscal_reservation_continuation_test.gd` 为 **failures=0**。这只是
      Economy-owned 可续跑边界，不是 Host ACTIVE 放行。
- [x] **D8 / K2-C Host stage 与真实 SHADOW plan/replay**：`submit_country_commands` 在非
      `0x004` 下先写同步权威，再把 opcode 1–20 镜像进同一条 Host 编码路径（失败码
      `country_shadow_command_mirror_failed`，不回滚同步 admission）。同步 committed slice
      经 `export_pod_snapshot` → `country_core_hash_business_state` →
      `publish_country_reference`；worker commit 后字段级对拍（`country_parity_status` /
      `first_mismatch_day` / 双方 hash）。未知分叉不得标绿。SHADOW 不把 worker read-view
      写回 `MapData`。D12 后生产 Country grant 为 `0x004`，主线程不得等待 worker；测试授权用
      `set_country_sync_store_writes_forbidden` 只用于协议验证，不能替代生产 grant。
- [x] **D9 / K2-D CountryReadView 与稀疏发布（2026-09-09）**：C++ host 保存不可变
      `RuntimeCountryPodSnapshot`，以 `generation/patch_base_generation` 提供游标消费，首次
      bootstrap/跳代提供 full owner snapshot，连续代次只返回 changed cell/owner patch；
      `MapGenerator.get_country_worker_read_view()` 与 `WorldRuntimeHost` 主线程消费边界已接入，
      通过 `MapData.country_slot_arr` 更新后复用 `CountryFacade.country_committed`，不增加第二套
      通知路径。纯身份/研究捕获不会产生 territory cell patch。专项回归：
      `runtime_country_pod_test.gd` **failures=0**（源码静态约 36 个 `_expect`）。
- [x] **D10 / K2-E 保存恢复与交接（2026-09-10）**：CPD2/PKSR receipt 恢复仍在。Host
      `prepare/install/abort_country_authority_handoff`：drain 未完成 intent/asset/Accepted
      命令后切 owner；SYNC→WORKER 必须先发布 sync `export_pod_snapshot` checkpoint，缺失则
      失败并保持原 owner；成功推进 session epoch；WORKER owner 驱动 unique-writer 与跳过
      sync `run_country_slice`。完成时**不**改 `implemented_domain_mask`（仍 `0x802`；后由
      D12 升至 `0x806`）。prepare 期间 `begin_save` 返回 `country_authority_handoff_pending`。
      `runtime_country_host_protocol_test.gd` 现为 **42/0**（含 prepare/abort/install 往返与
      handoff unique-writer）。D10 ≠ D12：handoff 测试授权不能代替生产 Country ACTIVE。
- [x] **D11 / K3 正确性、故障和性能门禁**：headless 已有 `runtime_country_parity_test.gd`
      （默认 30 日 soak，可用 `PK_COUNTRY_SOAK_DAYS` 设为 1–100）、probe 公式对拍、
      多国家/中立地块 fixture，以及 rename/territory/research/tax/claim/technology 六类以上
      确定性命令双写、unique-writer、save capture、Host protocol。测试现在必须实际观察到
      `country_parity_compared=true`、`status=comparable` 且双方非零 hash 相等；零 comparison
      不再允许绿色退出。分叉必须带
      `country_parity_field` 归因。守恒仍以既有 ledger `0/0/0` 用例
      （`runtime_country_economy_transaction_test`、`treasury_construction_runtime_test`）为准。
      本轮重跑 `runtime_country_economy_transaction_test` 为 **43/0**；
      `treasury_construction_runtime_test` 的 funded/cashless/grouped success/failure 守恒断言
      全部通过，但该测试整体仍有 2 个既知失败：
      grouped-material 报价的 AND/OR 共享替代聚合（期望 `material_offsets=[0,1]` /
      一次扣 60）失败，归因是施工报价 planner，不是 Country SHADOW hash 或命令双写。
      2026-09-10 聚焦运行已证明独立 fixture 没有生产 Climate reference/input 边界时停在
      `country_parity_status=uncompared`；加固门禁因此按预期失败，而不是把“没有比较”当成通过。
      根因之一是 SHADOW 冷启动把 `adopt_reference_baseline` 写成 `plan.context.day`（worker
      计划日），而第一帧 trace 是生成期 `environment.day`：随后 `plan_day` 撞上
      `climate_day_not_monotonic`，Climate barrier 失败，Country 永远进不了对拍。现已改为
      用 environment day 收基线，日不对齐时只收基线、不放行 worker 日。
      `runtime_country_parity_test.gd` 现用 `WorldRuntimeHost` 生产路径做 comparable-frame
      门禁；6 格独立 fixture 只覆盖命令双写/probe，不再把无 Climate 输入的零比较标绿。
      当前正式路径门禁为 **32 checks / 0 failures**：默认 30 日
      `compared_days=30 matched_days=30 first_mismatch_day=-1`，扩展 100 日
      `compared_days=100 matched_days=100 first_mismatch_day=-1`；Host protocol 为
      **41/0**，Country save roundtrip 为 **36/0**，Country POD 为 **35/0**。长程推进曾在 day 7 暴露
      Effect/Bio 直接写 Country、未进入 SHADOW command ingress 的缺口，以及 POD 把
      command payload `domain` 误判为 runtime envelope domain；两处均已改走既有 Host
      mirror/按 opcode 校验。逐日 seal 现等待 WorldClock 的五类硬 barrier，NativeDaily 在
      continuation 完成时也推进 Climate reference generation；Host 只有在整日 preflight/commit
      成功或 Country 产生确定性终态拒绝后才消费到期命令，Climate 缺帧重试不再丢失一次性
      Effect/Bio ingress。day 92 的研究信号分叉还暴露并修复了零 sequence 镜像、reveal catalog
      缺失，以及生产/worker 证据日期分别使用实际 slice 日与 effective day 的语义漂移。
      C2 真实客户端已用相同 seed/config、绝对 tick 121–220 完成 ACTIVE/OFF 双录制：
      240,000 行完全对齐，Country slot 与业务 evidence 零差异、receipt 一致；全域比较另有
      66 个 Climate/Weather 未声明差异。其中 `weather_field_init` 已补 extras 回灌，其余
      按 B8/滞后写入 C2 field policy。生产 Country stage 性能
      使用正式 `60x40` / seed `20260718` / 4 countries，每日一个唯一 rename，共 100 个同步
      `run_slice_core()` 样本：native P95 `0.0243ms`、max `0.0446ms`，含 facade/event dispatch
      wrapper P95 `0.839ms`、max `1.095ms`，通过 `2ms/4ms` 门槛。证据位于
      `artifacts/runtime/country-d11-perf-100d-workload-20260910`。D11 完成；D10 交接亦已
      完成。随后由 D12 把 COUNTRY 写入 `implemented_domain_mask`。
- [x] **D12 Country 放行（2026-09-11）**：`implemented_domain_mask` 加入 COUNTRY，使
      Climate + Country + COMMIT = `0x806`。生产 `world_runtime_host.gd` 在
      `runtime_climate_authority_enabled` 下请求同一 mask；Country capture 不全则拒绝
      ACTIVE 启动。ACTIVE 冷启动与 SHADOW 一样把 `committed_day=-1` 无业务基线对齐到
      Host `start_day`；Climate park 日跳过 Country stage，避免 `country_day_not_contiguous`
      卡死整包 grant。同步 SUS / graph country slice 在 grant 后抑制；命令走 Host；read-view
      回写 `MapData.country_slot_arr`。`climate_authority_test.gd` **16/0**（grant 同授
      Climate+Country，抑制+回灌仍绿）；Host protocol **42/0**；protocol/pod 回归绿。
      不得以 handoff / `set_country_sync_store_writes_forbidden` 代替本放行。SHADOW fixture
      仍断言 `authoritative & 0x004 == 0`。

## 每个域的通用七步

E–J 六个域共用同一套步骤模板，下面各阶段只列**该域特有的难点**，不重复这七步：

| 步 | 内容 | 完成判据 |
| --- | --- | --- |
| 1 | 真实 plan/replay 替换诊断投影 | 算的是生产公式，不是 environment 投影或计数器 |
| 2 | 命令队列迁移：legacy opcode → POD | 逐条对照，无遗漏无多余 |
| 3 | ACK / 跨域屏障 | 需要 ACK 的路径能正确阻塞与恢复 |
| 4 | snapshot 类型 | 可整份传输 |
| 5 | 存档 section | roundtrip 测试绿 |
| 6 | 接入 `NativeSimulationHost` 真实 stage | ACTIVE 下真跑，不是 diagnostic runner |
| 7 | 跨域读取确认 + 按 2.8 六步放行 | mask 加该域 bit |

**迁移顺序由依赖决定**，不能随意调换：

```text
Modifier ──→ Effect ──→ Ideology
   │            │    └─→ Trigger ←── Events
   │            │
   └────────────┴─→ Economy（还依赖 Country 的冻结快照）
```

Modifier 最底层（其他域经 Effect 写它）；Effect 是跨域事务枢纽（Country / Ideology /
Technology 都靠它的 ACK）；Economy 最后，因为它同时依赖 Country 与 Modifier。

## 阶段 E：MODIFIER（第三个域）✅（E2–E8 完成）

**为什么排在其余域最前**：它是 Effect / Ideology / Economy 税率的共同下游，它不迁移，上面几个
域的写入路径就得跨 worker/主线程边界。

- [x] E1 `RuntimeModifierStore` + `RuntimeModifierPodState`
- [x] E2 真实双缓冲 plan/replay：capture、expiry、稳定排序、五个 opcode 执行、受影响
      bucket 重建和 deterministic state hash（`runtime_modifier_pod.{h,cpp}`）
- [x] E3 迁移 legacy 5 个 opcode：`APPLY`、`REMOVE`、`REFRESH`、`SET_STACKS`、
      `SET_MAGNITUDE`；command 使用 numeric definition/catalog 和固定 little-endian POD payload
- [x] E4 真实 Effect → Modifier ACK barrier：`OK`、`REJECTED`、`STALE_GENERATION`、
      `RETRY`，校验 request/transaction identity、target generation、effective day，缺失或
      溢出直接 discard plan
- [x] E5 immutable Modifier snapshot ring：generation 单调消费、catalog hash/domain shape 校验，
      不回灌 legacy ModifierRuntime
- [x] E6 独立 `MDF2` 存档 section：PDP4 不再重复写 Modifier；保留旧 PDP3 的一次性兼容迁移读取
- [x] E7 接入 `NativeSimulationHost` 的 `EFFECT → MODIFIER → ... → COMMIT` SHADOW stage，
      失败时不 swap、不发布 snapshot、不推进 generation
- [x] E8 放行（`0x846`；Host ACTIVE 唯一写者；snapshot 回灌 `ModifierRuntime`；抑制 `modifier_daily`）

**当前边界**：四域 ModifierStore 的 worker-side authority 已在 SHADOW 中运行；capture barrier
之后到达的 command 顺延到下一安全日。`implemented_domain_mask()` 现为
`CLIMATE|COUNTRY|TRIGGER_INPUT|IDEOLOGY|MODIFIER|EFFECT|EVENTS|COMMIT = 0xFFF`；worker 为 Modifier 唯一写者，snapshot 回灌
legacy `ModifierRuntime`（非 MapData）；主线程仅抑制 `modifier_daily`。

## 阶段 F：EFFECT 🔶

- [x] F1 `RuntimeEffectStore` + `RuntimeEffectPodState`
- [x] F2 独立 `RuntimeEffectPodAuthority` 完成 deterministic plan/replay、bounded command arena、
      stable command offset、plan hash 与幂等重放；未接入 Host 日循环
- [x] F3 六类 action 全部编译为 typed `RuntimeDomainIntent`：Modifier、Country、Economy、
      Gameplay、Publish Event、Custom Domain
- [x] F4 真实 ACK 状态机：`PLANNED / PREFLIGHTED / COMMITTED / ACKED / REJECTED /
      RESYNC_REQUIRED`，支持部分/重复 ACK、`RETRY`、`REJECTED`、`STALE_GENERATION`；
      Effect POD 不再制造 synthetic `OK` ACK
- [x] F5 独立 immutable snapshot：catalog hash/revision、metric slab/revision、instance 输入与
      generation、transaction/ACK 状态及 deterministic state hash
- [x] F6 独立 `EFP1` 存档 section（PKSR bit `1 << 7`）：pending transaction、ACK mask、
      plan/idempotency 信息 roundtrip；缺失、截断、版本、catalog、checksum 不匹配均原子拒绝
- [x] F7 接入 host 真实 stage（2026-09-11）：`execute_effect_worker_stage` 位于 Ideology
      之后、Modifier 之前；真实 Effect POD intents 在 catalog 非空且 stage 成功时替换
      diagnostic `run_effect` fixture 作为 Modifier 上游，Modifier ACK 回灌 Effect POD；
      主线程 transport（queue instance/metric/remove、poll intent、submit ACK）与
      `effect_pod_*` report 已接线；`implemented_domain_mask` 现为 `0x866`（含 EFFECT）；
      legacy `EffectRuntime` 仍是生产权威。空冷启动 catalog 不启用 stage，以免关掉
      Modifier E7 fixture 上游。
- [x] F8 放行（`0x866`；Host ACTIVE 唯一写者；snapshot 回灌 `EffectRuntime`；抑制 `run_effect_daily`；跨域 intent 主线程 pump）

**特有难点**：它是**跨域原子事务的枢纽**。Country 的 grant tech、Ideology 的三选一、
Technology 的里程碑都靠它的 ACK 完成。迁移它等于同时改动这几个域的提交路径，需要
"Effect 在 worker、消费者在主线程"的中间态设计。

**当前边界（F8/G8/H8/I8）**：`implemented`/`request` 均为 `CLIMATE|COUNTRY|TRIGGER_INPUT|IDEOLOGY|MODIFIER|EFFECT|EVENTS|COMMIT = 0xFFF`；worker 为 Effect 唯一写者；snapshot 回灌 legacy `EffectRuntime`；主线程抑制 effect daily；MODIFIER intents 在 worker 内 ACK，Ideology 与 Trigger 指向 EFFECT 的 intents 在 Effect stage 之后于 worker 内 ACK（另有主线程 pump 作为协议路径），其它 intents 主线程 pump+ACK。

## 阶段 G：IDEOLOGY ✅（G2–G8 完成；生产 ACTIVE）

- [x] G1 `RuntimeIdeologyStore` + `RuntimeIdeologyPodState`
- [x] G2 真实 worker plan/replay：`RuntimeIdeologyPodAuthority` 使用 copy-on-write
      next state、head cursor、固定 slice limit 和 same-day continuation；命令稳定排序为
      `effective_day -> source_priority -> producer_id -> sequence -> submit_order`。
- [x] G3 迁移 legacy 9 个 opcode：worker 只消费 numeric POD catalog/command，保留
      producer/sequence 高水位幂等和确定性三选一 offer。固定 opcode 为 `discover`、
      `grant points`、`open offer`、`choose offer`、`equip`、`unequip`、`promote`、
      `add understanding`、`set gate`。
- [x] G4 deferred Effect intent/真实 ACK barrier：equip、unequip、promote、level
      transition 和 active progression 只发带 `DEFERRED | REQUIRES_ACK` 的 typed intent；
      bridge 未就绪、generation 过期或 ACK 非 `OK` 时不写最终 ACTIVE/location/level/slot/synergy，
      不生成 synthetic ACK。
- [x] G5 immutable worker snapshot：捕获 Country technology/discovered/pending/research
      signal 与上一份已提交的 Economy class-opinion snapshot，并校验 catalog、class hash、revision、
      lane shape、country handle/generation 和 state generation。
- [x] G6 独立 `IDP1` ideology worker section：ABI、catalog/state hash、长度和 checksum
      原子校验；只恢复 worker ideology state，不从 `PDP3` 或同步 `PKID` 推导。
- [x] G7 接入 `NativeSimulationHost` SHADOW stage：Country 之后、Effect 之前执行，
      snapshot/intent/ACK 通过现有 publication contract 暴露；legacy ideology runtime 仍为
      生产参考 authority。
- [x] G8 放行（`0x876`；Host ACTIVE 唯一写者；snapshot 回灌 `NativeIdeologyRuntime`；
      抑制 `run_ideology_daily` / `ideology_should_run`；Ideology 的 EFFECT-targeted transition
      intent 在 Effect stage 之后于 worker 内 ACK，并保留主线程 pump 作为协议路径）

**当前边界（G8）**：`implemented`/`request` 均为
`CLIMATE|COUNTRY|TRIGGER_INPUT|IDEOLOGY|MODIFIER|EFFECT|EVENTS|COMMIT = 0xFFF`。ACTIVE 下 stage loop 里的
`RuntimeDomainId::IDEOLOGY` 分支是唯一写者（与 Country/Effect/Modifier 一起在 Climate park 日
跳过）；`_ideology_snapshots` ring 把 immutable snapshot 回灌 legacy `NativeIdeologyRuntime`，
UI/存档仍只读一个 runtime；`submit_ideology_commands` 在 worker 权威下只入 POD 队列，不再先改
legacy 队列。Ideology 仍使用上一份已提交的 Economy opinion snapshot，避免当日
Ideology↔Economy 循环依赖。SHADOW 模式的 G7 诊断 stage 原样保留。

**已知后续（G8 遗留）**：POD catalog 不携带 effect template，因此 UniqueSource Modifier template
replay 无法从 POD intent 重放——与 F8 Effect ACTIVE 下 Ideology 的同类缺口一致，不是 G8 的回归。
soak / C2 证据待 `Invoke-RuntimeTests.ps1` 补齐（见
`artifacts/runtime/authority-ideology-g8-20260913/EVIDENCE.md`）。

## 阶段 H：TRIGGER_INPUT ✅（H2–H8 完成；生产 ACTIVE）

- [x] H1 `RuntimeTriggerStore` + `RuntimeTriggerPodState`
- [x] H2 真实 plan/replay：`RuntimeTriggerKernel` 覆盖聚合、条件、游标/gap/resync、
      target generation、one-shot/repeat/cooldown、动态 branch binding、snapshot input、
      effect resolver/value mode、稳定 effect ID/fire sequence 和 Country payload 修正；
      legacy `TriggerRuntime::run_daily()` 委托同一纯 kernel。
- [x] H3 **POD 命令层**：固定 6 个 numeric opcode，命令带 request/producer/sequence、
      generation、requested/effective day 和固定 payload；保留 legacy Action 数值
      `1,2,3,4,10,11,12,13,14,15`。
- [x] H4 ACK：plan 生成 required ACK identity；commit 只接受真实 `OK` receipt，缺 ACK、
      retry、stale generation 和 rejected 都不提交；SHADOW bridge 不把 required ACK 列表
      当作 synthetic ACK。
- [x] H5 immutable POD snapshot：保存 source cursor/gap/resync、trigger states、distinct
      lanes、pending events/effects、ACK cursor、enabled state 和 dynamic branch bindings。
- [x] H6 独立 `TPD1` 存档 section：little-endian bounded codec、独立 ABI、catalog/state hash、
      checksum、shape/order/cursor/trailing-byte 校验；恢复失败保持旧 worker state 不变。
- [x] H7 接入 host 真实 stage：`NativeSimulationHost::execute_trigger_worker_stage()` 在
      stage order 的 `COUNTRY → TRIGGER_INPUT → IDEOLOGY → EFFECT` 位置消费排队的 Trigger
      POD 命令，跑真实 `plan_day` + `commit_day`（ACK 来自 `_trigger_acks`，不是空表），
      发布 `trigger_pod_*` 诊断，并与 Climate 一起 park；catalog 未配置 / 输入未就绪时
      soft-complete，不扣住 Climate 的 grant。SHADOW 诊断桥接原样保留，两条路径共用
      `RuntimeDomainAuthorityRunner::_trigger_authority`，不会 double-fault。
- [x] H8 放行（`0x87E`；worker 为 Trigger 唯一写者；`RuntimeTriggerSnapshotRing` +
      `TriggerRuntime::apply_pod_snapshot()` 回灌 legacy `TriggerRuntime`；主线程抑制
      `run_trigger_daily` 与 `trigger_should_run`；`submit_trigger_events/snapshots`、
      `set_trigger_enabled`、`reconcile_trigger_branch_bindings`、`resync_trigger_source`
      在权威下只写 POD 队列）

**当前边界（H8）**：`implemented`/`request` 含 `TRIGGER_INPUT(0x008)`。worker 拥有聚合与
effect 发射；主线程仍是 **Trigger→Effect 投递游标** 的所有者——`handoff_trigger_effects()`
读回灌后的 facade，成功投递后额外发一条 `ACK_EFFECTS` POD 命令让 worker 的 pending effect
队列同步收缩，`apply_pod_snapshot()` 用 `std::max` 夹住 `_acked_effect_id`/`_next_effect_id`
防止回灌把游标退回去造成重复派发。Trigger 的 effect intents 指向 EFFECT 且需要 ACK：
同一 session 里 EFFECT 也被授予时 Effect stage 之后由 `ack_trigger_intents_in_worker()`
在 worker 内 ACK，另有 `poll_trigger_worker_intent` / `submit_trigger_worker_ack` 主线程
pump 作为协议路径。触发日第一次访问必然 `ack_barrier_incomplete`（Trigger 排在 Effect
之前），这被列入 soft-complete：intent 已发布、ACK 下一次访问到位、`discard_plan()` 重放
同一批 intent id，所以是收敛的而不是卡死。

## 阶段 I：EVENTS ✅（I1–I8 完成；worker journal 为 ACTIVE 消费源）

- [x] I1 `RuntimeEventsAuthority` + `RuntimeEventsSnapshot` + bounded snapshot ring
- [x] I2 真实 deterministic plan/replay：APPEND_BATCH、ACK_CONSUMER、容量淘汰和
      FNV-1a state hash；legacy journal event id 作为 bridge 幂等证据
- [x] I3 命令层：固定 little-endian ABI、ABI/count header、单批最多
      `RUNTIME_EVENTS_MAX_BATCH_RECORDS`，worker preflight 允许 Events probe
- [x] I4 ACK：ACTIVE 下 `ack_gameplay_events()` 只提交稳定 UTF-8 consumer key 的
      typed ACK，poll 默认游标直接读取 worker snapshot；SHADOW/回退才保留 legacy cursor
- [x] I5 immutable snapshot：generation/hash/day、事件列、consumer ACK 列和幂等证据列；
      `poll_runtime_events_snapshot(after_generation)` 读取后立即释放 ring slot，旧 READY
      槽在 ring 满时可被最新写者回收
- [x] I6 独立 `EVT1` 存档 section：checksum、截断/版本/ABI/状态 hash 校验，restore
      事务性拒绝；不从 legacy `PDP3` 推导 Events POD state
- [x] I7 接入 `NativeSimulationHost` 日阶段、report、GDExtension 绑定和 GDScript wrapper；
      Events 可在 SHADOW probe 或 ACTIVE authority 中运行
- [x] I8 放行（`0xFFF`；EVENTS 进入 `implemented_domain_mask` 并在 ACTIVE stage loop 里拥有
      自己的阶段位；请求掩码含 EVENTS 时 `start()` 强制打开 `_events_probe_enabled`，否则
      阶段会永远 soft-complete 而不产出 snapshot）

**当前边界（M3）**：请求掩码授予 EVENTS 后，`RuntimeEventsAuthority` 是唯一生产 journal。
主线程 producer 只提交 APPEND_BATCH；legacy deque 不再追加，poll/replay/ACK 从 worker
snapshot 和 consumer cursor 读取。ACTIVE Events 对畸形批次 fail-closed，并保留同一 sealed
day 重试，不能 soft-complete 后发布半成品。SHADOW/显式回退仍保留 legacy journal。

GAMEPLAY_EFFECT typed ingress 会在 worker 内校验固定 payload，生成私有 Events APPEND_BATCH，
随后由 EVENTS stage 原子提交。独立 `GMP1` section 保存 generation、pending/terminal 计数和
state hash；pending packet 本体仍由 PKSR 通用 pending-command section 保存并交叉校验。

## 阶段 J：ECONOMY（最大工程）⬜

2026-09-13：J2-B Phase 1 地基已落地（不等于 J2 完成或 ACTIVE 放行）：

- 新增 `RuntimeEconomyPodAuthority`（epoch input、13-stage cursor、committed
  header、outbox/inbox 骨架）。
- Host 增加 `execute_economy_worker_stage` 与 `publish_economy_stage_reference`
  （SHADOW only；**不**改 `implemented_domain_mask`，仍为 `0xFFF`）。
- BUILDING_PLAN 经 Godot-free `economy_kernel_prepare_building_plan` + executor
  边界进入 sync body（无第二套公式）；J2-A `population/100` 投影已删除。
- `RuntimeEconomyReplayReport.STAGE_COUNT` 扩到 13；`parity_ready` 仍为假。

2026-09-13 Phase 2-6（CRITICAL）：生产 mask `0xFFF` 含 ECONOMY 后，主线程
`economy_should_run` 抑制与 worker StageOps 哈希桩并存会导致经济停摆。修复：
`worker_run_compact_slice` + `attach_economy_production_runtime`；ACTIVE 日路径
在 ECONOMY 授予时每轮最多 64 次 compact slice；StageOps 恒 mutate=false；未挂接
production runtime 时 fail-open 回 sync。POD `submit/poll` 为 Phase 4 脚手架；
生产命令仍走 sync `submit_commands` 直至 opcode 全量抽出。

2026-09-13 Phase 2–6（续）：

- **Phase 2**：sync `run_slice_internal` 在 TRADE_SETTLE…AGGREGATE_PUBLISH
  各 stage 成功完成后（与 BUILDING_PLAN 相同的 SHADOW-only 守卫）发布
  `publish_economy_stage_reference`；`work_units=cell_count` 与 StageOps
  `!mutate` 对拍。新增 11 个 Godot-free named kernel TU 桩（dispatch/document）；
  生产突变仍走 compact slice / StageOps 主路径。
- **Phase 3**：worker 权威时 D7 gate 全开；报告字段
  `economy_pod_operation_gate_mask` 可观测（见
  `runtime_economy_d7_gate_test.gd`）。
- **Phase 4**：POD `queue_command` 准入 opcode∈[1,23]、session/generation
  失配 → `RejectedAtAdmission`；`commit_pending_commands` 在 `commit_epoch`
  排水（BUILD_CANAL 无 token → `RejectedAtExecution`）；重复 `request_id`
  返回既有 terminal。GDScript：`runtime_economy_opcode_ack_test.gd`。
- **Phase 5**：ACTIVE compact-slice 成功与 `commit_epoch` 均写入
  `_snapshot_ring`；ECP1 ABI4 已含 `operation_gate_mask`、业务摘要与 committed
  cohort/market ledger mirror。ABI4 恢复先校验独立 ledger hash 和页拓扑，失败不替换
  live committed state；ABI1-3 恢复会清空旧的 ABI4 state。
- **Mask**：保持 `0xFFF`（含 ECONOMY），**不再翻转**。

- [x] J1 `RuntimeEconomyStore` + `RuntimeEconomyPodState`
- [~] J2 真实 plan/replay：Phase 2 已接全 stage SHADOW 参考哈希 + named kernel
      TU 桩；生产前进仍走 compact slice（非 13-TU StageOps mutate）
- [~] J3 迁移 legacy **23 个 opcode**：POD 准入脚手架已齐；执行仍委托 sync
      `submit_commands` / compact slice 公式 owner
- [~] J4 ACK：Host POD receipt + `commit_pending_commands` 已接线；pipeline
      ack 槽仍空
- [~] J5 snapshot：双缓冲 ring 已在 ACTIVE/`commit_epoch` 发布 header 与业务
      摘要；committed cohort/market ledger 已有独立 POD owner，完整 building/trade 等
      snapshot 尚未迁移
- [~] J6 **PKSR ECONOMY section**：bundle 已有可选 ECP1 ABI4，保存 committed
      cohort/market ledger mirror 并原子恢复；完整生产存档仍在 legacy
      `economy_runtime_persistence_*`
- [~] J7 接入 host 真实 stage：ACTIVE compact-slice + SHADOW
      `execute_economy_worker_stage`；ECONOMY 已在 `0xFFF`
- [ ] J8 放行（soak / 业务摘要 / opcode 全量抽出）

**四个特有难点**（这也是它排在最后的原因）：

1. **冻结 epoch 与一日滞后的交互**。epoch 会跨多天冻结 country 快照，而 worker 权威本身又滞后
   一日。两者叠加的语义必须先定义清楚，否则经济结算读到的 country 状态会漂移。
2. **它已经是并行的**。`worker_enabled` 开启的是 `parallel_for_range` 按 cell 分 task
   （`parallel_dispatcher.h:64+`），与 POD worker 是两套。迁移要决定：POD worker 内部继续
   用这套并行，还是改成 POD worker 的任务模型。**这不是"要不要迁"的问题，是"怎么迁"的问题。**
3. **守恒审计不能降级**。`aggregate_publish` 的 VERIFY 相位
   （`economy_runtime_publish.cpp:322+`）失败会 `_fatal=true` 并让 GDScript 侧
   `world_clock.pause(true)`。搬到 worker 后，这条"审计失败立即暂停游戏"的链路要跨线程重建。
4. **13 个 stage 的顺序契约**。`BUILDING_PLAN → … → AGGREGATE_PUBLISH` 的主序（2.7.2）在
   worker 侧要逐 stage 提取，与 Climate 的九个 pass 是同一类工作，但 stage 数更多、跨域读取
   更密。

## 阶段 K：三个无 store 的域 ⬜

全量迁移要求 `implemented_domain_mask` 达到 `0xFFF`，所以这三个也必须有结论——但它们的"迁移"
不是搬状态，而是确认语义。

- [ ] **K1 GAMEPLAY_EFFECT**：当前无 store，`run_gameplay_effect` 只递增 generation/work_units
      （`runtime_domain_pod.cpp:493`）。需确认它是一个真实域还是历史占位；若是前者，补齐七步；
      若是后者，从枚举中移除并调整 `RUNTIME_ALL_DOMAIN_MASK`
- [ ] **K2 VISUAL**：worker 不得访问 Godot 对象，所以它**不可能**成为 worker 权威。需要的是把
      "intent 生产"迁进 worker、"intent 消费"留在主线程，并明确它在 mask 里代表哪一半
      （当前 SHADOW 刻意不发布 intent，`native_simulation_host.cpp:4183`）
- [ ] **K3 INPUT_CAPTURE**：本就是只读快照 + 校验，无可变状态。需确认它在 `0xFFF` 语义下算
      "已实现"的判据是什么

## 阶段 L：整图收尾 ⬜

- [ ] L1 `implemented_domain_mask` 达到 `0xFFF`（前置：D–K 全部完成）
- [ ] L2 整图 ACTIVE：`start()` 不传显式 mask 的路径打通
- [ ] L3 达成 1.2 的全部硬约束：`main_wait_on_sim_us=0`、50 权威模拟日/秒、
      worker 停顿不造成帧尖峰
- [ ] L4 **一日滞后的全局语义**：十二个域全在 worker 后，跨域读取不再有"主线程读滞后值"的
      问题，但玩家输入到生效的延迟需要重新评估
- [ ] L5 legacy 路径删除 + 更新 `runtime-deletion-inventory.md`

---

# 第四部分：当前状态

本部分对着第三部分的任务表讲"到哪了"。**每个结论都能追到 A–L 里的具体条目。**

## 4.1 一句话与进度

十二个域的全量迁移里，**Climate、Country、Modifier、Effect、Ideology、Trigger 已放行为生产
ACTIVE，Events 以 worker 镜像形式放行（legacy journal 仍是消费源）；Country 的 D7 Economy
跨域事务仍未闭环；Economy 仍主要是诊断投影，3 个域待定语义**。

```text
A 基础设施       ████████████ 完成
B CLIMATE        ████████████ 完成（B8 收口）
C 测量能力       █████████░░░ C1/C3 无稳定收益；C2 field-init 已修且比较器 pass
D COUNTRY        ████████████ D1-D12 完成；生产 ACTIVE（0x806）
E MODIFIER       ████████████ E2-E8 完成；生产 ACTIVE（0x846）
F EFFECT         ████████████ F2-F8 完成；生产 ACTIVE（0x866）
G IDEOLOGY       ████████████ G2-G8 完成；生产 ACTIVE（0x876）
H TRIGGER_INPUT  ████████████ H2-H8 完成；生产 ACTIVE（0x87E）
I EVENTS         ████████████ I1-I8 完成；生产 ACTIVE（0xFFF，worker 镜像）
J ECONOMY        ██████░░░░░░ Phase2-6：ACTIVE compact-slice + stage refs + opcode/ECP1 脚手架；13-TU mutate 未完成
K 三个无 store   ░░░░░░░░░░░░ 未开始
L 整图收尾       ░░░░░░░░░░░░ 未开始
```

按逐域模板算，阶段 J（Economy）与阶段 K 是这轮迁移剩余工作量的主体，另加 Events 的消费者
迁移；SHADOW 组件完成不等于生产 authority 放行。

**Climate、Country、Modifier、Effect、Ideology、Trigger、Events 与 Economy 是当前生产
中真实承担 gameplay 权威的 worker 域（Economy 经 compact-slice 复用 sync 公式 owner）。**
Country core 已由 Host worker 承担；同步 Economy-owned 资产 coordinator 仍是 D7 的生产
peer。Events 只是 worker 侧镜像，legacy journal 仍是消费源。其余未放行域仍是
协议切片、SHADOW 或诊断实现，COMMIT 是屏障机制本身。

## 4.2 域成熟度（对应任务表 B–K）

| 类 | 域 | 一句话 | 任务表 |
| --- | --- | --- | --- |
| **第 1 类：生产权威** | CLIMATE、COUNTRY、COMMIT | ACTIVE 下真实承担，在 `implemented_domain_mask` | B + D12 |
| **第 2 类：共享核心与协议切片** | （原 COUNTRY 已升入第 1 类） | — | — |
| **第 1 类：生产 ACTIVE** | CLIMATE、COUNTRY、TRIGGER_INPUT、IDEOLOGY、MODIFIER、EFFECT、EVENTS、ECONOMY、COMMIT | 生产 request `0xFFF`（EVENTS 为 worker 镜像；ECONOMY 为 compact-slice ACTIVE） | 已放行 |
| **第 3 类：SHADOW/POD 迁移中** | ECONOMY（13-TU StageOps） | compact-slice 已 ACTIVE；独立 stage TU / opcode POD 仍在迁 | 阶段 J |
| **第 4 类：无 store** | GAMEPLAY_EFFECT、VISUAL、INPUT_CAPTURE | 结构上没有可迁移状态，需确认语义 | 阶段 K |

「SHADOW/POD 迁移中」表示代码可在 worker 侧运行并产出协议/对照数据，但尚未取得生产
authority；Modifier、Ideology 和 Trigger 的 plan/replay、ACK、snapshot 与独立存档已经完成，
各自 legacy runtime 仍负责生产写入。Trigger 的 worker effect intent 只用于 parity 和 ACK 诊断，
不会替代主线程 Effect 消费，也不会回灌同步 `TriggerRuntime`。

逐域 × 八维度：

| 域 | POD store | plan/replay | opcode | ACK | snapshot | save | Host stage | mask |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| CLIMATE | 有 | **真实** | 定义 5 个，**无消费者** | 协议层有 | 有 | CLM2 | **ACTIVE 真 stage** | **在** |
| COMMIT | 无（barrier） | 真实 | — | — | 有 | PKSR envelope | 有 | **在** |
| COUNTRY | 有（worker CountryCore + read-view） | **worker 走 `country_core_apply_command`；ACTIVE 下 Host worker 负责生产** | 20 个均已编码/core apply；staged SoA 保留为同步回退 | Effect/Modifier adapter 已验证；M1 fiscal 已有 Economy-owned peer journal，其余 D7 coordinator 仍为同步生产 peer；Host transport 与 D7T1 journal 已接线 | immutable ReadView 与稀疏 patch 已验证 | CPD2 v2 / PKCN v13；D7T1 Host transaction journal + PKEC v52 fiscal peer journal 已实现，非 fiscal peer recovery 尚未完成 | D10 handoff+unique-writer；D12 ACTIVE | **在（0x004）** |
| MODIFIER | 有（四域隔离） | **真实 SHADOW 双缓冲 plan/replay** | 固定 POD payload；legacy 5 已迁移 | **真实 Effect→Modifier ACK barrier** | immutable ring | **MDF2**（PDP4 不重复写） | **SHADOW 完整 stage** | 不在 |
| EFFECT | 有 | **独立真实 POD；Host SHADOW 日 stage（F7）** | 6 类 action | 真实多 adapter 状态机 | 独立 immutable | EFP1 | **SHADOW 完整日 stage**（Ideology 后、Modifier 前；fixture Effect→Modifier 在 POD catalog 非空时停用） | 不在 |
| IDEOLOGY | 有 | **真实双缓冲 plan/replay；ACTIVE 唯一写者** | 固定 POD payload；legacy 9 已迁移 | **真实 Effect ACK barrier；无 synthetic ACK**；ACTIVE 下 Effect stage 后 worker 内 ACK + 主线程 pump | immutable snapshot ring，回灌 legacy `NativeIdeologyRuntime`（Country/Economy 输入校验） | **IDP1**（`1 << 8`，不从 PDP3/PKID 恢复） | **ACTIVE 真 stage**（Country 之后、Effect 之前）；SHADOW 诊断 stage 保留 | **在（0x010）** |
| TRIGGER_INPUT | 有 | **真实 SHADOW plan/replay** | 6 个固定 opcode；legacy Action `1,2,3,4,10,11,12,13,14,15` 保留 | required ACK + 真实 receipt barrier | immutable POD snapshot | **TPD1**（独立 section，`1 << 4`） | **SHADOW parity bridge** | 不在 |
| ECONOMY | 有（committed cohort/market mirror） | ACTIVE compact-slice + SHADOW StageOps；全 stage reference + named kernel TU 桩 | legacy 23；POD 准入 1..23 | Host POD receipt + commit_pending_commands | ring header + 业务摘要（ACTIVE/`commit_epoch`） | **ECP1 ABI4：gate + 摘要 + committed ledger；完整 PKEC 业务态未迁** | ACTIVE compact-slice + SHADOW `execute_economy_worker_stage` | **在（0x100 / 0xFFF）** |
| EVENTS | 有 | **真实 ACTIVE deterministic plan/replay** | APPEND_BATCH、ACK_CONSUMER、CONFIGURE_CAPACITY、CLEAR_RESET | **worker-owned cursor** | **immutable snapshot ring** | **EVT1** | **ACTIVE fail-closed stage** | **在（0x200）** |
| GAMEPLAY_EFFECT | 有（transaction header + pending packet） | typed decode → Events plan | Effect gameplay/publish opcode | terminal after downstream commit | report snapshot | **GMP1** | handler 已实现，待 M5 grant | 不在 |
| VISUAL | 无（intent） | 诊断 | 无 | 无 | — | 无 | SHADOW 刻意不发布 | 不在 |
| INPUT_CAPTURE | 无（只读快照） | 校验 | — | — | 有 | — | 两模式均校验 | 不在 |

一条容易误读的：**「legacy N opcode」指主线程 runtime 的命令入口，不是 worker 队列**。
Economy 有 23 个 legacy opcode 不代表它的 POD 迁移靠前，它的 POD 侧仍是诊断投影。

### CLIMATE 细节

- **执行**：ACTIVE 真 stage（`native_simulation_host.cpp` 的 ACTIVE Climate 分支，约
  `execute_day_plan` 内 `climate_authority_requested` 段）。
- **注意**：pipeline / authority runner 里另有一份 climate，那是**诊断投影**
  （`runtime_domain_pod.cpp` / `runtime_domain_authorities.cpp` 注释写明），不是权威
  路径。对拍和排障只应看 `RuntimeClimateAuthority`。
- **悬空件（已清）**：`RuntimeClimateCommand` 的 5 个 opcode 全仓库只有定义处、
  无消费代码；2026-09-11（B8-6）连同 `RuntimeClimateIntentOpcode` 一并删除，
  协议头留下"命令枚举必须有消费者"的说明，防止同类空枚举回潮。
- **抑制**：`climate_worker_authoritative()` 为真时主线程跳过**整张** native daily /
  schedule graph，而不是历史文档写的“14 个节点逐一抑制”。

### COUNTRY 细节（D12 已放行，D7 仍在迁移）

生产核心已经统一，K2-A peer 链、K2-B 同步资产 coordinator、K2-D read-view 发布边界和
D12 Country ACTIVE 已完成；未完成的是 Country–Economy 事务的跨线程 continuation、持久化和
Economy 正式 ACTIVE 接管：

- **已有**：`CountryCore`、同步 `run_slice_core()`、20 opcode、boundary seal、生产排序、原子
  preflight、PKCN v13/CPD2 v2，以及 K2-A 的 peer identity、ACK、同日 continuation 和保存
  barrier。peer bridge / Country verifier 专项以 **failures=0** 为准（断言数运行时累加）。
- **已补齐**：真实 Effect/Modifier/gameplay publication adapter；Country/Economy 九类资产操作
  的统一 typed bridge；以及生产路径上的 **同步** Economy-owned coordinator
  （research / fiscal / cohort cash / market goods / treasury spend）。
- **已补齐（2026-09-09）**：`get_country_worker_read_view(after_generation)` GDExtension
  facade、generation 游标、连续代次稀疏 owner patch、跳代 full snapshot、MapGenerator 转发、
  WorldRuntimeHost 的 ACTIVE-gated 消费和既有 country_committed 复用。修复了重复 capture
  总是重置 patch base 并全量发布的缺陷；后续 capture 只在 owner 实际变化时设置 territory dirty。
- **已补齐（2026-09-09，K2-C 协议切片）**：Host Country 批量 admission、整批容量预检、
  单调 request identity/submit order、worker 数值命令 packet 编码，以及 peer intent 的 typed
  opcode/target-domain 映射；Host worker 命令排序也已统一为
  `(effective_day, sequence, submit_order)`。该实现只在实际 Country worker authority 下接管入口；未授权仍由
  同步 `NativeCountryRuntime` 处理。完成时 `implemented_domain_mask` 仍为 `0x802`（后由 D12
  升至 `0x806`）。
- **已补齐（2026-09-10，D10）**：handoff owner 驱动 unique-writer / 跳过 sync country slice；
  SYNC→WORKER 强制发布 sync checkpoint；abort 已导出；Host protocol 现为 **42/0**。D10 当时
  不改 mask；生产 Country ACTIVE 由 D12 放行。
- **已补齐（2026-09-11，D12）**：`implemented_domain_mask` 与生产 request 均为 `0x806`；
  ACTIVE 冷启动 Country 基线对齐；Climate park 日不推进 Country；`climate_authority_test`
  **16/0**。
- **权威结论**：`RuntimeCountryPodAuthority` 是 Host worker adapter；命令公式在
  `country_core_apply_command()`。生产默认在 `runtime_climate_authority_enabled` 下由 worker
  承担 Country（granted `0x004`）；关掉开关则退回同步 `NativeCountryRuntime`。
  D7 未完成不影响 Country core ACTIVE，也不应通过修改 `implemented_domain_mask` 回滚 Country。

### 第 3 类未放行域细节

除 Modifier 外，未放行域仍以诊断投影、协议切片或独立 SHADOW authority 运行；它们不能被
解释为 `implemented_domain_mask` 已授予生产权威。

### MODIFIER 细节（E2–E7）

- **执行**：`NativeSimulationHost::execute_day_plan()` 固定在 `EFFECT → MODIFIER → ... → COMMIT`
  中运行完整 Modifier SHADOW plan/replay；capture 后到达的 command 顺延下一安全日。
- **命令与 ACK**：五个 legacy opcode 通过 numeric catalog 和固定 little-endian POD payload
  进入 shadow pipeline；Effect intent 只在 Modifier stage 产生真实 ACK，缺失/溢出/身份错误
  使 plan 失败。
- **发布**：commit 成功后发布 immutable snapshot，generation 单调递增；失败时不 swap、不
  发布 snapshot、不推进 generation。
- **权威边界**：legacy `ModifierRuntime` 仍是主线程生产 authority，worker snapshot 不回灌；
  `implemented_domain_mask()` 现为 `0xFFF`（含 TRIGGER_INPUT|IDEOLOGY|MODIFIER|EFFECT|EVENTS）；
  F8/G8/H8/I8 已放行。
- **存档**：新格式为 PDP4 + 独立 `MDF2`（save bit `1 << 5`），旧 PDP3 仅做一次性兼容迁移。

未放行域的诊断/SHADOW 实现如下：

| 域 | 诊断实现干了什么 | 证据 |
| --- | --- | --- |
| EFFECT | legacy store 仍为 SHADOW/reference；独立 POD authority 已完成 F2-F7：Host 日循环在 Ideology 之后跑真实 plan/commit，Modifier 上游可切换到 Effect POD intents；未进入 ACTIVE mask | `runtime_effect_pod.{h,cpp}`、`native_simulation_host.{h,cpp}` |
| IDEOLOGY | 独立 POD SHADOW authority：9 opcode、确定性排序、bounded slice/continuation、deferred Effect intent 和真实 ACK barrier；legacy runtime 仍为生产参考 | `runtime_ideology_pod.{h,cpp}`、`native_simulation_host.{h,cpp}` |
| TRIGGER_INPUT | 共享 Trigger kernel 的真实 POD plan/replay、6-opcode 命令层、ACK barrier、immutable snapshot、TPD1 save 和 SHADOW parity；主线程 `TriggerRuntime` 仍是生产 authority | `runtime_trigger_kernel.{h,cpp}`、`runtime_trigger_pod.{h,cpp}`、`native_simulation_host.{h,cpp}`、`world_ext_trigger.cpp` |
| ECONOMY | 从 country snapshot 复制 treasury；简化 population→production 投影 | `runtime_domain_pod.cpp:507+`、`runtime_domain_authorities.cpp:581+`（注释："real Economy authority will replace"） |
| EVENTS | ACTIVE 唯一 journal：确定性 append/ACK、容量淘汰、snapshot 与 EVT1 restore；legacy API 路由到 worker snapshot | `runtime_events_authority.{h,cpp}`、`world_ext_events.cpp`、`native_simulation_host.{h,cpp}` |

**ECONOMY 额外缺独立 POD 存档** → J6：PKSR bundle 已有 Trigger 等独立 domain section，
但仍没有 Economy POD section；Economy 存档仍全在 legacy `economy_runtime_persistence_*`。

### 第 4 类三个

- **GAMEPLAY_EFFECT**：生产 Host 已有 typed ingress、严格 payload 校验、Events publication
  和 GMP1 transaction section；通用 `runtime_domain_pod.cpp` 投影仍只用于诊断。该 bit 保持
  不在 `implemented_domain_mask`，直到 M5 的 ACTIVE 证据齐全。
- **VISUAL**：只有 `RuntimeVisualIntent`。SHADOW 下**刻意不把 shadow intents 泄漏到 visual
  ring**（`native_simulation_host.cpp:4183`）。
- **INPUT_CAPTURE**：只读快照，两种模式都只做校验。

## 4.3 测试与验收现状

### 怎么跑

```powershell
# 统一 runner：25 个 runtime_* + dots_completion_gate（共 26；长期验收看 failures=0）
tools\runtime\Invoke-RuntimeTests.ps1

# 单个测试
godot --headless --path Project/project-keynes --script res://tests/<name>.gd --quit

# Climate SHADOW 对拍
tools\runtime\run_climate_parity.ps1

# 性能录制（CLI 参数在 -- 之后，不是环境变量）
godot --headless --path Project/project-keynes --script res://tests/headless_perf_record.gd -- days=50 speed=50

# 玩家存档复现：加载存档 → 无头续跑 N 天（见下节"存档复现入口"）
tools\runtime\Invoke-SaveReplay.ps1 -Slot autosave -Days 60
tools\runtime\Invoke-SaveReplay.ps1 -SavePath C:\tmp\day2740.pksv -Days 20 -Speed 10
```

### 存档复现入口（2026-09-22 新增）

在此之前无头能力是断的：`headless_perf_record.gd` 只能从新开局跑，
`game_save_roundtrip_test.gd` 只能用固定槽位续跑 6 天，**没有任何入口能回放玩家崩溃
现场**。这是"玩家报障后无法交给 AI 复现"的根因，不是工具缺失的小事。

`tests/headless_save_replay.gd`（由 `GameFlowService` 按 `PK_SAVE_REPLAY=1` 注入）走
生产 `GameFlow.begin_load_game` → `player_game.tscn` → `GameSaveCoordinator` 恢复路径，
不另写一套 restore，所以复现行为与玩家一致。

| 环境变量 | 默认 | 说明 |
| --- | --- | --- |
| `PK_SAVE_REPLAY` | — | `=1` 注入 runner |
| `PK_SAVE_REPLAY_SLOT` | `autosave` | `manual_1\|manual_2\|manual_3\|autosave` |
| `PK_SAVE_REPLAY_DAYS` | 30 | 续跑天数 |
| `PK_SAVE_REPLAY_SPEED` | 20 | 时钟倍速 |
| `PK_SAVE_REPLAY_DAY_TIMEOUT_MSEC` | 60000 | 单日墙钟上限，超过判为卡死 |
| `PK_SAVE_DIR` | — | 存档目录重定向，**仅调试构建生效**；包装脚本用它把任意 `.pksv` 暂存到临时目录，避免覆盖玩家槽位 |

失败判据是三条，缺一不可（只判"跑满 N 天"会出假绿）：

- 恢复没成功：country / economy 未 bootstrapped，或请求了后台权威却停在 STOPPED/FAULTED。
- 经济 fatal。
- 单日墙钟超时（卡死）。
- 跑完但 `newest_state_day` 没推进 —— 时钟走了而模拟没走，等于什么也没验证。

三种失败都写 forensics JSON（见下节），并打印唯一一行机器可读结果
`[save-replay/result] {...}`；包装脚本按这个前缀解析，不要改前缀。

### 事故取证产物（2026-09-22 新增）

`scripts/game/runtime_forensics.gd` 是 fatal 与 watchdog 共用的取证模块。落盘两份
相同内容：`user://diagnostics/<tag>_<时间戳>.json` 逐次留存，
`tmp/runtime_forensics_<tag>.json` 固定文件名供 agent 直接读。

| tag | 触发 |
| --- | --- |
| `economy_fatal` | `WorldRuntimeHost._observe_economy_fatal`，**任何**经济 fatal reason，每种 reason 一次 |
| `stall` | 权威日停在同一天超过 `stall_watchdog_threshold_msec`（默认 15s），之后每 30s 复抓 |
| `save_replay_fatal` / `save_replay_stall` / `save_replay_restore_failed` / `save_replay_ok` | 存档回放的四种终局 |

内容包含 economy 现场键（含 `fatal_context`、`audit_incomplete`）、守恒分桶、country
报告、runtime thread 报告（`authoritative_domain_mask` / host state / fault code）与时钟。
**权威 mask 必须在里面**：跨域 fast path 走不走由它决定，没有它就无法判断一次边界拒绝
是否合理。

watchdog 只观察不干预 —— 不暂停时钟、不改权威，避免看门狗本身成为新的行为变量。

Godot 可执行文件由 `GODOT_BIN` 或 `tools/runtime/Resolve-GodotBin.ps1` 定位。

### 关键测试

| 测试 | 覆盖 | 输出 |
| --- | --- | --- |
| `runtime_protocol_guard_test.gd` | ABI v3、SHADOW 启动、ACTIVE 门禁（A1） | `%d checks, %d failures` |
| `runtime_climate_parity_test.gd` | 可比性契约（B2） | 同上 |
| `climate_parity_probe.gd` | **SHADOW 对拍主力**，产出分叉矩阵 CSV（B2） | `compared_days=... matched_days=...` |
| `climate_authority_test.gd` | per-domain ACTIVE 三门禁（B6） | `%d checks, %d failures` |
| `climate_authority_soak_probe.gd` | **ACTIVE soak 主力**（B6） | `[soak/done] ticks=... drops=...` |
| `runtime_climate_save_roundtrip_test.gd` | CLM2 存读（B5） | `%d checks, %d failures` |
| `runtime_worker_source_scan_test.gd` | **worker 不得依赖 Godot/MapData**（A5） | PASS 或 push_error |
| `runtime_thread_isolation_test.gd` | 线程 API、三模式（A5） | `%d checks, %d failures` |
| `native_daily_graph_order_test.gd` | 图节点顺序与 C++ 常量一致 | `PASS ... (%d checks)` |
| `country_reference_trace_test.gd` | 生产边界参考轨迹（D1） | `failures=0` |
| `country_runtime_test.gd` | 同步共享核心、命令/税务/信号/PKCN（D2–D4） | `failures=0` |
| `runtime_country_pod_test.gd` | Country POD / read-view（D9） | `failures=0`（静态约 36 `_expect`） |
| `runtime_country_peer_bridge_test.gd` | 研究完成、真实 Effect/Modifier ACK、同日续跑、拒绝重试、保存 barrier（D5-D6） | `failures=0`（含循环断言） |
| `runtime_country_host_protocol_test.gd` | Host admission/receipt/handoff（D8/D10） | `failures=0`（当前日志 42 checks, 0 failures） |
| `runtime_country_economy_transaction_test.gd` | K2-B 九类 Country/Economy asset transaction path | `failures=0`（静态约 44 `_expect`） |
| `runtime_country_save_roundtrip_test.gd` | PKCN/CPD2/PKSR 恢复（D4/D10） | `failures=0` |
| `runtime_events_pod_test.gd` | Events I1-I7 | `failures=0` |
| `runtime_trigger_pod_test.gd` | Trigger H2-H5 | `PASS` |
| `runtime_trigger_parity_test.gd` | Trigger SHADOW parity / ACTIVE refusal | `PASS` |
| `runtime_trigger_save_roundtrip_test.gd` | Trigger H6：TPD1 | `PASS` |
| `runtime_modifier_pod_test.gd` | Modifier E2-E5 | `failures=0` |
| `runtime_protocol_guard_test.gd` | Modifier ABI + 全局 ACTIVE gate | `failures=0` |
| `runtime_save_domain_section_test.gd` | Modifier E6：MDF2/PDP4 | `failures=0` |
| `effect_native_modifier_bridge_test.gd` | Modifier E4：Effect → Modifier bridge | `PASS` |
| `modifier_runtime_test.gd` | legacy ModifierRuntime 生产 authority | `PASS` |
| `ideology_runtime_test.gd` | Ideology G2-G4 | `failures=0` |
| `ideology_opinion_synergy_test.gd` | Ideology G5 | `failures=0` |
| `ideology_runtime_stress_test.gd` | Ideology G2-G5 stress | `failures=0` |
| `runtime_ideology_save_roundtrip_test.gd` | Ideology G6/G7：IDP1 | `failures=0` |
| `runtime_effect_pod_test.gd` | Effect F2-F7 self-test（统一 suite 已收录；含 Host stage smoke） | `failures=0` |
| `dots_completion/dots_completion_gate.gd` | 当前静态门禁：D12 mask/request、D7 journal、flag registry；旧巨石行数与 map_generator bake-time 直写只输出 `LEGACY` 警告 | `ALL GATES PASSED` |

> 输出格式是 `checks / failures`，**没有** `passed=N failed=M`；断言数运行时累加，无编译期固定
> 总数。所以"某测试应该有 N 个断言"这种判断不成立，只能看 failures 是否为 0。含循环的 harness
> （peer bridge、fiscal continuation）更不要把某次运行的 checks 写进总纲当契约。

2026-09-22 复核：**26/26 passed**（25 个 `runtime_*` + `dots_completion_gate`，
`artifacts/runtime/cohort-cash-fix/test-summary.json`）。条目数会随新增测试漂移，
以 `tools/runtime/Invoke-RuntimeTests.ps1` 的 `$tests` 数组为准，不要把本文的数字
当契约。

2026-09-11 完整 runner 复核：**24/24 passed, failures=0**（23 个 `runtime_*` +
`dots_completion_gate`）。checks 数由运行时 assertion 数决定，长期验收只固定 `failures=0`。
`dots_completion_gate` 的 2026-05 monolith 行数与 `map_generator` bake-time 直写指标已明确降为
`LEGACY` 非门禁警告；当前硬门禁改为 H8/I8 `implemented_domain_mask`、生产 request `0xFFF`、
D7T1/fiscal peer section 与 ClimateProfile flag registry。2026-09-09 历史记录中的 **19/21**
（Economy bootstrap 超时与旧 monolith gate 失败）及仓库内更早的
`artifacts/runtime/s0-baseline/test-summary.json` 17/19 归档不代表当前状态。
Trigger 与 Events 已随 H8/I8 进入 `implemented_domain_mask`；Economy 专项仍不构成放行。

### soak 环境变量（`climate_authority_soak_probe.gd`）

| 变量 | 默认 | 变量 | 默认 |
| --- | --- | --- | --- |
| `PK_SOAK_DAYS` | 300 | `PK_SOAK_AUTHORITY` | 1（**设 0 取基准对照**） |
| `PK_SOAK_SEED` | 20260907 | `PK_SOAK_DRIVE` | serial |
| `PK_SOAK_W` / `PK_SOAK_H` | 50 / 48 | `PK_SOAK_SPEED` | 50 |
| `PK_SOAK_POP` | 100 | `PK_SOAK_FOREIGN` | 3 |
| `PK_SOAK_TRACE_DAYS` | 未设=关 | `PK_SOAK_DUMP_REPORT` | 未设=关 |

**A/B 的正确姿势**：同 seed 同尺寸跑两遍，只翻 `PK_SOAK_AUTHORITY`，对比逐场 nz/mean/max。

## 4.4 已知缺陷与限制

### Climate（已放行；B8 于 2026-09-12 收口）

| 项 | 状态 |
| --- | --- |
| stage 次序 | ✅ canonical 顺序 + 契约测试 |
| ψ / cyclone / monsoon / 物理环流 | ✅ worker 自持（ABI 4/6/7） |
| 量级偏差 | ✅ 已归因（declared_gap；非未查 bug） |
| 大地图跟拍 | ✅ 环境 FIFO ring + wait(0)；吞吐仍受 worker 成本限制 |
| 小地图负收益 / 阈值 | ✅ 实测无正阈值；AUTO keep-on + 显式诊断 |
| terrain/cover | ✅ CLM2 ABI 8 writeback |
| C5 场景表 | ✅ `runtime_climate_c5_scenarios_test.gd` |

### 测量能力缺口（→ 阶段 C，影响所有域）

- **帧延迟收益无法测量**：headless 的 `frame_wall_ms` 恒 0，而这正是 worker 化的主要卖点。
- **`run_ms` 在 ACTIVE 下不可直接比**：harness 每天 40ms 忙等轮询（`SceneTree -s` 下
  `_process` 不跑，回灌只能手动驱动）会淹没真实差异。

### 存档链路（2026-09-23 已修复）

下面这段是 2026-09-22 发现时的记录，保留作为归因过程。实际根因比当时的推断深得多：
"存档超时"不是 ring 与暂停互等，而是 `build_save_bundle` 在 worker 里失败、故障又被
状态覆盖藏起来；而读档一路下去还有十来处环环相扣的缺陷，其中最严重的是 **worker 权威下
存档捕获的是开局时的国家**——worker 上的领地、科技、国库变化在存盘时全部丢失。完整
清单、每一环的修法与回归覆盖见 `game-flow-start-save.md` 的
「Save/load under worker authority」。当前状态：`game_save_roundtrip_test.gd`
（开税、推进 20 天、存读档、逐字段比对、读档后完整结算）0 failures；带税存档读档后
回放 120 天 19.9 日/秒、守恒 0/0/0、worker 全程持有 `0xFFF`。

以下为 2026-09-22 的原始记录：

两个缺陷叠在一起，效果是"玩家既存不下来、已有的存档也读不回去"，因而无法把现场交给
任何人复现。两者都在当前工作树复现，与同日的 cohort cash 修复无关。

- **手动存档超时 `runtime_save_timeout`。** `game_save_roundtrip_test.gd` 稳定 4 项失败，
  代码来自 `GameSaveCoordinator._capture_native_runtime_bundle()` 轮询 1800 帧仍未
  ready。worker 的 save 准入条件是
  `!has_pending_climate_input() && !retained_day_pending`
  （`native_simulation_host.cpp` 主循环），而 `_save()` 一开始就 `pause(true)`。
  Climate 输入 ring 只有推进日期才会排空 —— 存档等 ring 排空，ring 等时钟推进，时钟
  为了存档被暂停。这是 5.3"跨边界接线"的又一例：两个互相等待的边界条件。
- **读档 `runtime_bundle_ideology_catalog_missing`。** 玩家 autosave（day 2930）无法
  载入。`DCWorldExt::configure_ideologies()` 要先
  `NativeCountryRuntime::export_pod_snapshot()` 成功才会调
  `configure_ideology_pod()`；读档时 country 处于
  `[save/restore] country configured without bootstrap; awaiting PKCN`，导出失败 →
  `_ideology_pod_configured=false` → 之后 PKSR 恢复撞上 IDP1 section 就拒绝
  （`native_simulation_host.cpp:10911`）。**这是恢复次序契约的缺陷**：PKSR 里带
  ideology POD section，但它的 catalog 要等 PKCN 之后才配得出来。修法需要定次序
  （PKCN → 配 ideology catalog → 恢复 PKSR ideology section，或让
  `restore_runtime_bundle` 暂存该 section 延后恢复），属于 `game-flow-start-save.md`
  的保存/恢复顺序契约，不要就地打补丁。

复现命令：

```powershell
# 存档失败
$env:PK_GAME_SAVE_ROUNDTRIP_TEST = "1"
godot --headless --path Project/project-keynes
# 读档失败（forensics 落在 tmp/runtime_forensics_save_replay_restore_failed.json）
tools\runtime\Invoke-SaveReplay.ps1 -Slot autosave -Days 5
```

### 危险默认值

- **`simulation_thread_mode` 键缺失时，C++ 侧 raw 默认是 `"ACTIVE"`**
  （`world_ext_simulation_host.cpp:46`，另有别名键 `mode`）。忘了传这个键的 harness 会静默
  跑成 ACTIVE。生产路径总是显式传，自己写 probe 时要注意。

---

# 第五部分：失效模式库

这一部分是这轮迁移里**每一条都对应至少一次实际走错**的教训，不是事后总结的漂亮话。动 worker
相关代码前建议整节读一遍——它们绝大多数不是 Climate 特有的。

## 5.1 归因方法

**一、归因要靠对照实验，不要靠读代码。** 代价最大的一条。`0xC0000005` 的定位：所有静态推断
都指向"双写"，方向全错，真正定位靠的是把 authority 关掉发现照样崩。冻结场那轮三次归因里两次
是读代码推出来的错误结论，唯一可靠的证据都来自双向 soak 对照。

**二、改动没有效果就回滚，不要因为"语义上更对"而保留。** 把 capture 挪到 season refresh 之后
在语义上确实更合理，但它不改变任何指标。保留它等于在代码里留一个没有依据、却改变了原有设计
约束的决策。

**三、先拿到实测再改，不要跳过验证步骤。** 上一条那次回滚正是因为跳过了这步：假设"季节信号被
capture 时点挡住"听起来自洽，直接改了执行序，零改善。同一个问题改成先静态确认
`fill_climate_round_input` 到底填不填 scalars，一次就中。

**四、争用与冻结类问题要看全场分布，单点 trace 会骗人。** `PK_CLIMATE_TRACE_CELL=1200` 显示
PAW 四十天不动，看着像全场冻结，实际那是个水域格，`IS_WATER` 分支把 PAW 清 0 是正确行为。
单个格子分不出"这个格子本来就该是这个值"和"全场都坏了"。

**五、"某个 stage 从不执行"不等于"它被漏接了"。** 先确认生产侧是否也不执行。hydrology 就是
这样：`runtime_hydrology_enabled=false` 时生产侧返回 `{}`，两侧都不跑。同理"worker 有这条
lane"不等于"生产没有"，两边都要看代码，不要靠对称性推断。

**六、平坦的场先查上游，不要逐条修。** 四条场在 worker 侧全部平坦，看着像四个独立缺陷。加一
条 `temp` 进对照就看清了：温度上限完全冻结，而温度是所有季节性的源头，下游平坦是必然的。
**顺带一条观测技巧**：温度要看极值而不是 nz/mean——全场 mean 随季节几乎不变（南北半球互相
抵消），振幅只体现在两端。

## 5.2 性能判断

**七、性能口径要先排除 harness 自身的开销。** `run_ms` 在 ACTIVE 下暴涨 3.5 倍，差值完全来自
harness 每天 40ms 的忙等轮询（`SceneTree -s` 下 `_process` 不跑，回灌只能手动驱动）。真实
客户端没有这段。同一件事的另一面：`frame_wall_ms` 在 headless 下恒 0，所以这条路径**最该看
的指标恰好测不出来**。

**八、"搬到后台线程"不等于"变快"。** 主线程 climate job 省了 49%，但 SUS 总均值不动——CPU
总需求没变，worker 与主线程抢核心。**要区分吞吐收益与延迟收益**，并且要知道自己在测哪个。
小地图上甚至是净负：固定的 capture 打包与回灌 memcpy 开销比被搬走的计算还大。

## 5.3 跨边界接线

**九、缺失是静默的，三种都是。** 缺 lane 被 `copy_f32` 填成等长全零（海冰因此每天从零冰起算，
max 恒等于当日增量上限）；缺 knob 落到结构默认值（默认值往往是个合理数字，于是表现为"物理
偏弱"而不是崩溃）；缺 comparable 字段曾被当零值哈希（会以假分叉形式浮出）。**边界解析处宁可
整份拒绝并报出缺失清单，也不要宽松填充**——一行守卫能定位的问题，宽松填充会变成要从分叉矩阵
反推的谜题。

**十、scalars 要整套传，不要逐个补。** 只补 `season_phase` 治不了病：`insol_amp` 取结构默认
0.20 而 profile 是 0.32，季节振幅还剩 62.5%。正确做法是复用生产那个构建函数，整份过边界。

**十一之一、一个拒绝条件里不能混两个类别。** `prepare_worker_cohort_cash()` 把"线程错了 /
域没授权 / 操作非法"（契约违反，重试一万次也不会对）和"Country plan 窗口开着"（时序，
下个 pulse 就好了）合成同一个 `country_worker_cohort_cash_boundary_invalid`。调用方只
拿得到这一个字符串，只能一视同仁地 fail，于是一次正常的 continuation 变成了整个经济
运行时停机。**跨边界的拒绝必须按"能不能重试"分类返回**，而不是按"检查写在一起"合并。

**十一之二、fail-closed 的快路径必须有回退，否则它就是停机开关。** `coordinate_country_cohort_cash`
的 sync fast path 失败直接 `return false`，够不到紧邻其下的
`block_or_enqueue_country_worker_asset` 软回退（那条路径有
`GATE_SOFT_UNAVAILABLE → committed=0, return true`）。同一个文件里
`service_country_economy_asset_peer` 的调用点早就把 `*_pending` 归为 backpressure 并注释
了"Treating it as fatal leaves the epoch half-open"，只是这套处理没有用到 fast path 上。
**新增快路径时，先列出它所有的失败出口，逐个回答"这条出口有回退吗"。**

**十一之三、游标驱动的 stage 天然可以 park，不要浪费这个性质。** `LEDGER_APPLY` 与
`STRUCTURAL_COMMIT` 都是 `_command_cursor` / `_structural_cursor` 驱动，失败时游标停在
出错的那条命令上。这意味着"不推进游标 + 返回 pending"就等于让同一条命令下个 pulse 重放，
不需要任何新的 continuation 状态。park 时要顺手把对端队列 drain 一次
（`service_country_economy_asset_peer`），否则会出现"Economy 等 Country 关窗口、
Country 等 Economy 落终态"的互等。

**十一、门控标志的名字要说它门控什么。** `climate_own_paw` 后来同时门控了 scalars 补齐，名字
就开始误导，改成了 `climate_worker_authoritative`。它和 `own_snow_state` / `own_field_state`
是并列但不同的区分：后两者问"跨天状态谁持有"，它问"生产被抑制后，那些由生产 pass 顺带记录的
东西谁来补"。

**十二、共享 bit 的 stage 计数器会骗人。** `weather` 与 `distribute` 共用一个 stage bit，于是
"weather=15"在 weather field solve 一天没跑的情况下照样显示。诊断计数器的粒度要与接线粒度
一致，否则它会掩盖整个 stage 缺失。

## 5.4 验收

**十三、headless 全绿不等于玩家看到的是对的。** Climate 在 headless soak 字段统计全部对齐、
七项回归全绿的情况下，仍在真实客户端暴露了四个缺陷（温度振幅、日照冻结、湿度跳变、海冰不
显示）。原因是 headless 不跑 `_process`、不做视觉消费、不存档。**真实客户端录制对照是独立
的一步，不能被 soak 替代。**

**十四、单独盯过的场才算验过。** ACTIVE soak 覆盖的是"跑过的天数里碰到的情况"。暴雨、干旱、
降雪、跨年、topology revision 这些场景如果没有单独构造，就只是"可能碰到过"。

**十五、诊断字段在异常态下的取值必须单独定义，否则它会主动误导。** `population_error /
money_error / goods_error` 原先只按 `!_epoch_active` 计算，而 `fail()` 恰好会把
`_epoch_active` 置 false —— 于是每次 fatal 都附带一组"用本 epoch 的 mint 减去上个 epoch
的 closing"的假差值。day 2744 那次 `money_error=-639200` 精确等于当天金银铸币额，所有人
都去追一个不存在的守恒 bug。**一个指标只在某些状态下有意义时，其他状态要显式报"未知"
（`audit_incomplete` + reason），不能让它退化成上一次的残值。**

**十六、停机现场要带 stage 与命令，只有 reason 字符串等于没有。** 事故落盘过去只覆盖
`money_conservation_failed` 且字段集是钱专用的，于是边界类停机拿到的是一份钱的报表：
没有 stage、没有触发命令的 opcode 与 handle、没有 `_d7_operation_gate_mask`、没有
`authoritative_domain_mask`。现在 `fail()` 捕获 `FatalContext`，
`WorldRuntimeHost` 对任何 fatal reason 落盘一次。**新增任何 fail-closed 点时，问一句
"只看这份 dump，能不能定位到行"。**

**十八、主线程副本在 worker 权威下是陈旧的，任何"从主线程取状态"的路径都要重审。**
存档从主线程 `NativeCountryRuntime` 捕获 Country，而 worker 拥有 Country 期间它从开局起就
没被写过——结果存盘的是开局国家。往返测试只跑 3 天、国家没变化，hash 碰巧一致，于是这个
数据丢失一直是绿的。**迁移一个域之后，要把"谁还在读旧 owner"列出来**，并且往返测试必须
先让状态在新 owner 上真正变化（开税、推进若干天）再存档。

**十九、授予前窗口是一个真实的运行态。** worker 在 ACTIVE 下按请求的 mask 执行 stage，
但跨域路由看已授予的 mask，而授予要等第一天完整提交。新开局第一天没有跨域资产流量，窗口
无害；读档后开着税，第一天就结算，于是 worker 线程直接改了主线程的 Country（崩溃）。
恢复启动现在立即授予；新增跨域路由时要确认它在授予前窗口里选的是哪条路。

**十七、"跑满 N 天且不报错"不是通过条件。** 新写的存档回放 harness 第一版就给出假绿：
PKSR 恢复失败、worker 停在 STOPPED，时钟照样以 19.6 日/秒空转到目标天数，结果判定 PASS。
这是 5.4 第十三条（headless 全绿 ≠ 玩家看到的是对的）的同一形态。**任何"推进 N 天"的
harness 都要同时断言权威真的在动**：country/economy 已 bootstrapped、host 不在
STOPPED/FAULTED、`newest_state_day` 有推进。

---

# 附录 A：文件地图

## 协议与 host

| 文件 | 内容 |
| --- | --- |
| `gdext/src/runtime_pod_protocol.h` | **契约单一源**：`RuntimeDomainId`、mask、stage 顺序、`RuntimeEnvironmentSnapshot`、各域命令与 ACK 结构；Trigger save bit 为 `1 << 4`，Ideology save bit 为 `1 << 8` |
| `gdext/src/native_simulation_host.{h,cpp}` | worker 状态机、implemented-domain/ACTIVE 准入、day plan、Country read-view、Trigger catalog/command/reference/parity/TPD1 生命周期、Ideology/Events SHADOW stage |
| `gdext/src/world_ext_simulation_host.cpp` | GDScript 边界：capture 全部解析、writeback、parity 字段表、模式解析（缺省 `"ACTIVE"`） |
| `gdext/src/runtime_domain_pod.{h,cpp}` | 通用 domain POD pipeline；Trigger 入口调用 `RuntimeTriggerPodAuthority`，不再递增 accumulator 或扫描简化 journal |
| `gdext/src/runtime_domain_authorities.cpp` | 未放行域 authority runner；Trigger 入口调用 `RuntimeTriggerPodAuthority`，不再保留独立简化聚合语义 |
| `gdext/src/runtime_authoritative_domains.{h,cpp}` | 各域 store 定义、`stage_preflight` |

## Trigger（H2–H6，SHADOW parity）

| 文件 | 内容 |
| --- | --- |
| `gdext/src/runtime_trigger_kernel.{h,cpp}` | Godot-free 共享 kernel：10 aggregator、condition bytecode、cursor/gap/resync、target generation、one-shot/repeat/cooldown、snapshot/branch binding、effect resolver/value mode 与稳定排序 |
| `gdext/src/runtime_trigger_pod.{h,cpp}` | numeric catalog、6 个固定 command opcode、plan/commit/discard、真实 ACK barrier、immutable snapshot、诊断 parity 和独立 TPD1 codec/事务性恢复 |
| `gdext/src/trigger_runtime.{h,cpp}` | 主线程生产 facade、PKTR v6 codec、numeric catalog/POD snapshot/canonical effect/ACK cursor 导出；日算法委托共享 kernel |
| `gdext/src/world_ext_trigger.cpp` | catalog/command/ACK bridge 与同步运行前后的 SHADOW reference frame；不改变主线程 Trigger authority |
| `gdext/src/native_simulation_host.{h,cpp}` | Trigger SHADOW plan/replay、parity/ACK blocker report、snapshot 和 TPD1 save bundle；不发布 Trigger authoritative mask |
| `Project/.../tests/runtime_trigger_pod_test.gd` / `runtime_trigger_parity_test.gd` | kernel/POD 行为、Action 数值、ACK/retry、canonical parity 和 ACTIVE refusal |
| `Project/.../tests/runtime_trigger_save_roundtrip_test.gd` | TPD1 roundtrip、catalog/state/checksum/shape/order/trailing-byte 拒绝和 PKTR v6 回归 |

## Ideology（G2–G8，生产 ACTIVE）

| 文件 | 内容 |
| --- | --- |
| `gdext/src/runtime_ideology_pod.{h,cpp}` | numeric catalog、9 个 legacy opcode、确定性排序、copy-on-write plan/replay、head cursor、bounded slice、same-day continuation、Country/Economy 输入校验、deferred typed intent、真实 Effect ACK barrier、immutable snapshot、`RuntimeIdeologySnapshotRing`、IDP1 序列化/恢复 |
| `gdext/src/native_simulation_host.{h,cpp}` | Ideology bootstrap、Country 之后/Effect 之前的日阶段（ACTIVE stage loop + SHADOW 诊断）、ACK 收集、`ack_ideology_intents_in_worker` 桥、snapshot ring publication、IDP1 section；不把 deferred intent 视为完成 |
| `gdext/src/world_ext_ideology.cpp` | 主线程 catalog/snapshot capture、worker command ingress（worker 权威下只入 POD 队列）、typed intent/ACK polling、`apply_runtime_ideology_snapshot` 回灌、`run_ideology_daily` / `ideology_should_run` 抑制 |
| `gdext/src/ideology_runtime.{h,cpp}` | legacy `NativeIdeologyRuntime`：ACTIVE 下改为 snapshot 回灌目标（`apply_pod_snapshot`）与 POD catalog export；`PKID` 仍只属于同步 runtime |
| `gdext/src/runtime_pod_protocol.h` | `RuntimeIdeologyPodOpcode`/ACK wire contract、Ideology stage report、`RUNTIME_SAVE_SECTION_IDEOLOGY = 1 << 8` |
| `Project/.../tests/ideology_runtime_test.gd` | 9 opcode parity、排序、generation、receipt、真实 Effect ACK 和 legacy reference 回归；failures=0 |
| `Project/.../tests/ideology_opinion_synergy_test.gd` | class opinion gate、exclusion、reverse-CSR synergy、revision/hash/generation rejection；failures=0 |
| `Project/.../tests/ideology_runtime_stress_test.gd` | 大规模 country/idea、slice continuation、same-day retry、pending transition 和 stress replay；failures=0 |
| `Project/.../tests/runtime_ideology_save_roundtrip_test.gd` | 独立 `IDP1` section、checksum/完整性失败的事务性拒绝，以及不从 `PDP3`/`PKID` 推导 worker state；failures=0 |

## Modifier（E2–E7，SHADOW-only）

| 文件 | 内容 |
| --- | --- |
| `gdext/src/runtime_modifier_pod.{h,cpp}` | numeric catalog、四域隔离 state、双缓冲 plan/replay、五个 opcode、expiry、ACK、immutable snapshot、MDF2 序列化与旧 PDP3 迁移 |
| `gdext/src/native_simulation_host.{h,cpp}` | Modifier snapshot ring、`EFFECT → MODIFIER → COMMIT` 日阶段、ACK barrier、MDF2/PKSR section、report 字段 |
| `gdext/src/world_ext_modifier.cpp` | Modifier command ingress、固定 little-endian payload、snapshot metadata/packed snapshot bridge |
| `gdext/src/runtime_pod_protocol.h` | Modifier domain、固定 command/ACK wire contract、`RUNTIME_SAVE_SECTION_MODIFIER` 和 POD ABI 常量 |
| `Project/.../tests/runtime_modifier_pod_test.gd` | Modifier POD self-test：四域隔离、五 opcode、expiry、排序、generation、stack/magnitude/clamp、determinism |
| `Project/.../tests/runtime_save_domain_section_test.gd` | MDF2/PDP4 section、marker/checksum/catalog mismatch 与兼容读取验证 |
| `Project/.../tests/effect_native_modifier_bridge_test.gd` | Effect → Modifier typed bridge 与 ACK identity 回归 |

## Events（I1–I7，SHADOW/PROBE）

| 文件 | 内容 |
| --- | --- |
| `gdext/src/runtime_events_authority.{h,cpp}` | Events POD authority：固定顺序 APPEND_BATCH/ACK_CONSUMER、容量淘汰、FNV-1a state hash、`EVT1` 序列化/事务性恢复和 snapshot ring |
| `gdext/src/native_simulation_host.{h,cpp}` | Events worker probe、日阶段执行、独立 snapshot ring、report 字段；不授予 Events ACTIVE authority |
| `gdext/src/world_ext_events.cpp` | legacy journal append/ack 到 POD command bridge、稳定 consumer key、snapshot/ACK/idempotency arrays facade |
| `gdext/src/world_ext_bind_methods.cpp` / `gdext/src/world_ext_simulation_host.cpp` | `poll_runtime_events_snapshot` 与 Events self-test GDExtension 绑定、direct runtime report 字段 |
| `Project/.../scripts/data_core/gameplay_event_bus.gd` | 独立 Events snapshot generation cursor；不把 POD snapshot 重新注入 legacy event bus |
| `Project/.../scripts/geography/map_generator.gd` | `poll_runtime_events_snapshot(after_generation)` 转发 |
| `Project/.../scripts/game/world_runtime_host.gd` | `runtime_events_probe_enabled`（默认 false）和 probe 配置透传 |
| `Project/.../tests/runtime_events_pod_test.gd` | Events I1-I7 聚焦验证；failures=0 |

## Climate / Country（生产权威域）

| 文件 | 内容 |
| --- | --- |
| `gdext/src/runtime_climate_authority.{h,cpp}` | **权威路径**：plan/commit、CLM2 序列化 |
| `gdext/src/runtime_climate_kernel.cpp` | worker round 编排、五个 stage_knobs stage 的守卫 |
| `gdext/src/runtime_climate_passes.{h,cpp}` | 九个 pass 的共享纯内核（生产与 worker 同一份） |
| `gdext/src/world_ext_climate.cpp` / `world_ext_weather.cpp` | 生产侧实现，**接线时的键名口径以它们为准** |
| `Project/.../scripts/geography/map_generator.gd` | capture、knobs 构建、stage 节拍 |
| `Project/.../scripts/game/world_runtime_host.gd` | worker 生命周期、模式决策（Climate|Country|Trigger|Modifier|Effect|Ideology|Events ACTIVE → `authoritative_domain_mask=0xFFF`） |

## 调度层

| 文件 | 内容 |
| --- | --- |
| `Project/.../scripts/data_core/dc_system_scheduler.gd` | 注册、拓扑排序、profile 配置透传、`tick()` 入口 |
| `gdext/src/sus_scheduler_ext.cpp` | **真正的 gate + slice 循环**：预算、policy、depends_on、统计 |
| `Project/.../scripts/simulation/sus/sus_job.gd` | `slice_budget_ms` / `must_run` / `depends_on` 的定义处 |
| `Project/.../scripts/game/world_clock.gd` | `day_changed`、日推进时间盒、`simulation_backpressure_pulse` |
| `gdext/src/world_ext_daily_sim.cpp` | native daily slice 图（21 节点）、cursor、continuation |
| `gdext/src/system_schedule.cpp` | `SCHEDULE_GRAPH` 15 节点顺序（**节点顺序的权威定义**） |
| `gdext/src/world_ext_runtime_graph.cpp` | `advance_runtime_pulse`：生产下 Economy/Country 的实际驱动点 |

## Country

| 文件 | 内容 |
| --- | --- |
| `gdext/src/country_core.{h,cpp}` | 共享纯 C++ 生产核心接口、boundary/checkpoint/peer POD 契约 |
| `gdext/src/country_runtime.{h,cpp}` | 当前同步生产 authority facade、`run_slice_core()`、20 opcode、研究和 peer continuation |
| `gdext/src/runtime_country_pod.{h,cpp}` | Host Country adapter、worker plan/commit 与 read-view 发布边界 |
| `gdext/src/world_ext_country.cpp` / `world_ext_bind_methods.cpp` | Godot facade 与 peer bridge 导出边界 |
| `Project/.../scripts/geography/map_generator.gd` | get_country_worker_read_view GDScript 转发；捕获边界不暴露 worker store |
| `Project/.../scripts/game/world_runtime_host.gd` | ACTIVE-gated read-view 消费；连续代次 sparse patch，跳代 full snapshot；复用 CountryFacade.country_committed |
| `Project/.../scripts/country/country_facade.gd` | dispatch_worker_committed_view，把 worker commit 接回现有 Country signal |
| `Project/.../tests/runtime_country_peer_bridge_test.gd` | K2-A 黑盒协议与同日研究完成验证 |
| `Project/.../tests/runtime_country_pod_test.gd` | read-view bootstrap、稀疏 CREATE、无 territory RENAME、跳代 full snapshot；failures=0 |
| `.agents/skills/project-keynes-country-runtime/scripts/verify_country_runtime.ps1` | Country reference/runtime/POD/peer/save 专项验收入口 |
| `Project/.../scripts/simulation/systems/country_daily_system.gd` | 同步调度壳；runtime graph 或实际 granted Country bit 存在时 no-op，避免双写 |

## Economy

| 文件 | 内容 |
| --- | --- |
| `gdext/src/economy_runtime.h` | stage 枚举（约 `:662`） |
| `gdext/src/economy_runtime.cpp` | `run_slice_internal` 主序（`:9672+`）、epoch/`should_run` 门禁（`:7860+`）、同步 Country asset coordinator |
| `gdext/src/economy_runtime_epoch.cpp` | 冻结 epoch：预检、country 快照、税率冻结 |
| `gdext/src/economy_runtime_publish.cpp` | `aggregate_publish`、**守恒审计 VERIFY**（`:322+`） |
| `gdext/src/parallel_dispatcher.h` | `parallel_for_range`——Economy 的并行是这个，不是 POD worker |
| `Project/.../scripts/simulation/systems/economy_daily_system.gd` | SUS 侧包装、fatal 时 `world_clock.pause(true)` |

---

# 附录 B：开关清单

## B.1 决定权威模式的

| 开关 | 定义 | 默认 | 作用 |
| --- | --- | --- | --- |
| `runtime_climate_authority_enabled` | `world_runtime_host.gd:90` | **true** | true → 以 ACTIVE + `authoritative_domain_mask=0xFFF`（Climate\|Country\|Trigger\|Ideology\|Modifier\|Effect\|Events\|COMMIT）启动；false → SHADOW。**Climate+Country+Trigger+Modifier+Effect+Ideology+Events 的总开关与回退路径** |
| `runtime_events_probe_enabled` | `world_runtime_host.gd:63` | **false** | true → 启用 Events legacy journal 到 POD 的 SHADOW/PROBE 镜像与 snapshot；不改变 `implemented_domain_mask`，不替代 legacy consumer |
| `simulation_thread_mode` | 启动配置键，C++ 解析 `world_ext_simulation_host.cpp:43` | ⚠ **键缺失时 raw 默认 `"ACTIVE"`** | OFF / SHADOW / ACTIVE |
| `runtime_shadow_on_generate` | `world_runtime_host.gd:59` | true | generate 时是否启动 worker |
| `runtime_parity_forcing` | `world_runtime_host.gd:60` | false | 强制 parity 采集 |

## B.2 native daily 图（`ClimateProfile`，生产覆盖在 `earth_like.tres`）

| 开关 | 脚本默认 | earth_like.tres |
| --- | --- | --- |
| `native_daily_sim_mode` | OFF(0) | **ACTIVE(2)** |
| `native_daily_sim_stride` | 1 | **10** |
| `native_runtime_graph_mode` | ACTIVE | 2 |
| `native_daily_split_weather_node_enabled` | false | **true** |
| `native_daily_node_range_enabled` | false | **true** |
| `native_daily_ocean_thread_variant_enabled` | false | **true** |
| `native_daily_coarse_spread_yield_enabled` | false | **true** |
| `native_daily_finalizer_slice_enabled` | false | **true** |
| `native_daily_finalizer_native_publish_enabled` | false | **true** |
| `native_daily_legacy_daily_production_retired` | false | **true** |
| `native_climate_round_active_owner_enabled` | false | **true** |
| `native_weather_transaction_active_owner_enabled` | false | **true** |
| `native_ocean_physical_active_owner_enabled` | false | **true** |
| `native_season_refresh_active_owner_enabled` | false | **true** |
| `runtime_hydrology_enabled` | false | **true**（但生产 knobs 返回 `{}`，两侧都不跑） |
| `native_tropical_cyclone_enabled` | false | **true** |
| `physical_cell_slice_enabled` | false | **true** |
| `wind_traj_table_enabled` | false | **true** |

> **脚本默认值几乎全是 false，生产靠 `.tres` 覆盖**。所以任何不加载 `earth_like.tres` 的
> fixture 拿到的是一套完全不同的配置——这解释过好几次"测试里复现不出来"。

`project.godot` 里**没有**任何 `runtime_*` / `native_*` 项目设置项，不要去那里找。

## 阶段 E（2026-09-09）

E2-E8 已完成。Modifier POD 在生产 ACTIVE 下为唯一写者：日循环 plan/replay、四域隔离、Effect POD intents ACK、immutable snapshot ring、MDF2，以及回灌 legacy ModifierRuntime。implemented/request 均为 CLIMATE|COUNTRY|TRIGGER_INPUT|IDEOLOGY|MODIFIER|EFFECT|EVENTS|COMMIT = 0xFFF；主线程抑制 modifier_daily、effect daily、ideology daily 与 trigger daily；Effect 为 F8 ACTIVE，Ideology 为 G8 ACTIVE，Trigger 为 H8 ACTIVE，Events 为 I8 worker 镜像。

Modifier snapshot 只在安全日边界发布并按 generation 单调消费。capture barrier 之后到达的 Modifier command 顺延到下一日；当前日中途不插入。新 composite 状态写入 PDP4，Modifier 独立写入 save bit 1 << 5 的 MDF2；旧 PDP3 只保留一次性兼容迁移读取。


