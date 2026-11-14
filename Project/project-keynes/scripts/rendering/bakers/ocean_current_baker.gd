extends RefCounted
class_name DCOceanCurrentBaker

const TerrainBakerScript = preload("res://scripts/rendering/bakers/terrain_baker.gd")
const TerrainGeometryScript = preload("res://scripts/rendering/bakers/terrain_geometry_utils.gd")
const DCAtlasEncoders = preload("res://scripts/rendering/bakers/atlas_encoders.gd")




## Stateless legacy ocean-current and upwelling pixel bake paths.


static func bake_ocean_currents(baker: MapBaker, map: MapData, hex_size: float, world: WorldData, cfg: MapConfig = null, season_phase: float = 2.0) -> PackedByteArray:
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
	var thermohaline_w: float = (cfg.THERMOHALINE_WEIGHT if cfg != null else baker._THERMOHALINE_DEFAULT)
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
				is_ocean = baker._is_water(int(biome_buf[idx]))
			elif hm_match:
				is_ocean = height[idx] < sea
			else:
				var wp := Vector2(wx_base, wy_base)
				var cube_f := TerrainGeometryScript.world_to_cube_f(wp, hex_size)
				var rounded := TerrainGeometryScript.cube_round(cube_f)
				var c: HexCell = map.get_cell_by_cube(rounded)
				is_ocean = c != null and baker._is_water(int(c.terrain))

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
			# 北半球 lat_signed < 0：rot = +baker.EKMAN_DEFLECTION_RAD
			# 南半球 lat_signed > 0：rot = -baker.EKMAN_DEFLECTION_RAD
			var lat_signed := (ny - 0.5) * 2.0
			var ekman_sign: float = -1.0 if lat_signed < 0.0 else 1.0
			# 在 +y 朝下的屏幕系里，绕原点旋转 +θ 是顺时针。北半球应顺时针偏，所以用 -ekman_sign × θ
			var rot_angle: float = -ekman_sign * baker.EKMAN_DEFLECTION_RAD
			var cur := wind.rotated(rot_angle)

			# 3) 噪声扰动
			cur.x += baker._detail_noise.get_noise_2d(wx_base * 0.6, wy_base * 0.6) * 0.30
			cur.y += baker._detail_noise.get_noise_2d(wx_base * 0.6 + 91.0, wy_base * 0.6 - 17.0) * 0.30

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

static func bake_ocean_upwelling(baker: MapBaker, map: MapData, hex_size: float, world: WorldData, cfg: MapConfig = null, season_phase: float = 2.0) -> PackedByteArray:
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
			ocean = baker._is_water(int(world.biome_buffer[i]))
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
		var is_highlat: bool = lat_signed_abs > baker._UPWELLING_HIGHLAT_ABS
		var is_cold_sink: bool = is_highlat and temp_rel < cold_sink_temp
		var t_cold: float = clampf((cold_sink_temp - temp_rel) / 0.3, 0.0, 1.0) if is_cold_sink else 0.0
		var cold_sink_byte: int = clampi(int(round(128.0 * (1.0 - t_cold))), 0, 128)
		# Ekman sign 也只与半球有关（行级常量）
		var ekman_sign: float = -1.0 if lat_signed < 0.0 else 1.0
		var rot_angle: float = -ekman_sign * baker.EKMAN_DEFLECTION_RAD
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
			if along < baker._UPWELLING_COAST_TANGENT_MIN:
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

static func rebake_ocean_currents(baker: MapBaker, map: MapData, world: WorldData, hex_size: float,
		cfg: MapConfig, season_phase: float) -> void:
	if map == null or world == null:
		return
	var total: int = world.derived_size.x * world.derived_size.y
	if total <= 0:
		return
	# [ocean-visual-skip 2026-06-16] flag 关 → 保留 per-cell 物理 solve（写 HexCell），
	# 跳过像素光栅 + 交错重建 + encode（纯视觉）。
	var _ocean_visual: bool = DCFeatureFlags.ocean_current_visual_active()
	if baker._use_physical_circulation(cfg):
		var saved_world_ext = baker._world_ext
		baker._world_ext = null
		baker._physical_solve_for_phase(map, world, hex_size, cfg, season_phase)
		baker._world_ext = saved_world_ext
		if _ocean_visual:
			if baker._pending_wind_buf.is_empty():
				baker._ensure_pending_wind_size(world)
				baker._rasterize_wind_slice_from_hex(world, baker._pending_wind_buf, 0, total)
			baker._ensure_pending_currents_size(world)
			baker._rasterize_ocean_current_slice_from_hex(world, baker._pending_currents_buf, 0, total)
			# 方案 B-1：物理路径下不再生成 ocean_upwelling_buffer
			# （唯一消费者是 F6 调试 shader 通过 _rasterize_upwelling_slice_from_hex 重建，
			#  per-cell SoA / 主视觉路径都不依赖此 buffer）。
			world.wind_field_buffer = baker._pending_wind_buf
			world.ocean_current_buffer = baker._pending_currents_buf
			world.ocean_upwelling_buffer = PackedByteArray()
		else:
			world.wind_field_buffer = PackedByteArray()
			world.ocean_current_buffer = PackedByteArray()
			world.ocean_upwelling_buffer = PackedByteArray()
	elif _ocean_visual:
		world.wind_field_buffer = baker._bake_wind_field(world.world_bounds, world.derived_size, season_phase)
		world.ocean_current_buffer = baker._bake_ocean_currents(map, hex_size, world, cfg, season_phase)
		# 旧 ny-only 路径保留 upwelling buffer 计算（其它 GD 调用方可能仍读它），
		# 但贴图编码方案 0 一并跳过。
		world.ocean_upwelling_buffer = baker._bake_ocean_upwelling(map, hex_size, world, cfg, season_phase)
	else:
		world.wind_field_buffer = PackedByteArray()
		world.ocean_current_buffer = PackedByteArray()
		world.ocean_upwelling_buffer = PackedByteArray()
	if _ocean_visual:
		baker._update_ocean_current_flow_texture(world)
	else:
		world.ocean_current_flow_tex = null
	world.vector_atlas_tex = null
	# 方案 0：upwelling_tex 不在 rebake 路径里烘焙；F6 调试模式再 lazy build。
	world.upwelling_tex = null
	baker._pending_currents_buf = PackedByteArray()
	baker._pending_upwelling_buf = PackedByteArray()
	baker._pending_upwelling_mask = PackedByteArray()
	baker._pending_upwelling_row_built = PackedByteArray()
	baker._pending_wind_buf = PackedByteArray()
	baker._pending_size = Vector2i.ZERO
	baker._pending_phys_solved_phase = NAN
	baker._pending_psi_state = null
	baker._phys_stage = baker._PHYS_STAGE_NONE
	baker._phys_psi_iters_done = 0

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


static func _ensure_pending_currents_size(baker: MapBaker, world: WorldData) -> void:
	var W := world.derived_size.x
	var H := world.derived_size.y
	var need_size: int = W * H * 2
	if baker._pending_size != world.derived_size or baker._pending_currents_buf.size() != need_size:
		baker._pending_currents_buf = PackedByteArray()
		baker._pending_currents_buf.resize(need_size)
		baker._pending_size = world.derived_size
		# L: 仅当 vector_atlas_data 的尺寸与新 derived_size 真正不一致时才失效；
		# _bake_initial_vector_buffers 末尾会把 _pending_size 复位为 ZERO（pending buf 已释放），
		# 但 _vector_atlas_data 仍是上一轮 _rebuild_..._from_buffers 填好的有效 (W,H) 缓存——
		# 此时若一并清掉，commit 就会走 fallback rebuild（620k 循环 ~138-180ms）。
		# 之前的实现犯了这个错，导致每个跨季都触发 cache miss。
		if baker._vector_atlas_data_size != world.derived_size:
			baker._vector_atlas_data = PackedByteArray()
			baker._vector_atlas_data_size = Vector2i.ZERO


static func _ensure_pending_upwelling_size(baker: MapBaker, world: WorldData) -> void:
	var W := world.derived_size.x
	var H := world.derived_size.y
	var need_size: int = W * H
	if baker._pending_upwelling_buf.size() != need_size:
		baker._pending_upwelling_buf = PackedByteArray()
		baker._pending_upwelling_buf.resize(need_size)
		baker._pending_upwelling_mask = PackedByteArray()
		baker._pending_upwelling_mask.resize(need_size)
		baker._pending_upwelling_row_built = PackedByteArray()
		baker._pending_upwelling_row_built.resize(H)


static func _ensure_upwelling_rows_mask(baker: MapBaker, world: WorldData, y_start: int, y_end_inclusive: int) -> void:
	# 按行 lazy build mask：仅扫指定行 [y_start, y_end_inclusive] 中尚未构建的部分。
	# 对每一行 yy：若 _pending_upwelling_row_built[yy]==0，则扫该行 W 个像素
	# 写入 _pending_upwelling_mask 与 _pending_upwelling_buf（默认 128），并打标。
	# 同行二次访问立即返回。
	var W := world.derived_size.x
	var H := world.derived_size.y
	if baker._pending_upwelling_row_built.size() != H:
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
		if baker._pending_upwelling_row_built[yy] != 0:
			continue
		var row_base: int = yy * W
		for x in range(W):
			var i: int = row_base + x
			var ocean := false
			if has_biome:
				ocean = baker._is_water(int(biome_buf[i]))
			elif hm_match:
				ocean = height[i] < sea
			baker._pending_upwelling_mask[i] = 1 if ocean else 0
			baker._pending_upwelling_buf[i] = 128  # 默认中性
		baker._pending_upwelling_row_built[yy] = 1

## 烘焙 ocean currents 在像素区间 [start_idx, end_idx) 上的部分。
## 第一次切片调用时 start_idx 应为 0，phase 在第一次切片时锁定（后续切片不再随
## season_phase 漂移）。返回 { pixels_done, total_pixels }。

static func bake_ocean_currents_slice(baker: MapBaker, map: MapData, world: WorldData, hex_size: float,
		cfg: MapConfig, season_phase: float,
		start_idx: int, end_idx: int) -> Dictionary:
	if world == null:
		return { "pixels_done": 0, "total_pixels": 0 }
	baker._ensure_pending_currents_size(world)
	if start_idx == 0:
		baker._pending_phase = season_phase
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
	if baker._use_physical_circulation(cfg):
		baker._rasterize_ocean_current_slice_from_hex(world, baker._pending_currents_buf, s, e)
		return { "pixels_done": e - s, "total_pixels": total }

	var origin := world.world_bounds.position
	var size := world.world_bounds.size
	var sea := world.sea_level
	var height := world.height_buffer
	var hm_W := world.hm_size.x
	var hm_H := world.hm_size.y
	var wind_buf := world.wind_field_buffer
	var has_wind: bool = not wind_buf.is_empty() and wind_buf.size() >= W * H * 2
	var thermohaline_w: float = (cfg.THERMOHALINE_WEIGHT if cfg != null else baker._THERMOHALINE_DEFAULT)
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
			is_ocean = baker._is_water(int(biome_buf[idx]))
		elif hm_match:
			is_ocean = height[idx] < sea
		else:
			var wp := Vector2(wx_base, wy_base)
			var cube_f := TerrainGeometryScript.world_to_cube_f(wp, hex_size)
			var rounded := TerrainGeometryScript.cube_round(cube_f)
			var c: HexCell = map.get_cell_by_cube(rounded)
			is_ocean = c != null and baker._is_water(int(c.terrain))

		if not is_ocean:
			baker._pending_currents_buf[idx * 2] = 128
			baker._pending_currents_buf[idx * 2 + 1] = 128
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
		var rot_angle: float = -ekman_sign * baker.EKMAN_DEFLECTION_RAD
		var cur := wind.rotated(rot_angle)

		cur.x += baker._detail_noise.get_noise_2d(wx_base * 0.6, wy_base * 0.6) * 0.30
		cur.y += baker._detail_noise.get_noise_2d(wx_base * 0.6 + 91.0, wy_base * 0.6 - 17.0) * 0.30

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
		baker._pending_currents_buf[idx * 2]     = clampi(int(round((cur.x * 0.5 + 0.5) * 255.0)), 0, 255)
		baker._pending_currents_buf[idx * 2 + 1] = clampi(int(round((cur.y * 0.5 + 0.5) * 255.0)), 0, 255)

	return { "pixels_done": e - s, "total_pixels": total }

## 烘焙 ocean upwelling 在像素区间 [start_idx, end_idx) 上的部分。
## 与 currents 不同：upwelling 主逻辑使用 8 邻域查询，必须先在切片覆盖范围 + 1 行
## padding 上建好 ocean mask + 默认值 128。mask 按行 lazy build，避免首片一次性
## 扫整图（~140ms 摊到所有切片）。已构建过的行直接复用。

static func bake_ocean_upwelling_slice(baker: MapBaker, map: MapData, world: WorldData, hex_size: float,
		cfg: MapConfig, season_phase: float,
		start_idx: int, end_idx: int) -> Dictionary:
	if world == null:
		return { "pixels_done": 0, "total_pixels": 0 }
	# 方案 B-1：物理路径下 upwelling buffer 没有消费者，整个切片改成 noop
	# （per-cell SoA / 主视觉路径不读；F6 调试由 lazy bake 单独触发一次）。
	# 旧 ny-only 路径仍保留 lazy-mask 光栅化，向后兼容。
	if baker._use_physical_circulation(cfg):
		var W_phys := world.derived_size.x
		var H_phys := world.derived_size.y
		return { "pixels_done": end_idx - start_idx, "total_pixels": W_phys * H_phys }
	baker._ensure_pending_upwelling_size(world)
	if start_idx == 0:
		baker._pending_phase = season_phase
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
	if baker._use_physical_circulation(cfg):
		baker._rasterize_upwelling_slice_from_hex(world, baker._pending_upwelling_buf, s, e)
		return { "pixels_done": e - s, "total_pixels": total }

	# 8 邻域查询会读 y±1 行的 mask；这里多 padding 1 行确保查询命中。
	var y_first: int = s / W
	var y_last: int = (e - 1) / W
	baker._ensure_upwelling_rows_mask(world, y_first - 1, y_last + 1)

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
		var is_highlat: bool = lat_signed_abs > baker._UPWELLING_HIGHLAT_ABS
		var is_cold_sink: bool = is_highlat and temp_rel < cold_sink_temp
		var t_cold: float = clampf((cold_sink_temp - temp_rel) / 0.3, 0.0, 1.0) if is_cold_sink else 0.0
		var cold_sink_byte: int = clampi(int(round(128.0 * (1.0 - t_cold))), 0, 128)
		var ekman_sign: float = -1.0 if lat_signed < 0.0 else 1.0
		var rot_angle: float = -ekman_sign * baker.EKMAN_DEFLECTION_RAD
		row_data[yy - y_start] = {
			"is_cold_sink": is_cold_sink,
			"cold_sink_byte": cold_sink_byte,
			"rot_angle": rot_angle,
		}

	for idx in range(s, e):
		var y: int = idx / W
		var x: int = idx - y * W
		# 陆地直接跳过（mask 中 0 表示陆地，buf 已被预填为 128）
		if baker._pending_upwelling_mask[idx] == 0:
			baker._pending_upwelling_buf[idx] = 128
			continue
		var rd: Dictionary = row_data[y - y_start]

		# (a) 高纬冷水下沉
		if bool(rd["is_cold_sink"]):
			baker._pending_upwelling_buf[idx] = int(rd["cold_sink_byte"])
			continue

		# 默认中性
		baker._pending_upwelling_buf[idx] = 128

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
				if baker._pending_upwelling_mask[ni] == 0:
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
		if along < baker._UPWELLING_COAST_TANGENT_MIN:
			continue
		var cur_dir := wind.rotated(rd["rot_angle"] as float)
		var offshore: float = cur_dir.dot(-nvec)
		if offshore <= 0.0:
			continue
		var up: float = clampf(along * offshore, 0.0, 1.0)
		baker._pending_upwelling_buf[idx] = clampi(int(round(128.0 + 127.0 * up)), 128, 255)

	return { "pixels_done": e - s, "total_pixels": total }

## 切片全部完成后调用：把 _pending_currents_buf / _pending_upwelling_buf
## 原子替换到 world。update_textures 为 true 时同步重编码 vector_atlas_tex /
## upwelling_tex；SUS fast tick 可传 false 避免 GPU 上传毛刺。返回耗时。
##
## upwelling_tex 编码默认 SKIP（方案 0：唯一消费者是 F6 调试 shader 分支，
## 主路径不读）。F6 切到 debug 模式时 main.gd / hex_renderer 会显式调
## `rebake_upwelling_tex_for_debug` lazy bake 一次。

static func commit_ocean_buffers(baker: MapBaker, world: WorldData, update_textures: bool = true) -> Dictionary:
	if world == null:
		return {}
	var t := Time.get_ticks_msec()
	world.ocean_current_buffer = baker._pending_currents_buf
	# 方案 B-1：物理路径下 ocean_upwelling_buffer 不再被消费（per-cell SoA 不依赖它，
	# F6 调试也是直接从 cell.upwelling_strength 重新光栅化），保留赋值仅为旧 ny-only
	# 路径兼容。物理路径下 _pending_upwelling_buf 在 _bake_ocean_upwelling_slice 里
	# 已不再写入，自然是空 PackedByteArray。
	world.ocean_upwelling_buffer = baker._pending_upwelling_buf
	# Physical Wind & Ocean Circulation：物理化路径在 _physical_solve_for_phase 时已
	# 把 hex → pixel 风场 buffer 写入 _pending_wind_buf，commit 时一并替换 world.wind_field_buffer
	# 让 weather_system advection / shader 都看到新风迹。旧路径 _pending_wind_buf
	# 为空，跳过。
	if not baker._pending_wind_buf.is_empty():
		world.wind_field_buffer = baker._pending_wind_buf
	# 洋流 Flowmap 与 pixel buffer 同步提交；RG8 直接复用现有 RG buffer。
	# 正常路径下 ocean_currents_job 已用 _phys_need_visual=false 提前 round_done、根本
	# 走不到 commit；此处的额外条件是防御性兜底（避免任何其它调用方在 flag 关时重建纹理）。
	if update_textures and DCFeatureFlags.ocean_current_visual_active():
		baker._update_ocean_current_flow_texture(world)
		# 方案 0：upwelling_tex 默认不在 commit 路径里上传。
		# F6 切到 ocean_current_debug 后会显式调 rebake_upwelling_tex_for_debug。
		# 这里不再调 _encode_upwelling_tex（省 ~10-15ms GPU 上传 + 编码）。
	var t_commit := Time.get_ticks_msec() - t
	# 清空 pending（下一轮重新分配，避免残留半旧数据）
	baker._pending_currents_buf = PackedByteArray()
	baker._pending_upwelling_buf = PackedByteArray()
	baker._pending_upwelling_mask = PackedByteArray()
	baker._pending_upwelling_row_built = PackedByteArray()
	baker._pending_size = Vector2i.ZERO
	baker._pending_phys_solved_phase = NAN
	baker._pending_psi_state = null
	baker._pending_wind_buf = PackedByteArray()
	# Phys Solve Sliced：commit 收尾 → 求解状态机一并复位，下一轮从 SLP 起步。
	baker._phys_stage = baker._PHYS_STAGE_NONE
	baker._phys_psi_iters_done = 0
	return { "commit_ms": t_commit }

## 方案 0：F6 切到 ocean_current_debug=true 时调用一次，按需 lazy build upwelling_tex。
## 直接从 per-cell HexCell.upwelling_strength 光栅化（_rasterize_upwelling_slice_from_hex
## 内部读 cell 即可，物理路径下 ocean_upwelling_buffer 已废弃但 hex 字段一直在更新）。
## 返回是否成功；shader 端在 ocean_upwelling_tex 仍为 null 时不会渲染（uniform 默认黑纹理，
## 且 ocean_current_debug=false 分支已是 default 主路径）。

static func rebake_upwelling_tex_for_debug(baker: MapBaker, world: WorldData) -> bool:
	if world == null:
		return false
	var W: int = world.derived_size.x
	var H: int = world.derived_size.y
	var n: int = W * H
	if n <= 0:
		return false
	if baker._world_ext != null and baker._last_bake_map != null:
		baker._ensure_ocean_pixel_to_cell_index(baker._last_bake_map, world)
		baker._world_ext.refresh_slots_from_map()
		var ret: Dictionary = baker._world_ext.encode_bake_upwelling_tex_data({
			"n_cells": baker._last_bake_map.cell_count(),
			"width": W,
			"height": H,
			"pixel_to_cell_idx": baker._ocean_pixel_to_cell_idx,
		})
		if not bool(ret.get("fallback", true)):
			world.upwelling_tex = DCAtlasEncoders.upload_single_channel(
				ret.get("data", PackedByteArray()), W, H, world.upwelling_tex)
			return true

	# Debug fallback: gdext missing/unbound only.
	var debug_buf: PackedByteArray = PackedByteArray()
	debug_buf.resize(n)
	for i in range(n):
		debug_buf[i] = 128
	baker._rasterize_upwelling_slice_from_hex(world, debug_buf, 0, n)
	world.upwelling_tex = DCAtlasEncoders.upload_single_channel(
		debug_buf, W, H, world.upwelling_tex)
	return true

## 丢弃所有 pending 缓冲（地图重生成 / SUS reset_all_progress 调用）。

static func discard_ocean_buffers(baker: MapBaker) -> void:
	baker._pending_currents_buf = PackedByteArray()
	baker._pending_upwelling_buf = PackedByteArray()
	baker._pending_upwelling_mask = PackedByteArray()
	baker._pending_upwelling_row_built = PackedByteArray()
	baker._pending_size = Vector2i.ZERO
	baker._pending_phys_solved_phase = NAN
	baker._pending_psi_state = null
	baker._pending_wind_buf = PackedByteArray()
	# L: vector atlas 缓存随 reset 失效；下一次 commit 会重新整张拼出来。
	baker._vector_atlas_data = PackedByteArray()
	baker._vector_atlas_data_size = Vector2i.ZERO
	# Phys Solve Sliced：丢弃时也复位状态机，避免下一轮在错误阶段恢复。
	baker._phys_stage = baker._PHYS_STAGE_NONE
	baker._phys_psi_iters_done = 0

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

static func _rebake_single_axis(baker: MapBaker, map: MapData, world: WorldData, hex_size: float, axis: String) -> void:
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
	if baker._try_cpp_enum_axis_patch(map, world, axis, report_t0_us):
		return

	# Fast path：lookup + cell_pixel_lists 都齐全 → 走增量路径
	var has_lookup: bool = world.pixel_to_cell_lookup.size() == pix_count
	var has_cell_lists: bool = not world.cell_pixel_lists.is_empty()
	if has_lookup and has_cell_lists:
		var cache_dict: Dictionary
		var cache_size_ref: Vector2i
		if axis == "cover":
			cache_dict = baker._last_cover_cell_bytes
			cache_size_ref = baker._cover_cache_size
		else:
			cache_dict = baker._last_vegetation_cell_bytes
			cache_size_ref = baker._vegetation_cache_size

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
				baker._last_cover_cell_bytes = cache_dict
				baker._cover_cache_size = Vector2i(W, H)
				world.cover_buffer = target_buf
			else:
				for i in range(pix_count):
					var c1: HexCell = lookup_init[i]
					target_buf[i] = (int(c1.vegetation) if c1 != null else fallback_default) & 0xFF
				for cell_key in world.cell_pixel_lists.keys():
					var cv: HexCell = cell_key
					cache_dict[cv] = int(cv.vegetation) & 0xFF
				baker._last_vegetation_cell_bytes = cache_dict
				baker._vegetation_cache_size = Vector2i(W, H)
				world.vegetation_buffer = target_buf
			var patch_ms: float = float(Time.get_ticks_usec() - patch_t0_us) / 1000.0
			# vegetation/cover 已由 enum_lut 消费；map-index atlas 不需要上传。
			baker._record_enum_atlas_upload_report(axis, "lut_only_no_map_index_upload",
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
			baker._last_cover_cell_bytes = cache_dict
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
			baker._last_vegetation_cell_bytes = cache_dict
			world.vegetation_buffer = target_buf
		var buffer_patch_ms: float = float(Time.get_ticks_usec() - patch_t0_us) / 1000.0

		if not any_dirty:
			baker._record_enum_atlas_upload_report(axis, "skipped_no_dirty",
				float(Time.get_ticks_usec() - report_t0_us) / 1000.0,
				0, 0, buffer_patch_ms, 0.0, 0.0, true)
			return  # 所有 cell byte 都没变 → 连 GPU 上传都跳过
		baker._record_enum_atlas_upload_report(axis, "lut_only_no_map_index_upload",
			float(Time.get_ticks_usec() - report_t0_us) / 1000.0,
			dirty_cells, dirty_pixels, buffer_patch_ms, 0.0, 0.0, true)
		return

	# Slow fallback：完整重跑 warp + cube_round（保留兼容性，正常不会走到）
	if baker._warp_noise_lo == null:
		baker._init_noise(world.bake_seed)
	var origin := world.world_bounds.position
	var size := world.world_bounds.size
	var step_x := size.x / float(W)
	var step_y := size.y / float(H)
	var warp_scale := hex_size * baker.WARP_AMP
	var wrap_period_x := HexUtils.wrap_period_x(map.width, hex_size)

	var patch_t0_us: int = Time.get_ticks_usec()
	for y in range(H):
		var wy_base := origin.y + (float(y) + 0.5) * step_y
		var row := y * W
		for x in range(W):
			var wx_base := origin.x + (float(x) + 0.5) * step_x
			var warp_x := TerrainGeometryScript.cyl_noise(baker._warp_noise_lo, wx_base, wy_base, wrap_period_x, hex_size)
			var warp_y := TerrainGeometryScript.cyl_noise(baker._warp_noise_lo, wx_base + 31.7, wy_base - 17.3, wrap_period_x, hex_size, 1.0, 31.7)
			var hi_x := TerrainGeometryScript.cyl_noise(baker._warp_noise_hi, wx_base + 91.1, wy_base + 53.7, wrap_period_x, hex_size, 1.0, 91.1) * baker.WARP_HIGH_AMP_RATIO
			var hi_y := TerrainGeometryScript.cyl_noise(baker._warp_noise_hi, wx_base - 41.5, wy_base + 23.9, wrap_period_x, hex_size, 1.0, -41.5) * baker.WARP_HIGH_AMP_RATIO
			var wx := wx_base + (warp_x + hi_x) * warp_scale
			var wy := wy_base + (warp_y + hi_y) * warp_scale
			var cube_f := TerrainGeometryScript.world_to_cube_f(Vector2(wx, wy), hex_size)
			var rounded := TerrainGeometryScript.cube_round(cube_f)
			var self_cell: HexCell = TerrainGeometryScript.get_wrapped_cell_by_cube(map, rounded)
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
	baker.prewarm_dynamic_axis_caches(map, world)
	baker._record_enum_atlas_upload_report(axis, "lut_only_no_map_index_upload",
		float(Time.get_ticks_usec() - report_t0_us) / 1000.0,
		world.cell_pixel_lists.size(), 0, buffer_patch_ms, 0.0, 0.0, false)

# Milestone 2 / J 增量：季节切换时同步重烘 biome / vegetation / cover 三张 R8 纹理。
# height / moisture / flow / latitude / wind / ocean 全部不动。
#
# 旧路径（130ms / season）：完整 _rewrite_axis_buffers（620k 像素 × 3 byte）+
# _encode_enum_atlas（620k 像素 × 3 byte 交错 + Image.create + tex.update）。
#
# J 新路径：与 _rebake_single_axis 同结构，把 biome / veg / cover 3 轴的 sig 缓存
# 一起遍历。多数季节切换只翻少数边界 cell 的 terrain，veg / cover 在前序 stage 已
# 部分更新，sig 不变直接跳过；变了才把 cell.pixel 列表批量写到 buf + 直写
# `_enum_atlas_data` 对应通道。最后用 cached interleaved data 做 tex.update()。

static func rebake_biome_axes_only(baker: MapBaker, map: MapData, world: WorldData, hex_size: float) -> void:
	var report_t0_us: int = Time.get_ticks_usec()
	if world == null or world.biome_buffer.is_empty():
		return
	if baker._warp_noise_lo == null:
		baker._init_noise(world.bake_seed)
	elif baker._detail_noise == null or baker._ridge_noise == null:
		baker._init_noise(world.bake_seed)
	var W := world.derived_size.x
	var H := world.derived_size.y
	var pix_count := W * H
	if baker._try_cpp_enum_axes_patch(map, world, report_t0_us):
		world.terrain_detail_tex = TerrainBakerScript.rebake_terrain_detail_texture(
			world, hex_size, baker._detail_noise, baker._ridge_noise, baker._world_ext,
			baker.TERRAIN_DETAIL_BAKE_MIN, baker.TERRAIN_DETAIL_BAKE_MAX)
		return
	var has_lookup: bool = world.pixel_to_cell_lookup.size() == pix_count
	var has_cell_lists: bool = not world.cell_pixel_lists.is_empty()

	# Cache validity：3 轴 sig + interleaved data 都得齐才走增量。
	var cache_valid: bool = (has_lookup \
			and has_cell_lists \
			and baker._biome_cache_size == Vector2i(W, H) \
			and baker._vegetation_cache_size == Vector2i(W, H) \
			and baker._cover_cache_size == Vector2i(W, H) \
			and baker._enum_atlas_data_size == Vector2i(W, H) \
			and baker._enum_atlas_data.size() == pix_count * 4 \
			and not baker._last_biome_cell_bytes.is_empty() \
			and not baker._last_vegetation_cell_bytes.is_empty() \
			and not baker._last_cover_cell_bytes.is_empty() \
			and world.biome_buffer.size() == pix_count \
			and world.vegetation_buffer.size() == pix_count \
			and world.cover_buffer.size() == pix_count)

	if not cache_valid:
		# Fallback：完整路径（首次 / 任意缓存失效）。同步顺便把 3 轴 sig + interleaved data 都建好。
		var patch_t0_us: int = Time.get_ticks_usec()
		baker._rewrite_axis_buffers(map, hex_size, world)
		var buffer_patch_ms: float = float(Time.get_ticks_usec() - patch_t0_us) / 1000.0
		var upload_t0_us: int = Time.get_ticks_usec()
		world.enum_atlas_tex = baker._encode_enum_atlas(
			world.biome_buffer, world.vegetation_buffer, world.cover_buffer,
			world.derived_size, world.enum_atlas_tex, world, map
		)
		var upload_ms: float = float(Time.get_ticks_usec() - upload_t0_us) / 1000.0
		baker.prewarm_dynamic_axis_caches(map, world)
		world.terrain_detail_tex = TerrainBakerScript.rebake_terrain_detail_texture(
			world, hex_size, baker._detail_noise, baker._ridge_noise, baker._world_ext,
			baker.TERRAIN_DETAIL_BAKE_MIN, baker.TERRAIN_DETAIL_BAKE_MAX)
		baker._record_enum_atlas_upload_report("biome", "fallback_full_rewrite",
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
		var prev_t: int = int(baker._last_biome_cell_bytes.get(cell, -1))
		var prev_v: int = int(baker._last_vegetation_cell_bytes.get(cell, -1))
		var prev_c: int = int(baker._last_cover_cell_bytes.get(cell, -1))
		if b_t == prev_t and b_v == prev_v and b_c == prev_c:
			continue
		var pixels: PackedInt32Array = cell_lists[cell_key]
		if b_t != prev_t:
			baker._last_biome_cell_bytes[cell] = b_t
			biome_dirty += 1
			dirty_pixels += pixels.size()
			for px in pixels:
				biome_buf[px] = b_t
				baker._enum_atlas_data[px * 4] = b_t
		if b_v != prev_v:
			baker._last_vegetation_cell_bytes[cell] = b_v
			veg_dirty += 1
			dirty_pixels += pixels.size()
			for px in pixels:
				veg_buf[px] = b_v
		if b_c != prev_c:
			baker._last_cover_cell_bytes[cell] = b_c
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
		baker._record_enum_atlas_upload_report("biome", "skipped_no_dirty",
			float(Time.get_ticks_usec() - report_t0_us) / 1000.0,
			0, 0, buffer_patch_ms, 0.0, 0.0, true)
		return  # 全 3 轴 byte 都没变 → 连 GPU 上传都跳过
	if biome_dirty == 0:
		baker._record_enum_atlas_upload_report("biome", "lut_only_no_map_index_upload",
			float(Time.get_ticks_usec() - report_t0_us) / 1000.0,
			dirty_cells, dirty_pixels, buffer_patch_ms, 0.0, 0.0, true)
		return

	# tex.update via cached map-index data；只在 biome/R 通道变化时上传。
	if world.enum_atlas_tex != null and world.enum_atlas_tex.get_size() == Vector2(float(W), float(H)):
		var image_t0_us: int = Time.get_ticks_usec()
		var img := Image.create_from_data(W, H, false, Image.FORMAT_RGBA8, baker._enum_atlas_data)
		var image_ms: float = float(Time.get_ticks_usec() - image_t0_us) / 1000.0
		var upload_t0_us: int = Time.get_ticks_usec()
		world.enum_atlas_tex.update(img)
		var upload_ms: float = float(Time.get_ticks_usec() - upload_t0_us) / 1000.0
		baker._record_enum_atlas_upload_report("biome", "cached_full_update",
			float(Time.get_ticks_usec() - report_t0_us) / 1000.0,
			dirty_cells, dirty_pixels, buffer_patch_ms, image_ms, upload_ms, true)
	else:
		var upload_t0_us: int = Time.get_ticks_usec()
		world.enum_atlas_tex = baker._encode_enum_atlas(
			world.biome_buffer, world.vegetation_buffer, world.cover_buffer,
			world.derived_size, world.enum_atlas_tex, world, map
		)
		var upload_ms: float = float(Time.get_ticks_usec() - upload_t0_us) / 1000.0
		baker._record_enum_atlas_upload_report("biome", "fallback_full_rewrite",
			float(Time.get_ticks_usec() - report_t0_us) / 1000.0,
			dirty_cells, dirty_pixels, buffer_patch_ms, 0.0, upload_ms, false)
		world.terrain_detail_tex = TerrainBakerScript.rebake_terrain_detail_texture(
			world, hex_size, baker._detail_noise, baker._ridge_noise, baker._world_ext,
			baker.TERRAIN_DETAIL_BAKE_MIN, baker.TERRAIN_DETAIL_BAKE_MAX)

# 重写 biome / vegetation / cover 三个 buffer，但保持 height/moisture/flow 不动

static func _rewrite_axis_buffers(baker: MapBaker, map: MapData, hex_size: float, world: WorldData) -> void:
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
	var warp_scale := hex_size * baker.WARP_AMP
	var wrap_period_x := HexUtils.wrap_period_x(map.width, hex_size)

	for y in range(H):
		var wy_base := origin.y + (float(y) + 0.5) * step_y
		var row := y * W
		for x in range(W):
			var wx_base := origin.x + (float(x) + 0.5) * step_x
			var warp_x := TerrainGeometryScript.cyl_noise(baker._warp_noise_lo, wx_base, wy_base, wrap_period_x, hex_size)
			var warp_y := TerrainGeometryScript.cyl_noise(baker._warp_noise_lo, wx_base + 31.7, wy_base - 17.3, wrap_period_x, hex_size, 1.0, 31.7)
			var hi_x := TerrainGeometryScript.cyl_noise(baker._warp_noise_hi, wx_base + 91.1, wy_base + 53.7, wrap_period_x, hex_size, 1.0, 91.1) * baker.WARP_HIGH_AMP_RATIO
			var hi_y := TerrainGeometryScript.cyl_noise(baker._warp_noise_hi, wx_base - 41.5, wy_base + 23.9, wrap_period_x, hex_size, 1.0, -41.5) * baker.WARP_HIGH_AMP_RATIO
			var wx := wx_base + (warp_x + hi_x) * warp_scale
			var wy := wy_base + (warp_y + hi_y) * warp_scale
			var cube_f := TerrainGeometryScript.world_to_cube_f(Vector2(wx, wy), hex_size)
			var rounded := TerrainGeometryScript.cube_round(cube_f)
			var self_cell: HexCell = TerrainGeometryScript.get_wrapped_cell_by_cube(map, rounded)
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
