extends "res://scripts/simulation/generator_context.gd"

const EconomyTestBootstrapScript = preload("res://scripts/economy/economy_test_bootstrap.gd")
const IdeologyFacadeScript = preload("res://scripts/ideology/ideology_facade.gd")

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
	return _generator._data_core_world_ext.get_runtime_thread_report()

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


func poll_runtime_commit(after_generation: int = 0) -> Dictionary:
	if _generator._data_core_world_ext == null:
		return {"ok": false, "code": "runtime_worker_api_missing"}
	return _generator._data_core_world_ext.poll_runtime_commit(after_generation)


func flush_runtime_economy_resource_writeback() -> Dictionary:
	if _generator._data_core_world_ext == null:
		return {"ok": false, "code": "runtime_worker_api_missing"}
	return _generator._data_core_world_ext.flush_runtime_economy_resource_writeback()


func consume_runtime_visual_patch(generation: int, family: int, cursor: int,
		max_items: int) -> Dictionary:
	if _generator._data_core_world_ext == null:
		return {"ok": false, "code": "runtime_worker_api_missing"}
	return _generator._data_core_world_ext.consume_runtime_visual_patch(
		generation, family, cursor, max_items)


func request_runtime_save(request_id: int) -> Dictionary:
	if _generator._data_core_world_ext == null:
		return {"ok": false, "code": "runtime_worker_api_missing"}
	# P1：存盘准入要求 ring 排空（`!has_pending_climate_input()`），而预发布会让
	# ring 长期非空。先让 host 把 K 降到 0、停掉新帧；环里的未来帧由 worker 侧
	# 在存盘准入处丢弃（PKSR 不保存 pending environment）。
	_generator._get_runtime_climate_capture()._notify_save_prefetch_suspend()
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


func request_runtime_stop() -> Dictionary:
	if _generator._data_core_world_ext == null:
		return {"ok": true, "state": "STOPPED"}
	return _generator._data_core_world_ext.request_runtime_stop()


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
	var trade_topology: Dictionary = _generator._get_map_country_initializer()._capture_economy_trade_topology(_generator._sus_map)
	if not bool(trade_topology.get("ok", false)):
		return trade_topology
	var registered: Dictionary = _generator._get_map_rules_initializer()._register_country_economy_systems(_generator._c())
	if not bool(registered.get("ok", false)):
		return registered
	# PKMI has already restored. Never configure again here: that would erase
	# the recovered armies, orders and AI state. Refresh settlement terrain
	# from restored ECP2 through the facade's state-preserving terrain path.
	if _generator._military_facade != null and _generator._military_facade.is_configured():
		var terrain: Dictionary = _generator._military_facade.set_terrain(_generator._sus_map, -1, true,
			_generator._get_map_country_initializer()._military_settlement_tiers(_generator._sus_map))
		if not bool(terrain.get("ok", false)) or not bool(terrain.get("state_preserved", false)):
			return {"ok": false, "reason": "military_restore_terrain_failed"}
		if _generator._military_facade.ai_player_handles().is_empty():
			_generator._get_map_country_initializer()._arm_military_ai(_generator._get_map_country_initializer()._gameplay_player_country_handles())
	else:
		# Keep a fallback for restore paths whose preparation did not produce a
		# configured facade. A successful configure is safe here because no PKMI
		# state was installed into the facade in that path.
		var military_configured: Dictionary = _generator._get_map_country_initializer()._configure_military_runtime(
			_generator._sus_map, null, _generator._save_restore_seed)
		if bool(military_configured.get("ok", false)):
			_generator._get_map_country_initializer()._arm_military_ai(_generator._get_map_country_initializer()._gameplay_player_country_handles())
	_generator._get_map_country_initializer()._maybe_register_military_system()
	if not _generator._runtime_build_topology("save restore finalize"):
		return {"ok": false, "reason": "save_restore_scheduler_topology_failed"}
	_generator._save_restore_preparation_enabled = false
	_generator._gameplay_start_report["country_count"] = int(country_report.get("country_count", 0))
	_generator._gameplay_start_report["settlement_source"] = "save_restore"
	print("[save/restore] PKCN and PKEC restored; country/economy systems registered")
	return {"ok": true}


func advance_save_boundary() -> void:
	# Save requests freeze the clock.  Drain the same ordered native Effect
	# chain that a normal daily SUS tick would run before continuing Country and
	# Economy at their own safe boundaries.  This keeps PKEF, PKCN, PKEC and the
	# gameplay journal from being captured on opposite sides of an ACK.
	if _generator._world_clock_ref == null or _generator._sus == null:
		return
	var day: int = _generator._world_clock_ref.day_index()
	var ctx := SusTickContext.make(day, day, _generator._world_clock_ref.season_phase(),
		_generator._world_clock_ref.speed_multiplier, &"save_boundary")
	_generator._drain_native_effect_ack_chain(ctx)
	# country 是存档边界里唯一没有"推进者"的域：时钟已 pause，而
	# _continue_economy_inflight() 的 runtime-graph 分支被
	# needs_continuation_pulse() 挡住（暂停期间没人举 barrier），于是
	# country_should_run(day) 只能一直为真，_wait_for_safe_boundary() 空转到
	# 停顿上限失败（web 90 帧 → "保存不了"）。这里按 country 当前的 owner 补推：
	#   * runtime graph 拥有 country -> 直接 pulse 一次（与正常帧同一条链路）；
	#   * GDScript country_daily 拥有 country -> continue_system 切片。
	# 两者都幂等：country 已经空闲时循环一次都不会进。
	if _generator._runtime_graph_active and _generator._data_core_world_ext != null :
		if not _generator.native_daily_round_active() and not _generator.bio_occupancy_round_active():
			_generator._advance_runtime_graph_pulse(day)
	elif _generator._country_daily_job != null and _generator._country_facade != null \
			and _generator._country_facade.should_run(day):
		var country_slices := 0
		while country_slices < _generator.SAVE_BOUNDARY_COUNTRY_MAX_SLICES \
				and _generator._country_facade.should_run(day):
			_generator._sus.continue_system(&"country_daily", ctx)
			country_slices += 1
			# Country 会注册新的 Effect 命令；不接着排 ACK 链的话
			# country_should_run 会因为"等 ACK"保持为真。
			_generator._drain_native_effect_ack_chain(ctx)
	_generator._continue_economy_inflight(day)

func _ensure_continuation_perf_pending() -> void:
	if not _generator._continuation_perf_pending.is_empty():
		return
	_generator._continuation_perf_pending = {
		"frames": 0,
		"slices": 0,
		"continuation_started_slices": 0,
		"continuation_completed_slices": 0,
		"continuation_budget_exhausted": false,
		"continuation_budget_overrun_frames": 0,
		"continuation_max_budget_overrun_ms": 0.0,
		"continuation_blocked_by_stage": "",
		"country_slices": 0,
		"economy_slices": 0,
		"wall_ms": 0.0,
		"max_frame_wall_ms": 0.0,
		"max_slice_ms": 0.0,
		"last_slice_ms": 0.0,
		"budget_ms": 0.0,
		"last_stage": "",
		"last_next_stage": "",
		"last_substage": "",
		"last_path": "",
		"done": false,

		"stage_counts": {},
		"stage_wall_ms": {},
		"stage_max_slice_ms": {},
		"substage_counts": {},
		"substage_wall_ms": {},
		"substage_max_slice_ms": {},
		"substage_work": {},
	}



func _record_continuation_slice(source: String, result: Dictionary, wall_ms: float) -> float:
	_generator._ensure_continuation_perf_pending()
	var slice_ms: float = maxf(wall_ms, 0.0)
	var stage: String = str(result.get("stage_name", result.get("stage", "")))
	var next_stage: String = str(result.get("next_stage", result.get("stage", "")))
	var substage: String = str(result.get("substage", ""))
	var path: String = str(result.get("path", ""))
	if stage.is_empty():
		stage = "unknown"
	var stage_key := "%s:%s" % [source, stage]
	var stage_counts: Dictionary = _generator._continuation_perf_pending.get("stage_counts", {})
	stage_counts[stage_key] = int(stage_counts.get(stage_key, 0)) + 1
	_generator._continuation_perf_pending["stage_counts"] = stage_counts
	var stage_wall_ms: Dictionary = _generator._continuation_perf_pending.get("stage_wall_ms", {})
	stage_wall_ms[stage_key] = float(stage_wall_ms.get(stage_key, 0.0)) + slice_ms
	_generator._continuation_perf_pending["stage_wall_ms"] = stage_wall_ms
	var stage_max_slice_ms: Dictionary = _generator._continuation_perf_pending.get(
		"stage_max_slice_ms", {})
	stage_max_slice_ms[stage_key] = maxf(
		float(stage_max_slice_ms.get(stage_key, 0.0)), slice_ms)
	_generator._continuation_perf_pending["stage_max_slice_ms"] = stage_max_slice_ms
	var breakdown_ms_value = result.get("stage_breakdown_ms", {})
	if breakdown_ms_value is Dictionary:
		var substage_counts: Dictionary = _generator._continuation_perf_pending.get(
			"substage_counts", {})
		var substage_wall_ms: Dictionary = _generator._continuation_perf_pending.get(
			"substage_wall_ms", {})
		var substage_max_slice_ms: Dictionary = _generator._continuation_perf_pending.get(
			"substage_max_slice_ms", {})
		for breakdown_name in breakdown_ms_value:
			var breakdown_ms: float = maxf(
				0.0, float(breakdown_ms_value.get(breakdown_name, 0.0)))
			if breakdown_ms <= 0.0:
				continue
			var breakdown_key := "%s:%s" % [source, str(breakdown_name)]
			substage_counts[breakdown_key] = int(
				substage_counts.get(breakdown_key, 0)) + 1
			substage_wall_ms[breakdown_key] = float(
				substage_wall_ms.get(breakdown_key, 0.0)) + breakdown_ms
			substage_max_slice_ms[breakdown_key] = maxf(float(
				substage_max_slice_ms.get(breakdown_key, 0.0)), breakdown_ms)
		_generator._continuation_perf_pending["substage_counts"] = substage_counts
		_generator._continuation_perf_pending["substage_wall_ms"] = substage_wall_ms
		_generator._continuation_perf_pending["substage_max_slice_ms"] = substage_max_slice_ms
	var breakdown_work_value = result.get("stage_breakdown_work", {})
	if breakdown_work_value is Dictionary:
		var substage_work: Dictionary = _generator._continuation_perf_pending.get("substage_work", {})
		for work_name in breakdown_work_value:
			var work: int = int(breakdown_work_value.get(work_name, 0))
			if work <= 0:
				continue
			var work_key := "%s:%s" % [source, str(work_name)]
			substage_work[work_key] = int(substage_work.get(work_key, 0)) + work
		_generator._continuation_perf_pending["substage_work"] = substage_work
	_generator._continuation_perf_pending["slices"] = int(_generator._continuation_perf_pending.get("slices", 0)) + 1
	_generator._continuation_perf_pending["continuation_started_slices"] = int(
		_generator._continuation_perf_pending.get("continuation_started_slices", 0)) + 1
	var source_key := "%s_slices" % source
	_generator._continuation_perf_pending[source_key] = int(_generator._continuation_perf_pending.get(source_key, 0)) + 1
	_generator._continuation_perf_pending["max_slice_ms"] = maxf(
		float(_generator._continuation_perf_pending.get("max_slice_ms", 0.0)), slice_ms)
	_generator._continuation_perf_pending["last_slice_ms"] = slice_ms
	_generator._continuation_perf_pending["last_stage"] = stage
	_generator._continuation_perf_pending["last_next_stage"] = next_stage
	_generator._continuation_perf_pending["last_substage"] = substage
	_generator._continuation_perf_pending["last_path"] = path
	var completed := bool(result.get("done", false))
	_generator._continuation_perf_pending["done"] = completed
	if completed:
		_generator._continuation_perf_pending["continuation_completed_slices"] = int(
			_generator._continuation_perf_pending.get("continuation_completed_slices", 0)) + 1
	return slice_ms



func _finish_continuation_perf_frame(started_us: int, frame_slices: int,
		frame_max_slice_ms: float, budget_ms: float) -> void:
	if frame_slices <= 0 or _generator._continuation_perf_pending.is_empty():
		return
	var frame_wall_ms: float = float(Time.get_ticks_usec() - started_us) / 1000.0
	_generator._continuation_perf_pending["frames"] = int(_generator._continuation_perf_pending.get("frames", 0)) + 1
	_generator._continuation_perf_pending["wall_ms"] = float(_generator._continuation_perf_pending.get("wall_ms", 0.0)) + frame_wall_ms
	_generator._continuation_perf_pending["max_frame_wall_ms"] = maxf(
		float(_generator._continuation_perf_pending.get("max_frame_wall_ms", 0.0)), frame_wall_ms)
	_generator._continuation_perf_pending["max_slice_ms"] = maxf(
		float(_generator._continuation_perf_pending.get("max_slice_ms", 0.0)), frame_max_slice_ms)
	_generator._continuation_perf_pending["budget_ms"] = budget_ms
	# Completion is a semantic state transition, not permission to hide a
	# deadline overrun.  The final publish slice can complete after the budget;
	# keep that fact visible for the render-frame performance gate.
	var budget_exhausted := budget_ms > 0.0 and frame_wall_ms >= budget_ms
	_generator._continuation_perf_pending["continuation_budget_exhausted"] = \
		bool(_generator._continuation_perf_pending.get(
			"continuation_budget_exhausted", false)) or budget_exhausted
	if budget_exhausted:
		_generator._continuation_perf_pending["continuation_budget_overrun_frames"] = int(
			_generator._continuation_perf_pending.get(
				"continuation_budget_overrun_frames", 0)) + 1
		_generator._continuation_perf_pending["continuation_max_budget_overrun_ms"] = maxf(
			float(_generator._continuation_perf_pending.get(
				"continuation_max_budget_overrun_ms", 0.0)),
			maxf(0.0, frame_wall_ms - budget_ms))
		var last_stage := str(_generator._continuation_perf_pending.get("last_stage", ""))
		if not last_stage.is_empty():
			_generator._continuation_perf_pending["continuation_blocked_by_stage"] = last_stage


## [continuation-reentry-guard 2026-11-03] 带符号引擎的 backtrace 显示真机崩溃是
## 一次约 500 帧的 GDScript 递归，三帧循环是
##   GDScriptFunction::call → GDScript::callp → Variant::callp
## 也就是"脚本函数里再调用脚本函数"的无限自调用。最可疑的环就在这条链上：
## WorldClock 发 `simulation_backpressure_pulse` → 本回调推进 native graph pulse →
## 同一调用链里若再次发 pulse，就会无限重入。
## 这里用重入闩把环切断：正常路径不会重入，一旦重入就打印并返回。

func _continue_economy_inflight(day_index: int) -> void:
	if _generator._continuation_reentry_guard:
		print("[continuation] re-entry blocked (recursion guard) day=%d" % day_index)
		return
	_generator._continuation_reentry_guard = true
	_generator._continue_economy_inflight_impl(day_index)
	_generator._continuation_reentry_guard = false



func _continue_economy_inflight_impl(day_index: int) -> void:
	# Defense in depth: climate capacity is not an economy/country continuation
	# target. WorldClock should already skip this pulse, but older callers or
	# mixed barriers can still land here — never burn the frame on graph capture.
	if _generator._world_clock_ref != null and _generator._world_clock_ref.has_method("needs_continuation_pulse") \
			and not _generator._world_clock_ref.needs_continuation_pulse():
		return
	if _generator._sus == null:
		return
	if _generator._runtime_graph_active and _generator._data_core_world_ext != null \
			and not _generator.native_daily_round_active() and not _generator.bio_occupancy_round_active():
		_generator._advance_runtime_graph_pulse(day_index)
		return
	var speed: float = float(_generator._world_clock_ref.speed_multiplier) if _generator._world_clock_ref != null else 1.0
	var season: float = float(_generator._world_clock_ref.season_phase()) if _generator._world_clock_ref != null else 0.0
	var ctx: SusTickContext = SusTickContext.make(
		day_index, day_index, season, speed, &"country_economy_continuation")
	var budget_ms = _generator.ECONOMY_CONTINUATION_FALLBACK_BUDGET_MS
	if _generator._world_clock_ref != null:
		var configured_budget = _generator._world_clock_ref.get("sim_frame_budget_ms")
		if configured_budget != null:
			budget_ms = maxf(0.25, float(configured_budget))
	# Allocate the diagnostic accumulator before starting the measured pulse so
	# dictionary/JSON setup cannot consume the continuation's simulation budget.
	_generator._ensure_continuation_perf_pending()
	var started_us := Time.get_ticks_usec()
	var continuation_count := 0
	var frame_max_slice_ms := 0.0
	var native_launch_deadline_ms = budget_ms - minf(
		_generator.NATIVE_DAILY_CONTINUATION_SLICE_HEADROOM_MS, budget_ms * 0.5)
	# Native climate and Bio occupancy are same-day transactions. Native slices
	# are synchronous cooperative stages, including deferred JIT-patch waits, so
	# drain consecutive slices inside this pulse while the shared frame budget
	# allows it. Release barriers only after the final publish, and never let a
	# diagnostic/economy drain run ahead of a still-open climate transaction.
	if _generator.native_daily_round_active():
		var native_round_was_active := true
		var native_last_result: Dictionary = {}
		# A pending first slice is not yet represented by the job's own
		# _native_round_active flag.  Once this pulse starts run_slice(), the job
		# becomes the authoritative owner of the barrier state.
		_generator._native_daily_day_pending = false
		while _generator.native_daily_round_active() \
				and continuation_count < _generator.ECONOMY_CONTINUATION_MAX_SLICES_PER_FRAME:
			var native_started_us := Time.get_ticks_usec()
			var native_result: Dictionary = _generator._sus.continue_system(&"native_daily_sim", ctx)
			native_last_result = native_result
			var native_slice_ms: float = float(Time.get_ticks_usec() - native_started_us) / 1000.0
			frame_max_slice_ms = maxf(frame_max_slice_ms,
				_generator._record_continuation_slice("native_daily", native_result, native_slice_ms))
			continuation_count += 1
			if bool(native_result.get("fatal", false)) \
					or float(Time.get_ticks_usec() - started_us) / 1000.0 \
						>= native_launch_deadline_ms:
				break
		# sus_tick_daily() advances this generation when a round completes in
		# the ordinary scheduler visit. A round finalized by continuation owns
		# the same immutable Climate commit boundary and must advance it once as
		# well, otherwise captured SHADOW frames remain reference-pending
		# forever despite the day barrier having been released.
		if native_round_was_active and not _generator.native_daily_round_active() \
				and bool(native_last_result.get("done", false)) \
				and not bool(native_last_result.get("fatal", false)):
			_generator._native_daily_climate_round_generation += 1
		if _generator._world_clock_ref != null:
			_generator._world_clock_ref.request_simulation_backpressure(
				&"native_daily_day_barrier", _generator.native_daily_round_active())
		if _generator.native_daily_round_active() \
				or float(Time.get_ticks_usec() - started_us) / 1000.0 >= native_launch_deadline_ms:
			_generator._finish_continuation_perf_frame(started_us, continuation_count, frame_max_slice_ms, budget_ms)
			return
	if _generator.bio_occupancy_round_active():
		_generator._bio_occupancy_day_pending = false
		var bio_started_us := Time.get_ticks_usec()
		var bio_result: Dictionary = _generator._sus.continue_system(&"bio_occupancy_daily", ctx)
		var bio_slice_ms: float = float(Time.get_ticks_usec() - bio_started_us) / 1000.0
		frame_max_slice_ms = maxf(frame_max_slice_ms,
			_generator._record_continuation_slice("bio_occupancy", bio_result, bio_slice_ms))
		continuation_count += 1
		if _generator._world_clock_ref != null:
			_generator._world_clock_ref.request_simulation_backpressure(
				&"bio_occupancy_day_barrier", _generator.bio_occupancy_round_active())
		if _generator.bio_occupancy_round_active() or float(Time.get_ticks_usec() - started_us) / 1000.0 >= budget_ms:
			_generator._finish_continuation_perf_frame(started_us, continuation_count, frame_max_slice_ms, budget_ms)
			return
	while continuation_count < _generator.ECONOMY_CONTINUATION_MAX_SLICES_PER_FRAME:
		if _generator._country_daily_job != null and _generator._country_facade != null and \
				bool(_generator._country_facade.world_ext().country_should_run(day_index)):
			var country_slice_started_us := Time.get_ticks_usec()
			var country_result: Dictionary = _generator._sus.continue_system(&"country_daily", ctx)
			var country_slice_ms: float = float(Time.get_ticks_usec() - country_slice_started_us) / 1000.0
			frame_max_slice_ms = maxf(frame_max_slice_ms,
				_generator._record_continuation_slice("country", country_result, country_slice_ms))
			continuation_count += 1
			if float(Time.get_ticks_usec() - started_us) / 1000.0 >= budget_ms:
				_generator._finish_continuation_perf_frame(started_us, continuation_count, frame_max_slice_ms, budget_ms)
				return
			# Keep a pure Country continuation contiguous.  If no hard ACK is
			# pending, the next Country slice cannot observe a newer dependency;
			# this avoids needless Country/Economy alternation and preserves the
			# deterministic command order expected by the day barrier.
			if bool(_generator._country_facade.world_ext().country_should_run(day_index)) \
					and not _generator._hard_effect_ack_chain_due(day_index):
				continue
			# Do not skip the ACK drain while country_should_run stays true.
			# Research completions register Effect instances that keep
			# country_should_run true via pending commands until Effect/Modifier/
			# gameplay ACK. Skipping ACK here livelocks leftover Stone-Age nodes.
		# Country may register a technology Effect after the morning Effect slot.
		# Drain Trigger/Ideology opportunistically, then the hard Effect→Modifier
		# →gameplay ACK chain. Trigger/Ideology should_run can stay true for
		# tomorrow's queued work; that must not starve an in-flight economy epoch
		# or pin WorldClock on country_day_barrier.
		continuation_count += _generator._drain_native_effect_ack_chain(ctx)
		if float(Time.get_ticks_usec() - started_us) / 1000.0 >= budget_ms:
			_generator._finish_continuation_perf_frame(started_us, continuation_count,
				frame_max_slice_ms, budget_ms)
			return
		_generator._ack_native_effect_domain_bindings()
		if float(Time.get_ticks_usec() - started_us) / 1000.0 >= budget_ms:
			_generator._finish_continuation_perf_frame(started_us, continuation_count,
				frame_max_slice_ms, budget_ms)
			return
		var ack_passes := 1
		while ack_passes < _generator.EFFECT_ACK_CHAIN_MAX_PASSES and \
				_generator._hard_effect_ack_chain_due(day_index):
			continuation_count += _generator._drain_native_effect_ack_chain(ctx)
			_generator._ack_native_effect_domain_bindings()
			ack_passes += 1
			if float(Time.get_ticks_usec() - started_us) / 1000.0 >= budget_ms:
				break
		var hard_ack_due = _generator._hard_effect_ack_chain_due(day_index)
		if _generator._world_clock_ref != null:
			var economy_inflight = _generator._economy_daily_job != null and _generator._economy_facade != null \
				and bool(_generator._economy_facade.world_ext().economy_should_run(day_index))
			# Keep the country barrier only while an in-flight economy epoch still
			# needs catchup. Otherwise release it so the next render frame can
			# advance a day and Country's UNIQUE_SOURCE fallback can fire.
			_generator._world_clock_ref.request_simulation_backpressure(
				&"country_day_barrier", hard_ack_due and economy_inflight)
			if hard_ack_due:
				_generator._log_stuck_day_barrier(day_index, economy_inflight)
		if _generator._economy_daily_job == null or _generator._economy_facade == null:
			if _generator._world_clock_ref != null:
				_generator._world_clock_ref.request_simulation_backpressure(&"economy_day_barrier", false)
			_generator._finish_continuation_perf_frame(started_us, continuation_count, frame_max_slice_ms, budget_ms)
			return
		var economy_ext: Object = _generator._economy_facade.world_ext()
		if not bool(economy_ext.economy_should_run(day_index)):
			# This is a cold/stale-barrier path. Query the full report only here so
			# fatal state remains distinguishable from a completed continuation.
			var report: Dictionary = _generator._economy_facade.report()
			if bool(report.get("fatal", false)):
				# FATAL is terminal for the economy graph, so no future economy slice
				# can clear the hard barrier. Release it defensively or WorldClock
				# remains permanently stuck on the last day.
				if _generator._world_clock_ref != null:
					_generator._world_clock_ref.request_simulation_backpressure(
						&"economy", false)
					_generator._world_clock_ref.request_simulation_backpressure(
						&"economy_day_barrier", false)
				_generator._finish_continuation_perf_frame(started_us, continuation_count, frame_max_slice_ms, budget_ms)
				return
			if _generator._world_clock_ref != null:
				_generator._world_clock_ref.request_simulation_backpressure(&"economy_day_barrier", false)
			_generator._finish_continuation_perf_frame(started_us, continuation_count, frame_max_slice_ms, budget_ms)
			return
		var economy_slice_started_us := Time.get_ticks_usec()
		var economy_result: Dictionary = _generator._sus.continue_system(&"economy_daily", ctx)
		var economy_slice_ms: float = float(Time.get_ticks_usec() - economy_slice_started_us) / 1000.0
		frame_max_slice_ms = maxf(frame_max_slice_ms,
			_generator._record_continuation_slice("economy", economy_result, economy_slice_ms))
		continuation_count += 1
		if bool(economy_result.get("fatal", false)):
			# A continuation may surface the terminal result directly. Keep this
			# backstop beside the cold-report path so no fatal route can strand the
			# WorldClock behind an economy barrier.
			if _generator._world_clock_ref != null:
				_generator._world_clock_ref.request_simulation_backpressure(
					&"economy", false)
				_generator._world_clock_ref.request_simulation_backpressure(
					&"economy_day_barrier", false)
			_generator._finish_continuation_perf_frame(started_us, continuation_count, frame_max_slice_ms, budget_ms)
			return
		if bool(economy_result.get("done", false)) or \
				not bool(economy_ext.economy_should_run(day_index)):
			if _generator._world_clock_ref != null:
				_generator._world_clock_ref.request_simulation_backpressure(&"economy_day_barrier", false)
			_generator._finish_continuation_perf_frame(started_us, continuation_count, frame_max_slice_ms, budget_ms)
			return
		if float(Time.get_ticks_usec() - started_us) / 1000.0 >= budget_ms:
			_generator._finish_continuation_perf_frame(started_us, continuation_count, frame_max_slice_ms, budget_ms)
			return
	_generator._finish_continuation_perf_frame(started_us, continuation_count, frame_max_slice_ms, budget_ms)



func _advance_runtime_graph_pulse(day_index: int) -> Dictionary:
	if _generator._data_core_world_ext == null:
		return {}
	var speed_graph := float(_generator._world_clock_ref.speed_multiplier) if _generator._world_clock_ref != null else 1.0
	var season_graph := float(_generator._world_clock_ref.season_phase()) if _generator._world_clock_ref != null else 0.0
	var budget_graph = _generator.ECONOMY_CONTINUATION_FALLBACK_BUDGET_MS
	if _generator._world_clock_ref != null and _generator._world_clock_ref.get("sim_frame_budget_ms") != null:
		budget_graph = maxf(0.25, float(_generator._world_clock_ref.sim_frame_budget_ms))
	var token := int(_generator._data_core_world_ext.advance_runtime_pulse(
		day_index, season_graph, speed_graph, int(budget_graph * 1000.0), 0))
	var token_status := int((token >> 56) & 0xff)
	var token_dirty := int((token >> 32) & 0xffff)
	var barrier_armed = _generator._track_runtime_graph_stall(day_index, token_status)
	if _generator._world_clock_ref != null:
		_generator._world_clock_ref.request_simulation_backpressure(
			&"economy_day_barrier", barrier_armed)
		_generator._world_clock_ref.request_simulation_backpressure(
			&"country_day_barrier", barrier_armed)
		# The first slice can run through IdeologyRuntimeSystem (which arms its
		# own barrier), while continuation goes straight to the native graph.
		# Reconcile that same barrier here after native completion as well.
		# `ideology_needs_daily_continuation` was added to the native bridge after
		# older Windows DLLs had already been distributed. Probe the binding before
		# calling it so an out-of-date extension cannot abort a save boundary. The
		# graph's hard-pending status is the conservative compatibility fallback: it
		# keeps the ideology barrier armed until the extension is rebuilt.
		var ideology_pending = barrier_armed
		ideology_pending = bool(_generator._data_core_world_ext.ideology_needs_daily_continuation(day_index))
		_generator._world_clock_ref.request_simulation_backpressure(
			&"ideology_day_barrier", ideology_pending)
	if token_dirty != 0:
		_generator._data_core_world_ext.flush_runtime_visuals(token_dirty)
	# Country slice 已在 pulse 内写入 native + MapData.country_slot_arr，但
	# CountryDailySystem.dispatch_committed_events 被 graph 短路跳过；这里按
	# generation watermark 补发，驱动 WorldRuntimeHost.refresh_country_visuals。
	_generator._dispatch_runtime_graph_country_committed()
	if _generator._data_core_world_ext is DCWorldExt:
		var economy_result: Dictionary = _generator._data_core_world_ext.get_runtime_graph_last_economy_report()
		if bool(economy_result.get("fatal", false)):
			_generator._halt_on_economy_fatal(day_index, economy_result)
		if int(economy_result.get("day_index", economy_result.get("sample_day", -1))) == day_index:
			if _generator._economy_facade != null and bool(economy_result.get(
					"economy_event_batch_published", false)):
				_generator._economy_facade.dispatch_committed_events(economy_result)
			if _generator._economy_facade != null:
				_generator._economy_facade.dispatch_construction_command_receipts()
	return {"token": token, "status": token_status,
		"dirty_mask": token_dirty}


## 经济 runtime 进入 fatal 后 economy_should_run() 恒为 false，原生 graph 的 pending
## 判定随之落回 idle，日历会继续推进——气候/国家/人口照跑，经济却已经死了，玩家看到的
## 是一份持续腐烂的存档。legacy 续跑路径在 fatal 时会举起 economy_day_barrier 把时钟
## 钉住；graph 路径这里补上等价语义，并且直接暂停 + push_error，让停机可见而不是伪装
## 成又一次卡顿。

func _halt_on_economy_fatal(day_index: int, economy_result: Dictionary) -> void:
	if _generator._runtime_graph_economy_fatal_halted:
		return
	_generator._runtime_graph_economy_fatal_halted = true
	var reason := String(economy_result.get("fatal_reason", "unknown"))
	# 全量 report 有 450+ 键，只在 fatal 这一次值得付这个跨语言搬运；守恒/审计字段
	# 只在这里齐全，compact slice 报告不带。
	var detail: Dictionary = economy_result
	if _generator._economy_facade != null and _generator._economy_facade.has_method("report"):
		detail = _generator._economy_facade.report()
	print("[sim/economy-fatal] day=%d reason=%s stage=%s sample_day=%s last_completed_sample_day=%s audit_mode=%s audit_ledger=%s audit_lane=%s audit_mismatches=%s population_error=%s money_error=%s goods_error=%s"
		% [day_index, reason, str(detail.get("stage", "?")),
			str(detail.get("sample_day", -1)),
			str(detail.get("last_completed_sample_day", -1)),
			str(detail.get("closing_audit_mode", "?")),
			str(detail.get("closing_audit_mismatch_ledger", "?")),
			str(detail.get("closing_audit_mismatch_lane", -1)),
			str(detail.get("closing_audit_mismatches", -1)),
			str(detail.get("population_error", -1)),
			str(detail.get("money_error", -1)),
			str(detail.get("goods_error", -1))])
	# graph 路径原先只打短行；money_conservation_failed 需要和 economy_daily 同等的分桶，
	# 否则 GM 截断/日志丢失后无法定位是 open 虚高、mint 漏记还是 burn 漏记。
	if reason == "money_conservation_failed" or reason == "population_conservation_failed" \
			or reason == "goods_conservation_failed":
		var conservation := {
			"money_open": detail.get("money_open", "missing"),
			"money_close": detail.get("money_close", "missing"),
			"money_expected": detail.get("money_expected", "missing"),
			"explicit_money_mint": detail.get("explicit_money_mint", "missing"),
			"explicit_money_burn": detail.get("explicit_money_burn", "missing"),
			"opening_cohort_funds": detail.get("opening_cohort_funds", "missing"),
			"closing_cohort_funds": detail.get("closing_cohort_funds", "missing"),
			"opening_country_cash": detail.get("opening_country_cash", "missing"),
			"closing_country_cash": detail.get("closing_country_cash", "missing"),
			"opening_escrow_cash": detail.get("opening_escrow_cash", "missing"),
			"closing_escrow_cash": detail.get("closing_escrow_cash", "missing"),
			"opening_expedition_funds": detail.get("opening_expedition_funds", "missing"),
			"closing_expedition_funds": detail.get("closing_expedition_funds", "missing"),
			"producer_support_money_issued": detail.get(
				"producer_support_money_issued", "missing"),
			"bullion_money_issued": detail.get("bullion_money_issued", "missing"),
			"opening_audit_fast_paths": detail.get(
				"opening_audit_fast_paths", "missing"),
			"opening_audit_full_verifications": detail.get(
				"opening_audit_full_verifications", "missing"),
			"closing_audit_mode": detail.get("closing_audit_mode", "missing"),
		}
		print("[sim/economy-fatal-conservation] %s" % JSON.stringify(conservation))
	push_error("[economy] 原生经济 runtime 已 fatal（%s），仿真已在第 %d 天暂停以避免继续产出错误结果。"
		% [reason, day_index])
	if _generator._world_clock_ref != null and _generator._world_clock_ref.has_method("pause"):
		_generator._world_clock_ref.pause(true)
	_generator.economy_runtime_fatal.emit(day_index, reason, detail)



func _dispatch_runtime_graph_country_committed() -> void:
	if _generator._country_facade == null or not _generator._country_facade.is_configured():
		return
	var report: Dictionary = _generator._country_facade.report()
	var generation := int(report.get("generation", -1))
	if generation < 0:
		return
	if generation == _generator._runtime_graph_last_country_generation:
		return
	_generator._runtime_graph_last_country_generation = generation
	var territory_generation := int(report.get("territory_generation", -1))
	# 广播前先把 native 领土刷进 MapData：country_committed 监听方会立刻
	# refresh_country_visuals；若此时 country_slot_arr 仍是 CoW 旧镜像，
	# 视野源集会缺新 CLAIM 格，邻格只被迷雾柔边照亮却保持未探索。
	if territory_generation != _generator._runtime_graph_last_country_territory_generation \
			and _generator._data_core_world_ext != null :
		var sync_started_us := Time.get_ticks_usec()
		_generator._data_core_world_ext.sync_country_territory_to_map()
		_generator._runtime_graph_country_territory_sync_ms = \
			float(Time.get_ticks_usec() - sync_started_us) / 1000.0
	else:
		_generator._runtime_graph_country_territory_sync_ms = 0.0
	_generator._runtime_graph_last_country_territory_generation = territory_generation
	# 不能用最后一份 report 的 changed_* 在这里提前门控。同一个
	# pulse 里的后续 country slice 可能把领土提交摘要覆盖掉；
	# CountryFacade 会根据未消费的原生事件流归一化 changed_cells。
	var dispatch_started_us := Time.get_ticks_usec()
	_generator._country_facade.dispatch_committed_events(report)
	_generator._runtime_graph_country_event_dispatch_ms = \
		float(Time.get_ticks_usec() - dispatch_started_us) / 1000.0


## 返回本次 pulse 之后 country/economy 硬 barrier 是否还应该举着。
## status=3 表示"还有硬域 pending"，正常情况下会在同一天的几次 pulse 内落回 1/2。
## 同一天连续 pending 到 RUNTIME_GRAPH_STALL_RELEASE_PULSES 时判定为自锁并放行日历：
## 放行只是让 WorldClock 继续推进，pending 的域在后续日仍会被 pulse 继续 drain。

func _track_runtime_graph_stall(day_index: int, token_status: int) -> bool:
	if token_status != 3:
		_generator._runtime_graph_stall_day = -1
		_generator._runtime_graph_stall_pulses = 0
		_generator._runtime_graph_stall_released = false
		return false
	if day_index != _generator._runtime_graph_stall_day:
		_generator._runtime_graph_stall_day = day_index
		_generator._runtime_graph_stall_pulses = 0
	_generator._runtime_graph_stall_pulses += 1
	var latching = not _generator._runtime_graph_stall_released \
		and _generator._runtime_graph_stall_pulses >= _generator.RUNTIME_GRAPH_STALL_RELEASE_PULSES
	if latching:
		_generator._runtime_graph_stall_released = true
	if latching or (_generator._runtime_graph_stall_pulses >= _generator.RUNTIME_GRAPH_STALL_DIAG_PULSES \
			and (_generator._runtime_graph_stall_pulses - _generator.RUNTIME_GRAPH_STALL_DIAG_PULSES) \
				% _generator.RUNTIME_GRAPH_STALL_DIAG_STRIDE == 0):
		_generator._log_stalled_runtime_graph(day_index)
	return not _generator._runtime_graph_stall_released



func _log_stalled_runtime_graph(day: int) -> void:
	var snapshot: Dictionary = {}
	if _generator._data_core_world_ext != null :
		snapshot = _generator._data_core_world_ext.get_runtime_perf_snapshot(1)
	var pinned := PackedStringArray()
	for key in ["country_pending", "trigger_pending", "ideology_pending",
			"effect_pending", "modifier_pending", "gameplay_effect_pending",
			"economy_pending"]:
		if bool(snapshot.get(key, false)):
			pinned.append(String(key).trim_suffix("_pending"))
	print("[sim/graph-barrier] day=%d pulses=%d released=%s pinned=%s work=%s economy_slices=%s economy_commits=%s yields=%s last_us=%s trigger_blocked=%s/%s"
		% [day, _generator._runtime_graph_stall_pulses, str(_generator._runtime_graph_stall_released),
			",".join(pinned), str(snapshot.get("work_done", -1)),
			str(snapshot.get("economy_slices", -1)),
			str(snapshot.get("economy_commits", -1)),
			str(snapshot.get("budget_yields", -1)),
			str(snapshot.get("last_elapsed_us", -1)),
			str(snapshot.get("trigger_blocked_pulses", -1)),
			str(snapshot.get("trigger_blocked_reason", ""))])
	# 放行日历意味着某个硬域自锁了，仿真接下来是在"经济/效果落后于日历"的降级状态下
	# 继续跑。这不能只留在 stdout 里——它和经济 fatal 一样会污染后续账目。
	if _generator._runtime_graph_stall_released:
		push_warning("[sim] 原生 runtime graph 在第 %d 天自锁 %d 个 pulse（pinned=%s），已放行日历；该域的工作已落后于日历，结果不可信。"
			% [day, _generator._runtime_graph_stall_pulses, ",".join(pinned)])
	# Effect 是这个 barrier 历史上最常见的钉子（一个永远到不了 ACKED/REJECTED/
	# RESYNC_REQUIRED 的 transaction 会让 effect_should_run 恒真）。命中时多打一行
	# 事务状态直方图，直接区分是"卡住的事务"还是"到期的 due heap 实例"。
	if bool(snapshot.get("effect_pending", false)) and _generator._effect_facade != null:
		var effect_report: Dictionary = _generator._effect_facade.report()
		print("[sim/graph-barrier/effect] current_day=%s last_completed_day=%s planned=%s preflighted=%s committed=%s acked=%s rejected=%s resync=%s transactions=%s instances=%s country_ack_pending=%s economy_ack_pending=%s modifier_ack_pending=%s gameplay_ack_pending=%s country_acks=%s economy_acks=%s modifier_acks=%s"
			% [str(effect_report.get("current_day", -1)),
				str(effect_report.get("last_completed_day", -1)),
				str(effect_report.get("planned_transactions", -1)),
				str(effect_report.get("preflighted_transactions", -1)),
				str(effect_report.get("committed_transactions", -1)),
				str(effect_report.get("acked_transactions", -1)),
				str(effect_report.get("rejected_transactions", -1)),
				str(effect_report.get("resync_required_transactions", -1)),
				str(effect_report.get("transactions", -1)),
				str(effect_report.get("instances", -1)),
				str(effect_report.get("native_country_ack_pending", -1)),
				str(effect_report.get("native_economy_ack_pending", -1)),
				str(effect_report.get("native_modifier_ack_pending", -1)),
				str(effect_report.get("native_gameplay_ack_pending", -1)),
				str(effect_report.get("native_country_acks", -1)),
				str(effect_report.get("native_economy_acks", -1)),
				str(effect_report.get("native_modifier_acks", -1))])
	_generator._log_stalled_runtime_graph_authority(day)


## worker 的 RUNTIME_DAY_STALL_* 位（runtime_pod_protocol.h）。日历被钉住时这一位
## 直接点名「这一天在等什么」，比在 pinned 列表里猜快得多。0 = 当天自由，不是「没诊断」。

func _day_stall_reason_name(mask: int) -> String:
	if mask == 0:
		return "none"
	var parts := PackedStringArray()
	const NAMES := [
		"climate_capacity", "country_peer", "effect_ack", "ideology_ack",
		"fiscal_peer", "economy_input",
	]
	for bit in NAMES.size():
		if (mask & (1 << bit)) != 0:
			parts.append(String(NAMES[bit]))
	if parts.is_empty():
		return "0x%x" % mask
	return "|".join(parts)


## 12 个原生阶段的位名（runtime_pod_protocol.h 的 RuntimeDomainId，位序 = id-1）。
## 日历被 worker 钉住时，这张 mask 直接点名「哪个域的阶段今天还没跑完」。

func _domain_mask_names(mask: int) -> String:
	if mask == 0:
		return "none"
	const NAMES := [
		"input_capture", "climate", "country", "trigger", "ideology", "effect",
		"modifier", "gameplay_effect", "economy", "events", "visual", "commit",
	]
	var parts := PackedStringArray()
	for bit in NAMES.size():
		if (mask & (1 << bit)) != 0:
			parts.append(String(NAMES[bit]))
	return "|".join(parts) if not parts.is_empty() else "0x%x" % mask


## [sim/graph-barrier] 只说「哪个域 pinned」，对经济自锁的两种成因是同形的：
## economy_slices 每 pulse +64、economy_commits 恒 0、last_us 只有几百微秒（每次
## slice 都是空转）。两种成因都长这样：
##   1) 主线程 slice 被 `run_economy_slice_internal` 开头的 economy_worker_execution_owned
##      短路——worker 已经 requested ECONOMY、但 authoritative_domain_mask 里还没有那一位，
##      而 worker 自己也没在推进这一天；
##   2) worker 自己的 host 日提交不上，主线程又因为 (1) 不许接手。
## 分辨靠三样东西：requested/granted 的差、worker 停在哪个 economy stage/yield reason，
## 以及 `day_wait` 那行的日计划缺口——stall 位只描述外部等待，缺口不设位时它恒为 none，
## 那正是「日历推不动却一个错都不报」的形态。

func _log_stalled_runtime_graph_authority(day: int) -> void:
	var host: Dictionary = _generator.get_runtime_thread_report()
	if not host.is_empty():
		# ECONOMY 的 runtime_domain_mask 是 0x100。这里只打「请求了 / 授了没有」，
		# 不打整张 mask —— 十二域一起看反而读不出结论。
		var econ_mask := 1 << 8
		var requested := (int(host.get("requested_authority_mask", 0)) & econ_mask) != 0
		var granted := (int(host.get("authoritative_domain_mask", 0)) & econ_mask) != 0
		print("[sim/graph-barrier/host] day=%d state=%s econ_requested=%s econ_granted=%s inflight=%s stall=%s@%s sim_committed_day=%s sim_env_day=%s econ_input_day=%s econ_stage=%s/%s econ_yield=%s attempt_slices=%s wait_input_us=%s wait_boundary_us=%s"
			% [day,
				str(host.get("simulation_host_state", host.get("state", "?"))),
				str(requested), str(granted),
				str(host.get("worker_day_inflight", -1)),
				_generator._day_stall_reason_name(int(host.get("day_stall_reason_mask", 0))),
				str(host.get("day_stall_day", -1)),
				str(host.get("simulation_committed_day", -1)),
				str(host.get("simulation_environment_day", -1)),
				str(host.get("economy_input_requested_day", -1)),
				str(host.get("economy_stage_name", "")),
				str(host.get("economy_substage_name", "")),
				str(host.get("economy_yield_reason", "")),
				str(host.get("economy_attempt_slices", -1)),
				str(host.get("worker_time_input_wait_us", -1)),
				str(host.get("worker_time_boundary_wait_us", -1))])
		# worker 的日计划缺口：`missing` 是 requested & ~completed 的域位，
		# stall 位为 none 时它是唯一能说明「今天卡在哪个阶段」的东西。
		# park 那一栏是「那一行为什么放弃」，有些分支只 stage.completed=0 就
		# continue，不设 stall 位也不写 fallback reason，只能靠它归因。
		print("[sim/graph-barrier/day] day=%d waiting_day=%s missing=%s env_day=%s ring=%s stall=%s park=%s:%s"
			% [day,
				str(host.get("day_wait_day", -1)),
				_generator._domain_mask_names(int(host.get("day_wait_missing_mask", 0))),
				str(host.get("day_wait_env_day", -1)),
				str(host.get("day_wait_ring", -1)),
				_generator._day_stall_reason_name(int(host.get("day_stall_reason_mask", 0))),
				_generator._domain_mask_names(int(host.get("day_park_domain_mask", 0))),
				str(host.get("day_park_reason", ""))])
		# 每个域的 POD 阶段各自的 ready / fallback reason。「阶段没跑完」的最后
		# 一层归因：park 只说放弃的位置，这里说该域自己的状态机是什么结局。
		print("[sim/graph-barrier/pods] effect ready=%s gen=%s reason=%s inst_rejected=%s reject_detail=%s | modifier ready=%s reason=%s | ideology ready=%s reason=%s | events ready=%s failed_day=%s reason=%s | country_blocker=%s"
			% [str(host.get("effect_pod_ready", "?")),
				str(host.get("effect_pod_snapshot_generation", "?")),
				str(host.get("effect_pod_fallback_reason", "")),
				str(host.get("effect_instance_rejected_count", 0)),
				str(host.get("effect_instance_reject_detail", "")),
				str(host.get("modifier_pod_ready", "?")),
				str(host.get("modifier_pod_fallback_reason", "")),
				str(host.get("ideology_pod_ready", "?")),
				str(host.get("ideology_pod_fallback_reason", "")),
				str(host.get("events_pod_ready", "?")),
				str(host.get("events_failed_day", "?")),
				str(host.get("events_pod_fallback_reason", "")),
				str(host.get("country_pod_blocker", ""))])
	if _generator._economy_facade != null and _generator._economy_facade.has_method("report"):
		var economy: Dictionary = _generator._economy_facade.report()
		print("[sim/graph-barrier/econ] day=%d fatal=%s stage=%s exec=%s substage=%s epoch_active=%s current_day=%s last_committed_day=%s env_day=%s trade_plan=%s sample_day=%s last_completed_sample_day=%s"
			% [day,
				str(economy.get("fatal", "?")),
				str(economy.get("stage", "?")),
				str(economy.get("executed_stage", "?")),
				str(economy.get("substage", "?")),
				str(economy.get("epoch_active", "?")),
				str(economy.get("current_day", "?")),
				str(economy.get("last_committed_day", "?")),
				str(economy.get("environment_day", "?")),
				str(economy.get("trade_plan_phase", "?")),
				str(economy.get("sample_day", "?")),
				str(economy.get("last_completed_sample_day", "?"))])



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
	_generator._sus_map = map
	_generator._sus_world = world
	# 生成收尾即刻建立散布同步基线：此后任何 tick 级写入（含 season-0 reconcile、
	# 海冰、veg_dyn）都会在 finish_daily_tick 被 diff 捕获并补发散布刷新。
	_generator._loading_profile_step("scatter_snapshot")
	_generator._prime_scatter_sync_snapshot(map)
	await _generator._yield_generation_frame()
	# 创建一个全新 DCSystemScheduler 实例（regenerate 路径会让旧实例随
	# MapGenerator 一起被替换，不需要手动 reset_all_progress）。
	var cp_sched = _generator._c()
	_generator._sus = _generator.DCSystemSchedulerScript.new()
	_generator._sea_ice_daily_job = null
	_generator._weather_refresh_system = null
	_generator._weather_refresh_job = null
	_generator._ocean_currents_system = null
	_generator._ocean_currents_job = null
	_generator._sus.configure_from_profile(cp_sched)
	# DataCore World 接入（dots-foundation-and-weather-migration）：
	# 在 SUS 注册任何 job 前先把 World 实例创建出来并 bind 到 MapData，
	# 这样所有 register_job 会自动被注入 world 引用。
	#
	# dots-flag-prune-pr1 (2026-05-22)： use_data_core flag 已删除——DataCore 现
	# 恒挂载并 bind（不再区分 "创建但不 bind" 的 legacy 路径）。
	var dc_enabled: bool = true
	var cp_dc = _generator._c()
	_generator._data_core_world = DCWorld.new()
	if dc_enabled:
		# Reference-impl Pass #2 (performance-charter §12.6)：把 demo 开关透传，
		# 使 DCWorld 在 bind 阶段注册 CELL_DEMO_THERMAL_GRADIENT slot 并把
		# map.demo_thermal_gradient_arr resize 到 N。否则 baker 看到 size=0 全部
		# invalid，overlay 全屏空白（典型现象：stats min/max/mean=0、invalid=N）。
		var demo_tg_on: bool = false
		if cp_dc != null and "demo_thermal_gradient_enabled" in cp_dc:
			demo_tg_on = bool(cp_dc.demo_thermal_gradient_enabled)
		_generator._loading_profile_step("dc_world_bind")
		_generator._data_core_world.bind_map_data(map, demo_tg_on)
		await _generator._yield_generation_frame()
	_generator._sus.bind_world(_generator._data_core_world)

	# DataCore World — C++ co-processor（dots-roadmap-to-gdextension 务实 A）。
	# 与 _data_core_world 同时 bind 到同一份 MapData PackedArray。CoW alias 已在
	# Phase 3a Step 2.0 验证：两侧 view_f32 看到同一块底层 buffer；C++ Pass 写完后
	# 调一次 map.set("temp_arr", arr) 推回（snapshot contract，详见 world_ext.cpp）。
	# - 仅 use_data_core=true 时创建（与主 World 一致门控）
	# - NativeWorld.create 失败（GDExtension 未加载）→ 保持 null，climate Pass-A
	#   走 GDScript 路径，不报 error（dev 机器上不一定每次都构建过 gdext）
	# - 不注入 SUS.bind_world：weather / sus 子系统对此实例零感知，避免 weather
	#   迁移连锁（接口集差异详见 plan/dots-roadmap-to-gdextension/architecture.md §7）
	if dc_enabled:
		if ClassDB.class_exists("DCWorldExt"):
			var ext_obj: Object = _generator._data_core_world_ext if _generator._data_core_world_ext != null else _generator.NativeWorld.create()
			if ext_obj != null and ext_obj is RefCounted:
				_generator._data_core_world_ext = ext_obj
				# C++ _diag_logs_enabled 默认 true；创建/复用时同步 PKLog 状态，
				# 避免 PKLog 默认关闭下原生 diag print 仍然刷屏。
				_generator._data_core_world_ext.set_diag_logs_enabled(PKLog.enabled)
				_generator._loading_profile_step("native_world_bind")
				var ext_bound: bool = bool(_generator._data_core_world_ext.bind_map_data(map))
				await _generator._yield_generation_frame()
				print("[DataCore] _data_core_world_ext bound=%s (climate co-processor; class=DCWorldExt)" % str(ext_bound))
				_generator._dc_terrain_mirror_dirty = true
				_generator._reset_natural_resource_cadence(map.cell_count(), 0)
				if not ext_bound:
					push_warning("[DataCore] DCWorldExt.bind_map_data returned false; climate Pass-A C++ acceleration disabled (will fall back to DataCore/GDScript path)")
					_generator._data_core_world_ext = null
				else:
					if _generator._gameplay_event_bus != null:
						_generator._gameplay_event_bus.bind_world_ext(_generator._data_core_world_ext)
					# sea-ice-snow-visual-fix-2026-06：bind 后注入 DCWorld 句柄。C++ pass
					# `_flush_slot_to_map` 末尾会 call("mark_dirty_all")，让 atlas pipeline
					# 在下个 stride 通过 `read_and_clear_dirty_mask` 拿到信号。修复 wind_surface
					# / pass_b / ocean_* 写 slot 后 atlas 不知道脏 → 视觉冻结。
					if _generator._data_core_world != null:
						_generator._data_core_world_ext.bind_dirty_world(_generator._data_core_world)
					# Block B（master 手册 §4）：把 DCWorldExt 注入 MapBaker，
					# 让 _PHYS_STAGE_WIND 等 C++ hook 在启用 use_gdext_wind_field 时使用。
					if _generator._baker != null and _generator._baker.has_method("set_world_ext"):
						_generator._baker.set_world_ext(_generator._data_core_world_ext)
					_generator._configure_native_world_context(map, world, cfg, hex_size)
					# cpp-dots（native-generation-publish-2026-06）：生成期地图对象/拓扑仍由
					# GDScript 编排，SoA/slot 初始仿真字段由 C++ publish 成权威，再 flush 回
					# MapData。失败时保留 map.bake_lat_temp_year_lut 的 GDScript fallback。
					var native_gen_ok: bool = _generator._publish_native_generation_from_slots(map, cfg)
					if not native_gen_ok:
						# cpp-dots（temp-baseline-authority-2026-06）：cell_temp_baseline_year
						# （海冰 + 显示温度的运行期 baseline）权威计算归 C++。L1235 的
						# bake_lat_temp_year_lut 已用 GDScript fallback 填好 cell_lat_norm +
						# temp_baseline_year；ext 现已 bind，把 temp_baseline_year 交给 C++
						# pk_lat_temp_bell 权威重算并 flush 回 MapData（ext 未就绪则保留 GDScript 值）。
						_generator._bake_temp_baseline_year_native(map)
			else:
				push_warning("[DataCore] NativeWorld.create() returned null/non-RefCounted; gdext likely not loaded — climate C++ accel disabled")
		else:
			# GDExtension 没加载（开发机没编译 gdext / 平台不支持等），完全降级。
			# 不打 error 避免噪声，main.gd 的 [DataCore] flags 那行已能体现整体路径。
			print("[DataCore] DCWorldExt class not registered (gdext unavailable); climate Pass-A will use DataCore/GDScript path only")
	if _generator._data_core_world_ext == null and _generator._gameplay_event_bus != null:
		_generator._gameplay_event_bus.bind_world_ext(null)

	# PR-2.3a HexCell facade infra：bake_world / 加载存档末尾给每个 cell 注入 world
	# 引用 + facade flag。
	#
	# dots-flag-prune-pr1 (2026-05-22)： use_hexcell_facade flag 已删除——
	# facade 现恒启用（bind_world 第 2 参 _facade_on=true），热字段 getter/setter 全走
	# DCWorld view（PR-2.3c 已验收）。
	#
	# plan/3b-single-read-source：本段已从 _data_core_world 创建紧后移到此处，
	# 在 _data_core_world_ext 创建之后才 bind，使第 3 参 world_ext 能正确传入。
	# 当 ext 为 null（gdext 未编译 / bind_map_data 失败）时退化为旧 2 参行为，
	# facade getter 走 _world.read_*，与 PR-2.3c 实现 100% 等价。
	if dc_enabled:
		var _facade_on: bool = true
		var _cell_arr_for_bind: Array = map._cell_array
		var _n_cells_for_bind: int = _cell_arr_for_bind.size()
		_generator._loading_profile_step("cell_facade_bind")
		# dots-boot-facade-2026-10：bind_world() 的 cid 缓存只取决于
		# (DCWorld, DCWorldExt) 两侧的注册表，与具体 cell 无关，但原实现要逐格做
		# 39×2 次 component_id 查询 + 39 次 String.replace（2400 格 ≈ 19 万次调用，
		# Web 实测 520~1000ms）。这里改成「第 0 格走原路径顺手产出 cid 表，其余格
		# 直接注入同一份 PackedArray」，每格只剩 5 次属性赋值。
		# 任何一步不符合预期（脚本字段改名 / 拿不到 cid 表）→ 立即整体退回原循环。
		var _cid_gd := PackedInt32Array()
		var _cid_ext := PackedInt32Array()
		var _hoisted := false
		for _ci in range(_n_cells_for_bind):
			if _generator._generation_slice_due():
				await _generator._yield_generation_frame()
				_generator._generation_slice_start_usec = Time.get_ticks_usec()
			var _c_for_bind = _cell_arr_for_bind[_ci]
			if _c_for_bind == null or not _c_for_bind.has_method("bind_world"):
				continue
			if _ci == 0:
				_c_for_bind.bind_world(_generator._data_core_world, _facade_on, _generator._data_core_world_ext)
				_cid_gd = _generator._cell_facade_cids_of(_c_for_bind, &"_cid_array")
				_cid_ext = _generator._cell_facade_cids_of(_c_for_bind, &"_cid_array_ext")
				_hoisted = not _cid_gd.is_empty() and not _cid_ext.is_empty()
				continue
			if _hoisted and _generator._bind_cell_facade_with_cids(
					_c_for_bind, _facade_on, _cid_gd, _cid_ext):
				continue
			# 兜底：cid 表不可复用 → 逐格走原路径（与迁移前完全一致）。
			_hoisted = false
			_c_for_bind.bind_world(_generator._data_core_world, _facade_on, _generator._data_core_world_ext)
		if _facade_on:
			print("[hex_cell] facade ENABLED (%d cells bound; ext=%s; shared_cids=%s)" % [
				_n_cells_for_bind, str(_generator._data_core_world_ext != null), str(_cid_gd.size())])
	# DOTS-Final-Push 修复：把 ClimateProfile 直接注入 MapBaker。
	# 历史上 sea_ice prepare / albedo / veg_dyn / feedback 通过 `world.get("config")`
	# 取 cp 永远拿到 null（WorldData 上没有 config 字段），导致 use_native 一直 false，
	# sea_ice prepare 稳定 48ms GDScript 全图回扫。这里显式注入修正这一长期 bug。
	# 不被 dc_enabled 门控——GDScript 路径同样需要 cp.flag 做配置读取。
	if _generator._baker != null and _generator._baker.has_method("set_climate_profile"):
		var cp_for_baker = _generator._c()
		_generator._baker.set_climate_profile(cp_for_baker)
		print("[DataCore] _baker climate_profile injected=%s (fixes WorldData.config==null sea_ice prepare path)" % str(cp_for_baker != null))
	if cfg != null:
		cfg.climate_profile = _generator._c()
	if _generator._baker != null and _generator._baker.has_method("run_deferred_initial_physical_circulation"):
		_generator._loading_profile_step("deferred_physical_circulation")
		_generator._baker.run_deferred_initial_physical_circulation(map, world, hex_size, cfg)
	# per-cell LUT 同样推迟到这里：ext 已 bind、原生温度场已 publish，encode_cell_luts
	# 因此能走 C++ 并读到权威气候值。仍在 generate() 内，早于渲染器绑定 lut 纹理。
	if _generator._baker != null and _generator._baker.has_method("run_deferred_initial_cell_luts"):
		_generator._loading_profile_step("deferred_cell_luts")
		_generator._baker.run_deferred_initial_cell_luts(map, world)
	# Resource bootstrap must observe committed physical geography. It still
	# precedes economy bootstrap, and the explicit push keeps the native
	# snapshot slots identical to MapData after replacing PackedArrays.
	await _generator._yield_generation_frame()
	# dots-boot-facade-2026-10：资源勘测 → 槽发布 → 研究信号 → 生态播种四段原本是
	# 「GDScript 造数组 → native 单 pass」，每段之间还要 `_yield_generation_frame()`
	# 让帧（Web 非 headless 下每次等 4 帧）。现在整链压成一次 `run_boot_facade_pass`：
	# habitat 掩码 / 河口羽流两段 per-cell 循环搬进 C++，中间量不出语言边界。
	# native 不可用（旧 DLL）或任一段被拒 → 逐段走下面原链路，行为逐位不变。
	_generator._loading_profile_step("_bootstrap_world_facades")
	var _fused_boot = _generator._bootstrap_world_facades(map, cfg)
	_generator._loading_profile_step("natural_resource_deposits")
	if not _fused_boot:
		await _generator._get_map_resource_initializer()._bootstrap_natural_resource_deposits(map, cfg, true)
	await _generator._yield_generation_frame()
	_generator._loading_profile_step("publish_natural_resources")
	_generator._get_map_resource_initializer()._publish_bootstrapped_natural_resources_to_runtime(map)
	if not _fused_boot:
		await _generator._yield_generation_frame()
		_generator._loading_profile_step("resource_research_signals")
		_generator._append_natural_resource_research_signals(map)
		await _generator._yield_generation_frame()
		_generator._loading_profile_step("seed_bio_occupancy")
		_generator._seed_bio_occupancy(map)
	_generator._loading_profile_step("facade_bootstrap_tail_done")
	if not _generator._gameplay_start_context.is_empty():
		var gameplay_config: Dictionary = _generator._gameplay_start_context.get("config", {})
		var country_config: Dictionary = gameplay_config.get("country", {})
		_generator._gameplay_start_report = await _generator.StartLocationPolicyScript.select_and_prepare_cooperative(
			map,
			world,
			int(cfg.seed),
			int(country_config.get("foreign_count", NewGameConfig.DEFAULT_FOREIGN_COUNT)),
			String(country_config.get("name", "新国家")), _generator._loading_frames)
		if not bool(_generator._gameplay_start_report.get("ok", false)):
			return
		_generator._gameplay_start_context.merge(_generator._gameplay_start_report, true)
		if _generator._get_map_country_initializer()._gameplay_start_has_resource_topups(_generator._gameplay_start_report):
			await _generator._yield_generation_frame()
			_generator._loading_profile_step("_append_natural_resource_research_signals")
			_generator._append_natural_resource_research_signals(map)
			await _generator._yield_generation_frame()
			_generator._loading_profile_step("_publish_bootstrapped_natural_resources_to_runtime")
			_generator._get_map_resource_initializer()._publish_bootstrapped_natural_resources_to_runtime(map)
	# ─── Phase F.1：DCWorldExt 接管 weather field solve（charter §7 P0）──
	# 把 ext 句柄一次性下发给 WeatherSystem。ext 为 null（gdext 未编译 / 未 bind）
	# 时 WeatherSystem 自动走 GDScript legacy path，对 caller 完全透明。
	#
	# dots-flag-prune-pr1 (2026-05-22)： use_gdext_weather_field/distribute/summary
	# /weather_front 四个 flag 已删除——enabled 参数现恒传 true，WeatherSystem 内部
	# 走 ext+has_method+sig 探测单边分支。
	# PR-2.1.6：第 4 个参数注入 GDScript DCWorld，让 weather field commit 写路径
	# 走 world.write_f32_indexed。详见 master 手册 §3.9。
	if _generator._weather_system != null and _generator._weather_system.has_method("configure_gdext_acceleration"):
		var cp_f1 = _generator._c()
		_generator._weather_system.configure_gdext_acceleration(_generator._data_core_world_ext, true, cp_f1, _generator._data_core_world)
	# EffectRuntime is independent from Country/Economy. Configure and register
	# it before economy bootstrap, whose valid early returns must not starve it.
	_generator._effect_facade = null
	_generator._effect_daily_job = null
	_generator._gameplay_effect_job = null
	if _generator._data_core_world_ext != null:
		var effect_facade = _generator.EffectFacadeScript.new()
		await _generator._yield_generation_frame()
		_generator._loading_profile_step("effect_catalog")
		var effect_catalog = _generator.EffectDomainCatalogScript.build()
		await _generator._yield_generation_frame()
		_generator._loading_profile_step("effect_configure")
		if effect_catalog == null:
			push_error("[effect] domain catalog build failed")
		else:
			var effect_configured: Dictionary = effect_facade.configure(
				_generator._data_core_world_ext, _generator._world_clock_ref, effect_catalog)
			if bool(effect_configured.get("ok", false)):
				# `ok` 只代表主线程 EffectRuntime 吃下了目录。worker 侧还有第二份
				# POD 目录：编译失败时 `_effect_pod_catalog` 保持空，Effect 阶段就
				# 在 `effect_stage_enabled == false` 那一行无条件放弃、不设 stall 位、
				# 不写日志，于是整局只表现为「日历推不动」。这里必须响。
				if not bool(effect_configured.get("effect_pod_ready", true)):
					push_error(
						"[effect] native POD catalog not ready (%s) — worker Effect stage will park every day" % [
							String(effect_configured.get(
								"effect_pod_fallback_reason", "unknown"))])
				_generator._effect_facade = effect_facade
				_generator._effect_daily_job = _generator.EffectRuntimeSystemScript.new(_generator._effect_facade)
				_generator._sus.configure_job_from_profile(
					_generator._effect_daily_job, cp_sched, false, &"effect_runtime", 1)
				_generator._runtime_register_system(_generator._effect_daily_job)
				_generator._gameplay_effect_job = _generator.GameplayEffectSystemScript.new(_generator._effect_facade)
				_generator._sus.configure_job_from_profile(
					_generator._gameplay_effect_job, cp_sched, false, &"gameplay_effect", 1)
				_generator._runtime_register_system(_generator._gameplay_effect_job)
			else:
				push_error("[effect] configure failed: %s" % String(
					effect_configured.get("reason", "unknown")))
	# Independent ECONOMY_GRAPH is registered after EffectRuntime and before the
	# native/legacy daily fork, so both environmental authority modes share one
	# economy schedule.
	await _generator._yield_generation_frame()
	_generator._loading_profile_step("_setup_economy_runtime")
	await _generator._get_map_country_initializer()._setup_economy_runtime(map, cfg, cp_sched)
	_generator._season_refresh_job = _generator.SeasonRefreshSystemScript.new(_generator, map, world)
	_generator._sus.configure_job_from_profile(_generator._season_refresh_job, cp_sched)
	_generator._runtime_register_system(_generator._season_refresh_job)
	# dots-flag-prune-pr1 (2026-05-22)：ocean_current_refresh_seasons E 类废字段已
	# 从 ClimateProfile 删除——原有的 deprecated warning 不再需要。SUS 路径仅
	# 读 ocean_currents_period_ticks / ocean_currents_slice_count。
	var cp = _generator._c()
	var enum_atlas_stride: int = 2
	var dynamic_visual_atlas_stride: int = _generator._dyn_atlas_upload_stride
	if cp != null:
		if cp.get("enum_atlas_upload_stride") != null:
			enum_atlas_stride = clampi(int(cp.enum_atlas_upload_stride), 1, 8)
		if cp.get("dynamic_visual_atlas_upload_stride") != null:
			dynamic_visual_atlas_stride = clampi(int(cp.dynamic_visual_atlas_upload_stride), 1, 8)
	_generator._dyn_atlas_upload_stride = dynamic_visual_atlas_stride
	# 注册 OceanCurrentsJob。
	var wind_period_ticks: int = _generator._ocean_daily_wind_period_ticks_for(cp)
	var ocean_period_ticks: int = 30
	var slice_count: int = 10
	if cp != null:
		ocean_period_ticks = max(1, int(cp.ocean_currents_period_ticks))
		slice_count = max(1, int(cp.ocean_currents_slice_count))
	# Physical Wind & Ocean Circulation：把激活的 ClimateProfile 引用注入 cfg，
	# 让 MapBaker 在切片烘焙时（OceanCurrentsJob.run_slice 调用 baker.bake_*_slice）
	# 通过 cfg.climate_profile 读到 physical_circulation_enabled 等开关。null 时
	# 走 ny-only 旧路径。
	if cfg != null:
		cfg.climate_profile = cp
	# OceanCurrentsSystem 仍是 delegate wrapper；_ocean_currents_job 指向内部
	# job，保持 on_commit / season_phase_getter / 诊断访问路径不变。
	var ocean_sys = _generator.OceanCurrentsSystemScript.new(
			_generator._baker, map, world, cfg, hex_size, wind_period_ticks, slice_count, ocean_period_ticks)
	_generator._ocean_currents_system = ocean_sys
	_generator._ocean_currents_job = ocean_sys.get_inner()
	_generator._sus.configure_job_from_profile(ocean_sys, cp, false, &"ocean_currents", 1)
	_generator._sus.configure_job_from_profile(_generator._ocean_currents_job, cp, false, &"ocean_currents", 1)
	# A method Callable borrows self; an owned lambda retains the generator.
	_generator._ocean_currents_job.on_commit = _generator._compute_ocean_currents.bind(map, world, hex_size)
	if _generator._world_clock_ref != null:
		_generator._ocean_currents_job.season_phase_getter = Callable(_generator._world_clock_ref, "season_phase")
	_generator._runtime_register_system(ocean_sys)
	if _generator._ocean_currents_job != null:
		_generator._ocean_currents_job.data_core_world_ext = _generator._data_core_world_ext
		_generator._ocean_currents_job.climate_ran_this_tick_getter = Callable(_generator, "did_refresh_climate_run_this_tick")
		_generator._ocean_currents_job.climate_slice_ms_getter = Callable(_generator, "last_refresh_climate_slice_ms")
	# NaturalResourceDailySystem：自然资源每日生成/衰减（独立于气候的资源计算任务）。
	# **必须在 native/legacy 分叉之前注册**，作为与 season_refresh / ocean_currents 同级
	# 的"保留边界 job"——否则 native_daily ACTIVE 时下方 early-return 会跳过 legacy 段的
	# 注册，资源 reserve 永不演化（玩家观察不到生物质变化）。
	# reads cell.temp / cell.moisture（native_daily_sim 或 refresh_climate_daily 写）
	# → build_topology 自动排在气候之后；不加硬 depends_on（避免切片 job 长期 dep_pending）。
	var natural_resource_stride: int = 1
	if cp != null and cp.get("natural_resource_daily_stride") != null:
		natural_resource_stride = max(1, int(cp.natural_resource_daily_stride))
	_generator._natural_resource_daily_job = _generator.NaturalResourceDailySystemScript.new(_generator, map, natural_resource_stride)
	_generator._sus.configure_job_from_profile(_generator._natural_resource_daily_job, cp, false, &"natural_resource_daily", natural_resource_stride)
	_generator._runtime_register_system(_generator._natural_resource_daily_job)
	_generator._bio_occupancy_daily_job = _generator.BioOccupancyDailySystemScript.new(_generator, map, 8)
	_generator._sus.configure_job_from_profile(_generator._bio_occupancy_daily_job, cp, false, &"bio_occupancy_daily", 1)
	_generator._runtime_register_system(_generator._bio_occupancy_daily_job)
	# military_daily 同样必须注册在 native/legacy 分叉之前（contract §0.1）。整图
	# ACTIVE 时它的 should_run 恒 false，由 WorldRuntimeHost 在已提交日之后补跑；
	# 但注册本身要在分叉前完成，否则 ACTIVE→SHADOW/legacy 降级后没有任何 Military
	# 日阶段。未配置（旧 DLL / 目录缺失）时 _military_daily_job 保持 null。
	_generator._get_map_country_initializer()._maybe_register_military_system()
	await _generator._yield_generation_frame()
	_generator._loading_profile_step("if _try_register_native_daily_sim_job")
	if _generator._try_register_native_daily_sim_job(map, world):
		if OS.is_debug_build():
			print("[native_daily] ACTIVE: registered native_daily_sim + natural_resource_daily + bio_occupancy_daily; retained season_refresh + ocean_currents boundary jobs")
		_generator._register_visual_upload_jobs(map, world, hex_size, cp_sched)
		_generator._runtime_build_topology("native_daily path")
		if _generator._sus_bootstrap == null:
			_generator._sus_bootstrap = _generator.DCSusSystemsBootstrapScript.new(_generator)
		await _generator._yield_generation_frame()
		_generator._loading_profile_step("_sus_bootstrap.attach_post_setup")
		_generator._sus_bootstrap.attach_post_setup(_generator, _generator._sus)
		return

	# 注册 ClimateDailySystem + WeatherDCSystem。
	# stride 仍读取 ClimateProfile 的 cadence 字段；实际 phase/bucket 由
	# DCSystemScheduler.configure_job_from_profile() 统一解释。
	var climate_stride: int = 1
	var sea_ice_stride: int = 1
	var weather_stride: int = 1
	if cp != null:
		climate_stride = max(1, int(cp.daily_climate_refresh_stride))
		if cp.get("sea_ice_daily_stride") != null:
			sea_ice_stride = clampi(int(cp.sea_ice_daily_stride), 1, 8)
		weather_stride = max(1, int(cp.weather_refresh_stride))
	# ClimateDailySystem：写连续气候基线（priority 100）
	var climate_phase_getter := Callable()
	if _generator._world_clock_ref != null:
		climate_phase_getter = Callable(_generator._world_clock_ref, "season_phase")
	var climate_sys = _generator.ClimateDailySystemScript.new(_generator, map, climate_phase_getter, climate_stride)
	_generator._refresh_climate_daily_job = climate_sys.get_inner()
	_generator._sus.configure_job_from_profile(climate_sys, cp, false, &"refresh_climate_daily", climate_stride)
	_generator._sus.configure_job_from_profile(_generator._refresh_climate_daily_job, cp, false, &"refresh_climate_daily", climate_stride)
	_generator._runtime_register_system(climate_sys)
	# 注：natural_resource_daily 已在 native/legacy 分叉前作为保留边界 job 统一注册
	# （见上方 _try_register_native_daily_sim_job 之前的段落），此处不再重复注册。
	_generator._sea_ice_daily_job = null
	if cp != null and cp.get("sea_ice_independent_system_enabled") != null \
			and bool(cp.sea_ice_independent_system_enabled):
		_generator._sea_ice_daily_job = _generator.SeaIceDailySystemScript.new(_generator, map, climate_phase_getter, sea_ice_stride)
		_generator._sus.configure_job_from_profile(_generator._sea_ice_daily_job, cp, false, &"sea_ice_daily", sea_ice_stride)
		_generator._runtime_register_system(_generator._sea_ice_daily_job)
	if _generator._ocean_currents_job != null:
		_generator._ocean_currents_job.data_core_world_ext = _generator._data_core_world_ext
		_generator._ocean_currents_job.climate_ran_this_tick_getter = Callable(_generator, "did_refresh_climate_run_this_tick")
		_generator._ocean_currents_job.climate_slice_ms_getter = Callable(_generator, "last_refresh_climate_slice_ms")
	_generator._enum_atlas_upload_job = _generator.EnumAtlasUploadSystemScript.new(_generator, _generator._baker, map, world, hex_size, enum_atlas_stride, _generator._data_core_world_ext)
	_generator._sus.configure_job_from_profile(_generator._enum_atlas_upload_job, cp, true, &"enum_atlas_upload", enum_atlas_stride)
	_generator._runtime_register_system(_generator._enum_atlas_upload_job)
	# WeatherRefreshJob：天气推进 + 反馈链（priority 150，依赖 refresh_climate_daily）
	var season_idx_getter := Callable()
	var season_phase_getter := Callable()
	var climate_anomaly_getter := Callable()
	if _generator._world_clock_ref != null:
		season_idx_getter = Callable(_generator._world_clock_ref, "season_index")
		season_phase_getter = Callable(_generator._world_clock_ref, "season_phase")
		# climate_anomaly 是 WorldClock 的普通 property、不是方法，
		# Callable 只能绑方法，这里用 lambda 包一层读。
		var wc_ref = _generator._world_clock_ref
		climate_anomaly_getter = func() -> float:
			return float(wc_ref.climate_anomaly)
	var weather_dc_system = _generator.WeatherDCSystemScript.new(
		_generator, map, world,
		season_idx_getter, season_phase_getter, climate_anomaly_getter,
		weather_stride
	)
	_generator._weather_refresh_system = weather_dc_system
	_generator._weather_refresh_job = weather_dc_system.get_inner()
	_generator._sus.configure_job_from_profile(weather_dc_system, cp, false, &"weather_refresh", weather_stride)
	_generator._sus.configure_job_from_profile(_generator._weather_refresh_job, cp, false, &"weather_refresh", weather_stride)
	# Weather=0 fix（2026-05-13，与 weather_refresh_job.gd line 498-507 同源
	# 历史教训）：原 `_weather_refresh_job.depends_on.append(&"season_refresh")`
	# 把 weather 硬挂在 season_refresh 上，但 season 是 11-stage 切片 round
	# （每 round 前 10 个 stage 返回 done=false），weather 在 SUS 优先级序里
	# 排在 season 之后（150 > 50），只要 season 切片中 weather 立刻 dep_pending。
	# 实测 30 tick 内 weather ran=0（详见 docs/architecture/current-state.md 排查记录）。
	#
	# 真实依赖关系：weather hot loop 读的是 cell.temperature / moisture / wind /
	# has_river 等慢层 baseline——这些字段跟 season 切换的"植被/cover redecide"
	# 是正交的；即使 weather 读到旧 base_vegetation 一两 tick 也不影响 weather
	# field 求解（与 weather_refresh_job.gd 注释里描述的 climate dep 解除是同
	# 一类问题）。所以 weather 不应阻塞在 season 上。
	# _weather_refresh_job.depends_on.append(&"season_refresh")  # ← 移除（保留作历史记录）
	_generator._runtime_register_system(weather_dc_system)

	# WeatherLUT 发布直接内联在 WeatherRefreshJob 的 commit/merged/direct 完成点，避免独立 job
	# 的 should_run 相位早于 weather_refresh 时读到 ran_this_tick=false，也避免额外每 tick 扫描。

	# 海冰主视觉数据通道：水路径 shader 从 dyn_atlas_smooth_atlas.A 通道读取
	# sea_ice_fraction（与 UI/info_panel 同源；sea-ice-render-source-unify 阶段 A）。
	# 不再需要 sea_ice_atlas_upload 周期性光栅化 / GPU 上传作为 shader 主源；
	# 保留 sea_ice_tex 作为兼容空纹理，但不注册 SUS job。
	_generator._last_sea_ice_atlas_upload_breakdown = _generator._disabled_sea_ice_atlas_report("dyn_atlas_smooth_a_unified_source")
	# plan/dirty-push-atlas-encode 阶段 D：把 cp 传给 system，让其入口可调
	# DCFeatureFlags.is_on(&"dirty_push_enabled", cp) 决定是否走 mask 路径。
	_generator._dynamic_visual_atlas_upload_job = _generator.DynamicVisualAtlasUploadSystemScript.new(
			_generator._baker, map, world, _generator._dyn_atlas_upload_stride, cp, _generator._data_core_world,
			_generator._data_core_world_ext)
	_generator._sus.configure_job_from_profile(_generator._dynamic_visual_atlas_upload_job, cp, true, &"dynamic_visual_atlas_upload", _generator._dyn_atlas_upload_stride)
	_generator._runtime_register_system(_generator._dynamic_visual_atlas_upload_job)
	_generator._try_register_native_environment_runtime_system(map, cp)

	var topo_ok: bool = _generator._runtime_build_topology("cycle detected; fast tick will not run")
	if topo_ok and OS.is_debug_build():
		print("[map_generator] DCSystemScheduler topology built: %s" % str(_generator._sus.topology_order_names()))

	# Phase 1.4 — sus_systems_bootstrap attach。让 main.gd / debug overlay 能通过
	# generator.get_sus_bootstrap() 拿到 scheduler 引用做诊断 / 未来直接 tick。
	# 注意：实际注册逻辑仍在本函数内（Phase 3.4 拆分时才搬到 bootstrap.bootstrap()）。
	if _generator._sus_bootstrap == null:
		_generator._sus_bootstrap = _generator.DCSusSystemsBootstrapScript.new(_generator)
	await _generator._yield_generation_frame()
	_generator._loading_profile_step("_sus_bootstrap.attach_post_setup")
	_generator._sus_bootstrap.attach_post_setup(_generator, _generator._sus)
	if OS.is_debug_build():
		print("[map_generator] %s" % _generator._sus_bootstrap.status_one_liner())


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
	if _generator._world_clock_ref.has_signal("simulation_backpressure_pulse"):
		var continuation_cb := Callable(_generator, "_continue_economy_inflight")
		if not _generator._world_clock_ref.simulation_backpressure_pulse.is_connected(continuation_cb):
			_generator._world_clock_ref.simulation_backpressure_pulse.connect(continuation_cb)
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
