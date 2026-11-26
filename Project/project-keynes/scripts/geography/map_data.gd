# map_data.gd
# 地图数据容器
# 存储所有 HexCell，以 Vector3i(q, r, s) 为键的 Dictionary

class_name MapData
const TerrainColumns = preload("res://scripts/geography/map_data_terrain_columns.gd")
const BakeArrays = preload("res://scripts/geography/map_data_bake_arrays.gd")
const MapLatitudeBake = preload("res://scripts/geography/map_latitude_bake.gd")
const Queries = preload("res://scripts/geography/map_data_queries.gd")

## Presentation input publication, after the authoritative arrays have landed.
## Empty cells means a whole-map publication, not "no changes". Consumers queue
## work here and sample on their next frame, after the publishing batch returns.
signal resource_visual_inputs_changed(flags: int, cells: PackedInt32Array)
const RESOURCE_VISUAL_BANDS := 1
const RESOURCE_VISUAL_CLIMATE := 2
const RESOURCE_VISUAL_GEOMETRY := 4

func publish_resource_visual_inputs(flags: int,
		cells: PackedInt32Array = PackedInt32Array()) -> void:
	resource_visual_inputs_changed.emit(flags, cells)

var width:  int = 0
var height: int = 0

# 主存储：cube 坐标 → HexCell
var _cells: Dictionary = {}

# ─── Daily-Sim SoA Refactor 阶段 2：邻居索引 SoA ──────────────────────
# 由 _build_indices() 一次性预计算（在 MapGenerator.generate 完成所有 cell
# 入库 + terrain 定型后调用）。fast-tick 热路径（_apply_sea_ice_daily_pass /
# ocean water/land native dispatch / climate Pass-B native dispatch）
# 通过这些索引避开每帧创建 6-元 Array 的 GC 压力。
#
# 不变量：
#   - _cell_array.size() == _cells.size() == _cell_index.size()
#   - _neighbor_indices.size() == _cell_array.size() * 6
#   - _neighbor_indices[i*6 + dir] == -1 表示该方向没有邻居（地图边缘）
#   - 顺序与 HexUtils.CUBE_DIRECTIONS 一致：0=E, 1=NE, 2=NW, 3=W, 4=SW, 5=SE
var _cell_array: Array[HexCell] = []
var _cell_index: Dictionary = {}            # HexCell → int (idx)
var _neighbor_indices: PackedInt32Array = PackedInt32Array()
var _indices_built: bool = false
var cell_index_revision: int = 0            # Display LUTs are addressed by cell index.

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
## 运河是持久格边设施；低六位方向与 neighbor_indices 的六方向一致。
var canal_edge_mask_arr:       PackedByteArray    = PackedByteArray()
var canal_water_arr:           PackedFloat32Array = PackedFloat32Array()

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
# 保留"slot → HexCell 回灌"兼容 baker/UI 读取点。
var vegetation_vitality_arr:           PackedFloat32Array = PackedFloat32Array()
var vitality_low_streak_arr:           PackedInt32Array   = PackedInt32Array()
var vitality_high_streak_arr:          PackedInt32Array   = PackedInt32Array()
var soil_moisture_arr:                 PackedFloat32Array = PackedFloat32Array()
var plant_available_water_arr:          PackedFloat32Array = PackedFloat32Array()
## Native generation ecology bundle is applied after init_soa_from_bake(),
## because the generic AoS->SoA bootstrap intentionally zeroes slow buffers.
var _pending_generation_ecology: Dictionary = {}
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
var published_biome_history := PackedByteArray()
var published_vegetation_history := PackedByteArray()
var _season_history_missing_warning_keys: Dictionary = {}
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
# ─── 视野迷雾（owner = VisionSolver）────────────────────────────────────
# visible  : 当前是否在玩家国家视野内（0/1）。每次领土变更重算，不持久化。
# explored : 是否曾经进入过视野（0/1）。单调累积，是玩家进度，进 PKSV 的 PKFG。
# fog_k    : 由上面两个位做 hex 邻域 blur 得到的「知识度」0..255，供 enum_lut.a
#            与迷雾层消费。纯派生量，不进 component schema、不存档。
#            0 = 未探索，128 ≈ 已探索未可见，255 = 完全可见。
var visible_arr:            PackedByteArray = PackedByteArray()
# 玩家国家的真实视野（0/1），由视野解算写入。模拟（贸易门控、投资、殖民）只读
# 这一份；visible_arr 是画面视野，关战争迷雾时会被写成全可见，不能进模拟。
var physical_visible_arr:   PackedByteArray = PackedByteArray()
## Monotonic transient revision for player-visible route quote invalidation.
## It is intentionally excluded from world save authority and rebuilt by VisionSolver.
var vision_revision: int = 0
var explored_arr:           PackedByteArray = PackedByteArray()
var fog_k_arr:              PackedByteArray = PackedByteArray()
# 上面三个数组是否已被 VisionSolver 解算过。数组大小不能当这个判据用——
# init_soa_from_bake 会把它们分配成全 0，那与"全图未探索"字节上无法区分。
# 消费者（enum_lut.a）在解算前必须按全知处理，否则首帧全图会是黑的。
# 纯运行期状态，不进存档：恢复后由 refresh_country_visuals 重解算。
var fog_solved: bool = false
var resource_habitat_mask_arr: PackedByteArray = PackedByteArray()

## Generation-only static research evidence. These arrays are not DataCore slots:
## they describe immutable world facts, while countries own discovery knowledge.
var generation_vegetation_arr: PackedByteArray = PackedByteArray()
var cell_biogeographic_realm_arr: PackedByteArray = PackedByteArray()
var cell_research_signal_offsets: PackedInt32Array = PackedInt32Array()
var cell_research_signal_ids: PackedInt32Array = PackedInt32Array()
var cell_research_signal_values: PackedInt32Array = PackedInt32Array()
## Current species presence (Kind.BIO occupancy bitset). Persisted with dynamic_world.
var bio_occupancy_bits_arr: PackedInt32Array = PackedInt32Array()
var landmass_id_arr: PackedInt32Array = PackedInt32Array()
var province_id_arr: PackedInt32Array = PackedInt32Array()

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

## Rebuild after all cells are present, preserving their insertion order.
func _build_indices() -> void:
	_cell_array.assign(_cells.values())
	_cell_index.clear()
	var n := _cell_array.size()
	_neighbor_indices.resize(n * 6)
	for i in n:
		var cell: HexCell = _cell_array[i]
		_cell_index[cell] = i
		cell.index = i
	_build_neighbor_indices(0,n)
	_indices_built = true
	cell_index_revision += 1


func _build_neighbor_indices(begin: int, end: int) -> void:
	var dirs: Array = HexUtils.CUBE_DIRECTIONS
	for j in range(begin,end):
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

## Generated neighbors must already use this map's insertion order and six direction slots.
func build_indices_cooperative(frame_gate = null,
		generated_neighbors: PackedInt32Array = PackedInt32Array()) -> void:
	if _indices_built:
		return
	_cell_array.assign(_cells.values())
	_cell_index.clear()
	var n := _cell_array.size()
	var tree := Engine.get_main_loop() as SceneTree
	var start := Time.get_ticks_usec()
	for i in n:
		var cell: HexCell = _cell_array[i]
		_cell_index[cell] = i
		cell.index = i
		if tree != null and Time.get_ticks_usec()-start >= UITokens.LOADING_MAIN_SLICE_USEC:
			await (frame_gate.next_frame() if frame_gate != null else tree.process_frame)
			if frame_gate != null and frame_gate.canceled:
				return
			start = Time.get_ticks_usec()
	if generated_neighbors.size() == n * 6:
		_neighbor_indices = generated_neighbors
	else:
		_neighbor_indices.resize(n*6)
		for begin in range(0,n,16):
			_build_neighbor_indices(begin,mini(begin+16,n))
			if tree != null and Time.get_ticks_usec()-start >= UITokens.LOADING_MAIN_SLICE_USEC:
				await (frame_gate.next_frame() if frame_gate != null else tree.process_frame)
				if frame_gate != null and frame_gate.canceled:
					return
				start = Time.get_ticks_usec()
	_indices_built = true
	cell_index_revision += 1

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

func season_history_for(cell: HexCell, vegetation: bool) -> PackedByteArray:
	var history := published_vegetation_history if vegetation else published_biome_history
	var start := cell.index * HexCell.HISTORY_LEN
	if start >= 0 and start + HexCell.HISTORY_LEN <= history.size():
		_season_history_missing_warning_keys.erase(_season_history_warning_key(vegetation))
		return history.slice(start, start + HexCell.HISTORY_LEN)
	var warning_key := _season_history_warning_key(vegetation)
	if not _season_history_missing_warning_keys.has(warning_key):
		_season_history_missing_warning_keys[warning_key] = true
		push_warning("MapData season history publication is incomplete: %s history has %d bytes; cell %d needs bytes %d..%d" % [
			"vegetation" if vegetation else "biome", history.size(), cell.index,
			start, start + HexCell.HISTORY_LEN - 1,
		])
	return PackedByteArray()

func _season_history_warning_key(vegetation: bool) -> String:
	return "vegetation" if vegetation else "biome"

func sync_is_water_arr_from_terrain() -> void:
	TerrainColumns.sync_is_water_arr_from_terrain(self)

func sync_runtime_terrain_facade_from_soa() -> int:
	return TerrainColumns.sync_runtime_terrain_facade_from_soa(self)

func set_runtime_terrain(idx: int, terrain_id: int, sync_cell: bool = true) -> void:
	TerrainColumns.set_runtime_terrain(self, idx, terrain_id, sync_cell)

## 一次性按 _cell_array.size() 预分配所有 SoA 数组与 dirty mask。重复调用是安全的。
func _alloc_soa(n: int) -> void:
	BakeArrays._alloc_soa(self, n)

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
	if not _indices_built:
		_build_indices()
	var seed := _prepare_bake_soa()
	_copy_bake_cells(0,_cell_array.size(),seed)
	_finish_bake_soa()

func _prepare_bake_soa() -> PackedInt32Array:
	return BakeArrays._prepare_bake_soa(self)

func _copy_bake_cells(begin: int, end: int, hydro_parent_seed: PackedInt32Array) -> void:
	BakeArrays._copy_bake_cells(self, begin, end, hydro_parent_seed)

func _finish_bake_soa() -> void:
	BakeArrays._finish_bake_soa(self)

func init_soa_from_bake_cooperative(frame_gate = null) -> void:
	await build_indices_cooperative(frame_gate)
	if frame_gate != null and frame_gate.canceled:
		return
	var seed := _prepare_bake_soa()
	var n := _cell_array.size()
	var tree := Engine.get_main_loop() as SceneTree
	var start := Time.get_ticks_usec()
	for begin in range(0,n,8):
		_copy_bake_cells(begin,mini(begin+8,n),seed)
		if tree != null and Time.get_ticks_usec()-start >= UITokens.LOADING_MAIN_SLICE_USEC:
			await (frame_gate.next_frame() if frame_gate != null else tree.process_frame)
			if frame_gate != null and frame_gate.canceled:
				return
			start = Time.get_ticks_usec()
	_finish_bake_soa()
	apply_pending_generation_ecology()


## 任务 3（dots-completion）：bake-time SoA 初始化的语义化别名。
## 等价于 rebuild_soa_from_cells()，但函数名更清晰地表明"仅 bake 时调用"。
## 新代码统一使用本名；旧 caller 保留 rebuild_soa_from_cells() 直到全部迁移完成。
func init_soa_from_bake() -> void:
	rebuild_soa_from_cells()
	apply_pending_generation_ecology()


func set_pending_generation_ecology(bundle: Dictionary) -> void:
	_pending_generation_ecology = bundle.duplicate(true)


func apply_pending_generation_ecology() -> void:
	BakeArrays.apply_pending_generation_ecology(self)


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
	MapLatitudeBake.bake_lat_temp_year_lut(self, generator)

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

func mark_climate_dirty_indexed(indices: PackedInt32Array) -> void:
	var n: int = climate_dirty_mask.size()
	for idx in indices:
		if idx >= 0 and idx < n:
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

## Read-only queries preserve MapData's public interface.
func terrain_stats() -> Dictionary:
	return Queries.terrain_stats(_cells)

func sample_slow_layer(qr: Vector3i, fields: Array) -> Dictionary:
	return Queries.sample_slow_layer(_cells, qr, fields)
