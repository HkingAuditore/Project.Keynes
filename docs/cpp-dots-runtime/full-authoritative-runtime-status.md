# Project.Keynes 全域权威运行时重构状态报告

更新时间：2026-09-07

## 1. 文档目的

本文总结 Project.Keynes 从当前 GDScript/同步 daily 权威迁移到纯 C++ POD worker 权威的整体进展。

本文严格区分三种状态：

1. **基础设施已完成**：协议、队列、快照、错误状态等已经具备并经过测试。
2. **SHADOW 诊断已存在**：代码可以在独立 worker-owned POD store 中运行，用于测量和对拍，但尚未成为真实权威。
3. **生产权威迁移已完成**：只有完成逐日确定性对拍、保存恢复、线程隔离和性能门禁后，才能归入此类。

当前不能把第二类描述为第三类。

## 2. 最终目标

最终运行时必须形成以下边界：

```text
主线程输入捕获
    ↓
immutable native input snapshot
    ↓
worker-owned POD state
    ↓
固定顺序 plan/replay
    ↓
typed intent / ACK barrier
    ↓
immutable committed snapshot
    ↓
主线程视觉和 UI 消费
```

最终要求：

- worker 不调用任何 Godot API；
- worker 不访问 MapData、场景树、renderer、GPU 或 Godot 对象；
- 主线程不读取 worker store；
- 主线程不等待 simulation、mutex、任务或保存编码；
- OFF 是同步参考权威；
- SHADOW 是后台对拍权威，不驱动画面；
- ACTIVE 只能在所有 domain、保存恢复、对拍、审计和性能门禁全部通过后开放；
- 权威模拟不跳过日期；
- 50 倍速目标为 50 个权威模拟日/秒；
- worker 停顿不造成 UI 帧尖峰。

## 3. 当前硬状态

当前必须继续保持：

```text
simulation_thread_mode  = OFF / SHADOW / ACTIVE
graph_coverage_state    = partial
implemented_domain_mask = CLIMATE | COMMIT (0x802)
整图 ACTIVE             = 仍禁止（逐域放行，不是全域开关）
```

> **更新（2026-09-08）：Climate 已经是生产权威，这一节原先的 `0x800` / `ACTIVE=禁止`
> 已过期。**`runtime_climate_authority_enabled` 生产默认 true，generate 时以
> per-domain ACTIVE（`CLIMATE|COMMIT = 0x802`）启动 worker，主线程的 14 个 Climate
> 节点被抑制门挡住，MapData 由 `apply_runtime_climate_writeback` 回灌、滞后一日。
> 其余七个 gameplay domain 仍按上面的旧约束办。落地过程与证据见 §39–§42。

> **校正（2026-09-06）**：原文此处还列了一行 `domain_pod_mode = SHADOW`。**代码里
> 不存在这个开关**（全库检索 `domain_pod_mode` 零命中）。POD 路径没有独立模式位，
> 它就跟着 `simulation_thread_mode` 走：`NativeSimulationHost::execute_day_plan` 里
> 判的是 `_mode == RuntimeSimulationMode::SHADOW`。照原文去找这个开关只会白费时间。

Climate 之外的域，真实权威仍然是：

```text
WorldClock._process()
→ day_changed
→ WorldRuntimeHost.run_daily_tick()
→ 同步 SUS/native daily graph
```

`RuntimeDomainAuthorityRunner` 与 Country POD 都不能改变这一事实。**Climate POD 是唯一
的例外**：它的那一段现在是

```text
WorldClock._process() → day_changed
→ apply_runtime_climate_writeback(day N 的 worker 结果)
→ season refresh
→ capture_runtime_inputs(day N+1 的输入)
→ 主线程 Climate 节点被抑制门跳过
```

这个顺序是钉死的，换序会让 season refresh 对回灌表内字段的写入全部作废（§33）。

## 4. 已完成的基础设施

### 4.1 Runtime Domain ABI v3

> **校正（2026-09-06）**：本节说的 "ABI v3" 是 **POD ABI**，不是 domain ABI。代码里
> 这是两个独立常量，值也不同（[runtime_pod_protocol.h](../../gdext/src/runtime_pod_protocol.h) 第 43、47 行）：
>
> ```text
> RUNTIME_DOMAIN_ABI_VERSION     = 1   ← RuntimeThreadReport::domain_abi_version
> RUNTIME_DOMAIN_POD_ABI_VERSION = 3   ← snapshot / catalog / store 的 abi_version
> ```
>
> 文档其余各节混用 "ABI v3" 与 "ABI v1" 指同一件事，实际上取决于说的是哪一个常量。
> 校验失败时要看报的是哪个字段：`domain_abi_version` 不匹配和 POD `abi_version`
> 不匹配是两回事。

已经完成并保留：

- Runtime Domain **POD** ABI 升级到 v3（domain ABI 仍是 v1）；
- stage 数量固定为 12；
- `CLIMATE` 与 `TRIGGER_INPUT` 已拆为不同 bit；
- `RUNTIME_ALL_DOMAIN_MASK == 0xFFF`；
- stage 顺序固定为：

```text
INPUT_CAPTURE
→ CLIMATE
→ COUNTRY
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

- `COMMIT` 是目前唯一允许进入 `implemented_domain_mask` 的 bit；
- ACTIVE gate 会拒绝不完整的 mask；
- ABI 不匹配必须在 worker 启动前拒绝。

### 4.2 公共运行时协议

已经建立统一的运行时数据边界，包含：

```text
RuntimeDayInput
RuntimeDomainPlan
RuntimeDomainCommit
RuntimeDomainIntent
RuntimeDomainAck
RuntimeDomainReport
RuntimeDomainSnapshot
RuntimeDomainSaveSection
```

公共 header 已包含：

```text
domain
abi_version
day
input_generation
base_generation
dirty_families
state_hash
work_units
intent_count
ack_count
preflight_ok
fallback_reason
```

### 4.3 命令与回执队列

已固定：

```text
command queue = 4096
receipt queue = 8192
```

命令排序键固定为：

```text
effective_day
→ producer_id
→ sequence
→ request_id
```

队列满不阻塞、不静默丢弃，必须返回：

```text
command_queue_capacity_exceeded
receipt_queue_capacity_exceeded
```

### 4.4 Snapshot ring

三缓冲 snapshot ring 已存在，状态为：

```text
FREE
→ WRITING
→ READY
→ READING
→ FREE
```

已经覆盖：

- READY 不覆盖 READING；
- 没有 FREE buffer 时只丢视觉发布，不丢模拟状态；
- generation 过期 patch 可以被丢弃；
- snapshot publish drop 可记录；
- 主线程不得等待 worker。

### 4.5 Worker 生命周期与时间债务

已有：

- worker state/faulted 状态；
- STOP、PAUSE、SPEED、SAVE 控制消息；
- condition variable 唤醒路径；
- 时间债务上限 100 天；
- worker fault 保留最后成功 snapshot；
- fallback reason 不允许静默丢失。

## 5. 输入边界和 Climate trace

### 5.1 Native input snapshot

已扩展 `RuntimeEnvironmentSnapshot`/native environment snapshot，覆盖：

- cell 温度、湿度、植物可用水；
- 降水、积雪、天气强度；
- 邻接 CSR；
- terrain、landform、vegetation、cover、water；
- 河流、运河与水量；
- trade passability 和 move cost；
- visibility；
- building resource reserve/extra；
- topology generation；
- vision revision；
- input generation 和 day。

### 5.2 输入验证

已有验证覆盖：

- 数组长度必须与 `cell_count` 一致；
- 浮点字段必须 finite；
- CSR offsets 单调递增；
- CSR 末值必须等于 indices 长度；
- 邻接索引必须在合法范围内；
- hydro parent 必须合法；
- trade cost 不得为非法负值；
- generation 必须递增；
- 输入 day 不得早于最后 committed day；
- topology generation 变化时必须重新捕获拓扑数据。

### 5.3 Climate trace barrier

已实现固定状态：

```text
CAPTURED
→ REFERENCE_READY
→ CONSUMABLE
→ CONSUMED
```

关键行为已经固定：

- worker 不能只拿实时 MapData 推进；
- 没有 OFF reference 时不能推进 SHADOW Climate day；
- trace 缺失时返回明确 fallback reason；
- trace ring 满时返回 `climate_trace_capacity_exceeded`；
- trace frame 携带输入 hash、reference state hash、day 和环境快照；
- trace 的容量和顺序有 self-test。

## 6. Climate 当前实现状态

> **本节是历史记录，读之前先看这段（2026-09-08）。**
>
> §6 写于 Climate 还在 SHADOW 的时期，6.2 整节的题目就是"当前仍不是生产权威的原因"。
> **那 6 条原因加 5 条补记阻断点现在全部已解决，Climate 已是生产默认权威。**保留原文是
> 因为其中几条的分析（比较器不可能通过、静默 no-op 与算法分叉不可区分、节拍错位被报成
> 分叉）在后面的域上会重演，但**不要把它当现状读**。
>
> 当前状态、五个 stage 的接线口径、已知限制与经验积累在 §39–§42：
>
> | 想知道 | 看 |
> | --- | --- |
> | 转 ACTIVE 的落地与回退路径 | §39 |
> | 经验积累（方法论一~二十） | §40、§42 结尾 |
> | 客户端暴露的两个缺陷（scalars / pass_a 回灌） | §41 |
> | 代码丢失事故与重建、海冰累积、跨边界键名、weather field | §42 |

### 6.1 已完成内容

已经存在：

- `RuntimeClimateStore` 初版；
- `RuntimeClimateKernel`；
- `RuntimeClimateAuthority`；
- Climate plan/replay/commit 边界；
- Climate snapshot；
- Climate save/restore 初版；
- Climate state hash；
- Climate reference hash 比较；
- Climate plan/replay timing；
- Climate parity compared/matched/mismatch count；
- Climate parity day/stage/cell/generation/trace hash 字段；
- Climate 共享公式文件：

```text
runtime_climate_formulas.h
runtime_climate_formulas.cpp
```

- 生产 graph 和 shadow kernel 已开始共用 Climate helper；
- Climate self-test 和 trace self-test 已存在。

> **补记（2026-09-06，S1–S3 完成后）**：上面这份清单描述的是 S1 之前的状态。此后
> 落地的内容改变了几条的性质，证据在 `artifacts/runtime/s1-*`、`s2-divergence/`、
> `s3-shared-passes/`：
>
> - **"Climate reference hash 比较" 已被替换。**原先 reference 是 GDScript 的
>   SHA-256 取前 7 字节、覆盖约 40 个 `MapData` 数组，worker 侧是 FNV-1a 的
>   `state_hash()` 且混入 `generation`/`rng_state`/`history_cursor` 等 worker 内部
>   簿记。两侧哈希函数、字段集、framing 全不同，`matched` 只能靠 2⁻⁵⁶ 碰撞成立。
>   现在两侧共用 `RuntimeClimateStore::parity_hash()`（只覆盖两侧都有物理语义的场），
>   `state_hash()` 保留给 save/restore 与 snapshot 完整性，语义不再混用。
> - **"parity day/stage/cell/generation/trace hash 字段" 先前只是槽位。**全库检索
>   确认 `RuntimeClimateParityReport` 没有任何代码填充。现在 mismatch 分支会填首差异
>   的 field/cell/stage/reference_bits/worker_bits，并按 canonical 字段表逐字段累积
>   分叉矩阵。注意 `get_runtime_thread_report` 一度漏了这些键（只有
>   `get_runtime_perf_snapshot` 有），harness 读前者时逐日 day 列全是 -1。
> - **"已开始共用 Climate helper" 的范围已扩大到 stage 级。**共享层不再只是
>   `runtime_climate_formulas.h` 里的标量 helper。9 个 pass 纯内核在
>   `runtime_climate_passes.{h,cpp}`，round 编排（passes_mask 门控 + 逐 pass 的
>   in←out 接力）在 `run_climate_round_passes`，生产 worker 与 SHADOW worker 调同一份。
>   `DCWorldExt::run_climate_pass_a` 已不再自带第二套 pass-A 算法，改为委派。
> - **PASS_A 已可判定为等价实现**：30 日 / 2400 cell 下 `temperature_baseline` 与
>   `temperature_30d_ema` 逐位相等，`thermal_energy`/`temperature_365d_ema` 只在
>   day 2（day-0 那轮的延迟落盘）分叉。S2 首测时这四条是 1~4 日分叉、max delta 0.97。
> - **stage 8 ALBEDO 也已共享**：生产侧原本有三份逐字重复的 albedo 主循环
>   （`run_albedo_pass` / `run_albedo_pass_thread` / `run_stage_b_pass` ① 段），现在统一
>   走 `pk_async_climate::albedo_apply_pure`。它是一个仿真日内 `temp_arr` 的最后一个
>   写者 —— 这也解释了为什么分叉矩阵把 `temperature` 标成 CLIMATE_FEEDBACK 分叉：
>   parity 的 stage 标签记的是"日内最后写者"，而 feedback pass 自己并不写 temp。
> - **"跳过"现在是可观测的**：`ClimateRoundPassTiming` 增加了 `passes_ran` /
>   `passes_starved` 两个 bit mask（9 个 pass 全部插桩），并经
>   `RuntimeClimateKernelReport` 上报。此前一个 pass 因输入 lane 长度不足被跳过时
>   `out` 字段留空，而 kernel 的 scatter 只做长度检查 —— 整段静默 no-op，在分叉矩阵里
>   与算法分叉完全无法区分。这条约束对块 B 的每个 domain 同样成立。
>
> 详细实测数据与残余阻塞点见 `artifacts/runtime/s3-shared-passes/S3-findings.md`。

### 6.2 曾经不是生产权威的原因（已全部解决，2026-09-08）

以下是 SHADOW 时期记录的阻断清单。**六条原因与五条补记阻断点现已全部解决**，Climate 于
2026-09-08 加入 `implemented_domain_mask`（`CLIMATE|COMMIT = 0x802`）。原文保留，因为几条
失效模式会在后续域上重演。

Climate 当时不能加入 `implemented_domain_mask`，原因是：

1. 尚未完成真实生产同步图与 worker 的 1000 日逐字段 bit-identical 对拍；
2. 当前 parity 主要是 state hash 比较，完整 field/cell 首差异 payload 仍需补齐；
3. 尚未完成 60×40 和 100×64 两种地图的完整固定 trace 验收；
4. 尚未完成所有异常天气、河流、运河、海冰、跨年和 topology revision 场景的稳定报告；
5. 尚未完成 Climate save/restore 后继续 1000 日的全量对拍；
6. 当前 worker 结果仍只用于 SHADOW 诊断，不驱动画面。

> **补记（2026-09-06）：原文漏记的四个阻断点。**前三个是全域地基问题，不是 Climate
> 局部问题——其余七个 gameplay domain 的处境相同或更差。
>
> 1. **比较器在数学上不可能通过**（已修，见 §6.1 补记）。后果比"对拍失败"更严重：
>    mismatch 会走 `discard_plan()`，所以 **SHADOW Climate 在此之前没有成功提交过
>    任何一天**，`climate_pod_parity_mismatch_count` 只会单调递增。且无测试覆盖——
>    `runtime_thread_isolation_test.gd` 只断言 SHADOW 能启动且非权威，从不检查
>    `parity_matched`。这是未被发现的缺陷，不是已知设计。
> 2. **worker kernel 14 个 stage 只落实了 1 个**（PASS_A）。`runtime_climate_kernel.cpp`
>    是 29 KB，生产 `world_ext_climate.cpp` 是 558 KB。其余 13 个 stage 当时是数值近似，
>    不具备 parity 语义。现状：stage 0–7（PASS_A..TRANSPIRATION）已接共享内核；
>    stage 8–13（ALBEDO / VEGETATION_DYNAMICS / CLIMATE_FEEDBACK / WEATHER /
>    RUNTIME_HYDROLOGY / STAGE_B_AFTER_HYDROLOGY）仍无 worker 实现，共享 round 模式下
>    这些 lane 刻意停在昨天的值而不填近似——填了会把"未实现"伪装成算法分叉。
> 3. **生产路径从不启动 worker。**`start_runtime_worker()` 是切换 OFF/SHADOW/ACTIVE
>    的唯一入口，但除测试外没有任何 GDScript 生产代码调用它。所以 §21 描述的
>    "SHADOW 路径并行存在"只在手动启动 worker 的测试里成立；capture/reference 时序虽
>    会执行，但**没有消费者**。任何 harness 必须自己显式 `start_runtime_worker(SHADOW)`，
>    否则拿到的是"worker 没跑"而不是"对拍通过"，两者在报告里都是全 0。
> 4. **生产 Climate round 按 stride 跑，不是每日一轮**（本地图约每 10 日一轮，实测
>    day 0/7/18/28）。worker 原先每天都跑，于是在生产没动的日子里单方面推进温度场，
>    分叉矩阵会把这种节拍错位报成算法分叉。现由
>    `RuntimeEnvironmentSnapshot::climate_round_ran` 在 reference publish 时按生产真实
>    情况回填。**该标志默认必须是 true**：默认 false 会让任何没显式设过它的 fixture
>    静默变成整域 no-op（`runtime_domain_pod_test` 与 `runtime_climate_authority_test`
>    的 self-test 就因此失败过）。albedo 有自己的 stride（`weather_albedo_stride`，实测
>    30 日只跑了 day 7 一次），与 round 节拍无关，所以它的"跑没跑"必须独立回填
>    （`climate_albedo`），只看 `climate_round_ran` 会漏掉只跑 albedo 的日子。
>
> **补记（2026-09-06，S3 实测后新增第 5 条阻断点）：worker 的 round 输入不是生产权威
> 的。**`_production_round_input` 是在 `run_climate_pass_a` 里留存的 pass_a 输入缓冲，
> 只含 pass_a 自己的 lane。它原先**整体覆盖**了 capture 侧那份完整缓冲，于是
> pass_b→sea_ice 全部撞尺寸守卫被跳过、输出留空、scatter 静默 no-op，表现成"worker 跑了
> round 但温度场停在昨天"。现改为分层（`overlay_production_pass_a`）：capture 那份提供
> 全 9 pass 的 lane，生产那份只覆盖 pass_a 的 lane 与标量子集。标量必须逐字段覆盖 ——
> 生产那份只填了 pass_a 段，整体覆盖会把后续 pass 的 knobs 全清成结构默认值。
>
> 同一条链上还有第二个坑（也已修）：probe 走 native_daily 路径时 `ClimateDailySystem`
> 根本没注册，capture 的 round input 字典为空。per-cell lane 因 `prefer_slot_lanes=true`
> 从 `_slots` 兜底填满，所以表面看不出问题；而标量与非 per-cell 的 LUT 没有兜底来源，于是
> `pb_*`/`ow_*`/`ol_*`/`wa_*`/`ws_*`/`si_*` 全是结构默认值，`water_terrain_ids` 直接为空
> （sea_ice 因此饿死）。现由 `DCWorldExt::record_production_round_scalars` 在每个 sync pass
> 拉完标量之后如实记录、随 reference 发布，`water_terrain_ids` 改走
> `ClimateRoundStaticKnobs`。**顺带测出生产在 60×40 上根本不跑 ocean_water / ocean_land**
> （`prod_knobs=0x72`），overlay 会据此把它们从 worker 的 `passes_mask` 里摘掉，否则
> worker 会用默认 knobs 单方面跑两个生产没跑的 pass。
>
> 现状 `ran=0x1F3 starved=0x0`：**输入边界侧已无已知缺口**，分叉矩阵上剩下的每一条都能
> 一对一映射到"哪个 stage 还没提取"，这正是 S2 矩阵原本要提供而当时提供不了的东西。
>
> 30 日窗口的实际信息量也比日历天数低得多：生产只在 day 0/7/18/28 算过东西，其余 26 天
> 两边都没动。1000 日窗口只会包含约 130 个有效比较日。
>
> 另需注意 SHADOW 下存在**两条并行的 climate 路径**：`_climate_authority`（真 kernel +
> reference parity）和 `_domain_authority_runner` 的 CLIMATE stage（只把 environment
> 字段投影到 store，不跑生产公式）。对拍只应看前者。
>
> 还有一个 worker 加入时序问题：worker store 是全零，而它拿到的第一帧 reference 已带着
> 整个世界生成期的结果。比这一天量到的只是"worker 没见过世界生成"，且会把每个字段都
> 标成分叉。现在第一帧走 `adopt_reference_baseline`（收作起点，不计入对拍）。

### 6.3 Climate 需要补齐的工作

原清单与 2026-09-08 的实际状态：

| 项 | 状态 |
| --- | --- |
| OFF reference runner | 已有：`climate_parity_probe.gd` |
| 固定 seed/map/catalog/config 的 trace 生成器 | 已有：probe 的 `parity30` fixture |
| reference payload 或版本化 delta | 已有：`publish_runtime_climate_reference_state` 发布整份 store |
| stage hash | **未做**，改为按 canonical 字段表逐字段累积分叉矩阵，信息量更高 |
| field/cell 级首次差异 | 已有：mismatch 分支填 field/cell/stage/两侧 bit |
| reference/worker bit pattern | 已有：`first_reference_bits` / `first_worker_bits` |
| 60×40、100×64 1000 日对拍 | **未做**。实际验收走 60×40 / 30 日 **28/30**（两日为 spin-up 与 season refresh 湿度链残差）+ 50×48 的 60~400 日 ACTIVE soak |
| Climate CLM2 section 完整 roundtrip | 已有：`runtime_climate_save_roundtrip_test` 37/0 |
| restore 后继续 1000 日对拍 | **未做** |
| 无 fallback、无 fatal、无 ledger failure 的 gate 报告 | 已有：soak `drops=0`，回归七项全绿 |

放行判据最终没有采用"1000 日 bit-identical"这条线 —— 生产在 60×40 上 30 日只有约 4 个有效
比较日（round 按 stride 跑），1000 日窗口也只含约 130 个。实际采用的是**逐 stage 提取 +
分叉矩阵逐条归因 + ACTIVE soak 对着主线程基准读字段统计**，理由与残差解释见 §31、§39。

## 7. Country 当前实现状态

### 7.1 已完成内容

截至 2026-09-08，K0、K1 和 K2-E 的基础已经落地：

- `gdext/src/country_core.*` 定义唯一 Country 业务步进、typed command、receipt、boundary seal
  和 CPD2 ABI；同步 `NativeCountryRuntime::run_slice()` 与 POD adapter 共用
  `run_slice_core()`，不再保留第二套研究/命令算法；
- 生产边界 reference trace 已能记录分状态族 hash、命令水位、事件水位和 canonical
  PKCN v13 checkpoint；
- 20 个生产 opcode 共用 admission 校验、`effective_day/sequence/submit_order` 排序、原子
  批次和 `Accepted/Committed/RejectedAtExecution` receipt；
- boundary seal 固定 `session_epoch/boundary_id/day/last_admitted_submit_order/base_generation`
  后，晚到命令不会进入已封口批次；
- CPD2 ABI v2 已正式编入 PKSR v2 Country section `0x8`，并与 standalone `pkcn` provider
  复用同一次 canonical PKCN 捕获；
- PKCN/CPD2 restore 已改为隔离 Country+Modifier staging、完整校验后原子 install；错误
  PKCN、checksum、catalog、generation/day/hash 或协议元数据不会污染在线状态；
- `runtime_country_save_roundtrip_test.gd` 已覆盖真实 Host bundle、错误输入拒绝、二次保存、
  future command 和事件游标恢复。

### 7.2 尚未完成内容

Country 尚未成为 Host 的真实 COUNTRY authority：

- 尚未完整接入 `NativeSimulationHost` daily stage；
- 尚未替代同步 Country daily；
- typed command、seal、receipt 尚未接入 Host transport/inbox/outbox；
- 尚未完成 Country 1000 日 OFF/SHADOW parity；
- 尚未完成 Country 与 Economy/Modifier/Effect 的真实 ACK barrier；
- 尚未完成全部 Country 资产写入的跨域事务桥；
- 尚未完成不可变 CountryReadView 与稀疏发布；
- 尚未证明研究变化不会触发 territory sync；
- 尚未允许增加 COUNTRY bit。

> **校正（2026-09-08）：2026-09-06 的“POD 约 80%，只差 Host 接线”判断已被替代。**
>
> 原 POD 只覆盖部分状态和算法，不能直接晋升。现在已先把生产算法抽成共享核心并补齐
> reference、seal、receipt 与正式 CPD2；但 Host 仍只是 SHADOW probe，跨域 ACK/资产事务、
> 唯一写者门控和长期 parity 仍是 COUNTRY bit 之前的硬阻塞项。

## 8. 全域诊断 runner 当前状态

`RuntimeDomainAuthorityRunner` 已新增并接入 SHADOW 诊断流程，覆盖：

```text
INPUT_CAPTURE
CLIMATE
COUNTRY
TRIGGER_INPUT
IDEOLOGY
EFFECT
MODIFIER
GAMEPLAY_EFFECT
ECONOMY
EVENTS
VISUAL
COMMIT
```

它目前可以：

- 运行预分配 scratch plan；
- 生成 typed intent；
- 生成 ACK；
- 执行稳定排序；
- 处理 Trigger distinct/dedupe；
- 处理 Ideology deterministic RNG/transition；
- 处理 Effect due/Modifier intent；
- 处理 Modifier expiry；
- 进行 Economy 基础守恒诊断；
- 进行 Events stable journal ordering；
- 输出 stage report、hash、work units、timing 和 fallback。

但它明确不是 authority：

```cpp
capability_mask() == 0
```

它不能替代各 domain 的真实算法，也不能用于开启 ACTIVE。

## 9. 已完成的测试和构建验证

已经验证通过的基础测试包括：

- ABI/protocol guard；
- runtime domain POD test；
- Climate authority self-test；
- Climate trace self-test；
- Country POD test；
- snapshot ring test；
- save domain section test；
- worker source scan；
- thread isolation test；
- RuntimeDomainAuthorityRunner standalone self-test；
- 关键 C++ 文件 MSVC C++17 单文件编译。

Debug/Release DLL 曾成功构建过，构建产物位于：

```text
Project/project-keynes/addons/dots_ext/bin/windows/
```

需要注意：最近新增 parity report 字段后，必须重新执行完整 GDExtension Debug/Release 构建和 headless suite，不能只依赖旧 DLL。

## 10. 尚未完成的 domain 清单

### Modifier

尚需实现真实：

- catalog；
- target generation；
- expiry heap；
- stack policy；
- bucket revision；
- cache invalidation；
- snapshot/save/restore；
- ACK 输出；
- 1000 日 parity。

### Effect

尚需实现真实：

- effect catalog；
- effect instance lifecycle；
- idempotency；
- duration/expiry；
- typed intent；
- required/received ACK mask；
- retry/reject/retire；
- stale target；
- save/restore；
- 1000 日 parity。

### Ideology

尚需实现真实：

- support/exclusion/synergy；
- dominant ideology；
- pending transition；
- offer generation；
- deterministic RNG；
- Effect ACK cursor；
- save/restore；
- 1000 日 parity。

### Trigger

尚需实现真实：

- window；
- distinct；
- consecutive；
- cooldown；
- dedupe；
- resync/gap；
- stable fire order；
- save/restore；
- 1000 日 parity。

### Events

尚需实现真实：

- committed journal；
- stable event IDs；
- gameplay/visual/debug separation；
- event dedupe；
- journal ordering；
- Trigger input boundary；
- save/restore；
- 1000 日 parity。

### Economy

Economy 是最大剩余迁移面，尚未完成：

- PopulationCohort；
- Family/Person；
- Settlement；
- Building/Employment；
- Production；
- Market/Inventory；
- Domestic Trade/Cargo；
- Construction/Investment；
- Fiscal Settlement；
- Treasury/Cash；
- Price State；
- Rolling Cadence；
- Economy RNG；
- population/money/goods conservation audit；
- 并行 chunk/replay 边界；
- 1000 日 parity；
- 双地图尺寸性能门禁。

## 11. Host 和主线程仍未完成的部分

### NativeSimulationHost

当前 Host 已能运行诊断链，但尚未做到所有 domain 的真实 ownership：

- Country/Modifier/Effect/Ideology/Trigger/Economy/Events 仍未完整接管；
- ACK barrier 目前不是全域生产 barrier；
- global committed state hash 还不是完整 authority hash；
- save bundle 还未包含所有 domain section；
- worker snapshot 仍不能作为正式画面权威。

### WorldClock

WorldClock 仍保留同步日期推进和 daily authority。

以下逻辑还没有清退：

```text
主线程 daily 推进
run_daily_tick()
同步 SUS daily
权威 year rollover
Climate anomaly 的同步写入
```

在所有 domain parity 和 save/restore 完成之前，不应清退这些逻辑。

### WorldRuntimeHost

`_process()` 尚未完全变为纯 snapshot consumer。

最终需要做到：

- 只 poll 最新 commit；
- 只应用 dirty family patch；
- 不驱动 daily simulation；
- 不访问 worker store；
- 不等待 worker；
- 不让兼容信号触发权威逻辑。

## 12. 存档当前状态

已经有部分 domain save section 和 Climate/Country 独立 save/restore 骨架。

但完整 PKSR v2 尚未完成。最终必须包含：

```text
simulation_runtime
climate
country
modifier
effect
ideology
trigger
economy
events
```

每个 section 必须包含：

```text
section ABI
committed day
generation
catalog hash
state hash
payload size
payload checksum
payload
```

必须完成：

- PKSV v1 明确拒绝；
- PKSR v2 roundtrip；
- 单 section 损坏整体拒绝；
- checksum 错误整体拒绝；
- catalog/map shape 不匹配整体拒绝；
- restore 后继续 1000 日 parity；
- 保存不暂停玩家原有运行状态；
- 主线程只写临时文件和最终文件，不读取 worker store。

> **校正（2026-09-08）：上面九个 section 目前到位三个。**
>
> PKSR v2 当前实际写/读三个 tail（见 `native_simulation_host.cpp` 的 serialize/restore）：
>
> ```text
> CLM2  climate      已编入
> DPD2  domain pod   已编入
> CPD2  country      已编入；内嵌 canonical PKCN v13，并与 PKSV pkcn provider 复用
> ```
>
> CPD2 采用 ABI v2，包含 Country 协议恢复元数据；Country restore 已使用 prepare/install
> 事务边界。其余六个 section 尚不存在。
>
> Economy 的收编风险显著高于其他 domain，不应按同一节奏排期：PKSV 的 `pkec` provider
> 已迭代到 **v47**（`game_save_coordinator.gd`），相比 `pkid` v2、`pkfg` v2。把它编进
> PKSR 意味着要么冻结这个仍在活跃演进的格式，要么双写。

## 13. 三缓冲视觉和 UI 隔离

snapshot ring 基础设施已存在，但完整 family consumer 尚未完成。

尚需独立实现：

```text
CLOCK
COUNTRY_STATE
COUNTRY_TERRITORY
COUNTRY_VISUAL_ERA
CLIMATE_FIELDS
WEATHER
ECONOMY_UI
EVENTS
OVERLAY
```

必须实现：

- dirty ratio 小于 25% 使用 sparse patch；
- 达到 25% 使用完整 staging array；
- staging 完成后一次性替换；
- 每个 family 每帧最多上传一次；
- 旧 generation patch 丢弃；
- 无 FREE buffer 时只丢视觉发布；
- UI 不读取 worker store；
- 交互期间 patch budget 不超过 0.25ms；
- 普通帧 patch budget 不超过 0.75ms；
- snapshot staleness 不超过 100ms；
- `main_wait_on_sim_us == 0`。

## 14. 性能和线程隔离差距

当前已有基础 timing/report 字段，但尚未完成最终验收。

最终报告必须同时展示：

```text
simulation compute
plan
replay
ACK barrier
snapshot publish
visual apply
GPU upload
time debt
command queue depth
receipt queue depth
snapshot publish drop
fallback count
snapshot staleness
main_wait_on_sim_us
```

目标：

```text
无限速诊断能力 >= 65 天/秒
50 倍速持续 10 分钟 = 49–51 天/秒
country_daily P95 <= 2ms
country_daily max <= 4ms
steady full_flush_count = 0
research territory sync = 0
UI frame P99 <= 16.7ms
input feedback P99 <= 50ms
snapshot staleness <= 100ms
visual patch P99 <= 1ms
main_wait_on_sim_us = 0
ledger_failures = 0
fatal = false
```

必须测试：

- worker 人为停顿 100ms；
- 连续拖拽 30 秒；
- resize/zoom；
- queue full；
- receipt full；
- snapshot buffer full；
- trace ring full；
- worker exception；
- pause/resume；
- speed change；
- 连续 100 次启停；
- 返回菜单；
- 重新开局。

## 15. 距离最终目标的主要差距

按影响排序：

### 第一优先级：证明 Climate 能力 —— 已完成（2026-09-08）

- 固定输入 trace；
- OFF reference runner；
- ~~1000 日逐日 hash~~ → 改为 30 日 28/30 + 分叉矩阵逐条归因 + ACTIVE soak 字段对照，
  理由见 §6.3（1000 日窗口只含约 130 个有效比较日，不值那个墙钟）；
- field/cell 首差异；
- ~~save/restore 后继续对拍~~ → 仍未做，但 CLM2 roundtrip 已绿（37/0）。

Climate 已于 2026-09-08 转为生产默认权威。**下一个 Climate 相关的优先事项不是"证明能力"
而是两条真实缺口**：真实客户端会话下的帧延迟收益从未量到（headless 的 `frame_wall_ms`
恒 0），以及大地图上 worker 跟不上节拍（180x120 下 `writeback_days=30/50`）。

### 第二优先级：Country 真实接入

- Host COUNTRY stage；
- command/ACK/save；
- Country 1000 日 parity。

### 第三优先级：完成跨 domain gameplay 链

```text
Modifier
→ Effect
→ Ideology
→ Trigger
→ Events
```

### 第四优先级：Economy

Economy 需要独立的字段矩阵、并行边界、守恒审计和完整 parity。

### 第五优先级：完整保存恢复

没有全域 restore，就不能清退同步 authority。

### 第六优先级：主线程权威清退

只有所有 domain 通过后才能迁移 WorldClock 和 WorldRuntimeHost。

### 第七优先级：视觉隔离和 ACTIVE

最后才允许：

- 全域 snapshot consumer；
- 完整 UI patch budget；
- ACTIVE gate 验证；
- Windows ACTIVE 默认。

## 16. 下一步具体执行顺序

### 工作包 A：重新构建和验证 parity report

1. 用成功的 SCons/VS 环境重建 Debug/Release DLL；
2. 运行 source scan；
3. 运行 ABI、trace、Climate、snapshot、save、thread isolation tests；
4. 确认新增 parity 字段可从 Godot Dictionary 读取；
5. 保存构建日志和测试日志。

### 工作包 B：Climate reference/worker 1000 日 harness

> **校正（2026-09-06）：A → B 这个顺序直接执行会产出 1000 行全部失败、且无法区分
> 失败原因的数据。**实际执行顺序改为 **S0 → S1 → S2 →（决策）→ S3 → S4**，其中
> S4 才是本工作包：
>
> - **S0 = 原工作包 A**，但必须补 build manifest（DLL SHA-256 + git HEAD + 两个 ABI
>   常量 + 构建时间）与统一的 `GODOT_BIN` 约定。重建是必需而非以防万一。
> - **S1 建立可比性**（修 §6.2 补记第 1 条）。核心原则：canonical parity hash 只能有
>   一份 C++ 实现，两侧共用——不要在 GDScript 里重写 FNV-1a，2400 cell × 40 字段 ×
>   1000 日约 1 亿次 GDScript 循环不可接受。产出的 canonical 字段表是六个 domain 可
>   复用的方法模板，是这一步最有长期价值的东西。
> - **S2 用 30 日短程测量**，目标不是通过，而是拿到 14 stage × canonical 字段的分叉
>   矩阵。这张矩阵决定 S3 策略以及其余 domain 的全部估算。定位首差异**零 ABI 成本**：
>   `field[48]`/`cell`/`stage`/`reference_bits[24]`/`worker_bits[24]` 槽位早已贯通，
>   `stage_hash[14]` 的 ABI 扩展可以一直推迟。
> - **S3 提取共享 pass**（修 §6.2 补记第 2 条）。这一步原文档完全没有，但它是唯一可
>   持续解法：不维护第二套 Climate 实现，把生产 pass 改为 Godot 无依赖纯函数，生产与
>   worker 调同一份。对拍性质因此从"两套实现比结果"（等价性要逐公式论证，且随每次生产
>   改动重新分叉）变为"同一套实现在两种驱动下比结果"（等价性天然成立，剩下的只是输入
>   边界、执行顺序和状态所有权差异）。这条理由对其余六个 domain 同样成立。
> - **S4 = 本工作包**，只有 S3 完成后才有意义。
>
> 前置条件相应从"B 通过"改为"S3 通过"。进度见 §6.1/§6.2 补记与 `artifacts/runtime/`。

1. 固定 map/config/catalog/seed；
2. 生成 2048 日 trace；
3. 运行 1000 日 OFF reference；
4. 逐日写 reference frame；
5. 运行 SHADOW worker；
6. 逐日比较 hash；
7. 首次差异写入 JSON/CSV；
8. 两张地图各运行 5 次；
9. 加入跨季、跨年、天气和 topology 场景。

### 工作包 C：Climate promotion gate —— 已放行（2026-09-08）

原定的准入条件：

```text
1000 日逐日 parity
save/restore parity
fallback_count = 0
fatal = false
source scan = 0
worker 不访问 Godot 类型
main_wait_on_sim_us = 0
```

**实际放行时这份清单被改过，改动本身要记下来。**其中两条没有按原样满足：

- **"1000 日逐日 parity" 降为 30 日 28/30 + 分叉矩阵逐条归因。**理由是生产 round 按 stride
  跑，1000 日窗口只含约 130 个有效比较日，而两日残差（day 7 spin-up、day 28 season refresh
  湿度链）已逐条归因到已知语义差而非算法分叉。判据从"多少天逐位相同"换成了"每一条分叉都
  能一对一映射到某个具体原因"。
- **"save/restore parity" 只做到 CLM2 roundtrip 绿（37/0）**，没做 restore 后继续长跑对拍。

其余五条满足。另外这次放行是 **per-domain** 的：`CLIMATE|COMMIT = 0x802`，其余七个域不受
影响，整图 ACTIVE 仍禁止。回退是一个开关（§39）。

放行后又在客户端暴露了四个 headless 没抓到的缺陷（§41、§42），这说明**这份 gate 清单本身
不足以证明"玩家看到的东西是对的"** —— 它全是 headless 指标。后续域放行时应补一条：真实
客户端会话下的字段录制对照。

### 工作包 D：Country Host 接入

在 Climate 通过后：

1. 将 Country authority 接入 Host；
2. 完整接入 Country command queue；
3. 接入 Country ACK；
4. 增加 Country save section；
5. 做 1000 日 parity；
6. 仅通过后再增加 COUNTRY bit。

## 17. 最终完成判定

只有以下条件全部满足，才算达到最终目标：

```text
implemented_domain_mask == 0xFFF
graph_coverage_state == complete
remaining_gdscript_simulation_authority == empty
save_codec_complete == true
shadow_parity_passed == true
fatal == false
ledger_failures == 0
main_wait_on_sim_us == 0
UI/frame/performance gates passed
```

在此之前，任何“ACTIVE 已完成”“worker 已经是完整权威”“Climate/Country 已经生产替代”的表述都不准确。

## 18. 结论

当前项目已经从单纯的线程边界和协议外壳，推进到具备 immutable input、trace barrier、POD store、plan/replay、ACK、snapshot、save skeleton 和统一 shadow diagnostics 的阶段。

最重要的剩余工作不是再增加诊断字段，而是用固定输入完成可复现的 1000 日逐日证明，并把每个 domain 从“诊断实现”逐一推进为“拥有真实状态、真实命令、真实 ACK、真实保存恢复和真实对拍证据的 worker authority”。

因此当前最合理的策略是：先完成 Climate 证明，再完成 Country 接入，然后逐 domain 扩大 mask，最后才清退 WorldClock 和同步 daily authority。

## 19. 文件与模块责任映射

下表用于工程交接。文件存在不代表该模块已经具备生产 authority。

| 模块 | 主要文件 | 当前责任 | 当前状态 |
|---|---|---|---|
| ABI/协议 | `gdext/src/runtime_pod_protocol.h` | domain ID、stage、header、report、队列容量 | 基础设施已完成 |
| Worker Host | `gdext/src/native_simulation_host.h/.cpp` | worker 生命周期、时间债务、输入、trace、诊断 stage | 已接入 SHADOW 诊断 |
| 输入快照 | `gdext/src/runtime_environment_snapshot.*`、`world_ext_simulation_host.cpp` | Godot → immutable native copy | 已有校验，仍需完整 trace harness |
| Climate trace | `gdext/src/runtime_climate_trace.h` | reference barrier、ring、消费顺序 | 已完成基础协议 |
| Climate kernel | `gdext/src/runtime_climate_kernel.*` | Climate plan/replay/store/hash | SHADOW/probe，未证明等价 |
| Climate authority | `gdext/src/runtime_climate_authority.*` | Climate store、commit、save/restore | 初版已存在，未提升 mask |
| Climate 公式 | `gdext/src/runtime_climate_formulas.*` | 共享公式 helper | 已建立，需继续逐公式核对 |
| Country authority | `gdext/src/country_core.*`、`country_runtime.*`、`runtime_country_pod.*` | 共享生产算法、typed boundary、CPD2、SHADOW adapter | K0/K1/K2-E 基础完成，未接管 Host |
| 全域诊断 | `gdext/src/runtime_domain_authorities.*` | 12-stage shadow 诊断 | 诊断专用，`capability_mask=0` |
| Report bridge | `gdext/src/world_ext_simulation_host.cpp`、`world_ext_runtime_graph.cpp` | C++ report → Godot Dictionary | 已扩展字段 |
| GDScript host | `scripts/game/world_runtime_host.gd` | daily authority、snapshot/UI orchestration | 仍保留同步权威 |
| WorldClock | `scripts/game/world_clock.gd` | 日期和 daily 驱动 | 仍是主线程权威 |
| Perf recorder | `scripts/ui/perf_recorder.gd` | 指标 CSV | 已有基础字段，需加入 parity 明细 |

## 20. 全域 domain 状态矩阵

| Domain | POD store | plan/replay | 命令 | ACK | snapshot | save/restore | 1000 日 parity | Host authority | mask |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| COMMIT | 是 | 是 | 基础 | 基础 | 是 | 部分 | 未完成 | 仅协议 | 已加入 |
| CLIMATE | 是 | 是 | 是 | 是 | 是 | CLM2 | 90 日双 seed 稳态绿；day7/28 见 S4 | per-domain ACTIVE | 已加入 |
| COUNTRY | 是 | 共享生产核心 | 20 opcode 核心完成；Host transport 未接 | 部分 | 同步 snapshot；ReadView 未完成 | CPD2 v2 已编入 PKSR | 未完成 | SHADOW probe | 未加入 |
| MODIFIER | store/诊断 | 诊断 | 未完成 | 诊断 | 诊断 | 未完成 | 未完成 | 未接入 | 未加入 |
| EFFECT | store/诊断 | 诊断 | 未完成 | 诊断 | 诊断 | 未完成 | 未完成 | 未接入 | 未加入 |
| IDEOLOGY | store/诊断 | 诊断 | 未完成 | 诊断 | 诊断 | 未完成 | 未完成 | 未接入 | 未加入 |
| TRIGGER_INPUT | store/诊断 | 诊断 | 未完成 | 诊断 | 诊断 | 未完成 | 未完成 | 未接入 | 未加入 |
| ECONOMY | store/诊断 | 诊断 | 未完成 | 诊断 | 诊断 | 未完成 | 未完成 | 未接入 | 未加入 |
| EVENTS | store/诊断 | 诊断 | 诊断 | 诊断 | 诊断 | 未完成 | 未完成 | 未接入 | 未加入 |
| VISUAL | snapshot 基础 | 部分 | 不适用 | 不适用 | ring 基础 | 不适用 | 不适用 | 主线程消费未完成 | 不单独开放 |

“诊断”表示能产生测试数据，不表示与旧权威逐字段一致。

## 21. 每日数据流的当前状态和目标状态

### 当前实际路径

Climate 之外的域：

```text
WorldClock._process()
→ WorldRuntimeHost.run_daily_tick()
→ GDScript/native synchronous daily
→ MapData/视觉状态修改
→ day_changed/season_changed/year_changed
```

> **更新（2026-09-08）：Climate 已经走 worker 权威并驱动显示**，下面"SHADOW 并行但不
> 驱动显示"的描述对它不再成立。Climate 那一段现在是：
>
> ```text
> WorldClock._process() → day_changed
> → apply_runtime_climate_writeback(day N 的 worker 结果 → MapData，38~39 个场)
> → season refresh
> → capture_runtime_inputs(day N+1：environment 快照 + round scalars + stage knobs)
> → 主线程 14 个 Climate 节点被抑制门跳过
> → worker 后台算 day N+1，明天回灌
> ```
>
> 即**滞后一日**：玩家在 day N+1 看到的是 worker 算的 day N。这是转 ACTIVE 时明确接受的
> 语义代价（§39）。SHADOW 路径仍然存在，用于 parity 对拍，但要在 generate 前把
> `runtime_climate_authority_enabled` 关掉才会走到。

SHADOW 路径并行存在，但不驱动上述显示：

```text
主线程 capture input
→ trace CAPTURED
→ OFF reference 写 reference parity hash + 生产 round 输入 + round_ran
→ trace REFERENCE_READY/CONSUMABLE
→ worker pop trace
→ Climate shadow plan/replay/compare
→ domain diagnostic runner
→ report/snapshot diagnostics
```

> **校正（2026-09-06）：这条路径只在手动启动 worker 的测试里成立。**
> `start_runtime_worker()` 在生产 GDScript 里没有调用点（`world_runtime_host.gd` 只有
> `_stop_previous_runtime_worker` 与 `_sync_runtime_worker_clock`），所以正常游玩时
> capture/reference 时序虽会执行，但 trace 从未被 pop，SHADOW 12-stage 从未运行。
> 见 §6.2 补记第 3 条。
>
> 另外两处与原文不同的实际行为：
>
> - reference 写的是两侧共用的 `parity_hash()`，不是 GDScript 的 SHA-256（§6.1 补记）。
> - reference 还会附带**生产这一天实际用过的 round 输入缓冲**与 `climate_round_ran`。
>   worker 因此跑的是生产用过的那份输入，而不是 capture 时另建的一份；`round_ran`
>   为 false 时整段跳过 Climate（生产 round 按 stride 跑，§6.2 补记第 4 条）。

### 最终目标路径

```text
主线程 capture immutable input
→ worker INPUT_CAPTURE
→ Climate
→ Country
→ Trigger input
→ Ideology
→ Effect
→ Modifier
→ Gameplay Effect
→ Economy
→ Events
→ Visual snapshot
→ Commit barrier
→ 主线程 poll snapshot
→ staging/patch/UI/GPU
```

两条路径不能在同一局同时写同一份权威状态。

## 22. Climate 完整实施分解

### C0：构建收口

完成定义：

- Debug/Release DLL 使用最新源码重新构建；
- report 新字段可由 Godot 读取；
- source scan 通过；
- 所有已有 Climate self-test 通过；
- 生成 build manifest，记录编译时间、ABI、catalog hash。

证据：

```text
artifacts/climate/c0-build-debug.log
artifacts/climate/c0-build-release.log
artifacts/climate/c0-test.log
artifacts/climate/c0-manifest.json
```

### C1：固定输入生成

完成定义：

- 地图种子、尺寸、生成器版本固定；
- catalog 编译结果固定；
- 输入 generation 单调；
- topology generation 变化能形成新 frame；
- dynamic-only 更新不重复复制静态 topology；
- trace 满时不覆盖未消费 frame。

测试：

```text
长度错误
NaN/Inf
非法 CSR
非法 hydro parent
错误 catalog hash
旧 generation
day 倒退
trace ring full
topology revision
```

### C2：reference frame

每个 frame 必须至少保存：

```text
day
input_generation
topology_generation
catalog_hash
input_hash
reference_state_hash
stage_hash[14]
reference payload checksum
```

生产路径只负责写 reference，不允许修改 worker store。

### C3：worker replay

worker 每日必须执行：

```text
读取唯一 trace frame
→ preflight
→ Pass-A
→ Pass-B
→ ocean/wind
→ sea ice
→ vegetation
→ weather
→ hydrology
→ year state
→ hash
→ compare
→ matched 才 commit
```

任何失败都必须：

- discard pending lane；
- 不增加 generation；
- 不推进 committed day；
- 设置 fallback reason；
- 保留上一份成功 snapshot。

### C4：差异报告

当前已有 hash 级字段，仍需补充完整首次差异：

```text
first divergent stage
field name
cell id
reference float/int bit pattern
worker float/int bit pattern
base generation
input generation
trace hash
catalog hash
last command sequence
```

输出格式固定为 JSON，并另外生成简短 CSV 摘要。

### C5：Climate gate

必须同时通过：

```text
60×40 1000 日
100×64 1000 日
普通天气
暴雨
干旱
降雪
海冰
河流/运河
跨季
跨年
topology revision
save/restore 后继续 1000 日
```

只有 C5 全部通过，才允许把 CLIMATE 加入 mask。

> **实际结果（2026-09-08）：CLIMATE 已加入 mask，但 C5 这张场景表没有逐项跑过。**
> 实际验收是 60×40 / 30 日 SHADOW 对拍 28/30 + 50×48 的 60~400 日 ACTIVE soak（对着
> `PK_SOAK_AUTHORITY=0` 的同 seed 主线程基准读逐场 nz/mean/max）+ 七项回归。表里的
> 暴雨/干旱/降雪/河流运河/跨年/topology revision 从未作为独立场景验证过 —— 它们只是被
> 混在 soak 的天数里碰到或碰不到。**这是一处已知的验收缺口**，不是已通过。
> 海冰是唯一被单独盯过的（`native_sea_ice_state_machine_test` 12/0，外加 §42 那次
> 累积缺陷的专门修复）。

## 23. Country 完整实施分解

### K0：输入和 catalog

固定：

- country catalog hash；
- technology catalog hash；
- territory CSR；
- country slot order；
- 初始 treasury；
- research weights；
- initial generation。

### K1：命令边界

主线程完成：

```text
Dictionary → typed command
handle 解析
value/range 校验
weights sum=10000
observed generation 校验
payload copy
request_id/sequence 分配
```

worker 完成：

```text
stable sort
preflight
plan
replay
receipt
ACK
```

### K2：真实 Host stage

Country stage 只能读取：

```text
上一日 Country snapshot
immutable catalog
sorted commands
上一阶段 ACK/snapshot
```

不能读取 MapData 或其他 domain 的临时 plan。

### K3：Country gate

必须证明：

- technology completion 一致；
- discovery frontier 一致；
- territory CSR 一致；
- treasury 一致；
- command receipt 一致；
- ACK 顺序一致；
- research 不触发无关 territory sync；
- CPD2 roundtrip 一致；
- 1000 日 parity 一致。

## 24. 其余 domain 的依赖关系

不能并行任意迁移，依赖关系固定如下：

```text
Country
  ↓
Modifier
  ↓
Effect
  ├──→ Ideology
  └──→ Economy
       ↓
Events
       ↓
Trigger
```

实际交付顺序仍固定为：

```text
Climate
→ Country
→ Modifier
→ Effect
→ Ideology
→ Trigger
→ Economy
→ Events
```

原因：

- Effect 需要 Country/Modifier/Ideology/Economy ACK；
- Trigger 只能消费 committed Events；
- Events 需要完整日 barrier；
- Economy 需要 Climate、Country、Modifier、Effect 的已提交 snapshot；
- Ideology 需要 Country 和 Effect ACK。

## 25. 每个 domain 的最小完成包

任何 domain 不允许只实现 store 就增加 bit。必须同时交付：

```text
catalog
store
typed command
validation
stable sort
plan
replay
intent
ACK
snapshot
state hash
save section
restore validation
unit tests
1000-day parity
fault/fallback report
performance report
```

缺任何一项都只能标记为 SHADOW 或 partial。

## 26. 测试证据目录规范

每个阶段必须写入独立目录：

```text
artifacts/runtime/<stage>/
```

至少包含：

```text
build-debug.log
build-release.log
unit-test.log
headless-test.log
source-scan.log
parity-1000d.json
parity-summary.csv
save-roundtrip.json
performance.csv
failure.log
rollback.md
mask.txt
```

`mask.txt` 必须明确记录：

```text
before_mask
after_mask
promotion_reason
fallback_reason
gate_result
```

## 27. 失败分类和处理

### 输入失败

```text
不推进当日
不修改 worker store
返回明确 input error
保留上一份 snapshot
```

### parity 失败

```text
discard pending plan
不推进 generation/day
输出首次差异
保持当前 mask
```

### ACK 失败

```text
retry/reject 按 domain 协议处理
不能静默完成 effect
不能部分提交跨 domain 事务
```

### save/restore 失败

```text
整体拒绝 restore
不污染当前 state
保留旧存档
不自动切换同步权威
```

### worker fault

```text
进入 FAULTED
保留最后成功 snapshot
记录 fault_count/fallback_reason
不自动热切换 authority
```

## 28. 当前距离最终目标的量化判断

可以确认已经完成的比例主要集中在“边界和诊断基础设施”，而不是“真实 domain authority”。

当前已完成：

```text
协议边界：高
输入校验：中高
trace barrier：中高
snapshot ring：中
命令/回执容器：中
Climate POD 外壳：中
Country POD 外壳：中
全域诊断 runner：中
```

当前仍明显不足：

```text
逐字段 1000 日 parity：未完成
全域真实 domain authority：未完成
完整 PKSR v2：未完成
WorldClock 清退：未完成
视觉/UI 完整隔离：未完成
ACTIVE gate：未通过
正式 Windows 性能验收：未完成
```

因此当前项目处于：

```text
架构和诊断基础设施阶段
→ Climate 证明阶段
→ 尚未进入全域 authority 切换阶段
```

> **校正（2026-09-06）：上面的评级是就代码存在性而言的；就运行证据而言，
> "trace barrier：中高" 与 "Climate POD 外壳：中" 在 2026-09-06 之前都应记为零。**
> 原因是 worker 在生产路径从未启动（§6.2 补记第 3 条），且比较器在数学上不可能通过
> （§6.1 补记），所以 SHADOW Climate 在此之前没有成功提交过任何一天。原文隐含假设
> "SHADOW 对拍正在持续产生数据"，这个假设不成立。
>
> 现在有了第一份可信的运行证据（`artifacts/runtime/s3-shared-passes/`）：30 日 /
> 2400 cell 下 26/30 日 parity 通过，不通过的 4 天就是生产真的跑了 Climate round 的
> 4 天；PASS_A 的四个字段已可判定为等价实现。
>
> 另有一项原文未提的规模判断：**其余 domain 的方法可复用性并不一致。**
> `Country → Modifier → Effect → Ideology → Trigger → Events` 合计约 1.15 MB，单个都比
> Climate 小，可以直接复用 S1 的字段表模板与 S2 的 harness。但 **Economy 必须独立立项**：
> 它占六成代码量（约 3.7 MB），且不是逐 cell 物理场，而是带实体生命周期与跨 cell 事务的
> 结构，parity 必须定义为人口/货币/货物的守恒审计加确定性事务顺序，而不是逐字段 bit 相等。
> 把 Climate 的做法放大套用会得出错误估算。
>
> 还有一项块 B 开始前的共性前置：`RuntimeClimateTrace` 是 Climate 专用的（硬编码
> `RuntimeEnvironmentSnapshot`，host 里只有一个 `_climate_trace` 成员）。六个 domain
> 各建一套 ring 是错的，应把 `CAPTURED → REFERENCE_READY → CONSUMABLE → CONSUMED`
> 这套状态机抽成 domain 无关的模板。

## 31. Climate 单域 ACTIVE：机制已通，生产默认关（2026-09-07）

Climate 不再等另外十个域，per-domain 权威门已经能单独提升它：

```text
runtime_climate_authority_enabled = false   # 当时的默认；已于 39 节翻为 true
simulation_thread_mode            = ACTIVE
authoritative_domain_mask         = 0x802   # CLIMATE|COMMIT
主线程 climate 图                   = 抑制（仅 native daily slice 图内的 14 个节点）
MapData 写入                       = RuntimeClimateWritebackRing
日历语义                           = 滞后一日（worker day N 在 main tick N+1 落地）
运行时回退                         = set_runtime_climate_authority_enabled(false)
```

验收：

- `tests/climate_authority_test.gd`：13/13。授予、抑制、回灌、撤销恢复，外加
  per-domain 提升不得跳过主线程 daily tick。
- `tests/runtime_climate_save_roundtrip_test.gd`：CLM2 字节往返（SHADOW 路径）。
- `tests/climate_active_parity_probe.gd`：ACTIVE MapData 对生产 MapData，按
  `writeback_last_day == N` 对齐。
- SHADOW 90 日双 seed：稳态绿；day 7 / day 28 是首次执行钉死的偏差，不累积。

全域 ACTIVE 仍未开放。Country / Economy / 其余域仍在主线程。

## 32. 开 Climate 权威前必须先关掉的两个缺口（2026-09-07）

> 这两个缺口都已关掉，默认值已于第 39 节翻为 `true`。本节保留为定位过程的记录。

用 `tests/climate_authority_soak_probe.gd`（正式多国开局、人口非零、400 天）
做了第一次真正的 ACTIVE soak。此前归档的证据全是 SHADOW parity 对拍，验证的是
worker 算得对不对，不是 worker 当权威后系统能不能长期活着 —— 这两件事一度被混
为一谈。soak 一跑就翻出两件此前完全没暴露的事，其中一件还推翻了原来的归因。

**第一件：硬崩不是 Climate 权威引入的，根因是并行执行器的屏障漏了一半，已修。**

`PK_SOAK_AUTHORITY=0` 的对照跑在 tick 375 左右同样 0xC0000005，开着权威则提前到
tick 25~75 —— 段错误是既存 bug，权威只是加速器。崩点符号化到
`gdext/src/world_ext_physical.cpp` 的 `pk_wind_div1` 并行 lambda，在
`NativeParallelExecutor` 池线程上读一个基址无效的 slot 数组：一次读出的 `ni` 是
`0x3f7096aa`（float `0.879` 的位模式）当索引，另一次访问地址是
`0x0000096000000960`（高低 32 位都是 `0x960` = n_cells = 2400）。这两个值都是
**失效栈帧上的残留数据**，崩点随调度漂移。

根因在 `NativeParallelExecutor::run_group`：它只等 `_remaining_tasks == 0` 就清空
`_task_fn` 并返回。但 worker 是在临界区内取走 `fn`/`userdata`/`task_count` 的，取
完之后、进入任务循环之前可以被抢占。等它恢复时这一代早已结束、`run_group` 已返回、
外层 pass 的栈帧已失效，而下一代又把 `_next_task` 重置了 —— 它于是用**上一代的
`fn`** 去消费**下一代的任务索引**，通过悬垂引用读那个失效栈帧。
`native_parallel_executor.h` 里原本就写着「A group owns stack-backed userdata
until run_group returns」，只是屏障没兑现这句话。

修法是新增 `_active_workers`（受 `_state_mutex` 保护）：worker 在取 `fn` 的同一个
临界区内递增，退出任务循环后递减并通知；`run_game` 的屏障改为同时等
`_remaining_tasks == 0 && _active_workers == 0`。这样在 worker 被抢占的窗口里
`run_group` 无法返回，栈上 userdata 的生命周期与实际使用者对齐。

这个竞态影响所有 `parallel_for_range` 使用者，不止 climate；Climate 权威只是把
并行组的发布频率推高、让它从「偶尔崩」变成「几十 tick 必崩」。

验收：`tests/climate_authority_soak_probe.gd` 400 天，authority 开/关各一遍 +
开着连跑三遍，全部 `exit=0`、无 NaN、`drops=0`；climate_authority_test（13）、
native_daily_graph_order_test（25）、runtime_climate_save_roundtrip_test（37）、
native_sea_ice_state_machine_test（12）、canal_runtime_test（27）、
climate_parity_probe 全绿。

追这个崩溃时走过的三条死路，记下来免得重复：

- `phys_solve ... pending=nan` 不是污染证据。`_pending_phys_solved_phase` 初值
  就是 `NAN`，`is_nan()` 是「本 phase 尚未求解」的判据，每轮重置，属正常输出。
- 回灌违反 `Slot` 的 `dtype` / `external_ref` 约束不是污染源。补上这两个守卫后
  soak 仍崩，且诊断显示 `applied=33`、`skipped` 只有 `riparian_moisture` 和
  `vegetation_succession_candidate` 这两个本就非 COMPARABLE 的字段，没有任何字段
  被新守卫拦下。（守卫本身是对的，按 slot.h 的约束该有，保留。）
- 给 `pk_wind_div1/div2` 的邻居循环补 `ni >= n_cells` 上界守卫没能止住崩溃 ——
  当时基址已经是野的，挡索引挡不住。（同样是该有的正确性守卫，保留。）

方法论上值一句：真正定位靠的是**对照实验**（authority 关掉也崩）而不是读代码。
在此之前所有静态推断都指向「双写」，方向全错。

**第二件事才是权威引入的：回灌把两个字段清零。**

| 字段 | authority=false | authority=true |
|---|---|---|
| `snow_cover` | 92~161 cells 非零 | 全 0 |
| `vegetation_growth_pressure` | 688~776 cells 非零（含负值） | 全 0 |

worker 对这两个字段算出 0，回灌照刷进 MapData，把主线程本该有的值覆盖掉。这不是
「谁最后写」的顺序竞争，是 worker 压根没在演化它们却仍然发布。早先一版 soak 里
这两个字段恒零，被误判为「世界太空、没行使到」，实际是被回灌清零 —— 这也是为什么
那次 300 天「全绿」毫无意义。

下面这条缺口是静态代码事实，且与上面的清零直接相关：

**一、抑制面不完整 —— season_refresh 是第二个 climate 写者。**
抑制门装在 `dispatch_system_schedule`（probe/debug）和 `run_native_daily_slice`
（生产 hot path），覆盖的是 native daily slice 图里的 14 个 climate 节点。
`SeasonRefreshSystem` 不在那张图里：它是 SUS 里按 `period_ticks` 自驱的独立
system，走 `start_season_round_b_plus` → C++ round slice →
`begin_finish_season_round_b_plus` 直接赋 `map.soil_moisture_arr` / `map.vegetation_growth_pressure_arr`。

盘过两侧写集后，真正重叠的 parity 字段是三个：

| 字段 | season refresh 写于 | 日频写者 |
|---|---|---|
| `moisture` | stage 0 / 1 / 3 / 4 | transpiration pass |
| `snow_cover` | stage 9（sync） | weather distribute |
| `vegetation_growth_pressure` | stage 11（feedback decay） | transpiration pass |

（season refresh 还写 `base_moisture`、`soil_moisture` 和 terrain/landform/
vegetation/cover/is_water，但这些不在回灌字段表里，不构成双写。）

400 天 soak 给这张表补了一条此前没有的事实：重叠的三个字段里，`snow_cover` 和
`vegetation_growth_pressure` 在 worker 侧的输出**恒为 0**（authority 关掉时分别有
92~161 和 688~776 个非零 cell）。所以这两行的问题不止是「谁最后写」，worker 侧对
它们的日频演化本身就是缺的或输入没接上，却照样发布并覆盖主线程的值。定位这一点
是 season refresh 进 worker 之前的必要前置 —— 否则搬完仍然是发布 0。

**把这三个从回灌表摘掉是伪解。** 它们都不是叶子字段：`RuntimeEnvironmentSnapshot`
每天从 MapData 读入 `cell_moisture` / `cell_snow_cover` / `cell_base_moisture` /
`cell_soil_moisture`，所以 worker 不持有私有跨天状态、不会自己漂移，但代价是
**谁最后写 MapData 就决定了 worker 下一天的输入**，而回灌（`_process`）与 season
refresh（SUS tick）的先后在一帧内非确定。摘掉回灌等于把日频 transp/weather 对
这三个字段的演化整个丢掉，`moisture` 只剩季频跳变 —— 那不是划分所有权，是删掉
一半物理。

这三个字段本质上是「日频连续演化 + 季频批量重算」共同拥有的状态，原同步路径靠
串行执行序保证顺序。唯一自洽的切法是让两个写者回到同一执行序，也就是 season
refresh 的 12 个 stage 一并进 worker。只在 SUS 层加抑制门不够：字段所有权不切清，
抑制只是把双写换成两边都不写。

**二、曾经被这个缺口掩盖的整局早退门。**
`_on_clock_day_changed` 的早退门一度读 `simulation_worker_ready`。该字段在
per-domain 落地时被扩成"含部分提升"，于是 Climate 一提升就把整个主线程 daily
tick 跳掉了 —— 经济、国家、触发器、perf 录制全部静默，而 Climate 看起来健康。
现已改回只认全图 `authority_ready`。`climate_authority_test.gd` 里那条走信号
路径的断言就是盯这个的；直接调 `run_daily_tick` 的测试和 headless perf 都绕过
这条路径，所以第一次是靠真机才发现。

**三、三个"恒零/衰减"字段的根因已定位到 stage 接线，不是算法分叉。**
上面那条「worker 侧输出恒为 0」当时只是现象。现在有了确切答案：ACTIVE 下 worker
每天跑满 8 个 stage（pass_a/pass_b/ocean_water/ocean_land/wind_air/wind_surface/
sea_ice/transpiration，240 天 soak 全部 239/239），albedo 按 `weather_albedo_stride`
的节拍跑；但 **weather field(11) / weather distribute / feedback(10) /
vegetation_dynamics(9) 四个 stage 从不执行** —— 它们的 `Input` 结构由生产侧的
`record_production_*` 填充，而 ACTIVE 恰好把生产侧抑制掉了，于是 `input.climate_*`
永远是空 `shared_ptr`，内核直接跳过。三个字段的对应关系正好落在这四个 stage 上：

| 字段 | 缺失的写者 | 状态 |
| --- | --- | --- |
| `snow_cover` / `snowpack` | weather distribute | **已修**：400 天 soak 稳定 111~113/2400，落在对照组 92~161 区间内 |
| `vegetation_growth_pressure` | feedback(10) | **已修**：400 天 soak 稳定 909/2400（对照组 688~776） |
| `soil_moisture` | 见下（归因是错的） | 仍衰减，但根因不在这四个 stage：worker store 根本没有这个成员 |

`soil_moisture` 那条最能说明性质：它不是被写零，是**只有支出没有收入** —— 蒸腾
每天扣水，而补水来自 weather 的降水，那个 stage 不跑。所以这四个 stage 是同一个
接线缺口的四个面，不是四个独立 bug。

已完成的前置：`climate_stage_knobs` 通道（`map_generator.gd` →
`world_ext_simulation_host.cpp`）与 ACTIVE 专用的节拍计数器
（`_runtime_climate_worker_weather_embed_day` / `_..._stage_b_call_index`；生产侧
计数器被抑制后永不推进，直接复用会让节拍冻结）。albedo 是走通这条通道的第一个
stage，可作为其余四个的模板。

**剩余四个 stage 的接线路径（已调查确认，避免重复摸索）：**

1. **knobs 只有一个公开入口**：`weather_system.build_unified_fast_tick_weather_knobs
   (map, world, season_idx, anomaly, season_phase, stage_b_knobs)`。field /
   distribute / summary / stage_b 四组是它一次性组装的，`_build_weather_field_knobs`
   和 `_build_weather_distribute_knobs` 都是私有的，没有单独入口。所以这四个 stage
   应当一次接通、共用一份 knobs，而不是逐个来。注意它经
   `_build_native_daily_weather_super_knobs` 调用时带副作用
   （`_weather_stage_b_call_index += 1`、`_consume_weather_dt_days()`），capture
   时必须走 `commit_side_effects=false`，否则会污染生产计数器。
2. **`distribute` 比 field 简单得多**，且它就是 `snow_cover` 的写者，建议先做：
   worker 段读的是 `next.weather_*`（store 里 pass_b 刚算的），不是 `input` 的
   lane，所以那四条 lane 只需满足 size 检查即可；真正需要的是 knobs（纯标量 +
   四张按 WeatherType 索引的 8 项表）+ `heat`/`elevation`/`landform`/`terrain`/
   `cover`/`soil_moisture`（全在 `RuntimeEnvironmentSnapshot` 里）。
3. **跨 tick 状态要改 worker 自持**，当前全是"每天从生产记录播种、输出丢弃"的
   scratch：`accumulated_snow_days` / `pre_snow_cover`（distribute）、
   `conv_inhib` / `field_init`（field，`field_init` 已改成只首次分配）。改法是
   只在 size 不匹配时从 input 播种，之后不再覆盖。
4. **ψ / cyclone / monsoon 现在可以由 worker 自持推进**。`WeatherFieldInput` 里
   那句"worker 不自己推进 ψ，因为 wind pass 还没提取"已经过期 ——
   wind_air/wind_surface 现在每天在共享 round 里跑。`synoptic_advance_pure` 是共享
   纯内核（生产侧内联在 solve pass 里，`world_ext_weather.cpp:724-751`），输入是
   邻接表 + pos_x/pos_y + 风场 + 温度，worker 全都拿得到，只需自己持有
   `_wx_synoptic` / `_wx_synoptic_prev` 两份。
5. **`traj_idx` / `traj_w` 不用接**：它们是风场派生量且带指纹校验，worker 侧重建不出
   同一份；生产未命中时本来就传空，内核走逐次重算分支。
6. **`pos_x` / `pos_y` 需要新增到 static knobs**：生产从 knobs 的 `cell_pos`
   （`PackedVector2Array`）解交织而来，`RuntimeEnvironmentSnapshot` 里没有这条。
7. **stage 顺序要重排**：feedback(10) 当前排在 weather(11) 之前，而生产语义是
   feedback 读 weather 当天的输出。接线时一并调整，否则 feedback 会读到昨天的天气。
8. **hydrology(12) 无需接**：`runtime_hydrology_enabled` 默认 false，生产也不跑它。

也就是说，剩余工作的实质不是"补几个字段"，而是要在 capture 时点重放
`weather_system` 的整条 knobs 组装链（它自身还带 `_dist_acc_snow_cache` 这类跨 tick
缓存），再把几组跨 tick 状态从 scratch 改成 worker 自持。

**四、distribute 已接通（`snow_cover` 恢复），并牵出一个更基础的 capture 缺口。**
按上面第 2 条的判断先接了 distribute：`weather_system.build_distribute_knobs_for_worker`
（薄包装，复用生产同一个 builder —— 那些 snow/flood 阈值有一半是 builder 里的硬编码
常量，重抄一份就是第二个漂移入口）→ `climate_stage_knobs.stage_distribute` →
`world_ext_simulation_host.cpp` 解析。240 天 soak：weather stage 跑满 30 次（240/8，
与 weather 轮节拍完全一致），`snow_cover` 稳定 110/2400。

接线过程中发现真正卡住 distribute 的不是 knobs，而是 **`cell_heat_input` /
`cell_soil_moisture` / `cell_weather_type` 三条 lane 从来就不在 capture 字典里**。
`RuntimeEnvironmentSnapshot` 早就声明了这三个字段，`validate_*` 也检查它们，但
`copy_f32` 的语义是「key 缺席就 `dst.clear()` 并返回 true」—— 缺席是合法且静默的。
于是 distribute 的 lane 完整性检查失败、整个 stage 直接跳过，表现为 `snow_cover`
恒零而不是任何报错。**任何新 stage 接线都要先确认它要读的 lane 真在 capture 里**，
不能因为 snapshot 结构体里有这个字段就假定它被填了。现在 lane 不齐时会
`push_warning` 一次，不再静默。

两条积雪计数（`accumulated_snow_days` / `pre_snow_cover`）没有 SoA 镜像也不经回灌，
所以加了 `WeatherDistributeInput::own_snow_state` 区分两种模式：SHADOW 留 false，
每天跟生产播种以便对拍同一条状态链；ACTIVE 置 true，只在首次建立初值后由 worker
自持。直接改成无条件自持会让 SHADOW 从第一天起各走一条积雪账，parity 会把它报成
算法分叉 —— 改完 parity 仍是 28/30，与接线前一致。

**五、feedback / vegetation_dynamics / weather field 也已接通，五个 stage 全跑。**
400 天 soak：`pass_a`..`transpiration` 各 399/399，`weather` 50（= 400/8，weather 轮
节拍），`albedo` 3、`vegetation` 5、`feedback` 3（各自 stride），0 drops，回灌 33 字段，
回归六项全绿、SHADOW parity 仍 28/30。

三件事值得记下来，因为它们都不是"再抄一份 knobs"那种工作量：

1. **feedback 与 vegetation 的 knobs 一行都不用新写。** 生产把它们和 albedo 的
   knobs 建在同一个 `_build_native_daily_stage_b_knobs` 里，而那份字典早就整份传过
   边界了 —— 包括 vegetation 那 8 张 catalog 表（`ideal_temp_table` 等）。之前把
   "8 张表进 static knobs"列为一项独立工作是误判，它们已经在路上了。两个 stage 加起来
   只是 C++ 侧的解析。
2. **capture 缺的 lane 一共补了九条**，分三批被发现，每一批都是同一个静默模式：
   `cell_heat_input` / `cell_soil_moisture` / `cell_weather_type`（distribute）、
   `cell_base_moisture` / `cell_water_balance_30d` /
   `cell_temperature_transport_anomaly`（feedback + vegetation）、
   `cell_pos_x` / `cell_pos_y` / `cell_wind_x` / `cell_wind_y` / `cell_wind_speed` /
   `cell_air_mass_temp_anomaly`（field；前两条连 `RuntimeEnvironmentSnapshot` 里都
   还没有，是这次新加的字段）。
3. **weather field 全场输出 0 的原因是 `field_init` 播种成了 1。** lane 齐了、
   knobs 到了、内核也确实执行了，但 `vapor` 与 `precip` 整场恒 0。`field_init=1` 让
   内核认为每个格子都已初始化，于是跳过那段"从 `moisture * 0.15` 播种 prev_vapor"
   的 spinup，而 worker store 的 `vapor` 是从 0 起步的 —— 没有水汽就没有凝结，也就
   没有降水。ACTIVE 必须传 0 让它自己 spinup 一次，之后 commit 会置 1 并由 worker
   自持（`own_field_state`，与 `own_snow_state` 同一套区分）。**紧接着还有第二个坑**：
   `WeatherFieldKnobs::n_cells` 忘了设，停在默认 0，内核照样"跑完"但一个格子都没
   写。这两个都属于"stage 执行了、报告说它跑了、输出却是空的"，stage mask 分辨不
   出来 —— field 和 distribute 还共用同一个 stage bit，所以 distribute 的成功会把
   field 的空转盖住。**新 stage 接线后要验的是输出量，不是 stage 有没有跑。**

ψ / cyclone / monsoon / 轨迹表这四项耦合仍未接：内核对它们每一项都有 nullptr 分支
（轨迹表为空时逐次重算，本来就是生产 cache miss 时的路径），所以现在跑的是无
synoptic 耦合的降水主循环。ψ 可以用共享的 `synoptic_advance_pure` 由 worker 自持推进
（wind pass 已经每天在跑，那句"wind 还没提取所以 worker 不推 ψ"的注释已过期），这是
下一步而不是缺陷。

**`soil_moisture` 的归因要改正。** 它不是"降水没接"—— field 接通后降水确实起来了
（`precip_nz` 135→266→427，`vapor` 逐轮累积），但 `soil_moisture` 400 天仍从 0.054
掉到 0.0002。真实原因是**worker 的 climate store 里根本没有 `soil_moisture` 成员**：
distribute 与 feedback 拿到它之后写的都是 scratch（`_distribute_soil_scratch` /
`_feedback_soil_moisture`），当天用完即弃，回灌自然也带不回 MapData。它和
`base_moisture`、`regen_score` 同属"没有 store 成员承接的 in/out"那一类。要修它得给
store 加成员并纳入回灌表，那是与 stage 接线无关的另一项工作。

**六、双写的执行序已钉死；同一次对照实验暴露出「落在区间内但不演化」。**

第一节留下的竞争（回灌在 `_process`、season refresh 与 capture 在 SUS tick，一帧内
先后无保证）改法比预想的小：不需要把 season refresh 的 12 个 stage 搬进 worker。
这三个字段本来就是「日频连续演化 + 季频批量重算」的快慢层结构，两者在逻辑上是串行
的（日频累积 → 季频消费并衰减 → 日频继续），缺的只是一个保证物理顺序的调用点。
现在 `_on_clock_day_changed` 在 `run_daily_tick` 之前显式回灌一次，把顺序钉成

    回灌(第 N 天) → season refresh → capture(第 N+1 天的输入)

三者落在同一个调用栈里。`_process` 那次回灌保留（服务视觉每帧刷新），apply 侧的
generation 与 committed-day 双重门让同一天的重复调用不会二次应用。

soak 的 `serial` 模式原本是 `tick → 回灌`，正好与客户端相反，所以它既不能证伪也不能
证实这个顺序 —— 注释里那句「serial does not reproduce」说的就是这件事。现已改成同序。
改完 240 天 soak 的每个字段数值与改前**完全一致**，这本身是预期结果：serial 从不让
两个写者交错，顺序改动的价值在客户端路径上，headless 无法覆盖（`frames` 模式仍卡在
`native_daily_day_barrier`）。

真正的收获来自这次补跑的 authority=0 对照。此前验收只看「非零 cell 数是否落在对照
区间内」，漏掉了一个维度：**活跃 cell 集合是否在变**。

| 字段 | authority=0（25→225 天） | authority=1（125→225 天） |
| --- | --- | --- |
| `snow_cover` nz | 99 → 179 → 152，mean 0.030~0.062 随季节起落 | 113 → 111，mean 恒 0.0351 |
| `vegetation_growth_pressure` nz | 850 / 725 / 779 持续变化 | 909 一动不动 |
| `soil_moisture` nz | 914 → 1970 单调增长 | 537 一动不动，mean 0.0134 → 0.0034 |

第五节说 `snow_cover`「稳定 111~113/2400，落在对照组 92~161 区间内」、
`vegetation_growth_pressure`「稳定 909」—— 措辞没错，但「稳定」在这里不是好消息。
对照组这两个字段的活跃 cell 数随季节呼吸，worker 侧是常数；`soil_moisture` 差得最
远，对照组 240 天里活跃 cell 翻了一倍，worker 侧恒为 537 且均值单调掉到四分之一。
**验收标准要跟着改：非零计数落在对照区间内不足以说明字段活着，还要看它随时间变不
变。** 恒定的 nz 配上单调的 mean，恰好是「有写者、无累积」的指纹。

**七、根因在 `plant_available_water` 的上游：`water_balance_30d` 形状与量级都错。**

冻结的三个字段有一个共同上游。transpiration 算的是
`growth_pressure = clamp(PAW * heat, 0, 1)`，而生产侧的 PAW **不是积分量，是纯派生量**
（`runtime_climate_passes.cpp:5042`、`:2602`）：

    PLANT_WATER[i] = IS_WATER[i] ? 0 : pk_plant_available_water(
        MOIST[i], WB30[i], SOIL[i], weights...)

它由 `moisture` / `water_balance_30d` / `soil_moisture` 三条输入即时算出，没有跨天
状态。所以「PAW 没有累积」这个说法本身是错的 —— 它不需要累积，需要的是三条输入正确。

**方法论上记一条：单点 cell trace 在这里给了错误结论。**
`PK_CLIMATE_TRACE_CELL=1200` 显示 `paw 0 -> 0` 四十天不动，看着像全场冻结，实际那是
一个水域格 —— `IS_WATER` 分支下 PAW 恒为 0 是正确行为。把 PAW 与 WB30 加进 soak 的
全场 liveness 扫描之后才看清真相。**争用/冻结类问题要看全场分布，单个格子分不出
「这个格子本来就该是这个值」和「全场都坏了」。**

150 天双向对照（`plant_available_water` / `water_balance_30d` 两列是这次新加的）：

| 字段 | authority=1 | authority=0 |
| --- | --- | --- |
| `plant_available_water` | nz 914，mean 0.33999 → 0.34715（两个离散值） | nz 914，mean 0.294 → 0.258 单调 |
| `water_balance_30d` | **nz 2400**，mean **0.750 → 0.433** | **nz 914**，mean **0.040 → 0.0085** |
| `moisture` | mean 0.956 → 0.910 | mean 0.892 → 0.859 |
| `soil_moisture` | nz 537 恒定 | nz 914 → 1845 增长 |

PAW 的形状是对的（nz 914 两侧一致），量值只在 vegetation_dynamics 的节拍上跳一次
（每 48 天），中间不动 —— 因为它的三条输入在 worker 侧不动。

**真正的缺陷是 `water_balance_30d`：形状和量级都不对。** worker 给全部 2400 格都写了
非零值（生产只有 914 个陆地格非零），均值高出约 20 倍。它是 PAW 的输入，于是错误
向下传播到 PAW → `growth_pressure`，而 `moisture` 偏高（0.956 vs 0.892）也与这条
输入偏大一致。

WB30 在内核里唯一的写者是 `RuntimeClimateStage::RUNTIME_HYDROLOGY`
（`runtime_climate_kernel.cpp:711`），而 soak 里 `hydrology=0` —— 它一次都没跑。原因
不是 `runtime_hydrology_enabled`（那个管的是生产侧另一条独立水文系统），而是**这个
stage 所在的整段是 fallback 分支，只在生产没有提供共享 round 时才执行**；ACTIVE 下
共享 round 每天跑满，这一段被整体跳过。而且它用的是水桶积分
（`WB30 = WB30 * 29/30 + (inflow - VGP*0.015)/30`），与生产的派生公式根本不是同一个
模型 —— 所以让它在 ACTIVE 下跑起来是错的解法，那会引入第二个模型。

**WB30 的写者已找齐，但归因还没落地 —— 这里记两条走错的路，避免下轮重复。**

worker 侧写 `water_balance_30d` 的地方有两处：

1. **weather distribute**（`runtime_climate_kernel.cpp:1235`，`lanes.water_balance_30d
   = next.water_balance_30d.data()`）。它每 8 天跑一次，且**对全场 2400 格无条件
   写**，不区分水陆 —— 这就是 `nz=2400` 的直接来源（生产只有 914 个陆地格非零）。
2. **共享 hydrology 内核**（`:1341`，同一处还写 `plant_available_water` / `runoff` /
   `groundwater` / `river_storage` / `river_discharge` / `riparian_moisture`）。
   行 1270 的注释说得很清楚：这八条「都是逐日累积的」，hydrology 才是它们的权威写者。

第 2 个从来没跑过。gate 是
`shared_hydrology_ran = hydrology_requested && (shared_round_ran || !input.climate_round_ran)`，
而 `hydrology_requested` 就是 `input.climate_hydrology` 非空 —— **与前五个 stage 完全
同一个模式**：填充它的 `record_production_hydrology` 在 ACTIVE 下被抑制门关掉，input
成了空 `shared_ptr`，内核静默跳过。

于是 ACTIVE 下的水文链变成：WB30 由 distribute 每 8 天全场覆写（形状错、量级错），
PAW 只由 vegetation_dynamics 每 48 天顺带算一次（所以冻结在两个离散值上），
`runoff` / `groundwater` / `river_storage` / `river_discharge` / `riparian_moisture`
彻底没有写者。三个字段的冻结、`moisture` 的偏高、`soil_moisture` 的衰减，全部由这
一个缺口解释。

**走错的路之一：以为 hydrology 是第六个待接线的 stage。** 看到共享 hydrology 内核
从不执行、而它正是那八条累积量的权威写者，很容易得出「`runtime_hydrology_enabled`
管的是别的系统，这个共享内核被漏接了」。**不成立**：
`map_generator.gd::_build_native_daily_runtime_hydrology_knobs`（`:5020`）在
`runtime_hydrology_enabled` 为假时直接 `return {}`，所以**生产侧同样不跑 hydrology**。
原来标记「无需做」的判断是对的，两侧都不跑，这里不构成 ACTIVE 独有的缺口。

**走错的路之二：以为生产侧 distribute 不写 WB30。** 既然 hydrology 两侧都不跑，
差异就该落在 distribute 上，于是猜「worker 传了 WB30 lane、生产没传」。也**不成立**：
`world_ext_weather.cpp:2061` 明确有 `wdl.water_balance_30d = s_waterbal.arr_f32.ptrw()`，
两侧跑的是同一个 `weather_distribute_pure`，都写这条 lane。

所以差异不在「谁写」，而在**初值**。

**根因（已修）：`seed_from_input` 把 WB30 播成了 PAW。**
`runtime_climate_authority.cpp` 原来那一行是

    _store.water_balance_30d[i] = _store.plant_available_water[i];

而 `environment.cell_water_balance_30d` 就在旁边、`validate_*` 也检查它，却没被用。
两者物理意义不同：PAW 是植物可用水（同图量级 0.3~1.2），WB30 是 30 天水平衡（生产
同图约 0.04），差的正好是观测到的约 20 倍。

形状也由此解释：seed 在 bind 时执行，那时地图生成刚算完的 PAW 还是**全场非零**
（水域格要等第一次 vegetation_dynamics 才被 `is_water` 分支清零），所以错误初值是
2400 格全非零。而 distribute 是 store 里 WB30 唯一的写者，它对陆地格只把原值写回、
对水域格按 `wb + (0 - wb)/30` 衰减（`runtime_climate_passes.cpp:4568`），没有任何
一步会纠正这个初值 —— 于是它一直留在场里缓慢下沉。衰减率也对得上：150 天里
distribute 跑约 18 次，`(29/30)^18 = 0.546`，而实测全场均值 0.750 → 0.433 是 0.577。

修成从 `environment.cell_water_balance_30d` 播种后，150 天双向对照：

| 字段 | 修前 authority=1 | 修后 authority=1 | authority=0 |
| --- | --- | --- | --- |
| `water_balance_30d` nz | 2400 | **914** | 914 |
| `water_balance_30d` mean | 0.750 → 0.433 | **0.0534 → 0.0297** | 0.0402 → 0.0085 |
| `plant_available_water` mean | 0.340 → 0.347 | **0.2963 → 0.2992** | 0.294 → 0.258 |
| `moisture` mean | 0.956 → 0.910 | **0.912 → 0.871** | 0.892 → 0.859 |

形状精确对上（914 = 914），PAW 的量级从 0.34 落到 0.296（对照 0.294），`moisture`
也从 0.956 收到 0.912（对照 0.892）。回归 13/37/25/12 全绿，SHADOW parity 仍 28/30。

**仍未解决的是「活跃集合冻结」，它与量级错误是两件事。** 修完之后 PAW 依然只在两个
离散值间跳（0.2963 / 0.2992），而对照组单调下降；`vegetation_growth_pressure` 的
nz 仍恒 909（对照 850 → 725），`soil_moisture` 仍恒 537（对照 914 → 1845）。原因是
worker 侧 PAW 的写者只有 vegetation_dynamics（每 48 天），而生产还有 season refresh
的 river ecology（`runtime_climate_passes.cpp:5042`，每 30 天）在写它。season refresh
仍在主线程跑，它写进 MapData 的 PAW 会被 capture 带进 environment，但 worker 的 store
在 seed 之后就不再读 environment 的这条 lane，于是下一次回灌又把 worker 那份旧值刷
回去。这是「store 自持但缺一个日频写者」的问题，不是初值问题。

**同一个 seed 函数里还有三处同类近似，其中两处有真值可用：**
`temperature_365d_ema` 被赋成 30d EMA（environment 有 `cell_temp_365d`）、
`vegetation_vitality` 硬编码 `0.5f`（environment 有 `cell_vegetation_vitality`）。
另外 `snowpack = snow_cover` 与 `thermal_energy = cell_temp` 确实没有对应 lane，属
无奈的近似。这两处有真值的没有一起改，是为了「一次只动一个变量」好归因 —— 但按
WB30 的先例，它们很可能是同一类缺陷。

**方法论上这一节值三条记录：**单点 cell trace 会因为「这个格子本来就该是这个值」而
给出错误结论（水域格 PAW=0）；「某个 stage 从不执行」不等于「它被漏接了」，要先确认
生产侧是否也不执行；「worker 有这条 lane」不等于「生产没有」，两边都要看代码而不是
靠对称性推断。三次归因里有两次是靠读代码推出来的错误结论，唯一可靠的证据都来自
双向 soak 对照的全场分布。

## 33. 冻结场收尾：seed 补真值、soil 回灌，与 capture 时点推翻的一个结论（2026-09-08）

**上一节留的两处 seed 近似已改完**，都改成读 environment 的对应 lane
（`temperature_365d_ema` ← `cell_temp_365d`，`vegetation_vitality` ←
`cell_vegetation_vitality`）。按 WB30 的先例判断它们属同一类缺陷，验证后成立。

**`soil_moisture` 走 snapshot 独立字段回灌，不进 store。** 上一节记的方向是「进 store
成员 + 回灌表」，实际没这么做：`RuntimeClimateStore` 的字段集同时决定 PKEC 存档格式
（`CLIMATE_CELL_FLOAT_LANES` 宏同时驱动 payload 的 append 与 read），为一条不需要跨天
自持的场去改存档格式并 bump schema 不划算。改成在 `RuntimeClimateSnapshot` 上加独立
字段：kernel 暴露 `distribute_soil_moisture()`，`snapshot()` 拷进去，
`apply_runtime_climate_writeback` 在字段表循环之后单独写 `cell_soil_moisture` slot
（同样带 `dtype` / `external_ref` 两道 slot.h 约束检查）。跨天累积由 MapData 承载 ——
每天从 environment 播种进 scratch、算完回灌。

150 天双向对照：

| 字段 | authority=1 修前 | authority=1 修后 | authority=0 对照 |
| --- | --- | --- | --- |
| `soil_moisture` | nz **537**，mean 0.054 → **0.0067** | nz **914**，mean 0.047 → 0.024 | nz 914 → 1845，mean 0.043 → 0.017 |

`nz=914` 正好是陆地格数，与对照组起点一致；衰减曲线也从「崩到 0.0067」变成与对照同量
级。对照组后期 nz 长到 1845 是季节性扩散，worker 侧恒 914，属残留差异不是缺陷类型。
`writeback_days` 142 → 148。

**`climate_season_refresh_ran` 在 ACTIVE 下一直是关的。** 它只在
`RuntimeClimateTrace::mark_reference_ready` 里被填 —— 那是 SHADOW 的 reference publish
路径，而 ACTIVE 不走 trace。内核那段收回逻辑的注释写着「ACTIVE 之后这条语义依然成立：
season refresh 保持在主线程，它是地理权威」，设计意图在，实现没跟上。已接到 capture
这条路上。判据用边沿检测而不是 `_last_season_refresh_day == day`：`finish_season_refresh`
与 capture 都在同一个 SUS tick 里，但 season round 是分片跑的，finish 落在哪个 tick 的
哪个位置不由 capture 决定，日相等会静默漏轮（实测 150 天 3 次 refresh 只捕到 1 次）。

**这一节最重要的一条是它推翻了第 32 节「双写执行序已钉死」的结论。**
`_on_clock_day_changed` 里确实把回灌排到了 `run_daily_tick` 之前，但 capture 并不在
season refresh 之后 —— 它在 `_sus.tick()` **之前**（见 `world_ext_simulation_host.cpp`
里 `fill_climate_round_input` 那处注释：capture 必须早于 `_sus.tick()`，这样 slot 内容
才是生产 pass_a 稍后会读到的那一份），而 season refresh 跑在 `_sus.tick()` 里面。真实
顺序是：

```
回灌(worker 第 N 天) → capture(第 N+1 天的输入) → season refresh 写 MapData
                                                        ↓
                              第 N+1 天开头的回灌把它覆盖掉
```

**所以 ACTIVE 下 season refresh 对回灌表内字段的写入整体作废。** PAW 就在回灌表里，
而它在 ACTIVE 下有两份，通过 MapData 首尾相接：

```
next.plant_available_water（store，进回灌表）
    ↑ 每 48 天被 vegetation_dynamics 写一次，别处不写
input.climate_round_input（capture 从 slot 填，喂共享 round 的 transpiration）
    ↑ 就是上面那份昨天回灌的结果
```

于是 PAW 只在 `vegetation_dynamics` 那几天动一下 —— 150 天里只有两个不同值
（0.296 / 0.302），而对照组单调降 12%（0.294 → 0.258）。

顺带纠正一处：`PASS_A` 里那次 `read_or(input.cell_plant_available_water, ...)` 不参与这个
闭环。它在 `if (input.climate_round_ran && !shared_round_ran)` 分支里，属于「共享 round
不可用时的诊断近似」，ACTIVE 下共享 round always 跑，这一整段是跳过的。判断哪条路径生效
必须看 `shared_round_ran`，不能只看 stage 名字。

`moisture` 没有这个问题，因为它的收回走 `base_moisture`，而 `base_moisture` 没有 store
成员、不在回灌表里，主线程仍是它唯一的写者。

基于这个认识，一开始为 PAW 加的「季末从 input 收回」被删掉了，没有留在代码里：它既冗余
（PASS_A 每天就在播种）又无效（读的是自己回灌的值）。留下的是解释这件事的注释。**正确
的解法是让 worker 每天自己派生 PAW** —— 它是 `f(moisture, WB30, soil)` 的纯派生量，三个
输入现在都齐了（WB30 上一节修好、soil 这一节修好），不该被当成一条需要从外部收回的状态。
SHADOW 侧要用 `own_*` 标志隔离，否则会与生产每 48/49 天一次的节拍分叉。

回归：parity 仍 28/30，`climate_authority_test` 13、save roundtrip 37、
`native_daily_graph_order_test` 25、`native_sea_ice_state_machine_test` 12、
`canal_runtime_test` 27，全部 0 失败。150 天 soak 0 drops、无非有限值。

## 34. PAW 改为 worker 每日自派生（2026-09-08）

按上一节的结论落地：PAW 是 `f(moisture, WB30, soil_moisture)` 的纯派生量，没有跨天累积，
所以「从外部收回」这个抽象本身就是错的 —— 它需要的是每天重算。三个输入现在都齐了
（WB30 见第 32 节、`soil_moisture` 见第 33 节）。

新增 `RuntimeEnvironmentSnapshot::climate_own_paw` 与三个权重字段。**门控是必须的，不是
保守**：SHADOW 下 PAW 必须跟着生产的节拍走（生产只在 `vegetation_dynamics` 与 season
refresh 的 river ecology 里算它，约每 48/49 天一次），每天自算会立刻分叉。这与
`own_snow_state` / `own_field_state` 是同一套「谁持有跨天状态」的区分，只是这条场压根不
需要持有。

三个权重（0.35 / 0.25 / 0.65）无条件从 `stage_b` 取，不挂在 `run_veg_dyn` 下面 —— 每天
派生都要用，而那个 stage 每 48 天才跑一次。与生产 `world_ext_climate.cpp` 读的是同一份
knobs。派生位置在 moisture 收回之后、共享 round 之前，读 `next.moisture` 而不是
`current`：收回可能刚把 season refresh 的 `base_moisture` 写进 `next`，PAW 应当看到它。
水域格恒 0，与生产两处调用点的 `is_water` 分支一致。

150 天双向对照：

| 字段 | authority=1 修前 | authority=1 修后 | authority=0 对照 |
| --- | --- | --- | --- |
| `plant_available_water` | 两个值 0.296 / 0.302，nz 恒 911 | **六个采样点六个值** 0.305 / 0.309 / 0.303 / 0.300 / 0.306 / 0.302，nz 910 → 912 | 0.294 → 0.258 单调降，nz 912 |

冻结解除了：PAW 现在逐日演化，活跃集合也跟着微动。残留差异是量级偏高且震荡而非单调下降
（0.30 上下 vs 对照 0.294 → 0.258），归因到它的两个输入在 worker 侧本身偏高 ——
`moisture` 0.902~0.913（对照 0.859~0.892）、WB30 0.029~0.053（对照 0.0085~0.040）。这两条
都由共享 round 内核算，两侧同一份代码，所以差异在初始条件或 `base_moisture` 这条主线程
写的输入上，属于下一轮的题目。

`vegetation_growth_pressure` 仍冻结（nz 恒 909，150 天只有 0.1131 与 -0.0106 两个值，且
在第 75~100 天之间跳成负值）。它由共享 round 的 transpiration 与 `climate_feedback` 写，
transpiration 吃的是 `_round_in` 里那份滞后一天的 PAW，所以 PAW 解冻不会自动带动它 ——
这是独立的一条，下一轮单独查。

回归：parity 仍 28/30（`own_paw` 在 SHADOW 下为 false，符合预期），
`climate_authority_test` 13、save roundtrip 37、`native_daily_graph_order_test` 25、
`native_sea_ice_state_machine_test` 12、`canal_runtime_test` 27，全部 0 失败。150 天 soak
`writeback_days=148`、0 drops、无非有限值。

## 35. 「季节信号被 capture 时点挡住」——假设被证伪并已回滚（2026-09-08）

先纠正第 34 节的一处怀疑：**`vegetation_growth_pressure` 跳负值不是缺陷。** 拿到
authority=0 对照后，主线程那侧的 VGP 全程也是负的（150 天六个采样点：-0.022 / -0.011 /
-0.011 / -0.0055 / -0.038 / -0.019）。feedback 减 stress 之后本来就不 clamp。

**真正值得注意的是对照组暴露出的一个模式**：四条场在 worker 侧全部平坦，而主线程那侧随
季节明显呼吸。

| 字段 | authority=1 | authority=0 对照 |
| --- | --- | --- |
| `snow_cover` | nz 恒 113，mean 恒 0.035 | nz 99 → **162**，mean 0.030 → **0.058** |
| `vegetation_growth_pressure` | nz 恒 909，两个值 | nz 850 → **725**，六个采样点五个值 |
| `soil_moisture` 活跃集合 | nz 恒 **914** | nz 914 → **1845** |
| `moisture` | 0.910 → 0.902 | 0.892 → **0.859** |

一个自然的假设：这不是四个独立缺陷，而是同一个根因 —— worker 跑在一个没有季节的世界里，
因为 season refresh 的结果进不去（capture 早于 `_sus.tick()`，而 season refresh 在其中）。

**这个假设是错的，已经用实验排除。** 试法是在 ACTIVE 下把 capture 挪到 `_sus.tick()` 之
后、回灌挪到 tick 之后，把执行序改成 `season refresh → capture → 回灌` —— 这确实是唯一
能让季节性重算进入 worker 的排法，而它的原始约束（「capture 必须早于同步图，因为 worker
要吃生产 pass_a 稍后读到的同一份输入」）在 ACTIVE 下本就不成立，生产 climate 被抑制门整段
关掉了。

结果是**零改善**：四条场逐项与挪动前一致（snow_cover 113~117、soil 914、VGP 909、moisture
0.902~0.913）。stage 接线确认未受影响（累计 `pass_a=149 weather=19 albedo=1 vegetation=2
feedback=1`，`applied=34`）。已全部回滚，包括 soak probe 里对应的 serial 时序。

**回头看，假设错在哪：** 这几条场在 ACTIVE 下根本不读 input。`snow_cover` / `snowpack` /
`accumulated_snow_days` 走 `own_snow_state`，ACTIVE 下由 worker 自持 —— 而这是对的，主线程
的 distribute 被抑制了，worker 是它们唯一的写者。所以它们平坦不是因为季节信号被挡住，是
因为 **worker 自己算出来的就是平的**。下一轮该查的是 worker 的温度/降水场为什么没有季节
振幅，而不是继续在数据通路上找缺口。

方法论上补一条到第 32 节那三条后面：**改动无效果时要回滚，不要因为「语义上更对」而保留。**
capture 挪到 season refresh 之后在语义上确实更合理，但既然它不改变任何指标，保留它就等于在
代码里留一个没有依据、且改变了原有设计约束的决策。

### 上游已定位到温度场，怀疑对象是 pass_a 的 season_phase（待实测确认）

把 `temp_arr` 加进 soak 对照（温度看极值而不是 nz/mean —— 全场 mean 随季节几乎不变，南北
半球互相抵消，振幅体现在两端）：

| | 六个采样点的 `temp` max |
| --- | --- |
| authority=1 | **0.91 / 0.91 / 0.91 / 0.91 / 0.91 / 0.91** |
| authority=0 | 0.95 / 0.97 / 1.00 / 1.00 / 0.98 / 0.94 |

worker 的温度上限完全冻结。温度是所有季节性的源头，下游那几条平坦是必然的，所以四条场不
需要分别查。

**证据链指向 `_round_in.scalars.season_phase`，但还没有实测确认：**

- pass_a 的日照 `insolation_now` 是它自己的**输出**而不是外部输入，算它用的是
  `in.scalars.season_phase` 与 `lat_norm`。所以日照通路本身没有问题。
- `kin.scalars.season_phase` 只在 `world_ext_climate.cpp` 的 `run_climate_pass_a` 里被填，
  紧接着 `record_production_pass_a_scalars(kin.scalars)`（同文件 452 / 487 行）。
- 而 ACTIVE 下生产的 climate pass 整段被抑制门关掉，那一行不再执行。
- worker 侧 `runtime_climate_kernel.cpp` 复制 round input 时（`_round_in = round_in`）只补了
  `water_terrain_ids` 一条，**没有补 scalars**。
- `snapshot.season_phase` 倒是每天都从 capture 新鲜传入（`world_ext_simulation_host.cpp:659`），
  但 pass_a 读的不是它。

如果成立，worker 就是一直按 `season_phase` 的默认值算温度，与 max 恒定完全吻合。scalars 里
其余二十几个字段是 ClimateProfile 常量、不随时间变，只有 `season_phase` 是时变量，所以修复
面很窄。

## 36. 根因确认并已修复：ACTIVE 下 round scalars 无人填充（2026-09-08）

上一节的怀疑成立，而且不需要运行时诊断就能静态确认：

- `fill_climate_round_input`（`world_ext_climate.cpp:6102`，capture 在 ACTIVE 下唯一的
  round input 来路）从头到尾只填 per-cell lane，**一个 scalar 都不填**。
- scalars 唯一的传递路径是 `publish.round_scalars`（`world_ext_simulation_host.cpp:1836`），
  那条是 SHADOW 的 reference publish —— 值由生产 `run_climate_pass_a` 里的
  `record_production_pass_a_scalars` 留存，而 ACTIVE 下生产 climate 整段被抑制门关掉。

于是 ACTIVE 下 `_round_in.scalars` 是默认构造的。~~其余二十几个 scalar 停在默认值无所谓~~
~~—— `ClimateRoundScalars` 的默认值就是 sync 路径在 `cp_struct` 缺字段时的 fallback~~，
`season_phase` 是里面唯一的时变量，`0.0` 不是「合理默认」而是**永远的春分**。

> **2026-09-08 更正：删除线那句是错的，代价是又一轮返工。** 见第 41 节。fallback 只在
> `cp_struct` **缺字段**时才生效，而字段并不缺 —— 生产每天都从 ClimateProfile 读真值填进去。
> 最贵的一条是 `insol_amp`：结构体默认 `0.20`，而 `ClimateProfile.season_temp_amp` 是 `0.32`，
> 于是 worker 的季节温度振幅只有生产的 62.5%。只补 `season_phase` 只修好了「日照会不会随
> 时间走」，没修「走多大幅度」。

修法是在 kernel 复制 round input 处补一行（`runtime_climate_kernel.cpp`，与原有那条
`water_terrain_ids` 补丁并列）：

```cpp
if (input.climate_worker_authoritative) {
    _round_in.scalars.season_phase = input.season_phase;
}
```

`input.season_phase` 是 capture 每天新鲜传入的，一直都在，只是 pass_a 读的不是它。

顺带把门控标志 `climate_own_paw` 改名为 `climate_worker_authoritative`：它现在门控两件不同
的事（scalars 补齐 + PAW 自派生），而两件事是同一类 —— 「生产被抑制后，凡是由生产 pass 顺带
记录再随 publish 交给 worker 的东西都会静默停更，worker 得自己补」。这与
`own_snow_state` / `own_field_state` 那套「跨天状态谁持有」是并列但不同的区分。

### 效果：`snow_cover` 的季节振幅回来了

| 字段 | 修复前 authority=1 | 修复后 authority=1 | authority=0 对照 |
| --- | --- | --- | --- |
| `snow_cover` nz | **恒 113** | 114 → **163** | 99 → 162 |
| `snow_cover` mean | **恒 0.035** | 0.033 → **0.047** | 0.030 → 0.058 |
| `temp` mean | — | 0.445 ~ 0.472 有波动 | 0.491 ~ 0.498 |

SHADOW parity 仍 **28/30**（与基线逐项一致），回归 **13 / 37 / 25 / 12 全绿**，150 天 soak
`drops=0`，八个日频 stage 满跑 148/148。门控确实把 SHADOW 隔离住了。

### 剩下的不是同一个 bug

`temp` max 仍恒 0.91（对照 0.94~1.00），但这已经是**量级**问题而不是振幅问题，与
`moisture` / WB30 偏高属同一类，怀疑在初始条件或 `base_moisture` 这条主线程输入上。

`vegetation_growth_pressure` 与 `soil_moisture` 活跃集合仍平坦，但原因已经清楚，**不是数据
通路**：150 天里 `feedback=1`、`vegetation=2`、`albedo=1`、`weather=19`。VGP 只由 feedback 与
vegetation 写，它取到几个值就是这两个 stage 跑了几次的直接结果。这是 stage 节拍问题（capture
侧的独立节拍计数器），要对齐的是生产节拍，不是补数据。

## 37. 排除掉的两条「缺陷」（2026-09-08）

**稀疏 stage 的节拍是对的。** `albedo` / `vegetation_dynamics` / `feedback` 三个 stage 都按
`call_index % stride` 走，stride 默认 10，而 `call_index` 数的是 **stage_b 调用次数**（即
weather 轮），不是天数。150 天有 19 个 weather 轮，于是 `albedo=1` / `vegetation=2` /
`feedback=1` 完全符合，与生产读的是同一份 stride。

顺带纠正第 34 节引用过的一条旧笔记：**`transpiration` 不写 `vegetation_growth_pressure`。**
VGP 只有两个写者（`runtime_climate_passes.cpp:2456` 的 feedback 段与 `:2690` 的
vegetation_dynamics 段），所以 worker 侧 150 天取到 3 个值 = 这两个 stage 一共跑了 3 次，是
正确行为而不是冻结。

**`soil_moisture` 活跃集合的差异倾向于 worker 更正确。** worker 恒 914（= 陆地格数），对照组
914 → 1845。多出的 900 多格是**水域格**，土壤湿度对它们没有物理意义。这与第 33 节已确认的
WB30 缺陷是同一个模式 —— distribute 对水域格无条件覆写 —— 而那次的正确值也正是 914。不作为
缺陷继续查。

## 38. ACTIVE 的性能数字（2026-09-08）

这是做整件事的初衷，之前一直没有测过。给 `headless_perf_record.gd` 加了
`climate_authority=on|off` 参数（必须在 `configure` 之前设：它决定 bind 时要不要 seed climate
store，也决定那 14 个主线程 climate 节点会不会被抑制门关掉，两者都发生在地图生成里）。

**`run_ms` 不能用作口径**：harness 每天有 40ms 的忙等轮询驱动回灌（`_process` 在
`SceneTree -s` 下不跑），50 天正好 2000ms，与实测差值完全吻合。真实客户端靠 `_process` 自然
消费，没有这段。口径要看 PerfRecorder 的 per-tick 列。

180x120（21600 格）、50 天、seed 20260718：

| 列 | OFF | ON | |
| --- | --- | --- | --- |
| `bd_climate_climate_ms` | 1.361 | **0.021** | 主线程 climate 计算，-98.5% |
| `j_native_daily_sim_ms` | 2.404 | **1.228** | climate job 整体，**-49%** |
| `bd_climate_bundle_dynamic_ms` | 2.004 | 0.363 | |
| `bd_climate_native_call_ms` | 1.372 | 0.412 | |
| `sus_sim_avg_300` | 6.023 | **6.082** | SUS 仿真总均值，**无改善** |

**抑制门确实生效，主线程 climate job 省了 1.18ms —— 但这 1.18ms 没有变成吞吐。** SUS 总均值
在噪声内不动，而 job 省下的量足够让它降到 4.8ms 才对。唯一说得通的解释是 worker 线程与主线程
抢 CPU：ACTIVE 下 worker 要在后台把 21600 格的整套 climate 物理跑完，`native_parallel_executor`
也在同时工作。

所以性能结论要分开说：

- **对帧延迟是真实收益**（主线程 climate job -49%），这对游戏体感有意义。
- **对 headless 总吞吐没有收益**，因为总 CPU 需求没变，只是换了个线程跑。
- `frame_wall_ms` 在 headless 下恒 0，**真正该看的那个指标测不出来** —— 必须在真实客户端会话
  里测。这条与下面那条「真实会话从未跑过」是同一件事的两面。

60x40（2400 格）那组更极端：`bd_climate_climate_ms` 0.233 → 0.004，但 `sus_sim_avg_300`
1.817 → 1.917（**+5.5%**，略负）。小地图上 climate 本来只占 0.27ms，capture 打包与回灌
memcpy 这些固定开销直接把它吃掉还倒亏。**ACTIVE 只在大地图上才可能有意义。**

另外大地图暴露了一个新问题：`writeback_days=30/50`（小地图是 49/50）。worker 在 21600 格上跟
不上一天的预算，40ms 窗口内有 20 天的回灌没落地。真实客户端的帧预算比这个窗口还紧。

## 39. 转 ACTIVE：生产默认已翻（2026-09-08）

`runtime_climate_authority_enabled` 的默认值从 `false` 改为 **`true`**。第 31 节那句「机制已
通，生产默认关」到此结束。

第 32 节列的两个前置缺口都已关掉，那节标题里的条件不再成立：

- **并行执行器的屏障竞态**（`0xC0000005`）已修 —— `run_group` 现在同时等
  `_remaining_tasks == 0` 与 `_active_workers == 0`，兑现了头文件里原本就写着的「A group
  owns stack-backed userdata until run_group returns」。
- **season refresh 与回灌的双写**已解决 —— 执行序在 `_on_clock_day_changed` 里钉成
  「回灌(第 N 天) → season refresh → capture(第 N+1 天输入)」，三者同一调用栈内串行，不再
  依赖节点树的 `_process` 顺序。season refresh 留在主线程是**设计而非妥协**：它是地理级
  重算，本就该由主线程持有。

翻默认值的影响面：**所有 climate 相关测试都显式设这个开关**（`climate_authority_test`=true，
`climate_parity_probe` / `runtime_climate_save_roundtrip_test`=false，两个 probe 走参数），只有
`headless_perf_record.gd` 跟随默认。它测的就是生产路径，所以让它跟随；要与转 ACTIVE 之前的
历史 CSV 对比，显式传 `climate_authority=off`。

新默认下的回归：**13 / 37 / 25 / 12 / 27 全绿**（authority、save roundtrip、daily graph order、
sea ice、canal），SHADOW parity 仍 **28/30**，默认路径实测
`enabled=true worker_authoritative=true writeback_days=19/20 mask=0x802`。

**运行时回退仍然可用且不需要重新生成世界**：`set_runtime_climate_authority_enabled(false)`
会停掉 ACTIVE worker 并以 SHADOW 重启，主线程立刻恢复算 climate。回灌一直把 worker 状态刷进
MapData，slot 与 MapData 在抑制期间保持同步，所以回退没有数据鸿沟。GM 面板的「Climate worker
权威」是同一个入口。

两条已知限制写进了开关的注释，因为它们会影响是否该开：小地图（≈2400 格）是负收益；大地图上
worker 可能跟不上一天的预算，落不下的那天保持 MapData 原值（是滞后，不是错值）。**按格数设
启用阈值这件事还没做。**

## 40. 经验积累：这轮 Climate 落地里反复起作用的几条（2026-09-08）

前面各节里散落记了若干条方法论，集中在这里。它们的共同点是**每一条都对应至少一次实际走错的
路**，不是事后总结的漂亮话。

**一、归因要靠对照实验，不要靠读代码。** 这条的代价最大。0xC0000005 的定位（第 32 节）：所有
静态推断都指向「双写」，方向全错，真正定位靠的是把 authority 关掉发现照样崩。冻结场那轮（第
33 节）三次归因里有两次是读代码推出来的错误结论，唯一可靠的证据都来自双向 soak 对照。

**二、改动没有效果就回滚，不要因为「语义上更对」而保留。** capture 挪到 season refresh 之后
（第 35 节）在语义上确实更合理 —— 它原本的约束在 ACTIVE 下本就不成立 —— 但它不改变任何指标。
保留它等于在代码里留一个没有依据、却改变了原有设计约束的决策。

**三、先拿到实测再改，不要跳过验证步骤。** 第 35 节那次回滚正是因为跳过了这一步：假设「季节
信号被 capture 时点挡住」听起来自洽，直接动手改了执行序，零改善。而下一节
（第 36 节）同一个问题改成先静态确认 `fill_climate_round_input` 到底填不填 scalars，一次就中。

**四、争用与冻结类问题要看全场分布，单点 trace 会骗人。** `PK_CLIMATE_TRACE_CELL=1200` 显示
PAW 四十天不动（第 33 节），看着像全场冻结，实际那是个水域格，`IS_WATER` 分支下 PAW 恒 0 是
正确行为。单个格子分不出「这个格子本来就该是这个值」和「全场都坏了」。

**五、「某个 stage 从不执行」不等于「它被漏接了」。** 先确认生产侧是否也不执行。hydrology 就
是这样：`runtime_hydrology_enabled=false` 时生产侧返回 `{}`，两侧都不跑，原本的 cancel 判断是
对的。同理「worker 有这条 lane」不等于「生产没有」，两边都要看代码，不要靠对称性推断。

**六、平坦的场先查上游，不要逐条修。** 四条场（snow_cover / VGP / soil / moisture）在 worker
侧全部平坦，看着像四个独立缺陷。加一列 `temp` 进对照就看清了：温度上限完全冻结，而温度是所有
季节性的源头，下游平坦是必然的。**顺带一条观测技巧**：温度要看极值而不是 nz/mean —— 全场 mean
随季节几乎不变（南北半球互相抵消），振幅只体现在两端。

**七、性能口径要先排除 harness 自身的开销。** `run_ms` 在 ACTIVE 下暴涨 3.5 倍（第 38 节），
差值完全来自 harness 每天 40ms 的忙等轮询（`SceneTree -s` 下 `_process` 不跑,回灌只能手动
驱动）。真实客户端没有这段。同一件事的另一面：`frame_wall_ms` 在 headless 下恒 0，所以这条
路径上**最该看的指标恰好测不出来**。

**八、"搬到后台线程"不等于"变快"。** 主线程 climate job 省了 49%，但 SUS 总均值不动 —— 总
CPU 需求没变，只是换了个线程跑，worker 与主线程抢核心。**要区分吞吐收益与延迟收益**，并且要
知道自己在测哪个。小地图上甚至是净负：固定的 capture 打包与回灌 memcpy 开销比被搬走的计算
还大。

**九、门控标志的名字要说它门控什么。** `climate_own_paw` 后来同时门控了 scalars 补齐，名字就
开始误导，改成了 `climate_worker_authoritative`。它和 `own_snow_state` / `own_field_state` 是
并列但不同的区分：后两者问「跨天状态谁持有」，它问「生产被抑制后，那些由生产 pass 顺带记录的
东西谁来补」。

Climate ACTIVE 现在的定位：**五个 stage 全部有权威写者，降水循环、土壤水、植物可用水逐日演
化，季节信号已进入温度场，生产默认已开**；剩下的是 synoptic 耦合、`temp` / `moisture` / WB30
相对对照组的量级偏差、按格数的启用阈值，以及大地图上 worker 跟不上节拍。**真实客户端会话
（视觉 / 存档 / 经济联动）仍然没有在 ACTIVE 下跑过**，而那既是唯一能测出帧延迟收益的地方，
也是历史上两个严重问题唯一暴露过的地方。

## 41. 客户端实跑暴露的两个残留缺陷（2026-09-08）

第 40 节最后那句「真实客户端会话仍然没有在 ACTIVE 下跑过」当天就被兑现了。玩家实跑后的报告：

> 开启 Worker 后温度没那么明显了，甚至观察不到日照导致的气温差异，雪线、海冰也没有变化。

三个症状指向同一个上游。`insolation_dev` 是 pass_a 直接从 `season_phase` + `lat_norm` 算的日照
偏差，温度是它的下游，雪线与海冰又是温度的下游。对比玩家的两份 tile 录制（ACTIVE 一份、
worker 关闭一份），同一 tick 内跨纬度的 min..max：

| | `insolation_dev` 逐 round |
| --- | --- |
| worker 关闭 | `-0.392..0.302` → `0.269` → `0.251` → `0.233` → `0.216`（每 round 推进） |
| ACTIVE | `-0.370..0.134`，**8 个 tick 一动不动** |

两个独立缺陷叠在一起：上界只有对照的 44%，而且完全冻结。

### 缺陷 A：scalars 缺的不止 `season_phase`

第 36 节只补了 `season_phase`，理由是「其余二十几个 scalar 的默认值就是 sync 路径的 fallback」。
**那个判断是错的**：fallback 只在 `cp_struct` 缺字段时生效，而字段并不缺 —— 生产每天都从
ClimateProfile 读真值。最贵的是 `insol_amp`（= `cp.season_temp_amp`）：结构体默认 `0.20`，
profile 实际 `0.32`，季节温度振幅只剩 62.5%。

诊断确认了两件事，一次实测同时给出：`round.before=0.000000`（第 36 节的根因判断成立）、
`insol_amp=0.2000`（第 36 节的「无所谓」判断不成立）。

修法不是继续逐字段补，而是把生产那份 cp_struct 整个接过边界。GDScript capture 侧新增
`climate_round_scalars`，直接复用生产 pass_a 用的同一个构建函数
（`_build_native_daily_climate_pass_a_struct`），C++ capture 侧逐字段填进
`snapshot.climate_round_input.scalars`。

两个设计约束：

- **逐字段填而不是整体替换**：`passes_mask` / `thermal_dt_days` 由 `fill_climate_round_input`
  与编排自己维护，整体覆盖会把 round 的启用位清掉。
- **SHADOW 不受影响**：那边 `overlay_production_round_scalars`（`runtime_climate_trace.h:199`）
  会按 mask 覆盖 capture 填的值，生产记录的真值仍然优先。实测 parity 仍 28/30、分叉日仍是
  day 7 / day 28，与基线逐项一致。

kernel 里第 36 节那行单字段补丁降级为兜底（只在 `season_phase` 恰好是 0 时生效），供不传
`climate_round_scalars` 的旧 harness 用。

### 缺陷 B：pass_a 的五条输出没有回灌写者

温度修好之后 `insolation_dev` **仍然**完全冻结 —— 这是第二个缺陷。`RuntimeClimateStore` 里
根本没有这几条字段，于是 worker 算完就丢，MapData 停在世界生成时的值。

这不影响 worker 内部的模拟正确性：round 内 pass_a→pass_b 的接力走 out 缓冲，不经 MapData
（`runtime_climate_passes.cpp:2844`）。坏的是**外部读者** —— 渲染、tile 录制、UI 面板读的都是
MapData，看到的是一张永远停在春分的日照图。这也解释了为什么 headless soak 一直没抓到它：
soak 看的是模拟量，而这五条是纯展示量。

与 `soil_moisture` 完全同一个模式（第 33 节），所以修法也一样：走 `RuntimeClimateSnapshot` 的
独立字段而不是 store 成员，**不进 PKEC 存档、不 bump schema**。顺手把 `soil_moisture` 那段
inline 代码重构成 `apply_extra` lambda，六条共用。

涉及 `insolation_now` / `insolation_dev` / `day_length` / `heat_input` / `temp_season_offset`。

### 验收

60 天同 seed A/B（`PK_SOAK_AUTHORITY=1` vs `0`）：

| 字段 | 修复前 ACTIVE | 修复后 ACTIVE | 对照 |
| --- | --- | --- | --- |
| `temp` max | 0.906 / 0.911 | **0.996 / 1.000** | 0.941 / 0.940 |
| `temp` mean | 0.458 / 0.472 | **0.508 / 0.520** | 0.487 / 0.482 |
| `insolation_dev` | **恒 `-0.476..0.630`** | `-0.456..0.630` → **`-0.408..0.474`** | `-0.464..0.630` → `-0.408..0.474` |
| `snow_cover` nz | 恒 113 | 127 → 124 | 91 → 103 |

`insolation_dev` 第二采样点与对照**逐位一致**。回归 **13 / 37 / 25 / 12 / 27 全绿**，SHADOW
parity 仍 **28/30**，soak `drops=0`、`writeback_days=58/60`。

`snow_cover` nz 仍比对照高约 25%，属于第 36 节留下的量级偏差那一类，未在这一轮处理。

### 方法论

**十、"默认值就是 fallback 所以无所谓"是一条需要实测的假设，不是推理。** 它成立的前提是
上游真的会缺字段。查一眼生产的构建函数（`map_generator.gd:4553`）就能否掉，代价是一整轮返工。

**十一、模拟量正确不代表展示量正确。** 缺陷 B 里 worker 内部算得完全对，soak 的所有指标都
正常，但玩家看到的是冻结的画面 —— 因为 round 内部接力不经 MapData，而渲染只读 MapData。
**凡是"生产某个 pass 顺手写进 MapData、但没有 store 成员"的场，在 ACTIVE 下都要单独清点一遍。**
已知同类：`soil_moisture`（第 33 节）、这五条。

**十二、玩家的定性描述可以直接翻译成可测指标。** 「观察不到日照导致的气温差异」→ 同一 tick 内
跨纬度的 `insolation_dev` min..max spread。两份录制来自不同世界、不同起始 tick，绝对值不可比，
但**同 tick 内的空间 spread 可比** —— 选对指标就能绕开无法复现种子的问题。


## 42. 代码丢失事故、重建，与海冰跨天累积缺陷（2026-09-08）

### 事故

清理第 41 节留下的旧 `climate_round_scalars` 解析块时，编辑脚本删错了范围，随后为了回到
干净状态执行了 `git checkout` —— 那些代码从未提交，`world_ext_simulation_host.cpp`
被回退到一个更早的版本，**1315 行未提交代码丢失**。`git fsck`、编辑器本地历史、Windows
卷影副本三条恢复路径全部无果。

唯一留下的资产是**已编译的 DLL 与 .obj**（丢失前那次构建的产物），以及 `world_ext.h`
里完整的函数声明、文档里记录的接线路径。

### 重建策略

按「链接器能不能发现缺失」分两批，这个顺序很关键：

1. **第一批 —— linker-visible 的 10 个函数。** 声明还在头文件里、GDScript 还在调，所以
   缺失会直接表现为链接失败或方法未绑定。照 `world_ext.h` 的签名重建，编译通过即证明
   边界完整：`append_climate_stage_cadence`、`climate_worker_authoritative`、
   `set_runtime_climate_parity_forcing`、`get_runtime_climate_parity_fields`、
   `get_runtime_climate_parity_divergence`、`compute_runtime_climate_parity_hash`、
   `publish_runtime_climate_reference_state`、`runtime_climate_writeback_self_test`、
   `runtime_climate_parity_contract_test`、`apply_runtime_climate_writeback`。
2. **第二批 —— `capture_runtime_inputs` 里的静默接线。** 这一批**编译器一句话都不会说**：
   少填一个 snapshot 字段只是让某个 stage 撞守卫静默跳过。只能靠 soak 的
   `stage-days` 与逐场 nz/mean 对着 SHADOW 基准反推缺什么。

重建过程中发现两个自身的坑，都由 soak 抓出：

- `neighbor_indices` 直接从 environment 快照赋给 static knobs 会崩：static knobs 的契约是
  定长 6N，而 environment 允许 CSR 形式（`neighbor_offsets` 非空时 indices 变长），内核按
  `i*6+k` 索引就越界。加了长度守卫，不匹配时清空。
- 回灌返回的键名写成了 `writeback_applied_fields`，GDScript 侧读的是 `applied_fields`，
  于是 soak 一直报 `applied=0` 而实际写了 38 个场。

### 缺陷：ACTIVE 下海冰每天从零冰起算

重建后 soak 显示 `sea_ice_frac` max **恒为 0.070**，而这个数正好等于
`si_daily_delta_cap`。对照（`PK_SOAK_AUTHORITY=0`）是 0.984。玩家看到的是海冰完全不显示。

根因是一条 lane 的**默认值恰好通过了所有守卫**：

```cpp
// _async_sea_ice_kernel_pure（runtime_climate_passes.cpp:1696）
const float *frac_in = ((int) in.sea_ice_frac.size() == n)
    ? in.sea_ice_frac.data() : in.sea_ice_frac_inout.data();
```

`sea_ice_frac` 是「生产 pass_b 消费点记录的那份」，SHADOW 下由生产填、ACTIVE 下抑制门后
没有写者。而 `fill_climate_round_input` 对缺键的处理是 `assign(n, 0.0f)` —— **长度恰好是
n，于是优先分支胜出，内核每天都拿一份全零起始冰量**，一个 delta cap 就是全部结果。

第一版修法用 `clear()` 走内核自带的退路，结果 `writeback_days` 从 28 掉到 **1**：这条
lane 同时是 `_async_ocean_water_kernel_pure` 的**必需** lane（`runtime_climate_passes.cpp:907`
硬校验 `size != n` 就 `return false`），清空会让整个 round 失败。正确修法是对齐到同一天的
slot 快照 `sea_ice_frac_inout` —— 这也正是内核注释描述的语义（ACTIVE 下 pass_b 与 sea_ice
读的就是同一个值）。

### `climate_stage_knobs` 五个 stage 补回

第二批的主体。GDScript 侧 `_build_runtime_climate_stage_knobs` 完好（丢的只有 C++ 解析），
字典是四个键：`weather_round` / `stage_b` / `stage_distribute` / `stage_weather`。

**键名的权威来源是生产的执行函数，不是结构体字段名。** GDScript 那几个 `*_for_worker`
builder 都是生产同一份 builder 的薄包装，所以生产 C++ 侧读同一份字典的地方就是映射表：

| stage | 生产执行函数（键名口径） | snapshot 成员 |
| --- | --- | --- |
| distribute | `run_weather_distribute_pass`（`world_ext_weather.cpp:1890`） | `climate_weather_distribute` |
| albedo | `run_albedo_pass`（`world_ext_climate.cpp:3530`） | `climate_albedo`（内联） |
| vegetation | `run_stage_b_pass` veg 段（`:4300`） | `climate_vegetation` |
| feedback | `run_stage_b_pass` fb 段（`:4564`） | `climate_feedback` |
| hydrology | 两侧都不跑（`runtime_hydrology_enabled=false`） | — |

三条实现约束：

- **守卫要求齐长的 lane 必须全填，即使内核不用它的值。** distribute 的 weather 四条会被
  worker 自己 store 覆盖（field solve 刚写过），但 12 条 lane 的长度校验是一次性的，少
  一条整个 stage 静默跳过。
- **`weather_field_init` 没有快照 lane**，worker 侧 field solve 总走 direct 语义（一定写 1），
  三处都填全 1 只为过守卫。
- **派生值在 capture 侧算好**：`day_scale` 的 `max(1.0)`、`stress_blend` 的
  `clamp(scale/memory_days,0,1)`，两侧各算一次会差 ULP。

### 验收

120 天 soak（50x48，同 seed A/B）：

| 字段 | 对照（authority=0） | 事故后 | 补回后 |
| --- | --- | --- | --- |
| `sea_ice_frac` max | 0.984 | 0.070 | **1.000** |
| `snow_cover` nz | 99 | 0 | **195** |
| `vegetation_growth_pressure` nz | 850 | 0 | **909** |
| `soil_moisture` nz | 914 | 537 | **914** |
| `water_balance_30d` nz | 914 | 542 | **914** |

`stage-days`：八个 round stage 满跑 118/118，`albedo=1` / `vegetation=2` / `feedback=1` /
`weather=15`（15 个 weather 轮 × 各自 stride），`drops=0`。

### 漏掉的第五个 stage：weather field solve

补回四个 stage 后 soak 全绿、回归全绿，但玩家仍报"湿度跳变"。原因是
`snapshot.climate_weather` **在整个文件里没有任何赋值点** —— 内核的 gate 是
`input.climate_weather != nullptr`（`runtime_climate_kernel.cpp:373`），所以 stage 11 的
前半段 weather field solve 在 ACTIVE 下一天都没跑过。它是 vapor / cloud_water / precip
这条降水循环的驱动，缺席时 moisture 只被 distribute 的 `moist_delta` 和 feedback 零散推
一下，表象正是跳变而不是连续演化。

**它为什么没被 soak 抓到**：stage 11 的 stage-day 计数与 distribute **共用同一个 bit**，
distribute 在跑，`weather=15` 就照常出现。`stage-days` 这个指标在这一段上无法区分两个
写者 —— 内核里那句 starved 诊断的注释早就写明了这点，我没读到。

接线本身是 55 个标量 + 9 个 ψ 演化参数 + 13 条必填 lane。三条实现要点：

- **键名与默认值的权威来源是 `run_weather_field_solve_pass`**（解析在
  `world_ext_weather.cpp:299` 起，收进 `wfk` 在 `:792` 起）。键名多数与 struct 字段同名，
  例外是 `omega_ascent_gain` ← `field_omega_ascent_gain`、五个 `syn_*` ←
  `weather_synoptic_*`。
- **clamp 必须照抄，不只是默认值。** `field_precip_spatial_smooth` 上限 0.8、
  `snow_classification_margin` 上限 0.12、`field_precip_inertia` 下限 0.05 等等。
  ClimateProfile 给越界值时，只有 clamp 能让两侧落在同一个数上，而少一次 clamp 不会有
  任何人报错。
- **`weather_synoptic_enabled` 的生产默认是 `true`**（不是 false）。

顺带修掉一个隐患：weather 与 feedback 的守卫都读 static knobs 的 `neighbor_indices`，而
那份在 environment 走 CSR 形式时会被长度守卫清空（第 42 节前面那次崩溃的修法）。
`stage_weather` 字典里带着一份生产校验过的定长 6N，缺失时从它补上。

**验收**（60 天、同 seed、A/B）：

| 字段 | 对照（authority=0） | 接线后 |
| --- | --- | --- |
| `moisture` mean | 0.88955 | 0.89961 |
| `snow_cover` nz / mean | 115 / 0.03611 | 116 / 0.03840 |
| `plant_available_water` mean | 0.29282 | 0.29957 |
| `temp` mean / max | 0.498 / 0.975 | 0.505 / 1.000 |
| `insolation_dev` | mean 0.011 / [-0.408, 0.474] | **逐位一致** |
| `sea_ice_frac` nz / max | 447 / 1.000 | 472 / 1.000 |

`weather=7`（60 天 ÷ 8 天一轮），无 starved，`drops=0`，SHADOW 仍 28/30。

**残留**：`vegetation_growth_pressure` 的均值符号与对照相反（+0.113 vs −0.011）。两个写者
（feedback / vegetation）现在都在跑，量级偏差归入 `moisture-magnitude` 那条一起查。
ψ / cyclone / monsoon 仍留空 —— 它们的推进输入是风场，而 worker 的 wind pass 在 round 里
比 weather 晚，自己推一份只会把风场的分叉搬到 ψ 上（待办 `synoptic-own`）。代价是降水少了
移动涡旋这条主驱动，`syn_base_lift` 默认 1.55 是当前配置里最强的一项。

### 第三批：跨边界的键名与类型

第一批（linker-visible）与第二批（capture 静默接线）之外还有第三类缺口：**函数存在、编译通过、
ACTIVE 路径全绿，但 GDScript 侧读不到它要的键**。它只在 SHADOW 上暴露，因为只有 SHADOW 会
穿过 GDScript↔C++ 的 parity 边界往回读值。

表象是 `climate_parity_probe` 报 `only_0_of_30_days_compared ... climate_trace_reference_pending`
—— 一天都没比上。三处独立的键名/类型错误串在同一条链上：

| 位置 | 重建给的 | GDScript 读的 | 后果 |
| --- | --- | --- | --- |
| `get_runtime_climate_parity_fields` | `comparability`/`kind`/`tolerance` = 枚举序号 | `String(entry.get("comparability"))` | **抛异常**，打断字段收集 |
| `publish_runtime_climate_reference_state` | `state_hash` | `parity_hash` | 取到 0 → 整天作废 |
| `runtime_climate_parity_contract_test` | `field_count`/`comparable_count` | `fields_total`/`fields_comparable` | 表长读成 0 → 9 项契约断言连坐 |

第一条最隐蔽：**Godot 4 的 `String()` 构造不接受 int**（`String(5)` 抛 "Nonexistent 'String'
constructor"），而给序号在 C++ 侧完全合法。GDScript 那行报错只是一句 SCRIPT ERROR，我一度把它
当成无关噪声 —— 它其实就是 0/30 的根因。修法是三条枚举一律跨边界发字符串
（`pk_parity_kind_name` / `..._comparability_name` / `..._tolerance_name`）。

同时修掉一处重建时自己引入的宽松语义：`build_climate_store_from_fields` 原本对缺席的
comparable 字段 `continue`（留在 reset 后的零值上）。契约测试对这条有明确要求且理由充分 ——
把缺席数组当零值哈希照样能出一个数，而两侧零的位置不同，日后会以「Climate 算法分叉」的形式
浮出来。改成整份拒绝 + `missing_fields`，`cell_count` 也不再从数组长度推断（推断值一旦不对，
逐条 size 检查会把每条字段都报成长度错，掩盖真正缺失的那一条）。

修完七项回归全绿：authority 13/0、parity contract **159/0**、SHADOW **28/30**（与事故前逐位
一致）、save roundtrip 37/0、daily graph 25、sea ice 12/0、canal 27/0。probe 的墙钟从 700s
降到 75s —— 之前那 11 分钟全耗在失败重试直到 tick 预算耗尽。

### 方法论

**十三、未提交的工作没有"干净状态"可回退。** `git checkout` 的语义是「丢弃未提交的改动」，
在有大量未提交工作时它不是撤销键。**编辑脚本删错范围之后的正确动作是先 commit（哪怕是
WIP），再修。**

**十四、按「编译器会不会告诉你」给重建排序。** linker-visible 的部分让编译成为验收条件，
一次就能确认边界完整；静默接线只能靠行为差分反推，把它放在后面才有一个已知可用的基线去对。

**十五、"缺省值恰好合法"是这套接线里最危险的一类缺陷。** 海冰这条 lane 缺席时被填成等长
全零数组：所有 `size == n` 守卫全过、不报 starve、round `ok=1`，只有物理结果不对。同类模式
已出现三次（`wind_baseline` 侥幸退回 LUT、`sea_ice_frac`、第 36 节的 scalars 默认值）。
**判据是"这条 lane 在 ACTIVE 下还有写者吗"，不是"它长度对不对"。**

**十六、修一条 lane 之前先查它还有几个读者。** `sea_ice_frac` 的第一版修法只考虑了 sea_ice
内核，没查 ocean_water 也硬依赖它，结果把整个 round 弄失败了 —— 而 soak 的表象是
`writeback_days` 掉到 1，与"海冰不涨"完全不像同一个改动引起的。

**十七、重建一个跨语言绑定时，键名的权威来源是调用方，不是结构体。** 十四条把重建按"编译器会
不会告诉你"分了两批，第三批是它们之外的：**函数签名对、编译过、ACTIVE 全绿，但字典键名对不上**。
Dictionary 是无类型边界，两侧各写一个名字不会有任何人报错。重建任何返回 Dictionary 的绑定，
第一步应该是 grep GDScript 侧对返回值的 `.get("...")`，把那份键集当作契约。

**十八、GDScript 的 SCRIPT ERROR 不是噪声。** `Invalid call. Nonexistent 'String' constructor`
在 soak 日志里出现过多次，我因为 soak 结果正常而当成无关噪声跳过了 —— 它是 SHADOW 对拍
0/30 的直接根因。ACTIVE 与 SHADOW 走的是不同代码路径，**一条路径全绿不能替另一条路径背书**。

**二十、共用一个计数 bit 的两个 stage，那个计数就不能用来证明其中之一跑了。** stage 11 的
`weather` 与 `distribute` 共用一个 bit，`weather=15` 一直照常出现，而 field solve 其实一天都
没跑过。**接线的验收判据必须是该 stage 独占的输出场，不是它参与的计数。**

**十九、"墙钟变长"本身是一条诊断信号。** parity probe 从 75 秒变成 700 秒，因为它在
`tick_budget = days * 4 + 16` 里一直重试一个永不成功的比较。用时反常时先看它是不是在重试，
比读结果更快定位。
