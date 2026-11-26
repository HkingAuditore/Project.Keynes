# hex_renderer.gd v5
# 单一全屏 quad mesh + WorldData 的 4 张高分辨率纹理 + world_map.gdshader v5。
class_name HexRenderer
extends "res://scripts/rendering/renderer_scene_settings.gd"
const RendererCameraDetail = preload("res://scripts/rendering/renderer_camera_detail.gd")
const RendererWeatherState = preload("res://scripts/rendering/renderer_weather_state.gd")
const RendererLoadingVegetation = preload("res://scripts/rendering/renderer_loading_vegetation.gd")
const RendererMaterialPublish = preload("res://scripts/rendering/renderer_material_publish.gd")
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
## [cell-field 2026-11-18] 解析格界的 define 片段与项目设置键：预热清单（WebShaderWarmup）
## 与测试都从这里取，保证「预热 = 运行期」用的是同一行字节（不在预热文件里写宏字面量）。
const CELL_FIELD_DEFINE = RendererShaderWater.CELL_FIELD_DEFINE
const CELL_FIELD_SETTING = RendererShaderWater.CELL_FIELD_SETTING
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

const PK_WEB_TRIVIAL_WORLD_SHADER_PROBE := RendererWebPolicy.PK_WEB_TRIVIAL_WORLD_SHADER_PROBE
const PK_WEB_SKIP_DEFERRED_VEG_SEED := RendererWebPolicy.PK_WEB_SKIP_DEFERRED_VEG_SEED
const PK_WEB_ENABLE_WEATHER_LAYER := RendererWebPolicy.PK_WEB_ENABLE_WEATHER_LAYER
const RendererWebPolicy = preload("res://scripts/rendering/renderer_web_policy.gd")
var _camera_pitch: float = deg_to_rad(60.0)
var _wind_dir: Vector2 = Vector2(0.3, 1.0)
var _wind_strength: float = 0.15
var _apply_shader_clock: Callable
var _simulation_speed_multiplier: float = 1.0

var _world_quad: MeshInstance2D
const LandBaseCache = preload("res://scripts/rendering/land_base_cache.gd")
var _land_base_cache: LandBaseCache
var _graphics_details := preload("res://scripts/rendering/renderer_graphics_settings.gd").new()
var _shader_mat: ShaderMaterial
var _sky_background: Node
## 拆分绘制使用独立水面节点与材质，由 _apply_uniforms() 调用 _sync_water_quad() 管理。
var _water_quad: MeshInstance2D
var _ripple_table: RendererShaderWater.WaterRippleLattice
var _water_mat: ShaderMaterial
## 记录当前水面材质前缀。贴图布局或分档变更时据此判断是否重编。
var _water_variant_prefix: String = ""
var _forced_water_program_kind: String = ""
## 缓存第二遍绘制的编译失败，避免每次推送材质时重试。
var _water_pass_failed: bool = false
## 紧凑 Web 水面用 web_min。high（Web 高档）和 split（电脑、手机）复用地表材质参数。
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
const PK_WEB_HIDE_WORLD_QUAD := RendererWebPolicy.PK_WEB_HIDE_WORLD_QUAD
const PK_WEB_MINIMAL_LAYERS := RendererWebPolicy.PK_WEB_MINIMAL_LAYERS
const PK_WEB_LAYER_FOG := RendererWebPolicy.PK_WEB_LAYER_FOG
const PK_WEB_LAYER_BORDER := RendererWebPolicy.PK_WEB_LAYER_BORDER
const PK_WEB_LAYER_WEATHER := RendererWebPolicy.PK_WEB_LAYER_WEATHER
const PK_WEB_LAYER_BUILDING := RendererWebPolicy.PK_WEB_LAYER_BUILDING
const PK_WEB_DEFER_VEG_LAYERS := RendererWebPolicy.PK_WEB_DEFER_VEG_LAYERS
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

static func cell_field_setting_enabled() -> bool:
	return RendererWebPolicy.cell_field_setting_enabled()

## [cell-field 2026-11-18] 项目设置只作为**初值**来源：部署期配置决定默认，运行期权威
## 仍是 export 变量（GM 面板要能双向热切，见 terrain_cell_field_enabled 的注释）。
## 放在 _init 而不是 _ready：_ready 时 set_map / shader 装配已经开始，改开关会与
## 首帧的变体装配抢时序。此处的赋值命中 setter，但此时还不在树上，
## _apply_cell_field_enabled() 里的 _refresh_split_configuration() 会安全早退。
func _init() -> void:
	terrain_cell_field_enabled = cell_field_setting_enabled()

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
	if _ripple_table != null:
		RendererShaderWater.sync_ripple_lattice(self)

func _load_shader() -> void: return RendererSceneServices._load_shader(self)
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
func _water_program_prefix(kind: String) -> String: return RendererShaderWater._water_program_prefix(self, kind)
func _push_world_uniform(key: Variant, value: Variant) -> void: return RendererShaderWater._push_world_uniform(self, key, value)
func _global_sky_day_weight() -> float: return RendererShaderWater._global_sky_day_weight(self)
func configure_shader_clock(apply: Callable) -> void: return RendererShaderWater.configure_shader_clock(self, apply)
func _bind_world_lighting_profile() -> void: return RendererShaderWater._bind_world_lighting_profile(self)
func _push_world_lighting_profile() -> void: return RendererLightingBindings.push_world_lighting_profile(self)


func _shader_declares_uniform(shader: Shader, uniform_name: StringName) -> bool: return RendererShaderWater._shader_declares_uniform(self, shader, uniform_name)
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
func _desktop_sky_quality_prefix() -> String: return RendererShaderWater._desktop_sky_quality_prefix(self)
func _apply_shader_variant_prefix(shader: Shader, source_path: String) -> Shader: return RendererShaderWater._apply_shader_variant_prefix(self, shader, source_path)

var _mobile_quality_tier_define: String = ""

func set_mobile_quality_tier(tier_define: String) -> void: return RendererShaderWater.set_mobile_quality_tier(self, tier_define)
func _mobile_quality_tier_from_define(tier_define: String) -> int: return RendererShaderWater._mobile_quality_tier_from_define(self, tier_define)
func _shader_quality_define_prefix(tier_define: String) -> String: return RendererShaderWater._shader_quality_define_prefix(self, tier_define)
func _for_each_vegetation_layer(callable: Callable) -> void: return RendererShaderWater._for_each_vegetation_layer(self, callable)
func configure_trade_visuals(layer: TradeActivityLayer, world: WorldData) -> void: return RendererShaderWater.configure_trade_visuals(self, layer, world)
func configure_military_visuals(layer: MilitaryArmyTokenLayer) -> void: return RendererShaderWater.configure_military_visuals(self, layer)
func _sync_detail_and_activity_materials() -> void: return RendererShaderWater._sync_detail_and_activity_materials(self)
func set_simulation_speed_multiplier(multiplier: float) -> void: return RendererShaderWater.set_simulation_speed_multiplier(self, multiplier)
func set_clock_running(running: bool) -> void: return RendererShaderWater.set_clock_running(self, running)
func _effective_detail_enqueue_coalesce_ms() -> float: return RendererDetailScatter._effective_detail_enqueue_coalesce_ms(self)


func queue_detail_scatter_refresh(indices: PackedInt32Array) -> void: return RendererDetailScatter.queue_detail_scatter_refresh(self, indices)
func _detail_all_family_mask() -> int: return RendererDetailScatter._detail_all_family_mask(self)
func queue_detail_scatter_changes(changes) -> void: return RendererDetailScatter.queue_detail_scatter_changes(self, changes)
func _dedup_detail_refresh_indices(indices: PackedInt32Array) -> PackedInt32Array: return RendererDetailScatter._dedup_detail_refresh_indices(self, indices)
func _enqueue_detail_refresh_batches(indices: PackedInt32Array) -> void: return RendererDetailScatter._enqueue_detail_refresh_batches(self, indices)
func _reset_detail_refresh_plan() -> void:
	return RendererDetailScatter._reset_detail_refresh_plan(self)

func _start_next_detail_refresh_batch(
		deadline_usec: int = 0, max_plan_items: int = 0) -> bool:
	return RendererDetailScatter._start_next_detail_refresh_batch(self, deadline_usec, max_plan_items)

func _drain_detail_refresh_queue() -> void:
	return RendererDetailScatter._drain_detail_refresh_queue(self)

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

# 受限平台判定覆盖：-1 = 跟随引擎特性；0 = 强制桌面；1 = 强制受限平台。
# 只给临时验证脚本 / A-B 调试用，正常游戏流程不会改它。
var _force_platform_limited_render: int = -1
# 保留比例运行期覆盖：<0 = 用常量 WEB_MOBILE_DETAIL_LAYER_KEEP_RATIO。
# 只给临时验证脚本 / A-B 调试用，正常流程不会改它。
var _web_mobile_layer_keep_ratio_override: float = -1.0



func set_force_platform_limited_render(value: int) -> void:
	return RendererDetailLayers.set_force_platform_limited_render(self, value)

func _select_platform_limited_detail_profiles(layers: Array) -> Array:
	return RendererDetailLayers._select_platform_limited_detail_profiles(self, layers)

func _spawn_detail_layers() -> void:
	return RendererDetailLayers._spawn_detail_layers(self)

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

func set_graphics_details(settings: Dictionary) -> void:
	_graphics_details.apply(self, settings)

func set_terrain_render_scale(percent: int, msaa: Viewport.MSAA) -> void:
	_graphics_details.apply_terrain_scale(self, percent, msaa)

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


func _push_gi_uniforms(sm: ShaderMaterial, tiled: bool, visual_tiles) -> void:
	return RendererTerrainHorizon._push_gi_uniforms(self, sm, tiled, visual_tiles)

func _maybe_bake_terrain_horizon_gpu() -> void:
	RendererTerrainHorizon._maybe_bake_terrain_horizon_gpu(self)

func _on_visual_tile_horizon_completed(world: WorldData, generation_id: int,
		success: bool, report: Dictionary) -> void:
	return RendererTerrainHorizon._on_visual_tile_horizon_completed(self, world, generation_id, success, report)

func _run_visual_tile_horizon_fallback(world: WorldData, generation_id: int,
		compute_report: Dictionary) -> void:
	await RendererTerrainHorizon._run_visual_tile_horizon_fallback(self, world, generation_id, compute_report)

func _on_terrain_horizon_frame_drawn() -> void:
	RendererTerrainHorizon._on_terrain_horizon_frame_drawn(self)

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


func _sync_cell_lut_dims() -> void:
	return RendererMaterialPublish._sync_cell_lut_dims(self)

func _sync_cell_lut_textures() -> void:
	return RendererMaterialPublish._sync_cell_lut_textures(self)

func _wrap_period_x() -> float:
	return RendererTerrainHorizon._wrap_period_x(self)

func land_water_split_diagnostics() -> Dictionary:
	return RendererTerrainHorizon.land_water_split_diagnostics(self)

func _set_world_quad_mesh(mesh: Mesh) -> void:
	RendererTerrainHorizon._set_world_quad_mesh(self, mesh)

func _apply_world_quad_geometry() -> void:
	RendererTerrainHorizon._apply_world_quad_geometry(self)

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

func _setup_loading_vegetation_layer_cooperative(layer: ShrubLayer) -> void:
	await RendererLoadingVegetation._setup_loading_vegetation_layer_cooperative(self, layer)

func _defer_vegetation_layers_after_bind() -> void:
	await RendererLoadingVegetation._defer_vegetation_layers_after_bind(self)
