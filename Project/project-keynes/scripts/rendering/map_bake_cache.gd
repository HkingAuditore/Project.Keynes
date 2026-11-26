extends RefCounted

## Owns map-bake settings, shared textures and the buffers reused by the bake and refresh stages.

const MapMaterialAssets = preload("res://scripts/rendering/map_material_assets.gd")
# ─── 分辨率 ───────────────────────────────────────────────────────────────
# 桌面基线 1024；移动端 512。Web 按设置选择 512/1024/2048，
# 高档优先保留近景海岸与高度精度；静态精度切换在下次创建地图生效。
const HM_MAX_DIM_DESKTOP := 1024
const HM_MAX_DIM_MOBILE := 512

static func _render_quality_setting() -> String:
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null:
		var settings := tree.root.get_node_or_null("GameSettings")
		if settings != null and settings.has_method("values"):
			return String(settings.values().get("render_quality", "auto"))
	return "auto"

static func _terrain_material_size() -> int:
	if OS.has_feature("web"):
		var q := _render_quality_setting()
		var use_mobile := q == "low" or (q == "auto" and DCFeatureFlags.is_mobile_web())
		return TERRAIN_MATERIAL_SIZE_MOBILE if use_mobile else TERRAIN_MATERIAL_SIZE_DESKTOP
	return TERRAIN_MATERIAL_SIZE_MOBILE if OS.has_feature("mobile") else TERRAIN_MATERIAL_SIZE_DESKTOP

static func _hm_max_dim() -> int:
	# F12 调试热键（2026-06-14）：force_atlas_quarter_size meta 临时把移动端
	# atlas 从 512 进一步降到 256，看 GPU 负载减半 FPS 提升多少。重启失效。
	if Engine.has_meta(&"force_atlas_quarter_size") and bool(Engine.get_meta(&"force_atlas_quarter_size")):
		return 256
	if OS.has_feature("web"):
		match _render_quality_setting():
			"high": return 2048
			"medium": return 1024
			"low": return HM_MAX_DIM_MOBILE
			_: return HM_MAX_DIM_MOBILE if DCFeatureFlags.is_mobile_web() else 2048
	if OS.has_feature("mobile"):
		return HM_MAX_DIM_MOBILE
	return HM_MAX_DIM_DESKTOP

# 兼容：保留旧常量名，值跟 desktop 一致。其它文件仍引用 HM_MAX_DIM 时不破坏；
# 真正决定渲染分辨率的是 _resolve_hm_size() 里调 _hm_max_dim()。
const HM_MAX_DIM := HM_MAX_DIM_DESKTOP

# [terrain-horizon 2026-07-03] 8 方向 horizon 生成期烘焙参数。桌面用一张 RGBA8
# nibble-packed 纹理，运行期 1 次采样近似地形投影阴影；Web 全部档位也 CPU 烘一张
# （见 TERRAIN_HORIZON_STEPS_WEB），mobile 仍为 null（shader 走无阴影回退）。
const TERRAIN_HORIZON_STEPS := 1024
const TERRAIN_HORIZON_STEP_PX := 2.0
const TERRAIN_HORIZON_STEP_GROWTH := 0.35  # 近密远疏；0 退回固定步长
const TERRAIN_HORIZON_LOWPASS_RADIUS := 1  # Horizon 专用 3x3 低通，不改权威高度场
const TERRAIN_HORIZON_MAX_ANGLE := 1.309      # 约 75°，与运行期解码契约一致
# height 单位，抑制同高/高频 relief 自遮蔽。高度按 16 hex 夸张后，0.01 的侵蚀残差在 1~3 texel
# 内就构成 60° 以上的遮挡角，山地满屏碎点状投影；0.04 只滤掉残差，山体与河谷投影保留。
const TERRAIN_HORIZON_BIAS := 0.04
const TERRAIN_HORIZON_HEIGHT_SCALE_HEX := 16.0   # 归一高程 → world units（×hex_size）
const TERRAIN_HORIZON_MAX_DISTANCE_HEX := 24.0  # 固定近场遮挡射程，避免大地图引入更远山体
# [terrain-web-baked-surface 2026-11-01] Web 全部档位的 horizon CPU marching 步数。
# 桌面 1024 步是给 4K 级 hm 的；Web 是 nothreads WASM，1024 步会秒级卡死。
# 真机探针（RTX native 多线程，steps=128）：512×298 = 15 ms / 1024×596 = 79 ms /
# 2048×1192 = 489 ms；max_distance=24 hex 还会自然截断有效步数（实际远小于 128）。
const TERRAIN_HORIZON_STEPS_WEB := 128

# [terrain-web-baked-surface 2026-11-01] Web 全部档位 + 桌面 legacy 回退的**单张静态地表**
# （normal RGBA8 + relief RGBA8）整图单 tile 烘焙封顶。复用 native
# run_bake_visual_tile_layer_pass，把整张地图当一个 tile 烘（relief_supersample=1）。
# 真机探针（RTX native 多线程）：512×298 = 68 ms；1024×596 = 265 ms；wasm nothreads
# 预计 3–5×，相对 map 生成总预算仍可接受，因此 Web 不再单独压到 512：封顶与桌面一致
# 取 1024，实际尺寸再被 world.hm_size 最大边自然钳住
# （Web LOW hm=512 → 512；Web MID/HIGH hm≥1024 → 1024；桌面 legacy → 1024）。
const LEGACY_STATIC_SURFACE_MAX_DIM := 1024
const LEGACY_STATIC_SURFACE_MAX_DIM_WEB := LEGACY_STATIC_SURFACE_MAX_DIM

# ─── v10.noise-pack：共享噪声包贴图（替换 shader 内海量 fbm 多 octave 采样） ──
# 256×256 RGBA8，固定 seed → 跨 world 实例可缓存共享。MapBaker 一次烘出，所有
# WorldData.noise_tex 都指向同一张 ImageTexture。通道约定：
#   R = raw tileable value noise（兼容 value_noise）
#   G = 2-octave fBM 预积分
#   B = 3-octave fBM 预积分
#   A = 4-octave fBM 预积分
# shader 端 fbm(p,N) 由 N 次 texture fetch 降为 1 次 texture fetch。
const NOISE_TEX_SIZE := 256
const NOISE_TEX_SEED := 0xC0DECAFE
static var _shared_noise_tex: ImageTexture = null
const TERRAIN_DETAIL_BAKE_MIN := 0.70
const TERRAIN_DETAIL_BAKE_MAX := 1.30

# [terrain-material-tiles] The four authored families are independent of map
# dimensions and are therefore cached once per device target size. Mobile gets
# one 512² downscale; desktop keeps the authored 1024² images.
# [terrain-web-baked-surface-B 2026-11-01] 第 5 层 = micro 细节（256² RGBA8 平铺贴图），
# 缩放到同一 target_size 后进同一 array（shader 用 terrain_material_micro_layer=4 采样），
# 这样 Web 陆地程序不必额外声明 terrain_micro_tex sampler（保持 8 槽）。
const TERRAIN_MATERIAL_SIZE_DESKTOP := 1024
const TERRAIN_MATERIAL_SIZE_MOBILE := 512
const TERRAIN_MATERIAL_MICRO_LAYER := 4
const TERRAIN_MATERIAL_TEXTURE_PATHS = MapMaterialAssets.TERRAIN_MATERIAL_TEXTURE_PATHS
const TERRAIN_MICRO_TEXTURE_PATH = MapMaterialAssets.TERRAIN_MICRO_TEXTURE_PATH
static var _shared_terrain_material_tex_by_size: Dictionary = {}
static var _shared_terrain_material_error_by_size: Dictionary = {}

static func _terrain_materials_supported_for_renderer(rendering_method: String) -> bool:
	# Compatibility/Web 现在也分配材质数组：主地形砍掉 eco_lut 后腾出 1 个
	# sampler 槽，PK_WEB_TEXTURE_BUDGET 变体已重新声明 terrain_material_tex。
	# rendering_method 参数保留供调用方诊断；不再按 gl_compatibility 拒绝。
	return true

static func _terrain_materials_supported() -> bool:
	return true

# Daily Sim SoA Refactor 阶段 1：海冰 GPU 上传从 scalar_atlas.a 拆出到独立 sea_ice_tex（R8）。
# 拆分前每日要传整张 RGBA8（2400×?，~7MB），其中 RGB 三通道是地形烘焙后的恒定值，
# 仅 A 通道每日变化，纯属冗余带宽。拆分后：
#   - scalar_atlas 的 RGB 三通道在 bake_world 编码一次后永不再传；A 通道写 0 占位。
#   - sea_ice_tex 曾作为独立 R8 由 sea_ice_atlas_upload 驱动；
#     该路径现已退役，主海冰视觉改走 dyn_atlas_smooth.A / shader 派生。
# 既有的"只遍历水格 + 按 cell byte dirty skip"机制完整保留，只是写入目标变成
# `_sea_ice_only_buf` 而非 `_scalar_atlas_data_buf`。
#
# 注意：`Image.create_from_data` 会**复制**入参 PackedByteArray，所以这里直接传
# 同一个常驻 buf 不会出现 "改 buf 影响 GPU 已上传内容" 的悬空引用问题。
var _sea_ice_only_buf: PackedByteArray = PackedByteArray()
var _sea_ice_cache_size: Vector2i = Vector2i.ZERO
var _sea_ice_pixel_to_cell_idx: PackedInt32Array = PackedInt32Array()
# Daily-sim perf opt: cell 级 byte 量化快照（key=HexCell, value=int 0..255）。
# bake_sea_ice_fraction_only 入口先做 cell 级 byte 比较：水格通常 ~1300 个，
# 比 620k 像素级比较快 ~500×。绝大多数日子海冰 byte 不变 → 直接 return，连像素
# buf 都不算，省掉 ~100ms 的 lookup 循环。
# 当 bake_world 重做 lookup 时一同失效（_sea_ice_only_buf 清空时也清掉）。
var _last_sea_ice_cell_bytes: Dictionary = {}
var _last_sea_ice_cell_bytes_packed: PackedByteArray = PackedByteArray()

# Daily-sim perf opt 阶段 P：cover / vegetation 的 per-cell byte 快照（用于 rebake_*_only 增量路径）。
# weather_system 每日翻 cover 的 cell 通常 < 30 个，而旧 fast path 仍要扫 614k 像素重写所有 byte
# （即便 99% 没变化）。改造为遍历 world.cell_pixel_lists 的 ~2400 个 cell，逐 cell 比对 byte：
# 不变直接跳过，只对真正翻面的 cell 把它的像素列表批量写入 buffer，再触发 enum_atlas 整张 update。
# 与 ice_bake 的 _last_sea_ice_cell_bytes 完全同构。bake_world 重做 lookup 时一并失效。
var _last_cover_cell_bytes: Dictionary = {}
var _last_vegetation_cell_bytes: Dictionary = {}
var _last_cover_cell_bytes_packed: PackedByteArray = PackedByteArray()
var _last_vegetation_cell_bytes_packed: PackedByteArray = PackedByteArray()
var _cover_cache_size: Vector2i = Vector2i.ZERO
var _vegetation_cache_size: Vector2i = Vector2i.ZERO
# J: biome（R 通道）增量缓存。stage 9 `rebake_biome_axes_only` 之前每季全图重烘
# (~130ms / season)；接入与 cover/veg 同结构的 sig 比对后，多数季节切换只有少量 cell
# 真正翻 terrain（_seasonal_redecide_terrain 的边界 cell），其余直接 byte 不变跳过。
# bake_world / regenerate 时一并失效。
var _last_biome_cell_bytes: Dictionary = {}
var _last_biome_cell_bytes_packed: PackedByteArray = PackedByteArray()
var _biome_cache_size: Vector2i = Vector2i.ZERO

# Daily-sim perf opt 阶段 P2：enum_atlas 的 RGB8 交错 data 持久缓存。
# 旧路径每次 _encode_enum_atlas 都要跑 614400 次循环交错三个 byte 通道（~50ms）——
# 即便底层 cover_buffer 只改了 < 5k 像素。缓存 RGB8 交错 data 后，rebake_cover_tex_only
# 增量路径每改一个 cell 就同步把那些像素的 R/G/B byte 直接写到 cached data，
# 最后 Image.create_from_data(cached_data) → texture.update(img)，省掉整张交错循环。
# 首次（bake_world / rebake_biome_axes_only / fallback / 增量首次）必须经过 _encode_enum_atlas
# 整张交错路径（顺便填充 cached data）；后续增量直接走局部 byte 写入。
# bake_world 时一并失效。
var _enum_atlas_data: PackedByteArray = PackedByteArray()
var _enum_atlas_data_size: Vector2i = Vector2i.ZERO
# Enum atlas upload telemetry：最近一次动态轴刷新/上传的细分耗时。
# 由 EnumAtlasUploadSystem 在 slice 结束后读取并转存到 MapGenerator。
var _last_enum_atlas_upload_report: Dictionary = {}

# ─── plan/sim-2ms-simd-dirty-budget（2026-05-21）：enum atlas upload 节流 ───
# Godot 4 没有 partial texture upload API（issue godotengine/godot#65762），整图
# RGB8 (~1.8MB) GPU upload 在每天有 ≥1 个 dirty cell 时都会触发，单次 1.0-1.5ms。
# cpp 端 patch_enum_atlas_axes 已经做了 dirty cell 比对，buffer_patch_ms 只占
# ~0.45ms；剩下 0.5-1.0ms 几乎全在 image_create + texture.update。
# Throttle 在 dirty_cells > 0 时不立即 GPU upload，而是按 axis 累积 dirty 计数，
# 满足以下任一条件才真正 flush：
#   1. 累积 dirty cells ≥ THRESHOLD_DIRTY_CELLS (16)
#   2. 累积 skip 次数 ≥ THRESHOLD_SKIP_COUNT (4)
#   3. 距上次 flush ≥ THRESHOLD_HEAL_TICKS (64)（自愈兜底，避免 dirty 漏标）
# 强制 flush 入口：
#   - bake_world / set_climate_profile（地图重生 / profile 切换）调用 reset
#   - season 切换 / save / screenshot 调用 force_flush_enum_atlas_throttle()
# 数据完整性：cpp 端 _enum_atlas_data 始终是最新，仅 GPU 端的 enum_atlas_tex
# 延迟 N tick；视觉上 cover/vegetation 的颜色翻转会延迟出现。
var _enum_atlas_throttle_skipped_uploads: Dictionary = {}  # axis(String) → int
var _enum_atlas_throttle_pending_dirty: Dictionary = {}    # axis(String) → int
var _enum_atlas_throttle_ticks_since_flush: Dictionary = {}# axis(String) → int
const _ENUM_ATLAS_THROTTLE_DIRTY_THRESHOLD: int = 16
const _ENUM_ATLAS_THROTTLE_SKIP_THRESHOLD: int = 4
var _daily_wind_refresh_keys: PackedStringArray = PackedStringArray([
	"cell_pos_x",
	"cell_pos_y",
	"cell_terrain",
	"cell_landform",
	"cell_temp",
	"cell_temp_anomaly",
	"cell_snow_cover",
	"cell_sea_ice_frac",
	"cell_weather_vapor",
	"cell_weather_cloud",
	"cell_slp",
	"cell_wind_x",
	"cell_wind_y",
	"cell_wind_speed",
])
const _ENUM_ATLAS_THROTTLE_HEAL_TICKS: int = 64

# Daily-sim perf opt：weather_field_tex 增量缓存。
# 旧 bake_weather_field_only 每天扫 ~2400 cell × 4 通道，再写 ~250k–600k 像素
# 字节，~27ms / tick。WeatherSystem 每日只让若干 cell 翻 weather/intensity/cloud/precip,
# 大多数 cell 当天不变。缓存 cell 级 4-byte 签名（u32 packed），逐 cell 比对：
#   - 不变 → 完全跳过（不读 cell_pixel_lists）
#   - 变 → 把 4 byte 写到该 cell 的所有像素 + 更新 sig
# 所有 cell 都没变 → 跳过 Image.create_from_data + texture.update。
# 任何 cell 变了 → 触发整张 image update（GPU 上传不可避，但循环开销骤降）。
# bake_world 时一并失效。
var _weather_field_buf: PackedByteArray = PackedByteArray()
var _weather_field_cache_size: Vector2i = Vector2i.ZERO
var _last_weather_field_cell_sigs: Dictionary = {}  # HexCell → int (packed u32)
# 主地图动态状态 atlas（RGBA8）：R=temp, G=moisture/wetness, B=snow_cover, A=vegetation_vitality。
# 与 weather/sea_ice 同构，按 cell 级 4-byte 签名 dirty 写入。
var _dynamic_cell_atlas_buf: PackedByteArray = PackedByteArray()
var _dynamic_cell_atlas_cache_size: Vector2i = Vector2i.ZERO
var _last_dynamic_cell_sigs: Dictionary = {}  # HexCell → int (packed u32)
# Ecology visual atlas: RGBA8, same cell-dirty write path as dynamic_cell_atlas.
var _ecology_visual_atlas_buf: PackedByteArray = PackedByteArray()
var _ecology_visual_atlas_cache_size: Vector2i = Vector2i.ZERO

# ─── map-visual-overhaul-v1：3 张新 atlas 的 baker 缓存 ───
# dyn_atlas_smooth：dynamic_cell_atlas 的"沿 hex 邻接 box blur"产物。
#   单 cell 处理 = R/G 通道：中心 0.5 + 6 邻居均值 0.5；
#                   B 通道（snow_cover）：passthrough，不参与平滑（阈值型，
#                                          单格能在雪线之上而邻居不在）。
#                   A 通道（vitality）：仅"非海域邻居"参与平均。海域 cell 在
#                                       encode 时被强制 A=0，若与陆地邻居一起
#                                       平均会把海岸陆地 cell 的 vitality 系统
#                                       性拖低（孤岛 5 海邻 → -42%）。
#   O(N_cells × 7) 一次。cell-level signature 也走 dirty 路径，但因为受邻居
#   影响，dirty 集合需要膨胀 1 跳。
var _dyn_atlas_smooth_buf: PackedByteArray = PackedByteArray()
var _dyn_atlas_smooth_cache_size: Vector2i = Vector2i.ZERO
var _last_dyn_smooth_cell_sigs: Dictionary = {}  # HexCell → int (smoothed packed u32)
# ice_state_atlas：R8，每像素 = sea_ice_frac × 255。仅水域 cell 写非零。
var _ice_state_buf: PackedByteArray = PackedByteArray()
var _ice_state_cache_size: Vector2i = Vector2i.ZERO
var _last_ice_state_cell_bytes: Dictionary = {}  # HexCell → int byte
var _last_ecology_visual_sigs: Dictionary = {}  # HexCell -> int (packed u32)
var _last_ecology_veg_bytes: Dictionary = {}  # HexCell -> int  (legacy, deprecated by SoA)
var _last_ecology_vitality_bytes: Dictionary = {}  # HexCell -> int  (legacy, deprecated by SoA)
var _ecology_transition_age_bytes: Dictionary = {}  # HexCell -> int  (legacy, deprecated by SoA)

# Cell-indirection LUT 的 CPU 镜像。Godot 4 不能做 texture sub-region update，
# 但可以在字节完全不变时跳过 Image 构造与 GPU upload；这些缓存也让 report 无需
# 携带三份 PackedByteArray 穿过 SUS/perf 记录链。
var _cell_enum_lut_bytes_cache: PackedByteArray = PackedByteArray()
var _cell_dyn_lut_bytes_cache: PackedByteArray = PackedByteArray()
var _cell_eco_lut_bytes_cache: PackedByteArray = PackedByteArray()
var _cell_bounce_lut_bytes_cache: PackedByteArray = PackedByteArray()
var _cell_lut_active_transition_count: int = 0
var _cell_offset_layout: Dictionary = {}
var _cell_table_source_cache: Dictionary = {}

# GM-only river Atlas probe. It samples a bounded set of river/non-river cells
# at the LUT encode boundary so source values can be compared with published bytes.
const RIVER_ATLAS_PROBE_CELL_LIMIT := 16
const RIVER_ATLAS_PROBE_SAMPLE_LIMIT := 64
const RIVER_ATLAS_PROBE_SCAN_LIMIT := 8192
var _river_atlas_probe_enabled := false
var _river_atlas_probe_cells: PackedInt32Array = PackedInt32Array()
var _river_atlas_probe_rows: Array[Dictionary] = []
var _river_atlas_probe_context: Dictionary = {}
# P1-E（dynamic_visual_atlas 长帧根治阶段二）：
# 把 ecology pass 内部用于"上一 stride 状态保留"的 3 个 Dict[HexCell→int]
# 改为 PackedByteArray，按 cell.index 直查。这样 cpp pass 的 prev_* 打包循环
# （原 K 次 Dict.get + 哈希），以及 GDScript fallback loop（同样 K 次哈希）
# 都退化为 PackedByteArray O(1) 索引，消除 Dictionary 字段读取开销。
# Dict 版本保留双写为 fallback 兼容（不依赖时可在后续阶段彻底移除）。
# 注意：cell.index < 0 视为 invalid，跳过；resize 由 cache_invalid 路径触发。
var _eco_veg_bytes_arr: PackedByteArray = PackedByteArray()
var _eco_vitality_bytes_arr: PackedByteArray = PackedByteArray()
var _eco_transition_age_arr: PackedByteArray = PackedByteArray()
var _eco_soa_initialized: bool = false  # 与 _ecology_visual_atlas_cache_size 同步失效
# plan/dirty-push-atlas-encode 阶段 E：transition_age > 0 的 cell 即使本 stride
# 没被 sim 写脏，也必须由 baker 自驱重新进入 chunk_step（让 transition_age 按
# 18/stride 衰减；line 800-802）。本 set 在 chunk_step 末尾按结果同步：
#   transition_age > 0 → set[cell] = true
#   transition_age == 0 → set.erase(cell)
# 调度器（DynamicVisualAtlasUploadSystem）在 ecology phase 入口取 set.keys()
# ∪ sim_dirty_cells 作为本 stride 真实工作集。
var _eco_active_decay_set: Dictionary = {}  # HexCell -> true
# H 诊断：bake_weather_field_only 命中率统计。每 30 次调用打一次 dirty 比例 +
# 跳过比例，确认 F 增量路径是否真的吃到便宜。重置时一并清。
var _wf_diag_calls: int = 0
var _wf_diag_dirty_sum: int = 0
var _wf_diag_skipped_full: int = 0  # 整图跳过 Image.update 的次数
var _wf_diag_total_cells: int = 0   # cell_pixel_lists.size()，最近一次记录

const PREBAKED_LOADING_DIR := "res://assets/textures/loading_prebaked_v1/"
const PrebakedResourceRequest = preload("res://scripts/game/loading_resource_request.gd")
static var _prebaked_images: Dictionary = {}
static func prepare_shared_materials_async(frame_gate = null) -> void:
	var paths := [PREBAKED_LOADING_DIR+"noise_rgba.res"]
	var target := _terrain_material_size()
	for i in TERRAIN_MATERIAL_TEXTURE_PATHS.size():
		paths.append(PREBAKED_LOADING_DIR+"material_%d_%d.res" % [target,i])
	if frame_gate != null and frame_gate.canceled:
		return
	var requests := {}
	for path: String in paths:
		if not _prebaked_images.has(path) and ResourceLoader.exists(path):
			requests[path] = PrebakedResourceRequest.new(path)
	var tree := Engine.get_main_loop() as SceneTree
	for path: String in requests:
		var request: PrebakedResourceRequest = requests[path]
		while not request.finished:
			if frame_gate != null and frame_gate.canceled:
				return
			await (frame_gate.next_frame() if frame_gate != null else tree.process_frame)
		if request.result != null:
			_prebaked_images[path] = request.result

static func get_or_build_shared_noise_tex() -> ImageTexture:
	if _shared_noise_tex == null:
		_shared_noise_tex = ImageTexture.create_from_image(_prebaked_images.get(PREBAKED_LOADING_DIR+"noise_rgba.res", load(PREBAKED_LOADING_DIR+"noise_rgba.res")) as Image)
	return _shared_noise_tex

static func get_or_build_shared_terrain_material_tex(target_size: int) -> Texture2DArray:
	if _shared_terrain_material_tex_by_size.has(target_size):
		return _shared_terrain_material_tex_by_size[target_size]
	var result := _build_terrain_material_tex(target_size)
	var texture: Texture2DArray = result.get("texture", null)
	_shared_terrain_material_tex_by_size[target_size] = texture
	_shared_terrain_material_error_by_size[target_size] = String(result.get("reason", ""))
	return texture

static func shared_terrain_material_error(target_size: int) -> String:
	return String(_shared_terrain_material_error_by_size.get(target_size, ""))

static func _build_terrain_material_tex(target_size: int) -> Dictionary:
	return MapMaterialAssets._build_terrain_material_tex(target_size)

## [terrain-web-baked-surface-B 2026-11-01] terrain_material_tex 的第 5 层（micro）源图：
## terrain_micro_data.png（RGBA8 256² 平铺）→ convert RGBA8（若导入格式不同）→
## resize(target_size, LANCZOS) → generate_mipmaps()（与 prebaked material 层一致）。
## 失败返回 null；调用方保留 4 层 array（shader 侧 terrain_material_micro_layer=-1）。
static func _load_terrain_micro_layer_image(target_size: int) -> Image:
	return MapMaterialAssets._load_terrain_micro_layer_image(target_size)

static func _build_noise_tex(size: int, seed_val: int) -> ImageTexture:
	return MapMaterialAssets._build_noise_tex(size, seed_val)

static func _sample_noise_raw(raw: PackedByteArray, size: int, p: Vector2) -> float:
	return MapMaterialAssets._sample_noise_raw(raw, size, p)

static func _noise_raw_at(raw: PackedByteArray, size: int, x: int, y: int) -> float:
	return MapMaterialAssets._noise_raw_at(raw, size, x, y)

# ─── Warp 参数 ────────────────────────────────────────────────────────────
const WARP_AMP := 0.4           # 相对 hex_size，决定 hex 边界扭曲幅度
const WARP_FREQ := 0.024
const WARP_HIGH_FREQ_MUL := 3.4  # 高频 warp 给 sub-hex 犬牙交错细节
const WARP_HIGH_AMP_RATIO := 0.55

# ─── per-biome 详节 noise 强度 ────────────────────────────────────────────
const DETAIL_FREQ_BASE := 0.8
# [P0 地形 relief 重做 2026-06-25] 各向异性脊线 + 连续振幅(relief 门控) + 山脊/谷不对称 +
#   气候耦合；取代旧的"按 terrain 硬分档各向同性 ridged 噪声"。与 world_ext.cpp 逐位对齐。
const RELIEF_AMP := 0.26       # 主起伏振幅（量级对齐旧 MOUNTAIN_RIDGE_AMP，与下游 erosion 同档）
const RELIEF_LO := 0.020       # relief 门控下限：below→趋平（平原视觉真平）
const RELIEF_HI := 0.150       # relief 门控上限：above→满振幅
const RIDGE_SMEAR_HEX := 0.65  # 沿脊线 3-tap smear 步长（hex 单位）
const K_CREST := 1.7           # 山脊尖化指数（>1：尖脊 + 缓谷）
const VALLEY_BIAS := 0.35      # 谷底负偏置（河道落低处，与河流 SDF 自洽）
const CRAG_AMP := 0.05         # 高频岩屑振幅
const CRAG_FREQ_MUL := 1.05    # 岩屑频率乘子

# [P1 hypsometric remap 2026-06-25] Layer A（bake 期 per-pixel 残差塑形）。与 world_ext.cpp 的
#   PkHypsoCurve / pk_hypso_remap_elev 逐位对齐。cell E 已被 C++ Layer B(仿真高程)重塑，此处仅以
#   小 mix 在像素分辨率下重锐化台地边缘（barycentric 插值会把台地/陡坡抹软）。
#   单调三段(可见柔和台地)曲线控制点(land_h 空间)：平原(压平)→缓坡上台→台地shelf(最平)→高山陡升。
#   端点固定 0→0/1→1，PCHIP(Fritsch–Carlson 单调限幅) 保 C1 + 单调（不倒置高程序）。
const HYPSO_LAYER_A_MIX := 0.0    # [bimodal 2026-06-26] 置 0：双峰地台模型已产出平台，Layer A 关闭

# [terrain-normal-bake 2026-06-25] 生成期烘焙"总体地形法线"（粗法线）的参数。
# 半径须小于汇流刻谷的谷宽（约 0.3–0.5 格），否则谷地被低通抹平；格内高频噪声已按奈奎斯特截断。
const TERRAIN_NORMAL_SAMPLE_RADIUS_HEX := 0.35
# [terrain-relief 2026-11-18] 2.10 → 4.50。2.10 档下烘焙法线 xy 实测只有 0.02–0.06，
# nz ≈ 0.998 —— 光照上地形几乎是一张平面，decal 拿不到任何可依附的坡度，这也是
# "贴花贴不住 / 地形起伏感弱"的共同根因。半径仍锁 0.35（注释：再大就抹平谷地），
# 只抬垂直夸张。同步：renderer_material_publish 的 uniform、uniforms.gdshaderinc 默认值。
const TERRAIN_NORMAL_HEIGHT_SCALE_HEX := 2.60

# ─── 轻度侵蚀（仅做边界平滑，不刻河谷） ──────────────────────────────────
const EROSION_DROPS := 6000
const EROSION_MAX_STEPS := 5
const EROSION_INERTIA := 0.10
const EROSION_CAPACITY_FACTOR := 1.5
const EROSION_MIN_CAPACITY := 0.01
const EROSION_DEPOSIT_SPEED := 0.30
const EROSION_ERODE_SPEED := 0.10  # 很轻
const EROSION_EVAPORATION := 0.025
const EROSION_GRAVITY := 4.0
const EROSION_RADIUS := 2

# ─── 河流栅格化 ──────────────────────────────────────────────────────────
const RIVER_CR_STEP := 12
# [river-hierarchy 2026-07-31] 0.035→0.048：拉大绝对笔宽，让干流有足够像素数承载宽度差。
# 支流仍靠下方幂律压细；仅加大基数不会让细河变粗，因为 w≈0.1 时乘数仍接近下限。
const RIVER_STROKE_HEX_FACTOR := 0.048
# SDF 截断距离改小：原 64 让河流过宽（视觉上 1.5 hex 宽），
# 5 pixels 让河保持细线但仍有 anti-alias 渐隐边
# [river-hierarchy 2026-07-31] 5→3.5：固定 SDF 晕圈越宽，细河与粗河越容易被同一条
# 阈值带（river_threshold_low..high）读成相近视觉宽度。收窄晕圈后 stamp 半径主导可见河宽。
const SDF_MAX_DIST_PX := 3.5
# [river-carve-bake 2026-06-25] #2a 河道下切(height 单位，× notch)。与 world_ext.cpp
#   run_bake_geometry_fields_pass 内 PK_BAKE_RIVER_INCISE 同值。仅 legacy(fused 失败)路径用此镜像。
const BAKE_RIVER_INCISE := 0.045
# [coast-beach 2026-06-25] 近岸海滩坡最大下压(height 单位，× smoothstep)。与 world_ext.cpp
#   run_bake_terrain_index_pass 内 PK_COAST_BEACH 同值。
const COAST_BEACH := 0.05
# [coast-carve-bake water-bodies] 海/湖统一离岸像素 SDF 岸坡 carve。与 world_ext.cpp
#   run_bake_geometry_fields_pass 内 coast carve 默认值对齐。SHORE_CARVE_AMP<=0 → 关闭(回退旧 beach)。
#   与 #2a 河流 carve 同法：用 run_bake_coast_sdf_pass(chamfer DT)的离岸像素距离逐像素刻连续岸坡。
const SHORE_CARVE_AMP := 0.06         # 岸坡最大下压(height 单位，× smoothstep)
const SHORE_CARVE_BAND := 6           # 岸坡像素带宽（近岸=满 carve → 带缘=0）
const COAST_SDF_MAX_DIST_PX := 8.0    # chamfer 离岸距离截断（控开销）

# ─── RNG / 噪声 ──────────────────────────────────────────────────────────
var _rng: RandomNumberGenerator
var _warp_noise_lo: FastNoiseLite
var _warp_noise_hi: FastNoiseLite
var _detail_noise: FastNoiseLite
var _ridge_noise: FastNoiseLite

# ─── SUS 双缓冲（接入点 ① · 任务 3） ──────────────────────────────────────
# 切片化烘焙时把新一轮 ocean 数据先写到这些 pending buffer，所有切片完成后
# 在 commit_ocean_buffers() 里一次性原子替换到 world_data，避免 shader 读到
# 半旧半新的撕裂条纹。
var _pending_currents_buf: PackedByteArray = PackedByteArray()
var _pending_upwelling_buf: PackedByteArray = PackedByteArray()
# 旧 vector_atlas 持久交错缓冲。vector_atlas 已退役，字段仅为历史路径清理前的空缓存。
var _vector_atlas_data: PackedByteArray = PackedByteArray()
var _vector_atlas_data_size: Vector2i = Vector2i.ZERO
# upwelling 切片专用：mask 按行 lazy build，避免首片一次性扫整图（~140ms）。
# _pending_upwelling_mask: W*H byte，每像素 1=ocean / 0=land。
# _pending_upwelling_row_built: H byte，行级"已构建"位图；某行第一次被任意切片
# 命中时才会扫该行 W 个像素填 mask + 默认 buf=128，已构建的行直接复用。
# 这样首片只为本片覆盖的几行付出扫描代价（~14ms 而非 ~140ms）。
var _pending_upwelling_mask: PackedByteArray = PackedByteArray()
var _pending_upwelling_row_built: PackedByteArray = PackedByteArray()
# 锁定的 season_phase（切片开始时记下，整轮使用同一个 phase 避免中途漂移）。
var _pending_phase: float = 0.0
# pending buffer 的目标尺寸（W, H）。下一轮重置或 discard 时清零。
var _pending_size: Vector2i = Vector2i.ZERO

# Physical Wind & Ocean Circulation：跨 slice 的 hex 求解状态（仅当
# cfg.physical_circulation_enabled = true 时使用）。
#
# 旧设计：第一片调用 bake_ocean_currents_slice 时**一次性**求解全部 hex 字段
# （SLP / wind / curl / ψ / ocean_current / upwelling）；ocean_currents 监控
# 显示 max=200ms+ 的 tick，全部来自这条 fat 第一片。
#
# 新设计（Phys Solve Sliced）：把求解拆成 7 个阶段（_PHYS_STAGE_*），每个 stage
# 5~30ms。OceanCurrentsJob 在每次 run_slice 先调 `_physical_solve_step_one`
# 推进一阶，全部完成后再开始按像素区间光栅化。`_phys_stage` 跟踪当前阶段；
# `_phys_psi_iters_done` 跟踪 SOR 迭代分摊进度（_PHYS_PSI_TOTAL_ITERS / _PER_STEP）。
# 一次性入口 `_physical_solve_for_phase` 仍可用（loop 调 step_one），给 bake_world /
# rebake_ocean_currents 等需要原子完成的路径使用。
var _pending_phys_solved_phase: float = NAN
var _pending_psi_state = null  # PhysicalCirculationSolver.PsiSolverState 或 null
var _pending_wind_buf: PackedByteArray = PackedByteArray()
# Block B（master 手册 §4）：DCWorldExt 引用，由 MapGenerator 在 bake_world / 加载存档
# 末尾通过 set_world_ext() 注入。null 时所有 C++ hook 走 GDScript fallback。
# 当前用于 _PHYS_STAGE_WIND C++ 化（run_wind_field_pass）；后续可扩展给 ψ / upwelling。
var _world_ext = null
var _visual_tile_generation_id: int = 0
## visual tile 公共 knob 缓存（canal 增量重烘复用）。注意：组装函数叫
## `_visual_tile_base_knobs(...)`，GDScript 不允许变量与函数同名，所以缓存加 _cache 后缀。
var _visual_tile_base_knobs_cache: Dictionary = {}
# 全局基线的刻谷/侵蚀前程序高度（hm_size）。visual tile 用它把 1024 基线丢掉的高频
# 程序地形按 tile 分辨率补回；为空时 tile 退回纯基线高度。
var _baseline_procedural_height := PackedFloat32Array()
var _visual_tile_refresh_layers: Dictionary = {}
var _visual_tile_refresh_running: bool = false
var _last_bake_map: MapData = null
# DOTS-Final-Push 修复：sea_ice prepare / 其他需要 ClimateProfile 的路径不能再依赖
# `world.get("config")`（WorldData 上根本没有 config 字段，永远返回 null，导致
# `use_native` 一直 false 走 48ms GDScript 回扫）。改由 MapGenerator 在 bake_world
# 末尾通过 set_climate_profile() 显式注入。null 时回退到旧的 cfg 参数路径。
var _climate_profile = null
var _world_clock_ref = null
var _enum_atlas_cpp_skip_reason: String = ""
# Block B (wind_field/B) 一次性诊断标记 — 仿 climate_b/F.3 / weather/F.1 路径。
var _wind_b_first_run_logged: bool = false
# DOTS-Final-Push 后续诊断 — wind stage 2 路径决策诊断（前 3 次进入 stage 2
# 都打印，避免 once-only 在启动期被消耗 / 用户截断日志看不到首次打印的情况）。
var _wind_b_path_log_count: int = 0
# DOTS-Final-Push 后续诊断 — wind C++ commit 阶段 size-check 诊断。
# 用于定位"_rc_wind>=0 但 commit 阶段静默 fallback"的边界 case（wspd_out 未回传等）。
# 同样改为前 3 次都打印。
var _wind_b_commit_diag_count: int = 0
# DOTS-Final-Push 任务 6.2：sea_ice atlas prepare 路径选择诊断（once-only）。
# 日志显示 path=gdscript 但 climate_profile default 是 true ——
# 必须暴露 use_native 判定中四个条件分别命中情况，定位真正 false 的那一项。
var _sea_ice_path_logged: bool = false
# ── Phys Solve wrapper 开销削减缓存（2026-07-07）────────────────────────
# 拓扑/几何/配置在 sim 期固定，故把各 stage knob 的「常量字段」预建成 base
# dict（按 map+profile+hex_size 失效），每调用只 .duplicate() 一次 + 覆盖变化
# 字段（season_phase / sim_day / world_seed / prev_slp_arr / wind 数组），
# 替代原先每 stage 每调用重建 27/22/25/7 字段 Dictionary（含 7 次 profile
# 属性读取 + 多次 int() 枚举转换）与 4 字节常量 water_ids 数组。
# 零接口变更、无需重建 DLL，fallback 路径完全保留。PROBE 验收见
# tmp/cutting_native_daily_ocean.md §7.5。
var _phys_knob_cache_map = null
var _phys_knob_cache_profile = null
var _phys_knob_cache_hex: float = NAN
var _phys_water_ids_cache: PackedByteArray = PackedByteArray()
var _phys_knobs_base_slp: Dictionary = {}
var _phys_knobs_base_wind: Dictionary = {}
var _phys_knobs_base_psi: Dictionary = {}
var _runtime_physics_knobs_reported: bool = false
var _runtime_physics_visual_view: Dictionary = {}
var _phys_knobs_base_up: Dictionary = {}
# DOTS-Final-Push 任务 6.2：upwelling C++ 路径选择诊断（once-only）。
# stage 6 GDScript fallback ~92ms 是当前最大瓶颈。原因可能是 _phys_wind_done_by_cpp
# 没翻 true（wind C++ 路径失败），或 use_gdext_physical_circulation 没生效。
var _upwelling_path_logged: bool = false
# DOTS-Total-CPP 诊断：path-decision once-only 不够，需要每次 stage 6 都 log
# 前 5 次完整路径决策 + 内层 fallback 原因 + 实测 GDScript fallback 耗时。
var _upwelling_diag_count: int = 0
# plan/dots-slp-psi-cpp — SLP stage 1 path-decision / commit-diag / fallback,
# fronts 3 hits each (matches wind_field/B style; once-only logs are usually
# consumed before the user sees them in long sessions).
var _slp_path_log_count: int = 0
var _slp_commit_diag_count: int = 0
var _slp_first_run_logged: bool = false
var _slp_native_ms_last: float = -1.0
var _slp_path_str_last: String = "gdscript"
# 临时根因诊断（SLP/wind 冻结排查 2026-06-08）：运行期每 N 次调用打印一次
# rc / size / 是否进入 commit，区分 C++ fallback(rc<0) 与 commit gate 拦截(size 不符)。
# 不受上面 3 次上限限制，定位"为何 map.slp_arr 全程不更新"。排查完可删除。
var _slp_rt_diag_count: int = 0
# plan/dots-slp-psi-cpp — PSI stage 3+4+5 fused C++ path diagnostics.
var _psi_path_log_count: int = 0
# Fix #11 second pass (2026-06-16)：BREAKDOWN print 独立计数（避免和 path-decision
# 的 _psi_path_log_count 混用，后者只在 path-decision 块自增，卡在 3 后让 BREAKDOWN
# 误命中 <=3 一直打）。
var _psi_breakdown_log_count: int = 0
var _psi_commit_diag_count: int = 0
var _psi_first_run_logged: bool = false
var _psi_native_ms_last: float = -1.0
var _psi_path_str_last: String = "gdscript"
var _psi_iters_run_last: int = 0
var _psi_residual_final_last: float = 0.0
var _psi_early_exit_last: bool = false
var _psi_mode_last: String = "off"
var _slp_thermal_p95_last: float = 0.0
var _slp_delta_p95_last: float = 0.0
var _wind_delta_p95_last: float = 0.0
var _wind_dir_delta_p95_last: float = 0.0
var _wind_dir_flip_count_last: int = 0
# NS 化四方向深化诊断(plan/NS化气候动力学四方向深化;gate 全关时恒 0,键始终存在)
var _wind_momentum_delta_p95_last: float = 0.0
var _wind_momentum_advect_w_eff_last: float = 0.0
var _wind_momentum_diffuse_w_eff_last: float = 0.0
var _wind_div_damp_alpha_eff_last: float = 0.0
var _wind_traj_gen_last: int = 0
var _wind_traj_stale_count_last: int = 0
var _ocean_delta_p95_last: float = 0.0
var _thermal_current_p95_last: float = 0.0
var _ocean_current_preclamp_p95_last: float = 0.0
var _ocean_current_preclamp_max_last: float = 0.0
var _ocean_current_clamp_count_last: int = 0
var _ocean_current_clamp_ratio_last: float = 0.0
var _ocean_current_max_magnitude_last: float = 0.0
# NS 化 Phase 4 诊断(gate 关闭时恒 0)
var _ocean_topo_steer_w_eff_last: float = 0.0
var _ocean_depth_curl_damp_eff_last: float = 0.0
var _phys_solve_rt_diag_count: int = 0
var _phys_last_season_phase: float = NAN
var _phys_last_sim_day: int = -1
# synoptic 相位的绝对日权威。C++ 物理 pass 里 sim_day 只服务天气相位（SLP/wind synoptic
# 行星波、移动低压的平移与纬度摆动），必须单调递增；季节效应另走 season_phase +
# axial_tilt_deg，与 sim_day 无关。
# 历史 bug（2026-08-03）：daily 路径由 ocean_currents_job 传 ctx.day_index（绝对日，6174…），
# 而 _physical_solve_step_one / _physical_solve_native_oneshot 传
# _season_phase_to_day_of_year()（年内日 0..364）。两套单位喂同一个 synoptic 相位，
# 使 SLP 波与 wind 扰动处于互不相关的相位，且每逢新年归零倒退。
var _phys_abs_sim_day: int = -1
# 上一次真正跑过 wind 段的绝对日，用于把 wind_max_turn_deg_per_day 从「每次调用」
# 还原成「每游戏日」（wind 段每 24 tick 才跑一次，见 C++ wind_elapsed_days 注释）。
var _phys_last_wind_sim_day: int = -1
var _phys_last_slp_rc_ms: float = -1.0
var _phys_last_slp_out_size: int = -1
var _phys_last_slp_published_to_slot: bool = false
var _phys_last_slp_commit_ok: bool = false
var _phys_last_wind_rc_ms: float = -1.0
var _phys_last_wind_wx_size: int = -1
var _phys_last_wind_wy_size: int = -1
var _phys_last_wind_speed_out_size: int = -1
var _phys_last_wind_map_speed_size: int = -1
var _phys_last_wind_commit_ok: bool = false
var _daily_wind_diag_last: Dictionary = {}

# Phys Solve Sliced：求解状态机阶段。
const _PHYS_STAGE_NONE: int = 0           # 还未开始 / 已完成 idle
const _PHYS_STAGE_SLP: int = 1            # 解海陆压力场 ~5ms
const _PHYS_STAGE_WIND: int = 2           # 解物理化风场 ~5ms
const _PHYS_STAGE_PSI_INIT: int = 3       # 初始化 ψ 求解器（含 curl τ） ~3ms
const _PHYS_STAGE_PSI_ITERS: int = 4      # 分摊 SOR 迭代；按 _PER_STEP 推进
const _PHYS_STAGE_PSI_FINALIZE: int = 5   # ψ→ocean_current + commit_psi ~3ms
const _PHYS_STAGE_UPWELLING: int = 6      # 解沿岸 Ekman + 高纬冷沉 ~3ms
const _PHYS_STAGE_WIND_RASTER: int = 7    # NaN 守门 + 风场 RG8 光栅化 ~3ms
const _PHYS_STAGE_DONE: int = 8

# SOR 总迭代数。psi_total_iters 直接传给 C++ run_psi_solver_pass（一次跑完），
# 也用于 GDScript fallback 的 8/step 分摊。
# plan/psi-warm-start（2026-06-17）：40→16。C++ run_psi_solver_pass 现默认 warm-start
# （用上一轮发布在 cell_ocean_psi slot 的 ψ 作 SOR 初值，psi_warm_start=true）。洋流
# 流函数日间变化极小，warm-start 后残差很小，16 次 Gauss-Seidel 扫描足以重新收敛，
# PSI kernel 从 ~1ms 降到 ~0.3ms。验证：日志 phys_slice 的 ocean_delta_p95 应保持
# 平滑（不再每轮大幅跳动）。若需冷启动对照，传 psi_warm_start=false 并回调迭代数。
const _PHYS_PSI_TOTAL_ITERS: int = 16
const _PHYS_PSI_ITERS_PER_STEP: int = 8

# Phys Solve Sliced：WIND_RASTER 阶段把"hex → W×H RGB8 风场 buffer"分多步写盘。
# 30000 像素 × ~0.2us = ~6ms / step；典型 derived_size 256×256=65k → 3 步完成。
const _PHYS_WIND_RASTER_PIXELS_PER_STEP: int = 30000

var _phys_stage: int = _PHYS_STAGE_NONE
var _phys_psi_iters_done: int = 0
var _phys_wind_raster_idx: int = 0
var _phys_wind_done_by_cpp: bool = false
var _initial_physical_deferred: bool = false
# 同类 bind-defer 标志：per-cell LUT 编码读 DCWorldExt 的绑定 slot，而 bind_map_data
# 要等 bake_world 返回、init_soa_from_bake 跑完才发生。就地烘必然退回 GDScript，
# 故推迟到 bind 之后由 run_deferred_initial_cell_luts() 走 C++ 补烘。
var _initial_cell_luts_deferred: bool = false

# Item 2b (2026-07-07)：phys leaf pass cell-range 切片游标 + 总开关。
# 默认 _phys_cell_slice_enabled=false → 完全 inert（与历史逐位等价）。开启后把 SLP/WIND/
# UPWELLING 各自拆成 _phys_cell_slice_divisor 段 cell-range 子调用，降低单帧尖刺。
# 约定：每个 leaf pass 内部用 end_idx==n_cells 判定末片 —— SLP 末片才写回 map.slp_arr，
# WIND/UPWELLING 末片才做 commit 检查；中间切片只推进游标、停留当前 stage、return false 续帧。
# 切片正确性依赖 GDScript 游标保证覆盖全 [0,n_cells)；C++ 侧 _phys_slp_buf 跨切片累积 Pass A。
var _phys_cell_slice_enabled: bool = false
var _phys_cell_slice_divisor: int = 8
var _phys_slp_cursor: int = 0
var _phys_wind_cursor: int = 0
var _phys_upwelling_cursor: int = 0

const _INITIAL_PHYSICAL_SEASON_PHASE: float = 1.5

var _prev_weather_lut_bytes: PackedByteArray = PackedByteArray()  # 帧间插值:上一次 weather LUT 字节
var _weather_lut_bytes_cache: PackedByteArray = PackedByteArray()  # weather-only 增量发布缓存

const EKMAN_DEFLECTION_RAD := 0.7854
const _THERMOHALINE_DEFAULT := 0.25
const _UPWELLING_COAST_TANGENT_MIN := 0.55
const _UPWELLING_HIGHLAT_ABS := 0.6

# [qa-skip-lut-publish 2026-11-02] 二分"渲染线程崩溃是否与每日 LUT 纹理上传有关"。
# 只有在 user://pk_debug.cfg 里写 `[render] skip_lut_publish=true` 才生效；正常玩家
# 没有这个文件 ⇒ 恒为 false，行为与改动前一致。
static var _qa_skip_lut_publish_cache := -1
static func _qa_skip_lut_publish() -> bool:
	if _qa_skip_lut_publish_cache >= 0:
		return _qa_skip_lut_publish_cache == 1
	var cfg := ConfigFile.new()
	var enabled := false
	if cfg.load("user://pk_debug.cfg") == OK:
		enabled = bool(cfg.get_value("render", "skip_lut_publish", false))
	_qa_skip_lut_publish_cache = 1 if enabled else 0
	if enabled:
		print("[map_baker] QA: skip_lut_publish=true (daily LUT texture uploads disabled)")
	return enabled

func _encode_upwelling_tex(upwelling_buf: PackedByteArray, size: Vector2i,
		existing: ImageTexture = null) -> ImageTexture:
	return DCAtlasEncoders.encode_upwelling_tex(upwelling_buf, size, existing, _world_ext)

# PR-3.1.1（master 手册 §6.2）：_encode_r8_tex 已搬到 DCAtlasEncoders.encode_r8_tex。
# 本 facade 保留作为 in-class shim，避免 caller 全部一次性改动。
# 后续 PR 可逐步把 caller 改为 DCAtlasEncoders.encode_r8_tex 直调。
func _encode_r8_tex(buf: PackedByteArray, size: Vector2i, existing: ImageTexture) -> ImageTexture:
	return DCAtlasEncoders.encode_r8_tex(buf, size, existing, _world_ext)

# [river-render-restore 2026-06-19] 河流 SDF（float[0,1]，1=河心）→ L8 纹理。
# 与 height_tex 共用同一 uv（world_origin/world_size 覆盖同一 world_bounds），
# shader 在 uv 处采样得到 [0,1] 河流强度，喂回 land_pipeline 的 flow 视觉层。
func _encode_flow_tex(buf: PackedFloat32Array, size: Vector2i, existing: ImageTexture) -> ImageTexture:
	return DCAtlasEncoders.encode_flow_tex(buf, size, existing, _world_ext)

# Emergent Climate Coupling：从 HexCell.sea_ice_fraction 把 per-cell 的连续海冰覆盖率
# 光栅化为 derived-size 的 R8 buffer，并写到独立的 sea_ice_tex（原地 update）。
#
# Daily Sim SoA Refactor 阶段 1：之前是写到 scalar_atlas.a，每天 RGBA8 整张 ~7MB 上传，
# 浪费 75% 带宽（RGB 三通道是 bake 后的恒定地形数据）。现在拆出独立 R8 纹理，
# 每日上传 ~1.7MB，且 scalar_atlas 在 bake_world 后不再触碰。
#
# 实现要点：
#   - 走 world.pixel_to_cell_lookup（per-pixel → HexCell 引用），O(W*H) 纯 array index，
#     与 rebake_biome_axes_only 等每日 pass 的 fast path 同源；
#   - 没有 lookup 时回退到全 0 + 警告（保守）；
#   - 陆地 cell 的 sea_ice_fraction 恒为 0，天然得到全 0；
#   - sea_ice_tex 走 ImageTexture.update() 原地刷新，不重建句柄。
#
# 调用约定：旧 sea_ice_atlas_upload 曾每 stride 日调用一次；当前生产路径不再调用。
var _ocean_pixel_to_cell_idx: PackedInt32Array = PackedInt32Array()
var _ocean_pixel_cache_key: Array = []
