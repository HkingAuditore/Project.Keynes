class_name ForestCanopyLayer
extends Node2D

## Large-area chunked forest canopy & dynamic ground tree-shadow renderer.
##
## Owns per-chunk static coverage pages (80x80 with 8-texel halo), static
## coarse-merged (or baseline chunk-quad) ArrayMeshes, and localised R8 city
## footprint mask pages. Pure presentation: reads only opening static geography
## and player-known building intel snapshots.

const CanopyField = preload("res://scripts/rendering/forest/forest_canopy_field.gd")
const CanopyMesh = preload("res://scripts/rendering/forest/forest_canopy_mesh.gd")
const CityMask = preload("res://scripts/rendering/forest/forest_canopy_city_mask.gd")
const FogDrawBounds = preload("res://scripts/rendering/fog_draw_bounds.gd")

const CANOPY_SHADER := preload("res://shaders/forest_canopy.gdshader")
const SHADOW_SHADER := preload("res://shaders/forest_canopy_shadow.gdshader")

const ALBEDO_STRIP_PATH := "res://assets/textures/resource_art/forest_canopy_albedo_tiles.png"
const AUX_STRIP_PATH := "res://assets/textures/resource_art/forest_canopy_aux_tiles.png"
const TILE_SIZE := 512
const TILE_LAYERS := 3

const Z_BAND_CANOPY_SHADOW := 1
const Z_BAND_CANOPY := 3
const DEFAULT_MAX_BUILDS_PER_UPDATE := 4
const CANOPY_DETAIL_KINDS := [1, 3, 4]

var _field: CanopyField = null
var _city_mask: CityMask = null
var _shadow_root: Node2D = null
var _canopy_root: Node2D = null

var _albedo_array: Texture2DArray = null
var _aux_array: Texture2DArray = null

var _geometry_mode: int = CanopyMesh.MODE_COARSE_MERGED
var _max_builds_per_update: int = DEFAULT_MAX_BUILDS_PER_UPDATE
var _enabled: bool = true

var _hex_size: float = 32.0
var _wrap_period_x: float = 0.0
var _world_bounds: Rect2 = Rect2()

# Earth daylight, TOD, world lighting field & cloud shadow state mirrored onto chunk materials.
var _daylight_params: Dictionary = {
	"season_phase": 1.0,
	"day_phase": 0.25,
	"axial_tilt_rad": 0.41,
	"day_night_enabled": true,
	"tod_debug_sun_position_enabled": false,
	"tod_debug_sun_uv": Vector2(0.25, 0.5),
	"tod_debug_sun_height_scale": 1.0,
	"eternal_min_elevation_rad": 0.17453293,
	"eternal_max_hour_angle_rad": 1.22173048,
	"tod_sun_dir": Vector3(0.4, -0.7, 0.6),
	"tod_exposure": 1.0,
}
var _snow_amount: float = 0.0
var _world_lighting_tex: Texture2D = null
var _world_lighting_bound: bool = false
var _world_lighting_radiance_scale: float = 2.0
var _cloud_shadow_tex: Texture2D = null
var _cloud_shadow_bound: bool = false
var _cloud_shadow_strength: float = 0.48
var _cloud_shadow_wrap_origin_uv: float = 0.0
var _cloud_shadow_wrap_period_uv: float = 0.0
var _dyn_lut_tex: Texture2D = null
var _eco_lut_tex: Texture2D = null
var _enum_lut_tex: Texture2D = null
var _lut_dims: Vector2 = Vector2.ONE
var _cell_luts_bound: bool = false
var _normal_enabled: bool = true
var _ao_enabled: bool = true
var _shadow_enabled: bool = true

# chunk_key (Vector2i) -> Dictionary (cached entry; empty chunks recorded too).
var _chunks: Dictionary = {}
var _camera_rect: Rect2 = Rect2()
var _camera_initialized: bool = false

# Telemetry / performance counters (§8).
var _cold_builds: int = 0
var _cache_hits: int = 0
var _empty_cache_hits: int = 0
var _mesh_upload_bytes: int = 0
var _coverage_upload_bytes: int = 0
var _visible_canopy_batches: int = 0
var _visible_shadow_batches: int = 0
var _visible_tris: int = 0


static func is_replaced_canopy_profile(profile: Resource) -> bool:
	if profile == null or not ("detail_kind" in profile):
		return false
	return int(profile.detail_kind) in CANOPY_DETAIL_KINDS


func _ready() -> void:
	z_as_relative = false
	_ensure_roots()
	_ensure_tile_arrays()


func _process(delta: float) -> void:
	if not _enabled or _chunks.is_empty():
		return
	var t := float(Time.get_ticks_msec()) * 0.001
	for entry in _chunks.values():
		var mat: ShaderMaterial = entry.get("canopy_mat", null)
		if mat != null:
			mat.set_shader_parameter("wind_time", t)


func configure_world(map: MapData, world: WorldData, hex_size: float, wrap_period_x: float = 0.0) -> bool:
	clear_world()
	_ensure_roots()
	_ensure_tile_arrays()
	if map == null or map.cell_count() == 0:
		return false
	_hex_size = maxf(hex_size, 1.0)
	_wrap_period_x = maxf(wrap_period_x, 0.0)
	_field = CanopyField.new()
	if not _field.configure(map, world, _hex_size, _wrap_period_x):
		_field = null
		return false
	_world_bounds = _field.world_bounds()
	_city_mask = CityMask.new()
	_city_mask.configure(_field, map, _hex_size)
	if _camera_initialized:
		_update_visible_chunks()
	return true


func clear_world() -> void:
	for entry in _chunks.values():
		_free_chunk_nodes(entry)
	_chunks.clear()
	_field = null
	_city_mask = null
	_cold_builds = 0
	_cache_hits = 0
	_empty_cache_hits = 0
	_mesh_upload_bytes = 0
	_coverage_upload_bytes = 0
	_visible_canopy_batches = 0
	_visible_shadow_batches = 0
	_visible_tris = 0


func set_enabled(value: bool) -> void:
	_enabled = value
	visible = value


func set_geometry_mode(mode: int) -> void:
	var clamped := CanopyMesh.MODE_CHUNK_QUAD if mode == CanopyMesh.MODE_CHUNK_QUAD else CanopyMesh.MODE_COARSE_MERGED
	if clamped == _geometry_mode:
		return
	_geometry_mode = clamped
	# Rebuild meshes for existing cached chunks using the same coverage pages.
	for key in _chunks.keys():
		var entry: Dictionary = _chunks[key]
		if bool(entry.get("empty", true)):
			continue
		var built := CanopyMesh.build_from_coverage(
			entry["rect"], entry["coverage_bytes"],
			CanopyField.PAGE_TEXELS, CanopyField.HALO_TEXELS,
			_geometry_mode, 0.0
		)
		entry["tri_count"] = int(built.get("tri_count", 0))
		entry["quad_count"] = int(built.get("quad_count", 0))
		entry["covered_area_ratio"] = float(built.get("covered_area_ratio", 0.0))
		var mesh: ArrayMesh = built.get("mesh", null)
		entry["canopy_mesh"] = mesh
		_mesh_upload_bytes += int(built.get("quad_count", 0)) * (4 * 16 + 6 * 4)
		for node in entry.get("canopy_nodes", []):
			if is_instance_valid(node):
				node.mesh = mesh
	_recompute_visible_stats()


func set_max_builds_per_update(limit: int) -> void:
	_max_builds_per_update = maxi(limit, 0)


func set_camera_view(world_rect: Rect2, _center: Vector2, _zoom: float) -> void:
	_camera_rect = world_rect
	_camera_initialized = world_rect.has_area()
	if _enabled and _field != null and _camera_initialized:
		_update_visible_chunks()


func set_settlement_core_buckets(buckets: PackedByteArray, changed_cells: PackedInt32Array = PackedInt32Array()) -> Array[Vector2i]:
	if _city_mask == null:
		return []
	var updated := _city_mask.set_core_buckets(buckets, changed_cells)
	# Rebind updated city mask textures onto affected chunks (zero mesh uploads).
	for key in updated:
		if not _chunks.has(key):
			continue
		var entry: Dictionary = _chunks[key]
		var page := _city_mask.get_or_create_page(key)
		var tex: Texture2D = page.get("texture", null)
		var cmat: ShaderMaterial = entry.get("canopy_mat", null)
		if cmat != null:
			cmat.set_shader_parameter("city_mask_tex", tex)
		var smat: ShaderMaterial = entry.get("shadow_mat", null)
		if smat != null:
			smat.set_shader_parameter("city_mask_tex", tex)
	return updated


func set_daylight_parameters(params: Dictionary) -> void:
	for k in params.keys():
		_daylight_params[k] = params[k]
	_push_lighting_to_all_chunks()


func sync_shared_textures_from_terrain_material(terrain_mat: ShaderMaterial) -> void:
	if terrain_mat == null:
		return
	var wl_tex = terrain_mat.get_shader_parameter("world_lighting_tex")
	var wl_bound = terrain_mat.get_shader_parameter("world_lighting_tex_bound")
	var wl_scale = terrain_mat.get_shader_parameter("world_lighting_radiance_scale")
	_world_lighting_tex = wl_tex if wl_tex is Texture2D else null
	_world_lighting_bound = (wl_bound is bool and wl_bound) and _world_lighting_tex != null
	if wl_scale is float or wl_scale is int:
		_world_lighting_radiance_scale = float(wl_scale)

	var cs_tex = terrain_mat.get_shader_parameter("cloud_shadow_tex")
	var cs_bound = terrain_mat.get_shader_parameter("cloud_shadow_field_bound")
	var cs_str = terrain_mat.get_shader_parameter("cloud_shadow_strength")
	var cs_org = terrain_mat.get_shader_parameter("cloud_shadow_wrap_origin_uv")
	var cs_per = terrain_mat.get_shader_parameter("cloud_shadow_wrap_period_uv")
	_cloud_shadow_tex = cs_tex if cs_tex is Texture2D else null
	_cloud_shadow_bound = (cs_bound is bool and cs_bound) and _cloud_shadow_tex != null
	if cs_str is float or cs_str is int:
		_cloud_shadow_strength = float(cs_str)
	if cs_org is float or cs_org is int:
		_cloud_shadow_wrap_origin_uv = float(cs_org)
	if cs_per is float or cs_per is int:
		_cloud_shadow_wrap_period_uv = float(cs_per)

	var dyn_t = terrain_mat.get_shader_parameter("dyn_lut")
	var eco_t = terrain_mat.get_shader_parameter("eco_lut")
	var enum_t = terrain_mat.get_shader_parameter("enum_lut")
	var ldims = terrain_mat.get_shader_parameter("lut_dims")
	_dyn_lut_tex = dyn_t if dyn_t is Texture2D else null
	_eco_lut_tex = eco_t if eco_t is Texture2D else null
	_enum_lut_tex = enum_t if enum_t is Texture2D else null
	if ldims is Vector2 and ldims.x > 0.5 and ldims.y > 0.5:
		_lut_dims = ldims
	_cell_luts_bound = _dyn_lut_tex != null and _eco_lut_tex != null and _enum_lut_tex != null
	_push_lighting_to_all_chunks()


func set_lighting_state(
		sun_dir: Vector3,
		_sun_color: Color,
		_ambient_color: Color,
		_local_day: float,
		exposure: float,
		season_phase: float,
		snow_amount: float = 0.0,
		_cloud_visibility: float = 1.0) -> void:
	_daylight_params["tod_sun_dir"] = sun_dir.normalized() if sun_dir.length_squared() > 0.0001 else Vector3(0.0, 0.0, 1.0)
	_daylight_params["tod_exposure"] = maxf(exposure, 0.01)
	_daylight_params["season_phase"] = season_phase
	_snow_amount = clampf(snow_amount, 0.0, 1.0)
	_push_lighting_to_all_chunks()


func set_debug_toggles(normal_enabled: bool, ao_enabled: bool, shadow_enabled: bool) -> void:
	_normal_enabled = normal_enabled
	_ao_enabled = ao_enabled
	_shadow_enabled = shadow_enabled
	_push_lighting_to_all_chunks()
	_recompute_visible_stats()


func evict_chunk(chunk_key: Vector2i) -> void:
	if _chunks.has(chunk_key):
		_free_chunk_nodes(_chunks[chunk_key])
		_chunks.erase(chunk_key)
	if _city_mask != null:
		_city_mask.evict_page(chunk_key)


func ensure_chunk_built(chunk_key: Vector2i) -> Dictionary:
	if _field == null:
		return {}
	if _chunks.has(chunk_key):
		var existing: Dictionary = _chunks[chunk_key]
		_cache_hits += 1
		if bool(existing.get("empty", true)):
			_empty_cache_hits += 1
		return existing
	return _build_chunk(chunk_key)


func diagnostics() -> Dictionary:
	var empty_count := 0
	var total_tris := 0
	var area_sum := 0.0
	var non_empty_count := 0
	for entry in _chunks.values():
		if bool(entry.get("empty", true)):
			empty_count += 1
		else:
			non_empty_count += 1
			total_tris += int(entry.get("tri_count", 0))
			area_sum += float(entry.get("covered_area_ratio", 0.0))
	return {
		"enabled": _enabled,
		"geometry_mode": "chunk_quad" if _geometry_mode == CanopyMesh.MODE_CHUNK_QUAD else "coarse_merged",
		"resident_chunks": _chunks.size(),
		"non_empty_chunks": non_empty_count,
		"empty_chunks": empty_count,
		"visible_canopy_batches": _visible_canopy_batches,
		"visible_shadow_batches": _visible_shadow_batches,
		"visible_tris": _visible_tris,
		"cached_total_tris": total_tris,
		"mean_covered_area_ratio": area_sum / float(maxi(non_empty_count, 1)),
		"cold_builds": _cold_builds,
		"cache_hits": _cache_hits,
		"empty_cache_hits": _empty_cache_hits,
		"mesh_upload_bytes": _mesh_upload_bytes,
		"coverage_upload_bytes": _coverage_upload_bytes,
		"city_mask": _city_mask.diagnostics() if _city_mask != null else {},
		"tiles_loaded": _albedo_array != null and _aux_array != null,
	}


func _update_visible_chunks() -> void:
	if _field == null:
		return
	var chunk_size := _field.chunk_world_size()
	var grid := _field.chunk_grid_dimensions()
	var bounds := _field.world_bounds()
	var shadow_margin := _hex_size * 2.5
	var query := _camera_rect.grow(shadow_margin)

	var cy0 := clampi(int(floor((query.position.y - bounds.position.y) / chunk_size)), 0, grid.y - 1)
	var cy1 := clampi(int(floor((query.end.y - bounds.position.y) / chunk_size)), 0, grid.y - 1)
	var cx0 := int(floor((query.position.x - bounds.position.x) / chunk_size))
	var cx1 := int(floor((query.end.x - bounds.position.x) / chunk_size))
	if _wrap_period_x <= 0.001:
		cx0 = clampi(cx0, 0, grid.x - 1)
		cx1 = clampi(cx1, 0, grid.x - 1)

	var visible_keys := {}
	var builds_this_frame := 0
	for cy in range(cy0, cy1 + 1):
		for cx in range(cx0, cx1 + 1):
			var norm_cx := posmod(cx, grid.x) if _wrap_period_x > 0.001 else cx
			var key := Vector2i(norm_cx, cy)
			if visible_keys.has(key):
				continue
			visible_keys[key] = true
			if _chunks.has(key):
				_cache_hits += 1
				if bool(_chunks[key].get("empty", true)):
					_empty_cache_hits += 1
			else:
				if _max_builds_per_update == 0 or builds_this_frame < _max_builds_per_update:
					_build_chunk(key)
					builds_this_frame += 1

	for key in _chunks.keys():
		var is_vis := visible_keys.has(key)
		var entry: Dictionary = _chunks[key]
		entry["visible"] = is_vis
		for node in entry.get("canopy_nodes", []):
			if is_instance_valid(node):
				node.visible = is_vis
		for node in entry.get("shadow_nodes", []):
			if is_instance_valid(node):
				node.visible = is_vis and _shadow_enabled

	_recompute_visible_stats()


func _build_chunk(chunk_key: Vector2i) -> Dictionary:
	_cold_builds += 1
	var baked := _field.bake_chunk_coverage(chunk_key.x, chunk_key.y)
	var has_forest := bool(baked.get("has_forest", false))
	var has_halo := bool(baked.get("has_halo_forest", false))

	if not has_forest and not has_halo:
		var empty_entry := {
			"chunk": chunk_key,
			"rect": baked["rect"],
			"empty": true,
			"visible": false,
			"tri_count": 0,
			"quad_count": 0,
			"covered_area_ratio": 0.0,
			"canopy_nodes": [],
			"shadow_nodes": [],
		}
		_chunks[chunk_key] = empty_entry
		return empty_entry

	var cov_img: Image = baked["image"]
	var cov_tex := ImageTexture.create_from_image(cov_img)
	var meta_img: Image = baked["meta_image"]
	var meta_tex := ImageTexture.create_from_image(meta_img)
	_coverage_upload_bytes += baked["bytes"].size() + baked["meta_bytes"].size()
	var city_page := _city_mask.get_or_create_page(chunk_key)
	var city_tex: Texture2D = city_page.get("texture", null)

	var built := CanopyMesh.build_from_coverage(
		baked["rect"], baked["bytes"],
		CanopyField.PAGE_TEXELS, CanopyField.HALO_TEXELS,
		_geometry_mode, 0.0
	)
	var canopy_mesh: ArrayMesh = built.get("mesh", null)
	if canopy_mesh != null:
		_mesh_upload_bytes += int(built.get("quad_count", 0)) * (4 * 16 + 6 * 4)

	var canopy_mat := _create_canopy_material(cov_tex, city_tex, meta_tex)
	var shadow_mat := _create_shadow_material(cov_tex, city_tex, meta_tex)
	var shadow_mesh := CanopyMesh.build_shadow_receiver_quad(
		baked["rect"], CanopyField.PAGE_TEXELS, CanopyField.HALO_TEXELS
	)

	var offsets: Array[float] = [0.0]
	if _wrap_period_x > 0.001:
		offsets = [-_wrap_period_x, 0.0, _wrap_period_x]

	var canopy_nodes: Array = []
	var shadow_nodes: Array = []
	for off_x in offsets:
		if canopy_mesh != null:
			var cn := MeshInstance2D.new()
			cn.mesh = canopy_mesh
			cn.material = canopy_mat
			cn.position = Vector2(off_x, 0.0)
			cn.z_as_relative = true
			cn.set_meta(FogDrawBounds.REST_RECT, baked["rect"])
			_canopy_root.add_child(cn)
			canopy_nodes.append(cn)
		var sn := MeshInstance2D.new()
		sn.mesh = shadow_mesh
		sn.material = shadow_mat
		sn.position = Vector2(off_x, 0.0)
		sn.z_as_relative = true
		sn.set_meta(FogDrawBounds.REST_RECT, baked["rect"])
		_shadow_root.add_child(sn)
		shadow_nodes.append(sn)

	var entry := {
		"chunk": chunk_key,
		"rect": baked["rect"],
		"empty": not has_forest,
		"has_shadow_receiver": true,
		"visible": true,
		"coverage_bytes": baked["bytes"],
		"coverage_tex": cov_tex,
		"canopy_mesh": canopy_mesh,
		"shadow_mesh": shadow_mesh,
		"canopy_mat": canopy_mat,
		"shadow_mat": shadow_mat,
		"canopy_nodes": canopy_nodes,
		"shadow_nodes": shadow_nodes,
		"tri_count": int(built.get("tri_count", 0)),
		"quad_count": int(built.get("quad_count", 0)),
		"covered_area_ratio": float(built.get("covered_area_ratio", 0.0)),
	}
	_chunks[chunk_key] = entry
	return entry


func _create_canopy_material(cov_tex: Texture2D, city_tex: Texture2D, meta_tex: Texture2D) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = CANOPY_SHADER
	mat.set_shader_parameter("coverage_tex", cov_tex)
	mat.set_shader_parameter("city_mask_tex", city_tex)
	mat.set_shader_parameter("cell_meta_tex", meta_tex)
	if _albedo_array != null:
		mat.set_shader_parameter("canopy_albedo_tiles", _albedo_array)
	if _aux_array != null:
		mat.set_shader_parameter("canopy_aux_tiles", _aux_array)
	mat.set_shader_parameter("hex_size", _hex_size)
	mat.set_shader_parameter("world_origin", _world_bounds.position)
	mat.set_shader_parameter("world_size", _world_bounds.size)
	mat.set_shader_parameter("wrap_origin_x", _world_bounds.position.x)
	mat.set_shader_parameter("wrap_period_x", _wrap_period_x)
	_apply_lighting_to_canopy_mat(mat)
	return mat


func _create_shadow_material(cov_tex: Texture2D, city_tex: Texture2D, meta_tex: Texture2D) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = SHADOW_SHADER
	mat.set_shader_parameter("coverage_tex", cov_tex)
	mat.set_shader_parameter("city_mask_tex", city_tex)
	mat.set_shader_parameter("cell_meta_tex", meta_tex)
	mat.set_shader_parameter("world_origin", _world_bounds.position)
	mat.set_shader_parameter("world_size", _world_bounds.size)
	mat.set_shader_parameter("wrap_origin_x", _world_bounds.position.x)
	mat.set_shader_parameter("wrap_period_x", _wrap_period_x)
	var page_world := _field.chunk_world_size() * (float(CanopyField.PAGE_TEXELS) / float(CanopyField.CHUNK_TEXELS))
	var halo_margin := float(CanopyField.HALO_TEXELS) / float(CanopyField.PAGE_TEXELS)
	mat.set_shader_parameter("page_world_span", page_world)
	mat.set_shader_parameter("halo_uv_margin", halo_margin)
	mat.set_shader_parameter("canopy_height_world", _hex_size * 0.56)
	mat.set_shader_parameter("max_shadow_length_world", _hex_size * 1.35)
	_apply_lighting_to_shadow_mat(mat)
	return mat


func _apply_shared_daylight_to_mat(mat: ShaderMaterial) -> void:
	for k in _daylight_params.keys():
		mat.set_shader_parameter(String(k), _daylight_params[k])
	if _world_lighting_tex != null:
		mat.set_shader_parameter("world_lighting_tex", _world_lighting_tex)
	mat.set_shader_parameter("world_lighting_tex_bound", _world_lighting_bound)
	mat.set_shader_parameter("world_lighting_radiance_scale", _world_lighting_radiance_scale)
	if _cloud_shadow_tex != null:
		mat.set_shader_parameter("cloud_shadow_tex", _cloud_shadow_tex)
	mat.set_shader_parameter("cloud_shadow_field_bound", _cloud_shadow_bound)
	mat.set_shader_parameter("cloud_shadow_strength", _cloud_shadow_strength)
	mat.set_shader_parameter("cloud_shadow_wrap_origin_uv", _cloud_shadow_wrap_origin_uv)
	mat.set_shader_parameter("cloud_shadow_wrap_period_uv", _cloud_shadow_wrap_period_uv)
	if _enum_lut_tex != null:
		mat.set_shader_parameter("enum_lut", _enum_lut_tex)
	mat.set_shader_parameter("lut_dims", _lut_dims)
	mat.set_shader_parameter("cell_luts_bound", _cell_luts_bound)


func _apply_lighting_to_canopy_mat(mat: ShaderMaterial) -> void:
	_apply_shared_daylight_to_mat(mat)
	if _dyn_lut_tex != null:
		mat.set_shader_parameter("dyn_lut", _dyn_lut_tex)
	if _eco_lut_tex != null:
		mat.set_shader_parameter("eco_lut", _eco_lut_tex)
	mat.set_shader_parameter("snow_amount", _snow_amount)
	mat.set_shader_parameter("normal_enabled", _normal_enabled)
	mat.set_shader_parameter("ao_enabled", _ao_enabled)


func _apply_lighting_to_shadow_mat(mat: ShaderMaterial) -> void:
	_apply_shared_daylight_to_mat(mat)
	mat.set_shader_parameter("shadow_enabled", _shadow_enabled)


func _push_lighting_to_all_chunks() -> void:
	for entry in _chunks.values():
		var cmat: ShaderMaterial = entry.get("canopy_mat", null)
		if cmat != null:
			_apply_lighting_to_canopy_mat(cmat)
		var smat: ShaderMaterial = entry.get("shadow_mat", null)
		if smat != null:
			_apply_lighting_to_shadow_mat(smat)
		for sn in entry.get("shadow_nodes", []):
			if is_instance_valid(sn):
				sn.visible = bool(entry.get("visible", false)) and _shadow_enabled


func _recompute_visible_stats() -> void:
	_visible_canopy_batches = 0
	_visible_shadow_batches = 0
	_visible_tris = 0
	for entry in _chunks.values():
		if not bool(entry.get("visible", false)):
			continue
		var cnodes: Array = entry.get("canopy_nodes", [])
		var snodes: Array = entry.get("shadow_nodes", [])
		_visible_canopy_batches += cnodes.size()
		if _shadow_enabled:
			_visible_shadow_batches += snodes.size()
		_visible_tris += int(entry.get("tri_count", 0)) * cnodes.size()


func _ensure_roots() -> void:
	if _shadow_root == null or not is_instance_valid(_shadow_root):
		_shadow_root = Node2D.new()
		_shadow_root.name = "CanopyShadowRoot"
		_shadow_root.z_as_relative = false
		_shadow_root.z_index = Z_BAND_CANOPY_SHADOW
		add_child(_shadow_root)
	if _canopy_root == null or not is_instance_valid(_canopy_root):
		_canopy_root = Node2D.new()
		_canopy_root.name = "CanopyMeshRoot"
		_canopy_root.z_as_relative = false
		_canopy_root.z_index = Z_BAND_CANOPY
		add_child(_canopy_root)


func _ensure_tile_arrays() -> void:
	if _albedo_array == null:
		_albedo_array = _load_strip_as_array(ALBEDO_STRIP_PATH)
	if _aux_array == null:
		_aux_array = _load_strip_as_array(AUX_STRIP_PATH)


static func _load_strip_as_array(res_path: String) -> Texture2DArray:
	var strip_img: Image = null
	if ResourceLoader.exists(res_path):
		var res := load(res_path)
		if res is Texture2D:
			strip_img = res.get_image()
	if strip_img == null:
		var abs_path := ProjectSettings.globalize_path(res_path)
		if FileAccess.file_exists(abs_path):
			strip_img = Image.load_from_file(abs_path)
	if strip_img == null or strip_img.is_empty():
		return null
	if strip_img.get_width() != TILE_SIZE or strip_img.get_height() < TILE_SIZE * TILE_LAYERS:
		return null
	var layers: Array[Image] = []
	for i in range(TILE_LAYERS):
		var slice := Image.create(TILE_SIZE, TILE_SIZE, false, strip_img.get_format())
		slice.blit_rect(strip_img, Rect2i(0, i * TILE_SIZE, TILE_SIZE, TILE_SIZE), Vector2i.ZERO)
		slice.generate_mipmaps()
		layers.append(slice)
	var arr := Texture2DArray.new()
	if arr.create_from_images(layers) != OK:
		return null
	return arr


static func _free_chunk_nodes(entry: Dictionary) -> void:
	for node in entry.get("canopy_nodes", []):
		if is_instance_valid(node):
			node.queue_free()
	for node in entry.get("shadow_nodes", []):
		if is_instance_valid(node):
			node.queue_free()
