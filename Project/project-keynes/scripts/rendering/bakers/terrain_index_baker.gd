extends RefCounted
class_name DCTerrainIndexBaker

const AtlasEncodersScript = preload("res://scripts/rendering/bakers/atlas_encoders.gd")

## Native terrain-index bridge.
##
## This module owns only request packing and result unpacking for the native
## terrain-index pass. C++ remains the computation authority; MapBaker keeps
## lifecycle ordering and all non-terrain texture/object ownership.


static func native_active(world_ext: Object) -> bool:
	return world_ext != null and world_ext.has_method(&"run_bake_terrain_index_pass")


static func build_cell_inputs(map: MapData) -> Dictionary:
	var n_cells: int = map.cell_count() if map != null else 0
	var elev_arr := PackedFloat32Array()
	elev_arr.resize(maxi(n_cells, 0))
	var moist_arr := PackedFloat32Array()
	moist_arr.resize(maxi(n_cells, 0))
	var terr_arr := PackedByteArray()
	terr_arr.resize(maxi(n_cells, 0))
	var veg_arr := PackedByteArray()
	veg_arr.resize(maxi(n_cells, 0))
	var cov_arr := PackedByteArray()
	cov_arr.resize(maxi(n_cells, 0))
	var water_depth_arr := PackedFloat32Array()
	water_depth_arr.resize(maxi(n_cells, 0))
	var o2i := PackedInt32Array()
	if map != null:
		o2i.resize(maxi(map.width * map.height, 0))
		o2i.fill(-1)
	var cells_by_index: Array = []
	cells_by_index.resize(maxi(n_cells, 0))
	if map != null:
		for cell in map.all_cells():
			if cell == null:
				continue
			var ci: int = int(cell.index)
			if ci < 0 or ci >= n_cells:
				continue
			elev_arr[ci] = cell.elevation
			moist_arr[ci] = cell.moisture
			terr_arr[ci] = int(cell.terrain) & 0xFF
			veg_arr[ci] = int(cell.vegetation) & 0xFF
			cov_arr[ci] = int(cell.cover) & 0xFF
			water_depth_arr[ci] = float(cell.water_depth)
			cells_by_index[ci] = cell
			var off: Vector2i = HexUtils.cube_to_offset(cell.q, cell.r)
			if off.y >= 0 and off.y < map.height and not o2i.is_empty():
				o2i[off.y * map.width + posmod(off.x, map.width)] = ci
	return {
		"n_cells": n_cells,
		"cell_elevation": elev_arr,
		"cell_moisture": moist_arr,
		"cell_terrain": terr_arr,
		"cell_vegetation": veg_arr,
		"cell_cover": cov_arr,
		"cell_water_depth": water_depth_arr,
		"offset_to_index": o2i,
		"cells_by_index": cells_by_index,
	}


static func build_knobs(map: MapData, world: WorldData, hex_size: float,
		seed_value: int = -1) -> Dictionary:
	var inputs := build_cell_inputs(map)
	var seed := world.bake_seed if seed_value < 0 else seed_value
	var knobs := {
		"width": world.hm_size.x,
		"height": world.hm_size.y,
		"map_width": map.width,
		"map_height": map.height,
		"n_cells": inputs["n_cells"],
		"origin_x": world.world_bounds.position.x,
		"origin_y": world.world_bounds.position.y,
		"size_x": world.world_bounds.size.x,
		"size_y": world.world_bounds.size.y,
		"hex_size": hex_size,
		"wrap_period_x": HexUtils.wrap_period_x(map.width, hex_size),
		"seed": seed,
		"sea_level": world.sea_level,
		"cell_elevation": inputs["cell_elevation"],
		"cell_moisture": inputs["cell_moisture"],
		"cell_terrain": inputs["cell_terrain"],
		"cell_vegetation": inputs["cell_vegetation"],
		"cell_cover": inputs["cell_cover"],
		"cell_water_depth": inputs["cell_water_depth"],
		"offset_to_index": inputs["offset_to_index"],
	}
	return {"knobs": knobs, "inputs": inputs}


static func bake(map: MapData, world: WorldData, hex_size: float,
		world_ext: Object) -> bool:
	if map == null or world == null or not native_active(world_ext):
		return false
	var prepared := build_knobs(map, world, hex_size)
	var rep: Dictionary = world_ext.run_bake_terrain_index_pass(prepared.knobs)
	return apply_result(map, world, world_ext, rep, prepared.inputs)


static func apply_result(map: MapData, world: WorldData, world_ext: Object,
		report: Dictionary, inputs: Dictionary) -> bool:
	if map == null or world == null or report == null \
			or bool(report.get("fallback", true)):
		return false
	var pix_count: int = world.hm_size.x * world.hm_size.y
	if pix_count <= 0:
		return false
	var hbuf: PackedFloat32Array = report.get("height_buffer", PackedFloat32Array())
	var bbuf: PackedByteArray = report.get("biome_buffer", PackedByteArray())
	var mbuf: PackedFloat32Array = report.get("moisture_buffer", PackedFloat32Array())
	var vbuf: PackedByteArray = report.get("vegetation_buffer", PackedByteArray())
	var cbuf: PackedByteArray = report.get("cover_buffer", PackedByteArray())
	if hbuf.size() != pix_count or bbuf.size() != pix_count \
			or mbuf.size() != pix_count or vbuf.size() != pix_count \
			or cbuf.size() != pix_count:
		return false
	world.height_buffer = hbuf
	world.biome_buffer = bbuf
	world.moisture_buffer = mbuf
	world.vegetation_buffer = vbuf
	world.cover_buffer = cbuf
	_upload_edge_textures(world, world_ext, report, pix_count)
	_apply_csr(world, map, report, inputs)
	return true


static func _upload_edge_textures(world: WorldData, world_ext: Object,
		report: Dictionary, pix_count: int) -> void:
	var secondary: PackedByteArray = report.get(
		"edge_secondary_index_buffer", PackedByteArray())
	var distance: PackedByteArray = report.get(
		"edge_distance_buffer", PackedByteArray())
	if secondary.size() != pix_count * 2 or distance.size() != pix_count:
		world.terrain_edge_neighbor_tex = null
		world.terrain_edge_distance_tex = null
		push_warning("[terrain_edge] native boundary buffers missing/invalid; using hard cell edges.")
		return
	world.terrain_edge_neighbor_tex = AtlasEncodersScript.encode_rg8_tex(
		secondary, world.derived_size, world.terrain_edge_neighbor_tex)
	world.terrain_edge_distance_tex = AtlasEncodersScript.encode_r8_tex(
		distance, world.derived_size, world.terrain_edge_distance_tex, world_ext)


static func _apply_csr(world: WorldData, map: MapData, report: Dictionary,
		inputs: Dictionary) -> void:
	var first_px: PackedInt32Array = report.get("cell_first_px", PackedInt32Array())
	var pcount: PackedInt32Array = report.get("cell_px_count", PackedInt32Array())
	var flat: PackedInt32Array = report.get("flat_px_indices", PackedInt32Array())
	world.cell_first_px_arr = first_px
	world.cell_px_count_arr = pcount
	world.flat_px_indices_arr = flat
	var pix_count: int = world.hm_size.x * world.hm_size.y
	var n_cells: int = int(inputs.get("n_cells", map.cell_count()))
	var cells_by_index: Array = inputs.get("cells_by_index", [])
	var p2c: PackedInt32Array = report.get("pixel_to_cell_index", PackedInt32Array())
	var lookup: Array = []
	lookup.resize(pix_count)
	if p2c.size() == pix_count:
		for i in range(pix_count):
			var ci: int = p2c[i]
			lookup[i] = cells_by_index[ci] if ci >= 0 and ci < cells_by_index.size() else null
	world.pixel_to_cell_lookup = lookup
	var lists: Dictionary = {}
	if first_px.size() >= n_cells and pcount.size() >= n_cells:
		var flat_n: int = flat.size()
		for ci in range(n_cells):
			var count: int = pcount[ci]
			if count <= 0:
				continue
			var start: int = first_px[ci]
			if start < 0 or start + count > flat_n:
				continue
			var cell: HexCell = cells_by_index[ci] if ci < cells_by_index.size() else null
			if cell == null:
				continue
			lists[cell] = flat.slice(start, start + count)
	world.cell_pixel_lists = lists
