class_name BuildingVisualLayer
extends Node2D

const FamilyTableScript = preload("res://scripts/rendering/building_visual_family_table.gd")
const CHUNK_SIZE := 16
const ARCHETYPE_COUNT := 6
const MAX_RESIDENT_DESKTOP := 128
const MAX_RESIDENT_WEB := 48
const BODY_CAP := [6000, 18000, 36000]
const RIVER_CLEAR_THRESHOLD := 0.42
const SHADOW_STRENGTH := [0.0, 0.55, 0.62]
const ARCHETYPE_NAMES := [
	"agriculture", "extractive", "manufacturing",
	"energy", "knowledge", "service",
]
# Mirrors the Family enum in gdext/src/world_ext_building_visual.cpp and the
# entry order of data/rendering/building_visual_families.tres.
const FAMILY_NAMES := [
	"field", "paddy", "plantation", "pasture", "forage", "fishery",
	"mine", "quarry", "forestry", "saltworks", "wells",
	"workshop", "food", "textile", "kiln", "metallurgy", "chemical",
	"machinery", "electronics", "energy", "knowledge", "service",
]
const FALLBACK_FAMILY_BY_ARCHETYPE := [0, 6, 11, 19, 20, 21]

const LOD_FRACTION_FAR := 0.28
const LOD_FRACTION_MID := 0.62
const UPLOADS_PER_FRAME := 4
const UPLOAD_BUDGET_USEC := 1500

# Settlement layout (lots, streets, plaza, era-specific building volumes) is
# planned per cell by NativeBuildingVisualCache on its own worker thread. Only
# cells whose last-seen row changed are submitted; the main thread uploads
# finished chunks as a concatenation of cached cells. Each body instance is one
# building volume and each decal instance one ground feature; the shared ABI is
# documented in shaders/include/building_form.gdshaderinc. There is no
# GDScript baker: a missing extension disables geometry and keeps the macro.

var _map: MapData
var _world: WorldData
var _intel: BuildingVisualIntelCache
var _hex_size := 22.0
var _visual_quality := 1
var _camera_zoom := 1.0
var _camera_rect := Rect2()
var _camera_center := Vector2.ZERO
var _season_phase := 1.0
var _day_phase := 0.25
var _axial_tilt_rad := 0.4101523
var _day_night_enabled := true
var _tod_debug_sun_position_enabled := false
var _tod_debug_sun_uv := Vector2(0.25, 0.5)
var _tod_debug_sun_height_scale := 1.0
var _tod_sun_dir := Vector3(0.4, -0.7, 0.6).normalized()
var _tod_exposure := 1.0
var _catalog_ready := false
var _type_to_archetype := PackedByteArray()
var _type_to_family := PackedByteArray()
var _type_to_scale := PackedByteArray()
var _type_to_grade := PackedByteArray()
var _visual_cache: Object
var _chunk_nodes := {}
var _chunk_instance_counts := {}
var _upload_queue: Array[int] = []
var _upload_set := {}
var _lod_fraction := 1.0
var _quad_mesh: ArrayMesh
var _shadow_hull_mesh: ArrayMesh
var _body_material: ShaderMaterial
var _shadow_material: ShaderMaterial
var _decal_material: ShaderMaterial
var _macro_material: ShaderMaterial
var _macro_quad: MeshInstance2D
var _macro_image: Image
var _macro_texture: ImageTexture
var _macro_index_high_texture: ImageTexture
var _macro_upload_pending := false
var _last_macro_upload_msec := 0
var _native_path_warning_emitted := false
var _diagnostics := {
	"catalog_types": 0, "catalog_unresolved": 0, "resident_chunks": 0,
	"body_instances": 0, "macro_uploads": 0, "chunk_uploads": 0,
	"queued_chunks": 0, "submitted_cells": 0,
	"last_submit_ms": 0.0, "max_submit_ms": 0.0,
	"last_upload_frame_ms": 0.0, "max_upload_frame_ms": 0.0,
	"last_chunk_upload_ms": 0.0, "max_chunk_upload_ms": 0.0,
	"main_thread_frame_gate_ms": 1.5, "native_failures": 0,
	"process_ticks": 0, "last_chunk_instance_count": 0,
	"last_chunk_decal_count": 0, "last_chunk_lot_count": 0,
	"last_native_reason": "", "last_chunk": -1,
	"native_required": true, "family_sources": {},
}


func _ready() -> void:
	# Use the same absolute 2D world-space contract as vegetation/detail layers.
	# The renderer itself is top-level in both player_game.tscn and main.tscn;
	# making this pass absolute avoids scene-parent z inheritance hiding buildings
	# behind the terrain on one of the two entry paths.
	top_level = true
	z_as_relative = false
	z_index = 3
	_quad_mesh = _make_quad_mesh()
	_shadow_hull_mesh = _make_shadow_hull_mesh()
	_body_material = _shader_material("res://shaders/building_compound.gdshader")
	_shadow_material = _shader_material("res://shaders/building_shadow.gdshader")
	_decal_material = _shader_material("res://shaders/building_ground_decal.gdshader")
	_macro_material = _shader_material("res://shaders/building_macro.gdshader")
	_macro_quad = MeshInstance2D.new()
	_macro_quad.name = "BuildingMacro"
	_macro_quad.z_as_relative = false
	_macro_quad.z_index = 1
	_macro_quad.material = _macro_material
	add_child(_macro_quad)
	set_process(true)
	_rebind_world_textures()


func configure(map: MapData, world: WorldData, hex_size: float,
		catalog: Dictionary, intel: BuildingVisualIntelCache) -> Dictionary:
	_map = map
	_world = world
	_hex_size = maxf(4.0, hex_size)
	_intel = intel
	_native_path_warning_emitted = false
	_clear_chunks()
	var audit := configure_catalog(catalog)
	_configure_macro()
	_rebind_world_textures()
	_configure_cache()
	if _intel != null:
		update_intel(_intel, _intel.known_cells())
	return audit


func native_cache_available() -> bool:
	return _visual_cache != null


func _configure_cache() -> void:
	if _visual_cache != null:
		_visual_cache.shutdown()
	_visual_cache = null
	if _map == null or not _catalog_ready:
		return
	if not ClassDB.class_exists("NativeBuildingVisualCache"):
		_diagnostics.native_failures = int(_diagnostics.native_failures) + 1
		_report_native_unavailable("native_class_missing")
		return
	var cache: Object = ClassDB.instantiate("NativeBuildingVisualCache")
	var config := {
		"cell_count": _map.cell_count(), "map_width": _map.width,
		"chunk_size": CHUNK_SIZE, "hex_size": _hex_size,
		"cell_pos_x": _map.cell_pos_x_arr, "cell_pos_y": _map.cell_pos_y_arr,
		"type_to_archetype": _type_to_archetype,
		"type_to_family": _type_to_family,
		"type_to_scale": _type_to_scale,
		"type_to_grade": _type_to_grade,
		"quality": _visual_quality, "layout_seed": 0,
		"river_clear_threshold": RIVER_CLEAR_THRESHOLD,
	}
	if _world != null and not _world.flow_buffer.is_empty():
		config["flow_buffer"] = _world.flow_buffer
		config["flow_w"] = _world.derived_size.x
		config["flow_h"] = _world.derived_size.y
		config["flow_origin_x"] = _world.world_bounds.position.x
		config["flow_origin_y"] = _world.world_bounds.position.y
		config["flow_size_x"] = _world.world_bounds.size.x
		config["flow_size_y"] = _world.world_bounds.size.y
		config["flow_wrap_period_x"] = _world.wrap_period_x
	var result: Dictionary = cache.configure(config)
	if not bool(result.get("ok", false)):
		_diagnostics.native_failures = int(_diagnostics.native_failures) + 1
		_report_native_unavailable("native_configure_failed:%s"
			% String(result.get("reason", "")))
		return
	_visual_cache = cache


## Derives, per authored type, the visual family (what its lot looks like), the
## archetype (which settlement ring it sits in), its scale (footprint grows
## with the square root of its workforce) and its build grade (the newest
## construction material it needs, which caps how modern its lot may look).
func configure_catalog(catalog: Dictionary) -> Dictionary:
	var ids := PackedStringArray(catalog.get("building_type_ids", PackedStringArray()))
	var kinds := PackedInt32Array(catalog.get("building_kinds", PackedInt32Array()))
	var sectors := PackedInt32Array(catalog.get(
		"building_economic_sectors", PackedInt32Array()))
	var offsets := PackedInt32Array(catalog.get(
		"building_semantic_tag_offsets", PackedInt32Array()))
	var tags := PackedStringArray(catalog.get(
		"building_semantic_tags", PackedStringArray()))
	var table: FamilyTableScript = FamilyTableScript.load_default()
	_type_to_archetype.resize(ids.size())
	_type_to_family.resize(ids.size())
	_type_to_scale.resize(ids.size())
	_type_to_grade.resize(ids.size())
	var unresolved := PackedStringArray()
	if kinds.size() != ids.size() or sectors.size() != ids.size() \
			or offsets.size() != ids.size() + 1 or offsets.is_empty() \
			or offsets[0] != 0 or offsets[-1] != tags.size():
		_catalog_ready = false
		return {"ok": false, "reason": "building_visual_catalog_shape_invalid"}
	if table == null or table.family_ids() != PackedStringArray(FAMILY_NAMES):
		_catalog_ready = false
		return {"ok": false, "reason": "building_visual_family_table_invalid"}
	var climate_idx := PackedInt32Array(catalog.get(
		"building_production_climate_profile_indices", PackedInt32Array()))
	var climate_ids := PackedStringArray(catalog.get(
		"production_climate_profile_ids", PackedStringArray()))
	var resource_offsets := PackedInt32Array(catalog.get(
		"building_resource_offsets", PackedInt32Array()))
	var resource_refs := PackedInt32Array(catalog.get(
		"building_production_resource_ids", PackedInt32Array()))
	var resource_names := PackedStringArray(catalog.get(
		"building_resource_ids", PackedStringArray()))
	var chains := PackedStringArray(catalog.get(
		"building_industry_chain_ids", PackedStringArray()))
	var output_offsets := PackedInt32Array(catalog.get(
		"building_output_offsets", PackedInt32Array()))
	var output_goods := PackedInt32Array(catalog.get(
		"building_output_good_ids", PackedInt32Array()))
	var good_names := PackedStringArray(catalog.get("good_ids", PackedStringArray()))
	var owner_slots := PackedInt64Array(catalog.get("building_owner_slots", PackedInt64Array()))
	var employee_offsets := PackedInt32Array(catalog.get(
		"building_employee_offsets", PackedInt32Array()))
	var employee_slots := PackedInt64Array(catalog.get(
		"building_employee_slots", PackedInt64Array()))
	var construction_offsets := PackedInt32Array(catalog.get(
		"building_construction_offsets", PackedInt32Array()))
	var construction_goods := PackedInt32Array(catalog.get(
		"building_construction_good_ids", PackedInt32Array()))
	var sector_names := ["agriculture", "extractive", "manufacturing", "energy", "knowledge"]
	var sources := {}
	var family_counts := PackedInt32Array()
	family_counts.resize(FAMILY_NAMES.size())
	family_counts.fill(0)
	for i in ids.size():
		var type_tags := tags.slice(offsets[i], offsets[i + 1])
		var climate := ""
		if i < climate_idx.size() and climate_idx[i] >= 0 and climate_idx[i] < climate_ids.size():
			climate = climate_ids[climate_idx[i]]
		var resources := PackedStringArray()
		if resource_offsets.size() == ids.size() + 1:
			for edge in range(resource_offsets[i], resource_offsets[i + 1]):
				var ref := resource_refs[edge] if edge < resource_refs.size() else -1
				if ref >= 0 and ref < resource_names.size():
					resources.append(resource_names[ref])
		var outputs := _csr_names(output_offsets, output_goods, good_names, i, ids.size())
		var sector: String = sector_names[sectors[i]] \
			if sectors[i] >= 0 and sectors[i] < sector_names.size() else ""
		var resolved := table.resolve(ids[i], sector, kinds[i], type_tags, climate,
			resources, chains[i] if i < chains.size() else "", outputs)
		var family := int(resolved.family)
		var source := String(resolved.source)
		if family < 0:
			# Unmatched types fall back to their sector's generic family.
			family = FALLBACK_FAMILY_BY_ARCHETYPE[5 if kinds[i] == 2 else clampi(sectors[i], 0, 4)]
			source = "fallback"
		sources[source] = int(sources.get(source, 0)) + 1
		family_counts[family] += 1
		_type_to_family[i] = family
		_type_to_archetype[i] = table.archetype_of(family)
		var slots := int(owner_slots[i]) if i < owner_slots.size() else 1
		if employee_offsets.size() == ids.size() + 1:
			for edge in range(employee_offsets[i], employee_offsets[i + 1]):
				slots += int(employee_slots[edge]) if edge < employee_slots.size() else 0
		_type_to_scale[i] = clampi(roundi(8.0 * sqrt(float(maxi(1, slots)))), 8, 255)
		_type_to_grade[i] = table.grade_for(_csr_names(
			construction_offsets, construction_goods, good_names, i, ids.size())) \
			if construction_offsets.size() == ids.size() + 1 else 255
		if _type_to_archetype[i] < 0 or _type_to_archetype[i] >= ARCHETYPE_COUNT:
			unresolved.append(ids[i])
	_catalog_ready = unresolved.is_empty()
	_diagnostics.catalog_types = ids.size()
	_diagnostics.catalog_unresolved = unresolved.size()
	_diagnostics.family_sources = sources
	return {"ok": _catalog_ready,
		"reason": "" if _catalog_ready else "building_visual_catalog_unresolved",
		"type_count": ids.size(), "unresolved_ids": unresolved,
		"family_sources": sources, "family_counts": family_counts}


static func _csr_names(offsets: PackedInt32Array, refs: PackedInt32Array,
		names: PackedStringArray, row: int, rows: int) -> PackedStringArray:
	var out := PackedStringArray()
	if offsets.size() != rows + 1:
		return out
	for edge in range(offsets[row], offsets[row + 1]):
		var ref := refs[edge] if edge < refs.size() else -1
		if ref >= 0 and ref < names.size():
			out.append(names[ref])
	return out


func update_intel(intel: BuildingVisualIntelCache,
		changed_cells: PackedInt32Array) -> void:
	_intel = intel
	if _map == null or _world == null or not _catalog_ready:
		return
	var begin_usec := Time.get_ticks_usec()
	var cells := PackedInt32Array()
	var eras := PackedInt32Array()
	var water := PackedByteArray()
	var offsets := PackedInt32Array([0])
	var types := PackedInt32Array()
	var counts := PackedInt64Array()
	var tiers := PackedByteArray()
	var living := PackedByteArray()
	var rich := PackedByteArray()
	var poor := PackedByteArray()
	for cell in changed_cells:
		if cell < 0 or cell >= _map.cell_count():
			continue
		var row := _intel.row_for_cell(cell) if _intel != null else {}
		_update_macro_cell(cell, row)
		cells.append(cell)
		eras.append(clampi(int(row.get("observed_era_index", -1)), 0, 10))
		water.append(1 if _is_water_cell(cell) else 0)
		var row_types := PackedInt32Array(row.get("type_indices", PackedInt32Array()))
		var row_counts := PackedInt64Array(row.get("counts", PackedInt64Array()))
		var edges := mini(row_types.size(), row_counts.size())
		types.append_array(row_types.slice(0, edges))
		counts.append_array(row_counts.slice(0, edges))
		offsets.append(types.size())
		# A forgotten row submits tier 0 so the planner drops the cell.
		tiers.append(int(row.get("settlement_tier", 0 if row.is_empty() else 255)))
		living.append(int(row.get("living_level", 255)))
		rich.append(int(row.get("rich_bucket", 255)))
		poor.append(int(row.get("poor_bucket", 255)))
	_macro_upload_pending = true
	if _visual_cache == null or cells.is_empty():
		return
	var submitted: Dictionary = _visual_cache.submit_cells({
		"cell_indices": cells, "era_indices": eras, "is_water": water,
		"type_offsets": offsets, "type_indices": types, "type_counts": counts,
		"settlement_tiers": tiers, "living_levels": living,
		"rich_buckets": rich, "poor_buckets": poor,
	})
	if not bool(submitted.get("ok", false)):
		_diagnostics.native_failures = int(_diagnostics.native_failures) + 1
		_diagnostics.last_native_reason = String(submitted.get("reason", ""))
	_diagnostics.submitted_cells = int(_diagnostics.submitted_cells) \
		+ int(submitted.get("accepted", 0))
	var elapsed := float(Time.get_ticks_usec() - begin_usec) / 1000.0
	_diagnostics.last_submit_ms = elapsed
	_diagnostics.max_submit_ms = maxf(float(_diagnostics.max_submit_ms), elapsed)


func set_visual_quality(value: int) -> void:
	var next := clampi(value, 0, 2)
	if next == _visual_quality:
		return
	_visual_quality = next
	_push_material_state()
	# The worker replans every cached cell; resident chunks re-upload as their
	# cells finish, so the old geometry stays until the new one is ready.
	if _visual_cache != null:
		_visual_cache.set_quality(next)


func set_camera_zoom(value: float) -> void:
	_set_camera_zoom(value)
	_refresh_lod()


func set_camera_view(rect: Rect2, center: Vector2, zoom_value: float) -> void:
	_camera_rect = rect
	_camera_center = center
	_set_camera_zoom(zoom_value)
	_refresh_resident_chunks()
	_refresh_lod()


func _set_camera_zoom(value: float) -> void:
	var next := clampf(value, 0.01, 16.0)
	if next == _camera_zoom:
		return
	_camera_zoom = next
	for material in [_body_material, _shadow_material, _decal_material, _macro_material]:
		if material != null:
			material.set_shader_parameter("camera_zoom", _camera_zoom)


func set_season_phase(value: float) -> void:
	_season_phase = value
	_set_tod_parameter("season_phase", _season_phase)


func set_day_phase(value: float) -> void:
	_day_phase = fposmod(value, 1.0)
	_set_tod_parameter("day_phase", _day_phase)


func set_axial_tilt_rad(value: float) -> void:
	_axial_tilt_rad = value
	_set_tod_parameter("axial_tilt_rad", _axial_tilt_rad)


func set_day_night_enabled(value: bool) -> void:
	_day_night_enabled = value
	_set_tod_parameter("day_night_enabled", _day_night_enabled)


func set_tod(_sun_color: Color, _ambient_color: Color,
		_night_factor: float, exposure: float) -> void:
	# Colour palettes and local day/night are evaluated by earth_daylight;
	# TODProfile still owns the common exposure.
	_tod_exposure = maxf(exposure, 0.0)
	_set_tod_parameter("tod_exposure", _tod_exposure, false)


func set_tod_sun_dir(value: Vector3) -> void:
	_tod_sun_dir = value.normalized()
	if _tod_sun_dir.length_squared() <= 0.000001:
		_tod_sun_dir = Vector3(0.4, -0.7, 0.6).normalized()
	_set_tod_parameter("tod_sun_dir", _tod_sun_dir)


func set_tod_debug_sun_position(enabled: bool, uv: Vector2) -> void:
	_tod_debug_sun_position_enabled = enabled
	_tod_debug_sun_uv = Vector2(fposmod(uv.x, 1.0), clampf(uv.y, 0.0, 1.0))
	_set_tod_parameter("tod_debug_sun_position_enabled",
		_tod_debug_sun_position_enabled)
	_set_tod_parameter("tod_debug_sun_uv", _tod_debug_sun_uv)


func set_tod_debug_sun_height_scale(value: float) -> void:
	_tod_debug_sun_height_scale = clampf(value, 0.2, 1.5)
	_set_tod_parameter("tod_debug_sun_height_scale",
		_tod_debug_sun_height_scale)


func _set_tod_parameter(name: StringName, value: Variant,
		include_shadow: bool = true) -> void:
	var materials := [_body_material, _decal_material, _macro_material]
	if include_shadow:
		materials.append(_shadow_material)
	for material in materials:
		if material != null:
			material.set_shader_parameter(name, value)


func diagnostics() -> Dictionary:
	var out := _diagnostics.duplicate()
	out["resident_chunks"] = _chunk_nodes.size()
	out["macro_pending"] = _macro_upload_pending
	out["visual_quality"] = _visual_quality
	out["camera_zoom"] = _camera_zoom
	out["lod_fraction"] = _lod_fraction
	out["queued_chunks"] = _upload_queue.size()
	out["cache"] = _visual_cache.diagnostics() if _visual_cache != null else {}
	return out


## Blocks until the worker has planned every submitted cell. Tests and offline
## tools only; the game never waits on the worker.
func wait_for_layout(timeout_msec: int = 5000) -> bool:
	if _visual_cache == null:
		return false
	var idle := bool(_visual_cache.wait_idle(timeout_msec))
	_poll_ready_chunks()
	while not _upload_queue.is_empty():
		_upload_chunk(_upload_queue.pop_front())
	_upload_set.clear()
	return idle


func settlement_core_bucket(cell_idx: int) -> int:
	return int(_intel.row_for_cell(cell_idx).get("settlement_core_bucket", 0)) \
		if _intel != null else 0


func _process(_delta: float) -> void:
	_diagnostics.process_ticks = int(_diagnostics.process_ticks) + 1
	if _macro_upload_pending and Time.get_ticks_msec() - _last_macro_upload_msec >= 16:
		_macro_upload_pending = false
		_last_macro_upload_msec = Time.get_ticks_msec()
		if _macro_texture != null and _macro_image != null:
			_macro_texture.update(_macro_image)
			_diagnostics.macro_uploads = int(_diagnostics.macro_uploads) + 1
	_poll_ready_chunks()
	_process_upload_queue()


func _configure_macro() -> void:
	if _world == null or _macro_quad == null:
		return
	var bounds := _world.world_bounds
	var quad := QuadMesh.new()
	quad.size = bounds.size
	_macro_quad.mesh = quad
	_macro_quad.position = bounds.get_center()
	var dims := _world.lut_dims
	if dims.x <= 0 or dims.y <= 0:
		dims = Vector2i(maxi(1, mini(_map.cell_count(), 2048)),
			maxi(1, ceili(float(_map.cell_count()) / 2048.0)))
	_macro_image = Image.create(dims.x, dims.y, false, Image.FORMAT_RGBA8)
	_macro_image.fill(Color.TRANSPARENT)
	_macro_texture = ImageTexture.create_from_image(_macro_image)
	_macro_material.set_shader_parameter("building_macro_lut", _macro_texture)
	_macro_material.set_shader_parameter("world_size", bounds.size)
	_macro_material.set_shader_parameter("hex_size", _hex_size)
	_configure_macro_index_high_texture()


## The shared map index atlas stores only the low 16 bits in G/B. Building Macro
## supports the 500x400 target by adding one R8 high-byte texture. The source is
## the bake-time cell CSR, so this cold build never scans HexCell objects.
func _configure_macro_index_high_texture() -> void:
	if _world == null or _world.derived_size.x <= 0 or _world.derived_size.y <= 0:
		return
	var pixel_count := _world.derived_size.x * _world.derived_size.y
	var first := _world.cell_first_px_arr
	var counts := _world.cell_px_count_arr
	var flat := _world.flat_px_indices_arr
	var cell_count := _map.cell_count() if _map != null else 0
	var bytes := _encode_macro_index_high_bytes(
		cell_count, first, counts, flat, pixel_count)
	var image := Image.create_from_data(_world.derived_size.x,
		_world.derived_size.y, false, Image.FORMAT_R8, bytes)
	_macro_index_high_texture = ImageTexture.create_from_image(image)
	if _macro_material != null:
		_macro_material.set_shader_parameter(
			"cell_index_high_atlas", _macro_index_high_texture)


static func _encode_macro_index_high_bytes(cell_count: int,
		first: PackedInt32Array, counts: PackedInt32Array,
		flat: PackedInt32Array, pixel_count: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(maxi(0, pixel_count))
	bytes.fill(255) # map-outside sentinel, combined value 0xFFFFFF
	if cell_count > 0 and first.size() >= cell_count \
			and counts.size() >= cell_count:
		for cell in cell_count:
			var begin: int = first[cell]
			var count: int = counts[cell]
			if begin < 0 or count <= 0 or begin + count > flat.size():
				continue
			var high := (cell >> 16) & 0xFF
			for edge in range(begin, begin + count):
				var pixel: int = flat[edge]
				if pixel >= 0 and pixel < pixel_count:
					bytes[pixel] = high
	return bytes


func _update_macro_cell(cell: int, row: Dictionary) -> void:
	if _macro_image == null or _world == null:
		return
	var dims := _world.lut_dims
	if dims.x <= 0 or dims.y <= 0:
		return
	var x := cell % dims.x
	var y := cell / dims.x
	if row.is_empty():
		_macro_image.set_pixel(x, y, Color.TRANSPARENT)
		return
	var aggregate := _aggregate_archetypes(row)
	var counts: PackedInt64Array = aggregate.counts
	var total: int = int(aggregate.total)
	var dominant := 0
	for a in range(1, ARCHETYPE_COUNT):
		if counts[a] > counts[dominant]:
			dominant = a
	var density := clampf(float(_floor_log2(1 + total)) / 15.0, 0.0, 1.0)
	var tier := int(row.get("settlement_tier", 255))
	if tier >= 1 and tier <= 7:
		density = maxf(density, float(tier) / 8.0)
	var era := clampi(int(row.get("observed_era_index", -1)), 0, 10)
	_macro_image.set_pixel(x, y, Color(density, float(dominant) / 255.0,
		float(era) / 255.0, 1.0))


## Residency is chosen natively from per-chunk bounds of non-empty chunks, so a
## camera move costs one call instead of a scan over every known cell.
func _refresh_resident_chunks() -> void:
	if _map == null or _visual_cache == null or _camera_rect.size == Vector2.ZERO:
		return
	if _camera_zoom < 0.46:
		_clear_chunks()
		return
	var limit := MAX_RESIDENT_WEB if OS.has_feature("web") else MAX_RESIDENT_DESKTOP
	var ordered: PackedInt32Array = _visual_cache.chunks_in_rect(
		_camera_rect.grow(_hex_size * 18.0), _camera_center, limit)
	var wanted := {}
	for chunk_id in ordered:
		wanted[chunk_id] = true
		if not _chunk_nodes.has(chunk_id):
			_enqueue_upload(chunk_id)
	for raw_chunk in _chunk_nodes.keys():
		if not wanted.has(int(raw_chunk)):
			_remove_chunk(int(raw_chunk))


func _report_native_unavailable(reason: String) -> void:
	if _native_path_warning_emitted:
		return
	_native_path_warning_emitted = true
	push_warning("[building-visual] native layout cache unavailable (%s); geometry is disabled until the extension is rebuilt" % reason)


## Concatenates the chunk's cached cells (native memcpy) and swaps the buffers
## into the chunk's existing MultiMeshes. No layout work runs here.
func _upload_chunk(chunk_id: int) -> void:
	if _visual_cache == null or _camera_zoom < 0.46:
		return
	var begin_usec := Time.get_ticks_usec()
	_upload_chunk_buffers(chunk_id)
	var elapsed := float(Time.get_ticks_usec() - begin_usec) / 1000.0
	_diagnostics.last_chunk_upload_ms = elapsed
	_diagnostics.max_chunk_upload_ms = maxf(float(_diagnostics.max_chunk_upload_ms), elapsed)


func _upload_chunk_buffers(chunk_id: int) -> void:
	var current := int(_chunk_instance_counts.get(chunk_id, 0))
	var cap := maxi(0, int(BODY_CAP[_visual_quality])
		- (int(_diagnostics.body_instances) - current))
	var result: Dictionary = _visual_cache.build_chunk(chunk_id, cap)
	if not bool(result.get("ok", false)):
		_diagnostics.native_failures = int(_diagnostics.native_failures) + 1
		_diagnostics.last_native_reason = String(result.get("reason", ""))
		return
	var buffer := PackedFloat32Array(result.get("buffer", PackedFloat32Array()))
	var instance_count := int(result.get("instance_count", 0))
	var decal_buffer := PackedFloat32Array(result.get("decal_buffer", PackedFloat32Array()))
	var decal_count := int(result.get("decal_instance_count", 0))
	_diagnostics.last_chunk_instance_count = instance_count
	_diagnostics.last_chunk_decal_count = decal_count
	_diagnostics.last_chunk_lot_count = int(result.get("lot_count", 0))
	_diagnostics.last_chunk = chunk_id
	_diagnostics.chunk_uploads = int(_diagnostics.chunk_uploads) + 1
	if instance_count <= 0 or buffer.size() < instance_count * 16:
		_remove_chunk(chunk_id)
		_recount_instances()
		return
	var nodes: Dictionary = _chunk_nodes.get(chunk_id, {})
	_put_batch(nodes, "body", "Body", _body_material, buffer, instance_count, null, 3)
	var detailed := _visual_quality > 0
	if detailed and decal_count > 0 and decal_buffer.size() >= decal_count * 16:
		_put_batch(nodes, "decal", "GroundDecal", _decal_material,
			decal_buffer, decal_count, null, 1)
	else:
		_drop_batch(nodes, "decal")
	if detailed and not OS.has_feature("web"):
		_put_batch(nodes, "shadow", "Shadow", _shadow_material,
			buffer, instance_count, _shadow_hull_mesh, 2)
	else:
		_drop_batch(nodes, "shadow")
	_chunk_nodes[chunk_id] = nodes
	_chunk_instance_counts[chunk_id] = instance_count
	_recount_instances()


func _put_batch(nodes: Dictionary, key: String, name: String, material: Material,
		buffer: PackedFloat32Array, instance_count: int, mesh: Mesh,
		layer_z: int) -> void:
	var node = nodes.get(key)
	if node is MultiMeshInstance2D and is_instance_valid(node) and node.multimesh != null:
		node.multimesh.instance_count = instance_count
		node.multimesh.buffer = buffer
		return
	var created := _make_multimesh_instance(name, material, buffer, instance_count, mesh)
	created.z_as_relative = false
	created.z_index = layer_z
	add_child(created)
	nodes[key] = created


func _drop_batch(nodes: Dictionary, key: String) -> void:
	var node = nodes.get(key)
	if node != null and is_instance_valid(node):
		node.queue_free()
	nodes.erase(key)


func _aggregate_archetypes(row: Dictionary) -> Dictionary:
	var counts := PackedInt64Array()
	counts.resize(ARCHETYPE_COUNT)
	counts.fill(0)
	var types := PackedInt32Array(row.get("type_indices", PackedInt32Array()))
	var source_counts := PackedInt64Array(row.get("counts", PackedInt64Array()))
	var total := 0
	for i in mini(types.size(), source_counts.size()):
		var type_idx := types[i]
		if type_idx < 0 or type_idx >= _type_to_archetype.size():
			continue
		var archetype := int(_type_to_archetype[type_idx])
		if archetype >= ARCHETYPE_COUNT:
			continue
		counts[archetype] += source_counts[i]
		total += int(source_counts[i])
	return {"counts": counts, "total": total}


func _enqueue_upload(chunk_id: int) -> void:
	if chunk_id < 0 or _upload_set.has(chunk_id):
		return
	_upload_set[chunk_id] = true
	_upload_queue.append(chunk_id)


## Chunks whose cells all finished planning. Resident ones refresh in place;
## a newly populated chunk near the camera becomes resident.
func _poll_ready_chunks() -> void:
	if _visual_cache == null:
		return
	var ready: PackedInt32Array = _visual_cache.take_ready_chunks()
	for chunk_id in ready:
		if _chunk_nodes.has(chunk_id) or _chunk_in_prefetch(chunk_id):
			_enqueue_upload(chunk_id)


func _process_upload_queue() -> void:
	if _upload_queue.is_empty():
		return
	var begin_usec := Time.get_ticks_usec()
	if _upload_queue.size() > 1:
		_upload_queue.sort_custom(func(a: int, b: int) -> bool:
			return _chunk_center(a).distance_squared_to(_camera_center) \
				< _chunk_center(b).distance_squared_to(_camera_center))
	var uploads := 0
	while not _upload_queue.is_empty() and uploads < UPLOADS_PER_FRAME \
			and Time.get_ticks_usec() - begin_usec < UPLOAD_BUDGET_USEC:
		var chunk_id: int = _upload_queue.pop_front()
		_upload_set.erase(chunk_id)
		if _chunk_nodes.has(chunk_id) or _chunk_in_prefetch(chunk_id):
			_upload_chunk(chunk_id)
			uploads += 1
	var elapsed := float(Time.get_ticks_usec() - begin_usec) / 1000.0
	_diagnostics.last_upload_frame_ms = elapsed
	_diagnostics.max_upload_frame_ms = maxf(float(_diagnostics.max_upload_frame_ms), elapsed)


func _is_water_cell(cell: int) -> bool:
	if _map == null or cell < 0 or cell >= _map.cell_count():
		return true
	if cell < _map.is_water_arr.size() and _map.is_water_arr[cell] != 0:
		return true
	if cell < _map.landform_arr.size():
		return LandformType.is_water(int(_map.landform_arr[cell]))
	return false


## MultiMesh 2D layout is transform(8) + color(4) + custom(4). Body and Shadow
## share one immutable buffer; the shaders expand the unit quad themselves.
func _make_multimesh_instance(name: String, material: Material,
		buffer: PackedFloat32Array, instance_count: int,
		mesh: Mesh = null) -> MultiMeshInstance2D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = mesh if mesh != null else _quad_mesh
	mm.instance_count = maxi(0, instance_count)
	if mm.instance_count > 0:
		mm.buffer = buffer
	var node := MultiMeshInstance2D.new()
	node.name = name
	node.multimesh = mm
	node.material = material
	return node


## Each body carries its rank in its cell's importance order (civic core
## first) in COLOR.a; the shaders collapse instances above `lod_fraction`, so
## every settlement thins from its edge and LOD is one uniform per material.
func _refresh_lod() -> void:
	var fraction := 1.0
	if _camera_zoom < 0.82:
		fraction = LOD_FRACTION_FAR
	elif _camera_zoom < 1.30:
		fraction = LOD_FRACTION_MID
	if fraction == _lod_fraction:
		return
	_lod_fraction = fraction
	_push_lod_fraction()


func _push_lod_fraction() -> void:
	for material in [_body_material, _shadow_material]:
		if material != null:
			material.set_shader_parameter("lod_fraction", _lod_fraction)


func _rebind_world_textures() -> void:
	if _world == null:
		return
	var materials := [_body_material, _shadow_material, _decal_material]
	for material in materials:
		if material == null:
			continue
		material.set_shader_parameter("dyn_lut", _world.dyn_lut_tex)
		material.set_shader_parameter("enum_lut", _world.enum_lut_tex)
		material.set_shader_parameter("lut_dims", Vector2(_world.lut_dims))
		material.set_shader_parameter("cell_count",
			float(_map.cell_count()) if _map != null else 1.0)
	if _body_material != null:
		_body_material.set_shader_parameter("weather_lut", _world.weather_lut_tex)
	if _decal_material != null:
		_decal_material.set_shader_parameter("weather_lut", _world.weather_lut_tex)
	if _macro_material != null:
		_macro_material.set_shader_parameter("map_index_atlas", _world.enum_atlas_tex)
		if _macro_index_high_texture != null:
			_macro_material.set_shader_parameter(
				"cell_index_high_atlas", _macro_index_high_texture)
		_macro_material.set_shader_parameter("enum_lut", _world.enum_lut_tex)
		_macro_material.set_shader_parameter("lut_dims", Vector2(_world.lut_dims))
		if _world.enum_atlas_tex != null:
			_macro_material.set_shader_parameter("atlas_pixel_size", Vector2(
				1.0 / maxf(1.0, _world.enum_atlas_tex.get_width()),
				1.0 / maxf(1.0, _world.enum_atlas_tex.get_height())))
	var bounds := _world.world_bounds
	var daylight_materials := [_body_material, _shadow_material, _decal_material,
		_macro_material]
	for material in daylight_materials:
		if material == null:
			continue
		material.set_shader_parameter("world_origin", bounds.position)
		material.set_shader_parameter("world_size", Vector2(
			maxf(bounds.size.x, 0.0001), maxf(bounds.size.y, 0.0001)))
		material.set_shader_parameter("wrap_origin_x", 0.0)
		material.set_shader_parameter("wrap_period_x", _world.wrap_period_x)
	_push_material_state()


func _push_material_state() -> void:
	for material in [_body_material, _shadow_material, _decal_material]:
		if material != null:
			material.set_shader_parameter("camera_zoom", _camera_zoom)
			material.set_shader_parameter("visual_quality", _visual_quality)
	if _shadow_material != null:
		_shadow_material.set_shader_parameter("shadow_strength",
			0.0 if OS.has_feature("web") else float(SHADOW_STRENGTH[_visual_quality]))
	if _macro_material != null:
		_macro_material.set_shader_parameter("camera_zoom", _camera_zoom)
	_push_lod_fraction()
	_set_tod_parameter("season_phase", _season_phase)
	_set_tod_parameter("day_phase", _day_phase)
	_set_tod_parameter("axial_tilt_rad", _axial_tilt_rad)
	_set_tod_parameter("day_night_enabled", _day_night_enabled)
	_set_tod_parameter("tod_debug_sun_position_enabled",
		_tod_debug_sun_position_enabled)
	_set_tod_parameter("tod_debug_sun_uv", _tod_debug_sun_uv)
	_set_tod_parameter("tod_debug_sun_height_scale",
		_tod_debug_sun_height_scale)
	_set_tod_parameter("tod_sun_dir", _tod_sun_dir)
	_set_tod_parameter("tod_exposure", _tod_exposure, false)


func _chunk_in_prefetch(chunk_id: int) -> bool:
	return _camera_rect.size != Vector2.ZERO \
		and _camera_rect.grow(_hex_size * 18.0).has_point(_chunk_center(chunk_id))


func _chunk_xy(chunk_id: int) -> Vector2i:
	var chunks_x := ceili(float(_map.width) / CHUNK_SIZE)
	return Vector2i(chunk_id % chunks_x, chunk_id / chunks_x)


func _chunk_center(chunk_id: int) -> Vector2:
	var xy := _chunk_xy(chunk_id)
	var x := mini(_map.width - 1, xy.x * CHUNK_SIZE + CHUNK_SIZE / 2)
	var y := mini(_map.height - 1, xy.y * CHUNK_SIZE + CHUNK_SIZE / 2)
	return _cell_world_position(y * _map.width + x)


func _cell_world_position(cell: int) -> Vector2:
	if cell >= 0 and cell < _map.cell_pos_x_arr.size() \
			and cell < _map.cell_pos_y_arr.size():
		return Vector2(_map.cell_pos_x_arr[cell], _map.cell_pos_y_arr[cell]) * _hex_size
	return Vector2.ZERO


func _remove_chunk(chunk_id: int) -> void:
	if not _chunk_nodes.has(chunk_id):
		return
	for node in _chunk_nodes[chunk_id].values():
		if is_instance_valid(node):
			node.queue_free()
	_chunk_nodes.erase(chunk_id)
	_chunk_instance_counts.erase(chunk_id)


func _clear_chunks() -> void:
	for chunk_id in _chunk_nodes.keys():
		_remove_chunk(int(chunk_id))
	_chunk_nodes.clear()
	_chunk_instance_counts.clear()
	_upload_queue.clear()
	_upload_set.clear()
	_recount_instances()


func _recount_instances() -> void:
	var total := 0
	for count in _chunk_instance_counts.values():
		total += int(count)
	_diagnostics.body_instances = total
	_diagnostics.resident_chunks = _chunk_nodes.size()


static func _shader_material(path: String) -> ShaderMaterial:
	var shader := load(path) as Shader
	var material := ShaderMaterial.new()
	material.shader = shader
	return material


## Unit quad in [-1, 1]; every building pass expands it to its own footprint.
static func _make_quad_mesh() -> ArrayMesh:
	var vertices := PackedVector2Array([
		Vector2(-1.0, -1.0), Vector2(1.0, -1.0),
		Vector2(1.0, 1.0), Vector2(-1.0, 1.0),
	])
	var uv := PackedVector2Array([
		Vector2(0.0, 0.0), Vector2(1.0, 0.0),
		Vector2(1.0, 1.0), Vector2(0.0, 1.0),
	])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Shadow hull fan: a centre vertex plus each footprint corner twice, once per
## adjacent edge. VERTEX is the corner sign and UV the edge's outward normal;
## building_shadow.gdshader pushes the vertices of edges facing away from the
## sun along the shadow, which traces the convex hull of the swept footprint.
static func _make_shadow_hull_mesh() -> ArrayMesh:
	var vertices := PackedVector2Array([Vector2.ZERO])
	var normals := PackedVector2Array([Vector2.ZERO])
	var corners := [Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1), Vector2(-1, -1)]
	var edge_normals := [Vector2(1, 0), Vector2(0, 1), Vector2(-1, 0), Vector2(0, -1)]
	for k in 4:
		vertices.append(corners[k])
		normals.append(edge_normals[(k + 3) % 4])
		vertices.append(corners[k])
		normals.append(edge_normals[k])
	var indices := PackedInt32Array()
	for k in 8:
		indices.append_array([0, 1 + k, 1 + (k + 1) % 8])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func _floor_log2(value: int) -> int:
	var result := -1
	var current := maxi(0, value)
	while current > 0:
		current >>= 1
		result += 1
	return maxi(0, result)
