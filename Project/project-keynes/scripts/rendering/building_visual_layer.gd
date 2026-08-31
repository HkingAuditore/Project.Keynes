class_name BuildingVisualLayer
extends Node2D

const CHUNK_SIZE := 16
const ARCHETYPE_COUNT := 6
const STYLE_COUNT := 66
const VISUAL_PROFILE_COUNT := 3
const ART_ERA_BAND_COUNT := 4
const VISUAL_MANIFEST_PATH := "res://assets/buildings/building_visual_manifest.json"
const VISUAL_ALBEDO_PATH := "res://assets/buildings/generated/building_albedo.png"
const VISUAL_SURFACE_PATH := "res://assets/buildings/generated/building_surface.png"
const MAX_RESIDENT_DESKTOP := 128
const MAX_RESIDENT_WEB := 48
const BODY_CAP := [6000, 18000, 36000]
const NEAR_CAP := [8, 16, 24]
const RIVER_CLEAR_THRESHOLD := 0.42
# Native/GDScript bakers retain their stable placement scale; all visual passes
# shrink around each instance centre in the shader. This keeps stale/current
# native DLLs visually identical and does not rewrite the MultiMesh ABI.
#
# A compound is drawn on a quad two units wide carrying artwork over about 85%
# of it, so its visible width is `1.7 * baker_scale * COMPOUND_VISUAL_SCALE`,
# and a pointy-top hex is `sqrt(3) * hex_size` wide.
const COMPOUND_VISUAL_SCALE := 0.144
const COMPOUND_MAX_HEX_WIDTH_FRACTION := 0.16
#
# --- Settlement density ladder -----------------------------------------------
# One authoritative building total drives compound count, compound size and
# cluster radius through a single normalised value, so a settlement's footprint
# grows continuously instead of stepping through per-archetype buckets. Discrete
# buckets used to spend most of their resolution below ten buildings and then
# saturate in the low hundreds, which made a mature city indistinguishable from
# a town.
#
# `density = log2(1 + total) / log2(1 + DENSITY_LADDER_TOP)`, clamped to [0, 1].
# Coverage of the hex at density 1 works out to
# `COMPOUND_COUNT_MAX * visible_width^2 / hex_area` = about 70%.
#
#                                  ONE compound is   ALL compounds cover
#   total       density  compounds  this wide vs hex  this much of hex area
#   1           0.060    1          8.9%              0.9%
#   15          0.241    6          10.3%             7.3%
#   100         0.401    10         11.5%             15.2%
#   1 000       0.600    14         12.9%             27.0%
#   10 000      0.800    19         14.4%             45.6%
#   100 000     1.000    24         15.9%             70.0%
#
# Every constant below must stay in sync with world_ext_building_visual.cpp.
const DENSITY_LADDER_TOP := 100000.0
const COMPOUND_COUNT_MAX := 24
const COMPOUND_SCALE_MIN := 0.60
const COMPOUND_SCALE_MAX := 1.125
# Multiplier on the per-archetype ring radii in `_best_candidate`. A hamlet keeps
# a tight cluster; the ladder top opens the ring until the built-up area covers
# the intended share of the hex while staying inside the hex inradius.
const COMPOUND_SPREAD_MIN := 0.16
const COMPOUND_SPREAD_MAX := 1.15
const ARCHETYPE_NAMES := [
	"agriculture", "extractive", "manufacturing",
	"energy", "knowledge", "service",
]

## The production baker is DCWorldExt::bake_building_visual_chunk. Keeping the
## legacy baker behind an explicit opt-in prevents a stale/partial DLL from
## silently moving desktop play back onto a per-cell GDScript hot loop.
@export var allow_gdscript_baker_fallback: bool = false

var _map: MapData
var _world: WorldData
var _world_ext: Object
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
var _type_to_visual_profile := PackedByteArray()
var _chunk_nodes := {}
var _chunk_instance_counts := {}
var _dirty_chunk_queue: Array[int] = []
var _dirty_chunk_set := {}
var _sync_upload_frame := 0
var _body_mesh: ArrayMesh
var _shadow_mesh: ArrayMesh
var _decal_mesh: ArrayMesh
var _body_material: ShaderMaterial
var _shadow_material: ShaderMaterial
var _decal_material: ShaderMaterial
var _macro_material: ShaderMaterial
var _style_texture: ImageTexture
var _material_atlas_texture: Texture2D
var _material_mask_texture: Texture2D
var _authored_atlas_ready := false
var _authored_atlas_grid := Vector2(12.0, 6.0)
var _authored_atlas_tile_size := 160.0
var _macro_quad: MeshInstance2D
var _macro_image: Image
var _macro_texture: ImageTexture
var _macro_index_high_texture: ImageTexture
var _macro_upload_pending := false
var _last_macro_upload_msec := 0
var _native_path_warning_emitted := false
var _runtime_probe_logged := false
var _diagnostics := {
	"catalog_types": 0, "catalog_unresolved": 0, "resident_chunks": 0,
	"body_instances": 0, "macro_uploads": 0, "chunk_rebuilds": 0,
	"queued_chunks": 0, "last_chunk_bake_ms": 0.0, "max_chunk_bake_ms": 0.0,
	"chunk_bake_perf_gate_ms": 1.5, "bulk_encoder_required": false,
	"native_bake_calls": 0, "native_bake_failures": 0,
	"last_native_bake_ms": 0.0, "max_native_bake_ms": 0.0,
	"process_ticks": 0, "last_native_instance_count": 0,
	"last_native_reason": "", "last_native_chunk": -1,
	"native_required": true, "gdscript_fallback_enabled": false,
	"gdscript_fallback_calls": 0,
	"authored_atlas": false, "authored_atlas_reason": "",
	"authored_atlas_tiles": 0, "authored_visual_profiles": 0,
}


func _ready() -> void:
	# Use the same absolute 2D world-space contract as vegetation/detail layers.
	# The renderer itself is top-level in both player_game.tscn and main.tscn;
	# making this pass absolute avoids scene-parent z inheritance hiding buildings
	# behind the terrain on one of the two entry paths.
	top_level = true
	z_as_relative = false
	z_index = 3
	_body_mesh = _make_compound_mesh()
	_shadow_mesh = _make_shadow_mesh()
	_decal_mesh = _make_decal_mesh()
	_body_material = _shader_material("res://shaders/building_compound.gdshader")
	_shadow_material = _shader_material("res://shaders/building_shadow.gdshader")
	_decal_material = _shader_material("res://shaders/building_ground_decal.gdshader")
	_macro_material = _shader_material("res://shaders/building_macro.gdshader")
	_configure_style_resources()
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
	_diagnostics.gdscript_fallback_enabled = allow_gdscript_baker_fallback
	_clear_chunks()
	var audit := configure_catalog(catalog)
	_configure_macro()
	_rebind_world_textures()
	if _intel != null:
		update_intel(_intel, _intel.known_cells())
	return audit


func set_world_ext(ext: Object) -> void:
	_world_ext = ext


func native_bake_available() -> bool:
	return _world_ext != null and _world_ext.has_method("bake_building_visual_chunk")


func configure_catalog(catalog: Dictionary) -> Dictionary:
	var ids := PackedStringArray(catalog.get("building_type_ids", PackedStringArray()))
	var kinds := PackedInt32Array(catalog.get("building_kinds", PackedInt32Array()))
	var sectors := PackedInt32Array(catalog.get(
		"building_economic_sectors", PackedInt32Array()))
	var offsets := PackedInt32Array(catalog.get(
		"building_semantic_tag_offsets", PackedInt32Array()))
	var tags := PackedStringArray(catalog.get(
		"building_semantic_tags", PackedStringArray()))
	_type_to_archetype.resize(ids.size())
	_type_to_visual_profile.resize(ids.size())
	_type_to_visual_profile.fill(0)
	var unresolved := PackedStringArray()
	if kinds.size() != ids.size() or sectors.size() != ids.size() \
			or offsets.size() != ids.size() + 1 or offsets.is_empty() \
			or offsets[0] != 0 or offsets[-1] != tags.size():
		_catalog_ready = false
		return {"ok": false, "reason": "building_visual_catalog_shape_invalid"}
	var authored_profiles := 0
	for i in ids.size():
		var archetype := 5 if kinds[i] == 2 else sectors[i]
		# The silhouette variant is a style slot, not a semantic claim. An author
		# may pin it with the same explicit tag convention used by archetypes;
		# otherwise a stable index hash spreads authored types across the
		# category's variants so neighbouring types never share one outline.
		var profile := -1
		for edge in range(offsets[i], offsets[i + 1]):
			var tag := String(tags[edge])
			if tag.begins_with("visual.archetype."):
				archetype = ARCHETYPE_NAMES.find(tag.trim_prefix("visual.archetype."))
			elif tag.begins_with("visual.profile."):
				profile = tag.trim_prefix("visual.profile.").to_int()
				authored_profiles += 1
		if profile < 0 or profile >= VISUAL_PROFILE_COUNT:
			profile = _stable_hash(i, 0, 0, 19) % VISUAL_PROFILE_COUNT
		_type_to_visual_profile[i] = profile
		if archetype < 0 or archetype >= ARCHETYPE_COUNT:
			unresolved.append(ids[i])
			_type_to_archetype[i] = 255
		else:
			_type_to_archetype[i] = archetype
	_catalog_ready = unresolved.is_empty()
	_diagnostics.catalog_types = ids.size()
	_diagnostics.catalog_unresolved = unresolved.size()
	_diagnostics.authored_visual_profiles = authored_profiles
	return {"ok": _catalog_ready,
		"reason": "" if _catalog_ready else "building_visual_catalog_unresolved",
		"type_count": ids.size(), "unresolved_ids": unresolved,
		"authored_visual_profiles": authored_profiles}


func update_intel(intel: BuildingVisualIntelCache,
		changed_cells: PackedInt32Array) -> void:
	_intel = intel
	if _map == null or _world == null or not _catalog_ready:
		return
	var dirty_chunks := {}
	for cell in changed_cells:
		if cell < 0 or cell >= _map.cell_count():
			continue
		_update_macro_cell(cell)
		dirty_chunks[_chunk_id_for_cell(cell)] = true
	for raw_chunk in dirty_chunks:
		var chunk_id := int(raw_chunk)
		if _chunk_nodes.has(chunk_id) or _chunk_in_prefetch(chunk_id):
			_enqueue_chunk_rebuild(chunk_id)
	_macro_upload_pending = true


func set_visual_quality(value: int) -> void:
	var next := clampi(value, 0, 2)
	if next == _visual_quality:
		return
	_visual_quality = next
	_push_material_state()
	for chunk_id in _chunk_nodes.keys():
		_enqueue_chunk_rebuild(int(chunk_id))


func set_camera_zoom(value: float) -> void:
	_camera_zoom = clampf(value, 0.01, 16.0)
	_push_material_state()
	_refresh_lod()


func set_camera_view(rect: Rect2, center: Vector2, zoom_value: float) -> void:
	_camera_rect = rect
	_camera_center = center
	_camera_zoom = clampf(zoom_value, 0.01, 16.0)
	_push_material_state()
	_refresh_resident_chunks()
	_refresh_lod()


func set_sun_direction(value: Vector2) -> void:
	if _shadow_material != null:
		_shadow_material.set_shader_parameter("legacy_sun_dir",
			value.normalized() if value.length_squared() > 0.0001 else Vector2(0.55, 0.84))


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
	var materials := [_body_material, _macro_material]
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
	return out


func settlement_core_bucket(cell_idx: int) -> int:
	return int(_intel.row_for_cell(cell_idx).get("settlement_core_bucket", 0)) \
		if _intel != null else 0


func _process(_delta: float) -> void:
	_diagnostics.process_ticks = int(_diagnostics.process_ticks) + 1
	if not _runtime_probe_logged and int(_diagnostics.process_ticks) <= 3:
		var queued_chunk := int(_dirty_chunk_queue[0]) if not _dirty_chunk_queue.is_empty() else -1
		print("[building-visual] queue_probe ticks=%d queued=%d chunk=%d camera_rect=%s prefetch=%s zoom=%.3f" % [
			int(_diagnostics.process_ticks), _dirty_chunk_queue.size(), queued_chunk,
			str(_camera_rect), _chunk_in_prefetch(queued_chunk) if queued_chunk >= 0 else false,
			_camera_zoom])
	if _macro_upload_pending and Time.get_ticks_msec() - _last_macro_upload_msec >= 16:
		_macro_upload_pending = false
		_last_macro_upload_msec = Time.get_ticks_msec()
		if _macro_texture != null and _macro_image != null:
			_macro_texture.update(_macro_image)
			_diagnostics.macro_uploads = int(_diagnostics.macro_uploads) + 1
	_process_chunk_rebuild_queue()


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


func _update_macro_cell(cell: int) -> void:
	if _macro_image == null or _world == null or _intel == null:
		return
	var dims := _world.lut_dims
	if dims.x <= 0 or dims.y <= 0:
		return
	var x := cell % dims.x
	var y := cell / dims.x
	var row := _intel.row_for_cell(cell)
	if row.is_empty():
		_macro_image.set_pixel(x, y, Color.TRANSPARENT)
		return
	var aggregate := _aggregate_archetypes(row)
	var counts: PackedInt64Array = aggregate.counts
	var profile_counts: PackedInt64Array = aggregate.profile_counts
	var total: int = int(aggregate.total)
	var dominant := 0
	for a in range(1, ARCHETYPE_COUNT):
		if counts[a] > counts[dominant]:
			dominant = a
	var density := clampf(float(_floor_log2(1 + total)) / 15.0, 0.0, 1.0)
	var era := clampi(int(row.get("observed_era_index", -1)), 0, 10)
	_macro_image.set_pixel(x, y, Color(density, float(dominant) / 255.0,
		float(era) / 255.0, 1.0))


func _refresh_resident_chunks() -> void:
	if _map == null or _intel == null or _camera_rect.size == Vector2.ZERO:
		return
	if _camera_zoom < 0.46:
		_clear_chunks()
		_dirty_chunk_queue.clear()
		_dirty_chunk_set.clear()
		return
	var wanted := {}
	var grown := _camera_rect.grow(_hex_size * 18.0)
	for cell in _intel.known_cells():
		var pos := _cell_world_position(cell)
		if grown.has_point(pos):
			wanted[_chunk_id_for_cell(cell)] = true
	var ordered: Array = wanted.keys()
	ordered.sort_custom(func(a, b):
		return _chunk_center(int(a)).distance_squared_to(_camera_center) \
			< _chunk_center(int(b)).distance_squared_to(_camera_center))
	var limit := MAX_RESIDENT_WEB if OS.has_feature("web") else MAX_RESIDENT_DESKTOP
	if ordered.size() > limit:
		ordered.resize(limit)
	wanted.clear()
	for chunk_id in ordered:
		wanted[int(chunk_id)] = true
		if not _chunk_nodes.has(int(chunk_id)):
			_enqueue_chunk_rebuild(int(chunk_id))
	for raw_chunk in _chunk_nodes.keys():
		if not wanted.has(int(raw_chunk)):
			_remove_chunk(int(raw_chunk))


func _rebuild_chunk(chunk_id: int) -> void:
	var bake_begin_usec := Time.get_ticks_usec()
	_remove_chunk(chunk_id)
	_recount_instances()
	if _camera_zoom < 0.46 or _map == null or _intel == null:
		_record_chunk_bake_time(bake_begin_usec)
		return
	if native_bake_available():
		var native_result := _bake_chunk_native(chunk_id)
		if bool(native_result.get("ok", false)):
			_apply_native_chunk_result(chunk_id, native_result)
			_diagnostics.native_bake_calls = int(_diagnostics.native_bake_calls) + 1
			var native_ms := float(native_result.get("elapsed_ms", -1.0))
			if native_ms >= 0.0:
				_diagnostics.last_native_bake_ms = native_ms
				_diagnostics.max_native_bake_ms = maxf(
					float(_diagnostics.get("max_native_bake_ms", 0.0)), native_ms)
				if native_ms > float(_diagnostics.chunk_bake_perf_gate_ms):
					_diagnostics.bulk_encoder_required = true
			_record_chunk_bake_time(bake_begin_usec)
			return
		_diagnostics.native_bake_failures = int(_diagnostics.native_bake_failures) + 1
		_report_native_bake_unavailable("native_bake_failed")
	else:
		_diagnostics.native_bake_failures = int(_diagnostics.native_bake_failures) + 1
		_report_native_bake_unavailable("native_method_missing")
	if allow_gdscript_baker_fallback:
		_diagnostics.gdscript_fallback_calls = int(
			_diagnostics.gdscript_fallback_calls) + 1
		_rebuild_chunk_gdscript(chunk_id, bake_begin_usec)
	else:
		# Native-only production mode fails closed. A missing or stale extension
		# must never turn a visible chunk into a GDScript numeric hot loop.
		_record_chunk_bake_time(bake_begin_usec)
	return


func _report_native_bake_unavailable(reason: String) -> void:
	if _native_path_warning_emitted:
		return
	_native_path_warning_emitted = true
	push_warning("[building-visual] native C++ baker unavailable (%s); geometry is disabled until the extension is rebuilt" % reason)


func _rebuild_chunk_gdscript(chunk_id: int, bake_begin_usec: int) -> void:
	var specs: Array[Dictionary] = []
	var chunk_xy := _chunk_xy(chunk_id)
	var min_x := chunk_xy.x * CHUNK_SIZE
	var min_y := chunk_xy.y * CHUNK_SIZE
	for y in range(min_y, mini(min_y + CHUNK_SIZE, _map.height)):
		for x in range(min_x, mini(min_x + CHUNK_SIZE, _map.width)):
			var cell := y * _map.width + x
			if _is_water_cell(cell):
				continue
			var row := _intel.row_for_cell(cell)
			if row.is_empty():
				continue
			specs.append_array(_build_cell_specs(cell, row))
	if specs.is_empty():
		return
	specs.sort_custom(func(a, b):
		if int(a.importance) == int(b.importance):
			return int(a.stable_order) < int(b.stable_order)
		return int(a.importance) > int(b.importance))
	var cap: int = maxi(0, int(BODY_CAP[_visual_quality])
		- int(_diagnostics.body_instances))
	if specs.size() > cap:
		specs.resize(cap)
	if specs.is_empty():
		_recount_instances()
		_record_chunk_bake_time(bake_begin_usec)
		return
	var body_buffer := _specs_to_multimesh_buffer(specs)
	var body := _make_multimesh_instance(
		"Body", _body_mesh, _body_material, specs, body_buffer)
	body.z_as_relative = false
	body.z_index = 3
	add_child(body)
	var nodes := {"body": body}
	if _visual_quality > 0:
		var decal_specs := _select_decal_specs(specs)
		if not decal_specs.is_empty():
			var decal := _make_multimesh_instance(
				"GroundDecal", _decal_mesh, _decal_material, decal_specs,
				_specs_to_multimesh_buffer(decal_specs))
			decal.z_as_relative = false
			decal.z_index = 1
			add_child(decal)
			nodes["decal"] = decal
	if _visual_quality > 0 and not OS.has_feature("web"):
		var shadow := _make_multimesh_instance(
			"Shadow", _shadow_mesh, _shadow_material, specs, body_buffer)
		shadow.z_as_relative = false
		shadow.z_index = 2
		add_child(shadow)
		nodes["shadow"] = shadow
	_chunk_nodes[chunk_id] = nodes
	_chunk_instance_counts[chunk_id] = specs.size()
	_diagnostics.chunk_rebuilds = int(_diagnostics.chunk_rebuilds) + 1
	_recount_instances()
	_apply_chunk_lod(chunk_id)
	_record_chunk_bake_time(bake_begin_usec)


func _bake_chunk_native(chunk_id: int) -> Dictionary:
	var chunk_xy := _chunk_xy(chunk_id)
	var min_x := chunk_xy.x * CHUNK_SIZE
	var min_y := chunk_xy.y * CHUNK_SIZE
	var cells := PackedInt32Array()
	var pos_x := PackedFloat32Array()
	var pos_y := PackedFloat32Array()
	var eras := PackedInt32Array()
	var water := PackedByteArray()
	var offsets := PackedInt32Array([0])
	var types := PackedInt32Array()
	var counts := PackedInt64Array()
	for y in range(min_y, mini(min_y + CHUNK_SIZE, _map.height)):
		for x in range(min_x, mini(min_x + CHUNK_SIZE, _map.width)):
			var cell := y * _map.width + x
			var row := _intel.row_for_cell(cell)
			if row.is_empty():
				continue
			cells.append(cell)
			var position := _cell_world_position(cell)
			pos_x.append(position.x)
			pos_y.append(position.y)
			eras.append(clampi(int(row.get("observed_era_index", -1)), 0, 10))
			water.append(1 if _is_water_cell(cell) else 0)
			var row_types := PackedInt32Array(row.get("type_indices", PackedInt32Array()))
			var row_counts := PackedInt64Array(row.get("counts", PackedInt64Array()))
			for edge in mini(row_types.size(), row_counts.size()):
				types.append(row_types[edge])
				counts.append(row_counts[edge])
			offsets.append(types.size())
	if cells.is_empty():
		return {"ok": true, "path": "gdext_building_visual", "instance_count": 0,
			"decal_instance_count": 0, "buffer": PackedFloat32Array(),
			"decal_buffer": PackedFloat32Array(), "elapsed_ms": 0.0}
	var knobs := {
		"cell_indices": cells, "cell_pos_x": pos_x, "cell_pos_y": pos_y,
		"type_offsets": offsets, "type_indices": types, "type_counts": counts,
		"era_indices": eras, "type_to_archetype": _type_to_archetype,
		"type_to_visual_profile": _type_to_visual_profile,
		"is_water": water, "quality": _visual_quality,
		"instance_cap": maxi(0, int(BODY_CAP[_visual_quality])
			- int(_diagnostics.body_instances)),
		"hex_size": _hex_size, "cell_count": _map.cell_count(),
		"layout_seed": 0, "river_clear_threshold": RIVER_CLEAR_THRESHOLD,
	}
	if _world != null and not _world.flow_buffer.is_empty():
		knobs["flow_buffer"] = _world.flow_buffer
		knobs["flow_w"] = _world.derived_size.x
		knobs["flow_h"] = _world.derived_size.y
		knobs["flow_origin_x"] = _world.world_bounds.position.x
		knobs["flow_origin_y"] = _world.world_bounds.position.y
		knobs["flow_size_x"] = _world.world_bounds.size.x
		knobs["flow_size_y"] = _world.world_bounds.size.y
		knobs["flow_wrap_period_x"] = _world.wrap_period_x
	return _world_ext.bake_building_visual_chunk(knobs)


func _apply_native_chunk_result(chunk_id: int, result: Dictionary) -> void:
	var buffer := PackedFloat32Array(result.get("buffer", PackedFloat32Array()))
	var instance_count := int(result.get("instance_count", 0))
	_diagnostics.last_native_instance_count = instance_count
	_diagnostics.last_native_reason = String(result.get("reason", ""))
	_diagnostics.last_native_chunk = chunk_id
	if instance_count <= 0 or buffer.size() < instance_count * 16:
		if not _runtime_probe_logged:
			print("[building-visual] native_probe chunk=%d ok=%s instances=%d buffer=%d reason=%s" % [
				chunk_id, bool(result.get("ok", false)), instance_count,
				buffer.size(), String(result.get("reason", ""))])
			_runtime_probe_logged = true
		_recount_instances()
		return
	var body := _make_multimesh_instance_buffer(
		"Body", _body_mesh, _body_material, buffer, instance_count)
	body.z_as_relative = false
	body.z_index = 3
	add_child(body)
	var nodes := {"body": body}
	if _visual_quality > 0:
		var decal_buffer := PackedFloat32Array(
			result.get("decal_buffer", PackedFloat32Array()))
		var decal_count := int(result.get("decal_instance_count", 0))
		if decal_count > 0 and decal_buffer.size() >= decal_count * 16:
			var decal := _make_multimesh_instance_buffer(
				"GroundDecal", _decal_mesh, _decal_material,
				decal_buffer, decal_count)
			decal.z_as_relative = false
			decal.z_index = 1
			add_child(decal)
			nodes["decal"] = decal
	if _visual_quality > 0 and not OS.has_feature("web"):
		var shadow := _make_multimesh_instance_buffer(
			"Shadow", _shadow_mesh, _shadow_material, buffer, instance_count)
		shadow.z_as_relative = false
		shadow.z_index = 2
		add_child(shadow)
		nodes["shadow"] = shadow
	_chunk_nodes[chunk_id] = nodes
	_chunk_instance_counts[chunk_id] = instance_count
	_diagnostics.chunk_rebuilds = int(_diagnostics.chunk_rebuilds) + 1
	_recount_instances()
	_apply_chunk_lod(chunk_id)
	if not _runtime_probe_logged:
		print("[building-visual] native_probe chunk=%d ok=%s instances=%d body=%d nodes=%d" % [
			chunk_id, bool(result.get("ok", false)), instance_count,
			int(_diagnostics.body_instances), nodes.size()])
		_runtime_probe_logged = true


func _build_cell_specs(cell: int, row: Dictionary) -> Array[Dictionary]:
	var aggregate := _aggregate_archetypes(row)
	var counts: PackedInt64Array = aggregate.counts
	var profile_counts: PackedInt64Array = aggregate.profile_counts
	var total := int(aggregate.total)
	if total <= 0:
		return []
	var density := _settlement_density(total)
	# Rounding rather than ceiling keeps the compound count from ever exceeding
	# the authoritative total, so a two-building hamlet cannot draw three.
	var raw := roundi(COMPOUND_COUNT_MAX * density)
	var quota := _allocate_quotas(counts, clampi(raw, 1, NEAR_CAP[_visual_quality]))
	var scale := _hex_size * lerpf(COMPOUND_SCALE_MIN, COMPOUND_SCALE_MAX, density)
	var spread := lerpf(COMPOUND_SPREAD_MIN, COMPOUND_SPREAD_MAX, density)
	var out: Array[Dictionary] = []
	var accepted: Array[Vector2] = []
	var slot_total := 0
	for archetype in ARCHETYPE_COUNT:
		slot_total += quota[archetype]
	var rank := 0
	for archetype in ARCHETYPE_COUNT:
		var profile_assigned := PackedInt32Array()
		profile_assigned.resize(VISUAL_PROFILE_COUNT)
		profile_assigned.fill(0)
		for local_rank in quota[archetype]:
			var visual_profile := _select_visual_profile(
				archetype, profile_counts, profile_assigned)
			profile_assigned[visual_profile] += 1
			# A lone building is the settlement anchor.  Additional compounds
			# use the deterministic ring candidates below.
			var offset := Vector2.ZERO if slot_total == 1 else \
				_best_candidate(cell, archetype, rank, accepted, spread)
			if not is_finite(offset.x):
				rank += 1
				continue
			accepted.append(offset)
			var count := int(counts[archetype])
			var seed := float(_stable_hash(cell, archetype, local_rank, 7) & 0xFFFF) / 65535.0
			# The foundation must remain at the bottom of the sprite. Buildings
			# use one authored orientation; only stable positions and category
			# modules vary.
			var angle_step := 0.0
			var style := clampi(int(row.observed_era_index), 0, 10) * 6 + archetype
			out.append({
				"transform": Transform2D(angle_step, Vector2(scale, scale), 0.0,
					_cell_world_position(cell) + offset),
				"custom": Color(float(style) / 65.0, seed,
					float(cell) / float(maxi(1, _map.cell_count() - 1)),
					float(visual_profile) / float(VISUAL_PROFILE_COUNT - 1)),
				"importance": count * 16 - local_rank,
				"stable_order": archetype * 32 + local_rank,
			})
			rank += 1
	return out


## Maps an authoritative per-cell building total onto [0, 1]. Every visual
## dimension of a settlement reads from this one value so count, size and spread
## cannot disagree about how big the place is.
static func _settlement_density(total: int) -> float:
	if total <= 0:
		return 0.0
	var span := log(1.0 + DENSITY_LADDER_TOP) / log(2.0)
	return clampf(log(1.0 + float(total)) / log(2.0) / span, 0.0, 1.0)


func _aggregate_archetypes(row: Dictionary) -> Dictionary:
	var counts := PackedInt64Array()
	counts.resize(ARCHETYPE_COUNT)
	counts.fill(0)
	var profile_counts := PackedInt64Array()
	profile_counts.resize(ARCHETYPE_COUNT * VISUAL_PROFILE_COUNT)
	profile_counts.fill(0)
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
		var profile := clampi(int(_type_to_visual_profile[type_idx]),
			0, VISUAL_PROFILE_COUNT - 1)
		profile_counts[archetype * VISUAL_PROFILE_COUNT + profile] += source_counts[i]
		total += int(source_counts[i])
	return {"counts": counts, "profile_counts": profile_counts, "total": total}


func _select_visual_profile(archetype: int, counts: PackedInt64Array,
		assigned: PackedInt32Array) -> int:
	var selected := 0
	var best_score := -1.0
	for profile in VISUAL_PROFILE_COUNT:
		var count := int(counts[archetype * VISUAL_PROFILE_COUNT + profile])
		if count <= 0:
			continue
		var score := log(float(1 + count)) / log(2.0) / float(assigned[profile] + 1)
		if score > best_score:
			best_score = score
			selected = profile
	return selected


func _allocate_quotas(counts: PackedInt64Array, slots: int) -> PackedInt32Array:
	var quota := PackedInt32Array()
	quota.resize(ARCHETYPE_COUNT)
	quota.fill(0)
	var active: Array[int] = []
	for a in ARCHETYPE_COUNT:
		if counts[a] > 0:
			active.append(a)
	active.sort_custom(func(a, b):
		return counts[a] > counts[b] if counts[a] != counts[b] else a < b)
	var remaining := slots
	for a in active:
		if remaining <= 0:
			break
		quota[a] = 1
		remaining -= 1
	if remaining <= 0:
		return quota
	var weights := PackedFloat32Array()
	weights.resize(ARCHETYPE_COUNT)
	var weight_total := 0.0
	for a in active:
		weights[a] = log(float(1 + counts[a])) / log(2.0)
		weight_total += weights[a]
	var remainders: Array[Dictionary] = []
	var assigned := 0
	for a in active:
		var exact := float(remaining) * weights[a] / maxf(weight_total, 0.001)
		var whole := floori(exact)
		quota[a] += whole
		assigned += whole
		remainders.append({"a": a, "r": exact - whole})
	remainders.sort_custom(func(a, b):
		return float(a.r) > float(b.r) if not is_equal_approx(a.r, b.r) \
			else int(a.a) < int(b.a))
	for i in range(remaining - assigned):
		quota[int(remainders[i % remainders.size()].a)] += 1
	return quota


func _best_candidate(cell: int, archetype: int, rank: int,
		accepted: Array[Vector2], spread_scale: float) -> Vector2:
	var best := Vector2.ZERO
	var best_score := -INF
	var radial_min := 0.08
	var radial_max := 0.34
	if archetype in [0, 1]:
		radial_min = 0.24
		radial_max = 0.54
	elif archetype in [2, 3]:
		radial_min = 0.16
		radial_max = 0.46
	elif archetype in [4, 5]:
		radial_min = 0.08
		radial_max = 0.34
	for candidate in 8:
		var h := _stable_hash(cell, archetype, rank, candidate)
		var angle := float(h % 6) * PI / 3.0 + float((h >> 5) % 7 - 3) * 0.025
		var radius := lerpf(radial_min, radial_max,
			float((h >> 9) & 0xFFFF) / 65535.0) * _hex_size * spread_scale
		var point := Vector2(cos(angle), sin(angle)) * radius
		var world_point := _cell_world_position(cell) + point
		if _world != null and not _world.flow_buffer.is_empty() \
				and _world.sample_flow(world_point) >= RIVER_CLEAR_THRESHOLD:
			continue
		var nearest := _hex_size
		for prior in accepted:
			nearest = minf(nearest, point.distance_to(prior))
		if nearest > best_score:
			best_score = nearest
			best = point
	return best if best_score > -INF else Vector2(INF, INF)


func _enqueue_chunk_rebuild(chunk_id: int) -> void:
	if chunk_id < 0 or _dirty_chunk_set.has(chunk_id):
		return
	_dirty_chunk_set[chunk_id] = true
	_dirty_chunk_queue.append(chunk_id)
	_diagnostics.queued_chunks = _dirty_chunk_queue.size()


func _process_chunk_rebuild_queue() -> void:
	if _dirty_chunk_queue.is_empty():
		return
	_sync_upload_frame += 1
	if OS.has_feature("web") and _visual_quality == 0 and (_sync_upload_frame & 1) != 0:
		return
	var best_index := -1
	var best_distance := INF
	for i in _dirty_chunk_queue.size():
		var chunk_id := _dirty_chunk_queue[i]
		if not _chunk_nodes.has(chunk_id) and not _chunk_in_prefetch(chunk_id):
			continue
		var distance := _chunk_center(chunk_id).distance_squared_to(_camera_center)
		if distance < best_distance:
			best_distance = distance
			best_index = i
	if best_index < 0:
		_dirty_chunk_queue.clear()
		_dirty_chunk_set.clear()
		_diagnostics.queued_chunks = 0
		return
	var selected := _dirty_chunk_queue[best_index]
	_dirty_chunk_queue.remove_at(best_index)
	_dirty_chunk_set.erase(selected)
	_diagnostics.queued_chunks = _dirty_chunk_queue.size()
	_rebuild_chunk(selected)


func _record_chunk_bake_time(begin_usec: int) -> void:
	var elapsed := float(Time.get_ticks_usec() - begin_usec) / 1000.0
	_diagnostics.last_chunk_bake_ms = elapsed
	_diagnostics.max_chunk_bake_ms = maxf(
		float(_diagnostics.max_chunk_bake_ms), elapsed)
	if elapsed > float(_diagnostics.chunk_bake_perf_gate_ms):
		_diagnostics.bulk_encoder_required = true


func _is_water_cell(cell: int) -> bool:
	if _map == null or cell < 0 or cell >= _map.cell_count():
		return true
	if cell < _map.is_water_arr.size() and _map.is_water_arr[cell] != 0:
		return true
	if cell < _map.landform_arr.size():
		return LandformType.is_water(int(_map.landform_arr[cell]))
	return false


func _make_multimesh_instance(name: String, mesh: Mesh, material: Material,
		specs: Array[Dictionary], buffer := PackedFloat32Array()) -> MultiMeshInstance2D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = specs.size()
	if not specs.is_empty():
		mm.buffer = buffer if not buffer.is_empty() else _specs_to_multimesh_buffer(specs)
	var node := MultiMeshInstance2D.new()
	node.name = name
	node.multimesh = mm
	node.material = material
	return node


func _make_multimesh_instance_buffer(name: String, mesh: Mesh, material: Material,
		buffer: PackedFloat32Array, instance_count: int) -> MultiMeshInstance2D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = maxi(0, instance_count)
	if mm.instance_count > 0:
		mm.buffer = buffer
	var node := MultiMeshInstance2D.new()
	node.name = name
	node.multimesh = mm
	node.material = material
	return node


## MultiMesh 2D layout is transform(8) + color(4) + custom(4). Constructing one
## packed buffer avoids thousands of Object calls and lets Body/Shadow share the
## exact same immutable transform payload.
static func _specs_to_multimesh_buffer(specs: Array[Dictionary]) -> PackedFloat32Array:
	var buffer := PackedFloat32Array()
	buffer.resize(specs.size() * 16)
	for i in specs.size():
		var transform: Transform2D = specs[i].transform
		var custom: Color = specs[i].custom
		var base := i * 16
		buffer[base + 0] = transform.x.x
		buffer[base + 1] = transform.y.x
		buffer[base + 2] = 0.0
		buffer[base + 3] = transform.origin.x
		buffer[base + 4] = transform.x.y
		buffer[base + 5] = transform.y.y
		buffer[base + 6] = 0.0
		buffer[base + 7] = transform.origin.y
		buffer[base + 8] = 1.0
		buffer[base + 9] = 1.0
		buffer[base + 10] = 1.0
		buffer[base + 11] = 1.0
		buffer[base + 12] = custom.r
		buffer[base + 13] = custom.g
		buffer[base + 14] = custom.b
		buffer[base + 15] = custom.a
	return buffer


func _select_decal_specs(specs: Array[Dictionary]) -> Array[Dictionary]:
	var selected: Array[Dictionary] = []
	var seen := {}
	for spec in specs:
		var custom: Color = spec.custom
		var style := clampi(roundi(custom.r * 65.0), 0, 65)
		var cell := clampi(roundi(custom.b * float(maxi(1, _map.cell_count() - 1))),
			0, maxi(0, _map.cell_count() - 1))
		var archetype := style % ARCHETYPE_COUNT
		var key := cell if _visual_quality == 1 else cell * ARCHETYPE_COUNT + archetype
		if seen.has(key):
			continue
		seen[key] = true
		selected.append(spec)
	return selected


func _refresh_lod() -> void:
	for raw_chunk in _chunk_nodes:
		_apply_chunk_lod(int(raw_chunk))


func _apply_chunk_lod(chunk_id: int) -> void:
	if not _chunk_nodes.has(chunk_id):
		return
	var fraction := 1.0
	if _camera_zoom < 0.82:
		fraction = 0.28
	elif _camera_zoom < 1.30:
		fraction = 0.62
	var count := int(_chunk_instance_counts.get(chunk_id, 0))
	var visible_count := clampi(ceili(float(count) * fraction), 0, count)
	var nodes: Dictionary = _chunk_nodes[chunk_id]
	var body = nodes.get("body")
	if body is MultiMeshInstance2D and body.multimesh != null:
		body.multimesh.visible_instance_count = visible_count
	var shadow = nodes.get("shadow")
	if shadow is MultiMeshInstance2D and shadow.multimesh != null:
		var shadow_fraction := 0.5 if _visual_quality == 1 else 1.0
		shadow.multimesh.visible_instance_count = mini(
			visible_count, ceili(float(count) * shadow_fraction))


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
	var daylight_materials := [_body_material, _shadow_material, _macro_material]
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
	if _body_material != null:
		_body_material.set_shader_parameter("camera_zoom", _camera_zoom)
		_body_material.set_shader_parameter("visual_quality", _visual_quality)
		_body_material.set_shader_parameter(
			"compound_visual_scale", COMPOUND_VISUAL_SCALE)
	if _decal_material != null:
		_decal_material.set_shader_parameter("camera_zoom", _camera_zoom)
		_decal_material.set_shader_parameter(
			"compound_visual_scale", COMPOUND_VISUAL_SCALE)
	if _shadow_material != null:
		_shadow_material.set_shader_parameter("camera_zoom", _camera_zoom)
		_shadow_material.set_shader_parameter(
			"compound_visual_scale", COMPOUND_VISUAL_SCALE)
		_shadow_material.set_shader_parameter("shadow_strength",
			0.0 if _visual_quality == 0 or OS.has_feature("web") else
			(0.22 if _visual_quality == 1 else 0.30))
	if _macro_material != null:
		_macro_material.set_shader_parameter("camera_zoom", _camera_zoom)
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


func _chunk_id_for_cell(cell: int) -> int:
	var x := cell % _map.width
	var y := cell / _map.width
	return (y / CHUNK_SIZE) * ceili(float(_map.width) / CHUNK_SIZE) + x / CHUNK_SIZE


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
	_dirty_chunk_queue.clear()
	_dirty_chunk_set.clear()
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


static func _make_shadow_mesh() -> ArrayMesh:
	var vertices := PackedVector2Array([
		Vector2(-0.58, 0.05), Vector2(0.58, 0.05),
		Vector2(0.76, 0.88), Vector2(-0.36, 0.88),
	])
	var uv := PackedVector2Array([
		Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func _make_decal_mesh() -> ArrayMesh:
	# Tight six-sided footprint avoids the transparent overdraw of a large quad.
	var vertices := PackedVector2Array([
		Vector2(-0.72, -0.10), Vector2(-0.34, -0.46),
		Vector2(0.48, -0.42), Vector2(0.76, -0.04),
		Vector2(0.38, 0.34), Vector2(-0.46, 0.30),
	])
	var uv := PackedVector2Array([
		Vector2(0.0, 0.42), Vector2(0.24, 0.0), Vector2(0.78, 0.04),
		Vector2(1.0, 0.46), Vector2(0.74, 1.0), Vector2(0.18, 0.96),
	])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([
		0, 1, 2, 0, 2, 3, 0, 3, 4, 0, 4, 5])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _configure_style_resources() -> void:
	# The authoritative era/archetype pair addresses one row. Eight texels keep
	# the ABI stable as atlas art replaces the generated fallback over time.
	var style_image := Image.create(8, STYLE_COUNT, false, Image.FORMAT_RGBAH)
	var atlas_size := 512 if OS.has_feature("web") else 1024
	var material_image := Image.create(atlas_size, atlas_size, false, Image.FORMAT_RGBA8)
	var mask_image := Image.create(atlas_size, atlas_size, false, Image.FORMAT_RGBA8)
	for style in STYLE_COUNT:
		var era := style / ARCHETYPE_COUNT
		var archetype := style % ARCHETYPE_COUNT
		var era_t := float(era) / 10.0
		var roof_pitch := lerpf(1.24, 0.72, minf(1.0, float(era) / 8.0))
		if era >= 9:
			roof_pitch = lerpf(0.78, 0.90, float(era - 9))
		var wall_height := lerpf(0.72, 1.18, era_t)
		var annex := clampf(0.34 + archetype * 0.07 + era_t * 0.18, 0.0, 1.0)
		var facility := clampf(0.18 + float(archetype in [1, 2, 3]) * 0.40
			+ era_t * 0.22, 0.0, 1.0)
		var palette := _style_palette(era, archetype)
		var snow_retention := clampf(0.88 - era_t * 0.18
			- float(archetype == 3) * 0.18, 0.42, 0.94)
		style_image.set_pixel(0, style, Color(roof_pitch, wall_height, annex, facility))
		style_image.set_pixel(1, style, Color(palette.r, palette.g, palette.b, snow_retention))
		style_image.set_pixel(2, style, Color(
			0.15 + era_t * 0.18, 0.12 + float(archetype in [2, 3]) * 0.30,
			0.08 + float(era >= 7) * 0.34, 0.62 + era_t * 0.30))
		for parameter_texel in range(3, 8):
			style_image.set_pixel(parameter_texel, style, Color(0.0, 0.0, 0.0, 0.0))
	var tiles_x := 6
	var tiles_y := 11
	var tile_width := atlas_size / tiles_x
	var tile_height := atlas_size / tiles_y
	# Fill by authored style tile rather than setting two million pixels in
	# GDScript. This cold setup remains sub-frame on production maps.
	for era in tiles_y:
		for archetype in tiles_x:
			var rect := Rect2i(archetype * tile_width, era * tile_height,
				tile_width, tile_height)
			var palette := _style_palette(era, archetype)
			material_image.fill_rect(rect, palette)
			var mask := Color(0.88, 0.82 if era >= 6 else 0.34,
				0.80 if era >= 7 and archetype in [3, 4] else 0.18, 1.0)
			mask_image.fill_rect(rect, mask)
			# Low-frequency courses/panels provide material scale without shader noise.
			for stripe in range(2, 9, 2):
				var stripe_y := rect.position.y + stripe * rect.size.y / 10
				material_image.fill_rect(Rect2i(rect.position.x + 4, stripe_y,
					maxi(1, rect.size.x - 8), maxi(1, rect.size.y / 42)),
					palette.darkened(0.08 if era < 6 else 0.05))
	material_image.generate_mipmaps()
	mask_image.generate_mipmaps()
	_style_texture = ImageTexture.create_from_image(style_image)
	_material_atlas_texture = ImageTexture.create_from_image(material_image)
	_material_mask_texture = ImageTexture.create_from_image(mask_image)
	if _body_material != null:
		_body_material.set_shader_parameter("building_style_lut", _style_texture)
		_body_material.set_shader_parameter("building_material_atlas", _material_atlas_texture)
		_body_material.set_shader_parameter("building_material_mask_atlas", _material_mask_texture)
	_configure_authored_atlas()


## The authored atlas replaces the procedural glyph with flat top-down artwork.
## It fails closed to the procedural body so a missing/soft-failed asset can
## never blank out buildings during play.
func _configure_authored_atlas() -> void:
	var audit := _load_authored_atlas()
	_authored_atlas_ready = bool(audit.get("ok", false))
	_diagnostics.authored_atlas = _authored_atlas_ready
	_diagnostics.authored_atlas_reason = String(audit.get("reason", ""))
	_diagnostics.authored_atlas_tiles = int(audit.get("tiles", 0))
	if _body_material == null:
		return
	_body_material.set_shader_parameter("use_authored_atlas", _authored_atlas_ready)
	if not _authored_atlas_ready:
		push_warning("[building-visual] authored atlas unavailable (%s); using procedural body"
			% _diagnostics.authored_atlas_reason)
		return
	_body_material.set_shader_parameter("atlas_grid", _authored_atlas_grid)
	_body_material.set_shader_parameter("atlas_tile_size", _authored_atlas_tile_size)
	_body_material.set_shader_parameter("building_material_atlas", _material_atlas_texture)
	_body_material.set_shader_parameter("building_material_mask_atlas", _material_mask_texture)


func _load_authored_atlas() -> Dictionary:
	if not FileAccess.file_exists(VISUAL_MANIFEST_PATH):
		return {"ok": false, "reason": "manifest_missing"}
	var file := FileAccess.open(VISUAL_MANIFEST_PATH, FileAccess.READ)
	if file == null:
		return {"ok": false, "reason": "manifest_unreadable"}
	var parsed = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		return {"ok": false, "reason": "manifest_invalid"}
	var manifest := parsed as Dictionary
	var columns := int(manifest.get("atlas_columns", 0))
	var rows := int(manifest.get("atlas_rows", 0))
	var variants := int(manifest.get("variant_count", 0))
	var bands := (manifest.get("era_bands", []) as Array).size()
	var tiles := (manifest.get("tiles", []) as Array).size()
	if variants != VISUAL_PROFILE_COUNT or bands != ART_ERA_BAND_COUNT \
			or columns <= 0 or rows <= 0 \
			or tiles != bands * ARCHETYPE_COUNT * variants \
			or tiles != columns * rows:
		return {"ok": false, "reason": "manifest_shape_invalid"}
	# A baked shadow in the artwork would fight the analytic shadow pass.
	if bool(manifest.get("baked_shadow", true)):
		return {"ok": false, "reason": "authored_tiles_contain_baked_shadow"}
	var era_map := PackedInt32Array(manifest.get("runtime_era_to_band", PackedInt32Array()))
	if era_map.size() != 11:
		return {"ok": false, "reason": "runtime_era_map_invalid"}
	for era in era_map.size():
		if era_map[era] != _art_era_band(era):
			return {"ok": false, "reason": "runtime_era_map_disagrees_with_shader"}
	var albedo := ResourceLoader.load(VISUAL_ALBEDO_PATH, "Texture2D") as Texture2D
	var surface := ResourceLoader.load(VISUAL_SURFACE_PATH, "Texture2D") as Texture2D
	if albedo == null or surface == null:
		return {"ok": false, "reason": "atlas_texture_missing"}
	var tile_size := int(manifest.get("tile_size", 0))
	var expected := Vector2i(columns * tile_size, rows * tile_size)
	if tile_size <= 0 or albedo.get_size() != Vector2(expected) \
			or surface.get_size() != Vector2(expected):
		return {"ok": false, "reason": "atlas_texture_size_mismatch"}
	_material_atlas_texture = albedo
	_material_mask_texture = surface
	_authored_atlas_grid = Vector2(columns, rows)
	_authored_atlas_tile_size = float(tile_size)
	return {"ok": true, "tiles": tiles}


## Runtime eras stay authoritative; this only maps one onto an authored art band.
## The breakpoints match `_style_palette` so the authored atlas and the
## procedural fallback agree on what each era reads as.
static func _art_era_band(era_index: int) -> int:
	var era := clampi(era_index, 0, 10)
	if era < 2:
		return 0
	if era < 6:
		return 1
	return 2 if era < 8 else 3


static func _style_palette(era: int, archetype: int) -> Color:
	var early := Color(0.43, 0.35, 0.25)
	var masonry := Color(0.52, 0.45, 0.36)
	var industrial := Color(0.42, 0.38, 0.35)
	var modern := Color(0.46, 0.50, 0.51)
	var base := early if era < 2 else masonry if era < 6 else industrial if era < 8 else modern
	var tint: Color = [
		Color(0.96, 0.92, 0.72), Color(0.76, 0.72, 0.67),
		Color(0.88, 0.74, 0.66), Color(0.68, 0.75, 0.78),
		Color(0.82, 0.82, 0.76), Color(0.87, 0.78, 0.64),
	][clampi(archetype, 0, 5)]
	return Color(base.r * tint.r, base.g * tint.g, base.b * tint.b, 1.0)


static func _make_compound_mesh() -> ArrayMesh:
	# A single tight quad keeps one body batch while the fragment shader draws
	# a legible top-down house icon.  Keeping the quad tight avoids the large
	# transparent billboards that made the former compound read as fragments.
	var vertices := PackedVector2Array([
		Vector2(-1.0, -1.0), Vector2(1.0, -1.0),
		Vector2(1.0, 1.0), Vector2(-1.0, 1.0),
	])
	var uv := PackedVector2Array([
		Vector2(0.0, 0.0), Vector2(1.0, 0.0),
		Vector2(1.0, 1.0), Vector2(0.0, 1.0),
	])
	var indices := PackedInt32Array([0, 1, 2, 0, 2, 3])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func _append_quad(vertices: PackedVector2Array, uv: PackedVector2Array,
		indices: PackedInt32Array, a: Vector2, b: Vector2, c: Vector2, d: Vector2,
		surface: float, module_id: float) -> void:
	var base := vertices.size()
	vertices.append_array(PackedVector2Array([a, b, c, d]))
	uv.append_array(PackedVector2Array([
		Vector2(surface, module_id), Vector2(surface, module_id),
		Vector2(surface, module_id), Vector2(surface, module_id)]))
	indices.append_array(PackedInt32Array([
		base, base + 1, base + 2, base, base + 2, base + 3]))


static func _floor_log2(value: int) -> int:
	var result := -1
	var current := maxi(0, value)
	while current > 0:
		current >>= 1
		result += 1
	return maxi(0, result)


static func _stable_hash(cell: int, archetype: int, rank: int, salt: int) -> int:
	var value := (cell * 1103515245 + archetype * 374761393 \
		+ rank * 668265263 + salt * 2246822519) & 0x7FFFFFFF
	value = ((value ^ (value >> 13)) * 1274126177) & 0x7FFFFFFF
	return value ^ (value >> 16)
