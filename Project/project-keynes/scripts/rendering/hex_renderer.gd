







# hex_renderer.gd v5
# 单一全屏 quad mesh + WorldData 的 4 张高分辨率纹理 + world_map.gdshader v5。
class_name HexRenderer
extends Node2D
const RendererCameraDetail = preload("res://scripts/rendering/renderer_camera_detail.gd")
const RendererWeatherState = preload("res://scripts/rendering/renderer_weather_state.gd")
const RendererSceneServices = preload("res://scripts/rendering/renderer_scene_services.gd")
const RendererDetailLayers = preload("res://scripts/rendering/renderer_detail_layers.gd")
const RendererLoadingVegetation = preload("res://scripts/rendering/renderer_loading_vegetation.gd")
const RendererMaterialPublish = preload("res://scripts/rendering/renderer_material_publish.gd")
const RendererShaderWater = preload("res://scripts/rendering/renderer_shader_water.gd")
const RendererTerrainHorizon = preload("res://scripts/rendering/renderer_terrain_horizon.gd")
const RendererDetailScatter = preload("res://scripts/rendering/renderer_detail_scatter.gd")
const RendererMapAssets = preload("res://scripts/rendering/renderer_map_assets.gd")

const RendererLightingBindings = preload("res://scripts/rendering/renderer_lighting_bindings.gd")

const RendererWeatherInputs = preload("res://scripts/rendering/renderer_weather_inputs.gd")

const DetailProfileSelection = preload("res://scripts/rendering/detail_profile_selection.gd")

const RendererSeaIceDiagnostics = preload("res://scripts/rendering/renderer_sea_ice_diagnostics.gd")

# Preserve the existing HexRenderer constant surface while implementations
# live in the stateless collaborators.
const PK_WEB_TEXTURE_BUDGET_DEFINE = RendererShaderWater.PK_WEB_TEXTURE_BUDGET_DEFINE
const QUALITY_PREFIX_LOW = RendererShaderWater.QUALITY_PREFIX_LOW
const WORLD_MAP_WEB_MIN_DEFINE = RendererShaderWater.WORLD_MAP_WEB_MIN_DEFINE
const WORLD_MAP_WEB_NO_MICRO_DEFINE = RendererShaderWater.WORLD_MAP_WEB_NO_MICRO_DEFINE
const WORLD_MAP_WEB_LAND_ONLY_DEFINE = RendererShaderWater.WORLD_MAP_WEB_LAND_ONLY_DEFINE
const WORLD_MAP_WEB_HORIZON_DEFINE = RendererShaderWater.WORLD_MAP_WEB_HORIZON_DEFINE
const WORLD_MAP_WEB_PREFIX = RendererShaderWater.WORLD_MAP_WEB_PREFIX
const WORLD_MAP_WEB_PREFIX_MICRO = RendererShaderWater.WORLD_MAP_WEB_PREFIX_MICRO
const PK_WEB_MICRO_BOOT_META = RendererShaderWater.PK_WEB_MICRO_BOOT_META
const WORLD_MAP_WEB_HIGH_BASE = RendererShaderWater.WORLD_MAP_WEB_HIGH_BASE
const WORLD_MAP_WEB_HIGH_PREFIX = RendererShaderWater.WORLD_MAP_WEB_HIGH_PREFIX
const WATER_WEB_HIGH_PREFIX = RendererShaderWater.WATER_WEB_HIGH_PREFIX
const WATER_SHADER_PATH = RendererShaderWater.WATER_SHADER_PATH
const WATER_PASS_PREFIX = RendererShaderWater.WATER_PASS_PREFIX
const SPLIT_LAND_ONLY_DEFINE = RendererShaderWater.SPLIT_LAND_ONLY_DEFINE
const SPLIT_WATER_ONLY_DEFINE = RendererShaderWater.SPLIT_WATER_ONLY_DEFINE
const WORLD_MAP_SHADER_PATH = RendererShaderWater.WORLD_MAP_SHADER_PATH
const WATER_PARAM_NAMES: Array[StringName] = RendererShaderWater.WATER_PARAM_NAMES
const _HORIZON_BAKE_SHADER_PATH = RendererTerrainHorizon._HORIZON_BAKE_SHADER_PATH


## 加载期逐层构建进度（只用于"正在生成世界"进度条，不改变图层构建逻辑/数量）。
## layer_index 从 1 开始计"已完成层数"，layer_count 是本轮总层数。
## 订阅方（world_runtime_host）在 set_map_cooperative() 前后连接/断开。
signal loading_layer_progress(layer_index: int, layer_count: int, layer_name: String)

const TERRAIN_MICRO_TEXTURE: Texture2D = preload("res://assets/textures/terrain_micro_data.png")
const VisualTileHorizonBakerScript = preload(
	"res://scripts/rendering/visual_tile_horizon_baker.gd")
const DetailScatterChangeSetScript = preload("res://scripts/data/detail_scatter_change_set.gd")
const VegetationFamilyLayerScript = preload("res://scripts/rendering/vegetation_family_layer.gd")
const BuildingVisualLayerScript = preload("res://scripts/rendering/building_visual_layer.gd")
const ResourceVisualLayerScript = preload("res://scripts/rendering/resource_visual_layer.gd")
const WorldSkyBackgroundScript = preload("res://scripts/rendering/world_sky_background.gd")
const CloudShadowFieldScript = preload("res://scripts/rendering/cloud_shadow_field.gd")
var _resource_visual_layer: Node2D
var _resource_visual_cpu_ms := 0.0

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
		RendererSceneServices._after_hex_size(self)

## 探针开关（已定案，保留 false）：web 上用 3 行 shader 替换 world_map。
## 结论：换掉后首帧仍然 45s，所以世界材质不是元凶，见 weather_layer 的裁剪变体。
const PK_WEB_TRIVIAL_WORLD_SHADER_PROBE := false
## 探针：web 上跳过 deferred 植被填充（图层仍创建），用来判定长帧是否来自填充。
const PK_WEB_SKIP_DEFERRED_VEG_SEED := false
## Web 天气表现层总闸（只在高画质下绘制）。
## 判定见 `_web_weather_layer_draw_allowed()`：
##   - 玩家设置「高」→ `visual_quality >= 2` → 绘制；
##   - QA 的 `?tier=high`（autotest 把 mobile tier 推到 HIGH）→ 也按高画质处理；
##   - 低 / 中 / auto → 不绘制（对象仍在、所有 set_* 照常、天气**模拟**不受影响）。
## 实测依据：weather_overlay 那套在 ANGLE 上把每帧
## 拖到几十秒，94% 采样卡在 blitOffscreenFramebuffer 的 getParameter（GPU 排队同步）。
## 不绘制后：10x 跑满一年、最大帧间隔 2 秒。
## 落地注意：**不能**只在 `_ready` 里写一次 `visible = false` ——
## `WeatherLayer._refresh_visibility()` 在有 LUT/fronts 时会自己把 visible 置 true
## （setup() 里就会），必须走 `_apply_weather_layer_render_gate()` 把门交给天气层收敛。
## 置 false 是应急总闸：web 上任何画质都不绘制。
const PK_WEB_ENABLE_WEATHER_LAYER := true

@export var shader_path: String = "res://shaders/world_map.gdshader"
# 运行期会复制该材质并持续写入大量 Packed* shader uniforms。把资源引用保留在
# 场景/脚本存储中，但从 Inspector（尤其 Remote Inspector）隐藏，避免编辑器在
# 运行时序列化材质参数数组时触发 Godot remote debugger 的 Variant 解码问题。
@export_storage var world_material: ShaderMaterial = preload("res://materials/world_map_material.tres"):
	set(value):
		world_material = value
		RendererSceneServices._after_world_material(self)

@export_storage var world_lighting_profile: WorldLightingProfile:
	set(value):
		world_lighting_profile = value
		RendererSceneServices._after_world_lighting_profile(self)

@export_group("Shader Hot Reload")
@export var shader_hot_reload_enabled: bool = true
@export_range(0.1, 5.0, 0.1) var shader_hot_reload_interval: float = 0.35

# ─── Hypsometric 色阶（海陆双向，从深到浅） ──────────────────────────────
# Open Ocean Color Rebalance：与 world_map.gdshader 同步，把深/浅海亮度差收敛，
# 避免“浅海发亮、深海近黑”的强烈对比；海岸青绿环与深海深蓝过硬时，提亮深/中海、
# 略压浅/岸海，让整片海面更协调连续。
@export_group("Hypsometric Colors")
## 【深海底色】远洋最深处的基础颜色。
@export var color_deep_ocean: Color = Color(0.22, 0.31, 0.43):
	set(v):
		color_deep_ocean = RendererShaderWater._assign_water_param(self, &"color_deep_ocean", v)
## 【中深海底色】
@export var color_mid_ocean: Color = Color(0.25, 0.35, 0.46):
	set(v):
		color_mid_ocean = RendererShaderWater._assign_water_param(self, &"color_mid_ocean", v)
## 【浅海底色】
@export var color_shallow: Color = Color(0.27, 0.40, 0.49):
	set(v):
		color_shallow = RendererShaderWater._assign_water_param(self, &"color_shallow", v)
## 【近岸水色】
@export var color_coast_water: Color = Color(0.30, 0.43, 0.51):
	set(v):
		color_coast_water = RendererShaderWater._assign_water_param(self, &"color_coast_water", v)
# 地表色阶按 lowland/hill/mountain/peak 分开：低地偏绿、山丘收黄、山地压暗为岩棕、
# 山顶提亮为裸岩灰白，形成中→暗→亮的高度层次，并配合 hillshade 让山腰阴暗、山脊提亮。
@export var color_beach: Color = Color(0.85, 0.78, 0.55)
@export var color_lowland: Color = Color(0.54, 0.64, 0.40)
@export var color_hill: Color = Color(0.60, 0.56, 0.36)
@export var color_mountain: Color = Color(0.44, 0.39, 0.36)
@export var color_peak: Color = Color(0.80, 0.79, 0.78)
@export var color_snow: Color = Color(0.96, 0.96, 0.96)

# ─── 双光源 hillshading ──────────────────────────────────────────────────
# 加强双光源明暗与坡度增益，让大尺度起伏（山系阴影面、盆地洼地、河谷下切）在 2.5D
# 着色下更立体可读；配合 height bake / biome detail 保留坡面对比，让山脊和山谷更容易读出。
@export_group("Hillshading")
@export_range(0.0, 1.0, 0.01) var hillshade_strength: float = 0.90
@export_range(0.5, 24.0, 0.5) var hillshade_slope_gain: float = 15.0

# ─── 河流 ────────────────────────────────────────────────────────────────
# flow 是 SDF 反距离编码（1=河中心，0=>=SDF_MAX_DIST_PX 远）；Legacy 打在 height_tex.B。
# baker 的 SDF_MAX_DIST_PX = 5 像素，保持大尺度地图上河流为细线。
# threshold_low=外圈 outline 起点，threshold_high=内圈主色完全。
@export_group("Rivers")
@export_range(0.0, 1.0, 0.01) var river_strength: float = 0.85
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

# ─── 陆地色度：setter 直推 _shader_mat，可经远程场景树实时拖动 ─────────────
@export_group("Land Chroma")
## biome_hue_modulate 乘数保留比例；1 = 原始地形偏色，0 = 只剩海拔底色。
@export_range(0.0, 1.0, 0.01) var biome_tint_strength: float = 0.80:
	set(value):
		biome_tint_strength = RendererShaderWater._assign_world_uniform(self, &"biome_tint_strength", clampf(value, 0.0, 1.0))
## 所有陆地变色层之后、光照之前的反照率饱和度。
@export_range(0.0, 1.5, 0.01) var land_albedo_saturation: float = 0.92:
	set(value):
		land_albedo_saturation = RendererShaderWater._assign_world_uniform(self, &"land_albedo_saturation", clampf(value, 0.0, 1.5))
## 陆地色调映射中按明度 ACES 的占比；0 = 纯逐通道 ACES（toe 段会放大色度）。
@export_range(0.0, 1.0, 0.01) var tonemap_hue_preserve: float = 0.3:
	set(value):
		tonemap_hue_preserve = RendererShaderWater._assign_world_uniform(self, &"tonemap_hue_preserve", clampf(value, 0.0, 1.0))

# ─── 季节 / 气候系统（每帧由 main.gd 通过 set_*_phase 推进） ─────────────
# season_temp_amp 与 climate_profile.gd、uniforms.gdshaderinc 同步，是推送到 shader 的数据源。
# 和 uniforms.gdshaderinc 同步。这是真正推送到 shader 的数据源（行 989）。
@export_group("Climate")
@export_range(0.0, 0.4, 0.01) var season_temp_amp: float = 0.32
@export_range(0.0, 1.0, 0.01) var vegetation_season_strength: float = 0.85:
	set(value):
		vegetation_season_strength = RendererShaderWater._assign_world_uniform(self, &"vegetation_season_strength", clampf(value, 0.0, 1.0))
@export_range(0.0, 1.0, 0.01) var dynamic_snow_strength: float = 0.85
# dynamic_cell / dyn_atlas_smooth / ecology / ice 四张 atlas 的上传节流。
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
## 云层不透明度总控：只影响天上的云，不影响雨幕/风/云影。
## 1.0 = 原来的实心白云（alpha 上限 0.86）；0.72 让地形能透出来。
@export_range(0.0, 1.0, 0.01) var weather_cloud_opacity: float = 0.72:
	set(value):
		weather_cloud_opacity = RendererShaderWater._assign_weather_cloud_opacity(self, clampf(value, 0.0, 1.0))

@export_group("Cloud Shadow")
## PC 高画质直接光照路径的最大直射光压暗比例。
@export_range(0.0, 1.0, 0.01) var cloud_shadow_strength_high: float = 0.85:
	set(value):
		cloud_shadow_strength_high = clampf(value, 0.0, 1.0)
		RendererShaderWater._push_cloud_shadow_tuning(self)
## PC 中画质合成 pass 的压暗比例。
@export_range(0.0, 1.0, 0.01) var cloud_shadow_strength_mid: float = 0.62:
	set(value):
		cloud_shadow_strength_mid = clampf(value, 0.0, 1.0)
		RendererShaderWater._push_cloud_shadow_tuning(self)
## PC 低画质、移动端和 Web 合成 pass 的压暗比例。
@export_range(0.0, 1.0, 0.01) var cloud_shadow_strength_low: float = 0.48:
	set(value):
		cloud_shadow_strength_low = clampf(value, 0.0, 1.0)
		RendererShaderWater._push_cloud_shadow_tuning(self)
## 云量覆盖响应增益。提高后，中低云量天气也会形成连续可见的云影。
@export_range(0.25, 3.0, 0.05) var cloud_shadow_coverage_gain: float = 1.25:
	set(value):
		cloud_shadow_coverage_gain = clampf(value, 0.25, 3.0)
		RendererShaderWater._push_cloud_shadow_tuning(self)
## 厚云时环境光/天光的额外衰减权重（0=只压直射、1=间接光同幅压暗）。
## 云影主要挡住太阳直射，天空散射光基本照旧；这里只保留少量环境光层次感。
## 压三成环境光会让阴影里的地面丢失色相、发灰发脏。0.12 只留一点层次感。
@export_range(0.0, 1.0, 0.05) var cloud_shadow_ambient_weight: float = 0.12:
	set(value):
		cloud_shadow_ambient_weight = clampf(value, 0.0, 1.0)
		RendererShaderWater._push_cloud_shadow_material_inputs(self)
## 云影内部噪声的世界尺度平流速度；实际 UV 位移还乘 cloud_shadow_uv_scroll_gain。
@export_range(0.0, 0.20, 0.005) var cloud_shadow_motion_speed: float = 0.15:
	set(value):
		cloud_shadow_motion_speed = clampf(value, 0.0, 0.20)
		RendererShaderWater._push_cloud_shadow_tuning(self)
## 云影噪声 UV 滚动增益。用于把归一化世界坐标中的微小位移提升到可见的
## 连续动画速度，不改变 LUT 云量更新节奏。

@export_range(0.0, 32.0, 0.5) var cloud_shadow_uv_scroll_gain: float = 8.0:
	set(value):
		cloud_shadow_uv_scroll_gain = clampf(value, 0.0, 32.0)
		RendererShaderWater._push_cloud_shadow_tuning(self)
## 海面云影响应比例。陆地保持完整云影，海面单独控制以避免过弱或脏黑。
@export_range(0.0, 1.0, 0.05) var cloud_shadow_water_scale: float = 0.58:
	set(value):
		cloud_shadow_water_scale = clampf(value, 0.0, 1.0)
		RendererShaderWater._push_cloud_shadow_material_inputs(self)
## LUT 范围内部的云团明暗对比度。越高越能看出斑块形状。
@export_range(0.0, 1.0, 0.05) var cloud_shadow_shape_contrast: float = 1.0:
	set(value):
		cloud_shadow_shape_contrast = clampf(value, 0.0, 1.0)
		RendererShaderWater._push_cloud_shadow_tuning(self)
## 主噪声坐标的域扭曲强度。提高后云团边界更破碎、更接近自然云块。
@export_range(0.0, 1.0, 0.05) var cloud_shadow_noise_warp: float = 0.36:
	set(value):
		cloud_shadow_noise_warp = clampf(value, 0.0, 1.0)
		RendererShaderWater._push_cloud_shadow_tuning(self)
## 动态细节噪声对主云形的调制强度。
@export_range(0.0, 1.0, 0.05) var cloud_shadow_dynamic_detail_gain: float = 0.32:
	set(value):
		cloud_shadow_dynamic_detail_gain = clampf(value, 0.0, 1.0)
		RendererShaderWater._push_cloud_shadow_tuning(self)
## 动态域扭曲强度。提高后云团会随滚动产生更明显的形变。
@export_range(0.0, 2.0, 0.05) var cloud_shadow_dynamic_warp_gain: float = 0.80:
	set(value):
		cloud_shadow_dynamic_warp_gain = clampf(value, 0.0, 2.0)
		RendererShaderWater._push_cloud_shadow_tuning(self)
## 云影边缘羽化宽度。越高边缘越软、核心越不容易形成硬白边。
@export_range(0.0, 2.0, 0.05) var cloud_shadow_edge_softness: float = 1.10:
	set(value):
		cloud_shadow_edge_softness = clampf(value, 0.0, 2.0)
		RendererShaderWater._push_cloud_shadow_tuning(self)
## 局地风对 field 内动态形变的影响。主平流仍由 CPU 累积的全局风负责。
@export_range(0.0, 1.0, 0.05) var cloud_shadow_wind_influence: float = 0.22:
	set(value):
		cloud_shadow_wind_influence = clampf(value, 0.0, 1.0)
		RendererShaderWater._push_cloud_shadow_tuning(self)
## LUT 云量 Mask 的起始偏置。提高后只有更高云量区域会出现云影。
@export_range(0.0, 0.8, 0.02) var cloud_shadow_mask_bias: float = 0.10:
	set(value):
		cloud_shadow_mask_bias = clampf(value, 0.0, 0.8)
		RendererShaderWater._push_cloud_shadow_tuning(self)
## 独立云核密度。提高后同一片 LUT Mask 内会出现更多、更小的云朵。
@export_range(0.35, 2.5, 0.05) var cloud_shadow_cell_scale: float = 0.75:
	set(value):
		cloud_shadow_cell_scale = clampf(value, 0.35, 2.5)
		RendererShaderWater._push_cloud_shadow_tuning(self)
## 世界空间主云团尺度。降低后云团更大、更连续；提高后云团更密。
## 当前尺度把噪声单元压到约 1.6 hex，云团保持约 3~5 hex 的可分辨大小。
## 压到 62（约 1.6 hex），云团直径从 7~12 hex 降到 3~5 hex，整屏能看到
## 十来朵彼此分开的云影而不是 3~5 团大色块。
@export_range(0.001, 0.05, 0.001) var cloud_shadow_world_scale: float = 0.0130:
	set(value):
		cloud_shadow_world_scale = clampf(value, 0.001, 0.05)
		RendererShaderWater._push_cloud_shadow_tuning(self)
## 云缘侵蚀强度：中频噪声把云团边缘啃成絮状、并在云内部掏洞。
## 0 = 退回单层 value noise 的圆疙瘩；1 = 极碎（云量会明显变少）。
@export_range(0.0, 1.0, 0.05) var cloud_shadow_erosion: float = 0.40:
	set(value):
		cloud_shadow_erosion = clampf(value, 0.0, 1.0)
		RendererShaderWater._push_cloud_shadow_tuning(self)
## 开启后显示黑白云影 Mask：黑=无云影，白=云影区域。
@export var cloud_shadow_debug_view: bool = false:
	set(value):
		cloud_shadow_debug_view = RendererShaderWater._assign_cloud_shadow_debug_view(self, value)

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
@export_range(0, 17, 1) var terrain_surface_debug_view: int = 0:
	set(value):
		var was_split := _split_active()
		terrain_surface_debug_view = clampi(value, 0, 17)
		RendererShaderWater._apply_surface_debug_view(self, was_split)

## 陆地 / 水面双 program 总开关，可用于远程 inspector 的 A/B。
## 默认全平台启用；`terrain_surface_debug_view != 0` 或（Compatibility 后端 + tiled）时
## 自动回退单 program（见 _split_active()）。关掉即完全回到今天的单 program + 单 quad。
@export var split_land_water_passes: bool = true:
	set(value):
		if split_land_water_passes == value:
			return
		split_land_water_passes = value
		RendererShaderWater._apply_split_land_water_passes(self)

## 拆分时是否使用保守覆盖 mesh（TerrainCoverageMesh 模块）。
## 关掉 / 模块缺失 / 构建失败 ⇒ 两张 program 共享整张 quad（保底可运行，行为=今天）。
@export var terrain_coverage_mesh_enabled: bool = true:
	set(value):
		if terrain_coverage_mesh_enabled == value:
			return
		terrain_coverage_mesh_enabled = value
		RendererTerrainHorizon._apply_coverage_mesh_enabled(self)

# 材质族参数暴露给 Inspector；运行时经远程场景树拖动 setter 直推 _shader_mat 即时生效，
# _rebuild 全量推送也读这组值。
# 材质族四参数：编辑器可调，setter 直推 _shader_mat 即时生效；_rebuild 全量推送也读这组值。
@export_range(0.0, 1.0, 0.01) var terrain_material_albedo_strength: float = 0.6:
	set(value):
		terrain_material_albedo_strength = RendererShaderWater._assign_world_uniform(self, &"terrain_material_albedo_strength", clampf(value, 0.0, 1.0))

@export_range(0.0, 0.8, 0.005) var terrain_material_normal_strength: float = 0.24:
	set(value):
		terrain_material_normal_strength = RendererShaderWater._assign_world_uniform(self, &"terrain_material_normal_strength", clampf(value, 0.0, 0.5))

@export_range(0.0, 1.0, 0.01) var terrain_material_roughness_strength: float = 0.35:
	set(value):
		terrain_material_roughness_strength = RendererShaderWater._assign_world_uniform(self, &"terrain_material_roughness_strength", clampf(value, 0.0, 1.0))

@export_range(64.0, 1024.0, 1.0) var terrain_material_world_size: float = 384.0:
	set(value):
		terrain_material_world_size = RendererShaderWater._assign_world_uniform(self, &"terrain_material_world_size", clampf(value, 64.0, 1024.0))
		_for_each_vegetation_layer(func(layer: ShrubLayer) -> void:
			layer.set_lod_debug_view(terrain_surface_debug_view == 6)
		)
@export_range(0.0, 0.96, 0.01) var terrain_ecotone_width: float = 0.84:
	set(value):
		terrain_ecotone_width = clampf(value, 0.0, 0.96)
		RendererShaderWater._push_world_uniform(self, &"terrain_ecotone_width", terrain_ecotone_width)
		RendererTerrainHorizon._push_overlay_edge_transition_data(self)
@export_range(0.0, 0.45, 0.01) var terrain_ecotone_noise: float = 0.22:
	set(value):
		terrain_ecotone_noise = clampf(value, 0.0, 0.45)
		RendererShaderWater._push_world_uniform(self, &"terrain_ecotone_noise", terrain_ecotone_noise)
		RendererTerrainHorizon._push_overlay_edge_transition_data(self)
@export var day_night_enabled: bool = true
@export_group("永昼太阳")
## 每游戏年包含的 Shader 日数量；2 表示一年两轮，0.5 表示两年一轮。
@export_range(0.0, 32.0, 0.25, "or_greater") var shader_days_per_game_year: float = 2.0:
	set(value):
		shader_days_per_game_year = RendererShaderWater._assign_shader_days_per_game_year(self, maxf(value, 0.0))
var _apply_shader_clock: Callable

## 太阳最低高度（角度）；抬高会缩短最长阴影。
@export_range(0.0, 45.0, 1.0) var eternal_min_elevation_deg: float = 10.0:
	set(value):
		eternal_min_elevation_deg = clampf(value, 0.0, 45.0)
		RendererShaderWater._push_eternal_daylight_uniforms(self)
## 日内最大时角（角度）；增大会扩大高低浮动并拉长早晚阴影。
@export_range(0.0, 89.0, 1.0) var eternal_max_hour_angle_deg: float = 70.0:
	set(value):
		eternal_max_hour_angle_deg = clampf(value, 0.0, 89.0)
		RendererShaderWater._push_eternal_daylight_uniforms(self)
@export_group("")
@export var extreme_weather_ground_effect_enabled: bool = true
@export var perf_sampler_enabled: bool = false

@export_group("Terrain Horizon Shadow")
@export_range(0.0, 1.5, 0.01) var terrain_horizon_strength: float = 1.20:
	set(value):
		terrain_horizon_strength = clampf(value, 0.0, 1.5)
		RendererTerrainHorizon._push_terrain_horizon_uniforms(self)
@export_range(0.01, 1.0, 0.005) var terrain_horizon_softness: float = 0.30:
	set(value):
		terrain_horizon_softness = clampf(value, 0.01, 1.0)
		RendererTerrainHorizon._push_terrain_horizon_uniforms(self)
@export_range(0.30, 1.5708, 0.01) var terrain_horizon_max_angle: float = 1.309:
	set(value):
		terrain_horizon_max_angle = clampf(value, 0.30, 1.5708)
		RendererTerrainHorizon._push_terrain_horizon_uniforms(self)
@export_range(0.35, 1.0, 0.01) var terrain_horizon_cast_floor: float = 0.82:
	set(value):
		terrain_horizon_cast_floor = clampf(value, 0.35, 1.0)
		RendererTerrainHorizon._push_terrain_horizon_uniforms(self)
@export_range(0, 2, 1) var terrain_horizon_debug_view: int = 0:
	set(value):
		terrain_horizon_debug_view = clampi(value, 0, 2)
		RendererTerrainHorizon._push_terrain_horizon_uniforms(self)

# Terrain GI 从同一张 horizon 图派生；设计见 docs/cpp-dots-runtime/terrain-gi-bake.md。
# 三个强度全部归零即精确回退到接入 GI 之前，
# 这是视觉回归定位的主要手段。
@export_group("Terrain GI")
@export_range(0.0, 1.0, 0.01) var gi_ao_strength: float = 0.95:
	set(value):
		gi_ao_strength = clampf(value, 0.0, 1.0)
		RendererTerrainHorizon._push_terrain_horizon_uniforms(self)
## V_sky 下限。峡谷底部仍有岩壁多次散射，纯几何遮蔽的 0 会压成死黑并放大地表 dither 对比。
@export_range(0.0, 1.0, 0.01) var gi_ao_floor: float = 0.38:
	set(value):
		gi_ao_floor = clampf(value, 0.0, 1.0)
		RendererTerrainHorizon._push_terrain_horizon_uniforms(self)
## 0=双线性；1=2×2 箱式低通。滤掉视觉高度残差在 AO 上留下的颗粒感，采样次数不变。
@export_range(0.0, 1.0, 0.01) var gi_ao_smoothing: float = 0.75:
	set(value):
		gi_ao_smoothing = clampf(value, 0.0, 1.0)
		RendererTerrainHorizon._push_terrain_horizon_uniforms(self)
## 环境光法线向 bent normal 偏转的比例。1.0 会完全丢弃几何法线，导致块状跳变。
@export_range(0.0, 1.0, 0.01) var gi_bent_strength: float = 0.45:
	set(value):
		gi_bent_strength = clampf(value, 0.0, 1.0)
		RendererTerrainHorizon._push_terrain_horizon_uniforms(self)
@export_range(0.0, 1.0, 0.01) var gi_normal_floor: float = 0.80:
	set(value):
		gi_normal_floor = clampf(value, 0.0, 1.0)
		RendererTerrainHorizon._push_terrain_horizon_uniforms(self)
@export_range(0.0, 0.5, 0.01) var gi_bounce_strength: float = 0.18:
	set(value):
		gi_bounce_strength = clampf(value, 0.0, 0.5)
		RendererTerrainHorizon._push_terrain_horizon_uniforms(self)
## 0=off 1=sky visibility 2=bent normal 3=occluder cell id 4=bounce only 5=clay (gray albedo, full lighting)
## 6=clay rough 7=normal shade (all normals, fixed light) 8=normal shade (terrain geometry only)
@export_range(0, 8, 1) var gi_debug_view: int = 0:
	set(value):
		gi_debug_view = clampi(value, 0, 8)
		RendererTerrainHorizon._push_terrain_horizon_uniforms(self)

@export_group("Visual Overhaul")
@export_storage var shrub_visual_profile: Resource = preload("res://data/visual/shrub_default.tres"):
	set(value):
		shrub_visual_profile = value
		RendererDetailLayers._after_visual_profile(self)
@export_storage var tree_visual_profile: Resource = preload("res://data/visual/tree_default.tres"):
	set(value):
		tree_visual_profile = value
		RendererDetailLayers._after_visual_profile(self)
@export_storage var grass_visual_profile: Resource = preload("res://data/visual/grass_default.tres"):
	set(value):
		grass_visual_profile = value
		RendererDetailLayers._after_visual_profile(self)
# 数据驱动点缀清单。留空时回退到上面 grass/shrub/tree 三个 profile（行为 1:1）。
# 配置后，hex_renderer 在 _ready 按 manifest.layers 生成对应数量的散布层。
#
# 此前默认是 null 而且没有任何场景 / 脚本给它赋值，所以 21 层清单（针叶、棕榈、
# 季风林、云雾林、红树、芦苇、仙人掌、苔原地衣、海草……）从未被实例化，全图植被
# 实际上只由 grass/shrub/tree 三层表达，专属生物群系自然长不出对味的植被。
@export_storage var decoration_manifest: Resource = preload("res://data/visual/world_decoration_manifest.tres"):
	set(value):
		decoration_manifest = value
		RendererDetailLayers._after_decoration_manifest(self)
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
var _simulation_speed_multiplier: float = 1.0
# 累积器硬上限：超过即提前冲刷，防止无限堆积。
@export_range(64, 8192, 64) var detail_scatter_enqueue_max_pending_cells: int = 1024
# 积压兜底：待处理批次数超过该阈值时，存量批次与新单元整体去重合并后重新切批，
# 避免同一 chunk 在多个批次里被反复重建的复利积压。
@export_range(2, 64, 1) var detail_scatter_merge_batch_threshold: int = 8
@export var detail_scatter_refresh_log_enabled: bool = false
@export var detail_scatter_rebuild_log_enabled: bool = false
@export_range(0.0, 100.0, 0.25) var detail_scatter_slow_layer_ms: float = 2.0
# 21 层清单接入与散布配额化后总实例数显著上升，旧预算会让全局配额长期
# 触顶、所有层被同比稀释，反过来又抹平生物群系差异。
@export var detail_scatter_desktop_total_instance_budget: int = 120000
@export var detail_scatter_mobile_total_instance_budget: int = 12000

# ─── Visual Pass 2：TOD 消费端开关 ─────────────────────────────────────
# 这三个开关由 main.gd 的同名 @export 推进，到达 shader 内同名 uniform。
# rain_density_boost_enabled：粒子数量提升（renderer 仅转发到 WeatherLayer）
# cloud_tod_tint_enabled：云层 TOD 染色
@export_group("Pass 2")
@export var rain_density_boost_enabled: bool = true
@export var cloud_tod_tint_enabled: bool = true

# ═══════════════════════════════════════════════════════════════════════════
# 【水面参数】全部水面参数的唯一来源（main.gd 不再保留副本；以前两处都有、后写的覆盖先写的，
# 在这里改了没效果）。每个参数都带内联 setter：运行中在检视器里拖动滑条即时刷新画面。
# 参数名对应着色器 uniform（shaders/include/uniforms.gdshaderinc），悬停可看中文说明。
# 初值由 _push_water_params_to() 按 WATER_PARAM_NAMES 统一推给主材质与水面材质。
# ═══════════════════════════════════════════════════════════════════════════
@export_group("海洋水面 · 效果开关")
## 【水面效果总开关】关闭后水面退回纯色，下面所有波浪 / 反射 / 洋流效果一并失效。
@export var water_effect_enabled: bool = true:
	set(v):
		water_effect_enabled = RendererShaderWater._assign_water_param(self, &"water_effect_enabled", v)
## 【洋流可视化】关闭后浪向不再跟随洋流，洋流染色也消失。
@export var ocean_current_enabled: bool = true:
	set(v):
		ocean_current_enabled = RendererShaderWater._assign_water_param(self, &"ocean_current_enabled", v)
## 【波浪】关闭后水面法线恒为平面，只剩颜色与高光。
@export var water_waves_enabled: bool = true:
	set(v):
		water_waves_enabled = RendererShaderWater._assign_water_param(self, &"water_waves_enabled", v)
## 【菲涅尔天空反射】
@export var water_fresnel_enabled: bool = true:
	set(v):
		water_fresnel_enabled = RendererShaderWater._assign_water_param(self, &"water_fresnel_enabled", v)
## 【粼光】水面高频颗粒高光（需要画质 ≥ 中）。
@export var water_sparkle_enabled: bool = true:
	set(v):
		water_sparkle_enabled = RendererShaderWater._assign_water_param(self, &"water_sparkle_enabled", v)
## 【焦散】只在珊瑚礁水域、白天生效。
@export var caustics_enabled: bool = true:
	set(v):
		caustics_enabled = RendererShaderWater._assign_water_param(self, &"caustics_enabled", v)
## 【浅水透底】近岸浅水透出海底颜色。
@export var shallow_transparency_enabled: bool = true:
	set(v):
		shallow_transparency_enabled = RendererShaderWater._assign_water_param(self, &"shallow_transparency_enabled", v)

@export_group("海洋水面 · 波浪总体")
## 【浪的疏密】越大，涟漪和笔触越小越密；越小越舒缓。
@export_range(0.25, 4.0, 0.01, "or_greater") var water_flow_wave_density: float = 1.75:
	set(v):
		water_flow_wave_density = RendererShaderWater._assign_water_param(self, &"water_flow_wave_density", v)
## 【流动速度倍率】涟漪与笔触的流动速度正比于它；0 = 静止。
@export_range(0.0, 3.0, 0.01, "or_greater") var water_flow_advection: float = 1.15:
	set(v):
		water_flow_advection = RendererShaderWater._assign_water_param(self, &"water_flow_advection", v)
## 【波浪总幅度】同时放大法线与波峰波谷明暗。
@export_range(0.0, 3.0, 0.01, "or_greater") var water_flow_wave_amplitude: float = 1.35:
	set(v):
		water_flow_wave_amplitude = RendererShaderWater._assign_water_param(self, &"water_flow_wave_amplitude", v)
## 【浪尖碎白】浪头顶部的浅色高光强度，0 = 无。
@export_range(0.0, 1.0, 0.01) var water_flow_crest_strength: float = 0.38:
	set(v):
		water_flow_crest_strength = RendererShaderWater._assign_water_param(self, &"water_flow_crest_strength", v)
## 【浪脊笔触】离散浪脊法线与波高的总强度。
@export_range(0.0, 2.0, 0.01) var water_mark_strength: float = 1.0:
	set(v):
		water_mark_strength = RendererShaderWater._assign_water_param(self, &"water_mark_strength", v)
## 【浪脊覆盖率】笔触出现的格子比例。
@export_range(0.0, 2.0, 0.01) var water_mark_coverage: float = 1.0:
	set(v):
		water_mark_coverage = RendererShaderWater._assign_water_param(self, &"water_mark_coverage", v)
## 【浪脊长度】控制非顺流波峰笔触长度。
@export_range(0.3, 3.0, 0.01, "or_greater") var water_mark_length: float = 1.0:
	set(v):
		water_mark_length = RendererShaderWater._assign_water_param(self, &"water_mark_length", v)
## 【浪脊速度】只调节浪脊笔触的漂移与更新速度；0 = 静止。
@export_range(0.0, 4.0, 0.01, "or_greater") var water_mark_speed: float = 1.0:
	set(v):
		water_mark_speed = RendererShaderWater._assign_water_param(self, &"water_mark_speed", v)
## 【法线总强度】海洋波浪法线的整体倍率（同时影响陆地河流水面）。
@export_range(0.0, 6.0, 0.01, "or_greater") var water_base_normal_strength: float = 1.17:
	set(v):
		water_base_normal_strength = RendererShaderWater._assign_water_param(self, &"water_base_normal_strength", v)
## 【波浪尺度】越大波越密越短（同时影响陆地河流水面）。
@export_range(0.1, 4.0, 0.01, "or_greater", "or_less") var water_base_normal_scale: float = 0.93:
	set(v):
		water_base_normal_scale = RendererShaderWater._assign_water_param(self, &"water_base_normal_scale", v)
## 【波坡明暗】按太阳方向给波浪坡面做明暗，没有直射高光的海域也能看出起伏。
@export_range(0.0, 8.0, 0.05, "or_greater") var water_wave_shade_strength: float = 1.5:
	set(v):
		water_wave_shade_strength = RendererShaderWater._assign_water_param(self, &"water_wave_shade_strength", v)

@export_group("海洋水面 · 底层涟漪")
## 【涟漪强度】连续铺在整片海面下的细涟漪法线；0 = 去掉底层，只剩浪头笔触。
@export_range(0.0, 3.0, 0.01, "or_greater") var water_ripple_strength: float = 1.0:
	set(v):
		water_ripple_strength = RendererShaderWater._assign_water_param(self, &"water_ripple_strength", v)
## 【小尺度涟漪占比】小尺度涟漪相对大尺度的强度（需要画质 ≥ 中）。
@export_range(0.0, 1.5, 0.01) var water_ripple_detail_mix: float = 0.5:
	set(v):
		water_ripple_detail_mix = RendererShaderWater._assign_water_param(self, &"water_ripple_detail_mix", v)
## 【涟漪大小】越大涟漪越舒缓越粗；越小越细碎。
@export_range(0.3, 3.0, 0.01, "or_greater") var water_ripple_scale: float = 1.0:
	set(v):
		water_ripple_scale = RendererShaderWater._assign_water_param(self, &"water_ripple_scale", v)
## 【无洋流时的漂移】每个流动周期的位移（世界单位）。必须大于涟漪格宽（约 52）才是真正的流动，否则只是原地淡入淡出。
@export_range(0.0, 100.0, 0.5, "or_greater") var water_flow_drift_base: float = 30.0:
	set(v):
		water_flow_drift_base = RendererShaderWater._assign_water_param(self, &"water_flow_drift_base", v)
## 【洋流带来的漂移】位移 += 洋流向量 × 该值。越大，洋流强的海域流得越快。
@export_range(0.0, 300.0, 1.0, "or_greater") var water_flow_drift_current: float = 100.0:
	set(v):
		water_flow_drift_current = RendererShaderWater._assign_water_param(self, &"water_flow_drift_current", v)

@export_group("海洋水面 · 海况分区")
## 【平静海域强度】平静区的法线强度（相对值）。越小，平静区越平。
@export_range(0.0, 1.0, 0.01) var water_rough_min: float = 0.22:
	set(v):
		water_rough_min = RendererShaderWater._assign_water_param(self, &"water_rough_min", v)
## 【风浪海域强度】风浪区的法线强度（相对值）。
@export_range(0.0, 2.0, 0.01) var water_rough_max: float = 1.0:
	set(v):
		water_rough_max = RendererShaderWater._assign_water_param(self, &"water_rough_max", v)
## 【分区大小】平静 / 风浪区块的空间尺度，越大块越大。
@export_range(0.25, 4.0, 0.01, "or_greater") var water_rough_scale: float = 1.0:
	set(v):
		water_rough_scale = RendererShaderWater._assign_water_param(self, &"water_rough_scale", v)
## 【风浪区占比】0 = 几乎整片平静，1 = 几乎整片风浪。
@export_range(0.0, 1.0, 0.01) var water_rough_coverage: float = 0.5:
	set(v):
		water_rough_coverage = RendererShaderWater._assign_water_param(self, &"water_rough_coverage", v)

@export_group("海洋水面 · 洋流")
## 【洋流影响强度】浪向跟随洋流与洋流染色的总权重。
@export_range(0.0, 1.0, 0.01) var ocean_current_strength: float = 0.88:
	set(v):
		ocean_current_strength = RendererShaderWater._assign_water_param(self, &"ocean_current_strength", v)

@export_group("海洋水面 · 光照与反射")
## 【天空反射强度】
@export_range(0.0, 1.0, 0.01) var water_reflection_strength: float = 0.32:
	set(v):
		water_reflection_strength = RendererShaderWater._assign_water_param(self, &"water_reflection_strength", v)
## 【次表面散射强度】低太阳时迎光波坡透出青绿色；0 = 关闭（需要画质 ≥ 中）。
@export_range(0.0, 3.0, 0.01, "or_greater") var water_sss_strength: float = 0.18:
	set(v):
		water_sss_strength = RendererShaderWater._assign_water_param(self, &"water_sss_strength", v)
## 【次表面散射锐度】越大，只有正对太阳的波坡才透光。
@export_range(1.0, 8.0, 0.1) var water_sss_power: float = 2.0:
	set(v):
		water_sss_power = RendererShaderWater._assign_water_param(self, &"water_sss_power", v)
## 【次表面散射颜色】
@export var water_sss_color: Color = Color(0.10, 0.52, 0.46):
	set(v):
		water_sss_color = RendererShaderWater._assign_water_param(self, &"water_sss_color", v)
## 【焦散强度】仅珊瑚礁水域。
@export_range(0.0, 1.0, 0.01) var caustics_strength: float = 0.32:
	set(v):
		caustics_strength = RendererShaderWater._assign_water_param(self, &"caustics_strength", v)
## 【浅水透底程度】
@export_range(0.0, 1.0, 0.01) var shallow_transparency_factor: float = 0.56:
	set(v):
		shallow_transparency_factor = RendererShaderWater._assign_water_param(self, &"shallow_transparency_factor", v)

@export_group("海洋水面 · 色彩与过渡")
## 【深海对比度】
@export_range(0.5, 3.0, 0.05) var deep_ocean_contrast: float = 0.96:
	set(v):
		deep_ocean_contrast = RendererShaderWater._assign_water_param(self, &"deep_ocean_contrast", v)
## 0 = 回到旧的单色深海；下面四项色彩层次都会按这个总量缩放。
## 【深海色彩层次总量】0 = 回到旧的单色深海，下面四项都乘它。
@export_range(0.0, 1.0, 0.01) var deep_ocean_color_richness: float = 0.85:
	set(v):
		deep_ocean_color_richness = RendererShaderWater._assign_water_param(self, &"deep_ocean_color_richness", v)
## 【暖流 / 寒流色偏】暖流偏暖、寒流偏冷青（需要开启洋流可视化）。
@export_range(0.0, 1.0, 0.01) var deep_ocean_current_tint_strength: float = 0.60:
	set(v):
		deep_ocean_current_tint_strength = RendererShaderWater._assign_water_param(self, &"deep_ocean_current_tint_strength", v)
## 【纬度色温带】热带翠绿 — 温带中性 — 极地冷青。
@export_range(0.0, 1.0, 0.01) var deep_ocean_latitude_tint_strength: float = 0.85:
	set(v):
		deep_ocean_latitude_tint_strength = RendererShaderWater._assign_water_param(self, &"deep_ocean_latitude_tint_strength", v)
## 【深渊幽冷】最深处压暗并偏蓝紫。
@export_range(0.0, 1.0, 0.01) var deep_ocean_abyss_tint_strength: float = 0.60:
	set(v):
		deep_ocean_abyss_tint_strength = RendererShaderWater._assign_water_param(self, &"deep_ocean_abyss_tint_strength", v)
## 【海盆色斑】放大半封闭海与开阔海的色相差。
@export_range(0.0, 1.0, 0.01) var deep_ocean_patch_boost: float = 0.50:
	set(v):
		deep_ocean_patch_boost = RendererShaderWater._assign_water_param(self, &"deep_ocean_patch_boost", v)
## 【开阔海色块】远洋大块冷暖色斑的强度。
@export_range(0.0, 1.0, 0.01) var water_cartoon_color_strength: float = 0.75:
	set(v):
		water_cartoon_color_strength = RendererShaderWater._assign_water_param(self, &"water_cartoon_color_strength", v)
## 【亮度柔噪声】大尺度云影般的亮度起伏。
@export_range(0.0, 1.0, 0.01) var water_calm_noise_brightness: float = 0.95:
	set(v):
		water_calm_noise_brightness = RendererShaderWater._assign_water_param(self, &"water_calm_noise_brightness", v)
## 【色相柔噪声】冷暖色相的缓慢起伏。
@export_range(0.0, 1.0, 0.01) var water_calm_noise_tint_strength: float = 0.95:
	set(v):
		water_calm_noise_tint_strength = RendererShaderWater._assign_water_param(self, &"water_calm_noise_tint_strength", v)
## 【柔噪声总强度】乘在上面两项上，同时影响湖面波痕。
@export_range(0.0, 1.0, 0.01) var water_wave_line_strength: float = 0.70:
	set(v):
		water_wave_line_strength = RendererShaderWater._assign_water_param(self, &"water_wave_line_strength", v)
## 【水色边界扭曲】让海 / 湖 / 礁交界不是直线。过大会和洋流叠加撕出折痕。
@export_range(0.0, 4.0, 0.05) var water_domain_warp_strength: float = 0.55:
	set(v):
		water_domain_warp_strength = RendererShaderWater._assign_water_param(self, &"water_domain_warp_strength", v)
## 【水体软混合半径】越大过渡带越宽；0 = 硬切。
@export_range(0.0, 4.0, 0.05) var water_biome_blend_radius: float = 3.15:
	set(v):
		water_biome_blend_radius = RendererShaderWater._assign_water_param(self, &"water_biome_blend_radius", v)
## 【水色过渡柔和度】
@export_range(0.0, 1.0, 0.01) var water_transition_softness: float = 1.0:
	set(v):
		water_transition_softness = RendererShaderWater._assign_water_param(self, &"water_transition_softness", v)
## 【河口羽流】河水入海的扩散色带。
@export_range(0.0, 1.0, 0.01) var estuary_plume_strength: float = 0.65:
	set(v):
		estuary_plume_strength = RendererShaderWater._assign_water_param(self, &"estuary_plume_strength", v)

@export_group("湖泊与河流水面")
## 【湖水颜色】
@export var lake_water_color: Color = Color(0.18, 0.45, 0.60):
	set(v):
		lake_water_color = RendererShaderWater._assign_water_param(self, &"lake_water_color", v)
## 【河流流动条纹】
@export var river_flow_enabled: bool = true:
	set(v):
		river_flow_enabled = RendererShaderWater._assign_water_param(self, &"river_flow_enabled", v)
## 【河流流速】
@export_range(0.0, 4.0, 0.05) var river_flow_speed: float = 0.75:
	set(v):
		river_flow_speed = RendererShaderWater._assign_water_param(self, &"river_flow_speed", v)
## 【河流条纹频率】
@export_range(0.02, 1.0, 0.01) var river_flow_freq: float = 0.16:
	set(v):
		river_flow_freq = RendererShaderWater._assign_water_param(self, &"river_flow_freq", v)
## 【河流浪带强弱对比】【仅陆地河流水面，不影响海洋】
@export_range(0.0, 2.0, 0.01, "or_greater") var water_wave_patch_strength: float = 1.58:
	set(v):
		water_wave_patch_strength = RendererShaderWater._assign_water_param(self, &"water_wave_patch_strength", v)
## 【河流浪带尺度】【仅陆地河流水面，不影响海洋】
@export_range(0.1, 4.0, 0.01, "or_greater", "or_less") var water_wave_patch_scale: float = 2.69:
	set(v):
		water_wave_patch_scale = RendererShaderWater._assign_water_param(self, &"water_wave_patch_scale", v)
## 【河流细节涟漪强度】【仅陆地河流水面，不影响海洋；需要画质=高】
@export_range(0.0, 8.0, 0.05, "or_greater") var water_detail_normal_strength: float = 0.75:
	set(v):
		water_detail_normal_strength = RendererShaderWater._assign_water_param(self, &"water_detail_normal_strength", v)
## 【河流细节涟漪尺度】【仅陆地河流水面；需要画质=高】
@export_range(0.02, 4.0, 0.01, "or_greater", "or_less") var water_detail_normal_scale: float = 0.48:
	set(v):
		water_detail_normal_scale = RendererShaderWater._assign_water_param(self, &"water_detail_normal_scale", v)
## 【河流细节涟漪扭曲】【仅陆地河流水面；需要画质=高】
@export_range(0.0, 4.0, 0.01, "or_greater") var water_detail_normal_warp: float = 0.7:
	set(v):
		water_detail_normal_warp = RendererShaderWater._assign_water_param(self, &"water_detail_normal_warp", v)


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
var _shader_mat: ShaderMaterial
var _sky_background: Node
## [web-water-pass] web/Compatibility/LOW 档的**水面第二 pass** 节点与材质
## （见 shaders/world_water_web.gdshader）。桌面、以及 web 的中/高档恒为 null ——
## 那些情况下 world_map 自己就把水面画了，再画一遍就是双份水面。
## 创建/销毁唯一入口是 _sync_water_quad()（由 _apply_uniforms() 末尾驱动）。
var _water_quad: MeshInstance2D
var _water_mat: ShaderMaterial
## 已编进 _water_mat 的变体前缀（"" 或 "#define MAP_VISUAL_TILED\n"）。tiled 布局
# 切换会换掉 sampler 类型，前缀变了必须重编变体，不能复用旧的材质。
var _water_variant_prefix: String = ""
var _forced_water_program_kind: String = ""
## 第二 pass 的 shader 在 shader 语言层编不过（get_shader_uniform_list 为空）。
## 记住这一条，避免每次 _apply_uniforms 都重编 + 重复报同一条错。
var _water_pass_failed: bool = false
## 水面 program 的源码种类：
##   "web_min" = Web LOW/MID 的紧凑水面程序（world_water_web.gdshader + WATER_PASS_PREFIX）；
##   "high"    = Web HIGH 的 PC 水面程序（world_map.gdshader + WATER_WEB_HIGH_PREFIX）；
##   "split"   = 桌面 / 移动的 PC 水面程序（world_map.gdshader + SPLIT_WATER_ONLY_DEFINE）。
## 决定 uniform 对齐方式（"web_min" 之外都要从主材质整表拷贝）。
var _water_program_kind: String = ""
var _water_variant_kind: String = ""
## 当前水面 program 是否走 world_map.gdshader（= 能整表复用主材质的 uniform）。
var _water_uses_world_map: bool = false
## 当前水面 program 声明的 uniform 名集合（StringName → true）。运行期 setter 只把
## **水面 program 真的声明过**的键镜像过去，避免对紧凑程序刷 "parameter does not exist"。
var _water_uniform_names := {}
## 水面 program 在 shader 语言层编不过时整条拆分回退到单 program，避免只回退水面造成空洞。
## 单 program（陆地程序此时不带水面分支，只回退水会露出空洞）。
## 只对非 Web 生效：Web 的既有降级是"land-only 程序 + 暗海蓝占位色"，字节契约不动。
var _split_program_failed: bool = false
## 拆分时水面 / 陆地覆盖 mesh 来自 TerrainCoverageMesh 模块；任一为 null ⇒ 两张 program
## 共享整张 quad（保底可运行）。
var _coverage_water_mesh: Mesh = null
var _coverage_land_mesh: Mesh = null
## 最近一次覆盖 mesh 构建的结果（ok / reason / stats），诊断与测试用。
var _coverage_mesh_result := {}
var _coverage_mesh_stats := {}
var _coverage_mesh_script: Script = null
const TERRAIN_COVERAGE_MESH_PATH := "res://scripts/rendering/terrain_coverage_mesh.gd"
## Web 一次性取证：地表发白/黑屏时到底哪张 LUT/地形纹理是空的。
var _web_lut_probe_done := false
var _web_veg_defer_started := false
## Web 专用：把 9 层植被的 setup 推迟到进世界之后。实测这段在 wasm 里要 4.1 秒，
## 直接压在加载窗口里；植被只是观感层，晚 2-3 秒出现可以接受。
## Web 正式策略：天气层保留对象、只有高画质才绘制（见 PK_WEB_ENABLE_WEATHER_LAYER 注释）。
## PROBE：隐藏地图 quad 本身（隔离"地图绘制/图集上传"是否造成长帧）。
const PK_WEB_HIDE_WORLD_QUAD := false
const PK_WEB_MINIMAL_LAYERS := false
const PK_WEB_LAYER_FOG := true
const PK_WEB_LAYER_BORDER := true
const PK_WEB_LAYER_WEATHER := true
const PK_WEB_LAYER_BUILDING := false
const PK_WEB_DEFER_VEG_LAYERS := true
## 已绑到材质上的 LUT 纹理对象。不依赖 get_shader_parameter() 回读：
## web/GLES3 上回读不可靠，会让"过期检测"每帧命中、白白重绑并连带重推迷雾 uniform。
var _lut_bound := {}
var _weather_layer: WeatherLayer = null  # v9.split：天气独立层
var _cloud_shadow_field: Variant = null
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
# 最近一次视口加权下发回执（近处保留率等），供诊断报告合并。
var _last_detail_budget_weighted_report: Dictionary = {}
# 全局实例预算同步状态。21 层分块 MultiMesh 不能在每个 succession chunk 后全量
# 下发 visible_instance_count；那会把名义 2.5ms 的 drain 放大到几十毫秒。
# target 由当前总实例数计算，apply_fraction 是本轮渐进下发所用的稳定快照；
# 每帧最多推进 detail_scatter_refresh_layers_per_frame 层。
const DETAIL_BUDGET_FRACTION_EPSILON: float = 0.0025
var _detail_budget_target_fraction: float = 1.0
var _detail_budget_applied_fraction: float = -1.0
# 视口优先分配依赖相机视野：fraction 没变但相机平移或缩放也要重算，
# 否则玩家放大到某片区域时近处仍按旧视野分配预算。
var _detail_budget_applied_view_center: Vector2 = Vector2(INF, INF)
var _detail_budget_applied_view_zoom: float = -1.0
const DETAIL_BUDGET_VIEW_EPSILON: float = 24.0   # world units
const DETAIL_BUDGET_ZOOM_EPSILON: float = 0.02   # 相对缩放 2%
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
var _horizon_bake_vp: SubViewport = null
var _horizon_bake_world: WorldData = null
var _horizon_bake_waited: int = 0
var _camera_zoom: float = 1.0
# 一个物理像素覆盖的世界单位数，见 pixel_world_size()。
var _pixel_world_size: float = 1.0

# Phase 1：季节状态（每帧/每天由 WorldClock 推送）
var _season_phase: float = 1.0   # 0=spring 1=summer 2=autumn 3=winter
var _climate_anomaly: float = 0.0
var _world_time: float = 0.0
var _clock_running: bool = true
var _clock_speed_multiplier: float = 1.0
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
# 已推给 _shader_mat 的 cell LUT 网格尺寸；见 _sync_cell_lut_dims。
var _pushed_lut_dims: Vector2i = Vector2i.ZERO
var _qa_skip_lut_sync: bool = false
var _qa_skip_lut_checked: bool = false
var _lut_sync_frame: int = -1
var _lut_sync_reentry_count: int = 0
var _active_shader_source_path: String = ""
var _material_source_mtime: int = 0
var _shader_source_mtime: int = 0
# Milestone 3：天气子系统数组上传
# 与 shader 端 weather_front_centers[MAX_WEATHER_FRONTS] 长度严格一致；
# 0 fronts 时仍填满 16 个 zero-vec，避免 shader 端越界采样。
const MAX_WEATHER_FRONTS = RendererWeatherInputs.MAX_WEATHER_FRONTS

## Keep the nested type name for callers that construct `HexRenderer.PerfSampler`.
## The implementation and its state live in the scene-services collaborator.
class PerfSampler extends RendererSceneServices.PerfSampler:
	pass

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
var _trade_visual_layer: TradeActivityLayer = null
var _military_visual_layer: MilitaryArmyTokenLayer = null
var _building_visual_layer: BuildingVisualLayer = null


func get_last_detail_drain_ms() -> float: return RendererSceneServices.get_last_detail_drain_ms(self)

func _ready() -> void:
	RendererSceneServices._ready(self)

func _web_weather_layer_draw_allowed() -> bool: return RendererShaderWater._web_weather_layer_draw_allowed(self)

var _weather_gate_last_drawn: bool = true
var _set_weather_fronts_log_count: int = 0
var _set_weather_fronts_last_n: int = -1
const _set_weather_fronts_log_budget: int = 3

func _apply_weather_layer_render_gate() -> void: return RendererShaderWater._apply_weather_layer_render_gate(self)

func _process(delta: float) -> void:
	RendererSceneServices._process(self, delta)

func _sweep_dormant_detail_chunks() -> void:
	RendererSceneServices._sweep_dormant_detail_chunks(self)

func _load_shader() -> void: return RendererSceneServices._load_shader(self)

func _validate_world_program_variant() -> void: return RendererSceneServices._validate_world_program_variant(self)

func _load_fresh_shader_for_material(mat: ShaderMaterial) -> Shader: return RendererSceneServices._load_fresh_shader_for_material(self, mat)

func _visual_tiles_active() -> bool: return RendererShaderWater._visual_tiles_active(self)

static func micro_url_value_enabled(raw: String) -> bool:
	return RendererShaderWater.micro_url_value_enabled(raw)

static func web_map_micro_url_enabled() -> bool:
	return RendererShaderWater.web_map_micro_url_enabled()

static func web_map_web_prefix_active() -> String:
	return RendererShaderWater.web_map_web_prefix_active()

func _web_pc_high_active() -> bool: return RendererShaderWater._web_pc_high_active(self)

func _cloud_shadow_direct_active() -> bool: return RendererShaderWater._cloud_shadow_direct_active(self)

func _world_map_web_min_active() -> bool: return RendererShaderWater._world_map_web_min_active(self)

func _split_active() -> bool: return RendererShaderWater._split_active(self)

func _water_pass_active() -> bool: return RendererShaderWater._water_pass_active(self)

func _resolved_water_program_kind() -> String: return RendererShaderWater._resolved_water_program_kind(self)

func _water_program_prefix(kind: String) -> String: return RendererShaderWater._water_program_prefix(self, kind)

func _push_world_uniform(key: Variant, value: Variant) -> void: return RendererShaderWater._push_world_uniform(self, key, value)

func _global_sky_day_weight() -> float: return RendererShaderWater._global_sky_day_weight(self)

func configure_shader_clock(apply: Callable) -> void: return RendererShaderWater.configure_shader_clock(self, apply)

func _push_eternal_daylight_uniforms() -> void: return RendererShaderWater._push_eternal_daylight_uniforms(self)

func _bind_world_lighting_profile() -> void: return RendererShaderWater._bind_world_lighting_profile(self)

func _push_world_lighting_profile() -> void: return RendererLightingBindings.push_world_lighting_profile(self)


func _shader_declares_uniform(shader: Shader, uniform_name: StringName) -> bool: return RendererShaderWater._shader_declares_uniform(self, shader, uniform_name)

func _push_water_param(key: StringName, value: Variant) -> void: return RendererShaderWater._push_water_param(self, key, value)

func set_water_effect_enabled(v: bool) -> void: return RendererShaderWater.set_water_effect_enabled(self, v)

func set_ocean_current_enabled(v: bool) -> void: return RendererShaderWater.set_ocean_current_enabled(self, v)

func _push_water_params_to(sm: ShaderMaterial) -> void: return RendererShaderWater._push_water_params_to(self, sm)

func _refresh_split_configuration() -> void: return RendererShaderWater._refresh_split_configuration(self)

func _apply_split_program_fallback() -> void: return RendererShaderWater._apply_split_program_fallback(self)

func _sync_water_quad() -> void: return RendererShaderWater._sync_water_quad(self)

func _ensure_water_quad() -> void: return RendererShaderWater._ensure_water_quad(self)

func _water_quad_mesh(fallback: Mesh) -> Mesh: return RendererShaderWater._water_quad_mesh(self, fallback)

func _drop_water_quad() -> void: return RendererShaderWater._drop_water_quad(self)

func _create_water_quad(prefix: String, kind: String) -> void: return RendererShaderWater._create_water_quad(self, prefix, kind)

func _apply_water_uniforms() -> void: return RendererShaderWater._apply_water_uniforms(self)

func _push_water_lighting_uniforms() -> void: return RendererShaderWater._push_water_lighting_uniforms(self)

func _configure_cloud_shadow_field() -> void: return RendererShaderWater._configure_cloud_shadow_field(self)

func _push_cloud_shadow_tuning() -> void: return RendererShaderWater._push_cloud_shadow_tuning(self)

func _push_cloud_shadow_material_inputs() -> void: return RendererShaderWater._push_cloud_shadow_material_inputs(self)

func _push_water_fog_uniforms() -> void: return RendererShaderWater._push_water_fog_uniforms(self)

func _is_world_map_shader_path(path: String) -> bool: return RendererShaderWater._is_world_map_shader_path(self, path)

func _desktop_sky_quality_prefix() -> String: return RendererShaderWater._desktop_sky_quality_prefix(self)

func _apply_shader_variant_prefix(shader: Shader, source_path: String) -> Shader: return RendererShaderWater._apply_shader_variant_prefix(self, shader, source_path)

var _mobile_quality_tier_define: String = ""

func set_mobile_quality_tier(tier_define: String) -> void: return RendererShaderWater.set_mobile_quality_tier(self, tier_define)

func _mobile_quality_tier_from_define(tier_define: String) -> int: return RendererShaderWater._mobile_quality_tier_from_define(self, tier_define)

func _shader_quality_define_prefix(tier_define: String) -> String: return RendererShaderWater._shader_quality_define_prefix(self, tier_define)

func _for_each_vegetation_layer(callable: Callable) -> void: return RendererShaderWater._for_each_vegetation_layer(self, callable)

func configure_trade_visuals(layer: TradeActivityLayer) -> void: return RendererShaderWater.configure_trade_visuals(self, layer)

func configure_military_visuals(layer: MilitaryArmyTokenLayer) -> void: return RendererShaderWater.configure_military_visuals(self, layer)

func _instance_daylight_parameters() -> Dictionary: return RendererShaderWater._instance_daylight_parameters(self)

func _sync_trade_daylight() -> void: return RendererShaderWater._sync_trade_daylight(self)

func _sync_military_daylight() -> void: return RendererShaderWater._sync_military_daylight(self)

func _sync_detail_and_activity_materials() -> void: return RendererShaderWater._sync_detail_and_activity_materials(self)

func set_simulation_speed_multiplier(multiplier: float) -> void: return RendererShaderWater.set_simulation_speed_multiplier(self, multiplier)

func set_clock_running(running: bool) -> void: return RendererShaderWater.set_clock_running(self, running)

func _effective_detail_enqueue_coalesce_ms() -> float: return RendererDetailScatter._effective_detail_enqueue_coalesce_ms(self)


func queue_detail_scatter_refresh(indices: PackedInt32Array) -> void: return RendererDetailScatter.queue_detail_scatter_refresh(self, indices)

func _detail_all_family_mask() -> int: return RendererDetailScatter._detail_all_family_mask(self)

func _detail_family_mask_for_change(changes, row: int) -> int: return RendererDetailScatter._detail_family_mask_for_change(self, changes, row)

func _detail_profile_mask_for_change(changes, row: int) -> int: return RendererDetailScatter._detail_profile_mask_for_change(self, changes, row)

func queue_detail_scatter_changes(changes) -> void: return RendererDetailScatter.queue_detail_scatter_changes(self, changes)

func _count_set_bits(value: int) -> int: return RendererDetailScatter._count_set_bits(self, value)

func _dedup_detail_refresh_indices(indices: PackedInt32Array) -> PackedInt32Array: return RendererDetailScatter._dedup_detail_refresh_indices(self, indices)

func _enqueue_detail_refresh_batches(indices: PackedInt32Array) -> void: return RendererDetailScatter._enqueue_detail_refresh_batches(self, indices)

func _merge_pending_detail_refresh_batches(extra: PackedInt32Array) -> PackedInt32Array: return RendererDetailScatter._merge_pending_detail_refresh_batches(self, extra)

func _release_detail_refresh_inflight(cells: PackedInt32Array) -> void:
	return RendererDetailScatter._release_detail_refresh_inflight(self, cells)

func _reset_detail_refresh_plan() -> void:
	return RendererDetailScatter._reset_detail_refresh_plan(self)

func _begin_detail_refresh_plan() -> void:
	return RendererDetailScatter._begin_detail_refresh_plan(self)

func _detail_plan_should_yield(deadline_usec: int, items_done: int, max_items: int) -> bool:
	return RendererDetailScatter._detail_plan_should_yield(self, deadline_usec, items_done, max_items)

func _continue_detail_refresh_plan(deadline_usec: int, max_items: int) -> void:
	return RendererDetailScatter._continue_detail_refresh_plan(self, deadline_usec, max_items)

func _start_next_detail_refresh_batch(
		deadline_usec: int = 0, max_plan_items: int = 0) -> bool:
	return RendererDetailScatter._start_next_detail_refresh_batch(self, deadline_usec, max_plan_items)

func _drain_detail_refresh_queue() -> void:
	return RendererDetailScatter._drain_detail_refresh_queue(self)

func _drain_one_detail_family_upload() -> bool:
	return RendererDetailScatter._drain_one_detail_family_upload(self)

func _drain_one_vegetation_family_upload() -> bool:
	return RendererDetailScatter._drain_one_vegetation_family_upload(self)

func _detail_family_upload_has_pending_source(key: String) -> bool:
	return RendererDetailScatter._detail_family_upload_has_pending_source(self, key)

func detail_scatter_refresh_report() -> Dictionary:
	return RendererDetailScatter.detail_scatter_refresh_report(self)

func _oldest_visible_detail_task_wait_ms() -> int:
	return RendererDetailScatter._oldest_visible_detail_task_wait_ms(self)

func detail_scatter_layer_reports() -> Array:
	return RendererDetailScatter.detail_scatter_layer_reports(self)

func _detail_total_instance_budget() -> int:
	return RendererDetailScatter._detail_total_instance_budget(self)

func _detail_budget_fraction_needs_apply(next_fraction: float) -> bool:
	return RendererDetailScatter._detail_budget_fraction_needs_apply(self, next_fraction)

func _begin_detail_budget_apply(fraction: float) -> void:
	return RendererDetailScatter._begin_detail_budget_apply(self, fraction)

func _note_detail_budget_applied_view() -> void:
	return RendererDetailScatter._note_detail_budget_applied_view(self)

func _detail_budget_view_moved() -> bool:
	return RendererDetailScatter._detail_budget_view_moved(self)

func _apply_detail_budget_to_layer(layer, fraction: float) -> bool:
	return RendererDetailScatter._apply_detail_budget_to_layer(self, layer, fraction)

func _drain_detail_budget_apply(force_complete: bool) -> void:
	return RendererDetailScatter._drain_detail_budget_apply(self, force_complete)

func _apply_detail_global_budget(force_complete: bool = false, allow_apply: bool = true) -> void:
	return RendererDetailScatter._apply_detail_global_budget(self, force_complete, allow_apply)

func detail_scatter_budget_report() -> Dictionary:
	return RendererDetailScatter.detail_scatter_budget_report(self)

func _mark_detail_budget_total_dirty() -> void:
	return RendererDetailScatter._mark_detail_budget_total_dirty(self)

func _log_detail_scatter_rebuild_summary(reason: String) -> void:
	return RendererDetailScatter._log_detail_scatter_rebuild_summary(self, reason)

# ─── web / 移动端植被降档 ────────────────────────────────────────────────
const WEB_MOBILE_DETAIL_LAYER_KEEP_RATIO: float = RendererDetailLayers.WEB_MOBILE_DETAIL_LAYER_KEEP_RATIO
const DETAIL_LOADING_LAYERS_PER_YIELD: int = RendererDetailLayers.DETAIL_LOADING_LAYERS_PER_YIELD
const DETAIL_LOADING_YIELD_BUDGET_MS: float = RendererDetailLayers.DETAIL_LOADING_YIELD_BUDGET_MS
const DEFERRED_DETAIL_FILL_RESCUE_SECONDS: float = RendererDetailLayers.DEFERRED_DETAIL_FILL_RESCUE_SECONDS

# 受限平台判定覆盖：-1 = 跟随引擎特性；0 = 强制桌面；1 = 强制受限平台。
# 只给临时验证脚本 / A-B 调试用，正常游戏流程不会改它。
var _force_platform_limited_render: int = -1
var _deferred_fill_watchdog_msec: int = 0
var _deferred_fill_rescued: bool = false
# 保留比例运行期覆盖：<0 = 用常量 WEB_MOBILE_DETAIL_LAYER_KEEP_RATIO。
# 只给临时验证脚本 / A-B 调试用，正常流程不会改它。
var _web_mobile_layer_keep_ratio_override: float = -1.0



func set_force_platform_limited_render(value: int) -> void:
	return RendererDetailLayers.set_force_platform_limited_render(self, value)

func _platform_limited_vegetation_render() -> bool:
	return RendererDetailLayers._platform_limited_vegetation_render(self)

func _web_mobile_layer_keep_ratio() -> float:
	return RendererDetailLayers._web_mobile_layer_keep_ratio(self)

func _detail_profiles() -> Array:
	return RendererDetailLayers._detail_profiles(self)

func _select_platform_limited_detail_profiles(layers: Array) -> Array:
	return RendererDetailLayers._select_platform_limited_detail_profiles(self, layers)

func _using_default_layers() -> bool:
	return RendererDetailLayers._using_default_layers(self)

func _spawn_detail_layers() -> void:
	return RendererDetailLayers._spawn_detail_layers(self)

func _detail_layer_name(prof: Resource, i: int) -> String:
	return RendererDetailLayers._detail_layer_name(self, prof, i)

func _rebuild_detail_layers_if_default() -> void:
	return RendererDetailLayers._rebuild_detail_layers_if_default(self)

func set_world_ext(ext) -> void:
	return RendererSceneServices.set_world_ext(self, ext)


func _poll_shader_hot_reload(delta: float) -> void:
	return RendererSceneServices._poll_shader_hot_reload(self, delta)

func _refresh_shader_hot_reload_baseline() -> void:
	return RendererSceneServices._refresh_shader_hot_reload_baseline(self)

func _file_modified_time(path: String) -> int:
	return RendererSceneServices._file_modified_time(self, path)

# ─── 对外接口 ────────────────────────────────────────────────────────────

func set_map(map: MapData, world: WorldData = null) -> void:
	RendererSceneServices.set_map(self, map, world)

func set_map_cooperative(map: MapData, world: WorldData = null) -> void:
	await RendererSceneServices.set_map_cooperative(self, map, world)

func configure_building_visuals(catalog: Dictionary,
		intel: BuildingVisualIntelCache) -> Dictionary:
	return RendererSceneServices.configure_building_visuals(self, catalog, intel)

func set_resource_visual_context(fog_enabled: bool, seed_value: int = 0) -> void:
	RendererSceneServices.set_resource_visual_context(self, fog_enabled, seed_value)

func set_resource_visual_filter(stable_id: String) -> void:
	RendererSceneServices.set_resource_visual_filter(self, stable_id)

func set_resource_visual_lens(enabled: bool) -> void:
	RendererSceneServices.set_resource_visual_lens(self, enabled)

func resource_visual_lens_enabled() -> bool:
	return RendererSceneServices.resource_visual_lens_enabled(self)

func resource_visual_diagnostics() -> Dictionary:
	return RendererSceneServices.resource_visual_diagnostics(self)

func update_building_visual_intel(intel: BuildingVisualIntelCache,
		changed_cells: PackedInt32Array) -> void:
	RendererSceneServices.update_building_visual_intel(self, intel, changed_cells)

func _expand_building_detail_refresh_cells(
		changed_cells: PackedInt32Array) -> PackedInt32Array:
	return RendererSceneServices._expand_building_detail_refresh_cells(self, changed_cells)

func building_visual_diagnostics() -> Dictionary:
	return RendererSceneServices.building_visual_diagnostics(self)

func building_settlement_core_bucket(cell_idx: int) -> int:
	return RendererSceneServices.building_settlement_core_bucket(self, cell_idx)

func get_world_bounds() -> Rect2:
	return RendererSceneServices.get_world_bounds(self)

func country_border_layer() -> Node2D:
	return RendererSceneServices.country_border_layer(self)

func fog_of_war_layer() -> FogOfWarLayer:
	return RendererSceneServices.fog_of_war_layer(self)

func set_fog_of_war_enabled(enabled: bool, early_out: bool = false) -> void:
	RendererSceneServices.set_fog_of_war_enabled(self, enabled, early_out)

func is_fog_of_war_enabled() -> bool:
	return RendererSceneServices.is_fog_of_war_enabled(self)

func _push_fog_uniforms() -> void:
	RendererSceneServices._push_fog_uniforms(self)

func _effective_fog_early_out() -> bool:
	return RendererSceneServices._effective_fog_early_out(self)

func _apply_fog_early_out() -> void:
	RendererSceneServices._apply_fog_early_out(self)

func set_season_phase(phase: float) -> void:
	RendererSceneServices.set_season_phase(self, phase)

func set_climate_anomaly(v: float) -> void:
	RendererSceneServices.set_climate_anomaly(self, v)

func set_true_insolation_enabled(v: bool) -> void:
	RendererSceneServices.set_true_insolation_enabled(self, v)

func set_day_phase(v: float) -> void:
	RendererSceneServices.set_day_phase(self, v)

func set_tod_debug_sun_position(enabled: bool, uv: Vector2) -> void:
	RendererSceneServices.set_tod_debug_sun_position(self, enabled, uv)

func set_tod_debug_sun_height_scale(v: float) -> void:
	RendererSceneServices.set_tod_debug_sun_height_scale(self, v)

func set_visual_quality(q: int) -> void:
	RendererSceneServices.set_visual_quality(self, q)

func set_terrain_materials_enabled(enabled: bool) -> void:
	RendererSceneServices.set_terrain_materials_enabled(self, enabled)

func pixel_world_size() -> float:
	return RendererCameraDetail.pixel_world_size(self)

func pixel_scale_report() -> Dictionary:
	return RendererCameraDetail.pixel_scale_report(self)

func _refresh_pixel_world_size() -> float:
	return RendererCameraDetail._refresh_pixel_world_size(self)

func set_camera_zoom(value: float) -> void:
	return RendererCameraDetail.set_camera_zoom(self, value)

func set_camera_view(world_rect: Rect2, center: Vector2, zoom_value: float) -> void:
	return RendererCameraDetail.set_camera_view(self, world_rect, center, zoom_value)

func _queue_missing_prefetch_detail_chunks() -> void:
	return RendererCameraDetail._queue_missing_prefetch_detail_chunks(self)

func _detail_chunk_center_from_cells(cells: PackedInt32Array) -> Vector2:
	return RendererCameraDetail._detail_chunk_center_from_cells(self, cells)

func _reactivate_deferred_detail_chunks() -> void:
	return RendererCameraDetail._reactivate_deferred_detail_chunks(self)

func _push_overlay_edge_transition_data() -> void:
	RendererTerrainHorizon._push_overlay_edge_transition_data(self)

func _push_terrain_horizon_uniforms() -> void:
	RendererTerrainHorizon._push_terrain_horizon_uniforms(self)

static func build_gi_horizon_lut(max_angle: float) -> PackedVector3Array:
	return RendererMapAssets.build_gi_horizon_lut(max_angle)


func _push_gi_strength_uniforms(sm: ShaderMaterial) -> void:
	return RendererTerrainHorizon._push_gi_strength_uniforms(self, sm)

func _push_gi_uniforms(sm: ShaderMaterial, tiled: bool, visual_tiles) -> void:
	return RendererTerrainHorizon._push_gi_uniforms(self, sm, tiled, visual_tiles)

func _maybe_bake_terrain_horizon_gpu() -> void:
	RendererTerrainHorizon._maybe_bake_terrain_horizon_gpu(self)

func _start_visual_tile_horizon_bake(world: WorldData) -> void:
	RendererTerrainHorizon._start_visual_tile_horizon_bake(self, world)

func _on_visual_tile_horizon_completed(world: WorldData, generation_id: int,
		success: bool, report: Dictionary) -> void:
	return RendererTerrainHorizon._on_visual_tile_horizon_completed(self, world, generation_id, success, report)

func _run_visual_tile_horizon_fallback(world: WorldData, generation_id: int,
		compute_report: Dictionary) -> void:
	await RendererTerrainHorizon._run_visual_tile_horizon_fallback(self, world, generation_id, compute_report)

func _global_map_index_bytes(world: WorldData) -> PackedByteArray:
	return RendererTerrainHorizon._global_map_index_bytes(self, world)

func _publish_visual_tile_horizon(world: WorldData, report: Dictionary) -> void:
	RendererTerrainHorizon._publish_visual_tile_horizon(self, world, report)

func _record_visual_tile_horizon_failure(world: WorldData, reason: String,
		compute_report: Dictionary) -> void:
	return RendererTerrainHorizon._record_visual_tile_horizon_failure(self, world, reason, compute_report)

func _start_terrain_horizon_bake(world: WorldData, params: Dictionary) -> void:
	RendererTerrainHorizon._start_terrain_horizon_bake(self, world, params)

func _on_terrain_horizon_frame_drawn() -> void:
	RendererTerrainHorizon._on_terrain_horizon_frame_drawn(self)

func _dispose_horizon_bake_vp() -> void:
	RendererTerrainHorizon._dispose_horizon_bake_vp(self)

func set_terrain_horizon_strength(v: float) -> void: RendererTerrainHorizon.set_terrain_horizon_strength(self, v)

func set_terrain_horizon_softness(v: float) -> void: RendererTerrainHorizon.set_terrain_horizon_softness(self, v)

func set_terrain_horizon_max_angle(v: float) -> void: RendererTerrainHorizon.set_terrain_horizon_max_angle(self, v)

func set_terrain_horizon_cast_floor(v: float) -> void: RendererTerrainHorizon.set_terrain_horizon_cast_floor(self, v)

func set_terrain_horizon_debug_view(v: int) -> void: RendererTerrainHorizon.set_terrain_horizon_debug_view(self, v)

var _shader_disabled_by_toggle: bool = false

func toggle_world_shader_disabled() -> bool: return RendererTerrainHorizon.toggle_world_shader_disabled(self)

func is_world_shader_disabled() -> bool: return RendererTerrainHorizon.is_world_shader_disabled(self)

func set_ecology_visual_quality(q: int) -> void: RendererTerrainHorizon.set_ecology_visual_quality(self, q)

func set_ecology_visual_strength(v: float) -> void: RendererTerrainHorizon.set_ecology_visual_strength(self, v)

func set_temperature_visual_strength(v: float) -> void: RendererTerrainHorizon.set_temperature_visual_strength(self, v)

func set_moisture_visual_strength(v: float) -> void: RendererTerrainHorizon.set_moisture_visual_strength(self, v)

func set_vitality_visual_strength(v: float) -> void: RendererTerrainHorizon.set_vitality_visual_strength(self, v)

func set_snowline_visual_strength(v: float) -> void: RendererTerrainHorizon.set_snowline_visual_strength(self, v)

func set_debug_force_dyn_snow_only(v: bool) -> void: RendererTerrainHorizon.set_debug_force_dyn_snow_only(self, v)

func set_dyn_atlas_upload_stride(v: int) -> void: RendererTerrainHorizon.set_dyn_atlas_upload_stride(self, v)

func set_foliage_density_strength(v: float) -> void: RendererTerrainHorizon.set_foliage_density_strength(self, v)

func set_day_night_enabled(v: bool) -> void: return RendererWeatherState.set_day_night_enabled(self, v)

# debug=true 时 shader 水分支把流线振幅拉大 2.5× 并叠加方向提示色；
# 任务 9：ocean_current_debug toggle，F6 快捷键 / UI 顶栏按钮均写这里。
# 方案 0：upwelling_tex 仅本开关 true 时使用——首次开启时通过 MapBaker.rebake_upwelling_tex_for_debug
# lazy 烘焙一张并 set_shader_parameter；关闭时不做反向清理（保留贴图，避免来回切动反复 bake）。
var _ocean_current_debug: bool = false
# 外部注入：debug 开启时用来 lazy bake upwelling_tex。null 时跳过 bake，shader 也不会读到
# 这张贴图（保持 uniform 默认黑纹理，调试覆盖层全屏中性，与未启用 debug 视觉一致但无方向提示）。
var _map_baker = null

func set_map_baker(b) -> void: return RendererShaderWater.set_map_baker(self, b)

func set_ocean_current_debug(v: bool) -> void:
	return RendererShaderWater.set_ocean_current_debug(self, v)

func get_ocean_current_debug() -> bool:
	return RendererShaderWater.get_ocean_current_debug(self)

func set_extreme_weather_ground_effect_enabled(v: bool) -> void:
	return RendererWeatherState.set_extreme_weather_ground_effect_enabled(self, v)

func set_perf_sampler_enabled(v: bool) -> void:
	return RendererWeatherState.set_perf_sampler_enabled(self, v)

func apply_tod(profile: TODProfile) -> void:
	return RendererWeatherState.apply_tod(self, profile)

func set_rain_density_boost_enabled(v: bool) -> void:
	return RendererWeatherState.set_rain_density_boost_enabled(self, v)

func set_cloud_tod_tint_enabled(v: bool) -> void:
	return RendererWeatherState.set_cloud_tod_tint_enabled(self, v)

func set_camera_pitch_deg(deg: float) -> void:
	return RendererWeatherState.set_camera_pitch_deg(self, deg)

func set_wind(dir: Vector2, strength: float) -> void:
	return RendererWeatherState.set_wind(self, dir, strength)

func set_weather_fronts(fronts: Array) -> void:
	return RendererWeatherState.set_weather_fronts(self, fronts)

func set_weather_field_texture(tex: Texture2D) -> void:
	return RendererWeatherState.set_weather_field_texture(self, tex)

func refresh_terrain_weather_field_tex() -> void:
	return RendererWeatherState.refresh_terrain_weather_field_tex(self)

func _on_weather_layer_visual_fronts_changed(fronts: Array) -> void:
	return RendererWeatherState._on_weather_layer_visual_fronts_changed(self, fronts)

func _push_weather_fronts_to_shader(fronts: Array) -> void:
	return RendererWeatherState._push_weather_fronts_to_shader(self, fronts)

func _update_detail_wind_field(fronts: Array, n: int) -> void:
	return RendererWeatherState._update_detail_wind_field(self, fronts, n)

func _front_intensity(front) -> float:
	return RendererWeatherState._front_intensity(self, front)

func _front_axis(front) -> Vector2:
	return RendererWeatherState._front_axis(self, front)

func _front_precip_amount(front) -> float:
	return RendererWeatherState._front_precip_amount(self, front)

func _rebuild() -> void:
	return RendererMaterialPublish._rebuild(self)

func _push_cell_lut_dims(sm: ShaderMaterial, dims: Vector2i) -> void:
	return RendererMaterialPublish._push_cell_lut_dims(self, sm, dims)

func _sync_cell_lut_dims() -> void:
	return RendererMaterialPublish._sync_cell_lut_dims(self)

func _sync_cell_lut_textures() -> void:
	return RendererMaterialPublish._sync_cell_lut_textures(self)

func _apply_cell_lut_rebind(lut_name: String, world_tex: Texture2D) -> void:
	return RendererMaterialPublish._apply_cell_lut_rebind(self, lut_name, world_tex)

func _wrap_period_x() -> float:
	return RendererTerrainHorizon._wrap_period_x(self)

func land_water_split_diagnostics() -> Dictionary:
	return RendererTerrainHorizon.land_water_split_diagnostics(self)

func _set_world_quad_mesh(mesh: Mesh) -> void:
	RendererTerrainHorizon._set_world_quad_mesh(self, mesh)

func _apply_world_quad_geometry() -> void:
	RendererTerrainHorizon._apply_world_quad_geometry(self)

func _build_coverage_meshes(bounds: Rect2, wrap_period_x: float) -> Dictionary:
	return RendererTerrainHorizon._build_coverage_meshes(self, bounds, wrap_period_x)

func _build_world_quad_mesh(bounds: Rect2, wrap_period_x: float = 0.0) -> Mesh:
	return RendererMapAssets._build_world_quad_mesh(bounds, wrap_period_x)

func _push_visual_tile_layout_uniforms(material: ShaderMaterial, layout) -> void:
	RendererTerrainHorizon._push_visual_tile_layout_uniforms(self, material, layout)

func _apply_uniforms() -> void:
	return RendererMaterialPublish._apply_uniforms(self)

func _push_vegetation_season_lut() -> void:
	return RendererMaterialPublish._push_vegetation_season_lut(self)

func set_biome_tex_only(world: WorldData) -> void:
	return RendererMaterialPublish.set_biome_tex_only(self, world)

func set_cover_tex_only(world: WorldData) -> void:
	return RendererMaterialPublish.set_cover_tex_only(self, world)

func set_vegetation_tex_only(world: WorldData) -> void:
	return RendererMaterialPublish.set_vegetation_tex_only(self, world)

func debug_sea_ice_probe(cell) -> Dictionary:
	return RendererSeaIceDiagnostics.debug_sea_ice_probe(_world, _map, cell)

func _setup_loading_vegetation_layer(layer: ShrubLayer) -> void:
	await RendererLoadingVegetation._setup_loading_vegetation_layer(self, layer)

func _rebuild_cooperative() -> void:
	await RendererLoadingVegetation._rebuild_cooperative(self)

func _setup_loading_vegetation_layers_for_deferred_fill() -> int:
	return await RendererLoadingVegetation._setup_loading_vegetation_layers_for_deferred_fill(self)

func _setup_loading_vegetation_layer_deferred(layer: ShrubLayer) -> void:
	RendererLoadingVegetation._setup_loading_vegetation_layer_deferred(self, layer)

func _setup_loading_vegetation_layer_cooperative(layer: ShrubLayer) -> void:
	await RendererLoadingVegetation._setup_loading_vegetation_layer_cooperative(self, layer)

func _defer_vegetation_layers_after_bind() -> void:
	await RendererLoadingVegetation._defer_vegetation_layers_after_bind(self)

func _seed_deferred_detail_chunks_for_deferred_fill() -> void:
	RendererLoadingVegetation._seed_deferred_detail_chunks_for_deferred_fill(self)

func _detail_chunk_probe_layer():
	return RendererLoadingVegetation._detail_chunk_probe_layer(self)

func _arm_deferred_detail_fill_watchdog() -> void:
	return RendererLoadingVegetation._arm_deferred_detail_fill_watchdog(self)

func _poll_deferred_detail_fill_watchdog() -> void:
	return RendererLoadingVegetation._poll_deferred_detail_fill_watchdog(self)
