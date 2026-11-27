extends "res://scripts/simulation/generator_context.gd"

const SeaIceStageMachine = preload("res://scripts/simulation/climate/sea_ice_stage_machine.gd")
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
	return SeaIceStageMachine._sea_ice_slice_budget_cells(self)


func _sea_ice_insolation_input(map: MapData, cells: Array, season_phase: float) -> PackedFloat32Array:
	return SeaIceStageMachine._sea_ice_insolation_input(self, map, cells, season_phase)


func _abort_sea_ice_state_machine(reason: String = "abort") -> void:
	SeaIceStageMachine._abort_sea_ice_state_machine(self, reason)


func _begin_sea_ice_state_machine(map: MapData, season_phase: float, token: int) -> bool:
	return SeaIceStageMachine._begin_sea_ice_state_machine(self, map, season_phase, token)


func _run_sea_ice_state_machine_slice(map: MapData, season_phase: float, token: int) -> Dictionary:
	return SeaIceStageMachine._run_sea_ice_state_machine_slice(self, map, season_phase, token)


func _consume_sea_ice_dt_days(max_dt_days: float = 30.0) -> float:
	return SeaIceStageMachine._consume_sea_ice_dt_days(self, max_dt_days)


# [thermal dt 补偿 2026-06-16] 与 _consume_sea_ice_dt_days 对称：返回本次 climate
# pass_a 距上次实际经过的仿真天数 ∈ (0, 30]。C++/GDScript pass_a 用它把单日 α
# 换算为多日等效 α_eff、并把 delta_cap 乘以 dt。
# 同一仿真日内多个 knob builder（cp_struct / async kick / fallback 循环）可能各调
# 一次：用 _climate_dt_cached_day 缓存，保证返回同一 dt 且只推进一次游标。

func _consume_climate_dt_days() -> float:
	var dt_days: float = 1.0
	if _generator._world_clock_ref != null:
		var now_day_v = _generator._get_runtime_climate_capture().sample_day()
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
