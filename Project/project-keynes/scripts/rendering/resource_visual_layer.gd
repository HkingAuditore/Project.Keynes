class_name ResourceVisualLayer
extends Node2D

const Catalog = preload("res://scripts/rendering/resource_visual_catalog.gd")
const Profile = preload("res://scripts/data/resource_visual_profile.gd")
const DEFAULT_PROFILE = preload("res://data/visual/resource_default.tres")
const RESOURCE_SHADER = preload("res://shaders/resource_impostor.gdshader")
const GroundCover = preload("res://scripts/rendering/resource_ground_cover.gd")
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

# ─── Web / Compatibility 编译期精简变体（2026-10-31）────────────────────────
# 见 shaders/include/resource_impostor_web_min.gdshaderinc。这张 shader 展开后约
# 183 KB / 4 400 行 / 48 个 for，是全部 shader 里最重的一张，web 首次编译实测
# 27 424 ms。变体把「运行期必然走不到 / 只在 lens 徽章里出现」的分支整段裁掉：
#   展开源码 146 073 → 54 210 code chars，for 循环 48 → 14，uniform 声明 80 → 80。
#
# 前缀是**唯一**开关，而且必须是单一事实来源：菜单期 WebShaderWarmup 用
# warmup_prefix() 取同一串宏，差一个字节驱动就不认缓存、预热白做
# （植被/世界地图那边都踩过一次，见 ShrubLayer.web_warmup_shader_codes()）。
#
# 档位钉死 LOW：min 变体里没有任何代码响应 MOBILE_QUALITY_*（terrain_horizon 整段被
# 中性值顶替，本 include 链路也不用 PK_MOBILE_ANY），而菜单期预热读不到玩家进游戏后
# 才会生效的画质设置。若让前缀跟随设置，玩家选「中/高」时运行期就会编出另一份，
# 缓存必然不命中，27 秒的编译就回到游戏里了。
const MAP_VISUAL_TILED_DEFINE := "#define MAP_VISUAL_TILED\n"
const WEB_MIN_QUALITY_DEFINE := "#define MOBILE_QUALITY_LOW\n#define PK_SHADER_TIER_LOW\n"
const WEB_MIN_DEFINE := "#define PK_WEB_RESOURCE_MIN\n"
## [web-two-pass] 同一份 .gdshader 编成两份程序：surface / geology。
## 依据与实测见 shaders/resource_impostor.gdshader 的 [web-two-pass] 段与
## tmp/next/resource_cliff_IMPL.md。
const WEB_PASS_SURFACE_DEFINE := "#define PK_RES_WEB_PASS_SURFACE\n"
const WEB_PASS_GEOLOGY_DEFINE := "#define PK_RES_WEB_PASS_GEOLOGY\n"
## batch 2 = 矿物道具（form 16/17/18 → rt_geology_solid）。其余 batch 都是 surface。
const MINERAL_BATCH := 2

## 本图层是否走 web/GLES3 精简变体。web 上 is_compatibility_renderer() 恒 true
## （feature_flags.gd:464-465），桌面 Forward+/Mobile 恒 false → 桌面路径不变。
static func web_min_active() -> bool:
	return DCFeatureFlags.is_compatibility_renderer()


## 运行期真正会交给驱动的那份源码前缀（tiled 只可能出现在桌面）。
## 这是 **surface** pass 的前缀；矿物 batch 用 geology_variant_prefix()。
static func shader_variant_prefix(tiled: bool) -> String:
	var prefix := MAP_VISUAL_TILED_DEFINE if tiled else ""
	if web_min_active():
		prefix += WEB_MIN_QUALITY_DEFINE + WEB_MIN_DEFINE + WEB_PASS_SURFACE_DEFINE
	return prefix


## 矿物 batch（batch 2）那份程序的前缀。除 pass 宏外与 surface **逐字相同**：
## 两份程序共享同一套 uniform，差一个字节驱动就不认缓存。
static func geology_variant_prefix(tiled: bool) -> String:
	var prefix := MAP_VISUAL_TILED_DEFINE if tiled else ""
	if web_min_active():
		prefix += WEB_MIN_QUALITY_DEFINE + WEB_MIN_DEFINE + WEB_PASS_GEOLOGY_DEFINE
	return prefix


## 菜单期预热用：与运行期首次绘制时的前缀**同源**。非 web 返回空串（预热本身只在
## web 上跑，见 WebShaderWarmup.run）。web 上 visual_tiles 恒为 null
## （map_baker.gd:1276-1279），所以运行期的 tiled 也是 false，两份前缀逐字相同。
static func warmup_prefix() -> String:
	return shader_variant_prefix(false) if web_min_active() else ""


## 菜单期预热用：geology 那份的前缀（与运行期 geology_variant_prefix(false) 同源）。
static func geology_warmup_prefix() -> String:
	return geology_variant_prefix(false) if web_min_active() else ""


## 菜单期预热用：返回运行期真正会交给驱动的那份源码。WebShaderWarmup 只负责调它，
## 不自己拼宏串（差一个字节驱动就不认缓存、预热白做）。
static func compose_shader_code(source: Shader) -> String:
	if source == null:
		return ""
	return warmup_prefix() + source.code


## 菜单期预热：web 上本图层有**两份**程序，必须各编一遍，否则进世界还会再编一次。
## 返回 {label: code}，与 ShrubLayer.web_warmup_shader_codes() 同构，
## 让 WebShaderWarmup 只负责遍历、不自己拼宏串。
static func web_warmup_shader_codes() -> Dictionary:
	if not web_min_active():
		return {}
	var source := RESOURCE_SHADER
	if source == null:
		return {}
	var body := String(source.code)
	return {
		"resource_impostor": warmup_prefix() + body,
		"resource_impostor_geology": geology_warmup_prefix() + body,
	}


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
## 矿物 batch 专用材质（web 上是 geology pass 那份程序；桌面与 _material 指向同一资源）。
var _material_geo: ShaderMaterial
var _shader_tiled := false
## 上一次真正写进 _material.shader 的编译期前缀（见 shader_variant_prefix）。
var _shader_prefix := ""
## 同上，geology pass 的前缀。
var _shader_geo_prefix := ""
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
# Wild plant communities + grazing traces: one full-world quad drawn under all props.
var _cover: ResourceGroundCover
var _cover_pending: Array[int] = []
var _cover_pending_cursor := 0
var _stats := {"observed_cells": 0, "rebuilt_chunks": 0, "uploads": 0,
	"last_observe_ms": 0.0, "last_build_ms": 0.0, "last_upload_ms": 0.0,
	"max_upload_ms": 0.0, "stale_jobs": 0}

func _ready() -> void:
	# 不能 top_level：它会脱离 HexRenderer 的绘制子树（show_behind_parent）。
	z_index = 0
	_material = ShaderMaterial.new()
	_material.shader = RESOURCE_SHADER
	_material_geo = ShaderMaterial.new()
	_material_geo.shader = RESOURCE_SHADER
	_mesh = QuadMesh.new()
	_mesh.size = Vector2(2.0, 2.0)
	_cover = GroundCover.new()
	_cover.name = "ResourceGroundCover"
	add_child(_cover)
	move_child(_cover, 0)

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
	_set_param("memory_lut", _memory_texture)
	_set_param("lut_dims", Vector2(dims))
	_set_param("hex_size", _hex)
	_set_param("world_origin", _world.world_bounds.position if _world != null else Vector2.ZERO)
	_set_param("world_size", _world.world_bounds.size if _world != null else Vector2.ONE)
	_set_param("wrap_origin_x", _world.world_bounds.position.x if _world != null else 0.0)
	_set_param("wrap_period_x", _world.wrap_period_x if _world != null else 0.0)
	_sync_terrain_textures()
	_build_style_texture()
	if _cover != null:
		var tiles = _world.visual_tiles if _world != null else null
		_cover.configure(_styles, _hex, dims,
			_world.world_bounds if _world != null else Rect2(),
			_world.wrap_period_x if _world != null else 0.0,
			_world.enum_atlas_tex if _world != null else null, tiles)
		_cover.material().set_shader_parameter("memory_lut", _memory_texture)
		_sync_terrain_textures()
	_refresh_filter_style()
	_apply_profile()
	_last_intel = null
	_sync_restored_memory()
	set_camera_view(_camera, _center, _zoom)
	_configured = true
	return audit

func _sync_terrain_textures() -> void:
	if _material == null or _material_geo == null or _world == null:
		return
	var tiles = _world.visual_tiles
	var tiled := tiles != null and bool(tiles.ready) and String(tiles.layout.mode) == "tiled"
	var prefix := shader_variant_prefix(tiled)
	var geo_prefix := geology_variant_prefix(tiled)
	if tiled != _shader_tiled or prefix != _shader_prefix or geo_prefix != _shader_geo_prefix:
		_shader_tiled = tiled
		_shader_prefix = prefix
		_shader_geo_prefix = geo_prefix
		_assign_variant(_material, prefix)
		_assign_variant(_material_geo, geo_prefix)
	for material in _materials():
		_bind_terrain_textures(material, tiles, tiled)

## 桌面（且未 tiled，prefix 为空）：与改动前逐字相同，直接把源文件资源交给材质，
## 不产生任何新的 Shader 实例 ⇒ 桌面走的就是 preload 的那一份。
func _assign_variant(target: ShaderMaterial, prefix: String) -> void:
	if target == null:
		return
	if prefix.is_empty():
		target.shader = RESOURCE_SHADER
	else:
		var shader := Shader.new()
		shader.code = prefix + RESOURCE_SHADER.code
		target.shader = shader


## 每个 uniform 都要推到**两份** impostor 材质上：web 的两份程序共享同一套 uniform，
## 漏推一份就是"另一份 pass 画错/不画"。
## 注意不包含 ground cover：那是另一张 shader（resource_ground_cover.gdshader），
## 它的 uniform 集合不同，由 _bind_terrain_textures / configure 单独推。
func _set_param(name: String, value) -> void:
	if _material != null:
		_material.set_shader_parameter(name, value)
	if _material_geo != null:
		_material_geo.set_shader_parameter(name, value)


func _material_for(family: int) -> ShaderMaterial:
	# batch 2 = 矿物道具（rt_geology_solid）；桌面两份材质指向同一资源，等价。
	return _material_geo if family == MINERAL_BATCH and _material_geo != null else _material


func _materials() -> Array[ShaderMaterial]:
	var out: Array[ShaderMaterial] = []
	if _material != null:
		out.append(_material)
	if _material_geo != null:
		out.append(_material_geo)
	if _cover != null:
		out.append(_cover.material())
	return out

func _bind_terrain_textures(target: ShaderMaterial, tiles, tiled: bool) -> void:
	if tiled:
		target.set_shader_parameter("visual_horizon_tiles", tiles.horizon)
		target.set_shader_parameter("visual_terrain_normal_tiles", tiles.terrain_normal)
		target.set_shader_parameter("visual_height_tiles", tiles.height)
		var layout = tiles.layout
		target.set_shader_parameter("visual_domain_origin", layout.visual_domain.position)
		target.set_shader_parameter("visual_domain_size", layout.visual_domain.size)
		for pair in [["visual_grid_size", layout.grid_size], ["visual_interior_size", layout.interior_size],
			["visual_layer_size", layout.layer_size], ["visual_logical_resolution", layout.logical_size]]:
			target.set_shader_parameter(pair[0], Vector2(pair[1]))
		target.set_shader_parameter("visual_gutter_px", float(layout.gutter_px))
	else:
		target.set_shader_parameter("terrain_horizon_tex", _world.terrain_horizon_tex)
		target.set_shader_parameter("terrain_normal_tex", _world.terrain_normal_tex)
		target.set_shader_parameter("height_tex", _world.height_tex)
	var height_bound := tiles.height != null if tiled else _world.height_tex != null
	target.set_shader_parameter("has_height_tex", height_bound)
	target.set_shader_parameter("has_flow_tex", height_bound and not _world.flow_buffer.is_empty())
	target.set_shader_parameter("sea_level", _world.sea_level)
	target.set_shader_parameter("terrain_horizon_tex_bound", bool(tiles.horizon_ready) if tiled else _world.terrain_horizon_tex != null)
	target.set_shader_parameter("terrain_normal_tex_bound", tiles.terrain_normal != null if tiled else _world.terrain_normal_tex != null)

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
			for material in _materials():
				material.set_shader_parameter(name, value)

func _apply_profile() -> void:
	for name in ["vitality_dead_threshold", "vitality_power", "climate_response", "snow_response",
		"wind_strength", "animal_motion", "detailed_pixels", "simple_pixels", "fade_pixels",
		"palette_saturation", "badge_px", "decal_opacity", "submerged_opacity",
		"outline_strength", "contact_shadow", "cast_shadow", "luma_compress", "luma_range",
		"area_feather", "area_edge_noise", "plant_cluster_density", "river_clear_threshold"]:
		_set_param(name, profile.get(name))
	for name in ["herd_size_min", "herd_size_max", "animal_length_hex", "animal_min_pixels"]:
		_set_param(name, profile.get(name))
	_set_param("herd_radius_hex", herd_radius_hex())
	_set_param("visual_quality", quality())
	_set_param("filter_style", _filter_style)
	if _cover != null:
		_cover.apply_profile(profile)
		_cover.set_quality(quality(), _mobile_tier)

## Herd instance radius in hexes: room for herd_size_max animals of animal_length_hex.
func herd_radius_hex() -> float:
	return clampf(float(profile.animal_length_hex) * 4.0, 0.12, 0.55)

func set_context(fog_enabled: bool, seed_value: int = 0) -> void:
	if _context_ready and _fog == fog_enabled and _layout_seed == seed_value:
		return
	_layout_seed = seed_value
	_fog = fog_enabled
	_context_ready = true
	if not _styles.is_empty():
		_allowed = Catalog.presence_mask(_styles)
	if _material != null:
		_set_param("fog_enabled", _fog)
	_scan_cursor = 0
	# Herd traces follow world presence, which depends on the layout seed.
	_queue_cover_rewrite()
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
		_set_param("filter_style", _filter_style)

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
	_set_param("lens_amount", _lens_amount)
	if _cover != null:
		_cover.set_lens_amount(_lens_amount)
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
	_set_param("camera_zoom", _zoom)
	if _cover != null:
		_cover.set_zoom(_zoom)
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
	if _cover != null:
		_cover.set_enabled(bool(profile.enabled) and bool(profile.ground_cover_enabled) and _configured and _context_ready)
	if not _configured or _map == null or _intel == null or not profile.enabled or not _context_ready:
		return
	_set_param("world_time", time)
	_update_lens()
	_set_param("tod_sun_dir", sun)
	for name in state:
		_set_param(name, state[name])
	if _world != null:
		_set_param("dyn_lut", _world.dyn_lut_tex)
		_set_param("has_dynamic_lut", _world.dyn_lut_tex != null)
		_set_param("eco_lut", _world.eco_lut_tex)
		_set_param("has_ecology_lut", _world.eco_lut_tex != null)
		_set_param("enum_lut", _world.enum_lut_tex)
	if _cover != null:
		var cover_state := state.duplicate()
		cover_state["tod_sun_dir"] = sun
		cover_state["fog_enabled"] = _fog
		if _world != null:
			cover_state["dyn_lut"] = _world.dyn_lut_tex
			cover_state["has_dynamic_lut"] = _world.dyn_lut_tex != null
			cover_state["enum_lut"] = _world.enum_lut_tex
		_cover.set_frame_state(time, cover_state, _memory_texture)
	_sync_restored_memory()
	var begin := Time.get_ticks_usec()
	_observe_until(begin + int(float(profile.observation_budget_ms) * 1000.0))
	_drain_cover_pending(begin + int(float(profile.observation_budget_ms) * 1000.0) + 200)
	_stats.last_observe_ms = float(Time.get_ticks_usec() - begin) / 1000.0
	if _cover != null:
		_cover.flush()
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
			_write_cover(cell)
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
	if _cover != null:
		_cover.clear_cells()
	_queue_cover_rewrite()
	_invalidate()

## Re-encode every remembered cell over several frames (load, restore, new seed).
func _queue_cover_rewrite() -> void:
	_cover_pending.clear()
	_cover_pending_cursor = 0
	if _intel == null or _cover == null:
		return
	for cell in _intel.resource_observations.rows:
		_cover_pending.append(int(cell))

func _drain_cover_pending(deadline: int) -> void:
	while _cover_pending_cursor < _cover_pending.size() and Time.get_ticks_usec() < deadline:
		_write_cover(_cover_pending[_cover_pending_cursor])
		_cover_pending_cursor += 1
	if _cover_pending_cursor >= _cover_pending.size() and not _cover_pending.is_empty():
		_cover_pending.clear()
		_cover_pending_cursor = 0

## Ground cover texel for one cell, from remembered observations only.
func _write_cover(cell: int) -> void:
	if _cover == null or _map == null or cell < 0 or cell >= _map.cell_count():
		return
	var row: Dictionary = _intel.resource_observations.rows.get(cell, {})
	var bands: PackedByteArray = row.get("bands", PackedByteArray())
	var water := cell < _map.is_water_arr.size() and _map.is_water_arr[cell] != 0
	var cores := _intel.settlement_core_buckets()
	var core := int(cores[cell]) if cell < cores.size() else 0
	_cover.write_cell(cell, _cover.encode_cell(bands, water, core,
		func(style: int, band: int) -> bool: return world_presence_allowed(cell, style, band)))

func ground_cover() -> ResourceGroundCover:
	return _cover

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
			# Settlement cores clear wild cover; re-encode the changed cells.
			if _intel != null and _intel.resource_observations.rows.has(cell):
				_write_cover(cell)

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
# 动物是真实比例的小兽群，水产与水下油气是水下贴花。植物不再是实例：它们是
# ResourceGroundCover 里跨格连续的野生群落，这里只保留透镜徽章。
static func visual_plan(entry: Dictionary, source_water: bool) -> int:
	var family := int(entry.family)
	var form := int(entry.form)
	if source_water:
		return PLAN_SUBMERGED if family == 3 or form == 21 or form == 25 else 0
	if family == 3:
		return PLAN_SUBMERGED # River fish: only where the river body itself passes.
	if form == 26:
		return PLAN_BADGE # 木材：森林本身就是木材，世界里不再叠原木，只保留透镜徽章。
	if family == 0:
		return PLAN_BADGE # 植物群落由地被层绘制。
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
		var prop_radius := _hex * prop_diameter * 0.5 * size_scale
		if render_family == 1:
			# Real-scale herd: the quad only has to contain herd_size_max animals.
			prop_radius = _hex * herd_radius_hex() * size_scale
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
		node.material = _material_for(family)
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
				copy.material = _material_for(family)
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
	# shader在第143-144行从X=0.25和X=0.75采样
	# 在4像素宽的纹理中：0.25→像素1(颜色)，0.75→像素3(元数据)
	var image := Image.create(4, 64, false, Image.FORMAT_RGBAF)
	_max_style_scale = 1.0
	for i in _styles.size():
		var e := _styles[i]
		var override: Dictionary = profile.style_overrides.get(e.id, {})
		_max_style_scale = maxf(_max_style_scale, float(override.get("size_scale", 1.0)))
		# X=0.25采样（像素1）：颜色数据
		var color_val = override.get("color", e.color) if override.has("color") else e.color
		image.set_pixel(1, i, color_val)
		# X=0.75采样（像素3）：元数据(form, family, sub_style, metallic)
		image.set_pixel(3, i, Color(float(e.form), float(e.family), float(e.get("sub_style", i % 4)), float(e.get("metallic", 0.0))))
		# X=0.625采样（像素2）：动物/鱼位图（-, 图集层+1, 图集精灵数, -）；0 = 无位图。
		# 植物位图由 ResourceGroundCover 自己的 LUT 映射。
		var art := ResourceArtLibrary.shared()
		var fauna_layer := art.fauna_layer(e.id)
		image.set_pixel(2, i, Color(0.0, float(fauna_layer + 1),
			float(art.fauna_count) if fauna_layer >= 0 else 0.0, 0.0))
	_set_param("style_lut", ImageTexture.create_from_image(image))
	_bind_art()

func _bind_art() -> void:
	var art := ResourceArtLibrary.shared()
	_set_param("art_fauna_bound", art.fauna != null)
	if art.fauna != null:
		_set_param("art_fauna", art.fauna)

func diagnostics() -> Dictionary:
	var result := _stats.duplicate()
	result.merge({"instances": _instance_count, "resident_chunks": _resident.size(),
		"pending_uploads": _uploads.size(), "dirty_chunks": _dirty.size(),
		"known_cells": _intel.resource_observations.rows.size() if _intel != null else 0,
		"ground_cover": _cover.diagnostics() if _cover != null else {},
		"quality": quality(), "mobile": _mobile_tier >= 0, "catalog": Catalog.audit(_styles)})
	return result

static func _hash(cell: int, salt: int) -> float:
	var value := ((cell + 1) * 1103515245 + (salt + 71) * 12345) & 0x7fffffff
	value = ((value ^ (value >> 13)) * 1274126177) & 0x7fffffff
	return float(value) / 2147483647.0
