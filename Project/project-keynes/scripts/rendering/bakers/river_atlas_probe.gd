extends RefCounted


static func set_river_atlas_probe_enabled(baker: MapBaker, enabled: bool, map: MapData = null) -> Dictionary:
	baker._river_atlas_probe_enabled = enabled
	if enabled:
		baker._river_atlas_probe_rows.clear()
		# Cell selection is deferred to the next LUT bake so the GM click remains cheap.
		baker._river_atlas_probe_cells.clear()
	else:
		baker._river_atlas_probe_context.clear()
	return baker.get_river_atlas_probe_state()


static func get_river_atlas_probe_state(baker: MapBaker) -> Dictionary:
	return {
		"enabled": baker._river_atlas_probe_enabled,
		"sample_count": baker._river_atlas_probe_rows.size(),
		"cell_count": baker._river_atlas_probe_cells.size(),
	}


static func set_river_atlas_probe_context(baker: MapBaker, context: Dictionary) -> void:
	if baker._river_atlas_probe_enabled:
		baker._river_atlas_probe_context = context.duplicate(false)


static func dump_river_atlas_probe(baker: MapBaker) -> Dictionary:
	if baker._river_atlas_probe_rows.is_empty():
		return {"ok": false, "code": "probe_empty", "message": "Atlas 河谷采样暂无记录。"}
	var dir_path := "user://diagnostics"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir_path))
	var stamp := Time.get_datetime_string_from_system().replace(":", "").replace("-", "")
	var path := "%s/atlas_river_probe_%s.csv" % [dir_path, stamp]
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return {"ok": false, "code": "probe_open_failed", "message": "无法写入 Atlas 河谷采样文件。"}
	var columns := PackedStringArray([
		"sample_seq", "tick_idx", "sim_day", "cell_index", "q", "r", "has_river",
		"river_flow", "river_discharge", "map_moisture", "cell_moisture",
		"map_vitality", "cell_vitality", "map_drought_stress", "map_heat_stress",
		"dyn_temp_byte", "dyn_moisture_byte", "dyn_snow_byte", "dyn_vitality_byte",
		"eco_foliage_byte", "eco_stress_byte", "eco_transition_byte", "eco_growth_byte",
		"lut_path", "lut_encode_path", "lut_catchup", "lut_dirty_cells",
	])
	file.store_line(",".join(columns))
	for row in baker._river_atlas_probe_rows:
		var values := PackedStringArray()
		for column in columns:
			values.append(baker._csv_escape(str(row.get(column, ""))))
		file.store_line(",".join(values))
	file.close()
	return {"ok": true, "path": path, "rows": baker._river_atlas_probe_rows.size()}


static func _ensure_river_atlas_probe_cells(baker: MapBaker, map: MapData) -> void:
	if not baker._river_atlas_probe_cells.is_empty() or map == null:
		return
	var river_cells := PackedInt32Array()
	var control_cells := PackedInt32Array()
	var scan_count := mini(map.cell_count(), baker.RIVER_ATLAS_PROBE_SCAN_LIMIT)
	for idx in range(scan_count):
		var cell = map.cell_at(idx)
		if cell == null:
			continue
		if bool(cell.has_river) and river_cells.size() < baker.RIVER_ATLAS_PROBE_CELL_LIMIT:
			river_cells.append(idx)
		elif not bool(cell.has_river) and control_cells.size() < baker.RIVER_ATLAS_PROBE_CELL_LIMIT:
			control_cells.append(idx)
	baker._river_atlas_probe_cells.append_array(river_cells)
	baker._river_atlas_probe_cells.append_array(control_cells)


static func _record_river_atlas_probe(baker: MapBaker, map: MapData, out: Dictionary, dyn_data: PackedByteArray,
		eco_data: PackedByteArray) -> void:
	if not baker._river_atlas_probe_enabled or map == null:
		return
	baker._ensure_river_atlas_probe_cells(map)
	var lut_path := str(out.get("path", ""))
	var encode_path := str(out.get("lut_encode_path", ""))
	var dirty_cells := int(out.get("dirty_cells", out.get("dynamic_dirty_cells",
		baker._river_atlas_probe_context.get("dirty_count", -1))))
	for idx in baker._river_atlas_probe_cells:
		if baker._river_atlas_probe_rows.size() >= baker.RIVER_ATLAS_PROBE_SAMPLE_LIMIT:
			break
		var cell = map.cell_at(idx)
		if cell == null or idx < 0:
			continue
		var d4 := idx * 4
		if d4 + 3 >= dyn_data.size() or d4 + 3 >= eco_data.size():
			continue
		var row := {
			"sample_seq": baker._river_atlas_probe_rows.size(),
			"tick_idx": baker._river_atlas_probe_context.get("tick_idx", -1),
			"sim_day": baker._river_atlas_probe_context.get("sim_day", -1),
			"cell_index": idx, "q": int(cell.q), "r": int(cell.r),
			"has_river": 1 if bool(cell.has_river) else 0,
			"river_flow": float(cell.river_flow),
			"river_discharge": baker._probe_float(map.river_discharge_arr, idx),
			"map_moisture": baker._probe_float(map.moisture_arr, idx),
			"cell_moisture": float(cell.moisture),
			"map_vitality": baker._probe_float(map.vegetation_vitality_arr, idx),
			"cell_vitality": float(cell.vegetation_vitality),
			"map_drought_stress": baker._probe_float(map.vegetation_drought_stress_arr, idx),
			"map_heat_stress": baker._probe_float(map.vegetation_heat_stress_arr, idx),
			"dyn_temp_byte": int(dyn_data[d4]), "dyn_moisture_byte": int(dyn_data[d4 + 1]),
			"dyn_snow_byte": int(dyn_data[d4 + 2]), "dyn_vitality_byte": int(dyn_data[d4 + 3]),
			"eco_foliage_byte": int(eco_data[d4]), "eco_stress_byte": int(eco_data[d4 + 1]),
			"eco_transition_byte": int(eco_data[d4 + 2]), "eco_growth_byte": int(eco_data[d4 + 3]),
			"lut_path": lut_path, "lut_encode_path": encode_path,
			"lut_catchup": baker._river_atlas_probe_context.get("catchup", false),
			"lut_dirty_cells": dirty_cells,
		}
		baker._river_atlas_probe_rows.append(row)


static func _probe_float(baker: MapBaker, values: PackedFloat32Array, idx: int) -> float:
	return float(values[idx]) if idx >= 0 and idx < values.size() else NAN
