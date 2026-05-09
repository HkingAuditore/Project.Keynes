# hex_renderer.gd v5
# 单一全屏 quad mesh + WorldData 的 4 张高分辨率纹理 + world_map.gdshader v5。
class_name HexRenderer
extends Node2D

@export var hex_size: float = 22.0:
	set(v):
		hex_size = maxf(4.0, v)
		if is_inside_tree():
			_rebuild()

@export var shader_path: String = "res://shaders/world_map.gdshader"

# ─── Hypsometric 色阶（海陆双向，从深到浅） ──────────────────────────────
# Open Ocean Color Rebalance v2：与 world_map.gdshader 同步，把深/浅海亮度差
# 从 Δ=0.36 收敛到 Δ=0.22，避免"浅海发亮、深海近黑"的强烈对比。
# 旧 (v1) / 新 (v2)：
#   (0.10,0.18,0.30) → (0.14,0.22,0.34)   (0.16,0.28,0.40) → (0.20,0.30,0.42)
#   (0.27,0.45,0.56) → (0.28,0.42,0.52)   (0.40,0.62,0.66) → (0.34,0.50,0.56)
@export_group("Hypsometric Colors")
@export var color_deep_ocean: Color = Color(0.14, 0.22, 0.34)
@export var color_mid_ocean: Color = Color(0.20, 0.30, 0.42)
@export var color_shallow: Color = Color(0.28, 0.42, 0.52)
@export var color_coast_water: Color = Color(0.34, 0.50, 0.56)
@export var color_beach: Color = Color(0.85, 0.78, 0.55)
@export var color_lowland: Color = Color(0.62, 0.68, 0.42)
@export var color_hill: Color = Color(0.66, 0.55, 0.32)
@export var color_mountain: Color = Color(0.50, 0.42, 0.38)
@export var color_peak: Color = Color(0.65, 0.62, 0.60)
@export var color_snow: Color = Color(0.96, 0.96, 0.96)

# ─── 双光源 hillshading ──────────────────────────────────────────────────
@export_group("Hillshading")
@export_range(0.0, 1.0, 0.01) var hillshade_strength: float = 0.45
@export_range(0.5, 24.0, 0.5) var hillshade_slope_gain: float = 8.0

# ─── 河流 ────────────────────────────────────────────────────────────────
# v6：flow_tex 是 SDF 反距离编码（1=河中心，0=>=SDF_MAX_DIST_PX 远）。
# baker 的 SDF_MAX_DIST_PX = 8 像素 ≈ 0.4 hex_size。
# threshold_low=外圈 outline 起点，threshold_high=内圈主色完全。
@export_group("Rivers")
@export_range(0.0, 1.0, 0.01) var river_strength: float = 0.85
@export_range(0.0, 1.0, 0.01) var river_threshold_low: float = 0.55
@export_range(0.0, 1.0, 0.01) var river_threshold_high: float = 0.85
@export var river_color: Color = Color(0.30, 0.50, 0.68)
@export var river_outline_color: Color = Color(0.16, 0.30, 0.45)

# ─── 可选等高线 ──────────────────────────────────────────────────────────
@export_group("Contour Lines")
@export var contour_enabled: bool = false
@export_range(0.01, 0.20, 0.005) var contour_step: float = 0.05
@export_range(0.0, 0.40, 0.01) var contour_strength: float = 0.18
@export var contour_color: Color = Color(0.20, 0.16, 0.10)

# ─── 海岸光晕 ─────────────────────────────────────────────────────────────
@export_group("Coast Halo")
@export var coast_halo_color: Color = Color(0.78, 0.86, 0.88)
@export_range(0.0, 1.0, 0.01) var coast_halo_strength: float = 0.22

# ─── 羊皮纸 ───────────────────────────────────────────────────────────────
@export_group("Atlas Paper")
@export var parchment_tint: Color = Color(0.96, 0.88, 0.74)
@export_range(0.0, 0.4, 0.01) var parchment_strength: float = 0.10
@export_range(0.0, 0.2, 0.01) var paper_grain_strength: float = 0.05

# ─── 季节 / 气候系统（每帧由 main.gd 通过 set_*_phase 推进） ─────────────
@export_group("Climate")
@export_range(0.0, 0.4, 0.01) var season_temp_amp: float = 0.20
@export_range(0.0, 1.0, 0.01) var vegetation_season_strength: float = 0.85
@export_range(0.0, 1.0, 0.01) var dynamic_snow_strength: float = 0.85
@export_range(0.0, 1.0, 0.01) var ocean_current_strength: float = 0.88
@export_range(0.0, 0.20, 0.01) var wind_streak_strength: float = 0.05
@export_range(0.0, 1.0, 0.01) var season_transition_phase_span: float = 0.33
@export_range(0.02, 0.45, 0.01) var season_transition_softness: float = 0.18

# True Insolation-Driven（Phase F）：CPU / GPU 同源的四个参数。默认与 ClimateProfile 一致。
# 运行时由 main.gd 通过 set_true_insolation_params() 同步（F8 切换时）。
@export_group("True Insolation (Phase F)")
@export var true_insolation_enabled: bool = true
@export_range(0.0, 45.0, 0.5) var axial_tilt_deg: float = 23.5
@export_range(0.0, 1.0, 0.01) var insolation_daylen_amp: float = 0.35
@export_range(0.0, 2.0, 0.05) var insolation_season_gain: float = 1.0

# ─── Milestone 2：植被 / 覆盖物双通道（与 biome_tex 同分辨率，NEAREST 采样） ──
# vegetation_axis_strength：HILL/MOUNTAIN/PLAIN 等"主色单一"的地形上，按真实
# 植被 id 给 col 做轻度色相调制。0 关闭、1.0 完全替换成植被 tint × 原色。
# cover_axis_strength：FLOODING/PERMAFROST/GLACIER 等覆盖物在 fragment 末尾的
# 叠加强度（SNOW 仍走原 dynamic_snow 路径，避免与 snow_factor 双叠）。
@export_group("Axes (Milestone 2)")
@export_range(0.0, 1.0, 0.01) var vegetation_axis_strength: float = 0.35
@export_range(0.0, 1.0, 0.01) var cover_axis_strength: float = 0.65

# ─── Milestone 3：天气 overlay 总强度（0 关闭，1 全力） ─────────────────
@export_group("Weather (Milestone 3)")
@export_range(0.0, 1.0, 0.01) var weather_strength: float = 1.0

# ─── Visual Overhaul（任务 1）：视觉总开关 ────────────────────────
# 这组变量由 main.gd 通过 set_*() 推进；shader 分支逐步在任务 3~9 中接入。
# 默认值与 main.gd 一致，保证 renderer 被单独调试时也有合理初值。
@export_group("Visual Overhaul")
@export_range(0, 2, 1) var visual_quality: int = 2
@export var day_night_enabled: bool = true
@export var water_effect_enabled: bool = true
@export var ocean_current_enabled: bool = true
@export var extreme_weather_ground_effect_enabled: bool = true
@export var perf_sampler_enabled: bool = false

# ─── Visual Pass 2：TOD 消费端开关 ─────────────────────────────────────
# 这三个开关由 main.gd 的同名 @export 推进，到达 shader 内同名 uniform。
# water_sparkle_enabled：水面高频粼光（任务 4）
# rain_density_boost_enabled：粒子数量提升（任务 5，renderer 仅转发到 WeatherLayer）
# cloud_tod_tint_enabled：云层 TOD 染色（任务 6）
@export_group("Pass 2")
@export var water_sparkle_enabled: bool = true
@export var rain_density_boost_enabled: bool = true
@export var cloud_tod_tint_enabled: bool = true

# ─── Water Visual Overhaul（本轮）：水体细分开关与参数 ──────────────────
# 所有字段直通 shader 同名 uniform；关闭即回退到上一轮（pass2）表现，
# 总开关 water_effect_enabled=false 时整组子特性被 shader 端短路。
@export_group("Water Overhaul")
@export var water_waves_enabled: bool = true
@export var water_fresnel_enabled: bool = true
@export var river_flow_enabled: bool = true
@export var caustics_enabled: bool = true
@export var shallow_transparency_enabled: bool = true
@export_range(4.0, 128.0, 0.5) var water_gloss: float = 34.0
@export_range(0.0, 1.0, 0.01) var water_reflection_strength: float = 0.32
@export_range(0.0, 4.0, 0.05) var river_flow_speed: float = 0.75
@export_range(0.02, 1.0, 0.01) var river_flow_freq: float = 0.16
@export_range(0.0, 1.0, 0.01) var caustics_strength: float = 0.32
@export_range(0.5, 3.0, 0.05) var deep_ocean_contrast: float = 0.96
@export var lake_water_color: Color = Color(0.20, 0.48, 0.56)
@export_range(0.0, 1.0, 0.01) var shallow_transparency_factor: float = 0.56
# ShaderToy 启发的视觉增强（软边过渡 + 柔和噪声层）
# 说明：`water_wave_line_strength` 在 Water Calm Noise 改造后语义变为
@export_range(0.0, 4.0, 0.05) var water_domain_warp_strength: float = 1.45
@export_range(0.0, 1.0, 0.01) var water_wave_line_strength: float = 0.70
# 柔和噪声的两个独立细分强度：
# Open Ocean Color Rebalance：在新 base palette（已去饱和）上，把扰动幅度
# 从 0.70 抬到 0.95，使原本肉眼难辨的 ±5% 亮度 / ±2% 色相变化更可见，
# 让外海具备"云影感"色斑变化，而非一片均一。旧值 / 新值：0.70 / 0.95。
@export_range(0.0, 1.0, 0.01) var water_calm_noise_brightness: float = 0.95
@export_range(0.0, 1.0, 0.01) var water_calm_noise_tint_strength: float = 0.95
@export_range(0.0, 4.0, 0.05) var water_biome_blend_radius: float = 3.15
@export_range(0.0, 1.0, 0.01) var water_cartoon_color_strength: float = 0.75
@export_range(0.0, 1.0, 0.01) var water_transition_softness: float = 1.0
@export_range(0.0, 1.0, 0.01) var estuary_plume_strength: float = 0.65

# ─── 兼容字段（旧 .tscn 写过这些值，保留接收以避免反序列化警告） ─────────
@export_group("Legacy (Unused)")
@export var hex_overscan: float = 1.45
@export var draw_rivers: bool = true
@export var domain_warp_amp: float = 0.0
@export var domain_warp_freq: float = 0.0
@export var warp_high_freq_mul: float = 0.0
@export var warp_high_freq_amp_ratio: float = 0.0
@export var boundary_blend_start: float = 0.0
@export var boundary_blend_end: float = 0.0
@export var boundary_blend_max: float = 0.0
@export var river_width_factor: float = 0.0
@export var coast_halo_outer_px: float = 0.0
@export var coast_halo_inner_px: float = 0.0
@export var beach_band_px: float = 0.0
@export var coast_dash_freq: float = 0.0
@export var coast_dash_strength: float = 0.0
@export var beach_color: Color = Color(0.86, 0.78, 0.52)
@export var coast_foam_color: Color = Color(0.78, 0.86, 0.88)
@export var coast_foam_outer_px: float = 0.0
@export var sdf_resolution: Vector2i = Vector2i(0, 0)
@export var global_darken: float = 0.0

var _world_quad: MeshInstance2D
var _season_transition_quad: MeshInstance2D
var _shader_mat: ShaderMaterial
var _season_transition_mat: ShaderMaterial = null
var _weather_layer: WeatherLayer = null  # v9.split：天气独立层
var _map: MapData = null
var _world: WorldData = null

# Phase 1：季节状态（每帧/每天由 WorldClock 推送）
var _season_phase: float = 1.0   # 0=spring 1=summer 2=autumn 3=winter
var _climate_anomaly: float = 0.0
var _world_time: float = 0.0
var _season_transition_active: bool = false
var _season_transition_start_phase: float = 1.0
# 任务 2：昼夜相位 ∈ [0,1)，由 WorldClock 节流推送。
var _day_phase: float = 0.25   # 初始化正午，保证新地图默认白天效果
# Milestone 3：天气子系统数组上传
# 与 shader 端 weather_front_centers[MAX_WEATHER_FRONTS] 长度严格一致；
# 0 fronts 时仍填满 16 个 zero-vec，避免 shader 端越界采样。
const MAX_WEATHER_FRONTS := 16

# ─── 任务 1：性能采样器（30 秒窗口内 avg + P95） ───────────────────────
# 统计窗口通过 ring buffer，不分配；每 REPORT_INTERVAL_SEC 打印一次结果。
# 默认关闭，只有 perf_sampler_enabled == true 时才统计与打印。
class PerfSampler:
	const REPORT_INTERVAL_SEC: float = 30.0
	const MAX_SAMPLES: int = 1800  # 30s × 60fps
	var _samples: PackedFloat32Array
	var _write_idx: int = 0
	var _count: int = 0
	var _elapsed: float = 0.0
	var _label: String = "PerfSampler"

	func _init() -> void:
		_samples = PackedFloat32Array()
		_samples.resize(MAX_SAMPLES)

	func set_label(l: String) -> void:
		_label = l

	func push_frame_ms(frame_ms: float) -> void:
		_samples[_write_idx] = frame_ms
		_write_idx = (_write_idx + 1) % MAX_SAMPLES
		if _count < MAX_SAMPLES:
			_count += 1
		_elapsed += frame_ms / 1000.0
		if _elapsed >= REPORT_INTERVAL_SEC:
			_report()
			_elapsed = 0.0

	func reset() -> void:
		_write_idx = 0
		_count = 0
		_elapsed = 0.0

	func _report() -> void:
		if _count <= 0:
			return
		var sorted := PackedFloat32Array()
		sorted.resize(_count)
		for i in range(_count):
			sorted[i] = _samples[i]
		var arr := Array(sorted)
		arr.sort()
		var total: float = 0.0
		for v in arr:
			total += float(v)
		var avg: float = total / float(_count)
		var p95_idx: int = clampi(int(float(_count) * 0.95), 0, _count - 1)
		var p95: float = float(arr[p95_idx])
		var avg_fps: float = 1000.0 / maxf(avg, 0.001)
		print_rich(
			"[color=cyan][%s][/color] 30s samples=%d  avg=%.2fms (%.1f FPS)  P95=%.2fms" %
			[_label, _count, avg, avg_fps, p95]
		)

var _perf_sampler: PerfSampler = null

func _ready() -> void:
	_world_quad = MeshInstance2D.new()
	_world_quad.name = "WorldQuad"
	_world_quad.z_index = 0
	add_child(_world_quad)
	_season_transition_quad = MeshInstance2D.new()
	_season_transition_quad.name = "SeasonTransitionQuad"
	_season_transition_quad.z_index = 0
	_season_transition_quad.visible = false
	add_child(_season_transition_quad)
	# v9.split：天气表现层
	_weather_layer = WeatherLayer.new()
	_weather_layer.name = "WeatherLayer"
	_weather_layer.visual_fronts_changed.connect(_on_weather_layer_visual_fronts_changed)
	add_child(_weather_layer)
	_load_shader()
	if _map != null and _world != null:
		_rebuild()
	set_process(true)

# 每帧把 world_time 推进给 shader（驱动洋流流纹）
# 注意：这里只 push 一个 float uniform，几乎零开销
func _process(delta: float) -> void:
	if _shader_mat == null:
		return
	_world_time += delta
	_shader_mat.set_shader_parameter("world_time", _world_time)
	if _season_transition_mat != null:
		_season_transition_mat.set_shader_parameter("world_time", _world_time)
		_update_season_transition()
	# 任务 1：性能采样（仅当 perf_sampler_enabled 为 true 时启用）
	if _perf_sampler != null:
		_perf_sampler.push_frame_ms(delta * 1000.0)

func _load_shader() -> void:
	var shader := ResourceLoader.load(shader_path, "Shader", ResourceLoader.CACHE_MODE_IGNORE) as Shader
	if shader == null:
		push_warning("HexRenderer: shader not found at %s" % shader_path)
		return
	_shader_mat = ShaderMaterial.new()
	_shader_mat.shader = shader
	_world_quad.material = _shader_mat

# ─── 对外接口 ────────────────────────────────────────────────────────────

func set_map(map: MapData, world: WorldData = null) -> void:
	var replacing_world := _world != null and world != null and _world != world
	_map = map
	_world = world
	if replacing_world:
		_clear_season_transition()
	if is_inside_tree():
		_rebuild()

func begin_season_transition(start_phase: float) -> void:
	if _shader_mat == null or _world_quad == null or _world == null or _world.enum_atlas_tex == null:
		return
	if _world_quad.mesh == null:
		return
	var img := _world.enum_atlas_tex.get_image()
	if img == null or img.is_empty():
		return
	var enum_snapshot := ImageTexture.create_from_image(img.duplicate())
	_season_transition_mat = _shader_mat.duplicate() as ShaderMaterial
	if _season_transition_mat == null:
		return
	_season_transition_mat.set_shader_parameter("enum_atlas", enum_snapshot)
	_season_transition_mat.set_shader_parameter("season_transition_overlay", true)
	_season_transition_mat.set_shader_parameter("season_transition_progress", 0.0)
	_season_transition_mat.set_shader_parameter("season_transition_softness", season_transition_softness)
	# Weather is rendered by WeatherLayer; disabling terrain weather tint here avoids double tinting.
	_season_transition_mat.set_shader_parameter("weather_strength", 0.0)
	_season_transition_quad.mesh = _world_quad.mesh
	_season_transition_quad.material = _season_transition_mat
	_season_transition_quad.visible = true
	_season_transition_active = true
	_season_transition_start_phase = fposmod(start_phase, 4.0)

func _clear_season_transition() -> void:
	_season_transition_active = false
	_season_transition_mat = null
	if _season_transition_quad != null:
		_season_transition_quad.visible = false
		_season_transition_quad.material = null
		_season_transition_quad.mesh = null

func _update_season_transition() -> void:
	if not _season_transition_active or _season_transition_mat == null:
		return
	var span := maxf(season_transition_phase_span, 0.001)
	var elapsed := fposmod(_season_phase - _season_transition_start_phase, 4.0)
	var progress := clampf(elapsed / span, 0.0, 1.0)
	_season_transition_mat.set_shader_parameter("season_transition_progress", progress)
	_season_transition_mat.set_shader_parameter("season_transition_softness", season_transition_softness)
	if progress >= 1.0:
		_clear_season_transition()

func get_world_bounds() -> Rect2:
	if _world != null:
		return _world.world_bounds
	if _map != null and _map.cell_count() > 0:
		return MapBaker.compute_world_bounds(_map.width, _map.height, hex_size)
	return Rect2()

# Phase 1：让 main.gd 在 WorldClock day_changed 时推进 shader 季节相位
func set_season_phase(phase: float) -> void:
	_season_phase = phase
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("season_phase", _season_phase)
	if _season_transition_mat != null:
		_season_transition_mat.set_shader_parameter("season_phase", _season_phase)
		_update_season_transition()

func set_climate_anomaly(v: float) -> void:
	_climate_anomaly = v
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("climate_anomaly", _climate_anomaly)
	if _season_transition_mat != null:
		_season_transition_mat.set_shader_parameter("climate_anomaly", _climate_anomaly)

# True Insolation-Driven（Phase F）：运行时切换 insolation 主开关（F8 配套），
# 让 shader 画面与 CPU 端温度物理保持同步。
func set_true_insolation_enabled(v: bool) -> void:
	true_insolation_enabled = v
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("true_insolation_enabled", true_insolation_enabled)
	if _season_transition_mat != null:
		_season_transition_mat.set_shader_parameter("true_insolation_enabled", true_insolation_enabled)

# 任务 2：昼夜相位。由 main.gd 接收 WorldClock.day_phase_changed 信号后转发。
# 同时写入地形 shader 与 weather overlay shader（两者都需要昼夜相位。但后者
func set_day_phase(v: float) -> void:
	_day_phase = fposmod(v, 1.0)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("day_phase", _day_phase)
	if _season_transition_mat != null:
		_season_transition_mat.set_shader_parameter("day_phase", _day_phase)
	if _weather_layer != null:
		_weather_layer.set_day_phase(_day_phase)

# ─── 任务 1：视觉总开关 setter ─────────────────────────────────────────
#   2) 把对应 uniform 推到 shader（名字与后续任务 shader 分支匹配）；
func set_visual_quality(q: int) -> void:
	visual_quality = clampi(q, 0, 2)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("visual_quality", visual_quality)
	if _weather_layer != null:
		_weather_layer.set_visual_quality(visual_quality)

func set_day_night_enabled(v: bool) -> void:
	day_night_enabled = v
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("day_night_enabled", day_night_enabled)
	if _weather_layer != null:
		_weather_layer.set_day_night_enabled(day_night_enabled)

func set_water_effect_enabled(v: bool) -> void:
	water_effect_enabled = v
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("water_effect_enabled", water_effect_enabled)

func set_ocean_current_enabled(v: bool) -> void:
	ocean_current_enabled = v
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("ocean_current_enabled", ocean_current_enabled)

# 任务 9：ocean_current_debug toggle —— F6 快捷键 / UI 顶栏按钮均写这里。
# debug=true 时 shader 水分支把流线振幅拉大 2.5× 并叠加方向提示色；
var _ocean_current_debug: bool = false

func set_ocean_current_debug(v: bool) -> void:
	_ocean_current_debug = v
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("ocean_current_debug", _ocean_current_debug)

func get_ocean_current_debug() -> bool:
	return _ocean_current_debug

func set_extreme_weather_ground_effect_enabled(v: bool) -> void:
	extreme_weather_ground_effect_enabled = v
	if _shader_mat != null:
		_shader_mat.set_shader_parameter(
			"extreme_weather_ground_effect_enabled",
			extreme_weather_ground_effect_enabled
		)
	if _weather_layer != null:
		_weather_layer.set_extreme_weather_ground_effect_enabled(
			extreme_weather_ground_effect_enabled
		)

func set_perf_sampler_enabled(v: bool) -> void:
	perf_sampler_enabled = v
	if perf_sampler_enabled:
		if _perf_sampler == null:
			_perf_sampler = PerfSampler.new()
			_perf_sampler.set_label("HexRenderer")
		else:
			_perf_sampler.reset()
	else:
		_perf_sampler = null

# ─── Pass 2（任务 2）：apply_tod + 新增开关 setter ──────────────────────────
# 地表 shader 与 WeatherLayer 的 overlay shader。首帧必须显式调用以避免
func apply_tod(profile: TODProfile) -> void:
	if profile == null:
		return
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("tod_sun_dir", profile.sun_dir)
		_shader_mat.set_shader_parameter(
			"tod_sun_color",
			Vector3(profile.sun_color.r, profile.sun_color.g, profile.sun_color.b)
		)
		_shader_mat.set_shader_parameter(
			"tod_ambient_color",
			Vector3(profile.ambient_color.r, profile.ambient_color.g, profile.ambient_color.b)
		)
		_shader_mat.set_shader_parameter("tod_night_factor", profile.night_factor)
		_shader_mat.set_shader_parameter("tod_exposure", profile.exposure)
	if _season_transition_mat != null:
		_season_transition_mat.set_shader_parameter("tod_sun_dir", profile.sun_dir)
		_season_transition_mat.set_shader_parameter(
			"tod_sun_color",
			Vector3(profile.sun_color.r, profile.sun_color.g, profile.sun_color.b)
		)
		_season_transition_mat.set_shader_parameter(
			"tod_ambient_color",
			Vector3(profile.ambient_color.r, profile.ambient_color.g, profile.ambient_color.b)
		)
		_season_transition_mat.set_shader_parameter("tod_night_factor", profile.night_factor)
		_season_transition_mat.set_shader_parameter("tod_exposure", profile.exposure)
	if _weather_layer != null and _weather_layer.has_method("apply_tod"):
		_weather_layer.apply_tod(profile)

func set_water_sparkle_enabled(v: bool) -> void:
	water_sparkle_enabled = v
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("water_sparkle_enabled", water_sparkle_enabled)

func set_rain_density_boost_enabled(v: bool) -> void:
	if _weather_layer != null and _weather_layer.has_method("set_rain_density_boost_enabled"):
		_weather_layer.set_rain_density_boost_enabled(v)

func set_cloud_tod_tint_enabled(v: bool) -> void:
	cloud_tod_tint_enabled = v
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("cloud_tod_tint_enabled", cloud_tod_tint_enabled)
	if _weather_layer != null and _weather_layer.has_method("set_cloud_tod_tint_enabled"):
		_weather_layer.set_cloud_tod_tint_enabled(v)

# ─── Water Visual Overhaul：子特性 setter 组 ──────────────────────────
# 每个 setter 只做"字段写回 + shader uniform 同步"，让 main.gd 能逐个切换。
func set_water_waves_enabled(v: bool) -> void:
	water_waves_enabled = v
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("water_waves_enabled", water_waves_enabled)

func set_water_fresnel_enabled(v: bool) -> void:
	water_fresnel_enabled = v
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("water_fresnel_enabled", water_fresnel_enabled)

func set_river_flow_enabled(v: bool) -> void:
	river_flow_enabled = v
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("river_flow_enabled", river_flow_enabled)

func set_caustics_enabled(v: bool) -> void:
	caustics_enabled = v
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("caustics_enabled", caustics_enabled)

func set_shallow_transparency_enabled(v: bool) -> void:
	shallow_transparency_enabled = v
	if _shader_mat != null:
		_shader_mat.set_shader_parameter(
			"shallow_transparency_enabled",
			shallow_transparency_enabled
		)

func set_water_gloss(v: float) -> void:
	water_gloss = clampf(v, 4.0, 128.0)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("water_gloss", water_gloss)

func set_water_reflection_strength(v: float) -> void:
	water_reflection_strength = clampf(v, 0.0, 1.0)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter(
			"water_reflection_strength",
			water_reflection_strength
		)

func set_river_flow_speed(v: float) -> void:
	river_flow_speed = clampf(v, 0.0, 4.0)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("river_flow_speed", river_flow_speed)

func set_river_flow_freq(v: float) -> void:
	river_flow_freq = clampf(v, 0.02, 1.0)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("river_flow_freq", river_flow_freq)

func set_caustics_strength(v: float) -> void:
	caustics_strength = clampf(v, 0.0, 1.0)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("caustics_strength", caustics_strength)

func set_deep_ocean_contrast(v: float) -> void:
	deep_ocean_contrast = clampf(v, 0.5, 3.0)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("deep_ocean_contrast", deep_ocean_contrast)

func set_lake_water_color(c: Color) -> void:
	lake_water_color = c
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("lake_water_color", lake_water_color)

func set_shallow_transparency_factor(v: float) -> void:
	shallow_transparency_factor = clampf(v, 0.0, 1.0)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter(
			"shallow_transparency_factor",
			shallow_transparency_factor
		)

# ShaderToy 启发：三个新视觉 setter（域扭曲 / 风格化波痕 / biome 软混合）
func set_water_domain_warp_strength(v: float) -> void:
	water_domain_warp_strength = clampf(v, 0.0, 4.0)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter(
			"water_domain_warp_strength",
			water_domain_warp_strength
		)

func set_water_wave_line_strength(v: float) -> void:
	water_wave_line_strength = clampf(v, 0.0, 1.0)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter(
			"water_wave_line_strength",
			water_wave_line_strength
		)

func set_water_calm_noise_brightness(v: float) -> void:
	water_calm_noise_brightness = clampf(v, 0.0, 1.0)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter(
			"water_calm_noise_brightness",
			water_calm_noise_brightness
		)

func set_water_calm_noise_tint_strength(v: float) -> void:
	water_calm_noise_tint_strength = clampf(v, 0.0, 1.0)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter(
			"water_calm_noise_tint_strength",
			water_calm_noise_tint_strength
		)

func set_water_biome_blend_radius(v: float) -> void:
	water_biome_blend_radius = clampf(v, 0.0, 4.0)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter(
			"water_biome_blend_radius",
			water_biome_blend_radius
		)

func set_water_cartoon_color_strength(v: float) -> void:
	water_cartoon_color_strength = clampf(v, 0.0, 1.0)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter(
			"water_cartoon_color_strength",
			water_cartoon_color_strength
		)

func set_water_transition_softness(v: float) -> void:
	water_transition_softness = clampf(v, 0.0, 1.0)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter(
			"water_transition_softness",
			water_transition_softness
		)

func set_estuary_plume_strength(v: float) -> void:
	estuary_plume_strength = clampf(v, 0.0, 1.0)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter(
			"estuary_plume_strength",
			estuary_plume_strength
		)

# Upload active weather fronts to both the terrain shader and the weather layer.
func set_weather_fronts(fronts: Array) -> void:
	if _weather_layer != null:
		_weather_layer.set_weather_fronts(fronts)
	else:
		_push_weather_fronts_to_shader(fronts)

func _on_weather_layer_visual_fronts_changed(fronts: Array) -> void:
	_push_weather_fronts_to_shader(fronts)

func _push_weather_fronts_to_shader(fronts: Array) -> void:
	if _shader_mat == null:
		return
	var centers := PackedVector4Array()
	var shapes := PackedVector4Array()
	var visuals := PackedVector4Array()
	var types := PackedFloat32Array()
	centers.resize(MAX_WEATHER_FRONTS)
	shapes.resize(MAX_WEATHER_FRONTS)
	visuals.resize(MAX_WEATHER_FRONTS)
	types.resize(MAX_WEATHER_FRONTS)
	var n: int = mini(fronts.size(), MAX_WEATHER_FRONTS)
	for i in range(MAX_WEATHER_FRONTS):
		if i < n:
			var f = fronts[i]
			var c: Vector2 = _front_center(f)
			centers[i] = Vector4(c.x, c.y, _front_radius(f), _front_intensity(f))
			var ax: Vector2 = _front_axis(f)
			shapes[i] = Vector4(ax.x, ax.y, _front_major_scale(f), _front_minor_scale(f))
			visuals[i] = Vector4(
				_front_cloud_amount(f),
				_front_precip_amount(f),
				_front_dissolve_amount(f),
				_front_life_progress(f)
			)
			types[i] = float(_front_type(f))
		else:
			centers[i] = Vector4.ZERO
			shapes[i] = Vector4(1.0, 0.0, 1.0, 1.0)
			visuals[i] = Vector4.ZERO
			types[i] = -1.0
	_shader_mat.set_shader_parameter("weather_front_centers", centers)
	_shader_mat.set_shader_parameter("weather_front_shapes", shapes)
	_shader_mat.set_shader_parameter("weather_front_visuals", visuals)
	_shader_mat.set_shader_parameter("weather_front_types", types)
	_shader_mat.set_shader_parameter("weather_front_count", n)

func _front_center(front) -> Vector2:
	if front is Dictionary:
		return front.get("center", Vector2.ZERO)
	return front.center

func _front_radius(front) -> float:
	if front is Dictionary:
		return float(front.get("radius", 0.0))
	return float(front.radius)

func _front_type(front) -> int:
	if front is Dictionary:
		return int(front.get("type", WeatherType.WT.CLEAR))
	return int(front.type)

func _front_intensity(front) -> float:
	if front is Dictionary:
		return clampf(float(front.get("intensity", 0.0)), 0.0, 1.0)
	return clampf(float(front.intensity), 0.0, 1.0)

func _front_axis(front) -> Vector2:
	var ax: Vector2 = Vector2.RIGHT
	if front is Dictionary:
		ax = front.get("axis", Vector2.RIGHT)
	elif front.has_method("normalized_axis"):
		ax = front.normalized_axis()
	if ax.length_squared() <= 0.0001:
		return Vector2.RIGHT
	return ax.normalized()

func _front_major_scale(front) -> float:
	if front is Dictionary:
		return maxf(float(front.get("major_scale", 1.0)), 0.05)
	return maxf(float(front.major_scale), 0.05)

func _front_minor_scale(front) -> float:
	if front is Dictionary:
		return maxf(float(front.get("minor_scale", 1.0)), 0.05)
	return maxf(float(front.minor_scale), 0.05)

func _front_cloud_amount(front) -> float:
	if front is Dictionary:
		return clampf(float(front.get("cloud_amount", _front_intensity(front))), 0.0, 1.0)
	return clampf(float(front.cloud_amount), 0.0, 1.0)

func _front_precip_amount(front) -> float:
	if front is Dictionary:
		return clampf(float(front.get("precip_amount", _front_intensity(front))), 0.0, 1.0)
	return clampf(float(front.precip_amount), 0.0, 1.0)

func _front_dissolve_amount(front) -> float:
	if front is Dictionary:
		return clampf(float(front.get("dissolve_amount", 0.0)), 0.0, 1.0)
	return clampf(float(front.dissolve_amount), 0.0, 1.0)

func _front_life_progress(front) -> float:
	if front is Dictionary:
		return clampf(float(front.get("life_progress", 0.0)), 0.0, 1.0)
	return clampf(float(front.life_progress), 0.0, 1.0)

func _rebuild() -> void:
	if _world_quad == null:
		return
	if _map == null or _world == null or _map.cell_count() == 0:
		_world_quad.mesh = null
		return

	_world_quad.mesh = _build_world_quad_mesh(_world.world_bounds)
	if _shader_mat == null:
		return
	_apply_uniforms()

func _build_world_quad_mesh(bounds: Rect2) -> Mesh:
	var p := bounds.position
	var s := bounds.size
	var verts := PackedVector2Array([
		p,
		p + Vector2(s.x, 0.0),
		p + s,
		p + Vector2(0.0, s.y),
	])
	var indices := PackedInt32Array([0, 1, 2, 0, 2, 3])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

func _apply_uniforms() -> void:
	var sm := _shader_mat
	var bounds := _world.world_bounds

	# v9.atlas：原 10 张 sampler 压成 4 张（height + 3 atlas）+ 共享 noise_tex
	sm.set_shader_parameter("height_tex",   _world.height_tex)
	sm.set_shader_parameter("enum_atlas",   _world.enum_atlas_tex)
	sm.set_shader_parameter("scalar_atlas", _world.scalar_atlas_tex)
	sm.set_shader_parameter("vector_atlas", _world.vector_atlas_tex)
	# 火山强度场独立纹理（让位给 scalar_atlas.a 的连续 sea_ice_fraction）
	sm.set_shader_parameter("volcano_field_tex", _world.volcano_field_tex)
	# Daily Sim SoA Refactor 阶段 1：海冰覆盖率独立 R8（原 scalar_atlas.a 已让位）。
	# 由 SeaIceAtlasUploadJob 每 stride 日通过 MapBaker.bake_sea_ice_fraction_only 上传。
	sm.set_shader_parameter("sea_ice_tex", _world.sea_ice_tex)
	# Systemic Ocean Currents：上升流 R8（F6 调试层消费，主路径不采样）
	sm.set_shader_parameter("ocean_upwelling_tex", _world.upwelling_tex)
	# v9.fbm-opt：把共享 noise_tex 喂给地形 shader，替换 value_noise 内部的 4× hash21
	sm.set_shader_parameter("noise_tex",    _world.noise_tex)

	sm.set_shader_parameter("world_origin", bounds.position)
	sm.set_shader_parameter("world_size", bounds.size)
	sm.set_shader_parameter("hm_resolution", Vector2(_world.hm_size.x, _world.hm_size.y))
	sm.set_shader_parameter("derived_resolution", Vector2(_world.derived_size.x, _world.derived_size.y))
	sm.set_shader_parameter("sea_level", _world.sea_level)

	sm.set_shader_parameter("season_phase", _season_phase)
	sm.set_shader_parameter("climate_anomaly", _climate_anomaly)
	sm.set_shader_parameter("world_time", _world_time)
	# 任务 2：把当前 day_phase 同步到新创建的材质上
	sm.set_shader_parameter("day_phase", _day_phase)
	sm.set_shader_parameter("season_temp_amp", season_temp_amp)
	# True Insolation-Driven：CPU / GPU 同源的四个参数输出到 shader
	sm.set_shader_parameter("true_insolation_enabled", true_insolation_enabled)
	sm.set_shader_parameter("axial_tilt_rad", deg_to_rad(axial_tilt_deg))
	sm.set_shader_parameter("insolation_daylen_amp", insolation_daylen_amp)
	sm.set_shader_parameter("insolation_season_gain", insolation_season_gain)
	sm.set_shader_parameter("vegetation_season_strength", vegetation_season_strength)
	sm.set_shader_parameter("dynamic_snow_strength", dynamic_snow_strength)
	sm.set_shader_parameter("ocean_current_strength", ocean_current_strength)
	sm.set_shader_parameter("wind_streak_strength", wind_streak_strength)
	sm.set_shader_parameter("vegetation_axis_strength", vegetation_axis_strength)
	sm.set_shader_parameter("cover_axis_strength", cover_axis_strength)
	# Seasonal transition is only enabled on the temporary old-terrain overlay.
	sm.set_shader_parameter("season_transition_overlay", false)
	sm.set_shader_parameter("season_transition_progress", 1.0)
	sm.set_shader_parameter("season_transition_softness", season_transition_softness)

	# Milestone 3：默认填空 weather 数组 + 设全局 weather 强度
	sm.set_shader_parameter("weather_strength", weather_strength)

	sm.set_shader_parameter("visual_quality", visual_quality)
	sm.set_shader_parameter("day_night_enabled", day_night_enabled)
	sm.set_shader_parameter("water_effect_enabled", water_effect_enabled)
	sm.set_shader_parameter("ocean_current_enabled", ocean_current_enabled)
	sm.set_shader_parameter(
		"extreme_weather_ground_effect_enabled",
		extreme_weather_ground_effect_enabled
	)
	# Pass 2（任务 2）：把 Pass 2 开关也同步到新建材质上
	sm.set_shader_parameter("water_sparkle_enabled", water_sparkle_enabled)
	sm.set_shader_parameter("cloud_tod_tint_enabled", cloud_tod_tint_enabled)
	sm.set_shader_parameter("ocean_current_debug", _ocean_current_debug)

	# Water Visual Overhaul：首次建材质必须把本轮 uniform 全部初始化，
	sm.set_shader_parameter("water_waves_enabled", water_waves_enabled)
	sm.set_shader_parameter("water_fresnel_enabled", water_fresnel_enabled)
	sm.set_shader_parameter("river_flow_enabled", river_flow_enabled)
	sm.set_shader_parameter("caustics_enabled", caustics_enabled)
	sm.set_shader_parameter("shallow_transparency_enabled", shallow_transparency_enabled)
	sm.set_shader_parameter("water_gloss", water_gloss)
	sm.set_shader_parameter("water_reflection_strength", water_reflection_strength)
	sm.set_shader_parameter("river_flow_speed", river_flow_speed)
	sm.set_shader_parameter("river_flow_freq", river_flow_freq)
	sm.set_shader_parameter("caustics_strength", caustics_strength)
	sm.set_shader_parameter("deep_ocean_contrast", deep_ocean_contrast)
	sm.set_shader_parameter("lake_water_color", lake_water_color)
	sm.set_shader_parameter("shallow_transparency_factor", shallow_transparency_factor)
	sm.set_shader_parameter("water_domain_warp_strength", water_domain_warp_strength)
	sm.set_shader_parameter("water_wave_line_strength", water_wave_line_strength)
	sm.set_shader_parameter("water_calm_noise_brightness", water_calm_noise_brightness)
	sm.set_shader_parameter("water_calm_noise_tint_strength", water_calm_noise_tint_strength)
	sm.set_shader_parameter("water_biome_blend_radius", water_biome_blend_radius)
	sm.set_shader_parameter("water_cartoon_color_strength", water_cartoon_color_strength)
	sm.set_shader_parameter("water_transition_softness", water_transition_softness)
	sm.set_shader_parameter("estuary_plume_strength", estuary_plume_strength)

	# 挂上 enum_atlas 当海陆判断、noise_tex 给 weather overlay shader 复用
	if _weather_layer != null:
		_weather_layer.setup(bounds, _world.enum_atlas_tex, _world.noise_tex)
		_weather_layer.set_weather_strength(weather_strength)
	set_weather_fronts([])

	# Hypsometric 色阶
	sm.set_shader_parameter("color_deep_ocean", color_deep_ocean)
	sm.set_shader_parameter("color_mid_ocean", color_mid_ocean)
	sm.set_shader_parameter("color_shallow", color_shallow)
	sm.set_shader_parameter("color_coast_water", color_coast_water)
	sm.set_shader_parameter("color_beach", color_beach)
	sm.set_shader_parameter("color_lowland", color_lowland)
	sm.set_shader_parameter("color_hill", color_hill)
	sm.set_shader_parameter("color_mountain", color_mountain)
	sm.set_shader_parameter("color_peak", color_peak)
	sm.set_shader_parameter("color_snow", color_snow)

	# Hillshading
	sm.set_shader_parameter("hillshade_strength", hillshade_strength)
	sm.set_shader_parameter("hillshade_slope_gain", hillshade_slope_gain)

	# Rivers
	sm.set_shader_parameter("river_strength", river_strength)
	sm.set_shader_parameter("river_threshold_low", river_threshold_low)
	sm.set_shader_parameter("river_threshold_high", river_threshold_high)
	sm.set_shader_parameter("river_color", river_color)
	sm.set_shader_parameter("river_outline_color", river_outline_color)

	# Contour
	sm.set_shader_parameter("contour_enabled", contour_enabled)
	sm.set_shader_parameter("contour_step", contour_step)
	sm.set_shader_parameter("contour_strength", contour_strength)
	sm.set_shader_parameter("contour_color", contour_color)

	# Coast halo
	sm.set_shader_parameter("coast_halo_color", coast_halo_color)
	sm.set_shader_parameter("coast_halo_strength", coast_halo_strength)

	# Atlas
	sm.set_shader_parameter("parchment_tint", parchment_tint)
	sm.set_shader_parameter("parchment_strength", parchment_strength)
	sm.set_shader_parameter("paper_grain_strength", paper_grain_strength)

# ─── Fast-tick perf opt (E)：细粒度纹理重绑接口 ──────────────────────────
# 背景：原 `set_map` 路径会触发 `_rebuild` → `_build_world_quad_mesh` + `_apply_uniforms`，
#       后者一次性向 shader 写入 60+ uniform（含 geometry / hypsometric / water / TOD…），
#       在加速档 x20 下季节切换每 ~1.5s 触发一次，是肉眼可见的卡顿源头。
# 优化：season 切换时 `_baker.rebake_*_tex_only` 已经把新像素写进了共享 ImageTexture，
#       atlas 句柄并未变化（仍是 `_world.enum_atlas_tex`）。Godot 的 ImageTexture 内部
#       update 机制保证 GPU 端看到新内容，**理论上 shader 端无需任何额外动作**。
#       但为了对 set_shader_parameter 有缓存优化的 Godot 版本保险起见，这里仍重新
#       set 一次 atlas uniform（成本极低，仅 1~3 次 set_shader_parameter），避免脏帧。
# 三个 *_tex_only 方法语义：
#   - set_biome_tex_only      → 重绑 enum_atlas（biome / landform / vegetation / cover
#                                /weather 全部打包在 enum_atlas 的 4 通道里，是 biome
#                                决策影响最直接的 atlas）
#   - set_cover_tex_only      → 同样重绑 enum_atlas（cover 通道与 biome 通道共用 atlas）
#   - set_vegetation_tex_only → 同样重绑 enum_atlas（vegetation 通道与 biome 通道共用）
# 调用方（main.gd._on_season_changed）只需选择最贴合语义的一个调用即可，重复调用
# 是幂等的（同一 ImageTexture 重新 bind 不增加 GPU 成本）。
#
# 显式不做的事（与 `set_map` / `_apply_uniforms` 的关键差异）：
#   - 不重建 _world_quad.mesh（geometry 不变，避免一次几何上传）
#   - 不重新计算 world_bounds / world_origin / world_size / sea_level / hm_resolution
#   - 不重发 hypsometric 调色板、water 视觉、TOD 参数等静态 uniform
#   - 不重置 _weather_layer.setup（weather layer 自有节奏）
#   - 不重置 season_transition uniform（季节过渡材质独立路径）
func set_biome_tex_only(world: WorldData) -> void:
	if _shader_mat == null or world == null or world.enum_atlas_tex == null:
		return
	_shader_mat.set_shader_parameter("enum_atlas", world.enum_atlas_tex)
	# season 过渡材质若激活，也同步重绑（确保过渡覆盖层的 enum_atlas 不滞后）
	if _season_transition_mat != null:
		_season_transition_mat.set_shader_parameter("enum_atlas", world.enum_atlas_tex)

func set_cover_tex_only(world: WorldData) -> void:
	# Project.Keynes 把 biome / cover / vegetation / weather 共用一张 enum_atlas，
	# 因此 cover 重绑等价于 biome 重绑；保留独立方法名仅为契合方案 E 的 API 命名约定。
	set_biome_tex_only(world)

func set_vegetation_tex_only(world: WorldData) -> void:
	# 同上：vegetation 通道与 biome 共用 enum_atlas。
	set_biome_tex_only(world)
