extends SceneTree

# godot --headless --path . --script tests/marine_fish_habitat_test.gd --quit

var _failures := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	ResourceProfileRegistry.ensure_loaded()
	var marine: ResourceProfile = null
	for profile in ResourceProfileRegistry.ordered():
		if profile != null and profile.id == &"marine_fish":
			marine = profile
			break
	_expect("marine fish profile exists", marine != null)
	if marine == null:
		_finish()
		return
	_expect("marine fish uses coastal-or-marine habitat",
		ResourceProfileRegistry.habitat_code(marine) == 5)
	_expect("coastal land is valid", ResourceProfileRegistry.habitat_available(marine, 8))
	_expect("marine water is valid", ResourceProfileRegistry.habitat_available(marine, 2))
	_expect("ordinary land is invalid", not ResourceProfileRegistry.habitat_available(marine, 1))
	_expect("freshwater is invalid", not ResourceProfileRegistry.habitat_available(marine, 4))

	var collector := load("res://data/economy/buildings/marine_fish_collector.tres") \
		as BuildingProfile
	_expect("fishery remains strictly local",
		collector != null and collector.resource_access_modes == PackedStringArray(["local"]))

	var map := MapData.new(4, 1)
	map.temp_arr = PackedFloat32Array([0.5, 0.5, 0.5, 0.5])
	map.moisture_arr = PackedFloat32Array([0.5, 0.5, 0.5, 0.5])
	map.is_water_arr = PackedByteArray([0, 0, 1, 1])
	map.resource_habitat_mask_arr = PackedByteArray([1, 8, 2, 4])
	for profile in ResourceProfileRegistry.ordered():
		var reserves := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
		var extras := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
		if profile.id == &"marine_fish":
			reserves = PackedFloat32Array([100.0, 100.0, 100.0, 100.0])
		map.set(ResourceProfileRegistry.reserve_map_field(profile), reserves)
		map.set(ResourceProfileRegistry.extra_change_map_field(profile), extras)

	var ext := DCWorldExt.new()
	_expect("native world binds", bool(ext.bind_map_data(map)))
	var knobs := ResourceProfileRegistry.build_pass_knobs()
	knobs["n_cells"] = 4
	var result: Dictionary = ext.run_natural_resource_pass(knobs)
	_expect("native resource pass completes", bool(result.get("done", false)))
	var values: PackedFloat32Array = map.res_marine_fish_reserve_arr
	print("  [INFO] post-pass marine reserves=%s" % str(values))
	_expect("daily pass preserves both valid habitats",
		values[1] > 0.0 and values[2] > 0.0)
	_expect("daily pass clears invalid habitats",
		is_zero_approx(values[0]) and is_zero_approx(values[3]))

	var view_model := CellInspectorViewModel.new()
	view_model.set_context(map, null, null, null, 0.45, 10.0)
	var visible_resources := view_model._resource_state(2, true, {
		"enforce_extraction": true,
		"extractable_resource_ids": {},
	})
	var inspector_fish := {}
	for item in visible_resources:
		if StringName((item as Dictionary).get("id", "")) == &"marine_fish":
			inspector_fish = item
			break
	_expect("Inspector reads local fish reserve even without an extractor",
		not inspector_fish.is_empty() and float(inspector_fish.get("reserve", 0.0)) > 0.0)
	_expect("Inspector keeps extraction capability separate from local inventory",
		not bool(inspector_fish.get("extractable", true)))
	_finish()


func _expect(label: String, condition: bool) -> void:
	if condition:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		push_error("  [FAIL] %s" % label)


func _finish() -> void:
	print("=== marine fish habitat: %d failures ===" % _failures)
	quit(0 if _failures == 0 else 1)
