# 实施计划 — Fast Tick 加速运行性能优化

> 任务排序原则：风险从低到高、改动面从小到大递进。先做 D（纯 WorldClock 节流，孤立）→ A（外层 stride 包壳，不动内部公式）→ C（HexCell 字段重构，扩散面最大）→ E（renderer 细粒度上传）→ 性能基线对照与文档落地。

---

- [ ] 1. **建立性能基线** — 在改动前采集 x1 / x5 / x20 三档基线
  - 启动游戏 256×256 地图，依次切到三档运行 ≥ 30 秒，记录 console 打点：`fast tick`、`refresh_climate_daily`、`Season refresh`、`Yearly refresh` 的均值/p95
  - 同时用 Godot Profiler 采一份"加速运行 10 秒"快照
  - 把结果写入新建文件 `.codebuddy/plan/fast-tick-perf-optimization/perf-report.md` 的 "Baseline" 一节
  - 不写代码；仅产出基线数据，作为后续每个任务完成后的对照锚点
  - _需求：6.1、6.2、6.3、6.4_

- [ ] 2. **方案 D — `world_clock` 增加速度变更信号与 phase 节流自动调档**
  - 在 `world_clock.gd` 顶部新增 `signal speed_changed(new_speed: float)`；`set_speed(s)` 末尾在 `_speed != s` 时 emit
  - 新增 `@export var season_phase_emit_step: float = 0.0` 与 `_last_emit_season_phase: float = -1.0` 哨兵；`_process` 中 `season_phase_changed` 的发射逻辑参照 `day_phase` 增加节流
  - 新增内部成员 `_user_overridden_phase_step: bool`，`_ready` 末尾若初始 `day_phase_emit_step != 0.0` 或 `season_phase_emit_step != 0.0` 则置 true
  - 新增 `_apply_phase_step_for_speed(s: float)`：仅当 `_user_overridden_phase_step == false` 时按 x1→0/0、x5→0.005/0.002、x20→0.02/0.01 写入两个字段，并把 `_last_emit_day_phase` / `_last_emit_season_phase` 重置为 -1.0
  - `set_speed(s)` 内部在 emit 信号前先调用 `_apply_phase_step_for_speed(s)`；`_ready` 末尾按当前 speed 调一次（保证启动即生效）
  - 自测：x1 档保持每帧 emit、x20 档观察 TOD 色温过渡平滑无阶梯感
  - _需求：3.1、3.2、3.3、3.4、3.5_

- [ ] 3. **方案 A — `ClimateProfile` 加 `weather_refresh_stride` 字段并暴露 setter**
  - 在 `ClimateProfile`（resource）中新增 `@export_range(1, 8, 1) var weather_refresh_stride: int = 1`
  - 在 `MapGenerator` 中新增 `set_weather_refresh_stride(s: int)`：clamp 到 [1,8] 后写入 `_climate_profile.weather_refresh_stride`，并 print 一次 `[fastpath] weather_refresh_stride = N`
  - 缓存 `var _last_active_fronts: Array = []` 用于 stride 跳日时返回快照
  - 不改 `refresh_daily` 内部逻辑（下个任务再改）
  - _需求：1.1、1.4_

- [ ] 4. **方案 A — `refresh_daily` 入口 stride 节流，跳日复用 fronts 快照**
  - 在 `refresh_daily` 入口取 `var stride := max(1, _climate_profile.weather_refresh_stride)`
  - 计算 `var should_tick := (world_clock.day_index() % stride) == 0`
  - **跳日分支**（`should_tick == false`）：
    - 直接 `return _last_active_fronts`（保持外部接口签名不变）
    - 不调用 `_apply_transpiration_pass` / `_apply_albedo_pass` / `_apply_vegetation_dynamics` / `_apply_weather_to_map_feedback_pass`
    - 不调用 `_baker.rebake_*`
    - 跳过 fast tick 的 `> 12ms budget` 警告判断（用 bool 标志透传到 fast tick 打点处）
  - **正常分支**（`should_tick == true`）：执行原逻辑，结束时把当次活跃 fronts 存入 `_last_active_fronts`
  - 在 `main.gd` 订阅 `world_clock.speed_changed`，回调里按 x1→1、x5→2、x20→4 调用 `MapGenerator.set_weather_refresh_stride(s)`；`_ready` 末尾按当前 speed 也调一次
  - 跳日时 UI 选中地块面板的 weather/vitality/climate/emergent 行不强制刷新（在 main.gd UI 刷新入口加 `if was_skipped_day: return` 早返）
  - _需求：1.1、1.2、1.3、1.4、1.5、1.6、5.2_

- [ ] 5. **方案 C — `HexCell` 提升高频字段为强类型成员（含旧存档迁移）**
  - 在 `HexCell` 顶部新增普通 var：`temperature: float = 0.0`、`moisture: float = 0.0`、`snow_cover: float = 0.0`、`temp_baseline: float = 0.0`、`temp_season_offset: float = 0.0`、`temp_30d_mean: float = 0.0`、`temp_365d_mean: float = 0.0`、`temp_dev_from_annual: float = 0.0`
  - 新增私有方法 `_migrate_typed_fields_from_dict()`：检查 `current_state` 是否仍带有这些键（`"temperature"`、`"moisture"`、`"snow_cover"`、`"_temp_baseline"`、`"_temp_season_offset"`、`"temp_30d_mean"`、`"temp_365d_mean"`、`"temp_dev_from_annual"`），若有则一次性搬到强类型成员、再 `erase` 字典键
  - 在 `HexCell` 反序列化入口（如 `from_dict` / `_init_from_save`，或被 `MapData.load` 调用的位置）末尾调用 `_migrate_typed_fields_from_dict()`
  - 保留 `temperature_breakdown` 字典不动（冷路径，仅选中 cell 时填充）
  - 不改任何外部消费者（下个任务统一改读写路径）
  - _需求：2.1、2.4、2.7_

- [ ] 6. **方案 C — 全链路改读写：`map_generator.gd` / `weather_system.gd` / `_baker` / `main.gd` UI**
  - 在 `MapGenerator.refresh_climate_daily` 的 Pass A / Pass B 中：把 `cell.current_state["temperature"] = ...` 改成 `cell.temperature = ...`；其余 5 个迁移字段同样改写
  - 把 Pass A/B 中读旧值的 `cell.current_state.get("temperature", 0.0)` 改成 `cell.temperature`，其余字段同理
  - 在 `weather_system.gd` 中查找所有 `cell.current_state.get("temperature"` / `.get("moisture"` / `.get("snow_cover"` 的位置（grep `current_state.get\("(temperature|moisture|snow_cover|_temp_baseline|_temp_season_offset|temp_30d_mean|temp_365d_mean|temp_dev_from_annual)"` 全量盘点），改成强类型成员读取
  - 在 `_baker.gd`（或同名的 GPU 烘焙模块）中同样改读路径
  - 在 `main.gd` UI 行刷新（选中地块的 weather/vitality/climate/emergent 行）改读路径
  - 移除 `current_state` 中对这些字段的所有写入（确保不留双写）
  - 在 `MapGenerator._ready` 末尾或 `refresh_climate_daily` 首次入口 print 一次 `[fastpath] HexCell typed fields active`
  - 同 seed、x1 档运行 365 日做快照对比验证（与任务 1 基线对照，浮点误差 ≤ 1e-4）
  - _需求：2.2、2.3、2.5、2.6、5.3、5.4_

- [ ] 7. **方案 E — `HexRenderer` 新增三个细粒度纹理上传方法**
  - 新增 `set_biome_tex_only(world_data)`：仅 `_material.set_shader_parameter("biome_tex", world_data.biome_tex)`，不重建材质、不重算 `world_bounds`、不动 geometry
  - 新增 `set_cover_tex_only(world_data)`：仅替换 `cover_tex` uniform
  - 新增 `set_vegetation_tex_only(world_data)`：仅替换 `vegetation_tex` uniform
  - 三个方法都加 null 守卫（_material / world_data / 对应 tex 任一为 null 即 return）
  - `set_map(map, world_data)` 完全保持原行为不动（regenerate 路径仍走它）
  - _需求：4.1、4.3、4.4_

- [ ] 8. **方案 E — `main.gd._on_season_changed` 改用细粒度上传**
  - `_on_season_changed` 中把 `_renderer.set_map(_current_map, _world_data)` 替换为：
    - 必调用 `_renderer.set_biome_tex_only(_world_data)`
    - 若 `refresh_seasonal` 内部确实改写了 cover_tex / vegetation_tex，按需追加 `set_cover_tex_only` / `set_vegetation_tex_only`
  - 保留现有 `Season refresh %dms` 打点格式不变
  - 自测：x20 档季节切换时 `Season refresh` 打点应明显下降（目标 < 3ms），且无肉眼可见的色块抖动
  - _需求：4.2、4.5、5.1_

- [ ] 9. **回归验证 — 同 seed × 三档全链路对拍**
  - 用与任务 1 相同的 seed，x1 档跑 365 日，对 `MapData` 做字段级快照对比（重点比较 `temperature` / `moisture` / `snow_cover` / `temp_30d_mean` / `temp_365d_mean` / `vegetation` / `biome`），允许浮点误差 ≤ 1e-4
  - x5 / x20 档分别跑 365 日，确认长期均值与气候耦合方向（如冬季降温幅度、夏季升温幅度）与 x1 档一致；允许 stride 引发的平台稳态差异
  - 验证启动日志包含 `[fastpath] HexCell typed fields active` 与 `[fastpath] weather_refresh_stride = N`
  - 在 `perf-report.md` 追加 "Regression Diff" 一节记录上述对比
  - _需求：2.6、5.3、5.4_

- [ ] 10. **性能验收与 `perf-report.md` 收尾**
  - 与任务 1 基线对照，分别采集三档优化后的 `fast tick` / `refresh_climate_daily` / `Season refresh` 打点均值/p95 与 Godot Profiler 帧时
  - 在 `perf-report.md` 写入 "Final" 一节：x20 平均帧时 ≤ 22ms、x5 ≤ 16.6ms、x1 偏差 ≤ ±5%，并对每条结论给出打点截图或数值表
  - 主观评估并记录：x20 档跳日的 fronts 视觉断帧是否可察觉、季节切换抖动是否消除
  - 列出已知副作用（EMA 在 stride > 1 时收敛略慢、跳日的 UI 行不刷新）
  - _需求：5.1、6.1、6.2、6.3、6.4_

---

## 实施顺序与回滚锚点

| 顺序 | 任务 | 改动面 | 回滚成本 |
|---|---|---|---|
| 1 | 任务 1 | 0（采集） | 无 |
| 2 | 任务 2 | `world_clock.gd` 单文件 | 极低 |
| 3 | 任务 3-4 | `ClimateProfile` + `MapGenerator` + `main.gd` | 低（stride=1 即等价原行为） |
| 4 | 任务 5-6 | `HexCell` + 4 个调用方文件 | 中（扩散面大，需任务 9 守门） |
| 5 | 任务 7-8 | `HexRenderer` + `main.gd` | 低（新方法旁路，老方法保留） |
| 6 | 任务 9-10 | 文档与验收 | 无 |
