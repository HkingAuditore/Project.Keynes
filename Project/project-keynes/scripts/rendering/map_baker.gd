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

const WindBeltScript = preload("res://scripts/weather/wind_belt.gd")
# Physical Wind & Ocean Circulation：hex 域物理化求解器。当
# ClimateProfile.physical_circulation_enabled = true 时，bake_world / 切片烘焙
# 路径用它替换 ny-only 风场 + Ekman 洋流的旧实现，输出从 hex 字段（cell.wind_vector
# / cell.ocean_current / cell.upwelling_strength 等）光栅化到现有 buffer，shader 零改动。
const PhysCircSolverScript = preload("res://scripts/rendering/physical_circulation_solver.gd")

# ─── 分辨率 ───────────────────────────────────────────────────────────────
const HM_MAX_DIM := 1024  # hex-driven 模式下不需要 2048（hex 网格本身只 60×40，1024 已经远超）

# ─── v9.fbm-opt：共享 noise 贴图（替换 shader 内 value_noise 的 4× hash21 计算） ──
# 256×256 R8，固定 seed → 跨 world 实例可缓存共享。MapBaker 一次烘出，所有
# WorldData.noise_tex 都指向同一张 ImageTexture。shader 端 sampler 配置：
#   filter_linear（bilinear ≈ value_noise 的 smoothstep mix，肉眼无法区分）
#   repeat_enable（让 fbm 的多 octave 倍频采样自然 wrap）
# 然后 value_noise(p) 实现退化为：texture(noise_tex, p / NOISE_TEX_SCALE).r。
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
# Daily-sim perf opt: cell 级 byte 量化快照（key=HexCell, value=int 0..255）。
# bake_sea_ice_fraction_only 入口先做 cell 级 byte 比较：水格通常 ~1300 个，
# 比 620k 像素级比较快 ~500×。绝大多数日子海冰 byte 不变 → 直接 return，连像素
# buf 都不算，省掉 ~100ms 的 lookup 循环。
# 当 bake_world 重做 lookup 时一同失效（_sea_ice_only_buf 清空时也清掉）。
var _last_sea_ice_cell_bytes: Dictionary = {}

# Daily-sim perf opt 阶段 P：cover / vegetation 的 per-cell byte 快照（用于 rebake_*_only 增量路径）。
# weather_system 每日翻 cover 的 cell 通常 < 30 个，而旧 fast path 仍要扫 614k 像素重写所有 byte
# （即便 99% 没变化）。改造为遍历 world.cell_pixel_lists 的 ~2400 个 cell，逐 cell 比对 byte：
# 不变直接跳过，只对真正翻面的 cell 把它的像素列表批量写入 buffer，再触发 enum_atlas 整张 update。
# 与 ice_bake 的 _last_sea_ice_cell_bytes 完全同构。bake_world 重做 lookup 时一并失效。
var _last_cover_cell_bytes: Dictionary = {}
var _last_vegetation_cell_bytes: Dictionary = {}
var _cover_cache_size: Vector2i = Vector2i.ZERO
var _vegetation_cache_size: Vector2i = Vector2i.ZERO
# J: biome（R 通道）增量缓存。stage 9 `rebake_biome_axes_only` 之前每季全图重烘
# (~130ms / season)；接入与 cover/veg 同结构的 sig 比对后，多数季节切换只有少量 cell
# 真正翻 terrain（_seasonal_redecide_terrain 的边界 cell），其余直接 byte 不变跳过。
# bake_world / regenerate 时一并失效。
var _last_biome_cell_bytes: Dictionary = {}
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
	var data := PackedByteArray()
	data.resize(size * size)
	for i in range(size * size):
		data[i] = rng.randi_range(0, 255)
	# v9.perf：开启 mipmap。fbm 高 octave 在世界坐标里以 ~2.03^N 倍频采样这个 256² 贴图，
	# 没 mip 时邻近像素跳到完全不同的 texel → cache 抖动 + 视觉 aliasing。
	# 开 mip 后高频 fbm 自动落到低 mip 上（数据已被预滤波），既快又抗 aliasing。
	# 注意：create_from_data 第 3 参 mipmaps=true 时要求 data 已包含全部 mip 级别的数据，
	# 这里只提供了 base level，所以先传 false 建 base 图，再调用 generate_mipmaps() 生成后续级别。
	var img := Image.create_from_data(size, size, false, Image.FORMAT_R8, data)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

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
const RIVER_STROKE_HEX_FACTOR := 0.05
# SDF 截断距离改小：原 64 让河流过宽（视觉上 1.5 hex 宽），
# 8 pixels (~ 0.4 hex_size) 让河保持细线但仍有 anti-alias 渐隐边
const SDF_MAX_DIST_PX := 8.0

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
# L: 持久 RGBA8 交错缓冲。pixel slices 在写 _pending_currents_buf / _pending_wind_buf
# 时一并更新此 buf 的对应通道（RG=ocean, BA=wind），commit 时直接喂给 ImageTexture.update
# 避免 620k × 4 字节的 GDScript 交错循环（30-50ms 砍到 ~3ms memcpy）。
# bake_world / discard 时失效。size mismatch 时 commit 会重新整张 _encode_vector_atlas 兜底。
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

# SOR 总迭代数（与 PhysicalCirculationSolver._PSI_DEFAULT_ITERS 对齐）+
# 每次 step_one 推进的迭代量。8/40 → 5 个 step 完成 ψ；每个 step ~2ms（2400 cells
# 中典型 ~1300 个水格 × 6 邻居 × 8 iter ≈ 60k 浮点）。
const _PHYS_PSI_TOTAL_ITERS: int = 40
const _PHYS_PSI_ITERS_PER_STEP: int = 8

# Phys Solve Sliced：WIND_RASTER 阶段把"hex → W×H RGB8 风场 buffer"分多步写盘。
# 30000 像素 × ~0.2us = ~6ms / step；典型 derived_size 256×256=65k → 3 步完成。
const _PHYS_WIND_RASTER_PIXELS_PER_STEP: int = 30000

var _phys_stage: int = _PHYS_STAGE_NONE
var _phys_psi_iters_done: int = 0
var _phys_wind_raster_idx: int = 0

# ─── 公开接口 ─────────────────────────────────────────────────────────────

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

	# Daily Sim SoA Refactor 阶段 1：重新烘焙世界 → 失效海冰独立纹理缓冲与 cell-byte 快照，
	# 否则下一次 bake_sea_ice_fraction_only 的 cache_valid 判定会基于旧 lookup 命中。
	# scalar_atlas 自己每次 bake_world 都会通过 _encode_scalar_atlas 重建，无需手动清。
	_sea_ice_only_buf = PackedByteArray()
	_sea_ice_cache_size = Vector2i.ZERO
	_last_sea_ice_cell_bytes = {}
	# 阶段 P：cover / vegetation 的增量缓存同样要随地图重生 / 重烘失效。
	_last_cover_cell_bytes = {}
	_last_vegetation_cell_bytes = {}
	_cover_cache_size = Vector2i.ZERO
	_vegetation_cache_size = Vector2i.ZERO
	# J: biome 增量缓存随地图重生失效（首次 rebake_biome_axes_only 走 fallback 重建路径）
	_last_biome_cell_bytes = {}
	_biome_cache_size = Vector2i.ZERO
	# 阶段 P2：enum_atlas 交错 data 缓存随地图重生失效（首次 _encode_enum_atlas 会重新填）
	_enum_atlas_data = PackedByteArray()
	_enum_atlas_data_size = Vector2i.ZERO
	# weather_field 增量缓存：地图重生 → 缓冲与 sig 失效；首次 bake_weather_field_only 会重建。
	_weather_field_buf = PackedByteArray()
	_weather_field_cache_size = Vector2i.ZERO
	_last_weather_field_cell_sigs = {}
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

	# Phase 6：风带（每像素盛行风向，summer-default 当 baseline）
	# Physical Wind & Ocean Circulation：当 cfg.climate_profile.physical_circulation_enabled = true 时
	# 风场 / 洋流 / 上升流统一走 hex 求解 → 像素光栅化路径，三件产物一起在
	# _physical_solve_for_phase 内部生成（_pending_wind_buf 也在此时写好）。
	# 否则保留旧 _bake_wind_field + _bake_ocean_currents + _bake_ocean_upwelling 三段路径。
	t = Time.get_ticks_msec()
	if _use_physical_circulation(cfg):
		# 一次性求解（season_phase=2.0 同旧基线）
		_physical_solve_for_phase(map, world, hex_size, cfg, 2.0)
		# 风场 buffer：直接拿 _physical_solve 写好的 _pending_wind_buf
		world.wind_field_buffer = _pending_wind_buf if not _pending_wind_buf.is_empty() \
				else _bake_wind_field(world.world_bounds, world.derived_size, 2.0)
		print("  wind field (physical-hex): %dms" % (Time.get_ticks_msec() - t))
		# Ocean current：用 hex → pixel 光栅化整张
		t = Time.get_ticks_msec()
		var W := world.derived_size.x
		var H := world.derived_size.y
		var cur_buf := PackedByteArray()
		cur_buf.resize(W * H * 2)
		_rasterize_ocean_current_slice_from_hex(world, cur_buf, 0, W * H)
		world.ocean_current_buffer = cur_buf
		print("  ocean currents (physical-hex): %dms" % (Time.get_ticks_msec() - t))
		# Upwelling：同上
		t = Time.get_ticks_msec()
		var up_buf := PackedByteArray()
		up_buf.resize(W * H)
		_rasterize_upwelling_slice_from_hex(world, up_buf, 0, W * H)
		world.ocean_upwelling_buffer = up_buf
		print("  ocean upwelling (physical-hex): %dms" % (Time.get_ticks_msec() - t))
		# 清掉一次性路径用过的中间状态，避免 OceanCurrentsJob 第一次切片误以为已求解过本轮。
		_pending_phys_solved_phase = NAN
		_pending_psi_state = null
		_pending_wind_buf = PackedByteArray()
	else:
		world.wind_field_buffer = _bake_wind_field(world.world_bounds, world.derived_size, 2.0)
		print("  wind field: %dms" % (Time.get_ticks_msec() - t))

		# Phase 3：洋流向量场（RG8），仅海洋像素有意义。Phase 6 改为风驱动 + Ekman 偏转。
		# Systemic Ocean Currents：v2 加入热盐驱动项（经向分量）+ 独立的 upwelling buffer。
		t = Time.get_ticks_msec()
		world.ocean_current_buffer = _bake_ocean_currents(map, hex_size, world, cfg)
		print("  ocean currents: %dms" % (Time.get_ticks_msec() - t))

		t = Time.get_ticks_msec()
		world.ocean_upwelling_buffer = _bake_ocean_upwelling(map, hex_size, world, cfg)
		print("  ocean upwelling: %dms" % (Time.get_ticks_msec() - t))

	# Phase 14：火山强度场（R8），每像素 = 距最近 has_volcano cell 中心的径向衰减
	t = Time.get_ticks_msec()
	world.volcano_field_buffer = _bake_volcano_field(map, hex_size, world)
	print("  volcano field: %dms" % (Time.get_ticks_msec() - t))

	# Emergent Climate Coupling：初始化 sea_ice_fraction buffer（全 0）。
	# 真正的覆盖率数值由 MapGenerator._apply_sea_ice_daily_pass 逐日推进，
	# 再通过 SeaIceAtlasUploadJob → bake_sea_ice_fraction_only 上传到独立的 sea_ice_tex。
	# 这里留一个空 buffer 让首次构建路径有正确的 size 对齐。
	world.sea_ice_fraction_buffer = PackedByteArray()
	world.sea_ice_fraction_buffer.resize(world.derived_size.x * world.derived_size.y)

	# 编码纹理：v9.atlas → 9 张 derived 贴图合并成 3 张 atlas + 独立 height_tex
	t = Time.get_ticks_msec()
	world.height_tex = _encode_height_tex(world.height_buffer, world.hm_size)
	world.enum_atlas_tex = _encode_enum_atlas(
		world.biome_buffer, world.vegetation_buffer, world.cover_buffer,
		world.derived_size
	)
	# Daily Sim SoA Refactor 阶段 1：scalar_atlas 改回 RGB(latitude/flow/moisture)+空 A 通道，
	# 海冰从此走独立 sea_ice_tex（R8），见下方 `_encode_sea_ice_tex` 与
	# `bake_sea_ice_fraction_only` 实现。
	world.scalar_atlas_tex = _encode_scalar_atlas(
		world.moisture_buffer, world.flow_buffer,
		world.latitude_buffer,
		world.derived_size
	)
	# 海冰独立 R8 纹理（地形烘焙后初始化为全 0；首日 SUS Job 触发后会被实际数据 in-place update）。
	world.sea_ice_tex = _encode_r8_tex(world.sea_ice_fraction_buffer, world.derived_size, world.sea_ice_tex)
	world.volcano_field_tex = _encode_r8_tex(world.volcano_field_buffer, world.derived_size, world.volcano_field_tex)
	world.vector_atlas_tex = _encode_vector_atlas(
		world.ocean_current_buffer, world.wind_field_buffer,
		world.derived_size
	)
	# Systemic Ocean Currents：编码独立的 R8 upwelling 纹理
	world.upwelling_tex = _encode_upwelling_tex(world.ocean_upwelling_buffer, world.derived_size)
	# v9.fbm-opt：共享 noise 贴图（首次调用时 lazy 烘焙，之后所有 world 复用同一张）
	world.noise_tex = get_or_build_shared_noise_tex()
	print("  encode: %dms" % (Time.get_ticks_msec() - t))

	print("MapBaker v6: total %dms" % (Time.get_ticks_msec() - t_total))
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
	if world.cover_buffer.size() != pix_count or world.vegetation_buffer.size() != pix_count:
		return
	if _enum_atlas_data_size != Vector2i(W, H) or _enum_atlas_data.size() != pix_count * 3:
		return

	var cover_cache: Dictionary = {}
	var vegetation_cache: Dictionary = {}
	# J: 同步预热 biome 缓存，让下一次 rebake_biome_axes_only 直接走增量路径
	var biome_cache: Dictionary = {}
	for cell_key in world.cell_pixel_lists.keys():
		var cell: HexCell = cell_key
		if cell == null:
			continue
		cover_cache[cell] = int(cell.cover) & 0xFF
		vegetation_cache[cell] = int(cell.vegetation) & 0xFF
		biome_cache[cell] = int(cell.terrain) & 0xFF
	_last_cover_cell_bytes = cover_cache
	_last_vegetation_cell_bytes = vegetation_cache
	_last_biome_cell_bytes = biome_cache
	_cover_cache_size = Vector2i(W, H)
	_vegetation_cache_size = Vector2i(W, H)
	_biome_cache_size = Vector2i(W, H)

# Systemic Ocean Currents：季节切换时重烘洋流 + 上升流 buffer。
# 与夏季基线静态烘焙不同——调用方传入当前 season_phase ∈ [0, 4)，内部在读
# wind_field_buffer 的每一像素后叠加 WindBelt.monsoon_offset_at(ny, phase)，
# 与 WeatherSystem 的融合规则保持一致。热盐驱动项同样按 cfg 权重叠加。
# 产出：
#   - world.ocean_current_buffer（RG8，重写）
#   - world.ocean_upwelling_buffer（R8，重写）
#   - world.vector_atlas_tex（重编码，包含新 RG = ocean_current）
# 注意：wind_field_buffer 本身保持夏季基线不变，monsoon 仅作为 CPU 端融合项。
func rebake_ocean_currents(map: MapData, world: WorldData, hex_size: float,
		cfg: MapConfig, season_phase: float) -> void:
	if world == null:
		return
	# Physical Wind & Ocean Circulation：当物理化开启时，rebake 也走 hex 求解 + 光栅化路径。
	# 与 bake_world 入口策略相同：一次性把三件产物（wind / ocean_current / upwelling）烤好。
	if _use_physical_circulation(cfg):
		var t_phys := Time.get_ticks_msec()
		_physical_solve_for_phase(map, world, hex_size, cfg, season_phase)
		# 把 _pending_wind_buf 替换到 world.wind_field_buffer
		if not _pending_wind_buf.is_empty():
			world.wind_field_buffer = _pending_wind_buf
		var W := world.derived_size.x
		var H := world.derived_size.y
		var cur_buf := PackedByteArray()
		cur_buf.resize(W * H * 2)
		_rasterize_ocean_current_slice_from_hex(world, cur_buf, 0, W * H)
		world.ocean_current_buffer = cur_buf
		var up_buf := PackedByteArray()
		up_buf.resize(W * H)
		_rasterize_upwelling_slice_from_hex(world, up_buf, 0, W * H)
		world.ocean_upwelling_buffer = up_buf
		world.vector_atlas_tex = _encode_vector_atlas(
			world.ocean_current_buffer, world.wind_field_buffer,
			world.derived_size, world.vector_atlas_tex
		)
		world.upwelling_tex = _encode_upwelling_tex(
			world.ocean_upwelling_buffer, world.derived_size, world.upwelling_tex
		)
		# 清状态，让 OceanCurrentsJob 下一轮第一片重新触发求解
		_pending_phys_solved_phase = NAN
		_pending_psi_state = null
		_pending_wind_buf = PackedByteArray()
		print("  rebake_ocean_currents (physical-hex, phase=%.2f): total=%dms" % [
			season_phase, Time.get_ticks_msec() - t_phys
		])
		return
	var t := Time.get_ticks_msec()
	world.ocean_current_buffer = _bake_ocean_currents(map, hex_size, world, cfg, season_phase)
	var t_cur := Time.get_ticks_msec() - t
	t = Time.get_ticks_msec()
	world.ocean_upwelling_buffer = _bake_ocean_upwelling(map, hex_size, world, cfg, season_phase)
	var t_up := Time.get_ticks_msec() - t
	# 重编码 vector atlas（RGBA8：RG=ocean, BA=wind）。wind 维持夏季基线不变。
	world.vector_atlas_tex = _encode_vector_atlas(
		world.ocean_current_buffer, world.wind_field_buffer,
		world.derived_size, world.vector_atlas_tex
	)
	# Systemic Ocean Currents：同步重编码 upwelling R8 纹理（F6 调试层消费）
	world.upwelling_tex = _encode_upwelling_tex(
		world.ocean_upwelling_buffer, world.derived_size, world.upwelling_tex
	)
	print("  rebake_ocean_currents(phase=%.2f): currents=%dms upwelling=%dms" % [
		season_phase, t_cur, t_up
	])

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
		# L: derived_size 变化 → vector atlas 缓存与 _pending_currents_buf 不再匹配。
		# 标失效让下一次 commit 走 fallback 重建路径。
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
	var phase_use: float = _pending_phase

	# 缓存当前切片涉及的行级 monsoon offset。区间 [s, e) 跨多行时按 y 分组缓存。
	var y_start: int = s / W
	var y_end: int = (e - 1) / W  # inclusive
	var monsoons: Array = []
	monsoons.resize(y_end - y_start + 1)
	for yy in range(y_start, y_end + 1):
		var ny0 := float(yy) / float(maxi(H - 1, 1))
		monsoons[yy - y_start] = WindBeltScript.monsoon_offset_at(ny0, phase_use)

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
		wind += monsoons[y - y_start] as Vector2

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
	var phase_use: float = _pending_phase

	# 行级缓存：对切片覆盖的每一行预算一次。
	var y_start: int = s / W
	var y_end: int = (e - 1) / W
	var row_data: Array = []  # element: { lat_signed, lat_signed_abs, lat_temp,
							  # is_cold_sink, cold_sink_byte, ekman_sign,
							  # rot_angle, monsoon, near_edge_y }
	row_data.resize(y_end - y_start + 1)
	for yy in range(y_start, y_end + 1):
		var ny := float(yy) / float(maxi(H - 1, 1))
		var lat_signed := (ny - 0.5) * 2.0
		var lat_signed_abs: float = absf(lat_signed)
		var lat_temp: float = pow(cos(lat_signed_abs * PI * 0.5), 1.2)
		var temp_rel: float = lat_temp - 0.5
		var is_highlat: bool = lat_signed_abs > _UPWELLING_HIGHLAT_ABS
		var is_cold_sink: bool = is_highlat and temp_rel < cold_sink_temp
		var t_cold: float = clampf((cold_sink_temp - temp_rel) / 0.3, 0.0, 1.0) if is_cold_sink else 0.0
		var cold_sink_byte: int = clampi(int(round(128.0 * (1.0 - t_cold))), 0, 128)
		var ekman_sign: float = -1.0 if lat_signed < 0.0 else 1.0
		var rot_angle: float = -ekman_sign * EKMAN_DEFLECTION_RAD
		var monsoon_row: Vector2 = WindBeltScript.monsoon_offset_at(ny, phase_use)
		row_data[yy - y_start] = {
			"is_cold_sink": is_cold_sink,
			"cold_sink_byte": cold_sink_byte,
			"rot_angle": rot_angle,
			"monsoon": monsoon_row,
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
		) + (rd["monsoon"] as Vector2)
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
func commit_ocean_buffers(world: WorldData, update_textures: bool = true) -> Dictionary:
	if world == null:
		return {}
	var t := Time.get_ticks_msec()
	world.ocean_current_buffer = _pending_currents_buf
	world.ocean_upwelling_buffer = _pending_upwelling_buf
	# Physical Wind & Ocean Circulation：物理化路径在 _physical_solve_for_phase 时已
	# 把 hex → pixel 风场 buffer 写入 _pending_wind_buf，commit 时一并替换 world.wind_field_buffer
	# 让 weather_system advection / shader 都看到新风迹。旧路径 _pending_wind_buf
	# 为空，跳过。
	if not _pending_wind_buf.is_empty():
		world.wind_field_buffer = _pending_wind_buf
	if update_textures:
		# I + L: 复用 GPU 句柄 + 持久交错缓冲。
		# Fast path（典型 round 收尾）：_vector_atlas_data 已被 pixel slices 同步更新到位 →
		# 直接 Image.create_from_data + tex.update()，省掉 _encode_vector_atlas 的 620k×4 交错循环。
		# Fallback：缓存未就绪（首次 commit / regenerate） → 走旧整张 _encode_vector_atlas 兜底，
		# 顺便也把 _vector_atlas_data 填好让下次走快路径。
		var W: int = world.derived_size.x
		var H: int = world.derived_size.y
		var atlas_size_match: bool = (_vector_atlas_data_size == Vector2i(W, H) \
				and _vector_atlas_data.size() == W * H * 4 \
				and world.vector_atlas_tex != null \
				and world.vector_atlas_tex.get_size() == Vector2(float(W), float(H)))
		if atlas_size_match:
			var img_va := Image.create_from_data(W, H, false, Image.FORMAT_RGBA8, _vector_atlas_data)
			world.vector_atlas_tex.update(img_va)
		else:
			world.vector_atlas_tex = _encode_vector_atlas(
				world.ocean_current_buffer, world.wind_field_buffer,
				world.derived_size, world.vector_atlas_tex
			)
			_rebuild_vector_atlas_data_from_buffers(world)
		world.upwelling_tex = _encode_upwelling_tex(
			world.ocean_upwelling_buffer, world.derived_size, world.upwelling_tex
		)
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
			# 首次必须整张上传（buffer 完整重写）
			world.enum_atlas_tex = _encode_enum_atlas(
				world.biome_buffer, world.vegetation_buffer, world.cover_buffer,
				world.derived_size, world.enum_atlas_tex
			)
			return

		# ───── 增量路径：典型每日 ─────
		# 遍历所有 cell，逐 cell 比对 byte。命中 byte 不变 → continue（0 像素操作）。
		# 变了 → 把 cell_pixel_lists[cell] 的所有像素批量写入 target_buf。
		# 阶段 P2：同时局部写 _enum_atlas_data 对应通道（cover→B/offset=2, veg→G/offset=1），
		# 最后用 cached data 重组 Image → texture.update()，避免再跑一次 614400 次交错循环。
		# 仅当 _enum_atlas_data 缓存有效时启用 P2 快路径，否则降级为整张 _encode_enum_atlas。
		var any_dirty: bool = false
		var cell_lists: Dictionary = world.cell_pixel_lists
		var atlas_data_valid: bool = (_enum_atlas_data_size == Vector2i(W, H) \
				and _enum_atlas_data.size() == pix_count * 3)
		var channel_offset: int = 2 if axis == "cover" else 1  # B=cover, G=vegetation
		if axis == "cover":
			for cell_key in cell_lists.keys():
				var cc2: HexCell = cell_key
				var b: int = int(cc2.cover) & 0xFF
				var prev_b: int = int(cache_dict.get(cc2, -1))
				if b == prev_b:
					continue
				cache_dict[cc2] = b
				any_dirty = true
				var pixels: PackedInt32Array = cell_lists[cell_key]
				if atlas_data_valid:
					for px in pixels:
						target_buf[px] = b
						_enum_atlas_data[px * 3 + channel_offset] = b
				else:
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
				var pixels: PackedInt32Array = cell_lists[cell_key]
				if atlas_data_valid:
					for px in pixels:
						target_buf[px] = b
						_enum_atlas_data[px * 3 + channel_offset] = b
				else:
					for px in pixels:
						target_buf[px] = b
			_last_vegetation_cell_bytes = cache_dict
			world.vegetation_buffer = target_buf

		if not any_dirty:
			return  # 所有 cell byte 都没变 → 连 GPU 上传都跳过
		# 阶段 P2 快路径：cached data 已被局部更新 → 直接重组 Image + texture.update()
		# 省掉 _encode_enum_atlas 内部 614400 次的 RGB 交错循环（~50ms → ~3ms）。
		if atlas_data_valid and world.enum_atlas_tex != null \
				and world.enum_atlas_tex.get_size() == Vector2(float(W), float(H)):
			var img := Image.create_from_data(W, H, false, Image.FORMAT_RGB8, _enum_atlas_data)
			world.enum_atlas_tex.update(img)
		else:
			# 降级路径：cache 失效或 tex 未建 → 走整张交错（顺便重新填充 cache）
			world.enum_atlas_tex = _encode_enum_atlas(
				world.biome_buffer, world.vegetation_buffer, world.cover_buffer,
				world.derived_size, world.enum_atlas_tex
			)
		return

	# Slow fallback：完整重跑 warp + cube_round（保留兼容性，正常不会走到）
	if _warp_noise_lo == null:
		_init_noise(world.bake_seed)
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
			var v: int
			if axis == "cover":
				v = int(self_cell.cover) if self_cell != null else int(CoverType.CV.NONE)
			else:
				v = int(self_cell.vegetation) if self_cell != null else int(VegetationType.VEG.NONE)
			target_buf[row + x] = v & 0xFF
	if axis == "cover":
		world.cover_buffer = target_buf
	else:
		world.vegetation_buffer = target_buf
	world.enum_atlas_tex = _encode_enum_atlas(
		world.biome_buffer, world.vegetation_buffer, world.cover_buffer,
		world.derived_size, world.enum_atlas_tex
	)
	prewarm_dynamic_axis_caches(map, world)

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
	if world == null or world.biome_buffer.is_empty():
		return
	if _warp_noise_lo == null:
		_init_noise(world.bake_seed)
	var W := world.derived_size.x
	var H := world.derived_size.y
	var pix_count := W * H
	var has_lookup: bool = world.pixel_to_cell_lookup.size() == pix_count
	var has_cell_lists: bool = not world.cell_pixel_lists.is_empty()

	# Cache validity：3 轴 sig + interleaved data 都得齐才走增量。
	var cache_valid: bool = (has_lookup \
			and has_cell_lists \
			and _biome_cache_size == Vector2i(W, H) \
			and _vegetation_cache_size == Vector2i(W, H) \
			and _cover_cache_size == Vector2i(W, H) \
			and _enum_atlas_data_size == Vector2i(W, H) \
			and _enum_atlas_data.size() == pix_count * 3 \
			and not _last_biome_cell_bytes.is_empty() \
			and not _last_vegetation_cell_bytes.is_empty() \
			and not _last_cover_cell_bytes.is_empty() \
			and world.biome_buffer.size() == pix_count \
			and world.vegetation_buffer.size() == pix_count \
			and world.cover_buffer.size() == pix_count)

	if not cache_valid:
		# Fallback：完整路径（首次 / 任意缓存失效）。同步顺便把 3 轴 sig + interleaved data 都建好。
		_rewrite_axis_buffers(map, hex_size, world)
		world.enum_atlas_tex = _encode_enum_atlas(
			world.biome_buffer, world.vegetation_buffer, world.cover_buffer,
			world.derived_size, world.enum_atlas_tex
		)
		prewarm_dynamic_axis_caches(map, world)
		return

	# 增量路径：遍历 ~2400 cell，逐 cell 比 3 轴 byte。
	var biome_buf := world.biome_buffer
	var veg_buf := world.vegetation_buffer
	var cover_buf := world.cover_buffer
	var cell_lists: Dictionary = world.cell_pixel_lists
	var biome_dirty: int = 0
	var veg_dirty: int = 0
	var cover_dirty: int = 0
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
			for px in pixels:
				biome_buf[px] = b_t
				_enum_atlas_data[px * 3] = b_t
		if b_v != prev_v:
			_last_vegetation_cell_bytes[cell] = b_v
			veg_dirty += 1
			for px in pixels:
				veg_buf[px] = b_v
				_enum_atlas_data[px * 3 + 1] = b_v
		if b_c != prev_c:
			_last_cover_cell_bytes[cell] = b_c
			cover_dirty += 1
			for px in pixels:
				cover_buf[px] = b_c
				_enum_atlas_data[px * 3 + 2] = b_c
	world.biome_buffer = biome_buf
	world.vegetation_buffer = veg_buf
	world.cover_buffer = cover_buf

	if biome_dirty + veg_dirty + cover_dirty == 0:
		return  # 全 3 轴 byte 都没变 → 连 GPU 上传都跳过

	# tex.update via cached interleaved data — 省掉 _encode_enum_atlas 内 620k × 3
	# 的交错循环（30-50ms）。tex 句柄复用 → 避免驱动层重新分配。
	if world.enum_atlas_tex != null and world.enum_atlas_tex.get_size() == Vector2(float(W), float(H)):
		var img := Image.create_from_data(W, H, false, Image.FORMAT_RGB8, _enum_atlas_data)
		world.enum_atlas_tex.update(img)
	else:
		world.enum_atlas_tex = _encode_enum_atlas(
			world.biome_buffer, world.vegetation_buffer, world.cover_buffer,
			world.derived_size, world.enum_atlas_tex
		)

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
	if bounds.size.x < 0.01 or bounds.size.y < 0.01:
		return Vector2i(HM_MAX_DIM, HM_MAX_DIM)
	var aspect := bounds.size.x / bounds.size.y
	var w: int
	var h: int
	if aspect >= 1.0:
		w = HM_MAX_DIM
		h = int(round(float(HM_MAX_DIM) / aspect))
	else:
		h = HM_MAX_DIM
		w = int(round(float(HM_MAX_DIM) * aspect))
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
		for chain: Array in chains:
			if chain.size() < 2:
				continue
			# CR 平滑 → warp 扰动（跟 hex 边界共享同一份 _warp_noise_lo），让河流自然弯曲
			var dense := _catmull_rom_dense(chain, RIVER_CR_STEP)
			var warped := _warp_river_chain(dense, hex_size)
			_stamp_polyline_binary(mask, warped, origin, inv_world, W, H, stroke_radius_px)

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
	for cell: HexCell in map.all_cells():
		if not cell.has_river or _is_river_terminal_water(cell.terrain):
			continue
		var key := Vector3i(cell.q, cell.r, cell.s)
		if visited.has(key):
			continue
		var chain := _trace_river_chain(map, cell, hex_size, visited)
		if chain.size() >= 2:
			chains.append(chain)
	return chains

func _trace_river_chain(map: MapData, start: HexCell, hex_size: float, visited: Dictionary) -> Array:
	var chain: Array = []
	chain.append(HexUtils.cube_to_world(start.q, start.r, hex_size))
	visited[Vector3i(start.q, start.r, start.s)] = true

	var current: HexCell = start
	while true:
		var nxt: HexCell = _find_downhill_river_neighbor(map, current)
		if nxt == null:
			break

		# 如果支流流向一段已经烘焙过的主河道，仍然把合流点追加进当前折线。
		# 旧逻辑会因为 visited 直接跳过该邻居，导致支流在合流前一格视觉断开。
		chain.append(HexUtils.cube_to_world(nxt.q, nxt.r, hex_size))
		var nxt_key := Vector3i(nxt.q, nxt.r, nxt.s)
		current = nxt
		if visited.has(nxt_key):
			break
		visited[nxt_key] = true

	# 尾巴伸入终端水体一半，避免河口在最后陆地 cell 中心硬截断。
	# 这里使用河流专用水体判断，包含湖泊；不要复用海洋洋流用的 _is_water()。
	var water_nb := _find_river_terminal_water_neighbor(map, current)
	if water_nb != null:
		var river_end := HexUtils.cube_to_world(current.q, current.r, hex_size)
		var water_center := HexUtils.cube_to_world(water_nb.q, water_nb.r, hex_size)
		chain.append(river_end.lerp(water_center, 0.78))
	return chain

func _find_downhill_river_neighbor(map: MapData, cell: HexCell) -> HexCell:
	var best: HexCell = null
	var lowest: float = cell.elevation  # 关键：只走严格下坡的 has_river 邻居
	for nb: HexCell in map.get_neighbors(cell):
		if not nb.has_river or _is_river_terminal_water(nb.terrain):
			continue
		if nb.elevation < lowest:
			lowest = nb.elevation
			best = nb
	return best

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

# enum_atlas: RGB8 NEAREST  (R=biome, G=vegetation, B=cover)
# v9.perf：existing 非 null 时走 ImageTexture.update() 复用 GPU RID，
# 避免每天 rebake 时反复 alloc/free GPU buffer + 重新绑定 shader uniform
func _encode_enum_atlas(biome_buf: PackedByteArray, veg_buf: PackedByteArray,
		cover_buf: PackedByteArray, size: Vector2i,
		existing: ImageTexture = null) -> ImageTexture:
	var W := size.x
	var H := size.y
	var n := W * H
	var data := PackedByteArray()
	data.resize(n * 3)
	# veg / cover 可能在某些路径上没烤（兜底空数组当全 0）
	var has_veg: bool = veg_buf.size() >= n
	var has_cover: bool = cover_buf.size() >= n
	for i in range(n):
		var di := i * 3
		data[di] = biome_buf[i] if i < biome_buf.size() else 0
		data[di + 1] = veg_buf[i] if has_veg else 0
		data[di + 2] = cover_buf[i] if has_cover else 0
	# 阶段 P2：把交错完成的 RGB8 data 缓存下来，rebake_cover/vegetation 增量路径
	# 直接局部 byte 写入这个 cached data，免去再跑一次 614400 的交错循环。
	_enum_atlas_data = data
	_enum_atlas_data_size = Vector2i(W, H)
	var img := Image.create_from_data(W, H, false, Image.FORMAT_RGB8, data)
	# ImageTexture.get_size() 返回 Vector2，而 W/H 是 int → 用 Vector2 比较
	if existing != null and existing.get_size() == Vector2(float(W), float(H)):
		existing.update(img)
		return existing
	return ImageTexture.create_from_image(img)

# scalar_atlas: RGBA8 LINEAR (R=moisture, G=flow, B=latitude, A=0 reserved)
# moisture/flow/latitude 是 [0,1] 的 float → quantize 到 byte。
# Daily Sim SoA Refactor 阶段 1：A 通道恒为 0（保留位）；海冰已拆到独立 sea_ice_tex。
func _encode_scalar_atlas(moist_buf: PackedFloat32Array, flow_buf: PackedFloat32Array,
		lat_buf: PackedFloat32Array,
		size: Vector2i) -> ImageTexture:
	var W := size.x
	var H := size.y
	var n := W * H
	var data := PackedByteArray()
	data.resize(n * 4)
	var has_moist: bool = moist_buf.size() >= n
	var has_flow: bool = flow_buf.size() >= n
	var has_lat: bool = lat_buf.size() >= n
	for i in range(n):
		var di := i * 4
		data[di]     = int(round(clampf(moist_buf[i], 0.0, 1.0) * 255.0)) if has_moist else 0
		data[di + 1] = int(round(clampf(flow_buf[i], 0.0, 1.0) * 255.0)) if has_flow else 0
		data[di + 2] = int(round(clampf(lat_buf[i], 0.0, 1.0) * 255.0)) if has_lat else 0
		data[di + 3] = 0  # 保留位，原 sea_ice 通道已拆出
	var img := Image.create_from_data(W, H, false, Image.FORMAT_RGBA8, data)
	return ImageTexture.create_from_image(img)

# vector_atlas: RGBA8 LINEAR (RG=ocean_current, BA=wind_field)
# 两个源 buffer 都是 RG8 packed byte（每像素 2 字节）
func _encode_vector_atlas(ocean_buf: PackedByteArray, wind_buf: PackedByteArray,
		size: Vector2i, existing: ImageTexture = null) -> ImageTexture:
	var W := size.x
	var H := size.y
	var n := W * H
	var data := PackedByteArray()
	data.resize(n * 4)
	var has_ocean: bool = ocean_buf.size() >= n * 2
	var has_wind: bool = wind_buf.size() >= n * 2
	# 中性值：[-1,1] 的 0 → 字节 128
	for i in range(n):
		var di := i * 4
		var oi := i * 2
		data[di]     = ocean_buf[oi]     if has_ocean else 128
		data[di + 1] = ocean_buf[oi + 1] if has_ocean else 128
		data[di + 2] = wind_buf[oi]      if has_wind else 128
		data[di + 3] = wind_buf[oi + 1]  if has_wind else 128
	var img := Image.create_from_data(W, H, false, Image.FORMAT_RGBA8, data)
	# I: commit_ocean_buffers 频繁触发；尺寸不变时复用 GPU 句柄，减 30-50ms 上传开销。
	if existing != null and existing.get_size() == Vector2(float(W), float(H)):
		existing.update(img)
		return existing
	return ImageTexture.create_from_image(img)

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

# 通用 R8 → ImageTexture 编码（L8 LINEAR）。传入 existing 会尝试原地 update 以复用 GPU 句柄，
# 避免 refresh_climate_daily 每日创建新纹理带来的驱动层分配开销。
func _encode_r8_tex(buf: PackedByteArray, size: Vector2i, existing: ImageTexture) -> ImageTexture:
	var W := size.x
	var H := size.y
	var n := W * H
	var data := PackedByteArray()
	data.resize(n)
	var has_buf: bool = buf.size() >= n
	for i in range(n):
		data[i] = buf[i] if has_buf else 0
	var img := Image.create_from_data(W, H, false, Image.FORMAT_L8, data)
	if existing != null and existing.get_size() == Vector2(float(W), float(H)):
		existing.update(img)
		return existing
	return ImageTexture.create_from_image(img)

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
	if world == null or map == null:
		return
	var W := world.derived_size.x
	var H := world.derived_size.y
	var n := W * H
	if n <= 0:
		return

	var lookup := world.pixel_to_cell_lookup
	var has_lookup: bool = lookup.size() == n
	if not has_lookup:
		# lookup 缺失：bake_world 必定会填充它，这里走到意味着调用顺序出错。
		# 保守回退为全 0 + 警告，避免访问不存在的 map API。
		push_warning("MapBaker.bake_sea_ice_fraction_only: pixel_to_cell_lookup missing; falling back to zeros")
		var zero_buf := PackedByteArray()
		zero_buf.resize(n)
		world.sea_ice_fraction_buffer = zero_buf
		return

	# Daily-sim perf opt（数据结构层重构）：
	#   原实现每天走 620k 次像素循环（lookup[i] + clampf + round + int 字节码 ~110ms）。
	#   关键事实：陆地 cell 的 sea_ice_fraction 恒为 0；像素一旦初始化为 0 就永久不变。
	#   所以只有水格的像素才需要每日刷新。
	#
	#   新方案：首次调用时（_water_pixel_lists 为空）扫一遍 lookup 构建反向索引
	#     water_pixel_lists[cell] = PackedInt32Array(像素 1D index)
	#   之后每日：
	#     for cell in water_pixel_lists:
	#         byte = round(cell.sea_ice_fraction * 255)
	#         if byte == last_cell_byte[cell]: continue          # 该格无变化 → 0 操作
	#         for px in cell_pixels: buf[px] = byte; sea_ice_only_buf[px] = byte
	#         last_cell_byte[cell] = byte
	#
	#   性能预算：
	#     - 水格 ~1300 个 + 平均覆盖 ~140 像素 = ~180k 像素操作（vs 620k → -71%）
	#     - 字节没变的水格（典型日 70%+ 是赤道远海，恒 0）→ 完全跳过 → 实际 ~50k 操作
	#     - 阶段 1 拆 R8 后 GPU 上传体积 -75%，进一步省驱动开销

	var water_pixel_lists: Dictionary = world.water_cell_pixel_lists
	var cache_valid: bool = (_sea_ice_cache_size == Vector2i(W, H) \
			and _sea_ice_only_buf.size() == n \
			and not water_pixel_lists.is_empty() \
			and world.sea_ice_tex != null \
			and world.sea_ice_tex.get_size() == Vector2(float(W), float(H)))

	if not cache_valid:
		# ───────── 首次构建路径（地形重烘后第一日） ─────────
		# 1) 完整 R8 缓冲：按 lookup 全图扫，写当前 sea_ice_fraction byte。
		# 2) 同时构建 water_cell_pixel_lists 反向索引：cell → 像素 index 数组。
		# 3) 同时构建 _last_sea_ice_cell_bytes：cell → 当前 byte。
		_sea_ice_only_buf = PackedByteArray()
		_sea_ice_only_buf.resize(n)

		var sea_ice_buf := PackedByteArray()
		sea_ice_buf.resize(n)

		# 桶式构建：先按 cell 收集 pixel index（值不写到 PackedInt32Array 的 push_back，
		# 而是先用普通 Array 收集，最后一次性 PackedInt32Array.assign，避开重复扩容开销）。
		var raw_buckets: Dictionary = {}  # HexCell → Array[int]
		var cell_byte_dict: Dictionary = {}  # HexCell → int (byte)

		for i in range(n):
			var cell = lookup[i]
			if cell == null or not _is_water(cell.terrain):
				_sea_ice_only_buf[i] = 0
				sea_ice_buf[i] = 0
				continue
			# 水格：写当前 byte；同时记录到反向索引
			var b: int = int(round(clampf(float(cell.sea_ice_fraction), 0.0, 1.0) * 255.0))
			_sea_ice_only_buf[i] = b
			sea_ice_buf[i] = b
			if not raw_buckets.has(cell):
				raw_buckets[cell] = []
				cell_byte_dict[cell] = b
			(raw_buckets[cell] as Array).push_back(i)

		# Array → PackedInt32Array 一次性 append_array（GDScript 内部 memcpy，
		# 比逐个 push_back 快一个数量级；Godot 4 的 PackedInt32Array 没有 assign 方法）。
		water_pixel_lists.clear()
		for cell_key in raw_buckets.keys():
			var packed := PackedInt32Array()
			packed.append_array(raw_buckets[cell_key] as Array)
			water_pixel_lists[cell_key] = packed
		world.water_cell_pixel_lists = water_pixel_lists
		world.sea_ice_fraction_buffer = sea_ice_buf
		_last_sea_ice_cell_bytes = cell_byte_dict
		_sea_ice_cache_size = Vector2i(W, H)

		# 一次性整张 GPU 上传（R8 / FORMAT_L8）
		var first_img := Image.create_from_data(W, H, false, Image.FORMAT_L8, _sea_ice_only_buf)
		if world.sea_ice_tex != null and world.sea_ice_tex.get_size() == Vector2(float(W), float(H)):
			world.sea_ice_tex.update(first_img)
		else:
			world.sea_ice_tex = ImageTexture.create_from_image(first_img)
		return

	# ───────── 增量路径（典型每日） ─────────
	# 只遍历水格（~1300）；每格如果 byte 不变直接跳过；变了就批量写它的像素列表。
	var sea_ice_buf2 := world.sea_ice_fraction_buffer
	if sea_ice_buf2.size() != n:
		# 极偶发：buf 被外部 resize 过，重建一次零值（陆地像素本就该 0；水格马上覆盖）。
		sea_ice_buf2 = PackedByteArray()
		sea_ice_buf2.resize(n)

	var any_atlas_dirty: bool = false
	for cell_key in water_pixel_lists.keys():
		var cell: HexCell = cell_key
		# Defensive：cell 已变陆地（极少见，地形 in-place 切换）→ 强制 0 并保留在表里
		# （表本身在 bake_world 时会重建，这里只需保证语义正确）。
		var b: int
		if not _is_water(cell.terrain):
			b = 0
		else:
			b = int(round(clampf(float(cell.sea_ice_fraction), 0.0, 1.0) * 255.0))
		var prev_b: int = int(_last_sea_ice_cell_bytes.get(cell, -1))
		if b == prev_b:
			continue  # 该格 byte 未变 → 0 像素写
		_last_sea_ice_cell_bytes[cell] = b
		any_atlas_dirty = true
		var pixels: PackedInt32Array = water_pixel_lists[cell_key]
		for px in pixels:
			sea_ice_buf2[px] = b
			_sea_ice_only_buf[px] = b

	world.sea_ice_fraction_buffer = sea_ice_buf2
	if not any_atlas_dirty:
		return  # 所有水格 byte 都没动 → atlas 不变，连 GPU update 都跳过

	# 至少一个水格变了 → 重新上传 sea_ice_tex（Godot 没有 partial-update API，整张走，
	# 但 R8 比原 RGBA8 小 75%，驱动开销显著降低）
	var img := Image.create_from_data(W, H, false, Image.FORMAT_L8, _sea_ice_only_buf)
	if world.sea_ice_tex != null and world.sea_ice_tex.get_size() == Vector2(float(W), float(H)):
		world.sea_ice_tex.update(img)
	else:
		world.sea_ice_tex = ImageTexture.create_from_image(img)

func bake_weather_field_only(map: MapData, world: WorldData) -> void:
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
	for cell_key in cell_lists.keys():
		var cell: HexCell = cell_key
		if cell == null:
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
# season_phase = 2.0 当 baseline（Plan B 日历对齐：phase=2 = 7 月 = 北半球夏至，对应北半球夏季风 / 南半球冬季风的基线），后续如需季风变化由 shader 端的 season_phase uniform 自己处理（不重烤）。

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
		# Systemic Ocean Currents：当季 monsoon offset（与 weather_system 融合规则一致）
		var monsoon: Vector2 = WindBeltScript.monsoon_offset_at(ny, season_phase)
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

			# 1) 风驱动：读 wind_field 当主流向（+ 当季 monsoon offset）
			var wind: Vector2
			if has_wind:
				var wb_idx := idx * 2
				wind = Vector2(
					float(wind_buf[wb_idx]) / 255.0 * 2.0 - 1.0,
					float(wind_buf[wb_idx + 1]) / 255.0 * 2.0 - 1.0
				)
			else:
				wind = Vector2(1.0, 0.0)
			wind += monsoon

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
		var lat_temp: float = pow(cos(lat_signed_abs * PI * 0.5), 1.2)
		var temp_rel: float = lat_temp - 0.5
		var is_highlat: bool = lat_signed_abs > _UPWELLING_HIGHLAT_ABS
		var is_cold_sink: bool = is_highlat and temp_rel < cold_sink_temp
		var t_cold: float = clampf((cold_sink_temp - temp_rel) / 0.3, 0.0, 1.0) if is_cold_sink else 0.0
		var cold_sink_byte: int = clampi(int(round(128.0 * (1.0 - t_cold))), 0, 128)
		# Ekman sign 也只与半球有关（行级常量）
		var ekman_sign: float = -1.0 if lat_signed < 0.0 else 1.0
		var rot_angle: float = -ekman_sign * EKMAN_DEFLECTION_RAD
		# 当季 monsoon offset 也是 ny 的函数（行级常量）
		var monsoon_row: Vector2 = WindBeltScript.monsoon_offset_at(ny, season_phase)
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

			# 读风（无风则跳过），还得叠加当季 monsoon offset
			if not has_wind:
				continue
			var wb_idx := idx * 2
			var wind := Vector2(
				float(wind_buf[wb_idx]) / 255.0 * 2.0 - 1.0,
				float(wind_buf[wb_idx + 1]) / 255.0 * 2.0 - 1.0
			) + monsoon_row
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

# 强制下一次 _physical_solve_step_one 从 SLP 阶段重新开始。OceanCurrentsJob
# 在新一轮（_round_active=false → true）转换时调一次，确保季节相位变更被
# 重新求解；一次性入口 _physical_solve_for_phase 也调一次，避免和切片路径
# 残留的 _phys_stage 冲突。
func reset_physical_solve_state() -> void:
	_phys_stage = _PHYS_STAGE_NONE
	_phys_psi_iters_done = 0
	_phys_wind_raster_idx = 0
	_pending_phys_solved_phase = NAN
	_pending_psi_state = null
	_pending_wind_buf = PackedByteArray()

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
		cfg: MapConfig, season_phase: float) -> bool:
	if world == null or map == null:
		return true
	# 同 phase 已求解过 → idempotent fast path（caller 不需要外层判断）。
	if not is_nan(_pending_phys_solved_phase) \
			and absf(_pending_phys_solved_phase - season_phase) < 0.001:
		_phys_stage = _PHYS_STAGE_DONE
		return true
	if _phys_stage == _PHYS_STAGE_NONE:
		_phys_stage = _PHYS_STAGE_SLP
		_phys_psi_iters_done = 0
		_pending_psi_state = null

	var profile: ClimateProfile = cfg.climate_profile if cfg != null else null
	var terrain_aware: bool = profile.enable_terrain_aware_wind if profile != null else true
	var heat_transport: bool = profile.enable_ocean_heat_transport if profile != null else true
	var bounds: Rect2 = world.world_bounds

	match _phys_stage:
		_PHYS_STAGE_SLP:
			PhysCircSolverScript.solve_slp_field(map, hex_size, bounds, season_phase)
			_phys_stage = _PHYS_STAGE_WIND
		_PHYS_STAGE_WIND:
			PhysCircSolverScript.solve_wind_field(map, hex_size, bounds, season_phase, terrain_aware)
			if heat_transport:
				_phys_stage = _PHYS_STAGE_PSI_INIT
			else:
				# 跳过 ψ 求解，直接走 fallback ocean current；下一片做 upwelling。
				_pending_psi_state = null
				PhysCircSolverScript.solve_ocean_current_fallback(map, hex_size, bounds, cfg)
				_phys_stage = _PHYS_STAGE_UPWELLING
		_PHYS_STAGE_PSI_INIT:
			_pending_psi_state = PhysCircSolverScript.init_psi_solver(map, hex_size, bounds)
			_phys_psi_iters_done = 0
			_phys_stage = _PHYS_STAGE_PSI_ITERS
		_PHYS_STAGE_PSI_ITERS:
			var iters_to_do: int = mini(
				_PHYS_PSI_ITERS_PER_STEP,
				_PHYS_PSI_TOTAL_ITERS - _phys_psi_iters_done
			)
			if iters_to_do > 0 and _pending_psi_state != null:
				PhysCircSolverScript.step_psi_solver(_pending_psi_state, iters_to_do)
				_phys_psi_iters_done += iters_to_do
			if _phys_psi_iters_done >= _PHYS_PSI_TOTAL_ITERS:
				_phys_stage = _PHYS_STAGE_PSI_FINALIZE
		_PHYS_STAGE_PSI_FINALIZE:
			if _pending_psi_state != null:
				PhysCircSolverScript.psi_to_ocean_current(_pending_psi_state, map, hex_size, bounds, cfg)
				PhysCircSolverScript.commit_psi_to_cells(_pending_psi_state)
			_phys_stage = _PHYS_STAGE_UPWELLING
		_PHYS_STAGE_UPWELLING:
			PhysCircSolverScript.solve_upwelling(map, hex_size, bounds, cfg)
			_phys_stage = _PHYS_STAGE_WIND_RASTER
		_PHYS_STAGE_WIND_RASTER:
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
				# NaN/Inf 守门：若任一 cell 物理量异常，退回 fallback 路径覆写。
				var n_bad: int = 0
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
					PhysCircSolverScript.solve_ocean_current_fallback(map, hex_size, bounds, cfg)
					PhysCircSolverScript.solve_upwelling(map, hex_size, bounds, cfg)
				_ensure_pending_wind_size(world)
			var s_idx: int = _phys_wind_raster_idx
			var e_idx: int = mini(pix_total, s_idx + _PHYS_WIND_RASTER_PIXELS_PER_STEP)
			_rasterize_wind_slice_from_hex(world, _pending_wind_buf, s_idx, e_idx)
			_phys_wind_raster_idx = e_idx
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
# wind_vector 已是单位向量，speed 不进 RG8（与现有 shader 一致）。
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
			wx = cell.wind_vector.x
			wy = cell.wind_vector.y
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
