extends RefCounted

## Runs seasonal native passes and publishes the terrain values they update.


static func _run_season_refresh_stage11_gdext(context, map: MapData, _world: WorldData, _season: int) -> bool:
	# Stage 11 (feedback decay) → C++ stage 10：
	# - 输入：soil_moisture_arr / vegetation_growth_pressure_arr（PackedArray 引用）+
	#   n_cells + decay
	# - 输出：base_moisture 由 C++ 端 _flush_slot_to_map 直接写 SoA；
	#   soil_moisture / veg_growth_pressure 通过 knobs in/out 返回 decayed array，
	#   facade getter 自动从 SoA 拿新值（hex_cell.gd L668-697）。
	# - 数值契约：clamp / decay / FEEDBACK_SOIL_TO_BASE_W=0.15。
	var cp = context._generator._c()
	if cp == null:
		context._generator._season_log_path_once("stage11", "gdscript_fallback", "cp null")
		return false
	if map == null or context._generator._data_core_world_ext == null :
		context._generator._season_log_path_once("stage11", "gdscript_fallback", "ext/method/map unavailable")
		return false
	var n_cells: int = map.cell_count()
	if n_cells <= 0:
		context._generator._season_log_path_once("stage11", "gdscript_fallback", "n_cells<=0")
		return false
	# 取 map.xxx_arr 引用；run_climate_feedback_pass 已经维护这两个 array
	# 与 cell facade 的同步（line 6996-7002）。
	var soil_arr: PackedFloat32Array = map.soil_moisture_arr
	var vg_arr: PackedFloat32Array = map.vegetation_growth_pressure_arr
	if soil_arr.size() != n_cells or vg_arr.size() != n_cells:
		context._generator._season_log_path_once("stage11", "gdscript_fallback", "soil/vg arr size mismatch n_cells=%d soil=%d vg=%d" % [n_cells, soil_arr.size(), vg_arr.size()])
		return false
	# 让 C++ 端 SoA 看到最新 base_moisture（stage_8 之前可能已经写过 cell.base_moisture
	# 而未 flush 回 _slots）。
	context._generator._ensure_season_round_slots_fresh()
	var knobs: Dictionary = {
		"stage": 10,
		"n_cells": n_cells,
		"decay": float(cp.feedback_decay),
		"soil_moisture_arr": soil_arr,
		"veg_growth_pressure_arr": vg_arr,
	}
	var res: Dictionary = context._generator._data_core_world_ext.run_season_refresh_stage(knobs)
	if bool(res.get("fallback", true)) or float(res.get("elapsed_ms", -1.0)) < 0.0:
		context._generator._season_log_path_once("stage11", "gdscript_fallback", "C++ returned fallback: %s" % String(res.get("reason", "unknown")))
		return false
	# 写回 in/out arrays。C++ 端通过 knobs["soil_moisture_arr"] = soil_arr;
	# 把 decayed 值写回；这里把更新后的 PackedArray 灌回 map.xxx_arr，
	# facade getter 即可读到新值（与 _climate_feedback_pass 同模式）。
	var soil_out: PackedFloat32Array = knobs.get("soil_moisture_arr", soil_arr)
	var vg_out: PackedFloat32Array = knobs.get("veg_growth_pressure_arr", vg_arr)
	if soil_out.size() == n_cells:
		map.soil_moisture_arr = soil_out
	if vg_out.size() == n_cells:
		map.vegetation_growth_pressure_arr = vg_out
	context._generator._last_season_refresh_breakdown["stage_11_path"] = "gdext"
	context._generator._last_season_refresh_breakdown["stage_11_native_ms"] = float(res.get("elapsed_ms", 0.0))
	context._generator._last_season_refresh_breakdown["stage_11_touched"] = int(res.get("touched", 0))
	context._generator._season_log_path_once("stage11", "gdext", "native_ms=%.3f touched=%d" % [float(res.get("elapsed_ms", 0.0)), int(res.get("touched", 0))])
	return true

# DOTS-Total-CPP（任务 2）：stage 0（per-cell moisture set）gdext 路径。
# 与 stage 8 helper 同模式：检查 ClimateProfile flag + ext + method，未满足走 fallback。
# C++ 端写 cell_moisture SoA；feature_flags.use_hexcell_facade=true 让 cell.moisture
# 自动看到最新 SoA 值，不需要 facade sync。

static func _build_row_indices_for_gdext(context, map: MapData, cfg: MapConfig) -> PackedInt32Array:
	var n: int = map.cell_count()
	var out: PackedInt32Array = PackedInt32Array()
	if n <= 0 or cfg == null:
		return out
	out.resize(n)
	for i in range(n):
		var cell: HexCell = map.cell_at(i)
		if cell == null:
			out[i] = 0
			continue
		out[i] = context._generator._cube_to_row(cell, cfg)
	return out

static func _set_cell_runtime_terrain(context, map: MapData, cell: HexCell, terrain_id: int,
		sync_axes: bool = false, temperature_for_vegetation: float = -1.0,
		snow_cover: float = -1.0) -> void:
	if cell == null:
		return
	if map != null and map.has_soa():
		var idx: int = int(cell.index)
		if idx < 0 or idx >= map.cell_count():
			idx = map.index_of(cell)
		if idx >= 0 and idx < map.cell_count():
			map.set_runtime_terrain(idx, terrain_id, true)
			context._generator.mark_runtime_terrain_mirror_dirty()
			if sync_axes:
				context._generator._sync_runtime_axes_after_terrain(map, cell, idx, temperature_for_vegetation, snow_cover)
			return
	cell.apply_terrain(terrain_id)
	if sync_axes:
		context._generator._sync_runtime_axes_after_terrain(map, cell, -1, temperature_for_vegetation, snow_cover)

static func _sync_runtime_axes_after_terrain(context, map: MapData, cell: HexCell, idx: int,
		temperature_for_vegetation: float = -1.0, snow_cover: float = -1.0) -> void:
	if cell == null or context._generator._last_cfg == null:
		return
	var cfg: MapConfig = context._generator._last_cfg
	var landform: int = context._generator._derive_landform(cell, cfg)
	# 结构性地貌保留（与 C++ stage 2 / stage 8 sync_current_state 同口径）：生成期通过
	# 多格邻域起伏分析写入的 PEAK/VOLCANO/PLATEAU/RIFT_VALLEY/CANYON 无法由单格 _derive_landform
	# 复现，季节重判/运行期同步必须保留，否则首个 season-refresh round 就会把高原/高峰/裂谷/峡谷
	# 整片塌缩成朴素 MOUNTAIN/HILL。
	if not context._generator._is_water(cell.terrain):
		var prev_lf: int = int(cell.landform)
		if (
			prev_lf == LandformType.LF.PEAK
			or prev_lf == LandformType.LF.VOLCANO
			or prev_lf == LandformType.LF.PLATEAU
			or prev_lf == LandformType.LF.RIFT_VALLEY
			or prev_lf == LandformType.LF.CANYON
		):
			landform = prev_lf
	var temp_for_veg: float = temperature_for_vegetation
	if temp_for_veg < 0.0:
		temp_for_veg = context._generator._compute_temperature(context._generator._cube_row_norm(cell, cfg), cell.elevation)
	var cover_snow: float = snow_cover if snow_cover >= 0.0 else cell.snow_cover
	var vegetation: int = context._generator._derive_vegetation(cell, landform, temp_for_veg)
	var cover: int = context._generator._derive_cover(cell, cover_snow)
	cell.landform = landform
	cell.vegetation = vegetation
	cell.cover = cover
	if cell.current_state != null and not cell.current_state.is_empty():
		cell.current_state["biome"] = int(cell.terrain)
		cell.current_state["landform"] = int(landform)
		cell.current_state["vegetation"] = int(vegetation)
		cell.current_state["cover"] = int(cover)
	if map != null and map.has_soa():
		var safe_idx: int = idx
		if safe_idx < 0 or safe_idx >= map.cell_count():
			safe_idx = int(cell.index)
		if safe_idx < 0 or safe_idx >= map.cell_count():
			safe_idx = map.index_of(cell)
		if safe_idx >= 0 and safe_idx < map.cell_count():
			if safe_idx < map.terrain_arr.size():
				map.terrain_arr[safe_idx] = int(cell.terrain) & 0xFF
				context._generator.mark_runtime_terrain_mirror_dirty()
			if safe_idx < map.is_water_arr.size():
				map.is_water_arr[safe_idx] = MapData.terrain_is_water_u8(int(cell.terrain))
				context._generator.mark_runtime_terrain_mirror_dirty()
			if safe_idx < map.landform_arr.size():
				map.landform_arr[safe_idx] = landform & 0xFF
			if safe_idx < map.vegetation_arr.size():
				map.vegetation_arr[safe_idx] = vegetation & 0xFF
			if safe_idx < map.cover_arr.size():
				map.cover_arr[safe_idx] = cover & 0xFF
			if MapData.terrain_is_water_u8(int(cell.terrain)) != 0 or vegetation == VegetationType.VEG.NONE:
				context._generator._clear_cell_vegetation_state(map, cell, safe_idx)

static func _clear_cell_vegetation_state(context, map: MapData, cell: HexCell, idx: int = -1) -> void:
	if cell == null:
		return
	cell.vegetation_vitality = 0.0
	cell._vitality_low_streak = 0
	cell._vitality_high_streak = 0
	cell.vegetation_growth_pressure = 0.0
	cell.vegetation_heat_stress = 0.0
	cell.vegetation_drought_stress = 0.0
	cell.vegetation_cold_stress = 0.0
	cell.vegetation_regen_score = 0.0
	if map == null or not map.has_soa():
		return
	var safe_idx: int = idx
	if safe_idx < 0 or safe_idx >= map.cell_count():
		safe_idx = int(cell.index)
	if safe_idx < 0 or safe_idx >= map.cell_count():
		safe_idx = map.index_of(cell)
	if safe_idx < 0 or safe_idx >= map.cell_count():
		return
	if safe_idx < map.vegetation_vitality_arr.size():
		map.vegetation_vitality_arr[safe_idx] = 0.0
	if safe_idx < map.vitality_low_streak_arr.size():
		map.vitality_low_streak_arr[safe_idx] = 0
	if safe_idx < map.vitality_high_streak_arr.size():
		map.vitality_high_streak_arr[safe_idx] = 0
	if safe_idx < map.vegetation_growth_pressure_arr.size():
		map.vegetation_growth_pressure_arr[safe_idx] = 0.0
	if safe_idx < map.vegetation_heat_stress_arr.size():
		map.vegetation_heat_stress_arr[safe_idx] = 0.0
	if safe_idx < map.vegetation_drought_stress_arr.size():
		map.vegetation_drought_stress_arr[safe_idx] = 0.0
	if safe_idx < map.vegetation_cold_stress_arr.size():
		map.vegetation_cold_stress_arr[safe_idx] = 0.0
	if safe_idx < map.vegetation_regen_score_arr.size():
		map.vegetation_regen_score_arr[safe_idx] = 0.0

static func _write_runtime_enum_axes_dense(context, map: MapData) -> int:
	if map == null or context._generator._data_core_world == null or not context._generator._data_core_world.has_method("write_u8_dense"):
		return 0
	var written: int = 0
	var cid_terrain: int = context._generator._data_core_world.component_id(DCComponentIds.CELL_TERRAIN)
	if cid_terrain >= 0:
		context._generator._data_core_world.write_u8_dense(cid_terrain, map.terrain_arr)
		written += 1
	var cid_is_water: int = context._generator._data_core_world.component_id(DCComponentIds.CELL_IS_WATER)
	if cid_is_water >= 0:
		context._generator._data_core_world.write_u8_dense(cid_is_water, map.is_water_arr)
		written += 1
	var cid_landform: int = context._generator._data_core_world.component_id(DCComponentIds.CELL_LANDFORM)
	if cid_landform >= 0:
		context._generator._data_core_world.write_u8_dense(cid_landform, map.landform_arr)
		written += 1
	var cid_vegetation: int = context._generator._data_core_world.component_id(DCComponentIds.CELL_VEGETATION)
	if cid_vegetation >= 0:
		context._generator._data_core_world.write_u8_dense(cid_vegetation, map.vegetation_arr)
		written += 1
	var cid_cover: int = context._generator._data_core_world.component_id(DCComponentIds.CELL_COVER)
	if cid_cover >= 0:
		context._generator._data_core_world.write_u8_dense(cid_cover, map.cover_arr)
		written += 1
	return written

static func _world_ext_u8_component_id(context, gd_name: StringName) -> int:
	if context._generator._data_core_world_ext == null:
		return -1
	var cid_ext: int = int(context._generator._data_core_world_ext.component_id(gd_name))
	if cid_ext < 0:
		cid_ext = int(context._generator._data_core_world_ext.component_id(StringName(String(gd_name).replace(".", "_"))))
	return cid_ext

static func _apply_sea_ice_terrain_flips_indexed(context, map: MapData, indices: PackedInt32Array,
		terrain_values: PackedByteArray, sync_cells: bool = true) -> Dictionary:
	var diag: Dictionary = {
		"applied": false,
		"count": 0,
		"fallback_reason": "",
		"dc_written": false,
		"dc_ext_written": false,
	}
	if map == null or not map.has_soa():
		diag["fallback_reason"] = "missing_soa"
		return diag
	var n_values: int = mini(indices.size(), terrain_values.size())
	if n_values <= 0:
		diag["applied"] = true
		return diag
	if map.terrain_arr.size() < map.cell_count() or map.is_water_arr.size() < map.cell_count():
		diag["fallback_reason"] = "bad_map_array_size"
		return diag
	var apply_idx: PackedInt32Array = PackedInt32Array()
	var apply_terrain: PackedByteArray = PackedByteArray()
	var apply_water: PackedByteArray = PackedByteArray()
	apply_idx.resize(n_values)
	apply_terrain.resize(n_values)
	apply_water.resize(n_values)
	var w: int = 0
	for k in range(n_values):
		var idx: int = indices[k]
		if idx < 0 or idx >= map.cell_count():
			continue
		var terrain_byte: int = int(terrain_values[k]) & 0xFF
		var water_byte: int = MapData.terrain_is_water_u8(terrain_byte)
		if int(map.terrain_arr[idx]) == terrain_byte and int(map.is_water_arr[idx]) == water_byte:
			continue
		map.terrain_arr[idx] = terrain_byte
		map.is_water_arr[idx] = water_byte
		if sync_cells:
			var cell: HexCell = map.cell_at(idx)
			if cell != null:
				cell.apply_terrain(terrain_byte)
		if map.has_method("mark_climate_dirty"):
			map.mark_climate_dirty(idx)
		apply_idx[w] = idx
		apply_terrain[w] = terrain_byte
		apply_water[w] = water_byte
		w += 1
	if w <= 0:
		diag["applied"] = true
		return diag
	apply_idx.resize(w)
	apply_terrain.resize(w)
	apply_water.resize(w)
	if context._generator._data_core_world != null and context._generator._data_core_world.has_method("write_u8_indexed"):
		var cid_terrain: int = context._generator._data_core_world.component_id(DCComponentIds.CELL_TERRAIN)
		if cid_terrain >= 0:
			context._generator._data_core_world.write_u8_indexed(cid_terrain, apply_idx, apply_terrain)
			diag["dc_written"] = true
		var cid_is_water: int = context._generator._data_core_world.component_id(DCComponentIds.CELL_IS_WATER)
		if cid_is_water >= 0:
			context._generator._data_core_world.write_u8_indexed(cid_is_water, apply_idx, apply_water)
			diag["dc_written"] = true
	if context._generator._data_core_world != null and context._generator._data_core_world.has_method("mark_dirty_indexed"):
		context._generator._data_core_world.mark_dirty_indexed(apply_idx)
	if context._generator._data_core_world_ext != null:
		var cid_terr_ext: int = context._generator._world_ext_u8_component_id(DCComponentIds.CELL_TERRAIN)
		if cid_terr_ext >= 0:
			context._generator._data_core_world_ext.write_u8_indexed(cid_terr_ext, apply_idx, apply_terrain)
			diag["dc_ext_written"] = true
		var cid_isw_ext: int = context._generator._world_ext_u8_component_id(DCComponentIds.CELL_IS_WATER)
		if cid_isw_ext >= 0:
			context._generator._data_core_world_ext.write_u8_indexed(cid_isw_ext, apply_idx, apply_water)
			diag["dc_ext_written"] = true
	diag["applied"] = true
	diag["count"] = w
	return diag

static func _build_sea_ice_flip_batch(context, flip_to_ice_list: PackedInt32Array,
		flip_to_base_list: PackedInt32Array, flip_to_base_terrain: PackedByteArray,
		start: int = 0, end: int = -1) -> Dictionary:
	var total: int = flip_to_ice_list.size() + flip_to_base_list.size()
	var first: int = clampi(start, 0, total)
	var last: int = total if end < 0 else clampi(end, first, total)
	var out_idx: PackedInt32Array = PackedInt32Array()
	var out_terrain: PackedByteArray = PackedByteArray()
	out_idx.resize(last - first)
	out_terrain.resize(last - first)
	var sea_ice_id: int = int(TerrainType.TERRAIN.SEA_ICE) & 0xFF
	var w: int = 0
	for f in range(first, last):
		if f < flip_to_ice_list.size():
			out_idx[w] = int(flip_to_ice_list[f])
			out_terrain[w] = sea_ice_id
			w += 1
		else:
			var base_i: int = f - flip_to_ice_list.size()
			if base_i < flip_to_base_list.size() and base_i < flip_to_base_terrain.size():
				out_idx[w] = int(flip_to_base_list[base_i])
				out_terrain[w] = int(flip_to_base_terrain[base_i]) & 0xFF
				w += 1
	out_idx.resize(w)
	out_terrain.resize(w)
	return {
		"indices": out_idx,
		"terrain": out_terrain,
	}

# stage 4 用的 donor_table（PackedFloat32Array, size=26, 按 terrain enum 索引）。
# 复刻 _vegetation_donor_amount 的 10 类型 hot 表 + 其余为 0。

static func _build_vegetation_donor_table_for_gdext(context) -> PackedFloat32Array:
	var c = context._generator._c()
	var t: PackedFloat32Array = PackedFloat32Array()
	t.resize(26)
	if c == null:
		return t
	t[int(TerrainType.TERRAIN.FOREST)]    = float(c.veg_forest_donor)
	t[int(TerrainType.TERRAIN.SWAMP)]     = float(c.veg_swamp_donor)
	t[int(TerrainType.TERRAIN.GRASSLAND)] = float(c.veg_grassland_donor)
	t[int(TerrainType.TERRAIN.DESERT)]    = float(c.veg_desert_donor)
	t[int(TerrainType.TERRAIN.JUNGLE)]    = float(c.veg_jungle_donor)
	t[int(TerrainType.TERRAIN.TAIGA)]     = float(c.veg_taiga_donor)
	t[int(TerrainType.TERRAIN.SAVANNA)]   = float(c.veg_savanna_donor)
	t[int(TerrainType.TERRAIN.OASIS)]     = float(c.veg_oasis_donor)
	t[int(TerrainType.TERRAIN.DELTA)]     = float(c.veg_delta_donor)
	t[int(TerrainType.TERRAIN.SALT_FLAT)] = float(c.veg_salt_flat_donor)
	return t

# stage 1 用的 jitter_arr（PackedFloat32Array, size=n_cells）。
# 与 _apply_rain_shadow_per_cell line 3158 完全等价：
#   jitter[i] = _height_warp.get_noise_2d(cell.q*8.0, cell.r*8.0) * 0.04
# 让 C++ 端 stage 1 不需要 noise 引擎即可 bit-equal 复刻 WindBelt fallback 路径。

static func _build_rain_shadow_jitter_for_gdext(context, map: MapData) -> PackedFloat32Array:
	var n: int = map.cell_count()
	var out: PackedFloat32Array = PackedFloat32Array()
	if n <= 0 or context._generator._height_warp == null:
		return out
	out.resize(n)
	for i in range(n):
		var cell: HexCell = map.cell_at(i)
		if cell == null:
			out[i] = 0.0
			continue
		out[i] = context._generator._height_warp.get_noise_2d(float(cell.q) * 8.0, float(cell.r) * 8.0) * 0.04
	return out

# stage 1: rain_shadow_per_cell。
# C++ 等价：cell.wind_vector 优先 + WindBelt fallback（用预烘焙 jitter）+ 6 邻接 lookback。

static func _run_season_refresh_stage1_gdext(context, map: MapData, _world: WorldData, season: int) -> bool:
	var cp = context._generator._c()
	if cp == null:
		context._generator._season_log_path_once("stage1", "gdscript_fallback", "cp null")
		return false
	if context._generator._last_cfg == null or map == null or context._generator._data_core_world_ext == null :
		context._generator._season_log_path_once("stage1", "gdscript_fallback", "ext/method/map/cfg unavailable")
		return false
	if not map.has_indices():
		context._generator._season_log_path_once("stage1", "gdscript_fallback", "map.has_indices()=false (CSR not baked)")
		return false
	var n_cells: int = map.cell_count()
	if n_cells <= 0:
		context._generator._season_log_path_once("stage1", "gdscript_fallback", "n_cells<=0")
		return false
	context._generator._ensure_season_round_slots_fresh()
	var jitter_arr: PackedFloat32Array = context._generator._build_rain_shadow_jitter_for_gdext(map)
	if jitter_arr.size() != n_cells:
		context._generator._season_log_path_once("stage1", "gdscript_fallback", "jitter_arr size mismatch n_cells=%d jitter=%d" % [n_cells, jitter_arr.size()])
		return false
	var knobs: Dictionary = {
		"stage": 1,
		"n_cells": n_cells,
		"rain_shadow_lookback": int(cp.rain_shadow_lookback),
		"rain_shadow_threshold": float(cp.rain_shadow_threshold),
		"rain_shadow_factor": float(cp.rain_shadow_factor),
		"neighbor_indices": map.neighbor_indices_packed(),
		"season_phase": float(season) + 0.5,
		"jitter_arr": jitter_arr,
	}
	var res: Dictionary = context._generator._data_core_world_ext.run_season_refresh_stage(knobs)
	if bool(res.get("fallback", true)) or float(res.get("elapsed_ms", -1.0)) < 0.0:
		context._generator._season_log_path_once("stage1", "gdscript_fallback", "C++ returned fallback: %s" % String(res.get("reason", "unknown")))
		return false
	# moisture 是单轴写入，hexcell_facade=true 自动透出，不需 facade sync。
	context._generator._last_season_refresh_breakdown["stage_1_path"] = "gdext"
	context._generator._last_season_refresh_breakdown["stage_1_native_ms"] = float(res.get("elapsed_ms", 0.0))
	context._generator._season_log_path_once("stage1", "gdext", "native_ms=%.3f" % float(res.get("elapsed_ms", 0.0)))
	return true

# stage 2: seasonal_redecide_terrain。多轴写入（terrain + landform + vegetation + cover），
# 必须在结束后 _sync_stage8_facade_fields_from_soa 同步 facade。

static func _run_season_refresh_stage2_gdext(context, map: MapData, _world: WorldData, season: int) -> bool:
	var cp = context._generator._c()
	if cp == null:
		context._generator._season_log_path_once("stage2", "gdscript_fallback", "cp null")
		return false
	if context._generator._last_cfg == null or map == null or context._generator._data_core_world_ext == null :
		context._generator._season_log_path_once("stage2", "gdscript_fallback", "ext/method/map/cfg unavailable")
		return false
	var n_cells: int = map.cell_count()
	if n_cells <= 0:
		context._generator._season_log_path_once("stage2", "gdscript_fallback", "n_cells<=0")
		return false
	if not map.has_lat_lut():
		map.bake_lat_temp_year_lut(context._generator)
	context._generator._ensure_row_tables(context._generator._last_cfg, season)
	if context._generator._row_lat_temp.size() < context._generator._last_cfg.height or context._generator._row_season_off.size() < context._generator._last_cfg.height:
		context._generator._season_log_path_once("stage2", "gdscript_fallback", "row tables not ready: lat_temp=%d season_off=%d height=%d" % [context._generator._row_lat_temp.size(), context._generator._row_season_off.size(), int(context._generator._last_cfg.height)])
		return false
	context._generator._ensure_season_round_slots_fresh()
	var row_idx: PackedInt32Array = context._generator._build_row_indices_for_gdext(map, context._generator._last_cfg)
	if row_idx.size() != n_cells:
		context._generator._season_log_path_once("stage2", "gdscript_fallback", "row_idx size mismatch n_cells=%d row_idx=%d" % [n_cells, row_idx.size()])
		return false
	var knobs: Dictionary = {
		"stage": 2,
		"season": season,
		"n_cells": n_cells,
		"height": int(context._generator._last_cfg.height),
		"sea_level": float(context._generator._last_cfg.sea_level),
		"lat_temp_rows": context._generator._row_lat_temp,
		"season_offset_rows": context._generator._row_season_off,
		"row_indices": row_idx,
		"biome_water_balance_weight": float(cp.plant_water_balance_weight),
		"biome_drought_penalty": float(cp.plant_drought_penalty),
	}
	var res: Dictionary = context._generator._data_core_world_ext.run_season_refresh_stage(knobs)
	if bool(res.get("fallback", true)) or float(res.get("elapsed_ms", -1.0)) < 0.0:
		context._generator._season_log_path_once("stage2", "gdscript_fallback", "C++ returned fallback: %s" % String(res.get("reason", "unknown")))
		return false
	context._generator._sync_stage8_facade_fields_from_soa(map)
	context._generator._last_season_refresh_breakdown["stage_2_path"] = "gdext"
	context._generator._last_season_refresh_breakdown["stage_2_native_ms"] = float(res.get("elapsed_ms", 0.0))
	context._generator._season_log_path_once("stage2", "gdext", "native_ms=%.3f" % float(res.get("elapsed_ms", 0.0)))
	return true

# stage 3: river_ecology。河岸保湿；荒漠河道修成 FLOODPLAIN/OASIS/STEPPE；低地河道优先 FLOODPLAIN。
# 多轴写入需 facade sync。

static func _run_season_refresh_stage3_gdext(context, map: MapData, _world: WorldData, _season: int) -> bool:
	var cp = context._generator._c()
	if cp == null:
		context._generator._season_log_path_once("stage3", "gdscript_fallback", "cp null")
		return false
	if context._generator._last_cfg == null or map == null or context._generator._data_core_world_ext == null :
		context._generator._season_log_path_once("stage3", "gdscript_fallback", "ext/method/map/cfg unavailable")
		return false
	var n_cells: int = map.cell_count()
	if n_cells <= 0:
		context._generator._season_log_path_once("stage3", "gdscript_fallback", "n_cells<=0")
		return false
	context._generator._ensure_season_round_slots_fresh()
	var row_idx: PackedInt32Array = context._generator._build_row_indices_for_gdext(map, context._generator._last_cfg)
	if row_idx.size() != n_cells:
		context._generator._season_log_path_once("stage3", "gdscript_fallback", "row_idx size mismatch n_cells=%d row_idx=%d" % [n_cells, row_idx.size()])
		return false
	var knobs: Dictionary = {
		"stage": 3,
		"n_cells": n_cells,
		"height": int(context._generator._last_cfg.height),
		"sea_level": float(context._generator._last_cfg.sea_level),
		"row_indices": row_idx,
	}
	var res: Dictionary = context._generator._data_core_world_ext.run_season_refresh_stage(knobs)
	if bool(res.get("fallback", true)) or float(res.get("elapsed_ms", -1.0)) < 0.0:
		context._generator._season_log_path_once("stage3", "gdscript_fallback", "C++ returned fallback: %s" % String(res.get("reason", "unknown")))
		return false
	context._generator._sync_stage8_facade_fields_from_soa(map)
	context._generator._last_season_refresh_breakdown["stage_3_path"] = "gdext"
	context._generator._last_season_refresh_breakdown["stage_3_native_ms"] = float(res.get("elapsed_ms", 0.0))
	context._generator._season_log_path_once("stage3", "gdext", "native_ms=%.3f" % float(res.get("elapsed_ms", 0.0)))
	return true

# stage 4: vegetation_feedback。3-pass（donor delta 累加 / 应用 / 二次 redecide）。
# 多轴写入 + moisture 写入；需 facade sync。

static func _run_season_refresh_stage4_gdext(context, map: MapData, _world: WorldData, season: int) -> bool:
	var cp = context._generator._c()
	if cp == null:
		context._generator._season_log_path_once("stage4", "gdscript_fallback", "cp null")
		return false
	if context._generator._last_cfg == null or map == null or context._generator._data_core_world_ext == null :
		context._generator._season_log_path_once("stage4", "gdscript_fallback", "ext/method/map/cfg unavailable")
		return false
	if not map.has_indices():
		context._generator._season_log_path_once("stage4", "gdscript_fallback", "map.has_indices()=false (CSR not baked)")
		return false
	var n_cells: int = map.cell_count()
	if n_cells <= 0:
		context._generator._season_log_path_once("stage4", "gdscript_fallback", "n_cells<=0")
		return false
	if not map.has_lat_lut():
		map.bake_lat_temp_year_lut(context._generator)
	context._generator._ensure_row_tables(context._generator._last_cfg, season)
	if context._generator._row_lat_temp.size() < context._generator._last_cfg.height:
		context._generator._season_log_path_once("stage4", "gdscript_fallback", "row_lat_temp not ready: size=%d height=%d" % [context._generator._row_lat_temp.size(), int(context._generator._last_cfg.height)])
		return false
	context._generator._ensure_season_round_slots_fresh()
	var row_idx: PackedInt32Array = context._generator._build_row_indices_for_gdext(map, context._generator._last_cfg)
	if row_idx.size() != n_cells:
		context._generator._season_log_path_once("stage4", "gdscript_fallback", "row_idx size mismatch n_cells=%d row_idx=%d" % [n_cells, row_idx.size()])
		return false
	var donor_table: PackedFloat32Array = context._generator._build_vegetation_donor_table_for_gdext()
	var knobs: Dictionary = {
		"stage": 4,
		"n_cells": n_cells,
		"height": int(context._generator._last_cfg.height),
		"sea_level": float(context._generator._last_cfg.sea_level),
		"lat_temp_rows": context._generator._row_lat_temp,
		"row_indices": row_idx,
		"biome_water_balance_weight": float(cp.plant_water_balance_weight),
		"biome_drought_penalty": float(cp.plant_drought_penalty),
		"neighbor_indices": map.neighbor_indices_packed(),
		"donor_table": donor_table,
		"elev_decay": float(cp.veg_feedback_elev_decay),
	}
	var res: Dictionary = context._generator._data_core_world_ext.run_season_refresh_stage(knobs)
	if bool(res.get("fallback", true)) or float(res.get("elapsed_ms", -1.0)) < 0.0:
		context._generator._season_log_path_once("stage4", "gdscript_fallback", "C++ returned fallback: %s" % String(res.get("reason", "unknown")))
		return false
	context._generator._sync_stage8_facade_fields_from_soa(map)
	context._generator._last_season_refresh_breakdown["stage_4_path"] = "gdext"
	context._generator._last_season_refresh_breakdown["stage_4_native_ms"] = float(res.get("elapsed_ms", 0.0))
	context._generator._season_log_path_once("stage4", "gdext", "native_ms=%.3f" % float(res.get("elapsed_ms", 0.0)))
	return true
