# hex_renderer.gd v5
# 单一全屏 quad mesh + WorldData 的 4 张高分辨率纹理 + world_map.gdshader v5。
class_name HexRenderer
extends Node2D

const TERRAIN_MICRO_TEXTURE: Texture2D = preload("res://assets/textures/terrain_micro_data.png")
const VisualTileHorizonBakerScript = preload(
	"res://scripts/rendering/visual_tile_horizon_baker.gd")
const DetailScatterChangeSetScript = preload("res://scripts/data/detail_scatter_change_set.gd")
const VegetationFamilyLayerScript = preload("res://scripts/rendering/vegetation_family_layer.gd")

const DETAIL_PLAN_IDLE: int = 0
const DETAIL_PLAN_COLLECT: int = 1
const DETAIL_PLAN_BUILD_CHUNKS: int = 2
const DETAIL_PLAN_BEGIN_LAYERS: int = 3
const DETAIL_PLAN_BUILD_TASKS: int = 4
const DETAIL_PLAN_FALLBACK_COLLECT: int = 5
const DETAIL_PLAN_FALLBACK_TASKS: int = 6
const DETAIL_PLAN_FINALIZE: int = 7

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
@export var color_deep_ocean: Color = Color(0.22, 0.31, 0.43)
@export var color_mid_ocean: Color = Color(0.25, 0.35, 0.46)
@export var color_shallow: Color = Color(0.27, 0.40, 0.49)
@export var color_coast_water: Color = Color(0.30, 0.43, 0.51)
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
# [需求5 2026-06-25] strength 0.74→0.80、slope_gain 13→15：山地仍偏台地。配合更强的
# height bake / biome detail 之后，再把坡面对比抬一点，让山脊和山谷更容易读出来。
@export_group("Hillshading")
@export_range(0.0, 1.0, 0.01) var hillshade_strength: float = 0.80
@export_range(0.5, 24.0, 0.5) var hillshade_slope_gain: float = 15.0

# ─── 河流 ────────────────────────────────────────────────────────────────
# v6：flow_tex 是 SDF 反距离编码（1=河中心，0=>=SDF_MAX_DIST_PX 远）。
# baker 的 SDF_MAX_DIST_PX = 5 像素，保持大尺度地图上河流为细线。
# threshold_low=外圈 outline 起点，threshold_high=内圈主色完全。
@export_group("Rivers")
@export_range(0.0, 1.0, 0.01) var river_strength: float = 0.85
# [river-hierarchy 2026-07-31] 阈值收紧：配合更短的 SDF 晕圈，让可见河宽更多由
# stamp 半径（流量）决定，而不是被同一条 0.62→0.90 的淡出带抹平。
@export_range(0.0, 1.0, 0.01) var river_threshold_low: float = 0.70
@export_range(0.0, 1.0, 0.01) var river_threshold_high: float = 0.94
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
@export_range(0.0, 1.0, 0.01) var vegetation_season_strength: float = 1.0
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
@export_range(0.0, 1.0, 0.01) var vegetation_axis_strength: float = 0.40
@export_range(0.0, 1.0, 0.01) var cover_axis_strength: float = 0.65
@export_range(0.0, 1.0, 0.01) var ecology_visual_strength: float = 0.80
@export_range(0.0, 1.0, 0.01) var snowline_visual_strength: float = 0.85
@export_range(0.0, 1.0, 0.01) var foliage_density_strength: float = 0.75
@export_range(0.0, 1.5, 0.01) var temperature_visual_strength: float = 1.25
@export_range(0.0, 1.5, 0.01) var moisture_visual_strength: float = 1.18
@export_range(0.0, 1.5, 0.01) var vitality_visual_strength: float = 1.12
@export_range(0, 2, 1) var ecology_visual_quality: int = 2

# ─── Milestone 3：天气 overlay 总强度（0 关闭，1 全力） ─────────────────
@export_group("Weather (Milestone 3)")
@export_range(0.0, 1.0, 0.01) var weather_strength: float = 1.0

# [parallax-rain] 俯视雨幕参数：camera_pitch 控制雨滴侧投影长度收缩
@export_range(0.0, 90.0, 1.0, "degrees") var camera_pitch_deg: float = 75.0
@export var wind_dir: Vector2 = Vector2(0.3, 1.0)
@export_range(-1.0, 1.0, 0.05) var wind_strength: float = 0.15

var _camera_pitch: float = deg_to_rad(60.0)
var _wind_dir: Vector2 = Vector2(0.3, 1.0)
var _wind_strength: float = 0.15

# ─── Visual Overhaul（任务 1）：视觉总开关 ────────────────────────
# 这组变量由 main.gd 通过 set_*() 推进；shader 分支逐步在任务 3~9 中接入。
# 默认值与 main.gd 一致，保证 renderer 被单独调试时也有合理初值。
@export_group("Visual Overhaul")
@export_range(0, 2, 1) var visual_quality: int = 1
## A/B switch for the HIGH terrain material-array path. This is intentionally
## not exposed as a player-facing setting; false restores the legacy path.
var terrain_materials_enabled: bool = true
@export_range(0, 7, 1) var terrain_surface_debug_view: int = 0:
	set(value):
		terrain_surface_debug_view = clampi(value, 0, 7)
		if _shader_mat != null:
			_shader_mat.set_shader_parameter("terrain_surface_debug_view", terrain_surface_debug_view)

# [terrain-material-tiles 2026-08-01e] 材质族四参数提为 @export：编辑器检查器可见，
# 运行时经远程场景树拖动 setter 直推 _shader_mat 即时生效；_rebuild 全量推送也读这组值。
@export_range(0.0, 1.0, 0.01) var terrain_material_albedo_strength: float = 0.6:
	set(value):
		terrain_material_albedo_strength = clampf(value, 0.0, 1.0)
		if _shader_mat != null:
			_shader_mat.set_shader_parameter("terrain_material_albedo_strength", terrain_material_albedo_strength)

@export_range(0.0, 0.5, 0.005) var terrain_material_normal_strength: float = 0.15:
	set(value):
		terrain_material_normal_strength = clampf(value, 0.0, 0.5)
		if _shader_mat != null:
			_shader_mat.set_shader_parameter("terrain_material_normal_strength", terrain_material_normal_strength)

@export_range(0.0, 1.0, 0.01) var terrain_material_roughness_strength: float = 0.35:
	set(value):
		terrain_material_roughness_strength = clampf(value, 0.0, 1.0)
		if _shader_mat != null:
			_shader_mat.set_shader_parameter("terrain_material_roughness_strength", terrain_material_roughness_strength)

@export_range(64.0, 1024.0, 1.0) var terrain_material_world_size: float = 384.0:
	set(value):
		terrain_material_world_size = clampf(value, 64.0, 1024.0)
		if _shader_mat != null:
			_shader_mat.set_shader_parameter("terrain_material_world_size", terrain_material_world_size)
		_for_each_vegetation_layer(func(layer: ShrubLayer) -> void:
			layer.set_lod_debug_view(terrain_surface_debug_view == 6)
		)
@export_range(0.0, 0.96, 0.01) var terrain_ecotone_width: float = 0.84:
	set(value):
		terrain_ecotone_width = clampf(value, 0.0, 0.96)
		if _shader_mat != null:
			_shader_mat.set_shader_parameter("terrain_ecotone_width", terrain_ecotone_width)
		if _season_transition_mat != null:
			_season_transition_mat.set_shader_parameter("terrain_ecotone_width", terrain_ecotone_width)
		_push_overlay_edge_transition_data()
@export_range(0.0, 0.45, 0.01) var terrain_ecotone_noise: float = 0.22:
	set(value):
		terrain_ecotone_noise = clampf(value, 0.0, 0.45)
		if _shader_mat != null:
			_shader_mat.set_shader_parameter("terrain_ecotone_noise", terrain_ecotone_noise)
		if _season_transition_mat != null:
			_season_transition_mat.set_shader_parameter("terrain_ecotone_noise", terrain_ecotone_noise)
		_push_overlay_edge_transition_data()
@export var day_night_enabled: bool = true
@export var water_effect_enabled: bool = true
@export var ocean_current_enabled: bool = true
@export var extreme_weather_ground_effect_enabled: bool = true
@export var perf_sampler_enabled: bool = false

@export_group("Terrain Horizon Shadow")
@export_range(0.0, 1.0, 0.01) var terrain_horizon_strength: float = 0.70:
	set(value):
		terrain_horizon_strength = clampf(value, 0.0, 1.0)
		_push_terrain_horizon_uniforms()
@export_range(0.01, 1.0, 0.005) var terrain_horizon_softness: float = 0.16:
	set(value):
		terrain_horizon_softness = clampf(value, 0.01, 1.0)
		_push_terrain_horizon_uniforms()
@export_range(0.30, 1.5708, 0.01) var terrain_horizon_max_angle: float = 1.309:
	set(value):
		terrain_horizon_max_angle = clampf(value, 0.30, 1.5708)
		_push_terrain_horizon_uniforms()
@export_range(0.35, 1.0, 0.01) var terrain_horizon_cast_floor: float = 0.82:
	set(value):
		terrain_horizon_cast_floor = clampf(value, 0.35, 1.0)
		_push_terrain_horizon_uniforms()
@export_range(0, 2, 1) var terrain_horizon_debug_view: int = 0:
	set(value):
		terrain_horizon_debug_view = clampi(value, 0, 2)
		_push_terrain_horizon_uniforms()

# [terrain-gi 2026-07-31] 从同一张 horizon 图派生的全局光照。设计见
# docs/cpp-dots-runtime/terrain-gi-bake.md。三个强度全部归零即精确回退到接入 GI 之前，
# 这是视觉回归定位的主要手段。
@export_group("Terrain GI")
@export_range(0.0, 1.0, 0.01) var gi_ao_strength: float = 0.85:
	set(value):
		gi_ao_strength = clampf(value, 0.0, 1.0)
		_push_terrain_horizon_uniforms()
## V_sky 下限。峡谷底部仍有岩壁多次散射，纯几何遮蔽的 0 会压成死黑并放大地表 dither 对比。
@export_range(0.0, 1.0, 0.01) var gi_ao_floor: float = 0.45:
	set(value):
		gi_ao_floor = clampf(value, 0.0, 1.0)
		_push_terrain_horizon_uniforms()
## 0=双线性；1=2×2 箱式低通。滤掉视觉高度残差在 AO 上留下的颗粒感，采样次数不变。
@export_range(0.0, 1.0, 0.01) var gi_ao_smoothing: float = 0.75:
	set(value):
		gi_ao_smoothing = clampf(value, 0.0, 1.0)
		_push_terrain_horizon_uniforms()
## 环境光法线向 bent normal 偏转的比例。1.0 会完全丢弃几何法线，导致块状跳变。
@export_range(0.0, 1.0, 0.01) var gi_bent_strength: float = 0.35:
	set(value):
		gi_bent_strength = clampf(value, 0.0, 1.0)
		_push_terrain_horizon_uniforms()
@export_range(0.0, 1.0, 0.01) var gi_normal_floor: float = 0.85:
	set(value):
		gi_normal_floor = clampf(value, 0.0, 1.0)
		_push_terrain_horizon_uniforms()
@export_range(0.0, 0.5, 0.01) var gi_bounce_strength: float = 0.18:
	set(value):
		gi_bounce_strength = clampf(value, 0.0, 0.5)
		_push_terrain_horizon_uniforms()
## 0=off 1=sky visibility 2=bent normal 3=occluder cell id 4=bounce only
@export_range(0, 4, 1) var gi_debug_view: int = 0:
	set(value):
		gi_debug_view = clampi(value, 0, 4)
		_push_terrain_horizon_uniforms()

@export_group("Visual Overhaul")
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
#
# 此前默认是 null 而且没有任何场景 / 脚本给它赋值，所以 21 层清单（针叶、棕榈、
# 季风林、云雾林、红树、芦苇、仙人掌、苔原地衣、海草……）从未被实例化，全图植被
# 实际上只由 grass/shrub/tree 三层表达，专属生物群系自然长不出对味的植被。
@export var decoration_manifest: Resource = preload("res://data/visual/world_decoration_manifest.tres"):
	set(value):
		decoration_manifest = value
		if is_inside_tree():
			_spawn_detail_layers()
			if _map != null and _world != null:
				_rebuild()
@export_group("Detail Refresh")
# 新家族渲染器必须先通过图形 A/B；默认保持旧渲染器，避免未验收路径直接影响玩家。
@export var detail_scatter_family_renderer_enabled: bool = false
@export var detail_scatter_refresh_layers_per_frame: int = 1
@export var detail_scatter_refresh_cells_per_batch: int = 32
@export var detail_scatter_chunked_multimesh_enabled: bool = true
@export_range(2, 32, 1) var detail_scatter_chunk_size_cells: int = 16
@export var detail_scatter_refresh_chunks_per_frame: int = 4
@export_range(1, 128, 1) var detail_scatter_refresh_plan_items_per_frame: int = 16
@export_range(0.25, 10.0, 0.25) var detail_scatter_resident_retention_seconds: float = 2.0
# drain 信用预算：实测 4.0 时高倍速下 backlog 永不排空、帧均 drain 顶满预算
# （tail_vegetation 持续 4-5ms）。配合全链路在途去重后重排队速率大幅下降，
# 2.5ms 足以收敛 backlog，稳态帧成本直接减半。
@export_range(0.0, 20.0, 0.25) var detail_scatter_refresh_apply_budget_ms: float = 2.5
# 入队节流：succession 单元先并入去重累积器，按真实时间窗成批入队。高倍速下
# 跨多天翻转的单元只重建一次，批次数不再随天数线性增长；低速下窗口 < 一日，
# 延迟不可感知。0 表示逐次直通（旧行为）。
@export_range(0.0, 1000.0, 10.0) var detail_scatter_enqueue_coalesce_ms: float = 120.0
# 累积器硬上限：超过即提前冲刷，防止无限堆积。
@export_range(64, 8192, 64) var detail_scatter_enqueue_max_pending_cells: int = 1024
# 积压兜底：待处理批次数超过该阈值时，存量批次与新单元整体去重合并后重新切批，
# 避免同一 chunk 在多个批次里被反复重建的复利积压。
@export_range(2, 64, 1) var detail_scatter_merge_batch_threshold: int = 8
@export var detail_scatter_refresh_log_enabled: bool = true
@export var detail_scatter_rebuild_log_enabled: bool = true
@export_range(0.0, 100.0, 0.25) var detail_scatter_slow_layer_ms: float = 2.0
# 21 层清单接入 + 散布配额化之后总实例数显著上升，旧的 120000 会让全局预算长期
# 触顶、所有层被同比稀释，反过来又抹平生物群系差异。
@export var detail_scatter_desktop_total_instance_budget: int = 120000
@export var detail_scatter_mobile_total_instance_budget: int = 12000

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
@export var lake_water_color: Color = Color(0.18, 0.45, 0.60)
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

# ─── 波浪可读性 / 细节法线（2026-06-29，类 UE 材质实例参数实时调） ──────────
# 这几个字段用「内联 setter」直接把值推到 _shader_mat：运行时在远程检视器里选中
# 本节点（WorldRoot/HexRenderer），展开 Inspector 拖动滑条即实时刷新画面，
# 无需重编 shader / 重启游戏。_shader_mat 尚未创建时（.tscn 反序列化阶段）安全跳过，
# 由 _apply_*（材质创建后）补推一次初值。
@export_group("Water Waves (live-tunable)")
@export_range(0.0, 8.0, 0.05, "or_greater") var water_wave_shade_strength: float = 1.5:
	set(v):
		water_wave_shade_strength = v
		if _shader_mat != null:
			_shader_mat.set_shader_parameter("water_wave_shade_strength", v)
@export_range(0.0, 2.0, 0.01, "or_greater") var water_wave_patch_strength: float = 1.58:
	set(v):
		water_wave_patch_strength = v
		if _shader_mat != null:
			_shader_mat.set_shader_parameter("water_wave_patch_strength", v)
@export_range(0.1, 4.0, 0.01, "or_greater", "or_less") var water_wave_patch_scale: float = 2.69:
	set(v):
		water_wave_patch_scale = v
		if _shader_mat != null:
			_shader_mat.set_shader_parameter("water_wave_patch_scale", v)
@export_range(0.0, 6.0, 0.01, "or_greater") var water_base_normal_strength: float = 1.17:
	set(v):
		water_base_normal_strength = v
		if _shader_mat != null:
			_shader_mat.set_shader_parameter("water_base_normal_strength", v)
@export_range(0.1, 4.0, 0.01, "or_greater", "or_less") var water_base_normal_scale: float = 0.93:
	set(v):
		water_base_normal_scale = v
		if _shader_mat != null:
			_shader_mat.set_shader_parameter("water_base_normal_scale", v)
@export_range(0.0, 8.0, 0.05, "or_greater") var water_detail_normal_strength: float = 0.75:
	set(v):
		water_detail_normal_strength = v
		if _shader_mat != null:
			_shader_mat.set_shader_parameter("water_detail_normal_strength", v)
@export_range(0.02, 4.0, 0.01, "or_greater", "or_less") var water_detail_normal_scale: float = 0.48:
	set(v):
		water_detail_normal_scale = v
		if _shader_mat != null:
			_shader_mat.set_shader_parameter("water_detail_normal_scale", v)
@export_range(0.0, 4.0, 0.01, "or_greater") var water_detail_normal_warp: float = 0.7:
	set(v):
		water_detail_normal_warp = v
		if _shader_mat != null:
			_shader_mat.set_shader_parameter("water_detail_normal_warp", v)
@export_range(0.0, 3.0, 0.01, "or_greater") var water_sss_strength: float = 0.18:
	set(v):
		water_sss_strength = v
		if _shader_mat != null:
			_shader_mat.set_shader_parameter("water_sss_strength", v)

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
var _border_layer: CountryBorderLayer = null  # 国界线（几何 ribbon，z=6）
var _fog_layer: FogOfWarLayer = null  # 视野迷雾（全图 quad，z=12，盖住天气与国界）
var _fog_enabled: bool = false
var _fog_early_out: bool = false
# Decoration / vegetation 散布层（数据驱动）：默认回退到 grass/shrub/tree 三个
# @export profile；配置 decoration_manifest 后按其 layers 数组生成 N 层。
var _detail_layers: Array = []
var _detail_family_layer = null
var _detail_family_dirty_chunks: Dictionary = {}
var _detail_refresh_queue: Array = []
var _detail_refresh_indices: PackedInt32Array = PackedInt32Array()
var _detail_refresh_batches: Array = []
var _detail_plan_phase: int = DETAIL_PLAN_IDLE
var _detail_plan_probe = null
var _detail_plan_cursor: int = 0
var _detail_plan_key_cursor: int = 0
var _detail_plan_chunk_cursor: int = 0
var _detail_plan_layer_cursor: int = 0
var _detail_plan_dirty_chunks: Dictionary = {}
var _detail_plan_chunk_keys: Array = []
var _detail_plan_chunks: Array = []
var _detail_plan_had_chunk_plan: bool = false
var _detail_plan_fallback_profile_mask: int = 0
var _detail_plan_all_family_mask: int = 0
var _detail_plan_all_profile_mask: int = 0
var _last_detail_refresh_report: Dictionary = {}
# 入队节流/合并状态：跨日去重累积器 + 上次冲刷时刻。
var _scatter_pending_cells: PackedInt32Array = PackedInt32Array()
var _scatter_pending_seen: Dictionary = {}
var _scatter_requeue_cells: Dictionary = {}
var _scatter_cell_family_masks: Dictionary = {}
var _scatter_cell_profile_masks: Dictionary = {}
var _scatter_cell_generations: Dictionary = {}
var _detail_deferred_chunks: Dictionary = {}
var _detail_deferred_profile_masks: Dictionary = {}
var _detail_offscreen_deferred_cells: int = 0
var _detail_coalesced_cells: int = 0
var _detail_affected_family_count: int = 0
var _detail_stale_generation_drops: int = 0
var _camera_world_rect: Rect2 = Rect2()
var _camera_world_center: Vector2 = Vector2.ZERO
var _camera_view_initialized: bool = false
var _detail_visibility_last_ms: float = 0.0
var _detail_next_resident_sweep_msec: int = 0
var _detail_evicted_superchunks: int = 0
var _detail_render_chunk_count: int = 0
var _detail_prefetch_chunk_count: int = 0
# 全链路在途去重：覆盖 累积器 + 待处理批次 + 当前批次 的全部 cell。
# 气候提交以 ~6 帧节奏反复 dirty 同一批 cell；旧的 accumulator 去重在 flush 后
# 即失效，导致仍在队列里的 cell 被重复入队、同一 chunk 被重建多次。在途集合在
# cell 入队时加入、所属批次 drain 完成时移除；refresh 在 drain 时读取最新气候
# 状态，跳过重复入队不损失任何状态正确性。
var _scatter_inflight: Dictionary = {}
var _scatter_enqueue_dedup_skips: int = 0
var _scatter_last_enqueue_msec: int = 0
# drain 信用制预算：每帧累积 apply_budget（上限 2×），chunk 按实测成本扣减。
var _drain_credit_ms: float = 0.0
# 最近一次实际推进 chunk 的引擎帧号：防饿死强制推进用（见 drain 循环）。
var _drain_last_progress_frame: int = 0
var _drain_cfg_logged: bool = false
var _last_detail_budget_report: Dictionary = {}
# 全局实例预算同步状态。21 层分块 MultiMesh 不能在每个 succession chunk 后全量
# 下发 visible_instance_count；那会把名义 2.5ms 的 drain 放大到几十毫秒。
# target 由当前总实例数计算，apply_fraction 是本轮渐进下发所用的稳定快照；
# 每帧最多推进 detail_scatter_refresh_layers_per_frame 层。
const DETAIL_BUDGET_FRACTION_EPSILON: float = 0.0025
var _detail_budget_target_fraction: float = 1.0
var _detail_budget_applied_fraction: float = -1.0
var _detail_budget_apply_fraction: float = 1.0
var _detail_budget_apply_cursor: int = 0
var _detail_budget_apply_active: bool = false
var _detail_budget_apply_count: int = 0
var _detail_budget_apply_skip_count: int = 0
var _detail_budget_apply_ms_total: float = 0.0
var _detail_budget_last_apply_ms: float = 0.0
var _detail_budget_cached_total: int = 0
var _detail_budget_total_dirty: bool = true
var _detail_budget_total_scan_count: int = 0
var _detail_budget_last_scan_ms: float = 0.0
# C++ DCWorldExt 引用，转发给每个散布层做 native 生成。
var _world_ext = null
var _map: MapData = null
var _world: WorldData = null
var _visual_tile_horizon_baker = null
var _visual_tile_horizon_world: WorldData = null
var _camera_zoom: float = 1.0

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
var _tod_sun_dir: Vector3 = Vector3(0.4, -0.7, 0.6).normalized()
var _tod_debug_sun_position_enabled: bool = false
var _tod_debug_sun_uv: Vector2 = Vector2(0.25, 0.5)
var _tod_debug_sun_height_scale: float = 1.0
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
# 帧尾诊断：最近一帧 _drain_detail_refresh_queue 墙钟（毫秒）。tick 日触发的
# 植被 succession 刷新在帧尾 drain，成本逐帧计入 perf 的 tail_vegetation_ms 列。
var _last_detail_drain_ms: float = 0.0
var _last_detail_task_count: int = 0
var _last_detail_forced_task_count: int = 0
var _last_detail_max_task_ms: float = 0.0
var _last_detail_plan_ms: float = 0.0
var _last_detail_encode_ms: float = 0.0
var _last_detail_cache_update_ms: float = 0.0
var _last_detail_assemble_ms: float = 0.0
var _last_detail_upload_ms: float = 0.0


func get_last_detail_drain_ms() -> float:
	return _last_detail_drain_ms

func _ready() -> void:
	# [parallax-rain] 初始化俯视角度
	_camera_pitch = deg_to_rad(camera_pitch_deg)
	_wind_dir = wind_dir.normalized() if wind_dir.length_squared() > 0.0001 else Vector2(0.3, 1.0)
	_wind_strength = wind_strength
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
	# 帧间插值时序:让 weather_layer._process 最晚执行,保证在 LUT 烘焙(SUS/DC 系统)之后、同帧渲染前
	# 检测到 weather_lut_update_usec 变化并把 weather_lerp 归 0 → 消除"curr 已换帧但 lerp 还未重置"的一帧频闪。
	_weather_layer.process_priority = 1000
	if _world != null and _weather_layer.has_method("set_world_ref"):
		_weather_layer.set_world_ref(_world)  # 帧间插值:供 weather_layer 取 weather_lut_prev_tex
	# 国界线（z=6，在数据 overlay 之上）与视野迷雾（z=12，盖住天气/高亮/国界）。
	# 与 WeatherLayer 同套：代码创建 + 世界坐标几何，不进 .tscn。
	_border_layer = CountryBorderLayer.new()
	_border_layer.name = "CountryBorderLayer"
	add_child(_border_layer)
	_fog_layer = FogOfWarLayer.new()
	_fog_layer.name = "FogOfWarLayer"
	add_child(_fog_layer)
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
	if detail_scatter_family_renderer_enabled and _detail_family_layer != null \
			and is_instance_valid(_detail_family_layer):
		_detail_family_layer.set_frame_state(_world_time, _detail_wind_dir, wind_boost)
	else:
		_for_each_vegetation_layer(func(layer: ShrubLayer) -> void:
			layer.set_world_time(_world_time)
			layer.set_wind_field(_detail_wind_dir, wind_boost)
		)
	_sweep_dormant_detail_chunks()
	var drain_started_usec := Time.get_ticks_usec()
	_drain_detail_refresh_queue()
	_last_detail_drain_ms = float(Time.get_ticks_usec() - drain_started_usec) / 1000.0
	if _season_transition_mat != null:
		_season_transition_mat.set_shader_parameter("world_time", _world_time)
		_update_season_transition()
	# 任务 1：性能采样（仅当 perf_sampler_enabled 为 true 时启用）
	if _perf_sampler != null:
		_perf_sampler.push_frame_ms(delta * 1000.0)


func _sweep_dormant_detail_chunks() -> void:
	if not detail_scatter_family_renderer_enabled or not _camera_view_initialized:
		return
	var now_msec := Time.get_ticks_msec()
	if now_msec < _detail_next_resident_sweep_msec:
		return
	_detail_next_resident_sweep_msec = now_msec + 250
	var retention_msec := maxi(250, int(round(detail_scatter_resident_retention_seconds * 1000.0)))
	var evicted := 0
	for layer in _detail_layers:
		if layer != null and is_instance_valid(layer) \
				and layer.has_method("evict_dormant_detail_chunks"):
			evicted += int(layer.evict_dormant_detail_chunks(now_msec, retention_msec))
	if _detail_family_layer != null and is_instance_valid(_detail_family_layer) \
			and _detail_family_layer.has_method("evict_dormant_chunks"):
		var family_evicted := int(
			_detail_family_layer.evict_dormant_chunks(now_msec, retention_msec))
		_detail_evicted_superchunks += family_evicted
		evicted += family_evicted
	if evicted > 0:
		_mark_detail_budget_total_dirty()

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
	_shader_mat.shader = _apply_shader_variant_prefix(fallback_shader, shader_path)
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
	return _apply_shader_variant_prefix(shader, source_path)


func _visual_tiles_active() -> bool:
	return _world != null and _world.visual_tiles != null \
		and bool(_world.visual_tiles.ready) \
		and String(_world.visual_tiles.layout.mode) == "tiled"


func _apply_shader_variant_prefix(shader: Shader, source_path: String) -> Shader:
	if shader == null:
		return null
	var prefix := ""
	if _visual_tiles_active():
		prefix += "#define MAP_VISUAL_TILED\n"
	if OS.has_feature("mobile") and _mobile_quality_tier_define != "":
		prefix += _shader_quality_define_prefix(_mobile_quality_tier_define)
	# [pk-web-texture-budget] Compatibility(GLES3/WebGL2) 后端只保证 16 个
	# fragment 纹理单元；world_map.gdshader 是按桌面 Forward+/Mobile(32+) 预算
	# 声明的 sampler 数量，超预算会在链接期报
	# "texture image units count exceeds MAX_TEXTURE_IMAGE_UNITS(16)" 并整体
	# 渲染失败。裁掉几张已经在该后端恒不生效的 sampler（terrain_material_tex /
	# ocean_upwelling_tex，见各自声明处注释）。
	if DCFeatureFlags.is_compatibility_renderer():
		prefix += "#define PK_WEB_TEXTURE_BUDGET\n"
	if prefix.is_empty():
		return shader
	var variant := shader.duplicate() as Shader
	variant.code = prefix + shader.code
	print("[hex_renderer/variant] tiled=%s quality=%s web_texture_budget=%s shader=%s" % [
		_visual_tiles_active(), _mobile_quality_tier_define,
		DCFeatureFlags.is_compatibility_renderer(), source_path])
	return variant


# Mobile shader quality tier（2026-06-15）：由 main.gd::_push_visual_toggles 推过来。
# 空字符串 = 桌面端 / 不 prepend define。可选值 "MOBILE_QUALITY_LOW" / "MID" / "HIGH"。
var _mobile_quality_tier_define: String = ""

func set_mobile_quality_tier(tier_define: String) -> void:
	var veg_tier := _mobile_quality_tier_from_define(tier_define)
	_for_each_vegetation_layer(func(layer: ShrubLayer) -> void:
		layer.set_mobile_quality_tier(veg_tier)
	)
	if _detail_family_layer != null and is_instance_valid(_detail_family_layer) and _map != null:
		_detail_family_layer.configure(_detail_layers, detail_scatter_family_renderer_enabled)
		if detail_scatter_family_renderer_enabled and _camera_view_initialized:
			_queue_missing_prefetch_detail_chunks()
			_reactivate_deferred_detail_chunks()
	_mark_detail_budget_total_dirty()
	_apply_detail_global_budget()
	if _weather_layer != null and _weather_layer.has_method("set_mobile_quality_tier"):
		_weather_layer.set_mobile_quality_tier(tier_define)
	if _fog_layer != null:
		_fog_layer.set_mobile_quality_tier(tier_define)
		_apply_fog_early_out()
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


func _shader_quality_define_prefix(tier_define: String) -> String:
	match tier_define:
		"MOBILE_QUALITY_LOW":
			return "#define MOBILE_QUALITY_LOW\n#define PK_SHADER_TIER_LOW\n"
		"MOBILE_QUALITY_HIGH":
			return "#define MOBILE_QUALITY_HIGH\n#define PK_SHADER_TIER_HIGH\n"
		_:
			return "#define MOBILE_QUALITY_MID\n#define PK_SHADER_TIER_MID\n"


func _for_each_vegetation_layer(callable: Callable) -> void:
	for layer in _detail_layers:
		if layer != null:
			callable.call(layer)


func _sync_family_materials_from_sources() -> void:
	if detail_scatter_family_renderer_enabled and _detail_family_layer != null \
			and is_instance_valid(_detail_family_layer):
		_detail_family_layer.sync_dynamic_materials()


func queue_detail_scatter_refresh(indices: PackedInt32Array) -> void:
	var changes = DetailScatterChangeSetScript.new()
	for raw_idx in indices:
		changes.append_change(int(raw_idx), DetailScatterChangeSetScript.AXIS_UNKNOWN, 0, 0, 0, 0, 0, 0)
	queue_detail_scatter_changes(changes)


func _detail_all_family_mask() -> int:
	var mask := 0
	for layer in _detail_layers:
		if layer != null and is_instance_valid(layer) and layer.has_method("detail_render_family_mask"):
			mask |= int(layer.detail_render_family_mask())
	return mask if mask != 0 else 0x1F


func _detail_family_mask_for_change(changes, row: int) -> int:
	var axis_mask := int(changes.axis_masks[row])
	if (axis_mask & DetailScatterChangeSetScript.AXIS_UNKNOWN) != 0:
		return _detail_all_family_mask()
	var mask := 0
	for layer in _detail_layers:
		if layer == null or not is_instance_valid(layer) \
				or not layer.has_method("detail_change_affects_profile"):
			continue
		if bool(layer.detail_change_affects_profile(
				axis_mask,
				int(changes.old_vegetation[row]), int(changes.new_vegetation[row]),
				int(changes.old_landform[row]), int(changes.new_landform[row]),
				int(changes.old_cover[row]), int(changes.new_cover[row])
		)):
			mask |= int(layer.detail_render_family_mask())
	return mask


func _detail_profile_mask_for_change(changes, row: int) -> int:
	var axis_mask := int(changes.axis_masks[row])
	if (axis_mask & DetailScatterChangeSetScript.AXIS_UNKNOWN) != 0:
		return (1 << _detail_layers.size()) - 1
	var mask := 0
	for layer_idx in range(_detail_layers.size()):
		var layer = _detail_layers[layer_idx]
		if layer == null or not is_instance_valid(layer) \
				or not layer.has_method("detail_change_affects_profile"):
			continue
		if bool(layer.detail_change_affects_profile(
				axis_mask,
				int(changes.old_vegetation[row]), int(changes.new_vegetation[row]),
				int(changes.old_landform[row]), int(changes.new_landform[row]),
				int(changes.old_cover[row]), int(changes.new_cover[row])
		)):
			mask |= 1 << layer_idx
	return mask


func queue_detail_scatter_changes(changes) -> void:
	if changes == null or _detail_layers.is_empty() \
			or not changes.has_method("is_well_formed") \
			or not bool(changes.is_well_formed()) or bool(changes.is_empty()):
		return
	var affected_families := 0
	for row in range(changes.cell_indices.size()):
		var ci := int(changes.cell_indices[row])
		if ci < 0:
			continue
		var generation := int(changes.generation)
		var previous_generation := int(_scatter_cell_generations.get(ci, -1))
		if generation >= 0 and previous_generation > generation:
			_detail_stale_generation_drops += 1
			continue
		_scatter_cell_generations[ci] = maxi(previous_generation, generation)
		var family_mask := _detail_family_mask_for_change(changes, row)
		var profile_mask := _detail_profile_mask_for_change(changes, row)
		if family_mask == 0 or profile_mask == 0:
			continue
		affected_families |= family_mask
		if _camera_view_initialized and not _detail_layers.is_empty():
			var probe = _detail_layers[0]
			if probe != null and is_instance_valid(probe) \
					and probe.has_method("detail_chunk_id_for_cell") \
					and probe.has_method("detail_chunk_is_in_prefetch"):
				var chunk_id := int(probe.detail_chunk_id_for_cell(ci))
				if chunk_id >= 0 and not bool(probe.detail_chunk_is_in_prefetch(chunk_id)):
					_detail_deferred_chunks[chunk_id] = int(
						_detail_deferred_chunks.get(chunk_id, 0)) | family_mask
					_detail_deferred_profile_masks[chunk_id] = int(
						_detail_deferred_profile_masks.get(chunk_id, 0)) | profile_mask
					_detail_offscreen_deferred_cells += 1
					continue
		var previous_mask := int(_scatter_cell_family_masks.get(ci, 0))
		_scatter_cell_family_masks[ci] = previous_mask | family_mask
		var previous_profile_mask := int(_scatter_cell_profile_masks.get(ci, 0))
		_scatter_cell_profile_masks[ci] = previous_profile_mask | profile_mask
		if _scatter_pending_seen.has(ci):
			_detail_coalesced_cells += 1
			continue
		if _scatter_inflight.has(ci):
			# 当前 batch 已经按旧 generation 建好任务；完成后只补跑一次最新状态。
			_scatter_requeue_cells[ci] = true
			_scatter_enqueue_dedup_skips += 1
			continue
		_scatter_pending_seen[ci] = true
		_scatter_inflight[ci] = true
		_scatter_pending_cells.append(ci)
	_detail_affected_family_count = _count_set_bits(affected_families)
	var now_msec := Time.get_ticks_msec()
	var window_due := _scatter_last_enqueue_msec <= 0 or \
		float(now_msec - _scatter_last_enqueue_msec) >= maxf(0.0, detail_scatter_enqueue_coalesce_ms)
	if not window_due and _scatter_pending_cells.size() < detail_scatter_enqueue_max_pending_cells:
		return
	_scatter_last_enqueue_msec = now_msec
	var flushed := _scatter_pending_cells
	_scatter_pending_cells = PackedInt32Array()
	_scatter_pending_seen.clear()
	if _detail_refresh_batches.size() >= maxi(2, detail_scatter_merge_batch_threshold):
		flushed = _merge_pending_detail_refresh_batches(flushed)
	_enqueue_detail_refresh_batches(_dedup_detail_refresh_indices(flushed))
	if _detail_refresh_queue.is_empty():
		_start_next_detail_refresh_batch()
	_last_detail_refresh_report = {
		"queued_chunks": _detail_refresh_queue.size(),
		"queued_layers": _detail_layers.size(),
		"dirty_cells": _detail_refresh_indices.size(),
		"pending_batches": _detail_refresh_batches.size(),
		"chunks_done": 0,
		"layers_done": 0,
		"batch_chunks": int(_last_detail_refresh_report.get("batch_chunks", 0)),
		"elapsed_ms": 0.0,
	}
	if detail_scatter_refresh_log_enabled:
		print("[detail_scatter/QUEUE] succession active_cells=%d pending_batches=%d queued_chunks=%d chunks_per_frame=%d chunk_ms_budget=%.2f cells_per_batch=%d" % [
			_detail_refresh_indices.size(),
			_detail_refresh_batches.size(),
			_detail_refresh_queue.size(),
			maxi(1, detail_scatter_refresh_chunks_per_frame),
			maxf(0.0, detail_scatter_refresh_apply_budget_ms),
			maxi(1, detail_scatter_refresh_cells_per_batch),
		])


func _count_set_bits(value: int) -> int:
	var count := 0
	var bits := value
	while bits != 0:
		count += bits & 1
		bits >>= 1
	return count


func _dedup_detail_refresh_indices(indices: PackedInt32Array) -> PackedInt32Array:
	var seen := {}
	var out := PackedInt32Array()
	for v in indices:
		var idx := int(v)
		if seen.has(idx):
			continue
		seen[idx] = true
		out.append(idx)
	return out


func _enqueue_detail_refresh_batches(indices: PackedInt32Array) -> void:
	if indices.is_empty():
		return
	var batch_size := maxi(1, detail_scatter_refresh_cells_per_batch)
	var current := PackedInt32Array()
	for idx in indices:
		current.append(int(idx))
		if current.size() >= batch_size:
			_detail_refresh_batches.append(current)
			current = PackedInt32Array()
	if not current.is_empty():
		_detail_refresh_batches.append(current)


# 积压合并：把待处理批次与新单元整体去重后返回一条流，调用方负责重新切批。
# 已在 chunk 队列中的批次不动（本批即将 drain 完）。
func _merge_pending_detail_refresh_batches(extra: PackedInt32Array) -> PackedInt32Array:
	var seen := {}
	var merged := PackedInt32Array()
	for batch in _detail_refresh_batches:
		for raw in batch:
			var ci := int(raw)
			if seen.has(ci):
				continue
			seen[ci] = true
			merged.append(ci)
	for raw in extra:
		var ci := int(raw)
		if seen.has(ci):
			continue
		seen[ci] = true
		merged.append(ci)
	_detail_refresh_batches.clear()
	return merged


func _release_detail_refresh_inflight(cells: PackedInt32Array) -> void:
	if _scatter_inflight.is_empty():
		return
	var requeue := PackedInt32Array()
	for raw in cells:
		var ci := int(raw)
		_scatter_inflight.erase(ci)
		if _scatter_requeue_cells.has(ci):
			_scatter_requeue_cells.erase(ci)
			_scatter_inflight[ci] = true
			requeue.append(ci)
			continue
		_scatter_cell_family_masks.erase(ci)
		_scatter_cell_profile_masks.erase(ci)
	if not requeue.is_empty():
		_enqueue_detail_refresh_batches(_dedup_detail_refresh_indices(requeue))


func _reset_detail_refresh_plan() -> void:
	_detail_plan_phase = DETAIL_PLAN_IDLE
	_detail_plan_probe = null
	_detail_plan_cursor = 0
	_detail_plan_key_cursor = 0
	_detail_plan_chunk_cursor = 0
	_detail_plan_layer_cursor = 0
	_detail_plan_dirty_chunks.clear()
	_detail_plan_chunk_keys.clear()
	_detail_plan_chunks.clear()
	_detail_plan_had_chunk_plan = false
	_detail_plan_fallback_profile_mask = 0
	_detail_plan_all_family_mask = 0
	_detail_plan_all_profile_mask = 0


func _begin_detail_refresh_plan() -> void:
	_detail_refresh_indices = _detail_refresh_batches.pop_front()
	_detail_refresh_queue.clear()
	_reset_detail_refresh_plan()
	_detail_plan_all_family_mask = _detail_all_family_mask()
	_detail_plan_all_profile_mask = (1 << _detail_layers.size()) - 1
	if detail_scatter_chunked_multimesh_enabled:
		for layer in _detail_layers:
			if layer != null and is_instance_valid(layer) \
					and layer.has_method("detail_chunk_id_for_cell") \
					and layer.has_method("detail_chunk_cells"):
				_detail_plan_probe = layer
				break
	_detail_plan_phase = DETAIL_PLAN_COLLECT \
		if _detail_plan_probe != null else DETAIL_PLAN_FALLBACK_COLLECT


func _detail_plan_should_yield(deadline_usec: int, items_done: int, max_items: int) -> bool:
	if max_items > 0 and items_done >= max_items:
		return true
	return deadline_usec > 0 and items_done > 0 and Time.get_ticks_usec() >= deadline_usec


func _continue_detail_refresh_plan(deadline_usec: int, max_items: int) -> void:
	var items_done := 0
	var enqueued_msec := Time.get_ticks_msec()
	while _detail_plan_phase != DETAIL_PLAN_IDLE:
		match _detail_plan_phase:
			DETAIL_PLAN_COLLECT:
				if _detail_plan_cursor < _detail_refresh_indices.size():
					var cell_idx := int(_detail_refresh_indices[_detail_plan_cursor])
					_detail_plan_cursor += 1
					var chunk_id := int(_detail_plan_probe.detail_chunk_id_for_cell(cell_idx))
					if chunk_id >= 0:
						var dirty_indices: PackedInt32Array = _detail_plan_dirty_chunks.get(
							chunk_id, PackedInt32Array())
						dirty_indices.append(cell_idx)
						_detail_plan_dirty_chunks[chunk_id] = dirty_indices
					items_done += 1
					if _detail_plan_should_yield(deadline_usec, items_done, max_items):
						return
					continue
				_detail_plan_chunk_keys = _detail_plan_dirty_chunks.keys()
				_detail_plan_chunk_keys.sort()
				_detail_plan_had_chunk_plan = not _detail_plan_chunk_keys.is_empty()
				_detail_plan_phase = DETAIL_PLAN_BUILD_CHUNKS \
					if _detail_plan_had_chunk_plan else DETAIL_PLAN_FALLBACK_COLLECT
				_detail_plan_cursor = 0

			DETAIL_PLAN_BUILD_CHUNKS:
				if _detail_plan_key_cursor < _detail_plan_chunk_keys.size():
					var chunk_id := int(_detail_plan_chunk_keys[_detail_plan_key_cursor])
					_detail_plan_key_cursor += 1
					var dirty_indices: PackedInt32Array = _detail_plan_dirty_chunks[chunk_id]
					var family_mask := 0
					var profile_mask := 0
					for raw_idx in dirty_indices:
						family_mask |= int(_scatter_cell_family_masks.get(
							int(raw_idx), _detail_plan_all_family_mask))
						profile_mask |= int(_scatter_cell_profile_masks.get(
							int(raw_idx), _detail_plan_all_profile_mask))
					if family_mask == 0:
						family_mask = _detail_plan_all_family_mask
					if profile_mask == 0:
						profile_mask = _detail_plan_all_profile_mask
					var in_prefetch := true
					if _detail_plan_probe.has_method("detail_chunk_is_in_prefetch"):
						in_prefetch = bool(_detail_plan_probe.detail_chunk_is_in_prefetch(chunk_id))
					if not in_prefetch:
						_detail_deferred_chunks[chunk_id] = int(
							_detail_deferred_chunks.get(chunk_id, 0)) | family_mask
						_detail_deferred_profile_masks[chunk_id] = int(
							_detail_deferred_profile_masks.get(chunk_id, 0)) | profile_mask
						_detail_offscreen_deferred_cells += dirty_indices.size()
					else:
						var cell_indices: PackedInt32Array = _detail_plan_probe.detail_chunk_cells(chunk_id)
						var visible := bool(_detail_plan_probe.detail_chunk_is_render_visible(chunk_id)) \
							if _detail_plan_probe.has_method("detail_chunk_is_render_visible") else true
						_detail_plan_chunks.append({
							"chunk_id": chunk_id,
							"cell_indices": cell_indices,
							"dirty_indices": dirty_indices,
							"dirty_cells": dirty_indices.size(),
							"family_mask": family_mask,
							"profile_mask": profile_mask,
							"visible_priority": visible,
							"distance_sq": _detail_chunk_center_from_cells(
								cell_indices).distance_squared_to(_camera_world_center),
						})
					items_done += 1
					if _detail_plan_should_yield(deadline_usec, items_done, max_items):
						return
					continue
				_detail_plan_chunks.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
					var a_visible := bool(a.get("visible_priority", true))
					var b_visible := bool(b.get("visible_priority", true))
					if a_visible != b_visible:
						return a_visible
					return float(a.get("distance_sq", 0.0)) < float(b.get("distance_sq", 0.0))
				)
				_detail_plan_phase = DETAIL_PLAN_BEGIN_LAYERS
				_detail_plan_layer_cursor = 0

			DETAIL_PLAN_BEGIN_LAYERS:
				if _detail_plan_layer_cursor < _detail_layers.size():
					var layer = _detail_layers[_detail_plan_layer_cursor]
					_detail_plan_layer_cursor += 1
					if layer != null and is_instance_valid(layer) \
							and layer.has_method("begin_detail_chunk_refresh"):
						layer.begin_detail_chunk_refresh()
					items_done += 1
					if _detail_plan_should_yield(deadline_usec, items_done, max_items):
						return
					continue
				_detail_plan_phase = DETAIL_PLAN_BUILD_TASKS
				_detail_plan_chunk_cursor = 0
				_detail_plan_layer_cursor = 0

			DETAIL_PLAN_BUILD_TASKS:
				if _detail_plan_chunk_cursor >= _detail_plan_chunks.size():
					_detail_plan_phase = DETAIL_PLAN_FINALIZE
					continue
				var chunk: Dictionary = _detail_plan_chunks[_detail_plan_chunk_cursor]
				if _detail_plan_layer_cursor >= _detail_layers.size():
					_detail_plan_chunk_cursor += 1
					_detail_plan_layer_cursor = 0
					continue
				var layer_idx := _detail_plan_layer_cursor
				_detail_plan_layer_cursor += 1
				var profile_mask := int(chunk.get("profile_mask", _detail_plan_all_profile_mask))
				if (profile_mask & (1 << layer_idx)) != 0:
					var layer = _detail_layers[layer_idx]
					if layer != null and is_instance_valid(layer) \
							and layer.has_method("refresh_chunk_for_succession"):
						_detail_refresh_queue.append({
							"layer": layer,
							"chunk_id": int(chunk.get("chunk_id", -1)),
							"cell_indices": chunk.get("cell_indices", PackedInt32Array()),
							"dirty_indices": chunk.get("dirty_indices", PackedInt32Array()),
							"dirty_cells": int(chunk.get("dirty_cells", 0)),
							"family_mask": int(chunk.get(
								"family_mask", _detail_plan_all_family_mask)),
							"family": int(layer.detail_render_family()) \
								if layer.has_method("detail_render_family") else 0,
							"profile_index": layer_idx,
							"enqueued_msec": enqueued_msec,
							"visible_priority": bool(chunk.get("visible_priority", true)),
						})
				items_done += 1
				if _detail_plan_should_yield(deadline_usec, items_done, max_items):
					return

			DETAIL_PLAN_FALLBACK_COLLECT:
				if _detail_plan_cursor < _detail_refresh_indices.size():
					var cell_idx := int(_detail_refresh_indices[_detail_plan_cursor])
					_detail_plan_cursor += 1
					_detail_plan_fallback_profile_mask |= int(_scatter_cell_profile_masks.get(
						cell_idx, _detail_plan_all_profile_mask))
					items_done += 1
					if _detail_plan_should_yield(deadline_usec, items_done, max_items):
						return
					continue
				if _detail_plan_fallback_profile_mask == 0:
					_detail_plan_fallback_profile_mask = _detail_plan_all_profile_mask
				_detail_plan_layer_cursor = 0
				_detail_plan_phase = DETAIL_PLAN_FALLBACK_TASKS

			DETAIL_PLAN_FALLBACK_TASKS:
				if _detail_plan_layer_cursor >= _detail_layers.size():
					_detail_plan_phase = DETAIL_PLAN_FINALIZE
					continue
				var layer_idx := _detail_plan_layer_cursor
				_detail_plan_layer_cursor += 1
				if (_detail_plan_fallback_profile_mask & (1 << layer_idx)) != 0:
					var layer = _detail_layers[layer_idx]
					if layer != null and is_instance_valid(layer):
						_detail_refresh_queue.append({
							"layer": layer,
							"profile_index": layer_idx,
							"cell_indices": _detail_refresh_indices,
							"enqueued_msec": enqueued_msec,
							"visible_priority": true,
						})
				items_done += 1
				if _detail_plan_should_yield(deadline_usec, items_done, max_items):
					return

			DETAIL_PLAN_FINALIZE:
				var batch_chunk_count := _detail_plan_chunks.size()
				_last_detail_refresh_report = {
					"queued_chunks": _detail_refresh_queue.size(),
					"queued_layers": _detail_layers.size(),
					"dirty_cells": _detail_refresh_indices.size(),
					"pending_batches": _detail_refresh_batches.size(),
					"chunks_done": 0,
					"layers_done": 0,
					"batch_chunks": batch_chunk_count,
					"elapsed_ms": 0.0,
				}
				_reset_detail_refresh_plan()
				if _detail_refresh_queue.is_empty():
					_release_detail_refresh_inflight(_detail_refresh_indices)
					_detail_refresh_indices = PackedInt32Array()


func _start_next_detail_refresh_batch(
		deadline_usec: int = 0, max_plan_items: int = 0) -> bool:
	if not _detail_refresh_queue.is_empty():
		return true
	if _detail_plan_phase == DETAIL_PLAN_IDLE:
		if _detail_refresh_batches.is_empty():
			_release_detail_refresh_inflight(_detail_refresh_indices)
			_detail_refresh_indices = PackedInt32Array()
			return false
		_begin_detail_refresh_plan()
	# queue_detail_scatter_changes 可在仿真 tick 内调用；零预算调用只初始化状态，
	# 真正规划统一留到 HexRenderer._process 的帧尾预算段。
	if deadline_usec != 0 or max_plan_items > 0:
		_continue_detail_refresh_plan(deadline_usec, max_plan_items)
	return not _detail_refresh_queue.is_empty() \
		or _detail_plan_phase != DETAIL_PLAN_IDLE \
		or not _detail_refresh_batches.is_empty()


func _drain_detail_refresh_queue() -> void:
	_last_detail_task_count = 0
	_last_detail_forced_task_count = 0
	_last_detail_max_task_ms = 0.0
	_last_detail_plan_ms = 0.0
	_last_detail_encode_ms = 0.0
	_last_detail_cache_update_ms = 0.0
	_last_detail_assemble_ms = 0.0
	_last_detail_upload_ms = 0.0
	var chunk_budget := maxi(1, detail_scatter_refresh_chunks_per_frame)
	var ms_budget := maxf(0.0, detail_scatter_refresh_apply_budget_ms)
	# 信用制预算：每帧累积 ms_budget（上限 2× 防暴饮暴食）。严格闸门：信用不足
	# 一整份预算时不启动新 chunk——单个 chunk 成本可超预算（water cache ≈4ms），
	# 宽闸门（信用>0 即放行）会让贵 chunk 几乎每帧漏过，实测排水 3.5ms/帧远超
	# 2.5ms 预算。防饿死：30 帧无进度则强制放行一个 chunk（兜底预算 < chunk 成本
	# 的极端配置）。历史上该闸门曾与可视回归同时出现，事后查明回归根因是
	# GDExt DLL 与烘焙源码版本错配，与本闸门无关。
	var detail_work_pending := not _detail_refresh_queue.is_empty() \
		or _detail_plan_phase != DETAIL_PLAN_IDLE \
		or not _detail_refresh_batches.is_empty()
	if ms_budget > 0.0 and detail_work_pending:
		_drain_credit_ms = minf(_drain_credit_ms + ms_budget, ms_budget * 2.0)
	if not _drain_cfg_logged:
		_drain_cfg_logged = true
		print("[detail_scatter/DRAIN_CFG] budget_ms=%.2f chunks_per_frame=%d plan_items=%d cells_per_batch=%d chunk_size=%d" % [
			ms_budget, chunk_budget,
			maxi(1, detail_scatter_refresh_plan_items_per_frame),
			maxi(1, detail_scatter_refresh_cells_per_batch),
			maxi(2, detail_scatter_chunk_size_cells),
		])
	var t0 := Time.get_ticks_usec()
	if _detail_refresh_queue.is_empty():
		var has_pending_work := detail_work_pending
		var can_plan := ms_budget <= 0.0 or _drain_credit_ms > 0.0
		if can_plan:
			var plan_t0 := Time.get_ticks_usec()
			var plan_deadline_usec := 0
			if ms_budget > 0.0:
				var plan_budget_ms := minf(ms_budget, maxf(_drain_credit_ms, 0.0))
				plan_deadline_usec = t0 + int(plan_budget_ms * 1000.0)
			has_pending_work = _start_next_detail_refresh_batch(
				plan_deadline_usec, maxi(1, detail_scatter_refresh_plan_items_per_frame))
			_last_detail_plan_ms = float(Time.get_ticks_usec() - plan_t0) / 1000.0
			if ms_budget > 0.0:
				_drain_credit_ms -= _last_detail_plan_ms
		if _detail_refresh_queue.is_empty():
			_last_detail_refresh_report["plan_ms"] = _last_detail_plan_ms
			_last_detail_refresh_report["plan_active"] = _detail_plan_phase != DETAIL_PLAN_IDLE
			_last_detail_refresh_report["remaining_chunks"] = 0
			_last_detail_refresh_report["pending_batches"] = _detail_refresh_batches.size()
			_last_detail_refresh_report["elapsed_ms"] = float(
				_last_detail_refresh_report.get("elapsed_ms", 0.0)) + _last_detail_plan_ms
			if not has_pending_work:
				# succession 队列排空后继续完成尚未结束的 family/budget 分层下发。
				if _drain_one_detail_family_upload():
					_mark_detail_budget_total_dirty()
				_apply_detail_global_budget(false, true)
			return
	var done := 0
	var forced_one := false
	while done < chunk_budget and not _detail_refresh_queue.is_empty():
		if ms_budget > 0.0:
			var head: Dictionary = _detail_refresh_queue[0]
			var head_wait_msec := Time.get_ticks_msec() - int(
				head.get("enqueued_msec", Time.get_ticks_msec()))
			# 超时只授权这一帧推进一个任务，不能让后续所有超时任务一起绕过预算。
			# 旧逻辑会在 chunks_per_frame=4 时把约 15ms 的任务叠成稳定 60ms 尾耗时。
			var force_progress := done == 0 and bool(head.get("visible_priority", true)) \
				and head_wait_msec >= 100
			if not force_progress:
				if _drain_credit_ms < ms_budget:
					break
				if done > 0 and float(Time.get_ticks_usec() - t0) / 1000.0 >= ms_budget:
					break
			else:
				forced_one = true
		var task: Dictionary = _detail_refresh_queue.pop_front()
		var task_t0 := Time.get_ticks_usec()
		var layer = task.get("layer", null)
		if layer != null and is_instance_valid(layer):
			var task_family_mask := int(task.get("family_mask", _detail_all_family_mask()))
			for raw_idx in task.get("dirty_indices", PackedInt32Array()):
				task_family_mask |= int(_scatter_cell_family_masks.get(int(raw_idx), 0))
			var layer_family_mask := int(layer.detail_render_family_mask()) \
				if layer.has_method("detail_render_family_mask") else _detail_all_family_mask()
			if (task_family_mask & layer_family_mask) == 0:
				continue
			var layer_t0 := Time.get_ticks_usec()
			if task.has("chunk_id") and layer.has_method("refresh_chunk_for_succession"):
				var refreshed := bool(layer.refresh_chunk_for_succession(
					int(task.get("chunk_id", -1)),
					task.get("cell_indices", PackedInt32Array()),
					int(task.get("dirty_cells", 0)),
					task.get("dirty_indices", PackedInt32Array())
				))
				if refreshed and detail_scatter_family_renderer_enabled \
						and layer.has_method("detail_render_family"):
					var family := int(layer.detail_render_family())
					var chunk_id := int(task.get("chunk_id", -1))
					_detail_family_dirty_chunks["%d:%d" % [family, chunk_id]] = {
						"source": layer,
						"chunk_id": chunk_id,
					}
			elif layer.has_method("refresh_for_succession"):
				layer.refresh_for_succession(task.get("cell_indices", _detail_refresh_indices))
			var layer_elapsed := float(Time.get_ticks_usec() - layer_t0) / 1000.0
			_last_detail_task_count += 1
			if layer.has_method("get_scatter_diagnostics"):
				var timing: Dictionary = layer.get_scatter_diagnostics()
				_last_detail_encode_ms += float(timing.get("native_context_ms", 0.0)) \
					+ float(timing.get("native_knobs_ms", 0.0)) \
					+ float(timing.get("native_call_ms", 0.0))
				_last_detail_cache_update_ms += float(timing.get("cache_update_ms", 0.0))
				_last_detail_assemble_ms += float(timing.get("assemble_ms", 0.0))
				_last_detail_upload_ms += float(timing.get("native_apply_ms", 0.0))
			if detail_scatter_refresh_log_enabled and layer.has_method("get_scatter_diagnostics"):
				var d: Dictionary = layer.get_scatter_diagnostics()
				if layer_elapsed >= detail_scatter_slow_layer_ms or float(d.get("rebuild_ms", 0.0)) >= detail_scatter_slow_layer_ms:
					print("[detail_scatter/SLOW_CHUNK] name=%s wall=%.2fms update=%.2fms path=%s inst=%d cand=%d wrap=%d cells=%d chunks=%d sampled=%d active=%d water=%.2fms ctx=%.2fms knobs=%.2fms native=%.2fms apply=%.2fms remaining=%d missing=%d dropped=%d reason=%s" % [
						str(d.get("name", layer.name)),
						layer_elapsed,
						float(d.get("rebuild_ms", 0.0)),
						str(d.get("path", "")),
						int(d.get("instances", 0)),
						int(d.get("candidates", 0)),
						int(d.get("wrap_edge_copies", 0)),
						int(d.get("incremental_cells", 0)),
						int(d.get("dirty_chunks", 0)),
						int(d.get("native_sampled_cells", 0)),
						int(d.get("native_active_cells", 0)),
						float(d.get("native_water_cache_ms", 0.0)),
						float(d.get("native_context_ms", 0.0)),
						float(d.get("native_knobs_ms", 0.0)),
						float(d.get("native_call_ms", 0.0)),
						float(d.get("native_apply_ms", 0.0)),
						_detail_refresh_queue.size(),
					int(d.get("missing_slots", 0)),
					int(d.get("dropped_instances", 0)),
					str(d.get("reason", "")),
				])
		done += 1
		_drain_last_progress_frame = Engine.get_process_frames()
		if ms_budget > 0.0:
			var task_elapsed_ms := float(Time.get_ticks_usec() - task_t0) / 1000.0
			_last_detail_max_task_ms = maxf(_last_detail_max_task_ms, task_elapsed_ms)
			_drain_credit_ms -= task_elapsed_ms
		else:
			_last_detail_max_task_ms = maxf(
				_last_detail_max_task_ms,
				float(Time.get_ticks_usec() - task_t0) / 1000.0)
		if forced_one:
			_last_detail_forced_task_count = 1
			break
	var elapsed := float(Time.get_ticks_usec() - t0) / 1000.0
	# source payload 本帧已写过一个 MultiMesh 时，把 family 合并上传留到空闲帧，
	# 严格维持运行期每帧最多一次 MultiMesh buffer 赋值。
	if done == 0:
		if _drain_one_detail_family_upload():
			_mark_detail_budget_total_dirty()
	else:
		_mark_detail_budget_total_dirty()
	_last_detail_refresh_report["chunks_done"] = int(_last_detail_refresh_report.get("chunks_done", 0)) + done
	_last_detail_refresh_report["layers_done"] = int(_last_detail_refresh_report.get("chunks_done", 0))
	_last_detail_refresh_report["elapsed_ms"] = float(_last_detail_refresh_report.get("elapsed_ms", 0.0)) + elapsed
	_last_detail_refresh_report["remaining_chunks"] = _detail_refresh_queue.size()
	_last_detail_refresh_report["pending_batches"] = _detail_refresh_batches.size()
	_last_detail_refresh_report["plan_ms"] = _last_detail_plan_ms
	_last_detail_refresh_report["plan_active"] = _detail_plan_phase != DETAIL_PLAN_IDLE
	# 一个昂贵 chunk 已经消耗本帧信用时，不再叠加全层 visible-count 同步；
	# 无 chunk 的帧按 layers_per_frame 渐进推进，避免 20+ 层一次性尖峰。
	_apply_detail_global_budget(false, done == 0)
	if _detail_refresh_queue.is_empty() and _detail_plan_phase == DETAIL_PLAN_IDLE:
		if detail_scatter_refresh_log_enabled:
			print("[detail_scatter/DONE] batch_cells=%d chunks=%d batch_chunks=%d elapsed=%.2fms pending_batches=%d budget=%s" % [
				int(_last_detail_refresh_report.get("dirty_cells", 0)),
				int(_last_detail_refresh_report.get("chunks_done", 0)),
				int(_last_detail_refresh_report.get("batch_chunks", 0)),
				float(_last_detail_refresh_report.get("elapsed_ms", 0.0)),
				_detail_refresh_batches.size(),
				str(_last_detail_budget_report),
			])
		_release_detail_refresh_inflight(_detail_refresh_indices)
		_detail_refresh_indices = PackedInt32Array()


func _drain_one_detail_family_upload() -> bool:
	if not detail_scatter_family_renderer_enabled \
			or _detail_family_layer == null or not is_instance_valid(_detail_family_layer):
		return false
	if _detail_family_dirty_chunks.is_empty():
		return bool(_detail_family_layer.drain_one_shadow_upload()) \
			if _detail_family_layer.has_method("drain_one_shadow_upload") else false
	var keys: Array = _detail_family_dirty_chunks.keys()
	keys.sort()
	var key = ""
	for candidate in keys:
		if not _detail_family_upload_has_pending_source(str(candidate)):
			key = str(candidate)
			break
	if key.is_empty():
		return false
	var task: Dictionary = _detail_family_dirty_chunks[key]
	_detail_family_dirty_chunks.erase(key)
	var source = task.get("source", null)
	if source != null and is_instance_valid(source):
		_detail_family_layer.rebuild_source_chunk(source, int(task.get("chunk_id", -1)))
		return true
	return false


func _detail_family_upload_has_pending_source(key: String) -> bool:
	var parts := key.split(":")
	if parts.size() != 2:
		return false
	var family := int(parts[0])
	var chunk_id := int(parts[1])
	for pending in _detail_refresh_queue:
		if int(pending.get("chunk_id", -1)) == chunk_id \
				and int(pending.get("family", 0)) == family:
			return true
	return false


func detail_scatter_refresh_report() -> Dictionary:
	var report := _last_detail_refresh_report.duplicate(true)
	report["inflight_cells"] = _scatter_inflight.size()
	report["enqueue_dedup_skips"] = _scatter_enqueue_dedup_skips
	report["coalesced_cells"] = _detail_coalesced_cells
	report["offscreen_deferred_cells"] = _detail_offscreen_deferred_cells
	report["stale_superchunks"] = _detail_deferred_chunks.size()
	report["render_superchunks"] = _detail_render_chunk_count
	report["prefetch_superchunks"] = _detail_prefetch_chunk_count
	report["affected_families"] = _detail_affected_family_count
	report["visibility_ms"] = _detail_visibility_last_ms
	report["queued_tasks"] = _detail_refresh_queue.size()
	report["stale_generation_drops"] = _detail_stale_generation_drops
	report["evicted_superchunks"] = _detail_evicted_superchunks
	report["oldest_visible_wait_ms"] = _oldest_visible_detail_task_wait_ms()
	report["frame_tasks"] = _last_detail_task_count
	report["frame_forced_tasks"] = _last_detail_forced_task_count
	report["max_task_ms"] = _last_detail_max_task_ms
	report["plan_ms"] = _last_detail_plan_ms
	report["plan_active"] = _detail_plan_phase != DETAIL_PLAN_IDLE
	report["encode_ms"] = _last_detail_encode_ms
	report["cache_update_ms"] = _last_detail_cache_update_ms
	report["assemble_ms"] = _last_detail_assemble_ms
	report["upload_ms"] = _last_detail_upload_ms
	if _detail_family_layer != null and is_instance_valid(_detail_family_layer):
		var family_diag: Dictionary = _detail_family_layer.diagnostics()
		for key in family_diag.keys():
			report["family_%s" % str(key)] = family_diag[key]
	return report


func _oldest_visible_detail_task_wait_ms() -> int:
	var oldest := 0
	var now_msec := Time.get_ticks_msec()
	for task in _detail_refresh_queue:
		if not bool(task.get("visible_priority", true)):
			continue
		oldest = maxi(oldest, now_msec - int(task.get("enqueued_msec", now_msec)))
	return oldest


func detail_scatter_layer_reports() -> Array:
	var out: Array = []
	for layer in _detail_layers:
		if layer != null and layer.has_method("get_scatter_diagnostics"):
			out.append(layer.get_scatter_diagnostics())
	return out


func _detail_total_instance_budget() -> int:
	if OS.has_feature("mobile"):
		var mobile_high := maxi(0, detail_scatter_mobile_total_instance_budget)
		match _mobile_quality_tier_from_define(_mobile_quality_tier_define):
			0:
				return mini(mobile_high, 5000)
			1:
				return mini(mobile_high, 8000)
			_:
				return mobile_high
	var desktop_high := maxi(0, detail_scatter_desktop_total_instance_budget)
	match visual_quality:
		0:
			return mini(desktop_high, 35000)
		1:
			return mini(desktop_high, 70000)
		_:
			return desktop_high


func _detail_budget_fraction_needs_apply(next_fraction: float) -> bool:
	if _detail_budget_applied_fraction < 0.0:
		return true
	var next_unclamped := next_fraction >= 1.0 - 0.000001
	var applied_unclamped := _detail_budget_applied_fraction >= 1.0 - 0.000001
	if next_unclamped != applied_unclamped:
		return true
	return absf(next_fraction - _detail_budget_applied_fraction) >= DETAIL_BUDGET_FRACTION_EPSILON


func _begin_detail_budget_apply(fraction: float) -> void:
	_detail_budget_apply_fraction = clampf(fraction, 0.0, 1.0)
	_detail_budget_apply_cursor = 0
	_detail_budget_apply_active = not _detail_layers.is_empty()


func _drain_detail_budget_apply(force_complete: bool) -> void:
	if not _detail_budget_apply_active:
		return
	if detail_scatter_family_renderer_enabled and _detail_family_layer != null \
			and is_instance_valid(_detail_family_layer):
		var family_t0 := Time.get_ticks_usec()
		_detail_family_layer.apply_visible_instance_fraction(_detail_budget_apply_fraction)
		_detail_budget_last_apply_ms = float(Time.get_ticks_usec() - family_t0) / 1000.0
		_detail_budget_apply_ms_total += _detail_budget_last_apply_ms
		_detail_budget_apply_count += 1
		_detail_budget_applied_fraction = _detail_budget_apply_fraction
		_detail_budget_apply_active = false
		_detail_budget_apply_cursor = 0
		return
	var layer_budget := _detail_layers.size() if force_complete else \
		maxi(1, detail_scatter_refresh_layers_per_frame)
	var applied_layers := 0
	var started_usec := Time.get_ticks_usec()
	while _detail_budget_apply_cursor < _detail_layers.size() and applied_layers < layer_budget:
		var layer = _detail_layers[_detail_budget_apply_cursor]
		_detail_budget_apply_cursor += 1
		if layer == null or not is_instance_valid(layer) \
				or not layer.has_method("apply_visible_instance_fraction"):
			continue
		layer.apply_visible_instance_fraction(_detail_budget_apply_fraction)
		applied_layers += 1
	var apply_ms := float(Time.get_ticks_usec() - started_usec) / 1000.0
	_detail_budget_last_apply_ms = apply_ms
	_detail_budget_apply_ms_total += apply_ms
	_detail_budget_apply_count += applied_layers
	if _detail_budget_apply_cursor >= _detail_layers.size():
		_detail_budget_applied_fraction = _detail_budget_apply_fraction
		_detail_budget_apply_active = false
		_detail_budget_apply_cursor = 0


func _apply_detail_global_budget(force_complete: bool = false, allow_apply: bool = true) -> void:
	if _detail_layers.is_empty():
		_last_detail_budget_report = {"total_instances": 0, "budget": _detail_total_instance_budget(), "visible_fraction": 1.0}
		_detail_budget_target_fraction = 1.0
		_detail_budget_applied_fraction = 1.0
		_detail_budget_apply_active = false
		_detail_budget_apply_cursor = 0
		_detail_budget_cached_total = 0
		_detail_budget_total_dirty = false
		return
	if force_complete:
		_detail_budget_total_dirty = true
	if _detail_budget_total_dirty:
		var scan_t0 := Time.get_ticks_usec()
		var scanned_total := 0
		if detail_scatter_family_renderer_enabled and _detail_family_layer != null \
				and is_instance_valid(_detail_family_layer):
			scanned_total = int(_detail_family_layer.active_instance_count())
		else:
			for layer in _detail_layers:
				if layer != null and layer.has_method("active_instance_count"):
					scanned_total += int(layer.active_instance_count())
				elif layer != null and layer.has_method("instance_count"):
					scanned_total += int(layer.instance_count())
		_detail_budget_cached_total = scanned_total
		_detail_budget_total_dirty = false
		_detail_budget_total_scan_count += 1
		_detail_budget_last_scan_ms = float(Time.get_ticks_usec() - scan_t0) / 1000.0
	else:
		_detail_budget_last_scan_ms = 0.0
	var total := _detail_budget_cached_total
	var budget := _detail_total_instance_budget()
	var fraction := 1.0
	if budget > 0 and total > budget:
		fraction = float(budget) / float(total)
	_detail_budget_target_fraction = fraction
	if force_complete:
		_begin_detail_budget_apply(fraction)
		_drain_detail_budget_apply(true)
	elif not _detail_budget_apply_active and _detail_budget_fraction_needs_apply(fraction):
		_begin_detail_budget_apply(fraction)
	elif not _detail_budget_apply_active:
		_detail_budget_apply_skip_count += 1
	if allow_apply and _detail_budget_apply_active:
		_drain_detail_budget_apply(false)
	_last_detail_budget_report = {
		"total_instances": total,
		"budget": budget,
		"visible_fraction": fraction,
		"applied_visible_fraction": _detail_budget_applied_fraction,
		"budget_apply_fraction": _detail_budget_apply_fraction,
		"budget_apply_active": _detail_budget_apply_active,
		"budget_apply_cursor": _detail_budget_apply_cursor,
		"budget_apply_count": _detail_budget_apply_count,
		"budget_apply_skip_count": _detail_budget_apply_skip_count,
		"budget_apply_last_ms": _detail_budget_last_apply_ms,
		"budget_apply_ms_total": _detail_budget_apply_ms_total,
		"budget_total_scan_count": _detail_budget_total_scan_count,
		"budget_total_scan_ms": _detail_budget_last_scan_ms,
		"budget_total_dirty": _detail_budget_total_dirty,
		"layer_count": _detail_layers.size(),
	}
	if detail_scatter_rebuild_log_enabled and budget > 0 and total > budget:
		print("[detail_scatter/BUDGET_CLAMP] total_inst=%d budget=%d visible_fraction=%.3f layers=%d" % [
			total,
			budget,
			fraction,
			_detail_layers.size(),
		])


func detail_scatter_budget_report() -> Dictionary:
	return _last_detail_budget_report.duplicate(true)


func _mark_detail_budget_total_dirty() -> void:
	_detail_budget_total_dirty = true


func _log_detail_scatter_rebuild_summary(reason: String) -> void:
	if not detail_scatter_rebuild_log_enabled:
		return
	var reports := detail_scatter_layer_reports()
	if reports.is_empty():
		print("[detail_scatter/REBUILD] reason=%s no_layers" % reason)
		return
	var total_ms := 0.0
	var total_inst := 0
	var total_cand := 0
	var slow: Array = []
	for d in reports:
		var ms := float(d.get("rebuild_ms", 0.0))
		total_ms += ms
		total_inst += int(d.get("instances", 0))
		total_cand += int(d.get("candidates", 0))
		if ms >= detail_scatter_slow_layer_ms:
			slow.append(d)
	slow.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("rebuild_ms", 0.0)) > float(b.get("rebuild_ms", 0.0))
	)
	print("[detail_scatter/REBUILD] reason=%s layers=%d total_rebuild_ms=%.2f total_inst=%d total_cand=%d budget=%s" % [
		reason,
		reports.size(),
		total_ms,
		total_inst,
		total_cand,
		str(_last_detail_budget_report),
	])
	var limit := mini(5, slow.size())
	for i in range(limit):
		var d: Dictionary = slow[i]
		print("  [detail_scatter/TOP%d] name=%s rebuild=%.2fms path=%s inst=%d cand=%d wrap=%d reason=%s" % [
			i + 1,
			str(d.get("name", "")),
			float(d.get("rebuild_ms", 0.0)),
			str(d.get("path", "")),
			int(d.get("instances", 0)),
			int(d.get("candidates", 0)),
			int(d.get("wrap_edge_copies", 0)),
			str(d.get("reason", "")),
		])
	# 可见性现场：实例存在但屏幕无显示时，用每层 probe 区分 节点隐藏 / 可见数
	# 归零 / mesh 缺失 / profile 关闭（只读诊断，不改变状态）。
	for layer in _detail_layers:
		if layer != null and layer.has_method("detail_visibility_probe"):
			print("  [detail_scatter/VIS] %s" % str(layer.detail_visibility_probe()))


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
	if _detail_family_layer != null and is_instance_valid(_detail_family_layer):
		_detail_family_layer.queue_free()
	_detail_family_layer = null
	_detail_family_dirty_chunks.clear()
	for layer in _detail_layers:
		if is_instance_valid(layer):
			layer.queue_free()
	_detail_layers.clear()
	# 层销毁意味着旧世界的 succession 队列全部失效：任务里的 layer 引用虽有
	# is_instance_valid 兜底，但 cell 语义已跨世界失效，必须整体重置（含全链路
	# 在途集合，否则旧世界 cell 会永久屏蔽新世界的重排队）。
	_detail_refresh_queue.clear()
	_detail_refresh_batches.clear()
	_detail_refresh_indices = PackedInt32Array()
	_reset_detail_refresh_plan()
	_scatter_pending_cells = PackedInt32Array()
	_scatter_pending_seen.clear()
	_scatter_requeue_cells.clear()
	_scatter_inflight.clear()
	_scatter_cell_family_masks.clear()
	_scatter_cell_profile_masks.clear()
	_scatter_cell_generations.clear()
	_detail_deferred_chunks.clear()
	_detail_deferred_profile_masks.clear()
	_detail_offscreen_deferred_cells = 0
	_detail_coalesced_cells = 0
	_detail_stale_generation_drops = 0
	_detail_evicted_superchunks = 0
	_detail_next_resident_sweep_msec = 0
	_drain_credit_ms = 0.0
	_detail_budget_target_fraction = 1.0
	_detail_budget_applied_fraction = -1.0
	_detail_budget_apply_fraction = 1.0
	_detail_budget_apply_cursor = 0
	_detail_budget_apply_active = false
	_detail_budget_apply_count = 0
	_detail_budget_apply_skip_count = 0
	_detail_budget_apply_ms_total = 0.0
	_detail_budget_last_apply_ms = 0.0
	_detail_budget_cached_total = 0
	_detail_budget_total_dirty = true
	_detail_budget_total_scan_count = 0
	_detail_budget_last_scan_ms = 0.0
	var profiles := _detail_profiles()
	var veg_tier := _mobile_quality_tier_from_define(_mobile_quality_tier_define)
	for i in range(profiles.size()):
		var prof: Resource = profiles[i]
		var layer := ShrubLayer.new()
		layer.name = _detail_layer_name(prof, i)
		layer.profile = prof
		layer.set_mobile_quality_tier(veg_tier)
		if layer.has_method("set_defer_initial_rebuild"):
			layer.set_defer_initial_rebuild(detail_scatter_family_renderer_enabled)
		if layer.has_method("set_chunked_multimesh_enabled"):
			layer.set_chunked_multimesh_enabled(detail_scatter_chunked_multimesh_enabled, detail_scatter_chunk_size_cells)
		layer.set_world_ext(_world_ext)
		add_child(layer)
		# [cylindrical-earth-daylight] 新层补推昼夜光照所需状态（与地形同源）：
		# 相位/季节驱动晨昏线，axial_tilt 决定季节赤纬，day_night_enabled 为总开关。
		layer.set_season_phase(_season_phase)
		layer.set_day_phase(_day_phase)
		layer.set_axial_tilt_rad(deg_to_rad(axial_tilt_deg))
		layer.set_day_night_enabled(day_night_enabled)
		if layer.has_method("set_tod_debug_sun_position"):
			layer.set_tod_debug_sun_position(_tod_debug_sun_position_enabled, _tod_debug_sun_uv)
		if layer.has_method("set_tod_debug_sun_height_scale"):
			layer.set_tod_debug_sun_height_scale(_tod_debug_sun_height_scale)
		if _tod_valid:
			layer.set_tod(_tod_sun_color, _tod_ambient_color, _tod_night_factor, _tod_exposure)
			if layer.has_method("set_tod_sun_dir"):
				layer.set_tod_sun_dir(_tod_sun_dir)
		layer.set_camera_zoom(_camera_zoom)
		if _camera_view_initialized and layer.has_method("set_camera_view"):
			layer.set_camera_view(_camera_world_rect, _camera_world_center, _camera_zoom)
		layer.set_lod_debug_view(terrain_surface_debug_view == 6)
		_detail_layers.append(layer)
	_detail_family_layer = VegetationFamilyLayerScript.new()
	_detail_family_layer.name = "VegetationFamilyLayer"
	add_child(_detail_family_layer)


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
	if replacing_world and _visual_tile_horizon_baker != null:
		_visual_tile_horizon_baker.cancel()
	_map = map
	_world = world
	# _ready() loads the shader before a generated world exists, so it necessarily
	# selects the legacy variant. Re-select after world injection; setting array
	# uniforms on that legacy shader is ignored and leaves map_index_atlas unbound.
	if is_inside_tree() and _world_quad != null:
		_load_shader()
	if _weather_layer != null and _weather_layer.has_method("set_world_ref"):
		_weather_layer.set_world_ref(_world)  # 帧间插值:weather_lut_prev_tex 源
	# [terrain-horizon-gpu 2026-07-03] map_baker 若登记了 GPU 离屏烘焙，这里在场景树内发起。
	_maybe_bake_terrain_horizon_gpu()
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

## 国界线层。领土变更（country_committed）后由 WorldRuntimeHost 调 rebuild()。
func country_border_layer() -> CountryBorderLayer:
	return _border_layer

## 视野迷雾层。迷雾值本身走 enum_lut.a，本层只负责画云。
func fog_of_war_layer() -> FogOfWarLayer:
	return _fog_layer

## 同时开关迷雾层与主地形的迷雾响应。fog 关时主地形完全恢复改造前的行为
## （灰化与早退都是纯 uniform 分支，关掉即零成本）。
## early_out 是可开关的性能实验：净收益取决于厚云是否真的比被跳过的地形便宜，
## 必须靠 headless perf A/B 决定，默认关。它还要求迷雾层在未探索处输出常量色，
## 因此只有迷雾最低档才真正放行（见 _apply_fog_early_out）。
func set_fog_of_war_enabled(enabled: bool, early_out: bool = false) -> void:
	_fog_enabled = enabled
	_fog_early_out = early_out
	if _fog_layer != null:
		_fog_layer.set_enabled(enabled)
	_push_fog_uniforms()


func is_fog_of_war_enabled() -> bool:
	return _fog_enabled


func _push_fog_uniforms() -> void:
	# 天气屏蔽与主地形灰化共用同一张 enum_lut，只是消费点不同。
	if _weather_layer != null:
		_weather_layer.set_fog_mask(
			_fog_enabled, _world.enum_lut_tex if _world != null else null)
	if _shader_mat == null:
		return
	_shader_mat.set_shader_parameter("fog_gray_enabled", _fog_enabled)
	_shader_mat.set_shader_parameter("fog_early_out_enabled", _effective_fog_early_out())
	_shader_mat.set_shader_parameter("fog_unexplored_color", FogOfWarLayer.UNEXPLORED_COLOR)


## 早退要求迷雾层在未探索处画的是一个常量色 —— 地形被完全盖住，跳过才不可见。
## 迷雾一旦上体积云光照（q1+），颜色随位置/时间变化，早退分支那块常量色会露成
## 死斑。所以请求的 early_out 还要与迷雾层的实际档位取与。
func _effective_fog_early_out() -> bool:
	if not (_fog_enabled and _fog_early_out):
		return false
	return _fog_layer != null and _fog_layer.supports_terrain_early_out()


func _apply_fog_early_out() -> void:
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("fog_early_out_enabled", _effective_fog_early_out())

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
	if _fog_layer != null:
		_fog_layer.set_season_phase(_season_phase)
	_for_each_vegetation_layer(func(layer: ShrubLayer) -> void:
		layer.set_season_phase(_season_phase)
	)
	_sync_family_materials_from_sources()

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
	if _fog_layer != null:
		_fog_layer.set_day_phase(_day_phase)
	_for_each_vegetation_layer(func(layer: ShrubLayer) -> void:
		layer.set_day_phase(_day_phase)
	)
	_sync_family_materials_from_sources()


func set_tod_debug_sun_position(enabled: bool, uv: Vector2) -> void:
	_tod_debug_sun_position_enabled = enabled
	_tod_debug_sun_uv = Vector2(fposmod(uv.x, 1.0), clampf(uv.y, 0.0, 1.0))
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("tod_debug_sun_position_enabled", _tod_debug_sun_position_enabled)
		_shader_mat.set_shader_parameter("tod_debug_sun_uv", _tod_debug_sun_uv)
	if _season_transition_mat != null:
		_season_transition_mat.set_shader_parameter("tod_debug_sun_position_enabled", _tod_debug_sun_position_enabled)
		_season_transition_mat.set_shader_parameter("tod_debug_sun_uv", _tod_debug_sun_uv)
	if _weather_layer != null and _weather_layer.has_method("set_tod_debug_sun_position"):
		_weather_layer.set_tod_debug_sun_position(_tod_debug_sun_position_enabled, _tod_debug_sun_uv)
	if _fog_layer != null:
		_fog_layer.set_tod_debug_sun_position(_tod_debug_sun_position_enabled, _tod_debug_sun_uv)
	_for_each_vegetation_layer(func(layer: ShrubLayer) -> void:
		if layer.has_method("set_tod_debug_sun_position"):
			layer.set_tod_debug_sun_position(_tod_debug_sun_position_enabled, _tod_debug_sun_uv)
	)
	_sync_family_materials_from_sources()


func set_tod_debug_sun_height_scale(v: float) -> void:
	_tod_debug_sun_height_scale = clampf(v, 0.2, 1.5)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("tod_debug_sun_height_scale", _tod_debug_sun_height_scale)
	if _season_transition_mat != null:
		_season_transition_mat.set_shader_parameter("tod_debug_sun_height_scale", _tod_debug_sun_height_scale)
	if _weather_layer != null and _weather_layer.has_method("set_tod_debug_sun_height_scale"):
		_weather_layer.set_tod_debug_sun_height_scale(_tod_debug_sun_height_scale)
	if _fog_layer != null:
		_fog_layer.set_tod_debug_sun_height_scale(_tod_debug_sun_height_scale)
	_for_each_vegetation_layer(func(layer: ShrubLayer) -> void:
		if layer.has_method("set_tod_debug_sun_height_scale"):
			layer.set_tod_debug_sun_height_scale(_tod_debug_sun_height_scale)
	)
	_sync_family_materials_from_sources()

# ─── 任务 1：视觉总开关 setter ─────────────────────────────────────────
#   2) 把对应 uniform 推到 shader（名字与后续任务 shader 分支匹配）；
func set_visual_quality(q: int) -> void:
	visual_quality = clampi(q, 0, 2)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("visual_quality", visual_quality)
	if _weather_layer != null:
		_weather_layer.set_visual_quality(visual_quality)
	if _fog_layer != null:
		_fog_layer.set_visual_quality(visual_quality)
		_apply_fog_early_out()
	_for_each_vegetation_layer(func(layer: ShrubLayer) -> void:
		layer.set_visual_quality(visual_quality)
	)
	if _detail_family_layer != null and is_instance_valid(_detail_family_layer) and _map != null:
		_detail_family_layer.configure(_detail_layers, detail_scatter_family_renderer_enabled)
		if detail_scatter_family_renderer_enabled and _camera_view_initialized:
			_queue_missing_prefetch_detail_chunks()
			_reactivate_deferred_detail_chunks()
	# 画质切换沿用运行期分层下发，避免设置变化再次制造全层同步尖峰。
	_mark_detail_budget_total_dirty()
	_apply_detail_global_budget()


func set_terrain_materials_enabled(enabled: bool) -> void:
	terrain_materials_enabled = enabled
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("terrain_materials_enabled", enabled)


func set_camera_zoom(value: float) -> void:
	var next_zoom := clampf(value, 0.01, 16.0)
	if absf(next_zoom - _camera_zoom) < 0.001:
		return
	_camera_zoom = next_zoom
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("camera_zoom", _camera_zoom)
	if _season_transition_mat != null:
		_season_transition_mat.set_shader_parameter("camera_zoom", _camera_zoom)
	_for_each_vegetation_layer(func(layer: ShrubLayer) -> void:
		layer.set_camera_zoom(_camera_zoom)
	)
	_mark_detail_budget_total_dirty()


func set_camera_view(world_rect: Rect2, center: Vector2, zoom_value: float) -> void:
	var t0_us := Time.get_ticks_usec()
	_camera_world_rect = world_rect
	_camera_world_center = center
	_camera_view_initialized = world_rect.size.x > 0.0 and world_rect.size.y > 0.0
	_camera_zoom = clampf(zoom_value, 0.01, 16.0)
	_for_each_vegetation_layer(func(layer: ShrubLayer) -> void:
		if layer.has_method("set_camera_view"):
			layer.set_camera_view(world_rect, center, _camera_zoom)
	)
	if _detail_family_layer != null and is_instance_valid(_detail_family_layer):
		_detail_family_layer.set_camera_view(world_rect, center, _camera_zoom)
	if detail_scatter_family_renderer_enabled:
		_queue_missing_prefetch_detail_chunks()
	else:
		_detail_render_chunk_count = 0
		_detail_prefetch_chunk_count = 0
	if not detail_scatter_family_renderer_enabled and not _detail_layers.is_empty():
		var probe = _detail_layers[0]
		if probe != null and is_instance_valid(probe) and probe.has_method("get_scatter_diagnostics"):
			var d: Dictionary = probe.get_scatter_diagnostics()
			_detail_render_chunk_count = int(d.get("visible_chunks", 0))
			_detail_prefetch_chunk_count = int(d.get("prefetch_chunks", 0))
	_reactivate_deferred_detail_chunks()
	_mark_detail_budget_total_dirty()
	_detail_visibility_last_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0


func _queue_missing_prefetch_detail_chunks() -> void:
	if not detail_scatter_family_renderer_enabled or _detail_layers.is_empty() or _map == null:
		return
	var probe = _detail_layers[0]
	if probe == null or not is_instance_valid(probe) \
			or not probe.has_method("detail_prefetch_chunk_plan"):
		return
	var plan: Array = probe.detail_prefetch_chunk_plan()
	plan.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var a_cells: PackedInt32Array = a.get("cell_indices", PackedInt32Array())
		var b_cells: PackedInt32Array = b.get("cell_indices", PackedInt32Array())
		var a_pos := _detail_chunk_center_from_cells(a_cells)
		var b_pos := _detail_chunk_center_from_cells(b_cells)
		return a_pos.distance_squared_to(_camera_world_center) \
			< b_pos.distance_squared_to(_camera_world_center)
	)
	_detail_prefetch_chunk_count = plan.size()
	_detail_render_chunk_count = 0
	for chunk in plan:
		var chunk_id := int(chunk.get("chunk_id", -1))
		if chunk_id < 0:
			continue
		if probe.has_method("detail_chunk_is_render_visible") \
				and bool(probe.detail_chunk_is_render_visible(chunk_id)):
			_detail_render_chunk_count += 1
		var resident := true
		for layer in _detail_layers:
			if layer == null or not is_instance_valid(layer) \
					or not layer.has_method("detail_chunk_has_resident_cache") \
					or not bool(layer.detail_chunk_has_resident_cache(chunk_id)):
				resident = false
				break
		if not resident:
			_detail_deferred_chunks[chunk_id] = _detail_all_family_mask()
			_detail_deferred_profile_masks[chunk_id] = (1 << _detail_layers.size()) - 1


func _detail_chunk_center_from_cells(cells: PackedInt32Array) -> Vector2:
	if _map == null or cells.is_empty():
		return Vector2.ZERO
	var sum := Vector2.ZERO
	var count := 0
	for raw_idx in cells:
		var idx := int(raw_idx)
		if idx < 0 or idx >= _map.cell_pos_x_arr.size() or idx >= _map.cell_pos_y_arr.size():
			continue
		sum += Vector2(_map.cell_pos_x_arr[idx], _map.cell_pos_y_arr[idx]) * hex_size
		count += 1
	return sum / float(count) if count > 0 else Vector2.ZERO


func _reactivate_deferred_detail_chunks() -> void:
	if _detail_deferred_chunks.is_empty() or _detail_layers.is_empty():
		return
	var probe = _detail_layers[0]
	if probe == null or not is_instance_valid(probe) \
			or not probe.has_method("detail_chunk_is_in_prefetch") \
			or not probe.has_method("detail_chunk_cells"):
		return
	var resumed := PackedInt32Array()
	for raw_chunk_id in _detail_deferred_chunks.keys():
		var chunk_id := int(raw_chunk_id)
		if not bool(probe.detail_chunk_is_in_prefetch(chunk_id)):
			continue
		var family_mask := int(_detail_deferred_chunks[raw_chunk_id])
		var profile_mask := int(_detail_deferred_profile_masks.get(
			raw_chunk_id, (1 << _detail_layers.size()) - 1))
		var cells: PackedInt32Array = probe.detail_chunk_cells(chunk_id)
		for raw_idx in cells:
			var ci := int(raw_idx)
			_scatter_cell_family_masks[ci] = int(_scatter_cell_family_masks.get(ci, 0)) | family_mask
			_scatter_cell_profile_masks[ci] = int(
				_scatter_cell_profile_masks.get(ci, 0)) | profile_mask
			if _scatter_inflight.has(ci):
				continue
			_scatter_inflight[ci] = true
			resumed.append(ci)
		_detail_deferred_chunks.erase(raw_chunk_id)
		_detail_deferred_profile_masks.erase(raw_chunk_id)
	if resumed.is_empty():
		return
	_enqueue_detail_refresh_batches(_dedup_detail_refresh_indices(resumed))
	if _detail_refresh_queue.is_empty():
		_start_next_detail_refresh_batch()


func _push_overlay_edge_transition_data() -> void:
	var neighbor_tex: Texture2D = (
		_world.terrain_edge_neighbor_tex if _world != null else null
	)
	var distance_tex: Texture2D = (
		_world.terrain_edge_distance_tex if _world != null else null
	)
	if _weather_layer != null:
		_weather_layer.set_edge_transition_data(
			neighbor_tex, distance_tex, terrain_ecotone_width)
	if _fog_layer != null:
		_fog_layer.set_edge_transition_data(
			neighbor_tex, distance_tex, terrain_ecotone_width)


func _push_terrain_horizon_uniforms() -> void:
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("terrain_horizon_strength", terrain_horizon_strength)
		_shader_mat.set_shader_parameter("terrain_horizon_softness", terrain_horizon_softness)
		_shader_mat.set_shader_parameter("terrain_horizon_max_angle", terrain_horizon_max_angle)
		_shader_mat.set_shader_parameter("terrain_horizon_cast_floor", terrain_horizon_cast_floor)
		_shader_mat.set_shader_parameter("terrain_horizon_debug_view", terrain_horizon_debug_view)
		_push_gi_strength_uniforms(_shader_mat)
	# tiled 模式 horizon 在 visual_tiles.horizon（Texture2DArray），不写 world.terrain_horizon_tex。
	# 若仍按 legacy tex!=null 判断，会在 _apply_uniforms 末尾把植被 bound 盖回 false →
	# 直射遮蔽/天空 GI 全关，植株看起来「没光照」。
	var tiled := _visual_tiles_active()
	var horizon_tex: Texture2D = null
	var horizon_bound := false
	if tiled:
		horizon_bound = _world != null and _world.visual_tiles != null \
			and bool(_world.visual_tiles.horizon_ready)
	elif _world != null:
		horizon_tex = _world.terrain_horizon_tex
		horizon_bound = horizon_tex != null
	_for_each_vegetation_layer(func(layer: ShrubLayer) -> void:
		layer.set_terrain_horizon_inputs(horizon_tex, horizon_bound,
			terrain_horizon_strength, terrain_horizon_softness, terrain_horizon_max_angle,
			terrain_horizon_cast_floor, terrain_horizon_debug_view)
		layer.set_terrain_gi_inputs(build_gi_horizon_lut(terrain_horizon_max_angle),
			gi_ao_strength, gi_ao_floor, gi_bent_strength, gi_normal_floor)
	)
	_sync_family_materials_from_sources()


# [terrain-gi 2026-07-31] 4-bit 量化角的解码查表。shader 里 h_n = n/15·max_angle 只有 16 个
# 取值，把 cos²(h) 与可见锥质心方向 m=(h+π/2)/2 的 cos/sin 预先算好推过去，fragment 侧解
# 8 个方向的天空可见度与 bent normal 时就完全没有三角函数调用。
# max_angle 是 uniform（可在场景里调），所以这张表不能做成 shader 常量，必须随之重推。
static func build_gi_horizon_lut(max_angle: float) -> PackedVector3Array:
	var lut := PackedVector3Array()
	lut.resize(16)
	for i in range(16):
		var h: float = float(i) / 15.0 * max_angle
		var m: float = (h + PI * 0.5) * 0.5
		var c: float = cos(h)
		lut[i] = Vector3(c * c, cos(m), sin(m))
	return lut


func _push_gi_strength_uniforms(sm: ShaderMaterial) -> void:
	sm.set_shader_parameter("gi_horizon_lut", build_gi_horizon_lut(terrain_horizon_max_angle))
	sm.set_shader_parameter("gi_lut_bound", true)
	sm.set_shader_parameter("gi_ao_strength", gi_ao_strength)
	sm.set_shader_parameter("gi_ao_floor", gi_ao_floor)
	sm.set_shader_parameter("gi_ao_smoothing", gi_ao_smoothing)
	sm.set_shader_parameter("gi_bent_strength", gi_bent_strength)
	sm.set_shader_parameter("gi_normal_floor", gi_normal_floor)
	sm.set_shader_parameter("gi_bounce_strength", gi_bounce_strength)
	sm.set_shader_parameter("gi_debug_view", gi_debug_view)


# 遮挡源纹理绑定 + 强度参数。gi_bounce_bound 由调用方在 bounce_lut 也就绪后单独置位，
# 因为弹射需要两者同时可用；只有 occluder 而没有 bounce_lut 时应保持档 0/1 行为。
func _push_gi_uniforms(sm: ShaderMaterial, tiled: bool, visual_tiles) -> void:
	_push_gi_strength_uniforms(sm)
	if tiled:
		sm.set_shader_parameter("visual_gi_occluder_tiles", visual_tiles.gi_occluder)
	else:
		sm.set_shader_parameter("gi_occluder_tex", _world.gi_occluder_tex)


# ─── Terrain Horizon GPU 离屏烘焙（plan: terrain-horizon-gpu-bake 2026-07-03） ──────
# map_baker 选 GPU 路径时只在 world 上登记 terrain_horizon_gpu_params；这里用一次性
# SubViewport + canvas shader（res://shaders/bake/terrain_horizon_bake.gdshader）在场景树内
# 并行烘出 8 方向 horizon RGBA8。走引擎材质管线（非 RenderingDevice .glsl），PC/移动端同一
# 路径、规避 compute/SPIR-V 跨平台坑。SubViewport 需一帧渲染，故用 frame_post_draw 单次回读
# （set_map 是同步的、不能 await），回读为 ImageTexture 赋给 world.terrain_horizon_tex 后推 uniform。
const _HORIZON_BAKE_SHADER_PATH := "res://shaders/bake/terrain_horizon_bake.gdshader"
var _horizon_bake_vp: SubViewport = null
var _horizon_bake_world: WorldData = null
var _horizon_bake_waited: int = 0

func _maybe_bake_terrain_horizon_gpu() -> void:
	if _world == null:
		return
	if _visual_tiles_active() and not bool(_world.visual_tiles.horizon_ready):
		_start_visual_tile_horizon_bake(_world)
		return
	if not _world.terrain_horizon_gpu_pending:
		return
	if _world.height_tex == null or _world.hm_size.x <= 0 or _world.hm_size.y <= 0:
		print("[terrain_horizon] GPU bake skipped: height_tex=%s hm_size=%s" % [
			str(_world.height_tex != null), str(_world.hm_size)])
		return
	var params: Dictionary = _world.terrain_horizon_gpu_params
	if params.is_empty():
		return
	_world.terrain_horizon_gpu_pending = false   # 防重入（regenerate 会重新置位）
	print("[terrain_horizon] GPU bake start: hm_size=%s params=%s" % [str(_world.hm_size), str(params)])
	_start_terrain_horizon_bake(_world, params)


func _start_visual_tile_horizon_bake(world: WorldData) -> void:
	if world == null or world.visual_tiles == null or world.visual_tiles.layout == null:
		return
	if _visual_tile_horizon_baker != null:
		_visual_tile_horizon_baker.cancel()
	var tiles = world.visual_tiles
	var generation_id := int(tiles.layout.generation_id)
	_visual_tile_horizon_baker = VisualTileHorizonBakerScript.new()
	_visual_tile_horizon_world = world
	_visual_tile_horizon_baker.completed.connect(
		func(success: bool, report: Dictionary) -> void:
			_on_visual_tile_horizon_completed(world, generation_id, success, report),
		CONNECT_ONE_SHOT)
	var params := world.terrain_horizon_gpu_params.duplicate(true)
	params["max_iterations"] = int(ProjectSettings.get_setting(
		"project_keynes/rendering/map_tiles/horizon_max_iterations", 2048))
	world.terrain_horizon_gpu_pending = false
	print("[visual-tiles/horizon] compute start generation=%d layers=%d" % [
		generation_id, int(tiles.layout.layer_count)])
	_visual_tile_horizon_baker.start(tiles, generation_id, params)


func _on_visual_tile_horizon_completed(world: WorldData, generation_id: int,
		success: bool, report: Dictionary) -> void:
	if world == null or world.visual_tiles == null \
			or int(world.visual_tiles.layout.generation_id) != generation_id:
		return
	if success:
		_publish_visual_tile_horizon(world, report)
		return
	push_warning("[visual-tiles/horizon] compute failed (%s); using native baseline resample" %
		String(report.get("reason", "unknown")))
	_run_visual_tile_horizon_fallback(world, generation_id, report)


func _run_visual_tile_horizon_fallback(world: WorldData, generation_id: int,
		compute_report: Dictionary) -> void:
	var tiles = world.visual_tiles
	if _world_ext == null or not _world_ext.has_method("encode_bake_horizon_tex_data") \
			or not _world_ext.has_method("run_resample_visual_horizon_layer_pass"):
		_record_visual_tile_horizon_failure(world, "native_fallback_method_missing", compute_report)
		return
	var params := world.terrain_horizon_gpu_params
	var expected_source_bytes: int = world.hm_size.x * world.hm_size.y * 4
	var source_data := PackedByteArray()
	# [terrain-gi 2026-07-31] 全局遮挡源图。它与 horizon 独立降级：C++ 未 rebuild 或
	# map_index 不可用时 occluder_source 保持为空，AO 与 bent normal 仍然正常工作
	# （它们只需要 horizon），只有弹射项关闭。
	var occluder_source := PackedByteArray()
	var source_path := "existing_global_horizon"
	var source_ms := 0.0
	if world.terrain_horizon_tex != null:
		var source_image := world.terrain_horizon_tex.get_image()
		if source_image != null:
			if source_image.get_format() != Image.FORMAT_RGBA8:
				source_image.convert(Image.FORMAT_RGBA8)
			source_data = source_image.get_data()
	if world.gi_occluder_tex != null:
		var occ_image := world.gi_occluder_tex.get_image()
		if occ_image != null:
			if occ_image.get_format() != Image.FORMAT_RGBA8:
				occ_image.convert(Image.FORMAT_RGBA8)
			occluder_source = occ_image.get_data()
	if source_data.size() != expected_source_bytes:
		source_path = "native_global_horizon"
		var horizon_knobs := {
			"height_buffer": world.height_buffer,
			"width": world.hm_size.x,
			"height": world.hm_size.y,
			"world_size_x": world.world_bounds.size.x,
			"world_size_y": world.world_bounds.size.y,
			"wrap_x": world.wrap_period_x > 0.0001,
			"wrap_period_x": world.wrap_period_x,
			"steps": int(params.get("steps", 128)),
			"step_px": float(params.get("step_px", 8.0)),
			"step_growth": float(params.get("step_growth", 0.35)),
			"lowpass_radius": int(params.get("lowpass_radius", 1)),
			"max_horizon_angle": float(params.get("max_horizon_angle", 1.309)),
			"bias": float(params.get("bias", 0.004)),
			"height_world_scale": float(params.get("height_world_scale", 176.0)),
			"sea_level": clampf(float(params.get("sea_level", world.sea_level)), 0.0, 1.0),
		}
		var map_index_data := _global_map_index_bytes(world)
		if map_index_data.size() == expected_source_bytes:
			horizon_knobs["emit_occluder_cells"] = true
			horizon_knobs["map_index_data"] = map_index_data
		var source_result: Dictionary = _world_ext.encode_bake_horizon_tex_data(horizon_knobs)
		if bool(source_result.get("fallback", true)):
			_record_visual_tile_horizon_failure(world,
				"baseline_horizon_failed:%s" % String(source_result.get("reason", "unknown")),
				compute_report)
			return
		source_data = source_result.get("data", PackedByteArray())
		source_ms = float(source_result.get("elapsed_ms", 0.0))
		occluder_source = source_result.get("occluder_data", PackedByteArray())
		if source_data.size() == expected_source_bytes:
			world.terrain_horizon_tex = ImageTexture.create_from_image(Image.create_from_data(
				world.hm_size.x, world.hm_size.y, false, Image.FORMAT_RGBA8, source_data))
		if occluder_source.size() == expected_source_bytes:
			world.gi_occluder_tex = ImageTexture.create_from_image(Image.create_from_data(
				world.hm_size.x, world.hm_size.y, false, Image.FORMAT_RGBA8, occluder_source))
	if source_data.size() != expected_source_bytes:
		_record_visual_tile_horizon_failure(world, "baseline_horizon_size_mismatch", compute_report)
		return
	var occluder_available: bool = occluder_source.size() == expected_source_bytes

	var layout = tiles.layout
	var texel_world: Vector2 = layout.visual_domain.size / Vector2(layout.logical_size)
	var layer_reports: Array[Dictionary] = []
	var fallback_t0 := Time.get_ticks_usec()
	for layer_id in range(layout.layer_count):
		if _world != world or world.visual_tiles != tiles \
				or int(layout.generation_id) != generation_id:
			return
		var tile_xy := Vector2i(layer_id % layout.grid_size.x,
			layer_id / layout.grid_size.x)
		var physical_origin: Vector2 = layout.visual_domain.position + Vector2(
			tile_xy.x * layout.interior_size.x - layout.gutter_px,
			tile_xy.y * layout.interior_size.y - layout.gutter_px) * texel_world
		var resample_knobs := {
			"generation_id": generation_id,
			"layer_id": layer_id,
			"source_data": source_data,
			"source_width": world.hm_size.x,
			"source_height": world.hm_size.y,
			"source_origin_x": world.world_bounds.position.x,
			"source_origin_y": world.world_bounds.position.y,
			"source_size_x": world.world_bounds.size.x,
			"source_size_y": world.world_bounds.size.y,
			"width": layout.layer_size.x,
			"height": layout.layer_size.y,
			"origin_x": physical_origin.x,
			"origin_y": physical_origin.y,
			"size_x": layout.layer_size.x * texel_world.x,
			"size_y": layout.layer_size.y * texel_world.y,
			"wrap_period_x": layout.wrap_period_x,
		}
		var result: Dictionary = _world_ext.run_resample_visual_horizon_layer_pass(resample_knobs)
		if bool(result.get("fallback", true)) or int(result.get("generation_id", -1)) != generation_id \
				or not tiles.upload_horizon_layer(layer_id,
					result.get("data", PackedByteArray())):
			_record_visual_tile_horizon_failure(world,
				"resample_layer_failed:%d:%s" % [layer_id, String(result.get("reason", "upload"))],
				compute_report)
			return
		# 遮挡源图与 horizon 完全同构（RGBA8、同尺寸、必须 NEAREST），因此直接复用同一个
		# resample pass，只换 source_data。任一层失败就整体放弃弹射，但不影响 horizon 发布。
		if occluder_available:
			var occ_knobs := resample_knobs.duplicate()
			occ_knobs["source_data"] = occluder_source
			var occ_result: Dictionary = _world_ext.run_resample_visual_horizon_layer_pass(occ_knobs)
			if bool(occ_result.get("fallback", true)) \
					or int(occ_result.get("generation_id", -1)) != generation_id \
					or not tiles.upload_gi_occluder_layer(layer_id,
						occ_result.get("data", PackedByteArray())):
				occluder_available = false
				push_warning("[visual-tiles/gi] occluder resample failed at layer %d; bounce disabled"
					% layer_id)
		layer_reports.append({
			"layer": layer_id,
			"elapsed_ms": float(result.get("elapsed_ms", 0.0)),
			"hash": result.get("hash", 0),
		})
		var tree := Engine.get_main_loop() as SceneTree
		if tree != null:
			await tree.process_frame
	_publish_visual_tile_horizon(world, {
		"ok": true,
		"path": "baseline_horizon_resample",
		"source_path": source_path,
		"source_ms": source_ms,
		"layers": layer_reports,
		"gi_occluder_ok": occluder_available,
		"compute_failure": compute_report,
		"total_ms": float(Time.get_ticks_usec() - fallback_t0) / 1000.0,
	})


# [terrain-gi 2026-07-31] legacy 全局 map_index（RGBA8，G/B=cell.index 低/高字节）的字节视图，
# 供 C++ 全局 horizon pass 顺带产出遮挡源 cell。拿不到就返回空数组，调用方据此关闭弹射。
func _global_map_index_bytes(world: WorldData) -> PackedByteArray:
	if world == null or world.enum_atlas_tex == null:
		return PackedByteArray()
	var image := world.enum_atlas_tex.get_image()
	if image == null:
		return PackedByteArray()
	if image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)
	return image.get_data()


func _publish_visual_tile_horizon(world: WorldData, report: Dictionary) -> void:
	if world == null or world.visual_tiles == null:
		return
	world.visual_tiles.horizon_ready = true
	# 弹射独立于 AO 降级：occluder 缺失只关闭档 2，档 0/1 仍由 horizon 驱动。
	world.visual_tiles.gi_occluder_ready = bool(report.get("gi_occluder_ok", false))
	world.visual_tiles.bake_report["horizon_path"] = report.get("path", "unknown")
	world.visual_tiles.bake_report["horizon"] = report
	if _world == world:
		_apply_uniforms()
	print("[visual-tiles/horizon] published %s" % JSON.stringify(report))


func _record_visual_tile_horizon_failure(world: WorldData, reason: String,
		compute_report: Dictionary) -> void:
	if world != null and world.visual_tiles != null:
		world.visual_tiles.horizon_ready = false
		world.visual_tiles.gi_occluder_ready = false
		world.visual_tiles.bake_report["horizon_path"] = "neutral_failed"
		world.visual_tiles.bake_report["horizon"] = {
			"ok": false,
			"reason": reason,
			"compute_failure": compute_report,
		}
	push_warning("[visual-tiles/horizon] fallback failed: %s" % reason)

func _start_terrain_horizon_bake(world: WorldData, params: Dictionary) -> void:
	var shader: Shader = load(_HORIZON_BAKE_SHADER_PATH)
	if shader == null:
		push_warning("[terrain_horizon] GPU bake shader missing (%s); no cast shadow this world." % _HORIZON_BAKE_SHADER_PATH)
		return
	# 清理上一次遗留的烘焙 viewport（快速连续 regenerate）。
	_dispose_horizon_bake_vp()

	var size: Vector2i = world.hm_size
	var vp := SubViewport.new()
	vp.size = size
	vp.disable_3d = true
	# transparent_bg=true 关键：A 通道承载方向 6/7（S/SE）的打包数据，非透明度。若 false，
	# viewport 会把 alpha 强制为不透明 255 → S/SE 方向 horizon 恒为 max（15），阴影误判。
	# 配合 shader 的 blend_disabled（不做 alpha 预乘/混合），get_image 回读得到原样 RGBA 字节。
	vp.transparent_bg = true
	vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE

	var rect := ColorRect.new()
	rect.position = Vector2.ZERO
	rect.size = Vector2(size)
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("height_tex", world.height_tex)
	mat.set_shader_parameter("tex_dims", Vector2(size))
	mat.set_shader_parameter("steps", int(params.get("steps", 128)))
	mat.set_shader_parameter("step_px", float(params.get("step_px", 8.0)))
	mat.set_shader_parameter("step_growth", float(params.get("step_growth", 0.35)))
	mat.set_shader_parameter("lowpass_radius", int(params.get("lowpass_radius", 1)))
	mat.set_shader_parameter("max_horizon_angle", float(params.get("max_horizon_angle", 1.309)))
	mat.set_shader_parameter("bias", float(params.get("bias", 0.004)))
	mat.set_shader_parameter("height_world_scale", float(params.get("height_world_scale", 176.0)))
	mat.set_shader_parameter("sea_level", clampf(float(params.get("sea_level", world.sea_level)), 0.0, 1.0))
	mat.set_shader_parameter("texel_x", float(params.get("texel_x", 1.0)))
	mat.set_shader_parameter("texel_y", float(params.get("texel_y", 1.0)))
	# 真正经度周期：柱状地图 x 环绕按此折叠，与运行期 wrap_map_uv 对齐，接缝无缝。
	mat.set_shader_parameter("wrap_period_x", float(params.get("wrap_period_x", 0.0)))
	rect.material = mat
	vp.add_child(rect)
	add_child(vp)

	_horizon_bake_vp = vp
	_horizon_bake_world = world
	_horizon_bake_waited = 0
	# UPDATE_ONCE 的 viewport 需一次完整绘制才有内容；用 frame_post_draw 单次回读。
	RenderingServer.frame_post_draw.connect(_on_terrain_horizon_frame_drawn, CONNECT_ONE_SHOT)

func _on_terrain_horizon_frame_drawn() -> void:
	if _horizon_bake_vp == null or not is_instance_valid(_horizon_bake_vp):
		_dispose_horizon_bake_vp()
		return
	# 时序保险：确保 SubViewport 至少经过一次完整绘制再回读（避免 UPDATE_ONCE 首帧时序空读）。
	if _horizon_bake_waited < 1:
		_horizon_bake_waited += 1
		RenderingServer.frame_post_draw.connect(_on_terrain_horizon_frame_drawn, CONNECT_ONE_SHOT)
		return
	var vtex: ViewportTexture = _horizon_bake_vp.get_texture()
	var img: Image = vtex.get_image() if vtex != null else null
	if img == null:
		push_warning("[terrain_horizon] GPU bake readback returned null image; no cast shadow this world.")
		_dispose_horizon_bake_vp()
		return
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	# 诊断：中心 + 一个偏移像素的字节，全 0 说明 vp 未渲染或采样坐标错。
	var wx: int = img.get_width()
	var hy: int = img.get_height()
	var mid: Color = img.get_pixel(wx / 2, hy / 2)
	var q1: Color = img.get_pixel(mini(wx / 3, wx - 1), mini(hy / 3, hy - 1))
	print("[terrain_horizon] GPU readback %dx%d fmt=%d mid(rgba*255)=[%d,%d,%d,%d] q=[%d,%d,%d,%d]" % [
		wx, hy, img.get_format(),
		int(round(mid.r * 255.0)), int(round(mid.g * 255.0)), int(round(mid.b * 255.0)), int(round(mid.a * 255.0)),
		int(round(q1.r * 255.0)), int(round(q1.g * 255.0)), int(round(q1.b * 255.0)), int(round(q1.a * 255.0))])
	var tex := ImageTexture.create_from_image(img)
	# 只回填当初发起烘焙的那个 world（避免 regenerate 竞态把旧图写到新 world）。
	if _horizon_bake_world != null:
		_horizon_bake_world.terrain_horizon_tex = tex
	# 关键修复：延迟回读晚于生成期 _apply_uniforms，必须把纹理显式补推给主 shader，否则主地图
	# 仍持 null → terrain_horizon_tex_bound=false → 运行期 terrain_horizon_direct_visibility 直接
	# return 1.0（无阴影）。_push_terrain_horizon_uniforms 只推标量 + 植被层，不含主 shader tex。
	var applied := false
	if _world == _horizon_bake_world and _shader_mat != null:
		_shader_mat.set_shader_parameter("terrain_horizon_tex", tex)
		_shader_mat.set_shader_parameter("terrain_horizon_tex_bound", true)
		applied = true
	if _world == _horizon_bake_world:
		_push_terrain_horizon_uniforms()   # 同步植被层的 horizon 输入
	print("[terrain_horizon] GPU bake applied to main shader=%s (strength=%.2f)" % [str(applied), terrain_horizon_strength])
	_dispose_horizon_bake_vp()

func _dispose_horizon_bake_vp() -> void:
	if _horizon_bake_vp != null and is_instance_valid(_horizon_bake_vp):
		_horizon_bake_vp.queue_free()
	_horizon_bake_vp = null
	_horizon_bake_world = null


func set_terrain_horizon_strength(v: float) -> void:
	terrain_horizon_strength = v


func set_terrain_horizon_softness(v: float) -> void:
	terrain_horizon_softness = v


func set_terrain_horizon_max_angle(v: float) -> void:
	terrain_horizon_max_angle = v


func set_terrain_horizon_cast_floor(v: float) -> void:
	terrain_horizon_cast_floor = v


func set_terrain_horizon_debug_view(v: int) -> void:
	terrain_horizon_debug_view = v


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

func set_temperature_visual_strength(v: float) -> void:
	temperature_visual_strength = clampf(v, 0.0, 1.5)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("temperature_visual_strength", temperature_visual_strength)

func set_moisture_visual_strength(v: float) -> void:
	moisture_visual_strength = clampf(v, 0.0, 1.5)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("moisture_visual_strength", moisture_visual_strength)

func set_vitality_visual_strength(v: float) -> void:
	vitality_visual_strength = clampf(v, 0.0, 1.5)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("vitality_visual_strength", vitality_visual_strength)

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
	if _fog_layer != null:
		_fog_layer.set_day_night_enabled(day_night_enabled)
	# [cylindrical-earth-daylight] 植被/点缀层昼夜总开关随地形同步（关闭=永昼）。
	_for_each_vegetation_layer(func(layer: ShrubLayer) -> void:
		layer.set_day_night_enabled(day_night_enabled)
	)
	_sync_family_materials_from_sources()

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
	_tod_sun_dir = profile.sun_dir.normalized()
	_tod_valid = true
	_for_each_vegetation_layer(func(layer: ShrubLayer) -> void:
		layer.set_tod(_tod_sun_color, _tod_ambient_color, _tod_night_factor, _tod_exposure)
		if layer.has_method("set_tod_sun_dir"):
			layer.set_tod_sun_dir(_tod_sun_dir)
	)
	_sync_family_materials_from_sources()

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

# [parallax-rain] 俯视雨幕参数 setter
func set_camera_pitch_deg(deg: float) -> void:
	camera_pitch_deg = clampf(deg, 0.0, 90.0)
	_camera_pitch = deg_to_rad(camera_pitch_deg)
	if _weather_layer != null and _weather_layer.has_method("set_camera_pitch"):
		_weather_layer.set_camera_pitch(_camera_pitch)

func set_wind(dir: Vector2, strength: float) -> void:
	wind_dir = dir
	wind_strength = clampf(strength, -1.0, 1.0)
	_wind_dir = dir.normalized() if dir.length_squared() > 0.0001 else Vector2(0.3, 1.0)
	_wind_strength = wind_strength
	if _weather_layer != null and _weather_layer.has_method("set_wind"):
		_weather_layer.set_wind(_wind_dir, _wind_strength)

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
		_mark_detail_budget_total_dirty()
		return

	_world_quad.mesh = _build_world_quad_mesh(_world.world_bounds, _wrap_period_x())
	# 防御性：若 set_world_ext 尚未注入，尝试从已注入的 MapBaker 取 C++ ext。
	if _world_ext == null and _map_baker != null and "_world_ext" in _map_baker:
		set_world_ext(_map_baker._world_ext)
	_for_each_vegetation_layer(func(layer: ShrubLayer) -> void:
		layer.set_world_ext(_world_ext)
		if layer.has_method("set_defer_initial_rebuild"):
			layer.set_defer_initial_rebuild(detail_scatter_family_renderer_enabled)
		if layer.has_method("set_chunked_multimesh_enabled"):
			layer.set_chunked_multimesh_enabled(detail_scatter_chunked_multimesh_enabled, detail_scatter_chunk_size_cells)
		layer.setup(_map, _world, _world.world_bounds, hex_size, visual_quality)
		if _camera_view_initialized and layer.has_method("set_camera_view"):
			layer.set_camera_view(_camera_world_rect, _camera_world_center, _camera_zoom)
	)
	if _detail_family_layer != null and is_instance_valid(_detail_family_layer):
		_detail_family_layer.configure(_detail_layers, detail_scatter_family_renderer_enabled)
		if _camera_view_initialized:
			_detail_family_layer.set_camera_view(_camera_world_rect, _camera_world_center, _camera_zoom)
	if detail_scatter_family_renderer_enabled and _camera_view_initialized:
		_queue_missing_prefetch_detail_chunks()
		_reactivate_deferred_detail_chunks()
	# 世界重建属于加载边界，可一次性完成预算同步；运行期 succession 则按层切片。
	_apply_detail_global_budget(true)
	_log_detail_scatter_rebuild_summary("renderer_rebuild")
	if _shader_mat == null:
		return
	_apply_uniforms()

func _wrap_period_x() -> float:
	if _map == null:
		return 0.0
	return HexUtils.wrap_period_x(_map.width, hex_size)

func _build_world_quad_mesh(bounds: Rect2, wrap_period_x: float = 0.0) -> Mesh:
	var p := bounds.position
	var s := bounds.size
	if wrap_period_x > 0.0001:
		p.x = 0.0
		s.x = wrap_period_x
	var verts := PackedVector2Array()
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
		indices.append_array(PackedInt32Array([base, base + 1, base + 2, base, base + 2, base + 3]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

func _push_visual_tile_layout_uniforms(material: ShaderMaterial, layout) -> void:
	material.set_shader_parameter("visual_domain_origin", layout.visual_domain.position)
	material.set_shader_parameter("visual_domain_size", layout.visual_domain.size)
	material.set_shader_parameter("visual_grid_size", Vector2(layout.grid_size))
	material.set_shader_parameter("visual_interior_size", Vector2(layout.interior_size))
	material.set_shader_parameter("visual_layer_size", Vector2(layout.layer_size))
	material.set_shader_parameter("visual_logical_resolution", Vector2(layout.logical_size))
	material.set_shader_parameter("visual_gutter_px", float(layout.gutter_px))


func _apply_uniforms() -> void:
	var sm := _shader_mat
	var bounds := _world.world_bounds
	var tiled := _visual_tiles_active()
	var visual_tiles = _world.visual_tiles if tiled else null

	# 主地图只保留 height/enum + cell-index LUT + 共享 noise_tex。
	if tiled:
		sm.set_shader_parameter("visual_height_tiles", visual_tiles.height)
		sm.set_shader_parameter("visual_terrain_normal_tiles", visual_tiles.terrain_normal)
		sm.set_shader_parameter("visual_horizon_tiles", visual_tiles.horizon)
		sm.set_shader_parameter("visual_map_index_tiles", visual_tiles.map_index)
		sm.set_shader_parameter("visual_flow_tiles", visual_tiles.flow)
		sm.set_shader_parameter("visual_water_depth_tiles", visual_tiles.water_depth)
		sm.set_shader_parameter("visual_terrain_detail_tiles", visual_tiles.terrain_detail)
		sm.set_shader_parameter("visual_edge_neighbor_tiles", visual_tiles.edge_neighbor)
		sm.set_shader_parameter("visual_edge_distance_tiles", visual_tiles.edge_distance)
		_push_visual_tile_layout_uniforms(sm, visual_tiles.layout)
	else:
		sm.set_shader_parameter("height_tex", _world.height_tex)
	# [terrain-normal-bake 2026-06-25] 总体地形法线贴图（粗法线）。绑定后 shader 用它做宏观山脉
	# 走向；未绑定时 terrain_normal_tex_bound=false，shader 回退到运行期宽半径 4-tap。
	if not tiled:
		sm.set_shader_parameter("terrain_normal_tex", _world.terrain_normal_tex)
	sm.set_shader_parameter("terrain_normal_tex_bound",
		visual_tiles.terrain_normal != null if tiled else _world.terrain_normal_tex != null)
	# [terrain-horizon 2026-07-03] 8 方向 horizon angle：运行期只遮蔽直射光；未绑定/低档自动回退。
	# [terrain-gi 2026-07-31] 同一张图还派生天空可见度(AO)/bent normal/弹射；见 _push_gi_uniforms。
	if not tiled:
		sm.set_shader_parameter("terrain_horizon_tex", _world.terrain_horizon_tex)
	sm.set_shader_parameter("terrain_horizon_tex_bound",
		bool(visual_tiles.horizon_ready) if tiled else _world.terrain_horizon_tex != null)
	_push_gi_uniforms(sm, tiled, visual_tiles)
	if not tiled:
		sm.set_shader_parameter("map_index_atlas", _world.enum_atlas_tex)
	# [river-render-restore 2026-06-19] 河流 SDF 纹理重新接回主地图 shader（flow 视觉层）。
	if not tiled:
		sm.set_shader_parameter("flow_tex", _world.flow_tex)
	# [water-depth-tex 2026-06-26] 海/湖统一水深 R8：绑定后 shader 每水像素 1 次采样取代旧"海洋 5×5
	# height 邻域 + 湖泊 16× biome-atlas 多半径"两套深浅估算；未绑定时 has_water_depth_tex=false →
	# water_pipeline 回退旧逐邻域算法。
	if not tiled:
		sm.set_shader_parameter("water_depth_tex", _world.water_depth_tex)
	sm.set_shader_parameter("has_water_depth_tex",
		visual_tiles.water_depth != null if tiled else _world.water_depth_tex != null)
	# [terrain-detail-bake 2026-07-05] 静态 biome 细节调制：移动端中/高档和桌面中档用单次采样替代多噪声。
	if not tiled:
		sm.set_shader_parameter("terrain_detail_tex", _world.terrain_detail_tex)
	sm.set_shader_parameter("has_terrain_detail_tex",
		visual_tiles.terrain_detail != null if tiled else _world.terrain_detail_tex != null)
	var edge_data_ready := (
		_world.terrain_edge_neighbor_tex != null
		and _world.terrain_edge_distance_tex != null
	)
	if not tiled:
		sm.set_shader_parameter("terrain_edge_neighbor_tex", _world.terrain_edge_neighbor_tex)
		sm.set_shader_parameter("terrain_edge_distance_tex", _world.terrain_edge_distance_tex)
	sm.set_shader_parameter("has_terrain_edge_data", true if tiled else edge_data_ready)
	sm.set_shader_parameter("terrain_ecotone_width", terrain_ecotone_width)
	sm.set_shader_parameter("terrain_ecotone_noise", terrain_ecotone_noise)
	# [terrain-material-tiles] The array is shared by all maps and is valid for
	# both legacy and VisualTileSet variants. Shader-side quality gating keeps
	# MID/LOW and failed allocation on the existing detail path.
	sm.set_shader_parameter("terrain_material_tex", _world.terrain_material_tex)
	sm.set_shader_parameter("terrain_material_tex_bound", _world.terrain_material_tex_bound)
	sm.set_shader_parameter("terrain_materials_enabled", terrain_materials_enabled)
	# [terrain-material-tiles 2026-08-01d] 128 世界单位/张（5.8 hex）下特征尺度为亚 hex 级，
	# 常用 zoom 1-2 全部命中 mip 2-3、颗粒被预滤波抹平；384（17.5 hex/张）让 z=2 命中 mip≈0。
	# [terrain-material-tiles 2026-08-01e] 四参数已提为 @export（见文件头），此处读属性值。
	sm.set_shader_parameter("terrain_material_world_size", terrain_material_world_size)
	sm.set_shader_parameter("terrain_material_albedo_strength", terrain_material_albedo_strength)
	sm.set_shader_parameter("terrain_material_normal_strength", terrain_material_normal_strength)
	sm.set_shader_parameter("terrain_material_roughness_strength", terrain_material_roughness_strength)
	sm.set_shader_parameter("terrain_micro_tex", TERRAIN_MICRO_TEXTURE)
	sm.set_shader_parameter("has_terrain_micro_tex", TERRAIN_MICRO_TEXTURE != null)
	sm.set_shader_parameter("camera_zoom", _camera_zoom)
	sm.set_shader_parameter("terrain_surface_debug_view", terrain_surface_debug_view)
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
	# [terrain-gi 档 2] 弹射代表色 LUT：与 enum/dyn/eco 同一 lut_dims 网格、同一日刷节奏。
	sm.set_shader_parameter("bounce_lut", _world.bounce_lut_tex)
	sm.set_shader_parameter("gi_bounce_bound", _world.bounce_lut_tex != null
		and (visual_tiles.gi_occluder_ready if tiled else _world.gi_occluder_tex != null))
	_for_each_vegetation_layer(func(layer: ShrubLayer) -> void:
		layer.set_world_material_inputs(_world, bounds, _indirect_ready)
	)
	_sync_family_materials_from_sources()

	sm.set_shader_parameter("world_origin", bounds.position)
	sm.set_shader_parameter("world_size", bounds.size)
	sm.set_shader_parameter("wrap_origin_x", 0.0)
	sm.set_shader_parameter("wrap_period_x", _wrap_period_x())
	var visual_resolution := Vector2(visual_tiles.layout.logical_size) if tiled \
		else Vector2(_world.hm_size.x, _world.hm_size.y)
	sm.set_shader_parameter("hm_resolution", visual_resolution)
	sm.set_shader_parameter("derived_resolution", visual_resolution if tiled \
		else Vector2(_world.derived_size.x, _world.derived_size.y))
	sm.set_shader_parameter("visual_reference_resolution",
		visual_resolution)
	sm.set_shader_parameter("sea_level", _world.sea_level)

	sm.set_shader_parameter("season_phase", _season_phase)
	sm.set_shader_parameter("climate_anomaly", _climate_anomaly)
	sm.set_shader_parameter("world_time", _world_time)
	# 任务 2：把当前 day_phase 同步到新创建的材质上
	sm.set_shader_parameter("day_phase", _day_phase)
	sm.set_shader_parameter("tod_debug_sun_position_enabled", _tod_debug_sun_position_enabled)
	sm.set_shader_parameter("tod_debug_sun_uv", _tod_debug_sun_uv)
	sm.set_shader_parameter("tod_debug_sun_height_scale", _tod_debug_sun_height_scale)
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
	sm.set_shader_parameter("temperature_visual_strength", temperature_visual_strength)
	sm.set_shader_parameter("moisture_visual_strength", moisture_visual_strength)
	sm.set_shader_parameter("vitality_visual_strength", vitality_visual_strength)
	sm.set_shader_parameter("ecology_visual_quality", ecology_visual_quality)
	_push_terrain_horizon_uniforms()
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
	# 波浪可读性 / 细节法线初值（材质创建后补推；之后由内联 setter 实时刷新）
	sm.set_shader_parameter("water_wave_shade_strength", water_wave_shade_strength)
	sm.set_shader_parameter("water_wave_patch_strength", water_wave_patch_strength)
	sm.set_shader_parameter("water_wave_patch_scale", water_wave_patch_scale)
	sm.set_shader_parameter("water_base_normal_strength", water_base_normal_strength)
	sm.set_shader_parameter("water_base_normal_scale", water_base_normal_scale)
	sm.set_shader_parameter("water_detail_normal_strength", water_detail_normal_strength)
	sm.set_shader_parameter("water_detail_normal_scale", water_detail_normal_scale)
	sm.set_shader_parameter("water_detail_normal_warp", water_detail_normal_warp)
	sm.set_shader_parameter("water_sss_strength", water_sss_strength)

	# 挂上 enum_atlas 当海陆判断、noise_tex 给 weather overlay shader 复用
	if _weather_layer != null:
		_weather_layer.set_visual_tiles(_world.visual_tiles if tiled else null)
		_weather_layer.setup(bounds, _world.enum_atlas_tex, _world.noise_tex, hex_size, _world.weather_lut_tex, _world.lut_dims, _wrap_period_x(), _map)
		# [cylindrical-earth-daylight] 云光照真源相位：与 ShrubLayer spawn 同套，setup 后补推一次，
		# 之后由 set_day_phase / set_season_phase 增量刷新（晨昏线随时间扫过）。
		_weather_layer.set_season_phase(_season_phase)
		_weather_layer.set_day_phase(_day_phase)
		_weather_layer.set_axial_tilt_rad(deg_to_rad(axial_tilt_deg))
		if _weather_layer.has_method("set_tod_debug_sun_position"):
			_weather_layer.set_tod_debug_sun_position(_tod_debug_sun_position_enabled, _tod_debug_sun_uv)
		if _weather_layer.has_method("set_tod_debug_sun_height_scale"):
			_weather_layer.set_tod_debug_sun_height_scale(_tod_debug_sun_height_scale)
		_weather_layer.set_weather_field_texture(null)
		_weather_layer.set_vector_atlas_texture(null)
		_weather_layer.set_weather_strength(weather_strength)
		# [parallax-rain] 俯视雨幕默认参数（可被外部 set_camera_pitch 覆盖）
		_weather_layer.set_camera_pitch(_camera_pitch)
		_weather_layer.set_wind(_wind_dir, _wind_strength)
	if _border_layer != null:
		_border_layer.set_hex_size(hex_size)
		_border_layer.set_horizontal_wrap(_wrap_period_x())
	if _fog_layer != null:
		_fog_layer.set_visual_tiles(_world.visual_tiles if tiled else null)
		_fog_layer.setup(bounds, _world.enum_atlas_tex, _world.lut_dims, hex_size, _wrap_period_x())
		_fog_layer.set_enum_lut_texture(_world.enum_lut_tex)
		# [cylindrical-earth-daylight] 迷雾云的 TOD 光照与天气云同源，setup 后补推
		# 一次相位，之后由 set_day_phase / set_season_phase 增量刷新。
		_fog_layer.set_season_phase(_season_phase)
		_fog_layer.set_day_phase(_day_phase)
		_fog_layer.set_axial_tilt_rad(deg_to_rad(axial_tilt_deg))
		_fog_layer.set_day_night_enabled(day_night_enabled)
		_fog_layer.set_tod_debug_sun_position(_tod_debug_sun_position_enabled, _tod_debug_sun_uv)
		_fog_layer.set_tod_debug_sun_height_scale(_tod_debug_sun_height_scale)
		_fog_layer.set_visual_quality(visual_quality)
		_fog_layer.set_enabled(_fog_enabled)
		_apply_fog_early_out()
	_push_overlay_edge_transition_data()
	_push_fog_uniforms()
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
