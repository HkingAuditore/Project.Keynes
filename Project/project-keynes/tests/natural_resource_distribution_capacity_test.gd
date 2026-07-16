extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")

var _failures := PackedStringArray()


func _init() -> void:
	var profile = load("res://data/world/earth_like.tres").duplicate(true)
	profile.native_generation_mode = ClimateProfile.NATIVE_MODE_ACTIVE
	profile.native_daily_sim_mode = ClimateProfile.NATIVE_MODE_ACTIVE
	profile.native_environment_runtime_enabled = false
	var cfg := MapConfig.make(40, 25)
	cfg.seed = 17012026
	cfg.num_continents = 3
	cfg.sea_level = 0.42
	cfg.continent_size = 0.9
	cfg.climate_profile = profile
	var generator := MapGenerator.new()
	generator.climate_profile = profile
	var generated: Dictionary = generator.generate(cfg, 10.0)
	var map: MapData = generated.get("map", null)
	_expect("Earth-like audit map generates", map != null)
	if map == null:
		_finish()
		return
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("economy catalog compiles for resource audit", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		_finish()
		return
	var resource_ids: PackedStringArray = compiled.building_resource_ids
	var max_capacity := _max_capacity_requirements(compiled, resource_ids.size())
	var stats := {}
	var all_valid := true
	for resource_profile in ResourceProfileRegistry.ordered():
		var values: PackedFloat32Array = map.get(
			ResourceProfileRegistry.reserve_map_field(resource_profile))
		var positive: Array[float] = []
		var valid := 0
		for cell in range(map.cell_count()):
			var habitat := int(map.resource_habitat_mask_arr[cell])
			var available := ResourceProfileRegistry.habitat_available(resource_profile, habitat)
			var value := float(values[cell]) if cell < values.size() else -1.0
			if not is_finite(value) or value < 0.0 or (not available and value > 0.0001):
				all_valid = false
			if not available:
				continue
			valid += 1
			if value > 0.0001:
				positive.append(value)
		positive.sort()
		var coverage := float(positive.size()) / maxf(1.0, float(valid))
		stats[String(resource_profile.id)] = {
			"valid": valid,
			"positive": positive.size(),
			"coverage": coverage,
			"median": _quantile(positive, 0.5),
			"max": positive[-1] if not positive.is_empty() else 0.0,
		}
		if float(resource_profile.init_min_coverage) > 0.0:
			var target := ceili(float(valid) * float(resource_profile.init_min_coverage))
			var scaled_floor := float(resource_profile.init_min_reserve) * \
				ResourceProfileRegistry.CELL_AREA_RESOURCE_SCALE
			var at_floor := 0
			for value in positive:
				if value + 0.001 >= scaled_floor:
					at_floor += 1
			_expect("%s honors minimum deposit coverage" % String(resource_profile.id),
				at_floor >= target)
	_expect("all resource reserves are finite, nonnegative, and habitat-valid", all_valid)
	for resource_id in resource_ids:
		var row: Dictionary = stats.get(String(resource_id), {})
		_expect("used resource exists globally: %s" % String(resource_id),
			int(row.get("positive", 0)) > 0)

	_expect_capacity(stats, max_capacity, resource_ids, "fertile_soil", 5000.0)
	_expect_capacity(stats, max_capacity, resource_ids, "arable_land", 2000.0)
	_expect_capacity(stats, max_capacity, resource_ids, "paddy_land", 1500.0)
	_expect_capacity(stats, max_capacity, resource_ids, "plantation_land", 2000.0)
	_expect_capacity(stats, max_capacity, resource_ids, "pasture", 3000.0)
	_expect("plantation remains geographically selective",
		float((stats.get("plantation_land", {}) as Dictionary).get("coverage", 1.0)) <= 0.35)
	_expect("timber reaches a meaningful share of land",
		float((stats.get("timber", {}) as Dictionary).get("coverage", 0.0)) >= 0.30 and
		float((stats.get("timber", {}) as Dictionary).get("median", 0.0)) >= 3000000.0)
	_expect("marine fish covers marine habitat with durable stock",
		float((stats.get("marine_fish", {}) as Dictionary).get("coverage", 0.0)) >= 0.99 and
		float((stats.get("marine_fish", {}) as Dictionary).get("median", 0.0)) >= 300000.0)
	for resource_id in ["wild_game", "fertile_soil", "stone", "timber", "marine_fish"]:
		var row: Dictionary = stats.get(resource_id, {})
		print("[resource-scale-audit] %s coverage=%.3f median=%.1f max=%.1f" % [
			resource_id, float(row.get("coverage", 0.0)),
			float(row.get("median", 0.0)), float(row.get("max", 0.0))])
	_finish()


func _max_capacity_requirements(compiled: Dictionary, resource_count: int) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	result.resize(resource_count)
	var resources: PackedInt32Array = compiled.building_production_resource_ids
	var quantities: PackedInt64Array = compiled.building_production_resource_quantities
	var modes: PackedInt32Array = compiled.building_production_resource_modes
	for edge in range(resources.size()):
		var resource := int(resources[edge])
		if resource >= 0 and resource < result.size() and int(modes[edge]) == 1:
			result[resource] = maxf(result[resource], float(quantities[edge]) / 1000.0)
	return result


func _expect_capacity(stats: Dictionary, requirements: PackedFloat32Array,
		resource_ids: PackedStringArray, resource_id: String, minimum_buildings: float) -> void:
	var resource := resource_ids.find(resource_id)
	var row: Dictionary = stats.get(resource_id, {})
	var required := float(requirements[resource]) if resource >= 0 else 0.0
	var support := float(row.get("median", 0.0)) / required if required > 0.0 else 0.0
	_expect("%s median supports at least %.0f buildings" % [resource_id, minimum_buildings],
		support >= minimum_buildings)


func _quantile(values: Array[float], q: float) -> float:
	if values.is_empty():
		return 0.0
	return values[clampi(int(floor(q * float(values.size() - 1))), 0, values.size() - 1)]


func _expect(label: String, condition: bool) -> void:
	if not condition:
		_failures.append(label)


func _finish() -> void:
	if _failures.is_empty():
		print("[natural-resource-distribution-capacity] PASS")
		quit(0)
		return
	for failure in _failures:
		push_error("[natural-resource-distribution-capacity] FAIL: %s" % failure)
	quit(1)
