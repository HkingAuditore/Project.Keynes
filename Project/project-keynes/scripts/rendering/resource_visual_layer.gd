class_name ResourceVisualLayer
extends Node2D
const ResourceInstancePlan = preload("res://scripts/rendering/resource_instance_plan.gd")
const Materials = preload("res://scripts/rendering/resource_visual_materials.gd")
const Geometry = preload("res://scripts/rendering/resource_visual_geometry.gd")
const ChunkInputs = preload("res://scripts/rendering/resource_visual_chunk_inputs.gd")
const ObservationQueue = preload("res://scripts/rendering/resource_visual_work_queue.gd")

const ResourceShaderVariants = preload("res://scripts/rendering/resource_shader_variants.gd")


const Catalog = preload("res://scripts/rendering/resource_visual_catalog.gd")
const Profile = preload("res://scripts/data/resource_visual_profile.gd")
const DEFAULT_PROFILE = preload("res://data/visual/resource_default.tres")
const RESOURCE_SHADER = ResourceShaderVariants.RESOURCE_SHADER
const GroundCover = preload("res://scripts/rendering/resource_ground_cover.gd")
const FAMILY_COUNT := 4
const INSTANCE_SCALE_MIN = Geometry.INSTANCE_SCALE_MIN
const INSTANCE_SCALE_MAX = Geometry.INSTANCE_SCALE_MAX
const INSTANCE_ASPECT_MIN = Geometry.INSTANCE_ASPECT_MIN
const INSTANCE_ASPECT_MAX = Geometry.INSTANCE_ASPECT_MAX
# Batches 0..3 = prop subjects per family (3 = submerged cues); 4 = ground decals,
# drawn first so props always sit on top of their own scar/soil patch.
const BATCH_COUNT := 5
const DECAL_BATCH = Geometry.DECAL_BATCH
const STRIDE = ResourceInstancePlan.STRIDE
const RESOURCE_Z := 1 # 与植被共用父级：地表(0) < 资源/建筑投影(1) < 建筑主体(2) < 树冠(3)。
# Instance kind lives in COLOR.a: integer part = kind, +0.5 = not the lens badge carrier.
const KIND_PROP = Geometry.KIND_PROP
const KIND_DECAL = Geometry.KIND_DECAL
const KIND_SUBMERGED = Geometry.KIND_SUBMERGED
const KIND_BADGE_ONLY = Geometry.KIND_BADGE_ONLY
const NON_CARRIER = Geometry.NON_CARRIER
const PLAN_PROP = ResourceInstancePlan.PLAN_PROP
const PLAN_DECAL = ResourceInstancePlan.PLAN_DECAL
const PLAN_SUBMERGED = ResourceInstancePlan.PLAN_SUBMERGED
const PLAN_BADGE = ResourceInstancePlan.PLAN_BADGE
# clay, sand, soil (fertile/arable/paddy/plantation/pasture), game tracks, land seep, land gas.
const GROUND_FORMS = ResourceInstancePlan.GROUND_FORMS
# rock, vein, crystal: a bare scar decal plus a small pebble prop.
const DEPOSIT_FORMS = ResourceInstancePlan.DEPOSIT_FORMS

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
const MAP_VISUAL_TILED_DEFINE = ResourceShaderVariants.MAP_VISUAL_TILED_DEFINE
const WEB_MIN_QUALITY_DEFINE = ResourceShaderVariants.WEB_MIN_QUALITY_DEFINE
const WEB_MIN_DEFINE = ResourceShaderVariants.WEB_MIN_DEFINE
## [web-two-pass] 同一份 .gdshader 编成两份程序：surface / geology。
## 依据与实测见 shaders/resource_impostor.gdshader 的 [web-two-pass] 段与
## tmp/next/resource_cliff_IMPL.md。
const WEB_PASS_SURFACE_DEFINE = ResourceShaderVariants.WEB_PASS_SURFACE_DEFINE
const WEB_PASS_GEOLOGY_DEFINE = ResourceShaderVariants.WEB_PASS_GEOLOGY_DEFINE
## batch 2 = 矿物道具（form 16/17/18 → rt_geology_solid）。其余 batch 都是 surface。
const MINERAL_BATCH := 2

## 本图层是否走 web/GLES3 精简变体。web 上 is_compatibility_renderer() 恒 true
## （feature_flags.gd:464-465），桌面 Forward+/Mobile 恒 false → 桌面路径不变。
static func web_min_active() -> bool:
	return ResourceShaderVariants.web_min_active()


## 运行期真正会交给驱动的那份源码前缀（tiled 只可能出现在桌面）。
## 这是 **surface** pass 的前缀；矿物 batch 用 geology_variant_prefix()。
static func shader_variant_prefix(tiled: bool, cloud_shadow_direct: bool = false) -> String:
	return ResourceShaderVariants.shader_variant_prefix(tiled, cloud_shadow_direct)


## 矿物 batch（batch 2）那份程序的前缀。除 pass 宏外与 surface **逐字相同**：
## 两份程序共享同一套 uniform，差一个字节驱动就不认缓存。
static func geology_variant_prefix(tiled: bool, cloud_shadow_direct: bool = false) -> String:
	return ResourceShaderVariants.geology_variant_prefix(tiled, cloud_shadow_direct)


## 菜单期预热用：与运行期首次绘制时的前缀**同源**。非 web 返回空串（预热本身只在
## web 上跑，见 WebShaderWarmup.run）。web 上 visual_tiles 恒为 null
## （map_baker.gd:1276-1279），所以运行期的 tiled 也是 false，两份前缀逐字相同。
static func warmup_prefix() -> String:
	return ResourceShaderVariants.warmup_prefix()


## 菜单期预热用：geology 那份的前缀（与运行期 geology_variant_prefix(false) 同源）。
static func geology_warmup_prefix() -> String:
	return ResourceShaderVariants.geology_warmup_prefix()


## 菜单期预热用：返回运行期真正会交给驱动的那份源码。WebShaderWarmup 只负责调它，
## 不自己拼宏串（差一个字节驱动就不认缓存、预热白做）。
static func compose_shader_code(source: Shader) -> String:
	return ResourceShaderVariants.compose_shader_code(source)


## 菜单期预热：web 上本图层有**两份**程序，必须各编一遍，否则进世界还会再编一次。
## 返回 {label: code}，与 ShrubLayer.web_warmup_shader_codes() 同构，
## 让 WebShaderWarmup 只负责遍历、不自己拼宏串。
static func web_warmup_shader_codes() -> Dictionary:
	return ResourceShaderVariants.web_warmup_shader_codes()


@export var profile: ResourceVisualProfile = DEFAULT_PROFILE
var _map: MapData
var _world: WorldData
var _intel: BuildingVisualIntelCache
var _styles: Array[Dictionary] = []
var _geometry_styles: Geometry.StyleInputs
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
var _chunk_inputs := ChunkInputs.new()
var _active: Dictionary = {}
var _resident: Dictionary = {}
var _dirty: Dictionary = {}
var _build_round: Dictionary = {}
var _chunk_revisions: Dictionary = {}
var _published_chunk_revisions: Dictionary = {}
var _job: Dictionary = {}
var _uploads: Array[Dictionary] = []
var _upload_turn := 0
var _near_cells: Array[int] = []
var _observation_queue := ObservationQueue.new()
var _frame_work_usec := 0
var _frame_budget_usec := 0
var _frame_budget_active := false
var _material: ShaderMaterial
## 矿物 batch 专用材质（web 上是 geology pass 那份程序；桌面与 _material 指向同一资源）。
var _material_geo: ShaderMaterial
var _shader_tiled := false
## 上一次真正写进 _material.shader 的编译期前缀（见 shader_variant_prefix）。
var _shader_prefix := ""
## 同上，geology pass 的前缀。
var _shader_geo_prefix := ""
var _cloud_shadow_direct := false
var _cloud_shadow_texture: Texture2D
var _cloud_shadow_wrap_origin_uv := 0.0
var _cloud_shadow_wrap_period_uv := 0.0
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
var _cover_queued: Dictionary = {}
var _stats := {"observed_cells": 0, "rebuilt_chunks": 0, "uploads": 0,
	"last_observe_ms": 0.0, "last_build_ms": 0.0, "last_upload_ms": 0.0,
	"max_upload_ms": 0.0, "stale_jobs": 0, "built_cells": 0,
	"last_setup_ms": 0.0, "last_cover_ms": 0.0, "last_observed_cells": 0,
	"last_built_cells": 0, "last_build_steps": 0, "last_packed_batches": 0, "last_cover_cells": 0}

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
	if _map != null and _map.resource_visual_inputs_changed.is_connected(notify_resource_inputs):
		_map.resource_visual_inputs_changed.disconnect(notify_resource_inputs)
	_map = map
	_world = world
	_intel = intel
	_hex = maxf(4.0, hex_size)
	_observation_queue.configure(_map.cell_count() if _map != null else 0)
	_near_cells.clear()
	_chunk_inputs.clear()
	_styles = Catalog.entries()
	_geometry_styles = Geometry.StyleInputs.new(_styles)
	var audit := Catalog.audit(_styles)
	if not bool(audit.ok) or _map == null or _intel == null:
		return audit if not bool(audit.ok) else {"ok": false, "reason": "resource_visual_context_missing"}
	_map.resource_visual_inputs_changed.connect(notify_resource_inputs)
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
		_cover.set_cloud_shadow_field(_cloud_shadow_texture, _cloud_shadow_direct,
			_cloud_shadow_wrap_origin_uv, _cloud_shadow_wrap_period_uv)
		_sync_terrain_textures()
	_refresh_filter_style()
	_apply_profile()
	_last_intel = null
	_sync_restored_memory()
	set_camera_view(_camera, _center, _zoom)
	_configured = true
	return audit

func _sync_terrain_textures() -> void:
	Materials._sync_terrain_textures(self)



func set_cloud_shadow_field(texture: Texture2D, direct_enabled: bool,
		wrap_origin_uv: float, wrap_period_uv: float) -> void:
	Materials.set_cloud_shadow_field(self, texture, direct_enabled, wrap_origin_uv, wrap_period_uv)



func _push_cloud_shadow_uniforms() -> void:
	Materials._push_cloud_shadow_uniforms(self)


## 桌面（且未 tiled，prefix 为空）：与改动前逐字相同，直接把源文件资源交给材质，
## 不产生任何新的 Shader 实例 ⇒ 桌面走的就是 preload 的那一份。
func _assign_variant(target: ShaderMaterial, prefix: String) -> void:
	Materials._assign_variant(self, target, prefix)



## 每个 uniform 都要推到**两份** impostor 材质上：web 的两份程序共享同一套 uniform，
## 漏推一份就是"另一份 pass 画错/不画"。
## 注意不包含 ground cover：那是另一张 shader（resource_ground_cover.gdshader），
## 它的 uniform 集合不同，由 _bind_terrain_textures / configure 单独推。
func _set_param(name: String, value) -> void:
	Materials._set_param(self, name, value)



func _material_for(family: int) -> ShaderMaterial:
	return Materials._material_for(self, family)



func _materials() -> Array[ShaderMaterial]:
	return Materials._materials(self)


func _bind_terrain_textures(target: ShaderMaterial, tiles, tiled: bool) -> void:
	Materials._bind_terrain_textures(self, target, tiles, tiled)


# 复用地形/树木的参数；同时覆盖异步 horizon bake 完成后的重新绑定。
func set_terrain_lighting(source: ShaderMaterial) -> void:
	Materials.set_terrain_lighting(self, source)


func _apply_profile() -> void:
	Materials._apply_profile(self)


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
	_observation_queue.request(ObservationQueue.ALL)
	_observation_queue.request(ObservationQueue.ALL, PackedInt32Array(_near_cells))
	if _map != null and _intel != null:
		_chunk_inputs.prepare_view(_map, _near_cells, _cell_chunk, _intel.resource_observations.rows, _fog)
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

## 当前运行期画质档（推给 resource_impostor / resource_ground_cover 的 visual_quality）。
##
## [android-runtime-quality 2026-11-17] `_mobile_tier` 只表示"受限平台"：分块驻留、
## 实例预算走 mobile 分支（见 _resident_cap / instance_cap 的第二个参数）。它**不再
## 兼任画质档**——那是编译期 shader tier，被 player_game 钉死在 LOW，拿它当画质会让
## 设置里的"最高画质"在资源/点缀上完全无效：visual_quality 恒为 0 ⇒ `detailed_view`
## 永远 false ⇒ 道具只剩 !detailed 的简化形体（远看就是一块块纯色方块），
## cell_cap/type_cap/instance_cap 也全按 quality0 取值。
## web 侧一直是运行期档权威（见 shrub/scatter.gd 同款注释），移动端向它对齐。
func quality() -> int:
	return clampi(_quality, 0, 2)


## 密度档：移动端整体降一档，着色仍用 quality()。
##
## [mobile-density-trim 2026-11-17] 作者定夺：点缀数量可以少一半，但保留 HIGH 的
## 着色与光照。只有 cell_cap / type_cap / instance_cap 读这个函数；
## `visual_quality` uniform（= quality()）不变。
func density_quality() -> int:
	var q := quality()
	return mini(q, 1) if DCFeatureFlags.density_trim_enabled() else q

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
		_build_round.clear()
		_near_cells.clear()
		for key in _active:
			for cell in _chunks[key]:
				_near_cells.append(int(cell))
		# Prioritize entering the camera without restarting the global sweep.
		if not _near_cells.is_empty():
			var unknown: PackedInt32Array = _chunk_inputs.prepare_view(_map, _near_cells,
				_cell_chunk, _intel.resource_observations.rows, _fog)
			if not unknown.is_empty():
				_observation_queue.request(ObservationQueue.ALL, unknown)
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
	var frame_begin := Time.get_ticks_usec()
	_frame_work_usec = 0
	for field in ["last_observed_cells", "last_built_cells", "last_build_steps", "last_packed_batches", "last_cover_cells"]:
		_stats[field] = 0
	_stats.last_upload_ms = 0.0
	_frame_budget_usec = int(float(profile.frame_budget_ms) * 1000.0)
	_frame_budget_active = true
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
	_stats.last_setup_ms = float(begin - frame_begin) / 1000.0
	var deadline := frame_begin + _frame_budget_usec
	# Leave room for building and the separately scheduled upload. Each phase
	# uses the same CPU allowance; idle time between callers is not charged.
	var observe_deadline := mini(deadline, frame_begin + mini(
		int(float(profile.observation_budget_ms) * 1000.0), int(_frame_budget_usec * 0.45)))
	_drain_cover_pending(mini(observe_deadline, begin + int(_frame_budget_usec * 0.10)))
	_stats.last_cover_ms = float(Time.get_ticks_usec() - begin) / 1000.0
	begin = Time.get_ticks_usec()
	_observe_until(observe_deadline)
	_stats.last_observe_ms = float(Time.get_ticks_usec() - begin) / 1000.0
	begin = Time.get_ticks_usec()
	# Reserve CPU only for an upload that is actually due. An empty upload
	# slot belongs to construction; the shared allowance itself is unchanged.
	_build_until(mini(deadline - _upload_reserve_usec(Time.get_ticks_msec()),
		begin + int(float(profile.build_budget_ms) * 1000.0)))
	_stats.last_build_ms = float(Time.get_ticks_usec() - begin) / 1000.0
	_frame_work_usec = Time.get_ticks_usec() - frame_begin
	_stats.last_frame_work_ms = float(_frame_work_usec) / 1000.0

func _observe_until(deadline: int) -> void:
	if _allowed.size() != _styles.size():
		return
	var observations = _intel.resource_observations
	while _observation_queue.pending() and Time.get_ticks_usec() < deadline:
		var task: Vector2i = _observation_queue.take()
		var cell := task.x
		if cell < 0:
			break
		_chunk_inputs.complete(cell)
		if _fog and (cell >= _map.visible_arr.size() or _map.visible_arr[cell] == 0):
			continue
		var full: bool = (task.y & ObservationQueue.BANDS) != 0 or not observations.rows.has(cell)
		var changed := false
		if full:
			changed = observations.observe(_map, cell, _allowed, not _fog)
			_stats.observed_cells = int(_stats.observed_cells) + 1
		else:
			observations.observe_climate(_map, cell, not _fog)
			_stats.climate_observed_cells = int(_stats.get("climate_observed_cells", 0)) + 1
		_stats.last_observed_cells = int(_stats.last_observed_cells) + 1
		var row: Dictionary = observations.rows.get(cell, {})
		_write_memory_pixel(cell, row.get("climate", Color(0.5, 0.5, 0, 1)))
		if changed or (task.y & ObservationQueue.GEOMETRY) != 0:
			_write_cover(cell)
			_mark_chunk_dirty(_cell_chunk[cell])

func _sync_restored_memory() -> void:
	if _last_intel == _intel.resource_observations:
		return
	if _last_intel != null:
		_clear_geometry()
	_last_intel = _intel.resource_observations
	_observation_queue.configure(_map.cell_count())
	_observation_queue.request(ObservationQueue.ALL)
	_chunk_inputs.prepare_view(_map, _near_cells, _cell_chunk, _intel.resource_observations.rows, _fog)
	if not _near_cells.is_empty():
		_observation_queue.request(ObservationQueue.ALL, PackedInt32Array(_near_cells))
	_memory_image.fill(Color(0, 0, 0, 0))
	_memory_dirty = true
	if _cover != null:
		_cover.clear_cells()
	_queue_cover_rewrite()
	_invalidate()

## Re-encode every remembered cell over several frames (load, restore, new seed).
func _queue_cover_rewrite() -> void:
	_cover_pending.clear()
	_cover_pending_cursor = 0
	_cover_queued.clear()
	if _intel == null or _cover == null:
		return
	for cell in _intel.resource_observations.rows:
		_cover_pending.append(int(cell))
		_cover_queued[int(cell)] = true

func _drain_cover_pending(deadline: int) -> void:
	while _cover_pending_cursor < _cover_pending.size() and Time.get_ticks_usec() < deadline:
		var cell := _cover_pending[_cover_pending_cursor]
		_cover_queued.erase(cell)
		var row: Dictionary = _intel.resource_observations.rows.get(cell, {})
		if not row.is_empty():
			_write_memory_pixel(cell, row.climate)
		_write_cover(cell)
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
	_stats.last_cover_cells = int(_stats.last_cover_cells) + 1
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
			_mark_chunk_dirty(_cell_chunk[cell])
			# Settlement cores clear wild cover; re-encode the changed cells.
			if _intel != null and _intel.resource_observations.rows.has(cell):
				if not _cover_queued.has(cell):
					_cover_pending.append(cell)
					_cover_queued[cell] = true

func notify_resource_inputs(flags: int, cells: PackedInt32Array = PackedInt32Array()) -> void:
	_observation_queue.request(flags, cells)

func _mark_chunk_dirty(key: Vector2i) -> void:
	_dirty[key] = true
	_chunk_revisions[key] = int(_chunk_revisions.get(key, 0)) + 1
	# Finish the current chunk and its five uploads. Later observations coalesce
	# into one redo behind existing dirty chunks, never discard a built prefix.
	# Uploads reject generations older than one already visible, not merely
	# older than inputs that still need to be built.

func _invalidate() -> void:
	_revision += 1
	_build_round.clear()
	_job.clear()
	_uploads.clear()
	for key in _active:
		_dirty[key] = true

func _build_until(deadline: int) -> void:
	Geometry._build_until(self, deadline)


func selected_styles(cell: int) -> PackedInt32Array:
	return Geometry.selected_styles(self, cell)


# 概率按格/资源固定，只判定一次，不能放进候选位置重试，否则八次尝试会抹平稀疏度。
# 这里只控制实景；观测、资源列表、储量和生物占领完全不变。
func world_presence_allowed(cell: int, style: int, band: int) -> bool:
	return Geometry.world_presence_allowed(self, cell, style, band)


# 世界实景只做美术点缀：土地类是软边地面贴花，矿床是“裸露矿斑贴花 + 小件碎石”，
# 动物是真实比例的小兽群，水产与水下油气是水下贴花。植物不再是实例：它们是
# ResourceGroundCover 里跨格连续的野生群落，这里只保留透镜徽章。
static func visual_plan(entry: Dictionary, source_water: bool) -> int:
	return ResourceInstancePlan.visual_plan(entry, source_water)

func _append_cell(cell: int, buffers: Array) -> void:
	Geometry._append_cell(self, cell, buffers)


# Axis-aligned quad with independent X/Y radii; the shader rotates the material
# sampling internally so footprints keep no rotated collision corners.
# COLOR.g carries light transmission through water (1 on land).
func _emit(buffer: Array, point: Vector2, radius: Vector2, rank: int, cell: int, style: int,
		variation: float, band: int, importance: float, kind: float, transmission: float = 1.0) -> void:
	Geometry._emit(self, buffer, point, radius, rank, cell, style, variation, band, importance, kind, transmission)


# Deterministic silhouette variation. Herds keep a square quad because their bitmap
# sprites already vary heading and body scale; props/decals use area-preserving aspect.
func _instance_scale(cell: int, style: int, family: int) -> Vector2:
	return Geometry._instance_scale(self, cell, style, family)


# Deep water hides the seabed: same falloff the old terrain-shader path used.
func _water_transmission(cell: int) -> float:
	return Geometry._water_transmission(self, cell)


func candidate_allowed(point: Vector2, family: int, source_domain: int = -1) -> bool:
	return Geometry.candidate_allowed(self, point, family, source_domain)


func _patch_noise(point: Vector2) -> float:
	return Geometry._patch_noise(self, point)


func _upload_reserve_usec(now_msec: int) -> int:
	var due := ((_cover != null and _cover.can_flush(now_msec))
		or (_memory_dirty and now_msec - _last_texture_msec >= 100))
	return int(_frame_budget_usec * 0.20) if due else 0

# Called by HexRenderer only when the shared detail scheduler grants an upload.
func drain_one_upload() -> bool:
	if not _configured or not profile.enabled:
		return false
	if _frame_budget_active and _frame_work_usec >= _frame_budget_usec:
		return false
	var begin := Time.get_ticks_usec()
	var uploaded := _drain_one_upload()
	var elapsed := Time.get_ticks_usec() - begin
	_frame_work_usec += elapsed
	_stats.last_upload_ms = float(elapsed) / 1000.0
	_stats.max_upload_ms = maxf(float(_stats.max_upload_ms), float(_stats.last_upload_ms))
	_stats.last_frame_work_ms = float(_frame_work_usec) / 1000.0
	return uploaded

func _drain_one_upload() -> bool:
	return Geometry._drain_one_upload(self)


static func _keep_important_instances(buffer: PackedFloat32Array, count: int) -> PackedFloat32Array:
	return ResourceInstancePlan._keep_important_instances(buffer, count)

func _sync_wrap_visibility(key: Vector2i) -> void:
	Geometry._sync_wrap_visibility(self, key)


func _detail_visible() -> bool:
	return Geometry._detail_visible(self)


func _remove_node(node: MultiMeshInstance2D) -> void:
	Geometry._remove_node(self, node)


func _evict(key: Vector2i) -> void:
	Geometry._evict(self, key)


func _clear_geometry() -> void:
	Geometry._clear_geometry(self)


func _build_style_texture() -> void:
	Materials._build_style_texture(self)


func _bind_art() -> void:
	Materials._bind_art(self)


func diagnostics() -> Dictionary:
	var result := _stats.duplicate()
	result.merge(_observation_queue.diagnostics())
	result.merge({"instances": _instance_count, "resident_chunks": _resident.size(),
		"pending_uploads": _uploads.size(), "dirty_chunks": _dirty.size(),
		"initial_observation_cells": _chunk_inputs.pending_cells(),
		"job_cursor": int(_job.get("cursor", 0)),
		"job_cells": _chunks[_job.key].size() if not _job.is_empty() else 0,
		"known_cells": _intel.resource_observations.rows.size() if _intel != null else 0,
		"ground_cover": _cover.diagnostics() if _cover != null else {},
		"quality": quality(), "mobile": _mobile_tier >= 0, "catalog": Catalog.audit(_styles)})
	return result

static func _hash(cell: int, salt: int) -> float:
	return ResourceInstancePlan._hash(cell, salt)
