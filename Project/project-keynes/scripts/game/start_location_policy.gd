class_name StartLocationPolicy
extends RefCounted

const Profile = preload("res://scripts/game/start_location_profile.gd")
const ResearchSignalCatalogScript = preload(
	"res://scripts/research/research_signal_catalog.gd")
const COUNTRY_NAME_PACK_PATH := "res://data/country/default_country_names.tres"
const UNREACHABLE_DISTANCE := 0x3fffffff
const COUNTRY_DISTANCE_MAP_RATIO := 0.15
const MIN_COUNTRY_DISTANCE := 4
const MAX_COUNTRY_DISTANCE := 12

static var _research_signal_index_by_id: Dictionary = {}


static func select_and_prepare(map: MapData, seed: int, foreign_count: int = 0,
		player_country_name: String = "新国家") -> Dictionary:
	if map == null or map.cell_count() <= 0:
		return _error("start_world_missing", "生成的世界不包含可用地块。")
	if foreign_count < NewGameConfig.MIN_FOREIGN_COUNT \
			or foreign_count > NewGameConfig.MAX_FOREIGN_COUNT:
		return _error("foreign_count_out_of_range", "外国数量超出允许范围。")
	var candidates: Array[Dictionary] = []
	var neighbors := map.neighbor_indices_packed()
	for cell_idx in range(map.cell_count()):
		if not _is_candidate(map, cell_idx, neighbors):
			continue
		var gold := _reserve(map, "gold_ore", cell_idx)
		var silver := _reserve(map, "silver_ore", cell_idx)
		var precious := maxf(gold, silver)
		var survival_score := _survival_score(map, cell_idx)
		var starter_route := _starter_route_for_cell(map, cell_idx, neighbors)
		candidates.append({
			"cell": cell_idx,
			"score": survival_score + (0.20 if precious > 0.0 else 0.0)
				+ float(starter_route.get("geography_fit", 0.0)) * 0.20,
			"survival_score": survival_score,
			"natural_precious": precious > 0.0,
			"starter_route": starter_route,
			"closure_missing_count": (starter_route.get(
				"missing_resource_ids", PackedStringArray()) as PackedStringArray).size(),
		})
	if candidates.is_empty():
		return _error("no_survivable_start", "没有找到同时满足陆地、气候与淡水条件的出生地。")
	var economically_closable: Array[Dictionary] = []
	for candidate in candidates:
		if int(candidate.closure_missing_count) <= 1:
			economically_closable.append(candidate)
	if economically_closable.is_empty():
		return _error("no_closed_starter_route",
			"没有找到只需至多一项自然资源补入即可闭合的初始产业路线。")
	candidates = economically_closable
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a.closure_missing_count) != int(b.closure_missing_count):
			return int(a.closure_missing_count) < int(b.closure_missing_count)
		if bool(a.natural_precious) != bool(b.natural_precious):
			return bool(a.natural_precious)
		if not is_equal_approx(float(a.score), float(b.score)):
			return float(a.score) > float(b.score)
		return int(a.cell) < int(b.cell))
	var top_count := maxi(1, int(ceil(candidates.size() * 0.25)))
	var chosen_index := _stable_hash(seed, "player_start") % top_count
	var cell_idx := int(candidates[chosen_index].cell)
	var minimum_distance := minimum_country_distance(map.width, map.height)
	var nearest_start := PackedInt32Array()
	nearest_start.resize(map.cell_count())
	nearest_start.fill(UNREACHABLE_DISTANCE)
	_relax_minimum_distances(map, neighbors, cell_idx, nearest_start)
	var foreign_cells := PackedInt32Array()
	var foreign_selection_distances := PackedInt32Array()
	var foreign_routes: Array[Dictionary] = []
	var remaining: Array[Dictionary] = []
	for candidate in candidates:
		if int(candidate.cell) != cell_idx:
			remaining.append(candidate)
	for _foreign_index in range(foreign_count):
		var best: Dictionary = {}
		var best_distance := -1
		for candidate in remaining:
			var candidate_cell := int(candidate.cell)
			var candidate_distance := int(nearest_start[candidate_cell])
			if candidate_distance < minimum_distance:
				continue
			if best.is_empty() or _foreign_candidate_better(
					candidate, candidate_distance, best, best_distance):
				best = candidate
				best_distance = candidate_distance
		if best.is_empty():
			return {
				"ok": false,
				"code": "foreign_start_count_unavailable",
				"message": ("无法在至少 %d 格的陆路距离之外放置 %d 个外国；"
					+ "当前只能放置 %d 个。请减少外国数量或增大地图。") % [
						minimum_distance, foreign_count, foreign_cells.size()],
				"requested_count": foreign_count,
				"available_count": foreign_cells.size(),
				"minimum_distance": minimum_distance,
			}
		var selected_cell := int(best.cell)
		foreign_cells.append(selected_cell)
		foreign_selection_distances.append(best_distance)
		foreign_routes.append((best.starter_route as Dictionary).duplicate(true))
		for index in range(remaining.size() - 1, -1, -1):
			if int(remaining[index].cell) == selected_cell:
				remaining.remove_at(index)
				break
		_relax_minimum_distances(map, neighbors, selected_cell, nearest_start)

	var name_pack = ResourceLoader.load(COUNTRY_NAME_PACK_PATH, "Resource")
	if name_pack == null or not name_pack.has_method("select"):
		return _error("country_name_pack_unavailable", "外国名字库不可用。")
	var selected_names: Dictionary = name_pack.select(
		seed, foreign_count, player_country_name.strip_edges())
	if not bool(selected_names.get("ok", false)):
		return _error(String(selected_names.get("reason", "country_name_pack_invalid")),
			"外国名字库无效或名字数量不足。")
	var foreign_name_ids: PackedStringArray = selected_names.get(
		"name_ids", PackedStringArray())
	var foreign_names: PackedStringArray = selected_names.get(
		"display_names", PackedStringArray())
	var country_starts: Array[Dictionary] = []
	var player_precious := _precious_for_cell(
		map, cell_idx, seed, "player_precious")
	var player_start := {
		"country_id": "country.player",
		"country_name": player_country_name,
		"name_id": "",
		"cell": cell_idx,
		"precious_resource": player_precious,
		"is_player": true,
		"selection_distance": 0,
	}
	player_start.merge((candidates[chosen_index].starter_route as Dictionary).duplicate(true), true)
	_append_precious_route(player_start, player_precious)
	country_starts.append(player_start)
	for foreign_index in range(foreign_count):
		var foreign_cell := int(foreign_cells[foreign_index])
		var foreign_start := {
			"country_id": "country.foreign.%03d" % (foreign_index + 1),
			"country_name": String(foreign_names[foreign_index]),
			"name_id": String(foreign_name_ids[foreign_index]),
			"cell": foreign_cell,
			"precious_resource": _precious_for_cell(
				map, foreign_cell, seed,
				"foreign_precious_%03d" % (foreign_index + 1)),
			"is_player": false,
			"selection_distance": int(foreign_selection_distances[foreign_index]),
		}
		foreign_start.merge(foreign_routes[foreign_index], true)
		_append_precious_route(foreign_start, String(foreign_start.precious_resource))
		country_starts.append(foreign_start)
	for start in country_starts:
		var start_cell := int(start.cell)
		var precious_id := String(start.precious_resource)
		var applied_topups := PackedStringArray()
		var missing_resources: PackedStringArray = start.get(
			"missing_resource_ids", PackedStringArray())
		for resource_id in missing_resources:
			_top_up(map, resource_id, start_cell,
				float(Profile.MINIMUM_RESERVES[resource_id]))
			applied_topups.append(resource_id)
		if _reserve(map, precious_id, start_cell) <= 0.0:
			_top_up(map, precious_id, start_cell,
				float(Profile.MINIMUM_RESERVES[precious_id]))
			applied_topups.append(precious_id)
		start["resource_topups"] = applied_topups
	return {
		"ok": true,
		"code": "ok",
		"message": "",
		"cell": cell_idx,
		"precious_resource": player_precious,
		"candidate_count": candidates.size(),
		"top_quartile_count": top_count,
		"score": float(candidates[chosen_index].score),
		"foreign_count": foreign_count,
		"minimum_country_distance": minimum_distance,
		"foreign_cells": foreign_cells,
		"foreign_names": foreign_names,
		"foreign_name_ids": foreign_name_ids,
		"country_starts": country_starts,
	}


static func minimum_country_distance(map_width: int, map_height: int) -> int:
	return clampi(
		int(round(float(mini(map_width, map_height)) * COUNTRY_DISTANCE_MAP_RATIO)),
		MIN_COUNTRY_DISTANCE,
		MAX_COUNTRY_DISTANCE)


## Read-only route evaluation shared by the new-game solver, explain UI and
## deterministic geography fixtures. It does not add deposits or mutate MapData.
static func evaluate_starter_route(map: MapData, cell_idx: int) -> Dictionary:
	if map == null or cell_idx < 0 or cell_idx >= map.cell_count() \
			or not map.has_indices():
		return _error("starter_route_cell_invalid",
			"Starter route evaluation requires an indexed map cell.")
	return _starter_route_for_cell(map, cell_idx, map.neighbor_indices_packed())


static func _starter_route_for_cell(map: MapData, cell_idx: int,
		neighbors: PackedInt32Array) -> Dictionary:
	var temperature := float(map.temp_arr[cell_idx])
	var moisture := float(map.moisture_arr[cell_idx])
	var elevation := float(map.elevation_arr[cell_idx])
	var coastal := _has_coastal_water(map, cell_idx, neighbors)
	var riverine := _has_freshwater(map, cell_idx, neighbors)
	var region := "temperate"
	if coastal:
		region = "coastal"
	# A river is not by itself a floodplain. Using the generated paddy-land
	# carrying capacity keeps humid tropical forests reachable while still
	# recognizing deltas, marshes and recurrently flooded river valleys.
	elif riverine and _reserve(map, "paddy_land", cell_idx) > 0.0:
		region = "floodplain"
	elif temperature <= 0.34 or elevation >= 0.68:
		region = "cold_highland"
	elif temperature >= 0.66 and moisture >= 0.62:
		region = "tropical_forest"
	elif moisture <= 0.36 or elevation >= 0.56:
		region = "arid_highland"

	var technologies := PackedStringArray()
	var buildings := PackedStringArray()
	var missing := PackedStringArray()
	var food_good := ""
	var food_resource := ""
	var use_fishing := false
	if coastal and _reserve(map, "marine_fish", cell_idx) > 0.0:
		_append_unique(technologies, "tech.coastal_fishing")
		_append_unique(buildings, "marine_fish_collector")
		food_good = "fish"
		food_resource = "marine_fish"
		use_fishing = true
	elif riverine and _reserve(map, "freshwater_fish", cell_idx) > 0.0:
		_append_unique(technologies, "tech.freshwater_fishing")
		_append_unique(buildings, "freshwater_fishing_camp")
		food_good = "fish"
		food_resource = "freshwater_fish"
		use_fishing = true

	var game_available := _reserve(map, "wild_game", cell_idx) > 0.0
	var plants_available := _reserve(map, "fertile_soil", cell_idx) > 0.0
	var crop_food := false
	if not use_fishing and region == "floodplain" \
			and _reserve(map, "paddy_land", cell_idx) > 0.0 \
			and _vicinity_has_signal(map, cell_idx, neighbors, "bio.rice"):
		_append_unique(technologies, "tech.wild_rice_collection")
		_append_unique(buildings, "wild_rice_marsh")
		food_good = "rice_grain"
		food_resource = "paddy_land"
		crop_food = true
	elif not use_fishing and plants_available \
			and region in ["cold_highland", "arid_highland"] \
			and _vicinity_has_signal(map, cell_idx, neighbors, "bio.potato"):
		_append_unique(technologies, "tech.wild_tuber_collection")
		_append_unique(buildings, "wild_tuber_patch")
		food_good = "potatoes"
		food_resource = "fertile_soil"
		crop_food = true
	elif not use_fishing and plants_available and temperature >= 0.58 \
			and _vicinity_has_signal(map, cell_idx, neighbors, "bio.maize"):
		_append_unique(technologies, "tech.wild_maize_collection")
		_append_unique(buildings, "wild_maize_stand")
		food_good = "corn_grain"
		food_resource = "fertile_soil"
		crop_food = true
	elif not use_fishing and plants_available \
			and _vicinity_has_signal(map, cell_idx, neighbors, "bio.wheat"):
		_append_unique(technologies, "tech.wild_wheat_collection")
		_append_unique(buildings, "wild_wheat_stand")
		food_good = "wheat_grain"
		food_resource = "fertile_soil"
		crop_food = true

	var prefer_game := region in ["cold_highland", "arid_highland"]
	if not use_fishing and not crop_food:
		if game_available and (prefer_game or not plants_available):
			food_resource = "wild_game"
			food_good = "game_meat"
			_append_unique(technologies, "tech.animal_tracking")
			_append_unique(buildings, "small_game_trapline")
		elif plants_available:
			food_resource = "fertile_soil"
			food_good = "gathered_plants"
			_append_unique(technologies, "tech.gathering")
			_append_unique(buildings, "gathering_ground")
		elif game_available:
			food_resource = "wild_game"
			food_good = "game_meat"
			_append_unique(technologies, "tech.animal_tracking")
			_append_unique(buildings, "small_game_trapline")
		else:
			food_resource = "wild_game" if prefer_game else "fertile_soil"
			food_good = "game_meat" if prefer_game else "gathered_plants"
			_append_unique(missing, food_resource)
			if prefer_game:
				_append_unique(technologies, "tech.animal_tracking")
				_append_unique(buildings, "small_game_trapline")
			else:
				_append_unique(technologies, "tech.gathering")
				_append_unique(buildings, "gathering_ground")

	var bast_available := plants_available and (
		_vicinity_has_signal(map, cell_idx, neighbors, "bio.bast_fiber") \
		or _vicinity_has_signal(map, cell_idx, neighbors, "bio.flax"))
	var clothing_resource := ""
	if game_available and (prefer_game or not bast_available):
		clothing_resource = "wild_game"
	elif bast_available:
		clothing_resource = "fertile_soil"
	elif game_available:
		clothing_resource = "wild_game"
	else:
		# Never synthesize a species-discovery signal. A missing animal reserve is
		# the one allowed closure top-up when no real fiber plant was observed.
		clothing_resource = "wild_game"
		_append_unique(missing, clothing_resource)
	if clothing_resource == "wild_game":
		_append_unique(technologies, "tech.animal_tracking")
		_append_unique(technologies, "tech.hide_scraping")
		_append_unique(buildings, "small_game_trapline")
		_append_unique(buildings, "hide_scraping_shelter")
	else:
		_append_unique(technologies, "tech.wild_flax_collection")
		_append_unique(technologies, "tech.fiber_twisting")
		_append_unique(buildings, "bast_fiber_camp")
		_append_unique(buildings, "bast_wrap_shelter")

	var construction_resource := ""
	var construction_good := ""
	if riverine and _reserve(map, "paddy_land", cell_idx) > 0.0 \
			and _vicinity_has_signal(map, cell_idx, neighbors, "bio.reed"):
		construction_resource = "paddy_land"
		construction_good = "reed_bundle"
		_append_unique(technologies, "tech.reed_harvesting")
		_append_unique(buildings, "reed_cutting_camp")
	elif region == "cold_highland" and _reserve(map, "pasture", cell_idx) > 0.0:
		construction_resource = "pasture"
		construction_good = "turf_block"
		_append_unique(technologies, "tech.turf_cutting")
		_append_unique(buildings, "turf_cutting_ground")
	elif _reserve(map, "timber", cell_idx) > 0.0:
		construction_resource = "timber"
		construction_good = "logs"
		_append_unique(technologies, "tech.deadwood_collection")
		_append_unique(buildings, "deadwood_gathering_camp")
	else:
		construction_resource = "clay"
		construction_good = "clay"
		_append_unique(technologies, "tech.earth_building")
		_append_unique(buildings, "earth_digging_pit")
		if _reserve(map, "clay", cell_idx) <= 0.0:
			_append_unique(missing, "clay")

	var knowledge_technology := "tech.phenology_observation"
	var knowledge_building := "seasonal_observation_shelter"
	if coastal:
		knowledge_technology = "tech.tide_observation"
		knowledge_building = "tide_observation_hut"
	elif region == "floodplain":
		knowledge_technology = "tech.flood_calendar_practice"
		knowledge_building = "flood_calendar_shrine"
	elif region in ["cold_highland", "arid_highland"] \
			and _reserve(map, "pasture", cell_idx) > 0.0:
		knowledge_technology = "tech.pastoral_route_memory"
		knowledge_building = "pastoral_council_tent"
	elif region == "tropical_forest":
		knowledge_technology = "tech.oral_memory_practice"
		knowledge_building = "oral_memory_circle"
	_append_unique(technologies, knowledge_technology)
	_append_unique(buildings, knowledge_building)
	# The market post is part of the opening economy rather than free scenery;
	# its organization technology is included and expands through DAG closure.
	_append_unique(technologies, "tech.communal_specialization")
	_append_unique(buildings, "merchant_post")

	return {
		"regional_route": region,
		"starter_technology_ids": technologies,
		"starter_building_ids": buildings,
		"starter_food_good_id": food_good,
		"starter_clothing_good_id": "clothing",
		"starter_construction_good_id": construction_good,
		"starter_knowledge_good_id": "technology_points",
		"starter_food_resource_id": food_resource,
		"starter_clothing_resource_id": clothing_resource,
		"starter_construction_resource_id": construction_resource,
		"starter_input_buffer_good_id": \
			"raw_hide" if clothing_resource == "wild_game" else "bast_fiber",
		"missing_resource_ids": missing,
		"geography_fit": 1.0 if missing.is_empty() else 0.5 / float(missing.size()),
	}


static func _append_precious_route(start: Dictionary, precious_resource: String) -> void:
	var technologies: PackedStringArray = start.get(
		"starter_technology_ids", PackedStringArray())
	var buildings: PackedStringArray = start.get(
		"starter_building_ids", PackedStringArray())
	if precious_resource == "gold_ore":
		_append_unique(technologies, "tech.gold_panning")
		_append_unique(buildings, "placer_gold_working")
	else:
		_append_unique(technologies, "tech.surface_silver_collection")
		_append_unique(buildings, "surface_silver_working")
	start["starter_technology_ids"] = technologies
	start["starter_building_ids"] = buildings
	start["starter_precious_good_id"] = precious_resource


static func _append_unique(values: PackedStringArray, value: String) -> void:
	if not values.has(value):
		values.append(value)


static func _vicinity_has_signal(map: MapData, cell_idx: int,
		neighbors: PackedInt32Array, signal_id: String) -> bool:
	if _cell_has_signal(map, cell_idx, signal_id):
		return true
	var base := cell_idx * 6
	for direction in range(6):
		var neighbor := int(neighbors[base + direction])
		if neighbor >= 0 and _cell_has_signal(map, neighbor, signal_id):
			return true
	return false


static func _cell_has_signal(map: MapData, cell_idx: int, signal_id: String) -> bool:
	var offsets := map.cell_research_signal_offsets
	var ids := map.cell_research_signal_ids
	var values := map.cell_research_signal_values
	if cell_idx < 0 or offsets.size() != map.cell_count() + 1 \
			or ids.size() != values.size():
		return false
	if _research_signal_index_by_id.is_empty():
		var compiled: Dictionary = ResearchSignalCatalogScript.compile_native_catalog()
		if not bool(compiled.get("ok", false)):
			return false
		var stable_ids: PackedStringArray = compiled.research_signal_ids
		for index in range(stable_ids.size()):
			_research_signal_index_by_id[String(stable_ids[index])] = index
	var wanted := int(_research_signal_index_by_id.get(signal_id, -1))
	if wanted < 0:
		return false
	for edge in range(int(offsets[cell_idx]), int(offsets[cell_idx + 1])):
		if int(ids[edge]) == wanted and int(values[edge]) > 0:
			return true
	return false


static func _has_freshwater(map: MapData, cell_idx: int,
		neighbors: PackedInt32Array) -> bool:
	if map.has_river_arr[cell_idx] != 0 or map.is_lake_seed_arr[cell_idx] != 0:
		return true
	var base := cell_idx * 6
	for direction in range(6):
		var neighbor := int(neighbors[base + direction])
		if neighbor >= 0 and (map.has_river_arr[neighbor] != 0 \
				or map.is_lake_seed_arr[neighbor] != 0 \
				or int(map.terrain_arr[neighbor]) == int(TerrainType.TERRAIN.LAKE)):
			return true
	return false


static func _has_coastal_water(map: MapData, cell_idx: int,
		neighbors: PackedInt32Array) -> bool:
	var base := cell_idx * 6
	for direction in range(6):
		var neighbor := int(neighbors[base + direction])
		if neighbor >= 0 and map.is_water_arr[neighbor] != 0 \
				and int(map.terrain_arr[neighbor]) != int(TerrainType.TERRAIN.LAKE):
			return true
	return false


static func _foreign_candidate_better(candidate: Dictionary, distance: int,
		current: Dictionary, current_distance: int) -> bool:
	if distance != current_distance:
		return distance > current_distance
	if int(candidate.closure_missing_count) != int(current.closure_missing_count):
		return int(candidate.closure_missing_count) < int(current.closure_missing_count)
	if bool(candidate.natural_precious) != bool(current.natural_precious):
		return bool(candidate.natural_precious)
	if not is_equal_approx(float(candidate.survival_score), float(current.survival_score)):
		return float(candidate.survival_score) > float(current.survival_score)
	return int(candidate.cell) < int(current.cell)


static func _relax_minimum_distances(map: MapData, neighbors: PackedInt32Array,
		source: int, minimum_distances: PackedInt32Array) -> void:
	var distances := PackedInt32Array()
	distances.resize(map.cell_count())
	distances.fill(-1)
	var queue := PackedInt32Array()
	queue.resize(map.cell_count())
	var head := 0
	var tail := 1
	queue[0] = source
	distances[source] = 0
	while head < tail:
		var cell := int(queue[head])
		head += 1
		var distance := int(distances[cell])
		if distance < int(minimum_distances[cell]):
			minimum_distances[cell] = distance
		var base := cell * 6
		for direction in range(6):
			var neighbor := int(neighbors[base + direction])
			if neighbor < 0 or distances[neighbor] >= 0 \
					or map.is_water_arr[neighbor] != 0 \
					or not TerrainType.is_passable_land(int(map.terrain_arr[neighbor])):
				continue
			distances[neighbor] = distance + 1
			queue[tail] = neighbor
			tail += 1


static func _is_candidate(map: MapData, cell_idx: int, neighbors: PackedInt32Array) -> bool:
	if map.is_water_arr[cell_idx] != 0:
		return false
	if not TerrainType.is_passable_land(int(map.terrain_arr[cell_idx])):
		return false
	var temperature := float(map.temp_arr[cell_idx])
	var moisture := float(map.moisture_arr[cell_idx])
	var elevation := float(map.elevation_arr[cell_idx])
	var vitality := float(map.vegetation_vitality_arr[cell_idx])
	if temperature < Profile.TEMPERATURE_MIN or temperature > Profile.TEMPERATURE_MAX:
		return false
	if moisture < Profile.MOISTURE_MIN or moisture > Profile.MOISTURE_MAX:
		return false
	if elevation < Profile.ELEVATION_MIN or elevation > Profile.ELEVATION_MAX:
		return false
	if vitality < Profile.VITALITY_MIN:
		return false
	if map.has_river_arr[cell_idx] != 0 or map.is_lake_seed_arr[cell_idx] != 0:
		return true
	if _has_coastal_water(map, cell_idx, neighbors):
		return true
	var base := cell_idx * 6
	for direction in range(6):
		var neighbor := int(neighbors[base + direction])
		if neighbor >= 0 and (map.has_river_arr[neighbor] != 0 \
				or map.is_lake_seed_arr[neighbor] != 0 \
				or int(map.terrain_arr[neighbor]) == int(TerrainType.TERRAIN.LAKE)):
			return true
	return false


static func _survival_score(map: MapData, cell_idx: int) -> float:
	var temperature_fit := 1.0 - absf(float(map.temp_arr[cell_idx]) - 0.55) / 0.55
	var moisture_fit := 1.0 - absf(float(map.moisture_arr[cell_idx]) - 0.60) / 0.60
	var elevation_fit := 1.0 - absf(float(map.elevation_arr[cell_idx]) - 0.35) / 0.65
	return temperature_fit * 0.30 + moisture_fit * 0.25 + elevation_fit * 0.15 \
		+ float(map.vegetation_vitality_arr[cell_idx]) * 0.30


static func _precious_for_cell(map: MapData, cell_idx: int, seed: int,
		purpose: String) -> String:
	var natural_gold := _reserve(map, "gold_ore", cell_idx)
	var natural_silver := _reserve(map, "silver_ore", cell_idx)
	if natural_gold > 0.0 or natural_silver > 0.0:
		return "gold_ore" if natural_gold >= natural_silver else "silver_ore"
	return _choose_missing_precious(map, seed, purpose)


static func _choose_missing_precious(map: MapData, seed: int,
		purpose: String = "player_precious") -> String:
	var gold_cells := 0
	var silver_cells := 0
	for cell_idx in range(map.cell_count()):
		if _reserve(map, "gold_ore", cell_idx) > 0.0: gold_cells += 1
		if _reserve(map, "silver_ore", cell_idx) > 0.0: silver_cells += 1
	if gold_cells == silver_cells:
		return "gold_ore" if (_stable_hash(seed, purpose) & 1) == 0 else "silver_ore"
	return "gold_ore" if gold_cells < silver_cells else "silver_ore"


static func _reserve(map: MapData, resource_id: String, cell_idx: int) -> float:
	for profile in ResourceProfileRegistry.ordered():
		if profile != null and String(profile.id) == resource_id:
			var field := ResourceProfileRegistry.reserve_map_field(profile)
			var values = map.get(field)
			return float(values[cell_idx]) if values != null and cell_idx < values.size() else 0.0
	return 0.0


static func _top_up(map: MapData, resource_id: String, cell_idx: int, minimum: float) -> void:
	for profile in ResourceProfileRegistry.ordered():
		if profile == null or String(profile.id) != resource_id:
			continue
		var field := ResourceProfileRegistry.reserve_map_field(profile)
		var values: PackedFloat32Array = map.get(field)
		if cell_idx >= 0 and cell_idx < values.size():
			values[cell_idx] = maxf(values[cell_idx], minimum)
			map.set(field, values)
		return


static func _stable_hash(seed: int, purpose: String) -> int:
	var value := int(seed) & 0x7fffffff
	for byte in purpose.to_utf8_buffer():
		value = int((value * 16777619) ^ int(byte)) & 0x7fffffff
	return value


static func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "message": message}
