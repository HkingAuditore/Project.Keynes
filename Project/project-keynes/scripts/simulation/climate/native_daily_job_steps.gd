extends RefCounted

## Runs the native daily job and reports the result to the owning generator.


static func run_native_daily_slice_from_job(context, ctx: SusTickContext, _map: MapData, _world: WorldData) -> Dictionary:
	if not context._generator._native_daily_slice_available():
		return context._generator._native_daily_missing_slice_report()
	var wall_t0: int = Time.get_ticks_usec()
	var bundle_ms: float = 0.0
	var jit_patch_build_ms: float = 0.0
	var jit_patch_keys: PackedStringArray = PackedStringArray()
	if context._generator._native_daily_finalizer_pending:
		var res: Dictionary = context._generator._native_daily_finalizer_pending_res.duplicate()
		var breakdown: Dictionary = context._generator._native_daily_finalizer_pending_breakdown.duplicate()
		var complete_apply_diag: Dictionary = {}
		var rc_int: int = int(res.get("rc", 0))
		if rc_int == 0:
			var publish_t0: int = Time.get_ticks_usec()
			context._generator._get_native_daily_publish()._publish_native_daily_temperature_transport_anomaly(_map, context._generator._native_daily_slice_active_bundle, breakdown, res, true)
			context._generator._get_native_daily_publish()._native_daily_add_complete_apply_ms(
				complete_apply_diag,
				"complete_apply_publish_tta_ms",
				Time.get_ticks_usec() - publish_t0
			)
			if context._generator._native_daily_slice_unified_weather_embedded and context._generator._weather_system != null \
					and context._generator._weather_system.has_method("apply_unified_fast_tick_result"):
				var weather_t0: int = Time.get_ticks_usec()
				var fronts_out: Array[WeatherFront] = context._generator._weather_system.apply_unified_fast_tick_result(breakdown)
				context._generator._get_native_daily_publish()._native_daily_add_complete_apply_ms(
					complete_apply_diag,
					"complete_apply_weather_result_ms",
					Time.get_ticks_usec() - weather_t0
				)
				var visual_t0: int = Time.get_ticks_usec()
				context._generator._get_native_daily_publish()._apply_native_daily_visual_intents(res, breakdown, fronts_out, _map, _world)
				context._generator._get_native_daily_publish()._native_daily_add_complete_apply_ms(
					complete_apply_diag,
					"complete_apply_visual_intents_ms",
					Time.get_ticks_usec() - visual_t0
				)
			var finalizer_t0: int = Time.get_ticks_usec()
			var finalizer_diag: Dictionary = context._generator._get_native_daily_publish()._native_daily_apply_finalizer(_map)
			context._generator._get_native_daily_publish()._native_daily_add_complete_apply_ms(
				complete_apply_diag,
				"complete_apply_finalizer_ms",
				Time.get_ticks_usec() - finalizer_t0
			)
			var merge_t0: int = Time.get_ticks_usec()
			context._generator._get_native_daily_publish()._merge_native_daily_finalizer_diag(breakdown, finalizer_diag)
			context._generator._get_native_daily_publish()._merge_native_daily_finalizer_diag(res, finalizer_diag)
			context._generator._get_native_daily_publish()._native_daily_add_complete_apply_ms(
				complete_apply_diag,
				"complete_apply_finalizer_merge_ms",
				Time.get_ticks_usec() - merge_t0
			)
			var patch_t0: int = Time.get_ticks_usec()
			if _map != null and _map.temperature_transport_anomaly_arr.size() == _map.soa_size():
				res["temperature_transport_anomaly_out"] = _map.temperature_transport_anomaly_arr
			context._generator._get_native_daily_publish()._native_daily_add_complete_apply_ms(
				complete_apply_diag,
				"complete_apply_result_patch_ms",
				Time.get_ticks_usec() - patch_t0
			)
		context._generator._native_daily_finalizer_pending = false
		context._generator._native_daily_finalizer_pending_res = {}
		context._generator._native_daily_finalizer_pending_breakdown = {}
		context._generator._native_daily_slice_round_active = false
		context._generator._native_daily_slice_range_active = false
		var wrapper_wall_ms: float = float(Time.get_ticks_usec() - wall_t0) / 1000.0
		context._generator._get_native_daily_publish()._native_daily_install_complete_apply_diag(res, breakdown, complete_apply_diag, wrapper_wall_ms)
		context._generator._native_daily_round_apply_accum_ms += wrapper_wall_ms
		context._generator._native_daily_round_slice_count += 1
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
		res["round_bundle_ms"] = context._generator._native_daily_round_bundle_accum_ms
		res["round_native_call_ms"] = context._generator._native_daily_round_native_accum_ms
		res["round_apply_ms"] = context._generator._native_daily_round_apply_accum_ms
		res["round_slice_count"] = context._generator._native_daily_round_slice_count
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
		breakdown["round_bundle_ms"] = context._generator._native_daily_round_bundle_accum_ms
		breakdown["round_native_call_ms"] = context._generator._native_daily_round_native_accum_ms
		breakdown["round_apply_ms"] = context._generator._native_daily_round_apply_accum_ms
		breakdown["round_slice_count"] = context._generator._native_daily_round_slice_count
		context._generator._native_daily_stamp_contract(res, breakdown, ctx, rc_int == 0, "complete" if rc_int == 0 else "failed")
		res["breakdown"] = breakdown
		context._generator._get_native_daily_publish()._record_native_daily_slice_climate_breakdown(res, breakdown, _map, true, rc_int)
		context._generator._native_daily_last_result = res.duplicate()
		context._generator._native_daily_reset_contract_round()
		context._generator._native_daily_slice_unified_weather_embedded = false
		context._generator._native_daily_slice_bundle_pass_keys = []
		context._generator._native_daily_slice_active_bundle = {}
		context._generator._native_daily_slice_next_node_index = -1
		context._generator._native_daily_slice_phase_locked = 0.0
		context._generator._native_daily_slice_temp_start_arr = PackedFloat32Array()
		context._generator._native_daily_slice_tta_start_arr = PackedFloat32Array()
		context._generator._native_daily_slice_thermal_start_arr = PackedFloat32Array()
		return res
	var tick_knobs: Dictionary = context._generator._get_native_daily_bundle_builder()._native_daily_base_tick_knobs(ctx)
	var cp_range = context._generator._c()
	var range_contract: Dictionary = {}
	if cp_range != null and cp_range.get("native_daily_node_range_enabled") != null \
			and bool(cp_range.native_daily_node_range_enabled):
		range_contract = context._generator._native_daily_effective_node_range_config(cp_range, ctx, _map)
		tick_knobs["native_daily_node_range_cells"] = int(range_contract.get("effective_cells", 768))
		tick_knobs["native_daily_node_range_nodes"] = cp_range.native_daily_node_range_nodes \
				if cp_range.get("native_daily_node_range_nodes") != null else PackedStringArray()
	var starting_round: bool = not context._generator._native_daily_slice_round_active
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
		context._generator._get_native_daily_publish()._native_daily_capture_finalizer_start_state(_map)
		var bundle: Dictionary = context._generator._get_native_daily_bundle_builder()._build_native_daily_bundle(ctx, _map, _world, true, 1.0, false, true)
		bundle_ms = float(Time.get_ticks_usec() - bundle_t0) / 1000.0
		context._generator._native_daily_slice_active_bundle = bundle
		context._generator._native_daily_slice_unified_weather_embedded = bundle.has("weather_knobs")
		context._generator._native_daily_slice_bundle_pass_keys = context._generator._get_native_daily_bundle_builder()._native_daily_bundle_pass_keys(bundle)
		context._generator._native_daily_slice_next_node_index = 0
		context._generator._native_daily_slice_range_active = false
		context._generator._native_daily_slice_phase_locked = ctx.season_phase
		context._generator._native_daily_begin_contract_round(ctx)
		tick_knobs["native_daily_bundle"] = bundle
		# Tell C++ which nodes need a GDScript JIT patch so it can batch the rest
		# (non-yield consecutive nodes) into a single call → fewer round-trips.
		tick_knobs["native_daily_slice_yield_nodes"] = context._generator.native_daily_slice_yield_nodes_override \
				if not context._generator.native_daily_slice_yield_nodes_override.is_empty() \
				else context._generator._get_native_daily_bundle_builder()._native_daily_effective_yield_nodes(context._generator._c())
	else:
		tick_knobs["native_daily_continue"] = true
		var patch_t0: int = Time.get_ticks_usec()
		var patch: Dictionary = {}
		if not context._generator._native_daily_slice_range_active:
			patch = context._generator._get_native_daily_bundle_builder()._build_native_daily_slice_bundle_patch(
				context._generator._native_daily_slice_next_node_index,
				ctx,
				_map,
				_world)
		jit_patch_build_ms = float(Time.get_ticks_usec() - patch_t0) / 1000.0
		if not patch.is_empty():
			context._generator._get_native_daily_bundle_builder()._merge_native_daily_slice_patch_local(patch)
			tick_knobs["native_daily_bundle_patch"] = patch
			for k in patch.keys():
				jit_patch_keys.append(str(k))
			if patch.has("weather_knobs"):
				context._generator._native_daily_slice_unified_weather_embedded = true
			bundle_ms += jit_patch_build_ms
	var native_t0: int = Time.get_ticks_usec()
	var res: Dictionary = context._generator._data_core_world_ext.run_native_daily_slice(tick_knobs)
	var native_call_ms: float = float(Time.get_ticks_usec() - native_t0) / 1000.0
	res["bundle_pass_keys"] = context._generator._native_daily_slice_bundle_pass_keys
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
	breakdown["bundle_pass_keys"] = context._generator._native_daily_slice_bundle_pass_keys
	# Shallow copy (CoW-safe): only top-level keys are added; nested PackedArrays
	# share buffers instead of being byte-copied each slice.
	context._generator._diagnostics_bus.replace_weather_breakdown(breakdown, context._generator._current_fast_tick_idx)
	context._generator._dump_weather_breakdown_if_slow()
	var rc_int: int = int(res.get("rc", -1))
	var done: bool = bool(res.get("done", true))
	var climate_authority_suppressed: bool = bool(res.get("climate_authority_suppressed", breakdown.get("climate_authority_suppressed", false)))
	if rc_int == 0 and not climate_authority_suppressed and res.has("temperature_transport_anomaly_out"):
		# done → finalizer follows and re-writes the clamped TTA, so skip the dense write here.
		var publish_t0: int = Time.get_ticks_usec()
		context._generator._get_native_daily_publish()._publish_native_daily_temperature_transport_anomaly(_map, context._generator._native_daily_slice_active_bundle, breakdown, res, done)
		if done:
			context._generator._get_native_daily_publish()._native_daily_add_complete_apply_ms(
				complete_apply_diag,
				"complete_apply_publish_tta_ms",
				Time.get_ticks_usec() - publish_t0
			)
	var defer_finalizer: bool = rc_int == 0 and done and not climate_authority_suppressed and cp_range != null \
			and cp_range.get("native_daily_finalizer_slice_enabled") != null \
			and bool(cp_range.native_daily_finalizer_slice_enabled)
	if defer_finalizer:
		complete_apply_diag.clear()
		context._generator._native_daily_finalizer_pending = true
		context._generator._native_daily_finalizer_pending_res = res.duplicate()
		context._generator._native_daily_finalizer_pending_breakdown = breakdown.duplicate()
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
	if context._generator._native_daily_slice_unified_weather_embedded and context._generator._weather_system != null and not climate_authority_suppressed:
		if rc_int == 0 and done:
			if not context._generator._unified_fast_tick_first_log_done:
				context._generator._unified_fast_tick_first_log_done = true
				var weather_split_enabled := bool(breakdown.get("weather_split_enabled", false))
				var weather_split_skipped_monolithic := bool(breakdown.get("weather_split_skipped_monolithic", false))
				print("[native_daily/unified] native slice ACTIVE — weather_knobs embedded split=%s split_skipped_monolithic=%s; slice_ms=%.2f round_ms=%.2f weather_ms=%.2f"
						% [str(weather_split_enabled), str(weather_split_skipped_monolithic), float(breakdown.get("total_ms", 0.0)), float(breakdown.get("round_native_ms", res.get("round_native_ms", 0.0))), float(breakdown.get("weather_ms", 0.0))])
			if context._generator._weather_system.has_method("apply_unified_fast_tick_result"):
				var weather_t0: int = Time.get_ticks_usec()
				var fronts_out: Array[WeatherFront] = context._generator._weather_system.apply_unified_fast_tick_result(breakdown)
				context._generator._get_native_daily_publish()._native_daily_add_complete_apply_ms(
					complete_apply_diag,
					"complete_apply_weather_result_ms",
					Time.get_ticks_usec() - weather_t0
				)
				var visual_t0: int = Time.get_ticks_usec()
				context._generator._get_native_daily_publish()._apply_native_daily_visual_intents(res, breakdown, fronts_out, _map, _world)
				context._generator._get_native_daily_publish()._native_daily_add_complete_apply_ms(
					complete_apply_diag,
					"complete_apply_visual_intents_ms",
					Time.get_ticks_usec() - visual_t0
				)
		elif rc_int != 0:
			context._generator._weather_stage_b_call_index = maxi(0, context._generator._weather_stage_b_call_index - 1)
			if context._generator._weather_system.has_method("_clear_weather_field_slice_state"):
				context._generator._weather_system._clear_weather_field_slice_state()
			if not context._generator._unified_fast_tick_warned_fallback:
				context._generator._unified_fast_tick_warned_fallback = true
				push_warning("[native_daily/unified] native slice rc=%d fail_stage=%s; weather state cleared"
						% [rc_int, String(res.get("fail_stage", "unknown"))])
	context._generator._native_daily_slice_round_active = rc_int == 0 and not done
	context._generator._native_daily_slice_next_node_index = int(res.get("next_node_index", -1)) if context._generator._native_daily_slice_round_active else -1
	if rc_int == 0 and done and not climate_authority_suppressed:
		# Finalizer below re-writes the clamped TTA dense → skip the redundant raw dense write.
		var complete_publish_t0: int = Time.get_ticks_usec()
		context._generator._get_native_daily_publish()._publish_native_daily_temperature_transport_anomaly(_map, context._generator._native_daily_slice_active_bundle, breakdown, res, true)
		context._generator._get_native_daily_publish()._native_daily_add_complete_apply_ms(
			complete_apply_diag,
			"complete_apply_publish_tta_ms",
			Time.get_ticks_usec() - complete_publish_t0
		)
		var finalizer_t0: int = Time.get_ticks_usec()
		var finalizer_diag: Dictionary = context._generator._get_native_daily_publish()._native_daily_apply_finalizer(_map)
		context._generator._get_native_daily_publish()._native_daily_add_complete_apply_ms(
			complete_apply_diag,
			"complete_apply_finalizer_ms",
			Time.get_ticks_usec() - finalizer_t0
		)
		var merge_t0: int = Time.get_ticks_usec()
		context._generator._get_native_daily_publish()._merge_native_daily_finalizer_diag(breakdown, finalizer_diag)
		context._generator._get_native_daily_publish()._merge_native_daily_finalizer_diag(res, finalizer_diag)
		context._generator._get_native_daily_publish()._native_daily_add_complete_apply_ms(
			complete_apply_diag,
			"complete_apply_finalizer_merge_ms",
			Time.get_ticks_usec() - merge_t0
		)
		var result_patch_t0: int = Time.get_ticks_usec()
		if _map != null and _map.temperature_transport_anomaly_arr.size() == _map.soa_size():
			res["temperature_transport_anomaly_out"] = _map.temperature_transport_anomaly_arr
		context._generator._get_native_daily_publish()._native_daily_add_complete_apply_ms(
			complete_apply_diag,
			"complete_apply_result_patch_ms",
			Time.get_ticks_usec() - result_patch_t0
		)
	context._generator._native_daily_slice_range_active = rc_int == 0 and not done and bool(res.get("node_range_active", breakdown.get("node_range_active", false)))
	var active_deferred_node_count: int = int(context._generator._native_daily_slice_active_bundle.get("deferred_node_count", 0))
	var active_bundle_cache_hit: bool = bool(context._generator._native_daily_slice_active_bundle.get("bundle_cache_hit", false))
	var active_bundle_cache_rebuild_reason: String = str(context._generator._native_daily_slice_active_bundle.get("bundle_cache_rebuild_reason", ""))
	var active_bundle_static_ms: float = float(context._generator._native_daily_slice_active_bundle.get("bundle_static_ms", 0.0))
	var active_bundle_dynamic_ms: float = float(context._generator._native_daily_slice_active_bundle.get("bundle_dynamic_ms", bundle_ms))
	var active_weather_knobs_prebuilt: bool = bool(context._generator._native_daily_slice_active_bundle.get("weather_knobs_prebuilt", false))
	if not context._generator._native_daily_slice_round_active:
		context._generator._native_daily_finalizer_pending = false
		context._generator._native_daily_finalizer_pending_res = {}
		context._generator._native_daily_finalizer_pending_breakdown = {}
		context._generator._native_daily_slice_unified_weather_embedded = false
		context._generator._native_daily_slice_bundle_pass_keys = []
		context._generator._native_daily_slice_active_bundle = {}
		context._generator._native_daily_slice_next_node_index = -1
		context._generator._native_daily_slice_range_active = false
		context._generator._native_daily_slice_phase_locked = 0.0
		context._generator._native_daily_slice_temp_start_arr = PackedFloat32Array()
		context._generator._native_daily_slice_tta_start_arr = PackedFloat32Array()
		context._generator._native_daily_slice_thermal_start_arr = PackedFloat32Array()
	var wrapper_wall_ms: float = float(Time.get_ticks_usec() - wall_t0) / 1000.0
	var apply_ms: float = maxf(0.0, wrapper_wall_ms - bundle_ms - native_call_ms)
	if rc_int == 0 and done:
		context._generator._get_native_daily_publish()._native_daily_install_complete_apply_diag(res, breakdown, complete_apply_diag, apply_ms)
	if starting_round:
		context._generator._native_daily_round_bundle_accum_ms = 0.0
		context._generator._native_daily_round_native_accum_ms = 0.0
		context._generator._native_daily_round_apply_accum_ms = 0.0
		context._generator._native_daily_round_slice_count = 0
	context._generator._native_daily_round_bundle_accum_ms += bundle_ms
	context._generator._native_daily_round_native_accum_ms += native_call_ms
	context._generator._native_daily_round_apply_accum_ms += apply_ms
	context._generator._native_daily_round_slice_count += 1
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
		breakdown["round_bundle_ms"] = context._generator._native_daily_round_bundle_accum_ms
		breakdown["round_native_call_ms"] = context._generator._native_daily_round_native_accum_ms
		breakdown["round_apply_ms"] = context._generator._native_daily_round_apply_accum_ms
		breakdown["round_slice_count"] = context._generator._native_daily_round_slice_count
		res["round_bundle_ms"] = context._generator._native_daily_round_bundle_accum_ms
		res["round_native_call_ms"] = context._generator._native_daily_round_native_accum_ms
		res["round_apply_ms"] = context._generator._native_daily_round_apply_accum_ms
		res["round_slice_count"] = context._generator._native_daily_round_slice_count
	var contract_state: String = "active"
	var contract_committed: bool = false
	if rc_int != 0:
		contract_state = "failed"
	elif done:
		contract_state = "complete"
		contract_committed = true
	elif context._generator._native_daily_finalizer_pending:
		contract_state = "pending_finalizer"
	context._generator._native_daily_stamp_contract(res, breakdown, ctx, contract_committed, contract_state)
	res["breakdown"] = breakdown
	context._generator._get_native_daily_publish()._record_native_daily_slice_climate_breakdown(res, breakdown, _map, done, rc_int)
	# Shallow copy (CoW-safe): the scheduler/diagnostics read scalars + the fronts
	# object array; the large output arrays (e.g. temperature_transport_anomaly_out)
	# are shared by ref, not deep-copied each slice. native_daily_last_result() also
	# returns a shallow copy.
	context._generator._native_daily_last_result = res.duplicate()
	if rc_int != 0 or done:
		context._generator._native_daily_reset_contract_round()
	return res

static func run_native_daily_tick_from_job(context, ctx: SusTickContext, _map: MapData, _world: WorldData) -> Dictionary:
	if context._generator._data_core_world_ext == null:
		return { "rc": -1, "fail_stage": "gdext_unavailable" }
	var wall_t0: int = Time.get_ticks_usec()
	var bundle_t0: int = wall_t0
	if _map != null and _map.has_soa() and _map.has_method("soa_begin_climate_transaction"):
		_map.soa_begin_climate_transaction()
	var bundle: Dictionary = context._generator._get_native_daily_bundle_builder()._build_native_daily_bundle(ctx, _map, _world, true)
	var bundle_ms: float = float(Time.get_ticks_usec() - bundle_t0) / 1000.0
	var unified_weather_embedded: bool = bundle.has("weather_knobs")
	var tick_knobs: Dictionary = context._generator._get_native_daily_bundle_builder()._native_daily_base_tick_knobs(ctx)
	tick_knobs["native_daily_bundle"] = bundle
	var native_t0: int = Time.get_ticks_usec()
	var res: Dictionary = context._generator._data_core_world_ext.run_native_daily_tick(tick_knobs)
	var native_call_ms: float = float(Time.get_ticks_usec() - native_t0) / 1000.0
	res["bundle_pass_keys"] = context._generator._get_native_daily_bundle_builder()._native_daily_bundle_pass_keys(bundle)
	var breakdown: Dictionary = res.get("breakdown", {})
	context._generator._diagnostics_bus.replace_weather_breakdown(breakdown, context._generator._current_fast_tick_idx)
	# 方案 ④ Step 1：标记本帧 fast tick，perf_recorder 据此过滤 stale 回放
	# 5/21 突刺诊断：weather_tick≥5ms 或 cyclone≥3ms 时打全字段
	context._generator._dump_weather_breakdown_if_slow()
	# Phase A.2 unified fast tick：成功路径下同步 weather state（fronts + cyclone +
	# cover_dirty + slice cleanup）。失败路径下回滚 stage_b call_index 并清 slice state
	# 让下次有机会重试 / 让独立 weather_refresh_job 接手（如果它被注册）。
	if unified_weather_embedded and context._generator._weather_system != null:
		var rc_int: int = int(res.get("rc", -1))
		if rc_int == 0:
			if not context._generator._unified_fast_tick_first_log_done:
				context._generator._unified_fast_tick_first_log_done = true
				print("[native_daily/unified] gdext path ACTIVE — weather_knobs embedded in native_daily_bundle; 16-pass single-marshal tick first run total_ms=%.2f weather_ms=%.2f"
						% [float(breakdown.get("total_ms", 0.0)), float(breakdown.get("weather_ms", 0.0))])
			if context._generator._weather_system.has_method("apply_unified_fast_tick_result"):
				# breakdown 顶层就是 weather 段产出（C++ 端 copy_dict_into 把
				# run_weather_refresh_daily_pass 返回值合进 native_daily breakdown）。
				var fronts_out: Array[WeatherFront] = context._generator._weather_system.apply_unified_fast_tick_result(breakdown)
				context._generator._get_native_daily_publish()._apply_native_daily_visual_intents(res, breakdown, fronts_out, _map, _world)
		else:
			# 失败回滚：stage_b call_index 还原 + 清理 slice state（weather_system 内部
			# 已自我守护，但 caller 端也防御性清一次，避免泄漏到下个 tick）。
			context._generator._weather_stage_b_call_index = maxi(0, context._generator._weather_stage_b_call_index - 1)
			if context._generator._weather_system.has_method("_clear_weather_field_slice_state"):
				context._generator._weather_system._clear_weather_field_slice_state()
			if not context._generator._unified_fast_tick_warned_fallback:
				context._generator._unified_fast_tick_warned_fallback = true
				push_warning("[native_daily/unified] embedded weather_knobs path rc=%d fail_stage=%s; weather_refresh state cleared; will fallback to independent jobs next tick"
						% [rc_int, String(res.get("fail_stage", "unknown"))])
	if int(res.get("rc", -1)) == 0:
		context._generator._get_native_daily_publish()._publish_native_daily_temperature_transport_anomaly(_map, bundle, breakdown, res)
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
	context._generator._native_daily_last_result = res.duplicate(true)
	return res
