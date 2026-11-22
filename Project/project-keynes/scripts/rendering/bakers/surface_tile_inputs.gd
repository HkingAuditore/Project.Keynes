extends RefCounted

const TerrainIndexBakerScript = preload("res://scripts/rendering/bakers/terrain_index_baker.gd")

static func _visual_tile_base_knobs(baker: MapBaker, map: MapData, world: WorldData, hex_size: float,
		seed_val: int, visual_generation_id: int) -> Dictionary:
	if map == null or world == null:
		return {}
	var n_cells := map.cell_count()
	var elev := PackedFloat32Array(); elev.resize(n_cells)
	var moist := PackedFloat32Array(); moist.resize(n_cells)
	var terrain := PackedByteArray(); terrain.resize(n_cells)
	var vegetation := PackedByteArray(); vegetation.resize(n_cells)
	var cover := PackedByteArray(); cover.resize(n_cells)
	var water_surface := PackedFloat32Array(); water_surface.resize(n_cells)
	var canal_mask: PackedByteArray = map.canal_edge_mask_arr
	var cell_pos_x: PackedFloat32Array = map.cell_pos_x_arr
	var cell_pos_y: PackedFloat32Array = map.cell_pos_y_arr
	var offset_to_index := PackedInt32Array()
	offset_to_index.resize(map.width * map.height)
	offset_to_index.fill(-1)
	for cell in map.all_cells():
		if cell == null:
			continue
		var ci := int(cell.index)
		if ci < 0 or ci >= n_cells:
			continue
		elev[ci] = cell.elevation
		moist[ci] = cell.moisture
		terrain[ci] = int(cell.terrain) & 0xFF
		vegetation[ci] = int(cell.vegetation) & 0xFF
		cover[ci] = int(cell.cover) & 0xFF
		water_surface[ci] = float(cell.water_depth)
		var off := HexUtils.cube_to_offset(cell.q, cell.r)
		if off.y >= 0 and off.y < map.height:
			offset_to_index[off.y * map.width + posmod(off.x, map.width)] = ci

	var base_knobs := {
		"generation_id": visual_generation_id,
		"map_width": map.width,
		"map_height": map.height,
		"n_cells": n_cells,
		"hex_size": hex_size,
		"seed": seed_val,
		"wrap_period_x": world.wrap_period_x,
		"sea_level": world.sea_level,
		"cell_elevation": elev,
		"cell_moisture": moist,
		"cell_terrain": terrain,
		"cell_vegetation": vegetation,
		"cell_cover": cover,
		"cell_water_depth": water_surface,
		"cell_canal_edge_mask": canal_mask,
		"cell_pos_x": cell_pos_x,
		"cell_pos_y": cell_pos_y,
		"neighbor_indices": map.neighbor_indices_packed(),
		"canal_stroke_hex_factor": 0.045,
		"cell_landform": baker._landform_bytes_for_map(map),
		"offset_to_index": offset_to_index,
		"baseline_width": world.hm_size.x,
		"baseline_height": world.hm_size.y,
		"baseline_origin_x": world.world_bounds.position.x,
		"baseline_origin_y": world.world_bounds.position.y,
		"baseline_size_x": world.world_bounds.size.x,
		"baseline_size_y": world.world_bounds.size.y,
		"baseline_height_buffer": world.height_buffer,
		"baseline_procedural_height_buffer": baker._baseline_procedural_height,
		"baseline_flow_buffer": world.flow_buffer,
		"baseline_water_depth_buffer": world.water_depth_buffer,
		"algorithm_halo_px": 8,
		# [normal-soften 2026-07-31] 默认 0.035→0.01：高频 residual 写进 height 后被运行期
		# 1-texel 细节法线 × slope_gain=8 放大成全图砂砾。滤半径同步放宽，残差更平滑。
		"residual_amp": float(ProjectSettings.get_setting(
			"project_keynes/rendering/map_tiles/residual_amp", 0.01)),
		"residual_filter_hex": float(ProjectSettings.get_setting(
			"project_keynes/rendering/map_tiles/residual_filter_hex", 0.06)),
		"procedural_detail_gain": float(ProjectSettings.get_setting(
			"project_keynes/rendering/map_tiles/procedural_detail_gain", 1.0)),
		"river_stroke_hex_factor": baker.RIVER_STROKE_HEX_FACTOR,
		"sdf_max_dist_px": baker.SDF_MAX_DIST_PX,
		"shore_carve_amp": baker.SHORE_CARVE_AMP,
		"shore_carve_band": baker.SHORE_CARVE_BAND,
		"coast_sdf_max_dist_px": baker.COAST_SDF_MAX_DIST_PX,
		"normal_sample_radius_hex": baker.TERRAIN_NORMAL_SAMPLE_RADIUS_HEX,
		"normal_height_scale_hex": baker.TERRAIN_NORMAL_HEIGHT_SCALE_HEX,
	}
	base_knobs.merge(TerrainIndexBakerScript.dem_landform_knobs())
	return base_knobs
