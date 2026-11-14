extends "res://scripts/simulation/generator_context.gd"
## Native daily graph execution and SUS tick orchestration extracted from MapGenerator.
func _init(generator) -> void:
	_generator = generator


func _ensure_maritime_factor(map: MapData, decay_cells: float) -> PackedFloat32Array:
	var n: int = map.soa_size()
	if n <= 0:
		return PackedFloat32Array()
	var key: String = "%d:%.3f" % [n, decay_cells]
	if _generator._maritime_factor_cache_key == key and _generator._maritime_factor_cache.size() == n:
		return _generator._maritime_factor_cache
	var isw: PackedByteArray = map.is_water_arr
	var nb: PackedInt32Array = map.neighbor_indices_packed()
	if isw.size() != n or nb.size() < n * 6:
		return PackedFloat32Array()
	var dist: PackedInt32Array = PackedInt32Array()
	dist.resize(n)
	var queue: PackedInt32Array = PackedInt32Array()
	queue.resize(n)
	var qh: int = 0
	var qt: int = 0
	for i in range(n):
		if isw[i] != 0:
			dist[i] = 0
			queue[qt] = i
			qt += 1
		else:
			dist[i] = -1
	while qh < qt:
		var cur: int = queue[qh]
		qh += 1
		var nd: int = dist[cur] + 1
		var base: int = cur * 6
		for d in range(6):
			var ni: int = nb[base + d]
			if ni < 0 or ni >= n:
				continue
			if dist[ni] >= 0:
				continue
			dist[ni] = nd
			queue[qt] = ni
			qt += 1
	var inv_decay: float = 1.0 / maxf(decay_cells, 0.001)
	var out: PackedFloat32Array = PackedFloat32Array()
	out.resize(n)
	for i in range(n):
		if isw[i] != 0 or dist[i] < 0:
			out[i] = 0.0  # 水面 / 无海可达内陆 → 不调温
		else:
			out[i] = exp(-float(dist[i]) * inv_decay)  # 沿海陆地(dist=1)≈最大，向内陆衰减
	_generator._maritime_factor_cache = out
	_generator._maritime_factor_cache_key = key
	return out


# _async_pass_a_kernel_pure 的硬校验 lane 列表（gdext/src/runtime_climate_passes.cpp
# 顶部的维度检查）。任一条 size != n_cells，共享内核直接 return false。

func publish_worker_climate_visuals() -> Dictionary:
	# Reuse the production cell LUT encoders; no simulation or full map rebake.
	if _generator._baker == null or _generator._sus_map == null or _generator._last_world == null:
		return {}
	# Weather LUT is fully re-encoded here: the worker writes weather fields back
	# but never weather_dirty_mask, so refresh_weather_lut_from_weather's dirty
	# subset stays empty and the LUT would freeze at its world-gen contents.
	return _generator._baker.refresh_cell_luts_daily(
		_generator._sus_map, _generator._last_world, PackedInt32Array(), true, true)



func _temperature_transport_anomaly_knobs(cp_now) -> Dictionary:
	var source_cap: float = 0.22
	var blend_rate: float = 0.70
	var decay_rate: float = 0.04
	var zero_current_decay: float = 0.06
	if cp_now != null:
		if cp_now.get("temperature_transport_anomaly_source_cap") != null:
			source_cap = float(cp_now.temperature_transport_anomaly_source_cap)
		if cp_now.get("temperature_transport_anomaly_blend_rate") != null:
			blend_rate = float(cp_now.temperature_transport_anomaly_blend_rate)
		if cp_now.get("temperature_transport_anomaly_decay_rate") != null:
			decay_rate = float(cp_now.temperature_transport_anomaly_decay_rate)
		if cp_now.get("temperature_transport_anomaly_zero_current_decay") != null:
			zero_current_decay = float(cp_now.temperature_transport_anomaly_zero_current_decay)
	return {
		"tta_source_cap": clampf(source_cap, 0.0, 0.5),
		"tta_blend_rate": clampf(blend_rate, 0.0, 1.0),
		"tta_decay_rate": clampf(decay_rate, 0.0, 1.0),
		"tta_zero_current_decay": clampf(zero_current_decay, 0.0, 1.0),
	}



func _prepare_temperature_transport_anomaly_state(map: MapData, n: int, cells: Array = [], prefer_cached: bool = false) -> PackedFloat32Array:
	var out: PackedFloat32Array = PackedFloat32Array()
	out.resize(maxi(n, 0))
	if n <= 0:
		return out
	if prefer_cached and _generator._gdext_ocean_anomaly_buf_cached.size() == n:
		var cached: PackedFloat32Array = _generator._gdext_ocean_anomaly_buf_cached
		for ci in range(n):
			out[ci] = float(cached[ci])
		return out
	if map != null and map.temperature_transport_anomaly_arr.size() == n:
		var arr: PackedFloat32Array = map.temperature_transport_anomaly_arr
		for ai in range(n):
			out[ai] = float(arr[ai])
		return out
	if not prefer_cached and _generator._gdext_ocean_anomaly_buf_cached.size() == n:
		var cached_after_map: PackedFloat32Array = _generator._gdext_ocean_anomaly_buf_cached
		for cmi in range(n):
			out[cmi] = float(cached_after_map[cmi])
		return out
	if cells.size() == n:
		for i in range(n):
			var cell = cells[i]
			if cell != null:
				out[i] = float((cell as HexCell).temperature_transport_anomaly)
	return out



func _run_native_daily_shadow_probe(ctx: SusTickContext, map: MapData, world: WorldData) -> void:
	var cp = _generator._c()
	if not _generator._native_mode_is_shadow(cp, "native_daily_sim_mode"):
		return
	if _generator._data_core_world_ext == null:
		_generator._native_daily_last_result = { "rc": -1, "mode": "shadow_probe", "fail_stage": "gdext_unavailable" }
		return
	# SHADOW probe 同样是 readiness 探测，强制纳入 weather/stage_b 探完整图。
	var bundle: Dictionary = _generator._get_native_daily_bundle_builder()._build_native_daily_bundle(ctx, map, world, false, 30.0, true, true)
	var pass_keys: Array[String] = _generator._get_native_daily_bundle_builder()._native_daily_bundle_pass_keys(bundle)
	if pass_keys.is_empty():
		_generator._native_daily_last_result = { "rc": -1, "mode": "shadow_probe", "fail_stage": "empty_bundle" }
		return
	var tick_knobs: Dictionary = _generator._get_native_daily_bundle_builder()._native_daily_base_tick_knobs(ctx)
	tick_knobs["probe"] = true
	tick_knobs["native_daily_bundle"] = bundle
	tick_knobs["required_pass_keys"] = _generator._get_native_daily_bundle_builder()._native_daily_required_pass_keys_array(cp)
	var res: Dictionary = _generator._data_core_world_ext.run_native_daily_tick(tick_knobs)
	res["mode"] = "shadow_probe"
	res["bundle_pass_keys"] = pass_keys
	_generator._native_daily_last_result = res.duplicate(true)
	if not _generator._native_daily_shadow_probe_logged:
		_generator._native_daily_shadow_probe_logged = true
		var pass_key_text: String = ", ".join(PackedStringArray(pass_keys))
		print("[native_daily] SHADOW probe rc=%s passes=%s (legacy SUS remains authoritative)"
			% [str(res.get("rc", -1)), pass_key_text])



func _configure_native_world_context(map: MapData, world: WorldData, cfg: MapConfig, hex_size: float) -> void:
	_generator._native_daily_configured = false
	if _generator._data_core_world_ext == null:
		return
	var cp = _generator._c()
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
		"ocean_daily_wind_period_ticks": _generator._ocean_daily_wind_period_ticks_for(cp),
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
	var res: Dictionary = _generator._data_core_world_ext.configure_native_world(knobs)
	_generator._native_daily_configured = int(res.get("rc", -1)) == 0
	_generator._runtime_graph_active = false
	_generator._runtime_graph_last_country_generation = -1
	_generator._runtime_graph_last_country_territory_generation = -1
	_generator._runtime_graph_country_territory_sync_ms = 0.0
	_generator._runtime_graph_country_event_dispatch_ms = 0.0
	var graph_mode := int(cp.native_runtime_graph_mode) if cp != null and cp.get("native_runtime_graph_mode") != null else 0
	var graph_rc := int(_generator._data_core_world_ext.configure_runtime_graph({
		"enabled": graph_mode == _generator.ClimateProfileScript.NATIVE_MODE_ACTIVE,
		"mode": graph_mode,
		"day": int(_generator._world_clock_ref.day_index()) if _generator._world_clock_ref != null else 0,
		"generation": 0,
	}))
	_generator._runtime_graph_active = graph_rc == 0 and graph_mode == _generator.ClimateProfileScript.NATIVE_MODE_ACTIVE
	if OS.is_debug_build():
		# wrap_period_x 回显：0 表示 climate/weather 平流内核退化为裸 cell_pos_x 差分，
		# 东西接缝会重新出现方向恒定的风场/洋流经线伪影。
		print("[native_world] configure rc=%s reason=%s cells=%d wrap_period_x=%.3f"
			% [str(res.get("rc", -1)), str(res.get("reason", "")), int(knobs["cell_count"]),
				float(res.get("wrap_period_x", 0.0))])



func _try_register_native_daily_sim_job(map: MapData, world: WorldData) -> bool:
	var cp = _generator._c()
	if not _generator._native_mode_is_active(cp, "native_daily_sim_mode"):
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

	var weather_field_required: bool = _generator._weather_system != null \
			and _generator._weather_system.has_method("uses_weather_field") \
			and bool(_generator._weather_system.uses_weather_field())
	var weather_readiness: Dictionary = _generator.weather_native_daily_readiness_report()
	if weather_field_required \
			and not bool(weather_readiness.get("ready", false)) \
			and not _generator._get_native_daily_bundle_builder()._native_daily_weather_active_bootstrap_allowed(weather_readiness):
		push_warning("[native_daily] ACTIVE requested but native weather is not visible-publish ready (%s); falling back to legacy SUS jobs"
			% str(weather_readiness.get("reason", "not_ready")))
		return false
	if not _generator._native_daily_configured or _generator._data_core_world_ext == null:
		push_warning("[native_daily] ACTIVE requested but native world is not configured; falling back to legacy SUS jobs")
		return false
	if not _generator._native_daily_slice_available():
		push_warning("[native_daily] ACTIVE requested but gdext lacks run_native_daily_slice; falling back to legacy SUS jobs")
		return false
	var probe_ctx: SusTickContext = SusTickContext.make(0, 0, 0.0, 1.0, &"native_daily_probe")
	# probe 是 readiness 探测（“weather 到期时能否跑”），强制纳入 weather/stage_b，
	# 否则 tick 0 非 weather 到期会让 required pass key 判缺失→错误回退 legacy。
	var probe_bundle: Dictionary = _generator._get_native_daily_bundle_builder()._build_native_daily_bundle(probe_ctx, map, world, false, 30.0, true, true)
	var required_pass_keys_packed: PackedStringArray = _generator._get_native_daily_bundle_builder()._native_daily_required_pass_keys(cp)
	var required_pass_keys: Array[String] = _generator._get_native_daily_bundle_builder()._native_daily_required_pass_keys_array(cp)
	var missing_required: PackedStringArray = _generator._get_native_daily_bundle_builder()._native_daily_missing_required_pass_keys(
			probe_bundle, required_pass_keys_packed)
	var probe: Dictionary = _generator._data_core_world_ext.run_native_daily_tick({
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
	_generator._native_daily_sim_job = _generator.NativeDailySimJobScript.new(_generator, map, world, native_stride)
	_generator._sus.configure_job_from_profile(_generator._native_daily_sim_job, cp, false, &"native_daily_sim", native_stride)
	_generator._configure_native_daily_transaction_budget(_generator._native_daily_sim_job, cp)
	_generator._runtime_register_system(_generator._native_daily_sim_job)
	return true



func _configure_native_daily_transaction_budget(job, cp) -> void:
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



func _try_register_native_environment_runtime_system(map: MapData, cp) -> bool:
	_generator._native_environment_runtime_job = null
	if cp == null or cp.get("native_environment_runtime_enabled") == null or not bool(cp.native_environment_runtime_enabled):
		return false
	if _generator.get_environment_runtime() == null:
		push_warning("[native_env_runtime] enabled but EnvironmentRuntime class is unavailable; skipping thin native scheduler job")
		return false
	var runtime_stride: int = 1
	if cp.get("native_environment_runtime_stride") != null:
		runtime_stride = clampi(int(cp.native_environment_runtime_stride), 1, 8)
	_generator._native_environment_runtime_job = _generator.NativeEnvironmentRuntimeSystemScript.new(_generator, map, runtime_stride)
	_generator._sus.configure_job_from_profile(_generator._native_environment_runtime_job, cp, false, &"native_environment_runtime", runtime_stride)
	_generator._native_environment_runtime_job.slice_budget_ms = min(float(_generator._native_environment_runtime_job.slice_budget_ms), 0.5)
	_generator._native_environment_runtime_job.must_run = false
	_generator._runtime_register_system(_generator._native_environment_runtime_job)
	if OS.is_debug_build():
		print("[native_env_runtime] SHADOW: registered thin EnvironmentRuntime step job")
	return true



func _register_visual_upload_jobs(map: MapData, world: WorldData, hex_size: float, cp) -> void:
	var enum_atlas_stride: int = 2
	var dynamic_visual_atlas_stride: int = _generator._dyn_atlas_upload_stride
	if cp != null:
		if cp.get("enum_atlas_upload_stride") != null:
			enum_atlas_stride = clampi(int(cp.enum_atlas_upload_stride), 1, 8)
		if cp.get("dynamic_visual_atlas_upload_stride") != null:
			dynamic_visual_atlas_stride = clampi(int(cp.dynamic_visual_atlas_upload_stride), 1, 8)
	_generator._dyn_atlas_upload_stride = dynamic_visual_atlas_stride
	_generator._enum_atlas_upload_job = _generator.EnumAtlasUploadSystemScript.new(_generator, _generator._baker, map, world, hex_size, enum_atlas_stride, _generator._data_core_world_ext)
	_generator._sus.configure_job_from_profile(_generator._enum_atlas_upload_job, cp, true, &"enum_atlas_upload", enum_atlas_stride)
	_generator._runtime_register_system(_generator._enum_atlas_upload_job)
	# 海冰主视觉由 shader 按 current_temp/latitude/depth 直接派生；停用旧 atlas upload。
	_generator._last_sea_ice_atlas_upload_breakdown = _generator._disabled_sea_ice_atlas_report("shader_temperature_derived")
	# plan/dirty-push-atlas-encode 阶段 D：把 cp 传给 system，让其入口可调
	# DCFeatureFlags.is_on(&"dirty_push_enabled", cp) 决定是否走 mask 路径。
	_generator._dynamic_visual_atlas_upload_job = _generator.DynamicVisualAtlasUploadSystemScript.new(
			_generator._baker, map, world, _generator._dyn_atlas_upload_stride, cp, _generator._data_core_world,
			_generator._data_core_world_ext)
	_generator._sus.configure_job_from_profile(_generator._dynamic_visual_atlas_upload_job, cp, true, &"dynamic_visual_atlas_upload", _generator._dyn_atlas_upload_stride)
	_generator._runtime_register_system(_generator._dynamic_visual_atlas_upload_job)



func _native_daily_contract_stride_days() -> int:
	var cp = _generator._c()
	if cp != null and cp.get("native_daily_sim_stride") != null:
		return clampi(int(cp.native_daily_sim_stride), 1, 30)
	return 1



func _native_daily_contract_budget_days() -> int:
	var cp = _generator._c()
	if cp != null and cp.get("native_daily_commit_lag_budget_days") != null:
		return clampi(int(cp.native_daily_commit_lag_budget_days), 1, 30)
	return _generator._native_daily_contract_stride_days()



func _native_daily_effective_node_range_config(cp, ctx: SusTickContext, map_ref: MapData) -> Dictionary:
	var base_cells: int = 768
	if cp != null and cp.get("native_daily_node_range_cells") != null:
		base_cells = maxi(1, int(cp.native_daily_node_range_cells))
	var n_cells: int = map_ref.soa_size() if map_ref != null else 0
	var range_nodes: PackedStringArray = PackedStringArray()
	if cp != null and cp.get("native_daily_node_range_nodes") != null:
		range_nodes = cp.native_daily_node_range_nodes
	var range_node_count: int = maxi(1, range_nodes.size())
	var budget_days: int = _generator._native_daily_contract_budget_days()
	var age_days: int = _generator._native_daily_contract_age_days_for(ctx)
	var effective_cells: int = base_cells
	var catchup_active: bool = false
	var catchup_reason: String = "none"
	var estimated_slices: int = _generator._NATIVE_DAILY_CONTRACT_FIXED_SLICE_ESTIMATE
	if n_cells > 0:
		estimated_slices += int(ceil(float(n_cells) / float(base_cells))) * range_node_count
	if n_cells > 0 and estimated_slices > budget_days:
		var range_slice_budget: int = maxi(range_node_count, budget_days - _generator._NATIVE_DAILY_CONTRACT_FIXED_SLICE_ESTIMATE)
		var chunks_per_node: int = maxi(1, int(floor(float(range_slice_budget) / float(range_node_count))))
		effective_cells = maxi(base_cells, int(ceil(float(n_cells) / float(chunks_per_node))))
		catchup_active = effective_cells > base_cells
		catchup_reason = "fit_contract_budget" if catchup_active else "base_fits_contract"
	elif n_cells > 0 and age_days >= budget_days - 1:
		effective_cells = maxi(base_cells, mini(n_cells, base_cells * 2))
		catchup_active = effective_cells > base_cells
		catchup_reason = "near_contract_deadline" if catchup_active else "base_at_deadline"
	return {
		"base_cells": base_cells,
		"effective_cells": effective_cells,
		"catchup_active": catchup_active,
		"catchup_reason": catchup_reason,
		"estimated_slices": estimated_slices,
		"budget_days": budget_days,
		"age_days": age_days,
		"range_node_count": range_node_count,
	}



func _native_daily_begin_contract_round(ctx: SusTickContext) -> void:
	_generator._native_daily_contract_round_seq += 1
	_generator._native_daily_contract_sample_day = ctx.day_index if ctx != null else -1
	_generator._native_daily_contract_sample_tick = ctx.tick_index if ctx != null else -1
	_generator._native_daily_contract_warned_over_budget = false



func _native_daily_stamp_contract(res: Dictionary, breakdown: Dictionary,
		ctx: SusTickContext, committed: bool, state: String) -> void:
	if _generator._native_daily_contract_sample_day < 0 and ctx != null:
		_generator._native_daily_begin_contract_round(ctx)
	var current_day: int = ctx.day_index if ctx != null else _generator._native_daily_contract_sample_day
	var current_tick: int = ctx.tick_index if ctx != null else _generator._native_daily_contract_sample_tick
	var sample_day: int = _generator._native_daily_contract_sample_day
	var sample_tick: int = _generator._native_daily_contract_sample_tick
	var age_days: int = maxi(0, current_day - sample_day) if sample_day >= 0 and current_day >= 0 else 0
	var age_ticks: int = maxi(0, current_tick - sample_tick) if sample_tick >= 0 and current_tick >= 0 else age_days
	var budget_days: int = _generator._native_daily_contract_budget_days()
	var over_budget: bool = age_days > budget_days
	var commit_day: int = current_day if committed else -1
	var commit_tick: int = current_tick if committed else -1
	var fields := {
		"native_daily_contract_version": 1,
		"native_daily_contract_state": state,
		"native_daily_round_seq": _generator._native_daily_contract_round_seq,
		"native_daily_stride_days": _generator._native_daily_contract_stride_days(),
		"native_daily_commit_lag_budget_days": budget_days,
		"native_daily_sample_day": sample_day,
		"native_daily_sample_tick": sample_tick,
		"native_daily_current_day": current_day,
		"native_daily_current_tick": current_tick,
		"native_daily_commit_day": commit_day,
		"native_daily_commit_tick": commit_tick,
		"native_daily_age_days": age_days,
		"native_daily_age_ticks": age_ticks,
		"native_daily_commit_over_budget": over_budget,
		"native_daily_finalizer_pending": _generator._native_daily_finalizer_pending,
	}
	for key in fields.keys():
		res[key] = fields[key]
		breakdown[key] = fields[key]
	if over_budget and not _generator._native_daily_contract_warned_over_budget:
		_generator._native_daily_contract_warned_over_budget = true
		push_warning("[native_daily/contract] round=%d sample_day=%d current_day=%d age=%d budget=%d state=%s exceeded freshness contract"
				% [_generator._native_daily_contract_round_seq, sample_day, current_day, age_days, budget_days, state])



func run_native_daily_slice_from_job(ctx: SusTickContext, _map: MapData, _world: WorldData) -> Dictionary:
	if not _generator._native_daily_slice_available():
		return _generator._native_daily_missing_slice_report()
	var wall_t0: int = Time.get_ticks_usec()
	var bundle_ms: float = 0.0
	var jit_patch_build_ms: float = 0.0
	var jit_patch_keys: PackedStringArray = PackedStringArray()
	if _generator._native_daily_finalizer_pending:
		var res: Dictionary = _generator._native_daily_finalizer_pending_res.duplicate()
		var breakdown: Dictionary = _generator._native_daily_finalizer_pending_breakdown.duplicate()
		var complete_apply_diag: Dictionary = {}
		var rc_int: int = int(res.get("rc", 0))
		if rc_int == 0:
			var publish_t0: int = Time.get_ticks_usec()
			_generator._get_native_daily_publish()._publish_native_daily_temperature_transport_anomaly(_map, _generator._native_daily_slice_active_bundle, breakdown, res, true)
			_generator._get_native_daily_publish()._native_daily_add_complete_apply_ms(
				complete_apply_diag,
				"complete_apply_publish_tta_ms",
				Time.get_ticks_usec() - publish_t0
			)
			if _generator._native_daily_slice_unified_weather_embedded and _generator._weather_system != null \
					and _generator._weather_system.has_method("apply_unified_fast_tick_result"):
				var weather_t0: int = Time.get_ticks_usec()
				var fronts_out: Array[WeatherFront] = _generator._weather_system.apply_unified_fast_tick_result(breakdown)
				_generator._get_native_daily_publish()._native_daily_add_complete_apply_ms(
					complete_apply_diag,
					"complete_apply_weather_result_ms",
					Time.get_ticks_usec() - weather_t0
				)
				var visual_t0: int = Time.get_ticks_usec()
				_generator._get_native_daily_publish()._apply_native_daily_visual_intents(res, breakdown, fronts_out, _map, _world)
				_generator._get_native_daily_publish()._native_daily_add_complete_apply_ms(
					complete_apply_diag,
					"complete_apply_visual_intents_ms",
					Time.get_ticks_usec() - visual_t0
				)
			var finalizer_t0: int = Time.get_ticks_usec()
			var finalizer_diag: Dictionary = _generator._get_native_daily_publish()._native_daily_apply_finalizer(_map)
			_generator._get_native_daily_publish()._native_daily_add_complete_apply_ms(
				complete_apply_diag,
				"complete_apply_finalizer_ms",
				Time.get_ticks_usec() - finalizer_t0
			)
			var merge_t0: int = Time.get_ticks_usec()
			_generator._get_native_daily_publish()._merge_native_daily_finalizer_diag(breakdown, finalizer_diag)
			_generator._get_native_daily_publish()._merge_native_daily_finalizer_diag(res, finalizer_diag)
			_generator._get_native_daily_publish()._native_daily_add_complete_apply_ms(
				complete_apply_diag,
				"complete_apply_finalizer_merge_ms",
				Time.get_ticks_usec() - merge_t0
			)
			var patch_t0: int = Time.get_ticks_usec()
			if _map != null and _map.temperature_transport_anomaly_arr.size() == _map.soa_size():
				res["temperature_transport_anomaly_out"] = _map.temperature_transport_anomaly_arr
			_generator._get_native_daily_publish()._native_daily_add_complete_apply_ms(
				complete_apply_diag,
				"complete_apply_result_patch_ms",
				Time.get_ticks_usec() - patch_t0
			)
		_generator._native_daily_finalizer_pending = false
		_generator._native_daily_finalizer_pending_res = {}
		_generator._native_daily_finalizer_pending_breakdown = {}
		_generator._native_daily_slice_round_active = false
		_generator._native_daily_slice_range_active = false
		var wrapper_wall_ms: float = float(Time.get_ticks_usec() - wall_t0) / 1000.0
		_generator._get_native_daily_publish()._native_daily_install_complete_apply_diag(res, breakdown, complete_apply_diag, wrapper_wall_ms)
		_generator._native_daily_round_apply_accum_ms += wrapper_wall_ms
		_generator._native_daily_round_slice_count += 1
		res["done"] = true
		res["stage_name"] = "native_daily_complete"
		res["substage"] = "round_complete"
		res["progress_ratio"] = 1.0
		res["bundle_ms"] = 0.0
		res["jit_patch_build_ms"] = 0.0
		res["jit_patch_keys"] = PackedStringArray()
		res["native_call_ms"] = 0.0
		res["apply_ms"] = wrapper_wall_ms
		res["wrapper_wall_ms"] = wrapper_wall_ms
		res["round_bundle_ms"] = _generator._native_daily_round_bundle_accum_ms
		res["round_native_call_ms"] = _generator._native_daily_round_native_accum_ms
		res["round_apply_ms"] = _generator._native_daily_round_apply_accum_ms
		res["round_slice_count"] = _generator._native_daily_round_slice_count
		breakdown["done"] = true
		breakdown["stage_name"] = "native_daily_complete"
		breakdown["substage"] = "round_complete"
		breakdown["progress_ratio"] = 1.0
		breakdown["bundle_ms"] = 0.0
		breakdown["jit_patch_build_ms"] = 0.0
		breakdown["jit_patch_keys"] = PackedStringArray()
		breakdown["native_call_ms"] = 0.0
		breakdown["apply_ms"] = wrapper_wall_ms
		breakdown["wrapper_wall_ms"] = wrapper_wall_ms
		breakdown["round_bundle_ms"] = _generator._native_daily_round_bundle_accum_ms
		breakdown["round_native_call_ms"] = _generator._native_daily_round_native_accum_ms
		breakdown["round_apply_ms"] = _generator._native_daily_round_apply_accum_ms
		breakdown["round_slice_count"] = _generator._native_daily_round_slice_count
		_generator._native_daily_stamp_contract(res, breakdown, ctx, rc_int == 0, "complete" if rc_int == 0 else "failed")
		res["breakdown"] = breakdown
		_generator._get_native_daily_publish()._record_native_daily_slice_climate_breakdown(res, breakdown, _map, true, rc_int)
		_generator._native_daily_last_result = res.duplicate()
		_generator._native_daily_reset_contract_round()
		_generator._native_daily_slice_unified_weather_embedded = false
		_generator._native_daily_slice_bundle_pass_keys = []
		_generator._native_daily_slice_active_bundle = {}
		_generator._native_daily_slice_next_node_index = -1
		_generator._native_daily_slice_phase_locked = 0.0
		_generator._native_daily_slice_temp_start_arr = PackedFloat32Array()
		_generator._native_daily_slice_tta_start_arr = PackedFloat32Array()
		_generator._native_daily_slice_thermal_start_arr = PackedFloat32Array()
		return res
	var tick_knobs: Dictionary = _generator._get_native_daily_bundle_builder()._native_daily_base_tick_knobs(ctx)
	var cp_range = _generator._c()
	var range_contract: Dictionary = {}
	if cp_range != null and cp_range.get("native_daily_node_range_enabled") != null \
			and bool(cp_range.native_daily_node_range_enabled):
		range_contract = _generator._native_daily_effective_node_range_config(cp_range, ctx, _map)
		tick_knobs["native_daily_node_range_cells"] = int(range_contract.get("effective_cells", 768))
		tick_knobs["native_daily_node_range_nodes"] = cp_range.native_daily_node_range_nodes \
				if cp_range.get("native_daily_node_range_nodes") != null else PackedStringArray()
	var starting_round: bool = not _generator._native_daily_slice_round_active
	if starting_round:
		var bundle_t0: int = wall_t0
		# ACTIVE slice graph may take many simulation days to complete a round.
		# Build the bootstrap bundle once, but defer sea-ice dt consumption and
		# refresh dynamic pass knobs just-in-time before their native node runs.
		# Freeze the last committed climate state before any bundle captures MapData
		# arrays. Legacy ClimateDailySystem already does this; ACTIVE must honor the
		# same transaction boundary or *_prev/classification remain generation-era.
		if _map != null and _map.has_soa() and _map.has_method("soa_begin_climate_transaction"):
			_map.soa_begin_climate_transaction()
		_generator._get_native_daily_publish()._native_daily_capture_finalizer_start_state(_map)
		var bundle: Dictionary = _generator._get_native_daily_bundle_builder()._build_native_daily_bundle(ctx, _map, _world, true, 1.0, false, false, true)
		bundle_ms = float(Time.get_ticks_usec() - bundle_t0) / 1000.0
		_generator._native_daily_slice_active_bundle = bundle
		_generator._native_daily_slice_unified_weather_embedded = bundle.has("weather_knobs")
		_generator._native_daily_slice_bundle_pass_keys = _generator._get_native_daily_bundle_builder()._native_daily_bundle_pass_keys(bundle)
		_generator._native_daily_slice_next_node_index = 0
		_generator._native_daily_slice_range_active = false
		_generator._native_daily_slice_phase_locked = ctx.season_phase
		_generator._native_daily_begin_contract_round(ctx)
		tick_knobs["native_daily_bundle"] = bundle
		# Tell C++ which nodes need a GDScript JIT patch so it can batch the rest
		# (non-yield consecutive nodes) into a single call → fewer round-trips.
		tick_knobs["native_daily_slice_yield_nodes"] = _generator.native_daily_slice_yield_nodes_override \
				if not _generator.native_daily_slice_yield_nodes_override.is_empty() \
				else _generator._get_native_daily_bundle_builder()._native_daily_effective_yield_nodes(_generator._c())
	else:
		tick_knobs["native_daily_continue"] = true
		var patch_t0: int = Time.get_ticks_usec()
		var patch: Dictionary = {}
		if not _generator._native_daily_slice_range_active:
			patch = _generator._get_native_daily_bundle_builder()._build_native_daily_slice_bundle_patch(
				_generator._native_daily_slice_next_node_index,
				ctx,
				_map,
				_world)
		jit_patch_build_ms = float(Time.get_ticks_usec() - patch_t0) / 1000.0
		if not patch.is_empty():
			_generator._get_native_daily_bundle_builder()._merge_native_daily_slice_patch_local(patch)
			tick_knobs["native_daily_bundle_patch"] = patch
			for k in patch.keys():
				jit_patch_keys.append(str(k))
			if patch.has("weather_knobs"):
				_generator._native_daily_slice_unified_weather_embedded = true
			bundle_ms += jit_patch_build_ms
	var native_t0: int = Time.get_ticks_usec()
	var res: Dictionary = _generator._data_core_world_ext.run_native_daily_slice(tick_knobs)
	var native_call_ms: float = float(Time.get_ticks_usec() - native_t0) / 1000.0
	res["bundle_pass_keys"] = _generator._native_daily_slice_bundle_pass_keys
	var breakdown: Dictionary = res.get("breakdown", {})
	if not range_contract.is_empty():
		var catchup_fields := {
			"contract_catchup_active": bool(range_contract.get("catchup_active", false)),
			"contract_catchup_reason": str(range_contract.get("catchup_reason", "")),
			"contract_range_base_cells": int(range_contract.get("base_cells", 0)),
			"contract_range_effective_cells": int(range_contract.get("effective_cells", 0)),
			"contract_estimated_slices": int(range_contract.get("estimated_slices", 0)),
		}
		for key in catchup_fields.keys():
			res[key] = catchup_fields[key]
			breakdown[key] = catchup_fields[key]
	var complete_apply_diag: Dictionary = {}
	breakdown["bundle_pass_keys"] = _generator._native_daily_slice_bundle_pass_keys
	# Shallow copy (CoW-safe): only top-level keys are added; nested PackedArrays
	# share buffers instead of being byte-copied each slice.
	_generator._diagnostics_bus.replace_weather_breakdown(breakdown, _generator._current_fast_tick_idx)
	_generator._dump_weather_breakdown_if_slow()
	var rc_int: int = int(res.get("rc", -1))
	var done: bool = bool(res.get("done", true))
	var climate_authority_suppressed: bool = bool(res.get("climate_authority_suppressed", breakdown.get("climate_authority_suppressed", false)))
	if rc_int == 0 and not climate_authority_suppressed and res.has("temperature_transport_anomaly_out"):
		# done → finalizer follows and re-writes the clamped TTA, so skip the dense write here.
		var publish_t0: int = Time.get_ticks_usec()
		_generator._get_native_daily_publish()._publish_native_daily_temperature_transport_anomaly(_map, _generator._native_daily_slice_active_bundle, breakdown, res, done)
		if done:
			_generator._get_native_daily_publish()._native_daily_add_complete_apply_ms(
				complete_apply_diag,
				"complete_apply_publish_tta_ms",
				Time.get_ticks_usec() - publish_t0
			)
	var defer_finalizer: bool = rc_int == 0 and done and not climate_authority_suppressed and cp_range != null \
			and cp_range.get("native_daily_finalizer_slice_enabled") != null \
			and bool(cp_range.native_daily_finalizer_slice_enabled)
	if defer_finalizer:
		complete_apply_diag.clear()
		_generator._native_daily_finalizer_pending = true
		_generator._native_daily_finalizer_pending_res = res.duplicate()
		_generator._native_daily_finalizer_pending_breakdown = breakdown.duplicate()
		done = false
		res["done"] = false
		res["stage_name"] = "native_daily_finalizer"
		res["substage"] = "pending"
		res["progress_ratio"] = 0.99
		res["published_slots"] = []
		res["visual_dirty_intents"] = []
		res["fronts_changed"] = false
		breakdown["done"] = false
		breakdown["stage_name"] = "native_daily_finalizer"
		breakdown["substage"] = "pending"
		breakdown["progress_ratio"] = 0.99
		breakdown["published_slots"] = []
		breakdown["visual_dirty_intents"] = []
	if _generator._native_daily_slice_unified_weather_embedded and _generator._weather_system != null and not climate_authority_suppressed:
		if rc_int == 0 and done:
			if not _generator._unified_fast_tick_first_log_done:
				_generator._unified_fast_tick_first_log_done = true
				var weather_split_enabled := bool(breakdown.get("weather_split_enabled", false))
				var weather_split_skipped_monolithic := bool(breakdown.get("weather_split_skipped_monolithic", false))
				print("[native_daily/unified] native slice ACTIVE — weather_knobs embedded split=%s split_skipped_monolithic=%s; slice_ms=%.2f round_ms=%.2f weather_ms=%.2f"
						% [str(weather_split_enabled), str(weather_split_skipped_monolithic), float(breakdown.get("total_ms", 0.0)), float(breakdown.get("round_native_ms", res.get("round_native_ms", 0.0))), float(breakdown.get("weather_ms", 0.0))])
			if _generator._weather_system.has_method("apply_unified_fast_tick_result"):
				var weather_t0: int = Time.get_ticks_usec()
				var fronts_out: Array[WeatherFront] = _generator._weather_system.apply_unified_fast_tick_result(breakdown)
				_generator._get_native_daily_publish()._native_daily_add_complete_apply_ms(
					complete_apply_diag,
					"complete_apply_weather_result_ms",
					Time.get_ticks_usec() - weather_t0
				)
				var visual_t0: int = Time.get_ticks_usec()
				_generator._get_native_daily_publish()._apply_native_daily_visual_intents(res, breakdown, fronts_out, _map, _world)
				_generator._get_native_daily_publish()._native_daily_add_complete_apply_ms(
					complete_apply_diag,
					"complete_apply_visual_intents_ms",
					Time.get_ticks_usec() - visual_t0
				)
		elif rc_int != 0:
			_generator._weather_stage_b_call_index = maxi(0, _generator._weather_stage_b_call_index - 1)
			if _generator._weather_system.has_method("_clear_weather_field_slice_state"):
				_generator._weather_system._clear_weather_field_slice_state()
			if not _generator._unified_fast_tick_warned_fallback:
				_generator._unified_fast_tick_warned_fallback = true
				push_warning("[native_daily/unified] native slice rc=%d fail_stage=%s; weather state cleared"
						% [rc_int, String(res.get("fail_stage", "unknown"))])
	_generator._native_daily_slice_round_active = rc_int == 0 and not done
	_generator._native_daily_slice_next_node_index = int(res.get("next_node_index", -1)) if _generator._native_daily_slice_round_active else -1
	if rc_int == 0 and done and not climate_authority_suppressed:
		# Finalizer below re-writes the clamped TTA dense → skip the redundant raw dense write.
		var complete_publish_t0: int = Time.get_ticks_usec()
		_generator._get_native_daily_publish()._publish_native_daily_temperature_transport_anomaly(_map, _generator._native_daily_slice_active_bundle, breakdown, res, true)
		_generator._get_native_daily_publish()._native_daily_add_complete_apply_ms(
			complete_apply_diag,
			"complete_apply_publish_tta_ms",
			Time.get_ticks_usec() - complete_publish_t0
		)
		var finalizer_t0: int = Time.get_ticks_usec()
		var finalizer_diag: Dictionary = _generator._get_native_daily_publish()._native_daily_apply_finalizer(_map)
		_generator._get_native_daily_publish()._native_daily_add_complete_apply_ms(
			complete_apply_diag,
			"complete_apply_finalizer_ms",
			Time.get_ticks_usec() - finalizer_t0
		)
		var merge_t0: int = Time.get_ticks_usec()
		_generator._get_native_daily_publish()._merge_native_daily_finalizer_diag(breakdown, finalizer_diag)
		_generator._get_native_daily_publish()._merge_native_daily_finalizer_diag(res, finalizer_diag)
		_generator._get_native_daily_publish()._native_daily_add_complete_apply_ms(
			complete_apply_diag,
			"complete_apply_finalizer_merge_ms",
			Time.get_ticks_usec() - merge_t0
		)
		var result_patch_t0: int = Time.get_ticks_usec()
		if _map != null and _map.temperature_transport_anomaly_arr.size() == _map.soa_size():
			res["temperature_transport_anomaly_out"] = _map.temperature_transport_anomaly_arr
		_generator._get_native_daily_publish()._native_daily_add_complete_apply_ms(
			complete_apply_diag,
			"complete_apply_result_patch_ms",
			Time.get_ticks_usec() - result_patch_t0
		)
	_generator._native_daily_slice_range_active = rc_int == 0 and not done and bool(res.get("node_range_active", breakdown.get("node_range_active", false)))
	var active_deferred_node_count: int = int(_generator._native_daily_slice_active_bundle.get("deferred_node_count", 0))
	var active_bundle_cache_hit: bool = bool(_generator._native_daily_slice_active_bundle.get("bundle_cache_hit", false))
	var active_bundle_cache_rebuild_reason: String = str(_generator._native_daily_slice_active_bundle.get("bundle_cache_rebuild_reason", ""))
	var active_bundle_static_ms: float = float(_generator._native_daily_slice_active_bundle.get("bundle_static_ms", 0.0))
	var active_bundle_dynamic_ms: float = float(_generator._native_daily_slice_active_bundle.get("bundle_dynamic_ms", bundle_ms))
	var active_weather_knobs_prebuilt: bool = bool(_generator._native_daily_slice_active_bundle.get("weather_knobs_prebuilt", false))
	if not _generator._native_daily_slice_round_active:
		_generator._native_daily_finalizer_pending = false
		_generator._native_daily_finalizer_pending_res = {}
		_generator._native_daily_finalizer_pending_breakdown = {}
		_generator._native_daily_slice_unified_weather_embedded = false
		_generator._native_daily_slice_bundle_pass_keys = []
		_generator._native_daily_slice_active_bundle = {}
		_generator._native_daily_slice_next_node_index = -1
		_generator._native_daily_slice_range_active = false
		_generator._native_daily_slice_phase_locked = 0.0
		_generator._native_daily_slice_temp_start_arr = PackedFloat32Array()
		_generator._native_daily_slice_tta_start_arr = PackedFloat32Array()
		_generator._native_daily_slice_thermal_start_arr = PackedFloat32Array()
	var wrapper_wall_ms: float = float(Time.get_ticks_usec() - wall_t0) / 1000.0
	var apply_ms: float = maxf(0.0, wrapper_wall_ms - bundle_ms - native_call_ms)
	if rc_int == 0 and done:
		_generator._get_native_daily_publish()._native_daily_install_complete_apply_diag(res, breakdown, complete_apply_diag, apply_ms)
	if starting_round:
		_generator._native_daily_round_bundle_accum_ms = 0.0
		_generator._native_daily_round_native_accum_ms = 0.0
		_generator._native_daily_round_apply_accum_ms = 0.0
		_generator._native_daily_round_slice_count = 0
	_generator._native_daily_round_bundle_accum_ms += bundle_ms
	_generator._native_daily_round_native_accum_ms += native_call_ms
	_generator._native_daily_round_apply_accum_ms += apply_ms
	_generator._native_daily_round_slice_count += 1
	res["bundle_ms"] = bundle_ms
	res["deferred_node_count"] = active_deferred_node_count
	res["jit_patch_build_ms"] = jit_patch_build_ms
	res["jit_patch_keys"] = jit_patch_keys
	res["bundle_cache_hit"] = active_bundle_cache_hit
	res["bundle_cache_rebuild_reason"] = active_bundle_cache_rebuild_reason
	res["bundle_static_ms"] = active_bundle_static_ms
	res["bundle_dynamic_ms"] = active_bundle_dynamic_ms
	res["weather_knobs_prebuilt"] = active_weather_knobs_prebuilt
	res["native_call_ms"] = native_call_ms
	res["apply_ms"] = apply_ms
	res["wrapper_wall_ms"] = wrapper_wall_ms
	breakdown["bundle_ms"] = bundle_ms
	breakdown["deferred_node_count"] = res["deferred_node_count"]
	breakdown["jit_patch_build_ms"] = jit_patch_build_ms
	breakdown["jit_patch_keys"] = jit_patch_keys
	breakdown["bundle_cache_hit"] = res["bundle_cache_hit"]
	breakdown["bundle_cache_rebuild_reason"] = res["bundle_cache_rebuild_reason"]
	breakdown["bundle_static_ms"] = res["bundle_static_ms"]
	breakdown["bundle_dynamic_ms"] = res["bundle_dynamic_ms"]
	breakdown["weather_knobs_prebuilt"] = res["weather_knobs_prebuilt"]
	breakdown["native_call_ms"] = native_call_ms
	breakdown["apply_ms"] = apply_ms
	breakdown["wrapper_wall_ms"] = wrapper_wall_ms
	if rc_int == 0 and done:
		breakdown["round_bundle_ms"] = _generator._native_daily_round_bundle_accum_ms
		breakdown["round_native_call_ms"] = _generator._native_daily_round_native_accum_ms
		breakdown["round_apply_ms"] = _generator._native_daily_round_apply_accum_ms
		breakdown["round_slice_count"] = _generator._native_daily_round_slice_count
		res["round_bundle_ms"] = _generator._native_daily_round_bundle_accum_ms
		res["round_native_call_ms"] = _generator._native_daily_round_native_accum_ms
		res["round_apply_ms"] = _generator._native_daily_round_apply_accum_ms
		res["round_slice_count"] = _generator._native_daily_round_slice_count
	var contract_state: String = "active"
	var contract_committed: bool = false
	if rc_int != 0:
		contract_state = "failed"
	elif done:
		contract_state = "complete"
		contract_committed = true
	elif _generator._native_daily_finalizer_pending:
		contract_state = "pending_finalizer"
	_generator._native_daily_stamp_contract(res, breakdown, ctx, contract_committed, contract_state)
	res["breakdown"] = breakdown
	_generator._get_native_daily_publish()._record_native_daily_slice_climate_breakdown(res, breakdown, _map, done, rc_int)
	# Shallow copy (CoW-safe): the scheduler/diagnostics read scalars + the fronts
	# object array; the large output arrays (e.g. temperature_transport_anomaly_out)
	# are shared by ref, not deep-copied each slice. native_daily_last_result() also
	# returns a shallow copy.
	_generator._native_daily_last_result = res.duplicate()
	if rc_int != 0 or done:
		_generator._native_daily_reset_contract_round()
	return res



func run_native_daily_tick_from_job(ctx: SusTickContext, _map: MapData, _world: WorldData) -> Dictionary:
	if _generator._data_core_world_ext == null:
		return { "rc": -1, "fail_stage": "gdext_unavailable" }
	var wall_t0: int = Time.get_ticks_usec()
	var bundle_t0: int = wall_t0
	if _map != null and _map.has_soa() and _map.has_method("soa_begin_climate_transaction"):
		_map.soa_begin_climate_transaction()
	var bundle: Dictionary = _generator._get_native_daily_bundle_builder()._build_native_daily_bundle(ctx, _map, _world, true)
	var bundle_ms: float = float(Time.get_ticks_usec() - bundle_t0) / 1000.0
	var unified_weather_embedded: bool = bundle.has("weather_knobs")
	var tick_knobs: Dictionary = _generator._get_native_daily_bundle_builder()._native_daily_base_tick_knobs(ctx)
	tick_knobs["native_daily_bundle"] = bundle
	var native_t0: int = Time.get_ticks_usec()
	var res: Dictionary = _generator._data_core_world_ext.run_native_daily_tick(tick_knobs)
	var native_call_ms: float = float(Time.get_ticks_usec() - native_t0) / 1000.0
	res["bundle_pass_keys"] = _generator._get_native_daily_bundle_builder()._native_daily_bundle_pass_keys(bundle)
	var breakdown: Dictionary = res.get("breakdown", {})
	_generator._diagnostics_bus.replace_weather_breakdown(breakdown, _generator._current_fast_tick_idx)
	# 方案 ④ Step 1：标记本帧 fast tick，perf_recorder 据此过滤 stale 回放
	# 5/21 突刺诊断：weather_tick≥5ms 或 cyclone≥3ms 时打全字段
	_generator._dump_weather_breakdown_if_slow()
	# Phase A.2 unified fast tick：成功路径下同步 weather state（fronts + cyclone +
	# cover_dirty + slice cleanup）。失败路径下回滚 stage_b call_index 并清 slice state
	# 让下次有机会重试 / 让独立 weather_refresh_job 接手（如果它被注册）。
	if unified_weather_embedded and _generator._weather_system != null:
		var rc_int: int = int(res.get("rc", -1))
		if rc_int == 0:
			if not _generator._unified_fast_tick_first_log_done:
				_generator._unified_fast_tick_first_log_done = true
				print("[native_daily/unified] gdext path ACTIVE — weather_knobs embedded in native_daily_bundle; 16-pass single-marshal tick first run total_ms=%.2f weather_ms=%.2f"
						% [float(breakdown.get("total_ms", 0.0)), float(breakdown.get("weather_ms", 0.0))])
			if _generator._weather_system.has_method("apply_unified_fast_tick_result"):
				# breakdown 顶层就是 weather 段产出（C++ 端 copy_dict_into 把
				# run_weather_refresh_daily_pass 返回值合进 native_daily breakdown）。
				var fronts_out: Array[WeatherFront] = _generator._weather_system.apply_unified_fast_tick_result(breakdown)
				_generator._get_native_daily_publish()._apply_native_daily_visual_intents(res, breakdown, fronts_out, _map, _world)
		else:
			# 失败回滚：stage_b call_index 还原 + 清理 slice state（weather_system 内部
			# 已自我守护，但 caller 端也防御性清一次，避免泄漏到下个 tick）。
			_generator._weather_stage_b_call_index = maxi(0, _generator._weather_stage_b_call_index - 1)
			if _generator._weather_system.has_method("_clear_weather_field_slice_state"):
				_generator._weather_system._clear_weather_field_slice_state()
			if not _generator._unified_fast_tick_warned_fallback:
				_generator._unified_fast_tick_warned_fallback = true
				push_warning("[native_daily/unified] embedded weather_knobs path rc=%d fail_stage=%s; weather_refresh state cleared; will fallback to independent jobs next tick"
						% [rc_int, String(res.get("fail_stage", "unknown"))])
	if int(res.get("rc", -1)) == 0:
		_generator._get_native_daily_publish()._publish_native_daily_temperature_transport_anomaly(_map, bundle, breakdown, res)
	var wrapper_wall_ms: float = float(Time.get_ticks_usec() - wall_t0) / 1000.0
	var apply_ms: float = maxf(0.0, wrapper_wall_ms - bundle_ms - native_call_ms)
	res["bundle_ms"] = bundle_ms
	res["native_call_ms"] = native_call_ms
	res["apply_ms"] = apply_ms
	res["wrapper_wall_ms"] = wrapper_wall_ms
	breakdown["bundle_ms"] = bundle_ms
	breakdown["native_call_ms"] = native_call_ms
	breakdown["apply_ms"] = apply_ms
	breakdown["wrapper_wall_ms"] = wrapper_wall_ms
	res["breakdown"] = breakdown
	_generator._native_daily_last_result = res.duplicate(true)
	return res



func sus_tick_daily(world_clock_node, day_index_override: int = -1,
		season_phase_override: float = NAN) -> Dictionary:
	if _generator._sus == null:
		return { "fronts": [] as Array[WeatherFront], "weather_ran": false }
	var di: int = 0
	var sp: float = 0.0
	var ss: float = 1.0
	if world_clock_node != null:
		if world_clock_node.has_method("day_index"):
			di = int(world_clock_node.day_index())
		if world_clock_node.has_method("season_phase"):
			sp = float(world_clock_node.season_phase())
		# WorldClock.speed_multiplier 是普通成员变量；用 get() 安全读取。
		var v = world_clock_node.get("speed_multiplier")
		if v != null:
			ss = float(v)
	if day_index_override >= 0:
		di = day_index_override
	if not is_nan(season_phase_override):
		sp = season_phase_override
	# A sliced Climate round may finish on a later render-frame/day boundary.
	# Release older completed references first; capture remains ordered but is
	# allowed to queue behind an unreleased frame so each input day is retained.
	# The tick's input is day - 1, but never a day already published (a fresh
	# world publishes day 1 during preparation). publish_environment_through
	# fills any day a full ring refused, in order.
	var trace_input_day: int = maxi(maxi(0, di - 1),
		_generator._get_runtime_climate_capture().next_environment_day() - 1)
	var runtime_climate_pre_reference: Dictionary = \
		_generator._get_runtime_climate_capture()._publish_ready_runtime_climate_references(trace_input_day - 1, _generator._sus_map)
	# Capture the immutable Climate input immediately before the synchronous OFF
	# graph. The worker never reads MapData directly; it can only consume this
	# frame after _publish_runtime_climate_reference() releases its hash below.
	# capture 留在同步图之前，ACTIVE 也一样。
	#
	# 试过在 ACTIVE 下把它挪到 _sus.tick() 之后（那条约束的原始理由——「worker 要吃
	# 生产 pass_a 稍后读到的同一份输入」——在 ACTIVE 下确实不再成立，因为生产 climate
	# 被抑制门整段关掉了）。动机是让 season refresh 的季节性重算能进入 worker。
	#
	# 结果是零改善：snow_cover 非零格仍恒 113~117、soil_moisture 仍恒 914、
	# vegetation_growth_pressure 仍恒 909、moisture 仍 0.902~0.913，与挪动前逐项一致
	# （stage 接线也确认未受影响，累计 pass_a=149 weather=19 albedo=1）。
	#
	# 所以「worker 的场平坦 = 季节信号被 capture 时点挡在门外」这个假设是错的，真正
	# 的原因在别处。挪回来：没有证据支持的时点改动不值得留在这条路径上。
	var runtime_climate_capture: Dictionary = \
		_generator._get_runtime_climate_capture().publish_environment_through(trace_input_day, sp, _generator.ENV_CALLSITE_SUS_TICK)
	# 任务 8：每个 tick 入场前清掉 weather_refresh 的 ran_this_tick 标志，
	# 这样 SUS 决定跳过该 Job 时它就保持 false（main.gd 据此跳过 UI 行刷新）。
	if _generator._refresh_climate_daily_job != null:
		_generator._refresh_climate_daily_job.reset_run_flag()
	if _generator._sea_ice_daily_job != null and _generator._sea_ice_daily_job.has_method("reset_run_flag"):
		_generator._sea_ice_daily_job.reset_run_flag()
	if _generator._weather_refresh_job != null:
		_generator._weather_refresh_job.reset_run_flag()
	if _generator._native_daily_sim_job != null and _generator._native_daily_sim_job.has_method("reset_run_flag"):
		_generator._native_daily_sim_job.reset_run_flag()
	var ctx: SusTickContext = SusTickContext.make(di, di, sp, ss, &"day_changed")
	_generator._sync_data_core_runtime_terrain_mirror(_generator._sus_map, "sus_tick_pre")
	_generator._sus.tick(ctx)
	var runtime_graph_pulse: Dictionary = {}
	if _generator._runtime_graph_active and not _generator.native_daily_round_active() \
			and not _generator.bio_occupancy_round_active():
		runtime_graph_pulse = _generator._advance_runtime_graph_pulse(di)
	# Bio remains daily-semantic even when its first slice loses the ordinary
	# frame-budget race. Convert that skip into a same-day pending transaction;
	# the continuation pulse starts it before WorldClock may advance.
	var sus_tick_report: Dictionary = _generator._sus.report_last_tick()
	var bio_tick_report: Dictionary = sus_tick_report.get(&"bio_occupancy_daily",
		sus_tick_report.get("bio_occupancy_daily", {}))
	var bio_skip_reason := str(bio_tick_report.get("skipped_reason", ""))
	if _generator._bio_occupancy_daily_job != null and bio_skip_reason in [
			"frame_budget_exhausted", "strict_budget_one_job"]:
		_generator._bio_occupancy_day_pending = true
	if not _generator._bio_occupancy_slice_inflight and bio_skip_reason == "":
		var bio_done_reported := bool(bio_tick_report.get("done", true))
		if bio_done_reported:
			_generator._bio_occupancy_day_pending = false
	# Native daily has the same same-day transaction boundary as Bio.  A first
	# slice skipped by SUS budget must be started by the continuation pulse before
	# WorldClock is allowed to advance; otherwise that semantic day would be
	# silently lost because the job has not established _native_round_active yet.
	var native_tick_report: Dictionary = sus_tick_report.get(&"native_daily_sim",
		sus_tick_report.get("native_daily_sim", {}))
	var native_skip_reason := str(native_tick_report.get("skipped_reason", ""))
	if _generator._native_daily_sim_job != null and native_skip_reason in [
			"frame_budget_exhausted", "strict_budget_one_job"]:
		_generator._native_daily_day_pending = true
	if _generator._native_daily_sim_job != null and native_skip_reason == "":
		var native_done_reported := bool(native_tick_report.get("done", true))
		if native_done_reported and not bool(_generator._native_daily_sim_job.get("_native_round_active")):
			_generator._native_daily_day_pending = false
			# The round reached its immutable boundary, so the captured frame for
			# this day may now be released to the worker.
			_generator._native_daily_climate_round_generation += 1
	if world_clock_node != null and world_clock_node.has_method("request_simulation_backpressure"):
		world_clock_node.request_simulation_backpressure(
			&"native_daily_day_barrier", _generator.native_daily_round_active())
		world_clock_node.request_simulation_backpressure(
			&"bio_occupancy_day_barrier", _generator.bio_occupancy_round_active())
	if _generator._native_daily_sim_job == null:
		_generator._run_native_daily_shadow_probe(ctx, _generator._sus_map, _generator._sus_world)
	var fronts: Array[WeatherFront] = [] as Array[WeatherFront]
	var weather_ran: bool = false
	# Drift-fix（2026-05-10）：暴露"fronts 是否真的变了"标志。
	# 与 weather_ran 区别：field 分片期间二者都保持 false；只有 commit + stage_b
	# 完成、_last_fronts 重新赋值时才置位，避免 UI/renderer 读取半成品。
	# main.gd 用它 gate renderer.set_weather_fronts 调用，避免每隔一 tick 重复推送
	# 同一份 fronts 触发 weather_layer 内部的 blend reset → 云视觉冻结。
	var fronts_changed: bool = false
	var fronts_diff: Dictionary = {}
	if _generator._weather_refresh_job != null:
		fronts = _generator._weather_refresh_job.last_fronts()
		weather_ran = _generator._weather_refresh_job.did_run_last_tick()
		fronts_changed = _generator._weather_refresh_job.did_change_fronts_last_tick()
		if _generator._weather_refresh_job.has_method("last_fronts_diff_report"):
			fronts_diff = _generator._weather_refresh_job.last_fronts_diff_report()
	elif _generator._native_daily_sim_job != null:
		var native_res: Dictionary = _generator._native_daily_last_result
		weather_ran = int(native_res.get("rc", -1)) == 0
		fronts_changed = bool(native_res.get("fronts_changed", false))
		for f in native_res.get("fronts", []):
			if f is WeatherFront:
				fronts.append(f)
		fronts_diff = native_res.get("fronts_diff", {})
	if weather_ran and _generator._sus_map != null:
		var cyclone_snapshot: Dictionary = {}
		if _generator._data_core_world_ext != null :
			cyclone_snapshot = _generator._data_core_world_ext.get_active_cyclone_snapshot()
		_generator.WeatherResearchSignalPublisherScript.publish(
			_generator._sus_map, _generator._country_facade, _generator._gameplay_event_bus, di, cyclone_snapshot)
	# 天气类型交叉淡入的"跳过日 GDScript 兜底"已移除（2026-06-17）：该淡入纯属
	# 视觉平滑，且没有任何 shader 采样 cell.weather_transition_alpha（地图只读离散
	# weather_type），高倍速下逐 cell fan-out 反而是 ~35ms/次的空耗。淡入开关
	# weather_transition_enabled 现仅作用于 C++ weather.commit（跑天气日推进）。
	if world_clock_node != null and world_clock_node.has_method("note_sim_slice_diag"):
		var economy_tick: Dictionary = sus_tick_report.get(&"economy_daily",
			sus_tick_report.get("economy_daily", {}))
		world_clock_node.note_sim_slice_diag({
			"largest_slice_ms": float(sus_tick_report.get("largest_slice_ms", 0.0)),
			"largest_slice_job": str(sus_tick_report.get("largest_slice_job", "")),
			"largest_slice_stage": str(sus_tick_report.get("largest_slice_stage", "")),
			"commit_over_budget": bool(economy_tick.get("commit_over_budget", false)),
			"native_stage": str(native_tick_report.get("stage_name",
				native_tick_report.get("substage", ""))),
		})
	var runtime_climate_reference: Dictionary = \
		_generator._get_runtime_climate_capture()._publish_ready_runtime_climate_references(trace_input_day, _generator._sus_map)
	return { "fronts": fronts, "weather_ran": weather_ran, "fronts_changed": fronts_changed,
		"fronts_diff": fronts_diff, "runtime_graph": runtime_graph_pulse,
		"runtime_climate_pre_reference": runtime_climate_pre_reference,
		"runtime_climate_capture": runtime_climate_capture,
		"runtime_climate_reference": runtime_climate_reference,
		"runtime_climate_trace": _generator._get_runtime_climate_capture().runtime_climate_trace_report(), }


## 地图重新生成 / regenerate 路径调用：清空所有 Job 的进度游标 + pending 缓冲。

func sus_reset_all() -> void:
	_generator._abort_all_climate_passes("sus_reset_all")
	# A regenerate/restore invalidates every captured frame. The C++ host is
	# stopped by WorldRuntimeHost before this reset, so no stale reference may be
	# released into the next map's trace.
	_generator._runtime_climate_trace_pending.clear()
	_generator._runtime_climate_reference_last_day = -1
	_generator._runtime_climate_reference_last_hash = 0
	_generator._runtime_climate_reference_last_error = ""
	# Drop same-day transient transactions before a map regenerate/restore. The
	# new world must never inherit a stale Bio/native daily barrier from the old
	# map, even when reset is requested between continuation pulses.
	_generator._bio_occupancy_slice_inflight = false
	_generator._bio_occupancy_day_pending = false
	_generator._native_daily_slice_round_active = false
	_generator._native_daily_day_pending = false
	_generator._native_daily_slice_range_active = false
	_generator._native_daily_finalizer_pending = false
	_generator._native_daily_finalizer_pending_res = {}
	_generator._native_daily_finalizer_pending_breakdown = {}
	_generator._native_daily_slice_active_bundle = {}
	_generator._native_daily_slice_bundle_pass_keys = []
	_generator._native_daily_slice_next_node_index = -1
	_generator._native_daily_slice_unified_weather_embedded = false
	_generator._native_daily_reset_contract_round()
	if _generator._world_clock_ref != null and _generator._world_clock_ref.has_method("request_simulation_backpressure"):
		_generator._world_clock_ref.request_simulation_backpressure(&"bio_occupancy_day_barrier", false)
		_generator._world_clock_ref.request_simulation_backpressure(&"native_daily_day_barrier", false)
	_generator._diagnostics_bus.clear_all()
	if _generator._sus != null:
		_generator._sus.reset_all_progress()




func set_current_fast_tick_idx(idx: int) -> void:
	_generator._current_fast_tick_idx = idx
	# DVA 不持有 generator 引用，单独同步过去；其内部 4 个 _last_breakdown 写入点
	# 直接读 current_fast_tick_idx。
	if _generator._dynamic_visual_atlas_upload_job != null \
			and "current_fast_tick_idx" in _generator._dynamic_visual_atlas_upload_job:
		_generator._dynamic_visual_atlas_upload_job.current_fast_tick_idx = idx



func sus_ocean_currents_breakdown() -> Dictionary:
	var out: Dictionary = {}
	if _generator._ocean_currents_job != null and _generator._ocean_currents_job.has_method("last_physical_diag"):
		out = _generator._ocean_currents_job.last_physical_diag()
	if _generator._baker != null and _generator._baker.has_method("get_physical_circulation_diag"):
		var baker_diag: Dictionary = _generator._baker.get_physical_circulation_diag()
		for k in baker_diag.keys():
			out[k] = baker_diag[k]
	out["_tick_idx"] = _generator._current_fast_tick_idx
	return out



func _weather_front_count_from_value(v) -> int:
	match typeof(v):
		TYPE_INT:
			return int(v)
		TYPE_FLOAT:
			return int(v)
		TYPE_ARRAY:
			return (v as Array).size()
		TYPE_PACKED_FLOAT32_ARRAY:
			return (v as PackedFloat32Array).size()
		TYPE_PACKED_INT32_ARRAY:
			return (v as PackedInt32Array).size()
		TYPE_PACKED_STRING_ARRAY:
			return (v as PackedStringArray).size()
		TYPE_DICTIONARY:
			var d: Dictionary = v
			return _generator._weather_front_count_from_value(d.get("fronts_count", d.get("n_fronts", 0)))
		_:
			return 0



func _normalized_weather_breakdown(src: Dictionary) -> Dictionary:
	var out: Dictionary = src.duplicate(true)
	var front_count: int = _generator._weather_front_count_from_value(
		out.get("fronts_count", out.get("fronts", 0))
	)
	if out.has("fronts") and typeof(out.get("fronts")) != TYPE_INT:
		out["fronts_raw"] = out.get("fronts")
	out["fronts"] = front_count
	out["fronts_count"] = front_count
	return out



func consume_pending_enum_atlas_axis() -> String:
	if _generator._enum_atlas_biome_dirty:
		_generator._enum_atlas_biome_dirty = false
		_generator._enum_atlas_cover_dirty = false
		_generator._enum_atlas_vegetation_dirty = false
		return "biome"
	if _generator._enum_atlas_cover_dirty:
		_generator._enum_atlas_cover_dirty = false
		return "cover"
	if _generator._enum_atlas_vegetation_dirty:
		_generator._enum_atlas_vegetation_dirty = false
		return "vegetation"
	return ""



func queue_detail_scatter_refresh(indices: PackedInt32Array) -> void:
	if indices.is_empty():
		return
	var seen := {}
	for idx in _generator._pending_detail_scatter_refresh_indices:
		seen[int(idx)] = true
	for idx in indices:
		var ci := int(idx)
		if ci < 0 or seen.has(ci):
			continue
		seen[ci] = true
		_generator._pending_detail_scatter_refresh_indices.append(ci)



func has_pending_detail_scatter_refresh() -> bool:
	if not _generator._pending_detail_scatter_refresh_indices.is_empty() \
			or not _generator._pending_detail_scatter_change_sets.is_empty():
		return true
	if _generator._gameplay_event_bus != null and _generator._gameplay_event_bus.is_available():
		var probe: Dictionary = _generator._gameplay_event_bus.poll_events(
			&"detail_renderer",
			1,
			GameplayEventBus.EVENT_VEGETATION_SUCCESSION,
			false
		)
		return int(probe.get("count", 0)) > 0
	return false



func consume_pending_detail_scatter_refresh_indices() -> PackedInt32Array:
	var out := PackedInt32Array()
	var seen := {}
	if _generator._gameplay_event_bus != null and _generator._gameplay_event_bus.is_available():
		var event_cells: PackedInt32Array = _generator._gameplay_event_bus.poll_succession_cells(&"detail_renderer", 512, true)
		for idx in event_cells:
			var ci_event := int(idx)
			if ci_event < 0 or seen.has(ci_event):
				continue
			seen[ci_event] = true
			out.append(ci_event)
	for idx in _generator._pending_detail_scatter_refresh_indices:
		var ci := int(idx)
		if ci < 0 or seen.has(ci):
			continue
		seen[ci] = true
		out.append(ci)
	_generator._pending_detail_scatter_refresh_indices = PackedInt32Array()
	_generator._pending_detail_scatter_change_sets.clear()
	return out



func consume_pending_detail_scatter_changes():
	_generator._detail_scatter_change_generation += 1
	var merged := {}
	# 无 old/new 状态的旧事件保持兼容；精确 tick diff 在后面覆盖同格 unknown。
	if _generator._gameplay_event_bus != null and _generator._gameplay_event_bus.is_available():
		var event_cells: PackedInt32Array = _generator._gameplay_event_bus.poll_succession_cells(&"detail_renderer", 512, true)
		for raw_idx in event_cells:
			var ci := int(raw_idx)
			if ci >= 0:
				merged[ci] = {"axis": _generator.DetailScatterChangeSetScript.AXIS_UNKNOWN}
	for raw_idx in _generator._pending_detail_scatter_refresh_indices:
		var ci := int(raw_idx)
		if ci >= 0 and not merged.has(ci):
			merged[ci] = {"axis": _generator.DetailScatterChangeSetScript.AXIS_UNKNOWN}
	for raw_set in _generator._pending_detail_scatter_change_sets:
		if raw_set == null or not raw_set.has_method("is_well_formed") \
				or not bool(raw_set.is_well_formed()):
			continue
		for i in range(raw_set.cell_indices.size()):
			var ci := int(raw_set.cell_indices[i])
			if ci < 0:
				continue
			merged[ci] = {
				"axis": int(raw_set.axis_masks[i]),
				"ov": int(raw_set.old_vegetation[i]), "nv": int(raw_set.new_vegetation[i]),
				"ol": int(raw_set.old_landform[i]), "nl": int(raw_set.new_landform[i]),
				"oc": int(raw_set.old_cover[i]), "nc": int(raw_set.new_cover[i]),
			}
	_generator._pending_detail_scatter_refresh_indices = PackedInt32Array()
	_generator._pending_detail_scatter_change_sets.clear()
	var out = _generator.DetailScatterChangeSetScript.new()
	out.generation = _generator._detail_scatter_change_generation
	var keys: Array = merged.keys()
	keys.sort()
	for raw_idx in keys:
		var ci := int(raw_idx)
		var row: Dictionary = merged[raw_idx]
		out.append_change(
			ci,
			int(row.get("axis", _generator.DetailScatterChangeSetScript.AXIS_UNKNOWN)),
			int(row.get("ov", 0)), int(row.get("nv", 0)),
			int(row.get("ol", 0)), int(row.get("nl", 0)),
			int(row.get("oc", 0)), int(row.get("nc", 0))
		)
	return out



func record_enum_atlas_upload(axis: String, elapsed_ms: float) -> void:
	_generator._last_enum_atlas_upload_breakdown = {
		"axis": axis,
		"elapsed_ms": elapsed_ms,
		"biome_pending": _generator._enum_atlas_biome_dirty,
		"cover_pending": _generator._enum_atlas_cover_dirty,
		"vegetation_pending": _generator._enum_atlas_vegetation_dirty,
		# 方案 ④ Step 1：标记本帧 fast tick，perf_recorder 据此过滤 stale 回放
		"_tick_idx": _generator._current_fast_tick_idx,
	}



func record_enum_atlas_upload_report(report: Dictionary) -> void:
	_generator._last_enum_atlas_upload_breakdown = report.duplicate(true)
	_generator._last_enum_atlas_upload_breakdown["biome_pending"] = _generator._enum_atlas_biome_dirty
	_generator._last_enum_atlas_upload_breakdown["cover_pending"] = _generator._enum_atlas_cover_dirty
	_generator._last_enum_atlas_upload_breakdown["vegetation_pending"] = _generator._enum_atlas_vegetation_dirty
	# 方案 ④ Step 1：标记本帧 fast tick，perf_recorder 据此过滤 stale 回放
	_generator._last_enum_atlas_upload_breakdown["_tick_idx"] = _generator._current_fast_tick_idx



func sus_dynamic_visual_atlas_breakdown() -> Dictionary:
	if _generator._dynamic_visual_atlas_upload_job != null \
			and _generator._dynamic_visual_atlas_upload_job.has_method("last_breakdown"):
		return _generator._dynamic_visual_atlas_upload_job.last_breakdown()
	return {}



func _climate_authority_grant_pending(thread_report: Dictionary) -> bool:
	# 内联日（web）没有 worker：grant 只能由内联日自己产生，在这里等它等于等自己。
	# 这个 60s 自旋整段落在 inline_day 的计时区间里，浏览器上表现为"首日卡 24 秒 ~
	# 彻底挂死"，而所有 native stage_ms 都只有 ~1ms。
	if bool(thread_report.get("native_daily_inline", false)):
		return false
	if int(thread_report.get("simulation_environment_generation", 0)) <= 0 \
			or bool(thread_report.get("climate_worker_authoritative", false)):
		return false
	if String(thread_report.get("requested_simulation_thread_mode", "")) != "ACTIVE" \
			or String(thread_report.get("state", "")) == "FAULTED":
		return false
	if (int(thread_report.get("requested_authority_mask", 0)) \
			& _generator.RUNTIME_CLIMATE_DOMAIN_BIT) == 0:
		return false
	return int(thread_report.get("simulation_committed_day", -1)) \
		< int(thread_report.get("simulation_environment_day", -1))


## Waits until the worker has committed the last captured day; if the grant did
## not land with it, it is not coming on a fixed day and waiting longer only stalls.

func _wait_climate_authority_grant() -> Dictionary:
	var ext = _generator._data_core_world_ext
	var started_ms := Time.get_ticks_msec()
	var report: Dictionary = _generator.get_runtime_thread_report()
	while _generator._climate_authority_grant_pending(report):
		if Time.get_ticks_msec() - started_ms > _generator.CLIMATE_AUTHORITY_GRANT_TIMEOUT_MS:
			push_warning("[climate-authority] grant wait timed out at day %d"
				% int(report.get("simulation_environment_day", -1)))
			break
		_generator.service_country_worker_peer_adapter(64, false)
		if ext != null:
			ext.wait_climate_consumed(_generator._runtime_input_generation, 10)
		OS.delay_usec(200)
		report = _generator.get_runtime_thread_report()
	return report



func _prime_scatter_sync_snapshot(map: MapData) -> void:
	if map == null or not map.has_soa():
		_generator._scatter_sync_snap_landform = PackedByteArray()
		_generator._scatter_sync_snap_vegetation = PackedByteArray()
		_generator._scatter_sync_snap_cover = PackedByteArray()
		return
	_generator._scatter_sync_snap_landform = map.landform_arr.duplicate()
	_generator._scatter_sync_snap_vegetation = map.vegetation_arr.duplicate()
	_generator._scatter_sync_snap_cover = map.cover_arr.duplicate()



func sync_detail_scatter_after_tick(map: MapData) -> void:
	if map == null or not map.has_soa():
		return
	var n: int = map.cell_count()
	var landform_a: PackedByteArray = map.landform_arr
	var vegetation_a: PackedByteArray = map.vegetation_arr
	var cover_a: PackedByteArray = map.cover_arr
	if _generator._scatter_sync_snap_vegetation.size() != n \
			or _generator._scatter_sync_snap_landform.size() != n \
			or _generator._scatter_sync_snap_cover.size() != n \
			or vegetation_a.size() != n or landform_a.size() != n \
			or cover_a.size() != n:
		_generator._prime_scatter_sync_snapshot(map)
		return
	# 快路径：PackedByteArray == 是原生 memcmp。权威脏源已有 pending 时只对齐快照，
	# 避免季节日再扫 2400 格并与 bus/changeset 双排队。
	var l_same: bool = _generator._scatter_sync_snap_landform == landform_a
	var c_same: bool = _generator._scatter_sync_snap_cover == cover_a
	var v_same: bool = _generator._scatter_sync_snap_vegetation == vegetation_a
	if l_same and c_same and v_same:
		return
	if _generator.has_pending_detail_scatter_refresh() and not _generator.detail_scatter_tick_sync_debug:
		_generator._prime_scatter_sync_snapshot(map)
		_generator._last_detail_scatter_sync["cells"] = 0
		_generator._last_detail_scatter_sync["vegetation_cells"] = 0
		_generator._last_detail_scatter_sync["skipped_pending"] = true
		return
	var changes = _generator.DetailScatterChangeSetScript.new()
	_generator._detail_scatter_change_generation += 1
	changes.generation = _generator._detail_scatter_change_generation
	var veg_changed := 0
	for i in range(n):
		var axis_mask := 0
		if not v_same and _generator._scatter_sync_snap_vegetation[i] != vegetation_a[i]:
			axis_mask |= _generator.DetailScatterChangeSetScript.AXIS_VEGETATION
			veg_changed += 1
		if not l_same and _generator._scatter_sync_snap_landform[i] != landform_a[i]:
			axis_mask |= _generator.DetailScatterChangeSetScript.AXIS_LANDFORM
		if not c_same and _generator._scatter_sync_snap_cover[i] != cover_a[i]:
			axis_mask |= _generator.DetailScatterChangeSetScript.AXIS_COVER
		if axis_mask != 0:
			changes.append_change(
				i, axis_mask,
				int(_generator._scatter_sync_snap_vegetation[i]), int(vegetation_a[i]),
				int(_generator._scatter_sync_snap_landform[i]), int(landform_a[i]),
				int(_generator._scatter_sync_snap_cover[i]), int(cover_a[i])
			)
	if changes.is_empty():
		_generator._prime_scatter_sync_snapshot(map)
		return
	_generator._prime_scatter_sync_snapshot(map)
	_generator._last_detail_scatter_sync["cells"] = changes.size()
	_generator._last_detail_scatter_sync["vegetation_cells"] = veg_changed
	_generator._last_detail_scatter_sync["skipped_pending"] = false
	_generator.queue_detail_scatter_changes(changes)
	if _generator.detail_scatter_tick_sync_debug:
		print("[detail_scatter] tick-sync queued=%d (vegetation=%d)" % [changes.size(), veg_changed])


# per-stage path once-log。每个 stage_key（如 "stage1"）在同一会话内最多打印一次路径来源。
# stage_key:  stage 标识，例如 "stage1" / "stage_swamp" / "stage0"
# path:       "gdext"（成功）/ "failed"（native 失败）
# detail:     reason / native_ms / 哪个 gate 拦下

func _season_log_path_once(stage_key: String, path: String, detail: String) -> void:
	# 同一 stage 同一 path 同一 detail 才算 dedup；path 切换（fallback→gdext）要重打。
	var k: String = "%s|%s|%s" % [stage_key, path, detail]
	if _generator._season_stage_path_logged.has(k):
		return
	_generator._season_stage_path_logged[k] = true
	print("[season_refresh] %s path=%s %s" % [stage_key, path, detail])


# X2-精简版（2026-05-21）：round 内 SoA-slots 同步守门员。
# 调用模式：每个 stage helper 进入时调本函数（替换原 if has_method+refresh_slots_from_map）。
# 行为：
#   - 若 _season_round_slots_fresh == true（同 round 已 refresh 过，且中间无 fallback 改 cell）
#     → 跳过 refresh_slots_from_map，省 ~14μs Variant get-loop。
#   - 若 false（首次或 round 边界）
#     → 调一次 refresh_slots_from_map，置 true。
# 注意：本 helper 仅用于 season_refresh round 内的 11 处 stage helper（含 micro-pass）。
# climate_pass_a / daily ECS 路径不在 round 内，**不要**改用本 helper。

func _ensure_season_round_slots_fresh() -> void:
	if _generator._data_core_world_ext == null:
		return
	if _generator._season_round_slots_fresh:
		_generator._season_round_slots_skip_count += 1
		return
	# Do not overwrite native-only Economy/resource slots or pay their copy
	# cost at a seasonal boundary.  Every B+ stage reads one of the keys above;
	# its outputs stay in the native slots and publish at their existing stage
	# boundary.
	if _generator._data_core_world_ext.has_method("refresh_slots_from_map_keys"):
		_generator._data_core_world_ext.refresh_slots_from_map_keys(_generator._season_round_refresh_keys)
	else:
		_generator._data_core_world_ext.refresh_slots_from_map()
	_generator._season_round_slots_fresh = true
	_generator._season_round_slots_refresh_count += 1


# refresh-consolidation-2026-06：climate daily round 内 SoA-slots 同步守门员。
# 见 _climate_daily_round_slots_fresh 注释。每个 climate sub-pass 入口调本函数
# 替换原 refresh_slots_from_map()。守门员逻辑与 season 版完全对称。

func _ensure_climate_daily_round_slots_fresh() -> void:
	if _generator._data_core_world_ext == null:
		return
	if _generator._climate_daily_round_slots_fresh:
		_generator._climate_daily_round_slots_skip_count += 1
		return
	_generator._data_core_world_ext.refresh_slots_from_map()
	_generator._climate_daily_round_slots_fresh = true
	_generator._climate_daily_round_slots_refresh_count += 1


# 跨 pass 边界 / fallback 写 cell / round 末尾时调用，让下一次
# _ensure_climate_daily_round_slots_fresh() 重新跑 refresh_slots_from_map()。

func _ensure_natural_resource_knobs() -> void:
	if _generator._natural_resource_pass_knobs.is_empty():
		_generator._natural_resource_pass_knobs = ResourceProfileRegistry.build_pass_knobs()
		_generator._natural_resource_refresh_keys = PackedStringArray([
			"cell_temp",
			"cell_temp_30d",
			"cell_moisture",
			"cell_plant_available_water",
			"cell_is_water",
			"cell_resource_habitat_mask",
		])
		var extra_slots: PackedStringArray = _generator._natural_resource_pass_knobs.get("extra_change_slots", PackedStringArray())
		for slot in extra_slots:
			if slot != "":
				_generator._natural_resource_refresh_keys.append(slot)


