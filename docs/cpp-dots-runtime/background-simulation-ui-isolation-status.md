# Project.Keynes 后台模拟与 UI 隔离：规划、进度与未完成项

> 文档性质：当前工程状态和后续实施的事实源。  
> 更新时间：2026-09-04。  
> 适用平台：Windows x86_64 首发。  
> 重要：本文把“已经落地的代码”“可运行但非权威的骨架”“尚未完成的迁移”分开描述。不要把 SHADOW worker 骨架误认为 ACTIVE 模拟器。

## 1. 用户目标与硬约束

本项目要解决的问题是：游戏开到 50 倍速时，日程推进仍然很慢，同时模拟卡顿会拖慢渲染和 UI 拖拽。

最终验收目标固定为：

- `speed=50` 表示目标 50 个模拟日/现实秒；达到目标后主动让出 CPU，不以无限制满载换取速度。
- 模拟权威永远不跳日、不重排命令、不改变确定性结果；可视层允许丢弃中间日，只显示最新提交。
- 主线程负责输入、UI、Godot Object、MapData、渲染和 GPU 上传；模拟线程不调用任何 Godot API。
- 主线程任何路径都不得等待模拟线程、锁、condition variable、worker task 或 save encode。
- UI 拖拽按稳定 60 FPS 验收：帧时间 P99 `<=16.7ms`，输入到视觉反馈 P99 `<=50ms`。
- 可视状态最多落后权威状态 100ms；没有快照 buffer 时只能丢可视发布，不能丢模拟状态。
- Windows worker 与 native executor 使用 `BELOW_NORMAL`；普通模式保留至少 2 个逻辑核心，交互模式保留至少 4 个逻辑核心。四核及以下交互时不启用额外 worker。
- 模式只能在启动/新开局时选择，不能在同一局热切换：`OFF`、`SHADOW`、`ACTIVE`。
- `ACTIVE` 只有在全部权威 daily/yearly domain 完成纯 C++ POD 迁移、`graph_coverage_state=complete` 且无残留 GDScript 权威时才可开放。
- 存档升级为 PKSV v2；旧 PKSV v1 保留但明确标记“不兼容”，不删除、不迁移。

## 2. 目标架构

```text
Godot 主线程
  输入 / UI / 渲染 / Godot Object / MapData / GPU 上传
             │
             ├── 有界 POD 命令队列 ──→ NativeSimulationHost
             │                           时钟、Runtime Graph、各 domain、事件、保存
             │
             └── 最新不可变提交快照 ←── 三缓冲快照环
```

### 2.1 所有权

`DCWorldExt` 是 GDExtension facade，不再承担后台线程中的业务状态。它只做：

- 主线程配置和参数校验；
- `Dictionary`/`Variant`/`PackedArray` 到 POD 的复制；
- 命令入队；
- commit、receipt、save bundle 到 Godot `Dictionary` 的转换；
- MapData、视觉层和 GPU 的主线程同步。

`NativeSimulationHost` 最终独占：

- Country、Economy、Effect、Modifier、Ideology、Trigger、Climate、Events 的可变 native store；
- graph cursor、整数日期、年度 RNG、climate anomaly；
- 命令/回执队列、三缓冲提交快照、异步保存 bundle；
- 运行时状态机和时间债务。

worker 绝不保存 `Object *`、`MapData *`、`Variant`、`Dictionary`、Godot PackedArray 或场景树引用。

### 2.2 日屏障顺序

协议中固定并版本化的阶段顺序为：

```text
COUNTRY
→ TRIGGER_INPUT
→ IDEOLOGY
→ EFFECT
→ MODIFIER
→ GAMEPLAY_EFFECT
→ ECONOMY
→ EVENTS
→ VISUAL
→ COMMIT
```

每个 domain 必须实现：

```text
纯 POD calculate plan
→ 按 stable id/chunk id 固定顺序 replay/commit
→ 生成 dirty intent、事件 intent、资源 delta、state hash
```

并行计算只能使用固定分块、固定归并顺序和纯 C++ `NativeParallelExecutor`；不能从后台 worker 调用 Godot `WorkerThreadPool`。

## 3. 当前已落地内容

### 3.1 后台 Host 与生命周期

已新增/接入：

- `gdext/src/native_simulation_host.h/.cpp`
- `gdext/src/runtime_pod_protocol.h`
- `gdext/src/runtime_snapshot_ring.h/.cpp`
- `gdext/src/native_parallel_executor.h/.cpp`
- `gdext/src/world_ext_simulation_host.cpp`
- `DCWorldExt` 绑定和 facade API。

已经具备：

- 状态机：`STOPPED`、`STARTING`、`RUNNING`、`PAUSED`、`SAVE_PENDING`、`STOPPING`、`FAULTED`。
- `request_runtime_stop()` 只设置原子停止标志并唤醒 condition variable。
- worker 发布 `STOPPED` 后，复用 host 时通过 detached reaper 回收旧 `std::thread`；主线程不 join。
- `DCWorldExt` 析构时才作为进程退出兜底等待 worker/reaper。
- worker 创建异常转换为 `worker_thread_create_failed`，并回到可复用 `STOPPED`，避免永久停在 `STARTING`。
- STOPPING 或已设置停止标志时拒绝保存请求，返回 `runtime_worker_stopping`。
- worker 在进入暂停、运行和每个模拟日之前重复检查停止标志，降低停止竞态。

### 3.2 POD 协议与命令边界

已具备：

- `RuntimeCommandEnvelope` 固定字段：`request_id`、`producer_id`、`sequence`、`observed_generation`、`requested_day`、`effective_day`、`domain`、`opcode`、`payload_offset`、`payload_size`。
- 固定容量命令队列 4096，payload 上限 1024 字节；队列满立即返回 `command_queue_capacity_exceeded`。
- worker 按 `(effective_day, producer_id, sequence, request_id)` 稳定排序。
- 日期已过期时 facade 计算 `effective_day=max(requested_day, committed_day+1)`。
- 非法 payload/value 在主线程拒绝；未知 domain/opcode 在 worker 日边界生成确定性 preflight 回执。
- 回执队列容量 8192，回执不静默丢失；满载计数进入报告。
- producer sequence 支持恢复和保存。

### 3.3 输入快照边界

`capture_runtime_inputs()` 已从 Godot 输入复制出 `RuntimeEnvironmentSnapshot`，包括：

- 日期、季节相位、climate anomaly、vision revision、fog solved；
- 温度、30 日温度、湿度、可用植物水、降水、雪盖、天气强度；
- elevation、纬度、邻接、terrain、landform、vegetation、cover、water、river；
- canal edge/water、trade passable/move-cost LUT、visible；
- building resource reserve/extra。

发布前已校验：PackedArray 类型、float finite、数组尺寸、邻接范围、交易 LUT 256 项、cell 数量上限，以及 generation 单调性。worker 只读取 immutable `shared_ptr` 快照。

### 3.4 提交与视觉快照

已具备：

- `RuntimeCommitHeader`：generation、from/committed day、产生时间、dirty families、state hash、回执数量。
- 三缓冲 `FREE → WRITING → READY → READING`；worker 不覆盖 READING buffer。
- 没有空闲 buffer 时只丢可视发布，累计 `snapshot_publish_drop_count`。
- commit 标量头与视觉 buffer 分离；视觉最多 20Hz，命令/重大 dirty family 可立即发布。
- generation 过期 patch 返回 `runtime_generation_expired`。
- 主线程缓存最近消费的 immutable commit，避免多次轮询混用 generation。
- `WorldRuntimeHost._process()` 已接入非阻塞消费骨架：ACTIVE 且 worker ready 时每帧最多采纳一个最新 generation，
  视觉 family 按 0.75ms/0.25ms（交互）预算和 cursor 分片；generation 过期直接作废，提交通过
  `simulation_committed` 仅通知展示，不调用同步模拟。

### 3.5 时钟和时间债务

worker 使用 `steady_clock`，按 `speed_days_per_second` 形成时间债务：

- 性能足够时通过 condition variable 等待下一个模拟日；
- 性能不足时连续追赶，但每次最多处理 8 个日，永远不跳过模拟日；
- 时间债务限制在 `[0,100]` 日，超过上限饱和；
- pause、改速、stop、save 都通过控制消息唤醒，不使用忙等轮询。

报告同时暴露 `simulation_time_debt_days` 和直接 host 查询别名 `time_debt_days`；`main_wait_on_sim_us` 固定应为 0。

### 3.6 NativeParallelExecutor 与交互 QoS

已新增固定 native worker pool：

- 普通模式预留 2 个逻辑核心；
- interactive 模式在大于四核设备上预留 4 个逻辑核心；
- 四核及以下 interactive 模式使用协调线程顺序执行；
- Windows worker priority 为 `BELOW_NORMAL`；
- 固定 task group、无 Godot API、可报告 dispatch/task/fault 计数。

### 3.7 ACTIVE 门禁

当前 `NativeSimulationHost::implemented_domain_mask()` 只返回 `COMMIT`。因此：

- `SHADOW` 可以运行时钟、命令排序、输入快照、commit ring、保存和故障路径；
- `ACTIVE` 明确返回 `runtime_native_domains_incomplete`，不会以假 ACTIVE 运行；
- `graph_coverage_complete=true` 只是调用者的资格提示，不能伪造权威覆盖；
- 当前权威仍是 OFF/同步 SUS 路径。

### 3.8 存档边界

已完成：

- `SaveRepository.FORMAT_VERSION = 2`；
- PKSV v1 文件保留、列表显示 `format_version` 和 `incompatible`；
- 读取 v1 返回 `save_format_version_incompatible`，不删除文件、不被 `.bak` fallback 覆盖成 `save_missing`；
- `simulation_runtime` section 可保存 immutable PKSR v2 runtime envelope；
- PKSR v2 envelope 当前包含 committed day、暂停/速度、generation/hash、环境 generation/day、climate anomaly、time debt、pending commands、producer sequence、ABI/section metadata 和 checksum；PKSR v1 明确拒绝；
- save bundle 只消费一次；保存期间 UI 不等待 worker。

### 3.9 Country Phase B 边界切片（本次继续工作的实际落地）

本次只推进了不会改变权威归属的安全切片：

- `runtime_pod_protocol.h` 新增固定容量 `RuntimeCountryCommandBatch`（256 条）和无字符串指针的 `RuntimeCountryCommand`；所有字段都是整数/定长数组，可作为后续 worker ABI 的稳定输入。
- 新增 `runtime_country_research_weights_valid()`，统一执行四域权重每项 `0..10000`、总和必须为 `10000` 的检查。
- `NativeCountryRuntime::submit_commands()` 在构造内部 pending command 前预检整个 batch 的研究权重子集；非法策略返回 `country_research_weight_policy_invalid`，且同批次任何先前合法项也不会进入 pending 队列。
- `country_facade.gd::set_research_weights()` 在 GDScript facade 先做同样的早拒绝，减少一次 GDExtension 往返；合法命令语义不变。
- `technology_research_runtime_test.gd` 增加越界、总和非法的早拒绝断言。
- `docs/cpp-dots-runtime/index.md` 增加本状态总文档入口。

这一步没有把 Country 接入 `NativeSimulationHost`，没有修改 `implemented_domain_mask()`，也没有打开 ACTIVE；`run_day_pod()` 仍然因为命令批和跨域 ACK 未完成而不是 worker authority。

## 4. 当前验证证据

最近一次 Windows Debug GDExtension 构建：

```text
scons platform=windows target=template_debug -j4
成功
```

Windows Release 构建：

```text
scons platform=windows target=template_release -j4
成功，template_release DLL 已生成/为最新
```

Godot 4.6.2 headless focused suite：

| 测试 | 结果 |
|---|---:|
| `runtime_thread_isolation_test.gd` | 53 checks, 0 failures |
| `runtime_snapshot_ring_test.gd` | PASS |
| `native_runtime_graph_api_test.gd` | PASS |
| `save_repository_test.gd` | 21 checks, 0 failures |
| `technology_research_runtime_test.gd` | PASS |
| `perf_recorder_test.gd` | 64 checks, 0 failures |

测试运行时有 Godot headless 的资源/RID 泄漏警告，但没有功能断言失败；这些警告不能被误写成线程隔离通过或失败的依据。

已验证的线程契约包括：

- worker 异步启动和推进日期；
- `main_wait_on_sim_us=0`；
- time debt 不超过 100；
- ACTIVE 不完整时拒绝；
- SHADOW 非权威；
- 同 generation 不重复发布；
- 过期 patch 被丢弃；
- 输入快照 stale/shape/LUT 校验；
- 稳定 producer 排序回执；
- 命令队列满立即失败；
- 停止期间保存立即拒绝；
- 停止、restore、重启 host；
- pending command 保存后恢复并生成确定性回执；
- v1 存档明确不兼容。

## 5. 原始性能基线

基线文件：`tmp/perf_record_20260903_235556.csv`。该文件有 164 条记录，当前采样统计为：

| 字段 | avg | P95 | P99 | max |
|---|---:|---:|---:|---:|
| `t_sus_ms` | 122.973 | 168.854 | 175.101 | 175.282 |
| `t_render_ms` | 0.092 | 0.706 | 0.746 | 0.750 |
| `t_ui_ms` | 0.232 | 0.247 | 0.263 | 0.266 |
| `frame_wall_ms` | 28.379 | 36.361 | 37.514 | 45.501 |
| `render_residual_ms` | 26.494 | 34.953 | 36.185 | 44.993 |
| `sus_sim_avg_300` | 57.405 | 74.475 | 75.704 | 75.820 |
| `sus_sim_p95_300` | 103.960 | 103.961 | 103.961 | 103.961 |
| `sus_sim_max_300` | 118.219 | 118.219 | 118.219 | 118.219 |

这说明当前主要问题不只有单一国家研究热循环：同步模拟/续算有高尾延迟，且渲染 residual 平均约 26.49ms。即使模拟搬到 worker，仍必须做 patch、atlas、vegetation、UI layout 和 GPU budget 治理。

## 6. 尚未完成且不能遗漏的工作

### 6.1 最高阻断：真正 domain authority 迁移

当前仍缺：

- Country 的完整 POD command batch、日 plan/replay、territory/state/research generation 发布；
- Economy 的 POD day entry point、固定点计算计划、settlement/ledger/market commit barrier；
- Effect 的 POD intent/transaction apply 和 ACK；
- Modifier 的 POD snapshot、generation invalidation、ACK；
- Ideology 的 POD requirement/effect intent 和 ACK；
- Trigger 的 POD event ingress/normalization；
- Climate/weather/ocean/sea-ice/vegetation 年度与日权威迁移；
- Events 的固定顺序归一化与 commit；
- 跨 domain 共享状态的固定 replay 顺序。

`NativeCountryRuntime::run_day_pod()` 目前只是研究侧适配器：如果有 pending command，返回 `COMMAND_BATCH_PENDING`；如果挂接 Effect/Modifier/Economy，返回 `CROSS_DOMAIN_BARRIER_REQUIRED`。它不能成为 worker authority。

`advance_runtime_pulse()` 仍使用 Godot `Dictionary`、`Variant`、对象桥和 MapData/视觉边界，禁止直接放进 `std::thread`。

### 6.2 Host 尚未真正持有游戏状态

PKSR 当前只保存 runtime envelope，不保存完整 Country/Economy/Effect/Modifier/Ideology/Climate 状态。worker 重启/读档仍依赖现有 domain provider；完整 immutable `SaveBundle` 和 worker-side restore 尚未完成。

还缺：

- Host 对各 domain store 的明确成员所有权；
- domain state snapshot/restore codec；
- save 时完整日边界和跨域 ACK 安全点；
- save bundle 发布后自动恢复运行/保持原暂停状态；
- worker STARTING/RESTORING 成功后才 RUNNING；
- SaveBundle encode failure、磁盘失败、旧存档拒绝的完整故障 UI。

### 6.3 WorldClock / day_changed 尚未迁移

当前 `WorldClock._process()` 仍推进 `_day_carry` 和 `_advance_one_sim_day()`，并发出 `day_changed`；`WorldRuntimeHost._on_clock_day_changed()` 在非 ACTIVE 时调用 `run_daily_tick()`；`run_daily_tick()` 仍执行同步 SUS、渲染和部分 UI 同步。

还缺：

- worker 唯一推进整数日期；
- `simulation_committed(from_day,to_day,generation)` 消费路径；
- `day_changed` 只保留展示兼容、每帧最多一次；
- `season_changed/year_changed` 跨多个边界只发布最新值；
- `_apply_year_rollover()`、年度 RNG、climate anomaly、vegetation/biome history 迁入 worker；
- `PlayerController._on_day_changed()` 和 `main.gd._on_day_changed()` 删除任何权威 simulation call；
- `simulation_backpressure_pulse` 从生产路径移除，仅保留同步调试。

### 6.4 可视 patch/UI 治理尚未完成

后台 commit/patch API 已有，但主游戏尚未完全消费它。还缺：

- WorldRuntimeHost 每帧最多消费一个最新 commit；
- dirty family 独立 cursor、generation 作废和 25% sparse/full 阈值；
- MapData/GPU staging buffer 一次替换，禁止半更新；
- atlas 每 family 每帧最多一次上传；
- vegetation/MultiMesh dirty index 合并，每帧最多一次 buffer update；
- settlement label、国家面板、选中格、overlay 的字段级 patch；
- 普通帧 patch apply `<=0.75ms`、拖拽/缩放 `<=0.25ms`；
- 拖拽、缩放、resize 和 150ms grace period 的全局 interactive state；
- `ui_input_to_feedback_ms`、`visual_apply_ms`、`gpu_upload_ms`、`snapshot_staleness_ms` 的真实运行采样；
- GPU frame `>12ms` 时降低全屏 pass 频率，而不是挤占 UI 预算。

### 6.5 确定性和压力验收尚未完成

还没有完成：

- OFF 同步参考世界 vs SHADOW 独立后台世界 1000 日逐日 state hash 对拍；
- 事件 ID/顺序、命令回执、国家/领土/国库、经济总量、technology completion、climate anomaly、season/year boundary 对拍；
- `ledger_failures=0`、`fatal=false` 的长回放；
- 60×40 和 100×64 地图各运行 5 次的 avg/P95/P99/max 报告；
- 无限速原始能力 `>=65 天/秒`；
- 正式 50 倍速连续 10 分钟保持 49–51 天/秒；
- 连续拖拽 30 秒 P99 验收；
- worker 人为停顿 100ms 时 UI 无对应尖峰；
- 队列满、回执满、快照满、preflight 失败、worker 异常、保存编码失败、磁盘失败；
- 连续 100 次启停、暂停恢复、改速、跨季、跨年、保存、读档、返回菜单、重新开局。

### 6.6 文档和删除清单尚未完全同步

真正迁移每个 domain 后必须同步：

- `docs/cpp-dots-runtime/computation-pipelines.md`：输入、输出、权威 owner、publish/flush、fallback；
- `docs/cpp-dots-runtime/gdscript-cpp-data-bridge.md`：POD bridge、snapshot、flush、schema/CoW；
- `docs/cpp-dots-runtime/scheduling-and-job-graph.md`：job 注册、barrier、budget、skip、stage；
- `docs/cpp-dots-runtime/performance-diagnostics-playbook.md`：新增诊断字段和判断规则；
- `docs/cpp-dots-runtime/runtime-authority-matrix.md`：每个 domain 的唯一 authority、remaining blocker；
- `docs/cpp-dots-runtime/runtime-deletion-inventory.md`：旧 daily、backpressure、fallback 和 probe 的隔离/删除证据。

## 7. 下一步具体实施顺序

以下顺序不可颠倒；每一步都要保留前一步的 CSV、hash 对拍结果、构建产物和失败日志。

### Step 1：建立可归因基线和 guard

目标：所有后续收益可解释、可回退。

动作：

1. 固定 seed、地图尺寸、命令 trace、配置，生成 500 日回放；每组运行 5 次，保存 avg/P95/P99/max。
2. 确认 `research_*_ms`、research checks、modifier cache、post-pulse flush、flush slot、territory sync、event dispatch 已进入图形版 CSV，而不是只在 headless report。
3. 增加 CI/测试 guard：worker 文件不能包含 Godot include；`main_wait_on_sim_us != 0` 直接失败；ACTIVE 不完整直接失败。
4. 记录当前 `t_sus_ms≈122.973ms avg`、`render_residual≈26.494ms avg`，不要用单次墙钟替代基线。

退出：country daily 的约 75ms 有完整子阶段归属，未归属时间低于 1ms。

### Step 2：Country POD adapter 完整化

目标：先让 Country 能在不构造 Godot 类型的情况下完成一个完整日。

动作：

1. 在 `runtime_pod_protocol.h` 增加 `RuntimeCountryCommandBatch`、`RuntimeCountryDayPlan`、`RuntimeCountryDayCommit` 的固定数组/索引语义；payload 不携带字符串指针。
2. 在 facade 主线程把 `submit_country_commands()` 的 Dictionary 转成 POD command；验证 weights `0..10000` 且总和 `10000`，命令值和 handle generation 在入队前校验。
3. 在 Country store 增加 worker 可用的 command queue、active research slots、pending activation/discovery frontier、modifier cache generation。
4. 把 `run_day_pod()` 拆成 command preflight、research plan、固定 replay、effect intent、dirty generation；不要在接口内返回 Dictionary。
5. 将 `CROSS_DOMAIN_BARRIER_REQUIRED` 变成显式 ACK 输入：Country 等待 Effect/Modifier/Economy POD commit，不读取 Godot peer。
6. 增加 Country-only parity mode：同一命令 trace 比较旧 `run_slice(Dictionary)` 与新 POD commit 的逐日 hash/事件/receipt。

退出：Country 1000 日 hash 完全一致；研究日 `territory_sync_ms=0`；`country_daily` P95 `<=2ms`、max `<=4ms`。

### Step 3：Economy POD adapter

目标：把最大工作量的 Economy 从 Dictionary/context 迁到 POD plan/replay。

动作：

1. 定义 `RuntimeEconomyDayContext` 的完整输入快照：country generation、modifier generation、environment generation、market/building/family handles。
2. 把 `run_slice_internal(Dictionary)` 按 epoch preflight、workset、fixed-point plan、ledger plan、settlement plan、commit 拆分；热循环只读 SoA/POD。
3. 所有并行计算固定 chunk；按 chunk id/entity stable id 归并；共享余额、ledger、population、building reserve 仅在 replay 阶段改写。
4. 经济错误统一为 POD error/receipt，不能在 worker 生成 Godot report。
5. 将 Economy ACK 接入 Country/Effect/Modifier barrier；禁止同一天由 GDScript 再补跑 Economy。
6. 保留旧 Dictionary facade，仅在主线程把 `RuntimeEconomyDayCommit` 格式化为诊断字典。

退出：经济总量、ledger、国家资产和 selected-cell summary 与 OFF 逐日一致；固定点无 `ledger_failures`。

### Step 4：Effect、Modifier、Ideology、Trigger、Climate、Events

目标：填满 `implemented_domain_mask`，但每次只开启一个已验证 bit。

动作：

1. Effect：catalog ID 在 bootstrap 编译为整数，worker 只处理 effect intent/transaction，完成后发布 ACK。
2. Modifier：按 `(country_handle, modifier_generation)` 缓存，commit 后按受影响国家失效；发布 immutable snapshot。
3. Ideology：requirements、互斥、民意和 effect intent 全 POD 化；不直接访问 Godot。
4. Trigger：事件 ingress、条件聚合、稳定排序和 normalized event intent 全 POD 化。
5. Climate/weather/ocean/sea-ice/vegetation：把年度 RNG、异常值、历史环形缓冲和 daily fields 从 WorldClock/GDScript 迁入 worker。
6. Events：在 COMMIT 前按 `(day, producer, sequence, event id)` 固定归一化。
7. 每完成一个 domain，只在 SHADOW parity 通过后扩大 implemented mask；失败则保留旧 bit 和回退路径。

退出：`implemented_domain_mask == RUNTIME_ALL_DOMAIN_MASK`，所有 authority blockers 为空。

### Step 5：Host ownership、完整快照和读档

目标：worker 成为可恢复的完整状态 owner。

动作：

1. `NativeSimulationHost` 持有 domain store 或明确 owner handle；主线程不再直接访问这些 store。
2. 为每个 domain 提供 immutable `SaveBundle` section encoder/decoder；PKSR v2 runtime envelope 扩展为带 section mask 的完整 bundle，保留 checksum 和 v1 版本拒绝。
3. save request 只在完整日和跨域 ACK barrier 后生成 bundle；生成后立即恢复 worker 原运行/暂停状态。
4. restore 在 STARTING/RESTORING 完成：校验 magic/version/checksum/catalog hash/shape，成功后发布 generation 0/初始 snapshot，失败进入 FAULTED。
5. 主线程继续异步分块写 PKSV v2；临时文件、checksum、`.bak`、原子替换和失败保留旧存档。

退出：保存/读档/失败不会阻塞 UI；v1 明确拒绝；v2 roundtrip 逐日 hash 一致。

### Step 6：WorldClock、WorldRuntimeHost 和 PlayerController 迁移

目标：彻底删除主线程 simulation authority。

动作：

1. `WorldClock._process()` 只维护展示相位并发送 pause/speed 控制；不再 `_advance_one_sim_day()`。
2. worker commit 消费统一进入 `WorldRuntimeHost`；每帧最多应用一次最新 generation。
3. 新增 `simulation_committed(from_day,to_day,generation)`；`day_changed/season_changed/year_changed` 只做展示兼容信号。
4. `main.gd`、`PlayerController` 的 day callbacks 只刷新文本、当前快照、overlay 和 selected-cell UI，禁止调用 `run_daily_tick()`。
5. `simulation_backpressure_pulse` 从生产路径移除；同步 OFF 调试模式保留旧逻辑。
6. 启动时捕获环境输入；环境 generation 改变时增量发布，不允许 worker 反查 MapData。

退出：ACTIVE 下 `rg` 不再发现残留 GDScript 权威 daily/yearly call；同日不会重复运行 Economy/Country。

### Step 7：三缓冲视觉发布和交互预算

目标：模拟停顿只能增加 staleness，不能制造 UI 帧尖峰。

动作：

1. 为 CLOCK、COUNTRY_STATE、COUNTRY_TERRITORY、COUNTRY_VISUAL_ERA、CLIMATE_FIELDS、WEATHER、ECONOMY_UI、EVENTS、OVERLAY 建立独立 patch consumer。
2. sparse dirty 比例 `<25%` 用 patch，`>=25%` 用完整 staging array；旧 generation 未应用 patch 立即作废。
3. atlas/texture/MultiMesh/vegetation 每 family 每帧最多一次上传/更新；禁止同步 GPU readback。
4. 交互态包含 mouse down、Control drag、地图拖拽/缩放、resize、结束后 150ms；交互期间 executor 降并发，patch budget `0.25ms`。
5. 普通帧 patch budget `0.75ms`；UI layout 超 1ms 时改字段 patch；GPU frame 超 12ms 时降低全屏 pass 频率。
6. 采集 `ui_input_to_feedback_ms`、`visual_apply_ms`、`gpu_upload_ms`、`snapshot_staleness_ms`、`main_wait_on_sim_us`。

退出：拖拽 30 秒 P99 帧 `<=16.7ms`，输入反馈 `<=50ms`，patch P99 `<=1ms`，staleness max `<=100ms`。

### Step 8：确定性、压力、性能和发布门禁

目标：只在证据完整时开放 ACTIVE 默认。

动作：

1. OFF/SHADOW 同 seed、同命令 trace 1000 日逐日对拍 state hash、事件、receipt、country/economy totals、technology、climate、season/year、ledger/fatal。
2. 队列/快照/回执满载、preflight 失败、worker exception、save encode/disk failure 全部注入测试。
3. 60×40、100×64 各 5 次：无限速原始能力 `>=65 天/秒`；50 倍速 10 分钟保持 49–51 天/秒。
4. 人为停顿 worker 100ms：UI 帧无对应尖峰，只有 snapshot staleness 上升，`main_wait_on_sim_us=0`。
5. ACTIVE 默认前检查：`graph_coverage_state=complete`、`implemented_domain_mask=RUNTIME_ALL_DOMAIN_MASK`、remaining GDScript authority 为空、full flush 为 0。
6. 按阶段保留 CSV、hash 报告、DLL、日志和回退开关；不能热切换运行模式。

## 8. 模式、回退和故障处理

### OFF

同步参考世界，开发默认回退。保留现有 `WorldClock → day_changed → run_daily_tick()` 作为参考实现和 parity oracle。

### SHADOW

后台 worker 运行协议和已迁移 domain，但不驱动画面；与 OFF 独立 world 比较 hash、事件和回执。SHADOW 不能把未完成 domain 标为权威。

### ACTIVE

仅在完整 POD graph 和 authority matrix 通过后开放；worker 是唯一模拟权威。任何残留 GDScript daily/yearly authority 都阻断发布。

### 故障

- worker 捕获所有异常并进入 `FAULTED`；
- 时钟暂停，保留最后成功 commit/snapshot；
- 主线程显示明确 fault code；
- 禁止运行中自动切回同步权威；
- 用户可返回菜单或重新加载；
- 正常退出先异步 stop，收到 STOPPED 后释放 world；析构 join 仅兜底。

## 9. 接手者启动检查清单

1. 先读本文和 `docs/cpp-dots-runtime/index.md`、`architecture-overview.md`、`gdscript-cpp-data-bridge.md`、`scheduling-and-job-graph.md`、`computation-pipelines.md`、`performance-diagnostics-playbook.md`。
2. 检查 `git status`，保留既有用户修改，不执行 reset/checkout/清理。
3. 构建 Debug DLL，再运行 focused tests；必要时构建 Release DLL。
4. 检查 `get_runtime_thread_report()`：当前应为 `OFF` 或 `SHADOW`、`graph_coverage_state=partial`、`simulation_worker_ready=false`。
5. 不要直接把 `advance_runtime_pulse()`、`run_daily_tick()` 或任何带 Godot 类型的函数塞进 `std::thread`。
6. 完成一个 domain 后先做 parity 和报告，再扩大 `implemented_domain_mask`，最后才进入下一个 domain。
7. 每次改变 authority、bridge、scheduler、诊断或存档，都同步更新本目录对应文档。

## 10. 相关源码和测试入口

核心线程边界：

- `gdext/src/native_simulation_host.h`
- `gdext/src/native_simulation_host.cpp`
- `gdext/src/runtime_pod_protocol.h`
- `gdext/src/runtime_snapshot_ring.h`
- `gdext/src/runtime_snapshot_ring.cpp`
- `gdext/src/native_parallel_executor.h`
- `gdext/src/native_parallel_executor.cpp`
- `gdext/src/world_ext_simulation_host.cpp`

同步运行和展示边界：

- `Project/project-keynes/scripts/game/world_runtime_host.gd`
- `Project/project-keynes/scripts/geography/world_clock.gd`
- `Project/project-keynes/scripts/game/player_controller.gd`
- `Project/project-keynes/scripts/main.gd`
- `Project/project-keynes/scripts/geography/map_generator.gd`

domain runtime：

- `gdext/src/country_runtime.h/.cpp`
- `gdext/src/economy_runtime.h/.cpp` 及拆分的 economy translation units
- `gdext/src/effect_runtime.h/.cpp`
- `gdext/src/modifier_runtime.h/.cpp`
- `gdext/src/ideology_runtime.h/.cpp`
- `gdext/src/trigger_runtime.h/.cpp`

存档和测试：

- `Project/project-keynes/scripts/game/save_repository.gd`
- `Project/project-keynes/scripts/game/game_save_coordinator.gd`
- `Project/project-keynes/tests/runtime_thread_isolation_test.gd`
- `Project/project-keynes/tests/runtime_snapshot_ring_test.gd`
- `Project/project-keynes/tests/native_runtime_graph_api_test.gd`
- `Project/project-keynes/tests/save_repository_test.gd`
- `Project/project-keynes/tests/technology_research_runtime_test.gd`
- `Project/project-keynes/tests/perf_recorder_test.gd`

性能基线：

- `tmp/perf_record_20260903_235556.csv`
