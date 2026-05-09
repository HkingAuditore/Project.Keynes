# 实施计划 — Sliced Update Scheduler（全局切片更新调度器）

> 任务排序遵循需求文档"实施顺序约束"：① 建框架 → ③ 改设计 → ② 做合并 → ④ 收编旧字段 → 收尾验收。
> 每完成一个接入点都要落一次基线对照到 `perf-report.md`，避免回归无源可溯。

---

- [ ] 1. **建立性能基线 + 创建 SUS 模块骨架目录**
  - 启动游戏 256×256 地图，依次切到 x1 / x5 / x20 三档运行 ≥ 30 秒，记录 console 打点：`refresh_climate_daily`、`Season refresh`（区分年首与普通季）、`Yearly refresh`、`rebake_ocean_currents` 的均值/p95
  - 同时用 Godot Profiler 采一份"加速运行 10 秒"快照
  - 把结果写入新建文件 `.codebuddy/plan/sliced-update-scheduler/perf-report.md` 的 "Baseline" 一节
  - 在 `Project/project-keynes/scripts/` 下创建 `simulation/sus/` 子目录（约定为 SUS 模块根目录），新增空文件 `sus_scheduler.gd`、`sus_job.gd`、`sus_policy.gd`、`sus_tick_context.gd`
  - 不写实质逻辑；仅产出基线数据 + 占位骨架，作为后续每个任务完成后的对照锚点
  - _需求：1.1、7.4_

- [ ] 2. **实现 SUS 核心抽象（Job / Policy / Scheduler / TickContext）**
  - `sus_tick_context.gd`：`class_name SusTickContext`，含 `tick_index: int`、`day_index: int`、`season_phase: float`、`speed_scale: float`、`source: StringName`（"day_changed" / "season_changed" / "year_changed" / "frame"）
  - `sus_policy.gd`：`class_name SusPolicy`，定义虚方法 `func should_run(job, ctx) -> bool: return true`；同文件下定义 `AlwaysPolicy` / `StridePolicy(stride, phase)` / `AccumulatorPolicy(threshold, getter)` / `ContinuousSlicedPolicy(period_ticks, slice_count)` / `AndPolicy(a,b)` / `OrPolicy(a,b)`
  - `sus_job.gd`：`class_name SusJob`，含字段 `id: StringName`、`policy: SusPolicy`、`slice_budget_ms: float = 4.0`、`priority: int = 100`、`depends_on: Array[StringName] = []`、`_progress: float = 0.0`；定义虚方法 `should_run(ctx) -> bool`（默认转发给 policy）、`run_slice(ctx) -> Dictionary`（返回 `{ done: bool, work_done: int, elapsed_ms: float }`）、`reset_progress() -> void`
  - `sus_scheduler.gd`：`class_name SlicedUpdateScheduler extends Node`，含 `_jobs: Array[SusJob]`、`_last_report: Dictionary`、`@export var frame_budget_ms: float = 12.0`；实现 `register_job(job)`、`tick(ctx)`（按 priority 排序、依赖校验、try/catch run_slice、累积耗时停止启动新 Job）、`reset_all_progress()`、`report_last_tick() -> Dictionary`、`set_log_interval(n: int)`（默认 30 tick 打一行 `[SUS] last 30 ticks: ...`）
  - 单元自测：在 `MapGenerator._ready` 末尾临时注册一个 `AlwaysPolicy` 的 noop Job（run_slice 立刻 done=true）、在 `_on_day_changed` 调一次 `_sus.tick(ctx)`，确认日志正确打点
  - _需求：1.1、1.2、1.3、1.4、1.5、1.6、2.1、2.2、2.3、2.4、2.5、2.6、8.4_

- [ ] 3. **接入点 ① · 改造 `map_baker` 暴露切片烘焙接口**
  - 在 `map_baker.gd` 中：
    - 抽出 `_bake_ocean_currents` 的核心循环为 `_bake_ocean_currents_pixel_range(map, world, hex_size, cfg, season_phase, start_idx, end_idx, out_image: Image)`，所有像素索引从 `[start_idx, end_idx)` 区间计算，写入传入的 out_image（不直接覆盖 world.ocean_currents_tex）
    - 新增 `bake_ocean_currents_slice(map, world, hex_size, cfg, season_phase, start_idx, end_idx) -> Dictionary`：内部维护 `_pending_currents_image: Image`（双缓冲），首次切片创建/拷贝，后续切片继续写入；返回 `{ image_size, pixels_done }`
    - 新增 `commit_ocean_currents_buffer(world)`：把 `_pending_currents_image` 转成 ImageTexture 原子替换 `world.ocean_currents_tex`，调用现有 `_compute_ocean_currents` 回填 per-cell，清空 pending 缓冲
    - 同样为 `_bake_ocean_upwelling` 抽出 `bake_ocean_upwelling_slice` / `commit_ocean_upwelling_buffer`
    - 新增 `discard_ocean_buffers()`：丢弃所有 pending 缓冲（地图重生成时调用）
  - 保持原 `rebake_ocean_currents` / `rebake_ocean_upwelling` 接口不动（regenerate 路径仍走它们一次性烘完）
  - _需求：3.1、3.3、3.4、3.6_

- [ ] 4. **接入点 ① + ③ · 实现 `OceanCurrentsJob` 并注册到 SUS（每日 tick 驱动）**
  - 新增 `simulation/sus/jobs/ocean_currents_job.gd`：`class_name OceanCurrentsJob extends SusJob`
    - 持有 `_baker`、`_map`、`_world_data`、`_climate_profile`、`_world_clock` 引用
    - `id = &"ocean_currents"`、`priority = 200`（晚于 `refresh_climate_daily`）
    - 内部进度游标 `_next_pixel_idx: int`、`_total_pixels: int`、`_phase_locked: float`（切片开始时锁住 season_phase，避免本轮中途 phase 漂移）
    - `run_slice(ctx)`：根据 policy 算出本切片像素配额（`_total_pixels / slice_count`），调用 `_baker.bake_ocean_currents_slice(...)` + `bake_ocean_upwelling_slice(...)`，推进 `_next_pixel_idx`；当达到 `_total_pixels` 时调用两个 `commit_*_buffer`、reset 进度、`done=true`
    - `reset_progress()`：清零游标、调用 `_baker.discard_ocean_buffers()`
    - 计算 phase 时使用 `_world_clock.season_phase()`（连续浮点），**不再**使用 0.5/1.5/2.5/3.5 离散值
  - 在 `MapGenerator._ready`（或 `MapGenerator.set_world_clock` 等已有初始化路径末尾）创建 SUS 实例 + 注册 `OceanCurrentsJob`，policy 用 `ContinuousSlicedPolicy(period_ticks=30, slice_count=10)`（值从新增的 `ClimateProfile.ocean_currents_period_ticks` / `ocean_currents_slice_count` 读取，默认 30/10）
  - 在 `main.gd._on_day_changed` 末尾调用 `_generator.sus_tick_daily(ctx)`（MapGenerator 暴露的薄包装），驱动 SUS 推进
  - 在 `main.gd._on_season_changed` 中**移除**对 `_baker.rebake_ocean_currents` / `rebake_ocean_upwelling` 的调用（regenerate 路径除外）
  - 在 `ClimateProfile` 中新增 `@export var ocean_currents_period_ticks: int = 30`、`@export var ocean_currents_slice_count: int = 10`；保留 `ocean_current_refresh_seasons` 但加注释 `# DEPRECATED: 已被 SUS OceanCurrentsJob 接管`
  - 在 `MapGenerator` 加载 ClimateProfile 时若检测到 `ocean_current_refresh_seasons != 0` 打印一次 warning：`[SUS] ocean_current_refresh_seasons is deprecated, ignored.`
  - 自测：x20 档跑 90 日，控制台应看到 `[SUS]` 打点显示 OceanCurrentsJob 平均切片时间 ≤ 4ms；年首 Season refresh 应 ≤ 200ms
  - _需求：3.1、3.2、3.3、3.5、3.6、4.1、4.2、4.3、4.4、4.5、4.6、8.1、8.2_

- [ ] 5. **接入点 ① 守门 · 双缓冲视觉验收 + regenerate 路径保护**
  - 在 `main.gd` 的 `[R] regenerate` 处理（grep `regenerate` 找到入口）末尾增加 `_generator.sus_reset_all()` 调用 → SUS.reset_all_progress() → 各 Job 包括 OceanCurrentsJob 调用自身 reset_progress、丢弃 pending 缓冲
  - x20 档跑 365 日肉眼观察：洋流可视化（如有 debug 视图）应**无**撕裂条纹，每 30 日 phase 推进 1 步对应连续平滑过渡
  - 同 seed 跑 365 日采集 ocean_currents_tex 的最终快照（导出为 PNG 或抽样像素 mean/std），与基线对比应在年级时间尺度上等价（允许像素级 ≤ 5% 偏差，因为离散→连续 phase 不可能逐像素一致）
  - 在 `perf-report.md` 追加 "After Phase ①+③" 一节：年首单帧、x20 平均帧时、SUS Job 切片打点
  - _需求：3.4、3.5、3.6、4.4、7.5、8.2、8.3_

- [ ] 6. **接入点 ② · `refresh_seasonal` 多趟全图遍历合并到 2 趟**
  - 在 `map_generator.gd` 中盘点 `refresh_seasonal` 内所有 `for cell in map.all_cells()` 与 `for cell in map.cells.values()` 循环（grep 后逐一列出）
  - **趟 1（决策趟）**：在 refresh_seasonal 内整合为单个循环，依次调用静态化的决策子函数（保持原顺序敏感语义不变）：
    - `_seasonal_reset_moisture(cell, ctx)`
    - `_seasonal_apply_rain_shadow(cell, ctx)`
    - `_seasonal_redecide_terrain(cell, ctx)`
    - `_seasonal_river_ecology(cell, ctx)`
    - `_seasonal_vegetation_feedback(cell, ctx)`
    - `_seasonal_shrubland_pass(cell, ctx)` / `_seasonal_mangrove_pass(cell, ctx)` / `_seasonal_glacier_pass(cell, ctx)` / `_seasonal_swamp_pass(cell, ctx)`
  - **趟 2（写入趟）**：第二个循环依次调用：
    - `_seasonal_writeback_current_state(cell, ctx)`
    - `_seasonal_push_history(cell, ctx)`（biome + vegetation history 合并）
    - `_seasonal_consume_feedback(cell, ctx)`
  - 移除 refresh_seasonal 末尾的 `refresh_climate_daily(map, season)` 调用（其工作合并入趟 2 的 writeback）
  - 决策子函数的纯化：每个子函数只读 cell 现状 + ctx（季节 / climate_profile / world_data），写 cell 临时字段；不再触发跨 cell 的副作用（如有，必须显式标注为"需要在主循环外预计算"并提到趟 1 之前）
  - _需求：5.1、5.2、5.3_

- [ ] 7. **接入点 ② 验证 · 同 seed 365 日逐字段快照对比**
  - 用与任务 1 相同的 seed，x1 档跑 365 日，对 `MapData.cells` 做字段级快照对比：`temperature` / `moisture` / `vegetation` / `biome` / `landform` / `terrain_type`，允许浮点误差 ≤ 1e-4
  - 任何不一致项必须在合并的决策子函数中找出顺序敏感的副作用补回（典型是 vegetation_feedback 与 shrubland_pass 之间的 vegetation 字段读写顺序）
  - 在 `perf-report.md` 追加 "After Phase ②" 一节：普通季 Season refresh 打点、x1/x5/x20 三档平均帧时
  - 验收：普通季 Season refresh ≤ 250ms；与重构前快照逐字段一致
  - _需求：5.4、5.5、7.5、8.3_

- [ ] 8. **接入点 ④ · 收编 `weather_refresh_stride` / `daily_climate_refresh_stride`**
  - 新增 `simulation/sus/jobs/weather_refresh_job.gd`：包装 `MapGenerator.refresh_daily` 内的天气推进+反馈链；policy 用 `StridePolicy(stride)`，stride 从 `ClimateProfile.weather_refresh_stride` 读取（速度变更时通过 `MapGenerator.set_weather_refresh_stride` 写入并 emit Job 重建 policy）
  - 新增 `simulation/sus/jobs/refresh_climate_daily_job.gd`：包装 `refresh_climate_daily`；policy 用 `StridePolicy(daily_climate_refresh_stride)`
  - 在 `MapGenerator._ready` 末尾把这两个 Job 注册到 SUS，priority 分别为 100（refresh_climate_daily 最先）、150（weather_refresh 次之）、200（ocean_currents 最后）
  - `main.gd._on_day_changed` 改为只调用 `_generator.sus_tick_daily(ctx)`，移除直接调用 `refresh_daily` / `refresh_climate_daily`（这些工作完全交给 SUS 调度）
  - `ClimateProfile.weather_refresh_stride` / `daily_climate_refresh_stride` 字段保留并加注释 `# Used by SUS StridePolicy`，**不**改字段名（避免存档破坏）
  - 自测：三档下行为应与既有完全一致（同 seed 365 日快照逐字段一致）
  - _需求：6.1、6.2、6.3、6.4、6.5、8.1_

- [ ] 9. **回归验证 · 三档全链路对拍 + 异常路径测试**
  - 与任务 1 基线对照，x1 / x5 / x20 三档分别跑 365 日：
    - x1：MapData 逐字段一致（浮点误差 ≤ 1e-4）
    - x5/x20：长期均值与气候耦合方向一致，允许 stride/切片化引发的 ≤ 1 日相位偏移
  - 异常路径测试：
    - 切片中途按 R regenerate：SUS 调用 reset_all_progress、各 Job pending 缓冲清空，新地图正常烘焙不串味
    - 切片中途暂停游戏（speed=0）→ 恢复：SUS 进度游标无回滚、无重复推进
    - 故意在 OceanCurrentsJob.run_slice 抛 `push_error`：SUS 应捕获并跳过本 Job 当前 tick，其他 Job 不受影响
  - 在 `perf-report.md` 追加 "Regression Diff" 一节记录上述对比
  - _需求：3.4、5.5、7.5、8.2、8.3、8.4、8.5_

- [ ] 10. **性能验收与 `perf-report.md` 收尾**
  - 与任务 1 基线对照，分别采集三档优化后的 `Season refresh`（年首/普通季）、`refresh_climate_daily`、`Yearly refresh`、`[SUS]` 行打点的均值/p95 与 Godot Profiler 帧时
  - 在 `perf-report.md` 写入 "Final" 一节，验收：
    - x20 平均帧时 ≤ 16.6ms、单帧峰值 ≤ 33ms
    - x5 平均帧时 ≤ 12ms
    - x1 偏差 ≤ ±5%
    - Season refresh：年首 ≤ 200ms、普通季 ≤ 250ms、平均 ≤ 220ms
    - SUS 调度自身开销 ≤ 0.1ms / tick
  - 主观评估并记录：年首切片化的视觉接缝是否可察觉、普通季合并后的玩家可见行为是否一致
  - 列出已知副作用（洋流连续 phase 与原离散 phase 的像素级偏差、stride > 1 时 EMA 收敛略慢）
  - 列出 fastpath 三套旧计划的字段去向：哪些保留、哪些 deprecated、哪些迁移
  - _需求：7.1、7.2、7.3、7.4、7.5、7.6、8.1_

---

## 实施顺序与回滚锚点

| 顺序 | 任务 | 改动面 | 回滚成本 |
|---|---|---|---|
| 1 | 任务 1 | 0（采集 + 空文件） | 无 |
| 2 | 任务 2 | SUS 4 个新文件 | 极低（旁路） |
| 3 | 任务 3 | `map_baker.gd` 单文件 | 低（旧接口保留） |
| 4 | 任务 4 | `map_generator.gd` + `main.gd` + `climate_profile.gd` + 1 新 Job | 中（移除 season 路径的 ocean rebake） |
| 5 | 任务 5 | regenerate 路径 + 文档 | 极低 |
| 6 | 任务 6-7 | `map_generator.gd` 大改 refresh_seasonal | 高（需任务 7 守门） |
| 7 | 任务 8 | 新 2 个 Job + main.gd 调度入口 | 中（行为等价但调用路径变） |
| 8 | 任务 9-10 | 文档与验收 | 无 |
