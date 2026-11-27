extends RefCounted

## Calculates a slice of weather cells using the current slice owner's buffers.

static func run_slice(solver: DCWeatherFieldSolver, cell_budget: int) -> Dictionary:
	if not solver._field_slice_active:
		return { "done": true, "work_done": 0, "elapsed_ms": 0.0, "progress_ratio": 1.0 }
	var t_us0: int = Time.get_ticks_usec()
	var map: MapData = solver._field_slice_map
	var world: WorldData = solver._field_slice_world
	var cells: Array = solver._field_slice_cells
	var n_cells: int = cells.size()
	var start_i: int = solver._field_slice_cursor
	var end_i: int = mini(n_cells, start_i + maxi(1, cell_budget))

	# ─── Phase F.1：DCWorldExt C++ range 快路径 ────────────────────────
	# 触发条件：
	#   1. configure_gdext_acceleration(_weather_system._data_core_world_ext, true) 已生效
	#   2. _field_slice_fast_indexed（neighbor_indices_packed 完整）
	#   3. C++ 端 run_weather_field_solve_pass 支持 start_idx/end_idx 并返回 ≥ 0
	if solver._weather_system._use_gdext_weather_field \
			and solver._field_slice_fast_indexed and solver._weather_system._data_core_world_ext != null:
		# 一次性诊断：第一次进入 fast path 时打一条日志，把 5 个 precondition
		# 的真实状态以及 n_cells / cell_budget 全打出，方便排查。已成功跑过
		# 一次后不再 spam。
		if not solver._weather_system._gdext_field_first_attempt_logged:
			solver._weather_system._gdext_field_first_attempt_logged = true
			print("[weather/F.1] first fast-path attempt: n_cells=%d cell_budget=%d (would-end_i=%d) fast_indexed=%s ext_bound=%s" % [
				n_cells, cell_budget, end_i, str(solver._field_slice_fast_indexed), str(solver._weather_system._data_core_world_ext != null)
			])
		var rc: float = solver._weather_system._try_run_weather_field_solve_gdext(map, world, n_cells, start_i, end_i)
		if rc >= 0.0:
			# C++ 完成当前 range。写入 SoA 暂不发布；只有 commit() 才让 renderer/UI
			# 看到完整 round，保持中间态不可见。
			solver._field_slice_results_in_soa = false
			solver._field_slice_native_convergence_boost = solver._field_slice_refresh_convergence \
				and not solver._weather_system._field_verify_enabled
			# A/B 验证（dev 诊断 only）：在 C++ 写完 SoA 之后，把 next_* 快照、
			# 复位 SoA、跑一遍 GDScript loop 写到独立缓冲区，然后逐 cell 对账。
			# 失败时 push_warning 并打首次发散位置；不影响本 tick commit（commit
			# 仍走 C++ 结果——出 bug 时玩家肉眼能看到，verify 只是给 dev 抓证据）。
			var done_native: bool = end_i >= n_cells
			var transition_enabled_native: bool = false
			var cp_native = solver._weather_system._cp_for_front_flag
			if cp_native != null and cp_native.get("weather_transition_enabled") != null:
				transition_enabled_native = bool(cp_native.weather_transition_enabled)
			var native_wrote_next: bool = bool(solver._field_slice_native_knobs.get("weather_field_wrote_next", false))
			if done_native:
				if not native_wrote_next and (
						solver._weather_system._field_verify_enabled
						or not solver._weather_system._hexcell_facade_on
						or transition_enabled_native):
					solver._weather_system._pull_gdext_field_results_to_next(map, n_cells)
				if solver._weather_system._field_verify_enabled:
					solver._weather_system._verify_gdext_field_against_gdscript(map, world, n_cells)
			solver._field_slice_cursor = end_i
			solver._field_slice_solve_ms += rc
			solver._field_slice_last_ms = rc
			solver._weather_system._gdext_field_runs += 1
			solver._weather_system._gdext_field_total_ms += rc
			# 一次性确认日志：第一次成功跑过 C++ 后打一条，后续静默
			if solver._weather_system._gdext_field_runs == 1:
				print("[weather/F.1] gdext path ACTIVE — first run elapsed=%.2fms (legacy GDScript baseline ≈ 13ms; charter §7 target < 2ms)" % rc)
			return {
				"done": done_native,
				"work_done": end_i - start_i,
				"elapsed_ms": rc,
				"progress_ratio": float(solver._field_slice_cursor) / float(maxi(n_cells, 1)),
				"processed_cells": end_i - start_i,
				"cursor_start": start_i,
				"cursor_end": end_i,
			}
		solver._weather_system._gdext_field_fallbacks += 1
		# rc<0 时 C++ 已经在 console push_warning 了，不需要再叠加日志。

	var cell_pos: PackedVector2Array = solver._field_slice_cell_pos
	var neighbor_indices: PackedInt32Array = solver._field_slice_neighbor_indices
	var fast_indexed: bool = solver._field_slice_fast_indexed
	var prev_vapor: PackedFloat32Array = solver._field_slice_prev_vapor
	var prev_precip: PackedFloat32Array = solver._field_slice_prev_precip
	var next_vapor: PackedFloat32Array = solver._field_slice_next_vapor
	var next_cloud: PackedFloat32Array = solver._field_slice_next_cloud
	var next_cloud_water: PackedFloat32Array = solver._field_slice_next_cloud_water
	var next_precip: PackedFloat32Array = solver._field_slice_next_precip
	var next_instability: PackedFloat32Array = solver._field_slice_next_instability
	var next_intensity: PackedFloat32Array = solver._field_slice_next_intensity
	var next_convergence: PackedFloat32Array = solver._field_slice_next_convergence
	var next_type: PackedInt32Array = solver._field_slice_next_type
	var season_idx: int = solver._field_slice_season_idx
	var climate_anomaly: float = solver._field_slice_climate_anomaly
	var refresh_convergence: bool = solver._field_slice_refresh_convergence
	# B-full Step-2：cell-loop 外一次性取 SoA 数组引用。SoA 与 DCWorld view_f32 同引用，
	# 循环内全部走 PackedArray index 访问，消除 cell.xxx 强类型成员访问。
	# 唯一保留 AoS 的字段是 temperature_transport_anomaly（在 _avg_ocean_anomaly_at_idx
	# helper 中），不在本 plan 范围（属 climate ocean heat transport pass 改造）。
	var soa_temp: PackedFloat32Array = solver._field_slice_temp_read if solver._field_slice_temp_read.size() == n_cells else map.temp_arr
	var soa_air_anomaly: PackedFloat32Array = map.air_mass_temp_anomaly_arr
	var soa_temp_anom: PackedFloat32Array = map.temp_anomaly_arr
	var soa_moisture_loop: PackedFloat32Array = solver._field_slice_moisture_read if solver._field_slice_moisture_read.size() == n_cells else map.moisture_arr
	var soa_elevation: PackedFloat32Array = map.elevation_arr
	var soa_wind_x: PackedFloat32Array = map.wind_x_arr
	var soa_wind_y: PackedFloat32Array = map.wind_y_arr
	var soa_wind_speed: PackedFloat32Array = map.wind_speed_arr
	var soa_terrain: PackedByteArray = map.terrain_arr
	var soa_has_river: PackedByteArray = map.has_river_arr
	var soa_river_q30: PackedFloat32Array = map.river_discharge_30d_arr
	var soa_soil_moisture: PackedFloat32Array = map.soil_moisture_arr
	var soa_veg_vitality: PackedFloat32Array = map.vegetation_vitality_arr
	var soa_sea_ice: PackedFloat32Array = map.sea_ice_frac_arr
	var soa_convergence_in: PackedFloat32Array = map.weather_convergence_arr
	var prev_cloud_water_arr: PackedFloat32Array = map.weather_cloud_water_arr
	var prev_cloud_arr: PackedFloat32Array = map.weather_cloud_arr  # Stage15 云量 EMA 用上帧云量
	var temp_anom_arr: PackedFloat32Array = solver._field_slice_temp_anom if solver._field_slice_temp_anom.size() == n_cells else map.temperature_transport_anomaly_arr
	# ─── 平流式湿团模型常量 (2026-06-21, 镜像 world_ext.cpp 默认值; 实机校准定稿后再旋钮化) ──
	# 2026-06-21 实机迭代(镜像 world_ext.cpp)：第一轮(降 RH_CONDENSE 0.55→0.32 + 提 base/auto)经
	# 205247 复验适得其反——land_dry 49%→83%、vapor 全面崩塌(内陆 0.185→0.085)。根因：降 rh_condense
	# 降低【全局】凝结门槛→水汽场被过度凝结+降水抽干，内陆(输送末端)枯竭最重；增雨靠多凝结是零和陷阱。
	# 第二轮：RH_CONDENSE 回滚 0.55 止抽干，仅保留 BASE_FRAC 0.50 + AUTOCONVERSION 0.16 提 trig
	# (离线验证不抽干 vapor)，隔离验证 trig 提升单独效果。下一轮若不足走开源(提 land_evap)而非加速循环。
	const ADV_VAPOR := 0.95  # 同步C++ 方案③ vapor 平流主导
	const ADV_CLOUD := 0.94
	const RH_CONDENSE := 0.55
	const STATIC_COND_W := 1.0
	const CONDENSE_RATE := 0.45
	const LIFT_COND_GAIN := 0.80
	const CONV_COND_GAIN := 1.0
	const AUTOCONVERSION := 0.16
	# [climate-zone-fix P3] 修漂移：原 const 0.12 与 C++ 主路径(读 field_precip_base_frac knob=cp.weather_field_precip_base_frac=0.08)
	# 不一致。改读同一 weather_system 成员，两路逐位同源(生产默认 0.08)。
	var PRECIP_BASE_FRAC: float = solver._weather_system._field_precip_base_frac
	const LIFT_PRECIP_GAIN := 0.25
	const CONV_PRECIP_GAIN := 1.95   # B1(2026-06-28) 1.80→1.95 提辐合致雨权重,补温度对流减弱→r(precip,conv)↑。镜像 world_ext.cpp
	const ORO_PRECIP_GAIN := 0.10
	const CLOUD_REEVAP := 0.18   # 2026-06-22 雨云化:0.06→0.18 云水更快再蒸发→雨团边缘消散、雨过转晴(生命周期)
	# 热力对流(大陆夏季雷暴)：地表加热+本地水汽 → 凝结/降水，修复内陆"水汽到了却凝不成雨"。镜像 world_ext field_thermal_conv_*。
	const THERMAL_CONV_COND := 1.15   # 降低静态热力云源，让移动/平流项主导雨云
	# [climate-zone-fix P3] 导出为旋钮(cp.weather_field_thermal_conv_precip)；两路读同一 weather_system 成员保 SAME_SOURCE。
	var THERMAL_CONV_PRECIP: float = solver._weather_system._field_thermal_conv_precip
	# ─── climate-realism Stage1 (2026-06-23): Hadley/Ferrel 垂直运动项 omega ──
	# 键在「热赤道」相对纬度(随季迁移、无直线条带): ITCZ/风暴轴上升带增雨, 副热带下沉带抑制凝结+降水。
	# lat_te_norm 由 begin_slice 按 zonal-max 温度逐 tick 计算。镜像 world_ext.cpp。
	# [climate-zone-fix P3] 导出为旋钮(cp.weather_field_omega_ascent_gain)；两路读同一 weather_system 成员保 SAME_SOURCE。
	var OMEGA_ASCENT_GAIN: float = solver._weather_system._field_omega_ascent_gain  # ITCZ(|dlat|<~12°)/风暴轴上升带成雨增益(下调弱化静止ITCZ)
	const OMEGA_DESCENT_GAIN := 0.70   # 副热带(|dlat|~22-34°)下沉带降水抑制
	const OMEGA_DESCENT_COND := 0.45   # 副热带下沉抑制凝结→晴空(利于热浪/旱灾)
	# ─── climate-realism Stage6 (2026-06-23): 湿度充放电 recharge-discharge ─────
	# Stage6/6b 用 vapor 放电把雨段中位 37天→3天、单带 0.91→0.16、海上开始自生成；但 ≥7天长尾(34%)未消、且偏干。
	# 根因：长尾格是【强迫主导】(常驻辐合/地形抬升)而非水汽主导——抽干水汽只会饿死弱短系统(全局变干)，
	# 强迫格仍靠平流来的少量水汽持续成雨。Stage6c 改用【对流抑制记忆】(下方 INHIB_*)定点封顶强迫格，
	# 同时把 vapor 放电调回温和(不再过度抽干)。
	const VAPOR_DISCHARGE := 0.70   # 持续降水更快抽干本格水汽，避免固定雨核永雨
	const DISCHARGE_SUSTAIN := 0.65 # prev_precip 高时加强放电，让雨团下完后进入恢复期
	# ── Stage6e (2026-06-23): 对流抑制记忆=双稳弛豫振子(真·充放电极限环) ──
	# 实测线性版(precip×(1-inhib·k))只把降水压到稳态弱雨(~0.05>湿阈)→雨永不停、中位反而升到 16 天。
	# 改双稳硬阈：inhib 累积过 TRIGGER → 降水砍到近 0(气柱放电、转干转晴) → inhib 衰减落回 → 释放再积累。
	# 无中间稳态→真正的 开/关 循环→封顶雨段；只作用于刚下过雨的格(干区 inhib=0)。
	# ── Stage6g (2026-06-23): 对流抑制=按【时长】充放电(强度无关)，双稳两段编码于单个 float ──
	# 实测 magnitude 版只能封重雨(>~0.065)，中等雨(p50 0.065)稳态 inhib<阈→永不触发→中等长尾(≥7天 18%)。
	# 改按"连续降水 tick 数"充能：任意强度连下 ~6 tick → 满 → 跳到不应期(转干转晴) → 衰减落回 → 重启。
	# 与强度无关→中等雨也被封顶；充能期满强度照下→不伤雨量/多样性。物理上=对流耗尽本地不稳定度需特征"时长"。
	#   inhib∈[0,1) 充能期；inhib≥1 不应期(压制降水)。
	const INHIB_CHARGE := 0.26    # Stage7c: 0.18→0.26 雨段缩到≈4tick(~2天)→雨不再"久久下不完"
	const INHIB_REFRAC := 0.18    # Stage7c: 0.55→0.18 不应期拉长到≈5-6tick(~3天)→晴天是真间断而非极短闪烁
	const INHIB_LEAK := 0.88      # 充能期遇干 tick 的泄放(断续雨慢充、久干遗忘)
	const INHIB_STRENGTH := 0.92  # 不应期内 precip ×(1-此值)
	const INHIB_WET := 0.02       # 计为"降水 tick"的阈
	var lat_te_norm: float = solver._field_slice_lat_te_norm
	var omega_bpos_y: float = solver._weather_system._world_bounds.position.y
	var omega_bsize_y: float = solver._weather_system._world_bounds.size.y
	for i in range(start_i, end_i):
		var cell: HexCell = cells[i]
		var pos: Vector2 = cell_pos[i]
		var temp: float = clampf(soa_temp[i] + climate_anomaly + soa_air_anomaly[i], 0.0, 1.0)
		var base_m: float = clampf(soa_moisture_loop[i], 0.0, 1.0)
		var elevation: float = soa_elevation[i]
		var vapor_capacity: float = clampf(0.18 + 0.82 * temp - 0.18 * elevation, 0.14, 1.0)
		var ocean_an: float = solver._avg_ocean_anomaly_at_idx(i, cells, neighbor_indices) if fast_indexed else solver._avg_ocean_anomaly_at(cell, map)
		var on_water: bool = solver._weather_system._is_water_terrain(int(soa_terrain[i]))

		var wind: Vector2 = Vector2(soa_wind_x[i], soa_wind_y[i])
		if wind.length_squared() < 0.0001:
			var ny: float = 0.5
			if solver._weather_system._world_bounds.size.y > 0.001:
				ny = clampf((pos.y - solver._weather_system._world_bounds.position.y) / solver._weather_system._world_bounds.size.y, 0.0, 1.0)
			wind = solver._weather_system._sample_terrain_wind(map, world, pos, ny, solver._weather_system._season_phase)
		var wind_dir: Vector2 = wind.normalized() if wind.length_squared() > 0.0001 else Vector2.RIGHT

		var upstream_idx: int = solver._neighbor_aligned_idx(i, -wind_dir, cell_pos, neighbor_indices) if fast_indexed and solver._weather_system._field_advect_steps > 0 else -1
		var advected_vapor: float = solver._upstream_vapor_idx_from_first(i, upstream_idx, cell_pos, neighbor_indices, prev_vapor, wind_dir) if fast_indexed else solver._upstream_vapor_cached(cell, map, prev_vapor, wind_dir)
		var neighbor_vapor: float = solver._neighbor_average_vapor_idx(i, neighbor_indices, prev_vapor) if fast_indexed else solver._neighbor_average_vapor_cached(cell, map, prev_vapor)
		var raw_wind_speed: float = soa_wind_speed[i] if soa_wind_speed.size() == n_cells else wind.length()
		var wind_mag: float = clampf(raw_wind_speed / 1.2, 0.0, 1.0)
		var lift: float = solver._orographic_lift_from_upstream_idx(i, upstream_idx, cells) if fast_indexed else solver._orographic_lift_for_cell(cell, map, wind_dir)
		var convergence: float = soa_convergence_in[i]
		if refresh_convergence:
			convergence = solver._wind_convergence_idx(i, cells, cell_pos, neighbor_indices) if fast_indexed else solver._wind_convergence_for_cell(cell, map)
		var is_lake: bool = int(soa_terrain[i]) == TerrainType.TERRAIN.LAKE
		var has_river: bool = (not is_lake) and (soa_has_river[i] > 0) and not on_water
		var river_flow_feedback: float = clampf(soa_river_q30[i] if soa_river_q30.size() == n_cells and has_river else 0.0, 0.0, 1.0)
		var river_recycle_lock: float = 0.0
		if has_river:
			var river_forcing_proxy: float = maxf(convergence * 0.76, maxf(lift, 0.0) * 0.80)  # W3: 0.65→0.76，保持旧 p90 处贡献
			river_recycle_lock = clampf(smoothstep(0.035, 0.12, prev_precip[i]) \
				* (1.0 - smoothstep(0.16, 0.44, river_forcing_proxy)) \
				* (0.35 + river_flow_feedback * 0.65), 0.0, 1.0)
		var river_source_scale: float = 1.0 - river_recycle_lock * 0.72
		var river_evap_floor: float = maxf(0.08, river_flow_feedback * 0.22) * (1.0 - river_recycle_lock * 0.65) if has_river else 0.0
		var effective_ocean_an: float = ocean_an
		if is_lake:
			effective_ocean_an = 0.20
		elif has_river:
			effective_ocean_an = maxf(ocean_an, river_evap_floor)

		var temp_evap: float = maxf(solver._weather_system._field_cool_season_vapor_floor, smoothstep(0.10, 0.78, temp))  # [P3] 冷季蒸发地板(0=原行为)
		var wind_evap: float = 0.70 + wind_mag * 0.55
		var soil_norm: float = clampf(0.5 + (soa_soil_moisture[i] if soa_soil_moisture.size() == n_cells else cell.soil_moisture), 0.0, 1.0)
		var veg_vitality: float = clampf(soa_veg_vitality[i] if soa_veg_vitality.size() == n_cells else cell.vegetation_vitality, 0.0, 1.0)
		var veg_flux: float = solver._weather_system._vegetation_transpiration_factor(cell) * (0.45 + veg_vitality * 0.65)
		var sea_ice: float = clampf(soa_sea_ice[i] if soa_sea_ice.size() == n_cells else cell.sea_ice_fraction, 0.0, 1.0)
		var wet_terrain_bonus: float = 0.0
		match int(soa_terrain[i]):
			TerrainType.TERRAIN.SWAMP, TerrainType.TERRAIN.JUNGLE, TerrainType.TERRAIN.DELTA:
				wet_terrain_bonus = 0.010
			TerrainType.TERRAIN.LAKE:
				wet_terrain_bonus = 0.016
			_:
				wet_terrain_bonus = 0.0
		var source_local: float = 0.0
		if on_water:
			source_local = (0.018 + temp_evap * 0.052) * solver._weather_system._field_ocean_evap_gain * wind_evap
			source_local *= clampf(1.0 + effective_ocean_an * 0.55, 0.55, 1.45)
			source_local *= 1.0 - sea_ice * 0.92
			if is_lake:
				source_local *= solver._weather_system._field_lake_evap_scale
		else:
			source_local = (0.005 + base_m * 0.010 + soil_norm * 0.020 + veg_flux * 0.016 + wet_terrain_bonus) \
				* solver._weather_system._field_land_evapotranspiration_gain * temp_evap * (0.85 + wind_mag * 0.25)
			if has_river:
				var river_extra: float = (0.010 + river_flow_feedback * 0.020) * solver._weather_system._field_land_evapotranspiration_gain * temp_evap
				source_local += river_extra * river_source_scale

		var source_upwind: float = source_local
		var upstream_on_water: bool = false
		if upstream_idx >= 0:
			var up_cell: HexCell = cells[upstream_idx]
			var up_temp: float = clampf(soa_temp[upstream_idx] + climate_anomaly + soa_air_anomaly[upstream_idx], 0.0, 1.0)
			var up_base_m: float = clampf(soa_moisture_loop[upstream_idx], 0.0, 1.0)
			var up_terrain: int = int(soa_terrain[upstream_idx])
			var up_on_water: bool = solver._weather_system._is_water_terrain(up_terrain)
			upstream_on_water = up_on_water
			var up_is_lake: bool = up_terrain == TerrainType.TERRAIN.LAKE
			var up_has_river: bool = (not up_is_lake) and (soa_has_river[upstream_idx] > 0) and not up_on_water
			var up_river_q: float = clampf(soa_river_q30[upstream_idx] if soa_river_q30.size() == n_cells and up_has_river else 0.0, 0.0, 1.0)
			var up_river_recycle_lock: float = 0.0
			if up_has_river:
				var up_forcing_proxy: float = clampf(soa_convergence_in[upstream_idx] * 0.76, 0.0, 1.0)
				up_river_recycle_lock = clampf(smoothstep(0.035, 0.12, prev_precip[upstream_idx]) \
					* (1.0 - smoothstep(0.16, 0.44, up_forcing_proxy)) \
					* (0.35 + up_river_q * 0.65), 0.0, 1.0)
			var up_river_source_scale: float = 1.0 - up_river_recycle_lock * 0.72
			var up_temp_evap: float = maxf(solver._weather_system._field_cool_season_vapor_floor, smoothstep(0.10, 0.78, up_temp))  # [P3] 冷季蒸发地板(0=原行为)
			var up_ocean_an: float = temp_anom_arr[upstream_idx] if temp_anom_arr.size() == n_cells and up_on_water else effective_ocean_an
			var up_soil: float = clampf(0.5 + (soa_soil_moisture[upstream_idx] if soa_soil_moisture.size() == n_cells else up_cell.soil_moisture), 0.0, 1.0)
			var up_vitality: float = clampf(soa_veg_vitality[upstream_idx] if soa_veg_vitality.size() == n_cells else up_cell.vegetation_vitality, 0.0, 1.0)
			var up_veg_flux: float = solver._weather_system._vegetation_transpiration_factor(up_cell) * (0.45 + up_vitality * 0.65)
			var up_sea_ice: float = clampf(soa_sea_ice[upstream_idx] if soa_sea_ice.size() == n_cells else up_cell.sea_ice_fraction, 0.0, 1.0)
			var up_wet_bonus: float = 0.0
			match up_terrain:
				TerrainType.TERRAIN.SWAMP, TerrainType.TERRAIN.JUNGLE, TerrainType.TERRAIN.DELTA:
					up_wet_bonus = 0.010
				TerrainType.TERRAIN.LAKE:
					up_wet_bonus = 0.016
				_:
					up_wet_bonus = 0.0
			if up_on_water:
				source_upwind = (0.018 + up_temp_evap * 0.052) * solver._weather_system._field_ocean_evap_gain * wind_evap
				source_upwind *= clampf(1.0 + up_ocean_an * 0.55, 0.55, 1.45)
				source_upwind *= 1.0 - up_sea_ice * 0.92
				if up_is_lake:
					source_upwind *= solver._weather_system._field_lake_evap_scale
			else:
				source_upwind = (0.005 + up_base_m * 0.010 + up_soil * 0.020 + up_veg_flux * 0.016 + up_wet_bonus) \
					* solver._weather_system._field_land_evapotranspiration_gain * up_temp_evap * (0.85 + wind_mag * 0.25)
				if up_has_river:
					var up_river_extra: float = (0.010 + up_river_q * 0.020) * solver._weather_system._field_land_evapotranspiration_gain * up_temp_evap
					source_upwind += up_river_extra * up_river_source_scale

		# 平流式湿团：vapor 去 base_m 锚定 → 本地与上风加权平流(强度随风速) + 邻域扩散 + 蒸发源。
		# 允许短暂过饱和(不夹 cap 上限)，由后续凝结消耗 → 随风移动的湿团。镜像 world_ext.cpp。
		var adv_w_v: float = minf(ADV_VAPOR * (0.75 + 0.25 * wind_mag), 0.99)  # 同步C++ vapor 平流主导
		var vapor: float = lerpf(prev_vapor[i], advected_vapor, adv_w_v)
		vapor = lerpf(vapor, neighbor_vapor, solver._weather_system._field_diffusion)
		vapor = maxf(0.0, vapor + source_local + source_upwind * wind_mag * 0.25)

		# (背风焚风干燥已移入下方凝结/降水的 lift<0 抑制，避免对 vapor 重复扣减)

		var temp_min: float = temp
		var temp_max: float = temp
		if fast_indexed:
			var nb_base: int = i * 6
			for d in range(6):
				var nb_idx: int = neighbor_indices[nb_base + d]
				if nb_idx < 0:
					continue
				var nb_temp: float = clampf(soa_temp[nb_idx] + climate_anomaly + soa_air_anomaly[nb_idx], 0.0, 1.0)
				temp_min = minf(temp_min, nb_temp)
				temp_max = maxf(temp_max, nb_temp)
		else:
			for nb: HexCell in solver._weather_system._cell_neighbors(cell, map):
				if nb == null:
					continue
				var nb_temp_cell: float = clampf(nb.temperature + climate_anomaly + nb.air_mass_temp_anomaly, 0.0, 1.0)
				temp_min = minf(temp_min, nb_temp_cell)
				temp_max = maxf(temp_max, nb_temp_cell)
		var temp_gradient: float = temp_max - temp_min
		var relative_humidity: float = maxf(vapor / maxf(vapor_capacity, 0.001), 0.0)
		var frontal_convergence: float = smoothstep(0.02, 0.46, convergence)  # W3: 旧 0.14 按 p50=0.376 的假基线标的；net p50=0.016/p90=0.458
		var humidity_front_gate: float = smoothstep(0.25, 0.78, relative_humidity)  # Stage2: 0.38→0.25 让冷湿锋面也成雨(温带过境雨团/冷区降雪)
		var frontogenesis: float = clampf(frontal_convergence * smoothstep(0.04, 0.16, temp_gradient) * humidity_front_gate * solver._weather_system._field_frontogenesis_gain, 0.0, 1.0)
		var lift_pos: float = maxf(lift, 0.0)
		# Stage11 层状降水(stratiform)：补对流暖门(temp>0.48)挡死的冷/高/水区降水——湿度+弱抬升(地形/辐合/
		# 锋面/海面层云·lake-effect),冷区权重高(与对流互补)。修 #4湖/#5a雪/#6山。镜像 world_ext.cpp。
		var strat_cool: float = 1.0 - smoothstep(0.40, 0.62, temp)
		var strat_humid: float = smoothstep(0.42, 0.70, relative_humidity)
		var strat_drive: float = lift_pos * 0.90 + convergence * 0.70 + frontogenesis * 0.80  # W3: 0.60→0.70
		if on_water:
			strat_drive += (0.22 + wind_mag * 0.30) * (1.0 - sea_ice * 0.92)
		var stratiform: float = clampf(strat_humid * strat_cool * minf(strat_drive, 1.0) * solver._weather_system._field_stratiform_gain, 0.0, 1.0)  # [P3] 层状增益镜像 C++ field_stratiform_gain

		# 热力对流(大陆夏季雷暴/对流雨)：地表加热+本地水汽 → 浮力凝结+高效降水。修复内陆 rh 永远
		# <<静力阈、lift/辐合皆缺 → 蒸散/平流来的 vapor 凝不成云的死结(用户洞察:内陆蒸发应能成雨)。
		# 仅陆地。季节自限:冬温<0.45 不触发;降水耗 vapor→rh 降→对流减弱,呈"晴-积累-雷暴"间歇,不永雨。
		# 2026-06-22 雨云化根因:陆地rh中位0.18(>0.55仅2.7%→静力凝结死),成云降水76%靠本项热力对流。
		# rh*5门控致干空气被硬拉成半饱和→温暖陆地处处弱对流→产云水平流扩散→遍地雾+小雨。convective双峰
		# (p50=0,p75=0.39),谷底0.28硬截断:砍弱对流(损失6.5%降水)转晴/多云、保强对流核突显明显降水。(C++主路径同值)
		var conv_raw: float = 0.0 if on_water else smoothstep(0.48, 0.74, temp) * clampf(relative_humidity * 2.6, 0.0, 1.0)  # B1(2026-06-28) 3.6→2.6 去 rh 虚高:对流改由"湿暖"(沿海)触发而非"干暖"(内陆)→降水脱离纯温度。镜像 world_ext.cpp
		var convective: float = 0.0 if conv_raw < 0.42 else conv_raw
		var ocean_convective: float = 0.0
		if on_water:
			ocean_convective = smoothstep(0.10, 0.22, ocean_an) * smoothstep(0.58, 0.78, temp) * clampf(relative_humidity, 0.0, 1.0)
			var open_water: float = 1.0 - sea_ice * 0.92
			var warm_humid_marine: float = smoothstep(0.54, 0.74, temp) \
				* smoothstep(0.47, 0.69, relative_humidity) \
				* clampf(open_water, 0.0, 1.0)
			var marine_convective_seed: float = warm_humid_marine * (0.20 + wind_mag * 0.36)
			ocean_convective = minf(1.0, maxf(ocean_convective, marine_convective_seed))
		var onshore_moist_flux: float = 0.0
		var coastal_monsoon_flux: float = 0.0
		if not on_water and upstream_idx >= 0 and upstream_on_water:
			onshore_moist_flux = wind_mag * clampf(relative_humidity, 0.0, 1.0) * smoothstep(0.54, 0.75, temp)
			coastal_monsoon_flux = onshore_moist_flux
		elif on_water and upstream_idx >= 0:
			var downwind_idx: int = solver._neighbor_aligned_idx(i, wind_dir, cell_pos, neighbor_indices) if fast_indexed else -1
			var near_land: bool = false
			if downwind_idx >= 0:
				near_land = not solver._weather_system._is_water_terrain(int(soa_terrain[downwind_idx]))
			if near_land:
				coastal_monsoon_flux = wind_mag * clampf(relative_humidity, 0.0, 1.0) * smoothstep(0.56, 0.76, temp) * 0.75
		var dynamic_forcing: float = maxf(maxf(maxf(frontogenesis, convergence * 0.76), maxf(maxf(convective, ocean_convective), coastal_monsoon_flux)), stratiform)  # Stage11 含层状；W3: conv 0.65→0.76
		# Stage6: post-rain 抑制不再被强强迫完全豁免(原 ×(1-smoothstep) 在辐合带=0→雨带不自抑)。
		# 改留 45% 残余(×(1-0.55·smoothstep))，让辐合带雨团下完也进入不应期→配合放电自发消散。
		var post_rain_subsidence: float = smoothstep(0.035, 0.11, prev_precip[i]) * (1.0 - 0.55 * smoothstep(0.18, 0.55, dynamic_forcing))

		# ─── climate-realism Stage1: Hadley/Ferrel omega (镜像 world_ext.cpp) ──
		# dlat = 本格纬度距「热赤道」的度数; ITCZ/风暴轴上升带增雨, 副热带下沉带抑制凝结+降水→晴干。
		var omega_ny: float = clampf((cell_pos[i].y - omega_bpos_y) / omega_bsize_y, 0.0, 1.0) if omega_bsize_y > 0.001 else 0.5
		var omega_adlat: float = absf((omega_ny - lat_te_norm) * 180.0)
		var omega_itcz: float = 1.0 - smoothstep(8.0, 16.0, omega_adlat)
		var omega_storm: float = smoothstep(40.0, 48.0, omega_adlat) * (1.0 - smoothstep(62.0, 70.0, omega_adlat))
		var omega_ascent: float = maxf(omega_itcz, omega_storm)
		var omega_descent: float = smoothstep(14.0, 22.0, omega_adlat) * (1.0 - smoothstep(34.0, 42.0, omega_adlat))
		var omega_precip_mult: float = (1.0 + omega_ascent * OMEGA_ASCENT_GAIN) * (1.0 - omega_descent * OMEGA_DESCENT_GAIN)

		# 凝结 vapor→cloud_water：动力(抬升/辐合)主导 + 静力过饱和(rh 超阈) + 热力对流。
		var sup: float = maxf(relative_humidity - RH_CONDENSE, 0.0)
		# 注:ψ(synoptic eddy)/base_lift/水汽辐合抽吸/ψ 主导降水 = C++-only(run_weather_field_solve_pass 内联全场推进),
		# 本 GDScript fallback 【不含 ψ】→ 退化为"无移动天气系统"的旧版(整数 hash 难 bit-perfect 双镜像,故有意未镜像)。
		# 其余确定性物理(omega/平流主导/对流/stratiform/云EMA/precip平滑/湖山冷区)已与 C++ 同步。
		var cond_force: float = clampf(sup * STATIC_COND_W + lift_pos * LIFT_COND_GAIN + convergence * CONV_COND_GAIN + frontogenesis * 1.35 + convective * THERMAL_CONV_COND + ocean_convective * 0.90 + stratiform * 0.75, 0.0, 1.0)  # Stage11 层状凝结
		cond_force *= 1.0 - post_rain_subsidence * 0.45

		cond_force *= 1.0 - omega_descent * OMEGA_DESCENT_COND   # 副热带下沉抑制凝结
		var condensation: float = vapor * cond_force * CONDENSE_RATE
		if lift < 0.0:
			condensation *= maxf(1.0 + lift * solver._weather_system._field_rain_shadow_drying, 0.0)
		condensation = clampf(condensation, 0.0, vapor * 0.92)
		vapor -= condensation

		# cloud_water 随风平流(搬运湿团) + 凝结加入 + 邻域扩散。复用 vapor 平流 helper(传 cloud_water)。
		var cloud_water: float = prev_cloud_water_arr[i] if prev_cloud_water_arr.size() == n_cells else 0.0
		if upstream_idx >= 0 and prev_cloud_water_arr.size() == n_cells:
			var cw_upwind: float = solver._upstream_vapor_idx_from_first(i, upstream_idx, cell_pos, neighbor_indices, prev_cloud_water_arr, wind_dir)
			var cw_neighbor: float = solver._neighbor_average_vapor_idx(i, neighbor_indices, prev_cloud_water_arr)
			var adv_w_c: float = minf(ADV_CLOUD * (0.55 + 0.45 * wind_mag), 0.98)
			cloud_water = lerpf(cloud_water, cw_upwind, adv_w_c)
			cloud_water = lerpf(cloud_water, cw_neighbor, solver._weather_system._field_diffusion)
		cloud_water = clampf(cloud_water + condensation, 0.0, 1.0)

		var instability: float = clampf(
			(temp - 0.48) * 0.80
			+ relative_humidity * 0.30
			+ convergence * 0.55
			+ lift_pos * 1.20
			+ frontogenesis * 0.55
			+ ocean_convective * 0.35,
			0.0, 1.0
		)

		# 降水：autoconversion 消耗 cloud_water。动力(辐合/抬升/不稳定)触发主导，地形弱增强；
		# 背景 base_frac 很小 → 无动力区降水压到 wet 阈值以下 → 只有移动天气系统处成雨 → 雨随系统移动。
		var trig: float = AUTOCONVERSION * (PRECIP_BASE_FRAC + lift_pos * LIFT_PRECIP_GAIN + convergence * CONV_PRECIP_GAIN + frontogenesis * 0.85 + instability * 0.30)
		trig *= (1.0 + lift_pos * ORO_PRECIP_GAIN)
		trig += convective * THERMAL_CONV_PRECIP   # 对流雨高效成雨，旁路 autoconv 瓶颈(内陆 cw 少)
		trig += ocean_convective * 0.95
		trig += stratiform * 0.80   # Stage11 层状降水高效成雨(冷/高/水区,旁路 autoconv)→修 #4湖/#5a雪/#6山
		trig = clampf(trig, 0.0, 0.95)
		var precip_target: float = cloud_water * trig
		precip_target *= omega_precip_mult   # Stage1 omega: ITCZ/风暴轴增雨 + 副热带下沉抑雨(纬向廓线)
		# Stage6e 对流抑制记忆(双稳)：读取累积抑制(本 tick 起始值)，硬阈压制移到最终降水处(EMA 之后)。
		var inhib_old: float = solver._convective_inhib[i] if solver._convective_inhib.size() == n_cells else 0.0
		if lift < 0.0:
			precip_target *= 1.0 - minf(maxf(-lift, 0.0) * solver._weather_system._field_rain_shadow_drying, 0.85)
		if has_river and river_recycle_lock > 0.0:
			var river_relief: float = river_recycle_lock * (1.0 - smoothstep(0.22, 0.50, dynamic_forcing))
			if river_relief > 0.0:
				var cloud_relief: float = cloud_water * 0.22 * river_relief
				cloud_water -= cloud_relief
				vapor += cloud_relief * 0.60
				precip_target *= 1.0 - 0.48 * river_relief
		# 水面对流抑制(保留动力门控：辐合/锋生/暖流异常 释放降水；instability 仅极端深对流安全阀)。
		var ocean_drive: float = 0.0
		if on_water:
			var drv_an: float = clampf(ocean_an / 0.16, 0.0, 1.0)
			var drv_in: float = clampf((instability - 0.52) / 0.30, 0.0, 1.0)
			var drv_cv: float = clampf((convergence - 0.02) / 0.44, 0.0, 1.0)  # W3: 旧 (0.38,0.16)→(p50, p90-p50)
			var drv_fr: float = clampf(frontogenesis / 0.16, 0.0, 1.0)
			var drv_mn: float = clampf(coastal_monsoon_flux / 0.18, 0.0, 1.0)
			var drv_hc: float = smoothstep(0.47, 0.69, relative_humidity) \
				* smoothstep(0.040, 0.105, cloud_water) \
				* smoothstep(0.54, 0.74, temp)
			if is_lake:
				drv_hc *= 0.60
			drv_hc *= 0.68
			ocean_drive = maxf(maxf(drv_an, drv_in), maxf(maxf(drv_cv, drv_fr), maxf(drv_mn, drv_hc)))
			ocean_drive = maxf(ocean_drive, omega_ascent)   # ITCZ/风暴轴上升带释放海面降水抑制
			var precip_suppression: float = solver._weather_system._field_ocean_precip_suppression
			if is_lake:
				precip_suppression = minf(precip_suppression, 0.35)  # Stage9: 湖泊≈陆地降水(0.70→0.35)→湖区不再始终晴
			else:
				precip_suppression = minf(precip_suppression, 0.78)
			precip_target *= lerpf(1.0 - precip_suppression, 1.0, ocean_drive)
			var marine_relief: float = post_rain_subsidence * (1.0 - smoothstep(0.30, 0.58, ocean_drive))
			precip_target *= 1.0 - marine_relief * 0.72
		precip_target = minf(precip_target, cloud_water)
		precip_target = maxf(precip_target, 0.0)
		cloud_water = maxf(cloud_water - precip_target, 0.0)
		var precip_cloud_reserve: float = precip_target * (0.18 + dynamic_forcing * 0.18)
		cloud_water = minf(1.0, cloud_water + precip_cloud_reserve)
		var quiet_core: float = 1.0 - smoothstep(0.12, 0.50, dynamic_forcing)
		if on_water and ocean_drive < 0.34:
			var marine_scour: float = clampf(cloud_water * (0.036 + (0.34 - ocean_drive) * 0.18) * (1.0 + post_rain_subsidence * 1.60), 0.0, cloud_water)
			cloud_water -= marine_scour
			vapor += marine_scour * 0.55

		# 干空气云水再蒸发回 vapor（湿团边缘消散 → 闭合水量收支）。
		var reevap: float = clampf(cloud_water * solver._weather_system._field_cloud_reevap * (1.0 - relative_humidity) * (1.0 + post_rain_subsidence * 1.75 + quiet_core * 0.75), 0.0, cloud_water)
		cloud_water -= reevap
		vapor += reevap
		if on_water:
			vapor *= 1.0 - post_rain_subsidence * (1.0 - smoothstep(0.28, 0.58, ocean_drive)) * 0.045
		# 降水稳定性(地形阻尼 + 极端 soft cap) + EMA 时间惯性(保留)。
		precip_target = solver._weather_system._moderate_field_precip_for_terrain(int(soa_terrain[i]), precip_target)
		# Stage10 不应期(inhib≥1)作用于 target(EMA 前)→降水随惯性平滑衰减到近零，不再瞬间砍断(去时间跳变)。镜像 world_ext.cpp。
		if inhib_old >= 1.0:
			precip_target *= 1.0 - INHIB_STRENGTH
		var precip: float = lerpf(prev_precip[i], precip_target, solver._weather_system._field_precip_inertia)
		if precip_target < prev_precip[i] and dynamic_forcing < 0.20:
			precip = lerpf(precip, precip_target, post_rain_subsidence * 0.55)
		# 按配置做空间平滑。削峰权重较小，保留局部强降水。
		var nbr_precip: float = solver._neighbor_average_vapor_idx(i, neighbor_indices, prev_precip) if fast_indexed else solver._neighbor_average_vapor_cached(cell, map, prev_precip)
		var smooth_k: float = solver._weather_system._field_precip_spatial_smooth
		precip = lerpf(precip, nbr_precip, smooth_k if nbr_precip > precip else smooth_k * 0.30)
		var effective_precip_floor: float = 0.014 if on_water else 0.018
		if precip < 0.003:
			precip = 0.0
		var provisional_cloud: float = clampf(cloud_water * 1.10 + condensation * 0.25, 0.0, 1.0)
		var temp_anom_i: float = soa_temp_anom[i] if soa_temp_anom.size() == n_cells else 0.0
		var snow_cover_cls: float = solver._field_slice_snow_cover_read[i] if solver._field_slice_snow_cover_read.size() == n_cells else 0.0
		var pre_wt: int = solver._weather_system._classify_field_weather_at(temp, vapor, provisional_cloud, cloud_water, precip, instability, ocean_an, raw_wind_speed, temp_anom_i, maxf(onshore_moist_flux, coastal_monsoon_flux), on_water, snow_cover_cls)
		var quiet_non_precip: bool = not solver._weather_system._is_precip_weather_type(pre_wt) and quiet_core > 0.0
		if (precip < 0.003 or quiet_non_precip) and quiet_core > 0.0:
			var clear_cap: float = 0.065 + dynamic_forcing * 0.12
			if on_water and ocean_drive < 0.20:
				clear_cap = minf(clear_cap, 0.070 + ocean_drive * 0.18)
			if cloud_water > clear_cap:
				var excess_cloud_water: float = (cloud_water - clear_cap) * quiet_core
				cloud_water -= excess_cloud_water
				vapor += excess_cloud_water * 0.75
		if quiet_non_precip and precip < effective_precip_floor:
			vapor += precip * 0.65
			precip = 0.0
		vapor = clampf(vapor, 0.0, 1.0)
		var vapor_after_precip: float = vapor
		var rain_core: float = smoothstep(0.025, 0.095, precip)
		var front_core: float = smoothstep(0.08, 0.55, frontogenesis)
		var cloud_floor: float = maxf(rain_core * (0.14 + rain_core * 0.22), front_core * 0.30)
		if convective > 0.0:
			cloud_floor = maxf(cloud_floor, 0.06 + convective * 0.18)
		if ocean_convective > 0.0:
			cloud_floor = maxf(cloud_floor, 0.10 + ocean_convective * 0.16)
		if quiet_non_precip:
			var fair_humid: float = smoothstep(0.34, 0.56, relative_humidity)
			var fair_cloud_floor: float = fair_humid * quiet_core * (0.050 + fair_humid * 0.070)
			cloud_floor = maxf(cloud_floor, fair_cloud_floor)
		var cloud: float = clampf(maxf(cloud_water * 1.10 + condensation * 0.25, cloud_floor), 0.0, 1.0)
		if prev_cloud_arr.size() == n_cells:
			cloud = lerpf(prev_cloud_arr[i], cloud, solver._weather_system._field_cloud_inertia)  # Stage15 云量时间 EMA，镜像 C++ field_cloud_inertia

		var wt: int = solver._weather_system._classify_field_weather_at(temp, vapor, cloud, cloud_water, precip, instability, ocean_an, raw_wind_speed, temp_anom_i, maxf(onshore_moist_flux, coastal_monsoon_flux), on_water, snow_cover_cls)
		if not solver._weather_system._is_precip_weather_type(wt) and precip > 0.0:
			vapor = clampf(vapor + precip * 0.65, 0.0, 1.0)
			vapor_after_precip = vapor
			precip = 0.0
		elif precip > 0.0:
			# Stage6 放电：实际降水抽干本格水汽→气柱失水→RH降→自发停雨→需充电恢复(雨团生命周期+随上风新鲜水汽移动+海面自生成)。
			# Stage6b：持续降水(prev_precip 高)放电翻倍→定点清除"连下一周"长尾，不动新生短雨段。
			var discharge_amp: float = 1.0 + DISCHARGE_SUSTAIN * smoothstep(0.04, 0.10, prev_precip[i])
			vapor_after_precip = maxf(0.0, vapor_after_precip - precip * VAPOR_DISCHARGE * discharge_amp)
		var intensity: float = solver._weather_system._field_intensity_for_type(wt, temp, vapor, cloud, precip, instability, ocean_an)
		# Stage6g 更新对流抑制(按时长两段)：充能期连续降水累加→满进不应期；不应期衰减→落回清零重启。
		if solver._convective_inhib.size() == n_cells:
			var ni: float
			if inhib_old >= 1.0:
				ni = inhib_old - INHIB_REFRAC
				if ni < 1.0:
					ni = 0.0
			elif precip > INHIB_WET:
				ni = inhib_old + INHIB_CHARGE
				if ni >= 1.0:
					ni = 2.0
			else:
				ni = inhib_old * INHIB_LEAK
			solver._convective_inhib[i] = ni
		next_vapor[i] = vapor_after_precip
		next_cloud[i] = cloud
		next_cloud_water[i] = cloud_water
		next_precip[i] = precip
		next_instability[i] = instability
		next_type[i] = wt
		next_intensity[i] = intensity
		next_convergence[i] = convergence
	solver._field_slice_cursor = end_i
	var elapsed_ms: float = (Time.get_ticks_usec() - t_us0) / 1000.0
	solver._field_slice_solve_ms += elapsed_ms
	solver._field_slice_last_ms = elapsed_ms
	return {
		"done": solver._field_slice_cursor >= n_cells,
		"work_done": end_i - start_i,
		"elapsed_ms": elapsed_ms,
		"progress_ratio": float(solver._field_slice_cursor) / float(maxi(n_cells, 1)),
		"processed_cells": end_i - start_i,
		"cursor_start": start_i,
		"cursor_end": end_i,
	}


## 切片入口（搬迁 commit_weather_field_solve + slice 状态机后填充）。
## E.1 阶段返回空 fronts；F.1 C++ 化后由 caller 切到 DCWorldExt 路径。
