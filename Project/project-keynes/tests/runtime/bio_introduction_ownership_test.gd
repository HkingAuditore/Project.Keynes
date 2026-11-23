extends "res://tests/building/building_runtime_test.gd"

var _entrypoint: StringName


func _run() -> void:
	var catalog := EconomyCatalogScript.compile_native_catalog()
	_expect("bio introduction catalog compiles", bool(catalog.get("ok", false)))
	if not bool(catalog.get("ok", false)):
		return
	catalog.erase("ok")
	# A positive output on the fixture's existing food plant creates a real
	# production introduction. Use one bit and no carrier to isolate ingress.
	catalog["research_bio_introduce_good_ids"] = PackedStringArray(["prepared_staples"])
	catalog["research_bio_introduce_occupancy_bits"] = PackedInt32Array([0])
	var profile: Dictionary = load("res://data/economy/default_economy.tres").to_native_profile()
	profile["startup_demand_runtime_mode"] = "OFF"
	profile["family_runtime_mode"] = "OFF"
	profile["market_runtime_mode"] = "ACTIVE"
	profile["economy_cadence_force_market_days"] = 5
	for entrypoint in [&"run_bio_occupancy_pass", &"run_bio_occupancy_slice"]:
		_entrypoint = entrypoint
		_test_production_income_consumption_order(catalog, profile)
	print("bio introduction ownership: %d failures" % failures)


func _run_day(ext: Object, day: int) -> Dictionary:
	var report := super._run_day(ext, day)
	var knobs := {
		"cell_count": 1, "seed": 42, "day_index": day,
		"occupancy_bits": PackedInt32Array([0]), "province_ids": PackedInt32Array([1]),
		"is_water": PackedByteArray([0]), "vegetation": PackedByteArray([0]),
		"landform": PackedByteArray([0]), "has_river": PackedByteArray([0]),
		"temperature": PackedFloat32Array([0.5]), "moisture": PackedFloat32Array([0.5]),
		"elevation": PackedFloat32Array([0.5]),
		"neighbor_indices": PackedInt32Array([-1, -1, -1, -1, -1, -1]),
		"species_occupancy_bits": PackedInt32Array([0]), "species_signal_ids": PackedInt32Array([1]),
		"species_carrier_index": PackedInt32Array([-1]), "species_carrier_alt_index": PackedInt32Array([-1]),
		"species_temp_lo": PackedFloat32Array([0.0]), "species_temp_hi": PackedFloat32Array([1.0]),
		"species_moist_lo": PackedFloat32Array([0.0]), "species_moist_hi": PackedFloat32Array([1.0]),
		"species_elev_lo": PackedFloat32Array([0.0]), "species_elev_hi": PackedFloat32Array([1.0]),
		"species_veg_mask0": PackedInt32Array([0]), "species_veg_mask1": PackedInt32Array([0]),
		"species_flags": PackedInt32Array([0]), "species_max_cost": PackedInt32Array([1]),
		"species_fill_keep": PackedFloat32Array([1.0]),
	}
	var implicit_result := _occupancy(ext, knobs)
	_expect("%s leaves production introductions alone" % _entrypoint,
		implicit_result.get("occupancy_bits", PackedInt32Array()) == PackedInt32Array([0]))
	knobs["introduce_cells"] = PackedInt32Array([0])
	knobs["introduce_bits"] = PackedInt32Array([0])
	var explicit_result := _occupancy(ext, knobs)
	_expect("%s uses the caller's explicit introduction" % _entrypoint,
		explicit_result.get("occupancy_bits", PackedInt32Array()) == PackedInt32Array([1]))
	return report


func _occupancy(ext: Object, knobs: Dictionary) -> Dictionary:
	var result: Dictionary = ext.call(_entrypoint, knobs)
	while bool(result.get("ok", false)) and not bool(result.get("done", true)):
		result = ext.call(_entrypoint, knobs)
	_expect("%s completes the occupancy pass" % _entrypoint, bool(result.get("ok", false)))
	return result
