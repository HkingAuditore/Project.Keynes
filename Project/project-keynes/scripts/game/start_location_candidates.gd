extends RefCounted

const MIN_PLAYER_LANDMASS_LAND_CELLS := 4


static func rank_for_player(candidates: Array[Dictionary], map: MapData) -> void:
	var landmass_ids := map.landmass_id_arr
	var sizes: Dictionary = {}
	if landmass_ids.size() == map.cell_count():
		for landmass_id in landmass_ids:
			if landmass_id != 0:
				sizes[landmass_id] = int(sizes.get(landmass_id, 0)) + 1
	# Try larger landmasses first. Keep every eligible start as a candidate
	# when only small islands have a viable starter route.
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if not sizes.is_empty():
			var a_large := int(sizes.get(landmass_ids[int(a.cell)], 0)) >= MIN_PLAYER_LANDMASS_LAND_CELLS
			var b_large := int(sizes.get(landmass_ids[int(b.cell)], 0)) >= MIN_PLAYER_LANDMASS_LAND_CELLS
			if a_large != b_large:
				return a_large
		if bool(a.natural_precious) != bool(b.natural_precious):
			return bool(a.natural_precious)
		if not is_equal_approx(float(a.survival_score), float(b.survival_score)):
			return float(a.survival_score) > float(b.survival_score)
		return int(a.cell) < int(b.cell))
