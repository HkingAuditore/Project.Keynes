# fog_of_war_layer.gd
# 三态视野迷雾层。
#
# 与 DataOverlayLayer / WeatherLayer 同一套机制：一张覆盖 world_bounds 的
# quad + per-pixel 取格 + per-cell 表。之所以不用 GPU instance 画六边形：2400 格 ×
# 3 份 wrap 副本 = 7200 instance，每次视野变化都要重传 instance buffer，六边形还是硬边、
# 得额外羽化；而 LUT 方案是 1 个 draw call、0 几何，视野变化只需重写 2400 个 texel。
#
# ── 取格的两条路径（与主地形**同一个**开关 `PK_CELL_FIELD`）───────────────
# [cell-field-overlays 2026-11-18 / O3] 开（方案 docs/plans/terrain-cell-field-overlays-plan.md
# §3.6 / §4）：像素归属由解析格界（场函数）算出，知识度 k 从 `cell_table` 的 layer2.R 取。
# 本层负责把世界 uniform / per-cell 表 / 地形扭曲场推给 shader，并且**必须**用主地形
# 拼前缀的那个判定口（RendererShaderWater._cell_field_active）—— 迷雾的「地形早退
# 像素必须不透明」是在 shader 内复算地形的判定式，地形走旧路径时那条判定判的是一个
# 不存在的条件，所以两边只能同开同关。**迷雾不新增开关。**
# 关：旧路径不变（map_index_atlas 逐像素解 cell.index + enum_lut.a 取 k）。
#
# 知识度 k 的语义（两条路径相同）：
#   k = 0 未探索 / 0.5 已探索未可见 / 1 完全可见。旧路径住在 enum_lut 的 A 通道
#   （主地形已经无条件采样它，因此灰化与早退都是零新增采样）；场函数路径住在
#   cell_table.layer2.R（与 enum_lut.a 逐字节同源，见 cell_lut_baker 的 layer2 注释）。
#
# z_index = 12：必须盖住 WeatherLayer(4) / DataOverlayLayer(5) /
# CountryBorderLayer(6) / CellHighlight(10) —— 未探索区不该漏出任何信息。
class_name FogOfWarLayer
extends Node2D

const CellFieldBindings = preload("res://scripts/rendering/fog_cell_field_bindings.gd")

const SHADER_PATH: String = "res://shaders/fog_of_war.gdshader"

## [cell-field-overlays 2026-11-18 / O3] 前缀拼装的唯一真源（与陆地 / 水面两条路径
## 引用同一个常量）；本文件**不写宏字面量**。
const RendererShaderWaterScript = preload("res://scripts/rendering/renderer_shader_water.gd")
const CELL_FIELD_DEFINE = RendererShaderWaterScript.CELL_FIELD_DEFINE

## 迷雾锐化带宽（gap 单位）。约束 1：必须 < √3/2，默认 0.6（比地形的 0.84 宽 ⇒ 更柔）。
## 与 fog_of_war.gdshader 的 `fog_field_band` 默认值同值；运行期由本层推送覆盖。
const FOG_FIELD_BAND := 0.6
## 迷雾自己的可平铺扭曲：提高频率打散长直边，仍只计算原有两次噪声。
## amp 的单位是 **hex_size**（旧 edge_warp 用的是 hex 直径，见 shader 里
## 约束 2 的推导 —— 按长度 clamp 后幅度会变小，这是有意的视觉变化）。
const FOG_WARP_FREQ := 0.010
const FOG_WARP_AMP := 0.55
## `fog_early_out_k` 在拿不到地形材质实参时的兜底（= uniforms.gdshaderinc:221 的默认值）。
## 正常路径永远读 host._shader_mat 上的**实际值**，不靠这个常数。
const FOG_EARLY_OUT_K_FALLBACK := 0.02

## Web 上是否编译完整 fog shader（43 KB）。实测：它和 weather_overlay 一起构成
## "进世界后卡一次"的那几十秒；web 默认用极简纯色版本（雾仍然整片不透明，
## 只是没有边沿过渡/噪声纹理）。做出裁剪版 web 变体后置回 true。
const PK_WEB_ENABLE_FOG_FULL_SHADER := true

## 未探索厚云的基础反照率，必须与 fog_of_war.gdshader 的 unexplored_color 默认值一致。
## world_map.gdshader 的早退分支输出同一个颜色；只有 q0（无光照）时两者才真的对得齐，
## 见 supports_terrain_early_out()。
const UNEXPLORED_COLOR := Color(0.52, 0.56, 0.64)
const GRADIENT_STEP := 0.25  # cloud-evolution seconds

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
var _gradient_table: SubViewport
var _gradient_start := -INF
var _visual_tiles = null
# 与 WeatherLayer 同一表现时钟语义：运行时按游戏倍速推进；暂停时保留 1x 环境运动，
# 避免整个大气层完全冻结。
var _clock_running: bool = true
var _clock_speed_multiplier: float = 1.0

# 质量：编译期 tier 卡上限（低端机整段代码不编进去），运行时 _fog_quality 在上限内再降。
var _mobile_quality_tier_define: String = ""
var _fog_quality: int = 3
var _render_scale_percent := -1
var _scaled := preload("res://scripts/rendering/fog_render_target.gd").new()
var _sub_viewport: SubViewport:
	get: return _scaled.viewport
var _blit_sprite: Sprite2D:
	get: return _scaled.blit
## 玩家画质档（0..2）。档位映射要用到它，且 set_mobile_quality_tier 晚于
## set_visual_quality 到达时必须能重算，所以单独存一份。
var _visual_quality: int = 0

# ── [cell-field-overlays 2026-11-18 / O3] 场函数路径的推送状态 ────────────────
## 当前 shader 是否在搭的时候带了 `#define PK_CELL_FIELD`。与判定口不一致时要重编
## （开关在运行期翻转 / boot 自检结论晚到 —— 与陆地 program 的重编时机同源）。
var _built_cell_field: bool = false
## 上一帧推给材质的场函数参数快照。稳态下每帧只是**一次字典比较**（与
## renderer_material_publish._sync_cell_lut_textures 同一个取舍：不靠"绑一次"的假设，
## 但也不每帧盲推十几个 set_shader_parameter）。
var _cell_field_sig: Dictionary = {}

# TOD：earth_daylight 的三个相位 uniform 与调试项，与 WeatherLayer 同套。
var _day_night_enabled: bool = true
var _day_phase: float = 0.25
var _season_phase: float = 1.0
var _axial_tilt_rad: float = 0.4101523
var _tod_debug_sun_position_enabled: bool = false
var _tod_debug_sun_uv: Vector2 = Vector2(0.25, 0.5)
var _tod_debug_sun_height_scale: float = 1.0


func _enter_tree() -> void:
	# Register before terrain culling, including when a scaled target is enabled later in play.
	RenderingServer.frame_pre_draw.connect(_prepare_scaled_draw)


func _exit_tree() -> void:
	RenderingServer.frame_pre_draw.disconnect(_prepare_scaled_draw)


func _ready() -> void:
	z_index = 12
	# [fog-z-absolute 2026-11-18] 必须与植被同口径用**绝对 z**。
	# 植被（ShrubLayer.shrub/lifecycle.gd）是 z_as_relative=false + z=0..3，而本层原先是
	# 相对 z（12 + HexRenderer 的 0）。两者混用同一个 CanvasLayer 时，相对 z 的项会跟着
	# 父的绘制组走，实测结果是 z=3 的树冠压在 z=12 的迷雾之上（未探索厚云里浮出树点）。
	# 改成绝对 z 后，12 与 3 在同一把尺子上比较。
	z_as_relative = false
	top_level = true
	visible = false
	# 运行期档平台的首帧兜底：_fog_quality 的成员初值 3 是桌面语义（全效果）。
	# 移动端在玩家画质档推下来之前不该先按 q3 画一帧——auto 档本来就解出 0。
	# 只在"还没人推过档"（仍是初值 3）时兜底，避免覆盖先于 _ready 到来的设置。
	if _fog_runtime_mapping_graded() and _fog_quality == 3:
		_fog_quality = 0
	_ensure_nodes()
	visibility_changed.connect(_sync_scaled_visibility)
	set_process(true)


func _process(delta: float) -> void:
	# [cell-field-overlays 2026-11-18 / O3] 场函数 uniform 的同步放在 visible 判断**之前**：
	# 世界烘焙完成后本层往往还是隐藏的（_update_visibility 要等 atlas 绑上），而材质一旦
	# 提前可见就必须已经是"对的那一帧数据"。稳态下这里只是一次字典比较。
	_sync_cell_field_uniforms()
	if not is_visible_in_tree() or _shader_mat == null:
		return
	var visual_time_scale := _clock_speed_multiplier if _clock_running else 1.0
	_world_time += delta * visual_time_scale
	if _sub_viewport != null:
		_scaled.elapsed += delta
	else:
		_push_animation_time()


func _push_animation_time() -> void:
	_shader_mat.set_shader_parameter("world_time", _world_time)
	_sync_gradient_table()


func _uses_gradient_table() -> bool:
	return effective_quality() > 0 and RenderingServer.get_rendering_device() != null


func _sync_gradient_table() -> void:
	if not _uses_gradient_table():
		if _gradient_table != null:
			_shader_mat.set_shader_parameter("fog_gradient_lattice", null)
			_gradient_table.queue_free()
			_gradient_table = null
			_gradient_start = -INF
		return
	if _gradient_table == null:
		_gradient_table = preload("res://scripts/rendering/render_data_table.gd").new()
		# The table follows the fog mesh when the player changes its drawing resolution.
		_gradient_table.configure(_mesh_inst, Vector2i(128 * 2, 128 * 10),
			preload("res://shaders/fog_gradient_lattice.gdshader"))
		_gradient_table.material.set_shader_parameter("evolution_step", GRADIENT_STEP)
		_shader_mat.set_shader_parameter("fog_gradient_lattice", _gradient_table.get_texture())
	var speed: Variant = _shader_mat.get_shader_parameter("churn_speed")
	var time := _world_time * (0.2 if speed == null else float(speed))
	var start := floorf(time / GRADIENT_STEP) * GRADIENT_STEP
	if start != _gradient_start:
		_gradient_start = start
		_gradient_table.material.set_shader_parameter("evolution_start", start)
		_gradient_table.refresh()
	_shader_mat.set_shader_parameter("fog_gradient_blend", (time - start) / GRADIENT_STEP)


func _effective_render_scale() -> int:
	if _render_scale_percent < 0:
		return 50 if DCFeatureFlags.fog_half_res_enabled() else 100
	return _render_scale_percent


func set_render_scale(percent: int) -> void:
	if percent == _render_scale_percent or percent not in [-1, 50, 75, 100]:
		return
	_render_scale_percent = percent
	if _mesh_inst == null:
		return
	if _effective_render_scale() < 100:
		_scaled.build(self, _mesh_inst)
	else:
		_scaled.drop(self, _mesh_inst)
	_update_visibility()


func _ensure_nodes() -> void:
	if _mesh_inst != null:
		return
	_mesh_inst = MeshInstance2D.new()
	_mesh_inst.name = "FogQuad"
	_mesh_inst.texture = DataOverlayBaker.get_empty_texture()
	if _effective_render_scale() < 100:
		_scaled.build(self, _mesh_inst)
	else:
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
	_sync_gradient_table()
	_has_valid_shader = true
	_push_quality()
	_push_tod()
	_push_edge_transition_data()
	# [cell-field-overlays 2026-11-18 / O3] 场函数参数。此刻世界可能还没建好（_world 为
	# null）⇒ 推中性值：cell_table_bound=false 时 shader 一律按厚云画、**不读表**；
	# 本层此时也不可见（_update_visibility 要求 atlas 已绑），所以不会看到那一帧。
	# 真正的数据在 setup() 与 _process 的每次比较里补上。
	_sync_cell_field_uniforms(true)


func _sync_scaled_visibility() -> void:
	_scaled.sync_visibility(self, _effective_render_scale())


func _prepare_scaled_draw() -> void:
	if _sub_viewport != null and is_visible_in_tree() and _shader_mat != null:
		var host: Variant = _cell_field_host()
		var world: WorldData = host._world if host != null else null
		if _scaled.needs_draw(self, _effective_render_scale(), world):
			_push_animation_time()
			_sub_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


## 编译期质量档：mobile/web 共用 MOBILE_QUALITY_*；桌面不 prepend。
func _load_shader() -> Shader:
	# Web：fog_of_war.gdshader（43 KB，全屏、含多层噪声/边沿混合）的首次编译在
	# ANGLE 上同样是几十秒级——它和 weather_overlay 一起构成了"进世界后卡一次"。
	# 这里换成极简版：未探索区域仍然整片不透明（雾的语义在逻辑层由
	# cell.visible/explored 决定，渲染层用纯色近似），边沿过渡在 web 上暂时没有。
	# 做出裁剪版 web 变体后把 PK_WEB_ENABLE_FOG_FULL_SHADER 置回 true。
	if not PK_WEB_ENABLE_FOG_FULL_SHADER and OS.has_feature("web"):
		var stub := Shader.new()
		stub.code = "shader_type canvas_item;\nuniform vec4 unexplored_color : source_color = vec4(0.09, 0.08, 0.07, 1.0);\nvoid fragment() { COLOR = unexplored_color; }\n"
		print("[fog_of_war_layer] web: simplified fog shader (full shader compiles in tens of seconds)")
		return stub
	var sh := ResourceLoader.load(SHADER_PATH, "Shader", ResourceLoader.CACHE_MODE_IGNORE) as Shader
	if sh == null:
		return null
	var prefix := "#define MAP_VISUAL_TILED\n" if _visual_tiles_active() else ""
	if _mobile_quality_tier_define != "" and DCFeatureFlags.uses_shader_quality_tier():
		prefix += _shader_quality_define_prefix(_mobile_quality_tier_define)
	if OS.has_feature("web"):
		# web：把 full fog shader 的 q1/q2 分支留给运行期设置；采样器与纹理不变。
		# ⚠ 宏名必须与 WebShaderWarmup.SHADERS 里那条前缀**逐字节一致**（预热 = 运行期
		# 是驱动缓存命中的前提），所以 web 保留历史名字 PK_WEB_FOG_RUNTIME，
		# 由 shader 内的别名转成 PK_FOG_RUNTIME。
		prefix += "#define PK_WEB_FOG_RUNTIME\n"
	elif _fog_runtime_quality_override():
		# [fog-runtime-quality 2026-11-17] 编译期 tier 只裁特征，运行期画质归玩家设置。
		# 之前只有 web 追加这条宏，移动端因此永远停在 MOBILE_QUALITY_LOW 的 q0：
		# 设置里的"最高画质"对迷雾是空操作（见 shader 里 effective_fog_quality）。
		# 这里不新增采样、不换程序：q1..q3 的分支本来就全部编进了低档程序，只是
		# 被 effective_fog_quality 钳成 0、永不执行。
		prefix += "#define PK_FOG_RUNTIME\n"
	# [cell-field-overlays 2026-11-18 / O3] 解析格界（场函数）开关。
	# **唯一判定口**：RendererShaderWater._cell_field_active() —— 陆地 program 拼
	# CELL_FIELD_DEFINE 用的是同一个静态函数（方案 §4 表格第三行 + §1.3）。迷雾的
	# 「地形早退像素必须不透明」判定必须在**地形真的早退**时才成立，所以两边只能同开
	# 同关；这里绝不自己判平台 / 画质 / 项目设置。
	# 关 = 一个字节都不加（与今日逐字节相同）。
	if _uses_gradient_table():
		if not _cell_field_sig.get("early", false):
			prefix += "#define PK_FOG_NO_TERRAIN_QUERY\n"
		prefix += "#define PK_FOG_LATTICE\n"
	_built_cell_field = _cell_field_active()
	if _built_cell_field:
		prefix += CELL_FIELD_DEFINE
	if not prefix.is_empty():
		sh = sh.duplicate() as Shader
		sh.code = prefix + sh.code
	return sh


## 是否让运行期画质（玩家设置）权威，而不是编译期 tier。
##
## 判据与"这个平台会不会 prepend 编译期 tier"同一个开关（DCFeatureFlags.uses_shader_quality_tier）：
## 只要 prepend 了 MOBILE_QUALITY_*，就必须给一条运行期出口，否则设置里的画质档被
## 编译期档吃掉。web / mobile 都被钉死在 LOW；桌面上设 PK_MOBILE_SHADER_TIER 做
## 移动变体二分时同样适用（此时 layer 与 shader 必须同口径，见 _load_shader 的两个分支）。
func _fog_runtime_quality_override() -> bool:
	return DCFeatureFlags.uses_shader_quality_tier()


## [cell-field-overlays 2026-11-18 / O3] 场函数路径是否启用（**迷雾不新增开关**）。
##
## 与地形的前缀拼装是同一个判定函数，因此结构上不可能出现"地形走旧路径、迷雾走新路径"
## —— 那会让约束 3 判一个地形根本没执行的条件（方案 §4）。
## 独立创建（tests/ui/overlay_edge_transition_shader_test.gd 直接 new + add_child(root)）
## 时拿不到宿主 ⇒ 返回 false ⇒ 与今天的旧路径行为一致。
func _cell_field_active() -> bool:
	var host: Variant = _cell_field_host()
	if host == null:
		return false
	return RendererShaderWaterScript._cell_field_active(host)


## 迷雾层的宿主 = 父节点 HexRenderer（renderer_scene_services.gd:159-161 建 + add_child）。
## 按**方法面**识别而不是按类型，避免 fog_of_war_layer.gd 反向 preload hex_renderer.gd
## 形成循环依赖：`_wrap_period_x` / `_push_world_uniform` 是 HexRenderer 独有的两个入口。
func _cell_field_host() -> Variant:
	var p: Node = get_parent()
	if p == null:
		return null
	if not (p.has_method("_wrap_period_x") and p.has_method("_push_world_uniform")):
		return null
	return p


func _visual_tiles_active() -> bool:
	return _visual_tiles != null and bool(_visual_tiles.ready) \
		and String(_visual_tiles.layout.mode) == "tiled"


func set_visual_tiles(tiles) -> void:
	var was_tiled := _visual_tiles_active()
	_visual_tiles = tiles
	if _shader_mat != null and was_tiled != _visual_tiles_active():
		var sh := _load_shader()
		if sh != null:
			_shader_mat.shader = sh
	_push_visual_tile_uniforms()
	_push_edge_transition_data()
	# [cell-field-overlays 2026-11-18 / O3] 换 tiled 变体会换掉 PK 变体的扭曲场来源
	# （terrain_surface_tex ↔ visual_warp_tiles），必须重推一遍（签名比较会看到变化）。
	_sync_cell_field_uniforms(true)


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
	# 档位变了，映射与 cap 都可能变（HIGH = 桌面同款 q3 / 其余 = 等距 q0..q2），
	# 必须按同一个 visual_quality 重算一次 _fog_quality，否则先推画质后推档位时
	# 会停在旧映射上（例如 低档 2 号档 = q1，切成高档后应该变成 q3）。
	_fog_quality = _fog_quality_for(_visual_quality)
	if _shader_mat != null:
		var sh := _load_shader()
		if sh != null:
			_shader_mat.shader = sh
			_sync_gradient_table()
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
	# [cell-field-overlays 2026-11-18 / O3] 场函数参数：setup() 是"世界数据已就绪"的
	# 唯一入口（renderer_material_publish.gd:495 在 _apply_uniforms 里调），所以这里
	# 强制重推一次 —— cell_table / 扭曲场 / 早退实参全在这一刻才第一次可用。
	_sync_cell_field_uniforms(true)
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
	_scaled.dirty = true
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


# ─── [cell-field-overlays 2026-11-18 / O3] 场函数路径的 uniform 推送 ────────────
#
# 数据来源全部是**已有字段**（不新增 WorldData 字段、不改其他模块）：
#   cell_table / dims / bound   ← WorldData.cell_table_tex / cell_table_dims / cell_table_bound
#   地形扭曲场                   ← 非 tiled: WorldData.terrain_surface_tex 的 layer6
#                                  + terrain_warp_layer_bound / boundary_warp_range
#                                  tiled   : WorldData.visual_tiles.boundary_warp
#   hex_size                    ← setup() 收到的 host.hex_size
#   map_dims                    ← cell_table_dims（与 cell_table_size 同值：1 texel = 1 格）
#   fog_early_out_enabled/_k    ← 地形材质上**实际**的实参（见下面的注释）
#
# 缺数据时一律推中性值，绝不猜：
#   cell_table_bound=false ⇒ shader 一律按厚云（k=0）画，**不读表**（GLES3 对未绑
#   sampler2DArray / 越界层的返回值未定义）；terrain_warp_layer_bound=false ⇒ 扭曲 0
#   （与地形侧 pk_boundary_warp_world 的退化分支一致）。
func _sync_cell_field_uniforms(force: bool = false) -> void:
	if not CellFieldBindings.prepare(self, force):
		return
	var bindings := _cell_field_sig
	var dims: Vector2i = bindings["dims"]
	_shader_mat.set_shader_parameter("hex_size", _hex_size)
	_shader_mat.set_shader_parameter("map_dims", Vector2(dims.x, dims.y))
	_shader_mat.set_shader_parameter("cell_table_size", Vector2(dims.x, dims.y))
	if bindings["table"] != null:
		_shader_mat.set_shader_parameter("cell_table", bindings["table"])
	_shader_mat.set_shader_parameter("cell_table_bound", bindings["bound"])
	if bindings["tiled"]:
		if bindings["warp_tiles"] != null:
			_shader_mat.set_shader_parameter("visual_warp_tiles", bindings["warp_tiles"])
	else:
		if bindings["surface"] != null:
			_shader_mat.set_shader_parameter("terrain_surface_tex", bindings["surface"])
	_shader_mat.set_shader_parameter("terrain_warp_layer_bound", bindings["warp_bound"])
	_shader_mat.set_shader_parameter("terrain_warp_range", bindings["warp_range"])
	# amp 与地形同源（MapBaker.WARP_AMP = 生成期 C++ 烘焙用的同一个常量）。
	_shader_mat.set_shader_parameter("terrain_warp_amp", MapBaker.WARP_AMP)
	_shader_mat.set_shader_parameter("fog_field_band", FOG_FIELD_BAND)
	_shader_mat.set_shader_parameter("fog_warp_freq", FOG_WARP_FREQ)
	_shader_mat.set_shader_parameter("fog_warp_amp", FOG_WARP_AMP)
	_shader_mat.set_shader_parameter("fog_early_out_enabled", bindings["early"])
	_shader_mat.set_shader_parameter("fog_early_out_k", bindings["early_k"])


## 调试输出档（0 = 正常；1 = terrain_hidden；2 = 最终 alpha；3 = 显示用 k）。
## 只给真后端不变量探针（tests/world/fog_cell_field_test.gd）用；生产路径从不调用，
## 材质上的 fog_debug_view 因此恒为 shader 默认值 0。
func set_fog_debug_view(view: int) -> void:
	if _shader_mat == null:
		return
	_scaled.dirty = true
	_shader_mat.set_shader_parameter("fog_debug_view", clampi(view, 0, 3))


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
	_scaled.dirty = true
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
##
## 移动端改走 0/1/2 → q0/q1/q2 的等距映射：编译期档被钉死 LOW，若仍按桌面跳档，
## "中"会直接落到 q2 的完整散射（移动 GPU 上最贵的一档），而 q1 这个专为移动端
## 中档准备的分层云海反而永远拿不到。web 保持原映射，避免二次动它的性能基线。
func set_visual_quality(quality: int) -> void:
	var used_table := _uses_gradient_table()
	_visual_quality = clampi(quality, 0, 2)
	_fog_quality = _fog_quality_for(_visual_quality)
	if _shader_mat != null and used_table != _uses_gradient_table():
		_shader_mat.shader = _load_shader()
		_sync_cell_field_uniforms(true)
		_sync_gradient_table()
	_push_quality()


## visual_quality(0..2) → 迷雾内部档位(0..3)。映射取决于编译档，见两个 helper。
func _fog_quality_for(quality: int) -> int:
	var q := clampi(quality, 0, 2)
	return [0, 1, 2][q] if _fog_runtime_mapping_graded() else [0, 2, 3][q]


## 运行期档是否需要"移动端等距映射"（见 set_visual_quality）。
##
## HIGH 编译档不算：它已经不按移动平台裁光照（见 shader_quality.gdshaderinc），
## 迷雾也就能和桌面一样吃到 q3，所以映射直接用桌面那套 [0,2,3]。
func _fog_runtime_mapping_graded() -> bool:
	return OS.has_feature("mobile") and _mobile_quality_tier_define != "MOBILE_QUALITY_HIGH"


## 移动端 HIGH 档是否等价于桌面（fog 可到 q3）。
func _fog_high_tier_full() -> bool:
	return _mobile_quality_tier_define == "MOBILE_QUALITY_HIGH"


## 当前实际生效的档位 = min(编译期 tier 上限, 运行时档)。
##
## 必须与 shader 的 effective_fog_quality() 逐档一致：
##   · 运行期档（web / mobile，_load_shader() 追加 PK_FOG_RUNTIME）：shader 忽略编译期
##     tier、按运行时 fog_quality 夹到 2。这两端的编译期档被钉死在 MOBILE_QUALITY_LOW，
##     若这里仍按 tier cap=0 计算，就会得出 effective_quality()==0，
##     supports_terrain_early_out() 随之放行 —— 但 shader 实际画的是 q2 云海，
##     主地形的早退常量色会在半透明云缘下露成死斑
##     （见 fog_of_war.gdshader / docs vision-fog-and-borders「主地形早退」）。
##   · 桌面：不 prepend 任何 tier define，cap 恒 3。
func effective_quality() -> int:
	if _fog_runtime_quality_override():
		# 与 shader 的 effective_fog_quality() 逐档一致：
		#   HIGH 编译档 = 桌面同款，可到 q3；其余运行期档夹到 2。
		return clampi(_fog_quality, 0, 3) if _fog_high_tier_full() else mini(_fog_quality, 2)
	return mini(_fog_quality, 3)


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


var _eternal_min_elevation_rad: float = deg_to_rad(10.0)
var _eternal_max_hour_angle_rad: float = deg_to_rad(70.0)

func set_eternal_daylight_parameters(min_elevation: float, max_hour_angle: float) -> void:
	_eternal_min_elevation_rad = min_elevation
	_eternal_max_hour_angle_rad = max_hour_angle
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("eternal_min_elevation_rad", min_elevation)
		_shader_mat.set_shader_parameter("eternal_max_hour_angle_rad", max_hour_angle)


func set_tod_debug_sun_height_scale(v: float) -> void:
	_tod_debug_sun_height_scale = clampf(v, 0.2, 1.5)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("tod_debug_sun_height_scale", _tod_debug_sun_height_scale)
		_shader_mat.set_shader_parameter("eternal_min_elevation_rad", _eternal_min_elevation_rad)
		_shader_mat.set_shader_parameter("eternal_max_hour_angle_rad", _eternal_max_hour_angle_rad)


# --- 内部 -----------------------------------------------------

func _push_quality() -> void:
	if _shader_mat == null:
		return
	_scaled.dirty = true
	_shader_mat.set_shader_parameter("fog_quality", _fog_quality)
	# [fog-quality-diag 2026-11-17] 一行可 grep 的实际档位。真机排查"迷雾画质没变"
	# 时需要区分三件事：设置没推下来 / 推了但被 tier 夹住 / shader 根本没生效。
	#   adb logcat | grep "\\[fog\\]"
	if _fog_quality != _logged_fog_quality:
		_logged_fog_quality = _fog_quality
		print("[fog] fog_quality=%d effective=%d runtime_override=%s tier=%s" % [
			_fog_quality, effective_quality(), _fog_runtime_quality_override(),
			_mobile_quality_tier_define if not _mobile_quality_tier_define.is_empty() else "desktop"])


var _logged_fog_quality: int = -1


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
	_shader_mat.set_shader_parameter("eternal_min_elevation_rad", _eternal_min_elevation_rad)
	_shader_mat.set_shader_parameter("eternal_max_hour_angle_rad", _eternal_max_hour_angle_rad)


func _update_visibility() -> void:
	var was_visible := visible
	visible = _enabled \
		and _has_valid_shader \
		and _has_atlas \
		and _bounds.size.x > 0.0 \
		and _bounds.size.y > 0.0
	# [fog-quality-diag 2026-11-17] 只在翻转时打一行：区分"迷雾没开"与"迷雾画不出来"。
	if was_visible != visible:
		print("[fog] visible=%s enabled=%s shader_ok=%s atlas_ok=%s bounds=%s" % [
			visible, _enabled, _has_valid_shader, _has_atlas, _bounds.size])
	else:
		_sync_scaled_visibility()


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
