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

# ─── 分辨率 ───────────────────────────────────────────────────────────────
const HM_MAX_DIM := 1024  # hex-driven 模式下不需要 2048（hex 网格本身只 60×40，1024 已经远超）

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

	var t_total := Time.get_ticks_msec()
	print("MapBaker v6: hm=%s seed=%d" % [world.hm_size, seed_val])

	# 一次循环同时算 heightmap + biome + moisture（共享 warp 计算）
	var t := Time.get_ticks_msec()
	var height_buf := PackedFloat32Array()
	var biome_buf := PackedByteArray()
	var moist_buf := PackedFloat32Array()
	height_buf.resize(world.hm_size.x * world.hm_size.y)
	biome_buf.resize(world.hm_size.x * world.hm_size.y)
	moist_buf.resize(world.hm_size.x * world.hm_size.y)
	_bake_height_biome_moisture(map, hex_size, world, height_buf, biome_buf, moist_buf)
	world.height_buffer = height_buf
	world.biome_buffer = biome_buf
	world.moisture_buffer = moist_buf
	print("  height+biome+moisture: %dms" % (Time.get_ticks_msec() - t))

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

	# 编码纹理
	t = Time.get_ticks_msec()
	world.height_tex = _encode_height_tex(world.height_buffer, world.hm_size)
	world.moisture_tex = _encode_byte_tex_from_float(world.moisture_buffer, world.derived_size)
	world.flow_tex = _encode_byte_tex_from_float(world.flow_buffer, world.derived_size)
	world.biome_tex = _encode_biome_tex(world.biome_buffer, world.derived_size)
	print("  encode: %dms" % (Time.get_ticks_msec() - t))

	print("MapBaker v6: total %dms" % (Time.get_ticks_msec() - t_total))
	return world

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
	moist_buf: PackedFloat32Array
) -> void:
	var W := world.hm_size.x
	var H := world.hm_size.y
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
		if not cell.has_river or _is_water(cell.terrain):
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
		var nxt: HexCell = null
		var lowest: float = current.elevation  # 关键：只走严格下坡的 has_river 邻居
		for nb: HexCell in map.get_neighbors(current):
			if not nb.has_river or _is_water(nb.terrain):
				continue
			var k := Vector3i(nb.q, nb.r, nb.s)
			if visited.has(k):
				continue
			if nb.elevation < lowest:
				lowest = nb.elevation
				nxt = nb
		if nxt == null:
			break
		chain.append(HexUtils.cube_to_world(nxt.q, nxt.r, hex_size))
		visited[Vector3i(nxt.q, nxt.r, nxt.s)] = true
		current = nxt

	# 尾巴伸入海里一半，避免河口在最后陆地 cell 中心硬截断
	var water_nb := _find_water_neighbor(map, current)
	if water_nb != null:
		var river_end := HexUtils.cube_to_world(current.q, current.r, hex_size)
		var water_center := HexUtils.cube_to_world(water_nb.q, water_nb.r, hex_size)
		chain.append(river_end.lerp(water_center, 0.5))
	return chain

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

func _find_water_neighbor(map: MapData, cell: HexCell) -> HexCell:
	var best: HexCell = null
	for nb: HexCell in map.get_neighbors(cell):
		if not _is_water(nb.terrain):
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

func _encode_byte_tex_from_float(buf: PackedFloat32Array, size: Vector2i) -> ImageTexture:
	var W := size.x
	var H := size.y
	var data := PackedByteArray()
	data.resize(W * H)
	for i in range(W * H):
		data[i] = int(round(clampf(buf[i], 0.0, 1.0) * 255.0))
	var img := Image.create_from_data(W, H, false, Image.FORMAT_R8, data)
	return ImageTexture.create_from_image(img)

func _encode_biome_tex(buf: PackedByteArray, size: Vector2i) -> ImageTexture:
	var img := Image.create_from_data(size.x, size.y, false, Image.FORMAT_R8, buf)
	return ImageTexture.create_from_image(img)

# ─── 工具 ─────────────────────────────────────────────────────────────────

static func _is_water(t: int) -> bool:
	return t == TerrainType.TERRAIN.OCEAN or t == TerrainType.TERRAIN.COAST
