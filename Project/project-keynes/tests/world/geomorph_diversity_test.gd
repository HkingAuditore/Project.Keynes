extends SceneTree

# Headless:
#   godot --headless --path . --script res://tests/world/geomorph_diversity_test.gd --quit

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
	_test_generation_controls(ext)


func _test_generation_controls(ext: Object) -> void:
	var generator := MapGenerator.new()
	generator.climate_profile = ClimateProfile.new()
	var bridge := generator._get_native_generation_bridge()
	var cfg := MapConfig.make(60, 40)
	cfg.sea_level = 0.50
	cfg.num_continents = 2
	cfg.continent_size = 0.50
	var cfg_dict: Dictionary = bridge.native_generation_cfg_dict(cfg)
	var standard: Dictionary = bridge.native_generation_profile_dict(cfg)
	_expect("neutral generation settings preserve profile", standard == bridge.native_generation_profile_dict())

	cfg.terrain_ruggedness = 0
	var smooth: Dictionary = ext.run_native_world_generate_full_pass(20260731, cfg_dict,
		bridge.native_generation_profile_dict(cfg))
	cfg.terrain_ruggedness = 100
	var rugged: Dictionary = ext.run_native_world_generate_full_pass(20260731, cfg_dict,
		bridge.native_generation_profile_dict(cfg))
	cfg.terrain_ruggedness = MapConfig.DEFAULT_GENERATION_LEVEL
	cfg.terrain_diversity = 0
	var uniform: Dictionary = ext.run_native_world_generate_full_pass(20260731, cfg_dict,
		bridge.native_generation_profile_dict(cfg))
	cfg.terrain_diversity = 100
	var diverse: Dictionary = ext.run_native_world_generate_full_pass(20260731, cfg_dict,
		bridge.native_generation_profile_dict(cfg))
	for result in [smooth, rugged, uniform, diverse]:
		_expect("configured map generation succeeds", int(result.get("rc", -1)) == 0)
		if int(result.get("rc", -1)) != 0:
			return
	_expect("rugged world has more neighbor elevation contrast",
		_land_elevation_contrast(rugged, cfg.width) > _land_elevation_contrast(smooth, cfg.width))
	for field in ["landform_arr", "vegetation_arr"]:
		_expect("diversity increases the variety of %s" % field,
			_land_category_entropy(diverse[field], diverse.is_water_arr)
			> _land_category_entropy(uniform[field], uniform.is_water_arr))
	cfg.map_source = "pkmap"
	_expect("authored maps keep the standard profile", bridge.native_generation_profile_dict(cfg) == standard)


func _land_elevation_contrast(result: Dictionary, width: int) -> float:
	var elevation: PackedFloat32Array = result.elevation_arr
	var water: PackedByteArray = result.is_water_arr
	var total := 0.0
	var edges := 0
	for i in range(elevation.size() - 1):
		if (i + 1) % width == 0 or water[i] != 0 or water[i + 1] != 0:
			continue
		total += absf(elevation[i + 1] - elevation[i])
		edges += 1
	return total / max(1, edges)


func _land_category_entropy(values: PackedByteArray, water: PackedByteArray) -> float:
	var counts := {}
	var land_cells := 0
	for i in range(values.size()):
		if water[i] == 0:
			counts[values[i]] = int(counts.get(values[i], 0)) + 1
			land_cells += 1
	var entropy := 0.0
	for count in counts.values():
		var fraction := float(count) / land_cells
		entropy -= fraction * log(fraction)
	return entropy


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_fail(label)


func _fail(label: String) -> void:
	_failures += 1
	printerr("[geomorph-diversity] FAIL: %s" % label)
