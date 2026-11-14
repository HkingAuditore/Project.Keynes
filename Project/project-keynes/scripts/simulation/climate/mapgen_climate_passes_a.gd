extends "res://scripts/simulation/generator_context.gd"
## Generation/runtime climate helpers and sliced native pass orchestration.
func _init(generator) -> void:
	_generator = generator


func _publish_native_generation_from_slots(map: MapData, cfg: MapConfig) -> bool:
	if map == null or cfg == null or _generator._data_core_world_ext == null:
		return false
	var cp = _generator._c()
	var cfg_dict: Dictionary = {
		"cell_count": map.cell_count(),
		"width": int(cfg.width),
		"height": int(cfg.height),
		"sea_level": float(cfg.sea_level),
	}
	var profile_dict: Dictionary = {
		"native_generation_mode": int(cp.get("native_generation_mode")) if cp != null and cp.get("native_generation_mode") != null else 0,
	}
	var res: Dictionary = _generator._data_core_world_ext.run_native_world_generate_pass(_generator._last_seed, cfg_dict, profile_dict)
	if int(res.get("rc", -1)) == 0 and bool(res.get("published_to_slot", false)):
		# C++ flush 使用 MapData.set() reseat PackedArray；重绑 GDScript DCWorld，避免
		# scheduler/facade 持有生成前的旧数组引用。
		if _generator._data_core_world != null and _generator._data_core_world.has_method("rebind_map_data"):
			var demo_tg_on: bool = false
			if cp != null and "demo_thermal_gradient_enabled" in cp:
				demo_tg_on = bool(cp.demo_thermal_gradient_enabled)
			_generator._data_core_world.rebind_map_data(map, demo_tg_on)
			if _generator._sus != null and _generator._sus.has_method("bind_world"):
				_generator._sus.bind_world(_generator._data_core_world)
		_generator._data_core_world_ext.flush_pending_mark_dirty_all()
		var published: Array = res.get("published_slots", [])
		print("[native_generation] path=gdext n=%d published=%d native_ms=%.3f compute_ms=%.3f flush_ms=%.3f"
			% [
				int(res.get("n_cells", 0)),
				published.size(),
				float(res.get("native_ms", res.get("elapsed_ms", 0.0))),
				float(res.get("compute_ms", 0.0)),
				float(res.get("flush_ms", 0.0)),
			])
		return true
	var reason: String = String(res.get("fallback_reason", res.get("reason", "unknown")))
	push_warning("[native_generation] C++ publish fallback (%s); 保留 GDScript 生成期 SoA" % reason)
	return false

# cpp-dots（temp-baseline-authority-2026-06）：cell_temp_baseline_year 的权威 C++ 烘焙。
# 海冰 + 显示温度的运行期 baseline 是 lat_temp_bell(lat_norm) 的纯仿真量——计算权威归
# C++（DCWorldExt.run_temp_baseline_year_bake / pk_lat_temp_bell），写 cell_temp_baseline_year
# slot 并 flush 回 MapData.temp_baseline_year_arr。本函数在 DCWorldExt bind 完成后调用一次。
# ext 未编译 / 未 bind / 缺方法 → 静默保留 bake_lat_temp_year_lut 已填的 GDScript fallback 值。

func _bake_temp_baseline_year_native(map: MapData) -> void:
	if map == null or _generator._data_core_world_ext == null :
		return
	if int(_generator._data_core_world_ext.component_id("cell_temp_baseline_year")) < 0:
		return
	var lat: PackedFloat32Array = map.cell_lat_norm_arr
	if lat.is_empty():
		return
	var res: Dictionary = _generator._data_core_world_ext.run_temp_baseline_year_bake({"lat_norm": lat})
	if bool(res.get("fallback", true)):
		push_warning("[DataCore] run_temp_baseline_year_bake fallback (%s); 保留 GDScript baseline" % String(res.get("reason", "unknown")))
	else:
		print("[DataCore] cell_temp_baseline_year baked by C++ (pk_lat_temp_bell): n=%d native_ms=%.3f" % [int(res.get("n_cells", 0)), float(res.get("elapsed_ms", 0.0))])

# ─── 轨道相位边界刷新（慢层维护）────────────────────────────────────
# 每次 WorldClock.season_changed 触发。这里不再直接重置湿度、温度、雨影或风；
# 气候变化由每日 C++/DOTS 链条推进：太阳直射点 -> 日照/昼长 -> 热惯性 ->
# SLP/风场 -> 水汽/天气。season_changed 只作为慢层/atlas 的维护边界。

func refresh_climate_daily(map: MapData, season_phase: float) -> void:
	if map == null:
		return
	var cp = _generator._c()
	if cp == null or _generator._last_cfg == null:
		return
	if not cp.daily_climate_interpolation:
		return  # 兼容回退路径：开关 false 时维持旧"季首硬切"行为

	# Daily Sim SoA Refactor 方向 X：refresh_climate_daily 现在只是 wrapper，
	# 串联调用 6 个独立 sub-pass。ClimateDailySystem 切片化路径会绕过
	# 本 wrapper，改为按 _pass_cursor 逐 tick 调用对应 sub-pass，把单 tick 的
	# ~80ms 切到 5-6 个 tick 上。其他历史/非切片调用方继续走 wrapper。
	var t0: int = Time.get_ticks_msec()
	var local_coupling: bool = bool(cp.enable_local_climate_coupling)

	# Pass A：基线 temp/moisture/snow_cover + EMA。
	var t_pass_a_us0: int = Time.get_ticks_usec()
	_generator._climate_pass_a(map, season_phase)
	var t_pass_a_ms: float = (Time.get_ticks_usec() - t_pass_a_us0) / 1000.0

	# Pass B：局部气候耦合（受开关控）。
	var t_pass_b_ms: float = 0.0
	if local_coupling:
		var t_pass_b_us0: int = Time.get_ticks_usec()
		_generator._climate_pass_b(map, season_phase)
		t_pass_b_ms = (Time.get_ticks_usec() - t_pass_b_us0) / 1000.0

	var climate_call_count: int = _generator._diagnostics_bus.increment_climate_call_count()

	# Ocean heat transport：水段 + 陆段（受主开关控）。
	# 切片化路径会把这两段拆到独立 sub-tick；wrapper 保持串联调用以维持
	# 非切片路径行为不变。
	var t_ocean_ms: float = 0.0
	if _generator._last_cfg.enable_ocean_heat_transport:
		var t_ocean_us0: int = Time.get_ticks_usec()
		_generator._ocean_water_pass(map, season_phase)
		_generator._ocean_land_pass(map, season_phase)
		t_ocean_ms = (Time.get_ticks_usec() - t_ocean_us0) / 1000.0

	# Wind heat transport：气团段 + 地表段（对称复刻洋流热输运）。
	# 受 enable_ocean_heat_transport 开关统一控制（风温耦合与洋流热输运同属物理环流系统）。
	var t_wind_ms: float = 0.0
	if _generator._last_cfg.enable_ocean_heat_transport:
		var t_wind_us0: int = Time.get_ticks_usec()
		_generator._wind_air_mass_pass(map, season_phase)
		_generator._wind_surface_pass(map, season_phase)
		t_wind_ms = (Time.get_ticks_usec() - t_wind_us0) / 1000.0

	# Sea ice：逐日演替 pass（路线 A：单一真值源）。
	var t_sea_ice_us0: int = Time.get_ticks_usec()
	_generator._apply_sea_ice_daily_pass(map, season_phase)
	var t_sea_ice_ms: float = (Time.get_ticks_usec() - t_sea_ice_us0) / 1000.0

	# 旧 sea_ice R8 atlas upload 已退役；这里只保留指标字段为 0 占位。
	var t_ice_bake_ms: float = 0.0

	# Transpiration：植被→湿度反馈（受开关控）。
	var t_transp_ms: float = 0.0
	if local_coupling:
		var t_transp_us0: int = Time.get_ticks_usec()
		_generator._ensure_daily_pass_modules()
		_generator._transpiration_pass_module.run(map)
		t_transp_ms = (Time.get_ticks_usec() - t_transp_us0) / 1000.0

	# Daily-sim perf instrumentation：把 7 段子耗时缓存到生成器成员，
	# 由 main.gd 的 fast tick 详细日志 / WARN 路径按需读取。
	var climate_breakdown: Dictionary = {
		"pass_a_ms": t_pass_a_ms,
		"pass_b_ms": t_pass_b_ms,
		"ocean_ms": t_ocean_ms,
		"wind_ms": t_wind_ms,
		"sea_ice_ms": t_sea_ice_ms,
		"ice_bake_ms": t_ice_bake_ms,
		"transp_ms": t_transp_ms,
		"total_ms": float(Time.get_ticks_msec() - t0),
		"cells": map.cell_count(),
		"_tick_idx": _generator._current_fast_tick_idx,
	}
	_generator._diagnostics_bus.record_climate_breakdown(climate_breakdown)
	if _generator._is_annual_log_tick(climate_call_count):
		# I1.A-1: wrapper 路径也补上 path=... 标识，与 sliced 路径输出格式对齐。
		# 实际该路径在 SUS 接管后基本不触发（已走 ClimateDailySystem.sliced），
		# 但保留对齐避免日志解析脚本分歧。
		var _wrap_path: String = "legacy"
		if _generator._data_core_world != null and _generator._data_core_world.is_bound():
			if _generator._refresh_climate_daily_job != null and _generator._refresh_climate_daily_job.has_method("data_core_ready") and _generator._refresh_climate_daily_job.data_core_ready():
				_wrap_path = "data_core"
			else:
				_wrap_path = "data_core_cells_only"
		print("refresh_climate_daily #%d: %dms (cells=%d, phase=%.3f) | A=%.1f B=%.1f ocean=%.1f wind=%.1f sea_ice=%.1f ice_bake=%.1f transp=%.1f path=%s" % [
			climate_call_count,
			Time.get_ticks_msec() - t0,
			map.cell_count(),
			season_phase,
			t_pass_a_ms, t_pass_b_ms, t_ocean_ms, t_wind_ms, t_sea_ice_ms, t_ice_bake_ms, t_transp_ms,
			_wrap_path,
		])

## Initial publish uses the same pass kernels and ordering while the clock is paused.

func refresh_climate_loading(map: MapData, season_phase: float) -> void:
	var cp = _generator._c()
	if map == null or cp == null or _generator._last_cfg == null or not cp.daily_climate_interpolation:
		return
	_generator._climate_pass_a(map, season_phase)
	await _generator._yield_generation_frame()
	if cp.enable_local_climate_coupling:
		_generator._climate_pass_b(map, season_phase)
		await _generator._yield_generation_frame()
	if _generator._last_cfg.enable_ocean_heat_transport:
		_generator._ocean_water_pass(map, season_phase)
		await _generator._yield_generation_frame()
		_generator._ocean_land_pass(map, season_phase)
		await _generator._yield_generation_frame()
		await _generator._wind_air_mass_pass(map, season_phase, true)
		await _generator._yield_generation_frame()
		await _generator._wind_surface_pass(map, season_phase, true)
		await _generator._yield_generation_frame()
	_generator._apply_sea_ice_daily_pass(map, season_phase)
	await _generator._yield_generation_frame()
	if cp.enable_local_climate_coupling:
		_generator._ensure_daily_pass_modules()
		_generator._transpiration_pass_module.run(map)
	_generator._diagnostics_bus.increment_climate_call_count()

# ─── Daily Sim SoA Refactor 方向 X：sub-pass API ──────────────────────────
# 把 refresh_climate_daily 内部拆成可独立调用的 sub-pass，供 ClimateDailySystem
# 按 _pass_cursor 切片调用。每段都是"读字段 → 写字段"
# 的纯函数：跨 sub-tick 之间靠 HexCell 已稳定的字段做数据交接，不依赖局部
# Dictionary 缓存，因此天然支持跨 tick 切片。
#
# 顺序约束（必须严格按下方顺序调用）：
#   1) _climate_pass_a       — 写 temperature/moisture/snow_cover/EMA（裸基线）
#   2) _climate_pass_b       — 局部气候耦合（可选，受 enable_local_climate_coupling）
#   3) _ocean_water_pass     — 水段（可选，受 enable_ocean_heat_transport）
#   4) _ocean_land_pass      — 陆段（可选，必须紧跟水段）
#   5) _wind_air_mass_pass   — 气团段（可选，受 enable_ocean_heat_transport）
#   6) _wind_surface_pass    — 地表段（可选，必须紧跟气团段）
#   7) _apply_sea_ice_daily_pass — 海冰演替（必跑）
#   8) transpiration_pass.gd.run — 植被→湿度反馈（可选，与 Pass B 同开关）

# PR-2.1.1 helper：把 [name → cid → write_*_indexed] 三步压成一行调用，封装
# `_data_core_world == null` / `cid < 0` 双守卫。供 _climate_pass_a /
# _climate_pass_a_soa 以及后续 PR-2.1.2/3/4 的 hot pass push 块复用。
# 详见 docs/architecture/development-guide.md / §9.2 模板 2。

func _dump_sea_ice_breakdown_if_slow() -> void:
	if _generator._last_sea_ice_daily_breakdown.is_empty():
		return
	var total_wall: float = float(_generator._last_sea_ice_daily_breakdown.get("total_wall_ms", 0.0))
	if total_wall < _generator._SEA_ICE_SLOW_DUMP_THRESHOLD_MS:
		return
	# 节流：30 fast tick 内最多打一次，避免连续帧刷屏。
	# _current_fast_tick_idx 由 main.gd._run_fast_tick 顶部同步，初始 0；
	# 首次触发时 last_tick=-10000，无论如何会打。
	if _generator._current_fast_tick_idx - _generator._sea_ice_slow_dump_last_tick < _generator._SEA_ICE_SLOW_DUMP_MIN_INTERVAL:
		return
	_generator._sea_ice_slow_dump_last_tick = _generator._current_fast_tick_idx
	var b: Dictionary = _generator._last_sea_ice_daily_breakdown
	print("[sea_ice/slow-dump] tick=%d path=%s total_wall=%.2fms (pack=%.2f refresh=%.2f native=%.2f native_wall=%.2f sync=%.2f flip=%.2f) water=%d flipped=%d" % [
		_generator._current_fast_tick_idx,
		str(b.get("path", "?")),
		total_wall,
		float(b.get("pack_ms", 0.0)),
		float(b.get("refresh_ms", 0.0)),
		float(b.get("native_ms", -1.0)),
		float(b.get("native_wall_ms", 0.0)),
		float(b.get("sync_ms", 0.0)),
		float(b.get("flip_ms", 0.0)),
		int(b.get("water", 0)),
		int(b.get("flipped", 0)),
	])


# Plan: civ-grounded-development / weather cyclone 突刺一次性诊断（2026-05-21）
# 触发条件（任一）：
#   - weather_tick_ms ≥ 5.0   → 总 tick 突刺
#   - cyclone_ms      ≥ 3.0   → cyclone_wake_step 单段突刺（典型常态 0.15ms）
# 输出 _last_weather_breakdown 全字段：advance / spawn / distribute / cyclone /
#   stage_a/b 各段 / albedo / veg_dyn / cover_rebake / veg_rebake / feedback / fronts / path。
# 节流到至少 30 fast tick 间隔一次。

func _dump_weather_breakdown_if_slow() -> void:
	var weather_breakdown: Dictionary = _generator._diagnostics_bus.get_weather_breakdown()
	if weather_breakdown.is_empty():
		return
	var total_wall: float = float(weather_breakdown.get("weather_tick_ms", 0.0))
	var cyclone_ms_v: float = float(weather_breakdown.get("cyclone_ms", 0.0))
	if total_wall < _generator._WEATHER_SLOW_DUMP_TOTAL_THRESHOLD_MS \
			and cyclone_ms_v < _generator._WEATHER_SLOW_DUMP_CYCLONE_THRESHOLD_MS:
		return
	if _generator._current_fast_tick_idx - _generator._weather_slow_dump_last_tick < _generator._WEATHER_SLOW_DUMP_MIN_INTERVAL:
		return
	_generator._weather_slow_dump_last_tick = _generator._current_fast_tick_idx
	var b: Dictionary = _generator._normalized_weather_breakdown(weather_breakdown)
	print("[weather/slow-dump] tick=%d path=%s tick_ms=%.2f (adv=%.2f spawn=%.2f dist=%.2f cyc=%.2f stage_b=%.2f albedo=%.2f veg_dyn=%.2f feedback=%.2f cover_rb=%.2f veg_rb=%.2f) fronts=%d" % [
		_generator._current_fast_tick_idx,
		str(b.get("path", "?")),
		total_wall,
		float(b.get("advance_ms", 0.0)),
		float(b.get("spawn_ms", 0.0)),
		float(b.get("distribute_ms", 0.0)),
		cyclone_ms_v,
		float(b.get("stage_b_ms", 0.0)),
		float(b.get("albedo_ms", 0.0)),
		float(b.get("veg_dyn_ms", 0.0)),
		float(b.get("feedback_ms", 0.0)),
		float(b.get("cover_rebake_ms", 0.0)),
		float(b.get("veg_rebake_ms", 0.0)),
		int(b.get("fronts_count", 0)),
	])
	# Phase B.2 cyclone 细粒度遥测：仅在 cyclone 段实际有耗时（≥0.5ms）且 C++
	# combined path 提供了 phase1/phase2 拆分时打印第二行。常态 cyclone≈0.15ms
	# 时此分支不触发，避免噪音；一旦未来真出现 cyclone 突刺立即可定位是衰减循环
	# (phase1) vs 注入循环 (phase2)、是大量 evict vs 大量 replace。
	var phase1_ms: float = float(b.get("cyclone_phase1_decay_ms", 0.0))
	var phase2_ms: float = float(b.get("cyclone_phase2_inject_ms", 0.0))
	if cyclone_ms_v >= 0.5 and (phase1_ms > 0.0 or phase2_ms > 0.0):
		print("[weather/slow-dump-cyclone] tick=%d phase1_decay=%.2fms phase2_inject=%.2fms (n_decayed=%d n_evicted=%d n_replaced=%d n_injected=%d pool_size=%d)" % [
			_generator._current_fast_tick_idx,
			phase1_ms,
			phase2_ms,
			int(b.get("cyclone_n_decayed", 0)),
			int(b.get("cyclone_n_evicted", 0)),
			int(b.get("cyclone_n_replaced", 0)),
			int(b.get("cyclone_n_injected", 0)),
			int(b.get("cyclone_pool_size", 0)),
		])



func _sea_ice_slice_budget_cells() -> int:
	var cp = _generator._c()
	var slice_ms: float = 0.75
	if cp != null and cp.get("sim_slice_budget_ms") != null:
		slice_ms = float(cp.sim_slice_budget_ms)
	return clampi(int(round(512.0 * clampf(slice_ms / 0.75, 0.5, 2.0))), 128, 1024)



func _sea_ice_insolation_input(map: MapData, cells: Array, season_phase: float) -> PackedFloat32Array:
	var n_cells: int = cells.size()
	if map != null and map.insolation_now_arr.size() == n_cells:
		# Live slot first: the freeze gate and solar melt must see today's sun, and
		# Pass-A only mirrors insolation into MapData at the round boundary.
		return _generator._get_native_daily_bundle_builder()._native_daily_live_f32("cell_insolation_now", map.insolation_now_arr, n_cells)
	if _generator._gdext_sea_ice_insol_buf.size() != n_cells:
		_generator._gdext_sea_ice_insol_buf.resize(n_cells)
	for i in range(n_cells):
		var c: HexCell = cells[i]
		_generator._gdext_sea_ice_insol_buf[i] = _generator._compute_insolation(_generator._cube_row_norm(c, _generator._last_cfg), season_phase) \
			if c != null and _generator._last_cfg != null else 0.0
	return _generator._gdext_sea_ice_insol_buf



func _abort_sea_ice_state_machine(reason: String = "abort") -> void:
	if _generator._sea_ice_state_machine.is_empty():
		return
	_generator._sea_ice_state_machine["status"] = _generator._CLIMATE_PASS_STATUS_ABORTED
	_generator._sea_ice_state_machine["abort_reason"] = reason
	_generator._sea_ice_state_machine["ended_msec"] = Time.get_ticks_msec()
	_generator._sea_ice_state_machine = {}



func _begin_sea_ice_state_machine(map: MapData, season_phase: float, token: int) -> bool:
	if map == null or _generator._last_cfg == null:
		return false
	var cp = _generator._c()
	if cp == null:
		return false
	var cells_fast: Array = map.iter_cells() if map.has_indices() else map.all_cells()
	var n_cells_fast: int = cells_fast.size()
	var nb_idx_fast: PackedInt32Array = map.neighbor_indices_packed() if map.has_indices() else PackedInt32Array()
	var fast_indexed: bool = nb_idx_fast.size() >= n_cells_fast * 6
	if _generator._data_core_world_ext == null \
			or not _generator._data_core_world_ext.has_method("run_sea_ice_daily_pass") \
			or not fast_indexed:
		return false
	if not _generator._gdext_sea_ice_signature_checked:
		_generator._gdext_sea_ice_signature_checked = true
		_generator._gdext_sea_ice_signature_ok = _generator._validate_gdext_method_signature("run_sea_ice_daily_pass", 2)
		print("[sea_ice/F.4] sig probe result = %s（仅作诊断，不阻止下方 C++ 调用）" % str(_generator._gdext_sea_ice_signature_ok))

	var k_freeze: float = float(cp.sea_ice_freeze_rate)
	var k_melt: float = float(cp.sea_ice_melt_rate)
	var t_form: float = float(cp.sea_ice_form_threshold)
	var t_melt: float = float(cp.sea_ice_melt_threshold)
	var contagion: float = float(cp.sea_ice_neighbor_contagion)
	var threshold: float = float(cp.sea_ice_terrain_threshold)
	var hysteresis: float = float(cp.sea_ice_terrain_hysteresis)
	var ice_delay: float = float(_generator._last_cfg.OCEAN_CURRENT_ICE_DELAY)
	var climate_anomaly_now: float = 0.0
	if _generator._world_clock_ref != null:
		var ca_v = _generator._world_clock_ref.get("climate_anomaly")
		if ca_v != null:
			climate_anomaly_now = float(ca_v)
	if not is_equal_approx(climate_anomaly_now, 0.0):
		var ice_thr_shift: float = 0.10 * climate_anomaly_now
		t_form = clampf(t_form - ice_thr_shift, 0.0, 1.0)
		t_melt = clampf(t_melt - ice_thr_shift, 0.0, 1.0)

	# ─── sea_ice dt_days 补偿（状态机入口路径）────────────────────────────
	# C++ 接收 per-day k 与 dt_days，避免 sliced 调度间隔造成 dt^2 过冲。
	var dt_days: float = _generator._consume_sea_ice_dt_days()
	var k_freeze_scaled: float = k_freeze * dt_days
	var k_melt_scaled: float = k_melt * dt_days

	var t_total_us: int = Time.get_ticks_usec()
	var t_pack_us: int = Time.get_ticks_usec()
	var base_terrain_input: PackedByteArray
	if map.base_terrain_arr.size() == n_cells_fast:
		base_terrain_input = map.base_terrain_arr
	else:
		if _generator._gdext_sea_ice_base_terrain_buf.size() != n_cells_fast:
			_generator._gdext_sea_ice_base_terrain_buf.resize(n_cells_fast)
		base_terrain_input = _generator._gdext_sea_ice_base_terrain_buf
		for i_build in range(n_cells_fast):
			var c_build: HexCell = cells_fast[i_build]
			_generator._gdext_sea_ice_base_terrain_buf[i_build] = int(c_build.base_terrain) & 0xFF
	var tta_input: PackedFloat32Array
	if _generator._gdext_ocean_anomaly_buf_cached.size() == n_cells_fast:
		tta_input = _generator._gdext_ocean_anomaly_buf_cached
	elif map.temperature_transport_anomaly_arr.size() == n_cells_fast:
		tta_input = map.temperature_transport_anomaly_arr
	else:
		if _generator._gdext_sea_ice_tta_buf.size() != n_cells_fast:
			_generator._gdext_sea_ice_tta_buf.resize(n_cells_fast)
		tta_input = _generator._gdext_sea_ice_tta_buf
		for i_tta in range(n_cells_fast):
			tta_input[i_tta] = cells_fast[i_tta].temperature_transport_anomaly
	var upw_input: PackedFloat32Array = map.upwelling_strength_arr \
			if map.upwelling_strength_arr.size() == n_cells_fast \
			else _generator._gdext_sea_ice_upw_buf
	if upw_input.size() != n_cells_fast:
		_generator._gdext_sea_ice_upw_buf.resize(n_cells_fast)
		upw_input = _generator._gdext_sea_ice_upw_buf
		for i_upw in range(n_cells_fast):
			upw_input[i_upw] = cells_fast[i_upw].upwelling_strength
	var temp_input: PackedFloat32Array = map.temp_arr \
			if map.temp_arr.size() == n_cells_fast \
			else _generator._gdext_sea_ice_temp_buf
	if temp_input.size() != n_cells_fast:
		_generator._gdext_sea_ice_temp_buf.resize(n_cells_fast)
		temp_input = _generator._gdext_sea_ice_temp_buf
		for i_temp in range(n_cells_fast):
			temp_input[i_temp] = cells_fast[i_temp].temperature
	var insol_input: PackedFloat32Array = _generator._sea_ice_insolation_input(map, cells_fast, season_phase)
	var pack_ms: float = (Time.get_ticks_usec() - t_pack_us) / 1000.0
	var water_ids: PackedByteArray = PackedByteArray([
		int(TerrainType.TERRAIN.OCEAN) & 0xFF,
		int(TerrainType.TERRAIN.COAST) & 0xFF,
		int(TerrainType.TERRAIN.LAKE) & 0xFF,
		int(TerrainType.TERRAIN.REEF) & 0xFF,
		int(TerrainType.TERRAIN.KELP) & 0xFF,
		int(TerrainType.TERRAIN.SEA_ICE) & 0xFF,
	])
	var knobs: Dictionary = {
		"n_cells": n_cells_fast,
		# C++ 端会用 dt_days 乘一次；这里传原始 per-day 速率，避免 dt^2 过冲。
		"k_freeze": k_freeze,
		"k_melt": k_melt,
		"dt_days": dt_days,
		"t_form": t_form,
		"t_melt": t_melt,
		"contagion": contagion,
		"threshold": threshold,
		"hysteresis": hysteresis,
		"ice_delay": ice_delay,
		"enable_ocean_heat_transport": bool(_generator._last_cfg.enable_ocean_heat_transport),
		"terrain_lake_id": int(TerrainType.TERRAIN.LAKE),
		"terrain_sea_ice_id": int(TerrainType.TERRAIN.SEA_ICE),
		"terrain_ocean_id": int(TerrainType.TERRAIN.OCEAN),
		"water_terrain_ids": water_ids,
		"neighbor_indices": nb_idx_fast,
		"base_terrain_arr": base_terrain_input,
		"temp_transport_anomaly": tta_input,
		"upwelling_strength": upw_input,
		"insolation_now_arr": insol_input,
		"solar_gate_enabled": _generator._sea_ice_solar_gate_enabled(cp),
		"freeze_insol_low": float(cp.sea_ice_freeze_insol_low),
		"freeze_insol_high": float(cp.sea_ice_freeze_insol_high),
		"solar_melt_start": float(cp.sea_ice_solar_melt_start),
		"solar_melt_gain": float(cp.sea_ice_solar_melt_gain),
		"min_thick_ice_solar_exposure": float(cp.sea_ice_min_thick_ice_solar_exposure) if cp.get("sea_ice_min_thick_ice_solar_exposure") != null else 0.32,
		"daily_delta_cap": float(cp.sea_ice_daily_delta_cap) if cp.get("sea_ice_daily_delta_cap") != null else 0.070,
		"edge_mix_rate": float(cp.sea_ice_edge_mix_rate) if cp.get("sea_ice_edge_mix_rate") != null else 0.035,
		"cell_temperature_arr": temp_input,
	}
	var refresh_ms: float = 0.0
	if _generator._data_core_world_ext.has_method("refresh_slots_from_map"):
		var t_refresh_us: int = Time.get_ticks_usec()
		_generator._data_core_world_ext.refresh_slots_from_map()
		refresh_ms = (Time.get_ticks_usec() - t_refresh_us) / 1000.0
	# [BUG-FIX 2026-05-23 海冰看似不动] 在 C++ pass 修改 SIF 之前，先 snapshot
	# pre-pass 状态。dense_sync_chunk 阶段会用它和 post-pass 比对，对真正变化
	# 的 cell 调 mark_dirty_indexed —— 否则 atlas pipeline 永远拿不到 SIF dirty。
	# 见 _run_sea_ice_state_machine_slice DENSE_SYNC_CHUNK 分支注释。
	var pre_sif_snapshot: PackedFloat32Array = PackedFloat32Array()
	if map.sea_ice_frac_arr.size() == n_cells_fast:
		pre_sif_snapshot = map.sea_ice_frac_arr.duplicate()
	var t_native_us: int = Time.get_ticks_usec()
	var rc: float = float(_generator._data_core_world_ext.run_sea_ice_daily_pass(knobs, season_phase))
	var dispatch_path: String = "scalar"
	if rc < 0.0 and _generator._data_core_world_ext.has_method("run_sea_ice_daily_pass_thread"):
		dispatch_path = "thread_fallback"
		rc = float(_generator._data_core_world_ext.run_sea_ice_daily_pass_thread(knobs, season_phase, 4))
	var native_wall_ms: float = (Time.get_ticks_usec() - t_native_us) / 1000.0
	if rc < 0.0:
		_generator._gdext_sea_ice_fallbacks += 1
		return false
	var facade_on: bool = false
	if n_cells_fast > 0 and cells_fast[0] != null:
		var c0_sync: HexCell = cells_fast[0] as HexCell
		facade_on = c0_sync != null and c0_sync.is_facade_enabled()
	_generator._sea_ice_state_machine = {
		"token": token,
		"map_id": map.get_instance_id(),
		"season_phase": season_phase,
		"stage": _generator._SEA_ICE_STAGE_DENSE_SYNC_CHUNK,
		"cells": cells_fast,
		"n": n_cells_fast,
		"facade_on": facade_on,
		"sync_cursor": 0,
		"flip_cursor": 0,
		"flip_to_ice_list": knobs.get("flip_to_ice_list", PackedInt32Array()),
		"flip_to_base_list": knobs.get("flip_to_base_list", PackedInt32Array()),
		"flip_to_base_terrain": knobs.get("flip_to_base_terrain", PackedByteArray()),
		"pack_ms": pack_ms,
		"refresh_ms": refresh_ms,
		"native_ms": rc,
		"native_wall_ms": native_wall_ms,
		"sync_ms": 0.0,
		"flip_ms": 0.0,
		"total_start_us": t_total_us,
		"water": int(knobs.get("stat_water_count", 0)),
		"flipped": int(knobs.get("stat_flipped_count", 0)),
		"dispatch_path": dispatch_path,
		# [BUG-FIX 2026-05-23 海冰看似不动] pre-pass SIF 快照：dense_sync_chunk 用
		# 来比对找真正变化 cell + 显式 mark_dirty_indexed。见同函数注释。
		"pre_sif_snapshot": pre_sif_snapshot,
		"dirty_marked_count": 0,
	}
	# [DIAG 2026-05-23] 海冰不动排障：状态机入口（实际运行主路径）。
	# 每个日历年长 + 前 5 次打印一次温度 / SIF 分布。
	# 关键问诊：t_eff 实际有没有 < t_form？SIF 是否在累积但卡在 threshold 下？
	if _generator._gdext_sea_ice_runs < 5 or _generator._is_annual_log_tick(_generator._gdext_sea_ice_runs):
		var _diag_water: int = 0
		var _diag_below_form: int = 0
		var _diag_sif_pos: int = 0
		var _diag_sif_near_thr: int = 0
		var _diag_t_min: float = 9.99
		var _diag_t_max: float = -9.99
		var _diag_t_sum: float = 0.0
		var _diag_t_min_water: float = 9.99
		var _diag_sif_max: float = 0.0
		var _diag_sif_sum: float = 0.0
		var _diag_d_frac_max: float = 0.0    # 单 cell 单 pass 最大 d_frac 估算
		var _terrain_arr_diag: PackedByteArray = map.terrain_arr
		var _sif_arr_diag: PackedFloat32Array = map.sea_ice_frac_arr
		var _temp_n: int = temp_input.size()
		var _sif_n: int = _sif_arr_diag.size()
		var _terr_n: int = _terrain_arr_diag.size()
		for _i_diag in range(n_cells_fast):
			var _t_d: float = temp_input[_i_diag] if _i_diag < _temp_n else 0.0
			if _t_d < _diag_t_min: _diag_t_min = _t_d
			if _t_d > _diag_t_max: _diag_t_max = _t_d
			_diag_t_sum += _t_d
			var _terr_d: int = int(_terrain_arr_diag[_i_diag]) if _i_diag < _terr_n else -1
			var _is_w: bool = (_terr_d == int(TerrainType.TERRAIN.OCEAN) \
				or _terr_d == int(TerrainType.TERRAIN.COAST) \
				or _terr_d == int(TerrainType.TERRAIN.REEF) \
				or _terr_d == int(TerrainType.TERRAIN.KELP) \
				or _terr_d == int(TerrainType.TERRAIN.SEA_ICE))
			if _is_w:
				_diag_water += 1
				if _t_d < _diag_t_min_water: _diag_t_min_water = _t_d
				if _t_d < t_form:
					_diag_below_form += 1
					var _df: float = k_freeze_scaled * (t_form - _t_d)
					if _df > _diag_d_frac_max: _diag_d_frac_max = _df
				var _sf_d: float = _sif_arr_diag[_i_diag] if _i_diag < _sif_n else 0.0
				_diag_sif_sum += _sf_d
				if _sf_d > _diag_sif_max: _diag_sif_max = _sf_d
				if _sf_d > 0.01: _diag_sif_pos += 1
				if _sf_d >= threshold * 0.5 and _sf_d < threshold: _diag_sif_near_thr += 1
		var _avg_t: float = _diag_t_sum / max(1, n_cells_fast)
		var _avg_sif_w: float = _diag_sif_sum / max(1, _diag_water)
		# [DIAG 2026-05-23 四轮] 海冰看似不动排障：把 C++ 端写回的 flip 列表 + 计数也打出来。
		# 关键问诊：terrain 真的没翻吗？flip_to_ice_list 有没有元素？
		var _flip_to_ice_diag: PackedInt32Array = knobs.get("flip_to_ice_list", PackedInt32Array())
		var _flip_to_base_diag: PackedInt32Array = knobs.get("flip_to_base_list", PackedInt32Array())
		var _stat_water_diag: int = int(knobs.get("stat_water_count", 0))
		var _stat_flipped_diag: int = int(knobs.get("stat_flipped_count", 0))
		# 当前 terrain 已是 SEA_ICE 的 cell 数（用于交叉核对：若已翻 cell 多但 SIF avg_w 仍低 = 渲染层问题）
		var _existing_ice_terrain: int = 0
		for _i_terr in range(n_cells_fast):
			if _i_terr < _terr_n and int(_terrain_arr_diag[_i_terr]) == int(TerrainType.TERRAIN.SEA_ICE):
				_existing_ice_terrain += 1
		print("[sea_ice/DIAG-SM] run#%d phase=%.3f | thr_eff t_form=%.3f t_melt=%.3f flip_thr=%.3f | k_f=%.3f k_m=%.3f dt=%.2f | temp all min=%.3f max=%.3f avg=%.3f | water n=%d t_min_w=%.3f below_form=%d (%.1f%%) max_dfrac=%.4f | SIF pos=%d max=%.3f avg_w=%.4f near_thr=%d | FLIP to_ice=%d to_base=%d stat_water=%d stat_flipped=%d existing_ice_terr=%d | climate_anom=%.3f" % [
			_generator._gdext_sea_ice_runs + 1, season_phase,
			t_form, t_melt, threshold,
			k_freeze_scaled, k_melt_scaled, dt_days,
			_diag_t_min, _diag_t_max, _avg_t,
			_diag_water, _diag_t_min_water,
			_diag_below_form, 100.0 * float(_diag_below_form) / max(1, _diag_water), _diag_d_frac_max,
			_diag_sif_pos, _diag_sif_max, _avg_sif_w, _diag_sif_near_thr,
			_flip_to_ice_diag.size(), _flip_to_base_diag.size(),
			_stat_water_diag, _stat_flipped_diag, _existing_ice_terrain,
			climate_anomaly_now,
		])
	_generator._gdext_sea_ice_runs += 1
	_generator._gdext_sea_ice_total_ms += rc
	return true



func _run_sea_ice_state_machine_slice(map: MapData, season_phase: float, token: int) -> Dictionary:
	if _generator._sea_ice_state_machine.is_empty() \
			or int(_generator._sea_ice_state_machine.get("map_id", -1)) != map.get_instance_id() \
			or int(_generator._sea_ice_state_machine.get("token", 0)) != token:
		if not _generator._begin_sea_ice_state_machine(map, season_phase, token):
			var fb: Dictionary = _generator._run_climate_pass_legacy_fallback(_generator._CLIMATE_PASS_SEA_ICE, map, season_phase, token, "native_unavailable")
			_generator._climate_pass_states.erase(_generator._CLIMATE_PASS_SEA_ICE)
			return fb
		var native_result: Dictionary = _generator._make_climate_pass_result(_generator._CLIMATE_PASS_SEA_ICE, false, 0.0, 0, 0, 0, _generator._CLIMATE_PASS_STATUS_RUNNING, token, _generator._SEA_ICE_STAGE_NATIVE_COMPUTE)
		native_result["cursor_remaining"] = int(_generator._sea_ice_state_machine.get("n", 0))
		native_result["budget_cells"] = _generator._sea_ice_slice_budget_cells()
		return native_result
	var stage: String = str(_generator._sea_ice_state_machine.get("stage", _generator._SEA_ICE_STAGE_DENSE_SYNC_CHUNK))
	var n: int = int(_generator._sea_ice_state_machine.get("n", 0))
	var budget: int = _generator._sea_ice_slice_budget_cells()
	if stage == _generator._SEA_ICE_STAGE_DENSE_SYNC_CHUNK:
		var sync_start: int = int(_generator._sea_ice_state_machine.get("sync_cursor", 0))
		var sync_end: int = mini(n, sync_start + budget)
		var t_sync_us: int = Time.get_ticks_usec()
		if bool(_generator._sea_ice_state_machine.get("facade_on", false)) and _generator._data_core_world != null and map.sea_ice_frac_arr.size() >= n:
			var cid_si: int = _generator._data_core_world.component_id(DCComponentIds.CELL_SEA_ICE_FRAC)
			if cid_si >= 0 and _generator._data_core_world.has_method("write_f32_indexed"):
				var idx: PackedInt32Array = PackedInt32Array()
				var vals: PackedFloat32Array = PackedFloat32Array()
				idx.resize(sync_end - sync_start)
				vals.resize(sync_end - sync_start)
				for k in range(sync_end - sync_start):
					var ci: int = sync_start + k
					idx[k] = ci
					vals[k] = map.sea_ice_frac_arr[ci]
				_generator._data_core_world.write_f32_indexed(cid_si, idx, vals)
				# [B-Surgical 2026-05-23 海冰看似不动] 同步写 DCWorldExt 的 SIF slot。
				# 真因：C++ ice atlas raster（world_ext.cpp::encode_ice_state_atlas_*）
				# 从 DCWorldExt 自己的 cell_sea_ice_frac slot.arr_f32 读，不读
				# MapData.sea_ice_frac_arr，也不读 GDScript DCWorld。状态机只写
				# MapData + GDScript DCWorld，DCWorldExt slot 永远停留在初始 0 →
				# atlas pixel 全 0 → 视觉上海冰一直不动。
				# 修复：在已经备好 idx/vals 的同一处，向 DCWorldExt 镜像一次。
				# 双 world 架构由 GDScript DCWorld（ECS 容器）+ DCWorldExt（C++ 镜像
				# slot）组成，本来就是 superset/subset 关系；这里属于补足缺失的一条
				# 镜像链路（B-Surgical），不动其它系统的写入路径。
				# 见 docs/architecture/development-guide.md。
				if _generator._data_core_world_ext != null \
						and _generator._data_core_world_ext.has_method("write_f32_indexed") \
						and _generator._data_core_world_ext.has_method("component_id"):
					# [B-Surgical 命名空间不一致] DCComponentIds 用点号风格
					# (`cell.sea_ice_frac`)，但 DCWorldExt 的 BIND_TABLE 用下划线
					# 风格 (`cell_sea_ice_frac`，见 component_bind_table.gen.h)。
					# C++ component_id 是按字面量 hash 查表，找不到点号版本。
					# 这里两种都试一遍，下划线版作为 ext 端的真名 fallback。
					var cid_si_ext: int = int(_generator._data_core_world_ext.component_id(DCComponentIds.CELL_SEA_ICE_FRAC))
					if cid_si_ext < 0:
						cid_si_ext = int(_generator._data_core_world_ext.component_id(&"cell_sea_ice_frac"))
					if cid_si_ext >= 0:
						_generator._data_core_world_ext.write_f32_indexed(cid_si_ext, idx, vals)
				# [BUG-FIX 2026-05-23 海冰看似不动] C++ sea_ice pass 直接改 DCWorld
				# slot.arr_f32 + _flush_slot_to_map(set MapData)，slot 已是新值。
				# 上面 write_f32_indexed 的 value-diff 因此命中"未变" → 不 mark dirty
				# → atlas_pipeline read_and_clear_dirty_mask 拿不到 SIF 变化 cell
				# → ice_state_atlas 永远空 → 海冰看似不动。
				# 修复：用 _begin 时缓存的 pre-pass SIF 快照比对 + 显式 mark_dirty_indexed。
				# 海冰 pass 一天一次，开销可接受。
				if _generator._data_core_world.has_method("mark_dirty_indexed"):
					var pre_arr: PackedFloat32Array = _generator._sea_ice_state_machine.get("pre_sif_snapshot", PackedFloat32Array())
					if pre_arr.size() >= sync_end:
						var dirty_idx: PackedInt32Array = PackedInt32Array()
						dirty_idx.resize(sync_end - sync_start)
						var dw: int = 0
						# [DIAG 2026-05-23 海冰排障第二轮] 收集 SIF>0 的 dirty cell 计数
						# + 最大 SIF 值，用来核对 atlas COMMIT 收到的 nonzero=0 是否
						# 因为 dirty_idx 里的 cell SIF 实际上都是 0（量化后 byte=0）。
						var dw_pos: int = 0
						var dw_sif_max: float = 0.0
						for k2 in range(sync_end - sync_start):
							var ci2: int = sync_start + k2
							var v_now: float = map.sea_ice_frac_arr[ci2]
							if v_now != pre_arr[ci2]:
								dirty_idx[dw] = ci2
								dw += 1
								if v_now > 0.0:
									dw_pos += 1
									if v_now > dw_sif_max:
										dw_sif_max = v_now
						if dw > 0:
							dirty_idx.resize(dw)
							_generator._data_core_world.mark_dirty_indexed(dirty_idx)
							_generator._sea_ice_state_machine["dirty_marked_count"] = int(_generator._sea_ice_state_machine.get("dirty_marked_count", 0)) + dw
							_generator._sea_ice_state_machine["dirty_marked_sif_pos"] = int(_generator._sea_ice_state_machine.get("dirty_marked_sif_pos", 0)) + dw_pos
							var prev_max: float = float(_generator._sea_ice_state_machine.get("dirty_marked_sif_max", 0.0))
							if dw_sif_max > prev_max:
								_generator._sea_ice_state_machine["dirty_marked_sif_max"] = dw_sif_max
			else:
				var cells_sync: Array = _generator._sea_ice_state_machine.get("cells", [])
				for i_sync in range(sync_start, sync_end):
					(cells_sync[i_sync] as HexCell).sea_ice_fraction = map.sea_ice_frac_arr[i_sync]
		else:
			var cells_sync_fb: Array = _generator._sea_ice_state_machine.get("cells", [])
			for i_sync_fb in range(sync_start, sync_end):
				(cells_sync_fb[i_sync_fb] as HexCell).sea_ice_fraction = map.sea_ice_frac_arr[i_sync_fb]
		_generator._sea_ice_state_machine["sync_ms"] = float(_generator._sea_ice_state_machine.get("sync_ms", 0.0)) + (Time.get_ticks_usec() - t_sync_us) / 1000.0
		_generator._sea_ice_state_machine["sync_cursor"] = sync_end
		if sync_end >= n:
			_generator._sea_ice_state_machine["stage"] = _generator._SEA_ICE_STAGE_TERRAIN_FLIP_CHUNK
		var sync_result: Dictionary = _generator._make_climate_pass_result(_generator._CLIMATE_PASS_SEA_ICE, false, (Time.get_ticks_usec() - t_sync_us) / 1000.0,
				sync_end - sync_start, sync_start, sync_end, _generator._CLIMATE_PASS_STATUS_RUNNING, token, _generator._SEA_ICE_STAGE_DENSE_SYNC_CHUNK)
		sync_result["cursor_remaining"] = maxi(0, n - sync_end)
		sync_result["budget_cells"] = budget
		sync_result["next_stage"] = str(_generator._sea_ice_state_machine.get("stage", _generator._SEA_ICE_STAGE_DENSE_SYNC_CHUNK))
		return sync_result
	if stage == _generator._SEA_ICE_STAGE_TERRAIN_FLIP_CHUNK:
		var flip_to_ice_list: PackedInt32Array = _generator._sea_ice_state_machine.get("flip_to_ice_list", PackedInt32Array())
		var flip_to_base_list: PackedInt32Array = _generator._sea_ice_state_machine.get("flip_to_base_list", PackedInt32Array())
		var flip_to_base_terrain: PackedByteArray = _generator._sea_ice_state_machine.get("flip_to_base_terrain", PackedByteArray())
		var total_flips: int = flip_to_ice_list.size() + flip_to_base_list.size()
		var flip_start: int = int(_generator._sea_ice_state_machine.get("flip_cursor", 0))
		var flip_end: int = mini(total_flips, flip_start + budget)
		var t_flip_us: int = Time.get_ticks_usec()
		var flip_batch: Dictionary = _generator._build_sea_ice_flip_batch(flip_to_ice_list, flip_to_base_list, flip_to_base_terrain, flip_start, flip_end)
		var flip_diag: Dictionary = _generator._apply_sea_ice_terrain_flips_indexed(
				map,
				flip_batch.get("indices", PackedInt32Array()),
				flip_batch.get("terrain", PackedByteArray()),
				true)
		if bool(flip_diag.get("applied", false)):
			_generator._sea_ice_state_machine["terrain_flip_indexed_count"] = int(_generator._sea_ice_state_machine.get("terrain_flip_indexed_count", 0)) + int(flip_diag.get("count", 0))
		else:
			_generator._sea_ice_state_machine["terrain_flip_legacy_fallback"] = true
			_generator._sea_ice_state_machine["terrain_flip_fallback_reason"] = str(flip_diag.get("fallback_reason", "unknown"))
			var sea_ice_id: int = int(TerrainType.TERRAIN.SEA_ICE) & 0xFF
			for f in range(flip_start, flip_end):
				if f < flip_to_ice_list.size():
					var idx_i: int = flip_to_ice_list[f]
					if idx_i >= 0 and idx_i < n:
						var sm_cell_i: HexCell = map.cell_at(idx_i)
						if sm_cell_i != null:
							_generator._set_cell_runtime_terrain(map, sm_cell_i, sea_ice_id, true, -1.0, sm_cell_i.snow_cover)
				else:
					var base_i: int = f - flip_to_ice_list.size()
					var idx_b: int = flip_to_base_list[base_i]
					if idx_b >= 0 and idx_b < n and base_i < flip_to_base_terrain.size():
						var target_terr: int = int(flip_to_base_terrain[base_i])
						var sm_cell_b: HexCell = map.cell_at(idx_b)
						if sm_cell_b != null:
							_generator._set_cell_runtime_terrain(map, sm_cell_b, target_terr, true, -1.0, sm_cell_b.snow_cover)
		_generator._sea_ice_state_machine["flip_ms"] = float(_generator._sea_ice_state_machine.get("flip_ms", 0.0)) + (Time.get_ticks_usec() - t_flip_us) / 1000.0
		_generator._sea_ice_state_machine["flip_cursor"] = flip_end
		if flip_end >= total_flips:
			_generator._sea_ice_state_machine["stage"] = _generator._SEA_ICE_STAGE_COMMIT
		var flip_result: Dictionary = _generator._make_climate_pass_result(_generator._CLIMATE_PASS_SEA_ICE, false, (Time.get_ticks_usec() - t_flip_us) / 1000.0,
				flip_end - flip_start, flip_start, flip_end, _generator._CLIMATE_PASS_STATUS_RUNNING, token, _generator._SEA_ICE_STAGE_TERRAIN_FLIP_CHUNK)
		flip_result["cursor_remaining"] = maxi(0, total_flips - flip_end)
		flip_result["budget_cells"] = budget
		flip_result["next_stage"] = str(_generator._sea_ice_state_machine.get("stage", _generator._SEA_ICE_STAGE_TERRAIN_FLIP_CHUNK))
		flip_result["terrain_flip_path"] = "legacy_set_cell_runtime_terrain" if bool(_generator._sea_ice_state_machine.get("terrain_flip_legacy_fallback", false)) else "indexed"
		flip_result["terrain_flip_count"] = int(_generator._sea_ice_state_machine.get("terrain_flip_indexed_count", 0))
		flip_result["fallback_reason"] = str(_generator._sea_ice_state_machine.get("terrain_flip_fallback_reason", ""))
		return flip_result
	var t_commit_us: int = Time.get_ticks_usec()
	if bool(_generator._sea_ice_state_machine.get("terrain_flip_legacy_fallback", false)):
		_generator._write_runtime_enum_axes_dense(map)
	var water_count: int = int(_generator._sea_ice_state_machine.get("water", 0))
	var flipped_count: int = int(_generator._sea_ice_state_machine.get("flipped", 0))
	# [BUG-FIX 2026-05-23 海冰看似不动] 诊断：本 pass 我们显式 mark_dirty 的 cell 数。
	# 期望：当 SIF 有变化时 dirty_marked > 0；若仍 ==0 而 SIF 在变，说明 fix 没生效。
	# 节流：前 5 次 + 每个日历年长（与 DIAG-SM 同步）。
	var _dirty_marked_count: int = int(_generator._sea_ice_state_machine.get("dirty_marked_count", 0))
	if _generator._gdext_sea_ice_runs <= 5 or _generator._is_annual_log_tick(_generator._gdext_sea_ice_runs):
		print("[sea_ice/DIRTY-MARK] run#%d marked_dirty_cells=%d (sif_pos=%d sif_max=%.4f) water=%d flipped=%d" % [
			_generator._gdext_sea_ice_runs, _dirty_marked_count,
			int(_generator._sea_ice_state_machine.get("dirty_marked_sif_pos", 0)),
			float(_generator._sea_ice_state_machine.get("dirty_marked_sif_max", 0.0)),
			water_count, flipped_count
		])
	if water_count > 0:
		var ratio: float = float(flipped_count) / float(water_count)
		if ratio > 0.03:
			push_warning("[sea_ice_daily/F.4] %d/%d (%.1f%%) cells flipped on phase=%.3f — possible bulk-switch regression" % [
				flipped_count, water_count, ratio * 100.0, season_phase
			])
	_generator._last_sea_ice_daily_breakdown = {
		"path": "gdext_state_machine",
		"stage": _generator._SEA_ICE_STAGE_COMMIT,
		"pack_ms": float(_generator._sea_ice_state_machine.get("pack_ms", 0.0)),
		"refresh_ms": float(_generator._sea_ice_state_machine.get("refresh_ms", 0.0)),
		"native_ms": float(_generator._sea_ice_state_machine.get("native_ms", 0.0)),
		"native_wall_ms": float(_generator._sea_ice_state_machine.get("native_wall_ms", 0.0)),
		"sync_ms": float(_generator._sea_ice_state_machine.get("sync_ms", 0.0)),
		"flip_ms": float(_generator._sea_ice_state_machine.get("flip_ms", 0.0)),
		"terrain_flip_path": "legacy_set_cell_runtime_terrain" if bool(_generator._sea_ice_state_machine.get("terrain_flip_legacy_fallback", false)) else "indexed",
		"terrain_flip_count": int(_generator._sea_ice_state_machine.get("terrain_flip_indexed_count", 0)),
		"terrain_flip_fallback_reason": str(_generator._sea_ice_state_machine.get("terrain_flip_fallback_reason", "")),
		"commit_ms": (Time.get_ticks_usec() - t_commit_us) / 1000.0,
		"total_wall_ms": (Time.get_ticks_usec() - int(_generator._sea_ice_state_machine.get("total_start_us", Time.get_ticks_usec()))) / 1000.0,
		"water": water_count,
		"flipped": flipped_count,
	}
	_generator._dump_sea_ice_breakdown_if_slow()
	_generator._gdext_ocean_anomaly_buf_cached = PackedFloat32Array()
	_generator._climate_pass_states.erase(_generator._CLIMATE_PASS_SEA_ICE)
	_generator._sea_ice_state_machine = {}
	return _generator._make_climate_pass_result(_generator._CLIMATE_PASS_SEA_ICE, true, (Time.get_ticks_usec() - t_commit_us) / 1000.0,
			0, -1, -1, _generator._CLIMATE_PASS_STATUS_DONE, token, _generator._SEA_ICE_STAGE_COMMIT)


# ─── [S2 fix 2026-05-23 三轮] sea_ice dt_days 补偿辅助函数 ────────────────────
# 抽自原 _apply_sea_ice_daily_pass 内联段。两条调用链共用：
#   - SUS sliced 路径：_begin_sea_ice_state_machine（实际运行时主路径）
#   - 非 sliced 整轮路径：_apply_sea_ice_daily_pass
# 同 tick 只命中其中一条，所以游标 _last_sea_ice_pass_day 不会双更新。
#
# 返回 dt_days ∈ (0, max_dt_days]（默认 30）。不要在传给 C++ 前预乘 k，避免 d_frac 变成 dt^2。
# 默认 clamp 上限 30：防 pause 复位 / 开局过冲；native daily sliced ACTIVE
# 可传 1.0，避免把整个 graph round 间隔折叠成一次批量融化。下限 ≥ 0 后
# 再 floor 到 1.0：阻断同 tick 重入。第一次调用保持默认 1.0。

func _consume_sea_ice_dt_days(max_dt_days: float = 30.0) -> float:
	var dt_days: float = 1.0
	if _generator._world_clock_ref != null:
		var now_day_v = _generator._world_clock_ref.get("current_day")
		if now_day_v != null:
			var now_day: float = float(now_day_v)
			if _generator._last_sea_ice_pass_day >= 0.0:
				dt_days = clampf(now_day - _generator._last_sea_ice_pass_day, 0.0, maxf(0.0, max_dt_days))
				if dt_days <= 0.0:
					dt_days = 1.0  # 同 tick 重入兜底
			# else: 第一次调用，保持 dt_days = 1.0 默认
			_generator._last_sea_ice_pass_day = now_day
	# 诊断：每个日历年长或前 5 次打印一次 dt_days，验证补偿是否在工作。
	# Fix #11 second pass (2026-06-16) mobile：x20 速度下 1 仿真年 ~6 秒，mobile
	# 每秒触发 ~0.16 次 print。logcat overhead ~10ms/行 → 1.6ms/秒。改为 mobile 上
	# 前 5 次后只在 sea_ice 行为异常时打（dt_days > 10 或 < 0.5 = 速度档异常）。
	var _sea_ice_call_total: int = _generator._gdext_sea_ice_runs + _generator._gdext_sea_ice_fallbacks
	var _should_log_dt: bool = _sea_ice_call_total < 5
	if not _should_log_dt and not OS.has_feature("mobile"):
		_should_log_dt = _generator._is_annual_log_tick(_sea_ice_call_total)
	if not _should_log_dt and OS.has_feature("mobile"):
		# mobile：超出 5 次后只在 dt_days 偏离常规时打（异常 dt 才有诊断价值）。
		_should_log_dt = dt_days > 10.0 or dt_days < 0.5
	if _should_log_dt and PKLog.enabled:
		print("[sea_ice/dt] call#%d dt_days=%.3f (last_pass_day=%.3f, k x%.2f)" % [
			_generator._gdext_sea_ice_runs + _generator._gdext_sea_ice_fallbacks + 1,
			dt_days,
			_generator._last_sea_ice_pass_day,
			dt_days,
		])
	return dt_days


# [thermal dt 补偿 2026-06-16] 与 _consume_sea_ice_dt_days 对称：返回本次 climate
# pass_a 距上次实际经过的仿真天数 ∈ (0, 30]。C++/GDScript pass_a 用它把单日 α
# 换算为多日等效 α_eff、并把 delta_cap 乘以 dt。
# 同一仿真日内多个 knob builder（cp_struct / async kick / fallback 循环）可能各调
# 一次：用 _climate_dt_cached_day 缓存，保证返回同一 dt 且只推进一次游标。

func _consume_climate_dt_days() -> float:
	var dt_days: float = 1.0
	if _generator._world_clock_ref != null:
		var now_day_v = _generator._world_clock_ref.get("current_day")
		if now_day_v != null:
			var now_day: float = float(now_day_v)
			# 同一仿真日重复取值 → 命中缓存，不再推进游标。
			if _generator._climate_dt_cached_day >= 0.0 and is_equal_approx(now_day, _generator._climate_dt_cached_day):
				return _generator._climate_dt_cached_val
			if _generator._last_climate_pass_day >= 0.0:
				dt_days = clampf(now_day - _generator._last_climate_pass_day, 0.0, 30.0)
				if dt_days <= 0.0:
					dt_days = 1.0  # 同 tick 重入兜底
			# else: 第一次调用，保持 dt_days = 1.0 默认
			_generator._last_climate_pass_day = now_day
			_generator._climate_dt_cached_day = now_day
			_generator._climate_dt_cached_val = dt_days
	return dt_days


# [weather transition dt 2026-06-28] 与 _consume_climate_dt_days 同构：返回上次天气求解到本次的
# 真实游戏天数差，喂给 weather_transition_dt_days knob。同-tick 多次取值命中缓存、只推进一次游标。

func _consume_weather_dt_days() -> float:
	var dt_days: float = 1.0
	if _generator._world_clock_ref != null:
		var now_day_v = _generator._world_clock_ref.get("current_day")
		if now_day_v != null:
			var now_day: float = float(now_day_v)
			if _generator._weather_dt_cached_day >= 0.0 and is_equal_approx(now_day, _generator._weather_dt_cached_day):
				return _generator._weather_dt_cached_val
			if _generator._last_weather_pass_day >= 0.0:
				dt_days = clampf(now_day - _generator._last_weather_pass_day, 0.0, 30.0)
				if dt_days <= 0.0:
					dt_days = 1.0  # 同 tick 重入兜底
			# else: 第一次调用，保持 dt_days = 1.0 默认
			_generator._last_weather_pass_day = now_day
			_generator._weather_dt_cached_day = now_day
			_generator._weather_dt_cached_val = dt_days
	return dt_days


# QA 异常守卫：当日 SEA_ICE 翻转 cell 数 > 总水体数 3% 时打印一次 WARN
# （帮助定位"全图统一切换"的回归）。

func _build_climate_b_foliage_table() -> PackedFloat32Array:
	if _generator._gdext_climate_b_foliage_table_cached.size() > 0:
		return _generator._gdext_climate_b_foliage_table_cached
	_generator._gdext_climate_b_foliage_table_cached = VegetationType.foliage_biomass_table()
	return _generator._gdext_climate_b_foliage_table_cached


func _begin_ocean_heat_transport_sliced(map: MapData, season_phase: float, cp: ClimateProfile) -> bool:
	if map == null or cp == null or _generator._data_core_world_ext == null \
			or not _generator._data_core_world_ext.has_method("run_ocean_water_pass") \
			or not _generator._data_core_world_ext.has_method("run_ocean_land_pass"):
		return false
	var n: int = map.soa_size()
	var nb_idx: PackedInt32Array = map.neighbor_indices_packed()
	if n <= 0 or nb_idx.size() < n * 6:
		return false
	var cells: Array[HexCell] = map.iter_cells()
	var _dc_views: Dictionary = _generator._climate_views_from_world(cp)
	var _use_dc: bool = not _dc_views.is_empty()
	var temp_a: PackedFloat32Array = _dc_views["temp"] if _use_dc else map.temp_arr
	var temp_baseline_a: PackedFloat32Array = _dc_views["temp_baseline"] if _use_dc else map.temp_baseline_arr
	var elev_a: PackedFloat32Array = _dc_views["elevation"] if _use_dc else map.elevation_arr
	var lat_a: PackedFloat32Array = _dc_views["lat_norm"] if _use_dc else map.cell_lat_norm_arr
	var ema_init_a: PackedByteArray = _dc_views["ema_initialized"] if _use_dc else map.ema_initialized_arr
	var ocx_a: PackedFloat32Array = _dc_views["ocean_current_x"] if _use_dc else map.ocean_current_x_arr
	var ocy_a: PackedFloat32Array = _dc_views["ocean_current_y"] if _use_dc else map.ocean_current_y_arr
	if _generator._gdext_ocean_baseline_work_buf.size() != n:
		_generator._gdext_ocean_baseline_work_buf.resize(n)
	if _generator._gdext_ocean_temp_before_work_buf.size() != n:
		_generator._gdext_ocean_temp_before_work_buf.resize(n)
	if _generator._gdext_ocean_anomaly_work_buf.size() != n:
		_generator._gdext_ocean_anomaly_work_buf.resize(n)
	var baseline: PackedFloat32Array = _generator._gdext_ocean_baseline_work_buf
	var temp_before: PackedFloat32Array = _generator._gdext_ocean_temp_before_work_buf
	for i in range(n):
		if ema_init_a[i] != 0:
			baseline[i] = temp_baseline_a[i]
		else:
			var ny: float = lat_a[i] if lat_a.size() > i else _generator._cube_row_norm(cells[i], _generator._last_cfg)
			baseline[i] = _generator._compute_temperature(ny, elev_a[i])
		var t0: float = temp_a[i]
		temp_before[i] = _generator._valid_runtime_temp_or_baseline(t0, baseline[i])
	var anomaly: PackedFloat32Array = _generator._gdext_ocean_anomaly_work_buf
	var prev_anomaly: PackedFloat32Array = _generator._prepare_temperature_transport_anomaly_state(map, n, cells)
	for ai in range(n):
		anomaly[ai] = prev_anomaly[ai]
	var winter_boost: float = 1.0
	var effective_leak: float = float(_generator._last_cfg.COASTAL_HEAT_LEAK) * winter_boost
	var tta: Dictionary = _generator._temperature_transport_anomaly_knobs(cp)
	var water_knobs: Dictionary = {
		"n_cells": n,
		"advect_steps": max(0, _generator._last_cfg.OCEAN_HEAT_ADVECT_STEPS),
		"heat_mix": clampf(_generator._last_cfg.OCEAN_HEAT_MIX, 0.0, 1.0),
		"neighbor_indices": nb_idx,
		"baseline_arr": baseline,
		"temp_before_arr": temp_before,
		"anomaly_out": anomaly,
		"ocean_current_x_arr": ocx_a,
		"ocean_current_y_arr": ocy_a,
		"cold_transport_form_threshold": float(cp.sea_ice_form_threshold),
		"cold_transport_melt_threshold": float(cp.sea_ice_melt_threshold),
	}
	var land_knobs: Dictionary = {
		"n_cells": n,
		"effective_leak": effective_leak,
		"neighbor_indices": nb_idx,
		"anomaly_inout": anomaly,
		"fallback_baseline_arr": baseline,
		"ocean_current_x_arr": ocx_a,
		"ocean_current_y_arr": ocy_a,
	}
	_generator._apply_temperature_transport_anomaly_knobs(water_knobs, tta)
	_generator._apply_temperature_transport_anomaly_knobs(land_knobs, tta)
	_generator._climate_ocean_slice_state = {
		"map_id": map.get_instance_id(),
		"n": n,
		"cells": cells,
		"water_cursor": 0,
		"land_cursor": 0,
		"anomaly": anomaly,
		"baseline": baseline,
		"water_knobs": water_knobs,
		"land_knobs": land_knobs,
	}
	_generator._data_core_world_ext.refresh_slots_from_map()
	return true



func _ocean_slice_budget_cells() -> int:
	var cp = _generator._c()
	var slice_ms: float = 0.75
	if cp != null and cp.get("sim_slice_budget_ms") != null:
		slice_ms = float(cp.sim_slice_budget_ms)
	return clampi(int(round(700.0 * clampf(slice_ms / 0.75, 0.5, 1.5))), 256, 900)



func _make_climate_pass_result(pass_type: String, done: bool, elapsed_ms: float, processed_cells: int,
		cursor_start: int, cursor_end: int, status: String = "", token: int = 0,
		stage: String = "", abort_reason: String = "") -> Dictionary:
	var out_status: String = status
	if out_status == "":
		out_status = _generator._CLIMATE_PASS_STATUS_DONE if done else _generator._CLIMATE_PASS_STATUS_RUNNING
	return {
		"pass_type": pass_type,
		"done": done,
		"status": out_status,
		"elapsed_ms": elapsed_ms,
		"processed_cells": processed_cells,
		"cursor_start": cursor_start,
		"cursor_end": cursor_end,
		"budget_interrupted": not done,
		"token": token,
		"stage": stage if stage != "" else pass_type,
		"abort_reason": abort_reason,
	}



func _climate_pass_state_matches(pass_type: String, map: MapData, token: int = 0) -> bool:
	if not _generator._climate_pass_states.has(pass_type):
		return false
	var state: Dictionary = _generator._climate_pass_states[pass_type]
	if map != null and int(state.get("map_id", -1)) != map.get_instance_id():
		return false
	if token > 0 and int(state.get("token", 0)) != token:
		return false
	return str(state.get("status", "")) == _generator._CLIMATE_PASS_STATUS_RUNNING



func begin_climate_pass(pass_type: String, map: MapData, season_phase: float, opts: Dictionary = {}) -> Dictionary:
	var cp = _generator._c()
	if map == null or cp == null:
		return _generator._make_climate_pass_result(pass_type, true, 0.0, 0, -1, -1, _generator._CLIMATE_PASS_STATUS_FAILED, 0, pass_type, "missing_context")
	if _generator._climate_pass_state_matches(pass_type, map):
		return _generator._climate_pass_states[pass_type].duplicate(true)
	_generator._climate_pass_generation += 1
	var token: int = _generator._climate_pass_generation
	var stage: String = str(opts.get("stage", pass_type))
	var state: Dictionary = {
		"pass_type": pass_type,
		"token": token,
		"status": _generator._CLIMATE_PASS_STATUS_RUNNING,
		"map_id": map.get_instance_id(),
		"season_phase": season_phase,
		"stage": stage,
		"cursor": 0,
		"cursor_start": 0,
		"cursor_end": 0,
		"processed_cells": 0,
		"budget_cells": int(opts.get("budget_cells", _generator._ocean_slice_budget_cells())),
		"started_msec": Time.get_ticks_msec(),
	}
	match pass_type:
		_generator._CLIMATE_PASS_OCEAN_WATER, _generator._CLIMATE_PASS_OCEAN_LAND:
			if _generator._climate_ocean_slice_state.is_empty() \
					or int(_generator._climate_ocean_slice_state.get("map_id", -1)) != map.get_instance_id():
				if not _generator._begin_ocean_heat_transport_sliced(map, season_phase, cp):
					return _generator._make_climate_pass_result(pass_type, true, 0.0, 0, -1, -1, _generator._CLIMATE_PASS_STATUS_FAILED, token, stage, "begin_failed")
			state["n"] = int(_generator._climate_ocean_slice_state.get("n", 0))
			state["water_cursor"] = int(_generator._climate_ocean_slice_state.get("water_cursor", 0))
			state["land_cursor"] = int(_generator._climate_ocean_slice_state.get("land_cursor", 0))
		_generator._CLIMATE_PASS_SEA_ICE:
			state["n"] = map.cell_count()
		_:
			return _generator._make_climate_pass_result(pass_type, true, 0.0, 0, -1, -1, _generator._CLIMATE_PASS_STATUS_FAILED, token, stage, "unknown_pass")
	_generator._climate_pass_states[pass_type] = state
	return state.duplicate(true)



func abort_climate_pass(pass_type: String, reason: String = "abort") -> Dictionary:
	if not _generator._climate_pass_states.has(pass_type):
		return _generator._make_climate_pass_result(pass_type, true, 0.0, 0, -1, -1, _generator._CLIMATE_PASS_STATUS_ABORTED, 0, pass_type, reason)
	var state: Dictionary = _generator._climate_pass_states[pass_type]
	state["status"] = _generator._CLIMATE_PASS_STATUS_ABORTED
	state["abort_reason"] = reason
	state["ended_msec"] = Time.get_ticks_msec()
	_generator._climate_pass_states.erase(pass_type)
	if pass_type == _generator._CLIMATE_PASS_OCEAN_WATER or pass_type == _generator._CLIMATE_PASS_OCEAN_LAND:
		_generator._climate_ocean_slice_state.clear()
		_generator._gdext_ocean_anomaly_buf_cached = PackedFloat32Array()
		_generator._gdext_ocean_baseline_arr_cached = PackedFloat32Array()
		_generator._gdext_ocean_current_x_arr_cached = PackedFloat32Array()
		_generator._gdext_ocean_current_y_arr_cached = PackedFloat32Array()
		_generator._ocean_water_done_phase = NAN
	elif pass_type == _generator._CLIMATE_PASS_SEA_ICE:
		_generator._abort_sea_ice_state_machine(reason)
	return _generator._make_climate_pass_result(pass_type, true, 0.0, int(state.get("processed_cells", 0)),
			int(state.get("cursor_start", -1)), int(state.get("cursor_end", -1)),
			_generator._CLIMATE_PASS_STATUS_ABORTED, int(state.get("token", 0)), str(state.get("stage", pass_type)), reason)



func _abort_all_climate_passes(reason: String = "abort_all") -> void:
	var pass_types: Array = _generator._climate_pass_states.keys()
	for pass_type in pass_types:
		_generator.abort_climate_pass(str(pass_type), reason)
	_generator._climate_pass_states.clear()
	_generator._climate_ocean_slice_state.clear()
	_generator._gdext_ocean_anomaly_buf_cached = PackedFloat32Array()
	_generator._gdext_ocean_baseline_arr_cached = PackedFloat32Array()
	_generator._gdext_ocean_current_x_arr_cached = PackedFloat32Array()
	_generator._gdext_ocean_current_y_arr_cached = PackedFloat32Array()
	_generator._ocean_water_done_phase = NAN
	_generator._abort_sea_ice_state_machine(reason)



func run_climate_pass_slice(pass_type: String, map: MapData, season_phase: float, opts: Dictionary = {}) -> Dictionary:
	_generator._ensure_daily_pass_modules()
	var state: Dictionary = _generator.begin_climate_pass(pass_type, map, season_phase, opts)
	var token: int = int(state.get("token", 0))
	if str(state.get("status", "")) == _generator._CLIMATE_PASS_STATUS_FAILED:
		return _generator._run_climate_pass_legacy_fallback(pass_type, map, season_phase, token, str(state.get("abort_reason", "begin_failed")))
	if not _generator._climate_pass_state_matches(pass_type, map, token):
		return _generator._make_climate_pass_result(pass_type, true, 0.0, 0, -1, -1, _generator._CLIMATE_PASS_STATUS_ABORTED, token, pass_type, "stale_token")
	match pass_type:
		_generator._CLIMATE_PASS_OCEAN_WATER:
			return _generator._ocean_water_pass_module._run_ocean_water_pass_slice_impl(map, season_phase, token)
		_generator._CLIMATE_PASS_OCEAN_LAND:
			return _generator._ocean_land_pass_module._run_ocean_land_pass_slice_impl(map, season_phase, token)
		_generator._CLIMATE_PASS_SEA_ICE:
			return _generator._run_sea_ice_state_machine_slice(map, season_phase, token)
	return _generator._make_climate_pass_result(pass_type, true, 0.0, 0, -1, -1, _generator._CLIMATE_PASS_STATUS_FAILED, token, pass_type, "unknown_pass")


