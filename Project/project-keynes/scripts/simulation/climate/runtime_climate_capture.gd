extends "res://scripts/simulation/generator_context.gd"

const ClimateReference = preload("res://scripts/simulation/climate/runtime_climate_reference.gd")

const RuntimeClimateHash = preload("res://scripts/simulation/runtime_climate_hash.gd")

## Runtime climate input capture, parity reference publish, and capture diagnostics. Session state remains on MapGenerator.


# Only set while packing one worker input on the main thread.
var calendar_day := -1

func sample_day() -> float:
	if calendar_day >= 0:
		return float(calendar_day)
	var clock = _generator._world_clock_ref
	return float(clock.current_day) if clock != null else 0.0

func sample_anomaly() -> float:
	var clock = _generator._world_clock_ref
	if clock == null:
		return 0.0
	if calendar_day >= 0 and clock.has_method("climate_anomaly_for_day"):
		return float(clock.climate_anomaly_for_day(calendar_day))
	var value = clock.get("climate_anomaly")
	return float(value) if value != null else 0.0

func _build_runtime_climate_stage_knobs(map: MapData, day: int,
		authoritative: bool, defer_thermal_equator: bool = false,
		session_seed: bool = false) -> Dictionary:
	if not authoritative or map == null:
		return {}
	var cp_now = _generator._c()
	if cp_now == null:
		return {}
	# Physical circulation has its own cadence. Always transport its immutable
	# profile, including on days when the weather round is not due.
	var out: Dictionary = {}
	if _generator._baker != null:
		var physics: Dictionary = _generator._baker.runtime_physics_knobs()
		if not physics.is_empty():
			physics["enabled"] = bool(cp_now.physical_circulation_enabled)
			physics["daily_split"] = bool(cp_now.daily_wind_split_passes)
			physics["daily_period_days"] = maxi(1, int(cp_now.ocean_daily_wind_period_ticks))
			physics["ocean_period_days"] = maxi(1, int(cp_now.ocean_currents_period_ticks))
			physics["world_seed"] = _generator._last_seed
			out["physics_knobs"] = physics
	if not session_seed and day != _generator._runtime_climate_worker_weather_embed_day:
		_generator._runtime_climate_worker_weather_embed_day = day
		_generator._runtime_climate_worker_stage_b_call_index += 1
	var stage_index: int = 0 if session_seed else _generator._runtime_climate_worker_stage_b_call_index
	var stage_b: Dictionary = _generator._get_native_daily_bundle_builder()._build_native_daily_stage_b_knobs(
		map, cp_now, stage_index, 1.0, 0 if session_seed else day + 1)
	if not stage_b.is_empty():
		out["stage_b"] = stage_b
	# The worker reuses the production precipitation and snowpack configuration.
	if _generator._weather_system != null \
			and _generator._weather_system.has_method("build_distribute_knobs_for_worker"):
		var dist: Dictionary = _generator._weather_system.build_distribute_knobs_for_worker(
			map, map.cell_count())
		if not dist.is_empty():
			out["stage_distribute"] = dist
		# stage 11 前半段 weather field —— soil_moisture 的补水来源。distribute 只是
		# 把已有的天气分配下去，降水本身是这一段解出来的，所以 field 不跑时
		# soil_moisture 只有蒸腾的支出、没有收入，会一路单调衰减。
		if _generator._weather_system.has_method("build_field_knobs_for_worker") \
				and _generator._sus_world != null:
			var clock: Dictionary = _generator._get_native_daily_bundle_builder()._native_daily_weather_clock_values(0.0)
			var field_knobs: Dictionary = \
				_generator._weather_system.build_field_knobs_for_worker(
					map, _generator._sus_world,
					int(clock.get("season_idx", 0)),
					float(clock.get("anomaly", 0.0)),
					float(clock.get("season_phase", 0.0)),
					defer_thermal_equator)
			if not field_knobs.is_empty():
				if _generator._weather_system.has_method("convergence_refresh_due_on_day"):
					field_knobs["refresh_convergence"] = \
						_generator._weather_system.convergence_refresh_due_on_day(day)
				# The builder's dt is the main thread's gap between its own weather
				# solves, which are suppressed here; the worker solves every day.
				field_knobs["weather_transition_dt_days"] = 1.0
				out["stage_weather"] = field_knobs
			elif not _generator._runtime_climate_field_reported:
				_generator._runtime_climate_field_reported = true
				push_warning("[climate/worker] field knobs empty (fast_indexed?)")
		elif not _generator._runtime_climate_field_reported:
			_generator._runtime_climate_field_reported = true
			push_warning("[climate/worker] no field builder: has_method=%s world=%s"
				% [str(_generator._weather_system.has_method("build_field_knobs_for_worker")),
					str(_generator._sus_world)])
		elif not _generator._runtime_climate_distribute_reported:
			_generator._runtime_climate_distribute_reported = true
			push_warning("[climate/worker] distribute knobs came back empty")
	elif not _generator._runtime_climate_distribute_reported:
		# 权威下 distribute 不接就是 snow_cover 恒零，所以这条缺席必须出声，
		# 而不是安静地少跑一个 stage。
		_generator._runtime_climate_distribute_reported = true
		push_warning("[climate/worker] no distribute builder: ws=%s has_method=%s"
			% [str(_generator._weather_system),
				str(_generator._weather_system != null and _generator._weather_system.has_method(
					"build_distribute_knobs_for_worker"))])
	return out

func _build_runtime_climate_round_input(
		map: MapData, season_phase: float,
		worker_authoritative: bool = false) -> Dictionary:
	# S3：这里曾经是 _build_async_kick_input 的第二份实现（只覆盖 pass_a 需要的
	# 那些 lane）。生产 Climate 绝大多数日子走的是 async round，它的输入由
	# ClimateDailySystem._build_async_kick_input 构造 —— 两份构造代码只要有一个
	# 字段取值不同，SHADOW worker 就会在"同一份内核"上算出不同结果，而分叉矩阵
	# 会把它误报成算法分叉。所以 capture 直接复用生产自己的那份构造函数。
	#
	# 拿不到 ClimateDailySystem（native_daily 路径下它根本没注册）时返回空字典：
	# worker 会退回诊断近似并在 parity reason 里标注，而不是拿一份来源不同的输入
	# 去冒充对拍。
	if map == null:
		return {}
	var job = _generator._refresh_climate_daily_job
	if job == null or not job.has_method("_build_async_kick_input"):
		if not _generator._runtime_climate_round_input_lanes_reported:
			_generator._runtime_climate_round_input_lanes_reported = true
			push_warning("[runtime-climate-round] no ClimateDailySystem; SHADOW capture carries no shared pass input")
		# 上面那句注释说的"退回诊断近似"并没有发生：per-cell lane 由 C++ 侧
		# prefer_slot_lanes 从 _slots 填满，n_cells 也由 static knobs 给出，于是
		# shared_passes_available 成立、共享 round 照跑 —— 只有 scalars 全是结构体
		# 默认值，因为它们唯一的来路就是这个字典。这个"半真"状态静默了很久：
		# si_t_form 默认 0.06 而 profile 是 0.08，海冰 frac 上限只到 0.024（几乎不
		# 结冰），insol_amp 默认 0.20 而 profile 是 0.32，季节温度振幅只剩 62.5%。
		#
		# 所以这里不能返回空字典，要把 scalars 补上。仅 ACTIVE：SHADOW 下 scalars
		# 由 overlay_production_round_scalars 从生产记录覆盖，而且下面那个构建函数
		# 会 consume dt_days 累积值 —— SHADOW 下两侧都 consume 会互相偷。
		if not worker_authoritative:
			return {}
		return _build_runtime_climate_round_scalar_knobs(map, season_phase)
	var input: Dictionary = job._build_async_kick_input(season_phase)
	if typeof(input) != TYPE_DICTIONARY:
		return {}
	# 共享内核对每条输入 lane 都做 size == n 的硬校验，任一条缺失就整体静默回退到
	# worker 的诊断近似实现。这个诊断就是用来抓"镜像空数组"的，只在第一次不完整时报。
	var n_cells: int = map.soa_size()
	if not _generator._runtime_climate_round_input_lanes_reported:
		var missing: PackedStringArray = PackedStringArray()
		for lane in _generator._RUNTIME_CLIMATE_ROUND_REQUIRED_LANES:
			var arr = input.get(lane)
			if arr == null or arr.size() != n_cells:
				missing.append("%s=%d" % [lane, 0 if arr == null else arr.size()])
		if not missing.is_empty():
			_generator._runtime_climate_round_input_lanes_reported = true
			push_warning("[runtime-climate-round] pass_a shared kernel disabled; n_cells=%d incomplete lanes: %s"
					% [n_cells, ", ".join(missing)])
	return input


# ACTIVE 下 climate round 全部 scalars 的来源。
#
# 生产那侧这批值由各 pass 自己在运行时调 record_production_round_scalars 记录，再随
# reference publish 交给 worker（SHADOW）。ACTIVE 把生产 climate 整段抑制掉之后那条
# 来路就断了，而 capture 唯一的 round input 通道
# （ClimateDailySystem._build_async_kick_input）在 native_daily 路径下拿不到 job。
#
# 键名与 C++ fill_climate_round_input（world_ext_climate.cpp:6180+）逐一对应，前缀即
# pass：pb_ = pass_b、ow_/ol_ = ocean water/land、wa_/ws_ = wind air/surface、
# si_ = sea_ice。pass_a 那一段直接复用生产的 cp_struct 构建函数，键名本就相同。
#
# 这是这批 profile 字段的第三份读取（另两份：cp_struct + ClimateDailySystem 里那份
# 标着"必须 mirror"的移植）。没有合并是因为三个调用点的依赖不同 —— 这份不能碰 map
# （lane 走 slots）也不能依赖 job 实例。任何一侧改了 profile 字段名，三份都要改。

func _build_runtime_climate_round_scalar_knobs(
		map: MapData, season_phase: float, session_seed: bool = false) -> Dictionary:
	var cp = _generator._c()
	if cp == null or _generator._last_cfg == null:
		return {}
	# pass_a：cp_struct 的键名与 fill_climate_round_input 完全一致，直接用。
	# 注意它内部 consume 了 climate dt_days，所以这个函数只能在 ACTIVE 下调。
	var d: Dictionary = _generator._get_native_daily_bundle_builder()._build_native_daily_climate_pass_a_struct(map, cp, season_phase)
	# transpiration
	d["transp_outflow_rate"] = float(cp.transpiration_outflow_rate) if cp.get("transpiration_outflow_rate") != null else 0.025
	d["transp_self_rate"] = float(cp.transpiration_self_rate) if cp.get("transpiration_self_rate") != null else 0.015
	# pass_b。winter_boost 生产恒 1.0；coast_leak 来自 _generator._last_cfg 而不是 profile。
	d["pb_winter_boost"] = 1.0
	d["pb_snow_cool"] = float(cp.snow_albedo_cooling) if cp.get("snow_albedo_cooling") != null else 0.0
	d["pb_veg_cool"] = float(cp.vegetation_cooling) if cp.get("vegetation_cooling") != null else 0.0
	d["pb_diurnal_amp"] = float(cp.landform_diurnal_amp) if cp.get("landform_diurnal_amp") != null else 0.0
	d["pb_evap_gain"] = float(cp.evaporation_gain) if cp.get("evaporation_gain") != null else 0.0
	d["pb_rs_threshold"] = float(cp.rain_shadow_threshold) if cp.get("rain_shadow_threshold") != null else 0.0
	d["pb_rs_factor"] = float(cp.rain_shadow_factor) if cp.get("rain_shadow_factor") != null else 1.0
	d["pb_rs_lookback"] = maxi(0, int(cp.rain_shadow_lookback)) if cp.get("rain_shadow_lookback") != null else 0
	d["pb_t_freeze"] = float(cp.sea_ice_form_threshold) if cp.get("sea_ice_form_threshold") != null else 0.0
	d["pb_coupling_gain"] = float(cp.ocean_moisture_coupling_gain) if cp.get("ocean_moisture_coupling_gain") != null else 0.0
	d["pb_coast_leak"] = float(_generator._last_cfg.COASTAL_HEAT_LEAK)
	d["pb_sea_ice_albedo_cooling"] = float(cp.sea_ice_albedo_cooling) if cp.get("sea_ice_albedo_cooling") != null else 0.01
	# ocean_water / ocean_land。TTA 那四个 ocean_water 与 ocean_land 共用同一份值，
	# C++ 侧按 ow_/ol_ 前缀分别取。
	d["ow_advect_steps"] = maxi(0, int(_generator._last_cfg.OCEAN_HEAT_ADVECT_STEPS))
	d["ow_heat_mix"] = clampf(float(_generator._last_cfg.OCEAN_HEAT_MIX), 0.0, 1.0)
	var tta_cap: float = clampf(float(cp.temperature_transport_anomaly_source_cap), 0.0, 0.5) if cp.get("temperature_transport_anomaly_source_cap") != null else 0.22
	var tta_blend: float = clampf(float(cp.temperature_transport_anomaly_blend_rate), 0.0, 1.0) if cp.get("temperature_transport_anomaly_blend_rate") != null else 0.70
	var tta_decay: float = clampf(float(cp.temperature_transport_anomaly_decay_rate), 0.0, 1.0) if cp.get("temperature_transport_anomaly_decay_rate") != null else 0.04
	var tta_zero: float = clampf(float(cp.temperature_transport_anomaly_zero_current_decay), 0.0, 1.0) if cp.get("temperature_transport_anomaly_zero_current_decay") != null else 0.06
	d["ow_tta_source_cap"] = tta_cap
	d["ow_tta_blend_rate"] = tta_blend
	d["ow_tta_zero_current_decay"] = tta_zero
	d["ol_tta_source_cap"] = tta_cap
	d["ol_tta_blend_rate"] = tta_blend
	d["ol_tta_decay_rate"] = tta_decay
	d["ol_effective_leak"] = float(_generator._last_cfg.COASTAL_HEAT_LEAK)
	# ocean_water 的冷输运阈值与 sea_ice 的 t_form/t_melt 是两组不同的 knob（C++ 侧
	# 曾经误用过后者，见 runtime_climate_passes.cpp 里那处注释）。
	d["ow_cold_transport_form"] = float(cp.sea_ice_form_threshold) if cp.get("sea_ice_form_threshold") != null else 0.06
	d["ow_cold_transport_melt"] = float(cp.sea_ice_melt_threshold) if cp.get("sea_ice_melt_threshold") != null else 0.11
	# wind_air / wind_surface
	d["wa_advect_steps"] = maxi(0, int(_generator._last_cfg.WIND_HEAT_ADVECT_STEPS))
	d["wa_heat_mix"] = clampf(float(_generator._last_cfg.WIND_HEAT_MIX), 0.0, 1.0)
	d["ws_air_leak"] = float(_generator._last_cfg.AIR_MASS_HEAT_LEAK)
	d["ws_cold_transport_form"] = float(cp.sea_ice_form_threshold) if cp.get("sea_ice_form_threshold") != null else 0.06
	d["ws_cold_transport_melt"] = float(cp.sea_ice_melt_threshold) if cp.get("sea_ice_melt_threshold") != null else 0.11
	# sea_ice。这一段是「海冰完全不显示」的直接原因：默认 t_form 0.06 vs profile
	# 0.08、k_freeze/k_melt/delta_cap 全默认，实测 frac 上限只到 0.024。
	d["si_k_freeze"] = float(cp.sea_ice_freeze_rate) if cp.get("sea_ice_freeze_rate") != null else 0.40
	d["si_k_melt"] = float(cp.sea_ice_melt_rate) if cp.get("sea_ice_melt_rate") != null else 1.45
	var si_t_form: float = float(cp.sea_ice_form_threshold) if cp.get("sea_ice_form_threshold") != null else 0.06
	var si_t_melt: float = float(cp.sea_ice_melt_threshold) if cp.get("sea_ice_melt_threshold") != null else 0.11
	d["si_contagion"] = float(cp.sea_ice_neighbor_contagion) if cp.get("sea_ice_neighbor_contagion") != null else 0.035
	d["si_threshold"] = float(cp.sea_ice_terrain_threshold) if cp.get("sea_ice_terrain_threshold") != null else 0.68
	d["si_hysteresis"] = float(cp.sea_ice_terrain_hysteresis) if cp.get("sea_ice_terrain_hysteresis") != null else 0.12
	d["si_ice_delay"] = float(_generator._last_cfg.OCEAN_CURRENT_ICE_DELAY)
	d["si_solar_gate_enabled"] = bool(cp.sea_ice_solar_gate_enabled) if cp.get("sea_ice_solar_gate_enabled") != null else true
	d["si_freeze_insol_low"] = float(cp.sea_ice_freeze_insol_low) if cp.get("sea_ice_freeze_insol_low") != null else 0.22
	d["si_freeze_insol_high"] = float(cp.sea_ice_freeze_insol_high) if cp.get("sea_ice_freeze_insol_high") != null else 0.45
	d["si_solar_melt_start"] = float(cp.sea_ice_solar_melt_start) if cp.get("sea_ice_solar_melt_start") != null else 0.28
	d["si_solar_melt_gain"] = float(cp.sea_ice_solar_melt_gain) if cp.get("sea_ice_solar_melt_gain") != null else 1.35
	d["si_min_thick_ice_solar_exposure"] = float(cp.sea_ice_min_thick_ice_solar_exposure) if cp.get("sea_ice_min_thick_ice_solar_exposure") != null else 0.32
	d["si_daily_delta_cap"] = float(cp.sea_ice_daily_delta_cap) if cp.get("sea_ice_daily_delta_cap") != null else 0.070
	d["si_edge_mix_rate"] = float(cp.sea_ice_edge_mix_rate) if cp.get("sea_ice_edge_mix_rate") != null else 0.035
	d["si_enable_oht"] = bool(_generator._last_cfg.enable_ocean_heat_transport)
	d["si_terrain_lake_id"] = int(TerrainType.TERRAIN.LAKE) & 0xFF
	d["si_terrain_sea_ice_id"] = int(TerrainType.TERRAIN.SEA_ICE) & 0xFF
	d["si_terrain_ocean_id"] = int(TerrainType.TERRAIN.OCEAN) & 0xFF
	d["si_apply_terrain_flips"] = true
	d["si_dt_days"] = float(_generator._consume_sea_ice_dt_days()) if _generator.has_method("_consume_sea_ice_dt_days") else 1.0
	# 生产在调 sea_ice pass 之前把 t_form/t_melt 各减去 climate_anomaly * 0.10
	# （_generator._apply_sea_ice_daily_pass）。worker 要用同一组阈值，所以这个偏移要在这里做。
	var ca_now := 0.0 if session_seed else sample_anomaly()
	if not is_equal_approx(ca_now, 0.0):
		si_t_form = clampf(si_t_form - 0.10 * ca_now, 0.0, 1.0)
		si_t_melt = clampf(si_t_melt - 0.10 * ca_now, 0.0, 1.0)
	d["si_t_form"] = si_t_form
	d["si_t_melt"] = si_t_melt
	return d


func _runtime_climate_failure(code: String, reason: String = "", day: int = -1) -> Dictionary:
	_generator._runtime_climate_reference_failures += 1
	_generator._runtime_climate_reference_last_error = reason if not reason.is_empty() else code
	return {
		"ok": false,
		"code": code,
		"reason": _generator._runtime_climate_reference_last_error,
		"fallback_reason": _generator._runtime_climate_reference_last_error,
		"day": day,
	}

func _runtime_climate_hash_append(hashing, label: String, value) -> void:
	RuntimeClimateHash._runtime_climate_hash_append(hashing, label, value)

func _runtime_climate_hash_digest_value(digest: PackedByteArray) -> int:
	return RuntimeClimateHash._runtime_climate_hash_digest_value(digest)

func _runtime_climate_catalog_hash_for_map(map: MapData) -> int:
	if map == null:
		return 0
	var map_id := map.get_instance_id()
	if _generator._runtime_climate_catalog_map_id == map_id and _generator._runtime_climate_catalog_hash > 0:
		return _generator._runtime_climate_catalog_hash
	_generator._runtime_climate_catalog_hash = RuntimeClimateHash.catalog_hash(map, _generator._c())
	_generator._runtime_climate_catalog_map_id = map_id
	return _generator._runtime_climate_catalog_hash

func _runtime_climate_topology_generation_for_map(map: MapData) -> int:
	if map == null:
		return 0
	var map_id := map.get_instance_id()
	var supplied = map.get("topology_generation")
	if supplied != null:
		_generator._runtime_climate_topology_generation = maxi(1, int(supplied))
	elif _generator._runtime_climate_topology_map_id != map_id:
		# MapData is immutable at the topology boundary for the current phase. A
		# regenerated map receives a new local revision; later topology mutation
		# work can replace this with the authored topology revision field.
		_generator._runtime_climate_topology_generation = 1
	_generator._runtime_climate_topology_map_id = map_id
	return _generator._runtime_climate_topology_generation

func _runtime_climate_optional_array(map: MapData, field_name: String, packed_type: int):
	var value = map.get(field_name) if map != null else null
	if value != null and typeof(value) == packed_type:
		return value
	match packed_type:
		TYPE_PACKED_FLOAT32_ARRAY:
			return PackedFloat32Array()
		TYPE_PACKED_INT32_ARRAY:
			return PackedInt32Array()
		TYPE_PACKED_BYTE_ARRAY:
			return PackedByteArray()
	return PackedByteArray()

func _runtime_climate_neighbor_offsets_for_map(map: MapData) -> PackedInt32Array:
	if map == null:
		return PackedInt32Array()
	var map_id := map.get_instance_id()
	var cell_count := int(map.cell_count())
	if _generator._runtime_climate_neighbor_offsets_map_id == map_id \
			and _generator._runtime_climate_neighbor_offsets.size() == cell_count + 1:
		return _generator._runtime_climate_neighbor_offsets
	var offsets := PackedInt32Array()
	offsets.resize(cell_count + 1)
	for i in range(cell_count + 1):
		offsets[i] = i * 6
	_generator._runtime_climate_neighbor_offsets = offsets
	_generator._runtime_climate_neighbor_offsets_map_id = map_id
	return offsets

func _runtime_climate_trace_has_older_pending(day: int) -> bool:
	for raw_day in _generator._runtime_climate_trace_pending.keys():
		var pending_day := int(raw_day)
		if pending_day < day and not bool(
				_generator._runtime_climate_trace_pending[raw_day].get("reference_published", false)):
			return true
	return false


# ─── P1：环境帧发布者所有权 ────────────────────────────────────────────────
# `callsite` 为 0（默认）⇒ 所有权为空 ⇒ 任何调用点都能发，与改动前逐字节相同。

## 存盘窗口的预发布暂停回调。`_generator.request_runtime_save()` 是 game_save_coordinator
## 直接调的入口（不经过 WorldRuntimeHost），所以"先降 K 再 drain ring"必须由
## 发布权的真正持有者在这里收口。

func environment_publish_callsite_mask() -> int:
	return _generator._environment_publish_callsite_mask

func environment_publish_diagnostics() -> Dictionary:
	return {
		"environment_publish_callsite_mask": _generator._environment_publish_callsite_mask,
		"environment_publish_count": _generator._environment_publish_count,
		"environment_publish_orphan_day": _generator._environment_publish_orphan_day,
	}


## 今天这一天还该不该由本调用点发布环境帧。
## 返回 false 时调用方必须**什么都不做**：不打包、不递增 generation —— 打包了却
## 被别人抢先发，只会得到 `runtime_input_stale` 的静默丢弃（并让 generation 空洞）。

## Day the next environment frame must carry, as NativeSimulationHost tracks it
## (-1 without a runtime host). Publishers never infer it from their own clock.

func next_environment_day() -> int:
	var ext = _generator._data_core_world_ext
	return int(ext.runtime_next_environment_day()) if ext != null else -1


## Publishes environment frames in order from next_environment_day() through
## `last_day`. Days before `last_day` take the calendar phase of the following
## day (the day-change convention); `last_day` takes the caller's phase. Stops at
## the first failure and returns it; when `last_day` is already published it
## returns that frame's cached capture, or the watermark day.

func publish_environment_through(last_day: int, last_phase: float,
		callsite: int = 0) -> Dictionary:
	var next_day := next_environment_day()
	if next_day < 0:
		return capture_runtime_inputs_for_worker(last_day, last_phase, callsite)
	if last_day < next_day:
		if _generator._runtime_climate_trace_pending.has(next_day - 1):
			return capture_runtime_inputs_for_worker(next_day - 1, last_phase, callsite)
		return {"ok": true, "already_captured": true, "day": next_day - 1}
	var clock = _generator._world_clock_ref
	var result: Dictionary = {}
	for day in range(next_day, last_day + 1):
		var phase := last_phase
		if day < last_day:
			phase = float(clock.season_phase_for_day(day + 1)) \
				if clock != null and clock.has_method("season_phase_for_day") else last_phase
		result = capture_runtime_inputs_for_worker(day, phase, callsite)
		if not bool(result.get("ok", false)) or bool(result.get("suppressed", false)):
			break
	return result


## Phase A input boundary.  This is the only production helper allowed to
## read MapData arrays before they cross into NativeSimulationHost.  The
## returned dictionary is immediately copied by the C++ facade; no PackedArray
## reference is retained by the worker.

func capture_runtime_inputs_for_worker(day: int = -1, phase: float = -1.0,
		callsite: int = 0) -> Dictionary:
	if _generator._data_core_world_ext == null:
		return _runtime_climate_failure("runtime_worker_api_missing", "runtime worker input API is unavailable", day)
	var map: MapData = _generator._sus_map
	if map == null:
		return _runtime_climate_failure("runtime_input_map_unavailable", "MapData is not bound", day)
	if day < 0:
		day = int(_generator._world_clock_ref.day_index()) if _generator._world_clock_ref != null \
			and _generator._world_clock_ref.has_method("day_index") else 0
	if phase < 0.0:
		phase = float(_generator._world_clock_ref.season_phase()) if _generator._world_clock_ref != null \
			and _generator._world_clock_ref.has_method("season_phase") else 0.0
	if is_nan(phase) or is_inf(phase) or day < 0:
		return _runtime_climate_failure("runtime_input_value_invalid", "day/season phase is not finite", day)
	# 只由指定发布者消耗输入编号。
	if _generator._runtime_climate_trace_pending.has(day):
		var cached: Dictionary = _generator._runtime_climate_trace_pending[day]
		_generator._capture_trace("cached day=%d callsite=%d" % [day, callsite])
		return {
			"ok": true,
			"already_captured": true,
			"day": day,
			"input_generation": int(cached.get("input_generation", 0)),
			"catalog_hash": int(cached.get("catalog_hash", 0)),
			"topology_generation": int(cached.get("topology_generation", 0)),
		}
	var cell_count := int(map.cell_count())
	if cell_count <= 0 or int(map.width) <= 0 or int(map.height) <= 0:
		return _runtime_climate_failure("runtime_input_map_shape_invalid", "MapData shape is empty", day)
	# Restored hosts retain their last accepted input generation.
	var thread_report: Dictionary = {}
	if _generator._data_core_world_ext != null:
		thread_report = _generator.get_runtime_thread_report()
		_generator._runtime_input_generation = maxi(
			_generator._runtime_input_generation,
			int(thread_report.get("simulation_environment_generation",
				thread_report.get("environment_generation", 0))))
		if _generator._climate_authority_grant_pending(thread_report):
			thread_report = _generator._wait_climate_authority_grant()
	# The packet date governs capture, including retries across the year fence.
	var previous_date: int = calendar_day
	if bool(thread_report.get("climate_worker_authoritative", false)) \
			or bool(thread_report.get("whole_graph_requested", false)):
		calendar_day = day + 1
	var result := _capture_environment(map, day, phase, callsite, thread_report)
	calendar_day = previous_date
	return result


func initialize_world_environment(notice_history: Array = []) -> Dictionary:
	var map: MapData = _generator._sus_map
	var clock: WorldClock = _generator._world_clock_ref
	var profile = _generator._c()
	var config := clock.opening_climate_seed()
	config["display_notice_history"] = notice_history
	config["days_per_year"] = clock.days_per_year()
	config["climate_random_drift"] = clock.climate_random_drift
	config["climate_anomaly_max"] = clock.climate_anomaly_max
	config["season"] = _generator._build_season_round_knobs(map, 0)
	config["season_period"] = int(profile.season_refresh_period_ticks)
	config["albedo_stride"] = int(profile.weather_albedo_stride)
	config["vegetation_stride"] = int(profile.weather_vegetation_dynamics_stride)
	config["feedback_stride"] = int(profile.weather_feedback_stride)
	config["convergence_stride"] = int(profile.weather_convergence_refresh_stride)
	config["ice_form"] = float(profile.sea_ice_form_threshold)
	config["ice_melt"] = float(profile.sea_ice_melt_threshold)
	config["volcano_landform"] = int(LandformType.LF.VOLCANO)
	config["volcanoes"] = map.has_volcano_arr
	config["water_lut"] = MapData.is_water_lut()
	config["river_flow"] = map.river_flow_arr
	return _capture_environment(map, clock.day_index() + 1, clock.season_phase(), 0,
		{"climate_worker_authoritative": true, "climate_worker_prepares_thermal_equator": true}, config)


func _capture_environment(map: MapData, day: int, phase: float,
		callsite: int, thread_report: Dictionary, session_config: Dictionary = {}) -> Dictionary:
	# The due season refresh completes before its fields enter the worker packet.
	if session_config.is_empty() and _generator._season_refresh_job != null \
			and bool(thread_report.get("climate_worker_authoritative", false)):
		var season_slices: int = _generator._season_refresh_job.run_due_round_for_capture(day)
		if season_slices > 0:
			_generator.record_runtime_main_step(day - 1, &"season_install")
		if bool(_generator._season_refresh_job.season_refresh_state_snapshot().get("round_active", false)):
			return {"ok": false, "pending": true, "code": "season_refresh_incomplete", "day": day}
	var next_generation := maxi(1, _generator._runtime_input_generation + 1)
	var catalog_hash := _runtime_climate_catalog_hash_for_map(map)
	var topology_generation := _runtime_climate_topology_generation_for_map(map)
	var hydro_parent: PackedInt32Array = map.hydro_parent_arr
	var geometry_area = _runtime_climate_optional_array(
		map, "cell_geometry_area_arr", TYPE_PACKED_FLOAT32_ARRAY)
	var wind_band = _runtime_climate_optional_array(
		map, "cell_wind_band_arr", TYPE_PACKED_FLOAT32_ARRAY)
	var ocean_heat_capacity = _runtime_climate_optional_array(
		map, "cell_ocean_heat_capacity_arr", TYPE_PACKED_FLOAT32_ARRAY)
	var building_reserve = _runtime_climate_optional_array(
		map, "building_resource_reserve_arr", TYPE_PACKED_FLOAT32_ARRAY)
	var building_extra = _runtime_climate_optional_array(
		map, "building_resource_extra_arr", TYPE_PACKED_FLOAT32_ARRAY)
	var trade_passable: PackedByteArray = map.economy_trade_passable_lut()
	var trade_cost: PackedInt32Array = map.economy_trade_move_cost_lut()
	var neighbor_offsets := _runtime_climate_neighbor_offsets_for_map(map)
	if (not trade_passable.is_empty() or not trade_cost.is_empty()) \
			and (trade_passable.size() != 256 or trade_cost.size() != 256):
		return _runtime_climate_failure("runtime_input_lut_shape_mismatch",
			"trade LUTs must both be empty or both contain 256 entries", day)
	var input_generation := next_generation
	_generator._capture_trace("publish day=%d gen=%d callsite=%d" % [day, input_generation, callsite])
	var inputs := {
		"generation": input_generation,
		"climate_catalog_abi_version": 3,
		"climate_catalog_hash": catalog_hash,
		"climate_map_width": int(map.width),
		"climate_map_height": int(map.height),
		"day": day,
		"season_phase": phase,
		"climate_anomaly": sample_anomaly(),
		"topology_generation": topology_generation,
		"cell_temp": map.temp_arr,
		"cell_temp_30d": map.temp_30d_arr,
		"cell_moisture": map.moisture_arr,
		"cell_plant_available_water": map.plant_available_water_arr,
		"cell_weather_precip": map.weather_precip_arr,
		"cell_snow_cover": map.snow_cover_arr,
		"cell_weather_intensity": map.weather_intensity_arr,
		"cell_elevation": map.elevation_arr,
		"cell_lat_norm": map.cell_lat_norm_arr,
		"cell_geometry_area": geometry_area,
		"cell_wind_band": wind_band,
		"cell_ocean_heat_capacity": ocean_heat_capacity,
		# 这三条原本不在 capture 里：environment 快照的字段虽然早就声明了它们，但
		# copy_f32 的语义是"key 缺席就留空并放行"，所以缺席一直是静默的。权威下
		# weather distribute 要读 heat（融雪的日照项）与 soil_moisture（它自己的
		# in/out），少一条就整个 stage 静默跳过，snow_cover 因此恒为 0。
		# weather_type 只是为了过 distribute 的 size 检查 —— 内核实际读的是自己
		# store 里那份（round 刚写过），但输入侧仍要求它齐长。
		"cell_heat_input": map.heat_input_arr,
		"cell_soil_moisture": map.soil_moisture_arr,
		"cell_weather_type": map.weather_type_arr,
		# 同一批缺口的后三条：feedback 读 base_moisture 与
		# temperature_transport_anomaly，vegetation_dynamics 读 water_balance_30d。
		"cell_base_moisture": map.base_moisture_arr,
		"cell_water_balance_30d": map.water_balance_30d_arr,
		"cell_temperature_transport_anomaly": map.temperature_transport_anomaly_arr,
		# weather field 的平流与邻域几何要用格子平面坐标。
		"cell_pos_x": map.cell_pos_x_arr,
		"cell_pos_y": map.cell_pos_y_arr,
		# 风场与气团温度异常：weather field 的平流方向与锋生项。
		"cell_wind_x": map.wind_x_arr,
		"cell_wind_y": map.wind_y_arr,
		"cell_wind_speed": map.wind_speed_arr,
		"cell_ocean_current_x": map.ocean_current_x_arr,
		"cell_ocean_current_y": map.ocean_current_y_arr,
		"cell_ocean_thermal_anomaly": map.ocean_thermal_anomaly_arr,
		"cell_air_mass_temp_anomaly": map.air_mass_temp_anomaly_arr,
		"neighbor_indices": map.neighbor_indices_packed(),
		"neighbor_offsets": neighbor_offsets,
		"hydro_parent": hydro_parent,
		"province_ids": map.province_id_arr,
		"terrain": map.terrain_arr,
		"landform": map.landform_arr,
		"vegetation": map.vegetation_arr,
		"cover": map.cover_arr,
		"is_water": map.is_water_arr,
		"has_river": map.has_river_arr,
		"canal_edge_mask": map.canal_edge_mask_arr,
		"canal_water": map.canal_water_arr,
		"trade_passable_lut": trade_passable,
		"trade_move_cost_lut": trade_cost,
		"military_base_landform": map.base_landform_arr,
		"military_settlement_tier": _generator._get_map_country_initializer()._military_settlement_tiers(map),
		"building_resource_reserve": building_reserve,
		"building_resource_extra": building_extra,
		# S3：生产 Climate round 的输入缓冲。worker 用它调共享纯内核，替代原来
		# worker 侧自己重写的 stage 近似实现。
		# ACTIVE 下这个字典还负责带全套 round scalars（见该函数里的说明）—— 那是
		# 「海冰不显示」「季节振幅只剩 62.5%」的共同根因所在。
		"climate_round_input": _build_runtime_climate_round_scalar_knobs(map, phase, true) \
			if not session_config.is_empty() else _build_runtime_climate_round_input(
			map, phase,
			bool(thread_report.get("climate_worker_authoritative", false))),
		"climate_round_static_knobs": {
			"donor_table": _generator._build_transpiration_donor_table(),
			"foliage_table": _generator._build_climate_b_foliage_table(),
			# stage 8 albedo 用。生产 stage_b 的 albedo 段读的是同一个构建函数的结果，
			# 所以 worker 与生产查的是同一张表；缺了它 worker 会静默跳过 albedo，而
			# albedo 是 temp 的日内最后写者。
			"albedo_table": _generator._build_albedo_donor_table(),
			# sea_ice 的 water terrain LUT。它不是 per-cell lane，所以 capture 的
			# slot 兜底覆盖不到它；缺了它 sea_ice pass 会静默跳过。
			"water_terrain_ids": PackedByteArray([
				int(TerrainType.TERRAIN.OCEAN) & 0xFF,
				int(TerrainType.TERRAIN.COAST) & 0xFF,
				int(TerrainType.TERRAIN.LAKE) & 0xFF,
				int(TerrainType.TERRAIN.REEF) & 0xFF,
				int(TerrainType.TERRAIN.KELP) & 0xFF,
				int(TerrainType.TERRAIN.SEA_ICE) & 0xFF,
			]),
		},
		# Per-stage knobs for the stages the worker cannot reach on its own.
		# Empty unless Climate is worker-authoritative; under SHADOW these same
		# stages get their input from the production reference publish, and
		# supplying a second source would give the two sides different inputs
		# for the same day.
		"climate_stage_knobs": _build_runtime_climate_stage_knobs(
			map, day, bool(thread_report.get("climate_worker_authoritative", false)),
			bool(thread_report.get("climate_worker_prepares_thermal_equator", false)),
			not session_config.is_empty()),
		# 只有慢层结果写回后才提交对应输入，气候据此接收重算字段。
		"climate_season_refresh_ran": _generator._season_refresh_edge_pending(),
		# Climate 在 worker 手上时，worker 要自己补上「生产被抑制后就停更」的那些
		# 记录：round scalars（season_phase）与 PAW。两处都不能无条件做，否则
		# SHADOW parity 立刻分叉。见 RuntimeEnvironmentSnapshot::climate_worker_authoritative。
		"climate_worker_authoritative": bool(
			thread_report.get("climate_worker_authoritative", false)),
		"climate_capture_cursors": preload("res://scripts/game/world_runtime_climate_restore.gd").capture(_generator),
	}
	if not session_config.is_empty():
		inputs["world_environment_config"] = session_config
		return _generator._data_core_world_ext.capture_runtime_inputs(inputs)
	if callsite != 0 or day > 1:
		_generator.record_runtime_main_step(day, &"environment_capture")
	var result: Dictionary = _generator._data_core_world_ext.capture_runtime_inputs(inputs)
	_generator._capture_trace("result day=%d ok=%s code=%s" % [
		day, str(result.get("ok", false)), String(result.get("code", ""))])
	if bool(result.get("ok", false)):
		_generator._runtime_input_generation = input_generation
		_generator._last_capture_season_refresh_day = _generator._last_season_refresh_day
		# P1 调用点账本：谁真的发出去了。收敛成单一发布者之后这里应当只剩一位。
		if callsite != 0:
			_generator._environment_publish_callsite_mask |= callsite
		_generator._environment_publish_count += 1
		var round_state = _generator._native_daily_climate_round_state_snapshot()
		_generator._runtime_climate_trace_pending[day] = {
			"day": day,
			"phase": phase,
			"input_generation": input_generation,
			"catalog_hash": catalog_hash,
			"topology_generation": topology_generation,
			"captured_at_msec": Time.get_ticks_msec(),
			"pass_generation_before": int(round_state.get("pass_generation", -1)),
			"round_active_before": bool(round_state.get("round_active", false)),
			"reference_published": false,
			"reference_hash": 0,
			"capture_result": result.duplicate(true),
		}
		result["input_generation"] = input_generation
		result["catalog_hash"] = catalog_hash
		result["topology_generation"] = topology_generation
	else:
		result["fallback_reason"] = String(result.get("code", "runtime_input_publish_failed"))
		_generator._runtime_climate_reference_last_error = String(result["fallback_reason"])
		_generator._runtime_climate_reference_failures += 1
	return result


func _collect_runtime_climate_parity_fields(map: MapData) -> Dictionary:
	return ClimateReference._collect_runtime_climate_parity_fields(self, map)


func _runtime_climate_parity_map_array(map: MapData, array_name: String) -> Variant:
	return ClimateReference._runtime_climate_parity_map_array(map, array_name)


func _runtime_climate_reference_ready_for_day(day: int) -> bool:
	return ClimateReference._runtime_climate_reference_ready_for_day(self, day)


func _publish_runtime_climate_reference(day: int, map: MapData = null) -> Dictionary:
	return ClimateReference._publish_runtime_climate_reference(self, day, map)


func _publish_ready_runtime_climate_references(up_to_day: int,
		map: MapData = null) -> Dictionary:
	return ClimateReference._publish_ready_runtime_climate_references(self, up_to_day, map)


func runtime_climate_trace_report() -> Dictionary:
	return ClimateReference.runtime_climate_trace_report(self)

