extends SceneTree

# Headless:
#   godot --headless --script tests/native_daily_graph_order_test.gd --quit
#
# Locks the native daily climate prefix to the retained ClimateDailySystem order.
# Humidity pass-b must run before ocean heat transport so it reads the
# round-start TTA instead of the same-day ocean update.

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	print("=== native daily graph order ===")
	var daily_src: String = _read_source("res://../../gdext/src/world_ext_daily_sim.cpp")
	var schedule_src: String = _read_source("res://../../gdext/src/system_schedule.cpp")
	var generator_src: String = _read_source("res://scripts/geography/map_generator.gd")

	_expect("world_ext_daily_sim.cpp readable", not daily_src.is_empty())
	_expect("system_schedule.cpp readable", not schedule_src.is_empty())
	_expect("map_generator.gd readable", not generator_src.is_empty())
	if _failures > 0:
		_finish()
		return

	var slice_graph: String = _section(daily_src,
			"static const NativeDailySliceNode NATIVE_DAILY_SLICE_GRAPH[] = {",
			"static const int NATIVE_DAILY_SLICE_GRAPH_SIZE")
	_expect("slice graph keeps pass_b before ocean", _contains_in_order(slice_graph, [
		"\"climate_pass_a\"",
		"\"climate_pass_b\"",
		"\"ocean_water\"",
		"\"ocean_land\"",
		"\"wind_air\"",
		"\"wind_surface\"",
	]))

	var full_run: String = _section(daily_src,
			"Dictionary cp_struct = as_dict(bundle[\"climate_pass_a_struct\"])",
			"if (bundle.has(\"wind_air_knobs\"))")
	_expect("full-run helper keeps pass_b before ocean", _contains_in_order(full_run, [
		"run_climate_pass_a",
		"run_climate_pass_b",
		"run_ocean_water_pass",
		"run_ocean_land_pass",
	]))

	var schedule_graph: String = _section(schedule_src,
			"const SystemNode SCHEDULE_GRAPH[] = {",
			"const int SCHEDULE_GRAPH_SIZE")
	_expect("system schedule keeps pass_b before ocean", _contains_in_order(schedule_graph, [
		"\"climate_pass_a\"",
		"\"climate_pass_b\"",
		"\"ocean_water\"",
		"\"ocean_land\"",
		"\"wind_air\"",
		"\"wind_surface\"",
	]))

	var patch_builder: String = _section(generator_src,
			"func _build_native_daily_slice_bundle_patch(",
			"func _native_daily_bundle_pass_keys(")
	_expect("slice patch refreshes deferred native daily nodes in graph order", _contains_in_order(patch_builder, [
		"match next_node_index:",
		"1:",
		"climate_pass_b_knobs",
		"2:",
		"ocean_water_knobs",
		"ocean_land_knobs",
		"4:",
		"wind_air_knobs",
		"wind_surface_knobs",
		"6:",
		"sea_ice_knobs",
		"7:",
		"transpiration_knobs",
	]))

	# Node-batching contract is cadence-dependent (see _native_daily_effective_yield_nodes):
	#   - ATOMIC (default): minimal {2,6} — only ocean_water/sea_ice repack data upstream
	#     passes changed; every other node runs bit-equal with its round-start knobs
	#     (validated by tmp_native_batch_bitequal_test.gd). Fewest round-trips/round.
	#   - SPREAD (native_daily_spread_across_ticks): full {0..14} — yielding more is purely
	#     bit-equal (extra checkpoints), and the finer granularity gives the lowest per-tick
	#     peak (mean 3.14→1.95ms in tmp_native_spread_validate.gd). The {2,6} patch cases
	#     still fire on those indices; no new patch case is required for the extra yields.
	# Deferred nodes are also added to C++ yield bits at round start, so atomic mode can
	# keep its historical explicit yield constant while lazy knobs still get a patch.
	_expect("atomic yield-set constant is the minimal {2,6}", _contains_in_order(generator_src, [
		"const _NATIVE_DAILY_SLICE_YIELD_NODES: Array[int] = [2, 6]",
	]))
	_expect("spread yield-set + mode selector exist", _contains_in_order(generator_src, [
		"const _NATIVE_DAILY_SLICE_YIELD_NODES_SPREAD: Array[int] = [",
		"func _native_daily_effective_yield_nodes(",
		"native_daily_spread_across_ticks",
	]))
	_expect("deferred node declaration reaches C++", _contains_in_order(generator_src, [
		"native_daily_deferred_nodes",
		"deferred_node_count",
	]))
	_expect("C++ slice consumes the yield-node hint", _contains_in_order(daily_src, [
		"native_daily_slice_yield_nodes",
		"_native_daily_slice_yield_bits",
	]))

	_finish()


func _read_source(path: String) -> String:
	var global_path: String = ProjectSettings.globalize_path(path)
	var file := FileAccess.open(global_path, FileAccess.READ)
	if file == null:
		return ""
	return file.get_as_text()


func _section(source: String, start_marker: String, end_marker: String) -> String:
	var start: int = source.find(start_marker)
	if start < 0:
		return ""
	var end: int = source.find(end_marker, start + start_marker.length())
	if end < 0:
		return source.substr(start)
	return source.substr(start, end - start)


func _contains_in_order(source: String, needles: Array[String]) -> bool:
	var pos: int = 0
	for needle in needles:
		var next_pos: int = source.find(needle, pos)
		if next_pos < 0:
			return false
		pos = next_pos + needle.length()
	return true


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if ok:
		print("[OK] ", label)
	else:
		_failures += 1
		push_error("[FAIL] %s" % label)


func _finish() -> void:
	if _failures == 0:
		print("PASS native daily graph order (%d checks)" % _checks)
	else:
		print("FAIL native daily graph order (%d failures / %d checks)" % [_failures, _checks])
