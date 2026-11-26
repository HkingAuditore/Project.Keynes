extends "res://scripts/simulation/generator_context.gd"

const RuntimeSystemRegistration = preload("res://scripts/game/map_runtime_system_registration.gd")

const InlineEconomyPulse = preload("res://scripts/game/inline_economy_pulse.gd")

const InlineEconomyTiming = preload("res://scripts/game/inline_economy_timing.gd")

const EconomyTestBootstrapScript = preload("res://scripts/economy/economy_test_bootstrap.gd")
const IdeologyFacadeScript = preload("res://scripts/ideology/ideology_facade.gd")
var _main_steps = preload("res://scripts/game/runtime_main_step_diagnostics.gd").new()
var measure_map_lut_copies := false

## 第 5 批：保存边界、停止清理与 worker 控制。可变状态仍由 MapGenerator 持有。

func set_runtime_interactive(interactive: bool) -> void:
	# QoS is a native executor hint only. It never changes simulation order or
	# authority; the next native group observes the reduced permit count.
	if _generator._data_core_world_ext != null:
		_generator._data_core_world_ext.set_runtime_qos(interactive)


func set_runtime_qos_threaded(interactive: bool) -> Dictionary:
	if _generator._data_core_world_ext == null:
		return {"ok": false, "code": "runtime_worker_api_missing"}
	return _generator._data_core_world_ext.set_runtime_qos_threaded(interactive)

func get_runtime_thread_report() -> Dictionary:
	if _generator._data_core_world_ext == null:
		return {}
	var report: Dictionary = _generator._data_core_world_ext.get_runtime_thread_report()
	report["main_simulation_steps_by_day"] = _main_steps.snapshot(_generator._sus_map)
	return report


func record_runtime_main_step(day: int, step: StringName) -> void:
	_main_steps.record(_generator._sus_map, day, step)


func get_runtime_control_state() -> Dictionary:
	if _generator._data_core_world_ext == null:
		return _generator.get_runtime_thread_report()
	if _generator._data_core_world_ext.has_method("get_runtime_control_state"):
		return _generator._data_core_world_ext.get_runtime_control_state()
	return _generator.get_runtime_thread_report()


## WorldRuntimeHost probes the generator, not DCWorldExt, for the ACTIVE
## write-backs that refresh the legacy facades. The Trigger facade feeds the
## main-thread Trigger -> Effect handoff, so a missing forwarder here means no
## worker-fired trigger (e.g. development signals) ever takes effect.
## Modifier and Effect were previously omitted because applying both together
## crashed (~100 ACTIVE days); the native apply paths now copy the POD snapshot
## out of the ring and preserve Economy-owned colonization builtins across
## Effect write-back.

func record_runtime_visual_timings(ui_input_to_feedback_ms: float,
		visual_apply_ms: float, gpu_upload_ms: float) -> Dictionary:
	if _generator._data_core_world_ext == null:
		return {"ok": false, "code": "runtime_worker_api_missing"}
	return _generator._data_core_world_ext.record_runtime_visual_timings(
		ui_input_to_feedback_ms, visual_apply_ms, gpu_upload_ms)


func start_runtime_worker(config: Dictionary) -> Dictionary:
	if _generator._data_core_world_ext == null:
		return {"ok": false, "code": "runtime_worker_api_missing"}
	return _generator._data_core_world_ext.start_runtime_worker(config)


func poll_runtime_events_snapshot(after_generation: int = 0) -> Dictionary:
	if _generator._data_core_world_ext == null:
		return {"ok": false, "available": false, "fallback": true,
			"reason": "runtime_events_snapshot_api_missing"}
	return _generator._data_core_world_ext.poll_runtime_events_snapshot(after_generation)


func set_runtime_clock_threaded(paused: bool, speed_days_per_second: float) -> Dictionary:
	if _generator._data_core_world_ext == null:
		return {"ok": false, "code": "runtime_worker_api_missing"}
	return _generator._data_core_world_ext.set_runtime_clock(paused, speed_days_per_second)


func capture_runtime_inputs(inputs: Dictionary) -> Dictionary:
	if _generator._data_core_world_ext == null:
		return {"ok": false, "code": "runtime_worker_api_missing"}
	return _generator._data_core_world_ext.capture_runtime_inputs(inputs)


## Captures the complete Country POD input only after Country and Economy
## bootstrap/restore have settled.  This is a diagnostics/SHADOW boundary;
## it must not be called before starter settlements or PKCN restore is done.

func capture_country_worker_inputs() -> Dictionary:
	var country = _generator._country_facade
	if country == null or country.world_ext() == null:
		return {"ok": false, "code": "runtime_worker_api_missing"}
	if not country.is_configured():
		return {"ok": false, "code": "country_runtime_unavailable"}
	var catalog: Dictionary = country.capture_worker_pod_catalog()
	if not bool(catalog.get("ok", false)):
		return {"ok": false, "code": String(catalog.get("code", "country_catalog_capture_failed")),
			"catalog": catalog}
	var snapshot: Dictionary = country.capture_worker_runtime_snapshot()
	if not bool(snapshot.get("ok", false)):
		return {"ok": false, "code": String(snapshot.get("code", "country_snapshot_capture_failed")),
			"catalog": catalog, "snapshot": snapshot}
	return {"ok": true, "code": "ok", "catalog": catalog, "snapshot": snapshot,
		"generation": int(snapshot.get("generation", 0)),
		"state_hash": int(snapshot.get("state_hash", 0))}


## Pulls one immutable Country worker read view.  The host owns the cursor and
## applies the returned sparse territory patch; this wrapper deliberately does
## not expose the worker store or retain references to native vectors.

func get_country_worker_read_view(after_generation: int = 0) -> Dictionary:
	if _generator._country_facade == null or _generator._country_facade.world_ext() == null:
		return {"ok": false, "code": "country_worker_read_view_api_missing"}
	return _generator._country_facade.worker_read_view(after_generation)


func service_country_worker_peer_adapter(max_intents: int = 64,
		shadow_replay: bool = true) -> Dictionary:
	if _generator._country_facade == null or _generator._country_facade.world_ext() == null:
		return {"ok": false, "code": "country_worker_adapter_api_missing"}
	return _generator._country_facade.service_worker_peer_adapter(max_intents, shadow_replay)


## Country -> Economy typed transport. These methods only move immutable
## request/result dictionaries across the GDExtension boundary; they do not
## read or mutate the worker's Economy state. The real Economy adapter is a
## later K2-B continuation and must use this queue rather than a direct store
## call when Country eventually becomes ACTIVE.

func get_country_economy_asset_protocol_status() -> Dictionary:
	if _generator._country_facade == null or _generator._country_facade.world_ext() == null:
		return {"ok": false, "code": "country_economy_asset_protocol_api_missing"}
	return _generator._country_facade.economy_asset_protocol_status()


func poll_country_economy_asset_request() -> Dictionary:
	if _generator._country_facade == null or _generator._country_facade.world_ext() == null:
		return {"ok": false, "code": "country_economy_asset_protocol_api_missing"}
	return _generator._country_facade.poll_economy_asset_request()


func submit_country_economy_asset_result(result: Dictionary) -> Dictionary:
	if _generator._country_facade == null or _generator._country_facade.world_ext() == null:
		return {"ok": false, "code": "country_economy_asset_protocol_api_missing"}
	return _generator._country_facade.submit_economy_asset_result(result)


func submit_runtime_command(command: Dictionary) -> Dictionary:
	if _generator._data_core_world_ext == null:
		return {"ok": false, "code": "runtime_worker_api_missing"}
	return _generator._data_core_world_ext.submit_runtime_command(command)


func poll_runtime_commit(after_generation: int = 0, take_days: bool = false) -> Dictionary:
	if _generator._data_core_world_ext == null:
		return {"ok": false, "code": "runtime_worker_api_missing"}
	return _generator._data_core_world_ext.poll_runtime_commit(after_generation, take_days)


func read_runtime_map_lut_frame(map: MapData, day: int, generation: int) -> Dictionary:
	var ext = _generator._data_core_world_ext
	if ext == null:
		return {"reason": "map_lut_extension_unavailable"}
	if map == null:
		return {"reason": "map_lut_map_unavailable"}
	var frame: Dictionary = ext.read_runtime_map_lut_frame(
		map, day, generation, map.cell_count(), measure_map_lut_copies)
	return {"reason": "map_lut_publication_unavailable"} if frame.is_empty() else frame


func clear_runtime_map_lut_frame() -> void:
	var ext = _generator._data_core_world_ext
	if ext != null:
		ext.clear_runtime_map_lut_frame()


func request_runtime_save(request_id: int) -> Dictionary:
	if _generator._data_core_world_ext == null:
		return {"ok": false, "code": "runtime_worker_api_missing"}
	# P1：存盘准入要求 ring 排空（`!has_pending_climate_input()`），而预发布会让
	# ring 长期非空。先让 host 把 K 降到 0、停掉新帧；环里的未来帧由 worker 侧
	# 在存盘准入处丢弃（PKSR 不保存 pending environment）。
	return _generator._data_core_world_ext.request_runtime_save(request_id)


func poll_runtime_save(request_id: int) -> Dictionary:
	if _generator._data_core_world_ext == null:
		return {"ok": false, "code": "runtime_worker_api_missing"}
	return _generator._data_core_world_ext.poll_runtime_save(request_id)


func restore_runtime_bundle(bytes: PackedByteArray,
		external_ecp2: PackedByteArray = PackedByteArray()) -> Dictionary:
	if _generator._data_core_world_ext == null:
		return {"ok": false, "code": "runtime_worker_api_missing"}
	return _generator._data_core_world_ext.restore_runtime_bundle(bytes, external_ecp2)


func request_runtime_stop(preserve_day_boundary: bool = false) -> Dictionary:
	if _generator._data_core_world_ext == null:
		return {"ok": true, "state": "STOPPED"}
	return _generator._data_core_world_ext.request_runtime_stop(preserve_day_boundary)


# 由 main.gd 每日按录制器状态推送。关闭时经济 slice 走 compact 报告。

func set_economy_diagnostics_enabled(enabled: bool) -> void:
	if _generator._economy_daily_job != null:
		_generator._economy_daily_job.diagnostics_enabled = enabled


func set_test_economy_bootstrap_enabled(enabled: bool) -> void:
	_generator._test_economy_bootstrap_enabled = enabled


func set_test_economy_population_scale(scale: int) -> void:
	_generator._test_economy_population_scale = scale \
		if scale in EconomyTestBootstrapScript.SUPPORTED_POPULATION_SCALES \
		else EconomyTestBootstrapScript.DEFAULT_POPULATION_SCALE


func set_save_restore_preparation_enabled(enabled: bool) -> void:
	_generator._save_restore_preparation_enabled = enabled


func prepare_economy_save_restore_runtime() -> Dictionary:
	if not _generator._save_restore_preparation_enabled:
		return {"ok": false, "reason": "save_restore_preparation_not_enabled"}
	if _generator._country_facade == null or not bool(
			_generator._country_facade.report().get("bootstrapped", false)):
		return {"ok": false, "reason": "country_restore_incomplete"}
	if _generator._economy_facade != null:
		return {"ok": false, "reason": "economy_restore_already_prepared"}
	var configured: Dictionary = _generator._get_map_country_initializer()._configure_economy_runtime(_generator._sus_map, _generator._save_restore_seed)
	if bool(configured.get("ok", false)):
		var ideology_facade := IdeologyFacadeScript.new()
		var ideology_configured: Dictionary = ideology_facade.configure(
			_generator._data_core_world_ext, _generator._country_facade.native_catalog(), null,
			_generator._economy_facade.native_catalog(), _generator._save_restore_seed)
		if not bool(ideology_configured.get("ok", false)):
			return ideology_configured
		_generator._ideology_facade = ideology_facade
		# Player handles arrive with PKSV pkai (or the legacy fallback); until
		# then the native AI stays unarmed.
		_generator._get_map_country_initializer()._configure_country_ai(_generator._sus_map, _generator._save_restore_seed, PackedInt64Array())
		# PKMI is the next provider, before ECP2. It needs its catalog and map
		# shape now; settlement tiers are refreshed after ECP2 restores below.
		_generator._get_map_country_initializer()._configure_military_runtime(_generator._sus_map, null, _generator._save_restore_seed)
		print("[save/restore] PKCN restored; economy configured and awaiting PKEC")
	return configured


func finalize_save_restore_runtime() -> Dictionary:
	if not _generator._save_restore_preparation_enabled:
		return {"ok": false, "reason": "save_restore_preparation_not_enabled"}
	if _generator._country_facade == null or _generator._economy_facade == null:
		return {"ok": false, "reason": "country_economy_runtime_unavailable"}
	var country_report: Dictionary = _generator._country_facade.report()
	var economy_report: Dictionary = _generator._economy_facade.report()
	if not bool(country_report.get("bootstrapped", false)):
		return {"ok": false, "reason": "country_restore_incomplete"}
	if not bool(economy_report.get("bootstrapped", false)):
		return {"ok": false, "reason": "economy_restore_incomplete"}
	# Geography restored the landform column into MapData after the native map
	# was bound. The first climate round reads the native slot.
	_generator._data_core_world_ext.refresh_slots_from_map_keys(PackedStringArray(["cell_landform"]))
	var trade_topology: Dictionary = _generator._get_map_country_initializer()._capture_economy_trade_topology(_generator._sus_map)
	if not bool(trade_topology.get("ok", false)):
		return trade_topology
	var registered: Dictionary = _generator._get_map_rules_initializer()._register_country_economy_systems(_generator._c())
	if not bool(registered.get("ok", false)):
		return registered
	# PKMI has already restored. Updating the bound map's terrain in place
	# keeps the restored armies, orders and AI state.
	if _generator._military_facade != null and _generator._military_facade.is_configured():
		var terrain: Dictionary = _generator._military_facade.set_terrain(_generator._sus_map, -1, true,
			_generator._get_map_country_initializer()._military_settlement_tiers(_generator._sus_map))
		if not bool(terrain.get("ok", false)):
			return {"ok": false, "reason": "military_restore_terrain_failed"}
	else:
		# Keep a fallback for restore paths whose preparation did not produce a
		# configured facade. A successful configure is safe here because no PKMI
		# state was installed into the facade in that path.
		_generator._get_map_country_initializer()._configure_military_runtime(
			_generator._sus_map, null, _generator._save_restore_seed)
	_generator._get_map_country_initializer()._maybe_register_military_system()
	if not _generator._runtime_build_topology("save restore finalize"):
		return {"ok": false, "reason": "save_restore_scheduler_topology_failed"}
	_generator._save_restore_preparation_enabled = false
	_generator._gameplay_start_report["country_count"] = int(country_report.get("country_count", 0))
	_generator._gameplay_start_report["settlement_source"] = "save_restore"
	print("[save/restore] PKCN and PKEC restored; country/economy systems registered")
	return {"ok": true}


func _ensure_continuation_perf_pending() -> void:
	InlineEconomyTiming._ensure_continuation_perf_pending(self)


func _record_continuation_slice(source: String, result: Dictionary, wall_ms: float) -> float:
	return InlineEconomyTiming._record_continuation_slice(self, source, result, wall_ms)


func _finish_continuation_perf_frame(started_us: int, frame_slices: int,
		frame_max_slice_ms: float, budget_ms: float) -> void:
	InlineEconomyTiming._finish_continuation_perf_frame(self, started_us, frame_slices, frame_max_slice_ms, budget_ms)


## [continuation-reentry-guard 2026-11-03] 带符号引擎的 backtrace 显示真机崩溃是
## 一次约 500 帧的 GDScript 递归，三帧循环是
##   GDScriptFunction::call → GDScript::callp → Variant::callp
## 也就是"脚本函数里再调用脚本函数"的无限自调用。最可疑的环就在这条链上：
## WorldClock 发 `simulation_backpressure_pulse` → 本回调推进 native graph pulse →
## 同一调用链里若再次发 pulse，就会无限重入。
## 这里用重入闩把环切断：正常路径不会重入，一旦重入就打印并返回。

func _continue_economy_inflight(day_index: int) -> void:
	InlineEconomyPulse._continue_economy_inflight(self, day_index)


func _continue_economy_inflight_impl(day_index: int) -> void:
	InlineEconomyPulse._continue_economy_inflight_impl(self, day_index)


func _advance_runtime_graph_pulse(day_index: int) -> Dictionary:
	return InlineEconomyPulse._advance_runtime_graph_pulse(self, day_index)


func _halt_on_economy_fatal(day_index: int, economy_result: Dictionary) -> void:
	InlineEconomyPulse._halt_on_economy_fatal(self, day_index, economy_result)


func _dispatch_runtime_graph_country_committed() -> void:
	InlineEconomyPulse._dispatch_runtime_graph_country_committed(self)


func _track_runtime_graph_stall(day_index: int, token_status: int) -> bool:
	return InlineEconomyPulse._track_runtime_graph_stall(self, day_index, token_status)


func _log_stalled_runtime_graph(day: int) -> void:
	InlineEconomyPulse._log_stalled_runtime_graph(self, day)


func _day_stall_reason_name(mask: int) -> String:
	return InlineEconomyPulse._day_stall_reason_name(self, mask)


func _domain_mask_names(mask: int) -> String:
	return InlineEconomyPulse._domain_mask_names(self, mask)


func _log_stalled_runtime_graph_authority(day: int) -> void:
	InlineEconomyPulse._log_stalled_runtime_graph_authority(self, day)


func _native_daily_missing_slice_report() -> Dictionary:
	return {
		"rc": -1,
		"done": true,
		"path": "gdext_native_daily_slice",
		"fail_stage": "missing_run_native_daily_slice",
		"fallback_reason": "missing_run_native_daily_slice",
		"progress_ratio": 0.0,
		"stage_name": "native_daily",
		"substage": "missing_slice_method",
	}



func _disabled_sea_ice_atlas_report(reason: String) -> Dictionary:
	return {
		"done": true,
		"phase": "disabled",
		"stage_name": "sea_ice_atlas_upload",
		"elapsed_ms": 0.0,
		"reason": reason,
	}


## 取 HexCell 的 facade cid 缓存（39 项）。不可用（字段改名/类型不符）返回空数组。
## 这两份缓存只取决于 (DCWorld, DCWorldExt) 的注册表，与 cell 无关 —— 这正是
## 能把 2400 格 × 78 次 component_id 查询压成一次的原因。

func _cell_facade_cids_of(cell: Object, field: StringName) -> PackedInt32Array:
	if cell == null:
		return PackedInt32Array()
	var value: Variant = cell.get(field)
	if value is PackedInt32Array:
		return value
	return PackedInt32Array()


## 用共享 cid 表完成一次 `HexCell.bind_world()` 等价注入。
## 返回 false = 该对象不接受注入（调用方退回 bind_world()，行为不变）。

func _bind_cell_facade_with_cids(cell: Object, facade_on: bool,
		cid_gd: PackedInt32Array, cid_ext: PackedInt32Array) -> bool:
	var cell_index: Variant = cell.get(&"index")
	if not (cell_index is int):
		return false
	var expected := facade_on and (_generator._data_core_world != null) and int(cell_index) >= 0
	cell.set(&"_world", _generator._data_core_world)
	cell.set(&"_world_ext", _generator._data_core_world_ext)
	cell.set(&"_facade_enabled", expected)
	cell.set(&"_cid_array", cid_gd)
	cell.set(&"_cid_array_ext", cid_ext)
	# 回读校验：任一处字段名/语义漂移就整体退回 bind_world()。
	return bool(cell.get(&"_facade_enabled")) == expected \
			and _generator._cell_facade_cids_of(cell, &"_cid_array").size() == cid_gd.size()



func _setup_sus(map: MapData, world: WorldData, cfg: MapConfig, hex_size: float) -> void:
	await RuntimeSystemRegistration._setup_sus(self, map, world, cfg, hex_size)


## Phase 1.4 — 让 main.gd / debug overlay 拿到 sus_systems_bootstrap 引用。
## 在 _setup_sus 完成之前返回 null。


func get_environment_runtime() -> RefCounted:
	if _generator._environment_runtime != null:
		return _generator._environment_runtime
	if not ClassDB.class_exists("EnvironmentRuntime"):
		return null
	_generator._environment_runtime = ClassDB.instantiate("EnvironmentRuntime") as RefCounted
	return _generator._environment_runtime



func ensure_environment_runtime(map: MapData, pixel_size: Vector2i = Vector2i.ZERO) -> RefCounted:
	var rt: RefCounted = _generator.get_environment_runtime()
	if rt == null:
		return null
	var cell_count: int = map.cell_count() if map != null else 0
	if rt.has_method("initialize_with_sizes"):
		rt.call("initialize_with_sizes", cell_count, pixel_size)
	if map != null and map.has_method("neighbor_indices_packed") and rt.has_method("build_topology_from_arrays"):
		var pixel_to_cell: PackedInt32Array = PackedInt32Array()
		rt.call("build_topology_from_arrays", map.neighbor_indices_packed(), map.is_water_arr, map.terrain_arr, pixel_to_cell)
	if map != null and rt.has_method("bind_core_buffers"):
		rt.call("bind_core_buffers", map.elevation_arr, map.temp_arr, map.moisture_arr, map.slp_arr, map.wind_x_arr, map.wind_y_arr, map.ocean_current_x_arr, map.ocean_current_y_arr)
	if map != null and rt.has_method("bind_weather_buffers"):
		rt.call("bind_weather_buffers", map.weather_vapor_arr, map.weather_cloud_arr, map.weather_precip_arr)
	return rt



func environment_runtime_status() -> Dictionary:
	var rt: RefCounted = _generator.get_environment_runtime()
	if rt == null or not rt.has_method("status"):
		return {}
	var out: Dictionary = rt.call("status")
	if rt.has_method("buffer_summary"):
		out["buffers"] = rt.call("buffer_summary")
	if rt.has_method("topology_summary"):
		out["topology"] = rt.call("topology_summary")
	if rt.has_method("snapshot_summary"):
		out["snapshot"] = rt.call("snapshot_summary")
	if rt.has_method("progress_summary"):
		out["progress"] = rt.call("progress_summary")
	if rt.has_method("export_runtime_state"):
		out["runtime_state"] = rt.call("export_runtime_state")
	return out



func export_environment_runtime_state() -> Dictionary:
	var rt: RefCounted = _generator.get_environment_runtime()
	if rt == null or not rt.has_method("export_runtime_state"):
		return {}
	var state: Dictionary = rt.call("export_runtime_state")
	if _generator._data_core_world_ext != null:
		state["climate_modes"] = _generator._data_core_world_ext.capture_climate_modes_state()
	return state



func restore_environment_runtime_state(state: Dictionary) -> Dictionary:
	var rt: RefCounted = _generator.get_environment_runtime()
	if rt == null or not rt.has_method("restore_runtime_state"):
		return {"ok": false, "code": "environment_provider_missing",
			"message": "Environment runtime provider is unavailable."}
	var result = rt.call("restore_runtime_state", state)
	if not result is Dictionary:
		return {
		"ok": false, "code": "environment_restore_contract_invalid",
		"message": "Environment runtime restore returned an invalid result."}
	if not bool(result.get("ok", false)):
		return result
	var climate_modes = state.get("climate_modes", null)
	if climate_modes is Dictionary and _generator._data_core_world_ext != null :
		var climate_result: Dictionary = _generator._data_core_world_ext.restore_climate_modes_state(climate_modes)
		if not bool(climate_result.get("ok", false)):
			return climate_result
	return result



func _hard_effect_ack_chain_due(day: int) -> bool:
	if _generator._effect_daily_job != null and _generator._effect_facade != null and \
			bool(_generator._effect_facade.world_ext().effect_should_run(day)):
		return true
	if _generator._modifier_daily_job != null and _generator._modifier_facade != null and \
			bool(_generator._modifier_facade.world_ext().modifier_should_run(day)):
		return true
	if _generator._gameplay_effect_job != null and _generator._effect_facade != null and \
			bool(_generator._effect_facade.world_ext().gameplay_effect_should_run(day)):
		return true
	return false



func _ack_native_effect_domain_bindings() -> void:
	if _generator._modifier_facade != null:
		var modifier_ext: Object = _generator._modifier_facade.world_ext()
		if modifier_ext != null:
			modifier_ext.ack_effect_native_modifier()
	if _generator._country_facade != null:
		var country_ext: Object = _generator._country_facade.world_ext()
		if country_ext != null:
			country_ext.ack_effect_native_country()
	if _generator._economy_facade != null:
		var economy_ext: Object = _generator._economy_facade.world_ext()
		if economy_ext != null:
			economy_ext.ack_effect_native_economy()
	if _generator._effect_facade != null:
		var effect_ext: Object = _generator._effect_facade.world_ext()
		if effect_ext != null:
			effect_ext.ack_effect_native_gameplay()



func _log_stuck_day_barrier(day: int, economy_inflight: bool) -> void:
	_generator._barrier_diag_count += 1
	if _generator._barrier_diag_count > 8 and (_generator._barrier_diag_count % _generator.BARRIER_DIAG_LOG_STRIDE) != 0:
		return
	var hard_flags := PackedStringArray()
	var extra_flags := PackedStringArray()
	if _generator._trigger_daily_job != null and _generator._trigger_facade != null \
			and bool(_generator._trigger_facade.world_ext().trigger_should_run(day)):
		extra_flags.append("trigger")
	if _generator._ideology_daily_job != null and _generator._ideology_facade != null \
			and bool(_generator._ideology_facade.world_ext().ideology_should_run(day)):
		extra_flags.append("ideology")
	if _generator._effect_daily_job != null and _generator._effect_facade != null \
			and bool(_generator._effect_facade.world_ext().effect_should_run(day)):
		hard_flags.append("effect")
	if _generator._modifier_daily_job != null and _generator._modifier_facade != null \
			and bool(_generator._modifier_facade.world_ext().modifier_should_run(day)):
		hard_flags.append("modifier")
	if _generator._gameplay_effect_job != null and _generator._effect_facade != null \
			and bool(_generator._effect_facade.world_ext().gameplay_effect_should_run(day)):
		hard_flags.append("gameplay")
	print("[sim/barrier] day=%d pulse=%d economy_inflight=%s hard_ack=%s extra=%s"
		% [day, _generator._barrier_diag_count, str(economy_inflight), ",".join(hard_flags),
			",".join(extra_flags)])



func _drain_native_effect_ack_chain(ctx: SusTickContext) -> int:
	if _generator._sus == null or ctx == null:
		return 0
	var day := int(ctx.day_index)
	var drained := 0
	if _generator._trigger_daily_job != null and _generator._trigger_facade != null and \
			bool(_generator._trigger_facade.world_ext().trigger_should_run(day)):
		_generator._sus.continue_system(&"trigger_runtime", ctx)
		drained += 1
	if _generator._ideology_daily_job != null and _generator._ideology_facade != null and \
			bool(_generator._ideology_facade.world_ext().ideology_should_run(day)):
		_generator._sus.continue_system(&"ideology_runtime", ctx)
		drained += 1
	if _generator._effect_daily_job != null and _generator._effect_facade != null and \
			bool(_generator._effect_facade.world_ext().effect_should_run(day)):
		_generator._sus.continue_system(&"effect_runtime", ctx)
		drained += 1
	if _generator._modifier_daily_job != null and _generator._modifier_facade != null and \
			bool(_generator._modifier_facade.world_ext().modifier_should_run(day)):
		_generator._sus.continue_system(&"modifier_daily", ctx)
		drained += 1
	if _generator._gameplay_effect_job != null and _generator._effect_facade != null and \
			bool(_generator._effect_facade.world_ext().gameplay_effect_should_run(day)):
		_generator._sus.continue_system(&"gameplay_effect", ctx)
		drained += 1
	return drained



func environment_runtime_step_budgeted(budget_ms: float, max_cells: int = 0, max_pixels: int = 0, max_indices: int = 0, pipeline: StringName = &"ocean") -> Dictionary:
	var rt: RefCounted = _generator.get_environment_runtime()
	if rt == null:
		return {"done": true, "stage": "missing_runtime", "work_done": 0, "elapsed_ms": 0.0}
	if pipeline == &"climate" and rt.has_method("step_climate_budgeted"):
		return rt.call("step_climate_budgeted", budget_ms, max_cells, max_pixels, max_indices)
	if pipeline == &"weather" and rt.has_method("step_weather_budgeted"):
		return rt.call("step_weather_budgeted", budget_ms, max_cells, max_pixels, max_indices)
	if pipeline == &"ocean" and rt.has_method("step_ocean_budgeted"):
		return rt.call("step_ocean_budgeted", budget_ms, max_cells, max_pixels, max_indices)
	if rt.has_method("step_budgeted"):
		return rt.call("step_budgeted", budget_ms, max_cells, max_pixels, max_indices)
	return {"done": true, "stage": "missing_step", "work_done": 0, "elapsed_ms": 0.0}


## 2026-05-19：dynamic/ecology/smooth/ice atlas 上传 stride 的运行时调整入口。
## HexRenderer.set_dyn_atlas_upload_stride() 反向调用过来；如果 _setup_sus 还没
## 跑过（_dynamic_visual_atlas_upload_job == null），先存到字段，等下次 setup 用。

func set_dyn_atlas_upload_stride(p_stride: int) -> void:
	_generator._dyn_atlas_upload_stride = clampi(p_stride, 1, 8)
	var cp = _generator._c()
	if cp != null and cp.get("dynamic_visual_atlas_upload_stride") != null:
		cp.dynamic_visual_atlas_upload_stride = _generator._dyn_atlas_upload_stride
	if _generator._sus != null:
		_generator._sus.apply_job_schedule(_generator._dynamic_visual_atlas_upload_job, cp, &"dynamic_visual_atlas_upload", _generator._dyn_atlas_upload_stride)



func set_enum_atlas_upload_stride(p_stride: int) -> void:
	var stride: int = clampi(p_stride, 1, 8)
	var cp = _generator._c()
	if cp != null and cp.get("enum_atlas_upload_stride") != null:
		cp.enum_atlas_upload_stride = stride
	if _generator._sus != null:
		_generator._sus.apply_job_schedule(_generator._enum_atlas_upload_job, cp, &"enum_atlas_upload", stride)



func set_world_clock_ref(world_clock_node) -> void:
	_generator._world_clock_ref = world_clock_node
	if _generator._baker != null and _generator._baker.has_method("set_world_clock_ref"):
		_generator._baker.set_world_clock_ref(_generator._world_clock_ref)
	if _generator._world_clock_ref == null:
		return
	# Jobs may already exist when a host injects the clock late. Keep their
	# barrier requests and continuation pulse connection aligned with the host.
	if _generator._country_daily_job != null:
		_generator._country_daily_job.world_clock = _generator._world_clock_ref
	if _generator._ideology_daily_job != null:
		_generator._ideology_daily_job.world_clock = _generator._world_clock_ref
	if _generator._economy_daily_job != null:
		_generator._economy_daily_job.world_clock = _generator._world_clock_ref
	if _generator._bio_occupancy_daily_job != null:
		_generator._bio_occupancy_daily_job.world_clock = _generator._world_clock_ref
	if _generator._ocean_currents_job != null:
		_generator._ocean_currents_job.season_phase_getter = Callable(_generator._world_clock_ref, "season_phase")
	# 任务 8：把 world_clock getter 注入给气候 / 天气 Job。
	if _generator._refresh_climate_daily_job != null:
		_generator._refresh_climate_daily_job.season_phase_getter = Callable(_generator._world_clock_ref, "season_phase")
	if _generator._sea_ice_daily_job != null:
		_generator._sea_ice_daily_job.season_phase_getter = Callable(_generator._world_clock_ref, "season_phase")
	if _generator._weather_refresh_job != null:
		_generator._weather_refresh_job.season_index_getter = Callable(_generator._world_clock_ref, "season_index")
		_generator._weather_refresh_job.season_phase_getter = Callable(_generator._world_clock_ref, "season_phase")
		var wc_ref = _generator._world_clock_ref
		_generator._weather_refresh_job.climate_anomaly_getter = func() -> float:
			return float(wc_ref.climate_anomaly)


## main.gd._on_day_changed 末尾调用，驱动 SUS 推进所有日级 Job。
## tick_index 单调递增；day_index / season_phase / speed 由 world_clock 提供。
## 返回字典：{ fronts: Array[WeatherFront], weather_ran: bool }，
## 让 main.gd 把 fronts 转发给 renderer、用 weather_ran 决定面板刷新策略。
