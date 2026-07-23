extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")

const MINERAL_COVERAGE_FLOORS := {
	"stone": 0.04,
	"clay": 0.05,
	"coal": 0.04,
	"oil": 0.04,
	"natural_gas": 0.04,
	"copper_ore": 0.04,
	"iron_ore": 0.04,
	"gold_ore": 0.06,
	"silver_ore": 0.15,
	"salt": 0.04,
	"saltpeter": 0.03,
	"rare_earth": 0.03,
	"flint": 0.04,
	"bauxite": 0.04,
	"limestone": 0.05,
	"silica_sand": 0.05,
	"phosphate_rock": 0.04,
	"tin_ore": 0.03,
	"lead_ore": 0.03,
	"zinc_ore": 0.03,
	"manganese_ore": 0.03,
	"sulfur": 0.03,
}

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
				if value + 0.001 >= scaled_floor:
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
		var designed_floor := float(MINERAL_COVERAGE_FLOORS.get(
			String(resource_profile.id), 0.0))
		if designed_floor > 0.0:
			_expect("%s keeps its designed mineral coverage floor" % String(resource_profile.id),
				float(resource_profile.init_min_coverage) + 0.000001 >= designed_floor)
			_expect("%s reaches its designed mineral coverage floor" % String(resource_profile.id),
				coverage + 0.000001 >= designed_floor)
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
	var mineral_ids := MINERAL_COVERAGE_FLOORS.keys()
	mineral_ids.sort()
	for resource_id in mineral_ids:
		var row: Dictionary = stats.get(String(resource_id), {})
		print("[mineral-coverage-audit] %s cells=%d/%d viable=%d coverage=%.3f floor=%.3f" % [
			String(resource_id), int(row.get("positive", 0)), int(row.get("valid", 0)),
			int(row.get("viable", 0)),
			float(row.get("coverage", 0.0)),
			float(MINERAL_COVERAGE_FLOORS[resource_id]),
		])
		if float(row.get("mean", 0.0)) > 0.0:
			print("[mineral-reserve-audit] %s total=%.1f mean=%.1f p10=%.1f p50=%.1f p90=%.1f clusters=%d largest=%d" % [
				String(resource_id), float(row.get("total", 0.0)),
				float(row.get("mean", 0.0)), float(row.get("p10", 0.0)),
				float(row.get("median", 0.0)), float(row.get("p90", 0.0)),
				int(row.get("clusters", 0)), int(row.get("largest_cluster", 0)),
			])

	_expect_capacity(stats, max_capacity, resource_ids, "fertile_soil", 5000.0)
	_expect_capacity(stats, max_capacity, resource_ids, "arable_land", 2000.0)
	_expect_capacity(stats, max_capacity, resource_ids, "paddy_land", 1500.0)
	_expect_capacity(stats, max_capacity, resource_ids, "plantation_land", 2000.0)
	_expect_capacity(stats, max_capacity, resource_ids, "pasture", 3000.0)
	_expect("plantation remains geographically selective",
		float((stats.get("plantation_land", {}) as Dictionary).get("coverage", 1.0)) <= 0.35)
	_expect("timber reaches a meaningful share of land",
		float((stats.get("timber", {}) as Dictionary).get("coverage", 0.0)) >= 0.30 and
		float((stats.get("timber", {}) as Dictionary).get("median", 0.0)) >= 100000.0)
	var marine_stats := stats.get("marine_fish", {}) as Dictionary
	_expect("marine fish is widespread without filling every valid habitat",
		float(marine_stats.get("coverage", 0.0)) >= 0.65 and
		float(marine_stats.get("coverage", 0.0)) <= 0.80)
	_expect("marine fish has visibly differentiated reserve bands",
		float(marine_stats.get("p90", 0.0)) >=
			float(marine_stats.get("p10", 0.0)) * 2.0)
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
