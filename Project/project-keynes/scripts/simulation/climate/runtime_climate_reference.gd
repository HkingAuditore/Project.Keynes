extends RefCounted

## Computes and publishes the Climate reference for input/output parity reports.

# Collects the OFF-path Climate state in the shape the canonical parity
# reduction expects. The field set is deliberately not written out here: it is
# read from the C++ table so the two sides cannot drift, and the reduction
# itself runs in C++ because hashing ~30 arrays per day in GDScript would be
# far too slow for a 1000-day comparison.

static func _collect_runtime_climate_parity_fields(capture, map: MapData) -> Dictionary:
	if map == null:
		return {"ok": false, "code": "climate_parity_reference_input_invalid"}
	if capture._generator._data_core_world_ext == null:
		return {"ok": false, "code": "climate_parity_field_table_missing"}
	var fields := {}
	fields["cell_count"] = int(map.cell_count())
	var anomaly := 0.0
	if capture._generator._world_clock_ref != null:
		var anomaly_value = capture._generator._world_clock_ref.get("climate_anomaly")
		if anomaly_value != null:
			anomaly = float(anomaly_value)
	fields["climate_anomaly"] = anomaly
	var absent: Array = []
	for entry in capture._generator._data_core_world_ext.get_runtime_climate_parity_fields():
		if String(entry.get("comparability", "")) != "comparable":
			continue
		var array_name := String(entry.get("map_data_array", ""))
		var value = _runtime_climate_parity_map_array(map, array_name)
		if value == null:
			absent.append(array_name)
			continue
		fields[String(entry.get("name", ""))] = value
	if not absent.is_empty():
		return {
			"ok": false,
			"code": "climate_parity_map_arrays_absent",
			"absent_arrays": absent,
		}
	return {"ok": true, "fields": fields}


# Returns null when MapData does not expose the array at all, which is a
# contract break rather than an empty field, and must not be hashed as zeros.

static func _runtime_climate_parity_map_array(map: MapData, array_name: String) -> Variant:
	if array_name == "":
		return null
	var value = map.get(array_name)
	if value == null:
		return null
	var value_type := typeof(value)
	if value_type != TYPE_PACKED_FLOAT32_ARRAY and value_type != TYPE_PACKED_INT32_ARRAY \
			and value_type != TYPE_PACKED_BYTE_ARRAY:
		return null
	return value

static func _runtime_climate_reference_ready_for_day(capture, day: int) -> bool:
	if not capture._generator._runtime_climate_trace_pending.has(day):
		return false
	var pending: Dictionary = capture._generator._runtime_climate_trace_pending[day]
	if bool(pending.get("reference_published", false)):
		return true
	# The native daily job owns Climate on the production path, where neither
	# ClimateDailySystem nor _generator._last_climate_breakdown exists. Checking for those
	# made this function return false forever, which silently disabled the whole
	# capture/reference barrier: frames were captured and never released, so the
	# SHADOW worker had nothing to compare against.
	if capture._generator._native_daily_sim_job != null:
		if capture._generator.native_daily_round_active():
			return false
		return capture._generator._native_daily_climate_round_generation > \
			int(pending.get("pass_generation_before", -1))
	if capture._generator._refresh_climate_daily_job == null:
		return false
	var state = capture._generator._native_daily_climate_round_state_snapshot()
	var before_generation := int(pending.get("pass_generation_before", -1))
	var current_generation := int(state.get("pass_generation", -1))
	var was_active := bool(pending.get("round_active_before", false))
	var active_now := bool(state.get("round_active", false))
	var finalizing_now := bool(state.get("finalize_pending", false))
	var cursor := int(state.get("pass_cursor", -1))
	var pass_count := int(state.get("pass_count", 0))
	var round_complete := cursor >= pass_count and pass_count > 0 \
			and not active_now and not finalizing_now
	var breakdown_done := not bool(capture._generator._last_climate_breakdown.get("partial", true)) \
			and String(capture._generator._last_climate_breakdown.get("pass_status", "")) in ["done", ""]
	# A new pass generation, or a previously active round transitioning to idle,
	# proves that the synchronous reference has reached its immutable boundary.
	if round_complete and breakdown_done and (current_generation > before_generation \
			or (was_active and not active_now)):
		return true
	# Climate can be skipped by SUS cadence. In that case the OFF state is
	# intentionally unchanged; releasing the captured frame still preserves the
	# exact input/output day contract and prevents an unbounded trace backlog.
	var ran_this_tick: bool = capture._generator._refresh_climate_daily_job.did_run_last_tick()
	return round_complete and breakdown_done and not ran_this_tick \
			and current_generation == before_generation and not was_active

static func _publish_runtime_climate_reference(capture, day: int, map: MapData = null) -> Dictionary:
	if map == null:
		map = capture._generator._sus_map
	if not capture._generator._runtime_climate_trace_pending.has(day):
		return capture._runtime_climate_failure("climate_trace_reference_frame_missing",
			"no captured input frame exists for this day", day)
	var pending: Dictionary = capture._generator._runtime_climate_trace_pending[day]
	if bool(pending.get("reference_published", false)):
		return {
			"ok": true,
			"already_published": true,
			"day": day,
			"state_hash": int(pending.get("reference_hash", 0)),
			"input_generation": int(pending.get("input_generation", 0)),
		}
	if not _runtime_climate_reference_ready_for_day(capture, day):
		return {
			"ok": false,
			"pending": true,
			"code": "climate_trace_reference_pending",
			"fallback_reason": "synchronous Climate round is not complete",
			"day": day,
		}
	var fields: Dictionary = _collect_runtime_climate_parity_fields(capture, map)
	if not bool(fields.get("ok", false)):
		var field_code := String(fields.get("code", "climate_parity_fields_unavailable"))
		return capture._runtime_climate_failure(field_code, field_code, day)
	if capture._generator._data_core_world_ext == null:
		return capture._runtime_climate_failure("runtime_worker_api_missing",
			"runtime climate reference API is unavailable", day)
	# Publish state and hash in one call: the hash is derived from the state on
	# the C++ side, so they cannot disagree, and retaining the state lets a
	# mismatch be reported per field and cell instead of as two numbers.
	var result: Dictionary = capture._generator._data_core_world_ext.publish_runtime_climate_reference_state(
		day, fields["fields"])
	if not bool(result.get("ok", false)):
		var code := String(result.get("code", "climate_trace_reference_publish_failed"))
		return capture._runtime_climate_failure(code, code, day)
	var state_hash := int(result.get("parity_hash", 0))
	# A parity hash uses all 64 bits, so a negative value is normal here; only
	# zero means the reduction produced nothing.
	if state_hash == 0:
		return capture._runtime_climate_failure("climate_trace_reference_hash_invalid",
			"reference Climate state hash is zero", day)
	pending["reference_published"] = true
	pending["reference_hash"] = state_hash
	pending["published_at_msec"] = Time.get_ticks_msec()
	capture._generator._runtime_climate_trace_pending[day] = pending
	capture._generator._runtime_climate_reference_last_day = day
	capture._generator._runtime_climate_reference_last_hash = state_hash
	capture._generator._runtime_climate_reference_last_error = ""
	# Keep enough history for diagnostics without allowing a long-running OFF
	# session to grow the GDScript dictionary indefinitely.
	var days: Array = capture._generator._runtime_climate_trace_pending.keys()
	days.sort()
	while days.size() > 64:
		capture._generator._runtime_climate_trace_pending.erase(days.pop_front())
	result["input_generation"] = int(pending.get("input_generation", 0))
	result["catalog_hash"] = int(pending.get("catalog_hash", 0))
	result["topology_generation"] = int(pending.get("topology_generation", 0))
	return result

static func _publish_ready_runtime_climate_references(capture, up_to_day: int,
		map: MapData = null) -> Dictionary:
	var aggregate: Dictionary = {
		"ok": true,
		"published_days": [],
		"pending_days": [],
		"last_result": {},
	}
	if up_to_day < 0:
		return aggregate
	var days: Array = capture._generator._runtime_climate_trace_pending.keys()
	days.sort()
	for raw_day in days:
		var pending_day := int(raw_day)
		if pending_day > up_to_day:
			break
		var pending: Dictionary = capture._generator._runtime_climate_trace_pending[raw_day]
		if bool(pending.get("reference_published", false)):
			continue
		var result := _publish_runtime_climate_reference(capture, pending_day, map)
		aggregate["last_result"] = result
		if bool(result.get("ok", false)):
			var published_days: Array = aggregate["published_days"]
			published_days.append(pending_day)
			aggregate["published_days"] = published_days
			continue
		var code := String(result.get("code", "climate_trace_reference_pending"))
		if code == "climate_trace_reference_pending":
			var pending_days: Array = aggregate["pending_days"]
			pending_days.append(pending_day)
			aggregate["pending_days"] = pending_days
			break
		aggregate["ok"] = false
		break
	return aggregate

static func runtime_climate_trace_report(capture) -> Dictionary:
	var pending_days: Array[int] = []
	for raw_day in capture._generator._runtime_climate_trace_pending.keys():
		pending_days.append(int(raw_day))
	pending_days.sort()
	return {
		"pending_days": pending_days,
		"pending_count": pending_days.size(),
		"input_generation": capture._generator._runtime_input_generation,
		"last_reference_day": capture._generator._runtime_climate_reference_last_day,
		"last_reference_hash": capture._generator._runtime_climate_reference_last_hash,
		"reference_failures": capture._generator._runtime_climate_reference_failures,
		"fallback_reason": capture._generator._runtime_climate_reference_last_error,
		"catalog_hash": capture._generator._runtime_climate_catalog_hash,
		"topology_generation": capture._generator._runtime_climate_topology_generation,
	}
