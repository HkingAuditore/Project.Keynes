# 运行时权威迁移：目标、设计框架、当前状态与任务

更新时间：2026-09-08

**一句话现状**：十个 domain 里 Climate 已是生产默认权威（`implemented_domain_mask =
CLIMATE|COMMIT = 0x802`，滞后一日），Country 有完整 POD 实现但未接 Host，其余七个只有诊断级
占位。整图 ACTIVE 仍禁止，放行是**逐域**的。

---

## 如何使用这份文档

本文是这轮迁移的**总纲**：目标、框架、状态、任务四类分开，每类先总后分。它不复述架构细节，
细节在 `docs/cpp-dots-runtime/` 下的专项文档里，本文只负责给出准确的当前状态和指路。

| 你想知道 | 看 |
| --- | --- |
| 为什么做这件事、做到什么算完 | 第一部分 |
| 整体架构长什么样、调度怎么跑、某个模块具体怎么运行 | 第二部分 |
| 完整迁移一共要做哪些事、哪些已经做完了 | 第三部分（工作分解 A–F） |
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
| 注册 system、reads/writes 拓扑、重写 priority | `DCSystemScheduler` | `dc_system_scheduler.gd:308-378` |
| tick 入口、同步 budget 配置 | `DCSystemScheduler` | `:388-426` |
| **决定跑不跑**（policy / `should_run` / deadline_critical） | `SusSchedulerExt` | `sus_scheduler_ext.cpp:512-533, 474-478` |
| 决定顺序 | 拓扑定 priority → Ext 内 `stable_sort` | `dc_system_scheduler.gd:357-371`；`sus_scheduler_ext.cpp:216-218` |
| 管预算（frame gate + 每 job slice 循环） | `SusSchedulerExt` | `sus_scheduler_ext.cpp:421-422, 482-607` |

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
  → _advance_one_sim_day() → day_changed.emit(day)        world_clock.gd:223-230
main.gd::_on_day_changed
  → MapGenerator.sus_tick_daily(clock, day_idx, season_phase)   main.gd:1499
MapGenerator.sus_tick_daily
  → SusTickContext.make(...) → DCSystemScheduler.tick(ctx)      map_generator.gd:7675
DCSystemScheduler.tick
  → _sus.tick(ctx)  →  SusSchedulerExt::tick                    dc_system_scheduler.gd:388
SusSchedulerExt::tick
  → 逐 job：budget / policy / dep gate → job.run_slice(ctx) 循环 sus_scheduler_ext.cpp:410-770
DCSystem.run_slice → tick(ctx) → C++ pass
```

tick 结束后经 `report_last_tick()` 出报告（Ext 侧写 `_last_report`，`:789-823`）。

**跨帧续跑**：遇到硬 barrier 时 `WorldClock` 发 `simulation_backpressure_pulse`，
`MapGenerator._continue_economy_inflight` 调 `DCSystemScheduler.continue_system` 补跑
（`world_clock.gd:199-202`；`map_generator.gd:3026-3098`）。

### 2.2.4 注册了哪些 job

`MapGenerator._setup_sus()`（`:3433+`）。**注册是有条件的**，同一份代码在不同 profile 下注册
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
`DCWorldExt` 成员里：图节点游标 `_native_daily_slice_node_index`（`world_ext.h:2786`）、节点内
cell range 游标 `_native_daily_slice_cell_cursor`、round 活跃标志 `_native_daily_slice_active`。

> **坑**：SUS 因预算跳过 native 首 slice 时会设 `_native_daily_day_pending`，靠 pulse 补跑
> （`map_generator.gd:7696-7705`）。所以"这一天 native 没跑"未必是缺陷，可能只是被推迟了。

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

`RuntimeDomainId` 共 **12 个域**（`runtime_pod_protocol.h:328`），`RUNTIME_ALL_DOMAIN_MASK = 0xFFF`：

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
| `implemented_domain_mask()` | **编译期 constexpr**（`native_simulation_host.h:101`） | 该域**有真实 POD handler**，不代表它是权威 | `CLIMATE|COMMIT = 0x802` |
| `authoritative_domain_mask` | 启动配置键，由 GDScript 传入（`world_runtime_host.gd:540`） | 本次会话**实际要 worker 承担权威**的域 | ACTIVE 时 `0x802` |
| `completed_domain_mask` | 每日报告 | 当天实际跑完的域 | ACTIVE 下 `COMMIT|CLIMATE` |

准入逻辑（`native_simulation_host.cpp:115`）：ACTIVE 要求
`authoritative_domain_mask & ~implemented_domain_mask() == 0` 且 `graph_coverage_complete`。
**整图 ACTIVE**（不传 `authoritative_domain_mask`）要求 `implemented == 0xFFF`，当前
`0x802 ≠ 0xFFF`，所以结构上就不可能——这是刻意的。

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

**Worker 路径**（目前只有 Climate）：

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
（`world_ext_daily_sim.cpp:65-109`）；一次性全量 tick 走 15 节点的 `SCHEDULE_GRAPH`
（`system_schedule.cpp:308-354`）。后者是节点顺序的权威定义，`native_daily_graph_order_test`
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
的慢变量轮（`season_refresh_system.gd:32-57`）。这是 Climate worker 化时最大的一个坑：它是
主线程写者，且必须排在回灌之后。

**Worker ACTIVE 形态**：上述 14 个 Climate 节点被抑制门跳过，由 POD worker 跑同一份共享纯
内核，执行序见 2.5。worker 侧 round 内八个 pass + 五个 `stage_knobs` stage，hydrology 两侧
都不跑。

### 2.7.2 Economy

**与 Climate 完全不同的机制**：Economy 有自己的内部状态机 `ECONOMY_GRAPH`
（`economy_runtime_diagnostics.cpp:571`），**独立于** SUS 图和 native daily 图。

驱动路径有两条，生产走第二条：

```text
① SUS job `economy_daily`  —— runtime_graph_active() 时 should_run 直接返回 false
② DCWorldExt::advance_runtime_pulse → run_economy_slice_compact   ← 生产路径
   （native_runtime_graph_mode=ACTIVE，earth_like.tres:10）
```

**冻结 epoch 是它的核心机制**：`start_epoch(day)` 冻结当日 environment/building 上下文，并
`capture_country_epoch` 复制 country 的领土/科技/税表/国库快照。目的是在整个周期内隔离 live
country。**新 cycle 必须等 country 当日命令已 commit**——`country_runtime->should_run(day)` 为
真时 economy 不启动新 cycle（`economy_runtime.cpp:7076-7078`）。

冻结周期内的 stage 主序（`run_slice_internal`，`economy_runtime.cpp:8991+`）：

```text
BUILDING_PLAN → TRADE_SETTLE → LEDGER_APPLY
→ BUILDING_EMPLOYMENT → BUILDING_PRODUCTION → HOUSEHOLD_MARKET
→ GOVERNMENT_RESEARCH_PROCUREMENT → TRADE_DISPATCH → STRUCTURAL_COMMIT
→ BUILDING_COMMIT → FAMILY_COMMIT → PERSON_COMMIT → AGGREGATE_PUBLISH
```

**它自己的 worker 不是 POD worker**：`economy_profile.worker_enabled`（默认 true）开启的是
`NativeParallelExecutor` + `parallel_for_range` 的按 cell 分 task 并行
（`parallel_dispatcher.h:45-99`），与 `NativeSimulationHost` 的 POD worker 是两个东西。这一点
直接影响 E1 的决策：**Economy 已经是并行的了**，搬进 POD worker 的增量收益需要单独论证。

**守恒审计**在 `aggregate_publish` 的 `PublishPhase::VERIFY`
（`economy_runtime_publish.cpp:367-373`）。失败 → `_fatal=true`、`_stage=FATAL`，GDScript 侧
`EconomyDailySystem` 收到 `fatal` 后清 barrier 并 **`world_clock.pause(true)`**
（`economy_daily_system.gd:155-166`）。生产路径的审计字段是 `population_error` /
`money_error` / `goods_error`，**不是** `ledger_failures`（后者只在 POD 诊断适配层里）。

### 2.7.3 Country

驱动路径与 Economy 同构：SUS job `country_daily` 在 `runtime_graph_active()` 时不跑，生产由
`advance_runtime_pulse` 驱动（`country_daily_system.gd:31-36`；`world_ext_runtime_graph.cpp:172-180`）。

**命令屏障**是它区别于其他模块的地方：

```text
命令入队 _pending_commands
  → slice 开头：无 active batch 时 open_implicit_boundary + begin_reference_boundary
  → 按 seal watermark 过滤出 admitted_and_due，装入 _command_batch
  → 批内 preflight + apply
  → Effect ACK 未完成 → country_day_barrier
  → GDScript 侧 world_clock.request_simulation_backpressure
```

（`country_runtime.cpp:2289-2401`；`country_daily_system.gd:67-69`）

**与 Economy 的边界**：国库/科技/领土由 `NativeCountryRuntime` 权威，Economy 通过
`capture_country_epoch` 冻结快照消费；税率在 epoch begin 从 country + modifier 快照冻结；
研究采购在 Economy 的 `GOVERNMENT_RESEARCH_PROCUREMENT` stage 消费冻结的 country 政策。

**`country_committed` 信号**：由 `CountryFacade.dispatch_committed_events` 在领土/country 变更
时发出，`WorldRuntimeHost`（视野/边界）、`PlayerController`、`GameUIManager` 监听。
注意顺序要求——runtime graph 路径下必须**先 `sync_country_territory_to_map` 再 dispatch**
（`map_generator.gd:3305-3333`），否则监听方读到的 `cell.country_slot` 是旧的。

### 2.7.4 其余模块

`modifier_daily` / `trigger_daily` / `ideology_runtime` / `effect_runtime` / `gameplay_effect`
都是 SUS job + 各自的 native runtime，走主线程同步路径。它们的 POD 侧只有诊断投影（见 4.2）。

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

推荐的放行流程（Climate 走通的那条）：

```text
1. SHADOW 接线   → 每个 stage 单独接，接一个验一个（stage-days 计数）
2. 分叉矩阵归因 → 每条分叉写明原因，不允许"暂时未知"
3. ACTIVE soak  → 对着 PK_SOAK_AUTHORITY=0 的同 seed 基准读逐场 nz/mean/max
4. 回归全绿
5. 真实客户端录制对照  ← Climate 是在这一步之后才发现四个缺陷的
6. 翻默认开关
```

---

# 第三部分：任务表（完整迁移的工作分解）

这是**完整迁移的工作分解**，六个阶段 A–F，含已完成项。每条子任务标状态：`[x]` 完成、
`[~]` 部分、`[ ]` 未开始、`[-]` 已取消（附原因）。没有验收标准的条目不该进这张表。

**目标是全量迁移**：十二个域全部进入 `implemented_domain_mask`（`0xFFF`），整图 ACTIVE。所以
下面没有"要不要迁"的决策项，只有"怎么迁、按什么顺序迁"。

进度概览：

| 阶段 | 内容 | 状态 |
| --- | --- | --- |
| **A** | 基础设施：协议、线程、快照、存档骨架 | ✅ 完成 |
| **B** | CLIMATE 垂直切片：第一个域走通全流程 | ✅ 完成（带 6 项遗留） |
| **C** | 测量能力：证明收益、抓住 headless 抓不到的问题 | ⬜ **未开始，阻塞后续所有判断** |
| **D** | COUNTRY | 🔶 实现完整，接线未做 |
| **E** | MODIFIER | ⬜ 仅 store |
| **F** | EFFECT | ⬜ 仅 store |
| **G** | IDEOLOGY | ⬜ 仅 store |
| **H** | TRIGGER_INPUT | ⬜ 仅 store |
| **I** | EVENTS | ⬜ 仅 store |
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
- [x] 首帧 `adopt_reference_baseline`（worker store 全零 vs reference 带世界生成结果）

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
- [x] per-domain 授权门
- [x] 主线程 14 节点抑制门
- [x] `runtime_climate_authority_enabled` 默认 true
- [x] 回退路径（一个开关）

### B7 客户端暴露的缺陷 ✅
- [x] scalars 缺失（`insol_amp` 默认 0.20 vs profile 0.32，季节振幅只剩 62.5%）
- [x] pass_a 五条输出无回灌写者
- [x] 海冰累积（lane 被填零 → 每天从零冰起算）
- [x] weather field solve 从未运行（湿度跳变）

### B8 遗留（转入 P2） 🔶
- [ ] stage 重排：`feedback` 移到 `weather`/`distribute` 之后 → 验收：与生产语义一致且 soak 无回归
- [ ] ψ / cyclone / monsoon 自持推进 → 前置：解决 wind pass 与 weather 的次序
- [ ] 量级偏差归因（snow_cover +25%、moisture/WB30 偏高、VGP 符号相反）→ 验收：每条一对一映射到原因
- [ ] 按格数的启用阈值（小地图 +5.5% 负收益）→ 验收：阈值有实测依据
- [ ] 大地图回灌跟不上节拍 → 验收：`writeback_days` 达到 50/50
- [ ] 清理 `RuntimeClimateCommand` 5 个悬空 opcode → 验收：接上消费者或删除
- [x] ~~修 `implemented_domain_mask()` 过期注释~~（2026-09-08）

## 阶段 C：测量能力 ⬜ **最高优先级**

**为什么排在 Country 前面**：worker 化的主要卖点是帧延迟，而这个收益至今一次都没测到过；
同时 Climate 四个缺陷全部是真实客户端抓到的，headless 全绿。**不补上这两条，后续每个域都会
重复 Climate 的弯路。**

- [ ] **C1 真实客户端帧统计**：ACTIVE / OFF 各一次同 seed 会话
      → 验收：给出帧时间分布对比，回答"worker 化到底改善了什么"
- [ ] **C2 客户端字段录制对照 SOP**：固化成放行流程的第五步
      → 验收：可重复执行的脚本 + 判读标准，Country 放行时首次执行
- [ ] **C3 排除 harness 开销的性能口径**：headless 的 40ms 忙等轮询污染 `run_ms`
      → 验收：一个能直接比较 ACTIVE/OFF 的指标

## 阶段 D：Country 接入 🔶

实现已完整，缺的是接线与决策。

- [x] D1 `RuntimeCountryStore` + `RuntimeCountryPodAuthority`
- [x] D2 `plan_day` / `commit_day` 完整实现
- [x] D3 9 个 opcode 的 `apply_command`
- [x] D4 ACK 语义（grant tech 发 intent、commit 校验 acks）
- [x] D5 CPD2 存档 + roundtrip 测试
- [x] D6 SHADOW 诊断 adapter
- [ ] **D7 定夺两条存档路径**：host 用 `encode_country_core_checkpoint`，而
      `RuntimeCountryPodAuthority::encode_save` 没被调用
      → 验收：单一路径，另一条删除或注明用途
- [ ] **D8 盘点 opcode 差额**：legacy 20 vs POD 9
      → 验收：逐条列出「已实现 / 不需要 / 待实现」
- [ ] **D9 接进 host 主循环**：目前 `NativeSimulationHost` 没有 `_country_authority` 引用
      → 前置 D7、D8；验收：ACTIVE 下 Country stage 真实执行
- [ ] **D10 跨域读取确认**：谁在读 Country 字段、能否接受滞后一日
      → 验收：逐个消费者确认并记录
- [ ] **D11 按六步流程放行** → 前置 C1–C3、D7–D10；验收：mask 加 COUNTRY bit

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

## 阶段 E：MODIFIER（第三个域）⬜

**为什么排在其余域最前**：它是 Effect / Ideology / Economy 税率的共同下游，它不迁移，上面几个
域的写入路径就得跨 worker/主线程边界。

- [x] E1 `RuntimeModifierStore` + `RuntimeModifierPodState`
- [ ] E2 真实 plan/replay：目前只做过期删除与 intent 应用
      （`runtime_domain_pod.cpp:437`、`runtime_domain_authorities.cpp:450`）
- [ ] E3 迁移 legacy 5 个 opcode（`modifier_runtime.h:37-40`）
- [ ] E4 ACK：目前 pipeline 读 acks 计数但**不填充**（`runtime_domain_pod.cpp:452`）
- [ ] E5 snapshot 类型（当前无）
- [ ] E6 独立存档 section（当前混在 PDP3 里）
- [ ] E7 接入 host 真实 stage
- [ ] E8 放行

**特有难点**：四域 ModifierStore + daily freeze 语义。冻结发布与 worker 一日滞后叠加后是
"滞后两日"还是"滞后一日"，要先定清楚再动手。

## 阶段 F：EFFECT ⬜

- [x] F1 `RuntimeEffectStore` + `RuntimeEffectPodState`
- [ ] F2 真实 plan/replay：目前按 instance 调度并 emit intent（`runtime_domain_pod.cpp:411`）
- [ ] F3 迁移 legacy 6 个 action（`effect_runtime.h:56-63`）
- [ ] F4 ACK：目前 runner 里是 **synthetic ACK**（`runtime_domain_authorities.cpp:428`），
      要换成真实跨域屏障
- [ ] F5 snapshot 类型（当前无）
- [ ] F6 独立存档 section（当前 PDP3）
- [ ] F7 接入 host 真实 stage
- [ ] F8 放行

**特有难点**：它是**跨域原子事务的枢纽**。Country 的 grant tech、Ideology 的三选一、
Technology 的里程碑都靠它的 ACK 完成。迁移它等于同时改动这几个域的提交路径，需要
"Effect 在 worker、消费者在主线程"的中间态设计。

## 阶段 G：IDEOLOGY ⬜

- [x] G1 `RuntimeIdeologyStore` + `RuntimeIdeologyPodState`
- [ ] G2 真实 plan/replay：目前只 bump generation/rng（`runtime_domain_pod.cpp:396`），
      runner 侧做 pending_transition 排序 + xorshift（`:361`）
- [ ] G3 迁移 legacy 9 个 opcode（`ideology_runtime.h:30-40`）
- [ ] G4 ACK（当前无域级 ACK）
- [ ] G5 snapshot 类型（当前无）
- [ ] G6 存档 section（当前**无独立 section**）
- [ ] G7 接入 host 真实 stage
- [ ] G8 放行

**特有难点**：阶级民意门与互斥/联动组的求值依赖 Economy 的阶级数据。前置是 Economy 的读取
边界定清楚（见阶段 J），否则会形成 Ideology↔Economy 的循环依赖。

## 阶段 H：TRIGGER_INPUT ⬜

- [x] H1 `RuntimeTriggerStore` + `RuntimeTriggerPodState`
- [ ] H2 真实 plan/replay：目前递增 accumulator + 扫 events journal
      （`runtime_domain_pod.cpp:371`、`runtime_domain_authorities.cpp:315`）
- [ ] H3 **建立 POD 命令层**：当前 POD 侧无 opcode enum，legacy `TriggerRuntime::Action`
      有 15 项（`trigger_runtime.h:66-77`）
- [ ] H4 ACK：目前只有 intent 链，**无屏障完成语义**
- [ ] H5 snapshot 类型（当前无）
- [ ] H6 独立存档 section（当前 PDP3）
- [ ] H7 接入 host 真实 stage
- [ ] H8 放行

**特有难点**：它的输入是 Events journal、输出是 Effect，**两端都在迁移中**。三者的迁移顺序要
么串行（Events → Trigger → Effect 各自完整放行），要么设计一个三域同时切换的批次。

## 阶段 I：EVENTS ⬜

- [x] I1 `RuntimeEventsStore` + `RuntimeEventsPodState`
- [ ] I2 真实 plan/replay：目前每日 push 一条 journal（`runtime_domain_pod.cpp:496`）
- [ ] I3 命令层（当前无 opcode）
- [ ] I4 ACK（当前无）
- [ ] I5 snapshot 类型（当前无）
- [ ] I6 独立存档 section（当前 PDP3）
- [ ] I7 接入 host 真实 stage
- [ ] I8 放行

**特有难点**：journal 是**只增不改**的结构，跨 worker 边界时要定清楚"谁能 append"。如果主线程
与 worker 都能写，需要合并策略；如果只有 worker 能写，主线程侧的事件产生点全部要改成命令。

## 阶段 J：ECONOMY（最大工程）⬜

- [x] J1 `RuntimeEconomyStore` + `RuntimeEconomyPodState`
- [ ] J2 真实 plan/replay：目前是从 country snapshot 复制 treasury + 简化的
      population→production 投影（`runtime_domain_pod.cpp:471`、`runtime_domain_authorities.cpp:533`，
      注释明写 "real Economy authority will replace"）
- [ ] J3 迁移 legacy **23 个 opcode**（`economy_runtime.h:151-176`）
- [ ] J4 ACK：pipeline ack 槽当前为空（`runtime_domain_pod.cpp:490`）
- [ ] J5 snapshot 类型（当前无）
- [ ] J6 **PKSR ECONOMY section**：bundle 里目前完全没有它，存档仍全在 legacy
      `economy_runtime_persistence_*`（`native_simulation_host.cpp:1942-1987`）
- [ ] J7 接入 host 真实 stage
- [ ] J8 放行

**四个特有难点**（这也是它排在最后的原因）：

1. **冻结 epoch 与一日滞后的交互**。epoch 会跨多天冻结 country 快照，而 worker 权威本身又滞后
   一日。两者叠加的语义必须先定义清楚，否则经济结算读到的 country 状态会漂移。
2. **它已经是并行的**。`worker_enabled` 开启的是 `parallel_for_range` 按 cell 分 task
   （`parallel_dispatcher.h:45-99`），与 POD worker 是两套。迁移要决定：POD worker 内部继续
   用这套并行，还是改成 POD worker 的任务模型。**这不是"要不要迁"的问题，是"怎么迁"的问题。**
3. **守恒审计不能降级**。`aggregate_publish` 的 VERIFY 相位
   （`economy_runtime_publish.cpp:367`）失败会 `_fatal=true` 并让 GDScript 侧
   `world_clock.pause(true)`。搬到 worker 后，这条"审计失败立即暂停游戏"的链路要跨线程重建。
4. **13 个 stage 的顺序契约**。`BUILDING_PLAN → … → AGGREGATE_PUBLISH` 的主序（2.7.2）在
   worker 侧要逐 stage 提取，与 Climate 的九个 pass 是同一类工作，但 stage 数更多、跨域读取
   更密。

## 阶段 K：三个无 store 的域 ⬜

全量迁移要求 `implemented_domain_mask` 达到 `0xFFF`，所以这三个也必须有结论——但它们的"迁移"
不是搬状态，而是确认语义。

- [ ] **K1 GAMEPLAY_EFFECT**：当前无 store，`run_gameplay_effect` 只递增 generation/work_units
      （`runtime_domain_pod.cpp:457`）。需确认它是一个真实域还是历史占位；若是前者，补齐七步；
      若是后者，从枚举中移除并调整 `RUNTIME_ALL_DOMAIN_MASK`
- [ ] **K2 VISUAL**：worker 不得访问 Godot 对象，所以它**不可能**成为 worker 权威。需要的是把
      "intent 生产"迁进 worker、"intent 消费"留在主线程，并明确它在 mask 里代表哪一半
      （当前 SHADOW 刻意不发布 intent，`native_simulation_host.cpp:1318`）
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

本部分对着第三部分的任务表讲"到哪了"。**每个结论都能追到 A–F 里的具体条目。**

## 4.1 一句话与进度

十二个域的全量迁移里，**1 个已放行、1 个实现完整待接线、6 个只有 store、3 个待定语义**。

```text
A 基础设施       ████████████ 完成
B CLIMATE        ███████████░ 完成，6 项遗留（B8）
C 测量能力       ░░░░░░░░░░░░ 未开始  ← 阻塞后续所有判断
D COUNTRY        ██████░░░░░░ D1-D6 完成，D7-D11 未做
E MODIFIER       █░░░░░░░░░░░ 仅 store
F EFFECT         █░░░░░░░░░░░ 仅 store
G IDEOLOGY       █░░░░░░░░░░░ 仅 store
H TRIGGER_INPUT  █░░░░░░░░░░░ 仅 store
I EVENTS         █░░░░░░░░░░░ 仅 store
J ECONOMY        █░░░░░░░░░░░ 仅 store（最大工程，四个特有难点）
K 三个无 store   ░░░░░░░░░░░░ 未开始
L 整图收尾       ░░░░░░░░░░░░ 未开始
```

按七步模板算，E–J 六个域各欠 6–7 步，是这轮迁移剩余工作量的主体。

**唯一在生产中真实承担权威的域是 Climate。** 其余十一个域中，Country 有完整实现但未接线，
六个是诊断占位，三个结构上没有可迁移状态，COMMIT 是屏障机制本身。

## 4.2 域成熟度（对应任务表 B–K）

| 类 | 域 | 一句话 | 任务表 |
| --- | --- | --- | --- |
| **第 1 类：生产权威** | CLIMATE、COMMIT | ACTIVE 下真实承担，在 `implemented_domain_mask` | B（完成，遗留 B8） |
| **第 2 类：实现完整未接入** | COUNTRY | POD authority 有完整 plan/commit/9 opcode/ACK/CPD2，host 主循环没引用它 | D7–D11 |
| **第 3 类：诊断占位** | MODIFIER、EFFECT、IDEOLOGY、TRIGGER_INPUT、ECONOMY、EVENTS | 有 store，但 plan/replay 是投影或计数器 | 阶段 E–J |
| **第 4 类：无 store** | GAMEPLAY_EFFECT、VISUAL、INPUT_CAPTURE | 结构上没有可迁移状态，需确认语义 | 阶段 K |

「诊断占位」的准确含义：**代码能跑、能产出测试数据，但算的不是生产公式**。

逐域 × 八维度：

| 域 | POD store | plan/replay | opcode | ACK | snapshot | save | Host stage | mask |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| CLIMATE | 有 | **真实** | 定义 5 个，**无消费者** | 协议层有 | 有 | CLM2 | **ACTIVE 真 stage** | **在** |
| COMMIT | 无（barrier） | 真实 | — | — | 有 | PKSR envelope | 有 | **在** |
| COUNTRY | 有 | **真实但未接入** | 9 个已实现 | 有 | 有 | CPD2 | 仅 SHADOW adapter | 不在 |
| MODIFIER | 有 | 诊断 | legacy 5 | 部分 | 无 | PDP3 | 无 | 不在 |
| EFFECT | 有 | 诊断 | legacy 6 | 部分 | 无 | PDP3 | 无 | 不在 |
| IDEOLOGY | 有 | 诊断 | legacy 9 | 无 | 无 | 无独立 | 无 | 不在 |
| TRIGGER_INPUT | 有 | 诊断 | 无 POD | 部分 | 无 | PDP3 | 无 | 不在 |
| ECONOMY | 有 | 诊断 | legacy 23 | 空槽 | 无 | **无 POD section** | 无 | 不在 |
| EVENTS | 有 | 诊断 | 无 | 无 | 无 | PDP3 | 无 | 不在 |
| GAMEPLAY_EFFECT | **无** | 空转 | 无 | 无 | 无 | 无 | 无 | 不在 |
| VISUAL | 无（intent） | 诊断 | 无 | 无 | — | 无 | SHADOW 刻意不发布 | 不在 |
| INPUT_CAPTURE | 无（只读快照） | 校验 | — | — | 有 | — | 两模式均校验 | 不在 |

一条容易误读的：**「legacy N opcode」指主线程 runtime 的命令入口，不是 worker 队列**。
Economy 有 23 个 legacy opcode 不代表它的 POD 迁移靠前，它的 POD 侧仍是诊断投影。

### CLIMATE 细节

- **执行**：ACTIVE 真 stage（`native_simulation_host.cpp:1339-1448`）。
- **注意**：pipeline / authority runner 里另有一份 climate，那是**诊断投影**
  （`runtime_domain_pod.cpp:255`、`runtime_domain_authorities.cpp:172` 注释写明），不是权威
  路径。对拍和排障只应看 `RuntimeClimateAuthority`。
- **悬空件**：`RuntimeClimateCommand` 5 个 opcode（`runtime_pod_protocol.h:119`）全仓库只有
  定义处，无任何消费代码 → B8。

### COUNTRY 细节（下一个域）

缺的不是实现而是接线：

- **已有**：`plan_day`/`commit_day`（`runtime_country_pod.cpp:1128-1244`）、9 个 opcode
  （`:846-1042`）、ACK（grant tech 发 intent `:895`，commit 校验 `:1204`）、CPD2。
- **缺的**：host 主循环**没有 `_country_authority` 引用**；SHADOW 下只调
  `RuntimeCountryPodAdapter::execute_day` 做诊断（`native_simulation_host.cpp:1450-1477`）。
- **两条并存的存档路径** → D7：host 用 `encode_country_core_checkpoint`（`:1978`），而
  authority 自己的 `encode_save`（`runtime_country_pod.cpp:1257`）没被调用。

### 第 3 类六域细节

共同形态：有 store、有 PDP3 序列化、`stage_preflight` 返回 `domain_handler_not_migrated`
（`runtime_authoritative_domains.cpp:804`），只在 SHADOW diagnostic runner 里跑。

| 域 | 诊断实现干了什么 | 证据 |
| --- | --- | --- |
| MODIFIER | 过期删除 / 应用 intent 到 entries | `runtime_domain_pod.cpp:437`、`runtime_domain_authorities.cpp:450` |
| EFFECT | 按 instance 调度、emit intent、synthetic ACK | `:411`、`:397` |
| IDEOLOGY | 仅 bump generation/rng；runner 做 pending_transition 排序 | `:396`、`:361` |
| TRIGGER_INPUT | 递增 accumulator、扫 events journal | `:371`、`:315` |
| ECONOMY | 从 country snapshot 复制 treasury；简化 population→production 投影 | `:471`、`:533`（注释："real Economy authority will replace"） |
| EVENTS | 每日 push 一条 journal | `:496`、`:584` |

**ECONOMY 额外缺存档** → J6：PKSR bundle 只有 ENVELOPE / DOMAIN_POD / CLIMATE / COUNTRY
（`native_simulation_host.cpp:1942-1987`），它的存档仍全在 legacy `economy_runtime_persistence_*`。

### 第 4 类三个

- **GAMEPLAY_EFFECT**：`RuntimeAuthoritativeDomainStores` 无对应成员，`run_gameplay_effect`
  只递增 generation/work_units（`runtime_domain_pod.cpp:457`）。需确认是真实域还是历史占位 → K1。
- **VISUAL**：只有 `RuntimeVisualIntent`。SHADOW 下**刻意不把 shadow intents 泄漏到 visual
  ring**（`native_simulation_host.cpp:1318`）。
- **INPUT_CAPTURE**：只读快照，两种模式都只做校验。

## 4.3 测试与验收现状

### 怎么跑

```powershell
# 统一 runner：13 个 runtime_* + dots_completion_gate
tools\runtime\Invoke-RuntimeTests.ps1

# 单个测试
godot --headless --path Project/project-keynes --script res://tests/<name>.gd --quit

# Climate SHADOW 对拍
tools\runtime\run_climate_parity.ps1

# 性能录制（CLI 参数在 -- 之后，不是环境变量）
godot --headless --path Project/project-keynes --script res://tests/headless_perf_record.gd -- days=50 speed=50
```

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
| `runtime_country_pod_test.gd` | Country POD self-test（D1–D5） | `%d checks, %d failures` |
| `dots_completion/dots_completion_gate.gd` | 静态门禁：巨石行数、直写 grep、flag registry | `ALL GATES PASSED` |

> 输出格式是 `checks / failures`，**没有** `passed=N failed=M`；断言数运行时累加，无编译期固定
> 总数。所以"某测试应该有 N 个断言"这种判断不成立，只能看 failures 是否为 0。

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

### Climate（已放行，带着这些限制 → B8）

| 项 | 状态 |
| --- | --- |
| stage 次序与生产不同 | worker 的 `climate_feedback` 排在 `weather`/`distribute` 前，生产是后 |
| ψ / cyclone / monsoon 未接 | 刻意留空（推进输入是风场，而 wind pass 在 round 里排在 weather 之后） |
| 量级偏差 | snow_cover nz 比对照高约 25%，moisture / WB30 偏高；VGP 均值符号与对照相反 |
| 大地图跟不上节拍 | 180x120 下 `writeback_days=30/50` |
| 小地图负收益 | 60x40 下 `sus_sim_avg` +5.5%，且默认对所有尺寸开启 |
| C5 场景表未逐项验证 | 暴雨/干旱/降雪/河流运河/跨年/topology revision 从未单独构造 |

### 测量能力缺口（→ 阶段 C，影响所有域）

- **帧延迟收益无法测量**：headless 的 `frame_wall_ms` 恒 0，而这正是 worker 化的主要卖点。
- **`run_ms` 在 ACTIVE 下不可直接比**：harness 每天 40ms 忙等轮询（`SceneTree -s` 下
  `_process` 不跑，回灌只能手动驱动）会淹没真实差异。

### 危险默认值

- **`simulation_thread_mode` 键缺失时，C++ 侧 raw 默认是 `"ACTIVE"`**
  （`world_ext_simulation_host.cpp:44`，另有别名键 `mode`）。忘了传这个键的 harness 会静默
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

---

# 附录 A：文件地图

## 协议与 host

| 文件 | 内容 |
| --- | --- |
| `gdext/src/runtime_pod_protocol.h` | **契约单一源**：`RuntimeDomainId`（:328）、mask（:346）、stage 顺序（:353）、`RuntimeEnvironmentSnapshot`（:161）、各域命令与 ACK 结构 |
| `gdext/src/native_simulation_host.{h,cpp}` | worker 状态机、`implemented_domain_mask()`（h:101）、ACTIVE 准入（cpp:115）、day plan、save bundle（cpp:1942） |
| `gdext/src/world_ext_simulation_host.cpp` | GDScript 边界：capture 全部解析、writeback、parity 字段表、模式解析（:42） |
| `gdext/src/runtime_domain_pod.{h,cpp}` | 诊断级 POD pipeline（C 档六域都在这） |
| `gdext/src/runtime_domain_authorities.cpp` | 诊断 authority runner |
| `gdext/src/runtime_authoritative_domains.{h,cpp}` | 各域 store 定义、`stage_preflight` |

## Climate（唯一的生产权威域）

| 文件 | 内容 |
| --- | --- |
| `gdext/src/runtime_climate_authority.{h,cpp}` | **权威路径**：plan/commit、CLM2 序列化 |
| `gdext/src/runtime_climate_kernel.cpp` | worker round 编排、五个 stage_knobs stage 的守卫 |
| `gdext/src/runtime_climate_passes.{h,cpp}` | 九个 pass 的共享纯内核（生产与 worker 同一份） |
| `gdext/src/world_ext_climate.cpp` / `world_ext_weather.cpp` | 生产侧实现，**接线时的键名口径以它们为准** |
| `Project/.../scripts/geography/map_generator.gd` | capture、knobs 构建、stage 节拍 |
| `Project/.../scripts/game/world_runtime_host.gd` | worker 生命周期、模式决策（:520） |

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

`gdext/src/runtime_country_pod.{h,cpp}`（POD authority）、`gdext/src/country_runtime.{h,cpp}`
（legacy，命令屏障在 `:2289-2401`）、`gdext/src/world_ext_country.cpp`、
`Project/.../scripts/simulation/systems/country_daily_system.gd`。

## Economy

| 文件 | 内容 |
| --- | --- |
| `gdext/src/economy_runtime.cpp` | stage 枚举（h:662）、`run_slice_internal` 主序（:8991+）、epoch 门禁（:7076） |
| `gdext/src/economy_runtime_epoch.cpp` | 冻结 epoch：预检、country 快照、税率冻结 |
| `gdext/src/economy_runtime_publish.cpp` | `aggregate_publish`、**守恒审计 VERIFY**（:367） |
| `gdext/src/parallel_dispatcher.h` | `parallel_for_range`——Economy 的并行是这个，不是 POD worker |
| `Project/.../scripts/simulation/systems/economy_daily_system.gd` | SUS 侧包装、fatal 时 `world_clock.pause(true)` |

---

# 附录 B：开关清单

## B.1 决定权威模式的

| 开关 | 定义 | 默认 | 作用 |
| --- | --- | --- | --- |
| `runtime_climate_authority_enabled` | `world_runtime_host.gd:87` | **true** | true → 以 ACTIVE + `authoritative_domain_mask=0x802` 启动；false → SHADOW。**Climate 的总开关与回退路径** |
| `simulation_thread_mode` | 启动配置键，C++ 解析 `world_ext_simulation_host.cpp:42` | ⚠ **键缺失时 raw 默认 `"ACTIVE"`** | OFF / SHADOW / ACTIVE |
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
