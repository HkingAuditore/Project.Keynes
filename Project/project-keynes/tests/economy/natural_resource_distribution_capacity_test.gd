extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")

var _failures := PackedStringArray()


func _init() -> void:
	var profile = load("res://data/world/earth_like.tres").duplicate(true)
	profile.native_generation_mode = ClimateProfile.NATIVE_MODE_ACTIVE
	profile.native_daily_sim_mode = ClimateProfile.NATIVE_MODE_ACTIVE
	profile.native_environment_runtime_enabled = false
	# Match the 60x40 strategic-world scale used by economy recorder audits.
	var cfg := MapConfig.make(60, 40)
	cfg.seed = int(OS.get_environment("PK_TEST_MAP_SEED")) \
		if OS.has_environment("PK_TEST_MAP_SEED") else 17012026
	cfg.num_continents = 3
	cfg.sea_level = 0.42
	cfg.continent_size = 0.9
	cfg.climate_profile = profile
	var generator := MapGenerator.new()
	generator.climate_profile = profile
	var generated: Dictionary = await generator.generate(cfg, 10.0)
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
		var total := 0.0
		for value in positive:
			total += value
		var mean := total / positive.size() if not positive.is_empty() else 0.0
		var cluster_stats := _deposit_cluster_stats(map, values)
		var scaled_floor := float(resource_profile.init_min_reserve) * \
			ResourceProfileRegistry.CELL_AREA_RESOURCE_SCALE
		var viable := 0
		var micro_like := 0
		if scaled_floor > 0.0:
			for value in positive:
				if value >= scaled_floor or is_equal_approx(value, scaled_floor):
					viable += 1
				else:
					micro_like += 1
		stats[String(resource_profile.id)] = {
			"valid": valid,
			"positive": positive.size(),
			"viable": viable,
			"micro_like": micro_like,
			"coverage": coverage,
			"total": total,
			"mean": mean,
			"p10": _quantile(positive, 0.1),
			"median": _quantile(positive, 0.5),
			"p90": _quantile(positive, 0.9),
			"max": positive[-1] if not positive.is_empty() else 0.0,
			"clusters": int(cluster_stats.clusters),
			"largest_cluster": int(cluster_stats.largest),
		}
		_expect("%s coverage stays inside the habitat bounds" % String(resource_profile.id),
			coverage >= 0.0 and coverage <= 1.0)
		if float(resource_profile.init_min_coverage) > 0.0:
			var target := ceili(float(valid) * float(resource_profile.init_min_coverage))
			_expect("%s honors minimum deposit coverage" % String(resource_profile.id),
				viable >= target)
		if float(resource_profile.init_target_coverage) > 0.0:
			var core_target := ceili(
				float(valid) * float(resource_profile.init_target_coverage))
			var micro_target := mini(valid - core_target, ceili(
				float(valid) * float(resource_profile.init_micro_coverage)))
			_expect("%s honors exact core + micro deposit coverage" %
					String(resource_profile.id),
				positive.size() == core_target + micro_target)
			var target_total := float(resource_profile.init_target_reserve_density) * \
				ResourceProfileRegistry.CELL_AREA_RESOURCE_SCALE * valid
			if target_total <= 0.0:
				target_total = float(resource_profile.init_target_mean_reserve) * \
					ResourceProfileRegistry.CELL_AREA_RESOURCE_SCALE * core_target
			_expect("%s honors target world reserve" % String(resource_profile.id),
				absf(total - target_total) <= maxf(1.0, target_total * 0.00001))
			_expect("%s forms differentiated enrichment" % String(resource_profile.id),
				positive.size() < 3 or _quantile(positive, 0.9) > _quantile(positive, 0.1))
			if micro_target > 0:
				_expect("%s keeps a visible small/micro deposit tier" %
						String(resource_profile.id),
					micro_like >= ceili(float(micro_target) * 0.5))
				_expect("%s disperses small/micro deposits across regions" %
						String(resource_profile.id),
					int(cluster_stats.clusters) >= ceili(float(micro_target) * 0.75))
	_expect("all resource reserves are finite, nonnegative, and habitat-valid", all_valid)
	for resource_id in resource_ids:
		var row: Dictionary = stats.get(String(resource_id), {})
		_expect("used resource exists globally: %s" % String(resource_id),
			int(row.get("positive", 0)) > 0)
	var mineral_ids := []
	for resource_profile in ResourceProfileRegistry.ordered():
		if String(resource_profile.geology_family_id) != "":
			mineral_ids.append(String(resource_profile.id))
	mineral_ids.sort()
	for resource_id in mineral_ids:
		var row: Dictionary = stats.get(String(resource_id), {})
		print("[mineral-coverage-audit] %s cells=%d/%d viable=%d coverage=%.3f" % [
			String(resource_id), int(row.get("positive", 0)), int(row.get("valid", 0)),
			int(row.get("viable", 0)),
			float(row.get("coverage", 0.0)),
		])
		if float(row.get("mean", 0.0)) > 0.0:
			print("[mineral-reserve-audit] %s total=%.1f mean=%.1f p10=%.1f p50=%.1f p90=%.1f clusters=%d largest=%d" % [
				String(resource_id), float(row.get("total", 0.0)),
				float(row.get("mean", 0.0)), float(row.get("p10", 0.0)),
				float(row.get("median", 0.0)), float(row.get("p90", 0.0)),
				int(row.get("clusters", 0)), int(row.get("largest_cluster", 0)),
			])

	var capacity_profiles_positive := true
	for profile_value in ResourceProfileRegistry.ordered():
		var row: Dictionary = stats.get(String(profile_value.id), {})
		if float(profile_value.ecology_capacity) > 0.0:
			capacity_profiles_positive = capacity_profiles_positive \
				and float(row.get("median", 0.0)) > 0.0
	_expect("each resource has a nonempty bounded distribution and ecology capacity where authored",
		capacity_profiles_positive)
	var marine_stats := stats.get("marine_fish", {}) as Dictionary
	_expect("marine fish has visibly differentiated reserve bands",
		float(marine_stats.get("p90", 0.0)) >
			float(marine_stats.get("p10", 0.0)))
	_expect("marine fish distribution responds to temperature, currents, upwelling, and estuaries",
		_marine_driver_sensitivity(generator, map))
	for resource_id in ["wild_game", "fertile_soil", "stone", "timber", "marine_fish"]:
		var row: Dictionary = stats.get(resource_id, {})
		print("[resource-scale-audit] %s coverage=%.3f median=%.1f max=%.1f" % [
			resource_id, float(row.get("coverage", 0.0)),
			float(row.get("median", 0.0)), float(row.get("max", 0.0))])
	_finish()


func _marine_driver_sensitivity(generator: MapGenerator, map: MapData) -> bool:
	var marine: ResourceProfile = null
	for profile in ResourceProfileRegistry.ordered():
		if profile.id == &"marine_fish":
			marine = profile
			break
	if marine == null:
		return false
	var baseline := map.res_marine_fish_reserve_arr.duplicate()
	var properties := [
		&"init_climate_fit",
		&"init_ocean_current",
		&"init_upwelling",
		&"init_estuary",
	]
	var changed := true
	for property in properties:
		var original := float(marine.get(property))
		if is_zero_approx(original):
			return false
		marine.set(property, 0.0)
		generator._bootstrap_natural_resource_deposits(map, generator._last_cfg)
		var candidate: PackedFloat32Array = map.res_marine_fish_reserve_arr
		var max_delta := 0.0
		for cell in range(mini(baseline.size(), candidate.size())):
			max_delta = maxf(max_delta, absf(baseline[cell] - candidate[cell]))
		marine.set(property, original)
		changed = changed and max_delta > 1.0
	generator._bootstrap_natural_resource_deposits(map, generator._last_cfg)
	return changed


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


func _deposit_cluster_stats(map: MapData, values: PackedFloat32Array) -> Dictionary:
	var neighbors := map.neighbor_indices_packed()
	var visited := {}
	var clusters := 0
	var largest := 0
	for start in range(mini(map.cell_count(), values.size())):
		if values[start] <= 0.0001 or visited.has(start):
			continue
		clusters += 1
		var size := 0
		var queue := [start]
		visited[start] = true
		while not queue.is_empty():
			var cell := int(queue.pop_back())
			size += 1
			for direction in range(6):
				var neighbor_index := cell * 6 + direction
				if neighbor_index < 0 or neighbor_index >= neighbors.size():
					continue
				var neighbor := int(neighbors[neighbor_index])
				if neighbor < 0 or neighbor >= values.size() or visited.has(neighbor) \
						or values[neighbor] <= 0.0001:
					continue
				visited[neighbor] = true
				queue.append(neighbor)
		largest = maxi(largest, size)
	return {"clusters": clusters, "largest": largest}


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
