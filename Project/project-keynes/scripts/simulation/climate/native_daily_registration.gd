extends RefCounted

## Configures the native daily jobs and their visual publication consumers.


static func _configure_native_world_context(context, map: MapData, world: WorldData, cfg: MapConfig, hex_size: float) -> void:
	context._generator._native_daily_configured = false
	if context._generator._data_core_world_ext == null:
		return
	var cp = context._generator._c()
	var knobs: Dictionary = {
		"cell_count": map.cell_count() if map != null else 0,
		"hex_size": hex_size,
		# seam-advection-fix（2026-08-03）：经度环绕周期常驻到 DCWorldExt。climate/weather 的
		# 平流内核用 cell_pos_x 裸差分求方向，接缝邻居会拿到 ±(period − 列距) 的错向位移，
		# 在 col 0 / col width-1 形成一条方向恒定的风场/洋流经线伪影。C++ 侧用它做最小映像
		# 折叠。map_width 一并传，供 C++ 在 wrap_period_x 缺失时按同式回算。
		#
		# 单位必须是 size=1.0 的单位六边形空间，**不能乘 hex_size**：内核读的是
		# cell_pos_x slot，而 map_data.gd::_publish 用 cube_to_world(q, r, 1.0) 填它
		# （field_solver 的 _field_slice_cell_pos_scale 走 SoA 时同样取 1.0）。
		"map_width": int(map.width) if map != null else 0,
		"wrap_period_x": HexUtils.wrap_period_cell_pos_x(int(map.width)) if map != null else 0.0,
		"native_generation_mode": int(cp.get("native_generation_mode")) if cp != null and cp.get("native_generation_mode") != null else 0,
		"native_daily_sim_mode": int(cp.get("native_daily_sim_mode")) if cp != null and cp.get("native_daily_sim_mode") != null else 0,
		"native_render_prepare_mode": int(cp.get("native_render_prepare_mode")) if cp != null and cp.get("native_render_prepare_mode") != null else 0,
		"native_daily_perf_target_ms": float(cp.get("native_daily_perf_target_ms")) if cp != null and cp.get("native_daily_perf_target_ms") != null else 1.0,
		"shadow_diff_enabled": bool(cp.get("native_shadow_diff_enabled")) if cp != null and cp.get("native_shadow_diff_enabled") != null else true,
		"weather_albedo_stride": int(cp.weather_albedo_stride) if cp != null else 10,
		"weather_vegetation_dynamics_stride": int(cp.weather_vegetation_dynamics_stride) if cp != null else 10,
		"weather_feedback_stride": int(cp.weather_feedback_stride) if cp != null else 10,
		"season_refresh_period_ticks": int(cp.season_refresh_period_ticks) if cp != null and cp.get("season_refresh_period_ticks") != null else 1,
		"ocean_daily_wind_period_ticks": context._generator._ocean_daily_wind_period_ticks_for(cp),
		"ocean_currents_period_ticks": int(cp.ocean_currents_period_ticks) if cp != null else 30,
		"ocean_currents_slice_count": int(cp.ocean_currents_slice_count) if cp != null else 10,
		"native_climate_round_active_owner_enabled": bool(cp.native_climate_round_active_owner_enabled) if cp != null and cp.get("native_climate_round_active_owner_enabled") != null else false,
		"native_weather_transaction_active_owner_enabled": bool(cp.native_weather_transaction_active_owner_enabled) if cp != null and cp.get("native_weather_transaction_active_owner_enabled") != null else false,
		"native_ocean_physical_active_owner_enabled": bool(cp.native_ocean_physical_active_owner_enabled) if cp != null and cp.get("native_ocean_physical_active_owner_enabled") != null else false,
		"native_season_refresh_active_owner_enabled": bool(cp.native_season_refresh_active_owner_enabled) if cp != null and cp.get("native_season_refresh_active_owner_enabled") != null else false,
		"world_seed": int(cfg.seed) if cfg != null else 0,
		"thermal_monsoon_enabled": bool(cp.thermal_monsoon_enabled) if cp != null else false,
		"thermal_monsoon_lat_limit": float(cp.thermal_monsoon_lat_limit) if cp != null else 0.45,
		"thermal_monsoon_deadband": float(cp.thermal_monsoon_deadband) if cp != null else 0.015,
		"thermal_monsoon_full_contrast": float(cp.thermal_monsoon_full_contrast) if cp != null else 0.08,
		"thermal_monsoon_gain": float(cp.thermal_monsoon_gain) if cp != null else 0.85,
		"thermal_monsoon_breeze_floor": float(cp.thermal_monsoon_breeze_floor) if cp != null else 0.20,
		"native_tropical_cyclone_enabled": bool(cp.native_tropical_cyclone_enabled) if cp != null else false,
		"tropical_cyclone_capacity": int(cp.tropical_cyclone_capacity) if cp != null else 24,
		"tropical_cyclone_births_per_commit": int(cp.tropical_cyclone_births_per_commit) if cp != null else 2,
		"tropical_cyclone_min_temp": float(cp.tropical_cyclone_min_temp) if cp != null else 0.58,
		"tropical_cyclone_min_instability": float(cp.tropical_cyclone_min_instability) if cp != null else 0.40,
		"tropical_cyclone_max_shear": float(cp.tropical_cyclone_max_shear) if cp != null else 0.42,
		"tropical_cyclone_min_lat": float(cp.tropical_cyclone_min_lat) if cp != null else 0.06,
		"tropical_cyclone_max_lat": float(cp.tropical_cyclone_max_lat) if cp != null else 0.40,
		"tropical_cyclone_max_radius_cells": int(cp.tropical_cyclone_max_radius_cells) if cp != null else 5,
		"enso_basin_modes_enabled": bool(cp.enso_basin_modes_enabled) if cp != null else false,
		"enso_max_basins": int(cp.enso_max_basins) if cp != null else 3,
		"enso_tropical_lat_limit": float(cp.enso_tropical_lat_limit) if cp != null else 0.33,
		"enso_period_days": float(cp.enso_period_days) if cp != null else 1460.0,
		"enso_temp_anomaly_cap": float(cp.enso_temp_anomaly_cap) if cp != null else 0.06,
		"enso_wind_coupling": float(cp.enso_wind_coupling) if cp != null else 0.0008,
		"enso_integration_substep_days": float(cp.enso_integration_substep_days) if cp != null else 10.0,
		"has_world_data": world != null,
		"has_config": cfg != null,
	}
	var res: Dictionary = context._generator._data_core_world_ext.configure_native_world(knobs)
	context._generator._native_daily_configured = int(res.get("rc", -1)) == 0
	context._generator._runtime_graph_active = false
	context._generator._runtime_graph_last_country_generation = -1
	context._generator._runtime_graph_last_country_territory_generation = -1
	context._generator._runtime_graph_country_territory_sync_ms = 0.0
	context._generator._runtime_graph_country_event_dispatch_ms = 0.0
	var graph_mode := int(cp.native_runtime_graph_mode) if cp != null and cp.get("native_runtime_graph_mode") != null else 0
	var graph_rc := int(context._generator._data_core_world_ext.configure_runtime_graph({
		"enabled": graph_mode == context._generator.ClimateProfileScript.NATIVE_MODE_ACTIVE,
		"mode": graph_mode,
		"day": int(context._generator._world_clock_ref.day_index()) if context._generator._world_clock_ref != null else 0,
		"generation": 0,
	}))
	context._generator._runtime_graph_active = graph_rc == 0 and graph_mode == context._generator.ClimateProfileScript.NATIVE_MODE_ACTIVE
	if OS.is_debug_build():
		# wrap_period_x 回显：0 表示 climate/weather 平流内核退化为裸 cell_pos_x 差分，
		# 东西接缝会重新出现方向恒定的风场/洋流经线伪影。
		print("[native_world] configure rc=%s reason=%s cells=%d wrap_period_x=%.3f"
			% [str(res.get("rc", -1)), str(res.get("reason", "")), int(knobs["cell_count"]),
				float(res.get("wrap_period_x", 0.0))])

static func _try_register_native_daily_sim_job(context, map: MapData, world: WorldData) -> bool:
	var cp = context._generator._c()
	if not context._generator._native_mode_is_active(cp, "native_daily_sim_mode"):
		return false
	# Web 上 native daily 走不通：仿真主机把「一天」的收尾交给 worker 线程，
	# 浏览器里这条 handoff 永远回不来——实测 SUS 卡在
	# `native_daily_sim / native_daily_finalizer / pending`，日历停在第 1~2 天
	# （runtime-forensics 的 stalled_day=1、stalled_ms=45017、fast_tick_count=1）。
	# 这里改为回退到既有的 GDScript SUS 协作路径（逐帧切片，不跨线程等待）。
	# 换实现（host 侧改成主线程内联/异步）后再移除这条守卫。
	# Web 曾经在这里整段回退到 GDScript SUS（当时 host 的 daily handoff 回不来）。
	# 实际原因是首帧 shader 编译 45s 把整帧堵住；裁剪之后 native daily 在浏览器里
	# 可以正常注册并推进日历。

	var weather_field_required: bool = context._generator._weather_system != null \
			and context._generator._weather_system.has_method("uses_weather_field") \
			and bool(context._generator._weather_system.uses_weather_field())
	var weather_readiness: Dictionary = context._generator.weather_native_daily_readiness_report()
	if weather_field_required \
			and not bool(weather_readiness.get("ready", false)) \
			and not context._generator._get_native_daily_bundle_builder()._native_daily_weather_active_bootstrap_allowed(weather_readiness):
		push_warning("[native_daily] ACTIVE requested but native weather is not visible-publish ready (%s); falling back to legacy SUS jobs"
			% str(weather_readiness.get("reason", "not_ready")))
		return false
	if not context._generator._native_daily_configured or context._generator._data_core_world_ext == null:
		push_warning("[native_daily] ACTIVE requested but native world is not configured; falling back to legacy SUS jobs")
		return false
	if not context._generator._native_daily_slice_available():
		push_warning("[native_daily] ACTIVE requested but gdext lacks run_native_daily_slice; falling back to legacy SUS jobs")
		return false
	var probe_ctx: SusTickContext = SusTickContext.make(0, 0, 0.0, 1.0, &"native_daily_probe")
	# probe 是 readiness 探测（“weather 到期时能否跑”），强制纳入 weather/stage_b，
	# 否则 tick 0 非 weather 到期会让 required pass key 判缺失→错误回退 legacy。
	var probe_bundle: Dictionary = context._generator._get_native_daily_bundle_builder()._build_native_daily_bundle(probe_ctx, map, world, false, 30.0, true)
	var required_pass_keys_packed: PackedStringArray = context._generator._get_native_daily_bundle_builder()._native_daily_required_pass_keys(cp)
	var required_pass_keys: Array[String] = context._generator._get_native_daily_bundle_builder()._native_daily_required_pass_keys_array(cp)
	var missing_required: PackedStringArray = context._generator._get_native_daily_bundle_builder()._native_daily_missing_required_pass_keys(
			probe_bundle, required_pass_keys_packed)
	var probe: Dictionary = context._generator._data_core_world_ext.run_native_daily_tick({
		"probe": true,
		"native_daily_bundle": probe_bundle,
		"required_pass_keys": required_pass_keys,
	})
	if int(probe.get("rc", -1)) != 0:
		push_warning("[native_daily] ACTIVE requested but native tick is not ready (%s); falling back to legacy SUS jobs"
			% str(probe.get("fail_stage", probe.get("reason", ""))))
		return false
	if not missing_required.is_empty():
		push_warning("[native_daily] ACTIVE requested but native bundle is missing required passes: %s; falling back to legacy SUS jobs"
			% ", ".join(missing_required))
		return false
	var native_daily_authoritative_ready: bool = bool(probe.get("authoritative_ready", false))
	if not native_daily_authoritative_ready:
		var probe_missing := PackedStringArray()
		for key in probe.get("missing_pass_keys", []):
			probe_missing.append(String(key))
		push_warning("[native_daily] ACTIVE requested but native probe did not authorize handoff (missing=%s); falling back to legacy SUS jobs"
			% ", ".join(probe_missing))
		return false
	var native_stride: int = 1
	if cp != null and cp.get("native_daily_sim_stride") != null:
		native_stride = clampi(int(cp.native_daily_sim_stride), 1, 30)
	context._generator._native_daily_sim_job = context._generator.NativeDailySimJobScript.new(context._generator, map, world, native_stride)
	context._generator._sus.configure_job_from_profile(context._generator._native_daily_sim_job, cp, false, &"native_daily_sim", native_stride)
	context._generator._configure_native_daily_transaction_budget(context._generator._native_daily_sim_job, cp)
	context._generator._runtime_register_system(context._generator._native_daily_sim_job)
	return true

static func _configure_native_daily_transaction_budget(context, job, cp) -> void:
	if job == null:
		return
	# Spread mode (native_daily_spread_across_ticks): run the round one slice-batch
	# per tick (round-robin A→B→C→A…) instead of the whole round atomically. C++ keeps
	# the slice cursor + SoA slots across ticks, so the round resumes next tick with
	# identical state — the completed-round result is bit-equal to the one-tick path
	# (validated by tmp_native_batch_bitequal_test.gd, which drives one slice/call).
	# Retained-job stagger (2026-06): native is NOT must_run in spread. Instead it
	# respects frame_budget so it yields the tick when a heavier slow-variable round
	# (season_refresh: priority 50 → runs first, one 11-stage stage ~3ms already busts
	# the 2ms budget) is in flight. Previously must_run=true made native ignore the
	# exhausted budget and pile its ~2.5ms batch on top → the season+native ~5.8ms
	# collision peak. A starvation safety net (native_daily_spread_starve_ticks, default
	# 16 > season's ~11-stage round) force-runs one batch if native is starved that long,
	# so a bounded season round defers native fully (no collision) yet pathological
	# sustained preemption can't freeze the sim. Outside season rounds the budget is not
	# exhausted before native, so it still advances one batch every tick.
	var spread: bool = cp != null and cp.get("native_daily_spread_across_ticks") != null \
			and bool(cp.native_daily_spread_across_ticks)
	if spread:
		job.must_run = false
		var max_slices: int = 1
		if cp.get("native_daily_max_slices_per_tick") != null:
			max_slices = clampi(int(cp.native_daily_max_slices_per_tick), 1, 32)
		job.max_slices_per_tick = max_slices
		# Soft per-slice budget only; max_slices is the hard per-tick cap in spread mode.
		var target_spread_ms: float = 3.0
		if cp.get("native_daily_perf_target_ms") != null:
			target_spread_ms = clampf(float(cp.native_daily_perf_target_ms), 0.75, 8.0)
		job.slice_budget_ms = target_spread_ms
		if job.get("starvation_threshold") != null:
			var starve_ticks: int = 16
			if cp.get("native_daily_spread_starve_ticks") != null:
				starve_ticks = clampi(int(cp.native_daily_spread_starve_ticks), 0, 64)
			job.starvation_threshold = starve_ticks
		return
	# Default: native daily is a logical daily transaction. It may internally slice by
	# graph node, but the default ACTIVE path finishes the round inside the same
	# day_changed tick so slow state such as sea ice keeps daily climate cadence.
	job.must_run = true
	job.max_slices_per_tick = 32
	var target_ms: float = 8.0
	if cp != null and cp.get("native_daily_perf_target_ms") != null:
		target_ms = maxf(8.0, float(cp.native_daily_perf_target_ms))
	job.slice_budget_ms = maxf(float(job.slice_budget_ms), clampf(target_ms, 0.75, 8.0))
	if job.get("starvation_threshold") != null:
		job.starvation_threshold = 0

static func _try_register_native_environment_runtime_system(context, map: MapData, cp) -> bool:
	context._generator._native_environment_runtime_job = null
	if cp == null or cp.get("native_environment_runtime_enabled") == null or not bool(cp.native_environment_runtime_enabled):
		return false
	if context._generator.get_environment_runtime() == null:
		push_warning("[native_env_runtime] enabled but EnvironmentRuntime class is unavailable; skipping thin native scheduler job")
		return false
	var runtime_stride: int = 1
	if cp.get("native_environment_runtime_stride") != null:
		runtime_stride = clampi(int(cp.native_environment_runtime_stride), 1, 8)
	context._generator._native_environment_runtime_job = context._generator.NativeEnvironmentRuntimeSystemScript.new(context._generator, map, runtime_stride)
	context._generator._sus.configure_job_from_profile(context._generator._native_environment_runtime_job, cp, false, &"native_environment_runtime", runtime_stride)
	context._generator._native_environment_runtime_job.slice_budget_ms = min(float(context._generator._native_environment_runtime_job.slice_budget_ms), 0.5)
	context._generator._native_environment_runtime_job.must_run = false
	context._generator._runtime_register_system(context._generator._native_environment_runtime_job)
	if OS.is_debug_build():
		print("[native_env_runtime] SHADOW: registered thin EnvironmentRuntime step job")
	return true

static func _register_visual_upload_jobs(context, map: MapData, world: WorldData, hex_size: float, cp) -> void:
	var enum_atlas_stride: int = 2
	var dynamic_visual_atlas_stride: int = context._generator._dyn_atlas_upload_stride
	if cp != null:
		if cp.get("enum_atlas_upload_stride") != null:
			enum_atlas_stride = clampi(int(cp.enum_atlas_upload_stride), 1, 8)
		if cp.get("dynamic_visual_atlas_upload_stride") != null:
			dynamic_visual_atlas_stride = clampi(int(cp.dynamic_visual_atlas_upload_stride), 1, 8)
	context._generator._dyn_atlas_upload_stride = dynamic_visual_atlas_stride
	context._generator._enum_atlas_upload_job = context._generator.EnumAtlasUploadSystemScript.new(context._generator, context._generator._baker, map, world, hex_size, enum_atlas_stride, context._generator._data_core_world_ext)
	context._generator._sus.configure_job_from_profile(context._generator._enum_atlas_upload_job, cp, true, &"enum_atlas_upload", enum_atlas_stride)
	context._generator._runtime_register_system(context._generator._enum_atlas_upload_job)
	# 海冰主视觉由 shader 按 current_temp/latitude/depth 直接派生；停用旧 atlas upload。
	context._generator._last_sea_ice_atlas_upload_breakdown = context._generator._disabled_sea_ice_atlas_report("shader_temperature_derived")
	# plan/dirty-push-atlas-encode 阶段 D：把 cp 传给 system，让其入口可调
	# DCFeatureFlags.is_on(&"dirty_push_enabled", cp) 决定是否走 mask 路径。
	context._generator._dynamic_visual_atlas_upload_job = context._generator.DynamicVisualAtlasUploadSystemScript.new(
			context._generator._baker, map, world, context._generator._dyn_atlas_upload_stride, cp, context._generator._data_core_world,
			context._generator._data_core_world_ext)
	context._generator._sus.configure_job_from_profile(context._generator._dynamic_visual_atlas_upload_job, cp, true, &"dynamic_visual_atlas_upload", context._generator._dyn_atlas_upload_stride)
	context._generator._runtime_register_system(context._generator._dynamic_visual_atlas_upload_job)
