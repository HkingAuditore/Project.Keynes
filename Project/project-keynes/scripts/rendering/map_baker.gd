# map_baker.gd v6
#
# ─── Phase G.2 / dots-full-migration §G.2 计划状态（2026-05-13）──────────
#
# 本文件当前 2583 行，dots-full-migration plan 目标拆完后 ≤ 200 行。
# 拆分目的地骨架（B.2 已就位 + 详细迁移规格在各骨架文件顶部）：
#
#   rendering/bakers/baker_context.gd         ← 共享 ViewAdapter / dirty mask（已实现）
#   rendering/bakers/atlas_encoders.gd        ← 6 个 _encode_*_tex / _encode_*_atlas
#                                                helper（最易，先迁移；line 1866-2020）
#   rendering/bakers/terrain_baker.gd         ← _bake_height_biome_moisture (line 1315) +
#                                                _bake_river_sdf + _trace_* + _hydraulic_erosion
#   rendering/bakers/climate_baker.gd         ← bake_sea_ice_fraction_only (line 2021) +
#                                                climate atlas 编码段
#   rendering/bakers/weather_baker.gd         ← bake_weather_field_only (line 2158) +
#                                                _bake_wind_field (line 2338) +
#                                                _rasterize_wind_*  (line 2828+)
#   rendering/bakers/overlay_baker.gd         ← data overlay 通道（已部分由
#                                                data_overlay_baker.gd 承担）
#
# G.2 完成后 map_baker.gd 残留：
#   - bake_world(map, cfg, hex_size, seed_val) -> WorldData 入口（弱协调多 baker 调用）
#   - 各 sub-baker 的 dispatch 函数（rebake_*_tex_only / rebake_ocean_currents 等）
#   - 共享常量（NORM_MAX 等已属本文件）
#
# 当前各 sub-baker 是 placeholder（push_warning），actual function migration is
# the work of subsequent PRs。
#
# **推荐迁移顺序**（每函数独立 PR + 截图像素 diff < 0.1% 验收）：
#   1. atlas_encoders.gd 的 6 个 helper（最简单，纯 static func 搬动即可）
#   2. terrain_baker.gd 的 _bake_river_sdf 系列（独立性强）
#   3. climate_baker.gd 的 bake_sea_ice_fraction_only（独立 R8 atlas）
#   4. weather_baker.gd 的 bake_weather_field_only
#   5. terrain_baker.gd 的 _bake_height_biome_moisture（最大、最复杂）
#
# ─── 原始流程说明（保留）────────────────────────────────────────────────
#
# 把 MapData（per-hex 玩法层）涂抹成高分辨率 WorldData（视觉层）。
# 设计原则：hex 是真理，烘焙只是"模糊化 + 加细节" 让 hex 边界看不出直边。
#
# 流程：
#   1. heightmap：cell.elevation 用 warped barycentric 在 3 邻 hex 之间插值，
#      再叠 per-biome detail noise（mountain → ridged，hill → fbm 等）
#   2. biome_tex：warped NEAREST 查最近 hex 的 cell.terrain（v4 风格，但分辨率高）
#   3. 轻度水力侵蚀：在 heightmap 上跑稀疏 raindrop，让 hex 边界更自然
#   4. 河流：cell.has_river 链 → Catmull-Rom 曲线 → 栅格化 SDF
#   5. 湿度：cell.moisture 用 warped barycentric 上采样
#
# 整张地图分辨率 1024×N（hm_size = derived_size，统一），
# 一次 warp + cube_round 同时产出 height / biome / moisture，省一遍循环。

class_name MapBaker

# 生成期阶段进度信号。main.gd 的 splash overlay 接此信号显示阶段提示，
# 避免开场 ~13 秒黑屏体感。fraction 是该阶段相对总耗时的估计值（0.0..1.0
# 累积），不是精确百分比；目的是让用户知道在跑哪一步、还差多少。
# stage 取值（按 emit 顺序）：
#   "terrain"    — _bake_height_biome_moisture / erosion / river SDF / latitude
#   "physical"   — _bake_initial_physical_circulation / vector buffers
#   "volcano"    — _bake_volcano_field
#   "atlas"      — dynamic / ecology / smooth / ice atlas 初始化
#   "encode"     — _encode_*_tex / atlas 整体编码
#   "done"       — bake_world 全部完成（fraction=1.0）
signal stage_progress(stage: String, fraction: float)

const WindBeltScript = preload("res://scripts/weather/wind_belt.gd")
# Physical Wind & Ocean Circulation：hex 域物理化求解器。当
# ClimateProfile.physical_circulation_enabled = true 时，bake_world / 切片烘焙
# 路径用它替换 ny-only 风场 + Ekman 洋流的旧实现，输出从 hex 字段（cell.wind_vector
# / cell.ocean_current / cell.upwelling_strength 等）光栅化到现有 buffer，shader 零改动。
const PhysCircSolverScript = preload("res://scripts/rendering/physical_circulation_solver.gd")

# ─── 分辨率 ───────────────────────────────────────────────────────────────
# 桌面 1024×N，移动端 512×N。hex 网格本身只 60×40，1024 已远超；移动端 512
# 让 derived_size 从 1024×606 (620k px) 降到 512×303 (155k px) — atlas RGBA
# 从 2.4MB 降到 0.6MB，4 张总 GPU 上传从 9.6MB 降到 2.4MB，Adreno 830 上单
# tick atlas commit 从 12ms 降到 ~3ms。地形细节肉眼可分辨度差异可接受
# （hex 边界已被 warp noise 模糊）。需要时把 _hm_max_dim() 改回 1024 即可
# 强制移动端走桌面分辨率。
const HM_MAX_DIM_DESKTOP := 1024
const HM_MAX_DIM_MOBILE := 512

static func _hm_max_dim() -> int:
	# F12 调试热键（2026-06-14）：force_atlas_quarter_size meta 临时把移动端
	# atlas 从 512 进一步降到 256，看 GPU 负载减半 FPS 提升多少。重启失效。
	if Engine.has_meta(&"force_atlas_quarter_size") and bool(Engine.get_meta(&"force_atlas_quarter_size")):
		return 256
	return HM_MAX_DIM_MOBILE if OS.has_feature("mobile") else HM_MAX_DIM_DESKTOP

# 兼容：保留旧常量名，值跟 desktop 一致。其它文件仍引用 HM_MAX_DIM 时不破坏；
# 真正决定渲染分辨率的是 _resolve_hm_size() 里调 _hm_max_dim()。
const HM_MAX_DIM := HM_MAX_DIM_DESKTOP

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

# Daily Sim SoA Refactor 阶段 1：海冰 GPU 上传从 scalar_atlas.a 拆出到独立 sea_ice_tex（R8）。
# 拆分前每日要传整张 RGBA8（2400×?，~7MB），其中 RGB 三通道是地形烘焙后的恒定值，
# 仅 A 通道每日变化，纯属冗余带宽。拆分后：
#   - scalar_atlas 的 RGB 三通道在 bake_world 编码一次后永不再传；A 通道写 0 占位。
#   - sea_ice_tex 为独立 R8（FORMAT_L8），每日 ~1.7MB（带宽 -75%），由 SeaIceAtlasUploadJob 驱动。
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
# 由 EnumAtlasUploadJob/System 在 slice 结束后读取并转存到 MapGenerator。
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

static func get_or_build_shared_noise_tex() -> ImageTexture:
	if _shared_noise_tex == null:
		_shared_noise_tex = _build_noise_tex(NOISE_TEX_SIZE, NOISE_TEX_SEED)
	return _shared_noise_tex

static func _build_noise_tex(size: int, seed_val: int) -> ImageTexture:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val
	var raw := PackedByteArray()
	raw.resize(size * size)
	for i in range(size * size):
		raw[i] = rng.randi_range(0, 255)

	var data := PackedByteArray()
	data.resize(size * size * 4)
	for y in range(size):
		for x in range(size):
			var p := Vector2(float(x), float(y))
			var n1 := _sample_noise_raw(raw, size, p)
			var n2 := n1 * 0.5 + _sample_noise_raw(raw, size, p * 2.03) * 0.24
			var n3 := n2 + _sample_noise_raw(raw, size, p * 2.03 * 2.03) * 0.1152
			var n4 := n3 + _sample_noise_raw(raw, size, p * 2.03 * 2.03 * 2.03) * 0.055296
			var idx: int = (y * size + x) * 4
			data[idx] = clampi(int(round(n1 * 255.0)), 0, 255)
			data[idx + 1] = clampi(int(round(n2 * 255.0)), 0, 255)
			data[idx + 2] = clampi(int(round(n3 * 255.0)), 0, 255)
			data[idx + 3] = clampi(int(round(n4 * 255.0)), 0, 255)
	# v10.noise-pack：开启 mipmap。高频水纹/雪线/植被 dissolve 采样同一张预烘
	# RGBA fBM 噪声包；mipmap 让远距离/高频采样自动预滤波，降低 cache 抖动和 aliasing。
	var img := Image.create_from_data(size, size, false, Image.FORMAT_RGBA8, data)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

static func _sample_noise_raw(raw: PackedByteArray, size: int, p: Vector2) -> float:
	var x0 := int(floor(p.x))
	var y0 := int(floor(p.y))
	var fx := p.x - float(x0)
	var fy := p.y - float(y0)
	var ux := fx * fx * (3.0 - 2.0 * fx)
	var uy := fy * fy * (3.0 - 2.0 * fy)
	var a := _noise_raw_at(raw, size, x0, y0)
	var b := _noise_raw_at(raw, size, x0 + 1, y0)
	var c := _noise_raw_at(raw, size, x0, y0 + 1)
	var d := _noise_raw_at(raw, size, x0 + 1, y0 + 1)
	return lerpf(lerpf(a, b, ux), lerpf(c, d, ux), uy)

static func _noise_raw_at(raw: PackedByteArray, size: int, x: int, y: int) -> float:
	var xx := posmod(x, size)
	var yy := posmod(y, size)
	return float(raw[yy * size + xx]) / 255.0

# ─── Warp 参数 ────────────────────────────────────────────────────────────
const WARP_AMP := 0.4           # 相对 hex_size，决定 hex 边界扭曲幅度
const WARP_FREQ := 0.024
const WARP_HIGH_FREQ_MUL := 3.4  # 高频 warp 给 sub-hex 犬牙交错细节
const WARP_HIGH_AMP_RATIO := 0.55

# ─── per-biome 详节 noise 强度 ────────────────────────────────────────────
const DETAIL_FREQ_BASE := 0.8
const MOUNTAIN_RIDGE_AMP := 0.2
const HILL_AMP := 0.04
const PLAIN_AMP := 0.015

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
const RIVER_STROKE_HEX_FACTOR := 0.035
# SDF 截断距离改小：原 64 让河流过宽（视觉上 1.5 hex 宽），
# 5 pixels 让河保持细线但仍有 anti-alias 渐隐边
const SDF_MAX_DIST_PX := 5.0

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
var _slp_thermal_p95_last: float = 0.0
var _slp_delta_p95_last: float = 0.0
var _wind_delta_p95_last: float = 0.0
var _ocean_delta_p95_last: float = 0.0
var _thermal_current_p95_last: float = 0.0
var _ocean_current_preclamp_p95_last: float = 0.0
var _ocean_current_preclamp_max_last: float = 0.0
var _ocean_current_clamp_count_last: int = 0
var _ocean_current_clamp_ratio_last: float = 0.0
var _ocean_current_max_magnitude_last: float = 0.0
var _phys_solve_rt_diag_count: int = 0
var _phys_last_season_phase: float = NAN
var _phys_last_sim_day: int = -1
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

# ─── 公开接口 ─────────────────────────────────────────────────────────────

const _INITIAL_PHYSICAL_SEASON_PHASE: float = 1.5


func _bake_initial_physical_circulation(map: MapData, world: WorldData, hex_size: float, cfg: MapConfig) -> void:
	_initial_physical_deferred = false
	if not _use_physical_circulation(cfg):
		return
	var ext_ready_now: bool = _world_ext != null and map != null and map.has_indices() and map.has_soa()
	if not ext_ready_now and ClassDB.class_exists("DCWorldExt"):
		_initial_physical_deferred = true
		_pending_currents_buf = PackedByteArray()
		_pending_upwelling_buf = PackedByteArray()
		_pending_upwelling_mask = PackedByteArray()
		_pending_upwelling_row_built = PackedByteArray()
		_pending_wind_buf = PackedByteArray()
		_pending_size = Vector2i.ZERO
		_pending_phys_solved_phase = NAN
		_pending_psi_state = null
		_phys_stage = _PHYS_STAGE_NONE
		_phys_psi_iters_done = 0
		_phys_wind_raster_idx = 0
		_phys_wind_done_by_cpp = false
		print("  physical circulation hex solve: deferred until DCWorldExt bind (ext=%s idx=%s soa=%s)" % [
			str(_world_ext != null), str(map != null and map.has_indices()), str(map != null and map.has_soa())
		])
		return
	var t_phys := Time.get_ticks_msec()
	var saved_world_ext = _world_ext
	# 若 native 尚未满足安全条件且本平台没有 DCWorldExt 可用于后置刷新，保留旧的
	# GDScript 兜底；否则 ext_ready_now=true 时直接使用已绑定的当前 map slots。
	if not ext_ready_now:
		_world_ext = null
	_physical_solve_for_phase(map, world, hex_size, cfg, _INITIAL_PHYSICAL_SEASON_PHASE)
	_world_ext = saved_world_ext
	# Vector atlas was removed; only the per-cell fields are needed before
	# MapData.init_soa_from_bake() mirrors them into SoA.
	_pending_currents_buf = PackedByteArray()
	_pending_upwelling_buf = PackedByteArray()
	_pending_upwelling_mask = PackedByteArray()
	_pending_upwelling_row_built = PackedByteArray()
	_pending_wind_buf = PackedByteArray()
	_pending_size = Vector2i.ZERO
	_pending_phys_solved_phase = NAN
	_pending_psi_state = null
	_phys_stage = _PHYS_STAGE_NONE
	_phys_psi_iters_done = 0
	_phys_wind_raster_idx = 0
	_phys_wind_done_by_cpp = false
	print("  physical circulation hex solve: %dms" % (Time.get_ticks_msec() - t_phys))

func _bake_initial_vector_buffers(map: MapData, world: WorldData, hex_size: float, cfg: MapConfig) -> void:
	if map == null or world == null:
		return
	var t_vec := Time.get_ticks_msec()
	var pix_total: int = world.derived_size.x * world.derived_size.y
	if pix_total <= 0:
		return
	# vector_atlas 已退役 → 跳过逐像素风/洋流光栅（纯视觉）。
	# per-cell 风/洋流求解已在 _bake_initial_physical_circulation / 物理 solve 写入
	# HexCell（气候/天气仿真读它，不读这些像素 buffer），故清空像素 buffer 并提前返回。
	# shader 端固定使用中性风/洋流向量。
	if not DCFeatureFlags.ocean_current_visual_active():
		world.wind_field_buffer = PackedByteArray()
		world.ocean_current_buffer = PackedByteArray()
		world.ocean_upwelling_buffer = PackedByteArray()
		print("  wind/ocean pixel buffers: skipped (ocean_current_visual off)")
		return
	if _use_physical_circulation(cfg) and _initial_physical_deferred:
		world.wind_field_buffer = PackedByteArray()
		world.ocean_current_buffer = PackedByteArray()
		world.ocean_upwelling_buffer = PackedByteArray()
		_pending_currents_buf = PackedByteArray()
		_pending_upwelling_buf = PackedByteArray()
		_pending_upwelling_mask = PackedByteArray()
		_pending_upwelling_row_built = PackedByteArray()
		_pending_wind_buf = PackedByteArray()
		_pending_size = Vector2i.ZERO
		print("  wind/ocean/upwelling pixel buffers: deferred until DCWorldExt bind (%dms)" % (Time.get_ticks_msec() - t_vec))
		return
	if _use_physical_circulation(cfg):
		_ensure_pending_currents_size(world)
		_ensure_pending_wind_size(world)
		var wind_raster_done: bool = _pending_wind_buf.size() >= pix_total * 2
		var ocean_raster_done: bool = false
		if _world_ext != null:
			if not wind_raster_done:
				var wind_ret: Dictionary = run_wind_field_rasterize_full(map, world, cfg)
				wind_raster_done = not bool(wind_ret.get("fallback", true))
			var ocean_ret: Dictionary = run_ocean_field_rasterize_full(map, world, cfg)
			ocean_raster_done = not bool(ocean_ret.get("fallback", true))
		if not wind_raster_done:
			_rasterize_wind_slice_from_hex(world, _pending_wind_buf, 0, pix_total)
		if not ocean_raster_done:
			_rasterize_ocean_current_slice_from_hex(world, _pending_currents_buf, 0, pix_total)
		# 方案 B-1：物理路径下不再光栅化 ocean_upwelling_buffer
		# （per-cell SoA / 主视觉路径无消费者，F6 调试由 lazy bake 现场光栅化）。
		world.wind_field_buffer = _pending_wind_buf
		world.ocean_current_buffer = _pending_currents_buf
		world.ocean_upwelling_buffer = PackedByteArray()
	else:
		world.wind_field_buffer = _bake_wind_field(world.world_bounds, world.derived_size, _INITIAL_PHYSICAL_SEASON_PHASE)
		world.ocean_current_buffer = _bake_ocean_currents(map, hex_size, world, cfg, _INITIAL_PHYSICAL_SEASON_PHASE)
		world.ocean_upwelling_buffer = _bake_ocean_upwelling(map, hex_size, world, cfg, _INITIAL_PHYSICAL_SEASON_PHASE)
	_rebuild_vector_atlas_data_from_buffers(world)
	_pending_currents_buf = PackedByteArray()
	_pending_upwelling_buf = PackedByteArray()
	_pending_upwelling_mask = PackedByteArray()
	_pending_upwelling_row_built = PackedByteArray()
	_pending_wind_buf = PackedByteArray()
	_pending_size = Vector2i.ZERO
	_pending_phys_solved_phase = NAN
	_pending_psi_state = null
	print("  wind/ocean/upwelling pixel buffers: %dms" % (Time.get_ticks_msec() - t_vec))

func run_deferred_initial_physical_circulation(map: MapData, world: WorldData, hex_size: float, cfg: MapConfig) -> bool:
	if not _initial_physical_deferred:
		return false
	if not _use_physical_circulation(cfg):
		_initial_physical_deferred = false
		return false
	var t_deferred := Time.get_ticks_msec()
	_initial_physical_deferred = false
	_physical_solve_for_phase(map, world, hex_size, cfg, _INITIAL_PHYSICAL_SEASON_PHASE)
	_bake_initial_vector_buffers(map, world, hex_size, cfg)
	world.vector_atlas_tex = null
	world.upwelling_tex = null
	_pending_currents_buf = PackedByteArray()
	_pending_upwelling_buf = PackedByteArray()
	_pending_upwelling_mask = PackedByteArray()
	_pending_upwelling_row_built = PackedByteArray()
	_pending_wind_buf = PackedByteArray()
	_pending_size = Vector2i.ZERO
	_pending_phys_solved_phase = NAN
	_pending_psi_state = null
	_phys_stage = _PHYS_STAGE_NONE
	_phys_psi_iters_done = 0
	_phys_wind_raster_idx = 0
	_phys_wind_done_by_cpp = false
	print("[physical_init] deferred native refresh complete: %dms" % (Time.get_ticks_msec() - t_deferred))
	return true

static func compute_world_bounds(width: int, height: int, hex_size: float) -> Rect2:
	if width <= 0 or height <= 0:
		return Rect2()
	var w := float(width)
	var h := float(height)
	var px := sqrt(3.0) * hex_size * (w + 0.5)
	var py := 1.5 * hex_size * h + 0.5 * hex_size
	return Rect2(
		Vector2(-hex_size * 2.0, -hex_size * 2.0),
		Vector2(px + hex_size * 4.0, py + hex_size * 4.0)
	)

func bake_world(map: MapData, cfg: MapConfig, hex_size: float, seed_val: int) -> WorldData:
	_rng = RandomNumberGenerator.new()
	_rng.seed = seed_val
	_init_noise(seed_val)

	# 重新烘焙世界 → 失效旧海冰独立纹理缓冲与 cell-byte 快照。
	_sea_ice_only_buf = PackedByteArray()
	_sea_ice_cache_size = Vector2i.ZERO
	_sea_ice_pixel_to_cell_idx = PackedInt32Array()
	_last_sea_ice_cell_bytes = {}
	_last_sea_ice_cell_bytes_packed = PackedByteArray()
	# 阶段 P：cover / vegetation 的增量缓存同样要随地图重生 / 重烘失效。
	_last_cover_cell_bytes = {}
	_last_vegetation_cell_bytes = {}
	_last_cover_cell_bytes_packed = PackedByteArray()
	_last_vegetation_cell_bytes_packed = PackedByteArray()
	_cover_cache_size = Vector2i.ZERO
	_vegetation_cache_size = Vector2i.ZERO
	# J: biome 增量缓存随地图重生失效（首次 rebake_biome_axes_only 走 fallback 重建路径）
	_last_biome_cell_bytes = {}
	_last_biome_cell_bytes_packed = PackedByteArray()
	_biome_cache_size = Vector2i.ZERO
	# 阶段 P2：enum_atlas 交错 data 缓存随地图重生失效（首次 _encode_enum_atlas 会重新填）
	_enum_atlas_data = PackedByteArray()
	_enum_atlas_data_size = Vector2i.ZERO
	# plan/sim-2ms-simd-dirty-budget：地图重生 → enum atlas 整张重烘必走 GPU upload；
	# 累积的 throttle 计数同步清零，避免老 axis 的 pending dirty 在新地图上误触发自愈。
	force_flush_enum_atlas_throttle()
	# weather_field 增量缓存：地图重生 → 缓冲与 sig 失效；首次 bake_weather_field_only 会重建。
	_weather_field_buf = PackedByteArray()
	_weather_field_cache_size = Vector2i.ZERO
	_last_weather_field_cell_sigs = {}
	# dynamic_cell_atlas 增量缓存同样随地图重生失效。
	_dynamic_cell_atlas_buf = PackedByteArray()
	_dynamic_cell_atlas_cache_size = Vector2i.ZERO
	_last_dynamic_cell_sigs = {}
	_ecology_visual_atlas_buf = PackedByteArray()
	_ecology_visual_atlas_cache_size = Vector2i.ZERO
	_last_ecology_visual_sigs = {}
	# map-visual-overhaul-v1：新 atlas 缓存随地图重生失效
	_dyn_atlas_smooth_buf = PackedByteArray()
	_dyn_atlas_smooth_cache_size = Vector2i.ZERO
	_last_dyn_smooth_cell_sigs = {}
	_ice_state_buf = PackedByteArray()
	_ice_state_cache_size = Vector2i.ZERO
	_last_ice_state_cell_bytes = {}
	_last_ecology_veg_bytes = {}
	_last_ecology_vitality_bytes = {}
	_ecology_transition_age_bytes = {}
	# P1-E：SoA 镜像同步清空，下一次 ecology cache prepare 时按 N 重 resize 填零
	_eco_veg_bytes_arr = PackedByteArray()
	_eco_vitality_bytes_arr = PackedByteArray()
	_eco_transition_age_arr = PackedByteArray()
	_eco_soa_initialized = false
	_eco_active_decay_set = {}  # plan/dirty-push-atlas-encode 阶段 E：地图重生时清空
	# L: vector atlas 持久交错缓冲随地图重生失效（首次 commit 走 fallback 路径重建）。
	_vector_atlas_data = PackedByteArray()
	_vector_atlas_data_size = Vector2i.ZERO

	var world := WorldData.new()
	world.world_bounds = compute_world_bounds(map.width, map.height, hex_size)
	world.hm_size = _resolve_hm_size(world.world_bounds)
	world.derived_size = world.hm_size  # 统一分辨率
	world.sea_level = cfg.sea_level
	world.bake_seed = seed_val

	var t_total := Time.get_ticks_msec()
	print("MapBaker v6: hm=%s seed=%d" % [world.hm_size, seed_val])
	# 安卓黑屏体感修复：bake_world 一次性 ~13s 期间 main.gd 的 splash overlay
	# 接 stage_progress 信号显示阶段进度。fraction 是按 logcat 实测耗时估的累积
	# 进度（不是精确百分比）。
	stage_progress.emit("terrain", 0.0)

	# 一次循环同时算 heightmap + biome + moisture + vegetation + cover（共享 warp 计算）
	# Milestone 2：vegetation_buf / cover_buf 与 biome_buf 完全同 warp、同 cube_round，
	# shader 端用同一 uv 采样三张 R8 即可对齐。
	var t := Time.get_ticks_msec()
	var pix_count := world.hm_size.x * world.hm_size.y
	var height_buf := PackedFloat32Array()
	var biome_buf := PackedByteArray()
	var moist_buf := PackedFloat32Array()
	var veg_buf := PackedByteArray()
	var cover_buf := PackedByteArray()
	height_buf.resize(pix_count)
	biome_buf.resize(pix_count)
	moist_buf.resize(pix_count)
	veg_buf.resize(pix_count)
	cover_buf.resize(pix_count)
	_bake_height_biome_moisture(map, hex_size, world, height_buf, biome_buf, moist_buf, veg_buf, cover_buf)
	world.height_buffer = height_buf
	world.biome_buffer = biome_buf
	world.moisture_buffer = moist_buf
	world.vegetation_buffer = veg_buf
	world.cover_buffer = cover_buf
	print("  height+biome+moisture+veg+cover: %dms" % (Time.get_ticks_msec() - t))

	# 轻度侵蚀，让 hex 边界进一步自然
	t = Time.get_ticks_msec()
	var hm_flow_dummy := PackedFloat32Array()
	hm_flow_dummy.resize(world.hm_size.x * world.hm_size.y)
	_hydraulic_erosion(world.height_buffer, hm_flow_dummy, world.hm_size)
	_clamp_buffer(world.height_buffer, 0.0, 1.0)
	print("  light erosion: %dms" % (Time.get_ticks_msec() - t))

	# 河流：从 cell.has_river 链 → Catmull-Rom → SDF
	t = Time.get_ticks_msec()
	world.flow_buffer = _bake_river_sdf(map, hex_size, world.world_bounds, world.derived_size)
	print("  river SDF: %dms" % (Time.get_ticks_msec() - t))

	# Phase 1：纬度纹理（每像素 ny），给 shader 算半球 + 季节温度偏移
	t = Time.get_ticks_msec()
	world.latitude_buffer = _bake_latitude_buffer(world.world_bounds, world.derived_size)
	print("  latitude: %dms" % (Time.get_ticks_msec() - t))

	# 风/洋流/上升流像素 buffer：先在 hex 域求解物理场，再把 per-cell 真值
	# 光栅化回 vector_atlas，供主地图海洋 tint / 水面风驱细节和 WeatherLayer advection 消费。

	stage_progress.emit("physical", 0.62)
	_bake_initial_physical_circulation(map, world, hex_size, cfg)
	_bake_initial_vector_buffers(map, world, hex_size, cfg)

	# Phase 14：火山强度场（R8），每像素 = 距最近 has_volcano cell 中心的径向衰减
	stage_progress.emit("volcano", 0.70)
	t = Time.get_ticks_msec()
	world.volcano_field_buffer = _bake_volcano_field(map, hex_size, world)
	print("  volcano field: %dms" % (Time.get_ticks_msec() - t))

	# Emergent Climate Coupling：sea_ice_fraction buffer 保持兼容数据通道。
	# 主地图海冰视觉已改为 shader 直接按水温派生，不依赖此贴图光栅化。
	# [sea-ice-atlas-skip 2026-06-16] flag 关（默认）→ 不再分配空 R8 buffer（无采样者，
	# 仅 dots_soak_dump 调试哈希读它，n==0 时自有兜底）。
	world.sea_ice_fraction_buffer = PackedByteArray()
	if DCFeatureFlags.sea_ice_atlas_active():
		world.sea_ice_fraction_buffer.resize(world.derived_size.x * world.derived_size.y)

	# 动态视觉状态统一由 map_index_atlas + LUT 提供，不再初始化逐像素 dynamic/smooth/eco/ice atlas。
	stage_progress.emit("atlas", 0.82)

	# 编码纹理：保留 height + map_index；动态视觉走 LUT。
	stage_progress.emit("encode", 0.88)
	t = Time.get_ticks_msec()
	world.height_tex = _encode_height_tex(world.height_buffer, world.hm_size)
	world.enum_atlas_tex = _encode_enum_atlas(
		world.biome_buffer, world.vegetation_buffer, world.cover_buffer,
		world.derived_size, null, world
	)
	prewarm_dynamic_axis_caches(map, world)
	world.scalar_atlas_tex = null
	# [river-render-restore 2026-06-19] 把河流 SDF（flow_buffer, float[0,1]）编码成 L8 纹理
	# 接回主地图 shader。scalar_atlas 退役后此通道断供，导致 has_river 河网完全不可见。
	world.flow_tex = _encode_flow_tex(world.flow_buffer, world.derived_size, world.flow_tex)
	world.sea_ice_tex = null
	world.volcano_field_tex = _encode_r8_tex(world.volcano_field_buffer, world.derived_size, world.volcano_field_tex)
	world.vector_atlas_tex = null
	# 方案 0：upwelling_tex 仅 F6 调试 shader 分支采样，主路径不读；这里不再无条件烘，
	# F6 切到 debug 模式时由 rebake_upwelling_tex_for_debug() lazy 建一张。
	# 保留 world.upwelling_tex 为 null：shader 在 ocean_current_debug=false 时不采样此 tex，
	# 不绑定不会渲染异常（hex_renderer 也已改为仅在 debug 开启时 set_shader_parameter）。
	world.upwelling_tex = null
	# v10.noise-pack：共享 RGBA 噪声包（首次调用时 lazy 烘焙，之后所有 world 复用同一张）
	world.noise_tex = get_or_build_shared_noise_tex()
	_ensure_cell_lut_dims(map, world)
	bake_cell_luts(map, world)
	print("  encode: %dms" % (Time.get_ticks_msec() - t))

	print("MapBaker v6: total %dms" % (Time.get_ticks_msec() - t_total))
	stage_progress.emit("done", 1.0)
	return world

# ─── Phase 2：增量重新烘焙 biome_tex ────────────────────────────────────────
# 季节切换时只需重画 biome（其他 buffer 不变），单次只跑 ~80ms。
# 注意：调用此方法前必须保证 `_warp_noise_lo/hi` 等已 init（一般通过先跑过 bake_world）。
# 若 baker 是新建的实例，请先调用 `_init_noise(seed_val)`。

func rebake_biome_tex_only(map: MapData, world: WorldData, hex_size: float) -> void:
	rebake_biome_axes_only(map, world, hex_size)

# Milestone 3：仅重烘 cover_tex（biome/vegetation 不动），给 day-tick 用。
# 跑同一遍 warp + cube_round，但只写 cover_buffer + 编码一张 R8 tex。
# 比 rebake_biome_axes_only 快 ~3 倍（~25-30ms vs 80ms）。
func rebake_cover_tex_only(map: MapData, world: WorldData, hex_size: float) -> void:
	_rebake_single_axis(map, world, hex_size, "cover")

# Milestone 4：仅重烘 vegetation_tex（biome/cover 不动），给植被演替触发用。
# 同样的 warp + cube_round + 单 R8 编码路径，开销与 cover-only 相同。
func rebake_vegetation_tex_only(map: MapData, world: WorldData, hex_size: float) -> void:
	_rebake_single_axis(map, world, hex_size, "vegetation")


func _enum_atlas_cpp_pack_disabled_reason() -> String:
	if _world_ext == null:
		return "cpp_gate_no_world_ext"
	if not _world_ext.has_method("patch_enum_atlas_axes"):
		return "cpp_gate_method_missing"
	# map_index_atlas 的 G/B 通道存 cell index；旧 C++ patch 仍按 RGB=biome/veg/cover 写入。
	return "cpp_gate_map_index_atlas_gb_reserved"


func _enum_atlas_cpp_pack_enabled() -> bool:
	return _enum_atlas_cpp_pack_disabled_reason() == ""


func _ensure_world_cell_pixel_csr(map: MapData, world: WorldData) -> bool:
	if world == null:
		return false
	if not world.cell_first_px_arr.is_empty() and not world.cell_px_count_arr.is_empty() \
			and not world.flat_px_indices_arr.is_empty():
		return true
	if world.cell_pixel_lists.is_empty():
		return false
	var n_cells: int = map.cell_count() if map != null else 0
	if n_cells <= 0:
		for cell_key in world.cell_pixel_lists.keys():
			var cell: HexCell = cell_key
			if cell != null:
				n_cells = maxi(n_cells, int(cell.index) + 1)
	if n_cells <= 0:
		return false
	var first_px_arr := PackedInt32Array()
	var px_count_arr := PackedInt32Array()
	first_px_arr.resize(n_cells)
	px_count_arr.resize(n_cells)
	for i in range(n_cells):
		first_px_arr[i] = -1
		px_count_arr[i] = 0
	var total_px: int = 0
	for cell_key in world.cell_pixel_lists.keys():
		var pixels: PackedInt32Array = world.cell_pixel_lists[cell_key]
		total_px += pixels.size()
	if total_px <= 0:
		return false
	var flat_arr := PackedInt32Array()
	flat_arr.resize(total_px)
	var flat_w: int = 0
	for cell_key in world.cell_pixel_lists.keys():
		var cell: HexCell = cell_key
		if cell == null:
			continue
		var idx: int = int(cell.index)
		if idx < 0 or idx >= n_cells:
			continue
		var pixels: PackedInt32Array = world.cell_pixel_lists[cell_key]
		var count: int = pixels.size()
		if count <= 0:
			continue
		first_px_arr[idx] = flat_w
		px_count_arr[idx] = count
		for p in range(count):
			flat_arr[flat_w + p] = pixels[p]
		flat_w += count
	if flat_w <= 0:
		return false
	if flat_w != total_px:
		flat_arr.resize(flat_w)
	world.cell_first_px_arr = first_px_arr
	world.cell_px_count_arr = px_count_arr
	world.flat_px_indices_arr = flat_arr
	return true


func _try_cpp_enum_axis_patch(map: MapData, world: WorldData, axis: String, report_t0_us: int) -> bool:
	_enum_atlas_cpp_skip_reason = ""
	if world == null:
		_enum_atlas_cpp_skip_reason = "cpp_gate_world_null"
		return false
	var gate_reason: String = _enum_atlas_cpp_pack_disabled_reason()
	if gate_reason != "":
		_enum_atlas_cpp_skip_reason = gate_reason
		return false
	var W: int = world.derived_size.x
	var H: int = world.derived_size.y
	var pix_count: int = W * H
	if pix_count <= 0:
		_enum_atlas_cpp_skip_reason = "cpp_gate_bad_size"
		return false
	if _enum_atlas_data_size != Vector2i(W, H) or _enum_atlas_data.size() != pix_count * 4:
		_enum_atlas_cpp_skip_reason = "cpp_gate_enum_data_invalid"
		return false
	if not _ensure_world_cell_pixel_csr(map, world):
		_enum_atlas_cpp_skip_reason = "cpp_gate_csr_empty"
		return false
	var run_cover: bool = axis == "cover"
	var run_vegetation: bool = axis == "vegetation"
	if not run_cover and not run_vegetation:
		_enum_atlas_cpp_skip_reason = "cpp_gate_axis_unsupported"
		return false
	var patch_t0_us: int = Time.get_ticks_usec()
	var knobs: Dictionary = {
		"n_cells": world.cell_first_px_arr.size(),
		"n_pix": pix_count,
		"cell_first_px": world.cell_first_px_arr,
		"cell_px_count": world.cell_px_count_arr,
		"flat_px_indices": world.flat_px_indices_arr,
		"enum_atlas_data": _enum_atlas_data,
		"run_cover": run_cover,
		"run_vegetation": run_vegetation,
		"cover_buffer": world.cover_buffer,
		"vegetation_buffer": world.vegetation_buffer,
		"prev_cover": _last_cover_cell_bytes_packed,
		"prev_vegetation": _last_vegetation_cell_bytes_packed,
	}
	var out: Dictionary = _world_ext.patch_enum_atlas_axes(knobs)
	if bool(out.get("fallback", true)):
		_enum_atlas_cpp_skip_reason = "cpp_native_fallback_" + str(out.get("reason", "unknown"))
		return false
	var buffer_patch_ms: float = float(Time.get_ticks_usec() - patch_t0_us) / 1000.0
	_enum_atlas_data = out.get("enum_atlas_data", _enum_atlas_data)
	var dirty_cells: int = 0
	var dirty_pixels: int = int(out.get("dirty_pixels", 0))
	if run_cover:
		world.cover_buffer = out.get("cover_buffer", world.cover_buffer)
		_last_cover_cell_bytes_packed = out.get("prev_cover", _last_cover_cell_bytes_packed)
		dirty_cells = int(out.get("cover_dirty", 0))
		_cover_cache_size = Vector2i(W, H)
	else:
		world.vegetation_buffer = out.get("vegetation_buffer", world.vegetation_buffer)
		_last_vegetation_cell_bytes_packed = out.get("prev_vegetation", _last_vegetation_cell_bytes_packed)
		dirty_cells = int(out.get("vegetation_dirty", 0))
		_vegetation_cache_size = Vector2i(W, H)
	if dirty_cells <= 0:
		_record_enum_atlas_upload_report(axis, "cpp_skipped_no_dirty",
			float(Time.get_ticks_usec() - report_t0_us) / 1000.0,
			0, 0, buffer_patch_ms, 0.0, 0.0, true)
		return true
	# plan/sim-2ms-simd-dirty-budget：节流判定。flag=false 时直通走原路径；
	# flag=true 时按累积阈值（≥16 dirty cells / ≥4 skip / ≥64 tick 自愈）决策。
	# 跳过路径：cpu 端 _enum_atlas_data 已经被 cpp 写入最新值，仅 GPU upload 推迟。
	if not _enum_atlas_throttle_should_flush(axis, dirty_cells):
		_record_enum_atlas_upload_report(axis, "cpp_throttle_skipped",
			float(Time.get_ticks_usec() - report_t0_us) / 1000.0,
			dirty_cells, dirty_pixels, buffer_patch_ms, 0.0, 0.0, true)
		return true
	var image_t0_us: int = Time.get_ticks_usec()
	var img := Image.create_from_data(W, H, false, Image.FORMAT_RGBA8, _enum_atlas_data)
	var image_ms: float = float(Time.get_ticks_usec() - image_t0_us) / 1000.0
	var upload_t0_us: int = Time.get_ticks_usec()
	if world.enum_atlas_tex != null and world.enum_atlas_tex.get_size() == Vector2(float(W), float(H)):
		world.enum_atlas_tex.update(img)
	else:
		world.enum_atlas_tex = ImageTexture.create_from_image(img)
	var upload_ms: float = float(Time.get_ticks_usec() - upload_t0_us) / 1000.0
	_record_enum_atlas_upload_report(axis, "cpp_cached_patch",
		float(Time.get_ticks_usec() - report_t0_us) / 1000.0,
		dirty_cells, dirty_pixels, buffer_patch_ms, image_ms, upload_ms, true)
	return true


func _try_cpp_enum_axes_patch(map: MapData, world: WorldData, report_t0_us: int) -> bool:
	_enum_atlas_cpp_skip_reason = ""
	if world == null:
		_enum_atlas_cpp_skip_reason = "cpp_gate_world_null"
		return false
	var gate_reason: String = _enum_atlas_cpp_pack_disabled_reason()
	if gate_reason != "":
		_enum_atlas_cpp_skip_reason = gate_reason
		return false
	var W: int = world.derived_size.x
	var H: int = world.derived_size.y
	var pix_count: int = W * H
	if pix_count <= 0:
		_enum_atlas_cpp_skip_reason = "cpp_gate_bad_size"
		return false
	if _enum_atlas_data_size != Vector2i(W, H) or _enum_atlas_data.size() != pix_count * 4:
		_enum_atlas_cpp_skip_reason = "cpp_gate_enum_data_invalid"
		return false
	if not _ensure_world_cell_pixel_csr(map, world):
		_enum_atlas_cpp_skip_reason = "cpp_gate_csr_empty"
		return false
	var patch_t0_us: int = Time.get_ticks_usec()
	var out: Dictionary = _world_ext.patch_enum_atlas_axes({
		"n_cells": world.cell_first_px_arr.size(),
		"n_pix": pix_count,
		"cell_first_px": world.cell_first_px_arr,
		"cell_px_count": world.cell_px_count_arr,
		"flat_px_indices": world.flat_px_indices_arr,
		"enum_atlas_data": _enum_atlas_data,
		"run_biome": true,
		"run_vegetation": true,
		"run_cover": true,
		"biome_buffer": world.biome_buffer,
		"vegetation_buffer": world.vegetation_buffer,
		"cover_buffer": world.cover_buffer,
		"prev_biome": _last_biome_cell_bytes_packed,
		"prev_vegetation": _last_vegetation_cell_bytes_packed,
		"prev_cover": _last_cover_cell_bytes_packed,
	})
	if bool(out.get("fallback", true)):
		_enum_atlas_cpp_skip_reason = "cpp_native_fallback_" + str(out.get("reason", "unknown"))
		return false
	var buffer_patch_ms: float = float(Time.get_ticks_usec() - patch_t0_us) / 1000.0
	world.biome_buffer = out.get("biome_buffer", world.biome_buffer)
	world.vegetation_buffer = out.get("vegetation_buffer", world.vegetation_buffer)
	world.cover_buffer = out.get("cover_buffer", world.cover_buffer)
	_enum_atlas_data = out.get("enum_atlas_data", _enum_atlas_data)
	_last_biome_cell_bytes_packed = out.get("prev_biome", _last_biome_cell_bytes_packed)
	_last_vegetation_cell_bytes_packed = out.get("prev_vegetation", _last_vegetation_cell_bytes_packed)
	_last_cover_cell_bytes_packed = out.get("prev_cover", _last_cover_cell_bytes_packed)
	_biome_cache_size = Vector2i(W, H)
	_vegetation_cache_size = Vector2i(W, H)
	_cover_cache_size = Vector2i(W, H)
	var dirty_cells: int = int(out.get("dirty_cells", 0))
	var dirty_pixels: int = int(out.get("dirty_pixels", 0))
	if dirty_cells <= 0:
		_record_enum_atlas_upload_report("biome", "cpp_skipped_no_dirty",
			float(Time.get_ticks_usec() - report_t0_us) / 1000.0,
			0, 0, buffer_patch_ms, 0.0, 0.0, true)
		return true
	# plan/sim-2ms-simd-dirty-budget：节流判定（合并 axes 路径用 "biome" 当 key
	# —— 一次合并 patch 等同 biome+veg+cover 三 axis 的整体翻转，所以共用一个
	# 阈值序列即可）。详见 _try_cpp_enum_axis_patch 同名注释。
	if not _enum_atlas_throttle_should_flush("biome", dirty_cells):
		_record_enum_atlas_upload_report("biome", "cpp_throttle_skipped",
			float(Time.get_ticks_usec() - report_t0_us) / 1000.0,
			dirty_cells, dirty_pixels, buffer_patch_ms, 0.0, 0.0, true)
		return true
	var image_t0_us: int = Time.get_ticks_usec()
	var img := Image.create_from_data(W, H, false, Image.FORMAT_RGBA8, _enum_atlas_data)
	var image_ms: float = float(Time.get_ticks_usec() - image_t0_us) / 1000.0
	var upload_t0_us: int = Time.get_ticks_usec()
	if world.enum_atlas_tex != null and world.enum_atlas_tex.get_size() == Vector2(float(W), float(H)):
		world.enum_atlas_tex.update(img)
	else:
		world.enum_atlas_tex = ImageTexture.create_from_image(img)
	var upload_ms: float = float(Time.get_ticks_usec() - upload_t0_us) / 1000.0
	_record_enum_atlas_upload_report("biome", "cpp_cached_patch",
		float(Time.get_ticks_usec() - report_t0_us) / 1000.0,
		dirty_cells, dirty_pixels, buffer_patch_ms, image_ms, upload_ms, true)
	return true

# 主地图动态状态 atlas：RGBA8，R=temp, G=moisture/wetness, B=snow_cover, A=vegetation_vitality。
# 使用 world.cell_pixel_lists 按 cell dirty 写入，避免每次重新 cube_round / 逐像素取字段。
# [cell-indirect single-path 2026-06-16] flag 开时这组逐像素动态 atlas
# (dynamic_cell_atlas / ecology_visual_atlas / dyn_atlas_smooth / ice_state_atlas)
# 主 shader 已改读 per-cell LUT（dyn_lut/eco_lut，海冰走 dyn_lut.a），不再被采样，
# 故所有 rebake 入口统一返回此 no-op 报告。字段与正常 rebake 报告同构，调用方
# （bake_world / DVA oneshot / SeaIceAtlasUploadSystem|Job）的 dirty/ms 累加安全。
func _indirection_skip_atlas_report() -> Dictionary:
	return {
		"prepared": false,
		"dirty": false,
		"dirty_cells": 0,
		"pixels_written": 0,
		"elapsed_ms": 0.0,
		"skipped_indirection": true,
	}


func rebake_dynamic_cell_atlas_only(map: MapData, world: WorldData) -> Dictionary:
	# [cell-indirect single-path] flag 开 → 间接寻址 dyn_lut 接管，跳过逐像素重烤。
	if DCFeatureFlags.cell_indirection_active():
		return _indirection_skip_atlas_report()
	# Thin wrapper：保持旧签名 100% 兼容（synthesize_world 初始烘走这条）。
	# 走完整 chunk_begin → chunk_step(all_cells) → chunk_finalize 三段。
	var report := {
		"prepared": false,
		"dirty": false,
		"dirty_cells": 0,
		"pixels_written": 0,
		"elapsed_ms": 0.0,
	}
	if map == null or world == null:
		return report
	var t_us: int = Time.get_ticks_usec()
	var ctx: Dictionary = dynamic_cell_atlas_chunk_begin(map, world)
	if not bool(ctx.get("prepared", false)):
		return report
	dynamic_cell_atlas_chunk_step(map, world, ctx, map.all_cells(), report)
	dynamic_cell_atlas_chunk_finalize(world, ctx, report)
	report.elapsed_ms = float(Time.get_ticks_usec() - t_us) / 1000.0
	return report


# ─── dynamic_cell_atlas chunk API ─────────────────────────────────────────────
# [deprecated 2026-05-20 atlas-pipeline-cpp]
# 当 climate_profile.cpp_atlas_pipeline_enabled = true 时，本函数 + chunk_step
# + chunk_finalize 组合不会被调用：dynamic_visual_atlas_upload_system 直接调
# DCWorldExt.run_atlas_pipeline_step 拿 atlas_buffers 后做 ImageTexture.update。
# 此函数仅在 flag=false（fallback / 调试 / bit-equal 测试）时保留可用。
func dynamic_cell_atlas_chunk_begin(map: MapData, world: WorldData) -> Dictionary:
	var ctx: Dictionary = {"prepared": false}
	if map == null or world == null:
		return ctx
	var W: int = world.derived_size.x
	var H: int = world.derived_size.y
	var n: int = W * H
	if n <= 0:
		return ctx
	var cache_valid: bool = (_dynamic_cell_atlas_cache_size == Vector2i(W, H) \
			and _dynamic_cell_atlas_buf.size() == n * 4)
	if not cache_valid:
		_dynamic_cell_atlas_buf = PackedByteArray()
		_dynamic_cell_atlas_buf.resize(n * 4)
		# 全 0 起步：shader 端 dyn_valid = step(0.02, dyn_temp) 在未写入时退回 derived 路径，
		# 避免把 G/A 通道的"中性默认"误判为真实数据。
		_dynamic_cell_atlas_buf.fill(0)
		_dynamic_cell_atlas_cache_size = Vector2i(W, H)
		_last_dynamic_cell_sigs = {}
	ctx["prepared"] = true
	ctx["W"] = W
	ctx["H"] = H
	ctx["n"] = n
	ctx["cache_valid"] = cache_valid
	ctx["use_pixel_lists"] = world.cell_pixel_lists != null and not world.cell_pixel_lists.is_empty()
	return ctx


func dynamic_cell_atlas_chunk_step(map: MapData, world: WorldData, ctx: Dictionary, cells,
		report: Dictionary, start_idx: int = 0, end_idx: int = -1) -> void:
	if not bool(ctx.get("prepared", false)):
		return
	var span: Vector2i = _cell_range(cells, start_idx, end_idx)
	if span.x >= span.y:
		_report_inc(report, "empty_calls")
		return
	var cpp_reason: String = _cpp_atlas_encode_disabled_reason(&"encode_dynamic_cell_atlas")
	if cpp_reason == "":
		if _try_cpp_dynamic_cell_atlas_encode(map, world, ctx, cells, report, span.x, span.y):
			return
		cpp_reason = str(report.get("fallback_reason", "cpp_fallback"))
	report["path"] = "gdscript"
	if cpp_reason != "":
		report["fallback_reason"] = cpp_reason
	_report_inc(report, "gd_calls")
	var n: int = int(ctx.n)
	var cache_valid: bool = bool(ctx.cache_valid)
	var use_pixel_lists: bool = bool(ctx.use_pixel_lists)
	for i in range(span.x, span.y):
		var cell: HexCell = cells[i]
		if cell == null:
			continue
		var sig: int = _dynamic_cell_signature(cell)
		if cache_valid and int(_last_dynamic_cell_sigs.get(cell, -1)) == sig:
			continue
		_last_dynamic_cell_sigs[cell] = sig
		var r: int = sig & 0xFF
		var g: int = (sig >> 8) & 0xFF
		var b: int = (sig >> 16) & 0xFF
		var a: int = (sig >> 24) & 0xFF
		var pixels: PackedInt32Array = PackedInt32Array()
		if use_pixel_lists:
			pixels = world.cell_pixel_lists.get(cell, PackedInt32Array())
		for px_idx in pixels:
			if px_idx < 0 or px_idx >= n:
				continue
			var base_px: int = px_idx * 4
			_dynamic_cell_atlas_buf[base_px] = r
			_dynamic_cell_atlas_buf[base_px + 1] = g
			_dynamic_cell_atlas_buf[base_px + 2] = b
			_dynamic_cell_atlas_buf[base_px + 3] = a
		report.dirty_cells = int(report.dirty_cells) + 1
		report.pixels_written = int(report.pixels_written) + pixels.size()


func dynamic_cell_atlas_chunk_finalize(world: WorldData, ctx: Dictionary, report: Dictionary) -> void:
	if not bool(ctx.get("prepared", false)):
		return
	var W: int = int(ctx.W)
	var H: int = int(ctx.H)
	report.prepared = true
	report.dirty = int(report.dirty_cells) > 0 or world.dynamic_cell_atlas_tex == null
	world.dynamic_cell_atlas_buffer = _dynamic_cell_atlas_buf
	if bool(report.dirty):
		var img := Image.create_from_data(W, H, false, Image.FORMAT_RGBA8, _dynamic_cell_atlas_buf)
		if world.dynamic_cell_atlas_tex != null and world.dynamic_cell_atlas_tex.get_size() == Vector2(float(W), float(H)):
			world.dynamic_cell_atlas_tex.update(img)
		else:
			world.dynamic_cell_atlas_tex = ImageTexture.create_from_image(img)

func _dynamic_cell_signature(cell: HexCell) -> int:
	# A 通道双语义（sea-ice-render-source-unify 阶段 C）：
	#   - 水格（is_water=true，等价于 not passable_land）：A = q01_byte_ice(sea_ice_fraction)
	#       让 shader 水路径直接从 dyn_atlas_smooth.A 读取海冰覆盖率；同源于
	#       UI/info_panel.sea_ice_fraction，根除"UI 100% 但画面无冰"类病灶。
	#   - 陆格：A = q01_byte(vegetation_vitality)（保持原语义，陆地植被通道）
	# 关键：用 is_water 而非 passable_sea——SEA_ICE 因冰面阻断航行 passable_sea=false，
	# 但视觉上仍是水域；用 passable_sea 会把 SEA_ICE 误归入陆格写 vit，shader 水路径
	# 拿到错误数据完全看不到冰。
	# SAME_SOURCE：gdext/src/world_ext.cpp::encode_dynamic_cell_atlas / encode_dyn_smooth_atlas /
	#              monolithic atlas pipeline pk_atlas_sig_dynamic（统一用 is_water 语义）。
	var r: int = _q01_byte(float(cell.temperature))
	var g: int = _q01_byte(float(cell.moisture))
	var b: int = _q01_byte(float(cell.snow_cover))
	var a: int
	if MapData.terrain_is_water(int(cell.terrain)):
		a = _q01_byte_ice(float(cell.sea_ice_fraction))
	else:
		a = _q01_byte(float(cell.vegetation_vitality))
	return r | (g << 8) | (b << 16) | (a << 24)

# 生态视觉 atlas：RGBA8，derived_size。
# R=叶量/冠层密度，G=胁迫/干旱，B=植被 enum 变化后的过渡年龄，A=近期生长/受损。
func rebake_ecology_visual_atlas_only(map: MapData, world: WorldData) -> Dictionary:
	# [cell-indirect single-path] flag 开 → 间接寻址 eco_lut 接管，跳过逐像素重烤。
	if DCFeatureFlags.cell_indirection_active():
		return _indirection_skip_atlas_report()
	# Thin wrapper：保持旧签名 100% 兼容。chunk_step 走 all_cells，一次性完成。
	var report := {
		"prepared": false,
		"dirty": false,
		"dirty_cells": 0,
		"pixels_written": 0,
		"elapsed_ms": 0.0,
	}
	if map == null or world == null:
		return report
	var t_us: int = Time.get_ticks_usec()
	var ctx: Dictionary = ecology_visual_atlas_chunk_begin(map, world)
	if not bool(ctx.get("prepared", false)):
		return report
	ecology_visual_atlas_chunk_step(map, world, ctx, map.all_cells(), report)
	ecology_visual_atlas_chunk_finalize(world, ctx, report)
	report.elapsed_ms = float(Time.get_ticks_usec() - t_us) / 1000.0
	return report


# ─── ecology_visual_atlas chunk API ───────────────────────────────────────────
# [deprecated 2026-05-20 atlas-pipeline-cpp]
# 当 cpp_atlas_pipeline_enabled = true 时不会被调用（DOTS C++ pipeline 取代）。
# fallback 路径仍可用；首次 cpp 路径启用前需调 migrate_eco_persistent_from_gd
# 把 _eco_active_decay_set / _eco_transition_age_arr 灌到 C++。
func ecology_visual_atlas_chunk_begin(map: MapData, world: WorldData) -> Dictionary:
	var ctx: Dictionary = {"prepared": false}
	if map == null or world == null:
		return ctx
	var W: int = world.derived_size.x
	var H: int = world.derived_size.y
	var n: int = W * H
	if n <= 0:
		return ctx
	var cache_valid: bool = (_ecology_visual_atlas_cache_size == Vector2i(W, H) \
			and _ecology_visual_atlas_buf.size() == n * 4)
	if not cache_valid:
		_ecology_visual_atlas_buf = PackedByteArray()
		_ecology_visual_atlas_buf.resize(n * 4)
		_ecology_visual_atlas_buf.fill(0)
		_ecology_visual_atlas_cache_size = Vector2i(W, H)
		_last_ecology_visual_sigs = {}
		_last_ecology_veg_bytes = {}
		_last_ecology_vitality_bytes = {}
		_ecology_transition_age_bytes = {}
		# P1-E：SoA 镜像同步 invalid。按 cell.index 寻址，所以 size = map.cell_count()。
		# 首帧 baseline 设为 cur（cell.vegetation / vitality），等价于旧的
		# Dict.get(cell, cur) 首次 fallback 语义；transition_age 清 0。
		# 该 O(N_cells) 灌注一次性成本远低于后续每 stride K*Dict.get 的累计开销。
		var cell_count: int = map.cell_count()
		if cell_count <= 0:
			cell_count = map.all_cells().size()
		_eco_veg_bytes_arr = PackedByteArray()
		_eco_veg_bytes_arr.resize(cell_count)
		_eco_vitality_bytes_arr = PackedByteArray()
		_eco_vitality_bytes_arr.resize(cell_count)
		_eco_transition_age_arr = PackedByteArray()
		_eco_transition_age_arr.resize(cell_count)
		_eco_transition_age_arr.fill(0)
		var _all_cells_baseline: Array = map.all_cells()
		for _bc in _all_cells_baseline:
			if _bc == null or _bc.index < 0 or _bc.index >= cell_count:
				continue
			_eco_veg_bytes_arr[_bc.index] = int(_bc.vegetation) & 0xFF
			_eco_vitality_bytes_arr[_bc.index] = _q01_byte(float(_bc.vegetation_vitality))
		_eco_soa_initialized = true
		_eco_active_decay_set = {}  # plan/dirty-push-atlas-encode 阶段 E：cache 失效时一并清空
	ctx["prepared"] = true
	ctx["W"] = W
	ctx["H"] = H
	ctx["n"] = n
	ctx["cache_valid"] = cache_valid
	ctx["use_pixel_lists"] = world.cell_pixel_lists != null and not world.cell_pixel_lists.is_empty()
	return ctx


func ecology_visual_atlas_chunk_step(map: MapData, world: WorldData, ctx: Dictionary, cells,
		report: Dictionary, start_idx: int = 0, end_idx: int = -1) -> void:
	if not bool(ctx.get("prepared", false)):
		return
	var span: Vector2i = _cell_range(cells, start_idx, end_idx)
	if span.x >= span.y:
		_report_inc(report, "empty_calls")
		return
	var cpp_reason: String = _cpp_atlas_encode_disabled_reason(&"encode_ecology_visual_atlas")
	if cpp_reason == "":
		if _try_cpp_ecology_visual_atlas_encode(map, world, ctx, cells, report, span.x, span.y):
			return
		cpp_reason = str(report.get("fallback_reason", "cpp_fallback"))
	report["path"] = "gdscript"
	if cpp_reason != "":
		report["fallback_reason"] = cpp_reason
	_report_inc(report, "gd_calls")
	var n: int = int(ctx.n)
	var cache_valid: bool = bool(ctx.cache_valid)
	var use_pixel_lists: bool = bool(ctx.use_pixel_lists)
	for i in range(span.x, span.y):
		var cell: HexCell = cells[i]
		if cell == null:
			continue
		var cur_veg: int = int(cell.vegetation) & 0xFF
		var cur_vitality_byte: int = _q01_byte(float(cell.vegetation_vitality))
		# P1-E：SoA cell.index 直查替代 Dict.get；index 越界时退回 cur（baseline 等价）
		var ci_idx_gd: int = cell.index
		var soa_n_gd: int = _eco_veg_bytes_arr.size()
		var prev_veg: int
		var prev_vitality_byte: int
		var transition_age: int
		if ci_idx_gd >= 0 and ci_idx_gd < soa_n_gd:
			prev_veg = _eco_veg_bytes_arr[ci_idx_gd]
			prev_vitality_byte = _eco_vitality_bytes_arr[ci_idx_gd]
			transition_age = _eco_transition_age_arr[ci_idx_gd]
		else:
			prev_veg = cur_veg
			prev_vitality_byte = cur_vitality_byte
			transition_age = 0
		if cache_valid:
			if cur_veg != prev_veg:
				transition_age = 255
			elif transition_age > 0:
				transition_age = maxi(0, transition_age - 18)
		else:
			transition_age = 0

		var sig: int = _ecology_visual_signature(cell, transition_age, prev_vitality_byte)
		# P1-E：辅助状态必须每 cell 都写（无论是否 dirty），否则 transition_age 衰减会丢。
		# 走 SoA cell.index 直查；旧 Dict 不再维护。
		if ci_idx_gd >= 0 and ci_idx_gd < soa_n_gd:
			_eco_veg_bytes_arr[ci_idx_gd] = cur_veg
			_eco_vitality_bytes_arr[ci_idx_gd] = cur_vitality_byte
			_eco_transition_age_arr[ci_idx_gd] = transition_age & 0xFF
		# plan/dirty-push-atlas-encode 阶段 E：维护 active decay set。
		# 该 set 让调度器在下 stride 即使没收到 sim dirty，也能把"transition_age
		# 还在衰减"的 cell 重新喂进 chunk_step，避免衰减卡在 stale byte。
		# 注意：cache_invalid 路径下 transition_age 被强制清 0（上方 else 分支），
		# 这里 erase 是正确的。
		if transition_age > 0:
			_eco_active_decay_set[cell] = true
		else:
			_eco_active_decay_set.erase(cell)
		if cache_valid and int(_last_ecology_visual_sigs.get(cell, -1)) == sig:
			continue
		_last_ecology_visual_sigs[cell] = sig
		var r: int = sig & 0xFF
		var g: int = (sig >> 8) & 0xFF
		var b: int = (sig >> 16) & 0xFF
		var a: int = (sig >> 24) & 0xFF
		var pixels: PackedInt32Array = PackedInt32Array()
		if use_pixel_lists:
			pixels = world.cell_pixel_lists.get(cell, PackedInt32Array())
		for px_idx in pixels:
			if px_idx < 0 or px_idx >= n:
				continue
			var base_px: int = px_idx * 4
			_ecology_visual_atlas_buf[base_px] = r
			_ecology_visual_atlas_buf[base_px + 1] = g
			_ecology_visual_atlas_buf[base_px + 2] = b
			_ecology_visual_atlas_buf[base_px + 3] = a
		report.dirty_cells = int(report.dirty_cells) + 1
		report.pixels_written = int(report.pixels_written) + pixels.size()


func ecology_visual_atlas_chunk_finalize(world: WorldData, ctx: Dictionary, report: Dictionary) -> void:
	if not bool(ctx.get("prepared", false)):
		return
	var W: int = int(ctx.W)
	var H: int = int(ctx.H)
	report.prepared = true
	report.dirty = int(report.dirty_cells) > 0 or world.ecology_visual_atlas_tex == null
	world.ecology_visual_atlas_buffer = _ecology_visual_atlas_buf
	if bool(report.dirty):
		var img := Image.create_from_data(W, H, false, Image.FORMAT_RGBA8, _ecology_visual_atlas_buf)
		if world.ecology_visual_atlas_tex != null and world.ecology_visual_atlas_tex.get_size() == Vector2(float(W), float(H)):
			world.ecology_visual_atlas_tex.update(img)
		else:
			world.ecology_visual_atlas_tex = ImageTexture.create_from_image(img)

func _ecology_visual_signature(cell: HexCell, transition_age: int, prev_vitality_byte: int) -> int:
	var terrain_id: int = int(cell.terrain)
	var is_water_cell: bool = MapData.terrain_is_water(terrain_id)
	var veg_id: int = int(cell.vegetation)
	var vitality: float = clampf(float(cell.vegetation_vitality), 0.0, 1.0)
	var moist: float = clampf(float(cell.moisture), 0.0, 1.0)
	var temp: float = clampf(float(cell.temperature), 0.0, 1.0)
	var snow: float = clampf(float(cell.snow_cover), 0.0, 1.0)

	var foliage: float = 0.0
	if not is_water_cell and veg_id != int(VegetationType.VEG.NONE):
		var cold_loss: float = (1.0 - smoothstep(0.02, 0.18, temp)) * 0.55
		var snow_loss: float = smoothstep(0.12, 0.75, snow) * 0.70
		var dry_loss: float = (1.0 - smoothstep(0.05, 0.35, moist)) * 0.45
		foliage = clampf(vitality * 0.72 + moist * 0.28 - cold_loss - snow_loss - dry_loss, 0.0, 1.0)

	var stress: float = 0.0
	if not is_water_cell:
		var dryness: float = 1.0 - moist
		var heat_stress: float = smoothstep(0.72, 0.95, temp)
		var cold_stress: float = 1.0 - smoothstep(0.03, 0.20, temp)
		var vitality_stress: float = 1.0 - vitality
		stress = clampf(max(dryness * 0.70, max(heat_stress, cold_stress) * 0.65) \
				+ vitality_stress * 0.45, 0.0, 1.0)

	var vitality_delta: float = (float(_q01_byte(vitality)) - float(prev_vitality_byte)) / 255.0
	var growth_damage: float = clampf(0.5 + vitality_delta * 5.0 + (foliage - 0.5) * 0.12 \
			- stress * 0.10, 0.0, 1.0)
	var r: int = _q01_byte(foliage)
	var g: int = _q01_byte(stress)
	var b: int = clampi(transition_age, 0, 255)
	var a: int = _q01_byte(growth_damage)
	return r | (g << 8) | (b << 16) | (a << 24)

static func _q01_byte(v: float) -> int:
	return clampi(int(round(clampf(v, 0.0, 1.0) * 255.0)), 0, 255)

# 2026-05-19 Plan-C：海冰专用量化（不影响 temp/moist/snow/vitality 等其他通道）。
# 当 fraction > 0 时使用 ceil 并保证至少 byte=1，避免低浓度冰在量化时丢失；
# shader 端再用更高、更宽的 smoothstep 决定可见强度。fraction == 0 仍写 0。
# 仅由 ice_state_atlas_chunk_step 在海冰写入路径调用。
static func _q01_byte_ice(v: float) -> int:
	if v <= 0.0:
		return 0
	return clampi(maxi(1, int(ceil(clampf(v, 0.0, 1.0) * 255.0))), 1, 255)

# ─── map-visual-overhaul-v1：3 张新 atlas baker 实现 ─────────────────────────
#
# 设计原则与 rebake_dynamic_cell_atlas_only / rebake_ecology_visual_atlas_only
# 一致：cell-level dirty 缓存 + cell_pixel_lists 像素列表批量写入。新增的"smooth"
# atlas 在 cell 域做一次 hex 邻接 box blur，shader 端单点采样即可得到跨 cell 平滑
# 的连续场（消除"颜色按 hex 块切"的硬阶梯，同时主地图 fragment 采样数严格 ≤ 8）。
#
# 调用约定：
# - rebake_dyn_atlas_smooth 必须在 rebake_dynamic_cell_atlas_only 之后调用
#   （因为它读取 _dynamic_cell_atlas_buf 中已经写入的 byte 作为 blur 输入）。
# - rebake_ice_state_atlas 与气候/天气日 tick 解耦，每日 climate_system 末尾跑一次即可。

# dyn_atlas_smooth：dynamic_cell_atlas 的"沿 hex 邻接 box blur"产物。
# 单 cell 处理成本 = 中心 0.5 + 6 邻居均值 0.5；O(N_cells × 7) 加和。
# 与 rebake_dynamic_cell_atlas_only 同分辨率（derived_size, RGBA8）。
#
# Neighbor-aware sig（方案 C v1）：
# 旧版 sig 用"输出 byte 拼接"做 cache key —— int 除法 + clampi 量化可能淹没真实
# 邻居变动，造成视觉滞后。改造为"自己 4-byte + 6 邻居 4-byte，FNV-1a 哈希"作 cache
# sig，保证邻居 sig 任一 bit 变化都能立刻触发本 cell 重算。
func rebake_dyn_atlas_smooth(map: MapData, world: WorldData) -> Dictionary:
	# [cell-indirect single-path] flag 开 → 间接寻址 dyn_lut 跨 cell 平滑接管，跳过 box-blur 重烤。
	if DCFeatureFlags.cell_indirection_active():
		return _indirection_skip_atlas_report()
	# Thin wrapper：保持旧签名 100% 兼容。
	var report := {
		"prepared": false,
		"dirty": false,
		"dirty_cells": 0,
		"pixels_written": 0,
		"elapsed_ms": 0.0,
	}
	if map == null or world == null:
		return report
	var t_us: int = Time.get_ticks_usec()
	var ctx: Dictionary = dyn_atlas_smooth_chunk_begin(map, world)
	if not bool(ctx.get("prepared", false)):
		return report
	dyn_atlas_smooth_chunk_step(map, world, ctx, map.all_cells(), report)
	dyn_atlas_smooth_chunk_finalize(world, ctx, report)
	report.elapsed_ms = float(Time.get_ticks_usec() - t_us) / 1000.0
	return report


# ─── dyn_atlas_smooth chunk API ───────────────────────────────────────────────
# [deprecated 2026-05-20 atlas-pipeline-cpp]
# 当 cpp_atlas_pipeline_enabled = true 时不会被调用（DOTS C++ pipeline 取代）。
# fallback 路径保留 1 跳邻居膨胀逻辑（baker_dirty_helpers.dilate_dirty_one_hop）。
func dyn_atlas_smooth_chunk_begin(map: MapData, world: WorldData) -> Dictionary:
	var ctx: Dictionary = {"prepared": false}
	if map == null or world == null:
		return ctx
	var W: int = world.derived_size.x
	var H: int = world.derived_size.y
	var n: int = W * H
	if n <= 0:
		return ctx
	var cache_valid: bool = (_dyn_atlas_smooth_cache_size == Vector2i(W, H) \
			and _dyn_atlas_smooth_buf.size() == n * 4)
	if not cache_valid:
		_dyn_atlas_smooth_buf = PackedByteArray()
		_dyn_atlas_smooth_buf.resize(n * 4)
		# 同 dynamic_cell_atlas：全 0 起步，shader 端 dyn_valid step 退回 derived 路径。
		_dyn_atlas_smooth_buf.fill(0)
		_dyn_atlas_smooth_cache_size = Vector2i(W, H)
		_last_dyn_smooth_cell_sigs = {}
	ctx["prepared"] = true
	ctx["W"] = W
	ctx["H"] = H
	ctx["n"] = n
	ctx["cache_valid"] = cache_valid
	ctx["use_pixel_lists"] = world.cell_pixel_lists != null and not world.cell_pixel_lists.is_empty()
	# 复用 _last_dynamic_cell_sigs 加速邻居 sig 查询：调度器保证 dyn_smooth 跑在
	# dynamic_cell phase 完整完成之后，dict 内值就是本 stride 最新。
	ctx["cache_dynamic_fresh"] = not _last_dynamic_cell_sigs.is_empty()
	return ctx


func dyn_atlas_smooth_chunk_step(map: MapData, world: WorldData, ctx: Dictionary, cells,
		report: Dictionary, start_idx: int = 0, end_idx: int = -1) -> void:
	if not bool(ctx.get("prepared", false)):
		return
	var span: Vector2i = _cell_range(cells, start_idx, end_idx)
	if span.x >= span.y:
		_report_inc(report, "empty_calls")
		return
	var cpp_reason: String = _cpp_atlas_encode_disabled_reason(&"encode_dyn_smooth_atlas")
	if cpp_reason == "":
		if _try_cpp_dyn_smooth_atlas_encode(map, world, ctx, cells, report, span.x, span.y):
			return
		cpp_reason = str(report.get("fallback_reason", "cpp_fallback"))
	report["path"] = "gdscript"
	if cpp_reason != "":
		report["fallback_reason"] = cpp_reason
	_report_inc(report, "gd_calls")
	var n: int = int(ctx.n)
	var cache_valid: bool = bool(ctx.cache_valid)
	var use_pixel_lists: bool = bool(ctx.use_pixel_lists)
	var cache_dynamic_fresh: bool = bool(ctx.get("cache_dynamic_fresh", false))
	for i in range(span.x, span.y):
		var cell: HexCell = cells[i]
		if cell == null:
			continue
		# 中心 sig（与 dynamic_cell_atlas 完全相同的 R/G/B/A 量化）。
		var c_sig: int = _dynamic_cell_signature(cell)
		var cr: int = c_sig & 0xFF
		var cg: int = (c_sig >> 8) & 0xFF
		var cb: int = (c_sig >> 16) & 0xFF
		var ca: int = (c_sig >> 24) & 0xFF
		# 邻居均值（最多 6 个；缺失方向不补 0，按实际邻居数取均值，避免边界 cell 被压暗）。
		var nr: int = 0
		var ng: int = 0
		var nb: int = 0
		var na: int = 0
		var nc: int = 0
		var na_c: int = 0  # A 通道独立邻居计数：仅累加非海域邻居（D 项修复）
		# 同时累积 neighbor-aware cache sig：FNV-1a 32-bit，吃 7×4=28 bytes。
		var hood_h: int = 0x811C9DC5
		hood_h = ((hood_h ^ (c_sig & 0xFF)) * 0x01000193) & 0xFFFFFFFF
		hood_h = ((hood_h ^ ((c_sig >> 8) & 0xFF)) * 0x01000193) & 0xFFFFFFFF
		hood_h = ((hood_h ^ ((c_sig >> 16) & 0xFF)) * 0x01000193) & 0xFFFFFFFF
		hood_h = ((hood_h ^ ((c_sig >> 24) & 0xFF)) * 0x01000193) & 0xFFFFFFFF
		for nb_cell in map.get_neighbors(cell):
			if nb_cell == null:
				continue
			# 复用 dynamic_cell phase 刚写好的 cache；冷启用 fallback。
			var n_sig: int
			if cache_dynamic_fresh:
				n_sig = int(_last_dynamic_cell_sigs.get(nb_cell, -1))
				if n_sig == -1:
					n_sig = _dynamic_cell_signature(nb_cell)
			else:
				n_sig = _dynamic_cell_signature(nb_cell)
			nr += n_sig & 0xFF
			ng += (n_sig >> 8) & 0xFF
			nb += (n_sig >> 16) & 0xFF
			nc += 1
			# A 通道水陆分裂语义（sea-ice-render-source-unify 阶段 C）：
			#   - 中心是陆格：A=vitality，仅累加陆地邻居（sea-ice 邻居恒持 ice_byte，
			#     若纳入会污染陆地 vitality blur）；保持 2026-05-21 既有修复语义。
			#   - 中心是水格：A=sea_ice_fraction，仅累加水域邻居（陆地邻居 A=vit
			#     与海冰物理无关，纳入会拖偏冰边界）。陆地邻居恒持 vit，对中心海
			#     冰 box blur 是噪声源，必须排除。
			# 关键：水陆分类必须用 is_water 语义（含 SEA_ICE），不能用 passable_sea，
			# 否则 SEA_ICE 邻居会被错归"陆地邻居"导致 A 通道污染。
			# SAME_SOURCE：gdext/src/world_ext.cpp::encode_dyn_smooth_atlas /
			#              monolithic atlas pipeline smooth phase。
			var center_is_water: bool = MapData.terrain_is_water(int(cell.terrain))
			var nb_is_water: bool = MapData.terrain_is_water(int(nb_cell.terrain))
			if center_is_water:
				if nb_is_water:
					na += (n_sig >> 24) & 0xFF
					na_c += 1
			else:
				if not nb_is_water:
					na += (n_sig >> 24) & 0xFF
					na_c += 1
			hood_h = ((hood_h ^ (n_sig & 0xFF)) * 0x01000193) & 0xFFFFFFFF
			hood_h = ((hood_h ^ ((n_sig >> 8) & 0xFF)) * 0x01000193) & 0xFFFFFFFF
			hood_h = ((hood_h ^ ((n_sig >> 16) & 0xFF)) * 0x01000193) & 0xFFFFFFFF
			hood_h = ((hood_h ^ ((n_sig >> 24) & 0xFF)) * 0x01000193) & 0xFFFFFFFF

		# Cache 比对：用 neighbor-aware hood_h（不再用 smooth_sig output byte）。
		if cache_valid and int(_last_dyn_smooth_cell_sigs.get(cell, -2)) == hood_h:
			continue
		_last_dyn_smooth_cell_sigs[cell] = hood_h

		# Cache miss → 真正算 smooth 输出 byte 并写 buffer。
		var or_: int
		var og: int
		var ob: int
		var oa: int
		if nc > 0:
			# 中心 0.5 + 邻居均值 0.5（R/G）
			# 2026-05-21 修复：B 通道（snow_cover）是阈值型现象，不做邻居平均，
			# 否则单格 95% 雪盖会被无雪邻居拖到 ~47.5% 后被 shader 后段压不可见。
			# A 通道仅平均非海域邻居（见上面 for 循环内的 SAME_SOURCE 注释）。
			# SAME_SOURCE 见 gdext/src/world_ext.cpp::encode_dyn_smooth_atlas。
			or_ = clampi((cr + nr / nc) / 2, 0, 255)
			og = clampi((cg + ng / nc) / 2, 0, 255)
			ob = clampi(cb, 0, 255)  # snow passthrough：保留 cell 真值
			if na_c > 0:
				oa = clampi((ca + na / na_c) / 2, 0, 255)
			else:
				oa = clampi(ca, 0, 255)  # 全是海邻 → 退回中心值
		else:
			or_ = cr
			og = cg
			ob = cb
			oa = ca
		var pixels: PackedInt32Array = PackedInt32Array()
		if use_pixel_lists:
			pixels = world.cell_pixel_lists.get(cell, PackedInt32Array())
		# [TEMP DIAG sea-ice GD-smo-write]
		if cell != null and MapData.terrain_is_water(int(cell.terrain)) and float(cell.sea_ice_fraction) > 0.5:
			if not Engine.has_meta("_diag_gd_smo_dumped"):
				Engine.set_meta("_diag_gd_smo_dumped", 0)
			var _diag_n: int = int(Engine.get_meta("_diag_gd_smo_dumped"))
			if _diag_n < 8:
				print("[GD-SMO-WRITE] cell=", cell, " ICE=", float(cell.sea_ice_fraction),
					" ca=", ca, " oa=", oa, " nc=", nc, " na_c=", na_c, " na=", na,
					" px0=", (pixels[0] if pixels.size() > 0 else -1))
				Engine.set_meta("_diag_gd_smo_dumped", _diag_n + 1)
		for px_idx in pixels:
			if px_idx < 0 or px_idx >= n:
				continue
			var base_px: int = px_idx * 4
			_dyn_atlas_smooth_buf[base_px] = or_
			_dyn_atlas_smooth_buf[base_px + 1] = og
			_dyn_atlas_smooth_buf[base_px + 2] = ob
			_dyn_atlas_smooth_buf[base_px + 3] = oa
		report.dirty_cells = int(report.dirty_cells) + 1
		report.pixels_written = int(report.pixels_written) + pixels.size()


func dyn_atlas_smooth_chunk_finalize(world: WorldData, ctx: Dictionary, report: Dictionary) -> void:
	if not bool(ctx.get("prepared", false)):
		return
	var W: int = int(ctx.W)
	var H: int = int(ctx.H)
	report.prepared = true
	report.dirty = int(report.dirty_cells) > 0 or world.dyn_atlas_smooth_tex == null
	world.dyn_atlas_smooth_buffer = _dyn_atlas_smooth_buf
	if bool(report.dirty):
		var img := Image.create_from_data(W, H, false, Image.FORMAT_RGBA8, _dyn_atlas_smooth_buf)
		if world.dyn_atlas_smooth_tex != null and world.dyn_atlas_smooth_tex.get_size() == Vector2(float(W), float(H)):
			world.dyn_atlas_smooth_tex.update(img)
		else:
			world.dyn_atlas_smooth_tex = ImageTexture.create_from_image(img)


# ice_state_atlas：R8，每像素 = 该 cell.sea_ice_frac × 255。仅水域 cell 写非零，
# 陆地恒 0。shader 据此替换原 lat-driven 静态 ice mask（病灶 A 解药）。
# 走 cell-level byte dirty 缓存（与 bake_sea_ice_fraction_only 同构但本路径独立，
# 因为目标 buffer 不同 + shader uniform 不同）。
func rebake_ice_state_atlas(map: MapData, world: WorldData) -> Dictionary:
	# [cell-indirect single-path] flag 开 → 海冰随 dyn_lut.a 迁移，ice_state_atlas 无消费者，跳过。
	if DCFeatureFlags.cell_indirection_active():
		return _indirection_skip_atlas_report()
	# Thin wrapper：保持旧签名 100% 兼容。
	var report := {
		"prepared": false,
		"dirty": false,
		"dirty_cells": 0,
		"pixels_written": 0,
		"elapsed_ms": 0.0,
	}
	if map == null or world == null:
		return report
	var t_us: int = Time.get_ticks_usec()
	var ctx: Dictionary = ice_state_atlas_chunk_begin(map, world)
	if not bool(ctx.get("prepared", false)):
		return report
	# Cell 来源：优先 water_cell_pixel_lists.keys()；fallback 走 all_cells + 过滤。
	var cells = ice_state_atlas_default_cell_source(map, world, ctx)
	ice_state_atlas_chunk_step(map, world, ctx, cells, report)
	ice_state_atlas_chunk_finalize(world, ctx, report)
	report.elapsed_ms = float(Time.get_ticks_usec() - t_us) / 1000.0
	return report


# ─── ice_state_atlas chunk API ────────────────────────────────────────────────
# [deprecated 2026-05-20 atlas-pipeline-cpp]
# 当 cpp_atlas_pipeline_enabled = true 时不会被调用（DOTS C++ pipeline 取代）。
# fallback 路径仍走 water_cell_pixel_lists（cpp 路径走整图 SoA + cell_psea 过滤，
# bit-equal 因陆地 cell sea_ice_frac=0 → byte=0 而成立）。
func ice_state_atlas_chunk_begin(map: MapData, world: WorldData) -> Dictionary:
	var ctx: Dictionary = {"prepared": false}
	if map == null or world == null:
		return ctx
	var W: int = world.derived_size.x
	var H: int = world.derived_size.y
	var n: int = W * H
	if n <= 0:
		return ctx
	var cache_valid: bool = (_ice_state_cache_size == Vector2i(W, H) \
			and _ice_state_buf.size() == n)
	if not cache_valid:
		_ice_state_buf = PackedByteArray()
		_ice_state_buf.resize(n)
		_ice_state_buf.fill(0)
		_ice_state_cache_size = Vector2i(W, H)
		_last_ice_state_cell_bytes = {}
	var lists: Dictionary = world.water_cell_pixel_lists
	var use_water_lists: bool = lists != null and not lists.is_empty()
	ctx["prepared"] = true
	ctx["W"] = W
	ctx["H"] = H
	ctx["n"] = n
	ctx["cache_valid"] = cache_valid
	ctx["use_water_lists"] = use_water_lists
	ctx["use_pixel_lists"] = world.cell_pixel_lists != null and not world.cell_pixel_lists.is_empty()
	return ctx


# 默认 cell 数据源：根据 ctx 选择 water_cell_pixel_lists 或 all_cells。
# 调度器（DynamicVisualAtlasUploadSystem）会在 phase 入口快照这份序列做切片。
func ice_state_atlas_default_cell_source(map: MapData, world: WorldData, ctx: Dictionary) -> Array:
	if not bool(ctx.get("prepared", false)):
		return []
	if bool(ctx.use_water_lists):
		return world.water_cell_pixel_lists.keys()
	return map.all_cells()


func ice_state_atlas_chunk_step(map: MapData, world: WorldData, ctx: Dictionary, cells,
		report: Dictionary, start_idx: int = 0, end_idx: int = -1) -> void:
	if not bool(ctx.get("prepared", false)):
		return
	var span: Vector2i = _cell_range(cells, start_idx, end_idx)
	if span.x >= span.y:
		_report_inc(report, "empty_calls")
		return
	var cpp_reason: String = _cpp_atlas_encode_disabled_reason(&"encode_ice_state_atlas")
	if cpp_reason == "":
		if _try_cpp_ice_state_atlas_encode(map, world, ctx, cells, report, span.x, span.y):
			return
		cpp_reason = str(report.get("fallback_reason", "cpp_fallback"))
	report["path"] = "gdscript"
	if cpp_reason != "":
		report["fallback_reason"] = cpp_reason
	_report_inc(report, "gd_calls")
	var n: int = int(ctx.n)
	var cache_valid: bool = bool(ctx.cache_valid)
	var use_water_lists: bool = bool(ctx.use_water_lists)
	var use_pixel_lists: bool = bool(ctx.use_pixel_lists)
	if use_water_lists:
		var lists: Dictionary = world.water_cell_pixel_lists
		for i in range(span.x, span.y):
			var cell: HexCell = cells[i]
			if cell == null:
				continue
			var byte_v: int = _q01_byte_ice(float(cell.sea_ice_fraction))
			if cache_valid and int(_last_ice_state_cell_bytes.get(cell, -1)) == byte_v:
				continue
			_last_ice_state_cell_bytes[cell] = byte_v
			var pixels: PackedInt32Array = lists.get(cell, PackedInt32Array())
			for px_idx in pixels:
				if px_idx < 0 or px_idx >= n:
					continue
				_ice_state_buf[px_idx] = byte_v
			report.dirty_cells = int(report.dirty_cells) + 1
			report.pixels_written = int(report.pixels_written) + pixels.size()
	else:
		# Fallback：扫所有 cell 但只处理水格。
		# sea-ice-render-source-unify 阶段 C：用 is_water (not passable_land) 而非
		# passable_sea，否则 SEA_ICE cell 会被漏掉（passable_sea=false），
		# ice_state atlas 拿不到它的 sea_ice_fraction。与 cpp monolithic
		# pipeline cell_is_ice_renderable 语义一致。
		for i in range(span.x, span.y):
			var cell: HexCell = cells[i]
			if cell == null or not MapData.terrain_is_water(int(cell.terrain)):
				continue
			var byte_v: int = _q01_byte_ice(float(cell.sea_ice_fraction))
			if cache_valid and int(_last_ice_state_cell_bytes.get(cell, -1)) == byte_v:
				continue
			_last_ice_state_cell_bytes[cell] = byte_v
			var pixels: PackedInt32Array = PackedInt32Array()
			if use_pixel_lists:
				pixels = world.cell_pixel_lists.get(cell, PackedInt32Array())
			for px_idx in pixels:
				if px_idx < 0 or px_idx >= n:
					continue
				_ice_state_buf[px_idx] = byte_v
			report.dirty_cells = int(report.dirty_cells) + 1
			report.pixels_written = int(report.pixels_written) + pixels.size()


func ice_state_atlas_chunk_finalize(world: WorldData, ctx: Dictionary, report: Dictionary) -> void:
	if not bool(ctx.get("prepared", false)):
		return
	var W: int = int(ctx.W)
	var H: int = int(ctx.H)
	report.prepared = true
	report.dirty = int(report.dirty_cells) > 0 or world.ice_state_tex == null
	world.ice_state_buffer = _ice_state_buf
	if bool(report.dirty):
		var img := Image.create_from_data(W, H, false, Image.FORMAT_R8, _ice_state_buf)
		if world.ice_state_tex != null and world.ice_state_tex.get_size() == Vector2(float(W), float(H)):
			world.ice_state_tex.update(img)
		else:
			world.ice_state_tex = ImageTexture.create_from_image(img)


func get_last_enum_atlas_upload_report() -> Dictionary:
	return _last_enum_atlas_upload_report.duplicate(true)


# ─── plan/dirty-push-atlas-encode 阶段 F：C++ encode fast-path helpers ────────
#
# 共享设计：所有 4 个 atlas 走同一 CSR 协议（cell_indices/cell_first_px/
# cell_px_count/flat_px_indices），由 `_pack_csr_for_cells()` 一次构建，按需
# 加上 passable_sea / prev_* / neighbor 等 pass 特有字段后调对应 cpp method。
#
# 失败模式：cpp method 缺失、CSR 打包失败、SoA slot 不匹配等情况下 helper 返回
# false，caller 直接走下方 GDScript loop（透明 fallback）。**不报错、不抛异常**。

# 是否启用 cpp encode pass。使用 helper 集中判断三件事：
#   1. cpp_atlas_encode_enabled flag 为 true（或 climate_profile 缺失时跳过）
#   2. _world_ext 已注入（DCWorld bind 完成）
#   3. ext 实现了对应 method（向前兼容旧 dll）
func _cpp_atlas_encode_active(method_name: StringName) -> bool:
	return _cpp_atlas_encode_disabled_reason(method_name) == ""


func _cpp_atlas_encode_disabled_reason(method_name: StringName) -> String:
	if _climate_profile == null:
		return "no_climate_profile"
	# dots-flag-prune-pr1 round 2 (2026-05-22): cpp_atlas_encode_enabled flag 已删除——
	# C++ atlas encode 现恒走入口，仅受 ext + has_method 探测控制。
	if _world_ext == null:
		return "no_world_ext"
	if not _world_ext.has_method(method_name):
		return "method_missing"
	return ""


func _report_inc(report: Dictionary, key: String, delta: int = 1) -> void:
	report[key] = int(report.get(key, 0)) + delta


func _cell_range(cells, start_idx: int = 0, end_idx: int = -1) -> Vector2i:
	var count: int = cells.size()
	var s: int = clampi(start_idx, 0, count)
	var e: int = count if end_idx < 0 else clampi(end_idx, s, count)
	return Vector2i(s, e)


# 共享 CSR 打包：把 dirty cells（HexCell Array）转成 4 个 PackedInt32Array。
# - cells: HexCell Array，可能含 null（caller 应已过滤但兼容 null 跳过）
# - world: 用于读 cell_pixel_lists / water_cell_pixel_lists
# - use_water_lists: ice_state pass 走 water_cell_pixel_lists；其他走 cell_pixel_lists
# - n_pix: W*H，用于越界过滤
# 返回 Dictionary：含 cell_indices / cell_first_px / cell_px_count / flat_px_indices /
#                 cell_is_water / valid_count（实际有效 cell 数；剔除 null/idx<0/无 pixel list）
# 如果 valid_count == 0，caller 应直接 return（无需调 cpp）。
#
# sea-ice-render-source-unify 阶段 C：cell_is_water 语义代替原来的 cell_passable_sea。
# is_water = not passable_land，含 OCEAN/COAST/LAKE/SEA_ICE/REEF/KELP 等所有水域；
# 原 passable_sea 仅指“可航行”造成 SEA_ICE 被误归入陆格，是本阶段修复的根因。
#
# P1：当 `world.cell_first_px_arr` 已构建（_bake_height_biome_moisture 跑过）
# 且 use_water_lists=false 时，走 SoA fast path：
#   - 直接读 `world.cell_first_px_arr[idx]` 拿 flat 起始 / `cell_px_count_arr[idx]`
#     拿长度，不再走 `cell_pixel_lists.has(cell)` + `.get(cell)` 的 K 次 Dict 查找。
#   - is_water 改用 `MapData.is_water_lut()[map.terrain_arr[idx]]`，消除 `cell.is_water`/
#     `cell.passable_land` 字段读取（均需走 GDScript 属性路径，远比 PackedByteArray 索引贵）。
# fallback：use_water_lists=true / SoA 未 build / map==null / terrain_arr 大小不符 →
#           走 Dict + “not cell.passable_land” 旧路径（行为完全一致）。
func _pack_csr_for_cells(world: WorldData, cells, use_water_lists: bool, n_pix: int,
		start_idx: int = 0, end_idx: int = -1, map: MapData = null) -> Dictionary:
	# ── P1 SoA fast path ──────────────────────────────────────────────
	if (not use_water_lists) and world != null and world.cell_first_px_arr.size() > 0:
		var _soa_n: int = world.cell_first_px_arr.size()
		# terrain_arr / is_water_render_lut 二选一：map 若没传或 size 不符则退化为
		# “not cell.passable_land + SEA_ICE 兜底”字段读取（仍比走 Dict 快）。
		# 阶段 D：渲染语义专用 LUT（SEA_ICE 强制视为水），与 gameplay is_water_lut 解耦。
		var _have_lut: bool = map != null \
				and map.terrain_arr.size() == _soa_n \
				and MapData.is_water_render_lut().size() >= 256
		var _terrain_arr: PackedByteArray = map.terrain_arr if _have_lut else PackedByteArray()
		var _iw_lut: PackedByteArray = MapData.is_water_render_lut() if _have_lut else PackedByteArray()
		var _span_fast: Vector2i = _cell_range(cells, start_idx, end_idx)
		var _kmax_fast: int = _span_fast.y - _span_fast.x
		var _ci_fast: PackedInt32Array = PackedInt32Array(); _ci_fast.resize(_kmax_fast)
		var _fpx_fast: PackedInt32Array = PackedInt32Array(); _fpx_fast.resize(_kmax_fast)
		var _pxc_fast: PackedInt32Array = PackedInt32Array(); _pxc_fast.resize(_kmax_fast)
		var _iw_fast: PackedByteArray = PackedByteArray(); _iw_fast.resize(_kmax_fast)
		# [perf 2026-05-20] 方案 B：flat_px 整图静态复用。
		# 之前注释提到"caller 期望 flat_px_indices 是按 K 个 cell 顺序串接的紧凑数组"——
		# 实际上 C++ 端 parse_csr_common 只校验 `last_first + last_count <= total_px`，
		# 完全允许 flat_px 大于 sum(cnt)。直接复用 `world.flat_px_indices_arr`（整图全 flat）
		# 并让 `_fpx_fast[k] = _src_first[cell_idx]`（指向整图 flat 里该 cell 的原始 offset），
		# CSR 语义等价。收益巨大：
		#   - 不再做 O(total_px) 的 int 拷贝循环（2400 cell × 30~100 px = 7.2万~24万 int/call）
		#   - 不再做 PackedInt32Array.resize（avoid GDScript 内存分配 + COW detach）
		#   - flat_px_indices_arr 是 WorldData 持有的稳定数组，传递只是引用计数 +1
		# 风险评估：
		#   - SoA 端用 `first==-1 / count==0` 表示空 cell —— 此时 _fpx_fast[k]=-1，C++ CNT[k]=0
		#     不会真正去 FIRST 访问；为防越界 sanity，在 _cnt==0 时把 _first 归零（安全索引）。
		var _src_flat: PackedInt32Array = world.flat_px_indices_arr
		var _src_first: PackedInt32Array = world.cell_first_px_arr
		var _src_count: PackedInt32Array = world.cell_px_count_arr
		var _k_fast: int = 0
		for _i in range(_span_fast.x, _span_fast.y):
			var _cell: HexCell = cells[_i]
			if _cell == null:
				continue
			var _idx: int = int(_cell.index)
			if _idx < 0 or _idx >= _soa_n:
				continue
			var _first: int = _src_first[_idx]
			var _cnt: int = _src_count[_idx]
			# 与 Dict 路径完全一致的语义：has(cell)=false → 视为"该 cell 无像素"。
			_ci_fast[_k_fast] = _idx
			# 空 cell：把 first 归零（避免 C++ parse_csr_common 看到 first=-1 误判 out-of-bounds）
			if _cnt <= 0 or _first < 0:
				_fpx_fast[_k_fast] = 0
				_pxc_fast[_k_fast] = 0
			else:
				_fpx_fast[_k_fast] = _first
				_pxc_fast[_k_fast] = _cnt
			# is_water：LUT 查表 / 字段 fallback。
			# 阶段 D：使用 is_water_render_lut（含 SEA_ICE）→ 不再需要 `or _t_idx == 20` 散点兜底；
			# fallback 路径保留 SEA_ICE 兜底以确保 LUT 不可用时（极不应触发）仍正确。
			if _have_lut:
				_iw_fast[_k_fast] = _iw_lut[_terrain_arr[_idx]]
			else:
				var _t_fb: int = int(_cell.terrain) & 0xFF
				_iw_fast[_k_fast] = MapData.terrain_is_water_u8(_t_fb)
			_k_fast += 1
		_ci_fast.resize(_k_fast)
		_fpx_fast.resize(_k_fast)
		_pxc_fast.resize(_k_fast)
		_iw_fast.resize(_k_fast)
		# flat_px_indices 直接传整图（不再拷贝；C++ 用 FIRST/CNT 索引即可）。
		return {
			"cell_indices": _ci_fast,
			"cell_first_px": _fpx_fast,
			"cell_px_count": _pxc_fast,
			"flat_px_indices": _src_flat,
			"cell_is_water": _iw_fast,
			"valid_count": _k_fast,
		}

	# ── Dict fallback path（旧行为，保留） ──────────────────────────────
	var lists: Dictionary
	if use_water_lists:
		lists = world.water_cell_pixel_lists if world != null else {}
	else:
		lists = world.cell_pixel_lists if world != null else {}

	var span: Vector2i = _cell_range(cells, start_idx, end_idx)
	var k_max: int = span.y - span.x
	var cell_indices: PackedInt32Array = PackedInt32Array()
	cell_indices.resize(k_max)
	var first_px: PackedInt32Array = PackedInt32Array()
	first_px.resize(k_max)
	var px_count: PackedInt32Array = PackedInt32Array()
	px_count.resize(k_max)
	var is_water_arr: PackedByteArray = PackedByteArray()
	is_water_arr.resize(k_max)

	var flat_px: PackedInt32Array = PackedInt32Array()
	# 估算 flat_px 容量：典型每 cell 30-100 px。先粗占 64×k_max；resize 仅在结尾一次校准。
	flat_px.resize(k_max * 64)
	var flat_w: int = 0
	var k: int = 0
	for i in range(span.x, span.y):
		var cell: HexCell = cells[i]
		if cell == null or cell.index < 0:
			continue
		var pixels: PackedInt32Array
		if lists != null and lists.has(cell):
			pixels = lists.get(cell, PackedInt32Array())
		else:
			pixels = PackedInt32Array()
		# 跳过 0-pixel cell：cpp 端 byte fill 也是 no-op，但保留会拉长 K 影响 sig cache 命中。
		# 但 ecology pass 即使 0-pixel 也要更新 prev_*/transition_age 状态——这种情况
		# caller 会传 use_water_lists=false 同时确保 cells 已过滤 null。这里保留写入。
		cell_indices[k] = cell.index
		first_px[k] = flat_w
		px_count[k] = pixels.size()
		# sea-ice-render-source-unify 阶段 C：is_water = not passable_land，含 SEA_ICE 等所有水域。
		is_water_arr[k] = MapData.terrain_is_water_u8(int(cell.terrain))
		# 拷贝 pixel idx 到 flat 数组
		var nx: int = pixels.size()
		if flat_w + nx > flat_px.size():
			flat_px.resize(maxi(flat_w + nx, flat_px.size() * 2))
		for p in range(nx):
			flat_px[flat_w + p] = pixels[p]
		flat_w += nx
		k += 1

	cell_indices.resize(k)
	first_px.resize(k)
	px_count.resize(k)
	is_water_arr.resize(k)
	flat_px.resize(flat_w)

	return {
		"cell_indices": cell_indices,
		"cell_first_px": first_px,
		"cell_px_count": px_count,
		"flat_px_indices": flat_px,
		"cell_is_water": is_water_arr,
		"valid_count": k,
	}


# dynamic_cell_atlas C++ fast-path。返回 true = 成功消费，caller 直接 return。
# P1：增加 map 参数以启用 _pack_csr_for_cells 的 SoA fast path。
func _try_cpp_dynamic_cell_atlas_encode(map: MapData, world: WorldData, ctx: Dictionary, cells,
		report: Dictionary, start_idx: int = 0, end_idx: int = -1) -> bool:
	var n: int = int(ctx.n)
	if n <= 0:
		report["fallback_reason"] = "empty_texture"
		return false
	var span: Vector2i = _cell_range(cells, start_idx, end_idx)
	var csr: Dictionary = _pack_csr_for_cells(world, cells, false, n, span.x, span.y, map)
	var k: int = int(csr.get("valid_count", 0))
	if k <= 0:
		_report_inc(report, "empty_calls")
		report["path"] = "cpp_empty"
		report["fallback_reason"] = ""
		return true
	# [perf 2026-05-20 sig-diff-skip] 与 GDScript fallback 对齐：
	#   GD 路径 line 727: `if cache_valid and _last_dynamic_cell_sigs.get(cell, -1) == sig: continue`
	#   现在打包 prev_sigs 给 cpp，让 cpp 端命中 sig 一致就跳过 pixel fan-out（热点）。
	#   按 cell_indices 顺序回查 _last_dynamic_cell_sigs（key 是 HexCell 引用），
	#   不命中（首次/驱逐）填 -1（uint32 cast 不会等于任何真实 sig）。
	var cache_valid: bool = bool(ctx.get("cache_valid", false))
	var prev_sigs: PackedInt32Array = PackedInt32Array()
	if cache_valid and not _last_dynamic_cell_sigs.is_empty():
		prev_sigs.resize(k)
		var ci_pre: PackedInt32Array = csr["cell_indices"]
		var k_idx2: int = 0
		for i in range(span.x, span.y):
			var cell_pre: HexCell = cells[i]
			if cell_pre == null or cell_pre.index < 0:
				continue
			if k_idx2 >= k:
				break
			# csr 端按 cells 顺序写入，cell_indices[k_idx2] 必然 == cell_pre.index
			# （_pack_csr_for_cells 跳过 null/index<0，与本循环同步）。
			if cell_pre.index == ci_pre[k_idx2]:
				prev_sigs[k_idx2] = int(_last_dynamic_cell_sigs.get(cell_pre, -1))
			else:
				prev_sigs[k_idx2] = -1
			k_idx2 += 1
	var knobs := {
		"n_pix": n,
		"stride_bytes": 4,
		"atlas_buffer": _dynamic_cell_atlas_buf,
		"cell_indices": csr["cell_indices"],
		"cell_first_px": csr["cell_first_px"],
		"cell_px_count": csr["cell_px_count"],
		"flat_px_indices": csr["flat_px_indices"],
		"cell_is_water": csr["cell_is_water"],
		"cache_valid": cache_valid,
		"prev_sigs": prev_sigs,
	}
	var out: Dictionary = _world_ext.call("encode_dynamic_cell_atlas", knobs)
	if bool(out.get("fallback", true)):
		report["fallback_reason"] = str(out.get("reason", "cpp_fallback"))
		return false
	# 取回 buffer（C++ 端通过 PackedByteArray 直写后返回；GDScript 端 PackedByteArray
	# 是 COW，需要重新赋值才能让"GDScript 后续 finalize 看到新 byte"）。
	_dynamic_cell_atlas_buf = out["atlas_buffer"]
	# 写回 sig cache（caller 路径下 _last_dynamic_cell_sigs[cell] = sig）。
	# C++ 没有 sig cache 命中 skip，所以所有进入的 cell 都视为 dirty 并刷 cache。
	var new_sigs: PackedInt32Array = out.get("new_sigs", PackedInt32Array())
	if new_sigs.size() == k:
		var ci: PackedInt32Array = csr["cell_indices"]
		var k_idx: int = 0
		for i in range(span.x, span.y):
			var cell: HexCell = cells[i]
			if cell == null or cell.index < 0:
				continue
			if k_idx >= k:
				break
			if cell.index == ci[k_idx]:
				_last_dynamic_cell_sigs[cell] = new_sigs[k_idx]
			k_idx += 1
	report.dirty_cells = int(report.dirty_cells) + k
	report.pixels_written = int(report.pixels_written) + int(out.get("pixels_written", 0))
	_report_inc(report, "cpp_calls")
	report["path"] = "cpp"
	report["fallback_reason"] = ""
	return true


# ecology_visual_atlas C++ fast-path。
# P1：增加 map 参数以启用 _pack_csr_for_cells 的 SoA fast path。
func _try_cpp_ecology_visual_atlas_encode(map: MapData, world: WorldData, ctx: Dictionary, cells,
		report: Dictionary, start_idx: int = 0, end_idx: int = -1) -> bool:
	var n: int = int(ctx.n)
	if n <= 0:
		report["fallback_reason"] = "empty_texture"
		return false
	var cache_valid: bool = bool(ctx.cache_valid)
	var span: Vector2i = _cell_range(cells, start_idx, end_idx)
	var csr: Dictionary = _pack_csr_for_cells(world, cells, false, n, span.x, span.y, map)
	var k: int = int(csr.get("valid_count", 0))
	if k <= 0:
		_report_inc(report, "empty_calls")
		report["path"] = "cpp_empty"
		report["fallback_reason"] = ""
		return true
	# 打包 prev_veg / prev_vitality / prev_transition（按 cells 顺序）
	var ci: PackedInt32Array = csr["cell_indices"]
	var prev_veg: PackedByteArray = PackedByteArray()
	prev_veg.resize(k)
	var prev_vit: PackedByteArray = PackedByteArray()
	prev_vit.resize(k)
	var prev_tr: PackedByteArray = PackedByteArray()
	prev_tr.resize(k)
	# 拿取 cell 的本 stride 之前的状态（首次访问时取 cur 作 fallback 与 GDScript loop 同义）
	# P1-E：改用 PackedByteArray SoA，cell.index 直查 O(1)，消除 Dict.get 哈希。
	# baseline 已在 ecology_visual_atlas_chunk_begin 的 cache_invalid 路径里灌入 cur，
	# 所以这里"首次访问 == 拿到 cur"的旧语义被透明保留；不再需要 cur_veg/cur_vit_byte fallback。
	var soa_n: int = _eco_veg_bytes_arr.size()
	var k_idx: int = 0
	for i in range(span.x, span.y):
		var cell: HexCell = cells[i]
		if cell == null or cell.index < 0:
			continue
		if k_idx >= k:
			break
		var ci_idx: int = cell.index
		if ci_idx < soa_n:
			prev_veg[k_idx] = _eco_veg_bytes_arr[ci_idx]
			prev_vit[k_idx] = _eco_vitality_bytes_arr[ci_idx]
			prev_tr[k_idx] = _eco_transition_age_arr[ci_idx]
		else:
			# 边界 fallback：SoA 容量不足时退化到 cur（与旧 Dict.get(cell, cur) 等价）
			prev_veg[k_idx] = int(cell.vegetation) & 0xFF
			prev_vit[k_idx] = _q01_byte(float(cell.vegetation_vitality))
			prev_tr[k_idx] = 0
		k_idx += 1
	var knobs := {
		"n_pix": n,
		"stride_bytes": 4,
		"atlas_buffer": _ecology_visual_atlas_buf,
		"cell_indices": ci,
		"cell_first_px": csr["cell_first_px"],
		"cell_px_count": csr["cell_px_count"],
		"flat_px_indices": csr["flat_px_indices"],
		"cell_is_water": csr["cell_is_water"],
		"prev_veg": prev_veg,
		"prev_vitality": prev_vit,
		"prev_transition": prev_tr,
		"cache_valid": cache_valid,
		"terrain_lake": int(TerrainType.TERRAIN.LAKE),
		"terrain_sea_ice": int(TerrainType.TERRAIN.SEA_ICE),
		"veg_none": int(VegetationType.VEG.NONE),
	}
	var out: Dictionary = _world_ext.call("encode_ecology_visual_atlas", knobs)
	if bool(out.get("fallback", true)):
		report["fallback_reason"] = str(out.get("reason", "cpp_fallback"))
		return false
	_ecology_visual_atlas_buf = out["atlas_buffer"]
	var new_veg: PackedByteArray = out.get("new_veg", PackedByteArray())
	var new_vit: PackedByteArray = out.get("new_vitality", PackedByteArray())
	var new_tr: PackedByteArray = out.get("new_transition", PackedByteArray())
	var new_sigs: PackedInt32Array = out.get("new_sigs", PackedInt32Array())
	if new_veg.size() == k and new_vit.size() == k and new_tr.size() == k:
		k_idx = 0
		for i in range(span.x, span.y):
			var cell: HexCell = cells[i]
			if cell == null or cell.index < 0:
				continue
			if k_idx >= k:
				break
			# P1-E：辅助状态必须每 cell 都写（无论是否 dirty；GDScript loop 同理）
			# 走 SoA cell.index 直查；旧 Dict 不再维护。
			var ci_idx2: int = cell.index
			if ci_idx2 < _eco_veg_bytes_arr.size():
				_eco_veg_bytes_arr[ci_idx2] = int(new_veg[k_idx]) & 0xFF
				_eco_vitality_bytes_arr[ci_idx2] = int(new_vit[k_idx]) & 0xFF
				_eco_transition_age_arr[ci_idx2] = int(new_tr[k_idx]) & 0xFF
			# 维护 active decay set（保留 Dict 形态，外部消费方依赖 contract）
			if int(new_tr[k_idx]) > 0:
				_eco_active_decay_set[cell] = true
			else:
				_eco_active_decay_set.erase(cell)
			if k_idx < new_sigs.size():
				_last_ecology_visual_sigs[cell] = new_sigs[k_idx]
			k_idx += 1
	report.dirty_cells = int(report.dirty_cells) + k
	report.pixels_written = int(report.pixels_written) + int(out.get("pixels_written", 0))
	_report_inc(report, "cpp_calls")
	report["path"] = "cpp"
	report["fallback_reason"] = ""
	return true


# dyn_atlas_smooth C++ fast-path。需要 neighbor_indices（n_cells*6）+ neighbor_is_water（K*6）。
func _try_cpp_dyn_smooth_atlas_encode(map: MapData, world: WorldData, ctx: Dictionary, cells,
		report: Dictionary, start_idx: int = 0, end_idx: int = -1) -> bool:
	var n: int = int(ctx.n)
	if n <= 0:
		report["fallback_reason"] = "empty_texture"
		return false
	var span: Vector2i = _cell_range(cells, start_idx, end_idx)
	var csr: Dictionary = _pack_csr_for_cells(world, cells, false, n, span.x, span.y, map)
	var k: int = int(csr.get("valid_count", 0))
	if k <= 0:
		_report_inc(report, "empty_calls")
		report["path"] = "cpp_empty"
		report["fallback_reason"] = ""
		return true
	# 邻居 SoA：neighbor_indices 已由 MapData 持有（rebuild 时建好），尺寸 = cell_count * 6。
	var nb_indices: PackedInt32Array = map.neighbor_indices_packed() if map.has_method("neighbor_indices_packed") else PackedInt32Array()
	if nb_indices.size() <= 0:
		# 没有 neighbor SoA 不能走 cpp（fallback 到 GDScript 的 map.get_neighbors）
		report["fallback_reason"] = "neighbor_indices_missing"
		return false
	# neighbor_is_water：长度 K*6，按 cells 顺序对每个 dirty cell 的 6 邻居打包 is_water。
	# sea-ice-render-source-unify 阶段 C：语义从 passable_sea 切换为 is_water（含 SEA_ICE）。
	var nb_iws: PackedByteArray = PackedByteArray()
	nb_iws.resize(k * 6)
	# P1-D：K*6 邻居 is_water 走 terrain_arr + is_water_lut 查表，消除
	# K*6 次 `map.cell_at(ni)` (Dictionary 哈希反查) + 字段读取双开销。
	# fallback 路径保持原 cell_at + `not passable_land` 字段读取行为。
	var _smooth_terrain_arr: PackedByteArray = map.terrain_arr if map != null else PackedByteArray()
	# 阶段 D：渲染语义专用 LUT（含 SEA_ICE）取代 is_water_lut，与 cpp / fast path 对齐。
	var _smooth_iw_lut: PackedByteArray = MapData.is_water_render_lut()
	var _smooth_have_lut: bool = _smooth_terrain_arr.size() > 0 \
			and _smooth_iw_lut.size() >= 256 \
			and _smooth_terrain_arr.size() == map.cell_count()
	var k_idx: int = 0
	for i in range(span.x, span.y):
		var cell: HexCell = cells[i]
		if cell == null or cell.index < 0:
			continue
		if k_idx >= k:
			break
		var ci_idx: int = cell.index
		var base_g: int = ci_idx * 6
		var base_l: int = k_idx * 6
		if _smooth_have_lut:
			# Fast path：纯 PackedArray 索引；is_water_render_lut 已含 SEA_ICE，零分支。
			for d in range(6):
				var ni_f: int = nb_indices[base_g + d] if base_g + d < nb_indices.size() else -1
				if ni_f >= 0 and ni_f < _smooth_terrain_arr.size():
					nb_iws[base_l + d] = _smooth_iw_lut[_smooth_terrain_arr[ni_f]]
				else:
					nb_iws[base_l + d] = 0
		else:
			# Fallback：cell_at + `not passable_land + SEA_ICE 兜底` 字段读取。
			for d in range(6):
				var ni: int = nb_indices[base_g + d] if base_g + d < nb_indices.size() else -1
				var nb_iw: int = 0
				if ni >= 0:
					var nb_cell: HexCell = map.cell_at(ni)
					if nb_cell != null:
						var _t_nb: int = int(nb_cell.terrain) & 0xFF
						if MapData.terrain_is_water(_t_nb):
							nb_iw = 1
				nb_iws[base_l + d] = nb_iw
		k_idx += 1
	var knobs := {
		"n_pix": n,
		"stride_bytes": 4,
		"atlas_buffer": _dyn_atlas_smooth_buf,
		"cell_indices": csr["cell_indices"],
		"cell_first_px": csr["cell_first_px"],
		"cell_px_count": csr["cell_px_count"],
		"flat_px_indices": csr["flat_px_indices"],
		"cell_is_water": csr["cell_is_water"],
		"neighbor_indices": nb_indices,
		"neighbor_is_water": nb_iws,
	}
	var out: Dictionary = _world_ext.call("encode_dyn_smooth_atlas", knobs)
	if bool(out.get("fallback", true)):
		report["fallback_reason"] = str(out.get("reason", "cpp_fallback"))
		return false
	_dyn_atlas_smooth_buf = out["atlas_buffer"]
	# 写回 hood-aware sig cache（FNV-1a hash, 与 GDScript 1:1）
	var new_sigs: PackedInt32Array = out.get("new_sigs", PackedInt32Array())
	if new_sigs.size() == k:
		k_idx = 0
		for i in range(span.x, span.y):
			var cell: HexCell = cells[i]
			if cell == null or cell.index < 0:
				continue
			if k_idx >= k:
				break
			_last_dyn_smooth_cell_sigs[cell] = new_sigs[k_idx]
			k_idx += 1
	report.dirty_cells = int(report.dirty_cells) + k
	report.pixels_written = int(report.pixels_written) + int(out.get("pixels_written", 0))
	_report_inc(report, "cpp_calls")
	report["path"] = "cpp"
	report["fallback_reason"] = ""
	return true


# ice_state_atlas C++ fast-path。caller 负责只把水域 cell 喂入；cpp 端不再过滤。
# P1：增加 map 参数（即便 ice 走 use_water_lists=true → Dict fallback 路径，
# 也保持 4 个 try_cpp_* 的签名一致，便于阅读）。
func _try_cpp_ice_state_atlas_encode(map: MapData, world: WorldData, ctx: Dictionary, cells,
		report: Dictionary, start_idx: int = 0, end_idx: int = -1) -> bool:
	var n: int = int(ctx.n)
	if n <= 0:
		report["fallback_reason"] = "empty_texture"
		return false
	# ice 走 water_cell_pixel_lists（caller 已交集水域 cell；fallback 时 caller 传非水域 cell
	# 也安全：cpp 端按 _q01_byte_ice 对 sea_ice_frac 量化，陆地 cell 该字段恒 0 → byte=0）。
	var use_water: bool = bool(ctx.get("use_water_lists", false))
	var span: Vector2i = _cell_range(cells, start_idx, end_idx)
	var csr: Dictionary = _pack_csr_for_cells(world, cells, use_water, n, span.x, span.y, map)
	var k: int = int(csr.get("valid_count", 0))
	if k <= 0:
		_report_inc(report, "empty_calls")
		report["path"] = "cpp_empty"
		report["fallback_reason"] = ""
		return true
	var knobs := {
		"n_pix": n,
		"stride_bytes": 1,
		"atlas_buffer": _ice_state_buf,
		"cell_indices": csr["cell_indices"],
		"cell_first_px": csr["cell_first_px"],
		"cell_px_count": csr["cell_px_count"],
		"flat_px_indices": csr["flat_px_indices"],
		# ice pass 不需要 is_water，但为了 CSR parse 共享 sanity（C++ 端会校验 K 匹配）
		# 仍然把 cell_is_water 字段塞进去（C++ ice 路径不读取）。
		"cell_is_water": csr["cell_is_water"],
	}
	var out: Dictionary = _world_ext.call("encode_ice_state_atlas", knobs)
	if bool(out.get("fallback", true)):
		report["fallback_reason"] = str(out.get("reason", "cpp_fallback"))
		return false
	_ice_state_buf = out["atlas_buffer"]
	# 写回 _last_ice_state_cell_bytes
	var new_bytes: PackedByteArray = out.get("new_bytes", PackedByteArray())
	if new_bytes.size() == k:
		var k_idx: int = 0
		for i in range(span.x, span.y):
			var cell: HexCell = cells[i]
			if cell == null or cell.index < 0:
				continue
			if k_idx >= k:
				break
			_last_ice_state_cell_bytes[cell] = int(new_bytes[k_idx])
			k_idx += 1
	report.dirty_cells = int(report.dirty_cells) + k
	report.pixels_written = int(report.pixels_written) + int(out.get("pixels_written", 0))
	_report_inc(report, "cpp_calls")
	report["path"] = "cpp"
	report["fallback_reason"] = ""
	return true


# plan/sim-2ms-simd-dirty-budget：enum atlas upload 节流核心判定。
# dots-flag-prune-pr1 round 2 (2026-05-22): use_atlas_dirty_throttle flag 已删除——
# 节流逻辑整体退役，函数退化为透明 passthrough（恒返 true 表示每次都 flush）。
# axis / dirty_cells 参数保留以兼容 caller 签名。
func _enum_atlas_throttle_should_flush(_axis: String, _dirty_cells: int) -> bool:
	return true


# plan/sim-2ms-simd-dirty-budget：强制 flush 入口（season 切换 / save /
# screenshot 等场景必须把累积的 dirty 立即同步到 GPU 避免视觉错位）。
# axis = "" 表示 flush 所有 axis；否则 flush 单 axis。
# Caller 必须在调用本函数后再触发 enum atlas 重烘走完整路径，本函数仅清算计数。
func force_flush_enum_atlas_throttle(axis: String = "") -> void:
	if axis == "":
		_enum_atlas_throttle_pending_dirty.clear()
		_enum_atlas_throttle_skipped_uploads.clear()
		_enum_atlas_throttle_ticks_since_flush.clear()
	else:
		_enum_atlas_throttle_pending_dirty.erase(axis)
		_enum_atlas_throttle_skipped_uploads.erase(axis)
		_enum_atlas_throttle_ticks_since_flush.erase(axis)


func _record_enum_atlas_upload_report(axis: String, path: String, elapsed_ms: float,
		dirty_cells: int, dirty_pixels: int, buffer_patch_ms: float,
		image_ms: float, upload_ms: float, cache_valid: bool) -> void:
	var out_path: String = path
	var skip_reason: String = _enum_atlas_cpp_skip_reason
	if skip_reason != "" and not path.begins_with("cpp_"):
		out_path = "%s:%s" % [path, skip_reason]
	_last_enum_atlas_upload_report = {
		"axis": axis,
		"path": out_path,
		"elapsed_ms": elapsed_ms,
		"dirty_cells": dirty_cells,
		"dirty_pixels": dirty_pixels,
		"buffer_patch_ms": buffer_patch_ms,
		"image_ms": image_ms,
		"upload_ms": upload_ms,
		"cache_valid": cache_valid,
		"cpp_skip_reason": skip_reason,
	}
	_enum_atlas_cpp_skip_reason = ""


func prewarm_dynamic_axis_caches(map: MapData, world: WorldData) -> void:
	if map == null or world == null:
		return
	var W := world.derived_size.x
	var H := world.derived_size.y
	var pix_count := W * H
	if pix_count <= 0:
		return
	if world.cell_pixel_lists.is_empty():
		return
	if world.cover_buffer.size() != pix_count or world.vegetation_buffer.size() != pix_count \
			or world.biome_buffer.size() != pix_count:
		return
	if _enum_atlas_data_size != Vector2i(W, H) or _enum_atlas_data.size() != pix_count * 4:
		return

	var cover_cache: Dictionary = {}
	var vegetation_cache: Dictionary = {}
	# J: 同步预热 biome 缓存，让下一次 rebake_biome_axes_only 直接走增量路径
	var biome_cache: Dictionary = {}
	var n_cells: int = map.cell_count()
	_last_cover_cell_bytes_packed = PackedByteArray()
	_last_vegetation_cell_bytes_packed = PackedByteArray()
	_last_biome_cell_bytes_packed = PackedByteArray()
	_last_cover_cell_bytes_packed.resize(n_cells)
	_last_vegetation_cell_bytes_packed.resize(n_cells)
	_last_biome_cell_bytes_packed.resize(n_cells)
	var cells_for_cache: Array = map.iter_cells() if map.has_indices() else map.all_cells()
	for cell_key in cells_for_cache:
		var cell: HexCell = cell_key
		if cell == null:
			continue
		var b_cover: int = int(cell.cover) & 0xFF
		var b_veg: int = int(cell.vegetation) & 0xFF
		var b_biome: int = int(cell.terrain) & 0xFF
		cover_cache[cell] = b_cover
		vegetation_cache[cell] = b_veg
		biome_cache[cell] = b_biome
		if cell.index >= 0 and cell.index < n_cells:
			_last_cover_cell_bytes_packed[cell.index] = b_cover
			_last_vegetation_cell_bytes_packed[cell.index] = b_veg
			_last_biome_cell_bytes_packed[cell.index] = b_biome
	_last_cover_cell_bytes = cover_cache
	_last_vegetation_cell_bytes = vegetation_cache
	_last_biome_cell_bytes = biome_cache
	_cover_cache_size = Vector2i(W, H)
	_vegetation_cache_size = Vector2i(W, H)
	_biome_cache_size = Vector2i(W, H)

# Systemic Ocean Currents：重烘洋流 + 上升流 buffer。
# season_phase 只作为切片锁相/兼容参数；运行时风场已经由 C++ SLP/solar
# chain 逐日写入 wind_field_buffer，不再在像素路径叠加独立季节风向偏置。
# 热盐驱动项仍按 cfg 权重叠加。
# 产出：
#   - world.ocean_current_buffer（RG8，重写）
#   - world.ocean_upwelling_buffer（R8，重写）
#   - world.vector_atlas_tex（重编码，包含新 RG = ocean_current）
# 注意：wind_field_buffer 是当前物理风场快照，而不是夏季基线。
func rebake_ocean_currents(map: MapData, world: WorldData, hex_size: float,
		cfg: MapConfig, season_phase: float) -> void:
	if map == null or world == null:
		return
	var total: int = world.derived_size.x * world.derived_size.y
	if total <= 0:
		return
	# [ocean-visual-skip 2026-06-16] flag 关 → 保留 per-cell 物理 solve（写 HexCell），
	# 跳过像素光栅 + 交错重建 + encode（纯视觉）。
	var _ocean_visual: bool = DCFeatureFlags.ocean_current_visual_active()
	if _use_physical_circulation(cfg):
		var saved_world_ext = _world_ext
		_world_ext = null
		_physical_solve_for_phase(map, world, hex_size, cfg, season_phase)
		_world_ext = saved_world_ext
		if _ocean_visual:
			if _pending_wind_buf.is_empty():
				_ensure_pending_wind_size(world)
				_rasterize_wind_slice_from_hex(world, _pending_wind_buf, 0, total)
			_ensure_pending_currents_size(world)
			_rasterize_ocean_current_slice_from_hex(world, _pending_currents_buf, 0, total)
			# 方案 B-1：物理路径下不再生成 ocean_upwelling_buffer
			# （唯一消费者是 F6 调试 shader 通过 _rasterize_upwelling_slice_from_hex 重建，
			#  per-cell SoA / 主视觉路径都不依赖此 buffer）。
			world.wind_field_buffer = _pending_wind_buf
			world.ocean_current_buffer = _pending_currents_buf
			world.ocean_upwelling_buffer = PackedByteArray()
		else:
			world.wind_field_buffer = PackedByteArray()
			world.ocean_current_buffer = PackedByteArray()
			world.ocean_upwelling_buffer = PackedByteArray()
	elif _ocean_visual:
		world.wind_field_buffer = _bake_wind_field(world.world_bounds, world.derived_size, season_phase)
		world.ocean_current_buffer = _bake_ocean_currents(map, hex_size, world, cfg, season_phase)
		# 旧 ny-only 路径保留 upwelling buffer 计算（其它 GD 调用方可能仍读它），
		# 但贴图编码方案 0 一并跳过。
		world.ocean_upwelling_buffer = _bake_ocean_upwelling(map, hex_size, world, cfg, season_phase)
	else:
		world.wind_field_buffer = PackedByteArray()
		world.ocean_current_buffer = PackedByteArray()
		world.ocean_upwelling_buffer = PackedByteArray()
	if _ocean_visual:
		_rebuild_vector_atlas_data_from_buffers(world)
	world.vector_atlas_tex = null
	# 方案 0：upwelling_tex 不在 rebake 路径里烘焙；F6 调试模式再 lazy build。
	world.upwelling_tex = null
	_pending_currents_buf = PackedByteArray()
	_pending_upwelling_buf = PackedByteArray()
	_pending_upwelling_mask = PackedByteArray()
	_pending_upwelling_row_built = PackedByteArray()
	_pending_wind_buf = PackedByteArray()
	_pending_size = Vector2i.ZERO
	_pending_phys_solved_phase = NAN
	_pending_psi_state = null
	_phys_stage = _PHYS_STAGE_NONE
	_phys_psi_iters_done = 0

# ─── SUS 切片烘焙接口（接入点 ① · 任务 3） ────────────────────────────────
#
# 与 rebake_ocean_currents 的关系：
#   - rebake_ocean_currents：一次性烘完整轮（用于 regenerate / 老路径回滚）
#   - bake_ocean_currents_slice + bake_ocean_upwelling_slice + commit/discard：
#     由 SUS OceanCurrentsJob 驱动，按像素区间分多次切片烘完，最后 commit
#     原子替换 world.ocean_current_buffer / ocean_upwelling_buffer / vector_atlas_tex
#     / upwelling_tex 四件产物。
#
# 像素索引语义与 _bake_ocean_currents 一致：idx = y * W + x，区间 [start_idx, end_idx)。

func _ensure_pending_currents_size(world: WorldData) -> void:
	var W := world.derived_size.x
	var H := world.derived_size.y
	var need_size: int = W * H * 2
	if _pending_size != world.derived_size or _pending_currents_buf.size() != need_size:
		_pending_currents_buf = PackedByteArray()
		_pending_currents_buf.resize(need_size)
		_pending_size = world.derived_size
		# L: 仅当 vector_atlas_data 的尺寸与新 derived_size 真正不一致时才失效；
		# _bake_initial_vector_buffers 末尾会把 _pending_size 复位为 ZERO（pending buf 已释放），
		# 但 _vector_atlas_data 仍是上一轮 _rebuild_..._from_buffers 填好的有效 (W,H) 缓存——
		# 此时若一并清掉，commit 就会走 fallback rebuild（620k 循环 ~138-180ms）。
		# 之前的实现犯了这个错，导致每个跨季都触发 cache miss。
		if _vector_atlas_data_size != world.derived_size:
			_vector_atlas_data = PackedByteArray()
			_vector_atlas_data_size = Vector2i.ZERO

func _ensure_pending_upwelling_size(world: WorldData) -> void:
	var W := world.derived_size.x
	var H := world.derived_size.y
	var need_size: int = W * H
	if _pending_upwelling_buf.size() != need_size:
		_pending_upwelling_buf = PackedByteArray()
		_pending_upwelling_buf.resize(need_size)
		_pending_upwelling_mask = PackedByteArray()
		_pending_upwelling_mask.resize(need_size)
		_pending_upwelling_row_built = PackedByteArray()
		_pending_upwelling_row_built.resize(H)

func _ensure_upwelling_rows_mask(world: WorldData, y_start: int, y_end_inclusive: int) -> void:
	# 按行 lazy build mask：仅扫指定行 [y_start, y_end_inclusive] 中尚未构建的部分。
	# 对每一行 yy：若 _pending_upwelling_row_built[yy]==0，则扫该行 W 个像素
	# 写入 _pending_upwelling_mask 与 _pending_upwelling_buf（默认 128），并打标。
	# 同行二次访问立即返回。
	var W := world.derived_size.x
	var H := world.derived_size.y
	if _pending_upwelling_row_built.size() != H:
		return  # 尺寸异常，让上游 ensure_size 兜底
	var height := world.height_buffer
	var hm_W := world.hm_size.x
	var hm_H := world.hm_size.y
	var sea := world.sea_level
	var biome_buf := world.biome_buffer
	var has_biome: bool = biome_buf.size() >= W * H
	var hm_match: bool = (hm_W == W and hm_H == H)
	var ys: int = clampi(y_start, 0, H - 1)
	var ye: int = clampi(y_end_inclusive, 0, H - 1)
	for yy in range(ys, ye + 1):
		if _pending_upwelling_row_built[yy] != 0:
			continue
		var row_base: int = yy * W
		for x in range(W):
			var i: int = row_base + x
			var ocean := false
			if has_biome:
				ocean = _is_water(int(biome_buf[i]))
			elif hm_match:
				ocean = height[i] < sea
			_pending_upwelling_mask[i] = 1 if ocean else 0
			_pending_upwelling_buf[i] = 128  # 默认中性
		_pending_upwelling_row_built[yy] = 1

## 烘焙 ocean currents 在像素区间 [start_idx, end_idx) 上的部分。
## 第一次切片调用时 start_idx 应为 0，phase 在第一次切片时锁定（后续切片不再随
## season_phase 漂移）。返回 { pixels_done, total_pixels }。
func bake_ocean_currents_slice(map: MapData, world: WorldData, hex_size: float,
		cfg: MapConfig, season_phase: float,
		start_idx: int, end_idx: int) -> Dictionary:
	if world == null:
		return { "pixels_done": 0, "total_pixels": 0 }
	_ensure_pending_currents_size(world)
	if start_idx == 0:
		_pending_phase = season_phase
	var W := world.derived_size.x
	var H := world.derived_size.y
	var total: int = W * H
	var s: int = clampi(start_idx, 0, total)
	var e: int = clampi(end_idx, s, total)
	if s >= e:
		return { "pixels_done": 0, "total_pixels": total }

	# Physical Wind & Ocean Circulation 路径：caller（OceanCurrentsJob 或一次性路径）
	# 必须在调本片之前先把求解推进到 _PHYS_STAGE_DONE（通过 _physical_solve_step_one
	# 或 _physical_solve_for_phase）。本片仅做"把 cell.ocean_current 通过
	# pixel_to_cell_lookup 量化进区间 [s, e)"的纯光栅化工作。
	if _use_physical_circulation(cfg):
		_rasterize_ocean_current_slice_from_hex(world, _pending_currents_buf, s, e)
		return { "pixels_done": e - s, "total_pixels": total }

	var origin := world.world_bounds.position
	var size := world.world_bounds.size
	var sea := world.sea_level
	var height := world.height_buffer
	var hm_W := world.hm_size.x
	var hm_H := world.hm_size.y
	var wind_buf := world.wind_field_buffer
	var has_wind: bool = not wind_buf.is_empty() and wind_buf.size() >= W * H * 2
	var thermohaline_w: float = (cfg.THERMOHALINE_WEIGHT if cfg != null else _THERMOHALINE_DEFAULT)
	if cfg != null and not cfg.enable_ocean_heat_transport:
		thermohaline_w = 0.0
	var biome_buf := world.biome_buffer
	var has_biome_buf: bool = biome_buf.size() >= W * H
	var hm_match: bool = (hm_W == W and hm_H == H)
	for idx in range(s, e):
		var y: int = idx / W
		var x: int = idx - y * W
		var ny := float(y) / float(maxi(H - 1, 1))
		var wy_base := origin.y + (float(y) + 0.5) * size.y / float(H)
		var wx_base := origin.x + (float(x) + 0.5) * size.x / float(W)

		var is_ocean := false
		if has_biome_buf:
			is_ocean = _is_water(int(biome_buf[idx]))
		elif hm_match:
			is_ocean = height[idx] < sea
		else:
			var wp := Vector2(wx_base, wy_base)
			var cube_f := _world_to_cube_f(wp, hex_size)
			var rounded := _cube_round(cube_f)
			var c: HexCell = map.get_cell_by_cube(rounded)
			is_ocean = c != null and _is_water(int(c.terrain))

		if not is_ocean:
			_pending_currents_buf[idx * 2] = 128
			_pending_currents_buf[idx * 2 + 1] = 128
			continue

		var wind: Vector2
		if has_wind:
			var wb_idx := idx * 2
			wind = Vector2(
				float(wind_buf[wb_idx]) / 255.0 * 2.0 - 1.0,
				float(wind_buf[wb_idx + 1]) / 255.0 * 2.0 - 1.0
			)
		else:
			wind = Vector2(1.0, 0.0)

		var lat_signed := (ny - 0.5) * 2.0
		var ekman_sign: float = -1.0 if lat_signed < 0.0 else 1.0
		var rot_angle: float = -ekman_sign * EKMAN_DEFLECTION_RAD
		var cur := wind.rotated(rot_angle)

		cur.x += _detail_noise.get_noise_2d(wx_base * 0.6, wy_base * 0.6) * 0.30
		cur.y += _detail_noise.get_noise_2d(wx_base * 0.6 + 91.0, wy_base * 0.6 - 17.0) * 0.30

		if hm_match and x > 0 and x < W - 1 and y > 0 and y < H - 1:
			var hl: float = height[idx - 1]
			var hr: float = height[idx + 1]
			var hu: float = height[idx - W]
			var hd: float = height[idx + W]
			var grad_x := maxf(hl - sea, 0.0) - maxf(hr - sea, 0.0)
			var grad_y := maxf(hu - sea, 0.0) - maxf(hd - sea, 0.0)
			cur.x += grad_x * 4.0
			cur.y += grad_y * 4.0

		var pole_dir_y: float = signf(lat_signed)
		var grad_mag: float = sin(absf(lat_signed) * PI)
		cur.y += pole_dir_y * grad_mag * thermohaline_w

		if cur.length() > 1.0:
			cur = cur.normalized()
		_pending_currents_buf[idx * 2]     = clampi(int(round((cur.x * 0.5 + 0.5) * 255.0)), 0, 255)
		_pending_currents_buf[idx * 2 + 1] = clampi(int(round((cur.y * 0.5 + 0.5) * 255.0)), 0, 255)

	return { "pixels_done": e - s, "total_pixels": total }

## 烘焙 ocean upwelling 在像素区间 [start_idx, end_idx) 上的部分。
## 与 currents 不同：upwelling 主逻辑使用 8 邻域查询，必须先在切片覆盖范围 + 1 行
## padding 上建好 ocean mask + 默认值 128。mask 按行 lazy build，避免首片一次性
## 扫整图（~140ms 摊到所有切片）。已构建过的行直接复用。
func bake_ocean_upwelling_slice(map: MapData, world: WorldData, hex_size: float,
		cfg: MapConfig, season_phase: float,
		start_idx: int, end_idx: int) -> Dictionary:
	if world == null:
		return { "pixels_done": 0, "total_pixels": 0 }
	# 方案 B-1：物理路径下 upwelling buffer 没有消费者，整个切片改成 noop
	# （per-cell SoA / 主视觉路径不读；F6 调试由 lazy bake 单独触发一次）。
	# 旧 ny-only 路径仍保留 lazy-mask 光栅化，向后兼容。
	if _use_physical_circulation(cfg):
		var W_phys := world.derived_size.x
		var H_phys := world.derived_size.y
		return { "pixels_done": end_idx - start_idx, "total_pixels": W_phys * H_phys }
	_ensure_pending_upwelling_size(world)
	if start_idx == 0:
		_pending_phase = season_phase
	var W := world.derived_size.x
	var H := world.derived_size.y
	var total: int = W * H
	var s: int = clampi(start_idx, 0, total)
	var e: int = clampi(end_idx, s, total)
	if s >= e:
		return { "pixels_done": 0, "total_pixels": total }

	# Physical Wind & Ocean Circulation：upwelling 也走 hex → pixel 光栅化路径。
	# 同 currents_slice：caller 必须先把求解推到 _PHYS_STAGE_DONE。本片只光栅化。
	# 旧路径需要的 lazy mask 也跳过——cell.terrain 直接给我们海陆判定。
	if _use_physical_circulation(cfg):
		_rasterize_upwelling_slice_from_hex(world, _pending_upwelling_buf, s, e)
		return { "pixels_done": e - s, "total_pixels": total }

	# 8 邻域查询会读 y±1 行的 mask；这里多 padding 1 行确保查询命中。
	var y_first: int = s / W
	var y_last: int = (e - 1) / W
	_ensure_upwelling_rows_mask(world, y_first - 1, y_last + 1)

	var wind_buf := world.wind_field_buffer
	var has_wind: bool = not wind_buf.is_empty() and wind_buf.size() >= W * H * 2
	var cold_sink_temp: float = (cfg.COLD_SINK_TEMP if cfg != null else -0.05)

	# 行级缓存：对切片覆盖的每一行预算一次。
	var y_start: int = s / W
	var y_end: int = (e - 1) / W
	var row_data: Array = []  # element: { lat_signed, lat_signed_abs, lat_temp,
							  # is_cold_sink, cold_sink_byte, ekman_sign,
							  # rot_angle, near_edge_y }
	row_data.resize(y_end - y_start + 1)
	for yy in range(y_start, y_end + 1):
		var ny := float(yy) / float(maxi(H - 1, 1))
		var lat_signed := (ny - 0.5) * 2.0
		var lat_signed_abs: float = absf(lat_signed)
		var lat_temp: float = DCClimateMath.lat_temp_bell(lat_signed_abs)  # 纬度温度钟形单一来源
		var temp_rel: float = lat_temp - 0.5
		var is_highlat: bool = lat_signed_abs > _UPWELLING_HIGHLAT_ABS
		var is_cold_sink: bool = is_highlat and temp_rel < cold_sink_temp
		var t_cold: float = clampf((cold_sink_temp - temp_rel) / 0.3, 0.0, 1.0) if is_cold_sink else 0.0
		var cold_sink_byte: int = clampi(int(round(128.0 * (1.0 - t_cold))), 0, 128)
		var ekman_sign: float = -1.0 if lat_signed < 0.0 else 1.0
		var rot_angle: float = -ekman_sign * EKMAN_DEFLECTION_RAD
		row_data[yy - y_start] = {
			"is_cold_sink": is_cold_sink,
			"cold_sink_byte": cold_sink_byte,
			"rot_angle": rot_angle,
		}

	for idx in range(s, e):
		var y: int = idx / W
		var x: int = idx - y * W
		# 陆地直接跳过（mask 中 0 表示陆地，buf 已被预填为 128）
		if _pending_upwelling_mask[idx] == 0:
			_pending_upwelling_buf[idx] = 128
			continue
		var rd: Dictionary = row_data[y - y_start]

		# (a) 高纬冷水下沉
		if bool(rd["is_cold_sink"]):
			_pending_upwelling_buf[idx] = int(rd["cold_sink_byte"])
			continue

		# 默认中性
		_pending_upwelling_buf[idx] = 128

		# (b) 沿岸 Ekman 抽吸上升
		if x <= 0 or x >= W - 1 or y <= 0 or y >= H - 1:
			continue
		var nvec := Vector2.ZERO
		var has_coast := false
		for dy_i: int in [-1, 0, 1]:
			for dx_i: int in [-1, 0, 1]:
				if dx_i == 0 and dy_i == 0:
					continue
				var ni: int = (y + dy_i) * W + (x + dx_i)
				if _pending_upwelling_mask[ni] == 0:
					nvec += Vector2(float(dx_i), float(dy_i))
					has_coast = true
		if not has_coast:
			continue
		if nvec.length_squared() < 1e-6:
			continue
		nvec = nvec.normalized()
		if not has_wind:
			continue
		var wb_idx := idx * 2
		var wind := Vector2(
			float(wind_buf[wb_idx]) / 255.0 * 2.0 - 1.0,
			float(wind_buf[wb_idx + 1]) / 255.0 * 2.0 - 1.0
		)
		if wind.length_squared() < 1e-6:
			continue
		wind = wind.normalized()
		var tangent := Vector2(-nvec.y, nvec.x)
		var along: float = absf(wind.dot(tangent))
		if along < _UPWELLING_COAST_TANGENT_MIN:
			continue
		var cur_dir := wind.rotated(rd["rot_angle"] as float)
		var offshore: float = cur_dir.dot(-nvec)
		if offshore <= 0.0:
			continue
		var up: float = clampf(along * offshore, 0.0, 1.0)
		_pending_upwelling_buf[idx] = clampi(int(round(128.0 + 127.0 * up)), 128, 255)

	return { "pixels_done": e - s, "total_pixels": total }

## 切片全部完成后调用：把 _pending_currents_buf / _pending_upwelling_buf
## 原子替换到 world。update_textures 为 true 时同步重编码 vector_atlas_tex /
## upwelling_tex；SUS fast tick 可传 false 避免 GPU 上传毛刺。返回耗时。
##
## upwelling_tex 编码默认 SKIP（方案 0：唯一消费者是 F6 调试 shader 分支，
## 主路径不读）。F6 切到 debug 模式时 main.gd / hex_renderer 会显式调
## `rebake_upwelling_tex_for_debug` lazy bake 一次。
func commit_ocean_buffers(world: WorldData, update_textures: bool = true) -> Dictionary:
	if world == null:
		return {}
	var t := Time.get_ticks_msec()
	world.ocean_current_buffer = _pending_currents_buf
	# 方案 B-1：物理路径下 ocean_upwelling_buffer 不再被消费（per-cell SoA 不依赖它，
	# F6 调试也是直接从 cell.upwelling_strength 重新光栅化），保留赋值仅为旧 ny-only
	# 路径兼容。物理路径下 _pending_upwelling_buf 在 _bake_ocean_upwelling_slice 里
	# 已不再写入，自然是空 PackedByteArray。
	world.ocean_upwelling_buffer = _pending_upwelling_buf
	# Physical Wind & Ocean Circulation：物理化路径在 _physical_solve_for_phase 时已
	# 把 hex → pixel 风场 buffer 写入 _pending_wind_buf，commit 时一并替换 world.wind_field_buffer
	# 让 weather_system advection / shader 都看到新风迹。旧路径 _pending_wind_buf
	# 为空，跳过。
	if not _pending_wind_buf.is_empty():
		world.wind_field_buffer = _pending_wind_buf
	# [ocean-visual-skip 2026-06-16] flag 关 → 不重建/更新 vector_atlas_tex（纯视觉）。
	# 正常路径下 ocean_currents_job 已用 _phys_need_visual=false 提前 round_done、根本
	# 走不到 commit；此处的额外条件是防御性兜底（避免任何其它调用方在 flag 关时重建纹理）。
	if update_textures and DCFeatureFlags.ocean_current_visual_active():
		# I + L: 复用 GPU 句柄 + 持久交错缓冲（方案 A：fast path 永远成立）。
		# 典型 round 收尾下 _vector_atlas_data 已被 pixel slices 同步更新；
		# 缓存未就绪时（首次 commit / regenerate）直接从已 commit 的 buffer 重建
		# 交错缓冲（一次 620k×4 byte 写入，~3ms），然后立即走 fast path，
		# vector_atlas 已退役，正常运行不会进入此防御分支。
		var W: int = world.derived_size.x
		var H: int = world.derived_size.y
		var atlas_size_match: bool = (_vector_atlas_data_size == Vector2i(W, H) \
				and _vector_atlas_data.size() == W * H * 4 \
				and world.vector_atlas_tex != null \
				and world.vector_atlas_tex.get_size() == Vector2(float(W), float(H)))
		if not atlas_size_match:
			# 把 fallback 路径打印出来，方便后续定位"理论上不该走到这里"的边界 case。
			# 已 commit 的 ocean/wind buffer 直接喂 _rebuild_..._from_buffers 把交错缓冲填上；
			# 它内部会按需 resize _vector_atlas_data。
			print("[map_baker] commit_ocean_buffers: vector_atlas_data cache miss (size=%s expected=%s tex=%s) → rebuilding"
					% [str(_vector_atlas_data_size), str(Vector2i(W, H)), str(world.vector_atlas_tex)])
			_rebuild_vector_atlas_data_from_buffers(world)
			if world.vector_atlas_tex == null or world.vector_atlas_tex.get_size() != Vector2(float(W), float(H)):
				# size 不匹配 ImageTexture 必须重建；这一步走 ImageTexture.create_from_image
				# （一次性，无 update 复用），同样耗时但只在 size 变更（regenerate）时发生。
				var img_init := Image.create_from_data(W, H, false, Image.FORMAT_RGBA8, _vector_atlas_data)
				world.vector_atlas_tex = ImageTexture.create_from_image(img_init)
			else:
				var img_init2 := Image.create_from_data(W, H, false, Image.FORMAT_RGBA8, _vector_atlas_data)
				world.vector_atlas_tex.update(img_init2)
		else:
			var img_va := Image.create_from_data(W, H, false, Image.FORMAT_RGBA8, _vector_atlas_data)
			world.vector_atlas_tex.update(img_va)
		# 方案 0：upwelling_tex 默认不在 commit 路径里上传。
		# F6 切到 ocean_current_debug 后会显式调 rebake_upwelling_tex_for_debug。
		# 这里不再调 _encode_upwelling_tex（省 ~10-15ms GPU 上传 + 编码）。
	var t_commit := Time.get_ticks_msec() - t
	# 清空 pending（下一轮重新分配，避免残留半旧数据）
	_pending_currents_buf = PackedByteArray()
	_pending_upwelling_buf = PackedByteArray()
	_pending_upwelling_mask = PackedByteArray()
	_pending_upwelling_row_built = PackedByteArray()
	_pending_size = Vector2i.ZERO
	_pending_phys_solved_phase = NAN
	_pending_psi_state = null
	_pending_wind_buf = PackedByteArray()
	# Phys Solve Sliced：commit 收尾 → 求解状态机一并复位，下一轮从 SLP 起步。
	_phys_stage = _PHYS_STAGE_NONE
	_phys_psi_iters_done = 0
	return { "commit_ms": t_commit }

## 方案 0：F6 切到 ocean_current_debug=true 时调用一次，按需 lazy build upwelling_tex。
## 直接从 per-cell HexCell.upwelling_strength 光栅化（_rasterize_upwelling_slice_from_hex
## 内部读 cell 即可，物理路径下 ocean_upwelling_buffer 已废弃但 hex 字段一直在更新）。
## 返回是否成功；shader 端在 ocean_upwelling_tex 仍为 null 时不会渲染（uniform 默认黑纹理，
## 且 ocean_current_debug=false 分支已是 default 主路径）。
func rebake_upwelling_tex_for_debug(world: WorldData) -> bool:
	if world == null:
		return false
	var W: int = world.derived_size.x
	var H: int = world.derived_size.y
	var n: int = W * H
	if n <= 0:
		return false
	# 本地分配，不污染 _pending_upwelling_buf（commit 路径不再使用此 buffer）。
	var debug_buf: PackedByteArray = PackedByteArray()
	debug_buf.resize(n)
	# 初始填中性 128（陆地默认值），_rasterize_upwelling_slice_from_hex 会按 cell.terrain
	# 判定水陆，水域 cell 写真实 strength，陆地保持 128。
	for i in range(n):
		debug_buf[i] = 128
	_rasterize_upwelling_slice_from_hex(world, debug_buf, 0, n)
	var img := Image.create_from_data(W, H, false, Image.FORMAT_L8, debug_buf)
	if world.upwelling_tex != null and world.upwelling_tex.get_size() == Vector2(float(W), float(H)):
		world.upwelling_tex.update(img)
	else:
		world.upwelling_tex = ImageTexture.create_from_image(img)
	return true

## 丢弃所有 pending 缓冲（地图重生成 / SUS reset_all_progress 调用）。
func discard_ocean_buffers() -> void:
	_pending_currents_buf = PackedByteArray()
	_pending_upwelling_buf = PackedByteArray()
	_pending_upwelling_mask = PackedByteArray()
	_pending_upwelling_row_built = PackedByteArray()
	_pending_size = Vector2i.ZERO
	_pending_phys_solved_phase = NAN
	_pending_psi_state = null
	_pending_wind_buf = PackedByteArray()
	# L: vector atlas 缓存随 reset 失效；下一次 commit 会重新整张拼出来。
	_vector_atlas_data = PackedByteArray()
	_vector_atlas_data_size = Vector2i.ZERO
	# Phys Solve Sliced：丢弃时也复位状态机，避免下一轮在错误阶段恢复。
	_phys_stage = _PHYS_STAGE_NONE
	_phys_psi_iters_done = 0

# 抽出来的单轴 rebake 通用实现：axis ∈ {"cover", "vegetation"}
# 阶段 P 增量路径：weather_system 每日翻 cover 的 cell 通常 < 30 个，旧 fast path
# 仍要扫 614400 像素重写所有 byte（即便 99% 没变化，每天 ~110ms）。改造后：
#   1) 首次：完整重写 buffer（与旧 fast path 一致）+ 用 cell_pixel_lists 的 keys
#      为每个 cell 记录当前 byte 到 _last_*_cell_bytes 快照。
#   2) 后续：遍历 ~2400 个 cell，逐 cell 比对 byte → 不变直接 continue；变了
#      才用 cell_pixel_lists[cell] 批量写入像素列表。典型日 < 5k 像素操作。
#   3) 任何 cell byte 变了才触发 enum_atlas_tex 整张 update（GPU 上传开销不可避免，
#      但驱动层 update 比 create_from_image 仍然快数倍）。
# 与 ice_bake 的 SoA 重构完全同构。fallback 路径仍保留，不破坏旧存档兼容性。
func _rebake_single_axis(map: MapData, world: WorldData, hex_size: float, axis: String) -> void:
	var report_t0_us: int = Time.get_ticks_usec()
	if world == null:
		return
	var target_buf: PackedByteArray
	var fallback_default: int
	match axis:
		"cover":
			if world.cover_buffer.is_empty():
				return
			target_buf = world.cover_buffer
			fallback_default = int(CoverType.CV.NONE)
		"vegetation":
			if world.vegetation_buffer.is_empty():
				return
			target_buf = world.vegetation_buffer
			fallback_default = int(VegetationType.VEG.NONE)
		_:
			return
	var W := world.derived_size.x
	var H := world.derived_size.y
	var pix_count := W * H
	if _try_cpp_enum_axis_patch(map, world, axis, report_t0_us):
		return

	# Fast path：lookup + cell_pixel_lists 都齐全 → 走增量路径
	var has_lookup: bool = world.pixel_to_cell_lookup.size() == pix_count
	var has_cell_lists: bool = not world.cell_pixel_lists.is_empty()
	if has_lookup and has_cell_lists:
		var cache_dict: Dictionary
		var cache_size_ref: Vector2i
		if axis == "cover":
			cache_dict = _last_cover_cell_bytes
			cache_size_ref = _cover_cache_size
		else:
			cache_dict = _last_vegetation_cell_bytes
			cache_size_ref = _vegetation_cache_size

		var cache_valid: bool = (cache_size_ref == Vector2i(W, H) \
				and target_buf.size() == pix_count \
				and not cache_dict.is_empty())

		if not cache_valid:
			# ───── 首次构建：完整 fast path 重写 buffer + 初始化 cell byte 快照 ─────
			var patch_t0_us: int = Time.get_ticks_usec()
			if target_buf.size() != pix_count:
				target_buf.resize(pix_count)
			var lookup_init := world.pixel_to_cell_lookup
			cache_dict = {}
			if axis == "cover":
				for i in range(pix_count):
					var c0: HexCell = lookup_init[i]
					target_buf[i] = (int(c0.cover) if c0 != null else fallback_default) & 0xFF
				# 用 cell_pixel_lists 的 keys 一次性建立 byte 快照（每 cell 只 lookup 一次）
				for cell_key in world.cell_pixel_lists.keys():
					var cc: HexCell = cell_key
					cache_dict[cc] = int(cc.cover) & 0xFF
				_last_cover_cell_bytes = cache_dict
				_cover_cache_size = Vector2i(W, H)
				world.cover_buffer = target_buf
			else:
				for i in range(pix_count):
					var c1: HexCell = lookup_init[i]
					target_buf[i] = (int(c1.vegetation) if c1 != null else fallback_default) & 0xFF
				for cell_key in world.cell_pixel_lists.keys():
					var cv: HexCell = cell_key
					cache_dict[cv] = int(cv.vegetation) & 0xFF
				_last_vegetation_cell_bytes = cache_dict
				_vegetation_cache_size = Vector2i(W, H)
				world.vegetation_buffer = target_buf
			var patch_ms: float = float(Time.get_ticks_usec() - patch_t0_us) / 1000.0
			# vegetation/cover 已由 enum_lut 消费；map-index atlas 不需要上传。
			_record_enum_atlas_upload_report(axis, "lut_only_no_map_index_upload",
				float(Time.get_ticks_usec() - report_t0_us) / 1000.0,
				cache_dict.size(), 0, patch_ms, 0.0, 0.0, false)
			return

		# ───── 增量路径：典型每日 ─────
		# 遍历所有 cell，逐 cell 比对 byte。命中 byte 不变 → continue（0 像素操作）。
		# 变了 → 把 cell_pixel_lists[cell] 的所有像素批量写入 target_buf。
		# vegetation/cover 不再写 map-index atlas；只更新 CPU buffer/cache，LUT 刷新消费这些值。
		var any_dirty: bool = false
		var dirty_cells: int = 0
		var dirty_pixels: int = 0
		var cell_lists: Dictionary = world.cell_pixel_lists
		var patch_t0_us: int = Time.get_ticks_usec()
		if axis == "cover":
			for cell_key in cell_lists.keys():
				var cc2: HexCell = cell_key
				var b: int = int(cc2.cover) & 0xFF
				var prev_b: int = int(cache_dict.get(cc2, -1))
				if b == prev_b:
					continue
				cache_dict[cc2] = b
				any_dirty = true
				dirty_cells += 1
				var pixels: PackedInt32Array = cell_lists[cell_key]
				dirty_pixels += pixels.size()
				for px in pixels:
					target_buf[px] = b
			_last_cover_cell_bytes = cache_dict
			world.cover_buffer = target_buf
		else:
			for cell_key in cell_lists.keys():
				var cv2: HexCell = cell_key
				var b: int = int(cv2.vegetation) & 0xFF
				var prev_b: int = int(cache_dict.get(cv2, -1))
				if b == prev_b:
					continue
				cache_dict[cv2] = b
				any_dirty = true
				dirty_cells += 1
				var pixels: PackedInt32Array = cell_lists[cell_key]
				dirty_pixels += pixels.size()
				for px in pixels:
					target_buf[px] = b
			_last_vegetation_cell_bytes = cache_dict
			world.vegetation_buffer = target_buf
		var buffer_patch_ms: float = float(Time.get_ticks_usec() - patch_t0_us) / 1000.0

		if not any_dirty:
			_record_enum_atlas_upload_report(axis, "skipped_no_dirty",
				float(Time.get_ticks_usec() - report_t0_us) / 1000.0,
				0, 0, buffer_patch_ms, 0.0, 0.0, true)
			return  # 所有 cell byte 都没变 → 连 GPU 上传都跳过
		_record_enum_atlas_upload_report(axis, "lut_only_no_map_index_upload",
			float(Time.get_ticks_usec() - report_t0_us) / 1000.0,
			dirty_cells, dirty_pixels, buffer_patch_ms, 0.0, 0.0, true)
		return

	# Slow fallback：完整重跑 warp + cube_round（保留兼容性，正常不会走到）
	if _warp_noise_lo == null:
		_init_noise(world.bake_seed)
	var origin := world.world_bounds.position
	var size := world.world_bounds.size
	var step_x := size.x / float(W)
	var step_y := size.y / float(H)
	var warp_scale := hex_size * WARP_AMP

	var patch_t0_us: int = Time.get_ticks_usec()
	for y in range(H):
		var wy_base := origin.y + (float(y) + 0.5) * step_y
		var row := y * W
		for x in range(W):
			var wx_base := origin.x + (float(x) + 0.5) * step_x
			var warp_x := _warp_noise_lo.get_noise_2d(wx_base, wy_base)
			var warp_y := _warp_noise_lo.get_noise_2d(wx_base + 31.7, wy_base - 17.3)
			var hi_x := _warp_noise_hi.get_noise_2d(wx_base + 91.1, wy_base + 53.7) * WARP_HIGH_AMP_RATIO
			var hi_y := _warp_noise_hi.get_noise_2d(wx_base - 41.5, wy_base + 23.9) * WARP_HIGH_AMP_RATIO
			var wx := wx_base + (warp_x + hi_x) * warp_scale
			var wy := wy_base + (warp_y + hi_y) * warp_scale
			var cube_f := _world_to_cube_f(Vector2(wx, wy), hex_size)
			var rounded := _cube_round(cube_f)
			var self_cell: HexCell = map.get_cell_by_cube(rounded)
			var v: int
			if axis == "cover":
				v = int(self_cell.cover) if self_cell != null else int(CoverType.CV.NONE)
			else:
				v = int(self_cell.vegetation) if self_cell != null else int(VegetationType.VEG.NONE)
			target_buf[row + x] = v & 0xFF
	var buffer_patch_ms: float = float(Time.get_ticks_usec() - patch_t0_us) / 1000.0
	if axis == "cover":
		world.cover_buffer = target_buf
	else:
		world.vegetation_buffer = target_buf
	prewarm_dynamic_axis_caches(map, world)
	_record_enum_atlas_upload_report(axis, "lut_only_no_map_index_upload",
		float(Time.get_ticks_usec() - report_t0_us) / 1000.0,
		world.cell_pixel_lists.size(), 0, buffer_patch_ms, 0.0, 0.0, false)

# Milestone 2 / J 增量：季节切换时同步重烘 biome / vegetation / cover 三张 R8 纹理。
# height / moisture / flow / latitude / wind / ocean / volcano 全部不动。
#
# 旧路径（130ms / season）：完整 _rewrite_axis_buffers（620k 像素 × 3 byte）+
# _encode_enum_atlas（620k 像素 × 3 byte 交错 + Image.create + tex.update）。
#
# J 新路径：与 _rebake_single_axis 同结构，把 biome / veg / cover 3 轴的 sig 缓存
# 一起遍历。多数季节切换只翻少数边界 cell 的 terrain，veg / cover 在前序 stage 已
# 部分更新，sig 不变直接跳过；变了才把 cell.pixel 列表批量写到 buf + 直写
# `_enum_atlas_data` 对应通道。最后用 cached interleaved data 做 tex.update()。
func rebake_biome_axes_only(map: MapData, world: WorldData, hex_size: float) -> void:
	var report_t0_us: int = Time.get_ticks_usec()
	if world == null or world.biome_buffer.is_empty():
		return
	if _warp_noise_lo == null:
		_init_noise(world.bake_seed)
	var W := world.derived_size.x
	var H := world.derived_size.y
	var pix_count := W * H
	if _try_cpp_enum_axes_patch(map, world, report_t0_us):
		return
	var has_lookup: bool = world.pixel_to_cell_lookup.size() == pix_count
	var has_cell_lists: bool = not world.cell_pixel_lists.is_empty()

	# Cache validity：3 轴 sig + interleaved data 都得齐才走增量。
	var cache_valid: bool = (has_lookup \
			and has_cell_lists \
			and _biome_cache_size == Vector2i(W, H) \
			and _vegetation_cache_size == Vector2i(W, H) \
			and _cover_cache_size == Vector2i(W, H) \
			and _enum_atlas_data_size == Vector2i(W, H) \
			and _enum_atlas_data.size() == pix_count * 4 \
			and not _last_biome_cell_bytes.is_empty() \
			and not _last_vegetation_cell_bytes.is_empty() \
			and not _last_cover_cell_bytes.is_empty() \
			and world.biome_buffer.size() == pix_count \
			and world.vegetation_buffer.size() == pix_count \
			and world.cover_buffer.size() == pix_count)

	if not cache_valid:
		# Fallback：完整路径（首次 / 任意缓存失效）。同步顺便把 3 轴 sig + interleaved data 都建好。
		var patch_t0_us: int = Time.get_ticks_usec()
		_rewrite_axis_buffers(map, hex_size, world)
		var buffer_patch_ms: float = float(Time.get_ticks_usec() - patch_t0_us) / 1000.0
		var upload_t0_us: int = Time.get_ticks_usec()
		world.enum_atlas_tex = _encode_enum_atlas(
			world.biome_buffer, world.vegetation_buffer, world.cover_buffer,
			world.derived_size, world.enum_atlas_tex, world
		)
		var upload_ms: float = float(Time.get_ticks_usec() - upload_t0_us) / 1000.0
		prewarm_dynamic_axis_caches(map, world)
		_record_enum_atlas_upload_report("biome", "fallback_full_rewrite",
			float(Time.get_ticks_usec() - report_t0_us) / 1000.0,
			world.cell_pixel_lists.size(), pix_count, buffer_patch_ms, 0.0, upload_ms, false)
		return

	# 增量路径：遍历 ~2400 cell，逐 cell 比 3 轴 byte。
	var biome_buf := world.biome_buffer
	var veg_buf := world.vegetation_buffer
	var cover_buf := world.cover_buffer
	var cell_lists: Dictionary = world.cell_pixel_lists
	var biome_dirty: int = 0
	var veg_dirty: int = 0
	var cover_dirty: int = 0
	var dirty_pixels: int = 0
	var patch_t0_us: int = Time.get_ticks_usec()
	for cell_key in cell_lists.keys():
		var cell: HexCell = cell_key
		if cell == null:
			continue
		var b_t: int = int(cell.terrain) & 0xFF
		var b_v: int = int(cell.vegetation) & 0xFF
		var b_c: int = int(cell.cover) & 0xFF
		var prev_t: int = int(_last_biome_cell_bytes.get(cell, -1))
		var prev_v: int = int(_last_vegetation_cell_bytes.get(cell, -1))
		var prev_c: int = int(_last_cover_cell_bytes.get(cell, -1))
		if b_t == prev_t and b_v == prev_v and b_c == prev_c:
			continue
		var pixels: PackedInt32Array = cell_lists[cell_key]
		if b_t != prev_t:
			_last_biome_cell_bytes[cell] = b_t
			biome_dirty += 1
			dirty_pixels += pixels.size()
			for px in pixels:
				biome_buf[px] = b_t
				_enum_atlas_data[px * 4] = b_t
		if b_v != prev_v:
			_last_vegetation_cell_bytes[cell] = b_v
			veg_dirty += 1
			dirty_pixels += pixels.size()
			for px in pixels:
				veg_buf[px] = b_v
		if b_c != prev_c:
			_last_cover_cell_bytes[cell] = b_c
			cover_dirty += 1
			dirty_pixels += pixels.size()
			for px in pixels:
				cover_buf[px] = b_c
	world.biome_buffer = biome_buf
	world.vegetation_buffer = veg_buf
	world.cover_buffer = cover_buf
	var buffer_patch_ms: float = float(Time.get_ticks_usec() - patch_t0_us) / 1000.0
	var dirty_cells: int = biome_dirty + veg_dirty + cover_dirty

	if dirty_cells == 0:
		_record_enum_atlas_upload_report("biome", "skipped_no_dirty",
			float(Time.get_ticks_usec() - report_t0_us) / 1000.0,
			0, 0, buffer_patch_ms, 0.0, 0.0, true)
		return  # 全 3 轴 byte 都没变 → 连 GPU 上传都跳过
	if biome_dirty == 0:
		_record_enum_atlas_upload_report("biome", "lut_only_no_map_index_upload",
			float(Time.get_ticks_usec() - report_t0_us) / 1000.0,
			dirty_cells, dirty_pixels, buffer_patch_ms, 0.0, 0.0, true)
		return

	# tex.update via cached map-index data；只在 biome/R 通道变化时上传。
	if world.enum_atlas_tex != null and world.enum_atlas_tex.get_size() == Vector2(float(W), float(H)):
		var image_t0_us: int = Time.get_ticks_usec()
		var img := Image.create_from_data(W, H, false, Image.FORMAT_RGBA8, _enum_atlas_data)
		var image_ms: float = float(Time.get_ticks_usec() - image_t0_us) / 1000.0
		var upload_t0_us: int = Time.get_ticks_usec()
		world.enum_atlas_tex.update(img)
		var upload_ms: float = float(Time.get_ticks_usec() - upload_t0_us) / 1000.0
		_record_enum_atlas_upload_report("biome", "cached_full_update",
			float(Time.get_ticks_usec() - report_t0_us) / 1000.0,
			dirty_cells, dirty_pixels, buffer_patch_ms, image_ms, upload_ms, true)
	else:
		var upload_t0_us: int = Time.get_ticks_usec()
		world.enum_atlas_tex = _encode_enum_atlas(
			world.biome_buffer, world.vegetation_buffer, world.cover_buffer,
			world.derived_size, world.enum_atlas_tex, world
		)
		var upload_ms: float = float(Time.get_ticks_usec() - upload_t0_us) / 1000.0
		_record_enum_atlas_upload_report("biome", "fallback_full_rewrite",
			float(Time.get_ticks_usec() - report_t0_us) / 1000.0,
			dirty_cells, dirty_pixels, buffer_patch_ms, 0.0, upload_ms, false)

# 重写 biome / vegetation / cover 三个 buffer，但保持 height/moisture/flow 不动
func _rewrite_axis_buffers(map: MapData, hex_size: float, world: WorldData) -> void:
	var W := world.derived_size.x
	var H := world.derived_size.y
	var pix_count := W * H
	var biome_buf := world.biome_buffer
	var veg_buf := world.vegetation_buffer
	var cover_buf := world.cover_buffer
	if veg_buf.size() != pix_count:
		veg_buf.resize(pix_count)
	if cover_buf.size() != pix_count:
		cover_buf.resize(pix_count)
	if biome_buf.size() != pix_count:
		biome_buf.resize(pix_count)

	# v9.perf：fast path → 走 pixel_to_cell_lookup，避免 78 万次 noise + cube_round
	if world.pixel_to_cell_lookup.size() == pix_count:
		var lookup := world.pixel_to_cell_lookup
		for i in range(pix_count):
			var c: HexCell = lookup[i]
			if c != null:
				biome_buf[i] = int(c.terrain) & 0xFF
				veg_buf[i] = int(c.vegetation) & 0xFF
				cover_buf[i] = int(c.cover) & 0xFF
			else:
				biome_buf[i] = int(TerrainType.TERRAIN.OCEAN) & 0xFF
				veg_buf[i] = int(VegetationType.VEG.NONE) & 0xFF
				cover_buf[i] = int(CoverType.CV.NONE) & 0xFF
		world.biome_buffer = biome_buf
		world.vegetation_buffer = veg_buf
		world.cover_buffer = cover_buf
		return

	# Slow fallback：完整重跑 warp + cube_round（兼容旧路径）
	var origin := world.world_bounds.position
	var size := world.world_bounds.size
	var step_x := size.x / float(W)
	var step_y := size.y / float(H)
	var warp_scale := hex_size * WARP_AMP

	for y in range(H):
		var wy_base := origin.y + (float(y) + 0.5) * step_y
		var row := y * W
		for x in range(W):
			var wx_base := origin.x + (float(x) + 0.5) * step_x
			var warp_x := _warp_noise_lo.get_noise_2d(wx_base, wy_base)
			var warp_y := _warp_noise_lo.get_noise_2d(wx_base + 31.7, wy_base - 17.3)
			var hi_x := _warp_noise_hi.get_noise_2d(wx_base + 91.1, wy_base + 53.7) * WARP_HIGH_AMP_RATIO
			var hi_y := _warp_noise_hi.get_noise_2d(wx_base - 41.5, wy_base + 23.9) * WARP_HIGH_AMP_RATIO
			var wx := wx_base + (warp_x + hi_x) * warp_scale
			var wy := wy_base + (warp_y + hi_y) * warp_scale
			var cube_f := _world_to_cube_f(Vector2(wx, wy), hex_size)
			var rounded := _cube_round(cube_f)
			var self_cell: HexCell = map.get_cell_by_cube(rounded)
			var terrain_self: int = int(self_cell.terrain) if self_cell != null else int(TerrainType.TERRAIN.OCEAN)
			var veg_self: int = int(self_cell.vegetation) if self_cell != null else int(VegetationType.VEG.NONE)
			var cover_self: int = int(self_cell.cover) if self_cell != null else int(CoverType.CV.NONE)
			var idx := row + x
			biome_buf[idx] = terrain_self & 0xFF
			veg_buf[idx] = veg_self & 0xFF
			cover_buf[idx] = cover_self & 0xFF
	world.biome_buffer = biome_buf
	world.vegetation_buffer = veg_buf
	world.cover_buffer = cover_buf

# ─── 内部：分辨率 / 噪声初始化 ──────────────────────────────────────────

func _resolve_hm_size(bounds: Rect2) -> Vector2i:
	# 移动端走 512，桌面走 1024。详见 HM_MAX_DIM_DESKTOP/MOBILE 注释。
	var dim_max: int = _hm_max_dim()
	if bounds.size.x < 0.01 or bounds.size.y < 0.01:
		return Vector2i(dim_max, dim_max)
	var aspect := bounds.size.x / bounds.size.y
	var w: int
	var h: int
	if aspect >= 1.0:
		w = dim_max
		h = int(round(float(dim_max) / aspect))
	else:
		h = dim_max
		w = int(round(float(dim_max) * aspect))
	w = (w / 2) * 2
	h = (h / 2) * 2
	return Vector2i(maxi(w, 256), maxi(h, 256))

func _init_noise(seed_val: int) -> void:
	_warp_noise_lo = FastNoiseLite.new()
	_warp_noise_lo.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_warp_noise_lo.seed = seed_val + 71
	_warp_noise_lo.frequency = WARP_FREQ
	_warp_noise_lo.fractal_type = FastNoiseLite.FRACTAL_FBM
	_warp_noise_lo.fractal_octaves = 3

	_warp_noise_hi = FastNoiseLite.new()
	_warp_noise_hi.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_warp_noise_hi.seed = seed_val + 233
	_warp_noise_hi.frequency = WARP_FREQ * WARP_HIGH_FREQ_MUL
	_warp_noise_hi.fractal_type = FastNoiseLite.FRACTAL_FBM
	_warp_noise_hi.fractal_octaves = 3

	_detail_noise = FastNoiseLite.new()
	_detail_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_detail_noise.seed = seed_val + 503
	_detail_noise.frequency = DETAIL_FREQ_BASE
	_detail_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_detail_noise.fractal_octaves = 4

	_ridge_noise = FastNoiseLite.new()
	_ridge_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_ridge_noise.seed = seed_val + 977
	_ridge_noise.frequency = DETAIL_FREQ_BASE * 2.0
	_ridge_noise.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	_ridge_noise.fractal_octaves = 4

# ─── 核心：一次循环同时产出 height / biome / moisture ────────────────────

func _bake_height_biome_moisture(
	map: MapData,
	hex_size: float,
	world: WorldData,
	height_buf: PackedFloat32Array,
	biome_buf: PackedByteArray,
	moist_buf: PackedFloat32Array,
	veg_buf: PackedByteArray,
	cover_buf: PackedByteArray
) -> void:
	var W := world.hm_size.x
	var H := world.hm_size.y
	var origin := world.world_bounds.position
	var size := world.world_bounds.size
	var step_x := size.x / float(W)
	var step_y := size.y / float(H)
	var warp_scale := hex_size * WARP_AMP

	# v9.perf：建立 pixel→HexCell lookup，让后续 rebake_*_only / rebake_biome_axes_only
	# 不再需要重跑 noise + cube_round。这里只是 W*H 次引用赋值，开销 ~0
	var pix_count := W * H
	var lookup: Array = []
	lookup.resize(pix_count)
	world.pixel_to_cell_lookup = lookup

	# 阶段 P：桶式收集每个 cell 覆盖的像素 index，循环结束后批量打包成 PackedInt32Array。
	# 与 lookup 同源，零额外的 cube_round / noise 计算开销。
	# 用 Array 收集再 append_array 一次性 memcpy（比逐个 push_back 快一个数量级）。
	var cell_pixel_buckets: Dictionary = {}  # HexCell → Array[int]

	for y in range(H):
		var wy_base := origin.y + (float(y) + 0.5) * step_y
		var row := y * W
		for x in range(W):
			var wx_base := origin.x + (float(x) + 0.5) * step_x

			# 1. Warp（双频，让 hex 边界变弯曲 + 犬牙交错）
			var warp_x := _warp_noise_lo.get_noise_2d(wx_base, wy_base)
			var warp_y := _warp_noise_lo.get_noise_2d(wx_base + 31.7, wy_base - 17.3)
			var hi_x := _warp_noise_hi.get_noise_2d(wx_base + 91.1, wy_base + 53.7) * WARP_HIGH_AMP_RATIO
			var hi_y := _warp_noise_hi.get_noise_2d(wx_base - 41.5, wy_base + 23.9) * WARP_HIGH_AMP_RATIO
			var wx := wx_base + (warp_x + hi_x) * warp_scale
			var wy := wy_base + (warp_y + hi_y) * warp_scale

			# 2. Cube 归属
			var cube_f := _world_to_cube_f(Vector2(wx, wy), hex_size)
			var rounded := _cube_round(cube_f)
			var self_cell: HexCell = map.get_cell_by_cube(rounded)

			# 3. 找最近的 sextant 邻居（barycentric 用）
			var self_center := HexUtils.cube_to_world(rounded.x, rounded.y, hex_size)
			var local := Vector2(wx - self_center.x, wy - self_center.y) / hex_size
			var angle := atan2(local.y, local.x)
			var sextant: int = int(floor(fposmod((angle + PI / 6.0) / (PI / 3.0), 6.0)))
			var nb1_dir := _neighbor_dir(sextant)
			var nb2_dir := _neighbor_dir((sextant + 1) % 6)
			var nb1_cube := Vector3i(rounded.x + nb1_dir.x, rounded.y + nb1_dir.y, rounded.z + nb1_dir.z)
			var nb2_cube := Vector3i(rounded.x + nb2_dir.x, rounded.y + nb2_dir.y, rounded.z + nb2_dir.z)
			var nb1_cell: HexCell = map.get_cell_by_cube(nb1_cube)
			var nb2_cell: HexCell = map.get_cell_by_cube(nb2_cube)

			# 4. Barycentric 权重（self + 2 邻居）
			var nb1_center: Vector2 = HexUtils.cube_to_world(nb1_cube.x, nb1_cube.y, hex_size)
			var nb2_center: Vector2 = HexUtils.cube_to_world(nb2_cube.x, nb2_cube.y, hex_size)
			var w_self: float
			var w_nb1: float
			var w_nb2: float
			var bary := _barycentric(Vector2(wx, wy), self_center, nb1_center, nb2_center)
			w_self = bary.x
			w_nb1 = bary.y
			w_nb2 = bary.z

			# 5. 取 elevation / moisture / terrain
			var elev_self: float = self_cell.elevation if self_cell != null else 0.0
			var elev_nb1: float = nb1_cell.elevation if nb1_cell != null else elev_self
			var elev_nb2: float = nb2_cell.elevation if nb2_cell != null else elev_self
			var moist_self: float = self_cell.moisture if self_cell != null else 0.5
			var moist_nb1: float = nb1_cell.moisture if nb1_cell != null else moist_self
			var moist_nb2: float = nb2_cell.moisture if nb2_cell != null else moist_self
			var terrain_self: int = int(self_cell.terrain) if self_cell != null else int(TerrainType.TERRAIN.OCEAN)
			# Milestone 2：同 cube_round → 同源拿 vegetation / cover 三轴。
			# self_cell.vegetation / cover 在 MapGenerator._sync_axes_for_map 中已经派生齐全。
			var veg_self: int = int(self_cell.vegetation) if self_cell != null else int(VegetationType.VEG.NONE)
			var cover_self: int = int(self_cell.cover) if self_cell != null else int(CoverType.CV.NONE)

			# 6. Barycentric 插值 → 平滑 elevation/moisture
			var elev_blend := elev_self * w_self + elev_nb1 * w_nb1 + elev_nb2 * w_nb2
			var moist_blend := moist_self * w_self + moist_nb1 * w_nb1 + moist_nb2 * w_nb2

			# 7. 在陆地上叠 per-biome detail noise
			var elev_final := elev_blend
			if terrain_self != int(TerrainType.TERRAIN.OCEAN) and terrain_self != int(TerrainType.TERRAIN.COAST):
				var d := _detail_noise.get_noise_2d(wx_base, wy_base) * 0.5  # [-0.25, 0.25] (rough)
				if terrain_self == int(TerrainType.TERRAIN.MOUNTAIN):
					var ridge := (_ridge_noise.get_noise_2d(wx_base, wy_base) + 1.0) * 0.5
					elev_final = elev_blend + ridge * MOUNTAIN_RIDGE_AMP + d * 0.4 * HILL_AMP
				elif terrain_self == int(TerrainType.TERRAIN.HILL):
					elev_final = elev_blend + d * HILL_AMP * 0.8 + (_ridge_noise.get_noise_2d(wx_base, wy_base) + 1.0) * 0.5 * HILL_AMP * 0.5
				else:
					elev_final = elev_blend + d * PLAIN_AMP

			var idx := row + x
			height_buf[idx] = clampf(elev_final, 0.0, 1.0)
			biome_buf[idx] = terrain_self & 0xFF
			moist_buf[idx] = clampf(moist_blend, 0.0, 1.0)
			veg_buf[idx] = veg_self & 0xFF
			cover_buf[idx] = cover_self & 0xFF
			# v9.perf：缓存 cell 引用，rebake 时直接 lookup[idx].cover/vegetation
			lookup[idx] = self_cell
			# 阶段 P：同步把该像素 index 收进 cell 桶（仅非空 cell，map 外 None 跳过）
			if self_cell != null:
				if not cell_pixel_buckets.has(self_cell):
					cell_pixel_buckets[self_cell] = []
				(cell_pixel_buckets[self_cell] as Array).push_back(idx)

	# 阶段 P：把桶批量打包成 PackedInt32Array（一次 memcpy，避开 push_back 的反复扩容）。
	# 这就是 rebake_cover_tex_only / rebake_vegetation_tex_only 增量路径的核心反向索引。
	var cell_pixel_lists: Dictionary = {}
	for cell_key in cell_pixel_buckets.keys():
		var packed := PackedInt32Array()
		packed.append_array(cell_pixel_buckets[cell_key] as Array)
		cell_pixel_lists[cell_key] = packed
	world.cell_pixel_lists = cell_pixel_lists

	# P1：同源构建 SoA 镜像（CSR 布局），给 dynamic_visual_atlas 的
	# `_pack_csr_for_cells` fast path 用。Dict 路径保留（finalize/rebake 仍按
	# cell_key 查），SoA 路径只追加，不替换。
	# 长度 N = map 总 cell 数；cell.index 作为 idx 直接 O(1) 查 first_px / px_count。
	var n_cells_csr: int = map.cell_count()
	var first_px_arr: PackedInt32Array = PackedInt32Array(); first_px_arr.resize(n_cells_csr)
	var px_count_arr: PackedInt32Array = PackedInt32Array(); px_count_arr.resize(n_cells_csr)
	# 默认 -1 = 该 idx 无像素（map 外的 hex 占位 / 空 cell）。
	for _ic in range(n_cells_csr):
		first_px_arr[_ic] = -1
		px_count_arr[_ic] = 0
	# 先估算 flat 总长（O(N) 遍历桶）—— 一次性 resize，避免增量扩容的 CoW 拷贝。
	var total_px: int = 0
	for cell_key in cell_pixel_buckets.keys():
		total_px += (cell_pixel_buckets[cell_key] as Array).size()
	var flat_arr: PackedInt32Array = PackedInt32Array(); flat_arr.resize(total_px)
	# 第二次遍历：按 cell.index 升序（map.all_cells() 即按 idx 顺序）填 flat。
	# 这样 cells_subset 是 cells 序列对应 cell.index 的连续段时（很少），SoA 仍可
	# 按 idx 切片读出（4 phase 不要求顺序连续）。
	var flat_w_csr: int = 0
	for _cell_iter in map.all_cells():
		if _cell_iter == null:
			continue
		var _ci_idx: int = int(_cell_iter.index)
		if _ci_idx < 0 or _ci_idx >= n_cells_csr:
			continue
		if not cell_pixel_buckets.has(_cell_iter):
			# 该 cell 无任何像素（map 外或纯逻辑 hex）—— first_px = -1，count = 0
			continue
		var _bucket: Array = cell_pixel_buckets[_cell_iter] as Array
		var _bn: int = _bucket.size()
		first_px_arr[_ci_idx] = flat_w_csr
		px_count_arr[_ci_idx] = _bn
		for _bi in range(_bn):
			flat_arr[flat_w_csr + _bi] = int(_bucket[_bi])
		flat_w_csr += _bn
	# 严格相等的一致性检查：flat_w_csr 必须 == total_px。否则 cell_iter 漏了某个
	# 在桶里的 cell（说明 map.all_cells() 与 cell_pixel_buckets 的 keys 不同源），
	# 此时 SoA 不安全直接使用。这里只校验，不抛错；上层走 Dict fallback 即可。
	# 如果不等，把 flat_arr resize 到实际写入长度，避免末尾留 0。
	if flat_w_csr != total_px:
		flat_arr.resize(flat_w_csr)
	world.cell_first_px_arr = first_px_arr
	world.cell_px_count_arr = px_count_arr
	world.flat_px_indices_arr = flat_arr

# ─── Hex 工具 ─────────────────────────────────────────────────────────────

func _world_to_cube_f(pos: Vector2, size: float) -> Vector3:
	var q_f := (sqrt(3.0) / 3.0 * pos.x - (1.0 / 3.0) * pos.y) / size
	var r_f := (2.0 / 3.0 * pos.y) / size
	return Vector3(q_f, r_f, -q_f - r_f)

func _cube_round(c: Vector3) -> Vector3i:
	var rq: float = round(c.x)
	var rr: float = round(c.y)
	var rs: float = round(c.z)
	var dq: float = absf(rq - c.x)
	var dr: float = absf(rr - c.y)
	var ds: float = absf(rs - c.z)
	if dq > dr and dq > ds:
		rq = -rr - rs
	elif dr > ds:
		rr = -rq - rs
	else:
		rs = -rq - rr
	return Vector3i(int(rq), int(rr), int(rs))

func _neighbor_dir(sextant: int) -> Vector3i:
	# 与 hex_utils.gd 中 CUBE_DIRECTIONS 一致：0=E, 1=NE, 2=NW, 3=W, 4=SW, 5=SE
	# 这里我们按 atan2 角度 sextant 编号（0=E, 1=SE, 2=SW, 3=W, 4=NW, 5=NE）
	match sextant:
		0: return Vector3i(1, 0, -1)   # E
		1: return Vector3i(0, 1, -1)   # SE
		2: return Vector3i(-1, 1, 0)   # SW
		3: return Vector3i(-1, 0, 1)   # W
		4: return Vector3i(0, -1, 1)   # NW
		_: return Vector3i(1, -1, 0)   # NE

func _barycentric(p: Vector2, a: Vector2, b: Vector2, c: Vector2) -> Vector3:
	var v0 := b - a
	var v1 := c - a
	var v2 := p - a
	var d00 := v0.dot(v0)
	var d01 := v0.dot(v1)
	var d11 := v1.dot(v1)
	var d20 := v2.dot(v0)
	var d21 := v2.dot(v1)
	var denom := d00 * d11 - d01 * d01
	if absf(denom) < 0.000001:
		return Vector3(1.0, 0.0, 0.0)
	var inv := 1.0 / denom
	var v_b := (d11 * d20 - d01 * d21) * inv
	var v_c := (d00 * d21 - d01 * d20) * inv
	var v_a := 1.0 - v_b - v_c
	# Clamp 到三角形内（防 warp 偶尔把 p 推到三角形外产生负权）
	v_a = maxf(v_a, 0.0)
	v_b = maxf(v_b, 0.0)
	v_c = maxf(v_c, 0.0)
	var sum := v_a + v_b + v_c
	if sum < 0.0001:
		return Vector3(1.0, 0.0, 0.0)
	return Vector3(v_a / sum, v_b / sum, v_c / sum)

# ─── 轻度侵蚀（仅做边界自然平滑） ────────────────────────────────────────

func _hydraulic_erosion(height: PackedFloat32Array, flow_acc: PackedFloat32Array, size: Vector2i) -> void:
	var W := size.x
	var H := size.y
	var num_drops := EROSION_DROPS
	var max_steps := EROSION_MAX_STEPS
	var inertia := EROSION_INERTIA
	var capacity_factor := EROSION_CAPACITY_FACTOR
	var min_capacity := EROSION_MIN_CAPACITY
	var deposit_speed := EROSION_DEPOSIT_SPEED
	var erode_speed := EROSION_ERODE_SPEED
	var evaporation := EROSION_EVAPORATION
	var gravity := EROSION_GRAVITY
	var brush_radius := EROSION_RADIUS

	if num_drops <= 0:
		return

	# Brush kernel
	var brush_dx := PackedInt32Array()
	var brush_dy := PackedInt32Array()
	var brush_w := PackedFloat32Array()
	var brush_count := 0
	var sum_w := 0.0
	var br_sq := brush_radius * brush_radius
	for dy in range(-brush_radius, brush_radius + 1):
		for dx in range(-brush_radius, brush_radius + 1):
			var d_sq := dx * dx + dy * dy
			if d_sq > br_sq:
				continue
			var w := 1.0 - sqrt(float(d_sq)) / float(brush_radius)
			brush_dx.append(dx)
			brush_dy.append(dy)
			brush_w.append(w)
			sum_w += w
			brush_count += 1
	if sum_w > 0.0:
		var inv_sum := 1.0 / sum_w
		for i in range(brush_count):
			brush_w[i] = brush_w[i] * inv_sum

	var W_f := float(W)
	var H_f := float(H)

	for drop_idx in range(num_drops):
		var pos_x := _rng.randf_range(1.0, W_f - 2.0)
		var pos_y := _rng.randf_range(1.0, H_f - 2.0)
		var dir_x := 0.0
		var dir_y := 0.0
		var speed := 1.0
		var water := 1.0
		var sediment := 0.0

		for step in range(max_steps):
			var node_x := int(floor(pos_x))
			var node_y := int(floor(pos_y))
			if node_x < 0 or node_x >= W - 1 or node_y < 0 or node_y >= H - 1:
				break
			var cell_offset_x := pos_x - float(node_x)
			var cell_offset_y := pos_y - float(node_y)
			var one_minus_x := 1.0 - cell_offset_x
			var one_minus_y := 1.0 - cell_offset_y

			var idx_00 := node_y * W + node_x
			var idx_10 := idx_00 + 1
			var idx_01 := idx_00 + W
			var idx_11 := idx_01 + 1

			var h00 := height[idx_00]
			var h10 := height[idx_10]
			var h01 := height[idx_01]
			var h11 := height[idx_11]

			var h_old := h00 * one_minus_x * one_minus_y \
					+ h10 * cell_offset_x * one_minus_y \
					+ h01 * one_minus_x * cell_offset_y \
					+ h11 * cell_offset_x * cell_offset_y
			var grad_x := (h10 - h00) * one_minus_y + (h11 - h01) * cell_offset_y
			var grad_y := (h01 - h00) * one_minus_x + (h11 - h10) * cell_offset_x

			dir_x = dir_x * inertia - grad_x * (1.0 - inertia)
			dir_y = dir_y * inertia - grad_y * (1.0 - inertia)
			var dir_len_sq := dir_x * dir_x + dir_y * dir_y
			if dir_len_sq < 0.000001:
				var ang := _rng.randf_range(0.0, TAU)
				dir_x = cos(ang)
				dir_y = sin(ang)
			else:
				var inv_len := 1.0 / sqrt(dir_len_sq)
				dir_x *= inv_len
				dir_y *= inv_len

			var new_pos_x := pos_x + dir_x
			var new_pos_y := pos_y + dir_y
			if new_pos_x < 1.0 or new_pos_x >= W_f - 1.0 or new_pos_y < 1.0 or new_pos_y >= H_f - 1.0:
				if sediment > 0.0:
					height[idx_00] += sediment * one_minus_x * one_minus_y
					height[idx_10] += sediment * cell_offset_x * one_minus_y
					height[idx_01] += sediment * one_minus_x * cell_offset_y
					height[idx_11] += sediment * cell_offset_x * cell_offset_y
				break

			var nnx := int(floor(new_pos_x))
			var nny := int(floor(new_pos_y))
			var ncx := new_pos_x - float(nnx)
			var ncy := new_pos_y - float(nny)
			var nidx00 := nny * W + nnx
			var h_new := height[nidx00] * (1.0 - ncx) * (1.0 - ncy) \
					+ height[nidx00 + 1] * ncx * (1.0 - ncy) \
					+ height[nidx00 + W] * (1.0 - ncx) * ncy \
					+ height[nidx00 + W + 1] * ncx * ncy
			var delta_h := h_new - h_old
			var capacity := maxf(-delta_h, min_capacity) * speed * water * capacity_factor

			if sediment > capacity or delta_h > 0.0:
				var deposit_amt: float
				if delta_h > 0.0:
					deposit_amt = minf(delta_h, sediment)
				else:
					deposit_amt = (sediment - capacity) * deposit_speed
				sediment -= deposit_amt
				height[idx_00] += deposit_amt * one_minus_x * one_minus_y
				height[idx_10] += deposit_amt * cell_offset_x * one_minus_y
				height[idx_01] += deposit_amt * one_minus_x * cell_offset_y
				height[idx_11] += deposit_amt * cell_offset_x * cell_offset_y
			else:
				var erode_amt := minf((capacity - sediment) * erode_speed, -delta_h)
				for i in range(brush_count):
					var bx := node_x + brush_dx[i]
					var by := node_y + brush_dy[i]
					if bx < 0 or bx >= W or by < 0 or by >= H:
						continue
					var bidx := by * W + bx
					var weighted := erode_amt * brush_w[i]
					var actual := minf(height[bidx], weighted)
					height[bidx] -= actual
					sediment += actual

			flow_acc[idx_00] += water
			var spd_sq := speed * speed + delta_h * gravity
			speed = sqrt(maxf(spd_sq, 0.0))
			water *= (1.0 - evaporation)
			pos_x = new_pos_x
			pos_y = new_pos_y
			if water < 0.001:
				break

func _clamp_buffer(buf: PackedFloat32Array, lo: float, hi: float) -> void:
	for i in range(buf.size()):
		buf[i] = clampf(buf[i], lo, hi)

# ─── 河流：从 cell.has_river 链 → Catmull-Rom → SDF ──────────────────────

func _bake_river_sdf(map: MapData, hex_size: float, bounds: Rect2, res: Vector2i) -> PackedFloat32Array:
	var W := res.x
	var H := res.y
	var INF := 1.0e9
	var mask := PackedFloat32Array()
	mask.resize(W * H)
	for i in range(W * H):
		mask[i] = INF

	var chains := _trace_all_rivers(map, hex_size)
	if not chains.is_empty():
		var origin := bounds.position
		var size := bounds.size
		var inv_world := Vector2(float(W) / size.x, float(H) / size.y)
		var stroke_radius_px := maxf(hex_size * RIVER_STROKE_HEX_FACTOR * inv_world.x, 0.5)
		for chain: Dictionary in chains:
			var points: Array = chain.get("points", [])
			var widths: Array = chain.get("widths", [])
			if points.size() < 2:
				continue
			# CR 平滑 → warp 扰动（跟 hex 边界共享同一份 _warp_noise_lo），让河流自然弯曲
			var dense := _catmull_rom_dense_with_widths(points, widths, RIVER_CR_STEP)
			var warped := _warp_river_chain(dense["points"], hex_size)
			_stamp_polyline_variable(mask, warped, dense["widths"], origin, inv_world, W, H, stroke_radius_px)

	_chamfer_sdt(mask, W, H)

	# 转成 [0, 1] 范围，1 = 河上，0 = 距离 ≥ SDF_MAX_DIST_PX
	var out_buf := PackedFloat32Array()
	out_buf.resize(W * H)
	var inv_max := 1.0 / SDF_MAX_DIST_PX
	for i in range(W * H):
		var t := clampf(mask[i] * inv_max, 0.0, 1.0)
		out_buf[i] = 1.0 - t
	return out_buf

func _trace_all_rivers(map: MapData, hex_size: float) -> Array:
	var visited: Dictionary = {}
	var chains: Array = []
	var inbound: Dictionary = {}
	for cell: HexCell in map.all_cells():
		if not cell.has_river or _is_river_terminal_water(cell.terrain):
			continue
		var dn := _declared_river_downstream(map, cell)
		if dn != null and dn.has_river and not _is_river_terminal_water(dn.terrain):
			var dn_key := Vector3i(dn.q, dn.r, dn.s)
			inbound[dn_key] = int(inbound.get(dn_key, 0)) + 1
	for cell: HexCell in map.all_cells():
		if not cell.has_river or _is_river_terminal_water(cell.terrain):
			continue
		var key := Vector3i(cell.q, cell.r, cell.s)
		if visited.has(key):
			continue
		if int(inbound.get(key, 0)) > 0:
			continue
		var chain := _trace_river_chain(map, cell, hex_size, visited)
		if chain.get("points", []).size() >= 2:
			chains.append(chain)
	return chains

func _trace_river_chain(map: MapData, start: HexCell, hex_size: float, visited: Dictionary) -> Dictionary:
	var points: Array = []
	var widths: Array = []
	points.append(HexUtils.cube_to_world(start.q, start.r, hex_size))
	widths.append(_river_width_weight(map, start))
	visited[Vector3i(start.q, start.r, start.s)] = true

	var current: HexCell = start
	var ended_in_water := false
	while true:
		var nxt: HexCell = _find_river_downstream_neighbor(map, current)
		if nxt == null:
			break

		points.append(HexUtils.cube_to_world(nxt.q, nxt.r, hex_size))
		widths.append(_river_width_weight(map, current if _is_river_terminal_water(nxt.terrain) else nxt))
		if _is_river_terminal_water(nxt.terrain):
			current = nxt
			ended_in_water = true
			break
		var nxt_key := Vector3i(nxt.q, nxt.r, nxt.s)
		current = nxt
		if visited.has(nxt_key):
			break
		visited[nxt_key] = true

	# 尾巴伸入终端水体一半，避免河口在最后陆地 cell 中心硬截断。
	# 这里使用河流专用水体判断，包含湖泊；不要复用海洋洋流用的 _is_water()。
	var water_nb: HexCell = null if ended_in_water else _find_river_terminal_water_neighbor(map, current)
	if water_nb != null:
		var river_end := HexUtils.cube_to_world(current.q, current.r, hex_size)
		var water_center := HexUtils.cube_to_world(water_nb.q, water_nb.r, hex_size)
		points.append(river_end.lerp(water_center, 0.78))
		widths.append(widths[widths.size() - 1] if not widths.is_empty() else 0.5)
	return {"points": points, "widths": widths}

func _declared_river_downstream(map: MapData, cell: HexCell) -> HexCell:
	if cell.has_river_downstream:
		return map.get_cell_by_cube(cell.river_downstream)
	return null

func _find_river_downstream_neighbor(map: MapData, cell: HexCell) -> HexCell:
	var declared := _declared_river_downstream(map, cell)
	if declared != null and (declared.has_river or _is_river_terminal_water(declared.terrain)):
		return declared
	var best: HexCell = null
	var best_flow: float = cell.river_flow
	for nb: HexCell in map.get_neighbors(cell):
		if not nb.has_river or _is_river_terminal_water(nb.terrain):
			continue
		if nb.river_flow > best_flow or (is_equal_approx(nb.river_flow, best_flow) and nb.elevation < cell.elevation):
			best_flow = nb.river_flow
			best = nb
	return best

func _river_width_weight(map: MapData, cell: HexCell) -> float:
	if cell == null:
		return 0.0
	var idx: int = cell.index
	if map != null and idx >= 0 and idx < map.river_discharge_30d_arr.size():
		var dynamic_q: float = float(map.river_discharge_30d_arr[idx])
		if dynamic_q > 0.0001:
			return clampf(dynamic_q, 0.0, 1.0)
	return clampf(cell.river_flow, 0.0, 1.0)

# A：把已经 CR 平滑的河流密集点统一走一遍 warp 噪声场，让河道跟 hex 边界一起弯
# 振幅 0.30 hex_size 给出明显的曲流感但不会大幅偏离原 cell 中心
func _warp_river_chain(chain: Array, hex_size: float) -> Array:
	var result: Array = []
	var amp := hex_size * 0.30
	for p: Vector2 in chain:
		var wx_off: float = _warp_noise_lo.get_noise_2d(p.x, p.y) * amp
		var wy_off: float = _warp_noise_lo.get_noise_2d(p.x + 31.7, p.y - 17.3) * amp
		# 加一点高频颤动，模拟"小幅弯曲"
		wx_off += _warp_noise_hi.get_noise_2d(p.x + 91.1, p.y + 53.7) * amp * 0.30
		wy_off += _warp_noise_hi.get_noise_2d(p.x - 41.5, p.y + 23.9) * amp * 0.30
		result.append(p + Vector2(wx_off, wy_off))
	return result

func _find_river_terminal_water_neighbor(map: MapData, cell: HexCell) -> HexCell:
	var best: HexCell = null
	for nb: HexCell in map.get_neighbors(cell):
		if not _is_river_terminal_water(nb.terrain):
			continue
		if best == null or nb.elevation < best.elevation:
			best = nb
	return best

# ─── Catmull-Rom 曲线插值 ───────────────────────────────────────────────

func _catmull_rom_dense(chain: Array, segments_per_step: int) -> Array:
	var n := chain.size()
	if n < 2:
		return chain.duplicate()
	var result: Array = []
	for i in range(n - 1):
		var p0: Vector2 = chain[i - 1] if i > 0 else chain[i]
		var p1: Vector2 = chain[i]
		var p2: Vector2 = chain[i + 1]
		var p3: Vector2 = chain[i + 2] if i + 2 < n else chain[i + 1]
		for j in range(segments_per_step):
			var t := float(j) / float(segments_per_step)
			result.append(_catmull_rom(p0, p1, p2, p3, t))
	result.append(chain[n - 1])
	return result

func _catmull_rom_dense_with_widths(points: Array, widths: Array, segments_per_step: int) -> Dictionary:
	var n := points.size()
	if n < 2:
		return {"points": points.duplicate(), "widths": widths.duplicate()}
	var dense_points: Array = []
	var dense_widths: Array = []
	for i in range(n - 1):
		var p0: Vector2 = points[i - 1] if i > 0 else points[i]
		var p1: Vector2 = points[i]
		var p2: Vector2 = points[i + 1]
		var p3: Vector2 = points[i + 2] if i + 2 < n else points[i + 1]
		var w1: float = float(widths[i]) if i < widths.size() else 0.5
		var w2: float = float(widths[i + 1]) if i + 1 < widths.size() else w1
		for j in range(segments_per_step):
			var t := float(j) / float(segments_per_step)
			dense_points.append(_catmull_rom(p0, p1, p2, p3, t))
			dense_widths.append(lerpf(w1, w2, t))
	dense_points.append(points[n - 1])
	dense_widths.append(float(widths[n - 1]) if n - 1 < widths.size() else 0.5)
	return {"points": dense_points, "widths": dense_widths}

func _catmull_rom(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, t: float) -> Vector2:
	var t2 := t * t
	var t3 := t2 * t
	return 0.5 * (
		(p1 * 2.0)
		+ (p2 - p0) * t
		+ (p0 * 2.0 - p1 * 5.0 + p2 * 4.0 - p3) * t2
		+ (-p0 + p1 * 3.0 - p2 * 3.0 + p3) * t3
	)

# ─── 折线 → 二值 mask（线段距离 ≤ stroke_radius_px 的像素 = 0） ────────

func _stamp_polyline_binary(
	mask: PackedFloat32Array,
	points: Array,
	origin: Vector2,
	inv_world: Vector2,
	W: int,
	H: int,
	stroke_radius_px: float
) -> void:
	var pad := int(ceil(stroke_radius_px)) + 1
	for i in range(points.size() - 1):
		var p0: Vector2 = (points[i] - origin) * inv_world
		var p1: Vector2 = (points[i + 1] - origin) * inv_world
		var min_x := int(floor(minf(p0.x, p1.x))) - pad
		var max_x := int(ceil(maxf(p0.x, p1.x))) + pad
		var min_y := int(floor(minf(p0.y, p1.y))) - pad
		var max_y := int(ceil(maxf(p0.y, p1.y))) + pad
		min_x = clampi(min_x, 0, W - 1)
		max_x = clampi(max_x, 0, W - 1)
		min_y = clampi(min_y, 0, H - 1)
		max_y = clampi(max_y, 0, H - 1)
		var seg := p1 - p0
		var seg_len_sq := seg.length_squared()
		for y in range(min_y, max_y + 1):
			for x in range(min_x, max_x + 1):
				var p := Vector2(float(x) + 0.5, float(y) + 0.5)
				var t: float = 0.0
				if seg_len_sq > 0.0001:
					t = clampf((p - p0).dot(seg) / seg_len_sq, 0.0, 1.0)
				var closest := p0 + seg * t
				if p.distance_to(closest) <= stroke_radius_px:
					mask[y * W + x] = 0.0

func _stamp_polyline_variable(
	mask: PackedFloat32Array,
	points: Array,
	widths: Array,
	origin: Vector2,
	inv_world: Vector2,
	W: int,
	H: int,
	base_radius_px: float
) -> void:
	for i in range(points.size() - 1):
		var w0: float = float(widths[i]) if i < widths.size() else 0.5
		var w1: float = float(widths[i + 1]) if i + 1 < widths.size() else w0
		# [river-hierarchy 2026-06-19] 加大干支流宽度对比：0.70+w*2.10 → 0.60+w*2.7 → 0.40+pow(w,1.4)*3.7。
		# 改线性为幂律：低流量支流更细(~0.6px)、高流量干流更粗(~4px)，干支流层级与径流量视觉差一眼可辨
		# (discharge max/p50 仅~2.1，线性映射宽度差不明显，幂律放大中高流量段差异)。
		var seg_radius_px: float = base_radius_px * (0.40 + pow(maxf(w0, w1), 1.4) * 3.7)
		var pad := int(ceil(seg_radius_px)) + 1
		var p0: Vector2 = (points[i] - origin) * inv_world
		var p1: Vector2 = (points[i + 1] - origin) * inv_world
		var min_x := int(floor(minf(p0.x, p1.x))) - pad
		var max_x := int(ceil(maxf(p0.x, p1.x))) + pad
		var min_y := int(floor(minf(p0.y, p1.y))) - pad
		var max_y := int(ceil(maxf(p0.y, p1.y))) + pad
		min_x = clampi(min_x, 0, W - 1)
		max_x = clampi(max_x, 0, W - 1)
		min_y = clampi(min_y, 0, H - 1)
		max_y = clampi(max_y, 0, H - 1)
		var seg := p1 - p0
		var seg_len_sq := seg.length_squared()
		for y in range(min_y, max_y + 1):
			for x in range(min_x, max_x + 1):
				var p := Vector2(float(x) + 0.5, float(y) + 0.5)
				var t: float = 0.0
				if seg_len_sq > 0.0001:
					t = clampf((p - p0).dot(seg) / seg_len_sq, 0.0, 1.0)
				var radius := base_radius_px * (0.40 + pow(lerpf(w0, w1, t), 1.4) * 3.7)
				var closest := p0 + seg * t
				if p.distance_to(closest) <= radius:
					mask[y * W + x] = 0.0

# ─── Chamfer 3-4 距离变换（双通） ───────────────────────────────────────

func _chamfer_sdt(mask: PackedFloat32Array, W: int, H: int) -> void:
	var d3 := 3.0
	var d4 := 4.0
	for y in range(H):
		for x in range(W):
			var idx := y * W + x
			var v := mask[idx]
			if v <= 0.0:
				continue
			if x > 0:
				v = minf(v, mask[idx - 1] + d3)
			if y > 0:
				v = minf(v, mask[idx - W] + d3)
				if x > 0:
					v = minf(v, mask[idx - W - 1] + d4)
				if x < W - 1:
					v = minf(v, mask[idx - W + 1] + d4)
			mask[idx] = v
	for y in range(H - 1, -1, -1):
		for x in range(W - 1, -1, -1):
			var idx := y * W + x
			var v := mask[idx]
			if v <= 0.0:
				continue
			if x < W - 1:
				v = minf(v, mask[idx + 1] + d3)
			if y < H - 1:
				v = minf(v, mask[idx + W] + d3)
				if x > 0:
					v = minf(v, mask[idx + W - 1] + d4)
				if x < W - 1:
					v = minf(v, mask[idx + W + 1] + d4)
			mask[idx] = v
	var inv3 := 1.0 / 3.0
	for i in range(W * H):
		mask[i] = mask[i] * inv3

# ─── 纹理编码 ────────────────────────────────────────────────────────────

func _encode_height_tex(buf: PackedFloat32Array, size: Vector2i) -> ImageTexture:
	# RG8 16-bit：v16 = round(v*65535)；R = v16>>8, G = v16 & 0xFF
	var W := size.x
	var H := size.y
	var data := PackedByteArray()
	data.resize(W * H * 2)
	for i in range(W * H):
		var v := clampf(buf[i], 0.0, 1.0)
		var v16 := clampi(int(round(v * 65535.0)), 0, 65535)
		data[i * 2] = (v16 >> 8) & 0xFF
		data[i * 2 + 1] = v16 & 0xFF
	var img := Image.create_from_data(W, H, false, Image.FORMAT_RG8, data)
	return ImageTexture.create_from_image(img)

# ─── v9.atlas：合并通道编码 ─────────────────────────────────────────────
# 把原先 9 张 derived 贴图（biome/veg/cover/moist/flow/lat/volcano/ocean/wind）
# 按"采样模式 + 数据语义"分到 3 张 atlas，shader 端只需 3 次 texture() 即可
# 拿到所有 derived 数据。height_tex 因分辨率/精度独立保留。

# map_index_atlas: RGBA8 NEAREST (R=biome, G=cell index low, B=cell index high, A=0)
# v9.perf：existing 非 null 时走 ImageTexture.update() 复用 GPU RID，
# 避免每天 rebake 时反复 alloc/free GPU buffer + 重新绑定 shader uniform
func _encode_enum_atlas(biome_buf: PackedByteArray, _veg_buf: PackedByteArray,
		_cover_buf: PackedByteArray, size: Vector2i,
		existing: ImageTexture = null, world: WorldData = null) -> ImageTexture:
	var W := size.x
	var H := size.y
	var n := W * H
	var data := PackedByteArray()
	data.resize(n * 4)
	var lookup: Array = world.pixel_to_cell_lookup if world != null else []
	var has_lookup: bool = lookup.size() >= n
	for i in range(n):
		var di := i * 4
		data[di] = biome_buf[i] if i < biome_buf.size() else 0
		var cid: int = 65535
		if has_lookup:
			var cell = lookup[i]
			if cell != null:
				cid = int(cell.index)
		data[di + 1] = cid & 0xFF
		data[di + 2] = (cid >> 8) & 0xFF
		data[di + 3] = 0
	# 阶段 P2：缓存 RGBA8 data。后续 biome 变化只局部写 R 通道；G/B cell index 不变。
	_enum_atlas_data = data
	_enum_atlas_data_size = Vector2i(W, H)
	var img := Image.create_from_data(W, H, false, Image.FORMAT_RGBA8, data)
	# ImageTexture.get_size() 返回 Vector2，而 W/H 是 int → 用 Vector2 比较
	if existing != null and existing.get_size() == Vector2(float(W), float(H)):
		existing.update(img)
		return existing
	return ImageTexture.create_from_image(img)


# ═══════════════════════════════════════════════════════════════════════
# Cell-index 间接寻址（province-ID indirection）烘焙
# plan: cell-index atlas indirection。bake_world 一次性烘出静态索引图 + per-cell LUT。
#   - cell index 已合入 map_index_atlas.g/b；
#   - LUT 由 daily 路径增量刷新（refresh_cell_luts_daily）。
# 全程 feature-flag（DCFeatureFlags.cell_indirection_active）：flag 关时本组函数
# 不被 bake_world 调用，旧 per-pixel atlas 路径逐字节不变。
# ═══════════════════════════════════════════════════════════════════════

func _ensure_cell_lut_dims(map: MapData, world: WorldData) -> void:
	if world == null:
		return
	var n_cells: int = map.cell_count() if map != null else 0
	if n_cells <= 0:
		n_cells = 1
	var lut_w: int = mini(n_cells, 2048)
	if lut_w < 1:
		lut_w = 1
	var lut_h: int = int(ceil(float(n_cells) / float(lut_w)))
	if lut_h < 1:
		lut_h = 1
	world.lut_dims = Vector2i(lut_w, lut_h)


# per-cell LUT 全量烘焙 dispatcher：C++（DCWorldExt.encode_cell_luts）优先，
# 失败回退 GDScript（skill rule 11，保留至 A/B parity 验证通过）。
# 字节量化与 fan-out 路径同源（enum=terrain/vegetation/cover、
# dyn=_dynamic_cell_signature/pk_atlas_sig_dynamic、
# eco=_ecology_visual_signature/pk_atlas_sig_ecology），保证间接寻址与旧 atlas
# bit-equivalent。cache_valid=true 时 C++ 端按 prev 推进 eco transition_age；
# 初次 bake 传 false（transition 归零）。daily 刷新走 refresh_cell_luts_daily。
func bake_cell_luts(map: MapData, world: WorldData, cache_valid: bool = false) -> void:
	if map == null or world == null:
		return
	if world.lut_dims.x <= 0 or world.lut_dims.y <= 0:
		_ensure_cell_lut_dims(map, world)
	var lw: int = world.lut_dims.x
	var lh: int = world.lut_dims.y
	if lw <= 0 or lh <= 0:
		return
	# C++ 优先路径：scalar tight loop（即便 n_cells≈2400 也在 CPP 做，含 transition tracking）。
	if _world_ext != null and _world_ext.has_method("encode_cell_luts"):
		# [fix cell-indirect 2026-06-16] 不再在此 refresh_slots_from_map()：
		# encode_cell_luts 与 encode_dynamic_cell_atlas / encode_dyn_smooth_atlas 同读
		# _slots（cell_temp/moisture/snow/vegetation_vitality/sea_ice_frac），那几个旧
		# pass 在同一 atlas 阶段直接读 *live* _slots 且不 refresh 也渲染正确——证明此处
		# _slots 已是当前帧值。之前误加的 refresh_slots_from_map() 反而把 _slots 用
		# *未回流的* MapData.*_arr 镜像（temp_arr/terrain_arr 等，原生气候 pass 只写
		# _slots、不每 tick flush 回 MapData）覆盖成陈旧/空值 → enum/dyn/eco LUT 全 0
		# （间接寻址地面发白、海冰消失、浮雕被糊）。skill §数据契约：两侧无可靠零拷贝，
		# 不能假设 MapData 镜像与 _slots 同步。
		var out: Dictionary = _world_ext.encode_cell_luts({
			"map": map,
			"lut_w": lw,
			"lut_h": lh,
			"n_cells": map.cell_count(),
			"terrain_lake": int(TerrainType.TERRAIN.LAKE),
			"terrain_sea_ice": int(TerrainType.TERRAIN.SEA_ICE),
			"veg_none": int(VegetationType.VEG.NONE),
			"cache_valid": cache_valid,
		})
		if not bool(out.get("fallback", true)):
			var e = out.get("enum_lut", null)
			var d = out.get("dyn_lut", null)
			var c = out.get("eco_lut", null)
			if e is PackedByteArray and d is PackedByteArray and c is PackedByteArray:
				world.enum_lut_tex = _lut_tex_from_data(e, lw, lh, Image.FORMAT_RGB8, world.enum_lut_tex)
				world.dyn_lut_tex = _lut_tex_from_data(d, lw, lh, Image.FORMAT_RGBA8, world.dyn_lut_tex)
				world.eco_lut_tex = _lut_tex_from_data(c, lw, lh, Image.FORMAT_RGBA8, world.eco_lut_tex)
				return
	_bake_cell_luts_gd(map, world, lw, lh)


# GDScript fallback：per-cell LUT 全量烘焙（C++ encode_cell_luts 不可用时）。
func _bake_cell_luts_gd(map: MapData, world: WorldData, lw: int, lh: int) -> void:
	var slots: int = lw * lh
	var enum_data := PackedByteArray(); enum_data.resize(slots * 3)
	var dyn_data := PackedByteArray(); dyn_data.resize(slots * 4)
	var eco_data := PackedByteArray(); eco_data.resize(slots * 4)
	for cell in map.all_cells():
		if cell == null:
			continue
		var ci: int = int(cell.index)
		if ci < 0 or ci >= slots:
			continue
		var e3: int = ci * 3
		enum_data[e3]     = int(cell.terrain) & 0xFF
		enum_data[e3 + 1] = int(cell.vegetation) & 0xFF
		enum_data[e3 + 2] = int(cell.cover) & 0xFF
		var dsig: int = _dynamic_cell_signature(cell)
		var d4: int = ci * 4
		dyn_data[d4]     = dsig & 0xFF
		dyn_data[d4 + 1] = (dsig >> 8) & 0xFF
		dyn_data[d4 + 2] = (dsig >> 16) & 0xFF
		dyn_data[d4 + 3] = (dsig >> 24) & 0xFF
		var cur_vit_byte: int = _q01_byte(float(cell.vegetation_vitality))
		var esig: int = _ecology_visual_signature(cell, 0, cur_vit_byte)
		var c4: int = ci * 4
		eco_data[c4]     = esig & 0xFF
		eco_data[c4 + 1] = (esig >> 8) & 0xFF
		eco_data[c4 + 2] = (esig >> 16) & 0xFF
		eco_data[c4 + 3] = (esig >> 24) & 0xFF
	world.enum_lut_tex = _lut_tex_from_data(enum_data, lw, lh, Image.FORMAT_RGB8, world.enum_lut_tex)
	world.dyn_lut_tex = _lut_tex_from_data(dyn_data, lw, lh, Image.FORMAT_RGBA8, world.dyn_lut_tex)
	world.eco_lut_tex = _lut_tex_from_data(eco_data, lw, lh, Image.FORMAT_RGBA8, world.eco_lut_tex)


func _lut_tex_from_data(data: PackedByteArray, w: int, h: int, fmt: int, existing: ImageTexture) -> ImageTexture:
	var img := Image.create_from_data(w, h, false, fmt, data)
	if existing != null and existing.get_size() == Vector2(float(w), float(h)):
		existing.update(img)
		return existing
	return ImageTexture.create_from_image(img)


# daily LUT 全量刷新：cell 视觉状态每日变化（enum 翻面 / temp / snow / vitality 等），
# per-cell LUT（n_cells ~2400）全量重烘 ~0.1-0.3ms，远小于旧 per-pixel fan-out。
# 由 DynamicVisualAtlasUploadSystem 每 stride 起点调用（仅 flag 开启时）。
func refresh_cell_luts_daily(map: MapData, world: WorldData) -> void:
	if world == null or world.lut_dims.x <= 0 or world.lut_dims.y <= 0:
		return
	# cache_valid=true：C++ encode_cell_luts 按 prev 推进 eco transition_age（每日衰减）。
	bake_cell_luts(map, world, true)


# Systemic Ocean Currents：独立 R8 upwelling 纹理编码（L8 单通道，LINEAR 过滤）。
# 源 buffer 编码：0 = 下沉满 / 128 = 中性 / 255 = 上升满。
# shader 端只在 ocean_current_debug 开启时采样，主路径不读。
func _encode_upwelling_tex(upwelling_buf: PackedByteArray, size: Vector2i,
		existing: ImageTexture = null) -> ImageTexture:
	var W := size.x
	var H := size.y
	var n := W * H
	# I + L: size 匹配时直接把 upwelling_buf 喂给 Image.create_from_data，省掉 620k
	# byte 的 GDScript 拷贝循环（~10-15ms）。size 不匹配（异常）才回退到补 128 的兜底。
	var img: Image
	if upwelling_buf.size() == n:
		img = Image.create_from_data(W, H, false, Image.FORMAT_L8, upwelling_buf)
	else:
		var data := PackedByteArray()
		data.resize(n)
		var has_up: bool = upwelling_buf.size() >= n
		for i in range(n):
			data[i] = upwelling_buf[i] if has_up else 128
		img = Image.create_from_data(W, H, false, Image.FORMAT_L8, data)
	if existing != null and existing.get_size() == Vector2(float(W), float(H)):
		existing.update(img)
		return existing
	return ImageTexture.create_from_image(img)

# PR-3.1.1（master 手册 §6.2）：_encode_r8_tex 已搬到 DCAtlasEncoders.encode_r8_tex。
# 本 facade 保留作为 in-class shim，避免 caller 全部一次性改动。
# 后续 PR 可逐步把 caller 改为 DCAtlasEncoders.encode_r8_tex 直调。
func _encode_r8_tex(buf: PackedByteArray, size: Vector2i, existing: ImageTexture) -> ImageTexture:
	return DCAtlasEncoders.encode_r8_tex(buf, size, existing)

# [river-render-restore 2026-06-19] 河流 SDF（float[0,1]，1=河心）→ L8 纹理。
# 与 height_tex 共用同一 uv（world_origin/world_size 覆盖同一 world_bounds），
# shader 在 uv 处采样得到 [0,1] 河流强度，喂回 land_pipeline 的 flow 视觉层。
func _encode_flow_tex(buf: PackedFloat32Array, size: Vector2i, existing: ImageTexture) -> ImageTexture:
	var W: int = size.x
	var H: int = size.y
	var n: int = W * H
	if buf.size() < n:
		return existing
	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(n)
	for i in range(n):
		bytes[i] = int(clampf(buf[i], 0.0, 1.0) * 255.0 + 0.5)
	return DCAtlasEncoders.encode_r8_tex(bytes, size, existing)

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
# 调用约定：SeaIceAtlasUploadJob 每 stride 日调用一次（之前是 refresh_climate_daily 末尾）。
func bake_sea_ice_fraction_only(map: MapData, world: WorldData) -> void:
	# [sea-ice-atlas-skip 2026-06-16] flag 关（默认）→ 整条 prepare/upload no-op
	# （sea_ice_tex 已退役，无 shader 采样者，运行时 upload job 也不注册）。
	if not DCFeatureFlags.sea_ice_atlas_active():
		return
	var prep: Dictionary = prepare_sea_ice_fraction_atlas(map, world)
	if bool(prep.get("prepared", false)) and bool(prep.get("dirty", true)):
		upload_prepared_sea_ice_fraction_atlas(world)


func prepare_sea_ice_fraction_atlas(map: MapData, world: WorldData) -> Dictionary:
	var t0: int = Time.get_ticks_usec()
	var out: Dictionary = {
		"prepared": false,
		"dirty": false,
		"prepare_ms": 0.0,
		"path": "none",
		"dirty_cells": 0,
		"dirty_ratio": 0.0,
	}
	# [sea-ice-atlas-skip 2026-06-16] flag 关（默认）→ 直接返回 not-prepared，
	# 调用方据此不会 enqueue upload。sea_ice_tex 已退役（无 shader 采样者）。
	if not DCFeatureFlags.sea_ice_atlas_active():
		out["path"] = "disabled"
		return out
	if world == null or map == null:
		return out
	var W: int = int(world.derived_size.x)
	var H: int = int(world.derived_size.y)
	var n: int = W * H
	if n <= 0:
		return out
	if world.pixel_to_cell_lookup.size() != n:
		push_warning("MapBaker.prepare_sea_ice_fraction_atlas: pixel_to_cell_lookup missing; falling back to zeros")
		var zero_buf := PackedByteArray()
		zero_buf.resize(n)
		_sea_ice_only_buf = zero_buf
		world.sea_ice_fraction_buffer = zero_buf
		out["prepared"] = true
		out["dirty"] = true
		out["path"] = "zero_fallback"
		out["prepare_ms"] = (Time.get_ticks_usec() - t0) / 1000.0
		return out

	_ensure_sea_ice_pixel_to_cell_index(map, world)
	# DOTS-Final-Push 修复：优先用 set_climate_profile() 注入的引用；fallback 才走
	# 老的 world.get("config") 路径——但 WorldData 没有 config 字段，那条永远是 null。
	var cp = _climate_profile
	if cp == null:
		var cfg_legacy = world.get("config")
		cp = cfg_legacy.climate_profile if cfg_legacy != null and "climate_profile" in cfg_legacy else null
	var use_native: bool = cp != null \
			and _world_ext != null and _world_ext.has_method("run_sea_ice_atlas_prepare")
	# DOTS-Final-Push 任务 6.2：once-only 诊断打印——把 use_native 几个条件分别状态
	# 暴露出来，定位 path=gdscript 的真因。dots-flag-prune-pr1 (2026-05-22)：
	# use_gdext_sea_ice_atlas_prepare flag 已删，路径现恒走 ext + has_method 探测。
	if not _sea_ice_path_logged:
		_sea_ice_path_logged = true
		var cp_ok: bool = cp != null
		var ext_ok: bool = _world_ext != null
		var method_ok: bool = ext_ok and _world_ext.has_method("run_sea_ice_atlas_prepare")
		print("[sea_ice_atlas_prepare] path-decision once-only: cp=%s ext=%s method=%s -> use_native=%s" % [
			str(cp_ok), str(ext_ok), str(method_ok), str(use_native)
		])
	if use_native:
		if _world_ext.has_method("refresh_slots_from_map"):
			_world_ext.refresh_slots_from_map()
		var ret: Dictionary = _world_ext.run_sea_ice_atlas_prepare({
			"n_cells": map.cell_count(),
			"width": W,
			"height": H,
			"pixel_to_cell_index": _sea_ice_pixel_to_cell_idx,
			"previous_cell_bytes": _last_sea_ice_cell_bytes_packed,
		})
		if not bool(ret.get("fallback", true)):
			_sea_ice_only_buf = ret.get("buffer", PackedByteArray())
			_last_sea_ice_cell_bytes_packed = ret.get("cell_bytes", PackedByteArray())
			world.sea_ice_fraction_buffer = _sea_ice_only_buf
			_sea_ice_cache_size = Vector2i(W, H)
			out["prepared"] = _sea_ice_only_buf.size() == n
			out["dirty_cells"] = int(ret.get("dirty_cells", map.cell_count()))
			out["dirty_ratio"] = float(ret.get("dirty_ratio", 1.0))
			out["dirty"] = int(out.get("dirty_cells", 0)) > 0 or world.sea_ice_tex == null
			out["path"] = "gdext"
			out["prepare_ms"] = float(ret.get("prepare_ms", ret.get("elapsed_ms", 0.0)))
			return out
		else:
			out["fallback_reason"] = String(ret.get("reason", "unknown"))

	var gd_ret: Dictionary = _prepare_sea_ice_fraction_atlas_gd(map, world, W, H, n)
	gd_ret["prepare_ms"] = (Time.get_ticks_usec() - t0) / 1000.0
	return gd_ret


func upload_prepared_sea_ice_fraction_atlas(world: WorldData) -> Dictionary:
	var out: Dictionary = {"uploaded": false, "image_ms": 0.0, "upload_ms": 0.0, "elapsed_ms": 0.0}
	# [sea-ice-atlas-skip 2026-06-16] flag 关（默认）→ no-op（不 create/update sea_ice_tex）。
	if not DCFeatureFlags.sea_ice_atlas_active():
		return out
	if world == null:
		return out
	var W: int = int(world.derived_size.x)
	var H: int = int(world.derived_size.y)
	if W <= 0 or H <= 0 or _sea_ice_only_buf.size() != W * H:
		return out
	var t0: int = Time.get_ticks_usec()
	var img := Image.create_from_data(W, H, false, Image.FORMAT_L8, _sea_ice_only_buf)
	var t1: int = Time.get_ticks_usec()
	if world.sea_ice_tex != null and world.sea_ice_tex.get_size() == Vector2(float(W), float(H)):
		world.sea_ice_tex.update(img)
	else:
		world.sea_ice_tex = ImageTexture.create_from_image(img)
	var t2: int = Time.get_ticks_usec()
	out["uploaded"] = true
	out["image_ms"] = (t1 - t0) / 1000.0
	out["upload_ms"] = (t2 - t1) / 1000.0
	out["elapsed_ms"] = (t2 - t0) / 1000.0
	return out


func _ensure_sea_ice_pixel_to_cell_index(map: MapData, world: WorldData) -> void:
	var n: int = int(world.derived_size.x) * int(world.derived_size.y)
	if _sea_ice_cache_size == world.derived_size and _sea_ice_pixel_to_cell_idx.size() == n:
		return
	_sea_ice_pixel_to_cell_idx = PackedInt32Array()
	_sea_ice_pixel_to_cell_idx.resize(n)
	var lookup := world.pixel_to_cell_lookup
	for i in range(n):
		var cell = lookup[i]
		_sea_ice_pixel_to_cell_idx[i] = map.index_of(cell) if cell != null else -1


func _prepare_sea_ice_fraction_atlas_gd(map: MapData, world: WorldData, W: int, H: int, n: int) -> Dictionary:
	# DOTS-Final-Push 任务 6.2 / 方案 A：之前每次 prepare 都跑 2400 cell 字节比对
	# 后再无条件跑 28800 像素回扫（var px in range(n)），即便所有 cell 都没翻面也
	# 一样。32-day 的 sea_ice_atlas_upload p95=49ms（极端 232ms）的 prepare 部分
	# 大概率卡在这里。优化：先做 cell 字节比对，dirty_cells==0 且 sea_ice_tex
	# 已存在时直接 dirty=false 返回——不重新填 _sea_ice_only_buf（保持上一帧的
	# buffer），upload 阶段也会被 SeaIceAtlasUploadJob 跳过（prep["dirty"]==false
	# → 不进入 _pending_upload）。
	var cell_bytes := PackedByteArray()
	cell_bytes.resize(map.cell_count())
	var dirty_cells: int = 0
	for i in range(map.cell_count()):
		var cell: HexCell = map.cell_at(i)
		var b: int = 0
		if cell != null and _is_water(cell.terrain):
			# 使用 _q01_byte_ice 保留低浓度冰的连续数据；可见强度由 shader 阈值决定。
			# 与 ice_state_atlas_chunk_step 的语义一致（fraction>0 → byte>=1）。
			b = _q01_byte_ice(float(cell.sea_ice_fraction))
		cell_bytes[i] = b
		if _last_sea_ice_cell_bytes_packed.size() <= i or int(_last_sea_ice_cell_bytes_packed[i]) != b:
			dirty_cells += 1
	# Early-return：所有 cell 字节都没翻面 + 纹理已建立 + 缓存大小匹配 →
	# 不重做 28800 像素回扫，直接复用上一帧 _sea_ice_only_buf（caller 不会
	# 走 upload 分支，sea_ice_tex 维持当前内容）。
	if dirty_cells == 0 and world.sea_ice_tex != null \
			and _sea_ice_cache_size == Vector2i(W, H) \
			and _sea_ice_only_buf.size() == n:
		# _last_sea_ice_cell_bytes_packed 已与本帧一致，无需再赋值。
		world.sea_ice_fraction_buffer = _sea_ice_only_buf
		return {
			"prepared": true,
			"dirty": false,
			"prepare_ms": 0.0,
			"path": "gdscript_skip",
			"dirty_cells": 0,
			"dirty_ratio": 0.0,
		}
	# 有翻面 → 走完整像素回扫。
	_sea_ice_only_buf = PackedByteArray()
	_sea_ice_only_buf.resize(n)
	for px in range(n):
		var ci: int = _sea_ice_pixel_to_cell_idx[px] if px < _sea_ice_pixel_to_cell_idx.size() else -1
		_sea_ice_only_buf[px] = cell_bytes[ci] if ci >= 0 and ci < cell_bytes.size() else 0
	_last_sea_ice_cell_bytes_packed = cell_bytes
	world.sea_ice_fraction_buffer = _sea_ice_only_buf
	_sea_ice_cache_size = Vector2i(W, H)
	return {
		"prepared": true,
		"dirty": dirty_cells > 0 or world.sea_ice_tex == null,
		"prepare_ms": 0.0,
		"path": "gdscript",
		"dirty_cells": dirty_cells,
		"dirty_ratio": float(dirty_cells) / float(maxi(map.cell_count(), 1)),
	}

func bake_weather_field_only(map: MapData, world: WorldData) -> void:
	# DEPRECATED（DOTS-Total-CPP 任务 7）：本函数沿用 GDScript 像素填充路径，
	# fast tick 主路径 set_weather_field_texture(null) 已不再实际烘焙整张纹理；
	# 仅保留兜底用途（手动 reset / regenerate 后首帧）。后续将由 weather_baker.gd
	# 接管 dirty-tile pack；新代码路径**不要**调用此函数。
	if world == null or map == null:
		return
	# Daily-sim perf opt（dirty 增量路径，与 bake_sea_ice_fraction_only / cover / vegetation
	# 同构）：weather_field_tex 是 hex-constant 数据（每个 hex 内部颜色完全一致）。
	#
	# 旧路径：每天扫 ~2400 cell + 写整张 RGBA8（~250k–600k bytes，27ms）。
	# 新路径：
	#   1) 首次或 size 变化 → 完整重建 _weather_field_buf + 填 sig 缓存（一次性 ~27ms）；
	#   2) 后续 → 遍历 ~2400 cell：sig 不变 ⇒ 直接 continue；变了才把 4 byte 写到那个
	#      cell 的所有像素 + 更新 sig。典型日 < 50 个 cell 翻面 → 写盘 ~5k 字节。
	#   3) 若任一 cell 翻面 → 触发整张 Image.create_from_data + tex.update（GPU 上传必经；
	#      但循环 / 写盘开销骤降到 < 5ms）。全无变化 ⇒ 连 image 创建也省。
	var W := world.derived_size.x
	var H := world.derived_size.y
	if W <= 0 or H <= 0:
		return
	var n := W * H
	if n <= 0:
		return
	var cell_lists: Dictionary = world.cell_pixel_lists
	if cell_lists.is_empty():
		push_warning("MapBaker.bake_weather_field_only: cell_pixel_lists missing; weather field empty")
		return

	var need_bytes: int = n * 4
	var cache_size_match: bool = (_weather_field_cache_size == Vector2i(W, H) \
			and _weather_field_buf.size() == need_bytes \
			and not _last_weather_field_cell_sigs.is_empty())

	if not cache_size_match:
		# 全重建路径：清状态 → 全图写一次 → 填 sig 缓存。
		_weather_field_buf = PackedByteArray()
		_weather_field_buf.resize(need_bytes)
		_last_weather_field_cell_sigs = {}
		_weather_field_cache_size = Vector2i(W, H)
		for cell_key in cell_lists.keys():
			var cell: HexCell = cell_key
			if cell == null:
				continue
			var wt0: int = cell.weather_type if cell.weather_field_initialized else int(cell.current_state.get("weather", WeatherType.WT.CLEAR))
			var intensity0: float = cell.weather_intensity if cell.weather_field_initialized else float(cell.current_state.get("weather_intensity", 0.0))
			var cloud0: float = cell.weather_cloud if cell.weather_field_initialized else float(cell.current_state.get("weather_cloud", 0.0))
			var precip0: float = cell.weather_precip if cell.weather_field_initialized else float(cell.current_state.get("weather_precip", 0.0))
			var b00: int = clampi(wt0, 0, 255)
			var b10: int = clampi(int(round(clampf(intensity0, 0.0, 1.0) * 255.0)), 0, 255)
			var b20: int = clampi(int(round(clampf(cloud0, 0.0, 1.0) * 255.0)), 0, 255)
			var b30: int = clampi(int(round(clampf(precip0, 0.0, 1.0) * 255.0)), 0, 255)
			var sig0: int = b00 | (b10 << 8) | (b20 << 16) | (b30 << 24)
			_last_weather_field_cell_sigs[cell] = sig0
			var pixels0: PackedInt32Array = cell_lists[cell_key]
			for px in pixels0:
				var di0: int = px * 4
				_weather_field_buf[di0] = b00
				_weather_field_buf[di0 + 1] = b10
				_weather_field_buf[di0 + 2] = b20
				_weather_field_buf[di0 + 3] = b30
		world.weather_field_buffer = _weather_field_buf
		var img0 := Image.create_from_data(W, H, false, Image.FORMAT_RGBA8, _weather_field_buf)
		if world.weather_field_tex != null and world.weather_field_tex.get_size() == Vector2(float(W), float(H)):
			world.weather_field_tex.update(img0)
		else:
			world.weather_field_tex = ImageTexture.create_from_image(img0)
		return

	# 增量路径：遍历 cell，比 sig，仅写翻面的。
	var dirty_count: int = 0
	var weather_dirty_mask: PackedByteArray = map.weather_dirty_mask
	var use_weather_dirty: bool = weather_dirty_mask.size() == map.cell_count()
	var has_weather_dirty: bool = false
	if use_weather_dirty:
		for _wd in weather_dirty_mask:
			if int(_wd) != 0:
				has_weather_dirty = true
				break
	for cell_key in cell_lists.keys():
		var cell: HexCell = cell_key
		if cell == null:
			continue
		if use_weather_dirty and has_weather_dirty:
			var cell_idx: int = map.index_of(cell)
			if cell_idx < 0 or cell_idx >= weather_dirty_mask.size() or weather_dirty_mask[cell_idx] == 0:
				continue
		var wt: int = cell.weather_type if cell.weather_field_initialized else int(cell.current_state.get("weather", WeatherType.WT.CLEAR))
		var intensity: float = cell.weather_intensity if cell.weather_field_initialized else float(cell.current_state.get("weather_intensity", 0.0))
		var cloud: float = cell.weather_cloud if cell.weather_field_initialized else float(cell.current_state.get("weather_cloud", 0.0))
		var precip: float = cell.weather_precip if cell.weather_field_initialized else float(cell.current_state.get("weather_precip", 0.0))
		var b0: int = clampi(wt, 0, 255)
		var b1: int = clampi(int(round(clampf(intensity, 0.0, 1.0) * 255.0)), 0, 255)
		var b2: int = clampi(int(round(clampf(cloud, 0.0, 1.0) * 255.0)), 0, 255)
		var b3: int = clampi(int(round(clampf(precip, 0.0, 1.0) * 255.0)), 0, 255)
		var sig: int = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
		var prev_sig_var = _last_weather_field_cell_sigs.get(cell, -1)
		if int(prev_sig_var) == sig:
			continue
		_last_weather_field_cell_sigs[cell] = sig
		var pixels: PackedInt32Array = cell_lists[cell_key]
		for px in pixels:
			var di: int = px * 4
			_weather_field_buf[di] = b0
			_weather_field_buf[di + 1] = b1
			_weather_field_buf[di + 2] = b2
			_weather_field_buf[di + 3] = b3
		dirty_count += 1

	world.weather_field_buffer = _weather_field_buf
	# H 诊断：累计 dirty 比例。每 30 次调用打一行，命中率高于 80% 时考虑回滚 F。
	_wf_diag_calls += 1
	_wf_diag_dirty_sum += dirty_count
	_wf_diag_total_cells = cell_lists.size()
	if dirty_count == 0:
		_wf_diag_skipped_full += 1
	if _wf_diag_calls >= 30:
		var avg_dirty: float = float(_wf_diag_dirty_sum) / float(_wf_diag_calls)
		var dirty_ratio: float = avg_dirty / float(maxi(_wf_diag_total_cells, 1))
		print("  [field_bake] last %d calls: avg dirty=%.0f/%d (%.1f%%), full-skip=%d" % [
			_wf_diag_calls, avg_dirty, _wf_diag_total_cells, dirty_ratio * 100.0, _wf_diag_skipped_full
		])
		_wf_diag_calls = 0
		_wf_diag_dirty_sum = 0
		_wf_diag_skipped_full = 0
	if dirty_count == 0:
		# 全图无变化：连 Image.update 也省。weather_field_tex 维持上一帧不变。
		return
	var img := Image.create_from_data(W, H, false, Image.FORMAT_RGBA8, _weather_field_buf)
	if world.weather_field_tex != null and world.weather_field_tex.get_size() == Vector2(float(W), float(H)):
		world.weather_field_tex.update(img)
	else:
		world.weather_field_tex = ImageTexture.create_from_image(img)

# ─── Phase 14：火山强度场（R8） ─────────────────────────────────────────────
# 每像素 = sum_over_volcanoes( max(0, 1 - dist / glow_radius) )
# glow_radius ≈ 3 × hex_size，让红光晕跨越自身 + 1-2 邻居。
# 性能：O(W * H * N_volcanoes)，N ≤ 8，对 192×108 derived 来说 ~165k 操作，可忽略。

func _bake_volcano_field(map: MapData, hex_size: float, world: WorldData) -> PackedByteArray:
	var W := world.derived_size.x
	var H := world.derived_size.y
	var origin := world.world_bounds.position
	var size := world.world_bounds.size
	var step_x := size.x / float(W)
	var step_y := size.y / float(H)
	var glow_radius := hex_size * 3.0
	var inv_glow := 1.0 / glow_radius

	# 收集火山中心
	var volcano_centers: Array[Vector2] = []
	for cell: HexCell in map.all_cells():
		if cell.has_volcano:
			volcano_centers.append(HexUtils.cube_to_world(cell.q, cell.r, hex_size))

	var buf := PackedByteArray()
	buf.resize(W * H)
	if volcano_centers.is_empty():
		return buf  # 全 0

	for y in range(H):
		var wy := origin.y + (float(y) + 0.5) * step_y
		var row := y * W
		for x in range(W):
			var wx := origin.x + (float(x) + 0.5) * step_x
			var intensity: float = 0.0
			for c: Vector2 in volcano_centers:
				var dx: float = wx - c.x
				var dy: float = wy - c.y
				var dist: float = sqrt(dx * dx + dy * dy)
				var contrib: float = 1.0 - dist * inv_glow
				if contrib > 0.0:
					# 平方衰减让中心更亮、远端更柔
					intensity += contrib * contrib
			buf[row + x] = clampi(int(round(clampf(intensity, 0.0, 1.0) * 255.0)), 0, 255)
	return buf

# ─── Phase 1：纬度 buffer（每像素 ny ∈ [0, 1]） ──────────────────────────
# shader 用来算半球（lat_signed = ny * 2 - 1）以及纬度温度钟形曲线。

func _bake_latitude_buffer(bounds: Rect2, size: Vector2i) -> PackedFloat32Array:
	var W := size.x
	var H := size.y
	var buf := PackedFloat32Array()
	buf.resize(W * H)
	for y in range(H):
		var ny := float(y) / float(maxi(H - 1, 1))
		for x in range(W):
			buf[y * W + x] = ny
	return buf

# ─── Phase 6：风带 buffer（每像素盛行风向，RG8） ──────────────────────────
# 用 WindBelt.wind_at(ny, season_phase, lat_jitter) 算每像素风向。
# 加 _warp_noise_lo 给 ny 做小扰动（±0.04），避免风带边界呈现明显纬向条纹。
# season_phase 仅保留给 WindBelt.wind_at 的旧签名；运行时物理风场由 C++ SLP/pressure
# chain 每日写入，静态 wind_field bake 只作为缺失物理风时的纬向基线。

func _bake_wind_field(bounds: Rect2, size: Vector2i, season_phase: float) -> PackedByteArray:
	var W := size.x
	var H := size.y
	var origin := bounds.position
	var step_x := bounds.size.x / float(W)
	var step_y := bounds.size.y / float(H)
	var buf := PackedByteArray()
	buf.resize(W * H * 2)
	for y in range(H):
		var ny := float(y) / float(maxi(H - 1, 1))
		var wy_base := origin.y + (float(y) + 0.5) * step_y
		for x in range(W):
			var wx_base := origin.x + (float(x) + 0.5) * step_x
			var jitter: float = _warp_noise_lo.get_noise_2d(wx_base * 0.3, wy_base * 0.3) * 0.04
			var w: Vector2 = WindBeltScript.wind_at(ny, season_phase, jitter)
			var idx := (y * W + x) * 2
			buf[idx]     = clampi(int(round((w.x * 0.5 + 0.5) * 255.0)), 0, 255)
			buf[idx + 1] = clampi(int(round((w.y * 0.5 + 0.5) * 255.0)), 0, 255)
	return buf

# ─── Phase 3 + Phase 6：洋流向量场（风驱动 + Ekman 偏转） ─────────────────
# 现实里海面洋流方向 ≈ 风向旋转 ±45°（北半球右偏，南半球左偏）。
# 算法：
#   1) 读 wind_field_buffer 的盛行风向当主驱动力
#   2) 按半球做 Ekman 偏转
#   3) 大陆反射：靠近陆地的海面被推离陆地
#   4) 噪声扰动
# 仅海洋像素有意义；陆地像素填中性 (0.5, 0.5) = 零向量。
# 编码：dx, dy ∈ [-1, 1] → 字节 [0, 255]。

const EKMAN_DEFLECTION_RAD := 0.7854  # ~45°

# Systemic Ocean Currents：热盐驱动 / Ekman 抽吸用到的几何常量
const _THERMOHALINE_DEFAULT := 0.25
const _UPWELLING_COAST_TANGENT_MIN := 0.55   # 风向与海岸切向的对齐阈值（|dot| > this）
const _UPWELLING_HIGHLAT_ABS := 0.6          # |lat_signed| > this 且 lat_temp 够低 → 下沉候选

func _bake_ocean_currents(map: MapData, hex_size: float, world: WorldData, cfg: MapConfig = null, season_phase: float = 2.0) -> PackedByteArray:
	var W := world.derived_size.x
	var H := world.derived_size.y
	var origin := world.world_bounds.position
	var size := world.world_bounds.size
	var buf := PackedByteArray()
	buf.resize(W * H * 2)

	var sea := world.sea_level
	var height := world.height_buffer
	var hm_W := world.hm_size.x
	var hm_H := world.hm_size.y
	var wind_buf := world.wind_field_buffer
	var has_wind: bool = not wind_buf.is_empty() and wind_buf.size() >= W * H * 2
	var thermohaline_w: float = (cfg.THERMOHALINE_WEIGHT if cfg != null else _THERMOHALINE_DEFAULT)
	# Systemic Ocean Currents：主开关关闭时热盐项归零，确保烘焙结果与旧分支一致（需求 8.4）
	if cfg != null and not cfg.enable_ocean_heat_transport:
		thermohaline_w = 0.0
	# Fast-tick perf opt (F3): 提到外层判定 ocean 判据归属，避免 W*H 次 size() 比较 +
	# 重复的 hm_W==W 等比较。70 万像素累积起来这些"看似无害"的比较有几十毫秒。
	var biome_buf := world.biome_buffer
	var has_biome_buf: bool = biome_buf.size() >= W * H
	var hm_match: bool = (hm_W == W and hm_H == H)

	for y in range(H):
		var ny := float(y) / float(maxi(H - 1, 1))
		var wy_base := origin.y + (float(y) + 0.5) * size.y / float(H)
		for x in range(W):
			var wx_base := origin.x + (float(x) + 0.5) * size.x / float(W)
			var idx := y * W + x

			# 是否海洋像素
			var is_ocean := false
			if has_biome_buf:
				is_ocean = _is_water(int(biome_buf[idx]))
			elif hm_match:
				is_ocean = height[idx] < sea
			else:
				var wp := Vector2(wx_base, wy_base)
				var cube_f := _world_to_cube_f(wp, hex_size)
				var rounded := _cube_round(cube_f)
				var c: HexCell = map.get_cell_by_cube(rounded)
				is_ocean = c != null and _is_water(int(c.terrain))

			if not is_ocean:
				buf[idx * 2] = 128
				buf[idx * 2 + 1] = 128
				continue

			# 1) 风驱动：读当前物理 wind_field 当主流向。
			var wind: Vector2
			if has_wind:
				var wb_idx := idx * 2
				wind = Vector2(
					float(wind_buf[wb_idx]) / 255.0 * 2.0 - 1.0,
					float(wind_buf[wb_idx + 1]) / 255.0 * 2.0 - 1.0
				)
			else:
				wind = Vector2(1.0, 0.0)

			# 2) Ekman 偏转：北半球右偏（顺时针），南半球左偏（逆时针）
			# 屏幕坐标 +y = 下 = 南，所以"右"在屏幕上是顺时针 = +x 旋转
			# 北半球 lat_signed < 0：rot = +EKMAN_DEFLECTION_RAD
			# 南半球 lat_signed > 0：rot = -EKMAN_DEFLECTION_RAD
			var lat_signed := (ny - 0.5) * 2.0
			var ekman_sign: float = -1.0 if lat_signed < 0.0 else 1.0
			# 在 +y 朝下的屏幕系里，绕原点旋转 +θ 是顺时针。北半球应顺时针偏，所以用 -ekman_sign × θ
			var rot_angle: float = -ekman_sign * EKMAN_DEFLECTION_RAD
			var cur := wind.rotated(rot_angle)

			# 3) 噪声扰动
			cur.x += _detail_noise.get_noise_2d(wx_base * 0.6, wy_base * 0.6) * 0.30
			cur.y += _detail_noise.get_noise_2d(wx_base * 0.6 + 91.0, wy_base * 0.6 - 17.0) * 0.30

			# 4) 大陆反射：海拔梯度把洋流推离陆地
			if hm_match and x > 0 and x < W - 1 and y > 0 and y < H - 1:
				var hl: float = height[idx - 1]
				var hr: float = height[idx + 1]
				var hu: float = height[idx - W]
				var hd: float = height[idx + W]
				var grad_x := maxf(hl - sea, 0.0) - maxf(hr - sea, 0.0)
				var grad_y := maxf(hu - sea, 0.0) - maxf(hd - sea, 0.0)
				cur.x += grad_x * 4.0
				cur.y += grad_y * 4.0

			# 5) Systemic Ocean Currents：热盐驱动项（经向分量）
			# 现实里 AMOC：高纬冷水下沉 → 低纬暖水向极地回补（上层）。
			# 简化为：将表层洋流沿 -dT/dlat 方向推（冷极 → 暖赤道方向的反向：赤道 → 极）。
			# 但由于高纬同时在下沉（见 _bake_ocean_upwelling），上层净效应应从暖向冷
			# （赤道暖水被风带和热盐上层流一起推向极），与气候学一致。
			# 采用 cos^1.2 钟形作为 lat_temp 代理，经向梯度方向 = sign(lat_signed)
			# （北半球 y=屏幕向上为负方向 = 向极地 = -y；南半球向极地 = +y）。
			var pole_dir_y: float = signf(lat_signed)  # 北半球 <0 → 向极 = -y；南半球 >0 → 向极 = +y
			# 在 +y 朝下的屏幕系，北半球 pole_dir_y < 0 自然对应"向上/向北/向极"。
			# lat_temp 梯度强度：|d(cos(lat*π/2)^1.2)/dlat| ∝ |sin(lat*π)| 的近似
			var grad_mag: float = sin(absf(lat_signed) * PI)
			# 赤道暖水 → 向极地推（正经向分量）；权重由 cfg 控
			cur.y += pole_dir_y * grad_mag * thermohaline_w

			if cur.length() > 1.0:
				cur = cur.normalized()
			buf[idx * 2]     = clampi(int(round((cur.x * 0.5 + 0.5) * 255.0)), 0, 255)
			buf[idx * 2 + 1] = clampi(int(round((cur.y * 0.5 + 0.5) * 255.0)), 0, 255)
	return buf

# Systemic Ocean Currents：上升/下沉流识别（独立 pass） ─────────────────
# 输出 R8 buffer：
#   0   = 下沉流满强度（upwelling_strength → -1）
#   128 = 中性（0，包括所有陆地像素）
#   255 = 上升流满强度（+1）
#
# 识别规则：
#   (a) 高纬冷水下沉：|lat_signed| > 0.6 且 lat_temp < COLD_SINK_TEMP
#       （lat_temp 采用 _compute_temperature 的纬度分量近似 cos^1.2）。
#   (b) 沿岸 Ekman 抽吸上升：水像素邻接陆地 + 盛行风沿海岸线切向
#       + 科里奥利把表层水推离海岸。通过以下几何条件同时命中判定：
#       - 8 邻域中存在陆地像素，构造"海→陆"向量 n（指向陆地）；
#       - 风向 wind 与 n 的切向（n 顺时针旋 90°）的对齐度 |dot(wind, tangent)| > 阈值；
#       - Ekman 偏转后流向 cur（已由 _bake_ocean_currents 内部做过一致的 Ekman 处理）
#         满足 dot(cur, -n) > 0（即流向离岸）。
#
# 依赖：_bake_ocean_currents 必须先跑完（需要 biome_buffer + wind_field_buffer）。
func _bake_ocean_upwelling(map: MapData, hex_size: float, world: WorldData, cfg: MapConfig = null, season_phase: float = 2.0) -> PackedByteArray:
	var W := world.derived_size.x
	var H := world.derived_size.y
	var origin := world.world_bounds.position
	var size := world.world_bounds.size
	var buf := PackedByteArray()
	buf.resize(W * H)

	var sea := world.sea_level
	var height := world.height_buffer
	var hm_W := world.hm_size.x
	var hm_H := world.hm_size.y
	var wind_buf := world.wind_field_buffer
	var has_wind: bool = not wind_buf.is_empty() and wind_buf.size() >= W * H * 2
	var cold_sink_temp: float = (cfg.COLD_SINK_TEMP if cfg != null else -0.05)

	# 海洋像素掩码（与 _bake_ocean_currents 保持同一判据以避免分裂）
	# Fast-tick perf opt (F3): 单次合并循环。原实现先全图扫一遍建 is_ocean_arr
	# 再全图扫一遍主逻辑，70 万像素双重遍历是 ~541ms 的主要常数。改为一次
	# 遍历：第一遍只为后续 8 邻域查询而存在（必须先全图建好掩码才能查邻居），
	# 但默认值 buf[i]=128 在主扫的陆地 / 早退分支里直接跳过，避免对 70 万陆地
	# 像素重复执行 lat_signed/pow/cos 等浮点运算。
	var is_ocean_arr := PackedByteArray()
	is_ocean_arr.resize(W * H)
	# 仅这一次需要全图扫描建掩码（8 邻域查询的依赖）
	for i in range(W * H):
		var ocean := false
		if world.biome_buffer.size() > i:
			ocean = _is_water(int(world.biome_buffer[i]))
		elif hm_W == W and hm_H == H:
			ocean = height[i] < sea
		is_ocean_arr[i] = 1 if ocean else 0
		buf[i] = 128  # 默认中性（陆地 + 海洋未命中规则）

	for y in range(H):
		var ny := float(y) / float(maxi(H - 1, 1))
		# F3 优化：行级缓存与像素无关的量，避免在 W 次内层循环里反复算
		var lat_signed := (ny - 0.5) * 2.0
		var lat_signed_abs: float = absf(lat_signed)
		var lat_temp: float = DCClimateMath.lat_temp_bell(lat_signed_abs)  # 纬度温度钟形单一来源
		var temp_rel: float = lat_temp - 0.5
		var is_highlat: bool = lat_signed_abs > _UPWELLING_HIGHLAT_ABS
		var is_cold_sink: bool = is_highlat and temp_rel < cold_sink_temp
		var t_cold: float = clampf((cold_sink_temp - temp_rel) / 0.3, 0.0, 1.0) if is_cold_sink else 0.0
		var cold_sink_byte: int = clampi(int(round(128.0 * (1.0 - t_cold))), 0, 128)
		# Ekman sign 也只与半球有关（行级常量）
		var ekman_sign: float = -1.0 if lat_signed < 0.0 else 1.0
		var rot_angle: float = -ekman_sign * EKMAN_DEFLECTION_RAD
		var row_off := y * W

		for x in range(W):
			var idx := row_off + x
			# F3 优化：陆地像素直接跳（buf 已 = 128，无需任何浮点运算）
			if is_ocean_arr[idx] == 0:
				continue

			# (a) 高纬冷水下沉（行级判定已缓存）
			if is_cold_sink:
				buf[idx] = cold_sink_byte
				continue

			# (b) 沿岸 Ekman 抽吸上升
			if x <= 0 or x >= W - 1 or y <= 0 or y >= H - 1:
				continue
			# 构造"海→陆"方向 n：把 8 邻域陆地像素相对本像素的位置求和
			var nvec := Vector2.ZERO
			var has_coast := false
			for dy_i: int in [-1, 0, 1]:
				for dx_i: int in [-1, 0, 1]:
					if dx_i == 0 and dy_i == 0:
						continue
					var ni: int = (y + dy_i) * W + (x + dx_i)
					if is_ocean_arr[ni] == 0:
						nvec += Vector2(float(dx_i), float(dy_i))
						has_coast = true
			if not has_coast:
				continue
			if nvec.length_squared() < 1e-6:
				continue
			nvec = nvec.normalized()

			# 读当前物理风（无风则跳过）。
			if not has_wind:
				continue
			var wb_idx := idx * 2
			var wind := Vector2(
				float(wind_buf[wb_idx]) / 255.0 * 2.0 - 1.0,
				float(wind_buf[wb_idx + 1]) / 255.0 * 2.0 - 1.0
			)
			if wind.length_squared() < 1e-6:
				continue
			wind = wind.normalized()
			# 海岸切向（n 顺时针旋 90°）
			var tangent := Vector2(-nvec.y, nvec.x)
			var along: float = absf(wind.dot(tangent))
			if along < _UPWELLING_COAST_TANGENT_MIN:
				continue

			# Ekman 偏转方向（行级 rot_angle 已缓存，与 _bake_ocean_currents 一致）
			var cur_dir := wind.rotated(rot_angle)
			var offshore: float = cur_dir.dot(-nvec)
			if offshore <= 0.0:
				continue

			# 上升流强度 = along × offshore ∈ (0, 1]
			var up: float = clampf(along * offshore, 0.0, 1.0)
			# 128 (无) → 255 (满上升)
			buf[idx] = clampi(int(round(128.0 + 127.0 * up)), 128, 255)
	return buf

# ─── 工具 ─────────────────────────────────────────────────────────────────

static func _is_river_terminal_water(t: int) -> bool:
	return t == TerrainType.TERRAIN.OCEAN \
			or t == TerrainType.TERRAIN.COAST \
			or t == TerrainType.TERRAIN.LAKE \
			or t == TerrainType.TERRAIN.REEF \
			or t == TerrainType.TERRAIN.KELP \
			or t == TerrainType.TERRAIN.SEA_ICE

static func _is_water(t: int) -> bool:
	return t == TerrainType.TERRAIN.OCEAN \
			or t == TerrainType.TERRAIN.COAST \
			or t == TerrainType.TERRAIN.REEF \
			or t == TerrainType.TERRAIN.KELP

# ═══════════════════════════════════════════════════════════════════════════
# Physical Wind & Ocean Circulation：hex 求解 + 像素光栅化辅助
# ═══════════════════════════════════════════════════════════════════════════
#
# 本块不引入新调度——只是封装"hex 求解器结果如何写进既有 4 个 buffer
# (wind_field / ocean_current / ocean_upwelling / per-cell)"的统一入口。
# 切片化路径与一次性路径都复用同一组 helper，避免双份维护。

# 是否启用物理化路径的开关读取。失败时（cfg 不存在 / 字段缺失）默认关闭，
# 走旧 ny-only 路径，最大化向后兼容。
func _use_physical_circulation(cfg: MapConfig) -> bool:
	if cfg == null or cfg.climate_profile == null:
		return false
	return bool(cfg.climate_profile.physical_circulation_enabled)

func _calendar_days_per_year(profile = null) -> int:
	if _world_clock_ref != null and _world_clock_ref.has_method("days_per_year"):
		return clampi(int(_world_clock_ref.days_per_year()), 1, 3660)
	var cp = profile if profile != null else _climate_profile
	if cp != null and cp.get("orbital_days_per_year") != null:
		return clampi(int(cp.get("orbital_days_per_year")), 1, 3660)
	return 365

func _season_phase_to_day_of_year(season_phase: float, days_per_year: int = 0) -> int:
	var dpy: int = clampi(days_per_year if days_per_year > 0 else _calendar_days_per_year(), 1, 3660)
	var p: float = fposmod(season_phase, 4.0)
	return clampi(int(floor((p / 4.0) * float(dpy))), 0, dpy - 1)

# 强制下一次 _physical_solve_step_one 从 SLP 阶段重新开始。OceanCurrentsJob
# 在新一轮（_round_active=false → true）转换时调一次，确保季节相位变更被
# 重新求解；一次性入口 _physical_solve_for_phase 也调一次，避免和切片路径
# 残留的 _phys_stage 冲突。
## Block B（master 手册 §4）：MapGenerator 在 bake_world / 加载存档时注入 DCWorldExt。
## ext == null 时所有 C++ hook 退化为 GDScript path，行为零回归。
func set_world_ext(ext) -> void:
	# Fix #4 (2026-06-15)：enum_atlas_upload_system / enum_atlas_upload_job 每个
	# slice 都 re-inject 同一个 ext 对象，之前会把所有 diag counter 清零，
	# 导致 upwelling/DIAG#1 在 log 里出现 225 次（每个 ext 注入重置 → 每 round
	# 又打 8 行）。同 ext re-inject 不动 counter。
	if _world_ext == ext:
		return
	_world_ext = ext
	# DOTS-Final-Push 后续诊断：启动期烘焙阶段 _world_ext 还是 null（注入晚于
	# bake_world），所以 once-only 诊断旗标在启动期就被消耗（打印过 ext=false /
	# wind_cpp=false 的诊断，对运行期参考价值有限）。注入 _world_ext 时重置这些
	# 旗标，让运行期 SUS 第一次进 stage 2/6 时重新打印一次真实路径决策。
	_wind_b_first_run_logged = false
	_wind_b_path_log_count = 0
	_wind_b_commit_diag_count = 0
	_slp_path_log_count = 0
	_slp_commit_diag_count = 0
	_slp_rt_diag_count = 0
	_psi_path_log_count = 0
	_psi_commit_diag_count = 0
	_upwelling_path_logged = false
	_upwelling_diag_count = 0
	_sea_ice_path_logged = false

## DOTS-Final-Push 修复：注入 ClimateProfile 引用，让 sea_ice / albedo / veg_dyn /
## feedback 等 C++ hook 能通过 `_climate_profile` 直接读 flag，不再走错误的
## `world.get("config")` 路径。
func set_climate_profile(cp) -> void:
	_climate_profile = cp

func set_world_clock_ref(world_clock_node) -> void:
	_world_clock_ref = world_clock_node

func reset_physical_solve_state() -> void:
	_phys_stage = _PHYS_STAGE_NONE
	_phys_psi_iters_done = 0
	_phys_wind_raster_idx = 0
	_phys_wind_done_by_cpp = false
	_pending_phys_solved_phase = NAN
	_pending_psi_state = null
	_pending_wind_buf = PackedByteArray()
	# plan/dots-slp-psi-cpp — reset per-round path-decision counters & timings
	# so a freshly-bound profile flag flip takes effect immediately on the
	# next round (previous round's residual values would otherwise be sticky).
	_slp_native_ms_last = -1.0
	_slp_path_str_last = "gdscript"
	_psi_native_ms_last = -1.0
	_psi_path_str_last = "gdscript"
	_slp_thermal_p95_last = 0.0
	_slp_delta_p95_last = 0.0
	_wind_delta_p95_last = 0.0
	_ocean_delta_p95_last = 0.0
	_thermal_current_p95_last = 0.0
	_ocean_current_preclamp_p95_last = 0.0
	_ocean_current_preclamp_max_last = 0.0
	_ocean_current_clamp_count_last = 0
	_ocean_current_clamp_ratio_last = 0.0
	_ocean_current_max_magnitude_last = 0.0
	_phys_last_season_phase = NAN
	_phys_last_sim_day = -1
	_phys_last_slp_rc_ms = -1.0
	_phys_last_slp_out_size = -1
	_phys_last_slp_published_to_slot = false
	_phys_last_slp_commit_ok = false
	_phys_last_wind_rc_ms = -1.0
	_phys_last_wind_wx_size = -1
	_phys_last_wind_wy_size = -1
	_phys_last_wind_speed_out_size = -1
	_phys_last_wind_map_speed_size = -1
	_phys_last_wind_commit_ok = false

# plan/dots-slp-psi-cpp — diagnostics getters for ocean_currents_job to attach
# stage_slp_path / stage_slp_native_ms / stage_psi_path / stage_psi_native_ms
# onto its slice-result dictionary (mirrors stage_0_path / stage_8_path naming
# convention from season_refresh's _last_season_refresh_breakdown).
func get_slp_path_str() -> String:
	return _slp_path_str_last
func get_slp_native_ms() -> float:
	return _slp_native_ms_last
func get_psi_path_str() -> String:
	return _psi_path_str_last
func get_psi_native_ms() -> float:
	return _psi_native_ms_last
func get_slp_thermal_p95() -> float:
	return _slp_thermal_p95_last
func get_slp_delta_p95() -> float:
	return _slp_delta_p95_last
func get_wind_delta_p95() -> float:
	return _wind_delta_p95_last
func get_ocean_delta_p95() -> float:
	return _ocean_delta_p95_last
func get_thermal_current_p95() -> float:
	return _thermal_current_p95_last
func get_ocean_current_preclamp_p95() -> float:
	return _ocean_current_preclamp_p95_last
func get_ocean_current_preclamp_max() -> float:
	return _ocean_current_preclamp_max_last
func get_ocean_current_clamp_count() -> int:
	return _ocean_current_clamp_count_last
func get_ocean_current_clamp_ratio() -> float:
	return _ocean_current_clamp_ratio_last
func get_ocean_current_max_magnitude() -> float:
	return _ocean_current_max_magnitude_last
func _physical_stage_name(stage: int) -> String:
	match stage:
		_PHYS_STAGE_NONE: return "phys_none"
		_PHYS_STAGE_SLP: return "phys_slp"
		_PHYS_STAGE_WIND: return "phys_wind"
		_PHYS_STAGE_PSI_INIT: return "phys_psi_init"
		_PHYS_STAGE_PSI_ITERS: return "phys_psi_iters"
		_PHYS_STAGE_PSI_FINALIZE: return "phys_psi_finalize"
		_PHYS_STAGE_UPWELLING: return "phys_upwelling"
		_PHYS_STAGE_WIND_RASTER: return "phys_wind_raster"
		_PHYS_STAGE_DONE: return "phys_done"
		_: return "phys_unknown"
func get_physical_circulation_diag() -> Dictionary:
	return {
		"season_phase": _phys_last_season_phase,
		"sim_day": _phys_last_sim_day,
		"phys_stage": _phys_stage,
		"phys_stage_name": _physical_stage_name(_phys_stage),
		"slp_path": _slp_path_str_last,
		"slp_native_ms": _slp_native_ms_last,
		"slp_rc_ms": _phys_last_slp_rc_ms,
		"slp_out_size": _phys_last_slp_out_size,
		"slp_published_to_slot": _phys_last_slp_published_to_slot,
		"slp_commit_ok": _phys_last_slp_commit_ok,
		"slp_thermal_p95": _slp_thermal_p95_last,
		"slp_delta_p95": _slp_delta_p95_last,
		"wind_cpp_done": _phys_wind_done_by_cpp,
		"wind_rc_ms": _phys_last_wind_rc_ms,
		"wind_wx_size": _phys_last_wind_wx_size,
		"wind_wy_size": _phys_last_wind_wy_size,
		"wind_speed_out_size": _phys_last_wind_speed_out_size,
		"wind_map_speed_size": _phys_last_wind_map_speed_size,
		"wind_commit_ok": _phys_last_wind_commit_ok,
		"wind_delta_p95": _wind_delta_p95_last,
		"daily_wind_ran": bool(_daily_wind_diag_last.get("ran", false)),
		"daily_wind_path": str(_daily_wind_diag_last.get("path", "")),
		"daily_wind_elapsed_ms": float(_daily_wind_diag_last.get("elapsed_ms", -1.0)),
		"daily_wind_refresh_ms": float(_daily_wind_diag_last.get("refresh_ms", -1.0)),
		"daily_wind_slp_ms": float(_daily_wind_diag_last.get("slp_ms", -1.0)),
		"daily_wind_wind_ms": float(_daily_wind_diag_last.get("wind_ms", -1.0)),
		"daily_wind_stage_requested": str(_daily_wind_diag_last.get("stage_requested", "both")),
		"daily_wind_slp_ran": bool(_daily_wind_diag_last.get("slp_ran", false)),
		"daily_wind_wind_ran": bool(_daily_wind_diag_last.get("wind_ran", false)),
		"daily_wind_slp_passA_ms": float(_daily_wind_diag_last.get("slp_passA_ms", -1.0)),
		"daily_wind_slp_passB_ms": float(_daily_wind_diag_last.get("slp_passB_ms", -1.0)),
		"daily_wind_slp_norm_ms": float(_daily_wind_diag_last.get("slp_norm_ms", -1.0)),
		"daily_wind_slp_marshall_ms": float(_daily_wind_diag_last.get("slp_marshall_ms", -1.0)),
		"daily_wind_fallback_reason": str(_daily_wind_diag_last.get("fallback_reason", "")),
		# 本 tick 实跑段是否成功：ran 且无 fallback_reason。直接读 wind_commit_ok 会在
		# SLP-only 日误报 false（wind 本就没跑），故改用 ran/fallback。
		"daily_wind_commit_ok": bool(_daily_wind_diag_last.get("ran", false)) \
				and str(_daily_wind_diag_last.get("fallback_reason", "")) == "",
		"daily_wind_slp_commit_ok": bool(_daily_wind_diag_last.get("slp_commit_ok", false)),
		"daily_wind_wind_commit_ok": bool(_daily_wind_diag_last.get("wind_commit_ok", false)),
		"daily_wind_slp_delta_p95": float(_daily_wind_diag_last.get("slp_delta_p95", 0.0)),
		"daily_wind_delta_p95": float(_daily_wind_diag_last.get("wind_delta_p95", 0.0)),
		"psi_path": _psi_path_str_last,
		"psi_native_ms": _psi_native_ms_last,
		"ocean_delta_p95": _ocean_delta_p95_last,
		"thermal_current_p95": _thermal_current_p95_last,
		"ocean_current_preclamp_p95": _ocean_current_preclamp_p95_last,
		"ocean_current_preclamp_max": _ocean_current_preclamp_max_last,
		"ocean_current_clamp_count": _ocean_current_clamp_count_last,
		"ocean_current_clamp_ratio": _ocean_current_clamp_ratio_last,
		"ocean_current_max_magnitude": _ocean_current_max_magnitude_last,
	}


func run_daily_wind_field_update(map: MapData, world: WorldData, cfg: MapConfig,
		hex_size: float, season_phase: float, sim_day_override: int = -1,
		stage: String = "both") -> Dictionary:
	# plan/daily-wind-stage-split（2026-06-17）：每日 wind 权威拆成 SLP / wind 两段。
	# stage="both" 一次跑两段（首跑/回归/冷启动安全网），"slp"/"wind" 各只跑一段，
	# 让 OceanCurrentsJob 按游戏日 parity 错峰调用，把单 tick 峰值从 ~5ms 降到
	# ~3ms(SLP)/~1ms(wind)。wind-only 读 map.slp_arr（上一 SLP tick 的发布值）。
	var t0_us: int = Time.get_ticks_usec()
	var out: Dictionary = {
		"ran": false,
		"path": "daily_wind_skip",
		"stage_requested": stage,
		"slp_ran": false,
		"wind_ran": false,
		"elapsed_ms": 0.0,
		"refresh_ms": 0.0,
		"slp_ms": -1.0,
		"wind_ms": -1.0,
		"slp_stage_name": "daily_wind_slp",
		"wind_stage_name": "daily_wind_wind",
		"dominant_stage": "",
		"dominant_stage_ms": 0.0,
		"fallback_reason": "",
		"slp_commit_ok": false,
		"wind_commit_ok": false,
		"wind_cpp_done": false,
		"slp_published_to_slot": false,
		"slp_delta_p95": 0.0,
		"slp_thermal_p95": 0.0,
		"wind_delta_p95": 0.0,
		"slp_passA_ms": -1.0,
		"slp_passB_ms": -1.0,
		"slp_norm_ms": -1.0,
		"slp_marshall_ms": -1.0,
	}
	var fail := func(reason: String) -> Dictionary:
		out["fallback_reason"] = reason
		out["elapsed_ms"] = float(Time.get_ticks_usec() - t0_us) / 1000.0
		_daily_wind_diag_last = out.duplicate(true)
		return out

	if map == null or world == null or cfg == null:
		return fail.call("missing_refs")
	var profile: ClimateProfile = cfg.climate_profile if cfg != null else null
	if profile == null or not bool(profile.physical_circulation_enabled):
		out["path"] = "daily_wind_disabled"
		return fail.call("physical_disabled")
	if _world_ext == null:
		return fail.call("missing_world_ext")
	if not _world_ext.has_method("run_slp_field_pass") \
			or not _world_ext.has_method("run_wind_field_pass"):
		return fail.call("missing_cpp_method")
	if not map.has_indices():
		return fail.call("missing_indices")

	var cells: Array = map.iter_cells()
	var n_cells: int = cells.size()
	var nb_idx: PackedInt32Array = map.neighbor_indices_packed()
	if n_cells <= 0:
		return fail.call("empty_map")
	if nb_idx.size() < n_cells * 6:
		return fail.call("neighbor_indices_too_small")

	# 决定本 tick 跑哪段。wind-only 但 map.slp_arr 尺寸不齐（冷启动/换图）→ 本 tick
	# 补跑 SLP，保证 wind 永不读到空/旧尺寸 slp。
	var do_slp: bool = (stage != "wind")
	var do_wind: bool = (stage != "slp")
	if do_wind and not do_slp and map.slp_arr.size() != n_cells:
		do_slp = true
		out["stage_note"] = "wind_only_slp_primed"

	var t_refresh_us: int = Time.get_ticks_usec()
	if _world_ext.has_method("refresh_slots_from_map"):
		_world_ext.refresh_slots_from_map()
	out["refresh_ms"] = float(Time.get_ticks_usec() - t_refresh_us) / 1000.0

	var bounds: Rect2 = world.world_bounds
	var days_per_year_phys: int = _calendar_days_per_year(profile)
	var sim_day_phys: int = sim_day_override if sim_day_override >= 0 \
			else _season_phase_to_day_of_year(season_phase, days_per_year_phys)
	var world_seed_phys: int = int(world.bake_seed) if world != null else (int(cfg.seed) if cfg != null else 0)
	_phys_last_season_phase = season_phase
	_phys_last_sim_day = sim_day_phys
	out["sim_day"] = sim_day_phys

	var water_ids := PackedByteArray()
	water_ids.append(int(TerrainType.TERRAIN.OCEAN))
	water_ids.append(int(TerrainType.TERRAIN.COAST))
	water_ids.append(int(TerrainType.TERRAIN.REEF))
	water_ids.append(int(TerrainType.TERRAIN.KELP))

	var slp_out: PackedFloat32Array = PackedFloat32Array()
	if do_slp:
		var knobs_slp := {
			"n_cells": n_cells,
			"hex_size": hex_size,
			"season_phase": season_phase,
			"smooth_passes": 1,
			"world_bounds_pos_y": bounds.position.y,
			"world_bounds_size_y": bounds.size.y,
			"neighbor_indices": nb_idx,
			"water_terrain_ids": water_ids,
			"prev_slp_arr": map.slp_arr,
			"slp_lat_amp": 0.16,
			"slp_land_amp": 0.55,
			"slp_water_damp": 0.20,
			"slp_interior_boost": 1.30,
			"slp_coast_damp": 0.60,
			"slp_target_p95": 0.18,
			"days_per_year": days_per_year_phys,
			"sim_day": sim_day_phys,
			"world_seed": world_seed_phys,
			"axial_tilt_deg": profile.axial_tilt_deg,
			"insolation_daylen_amp": profile.insolation_daylen_amp,
			"wind_thermal_slp_weight": profile.wind_thermal_slp_weight,
			"slp_ice_high_weight": profile.slp_ice_high_weight,
			"slp_snow_high_weight": profile.slp_snow_high_weight,
			"slp_response_rate": profile.slp_response_rate,
			"slp_synoptic_amp": profile.slp_synoptic_amp,
			"slp_moist_low_weight": profile.slp_moist_low_weight,
		}
		var ret_slp = _world_ext.run_slp_field_pass(knobs_slp)
		if ret_slp == null or typeof(ret_slp) != TYPE_DICTIONARY:
			return fail.call("slp_non_dict")
		var rc_slp: float = float(ret_slp.get("elapsed_ms", -1.0))
		slp_out = ret_slp.get("slp_out", PackedFloat32Array())
		var slp_published_to_slot: bool = bool(ret_slp.get("published_to_slot", false))
		out["slp_ms"] = rc_slp
		out["slp_published_to_slot"] = slp_published_to_slot
		# 埋点 surface：C++ run_slp_field_pass 内部分段计时（缺失=-1，旧 DLL 兼容）。
		out["slp_passA_ms"] = float(ret_slp.get("slp_passA_ms", -1.0))
		out["slp_passB_ms"] = float(ret_slp.get("slp_passB_ms", -1.0))
		out["slp_norm_ms"] = float(ret_slp.get("slp_norm_ms", -1.0))
		out["slp_marshall_ms"] = float(ret_slp.get("slp_marshall_ms", -1.0))
		_phys_last_slp_rc_ms = rc_slp
		_phys_last_slp_out_size = slp_out.size()
		_phys_last_slp_published_to_slot = slp_published_to_slot
		_phys_last_slp_commit_ok = rc_slp >= 0.0 and slp_out.size() == n_cells
		if rc_slp < 0.0 or slp_out.size() != n_cells:
			return fail.call("slp_failed:%s" % str(ret_slp.get("reason", "")))
		if not slp_published_to_slot:
			for i_slp in range(n_cells):
				map.slp_arr[i_slp] = slp_out[i_slp]
		_slp_thermal_p95_last = float(ret_slp.get("slp_thermal_p95", 0.0))
		_slp_delta_p95_last = float(ret_slp.get("slp_delta_p95", 0.0))
		_slp_native_ms_last = rc_slp
		_slp_path_str_last = "gdext"
		out["slp_commit_ok"] = true
		out["slp_delta_p95"] = _slp_delta_p95_last
		out["slp_thermal_p95"] = _slp_thermal_p95_last
		out["slp_ran"] = true

	if do_wind:
		var slp_for_wind: PackedFloat32Array = map.slp_arr if map.slp_arr.size() == n_cells else slp_out
		var terrain_aware: bool = profile.enable_terrain_aware_wind
		var knobs_wind := {
			"n_cells": n_cells,
			"hex_size": hex_size,
			"season_phase": season_phase,
			"terrain_aware": (1 if terrain_aware else 0),
			"world_bounds_pos_y": bounds.position.y,
			"world_bounds_size_y": bounds.size.y,
			"neighbor_indices": nb_idx,
			"slp_arr": slp_for_wind,
			"water_terrain_ids": water_ids,
			"land_lf_mountain": int(LandformType.LF.MOUNTAIN),
			"land_lf_peak": int(LandformType.LF.PEAK),
			"land_lf_hill": int(LandformType.LF.HILL),
			"days_per_year": days_per_year_phys,
			"sim_day": sim_day_phys,
			"world_seed": world_seed_phys,
			"axial_tilt_deg": profile.axial_tilt_deg,
			"wind_response_rate": profile.wind_response_rate,
			"wind_synoptic_amp": profile.wind_synoptic_amp,
			"wind_belt_only_debug": profile.wind_belt_only_debug,
		}
		var rc_wind_raw = _world_ext.run_wind_field_pass(knobs_wind)
		var rc_wind: float = float(rc_wind_raw) if rc_wind_raw != null else -1.0
		out["wind_ms"] = rc_wind
		_phys_last_wind_rc_ms = rc_wind
		if rc_wind < 0.0:
			_phys_wind_done_by_cpp = false
			return fail.call("wind_failed")

		var wx_arr: PackedFloat32Array = map.wind_x_arr
		var wy_arr: PackedFloat32Array = map.wind_y_arr
		var wspd_arr: PackedFloat32Array = knobs_wind.get("wind_speed_out", PackedFloat32Array())
		_phys_last_wind_wx_size = wx_arr.size()
		_phys_last_wind_wy_size = wy_arr.size()
		_phys_last_wind_speed_out_size = wspd_arr.size()
		_phys_last_wind_map_speed_size = map.wind_speed_arr.size()
		_phys_last_wind_commit_ok = wx_arr.size() == n_cells and wy_arr.size() == n_cells \
				and wspd_arr.size() == n_cells and map.wind_speed_arr.size() == n_cells
		if not _phys_last_wind_commit_ok:
			_phys_wind_done_by_cpp = false
			return fail.call("wind_size_mismatch")

		_wind_delta_p95_last = float(knobs_wind.get("wind_delta_p95", 0.0))
		_phys_wind_done_by_cpp = true
		out["wind_cpp_done"] = true
		out["wind_commit_ok"] = true
		out["wind_delta_p95"] = _wind_delta_p95_last
		out["wind_ran"] = true

	out["ran"] = bool(out["slp_ran"]) or bool(out["wind_ran"])
	if not bool(out["ran"]):
		return fail.call("no_stage_ran")
	# path 反映本 tick 实际跑的段，供调度日志 / 归因区分。
	if bool(out["slp_ran"]) and bool(out["wind_ran"]):
		out["path"] = "gdext_daily_wind"
	elif bool(out["slp_ran"]):
		out["path"] = "gdext_daily_wind_slp"
	else:
		out["path"] = "gdext_daily_wind_wind"
	out["elapsed_ms"] = float(Time.get_ticks_usec() - t0_us) / 1000.0
	# dominant_stage：两段都跑时比大小；单段 tick 直接取该段。
	var slp_ms_v: float = float(out["slp_ms"])
	var wind_ms_v: float = float(out["wind_ms"])
	if bool(out["slp_ran"]) and (not bool(out["wind_ran"]) or slp_ms_v >= wind_ms_v):
		out["dominant_stage"] = str(out["slp_stage_name"])
		out["dominant_stage_ms"] = slp_ms_v
	else:
		out["dominant_stage"] = str(out["wind_stage_name"])
		out["dominant_stage_ms"] = wind_ms_v
	_daily_wind_diag_last = out.duplicate(true)
	return out


func prime_physical_solve_from_current_wind(map: MapData, season_phase: float) -> bool:
	if map == null:
		return false
	var n_cells: int = map.soa_size()
	if n_cells <= 0:
		return false
	if map.wind_x_arr.size() != n_cells or map.wind_y_arr.size() != n_cells \
			or map.wind_speed_arr.size() != n_cells:
		return false
	_phys_stage = _PHYS_STAGE_PSI_INIT
	_phys_psi_iters_done = 0
	_phys_wind_raster_idx = 0
	_pending_psi_state = null
	_pending_phys_solved_phase = NAN
	_phys_wind_done_by_cpp = true
	_phys_last_season_phase = season_phase
	_phys_last_wind_wx_size = map.wind_x_arr.size()
	_phys_last_wind_wy_size = map.wind_y_arr.size()
	_phys_last_wind_speed_out_size = map.wind_speed_arr.size()
	_phys_last_wind_map_speed_size = map.wind_speed_arr.size()
	_phys_last_wind_commit_ok = true
	return true

# Phys Solve Sliced 入口 ② ：把 7 阶段求解推进 1 步，返回 true 表示本轮已彻底完成
# （`_pending_phys_solved_phase = season_phase` 同时被设好）。
#
# OceanCurrentsJob 每个 run_slice 调一次 step_one，全部完成后再开始按像素区间
# 光栅化。每个 stage 的耗时上界：
#   SLP        ~5ms     —— 2400 cell × 6 邻居平滑 1 次 + 基线公式
#   WIND       ~5ms     —— 2400 cell × (6 邻居梯度 + 山脉绕流)
#   PSI_INIT   ~3ms     —— 标记水格 + 邻居索引 + curl τ
#   PSI_ITERS  ~2ms × 5 —— 8 SOR/step × 5 step = 40 iters，与一次性路径等价
#   PSI_FINAL  ~3ms     —— ψ → ocean_current + commit
#   UPWELLING  ~3ms     —— 沿岸 Ekman + 高纬冷沉
#   WIND_RASTER ~5ms    —— NaN 守门 + 风场 RG8 写盘
# 第一片最坏 ~5ms（远低于一次性路径的 ~200ms 毛刺）。
func _physical_solve_step_one(map: MapData, world: WorldData, hex_size: float,
		cfg: MapConfig, season_phase: float, solve_ocean: bool = true) -> bool:
	if world == null or map == null:
		return true
	# 同 phase 已求解过 → idempotent fast path（caller 不需要外层判断）。
	if not is_nan(_pending_phys_solved_phase) \
			and absf(_pending_phys_solved_phase - season_phase) < 0.001:
		if _phys_solve_rt_diag_count < 24:
			_phys_solve_rt_diag_count += 1
			print("[phys_solve][RT] cache_hit#%d phase=%.4f pending=%s stage=%d solve_ocean=%s" % [
				_phys_solve_rt_diag_count, season_phase,
				str(_pending_phys_solved_phase), _phys_stage, str(solve_ocean),
			])
		_phys_stage = _PHYS_STAGE_DONE
		return true
	if _phys_stage == _PHYS_STAGE_NONE:
		if _phys_solve_rt_diag_count < 24:
			_phys_solve_rt_diag_count += 1
			print("[phys_solve][RT] start#%d phase=%.4f pending=%s solve_ocean=%s ext=%s idx=%s soa=%s" % [
				_phys_solve_rt_diag_count, season_phase,
				str(_pending_phys_solved_phase), str(solve_ocean),
				str(_world_ext != null), str(map.has_indices()), str(map.has_soa()),
			])
		_phys_stage = _PHYS_STAGE_SLP
		_phys_psi_iters_done = 0
		_phys_wind_done_by_cpp = false
		_pending_psi_state = null

	var profile: ClimateProfile = cfg.climate_profile if cfg != null else null
	var terrain_aware: bool = profile.enable_terrain_aware_wind if profile != null else true
	var heat_transport: bool = profile.enable_ocean_heat_transport if profile != null else true
	var slp_wind_gdscript_required: bool = profile != null and (
			absf(profile.wind_thermal_slp_weight) > 0.0001
			or absf(profile.slp_ice_high_weight) > 0.0001
			or absf(profile.slp_snow_high_weight) > 0.0001
			or profile.wind_response_rate < 0.999)
	var ocean_gdscript_required: bool = profile != null and (
			profile.ocean_current_response_rate < 0.999
			or absf(profile.ocean_thermal_current_weight) > 0.0001
			or absf(profile.ocean_density_cold_weight) > 0.0001
			or absf(profile.ocean_density_ice_weight) > 0.0001)
	var bounds: Rect2 = world.world_bounds
	var days_per_year_phys: int = _calendar_days_per_year(profile)
	var sim_day_phys: int = _season_phase_to_day_of_year(season_phase, days_per_year_phys)
	var world_seed_phys: int = int(world.bake_seed) if world != null else (int(cfg.seed) if cfg != null else 0)
	_phys_last_season_phase = season_phase
	_phys_last_sim_day = sim_day_phys

	match _phys_stage:
		_PHYS_STAGE_SLP:
			# Fix #11 (2026-06-15) STAGE-TOTAL 埋点：记录 wrapper 整体耗时（包括 iter_cells +
			# Dict 构造 + C++ call + writeback fallback）。配合 ocean_currents/STAGE-DIAG
			# 在 SUS slice 层定位 stage 1 wall time。
			var _slp_stage_t0_us: int = Time.get_ticks_usec()
			# plan/dots-slp-psi-cpp — once-only path-decision (fronts 3 hits).
			# dots-flag-prune-pr1 round 2: use_gdext_slp_field flag 已删除——恒走 ext +
			# has_method(run_slp_field_pass) + map.has_indices() 探测分支。DIAG 块保留原状，
			# pflag_val 恒为 true 仅作为诊断记录。
			var _slp_done_by_cpp: bool = false
			var _slp_native_ms: float = -1.0
			if _slp_path_log_count < 3:
				_slp_path_log_count += 1
				var _s_prof_ok: bool = profile != null
				var _s_pflag_attr_ok: bool = true  # 已折叠：flag 字段已删，不再检查
				var _s_pflag_val_ok: bool = true  # 已折叠：恒 true
				var _s_pext_ok: bool = _world_ext != null
				var _s_pmethod_ok: bool = _s_pext_ok and _world_ext.has_method("run_slp_field_pass")
				var _s_idx_ok: bool = map != null and map.has_indices()
				var _s_gate_pass: bool = _s_pmethod_ok and _s_idx_ok
				print("[slp_field] path-decision call#%d: prof=%s pflag_attr=%s pflag_val=%s ext=%s method=%s idx=%s -> cpp_gate=%s" % [
					_slp_path_log_count,
					str(_s_prof_ok), str(_s_pflag_attr_ok), str(_s_pflag_val_ok),
					str(_s_pext_ok), str(_s_pmethod_ok), str(_s_idx_ok), str(_s_gate_pass)
				])
			if _world_ext != null and _world_ext.has_method("run_slp_field_pass") \
					and map != null and map.has_indices():
				var cells_for_slp_cpp: Array = map.iter_cells()
				var n_slp: int = cells_for_slp_cpp.size()
				var nb_idx_for_slp: PackedInt32Array = map.neighbor_indices_packed()
				if n_slp > 0 and nb_idx_for_slp.size() >= n_slp * 6:
					var water_ids_slp := PackedByteArray()
					water_ids_slp.append(int(TerrainType.TERRAIN.OCEAN))
					water_ids_slp.append(int(TerrainType.TERRAIN.COAST))
					water_ids_slp.append(int(TerrainType.TERRAIN.REEF))
					water_ids_slp.append(int(TerrainType.TERRAIN.KELP))
					var knobs_slp := {
						"n_cells": n_slp,
						"hex_size": hex_size,
						"season_phase": season_phase,
						"smooth_passes": 1,  # mirrors PhysCircSolverScript._SLP_SMOOTH_PASSES
						"world_bounds_pos_y": bounds.position.y,
						"world_bounds_size_y": bounds.size.y,
						"neighbor_indices": nb_idx_for_slp,
						"water_terrain_ids": water_ids_slp,
						"prev_slp_arr": map.slp_arr,
						"slp_lat_amp": 0.16,
						"slp_land_amp": 0.55,
						"slp_water_damp": 0.20,
						"slp_interior_boost": 1.30,
						"slp_coast_damp": 0.60,
						"slp_target_p95": 0.18,
						"days_per_year": days_per_year_phys,
						"sim_day": sim_day_phys,
						"world_seed": world_seed_phys,
						"axial_tilt_deg": profile.axial_tilt_deg if profile != null else 23.5,
						"insolation_daylen_amp": profile.insolation_daylen_amp if profile != null else 0.35,
					}
					if profile != null:
						knobs_slp["wind_thermal_slp_weight"] = profile.wind_thermal_slp_weight
						knobs_slp["slp_ice_high_weight"] = profile.slp_ice_high_weight
						knobs_slp["slp_snow_high_weight"] = profile.slp_snow_high_weight
						knobs_slp["slp_response_rate"] = profile.slp_response_rate
						knobs_slp["slp_synoptic_amp"] = profile.slp_synoptic_amp
						knobs_slp["slp_moist_low_weight"] = profile.slp_moist_low_weight
					var ret_slp = _world_ext.run_slp_field_pass(knobs_slp)
					if ret_slp != null and typeof(ret_slp) == TYPE_DICTIONARY:
						var rc_slp: float = float(ret_slp.get("elapsed_ms", -1.0))
						var slp_out: PackedFloat32Array = ret_slp.get("slp_out", PackedFloat32Array())
						var slp_published_to_slot: bool = bool(ret_slp.get("published_to_slot", false))
						_phys_last_slp_rc_ms = rc_slp
						_phys_last_slp_out_size = slp_out.size()
						_phys_last_slp_published_to_slot = slp_published_to_slot
						_phys_last_slp_commit_ok = rc_slp >= 0.0 and slp_out.size() == n_slp
						if _slp_commit_diag_count < 3:
							_slp_commit_diag_count += 1
							print("[slp_field] commit-diag call#%d: rc=%.3f slp_out=%d n_cells=%d map_slp=%d published=%s" % [
								_slp_commit_diag_count, rc_slp, slp_out.size(), n_slp, map.slp_arr.size(),
								str(slp_published_to_slot)
							])
						# 运行期根因诊断（每 200 次调用 + 前 5 次打印一次），定位 SLP 冻结：
						# - commit_ok=true  → 已写回 map.slp_arr，理应随 season 变化
						# - rc<0            → C++ pass 内部走了 fallback(返回 dict 但无效)
						# - size_mismatch   → commit gate 因 slp_out.size()!=n_cells 拦截
						_slp_rt_diag_count += 1
						if _slp_rt_diag_count <= 5 or _slp_rt_diag_count % 200 == 0:
							var _commit_ok: bool = rc_slp >= 0.0 and slp_out.size() == n_slp
							var _reason: String = "commit_ok" if _commit_ok else \
								("rc<0(cpp_fallback)" if rc_slp < 0.0 else "size_mismatch(gate_block)")
							print("[slp_field][RT-DIAG] call#%d phase=%.4f rc=%.3f slp_out=%d n=%d published=%s -> %s" % [
								_slp_rt_diag_count, season_phase, rc_slp, slp_out.size(), n_slp,
								str(slp_published_to_slot), _reason
							])
						if rc_slp >= 0.0 and slp_out.size() == n_slp:
							_slp_thermal_p95_last = float(ret_slp.get("slp_thermal_p95", 0.0))
							_slp_delta_p95_last = float(ret_slp.get("slp_delta_p95", 0.0))
							if not slp_published_to_slot:
								for _i_slp_arr in range(n_slp):
									map.slp_arr[_i_slp_arr] = slp_out[_i_slp_arr]
							_slp_done_by_cpp = true
							_slp_native_ms = rc_slp
							if not _slp_first_run_logged:
								_slp_first_run_logged = true
								print("[slp_field] gdext path ACTIVE — first run elapsed=%.2fms (legacy GDScript baseline ~36ms; target < 3ms)" % rc_slp)
			if not _slp_done_by_cpp:
				_phys_last_slp_rc_ms = -1.0
				_phys_last_slp_out_size = -1
				_phys_last_slp_published_to_slot = false
				_phys_last_slp_commit_ok = false
				if _slp_path_log_count > 0 and _slp_path_log_count <= 3:
					print("[slp_field] FALLBACK to GDScript solve_slp_field (call#%d) — see preceding path-decision / commit-diag for reason" % _slp_path_log_count)
				# 运行期诊断：进入此分支即说明 C++ commit 未成功（没进 C++ 分支 /
				# 返回 null / gate 拦截）。打印 has_soa——若为 true，下面镜像写回被跳过，
				# GDScript 只写了 HexCell.slp(SoA)，若 SoA 与 map.slp_arr 不同步则冻结。
				_slp_rt_diag_count += 1
				if _slp_rt_diag_count <= 5 or _slp_rt_diag_count % 200 == 0:
					print("[slp_field][RT-DIAG] call#%d phase=%.4f -> GDSCRIPT_FALLBACK has_soa=%s (镜像写回 %s)" % [
						_slp_rt_diag_count, season_phase, str(map.has_soa()),
						"SKIP" if map.has_soa() else "DONE"
					])
				PhysCircSolverScript.solve_slp_field(map, hex_size, bounds, season_phase, 1, profile)
				# Fallback path 内部用 HexCell.slp setter（_facade_enabled=true 时已
				# 写 SoA），这里仅在 facade 关闭/非完整迁移的兼容窗口里做兜底镜像。
				# 用 has_soa() 守门避免无谓 2400× loop。
				if not map.has_soa():
					var cells_for_slp: Array = map.iter_cells() if map.has_indices() else map.all_cells()
					if map.slp_arr.size() == cells_for_slp.size():
						for _i_slp_commit in range(cells_for_slp.size()):
							var _c_slp_commit: HexCell = cells_for_slp[_i_slp_commit]
							map.slp_arr[_i_slp_commit] = _c_slp_commit.slp if _c_slp_commit != null else 0.0
			_slp_native_ms_last = _slp_native_ms
			_slp_path_str_last = "gdext" if _slp_done_by_cpp else "gdscript"
			var _slp_stage_total_ms: float = float(Time.get_ticks_usec() - _slp_stage_t0_us) / 1000.0
			# 前 3 次必打 + >= 5ms 异常打。配合 [ocean_currents/STAGE-DIAG] 做交叉验证。
			# 注意：call#1 内还有 path-decision / commit-diag / RT-DIAG / ACTIVE 共 4 个 print，
			#       Windows stdout flush 每行 ~12-15ms → call#1 wall 会被污染 ~50-60ms。
			#       真实 stage wall ≈ call#1_wall - 15ms × (该 call 同 stage 内已打印的 print 行数)。
			#       call#2+ 后 path-decision / commit-diag 命中前 3 次封顶，wall 才反映真实开销。
			if _slp_path_log_count <= 3 or _slp_stage_total_ms >= 5.0:
				print("[slp_field/STAGE-TOTAL] call#%d wall=%.2fms native=%.2fms path=%s commit_ok=%s (call#1 wall pollution: ~15ms/print × 4 prints; trust call#4+ or wall>=5ms warn)" % [
					_slp_path_log_count, _slp_stage_total_ms,
					float(_slp_native_ms),
					_slp_path_str_last,
					str(_phys_last_slp_commit_ok),
				])
			_phys_stage = _PHYS_STAGE_WIND
		_PHYS_STAGE_WIND:
			# Fix #11 (2026-06-15) STAGE-TOTAL 埋点：见 _PHYS_STAGE_SLP。
			var _wind_stage_t0_us: int = Time.get_ticks_usec()
			# Block B（master 手册 §4 / dots-wind-validation.md）：wind solver C++ 化 hook。
			# dots-flag-prune-pr1 round 2: use_gdext_wind_field flag 已删除——恒走 ext +
			# has_method(run_wind_field_pass) 探测分支（C++ 返回 fallback 或 ext 未 bind 时
			# 透明 fallback 到 GDScript solve_wind_field）。DIAG 块保留原状。
			var _wind_done_by_cpp: bool = false
			_phys_last_wind_rc_ms = -1.0
			_phys_last_wind_wx_size = -1
			_phys_last_wind_wy_size = -1
			_phys_last_wind_speed_out_size = -1
			_phys_last_wind_map_speed_size = -1
			_phys_last_wind_commit_ok = false
			# DOTS-Final-Push 后续诊断 — once-only 路径决策（仿 upwelling stage 6）。
			# 与 _wind_b_first_run_logged 不同：那个只在 C++ 路径首次成功后打印；
			# 这里在 stage 2 第一次执行时无条件打印各子条件命中状态。
			if _wind_b_path_log_count < 3:
				_wind_b_path_log_count += 1
				var _w_prof_ok: bool = profile != null
				var _w_pflag_attr_ok: bool = true  # 已折叠：flag 字段已删
				var _w_pflag_val_ok: bool = true  # 已折叠：恒 true
				var _w_pext_ok: bool = _world_ext != null
				var _w_pmethod_ok: bool = _w_pext_ok and _world_ext.has_method("run_wind_field_pass")
				var _w_idx_ok: bool = map != null and map.has_indices()
				var _w_gate_pass: bool = _w_pmethod_ok and _w_idx_ok
				print("[wind_field/B] path-decision call#%d: prof=%s pflag_attr=%s pflag_val=%s ext=%s method=%s idx=%s -> cpp_gate=%s" % [
					_wind_b_path_log_count,
					str(_w_prof_ok), str(_w_pflag_attr_ok), str(_w_pflag_val_ok),
					str(_w_pext_ok), str(_w_pmethod_ok), str(_w_idx_ok), str(_w_gate_pass)
				])
			if _world_ext != null and _world_ext.has_method("run_wind_field_pass"):
				var cells_for_wind: Array = map.iter_cells() if map.has_indices() else map.all_cells()
				var n_wind: int = cells_for_wind.size()
				var nb_idx_for_wind: PackedInt32Array = map.neighbor_indices_packed() if map.has_indices() else PackedInt32Array()
				var fast_indexed_wind: bool = nb_idx_for_wind.size() >= n_wind * 6
				if fast_indexed_wind and n_wind > 0:
					var slp_arr: PackedFloat32Array = map.slp_arr if map.slp_arr.size() == n_wind else PackedFloat32Array()
					if slp_arr.is_empty():
						slp_arr.resize(n_wind)
						for _i_slp in range(n_wind):
							var _c_slp: HexCell = cells_for_wind[_i_slp]
							slp_arr[_i_slp] = _c_slp.slp if _c_slp != null else 0.0
					# water_terrain_ids：与 PhysicalCirculationSolver._is_water_terrain 1:1
					var water_ids := PackedByteArray()
					water_ids.append(int(TerrainType.TERRAIN.OCEAN))
					water_ids.append(int(TerrainType.TERRAIN.COAST))
					water_ids.append(int(TerrainType.TERRAIN.REEF))
					water_ids.append(int(TerrainType.TERRAIN.KELP))
					var knobs_wind := {
						"n_cells": n_wind,
						"hex_size": hex_size,
						"season_phase": season_phase,
						"terrain_aware": (1 if terrain_aware else 0),
						"world_bounds_pos_y": bounds.position.y,
						"world_bounds_size_y": bounds.size.y,
						"neighbor_indices": nb_idx_for_wind,
						"slp_arr": slp_arr,
						"water_terrain_ids": water_ids,
						"land_lf_mountain": int(LandformType.LF.MOUNTAIN),
						"land_lf_peak": int(LandformType.LF.PEAK),
						"land_lf_hill": int(LandformType.LF.HILL),
						"days_per_year": days_per_year_phys,
						"sim_day": sim_day_phys,
						"world_seed": world_seed_phys,
						"axial_tilt_deg": profile.axial_tilt_deg if profile != null else 23.5,
					}
					if profile != null:
						knobs_wind["wind_response_rate"] = profile.wind_response_rate
						knobs_wind["wind_synoptic_amp"] = profile.wind_synoptic_amp
						knobs_wind["wind_belt_only_debug"] = profile.wind_belt_only_debug
					var _rc_wind = _world_ext.run_wind_field_pass(knobs_wind)
					_phys_last_wind_rc_ms = float(_rc_wind) if _rc_wind != null else -1.0
					if _rc_wind != null and float(_rc_wind) >= 0.0:
						# C++ 已写入并 flush wind_x/y/speed；这里保留 size gate 与
						# 非 PSI fallback 的 HexCell 同步，避免成功路径重复写 PackedArray。
						var wx_arr: PackedFloat32Array = map.wind_x_arr
						var wy_arr: PackedFloat32Array = map.wind_y_arr
						var wspd_arr: PackedFloat32Array = knobs_wind.get("wind_speed_out", PackedFloat32Array())
						_phys_last_wind_wx_size = wx_arr.size()
						_phys_last_wind_wy_size = wy_arr.size()
						_phys_last_wind_speed_out_size = wspd_arr.size()
						_phys_last_wind_map_speed_size = map.wind_speed_arr.size()
						_phys_last_wind_commit_ok = wx_arr.size() == n_wind and wy_arr.size() == n_wind \
								and wspd_arr.size() == n_wind and map.wind_speed_arr.size() == n_wind
						# DOTS-Final-Push 后续诊断：commit size 检查是 silent
						# fallback 唯一缺口（rc>=0 但 size 不齐 → _phys_wind_done_by_cpp
						# 仍是 false，stage 6 走 GDScript upwelling 92ms）。一次性 print。
						if _wind_b_commit_diag_count < 3:
							_wind_b_commit_diag_count += 1
							print("[wind_field/B] commit-diag call#%d: rc=%.3f n_wind=%d wx=%d wy=%d wspd=%d map_wspd=%d" % [
								_wind_b_commit_diag_count, float(_rc_wind), n_wind, wx_arr.size(), wy_arr.size(), wspd_arr.size(), map.wind_speed_arr.size()
							])
						if _phys_last_wind_commit_ok:
							var psi_cpp_expected: bool = solve_ocean and heat_transport \
									and _world_ext != null and _world_ext.has_method("run_psi_solver_pass")
							if not psi_cpp_expected:
								for _i_w in range(n_wind):
									var _c_w: HexCell = cells_for_wind[_i_w]
									if _c_w != null:
										_c_w.wind_vector = Vector2(wx_arr[_i_w], wy_arr[_i_w])
										_c_w.wind_speed = wspd_arr[_i_w]
							_wind_delta_p95_last = float(knobs_wind.get("wind_delta_p95", 0.0))
							_wind_done_by_cpp = true
							_phys_wind_done_by_cpp = true
							if not _wind_b_first_run_logged:
								_wind_b_first_run_logged = true
								print("[wind_field/B] gdext path ACTIVE — first run elapsed=%.2fms (legacy GDScript baseline ≈ 35ms; charter §7 / dots-wind-validation.md target < 5ms)" % float(_rc_wind))
			if not _wind_done_by_cpp:
				_phys_wind_done_by_cpp = false
				# DOTS-Final-Push 后续诊断：fallback 分支也打前 3 次，配合 path-decision /
				# commit-diag 形成完整诊断三角（gate 失败 / commit size mismatch / 默默 fallback）。
				if _wind_b_path_log_count > 0 and _wind_b_path_log_count <= 3:
					print("[wind_field/B] FALLBACK to GDScript solve_wind_field (call#%d) — see preceding path-decision / commit-diag for reason" % _wind_b_path_log_count)
				PhysCircSolverScript.solve_wind_field(map, hex_size, bounds, season_phase, terrain_aware, profile)
			var _wind_stage_total_ms: float = float(Time.get_ticks_usec() - _wind_stage_t0_us) / 1000.0
			if _wind_b_path_log_count <= 3 or _wind_stage_total_ms >= 5.0:
				print("[wind_field/STAGE-TOTAL] call#%d wall=%.2fms native=%.2fms path=%s commit_ok=%s" % [
					_wind_b_path_log_count, _wind_stage_total_ms,
					float(_phys_last_wind_rc_ms),
					"gdext" if _wind_done_by_cpp else "gdscript",
					str(_phys_last_wind_commit_ok),
				])
			if not solve_ocean:
				_pending_psi_state = null
				_phys_psi_iters_done = 0
				_pending_phys_solved_phase = season_phase
				_phys_stage = _PHYS_STAGE_DONE
				return true
			if heat_transport:
				_phys_stage = _PHYS_STAGE_PSI_INIT
			else:
				# 跳过 ψ 求解，直接走 fallback ocean current；下一片做 upwelling。
				_pending_psi_state = null
				PhysCircSolverScript.solve_ocean_current_fallback(map, hex_size, bounds, cfg, profile)
				_phys_stage = _PHYS_STAGE_UPWELLING
		_PHYS_STAGE_PSI_INIT:
			# plan/dots-slp-psi-cpp — once-only path-decision (fronts 3 hits).
			# dots-flag-prune-pr1 round 2: use_gdext_psi_solver flag 已删除——恒走 ext +
			# has_method(run_psi_solver_pass) + heat_transport + map.has_indices() 探测分支。
			var _psi_done_by_cpp: bool = false
			var _psi_native_ms: float = -1.0
			if _psi_path_log_count < 3:
				_psi_path_log_count += 1
				var _p_prof_ok: bool = profile != null
				var _p_pflag_attr_ok: bool = true  # 已折叠：flag 字段已删
				var _p_pflag_val_ok: bool = true  # 已折叠：恒 true
				var _p_pext_ok: bool = _world_ext != null
				var _p_pmethod_ok: bool = _p_pext_ok and _world_ext.has_method("run_psi_solver_pass")
				var _p_idx_ok: bool = map != null and map.has_indices()
				var _p_heat_ok: bool = heat_transport
				var _p_gate_pass: bool = _p_pmethod_ok and _p_idx_ok and _p_heat_ok
				print("[psi_solver] path-decision call#%d: prof=%s pflag_attr=%s pflag_val=%s ext=%s method=%s idx=%s heat=%s -> cpp_gate=%s" % [
					_psi_path_log_count,
					str(_p_prof_ok), str(_p_pflag_attr_ok), str(_p_pflag_val_ok),
					str(_p_pext_ok), str(_p_pmethod_ok), str(_p_idx_ok),
					str(_p_heat_ok), str(_p_gate_pass)
				])
			if heat_transport \
					and _world_ext != null and _world_ext.has_method("run_psi_solver_pass") \
					and map != null and map.has_indices():
				# Fix #11 grounding (2026-06-15)：精确测量 PSI_INIT wrapper 时间分布。
				# log 实测 phys_slice elapsed=8-13ms，C++ kernel 仅 0.4ms。剩 7-12ms
				# 在哪？分 4 段测量：
				#   T1_prepack: iter_cells + neighbor_indices_packed + wind PackedArray ref/build
				#   T2_knobs:   构造 knobs Dictionary（25+ 字段）
				#   T3_call:    跨 GDExtension run_psi_solver_pass C++ kernel
				#   T4_writeback: 解 ret Dict + 2400 loop 写 wind_stress_curl_arr / ocean_psi_arr
				# 前 3 次完整 dump，之后只在异常 (>5ms) 时打印。
				var _psi_t_stage_us: int = Time.get_ticks_usec()
				var _psi_t1_us: int = Time.get_ticks_usec()
				var cells_for_psi: Array = map.iter_cells()
				var n_psi: int = cells_for_psi.size()
				var nb_idx_for_psi: PackedInt32Array = map.neighbor_indices_packed()
				# Pack current-frame wind state. C++ wind path already wrote map.wind_x/y
				# and map.wind_speed_arr, so reuse SoA directly and avoid 2400 facade reads.
				var wx_arr_psi: PackedFloat32Array = PackedFloat32Array()
				var wy_arr_psi: PackedFloat32Array = PackedFloat32Array()
				var wspd_arr_psi: PackedFloat32Array = PackedFloat32Array()
				if _phys_wind_done_by_cpp and map.wind_x_arr.size() == n_psi \
						and map.wind_y_arr.size() == n_psi and map.wind_speed_arr.size() == n_psi:
					wx_arr_psi = map.wind_x_arr
					wy_arr_psi = map.wind_y_arr
					wspd_arr_psi = map.wind_speed_arr
				else:
					wx_arr_psi.resize(n_psi)
					wy_arr_psi.resize(n_psi)
					wspd_arr_psi.resize(n_psi)
					for _i_w_pack in range(n_psi):
						var _c_wp: HexCell = cells_for_psi[_i_w_pack]
						if _c_wp == null:
							wx_arr_psi[_i_w_pack] = 0.0
							wy_arr_psi[_i_w_pack] = 0.0
							wspd_arr_psi[_i_w_pack] = 0.0
						else:
							wx_arr_psi[_i_w_pack] = _c_wp.wind_vector.x
							wy_arr_psi[_i_w_pack] = _c_wp.wind_vector.y
							wspd_arr_psi[_i_w_pack] = _c_wp.wind_speed
				if n_psi > 0 and nb_idx_for_psi.size() >= n_psi * 6:
					var _psi_t1_ms: float = float(Time.get_ticks_usec() - _psi_t1_us) / 1000.0
					var _psi_t2_us: int = Time.get_ticks_usec()
					var water_ids_psi := PackedByteArray()
					water_ids_psi.append(int(TerrainType.TERRAIN.OCEAN))
					water_ids_psi.append(int(TerrainType.TERRAIN.COAST))
					water_ids_psi.append(int(TerrainType.TERRAIN.REEF))
					water_ids_psi.append(int(TerrainType.TERRAIN.KELP))
					var cold_sink_temp: float = -0.05
					if cfg != null and "COLD_SINK_TEMP" in cfg:
						cold_sink_temp = float(cfg.COLD_SINK_TEMP)
					var knobs_psi := {
						"n_cells": n_psi,
						"hex_size": hex_size,
						"world_bounds_pos_y": bounds.position.y,
						"world_bounds_size_y": bounds.size.y,
						"neighbor_indices": nb_idx_for_psi,
						"water_terrain_ids": water_ids_psi,
						"wind_x_arr": wx_arr_psi,
						"wind_y_arr": wy_arr_psi,
						"wind_speed_arr": wspd_arr_psi,
						"psi_total_iters": _PHYS_PSI_TOTAL_ITERS,
						# plan/psi-warm-start：SOR 用上一轮 cell_ocean_psi slot 作初值；
						# 默认开，profile 可显式关闭做冷启动对照。
						"psi_warm_start": bool(profile.psi_warm_start) if profile != null and profile.get("psi_warm_start") != null else true,
						"psi_sor_omega": 1.4,
						"psi_r_base": 0.18,
						"psi_beta_floor": 0.05,
						"psi_source_scale": float(profile.ocean_psi_source_scale) if profile != null and profile.get("ocean_psi_source_scale") != null else 0.08,
						"ocean_current_scale": float(profile.ocean_current_scale) if profile != null and profile.get("ocean_current_scale") != null else 0.30,
						"ocean_current_max_magnitude": float(profile.ocean_current_max_magnitude) if profile != null and profile.get("ocean_current_max_magnitude") != null else 0.50,
						"thermohaline_weight": 0.25,
						"upwelling_highlat_abs": 0.75,
						"cold_sink_temp": cold_sink_temp,
					}
					if profile != null:
						knobs_psi["ocean_current_response_rate"] = profile.ocean_current_response_rate
						knobs_psi["ocean_thermal_current_weight"] = profile.ocean_thermal_current_weight
						knobs_psi["ocean_density_cold_weight"] = profile.ocean_density_cold_weight
						knobs_psi["ocean_density_ice_weight"] = profile.ocean_density_ice_weight
					var _psi_t2_ms: float = float(Time.get_ticks_usec() - _psi_t2_us) / 1000.0
					var _psi_t3_us: int = Time.get_ticks_usec()
					var ret_psi = _world_ext.run_psi_solver_pass(knobs_psi)
					var _psi_t3_ms: float = float(Time.get_ticks_usec() - _psi_t3_us) / 1000.0
					# Fix #11 (2026-06-15)：published_to_slot=true 时 C++ 已写 slot + flush 到 map.*，
					# GDScript 跳过 4 次 PackedArray dict.get（每次会 deep copy 2400 floats）+ 2400-loop writeback。
					# 实测 fast path STAGE 从 15ms → 0.67ms（kernel 0.45ms + 边界 0.16ms + dict 0.06ms）。
					# fallback 路径（rc>=0 但 published_to_slot=false）走 4 array get + 2400-loop 兜底，
					# 兼容旧 DLL（不认识 curl/psi slot）的情况。
					var _psi_t4_us: int = Time.get_ticks_usec()
					if ret_psi != null and typeof(ret_psi) == TYPE_DICTIONARY:
						var rc_psi: float = float(ret_psi.get("elapsed_ms", -1.0))
						var psi_published_to_slot: bool = bool(ret_psi.get("published_to_slot", false))
						var curl_out: PackedFloat32Array
						var psi_out: PackedFloat32Array
						var ocx_out: PackedFloat32Array
						var ocy_out: PackedFloat32Array
						if not psi_published_to_slot:
							curl_out = ret_psi.get("wind_stress_curl_out", PackedFloat32Array())
							psi_out = ret_psi.get("ocean_psi_out", PackedFloat32Array())
							ocx_out = ret_psi.get("ocean_current_x_out", PackedFloat32Array())
							ocy_out = ret_psi.get("ocean_current_y_out", PackedFloat32Array())
						# commit-diag print 移到 STAGE 测量外（Windows ConHost stdout flush ~15ms/line 会污染 T4）
						var _do_commit_diag_print: bool = (_psi_commit_diag_count < 3)
						if _do_commit_diag_print:
							_psi_commit_diag_count += 1
						if rc_psi >= 0.0 and (psi_published_to_slot or (
								curl_out.size() == n_psi and psi_out.size() == n_psi
								and ocx_out.size() == n_psi and ocy_out.size() == n_psi)):
							_ocean_delta_p95_last = float(ret_psi.get("ocean_delta_p95", 0.0))
							_thermal_current_p95_last = float(ret_psi.get("thermal_current_p95", 0.0))
							_ocean_current_preclamp_p95_last = float(ret_psi.get("ocean_current_preclamp_p95", 0.0))
							_ocean_current_preclamp_max_last = float(ret_psi.get("ocean_current_preclamp_max", 0.0))
							_ocean_current_clamp_count_last = int(ret_psi.get("ocean_current_clamp_count", 0))
							_ocean_current_clamp_ratio_last = float(ret_psi.get("ocean_current_clamp_ratio", 0.0))
							_ocean_current_max_magnitude_last = float(ret_psi.get("ocean_current_max_magnitude", 0.0))
							var _has_psi_debug_arr: bool = map.wind_stress_curl_arr.size() == n_psi \
									and map.ocean_psi_arr.size() == n_psi
							# Fix #11 (2026-06-15)：published_to_slot=true 时 C++ 已写 slot + flush 到 map.*，
							# GDScript 完全跳过 2400 loop writeback。fallback 路径走兜底循环（旧 DLL 不认识 slot）。
							if not psi_published_to_slot:
								for _i_pc in range(n_psi):
									map.ocean_current_x_arr[_i_pc] = ocx_out[_i_pc]
									map.ocean_current_y_arr[_i_pc] = ocy_out[_i_pc]
									if _has_psi_debug_arr:
										map.wind_stress_curl_arr[_i_pc] = curl_out[_i_pc]
										map.ocean_psi_arr[_i_pc] = psi_out[_i_pc]
							_psi_done_by_cpp = true
							_psi_native_ms = rc_psi
							var _psi_t4_ms: float = float(Time.get_ticks_usec() - _psi_t4_us) / 1000.0
							var _psi_stage_ms: float = float(Time.get_ticks_usec() - _psi_t_stage_us) / 1000.0
							# Fix #11 grounding：前 3 次完整打印，之后异常 (>5ms) 才打。
							# 注意：commit-diag 打印移到 STAGE 测量之后，避免 stdout flush ~15ms 污染 T4。
							# Fix #11 second pass (2026-06-16)：原 `_psi_path_log_count <= 3` 误用——
							# 该计数只在 line 5555 path-decision 块自增（封顶 3），不在 BREAKDOWN 块自增，
							# 所以 BREAKDOWN 永远命中 `<=3` 一直 print，mobile 上 61 次 / 2min 污染 logcat。
							# 改为独立 _psi_breakdown_log_count 计数 + 5ms warn 阈值（mobile 实测 STAGE
							# 0.6-1.2ms，不会触发 warn）。
							_psi_breakdown_log_count += 1
							if PKLog.enabled and (_psi_breakdown_log_count <= 3 or _psi_stage_ms > 5.0):
								print("[psi_solver/BREAKDOWN] call#%d STAGE=%.2fms T1_prepack=%.2fms T2_knobs=%.2fms T3_call=%.2fms (kernel=%.2fms gdext_overhead=%.2fms) T4_writeback=%.2fms (n_psi=%d published=%s has_debug=%s)" % [
									_psi_breakdown_log_count,
									_psi_stage_ms, _psi_t1_ms, _psi_t2_ms, _psi_t3_ms, rc_psi, maxf(0.0, _psi_t3_ms - rc_psi),
									_psi_t4_ms, n_psi, str(psi_published_to_slot), str(_has_psi_debug_arr)
								])
							if not _psi_first_run_logged:
								_psi_first_run_logged = true
								print("[psi_solver] gdext path ACTIVE — first run elapsed=%.2fms (legacy GDScript stage3+4+5 baseline ~32+ms; target < 5ms)" % rc_psi)
							# 推迟到 STAGE 测量之外的 commit-diag print（避免 print stdout flush 污染 T4）
							if _do_commit_diag_print:
								print("[psi_solver] commit-diag call#%d: rc=%.3f n_water=%d n_cells=%d published=%s" % [
									_psi_commit_diag_count, rc_psi,
									int(ret_psi.get("n_water", -1)),
									n_psi, str(psi_published_to_slot)
								])
			_psi_native_ms_last = _psi_native_ms
			_psi_path_str_last = "gdext" if _psi_done_by_cpp else "gdscript"
			if _psi_done_by_cpp:
				# Skip stage 4 / 5: C++ pass did init+iters+finalize+commit.
				_pending_psi_state = null
				_phys_psi_iters_done = _PHYS_PSI_TOTAL_ITERS
				_phys_stage = _PHYS_STAGE_UPWELLING
			else:
				if _psi_path_log_count > 0 and _psi_path_log_count <= 3:
					print("[psi_solver] FALLBACK to GDScript init/iters/finalize (call#%d) — see preceding path-decision / commit-diag for reason" % _psi_path_log_count)
				if _phys_wind_done_by_cpp and map.wind_x_arr.size() >= map.soa_size() \
						and map.wind_y_arr.size() >= map.soa_size() \
						and map.wind_speed_arr.size() >= map.soa_size():
					var cells_sync_wind: Array = map.iter_cells() if map.has_indices() else map.all_cells()
					for _i_sync_wind in range(map.soa_size()):
						var _c_sync_wind: HexCell = cells_sync_wind[_i_sync_wind]
						if _c_sync_wind != null:
							_c_sync_wind.wind_vector = Vector2(map.wind_x_arr[_i_sync_wind], map.wind_y_arr[_i_sync_wind])
							_c_sync_wind.wind_speed = map.wind_speed_arr[_i_sync_wind]
				_pending_psi_state = PhysCircSolverScript.init_psi_solver(map, hex_size, bounds)
				_phys_psi_iters_done = 0
				_phys_stage = _PHYS_STAGE_PSI_ITERS
		_PHYS_STAGE_PSI_ITERS:
			# Fix #11 (2026-06-15) STAGE-TOTAL 埋点：mobile 上 C++ 路径 PSI_INIT 跳过 ITERS/
			# FINALIZE，进这里就说明走了 fallback（GDScript SOR 40 iters），是高优先级排查目标。
			var _psi_iters_stage_t0_us: int = Time.get_ticks_usec()
			var iters_to_do: int = mini(
				_PHYS_PSI_ITERS_PER_STEP,
				_PHYS_PSI_TOTAL_ITERS - _phys_psi_iters_done
			)
			if iters_to_do > 0 and _pending_psi_state != null:
				PhysCircSolverScript.step_psi_solver(_pending_psi_state, iters_to_do)
				_phys_psi_iters_done += iters_to_do
			var _psi_iters_stage_total_ms: float = float(Time.get_ticks_usec() - _psi_iters_stage_t0_us) / 1000.0
			# 进入这里就是 fallback，每次都打（频次不会高 — 40/8 = 5 slice 才完成一轮）。
			print("[psi_iters/STAGE-TOTAL] wall=%.2fms iters_done=%d/%d iters_this_slice=%d (FALLBACK path — C++ run_psi_solver_pass not available)" % [
				_psi_iters_stage_total_ms, _phys_psi_iters_done, _PHYS_PSI_TOTAL_ITERS, iters_to_do,
			])
			if _phys_psi_iters_done >= _PHYS_PSI_TOTAL_ITERS:
				_phys_stage = _PHYS_STAGE_PSI_FINALIZE
		_PHYS_STAGE_PSI_FINALIZE:
			# Fix #11 (2026-06-15) STAGE-TOTAL 埋点：同 PSI_ITERS，进这里是 fallback。
			# psi_to_ocean_current 在 GDScript 跑 2400-loop 6 邻居梯度 + density gradient + lat_temp，
			# 是 ocean fallback 路径的最大单 stage 嫌疑（~20-40ms / slice）。
			var _psi_fin_stage_t0_us: int = Time.get_ticks_usec()
			if _pending_psi_state != null:
				PhysCircSolverScript.psi_to_ocean_current(_pending_psi_state, map, hex_size, bounds, cfg, profile)
				PhysCircSolverScript.commit_psi_to_cells(_pending_psi_state)
				if map.has_indices() and map.wind_stress_curl_arr.size() == map.soa_size() \
						and map.ocean_psi_arr.size() == map.soa_size():
					var cells_for_psi_debug: Array = map.iter_cells()
					for _i_psi_debug in range(cells_for_psi_debug.size()):
						var _c_psi_debug: HexCell = cells_for_psi_debug[_i_psi_debug]
						map.wind_stress_curl_arr[_i_psi_debug] = _c_psi_debug.wind_stress_curl if _c_psi_debug != null else 0.0
						map.ocean_psi_arr[_i_psi_debug] = _c_psi_debug.ocean_psi if _c_psi_debug != null else 0.0
			var _psi_fin_stage_total_ms: float = float(Time.get_ticks_usec() - _psi_fin_stage_t0_us) / 1000.0
			print("[psi_finalize/STAGE-TOTAL] wall=%.2fms (FALLBACK path — psi_to_ocean_current + commit_psi + 2400-loop curl/psi writeback in GDScript)" % _psi_fin_stage_total_ms)
			_phys_stage = _PHYS_STAGE_UPWELLING
		_PHYS_STAGE_UPWELLING:
			var _upwelling_done_by_cpp: bool = false
			# DOTS-Total-CPP 诊断：stage 6 整体 87ms 但 cpp 内部 0.045ms，瓶颈
			# 此前定位在 GDScript 准备步骤；现在 C++ 路径已经稳定（实测
			# STAGE-TOTAL ≈ 0.21ms），收尾把诊断收紧到只在第一次进入时打一组，
			# 之后静默。要复现详细日志只需把 budget 改大或重置 _upwelling_diag_count = 0。
			const _UPWELLING_DIAG_BUDGET: int = 1
			var _diag_active: bool = _upwelling_diag_count < _UPWELLING_DIAG_BUDGET
			var _t_stage_us: int = Time.get_ticks_usec()
			if _diag_active:
				_upwelling_diag_count += 1
				var prof_ok: bool = profile != null
				# dots-flag-prune-pr1 round 2: use_gdext_physical_circulation flag 已删除——
				# 探针保留以观察 ext / wind_cpp / idx 准备状态，pflag 列恒 true 标记。
				var pflag_attr_ok: bool = true  # 已折叠：flag 字段已删
				var pflag_val_ok: bool = true   # 已折叠：恒 true
				var pext_ok: bool = _world_ext != null
				var pmethod_ok: bool = pext_ok and _world_ext.has_method("run_physical_circulation_pass")
				var wind_cpp_ok: bool = _phys_wind_done_by_cpp
				var idx_ok: bool = map != null and map.has_indices()
				var gate_pass: bool = pmethod_ok and wind_cpp_ok and idx_ok
				print("[upwelling/DIAG#%d] gate: prof=%s pflag_attr=%s pflag_val=%s ext=%s method=%s wind_cpp=%s idx=%s -> cpp_gate=%s" % [
					_upwelling_diag_count, str(prof_ok), str(pflag_attr_ok), str(pflag_val_ok), str(pext_ok),
					str(pmethod_ok), str(wind_cpp_ok), str(idx_ok), str(gate_pass)
				])
			# dots-flag-prune-pr1 round 2: use_gdext_physical_circulation flag 已删除——
			# 恒走 ext + has_method(run_physical_circulation_pass) + wind_cpp + idx 探测。
			if _world_ext != null and _world_ext.has_method("run_physical_circulation_pass") \
					and _phys_wind_done_by_cpp \
					and map.has_indices():
				# T1: neighbor_indices_packed
				var _t1_us: int = Time.get_ticks_usec()
				var n_up: int = map.soa_size()
				var nb_idx_up: PackedInt32Array = map.neighbor_indices_packed()
				var _ms_t1: float = float(Time.get_ticks_usec() - _t1_us) / 1000.0
				if n_up > 0 and nb_idx_up.size() >= n_up * 6:
					# T2: 准备 knobs（PackedByteArray + Dictionary）
					var _t2_us: int = Time.get_ticks_usec()
					var water_ids_up := PackedByteArray()
					water_ids_up.append(int(TerrainType.TERRAIN.OCEAN))
					water_ids_up.append(int(TerrainType.TERRAIN.COAST))
					water_ids_up.append(int(TerrainType.TERRAIN.REEF))
					water_ids_up.append(int(TerrainType.TERRAIN.KELP))
					var knobs_up := {
						"stage": "upwelling",
						"n_cells": n_up,
						"neighbor_indices": nb_idx_up,
						"water_terrain_ids": water_ids_up,
						"world_bounds_pos_y": bounds.position.y,
						"world_bounds_size_y": bounds.size.y,
						"cold_sink_temp": (cfg.COLD_SINK_TEMP if cfg != null else -0.05),
					}
					var _ms_t2: float = float(Time.get_ticks_usec() - _t2_us) / 1000.0
					# T3: refresh_slots_from_map
					var _t3_us: int = Time.get_ticks_usec()
					if _world_ext.has_method("refresh_slots_from_map"):
						_world_ext.refresh_slots_from_map()
					var _ms_t3: float = float(Time.get_ticks_usec() - _t3_us) / 1000.0
					# T4: 真正调用 C++
					var _t4_us: int = Time.get_ticks_usec()
					var ret_up = _world_ext.run_physical_circulation_pass(knobs_up)
					var _ms_t4: float = float(Time.get_ticks_usec() - _t4_us) / 1000.0
					if _diag_active:
						var rt_ok: bool = (typeof(ret_up) == TYPE_DICTIONARY)
						var fb: bool = (not rt_ok) or bool(ret_up.get("fallback", true))
						var rsn: String = (ret_up.get("reason", "") if rt_ok else "non-dict")
						var em: float = (float(ret_up.get("elapsed_ms", -1.0)) if rt_ok else -1.0)
						print("[upwelling/DIAG#%d] cpp-call: ret_type=%s fallback=%s reason='%s' elapsed_native_ms=%.3f" % [
							_upwelling_diag_count, str(typeof(ret_up)), str(fb), rsn, em
						])
						print("[upwelling/DIAG#%d] BREAKDOWN: T1_nb_pack=%.2fms T2_knobs=%.2fms T3_refresh_slots=%.2fms T4_cpp_call=%.2fms (n=%d)" % [
							_upwelling_diag_count, _ms_t1, _ms_t2, _ms_t3, _ms_t4, n_up
						])
					if typeof(ret_up) == TYPE_DICTIONARY and not bool(ret_up.get("fallback", true)):
						_upwelling_done_by_cpp = true
				else:
					if _diag_active:
						print("[upwelling/DIAG#%d] inner-skip: n_cells=%d nb_idx_size=%d (need >= %d)" % [
							_upwelling_diag_count, n_up, nb_idx_up.size(), n_up * 6
						])
			else:
				if _diag_active:
					print("[upwelling/DIAG#%d] outer-skip: gate_pass=false (see gate line above)" % _upwelling_diag_count)
			if not _upwelling_done_by_cpp:
				var _t_fb_us: int = Time.get_ticks_usec()
				PhysCircSolverScript.solve_upwelling(map, hex_size, bounds, cfg)
				if _diag_active:
					var _ms_fb: float = float(Time.get_ticks_usec() - _t_fb_us) / 1000.0
					print("[upwelling/DIAG#%d] GDSCRIPT-FALLBACK ran=%.2fms (THIS IS THE BOTTLENECK)" % [
						_upwelling_diag_count, _ms_fb
					])
			else:
				if _diag_active:
					print("[upwelling/DIAG#%d] CPP-PATH-OK (no GDScript fallback)" % _upwelling_diag_count)
			if _diag_active:
				var _ms_stage: float = float(Time.get_ticks_usec() - _t_stage_us) / 1000.0
				print("[upwelling/DIAG#%d] STAGE-TOTAL=%.2fms (matches slow_slice if > 25ms)" % [
					_upwelling_diag_count, _ms_stage
				])
			# Fix #11 (2026-06-15)：原 _UPWELLING_DIAG_BUDGET=1 封顶后整个 stage 静音，
			# 但 STAGE >= 5ms 的异常应该一直报。补一行 warn-only 路径，与 _diag_active 解耦。
			if not _diag_active:
				var _ms_stage_warn: float = float(Time.get_ticks_usec() - _t_stage_us) / 1000.0
				if _ms_stage_warn >= 5.0:
					print("[upwelling/STAGE-TOTAL] warn wall=%.2fms cpp=%s (>= 5ms threshold; mobile ocean candidate hotspot)" % [
						_ms_stage_warn, str(_upwelling_done_by_cpp),
					])
			_phys_stage = _PHYS_STAGE_WIND_RASTER
		_PHYS_STAGE_WIND_RASTER:
			# Fix #11 (2026-06-15) STAGE-TOTAL 埋点：第一次进入 stage 时整段 wall time 已被
			# 内部 `t_wr_us > 8.0ms` 报警覆盖。这里给 GDScript slice 路径再加一行 wall warn，
			# mobile 上 Fix #1 已经禁用了 phys_need_visual 跨季 rebake，所以 stage 7 进入即
			# 异常（应该不再来这里）。这条诊断帮我们捕获回退。
			var _wr_stage_t0_us: int = Time.get_ticks_usec()
			# 第一次进入 WIND_RASTER 时跑 NaN 守门 + 分配 buffer，之后每次推进
			# 一片像素，全部写完才 _PHYS_STAGE_DONE。
			var W := world.derived_size.x
			var H := world.derived_size.y
			var pix_total: int = W * H
			if pix_total <= 0:
				_pending_phys_solved_phase = season_phase
				_phys_stage = _PHYS_STAGE_DONE
				return true
			if _phys_wind_raster_idx == 0:
				var t_wr_us: int = Time.get_ticks_usec()
				# NaN/Inf 守门：若任一 cell 物理量异常，退回 fallback 路径覆写。
				# DOTS-Total-CPP（A 方案 / phys nan_guard 孪生）：优先走 C++ SoA
				# 位运算扫描（2400 cell × 6 字段 << 0.1ms），替代 22ms GDScript 循环。
				# 失败（旧 DLL / SoA 缺失）→ 透明回落原路径。
				var n_bad: int = -1
				if _world_ext != null and _world_ext.has_method("phys_field_nan_guard"):
					n_bad = int(_world_ext.phys_field_nan_guard())
				if n_bad < 0:
					n_bad = 0
					for c: HexCell in map.all_cells():
						if c == null:
							continue
						if not is_finite(c.wind_vector.x) or not is_finite(c.wind_vector.y) \
								or not is_finite(c.wind_speed) \
								or not is_finite(c.ocean_current.x) or not is_finite(c.ocean_current.y) \
								or not is_finite(c.upwelling_strength):
							n_bad += 1
				if n_bad > 0:
					push_warning("PhysicalCirculation: detected %d cells with NaN/Inf, falling back to ny-only solver" % n_bad)
					PhysCircSolverScript.solve_ocean_current_fallback(map, hex_size, bounds, cfg, profile)
					PhysCircSolverScript.solve_upwelling(map, hex_size, bounds, cfg)
				var t_nan_ms: float = (Time.get_ticks_usec() - t_wr_us) / 1000.0
				var t_ensure0_us: int = Time.get_ticks_usec()
				_ensure_pending_wind_size(world)
				var t_ensure_ms: float = (Time.get_ticks_usec() - t_ensure0_us) / 1000.0
				# DOTS-Total-CPP（A 方案 / wind raster）：第一次进入 stage 时尝试 C++
				# 一次性 hex→pixel rasterize（620544 像素 ≤ 5ms），成功则直接收尾。
				# 失败 → 透明回落到下面的 GDScript 像素切片路径。
				# dots-flag-prune-pr1 (2026-05-22)：use_gdext_ocean_currents_pixel flag 已删，
				# wind raster fast path 现恒走 ext + has_method 探测。
				if profile != null \
						and _world_ext != null \
						and _world_ext.has_method("run_wind_field_rasterize"):
					var t_raster0_us: int = Time.get_ticks_usec()
					var _wr_res: Dictionary = run_wind_field_rasterize_full(map, world, cfg)
					var t_raster_ms: float = (Time.get_ticks_usec() - t_raster0_us) / 1000.0
					if not bool(_wr_res.get("fallback", true)):
						_pending_phys_solved_phase = season_phase
						_phys_stage = _PHYS_STAGE_DONE
						_phys_wind_raster_idx = 0
						var t_total_ms: float = (Time.get_ticks_usec() - t_wr_us) / 1000.0
						if t_total_ms > 8.0:
							print("  [phys_wind_raster] total=%.1fms nan_guard=%.1f ensure_buf=%.1f cpp_raster=%.1f (cells=%d)" % [
								t_total_ms, t_nan_ms, t_ensure_ms, t_raster_ms, map.cell_count()
							])
						return true
			var s_idx: int = _phys_wind_raster_idx
			var e_idx: int = mini(pix_total, s_idx + _PHYS_WIND_RASTER_PIXELS_PER_STEP)
			_rasterize_wind_slice_from_hex(world, _pending_wind_buf, s_idx, e_idx)
			_phys_wind_raster_idx = e_idx
			var _wr_slice_total_ms: float = float(Time.get_ticks_usec() - _wr_stage_t0_us) / 1000.0
			if _wr_slice_total_ms >= 5.0:
				print("[wind_raster/STAGE-TOTAL] warn slice wall=%.2fms (pix %d..%d / %d) [GDScript slice path; mobile Fix #1 expected to skip this stage entirely]" % [
					_wr_slice_total_ms, s_idx, e_idx, pix_total,
				])
			if _phys_wind_raster_idx >= pix_total:
				_pending_phys_solved_phase = season_phase
				_phys_stage = _PHYS_STAGE_DONE
				_phys_wind_raster_idx = 0
				return true
			# 还有像素要写 → 留在 WIND_RASTER stage，下次 step_one 续。
			return false
		_PHYS_STAGE_DONE:
			return true
		_:
			# 未知状态 → 强制收尾（避免死循环）。
			_pending_phys_solved_phase = season_phase
			_phys_stage = _PHYS_STAGE_DONE
			return true
	return _phys_stage == _PHYS_STAGE_DONE


# Phys Solve Sliced 入口 ① ：给一次性路径用的 wrapper。
#
# 一次性调用：把 SLP / wind / ψ / current / upwelling / wind raster 全部在
# 一次函数调用中跑完。bake_world 与 rebake_ocean_currents 走这条；它们都需要
# "调用返回时 hex 字段已就绪"的强语义。内部循环调 `_physical_solve_step_one`
# 直到 `_PHYS_STAGE_DONE`，避免与切片路径双份维护求解逻辑。
#
# 重复调用同一 phase 时直接 return（_pending_phys_solved_phase 命中）。下一轮
# 来临前 commit_ocean_buffers / discard_ocean_buffers 都会把
# _pending_phys_solved_phase + _phys_stage 重置，强制重算。
func _physical_solve_for_phase(map: MapData, world: WorldData, hex_size: float,
		cfg: MapConfig, season_phase: float) -> void:
	if world == null or map == null:
		return
	if not is_nan(_pending_phys_solved_phase) and absf(_pending_phys_solved_phase - season_phase) < 0.001:
		return
	var t0_total := Time.get_ticks_msec()
	# 一次性路径必须从干净状态起步，避免和切片路径残留的 _phys_stage 冲突。
	reset_physical_solve_state()
	var stage_ms: Dictionary = {}  # stage_idx -> ms（diagnostic）
	var stage_t0: int = Time.get_ticks_msec()
	var prev_stage: int = _phys_stage
	while not _physical_solve_step_one(map, world, hex_size, cfg, season_phase):
		# 在每个 stage 切换处采样一次，方便日志比对老的 slp/wind/psi/up 拆分。
		if _phys_stage != prev_stage:
			stage_ms[prev_stage] = Time.get_ticks_msec() - stage_t0
			stage_t0 = Time.get_ticks_msec()
			prev_stage = _phys_stage
	stage_ms[prev_stage] = Time.get_ticks_msec() - stage_t0

	var total_ms := Time.get_ticks_msec() - t0_total
	var msg := "PhysicalCirculation solve@phase=%.2f total=%dms (slp=%dms wind=%dms psi=%dms finalize=%dms upwelling=%dms wind_raster=%dms)" % [
		season_phase, total_ms,
		int(stage_ms.get(_PHYS_STAGE_SLP, 0)),
		int(stage_ms.get(_PHYS_STAGE_WIND, 0)),
		int(stage_ms.get(_PHYS_STAGE_PSI_INIT, 0)) + int(stage_ms.get(_PHYS_STAGE_PSI_ITERS, 0)),
		int(stage_ms.get(_PHYS_STAGE_PSI_FINALIZE, 0)),
		int(stage_ms.get(_PHYS_STAGE_UPWELLING, 0)),
		int(stage_ms.get(_PHYS_STAGE_WIND_RASTER, 0)),
	]
	if total_ms > 25:
		push_warning("%s — exceeds 25ms soft budget" % msg)
	else:
		print(msg)

# 确保 _pending_wind_buf 已按 W×H×2 字节就位（PackedByteArray 不在 size 一致时
# 强制重分配，避免 GC 压力）。WIND_RASTER 阶段的第一次 step 调一次。
func _ensure_pending_wind_size(world: WorldData) -> void:
	var W := world.derived_size.x
	var H := world.derived_size.y
	var need: int = W * H * 2
	if _pending_wind_buf.size() != need:
		_pending_wind_buf = PackedByteArray()
		_pending_wind_buf.resize(need)

# 把 cell.wind_vector 量化进区间 [s, e)（按像素索引）。s 必须是非负，e ≤ W*H。
# 用 pixel_to_cell_lookup 直接查最近 hex，无 cube_round 成本。
# wind_vector 是单位方向；RG8 写入 dir * wind_speed_norm，让 shader length() 表示风速。
# L: 同 ocean_current_slice，同步写持久 _vector_atlas_data 的 BA 通道（[idx*4+2, idx*4+3]）。
func _rasterize_wind_slice_from_hex(world: WorldData, buf: PackedByteArray,
		s: int, e: int) -> void:
	if buf.is_empty() or s >= e:
		return
	var W := world.derived_size.x
	var H := world.derived_size.y
	var lookup: Array = world.pixel_to_cell_lookup
	var has_lookup: bool = lookup.size() == W * H
	var atlas_valid: bool = (_vector_atlas_data_size == Vector2i(W, H) \
			and _vector_atlas_data.size() == W * H * 4)
	for i in range(s, e):
		var cell: HexCell = null
		if has_lookup:
			cell = lookup[i]
		var wx: float = 1.0
		var wy: float = 0.0
		if cell != null:
			var wind_speed_norm: float = clampf(cell.wind_speed / 1.7, 0.0, 1.0)
			wx = cell.wind_vector.x * wind_speed_norm
			wy = cell.wind_vector.y * wind_speed_norm
		var bx: int = clampi(int(round((wx * 0.5 + 0.5) * 255.0)), 0, 255)
		var by: int = clampi(int(round((wy * 0.5 + 0.5) * 255.0)), 0, 255)
		buf[i * 2]     = bx
		buf[i * 2 + 1] = by
		if atlas_valid:
			_vector_atlas_data[i * 4 + 2] = bx
			_vector_atlas_data[i * 4 + 3] = by

# 一次性版本（bake_world / rebake_ocean_currents 用）：直接全图写入 _pending_wind_buf
# 并返回它。等价于多次调 _rasterize_wind_slice_from_hex 拼成全图。
func _rasterize_wind_field_from_hex(map: MapData, world: WorldData) -> PackedByteArray:
	_ensure_pending_wind_size(world)
	var W := world.derived_size.x
	var H := world.derived_size.y
	_rasterize_wind_slice_from_hex(world, _pending_wind_buf, 0, W * H)
	return _pending_wind_buf

# L: 从 world.ocean_current_buffer / wind_field_buffer 一次性拼出 RGBA8 交错缓冲。
# fallback 路径（缓存未就绪）的 commit 末尾调一次，让下一次 commit 走 fast path。
# 之后 pixel slices 在写 _pending_currents_buf / _pending_wind_buf 时同步维护此 buf。
func _rebuild_vector_atlas_data_from_buffers(world: WorldData) -> void:
	if world == null:
		return
	var W: int = world.derived_size.x
	var H: int = world.derived_size.y
	var n: int = W * H
	var need: int = n * 4
	if _vector_atlas_data.size() != need:
		_vector_atlas_data = PackedByteArray()
		_vector_atlas_data.resize(need)
	_vector_atlas_data_size = Vector2i(W, H)
	var ocean_buf: PackedByteArray = world.ocean_current_buffer
	var wind_buf: PackedByteArray = world.wind_field_buffer
	var has_ocean: bool = ocean_buf.size() >= n * 2
	var has_wind: bool = wind_buf.size() >= n * 2
	for i in range(n):
		var di: int = i * 4
		var oi: int = i * 2
		_vector_atlas_data[di]     = ocean_buf[oi]     if has_ocean else 128
		_vector_atlas_data[di + 1] = ocean_buf[oi + 1] if has_ocean else 128
		_vector_atlas_data[di + 2] = wind_buf[oi]      if has_wind else 128
		_vector_atlas_data[di + 3] = wind_buf[oi + 1]  if has_wind else 128

# 把 cell.ocean_current 量化进 RG8 像素区间 [s, e)。陆地像素填中性 (128, 128) = 零向量。
# L: 同步把 RG 写到持久 _vector_atlas_data 的 [idx*4, idx*4+1] 通道（若 size 已就绪），
# 让 commit_ocean_buffers 直接 Image.create_from_data(_vector_atlas_data) + tex.update，
# 省掉 620k × 4 字节的全图交错循环（30-50ms → memcpy）。
func _rasterize_ocean_current_slice_from_hex(world: WorldData, dst: PackedByteArray,
		s: int, e: int) -> void:
	var lookup: Array = world.pixel_to_cell_lookup
	var W := world.derived_size.x
	var H := world.derived_size.y
	var has_lookup: bool = lookup.size() == W * H
	var atlas_valid: bool = (_vector_atlas_data_size == Vector2i(W, H) \
			and _vector_atlas_data.size() == W * H * 4)
	for i in range(s, e):
		var cell: HexCell = null
		if has_lookup:
			cell = lookup[i]
		var cur_x: float = 0.0
		var cur_y: float = 0.0
		if cell != null and _is_water(int(cell.terrain)):
			cur_x = cell.ocean_current.x
			cur_y = cell.ocean_current.y
		var bx: int = clampi(int(round((cur_x * 0.5 + 0.5) * 255.0)), 0, 255)
		var by: int = clampi(int(round((cur_y * 0.5 + 0.5) * 255.0)), 0, 255)
		dst[i * 2]     = bx
		dst[i * 2 + 1] = by
		if atlas_valid:
			_vector_atlas_data[i * 4]     = bx
			_vector_atlas_data[i * 4 + 1] = by

# 把 cell.upwelling_strength 量化进 R8 像素区间 [s, e)。陆地填 128（中性）。
# 编码：strength ∈ [-1, 1] → byte ∈ [0, 255]，128 = 0；255 = +1（满上升）；0 = -1（满下沉）。
# 与现有 _bake_ocean_upwelling 的编码契约一致（虽然旧路径只用 [128, 255] 半区上升 +
# [0, 128] 半区下沉，新路径继续遵守）。
func _rasterize_upwelling_slice_from_hex(world: WorldData, dst: PackedByteArray,
		s: int, e: int) -> void:
	var lookup: Array = world.pixel_to_cell_lookup
	var W := world.derived_size.x
	var H := world.derived_size.y
	var has_lookup: bool = lookup.size() == W * H
	for i in range(s, e):
		var cell: HexCell = null
		if has_lookup:
			cell = lookup[i]
		if cell == null or not _is_water(int(cell.terrain)):
			dst[i] = 128
			continue
		var up: float = clampf(cell.upwelling_strength, -1.0, 1.0)
		dst[i] = clampi(int(round(128.0 + 127.0 * up)), 0, 255)


# ─── DOTS-Total-CPP（plan/dots-total-cpp 任务 4+5）────────────────────────
# Ocean rasterize 一次性 hex→pixel byte 直出 — 替代 _rasterize_ocean_current_slice_from_hex
# + _rasterize_upwelling_slice_from_hex 的 17 个 pixel slice。
	# Gate：caller 已确认 ext + has_method (use_gdext_ocean_currents_pixel removed in dots-flag-prune-pr1).

# 缓存 ocean rasterize 的 pixel→cell-index 表（与 sea_ice 缓存独立）。
var _ocean_pixel_to_cell_idx: PackedInt32Array = PackedInt32Array()
var _ocean_pixel_cache_size: Vector2i = Vector2i.ZERO


func _ensure_ocean_pixel_to_cell_index(map: MapData, world: WorldData) -> void:
	var n: int = int(world.derived_size.x) * int(world.derived_size.y)
	if _ocean_pixel_cache_size == world.derived_size and _ocean_pixel_to_cell_idx.size() == n:
		return
	_ocean_pixel_to_cell_idx = PackedInt32Array()
	_ocean_pixel_to_cell_idx.resize(n)
	var lookup := world.pixel_to_cell_lookup
	for i in range(n):
		var cell = lookup[i] if i < lookup.size() else null
		_ocean_pixel_to_cell_idx[i] = map.index_of(cell) if cell != null else -1
	_ocean_pixel_cache_size = world.derived_size


# 一次性把 ocean_current + upwelling SoA 通过 C++ rasterize 量化进
# _pending_currents_buf / _pending_upwelling_buf / _vector_atlas_data。
#
# Sub-slice 支持（plan/ocean-raster-subslice 2026-05-22）：
#   p_start_idx / p_end_idx 缺省 -1 表示"全图一次性"（旧行为）。
#   传入 [s, e) 时仅 raster 该像素区间，配合 OceanCurrentsJob 的多 sub-tick 切片。
#   首片（s==0）做 _ensure_pending_* / refresh_slots_from_map（O(1) check + 一次性
#   slot sync）；后续 sub-slice 跳过这两步，靠 caller 维持 buffer 一致。
# 返回 Dictionary：{ "fallback": bool, "elapsed_ms": float, "pixels": int,
#                  "atlas_updated": bool, "start_idx": int, "end_idx": int }
func run_ocean_field_rasterize_full(map: MapData, world: WorldData, _cfg: MapConfig,
		p_start_idx: int = -1, p_end_idx: int = -1) -> Dictionary:
	var out := { "fallback": true, "elapsed_ms": -1.0, "pixels": 0, "atlas_updated": false }
	if world == null or map == null:
		out["reason"] = "missing world/map"
		return out
	if _world_ext == null or not _world_ext.has_method("run_ocean_field_rasterize"):
		out["reason"] = "ext/method missing"
		return out
	# 必须先把 hex 求解推到 DONE — caller 已通过 _physical_solve_step_one 完成。
	# pending_currents / pending_upwelling 缓冲就绪
	_ensure_pending_currents_size(world)
	_ensure_pending_upwelling_size(world)
	_ensure_ocean_pixel_to_cell_index(map, world)

	var W := int(world.derived_size.x)
	var H := int(world.derived_size.y)
	var n_px: int = W * H

	# 解析 sub-slice 区间。负数 / 越界 → 全图。
	var s: int = p_start_idx
	var e: int = p_end_idx
	if s < 0:
		s = 0
	if e < 0 or e > n_px:
		e = n_px
	if s > e:
		s = e
	var is_first_subslice: bool = (s == 0)

	# 同步 DataCoreWorld slots（HexCell facade 已直写 SoA，但保险起见 refresh）
	# 仅首片做：sub-slice 中途 SoA 不应再变（_phase_locked 已固定，hex 求解已 DONE）
	if is_first_subslice and _world_ext.has_method("refresh_slots_from_map"):
		_world_ext.refresh_slots_from_map()

	# atlas_data fast path：若 _vector_atlas_data 已就位，让 C++ 同步写入
	var atlas_ok: bool = (_vector_atlas_data_size == Vector2i(W, H) \
			and _vector_atlas_data.size() == n_px * 4)
	var knobs: Dictionary = {
		"n_cells": map.cell_count(),
		"w": W,
		"h": H,
		"pixel_to_cell_idx": _ocean_pixel_to_cell_idx,
		"dst_currents": _pending_currents_buf,
		"dst_upwelling": _pending_upwelling_buf,
		"update_atlas_data": atlas_ok,
		"start_idx": s,
		"end_idx": e,
	}
	if atlas_ok:
		knobs["atlas_data"] = _vector_atlas_data
	var res: Dictionary = _world_ext.run_ocean_field_rasterize(knobs)
	if bool(res.get("fallback", true)) or float(res.get("elapsed_ms", -1.0)) < 0.0:
		out["reason"] = String(res.get("reason", "unknown"))
		return out
	# C++ 端通过 ptrw 已修改 PackedByteArray；Dictionary 共享 ref，赋值即同步。
	_pending_currents_buf = knobs["dst_currents"]
	_pending_upwelling_buf = knobs["dst_upwelling"]
	if atlas_ok:
		_vector_atlas_data = knobs["atlas_data"]
	out["fallback"] = false
	out["elapsed_ms"] = float(res.get("elapsed_ms", 0.0))
	out["pixels"] = int(res.get("pixels", 0))
	out["atlas_updated"] = bool(res.get("atlas_updated", false))
	out["start_idx"] = int(res.get("start_idx", s))
	out["end_idx"] = int(res.get("end_idx", e))
	return out


# ─── DOTS-Total-CPP（A 方案 / wind raster 孪生）─────────────────────────
# Wind rasterize 一次性 hex→pixel byte 直出 — 替代 _rasterize_wind_slice_from_hex
# 在 _PHYS_STAGE_WIND_RASTER 中跑 21 片 × ~87ms 的 GDScript 循环。
# 复用 _ocean_pixel_to_cell_idx 缓存（同一 pixel→cell 映射）。
#
	# Gate：caller 已确认 ext + has_method (use_gdext_ocean_currents_pixel removed in dots-flag-prune-pr1).
# 返回 Dictionary：{ "fallback": bool, "elapsed_ms": float, "pixels": int, "atlas_updated": bool }
func run_wind_field_rasterize_full(map: MapData, world: WorldData, _cfg: MapConfig) -> Dictionary:
	var out := { "fallback": true, "elapsed_ms": -1.0, "pixels": 0, "atlas_updated": false }
	if world == null or map == null:
		out["reason"] = "missing world/map"
		return out
	if _world_ext == null or not _world_ext.has_method("run_wind_field_rasterize"):
		out["reason"] = "ext/method missing"
		return out
	# pending_wind 缓冲就绪
	_ensure_pending_wind_size(world)
	# pixel→cell idx 表（与 ocean rasterize 共用同一张表）
	_ensure_ocean_pixel_to_cell_index(map, world)

	# 同步 DataCoreWorld slots（HexCell facade 已直写 SoA，但保险起见 refresh）
	if _world_ext.has_method("refresh_slots_from_map"):
		_world_ext.refresh_slots_from_map()

	var W := int(world.derived_size.x)
	var H := int(world.derived_size.y)
	var n_px: int = W * H
	# atlas_data fast path：若 _vector_atlas_data 已就位，让 C++ 同步写 [+2]/[+3]
	var atlas_ok: bool = (_vector_atlas_data_size == Vector2i(W, H) \
			and _vector_atlas_data.size() == n_px * 4)
	var knobs: Dictionary = {
		"n_cells": map.cell_count(),
		"w": W,
		"h": H,
		"pixel_to_cell_idx": _ocean_pixel_to_cell_idx,
		"dst_wind": _pending_wind_buf,
		"update_atlas_data": atlas_ok,
	}
	if atlas_ok:
		knobs["atlas_data"] = _vector_atlas_data
	var res: Dictionary = _world_ext.run_wind_field_rasterize(knobs)
	if bool(res.get("fallback", true)) or float(res.get("elapsed_ms", -1.0)) < 0.0:
		out["reason"] = String(res.get("reason", "unknown"))
		return out
	# C++ 端通过 ptrw 已修改 PackedByteArray；Dictionary 共享 ref，赋值即同步。
	_pending_wind_buf = knobs["dst_wind"]
	if atlas_ok:
		_vector_atlas_data = knobs["atlas_data"]
	out["fallback"] = false
	out["elapsed_ms"] = float(res.get("elapsed_ms", 0.0))
	out["pixels"] = int(res.get("pixels", 0))
	out["atlas_updated"] = bool(res.get("atlas_updated", false))
	return out
