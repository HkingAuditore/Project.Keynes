# map_baker.gd v6
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

const WindBeltScript = preload("res://scripts/wind_belt.gd")

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
	t = Time.get_ticks_msec()
	world.wind_field_buffer = _bake_wind_field(world.world_bounds, world.derived_size, 1.0)
	print("  wind field: %dms" % (Time.get_ticks_msec() - t))

	# Phase 3：洋流向量场（RG8），仅海洋像素有意义。Phase 6 改为风驱动 + Ekman 偏转。
	t = Time.get_ticks_msec()
	world.ocean_current_buffer = _bake_ocean_currents(map, hex_size, world)
	print("  ocean currents: %dms" % (Time.get_ticks_msec() - t))

	# Phase 14：火山强度场（R8），每像素 = 距最近 has_volcano cell 中心的径向衰减
	t = Time.get_ticks_msec()
	world.volcano_field_buffer = _bake_volcano_field(map, hex_size, world)
	print("  volcano field: %dms" % (Time.get_ticks_msec() - t))

	# 编码纹理：v9.atlas → 9 张 derived 贴图合并成 3 张 atlas + 独立 height_tex
	t = Time.get_ticks_msec()
	world.height_tex = _encode_height_tex(world.height_buffer, world.hm_size)
	world.enum_atlas_tex = _encode_enum_atlas(
		world.biome_buffer, world.vegetation_buffer, world.cover_buffer,
		world.derived_size
	)
	world.scalar_atlas_tex = _encode_scalar_atlas(
		world.moisture_buffer, world.flow_buffer,
		world.latitude_buffer, world.volcano_field_buffer,
		world.derived_size
	)
	world.vector_atlas_tex = _encode_vector_atlas(
		world.ocean_current_buffer, world.wind_field_buffer,
		world.derived_size
	)
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

# 抽出来的单轴 rebake 通用实现：axis ∈ {"cover", "vegetation"}
# v9.perf：fast path 走 world.pixel_to_cell_lookup（每像素 → HexCell 引用）
# 重写整张 buffer 只需 O(W*H) array indexing，~2-3ms。
# fallback 路径（lookup 缺失，例如旧存档加载或 baker 不是 bake_world 跑出来的）
# 仍保留原 warp + cube_round 全跑流程。
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

	# Fast path：lookup 存在且大小一致
	if world.pixel_to_cell_lookup.size() == pix_count:
		var lookup := world.pixel_to_cell_lookup
		if axis == "cover":
			for i in range(pix_count):
				var c: HexCell = lookup[i]
				target_buf[i] = (int(c.cover) if c != null else fallback_default) & 0xFF
		else:
			for i in range(pix_count):
				var c2: HexCell = lookup[i]
				target_buf[i] = (int(c2.vegetation) if c2 != null else fallback_default) & 0xFF
		if axis == "cover":
			world.cover_buffer = target_buf
		else:
			world.vegetation_buffer = target_buf
		# v9.perf：复用已有 ImageTexture（避免每天重新 alloc GPU 资源）
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

# Milestone 2：季节切换时同步重烘 biome / vegetation / cover 三张 R8 纹理。
# height / moisture / flow / latitude / wind / ocean / volcano 全部不动
# （与季节相位无关），所以这里仍然只跑一遍 warp + cube_round。
func rebake_biome_axes_only(map: MapData, world: WorldData, hex_size: float) -> void:
	if world == null or world.biome_buffer.is_empty():
		return
	if _warp_noise_lo == null:
		_init_noise(world.bake_seed)
	_rewrite_axis_buffers(map, hex_size, world)
	# v9.atlas：biome / vegetation / cover 三轴一次编入 enum_atlas
	# v9.perf：复用现有 ImageTexture
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
		chain.append(river_end.lerp(water_center, 0.5))
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
	var img := Image.create_from_data(W, H, false, Image.FORMAT_RGB8, data)
	# ImageTexture.get_size() 返回 Vector2，而 W/H 是 int → 用 Vector2 比较
	if existing != null and existing.get_size() == Vector2(float(W), float(H)):
		existing.update(img)
		return existing
	return ImageTexture.create_from_image(img)

# scalar_atlas: RGBA8 LINEAR (R=moisture, G=flow, B=latitude, A=volcano)
# moisture/flow/latitude 是 [0,1] 的 float → quantize 到 byte
# volcano 已经是 PackedByteArray，直接用
func _encode_scalar_atlas(moist_buf: PackedFloat32Array, flow_buf: PackedFloat32Array,
		lat_buf: PackedFloat32Array, volcano_buf: PackedByteArray,
		size: Vector2i) -> ImageTexture:
	var W := size.x
	var H := size.y
	var n := W * H
	var data := PackedByteArray()
	data.resize(n * 4)
	var has_moist: bool = moist_buf.size() >= n
	var has_flow: bool = flow_buf.size() >= n
	var has_lat: bool = lat_buf.size() >= n
	var has_volcano: bool = volcano_buf.size() >= n
	for i in range(n):
		var di := i * 4
		data[di]     = int(round(clampf(moist_buf[i], 0.0, 1.0) * 255.0)) if has_moist else 0
		data[di + 1] = int(round(clampf(flow_buf[i], 0.0, 1.0) * 255.0)) if has_flow else 0
		data[di + 2] = int(round(clampf(lat_buf[i], 0.0, 1.0) * 255.0)) if has_lat else 0
		data[di + 3] = volcano_buf[i] if has_volcano else 0
	var img := Image.create_from_data(W, H, false, Image.FORMAT_RGBA8, data)
	return ImageTexture.create_from_image(img)

# vector_atlas: RGBA8 LINEAR (RG=ocean_current, BA=wind_field)
# 两个源 buffer 都是 RG8 packed byte（每像素 2 字节）
func _encode_vector_atlas(ocean_buf: PackedByteArray, wind_buf: PackedByteArray,
		size: Vector2i) -> ImageTexture:
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
	return ImageTexture.create_from_image(img)

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
# season_phase = 1.0 当 baseline（夏季视觉），后续如需季风变化由 shader 端的 season_phase uniform 自己处理（不重烤）。

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

func _bake_ocean_currents(map: MapData, hex_size: float, world: WorldData) -> PackedByteArray:
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

	for y in range(H):
		var ny := float(y) / float(maxi(H - 1, 1))
		var wy_base := origin.y + (float(y) + 0.5) * size.y / float(H)
		for x in range(W):
			var wx_base := origin.x + (float(x) + 0.5) * size.x / float(W)
			var idx := y * W + x

			# 是否海洋像素
			var is_ocean := false
			if hm_W == W and hm_H == H:
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

			# 1) 风驱动：读 wind_field 当主流向
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
			if hm_W == W and hm_H == H and x > 0 and x < W - 1 and y > 0 and y < H - 1:
				var hl: float = height[idx - 1]
				var hr: float = height[idx + 1]
				var hu: float = height[idx - W]
				var hd: float = height[idx + W]
				var grad_x := maxf(hl - sea, 0.0) - maxf(hr - sea, 0.0)
				var grad_y := maxf(hu - sea, 0.0) - maxf(hd - sea, 0.0)
				cur.x += grad_x * 4.0
				cur.y += grad_y * 4.0

			if cur.length() > 1.0:
				cur = cur.normalized()
			buf[idx * 2]     = clampi(int(round((cur.x * 0.5 + 0.5) * 255.0)), 0, 255)
			buf[idx * 2 + 1] = clampi(int(round((cur.y * 0.5 + 0.5) * 255.0)), 0, 255)
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
	return t == TerrainType.TERRAIN.OCEAN or t == TerrainType.TERRAIN.COAST
