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
	if map != null and facade != null:
		var populated_cell := _first_populated_cell(map, facade)
		_expect("generated map has populated land", populated_cell >= 0)
		if populated_cell >= 0:
			var buildings: Dictionary = facade.building_cell_snapshot(populated_cell)
			_expect("generated economy includes building groups",
				_sum_i64(buildings.get("building_counts_by_type", PackedInt64Array())) > 0)
			_expect("building snapshot is committed", bool(buildings.get("committed", false)))
		_expect("populated cells expose sparse resource-specialized local economies",
			_all_populated_cells_are_specialized(map, facade))
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
	var freshwater: PackedFloat32Array = map.res_freshwater_fish_reserve_arr
	if marine.size() != map.cell_count() or freshwater.size() != map.cell_count():
		return false
	var found_marine_water := false
	for cell in range(map.cell_count()):
		var is_water := cell < map.is_water_arr.size() and map.is_water_arr[cell] != 0
		var landform := int(map.landform_arr[cell]) if cell < map.landform_arr.size() else -1
		var river := cell < map.has_river_arr.size() and map.has_river_arr[cell] != 0
		var marine_habitat := is_water and landform in [LandformType.LF.DEEP_OCEAN,
			LandformType.LF.OCEAN, LandformType.LF.COAST]
		var freshwater_habitat := (is_water and landform == LandformType.LF.LAKE) or river
		if marine[cell] > 0.0:
			if not marine_habitat:
				return false
			found_marine_water = true
		if freshwater[cell] > 0.0 and not freshwater_habitat:
			return false
	return found_marine_water


func _sum_i64(values: PackedInt64Array) -> int:
	var total := 0
	for value in values:
		total += int(value)
	return total


func _all_populated_cells_are_specialized(map: MapData, facade) -> bool:
	var expected_ids: PackedStringArray = facade.building_type_ids()
	if expected_ids.is_empty():
		return false
	var local_sets := {}
	var global_types := {}
	var populated_count := 0
	for cell in range(map.cell_count()):
		var population: Dictionary = facade.population_cell_snapshot(cell)
		if int(population.get("population", 0)) <= 0:
			continue
		populated_count += 1
		if int(population.get("cohort_count", 0)) < 2:
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
			local_ids.append(String(building_id))
			global_types[building_id] = true
			if not _collector_respects_local_resources(
					map, facade, cell, building_id, int(counts[type_idx])):
				return false
		if local_ids.is_empty() or local_ids.size() >= expected_ids.size():
			return false
		local_sets["|".join(local_ids)] = true
	return populated_count > 1 and local_sets.size() > 1 and \
		global_types.size() * 2 >= expected_ids.size()


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
