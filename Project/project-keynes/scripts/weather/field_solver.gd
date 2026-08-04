extends RefCounted
class_name DCWeatherFieldSolver

## Phase E.1 / dots-full-migration §Phase E.1：weather field solver 抽出。
##
## **当前状态（dots-monolith-split §1.2 / PR-1..7 全部完成）**：
## 实际 hot-path 实现已全量搬入本类。`weather_system.gd` 端的同名函数
## （begin_weather_field_solve / run_weather_field_solve_slice /
## commit_weather_field_solve / _solve_weather_field）保留为薄转发入口，
## 服务于 map_generator.gd 等 SUS job 的外部契约稳定。
## 业务旋钮（`_field_advect_steps` / `_field_diffusion` / `_field_condensation_gain`
## 等约 12 个 `_field_*` 配置字段）仍保留在 weather_system 作为 owner
## 配置中心；本类通过 `_weather_system.<field>` 读取。
##
## ─── 已完成的搬迁清单 ─────────────────────────────────────────────────
##
## PR-1：邻居/风向 helper（9 个）
##   - `_neighbor_aligned` / `_neighbor_aligned_idx`
##   - `_upstream_vapor` / `_upstream_vapor_cached` / `_upstream_vapor_idx` /
##     `_upstream_vapor_idx_from_first`
##   - `_neighbor_average_vapor` / `_neighbor_average_vapor_cached` /
##     `_neighbor_average_vapor_idx`
##
## PR-2：物理项 helper（5 个）
##   - `_orographic_lift_for_cell` / `_orographic_lift_idx` /
##     `_orographic_lift_from_upstream_idx`
##   - `_wind_convergence_for_cell` / `_wind_convergence_idx`
##
## PR-3：海洋异常 helper（2 个）
##   - `_avg_ocean_anomaly_at` / `_avg_ocean_anomaly_at_idx`
##
## PR-4：切片状态字段（22 个 `_field_slice_*`）
##   - active / map / world / season_idx / climate_anomaly / cursor /
##     refresh_convergence / cells / cell_pos / neighbor_indices /
##     fast_indexed / prev_vapor / prev_precip / next_vapor / next_cloud /
##     next_precip / next_instability / next_intensity / next_convergence /
##     next_type / solve_ms / last_ms
##
## PR-5：`commit()` 主体（149 行）
##   - 9 字段 batch SoA 写入（DCWorld.write_f32_indexed / write_u8_indexed）
##   - facade 开启时跳过 AoS 双写
##   - distribute / build_field_summary_fronts / cyclone_wake / breakdown
##
## PR-6：`begin_slice()`（63 行）+ `run_slice()`（181 行）
##   - DCWorldExt C++ 单 shot fast path
##   - GDScript fallback：vapor / cloud / precip / instability 三段式 hot loop
##   - `_solve_weather_field` 内 250 行 dead code 清除
##
## ─── 拆分原则（保留作为后续维护参考）──────────────────────────────────
##
## 1. `DCWeatherFieldSolver.new(weather_system)` 接受 owner 引用，从中拿
##    约 12 个 `_field_*` 配置字段；
## 2. 读 cell.* schema-mirrored 字段统一走 SoA index（PackedArray）；
## 3. 写 weather component 走 cell.<field> = ... 的 SoA 镜像 + DCWorld
##    write_*_indexed 批量提交；
## 4. F.1 阶段（已上线）把 `run_slice` 整体调度切到
##    `DCWorldExt.run_weather_field_solve_pass` 的 C++ 实现，本类的 GDScript
##    实现作为 fallback 路径。
##
## ─── 隔离 fallback 声明（NS 化 Phase 2,2026-08-04）──────────────────
## 生产 profile 已退休 legacy weather 生产注册（native C++ 是唯一生产路径），
## 本 GDScript hot loop 定位为 **stale-DLL 隔离 fallback**：保留旧 hopping
## 平流语义（`_upstream_vapor_idx_from_first`，离散邻居逐跳），**不镜像**
## C++ 的风场轨迹表三点插值（`_phys_wind_traj` 成员缓存仅存在于 native 侧，
## GDScript 无法访问 → 无法 bit-equal，强行近似反而引入第二条漂移源）。
## 例外：静态纯函数 `hex_sextant_barycentric()` 与 C++ 保持 SAME_SOURCE
## 数学定义互链（不依赖成员缓存，可供任何 GDScript 侧 SL 计算复用）。

# ─── solver 实现入口（hot loop 已全量实装，见上方 PR-1..7 清单）─────

var _weather_system  # WeatherSystem owner; 在 E.1 后替换为本类持有的字段


## 在 weather_system 实例上注入本 solver。为 E.3 cleanup 时 weather_system 可
## 通过 `_field_solver = DCWeatherFieldSolver.new(self)` 实例化并 forward 调用。
func _init(weather_system) -> void:
	_weather_system = weather_system
	if _weather_system == null:
		push_warning("[DCWeatherFieldSolver] _init: null weather_system; field solver will no-op")


## 主入口：dots-monolith-split §1.2 / PR-6 搬迁。
## 三段式：begin_slice 初始化 → 循环 run_slice 跑完所有 cell → commit 写出 SoA & 构建 fronts。
## map_generator.gd 的 SUS job 直接调 weather_system.begin_weather_field_solve /
## run_weather_field_solve_slice / commit_weather_field_solve（已薄转发到本类）。
func solve(map: MapData, world: WorldData, season_idx: int, climate_anomaly: float) -> void:
	if _weather_system == null:
		return
	begin_slice(map, world, season_idx, climate_anomaly, _weather_system._season_phase)
	while true:
		var slice_result: Dictionary = run_slice(2147483647)
		if bool(slice_result.get("done", true)):
			break
	commit()

# ─── PR-6：切片状态机主体（搬迁自 weather_system.gd line 629-873）──────────
# weather_system 端 begin_weather_field_solve / run_weather_field_solve_slice
# 改为薄转发到本类的 begin_slice / run_slice。所有 _field_slice_* 字段（PR-4
# 搬来）作为 self 成员；owner 上的 _field_*/世界边界/gdext 状态等通过
# _weather_system.xxx 访问；helper（_neighbor_aligned_idx / _upstream_vapor_idx*
# / _orographic_lift* / _wind_convergence* / _avg_ocean_anomaly_at* /
# _neighbor_average_vapor*）已在 PR-1/2/3 搬入本类，自调用。

## 切片初始化：分配 prev/next buffer、读 SoA 进 prev_vapor/precip。
func begin_slice(map: MapData, world: WorldData, season_idx: int, climate_anomaly: float, season_phase: float = -1.0, count_day: bool = true) -> void:
	_weather_system._clear_weather_field_slice_state()
	if map == null or world == null:
		return
	if count_day:
		_weather_system._day_counter += 1
	_weather_system._current_map_for_tick = map
	_weather_system._season_phase = season_phase if season_phase >= 0.0 else float(season_idx) + 0.5
	_weather_system._field_solve_tick += 1
	_field_slice_active = true
	_field_slice_map = map
	_field_slice_world = world
	_field_slice_season_idx = season_idx
	_field_slice_climate_anomaly = climate_anomaly
	_field_slice_cursor = 0
	_field_slice_solve_ms = 0.0
	_field_slice_last_ms = 0.0
	_field_slice_results_in_soa = false
	_field_slice_native_convergence_boost = false
	_field_slice_temp_anom = PackedFloat32Array()
	_field_slice_native_knobs.clear()
	_field_slice_refresh_convergence = ((_weather_system._field_solve_tick - 1) % _weather_system._field_convergence_refresh_stride) == 0
	_field_slice_cells = map.iter_cells() if map.has_indices() else map.all_cells()
	var n_cells: int = _field_slice_cells.size()
	# Stage6c: 对流抑制记忆数组——仅在尺寸变化(换地图)时重置，否则跨 tick 持久(承载充放电记忆)。
	if _convective_inhib.size() != n_cells:
		_convective_inhib = PackedFloat32Array()
		_convective_inhib.resize(n_cells)
	_field_slice_temp_read = map.temp_arr_prev if map.temp_arr_prev.size() == n_cells else map.temp_arr
	_field_slice_moisture_read = map.moisture_arr_prev if map.moisture_arr_prev.size() == n_cells else map.moisture_arr
	if map.weather_classification_temp_arr.size() == n_cells:
		map.weather_classification_temp_arr = _field_slice_temp_read.duplicate()
	if map.weather_classification_moisture_arr.size() == n_cells:
		map.weather_classification_moisture_arr = _field_slice_moisture_read.duplicate()
	_field_slice_snow_cover_read = map.snow_cover_arr_prev if map.snow_cover_arr_prev.size() == n_cells else map.snow_cover_arr
	_field_slice_neighbor_indices = map.neighbor_indices_packed() if map.has_indices() else PackedInt32Array()
	_field_slice_fast_indexed = _field_slice_neighbor_indices.size() >= n_cells * 6
	var map_id: int = map.get_instance_id()
	var has_soa_pos_for_scale: bool = map.cell_pos_x_arr.size() >= n_cells and map.cell_pos_y_arr.size() >= n_cells
	_field_slice_cell_pos_scale = 1.0 if has_soa_pos_for_scale else _weather_system._hex_size
	_field_slice_wrap_width_x = float(map.width) * sqrt(3.0) * _field_slice_cell_pos_scale if map.width > 0 else 0.0
	var can_reuse_cell_pos: bool = _cached_cell_pos_n == n_cells \
		and _cached_cell_pos_map_id == map_id \
		and absf(_cached_cell_pos_hex_size - _field_slice_cell_pos_scale) < 0.0001 \
		and _cached_cell_pos.size() == n_cells
	if not can_reuse_cell_pos:
		_cached_cell_pos = PackedVector2Array()
		_cached_cell_pos.resize(n_cells)
		var pos_x_arr: PackedFloat32Array = map.cell_pos_x_arr
		var pos_y_arr: PackedFloat32Array = map.cell_pos_y_arr
		for i in range(n_cells):
			if has_soa_pos_for_scale:
				_cached_cell_pos[i] = Vector2(pos_x_arr[i], pos_y_arr[i])
			else:
				var cell: HexCell = _field_slice_cells[i]
				_cached_cell_pos[i] = HexUtils.cube_to_world(cell.q, cell.r, _weather_system._hex_size)
		_cached_cell_pos_n = n_cells
		_cached_cell_pos_map_id = map_id
		_cached_cell_pos_hex_size = _field_slice_cell_pos_scale
	_field_slice_cell_pos = _cached_cell_pos
	_weather_system._tick_cell_pos.clear()
	_weather_system._tick_cell_neighbors.clear()

	_field_slice_prev_vapor = PackedFloat32Array()
	_field_slice_prev_precip = PackedFloat32Array()
	_field_slice_next_vapor = PackedFloat32Array()
	_field_slice_next_cloud = PackedFloat32Array()
	_field_slice_next_cloud_water = PackedFloat32Array()
	_field_slice_next_precip = PackedFloat32Array()
	_field_slice_next_instability = PackedFloat32Array()
	_field_slice_next_intensity = PackedFloat32Array()
	_field_slice_next_convergence = PackedFloat32Array()
	_field_slice_next_type = PackedInt32Array()
	_field_slice_prev_vapor.resize(n_cells)
	_field_slice_prev_precip.resize(n_cells)
	_field_slice_next_vapor.resize(n_cells)
	_field_slice_next_cloud.resize(n_cells)
	_field_slice_next_cloud_water.resize(n_cells)
	_field_slice_next_precip.resize(n_cells)
	_field_slice_next_instability.resize(n_cells)
	_field_slice_next_intensity.resize(n_cells)
	_field_slice_next_convergence.resize(n_cells)
	_field_slice_next_type.resize(n_cells)
	# B-full Step-2：prev 拷贝走 SoA 直读，消除每 cell 4 次 HexCell 字段访问。
	# SoA 数组在 bake_world 时由 rebuild_soa_from_cells() alloc 并与 DCWorld view_f32
	# 同引用；--data-core=true / false 行为完全一致，因为 SoA 始终被维护。
	# 等价语义保留：未 init 的 cell（field_init==0）用 moisture 兜底，precip 当 0。
	var soa_vapor_in: PackedFloat32Array = map.weather_vapor_arr
	var soa_precip_in: PackedFloat32Array = map.weather_precip_arr
	var soa_field_init: PackedByteArray = map.weather_field_init_arr
	var soa_moisture: PackedFloat32Array = _field_slice_moisture_read if _field_slice_moisture_read.size() == n_cells else map.moisture_arr
	for i in range(n_cells):
		if soa_field_init[i] > 0:
			_field_slice_prev_vapor[i] = soa_vapor_in[i]
			_field_slice_prev_precip[i] = soa_precip_in[i]
		else:
			# Stage6d (2026-06-23) 修首帧暴雨/暴雪：原 prev_vapor=moisture(满饱和，洋=1.0)→首 tick 处处过饱和
			# →全图凝结成雨(实测首 tick 86% 格降水、21% 暴雪)，再经 ~15 tick 弛豫。改为按稳态量级(≈0.15×moisture)
			# 起步，让水汽由蒸发温和积累、降水渐次涌现，消除 spin-up 暴雨暴雪瞬变。
			_field_slice_prev_vapor[i] = soa_moisture[i] * 0.15
			_field_slice_prev_precip[i] = 0.0
	var tta_soa: PackedFloat32Array = map.temperature_transport_anomaly_arr
	if tta_soa.size() == n_cells:
		_field_slice_temp_anom = tta_soa
	else:
		_field_slice_temp_anom = PackedFloat32Array()
		_field_slice_temp_anom.resize(n_cells)
		for ti in range(n_cells):
			var tc: HexCell = _field_slice_cells[ti]
			_field_slice_temp_anom[ti] = float(tc.temperature_transport_anomaly)
	# ─── climate-realism Stage1 (2026-06-23): 计算「热赤道」纬度 (norm) ──────
	# = zonal-mean 温度最高的纬度带。供 Hadley/Ferrel omega 项以「相对热赤道距离」定位
	# ITCZ/副热带/风暴轴，随季迁移、不产生沿绝对纬线的直线条带。用基准气候温度(非含
	# air anomaly 的分类温度)。每 tick 一次 O(n) 累加 + 24 桶 argmax + 抛物线细化。
	var lat_te_norm: float = 0.5
	var te_bpos_y: float = _weather_system._world_bounds.position.y
	var te_bsize_y: float = _weather_system._world_bounds.size.y
	if te_bsize_y > 0.001 and _field_slice_temp_read.size() == n_cells and _field_slice_cell_pos.size() == n_cells:
		const TE_NB := 24
		var te_sum: PackedFloat32Array = PackedFloat32Array(); te_sum.resize(TE_NB)
		var te_cnt: PackedInt32Array = PackedInt32Array(); te_cnt.resize(TE_NB)
		for ci in range(n_cells):
			var nyv: float = clampf((_field_slice_cell_pos[ci].y - te_bpos_y) / te_bsize_y, 0.0, 0.999999)
			var bkt: int = int(nyv * TE_NB)
			te_sum[bkt] += _field_slice_temp_read[ci]
			te_cnt[bkt] += 1
		var best_m: float = -1.0
		var best_b: int = TE_NB / 2
		for bk in range(TE_NB):
			if te_cnt[bk] > 0:
				var m: float = te_sum[bk] / float(te_cnt[bk])
				if m > best_m:
					best_m = m
					best_b = bk
		var bf: float = float(best_b)
		if best_b > 0 and best_b < TE_NB - 1 and te_cnt[best_b - 1] > 0 and te_cnt[best_b + 1] > 0:
			var ml: float = te_sum[best_b - 1] / float(te_cnt[best_b - 1])
			var mr: float = te_sum[best_b + 1] / float(te_cnt[best_b + 1])
			var denom: float = ml - 2.0 * best_m + mr
			if absf(denom) > 1.0e-6:
				bf += clampf(0.5 * (ml - mr) / denom, -0.5, 0.5)
		lat_te_norm = clampf((bf + 0.5) / float(TE_NB), 0.0, 1.0)
	_field_slice_lat_te_norm = lat_te_norm
	if _weather_system._use_gdext_weather_field and _field_slice_fast_indexed \
			and _weather_system._data_core_world_ext != null:
		_field_slice_native_knobs = _weather_system._build_weather_field_knobs(map, world, n_cells, 0, n_cells)


## 切片单步：在 [start_i, end_i) 范围内跑 vapor/cloud/precip 三段式 hot loop。
## 优先走 DCWorldExt C++ range fast path；失败时回退到 GDScript range loop。
func run_slice(cell_budget: int) -> Dictionary:
	if not _field_slice_active:
		return { "done": true, "work_done": 0, "elapsed_ms": 0.0, "progress_ratio": 1.0 }
	var t_us0: int = Time.get_ticks_usec()
	var map: MapData = _field_slice_map
	var world: WorldData = _field_slice_world
	var cells: Array = _field_slice_cells
	var n_cells: int = cells.size()
	var start_i: int = _field_slice_cursor
	var end_i: int = mini(n_cells, start_i + maxi(1, cell_budget))

	# ─── Phase F.1：DCWorldExt C++ range 快路径 ────────────────────────
	# 触发条件：
	#   1. configure_gdext_acceleration(_weather_system._data_core_world_ext, true) 已生效
	#   2. _field_slice_fast_indexed（neighbor_indices_packed 完整）
	#   3. C++ 端 run_weather_field_solve_pass 支持 start_idx/end_idx 并返回 ≥ 0
	if _weather_system._use_gdext_weather_field \
			and _field_slice_fast_indexed and _weather_system._data_core_world_ext != null:
		# 一次性诊断：第一次进入 fast path 时打一条日志，把 5 个 precondition
		# 的真实状态以及 n_cells / cell_budget 全打出，方便排查。已成功跑过
		# 一次后不再 spam。
		if not _weather_system._gdext_field_first_attempt_logged:
			_weather_system._gdext_field_first_attempt_logged = true
			print("[weather/F.1] first fast-path attempt: n_cells=%d cell_budget=%d (would-end_i=%d) fast_indexed=%s ext_bound=%s" % [
				n_cells, cell_budget, end_i, str(_field_slice_fast_indexed), str(_weather_system._data_core_world_ext != null)
			])
		var rc: float = _weather_system._try_run_weather_field_solve_gdext(map, world, n_cells, start_i, end_i)
		if rc >= 0.0:
			# C++ 完成当前 range。写入 SoA 暂不发布；只有 commit() 才让 renderer/UI
			# 看到完整 round，保持中间态不可见。
			_field_slice_results_in_soa = false
			_field_slice_native_convergence_boost = _field_slice_refresh_convergence \
				and not _weather_system._field_verify_enabled
			# A/B 验证（dev 诊断 only）：在 C++ 写完 SoA 之后，把 next_* 快照、
			# 复位 SoA、跑一遍 GDScript loop 写到独立缓冲区，然后逐 cell 对账。
			# 失败时 push_warning 并打首次发散位置；不影响本 tick commit（commit
			# 仍走 C++ 结果——出 bug 时玩家肉眼能看到，verify 只是给 dev 抓证据）。
			var done_native: bool = end_i >= n_cells
			var transition_enabled_native: bool = false
			var cp_native = _weather_system._cp_for_front_flag
			if cp_native != null and cp_native.get("weather_transition_enabled") != null:
				transition_enabled_native = bool(cp_native.weather_transition_enabled)
			var native_wrote_next: bool = bool(_field_slice_native_knobs.get("weather_field_wrote_next", false))
			if done_native:
				if not native_wrote_next and (
						_weather_system._field_verify_enabled
						or not _weather_system._hexcell_facade_on
						or transition_enabled_native):
					_weather_system._pull_gdext_field_results_to_next(map, n_cells)
				if _weather_system._field_verify_enabled:
					_weather_system._verify_gdext_field_against_gdscript(map, world, n_cells)
			_field_slice_cursor = end_i
			_field_slice_solve_ms += rc
			_field_slice_last_ms = rc
			_weather_system._gdext_field_runs += 1
			_weather_system._gdext_field_total_ms += rc
			# 一次性确认日志：第一次成功跑过 C++ 后打一条，后续静默
			if _weather_system._gdext_field_runs == 1:
				print("[weather/F.1] gdext path ACTIVE — first run elapsed=%.2fms (legacy GDScript baseline ≈ 13ms; charter §7 target < 2ms)" % rc)
			return {
				"done": done_native,
				"work_done": end_i - start_i,
				"elapsed_ms": rc,
				"progress_ratio": float(_field_slice_cursor) / float(maxi(n_cells, 1)),
				"processed_cells": end_i - start_i,
				"cursor_start": start_i,
				"cursor_end": end_i,
			}
		_weather_system._gdext_field_fallbacks += 1
		# rc<0 时 C++ 已经在 console push_warning 了，不需要再叠加日志。

	var cell_pos: PackedVector2Array = _field_slice_cell_pos
	var neighbor_indices: PackedInt32Array = _field_slice_neighbor_indices
	var fast_indexed: bool = _field_slice_fast_indexed
	var prev_vapor: PackedFloat32Array = _field_slice_prev_vapor
	var prev_precip: PackedFloat32Array = _field_slice_prev_precip
	var next_vapor: PackedFloat32Array = _field_slice_next_vapor
	var next_cloud: PackedFloat32Array = _field_slice_next_cloud
	var next_cloud_water: PackedFloat32Array = _field_slice_next_cloud_water
	var next_precip: PackedFloat32Array = _field_slice_next_precip
	var next_instability: PackedFloat32Array = _field_slice_next_instability
	var next_intensity: PackedFloat32Array = _field_slice_next_intensity
	var next_convergence: PackedFloat32Array = _field_slice_next_convergence
	var next_type: PackedInt32Array = _field_slice_next_type
	var season_idx: int = _field_slice_season_idx
	var climate_anomaly: float = _field_slice_climate_anomaly
	var refresh_convergence: bool = _field_slice_refresh_convergence
	# B-full Step-2：cell-loop 外一次性取 SoA 数组引用。SoA 与 DCWorld view_f32 同引用，
	# 循环内全部走 PackedArray index 访问，消除 cell.xxx 强类型成员访问。
	# 唯一保留 AoS 的字段是 temperature_transport_anomaly（在 _avg_ocean_anomaly_at_idx
	# helper 中），不在本 plan 范围（属 climate ocean heat transport pass 改造）。
	var soa_temp: PackedFloat32Array = _field_slice_temp_read if _field_slice_temp_read.size() == n_cells else map.temp_arr
	var soa_air_anomaly: PackedFloat32Array = map.air_mass_temp_anomaly_arr
	var soa_temp_anom: PackedFloat32Array = map.temp_anomaly_arr
	var soa_moisture_loop: PackedFloat32Array = _field_slice_moisture_read if _field_slice_moisture_read.size() == n_cells else map.moisture_arr
	var soa_elevation: PackedFloat32Array = map.elevation_arr
	var soa_wind_x: PackedFloat32Array = map.wind_x_arr
	var soa_wind_y: PackedFloat32Array = map.wind_y_arr
	var soa_wind_speed: PackedFloat32Array = map.wind_speed_arr
	var soa_terrain: PackedByteArray = map.terrain_arr
	var soa_has_river: PackedByteArray = map.has_river_arr
	var soa_river_q30: PackedFloat32Array = map.river_discharge_30d_arr
	var soa_soil_moisture: PackedFloat32Array = map.soil_moisture_arr
	var soa_veg_vitality: PackedFloat32Array = map.vegetation_vitality_arr
	var soa_sea_ice: PackedFloat32Array = map.sea_ice_frac_arr
	var soa_convergence_in: PackedFloat32Array = map.weather_convergence_arr
	var prev_cloud_water_arr: PackedFloat32Array = map.weather_cloud_water_arr
	var prev_cloud_arr: PackedFloat32Array = map.weather_cloud_arr  # Stage15 云量 EMA 用上帧云量
	var temp_anom_arr: PackedFloat32Array = _field_slice_temp_anom if _field_slice_temp_anom.size() == n_cells else map.temperature_transport_anomaly_arr
	# ─── 平流式湿团模型常量 (2026-06-21, 镜像 world_ext.cpp 默认值; 实机校准定稿后再旋钮化) ──
	# 2026-06-21 实机迭代(镜像 world_ext.cpp)：第一轮(降 RH_CONDENSE 0.55→0.32 + 提 base/auto)经
	# 205247 复验适得其反——land_dry 49%→83%、vapor 全面崩塌(内陆 0.185→0.085)。根因：降 rh_condense
	# 降低【全局】凝结门槛→水汽场被过度凝结+降水抽干，内陆(输送末端)枯竭最重；增雨靠多凝结是零和陷阱。
	# 第二轮：RH_CONDENSE 回滚 0.55 止抽干，仅保留 BASE_FRAC 0.50 + AUTOCONVERSION 0.16 提 trig
	# (离线验证不抽干 vapor)，隔离验证 trig 提升单独效果。下一轮若不足走开源(提 land_evap)而非加速循环。
	const ADV_VAPOR := 0.95  # 同步C++ 方案③ vapor 平流主导
	const ADV_CLOUD := 0.94
	const RH_CONDENSE := 0.55
	const STATIC_COND_W := 1.0
	const CONDENSE_RATE := 0.45
	const LIFT_COND_GAIN := 0.80
	const CONV_COND_GAIN := 1.0
	const AUTOCONVERSION := 0.16
	# [climate-zone-fix P3] 修漂移：原 const 0.12 与 C++ 主路径(读 field_precip_base_frac knob=cp.weather_field_precip_base_frac=0.08)
	# 不一致。改读同一 weather_system 成员，两路逐位同源(生产默认 0.08)。
	var PRECIP_BASE_FRAC: float = _weather_system._field_precip_base_frac
	const LIFT_PRECIP_GAIN := 0.25
	const CONV_PRECIP_GAIN := 1.95   # B1(2026-06-28) 1.80→1.95 提辐合致雨权重,补温度对流减弱→r(precip,conv)↑。镜像 world_ext.cpp
	const ORO_PRECIP_GAIN := 0.10
	const CLOUD_REEVAP := 0.18   # 2026-06-22 雨云化:0.06→0.18 云水更快再蒸发→雨团边缘消散、雨过转晴(生命周期)
	# 热力对流(大陆夏季雷暴)：地表加热+本地水汽 → 凝结/降水，修复内陆"水汽到了却凝不成雨"。镜像 world_ext field_thermal_conv_*。
	const THERMAL_CONV_COND := 1.15   # 降低静态热力云源，让移动/平流项主导雨云
	# [climate-zone-fix P3] 导出为旋钮(cp.weather_field_thermal_conv_precip)；两路读同一 weather_system 成员保 SAME_SOURCE。
	var THERMAL_CONV_PRECIP: float = _weather_system._field_thermal_conv_precip
	# ─── climate-realism Stage1 (2026-06-23): Hadley/Ferrel 垂直运动项 omega ──
	# 键在「热赤道」相对纬度(随季迁移、无直线条带): ITCZ/风暴轴上升带增雨, 副热带下沉带抑制凝结+降水。
	# lat_te_norm 由 begin_slice 按 zonal-max 温度逐 tick 计算。镜像 world_ext.cpp。
	# [climate-zone-fix P3] 导出为旋钮(cp.weather_field_omega_ascent_gain)；两路读同一 weather_system 成员保 SAME_SOURCE。
	var OMEGA_ASCENT_GAIN: float = _weather_system._field_omega_ascent_gain  # ITCZ(|dlat|<~12°)/风暴轴上升带成雨增益(下调弱化静止ITCZ)
	const OMEGA_DESCENT_GAIN := 0.70   # 副热带(|dlat|~22-34°)下沉带降水抑制
	const OMEGA_DESCENT_COND := 0.45   # 副热带下沉抑制凝结→晴空(利于热浪/旱灾)
	# ─── climate-realism Stage6 (2026-06-23): 湿度充放电 recharge-discharge ─────
	# Stage6/6b 用 vapor 放电把雨段中位 37天→3天、单带 0.91→0.16、海上开始自生成；但 ≥7天长尾(34%)未消、且偏干。
	# 根因：长尾格是【强迫主导】(常驻辐合/地形抬升)而非水汽主导——抽干水汽只会饿死弱短系统(全局变干)，
	# 强迫格仍靠平流来的少量水汽持续成雨。Stage6c 改用【对流抑制记忆】(下方 INHIB_*)定点封顶强迫格，
	# 同时把 vapor 放电调回温和(不再过度抽干)。
	const VAPOR_DISCHARGE := 0.70   # 持续降水更快抽干本格水汽，避免固定雨核永雨
	const DISCHARGE_SUSTAIN := 0.65 # prev_precip 高时加强放电，让雨团下完后进入恢复期
	# ── Stage6e (2026-06-23): 对流抑制记忆=双稳弛豫振子(真·充放电极限环) ──
	# 实测线性版(precip×(1-inhib·k))只把降水压到稳态弱雨(~0.05>湿阈)→雨永不停、中位反而升到 16 天。
	# 改双稳硬阈：inhib 累积过 TRIGGER → 降水砍到近 0(气柱放电、转干转晴) → inhib 衰减落回 → 释放再积累。
	# 无中间稳态→真正的 开/关 循环→封顶雨段；只作用于刚下过雨的格(干区 inhib=0)。
	# ── Stage6g (2026-06-23): 对流抑制=按【时长】充放电(强度无关)，双稳两段编码于单个 float ──
	# 实测 magnitude 版只能封重雨(>~0.065)，中等雨(p50 0.065)稳态 inhib<阈→永不触发→中等长尾(≥7天 18%)。
	# 改按"连续降水 tick 数"充能：任意强度连下 ~6 tick → 满 → 跳到不应期(转干转晴) → 衰减落回 → 重启。
	# 与强度无关→中等雨也被封顶；充能期满强度照下→不伤雨量/多样性。物理上=对流耗尽本地不稳定度需特征"时长"。
	#   inhib∈[0,1) 充能期；inhib≥1 不应期(压制降水)。
	const INHIB_CHARGE := 0.26    # Stage7c: 0.18→0.26 雨段缩到≈4tick(~2天)→雨不再"久久下不完"
	const INHIB_REFRAC := 0.18    # Stage7c: 0.55→0.18 不应期拉长到≈5-6tick(~3天)→晴天是真间断而非极短闪烁
	const INHIB_LEAK := 0.88      # 充能期遇干 tick 的泄放(断续雨慢充、久干遗忘)
	const INHIB_STRENGTH := 0.92  # 不应期内 precip ×(1-此值)
	const INHIB_WET := 0.02       # 计为"降水 tick"的阈
	var lat_te_norm: float = _field_slice_lat_te_norm
	var omega_bpos_y: float = _weather_system._world_bounds.position.y
	var omega_bsize_y: float = _weather_system._world_bounds.size.y
	for i in range(start_i, end_i):
		var cell: HexCell = cells[i]
		var pos: Vector2 = cell_pos[i]
		var temp: float = clampf(soa_temp[i] + climate_anomaly + soa_air_anomaly[i], 0.0, 1.0)
		var base_m: float = clampf(soa_moisture_loop[i], 0.0, 1.0)
		var elevation: float = soa_elevation[i]
		var vapor_capacity: float = clampf(0.18 + 0.82 * temp - 0.18 * elevation, 0.14, 1.0)
		var ocean_an: float = _avg_ocean_anomaly_at_idx(i, cells, neighbor_indices) if fast_indexed else _avg_ocean_anomaly_at(cell, map)
		var on_water: bool = _weather_system._is_water_terrain(int(soa_terrain[i]))

		var wind: Vector2 = Vector2(soa_wind_x[i], soa_wind_y[i])
		if wind.length_squared() < 0.0001:
			var ny: float = 0.5
			if _weather_system._world_bounds.size.y > 0.001:
				ny = clampf((pos.y - _weather_system._world_bounds.position.y) / _weather_system._world_bounds.size.y, 0.0, 1.0)
			wind = _weather_system._sample_terrain_wind(map, world, pos, ny, _weather_system._season_phase)
		var wind_dir: Vector2 = wind.normalized() if wind.length_squared() > 0.0001 else Vector2.RIGHT

		var upstream_idx: int = _neighbor_aligned_idx(i, -wind_dir, cell_pos, neighbor_indices) if fast_indexed and _weather_system._field_advect_steps > 0 else -1
		var advected_vapor: float = _upstream_vapor_idx_from_first(i, upstream_idx, cell_pos, neighbor_indices, prev_vapor, wind_dir) if fast_indexed else _upstream_vapor_cached(cell, map, prev_vapor, wind_dir)
		var neighbor_vapor: float = _neighbor_average_vapor_idx(i, neighbor_indices, prev_vapor) if fast_indexed else _neighbor_average_vapor_cached(cell, map, prev_vapor)
		var raw_wind_speed: float = soa_wind_speed[i] if soa_wind_speed.size() == n_cells else wind.length()
		var wind_mag: float = clampf(raw_wind_speed / 1.2, 0.0, 1.0)
		var lift: float = _orographic_lift_from_upstream_idx(i, upstream_idx, cells) if fast_indexed else _orographic_lift_for_cell(cell, map, wind_dir)
		var convergence: float = soa_convergence_in[i]
		if refresh_convergence:
			convergence = _wind_convergence_idx(i, cells, cell_pos, neighbor_indices) if fast_indexed else _wind_convergence_for_cell(cell, map)
		var is_lake: bool = int(soa_terrain[i]) == TerrainType.TERRAIN.LAKE
		var has_river: bool = (not is_lake) and (soa_has_river[i] > 0) and not on_water
		var river_flow_feedback: float = clampf(soa_river_q30[i] if soa_river_q30.size() == n_cells and has_river else 0.0, 0.0, 1.0)
		var river_recycle_lock: float = 0.0
		if has_river:
			var river_forcing_proxy: float = maxf(convergence * 0.65, maxf(lift, 0.0) * 0.80)
			river_recycle_lock = clampf(smoothstep(0.035, 0.12, prev_precip[i]) \
				* (1.0 - smoothstep(0.16, 0.44, river_forcing_proxy)) \
				* (0.35 + river_flow_feedback * 0.65), 0.0, 1.0)
		var river_source_scale: float = 1.0 - river_recycle_lock * 0.72
		var river_evap_floor: float = maxf(0.08, river_flow_feedback * 0.22) * (1.0 - river_recycle_lock * 0.65) if has_river else 0.0
		var effective_ocean_an: float = ocean_an
		if is_lake:
			effective_ocean_an = 0.20
		elif has_river:
			effective_ocean_an = maxf(ocean_an, river_evap_floor)

		var temp_evap: float = maxf(_weather_system._field_cool_season_vapor_floor, smoothstep(0.10, 0.78, temp))  # [P3] 冷季蒸发地板(0=原行为)
		var wind_evap: float = 0.70 + wind_mag * 0.55
		var soil_norm: float = clampf(0.5 + (soa_soil_moisture[i] if soa_soil_moisture.size() == n_cells else cell.soil_moisture), 0.0, 1.0)
		var veg_vitality: float = clampf(soa_veg_vitality[i] if soa_veg_vitality.size() == n_cells else cell.vegetation_vitality, 0.0, 1.0)
		var veg_flux: float = _weather_system._vegetation_transpiration_factor(cell) * (0.45 + veg_vitality * 0.65)
		var sea_ice: float = clampf(soa_sea_ice[i] if soa_sea_ice.size() == n_cells else cell.sea_ice_fraction, 0.0, 1.0)
		var wet_terrain_bonus: float = 0.0
		match int(soa_terrain[i]):
			TerrainType.TERRAIN.SWAMP, TerrainType.TERRAIN.JUNGLE, TerrainType.TERRAIN.DELTA:
				wet_terrain_bonus = 0.010
			TerrainType.TERRAIN.LAKE:
				wet_terrain_bonus = 0.016
			_:
				wet_terrain_bonus = 0.0
		var source_local: float = 0.0
		if on_water:
			source_local = (0.018 + temp_evap * 0.052) * _weather_system._field_ocean_evap_gain * wind_evap
			source_local *= clampf(1.0 + effective_ocean_an * 0.55, 0.55, 1.45)
			source_local *= 1.0 - sea_ice * 0.92
			if is_lake:
				source_local *= _weather_system._field_lake_evap_scale
		else:
			source_local = (0.005 + base_m * 0.010 + soil_norm * 0.020 + veg_flux * 0.016 + wet_terrain_bonus) \
				* _weather_system._field_land_evapotranspiration_gain * temp_evap * (0.85 + wind_mag * 0.25)
			if has_river:
				var river_extra: float = (0.010 + river_flow_feedback * 0.020) * _weather_system._field_land_evapotranspiration_gain * temp_evap
				source_local += river_extra * river_source_scale

		var source_upwind: float = source_local
		var upstream_on_water: bool = false
		if upstream_idx >= 0:
			var up_cell: HexCell = cells[upstream_idx]
			var up_temp: float = clampf(soa_temp[upstream_idx] + climate_anomaly + soa_air_anomaly[upstream_idx], 0.0, 1.0)
			var up_base_m: float = clampf(soa_moisture_loop[upstream_idx], 0.0, 1.0)
			var up_terrain: int = int(soa_terrain[upstream_idx])
			var up_on_water: bool = _weather_system._is_water_terrain(up_terrain)
			upstream_on_water = up_on_water
			var up_is_lake: bool = up_terrain == TerrainType.TERRAIN.LAKE
			var up_has_river: bool = (not up_is_lake) and (soa_has_river[upstream_idx] > 0) and not up_on_water
			var up_river_q: float = clampf(soa_river_q30[upstream_idx] if soa_river_q30.size() == n_cells and up_has_river else 0.0, 0.0, 1.0)
			var up_river_recycle_lock: float = 0.0
			if up_has_river:
				var up_forcing_proxy: float = clampf(soa_convergence_in[upstream_idx] * 0.65, 0.0, 1.0)
				up_river_recycle_lock = clampf(smoothstep(0.035, 0.12, prev_precip[upstream_idx]) \
					* (1.0 - smoothstep(0.16, 0.44, up_forcing_proxy)) \
					* (0.35 + up_river_q * 0.65), 0.0, 1.0)
			var up_river_source_scale: float = 1.0 - up_river_recycle_lock * 0.72
			var up_temp_evap: float = maxf(_weather_system._field_cool_season_vapor_floor, smoothstep(0.10, 0.78, up_temp))  # [P3] 冷季蒸发地板(0=原行为)
			var up_ocean_an: float = temp_anom_arr[upstream_idx] if temp_anom_arr.size() == n_cells and up_on_water else effective_ocean_an
			var up_soil: float = clampf(0.5 + (soa_soil_moisture[upstream_idx] if soa_soil_moisture.size() == n_cells else up_cell.soil_moisture), 0.0, 1.0)
			var up_vitality: float = clampf(soa_veg_vitality[upstream_idx] if soa_veg_vitality.size() == n_cells else up_cell.vegetation_vitality, 0.0, 1.0)
			var up_veg_flux: float = _weather_system._vegetation_transpiration_factor(up_cell) * (0.45 + up_vitality * 0.65)
			var up_sea_ice: float = clampf(soa_sea_ice[upstream_idx] if soa_sea_ice.size() == n_cells else up_cell.sea_ice_fraction, 0.0, 1.0)
			var up_wet_bonus: float = 0.0
			match up_terrain:
				TerrainType.TERRAIN.SWAMP, TerrainType.TERRAIN.JUNGLE, TerrainType.TERRAIN.DELTA:
					up_wet_bonus = 0.010
				TerrainType.TERRAIN.LAKE:
					up_wet_bonus = 0.016
				_:
					up_wet_bonus = 0.0
			if up_on_water:
				source_upwind = (0.018 + up_temp_evap * 0.052) * _weather_system._field_ocean_evap_gain * wind_evap
				source_upwind *= clampf(1.0 + up_ocean_an * 0.55, 0.55, 1.45)
				source_upwind *= 1.0 - up_sea_ice * 0.92
				if up_is_lake:
					source_upwind *= _weather_system._field_lake_evap_scale
			else:
				source_upwind = (0.005 + up_base_m * 0.010 + up_soil * 0.020 + up_veg_flux * 0.016 + up_wet_bonus) \
					* _weather_system._field_land_evapotranspiration_gain * up_temp_evap * (0.85 + wind_mag * 0.25)
				if up_has_river:
					var up_river_extra: float = (0.010 + up_river_q * 0.020) * _weather_system._field_land_evapotranspiration_gain * up_temp_evap
					source_upwind += up_river_extra * up_river_source_scale

		# 平流式湿团：vapor 去 base_m 锚定 → 本地与上风加权平流(强度随风速) + 邻域扩散 + 蒸发源。
		# 允许短暂过饱和(不夹 cap 上限)，由后续凝结消耗 → 随风移动的湿团。镜像 world_ext.cpp。
		var adv_w_v: float = minf(ADV_VAPOR * (0.75 + 0.25 * wind_mag), 0.99)  # 同步C++ vapor 平流主导
		var vapor: float = lerpf(prev_vapor[i], advected_vapor, adv_w_v)
		vapor = lerpf(vapor, neighbor_vapor, _weather_system._field_diffusion)
		vapor = maxf(0.0, vapor + source_local + source_upwind * wind_mag * 0.25)

		# (背风焚风干燥已移入下方凝结/降水的 lift<0 抑制，避免对 vapor 重复扣减)

		var temp_min: float = temp
		var temp_max: float = temp
		if fast_indexed:
			var nb_base: int = i * 6
			for d in range(6):
				var nb_idx: int = neighbor_indices[nb_base + d]
				if nb_idx < 0:
					continue
				var nb_temp: float = clampf(soa_temp[nb_idx] + climate_anomaly + soa_air_anomaly[nb_idx], 0.0, 1.0)
				temp_min = minf(temp_min, nb_temp)
				temp_max = maxf(temp_max, nb_temp)
		else:
			for nb: HexCell in _weather_system._cell_neighbors(cell, map):
				if nb == null:
					continue
				var nb_temp_cell: float = clampf(nb.temperature + climate_anomaly + nb.air_mass_temp_anomaly, 0.0, 1.0)
				temp_min = minf(temp_min, nb_temp_cell)
				temp_max = maxf(temp_max, nb_temp_cell)
		var temp_gradient: float = temp_max - temp_min
		var relative_humidity: float = maxf(vapor / maxf(vapor_capacity, 0.001), 0.0)
		var frontal_convergence: float = smoothstep(0.14, 0.46, convergence)
		var humidity_front_gate: float = smoothstep(0.25, 0.78, relative_humidity)  # Stage2: 0.38→0.25 让冷湿锋面也成雨(温带过境雨团/冷区降雪)
		var frontogenesis: float = clampf(frontal_convergence * smoothstep(0.04, 0.16, temp_gradient) * humidity_front_gate * _weather_system._field_frontogenesis_gain, 0.0, 1.0)
		var lift_pos: float = maxf(lift, 0.0)
		# Stage11 层状降水(stratiform)：补对流暖门(temp>0.48)挡死的冷/高/水区降水——湿度+弱抬升(地形/辐合/
		# 锋面/海面层云·lake-effect),冷区权重高(与对流互补)。修 #4湖/#5a雪/#6山。镜像 world_ext.cpp。
		var strat_cool: float = 1.0 - smoothstep(0.40, 0.62, temp)
		var strat_humid: float = smoothstep(0.42, 0.70, relative_humidity)
		var strat_drive: float = lift_pos * 0.90 + convergence * 0.60 + frontogenesis * 0.80
		if on_water:
			strat_drive += (0.22 + wind_mag * 0.30) * (1.0 - sea_ice * 0.92)
		var stratiform: float = clampf(strat_humid * strat_cool * minf(strat_drive, 1.0) * _weather_system._field_stratiform_gain, 0.0, 1.0)  # [P3] 层状增益镜像 C++ field_stratiform_gain

		# 热力对流(大陆夏季雷暴/对流雨)：地表加热+本地水汽 → 浮力凝结+高效降水。修复内陆 rh 永远
		# <<静力阈、lift/辐合皆缺 → 蒸散/平流来的 vapor 凝不成云的死结(用户洞察:内陆蒸发应能成雨)。
		# 仅陆地。季节自限:冬温<0.45 不触发;降水耗 vapor→rh 降→对流减弱,呈"晴-积累-雷暴"间歇,不永雨。
		# 2026-06-22 雨云化根因:陆地rh中位0.18(>0.55仅2.7%→静力凝结死),成云降水76%靠本项热力对流。
		# rh*5门控致干空气被硬拉成半饱和→温暖陆地处处弱对流→产云水平流扩散→遍地雾+小雨。convective双峰
		# (p50=0,p75=0.39),谷底0.28硬截断:砍弱对流(损失6.5%降水)转晴/多云、保强对流核突显明显降水。(C++主路径同值)
		var conv_raw: float = 0.0 if on_water else smoothstep(0.48, 0.74, temp) * clampf(relative_humidity * 2.6, 0.0, 1.0)  # B1(2026-06-28) 3.6→2.6 去 rh 虚高:对流改由"湿暖"(沿海)触发而非"干暖"(内陆)→降水脱离纯温度。镜像 world_ext.cpp
		var convective: float = 0.0 if conv_raw < 0.42 else conv_raw
		var ocean_convective: float = 0.0
		if on_water:
			ocean_convective = smoothstep(0.10, 0.22, ocean_an) * smoothstep(0.58, 0.78, temp) * clampf(relative_humidity, 0.0, 1.0)
			var open_water: float = 1.0 - sea_ice * 0.92
			var warm_humid_marine: float = smoothstep(0.54, 0.74, temp) \
				* smoothstep(0.47, 0.69, relative_humidity) \
				* clampf(open_water, 0.0, 1.0)
			var marine_convective_seed: float = warm_humid_marine * (0.20 + wind_mag * 0.36)
			ocean_convective = minf(1.0, maxf(ocean_convective, marine_convective_seed))
		var onshore_moist_flux: float = 0.0
		var coastal_monsoon_flux: float = 0.0
		if not on_water and upstream_idx >= 0 and upstream_on_water:
			onshore_moist_flux = wind_mag * clampf(relative_humidity, 0.0, 1.0) * smoothstep(0.54, 0.75, temp)
			coastal_monsoon_flux = onshore_moist_flux
		elif on_water and upstream_idx >= 0:
			var downwind_idx: int = _neighbor_aligned_idx(i, wind_dir, cell_pos, neighbor_indices) if fast_indexed else -1
			var near_land: bool = false
			if downwind_idx >= 0:
				near_land = not _weather_system._is_water_terrain(int(soa_terrain[downwind_idx]))
			if near_land:
				coastal_monsoon_flux = wind_mag * clampf(relative_humidity, 0.0, 1.0) * smoothstep(0.56, 0.76, temp) * 0.75
		var dynamic_forcing: float = maxf(maxf(maxf(frontogenesis, convergence * 0.65), maxf(maxf(convective, ocean_convective), coastal_monsoon_flux)), stratiform)  # Stage11 含层状
		# Stage6: post-rain 抑制不再被强强迫完全豁免(原 ×(1-smoothstep) 在辐合带=0→雨带不自抑)。
		# 改留 45% 残余(×(1-0.55·smoothstep))，让辐合带雨团下完也进入不应期→配合放电自发消散。
		var post_rain_subsidence: float = smoothstep(0.035, 0.11, prev_precip[i]) * (1.0 - 0.55 * smoothstep(0.18, 0.55, dynamic_forcing))

		# ─── climate-realism Stage1: Hadley/Ferrel omega (镜像 world_ext.cpp) ──
		# dlat = 本格纬度距「热赤道」的度数; ITCZ/风暴轴上升带增雨, 副热带下沉带抑制凝结+降水→晴干。
		var omega_ny: float = clampf((cell_pos[i].y - omega_bpos_y) / omega_bsize_y, 0.0, 1.0) if omega_bsize_y > 0.001 else 0.5
		var omega_adlat: float = absf((omega_ny - lat_te_norm) * 180.0)
		var omega_itcz: float = 1.0 - smoothstep(8.0, 16.0, omega_adlat)
		var omega_storm: float = smoothstep(40.0, 48.0, omega_adlat) * (1.0 - smoothstep(62.0, 70.0, omega_adlat))
		var omega_ascent: float = maxf(omega_itcz, omega_storm)
		var omega_descent: float = smoothstep(14.0, 22.0, omega_adlat) * (1.0 - smoothstep(34.0, 42.0, omega_adlat))
		var omega_precip_mult: float = (1.0 + omega_ascent * OMEGA_ASCENT_GAIN) * (1.0 - omega_descent * OMEGA_DESCENT_GAIN)

		# 凝结 vapor→cloud_water：动力(抬升/辐合)主导 + 静力过饱和(rh 超阈) + 热力对流。
		var sup: float = maxf(relative_humidity - RH_CONDENSE, 0.0)
		# 注:ψ(synoptic eddy)/base_lift/水汽辐合抽吸/ψ 主导降水 = C++-only(run_weather_field_solve_pass 内联全场推进),
		# 本 GDScript fallback 【不含 ψ】→ 退化为"无移动天气系统"的旧版(整数 hash 难 bit-perfect 双镜像,故有意未镜像)。
		# 其余确定性物理(omega/平流主导/对流/stratiform/云EMA/precip平滑/湖山冷区)已与 C++ 同步。
		var cond_force: float = clampf(sup * STATIC_COND_W + lift_pos * LIFT_COND_GAIN + convergence * CONV_COND_GAIN + frontogenesis * 1.35 + convective * THERMAL_CONV_COND + ocean_convective * 0.90 + stratiform * 0.75, 0.0, 1.0)  # Stage11 层状凝结
		cond_force *= 1.0 - post_rain_subsidence * 0.45

		cond_force *= 1.0 - omega_descent * OMEGA_DESCENT_COND   # 副热带下沉抑制凝结
		var condensation: float = vapor * cond_force * CONDENSE_RATE
		if lift < 0.0:
			condensation *= maxf(1.0 + lift * _weather_system._field_rain_shadow_drying, 0.0)
		condensation = clampf(condensation, 0.0, vapor * 0.92)
		vapor -= condensation

		# cloud_water 随风平流(搬运湿团) + 凝结加入 + 邻域扩散。复用 vapor 平流 helper(传 cloud_water)。
		var cloud_water: float = prev_cloud_water_arr[i] if prev_cloud_water_arr.size() == n_cells else 0.0
		if upstream_idx >= 0 and prev_cloud_water_arr.size() == n_cells:
			var cw_upwind: float = _upstream_vapor_idx_from_first(i, upstream_idx, cell_pos, neighbor_indices, prev_cloud_water_arr, wind_dir)
			var cw_neighbor: float = _neighbor_average_vapor_idx(i, neighbor_indices, prev_cloud_water_arr)
			var adv_w_c: float = minf(ADV_CLOUD * (0.55 + 0.45 * wind_mag), 0.98)
			cloud_water = lerpf(cloud_water, cw_upwind, adv_w_c)
			cloud_water = lerpf(cloud_water, cw_neighbor, _weather_system._field_diffusion)
		cloud_water = clampf(cloud_water + condensation, 0.0, 1.0)

		var instability: float = clampf(
			(temp - 0.48) * 0.80
			+ relative_humidity * 0.30
			+ convergence * 0.55
			+ lift_pos * 1.20
			+ frontogenesis * 0.55
			+ ocean_convective * 0.35,
			0.0, 1.0
		)

		# 降水：autoconversion 消耗 cloud_water。动力(辐合/抬升/不稳定)触发主导，地形弱增强；
		# 背景 base_frac 很小 → 无动力区降水压到 wet 阈值以下 → 只有移动天气系统处成雨 → 雨随系统移动。
		var trig: float = AUTOCONVERSION * (PRECIP_BASE_FRAC + lift_pos * LIFT_PRECIP_GAIN + convergence * CONV_PRECIP_GAIN + frontogenesis * 0.85 + instability * 0.30)
		trig *= (1.0 + lift_pos * ORO_PRECIP_GAIN)
		trig += convective * THERMAL_CONV_PRECIP   # 对流雨高效成雨，旁路 autoconv 瓶颈(内陆 cw 少)
		trig += ocean_convective * 0.95
		trig += stratiform * 0.80   # Stage11 层状降水高效成雨(冷/高/水区,旁路 autoconv)→修 #4湖/#5a雪/#6山
		trig = clampf(trig, 0.0, 0.95)
		var precip_target: float = cloud_water * trig
		precip_target *= omega_precip_mult   # Stage1 omega: ITCZ/风暴轴增雨 + 副热带下沉抑雨(纬向廓线)
		# Stage6e 对流抑制记忆(双稳)：读取累积抑制(本 tick 起始值)，硬阈压制移到最终降水处(EMA 之后)。
		var inhib_old: float = _convective_inhib[i] if _convective_inhib.size() == n_cells else 0.0
		if lift < 0.0:
			precip_target *= 1.0 - minf(maxf(-lift, 0.0) * _weather_system._field_rain_shadow_drying, 0.85)
		if has_river and river_recycle_lock > 0.0:
			var river_relief: float = river_recycle_lock * (1.0 - smoothstep(0.22, 0.50, dynamic_forcing))
			if river_relief > 0.0:
				var cloud_relief: float = cloud_water * 0.22 * river_relief
				cloud_water -= cloud_relief
				vapor += cloud_relief * 0.60
				precip_target *= 1.0 - 0.48 * river_relief
		# 水面对流抑制(保留动力门控：辐合/锋生/暖流异常 释放降水；instability 仅极端深对流安全阀)。
		var ocean_drive: float = 0.0
		if on_water:
			var drv_an: float = clampf(ocean_an / 0.16, 0.0, 1.0)
			var drv_in: float = clampf((instability - 0.52) / 0.30, 0.0, 1.0)
			var drv_cv: float = clampf((convergence - 0.38) / 0.16, 0.0, 1.0)
			var drv_fr: float = clampf(frontogenesis / 0.16, 0.0, 1.0)
			var drv_mn: float = clampf(coastal_monsoon_flux / 0.18, 0.0, 1.0)
			var drv_hc: float = smoothstep(0.47, 0.69, relative_humidity) \
				* smoothstep(0.040, 0.105, cloud_water) \
				* smoothstep(0.54, 0.74, temp)
			if is_lake:
				drv_hc *= 0.60
			drv_hc *= 0.68
			ocean_drive = maxf(maxf(drv_an, drv_in), maxf(maxf(drv_cv, drv_fr), maxf(drv_mn, drv_hc)))
			ocean_drive = maxf(ocean_drive, omega_ascent)   # ITCZ/风暴轴上升带释放海面降水抑制
			var precip_suppression: float = _weather_system._field_ocean_precip_suppression
			if is_lake:
				precip_suppression = minf(precip_suppression, 0.35)  # Stage9: 湖泊≈陆地降水(0.70→0.35)→湖区不再始终晴
			else:
				precip_suppression = minf(precip_suppression, 0.78)
			precip_target *= lerpf(1.0 - precip_suppression, 1.0, ocean_drive)
			var marine_relief: float = post_rain_subsidence * (1.0 - smoothstep(0.30, 0.58, ocean_drive))
			precip_target *= 1.0 - marine_relief * 0.72
		precip_target = minf(precip_target, cloud_water)
		precip_target = maxf(precip_target, 0.0)
		cloud_water = maxf(cloud_water - precip_target, 0.0)
		var precip_cloud_reserve: float = precip_target * (0.18 + dynamic_forcing * 0.18)
		cloud_water = minf(1.0, cloud_water + precip_cloud_reserve)
		var quiet_core: float = 1.0 - smoothstep(0.12, 0.50, dynamic_forcing)
		if on_water and ocean_drive < 0.34:
			var marine_scour: float = clampf(cloud_water * (0.036 + (0.34 - ocean_drive) * 0.18) * (1.0 + post_rain_subsidence * 1.60), 0.0, cloud_water)
			cloud_water -= marine_scour
			vapor += marine_scour * 0.55

		# 干空气云水再蒸发回 vapor（湿团边缘消散 → 闭合水量收支）。
		var reevap: float = clampf(cloud_water * _weather_system._field_cloud_reevap * (1.0 - relative_humidity) * (1.0 + post_rain_subsidence * 1.75 + quiet_core * 0.75), 0.0, cloud_water)
		cloud_water -= reevap
		vapor += reevap
		if on_water:
			vapor *= 1.0 - post_rain_subsidence * (1.0 - smoothstep(0.28, 0.58, ocean_drive)) * 0.045

		# 降水稳定性(地形阻尼 + 极端 soft cap) + EMA 时间惯性(保留)。
		precip_target = _weather_system._moderate_field_precip_for_terrain(int(soa_terrain[i]), precip_target)
		# Stage10 不应期(inhib≥1)作用于 target(EMA 前)→降水随惯性平滑衰减到近零，不再瞬间砍断(去时间跳变)。镜像 world_ext.cpp。
		if inhib_old >= 1.0:
			precip_target *= 1.0 - INHIB_STRENGTH
		var precip: float = lerpf(prev_precip[i], precip_target, _weather_system._field_precip_inertia)
		if precip_target < prev_precip[i] and dynamic_forcing < 0.20:
			precip = lerpf(precip, precip_target, post_rain_subsidence * 0.55)
		# Stage10b 空间平滑(非对称)：强填洞(0.30)、弱削峰(×0.30→保超级单体暴雨)。镜像 world_ext.cpp。
		var nbr_precip: float = _neighbor_average_vapor_idx(i, neighbor_indices, prev_precip) if fast_indexed else _neighbor_average_vapor_cached(cell, map, prev_precip)
		precip = lerpf(precip, nbr_precip, 0.30 if nbr_precip > precip else 0.09)
		var effective_precip_floor: float = 0.014 if on_water else 0.018
		if precip < 0.003:
			precip = 0.0
		var provisional_cloud: float = clampf(cloud_water * 1.10 + condensation * 0.25, 0.0, 1.0)
		var temp_anom_i: float = soa_temp_anom[i] if soa_temp_anom.size() == n_cells else 0.0
		var snow_cover_cls: float = _field_slice_snow_cover_read[i] if _field_slice_snow_cover_read.size() == n_cells else 0.0
		var pre_wt: int = _weather_system._classify_field_weather_at(temp, vapor, provisional_cloud, cloud_water, precip, instability, ocean_an, raw_wind_speed, temp_anom_i, maxf(onshore_moist_flux, coastal_monsoon_flux), on_water, snow_cover_cls)
		var quiet_non_precip: bool = not _weather_system._is_precip_weather_type(pre_wt) and quiet_core > 0.0
		if (precip < 0.003 or quiet_non_precip) and quiet_core > 0.0:
			var clear_cap: float = 0.065 + dynamic_forcing * 0.12
			if on_water and ocean_drive < 0.20:
				clear_cap = minf(clear_cap, 0.070 + ocean_drive * 0.18)
			if cloud_water > clear_cap:
				var excess_cloud_water: float = (cloud_water - clear_cap) * quiet_core
				cloud_water -= excess_cloud_water
				vapor += excess_cloud_water * 0.75
		if quiet_non_precip and precip < effective_precip_floor:
			vapor += precip * 0.65
			precip = 0.0
		vapor = clampf(vapor, 0.0, 1.0)
		var vapor_after_precip: float = vapor
		var rain_core: float = smoothstep(0.025, 0.095, precip)
		var front_core: float = smoothstep(0.08, 0.55, frontogenesis)
		var cloud_floor: float = maxf(rain_core * (0.14 + rain_core * 0.22), front_core * 0.30)
		if convective > 0.0:
			cloud_floor = maxf(cloud_floor, 0.06 + convective * 0.18)
		if ocean_convective > 0.0:
			cloud_floor = maxf(cloud_floor, 0.10 + ocean_convective * 0.16)
		if quiet_non_precip:
			var fair_humid: float = smoothstep(0.34, 0.56, relative_humidity)
			var fair_cloud_floor: float = fair_humid * quiet_core * (0.050 + fair_humid * 0.070)
			cloud_floor = maxf(cloud_floor, fair_cloud_floor)
		var cloud: float = clampf(maxf(cloud_water * 1.10 + condensation * 0.25, cloud_floor), 0.0, 1.0)
		if prev_cloud_arr.size() == n_cells:
			cloud = lerpf(prev_cloud_arr[i], cloud, _weather_system._field_cloud_inertia)  # Stage15 云量时间 EMA，镜像 C++ field_cloud_inertia

		var wt: int = _weather_system._classify_field_weather_at(temp, vapor, cloud, cloud_water, precip, instability, ocean_an, raw_wind_speed, temp_anom_i, maxf(onshore_moist_flux, coastal_monsoon_flux), on_water, snow_cover_cls)
		if not _weather_system._is_precip_weather_type(wt) and precip > 0.0:
			vapor = clampf(vapor + precip * 0.65, 0.0, 1.0)
			vapor_after_precip = vapor
			precip = 0.0
		elif precip > 0.0:
			# Stage6 放电：实际降水抽干本格水汽→气柱失水→RH降→自发停雨→需充电恢复(雨团生命周期+随上风新鲜水汽移动+海面自生成)。
			# Stage6b：持续降水(prev_precip 高)放电翻倍→定点清除"连下一周"长尾，不动新生短雨段。
			var discharge_amp: float = 1.0 + DISCHARGE_SUSTAIN * smoothstep(0.04, 0.10, prev_precip[i])
			vapor_after_precip = maxf(0.0, vapor_after_precip - precip * VAPOR_DISCHARGE * discharge_amp)
		var intensity: float = _weather_system._field_intensity_for_type(wt, temp, vapor, cloud, precip, instability, ocean_an)
		# Stage6g 更新对流抑制(按时长两段)：充能期连续降水累加→满进不应期；不应期衰减→落回清零重启。
		if _convective_inhib.size() == n_cells:
			var ni: float
			if inhib_old >= 1.0:
				ni = inhib_old - INHIB_REFRAC
				if ni < 1.0:
					ni = 0.0
			elif precip > INHIB_WET:
				ni = inhib_old + INHIB_CHARGE
				if ni >= 1.0:
					ni = 2.0
			else:
				ni = inhib_old * INHIB_LEAK
			_convective_inhib[i] = ni
		next_vapor[i] = vapor_after_precip
		next_cloud[i] = cloud
		next_cloud_water[i] = cloud_water
		next_precip[i] = precip
		next_instability[i] = instability
		next_type[i] = wt
		next_intensity[i] = intensity
		next_convergence[i] = convergence
	_field_slice_cursor = end_i
	var elapsed_ms: float = (Time.get_ticks_usec() - t_us0) / 1000.0
	_field_slice_solve_ms += elapsed_ms
	_field_slice_last_ms = elapsed_ms
	return {
		"done": _field_slice_cursor >= n_cells,
		"work_done": end_i - start_i,
		"elapsed_ms": elapsed_ms,
		"progress_ratio": float(_field_slice_cursor) / float(maxi(n_cells, 1)),
		"processed_cells": end_i - start_i,
		"cursor_start": start_i,
		"cursor_end": end_i,
	}


## 切片入口（搬迁 commit_weather_field_solve + slice 状态机后填充）。
## E.1 阶段返回空 fronts；F.1 C++ 化后由 caller 切到 DCWorldExt 路径。
func _ensure_weather_commit_arrays(map: MapData, n_cells: int) -> void:
	if map == null or n_cells <= 0:
		return
	if map.weather_intensity_arr.size() != n_cells:
		map.weather_intensity_arr.resize(n_cells)
	if map.weather_cloud_arr.size() != n_cells:
		map.weather_cloud_arr.resize(n_cells)
	if map.weather_cloud_water_arr.size() != n_cells:
		map.weather_cloud_water_arr.resize(n_cells)
	if map.weather_precip_arr.size() != n_cells:
		map.weather_precip_arr.resize(n_cells)
	if map.weather_type_arr.size() != n_cells:
		map.weather_type_arr.resize(n_cells)
	if map.weather_prev_type_arr.size() != n_cells:
		map.weather_prev_type_arr.resize(n_cells)
	if map.weather_target_type_arr.size() != n_cells:
		map.weather_target_type_arr.resize(n_cells)
	if map.weather_transition_alpha_arr.size() != n_cells:
		map.weather_transition_alpha_arr.resize(n_cells)
	if map.weather_vapor_arr.size() != n_cells:
		map.weather_vapor_arr.resize(n_cells)
	if map.weather_convergence_arr.size() != n_cells:
		map.weather_convergence_arr.resize(n_cells)
	if map.weather_instability_arr.size() != n_cells:
		map.weather_instability_arr.resize(n_cells)
	if map.weather_field_init_arr.size() != n_cells:
		map.weather_field_init_arr.resize(n_cells)
	if map.weather_dirty_mask.size() != n_cells:
		map.weather_dirty_mask.resize(n_cells)


func _weather_commit_visible(map: MapData, n_cells: int, transition_enabled: bool) -> Dictionary:
	var result: Dictionary = {
		"verified": false,
		"init_count": 0,
		"reason": "",
	}
	if map == null:
		result["reason"] = "map_null"
		return result
	if n_cells <= 0:
		result["verified"] = true
		result["reason"] = "empty"
		return result
	var init_arr: PackedByteArray = map.weather_field_init_arr
	if init_arr.size() != n_cells:
		result["reason"] = "field_init_size_%d_expected_%d" % [init_arr.size(), n_cells]
		return result
	var init_count: int = 0
	for i in range(n_cells):
		if init_arr[i] != 0:
			init_count += 1
	result["init_count"] = init_count
	if init_count != n_cells:
		result["reason"] = "field_init_incomplete_%d_of_%d" % [init_count, n_cells]
		return result
	if map.weather_vapor_arr.size() != n_cells \
			or map.weather_cloud_arr.size() != n_cells \
			or map.weather_cloud_water_arr.size() != n_cells \
			or map.weather_precip_arr.size() != n_cells \
			or map.weather_type_arr.size() != n_cells:
		result["reason"] = "visible_weather_array_size_mismatch"
		return result
	if _field_slice_next_vapor.size() != n_cells \
			or _field_slice_next_cloud.size() != n_cells \
			or _field_slice_next_precip.size() != n_cells \
			or _field_slice_next_type.size() != n_cells:
		result["reason"] = "next_weather_array_size_mismatch"
		return result
	var vapor_arr: PackedFloat32Array = map.weather_vapor_arr
	var cloud_arr: PackedFloat32Array = map.weather_cloud_arr
	var cloud_water_arr: PackedFloat32Array = map.weather_cloud_water_arr
	var precip_arr: PackedFloat32Array = map.weather_precip_arr
	var type_arr: PackedByteArray = map.weather_type_arr
	var sample_count: int = mini(n_cells, 64)
	var mismatch_count: int = 0
	for sample_i in range(sample_count):
		var idx: int = 0
		if sample_count > 1:
			idx = int(floor(float(sample_i * (n_cells - 1)) / float(sample_count - 1)))
		var mismatch: bool = false
		mismatch = mismatch or absf(vapor_arr[idx] - _field_slice_next_vapor[idx]) > 0.015
		mismatch = mismatch or absf(cloud_arr[idx] - _field_slice_next_cloud[idx]) > 0.015
		if _field_slice_next_cloud_water.size() == n_cells:
			mismatch = mismatch or absf(cloud_water_arr[idx] - _field_slice_next_cloud_water[idx]) > 0.015
		mismatch = mismatch or absf(precip_arr[idx] - _field_slice_next_precip[idx]) > 0.015
		if not transition_enabled:
			mismatch = mismatch or int(type_arr[idx]) != (int(_field_slice_next_type[idx]) & 0xFF)
		if mismatch:
			mismatch_count += 1
	if mismatch_count > 0:
		result["reason"] = "field_sample_mismatch_%d_of_%d" % [mismatch_count, sample_count]
		return result
	result["verified"] = true
	result["reason"] = "ok"
	return result


func commit() -> Array[WeatherFront]:
	# dots-monolith-split §1.2 / PR-5：从 weather_system.commit_weather_field_solve
	# 整段搬迁。所有 _field_slice_* 状态字段为本类成员（PR-4 搬过来）；
	# owner 字段（_active_fronts / _hexcell_facade_on / _data_core_world /
	# _apply_frontal_convergence_boost / _distribute_weather_field_to_cells /
	# _build_field_summary_fronts / _cyclone_wake_enabled / _advect /
	# _last_breakdown / _last_map_for_query / _current_map_for_tick /
	# _tick_cell_pos / _tick_cell_neighbors / _clear_weather_field_slice_state）
	# 通过 _weather_system.<field/method> 访问。
	if _weather_system == null:
		return [] as Array[WeatherFront]
	if not _field_slice_active:
		return _weather_system._active_fronts
	var t_commit_total_us: int = Time.get_ticks_usec()
	var map: MapData = _field_slice_map
	var world: WorldData = _field_slice_world
	var cells: Array = _field_slice_cells
	# v9c: 同时写 SoA 镜像数组，修复 flush_soa_to_cells() 用 SoA 反向覆盖 AoS
	# 导致 weather_type 被周期性清回 CLEAR 的问题。SoA 数组已 bind 到 DataCore
	# 的 CELL_WEATHER_INTENSITY/CLOUD/PRECIP/TYPE 4 个 component。
	var soa_intensity: PackedFloat32Array = map.weather_intensity_arr
	var soa_cloud: PackedFloat32Array = map.weather_cloud_arr
	var soa_cloud_water: PackedFloat32Array = map.weather_cloud_water_arr
	var soa_precip: PackedFloat32Array = map.weather_precip_arr
	var soa_type: PackedByteArray = map.weather_type_arr
	var soa_prev_type: PackedByteArray = map.weather_prev_type_arr
	var soa_target_type: PackedByteArray = map.weather_target_type_arr
	var soa_transition_alpha: PackedFloat32Array = map.weather_transition_alpha_arr
	# B-full Step-2：4 个新 SoA（vapor/convergence/instability/field_init）一并写出。
	# 与 weather_intensity/cloud/precip/type 一组，hot loop 自身的 11 个写入字段全部 SoA 化。
	var soa_vapor: PackedFloat32Array = map.weather_vapor_arr
	var soa_convergence: PackedFloat32Array = map.weather_convergence_arr
	var soa_instability: PackedFloat32Array = map.weather_instability_arr
	var soa_field_init: PackedByteArray = map.weather_field_init_arr
	var commit_n: int = cells.size()
	var commit_setup_ms: float = (Time.get_ticks_usec() - t_commit_total_us) / 1000.0
	var weather_dirty: PackedByteArray = map.weather_dirty_mask
	var weather_dirty_count: int = 0
	if weather_dirty.size() == commit_n:
		for di in range(commit_n):
			weather_dirty[di] = 0

	var t_commit_loop_us: int = Time.get_ticks_usec()
	var hexcell_facade_on: bool = _weather_system._hexcell_facade_on
	var cp_transition = _weather_system._cp_for_front_flag
	var transition_enabled: bool = cp_transition != null \
			and cp_transition.get("weather_transition_enabled") != null \
			and bool(cp_transition.weather_transition_enabled)
	var transition_rate: float = 1.0
	if transition_enabled and cp_transition.get("weather_transition_alpha_rate") != null:
		transition_rate = clampf(float(cp_transition.weather_transition_alpha_rate), 0.0, 1.0)
	# [dt-aware transition 2026-06-28] 镜像 world_ext_weather.cpp：过渡按游戏天数推进而非求解次数。
	# dt_days 取自与 C++ 同一份 native knobs（weather_system 用 _consume_weather_dt_days() 填入），缺省 1.0。
	var transition_dt_days: float = clampf(float(_field_slice_native_knobs.get("weather_transition_dt_days", 1.0)), 0.0, 30.0)
	var water_budget_error_acc: float = 0.0
	var commit_path: String = "gdscript"
	var commit_loop_ms: float = 0.0
	var native_commit_done: bool = false
	var native_weather_lut: PackedByteArray = PackedByteArray()
	var native_weather_lut_changed: bool = false
	var native_weather_lut_dirty_count: int = 0
	var native_weather_lut_full_rebuild: bool = false
	var commit_publish_verified: bool = false

	var commit_publish_repaired: bool = false
	var commit_visible_init_count: int = 0
	var commit_publish_reason: String = ""
	var convergence_delta_samples: PackedFloat32Array = PackedFloat32Array()
	var convergence_delta_count: int = 0
	if _field_slice_refresh_convergence and commit_n > 0:
		convergence_delta_samples.resize(commit_n)
	var native_wrote_next: bool = bool(_field_slice_native_knobs.get("weather_field_wrote_next", false))
	if _weather_system._use_gdext_weather_field_commit \
			and _weather_system._data_core_world_ext != null \
			and _field_slice_fast_indexed \
			and hexcell_facade_on \
			and native_wrote_next \
			and _field_slice_next_vapor.size() == commit_n \
			and _field_slice_next_cloud.size() == commit_n \
			and _field_slice_next_precip.size() == commit_n \
			and _field_slice_next_instability.size() == commit_n \
			and _field_slice_next_intensity.size() == commit_n \
			and _field_slice_next_convergence.size() == commit_n \
			and _field_slice_next_type.size() == commit_n:
		var commit_rc: Dictionary = _weather_system._try_run_weather_field_commit_gdext(map, commit_n)
		if float(commit_rc.get("elapsed_ms", -1.0)) >= 0.0:
			native_commit_done = true
			_field_slice_results_in_soa = true
			commit_path = str(commit_rc.get("path", "gdext_commit"))
			native_weather_lut = commit_rc.get("weather_lut", PackedByteArray())
			native_weather_lut_changed = bool(commit_rc.get("weather_lut_changed", false))
			native_weather_lut_dirty_count = int(commit_rc.get("weather_lut_dirty_count", 0))
			native_weather_lut_full_rebuild = bool(commit_rc.get("weather_lut_full_rebuild", false))
			weather_dirty_count = int(commit_rc.get("weather_dirty_count", 0))

			water_budget_error_acc = float(commit_rc.get("water_budget_error", 0.0)) * float(maxi(commit_n, 1))
			commit_loop_ms = float(commit_rc.get("commit_loop_ms", commit_rc.get("elapsed_ms", 0.0)))
			convergence_delta_count = int(commit_rc.get("weather_convergence_dirty_count", 0))
			if _field_slice_refresh_convergence:
				convergence_delta_samples = commit_rc.get("weather_convergence_deltas", PackedFloat32Array())
			var visible_check: Dictionary = _weather_commit_visible(map, commit_n, transition_enabled)
			commit_publish_verified = bool(visible_check.get("verified", false))
			commit_visible_init_count = int(visible_check.get("init_count", 0))
			commit_publish_reason = str(visible_check.get("reason", ""))
			if not commit_publish_verified:
				native_commit_done = false
				native_weather_lut = PackedByteArray()
				native_weather_lut_changed = false
				native_weather_lut_dirty_count = 0
				native_weather_lut_full_rebuild = false
				_field_slice_results_in_soa = false
				commit_publish_repaired = true

				commit_path = "gdext_commit_repaired_gdscript_publish"
				weather_dirty_count = 0
				water_budget_error_acc = 0.0
				commit_loop_ms = 0.0
				convergence_delta_count = 0
				if _field_slice_refresh_convergence:
					convergence_delta_samples = PackedFloat32Array()
					convergence_delta_samples.resize(commit_n)
				_ensure_weather_commit_arrays(map, commit_n)
				soa_intensity = map.weather_intensity_arr
				soa_cloud = map.weather_cloud_arr
				soa_cloud_water = map.weather_cloud_water_arr
				soa_precip = map.weather_precip_arr
				soa_type = map.weather_type_arr
				soa_prev_type = map.weather_prev_type_arr
				soa_target_type = map.weather_target_type_arr
				soa_transition_alpha = map.weather_transition_alpha_arr
				soa_vapor = map.weather_vapor_arr
				soa_convergence = map.weather_convergence_arr
				soa_instability = map.weather_instability_arr
				soa_field_init = map.weather_field_init_arr
				weather_dirty = map.weather_dirty_mask
				if weather_dirty.size() == commit_n:
					for repair_di in range(commit_n):
						weather_dirty[repair_di] = 0
				if not _weather_system._gdext_field_commit_warned_fallback:
					_weather_system._gdext_field_commit_warned_fallback = true
					push_warning("[weather] gdext field commit did not publish visible MapData (%s); repaired with GDScript publish for this tick" % commit_publish_reason)
	if not native_commit_done:
		for i in range(cells.size()):
			if _field_slice_results_in_soa and hexcell_facade_on and not transition_enabled:
				break
			var out_cell: HexCell = cells[i]
			var v_cloud: float = _field_slice_next_cloud[i]
			var v_cloud_water: float = _field_slice_next_cloud_water[i] if _field_slice_next_cloud_water.size() > i else v_cloud * 0.5
			var v_precip: float = _field_slice_next_precip[i]
			var v_type: int = _field_slice_next_type[i]
			var v_intensity: float = _field_slice_next_intensity[i]
			var v_vapor: float = _field_slice_next_vapor[i]
			var v_convergence: float = _field_slice_next_convergence[i]
			var v_instability: float = _field_slice_next_instability[i]
			if _field_slice_refresh_convergence and soa_convergence.size() > i:
				var conv_delta: float = absf(soa_convergence[i] - v_convergence)
				if conv_delta > 0.0005:
					convergence_delta_samples[convergence_delta_count] = conv_delta
					convergence_delta_count += 1
			var prev_budget_vapor: float = _field_slice_prev_vapor[i] if _field_slice_prev_vapor.size() > i else (soa_vapor[i] if soa_vapor.size() > i else 0.0)
			var prev_budget_cloud_water: float = soa_cloud_water[i] if soa_cloud_water.size() > i else 0.0
			water_budget_error_acc += absf((v_vapor + v_cloud_water + v_precip) - (prev_budget_vapor + prev_budget_cloud_water))
			var display_type: int = v_type
			var prev_type: int = v_type
			var target_type: int = v_type
			var alpha: float = 1.0
			if transition_enabled and soa_prev_type.size() > i \
					and soa_target_type.size() > i and soa_transition_alpha.size() > i:
				var current_display: int = v_type
				if soa_type.size() > i:
					current_display = int(soa_type[i])
				elif out_cell != null:
					current_display = out_cell.weather_type
				prev_type = int(soa_prev_type[i])
				target_type = int(soa_target_type[i])
				alpha = clampf(soa_transition_alpha[i], 0.0, 1.0)
				if target_type != v_type:
					prev_type = current_display
					target_type = v_type
					alpha = clampf(transition_rate * transition_dt_days, 0.0, 1.0) # [dt-aware] 当前求解即计入
				elif prev_type == target_type or current_display == target_type:
					prev_type = target_type
					alpha = 0.0
				else:
					alpha = clampf(alpha + transition_rate * transition_dt_days, 0.0, 1.0)
				display_type = target_type if alpha >= 1.0 else prev_type
				if alpha >= 1.0:
					prev_type = target_type
					alpha = 0.0
			# 任务 2：facade 开启后跳过 AoS 双写（SoA 由本函数末尾的 batch indexed 写入）。
			# facade=false 时仍保留 AoS 写，让 legacy reader（map_baker / map_generator）能读到值。
			if not hexcell_facade_on:
				out_cell.weather_field_initialized = true
				out_cell.weather_vapor = v_vapor
				out_cell.weather_cloud = v_cloud
				out_cell.weather_precip = v_precip
				out_cell.weather_instability = v_instability
				out_cell.weather_type = display_type
				out_cell.weather_prev_type = prev_type
				out_cell.weather_target_type = target_type
				out_cell.weather_transition_alpha = alpha
				out_cell.weather_intensity = v_intensity
				out_cell.weather_convergence = v_convergence
			# SoA 镜像（与 DCWorld view_f32 同引用；renderer 在 round 末经
			# flush_soa_to_cells() 拿一致快照）
			var weather_changed: bool = false
			if soa_vapor.size() > i:
				weather_changed = weather_changed or absf(soa_vapor[i] - v_vapor) > 0.002
			if soa_cloud.size() > i:
				weather_changed = weather_changed or absf(soa_cloud[i] - v_cloud) > 0.002
			if soa_cloud_water.size() > i:
				weather_changed = weather_changed or absf(soa_cloud_water[i] - v_cloud_water) > 0.002
			if soa_precip.size() > i:
				weather_changed = weather_changed or absf(soa_precip[i] - v_precip) > 0.002
			if soa_type.size() > i:
				weather_changed = weather_changed or int(soa_type[i]) != display_type
			if weather_changed and weather_dirty.size() == commit_n:
				if weather_dirty[i] == 0:
					weather_dirty_count += 1
				weather_dirty[i] = 1
				if _field_slice_fast_indexed and _field_slice_neighbor_indices.size() >= commit_n * 6:
					var nb_base: int = i * 6
					for nd in range(6):
						var nb_i: int = _field_slice_neighbor_indices[nb_base + nd]
						if nb_i >= 0 and nb_i < commit_n:
							if weather_dirty[nb_i] == 0:
								weather_dirty_count += 1
							weather_dirty[nb_i] = 1
			soa_intensity[i] = v_intensity
			soa_cloud[i] = v_cloud
			if soa_cloud_water.size() > i:
				soa_cloud_water[i] = v_cloud_water
			soa_precip[i] = v_precip
			soa_type[i] = display_type & 0xFF
			if soa_prev_type.size() > i:
				soa_prev_type[i] = prev_type & 0xFF
			if soa_target_type.size() > i:
				soa_target_type[i] = target_type & 0xFF
			if soa_transition_alpha.size() > i:
				soa_transition_alpha[i] = alpha
			soa_vapor[i] = v_vapor
			soa_convergence[i] = v_convergence
			soa_instability[i] = v_instability
			soa_field_init[i] = 1
		commit_loop_ms = (Time.get_ticks_usec() - t_commit_loop_us) / 1000.0
		var final_visible_check: Dictionary = _weather_commit_visible(map, commit_n, transition_enabled)
		commit_publish_verified = bool(final_visible_check.get("verified", false))
		commit_visible_init_count = int(final_visible_check.get("init_count", 0))
		if commit_publish_repaired:
			if not commit_publish_verified:
				commit_publish_reason = "%s; repair_%s" % [
					commit_publish_reason,
					str(final_visible_check.get("reason", "")),
				]
		else:
			commit_publish_reason = str(final_visible_check.get("reason", ""))
	# Full-field commit 始终覆盖 [0,n)，用 range 写避免构造 idx/value batch。
	var t_commit_dc_us: int = Time.get_ticks_usec()
	var _data_core_world = _weather_system._data_core_world
	if _data_core_world != null and commit_n > 0 and not _field_slice_results_in_soa:
		var _cid_wi: int = _data_core_world.component_id(DCComponentIds.CELL_WEATHER_INTENSITY)
		var world_reads_map_arrays: bool = _cid_wi >= 0 \
				and _data_core_world.has_method("is_external_component") \
				and bool(_data_core_world.is_external_component(_cid_wi))
		if commit_publish_repaired or not world_reads_map_arrays:
			if _cid_wi >= 0:
				_data_core_world.write_f32_range(_cid_wi, 0, soa_intensity)
			var _cid_wc: int = _data_core_world.component_id(DCComponentIds.CELL_WEATHER_CLOUD)
			if _cid_wc >= 0:
				_data_core_world.write_f32_range(_cid_wc, 0, soa_cloud)
			var _cid_wcw: int = _data_core_world.component_id(DCComponentIds.CELL_WEATHER_CLOUD_WATER)
			if _cid_wcw >= 0:
				_data_core_world.write_f32_range(_cid_wcw, 0, soa_cloud_water)
			var _cid_wp: int = _data_core_world.component_id(DCComponentIds.CELL_WEATHER_PRECIP)
			if _cid_wp >= 0:
				_data_core_world.write_f32_range(_cid_wp, 0, soa_precip)
			var _cid_wv: int = _data_core_world.component_id(DCComponentIds.CELL_WEATHER_VAPOR)
			if _cid_wv >= 0:
				_data_core_world.write_f32_range(_cid_wv, 0, soa_vapor)
			var _cid_wcv: int = _data_core_world.component_id(DCComponentIds.CELL_WEATHER_CONVERGENCE)
			if _cid_wcv >= 0:
				_data_core_world.write_f32_range(_cid_wcv, 0, soa_convergence)
			var _cid_wins: int = _data_core_world.component_id(DCComponentIds.CELL_WEATHER_INSTABILITY)
			if _cid_wins >= 0:
				_data_core_world.write_f32_range(_cid_wins, 0, soa_instability)
			var _cid_wt: int = _data_core_world.component_id(DCComponentIds.CELL_WEATHER_TYPE)
			if _cid_wt >= 0:
				_data_core_world.write_u8_range(_cid_wt, 0, soa_type)
			var _cid_wpt: int = _data_core_world.component_id(DCComponentIds.CELL_WEATHER_PREV_TYPE)
			if _cid_wpt >= 0:
				_data_core_world.write_u8_range(_cid_wpt, 0, soa_prev_type)
			var _cid_wtt: int = _data_core_world.component_id(DCComponentIds.CELL_WEATHER_TARGET_TYPE)
			if _cid_wtt >= 0:
				_data_core_world.write_u8_range(_cid_wtt, 0, soa_target_type)
			var _cid_wta: int = _data_core_world.component_id(DCComponentIds.CELL_WEATHER_TRANSITION_ALPHA)
			if _cid_wta >= 0:
				_data_core_world.write_f32_range(_cid_wta, 0, soa_transition_alpha)
			var _cid_wfi: int = _data_core_world.component_id(DCComponentIds.CELL_WEATHER_FIELD_INIT)
			if _cid_wfi >= 0:
				_data_core_world.write_u8_range(_cid_wfi, 0, soa_field_init)
	var commit_dc_ms: float = (Time.get_ticks_usec() - t_commit_dc_us) / 1000.0
	var commit_convergence_ms: float = 0.0
	if _field_slice_refresh_convergence and not _field_slice_native_convergence_boost:
		var t_commit_conv_us: int = Time.get_ticks_usec()
		_weather_system._apply_frontal_convergence_boost(map, cells, _field_slice_climate_anomaly, _field_slice_neighbor_indices, _field_slice_fast_indexed)
		commit_convergence_ms = (Time.get_ticks_usec() - t_commit_conv_us) / 1000.0
	var commit_total_ms: float = (Time.get_ticks_usec() - t_commit_total_us) / 1000.0
	if convergence_delta_samples.size() > convergence_delta_count:
		convergence_delta_samples.resize(convergence_delta_count)
	var convergence_delta_p95: float = _weather_system._percentile_abs_from_array(convergence_delta_samples, 0.95) if convergence_delta_count > 0 else 0.0

	var t_us0_field: int = Time.get_ticks_usec()
	# ─── Weather Hot-Path：dist fast-path（plan/weather-hotpath-cpp 任务 3）──
	# C++ 通路开关启用 + 方法签名 OK 时，先尝试 C++ pass；rc≥0 时跳过 GDScript。
	# 任务 4 实装 C++ 主体之前，C++ 始终返回 -1 → 自动 fallback；本接入点行为
	# 与原版 GDScript 调用完全等价（含 distribute_ms_field 计时口径）。
	var n_cells: int = cells.size()
	var distribute_ms_field: float = 0.0
	var dist_done_by_cpp: bool = false
	if _weather_system._use_gdext_weather_distribute and _weather_system._data_core_world_ext != null:
		if not _weather_system._gdext_dist_first_attempt_logged:
			_weather_system._gdext_dist_first_attempt_logged = true
			print("[weather/dist] first fast-path attempt: n_cells=%d ext_bound=%s" % [
				n_cells, str(_weather_system._data_core_world_ext != null)
			])
		# 任务 5 verify：开启时先 snapshot 5 个 SoA/AoS 字段，跑完 C++ 后由
		# _verify_gdext_distribute_against_gdscript 复位 + 跑 GDScript + 比对。
		var verify_on: bool = _weather_system._distribute_verify_enabled
		var snap_temp: PackedFloat32Array = PackedFloat32Array()
		var snap_moist: PackedFloat32Array = PackedFloat32Array()
		var snap_cover: PackedByteArray = PackedByteArray()
		var snap_acc: PackedInt32Array = PackedInt32Array()
		var snap_pre: PackedInt32Array = PackedInt32Array()
		if verify_on:
			snap_temp = map.temp_arr.duplicate()
			snap_moist = map.moisture_arr.duplicate()
			snap_cover = map.cover_arr.duplicate()
			snap_acc.resize(n_cells)
			snap_pre.resize(n_cells)
			var verify_cells: Array = map.iter_cells() if map.has_indices() else map.all_cells()
			for vi in range(n_cells):
				var vc: HexCell = verify_cells[vi]
				snap_acc[vi] = vc.accumulated_snow_days
				snap_pre[vi] = vc.pre_snow_cover
		var dist_rc: Dictionary = _weather_system._try_run_weather_distribute_gdext(map, n_cells)
		var dist_elapsed: float = float(dist_rc.get("elapsed_ms", -1.0))
		if dist_elapsed >= 0.0:
			distribute_ms_field = dist_elapsed
			# 把 C++ pass 写好的 cover_dirty 状态同步到 GDScript（dist 主路径
			# 在 GDScript 版里也只通过 _cover_dirty 让下游 cover atlas 决定是否重 bake）。
			_weather_system._cover_dirty = bool(dist_rc.get("cover_dirty", false)) or _weather_system._cover_dirty
			_weather_system._gdext_dist_runs += 1
			_weather_system._gdext_dist_total_ms += dist_elapsed
			if _weather_system._gdext_dist_runs == 1:
				print("[weather/dist] gdext path ACTIVE — first run elapsed=%.2fms (legacy GDScript baseline ≈ 11.6ms; charter target < 1.5ms)" % dist_elapsed)
			dist_done_by_cpp = true
			if verify_on:
				dist_rc["snap_temp"] = snap_temp
				dist_rc["snap_moist"] = snap_moist
				dist_rc["snap_cover"] = snap_cover
				dist_rc["snap_acc"] = snap_acc
				dist_rc["snap_pre"] = snap_pre
				_weather_system._verify_gdext_distribute_against_gdscript(map, n_cells, dist_rc)
		else:
			_weather_system._gdext_dist_fallbacks += 1
	if not dist_done_by_cpp:
		if _weather_system.has_method("_sync_weather_distribute_cache_to_cells"):
			_weather_system._sync_weather_distribute_cache_to_cells(map, n_cells)
		_weather_system._distribute_weather_field_to_cells(map)
		distribute_ms_field = (Time.get_ticks_usec() - t_us0_field) / 1000.0

	t_us0_field = Time.get_ticks_usec()
	# Weather Hot-Path（plan/weather-hotpath-cpp）任务 6：summary fronts pass
	# fast-path。flag + ext 非空时优先走 C++；rc<0 自动降级到 GDScript（节流告警）。
	# 任务 8：verify on 时先 snapshot C++ state，跑 C++ 取得 fronts_cpp 后，
	# 由 _verify_gdext_summary_against_gdscript 内部 restore + 跑 GDScript +
	# 比较；commit 始终用 fronts_cpp。
	var summary_done_by_cpp: bool = false
	if _weather_system._use_gdext_weather_summary and _weather_system._data_core_world_ext != null:
		if not _weather_system._gdext_summary_first_attempt_logged:
			_weather_system._gdext_summary_first_attempt_logged = true
			print("[weather/summary] first fast-path attempt: n_cells=%d ext_bound=%s" % [
				map.cell_count(), str(_weather_system._data_core_world_ext != null)
			])
		var summary_verify_on: bool = _weather_system._summary_verify_enabled
		if summary_verify_on and _weather_system._data_core_world_ext.has_method("snapshot_weather_summary_state"):
			_weather_system._data_core_world_ext.snapshot_weather_summary_state()
		var fronts_v: Variant = _weather_system._try_run_weather_summary_fronts_gdext(map, world)
		if fronts_v != null:
			var fronts_cpp: Array[WeatherFront] = fronts_v
			if summary_verify_on:
				_weather_system._verify_gdext_summary_against_gdscript(map, world, fronts_cpp)
			_weather_system._active_fronts = fronts_cpp
			summary_done_by_cpp = true
	if not summary_done_by_cpp:
		_weather_system._active_fronts = _weather_system._build_field_summary_fronts(map, world)
	var summary_ms: float = (Time.get_ticks_usec() - t_us0_field) / 1000.0

	var cyclone_ms_field: float = 0.0
	if _weather_system._cyclone_wake_enabled:
		t_us0_field = Time.get_ticks_usec()
		# dots-monolith-split §1.1：cyclone_wake 已迁出至 DCWeatherFrontAdvect。
		_weather_system._advect.tick_cyclone_wake(map)
		cyclone_ms_field = (Time.get_ticks_usec() - t_us0_field) / 1000.0

	var solve_ms: float = _field_slice_solve_ms
	var last_solve_ms: float = _field_slice_last_ms
	var breakdown: Dictionary = {
		"advance_ms": last_solve_ms,
		"spawn_ms": summary_ms,
		"distribute_ms": distribute_ms_field,
		"cyclone_ms": cyclone_ms_field,
		"field_solve_ms": last_solve_ms,
		"field_solve_total_ms": solve_ms,
		"field_summary_ms": summary_ms,
		"field_commit_total_ms": commit_total_ms,
		"field_commit_setup_ms": commit_setup_ms,
		"field_commit_loop_ms": commit_loop_ms,
		"field_commit_path": commit_path,
		"field_commit_publish_verified": commit_publish_verified,
		"field_commit_publish_repaired": commit_publish_repaired,
		"field_commit_init_count": commit_visible_init_count,
		"field_commit_publish_reason": commit_publish_reason,
		"field_commit_dc_ms": commit_dc_ms,
		"field_commit_convergence_ms": commit_convergence_ms,
		"field_solve_tick": _weather_system._field_solve_tick,
		"field_convergence_refresh_stride": _weather_system._field_convergence_refresh_stride,
		"refresh_convergence": _field_slice_refresh_convergence,
		"native_convergence_boost": _field_slice_native_convergence_boost,
		"weather_convergence_dirty_count": convergence_delta_count,
		"weather_convergence_delta_p95": convergence_delta_p95,
		"convergence_published": _field_slice_refresh_convergence \
				and (_field_slice_native_convergence_boost or commit_convergence_ms > 0.0 or convergence_delta_count > 0),
		"weather_dirty_count": weather_dirty_count,
		"weather_lut": native_weather_lut,
		"weather_lut_changed": native_weather_lut_changed,
		"weather_lut_dirty_count": native_weather_lut_dirty_count,
		"weather_lut_full_rebuild": native_weather_lut_full_rebuild,
		"water_budget_error": water_budget_error_acc / float(maxi(commit_n, 1)),

		"active_weather_ratio": float(weather_dirty_count) / float(maxi(commit_n, 1)),
		"weather_tick_ms": last_solve_ms + distribute_ms_field + summary_ms + cyclone_ms_field,
	}
	breakdown.merge(_weather_system._front_diagnostic_counts(_weather_system._active_fronts), true)
	breakdown.merge(_weather_system._mark_weather_commit_tick(), true)
	_weather_system._last_breakdown = breakdown
	# 任务 9：节流式回归告警（dist/summary 各自门槛 × 2 ring buffer 检测）
	_weather_system.push_dist_perf_sample(distribute_ms_field)
	_weather_system.push_summary_perf_sample(summary_ms)
	_weather_system._last_map_for_query = map
	_weather_system._current_map_for_tick = null
	_weather_system._tick_cell_pos.clear()
	_weather_system._tick_cell_neighbors.clear()
	_weather_system._clear_weather_field_slice_state()
	return _weather_system._active_fronts


## 是否所有 declared component 都已 ready（与 weather_refresh_job.data_core_field_ready 同义）。
func is_data_core_ready() -> bool:
	if _weather_system == null:
		return false
	# Delegate to weather_system if it has the check; future: own check
	return false


func describe() -> String:
	return "DCWeatherFieldSolver(owner=%s)" % ("weather_system" if _weather_system != null else "(null)")


# region PR-1 — neighbor / advect helpers (dots-monolith-split §1.2 / PR-1)
#
# 9 个无状态 helper 已从 weather_system.gd 整体搬迁到 field_solver。weather_system
# 端原同名 `_xxx` 私有方法保留为薄转发，所有 hot-loop / 物理项 helper / owner 自身
# 的内部调用都最终落到下面的实现上。
#
# 依赖（通过 _weather_system 访问）：
#   - _weather_system._field_advect_steps      : int     业务旋钮（保留在 weather_system）
#   - _weather_system._hex_size                : float   网格尺度
#   - _weather_system._cell_neighbors(cell,map): Array   1 环邻居（HexCell）
#   - _weather_system._cell_world_pos(cell)    : Vector2 世界坐标
#   - _weather_system._prev_vapor_cached(...)  : float   PackedFloat32Array 视图取值
#
# 所有跨 helper 调用走 self.xxx（同类内），保证 weather_system 转发后语义不变。

func _upstream_vapor(cell: HexCell, map: MapData, prev_vapor: Dictionary, wind_dir: Vector2) -> float:
	# 修（v3）：原版以 cell 自身为锚（weight=1.0）+ 上游 1/2,1/3,1/4 → cell 自己占 48%
	# → 上游链根本拽不动场，这是"风动不明显"的真凶（lerp 权重再高也救不回来）。
	# 现在：完全不含自己，仅看上游链，权重高 → 远 → 低，让 vapor 真正随风迁移。
	if _weather_system == null:
		return float(prev_vapor.get(cell, cell.moisture)) if cell != null else 0.0
	var current: HexCell = cell
	var sum_v: float = 0.0
	var weight: float = 0.0
	var w_decay: float = 1.0
	for step in range(_weather_system._field_advect_steps):
		var upstream: HexCell = _neighbor_aligned(current, map, -wind_dir)
		if upstream == null:
			break
		sum_v += float(prev_vapor.get(upstream, upstream.moisture)) * w_decay
		weight += w_decay
		w_decay *= 0.75  # 1.0 → 0.75 → 0.56 → 0.42 → 0.32 → 0.24，6 跳更长尾
		current = upstream
	if weight < 0.001:
		# 边缘格子无上游：fallback 到自身（避免 0 vapor）
		return float(prev_vapor.get(cell, cell.moisture))
	return sum_v / weight

func _neighbor_average_vapor(cell: HexCell, map: MapData, prev_vapor: Dictionary) -> float:
	if _weather_system == null or cell == null:
		return 0.0
	var sum_v: float = float(prev_vapor.get(cell, cell.moisture))
	var n: int = 1
	for nb: HexCell in _weather_system._cell_neighbors(cell, map):
		if nb == null:
			continue
		sum_v += float(prev_vapor.get(nb, nb.moisture))
		n += 1
	return sum_v / float(maxi(n, 1))

func _upstream_vapor_cached(cell: HexCell, map: MapData, prev_vapor: PackedFloat32Array, wind_dir: Vector2) -> float:
	if _weather_system == null:
		return 0.0
	var current: HexCell = cell
	var sum_v: float = 0.0
	var weight: float = 0.0
	var w_decay: float = 1.0
	for step in range(_weather_system._field_advect_steps):
		var upstream: HexCell = _neighbor_aligned(current, map, -wind_dir)
		if upstream == null:
			break
		sum_v += _weather_system._prev_vapor_cached(upstream, map, prev_vapor) * w_decay
		weight += w_decay
		w_decay *= 0.75
		current = upstream
	if weight < 0.001:
		return _weather_system._prev_vapor_cached(cell, map, prev_vapor)
	return sum_v / weight

func _neighbor_average_vapor_cached(cell: HexCell, map: MapData, prev_vapor: PackedFloat32Array) -> float:
	if _weather_system == null or cell == null:
		return 0.0
	var sum_v: float = _weather_system._prev_vapor_cached(cell, map, prev_vapor)
	var n: int = 1
	for nb: HexCell in _weather_system._cell_neighbors(cell, map):
		if nb == null:
			continue
		sum_v += _weather_system._prev_vapor_cached(nb, map, prev_vapor)
		n += 1
	return sum_v / float(maxi(n, 1))

func _wrapped_delta(a: Vector2, b: Vector2, wrap_width_x: float) -> Vector2:
	var dx: float = b.x - a.x
	if wrap_width_x > 0.001:
		var half: float = wrap_width_x * 0.5
		if dx > half:
			dx -= wrap_width_x
		elif dx < -half:
			dx += wrap_width_x
	return Vector2(dx, b.y - a.y)

func _world_wrap_width_x(map: MapData) -> float:
	if map == null or map.width <= 0 or _weather_system == null:
		return 0.0
	return float(map.width) * sqrt(3.0) * _weather_system._hex_size

func _neighbor_aligned_idx(idx: int, dir: Vector2, cell_pos: PackedVector2Array, neighbor_indices: PackedInt32Array) -> int:
	if idx < 0 or idx >= cell_pos.size() or dir.length_squared() <= 0.0001:
		return -1
	if _weather_system == null:
		return -1
	var self_wp: Vector2 = cell_pos[idx]
	var best_idx: int = -1
	var best_dot: float = maxf(_field_slice_cell_pos_scale, 0.001) * 0.31176915 # sqrt(3) * 0.18
	var ndir: Vector2 = dir.normalized()
	var base: int = idx * 6
	for d in range(6):
		var nb_idx: int = neighbor_indices[base + d]
		if nb_idx < 0:
			continue
		var to_nb: Vector2 = _wrapped_delta(self_wp, cell_pos[nb_idx], _field_slice_wrap_width_x)
		var dot: float = to_nb.dot(ndir)
		if dot > best_dot:
			best_dot = dot
			best_idx = nb_idx
	return best_idx

func _upstream_vapor_idx(idx: int, cell_pos: PackedVector2Array, neighbor_indices: PackedInt32Array, prev_vapor: PackedFloat32Array, wind_dir: Vector2) -> float:
	if _weather_system == null:
		return prev_vapor[idx] if idx >= 0 and idx < prev_vapor.size() else 0.0
	var current_idx: int = idx
	var sum_v: float = 0.0
	var weight: float = 0.0
	var w_decay: float = 1.0
	for step in range(_weather_system._field_advect_steps):
		var upstream_idx: int = _neighbor_aligned_idx(current_idx, -wind_dir, cell_pos, neighbor_indices)
		if upstream_idx < 0:
			break
		sum_v += prev_vapor[upstream_idx] * w_decay
		weight += w_decay
		w_decay *= 0.75
		current_idx = upstream_idx
	if weight < 0.001:
		return prev_vapor[idx]
	return sum_v / weight

func _upstream_vapor_idx_from_first(idx: int, first_upstream_idx: int, cell_pos: PackedVector2Array, neighbor_indices: PackedInt32Array, prev_vapor: PackedFloat32Array, wind_dir: Vector2) -> float:
	if _weather_system == null:
		return prev_vapor[idx] if idx >= 0 and idx < prev_vapor.size() else 0.0
	if first_upstream_idx < 0 or _weather_system._field_advect_steps <= 0:
		return prev_vapor[idx]
	var current_idx: int = first_upstream_idx
	var sum_v: float = prev_vapor[current_idx]
	var weight: float = 1.0
	var w_decay: float = 0.75
	for step in range(1, _weather_system._field_advect_steps):
		var upstream_idx: int = _neighbor_aligned_idx(current_idx, -wind_dir, cell_pos, neighbor_indices)
		if upstream_idx < 0:
			break
		sum_v += prev_vapor[upstream_idx] * w_decay
		weight += w_decay
		w_decay *= 0.75
		current_idx = upstream_idx
	return sum_v / weight

func _neighbor_average_vapor_idx(idx: int, neighbor_indices: PackedInt32Array, prev_vapor: PackedFloat32Array) -> float:
	var sum_v: float = prev_vapor[idx]
	var n: int = 1
	var base: int = idx * 6
	for d in range(6):
		var nb_idx: int = neighbor_indices[base + d]
		if nb_idx < 0:
			continue
		sum_v += prev_vapor[nb_idx]
		n += 1
	return sum_v / float(n)

## ─── NS 化 Phase 0:六分扇形 barycentric(半拉格朗日终点插值)─────────────
## SAME_SOURCE 数学定义:C++ 镜像 gdext/src/world_ext_internal.h::
## pk_hex_sextant_barycentric()。给定回溯终点 target 与宿主 cell cur,在 cur 与
## 其 1-ring 邻居组成的 6 个扇形三角形 (cur, nb_s, nb_{s+1}) 中寻找包含
## target 的三角形,返回 {i0=cur, i1, i2, w0, w1, w2}。权重 clamp 到 [0,1]
## 且和恒为 1(单调、无 overshoot);邻居缺失的扇形跳过,全部缺失退化为
## (cur,cur,cur,1,0,0)。x 方向按 wrap_period_x 最小映像折叠(≤0.001 不环绕)。
## 静态纯函数:供 physical_circulation_solver.gd(风场镜像动量自平流)与未来
## GDScript 侧 SL 消费复用。
static func hex_sextant_barycentric(cur: int, target: Vector2,
		cell_pos: PackedVector2Array, neighbor_indices: PackedInt32Array,
		wrap_period_x: float) -> Dictionary:
	var out: Dictionary = {"i0": cur, "i1": cur, "i2": cur, "w0": 1.0, "w1": 0.0, "w2": 0.0}
	var n_cells: int = cell_pos.size()
	if cur < 0 or cur >= n_cells:
		return out
	var c: Vector2 = cell_pos[cur]
	var dx: float = target.x - c.x
	var dy: float = target.y - c.y
	if wrap_period_x > 0.001:
		var half: float = wrap_period_x * 0.5
		if dx > half:
			dx -= wrap_period_x
		elif dx < -half:
			dx += wrap_period_x
	var base: int = cur * 6
	var best_score: float = -2.0
	var best_a: int = -1
	var best_b: int = -1
	var best_u1: float = 0.0
	var best_u2: float = 0.0
	for s in range(6):
		var a: int = neighbor_indices[base + s]
		var b: int = neighbor_indices[base + ((s + 1) % 6)]
		if a < 0 or a >= n_cells or b < 0 or b >= n_cells:
			continue
		var eax: float = cell_pos[a].x - c.x
		var eay: float = cell_pos[a].y - c.y
		var ebx: float = cell_pos[b].x - c.x
		var eby: float = cell_pos[b].y - c.y
		if wrap_period_x > 0.001:
			var half: float = wrap_period_x * 0.5
			if eax > half:
				eax -= wrap_period_x
			elif eax < -half:
				eax += wrap_period_x
			if ebx > half:
				ebx -= wrap_period_x
			elif ebx < -half:
				ebx += wrap_period_x
		var det: float = eax * eby - eay * ebx
		if det > -1e-7 and det < 1e-7:
			continue
		var inv_det: float = 1.0 / det
		var u1: float = (dx * eby - dy * ebx) * inv_det
		var u2: float = (eax * dy - eay * dx) * inv_det
		if u1 < -1e-4 or u2 < -1e-4:
			continue
		var score: float = 1.0 - u1 - u2
		if score > best_score:
			best_score = score
			best_a = a
			best_b = b
			best_u1 = u1
			best_u2 = u2
			if score >= 0.0:
				break
	if best_a < 0:
		return out
	var c1: float = clampf(best_u1, 0.0, 1.0)
	var c2: float = clampf(best_u2, 0.0, 1.0)
	var c0: float = 1.0 - c1 - c2
	if c0 < 0.0:
		var inv_sum: float = 1.0 / (c1 + c2)
		c1 *= inv_sum
		c2 *= inv_sum
		c0 = 0.0
	out["i1"] = best_a
	out["i2"] = best_b
	out["w0"] = c0
	out["w1"] = c1
	out["w2"] = c2
	return out

func _neighbor_aligned(cell: HexCell, map: MapData, dir: Vector2) -> HexCell:
	if cell == null or dir.length_squared() <= 0.0001:
		return null
	if _weather_system == null:
		return null
	var neighbors: Array = _weather_system._cell_neighbors(cell, map)
	if neighbors.is_empty():
		return null
	var self_wp: Vector2 = _weather_system._cell_world_pos(cell)
	var best: HexCell = null
	var best_dot: float = 0.18
	var ndir: Vector2 = dir.normalized()
	for nb: HexCell in neighbors:
		if nb == null:
			continue
		var nb_wp: Vector2 = _weather_system._cell_world_pos(nb)
		var to_nb: Vector2 = _wrapped_delta(self_wp, nb_wp, _world_wrap_width_x(map))
		if to_nb.length_squared() <= 0.0001:
			continue
		var d: float = to_nb.normalized().dot(ndir)
		if d > best_dot:
			best_dot = d
			best = nb
	return best
# endregion PR-1


# region PR-2 — orographic lift / wind convergence helpers (dots-monolith-split §1.2 / PR-2)
#
# 5 个物理项 helper 已从 weather_system.gd 整体搬迁到 field_solver。weather_system
# 端原同名 `_xxx` 私有方法保留为薄转发；hot loop 内 6 处调用点（line 840/843、
# 1278/1281、1429/1432）保持不变，最终都落到下面的实现。
#
# 依赖（通过 _weather_system 访问）：
#   - _weather_system._cell_neighbors(cell,map): Array   1 环邻居（HexCell）
#   - _weather_system._cell_world_pos(cell)    : Vector2 世界坐标
# 跨 helper 内部调用走 self._neighbor_aligned* 等（同类内的 PR-1 实现）。

func _orographic_lift_for_cell(cell: HexCell, map: MapData, wind_dir: Vector2) -> float:
	var upstream: HexCell = _neighbor_aligned(cell, map, -wind_dir)
	if upstream == null:
		return 0.0
	var diff: float = cell.elevation - upstream.elevation
	if diff > 0.02:
		return clampf(diff * 2.2, 0.0, 1.0)
	if diff < -0.02:
		return clampf(diff * 1.6, -1.0, 0.0)
	return 0.0

func _orographic_lift_idx(idx: int, cells: Array, cell_pos: PackedVector2Array, neighbor_indices: PackedInt32Array, wind_dir: Vector2) -> float:
	var upstream_idx: int = _neighbor_aligned_idx(idx, -wind_dir, cell_pos, neighbor_indices)
	if upstream_idx < 0:
		return 0.0
	var cell: HexCell = cells[idx]
	var upstream: HexCell = cells[upstream_idx]
	var diff: float = cell.elevation - upstream.elevation
	if diff > 0.02:
		return clampf(diff * 2.2, 0.0, 1.0)
	if diff < -0.02:
		return clampf(diff * 1.6, -1.0, 0.0)
	return 0.0

func _orographic_lift_from_upstream_idx(idx: int, upstream_idx: int, cells: Array) -> float:
	if upstream_idx < 0:
		return 0.0
	var cell: HexCell = cells[idx]
	var upstream: HexCell = cells[upstream_idx]
	var diff: float = cell.elevation - upstream.elevation
	if diff > 0.02:
		return clampf(diff * 2.2, 0.0, 1.0)
	if diff < -0.02:
		return clampf(diff * 1.6, -1.0, 0.0)
	return 0.0

func _wind_convergence_for_cell(cell: HexCell, map: MapData) -> float:
	if _weather_system == null or cell == null:
		return 0.0
	var self_wp: Vector2 = _weather_system._cell_world_pos(cell)
	var wrap_width_x: float = _world_wrap_width_x(map)
	var incoming: float = 0.0
	var checked: int = 0
	for nb: HexCell in _weather_system._cell_neighbors(cell, map):
		if nb == null:
			continue
		var nb_wp: Vector2 = _weather_system._cell_world_pos(nb)
		var dir_to_self: Vector2 = _wrapped_delta(nb_wp, self_wp, wrap_width_x)
		if dir_to_self.length_squared() <= 0.0001:
			continue
		var wind: Vector2 = nb.wind_vector
		if wind.length_squared() <= 0.0001:
			continue
		incoming += maxf(0.0, dir_to_self.normalized().dot(wind.normalized()))
		checked += 1
	if checked == 0:
		return 0.0
	return clampf(incoming / float(checked), 0.0, 1.0)

func _wind_convergence_idx(idx: int, cells: Array, cell_pos: PackedVector2Array, neighbor_indices: PackedInt32Array) -> float:
	var self_wp: Vector2 = cell_pos[idx]
	var incoming: float = 0.0
	var checked: int = 0
	var base: int = idx * 6
	for d in range(6):
		var nb_idx: int = neighbor_indices[base + d]
		if nb_idx < 0:
			continue
		var dir_to_self: Vector2 = _wrapped_delta(cell_pos[nb_idx], self_wp, _field_slice_wrap_width_x)
		if dir_to_self.length_squared() <= 0.0001:
			continue
		var nb: HexCell = cells[nb_idx]
		var wind: Vector2 = nb.wind_vector
		if wind.length_squared() <= 0.0001:
			continue
		incoming += maxf(0.0, dir_to_self.normalized().dot(wind.normalized()))
		checked += 1
	if checked == 0:
		return 0.0
	return clampf(incoming / float(checked), 0.0, 1.0)
# endregion PR-2


# region PR-3 — ocean anomaly helpers (dots-monolith-split §1.2 / PR-3)
#
# 2 个海洋温度偏移 helper 已从 weather_system.gd 整体搬迁到 field_solver。
# weather_system 端原同名 `_xxx` 私有方法保留为薄转发；hot loop 内 4 处 `_idx`
# 调用点（line 807/1249/1382/1666）与 2 处 cell 版本调用点（line 2760/2773）保持
# 不变，最终都落到下面的实现。
#
# 依赖（通过 _weather_system 访问）：
#   - _weather_system._is_water_terrain(t)     : bool
#   - _weather_system._cell_neighbors(cell,map): Array

func _avg_ocean_anomaly_at_idx(idx: int, cells: Array, neighbor_indices: PackedInt32Array) -> float:
	if _weather_system == null:
		return 0.0
	var cell: HexCell = cells[idx]
	if _weather_system._is_water_terrain(int(cell.terrain)):
		return cell.temperature_transport_anomaly
	var sum_an: float = 0.0
	var n_water: int = 0
	var base: int = idx * 6
	for d in range(6):
		var nb_idx: int = neighbor_indices[base + d]
		if nb_idx < 0:
			continue
		var nb: HexCell = cells[nb_idx]
		if _weather_system._is_water_terrain(int(nb.terrain)):
			sum_an += nb.temperature_transport_anomaly
			n_water += 1
	if n_water == 0:
		return 0.0
	return sum_an / float(n_water)

func _avg_ocean_anomaly_at(cell: HexCell, map: MapData) -> float:
	if cell == null or _weather_system == null:
		return 0.0
	# 海面 cell：直接读自身洋流偏差
	if _weather_system._is_water_terrain(int(cell.terrain)):
		return cell.temperature_transport_anomaly
	var sum_an: float = 0.0
	var n_water: int = 0
	for nb: HexCell in _weather_system._cell_neighbors(cell, map):
		if nb != null and _weather_system._is_water_terrain(int(nb.terrain)):
			sum_an += nb.temperature_transport_anomaly
			n_water += 1
	if n_water == 0:
		return 0.0
	return sum_an / float(n_water)
# endregion PR-3


# region PR-4 — slice state machine fields (dots-monolith-split §1.2 / PR-4)
#
# 22 个 _field_slice_* 切片状态字段已从 weather_system.gd 整体搬迁到 field_solver。
# weather_system 端原 22 个 `var _field_slice_xxx` 字段定义全部删除；所有 184 处
# 访问点（begin_weather_field_solve / run_weather_field_solve_slice /
# commit_weather_field_solve / _clear_weather_field_slice_state 内部读写）改为
# `_field_solver._field_slice_xxx` 形式访问。
#
# 这些字段在 PR-5 / PR-6 把 commit / solve 主体搬过来后会自然变为 self.* 内部访问。
# 当前阶段它们仍被 weather_system 内的 begin / commit / solve 体读写，因此
# 命名保持 `_field_slice_xxx` 不加额外前缀。

var _field_slice_active: bool = false
var _field_slice_map: MapData = null
var _field_slice_world: WorldData = null
var _field_slice_season_idx: int = 0
var _field_slice_climate_anomaly: float = 0.0
var _field_slice_cursor: int = 0
# climate-realism Stage1: 「热赤道」纬度(norm)，begin_slice 按 zonal-max 温度逐 tick 算，omega 项消费。
var _field_slice_lat_te_norm: float = 0.5
var _field_slice_refresh_convergence: bool = false
var _field_slice_cells: Array = []
var _field_slice_cell_pos: PackedVector2Array = PackedVector2Array()
var _field_slice_neighbor_indices: PackedInt32Array = PackedInt32Array()
var _field_slice_fast_indexed: bool = false
var _field_slice_temp_read: PackedFloat32Array = PackedFloat32Array()
var _field_slice_moisture_read: PackedFloat32Array = PackedFloat32Array()
var _field_slice_snow_cover_read: PackedFloat32Array = PackedFloat32Array()
var _field_slice_prev_vapor: PackedFloat32Array = PackedFloat32Array()
var _field_slice_prev_precip: PackedFloat32Array = PackedFloat32Array()
var _field_slice_next_vapor: PackedFloat32Array = PackedFloat32Array()
var _field_slice_next_cloud: PackedFloat32Array = PackedFloat32Array()
var _field_slice_next_cloud_water: PackedFloat32Array = PackedFloat32Array()
var _field_slice_next_precip: PackedFloat32Array = PackedFloat32Array()
var _field_slice_next_instability: PackedFloat32Array = PackedFloat32Array()
var _field_slice_next_intensity: PackedFloat32Array = PackedFloat32Array()
var _field_slice_next_convergence: PackedFloat32Array = PackedFloat32Array()
var _field_slice_next_type: PackedInt32Array = PackedInt32Array()
var _field_slice_solve_ms: float = 0.0
var _field_slice_last_ms: float = 0.0
var _field_slice_results_in_soa: bool = false
var _field_slice_native_convergence_boost: bool = false
var _field_slice_temp_anom: PackedFloat32Array = PackedFloat32Array()
var _field_slice_native_knobs: Dictionary = {}
var _field_slice_wrap_width_x: float = 0.0
var _field_slice_cell_pos_scale: float = 1.0
var _cached_cell_pos: PackedVector2Array = PackedVector2Array()
var _cached_cell_pos_map_id: int = 0
var _cached_cell_pos_n: int = 0
var _cached_cell_pos_hex_size: float = -1.0
# Stage6c: 对流抑制记忆(per-cell)，跨 slice/tick 持久(不在 begin_slice 重置)。本地状态，非 SoA 组件、不入 CSV。
# 经 knobs "convective_inhib" 以 in/out 传给 C++(ptrw 原地更新，调用后读回)。GDScript fallback 直接读写本数组。
var _convective_inhib: PackedFloat32Array = PackedFloat32Array()
# endregion PR-4
