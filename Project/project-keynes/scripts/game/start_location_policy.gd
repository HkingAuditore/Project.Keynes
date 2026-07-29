class_name StartLocationPolicy
extends RefCounted

const Profile = preload("res://scripts/game/start_location_profile.gd")
const COUNTRY_NAME_PACK_PATH := "res://data/country/default_country_names.tres"
const UNREACHABLE_DISTANCE := 0x3fffffff


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
		candidates.append({
			"cell": cell_idx,
			"score": survival_score + (0.35 if precious > 0.0 else 0.0),
			"survival_score": survival_score,
			"natural_precious": precious > 0.0,
		})
	if candidates.is_empty():
		return _error("no_survivable_start", "没有找到同时满足陆地、气候与淡水条件的出生地。")
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if bool(a.natural_precious) != bool(b.natural_precious):
			return bool(a.natural_precious)
		if not is_equal_approx(float(a.score), float(b.score)):
			return float(a.score) > float(b.score)
		return int(a.cell) < int(b.cell))
	var top_count := maxi(1, int(ceil(candidates.size() * 0.25)))
	var chosen_index := _stable_hash(seed, "player_start") % top_count
	var cell_idx := int(candidates[chosen_index].cell)
	var minimum_distance := clampi(
		int(round(float(mini(map.width, map.height)) * 0.25)), 6, 16)
	var nearest_start := PackedInt32Array()
	nearest_start.resize(map.cell_count())
	nearest_start.fill(UNREACHABLE_DISTANCE)
	_relax_minimum_distances(map, neighbors, cell_idx, nearest_start)
	var foreign_cells := PackedInt32Array()
	var foreign_selection_distances := PackedInt32Array()
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
	country_starts.append({
		"country_id": "country.player",
		"country_name": player_country_name,
		"name_id": "",
		"cell": cell_idx,
		"precious_resource": player_precious,
		"is_player": true,
		"selection_distance": 0,
	})
	for foreign_index in range(foreign_count):
		var foreign_cell := int(foreign_cells[foreign_index])
		country_starts.append({
			"country_id": "country.foreign.%03d" % (foreign_index + 1),
			"country_name": String(foreign_names[foreign_index]),
			"name_id": String(foreign_name_ids[foreign_index]),
			"cell": foreign_cell,
			"precious_resource": _precious_for_cell(
				map, foreign_cell, seed,
				"foreign_precious_%03d" % (foreign_index + 1)),
			"is_player": false,
			"selection_distance": int(foreign_selection_distances[foreign_index]),
		})
	for start in country_starts:
		var start_cell := int(start.cell)
		var precious_id := String(start.precious_resource)
		for resource_id in [
				"fertile_soil", "timber", "wild_game", "stone", "flint", precious_id]:
			_top_up(map, resource_id, start_cell,
				float(Profile.MINIMUM_RESERVES[resource_id]))
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


static func _foreign_candidate_better(candidate: Dictionary, distance: int,
		current: Dictionary, current_distance: int) -> bool:
	if distance != current_distance:
		return distance > current_distance
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
