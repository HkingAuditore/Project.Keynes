extends RefCounted
class_name DCWeatherFieldSolver

## Phase E.1 / dots-full-migration §Phase E.1：weather field solver 抽出。
##
## **当前状态**：迁移规格 + facade 接口已定义；实际函数体仍在
## [`weather_system.gd`](./weather_system.gd) 待按下方"逐函数搬迁清单"
## 移过来。本类目前作为 facade 把 `weather_system` 实例的 field-solver 部分
## 调用包装成稳定 API，让 E.3 weather_system.gd 残留收尾、F.1 C++ 化都能
## 锚定本类的入口而不是直接钩住 weather_system 内部。
##
## ─── 逐函数搬迁清单（按依赖顺序，每个函数独立 PR）──────────────────────
##
## 主求解入口（最大、最复杂）：
##   - `_solve_weather_field(map, world, season_idx, anomaly)`  — line 849-1170 (~320 行)
##     主求解：vapor / cloud / precip / instability 三段式，含 advect + condensation +
##     orographic lift + convergence + decay + EMA。这是 weather_field_solve 的真正
##     hot loop body。
##
## 切片基础设施（field_slice 状态机）：
##   - `commit_weather_field_solve()`                           — line 743-848 (~100 行)
##   - `begin_weather_refresh_stage_a(...)` / `run_weather_refresh_stage_a_slice(...)`
##     等切片入口（在 weather_system 中分散；search "_field_slice_" 找出全部 ~20 字段）
##
## 邻居 / 风向 helper（hot loop 内层调用）：
##   - `_neighbor_aligned(cell, map, dir) -> HexCell`           — line 1448
##   - `_neighbor_aligned_idx(idx, dir, cell_pos, neighbor_indices)` — line 1235 (cached 版本)
##   - `_upstream_vapor(cell, map, prev_vapor, wind_dir)`        — line 1171
##   - `_upstream_vapor_cached(cell, map, prev_vapor, wind_dir)` — line 1208
##   - `_upstream_vapor_idx(idx, cell_pos, neighbor_indices, prev_vapor, wind_dir)` — line 1254
##   - `_upstream_vapor_idx_from_first(...)`                    — line 1271
##   - `_neighbor_average_vapor(cell, map, prev_vapor)`         — line 1192
##   - `_neighbor_average_vapor_cached(...)`                    — line 1225
##   - `_neighbor_average_vapor_idx(...)`                       — line 1288
##
## 物理项 helper：
##   - `_orographic_lift_for_cell(cell, map, wind_dir)`         — line 1370
##   - `_orographic_lift_idx(idx, cells, cell_pos, neighbor_indices, wind_dir)` — line 1381
##   - `_orographic_lift_from_upstream_idx(...)`                — line 1394
##   - `_wind_convergence_for_cell(cell, map)`                  — line 1406
##   - `_wind_convergence_idx(idx, cells, cell_pos, neighbor_indices)` — line 1426
##   - `_avg_ocean_anomaly_at(cell, map)`                       — line 2348
##   - `_avg_ocean_anomaly_at_idx(idx, cells, neighbor_indices)` — line 1300
##
## 跨 tick / round 缓存字段（移过来后这些字段从 weather_system 删除）：
##   - `_field_slice_active / _field_slice_map / _field_slice_world / _field_slice_season_idx /
##      _field_slice_climate_anomaly / _field_slice_cursor / _field_slice_refresh_convergence /
##      _field_slice_cells / _field_slice_cell_pos / _field_slice_neighbor_indices /
##      _field_slice_fast_indexed / _field_slice_prev_vapor / _field_slice_prev_precip /
##      _field_slice_next_vapor / _field_slice_next_cloud / _field_slice_next_precip /
##      _field_slice_next_instability / _field_slice_next_intensity /
##      _field_slice_next_convergence / _field_slice_next_type /
##      _field_slice_solve_ms / _field_slice_last_ms`
##   - `_weather_field: Dictionary`（per-cell field state）
##   - `_tick_cell_pos: Dictionary` / `_tick_cell_neighbors: Dictionary`（tick-scoped）
##
## ─── 拆分原则 ────────────────────────────────────────────────────────
##
## 1. `DCWeatherFieldSolver.new(weather_system)` 接受 owner 引用，从中拿
##    配置参数（_field_advect_steps / _field_diffusion / _field_condensation_gain
##    等约 12 个 _field_* 配置字段保留在 weather_system 作为业务旋钮）；
## 2. 读 cell.* schema-mirrored 字段统一走 `weather_refresh_job.data_core_views()`
##    返回的 view 字典（已存在）；
## 3. 写 weather component 仍走 cell.<field> = ... 的 SoA 镜像（阶段 II G.4 之后
##    才改为 world.write_*）；
## 4. F.1 阶段把 `_solve_weather_field` 整体调度切到 `DCWorldExt.run_weather_field_solve_pass`
##    的 C++ 实现，本类成为 GDScript fallback 路径的承载点。
##
## ─── 拆完后 weather_system.gd 应有变化 ──────────────────────────────────
## - line 849-2348 之间约 1500 行 field-solver 相关代码被搬走
## - 残留 weather_system.gd ~600 行（持 _field_* 配置字段 + tick_one_day 协调入口）
## - E.2 / E.3 后再砍到 ~150 行

# ─── 当前 facade 接口（actual extraction PR will add real implementations）─────

var _weather_system  # WeatherSystem owner; 在 E.1 后替换为本类持有的字段


## 在 weather_system 实例上注入本 solver。为 E.3 cleanup 时 weather_system 可
## 通过 `_field_solver = DCWeatherFieldSolver.new(self)` 实例化并 forward 调用。
func _init(weather_system) -> void:
	_weather_system = weather_system
	if _weather_system == null:
		push_warning("[DCWeatherFieldSolver] _init: null weather_system; field solver will no-op")


## 主入口（搬迁 line 849-1170 后填充实现）。
## 当前：forward to owner 以保证业务语义不变。
func solve(map: MapData, world: WorldData, season_idx: int, climate_anomaly: float) -> void:
	if _weather_system == null:
		return
	# Future: call _solve_weather_field implementation moved here
	# Currently: weather_system._solve_weather_field is private; remains called
	# directly by weather_system.tick_one_day until extraction PR lands.
	pass


## 切片入口（搬迁 commit_weather_field_solve + slice 状态机后填充）。
## E.1 阶段返回空 fronts；F.1 C++ 化后由 caller 切到 DCWorldExt 路径。
func commit() -> Array[WeatherFront]:
	return [] as Array[WeatherFront]


## 是否所有 declared component 都已 ready（与 weather_refresh_job.data_core_field_ready 同义）。
func is_data_core_ready() -> bool:
	if _weather_system == null:
		return false
	# Delegate to weather_system if it has the check; future: own check
	return false


func describe() -> String:
	return "DCWeatherFieldSolver(owner=%s)" % ("weather_system" if _weather_system != null else "(null)")
