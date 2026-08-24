# fog_of_war_layer.gd
# 三态视野迷雾层。
#
# 与 DataOverlayLayer / WeatherLayer 同一套机制：一张覆盖 world_bounds 的
# quad + map_index_atlas 逐像素解 cell.index + per-cell LUT 间接寻址。
# 之所以不用 GPU instance 画六边形：2400 格 × 3 份 wrap 副本 = 7200 instance，
# 每次视野变化都要重传 instance buffer，六边形还是硬边、得额外羽化；而 LUT 方案
# 是 1 个 draw call、0 几何，视野变化只需重写 2400 个 texel。map_index_atlas 在
# 烘焙期提供硬主索引 + 独立邻格/距离场，Shader 只混合显示用知识度。
#
# 迷雾值不占独立纹理：它住在 enum_lut 的 A 通道（知识度 k），主地形已经无条件
# 采样 enum_lut，因此灰化与早退都是零新增 texture sample。本层复用同一张 LUT。
#
# z_index = 12：必须盖住 WeatherLayer(4) / DataOverlayLayer(5) /
# CountryBorderLayer(6) / CellHighlight(10) —— 未探索区不该漏出任何信息。
class_name FogOfWarLayer
extends Node2D

const SHADER_PATH: String = "res://shaders/fog_of_war.gdshader"

## 未探索厚云的基础反照率，必须与 fog_of_war.gdshader 的 unexplored_color 默认值一致。
## world_map.gdshader 的早退分支输出同一个颜色；只有 q0（无光照）时两者才真的对得齐，
## 见 supports_terrain_early_out()。
const UNEXPLORED_COLOR := Color(0.52, 0.56, 0.64)

var _mesh_inst: MeshInstance2D
var _shader_mat: ShaderMaterial
var _bounds: Rect2 = Rect2()
var _wrap_period_x: float = 0.0
var _hex_size: float = 22.0
var _has_valid_shader: bool = false
var _has_atlas: bool = false
var _edge_neighbor_tex: Texture2D = null
var _edge_distance_tex: Texture2D = null
var _edge_transition_width: float = 0.84
var _enabled: bool = true
var _world_time: float = 0.0
var _visual_tiles = null
# 与 WeatherLayer 同一表现时钟语义：运行时按游戏倍速推进；暂停时保留 1x 环境运动，
# 避免整个大气层完全冻结。
var _clock_running: bool = true
var _clock_speed_multiplier: float = 1.0

# 质量：编译期 tier 卡上限（低端机整段代码不编进去），运行时 _fog_quality 在上限内再降。
var _mobile_quality_tier_define: String = ""
var _fog_quality: int = 3

# TOD：earth_daylight 的三个相位 uniform 与调试项，与 WeatherLayer 同套。
var _day_night_enabled: bool = true
var _day_phase: float = 0.25
var _season_phase: float = 1.0
var _axial_tilt_rad: float = 0.4101523
var _tod_debug_sun_position_enabled: bool = false
var _tod_debug_sun_uv: Vector2 = Vector2(0.25, 0.5)
var _tod_debug_sun_height_scale: float = 1.0


func _ready() -> void:
	z_index = 12
	top_level = true
	visible = false
	_ensure_nodes()
	set_process(true)


func _process(delta: float) -> void:
	if not visible or _shader_mat == null:
		return
	var visual_time_scale := _clock_speed_multiplier if _clock_running else 1.0
	_world_time += delta * visual_time_scale
	_shader_mat.set_shader_parameter("world_time", _world_time)


func _ensure_nodes() -> void:
	if _mesh_inst != null:
		return
	_mesh_inst = MeshInstance2D.new()
	_mesh_inst.name = "FogQuad"
	_mesh_inst.texture = DataOverlayBaker.get_empty_texture()
	add_child(_mesh_inst)

	var sh: Shader = _load_shader()
	if sh == null:
		push_warning("FogOfWarLayer: failed to load shader '%s'; fog disabled" % SHADER_PATH)
		_has_valid_shader = false
		return
	_shader_mat = ShaderMaterial.new()
	_shader_mat.shader = sh
	var empty := DataOverlayBaker.get_empty_texture()
	_shader_mat.set_shader_parameter("map_index_atlas", empty)
	_shader_mat.set_shader_parameter("enum_lut", empty)
	_shader_mat.set_shader_parameter("lut_dims", Vector2(1.0, 1.0))
	_shader_mat.set_shader_parameter("fog_enabled", true)
	_shader_mat.set_shader_parameter("unexplored_color", UNEXPLORED_COLOR)
	_mesh_inst.material = _shader_mat
	_has_valid_shader = true
	_push_quality()
	_push_tod()
	_push_edge_transition_data()


## 编译期质量档：mobile/web 共用 MOBILE_QUALITY_*；桌面不 prepend。
func _load_shader() -> Shader:
	var sh := ResourceLoader.load(SHADER_PATH, "Shader", ResourceLoader.CACHE_MODE_IGNORE) as Shader
	if sh == null:
		return null
	var prefix := "#define MAP_VISUAL_TILED\n" if _visual_tiles_active() else ""
	if _mobile_quality_tier_define != "" and DCFeatureFlags.uses_shader_quality_tier():
		prefix += _shader_quality_define_prefix(_mobile_quality_tier_define)
	if not prefix.is_empty():
		sh = sh.duplicate() as Shader
		sh.code = prefix + sh.code
	return sh


func set_visual_tiles(tiles) -> void:
	var was_tiled := _visual_tiles_active()
	_visual_tiles = tiles
	if _shader_mat != null and was_tiled != _visual_tiles_active():
		var sh := _load_shader()
		if sh != null:
			_shader_mat.shader = sh
	_push_visual_tile_uniforms()
	_push_edge_transition_data()


func _visual_tiles_active() -> bool:
	return _visual_tiles != null and bool(_visual_tiles.ready) \
		and String(_visual_tiles.layout.mode) == "tiled"


func _push_visual_tile_uniforms() -> void:
	if _shader_mat == null or not _visual_tiles_active():
		return
	var layout = _visual_tiles.layout
	_shader_mat.set_shader_parameter("visual_map_index_tiles", _visual_tiles.map_index)
	_shader_mat.set_shader_parameter("visual_edge_neighbor_tiles", _visual_tiles.edge_neighbor)
	_shader_mat.set_shader_parameter("visual_edge_distance_tiles", _visual_tiles.edge_distance)
	_shader_mat.set_shader_parameter("visual_domain_origin", layout.visual_domain.position)
	_shader_mat.set_shader_parameter("visual_domain_size", layout.visual_domain.size)
	_shader_mat.set_shader_parameter("visual_grid_size", Vector2(layout.grid_size))
	_shader_mat.set_shader_parameter("visual_interior_size", Vector2(layout.interior_size))
	_shader_mat.set_shader_parameter("visual_layer_size", Vector2(layout.layer_size))
	_shader_mat.set_shader_parameter("visual_logical_resolution", Vector2(layout.logical_size))
	_shader_mat.set_shader_parameter("visual_gutter_px", float(layout.gutter_px))


func _shader_quality_define_prefix(tier_define: String) -> String:
	match tier_define:
		"MOBILE_QUALITY_LOW":
			return "#define MOBILE_QUALITY_LOW\n#define PK_SHADER_TIER_LOW\n"
		"MOBILE_QUALITY_HIGH":
			return "#define MOBILE_QUALITY_HIGH\n#define PK_SHADER_TIER_HIGH\n"
		_:
			return "#define MOBILE_QUALITY_MID\n#define PK_SHADER_TIER_MID\n"


## 移动端编译期档位。切换时必须重载 shader 让 #define 生效。
func set_mobile_quality_tier(tier_define: String) -> void:
	if _mobile_quality_tier_define == tier_define:
		return
	_mobile_quality_tier_define = tier_define
	if _shader_mat != null:
		var sh := _load_shader()
		if sh != null:
			_shader_mat.shader = sh
			_push_quality()
			_push_tod()
			_push_edge_transition_data()


## 一次性配置。atlas 与 enum_lut 都是世界生命周期内稳定的纹理对象
## （enum_lut 每日通过 ImageTexture.update() 原地刷新，不换对象）。
func setup(
	bounds: Rect2,
	map_index_atlas: Texture2D,
	lut_dims: Vector2i,
	hex_size: float,
	wrap_period_x: float
) -> void:
	_ensure_nodes()
	_hex_size = maxf(1.0, hex_size)
	_wrap_period_x = maxf(0.0, wrap_period_x)
	set_bounds(bounds)
	if _shader_mat == null:
		return
	var empty := DataOverlayBaker.get_empty_texture()
	if not _visual_tiles_active():
		_shader_mat.set_shader_parameter(
			"map_index_atlas",
			map_index_atlas if map_index_atlas != null else empty
		)
	_push_visual_tile_uniforms()
	_shader_mat.set_shader_parameter(
		"lut_dims",
		Vector2(maxi(1, lut_dims.x), maxi(1, lut_dims.y))
	)
	# hex 外接圆半径 → 直径（噪声域扭曲的位移尺度基准）。
	_shader_mat.set_shader_parameter("hex_world_diameter", _hex_size * 2.0)
	_has_atlas = map_index_atlas != null and lut_dims.x > 0 and lut_dims.y > 0
	_update_visibility()


## enum_lut（A 通道 = 知识度 k）。日刷时 ImageTexture 对象不变，只有首次绑定
## 与 regenerate 才需要重新调用。
func set_enum_lut_texture(tex: Texture2D) -> void:
	_ensure_nodes()
	if _shader_mat == null:
		return
	_shader_mat.set_shader_parameter(
		"enum_lut",
		tex if tex != null else DataOverlayBaker.get_empty_texture()
	)
	_update_visibility()


func set_edge_transition_data(
	neighbor_tex: Texture2D,
	distance_tex: Texture2D,
	width: float
) -> void:
	_edge_neighbor_tex = neighbor_tex
	_edge_distance_tex = distance_tex
	_edge_transition_width = clampf(width, 0.0, 0.96)
	_push_edge_transition_data()


func _push_edge_transition_data() -> void:
	if _shader_mat == null:
		return
	var empty := DataOverlayBaker.get_empty_texture()
	var ready := _visual_tiles_active() or (_edge_neighbor_tex != null and _edge_distance_tex != null)
	if not _visual_tiles_active():
		_shader_mat.set_shader_parameter(
			"terrain_edge_neighbor_tex",
			_edge_neighbor_tex if _edge_neighbor_tex != null else empty
		)
		_shader_mat.set_shader_parameter(
			"terrain_edge_distance_tex",
			_edge_distance_tex if _edge_distance_tex != null else empty
		)
	_shader_mat.set_shader_parameter("has_terrain_edge_data", ready)
	_shader_mat.set_shader_parameter("terrain_ecotone_width", _edge_transition_width)


func set_bounds(bounds: Rect2) -> void:
	if bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
		return
	_bounds = bounds
	_ensure_nodes()
	if _mesh_inst == null:
		return
	_mesh_inst.mesh = _build_quad_mesh(bounds, _wrap_period_x)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("world_origin", bounds.position)
		_shader_mat.set_shader_parameter("world_size", bounds.size)
		_shader_mat.set_shader_parameter("wrap_origin_x", 0.0)
		_shader_mat.set_shader_parameter("wrap_period_x", _wrap_period_x)
	_update_visibility()


func set_horizontal_wrap(period_x: float) -> void:
	_wrap_period_x = maxf(0.0, period_x)
	if _bounds.size.x > 0.0 and _mesh_inst != null:
		_mesh_inst.mesh = _build_quad_mesh(_bounds, _wrap_period_x)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("wrap_origin_x", 0.0)
		_shader_mat.set_shader_parameter("wrap_period_x", _wrap_period_x)


## 关掉整层（GM 面板 / perf A-B 用）。隐藏节点即 0 fragment 开销。
func set_enabled(enabled: bool) -> void:
	_enabled = enabled
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("fog_enabled", enabled)
	_update_visibility()


func is_enabled() -> bool:
	return _enabled


## 与 WeatherLayer 对齐的表现时钟。倍速切换立即影响云体内部演化速度。
func set_clock_speed_multiplier(multiplier: float) -> void:
	_clock_speed_multiplier = clampf(multiplier, 0.0, 20.0)


## 兼容 WeatherLayer 的暂停语义：暂停模拟时大气仍以 1x 真实时间缓慢活动。
func set_clock_running(running: bool) -> void:
	_clock_running = running


## 运行时质量档。visual_quality 是 0..2，迷雾内部用 0..3：
## 0 → q0 超低（无光照的纯色云，给低配保底）；1 → q2 中；2 → q3 全效果。
##
## 桌面端跳过 q1：q1 是无域扭曲/无质量阴影探针的分层云海，存在的意义是给移动端
## 中档兜底（编译期 tier 会把上限卡在 q1）。桌面端要么便宜到 q0，要么就该拿到
## q2/q3 的完整分层密度、散射与柔和自阴影，中间档没有意义。
func set_visual_quality(quality: int) -> void:
	var q := clampi(quality, 0, 2)
	_fog_quality = [0, 2, 3][q]
	_push_quality()


## 当前实际生效的档位 = min(编译期 tier 上限, 运行时档)。
func effective_quality() -> int:
	var cap := 3
	if _mobile_quality_tier_define != "" and DCFeatureFlags.uses_shader_quality_tier():
		match _mobile_quality_tier_define:
			"MOBILE_QUALITY_LOW":
				cap = 0
			"MOBILE_QUALITY_HIGH":
				cap = 2
			_:
				cap = 1
	return mini(_fog_quality, cap)


## 主地形能否对未探索像素早退。
##
## 早退的前提是本层在该处输出一个**与地形无关的常量色**，地形怎么画都被盖住。
## q0 满足（纯色 + 起伏）；q1+ 一旦接入 TOD 光照与高度场着色，颜色随位置和时间
## 变化，早退分支那块常量色就会露成一块死斑。所以早退只在 q0 放行。
func supports_terrain_early_out() -> bool:
	return effective_quality() <= 0


func set_day_night_enabled(v: bool) -> void:
	_day_night_enabled = v
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("day_night_enabled", _day_night_enabled)


func set_day_phase(v: float) -> void:
	_day_phase = fposmod(v, 1.0)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("day_phase", _day_phase)


func set_season_phase(v: float) -> void:
	_season_phase = v
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("season_phase", _season_phase)


func set_axial_tilt_rad(v: float) -> void:
	_axial_tilt_rad = v
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("axial_tilt_rad", _axial_tilt_rad)


func set_tod_debug_sun_position(enabled: bool, uv: Vector2) -> void:
	_tod_debug_sun_position_enabled = enabled
	_tod_debug_sun_uv = uv
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("tod_debug_sun_position_enabled", enabled)
		_shader_mat.set_shader_parameter("tod_debug_sun_uv", uv)


func set_tod_debug_sun_height_scale(v: float) -> void:
	_tod_debug_sun_height_scale = clampf(v, 0.2, 1.5)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("tod_debug_sun_height_scale", _tod_debug_sun_height_scale)


# --- 内部 -----------------------------------------------------

func _push_quality() -> void:
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("fog_quality", _fog_quality)


func _push_tod() -> void:
	if _shader_mat == null:
		return
	_shader_mat.set_shader_parameter("day_night_enabled", _day_night_enabled)
	_shader_mat.set_shader_parameter("day_phase", _day_phase)
	_shader_mat.set_shader_parameter("season_phase", _season_phase)
	_shader_mat.set_shader_parameter("axial_tilt_rad", _axial_tilt_rad)
	_shader_mat.set_shader_parameter("tod_debug_sun_position_enabled", _tod_debug_sun_position_enabled)
	_shader_mat.set_shader_parameter("tod_debug_sun_uv", _tod_debug_sun_uv)
	_shader_mat.set_shader_parameter("tod_debug_sun_height_scale", _tod_debug_sun_height_scale)


func _update_visibility() -> void:
	visible = _enabled \
		and _has_valid_shader \
		and _has_atlas \
		and _bounds.size.x > 0.0 \
		and _bounds.size.y > 0.0


func _build_quad_mesh(bounds: Rect2, wrap_period_x: float = 0.0) -> Mesh:
	var p := bounds.position
	var s := bounds.size
	if wrap_period_x > 0.0001:
		p.x = 0.0
		s.x = wrap_period_x
	var verts := PackedVector2Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var tile_offsets := PackedFloat32Array([0.0])
	if wrap_period_x > 0.0001:
		tile_offsets = PackedFloat32Array([-wrap_period_x, 0.0, wrap_period_x])
	for ox in tile_offsets:
		var base := verts.size()
		var tp := p + Vector2(float(ox), 0.0)
		verts.append(tp)
		verts.append(tp + Vector2(s.x, 0.0))
		verts.append(tp + s)
		verts.append(tp + Vector2(0.0, s.y))
		uvs.append_array(PackedVector2Array([
			Vector2(0.0, 0.0),
			Vector2(1.0, 0.0),
			Vector2(1.0, 1.0),
			Vector2(0.0, 1.0),
		]))
		indices.append_array(PackedInt32Array([base, base + 1, base + 2, base, base + 2, base + 3]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
