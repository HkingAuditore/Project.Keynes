class_name StartLocationPolicy
extends RefCounted

const StartRoutes = preload("res://scripts/game/start_location_routes.gd")

const Profile = preload("res://scripts/game/start_location_profile.gd")
const CandidateOrder = preload("res://scripts/game/start_location_candidates.gd")
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
const STARTER_POPULATION := StartRoutes.STARTER_POPULATION
## 玩家落点门槛：所在大陆的陆地格数下限（水格 landmass_id == 0，不计数）。
## 取 4 而不是 2：LM2（3 格）、LM7（2 格）也要退出玩家候选（gate_10 §2）。
const MIN_PLAYER_LANDMASS_LAND_CELLS := 4



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
		var survival_score := _survival_score(map, cell_idx)
		candidates.append({
			"cell": cell_idx,
			"score": survival_score,
			"survival_score": survival_score,
			"natural_precious": gold > 0.0,
			"closure_missing_count": 0,
		})
	if candidates.is_empty():
		return _error("starter_capability_unsatisfied",
			"没有找到气候与通行条件合格的出生地。")
	CandidateOrder.rank_for_player(candidates, map)
	var chosen: Dictionary = {}
	# 玩家落点两趟：第一趟跳过所在大陆不足 MIN_PLAYER_LANDMASS_LAND_CELLS 格的碎岛；
	# 若第一趟被筛空（全池都是小岛），第二趟不带门槛重跑同一循环，
	# 再落回下面的 starter_capability_unsatisfied——只加一层会把小岛地图变成新的硬失败。
	var player_landmass_land_cells := _landmass_land_cell_counts(map)
	for player_pass in range(2):
		var landmass_gate_active := player_pass == 0
		for candidate in candidates:
			if landmass_gate_active and _skips_small_landmass(
					map, player_landmass_land_cells, int(candidate.cell)):
				continue
			if _close_candidate_route(map, world, neighbors, starter_catalog, candidate):
				chosen = candidate
				break
		if not chosen.is_empty():
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
		"regime_id": "early_clan",
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
			"regime_id": "early_clan",
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
	return StartRoutes.evaluate_starter_route(map, cell_idx, world)


static func _starter_route_for_cell(map: MapData, cell_idx: int,
		neighbors: PackedInt32Array, signal_probe: Dictionary,
		starter_catalog: Dictionary, overlay: Dictionary = {}) -> Dictionary:
	return StartRoutes._starter_route_for_cell(map, cell_idx, neighbors, signal_probe, starter_catalog, overlay)


static func _append_precious_route(start: Dictionary, precious_resource: String) -> void:
	StartRoutes._append_precious_route(start, precious_resource)


static func _starter_catalog() -> Dictionary:
	return StartRoutes._starter_catalog()


static func _signals_for_visible_cells(map: MapData, visible: PackedByteArray,
		catalog: Dictionary) -> Dictionary:
	return StartRoutes._signals_for_visible_cells(map, visible, catalog)


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
	return StartRoutes._with_overlay_resource_signals(signal_probe, catalog, overlay)


static func _apply_start_resource_topups(map: MapData,
		country_starts: Array[Dictionary]) -> void:
	StartRoutes._active_reserve_overlay = {}
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


## 一次数清每块大陆的陆地格数：landmass_id → 格数。
## 水格 landmass_id == 0，不计数（component_ids.gd:232 的语义）。
## 数组缺失或长度不足时返回空字典，调用方据此关掉门槛、保持旧行为。
static func _landmass_land_cell_counts(map: MapData) -> Dictionary:
	var counts: Dictionary = {}
	var ids := map.landmass_id_arr
	if ids.size() < map.cell_count():
		return counts
	for cell_idx in range(map.cell_count()):
		var landmass_id := int(ids[cell_idx])
		if landmass_id == 0:
			continue
		counts[landmass_id] = int(counts.get(landmass_id, 0)) + 1
	return counts


## 玩家落点门槛：该格所在大陆陆地格数是否不足 MIN_PLAYER_LANDMASS_LAND_CELLS。
## 只在玩家落点排序之后过筛；候选池、_is_candidate、外国落点都不走这里。
static func _skips_small_landmass(map: MapData, landmass_land_cells: Dictionary,
		cell_idx: int) -> bool:
	if landmass_land_cells.is_empty():
		return false
	var ids := map.landmass_id_arr
	if cell_idx < 0 or cell_idx >= ids.size():
		return false
	var landmass_id := int(ids[cell_idx])
	if landmass_id == 0:
		return true
	return int(landmass_land_cells.get(landmass_id, 0)) < MIN_PLAYER_LANDMASS_LAND_CELLS


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
	return "gold_ore" if natural_gold > 0.0 else ""


static func _precious_for_cell(map: MapData, cell_idx: int) -> String:
	return StartRoutes._precious_for_cell(map, cell_idx)


static func _precious_good_id(precious_resource: String) -> String:
	return StartRoutes._precious_good_id(precious_resource)


static func _raw_reserve(map: MapData, resource_id: String, cell_idx: int) -> float:
	return StartRoutes._raw_reserve(map, resource_id, cell_idx)


static func _reserve(map: MapData, resource_id: String, cell_idx: int) -> float:
	return StartRoutes._reserve(map, resource_id, cell_idx)


static func _stable_hash(seed: int, purpose: String) -> int:
	var value := int(seed) & 0x7fffffff
	for byte in purpose.to_utf8_buffer():
		value = int((value * 16777619) ^ int(byte)) & 0x7fffffff
	return value


static func _error(code: String, message: String) -> Dictionary:
	return StartRoutes._error(code, message)


static func select_and_prepare_cooperative(map: MapData, world: WorldData, seed: int, foreign_count: int = 0,
		player_country_name: String = "新国家", frame_gate = null) -> Dictionary:
	var tree := Engine.get_main_loop() as SceneTree
	var slice_start := Time.get_ticks_usec()
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
		if tree != null and Time.get_ticks_usec()-slice_start>=UITokens.LOADING_MAIN_SLICE_USEC:
			await (frame_gate.next_frame() if frame_gate != null else tree.process_frame)
			if frame_gate != null and frame_gate.canceled:
				return _error("loading_canceled", "生成已取消。")
			slice_start = Time.get_ticks_usec()
		if not _is_candidate(map, cell_idx, neighbors):
			continue
		var gold := _raw_reserve(map, "gold_ore", cell_idx)
		var survival_score := _survival_score(map, cell_idx)
		candidates.append({
			"cell": cell_idx,
			"score": survival_score,
			"survival_score": survival_score,
			"natural_precious": gold > 0.0,
			"closure_missing_count": 0,
		})
	if candidates.is_empty():
		return _error("starter_capability_unsatisfied",
			"没有找到气候与通行条件合格的出生地。")
	CandidateOrder.rank_for_player(candidates, map)
	var chosen: Dictionary = {}
	# 与同步版同一套两趟逻辑：第一趟带大陆格数门槛，被筛空则第二趟不带门槛重跑。
	var player_landmass_land_cells := _landmass_land_cell_counts(map)
	for player_pass in range(2):
		var landmass_gate_active := player_pass == 0
		for candidate in candidates:
			if tree != null and Time.get_ticks_usec()-slice_start>=UITokens.LOADING_MAIN_SLICE_USEC:
				await (frame_gate.next_frame() if frame_gate != null else tree.process_frame)
				if frame_gate != null and frame_gate.canceled:
					return _error("loading_canceled", "生成已取消。")
				slice_start = Time.get_ticks_usec()
			if landmass_gate_active and _skips_small_landmass(
					map, player_landmass_land_cells, int(candidate.cell)):
				continue
			if _close_candidate_route(map, world, neighbors, starter_catalog, candidate):
				chosen = candidate
				break
		if not chosen.is_empty():
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
		if tree != null and Time.get_ticks_usec()-slice_start>=UITokens.LOADING_MAIN_SLICE_USEC:
			await (frame_gate.next_frame() if frame_gate != null else tree.process_frame)
			if frame_gate != null and frame_gate.canceled:
				return _error("loading_canceled", "生成已取消。")
			slice_start = Time.get_ticks_usec()
		if int(candidate.cell) != cell_idx:
			remaining.append(candidate)
	for _foreign_index in range(foreign_count):
		if tree != null and Time.get_ticks_usec()-slice_start>=UITokens.LOADING_MAIN_SLICE_USEC:
			await (frame_gate.next_frame() if frame_gate != null else tree.process_frame)
			if frame_gate != null and frame_gate.canceled:
				return _error("loading_canceled", "生成已取消。")
			slice_start = Time.get_ticks_usec()
		var ordered: Array[Dictionary] = []
		for candidate in remaining:
			if tree != null and Time.get_ticks_usec()-slice_start>=UITokens.LOADING_MAIN_SLICE_USEC:
				await (frame_gate.next_frame() if frame_gate != null else tree.process_frame)
				if frame_gate != null and frame_gate.canceled:
					return _error("loading_canceled", "生成已取消。")
				slice_start = Time.get_ticks_usec()
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
			if tree != null and Time.get_ticks_usec()-slice_start>=UITokens.LOADING_MAIN_SLICE_USEC:
				await (frame_gate.next_frame() if frame_gate != null else tree.process_frame)
				if frame_gate != null and frame_gate.canceled:
					return _error("loading_canceled", "生成已取消。")
				slice_start = Time.get_ticks_usec()
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
			if tree != null and Time.get_ticks_usec()-slice_start>=UITokens.LOADING_MAIN_SLICE_USEC:
				await (frame_gate.next_frame() if frame_gate != null else tree.process_frame)
				if frame_gate != null and frame_gate.canceled:
					return _error("loading_canceled", "生成已取消。")
				slice_start = Time.get_ticks_usec()
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
		"regime_id": "early_clan",
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
		if tree != null and Time.get_ticks_usec()-slice_start>=UITokens.LOADING_MAIN_SLICE_USEC:
			await (frame_gate.next_frame() if frame_gate != null else tree.process_frame)
			if frame_gate != null and frame_gate.canceled:
				return _error("loading_canceled", "生成已取消。")
			slice_start = Time.get_ticks_usec()
		var foreign_cell := int(foreign_cells[foreign_index])
		var foreign_route: Dictionary = foreign_routes[foreign_index]
		var foreign_start := {
			"country_id": "country.foreign.%03d" % (foreign_index + 1),
			"regime_id": "early_clan",
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

