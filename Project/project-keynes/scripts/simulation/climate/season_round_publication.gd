extends RefCounted

## Publishes each completed seasonal update and its sampled diagnostics.


static func continue_finish_season_round_b_plus(context, map: MapData, max_cells: int = 128) -> Dictionary:
	var out: Dictionary = {"done": false, "cursor": context._generator._season_round_b_plus_publish_cursor, "work_done": 0}
	if not context._generator._season_round_b_plus_publish_active:
		out["done"] = true
		return out
	if map == null:
		context._generator._season_round_b_plus_publish_active = false
		out["done"] = true
		return out
	var n: int = map.cell_count()
	var terrain_a: PackedByteArray = map.terrain_arr
	var landform_a: PackedByteArray = map.landform_arr
	var vegetation_a: PackedByteArray = map.vegetation_arr
	var cover_a: PackedByteArray = map.cover_arr
	var water_a: PackedByteArray = map.is_water_arr
	var volcano_a: PackedByteArray = map.has_volcano_arr
	var cells: Array = map.iter_cells() if map.has_indices() else map.all_cells()
	var water_lut: PackedByteArray = MapData.is_water_lut()
	var volcano_lf: int = int(LandformType.LF.VOLCANO)
	var cursor: int = clampi(context._generator._season_round_b_plus_publish_cursor, 0, n)
	var start_cursor: int = cursor
	var end: int = mini(n, cursor + clampi(max_cells, 32, 256))
	while cursor < end:
		if cursor < volcano_a.size() and int(volcano_a[cursor]) != 0 and cursor < landform_a.size() \
				and int(landform_a[cursor]) != volcano_lf:
			landform_a[cursor] = volcano_lf
			if cursor < map.base_landform_arr.size():
				map.base_landform_arr[cursor] = volcano_lf
		var cell: HexCell = cells[cursor] if cursor < cells.size() else null
		if cell != null:
			var terrain_changed: bool = cursor < terrain_a.size() and int(cell.terrain) != int(terrain_a[cursor])
			if terrain_changed:
				cell.apply_terrain(int(terrain_a[cursor]))
				context._generator._season_round_b_plus_publish_terrain_fixed += 1
			if cursor < terrain_a.size() and cursor < water_a.size():
				water_a[cursor] = water_lut[int(terrain_a[cursor]) & 0xFF]
			var landform_changed: bool = cursor < landform_a.size() and int(cell.landform) != int(landform_a[cursor])
			var vegetation_changed: bool = cursor < vegetation_a.size() and int(cell.vegetation) != int(vegetation_a[cursor])
			var cover_changed: bool = cursor < cover_a.size() and int(cell.cover) != int(cover_a[cursor])
			if landform_changed:
				cell.landform = int(landform_a[cursor])
			if vegetation_changed:
				cell.vegetation = int(vegetation_a[cursor])
			if cover_changed:
				cell.cover = int(cover_a[cursor])
			if landform_changed or vegetation_changed or cover_changed:
				context._generator._season_round_b_plus_publish_axis_fixed += 1
			if (terrain_changed or landform_changed or vegetation_changed or cover_changed) \
					and cell.current_state != null and not cell.current_state.is_empty():
				cell.current_state["biome"] = int(cell.terrain)
				cell.current_state["landform"] = int(cell.landform)
				cell.current_state["vegetation"] = int(cell.vegetation)
				cell.current_state["cover"] = int(cell.cover)
				context._generator._season_round_b_plus_publish_state_fixed += 1
			# Preserve one history sample per completed round without per-cell method
			# calls. The direct writes are identical to HexCell.push_*_history().
			if cell.biome_history.size() < HexCell.HISTORY_LEN:
				cell.biome_history.resize(HexCell.HISTORY_LEN)
				for h in range(HexCell.HISTORY_LEN):
					cell.biome_history[h] = int(cell.terrain) & 0xFF
			cell.biome_history[cell._history_idx] = int(cell.terrain) & 0xFF
			cell._history_idx = (cell._history_idx + 1) % HexCell.HISTORY_LEN
			if cell.vegetation_history.size() < HexCell.HISTORY_LEN:
				cell.vegetation_history.resize(HexCell.HISTORY_LEN)
				for h in range(HexCell.HISTORY_LEN):
					cell.vegetation_history[h] = int(cell.vegetation) & 0xFF
			cell.vegetation_history[cell._veg_history_idx] = int(cell.vegetation) & 0xFF
			cell._veg_history_idx = (cell._veg_history_idx + 1) % HexCell.HISTORY_LEN
		cursor += 1
	context._generator._season_round_b_plus_publish_cursor = cursor
	out["cursor"] = cursor
	out["work_done"] = cursor - start_cursor
	if cursor < n:
		return out
	if landform_a.size() == n:
		map.landform_arr = landform_a
	context._generator._write_runtime_enum_axes_dense(map)
	context._generator._season_round_b_plus_publish_active = false
	context._generator._season_round_b_plus_facade_published = true
	context._generator._last_season_refresh_breakdown["terrain_facade_fixed"] = context._generator._season_round_b_plus_publish_terrain_fixed
	context._generator._last_season_refresh_breakdown["axis_facade_fixed"] = context._generator._season_round_b_plus_publish_axis_fixed
	context._generator._last_season_refresh_breakdown["current_state_fixed"] = context._generator._season_round_b_plus_publish_state_fixed
	var wall_ms_now: float = float(Time.get_ticks_usec() - context._generator._b_plus_round_start_usec) / 1000.0 \
			if context._generator._b_plus_round_start_usec > 0 else 0.0
	context._generator._b_plus_rounds_total += 1
	context._generator._b_plus_rounds_b_plus += 1
	context._generator._b_plus_slices_used_samples.append(context._generator._season_round_b_plus_slices_used)
	context._generator._b_plus_stages_done_samples.append(context._generator._season_round_b_plus_stages_done)
	context._generator._b_plus_native_ms_samples.append(context._generator._season_round_b_plus_native_ms)
	context._generator._b_plus_wall_ms_samples.append(wall_ms_now)
	context._generator._season_round_b_plus_native_ms = 0.0
	context._generator._season_round_b_plus_slices_used = 0
	context._generator._season_round_b_plus_stages_done = 0
	context._generator._b_plus_round_start_usec = 0
	out["done"] = true
	return out

# 一次性取走 B+ round 验收样本，清零内部计数。
# 由 dots_final_frontier_perf_verdict.evaluate 调用，避免长期持有。

static func pop_b_plus_round_samples(context) -> Dictionary:
	var slices_arr: Array = []
	for v in context._generator._b_plus_slices_used_samples:
		slices_arr.append(int(v))
	var stages_arr: Array = []
	for v in context._generator._b_plus_stages_done_samples:
		stages_arr.append(int(v))
	var native_arr: Array = []
	for v in context._generator._b_plus_native_ms_samples:
		native_arr.append(float(v))
	var wall_arr: Array = []
	for v in context._generator._b_plus_wall_ms_samples:
		wall_arr.append(float(v))
	var out: Dictionary = {
		"rounds_total": context._generator._b_plus_rounds_total,
		"rounds_b_plus": context._generator._b_plus_rounds_b_plus,
		"rounds_fallback": context._generator._b_plus_rounds_fallback,
		"slices_used_samples": slices_arr,
		"stages_done_samples": stages_arr,
		"native_ms_samples": native_arr,
		"wall_ms_samples": wall_arr,
	}
	context._generator._b_plus_rounds_total = 0
	context._generator._b_plus_rounds_b_plus = 0
	context._generator._b_plus_rounds_fallback = 0
	context._generator._b_plus_slices_used_samples.clear()
	context._generator._b_plus_stages_done_samples.clear()
	context._generator._b_plus_native_ms_samples.clear()
	context._generator._b_plus_wall_ms_samples.clear()
	return out
