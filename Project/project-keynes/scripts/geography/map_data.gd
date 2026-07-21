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
# PR-2.3b/2.4：HexCell facade 让 cell.<field> getter 直接走 SoA read_f32，
# 无需再做 SoA → cell 反向同步。round 末 UI / Baker 自动看到最新 SoA 值。
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
var weather_cloud_water_arr: PackedFloat32Array = PackedFloat32Array()
var weather_precip_arr:     PackedFloat32Array = PackedFloat32Array()
var weather_transition_alpha_arr: PackedFloat32Array = PackedFloat32Array()
var weather_classification_temp_arr: PackedFloat32Array = PackedFloat32Array()
var weather_classification_moisture_arr: PackedFloat32Array = PackedFloat32Array()

# ─── B-full Step-2：weather hot loop 直读字段（写少读多） ────────────
# 与 weather_intensity/cloud/precip 一组，由 weather_system.commit 写入。
# weather_field_init_arr 为 u8 (0/1)，承载 hex_cell.weather_field_initialized。
var weather_vapor_arr:        PackedFloat32Array = PackedFloat32Array()
var weather_convergence_arr:  PackedFloat32Array = PackedFloat32Array()
var weather_instability_arr:  PackedFloat32Array = PackedFloat32Array()
var weather_field_init_arr:   PackedByteArray   = PackedByteArray()

# ─── B-full Step-2：风温耦合 anomaly + 河流标志（write 少 / read 多） ───
# air_mass_temp_anomaly_arr: 由 map_generator._climate_pass_b 写，weather hot loop 读。
# has_river_arr / river_*: 仅地图生成期写一次，Baker 读取方向和径流宽度。
var air_mass_temp_anomaly_arr: PackedFloat32Array = PackedFloat32Array()
var has_river_arr:             PackedByteArray   = PackedByteArray()
var river_flow_arr:            PackedFloat32Array = PackedFloat32Array()
var river_downstream_arr:      PackedInt32Array   = PackedInt32Array()
var has_volcano_arr:           PackedByteArray   = PackedByteArray()
var is_lake_seed_arr:          PackedByteArray   = PackedByteArray()
var hydro_parent_arr:          PackedInt32Array   = PackedInt32Array()
var river_discharge_arr:       PackedFloat32Array = PackedFloat32Array()
var river_discharge_30d_arr:   PackedFloat32Array = PackedFloat32Array()
var river_storage_arr:         PackedFloat32Array = PackedFloat32Array()
var groundwater_storage_arr:   PackedFloat32Array = PackedFloat32Array()
var surface_runoff_arr:        PackedFloat32Array = PackedFloat32Array()

# ─── Natural resources：per-cell 资源储量（纯运行期 SoA，无 HexCell 镜像）──
# 初值由 MapGenerator._bootstrap_natural_resource_deposits 在 init_soa_from_bake
# 之后写入；运行期由 run_natural_resource_pass（C++）或 GDScript fallback 推进。
# 与 ocean/local_thermal_anomaly 同类：rebuild_soa_from_cells 仅置 0，不从 HexCell 拷。
var res_timber_reserve_arr:       PackedFloat32Array = PackedFloat32Array()
var res_stone_reserve_arr:        PackedFloat32Array = PackedFloat32Array()
var res_fertile_soil_reserve_arr: PackedFloat32Array = PackedFloat32Array()
var res_coal_reserve_arr:         PackedFloat32Array = PackedFloat32Array()
var res_oil_reserve_arr:          PackedFloat32Array = PackedFloat32Array()
var res_natural_gas_reserve_arr:  PackedFloat32Array = PackedFloat32Array()
var res_copper_ore_reserve_arr:   PackedFloat32Array = PackedFloat32Array()
var res_iron_ore_reserve_arr:     PackedFloat32Array = PackedFloat32Array()
var res_gold_ore_reserve_arr:     PackedFloat32Array = PackedFloat32Array()
var res_silver_ore_reserve_arr:   PackedFloat32Array = PackedFloat32Array()
var res_salt_reserve_arr:         PackedFloat32Array = PackedFloat32Array()
var res_saltpeter_reserve_arr:    PackedFloat32Array = PackedFloat32Array()
var res_rare_earth_reserve_arr:   PackedFloat32Array = PackedFloat32Array()
var res_clay_reserve_arr:         PackedFloat32Array = PackedFloat32Array()
var res_wild_game_reserve_arr:    PackedFloat32Array = PackedFloat32Array()
var res_marine_fish_reserve_arr: PackedFloat32Array = PackedFloat32Array()
var res_freshwater_fish_reserve_arr: PackedFloat32Array = PackedFloat32Array()
var res_arable_land_reserve_arr: PackedFloat32Array = PackedFloat32Array()
var res_paddy_land_reserve_arr: PackedFloat32Array = PackedFloat32Array()
var res_plantation_land_reserve_arr: PackedFloat32Array = PackedFloat32Array()
var res_pasture_reserve_arr: PackedFloat32Array = PackedFloat32Array()
var res_bauxite_reserve_arr: PackedFloat32Array = PackedFloat32Array()
var res_limestone_reserve_arr: PackedFloat32Array = PackedFloat32Array()
var res_silica_sand_reserve_arr: PackedFloat32Array = PackedFloat32Array()
var res_phosphate_rock_reserve_arr: PackedFloat32Array = PackedFloat32Array()
var res_tin_ore_reserve_arr: PackedFloat32Array = PackedFloat32Array()
var res_lead_ore_reserve_arr: PackedFloat32Array = PackedFloat32Array()
var res_zinc_ore_reserve_arr: PackedFloat32Array = PackedFloat32Array()
var res_manganese_ore_reserve_arr: PackedFloat32Array = PackedFloat32Array()
var res_sulfur_reserve_arr: PackedFloat32Array = PackedFloat32Array()
var res_flint_reserve_arr: PackedFloat32Array = PackedFloat32Array()
var res_timber_extra_change_arr:       PackedFloat32Array = PackedFloat32Array()
var res_stone_extra_change_arr:        PackedFloat32Array = PackedFloat32Array()
var res_fertile_soil_extra_change_arr: PackedFloat32Array = PackedFloat32Array()
var res_coal_extra_change_arr:         PackedFloat32Array = PackedFloat32Array()
var res_oil_extra_change_arr:          PackedFloat32Array = PackedFloat32Array()
var res_natural_gas_extra_change_arr:  PackedFloat32Array = PackedFloat32Array()
var res_copper_ore_extra_change_arr:   PackedFloat32Array = PackedFloat32Array()
var res_iron_ore_extra_change_arr:     PackedFloat32Array = PackedFloat32Array()
var res_gold_ore_extra_change_arr:     PackedFloat32Array = PackedFloat32Array()
var res_silver_ore_extra_change_arr:   PackedFloat32Array = PackedFloat32Array()
var res_salt_extra_change_arr:         PackedFloat32Array = PackedFloat32Array()
var res_saltpeter_extra_change_arr:    PackedFloat32Array = PackedFloat32Array()
var res_rare_earth_extra_change_arr:   PackedFloat32Array = PackedFloat32Array()
var res_clay_extra_change_arr:         PackedFloat32Array = PackedFloat32Array()
var res_wild_game_extra_change_arr:    PackedFloat32Array = PackedFloat32Array()
var res_marine_fish_extra_change_arr: PackedFloat32Array = PackedFloat32Array()
var res_freshwater_fish_extra_change_arr: PackedFloat32Array = PackedFloat32Array()
var res_arable_land_extra_change_arr: PackedFloat32Array = PackedFloat32Array()
var res_paddy_land_extra_change_arr: PackedFloat32Array = PackedFloat32Array()
var res_plantation_land_extra_change_arr: PackedFloat32Array = PackedFloat32Array()
var res_pasture_extra_change_arr: PackedFloat32Array = PackedFloat32Array()
var res_bauxite_extra_change_arr: PackedFloat32Array = PackedFloat32Array()
var res_limestone_extra_change_arr: PackedFloat32Array = PackedFloat32Array()
var res_silica_sand_extra_change_arr: PackedFloat32Array = PackedFloat32Array()
var res_phosphate_rock_extra_change_arr: PackedFloat32Array = PackedFloat32Array()
var res_tin_ore_extra_change_arr: PackedFloat32Array = PackedFloat32Array()
var res_lead_ore_extra_change_arr: PackedFloat32Array = PackedFloat32Array()
var res_zinc_ore_extra_change_arr: PackedFloat32Array = PackedFloat32Array()
var res_manganese_ore_extra_change_arr: PackedFloat32Array = PackedFloat32Array()
var res_sulfur_extra_change_arr: PackedFloat32Array = PackedFloat32Array()
var res_flint_extra_change_arr: PackedFloat32Array = PackedFloat32Array()

# ─── A 修复（climate-temp-pingpong-fix-2026-06）— anomaly 合成 ───
# ocean_thermal_anomaly_arr: 由 ocean_water + ocean_land pass 写（写后由 wind_surface 读以合成 temp）。
# local_thermal_anomaly_arr: 由 climate pass_b 写（albedo + coastal + landform + sea_ice 反馈）。
# 二者由 _alloc_soa() 分配；不参与 rebuild_soa_from_cells（无 HexCell 镜像，纯运行期 SoA）。
var ocean_thermal_anomaly_arr: PackedFloat32Array = PackedFloat32Array()
var local_thermal_anomaly_arr: PackedFloat32Array = PackedFloat32Array()

# ─── Phase 3a Step 2.1.a：climate Pass-A SoA 化新增 2 个字段 ──────
# ema_initialized_arr: 1 字节，0 / 1。冷启动判定（Pass-A 冷启动赋初值；后续
#   ocean_heat_transport_water/land_soa 读它决定是否参与 EMA 平滑）。
# temp_season_offset_arr: 当日季节偏移量（Pass-A 写、UI breakdown 经 flush
#   读 cell 字段，运行期纯 SoA 内部使用）。
var ema_initialized_arr:       PackedByteArray   = PackedByteArray()
var temp_season_offset_arr:    PackedFloat32Array = PackedFloat32Array()
var insolation_now_arr:        PackedFloat32Array = PackedFloat32Array()
var insolation_dev_arr:        PackedFloat32Array = PackedFloat32Array()
var day_length_arr:            PackedFloat32Array = PackedFloat32Array()
var heat_input_arr:            PackedFloat32Array = PackedFloat32Array()
var thermal_energy_arr:        PackedFloat32Array = PackedFloat32Array()
var snowpack_arr:              PackedFloat32Array = PackedFloat32Array()
var water_balance_30d_arr:     PackedFloat32Array = PackedFloat32Array()

# ─── B3b：植被动力学字段全量下沉 SoA（消除 stage_b combined pack/unpack） ──
# 6 个字段（4 f32 + 2 i32），由 cpp run_stage_b_pass 在阶段 2 之后直读直写
# `_slots[].arr_f32/.arr_i32`；GDScript 端 hot pass 不再做 cells[i].<field>
# pack/unpack（原先 ~7ms wall 的 95%）。
# 启动期 bake 时从 HexCell 镜像初值（rebuild_soa_from_cells），阶段 2 末尾
# 保留"slot → HexCell 回灌"兼容 _trigger_succession / GDScript legacy fallback /
# baker/UI 读取点（阶段 3 全部迁完后可删）。
var vegetation_vitality_arr:           PackedFloat32Array = PackedFloat32Array()
var vitality_low_streak_arr:           PackedInt32Array   = PackedInt32Array()
var vitality_high_streak_arr:          PackedInt32Array   = PackedInt32Array()
var soil_moisture_arr:                 PackedFloat32Array = PackedFloat32Array()
var vegetation_growth_pressure_arr:    PackedFloat32Array = PackedFloat32Array()
var temperature_transport_anomaly_arr: PackedFloat32Array = PackedFloat32Array()
var vegetation_heat_stress_arr:        PackedFloat32Array = PackedFloat32Array()
var vegetation_drought_stress_arr:     PackedFloat32Array = PackedFloat32Array()
var vegetation_cold_stress_arr:        PackedFloat32Array = PackedFloat32Array()
var vegetation_regen_score_arr:        PackedFloat32Array = PackedFloat32Array()


# ─── Reference-impl Pass #2 (demo-only, performance-charter §12.6) ──
# 由 World.bind_map_data 在 ClimateProfile.demo_thermal_gradient_enabled
# == true 时按需 resize 到 N 并 attach；为 false 时保持 size=0（节省 N×4 字节）。
# 不进存档、不参与存档扫描；运行期由 _ext.run_thermal_gradient_pass 重算。
# 任何真实游戏机制禁止读取。
var demo_thermal_gradient_arr: PackedFloat32Array = PackedFloat32Array()

# float32 — 慢层基线 / 风 / 洋流（写少读多）
var elevation_arr:          PackedFloat32Array = PackedFloat32Array()
var base_moisture_arr:      PackedFloat32Array = PackedFloat32Array()
var ocean_current_x_arr:    PackedFloat32Array = PackedFloat32Array()
var ocean_current_y_arr:    PackedFloat32Array = PackedFloat32Array()
var wind_x_arr:             PackedFloat32Array = PackedFloat32Array()
var wind_y_arr:             PackedFloat32Array = PackedFloat32Array()
var slp_arr:                PackedFloat32Array = PackedFloat32Array()
var wind_speed_arr:         PackedFloat32Array = PackedFloat32Array()
var upwelling_strength_arr: PackedFloat32Array = PackedFloat32Array()
var wind_stress_curl_arr:   PackedFloat32Array = PackedFloat32Array()
var ocean_psi_arr:          PackedFloat32Array = PackedFloat32Array()

# float32 — cell 屏幕坐标缓存（size=1 单位；用于内层循环消除 HexUtils.cube_to_world 重算）
var cell_pos_x_arr:         PackedFloat32Array = PackedFloat32Array()
var cell_pos_y_arr:         PackedFloat32Array = PackedFloat32Array()

# ─── B1-A：每 cell 的归一化纬度 + 年均温度（与 elevation 无关）常量 LUT ────
# 由 bake_lat_temp_year_lut(generator) 在 rebuild_soa_from_cells 完成后立即
# bake 一次。运行期 Pass A 内层只是数组索引，彻底取消 _cube_row_norm 调用。
#   cell_lat_norm_arr[i] = _cube_row_norm(cell_i, _last_cfg)              ∈ [0, 1]
#   temp_baseline_year_arr[i] = DCClimateMath.lat_temp_bell_from_ny(ny)             ∈ [0, 1]
# Pass A 当日温度 = clamp(temp_baseline_year_arr[i] - alt_penalty(temp_height), 0, 1) + season_offset
#   land_h = clamp((elev - sea_level) / (1 - sea_level), 0, 1)
#   temp_height = lerp(land_h, clamp(elev, 0, 1), 0.25)
#   alt_penalty(temp_height) = temp_height*0.40 + smoothstep(0.45, 1.0, temp_height) * 0.22
var cell_lat_norm_arr:        PackedFloat32Array = PackedFloat32Array()
var temp_baseline_year_arr:   PackedFloat32Array = PackedFloat32Array()
var _lat_lut_baked: bool = false

# byte — 枚举与 bool 标志（阶段 A 不做双缓冲；需求 1.1 列表里的 8/9/10 项）
var terrain_arr:            PackedByteArray = PackedByteArray()
var landform_arr:           PackedByteArray = PackedByteArray()
var vegetation_arr:         PackedByteArray = PackedByteArray()
var base_terrain_arr:       PackedByteArray = PackedByteArray()
var base_landform_arr:      PackedByteArray = PackedByteArray()
var base_vegetation_arr:    PackedByteArray = PackedByteArray()
var cover_arr:              PackedByteArray = PackedByteArray()
var weather_type_arr:       PackedByteArray = PackedByteArray()
var weather_prev_type_arr:  PackedByteArray = PackedByteArray()
var weather_target_type_arr: PackedByteArray = PackedByteArray()
var is_water_arr:           PackedByteArray = PackedByteArray()
## Read-only mirror of NativeCountryRuntime territory authority. -1 is neutral.
var country_slot_arr:       PackedInt32Array = PackedInt32Array()
var resource_habitat_mask_arr: PackedByteArray = PackedByteArray()

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
		# [cylindrical-earth-daylight] 东西经度环绕（与 _build_indices 同规则）：
		# 南北(row)越界跳过（两极硬边界），东西(col)用 posmod 绕回 → 最左/最右列互为邻居。
		# 让冷路径（生成、refresh_seasonal、weather、循环 solver fallback）也物理东西连通。
		var off := HexUtils.cube_to_offset(cell.q + dir.x, cell.r + dir.y)
		if off.y < 0 or off.y >= height:
			continue
		var neighbor = _cells.get(HexUtils.offset_to_cube(posmod(off.x, width), off.y), null)
		if neighbor != null and neighbor != cell:
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
			# [cylindrical-earth-daylight] 东西经度环绕（真·圆柱地球）：邻居先转 offset，
			# 南北(row)越界仍 -1（两极是硬边界，不环绕），东西(col)用 posmod 绕回
			# → 最左列与最右列互为邻居。这是运行时唯一邻居权威：洋流/风/温度/湿度/
			# 海冰等 pass 都读 neighbor_indices，此处一改即让所有 pass 在东西方向物理连通。
			var off := HexUtils.cube_to_offset(c.q + dv.x, c.r + dv.y)
			var nrow: int = off.y
			if nrow < 0 or nrow >= height:
				_neighbor_indices[base + d] = -1
				continue
			var wrapped := HexUtils.offset_to_cube(posmod(off.x, width), nrow)
			var nb = _cells.get(wrapped, null)
			if nb == null or nb == c:
				# nb==c 兜底：width 极小时 posmod 可能绕回自身，避免自环邻居
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

# ─── P1：terrain → passable_sea 静态 LUT（256 byte 表） ────────────────
# 给 dynamic_visual_atlas dyn_smooth pass 的 K*6 邻居循环用：原本每个邻居要
# `var nb_cell = map.cell_at(ni); nb_cell.passable_sea` —— 这是
# Dictionary 哈希反查 + RefCounted 字段读取双开销。改用 LUT 后：
#     passable_sea_lut[terrain_arr[ni]]
# 直接 PackedByteArray 索引 → 0 字段解引用 / 0 dict 查找。
#
# LUT 仅依赖 TerrainProfileRegistry（启动时静态注册），构建一次后永久可复用，
# 不随 cell terrain 变化（terrain 改时 terrain_arr[ni] 改，查表结果自动跟随）。
const _PassableSeaLUT_TerrainTypeScript = preload("res://scripts/geography/terrain_type.gd")
static var _passable_sea_lut_cache: PackedByteArray = PackedByteArray()
static var _passable_sea_lut_built: bool = false
static var _trade_passable_lut_cache: PackedByteArray = PackedByteArray()
static var _trade_move_cost_lut_cache: PackedInt32Array = PackedInt32Array()
static var _trade_luts_built: bool = false

## 256-byte LUT：lut[terrain_byte] = 1 if passable_sea else 0。
## 第一次调用时 build；之后零分配返回。线程安全：build 只读 TerrainProfileRegistry。
static func passable_sea_lut() -> PackedByteArray:
	if _passable_sea_lut_built:
		return _passable_sea_lut_cache
	var lut: PackedByteArray = PackedByteArray()
	lut.resize(256)
	# 仅枚举值 0..N-1 有意义（其余字节 byte 默认 0=不通行海，安全 fallback）。
	for t_int in range(256):
		# is_passable_sea 接收 enum；超出枚举范围时 TerrainProfileRegistry 返回 default
		# profile（passable_sea=false），与默认值 0 一致，无需特判。
		lut[t_int] = 1 if _PassableSeaLUT_TerrainTypeScript.is_passable_sea(t_int) else 0
	_passable_sea_lut_cache = lut
	_passable_sea_lut_built = true
	return lut

static func _build_trade_luts() -> void:
	if _trade_luts_built:
		return
	var passable := PackedByteArray()
	var move_cost := PackedInt32Array()
	passable.resize(256)
	move_cost.resize(256)
	for terrain_id in range(256):
		var profile := TerrainProfileRegistry.get_profile(terrain_id)
		passable[terrain_id] = 1 if profile.trade_passable else 0
		move_cost[terrain_id] = int(profile.trade_move_cost)
	_trade_passable_lut_cache = passable
	_trade_move_cost_lut_cache = move_cost
	_trade_luts_built = true

static func trade_passable_lut() -> PackedByteArray:
	_build_trade_luts()
	return _trade_passable_lut_cache

static func trade_move_cost_lut() -> PackedInt32Array:
	_build_trade_luts()
	return _trade_move_cost_lut_cache

func economy_trade_passable_lut() -> PackedByteArray:
	return MapData.trade_passable_lut()

func economy_trade_move_cost_lut() -> PackedInt32Array:
	return MapData.trade_move_cost_lut()

# ─── terrain → physical water 静态 LUT ────────────────────────────────
# cell.is_water 是气候/海洋系统的物理水体掩码，不是通行性掩码。
# 不能用 `not passable_land` 推导：MOUNTAIN/SNOW/GLACIER 也不可陆行，但它们
# 不是水体；SEA_ICE 可陆行，但底层仍是海域，必须视为 water。
static var _is_water_lut_cache: PackedByteArray = PackedByteArray()
static var _is_water_lut_built: bool = false

static func terrain_is_water(t: int) -> bool:
	return t == int(_PassableSeaLUT_TerrainTypeScript.TERRAIN.OCEAN) \
			or t == int(_PassableSeaLUT_TerrainTypeScript.TERRAIN.COAST) \
			or t == int(_PassableSeaLUT_TerrainTypeScript.TERRAIN.LAKE) \
			or t == int(_PassableSeaLUT_TerrainTypeScript.TERRAIN.REEF) \
			or t == int(_PassableSeaLUT_TerrainTypeScript.TERRAIN.SEA_ICE) \
			or t == int(_PassableSeaLUT_TerrainTypeScript.TERRAIN.KELP)

static func terrain_is_water_u8(t: int) -> int:
	return 1 if terrain_is_water(t) else 0

## 256-byte LUT：lut[terrain_byte] = 1 if physical water body.
static func is_water_lut() -> PackedByteArray:
	if _is_water_lut_built:
		return _is_water_lut_cache
	var lut: PackedByteArray = PackedByteArray()
	lut.resize(256)
	for t_int in range(256):
		lut[t_int] = terrain_is_water_u8(t_int)
	_is_water_lut_cache = lut
	_is_water_lut_built = true
	return lut

# ─── sea-ice-render-source-unify 阶段 D：渲染水陆判定 LUT ───────────────
# 渲染管线与气候/海洋系统现在共享同一套物理水体语义：
# OCEAN/COAST/LAKE/REEF/SEA_ICE/KELP 为 water，其余地形为 land。不要用
# passable_land/passable_sea 推导，否则山地、雪地、冰面会被错误归类。
#
# 重要：is_water_lut / is_water_render_lut 都是物理水体语义；通行性、寻路、
#       AI 移动决策必须读 terrain profile 的 passable_land/passable_sea。
static var _is_water_render_lut_cache: PackedByteArray = PackedByteArray()
static var _is_water_render_lut_built: bool = false

const _SEA_ICE_TERRAIN_INT: int = 20  # TerrainType.TERRAIN.SEA_ICE 的 int 值

## 256-byte LUT：lut[terrain_byte] = 1 if 渲染上视为水（含 SEA_ICE）。
static func is_water_render_lut() -> PackedByteArray:
	if _is_water_render_lut_built:
		return _is_water_render_lut_cache
	var lut: PackedByteArray = PackedByteArray()
	lut.resize(256)
	for t_int in range(256):
		lut[t_int] = terrain_is_water_u8(t_int)
	_is_water_render_lut_cache = lut
	_is_water_render_lut_built = true
	return lut

# ─── Climate-Weather 2ms Budget — Phase A.1：SoA 构造 / 同步 API ─────────
# 调用关系（PR-2.4 之后）：
#   - bake_world / 加载存档完成后调用 rebuild_soa_from_cells() 一次同步全部字段
#     （bake-time 初始化路径，不能删除——首次把 cells 内容 dump 到 SoA）；
#   - 运行期 sub-pass 直接 write_*_indexed 到 SoA；HexCell facade getter 让
#     UI / Baker / Overlay 自动看到最新值，**无需** flush_soa_to_cells（PR-2.4 已删）；
#   - 跨 tick 切片场景下由 sub-pass 自己 swap _prev/_next 双缓冲（见 soa_swap_*
#     系列），UI 通道始终读 _arr_prev 保证一致快照。
func has_soa() -> bool:
	return _soa_built

func soa_size() -> int:
	return _cell_array.size()

func sync_is_water_arr_from_terrain() -> void:
	var n: int = mini(terrain_arr.size(), is_water_arr.size())
	var lut: PackedByteArray = MapData.is_water_lut()
	for i in range(n):
		is_water_arr[i] = lut[int(terrain_arr[i])]

func sync_runtime_terrain_facade_from_soa() -> int:
	var n: int = mini(_cell_array.size(), terrain_arr.size())
	var changed: int = 0
	var lut: PackedByteArray = MapData.is_water_lut()
	for i in range(n):
		var terrain_byte: int = int(terrain_arr[i]) & 0xFF
		if i < is_water_arr.size():
			is_water_arr[i] = lut[terrain_byte]
		var cell: HexCell = _cell_array[i]
		if cell != null and int(cell.terrain) != terrain_byte:
			cell.apply_terrain(terrain_byte)
			changed += 1
	return changed

func set_runtime_terrain(idx: int, terrain_id: int, sync_cell: bool = true) -> void:
	if idx < 0 or idx >= _cell_array.size():
		return
	var terrain_byte: int = terrain_id & 0xFF
	if idx < terrain_arr.size():
		terrain_arr[idx] = terrain_byte
	if idx < is_water_arr.size():
		is_water_arr[idx] = MapData.terrain_is_water_u8(terrain_byte)
	if sync_cell:
		var cell: HexCell = cell_at(idx)
		if cell != null:
			cell.apply_terrain(terrain_byte)

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
	weather_cloud_water_arr.resize(n)
	weather_precip_arr.resize(n)
	weather_transition_alpha_arr.resize(n)
	weather_classification_temp_arr.resize(n)
	weather_classification_moisture_arr.resize(n)
	elevation_arr.resize(n)
	base_moisture_arr.resize(n)
	ocean_current_x_arr.resize(n)
	ocean_current_y_arr.resize(n)
	wind_x_arr.resize(n)
	wind_y_arr.resize(n)
	slp_arr.resize(n)
	wind_speed_arr.resize(n)
	upwelling_strength_arr.resize(n)
	wind_stress_curl_arr.resize(n)
	ocean_psi_arr.resize(n)
	cell_pos_x_arr.resize(n)
	cell_pos_y_arr.resize(n)
	cell_lat_norm_arr.resize(n)
	temp_baseline_year_arr.resize(n)
	terrain_arr.resize(n)
	landform_arr.resize(n)
	vegetation_arr.resize(n)
	base_terrain_arr.resize(n)
	base_landform_arr.resize(n)
	base_vegetation_arr.resize(n)
	cover_arr.resize(n)
	weather_type_arr.resize(n)
	weather_prev_type_arr.resize(n)
	weather_target_type_arr.resize(n)
	is_water_arr.resize(n)
	country_slot_arr.resize(n)
	resource_habitat_mask_arr.resize(n)
	climate_dirty_mask.resize(n)
	weather_dirty_mask.resize(n)
	# B-full Step-2：6 个新 SoA 字段一次性 resize
	weather_vapor_arr.resize(n)
	weather_convergence_arr.resize(n)
	weather_instability_arr.resize(n)
	weather_field_init_arr.resize(n)
	air_mass_temp_anomaly_arr.resize(n)
	has_river_arr.resize(n)
	river_flow_arr.resize(n)
	river_downstream_arr.resize(n)
	has_volcano_arr.resize(n)
	is_lake_seed_arr.resize(n)
	hydro_parent_arr.resize(n)
	river_discharge_arr.resize(n)
	river_discharge_30d_arr.resize(n)
	river_storage_arr.resize(n)
	groundwater_storage_arr.resize(n)
	surface_runoff_arr.resize(n)
	# Natural resources：per-cell 资源储量字段
	res_timber_reserve_arr.resize(n)
	res_stone_reserve_arr.resize(n)
	res_fertile_soil_reserve_arr.resize(n)
	res_coal_reserve_arr.resize(n)
	res_oil_reserve_arr.resize(n)
	res_natural_gas_reserve_arr.resize(n)
	res_copper_ore_reserve_arr.resize(n)
	res_iron_ore_reserve_arr.resize(n)
	res_gold_ore_reserve_arr.resize(n)
	res_silver_ore_reserve_arr.resize(n)
	res_salt_reserve_arr.resize(n)
	res_saltpeter_reserve_arr.resize(n)
	res_rare_earth_reserve_arr.resize(n)
	res_clay_reserve_arr.resize(n)
	res_wild_game_reserve_arr.resize(n)
	res_marine_fish_reserve_arr.resize(n)
	res_freshwater_fish_reserve_arr.resize(n)
	res_arable_land_reserve_arr.resize(n)
	res_paddy_land_reserve_arr.resize(n)
	res_plantation_land_reserve_arr.resize(n)
	res_pasture_reserve_arr.resize(n)
	res_bauxite_reserve_arr.resize(n)
	res_limestone_reserve_arr.resize(n)
	res_silica_sand_reserve_arr.resize(n)
	res_phosphate_rock_reserve_arr.resize(n)
	res_tin_ore_reserve_arr.resize(n)
	res_lead_ore_reserve_arr.resize(n)
	res_zinc_ore_reserve_arr.resize(n)
	res_manganese_ore_reserve_arr.resize(n)
	res_sulfur_reserve_arr.resize(n)
	res_flint_reserve_arr.resize(n)
	res_timber_extra_change_arr.resize(n)
	res_stone_extra_change_arr.resize(n)
	res_fertile_soil_extra_change_arr.resize(n)
	res_coal_extra_change_arr.resize(n)
	res_oil_extra_change_arr.resize(n)
	res_natural_gas_extra_change_arr.resize(n)
	res_copper_ore_extra_change_arr.resize(n)
	res_iron_ore_extra_change_arr.resize(n)
	res_gold_ore_extra_change_arr.resize(n)
	res_silver_ore_extra_change_arr.resize(n)
	res_salt_extra_change_arr.resize(n)
	res_saltpeter_extra_change_arr.resize(n)
	res_rare_earth_extra_change_arr.resize(n)
	res_clay_extra_change_arr.resize(n)
	res_wild_game_extra_change_arr.resize(n)
	res_marine_fish_extra_change_arr.resize(n)
	res_freshwater_fish_extra_change_arr.resize(n)
	res_arable_land_extra_change_arr.resize(n)
	res_paddy_land_extra_change_arr.resize(n)
	res_plantation_land_extra_change_arr.resize(n)
	res_pasture_extra_change_arr.resize(n)
	res_bauxite_extra_change_arr.resize(n)
	res_limestone_extra_change_arr.resize(n)
	res_silica_sand_extra_change_arr.resize(n)
	res_phosphate_rock_extra_change_arr.resize(n)
	res_tin_ore_extra_change_arr.resize(n)
	res_lead_ore_extra_change_arr.resize(n)
	res_zinc_ore_extra_change_arr.resize(n)
	res_manganese_ore_extra_change_arr.resize(n)
	res_sulfur_extra_change_arr.resize(n)
	res_flint_extra_change_arr.resize(n)
	# A 修复（climate-temp-pingpong-fix-2026-06）：anomaly 合成新增 2 个字段
	ocean_thermal_anomaly_arr.resize(n)
	local_thermal_anomaly_arr.resize(n)
	# Phase 3a Step 2.1.a：climate Pass-A SoA 化新增 2 个字段
	ema_initialized_arr.resize(n)
	temp_season_offset_arr.resize(n)
	insolation_now_arr.resize(n)
	insolation_dev_arr.resize(n)
	day_length_arr.resize(n)
	heat_input_arr.resize(n)
	thermal_energy_arr.resize(n)
	snowpack_arr.resize(n)
	water_balance_30d_arr.resize(n)
	# B3b：植被动力学字段全量下沉 SoA（4 f32 + 2 i32）
	vegetation_vitality_arr.resize(n)
	vitality_low_streak_arr.resize(n)
	vitality_high_streak_arr.resize(n)
	soil_moisture_arr.resize(n)
	vegetation_growth_pressure_arr.resize(n)
	temperature_transport_anomaly_arr.resize(n)
	vegetation_heat_stress_arr.resize(n)
	vegetation_drought_stress_arr.resize(n)
	vegetation_cold_stress_arr.resize(n)
	vegetation_regen_score_arr.resize(n)

## DEPRECATED（PR-2.2，2026-Q3）：本函数仅在 bake_world / 加载存档时调用一次（生成期初始化）。
## 运行期 sub-pass 已经全部走 world.write_*_indexed（PR-2.1.x 完成）。
## PR-2.3 HexCell facade 化完成后本函数可彻底删除，迁移到 _alloc_soa + 生成期一次性
## write_f32_indexed 全字段 push to world（master 手册 §3.10.3 替代方案）。
## 当前过渡期保留：HexCell 字段仍是强类型 var，bake 末仍需要从 cell.* 读取初值写入 SoA。
##
## 从 HexCell 强类型成员单向 sync 到 SoA。在 bake_world / 加载存档 / regenerate
## 路径调用一次。运行期 sub-pass 完成后不要再调用本函数（会盖掉 SoA 写入）。
##
## 任务 3（dots-completion）：本函数仅供 bake-time 使用；运行期 hot path 严禁调用。
## 推荐新代码使用 init_soa_from_bake()（语义更清晰的别名），旧调用点保留向后兼容。
func rebuild_soa_from_cells() -> void:
	# 任务 3：bake-time-only guard。如果 _soa_built 已为 true 且不在 bake 路径，
	# debug build 下 push_warning 提示误用（运行期重建会盖掉 sub-pass 写入的 SoA）。
	if _soa_built and OS.is_debug_build():
		push_warning("[map_data] rebuild_soa_from_cells called when SoA already built; this is bake-time only. Prefer init_soa_from_bake() in new code.")
	if not _indices_built:
		_build_indices()
	var n: int = _cell_array.size()
	var hydro_parent_seed: PackedInt32Array = hydro_parent_arr.duplicate()
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
		weather_cloud_water_arr[i] = c.weather_cloud * 0.5 if c.weather_field_initialized else 0.0
		weather_precip_arr[i] = c.weather_precip
		weather_transition_alpha_arr[i] = c.weather_transition_alpha
		weather_classification_temp_arr[i] = c.temperature
		weather_classification_moisture_arr[i] = c.moisture
		elevation_arr[i] = c.elevation
		base_moisture_arr[i] = c.base_moisture
		ocean_current_x_arr[i] = c.ocean_current.x
		ocean_current_y_arr[i] = c.ocean_current.y
		wind_x_arr[i] = c.wind_vector.x
		wind_y_arr[i] = c.wind_vector.y
		slp_arr[i] = c.slp
		wind_speed_arr[i] = c.wind_speed
		upwelling_strength_arr[i] = c.upwelling_strength
		wind_stress_curl_arr[i] = c.wind_stress_curl
		ocean_psi_arr[i] = c.ocean_psi
		var wp: Vector2 = HexUtils.cube_to_world(c.q, c.r, 1.0)
		cell_pos_x_arr[i] = wp.x
		cell_pos_y_arr[i] = wp.y
		terrain_arr[i] = int(c.terrain) & 0xFF
		landform_arr[i] = c.landform & 0xFF
		vegetation_arr[i] = c.vegetation & 0xFF
		base_terrain_arr[i] = int(c.base_terrain) & 0xFF
		base_landform_arr[i] = c.base_landform & 0xFF
		base_vegetation_arr[i] = c.base_vegetation & 0xFF
		cover_arr[i] = c.cover & 0xFF
		weather_type_arr[i] = c.weather_type & 0xFF
		weather_prev_type_arr[i] = c.weather_prev_type & 0xFF
		weather_target_type_arr[i] = c.weather_target_type & 0xFF
		is_water_arr[i] = MapData.terrain_is_water_u8(int(terrain_arr[i]))
		country_slot_arr[i] = -1
		climate_dirty_mask[i] = 0
		weather_dirty_mask[i] = 0
		# B-full Step-2：6 个新字段 AoS → SoA 一次性镜像
		weather_vapor_arr[i] = c.weather_vapor
		weather_convergence_arr[i] = c.weather_convergence
		weather_instability_arr[i] = c.weather_instability
		weather_field_init_arr[i] = (1 if c.weather_field_initialized else 0)
		air_mass_temp_anomaly_arr[i] = c.air_mass_temp_anomaly
		has_river_arr[i] = (1 if c.has_river else 0)
		river_flow_arr[i] = c.river_flow
		has_volcano_arr[i] = (1 if c.has_volcano else 0)
		is_lake_seed_arr[i] = (1 if c.is_lake_seed else 0)
		var downstream_idx: int = -1
		if c.has_river_downstream:
			var downstream_cell: HexCell = get_cell_by_cube(c.river_downstream)
			downstream_idx = int(_cell_index.get(downstream_cell, -1)) if downstream_cell != null else -1
		river_downstream_arr[i] = downstream_idx
		var hydro_parent_idx: int = int(hydro_parent_seed[i]) if hydro_parent_seed.size() == n else -1
		hydro_parent_arr[i] = hydro_parent_idx if hydro_parent_idx >= -1 and hydro_parent_idx < n else -1
		river_discharge_arr[i] = maxf(0.0, river_flow_arr[i] if has_river_arr[i] != 0 else 0.0)
		river_discharge_30d_arr[i] = river_discharge_arr[i]
		river_storage_arr[i] = 0.0
		groundwater_storage_arr[i] = 0.0
		surface_runoff_arr[i] = 0.0
		# Phase 3a Step 2.1.a：Pass-A SoA 化新增 2 个字段镜像
		ema_initialized_arr[i] = (1 if c._ema_initialized else 0)
		temp_season_offset_arr[i] = c.temp_season_offset
		insolation_now_arr[i] = 0.0
		insolation_dev_arr[i] = 0.0
		day_length_arr[i] = 0.5
		heat_input_arr[i] = 0.0
		thermal_energy_arr[i] = c.temperature
		snowpack_arr[i] = 0.8 if c.cover == CoverType.CV.GLACIER else clampf(c.snow_cover * 0.35, 0.0, 1.0)
		water_balance_30d_arr[i] = 0.0
		# B3b：植被动力学字段全量下沉 SoA — bake 期一次性从 HexCell 镜像初值
		var has_live_vegetation: bool = is_water_arr[i] == 0 and int(c.vegetation) != int(VegetationType.VEG.NONE)
		vegetation_vitality_arr[i] = c.vegetation_vitality if has_live_vegetation else 0.0
		vitality_low_streak_arr[i] = c._vitality_low_streak if has_live_vegetation else 0
		vitality_high_streak_arr[i] = c._vitality_high_streak if has_live_vegetation else 0
		soil_moisture_arr[i] = c.soil_moisture
		vegetation_growth_pressure_arr[i] = c.vegetation_growth_pressure if has_live_vegetation else 0.0
		temperature_transport_anomaly_arr[i] = c.temperature_transport_anomaly
		vegetation_heat_stress_arr[i] = c.vegetation_heat_stress if has_live_vegetation else 0.0
		vegetation_drought_stress_arr[i] = c.vegetation_drought_stress if has_live_vegetation else 0.0
		vegetation_cold_stress_arr[i] = c.vegetation_cold_stress if has_live_vegetation else 0.0
		vegetation_regen_score_arr[i] = c.vegetation_regen_score if has_live_vegetation else 0.0
	# A 修复（climate-temp-pingpong-fix-2026-06）：anomaly 合成字段无 HexCell 镜像，
	# 全图 fill 为 0（resize 已经填 0，这里显式 fill 防止后续手动 resize 残值）。
	# Natural resources 储量同类（无 HexCell 镜像）：bake 时置 0，初值由
	# _bootstrap_natural_resource_deposits 在 init_soa_from_bake 之后覆盖。
	for i in range(n):
		ocean_thermal_anomaly_arr[i] = 0.0
		local_thermal_anomaly_arr[i] = 0.0
		res_timber_reserve_arr[i] = 0.0
		res_stone_reserve_arr[i] = 0.0
		res_fertile_soil_reserve_arr[i] = 0.0
		res_coal_reserve_arr[i] = 0.0
		res_oil_reserve_arr[i] = 0.0
		res_natural_gas_reserve_arr[i] = 0.0
		res_copper_ore_reserve_arr[i] = 0.0
		res_iron_ore_reserve_arr[i] = 0.0
		res_gold_ore_reserve_arr[i] = 0.0
		res_silver_ore_reserve_arr[i] = 0.0
		res_salt_reserve_arr[i] = 0.0
		res_saltpeter_reserve_arr[i] = 0.0
		res_rare_earth_reserve_arr[i] = 0.0
		res_clay_reserve_arr[i] = 0.0
		res_wild_game_reserve_arr[i] = 0.0
		res_marine_fish_reserve_arr[i] = 0.0
		res_freshwater_fish_reserve_arr[i] = 0.0
		res_arable_land_reserve_arr[i] = 0.0
		res_paddy_land_reserve_arr[i] = 0.0
		res_plantation_land_reserve_arr[i] = 0.0
		res_pasture_reserve_arr[i] = 0.0
		res_bauxite_reserve_arr[i] = 0.0
		res_limestone_reserve_arr[i] = 0.0
		res_silica_sand_reserve_arr[i] = 0.0
		res_phosphate_rock_reserve_arr[i] = 0.0
		res_tin_ore_reserve_arr[i] = 0.0
		res_lead_ore_reserve_arr[i] = 0.0
		res_zinc_ore_reserve_arr[i] = 0.0
		res_manganese_ore_reserve_arr[i] = 0.0
		res_sulfur_reserve_arr[i] = 0.0
		res_flint_reserve_arr[i] = 0.0
		res_timber_extra_change_arr[i] = 0.0
		res_stone_extra_change_arr[i] = 0.0
		res_fertile_soil_extra_change_arr[i] = 0.0
		res_coal_extra_change_arr[i] = 0.0
		res_oil_extra_change_arr[i] = 0.0
		res_natural_gas_extra_change_arr[i] = 0.0
		res_copper_ore_extra_change_arr[i] = 0.0
		res_iron_ore_extra_change_arr[i] = 0.0
		res_gold_ore_extra_change_arr[i] = 0.0
		res_silver_ore_extra_change_arr[i] = 0.0
		res_salt_extra_change_arr[i] = 0.0
		res_saltpeter_extra_change_arr[i] = 0.0
		res_rare_earth_extra_change_arr[i] = 0.0
		res_clay_extra_change_arr[i] = 0.0
		res_wild_game_extra_change_arr[i] = 0.0
		res_marine_fish_extra_change_arr[i] = 0.0
		res_freshwater_fish_extra_change_arr[i] = 0.0
		res_arable_land_extra_change_arr[i] = 0.0
		res_paddy_land_extra_change_arr[i] = 0.0
		res_plantation_land_extra_change_arr[i] = 0.0
		res_pasture_extra_change_arr[i] = 0.0
		resource_habitat_mask_arr[i] = 0
		res_bauxite_extra_change_arr[i] = 0.0
		res_limestone_extra_change_arr[i] = 0.0
		res_silica_sand_extra_change_arr[i] = 0.0
		res_phosphate_rock_extra_change_arr[i] = 0.0
		res_tin_ore_extra_change_arr[i] = 0.0
		res_lead_ore_extra_change_arr[i] = 0.0
		res_zinc_ore_extra_change_arr[i] = 0.0
		res_manganese_ore_extra_change_arr[i] = 0.0
		res_sulfur_extra_change_arr[i] = 0.0
		res_flint_extra_change_arr[i] = 0.0
	# 同步初始化 _prev 双缓冲为 _next 当前快照，避免首日 sub-pass 切片读到 0。
	temp_arr_prev = temp_arr.duplicate()
	moisture_arr_prev = moisture_arr.duplicate()
	snow_cover_arr_prev = snow_cover_arr.duplicate()
	sea_ice_frac_arr_prev = sea_ice_frac_arr.duplicate()
	_soa_built = true
	# B1-A：lat / temp_year LUT 必须由 generator 在 _last_cfg 就位后 bake；
	# 这里仅置为未 bake 状态，bake_world 路径会立即调用 bake_lat_temp_year_lut()。
	_lat_lut_baked = false


## 任务 3（dots-completion）：bake-time SoA 初始化的语义化别名。
## 等价于 rebuild_soa_from_cells()，但函数名更清晰地表明"仅 bake 时调用"。
## 新代码统一使用本名；旧 caller 保留 rebuild_soa_from_cells() 直到全部迁移完成。
func init_soa_from_bake() -> void:
	rebuild_soa_from_cells()


## REMOVED PR-2.4 (2026-05-14)：flush_soa_to_cells() 已删除。
##
## 历史背景：本函数曾用于"round 末把 SoA 反向同步给 HexCell 强类型成员"，
## 让 UI / Baker / 旧 GDScript pass 直接读 cell.<field> 拿到最新值。
## PR-2.3b HexCell facade 完成后，cell.<field> getter 直接走 SoA read_f32，
## 反向同步不再必要——本函数因此被删除。
## git history: scripts/geography/map_data.gd flush_soa_to_cells (line 389-424).

## B1-A：一次性烘焙 cell 归一化纬度 + 年均温度 LUT。
## 必须在 rebuild_soa_from_cells() 完成 + MapGenerator._last_cfg 就位之后调用。
## generator 参数提供 _cube_row_norm / _compute_temperature 数值的权威来源——
## 我们直接借用其私有方法保证与 legacy 1:1 对齐（避免在 MapData 重复实现）。
## 重复调用是安全的；运行期不再变化。
##
## cpp-dots（temp-baseline-authority-2026-06）：cell_lat_norm 是几何量（依赖
## cube_row_norm），始终由 GDScript 烤；temp_baseline_year 是 lat_temp_bell(lat_norm)
## 的纯仿真量——其【权威计算】已上交 C++ run_temp_baseline_year_bake（pk_lat_temp_bell），
## 由 map_generator._bake_temp_baseline_year_native 在 DCWorldExt bind 后调用并 flush 回本数组。
## 本函数里的 temp_baseline_year 循环仅作 GDScript fallback（ext 未编译 / 未 bind 时兜底）。
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
		# fallback only：权威值由 C++ run_temp_baseline_year_bake 写入（见函数顶部注释）。
		# 公式统一走 DCClimateMath.lat_temp_bell（全工程单一来源），与 C++ pk_lat_temp_bell 同源。
		var lat_temp: float = DCClimateMath.lat_temp_bell_from_ny(ny)
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

## 每日 climate round 开始前冻结上一个 committed 快照。weather/recorder/visual
## 插值可以读 *_prev，避免切片期间看到一半旧值、一半新值。
func soa_begin_climate_transaction() -> void:
	soa_swap_double_buffer()
	# Weather classification must observe the same committed snapshot as the
	# climate transaction.  Native-daily ACTIVE does not enter FieldSolver's
	# legacy begin-slice hook, so leaving these arrays there made biome/weather
	# classification read a map-generation-era value indefinitely.
	if weather_classification_temp_arr.size() == temp_arr_prev.size():
		weather_classification_temp_arr = temp_arr_prev.duplicate()
	if weather_classification_moisture_arr.size() == moisture_arr_prev.size():
		weather_classification_moisture_arr = moisture_arr_prev.duplicate()

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
