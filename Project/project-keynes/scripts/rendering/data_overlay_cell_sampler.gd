extends RefCounted

## Samples published map cells for an overlay without allocating one object per cell.

const PRECIPITATION_NORM_MAX: float = 1.0
const OCEAN_CURRENT_NORM_MAX: float = 0.35
const HEAT_TRANSPORT_NORM_RANGE: float = 0.08
const UPWELLING_NORM_RANGE: float = 1.0
const WIND_SPEED_NORM_MAX: float = 1.7
const SLP_OVERLAY_NORM_RANGE: float = 0.35


# 逐 cell 按 mode 做采样，结果写入下面这组静态槽而不是每格新建 Dictionary。
# 采样被调用 n_cells 次（约 2400）× 每秒最多 10 次重烘焙，逐格分配 Dictionary
# 等于每秒两万多次分配；槽化后语义不变、零分配。调用方读槽前必须先调本函数。
# _s_value     —— 连续通道使用；离散通道忽略
# _s_bucket    —— 离散通道使用（CLIMATE_ZONE 档位 / WeatherType.WT id）
# _s_intensity —— 仅 WEATHER 通道用于控制 alpha
# _s_hue / _s_dir_intensity —— 仅 vector 通道（风向 / 洋流方向）使用
static var _s_value: float = 0.0
static var _s_bucket: int = 0
static var _s_intensity: float = 0.0
static var _s_hue: float = 0.0
static var _s_dir_intensity: float = 0.0
static var _s_valid: bool = false
static var _s_vector_mode: bool = false


static func _sample_reset() -> void:
	_s_value = 0.0
	_s_bucket = 0
	_s_intensity = 0.0
	_s_hue = 0.0
	_s_dir_intensity = 0.0
	_s_valid = false
	_s_vector_mode = false


static func _sample_cell(
	cell,
	adapter: DCViewAdapter,
	mode: int,
	climate,
	season_phase: float,
	world,
	map,
	lat_buf: PackedFloat32Array,
	lat_buf_size: int
) -> void:
	_sample_reset()
	# B.1：所有 schema-mirrored 字段从 adapter 读，cell.* 仅留 non-schema
	# 字段（passable_sea / vegetation_vitality / temperature_transport_anomaly /
	# upwelling_strength / slp / wind_speed / wind_stress_curl / ocean_psi）。
	var idx: int = int(cell.index)
	match mode:
		OverlayMode.MODE.TEMPERATURE:
			_s_value = clampf(adapter.get_temp(idx), 0.0, 1.0)
			_s_valid = true
		OverlayMode.MODE.PRECIPITATION:
			var precip: float = adapter.get_weather_precip(idx)
			_s_value = clampf(precip / PRECIPITATION_NORM_MAX, 0.0, 1.0)
			_s_valid = true
		OverlayMode.MODE.CLIMATE_ZONE:
			# 与 main.gd._climate_zone_name 一致：用 world.latitude_buffer 取真实 ny。
			# 直接取该 cell 覆盖的第一个像素 idx，查 latitude_buffer[idx]。
			# 这是 map_baker 渲染所用的同一份 ny，保证 overlay / 文字标签 / shader
			# 三方完全一致；buffer 缺失时回退到 _latitude_hint 的近似（仅极旧地图）。
			var ny_like: float = _cell_latitude(cell, world, lat_buf, lat_buf_size)
			var lat_dev: float = absf(ny_like - 0.5) * 2.0  # 0(赤道)..1(极)
			_s_bucket = clampi(int(lat_dev * 5.0), 0, 4)
			_s_valid = true
		OverlayMode.MODE.HUMIDITY:
			_s_value = clampf(adapter.get_moisture(idx), 0.0, 1.0)
			_s_valid = true
		OverlayMode.MODE.WEATHER:
			var has_weather: bool = adapter.get_weather_field_init(idx)
			var w: int = adapter.get_weather_type(idx) if has_weather else WeatherType.WT.CLEAR
			var intensity: float = adapter.get_weather_intensity(idx) if has_weather else 0.0
			_s_bucket = w
			_s_intensity = clampf(intensity, 0.0, 1.0)
			_s_valid = true
		OverlayMode.MODE.VEGETATION_VITALITY:
			# 水域 cell 不参与植被健康度采样：用 HexCell.passable_sea 作为"水"
			# 的 proxy（TerrainProfileRegistry 已把 OCEAN/SEA_ICE/COAST/LAKE/REEF
			# 等水面地形标记 passable_sea=true）。陆上植被（即使 passable_land=false
			# 的高山 SNOW）仍参与采样，只是 vitality 默认 0.7，无特殊处理。
			if bool(cell.passable_sea):
				return
			_s_value = clampf(float(cell.vegetation_vitality), 0.0, 1.0)
			_s_valid = true
		OverlayMode.MODE.OCEAN_CURRENT:
			# 仅水域有效：陆地 ocean_current 维持 0，画出来无意义且会被中性灰污染。
			# 用 passable_sea 当水的 proxy（与 VEGETATION_VITALITY 同口径）。
			if not bool(cell.passable_sea):
				return
			var mag: float = adapter.get_ocean_current(idx).length()
			_s_value = clampf(mag / OCEAN_CURRENT_NORM_MAX, 0.0, 1.0)
			_s_valid = true
		OverlayMode.MODE.OCEAN_HEAT_TRANSPORT:
			# 仅水域有意义：洋流给该格相对静水状态的温度增减。
			# 双向归一化到 [0, 1]：0 = 强冷输入、0.5 = 中性、1 = 强暖输入。
			if not bool(cell.passable_sea):
				return
			var raw_t: float = float(cell.temperature_transport_anomaly)
			_s_value = 0.5 + clampf(raw_t / (HEAT_TRANSPORT_NORM_RANGE * 2.0), -0.5, 0.5)
			_s_valid = true
		OverlayMode.MODE.UPWELLING:
			# 仅水域有意义：upwelling_strength ∈ [-1, 1]，正=上升流（营养上涌）。
			# 同样双向归一化到 [0, 1]：0 = 强下沉、0.5 = 中性、1 = 强上升。
			if not bool(cell.passable_sea):
				return
			var raw_u: float = adapter.get_upwelling_strength(idx)
			_s_value = 0.5 + clampf(raw_u / (UPWELLING_NORM_RANGE * 2.0), -0.5, 0.5)
			_s_valid = true
		OverlayMode.MODE.WIND_SPEED:
			# 注意：wind_at() 总是 normalize（服务于风向场 advection），不能反推
			# 风速。这里读物理循环写入的 wind_speed SoA / facade 真值。
			# 值域 ≈ [0.15, 1.7]，由 WIND_SPEED_NORM_MAX 钳到 [0, 1]。
			# 全图都有效，包括海洋和高山。
			var w_speed: float = adapter.get_wind_speed(idx)
			_s_value = clampf(w_speed / WIND_SPEED_NORM_MAX, 0.0, 1.0)
			_s_valid = true
		OverlayMode.MODE.BIOME_GROUP:
			# 把 cell.terrain（27 种）映射到 OverlayMode.TERRAIN_TO_BIOME_GROUP 的
			# 10 个生态大类，避免离散调色板膨胀到难以辨认。
			var t_b: int = adapter.get_terrain(idx)
			var bgroup: int = 9  # 默认 fallback：未分类
			if t_b >= 0 and t_b < OverlayMode.TERRAIN_TO_BIOME_GROUP.size():
				bgroup = int(OverlayMode.TERRAIN_TO_BIOME_GROUP[t_b])
			_s_bucket = bgroup
			_s_valid = true
		OverlayMode.MODE.LANDFORM:
			_s_bucket = adapter.get_landform(idx)
			_s_valid = true
		OverlayMode.MODE.ELEVATION:
			_s_value = clampf(adapter.get_elevation(idx), 0.0, 1.0)
			_s_valid = true
		OverlayMode.MODE.VEGETATION_TYPE:
			_s_bucket = adapter.get_vegetation(idx)
			_s_valid = true
		OverlayMode.MODE.WIND_DIR:
			# 方向型通道：hue = atan2(dy, dx) / (2π) + 0.5（[0,1]），value = mag/NORM_MAX
			# 使用 cell.wind_vector 给方向，cell.wind_speed 给强度。
			var wv: Vector2 = adapter.get_wind_vector(idx)
			var mag_w: float = wv.length()
			if mag_w < 0.0001:
				return
			var speed_w: float = adapter.get_wind_speed(idx)
			if speed_w <= 0.0001:
				speed_w = mag_w
			var ang_w: float = atan2(wv.y, wv.x)
			# value 用 baker 现成的 R 通道；intensity 复用 G 通道存模长（HSV 的 V）
			# 但当前编码协议 R=value，G=intensity；我们让 R=hue，G=norm_mag。
			# 主循环按 _s_vector_mode 走 hue / dir_intensity 两个槽写入。
			_s_hue = fposmod((ang_w / TAU) + 0.5, 1.0)
			_s_dir_intensity = clampf(speed_w / WIND_SPEED_NORM_MAX, 0.0, 1.0)
			_s_valid = true
			_s_vector_mode = true
		OverlayMode.MODE.OCEAN_CURRENT_DIR:
			# 仅水域有效；陆地无意义。复用 cell.ocean_current。
			if not bool(cell.passable_sea):
				return
			var oc: Vector2 = adapter.get_ocean_current(idx)
			var mag_o: float = oc.length()
			if mag_o < 0.0001:
				return
			var ang_o: float = atan2(oc.y, oc.x)
			_s_hue = fposmod((ang_o / TAU) + 0.5, 1.0)
			_s_dir_intensity = clampf(mag_o / OCEAN_CURRENT_NORM_MAX, 0.0, 1.0)
			_s_valid = true
			_s_vector_mode = true
		OverlayMode.MODE.SLP:
			# Physical Wind & Ocean Circulation 调试通道：海陆压力（双向）。
			# cell.slp ∈ [-1, 1] 归一化（陆地夏低冬高、海洋季节波动小）。
			# 全图都有效；diverging 渐变 → 0=低压(冷色) / 0.5=中性 / 1=高压(暖色)。
			var slp_raw: float = adapter.get_slp(idx)
			_s_value = 0.5 + clampf(slp_raw / (SLP_OVERLAY_NORM_RANGE * 2.0), -0.5, 0.5)
			_s_valid = true
		OverlayMode.MODE.WIND_STRESS_CURL:
			# 仅水域有意义（陆地不参与海盆 ψ 求解）。cell.wind_stress_curl 由
			# PhysicalCirculationSolver 在 ψ 求解前的源项计算阶段写入；典型量级
			# ~ ±0.5（无量纲，只用于 overlay 视觉对比）。
			if not bool(cell.passable_sea):
				return
			var curl_raw: float = adapter.get_wind_stress_curl(idx)
			_s_value = 0.5 + clampf(curl_raw * 1.0, -0.5, 0.5)
			_s_valid = true
		OverlayMode.MODE.OCEAN_PSI:
			# 仅水域有效。流函数 ψ 的等高线 = 流线，diverging 渐变让北半球反气旋
			# (ψ 中部小)与南半球反气旋(ψ 中部大)以同色对称呈现。
			# cell.ocean_psi 量级 ~ ±5（数值随地图尺寸变化），稳健做法：scan max abs 后
			# 归一化；这里简化用经验常数 5.0。
			if not bool(cell.passable_sea):
				return
			var psi_raw: float = adapter.get_ocean_psi(idx)
			_s_value = 0.5 + clampf(psi_raw / 10.0, -0.5, 0.5)
			_s_valid = true
		OverlayMode.MODE.DEMO_THERMAL_GRADIENT:
			# Reference-impl Pass #2 (demo-only, performance-charter §12.6)。
			# 采样 MapData.demo_thermal_gradient_arr[cell.index]——该字段由 C++
			# _ext.run_thermal_gradient_pass + flush snapshot 填充；开关关闭时
			# size=0，安全返回 valid=false 避免走错路。
			if map == null:
				return
			var dtg_arr: PackedFloat32Array = map.demo_thermal_gradient_arr
			var dtg_n: int = dtg_arr.size()
			if dtg_n <= 0:
				return
			var dtg_idx: int = int(cell.index)
			if dtg_idx < 0 or dtg_idx >= dtg_n:
				return
			_s_value = clampf(dtg_arr[dtg_idx], 0.0, 1.0)
			_s_valid = true

static func _is_near_zero_sample(mode: int, value: float, intensity: float, is_vector_mode: bool) -> bool:
	if is_vector_mode:
		return intensity <= 0.025
	match mode:
		OverlayMode.MODE.OCEAN_CURRENT, OverlayMode.MODE.WIND_SPEED:
			return value <= 0.025
		OverlayMode.MODE.OCEAN_HEAT_TRANSPORT, OverlayMode.MODE.UPWELLING, OverlayMode.MODE.SLP, OverlayMode.MODE.WIND_STRESS_CURL, OverlayMode.MODE.OCEAN_PSI:
			return absf(value - 0.5) <= 0.01
		_:
			return false

# 取得 cell 的真实归一化纬度 ny ∈ [0, 1]。
# 优先级：
#   1. 用 world.cell_pixel_lists[cell] 第一个像素 idx 查 world.latitude_buffer
#      —— 这就是 map_baker 渲染时实际使用的 ny，与 main.gd 标签 / shader 半球
#      判断完全一致，是权威来源。
#   2. fallback：极旧地图没有 latitude_buffer / cell_pixel_lists 时，退到
#      _latitude_hint 的轴坐标近似（精度差，仅保证不崩）。
static func _cell_latitude(
	cell,
	world,
	lat_buf: PackedFloat32Array,
	lat_buf_size: int
) -> float:
	if world != null and lat_buf_size > 0 and world.cell_pixel_lists != null \
			and not world.cell_pixel_lists.is_empty():
		var pixels: PackedInt32Array = world.cell_pixel_lists.get(
			cell, PackedInt32Array()
		)
		if pixels.size() > 0:
			var idx: int = pixels[0]
			if idx >= 0 and idx < lat_buf_size:
				return lat_buf[idx]
	return _latitude_hint(cell)

# 用 cell 的 (q, r) 估算 ny ∈ [0, 1]。仅作为 latitude_buffer 缺失时的 fallback。
# 注意：这只是粗略近似，hex 轴坐标到 offset-row 的真实换算依赖具体布局，
# 5 档气候带分档足以容错；正常路径请走 _cell_latitude。
static func _latitude_hint(cell) -> float:
	# fallback 估算：直接用 axial 的 r 当行号（pointy-top 下 r 与垂直方向最对齐）。
	# 旧版本曾用 `r + 0.5*q`，这是对角线方向，会导致 overlay 呈左上→右下斜带 bug。
	var row_like: float = float(cell.r)
	# 世界半高的经验常量（hex 坐标下 map_height ~ 80..200），做一个稳定的归一化：
	var half_h: float = 90.0
	var ny: float = 0.5 + clampf(row_like / (2.0 * half_h), -0.5, 0.5)
	return ny
