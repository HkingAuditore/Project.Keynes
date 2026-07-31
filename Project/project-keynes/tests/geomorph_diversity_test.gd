extends SceneTree

# Headless:
#   godot --headless --path . --script res://tests/geomorph_diversity_test.gd --quit

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	print("[geomorph-diversity] checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt class is unavailable")
		return
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	if ext == null or not ext.has_method("run_native_world_generate_full_pass"):
		_fail("native full generation pass is unavailable")
		return

	var cfg := {
		"width": 60,
		"height": 40,
		"num_continents": 5,
		"sea_level": 0.10,
		"continent_size": 0.82,
	}
	var profile := {
		"native_generation_mode": 2,
		"relief_thresh_scale_exp": 0.25,
	}
	var result: Dictionary = ext.call("run_native_world_generate_full_pass", 20260731, cfg, profile)
	_expect("generation succeeds", int(result.get("rc", -1)) == 0)
	_expect("60x40 cell count", int(result.get("n_cells", 0)) == 2400)
	_expect("small-map relief scale stays moderate", is_equal_approx(float(result.get("relief_thresh_scale", 0.0)), pow(6.25, 0.25)))
	_expect("mountain height gate is reachable", int(result.get("mountain_height_candidates", 0)) > 0)
	_expect("mountain relief gate is reachable", int(result.get("mountain_relief_candidates", 0)) > 0)
	_expect("mountains survive post-base thinning", int(result.get("mountain_kept", 0)) > 0)
	_expect("peak candidates are reachable", int(result.get("peak_candidate_count", 0)) > 0)
	var landforms: PackedByteArray = result.get("landform_arr", PackedByteArray())
	var mountain_count := landforms.count(7)
	var peak_count := landforms.count(8)
	var plateau_count := landforms.count(13)
	_expect("final map contains mountains", mountain_count > 0)
	_expect("final map contains peaks", peak_count > 0)
	_expect("final map contains plateaus", plateau_count > 0)
	print("[geomorph-diversity] height=%d relief=%d kept=%d peak_candidates=%d mountain=%d peak=%d plateau=%d scale=%.4f" % [
		int(result.get("mountain_height_candidates", 0)),
		int(result.get("mountain_relief_candidates", 0)),
		int(result.get("mountain_kept", 0)),
		int(result.get("peak_candidate_count", 0)),
		mountain_count,
		peak_count,
		plateau_count,
		float(result.get("relief_thresh_scale", 0.0)),
	])


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_fail(label)


func _fail(label: String) -> void:
	_failures += 1
	printerr("[geomorph-diversity] FAIL: %s" % label)
