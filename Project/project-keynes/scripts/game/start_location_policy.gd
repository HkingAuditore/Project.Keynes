class_name StartLocationPolicy
extends RefCounted

const Profile = preload("res://scripts/game/start_location_profile.gd")
const ResearchSignalCatalogScript = preload(
	"res://scripts/research/research_signal_catalog.gd")
const TechnologyCatalogScript = preload("res://scripts/economy/technology_catalog.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const VisionSolverScript = preload("res://scripts/geography/vision_solver.gd")
const COUNTRY_NAME_PACK_PATH := "res://data/country/default_country_names.tres"
const UNREACHABLE_DISTANCE := 0x3fffffff
const COUNTRY_DISTANCE_MAP_RATIO := 0.15
const MIN_COUNTRY_DISTANCE := 4
const MAX_COUNTRY_DISTANCE := 12

static var _research_signal_index_by_id: Dictionary = {}
static var _research_signal_occupancy_bit: PackedInt32Array = PackedInt32Array()
static var _starter_catalog_cache: Dictionary = {}


static func select_and_prepare(map: MapData, world: WorldData, seed: int, foreign_count: int = 0,
		player_country_name: String = "新国家") -> Dictionary:
	if map == null or world == null or map.cell_count() <= 0:
		return _error("start_world_missing", "生成的世界不包含可用地块。")
	if foreign_count < NewGameConfig.MIN_FOREIGN_COUNT \
			or foreign_count > NewGameConfig.MAX_FOREIGN_COUNT:
		return _error("foreign_count_out_of_range", "外国数量超出允许范围。")
	var candidates: Array[Dictionary] = []
	var neighbors := map.neighbor_indices_packed()
	var starter_catalog := _starter_catalog()
	if not bool(starter_catalog.get("ok", false)):
		return starter_catalog
	for cell_idx in range(map.cell_count()):
		if not _is_candidate(map, cell_idx, neighbors):
			continue
		var gold := _reserve(map, "gold_ore", cell_idx)
		var silver := _reserve(map, "silver_ore", cell_idx)
		var precious := maxf(gold, silver)
		var survival_score := _survival_score(map, cell_idx)
		if precious <= 0.0:
			continue
		var visible_report := VisionSolverScript.compute_visible_for_sources(
			map, world, PackedInt32Array([cell_idx]))
		if not bool(visible_report.get("ok", false)):
			continue
		var visible: PackedByteArray = visible_report.visible
		var signal_probe := _signals_for_visible_cells(map, visible, starter_catalog)
		var starter_route := _starter_route_for_cell(
			map, cell_idx, neighbors, signal_probe, starter_catalog)
		if not bool(starter_route.get("ok", false)):
			continue
		candidates.append({
			"cell": cell_idx,
			"score": survival_score,
			"survival_score": survival_score,
			"natural_precious": true,
			"starter_route": starter_route,
			"closure_missing_count": 0,
			"starter_technology_count": (starter_route.starter_technology_ids as PackedStringArray).size(),
			"starter_building_count": (starter_route.starter_building_ids as PackedStringArray).size(),
		})
	if candidates.is_empty():
		return _error("starter_capability_unsatisfied",
			"没有找到能以真实本地资源和可见地理信号闭合六项开局能力的出生地。")
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a.starter_technology_count) != int(b.starter_technology_count):
			return int(a.starter_technology_count) < int(b.starter_technology_count)
		if int(a.starter_building_count) != int(b.starter_building_count):
			return int(a.starter_building_count) < int(b.starter_building_count)
		if not is_equal_approx(float(a.survival_score), float(b.survival_score)):
			return float(a.survival_score) > float(b.survival_score)
		return int(a.cell) < int(b.cell))
	var top_count := 1
	var chosen_index := 0
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
	var player_precious := _precious_for_cell(map, cell_idx)
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
			"precious_resource": _precious_for_cell(map, foreign_cell),
			"is_player": false,
			"selection_distance": int(foreign_selection_distances[foreign_index]),
		}
		foreign_start.merge(foreign_routes[foreign_index], true)
		_append_precious_route(foreign_start, String(foreign_start.precious_resource))
		country_starts.append(foreign_start)
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
static func evaluate_starter_route(map: MapData, cell_idx: int,
		world: WorldData = null) -> Dictionary:
	if map == null or cell_idx < 0 or cell_idx >= map.cell_count() \
			or not map.has_indices():
		return _error("starter_route_cell_invalid",
			"Starter route evaluation requires an indexed map cell.")
	var effective_world := world if world != null else WorldData.new()
	var catalog := _starter_catalog()
	var visible_report := VisionSolverScript.compute_visible_for_sources(
		map, effective_world, PackedInt32Array([cell_idx]))
	if not bool(catalog.get("ok", false)) or not bool(visible_report.get("ok", false)):
		return _error("starter_route_probe_failed", "无法计算出生点可见科技信号。")
	return _starter_route_for_cell(map, cell_idx, map.neighbor_indices_packed(),
		_signals_for_visible_cells(map, visible_report.visible, catalog), catalog)


static func _starter_route_for_cell(map: MapData, cell_idx: int,
		neighbors: PackedInt32Array, signal_probe: Dictionary,
		starter_catalog: Dictionary) -> Dictionary:
	var temperature := float(map.temp_arr[cell_idx])
	var moisture := float(map.moisture_arr[cell_idx])
	var elevation := float(map.elevation_arr[cell_idx])
	var coastal := _has_coastal_water(map, cell_idx, neighbors)
	var riverine := _has_freshwater_access(map, cell_idx, neighbors)
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

	var precious_resource := _precious_for_cell(map, cell_idx)
	if precious_resource.is_empty():
		return _error("starter_precious_metal_unavailable",
			"首都格没有天然金矿或银矿。")
	var food_options: Array[Dictionary] = []
	if coastal and _reserve(map, "marine_fish", cell_idx) > 0.0:
		food_options.append(_route_option(["tech.coastal_fishing"],
			["marine_fish_collector"], {"food_good": "fish", "food_resource": "marine_fish"}))
	if riverine and _reserve(map, "freshwater_fish", cell_idx) > 0.0:
		food_options.append(_route_option(["tech.freshwater_fishing"],
			["freshwater_fishing_camp"], {"food_good": "fish", "food_resource": "freshwater_fish"}))
	if region in ["cold_highland", "arid_highland"] \
			and _reserve(map, "fertile_soil", cell_idx) > 0.0 \
			and _probe_has_signal(signal_probe, starter_catalog, "bio.potato"):
		food_options.append(_route_option(["tech.wild_tuber_collection"],
			["wild_tuber_patch"], {"food_good": "potatoes", "food_resource": "fertile_soil"}))
	if _reserve(map, "fertile_soil", cell_idx) > 0.0:
		food_options.append(_route_option(["tech.gathering"],
			["gathering_ground"],
			{"food_good": "gathered_plants", "food_resource": "fertile_soil"}))
	if _reserve(map, "wild_game", cell_idx) > 0.0:
		# Hunting camp construction still spends gathered_plants, so the hunting
		# food closure carries gathering when soil evidence can reveal it.
		# Gathering does not reveal hunting; grassland no longer stands in.
		var hunting_food_techs: Array = ["tech.hunting"]
		if _reserve(map, "fertile_soil", cell_idx) > 0.0:
			hunting_food_techs.append("tech.gathering")
		food_options.append(_route_option(hunting_food_techs,
			["stone_age_hunting_camp"],
			{"food_good": "game_meat", "food_resource": "wild_game"}))

	var clothing_options: Array[Dictionary] = []
	if _reserve(map, "fertile_soil", cell_idx) > 0.0 \
			and (_probe_has_signal(signal_probe, starter_catalog, "bio.flax") \
				or _probe_has_signal(signal_probe, starter_catalog, "bio.bast_fiber")):
		# Bast clothing requires seeing flax or bast plants, not just fertile soil.
		clothing_options.append(_route_option(["tech.gathering", "tech.wild_flax_collection"],
			["bast_fiber_camp", "bast_wrap_shelter"],
			{"clothing_resource": "fertile_soil", "input_buffer": "bast_fiber"}))
	if _reserve(map, "wild_game", cell_idx) > 0.0:
		var hide_techs: Array = ["tech.hunting", "tech.hide_scraping"]
		if _reserve(map, "fertile_soil", cell_idx) > 0.0:
			hide_techs.append("tech.gathering")
		clothing_options.append(_route_option(hide_techs,
			["stone_age_hunting_camp", "hide_scraping_shelter"],
			{"clothing_resource": "wild_game", "input_buffer": "raw_hide"}))

	var construction_options: Array[Dictionary] = []
	if _reserve(map, "paddy_land", cell_idx) > 0.0:
		construction_options.append(_route_option(["tech.reed_harvesting"],
			["reed_cutting_camp"], {"construction_good": "reed_bundle", "construction_resource": "paddy_land"}))
	if _reserve(map, "pasture", cell_idx) > 0.0:
		construction_options.append(_route_option(["tech.turf_cutting"],
			["turf_cutting_ground"], {"construction_good": "turf_block", "construction_resource": "pasture"}))
	if _reserve(map, "timber", cell_idx) > 0.0:
		construction_options.append(_route_option(["tech.deadwood_collection"],
			["deadwood_gathering_camp"], {"construction_good": "logs", "construction_resource": "timber"}))
	if _reserve(map, "clay", cell_idx) > 0.0:
		construction_options.append(_route_option(["tech.earth_building"],
			["earth_digging_pit"], {"construction_good": "clay", "construction_resource": "clay"}))

	var knowledge_options: Array[Dictionary] = [
		# Knowledge buildings consume their local construction good. Keep the
		# material technology in the same route so the building dependency is
		# closed before bootstrap, rather than granting a hidden prerequisite.
		_route_option(["tech.reed_harvesting", "tech.flood_calendar_practice"],
			["reed_cutting_camp", "flood_calendar_shrine"], {}),
		_route_option(["tech.turf_cutting", "tech.pastoral_route_memory"],
			["turf_cutting_ground", "pastoral_council_tent"], {}),
		_route_option(["tech.deadwood_collection", "tech.oral_memory_practice"],
			["deadwood_gathering_camp", "oral_memory_circle"], {}),
		_route_option(["tech.deadwood_collection", "tech.phenology_observation"],
			["deadwood_gathering_camp", "seasonal_observation_shelter"], {}),
		_route_option(["tech.reed_harvesting", "tech.tide_observation"],
			["reed_cutting_camp", "tide_observation_hut"], {}),
	]
	var precious_option := _route_option(
		["tech.gold_panning"] if precious_resource == "gold_ore" else ["tech.surface_silver_collection"],
		["placer_gold_working"] if precious_resource == "gold_ore" else ["surface_silver_working"], {})
	var trade_option := _route_option(["tech.early_trade"], ["early_merchant_post"], {})
	var best: Dictionary = {}
	for food in food_options:
		for clothing in clothing_options:
			for construction in construction_options:
				for knowledge in knowledge_options:
					var technologies := PackedStringArray()
					var buildings := PackedStringArray()
					for option in [food, clothing, construction, knowledge, precious_option, trade_option]:
						_append_many_unique(technologies, option.technology_ids)
						_append_many_unique(buildings, option.building_ids)
					if not _starter_technologies_revealed(technologies, signal_probe, starter_catalog):
						continue
					var validation := _validate_starter_technologies(
						technologies, buildings, signal_probe, starter_catalog)
					if not bool(validation.get("ok", false)):
						continue
					var route := {
						"regional_route": region,
						"starter_technology_ids": technologies,
						"starter_building_ids": buildings,
						"starter_food_good_id": String(food.food_good),
						"starter_clothing_good_id": "clothing",
						"starter_construction_good_id": String(construction.construction_good),
						"starter_knowledge_good_id": "technology_points",
						"starter_food_resource_id": String(food.food_resource),
						"starter_clothing_resource_id": String(clothing.clothing_resource),
						"starter_construction_resource_id": String(construction.construction_resource),
						"starter_input_buffer_good_id": String(clothing.input_buffer),
						"starter_precious_good_id": precious_resource,
						"precious_resource": precious_resource,
						"missing_resource_ids": PackedStringArray(),
						"visible_signal_ids": signal_probe.signal_ids,
						"visible_signal_cells": signal_probe.signal_cells,
						"geography_fit": 1.0,
						"ok": true,
					}
					if best.is_empty() or _starter_route_better(route, best):
						best = route
	if best.is_empty():
		return _error("starter_capability_unsatisfied",
			"没有闭合食物、衣物、建材、知识、贵金属和贸易能力的出生点路线。")
	return best


static func _route_option(technology_ids: Array, building_ids: Array,
		values: Dictionary) -> Dictionary:
	var technology_values := PackedStringArray()
	var building_values := PackedStringArray()
	for technology_id in technology_ids:
		technology_values.append(String(technology_id))
	for building_id in building_ids:
		building_values.append(String(building_id))
	var option := {
		"technology_ids": technology_values,
		"building_ids": building_values,
	}
	for key in values:
		option[String(key)] = values[key]
	return option


static func _append_many_unique(values: PackedStringArray,
		candidates: PackedStringArray) -> void:
	for value in candidates:
		_append_unique(values, String(value))


static func _probe_has_signal(signal_probe: Dictionary, catalog: Dictionary,
		signal_id: String) -> bool:
	var ids: PackedStringArray = catalog.get("research_signal_ids", PackedStringArray())
	var signal_index := ids.find(signal_id)
	if signal_index < 0:
		return false
	return int((signal_probe.get("counts", {}) as Dictionary).get(signal_index, 0)) > 0


static func _starter_technologies_revealed(technology_ids: PackedStringArray,
		signal_probe: Dictionary, catalog: Dictionary) -> bool:
	for technology_id in technology_ids:
		var technology_index := (catalog.technology_ids as PackedStringArray).find(
			String(technology_id))
		if technology_index < 0 or not _reveal_condition_met(
			technology_index, signal_probe.counts, catalog):
			return false
	return true


static func _starter_route_better(candidate: Dictionary, current: Dictionary) -> bool:
	var candidate_buildings: PackedStringArray = candidate.starter_building_ids
	var current_buildings: PackedStringArray = current.starter_building_ids
	var candidate_technologies: PackedStringArray = candidate.starter_technology_ids
	var current_technologies: PackedStringArray = current.starter_technology_ids
	if candidate_buildings.size() != current_buildings.size():
		return candidate_buildings.size() < current_buildings.size()
	if candidate_technologies.size() != current_technologies.size():
		return candidate_technologies.size() < current_technologies.size()
	return String(candidate.starter_food_good_id) < String(current.starter_food_good_id)


static func _append_precious_route(start: Dictionary, precious_resource: String) -> void:
	var technologies: PackedStringArray = start.get(
		"starter_technology_ids", PackedStringArray())
	var buildings: PackedStringArray = start.get(
		"starter_building_ids", PackedStringArray())
	_append_precious_route_values(technologies, buildings, precious_resource)
	start["starter_technology_ids"] = technologies
	start["starter_building_ids"] = buildings
	start["starter_precious_good_id"] = precious_resource


static func _append_precious_route_values(technologies: PackedStringArray,
		buildings: PackedStringArray, precious_resource: String) -> void:
	if precious_resource == "gold_ore":
		_append_unique(technologies, "tech.gold_panning")
		_append_unique(buildings, "placer_gold_working")
	elif precious_resource == "silver_ore":
		_append_unique(technologies, "tech.surface_silver_collection")
		_append_unique(buildings, "surface_silver_working")


static func _starter_catalog() -> Dictionary:
	if not _starter_catalog_cache.is_empty():
		return _starter_catalog_cache
	# Building/material/resource closure validation needs the merged economy
	# catalog. It contains the authoritative technology columns as well as the
	# goods, buildings and local-resource dependency IR.
	var compiled := EconomyCatalogScript.compile_native_catalog()
	if not bool(compiled.get("ok", false)):
		return compiled
	var starter_set := {}
	for technology_id in compiled.starter_eligible_technology_ids:
		starter_set[String(technology_id)] = true
	compiled["starter_eligible_set"] = starter_set
	_starter_catalog_cache = compiled
	return _starter_catalog_cache


static func _signals_for_visible_cells(map: MapData, visible: PackedByteArray,
		catalog: Dictionary) -> Dictionary:
	var counts := {}
	var signal_ids := PackedInt32Array()
	var signal_cells := PackedInt32Array()
	var offsets: PackedInt32Array = map.cell_research_signal_offsets
	var ids: PackedInt32Array = map.cell_research_signal_ids
	var values: PackedInt32Array = map.cell_research_signal_values
	var signal_count := (catalog.research_signal_ids as PackedStringArray).size()
	for cell in range(mini(map.cell_count(), visible.size())):
		if visible[cell] == 0:
			continue
		if offsets.size() == map.cell_count() + 1 and ids.size() == values.size():
			for edge in range(offsets[cell], offsets[cell + 1]):
				var signal_index := int(ids[edge])
				if signal_index < 0 or signal_index >= signal_count or int(values[edge]) <= 0:
					continue
				counts[signal_index] = int(counts.get(signal_index, 0)) + 1
				signal_ids.append(signal_index)
				signal_cells.append(cell)
		if cell < map.bio_occupancy_bits_arr.size():
			for signal_index in ResearchSignalCatalogScript.occupancy_signal_indices(
					catalog, int(map.bio_occupancy_bits_arr[cell])):
				counts[signal_index] = int(counts.get(signal_index, 0)) + 1
				signal_ids.append(int(signal_index))
				signal_cells.append(cell)
	return {"counts": counts, "signal_ids": signal_ids,
		"signal_cells": signal_cells}


static func _validate_starter_technologies(technology_ids: PackedStringArray,
		building_ids: PackedStringArray, signal_probe: Dictionary, catalog: Dictionary) -> Dictionary:
	var stable_ids: PackedStringArray = catalog.technology_ids
	var starter_set: Dictionary = catalog.starter_eligible_set
	var capabilities := {}
	for technology_id in technology_ids:
		if not starter_set.has(String(technology_id)):
			return _error("starter_technology_not_eligible",
				"开局路线包含非 starter 科技：%s" % technology_id)
		var technology_index := stable_ids.find(String(technology_id))
		if technology_index < 0 or not _reveal_condition_met(
				technology_index, signal_probe.counts, catalog):
			return _error("starter_reveal_condition_unsatisfied",
				"开局科技缺少当前可见地理证据：%s" % technology_id)
		var offsets: PackedInt32Array = catalog.technology_starter_capability_offsets
		var tags: PackedStringArray = catalog.technology_starter_capability_tags
		for edge in range(offsets[technology_index], offsets[technology_index + 1]):
			capabilities[String(tags[edge])] = true
	for required in ["starter.food", "starter.clothing", "starter.construction",
			"starter.knowledge", "starter.precious_metal", "starter.trade"]:
		if not capabilities.has(required):
			return _error("starter_capability_unsatisfied",
				"开局路线缺少能力：%s" % required)
	var building_type_ids: PackedStringArray = catalog.get("building_type_ids", PackedStringArray())
	var completed := {}; for id in technology_ids: completed[String(id)] = true
	var total_owner_slots := 0
	for building_id in building_ids:
		var building_index := building_type_ids.find(String(building_id))
		if building_index < 0:
			return _error("starter_building_missing", "开局建筑不在经济目录：%s" % building_id)
		var direct_offsets: PackedInt32Array = catalog.get("building_technology_tag_offsets", PackedInt32Array())
		var direct_tags: PackedStringArray = catalog.get("building_technology_tags", PackedStringArray())
		for edge in range(direct_offsets[building_index], direct_offsets[building_index + 1]):
			var tag := String(direct_tags[edge])
			if tag.begins_with("tech.") and not completed.has(tag):
				return _error("starter_building_technology_missing", "%s 缺少 direct technology %s" % [building_id, tag])
		var required_offsets: PackedInt32Array = catalog.get("building_required_technology_tag_offsets", PackedInt32Array())
		var required_tags: PackedStringArray = catalog.get("building_required_technology_tags", PackedStringArray())
		for edge in range(required_offsets[building_index], required_offsets[building_index + 1]):
			if not completed.has(String(required_tags[edge])):
				return _error("starter_building_required_technology_missing", "%s 缺少 required technology %s" % [building_id, required_tags[edge]])
		var branch_offsets: PackedInt32Array = catalog.get("building_dependency_branch_offsets", PackedInt32Array())
		var branch_tech_offsets: PackedInt32Array = catalog.get("building_dependency_branch_technology_offsets", PackedInt32Array())
		var branch_techs: PackedInt32Array = catalog.get("building_dependency_branch_technologies", PackedInt32Array())
		var branch_group_offsets: PackedInt32Array = catalog.get("building_dependency_branch_group_offsets", PackedInt32Array())
		var dependency_tag_offsets: PackedInt32Array = catalog.get("building_dependency_tag_offsets", PackedInt32Array())
		var dependency_tags: PackedInt32Array = catalog.get("building_dependency_tags", PackedInt32Array())
		var branch_begin := int(branch_offsets[building_index]); var branch_end := int(branch_offsets[building_index + 1]); var branch_ok := false
		for branch in range(branch_begin, branch_end):
			var tech_ok := true
			for edge in range(branch_tech_offsets[branch], branch_tech_offsets[branch + 1]):
				if not completed.has(String(stable_ids[branch_techs[edge]])): tech_ok = false; break
			if not tech_ok:
				continue
			var groups_ok := true
			for group in range(branch_group_offsets[branch], branch_group_offsets[branch + 1]):
				var group_ok := false
				for edge in range(dependency_tag_offsets[group], dependency_tag_offsets[group + 1]):
					if completed.has(String(stable_ids[dependency_tags[edge]])):
						group_ok = true; break
				if not group_ok:
					groups_ok = false; break
			if groups_ok:
				branch_ok = true; break
		if not branch_ok:
			return _error("starter_building_dependency_missing", "开局建筑依赖未闭合：%s" % building_id)
		var owner_slots: PackedInt64Array = catalog.get("building_owner_slots", PackedInt64Array())
		total_owner_slots += int(owner_slots[building_index])
	if total_owner_slots >= 20:
		return _error("starter_population_overcommitted", "开局建筑业主槽位占用超过初始人口。")
	if not building_ids.has("early_merchant_post"):
		return _error("starter_trade_building_missing", "开局必须预建早期商栈。")
	return {"ok": true}


static func _reveal_condition_met(technology_index: int, signal_counts: Dictionary,
		catalog: Dictionary) -> bool:
	var offsets: PackedInt32Array = catalog.technology_reveal_condition_offsets
	var ops: PackedInt32Array = catalog.technology_reveal_condition_ops
	var refs: PackedInt32Array = catalog.technology_reveal_condition_refs
	var values: PackedInt64Array = catalog.technology_reveal_condition_values
	if technology_index < 0 or technology_index + 1 >= offsets.size():
		return false
	var stack: Array[bool] = []
	for edge in range(offsets[technology_index], offsets[technology_index + 1]):
		match int(ops[edge]):
			TechnologyCatalogScript.CONDITION_PUSH_TECH_COMPLETED:
				stack.append(false)
			TechnologyCatalogScript.CONDITION_PUSH_SIGNAL_PRESENT:
				stack.append(int(signal_counts.get(int(refs[edge]), 0)) > 0)
			TechnologyCatalogScript.CONDITION_PUSH_SIGNAL_COUNT:
				stack.append(int(signal_counts.get(int(refs[edge]), 0)) >= int(values[edge]))
			TechnologyCatalogScript.CONDITION_ALL_OF, TechnologyCatalogScript.CONDITION_ANY_OF, \
					TechnologyCatalogScript.CONDITION_AT_LEAST:
				var child_count := int(refs[edge])
				if child_count <= 0 or stack.size() < child_count:
					return false
				var true_count := 0
				for _child in range(child_count):
					if stack.pop_back():
						true_count += 1
				var required := child_count
				if int(ops[edge]) == TechnologyCatalogScript.CONDITION_ANY_OF:
					required = 1
				elif int(ops[edge]) == TechnologyCatalogScript.CONDITION_AT_LEAST:
					required = int(values[edge])
				stack.append(true_count >= required)
			TechnologyCatalogScript.CONDITION_NOT:
				if stack.is_empty():
					return false
				stack.append(not stack.pop_back())
			_:
				return false
	return stack.size() == 1 and bool(stack[0])


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
	if cell_idx < 0 or map == null:
		return false
	if _research_signal_index_by_id.is_empty():
		var compiled: Dictionary = ResearchSignalCatalogScript.compile_native_catalog()
		if not bool(compiled.get("ok", false)):
			return false
		var stable_ids: PackedStringArray = compiled.research_signal_ids
		for index in range(stable_ids.size()):
			_research_signal_index_by_id[String(stable_ids[index])] = index
		_research_signal_occupancy_bit = compiled.get(
			"research_signal_occupancy_bit", PackedInt32Array())
	var wanted := int(_research_signal_index_by_id.get(signal_id, -1))
	if wanted < 0:
		return false
	var offsets := map.cell_research_signal_offsets
	var ids := map.cell_research_signal_ids
	var values := map.cell_research_signal_values
	if offsets.size() == map.cell_count() + 1 and ids.size() == values.size() \
			and cell_idx + 1 < offsets.size():
		for edge in range(int(offsets[cell_idx]), int(offsets[cell_idx + 1])):
			if int(ids[edge]) == wanted and int(values[edge]) > 0:
				return true
	if cell_idx < map.bio_occupancy_bits_arr.size() \
			and wanted < _research_signal_occupancy_bit.size():
		var bit := int(_research_signal_occupancy_bit[wanted])
		if bit >= 0 and bit < 32 \
				and (int(map.bio_occupancy_bits_arr[cell_idx]) & (1 << bit)) != 0:
			return true
	return false


static func _has_freshwater_access(map: MapData, cell_idx: int,
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


static func _precious_for_cell(map: MapData, cell_idx: int) -> String:
	var natural_gold := _reserve(map, "gold_ore", cell_idx)
	var natural_silver := _reserve(map, "silver_ore", cell_idx)
	if natural_gold > 0.0 or natural_silver > 0.0:
		return "gold_ore" if natural_gold >= natural_silver else "silver_ore"
	return ""


static func _reserve(map: MapData, resource_id: String, cell_idx: int) -> float:
	for profile in ResourceProfileRegistry.ordered():
		if profile != null and String(profile.id) == resource_id:
			var field := ResourceProfileRegistry.reserve_map_field(profile)
			var values = map.get(field)
			return float(values[cell_idx]) if values != null and cell_idx < values.size() else 0.0
	return 0.0


static func _stable_hash(seed: int, purpose: String) -> int:
	var value := int(seed) & 0x7fffffff
	for byte in purpose.to_utf8_buffer():
		value = int((value * 16777619) ^ int(byte)) & 0x7fffffff
	return value


static func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "message": message}
