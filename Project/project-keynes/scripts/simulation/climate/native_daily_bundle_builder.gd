extends "res://scripts/simulation/generator_context.gd"

const NativeDailyPassInputs = preload("res://scripts/simulation/climate/native_daily_pass_inputs.gd")

## Native daily graph input bundle construction. Mutable cursors and caches remain on MapGenerator.

func _native_daily_live_f32(slot_name: String, fallback: PackedFloat32Array,
		n: int) -> PackedFloat32Array:
	return NativeDailyPassInputs._native_daily_live_f32(self, slot_name, fallback, n)


func _native_daily_live_u8(slot_name: String, fallback: PackedByteArray,
		n: int) -> PackedByteArray:
	return NativeDailyPassInputs._native_daily_live_u8(self, slot_name, fallback, n)


func _native_daily_base_tick_knobs(ctx: SusTickContext) -> Dictionary:
	return NativeDailyPassInputs._native_daily_base_tick_knobs(self, ctx)


func _build_native_daily_stage_b_knobs(map: MapData, cp_now, call_index: int,
		elapsed_days_per_call: float = 1.0, calendar_day: int = -1) -> Dictionary:
	return NativeDailyPassInputs._build_native_daily_stage_b_knobs(self, map, cp_now, call_index, elapsed_days_per_call, calendar_day)


func _native_daily_season_cadence_policy(cp_now, call_index: int) -> Dictionary:
	return NativeDailyPassInputs._native_daily_season_cadence_policy(self, cp_now, call_index)


func _build_native_daily_climate_pass_a_struct(map: MapData, cp_now, season_phase: float) -> Dictionary:
	return NativeDailyPassInputs._build_native_daily_climate_pass_a_struct(self, map, cp_now, season_phase)


func _build_native_daily_climate_pass_b_knobs(map: MapData, cp_now, season_phase: float) -> Dictionary:
	return NativeDailyPassInputs._build_native_daily_climate_pass_b_knobs(self, map, cp_now, season_phase)


func _build_native_daily_transpiration_knobs(map: MapData, cp_now) -> Dictionary:
	return NativeDailyPassInputs._build_native_daily_transpiration_knobs(self, map, cp_now)


func _build_native_daily_wind_knobs(map: MapData, cp_now) -> Dictionary:
	return NativeDailyPassInputs._build_native_daily_wind_knobs(self, map, cp_now)


func _native_daily_ema_all_initialized(map: MapData, ema_init: PackedByteArray, n: int) -> bool:
	return NativeDailyPassInputs._native_daily_ema_all_initialized(self, map, ema_init, n)


func _build_native_daily_ocean_knobs(map: MapData, cp_now, season_phase: float) -> Dictionary:
	return NativeDailyPassInputs._build_native_daily_ocean_knobs(self, map, cp_now, season_phase)


func _build_native_daily_sea_ice_knobs(
		map: MapData,
		cp_now,
		season_phase: float,
		commit_side_effects: bool,
		dt_cap_days: float = 30.0) -> Dictionary:
	return NativeDailyPassInputs._build_native_daily_sea_ice_knobs(self, map, cp_now, season_phase, commit_side_effects, dt_cap_days)


func _build_native_daily_runtime_hydrology_knobs(map: MapData, cp_now,
		dt_days: float = 1.0) -> Dictionary:
	return NativeDailyPassInputs._build_native_daily_runtime_hydrology_knobs(self, map, cp_now, dt_days)


func _native_daily_required_pass_keys(cp_now) -> PackedStringArray:
	var keys := PackedStringArray(["climate_pass_a_struct"])
	if cp_now != null and bool(cp_now.enable_local_climate_coupling):
		keys.append("climate_pass_b_knobs")
		keys.append("transpiration_knobs")
	if _generator._last_cfg != null and bool(_generator._last_cfg.enable_ocean_heat_transport):
		keys.append("ocean_water_knobs")
		keys.append("ocean_land_knobs")
	var wind_heat_required: bool = true
	if cp_now != null and cp_now.get("enable_wind_heat_transport") != null:
		wind_heat_required = bool(cp_now.enable_wind_heat_transport)
	if wind_heat_required:
		keys.append("wind_air_knobs")
		keys.append("wind_surface_knobs")
	keys.append("sea_ice_knobs")
	# stage_b follows albedo / vegetation / feedback strides and is legitimately
	# absent on most probe ticks. Requiring it here prevents native_daily active
	# handoff even though the scheduler can simply skip that node for the tick.
	var weather_field_required: bool = _generator._weather_system != null \
			and _generator._weather_system.has_method("uses_weather_field") \
			and bool(_generator._weather_system.uses_weather_field())
	if weather_field_required:
		keys.append("weather_knobs")
	if cp_now != null and cp_now.get("runtime_hydrology_enabled") != null \
			and bool(cp_now.runtime_hydrology_enabled):
		if keys.find("weather_knobs") < 0:
			keys.append("weather_knobs")
		# 与 stage_b 同理：stride > 1 时水文在多数 tick 合法缺席，硬性要求它会把
		# native_daily active handoff 卡住。stride == 1（默认）仍然逐轮要求。
		var hydrology_stride: int = 1
		if cp_now.get("runtime_hydrology_stride") != null:
			hydrology_stride = maxi(1, int(cp_now.runtime_hydrology_stride))
		if hydrology_stride <= 1:
			keys.append("runtime_hydrology_knobs")
	return keys

func _native_daily_required_pass_keys_array(cp_now) -> Array[String]:
	var out: Array[String] = []
	for key in _native_daily_required_pass_keys(cp_now):
		out.append(String(key))
	return out

func _native_daily_missing_required_pass_keys(bundle: Dictionary, required: PackedStringArray) -> PackedStringArray:
	var missing := PackedStringArray()
	for key in required:
		if not bundle.has(key):
			missing.append(key)
	return missing

func _native_daily_climate_round_state_snapshot() -> Dictionary:
	if _generator._refresh_climate_daily_job != null \
			and _generator._refresh_climate_daily_job.has_method("climate_round_state_snapshot"):
		return _generator._refresh_climate_daily_job.climate_round_state_snapshot()
	# On the native_daily path ClimateDailySystem is never registered, so there
	# is no GDScript pass cursor to report. Describe the native round instead;
	# returning "missing job" here used to make every consumer of this snapshot
	# conclude the Climate round had not completed.
	if _generator._native_daily_sim_job != null:
		return {
			"owner": "native_daily",
			"native_state_status": "native_daily_owner",
			"round_active": _generator.native_daily_round_active(),
			"finalize_pending": false,
			"pass_generation": _generator._native_daily_climate_round_generation,
			"pass_cursor": 1,
			"pass_count": 1,
		}
	return {
		"owner": "gdscript_retained",
		"native_state_status": "missing_refresh_climate_daily_job",
	}

func _native_daily_ocean_physical_state_snapshot() -> Dictionary:
	if _generator._ocean_currents_job != null \
			and _generator._ocean_currents_job.has_method("ocean_physical_state_snapshot"):
		return _generator._ocean_currents_job.ocean_physical_state_snapshot()
	return {
		"owner": "gdscript_retained",
		"native_state_status": "missing_ocean_currents_job",
	}

func _native_daily_season_refresh_state_snapshot() -> Dictionary:
	if _generator._season_refresh_job != null \
			and _generator._season_refresh_job.has_method("season_refresh_state_snapshot"):
		return _generator._season_refresh_job.season_refresh_state_snapshot()
	return {
		"owner": "gdscript_retained",
		"native_state_status": "missing_season_refresh_job",
	}

func _native_daily_weather_active_bootstrap_allowed(readiness: Dictionary) -> bool:
	var cp_now = _generator._c()
	if cp_now == null:
		return false
	if not _generator._native_mode_is_active(cp_now, "native_daily_sim_mode"):
		return false
	if cp_now.get("native_weather_transaction_active_owner_enabled") == null \
			or not bool(cp_now.native_weather_transaction_active_owner_enabled):
		return false
	return bool(readiness.get("has_knobs_builder", false)) \
			and bool(readiness.get("has_result_apply", false)) \
			and bool(readiness.get("has_weather_lut_publish", false)) \
			and _generator._weather_system != null \
			and _generator._sus_world != null \
			and _generator._weather_system.has_method("build_unified_fast_tick_weather_knobs")

func _native_daily_split_weather_node_enabled(cp_now) -> bool:
	return cp_now != null \
		and cp_now.get("native_daily_split_weather_node_enabled") != null \
		and bool(cp_now.native_daily_split_weather_node_enabled)

func _native_daily_weather_clock_values(default_phase: float) -> Dictionary:
	var clock = _generator._world_clock_ref
	var values := {"season_idx": 0, "anomaly": 0.0, "season_phase": default_phase}
	if clock == null:
		return values
	var capture = _generator._get_runtime_climate_capture()
	values["anomaly"] = capture.sample_anomaly()
	var date: int = capture.calendar_day
	if date >= 0:
		values["season_idx"] = clock.season_index_for_day(date)
		values["season_phase"] = clock.season_phase_for_day(date)
	else:
		if clock.has_method("season_index"):
			values["season_idx"] = clock.season_index()
		if clock.has_method("season_phase"):
			values["season_phase"] = clock.season_phase()
	return values

func _build_native_daily_weather_super_knobs(
		map: MapData,
		world: WorldData,
		phase_default: float,
		stage_b_knobs: Dictionary,
		runtime_hydrology_active: bool,
		commit_side_effects: bool) -> Dictionary:
	if _generator._weather_system == null or world == null \
			or not _generator._weather_system.has_method("build_unified_fast_tick_weather_knobs"):
		return {}
	var clock_values: Dictionary = _native_daily_weather_clock_values(phase_default)
	if commit_side_effects:
		_generator._weather_stage_b_call_index += 1
	if _generator._weather_system.has_method("set_weather_transition_dt_days"):
		_generator._weather_system.set_weather_transition_dt_days(_generator._consume_weather_dt_days() if commit_side_effects else 1.0)
	var weather_stage_b_knobs: Dictionary = {} if runtime_hydrology_active else stage_b_knobs
	var weather_super: Dictionary = _generator._weather_system.build_unified_fast_tick_weather_knobs(
		map,
		world,
		int(clock_values.get("season_idx", 0)),
		float(clock_values.get("anomaly", 0.0)),
		float(clock_values.get("season_phase", phase_default)),
		weather_stage_b_knobs
	)
	if not weather_super.is_empty():
		weather_super["native_daily_weather_stage_b_embedded"] = not runtime_hydrology_active \
			and not weather_stage_b_knobs.is_empty()
		return weather_super
	if commit_side_effects:
		_generator._weather_stage_b_call_index = maxi(0, _generator._weather_stage_b_call_index - 1)
	return {}

func _native_daily_boundary_contract(bundle: Dictionary, commit_side_effects: bool) -> Dictionary:
	var bootstrap_keys: Array[String] = []
	var tick_delta_keys: Array[String] = []
	for key in bundle.keys():
		var key_name: String = str(key)
		if key_name.ends_with("_state_snapshot") \
				or key_name == "weather_native_daily_readiness" \
				or key_name == "climate_round_active_owner_requested" \
				or key_name == "weather_transaction_active_owner_requested" \
				or key_name == "season_cadence_policy":
			bootstrap_keys.append(key_name)
		elif key_name.ends_with("_knobs") or key_name.ends_with("_struct"):
			tick_delta_keys.append(key_name)
	return {
		"schema_version": 1,
		"bootstrap_config_keys": bootstrap_keys,
		"tick_delta_keys": tick_delta_keys,
		"bundle_key_count": bundle.size(),
		"refresh_slots_from_map": bool(bundle.get("refresh_slots_from_map", true)),
		"flush_slots_to_map": bool(bundle.get("flush_slots_to_map", true)),
		"commit_side_effects": commit_side_effects,
		"refresh_policy": "tick_boundary",
		"flush_policy": "tick_boundary_or_visible_debug",
		"remaining_high_frequency_boundary": tick_delta_keys.size() > 0,
	}

func _native_daily_static_bundle_cache_key(map: MapData, cp_now) -> String:
	if map == null or cp_now == null:
		return ""
	var cfg_w: int = int(_generator._last_cfg.width) if _generator._last_cfg != null else 0
	var cfg_h: int = int(_generator._last_cfg.height) if _generator._last_cfg != null else 0
	var parts: PackedStringArray = PackedStringArray([
		str(map.soa_size()),
		str(cfg_w),
		str(cfg_h),
		str(cp_now.get_instance_id()),
		str(bool(cp_now.native_daily_legacy_daily_production_retired) if cp_now.get("native_daily_legacy_daily_production_retired") != null else false),
		str(bool(cp_now.native_climate_round_active_owner_enabled) if cp_now.get("native_climate_round_active_owner_enabled") != null else false),
		str(bool(cp_now.native_weather_transaction_active_owner_enabled) if cp_now.get("native_weather_transaction_active_owner_enabled") != null else false),
		str(bool(cp_now.native_season_refresh_active_owner_enabled) if cp_now.get("native_season_refresh_active_owner_enabled") != null else false),
		str(bool(cp_now.runtime_hydrology_enabled) if cp_now.get("runtime_hydrology_enabled") != null else false),
		str(_native_daily_split_weather_node_enabled(cp_now)),
	])
	return "|".join(parts)

func _build_native_daily_static_bundle_shell(map: MapData, cp_now) -> Dictionary:
	var climate_active: bool = cp_now.get("native_climate_round_active_owner_enabled") != null \
			and bool(cp_now.native_climate_round_active_owner_enabled)
	var refresh_keys := PackedStringArray()
	if climate_active:
		refresh_keys = PackedStringArray([
			"cell_terrain", "cell_base_terrain", "cell_is_water",
			"cell_landform", "cell_vegetation", "cell_cover",
			"cell_base_moisture",
		])
	var legacy_daily_retired: bool = cp_now.get("native_daily_legacy_daily_production_retired") != null \
			and bool(cp_now.native_daily_legacy_daily_production_retired)
	return {
		"refresh_slots_from_map": true,
		"refresh_slot_keys": refresh_keys,
		# Native pass wrappers already flush their published slots. A final bulk
		# flush walks every bound slot and was making ACTIVE native_daily cost ~8ms.
		"flush_slots_to_map": false,
		"climate_round_active_owner_requested": bool(cp_now.native_climate_round_active_owner_enabled) if cp_now.get("native_climate_round_active_owner_enabled") != null else false,
		"weather_transaction_active_owner_requested": bool(cp_now.native_weather_transaction_active_owner_enabled) if cp_now.get("native_weather_transaction_active_owner_enabled") != null else false,
		"season_refresh_active_owner_requested": bool(cp_now.native_season_refresh_active_owner_enabled) if cp_now.get("native_season_refresh_active_owner_enabled") != null else false,
		"runtime_hydrology_requested": bool(cp_now.runtime_hydrology_enabled) if cp_now.get("runtime_hydrology_enabled") != null else false,
		"legacy_sus_fallback_enabled": not legacy_daily_retired,
		"native_daily_legacy_daily_production_retired": legacy_daily_retired,
		"native_daily_split_weather_node_enabled": _native_daily_split_weather_node_enabled(cp_now),
		"use_system_schedule": true,
		"static_shell_cell_count": map.soa_size(),
	}

func _native_daily_get_static_bundle_shell(map: MapData, cp_now) -> Dictionary:
	var key: String = _native_daily_static_bundle_cache_key(map, cp_now)
	var hit: bool = key != "" and key == _generator._native_daily_static_bundle_cache_token \
			and not _generator._native_daily_static_bundle_cache.is_empty()
	if not hit:
		_generator._native_daily_static_bundle_cache_token = key
		_generator._native_daily_static_bundle_cache = _build_native_daily_static_bundle_shell(map, cp_now)
	return {
		"cache_hit": hit,
		"cache_key": key,
		"bundle": _generator._native_daily_static_bundle_cache.duplicate(),
	}

func _build_native_daily_bundle(
		ctx: SusTickContext,
		map: MapData,
		_world: WorldData,
		commit_side_effects: bool = false,
		sea_ice_dt_cap_days: float = 30.0,
		commit_sea_ice_side_effects: bool = true,
		defer_heavy_pass_knobs: bool = false) -> Dictionary:
	var t_bundle_us: int = Time.get_ticks_usec()
	var cp_now = _generator._c()
	if map == null or cp_now == null:
		return {}
	var t_static_us: int = Time.get_ticks_usec()
	var shell_report: Dictionary = _native_daily_get_static_bundle_shell(map, cp_now)
	var bundle: Dictionary = shell_report.get("bundle", {})
	var bundle_cache_hit: bool = bool(shell_report.get("cache_hit", false))
	var bundle_static_ms: float = float(Time.get_ticks_usec() - t_static_us) / 1000.0
	bundle["climate_round_state_snapshot"] = _native_daily_climate_round_state_snapshot()
	bundle["ocean_physical_state_snapshot"] = _native_daily_ocean_physical_state_snapshot()
	bundle["season_refresh_state_snapshot"] = _native_daily_season_refresh_state_snapshot()
	# Phase C.1（dots-total-cpp roadmap）：System schedule graph 双轨入口。
	# dots-flag-prune-pr1 (2026-05-22)：use_gdext_system_schedule flag 已删除，
	# C++ 端 run_native_daily_tick 现恒走 system_schedule.cpp 的
	# dispatch_system_schedule loop。输出 dict（breakdown / fronts / succession_*）
	# 必须 bit-equal（dots_soak_ab_runner SAME_SOURCE 1000-tick A/B 验收）。
	# 任意节点失败 → C++ 端 finish_with_failure 短路返回 rc=-1。ACTIVE
	# hot path 由 _generator.run_native_daily_slice_from_job 处理；full-run helper 仅供
	# debug/probe 使用。
	var pass_a_struct: Dictionary = _build_native_daily_climate_pass_a_struct(map, cp_now, ctx.season_phase)
	if not pass_a_struct.is_empty():
		bundle["climate_pass_a_struct"] = pass_a_struct
	if defer_heavy_pass_knobs:
		# Sea-ice, wind and transpiration are sensitive to the exact in-round
		# temperature/transport snapshots. Keep the conservative JIT boundaries until
		# SAME_SOURCE proves a narrower list is climate-bit-equal across seasons.
		var deferred_nodes: PackedInt32Array = PackedInt32Array([1, 2, 4, 6, 7])
		var weather_split_enabled: bool = _native_daily_split_weather_node_enabled(cp_now)
		var native_weather_readiness: Dictionary = _generator.weather_native_daily_readiness_report()
		var native_weather_active_bootstrap: bool = _native_daily_weather_active_bootstrap_allowed(native_weather_readiness)
		if native_weather_active_bootstrap and not bool(native_weather_readiness.get("ready", false)):
			native_weather_readiness["ready"] = true
			native_weather_readiness["reason"] = "active_bootstrap_unified_publish"
			native_weather_readiness["active_bootstrap_requested"] = true
		bundle["weather_native_daily_readiness"] = native_weather_readiness.duplicate()
		var native_weather_daily_allowed: bool = bool(native_weather_readiness.get("ready", false)) \
				or native_weather_active_bootstrap
		var runtime_hydrology_active: bool = cp_now.get("runtime_hydrology_enabled") != null \
				and bool(cp_now.runtime_hydrology_enabled)
		if native_weather_daily_allowed and _generator._weather_system != null and _world != null \
				and _generator._weather_system.has_method("build_unified_fast_tick_weather_knobs"):
			var stage_b_knobs_prebuilt: Dictionary = _build_native_daily_stage_b_knobs(
				map,
				cp_now,
				maxi(0, _generator._weather_stage_b_call_index),
				float(_generator._native_daily_contract_stride_days())
			)
			var weather_super_prebuilt: Dictionary = _build_native_daily_weather_super_knobs(
				map,
				_world,
				ctx.season_phase,
				stage_b_knobs_prebuilt,
				runtime_hydrology_active,
				commit_side_effects
			)
			if not weather_super_prebuilt.is_empty():
				bundle["weather_knobs"] = weather_super_prebuilt
				bundle["weather_knobs_prebuilt"] = true
			deferred_nodes.append(12)
			if runtime_hydrology_active:
				deferred_nodes.append(19)
				deferred_nodes.append(20)
			elif not weather_split_enabled:
				deferred_nodes.append(11)
		elif _generator._weather_system != null and _world != null and not native_weather_daily_allowed:
			bundle["weather_native_daily_blocked"] = true
			bundle["weather_native_daily_block_reason"] = str(native_weather_readiness.get("reason", "not_ready"))
			if not runtime_hydrology_active:
				deferred_nodes.append(11)
		bundle["season_cadence_policy"] = _native_daily_season_cadence_policy(
			cp_now,
			maxi(0, _generator._weather_stage_b_call_index)
		)
		bundle["native_daily_deferred_nodes"] = deferred_nodes
		bundle["deferred_node_count"] = deferred_nodes.size()
		bundle["bundle_cache_hit"] = bundle_cache_hit
		bundle["bundle_cache_rebuild_reason"] = "static_shell_hit" if bundle_cache_hit else "static_shell_rebuild"
		bundle["bundle_static_ms"] = bundle_static_ms
		bundle["bundle_dynamic_ms"] = maxf(0.0, float(Time.get_ticks_usec() - t_bundle_us) / 1000.0 - bundle_static_ms)
		bundle["native_daily_boundary_contract"] = _native_daily_boundary_contract(bundle, commit_side_effects)
		return bundle
	var pass_b_knobs: Dictionary = _build_native_daily_climate_pass_b_knobs(map, cp_now, ctx.season_phase)
	if not pass_b_knobs.is_empty():
		bundle["climate_pass_b_knobs"] = pass_b_knobs
	var transp_knobs: Dictionary = _build_native_daily_transpiration_knobs(map, cp_now)
	if not transp_knobs.is_empty():
		bundle["transpiration_knobs"] = transp_knobs
	var ocean_knobs: Dictionary = _build_native_daily_ocean_knobs(map, cp_now, ctx.season_phase)
	if not ocean_knobs.is_empty():
		bundle["ocean_water_knobs"] = ocean_knobs.get("water", {})
		bundle["ocean_land_knobs"] = ocean_knobs.get("land", {})
	var wind_knobs: Dictionary = _build_native_daily_wind_knobs(map, cp_now)
	if not wind_knobs.is_empty():
		bundle["wind_air_knobs"] = wind_knobs.get("air", {})
		bundle["wind_surface_knobs"] = wind_knobs.get("surface", {})
	var sea_ice_knobs: Dictionary = _build_native_daily_sea_ice_knobs(
		map,
		cp_now,
		ctx.season_phase,
		commit_side_effects and commit_sea_ice_side_effects,
		sea_ice_dt_cap_days)
	if not sea_ice_knobs.is_empty():
		bundle["sea_ice_knobs"] = sea_ice_knobs
	# Phase A.2 unified fast tick: dots-flag-prune-pr1 round 2 (2026-05-22):
	# use_gdext_unified_fast_tick / use_gdext_weather_refresh_daily flag 均已删除——
	# weather refresh daily 的 4 组 super_knobs（field/distribute/summary + stage_b
	# 平铺）现恒嵌入 bundle，仅受 ext + has_method 探测控制。任意前置不满足
	# （weather_system null / fast_indexed 缺失）自动返回空 dict，此时 bundle 不含
	# weather_knobs，C++ 端短路跳过 weather 段——bit-equal 兜底。
	var stage_b_knobs: Dictionary = _build_native_daily_stage_b_knobs(
		map,
		cp_now,
		maxi(0, _generator._weather_stage_b_call_index),
		float(_generator._native_daily_contract_stride_days())
	)
	bundle["season_cadence_policy"] = _native_daily_season_cadence_policy(
		cp_now,
		maxi(0, _generator._weather_stage_b_call_index)
	)
	var stage_b_embedded_in_weather: bool = false
	var native_weather_readiness: Dictionary = _generator.weather_native_daily_readiness_report()
	var native_weather_active_bootstrap: bool = _native_daily_weather_active_bootstrap_allowed(native_weather_readiness)
	if native_weather_active_bootstrap and not bool(native_weather_readiness.get("ready", false)):
		native_weather_readiness["ready"] = true
		native_weather_readiness["reason"] = "active_bootstrap_unified_publish"
		native_weather_readiness["active_bootstrap_requested"] = true
	bundle["weather_native_daily_readiness"] = native_weather_readiness.duplicate()
	var native_weather_daily_allowed: bool = bool(native_weather_readiness.get("ready", false)) \
			or native_weather_active_bootstrap
	var runtime_hydrology_active: bool = cp_now.get("runtime_hydrology_enabled") != null \
			and bool(cp_now.runtime_hydrology_enabled)
	# runtime_hydrology_stride 此前在 ClimateProfile 里声明但全库无引用，也就是说
	# 无论配成几，水文都跟着每个 weather 轮跑。按 stage_b 三件套的同一套模式接线：
	# 计数器只在真实 tick 的 weather 到期轮推进，probe（commit_side_effects=false）
	# 不许动它，否则 readiness 探测会把节拍带偏。
	var runtime_hydrology_stride: int = 1
	if cp_now.get("runtime_hydrology_stride") != null:
		runtime_hydrology_stride = maxi(1, int(cp_now.runtime_hydrology_stride))
	var runtime_hydrology_due: bool = true
	if runtime_hydrology_active and runtime_hydrology_stride > 1:
		if commit_side_effects:
			_generator._native_daily_hydrology_call_index += 1
		runtime_hydrology_due = (_generator._native_daily_hydrology_call_index % runtime_hydrology_stride) == 0
	var runtime_hydrology_knobs: Dictionary = {}
	if runtime_hydrology_due:
		runtime_hydrology_knobs = _build_native_daily_runtime_hydrology_knobs(
			map,
			cp_now,
			float(_generator._native_daily_contract_stride_days()) if commit_side_effects else 1.0
		)
	if _generator._weather_system != null and _world != null \
			and native_weather_daily_allowed \
			and _generator._weather_system.has_method("build_unified_fast_tick_weather_knobs"):
		var weather_super: Dictionary = _build_native_daily_weather_super_knobs(
			map,
			_world,
			ctx.season_phase,
			stage_b_knobs,
			runtime_hydrology_active,
			commit_side_effects
		)
		if not weather_super.is_empty():
			bundle["weather_knobs"] = weather_super
			bundle["weather_knobs_prebuilt"] = false
			stage_b_embedded_in_weather = not runtime_hydrology_active
	elif _generator._weather_system != null and _world != null and not native_weather_daily_allowed:
		bundle["weather_native_daily_blocked"] = true
		bundle["weather_native_daily_block_reason"] = str(native_weather_readiness.get("reason", "not_ready"))
	if runtime_hydrology_active and not runtime_hydrology_knobs.is_empty():
		bundle["runtime_hydrology_knobs"] = runtime_hydrology_knobs
	if runtime_hydrology_active and not stage_b_knobs.is_empty():
		bundle["stage_b_after_hydrology_knobs"] = stage_b_knobs
	elif not stage_b_embedded_in_weather and not stage_b_knobs.is_empty():
		bundle["stage_b_knobs"] = stage_b_knobs
	bundle["deferred_node_count"] = 0
	bundle["bundle_cache_hit"] = bundle_cache_hit
	bundle["bundle_cache_rebuild_reason"] = "static_shell_hit" if bundle_cache_hit else "static_shell_rebuild"
	bundle["bundle_static_ms"] = bundle_static_ms
	bundle["bundle_dynamic_ms"] = maxf(0.0, float(Time.get_ticks_usec() - t_bundle_us) / 1000.0 - bundle_static_ms)
	bundle["native_daily_boundary_contract"] = _native_daily_boundary_contract(bundle, commit_side_effects)
	return bundle

func _merge_native_daily_slice_patch_local(patch: Dictionary) -> void:
	if patch.is_empty():
		return
	for key in patch.keys():
		_generator._native_daily_slice_active_bundle[key] = patch[key]
	_generator._native_daily_slice_bundle_pass_keys = _native_daily_bundle_pass_keys(_generator._native_daily_slice_active_bundle)

# Slice-graph node indices that MUST receive a just-in-time knob patch before they run,
# because running them with the round-start knobs would diverge. Empirically minimized
# (tmp_native_batch_bitequal_test.gd, 40-round soak): only `ocean_water` (2) and
# `sea_ice` (6) need a repack. ocean reads temp_before from map.temp_arr (which the
# per-slice apply flushes post-pass_a/pass_b — NOT the raw cell_temp slot, so a C++
# slot-read is not bit-equal and was reverted); sea_ice picks up the post-ocean
# transport anomaly. `climate_pass_b` (1), `wind_air` (4) and `transpiration` (7) read
# their dynamic inputs straight from C++ slots (or use cached/static knobs), so their
# round-start knobs already match — yielding before them was pure redundant
# GDScript<->C++ round-trip. MUST stay in sync with the `match next_node_index` cases in
# _build_native_daily_slice_bundle_patch below. Passed to C++ as
# native_daily_slice_yield_nodes; C++ batches every other consecutive node into one call
# (bit-equal). Trims ~9.1 round-trips/round down to ~3.
const _NATIVE_DAILY_SLICE_YIELD_NODES: Array[int] = [2, 6]

# Spread mode (native_daily_spread_across_ticks) wants the OPPOSITE of atomic batching:
# maximize yield granularity so each tick runs the smallest possible batch → lowest
# per-tick peak (mean 3.14→1.95ms in spread-validate). Yielding more nodes is purely
# bit-equal — it only adds C++<->GDScript checkpoints; the round-start bundle knobs
# already satisfy every non-patched node, so no JIT repack is needed (the {2,6}/sea_ice
# patches still fire on those indices). Covers all 21 NATIVE_DAILY_SLICE_GRAPH nodes
# (world_ext_daily_sim.cpp); C++ skips indices whose bundle knobs are absent on a given
# day, so a typical round lands in ~5 ticks, not 21. Trade-off vs atomic: a sim-day now
# spans ~5 ticks at maxslices=1 (sim advance ~2.5x slower), which the spread design
# explicitly accepts.
const _NATIVE_DAILY_SLICE_YIELD_NODES_SPREAD: Array[int] = [
	0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
	11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
]

# Coarse spread keeps the slice round budgeted across ticks, but removes pure checkpoint
# nodes that do not need GDScript patching. Weather split subnodes remain inside the same
# C++ call unless another dynamic boundary is needed.
const _NATIVE_DAILY_SLICE_YIELD_NODES_SPREAD_COARSE: Array[int] = [2, 6, 12, 19, 20]

# Pick the slice yield set for the current cadence mode: spread → max granularity
# (lowest per-tick peak), atomic → coarse {2,6} batching (fewest round-trips/round).

func _native_daily_effective_yield_nodes(cp) -> PackedInt32Array:
	var spread: bool = cp != null and cp.get("native_daily_spread_across_ticks") != null \
		and bool(cp.native_daily_spread_across_ticks)
	var coarse_spread: bool = spread \
			and cp != null \
			and cp.get("native_daily_coarse_spread_yield_enabled") != null \
			and bool(cp.native_daily_coarse_spread_yield_enabled)
	var nodes: Array[int] = []
	if coarse_spread:
		nodes = _NATIVE_DAILY_SLICE_YIELD_NODES_SPREAD_COARSE.duplicate()
	elif spread:
		nodes = _NATIVE_DAILY_SLICE_YIELD_NODES_SPREAD.duplicate()
	else:
		nodes = _NATIVE_DAILY_SLICE_YIELD_NODES.duplicate()
	if _native_daily_split_weather_node_enabled(cp) and not coarse_spread:
		for idx in [13, 14, 15, 16, 17, 18]:
			if not nodes.has(idx):
				nodes.append(idx)
	return PackedInt32Array(nodes)

func _native_daily_sea_ice_dt_cap_days(cp) -> float:
	if cp != null and cp.get("native_daily_spread_across_ticks") != null \
			and bool(cp.native_daily_spread_across_ticks):
		return clampf(
			float(cp.native_daily_sea_ice_spread_dt_cap_days) \
					if cp.get("native_daily_sea_ice_spread_dt_cap_days") != null else 2.0,
			1.0,
			30.0
		)
	return 1.0

func _build_native_daily_slice_bundle_patch(
		next_node_index: int,
		ctx: SusTickContext,
		map: MapData,
		world: WorldData) -> Dictionary:
	var cp_now = _generator._c()
	if map == null or cp_now == null:
		return {}
	var patch: Dictionary = {}
	var phase_locked: float = _generator._native_daily_slice_phase_locked
	match next_node_index:
		1:
			var pass_b_knobs: Dictionary = _build_native_daily_climate_pass_b_knobs(map, cp_now, phase_locked)
			patch["climate_pass_b_knobs"] = pass_b_knobs
		2:
			var ocean_knobs: Dictionary = _build_native_daily_ocean_knobs(map, cp_now, phase_locked)
			if not ocean_knobs.is_empty():
				patch["ocean_water_knobs"] = ocean_knobs.get("water", {})
				patch["ocean_land_knobs"] = ocean_knobs.get("land", {})
			else:
				patch["ocean_water_knobs"] = {}
				patch["ocean_land_knobs"] = {}
		4:
			var wind_knobs: Dictionary = _build_native_daily_wind_knobs(map, cp_now)
			if not wind_knobs.is_empty():
				patch["wind_air_knobs"] = wind_knobs.get("air", {})
				patch["wind_surface_knobs"] = wind_knobs.get("surface", {})
			else:
				patch["wind_air_knobs"] = {}
				patch["wind_surface_knobs"] = {}
		6:
			var sea_ice_knobs: Dictionary = _build_native_daily_sea_ice_knobs(
				map,
				cp_now,
				phase_locked,
				true,
				_native_daily_sea_ice_dt_cap_days(cp_now))
			patch["sea_ice_knobs"] = sea_ice_knobs
		7:
			var transp_knobs: Dictionary = _build_native_daily_transpiration_knobs(map, cp_now)
			patch["transpiration_knobs"] = transp_knobs
		11:
			var stage_b_knobs: Dictionary = _build_native_daily_stage_b_knobs(
				map,
				cp_now,
				maxi(0, _generator._weather_stage_b_call_index),
				float(_generator._native_daily_contract_stride_days())
			)
			patch["stage_b_knobs"] = stage_b_knobs
		12:
			if _generator._native_daily_slice_active_bundle.has("weather_knobs"):
				return patch
			var native_weather_readiness: Dictionary = _generator.weather_native_daily_readiness_report()
			var native_weather_active_bootstrap: bool = _native_daily_weather_active_bootstrap_allowed(native_weather_readiness)
			if native_weather_active_bootstrap and not bool(native_weather_readiness.get("ready", false)):
				native_weather_readiness["ready"] = true
				native_weather_readiness["reason"] = "active_bootstrap_unified_publish"
				native_weather_readiness["active_bootstrap_requested"] = true
			var native_weather_daily_allowed: bool = bool(native_weather_readiness.get("ready", false)) \
					or native_weather_active_bootstrap
			var runtime_hydrology_active: bool = cp_now.get("runtime_hydrology_enabled") != null \
					and bool(cp_now.runtime_hydrology_enabled)
			if _generator._weather_system != null and world != null \
					and native_weather_daily_allowed \
					and _generator._weather_system.has_method("build_unified_fast_tick_weather_knobs"):
				var stage_b_knobs_for_weather: Dictionary = _build_native_daily_stage_b_knobs(
					map,
					cp_now,
					maxi(0, _generator._weather_stage_b_call_index),
					float(_generator._native_daily_contract_stride_days())
				)
				var weather_super: Dictionary = _build_native_daily_weather_super_knobs(
					map,
					world,
					phase_locked,
					stage_b_knobs_for_weather,
					runtime_hydrology_active,
					true
				)
				if not weather_super.is_empty():
					patch["weather_knobs"] = weather_super
					if not runtime_hydrology_active and not stage_b_knobs_for_weather.is_empty():
						# Weather embeds stage_b in this mode; keep no standalone node patch.
						pass
				else:
					patch["weather_knobs"] = {}
			else:
				patch["weather_knobs"] = {}
		19:
			var runtime_hydrology_knobs: Dictionary = _build_native_daily_runtime_hydrology_knobs(
				map,
				cp_now,
				float(_generator._native_daily_contract_stride_days())
			)
			patch["runtime_hydrology_knobs"] = runtime_hydrology_knobs
		20:
			var stage_b_after_hydrology_knobs: Dictionary = _build_native_daily_stage_b_knobs(
				map,
				cp_now,
				maxi(0, _generator._weather_stage_b_call_index),
				float(_generator._native_daily_contract_stride_days())
			)
			patch["stage_b_after_hydrology_knobs"] = stage_b_after_hydrology_knobs
	return patch

func _native_daily_bundle_pass_keys(bundle: Dictionary) -> Array[String]:
	var keys: Array[String] = []
	for k in bundle.keys():
		var s: String = str(k)
		if s.ends_with("_knobs") or s == "climate_pass_a_struct":
			keys.append(s)
	keys.sort()
	return keys
