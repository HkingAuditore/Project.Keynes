# WeatherLayer owns the Godot presentation boundary for weather fronts.
# It publishes the weather LUT and front snapshots to the overlay shader, and
# owns cell curtain meshes and the optional desktop particle pool. Simulation
# state remains in WeatherSystem; this node only keeps visual interpolation and
# GPU resources. The terrain shader applies drought and heatwave ground tint.

class_name WeatherLayer
extends Node2D

const WeatherRenderStep = preload("res://scripts/rendering/weather_layer_render_step.gd")
const WeatherFrontBlend = preload("res://scripts/rendering/weather_layer_front_blend.gd")
const WeatherMaterialPublish = preload("res://scripts/rendering/weather_layer_material_publish.gd")

const WeatherLayerParticlesScript = preload("res://scripts/rendering/weather_layer_particles.gd")
const WeatherCellCurtains = preload("res://scripts/rendering/weather_cell_curtains.gd")

signal visual_fronts_changed(fronts: Array)

const MAX_WEATHER_FRONTS := 16
## Web 上是否启用真实的天气 overlay shader（weather_overlay.gdshader）。
## [web-weather-min 2026-10-31] 已恢复 true：该 shader 现在有 web 裁剪变体
## （`#define PK_WEB_WEATHER_MIN` → shaders/include/weather_overlay_web_min.gdshaderinc），
## 把「域扭曲 + 4/3/2 octave 旋转 fbm × 十几处内联实例」换成「无 sin / 无循环的双 octave
## 值噪声 × 3 处调用点」，同时编译掉体积法线、偏移投影阴影、山雾邻域采样与接缝伙伴采样。
## 云量覆盖、三层云、逐像素晨昏色、云下直射阴影全部保留，所以 web 上高画质
## 能看见云（低/中画质由 hex_renderer 的画质门 set_render_gate() 关掉绘制，
## 见 PK_WEB_ENABLE_WEATHER_LAYER 与 _render_gate_open）。
## 仍保留这个开关作为应急：置 false 时 web 退回全透明 stub（不触发任何 shader 编译、不卡加载）。
## 注：本开关只决定 overlay 是否走 stub；cell curtain shader 一直按正常路径加载（未裁剪）。
const PK_WEB_ENABLE_WEATHER_SHADERS := true
## weather_overlay.gdshader 的 web 裁剪变体宏。只在 OS.has_feature("web") 时 prepend，
## 桌面/移动端不受影响（宏未定义 → 走原来的桌面路径）。
const WEB_WEATHER_MIN_DEFINE := "#define PK_WEB_WEATHER_MIN\n"
const OVERLAY_SHADER_PATH := "res://shaders/weather_overlay.gdshader"

# ═══════════════════════════════════════════════════════════════════════════
# [cell-field-overlays 2026-11-18 / O2] 天气 overlay 改走共享场函数（PK_CELL_FIELD）
#
# 方案：docs/plans/terrain-cell-field-overlays-plan.md §4（开关与平台）/
#       §3.2（坐标契约）/ §3.4（采样流程）/ §3.9（sampler 账）
#
# 为什么天气要**独立**开关（而不是跟着地形走）：天气和地形之间没有逐像素不变量，
# 画面只在本层内部变化；所以它可以单独开、单独回退，第一版 Web 也能开（sampler
# 8 → 2、编译更轻）。迷雾跟地形绑在一起是另一回事（早退判定必须同源），见方案 §4。
# ═══════════════════════════════════════════════════════════════════════════

## 开关的项目设置键。命名照 `project_keynes/rendering/map_tiles/terrain_cell_field_enabled`
## 的惯例（`project_keynes/rendering/<子系>/<键>`），但**是另一个键** ⇒ 两个开关互不影响。
const CELL_FIELD_SETTING := "project_keynes/rendering/map_tiles/weather_cell_field_enabled"
## PK_CELL_FIELD 的前缀片段：开 = 一个 define 行，关 = 空串。
## 关时必须**恰好**空串：关态编译产物要与加这套功能之前逐字节相同（回退保证）。
const CELL_FIELD_DEFINE := "#define PK_CELL_FIELD\n"
## 迷雾带宽（gap 单位）等三个「迷雾门控参数」的**唯一真源在 FogOfWarLayer**。
##
## [O23 2026-11-18] 方案 §3.7 的硬要求：云的消失边界与迷雾薄纱边界必须是**同一条线**。
## 函数一致还不够 —— k 的取样位置由扭曲决定，参数一分开边界就会错开。所以
## `fog_field_band` / `fog_warp_freq` / `fog_warp_amp` 在本文件里**一个定义都不留**，
## 只能引用 fog_of_war_layer.gd 的三个常量（绘制迷雾那一条路径读的是同一批常量）。
##
## 环形依赖检查：fog_of_war_layer.gd 只 preload renderer_shader_water.gd，**不** preload
## 本文件（它只在注释里提到 WeatherLayer，代码里从不引用），所以这条引用是单向的：
##   weather_layer.gd → fog_of_war_layer.gd → renderer_shader_water.gd（无出边）
## 检测：tests/world/weather_overlay_field_test.gd 断言两个方向（本文件有这条 preload、
## fog_of_war_layer.gd 的 preload 列表里没有 weather_layer.gd）。
const FogOfWarLayerScript = preload("res://scripts/rendering/fog_of_war_layer.gd")
## 查表前的低频域扭曲（方案 §3.4 / §8-2）：频率单位 1/世界单位，幅度单位 × hex_size。
## 0.004 → 波长 ≈ 250 wu ≈ 5~6 个 hex；0.75 → 每轴位移 ≈ 0.37 个 hex 直径（落在方案
## §8-2 建议的 0.3~0.5 格内）。参数值待美术联调 —— 走 uniform 就是为了不重编 shader。
## ⚠ 这两个值只影响**天气云自己的形态**，与迷雾无关；迷雾门控取 k 用的 twisted 位置另有
## 两个 uniform（fog_warp_*），真源在 FogOfWarLayer（见上）。
const WEATHER_WARP_FREQ_DEFAULT := 0.004
const WEATHER_WARP_AMP_DEFAULT := 0.75
const _FRONT_PARTICLES_ENABLED := false
const _CELL_CURTAIN_ENABLED := true
const _CURTAIN_LAYER_COUNT_DESKTOP := 3
const _CURTAIN_LAYER_COUNT_MOBILE := 1
# Presentation interpolation keeps front snapshots moving between day commits.
# Its blend and prediction limits accommodate occasional 3–4 s gaps between commits.
const _WEATHER_FRONT_INITIAL_BLEND_SEC: float = 0.65
const _WEATHER_FRONT_MIN_BLEND_SEC: float = 0.35
const _WEATHER_FRONT_MAX_BLEND_SEC: float = 5.0
const _WEATHER_FRONT_BLEND_LAG_FACTOR: float = 1.15
const _WEATHER_FRONT_DESPAWN_FADE_SEC: float = 0.85
const _WEATHER_FRONT_MAX_PREDICT_DAYS: float = 2.5
# 抽动修复（2026-05-18）：blend_duration IIR 平滑系数（new × α + prev × (1-α)）。
# α 越小越平滑但响应越慢。0.35 是在"调速档切换后 ~3 次 commit 内追上新间隔"和
# "抑制单次 interval 抖动"之间取的折中。
const _WEATHER_FRONT_BLEND_IIR_ALPHA: float = 0.35

# 任务 5：降水粒子密度制。每单位像素²粒子数，与覆盖面积相乘得到 amount。
# 最小/最大数量 防止小 front 看不见雨 / 巨大 front 暗制 GPU。
const _RAIN_AMOUNT_MIN: int = 80
const _RAIN_AMOUNT_MAX: int = 640
const _SNOW_AMOUNT_MIN: int = 60
const _SNOW_AMOUNT_MAX: int = 480
# Pass 2（任务 5）：rain_density_boost_enabled=true 时的密度下限/上限
# 以侍需求 5.1：amount_min 从 80 → 180，BLIZZARD 60 → 120。
# WeatherType.WT id（与 weather_type.gd / weather_overlay.gdshader 严格一致）
const _WT_CLEAR    := 0
const _WT_BLIZZARD := 3

const WEATHER_DEBUG_VIEW_NAMES := [
	"off",
	"w.cloud",
	"cumulus_density",
	"fog_density",
	"final_alpha",
	"cell_id",
	"weather_type",
	"precip_intensity_cloud",
]

var _overlay_quad: MeshInstance2D
var _overlay_mat: ShaderMaterial
var _curtains := WeatherCellCurtains.new()
var _weather_map: MapData
var _particles_root: Node2D
var _particles_pool: Array[GPUParticles2D] = []  # 16 个，按 front index 复用
# 缓存每个 slot 当前配置类型，避免每次 set_weather_fronts 都重建 process_material
var _particles_type_cache: Array[int] = []
# Phase A 止血：缓存每个 slot 上一次写入的 amount / visibility_rect_radius，
# 避免逐帧因 area 微动 ±1 触发 GPUParticles 内部缓冲重建（这是"一顿一顿"的主因之一）。
# 仅当 |Δamount| > 5（约 3% 面积）或 radius 变化 > 5% 时才重写。
var _particles_amount_cache: Array[int] = []
var _particles_vis_radius_cache: Array[float] = []
# v-data-driven：每种 WeatherType 共享一份 ParticleProcessMaterial，避免 16 份各自触发
# shader 编译。key = WeatherType.WT int；由 _get_or_build_process_material(wt) 懒加载。
var _process_material_cache: Dictionary = {}
# v-data-driven：profile.particle_texture 为 null 时的兜底白色贴图，避免空引用。
var _fallback_particle_texture: ImageTexture

var _world_bounds: Rect2 = Rect2()
var _wrap_period_x: float = 0.0
var _world_time: float = 0.0
var _strength: float = 1.0
var _map_index_atlas_tex: ImageTexture = null
var _noise_tex: ImageTexture = null
var _hex_size: float = 22.0
var _weather_field_tex: Texture2D = null
var _weather_lut_tex: Texture2D = null
var _fog_enum_lut_tex: Texture2D = null
var _fog_mask_enabled: bool = false
var _edge_neighbor_tex: Texture2D = null
var _edge_distance_tex: Texture2D = null
var _edge_transition_width: float = 0.84
var _world_ref = null  # WorldData 引用(取 weather_lut_prev_tex 做帧间插值)
var _visual_tiles = null
var _wx_lut_last_usec: int = 0          # 上次检测到的 LUT 更新时刻
var _wx_lut_t0_usec: int = 0            # 本插值周期起点(检测到 LUT 换帧的时刻)
var _wx_commit_interval_usec: float = 500000.0  # 自适应 commit 间隔(默认 0.5s)
var _weather_lut_dims: Vector2i = Vector2i.ZERO
var _wx_lut_diag_count: int = 0
var _wx_lut_diag_last_msec: int = -1000000
# [uniform-churn 2026-11-02] 上一次真正推给材质的 weather_lut / prev / lerp。
# 以前这三项每帧无条件 set_shader_parameter，稳态下是无意义的采样器重绑；
# 真机渲染线程崩溃排查时一并压掉（值变了才推）。
var _wx_pushed_weather_lut: Texture2D = null
var _wx_pushed_weather_prev: Texture2D = null
var _wx_pushed_lerp: float = -1.0
# [cell-field-overlays 2026-11-18] weather_table（offset 空间 4 层）+ 层号双缓冲的推送缓存。
# 与上面三项同一个策略：值变了才推 —— 稳态下这几条 uniform 写回 0 次。
# shader 侧消费在 O2（weather_overlay.gdshader），本任务只保证数据与层号已经到位。
var _endpoints: SubViewport
var _endpoints_revision := -1
var _wx_pushed_weather_table: Texture2DArray = null
var _wx_pushed_weather_cur: int = -2
var _wx_pushed_weather_bound: bool = false
# [cell-field-overlays 2026-11-18 / O2] 场函数开关的"已警告一次"标记：开关开着但
# weather_table / cell_table 没发布时只报一次，避免每帧刷日志。
var _wx_cell_field_warned: bool = false

## [cell-field-overlays 2026-11-18 / O2] 天气 overlay 是否走共享场函数（见文件头的
## CELL_FIELD_SETTING 注释）。**与地形的 terrain_cell_field_enabled 完全独立**。
## **出货默认开**（2026-11-18 收尾；`project.godot` 里显式写 true）；关态 = 与加这套功能
## 之前逐字节相同，可整体回退。
## 两个口（惯例照 HexRenderer.terrain_cell_field_enabled）：
##   · 项目设置 project_keynes/rendering/map_tiles/weather_cell_field_enabled —— 部署期
##     默认值，_init() 读它作为初值（"setting + export" 惯例）；
##   · 本变量 —— 运行期权威，GM 面板 / 远程 inspector 可热切。
## 切换会重编 shader 变体（define 是编译期的）：见 _apply_cell_field_enabled()。
## 注意：本开关**不接** RendererShaderWater 的 Web boot 自检 —— 方案 §4 明确天气第一版
## Web 就能开，而那个自检判的是地形/水面两条 program 的驱动兼容性。
@export var weather_cell_field_enabled: bool = true:
	set(value):
		if weather_cell_field_enabled == value:
			return
		weather_cell_field_enabled = value
		_apply_cell_field_enabled()

# Phase 1：vector_atlas（RGBA8）的 BA 通道是 wind_field（[-1,1] mapped to [0,1]）。

# overlay shader 用它做 per-cell advection 让云沿真实风带流动，不再依赖全局常量 axis。
var _vector_atlas_tex: Texture2D = null
var _wind_lut_tex: Texture2D
var _wind_lut_prev_tex: Texture2D
var _has_wind_prev := false
# v9.perf：当前可见 fronts 数量；为 0 时整个 WeatherLayer 隐藏，省一次全屏 pass
var _active_count: int = 0
# 每日 WeatherFront 快照的表现层插值状态。这里存 Dictionary 快照，避免改 WeatherSystem 数据。
var _front_start_snapshots: Array = []
var _front_target_snapshots: Array = []
var _front_visual_snapshots: Array = []
var _front_blend_elapsed: float = 0.0
var _front_blend_duration: float = 0.0
var _last_front_snapshot_time: float = -1.0
var _front_snapshot_interval_sec: float = _WEATHER_FRONT_INITIAL_BLEND_SEC

# Drift-debug（2026-05-10）：set true 后：
#   1) set_weather_fronts 入口打印 snapshot_interval / blend_duration / forward_bias
#      + 每个 front 的 (raw center, velocity, biased target, start→target delta)
#   2) _process 每秒打印 visual_snapshots[0] 的 center 看是否真的在变
# 验证完成后改回 false 关日志。
const DRIFT_DEBUG_LOG: bool = false
var _drift_debug_last_log_time: float = -1.0

## [cell-field-overlays 2026-11-18 / O2] "项目设置 + 导出变量"惯例如
## HexRenderer.terrain_cell_field_enabled：_init() 读设置作为本变量的初值。
## 读不到键时走**关闭**默认值（方案 §4：出货默认关）。
func _init() -> void:
	weather_cell_field_enabled = cell_field_setting_enabled()


## [cell-field-overlays 2026-11-18 / O2] 项目设置侧的天气场函数开关（**默认 false**）。
## 刻意不接受 host：export 初值与测试必须读到同一个答案（形状同
## RendererShaderWater.cell_field_setting_enabled）。
## **出货默认开**（2026-11-18 收尾）：`project.godot` 里显式写了 true，这里的 fallback 也是
## `true`，所以「读不到键」与「没有 project.godot」都不会把它悄悄关掉。
static func cell_field_setting_enabled() -> bool:
	return bool(ProjectSettings.get_setting(CELL_FIELD_SETTING, true))


## [cell-field-overlays 2026-11-18 / O2] export 开关翻转后的重建入口。
## PK_CELL_FIELD 是**编译期** define，光推 uniform 不够：必须重载 shader 建新材质。
## 模板照 set_mobile_quality_tier()：_load_overlay_shader() 重建材质（并按最新值拼前缀），
## _push_overlay_runtime_state() 把全部 uniform 重推一遍（新 ShaderMaterial 上没有任何
## 已推的值）。只影响本层 overlay program —— 地形 / 水面 / 迷雾 / 雨幕一个字节都不动。
func _apply_cell_field_enabled() -> void:
	if _overlay_quad == null:
		# 还没 _ready()（例如 _init 里读项目设置）：_load_overlay_shader() 会按最新值建前缀。
		return
	_load_overlay_shader()
	_push_overlay_runtime_state()


func _ready() -> void:
	WeatherRenderStep._ready(self)

func _process(delta: float) -> void:
	WeatherRenderStep._process(self, delta)

var _clock_running: bool = true
var _clock_speed_multiplier: float = 1.0


func set_clock_running(running: bool) -> void:
	_clock_running = running

func set_clock_speed_multiplier(multiplier: float) -> void:
	_clock_speed_multiplier = clampf(multiplier, 0.0, 20.0)


# ─── 对外接口 ────────────────────────────────────────────────────────────

# 由 HexRenderer 在拿到 WorldData 之后调用一次；提供地图 bounds + 共用的 map_index_atlas + noise_tex。
# 2026-05-19 hex-grounded-offset：新增 hex_size 参数，用于把 shader 里的"邻域采样偏移"
# 按物理 hex 直径换算（替代之前在 uv 域写死的 0.0090~0.0125 魔数），避免和地块尺度共振。
func set_world_ref(w) -> void:
	if _world_ref != w:
		_world_ref = w
		_curtains.invalidate_inputs()
		_push_weather_table(true)

func setup(bounds: Rect2, map_index_atlas: ImageTexture, noise_tex: ImageTexture, hex_size: float = 22.0, weather_lut: ImageTexture = null, lut_dims: Vector2i = Vector2i.ZERO, wrap_period_x: float = 0.0, map: MapData = null) -> void:
	WeatherRenderStep.setup(self, bounds, map_index_atlas, noise_tex, hex_size, weather_lut, lut_dims, wrap_period_x, map)

func set_fog_mask(enabled: bool, enum_lut: Texture2D) -> void:
	WeatherRenderStep.set_fog_mask(self, enabled, enum_lut)

func set_edge_transition_data(
	neighbor_tex: Texture2D,
	distance_tex: Texture2D,
	width: float
) -> void:
	WeatherRenderStep.set_edge_transition_data(self, neighbor_tex, distance_tex, width)

func set_visual_tiles(tiles) -> void:
	WeatherRenderStep.set_visual_tiles(self, tiles)

func _visual_tiles_active() -> bool:
	return WeatherRenderStep._visual_tiles_active(self)

func _push_visual_tile_uniforms() -> void:
	WeatherRenderStep._push_visual_tile_uniforms(self)

func _push_edge_transition_data() -> void:
	WeatherRenderStep._push_edge_transition_data(self)

func _push_fog_mask_uniforms() -> void:
	WeatherRenderStep._push_fog_mask_uniforms(self)

var _cloud_opacity_scale := 0.72


func set_cloud_opacity_scale(v: float) -> void:
	_cloud_opacity_scale = clampf(v, 0.0, 1.0)
	if _overlay_mat != null:
		_overlay_mat.set_shader_parameter("cloud_opacity_scale", _cloud_opacity_scale)


# 全局天气强度（与 HexRenderer.weather_strength 同步）
func set_weather_strength(v: float) -> void:
	_strength = clampf(v, 0.0, 1.0)
	_update_curtain_visibility()
	if _overlay_mat != null:
		_overlay_mat.set_shader_parameter("weather_strength", _strength)
	for mat in _curtains.materials:
		mat.set_shader_parameter("weather_strength", _strength)

# weather_field_tex 通路已退役（main.gd 始终传 null，云改由 weather_lut 驱动）；
# 保留此 setter 让 main.gd / hex_renderer 的历史调用点安全退化。

func set_weather_field_texture(tex: Texture2D) -> void:
	_weather_field_tex = tex
	_refresh_visibility()

# Web 画质门（2026-11-01）：hex_renderer 在 web 上只有高画质才把门打开；
# 桌面 / 移动恒开。门关着时无论有没有 fronts / LUT 都不绘制 —— 这是刻意的：
# 只写一次 visible=false 不够，因为 _refresh_visibility() 会被 setup()/fronts
# 更新再次调用，于是天气层会自己重新显示（2026-10-31 的 web 性能开关就是
# 这样被绕过的）。所有 visible 写入都必须经过本门。
var _render_gate_open: bool = true


## 由 HexRenderer 调用：web 低/中/auto 画质传 false，高画质传 true。
## 关门时立即隐藏；开门时按当前 fronts/LUT 状态重新收敛可见性。
func set_render_gate(open: bool) -> void:
	if _render_gate_open == open:
		return
	_render_gate_open = open
	if open:
		_refresh_visibility()
	else:
		visible = false


func is_render_gate_open() -> bool:
	return _render_gate_open


# 可见性收敛点（画质门之外的唯一 visible 写入口）。门开着 且 任一条件成立：
#  1) 有活跃 fronts（粒子/旧摘要）
#  2) 有 weather_field_tex（旧按 cell 渲染天气场）
#  3) 有 weather_lut（当前逐格云场真源）

func _refresh_visibility() -> void:
	visible = _render_gate_open and ((_active_count > 0) \
			or (_weather_field_tex != null) \
			or _has_weather_lut_source())

func _has_weather_lut_source() -> bool:
	return _weather_lut_tex != null and _weather_lut_dims.x > 0 and _weather_lut_dims.y > 0


# vector_atlas 已退役；保留 setter 让旧调用点安全退化。
func set_vector_atlas_texture(tex: Texture2D) -> void:
	_vector_atlas_tex = tex

var _visual_quality: int = 2
var _weather_detail: int = -1  # -1 跟随总画质，兼容未配置单项的场景。
var _weather_debug_view: int = 0
var _day_night_enabled: bool = true
var _extreme_ground_enabled: bool = true

func set_visual_quality(q: int) -> void:
	var previous := _weather_quality()
	_visual_quality = clampi(q, 0, 2)
	if previous != _weather_quality():
		_apply_weather_quality()

func set_weather_detail(quality: int) -> void:
	var previous := _weather_quality()
	var previous_tier := _weather_shader_tier()
	var previous_capacity := _curtain_layer_capacity()
	_weather_detail = clampi(quality, -1, 2)
	if previous_tier != _weather_shader_tier() or previous_capacity != _curtain_layer_capacity():
		_rebuild_weather_materials()
	elif previous != _weather_quality():
		_apply_weather_quality()

func _weather_quality() -> int:
	return _visual_quality if _weather_detail < 0 else _weather_detail

func _weather_shader_tier() -> String:
	if _weather_detail < 0 or OS.has_feature("web") or not DCFeatureFlags.uses_shader_quality_tier():
		return _mobile_quality_tier_define
	return ["MOBILE_QUALITY_LOW", "MOBILE_QUALITY_MID", "MOBILE_QUALITY_HIGH"][_weather_detail]

func _apply_weather_quality() -> void:
	if _overlay_quad != null:
		_load_overlay_shader()
		_push_overlay_runtime_state()
	for mat in _curtains.materials:
		mat.set_shader_parameter("cell_curtain_quality", _weather_quality())
	_update_curtain_visibility()

func set_weather_debug_view(view: int) -> void:
	_weather_debug_view = clampi(view, 0, WEATHER_DEBUG_VIEW_NAMES.size() - 1)
	if _overlay_mat != null:
		_overlay_mat.set_shader_parameter("weather_debug_view", _weather_debug_view)

func get_weather_debug_view() -> int:
	return _weather_debug_view

func get_weather_debug_view_count() -> int:
	return WEATHER_DEBUG_VIEW_NAMES.size()

func get_weather_debug_view_name() -> String:
	return WEATHER_DEBUG_VIEW_NAMES[_weather_debug_view]

func get_cell_curtain_diag() -> Dictionary:
	return {
		"instances": _curtains.instance_count,
		"layers": _curtains.layers.size(),
		"active_layers": _desired_curtain_layer_count(),
		"has_lut": _has_weather_lut_source(),
		"quality": _weather_quality(),
		"mobile_tier": _weather_shader_tier(),
	}

var _mobile_quality_tier_define: String = ""

func set_mobile_quality_tier(tier_define: String) -> void:
	var previous := _weather_shader_tier()
	_mobile_quality_tier_define = tier_define
	if previous != _weather_shader_tier():
		_rebuild_weather_materials()

func _rebuild_weather_materials() -> void:
	if _overlay_quad == null:
		return
	_load_overlay_shader()
	_load_curtain_shader()
	_rebuild_curtain_layers()
	_push_overlay_runtime_state()
	_update_curtain_visibility()


func _shader_quality_define_prefix(tier_define: String) -> String:
	match tier_define:
		"MOBILE_QUALITY_LOW":
			return "#define MOBILE_QUALITY_LOW\n#define PK_SHADER_TIER_LOW\n"
		"MOBILE_QUALITY_HIGH":
			return "#define MOBILE_QUALITY_HIGH\n#define PK_SHADER_TIER_HIGH\n"
		_:
			return "#define MOBILE_QUALITY_MID\n#define PK_SHADER_TIER_MID\n"

func set_day_night_enabled(v: bool) -> void:
	_day_night_enabled = v
	if _overlay_mat != null:
		_overlay_mat.set_shader_parameter("day_night_enabled", _day_night_enabled)
	for mat in _curtains.materials:
		mat.set_shader_parameter("day_night_enabled", _day_night_enabled)

# extreme_weather_ground_effect_enabled uniform 已在重写中移除；保留 setter 供外部安全调用。
func set_extreme_weather_ground_effect_enabled(v: bool) -> void:
	_extreme_ground_enabled = v

# 任务 2：昼夜相位转发。overlay shader 可用它调暗夜间云色 / 在夜晚
# 把闪电/降水粒子的底色做冷蓝偏移（具体分支在任务 4~5 接入）。
var _day_phase: float = 0.25
# [cylindrical-earth-daylight] 云光照接入 earth_daylight 逐像素晨昏线真源（与地形/水面/植被同源），
# 需要 season_phase / day_phase / axial_tilt_rad 三个 per-material uniform。默认值同 uniforms.gdshaderinc。
var _season_phase: float = 1.0
var _axial_tilt_rad: float = 0.4101523
var _tod_debug_sun_position_enabled: bool = false
var _tod_debug_sun_uv: Vector2 = Vector2(0.25, 0.5)
var _tod_debug_sun_height_scale: float = 1.0

# 昼夜相位：drive earth_daylight 的正午经度（晨昏线东西扫过）。由 HexRenderer.set_day_phase 转发。
func set_day_phase(v: float) -> void:
	_day_phase = fposmod(v, 1.0)
	if _overlay_mat != null:
		_overlay_mat.set_shader_parameter("day_phase", _day_phase)
	for mat in _curtains.materials:
		mat.set_shader_parameter("day_phase", _day_phase)


# 季节相位：drive earth_daylight 的太阳赤纬（南/北半球长昼↔短昼）。由 HexRenderer.set_season_phase 转发。
func set_season_phase(v: float) -> void:
	_season_phase = v
	if _overlay_mat != null:
		_overlay_mat.set_shader_parameter("season_phase", _season_phase)
	for mat in _curtains.materials:
		mat.set_shader_parameter("season_phase", _season_phase)

# 地轴倾角(rad)：drive earth_daylight 的季节赤纬幅度。由 HexRenderer 在 setup/spawn 时推入。
func set_axial_tilt_rad(v: float) -> void:
	_axial_tilt_rad = v
	if _overlay_mat != null:
		_overlay_mat.set_shader_parameter("axial_tilt_rad", _axial_tilt_rad)
	for mat in _curtains.materials:
		mat.set_shader_parameter("axial_tilt_rad", _axial_tilt_rad)

func set_tod_debug_sun_position(enabled: bool, uv: Vector2) -> void:
	_tod_debug_sun_position_enabled = enabled
	_tod_debug_sun_uv = Vector2(fposmod(uv.x, 1.0), clampf(uv.y, 0.0, 1.0))
	if _overlay_mat != null:
		_overlay_mat.set_shader_parameter("tod_debug_sun_position_enabled", _tod_debug_sun_position_enabled)
		_overlay_mat.set_shader_parameter("tod_debug_sun_uv", _tod_debug_sun_uv)
	for mat in _curtains.materials:
		mat.set_shader_parameter("tod_debug_sun_position_enabled", _tod_debug_sun_position_enabled)
		mat.set_shader_parameter("tod_debug_sun_uv", _tod_debug_sun_uv)

var _eternal_min_elevation_rad: float = deg_to_rad(10.0)
var _eternal_max_hour_angle_rad: float = deg_to_rad(70.0)

func set_eternal_daylight_parameters(min_elevation: float, max_hour_angle: float) -> void:
	_eternal_min_elevation_rad = min_elevation
	_eternal_max_hour_angle_rad = max_hour_angle
	if _overlay_mat != null:
		_overlay_mat.set_shader_parameter("eternal_min_elevation_rad", min_elevation)
		_overlay_mat.set_shader_parameter("eternal_max_hour_angle_rad", max_hour_angle)
	for mat in _curtains.materials:
		mat.set_shader_parameter("eternal_min_elevation_rad", min_elevation)
		mat.set_shader_parameter("eternal_max_hour_angle_rad", max_hour_angle)


func set_tod_debug_sun_height_scale(v: float) -> void:
	_tod_debug_sun_height_scale = clampf(v, 0.2, 1.5)
	if _overlay_mat != null:
		_overlay_mat.set_shader_parameter("tod_debug_sun_height_scale", _tod_debug_sun_height_scale)
		_overlay_mat.set_shader_parameter("eternal_min_elevation_rad", _eternal_min_elevation_rad)
		_overlay_mat.set_shader_parameter("eternal_max_hour_angle_rad", _eternal_max_hour_angle_rad)
	for mat in _curtains.materials:
		mat.set_shader_parameter("tod_debug_sun_height_scale", _tod_debug_sun_height_scale)
		mat.set_shader_parameter("eternal_min_elevation_rad", _eternal_min_elevation_rad)
		mat.set_shader_parameter("eternal_max_hour_angle_rad", _eternal_max_hour_angle_rad)

# ─── Pass 2（任务 2）：TOD 消费端 ───────────────────────────────────
# TODProfile 的 6 个字段完整推到 overlay shader，同时让粒子模态 / 云阴影
# 也跟着重新染色，达成“夜晚雨雪偏冷灰、白天偏暖白”的视觉一致性（需求 5.5 / 6.2）。
var _tod_sun_color: Color = Color.WHITE
var _tod_ambient_color: Color = Color(0.65, 0.68, 0.75)
var _tod_night_factor: float = 0.0
var _tod_exposure: float = 1.0
var _tod_sun_dir: Vector3 = Vector3(0.4, -0.7, 0.6)

func apply_tod(profile: TODProfile) -> void:
	if profile == null:
		return
	_tod_sun_dir = profile.sun_dir
	_tod_sun_color = profile.sun_color
	_tod_ambient_color = profile.ambient_color
	_tod_night_factor = profile.night_factor
	_tod_exposure = profile.exposure
	# 云光照颜色 / 晨昏改走 earth_daylight 真源（逐像素经纬度），overlay 不再吃单色
	# tod_sun_color / tod_ambient_color / tod_night_factor（已从 shader 删除）。仅保留迎光屏幕方向
	# 与全局曝光。_tod_* 字段仍保留——下方雨雪粒子 modulate 染色仍按它取色（见 _sync_particles_pool）。
	if _overlay_mat != null:
		_overlay_mat.set_shader_parameter("tod_sun_dir", profile.sun_dir)
		_overlay_mat.set_shader_parameter("tod_exposure", profile.exposure)
	for mat in _curtains.materials:
		mat.set_shader_parameter("tod_exposure", profile.exposure)
	# 任务 5：粒子 modulate 随 TOD 重新染色。
	# base_color * tod_sun_color * (1 - 0.5 * night_factor)
	# 具体到每个 slot 仍用 intensity 控制 alpha，这里只保存“当前色因子”
	# 供 _sync_particles_pool 读取。
	# 云影昼夜淡出由共享 CloudShadowField 接收 _tod_night_factor。
	# 下，这里不再重制。

# 任务 5：开关——是否提升粒子密度（默认开，关闭后回到上一轮的 amount 下限）
var _rain_density_boost_enabled: bool = true

# [parallax-rain] 俯视投影参数：camera_pitch / wind
# camera_pitch: 摄像机俯视角弧度。0=正视，π/2=纯俯视，默认 75°(1.309)
# wind_dir: 世界空间风向（xy），默认微偏右下
# wind_strength: 风强度 [-1,1]，影响雨滴倾斜程度
var _camera_pitch: float = 1.309   # 默认 75°（v3 更贴近实际俯视角）
var _wind_dir: Vector2 = Vector2(0.3, 1.0)
var _wind_strength: float = 0.15

func set_camera_pitch(pitch_rad: float) -> void:
	_camera_pitch = clampf(pitch_rad, 0.0, PI * 0.5)
	for mat in _curtains.materials:
		mat.set_shader_parameter("camera_pitch", _camera_pitch)

func set_wind(dir: Vector2, strength: float) -> void:
	if dir.length_squared() > 0.0001:
		_wind_dir = dir.normalized()
	_wind_strength = clampf(strength, -1.0, 1.0)
	for mat in _curtains.materials:
		mat.set_shader_parameter("wind_dir", _wind_dir)
		mat.set_shader_parameter("wind_strength", _wind_strength)

func get_camera_pitch() -> float:
	return _camera_pitch

func set_rain_density_boost_enabled(v: bool) -> void:
	_rain_density_boost_enabled = v

# 任务 6：云层 TOD 染色开关，仅同步到 overlay shader。
var _cloud_tod_tint_enabled: bool = true

func set_cloud_tod_tint_enabled(v: bool) -> void:
	_cloud_tod_tint_enabled = v
	if _overlay_mat != null:
		_overlay_mat.set_shader_parameter("cloud_tod_tint_enabled", _cloud_tod_tint_enabled)

# 抽动修复（2026-05-18）：速度档切换时由 main.gd 调用，重置 interval/duration
# 估计，避免下一次 commit 算出"上次 push 到现在"的超长间隔（例如 x20→x1 切换
# 后第一段 lerp 会被算成几秒长，云突然变慢）。
func reset_snapshot_pacing() -> void:
	WeatherFrontBlend.reset_snapshot_pacing(self)

func set_weather_fronts(fronts: Array) -> void:
	WeatherFrontBlend.set_weather_fronts(self, fronts)

func _push_fronts_to_overlay(_fronts: Array) -> void:
	WeatherFrontBlend._push_fronts_to_overlay(self, _fronts)

func _push_empty_fronts_to_overlay() -> void:
	WeatherFrontBlend._push_empty_fronts_to_overlay(self)

const _MAX_WEATHER_TYPES   := 8

func _push_weather_profile_uniforms_to_overlay() -> void:
	WeatherFrontBlend._push_weather_profile_uniforms_to_overlay(self)

func _sync_particles_pool(fronts: Array) -> void:
	WeatherFrontBlend._sync_particles_pool(self, fronts)

func _disable_particle_slot(node: GPUParticles2D, slot_idx: int) -> void:
	WeatherFrontBlend._disable_particle_slot(self, node, slot_idx)

func _reset_front_blend_state() -> void:
	WeatherFrontBlend._reset_front_blend_state(self)

func _make_front_snapshots(fronts: Array) -> Array:
	return WeatherFrontBlend._make_front_snapshots(self, fronts)

func _align_front_blend_snapshots(start_candidates: Array, targets: Array) -> Array:
	return WeatherFrontBlend._align_front_blend_snapshots(self, start_candidates, targets)

func _fade_out_snapshot(snapshot: Dictionary) -> void:
	WeatherFrontBlend._fade_out_snapshot(self, snapshot)

func _update_weather_front_blend(delta: float) -> void:
	WeatherFrontBlend._update_weather_front_blend(self, delta)

func _filter_visible_front_snapshots(snapshots: Array) -> Array:
	return WeatherFrontBlend._filter_visible_front_snapshots(self, snapshots)

func _blend_front_snapshots(t: float) -> Array:
	return WeatherFrontBlend._blend_front_snapshots(self, t)

func _predict_front_snapshots(snapshots: Array, prediction_days: float) -> Array:
	return WeatherFrontBlend._predict_front_snapshots(self, snapshots, prediction_days)

func _front_center(front) -> Vector2:
	return WeatherFrontBlend._front_center(self, front)

func _front_radius(front) -> float:
	return WeatherFrontBlend._front_radius(self, front)

func _front_velocity(front) -> Vector2:
	return WeatherFrontBlend._front_velocity(self, front)

func _front_type(front) -> int:
	return WeatherFrontBlend._front_type(self, front)

func _front_intensity(front) -> float:
	return WeatherFrontBlend._front_intensity(self, front)

func _front_axis(front) -> Vector2:
	return WeatherFrontBlend._front_axis(self, front)

func _front_major_scale(front) -> float:
	return WeatherFrontBlend._front_major_scale(self, front)

func _front_minor_scale(front) -> float:
	return WeatherFrontBlend._front_minor_scale(self, front)

func _front_cloud_amount(front) -> float:
	return WeatherFrontBlend._front_cloud_amount(self, front)

func _front_precip_amount(front) -> float:
	return WeatherFrontBlend._front_precip_amount(self, front)

func _front_dissolve_amount(front) -> float:
	return WeatherFrontBlend._front_dissolve_amount(self, front)

func _front_life_progress(front) -> float:
	return WeatherFrontBlend._front_life_progress(self, front)

func _blend_axis(a: Vector2, b: Vector2, t: float) -> Vector2:
	return WeatherFrontBlend._blend_axis(self, a, b, t)

func _front_visual_intensity(raw_intensity: float) -> float:
	return WeatherFrontBlend._front_visual_intensity(self, raw_intensity)

func _particle_tod_tint_component(sun_component: float, ambient_component: float) -> float:
	return WeatherFrontBlend._particle_tod_tint_component(self, sun_component, ambient_component)


func _push_overlay_runtime_state() -> void:
	WeatherMaterialPublish._push_overlay_runtime_state(self)

func set_wind_luts(current: Texture2D, previous: Texture2D, has_previous: bool) -> void:
	WeatherMaterialPublish.set_wind_luts(self, current, previous, has_previous)

func _push_wind_luts() -> void:
	WeatherMaterialPublish._push_wind_luts(self)

func _uses_weather_endpoints() -> bool:
	return WeatherMaterialPublish._uses_weather_endpoints(self)

func _push_weather_table(force: bool = false) -> void:
	WeatherMaterialPublish._push_weather_table(self, force)

func _push_cell_field_uniforms() -> void:
	WeatherMaterialPublish._push_cell_field_uniforms(self)

func _resolve_map_dims() -> Vector2:
	return WeatherMaterialPublish._resolve_map_dims(self)

var _fog_field_band: float = FogOfWarLayerScript.FOG_FIELD_BAND


## 覆盖带宽（gap 单位）。默认值来自真源（`FogOfWarLayer.FOG_FIELD_BAND`），调用方通常
## 不需要改；上限 0.86 = PK_FIELD_BAND_MAX（shader 侧同一条约束，方案 §3.6 约束 1）。

func set_fog_field_band(v: float = FogOfWarLayerScript.FOG_FIELD_BAND) -> void:
	WeatherMaterialPublish.set_fog_field_band(self, v)

func _push_curtain_runtime_state() -> void:
	WeatherMaterialPublish._push_curtain_runtime_state(self)

func _load_overlay_shader() -> void:
	WeatherMaterialPublish._load_overlay_shader(self)

func _load_curtain_shader() -> void:
	WeatherMaterialPublish._load_curtain_shader(self)

func _rebuild_curtain_layers() -> void:
	WeatherMaterialPublish._rebuild_curtain_layers(self)

func _refresh_curtain_instances(update_usec: int, blending: bool) -> void:
	WeatherMaterialPublish._refresh_curtain_instances(self, update_usec, blending)

func _curtain_layer_capacity() -> int:
	return WeatherMaterialPublish._curtain_layer_capacity(self)

func _desired_curtain_layer_count() -> int:
	return WeatherMaterialPublish._desired_curtain_layer_count(self)

func _update_curtain_visibility() -> void:
	WeatherMaterialPublish._update_curtain_visibility(self)

func _init_particles_pool() -> void:
	WeatherMaterialPublish._init_particles_pool(self)

func _configure_particles_for_type(node: GPUParticles2D, wt: int) -> void:
	WeatherMaterialPublish._configure_particles_for_type(self, node, wt)

func _build_process_material_from_profile(profile: WeatherProfile) -> ParticleProcessMaterial:
	return WeatherMaterialPublish._build_process_material_from_profile(self, profile)

func _get_or_build_process_material(wt: int) -> ParticleProcessMaterial:
	return WeatherMaterialPublish._get_or_build_process_material(self, wt)

func _build_fallback_particle_texture() -> ImageTexture:
	return WeatherMaterialPublish._build_fallback_particle_texture(self)

func _build_full_quad(bounds: Rect2, wrap_period_x: float = 0.0) -> Mesh:
	return WeatherMaterialPublish._build_full_quad(self, bounds, wrap_period_x)
