# 实施计划

- [ ] 1. 在 `ClimateProfile` 增加配置开关与连续化所需常量
   - 在 [climate_profile.gd](d:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes\scripts\data\climate_profile.gd) 新增 `@export var daily_climate_interpolation: bool = true`，作为可一键回退的总开关
   - 新增 `@export var daily_climate_refresh_stride: int = 1`（每 N 日刷新一次，性能保险）
   - 必要时显式暴露 `season_temp_amp`（默认 0.20）以便与 shader 端硬编码值统一来源
   - 同步更新 [_registry_self_check.gd](d:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes\scripts\data\_registry_self_check.gd) 自检逻辑，确保新字段不会让旧 profile 加载失败
   - _需求：7.3、8.1、6.2_

- [ ] 2. 抽取 `_season_temp_offset` 为接受连续 phase 的版本
   - 在 [map_generator.gd](d:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes\scripts\map_generator.gd) 新增 `_season_temp_offset_phase(ny: float, season_phase: float) -> float`，公式与 shader `season_temp_offset` 完全对齐（半球反相 + `cos((phase-1)·π/2)·amp`）
   - 现有 `_season_temp_offset(ny, season:int)` 改为内部调用 `_season_temp_offset_phase(ny, float(season) + 0.5)`，保持旧调用点（`refresh_seasonal`、`_apply_sea_ice_pass` 等）行为不变
   - _需求：1.1、1.4、6.1、6.2_

- [ ] 3. 抽取 `seasonal_moisture_scale` 的连续插值辅助函数
   - 在 [map_generator.gd](d:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes\scripts\map_generator.gd) 新增 `_moisture_scale_at_phase(season_phase: float) -> float`
   - 实现：用 `floor(phase)` 作为当前季、`(floor(phase)+1) % 4` 作为下一季，按 `frac(phase)` 线性插值 `seasonal_moisture_scale`
   - _需求：2.1_

- [ ] 4. 实现核心日级刷新函数 `refresh_climate_daily`
   - 在 [map_generator.gd](d:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes\scripts\map_generator.gd) 新增 `refresh_climate_daily(map: MapData, season_phase: float) -> void`
   - 流程（仅写 `current_state`，不动 `cell.terrain` / `cell.moisture` / `base_*`）：
     1. 守卫：`_last_cfg == null` 或开关关闭直接 return（需求 8.2）
     2. 读取连续 `moist_scale_now`（任务 3）
     3. 遍历所有 cell：陆地用 `base_moisture × moist_scale_now`、水体保 `base_moisture`，写入 `current_state.moisture`
     4. 用 `_season_temp_offset_phase` 计算 `temperature_now`，写入 `current_state.temperature`
     5. 按需求 3.1 的双段公式重算 `snow_cover` 写入 `current_state.snow_cover`；永久 SNOW 仍为 1.0、GLACIER cover 维持原上限（需求 3.3）
   - 严禁调用 `_decide_terrain` / 植被反馈 / 雨影 / `_baker.rebake_*`（需求 4.1、7.2）
   - _需求：1.1、1.2、1.3、2.1、2.4、3.1、3.2、3.3、4.1、7.1、7.2、8.2_

- [ ] 5. 在 `main.gd::_on_day_changed` 接入日级刷新
   - 在 [main.gd](d:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes\scripts\main.gd) 的 `_on_day_changed` 中，在调用 `refresh_daily`（天气子系统）**之前**先调用 `_generator.refresh_climate_daily(_current_map, _world_clock.season_phase())`
   - 让天气扰动叠加在最新的连续基线上，保证 `current_state.temperature/moisture` 既连续又含天气扰动
   - 通过 `daily_climate_refresh_stride` 实现"每 N 日跳过"的降级路径（用 `_world_clock.day_index() % stride == 0` 判断）
   - _需求：1.1、2.2、5.3、7.3、7.4_

- [ ] 6. 新增 `_refresh_climate_line` 并接入面板逐日刷新
   - 在 [main.gd](d:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes\scripts\main.gd) 仿照 `_refresh_weather_line` 新增 `_refresh_climate_line()`，只更新温度行 / 湿度行 / 当季降水行
   - 当季降水行使用任务 3 的 `_moisture_scale_at_phase(season_phase)` 取连续倍率（需求 5.2），不再用整数 season 取整季常量
   - 在 `_on_day_changed` 末尾，若 `_selected_cell != null` 则调用 `_refresh_climate_line()`（与 `_refresh_weather_line/_refresh_vitality_line` 并列）
   - 同步更新 `_refresh_info_panel` 中相同的三行计算逻辑，保证整面板刷新时也用连续值（避免两条路径不一致）
   - _需求：5.1、5.2、5.3_

- [ ] 7. 让 `refresh_seasonal` 在季节切换后立即同步一次连续基线
   - 在 [map_generator.gd](d:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes\scripts\map_generator.gd) `refresh_seasonal` 末尾（写完 `current_state` 之后）追加一次 `refresh_climate_daily(map, season_phase)` 调用
   - 目的：season_changed 一般在某日清晨触发，此时 phase 刚跨过整数，需立刻把 `current_state` 从"季中段值"修正为"季首相位值"，保证需求 1.3 的"换季那一天与前一日差值最小"
   - 旧整数计算路径仅在 `daily_climate_interpolation == false` 时保留作为回退（需求 8.1）
   - _需求：1.3、4.2、8.1_

- [ ] 8. 处理旧存档与首次启动的字段缺失情况
   - 在 [map_generator.gd](d:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes\scripts\map_generator.gd) `refresh_climate_daily` 起始处检测 `cell.current_state` 是否为空 dict，若是则按"全字段写入"路径补齐 `season/biome/landform/vegetation/cover` 等键，避免下游消费者读到空字典
   - 在地图生成完成（generator 初始化结束）后立即调用一次 `refresh_climate_daily`，让玩家进入第一帧就看到当日连续值，而不是默认 0
   - _需求：8.3_

- [ ] 9. 性能与一致性手动验证（脚本内打印 + 面板观察）
   - 在 `refresh_climate_daily` 内用 `Time.get_ticks_msec()` 打点，确认单次耗时 ≤ `refresh_seasonal` 的 1/4（需求 7.1）
   - 在调试面板增加临时日志：随便选一个中纬度地块，连续推进 10 日打印 `temperature/moisture/snow_cover`，肉眼确认数值单调连续，且换季当天差值不大于其它日（需求 1.2、1.3、3.2）
   - 验证开关：`daily_climate_interpolation = false` 时退回旧硬切行为；开关 true 时面板逐日变化（需求 8.1）
   - _需求：1.2、1.3、3.2、7.1、8.1_
