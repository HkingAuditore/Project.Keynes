extends SceneTree

var failures := 0


func _init() -> void:
	var profile = load("res://data/world/earth_like.tres").duplicate(true)
	profile.native_generation_mode = ClimateProfile.NATIVE_MODE_ACTIVE
	profile.native_daily_sim_mode = ClimateProfile.NATIVE_MODE_ACTIVE
	profile.native_environment_runtime_enabled = false
	var cfg := MapConfig.make(8, 6)
	cfg.seed = 20260712
	cfg.num_continents = 1
	cfg.sea_level = 0.45
	cfg.continent_size = 0.85
	cfg.climate_profile = profile
	var generator := MapGenerator.new()
	generator.climate_profile = profile
	generator.set_test_economy_bootstrap_enabled(true)
	var generated: Dictionary = generator.generate(cfg, 10.0)
	var map: MapData = generated.get("map", null)
	_expect("map generated", map != null)
	if map != null:
		_expect("generated fisheries live on water/river habitats",
			_water_resource_habitats_valid(map))
	var facade = generator.get_economy_facade()
	_expect("economy facade configured", facade != null and facade.is_configured())
	if facade != null:
		_expect("facade exposes recipe candidates and multi-role output metadata",
			_substitution_metadata_valid(facade))
	if map != null and facade != null:
		var populated_cell := _first_populated_cell(map, facade)
		_expect("generated map has populated land", populated_cell >= 0)
		if populated_cell >= 0:
			var buildings: Dictionary = facade.building_cell_snapshot(populated_cell)
			_expect("generated economy includes building groups",
				_sum_i64(buildings.get("building_counts_by_type", PackedInt64Array())) > 0)
			_expect("building snapshot is committed", bool(buildings.get("committed", false)))
		_expect("generated economy starts with zero goods and unemployed people",
			_all_populated_cells_start_empty_and_unemployed(map, facade))
		_expect("populated cells expose mid-stone resource-specialized local economies",
			_all_populated_cells_are_mid_stone_specialized(map, facade))
		if populated_cell >= 0:
			_expect("player inspector hides technology-locked goods and resources",
				_inspector_visibility_respects_technology(
					map, generator, facade, populated_cell))
	if failures == 0:
		print("[economy-map-generation] PASS")
	quit(0 if failures == 0 else 1)


func _first_populated_cell(map: MapData, facade) -> int:
	for cell in range(map.cell_count()):
		var snapshot: Dictionary = facade.population_cell_snapshot(cell)
		if int(snapshot.get("population", 0)) > 0:
			return cell
	return -1


func _water_resource_habitats_valid(map: MapData) -> bool:
	var marine: PackedFloat32Array = map.res_marine_fish_reserve_arr
	if marine.size() != map.cell_count():
		return false
	var found_marine_water := false
	for cell in range(map.cell_count()):
		var is_water := cell < map.is_water_arr.size() and map.is_water_arr[cell] != 0
		var landform := int(map.landform_arr[cell]) if cell < map.landform_arr.size() else -1
		var marine_habitat := is_water and landform in [LandformType.LF.DEEP_OCEAN,
			LandformType.LF.OCEAN, LandformType.LF.COAST]
		if marine[cell] > 0.0:
			if not marine_habitat:
				return false
			found_marine_water = true
	return found_marine_water


func _sum_i64(values: PackedInt64Array) -> int:
	var total := 0
	for value in values:
		total += int(value)
	return total


func _all_populated_cells_are_mid_stone_specialized(map: MapData, facade) -> bool:
	var local_sets := {}
	var global_types := {}
	var populated_count := 0
	for cell in range(map.cell_count()):
		var population: Dictionary = facade.population_cell_snapshot(cell)
		if int(population.get("population", 0)) <= 0:
			continue
		populated_count += 1
		if int(population.get("cohort_count", 0)) < 1:
			return false
		var buildings: Dictionary = facade.building_cell_snapshot(cell)
		var actual_ids: PackedStringArray = buildings.get("building_type_ids", PackedStringArray())
		var counts: PackedInt64Array = buildings.get(
			"building_counts_by_type", PackedInt64Array())
		var local_ids := PackedStringArray()
		for type_idx in range(actual_ids.size()):
			if type_idx >= counts.size() or counts[type_idx] <= 0:
				continue
			var building_id := StringName(actual_ids[type_idx])
			if not _building_is_mid_stone(facade, building_id):
				return false
			local_ids.append(String(building_id))
			global_types[building_id] = true
			if not _collector_respects_local_resources(
					map, facade, cell, building_id, int(counts[type_idx])):
				return false
		if local_ids.is_empty():
			return false
		local_sets["|".join(local_ids)] = true
	return populated_count > 1 and local_sets.size() > 1 and global_types.size() > 1


func _all_populated_cells_start_empty_and_unemployed(map: MapData, facade) -> bool:
	var populated_count := 0
	for cell in range(map.cell_count()):
		var population: Dictionary = facade.population_cell_snapshot(cell)
		var total := int(population.get("population", 0))
		if total <= 0:
			continue
		populated_count += 1
		if _sum_i64(population.get("owner_employed_by_cohort", PackedInt64Array())) != 0 or \
				_sum_i64(population.get("employee_employed_by_cohort", PackedInt64Array())) != 0 or \
				_sum_i64(population.get("unemployed_by_cohort", PackedInt64Array())) != total:
			return false
		if _sum_i64(facade.market_cell_snapshot(cell).get("stock", PackedInt64Array())) != 0:
			return false
	return populated_count > 1


func _inspector_visibility_respects_technology(
		map: MapData, generator: MapGenerator, facade, cell_idx: int) -> bool:
	var cell := map.cell_at(cell_idx)
	if cell == null:
		return false
	var view_model := CellInspectorViewModel.new()
	view_model.set_context(map, generator, null, null, 0.45, 10.0)
	var market_snapshot: Dictionary = facade.market_cell_snapshot(cell_idx)
	var good_ids: PackedStringArray = market_snapshot.get("good_ids", PackedStringArray())
	var available: PackedByteArray = market_snapshot.get(
		"good_technology_available", PackedByteArray())
	if available.size() != good_ids.size():
		return false
	var market_rows: Array = view_model.build_tab_category(
		cell, "market").get("market_rows", [])
	if market_rows.is_empty() or market_rows.size() >= good_ids.size():
		return false
	for row in market_rows:
		var stable_id := String((row as Dictionary).get("id", "")).trim_prefix("market_")
		var good_idx := good_ids.find(stable_id)
		if good_idx < 0 or available[good_idx] == 0:
			return false
	var visibility: Dictionary = view_model._resource_visibility_context(cell_idx)
	if not bool(visibility.get("enforce_discovery", false)) \
			or not bool(visibility.get("enforce_extraction", false)):
		return false
	var extractable: Dictionary = visibility.get("extractable_resource_ids", {})
	var resources: Array = view_model._resource_state(
		cell_idx, LandformType.is_water(int(cell.landform)), visibility)
	for resource in resources:
		if not extractable.has(StringName((resource as Dictionary).get("id", ""))):
			return false
	return _find_resource(resources, &"rare_earth").is_empty()


func _find_resource(resources: Array, stable_id: StringName) -> Dictionary:
	for resource in resources:
		if StringName((resource as Dictionary).get("id", "")) == stable_id:
			return resource
	return {}


func _substitution_metadata_valid(facade) -> bool:
	var goldsmith: Dictionary = facade.building_placement_spec(&"goldsmith_workshop")
	if not bool(goldsmith.get("ok", false)) \
			or goldsmith.get("input_category_ids", PackedStringArray()) != \
				PackedStringArray(["precious_metal", "tools"]) \
			or not goldsmith.get("input_candidate_good_ids", PackedStringArray()).has("gold") \
			or not goldsmith.get("input_candidate_good_ids", PackedStringArray()).has("silver"):
		return false
	var steam_works: Dictionary = facade.building_placement_spec(&"steam_engine_works")
	var offsets: PackedInt32Array = steam_works.get(
		"output_substitution_category_offsets", PackedInt32Array())
	var categories: PackedStringArray = steam_works.get(
		"output_substitution_category_ids", PackedStringArray())
	return bool(steam_works.get("ok", false)) and offsets == PackedInt32Array([0, 3]) \
		and categories.has("prime_mover") and categories.has("industrial_prime_mover") \
		and categories.has("agricultural_prime_mover")


func _building_is_mid_stone(facade, building_id: StringName) -> bool:
	var spec: Dictionary = facade.building_placement_spec(building_id)
	if not bool(spec.get("ok", false)):
		return false
	for tag in spec.get("technology_tags", PackedStringArray()):
		var technology := String(tag)
		if technology.begins_with("tech.") and technology not in [
				"tech.hunting", "tech.gathering", "tech.stone_knapping", "tech.fire_control"]:
			return false
	return true


func _collector_respects_local_resources(map: MapData, facade, cell: int,
		building_id: StringName, count: int) -> bool:
	var spec: Dictionary = facade.building_placement_spec(building_id)
	if not bool(spec.get("ok", false)):
		return false
	if int(spec.kind) != 0:
		return true
	var resource_ids: PackedStringArray = spec.resource_ids
	var quantities: PackedInt64Array = spec.resource_quantities
	var modes: PackedInt32Array = spec.resource_modes
	var access_modes: PackedInt32Array = spec.resource_access_modes
	var neighbors: PackedInt32Array = map.neighbor_indices_packed()
	for i in range(resource_ids.size()):
		var reserves := _resource_values(map, StringName(resource_ids[i]))
		var required := float(quantities[i]) / 1000.0
		if int(modes[i]) == 0:
			required *= 5.0
		var available := _accessible_reserve(reserves, cell,
			int(access_modes[i]) if i < access_modes.size() else 0, neighbors, map.cell_count())
		if cell >= reserves.size() or required <= 0.0 or available < required * count:
			return false
	return true


func _accessible_reserve(reserves: PackedFloat32Array, cell: int, access_mode: int,
		neighbors: PackedInt32Array, cell_count: int) -> float:
	if cell < 0 or cell >= reserves.size():
		return 0.0
	var total := maxf(0.0, reserves[cell])
	if access_mode != 1 or neighbors.size() != cell_count * 6:
		return total
	var visited := {cell: true}
	for direction in range(6):
		var neighbor := int(neighbors[cell * 6 + direction])
		if neighbor < 0 or neighbor >= reserves.size() or visited.has(neighbor):
			continue
		visited[neighbor] = true
		total += maxf(0.0, reserves[neighbor])
	return total


func _resource_values(map: MapData, resource_id: StringName) -> PackedFloat32Array:
	ResourceProfileRegistry.ensure_loaded()
	for profile in ResourceProfileRegistry.ordered():
		if StringName(profile.id) != resource_id:
			continue
		var field := ResourceProfileRegistry.reserve_map_field(profile)
		return map.get(field) if field != "" else PackedFloat32Array()
	return PackedFloat32Array()


func _expect(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		failures += 1
