# 运行时权威迁移：目标、设计框架、当前状态与任务

更新时间：2026-09-10（对照当前源码与 `Invoke-RuntimeTests.ps1` 校准进度表述；未重跑 suite）

**一句话现状**：十二个 domain 里 Climate 已是生产默认权威（`implemented_domain_mask =
CLIMATE|COMMIT = 0x802`，滞后一日）；Country 已完成共享生产核心、20 opcode、CPD2、K2-A
peer 协议和不可变 read-view/稀疏 territory 发布边界，Effect/Modifier 的真实 typed adapter
已接入，Modifier E2-E7 已完成 SHADOW plan/replay、ACK、snapshot 和独立存档，Ideology G2-G7
已完成 SHADOW plan/replay、跨域输入校验、deferred intent、ACK barrier、snapshot 和独立存档。
Trigger H2-H6 已完成共享 kernel、POD command/ACK、snapshot、TPD1 和 SHADOW parity bridge，
但 H7/H8 未执行，主线程 `TriggerRuntime`、Events 输入和 Effect 消费仍是生产边界。
K2-B 已完成
treasury/fiscal/cohort/market/research-purchase 九条异步 operation path 及故障/保存屏障验证；研究采购、财政
escrow、Country↔cohort cash、Country↔market goods、construction/canal treasury spend 的生产调用方
也已接入 **同步** Economy-owned coordinator（仍在 Economy stage 内 prepare/commit/apply）。Country Host
已形成持久 POD candidate、seal、intent outbox/result inbox、SHADOW replay 与 ACTIVE real peer
adapter；但尚未形成持久 Economy outbox/inbox 和正式唯一写者门禁，整图 ACTIVE 仍禁止，放行是
**逐域**的。Country 任务进度以第三部分 D1–D12 勾选为准：D1–D6/D9 完成，D7/D8/D10 部分完成，
D11–D12 未做。

2026-09-09 继续实施结果：Country Host 新增批量 admission 垂直切片。`enqueue_batch()` 在
发布任何 packet 前先检查整批容量，由 Host 统一分配单调 `submit_order`；ACTIVE Country
入口将可表达的数值命令编码为 worker packet，CREATE/RENAME/税务等依赖完整字符串或税务
状态的命令则明确返回 `country_worker_command_unsupported`，不会回退写同步 store。Country
peer intent 也已改为按 typed opcode 和 target domain 校验，不再把所有 intent 强制改成
`ENSURE_TECHNOLOGY_EFFECT`。该切片仍不改变正式能力 mask，也不表示完整 20 opcode 已进入
Country ACTIVE。

同日后续切片已补齐 Country 命令生命周期的终态出口：ACTIVE admission 返回显式
`status=Accepted` / `receipt_code=1`，`poll_country_command_receipts(after_request_id, limit)`
按 request-id 游标返回 `Committed` 或 `RejectedAtExecution`，ACK 等待期间不提前终结。
Host 自测同时覆盖“批内首条已进入 POD pending、后续 packet malformed”的整批拒绝；失败时
按 request id 清除本批 pending，避免已经发布终态的请求被下一边界重放。同步 SUS
`country_daily`、`run_country_slice()` 和 native runtime graph Country stage 也都改为根据实际
granted `authoritative_domain_mask & 0x004` 抑制同步写者。以上仍是测试授权下的协议/门控切片：
正式 `implemented_domain_mask()` 保持 `0x802`；Host receipt/request state 已接入 CPD2/PKSR
恢复安装，但这仍不构成 Country ACTIVE 放行。

财政 continuation 追加验证：`NativeEconomyRuntime` 的财政 reserve 已按 Country 拆成可续跑
的 epoch-open barrier。请求计划先冻结为 `requested_by_country`，之后每个 Economy slice
最多处理一个 Country；reserve 未完成时保持 `epoch_begin_post_fiscal_pending`，不执行
research demand、bullion quota 或后续 Economy stage。保存和恢复在此中间态明确拒绝，并返回
cursor/count/day/phase 诊断。`economy_fiscal_reservation_continuation_test.gd` 专项回归为
**failures=0**（断言数含循环，运行时打印 `checks/failures`，不要写死 N）。这仍属于
Economy-owned coordinator 的跨 slice continuation，不是持久 `NativeSimulationHost`
outbox/inbox；正式 `implemented_domain_mask` 仍为 `0x802`，Country ACTIVE/`0x806` 不变。

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
| `implemented_domain_mask()` | **编译期 constexpr**（`native_simulation_host.h:235`） | 该域**有真实 POD handler**，不代表它是权威 | `CLIMATE|COMMIT = 0x802` |
| `authoritative_domain_mask` | 启动配置键，由 GDScript 传入（`world_runtime_host.gd:563-569`） | 本次会话**实际要 worker 承担权威**的域 | ACTIVE 时 `0x802` |
| `completed_domain_mask` | 每日报告 | 当天实际跑完的域 | ACTIVE 下 `COMMIT|CLIMATE` |

准入逻辑（`native_simulation_host.cpp` 的 `start()` / ACTIVE 分支）：ACTIVE 要求
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
当前生产写者仍是同步 `NativeCountryRuntime`，但业务执行已经经 `run_slice_core()` 进入共享
`CountryCore`；`RuntimeCountryPodAuthority` 仍是诊断/SHADOW 适配器，不是第二套生产权威。

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
专项为 **failures=0**（断言含循环，以运行时打印为准）。Host 侧已接入持久 Country intent
outbox/result inbox、seal 元数据和三模式 transport：SHADOW 只回放 typed result，ACTIVE 才允许
真实 peer adapter；正式 Country granted-mask、唯一写者和 Economy 跨线程 outbox/inbox 仍未接入。

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

**与 Economy 的边界**：国库/科技/领土由同步 Country 权威，Economy 通过
`capture_country_epoch` 冻结快照消费；税率在 epoch begin 从 country + modifier 快照冻结；
研究采购在 Economy 的 `GOVERNMENT_RESEARCH_PROCUREMENT` stage 消费冻结的 country 政策。
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

这是**完整迁移的工作分解**，阶段 A–L，含已完成项。每条子任务标状态：`[x]` 完成、
`[~]` 部分、`[ ]` 未开始、`[-]` 已取消（附原因）。没有验收标准的条目不该进这张表。

**目标是全量迁移**：十二个域全部进入 `implemented_domain_mask`（`0xFFF`），整图 ACTIVE。所以
下面没有"要不要迁"的决策项，只有"怎么迁、按什么顺序迁"。

进度概览：

| 阶段 | 内容 | 状态 |
| --- | --- | --- |
| **A** | 基础设施：协议、线程、快照、存档骨架 | ✅ 完成 |
| **B** | CLIMATE 垂直切片：第一个域走通全流程 | ✅ 完成（带 6 项遗留） |
| **C** | 测量能力：证明收益、抓住 headless 抓不到的问题 | 🔶 工具完成；C1/C3 已采集，C2 双录制待执行 |
| **D** | COUNTRY | 🔶 D1–D6/D9 完成；D7/D8/D10 部分；D11–D12 未做 |
| **E** | MODIFIER | ✅ E2–E7 完成；E8 未执行，仍为 SHADOW |
| **F** | EFFECT | 🔶 F2-F6 完成；F7/F8 未完成 |
| **G** | IDEOLOGY | 🔶 G2–G7 完成；G8 未执行，SHADOW |
| **H** | TRIGGER_INPUT | 🔶 H2–H6 已实现；SHADOW parity，H7/H8 未执行 |
| **I** | EVENTS | 🔶 I1–I7 已实现；SHADOW/PROBE，I8 未执行 |
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

### B8 遗留（转入 P2） 🔶
- [ ] stage 重排：`feedback` 移到 `weather`/`distribute` 之后 → 验收：与生产语义一致且 soak 无回归
- [ ] ψ / cyclone / monsoon 自持推进 → 前置：解决 wind pass 与 weather 的次序
- [ ] 量级偏差归因（snow_cover +25%、moisture/WB30 偏高、VGP 符号相反）→ 验收：每条一对一映射到原因
- [ ] 按格数的启用阈值（小地图 +5.5% 负收益）→ 验收：阈值有实测依据
- [ ] 大地图回灌跟不上节拍 → 验收：`writeback_days` 达到 50/50
- [ ] 清理 `RuntimeClimateCommand` 5 个悬空 opcode → 验收：接上消费者或删除
- [x] ~~修 `implemented_domain_mask()` 过期注释~~（2026-09-08）

## 阶段 C：测量能力 🔶 **工具已实现，C1/C3 已采集，C2 待执行**

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
      缺失键、非有限值、逐字段 max/mean/p95、首差异和 `-2..+2` tick 最佳滞后。默认 field
      policy 为空，因此任何未声明差异都是 release blocker。
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
      - C2 ACTIVE/OFF 人工全量 SoA 双录制仍待执行，因此阶段 C 不能标记完成。

## 阶段 D：Country 接入 🔶

旧判断“POD 实现完整，只缺 Host 接线”已被生产语义盘点替代。当前完成的是共享生产核心及
K2-A 协议垂直切片，不是 Country 后台权威。

- [x] **D1 / K0-A 生产参考边界**：固定命令水位、边界、hash、receipt、intent/ACK 和首差异
      定位；`country_reference_trace_test.gd` 为 **failures=0**。
- [x] **D2 / K0-B 唯一生产核心**：同步 `NativeCountryRuntime::run_slice_core()` 使用纯 C++
      `CountryCore`；POD authority 保留为诊断/SHADOW，不再作为生产算法完成度依据。
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
      请求且实际授权后才可执行；当前正式 mask 仍拒绝 Country，因此此项不等于生产 ACTIVE。
- [~] **D7 / K2-B Country/Economy 资产事务桥**：研究采购、财政 reserve/return/collect、
      Country↔cohort 现金、Country↔market 商品、construction/canal treasury spend 已进入统一
      typed bridge。当前九条 operation path 均支持 peer prepared/applied ACK、commit decision、
      原 transaction ID 幂等重试、session/generation 校验、方向正确的现金/商品守恒和保存屏障：
      `treasury_spend`、`fiscal_reserve`、`fiscal_return`、
      `fiscal_collect`、`cash_to_cohort`、`cash_from_cohort`、`good_to_market`、
      `good_from_market`、`research_purchase`，均支持 peer prepared/applied ACK、
      commit decision、原 transaction ID 幂等重试、session/generation 校验、方向正确的现金/商品
      守恒和保存屏障；扣款方向另外使用 Country 侧 reservation。`runtime_country_economy_transaction_test.gd`
      当前为 **failures=0**（源码静态约 44 个 `_expect`；以运行时打印为准）。
      `NativeEconomyRuntime` 的研究采购调用已改为经由这条统一状态机；
      本轮进一步将政府研究采购改为 Economy-owned coordinator：候选市场按原
      `(country, price, market)` 稳定顺序冻结，预算/剩余需求/候选 cursor 保存于 epoch
      continuation；每次只消费固定候选窗口，未完成时保持
      `GOVERNMENT_RESEARCH_PROCUREMENT` stage，不提前进入 `TRADE_DISPATCH`。每笔采购
      现在由 Economy 完成市场库存、活商人、整数分账和溢出预检，再调用 Country typed
      prepare/commit，最后执行市场/商人 peer apply 并提交 Country applied ACK。该路径已不再
      调用 `economy_purchase_research_points()` 合成兼容入口。
      财政三类调用已通过
      `coordinate_country_fiscal_transaction()`；cohort cash 和普通 market goods 命令已不再调用
      `transfer_cash_*` / `transfer_good_*` compatibility wrapper；construction/canal treasury
      支出由 `coordinate_country_treasury_spend()` 统一完成 Country 多商品扣款、market 扣货、
      merchant 分账与 ACK，调用方不再重复应用 market/merchant 副作用。专项回归：
      `runtime_country_economy_transaction_test.gd` **failures=0**、`technology_procurement_runtime_test.gd`
      **PASS**、`canal_runtime_test.gd` **failures=0**；`treasury_construction_runtime_test.gd` 的 funded
      construction、现金失败原子性、守恒和 Country bridge 断言通过，但 grouped-material planner
      仍有 **2 个既有失败**。同步 Economy-owned coordinator 已接入生产路径；尚未完成的是跨线程
      outbox/inbox、fiscal/cohort/market continuation 的持久化调度以及正式 Host ACTIVE 接管；
      D7 总体仍未完成。
- [x] **D7a / K2-B fiscal reserve continuation**：`prepare_fiscal_budgets()` 冻结按国家请求
      计划，`advance_fiscal_reservation()` 跨 Economy slice 逐国推进；保存/恢复中间态明确
      拒绝，专项回归 `economy_fiscal_reservation_continuation_test.gd` 为 **failures=0**。这只是
      Economy-owned 可续跑边界，不是 Host ACTIVE 放行。
- [~] **D8 / K2-C Host stage 与唯一写者**：`NativeSimulationHost` 已有持久 Country POD
      candidate、sealed-day 执行入口、peer result inbox、intent outbox、`NeedPeerResults`
      停驻和 session/generation 校验；GDScript 侧已接入 SHADOW replay 与 ACTIVE real adapter
      transport。`RuntimeThreadReport`/direct report/perf report 现在统一暴露
      `country_worker_*` seal、session、generation、queue 和 reason 字段；新增
      `runtime_country_host_protocol_test.gd` 当前为 **failures=0**。2026-09-09 已补
      `enqueue_batch()` 整批 admission、Host request/submit-order identity、ACTIVE 数值命令
      packet 入口、unsupported 命令拒绝，以及 Country peer typed opcode/target-domain 校验；
      2026-09-09 同时修正 Host worker 的排序为 `(effective_day, sequence, submit_order)`，不再
      使用 `producer_id` 提前打破同日顺序。Country admission 现返回显式 `Accepted`，Host 通过
      request-id cursor 发布唯一 `Committed/RejectedAtExecution` 终态；批内 decode/preflight
      失败会清除本批 POD pending，避免终态后重放。同步 SUS、facade slice 与 native graph stage
      已按实际 granted Country bit 抑制同步写者。2026-09-09 已补 receipt/request state 的
      CPD2/PKSR 保存合并、恢复安装和 request-id 水位恢复；尚缺完整 20 opcode worker 状态、
      真实 ACTIVE 资产协调器、正式 Country granted-mask 和完整 Host stage 故障门禁；本次已
      补齐 peer rejection 的显式 retry barrier 和 Host 自测，但不改变上述阻塞项；
      主线程不得等待 worker。
- [x] **D9 / K2-D CountryReadView 与稀疏发布（2026-09-09）**：C++ host 保存不可变
      `RuntimeCountryPodSnapshot`，以 `generation/patch_base_generation` 提供游标消费，首次
      bootstrap/跳代提供 full owner snapshot，连续代次只返回 changed cell/owner patch；
      `MapGenerator.get_country_worker_read_view()` 与 `WorldRuntimeHost` 主线程消费边界已接入，
      通过 `MapData.country_slot_arr` 更新后复用 `CountryFacade.country_committed`，不增加第二套
      通知路径。纯身份/研究捕获不会产生 territory cell patch。专项回归：
      `runtime_country_pod_test.gd` **failures=0**（源码静态约 36 个 `_expect`）。
- [~] **D10 / K2-E 保存恢复与交接**：同步 checkpoint/Host bundle roundtrip 已有；2026-09-09
      增加 Host receipt/request state 的 CPD2/PKSR 保存与恢复安装，并恢复自动 request-id 水位；
      pending packet 缺 Accepted、terminal 与 request state 不一致、checksum/section 损坏均整体
      拒绝且不污染当前状态。2026-09-09 又增加 Host rejection retry barrier 的保存阻止检查，
      并验证 rejection 日业务 state 已发布时 read-view 使用独立单调发布游标，不把业务 generation
      的“不增加”误当成“没有新提交”。ACTIVE↔SYNC drain、目标 owner prepare/install、新 session
      epoch 和失败保持原 owner 尚未完成。
- [ ] **D11 / K3 正确性、故障和性能门禁**：多 seed/地图 1000 日、保存续跑、ACK/背压/
      事务故障、真实客户端、守恒、延迟和吞吐证据。
- [ ] **D12 Country 放行**：D6–D11 全部通过后才加入 COUNTRY bit，使 Climate + Country +
      COMMIT 为 `0x806`；当前保持 `0x802`，不得以测试授权入口绕过。

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

## 阶段 E：MODIFIER（第三个域）✅（E2–E7；E8 未执行）

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
- [ ] E8 放行

**当前边界**：四域 ModifierStore 的 worker-side authority 已在 SHADOW 中运行；capture barrier
之后到达的 command 顺延到下一安全日。`implemented_domain_mask()` 继续保持
`CLIMATE | COMMIT = 0x802`，legacy ModifierRuntime 仍是生产 authority，E8 前不做 snapshot
回灌或 ACTIVE 放行。

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
- [ ] F7 接入 host 真实 stage
- [ ] F8 放行

**特有难点**：它是**跨域原子事务的枢纽**。Country 的 grant tech、Ideology 的三选一、
Technology 的里程碑都靠它的 ACK 完成。迁移它等于同时改动这几个域的提交路径，需要
"Effect 在 worker、消费者在主线程"的中间态设计。

## 阶段 G：IDEOLOGY 🔶（G2–G7 已实现；SHADOW；G8 未执行）

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
- [ ] G8 放行

**当前边界**：G2–G7 只证明 worker-side replay、跨域输入校验、deferred intent 和 save
round-trip 的 SHADOW 语义；`implemented_domain_mask()` 仍为 `CLIMATE | COMMIT = 0x802`，
IDEOLOGY 不进入 ACTIVE authority mask。Ideology 使用上一份已提交的 Economy opinion snapshot，
避免当日 Ideology↔Economy 循环依赖。G8 还需要完整 catalog/长 replay parity、真实 Effect ACK、
save compatibility、host smoke、thread isolation、source scan 和 stress evidence。

## 阶段 H：TRIGGER_INPUT 🔶（H2–H6 已实现；SHADOW parity；H7/H8 未执行）

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
- [ ] H7 接入 host 真实 stage；本阶段仅完成 SHADOW 诊断桥接：Host 发布
      catalog/commands/reference frame，执行真实 worker plan/replay 并报告 parity/ACK；不发布
      Trigger authoritative mask，不抑制
      `TriggerDailySystem`，`implemented_domain_mask()` 继续为 `0x802`。
- [ ] H8 放行

**当前边界**：H2–H6 已完成 worker-side Trigger kernel、POD command/ACK、snapshot/save；
当前另有 SHADOW parity 诊断桥接。主线程 `TriggerRuntime`、Events 输入、Effect 消费仍是生产边界。Trigger
不进入 `implemented_domain_mask`，也不抑制 `TriggerDailySystem`；H8 需要在 Events/Effect
迁移和长程 parity/故障证据完成后单独执行。

## 阶段 I：EVENTS 🔶（I1–I7 已实现；SHADOW/PROBE；I8 未执行）

- [x] I1 `RuntimeEventsAuthority` + `RuntimeEventsSnapshot` + bounded snapshot ring
- [x] I2 真实 deterministic plan/replay：APPEND_BATCH、ACK_CONSUMER、容量淘汰和
      FNV-1a state hash；legacy journal event id 作为 bridge 幂等证据
- [x] I3 命令层：固定 little-endian ABI、ABI/count header、单批最多
      `RUNTIME_EVENTS_MAX_BATCH_RECORDS`，worker preflight 允许 Events probe
- [x] I4 ACK：legacy `ack_gameplay_events()` 先提交自己的 consumer cursor，再 best-effort
      镜像稳定 UTF-8 consumer key；bridge 失败只回传诊断，不影响 legacy consumer
- [x] I5 immutable snapshot：generation/hash/day、事件列、consumer ACK 列和幂等证据列；
      `poll_runtime_events_snapshot(after_generation)` 读取后立即释放 ring slot，旧 READY
      槽在 ring 满时可被最新写者回收
- [x] I6 独立 `EVT1` 存档 section：checksum、截断/版本/ABI/状态 hash 校验，restore
      事务性拒绝；不从 legacy `PDP3` 推导 Events POD state
- [x] I7 接入 `NativeSimulationHost` 日阶段、report、GDExtension 绑定和 GDScript wrapper；
      Events 可在 SHADOW/ACTIVE worker 中 probe，但不进入 `implemented_domain_mask`
- [ ] I8 放行

**当前边界**：legacy gameplay journal 仍是主线程实际消费来源。Events POD 只做镜像、诊断、
snapshot 与 save/restore，不向 legacy consumers 重复派发；`runtime_events_probe_enabled`
默认关闭。I8 还需要连续多日 bridge/snapshot soak、Trigger/Effect 消费边界和正式客户端验证。

## 阶段 J：ECONOMY（最大工程）⬜

- [x] J1 `RuntimeEconomyStore` + `RuntimeEconomyPodState`
- [ ] J2 真实 plan/replay：目前是从 country snapshot 复制 treasury + 简化的
      population→production 投影（`runtime_domain_pod.cpp:507+`、
      `runtime_domain_authorities.cpp:581+`，注释明写 "real Economy authority will replace"）
- [ ] J3 迁移 legacy **23 个 opcode**（`economy_runtime.h` opcode 枚举）
- [ ] J4 ACK：pipeline ack 槽当前为空（`runtime_domain_pod.cpp` 的 economy 分支）
- [ ] J5 snapshot 类型（当前无）
- [ ] J6 **PKSR ECONOMY section**：bundle 里目前完全没有它，存档仍全在 legacy
      `economy_runtime_persistence_*`
- [ ] J7 接入 host 真实 stage
- [ ] J8 放行

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

十二个域的全量迁移里，**Climate 已放行，Country 已完成共享核心和协议切片但尚未形成后台权威；
Modifier/EFFECT/Ideology/Trigger 已有真实 POD SHADOW 组件，Events 已有独立 SHADOW/PROBE
authority，Economy 仍主要是诊断投影，3 个域待定语义**。

```text
A 基础设施       ████████████ 完成
B CLIMATE        ███████████░ 完成，6 项遗留（B8）
C 测量能力       ████████░░░░ 工具完成；C1/C3 已采集，C2 双录制待执行
D COUNTRY        ███████░░░░░ D1–D6/D9 完成；D7/D8/D10 部分；D11–D12 未做
E MODIFIER       ████████░░░░ E2-E7 完成，E8 未做（SHADOW）
F EFFECT         ████████░░░░ F2-F6 完成，F7/F8 未做
G IDEOLOGY       ████████░░░░ G2-G7 完成，G8 未做（SHADOW）
H TRIGGER_INPUT  ████████░░░░ H2-H6 完成，SHADOW parity；H7/H8 未做
I EVENTS         ████████░░░░ I1-I7 已实现，SHADOW/PROBE，I8 未做
J ECONOMY        █░░░░░░░░░░░ 仅 store（最大工程，四个特有难点）
K 三个无 store   ░░░░░░░░░░░░ 未开始
L 整图收尾       ░░░░░░░░░░░░ 未开始
```

按逐域模板算，未完成的 E8、F7/F8、G8、H7/H8、I8 和阶段 J 仍是这轮迁移剩余工作量的主体；
SHADOW 组件完成不等于生产 authority 放行。

**唯一在生产中真实承担 gameplay 权威的 worker 域是 Climate。** Country 的同步生产路径已使用
共享核心，且同步 Economy-owned 资产 coordinator 已接入生产调用方，但 Host 仍未取得 Country
权威；Modifier、Ideology 和 Trigger 已具备真实 SHADOW POD authority，Events 已具备独立 probe
authority，但各自 legacy 主线程边界仍承担生产职责。其它未放行域仍是协议切片、SHADOW 或诊断
实现，三个结构上没有可迁移状态，COMMIT 是屏障机制本身。

## 4.2 域成熟度（对应任务表 B–K）

| 类 | 域 | 一句话 | 任务表 |
| --- | --- | --- | --- |
| **第 1 类：生产权威** | CLIMATE、COMMIT | ACTIVE 下真实承担，在 `implemented_domain_mask` | B（完成，遗留 B8） |
| **第 2 类：共享核心与协议切片** | COUNTRY | 20 opcode 和同步生产核心已统一；K2-A peer、K2-B 同步资产 coordinator、K2-D ReadView、K2-C Host 协议切片已验证；跨线程 outbox/唯一写者/ACTIVE 未完成 | D1–D12 |
| **第 3 类：SHADOW/POD 迁移中** | MODIFIER、EFFECT、IDEOLOGY、TRIGGER_INPUT、ECONOMY、EVENTS | Modifier/EFFECT/Ideology/Trigger 已有真实 POD 组件，Events 已有独立 SHADOW/PROBE authority；Economy 仍主要是诊断投影 | 阶段 E–J |
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
| COUNTRY | 有（诊断） | **共享生产核心；Host stage 部分接入** | 20 个核心完成；Host 数值 transport/receipt 已接入，worker opcode 仍不完整 | Effect/Modifier adapter 已验证；**同步** Economy coordinator 已接；Host 跨线程 outbox **未接** | immutable ReadView 与稀疏 patch 已验证 | CPD2 v2 / PKCN v13；Host receipt/request state 已随 PKSR 保存恢复 | SHADOW/protocol probe | 不在 |
| MODIFIER | 有（四域隔离） | **真实 SHADOW 双缓冲 plan/replay** | 固定 POD payload；legacy 5 已迁移 | **真实 Effect→Modifier ACK barrier** | immutable ring | **MDF2**（PDP4 不重复写） | **SHADOW 完整 stage** | 不在 |
| EFFECT | 有 | **独立真实 POD；未接 Host 日循环** | 6 类 action | 真实多 adapter 状态机 | 独立 immutable | EFP1 | 无日 stage（仅 configure/save） | 不在 |
| IDEOLOGY | 有 | **真实 SHADOW 双缓冲 plan/replay** | 固定 POD payload；legacy 9 已迁移 | **真实 Effect ACK barrier；无 synthetic ACK** | immutable snapshot（Country/Economy 输入校验） | **IDP1**（`1 << 8`，不从 PDP3/PKID 恢复） | **SHADOW 完整 stage**（Country 之后、Effect 之前） | 不在 |
| TRIGGER_INPUT | 有 | **真实 SHADOW plan/replay** | 6 个固定 opcode；legacy Action `1,2,3,4,10,11,12,13,14,15` 保留 | required ACK + 真实 receipt barrier | immutable POD snapshot | **TPD1**（独立 section，`1 << 4`） | **SHADOW parity bridge** | 不在 |
| ECONOMY | 有 | 诊断 | legacy 23 | 空槽 | 无 | **无 POD section** | 无 | 不在 |
| EVENTS | 有 | **真实 SHADOW/PROBE deterministic plan/replay** | APPEND_BATCH、ACK_CONSUMER、CONFIGURE_CAPACITY、CLEAR_RESET | **worker ACK + legacy cursor bridge** | **immutable snapshot ring** | **EVT1** | **SHADOW/PROBE 日阶段** | 不在 |
| GAMEPLAY_EFFECT | **无** | 空转 | 无 | 无 | 无 | 无 | 无 | 不在 |
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
- **悬空件**：`RuntimeClimateCommand` 5 个 opcode（`runtime_pod_protocol.h:139`）全仓库只有
  定义处，无任何消费代码 → B8。
- **抑制**：`climate_worker_authoritative()` 为真时主线程跳过**整张** native daily /
  schedule graph，而不是历史文档写的“14 个节点逐一抑制”。

### COUNTRY 细节（下一个域）

生产核心已经统一，K2-A peer 链、K2-B 同步资产 coordinator、K2-D read-view 发布边界已完成，
但后台权威闭环还没有形成：

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
  同步 `NativeCountryRuntime` 处理，不改变 `implemented_domain_mask = 0x802`。
- **尚缺**：跨帧/跨线程持久 Host outbox/inbox、正式 Country 唯一写者门、ACTIVE↔SYNC 交接和
  K3 长程/故障/性能门禁。
- **权威结论**：`RuntimeCountryPodAuthority` 仍是诊断/SHADOW；当前生产写者仍为同步
  `NativeCountryRuntime`。`implemented_domain_mask()` 保持 `0x802`，不能把协议测试解释成
  Country ACTIVE。

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
  `implemented_domain_mask()` 保持 `0x802`，E8 未执行。
- **存档**：新格式为 PDP4 + 独立 `MDF2`（save bit `1 << 5`），旧 PDP3 仅做一次性兼容迁移。

未放行域的诊断/SHADOW 实现如下：

| 域 | 诊断实现干了什么 | 证据 |
| --- | --- | --- |
| EFFECT | legacy store 仍为 SHADOW/reference；独立 POD authority 已完成 F2-F6，但未进入 Host 日循环（Host 仅有 configure/save/restore） | `runtime_effect_pod.{h,cpp}` |
| IDEOLOGY | 独立 POD SHADOW authority：9 opcode、确定性排序、bounded slice/continuation、deferred Effect intent 和真实 ACK barrier；legacy runtime 仍为生产参考 | `runtime_ideology_pod.{h,cpp}`、`native_simulation_host.{h,cpp}` |
| TRIGGER_INPUT | 共享 Trigger kernel 的真实 POD plan/replay、6-opcode 命令层、ACK barrier、immutable snapshot、TPD1 save 和 SHADOW parity；主线程 `TriggerRuntime` 仍是生产 authority | `runtime_trigger_kernel.{h,cpp}`、`runtime_trigger_pod.{h,cpp}`、`native_simulation_host.{h,cpp}`、`world_ext_trigger.cpp` |
| ECONOMY | 从 country snapshot 复制 treasury；简化 population→production 投影 | `runtime_domain_pod.cpp:507+`、`runtime_domain_authorities.cpp:581+`（注释："real Economy authority will replace"） |
| EVENTS | legacy journal 的独立 SHADOW/PROBE 镜像：确定性 append/ACK、容量淘汰、snapshot 与 EVT1 restore；不重复派发给 legacy consumer | `runtime_events_authority.{h,cpp}`、`world_ext_events.cpp`、`native_simulation_host.{h,cpp}` |

**ECONOMY 额外缺独立 POD 存档** → J6：PKSR bundle 已有 Trigger 等独立 domain section，
但仍没有 Economy POD section；Economy 存档仍全在 legacy `economy_runtime_persistence_*`。

### 第 4 类三个

- **GAMEPLAY_EFFECT**：`RuntimeAuthoritativeDomainStores` 无对应成员，`run_gameplay_effect`
  只递增 generation/work_units（`runtime_domain_pod.cpp:493`）。需确认是真实域还是历史占位 → K1。
- **VISUAL**：只有 `RuntimeVisualIntent`。SHADOW 下**刻意不把 shadow intents 泄漏到 visual
  ring**（`native_simulation_host.cpp:4183`）。
- **INPUT_CAPTURE**：只读快照，两种模式都只做校验。

## 4.3 测试与验收现状

### 怎么跑

```powershell
# 统一 runner：20 个 runtime_* + dots_completion_gate（共 21）
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
| `country_reference_trace_test.gd` | 生产边界参考轨迹（D1） | `failures=0` |
| `country_runtime_test.gd` | 同步共享核心、命令/税务/信号/PKCN（D2–D4） | `failures=0` |
| `runtime_country_pod_test.gd` | Country POD / read-view（D9） | `failures=0`（静态约 36 `_expect`） |
| `runtime_country_peer_bridge_test.gd` | 研究完成、真实 Effect/Modifier ACK、同日续跑、拒绝重试、保存 barrier（D5-D6） | `failures=0`（含循环断言） |
| `runtime_country_save_roundtrip_test.gd` | PKCN/CPD2/PKSR 恢复（D4/D10） | `failures=0` |
| `runtime_country_economy_transaction_test.gd` | K2-B 九类 Country/Economy asset transaction path | `failures=0`（静态约 44 `_expect`） |
| `runtime_country_host_protocol_test.gd` | Host admission/receipt/peer transport（D8） | `failures=0` |
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
| `runtime_effect_pod_test.gd` | Effect F2-F6 self-test（统一 suite 已收录） | `failures=0` |
| `dots_completion/dots_completion_gate.gd` | 静态门禁：巨石行数、直写 grep、flag registry | `ALL GATES PASSED` |

> 输出格式是 `checks / failures`，**没有** `passed=N failed=M`；断言数运行时累加，无编译期固定
> 总数。所以"某测试应该有 N 个断言"这种判断不成立，只能看 failures 是否为 0。含循环的 harness
> （peer bridge、fiscal continuation）更不要把某次运行的 checks 写进总纲当契约。

2026-09-10 文档校准说明：统一 runner 现为 **20 个 runtime_* + dots_completion_gate = 21**。
2026-09-09 文档曾记载 suite **19/21**（`runtime_climate_save_roundtrip_test` 因既有 Economy
bootstrap 缺 timber/stone 超时，`dots_completion_gate` 因脚本行数/直写门禁失败）；仓库内
`artifacts/runtime/s0-baseline/test-summary.json` 仍是更早的 17/19 归档。本次校准**未重跑**
suite。Ideology / Modifier / Events / Trigger 专项此前均为 failures=0；它们不构成 H7/H8 或
I8 放行，也未进入 `implemented_domain_mask`。

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

## Ideology（G2–G7，SHADOW-only）

| 文件 | 内容 |
| --- | --- |
| `gdext/src/runtime_ideology_pod.{h,cpp}` | numeric catalog、9 个 legacy opcode、确定性排序、copy-on-write plan/replay、head cursor、bounded slice、same-day continuation、Country/Economy 输入校验、deferred typed intent、真实 Effect ACK barrier、immutable snapshot、IDP1 序列化/恢复 |
| `gdext/src/native_simulation_host.{h,cpp}` | Ideology bootstrap、Country 之后/Effect 之前的 SHADOW 日阶段、ACK 收集、snapshot publication、IDP1 section；不把 deferred intent 视为完成或 ACTIVE |
| `gdext/src/world_ext_ideology.cpp` | 主线程 catalog/snapshot capture、worker command ingress、typed intent/ACK polling、worker snapshot facade；不暴露 worker store 或 Godot 对象给 worker |
| `gdext/src/ideology_runtime.{h,cpp}` | legacy `NativeIdeologyRuntime` 生产参考 authority 与 POD catalog export；`PKID` 仍只属于同步 runtime |
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

## Climate（唯一的生产权威域）

| 文件 | 内容 |
| --- | --- |
| `gdext/src/runtime_climate_authority.{h,cpp}` | **权威路径**：plan/commit、CLM2 序列化 |
| `gdext/src/runtime_climate_kernel.cpp` | worker round 编排、五个 stage_knobs stage 的守卫 |
| `gdext/src/runtime_climate_passes.{h,cpp}` | 九个 pass 的共享纯内核（生产与 worker 同一份） |
| `gdext/src/world_ext_climate.cpp` / `world_ext_weather.cpp` | 生产侧实现，**接线时的键名口径以它们为准** |
| `Project/.../scripts/geography/map_generator.gd` | capture、knobs 构建、stage 节拍 |
| `Project/.../scripts/game/world_runtime_host.gd` | worker 生命周期、模式决策（Climate ACTIVE → `authoritative_domain_mask=0x802`） |

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
| `gdext/src/runtime_country_pod.{h,cpp}` | 诊断/SHADOW POD authority；不得作为生产语义完整或 ACTIVE 的证据 |
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
| `runtime_climate_authority_enabled` | `world_runtime_host.gd:90` | **true** | true → 以 ACTIVE + `authoritative_domain_mask=0x802` 启动；false → SHADOW。**Climate 的总开关与回退路径** |
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

E2-E7 已完成，E8 未执行。Modifier POD 已具备 worker-side plan/replay authority、四域隔离、五个 legacy opcode、真实 Effect -> Modifier ACK barrier、immutable snapshot ring 和独立 MDF2 存档 section。implemented_domain_mask 仍为 CLIMATE | COMMIT = 0x802；Modifier 不进入 ACTIVE authority，legacy ModifierRuntime 继续是主线程生产 authority，worker snapshot 不回灌 legacy store。

Modifier snapshot 只在安全日边界发布并按 generation 单调消费。capture barrier 之后到达的 Modifier command 顺延到下一日；当前日中途不插入。新 composite 状态写入 PDP4，Modifier 独立写入 save bit 1 << 5 的 MDF2；旧 PDP3 只保留一次性兼容迁移读取。
