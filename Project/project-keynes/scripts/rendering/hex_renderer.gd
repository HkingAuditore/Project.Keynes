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
@export var world_material: ShaderMaterial = preload("res://materials/world_map_material.tres"):
	set(value):
		world_material = value
		if is_inside_tree():
			_load_shader()
			if _map != null and _world != null:
				_rebuild()

@export_group("Shader Hot Reload")
@export var shader_hot_reload_enabled: bool = true
@export_range(0.1, 5.0, 0.1) var shader_hot_reload_interval: float = 0.35

# ─── Hypsometric 色阶（海陆双向，从深到浅） ──────────────────────────────
# Open Ocean Color Rebalance v2：与 world_map.gdshader 同步，把深/浅海亮度差
# 从 Δ=0.36 收敛到 Δ=0.22，避免"浅海发亮、深海近黑"的强烈对比。
# 旧 (v1) / 新 (v2)：
#   (0.10,0.18,0.30) → (0.14,0.22,0.34)   (0.16,0.28,0.40) → (0.20,0.30,0.42)
#   (0.27,0.45,0.56) → (0.28,0.42,0.52)   (0.40,0.62,0.66) → (0.34,0.50,0.56)
# [需求3 2026-06-19午] 缩小浅↔深海色差：原 coast(0.34,0.50,0.56)→deep(0.14,0.22,0.34) 亮度/色相跨度
# 过大，海岸青绿环与深海深蓝对比太硬。提亮深/中海、略压浅/岸海，让整片海面更协调连续。
@export_group("Hypsometric Colors")
@export var color_deep_ocean: Color = Color(0.18, 0.27, 0.40)
@export var color_mid_ocean: Color = Color(0.23, 0.34, 0.46)
@export var color_shallow: Color = Color(0.26, 0.39, 0.49)
@export var color_coast_water: Color = Color(0.31, 0.45, 0.53)
# [需求2/4 2026-06-19] 色阶去黄 + 拉开山段层次：原 lowland/hill/mountain 全是黄棕系且 hill→mountain
# 渐变过小，导致(2)地表整体偏黄、(4)山体一片同色像"平坦高原"。新方案：lowland 偏绿减黄；hill 收黄；
# mountain 压暗成深岩棕；peak 提亮成裸岩灰白 → 明度 中→暗→亮、色相 绿黄→棕→灰，配合 hillshade 让山腰
# 阴暗、山脊提亮，形成可读的高度层次。
@export var color_beach: Color = Color(0.85, 0.78, 0.55)
@export var color_lowland: Color = Color(0.54, 0.64, 0.40)
@export var color_hill: Color = Color(0.60, 0.56, 0.36)
@export var color_mountain: Color = Color(0.44, 0.39, 0.36)
@export var color_peak: Color = Color(0.80, 0.79, 0.78)
@export var color_snow: Color = Color(0.96, 0.96, 0.96)

# ─── 双光源 hillshading ──────────────────────────────────────────────────
# [macro-relief 2026-06-19] strength 0.45→0.62、slope_gain 8→11：宏观山脉/盆地/丘陵群
# 此前因 hillshade 偏弱 + 宽 hypsometric 色带而难以辨认。加强双光源明暗与坡度增益，让大尺度
# 起伏（山系阴影面、盆地洼地、河谷下切）在 2.5D 着色下更立体可读。属纯视觉 knob，可再微调。
# [需求4 2026-06-19] strength 0.62→0.74、slope_gain 11→13：山体仍显平。配合新山段色阶进一步加强
# 明暗，让山腰/山脊起伏更立体，弱化"平坦高原"观感。
@export_group("Hillshading")
@export_range(0.0, 1.0, 0.01) var hillshade_strength: float = 0.74
@export_range(0.5, 24.0, 0.5) var hillshade_slope_gain: float = 13.0

# ─── 河流 ────────────────────────────────────────────────────────────────
# v6：flow_tex 是 SDF 反距离编码（1=河中心，0=>=SDF_MAX_DIST_PX 远）。
# baker 的 SDF_MAX_DIST_PX = 5 像素，保持大尺度地图上河流为细线。
# threshold_low=外圈 outline 起点，threshold_high=内圈主色完全。
@export_group("Rivers")
@export_range(0.0, 1.0, 0.01) var river_strength: float = 0.85
@export_range(0.0, 1.0, 0.01) var river_threshold_low: float = 0.62
@export_range(0.0, 1.0, 0.01) var river_threshold_high: float = 0.90
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
# 2026-05-19 Plan-C：season_temp_amp 默认 0.20 → 0.32，与 climate_profile.gd
# 和 uniforms.gdshaderinc 同步。这是真正推送到 shader 的数据源（行 989）。
@export_group("Climate")
@export_range(0.0, 0.4, 0.01) var season_temp_amp: float = 0.32
@export_range(0.0, 1.0, 0.01) var vegetation_season_strength: float = 0.85
@export_range(0.0, 1.0, 0.01) var dynamic_snow_strength: float = 0.85
@export_range(0.0, 1.0, 0.01) var ocean_current_strength: float = 0.88
@export_range(0.0, 1.0, 0.01) var season_transition_phase_span: float = 0.33
@export_range(0.02, 0.45, 0.01) var season_transition_softness: float = 0.18
# 2026-05-19：dynamic_cell / dyn_atlas_smooth / ecology / ice 四张 atlas 的上传节流。
# 1=每仿真日上传一次；2（默认）=每 2 仿真日；4=每 4 仿真日。值越大越省 CPU 但雪线/海冰
# 视觉变化越"卡顿"。运行时改这个值会触发 DynamicVisualAtlasUploadSystem.reconfigure。
@export_range(1, 8, 1) var dyn_atlas_upload_stride: int = 2
# 调试用：true 时雪盖跳过 fbm cosmetic 抖动，直接拿 dyn_snow（CPU snow_cover）上屏。
# 用于验证"info_panel 显示的 snow_cover 是否真的体现在屏幕像素上"。
@export var debug_force_dyn_snow_only: bool = false

# True Insolation-Driven（Phase F）：CPU / GPU 同源的四个参数。
# true_insolation_enabled 保留给旧资源/旧 shader 兼容；运行时会强制保持 true。
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
@export_range(0.0, 1.0, 0.01) var ecology_visual_strength: float = 0.70
@export_range(0.0, 1.0, 0.01) var snowline_visual_strength: float = 0.85
@export_range(0.0, 1.0, 0.01) var foliage_density_strength: float = 0.75
@export_range(0, 2, 1) var ecology_visual_quality: int = 2

# ─── Milestone 3：天气 overlay 总强度（0 关闭，1 全力） ─────────────────
@export_group("Weather (Milestone 3)")
@export_range(0.0, 1.0, 0.01) var weather_strength: float = 1.0

# ─── Visual Overhaul（任务 1）：视觉总开关 ────────────────────────
# 这组变量由 main.gd 通过 set_*() 推进；shader 分支逐步在任务 3~9 中接入。
# 默认值与 main.gd 一致，保证 renderer 被单独调试时也有合理初值。
@export_group("Visual Overhaul")
@export_range(0, 2, 1) var visual_quality: int = 1
@export var day_night_enabled: bool = true
@export var water_effect_enabled: bool = true
@export var ocean_current_enabled: bool = true
@export var extreme_weather_ground_effect_enabled: bool = true
@export var perf_sampler_enabled: bool = false
@export var shrub_visual_profile: Resource = preload("res://data/visual/shrub_default.tres"):
	set(value):
		shrub_visual_profile = value
		_rebuild_detail_layers_if_default()
@export var tree_visual_profile: Resource = preload("res://data/visual/tree_default.tres"):
	set(value):
		tree_visual_profile = value
		_rebuild_detail_layers_if_default()
@export var grass_visual_profile: Resource = preload("res://data/visual/grass_default.tres"):
	set(value):
		grass_visual_profile = value
		_rebuild_detail_layers_if_default()
# 数据驱动点缀清单。留空时回退到上面 grass/shrub/tree 三个 profile（行为 1:1）。
# 配置后，hex_renderer 在 _ready 按 manifest.layers 生成对应数量的散布层。
@export var decoration_manifest: Resource = null:
	set(value):
		decoration_manifest = value
		if is_inside_tree():
			_spawn_detail_layers()
			if _map != null and _world != null:
				_rebuild()

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
# Decoration / vegetation 散布层（数据驱动）：默认回退到 grass/shrub/tree 三个
# @export profile；配置 decoration_manifest 后按其 layers 数组生成 N 层。
var _detail_layers: Array = []
# C++ DCWorldExt 引用，转发给每个散布层做 native 生成。
var _world_ext = null
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
# 阶段 D（vegetation-visual-pcg）：植被 shader 的全局风场。方向由当前天气锋面
# 的主轴按强度加权聚合得到，附加风强取各锋面降水/强度的峰值；无锋面时退回
# 一个轻柔的常量盛行风。每帧在 _process 里推送给各 detail 层。
var _detail_wind_dir: Vector2 = Vector2(1.0, 0.18)
var _detail_wind_boost: float = 0.0
# 植被 TOD 光照缓存（apply_tod 写入），新生成的 detail 层在 spawn 时补推一次。
var _tod_valid: bool = false
var _tod_sun_color: Color = Color(1.0, 0.97, 0.92)
var _tod_ambient_color: Color = Color(0.70, 0.75, 0.82)
var _tod_night_factor: float = 0.0
var _tod_exposure: float = 1.0
var _shader_hot_reload_accum: float = 0.0
var _active_material_source_path: String = ""
var _active_shader_source_path: String = ""
var _material_source_mtime: int = 0
var _shader_source_mtime: int = 0
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
	_spawn_detail_layers()
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
	_poll_shader_hot_reload(delta)
	if _shader_mat == null:
		return
	_world_time += delta
	_shader_mat.set_shader_parameter("world_time", _world_time)
	var wind_boost := _detail_wind_boost * weather_strength
	_for_each_vegetation_layer(func(layer: ShrubLayer) -> void:
		layer.set_world_time(_world_time)
		layer.set_wind_field(_detail_wind_dir, wind_boost)
	)
	if _season_transition_mat != null:
		_season_transition_mat.set_shader_parameter("world_time", _world_time)
		_update_season_transition()
	# 任务 1：性能采样（仅当 perf_sampler_enabled 为 true 时启用）
	if _perf_sampler != null:
		_perf_sampler.push_frame_ms(delta * 1000.0)

func _load_shader() -> void:
	var next_mat: ShaderMaterial = null
	_active_material_source_path = ""
	_active_shader_source_path = ""

	if world_material != null:
		var source_mat := world_material
		_active_material_source_path = source_mat.resource_path
		if source_mat.resource_path != "":
			var disk_mat := ResourceLoader.load(
				source_mat.resource_path,
				"ShaderMaterial",
				ResourceLoader.CACHE_MODE_IGNORE
			) as ShaderMaterial
			if disk_mat != null:
				source_mat = disk_mat
				_active_material_source_path = disk_mat.resource_path
		next_mat = source_mat.duplicate() as ShaderMaterial
		if next_mat != null:
			var shader := _load_fresh_shader_for_material(next_mat)
			if shader != null:
				next_mat.shader = shader
			if next_mat.shader != null:
				_shader_mat = next_mat
				_world_quad.material = _shader_mat
				_refresh_shader_hot_reload_baseline()
				return
		push_warning("HexRenderer: world_material has no shader; falling back to %s" % shader_path)

	var fallback_shader := ResourceLoader.load(shader_path, "Shader", ResourceLoader.CACHE_MODE_IGNORE) as Shader
	if fallback_shader == null:
		push_warning("HexRenderer: shader not found at %s" % shader_path)
		_world_quad.material = null
		return
	_shader_mat = ShaderMaterial.new()
	_shader_mat.shader = fallback_shader
	_world_quad.material = _shader_mat
	_active_shader_source_path = shader_path
	_refresh_shader_hot_reload_baseline()

func _load_fresh_shader_for_material(mat: ShaderMaterial) -> Shader:
	var source_path := shader_path
	if mat.shader != null and mat.shader.resource_path != "":
		source_path = mat.shader.resource_path
	_active_shader_source_path = source_path
	if source_path == "":
		return mat.shader
	var shader := ResourceLoader.load(source_path, "Shader", ResourceLoader.CACHE_MODE_IGNORE) as Shader
	if shader == null:
		push_warning("HexRenderer: shader not found at %s" % source_path)
		return mat.shader
	# Mobile quality tier 编译时变体（2026-06-15）：移动端 prepend #define MOBILE_QUALITY_*
	# 让 GPU 编译三种独立 shader 二进制（GPU warp 不再为所有 if 分支保留 register）。
	# tier 由 main.gd::_mobile_shader_quality_tier_for_define() 推送（onready 时机）。
	if OS.has_feature("mobile") and _mobile_quality_tier_define != "":
		var src: String = shader.code
		# 检查是否已经 prepend 过（避免热重载重复加）
		if not src.begins_with("#define"):
			shader = shader.duplicate() as Shader
			shader.code = "#define %s\n%s" % [_mobile_quality_tier_define, src]
			print("[hex_renderer/quality] prepended #define %s to %s" % [
				_mobile_quality_tier_define, source_path
			])
	return shader


# Mobile shader quality tier（2026-06-15）：由 main.gd::_push_visual_toggles 推过来。
# 空字符串 = 桌面端 / 不 prepend define。可选值 "MOBILE_QUALITY_LOW" / "MID" / "HIGH"。
var _mobile_quality_tier_define: String = ""

func set_mobile_quality_tier(tier_define: String) -> void:
	var veg_tier := _mobile_quality_tier_from_define(tier_define)
	_for_each_vegetation_layer(func(layer: ShrubLayer) -> void:
		layer.set_mobile_quality_tier(veg_tier)
	)
	if _weather_layer != null and _weather_layer.has_method("set_mobile_quality_tier"):
		_weather_layer.set_mobile_quality_tier(tier_define)
	if _mobile_quality_tier_define == tier_define:
		return
	_mobile_quality_tier_define = tier_define
	# 重新加载 shader 让 #define 生效（hot toggle 时也走这条）
	if _shader_mat != null:
		_load_shader()
		# 关键：_load_shader 创建了新 ShaderMaterial 实例（disk source_mat.duplicate()），
		# 原本的 atlas uniform (height_tex/enum_atlas/dyn_atlas_smooth_atlas 等) 都是 null。
		# 必须重新 push 所有 uniform，否则 fragment 拿到 null texture → 输出全白 / 失败。
		# bug fix（log_next.txt 2026-06-15 14:13 shader.dyn_atlas_smooth=<null> 即症状）。
		if _map != null and _world != null and _shader_mat != null:
			_apply_uniforms()


func _mobile_quality_tier_from_define(tier_define: String) -> int:
	match tier_define:
		"MOBILE_QUALITY_LOW":
			return 0
		"MOBILE_QUALITY_HIGH":
			return 2
		_:
			return 1


func _for_each_vegetation_layer(callable: Callable) -> void:
	for layer in _detail_layers:
		if layer != null:
			callable.call(layer)


# 默认散布层 profile 列表：优先 decoration_manifest.layers；留空时回退 grass/shrub/tree。
func _detail_profiles() -> Array:
	var manifest := decoration_manifest
	if manifest != null and manifest.has_method("valid_layers"):
		var mls: Array = manifest.valid_layers()
		if not mls.is_empty():
			return mls
	var defaults: Array = []
	if grass_visual_profile != null:
		defaults.append(grass_visual_profile)
	if shrub_visual_profile != null:
		defaults.append(shrub_visual_profile)
	if tree_visual_profile != null:
		defaults.append(tree_visual_profile)
	return defaults


# 是否当前用的是默认三层（未配置 manifest）。
func _using_default_layers() -> bool:
	var manifest := decoration_manifest
	return not (manifest != null and manifest.has_method("valid_layers") and not manifest.valid_layers().is_empty())


# 销毁旧散布层并按当前 profile 列表重建。
func _spawn_detail_layers() -> void:
	for layer in _detail_layers:
		if is_instance_valid(layer):
			layer.queue_free()
	_detail_layers.clear()
	var profiles := _detail_profiles()
	var veg_tier := _mobile_quality_tier_from_define(_mobile_quality_tier_define)
	for i in range(profiles.size()):
		var prof: Resource = profiles[i]
		var layer := ShrubLayer.new()
		layer.name = _detail_layer_name(prof, i)
		layer.profile = prof
		layer.set_mobile_quality_tier(veg_tier)
		layer.set_world_ext(_world_ext)
		add_child(layer)
		# [cylindrical-earth-daylight] 新层补推昼夜光照所需状态（与地形同源）：
		# 相位/季节驱动晨昏线，axial_tilt 决定季节赤纬，day_night_enabled 为总开关。
		layer.set_season_phase(_season_phase)
		layer.set_day_phase(_day_phase)
		layer.set_axial_tilt_rad(deg_to_rad(axial_tilt_deg))
		layer.set_day_night_enabled(day_night_enabled)
		if _tod_valid:
			layer.set_tod(_tod_sun_color, _tod_ambient_color, _tod_night_factor, _tod_exposure)
		_detail_layers.append(layer)


func _detail_layer_name(prof: Resource, i: int) -> String:
	if prof != null and "detail_kind" in prof:
		match int(prof.detail_kind):
			0:
				return "ShrubLayer" if i == 0 else "ShrubLayer%d" % i
			1:
				return "TreeLayer" if i == 0 else "TreeLayer%d" % i
			2:
				return "GrassLayer" if i == 0 else "GrassLayer%d" % i
	return "DetailLayer%d" % i


# 仅在使用默认三层（无 manifest）时，profile @export 改动后刷新对应层 profile。
func _rebuild_detail_layers_if_default() -> void:
	if not is_inside_tree() or not _using_default_layers():
		return
	_spawn_detail_layers()
	if _map != null and _world != null:
		_rebuild()


# 注入 C++ DCWorldExt（main.gd 在 set_map 前调用），转发给每个散布层。
func set_world_ext(ext) -> void:
	_world_ext = ext
	for layer in _detail_layers:
		if layer != null and layer.has_method("set_world_ext"):
			layer.set_world_ext(ext)


func _poll_shader_hot_reload(delta: float) -> void:
	if not shader_hot_reload_enabled:
		return
	_shader_hot_reload_accum += delta
	if _shader_hot_reload_accum < maxf(shader_hot_reload_interval, 0.1):
		return
	_shader_hot_reload_accum = 0.0

	var shader_mtime := _file_modified_time(_active_shader_source_path)
	var material_mtime := _file_modified_time(_active_material_source_path)
	var shader_changed := shader_mtime > 0 and _shader_source_mtime > 0 and shader_mtime != _shader_source_mtime
	var material_changed := material_mtime > 0 and _material_source_mtime > 0 and material_mtime != _material_source_mtime
	if not shader_changed and not material_changed:
		if _shader_source_mtime == 0:
			_shader_source_mtime = shader_mtime
		if _material_source_mtime == 0:
			_material_source_mtime = material_mtime
		return

	_load_shader()
	_clear_season_transition()
	if _map != null and _world != null and _shader_mat != null:
		_apply_uniforms()
	print("[HexRenderer] hot-reloaded world shader/material")

func _refresh_shader_hot_reload_baseline() -> void:
	_shader_source_mtime = _file_modified_time(_active_shader_source_path)
	_material_source_mtime = _file_modified_time(_active_material_source_path)

func _file_modified_time(path: String) -> int:
	if path == "":
		return 0
	var fs_path := path
	if path.begins_with("res://") or path.begins_with("user://"):
		fs_path = ProjectSettings.globalize_path(path)
	return int(FileAccess.get_modified_time(fs_path))

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
	_season_transition_mat.set_shader_parameter("map_index_atlas", enum_snapshot)
	_season_transition_mat.set_shader_parameter("season_transition_overlay", true)
	_season_transition_mat.set_shader_parameter("season_transition_progress", 0.0)
	_season_transition_mat.set_shader_parameter("season_transition_softness", season_transition_softness)
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
	if _weather_layer != null:
		_weather_layer.set_season_phase(_season_phase)
	_for_each_vegetation_layer(func(layer: ShrubLayer) -> void:
		layer.set_season_phase(_season_phase)
	)

func set_climate_anomaly(v: float) -> void:
	_climate_anomaly = v
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("climate_anomaly", _climate_anomaly)
	if _season_transition_mat != null:
		_season_transition_mat.set_shader_parameter("climate_anomaly", _climate_anomaly)

# True Insolation-Driven（Phase F）：旧兼容 setter。运行时和 shader 统一保持
# insolation 分支，bool 只保留给旧材质参数兼容。
func set_true_insolation_enabled(v: bool) -> void:
	var _unused_v: bool = v
	true_insolation_enabled = true
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
	_for_each_vegetation_layer(func(layer: ShrubLayer) -> void:
		layer.set_day_phase(_day_phase)
	)

# ─── 任务 1：视觉总开关 setter ─────────────────────────────────────────
#   2) 把对应 uniform 推到 shader（名字与后续任务 shader 分支匹配）；
func set_visual_quality(q: int) -> void:
	visual_quality = clampi(q, 0, 2)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("visual_quality", visual_quality)
	if _weather_layer != null:
		_weather_layer.set_visual_quality(visual_quality)
	_for_each_vegetation_layer(func(layer: ShrubLayer) -> void:
		layer.set_visual_quality(visual_quality)
	)


# 60 FPS 调查（2026-06-14）：完全禁用主地形 shader。
# 把 _world_quad.material = null → fragment shader 不跑，只剩 GPU 清屏 + canvas
# composite。用 ΔFPS 反推 hex_terrain/world_map shader 占多少 GPU 时间。
# 实验结束后再 toggle 回来恢复 _shader_mat。
var _shader_disabled_by_toggle: bool = false

func toggle_world_shader_disabled() -> bool:
	if _world_quad == null:
		print("[hex_renderer] _world_quad null, cannot toggle shader")
		return false
	_shader_disabled_by_toggle = not _shader_disabled_by_toggle
	if _shader_disabled_by_toggle:
		_world_quad.material = null
	else:
		_world_quad.material = _shader_mat
	print("[hex_renderer] world shader disabled=%s — material=%s" % [
		str(_shader_disabled_by_toggle),
		str(_world_quad.material)
	])
	return _shader_disabled_by_toggle


func is_world_shader_disabled() -> bool:
	return _shader_disabled_by_toggle

func set_ecology_visual_quality(q: int) -> void:
	ecology_visual_quality = clampi(q, 0, 2)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("ecology_visual_quality", ecology_visual_quality)

func set_ecology_visual_strength(v: float) -> void:
	ecology_visual_strength = clampf(v, 0.0, 1.0)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("ecology_visual_strength", ecology_visual_strength)

func set_snowline_visual_strength(v: float) -> void:
	snowline_visual_strength = clampf(v, 0.0, 1.0)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("snowline_visual_strength", snowline_visual_strength)

# 调试入口：toggle 雪盖"纯 dyn_snow（无 fbm 抖动）"渲染模式。
# 屏幕上的雪量将严格 = info_panel 显示的 cell.snow_cover（±量化误差），用于
# 验证 CPU→atlas→shader 链路。
func set_debug_force_dyn_snow_only(v: bool) -> void:
	debug_force_dyn_snow_only = v
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("debug_force_dyn_snow_only", debug_force_dyn_snow_only)

# 运行时调整 dynamic_cell / dyn_atlas_smooth / ecology / ice atlas 的上传 stride。
# 1=每仿真日 2=每 2 仿真日 4=每 4 仿真日。值越大越省 CPU 但视觉变化越"卡"。
# 透传到 DynamicVisualAtlasUploadSystem.reconfigure；map_generator 持有 system 引用。
func set_dyn_atlas_upload_stride(v: int) -> void:
	dyn_atlas_upload_stride = clampi(v, 1, 8)
	# 找到 MapGenerator 来 reconfigure 已注册的 system 实例。
	var mg = get_tree().root.find_child("MapGenerator", true, false)
	if mg != null and mg.has_method("set_dyn_atlas_upload_stride"):
		mg.set_dyn_atlas_upload_stride(dyn_atlas_upload_stride)

func set_foliage_density_strength(v: float) -> void:
	foliage_density_strength = clampf(v, 0.0, 1.0)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("foliage_density_strength", foliage_density_strength)

func set_day_night_enabled(v: bool) -> void:
	day_night_enabled = v
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("day_night_enabled", day_night_enabled)
	if _weather_layer != null:
		_weather_layer.set_day_night_enabled(day_night_enabled)
	# [cylindrical-earth-daylight] 植被/点缀层昼夜总开关随地形同步（关闭=永昼）。
	_for_each_vegetation_layer(func(layer: ShrubLayer) -> void:
		layer.set_day_night_enabled(day_night_enabled)
	)

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
# 方案 0：upwelling_tex 仅本开关 true 时使用——首次开启时通过 MapBaker.rebake_upwelling_tex_for_debug
# lazy 烘焙一张并 set_shader_parameter；关闭时不做反向清理（保留贴图，避免来回切动反复 bake）。
var _ocean_current_debug: bool = false
# 外部注入：debug 开启时用来 lazy bake upwelling_tex。null 时跳过 bake，shader 也不会读到
# 这张贴图（保持 uniform 默认黑纹理，调试覆盖层全屏中性，与未启用 debug 视觉一致但无方向提示）。
var _map_baker = null

func set_map_baker(b) -> void:
	_map_baker = b

func set_ocean_current_debug(v: bool) -> void:
	_ocean_current_debug = v
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("ocean_current_debug", _ocean_current_debug)
	# 方案 0：仅当切到 true 且贴图缺失时才 lazy bake upwelling_tex。
	if _ocean_current_debug and _world != null and _world.upwelling_tex == null \
			and _map_baker != null and _map_baker.has_method("rebake_upwelling_tex_for_debug"):
		var t0 := Time.get_ticks_msec()
		if _map_baker.rebake_upwelling_tex_for_debug(_world):
			print("[VisualOverhaul] ocean_current_debug → lazy baked upwelling_tex in %dms"
					% (Time.get_ticks_msec() - t0))
		if _shader_mat != null:
			_shader_mat.set_shader_parameter("ocean_upwelling_tex", _world.upwelling_tex)

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
	# 植被/点缀层随昼夜统一着色（修复"树草常亮"）。缓存供新生成层补推。
	_tod_sun_color = profile.sun_color
	_tod_ambient_color = profile.ambient_color
	_tod_night_factor = profile.night_factor
	_tod_exposure = profile.exposure
	_tod_valid = true
	_for_each_vegetation_layer(func(layer: ShrubLayer) -> void:
		layer.set_tod(_tod_sun_color, _tod_ambient_color, _tod_night_factor, _tod_exposure)
	)

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
# Diag log（2026-05-10 引入用于诊断 weather_layer logs 缺失）：本次收尾把
# "每帧必报"收紧为"前 3 次 + 数量变化时报"，避免 release log 刷屏；要恢复
# 详细日志只需把 _set_weather_fronts_log_budget 改大 / 把 last_n 重置为 -1。
var _set_weather_fronts_log_count: int = 0
var _set_weather_fronts_last_n: int = -1
const _set_weather_fronts_log_budget: int = 3
var _weather_fronts_signature: String = ""
var _weather_fronts_diag: Dictionary = {
	"published": 0,
	"skipped": 0,
	"fallback_full_sync": 0,
	"changed_slots_count": 0,
}

func sync_weather_fronts_signature(fronts: Array, diff: Dictionary) -> Dictionary:
	var next_sig: String = str(diff.get("signature", ""))
	var changed: bool = bool(diff.get("changed", false))
	if changed:
		set_weather_fronts(fronts)
		_weather_fronts_signature = next_sig
		_weather_fronts_diag["published"] = int(_weather_fronts_diag.get("published", 0)) + 1
	elif next_sig != "" and next_sig != _weather_fronts_signature:
		set_weather_fronts(fronts)
		_weather_fronts_signature = next_sig
		_weather_fronts_diag["fallback_full_sync"] = int(_weather_fronts_diag.get("fallback_full_sync", 0)) + 1
	else:
		_weather_fronts_diag["skipped"] = int(_weather_fronts_diag.get("skipped", 0)) + 1
	_weather_fronts_diag["changed_slots_count"] = int(diff.get("changed_slots_count", 0))
	_weather_fronts_diag["added_slots"] = int(diff.get("added_slots", 0))
	_weather_fronts_diag["removed_slots"] = int(diff.get("removed_slots", 0))
	_weather_fronts_diag["unchanged_slots"] = int(diff.get("unchanged_slots", 0))
	return _weather_fronts_diag.duplicate(true)

func weather_fronts_diag() -> Dictionary:
	return _weather_fronts_diag.duplicate(true)

func set_weather_fronts(fronts: Array) -> void:
	# Fix #7A (2026-06-15): mobile 限 fronts 上限 4（桌面继续 16）。
	# log_next.txt 实测 fronts=12 时 draw_calls 32→41 / primitives 1644→5418，
	# 主要来自 12 个 GPUParticles2D 实例（每个 ~300 粒子）+ overlay shader
	# 内 16-loop 内部计算。截断到 4 减少：
	#   - GPUParticles primitives: ~3600→1200 (-2400)
	#   - 内部 16-loop 早 break（weather_front_count uniform 写 4）
	# 选 4 而非 0 保留视觉效果："最近 4 个 front 仍可见，远处天气只在 cell 数据上推进"。
	if OS.has_feature("mobile") and fronts.size() > 4:
		fronts = fronts.slice(0, 4)
	var n_now: int = fronts.size()
	var should_log: bool = false
	if _set_weather_fronts_log_count < _set_weather_fronts_log_budget:
		should_log = true
	elif n_now != _set_weather_fronts_last_n:
		should_log = true
	if should_log:
		_set_weather_fronts_log_count += 1
		_set_weather_fronts_last_n = n_now
		print("[hex-renderer] set_weather_fronts(n=%d) layer=%s" % [
			n_now,
			"WeatherLayer" if _weather_layer != null else "<null,fallback>",
		])
	if _weather_layer != null:
		_weather_layer.set_weather_fronts(fronts)
	else:
		_push_weather_fronts_to_shader(fronts)

func set_weather_field_texture(tex: Texture2D) -> void:
	if _weather_layer != null and _weather_layer.has_method("set_weather_field_texture"):
		_weather_layer.set_weather_field_texture(tex)
	# map-visual-overhaul-v1：主地图 shader 已不再消费 weather_field_tex，
	# 海面天气视觉迁移到 weather_overlay 三层独立云。这里只转发给 weather_layer。

# map-visual-overhaul-v1：主地形材质的 weather_field_tex 通道已删除；
# 此函数保留为空 stub，让外部脚本（main.gd 等）历史调用点在过渡期不崩溃。
func refresh_terrain_weather_field_tex() -> void:
	pass

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
	_update_detail_wind_field(fronts, n)

# 阶段 D：由天气锋面聚合出植被风场。方向 = Σ(主轴·强度) 归一化；附加风强 =
# 各锋面 max(强度, 降水)·强度 的峰值。无锋面（n==0）时退回轻柔常量盛行风。
func _update_detail_wind_field(fronts: Array, n: int) -> void:
	if n <= 0:
		_detail_wind_dir = Vector2(1.0, 0.18)
		_detail_wind_boost = 0.0
		return
	var dir := Vector2.ZERO
	var boost := 0.0
	for i in range(n):
		var f = fronts[i]
		var intensity := _front_intensity(f)
		if intensity <= 0.001:
			continue
		var ax := _front_axis(f)
		if ax.length() <= 0.0001:
			continue
		# 主轴是无向的，统一指向 +x 半平面再按强度加权，避免反向相消。
		if ax.x < 0.0:
			ax = -ax
		dir += ax.normalized() * intensity
		boost = maxf(boost, maxf(intensity, _front_precip_amount(f)) * intensity)
	_detail_wind_dir = dir.normalized() if dir.length() > 0.0001 else Vector2(1.0, 0.18)
	_detail_wind_boost = clampf(boost, 0.0, 1.0)

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
		_for_each_vegetation_layer(func(layer: ShrubLayer) -> void:
			layer.clear()
		)
		return

	_world_quad.mesh = _build_world_quad_mesh(_world.world_bounds)
	# 防御性：若 set_world_ext 尚未注入，尝试从已注入的 MapBaker 取 C++ ext。
	if _world_ext == null and _map_baker != null and "_world_ext" in _map_baker:
		set_world_ext(_map_baker._world_ext)
	_for_each_vegetation_layer(func(layer: ShrubLayer) -> void:
		layer.set_world_ext(_world_ext)
		layer.setup(_map, _world, _world.world_bounds, hex_size, visual_quality)
	)
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

	# 主地图只保留 height/enum + cell-index LUT + 共享 noise_tex。
	sm.set_shader_parameter("height_tex",   _world.height_tex)
	sm.set_shader_parameter("map_index_atlas", _world.enum_atlas_tex)
	# [river-render-restore 2026-06-19] 河流 SDF 纹理重新接回主地图 shader（flow 视觉层）。
	sm.set_shader_parameter("flow_tex",     _world.flow_tex)
	# map-visual-overhaul-v1：weather_field_tex 已不再绑给主材质——海面天气视觉
	# 全部迁移到 weather_overlay 三层独立云（cirrus/cumulus/fog）。
	if _weather_layer != null:
		_weather_layer.set_vector_atlas_texture(null)
	# Systemic Ocean Currents：仅 F6 高对比调试层采样；主路径不依赖它。
	# 方案 0：默认不再每次新材质都绑 upwelling_tex（commit 路径已不烘焙它，绑过来就是 null）。
	# 当 _ocean_current_debug=true 时 set_ocean_current_debug 已 lazy bake 并 set 一次；
	# 这里仅在 _world.upwelling_tex 已存在时同步绑定，避免新材质丢失已 bake 的纹理。
	if _world.upwelling_tex != null:
		sm.set_shader_parameter("ocean_upwelling_tex", _world.upwelling_tex)
	# v10.noise-pack：把共享 RGBA 噪声包喂给地形 shader，fbm(p,N) 全局单次采样。
	sm.set_shader_parameter("noise_tex",    _world.noise_tex)

	# Cell-index 间接寻址是唯一动态视觉路径。
	var _indirect_ready: bool = _world.enum_atlas_tex != null and _world.enum_lut_tex != null
	sm.set_shader_parameter("enum_lut", _world.enum_lut_tex)
	sm.set_shader_parameter("dyn_lut", _world.dyn_lut_tex)
	sm.set_shader_parameter("eco_lut", _world.eco_lut_tex)
	sm.set_shader_parameter("lut_dims", Vector2(_world.lut_dims.x, _world.lut_dims.y))
	_for_each_vegetation_layer(func(layer: ShrubLayer) -> void:
		layer.set_world_material_inputs(_world, bounds, _indirect_ready)
	)

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
	# map-visual-overhaul-v1：把 24 种植被的四季 LUT + climate_anomaly 偏移色 push 到 shader。
	# 一次 setup 推送即可，运行时不刷新（除非热重载植被资源时显式 invalidate）。
	_push_vegetation_season_lut()
	sm.set_shader_parameter("dynamic_snow_strength", dynamic_snow_strength)
	sm.set_shader_parameter("debug_force_dyn_snow_only", debug_force_dyn_snow_only)
	sm.set_shader_parameter("ocean_current_strength", ocean_current_strength)
	sm.set_shader_parameter("vegetation_axis_strength", vegetation_axis_strength)
	sm.set_shader_parameter("cover_axis_strength", cover_axis_strength)
	sm.set_shader_parameter("ecology_visual_strength", ecology_visual_strength)
	sm.set_shader_parameter("snowline_visual_strength", snowline_visual_strength)
	sm.set_shader_parameter("foliage_density_strength", foliage_density_strength)
	sm.set_shader_parameter("ecology_visual_quality", ecology_visual_quality)
	# Seasonal transition is only enabled on the temporary old-terrain overlay.
	sm.set_shader_parameter("season_transition_overlay", false)
	sm.set_shader_parameter("season_transition_progress", 1.0)
	sm.set_shader_parameter("season_transition_softness", season_transition_softness)

	# Milestone 3：默认填空 weather 数组；全局天气强度只由 WeatherLayer 消费。

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
		_weather_layer.setup(bounds, _world.enum_atlas_tex, _world.noise_tex, hex_size, _world.weather_lut_tex, _world.lut_dims)
		# [cylindrical-earth-daylight] 云光照真源相位：与 ShrubLayer spawn 同套，setup 后补推一次，
		# 之后由 set_day_phase / set_season_phase 增量刷新（晨昏线随时间扫过）。
		_weather_layer.set_season_phase(_season_phase)
		_weather_layer.set_day_phase(_day_phase)
		_weather_layer.set_axial_tilt_rad(deg_to_rad(axial_tilt_deg))
		_weather_layer.set_weather_field_texture(null)
		_weather_layer.set_vector_atlas_texture(null)
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

# ─── map-visual-overhaul-v1：植被四季 LUT 推送 ──────────────────────────
# 把 VegetationProfileRegistry 加载的 24 个 VegetationProfile 的
#   season_color_lut[4]（春/夏/秋/冬叠乘色）
#   anomaly_color_shift  （climate_anomaly 升高时的叠加色）
# 一次性 push 到 shader 端的两个 uniform 数组：
#   vegetation_season_lut[VEG_COUNT*4] : 按 [veg*4 + season] 索引（VEG_COUNT=28）
#   vegetation_anomaly_shift[VEG_COUNT] : 按 [veg] 索引（VEG_COUNT=28）
# 仅在 setup / _apply_uniforms 调用一次（植被资源不会运行时变化）。
func _push_vegetation_season_lut() -> void:
	if _shader_mat == null:
		return
	const VEG_COUNT := 28
	var lut := PackedVector4Array()
	lut.resize(VEG_COUNT * 4)
	var shifts := PackedVector4Array()
	shifts.resize(VEG_COUNT)
	for veg in range(VEG_COUNT):
		var profile: VegetationProfile = VegetationProfileRegistry.get_profile(veg)
		if profile == null:
			# 未知 veg → 写中性白 / 零偏移，避免 shader 拿到未初始化数据。
			for s in range(4):
				lut[veg * 4 + s] = Vector4(1.0, 1.0, 1.0, 1.0)
			shifts[veg] = Vector4(0.0, 0.0, 0.0, 0.0)
			continue
		var profile_lut := profile.season_color_lut
		for s in range(4):
			if profile_lut != null and s < profile_lut.size():
				var c: Color = profile_lut[s]
				lut[veg * 4 + s] = Vector4(c.r, c.g, c.b, c.a)
			else:
				lut[veg * 4 + s] = Vector4(1.0, 1.0, 1.0, 1.0)
		var shift: Color = profile.anomaly_color_shift
		shifts[veg] = Vector4(shift.r, shift.g, shift.b, shift.a)
	_shader_mat.set_shader_parameter("vegetation_season_lut", lut)
	_shader_mat.set_shader_parameter("vegetation_anomaly_shift", shifts)
	if _season_transition_mat != null:
		_season_transition_mat.set_shader_parameter("vegetation_season_lut", lut)
		_season_transition_mat.set_shader_parameter("vegetation_anomaly_shift", shifts)

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
	_shader_mat.set_shader_parameter("map_index_atlas", world.enum_atlas_tex)
	# season 过渡材质若激活，也同步重绑（确保过渡覆盖层的 enum_atlas 不滞后）
	if _season_transition_mat != null:
		_season_transition_mat.set_shader_parameter("map_index_atlas", world.enum_atlas_tex)

func set_cover_tex_only(world: WorldData) -> void:
	# Project.Keynes 把 biome / cover / vegetation / weather 共用一张 enum_atlas，
	# 因此 cover 重绑等价于 biome 重绑；保留独立方法名仅为契合方案 E 的 API 命名约定。
	set_biome_tex_only(world)

func set_vegetation_tex_only(world: WorldData) -> void:
	# 同上：vegetation 通道与 biome 共用 enum_atlas。
	set_biome_tex_only(world)


# ─── [sea-ice-render-source-unify 阶段 A] 海冰单源诊断探针 ────────────────
# 用法（调试用，控制台/F8 调）：
#   HexRenderer.debug_sea_ice_probe(cell)  → 打印三元组：
#     (sea_ice_fraction_cpu, dyn_atlas_smooth.A 像素字节, biome id)
#
# 三者必须满足：
#   q01_byte_ice(sea_ice_fraction_cpu) == dyn_atlas_smooth_buffer[px_idx*4 + 3]
# 否则说明 GD↔C++ 编码漂移或 cache 滞后。
#
# biome id 仅作上下文参考——阶段 A 之后 shader 已不依赖 biome 决定海冰渲染。
func debug_sea_ice_probe(cell) -> Dictionary:
	var report := {
		"ok": false,
		"reason": "",
		"sea_ice_fraction_cpu": 0.0,
		"dyn_smooth_a_byte": -1,
		"dyn_smooth_a_norm": 0.0,
		"biome": -1,
		"px_idx": -1,
	}
	if cell == null:
		report.reason = "cell is null"
		print("[sea-ice/probe] %s" % report.reason)
		return report
	if _world == null or _map == null:
		report.reason = "world/map not bound"
		print("[sea-ice/probe] %s" % report.reason)
		return report
	report.sea_ice_fraction_cpu = float(cell.sea_ice_fraction)
	if "terrain" in cell:
		report.biome = int(cell.terrain)
	report.reason = "sea ice visual source moved to dyn_lut.a; per-pixel probe retired"
	report.ok = true
	print("[sea-ice/probe] cell=%s frac_cpu=%.4f biome=%d %s" % [
		str(cell), report.sea_ice_fraction_cpu, report.biome, report.reason])
	return report
	# 取该 cell 第一个 derived 像素的 dyn_atlas_smooth.A 字节
	var pixels: PackedInt32Array = PackedInt32Array()
	if not _world.cell_pixel_lists.is_empty() and _world.cell_pixel_lists.has(cell):
		pixels = _world.cell_pixel_lists[cell]
	if pixels.size() <= 0:
		report.reason = "cell has no pixels in cell_pixel_lists"
		print("[sea-ice/probe] cell=%s frac_cpu=%.4f biome=%d %s" % [
			str(cell), report.sea_ice_fraction_cpu, report.biome, report.reason])
		return report
	var px_idx: int = pixels[0]
	report.px_idx = px_idx
	var buf: PackedByteArray = _world.dyn_atlas_smooth_buffer
	# sea-ice-render-source-unify 阶段 C 探针扩展：
	# 同时读 dynamic_cell_atlas（未 smooth 的源 buffer）的 A 字节，便于区分
	# A_byte 错误是发生在 dynamic phase 还是 smooth phase。
	var raw_buf: PackedByteArray = _world.dynamic_cell_atlas_buffer
	var W: int = int(_world.derived_size.x)
	var H: int = int(_world.derived_size.y)
	var n_pix: int = W * H
	if buf.size() < n_pix * 4:
		report.reason = "dyn_atlas_smooth_buffer not ready (size=%d expected=%d)" % [buf.size(), n_pix * 4]
		print("[sea-ice/probe] %s" % report.reason)
		return report
	if px_idx < 0 or px_idx >= n_pix:
		report.reason = "px_idx out of range (%d not in [0,%d))" % [px_idx, n_pix]
		print("[sea-ice/probe] %s" % report.reason)
		return report
	var a_byte: int = int(buf[px_idx * 4 + 3])
	var raw_r: int = -1
	var raw_g: int = -1
	var raw_b: int = -1
	var raw_a_byte: int = -1
	if raw_buf.size() >= n_pix * 4:
		raw_r = int(raw_buf[px_idx * 4 + 0])
		raw_g = int(raw_buf[px_idx * 4 + 1])
		raw_b = int(raw_buf[px_idx * 4 + 2])
		raw_a_byte = int(raw_buf[px_idx * 4 + 3])
	report.dyn_smooth_a_byte = a_byte
	report.dyn_smooth_a_norm = float(a_byte) / 255.0
	report.ok = true
	# 同源校验：水格上 a_byte 应 == q01_byte_ice(sea_ice_fraction_cpu)。
	var expected_byte: int = 0
	var v: float = report.sea_ice_fraction_cpu
	if v > 0.0:
		expected_byte = clampi(maxi(1, int(ceil(clampf(v, 0.0, 1.0) * 255.0))), 1, 255)
	var passable_sea_str: String = "?"
	if "passable_sea" in cell:
		passable_sea_str = "true" if bool(cell.passable_sea) else "false"
	var passable_land_str: String = "?"
	if "passable_land" in cell:
		passable_land_str = "true" if bool(cell.passable_land) else "false"
	# 双源 SIF 对照：facade getter (cell.sea_ice_fraction) vs cpp read_f32 (cell_sea_ice_frac slot)
	# 理论上 facade 已直读 cpp slot，这里再调一次 read_f32 直读 cpp，能确认 cpp slot 在探针时刻的真值。
	var sif_via_facade: float = float(cell.sea_ice_fraction)
	var sif_via_ext: float = -1.0
	# 从 cell 里反射拿 _world_ext（HexCell facade 已存有该 ext 引用）
	var ext = null
	if "_world_ext" in cell:
		ext = cell.get("_world_ext")
	# 同时读 MapData.terrain_arr[idx]（cpp pipeline 用来查 is_water_lut 的源）
	# 与 cell.terrain（HexCell facade 实时值）对比，验证 SoA 是否陈旧。
	var terrain_via_facade: int = int(cell.terrain) if "terrain" in cell else -1
	var terrain_via_soa: int = -1
	# 探针使用 hex_renderer 已有的 _map 字段（不要走 world.map_data —— world_data.gd
	# 没有 map_data 字段，会返回 null）。
	var map_data_ref: MapData = _map
	if map_data_ref != null and "index" in cell:
		var tarr: PackedByteArray = map_data_ref.terrain_arr
		var tidx: int = int(cell.index)
		if tidx >= 0 and tidx < tarr.size():
			terrain_via_soa = int(tarr[tidx])
	var iw_via_lut: int = -1
	var iw_via_render_lut: int = -1
	if map_data_ref != null and terrain_via_soa >= 0:
		var iwlut: PackedByteArray = MapData.is_water_lut()
		if terrain_via_soa < iwlut.size():
			iw_via_lut = int(iwlut[terrain_via_soa])
		var iwlut_render: PackedByteArray = MapData.is_water_render_lut()
		if terrain_via_soa < iwlut_render.size():
			iw_via_render_lut = int(iwlut_render[terrain_via_soa])
	if ext != null and ext.has_method(&"read_f32"):
		# component_id 反查 cell_sea_ice_frac slot
		var sif_cid: int = -1
		if ext.has_method(&"component_id"):
			sif_cid = int(ext.call(&"component_id", &"cell_sea_ice_frac"))
		if sif_cid >= 0 and "index" in cell:
			sif_via_ext = float(ext.call(&"read_f32", sif_cid, int(cell.index)))
	# RGBA 全字节打印：raw_r/g/b 应是 q01(temp)/q01(moist)/q01(snow)
	# raw_a 应是 q01_byte_ice(sif) for water cells
	# 预期 R~q01(temp=0)=0, G~q01(moist≈适中)≈?, B~q01(snow=0)=0, A=q01_byte_ice(1.0)=255
	print("[sea-ice/probe] cell=%s idx=%s passable_sea=%s passable_land=%s biome=%d" % [
		str(cell), str(cell.index) if "index" in cell else "?",
		passable_sea_str, passable_land_str, report.biome])
	print("  SIF: facade=%.4f  cpp_slot=%.4f  → expected_a=%d" % [
		sif_via_facade, sif_via_ext, expected_byte])
	print("  terrain: facade=%d  soa(MapData.terrain_arr)=%d  → is_water_lut[soa]=%d render_lut[soa]=%d (1=water,0=land)" % [
		terrain_via_facade, terrain_via_soa, iw_via_lut, iw_via_render_lut])
	print("  raw_dyn RGBA = (%d, %d, %d, %d)  smooth.A = %d (norm=%.4f)  match=%s" % [
		raw_r, raw_g, raw_b, raw_a_byte, a_byte, report.dyn_smooth_a_norm,
		"YES" if a_byte == expected_byte else "MISMATCH"])
	# [TEMP DIAG sea-ice probe-cpp-known]
	# cpp [PHASE-D-SMO-OA] 已知写过 first_px=8584/4586/4843/5091/719/5245/274/961
	# 且 oa=255。这里直接读 buf 这些位置的 A 字节，验证 cpp 写入是否真的到达了
	# world.dyn_atlas_smooth_buffer 这个对象。
	var _check_pxs: Array = [8584, 4586, 4843, 5091, 719, 5245, 274, 961]
	var _check_str: String = "  cpp_written_check buf[smo].A @ "
	for _px in _check_pxs:
		var _i: int = int(_px)
		if _i >= 0 and _i < n_pix:
			_check_str += "%d=%d " % [_i, int(buf[_i * 4 + 3])]
	print(_check_str)
	# raw_dyn 同样位置 A 字节（cpp dyn 应该写 sig.A=255）
	if raw_buf.size() >= n_pix * 4:
		var _check_raw: String = "  cpp_written_check buf[dyn].A @ "
		for _px in _check_pxs:
			var _i: int = int(_px)
			if _i >= 0 and _i < n_pix:
				_check_raw += "%d=%d " % [_i, int(raw_buf[_i * 4 + 3])]
		print(_check_raw)
	return report
