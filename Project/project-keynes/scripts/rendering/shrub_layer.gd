class_name ShrubLayer
extends Node2D

const ShrubFullRebuild = preload("res://scripts/rendering/shrub_full_rebuild.gd")
const ShrubLodPolicy = preload("res://scripts/rendering/shrub_lod_policy.gd")
const VegetationLodFractions = preload("res://scripts/rendering/vegetation_lod_fractions.gd")
const VegetationNodeLifecycle = preload("res://scripts/rendering/vegetation_node_lifecycle.gd")
const VegetationShaderVariants = preload("res://scripts/rendering/vegetation_shader_variants.gd")
const ShrubScatter = preload("res://scripts/rendering/shrub/scatter.gd")
const Lifecycle = preload("res://scripts/rendering/shrub/lifecycle.gd")
const Diagnostics = preload("res://scripts/rendering/shrub/diagnostics.gd")
const Material_inputs = preload("res://scripts/rendering/shrub/material_inputs.gd")
const Cooperative_rebuild = preload("res://scripts/rendering/shrub/cooperative_rebuild.gd")
const Family_materials = preload("res://scripts/rendering/shrub/family_materials.gd")
const Chunk_nodes = preload("res://scripts/rendering/shrub/chunk_nodes.gd")
const Chunk_budget = preload("res://scripts/rendering/shrub/chunk_budget.gd")
const Chunk_refresh = preload("res://scripts/rendering/shrub/chunk_refresh.gd")

# Kept on the host for the existing ShrubLayer API; the values are authored by
# the stateless collaborators.
const PK_WEB_ENABLE_VEG_NEAR_FORMS = Material_inputs.PK_WEB_ENABLE_VEG_NEAR_FORMS
const PK_WEB_VEG_NEAR_FULL_FORMS = Material_inputs.PK_WEB_VEG_NEAR_FULL_FORMS
const _SHADOW_BUFFER_STRIDE = Chunk_nodes._SHADOW_BUFFER_STRIDE
const DECORATION_VEG_RESIDUAL = ShrubScatter.DECORATION_VEG_RESIDUAL


const _WT_RAIN := 1
const _WT_STORM := 2
const _WT_BLIZZARD := 3
const _WT_DROUGHT := 4
const _WT_HEATWAVE := 6
const _WT_MONSOON := 7
const DEFAULT_PROFILE := preload("res://data/visual/shrub_default.tres")
const ProfileScript := preload("res://scripts/data/shrub_visual_profile.gd")
const VegetationProfileRegistryScript := preload("res://scripts/data/vegetation_profile_registry.gd")
const DETAIL_SHRUB := 0
const DETAIL_TREE := 1
const DETAIL_GRASS := 2
# vegetation-visual-pcg 阶段 B：扩充 archetype。3..7 = 植被类（走植被 suitability +
# archetype 亲和），8..10 = 点缀/地貌类（走独立 _decoration_suitability，不依赖植被权重）。
const DETAIL_CONIFER := 3
const DETAIL_PALM := 4
const DETAIL_CACTUS := 5
const DETAIL_REED := 6
const DETAIL_ALPINE_FLOWER := 7
const DETAIL_ROCK := 8
const DETAIL_SNOW_MOUND := 9
const DETAIL_DEAD_SNAG := 10
const ROT_RANDOM_FULL := 0
const ROT_UPRIGHT := 1
const ROT_UPRIGHT_JITTER := 2
const SPAWN_LAND := 0
const SPAWN_WATER := 1
const SPAWN_ANY := 2

const IMPOSTOR_QUAD_HALF := 0.62
const SUB_FORM_SINGLE := 0
const SUB_FORM_CLUSTER := 1
const SUB_FORM_GROVE := 2
const FORM_COUNT_MAX := 32
# Element patches reach 0.88 of the quad; same-cell patches may overlap by 28%.
const SUB_FORM_PATCH_RADIUS := 0.88
const SUB_FORM_OVERLAP := 0.72

static var _mesh_cache: Dictionary = {}
static var _shared_offset_is_water_cache: Dictionary = {}


# custom.a of every instance: sub_form + (count - 0.5) / 32. Decoded by
# vegetation_impostor.gdshaderinc; family batches add style_id * 4 on top.
static func pack_form(sub_form: int, count: int) -> float:
	var n := clampi(count, 1, FORM_COUNT_MAX)
	return float(clampi(sub_form, 0, 3)) + (float(n) - 0.5) / float(FORM_COUNT_MAX)


static func unpack_form_count(packed: float) -> int:
	var local := fposmod(packed, 4.0)
	return int(floor((local - floor(local)) * float(FORM_COUNT_MAX))) + 1


static func unpack_sub_form(packed: float) -> int:
	return int(floor(fposmod(packed, 4.0)))


# Crown radius in quad-local units [-1, 1]; mirrors vf_elem_radius().
static func crown_local_radius(count: int) -> float:
	if count <= 1:
		return 0.80
	return minf(0.58, 0.88 / sqrt(float(count)))

# Body pass: a single quad per instance drawn as a top-down procedural form.
# The shader lives in shaders/include/vegetation_impostor.gdshaderinc so the
# family batches and every source layer compile exactly the same code.
const _SHADER_CODE = VegetationShaderVariants._SHADER_CODE

# Cast-shadow pass: soft sun-stretched ellipse per instance (unit-disc mesh).
const _SHADOW_SHADER_CODE = VegetationShaderVariants._SHADOW_SHADER_CODE

@export var profile: Resource = DEFAULT_PROFILE:
	set(value):
		profile = value if value != null else DEFAULT_PROFILE
		Material_inputs._apply_profile_uniforms(self)
		if is_inside_tree() and _map != null:
			Material_inputs._rebuild_or_defer(self)

var _map: MapData = null
var _world: WorldData = null
var _bounds: Rect2 = Rect2()
var _hex_size: float = 22.0
var _visual_quality: int = 1
var _density_detail := -1
var _mobile_quality_tier: int = 1
var _cloud_shadow_direct := false
var _cloud_shadow_texture: Texture2D
var _cloud_shadow_wrap_origin_uv := 0.0
var _cloud_shadow_wrap_period_uv := 0.0
# C++ DCWorldExt（由 hex_renderer.set_world_ext 注入）。null 或缺 encode_detail_scatter
# 方法时，散布生成走 GDScript fallback；二者结果是同一确定性 PCG 场的等价实现。
var _world_ext = null
# LOD 前缀排序下沉原生 encode 的 A-B 开关：true = encode_detail_scatter 返回已按
# _lod_order_sources 语义排好序的 buffer + far_count，apply 直接上传；false（或旧
# DLL 缺 lod_ordered 键）走 GDScript 复刻排序兜底，两条路径语义同一契约。
var native_lod_order_enabled := true:
	set(value):
		native_lod_order_enabled = value
		_native_delta_common_knobs = {}
# 上一次 _rebuild_instances 实际走的路径（"gdext" / "gdscript"），供调试/性能日志。
var _last_scatter_path: String = "none"
var _last_rebuild_ms: float = 0.0
var _last_candidate_count: int = 0
var _settlement_core_buckets := PackedByteArray()
var _eternal_min_elevation_rad: float = deg_to_rad(10.0)
var _eternal_max_hour_angle_rad: float = deg_to_rad(70.0)
var _family_materials: Array = []

# Settlement core envelope mirrors the building density ladder without copying
# individual building transforms.  The outer archetype ring is 0.54 hex and
# the authored building half-width is 0.85 * baker_scale * visual_scale.
# Keep these constants in sync with world_ext_detail.cpp.
const SETTLEMENT_BUILDING_SPREAD_MIN := 0.16
const SETTLEMENT_BUILDING_SPREAD_MAX := 1.15
const SETTLEMENT_BUILDING_SCALE_MIN := 0.60
const SETTLEMENT_BUILDING_SCALE_MAX := 1.125
const SETTLEMENT_BUILDING_VISUAL_SCALE := 0.144
const SETTLEMENT_OUTER_RING_FACTOR := 0.54
const SETTLEMENT_ART_HALF_WIDTH := 0.85
# The largest detail lobes extend about 0.84 local units from their instance
# origin. Include that footprint so a tree centre outside the core cannot still
# paint its canopy over a building.
const SETTLEMENT_DETAIL_FOOTPRINT_RADIUS := 0.85


func set_settlement_core_buckets(value: PackedByteArray) -> void:
	return Lifecycle.set_settlement_core_buckets(self, value)

var _last_wrap_edge_copy_count: int = 0
var _last_rebuild_reason: String = ""
var _last_incremental_cells: int = 0
var _last_incremental_missing_slots: int = 0
var _last_incremental_dropped_instances: int = 0
var _last_dirty_chunks: int = 0
var _last_native_sampled_cells: int = 0
var _last_native_active_cells: int = 0
var _last_native_water_cache_ms: float = 0.0
var _last_native_context_ms: float = 0.0
var _last_native_knobs_ms: float = 0.0
var _last_native_call_ms: float = 0.0
var _last_native_apply_ms: float = 0.0
var _last_cache_update_ms: float = 0.0
var _last_assemble_ms: float = 0.0
var _cell_instance_lookup: Dictionary = {}
var _native_offset_is_water_cache: PackedByteArray = PackedByteArray()
var _native_offset_cache_dims: Vector2i = Vector2i.ZERO
var _native_veg_climate_tables: Dictionary = {}
var _native_delta_common_knobs: Dictionary = {}
var _chunked_multimesh_enabled: bool = true
var _chunk_size_cells: int = 8
var _chunk_nodes: Dictionary = {}
## chunk_id -> {cell_idx: PackedFloat32Array}。生态变化只替换 dirty cell，
## 随后按稳定 cell 顺序装配一次 chunk buffer；不重新采样其余格。
var _chunk_cell_payloads: Dictionary = {}
## chunk_id -> 已按稳定 LOD 顺序装配的 payload。family renderer 在 source task
## 完成后会再次读取同一 chunk；缓存可避免第二次排序、分簇和整块复制。
var _chunk_assembled_payloads: Dictionary = {}
## 地图几何在运行期不变。可见性查询复用 cell 列表与包围盒，避免每层每帧重新
## cube/offset 转换并扫描整个 superchunk。
var _chunk_cell_indices_cache: Dictionary = {}
var _chunk_world_bounds_cache: Dictionary = {}
var _chunk_cell_cache_builds: int = 0
var _chunk_bounds_cache_builds: int = 0
var _active_instance_count_cache: int = 0
var _active_instance_count_valid: bool = false
var _active_instance_count_scans: int = 0
var _defer_initial_rebuild := false
var _chunk_dormant_since_msec: Dictionary = {}
var _chunk_wrap_nodes: Dictionary = {}
var _chunk_instance_counts: Dictionary = {}
var _chunk_far_instance_counts: Dictionary = {}

var _mmi: MultiMeshInstance2D = null
var _multimesh: MultiMesh = null
var _material: ShaderMaterial = null
## [veg-fog-knowledge 2026-11-18] 当前 enum_lut（知识度表）引用，用于每帧廉价比较：
## 世界烘完前 set_world_material_inputs 会把参数绑成空纹理，之后对象变了也没人补，
## 结果植被永远判成"可见"、知识度淡出完全不生效。
var _enum_lut_bound: Texture2D = null
var _single_wrap_nodes: Array[MultiMeshInstance2D] = []

# [veg-cast-shadow] 投影 pass：专用「软边椭圆 blob」网格（不复用植株多裂片网格——复用会按各裂片
# 高度剪切拉开 → 形状怪 + 硬边）。顶点把单位圆映射为沿太阳背光方向拉伸的椭圆，片元用径向 alpha
# 柔边。分块模式用 _shadow_chunk_nodes 逐 chunk 镜像（见下）；单节点回退用下面这组。
var _shadow_material: ShaderMaterial = null
var _shadow_mmi: MultiMeshInstance2D = null
var _shadow_multimesh: MultiMesh = null
var _shadow_blob_mesh: ArrayMesh = null
# [veg-cast-shadow perf] 投影与植株「逐 chunk 镜像」：每个植株 chunk 配一个 shadow chunk 节点
# （blob 网格 + 低 z + shadow 材质），buffer 直接镜像对应植株 chunk。演替只重写「脏 chunk」的
# buffer → 投影同步成本 = O(该 chunk)，与植株自身更新同阶（不再全图 O(total) 重传）。方向/长度/
# 强度/尺寸全部在顶点着色器里按 TOD 太阳方位实时计算（GPU），CPU 不写这些量；太阳移动零 CPU 开销。
# _shadow_multimesh/_shadow_mmi 仅用于「单节点(非分块)回退模式」。
var _shadow_chunk_nodes: Dictionary = {}
var _shadow_chunk_wrap_nodes: Dictionary = {}
var _single_shadow_wrap_nodes: Array[MultiMeshInstance2D] = []
var _shadow_built_total: int = 0   # 单节点回退模式：上次镜像的实例数（用于按需重建）
var _shadow_fraction: float = 1.0
var _shadow_strength_base: float = 0.32
var _camera_zoom: float = 1.0
var _camera_zoom_initialized: bool = false
var _camera_lod_hidden: bool = false
var _lod_alpha: float = 1.0
var _lod_zoom_t: float = 1.0
var _lod_far_visible_fraction: float = 1.0
var _camera_view_rect: Rect2 = Rect2()
var _camera_prefetch_rect: Rect2 = Rect2()
var _camera_view_center: Vector2 = Vector2.ZERO
var _camera_view_initialized: bool = false
var _visible_chunk_count: int = 0
var _prefetch_chunk_count: int = 0
var _family_style_id: int = 0
var _family_batch_suppressed: bool = false
var _zoom_visible_fraction: float = 1.0

var _instance_cell_indices: PackedInt32Array = PackedInt32Array()
var _instance_positions: PackedVector2Array = PackedVector2Array()
var _instance_rotations: PackedFloat32Array = PackedFloat32Array()
var _instance_sizes: PackedFloat32Array = PackedFloat32Array()
var _instance_seeds: PackedFloat32Array = PackedFloat32Array()
var _instance_variants: PackedFloat32Array = PackedFloat32Array()
var _instance_forms: PackedFloat32Array = PackedFloat32Array()
var _instance_scores: PackedFloat32Array = PackedFloat32Array()
var _instance_cells: Array = []
var _instance_count: int = 0
var _far_instance_count: int = 0



func _ready() -> void:
	return Lifecycle._ready(self)

func setup(map: MapData, world: WorldData, bounds: Rect2, hex_size: float, visual_quality: int = 1) -> void:
	return Lifecycle.setup(self, map, world, bounds, hex_size, visual_quality)

func set_defer_initial_rebuild(value: bool) -> void:
	return Lifecycle.set_defer_initial_rebuild(self, value)

func clear() -> void:
	return Lifecycle.clear(self)

func set_world_time(v: float) -> void:
	return Material_inputs.set_world_time(self, v)

func set_season_phase(v: float) -> void:
	return Material_inputs.set_season_phase(self, v)

func set_day_phase(v: float) -> void:
	return Material_inputs.set_day_phase(self, v)

func set_world_material_inputs(world: WorldData, bounds: Rect2, _use_cell_indirection: bool) -> void:
	return Material_inputs.set_world_material_inputs(self, world, bounds, _use_cell_indirection)

## [veg-fog-knowledge 2026-11-18] 知识度表的日常漂移补绑（enum_lut 每天重烘会换对象）。
func set_enum_lut_texture(tex: Texture2D) -> void:
	return Material_inputs.set_enum_lut_texture(self, tex)

func _visual_tiles_active() -> bool:
	return Material_inputs._visual_tiles_active(self)

func set_tod(_sun_color: Color, _ambient_color: Color, _night_factor: float, exposure: float) -> void:
	return Material_inputs.set_tod(self, _sun_color, _ambient_color, _night_factor, exposure)

func set_world_sky_lighting(source: ShaderMaterial) -> void:
	return Material_inputs.set_world_sky_lighting(self, source)

func set_tod_sun_dir(dir: Vector3) -> void:
	return Material_inputs.set_tod_sun_dir(self, dir)

func set_tod_debug_sun_position(enabled: bool, uv: Vector2) -> void:
	return Material_inputs.set_tod_debug_sun_position(self, enabled, uv)

func set_eternal_daylight_parameters(min_elevation: float, max_hour_angle: float) -> void:
	return Material_inputs.set_eternal_daylight_parameters(self, min_elevation, max_hour_angle)

func set_tod_debug_sun_height_scale(v: float) -> void:
	return Material_inputs.set_tod_debug_sun_height_scale(self, v)

func set_axial_tilt_rad(v: float) -> void:
	return Material_inputs.set_axial_tilt_rad(self, v)

func set_day_night_enabled(v: bool) -> void:
	return Material_inputs.set_day_night_enabled(self, v)

func set_wind_field(dir: Vector2, boost: float) -> void:
	return Material_inputs.set_wind_field(self, dir, boost)

func set_terrain_horizon_inputs(tex: Texture2D, bound: bool, strength: float, softness: float,
		max_angle: float, cast_floor: float, debug_view: int, coarse_normal_strength: float) -> void:
	return Material_inputs.set_terrain_horizon_inputs(self, tex, bound, strength, softness, max_angle, cast_floor, debug_view, coarse_normal_strength)

func set_terrain_gi_inputs(lut: PackedVector3Array, ao_strength: float, ao_floor: float,
		bent_strength: float, normal_floor: float) -> void:
	return Material_inputs.set_terrain_gi_inputs(self, lut, ao_strength, ao_floor, bent_strength, normal_floor)

func set_world_ext(ext) -> void:
	return Material_inputs.set_world_ext(self, ext)

func set_chunked_multimesh_enabled(enabled: bool, chunk_size_cells: int = 8) -> void:
	return Material_inputs.set_chunked_multimesh_enabled(self, enabled, chunk_size_cells)

func set_visual_quality(q: int) -> void:
	return Material_inputs.set_visual_quality(self, q)

func set_density_detail(detail: int) -> void:
	return Material_inputs.set_density_detail(self, detail)

func set_camera_zoom(value: float) -> void:
	return Lifecycle.set_camera_zoom(self, value)

func _family_far_fraction() -> float:
	return VegetationLodFractions._family_far_fraction(detail_render_family())


func _family_lod_fraction(zoom_value: float) -> float:
	return Lifecycle.family_lod_fraction(self, zoom_value)


func _family_lod_fraction_base(zoom_value: float) -> float:
	return VegetationLodFractions._family_lod_fraction_base(detail_render_family(), zoom_value)


func detail_render_family() -> int:
	return Family_materials.detail_render_family(self)

func detail_visual_form() -> int:
	return Family_materials.detail_visual_form(self)

func detail_style_shading() -> Dictionary:
	return Family_materials.detail_style_shading(self)

func detail_render_family_mask() -> int:
	return Family_materials.detail_render_family_mask(self)

func set_family_style_id(value: int) -> void:
	return Family_materials.set_family_style_id(self, value)

func family_style_id() -> int:
	return Family_materials.family_style_id(self)

func set_family_batch_suppressed(suppressed: bool) -> void:
	return Family_materials.set_family_batch_suppressed(self, suppressed)

func detail_family_chunk_payload(chunk_id: int) -> Dictionary:
	return Family_materials.detail_family_chunk_payload(self, chunk_id)

func detail_family_chunk_ids() -> Array:
	return Family_materials.detail_family_chunk_ids(self)

func detail_family_mesh() -> ArrayMesh:
	return Family_materials.detail_family_mesh(self)

func detail_family_quality() -> int:
	return Family_materials.detail_family_quality(self)

func detail_family_mesh_for_quality(quality: int) -> ArrayMesh:
	return Family_materials.detail_family_mesh_for_quality(self, quality)

func detail_family_material(style_lut: Texture2D) -> ShaderMaterial:
	return Family_materials.detail_family_material(self, style_lut)

func detail_family_shader(shadow_pass: bool) -> Shader:
	return Family_materials.detail_family_shader(self, shadow_pass)

func detail_family_shadow_material(style_lut: Texture2D = null) -> ShaderMaterial:
	return Family_materials.detail_family_shadow_material(self, style_lut)

func detail_family_shadow_mesh() -> ArrayMesh:
	return Family_materials.detail_family_shadow_mesh(self)

func detail_family_casts_shadow() -> bool:
	return Family_materials.detail_family_casts_shadow(self)

func detail_change_affects_profile(
		axis_mask: int,
		old_veg: int, new_veg: int,
		old_lf: int, new_lf: int,
		old_cover: int, new_cover: int
) -> bool:
	return Family_materials.detail_change_affects_profile(self, axis_mask, old_veg, new_veg, old_lf, new_lf, old_cover, new_cover)

func set_camera_view(world_rect: Rect2, center: Vector2, zoom_value: float) -> void:
	_camera_view_rect = world_rect
	_camera_view_center = center
	_camera_view_initialized = world_rect.size.x > 0.0 and world_rect.size.y > 0.0
	var chunk_margin := maxf(
		float(_chunk_size_cells) * _hex_size * 1.75,
		float(_chunk_size_cells) * _hex_size * 1.50
	)
	_camera_prefetch_rect = world_rect.grow(chunk_margin)
	_active_instance_count_valid = false
	set_camera_zoom(zoom_value)
	Chunk_nodes._refresh_chunk_visibility(self)


func set_lod_debug_view(enabled: bool) -> void:
	return Lifecycle.set_lod_debug_view(self, enabled)

func _resolved_lod_thresholds() -> Vector2:
	return ShrubLodPolicy._resolved_lod_thresholds(self)

func _resolved_lod_near_density_multiplier() -> float:
	return ShrubLodPolicy._resolved_lod_near_density_multiplier(self)


func active_instance_count() -> int:
	return Chunk_budget.active_instance_count(self)

func refresh_for_succession(_indices: PackedInt32Array) -> void:
	return Chunk_refresh.refresh_for_succession(self, _indices)


func _apply_native_delta_payload(
		valid_indices: PackedInt32Array,
		buffer: PackedFloat32Array,
		cell_indices: PackedInt32Array,
		inst: int,
		candidate_count: int,
		wrap_count: int,
		t0_us: int) -> void:
	return Chunk_refresh._apply_native_delta_payload(self, valid_indices, buffer, cell_indices,
		inst, candidate_count, wrap_count, t0_us)


func _native_offset_is_water(grid_w: int, grid_h: int) -> PackedByteArray:
	return ShrubFullRebuild._native_offset_is_water(self, grid_w, grid_h)

func _vegetation_climate_tables() -> Dictionary:
	return ShrubFullRebuild._vegetation_climate_tables(self)


func begin_detail_chunk_refresh() -> void:
	Chunk_refresh.begin_detail_chunk_refresh(self)

func instance_count() -> int:
	return _instance_count


func apply_visible_instance_fraction(fraction: float) -> void:
	return Chunk_budget.apply_visible_instance_fraction(self, fraction)

const VP_BUDGET_RECT_EPSILON := 24.0        # 视口中心/尺寸变化阈值（world units）
const VP_BUDGET_ZOOM_EPSILON := 0.02        # 相对缩放变化阈值（2%）
const VP_BUDGET_FRACTION_EPSILON := 0.0025  # 与 hex_renderer.DETAIL_BUDGET_FRACTION_EPSILON 对齐
const VP_BUDGET_BOOST_MAX := 6.0            # 视口内的「补到 100%」倍率上限
const VP_BUDGET_EDGE_FALLOFF_MIN := 0.18    # 近景（一 hex 几十像素）时边缘衰减深度
const VP_BUDGET_EDGE_FALLOFF_MAX := 0.72    # 总览（一 hex 几个像素）时边缘衰减深度
const VP_BUDGET_BISECT_STEPS := 10          # 软阈值二分次数（固定步数 → 确定性；θ 精度 ~0.1%）
const VP_BUDGET_NEAR_T := 0.5               # t ≤ 0.5 记作「内圈 near」，其余「外圈 far」
const VP_BUDGET_COVERAGE_FLOOR := 0.20      # 视口内每个 chunk 的覆盖保底（占其期望值）
const VP_BUDGET_COVERAGE_SHARE := 0.60      # 保底最多吃掉预算的比例，剩下留给近处优先

var _vp_budget_cache_valid: bool = false
var _vp_budget_cache_rect: Rect2 = Rect2()
var _vp_budget_cache_zoom: float = -1.0
var _vp_budget_cache_fraction: float = -1.0
var _vp_budget_cache_diag: Dictionary = {}
var _vp_budget_applies: int = 0
var _vp_budget_skips: int = 0
var _vp_budget_last_ms: float = 0.0
var _vp_budget_log_enabled: bool = false
var _vp_budget_log_count: int = 0


# 日志开关沿用 hex_renderer.detail_scatter_rebuild_log_enabled 的语义：
# 由主 agent 在接线时透传，实际打印还要 PKLog.enabled 与 fraction<1 两个门。

func set_viewport_budget_log_enabled(enabled: bool) -> void:
	return Chunk_budget.set_viewport_budget_log_enabled(self, enabled)

func invalidate_viewport_budget_cache() -> void:
	return Chunk_budget.invalidate_viewport_budget_cache(self)

func viewport_budget_report() -> Dictionary:
	return Chunk_budget.viewport_budget_report(self)

func apply_visible_instance_fraction_weighted(
		global_fraction: float,
		view_rect: Rect2,
		zoom: float,
		pixel_world_size: float,
		log_enabled: bool = false) -> Dictionary:
	return Chunk_budget.apply_visible_instance_fraction_weighted(self, global_fraction, view_rect, zoom, pixel_world_size, log_enabled)

func detail_chunk_lod_ceiling(chunk_id: int) -> int:
	return Chunk_budget.detail_chunk_lod_ceiling(self, chunk_id)

func set_mobile_quality_tier(q: int) -> void:
	return Material_inputs.set_mobile_quality_tier(self, q)

func set_cloud_shadow_field(texture: Texture2D, direct_enabled: bool,
		wrap_origin_uv: float, wrap_period_uv: float) -> void:
	return Material_inputs.set_cloud_shadow_field(self, texture, direct_enabled, wrap_origin_uv, wrap_period_uv)

func _push_cloud_shadow_uniforms() -> void:
	return Material_inputs._push_cloud_shadow_uniforms(self)

func _ensure_resources() -> void:
	return Material_inputs._ensure_resources(self)

static func quality_tier_defines(tier: int) -> String:
	return VegetationShaderVariants.quality_tier_defines(tier)


## [web-tier-pin 2026-10-31] web 上编译期档固定 LOW，与
## `player_game._shader_quality_define_from_setting()` 在 web 上的返回值同源。
##
## 为什么要在本层再钉一次：`_mobile_quality_tier` 的初值是 1(MID)，而 `_ready()` 的
## 早编（`_ensure_resources()`）发生在 hex_renderer 推档之前。于是 web 上第一份
## body/shadow 源码编成 MID 档，预热的却是 LOW 档 —— LOW/MID 两条宏串**长度相同**
## （27+27=54 字节：#define <18 字符宏> 两行）、内容不同，于是预热与运行期的 fp 长度一样、hash 不一样，驱动缓存
## 必然不命中（2026-10-31 实测 veg_body 284:2668251923 vs 预热 284:2751745859）。
## 钉死之后源码不再取决于推档时机。Web 画质预算和 veg_shade_quality
## 走 `_visual_quality`，移动端继续走 `_mobile_quality_tier`。
const WEB_SHADER_QUALITY_TIER = VegetationShaderVariants.WEB_SHADER_QUALITY_TIER


## web 运行期的近景 form 档位宏。`world_known=false` = `_world == null`（`_ready()` 早编）。
static func web_form_defines(world_known: bool) -> String:
	return VegetationShaderVariants.web_form_defines(world_known)


## **纯函数**：web 运行期会用的 define 前缀。单一事实来源 —— 运行期
## `_shader_quality_define_prefix()` 与菜单期 `web_warmup_shader_codes()` 都调这一个，
## "预热源码 == 运行期源码"由构造保证，而不是两处各抄一份宏串再指望它们一样
## （抄串的后果就是上面那条同长不同 hash 的 MISS）。
## 参数全部显式传入（不读 OS.has_feature / 成员变量），才能被桌面 headless 探针枚举：
## `tests/rendering/veg_variant_parity_probe.gd`。
static func web_define_prefix(tier: int, tiled: bool, world_known: bool,
		force_far_only: bool = false, pc_high: bool = false) -> String:
	return VegetationShaderVariants.web_define_prefix(tier, tiled, world_known, force_far_only, pc_high)


func _shader_quality_define_prefix(force_far_only: bool = false) -> String:
	return Material_inputs._shader_quality_define_prefix(self, force_far_only)

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		VegetationNodeLifecycle.release(self)



func _clear_chunk_nodes() -> void:
	return Chunk_nodes._clear_chunk_nodes(self)

func _wrap_period_x() -> float:
	return Chunk_nodes._wrap_period_x(self)

func _sync_single_wrap_nodes() -> void:
	return Chunk_nodes._sync_single_wrap_nodes(self)

func _sync_chunk_wrap_nodes(chunk_id: int) -> void:
	return Chunk_nodes._sync_chunk_wrap_nodes(self, chunk_id)

func _sync_shadow_chunk_wrap_nodes(chunk_id: int) -> void:
	return Chunk_nodes._sync_shadow_chunk_wrap_nodes(self, chunk_id)

func _shadow_min_zoom() -> float:
	return Chunk_nodes._shadow_min_zoom(self)

func _shadow_zoom_gain() -> float:
	return Chunk_nodes._shadow_zoom_gain(self)

func detail_chunk_cells(chunk_id: int) -> PackedInt32Array:
	return Chunk_nodes.detail_chunk_cells(self, chunk_id)

func detail_chunk_id_for_cell(cell_idx: int) -> int:
	return Chunk_nodes.detail_chunk_id_for_cell(self, cell_idx)

func _chunk_world_bounds(chunk_id: int) -> Rect2:
	return Chunk_nodes._chunk_world_bounds(self, chunk_id)

func _invalidate_chunk_spatial_cache() -> void:
	return Chunk_nodes._invalidate_chunk_spatial_cache(self)

func detail_chunk_is_in_prefetch(chunk_id: int) -> bool:
	return Chunk_nodes.detail_chunk_is_in_prefetch(self, chunk_id)

func detail_chunk_is_render_visible(chunk_id: int) -> bool:
	return Chunk_nodes.detail_chunk_is_render_visible(self, chunk_id)

func detail_chunk_plan_for_view(world_rect: Rect2) -> Array:
	return Chunk_nodes.detail_chunk_plan_for_view(self, world_rect)

func detail_prefetch_chunk_plan() -> Array:
	return Chunk_nodes.detail_prefetch_chunk_plan(self)

func detail_chunk_has_resident_cache(chunk_id: int) -> bool:
	return Chunk_nodes.detail_chunk_has_resident_cache(self, chunk_id)

func evict_dormant_detail_chunks(now_msec: int, retention_msec: int) -> int:
	return Chunk_nodes.evict_dormant_detail_chunks(self, now_msec, retention_msec)

func _lod_order_sources(
		src_indices: Array,
		cell_indices: PackedInt32Array,
		buffer: PackedFloat32Array) -> Dictionary:
	return Chunk_refresh._lod_order_sources(self, src_indices, cell_indices, buffer)

func _prepare_chunk_multimesh(chunk_id: int, inst: int, far_count: int = -1) -> MultiMesh:
	return Chunk_refresh._prepare_chunk_multimesh(self, chunk_id, inst, far_count)

func _apply_chunk_payload_direct(
		chunk_id: int,
		buffer: PackedFloat32Array,
		cell_indices: PackedInt32Array,
		inst: int,
		native_far_count: int = -1,
		cache_already_updated: bool = false) -> void:
	return Chunk_refresh._apply_chunk_payload_direct(self, chunk_id, buffer, cell_indices, inst, native_far_count, cache_already_updated)

func _cache_chunk_cell_payloads(
		chunk_id: int,
		buffer: PackedFloat32Array,
		cell_indices: PackedInt32Array,
		inst: int) -> void:
	return Chunk_refresh._cache_chunk_cell_payloads(self, chunk_id, buffer, cell_indices, inst)

func _replace_chunk_cell_payloads(
		chunk_id: int,
		dirty_indices: PackedInt32Array,
		buffer: PackedFloat32Array,
		cell_indices: PackedInt32Array,
		inst: int) -> Dictionary:
	return Chunk_refresh._replace_chunk_cell_payloads(self, chunk_id, dirty_indices, buffer, cell_indices, inst)

func _assemble_chunk_cell_payloads(by_cell: Dictionary) -> Dictionary:
	return Chunk_refresh._assemble_chunk_cell_payloads(self, by_cell)

func _apply_chunked_native_full(buffer: PackedFloat32Array, cell_indices: PackedInt32Array, inst: int, cooperative: bool = false) -> void:
	await Chunk_refresh._apply_chunked_native_full(self, buffer, cell_indices, inst, cooperative)

func detail_chunk_plan_for_indices(indices: PackedInt32Array) -> Array:
	return Chunk_refresh.detail_chunk_plan_for_indices(self, indices)

func refresh_chunk_for_succession(
		chunk_id: int,
		chunk_cells: PackedInt32Array,
		dirty_cell_count: int = 0,
		dirty_indices: PackedInt32Array = PackedInt32Array()) -> bool:
	return Chunk_refresh.refresh_chunk_for_succession(self, chunk_id, chunk_cells, dirty_cell_count, dirty_indices)

func _rebuild_instances() -> void:
	ShrubFullRebuild._rebuild_instances(self)

func _rebuild_via_native(
		cells: Array,
		cell_states: Array,
		cell_suitabilities: PackedFloat32Array,
		cell_attempts: PackedInt32Array,
		cell_accepts: PackedFloat32Array) -> bool:
	return ShrubFullRebuild._rebuild_via_native(self, cells, cell_states, cell_suitabilities, cell_attempts, cell_accepts)


func _form_knobs() -> Dictionary:
	return ShrubScatter._form_knobs(self)

func _sub_form_enabled() -> bool:
	return ShrubScatter._sub_form_enabled(self)

func _overlaps_cell_instance(idx: int, pos: Vector2, size: float) -> bool:
	return ShrubScatter._overlaps_cell_instance(self, idx, pos, size)

func _candidate_form(key: int, attempt: int, world_noise: float, cell_suitability: float,
		size_density: float) -> Vector3:
	return ShrubScatter._candidate_form(self, key, attempt, world_noise, cell_suitability, size_density)

func _overlaps_known_settlement(pos: Vector2, candidate_size: float) -> bool:
	return ShrubScatter._overlaps_known_settlement(self, pos, candidate_size)

func _cell_overlaps_settlement(cell, pos: Vector2, candidate_size: float) -> bool:
	return ShrubScatter._cell_overlaps_settlement(self, cell, pos, candidate_size)

func _settlement_core_radius(bucket: int) -> float:
	return ShrubScatter._settlement_core_radius(self, bucket)

func _candidate_position(center: Vector2, key: int, attempt: int) -> Vector2:
	return ShrubScatter._candidate_position(self, center, key, attempt)

func _world_noise_suitability(world_pos: Vector2) -> float:
	return ShrubScatter._world_noise_suitability(self, world_pos)

func _instance_rotation(key: int, attempt: int) -> float:
	return ShrubScatter._instance_rotation(self, key, attempt)

func _is_water_cell(cell, idx: int) -> bool:
	return ShrubScatter._is_water_cell(self, cell, idx)

func _cell_center(cell, idx: int) -> Vector2:
	return ShrubScatter._cell_center(self, cell, idx)

func _cell_index(cell, fallback: int) -> int:
	return ShrubScatter._cell_index(self, cell, fallback)

func _quality_size_scale() -> float:
	return ShrubScatter._quality_size_scale(self)

func _detail_kind() -> int:
	return ShrubScatter._detail_kind(self)

func _profile() -> Resource:
	return ShrubScatter._profile(self)

func _effective_spawn_radius_factor() -> float:
	return ShrubScatter._effective_spawn_radius_factor(self)

func _profile_float(prop: StringName, fallback: float) -> float:
	return ShrubScatter._profile_float(self, prop, fallback)

func get_scatter_diagnostics() -> Dictionary:
	return Diagnostics.get_scatter_diagnostics(self)

func detail_visibility_probe() -> Dictionary:
	return Diagnostics.detail_visibility_probe(self)

func _f32(arr: PackedFloat32Array, idx: int, fallback: float) -> float:
	return Diagnostics._f32(self, arr, idx, fallback)

func _u8(arr: PackedByteArray, idx: int, fallback: int) -> int:
	return Diagnostics._u8(self, arr, idx, fallback)

func _hash01(idx: int, salt: int) -> float:
	return Diagnostics._hash01(self, idx, salt)

static func web_warmup_shader_codes() -> Dictionary:
	return VegetationShaderVariants.web_warmup_shader_codes()


## 同一份源码只保留一个 label：预热每张都要单独跑两帧绘制，重复编就是白花时间。
static func _put_warmup_code(out: Dictionary, key: String, code: String) -> void:
	VegetationShaderVariants._put_warmup_code(out, key, code)


static func _compiled_shader(code: String, pass_tag: String = "body") -> Shader:
	return VegetationShaderVariants._compiled_shader(code, pass_tag)


# 每个还没上报过的变体发一条 WebTelemetry。字段：
#   s      pass：body / shadow / family
#   ms     该变体在本进程里的累计编译耗时（首次即真正的编译，缓存命中不计数）
#   n      该变体被编译了几次（1=正常；>1=换档/tiled 切换又编了一遍）
#   layers 共享这份 shader 的层数（同级 ShrubLayer 数，web 上已被砍半）
#   near   far / min / full（该变体实际编进去的近景档位，从代码读）
#   tier   0..2 受限平台画质档
#   tiled  是否 tiled 变体
#   h/l    变体标识（代码 hash / 代码长度），用来区分 legacy 与 tiled
static func _bind_crown_art(mat: ShaderMaterial) -> void:
	VegetationShaderVariants._bind_crown_art(mat)

func setup_cooperative(map: MapData, world: WorldData, bounds: Rect2, hex_size: float, visual_quality: int = 1) -> void:
	await Cooperative_rebuild.setup_cooperative(self, map, world, bounds, hex_size, visual_quality)

func _rebuild_instances_cooperative() -> void:
	await Cooperative_rebuild._rebuild_instances_cooperative(self)

func _rebuild_via_native_cooperative(
		cells: Array,
		cell_states: Array,
		cell_suitabilities: PackedFloat32Array,
		cell_attempts: PackedInt32Array,
		cell_accepts: PackedFloat32Array) -> bool:
	return await Cooperative_rebuild._rebuild_via_native_cooperative(self, cells, cell_states, cell_suitabilities, cell_attempts, cell_accepts)
