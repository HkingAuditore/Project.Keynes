extends SceneTree

# Headless:
#   godot --headless --script tests/native_generation_equivalence_test.gd --quit
#
# NativeWorldGenerator API smoke test. The native generation surface is now
# implemented as a C++ DOTS publish pass after MapData binding; without a bound
# MapData it must report an explicit fallback instead of the old unimplemented
# stub.

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	print("=== native generation API smoke ===")
	if not ClassDB.class_exists("DCWorldExt"):
		_skip("DCWorldExt class not found")
		return
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	if ext == null:
		_skip("DCWorldExt instantiate returned null")
		return

	_expect("start_native_generation exported", ext.has_method("start_native_generation"))
	_expect("run_native_generation_slice exported", ext.has_method("run_native_generation_slice"))
	_expect("finish_native_generation exported", ext.has_method("finish_native_generation"))
	_expect("run_native_world_generate_base_pass exported", ext.has_method("run_native_world_generate_base_pass"))
	_expect("run_native_world_generate_post_base_pass exported", ext.has_method("run_native_world_generate_post_base_pass"))
	_expect("run_native_world_generate_pass exported", ext.has_method("run_native_world_generate_pass"))
	if not ext.has_method("start_native_generation"):
		_finish()
		return

	var start: Dictionary = ext.call("start_native_generation", 12345, {"cell_count": 64}, {"profile": "test"})
	_expect("generation start accepted", int(start.get("rc", -1)) == 0)
	_expect("generation reports implemented flag", bool(start.get("implemented", false)))
	_expect("generation start has no publication yet", not bool(start.get("published_to_slot", true)))

	var step: Dictionary = ext.call("run_native_generation_slice", {"budget_ms": 0.25})
	_expect("unbound generation slice falls back explicitly", int(step.get("rc", 0)) == -1)
	_expect("unbound generation fallback is explicit", bool(step.get("fallback", false)))
	_expect("unbound generation reason is not_bound", str(step.get("fallback_reason", "")) == "not_bound")
	_expect("unbound generation reports no publication", not bool(step.get("published_to_slot", true)))

	var finish: Dictionary = ext.call("finish_native_generation")
	_expect("finish returns last unbound failure", int(finish.get("rc", 0)) == -1)
	_expect("finish keeps explicit fallback reason", str(finish.get("fallback_reason", "")) == "not_bound")
	_expect("generation progress remains zero while unbound", float(finish.get("generation_progress", -1.0)) == 0.0)

	if ext.has_method("run_native_world_generate_pass"):
		var direct: Dictionary = ext.call("run_native_world_generate_pass", 12345, {"cell_count": 64}, {})
		_expect("direct generation pass unbound fallback", int(direct.get("rc", 0)) == -1)
		_expect("direct generation reason is not_bound", str(direct.get("fallback_reason", "")) == "not_bound")
	if ext.has_method("run_native_world_generate_base_pass"):
		var base_cfg := {
			"width": 8,
			"height": 6,
			"num_continents": 2,
			"sea_level": 0.64,
			"continent_size": 0.8,
		}
		var base_res: Dictionary = ext.call("run_native_world_generate_base_pass", 12345, base_cfg, {"native_generation_mode": 2})
		var n: int = 8 * 6
		_expect("base generation succeeds unbound", int(base_res.get("rc", -1)) == 0)
		_expect("base generation path is gdext", str(base_res.get("path", "")) == "gdext")
		_expect("base generation does not publish slots", not bool(base_res.get("published_to_slot", true)))
		_expect("base generation reports expected n", int(base_res.get("n_cells", 0)) == n)
		_expect("base generation has q array", typeof(base_res.get("q_arr", null)) == TYPE_PACKED_INT32_ARRAY and base_res["q_arr"].size() == n)
		_expect("base generation has elevation array", typeof(base_res.get("elevation_arr", null)) == TYPE_PACKED_FLOAT32_ARRAY and base_res["elevation_arr"].size() == n)
		_expect("base generation has terrain array", typeof(base_res.get("terrain_arr", null)) == TYPE_PACKED_BYTE_ARRAY and base_res["terrain_arr"].size() == n)
		if ext.has_method("run_native_world_generate_post_base_pass"):
			var post_res: Dictionary = ext.call("run_native_world_generate_post_base_pass", 12345, base_cfg, {"native_generation_mode": 2}, base_res)
			_expect("post-base generation succeeds unbound", int(post_res.get("rc", -1)) == 0)
			_expect("post-base generation path is gdext", str(post_res.get("path", "")) == "gdext")
			_expect("post-base generation does not publish slots", not bool(post_res.get("published_to_slot", true)))
			_expect("post-base generation reports expected n", int(post_res.get("n_cells", 0)) == n)
			_expect("post-base generation has landform array", typeof(post_res.get("landform_arr", null)) == TYPE_PACKED_BYTE_ARRAY and post_res["landform_arr"].size() == n)
			_expect("post-base generation has river array", typeof(post_res.get("has_river_arr", null)) == TYPE_PACKED_BYTE_ARRAY and post_res["has_river_arr"].size() == n)
			_expect("post-base generation has volcano array", typeof(post_res.get("has_volcano_arr", null)) == TYPE_PACKED_BYTE_ARRAY and post_res["has_volcano_arr"].size() == n)
	_finish()


func _skip(reason: String) -> void:
	print("  [SKIP] %s" % reason)
	_finish()


func _finish() -> void:
	print("=== done: %d checks, %d failures ===" % [_checks, _failures])


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if ok:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		printerr("  [FAIL] %s" % label)
