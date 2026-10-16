class_name ResourceVisualLayer
extends Node2D

const Catalog = preload("res://scripts/rendering/resource_visual_catalog.gd")
const Profile = preload("res://scripts/data/resource_visual_profile.gd")
const DEFAULT_PROFILE = preload("res://data/visual/resource_default.tres")
const RESOURCE_SHADER = preload("res://shaders/resource_impostor.gdshader")
const FAMILY_COUNT := 4
# Batches 0..3 = prop subjects per family (3 = submerged cues); 4 = ground decals,
# drawn first so props always sit on top of their own scar/soil patch.
const BATCH_COUNT := 5
const DECAL_BATCH := 4
const STRIDE := 16
const RESOURCE_Z := 1 # 与植被共用父级：地表(0) < 资源(1) < 树冠(2)。
# Instance kind lives in COLOR.a: integer part = kind, +0.5 = not the lens badge carrier.
const KIND_PROP := 1.0
const KIND_DECAL := 2.0
const KIND_SUBMERGED := 3.0
const KIND_BADGE_ONLY := 4.0
const NON_CARRIER := 0.5
const PLAN_PROP := 1
const PLAN_DECAL := 2
const PLAN_SUBMERGED := 4
const PLAN_BADGE := 8
# clay, sand, soil (fertile/arable/paddy/plantation/pasture), game tracks, land seep, land gas.
const GROUND_FORMS := [19, 20, 21, 22, 23, 25]
# rock, vein, crystal: a bare scar decal plus a small pebble prop.
const DEPOSIT_FORMS := [16, 17, 18]

@export var profile: Resource = DEFAULT_PROFILE
var _map: MapData
var _world: WorldData
var _intel: BuildingVisualIntelCache
var _styles: Array[Dictionary] = []
var _allowed := PackedByteArray()
var _hex := 22.0
var _quality := 1
var _mobile_tier := -1
var _fog := true
var _filter := ""
# 资源透镜：手动开关或存在筛选时，世界实景平滑切换为屏幕恒定尺寸的识别徽章。
var _lens_manual := false
var _lens_amount := 0.0
var _lens_msec := 0
var _filter_style := -1
var _context_ready := false
var _camera := Rect2()
var _center := Vector2.ZERO
var _zoom := 1.0
var _chunks: Dictionary = {}
var _cell_chunk: Array[Vector2i] = []
var _active: Dictionary = {}
var _resident: Dictionary = {}
var _dirty: Dictionary = {}
var _job: Dictionary = {}
var _uploads: Array[Dictionary] = []
var _scan_cursor := 0
var _near_cells: Array[int] = []
var _near_cursor := 0
var _material: ShaderMaterial
var _shader_tiled := false
var _mesh: QuadMesh
var _memory_image: Image
var _memory_texture: ImageTexture
var _memory_dirty := false
var _last_texture_msec := 0
var _instance_count := 0
var _revision := 0
var _layout_seed := 0
var _max_style_scale := 1.0
var _last_profile_enabled := true
var _configured := false
var _last_intel: Object
var _stats := {"observed_cells": 0, "rebuilt_chunks": 0, "uploads": 0,
	"last_observe_ms": 0.0, "last_build_ms": 0.0, "last_upload_ms": 0.0,
	"max_upload_ms": 0.0, "stale_jobs": 0}

func _ready() -> void:
	# 不能 top_level：它会脱离 HexRenderer 的绘制子树（show_behind_parent）。
	z_index = 0
	_material = ShaderMaterial.new()
	_material.shader = RESOURCE_SHADER
	_mesh = QuadMesh.new()
	_mesh.size = Vector2(2.0, 2.0)

func configure(map: MapData, world: WorldData, hex_size: float,
		intel: BuildingVisualIntelCache) -> Dictionary:
	_configured = false
	_clear_geometry()
	_map = map
	_world = world
	_intel = intel
	_hex = maxf(4.0, hex_size)
	_scan_cursor = 0
	_near_cursor = 0
	_near_cells.clear()
	_styles = Catalog.entries()
	var audit := Catalog.audit(_styles)
	if not bool(audit.ok) or _map == null or _intel == null:
		return audit if not bool(audit.ok) else {"ok": false, "reason": "resource_visual_context_missing"}
	_allowed = Catalog.presence_mask(_styles)
	_chunks.clear()
	_cell_chunk.resize(_map.cell_count())
	for cell in _map.cell_count():
		var p := cell_position(cell)
		var key := Vector2i(floori(p.x / (_hex * 16.0 * sqrt(3.0))), floori(p.y / (_hex * 24.0)))
		_cell_chunk[cell] = key
		if not _chunks.has(key):
			_chunks[key] = []
		_chunks[key].append(cell)
	var dims := Vector2i(maxi(1, mini(2048, _map.cell_count())), maxi(1, ceili(float(_map.cell_count()) / 2048.0)))
	if _world != null and _world.lut_dims.x > 0:
		dims = _world.lut_dims
	_memory_image = Image.create(dims.x, dims.y, false, Image.FORMAT_RGBA8)
	_memory_texture = ImageTexture.create_from_image(_memory_image)
	_material.set_shader_parameter("memory_lut", _memory_texture)
	_material.set_shader_parameter("lut_dims", Vector2(dims))
	_material.set_shader_parameter("hex_size", _hex)
	_material.set_shader_parameter("world_origin", _world.world_bounds.position if _world != null else Vector2.ZERO)
	_material.set_shader_parameter("world_size", _world.world_bounds.size if _world != null else Vector2.ONE)
	_material.set_shader_parameter("wrap_origin_x", _world.world_bounds.position.x if _world != null else 0.0)
	_material.set_shader_parameter("wrap_period_x", _world.wrap_period_x if _world != null else 0.0)
	_sync_terrain_textures()
	_build_style_texture()
	_refresh_filter_style()
	_apply_profile()
	_last_intel = null
	_sync_restored_memory()
	set_camera_view(_camera, _center, _zoom)
	_configured = true
	return audit

func _sync_terrain_textures() -> void:
	if _material == null or _world == null:
		return
	var tiles = _world.visual_tiles
	var tiled := tiles != null and bool(tiles.ready) and String(tiles.layout.mode) == "tiled"
	if tiled != _shader_tiled:
		_shader_tiled = tiled
		var shader := Shader.new()
		shader.code = ("#define MAP_VISUAL_TILED\n" if tiled else "") + RESOURCE_SHADER.code
		_material.shader = shader
	if tiled:
		_material.set_shader_parameter("visual_horizon_tiles", tiles.horizon)
		_material.set_shader_parameter("visual_terrain_normal_tiles", tiles.terrain_normal)
		_material.set_shader_parameter("visual_height_tiles", tiles.height)
		var layout = tiles.layout
		_material.set_shader_parameter("visual_domain_origin", layout.visual_domain.position)
		_material.set_shader_parameter("visual_domain_size", layout.visual_domain.size)
		for pair in [["visual_grid_size", layout.grid_size], ["visual_interior_size", layout.interior_size],
			["visual_layer_size", layout.layer_size], ["visual_logical_resolution", layout.logical_size]]:
			_material.set_shader_parameter(pair[0], Vector2(pair[1]))
		_material.set_shader_parameter("visual_gutter_px", float(layout.gutter_px))
	else:
		_material.set_shader_parameter("terrain_horizon_tex", _world.terrain_horizon_tex)
		_material.set_shader_parameter("terrain_normal_tex", _world.terrain_normal_tex)
		_material.set_shader_parameter("height_tex", _world.height_tex)
	var height_bound := tiles.height != null if tiled else _world.height_tex != null
	_material.set_shader_parameter("has_height_tex", height_bound)
	_material.set_shader_parameter("has_flow_tex", height_bound and not _world.flow_buffer.is_empty())
	_material.set_shader_parameter("sea_level", _world.sea_level)
	_material.set_shader_parameter("terrain_horizon_tex_bound", bool(tiles.horizon_ready) if tiled else _world.terrain_horizon_tex != null)
	_material.set_shader_parameter("terrain_normal_tex_bound", tiles.terrain_normal != null if tiled else _world.terrain_normal_tex != null)

# 复用地形/树木的参数；同时覆盖异步 horizon bake 完成后的重新绑定。
func set_terrain_lighting(source: ShaderMaterial) -> void:
	if source == null or _material == null:
		return
	_sync_terrain_textures()
	for name in ["terrain_horizon_strength", "terrain_horizon_softness", "terrain_horizon_max_angle",
		"terrain_horizon_cast_floor", "terrain_horizon_debug_view", "gi_horizon_lut", "gi_lut_bound",
		"gi_ao_strength", "gi_ao_floor", "gi_ao_smoothing", "gi_bent_strength", "gi_normal_floor"]:
		var value = source.get_shader_parameter(name)
		if value != null:
			_material.set_shader_parameter(name, value)

func _apply_profile() -> void:
	for name in ["vitality_dead_threshold", "vitality_power", "climate_response", "snow_response",
		"wind_strength", "animal_motion", "detailed_pixels", "simple_pixels", "fade_pixels",
		"palette_saturation", "badge_px", "decal_opacity", "submerged_opacity",
		"outline_strength", "contact_shadow", "cast_shadow", "luma_compress", "luma_range",
		"area_feather", "area_edge_noise", "plant_cluster_density", "river_clear_threshold"]:
		_material.set_shader_parameter(name, profile.get(name))
	_material.set_shader_parameter("visual_quality", quality())
	_material.set_shader_parameter("filter_style", _filter_style)

func set_context(fog_enabled: bool, seed_value: int = 0) -> void:
	if _context_ready and _fog == fog_enabled and _layout_seed == seed_value:
		return
	_layout_seed = seed_value
	_fog = fog_enabled
	_context_ready = true
	if not _styles.is_empty():
		_allowed = Catalog.presence_mask(_styles)
	if _material != null:
		_material.set_shader_parameter("fog_enabled", _fog)
	_scan_cursor = 0
	_invalidate()

func set_filter(stable_id: String) -> void:
	if _filter == stable_id:
		return
	_filter = stable_id
	_refresh_filter_style()
	_invalidate()

func _refresh_filter_style() -> void:
	_filter_style = -1
	if _filter != "":
		for i in _styles.size():
			var id := String(_styles[i].id)
			if id == _filter or "resource." + id == _filter:
				_filter_style = i
				break
	if _material != null:
		_material.set_shader_parameter("filter_style", _filter_style)

# 资源透镜：手动开启，或地图叠加层给出资源筛选时自动开启。
func set_lens(enabled: bool) -> void:
	if _lens_manual == enabled:
		return
	_lens_manual = enabled
	# 世界实景的密度门槛不限制主动查找；重新选取当前显示的资源。
	_invalidate()

func lens_enabled() -> bool:
	return _lens_manual or _filter != ""

func lens_amount() -> float:
	return _lens_amount

func _update_lens() -> void:
	var now := Time.get_ticks_msec()
	var delta := clampf(float(now - _lens_msec) / 1000.0, 0.0, 0.1)
	_lens_msec = now
	var target := 1.0 if lens_enabled() else 0.0
	if is_equal_approx(_lens_amount, target):
		return
	var was_hidden := _lens_amount <= 0.001
	_lens_amount = move_toward(_lens_amount, target, delta / maxf(0.01, float(profile.lens_fade_seconds)))
	_material.set_shader_parameter("lens_amount", _lens_amount)
	if was_hidden != (_lens_amount <= 0.001):
		# Lens visibility bypasses the zoom-based detail cull; refresh node visibility.
		for key in _resident:
			_sync_wrap_visibility(key)

func quality() -> int:
	return clampi(_mobile_tier if _mobile_tier >= 0 else _quality, 0, 2)

func set_quality(value: int, mobile_tier: int = -1) -> void:
	if _quality == value and _mobile_tier == mobile_tier:
		return
	_quality = clampi(value, 0, 2)
	_mobile_tier = mobile_tier
	if _material != null:
		_apply_profile()
	_clear_geometry()
	_invalidate()

func cell_position(cell: int) -> Vector2:
	return Vector2(_map.cell_pos_x_arr[cell], _map.cell_pos_y_arr[cell]) * _hex

func set_camera_view(rect: Rect2, center: Vector2, zoom_value: float) -> void:
	_camera = rect
	_center = center
	_zoom = clampf(zoom_value, 0.01, 16.0)
	if _material == null:
		return
	_material.set_shader_parameter("camera_zoom", _zoom)
	if rect.size.x <= 0.0 or _map == null:
		return
	var next := {}
	var grown := rect.grow(_hex * 2.0)
	var size := Vector2(_hex * 16.0 * sqrt(3.0), _hex * 24.0)
	var period := _world.wrap_period_x if _world != null else 0.0
	for wrap in [-1, 0, 1]:
		if wrap != 0 and period <= 0.0:
			continue
		var local := Rect2(grown.position - Vector2(float(wrap) * period, 0), grown.size)
		var start := Vector2i(floori(local.position.x / size.x), floori(local.position.y / size.y))
		var end := Vector2i(floori(local.end.x / size.x), floori(local.end.y / size.y))
		for y in range(start.y, end.y + 1):
			for x in range(start.x, end.x + 1):
				var key := Vector2i(x, y)
				if _chunks.has(key):
					next[key] = true
	var ordered: Array = next.keys()
	ordered.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return _chunk_distance(a) < _chunk_distance(b))
	var cap := int(profile.resident_chunks_mobile if _mobile_tier >= 0 else profile.resident_chunks_desktop)
	var old_active := _active.duplicate()
	_active.clear()
	for i in mini(cap, ordered.size()):
		var key: Vector2i = ordered[i]
		_active[key] = true
		if not _resident.has(key):
			_dirty[key] = true
	if old_active != _active or _near_cells.is_empty():
		_near_cells.clear()
		for key in _active:
			for cell in _chunks[key]:
				_near_cells.append(int(cell))
		_near_cursor = 0
	for key in _resident.keys():
		if not _active.has(key):
			_evict(key)
	for key in _resident:
		_sync_wrap_visibility(key)

func _chunk_distance(key: Vector2i) -> float:
	var point := (Vector2(key) + Vector2(0.5, 0.5)) * Vector2(_hex * 16.0 * sqrt(3.0), _hex * 24.0)
	var dx := point.x - _center.x
	if _world != null and _world.wrap_period_x > 0.0:
		dx = wrapf(dx, -_world.wrap_period_x * 0.5, _world.wrap_period_x * 0.5)
	return Vector2(dx, point.y - _center.y).length_squared()

# CPU work is cell/chunk based. Never walk instances for weather or animation.
func prepare_frame(time: float, sun: Vector3, state: Dictionary) -> void:
	if _last_profile_enabled != bool(profile.enabled):
		_last_profile_enabled = bool(profile.enabled)
		for key in _resident:
			_sync_wrap_visibility(key)
	if not _configured or _map == null or _intel == null or not profile.enabled or not _context_ready:
		return
	_material.set_shader_parameter("world_time", time)
	_update_lens()
	_material.set_shader_parameter("tod_sun_dir", sun)
	for name in state:
		_material.set_shader_parameter(name, state[name])
	if _world != null:
		_material.set_shader_parameter("dyn_lut", _world.dyn_lut_tex)
		_material.set_shader_parameter("has_dynamic_lut", _world.dyn_lut_tex != null)
		_material.set_shader_parameter("eco_lut", _world.eco_lut_tex)
		_material.set_shader_parameter("has_ecology_lut", _world.eco_lut_tex != null)
		_material.set_shader_parameter("enum_lut", _world.enum_lut_tex)
	_sync_restored_memory()
	var begin := Time.get_ticks_usec()
	_observe_until(begin + int(float(profile.observation_budget_ms) * 1000.0))
	_stats.last_observe_ms = float(Time.get_ticks_usec() - begin) / 1000.0
	begin = Time.get_ticks_usec()
	_build_until(begin + int(float(profile.build_budget_ms) * 1000.0))
	_stats.last_build_ms = float(Time.get_ticks_usec() - begin) / 1000.0

func _observe_until(deadline: int) -> void:
	if _allowed.size() != _styles.size():
		return
	var observations = _intel.resource_observations
	var n := _map.cell_count()
	var visited := 0
	while visited < n and Time.get_ticks_usec() < deadline:
		var cell := _scan_cursor
		# Most observation time goes to the camera's resident cells; a quarter
		# continues the global visible-cell sweep, including offscreen sensors.
		if visited % 4 != 3 and not _near_cells.is_empty():
			cell = _near_cells[_near_cursor % _near_cells.size()]
			_near_cursor += 1
		else:
			_scan_cursor = (_scan_cursor + 1) % maxi(1, n)
		visited += 1
		if _fog and (cell >= _map.visible_arr.size() or _map.visible_arr[cell] == 0):
			continue
		var changed: bool = observations.observe(_map, cell, _allowed, not _fog)
		var row: Dictionary = observations.rows.get(cell, {})
		_write_memory_pixel(cell, row.get("climate", Color(0.5, 0.5, 0, 1)))
		_stats.observed_cells = int(_stats.observed_cells) + 1
		if changed:
			_dirty[_cell_chunk[cell]] = true
			# Only cancel work for this chunk, without starving other chunks.
			if not _job.is_empty() and _job.key == _cell_chunk[cell]:
				_job.clear()
				_stats.stale_jobs = int(_stats.stale_jobs) + 1

func _sync_restored_memory() -> void:
	if _last_intel == _intel.resource_observations:
		return
	if _last_intel != null:
		_clear_geometry()
	_last_intel = _intel.resource_observations
	_memory_image.fill(Color(0, 0, 0, 0))
	_memory_dirty = true
	for cell in _last_intel.rows:
		_write_memory_pixel(int(cell), _last_intel.rows[cell].climate)
	_invalidate()

func _write_memory_pixel(cell: int, value: Color) -> void:
	value = Color8(roundi(value.r * 255.0), roundi(value.g * 255.0), roundi(value.b * 255.0), roundi(value.a * 255.0))
	var x := cell % _memory_image.get_width()
	var y := cell / _memory_image.get_width()
	if _memory_image.get_pixel(x, y) != value:
		_memory_image.set_pixel(x, y, value)
		_memory_dirty = true

func notify_cells(cells: PackedInt32Array) -> void:
	for cell in cells:
		if cell >= 0 and cell < _cell_chunk.size():
			_dirty[_cell_chunk[cell]] = true

func _invalidate() -> void:
	_revision += 1
	_job.clear()
	_uploads.clear()
	for key in _active:
		_dirty[key] = true

func _build_until(deadline: int) -> void:
	if not _detail_visible():
		return
	if not _uploads.is_empty():
		return
	if _job.is_empty():
		for key in _active:
			if _dirty.has(key):
				_dirty.erase(key)
				_job = {"key": key, "cursor": 0, "buffers": [[], [], [], [], []], "revision": _revision}
				break
	if _job.is_empty():
		return
	var cells: Array = _chunks[_job.key]
	while int(_job.cursor) < cells.size() and Time.get_ticks_usec() < deadline:
		_append_cell(int(cells[int(_job.cursor)]), _job.buffers)
		_job.cursor = int(_job.cursor) + 1
	if int(_job.cursor) >= cells.size():
		for family in BATCH_COUNT:
			_uploads.append({"key": _job.key, "family": family,
				"buffer": PackedFloat32Array(_job.buffers[family]), "revision": _revision})
		_job.clear()
		_stats.rebuilt_chunks = int(_stats.rebuilt_chunks) + 1

func selected_styles(cell: int) -> PackedInt32Array:
	var row: Dictionary = _intel.resource_observations.rows.get(cell, {})
	var bands: PackedByteArray = row.get("bands", PackedByteArray())
	var source_water := cell < _map.is_water_arr.size() and _map.is_water_arr[cell] != 0
	var candidates: Array[Dictionary] = []
	for i in mini(bands.size(), _styles.size()):
		if bands[i] == 0 or i >= _allowed.size() or _allowed[i] == 0:
			continue
		var e := _styles[i]
		if visual_plan(e, source_water) == 0:
			continue
		if not lens_enabled() and not world_presence_allowed(cell, i, bands[i]):
			continue
		var override: Dictionary = profile.style_overrides.get(e.id, {})
		var score := float(override.get("priority", e.priority)) + float(bands[i]) * 0.18 + _hash(cell, i) * 0.08
		if String(e.id) == _filter or "resource." + String(e.id) == _filter:
			score += 100.0
		candidates.append({"style": i, "family": int(e.family), "score": score})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.score) > float(b.score))
	var result := PackedInt32Array()
	var families := {}
	var limit: int = profile.type_cap(quality())
	for candidate in candidates:
		if result.size() >= limit:
			break
		if families.has(candidate.family):
			continue
		result.append(int(candidate.style))
		families[candidate.family] = true
	for candidate in candidates:
		if result.size() >= limit:
			break
		if not result.has(int(candidate.style)):
			result.append(int(candidate.style))
	return result

# 概率按格/资源固定，只判定一次，不能放进候选位置重试，否则八次尝试会抹平稀疏度。
# 这里只控制实景；观测、资源列表、储量和生物占领完全不变。
func world_presence_allowed(cell: int, style: int, band: int) -> bool:
	if band <= 0:
		return false
	var e := _styles[style]
	if int(e.family) == 0 or int(e.family) == 3 or int(e.form) == 22:
		return true
	var probability := float(profile.animal_presence) if int(e.family) == 1 else float(profile.mineral_presence)
	if int(e.family) == 2 and band < int(profile.mineral_min_abundance_band):
		return false
	return _hash(cell, style * 211 + _layout_seed + 4217) < probability

# 世界实景只做美术点缀：土地类是软边地面贴花，矿床是“裸露矿斑贴花 + 小件碎石”，
# 动植物是小件主体，水产与水下油气是水下贴花。确切种类交给资源透镜徽章。
static func visual_plan(entry: Dictionary, source_water: bool) -> int:
	var family := int(entry.family)
	var form := int(entry.form)
	if source_water:
		return PLAN_SUBMERGED if family == 3 or form == 21 or form == 25 else 0
	if family == 3:
		return PLAN_SUBMERGED # River fish: only where the river body itself passes.
	if form == 26:
		return PLAN_BADGE # 木材：森林本身就是木材，世界里不再叠原木，只保留透镜徽章。
	if form in GROUND_FORMS:
		return PLAN_DECAL
	if form in DEPOSIT_FORMS:
		return PLAN_DECAL | PLAN_PROP
	return PLAN_PROP

func _append_cell(cell: int, buffers: Array) -> void:
	var selected := selected_styles(cell)
	var row: Dictionary = _intel.resource_observations.rows.get(cell, {})
	var bands: PackedByteArray = row.get("bands", PackedByteArray())
	var core := int(_intel.settlement_core_buckets()[cell])
	var cell_center := cell_position(cell)
	var cap: int = profile.cell_cap(quality())
	var source_water := cell < _map.is_water_arr.size() and _map.is_water_arr[cell] != 0
	# x, y = centre, z = footprint radius used for spacing.
	var occupied: Array[Vector3] = []
	for rank in selected.size():
		if occupied.size() >= cap:
			break
		var style := selected[rank]
		var e := _styles[style]
		var plan := visual_plan(e, source_water)
		if plan == 0:
			continue
		var render_family := int(e.family)
		var override: Dictionary = profile.style_overrides.get(e.id, {})
		var size_scale := float(override.get("size_scale", 1.0))
		var prop_diameter := float(profile.plant_diameter_hex) if render_family == 0 and int(e.form) != 26 else float(profile.patch_diameter_hex)
		var ground_diameter := float(profile.fertility_diameter_hex) if int(e.form) == 22 else float(profile.decal_diameter_hex)
		var prop_radius := _hex * prop_diameter * 0.5 * size_scale * (1.15 if render_family == 1 else 1.0)
		var decal_radius := _hex * ground_diameter * 0.5 * size_scale
		var submerged := (plan & PLAN_SUBMERGED) != 0
		var has_prop := (plan & (PLAN_PROP | PLAN_BADGE)) != 0
		var foot := prop_radius if has_prop else decal_radius * 0.55
		var domain_family := 3 if submerged else render_family
		var accepted := false
		var point := cell_center
		for attempt in 8:
			var seed_value := style * 211 + attempt * 17 + _layout_seed
			var angle := _hash(cell, seed_value) * TAU
			var radial := sqrt(_hash(cell, seed_value + 1)) * _hex * (0.40 + float(profile.cluster_spread) * 0.45)
			point = cell_center + Vector2.from_angle(angle) * radial
			if core > 0 and point.distance_to(cell_center) < _hex * (0.32 + minf(core / 15.0, 1.0) * 0.25) + foot:
				continue
			var collides := false
			for other in occupied:
				if Vector2(other.x, other.y).distance_to(point) < (foot + other.z) * 0.82:
					collides = true
					break
			if collides or not candidate_allowed(point, domain_family, 1 if source_water else 0):
				continue
			var patch := 1.0 - float(profile.patch_noise_strength) + float(profile.patch_noise_strength) * _patch_noise(point)
			if _hash(cell, seed_value + 5) > minf(1.0, float(profile.density_scale) * patch):
				continue
			accepted = true
			break
		if not accepted:
			continue
		occupied.append(Vector3(point.x, point.y, foot))
		var importance := (3.0 - float(rank)) * 2.0 + float(bands[style]) * 0.2 + _patch_noise(point)
		var variation := _hash(cell, style)
		if submerged:
			# Fish are everywhere at sea; only a few cells show a shoal.
			if render_family == 3 and _hash(cell, style + 577) > float(profile.shoal_density):
				continue
			var transmission := _water_transmission(cell)
			if transmission < 0.06:
				continue
			_emit(buffers[3], point, decal_radius, rank, cell, style, variation, bands[style], importance, KIND_SUBMERGED, transmission)
			continue
		if (plan & PLAN_DECAL) != 0:
			var kind := KIND_DECAL + (NON_CARRIER if has_prop else 0.0)
			_emit(buffers[DECAL_BATCH], point, decal_radius, rank, cell, style, variation, bands[style], importance, kind)
		if (plan & PLAN_PROP) != 0:
			# Pebbles sit slightly off-centre on their own scar, never dead centre.
			var offset := Vector2.from_angle(_hash(cell, style + 913) * TAU) * decal_radius * 0.12
			_emit(buffers[render_family], point + offset, prop_radius, rank, cell, style, variation, bands[style], importance + 0.5, KIND_PROP)
		elif (plan & PLAN_BADGE) != 0:
			_emit(buffers[render_family], point, prop_radius, rank, cell, style, variation, bands[style], importance, KIND_BADGE_ONLY)

# Axis-aligned quad; decals and props rotate internally by their static seed.
# COLOR.g carries light transmission through water (1 on land).
func _emit(buffer: Array, point: Vector2, radius: float, rank: int, cell: int, style: int,
		variation: float, band: int, importance: float, kind: float, transmission: float = 1.0) -> void:
	buffer.append_array([radius, 0.0, 0.0, point.x, 0.0, radius, 0.0, point.y,
		float(rank), transmission, importance, kind,
		float(cell), float(style), variation, float(band)])

# Deep water hides the seabed: same falloff the old terrain-shader path used.
func _water_transmission(cell: int) -> float:
	if _map == null or cell >= _map.elevation_arr.size() or _map.is_water_arr[cell] == 0:
		return 1.0
	var sea := clampf(_world.sea_level if _world != null else 0.42, 0.01, 1.0)
	var depth := clampf((sea - _map.elevation_arr[cell]) / sea, 0.0, 1.0)
	return exp(-depth * float(profile.water_depth_falloff))

func candidate_allowed(point: Vector2, family: int, source_domain: int = -1) -> bool:
	var flow := _world.sample_flow(point) if _world != null else 0.0
	var water := source_domain == 1
	if _world != null and not _world.biome_buffer.is_empty():
		var terrain := _world.sample_biome(point)
		water = terrain in [TerrainType.TERRAIN.OCEAN, TerrainType.TERRAIN.COAST,
			TerrainType.TERRAIN.LAKE, TerrainType.TERRAIN.SEA_ICE]
	elif _world != null and not _world.pixel_to_cell_lookup.is_empty():
		# Active tiled rendering can retire biome_buffer. Its static pixel→cell
		# lookup is still authoritative; an empty old atlas never means all land.
		var uv := _world._world_to_uv(point)
		var x := clampi(roundi(uv.x * float(_world.derived_size.x - 1)), 0, _world.derived_size.x - 1)
		var y := clampi(roundi(uv.y * float(_world.derived_size.y - 1)), 0, _world.derived_size.y - 1)
		var index := y * _world.derived_size.x + x
		if index < 0 or index >= _world.pixel_to_cell_lookup.size():
			return false
		var owner_cell = _world.pixel_to_cell_lookup[index]
		if owner_cell == null:
			return false
		var owner_index := int(owner_cell.index)
		water = owner_index >= 0 and owner_index < _map.is_water_arr.size() and _map.is_water_arr[owner_index] != 0
	if family == 3:
		return water or flow > 0.78
	return not water and flow < float(profile.river_clear_threshold)

func _patch_noise(point: Vector2) -> float:
	var p := point / (_hex * 5.0)
	var x := floori(p.x)
	var y := floori(p.y)
	var f := Vector2(p.x - float(x), p.y - float(y))
	f = f * f * (Vector2(3.0, 3.0) - f * 2.0)
	return lerpf(lerpf(_hash(x, y + _layout_seed), _hash(x + 1, y + _layout_seed), f.x),
		lerpf(_hash(x, y + 1 + _layout_seed), _hash(x + 1, y + 1 + _layout_seed), f.x), f.y)

# Called by HexRenderer only when the shared detail scheduler grants an upload.
func drain_one_upload() -> bool:
	if not _configured or not profile.enabled:
		return false
	var begin := Time.get_ticks_usec()
	if _memory_dirty and Time.get_ticks_msec() - _last_texture_msec >= 100:
		_memory_texture.update(_memory_image)
		_memory_dirty = false
		_last_texture_msec = Time.get_ticks_msec()
		return true
	if _uploads.is_empty():
		return false
	if not _detail_visible():
		return false
	var task: Dictionary = _uploads.pop_front()
	if int(task.revision) != _revision or not _active.has(task.key):
		return false
	var key: Vector2i = task.key
	var family := int(task.family)
	if not _resident.has(key):
		_resident[key] = {}
	var family_nodes: Dictionary = _resident[key]
	var previous := 0
	if family_nodes.has(family):
		previous = family_nodes[family].multimesh.instance_count
	var buffer: PackedFloat32Array = task.buffer
	var remaining: int = profile.instance_cap(quality(), _mobile_tier >= 0) - _instance_count + previous
	var count := mini(buffer.size() / STRIDE, maxi(0, remaining))
	if count > 0 and count < buffer.size() / STRIDE:
		buffer = _keep_important_instances(buffer, count)
	else:
		buffer.resize(count * STRIDE)
	if count == 0:
		if family_nodes.has(family):
			_remove_node(family_nodes[family])
			family_nodes.erase(family)
		_instance_count -= previous
		return true
	var node: MultiMeshInstance2D
	if family_nodes.has(family):
		node = family_nodes[family]
	else:
		node = MultiMeshInstance2D.new()
		node.name = "Resource_%d_%d_%d" % [key.x, key.y, family]
		node.z_index = RESOURCE_Z
		node.material = _material
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_2D
		mm.use_colors = true
		mm.use_custom_data = true
		mm.mesh = _mesh
		node.multimesh = mm
		add_child(node)
		if family == DECAL_BATCH:
			move_child(node, 0)
		family_nodes[family] = node
		var copies: Array[MultiMeshInstance2D] = []
		if _world != null and _world.wrap_period_x > 0.0:
			for side in [-1, 1]:
				var copy := MultiMeshInstance2D.new()
				copy.z_index = RESOURCE_Z
				copy.material = _material
				copy.multimesh = mm
				copy.position.x = float(side) * _world.wrap_period_x
				add_child(copy)
				if family == DECAL_BATCH:
					move_child(copy, 0)
				copies.append(copy)
		node.set_meta("wraps", copies)
	node.multimesh.instance_count = count
	node.multimesh.buffer = buffer
	_instance_count += count - previous
	_sync_wrap_visibility(key)
	_stats.uploads = int(_stats.uploads) + 1
	_stats.last_upload_ms = float(Time.get_ticks_usec() - begin) / 1000.0
	_stats.max_upload_ms = maxf(float(_stats.max_upload_ms), float(_stats.last_upload_ms))
	return true

static func _keep_important_instances(buffer: PackedFloat32Array, count: int) -> PackedFloat32Array:
	var order: Array[int] = []
	for i in buffer.size() / STRIDE:
		order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool:
		var av := buffer[a * STRIDE + 10]
		var bv := buffer[b * STRIDE + 10]
		return av > bv if av != bv else a < b)
	var result := PackedFloat32Array()
	result.resize(count * STRIDE)
	for i in count:
		for k in STRIDE:
			result[i * STRIDE + k] = buffer[order[i] * STRIDE + k]
	return result

func _sync_wrap_visibility(key: Vector2i) -> void:
	var size := Vector2(_hex * 16.0 * sqrt(3.0), _hex * 24.0)
	var bounds := Rect2(Vector2(key) * size, size).grow(_hex)
	for node in _resident[key].values():
		node.visible = _detail_visible() and _camera.intersects(bounds)
		for copy in node.get_meta("wraps", []):
			copy.visible = _detail_visible() and _camera.intersects(Rect2(bounds.position + copy.position, bounds.size))

func _detail_visible() -> bool:
	if not profile.enabled:
		return false
	if _lens_amount > 0.001:
		return true
	var diameter := maxf(maxf(float(profile.patch_diameter_hex), float(profile.decal_diameter_hex)),
		maxf(float(profile.plant_diameter_hex), float(profile.fertility_diameter_hex)))
	return _hex * diameter * 0.5 * _max_style_scale * _zoom > float(profile.fade_pixels)

func _remove_node(node: MultiMeshInstance2D) -> void:
	for copy in node.get_meta("wraps", []):
		copy.visible = false
		copy.queue_free()
	node.visible = false
	node.queue_free()

func _evict(key: Vector2i) -> void:
	for node in _resident[key].values():
		_instance_count -= node.multimesh.instance_count
		_remove_node(node)
	_resident.erase(key)

func _clear_geometry() -> void:
	for key in _resident.keys():
		_evict(key)
	_job.clear()
	_uploads.clear()
	_dirty.clear()
	_instance_count = 0
	_revision += 1

func _build_style_texture() -> void:
	var image := Image.create(2, 64, false, Image.FORMAT_RGBAF)
	_max_style_scale = 1.0
	for i in _styles.size():
		var e := _styles[i]
		var override: Dictionary = profile.style_overrides.get(e.id, {})
		_max_style_scale = maxf(_max_style_scale, float(override.get("size_scale", 1.0)))
		image.set_pixel(0, i, override.get("color", e.color))
		image.set_pixel(1, i, Color(float(e.form), float(e.family), float(e.get("sub_style", i % 4)), float(e.get("metallic", 0.0))))
	_material.set_shader_parameter("style_lut", ImageTexture.create_from_image(image))

func diagnostics() -> Dictionary:
	var result := _stats.duplicate()
	result.merge({"instances": _instance_count, "resident_chunks": _resident.size(),
		"pending_uploads": _uploads.size(), "dirty_chunks": _dirty.size(),
		"known_cells": _intel.resource_observations.rows.size() if _intel != null else 0,
		"quality": quality(), "mobile": _mobile_tier >= 0, "catalog": Catalog.audit(_styles)})
	return result

static func _hash(cell: int, salt: int) -> float:
	var value := ((cell + 1) * 1103515245 + (salt + 71) * 12345) & 0x7fffffff
	value = ((value ^ (value >> 13)) * 1274126177) & 0x7fffffff
	return float(value) / 2147483647.0
