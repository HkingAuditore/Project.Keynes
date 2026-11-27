# ptt_gi_baker.gd
# 轻量化 Precomputed Terrain Transfer GI（PTT-GI）静态传输烘焙器。
#
# 在低分辨率 GI 网格（默认上限 128x96，2:1 地图为 128x64，宽高严格在 [16, 255] 内
# 以便 (x, y) 坐标无损存入单个 RGBA8 字节）上，对高度场做确定性余弦加权半球射线步进
# （支持 wrap_x 东西环绕），产出三张轻量静态/半静态纹理：
#   1. ptt_transfer_idx_tex : 4 层 RGBA8 Texture2DArray（K = 8 共享权重重采样坐标，
#                             每层 l ∈ 0..3 存 2 个来源 GI texel：R=x0, G=y0, B=x1, A=y1）
#   2. ptt_coupling_tex     : RGBA8 ImageTexture（R = round(C_i * 255),
#                             G = round((nx*0.5+0.5)*255), B = round((ny*0.5+0.5)*255),
#                             A = round(clamp(nz, 0, 1) * 255)）
#   3. ptt_albedo_tex       : RGBA8 ImageTexture（RGB = 下采样地表代表色，A = 255 陆地 / 0 水体）
#
# 注意：本文件不 preload map_baker.gd，保持 MapBaker -> PttGiBaker -> WorldData 单向依赖。

class_name PttGiBaker
extends RefCounted

const TRANSFER_LAYERS := 4
const TRANSFER_K := 8
const DEFAULT_MAX_W := 128
const DEFAULT_MAX_H := 96
const MIN_DIM := 16
const MAX_DIM := 255
const DEFAULT_RAY_COUNT := 32
const WORLD_BAKE_RAY_COUNT := 24
const DEFAULT_MAX_STEPS := 28
const DEFAULT_HEIGHT_SCALE_HEX := 16.0
const GOLDEN_RATIO_CONJUGATE := 0.6180339887498949

# 与 MapBaker._BOUNCE_ALBEDO / _BOUNCE_WATER_TERRAINS 保持一致（按 TerrainType.TERRAIN 枚举序）
const _BOUNCE_ALBEDO: Array = [
	Color(0.10, 0.16, 0.26),  # OCEAN
	Color(0.16, 0.28, 0.36),  # COAST
	Color(0.48, 0.50, 0.34),  # PLAIN
	Color(0.42, 0.52, 0.28),  # GRASSLAND
	Color(0.22, 0.34, 0.20),  # FOREST
	Color(0.45, 0.42, 0.30),  # HILL
	Color(0.46, 0.44, 0.42),  # MOUNTAIN
	Color(0.76, 0.66, 0.44),  # DESERT
	Color(0.48, 0.48, 0.44),  # TUNDRA
	Color(0.84, 0.87, 0.92),  # SNOW
	Color(0.30, 0.36, 0.26),  # SWAMP
	Color(0.18, 0.32, 0.16),  # JUNGLE
	Color(0.56, 0.52, 0.28),  # SAVANNA
	Color(0.24, 0.32, 0.24),  # TAIGA
	Color(0.52, 0.50, 0.32),  # STEPPE
	Color(0.44, 0.44, 0.30),  # SHRUBLAND
	Color(0.22, 0.34, 0.24),  # MANGROVE
	Color(0.82, 0.88, 0.94),  # GLACIER
	Color(0.14, 0.24, 0.34),  # LAKE
	Color(0.24, 0.44, 0.44),  # REEF
	Color(0.80, 0.86, 0.92),  # SEA_ICE
	Color(0.18, 0.32, 0.30),  # KELP
	Color(0.38, 0.44, 0.30),  # DELTA
	Color(0.40, 0.50, 0.30),  # OASIS
	Color(0.84, 0.82, 0.76),  # SALT_FLAT
	Color(0.60, 0.42, 0.32),  # BADLANDS
	Color(0.62, 0.60, 0.52),  # COLD_DESERT
	Color(0.46, 0.44, 0.28),  # CHAPARRAL
	Color(0.34, 0.34, 0.26),  # MOOR
	Color(0.42, 0.48, 0.30),  # FLOODPLAIN
	Color(0.58, 0.44, 0.34),  # MESA
]
const _BOUNCE_FALLBACK := Color(0.45, 0.45, 0.42)
const _BOUNCE_WATER_TERRAINS: Array = [0, 1, 18, 19, 21]


## 按 hm_size 纵横比计算 GI 网格尺寸，宽上限 max_w（默认 128）、高上限 max_h（默认 96），
## 且双轴均在 [16, 255] 内以确保单个 RGBA8 字节无损编码 (x, y)。
static func resolve_gi_size(hm_size: Vector2i, max_w: int = DEFAULT_MAX_W,
		max_h: int = DEFAULT_MAX_H) -> Vector2i:
	var cap_w := clampi(max_w, MIN_DIM, MAX_DIM)
	var cap_h := clampi(max_h, MIN_DIM, MAX_DIM)
	if hm_size.x <= 0 or hm_size.y <= 0:
		return Vector2i(mini(128, cap_w), mini(64, cap_h))
	var aspect := float(hm_size.x) / float(hm_size.y)
	var cap_aspect := float(cap_w) / float(cap_h)
	var w: int
	var h: int
	if aspect >= cap_aspect:
		w = cap_w
		h = int(round(float(cap_w) / aspect))
	else:
		h = cap_h
		w = int(round(float(cap_h) * aspect))
	return Vector2i(clampi(w, MIN_DIM, MAX_DIM), clampi(h, MIN_DIM, MAX_DIM))


## 为 WorldData 烘焙 PTT-GI 静态传输纹理与初始地表代表色纹理。
static func bake_world(_map: MapData, world: WorldData, hex_size: float,
		bounce_bytes: PackedByteArray = PackedByteArray()) -> Dictionary:
	if world == null:
		return {"ok": false, "reason": "world_null"}
	if world.height_buffer.is_empty() or world.hm_size.x <= 0 or world.hm_size.y <= 0:
		world.ptt_gi_ready = false
		return {"ok": false, "reason": "empty_height_buffer"}

	var t0 := Time.get_ticks_msec()
	var gi_size := resolve_gi_size(world.hm_size)
	var world_size := world.world_bounds.size
	if world_size.x <= 0.001 or world_size.y <= 0.001:
		world_size = Vector2(float(world.hm_size.x), float(world.hm_size.y))
	var height_scale_hex := maxf(float(ProjectSettings.get_setting(
		"project_keynes/rendering/map_tiles/horizon_height_scale_hex",
		DEFAULT_HEIGHT_SCALE_HEX)), 0.01)
	var height_world_scale := maxf(hex_size * height_scale_hex, 1e-4)
	var wrap_x := world.wrap_period_x > 0.0001

	var res := bake_from_height_buffer(
		world.height_buffer, world.hm_size, world_size,
		height_world_scale, world.sea_level, wrap_x, gi_size, WORLD_BAKE_RAY_COUNT)
	if not bool(res.get("ok", false)):
		world.ptt_gi_ready = false
		return res

	world.ptt_transfer_idx_tex = res["transfer_idx_tex"]
	world.ptt_coupling_tex = res["coupling_tex"]
	world.ptt_gi_size = gi_size
	var albedo_ok := refresh_albedo(world, bounce_bytes)
	world.ptt_gi_ready = world.ptt_transfer_idx_tex != null \
		and world.ptt_coupling_tex != null \
		and world.ptt_albedo_tex != null \
		and albedo_ok
	var elapsed := Time.get_ticks_msec() - t0
	print("[ptt-gi] baked size=%s rays=%d wrap_x=%s ready=%s ms=%d" % [
		str(gi_size), WORLD_BAKE_RAY_COUNT, str(wrap_x), str(world.ptt_gi_ready), elapsed])
	res["albedo_tex"] = world.ptt_albedo_tex
	res["ok"] = world.ptt_gi_ready
	res["elapsed_ms"] = elapsed
	return res


## 直接从高度缓冲烘焙 PTT-GI 传输索引（4 层 RGBA8 Texture2DArray）与耦合/粗法线图。
## 供 bake_world 与单元测试共用。
static func bake_from_height_buffer(
		height_buf: PackedFloat32Array,
		hm_size: Vector2i,
		world_size: Vector2,
		height_world_scale: float,
		sea_level: float,
		wrap_x: bool,
		gi_size: Vector2i = Vector2i(128, 64),
		ray_count: int = DEFAULT_RAY_COUNT) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	var hm_w := hm_size.x
	var hm_h := hm_size.y
	if hm_w <= 0 or hm_h <= 0 or height_buf.size() < hm_w * hm_h:
		return {"ok": false, "reason": "invalid_height_buffer"}

	var gw := clampi(gi_size.x, MIN_DIM, MAX_DIM)
	var gh := clampi(gi_size.y, MIN_DIM, MAX_DIM)
	var target_size := Vector2i(gw, gh)
	var ws_x := world_size.x if world_size.x > 0.001 else float(hm_w)
	var ws_y := world_size.y if world_size.y > 0.001 else float(hm_h)
	var h_scale := maxf(height_world_scale, 1e-4)
	var n_rays := clampi(ray_count, 8, 64)
	var max_steps := clampi(mini(maxi(gw, gh), DEFAULT_MAX_STEPS), 8, 64)

	# 1. 下采样高度图到 gi_size（区域均值，水面钳制在 sea_level）
	var n_texels := gw * gh
	var z_grid := PackedFloat32Array()
	z_grid.resize(n_texels)
	var max_z_global := -1e20
	var min_z_global := 1e20
	var fx_step := float(hm_w) / float(gw)
	var fy_step := float(hm_h) / float(gh)
	for gy in range(gh):
		var sy0 := clampi(int(floor(float(gy) * fy_step)), 0, hm_h - 1)
		var sy1 := clampi(int(ceil(float(gy + 1) * fy_step)), sy0 + 1, hm_h)
		var row_off := gy * gw
		for gx in range(gw):
			var sx0 := clampi(int(floor(float(gx) * fx_step)), 0, hm_w - 1)
			var sx1 := clampi(int(ceil(float(gx + 1) * fx_step)), sx0 + 1, hm_w)
			var h_sum := 0.0
			var cnt := 0
			for sy in range(sy0, sy1):
				var s_row := sy * hm_w
				for sx in range(sx0, sx1):
					h_sum += height_buf[s_row + sx]
					cnt += 1
			var h_avg := h_sum / float(cnt) if cnt > 0 else sea_level
			var z_val := maxf(h_avg, sea_level) * h_scale
			z_grid[row_off + gx] = z_val
			if z_val > max_z_global:
				max_z_global = z_val
			if z_val < min_z_global:
				min_z_global = z_val

	var dx := ws_x / float(gw)
	var dy := ws_y / float(gh)
	var inv_dx := 1.0 / maxf(dx, 1e-5)
	var inv_dy := 1.0 / maxf(dy, 1e-5)
	var z_range := max_z_global - min_z_global
	var z_bias := maxf(z_range * 1e-4, 1e-4)
	var is_completely_flat := z_range <= 1e-6

	# 2. 预计算粗法线（gi_size 中心差分）
	var nx_arr := PackedFloat32Array()
	var ny_arr := PackedFloat32Array()
	var nz_arr := PackedFloat32Array()
	nx_arr.resize(n_texels)
	ny_arr.resize(n_texels)
	nz_arr.resize(n_texels)

	for gy in range(gh):
		var yu := maxi(gy - 1, 0)
		var yd := mini(gy + 1, gh - 1)
		var span_y := float(maxi(yd - yu, 1)) * dy
		var inv_span_y := 1.0 / maxf(span_y, 1e-5)
		var row_off := gy * gw
		var row_u := yu * gw
		var row_d := yd * gw
		for gx in range(gw):
			var xl: int
			var xr: int
			var span_x_cells: float
			if wrap_x:
				xl = gx - 1 if gx > 0 else gw - 1
				xr = gx + 1 if gx < gw - 1 else 0
				span_x_cells = 2.0
			else:
				xl = maxi(gx - 1, 0)
				xr = mini(gx + 1, gw - 1)
				span_x_cells = float(maxi(xr - xl, 1))
			var dz_dx := (z_grid[row_off + xr] - z_grid[row_off + xl]) / maxf(span_x_cells * dx, 1e-5)
			var dz_dy := (z_grid[row_d + gx] - z_grid[row_u + gx]) * inv_span_y
			var len_inv := 1.0 / sqrt(dz_dx * dz_dx + dz_dy * dz_dy + 1.0)
			var idx := row_off + gx
			nx_arr[idx] = -dz_dx * len_inv
			ny_arr[idx] = -dz_dy * len_inv
			nz_arr[idx] = len_inv

	# 3. 预计算切空间确定性余弦加权半球射线（Malley + Golden-angle）
	var ray_lx := PackedFloat32Array()
	var ray_ly := PackedFloat32Array()
	var ray_lz := PackedFloat32Array()
	ray_lx.resize(n_rays)
	ray_ly.resize(n_rays)
	ray_lz.resize(n_rays)
	var inv_n_rays := 1.0 / float(n_rays)
	for r in range(n_rays):
		var u1 := (float(r) + 0.5) * inv_n_rays
		var u2 := fposmod(float(r) * GOLDEN_RATIO_CONJUGATE, 1.0)
		var phi := TAU * u2
		var sin_t := sqrt(u1)
		var cos_t := sqrt(maxf(0.0, 1.0 - u1))
		ray_lx[r] = cos(phi) * sin_t
		ray_ly[r] = sin(phi) * sin_t
		ray_lz[r] = cos_t

	# 4. 分配输出字节数组
	var coupling_bytes := PackedByteArray()
	coupling_bytes.resize(n_texels * 4)
	var layer_bytes: Array = []
	for _l in range(TRANSFER_LAYERS):
		var lb := PackedByteArray()
		lb.resize(n_texels * 4)
		layer_bytes.append(lb)

	var lb0: PackedByteArray = layer_bytes[0]
	var lb1: PackedByteArray = layer_bytes[1]
	var lb2: PackedByteArray = layer_bytes[2]
	var lb3: PackedByteArray = layer_bytes[3]

	# 复用命中临时缓冲，避免热循环分配
	var hit_ids := PackedInt32Array()
	hit_ids.resize(n_rays)
	var uniq_ids := PackedInt32Array()
	var uniq_w := PackedInt32Array()
	uniq_ids.resize(n_rays)
	uniq_w.resize(n_rays)
	var slot_x := PackedInt32Array()
	var slot_y := PackedInt32Array()
	slot_x.resize(TRANSFER_K)
	slot_y.resize(TRANSFER_K)

	var f_gw := float(gw)
	var f_gh := float(gh)

	# 5. 对每个 GI texel 发射 N 条余弦加权半球射线并做高度场步进
	for gy in range(gh):
		var row_off := gy * gw
		for gx in range(gw):
			var idx := row_off + gx
			var p4 := idx * 4
			var nx := nx_arr[idx]
			var ny := ny_arr[idx]
			var nz := nz_arr[idx]
			var z0 := z_grid[idx]

			# 写粗法线到 coupling_bytes 的 G, B, A
			coupling_bytes[p4 + 1] = clampi(int(round((nx * 0.5 + 0.5) * 255.0)), 0, 255)
			coupling_bytes[p4 + 2] = clampi(int(round((ny * 0.5 + 0.5) * 255.0)), 0, 255)
			coupling_bytes[p4 + 3] = clampi(int(round(clampf(nz, 0.0, 1.0) * 255.0)), 0, 255)

			var hit_count := 0
			if not is_completely_flat:
				# 构造正交切空间基 (T, B, N)，因为 nz > 0 保证分母非零
				var t_len_inv := 1.0 / sqrt(nz * nz + nx * nx)
				var tx := nz * t_len_inv
				var tz := -nx * t_len_inv
				# B = N × T = (-ny*nx, nx*nx + nz*nz, -ny*nz) * t_len_inv
				var bx := -ny * nx * t_len_inv
				var by := (nx * nx + nz * nz) * t_len_inv
				var bz := -ny * nz * t_len_inv

				var origin_gx := float(gx) + 0.5
				var origin_gy := float(gy) + 0.5

				for r in range(n_rays):
					var lx := ray_lx[r]
					var ly := ray_ly[r]
					var lz := ray_lz[r]
					# 世界空间方向 (rx, ry, rz)
					var rx := tx * lx + bx * ly + nx * lz
					var ry := by * ly + ny * lz
					var rz := tz * lx + bz * ly + nz * lz

					# 已经在全局最高点且射线朝上，不可能命中
					if rz > 0.0 and z0 >= max_z_global - z_bias:
						continue

					# 换算为每“网格步”的增量（规范化使单步水平跨度恰好为 1 格）
					var dgx := rx * inv_dx
					var dgy := ry * inv_dy
					var g_horiz := sqrt(dgx * dgx + dgy * dgy)
					if g_horiz < 1e-5:
						continue
					var inv_gh := 1.0 / g_horiz
					var step_gx := dgx * inv_gh
					var step_gy := dgy * inv_gh
					var step_z := rz * inv_gh

					var cur_gx := origin_gx
					var cur_gy := origin_gy
					var cur_z := z0
					var dt := 1.0

					for _s in range(max_steps):
						cur_gx += step_gx * dt
						cur_gy += step_gy * dt
						cur_z += step_z * dt

						if cur_gy < 0.0 or cur_gy >= f_gh:
							break
						if wrap_x:
							if cur_gx < 0.0:
								cur_gx = fposmod(cur_gx, f_gw)
							elif cur_gx >= f_gw:
								cur_gx = fposmod(cur_gx, f_gw)
						else:
							if cur_gx < 0.0 or cur_gx >= f_gw:
								break

						# 若射线已高于全局最高点且仍在上升，必然射向天空
						if step_z >= 0.0 and cur_z > max_z_global + z_bias:
							break

						var ix := clampi(int(cur_gx), 0, gw - 1)
						var iy := clampi(int(cur_gy), 0, gh - 1)
						if ix != gx or iy != gy:
							if z_grid[iy * gw + ix] > cur_z + z_bias:
								hit_ids[hit_count] = iy * gw + ix
								hit_count += 1
								break
						dt *= 1.07

			# 写耦合因子 C_i = hit_count / N 到 coupling_bytes R 通道
			var c_i := float(hit_count) * inv_n_rays
			coupling_bytes[p4] = clampi(int(round(c_i * 255.0)), 0, 255)

			# 6. K=8 系统分层重采样（Weighted Resampling）
			if hit_count == 0:
				for k in range(TRANSFER_K):
					slot_x[k] = gx
					slot_y[k] = gy
			else:
				# 聚合命中直方图（hit_count <= 64，线性去重比 Dictionary 更快且完全确定性）
				var uniq_cnt := 0
				for h_i in range(hit_count):
					var hid := hit_ids[h_i]
					var found := -1
					for u_i in range(uniq_cnt):
						if uniq_ids[u_i] == hid:
							found = u_i
							break
					if found >= 0:
						uniq_w[found] += 1
					else:
						uniq_ids[uniq_cnt] = hid
						uniq_w[uniq_cnt] = 1
						uniq_cnt += 1

				# 按累积权重等距分层抽取 K=8 个共享权重样本
				var step_w := float(hit_count) / float(TRANSFER_K)
				var u_cursor := 0
				var cdf := float(uniq_w[0])
				for k in range(TRANSFER_K):
					var target_w := (float(k) + 0.5) * step_w
					while u_cursor + 1 < uniq_cnt and cdf < target_w:
						u_cursor += 1
						cdf += float(uniq_w[u_cursor])
					var chosen_id := uniq_ids[u_cursor]
					@warning_ignore("integer_division")
					slot_y[k] = chosen_id / gw
					slot_x[k] = chosen_id - slot_y[k] * gw

			# 打包写入 4 层 RGBA8（每层存 2 个坐标：R=x0, G=y0, B=x1, A=y1）
			lb0[p4] = slot_x[0]
			lb0[p4 + 1] = slot_y[0]
			lb0[p4 + 2] = slot_x[1]
			lb0[p4 + 3] = slot_y[1]

			lb1[p4] = slot_x[2]
			lb1[p4 + 1] = slot_y[2]
			lb1[p4 + 2] = slot_x[3]
			lb1[p4 + 3] = slot_y[3]

			lb2[p4] = slot_x[4]
			lb2[p4 + 1] = slot_y[4]
			lb2[p4 + 2] = slot_x[5]
			lb2[p4 + 3] = slot_y[5]

			lb3[p4] = slot_x[6]
			lb3[p4 + 1] = slot_y[6]
			lb3[p4 + 2] = slot_x[7]
			lb3[p4 + 3] = slot_y[7]

	# 7. 构建 GPU 纹理
	var layer_images: Array[Image] = []
	for l in range(TRANSFER_LAYERS):
		var img := Image.create_from_data(gw, gh, false, Image.FORMAT_RGBA8, layer_bytes[l])
		layer_images.append(img)
	var transfer_tex := Texture2DArray.new()
	var err := transfer_tex.create_from_images(layer_images)
	if err != OK:
		push_error("[ptt-gi] transfer Texture2DArray create_from_images failed: %s" % error_string(err))
		return {"ok": false, "reason": "transfer_tex_create_failed"}

	var coupling_img := Image.create_from_data(gw, gh, false, Image.FORMAT_RGBA8, coupling_bytes)
	var coupling_tex := ImageTexture.create_from_image(coupling_img)

	return {
		"ok": true,
		"gi_size": target_size,
		"transfer_idx_tex": transfer_tex,
		"coupling_tex": coupling_tex,
		"coupling_bytes": coupling_bytes,
		"transfer_layers_bytes": layer_bytes,
		"elapsed_ms": Time.get_ticks_msec() - t0,
	}


## 下采样/刷新 world.ptt_albedo_tex（RGBA8，RGB = 地表代表色，A = 255 陆地 / 0 水体）。
## 优先消费 world.bounce_lut_tex（运行期每日刷新自动带雪盖/物候变化），
## 不可用时回退 world.biome_buffer / world.enum_atlas_tex + 内置地表反照率表。
static func refresh_albedo(world: WorldData,
		bounce_bytes: PackedByteArray = PackedByteArray()) -> bool:
	if world == null:
		return false
	var gi_size := world.ptt_gi_size
	if gi_size.x <= 0 or gi_size.y <= 0:
		if world.hm_size.x <= 0 or world.hm_size.y <= 0:
			return false
		gi_size = resolve_gi_size(world.hm_size)
		world.ptt_gi_size = gi_size

	var gw := gi_size.x
	var gh := gi_size.y
	var out_bytes := PackedByteArray()
	out_bytes.resize(gw * gh * 4)

	var filled := false

	# 路径 1：优先使用 bounce_lut_tex + cell 索引映射（带每日雪盖/枯荣变化）
	if not bounce_bytes.is_empty() and world.lut_dims.x > 0 and world.lut_dims.y > 0:
		var lut_slots := world.lut_dims.x * world.lut_dims.y
		var src_size := world.derived_size if (world.derived_size.x > 0 and world.derived_size.y > 0) else world.hm_size
		var sw := src_size.x
		var sh := src_size.y
		var use_owner := sw > 0 and sh > 0 \
			and world.pixel_owner_indices.size() == sw * sh \
			and world.pixel_owner_present.size() == sw * sh
		var enum_data := PackedByteArray()
		var ew := 0
		var eh := 0
		if not use_owner and world.enum_atlas_tex != null:
			var enum_img := world.enum_atlas_tex.get_image()
			if enum_img != null and enum_img.get_format() == Image.FORMAT_RGBA8:
				enum_data = enum_img.get_data()
				ew = enum_img.get_width()
				eh = enum_img.get_height()

		if bounce_bytes.size() >= lut_slots * 4 and (use_owner or (ew > 0 and eh > 0)):
			var sample_w := sw if use_owner else ew
			var sample_h := sh if use_owner else eh
			for gy in range(gh):
				var sy := clampi(int((float(gy) + 0.5) / float(gh) * float(sample_h)), 0, sample_h - 1)
				var dst_row := gy * gw
				var src_row := sy * sample_w
				for gx in range(gw):
					var sx := clampi(int((float(gx) + 0.5) / float(gw) * float(sample_w)), 0, sample_w - 1)
					var sp := src_row + sx
					var cell_idx := -1
					if use_owner:
						if world.pixel_owner_present[sp] != 0:
							cell_idx = int(world.pixel_owner_indices[sp])
					else:
						var ep := sp * 4
						var cid := int(enum_data[ep + 1]) | (int(enum_data[ep + 2]) << 8)
						if cid != 0xFFFF:
							cell_idx = cid
					var dp := (dst_row + gx) * 4
					if cell_idx >= 0 and cell_idx < lut_slots:
						var bp := cell_idx * 4
						out_bytes[dp] = bounce_bytes[bp]
						out_bytes[dp + 1] = bounce_bytes[bp + 1]
						out_bytes[dp + 2] = bounce_bytes[bp + 2]
						out_bytes[dp + 3] = bounce_bytes[bp + 3]
					else:
						out_bytes[dp] = int(_BOUNCE_FALLBACK.r * 255.0)
						out_bytes[dp + 1] = int(_BOUNCE_FALLBACK.g * 255.0)
						out_bytes[dp + 2] = int(_BOUNCE_FALLBACK.b * 255.0)
						out_bytes[dp + 3] = 0
			filled = true

	# 路径 2：回退 biome_buffer + _BOUNCE_ALBEDO
	if not filled and not world.biome_buffer.is_empty():
		var b_size := world.derived_size if (world.derived_size.x > 0 and world.derived_size.y > 0) else world.hm_size
		var bw := b_size.x
		var bh := b_size.y
		if bw > 0 and bh > 0 and world.biome_buffer.size() >= bw * bh:
			var palette_n := _BOUNCE_ALBEDO.size()
			for gy in range(gh):
				var sy := clampi(int((float(gy) + 0.5) / float(gh) * float(bh)), 0, bh - 1)
				var dst_row := gy * gw
				var src_row := sy * bw
				for gx in range(gw):
					var sx := clampi(int((float(gx) + 0.5) / float(gw) * float(bw)), 0, bw - 1)
					var tid := int(world.biome_buffer[src_row + sx])
					var col: Color = _BOUNCE_ALBEDO[tid] if tid < palette_n else _BOUNCE_FALLBACK
					var is_water := tid in _BOUNCE_WATER_TERRAINS
					var dp := (dst_row + gx) * 4
					out_bytes[dp] = clampi(int(round(col.r * 255.0)), 0, 255)
					out_bytes[dp + 1] = clampi(int(round(col.g * 255.0)), 0, 255)
					out_bytes[dp + 2] = clampi(int(round(col.b * 255.0)), 0, 255)
					out_bytes[dp + 3] = 0 if is_water else 255
			filled = true

	# 路径 3：回退 enum_atlas_tex 的 R 通道（biome）
	if not filled and world.enum_atlas_tex != null:
		var enum_img := world.enum_atlas_tex.get_image()
		if enum_img != null and enum_img.get_format() == Image.FORMAT_RGBA8:
			var enum_data := enum_img.get_data()
			var ew := enum_img.get_width()
			var eh := enum_img.get_height()
			var palette_n := _BOUNCE_ALBEDO.size()
			if ew > 0 and eh > 0 and enum_data.size() >= ew * eh * 4:
				for gy in range(gh):
					var sy := clampi(int((float(gy) + 0.5) / float(gh) * float(eh)), 0, eh - 1)
					var dst_row := gy * gw
					var src_row := sy * ew
					for gx in range(gw):
						var sx := clampi(int((float(gx) + 0.5) / float(gw) * float(ew)), 0, ew - 1)
						var tid := int(enum_data[(src_row + sx) * 4])
						var col: Color = _BOUNCE_ALBEDO[tid] if tid < palette_n else _BOUNCE_FALLBACK
						var is_water := tid in _BOUNCE_WATER_TERRAINS
						var dp := (dst_row + gx) * 4
						out_bytes[dp] = clampi(int(round(col.r * 255.0)), 0, 255)
						out_bytes[dp + 1] = clampi(int(round(col.g * 255.0)), 0, 255)
						out_bytes[dp + 2] = clampi(int(round(col.b * 255.0)), 0, 255)
						out_bytes[dp + 3] = 0 if is_water else 255
				filled = true

	# 路径 4：最小兜底（仅依据 height_buffer 与 sea_level 区分陆地/水体）
	if not filled:
		var hw := world.hm_size.x
		var hh := world.hm_size.y
		var has_h := hw > 0 and hh > 0 and world.height_buffer.size() >= hw * hh
		var fb_r := clampi(int(round(_BOUNCE_FALLBACK.r * 255.0)), 0, 255)
		var fb_g := clampi(int(round(_BOUNCE_FALLBACK.g * 255.0)), 0, 255)
		var fb_b := clampi(int(round(_BOUNCE_FALLBACK.b * 255.0)), 0, 255)
		var water_col: Color = _BOUNCE_ALBEDO[0]
		var wr := clampi(int(round(water_col.r * 255.0)), 0, 255)
		var wg := clampi(int(round(water_col.g * 255.0)), 0, 255)
		var wb := clampi(int(round(water_col.b * 255.0)), 0, 255)
		for gy in range(gh):
			var sy := clampi(int((float(gy) + 0.5) / float(gh) * float(hh)), 0, hh - 1) if has_h else 0
			var dst_row := gy * gw
			for gx in range(gw):
				var is_water := false
				if has_h:
					var sx := clampi(int((float(gx) + 0.5) / float(gw) * float(hw)), 0, hw - 1)
					is_water = world.height_buffer[sy * hw + sx] <= world.sea_level
				var dp := (dst_row + gx) * 4
				if is_water:
					out_bytes[dp] = wr
					out_bytes[dp + 1] = wg
					out_bytes[dp + 2] = wb
					out_bytes[dp + 3] = 0
				else:
					out_bytes[dp] = fb_r
					out_bytes[dp + 1] = fb_g
					out_bytes[dp + 2] = fb_b
					out_bytes[dp + 3] = 255

	if world.ptt_albedo_tex != null and world.ptt_albedo_bytes == out_bytes:
		return true
	var img := Image.create_from_data(gw, gh, false, Image.FORMAT_RGBA8, out_bytes)
	if world.ptt_albedo_tex != null and world.ptt_albedo_tex.get_width() == gw \
			and world.ptt_albedo_tex.get_height() == gh \
			and world.ptt_albedo_tex.get_format() == Image.FORMAT_RGBA8:
		if DisplayServer.get_name() == "headless":
			world.ptt_albedo_tex = ImageTexture.create_from_image(img)
		else:
			world.ptt_albedo_tex.update(img)
	else:
		world.ptt_albedo_tex = ImageTexture.create_from_image(img)
	if world.ptt_albedo_tex == null:
		return false
	world.ptt_albedo_bytes = out_bytes
	world.ptt_albedo_changed.emit()
	return true
