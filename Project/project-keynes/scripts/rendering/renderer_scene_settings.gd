extends Node2D

## Owns the renderer scene's serialized settings and their live material setters.

const RendererSceneServices = preload("res://scripts/rendering/renderer_scene_services.gd")
const RendererDetailLayers = preload("res://scripts/rendering/renderer_detail_layers.gd")
const RendererShaderWater = preload("res://scripts/rendering/renderer_shader_water.gd")
const RendererTerrainHorizon = preload("res://scripts/rendering/renderer_terrain_horizon.gd")

@export var hex_size: float = 22.0:
	set(v):
		hex_size = maxf(4.0, v)
		RendererSceneServices._after_hex_size(self)

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
@export_range(0.0, 1.0, 0.01) var cloud_shadow_strength_high: float = 0.62:
	set(value):
		cloud_shadow_strength_high = clampf(value, 0.0, 1.0)
		RendererShaderWater._push_cloud_shadow_tuning(self)
## PC 中画质合成 pass 的压暗比例。
@export_range(0.0, 1.0, 0.01) var cloud_shadow_strength_mid: float = 0.58:
	set(value):
		cloud_shadow_strength_mid = clampf(value, 0.0, 1.0)
		RendererShaderWater._push_cloud_shadow_tuning(self)
## PC 低画质、移动端和 Web 合成 pass 的压暗比例。
@export_range(0.0, 1.0, 0.01) var cloud_shadow_strength_low: float = 0.46:
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
## [cloud-tiling 2026-11-18] 云影噪声在**每个世界 wrap 周期**里铺几遍（整数）。
## 1 = 云团直径 3~5 格、整屏十来朵；2 = 云团减半、数量翻倍；再大就碎成斑点。
##
## 为什么必须整数：tile_period = wrap_period / repeat，只有整数除，接缝两侧才落到
## 同一 texel 上；非整数除会在东西 wrap 处错半格，出现一条竖向错位缝。
##
## 这个名字原来是 cloud_shadow_cell_scale（"独立云核密度"），但那个 uniform 从
## 2026-11-07 改成预烘噪声之后就一直没被 shader 读取 —— 也就是说以前调它完全
## 没有效果。现在它真的接到平铺上了。
@export_range(1.0, 8.0, 1.0) var cloud_shadow_tile_repeat: float = 1.0:
	set(value):
		cloud_shadow_tile_repeat = clampf(value, 1.0, 8.0)
		RendererShaderWater._push_cloud_shadow_tuning(self)
## 云体内部厚薄调制：0 = 云心是一个常数（放大看是一块铁板），1 = 最强。
## 本质是把中频 Worley 的"云胞内部厚 / 胞界薄"乘在最终密度上。
@export_range(0.0, 1.0, 0.05) var cloud_shadow_interior_detail: float = 0.45:
	set(value):
		cloud_shadow_interior_detail = clampf(value, 0.0, 1.0)
		RendererShaderWater._push_cloud_shadow_tuning(self)
## 云形采样的目标世界 texel（越大越柔、越小越锐）。实际 footprint 会再和
## field 像素的世界尺寸取大者，所以低画质/移动端低分辨率场不会因此走样。
@export_range(2.0, 24.0, 0.5) var cloud_shadow_detail_texel_world: float = 8.0:
	set(value):
		cloud_shadow_detail_texel_world = clampf(value, 1.0, 64.0)
		RendererShaderWater._push_cloud_shadow_tuning(self)
## 云影平流的世界尺度：只影响**漂移速度**，不改变云团大小（大小看 tile_repeat）。
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

# ─── Visual Overhaul（任务 1）：视觉总开关 ────────────────────────
# 这组变量由 main.gd 通过 set_*() 推进；shader 分支逐步在任务 3~9 中接入。
# 默认值与 main.gd 一致，保证 renderer 被单独调试时也有合理初值。
@export_group("Visual Overhaul")
@export_range(0, 2, 1) var visual_quality: int = 1
## A/B switch for the HIGH terrain material-array path. This is intentionally
## not exposed as a player-facing setting; false restores the legacy path.
var terrain_materials_enabled: bool = true
## 地表诊断视图 id（0 = 正常画面）。0..17 为既有视图，18..23 是
## [cell-field 2026-11-18] 新增的六个解析格界对照视图（只在 PK_CELL_FIELD 变体里编得出来）：
##   18 = dom 一致性（解析格归属 vs 烘焙 map_index，不一致处标红）
##   19 = 三格权重 RGB（权重直接上屏，看对偶三角是否连续）
##   20 = gap 差值（解析 gap vs edge_distance.R）
##   21 = warp 可视化（扭曲场 rg → 屏幕向量）
##   22 = dom offset 编码（R,G=col 低/高字节，B=row 低字节，A=1.0；
##        tests/world/cell_field_gpu_parity_probe.gd 回读后逐像素与 DCHexCellField.dom_at 比对）
##   23 = 实际带宽 band 灰阶（band/0.86；经线接缝整列变白 = 导数取在已回绕坐标上的回归信号）
## 上限必须与 clampi、GM 面板条目、shader 里的 `terrain_surface_debug_view == 2x` 同步改。
@export_range(0, 23, 1) var terrain_surface_debug_view: int = 0:
	set(value):
		var was_split := RendererShaderWater._split_active(self)
		terrain_surface_debug_view = clampi(value, 0, 23)
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

## [cell-field 2026-11-18] 解析格界总开关（方案 §3.10「一个 define + 一个导出开关」）。
## **出货默认开**（2026-11-18 第二轮末尾打开；`project.godot` 里显式写 true）。
## 关闭时 shader 前缀一个字节都不变 ⇒ 与加这套功能之前逐像素一致，这是回退保证。
## 作用域 = 桌面 Vulkan / 移动 **+ Web / 桌面 Compatibility**：后者要先过 boot 自检
## （`cell_field_boot_allows()`），自检不过自动退回旧路径并在 `Engine` meta 里记 fail。
## 两个口：
##   · 项目设置 project_keynes/rendering/map_tiles/terrain_cell_field_enabled —— 部署期
##     默认值，_init() 读它作为本变量的初值（"setting + export" 惯例）；
##   · 本变量 —— 运行期权威，GM 面板 / 远程 inspector 可热切。
## 切换会重编 shader 变体（define 是编译期的）：见 RendererShaderWater._apply_cell_field_enabled()。
@export var terrain_cell_field_enabled: bool = true:
	set(value):
		if terrain_cell_field_enabled == value:
			return
		terrain_cell_field_enabled = value
		RendererShaderWater._apply_cell_field_enabled(self)

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
		RendererShaderWater._for_each_vegetation_layer(self, func(layer: ShrubLayer) -> void:
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
