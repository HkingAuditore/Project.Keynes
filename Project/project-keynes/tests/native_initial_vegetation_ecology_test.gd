extends SceneTree

const VegetationProfileRegistryScript = preload("res://scripts/data/vegetation_profile_registry.gd")

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	print("[native-initial-vegetation] checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if condition:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		print("  [FAIL] %s" % label)


func _run() -> void:
	_test_pending_generation_ecology_survives_soa_bootstrap()
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	_expect("DCWorldExt available", ext != null)
	if ext == null:
		return
	var ideal_t := PackedFloat32Array()
	var ideal_m := PackedFloat32Array()
	var tol_t := PackedFloat32Array()
	var tol_m := PackedFloat32Array()
	for v in range(28):
		var p: Variant = VegetationProfileRegistryScript.get_profile(v)
		ideal_t.append(float(p.ideal_temp))
		ideal_m.append(float(p.ideal_moist))
		tol_t.append(float(p.temp_tolerance))
		tol_m.append(float(p.moist_tolerance))
	var cfg := {
		"width": 48,
		"height": 32,
		"num_continents": 3,
		"sea_level": 0.42,
		"continent_size": 0.9,
	}
	var profile := {
		"native_generation_mode": 2,
		"veg_ideal_temp": ideal_t,
		"veg_ideal_moist": ideal_m,
		"veg_temp_tol": tol_t,
		"veg_moist_tol": tol_m,
		"plant_water_balance_weight": 0.35,
		"plant_soil_buffer_weight": 0.30,
		"plant_drought_penalty": 0.25,
		"vegetation_min_suitability": 0.18,
	}
	var res: Dictionary = ext.call("run_native_world_generate_full_pass", 20260731, cfg, profile)
	_expect("full pass succeeds", int(res.get("rc", -1)) == 0 and not bool(res.get("fallback", true)))
	if int(res.get("rc", -1)) != 0:
		return
	var n := int(res.get("n_cells", 0))
	for key in [
		"vegetation_vitality_arr", "soil_moisture_arr", "water_balance_30d_arr",
		"plant_available_water_arr", "vegetation_growth_pressure_arr",
		"vegetation_heat_stress_arr", "vegetation_drought_stress_arr",
		"vegetation_cold_stress_arr", "vegetation_regen_score_arr",
	]:
		var arr: PackedFloat32Array = res.get(key, PackedFloat32Array())
		_expect("%s is dense" % key, arr.size() == n)
	var water: PackedFloat32Array = res.get("plant_available_water_arr", PackedFloat32Array())
	var veg: PackedByteArray = res.get("vegetation_arr", PackedByteArray())
	var vitality: PackedFloat32Array = res.get("vegetation_vitality_arr", PackedFloat32Array())
	var nonzero_water := 0
	var live := 0
	var vitality_sum := 0.0
	for i in range(n):
		if water[i] > 0.01:
			nonzero_water += 1
		if veg[i] != 0:
			live += 1
			vitality_sum += vitality[i]
	_expect("land receives nonzero plant water", int(res.get("plant_water_nonzero_land_count", 0)) > 0)
	_expect("plant water is not all zero", nonzero_water > 0)
	_expect("initial vitality is not the default constant", live == 0 or vitality_sum / float(live) != 0.7)
	_expect("diagnostic score range is valid", float(res.get("vegetation_score_min", 0.0)) >= 0.0 and float(res.get("vegetation_score_max", 0.0)) <= 1.25)


func _test_pending_generation_ecology_survives_soa_bootstrap() -> void:
	var map := MapData.new(1, 1)
	var cell := HexCell.new(0, 0)
	map.set_cell(cell)
	var ecology := {
		"vegetation_vitality_arr": PackedFloat32Array([0.91]),
		"soil_moisture_arr": PackedFloat32Array([0.37]),
		"water_balance_30d_arr": PackedFloat32Array([0.21]),
		"plant_available_water_arr": PackedFloat32Array([0.64]),
		"vegetation_growth_pressure_arr": PackedFloat32Array([0.18]),
		"vegetation_heat_stress_arr": PackedFloat32Array([0.03]),
		"vegetation_drought_stress_arr": PackedFloat32Array([0.07]),
		"vegetation_cold_stress_arr": PackedFloat32Array([0.02]),
		"vegetation_regen_score_arr": PackedFloat32Array([0.73]),
	}
	map.set_pending_generation_ecology(ecology)
	map.init_soa_from_bake()
	_expect("pending ecology survives SoA bootstrap", is_equal_approx(map.vegetation_vitality_arr[0], 0.91))
	_expect("pending plant water survives SoA bootstrap", is_equal_approx(map.plant_available_water_arr[0], 0.64))
	_expect("pending regen score survives SoA bootstrap", is_equal_approx(map.vegetation_regen_score_arr[0], 0.73))
