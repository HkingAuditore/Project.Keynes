class_name StartLocationPolicy
extends RefCounted

const Profile = preload("res://scripts/game/start_location_profile.gd")
const ResearchSignalCatalogScript = preload(
	"res://scripts/research/research_signal_catalog.gd")
const TechnologyCatalogScript = preload("res://scripts/economy/technology_catalog.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const StarterEconomyPlannerScript = preload(
	"res://scripts/economy/starter_economy_planner.gd")
const VisionSolverScript = preload("res://scripts/geography/vision_solver.gd")
const COUNTRY_NAME_PACK_PATH := "res://data/country/default_country_names.tres"
const UNREACHABLE_DISTANCE := 0x3fffffff
const COUNTRY_DISTANCE_MAP_RATIO := 0.15
const MIN_COUNTRY_DISTANCE := 4
const MAX_COUNTRY_DISTANCE := 12

static var _research_signal_index_by_id: Dictionary = {}
static var _research_signal_occupancy_bit: PackedInt32Array = PackedInt32Array()
static var _starter_catalog_cache: Dictionary = {}
static var _active_reserve_overlay: Dictionary = {}


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
		var gold := _raw_reserve(map, "gold_ore", cell_idx)
		var silver := _raw_reserve(map, "silver_ore", cell_idx)
		var survival_score := _survival_score(map, cell_idx)
		candidates.append({
			"cell": cell_idx,
			"score": survival_score,
			"survival_score": survival_score,
			"natural_precious": gold > 0.0 or silver > 0.0,
			"closure_missing_count": 0,
		})
	if candidates.is_empty():
		return _error("starter_capability_unsatisfied",
			"没有找到气候与通行条件合格的出生地。")
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if bool(a.natural_precious) != bool(b.natural_precious):
			return bool(a.natural_precious)
		if not is_equal_approx(float(a.survival_score), float(b.survival_score)):
			return float(a.survival_score) > float(b.survival_score)
		return int(a.cell) < int(b.cell))
	var chosen: Dictionary = {}
	for candidate in candidates:
		if _close_candidate_route(map, world, neighbors, starter_catalog, candidate):
			chosen = candidate
			break
	if chosen.is_empty():
		return _error("starter_capability_unsatisfied",
			"没有找到能以真实本地资源和可见地理信号闭合生存核心开局的出生地。")
	var top_count := maxi(1, candidates.size() / 4)
	var cell_idx := int(chosen.cell)
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
		var ordered: Array[Dictionary] = []
		for candidate in remaining:
			var candidate_distance := int(nearest_start[int(candidate.cell)])
			if candidate_distance < minimum_distance:
				continue
			ordered.append(candidate)
		ordered.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return _foreign_candidate_better(
				a, int(nearest_start[int(a.cell)]),
				b, int(nearest_start[int(b.cell)])))
		var best: Dictionary = {}
		var best_distance := -1
		for candidate in ordered:
			if not _close_candidate_route(map, world, neighbors, starter_catalog,
					candidate):
				continue
			best = candidate
			best_distance = int(nearest_start[int(candidate.cell)])
			break
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
	var player_precious := String(chosen.starter_route.get("precious_resource", ""))
	var player_start := {
		"country_id": "country.player",
		"country_name": player_country_name,
		"name_id": "",
		"cell": cell_idx,
		"precious_resource": player_precious,
		"is_player": true,
		"selection_distance": 0,
	}
	player_start.merge((chosen.starter_route as Dictionary).duplicate(true), true)
	_append_precious_route(player_start, player_precious)
	country_starts.append(player_start)
	for foreign_index in range(foreign_count):
		var foreign_cell := int(foreign_cells[foreign_index])
		var foreign_route: Dictionary = foreign_routes[foreign_index]
		var foreign_start := {
			"country_id": "country.foreign.%03d" % (foreign_index + 1),
			"country_name": String(foreign_names[foreign_index]),
			"name_id": String(foreign_name_ids[foreign_index]),
			"cell": foreign_cell,
			"precious_resource": String(foreign_route.get("precious_resource", "")),
			"is_player": false,
			"selection_distance": int(foreign_selection_distances[foreign_index]),
		}
		foreign_start.merge(foreign_route, true)
		_append_precious_route(foreign_start, String(foreign_start.precious_resource))
		country_starts.append(foreign_start)
	_apply_start_resource_topups(map, country_starts)
	return {
		"ok": true,
		"code": "ok",
		"message": "",
		"cell": cell_idx,
		"precious_resource": player_precious,
		"candidate_count": candidates.size(),
		"top_quartile_count": top_count,
		"score": float(chosen.score),
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
		_signals_for_visible_cells(map, visible_report.visible, catalog), catalog, {})


static func _starter_route_for_cell(map: MapData, cell_idx: int,
		neighbors: PackedInt32Array, signal_probe: Dictionary,
		starter_catalog: Dictionary, overlay: Dictionary = {}) -> Dictionary:
	_active_reserve_overlay = overlay
	signal_probe = _with_overlay_resource_signals(signal_probe, starter_catalog, overlay)
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
	var is_cold := region == "cold_highland"
	var technologies := PackedStringArray()
	var buildings := PackedStringArray()
	var discovered_food_goods := PackedStringArray()
	var discovered_food_resources := PackedStringArray()
	if _reserve(map, "fertile_soil", cell_idx) > 0.0:
		_append_unique(technologies, "tech.gathering")
		_append_unique(buildings, "gathering_ground")
		_append_unique(discovered_food_goods, "gathered_plants")
		_append_unique(discovered_food_resources, "fertile_soil")
	if _reserve(map, "wild_game", cell_idx) > 0.0:
		_append_unique(technologies, "tech.hunting")
		_append_unique(buildings, "stone_age_hunting_camp")
		_append_unique(discovered_food_goods, "game_meat")
		_append_unique(discovered_food_resources, "wild_game")
	if discovered_food_goods.is_empty():
		return _error("starter_food_unavailable", "出生点没有已发现的可运行食物生产方式。")
	_append_unique(technologies, "tech.early_trade")
	_append_unique(buildings, "early_merchant_post")
	if precious_resource == "gold_ore":
		_append_unique(technologies, "tech.gold_panning")
		_append_unique(buildings, "placer_gold_working")
	else:
		_append_unique(technologies, "tech.surface_silver_collection")
		_append_unique(buildings, "surface_silver_working")
	var clothing_resource := ""
	var input_buffer := ""
	if is_cold:
		if _reserve(map, "wild_game", cell_idx) <= 0.0:
			return _error("starter_clothing_unavailable",
				"寒冷出生点缺少猎物，无法预建生皮刮制。")
		_append_unique(technologies, "tech.hide_scraping")
		_append_unique(buildings, "hide_scraping_shelter")
		clothing_resource = "wild_game"
		input_buffer = "raw_hide"
	var construction := StarterEconomyPlannerScript.select_construction_backbone(
		map, cell_idx)
	if not bool(construction.get("ok", false)):
		return construction
	var construction_tech := String(construction.get("tech_id", ""))
	var construction_building := String(construction.get("building_id", ""))
	var construction_good := String(construction.get("good_id", ""))
	var construction_resource := String(construction.get("resource_id", ""))
	if construction_tech.is_empty() or construction_building.is_empty() \
			or construction_good.is_empty() or construction_resource.is_empty():
		return _error("starter_construction_backbone_unavailable",
			"出生点没有可揭示的初始建材采集营。")
	_append_unique(technologies, construction_tech)
	_append_unique(buildings, construction_building)
	if not _starter_technologies_revealed(technologies, signal_probe, starter_catalog):
		return _error("starter_reveal_condition_unsatisfied",
			"生存核心科技缺少当前可见地理证据。")
	var validation := _validate_starter_technologies(
		technologies, buildings, signal_probe, starter_catalog)
	if not bool(validation.get("ok", false)):
		return validation
	var pending_knowledge := StarterEconomyPlannerScript.select_pending_knowledge(
		map, cell_idx, region)
	if not bool(pending_knowledge.get("ok", false)):
		return pending_knowledge
	var pending_tech := String(pending_knowledge.get("tech_id", ""))
	var pending_building := String(pending_knowledge.get("building_id", ""))
	if pending_tech.is_empty() or pending_building.is_empty():
		return _error("starter_knowledge_route_missing", "出生点没有可揭示的初始知识实践。")
	var discovered_technologies := PackedStringArray()
	_append_unique(discovered_technologies, pending_tech)
	var route := {
		"regional_route": region,
		"starter_technology_ids": technologies,
		"starter_discovered_technology_ids": discovered_technologies,
		"pending_knowledge_tech_id": pending_tech,
		"pending_knowledge_building_id": pending_building,
		"starter_building_ids": buildings,
		"starter_food_good_ids": discovered_food_goods,
		"starter_clothing_good_id": "clothing",
		"starter_construction_good_id": construction_good,
		"starter_knowledge_good_id": "technology_points",
		"starter_food_resource_ids": discovered_food_resources,
		"starter_clothing_resource_id": clothing_resource,
		"starter_construction_resource_id": construction_resource,
		"starter_input_buffer_good_id": input_buffer,
		"starter_precious_good_id": _precious_good_id(precious_resource),
		"precious_resource": precious_resource,
		"missing_resource_ids": PackedStringArray(),
		"visible_signal_ids": signal_probe.signal_ids,
		"visible_signal_cells": signal_probe.signal_cells,
		"geography_fit": 1.0,
		"reserve_overlay": overlay.duplicate(true),
		"ok": true,
	}
	var planned := StarterEconomyPlannerScript.plan(map, cell_idx, route)
	if not bool(planned.get("ok", false)):
		var failure := _error("starter_capability_unsatisfied",
			"没有闭合采集、狩猎、贵金属和贸易核心的出生点路线。")
		failure["planner_failure"] = planned
		return failure
	route.merge(planned, true)
	return route


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
		if technology_index < 0 or not _starter_technology_revealed(
			technology_index, signal_probe.counts, catalog, {}):
			return false
	return true


static func _starter_technology_revealed(technology_index: int,
		signal_counts: Dictionary, catalog: Dictionary, visiting: Dictionary) -> bool:
	# A zero-cost starter application may have no separate reveal condition when
	# its hard prerequisite is the observable identification step. In that case,
	# inherit the prerequisite's evidence without granting the non-starter node.
	if technology_index < 0 or visiting.has(technology_index):
		return false
	visiting[technology_index] = true
	var offsets: PackedInt32Array = catalog.technology_reveal_condition_offsets
	var direct_condition_present := technology_index + 1 < offsets.size() \
			and int(offsets[technology_index]) < int(offsets[technology_index + 1])
	if direct_condition_present:
		var direct_result := _reveal_condition_met(
			technology_index, signal_counts, catalog)
		visiting.erase(technology_index)
		return direct_result
	var prerequisite_offsets: PackedInt32Array = catalog.get(
		"technology_prerequisite_offsets", PackedInt32Array())
	var prerequisites: PackedInt32Array = catalog.get(
		"technology_prerequisites", PackedInt32Array())
	if technology_index + 1 >= prerequisite_offsets.size():
		visiting.erase(technology_index)
		return false
	var begin := int(prerequisite_offsets[technology_index])
	var end := int(prerequisite_offsets[technology_index + 1])
	if begin >= end:
		visiting.erase(technology_index)
		return false
	for edge in range(begin, end):
		if edge < 0 or edge >= prerequisites.size() \
				or not _starter_technology_revealed(
					int(prerequisites[edge]), signal_counts, catalog, visiting):
			visiting.erase(technology_index)
			return false
	visiting.erase(technology_index)
	return true


static func _starter_route_better(candidate: Dictionary, current: Dictionary) -> bool:
	if int(candidate.get("weakest_supply_coverage_q16", 0)) != int(current.get(
			"weakest_supply_coverage_q16", 0)):
		return int(candidate.get("weakest_supply_coverage_q16", 0)) > int(current.get(
			"weakest_supply_coverage_q16", 0))
	if int(candidate.get("resource_pressure_q16", 0)) != int(current.get(
			"resource_pressure_q16", 0)):
		return int(candidate.get("resource_pressure_q16", 0)) < int(current.get(
			"resource_pressure_q16", 0))
	if int(candidate.get("overproduction_quantity", 0)) != int(current.get(
			"overproduction_quantity", 0)):
		return int(candidate.get("overproduction_quantity", 0)) < int(current.get(
			"overproduction_quantity", 0))
	if int(candidate.get("starter_building_total", 0)) != int(current.get(
			"starter_building_total", 0)):
		return int(candidate.get("starter_building_total", 0)) < int(current.get(
			"starter_building_total", 0))
	var candidate_buildings: PackedStringArray = candidate.starter_building_ids
	var current_buildings: PackedStringArray = current.starter_building_ids
	if candidate_buildings.size() != current_buildings.size():
		return candidate_buildings.size() < current_buildings.size()
	# Discovery count is deliberately absent: the opening grant is a fixed
	# survival core, not a union of every visible starter node.
	return str(candidate_buildings) < str(current_buildings)


static func _append_precious_route(start: Dictionary, precious_resource: String) -> void:
	var technologies: PackedStringArray = start.get(
		"starter_technology_ids", PackedStringArray())
	var buildings: PackedStringArray = start.get(
		"starter_building_ids", PackedStringArray())
	var counts: PackedInt64Array = start.get(
		"starter_building_counts", PackedInt64Array())
	var old_building_count := buildings.size()
	_append_precious_route_values(technologies, buildings, precious_resource)
	while counts.size() < buildings.size():
		counts.append(1)
	start["starter_technology_ids"] = technologies
	start["starter_building_ids"] = buildings
	if not counts.is_empty() or buildings.size() != old_building_count:
		start["starter_building_counts"] = counts
	start["starter_precious_good_id"] = _precious_good_id(precious_resource)


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
		if technology_index < 0 or not _starter_technology_revealed(
				technology_index, signal_probe.counts, catalog, {}):
			return _error("starter_reveal_condition_unsatisfied",
				"开局科技缺少当前可见地理证据：%s" % technology_id)
		var offsets: PackedInt32Array = catalog.technology_starter_capability_offsets
		var tags: PackedStringArray = catalog.technology_starter_capability_tags
		for edge in range(offsets[technology_index], offsets[technology_index + 1]):
			capabilities[String(tags[edge])] = true
	for required in ["starter.food", "starter.precious_metal", "starter.trade",
			"starter.construction"]:
		if not capabilities.has(required):
			return _error("starter_capability_unsatisfied",
				"开局路线缺少能力：%s" % required)
	if technology_ids.has("tech.hide_scraping") and not capabilities.has("starter.clothing"):
		return _error("starter_capability_unsatisfied", "寒冷开局缺少衣着能力。")
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
		var owner_slots: PackedInt64Array = catalog.get("building_owner_slots", PackedInt64Array())
		total_owner_slots += int(owner_slots[building_index])
	if total_owner_slots > 20:
		return _error("starter_population_overcommitted", "开局建筑自营岗位容量超过初始人口规模。")
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


static func _close_candidate_route(map: MapData, world: WorldData,
		neighbors: PackedInt32Array, starter_catalog: Dictionary,
		candidate: Dictionary) -> bool:
	if candidate.has("starter_route"):
		return bool((candidate.starter_route as Dictionary).get("ok", false))
	var cell_idx := int(candidate.cell)
	var overlay := _starter_resource_overlay(map, cell_idx)
	var visible_report := VisionSolverScript.compute_visible_for_sources(
		map, world, PackedInt32Array([cell_idx]))
	if not bool(visible_report.get("ok", false)):
		candidate["starter_route"] = _error("starter_route_probe_failed",
			"无法计算出生点可见科技信号。")
		return false
	var starter_route := _starter_route_for_cell(
		map, cell_idx, neighbors,
		_signals_for_visible_cells(map, visible_report.visible, starter_catalog),
		starter_catalog, overlay)
	candidate["starter_route"] = starter_route
	candidate["starter_building_count"] = int(starter_route.get(
		"starter_building_total", (starter_route.get(
			"starter_building_ids", PackedStringArray()) as PackedStringArray).size()))
	return bool(starter_route.get("ok", false))


static func _starter_resource_overlay(map: MapData, cell_idx: int) -> Dictionary:
	var overlay := {}
	for resource_id in Profile.OPENING_TOPUP_RESOURCE_IDS:
		var minimum := float(Profile.MINIMUM_RESERVES.get(String(resource_id), 0.0))
		if minimum <= 0.0:
			continue
		overlay[String(resource_id)] = maxf(
			_raw_reserve(map, String(resource_id), cell_idx), minimum)
	var precious_id := _precious_for_raw_cell(map, cell_idx)
	if precious_id.is_empty():
		precious_id = "gold_ore"
	overlay[precious_id] = maxf(
		_raw_reserve(map, precious_id, cell_idx),
		float(Profile.MINIMUM_RESERVES.get(precious_id, 0.0)))
	return overlay


static func _with_overlay_resource_signals(signal_probe: Dictionary,
		catalog: Dictionary, overlay: Dictionary) -> Dictionary:
	if overlay.is_empty():
		return signal_probe
	var counts: Dictionary = (signal_probe.get("counts", {}) as Dictionary).duplicate()
	var ids: PackedStringArray = catalog.get("research_signal_ids", PackedStringArray())
	for resource_id in overlay:
		if float(overlay[resource_id]) <= 0.0:
			continue
		var signal_index := ids.find("resource.%s" % String(resource_id))
		if signal_index >= 0:
			counts[signal_index] = maxi(int(counts.get(signal_index, 0)), 1)
	return {
		"counts": counts,
		"signal_ids": signal_probe.get("signal_ids", PackedInt32Array()),
		"signal_cells": signal_probe.get("signal_cells", PackedInt32Array()),
	}


static func _apply_start_resource_topups(map: MapData,
		country_starts: Array[Dictionary]) -> void:
	_active_reserve_overlay = {}
	for start in country_starts:
		var overlay: Dictionary = start.get("reserve_overlay", {})
		var cell_idx := int(start.get("cell", -1))
		var topups := {}
		var missing := PackedStringArray()
		for resource_id in overlay:
			var target := float(overlay[resource_id])
			var current := _raw_reserve(map, String(resource_id), cell_idx)
			if target > current + 0.0001:
				_write_reserve(map, String(resource_id), cell_idx, target)
				topups[String(resource_id)] = target - current
				missing.append(String(resource_id))
		start.erase("reserve_overlay")
		if not topups.is_empty():
			start["resource_topups"] = topups
			start["missing_resource_ids"] = missing


static func _write_reserve(map: MapData, resource_id: String, cell_idx: int,
		amount: float) -> void:
	for profile in ResourceProfileRegistry.ordered():
		if profile == null or String(profile.id) != resource_id:
			continue
		var field := ResourceProfileRegistry.reserve_map_field(profile)
		if field.is_empty():
			return
		var values = map.get(field)
		if values == null or cell_idx < 0 or cell_idx >= values.size():
			return
		values[cell_idx] = amount
		map.set(field, values)
		return


static func _is_candidate(map: MapData, cell_idx: int, _neighbors: PackedInt32Array) -> bool:
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
	return true


static func _survival_score(map: MapData, cell_idx: int) -> float:
	var temperature_fit := 1.0 - absf(float(map.temp_arr[cell_idx]) - 0.55) / 0.55
	var moisture_fit := 1.0 - absf(float(map.moisture_arr[cell_idx]) - 0.60) / 0.60
	var elevation_fit := 1.0 - absf(float(map.elevation_arr[cell_idx]) - 0.35) / 0.65
	return temperature_fit * 0.30 + moisture_fit * 0.25 + elevation_fit * 0.15 \
		+ float(map.vegetation_vitality_arr[cell_idx]) * 0.30


static func _precious_for_raw_cell(map: MapData, cell_idx: int) -> String:
	var natural_gold := _raw_reserve(map, "gold_ore", cell_idx)
	var natural_silver := _raw_reserve(map, "silver_ore", cell_idx)
	if natural_gold > 0.0 or natural_silver > 0.0:
		return "gold_ore" if natural_gold >= natural_silver else "silver_ore"
	return ""


static func _precious_for_cell(map: MapData, cell_idx: int) -> String:
	var natural_gold := _reserve(map, "gold_ore", cell_idx)
	var natural_silver := _reserve(map, "silver_ore", cell_idx)
	if natural_gold > 0.0 or natural_silver > 0.0:
		return "gold_ore" if natural_gold >= natural_silver else "silver_ore"
	return ""


static func _precious_good_id(precious_resource: String) -> String:
	return "silver" if precious_resource == "silver_ore" else "gold"


static func _raw_reserve(map: MapData, resource_id: String, cell_idx: int) -> float:
	for profile in ResourceProfileRegistry.ordered():
		if profile != null and String(profile.id) == resource_id:
			var field := ResourceProfileRegistry.reserve_map_field(profile)
			var values = map.get(field)
			return float(values[cell_idx]) if values != null and cell_idx < values.size() else 0.0
	return 0.0


static func _reserve(map: MapData, resource_id: String, cell_idx: int) -> float:
	var actual := _raw_reserve(map, resource_id, cell_idx)
	if _active_reserve_overlay.has(resource_id):
		return maxf(actual, float(_active_reserve_overlay[resource_id]))
	return actual


static func _stable_hash(seed: int, purpose: String) -> int:
	var value := int(seed) & 0x7fffffff
	for byte in purpose.to_utf8_buffer():
		value = int((value * 16777619) ^ int(byte)) & 0x7fffffff
	return value


static func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "message": message}
