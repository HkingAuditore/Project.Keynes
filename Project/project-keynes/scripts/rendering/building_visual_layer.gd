class_name BuildingVisualLayer
extends Node2D

const BuildingCatalogUpload = preload("res://scripts/rendering/building_visual_catalog_upload.gd")
const BuildingChunkUpload = preload("res://scripts/rendering/building_visual_chunk_upload.gd")
const BuildingMaterialState = preload("res://scripts/rendering/building_visual_material_state.gd")
const FogDrawBounds = preload("res://scripts/rendering/fog_draw_bounds.gd")
const BuildingVisualAssets = preload("res://scripts/rendering/building_visual_assets.gd")


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
const BODY_SHADER_PATH := "res://shaders/building_compound.gdshader"
const DECAL_SHADER_PATH := "res://shaders/building_ground_decal.gdshader"
# 绝对绘制层带（top_level + z_as_relative=false，见 _ready），与 vegetation_family_layer.gd
# 的 Z_BAND_* 成对维护：地形 0 < 贴花/投影/灌木/资源 1 < 建筑主体 2 < 树冠 3。
# 树冠必须压住屋顶——植被只被排除在 settlement core 半径内，外圈和邻格的树冠天生就会
# 伸到屋顶上；建筑排在树冠之上时，每栋房子都像贴在森林上的一块贴纸。
const Z_BAND_DECAL := 1
const Z_BAND_SHADOW := 1
const Z_BAND_BODY := 2
const Z_BAND_MACRO := 1
# Strength parameters copied from the terrain material. Both shaders decode the
# same packed 4-bit horizon, so the numbers must be identical or a roof and the
# ground it stands on disagree about where the mountain shadow ends.
const TERRAIN_LIGHTING_PARAMS := [
	"terrain_horizon_strength", "terrain_horizon_softness",
	"terrain_horizon_max_angle", "gi_horizon_lut", "gi_lut_bound",
	"gi_ao_strength", "gi_ao_floor", "gi_ao_smoothing", "gi_bent_strength",
	"gi_normal_floor", "sky_ibl_bound", "sky_ambient_strength", "sky_day_sh_l1",
	"sky_night_sh_l1",
]

# Settlement layout (lots, streets, plaza, era-specific building volumes) is
# planned per cell by NativeBuildingVisualCache on a worker or in Web slices. Only
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
# Original (unprefixed) shader resources for the passes that sample terrain
# lighting; the tiled raster variant is a duplicate with MAP_VISUAL_TILED prepended.
var _body_shader_source: Shader
var _shadow_shader_source: Shader
var _decal_shader_source: Shader
var _macro_shader_source: Shader
var _shader_tiled := false
var _cloud_shadow_direct := false
var _cloud_shadow_texture: Texture2D
var _cloud_shadow_wrap_origin_uv := 0.0
var _cloud_shadow_wrap_period_uv := 0.0
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
	# 本层自己不绘制（只有子批次画东西，且都是绝对 z），这里留 0 只是不让
	# "建筑排在 3" 这种过时读数继续误导下一个读者。真正的层带见 Z_BAND_*。
	z_index = 0
	_quad_mesh = _make_quad_mesh()
	_shadow_hull_mesh = _make_shadow_hull_mesh()
	_body_material = _shader_material(BODY_SHADER_PATH)
	_body_shader_source = _body_material.shader
	_shadow_material = _shader_material("res://shaders/building_shadow.gdshader")
	_shadow_shader_source = _shadow_material.shader
	_decal_material = _shader_material(DECAL_SHADER_PATH)
	_decal_shader_source = _decal_material.shader
	_macro_material = _shader_material("res://shaders/building_macro.gdshader")
	_macro_shader_source = _macro_material.shader
	# web 受限档：把档位宏补进这 4 张（详见 compose_shader_code 的注释）。
	_apply_web_variant_prefix()
	_macro_quad = MeshInstance2D.new()
	_macro_quad.name = "BuildingMacro"
	_macro_quad.z_as_relative = false
	_macro_quad.z_index = Z_BAND_MACRO
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
	return BuildingCatalogUpload.configure_catalog(self, catalog)


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
	_set_tod_parameter("eternal_min_elevation_rad", _eternal_min_elevation_rad)
	_set_tod_parameter("eternal_max_hour_angle_rad", _eternal_max_hour_angle_rad)
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


var _eternal_min_elevation_rad: float = deg_to_rad(10.0)
var _eternal_max_hour_angle_rad: float = deg_to_rad(70.0)

func set_eternal_daylight_parameters(min_elevation: float, max_hour_angle: float) -> void:
	_eternal_min_elevation_rad = min_elevation
	_eternal_max_hour_angle_rad = max_hour_angle
	_set_tod_parameter("eternal_min_elevation_rad", min_elevation)
	_set_tod_parameter("eternal_max_hour_angle_rad", max_hour_angle)


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
	BuildingChunkUpload._configure_macro(self)

func _configure_macro_index_high_texture() -> void:
	BuildingChunkUpload._configure_macro_index_high_texture(self)

static func _encode_macro_index_high_bytes(cell_count: int,
		first: PackedInt32Array, counts: PackedInt32Array,
		flat: PackedInt32Array, pixel_count: int) -> PackedByteArray:
	return BuildingChunkUpload._encode_macro_index_high_bytes(cell_count, first, counts, flat, pixel_count)

func _update_macro_cell(cell: int, row: Dictionary) -> void:
	BuildingChunkUpload._update_macro_cell(self, cell, row)

func _refresh_resident_chunks() -> void:
	BuildingChunkUpload._refresh_resident_chunks(self)

func _report_native_unavailable(reason: String) -> void:
	BuildingChunkUpload._report_native_unavailable(self, reason)

func _upload_chunk(chunk_id: int) -> void:
	BuildingChunkUpload._upload_chunk(self, chunk_id)

func _upload_chunk_buffers(chunk_id: int) -> void:
	BuildingChunkUpload._upload_chunk_buffers(self, chunk_id)

func _put_batch(nodes: Dictionary, key: String, node_name: String, material: Material,
		buffer: PackedFloat32Array, instance_count: int, mesh: Mesh,
		layer_z: int, kind: FogDrawBounds.Kind, same_geometry: MultiMesh = null) -> void:
	BuildingChunkUpload._put_batch(self, nodes, key, node_name, material, buffer, instance_count, mesh, layer_z, kind, same_geometry)

func _drop_batch(nodes: Dictionary, key: String) -> void:
	BuildingChunkUpload._drop_batch(self, nodes, key)

func _aggregate_archetypes(row: Dictionary) -> Dictionary:
	return BuildingChunkUpload._aggregate_archetypes(self, row)


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
	BuildingMaterialState._rebind_world_textures(self)

func _push_material_state() -> void:
	BuildingMaterialState._push_material_state(self)

func set_terrain_lighting(source: ShaderMaterial) -> void:
	BuildingMaterialState.set_terrain_lighting(self, source)

func set_cloud_shadow_field(texture: Texture2D, direct_enabled: bool,
		wrap_origin_uv: float, wrap_period_uv: float) -> void:
	BuildingMaterialState.set_cloud_shadow_field(self, texture, direct_enabled, wrap_origin_uv, wrap_period_uv)

func _apply_cloud_shadow_shader_variants() -> void:
	BuildingMaterialState._apply_cloud_shadow_shader_variants(self)

func _push_cloud_shadow_uniforms() -> void:
	BuildingMaterialState._push_cloud_shadow_uniforms(self)

func _sync_terrain_textures() -> void:
	BuildingMaterialState._sync_terrain_textures(self)

func _apply_terrain_shader_variants() -> void:
	BuildingMaterialState._apply_terrain_shader_variants(self)


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


## 统一合成一份 shader 源码：web 档位宏 + tiled 宏 + 原始源码。
##
## Web 受限档（`PK_WEB_BUILDING_MIN`）的存在理由：这 4 张建筑 shader **从来没有**
## include `shader_quality.gdshaderinc`，所以一直拿不到 `MOBILE_QUALITY_LOW`。
## 后果不是"画质没降"，而是 `terrain_horizon.gdshaderinc:273` 的 LOW 分支不生效，
## `gi_horizon_lut[nibbles[d]]` 那个「8 次循环 × 4 个 tap」的动态 uniform 数组查表
## 不会被 DCE 掉 —— 浏览器首次编译实测 building_compound 3501 ms、
## building_ground_decal 2283 ms、building_macro 395 ms。
##
## web 上 `terrain_horizon_tex` 恒为 null（map_baker 在 web 上不烘 horizon），
## LOW 分支与"未绑定早退"分支构造的是同一个中性结构体，所以视觉逐位不变。
##
## ⚠ 预热器（web_shader_warmup.gd）必须用**逐字相同**的字符串，否则驱动缓存不命中、
## 预热白做。改这里要同步那里。
const PK_WEB_BUILDING_MIN_PREFIX = BuildingVisualAssets.PK_WEB_BUILDING_MIN_PREFIX

static func web_building_min_active() -> bool:
	return BuildingVisualAssets.web_building_min_active()

static func compose_shader_code(source: Shader, tiled: bool,
		cloud_shadow_direct: bool = false) -> String:
	return BuildingVisualAssets.compose_shader_code(source, tiled, cloud_shadow_direct)


func _apply_web_variant_prefix() -> void:
	if not web_building_min_active():
		return
	for entry in [[_body_material, _body_shader_source],
			[_shadow_material, _shadow_shader_source],
			[_decal_material, _decal_shader_source],
			[_macro_material, _macro_shader_source]]:
		_assign_shader_variant(entry[0], entry[1])


func _assign_shader_variant(material: ShaderMaterial, source: Shader) -> void:
	if material == null or source == null:
		return
	var variant := Shader.new()
	variant.code = compose_shader_code(source, _shader_tiled, _cloud_shadow_direct)
	material.shader = variant
	_push_cloud_shadow_uniforms()
	WebTelemetry.note_variant(
		String(source.resource_path).get_file().get_basename(), variant.code)


static func _shader_material(path: String) -> ShaderMaterial:
	return BuildingVisualAssets._shader_material(path)


## Unit quad in [-1, 1]; every building pass expands it to its own footprint.
static func _make_quad_mesh() -> ArrayMesh:
	return BuildingVisualAssets._make_quad_mesh()


## Shadow hull fan: a centre vertex plus each footprint corner twice, once per
## adjacent edge. VERTEX is the corner sign and UV the edge's outward normal;
## building_shadow.gdshader pushes the vertices of edges facing away from the
## sun along the shadow, which traces the convex hull of the swept footprint.
static func _make_shadow_hull_mesh() -> ArrayMesh:
	return BuildingVisualAssets._make_shadow_hull_mesh()


static func _floor_log2(value: int) -> int:
	var result := -1
	var current := maxi(0, value)
	while current > 0:
		current >>= 1
		result += 1
	return maxi(0, result)
