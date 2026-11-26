extends RefCounted

## Applies front-driven convergence and reads published front and terrain properties.

static func _apply_frontal_convergence_boost(weather: WeatherSystem, map: MapData, cells: Array, climate_anomaly: float, neighbor_indices: PackedInt32Array, fast_indexed: bool) -> void:
	# 锋面强度由净流入和归一化温差共同决定。
	const STORM_TEMP_DIFF: float = 0.28
	const CONVERGENCE_THRESHOLD: float = 0.64  # W3: net 口径 p95=0.636（旧 0.45 按 legacy p50=0.376 标定）
	# B-full Step-2：循环外一次性取 SoA 数组引用（与 view_f32 同引用）。
	# cell-level 字段全部走 PackedArray index 访问；只有 _avg_ocean_anomaly_at_idx
	# 内部读 temperature_transport_anomaly 仍走 AoS（不在本 plan 范围）。
	var soa_temp: PackedFloat32Array = map.temp_arr
	var soa_air_anomaly: PackedFloat32Array = map.air_mass_temp_anomaly_arr
	var soa_field_init: PackedByteArray = map.weather_field_init_arr
	var soa_convergence: PackedFloat32Array = map.weather_convergence_arr
	var soa_cloud: PackedFloat32Array = map.weather_cloud_arr
	var soa_cloud_water: PackedFloat32Array = map.weather_cloud_water_arr
	var soa_precip: PackedFloat32Array = map.weather_precip_arr
	var soa_instability: PackedFloat32Array = map.weather_instability_arr
	var soa_vapor: PackedFloat32Array = map.weather_vapor_arr
	var soa_type: PackedByteArray = map.weather_type_arr
	var soa_intensity: PackedFloat32Array = map.weather_intensity_arr
	# PR-2.1.6（frontal convergence boost 写路径下移）：dirty 收集。
	var _fb_idx: PackedInt32Array = PackedInt32Array()
	var _fb_cloud: PackedFloat32Array = PackedFloat32Array()
	var _fb_precip: PackedFloat32Array = PackedFloat32Array()
	var _fb_inst: PackedFloat32Array = PackedFloat32Array()
	var _fb_intensity: PackedFloat32Array = PackedFloat32Array()
	var _fb_type: PackedByteArray = PackedByteArray()
	var _fb_w: int = 0

	for i in range(cells.size()):
		var cell: HexCell = cells[i]
		if soa_field_init[i] == 0:
			continue
		var conv: float = soa_convergence[i]
		if conv < CONVERGENCE_THRESHOLD:
			continue
		# 计算 cell 邻域的温差 max - min（含 cell 自身）。
		var t_self: float = clampf(soa_temp[i] + climate_anomaly + soa_air_anomaly[i], 0.0, 1.0)
		var t_min: float = t_self
		var t_max: float = t_self
		if fast_indexed:
			var base: int = i * 6
			for d in range(6):
				var nb_idx: int = neighbor_indices[base + d]
				if nb_idx < 0:
					continue
				var t_nb: float = clampf(soa_temp[nb_idx] + climate_anomaly + soa_air_anomaly[nb_idx], 0.0, 1.0)
				if t_nb < t_min:
					t_min = t_nb
				if t_nb > t_max:
					t_max = t_nb
		else:
			for nb: HexCell in weather._cell_neighbors(cell, map):
				if nb == null:
					continue
				var t_nb: float = clampf(nb.temperature + climate_anomaly + nb.air_mass_temp_anomaly, 0.0, 1.0)
				if t_nb < t_min:
					t_min = t_nb
				if t_nb > t_max:
					t_max = t_nb
		var temp_diff: float = t_max - t_min
		# frontal_score：辐合强度 × 温差强度（温差 0.20 时为 1.0）。
		var frontal_score: float = clampf(
			(conv - CONVERGENCE_THRESHOLD) / (1.0 - CONVERGENCE_THRESHOLD)
			* clampf(temp_diff / STORM_TEMP_DIFF, 0.0, 1.0),
			0.0, 1.0
		)
		if frontal_score < 0.45:
			continue
		var cloud1 := clampf(maxf(soa_cloud[i], 0.25 + frontal_score * 0.20), 0.0, 1.0)
		var vapor1: float = soa_vapor[i]
		var precip1: float = soa_precip[i]
		var inst1 := clampf(maxf(soa_instability[i], 0.25 + frontal_score * 0.15), 0.0, 1.0)
		var new_wt: int = soa_type[i]
		var boosted_precip := clampf(maxf(precip1, 0.05 + frontal_score * 0.12), 0.0, 1.0)
		if weather._feedback.meets_precipitation_gate(weather, vapor1, cloud1,
				soa_cloud_water[i], boosted_precip, weather._is_water_terrain(int(cell.terrain))):
			precip1 = boosted_precip
			if not weather._is_precip_weather_type(new_wt):
				new_wt = WeatherType.WT.RAIN
		# AoS 镜像写回（兼容 renderer 在 round 内未 flush 时直读 HexCell 字段）。
		cell.weather_cloud = cloud1
		cell.weather_instability = inst1
		var ocean_an: float = weather._avg_ocean_anomaly_at_idx(i, cells, neighbor_indices) if fast_indexed else weather._avg_ocean_anomaly_at(cell, map)
		cell.weather_type = new_wt
		cell.weather_precip = precip1
		# 重算 intensity（沿用同套公式，确保下游可视化一致）。
		var new_intensity: float = weather._field_intensity_for_type(new_wt, t_self, vapor1, cloud1, precip1, inst1, ocean_an)
		cell.weather_intensity = new_intensity
		# B-full Step-2：SoA 镜像（与 view_f32 同引用）—— 所有被本 pass 修改的字段都写出
		soa_cloud[i] = cloud1
		soa_precip[i] = precip1
		soa_instability[i] = inst1
		soa_intensity[i] = new_intensity
		soa_type[i] = new_wt & 0xFF
		# PR-2.1.6：收集 dirty entry。
		_fb_idx.append(i)
		_fb_cloud.append(cloud1)
		_fb_precip.append(precip1)
		_fb_inst.append(inst1)
		_fb_intensity.append(new_intensity)
		_fb_type.append(new_wt & 0xFF)
		_fb_w += 1

	# PR-2.1.6（frontal convergence boost 写路径下移）：循环结束后批量提交到 DCWorld SoA。
	if weather._data_core_world != null and _fb_w > 0:
		var _cid_fbc: int = weather._data_core_world.component_id(DCComponentIds.CELL_WEATHER_CLOUD)
		if _cid_fbc >= 0:
			weather._data_core_world.write_f32_indexed(_cid_fbc, _fb_idx, _fb_cloud)
		var _cid_fbp: int = weather._data_core_world.component_id(DCComponentIds.CELL_WEATHER_PRECIP)
		if _cid_fbp >= 0:
			weather._data_core_world.write_f32_indexed(_cid_fbp, _fb_idx, _fb_precip)
		var _cid_fbi: int = weather._data_core_world.component_id(DCComponentIds.CELL_WEATHER_INSTABILITY)
		if _cid_fbi >= 0:
			weather._data_core_world.write_f32_indexed(_cid_fbi, _fb_idx, _fb_inst)
		var _cid_fbI: int = weather._data_core_world.component_id(DCComponentIds.CELL_WEATHER_INTENSITY)
		if _cid_fbI >= 0:
			weather._data_core_world.write_f32_indexed(_cid_fbI, _fb_idx, _fb_intensity)
		var _cid_fbt: int = weather._data_core_world.component_id(DCComponentIds.CELL_WEATHER_TYPE)
		if _cid_fbt >= 0:
			weather._data_core_world.write_u8_indexed(_cid_fbt, _fb_idx, _fb_type)
		# [DIAG mask_dirty=2400 排查 · 2026-05-20] 前 5 次 + 之后每 50 次打一次
		weather._diag_fb_commit_count += 1
		if weather._diag_fb_commit_count <= 5 or (weather._diag_fb_commit_count % 50) == 0:
			print("[DIAG weather_fb_commit] #%d wrote %d cells (cloud+precip+inst+intensity+type)" % [weather._diag_fb_commit_count, _fb_w])
# Phase 3c：积雪累积与融化（共享方法）
# ------------------------------------------------------------------------
# 目的：把"BLIZZARD/SNOW 一发生立刻 cover=SNOW"换成累积式累计 + 温升融化。
# 字段约定（hex_cell.gd 已新增）：
#   accumulated_snow_days: int  —— 当前连续可降雪天数，>=SNOW_ACCUM_DAYS 时落地为 SNOW
#   pre_snow_cover: int         —— 备份覆盖前的 cover；融化时恢复（-1 表示未备份）
# 写入策略：
#   1) 可降雪条件（can_form_snow 且 temp<冰点 且 intensity>0.4）→ accumulated_snow_days += 1
#   2) 否则若 temp 高于解冻阈值 → accumulated_snow_days -= 1（不再降雪即缓慢消融）
#   3) 累计达阈值且当前不是 SNOW → 备份原 cover，写 cover=SNOW
#   4) 累计回零且当前是 SNOW 且有备份 → 恢复 cover=pre_snow_cover


static func _prev_vapor_cached(weather: WeatherSystem, cell: HexCell, map: MapData, prev_vapor: PackedFloat32Array) -> float:
	return weather.WeatherDiagnostics.prev_vapor_cached(weather, cell, map, prev_vapor)

# dots-monolith-split §1.2 / PR-1：搬迁到 field_solver.gd（薄转发）。


static func _vegetation_transpiration_factor(weather: WeatherSystem, cell: HexCell) -> float:
	var veg: int = int(cell.vegetation)
	if veg == VegetationType.VEG.NONE:
		return 0.0
	if veg == VegetationType.VEG.TROPICAL_RAINFOREST or veg == VegetationType.VEG.SWAMP or veg == VegetationType.VEG.MANGROVE:
		return 1.0
	if veg == VegetationType.VEG.TEMPERATE_DECIDUOUS or veg == VegetationType.VEG.TAIGA or veg == VegetationType.VEG.SUBTROPICAL_FOREST:
		return 0.65
	if veg == VegetationType.VEG.TEMPERATE_GRASSLAND or veg == VegetationType.VEG.SAVANNA or veg == VegetationType.VEG.MARSH:
		return 0.35
	return 0.18

# dots-monolith-split §1.2 / PR-2：搬迁到 field_solver.gd（薄转发）。


static func has_cover_dirty(weather: WeatherSystem) -> bool:
	return weather._cover_dirty

# --- 查询接口（给 UI / 其他子系统） ---
# 返回 { "type": int(WT), "intensity": float [0,1] }；max-merge：取覆盖到该点的最强 front。


static func query_at(weather: WeatherSystem, world_pos: Vector2) -> Dictionary:
	if weather._weather_field_enabled:
		var map_ref: MapData = weather._current_map_for_tick if weather._current_map_for_tick != null else weather._last_map_for_query
		if map_ref != null:
			var cube := HexUtils.world_to_cube(world_pos, weather._hex_size)
			var cell: HexCell = map_ref.get_cell_by_cube(cube)
			if cell != null and cell.weather_field_initialized:
				return {
					"type": cell.weather_type,
					"intensity": cell.weather_intensity,
					"cloud": cell.weather_cloud,
					"precip": cell.weather_precip,
					"vapor": cell.weather_vapor,
					"instability": cell.weather_instability,
				}
	var best_type: int = WeatherType.WT.CLEAR
	var best_intensity: float = 0.0
	for front in weather._active_fronts:
		var c: float = front.coverage_at(world_pos)
		if c > best_intensity:
			best_intensity = c
			best_type = front.type
	return {"type": best_type, "intensity": best_intensity}

# --- shader uniform 打包 ---
# 返回 { "centers": Array[Vector4(cx, cy, radius, intensity)], "types": Array[int], "count": int }
# 由 HexRenderer.set_weather_fronts 取用，组装成 shader uniform 数组。


static func pack_to_uniforms(weather: WeatherSystem) -> Dictionary:
	var centers: Array = []
	var types: Array = []
	var shapes: Array = []
	var visuals: Array = []
	for front in weather._active_fronts:
		centers.append(Vector4(front.center.x, front.center.y, front.radius, front.intensity))
		types.append(int(front.type))
		var ax := front.normalized_axis()
		shapes.append(Vector4(ax.x, ax.y, front.major_scale, front.minor_scale))
		visuals.append(Vector4(
			front.cloud_amount,
			front.precip_amount,
			front.dissolve_amount,
			front.life_progress
		))
	return {
		"centers": centers,
		"types": types,
		"shapes": shapes,
		"visuals": visuals,
		"count": weather._active_fronts.size()
	}


static func active_fronts(weather: WeatherSystem) -> Array[WeatherFront]:
	return weather._active_fronts

# ─── Systemic Ocean Currents：台风尾迹扰动（可选） ──────────────────────

# 由外部在初始化时调用，把 MapConfig.enable_cyclone_wake / CYCLONE_WAKE_DAYS 写入。


static func configure_cyclone_wake(weather: WeatherSystem, enabled: bool, wake_days: int) -> void:
	weather._cyclone_wake_enabled = enabled
	weather._cyclone_wake_days = max(1, wake_days)
	if not enabled:
		weather.ocean_current_perturbation.clear()

# ─── Phase F.1：DCWorldExt 加速钩子注入 ─────────────────────────
# 由 map_generator 在 _data_core_world_ext 成功 bind 后调用一次（典型路径：
# DataCore._setup_sus 末尾 / refresh_daily 首次调度前）。后续若 ext 失效可
# 再调一次本函数 enabled=false 清空。
#
# 契约：
#   ext == null 或 enabled == false  → run_weather_field_solve_slice 全程走
#                                       GDScript legacy（与无加速完全等价）
#   ext != null 且 enabled == true   → 只要 slice 是全量 (cell_budget ≥ n)
#                                       就尝试 C++ 单 shot 路径，失败则透明
#                                       fallback 到 GDScript 完成本 tick

# 任务 2（dots-completion）：HexCell facade 启用时关掉 hot loop AoS 双写。
# - main / map_generator 在 ClimateProfile.use_hexcell_facade=true 时调用本方法。
# - 启用后 commit_weather_field_solve / GDScript fallback 跳过 16 行 out_cell.weather_*=
#   直写，cell 字段读全部走 SoA（DCWorld view_f32 / facade getter）。
# - 关闭时退回到双写（兼容 facade=false 的 legacy reader）。
# 该方法可在运行时反复调用；调用对下一次 tick 立即生效。


static func _sample_terrain_wind(weather: WeatherSystem, map: MapData, _world: WorldData, world_pos: Vector2, ny: float, season_phase: float) -> Vector2:
	if weather._use_wind_vector_for_advect and map != null:
		var cube := HexUtils.world_to_cube(world_pos, weather._hex_size)
		var cell: HexCell = map.get_cell_by_cube(cube)
		if cell != null:
			var wv: Vector2 = cell.wind_vector
			if wv.length() > 0.01:
				return wv
	# Pure-baseline fallback：纬度风基线（不再走像素 buffer 采样）。
	return WindBelt.wind_at(ny, season_phase)

# spawn 路径（_spawn_random_front / _build_front_at）复用 _current_map_for_tick 取 map
# 引用；if tick 未运行（外部直接调 _build_front_at）则返回 null → _sample_terrain_wind
# 会优雅 fallback。


static func _map_for_spawn(weather: WeatherSystem, _world: WorldData) -> MapData:
	return weather._current_map_for_tick

# 只读查询：返回某 cell 当前的扰动向量（无则 Vector2.ZERO）。给航运 AI / 未来 shader 上传用。


static func cell_perturbation(weather: WeatherSystem, cell: HexCell) -> Vector2:
	if cell == null:
		return Vector2.ZERO
	var key: int = cell.q * 10000 + cell.r
	if not weather.ocean_current_perturbation.has(key):
		return Vector2.ZERO
	var d: Dictionary = weather.ocean_current_perturbation[key]
	return d.get("vec", Vector2.ZERO)

# 每日推进：
#   1) 对已有扰动 days_left - 1，days_left <= 0 则移除；
#      vec 幅度按 days_left / init_days 线性衰减。
#   2) 遍历当前活跃 front，找 STORM + on_water + intensity > 0.8 的"强海上风暴"，
#      在其中心 cell 注入旋转扰动（与风速正交，按 intensity 缩放）。
# dots-monolith-split §1.1：_tick_cyclone_wake 内联实现已迁出至
# scripts/weather/front_advect.gd::tick_cyclone_wake(map)，本处不再保留函数体。
# 静态 _is_water_terrain 仍在本文件保留（被 weather_field/distribute 等多处调用）。
