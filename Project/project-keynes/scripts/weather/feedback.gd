extends "res://scripts/weather/weather_context.gd"
class_name DCWeatherFeedback


func _init(weather_system) -> void:
	_weather_system = weather_system


func _distribute_to_cells(host, map: MapData) -> void:
	host._cover_dirty = false
	# PR-2.1.6（weather → climate 反馈写路径下移）：预分配 batch buffer。
	# distribute 段在 weather field commit 之后跑，把 weather 扰动叠加到 cell.moisture/temp。
	# 详见 master 手册 §3.9.2 PR-2.1.6b。
	var _wd_n: int = map.cell_count() if map.has_method("cell_count") else map.all_cells().size()
	var _wd_idx: PackedInt32Array = PackedInt32Array()
	var _wd_moist: PackedFloat32Array = PackedFloat32Array()
	var _wd_temp: PackedFloat32Array = PackedFloat32Array()
	_wd_idx.resize(_wd_n)
	_wd_moist.resize(_wd_n)
	_wd_temp.resize(_wd_n)
	var _wd_w: int = 0

	for cell: HexCell in map.all_cells():
		var pos = HexUtils.cube_to_world(cell.q, cell.r, host._hex_size)
		var result = host.query_at(pos)
		var wt: int = int(result.get("type", WeatherType.WT.CLEAR))
		var intensity: float = float(result.get("intensity", 0.0))
		# 把 weather 状态写到 current_state（weather/intensity 仍是离散字段，保留字典）
		cell.current_state["weather"] = wt
		cell.current_state["weather_intensity"] = intensity
		# 应用临时湿度 / 温度扰动（不写回 base_*）
		# Fast-tick perf opt (C)：moisture / temperature 已升级为强类型成员，直接读写。
		var moist_now: float = cell.moisture
		var temp_now: float = cell.temperature
		if host._weather_direct_moisture_enabled:
			moist_now = clampf(moist_now + WeatherType.moisture_delta(wt) * intensity, 0.0, 1.0)
		var weather_temp_delta: float = clampf(WeatherType.temp_delta(wt) * intensity, -host._weather_temp_anomaly_cap, host._weather_temp_anomaly_cap)
		temp_now = clampf(temp_now + weather_temp_delta, 0.0, 1.0)
		# [perf 2026-05-20] 删除 cell.moisture = / cell.temperature = 单点 setter。
		# 这里循环 2400 次，每次走 facade setter → world.write_f32 → _dirty_mark_one 风暴，
		# 把 _dirty_cell_mask 标成全 1。下面的批量数组 _wd_moist / _wd_temp + 末尾
		# write_f32_indexed 已经完整 commit（含 dirty range 标记），单点 setter 是冗余写。
		# 若 facade 未启用 → fallback 回单点 setter（保 backing 同步）。
		if host._data_core_world == null:
			cell.moisture = moist_now
			cell.temperature = temp_now
		# PR-2.1.6：收集 dirty entry。
		if cell.index >= 0 and _wd_w < _wd_n:
			_wd_idx[_wd_w] = int(cell.index)
			_wd_moist[_wd_w] = moist_now
			_wd_temp[_wd_w] = temp_now
			_wd_w += 1
		# 临时覆盖物：FLOODING 仍走即时写入；SNOW 改走 host._apply_snow_accumulation 累积式# 临时覆盖物：FLOODING 仍走即时写入；SNOW 改走 _apply_snow_accumulation 累积式
		# 累积式好处：(1) 雪不再随单帧 BLIZZARD 闪烁出现；(2) 温升时按节律消融
		var is_water_cell: bool = LandformType.is_water(cell.landform) or host._is_water_terrain(int(cell.terrain))
		if not is_water_cell:
			# 1) 雪：累积 / 融化
			if host._apply_snow_accumulation(cell, wt, temp_now, intensity):
				host._cover_dirty = true
			# 2) 洪涝：保留即时写入。放宽条件 + 高强度直接淹（让暴雨真的导致洪涝）
			# 修：原条件 intensity>0.4 + elev<0.55 + moist>0.65 太严，从未触发
			# 现：低洼+中强度，或任意海拔下的极端暴雨都能淹
			if cell.cover != CoverType.CV.SNOW and WeatherType.can_form_flood(wt):
				var precip_now: float = float(cell.current_state.get("weather_precip", 0.0))
				var heavy_flood: bool = intensity > 0.55 and precip_now > 0.55  # 极端暴雨：任意海拔
				var lowland_flood: bool = intensity > 0.32 and cell.elevation < 0.50 and moist_now > 0.60
				if (heavy_flood or lowland_flood) and cell.cover != CoverType.CV.FLOODING:
					cell.cover = CoverType.CV.FLOODING
					cell.current_state["cover"] = int(cell.cover)
					host._cover_dirty = true
				elif cell.cover == CoverType.CV.FLOODING and not heavy_flood and not lowland_flood and moist_now < 0.50:
					# Stage8 修"洪泛不退→与旱灾共存"：积水在干燥(无致洪条件且 moist<0.50)时退去，恢复 NONE。
					cell.cover = CoverType.CV.NONE
					cell.current_state["cover"] = int(cell.cover)
					host._cover_dirty = true

	# PR-2.1.6（weather → climate 反馈写路径下移）：循环结束后批量提交 cell.moisture / cell.temperature 到 DCWorld。
	if host._data_core_world != null and _wd_w > 0:
		_wd_idx.resize(_wd_w)
		_wd_moist.resize(_wd_w)
		_wd_temp.resize(_wd_w)
		var _cid_md: int = host._data_core_world.component_id(DCComponentIds.CELL_MOISTURE)
		if _cid_md >= 0:
			host._data_core_world.write_f32_indexed(_cid_md, _wd_idx, _wd_moist)
		var _cid_td: int = host._data_core_world.component_id(DCComponentIds.CELL_TEMP)
		if _cid_td >= 0:
			host._data_core_world.write_f32_indexed(_cid_td, _wd_idx, _wd_temp)
		# [DIAG mask_dirty=2400 排查 · 2026-05-20] 前 5 次 + 之后每 50 次打一次
		host._diag_wd_commit_count += 1
		if host._diag_wd_commit_count <= 5 or (host._diag_wd_commit_count % 50) == 0:
			print("[DIAG weather_wd_commit] #%d wrote %d cells (moist+temp)" % [host._diag_wd_commit_count, _wd_w])


func _summer_snow_melt_bonus(host, heat_input: float, elevation: float) -> float:
	var sun: float = smoothstep(0.55, 0.90, clampf(heat_input, 0.0, 1.0))
	var high_elev: float = smoothstep(0.62, 0.95, clampf(elevation, 0.0, 1.0))
	return sun * (1.0 - high_elev * 0.60) * 0.045


func _snowline_floor_for_cell(host, temp_now: float, heat_input: float, elevation: float) -> float:
	if host._snowline_temp_threshold <= 0.0:
		return 0.0
	var sun: float = smoothstep(0.45, 0.85, clampf(heat_input, 0.0, 1.0))
	var high_elev: float = smoothstep(0.60, 0.95, clampf(elevation, 0.0, 1.0))
	var summer_drop: float = sun * lerpf(0.14, 0.045, high_elev)
	var elev_bonus: float = clampf((elevation - host.SNOW_ELEV_NEUTRAL) * 0.10, 0.0, 0.08)
	var effective_threshold: float = host._snowline_temp_threshold + elev_bonus - summer_drop
	var raw_floor: float = clampf((effective_threshold - temp_now) / maxf(host._snowline_band, 0.001), 0.0, 1.0)
	# Stage4(2026-06-23): 雪线 floor 只为「深冻区」自动铺白；雪线边缘(floor 弱)交给 snowpack-from-snowfall，
	# 让降雪可见地先于积雪(修"雪盖先于降雪")。smoothstep(0.30,0.80) 截掉最弱的暖侧雪线 floor。镜像 world_ext.cpp。
	return smoothstep(0.30, 0.80, raw_floor)


func _apply_snow_accumulation(host, cell: HexCell, wt: int, temp_now: float, intensity: float) -> bool:
	# 返回 true 表示本调用改写了 cell.cover（caller 据此设置 host._cover_dirty）。# 返回 true 表示本调用改写了 cell.cover（caller 据此设置 _cover_dirty）。
	if LandformType.is_water(cell.landform) or host._is_water_terrain(int(cell.terrain)):
		return false
	var changed: bool = false
	# 海拔偏移（雪线修正）：让高山即使 temp_now 较高也能积雪，平原相反。
	var elev_delta: float = cell.elevation - host.SNOW_ELEV_NEUTRAL
	var freeze_off: float = clampf(elev_delta * host.SNOW_ELEV_FREEZE_GAIN, -host.SNOW_ELEV_FREEZE_MAX_OFF, host.SNOW_ELEV_FREEZE_MAX_OFF)
	var melt_off: float = clampf(elev_delta * host.SNOW_ELEV_MELT_GAIN, -host.SNOW_ELEV_MELT_MAX_OFF, host.SNOW_ELEV_MELT_MAX_OFF)
	var freeze_t_local: float = host.SNOW_FREEZE_T + freeze_off
	var melt_t_local: float = host.SNOW_MELT_T + melt_off
	var snowing: bool = WeatherType.can_form_snow(wt) and temp_now < freeze_t_local and intensity > 0.4
	if snowing:
		cell.accumulated_snow_days += 1
	elif temp_now > melt_t_local:
		cell.accumulated_snow_days = max(0, cell.accumulated_snow_days - 1)
	# 升级：累积够了且当前还不是 SNOW → 备份并覆盖
	if cell.accumulated_snow_days >= host._snow_accum_days_req and cell.cover != CoverType.CV.SNOW:
		cell.pre_snow_cover = int(cell.cover)
		cell.cover = CoverType.CV.SNOW
		cell.current_state["cover"] = int(cell.cover)
		changed = true
	# 融化：累积清零且当前是 SNOW → 恢复（无备份则置 NONE）
	elif cell.accumulated_snow_days <= 0 and cell.cover == CoverType.CV.SNOW:
		var restored: int = cell.pre_snow_cover if cell.pre_snow_cover >= 0 else int(CoverType.CV.NONE)
		cell.cover = restored
		cell.current_state["cover"] = int(cell.cover)
		cell.pre_snow_cover = -1
		changed = true
	return changed

# dots-monolith-split §1.2 / PR-1：搬迁到 field_solver.gd；本端保留薄转发以兼容
# weather_system 内自我调用与外部 caller。实现入口见
# scripts/weather/field_solver.gd 的 region PR-1。

func _classify_field_weather_at(host, temp: float, vapor: float, cloud: float, cloud_water: float, precip: float, instability: float, ocean_an: float, wind_speed: float, temp_anom: float, monsoon_flux: float = 0.0, is_water: bool = false, snow_cover: float = 0.0) -> int:
	return host._classify_field_weather_core(temp, vapor, cloud, cloud_water, precip, instability, ocean_an, wind_speed, temp_anom, monsoon_flux, is_water, snow_cover)

# 涌现判据（无 season_idx，阈值由 tile_data_record_20260620_004323 实测标定）：
#   temp 已含轴倾→季节的温度结构；temp_anom=该格温度距平(异常冷暖)；wind_speed=原始风速(暴风强度)。
# 判定顺序：冰雪/暴风雪 → 强暖海/强对流风暴 → 季风 → 普通降水 → 雾 → 热浪 → 旱灾 → 晴。

func _classify_field_weather_core(host, temp: float, vapor: float, cloud: float, cloud_water: float, precip: float, instability: float, ocean_an: float, wind_speed: float, temp_anom: float, monsoon_flux: float = 0.0, is_water: bool = false, snow_cover: float = 0.0) -> int:
	# 去纬度门(2026-06-20)：分类不再使用纬度，类型边界由温度/湿度等弯曲物理场涌现，避免沿纬线的直线条带。
	var warm: bool = temp > 0.55
	# Stage3(2026-06-23): 删除 hot(temp>0.64)——热浪重定义为温度距平事件，不再用绝对高温门。
	# advective 模型下陆地 vapor/cloud 量级仅海洋的 1/5~1/30(海洋是水汽源,陆地天然干)。湿润类阈值海陆
	# 独立标定:海洋保原值(海洋天气分布已合理);陆地按实测分位下调(陆 vapor p50=.034/p90=.086,cloud
	# p50=.021/p90=.078),否则陆地 STORM/MONSOON/FOG 被"打死"全归 CLEAR/DROUGHT(用户:内陆永旱)。
	var humid_gate: float = 0.28 if is_water else 0.09
	var mp_cloud_gate: float = 0.22 if is_water else 0.12
	var mp_vapor_gate: float = 0.28 if is_water else 0.09
	var monsoon_vapor: float = 0.40 if is_water else 0.14
	var monsoon_precip: float = 0.055 if is_water else 0.065
	var monsoon_cloud: float = 0.45 if is_water else 0.24
	# B4(2026-06-28) FOG 门重标到实测云分位：原 cloud 门(陆 0.18≈p86 / 海 0.14≈p96)高于云场常态→冷湿
	# 阴天恒落 CLEAR(实测 FOG≈0%，68.5% 格全程不换类型)。改 cloud 门到 陆 0.10(≈p77)/海 0.085(≈p83)+
	# 海 vapor 门 0.34→0.22，让海洋性/温带阴雾天按地理涌现(冷湿多云非降水格→FOG)。镜像 world_ext_internal.h。
	var fog_vapor: float = 0.22 if is_water else 0.16
	var fog_cloud: float = 0.085 if is_water else 0.10
	var humid: bool = vapor > humid_gate
	var effective_cloud: float = maxf(cloud, cloud_water * 1.25)
	var precip_cloud_mass: float = maxf(cloud_water, precip * 0.70)
	# 降水判据回归单阈值(2026-06-20 根因重构)：precip 已是带时间惯性的 EMA 状态量(见 field_solver/
	# world_ext)，逐tick平滑由场层惯性提供，分类不再需要滞回/拖尾补丁。precip>0.030 或 中等降水+厚云
	# 高湿即算"有效降水"。
	var precip_gate: float = 0.032 if is_water else 0.040
	var weak_precip_gate: float = 0.022 if is_water else 0.030
	var meaningful_precip: bool = precip > precip_gate or (precip > weak_precip_gate and effective_cloud > mp_cloud_gate and precip_cloud_mass > mp_cloud_gate * 0.35 and vapor > mp_vapor_gate)

	# 1) 冰雪 / 暴风雪：极冷(temp≤FREEZE)+可观降水 → 直接暴雪（极地降水本就是冰雪）。
	#    过渡带(FREEZE~MELT)+降水 → 仅当大风(wind_speed>门)才算"暴风雪"，风弱则视为冷雨落到 RAIN。
	#    修前：整条过渡带冷降水无差别判暴雪 → 高纬湿润海洋一片白(实测海面 17%)。
	if host._cold_precip_as_blizzard and meaningful_precip:
		if temp <= host.SNOW_FREEZE_T:
			return WeatherType.WT.BLIZZARD
		if not is_water and snow_cover >= 0.25 and temp < host.SNOW_MELT_T + host._snow_classification_margin:
			return WeatherType.WT.BLIZZARD
		if temp < host.SNOW_MELT_T + host._snow_classification_margin \
				and effective_cloud > 0.18 and vapor > 0.20 and precip > 0.04 \
				and wind_speed > host.BLIZZARD_WIND_GATE:
			return WeatherType.WT.BLIZZARD
	# 2) 强对流风暴：暖湿 + 高不稳定 + 强降水；暖洋异常核心强制成 STORM。
	#    去硬纬度门(原 lat_abs<0.70)——warm(temp>0.55) 已把 STORM 限制在暖区，类型边界改由弯曲的
	#    等温线决定，消除"沿纬线的数学直线天气带"(用户反馈的不科学条带)。实测 STORM inst p50≈0.65。
	# Stage6h: STORM 阈大幅提高(雷暴应是少数强对流)。原 instability>0.50 被 47% 的 RAIN 格满足→STORM≈RAIN 数量、
	# 且与 RAIN 在 0.50 阈两侧逐 tick 横跳。提到 0.70(RAIN p90=0.76→仅最强对流入选)+ precip 0.05→0.065。
	var warm_ocean_core: bool = is_water and ocean_an > 0.05 and instability > 0.64 and precip > 0.060 and effective_cloud > 0.24 and precip_cloud_mass > 0.045
	if warm and humid and ((instability > 0.70 and precip > 0.065 and precip_cloud_mass > 0.050) or warm_ocean_core):
		return WeatherType.WT.STORM
	# 3) 季风：暖 + 季风湿通量/大尺度高湿 + 持续降水 + 厚云。暖海强对流核心先归 STORM，
	#    季风保留给沿岸/上岸的持续雨带，避免台风种子被 MONSOON 抢占。
	var monsoon_driver: float = maxf(monsoon_flux, smoothstep(monsoon_vapor * 0.78, monsoon_vapor + 0.06, vapor) * 0.24)
	var sustained_precip: bool = precip > monsoon_precip * 0.82 and precip_cloud_mass > monsoon_cloud * 0.38
	var monsoon_flux_gate: float = 0.08 if is_water else 0.13
	var inland_monsoon_plume: bool = (not is_water) and vapor > 0.24 and wind_speed > 0.75 and precip > monsoon_precip and precip_cloud_mass > monsoon_cloud * 0.45
	var monsoon_flow_gate: bool = monsoon_driver > monsoon_flux_gate or inland_monsoon_plume
	if warm and sustained_precip and effective_cloud > monsoon_cloud * 0.82 and monsoon_flow_gate:
		return WeatherType.WT.MONSOON
	# 4) 普通降水（含被降级的过渡带冷雨）。
	if meaningful_precip:
		return WeatherType.WT.RAIN
	# 5) 雾：高湿低降水、偏凉。单阈 cloud>0.14（FOG 闪烁由 EMA 平滑后的 cloud/precip 场自然消除）。
	if vapor > fog_vapor and effective_cloud > fog_cloud and precip < 0.030 and temp < 0.55:
		return WeatherType.WT.FOG
	# 6) 旱灾(2026-06-28 重标定)：暖 + 显著正温度距平 + 几乎无降水 + 少云。原门 temp_anom>0.10 高于陆地
	#    距平【最大值】(实测 tile_data_record_20260628 陆地 temp_anomaly max=0.0998 / p90=0.050)→恒不可达
	#    (实测占比 0%)。改 0.05(≈陆地 p90)：bone-dry 候选约 22% 达标→旱灾恢复(~2.3%)。镜像 world_ext_internal.h。
	if (not is_water) and temp > 0.55 and temp_anom > 0.05 and precip < 0.006 and effective_cloud < 0.18:
		return WeatherType.WT.DROUGHT
	# 7) 热浪(2026-06-28 重标定)：恢复气象学定义=显著正温度距平的暖事件。原"暖+干"无距平门 → 普通暖干陆地
	#    恒成立(实测当前热浪格 temp_anomaly 均值仅 0.0045≈0,即把常态暖干地误判热浪→实测热浪 6.7%过多)。
	#    加 temp_anom>0.04 门(≈陆地 p87)：仅保留约 6% 真·暖距平干热格(热浪 6.7%→~0.4%)。镜像 world_ext_internal.h。
	if (not is_water) and warm and temp_anom > 0.04 and precip < 0.012 and effective_cloud < 0.24 and vapor < 0.12:
		return WeatherType.WT.HEATWAVE
	return WeatherType.WT.CLEAR



func _is_precip_weather_type(host, wt: int) -> bool:
	return wt == WeatherType.WT.RAIN \
		or wt == WeatherType.WT.STORM \
		or wt == WeatherType.WT.BLIZZARD \
		or wt == WeatherType.WT.MONSOON



func _weather_precip_terrain_damping_factor(host, terrain: int) -> float:
	# Stage8 (2026-06-23) 用户:雨团绕着湖/山/盆地走、湿润地形不下雨。原设定把恰恰最该多雨的地形(雨林/
	# 地形抬升坡/湿地)的降水压低——方向反了。JUNGLE/HILL 应多雨故归 0；湿地仅轻微阻尼防过湿。镜像 world_ext.cpp。
	match terrain:
		TerrainType.TERRAIN.LAKE:
			return 0.50
		TerrainType.TERRAIN.DELTA:
			return 0.40
		TerrainType.TERRAIN.SWAMP:
			return 0.30
		TerrainType.TERRAIN.JUNGLE:
			return 0.0
		TerrainType.TERRAIN.HILL:
			return 0.0
		_:
			return 0.0



func _moderate_field_precip_for_terrain(host, terrain: int, precip: float) -> float:
	var out: float = clampf(precip, 0.0, 1.0)
	var factor: float = host._weather_precip_terrain_damping_factor(terrain)
	if factor > 0.0 and out > 0.08:
		var damp: float = host._field_lake_precip_damping if terrain == TerrainType.TERRAIN.LAKE else host._field_wet_terrain_precip_damping
		out -= (out - 0.08) * clampf(damp, 0.0, 1.0) * factor
	var cap: float = clampf(host._field_extreme_precip_soft_cap, 0.0, 1.0)
	if cap > 0.0 and out > cap:
		out = cap + (out - cap) * clampf(host._field_extreme_precip_softness, 0.0, 1.0)
	return clampf(out, 0.0, 1.0)



func _field_intensity_for_type(host, wt: int, temp: float, vapor: float, cloud: float, precip: float, instability: float, ocean_an: float) -> float:
	match wt:
		WeatherType.WT.STORM:
			return clampf(maxf(precip, instability) * 0.82 + cloud * 0.18, 0.0, 1.0)
		WeatherType.WT.MONSOON:
			return clampf(precip * 0.72 + vapor * 0.18 + cloud * 0.18, 0.0, 1.0)
		WeatherType.WT.RAIN, WeatherType.WT.BLIZZARD:
			return clampf(precip * 1.15 + cloud * 0.20, 0.0, 1.0)
		WeatherType.WT.FOG:
			return clampf(cloud * 0.75 + vapor * 0.20, 0.0, 1.0)
		WeatherType.WT.HEATWAVE:
			return clampf((temp - 0.65) * 2.2 + maxf(0.32 - vapor, 0.0), 0.0, 1.0)
		WeatherType.WT.DROUGHT:
			return clampf((0.35 - vapor) * 2.0 + (0.16 - cloud) + maxf(-ocean_an, 0.0) * 0.6, 0.0, 1.0)
	return 0.0


func _distribute_weather_field_to_cells_legacy(host, map: MapData) -> void:
	host._cover_dirty = false

	var cells: Array = map.iter_cells() if map.has_indices() else map.all_cells()
	# [perf 2026-05-20] 同 host._distribute_to_cells：累积到批量数组，末尾 write_f32_indexed。# [perf 2026-05-20] 同 _distribute_to_cells：累积到批量数组，末尾 write_f32_indexed。
	# 原循环里 cell.moisture / cell.temperature 单点 setter 会导致 _dirty_mark_one 风暴
	# （N 次单点 mark → mask 全 1 → atlas_upload 退化为全推）。
	var _wfd_n: int = cells.size()
	var _wfd_idx: PackedInt32Array = PackedInt32Array()
	var _wfd_moist: PackedFloat32Array = PackedFloat32Array()
	var _wfd_temp: PackedFloat32Array = PackedFloat32Array()
	var _wfd_env_idx: PackedInt32Array = PackedInt32Array()
	var _wfd_snow_cover: PackedFloat32Array = PackedFloat32Array()
	var _wfd_snowpack: PackedFloat32Array = PackedFloat32Array()
	var _wfd_water_balance: PackedFloat32Array = PackedFloat32Array()
	var _wfd_soil: PackedFloat32Array = PackedFloat32Array()
	_wfd_idx.resize(_wfd_n)
	_wfd_moist.resize(_wfd_n)
	_wfd_temp.resize(_wfd_n)
	_wfd_env_idx.resize(_wfd_n)
	_wfd_snow_cover.resize(_wfd_n)
	_wfd_snowpack.resize(_wfd_n)
	_wfd_water_balance.resize(_wfd_n)
	_wfd_soil.resize(_wfd_n)
	var _wfd_w: int = 0
	var _wfd_env_w: int = 0
	var has_snowpack_arr: bool = map.snowpack_arr.size() == _wfd_n
	var has_water_balance_arr: bool = map.water_balance_30d_arr.size() == _wfd_n
	var has_soil_arr: bool = map.soil_moisture_arr.size() == _wfd_n
	var has_snow_arr: bool = map.snow_cover_arr.size() == _wfd_n
	var has_heat_arr: bool = map.heat_input_arr.size() == _wfd_n
	for cell: HexCell in cells:
		var idx: int = int(cell.index)
		var is_water_cell: bool = LandformType.is_water(cell.landform) or host._is_water_terrain(int(cell.terrain))
		var wt: int = cell.weather_type if cell.weather_field_initialized else WeatherType.WT.CLEAR
		var intensity: float = cell.weather_intensity if cell.weather_field_initialized else 0.0
		var raw_precip: float = cell.weather_precip if cell.weather_field_initialized else 0.0
		var precip: float = raw_precip if host._is_precip_weather_type(wt) else 0.0
		var moist_now: float = cell.moisture
		var temp_now: float = cell.temperature
		if wt == WeatherType.WT.CLEAR or intensity <= 0.001:
			if not is_water_cell \
					and (cell.accumulated_snow_days > 0 or cell.cover == CoverType.CV.SNOW):
				if host._apply_snow_accumulation(cell, wt, cell.temperature, 0.0):
					host._cover_dirty = true
			if idx >= 0 and idx < _wfd_n:
				var clear_sp: float = map.snowpack_arr[idx] if has_snowpack_arr else clampf(cell.snow_cover * 0.35, 0.0, 1.0)
				var clear_wb: float = map.water_balance_30d_arr[idx] if has_water_balance_arr else 0.0
				var clear_soil: float = map.soil_moisture_arr[idx] if has_soil_arr else cell.soil_moisture
				var clear_heat: float = map.heat_input_arr[idx] if has_heat_arr else 0.0
				if is_water_cell:
					clear_sp = 0.0
					clear_wb = lerpf(clear_wb, 0.0, 1.0 / 30.0)
				else:
					var clear_elev_delta: float = cell.elevation - host.SNOW_ELEV_NEUTRAL
					var clear_freeze_off: float = clampf(clear_elev_delta * host.SNOW_ELEV_FREEZE_GAIN, -host.SNOW_ELEV_FREEZE_MAX_OFF, host.SNOW_ELEV_FREEZE_MAX_OFF)
					var clear_melt_off: float = clampf(clear_elev_delta * host.SNOW_ELEV_MELT_GAIN, -host.SNOW_ELEV_MELT_MAX_OFF, host.SNOW_ELEV_MELT_MAX_OFF)
					var clear_freeze_t: float = host.SNOW_FREEZE_T + clear_freeze_off
					var clear_melt_t: float = host.SNOW_MELT_T + clear_melt_off
					var clear_melt: float = maxf(temp_now - clear_melt_t, 0.0) * host._snowpack_melt_temp_gain + clear_heat * host._snowpack_melt_sun_gain + host._summer_snow_melt_bonus(clear_heat, cell.elevation)
					var clear_cold_precip: bool = temp_now < clear_freeze_t and precip > 0.002
					var clear_snow_accum: float = precip * host._snowpack_accum_gain * 0.75 if clear_cold_precip else 0.0
					if clear_cold_precip:
						clear_snow_accum += minf(intensity, 0.15) * 0.006
					clear_sp = clampf(clear_sp + clear_snow_accum - clear_melt, 0.0, 1.0)
					if cell.cover == CoverType.CV.GLACIER and clear_sp < 0.80:
						clear_sp = 0.80
					var clear_evap: float = clampf((0.01 + maxf(moist_now - 0.45, 0.0) * 0.03) * (0.35 + temp_now * 1.05) * 0.65, 0.0, 1.0)
					var clear_runoff: float = maxf(moist_now - 0.82, 0.0) * 0.25 + maxf(cell.elevation - 0.70, 0.0) * precip * 0.06
					var clear_daily_balance: float = clampf(precip - clear_evap - clear_runoff, -1.0, 1.0)
					clear_wb = lerpf(clear_wb, clear_daily_balance, 1.0 / 30.0)
					# climate-loop-closure Phase 3.1：土壤水每日衰减(×0.97,~33日时间常数)，
					# 使停雨后土壤能排干、持续小雨区不再单调累积到 +0.5 上限(诊断实测根因)。
					clear_soil = clampf(clear_soil * 0.97 + clear_daily_balance * 0.08, -0.5, 0.5)
					var clear_moist: float = moist_now
					if host._weather_direct_moisture_enabled:
						clear_moist = clampf(moist_now + precip * 0.35 + maxf(clear_daily_balance, 0.0) * 0.04, 0.0, 1.0)
					if host._data_core_world == null:
						cell.moisture = clear_moist
					elif _wfd_w < _wfd_n:
						_wfd_idx[_wfd_w] = idx
						_wfd_moist[_wfd_w] = clear_moist
						_wfd_temp[_wfd_w] = temp_now
						_wfd_w += 1
				# climate-loop-closure Phase 2.1/2.2：气候态物理雪线 floor（仅陆地）。
				# 冷区即便无降水也按当前温度获得基线雪盖；雪线随海拔/季节自然升降。
				if host._snowline_temp_threshold > 0.0 and not is_water_cell:
					var clear_floor: float = host._snowline_floor_for_cell(temp_now, clear_heat, cell.elevation)
					if clear_floor > 0.0:
						clear_sp = maxf(clear_sp, clear_floor * host._snowpack_cover_full)
				var clear_sc: float = smoothstep(host._snowpack_cover_low, host._snowpack_cover_full, clear_sp)
				if host._snowline_temp_threshold > 0.0 and not is_water_cell:
					clear_sc = maxf(clear_sc, host._snowline_floor_for_cell(temp_now, clear_heat, cell.elevation))
				if cell.cover == CoverType.CV.GLACIER and clear_sc < 0.80:
					clear_sc = 0.80
				if has_snowpack_arr: map.snowpack_arr[idx] = clear_sp
				if has_snow_arr: map.snow_cover_arr[idx] = clear_sc
				if has_water_balance_arr: map.water_balance_30d_arr[idx] = clear_wb
				if has_soil_arr: map.soil_moisture_arr[idx] = clear_soil
				_wfd_env_idx[_wfd_env_w] = idx
				_wfd_snow_cover[_wfd_env_w] = clear_sc
				_wfd_snowpack[_wfd_env_w] = clear_sp
				_wfd_water_balance[_wfd_env_w] = clear_wb
				_wfd_soil[_wfd_env_w] = clear_soil
				_wfd_env_w += 1
			continue

		moist_now = cell.moisture
		if host._weather_direct_moisture_enabled:
			moist_now = clampf(moist_now + WeatherType.moisture_delta(wt) * intensity + precip * 0.35, 0.0, 1.0)
		var weather_temp_delta: float = clampf(WeatherType.temp_delta(wt) * intensity, -host._weather_temp_anomaly_cap, host._weather_temp_anomaly_cap)
		temp_now = clampf(cell.temperature + weather_temp_delta, 0.0, 1.0)
		# [perf] 删除单点 setter；累积到批量数组（fallback 时仍走 setter 兜 backing）
		if host._data_core_world == null:
			cell.moisture = moist_now
			cell.temperature = temp_now
		if cell.index >= 0 and _wfd_w < _wfd_n:
			_wfd_idx[_wfd_w] = idx
			_wfd_moist[_wfd_w] = moist_now
			_wfd_temp[_wfd_w] = temp_now
			_wfd_w += 1

		if idx >= 0 and idx < _wfd_n:
			var sp_now: float = map.snowpack_arr[idx] if has_snowpack_arr else clampf(cell.snow_cover * 0.35, 0.0, 1.0)
			var prev_sp: float = sp_now
			var wb_now: float = map.water_balance_30d_arr[idx] if has_water_balance_arr else 0.0
			var soil_now: float = map.soil_moisture_arr[idx] if has_soil_arr else cell.soil_moisture
			var snow_cover_now: float = 0.0
			var heat_input: float = map.heat_input_arr[idx] if has_heat_arr else 0.0
			if is_water_cell:
				sp_now = 0.0
				wb_now = lerpf(wb_now, 0.0, 1.0 / 30.0)
			else:
				var elev_delta: float = cell.elevation - host.SNOW_ELEV_NEUTRAL
				var freeze_off: float = clampf(elev_delta * host.SNOW_ELEV_FREEZE_GAIN, -host.SNOW_ELEV_FREEZE_MAX_OFF, host.SNOW_ELEV_FREEZE_MAX_OFF)
				var melt_off: float = clampf(elev_delta * host.SNOW_ELEV_MELT_GAIN, -host.SNOW_ELEV_MELT_MAX_OFF, host.SNOW_ELEV_MELT_MAX_OFF)
				var freeze_t_local: float = host.SNOW_FREEZE_T + freeze_off
				var melt_t_local: float = host.SNOW_MELT_T + melt_off
				var precip_can_snow: bool = wt != WeatherType.WT.DROUGHT and wt != WeatherType.WT.HEATWAVE and wt != WeatherType.WT.CLEAR
				var snowing: bool = (WeatherType.can_form_snow(wt) or precip_can_snow) and temp_now < freeze_t_local and precip > 0.0
				var snow_accum: float = precip * host._snowpack_accum_gain if snowing else 0.0
				if snowing:
					snow_accum += intensity * 0.015
				var warm_rain_melt: float = precip * 0.03 if temp_now > melt_t_local else 0.0
				var melt: float = maxf(temp_now - melt_t_local, 0.0) * host._snowpack_melt_temp_gain + heat_input * host._snowpack_melt_sun_gain + host._summer_snow_melt_bonus(heat_input, cell.elevation) + warm_rain_melt
				sp_now = clampf(sp_now + snow_accum - melt, 0.0, 1.0)
				if cell.cover == CoverType.CV.GLACIER and sp_now < 0.80:
					sp_now = 0.80
				var meltwater: float = maxf(prev_sp - sp_now, 0.0)
				var runoff: float = maxf(moist_now - 0.82, 0.0) * 0.25 + maxf(cell.elevation - 0.70, 0.0) * precip * 0.06
				var evap_proxy: float = clampf((0.01 + maxf(moist_now - 0.45, 0.0) * 0.03) * (0.35 + temp_now * 1.05) * 0.65, 0.0, 1.0)
				var daily_balance: float = clampf(precip * 1.15 + meltwater * 0.65 - evap_proxy - runoff, -1.0, 1.0)
				wb_now = lerpf(wb_now, daily_balance, 1.0 / 30.0)
				# climate-loop-closure Phase 3.1：土壤水每日衰减(见 clear 分支同段注释)。
				soil_now = clampf(soil_now * 0.97 + daily_balance * 0.08, -0.5, 0.5)
			# climate-loop-closure Phase 2.1/2.2：气候态物理雪线 floor（仅陆地）。
			if host._snowline_temp_threshold > 0.0 and not is_water_cell:
				var snow_floor: float = host._snowline_floor_for_cell(temp_now, heat_input, cell.elevation)
				if snow_floor > 0.0:
					sp_now = maxf(sp_now, snow_floor * host._snowpack_cover_full)
			snow_cover_now = smoothstep(host._snowpack_cover_low, host._snowpack_cover_full, sp_now)
			if host._snowline_temp_threshold > 0.0 and not is_water_cell:
				snow_cover_now = maxf(snow_cover_now, host._snowline_floor_for_cell(temp_now, heat_input, cell.elevation))
			if cell.cover == CoverType.CV.GLACIER and snow_cover_now < 0.80:
				snow_cover_now = 0.80
			if has_snowpack_arr: map.snowpack_arr[idx] = sp_now
			if has_snow_arr: map.snow_cover_arr[idx] = snow_cover_now
			if has_water_balance_arr: map.water_balance_30d_arr[idx] = wb_now
			if has_soil_arr: map.soil_moisture_arr[idx] = soil_now
			_wfd_env_idx[_wfd_env_w] = idx
			_wfd_snow_cover[_wfd_env_w] = snow_cover_now
			_wfd_snowpack[_wfd_env_w] = sp_now
			_wfd_water_balance[_wfd_env_w] = wb_now
			_wfd_soil[_wfd_env_w] = soil_now
			_wfd_env_w += 1

		if not is_water_cell:
			# 雪：累积式（同 fronts 路径，避免两条分支不一致）
			if host._apply_snow_accumulation(cell, wt, temp_now, intensity):
				host._cover_dirty = true
			# 洪涝：放宽条件 + 高强度直接淹（与 fronts 路径同步）
			if cell.cover != CoverType.CV.SNOW and WeatherType.can_form_flood(wt):
				var heavy_flood: bool = intensity > 0.55 and precip > 0.55
				var lowland_flood: bool = intensity > 0.32 and cell.elevation < 0.50 and moist_now > 0.60
				if (heavy_flood or lowland_flood) and cell.cover != CoverType.CV.FLOODING:
					cell.cover = CoverType.CV.FLOODING
					cell.current_state["cover"] = int(cell.cover)
					host._cover_dirty = true
			# Stage8 退水：不受 can_form_flood 门限制(故 DROUGHT/CLEAR 也能退)→修"洪泛与旱灾共存"。干燥时积水退去。
			if cell.cover == CoverType.CV.FLOODING and moist_now < 0.50 and precip < 0.04:
				cell.cover = CoverType.CV.NONE
				cell.current_state["cover"] = int(cell.cover)
				host._cover_dirty = true

	# [perf] 末尾批量 commit moisture / temperature 到 DCWorld（一次性 mark dirty）
	if host._data_core_world != null and _wfd_w > 0:
		_wfd_idx.resize(_wfd_w)
		_wfd_moist.resize(_wfd_w)
		_wfd_temp.resize(_wfd_w)
		var _cid_md_f: int = host._data_core_world.component_id(DCComponentIds.CELL_MOISTURE)
		if _cid_md_f >= 0:
			host._data_core_world.write_f32_indexed(_cid_md_f, _wfd_idx, _wfd_moist)
		var _cid_td_f: int = host._data_core_world.component_id(DCComponentIds.CELL_TEMP)
		if _cid_td_f >= 0:
			host._data_core_world.write_f32_indexed(_cid_td_f, _wfd_idx, _wfd_temp)
	if host._data_core_world != null and _wfd_env_w > 0:
		_wfd_env_idx.resize(_wfd_env_w)
		_wfd_snow_cover.resize(_wfd_env_w)
		_wfd_snowpack.resize(_wfd_env_w)
		_wfd_water_balance.resize(_wfd_env_w)
		_wfd_soil.resize(_wfd_env_w)
		var _cid_sc_f: int = host._data_core_world.component_id(DCComponentIds.CELL_SNOW_COVER)
		if _cid_sc_f >= 0:
			host._data_core_world.write_f32_indexed(_cid_sc_f, _wfd_env_idx, _wfd_snow_cover)
		var _cid_sp_f: int = host._data_core_world.component_id(DCComponentIds.CELL_SNOWPACK)
		if _cid_sp_f >= 0:
			host._data_core_world.write_f32_indexed(_cid_sp_f, _wfd_env_idx, _wfd_snowpack)
		var _cid_wb_f: int = host._data_core_world.component_id(DCComponentIds.CELL_WATER_BALANCE_30D)
		if _cid_wb_f >= 0:
			host._data_core_world.write_f32_indexed(_cid_wb_f, _wfd_env_idx, _wfd_water_balance)
		var _cid_sm_f: int = host._data_core_world.component_id(DCComponentIds.CELL_SOIL_MOISTURE)
		if _cid_sm_f >= 0:
			host._data_core_world.write_f32_indexed(_cid_sm_f, _wfd_env_idx, _wfd_soil)


func distribute(map: MapData) -> void:
	if _weather_system == null or map == null:
		return
	_weather_system._distribute_weather_field_to_cells_legacy(map)

func apply_cover_overrides(map: MapData) -> void:
	distribute(map)

func describe() -> String:
	return "DCWeatherFeedback(owner=%s)" % ("ws" if _weather_system != null else "(null)")
