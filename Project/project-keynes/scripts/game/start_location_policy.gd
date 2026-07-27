class_name StartLocationPolicy
extends RefCounted

const Profile = preload("res://scripts/game/start_location_profile.gd")


static func select_and_prepare(map: MapData, seed: int) -> Dictionary:
	if map == null or map.cell_count() <= 0:
		return _error("start_world_missing", "生成的世界不包含可用地块。")
	var candidates: Array[Dictionary] = []
	var neighbors := map.neighbor_indices_packed()
	for cell_idx in range(map.cell_count()):
		if not _is_candidate(map, cell_idx, neighbors):
			continue
		var gold := _reserve(map, "gold_ore", cell_idx)
		var silver := _reserve(map, "silver_ore", cell_idx)
		var precious := maxf(gold, silver)
		candidates.append({
			"cell": cell_idx,
			"score": _survival_score(map, cell_idx) + (0.35 if precious > 0.0 else 0.0),
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
	var natural_gold := _reserve(map, "gold_ore", cell_idx)
	var natural_silver := _reserve(map, "silver_ore", cell_idx)
	var precious_id := "gold_ore" if natural_gold >= natural_silver and natural_gold > 0.0 else "silver_ore"
	if natural_gold <= 0.0 and natural_silver <= 0.0:
		precious_id = _choose_missing_precious(map, seed)
	for resource_id in ["fertile_soil", "timber", "wild_game", "stone", "flint", precious_id]:
		_top_up(map, resource_id, cell_idx, float(Profile.MINIMUM_RESERVES[resource_id]))
	return {
		"ok": true,
		"code": "ok",
		"message": "",
		"cell": cell_idx,
		"precious_resource": precious_id,
		"candidate_count": candidates.size(),
		"top_quartile_count": top_count,
		"score": float(candidates[chosen_index].score),
	}


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


static func _choose_missing_precious(map: MapData, seed: int) -> String:
	var gold_cells := 0
	var silver_cells := 0
	for cell_idx in range(map.cell_count()):
		if _reserve(map, "gold_ore", cell_idx) > 0.0: gold_cells += 1
		if _reserve(map, "silver_ore", cell_idx) > 0.0: silver_cells += 1
	if gold_cells == silver_cells:
		return "gold_ore" if (_stable_hash(seed, "player_precious") & 1) == 0 else "silver_ore"
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
