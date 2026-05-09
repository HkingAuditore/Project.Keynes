# 需求文档 — Sliced Update Scheduler（全局切片更新调度器）

## 引言

### 问题陈述

经过 `fast-tick-perf-optimization`（A+C+D+E）与 `systemic-ocean-currents` 的 F1+F3 两轮优化后，x20 加速档下的 Season refresh 已从 1676ms 降至：

- **普通季**：525ms（无洋流烘焙）
- **年首**：1605ms（含一次洋流烘焙 1013ms）
- **整体平均**：795ms（-52%）

但仍存在三类**结构性**问题，单独再做一次性局部优化收益已边际递减：

1. **年首单帧 1605ms 卡顿** — `rebake_ocean_currents` 占 1013ms，是当前最痛的单点。
2. **设计哲学冲突** — 洋流烘焙使用离散季节相位（4 个硬切相位），而项目核心理念是"自然涌现"：季节、气候、洋流应作为连续场基于太阳辐射、风场、温度自然演化，而非硬编码切换点。
3. **多趟全图遍历散点累积** — `refresh_seasonal` 内有 7~8 趟 `for cell in map.all_cells()` 子 pass（rain_shadow / terrain 决策 / river_ecology / vegetation_feedback / shrubland_pass / mangrove_pass / glacier_pass / swamp_pass / current_state 写入 / consume_feedback / refresh_climate_daily），`refresh_climate_daily` 内 Pass A/B 又各一趟，每个 cell 上的常数级开销被遍历次数放大。

更深层的问题：**现有节流字段是散点式的**。`ClimateProfile.weather_refresh_stride`（A 方案）、`ocean_current_refresh_seasons`（F1）、`world_clock.day_phase_emit_step`（D 方案）、`daily_climate_refresh_stride`（既有）四套机制各自为政，没有统一的"何时跑、跑多少、跑哪些"调度策略，难以横向比较、难以新增系统时复用。

### 目标

引入一个**全局切片更新调度器（Sliced Update Scheduler，简称 SUS）**，作为项目所有"周期性模拟工作"的统一执行入口。所有现有的逐日 / 季首 / 年首 pass 都注册为 SUS 的 **Job**，由 SUS 决定它在哪一 tick 跑、跑多少切片、是否积攒变化量到阈值再跑。

**核心承诺**：

- 短期：完成方向 ①（年首切片化）+ 方向 ③（洋流并入逐日连续涌现）+ 方向 ②（普通季多趟全图遍历合并）三件事，平均 Season refresh ≤ 200ms、年首单帧 ≤ 200ms、x20 平均帧时 ≤ 16.6ms。
- 中期：所有现有 stride 字段（`weather_refresh_stride` / `ocean_current_refresh_seasons` / `daily_climate_refresh_stride`）废弃为 SUS 的 Job 配置，**形成单一真值源**。
- 长期：未来新增任何模拟系统（生态扩散、城市影响、瘟疫传播…）只需注册为 SUS Job，性能预算自动纳入统一管理。

### 显式排除

- 本轮**不**引入多线程 / WorkerThreadPool（GDScript 在 Godot 4.x 的线程开销与本项目地图规模收益不匹配，且会引入热路径数据竞争风险）。所有切片仍在主线程执行，仅"切片化时序分摊"。
- 本轮**不**改变任何模拟的物理含义、数值平衡、视觉效果。SUS 只是把现有 pass 的执行时序从"在 X 事件里一次性跑完"改成"在 SUS 里按预算分摊跑"，**模拟结果在年级时间尺度上等价**（允许日级时间尺度上的 ≤ 1 日相位偏移作为切片化的合理代价）。
- 本轮**不**做 GPU 计算迁移（compute shader / RenderingDevice）。`_bake_ocean_currents` 的 GDScript 噪声循环虽是真正瓶颈，但迁 GPU 是独立大议题，由后续计划承接。

---

## 需求

### 需求 1（核心抽象）— SUS Job 与调度器

**用户故事**：作为开发者，我希望项目内所有周期性模拟工作有一个统一的注册、调度、计量入口，以便横向比较其性能开销、统一调整其执行频率，并在新增系统时不需要重新发明节流机制。

#### 验收标准

1. WHEN 系统启动 THEN 项目 SHALL 提供一个 `SlicedUpdateScheduler`（SUS）单例（或挂在 `MapGenerator` 下作为子模块），暴露以下核心接口：
   - `register_job(job: SusJob) -> void`
   - `tick(context: SusTickContext) -> void`（由外层 day_changed / season_changed / year_changed / 每帧任一驱动调用）
   - `report_last_tick() -> Dictionary`（返回上一轮 tick 内每个 Job 的耗时、是否被跳过、跳过原因）
2. WHEN 定义 `SusJob` 抽象 THEN 该类 SHALL 包含以下字段与回调：
   - `id: StringName`（Job 唯一标识，例如 `&"refresh_climate_daily"`、`&"rebake_ocean_currents"`）
   - `policy: SusPolicy`（节流策略，见需求 2）
   - `slice_budget_ms: float`（默认 4.0，单切片预算）
   - `priority: int`（同 tick 内多 Job 排序，越小越先跑）
   - `func should_run(ctx: SusTickContext) -> bool`（policy 决策入口，由 SUS 调用）
   - `func run_slice(ctx: SusTickContext) -> SusSliceResult`（跑一个切片，返回 `{ done: bool, work_done: int, elapsed_ms: float }`）
   - `func reset_progress() -> void`（外部可强制复位切片进度，例如地图重新生成时）
3. WHEN SUS.tick() 被调用 THEN 它 SHALL 按 priority 顺序依次询问每个 Job 的 should_run；若 true 则在当前 tick 内调用 run_slice 直至 done 或预算耗尽。
4. WHEN 某 Job 在当前 tick 切片未完成（done=false）THEN SUS SHALL 在 Job 内部保留进度游标，下一次 should_run=true 的 tick 接着推进，**不**重启 from scratch。
5. WHEN 一个 tick 内总耗时超过 `frame_budget_ms`（默认 12.0）THEN SUS SHALL 停止启动新 Job、把剩余 Job 推迟到下一 tick（已启动的当前切片不被打断，避免半成品状态）。
6. WHEN report_last_tick() 被调用 THEN 返回的 Dictionary SHALL 至少包含每个 Job 的：`id`、`elapsed_ms`、`slices_run`、`progress_ratio`（0~1）、`skipped_reason: String`（"" 表示未跳过）。

---

### 需求 2（策略层）— SusPolicy 三种节流模式

**用户故事**：作为开发者，我希望调度策略以策略对象的形式装配在 Job 上，使得"每 N tick 跑一次"、"累积变化量阈值触发"、"切片化分摊跑完"这三种常见节流模式可以混搭使用，避免每个 Job 重写节流代码。

#### 验收标准

1. WHEN 实现 `SusPolicy` 抽象基类 THEN 它 SHALL 暴露 `should_run(job: SusJob, ctx: SusTickContext) -> bool` 单一方法，由 SUS 调用决定本 tick 是否启动该 Job。
2. WHEN 实现 `StridePolicy(stride: int, phase: int = 0)` 子类 THEN 它 SHALL 表示"每 stride 个 tick 跑一次"，且当 `(ctx.tick_index + phase) % stride == 0` 时返回 true。例如 `weather_refresh_stride` 在 x20 档为 4 即对应 `StridePolicy(4)`。
3. WHEN 实现 `AccumulatorPolicy(threshold: float, getter: Callable)` 子类 THEN 它 SHALL 表示"累积变化量达到阈值才跑"，调用 getter() 取当前累积值，达到 threshold 时返回 true 并清零累积器。例如"温度场偏离 ≥ 0.05 才重烘 biome_tex"。
4. WHEN 实现 `ContinuousSlicedPolicy(period_ticks: int, slice_count: int)` 子类 THEN 它 SHALL 表示"在 period_ticks 个 tick 内分 slice_count 次切片跑完一遍"，配合 Job 内部进度游标实现连续切片。例如"洋流烘焙在 30 天内分 10 次切片，每 3 天跑 10% 像素"。
5. WHEN 多个 Policy 需要组合 THEN 系统 SHALL 提供 `AndPolicy(a, b)` / `OrPolicy(a, b)` 组合子（最小可用即可，不强求完整代数）。
6. IF 调度策略不写自定义子类 THEN 提供一个 `AlwaysPolicy()` 默认值（每 tick 都跑，等价于无节流），保证最小注册成本。

---

### 需求 3（接入点 ①）— 年首洋流烘焙切片化（解决 1605ms 卡顿）

**用户故事**：作为玩家，我希望年首季节切换不再产生 1.6 秒的肉眼可感卡顿，以便长期挂机加速运行无感知中断。

#### 验收标准

1. WHEN 现有 `_baker.rebake_ocean_currents` 与 `_baker._bake_ocean_upwelling` 被改造 THEN 它们 SHALL 支持"按像素索引区间执行"接口，即新增 `bake_ocean_currents_slice(map, world, hex_size, cfg, season_phase, start_idx, end_idx) -> void` 与对应 upwelling 切片接口。
2. WHEN 注册 `OceanCurrentsJob` 到 SUS THEN 该 Job SHALL 使用 `ContinuousSlicedPolicy(period_ticks=N, slice_count=M)`，period_ticks 取决于接入点 ③（连续涌现）的设计，slice_count 取决于实测每片预算（目标单切片 ≤ 4ms）。
3. WHEN 切片进行中 THEN OceanCurrentsJob SHALL 写入"双缓冲"：切片完成前不替换 `world_data.ocean_currents_tex`、不调用 `_compute_ocean_currents` 回填 per-cell；切片全部完成后再原子替换。
4. IF 切片进行中地图被重新生成（regenerate）或玩家按下重置 THEN SUS SHALL 调用所有 Job 的 reset_progress()，且 OceanCurrentsJob SHALL 丢弃双缓冲内的半成品数据。
5. WHEN 切片化生效 THEN 控制台 `Season refresh` 打点的年首峰值 SHALL ≤ 200ms（含 SUS 当前 tick 启动的其他 Job 的总和）。
6. WHEN 切片化生效 THEN 视觉上 SHALL 不产生洋流可见的"半旧半新"撕裂条纹（双缓冲保证）。

---

### 需求 4（接入点 ③）— 洋流并入逐日连续涌现（设计哲学修正）

**用户故事**：作为设计师，我希望洋流场不再是"季节切换"事件的从属物，而是基于风场、温度、地形持续逐日涌现的连续场，以与项目"自然涌现"核心理念对齐。

#### 验收标准

1. WHEN 路线生效 THEN OceanCurrentsJob SHALL 由 `_on_day_changed` 触发的 SUS.tick() 驱动，**不再**依赖 `_on_season_changed`。
2. WHEN 每日 tick 推进 THEN OceanCurrentsJob 内部 SHALL 使用 `world_clock.season_phase()`（0..4 连续浮点，已存在）作为洋流场计算的 phase 输入，**不再**使用整数季节相位 0.5/1.5/2.5/3.5。
3. WHEN `ContinuousSlicedPolicy(period_ticks=N, slice_count=M)` 配置 THEN 推荐初值 `period_ticks=30`（约一个月一轮全量更新）、`slice_count=10`（每 3 天烘 10% 像素），具体数值由实测调优决定。
4. WHEN 洋流烘焙采用连续 phase THEN 其结果 SHALL 与原 4 个离散相位在年级时间尺度（365 天均值）上等价（允许逐日浮点差异，但不允许出现哪一天突然"季节跳变"的洋流方向反转）。
5. WHEN 接入点 ③ 完成 THEN `ClimateProfile.ocean_current_refresh_seasons` 字段 SHALL 标注为 deprecated，逻辑上不再生效（保留字段以兼容旧资源文件，加载时打印 warning），改由 SUS Job 配置（在 ClimateProfile 中新增 `ocean_currents_period_ticks: int = 30`、`ocean_currents_slice_count: int = 10`）。
6. WHEN `_on_season_changed` 仍触发 THEN 它 SHALL NOT 再调用 `_baker.rebake_ocean_currents`（该工作完全交给 SUS 逐日推进）。

---

### 需求 5（接入点 ②）— 普通季多趟全图遍历合并

**用户故事**：作为开发者，我希望普通季 525ms 的多趟全图遍历被压缩到 ≤ 200ms，以便整体 Season refresh 平均 ≤ 200ms。

#### 验收标准

1. WHEN 重构 `refresh_seasonal` THEN 现有的 7~8 趟 `for cell in map.all_cells()` SHALL 被合并为最多 2 趟：
   - **趟 1（决策趟）**：moisture 重置 + rain_shadow + terrain 重决策 + river_ecology + vegetation_feedback + shrubland/mangrove/glacier/swamp pass，所有"读现状、写新 terrain"的工作合并到这一趟内的"决策子函数"链。
   - **趟 2（写入趟）**：current_state 写入 + push_biome_history + push_vegetation_history + consume_feedback_buffers，所有"派生快照、累积衰减"的工作合并到这一趟。
2. WHEN 合并完成 THEN 决策子函数 SHALL 保持顺序敏感语义不变（vegetation_feedback 必须在 terrain 重决策之后、shrubland_pass 必须在 vegetation_feedback 之后、swamp_pass 必须在反馈之后…），且每子函数的输入输出语义与合并前**逐 cell 等价**。
3. WHEN `refresh_climate_daily` 末尾的 `refresh_climate_daily(map, season)` 调用（季节切换"刚发生的同一帧用连续 phase 修正 current_state"）SHALL 被移除（合并到趟 2），避免重复全图遍历。
4. WHEN 接入点 ② 完成 THEN 普通季 Season refresh 打点 SHALL ≤ 250ms（基线 525ms，目标 -50%）。
5. WHEN 接入点 ② 完成 THEN 同 seed 跑 365 日的 cell 状态快照 SHALL 与重构前**逐字段一致**（终态等价；允许中间帧顺序差异）。

---

### 需求 6（接入点 ④）— 现有 stride 字段收编为 SUS Job 配置

**用户故事**：作为开发者，我希望现有四套散点式节流字段统一收编到 SUS 框架下，以便单一真值源、便于横向调优。

#### 验收标准

1. WHEN `weather_refresh_stride`（A 方案）SHALL 被改造为 `WeatherRefreshJob` 的 `StridePolicy` 配置，由 `MapGenerator.refresh_daily` 内的天气推进+反馈链注册为该 Job。
2. WHEN `daily_climate_refresh_stride`（既有）SHALL 被改造为 `RefreshClimateDailyJob` 的 `StridePolicy` 配置。
3. WHEN `world_clock.day_phase_emit_step`（D 方案）SHALL **保持原样**（它是信号节流，不是模拟工作；与 SUS 的 Job 模型语义不同），但需在 SUS 文档与 `perf-report.md` 中明确说明这一边界。
4. WHEN 收编完成 THEN `ClimateProfile` 中相关字段 SHALL 标注为 deprecated 或迁移到新的 `sus_jobs: Array[SusJobConfig]` 资源数组（具体形式由实施阶段定）。
5. WHEN 收编完成 THEN x1 / x5 / x20 三档下的实际节流行为 SHALL 与现有完全一致（行为等价，仅落地方式变化）。

---

### 需求 7（横切）— 性能验收门槛

**用户故事**：作为玩家，我希望切片调度器引入后游戏不出现帧率回归且达成既定性能目标，以便对优化效果有可量化的判断。

#### 验收标准

1. WHEN 在 256×256 地图、x20 加速、所有耦合开启的配置下运行 THEN 平均帧时 SHALL ≤ 16.6ms（60fps），单帧峰值 ≤ 33ms（30fps 不丢帧底线）。
2. WHEN x5 档位运行 THEN 平均帧时 SHALL ≤ 12ms。
3. WHEN x1 档位运行 THEN 平均帧时 SHALL 与现有偏差 ≤ ±5%（无回归）。
4. WHEN 验证 SHALL 通过现有 console 打点 + Godot Profiler 双源采集，记录到 `perf-report.md`（与 `fast-tick-perf-optimization/perf-report.md` 同风格）。
5. WHEN 接入点 ①+③+② 全部完成 THEN Season refresh 打点 SHALL：年首 ≤ 200ms、普通季 ≤ 250ms、平均 ≤ 220ms。
6. WHEN SUS 日志开启 THEN 控制台 SHALL 每 N（默认 30）个 tick 打印一次 `[SUS] last 30 ticks: <job_id> avg=Xms p95=Yms slices=Z` 的统计行，便于实时观察。

---

### 需求 8（横切）— 不破坏存档、不破坏视觉、不改设计语义

**用户故事**：作为玩家，我希望切片调度器引入后旧存档仍可加载、视觉无回归、模拟结果在年级时间尺度上等价，以便不影响既有进度。

#### 验收标准

1. WHEN 旧存档加载 THEN 系统 SHALL 检测到 ClimateProfile 中已废弃字段并迁移到新的 SUS Job 配置（带 print warning 一次）。
2. WHEN 模拟运行 THEN 视觉上 SHALL NOT 出现：洋流烘焙过程中的撕裂条纹、季节切换时的 biome 闪烁、切片中途选中地块面板读到不一致字段。
3. WHEN 365 日同 seed 运行 THEN cell.terrain / cell.vegetation 的年首快照 SHALL 与重构前一致（允许逐日相位 ≤ 1 日偏移作为切片化代价）。
4. WHEN SUS 出现异常（某 Job run_slice 抛异常）THEN SUS SHALL 在控制台打印错误、跳过该 Job 当前 tick、继续后续 Job，**不**让单个 Job 错误污染整个游戏循环。
5. IF 玩家在切片中途暂停游戏 THEN SUS SHALL 暂停所有 Job 的进度推进；恢复后从暂停时的进度游标继续，**不**回滚已完成切片。

---

## 边界情况与风险

### 风险 A — 双缓冲内存翻倍

OceanCurrentsJob 的双缓冲在切片期间需要保留两份 ocean_currents_tex（旧的供 shader 读、新的供 SUS 写）。地图大小 256×256 × RGB16F ≈ 384KB × 2 = 768KB，可接受。但 upwelling buffer 同样要双缓冲，需在实施时明确量级。

### 风险 B — 切片粒度与玩家可见性

`ContinuousSlicedPolicy(period_ticks=30, slice_count=10)` 意味着洋流场每天逐渐演变 1/10，理论上玩家在 zoom-in 慢慢观察时**可能**看到"某一行像素更新了、紧邻一行还是旧的"的视觉接缝。需在实施阶段验证：是否需要按"洋流方向连续区块"切片（按 lat 带切）而非纯像素索引切片。

### 风险 C — Job 间数据依赖

某些 Job 互相依赖（例如 RefreshClimateDailyJob 写完温度后 WeatherRefreshJob 才能读）。SUS priority 字段要保证依赖顺序正确；若依赖跨 tick（A Job 切片未完成 B Job 已经跑了）会产生"读到半新数据"。需在 SusJob 抽象中预留 `depends_on: Array[StringName]` 字段，由 SUS 校验：被依赖 Job 未完成切片时，依赖方推迟到下一 tick。

### 风险 D — 框架本身的开销

为节流而引入的调度框架本身不能成为新瓶颈。SUS.tick() 的调度开销（每 Job 一次 should_run + 优先级排序）在 10 个 Job 量级下应 ≤ 0.1ms。验收时要单独打点确认。

### 风险 E — 现有打点格式兼容

`fast tick #N: Xms`、`refresh_climate_daily #N: Xms`、`Season refresh Xms`、`Yearly refresh Xms` 这些打点是已有 perf-report 的对照基线。SUS 接入后这些打点的语义会变化（现在是"包了多个 SUS Job 的总和时间"），需在文档中明确说明，并新增 SUS 自己的细粒度打点。

### 风险 F — 与 fastpath skill 工作流的耦合

项目内已有 `.codebuddy/plan/fast-tick-perf-optimization/`、`.codebuddy/plan/systemic-ocean-currents/`、`.codebuddy/plan/emergent-climate-coupling/` 三套并行计划。SUS 计划落地后，前三个计划中已实施的 stride 字段会被部分接管，需要在实施任务清单中明确"哪些字段保留、哪些迁移、哪些废弃"，避免遗留双轨制。

---

## 实施顺序约束

**强制约束**：必须按 ① → ③ → ② 的顺序实施。理由：

- 接入点 ① 建立 SUS 框架 + 切片化基础设施，是后续所有工作的依赖
- 接入点 ③ 在 ① 的切片设施上把"季节硬切"改为"逐日连续"，是设计哲学层面的修正，需要 ① 的双缓冲机制兜底
- 接入点 ② 是相对独立的 refactor，但应在 ①③ 稳定后做，避免并发改动 refresh_seasonal 引入定位困难的回归

接入点 ④（现有 stride 字段收编）作为收尾工作，在 ①③② 全部稳定后统一迁移。

