# map_data.gd
# 地图数据容器
# 存储所有 HexCell，以 Vector3i(q, r, s) 为键的 Dictionary

class_name MapData

var width:  int = 0
var height: int = 0

# 主存储：cube 坐标 → HexCell
var _cells: Dictionary = {}

# ─── Daily-Sim SoA Refactor 阶段 2：邻居索引 SoA ──────────────────────
# 由 _build_indices() 一次性预计算（在 MapGenerator.generate 完成所有 cell
# 入库 + terrain 定型后调用）。fast-tick 热路径（_apply_sea_ice_daily_pass /
# _apply_ocean_heat_transport_pass / _apply_local_climate_coupling_pass）
# 通过这些索引避开每帧创建 6-元 Array 的 GC 压力。
#
# 不变量：
#   - _cell_array.size() == _cells.size() == _cell_index.size()
#   - _neighbor_indices.size() == _cell_array.size() * 6
#   - _neighbor_indices[i*6 + dir] == -1 表示该方向没有邻居（地图边缘）
#   - 顺序与 HexUtils.CUBE_DIRECTIONS 一致：0=E, 1=NE, 2=NW, 3=W, 4=SW, 5=SE
#   - regenerate 路径：MapData 实例本身被丢弃重建，无需手动失效；冷路径
#     （生成阶段、refresh_seasonal）继续使用 get_neighbors(cell)，不依赖索引
var _cell_array: Array[HexCell] = []
var _cell_index: Dictionary = {}            # HexCell → int (idx)
var _neighbor_indices: PackedInt32Array = PackedInt32Array()
var _indices_built: bool = false

# ─── Climate-Weather 2ms Budget Plan — Phase A.1：SoA 字段镜像 ───────────
# 25 个平行 PackedArray，长度恒等于 _cell_array.size()。所有热路径子段（climate
# pass A/B、ocean_water/ocean_land、sea_ice、transp、weather field solver）将
# 在阶段 A.3/B/C 切换到只读写下面的 SoA 数组，禁止再走 cell.* 强类型成员或字典。
# round 末通过 flush_soa_to_cells() 一次性同步给 UI / Baker / Overlay 等只读消费者。
#
# 双缓冲设计（阶段 B.1 投入使用）：
#   - 每个浮点字段同时维护 _arr（当前/写）与 _arr_prev（上一日/读）；阶段 A.3 仅
#     使用 _arr，行为与 legacy 等价；阶段 B.1 sub-pass 跨 tick 切片时下游读 _prev、
#     当前 sub-pass 写 _next（即 _arr），整段 sub-pass 完成才 swap。
#   - byte 字段（terrain/landform/vegetation/cover/weather_type/is_water）变化
#     频率低，阶段 A 不做双缓冲；后续按需扩展。
#
# 移动平台兼容（需求 9.1）：全部使用 PackedByteArray / PackedFloat32Array /
# PackedInt32Array，按 cell_count 一次性 resize，禁止 push_back（避免 GC 压力）。
var _soa_built: bool = false

# float32 — climate / 温度族
var temp_arr:               PackedFloat32Array = PackedFloat32Array()
var temp_arr_prev:          PackedFloat32Array = PackedFloat32Array()
var moisture_arr:           PackedFloat32Array = PackedFloat32Array()
var moisture_arr_prev:      PackedFloat32Array = PackedFloat32Array()
var snow_cover_arr:         PackedFloat32Array = PackedFloat32Array()
var snow_cover_arr_prev:    PackedFloat32Array = PackedFloat32Array()
var temp_baseline_arr:      PackedFloat32Array = PackedFloat32Array()
var temp_30d_arr:           PackedFloat32Array = PackedFloat32Array()
var temp_365d_arr:          PackedFloat32Array = PackedFloat32Array()
var temp_anomaly_arr:       PackedFloat32Array = PackedFloat32Array()
var sea_ice_frac_arr:       PackedFloat32Array = PackedFloat32Array()
var sea_ice_frac_arr_prev:  PackedFloat32Array = PackedFloat32Array()

# float32 — 天气场
var weather_intensity_arr:  PackedFloat32Array = PackedFloat32Array()
var weather_cloud_arr:      PackedFloat32Array = PackedFloat32Array()
var weather_precip_arr:     PackedFloat32Array = PackedFloat32Array()

# ─── B-full Step-2：weather hot loop 直读字段（写少读多） ────────────
# 与 weather_intensity/cloud/precip 一组，由 weather_system.commit 写入。
# weather_field_init_arr 为 u8 (0/1)，承载 hex_cell.weather_field_initialized。
var weather_vapor_arr:        PackedFloat32Array = PackedFloat32Array()
var weather_convergence_arr:  PackedFloat32Array = PackedFloat32Array()
var weather_instability_arr:  PackedFloat32Array = PackedFloat32Array()
var weather_field_init_arr:   PackedByteArray   = PackedByteArray()

# ─── B-full Step-2：风温耦合 anomaly + 河流标志（write 少 / read 多） ───
# air_mass_temp_anomaly_arr: 由 map_generator._climate_pass_b 写，weather hot loop 读。
# has_river_arr: 仅地图生成期写一次，运行期纯读；通过 rebuild_soa_from_cells 同步。
var air_mass_temp_anomaly_arr: PackedFloat32Array = PackedFloat32Array()
var has_river_arr:             PackedByteArray   = PackedByteArray()

# ─── Phase 3a Step 2.1.a：climate Pass-A SoA 化新增 2 个字段 ──────
# ema_initialized_arr: 1 字节，0 / 1。冷启动判定（Pass-A 冷启动赋初值；后续
#   ocean_heat_transport_water/land_soa 读它决定是否参与 EMA 平滑）。
# temp_season_offset_arr: 当日季节偏移量（Pass-A 写、UI breakdown 经 flush
#   读 cell 字段，运行期纯 SoA 内部使用）。
var ema_initialized_arr:       PackedByteArray   = PackedByteArray()
var temp_season_offset_arr:    PackedFloat32Array = PackedFloat32Array()

# float32 — 慢层基线 / 风 / 洋流（写少读多）
var elevation_arr:          PackedFloat32Array = PackedFloat32Array()
var base_moisture_arr:      PackedFloat32Array = PackedFloat32Array()
var ocean_current_x_arr:    PackedFloat32Array = PackedFloat32Array()
var ocean_current_y_arr:    PackedFloat32Array = PackedFloat32Array()
var wind_x_arr:             PackedFloat32Array = PackedFloat32Array()
var wind_y_arr:             PackedFloat32Array = PackedFloat32Array()

# float32 — cell 屏幕坐标缓存（size=1 单位；用于内层循环消除 HexUtils.cube_to_world 重算）
var cell_pos_x_arr:         PackedFloat32Array = PackedFloat32Array()
var cell_pos_y_arr:         PackedFloat32Array = PackedFloat32Array()

# ─── B1-A：每 cell 的归一化纬度 + 年均温度（与 elevation 无关）常量 LUT ────
# 由 bake_lat_temp_year_lut(generator) 在 rebuild_soa_from_cells 完成后立即
# bake 一次。运行期 Pass A 内层只是数组索引，彻底取消 _cube_row_norm 调用。
#   cell_lat_norm_arr[i] = _cube_row_norm(cell_i, _last_cfg)              ∈ [0, 1]
#   temp_baseline_year_arr[i] = pow(cos((ny-0.5)*π), 1.2)                  ∈ [0, 1]
# Pass A 当日温度 = clamp(temp_baseline_year_arr[i] - elev*0.5, 0, 1) + season_offset
var cell_lat_norm_arr:        PackedFloat32Array = PackedFloat32Array()
var temp_baseline_year_arr:   PackedFloat32Array = PackedFloat32Array()
var _lat_lut_baked: bool = false

# byte — 枚举与 bool 标志（阶段 A 不做双缓冲；需求 1.1 列表里的 8/9/10 项）
var terrain_arr:            PackedByteArray = PackedByteArray()
var landform_arr:           PackedByteArray = PackedByteArray()
var vegetation_arr:         PackedByteArray = PackedByteArray()
var cover_arr:              PackedByteArray = PackedByteArray()
var weather_type_arr:       PackedByteArray = PackedByteArray()
var is_water_arr:           PackedByteArray = PackedByteArray()

# ─── Dirty Mask（需求 2.1 / 2.4 阶段 A.2 投入使用） ───────────────────────
# 每个 cell 1 字节：0 = clean、1 = dirty。Pass A 写入时按 epsilon 判定标 dirty；
# Pass B / 下游稀疏 sub-pass 仅遍历 dirty=1 的 cell（含 1 跳邻居膨胀）。
# 阶段 A.1 仅声明并提供 mark/clear/ratio API，不在任何 sub-pass 内消费。
var climate_dirty_mask:     PackedByteArray = PackedByteArray()
var weather_dirty_mask:     PackedByteArray = PackedByteArray()

# --- 初始化 ---
func _init(w: int, h: int) -> void:
	width  = w
	height = h

# --- 基础读写 ---

## 按 cube 坐标获取地块（不存在返回 null）
func get_cell(q: int, r: int) -> HexCell:
	return _cells.get(Vector3i(q, r, -q - r), null)

func get_cell_by_cube(coords: Vector3i) -> HexCell:
	return _cells.get(coords, null)

## 写入地块（自动以其 cube 坐标为键）
func set_cell(cell: HexCell) -> void:
	_cells[Vector3i(cell.q, cell.r, cell.s)] = cell

## 判断坐标是否在地图内（offset 行列）
func has_offset(col: int, row: int) -> bool:
	return col >= 0 and col < width and row >= 0 and row < height

## 遍历所有地块
func all_cells() -> Array:
	return _cells.values()

## 获取地块总数
func cell_count() -> int:
	return _cells.size()

# --- 邻居查询 ---

## 返回指定地块的所有存在邻居（最多 6 个）
func get_neighbors(cell: HexCell) -> Array:
	var result: Array = []
	for dir in HexUtils.CUBE_DIRECTIONS:
		var nc := Vector3i(cell.q + dir.x, cell.r + dir.y, cell.s + dir.z)
		var neighbor = _cells.get(nc, null)
		if neighbor != null:
			result.append(neighbor)
	return result

## 返回指定 cube 坐标的所有存在邻居
func get_neighbors_by_cube(coords: Vector3i) -> Array:
	var cell = get_cell_by_cube(coords)
	if cell == null:
		return []
	return get_neighbors(cell)

# ─── Daily-Sim SoA Refactor 阶段 2：索引访问 API ────────────────────
# 仅 fast-tick 热路径使用；冷路径继续走 get_neighbors(cell)。

## 一次性构建（_cell_array / _cell_index / _neighbor_indices）。
## 必须在所有 cell 入库且 terrain 定型完成后调用一次；regenerate 时
## MapData 整体被替换，不需要重复调用。重复调用会先清空再重建。
func _build_indices() -> void:
	_cell_array.clear()
	_cell_index.clear()
	var n: int = _cells.size()
	_cell_array.resize(n)
	_neighbor_indices.resize(n * 6)
	# 第一遍：填 _cell_array / _cell_index（Phase 3a Step 2.1：同步注入 cell.index，
	# 让 hot loop 直接用 `arr[cell.index]`，避免 _cell_index Dictionary 查找）
	var i: int = 0
	for key in _cells.keys():
		var cell: HexCell = _cells[key]
		_cell_array[i] = cell
		_cell_index[cell] = i
		cell.index = i
		i += 1
	# 第二遍：填 _neighbor_indices；HexUtils.CUBE_DIRECTIONS 顺序：
	# 0=E, 1=NE, 2=NW, 3=W, 4=SW, 5=SE
	var dirs: Array = HexUtils.CUBE_DIRECTIONS
	for j in range(n):
		var c: HexCell = _cell_array[j]
		var base: int = j * 6
		for d in range(6):
			var dv: Vector3i = dirs[d]
			var nb_key := Vector3i(c.q + dv.x, c.r + dv.y, c.s + dv.z)
			var nb = _cells.get(nb_key, null)
			if nb == null:
				_neighbor_indices[base + d] = -1
			else:
				# 邻居一定已在 _cell_index 内（因为 _cells 是同源）
				_neighbor_indices[base + d] = int(_cell_index.get(nb, -1))
	_indices_built = true

## 索引是否已构建（fast-tick 调用前断言用）。
func has_indices() -> bool:
	return _indices_built

## 根据 idx 取 cell；越界返回 null。
func cell_at(idx: int) -> HexCell:
	if idx < 0 or idx >= _cell_array.size():
		return null
	return _cell_array[idx]

## 根据 cell 取 idx；不存在返回 -1。
func index_of(cell: HexCell) -> int:
	return int(_cell_index.get(cell, -1))

## 取 idx 处 cell 的第 dir 方向邻居的 idx；无邻居返回 -1。
## dir ∈ [0, 5]，与 HexUtils.CUBE_DIRECTIONS 同序。
func neighbor_index(idx: int, dir: int) -> int:
	if idx < 0 or idx >= _cell_array.size() or dir < 0 or dir > 5:
		return -1
	return _neighbor_indices[idx * 6 + dir]

## 顺序遍历所有 cell（按 _cell_array 顺序，与 idx 对应）。
## 与 all_cells() 不同：all_cells() 走的是 Dictionary.values()，顺序不保证；
## 而 iter_cells() 顺序固定，因此当外部循环需要"已知 idx"时优先用此函数。
func iter_cells() -> Array[HexCell]:
	return _cell_array

## 直接拿底层 PackedInt32Array（fast-tick 极致内联用）。
## 调用方应自行确保 has_indices() == true，并按 idx*6+dir 索引。
func neighbor_indices_packed() -> PackedInt32Array:
	return _neighbor_indices

# ─── Climate-Weather 2ms Budget — Phase A.1：SoA 构造 / 同步 API ─────────
# 调用关系：
#   - bake_world / 加载存档完成后调用 rebuild_soa_from_cells() 一次同步全部字段；
#   - 任何 sub-pass 写入完成后由调度器调用 flush_soa_to_cells() 把 SoA 写回
#     HexCell 强类型成员，供 UI / Baker / Overlay 等只读消费者继续用 cell.* 形式读；
#   - 跨 tick 切片场景下由 sub-pass 自己 swap _prev/_next 双缓冲（见 soa_swap_*
#     系列），UI 通道始终读 _arr_prev 保证一致快照。
#
# 注意：本阶段（A.1）只是建立基础设施，不修改任何 sub-pass 的行为。所以
# rebuild 在 bake_world 末尾执行后，flush 暂时不会被调度器主动触发；待
# climate_pass_a/b_soa 等新路径上线（任务 1.3）后才进入活跃同步状态。
func has_soa() -> bool:
	return _soa_built

func soa_size() -> int:
	return _cell_array.size()

## 一次性按 _cell_array.size() 预分配所有 SoA 数组与 dirty mask。重复调用是安全的。
func _alloc_soa(n: int) -> void:
	temp_arr.resize(n);              temp_arr_prev.resize(n)
	moisture_arr.resize(n);          moisture_arr_prev.resize(n)
	snow_cover_arr.resize(n);        snow_cover_arr_prev.resize(n)
	temp_baseline_arr.resize(n)
	temp_30d_arr.resize(n)
	temp_365d_arr.resize(n)
	temp_anomaly_arr.resize(n)
	sea_ice_frac_arr.resize(n);      sea_ice_frac_arr_prev.resize(n)
	weather_intensity_arr.resize(n)
	weather_cloud_arr.resize(n)
	weather_precip_arr.resize(n)
	elevation_arr.resize(n)
	base_moisture_arr.resize(n)
	ocean_current_x_arr.resize(n)
	ocean_current_y_arr.resize(n)
	wind_x_arr.resize(n)
	wind_y_arr.resize(n)
	cell_pos_x_arr.resize(n)
	cell_pos_y_arr.resize(n)
	cell_lat_norm_arr.resize(n)
	temp_baseline_year_arr.resize(n)
	terrain_arr.resize(n)
	landform_arr.resize(n)
	vegetation_arr.resize(n)
	cover_arr.resize(n)
	weather_type_arr.resize(n)
	is_water_arr.resize(n)
	climate_dirty_mask.resize(n)
	weather_dirty_mask.resize(n)
	# B-full Step-2：6 个新 SoA 字段一次性 resize
	weather_vapor_arr.resize(n)
	weather_convergence_arr.resize(n)
	weather_instability_arr.resize(n)
	weather_field_init_arr.resize(n)
	air_mass_temp_anomaly_arr.resize(n)
	has_river_arr.resize(n)
	# Phase 3a Step 2.1.a：climate Pass-A SoA 化新增 2 个字段
	ema_initialized_arr.resize(n)
	temp_season_offset_arr.resize(n)

## 从 HexCell 强类型成员单向 sync 到 SoA。在 bake_world / 加载存档 / regenerate
## 路径调用一次。运行期 sub-pass 完成后不要再调用本函数（会盖掉 SoA 写入）。
func rebuild_soa_from_cells() -> void:
	if not _indices_built:
		_build_indices()
	var n: int = _cell_array.size()
	_alloc_soa(n)
	# size=1 单位的 cube_to_world 缓存：内层循环用 dx/dy 相对位移，常量比例对方向判定无影响。
	for i in range(n):
		var c: HexCell = _cell_array[i]
		temp_arr[i] = c.temperature
		moisture_arr[i] = c.moisture
		snow_cover_arr[i] = c.snow_cover
		temp_baseline_arr[i] = c.temp_baseline
		temp_30d_arr[i] = c.temp_30d_mean
		temp_365d_arr[i] = c.temp_365d_mean
		temp_anomaly_arr[i] = c.temp_dev_from_annual
		sea_ice_frac_arr[i] = c.sea_ice_fraction
		weather_intensity_arr[i] = c.weather_intensity
		weather_cloud_arr[i] = c.weather_cloud
		weather_precip_arr[i] = c.weather_precip
		elevation_arr[i] = c.elevation
		base_moisture_arr[i] = c.base_moisture
		ocean_current_x_arr[i] = c.ocean_current.x
		ocean_current_y_arr[i] = c.ocean_current.y
		wind_x_arr[i] = c.wind_vector.x
		wind_y_arr[i] = c.wind_vector.y
		var wp: Vector2 = HexUtils.cube_to_world(c.q, c.r, 1.0)
		cell_pos_x_arr[i] = wp.x
		cell_pos_y_arr[i] = wp.y
		terrain_arr[i] = int(c.terrain) & 0xFF
		landform_arr[i] = c.landform & 0xFF
		vegetation_arr[i] = c.vegetation & 0xFF
		cover_arr[i] = c.cover & 0xFF
		weather_type_arr[i] = c.weather_type & 0xFF
		is_water_arr[i] = (1 if (not c.passable_land) else 0)
		climate_dirty_mask[i] = 0
		weather_dirty_mask[i] = 0
		# B-full Step-2：6 个新字段 AoS → SoA 一次性镜像
		weather_vapor_arr[i] = c.weather_vapor
		weather_convergence_arr[i] = c.weather_convergence
		weather_instability_arr[i] = c.weather_instability
		weather_field_init_arr[i] = (1 if c.weather_field_initialized else 0)
		air_mass_temp_anomaly_arr[i] = c.air_mass_temp_anomaly
		has_river_arr[i] = (1 if c.has_river else 0)
		# Phase 3a Step 2.1.a：Pass-A SoA 化新增 2 个字段镜像
		ema_initialized_arr[i] = (1 if c._ema_initialized else 0)
		temp_season_offset_arr[i] = c.temp_season_offset
	# 同步初始化 _prev 双缓冲为 _next 当前快照，避免首日 sub-pass 切片读到 0。
	temp_arr_prev = temp_arr.duplicate()
	moisture_arr_prev = moisture_arr.duplicate()
	snow_cover_arr_prev = snow_cover_arr.duplicate()
	sea_ice_frac_arr_prev = sea_ice_frac_arr.duplicate()
	_soa_built = true
	# B1-A：lat / temp_year LUT 必须由 generator 在 _last_cfg 就位后 bake；
	# 这里仅置为未 bake 状态，bake_world 路径会立即调用 bake_lat_temp_year_lut()。
	_lat_lut_baked = false

## 把 SoA 当前数组（_arr，不是 _prev）一次性回写到 HexCell 强类型成员。
## 仅由调度器在 round 末调用，UI/Baker 才能拿到一致快照。
func flush_soa_to_cells() -> void:
	if not _soa_built:
		return
	var n: int = _cell_array.size()
	for i in range(n):
		var c: HexCell = _cell_array[i]
		c.temperature = temp_arr[i]
		c.moisture = moisture_arr[i]
		c.snow_cover = snow_cover_arr[i]
		c.temp_baseline = temp_baseline_arr[i]
		c.temp_30d_mean = temp_30d_arr[i]
		c.temp_365d_mean = temp_365d_arr[i]
		c.temp_dev_from_annual = temp_anomaly_arr[i]
		c.sea_ice_fraction = sea_ice_frac_arr[i]
		c.weather_intensity = weather_intensity_arr[i]
		c.weather_cloud = weather_cloud_arr[i]
		c.weather_precip = weather_precip_arr[i]
		c.ocean_current.x = ocean_current_x_arr[i]
		c.ocean_current.y = ocean_current_y_arr[i]
		c.wind_vector.x = wind_x_arr[i]
		c.wind_vector.y = wind_y_arr[i]
		c.weather_type = int(weather_type_arr[i])
		# B-full Step-2：4 个新 weather 字段 SoA → HexCell 写回
		# air_mass_temp_anomaly / has_river 不写回（运行期 SoA 是权威，HexCell 字段
		# 在地图生成期 / climate pass 时已被独立写入，无需反向写）。
		c.weather_vapor = weather_vapor_arr[i]
		c.weather_convergence = weather_convergence_arr[i]
		c.weather_instability = weather_instability_arr[i]
		c.weather_field_initialized = (weather_field_init_arr[i] > 0)
		# Phase 3a Step 2.1.a：Pass-A SoA → cell 写回（UI breakdown / 调试 print 路径）
		c._ema_initialized = (ema_initialized_arr[i] > 0)
		c.temp_season_offset = temp_season_offset_arr[i]

## B1-A：一次性烘焙 cell 归一化纬度 + 年均温度 LUT。
## 必须在 rebuild_soa_from_cells() 完成 + MapGenerator._last_cfg 就位之后调用。
## generator 参数提供 _cube_row_norm / _compute_temperature 数值的权威来源——
## 我们直接借用其私有方法保证与 legacy 1:1 对齐（避免在 MapData 重复实现）。
## 重复调用是安全的；运行期不再变化。
func bake_lat_temp_year_lut(generator) -> void:
	if not _soa_built:
		push_warning("[map_data] bake_lat_temp_year_lut: SoA not built; call rebuild_soa_from_cells() first")
		return
	if generator == null:
		push_warning("[map_data] bake_lat_temp_year_lut: generator is null")
		return
	var n: int = _cell_array.size()
	cell_lat_norm_arr.resize(n)
	temp_baseline_year_arr.resize(n)
	for i in range(n):
		var c: HexCell = _cell_array[i]
		var ny: float = float(generator.public_cube_row_norm(c))
		cell_lat_norm_arr[i] = ny
		# 与 _compute_temperature(ny, 0.0) 1:1 对齐：lat_temp = pow(cos(lat_signed*π/2), 1.2)
		var lat_signed: float = (ny - 0.5) * 2.0
		var lat_temp: float = pow(cos(lat_signed * PI * 0.5), 1.2)
		if lat_temp < 0.0:
			lat_temp = 0.0
		elif lat_temp > 1.0:
			lat_temp = 1.0
		temp_baseline_year_arr[i] = lat_temp
	_lat_lut_baked = true

func has_lat_lut() -> bool:
	return _lat_lut_baked

## sub-pass 完整跑完一轮后，把当前 _arr 快照拷贝到 _arr_prev。下游若开启切片
## 双缓冲读路径，应统一从 _arr_prev 读、本 sub-pass 写 _arr，整段完成后调用此 swap。
## 注意：阶段 A.1 没有 sub-pass 真正使用双缓冲；本函数是阶段 B.1 的预留 API。
func soa_swap_double_buffer() -> void:
	if not _soa_built:
		return
	temp_arr_prev = temp_arr.duplicate()
	moisture_arr_prev = moisture_arr.duplicate()
	snow_cover_arr_prev = snow_cover_arr.duplicate()
	sea_ice_frac_arr_prev = sea_ice_frac_arr.duplicate()

# ─── Dirty Mask 操作 API（阶段 A.1 仅占位；阶段 A.2 正式投入使用） ──────────
func mark_climate_dirty(idx: int) -> void:
	if idx >= 0 and idx < climate_dirty_mask.size():
		climate_dirty_mask[idx] = 1

func mark_weather_dirty(idx: int) -> void:
	if idx >= 0 and idx < weather_dirty_mask.size():
		weather_dirty_mask[idx] = 1

func clear_climate_dirty() -> void:
	var n: int = climate_dirty_mask.size()
	for i in range(n):
		climate_dirty_mask[i] = 0

func clear_weather_dirty() -> void:
	var n: int = weather_dirty_mask.size()
	for i in range(n):
		weather_dirty_mask[i] = 0

## 标记全图 dirty（季节切换日 / 每 30 日强制 full sweep / 加载存档后首日）。
func mark_all_climate_dirty() -> void:
	var n: int = climate_dirty_mask.size()
	for i in range(n):
		climate_dirty_mask[i] = 1

func climate_dirty_ratio() -> float:
	var n: int = climate_dirty_mask.size()
	if n == 0:
		return 0.0
	var count: int = 0
	for i in range(n):
		if climate_dirty_mask[i] != 0:
			count += 1
	return float(count) / float(n)

func weather_dirty_ratio() -> float:
	var n: int = weather_dirty_mask.size()
	if n == 0:
		return 0.0
	var count: int = 0
	for i in range(n):
		if weather_dirty_mask[i] != 0:
			count += 1
	return float(count) / float(n)

# --- 统计工具 ---

## 统计各地形数量，返回 Dictionary { TERRAIN: count }
func terrain_stats() -> Dictionary:
	var stats: Dictionary = {}
	for cell in _cells.values():
		var t = cell.terrain
		stats[t] = stats.get(t, 0) + 1
	return stats

## 按地形筛选地块列表
func cells_of_terrain(terrain: TerrainType.TERRAIN) -> Array:
	var result: Array = []
	for cell in _cells.values():
		if cell.terrain == terrain:
			result.append(cell)
	return result

# --- Emergent Climate Coupling：慢层只读访问器 ──────────────────────────
# 天气 / 快层 pass 应通过该访问器读取慢层字段，而不是直接读 cell.base_* /
# cell.landform / cell.terrain / cell.cover / cell.elevation / cell.ocean_current 等。
# 这样日后如果把慢层数据迁移到独立容器或做并行化，调用方不需要修改。
#
# 参数：
#   qr     — 目标 cell 的 cube 坐标（Vector3i）
#   fields — 慢层字段名列表，允许值：
#              "elevation", "landform", "terrain", "cover",
#              "base_temperature", "base_moisture", "base_vegetation", "base_terrain",
#              "ocean_current", "upwelling_strength", "temperature_transport_anomaly",
#              "sea_ice_fraction", "soil_moisture", "vegetation_growth_pressure",
#              "has_river", "has_volcano"
# 返回：Dictionary，键为字段名、值为该字段当前值；cell 不存在时返回空字典。
#
# Debug 守卫：字段名拼写错误时在 OS.is_debug_build() 下 push_warning 一次。
# 快层 pass 禁止对返回的 Dictionary 写入后再回写 HexCell（本函数只读）。
const _SLOW_LAYER_FIELDS: Dictionary = {
	"elevation": true, "landform": true, "terrain": true, "cover": true,
	"base_temperature": true, "base_moisture": true,
	"base_vegetation": true, "base_terrain": true,
	"ocean_current": true, "upwelling_strength": true,
	"temperature_transport_anomaly": true,
	"sea_ice_fraction": true, "soil_moisture": true,
	"vegetation_growth_pressure": true,
	"has_river": true, "has_volcano": true,
}

func sample_slow_layer(qr: Vector3i, fields: Array) -> Dictionary:
	var cell: HexCell = _cells.get(qr, null)
	if cell == null:
		return {}
	var out: Dictionary = {}
	for f in fields:
		var key: String = str(f)
		if not _SLOW_LAYER_FIELDS.has(key):
			if OS.is_debug_build():
				push_warning("sample_slow_layer: unknown slow-layer field '%s'" % key)
			continue
		# 基础字段映射（GDScript 对 Object 可直接用字符串访问属性）
		match key:
			"base_temperature":
				# HexCell 上并没有 base_temperature（仅 base_moisture / base_terrain 等）；
				# Fast-tick perf opt (C)：temp_baseline 已升级为 HexCell 强类型成员，
				# 直接读，不再走 current_state["_temp_baseline"] 字典查找。
				out[key] = cell.temp_baseline
			_:
				out[key] = cell.get(key)
	return out
