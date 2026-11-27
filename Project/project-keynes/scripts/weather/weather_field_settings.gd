extends RefCounted

## Sets weather field and coupling parameters and records pass timings.

static func _percentile_abs_from_array(weather: WeatherSystem, values: PackedFloat32Array, q: float) -> float:
	var n: int = values.size()
	if n <= 0:
		return 0.0
	var sorted: Array[float] = []
	sorted.resize(n)
	for i in range(n):
		sorted[i] = absf(values[i])
	sorted.sort()
	var qi: int = clampi(int(floor(float(n - 1) * clampf(q, 0.0, 1.0))), 0, n - 1)
	return float(sorted[qi])

# --- 初始化 ---


static func push_dist_perf_sample(weather: WeatherSystem, elapsed_ms: float) -> void:
	weather._dist_recent_ms.append(elapsed_ms)
	if weather._dist_recent_ms.size() > weather._PERF_RING_SIZE:
		weather._dist_recent_ms.remove_at(0)
	var threshold: float = weather._DIST_PERF_BUDGET_MS * weather._PERF_BUDGET_MULTIPLIER
	if weather._dist_recent_ms.size() >= weather._PERF_RING_SIZE:
		var all_over: bool = true
		for v in weather._dist_recent_ms:
			if v <= threshold:
				all_over = false
				break
		if all_over and not weather._dist_regression_warned:
			weather._dist_regression_warned = true
			push_warning("[weather/dist] perf regression: last %d ticks all > %.2fms (budget %.2fms × %.1f)" % [
				weather._PERF_RING_SIZE, threshold, weather._DIST_PERF_BUDGET_MS, weather._PERF_BUDGET_MULTIPLIER
			])
		elif (not all_over) and weather._dist_regression_warned:
			# 性能恢复，下次回归时还能再警告一次
			weather._dist_regression_warned = false


static func push_summary_perf_sample(weather: WeatherSystem, elapsed_ms: float) -> void:
	weather._summary_recent_ms.append(elapsed_ms)
	if weather._summary_recent_ms.size() > weather._PERF_RING_SIZE:
		weather._summary_recent_ms.remove_at(0)
	var threshold: float = weather._SUMMARY_PERF_BUDGET_MS * weather._PERF_BUDGET_MULTIPLIER
	if weather._summary_recent_ms.size() >= weather._PERF_RING_SIZE:
		var all_over: bool = true
		for v in weather._summary_recent_ms:
			if v <= threshold:
				all_over = false
				break
		if all_over and not weather._summary_regression_warned:
			weather._summary_regression_warned = true
			push_warning("[weather/summary] perf regression: last %d ticks all > %.2fms (budget %.2fms × %.1f)" % [
				weather._PERF_RING_SIZE, threshold, weather._SUMMARY_PERF_BUDGET_MS, weather._PERF_BUDGET_MULTIPLIER
			])
		elif (not all_over) and weather._summary_regression_warned:
			weather._summary_regression_warned = false

# Emergent Climate Coupling：由 MapGenerator 在 refresh_daily 之前调用。
# 启用时 tick_one_day 内会做 4 项耦合：
#   1. 推进前按 front 中心 cell 的 local 状态调整本日 decay_per_day（类型匹配 ×0.7、不匹配 ×1.5）
#   2. 推进时如经过山脉迎风坡：本格 precip 强度叠加；经过背风坡：额外衰减
#   3. spawn 概率按本地 1 环温湿梯度加权（梯度大处更易生成 front）
#   4. spawn 类型由本地温度带、湿度带、水陆条件和实际气候异常决定。
# 关闭时保留旧 front 行为作为兼容回退，但不重新启用季节硬切气候 forcing。


static func configure_emergent_coupling(weather: WeatherSystem, enabled: bool, rain_shadow_threshold: float, rain_shadow_factor: float, orographic_boost: float) -> void:
	weather._emergent_coupling = enabled
	weather._emergent_rain_shadow_threshold = rain_shadow_threshold
	weather._emergent_rain_shadow_factor = rain_shadow_factor
	weather._emergent_orographic_boost = orographic_boost

# v11 由 MapGenerator 在初始化时推送。控制 advect / spawn 是否优先采样
# HexCell.wind_vector（地形扰动后的实际风）。


static func configure_terrain_wind(weather: WeatherSystem, enabled: bool) -> void:
	weather._use_wind_vector_for_advect = enabled

# Ocean spawn bias：由 MapGenerator 在 init/refresh_daily 推送 ClimateProfile
# 中的 ocean_weather_spawn_bias。0 = 关闭（legacy 行为），>0 = 寒流海岸抑制
# 降水类天气 spawn、暖流海岸促进。详见 _spawn_emergent_front 内的偏置公式。


static func configure_ocean_spawn_bias(weather: WeatherSystem, bias: float) -> void:
	weather._ocean_spawn_bias = maxf(0.0, bias)


static func configure_weather_field(weather: WeatherSystem,
		enabled: bool,
		advect_steps: int,
		diffusion: float,
		condensation_gain: float,
		precip_decay: float,
		orographic_lift_gain: float,
		convergence_gain: float,
		ocean_evap_gain: float,
		summary_limit: int,
		convergence_refresh_stride: int = 2,
		precip_carryover_max: float = 0.08,
		vapor_precip_sink: float = 0.85,
		snowpack_accum_gain: float = 0.08,
		snowpack_melt_temp_gain: float = 0.22,
		snowpack_melt_sun_gain: float = 0.12,
		snowpack_cover_low: float = 0.05,
		snowpack_cover_full: float = 0.32,
		snow_accum_days_req: int = 2,
		weather_temp_anomaly_cap: float = 0.025,
		snowline_temp_threshold: float = 0.24,
		snowline_band: float = 0.22,
		vapor_relax_rate: float = 0.08,
		orographic_lift_cap: float = 0.35,
		wet_terrain_precip_damping: float = 0.28,
		lake_precip_damping: float = 0.35,
		lake_evap_scale: float = 0.35,
		extreme_precip_soft_cap: float = 0.16,
		extreme_precip_softness: float = 0.20,
		land_evapotranspiration_gain: float = 0.70,
		precip_rh_threshold: float = 0.70,
		ocean_precip_suppression: float = 0.95,
		frontogenesis_gain: float = 0.42,
		rain_shadow_drying: float = 0.35,
		vapor_transport_gain: float = 0.75) -> void:
	weather._weather_field_enabled = enabled
	weather._field_advect_steps = clampi(advect_steps, 0, 8)  # 方案③ 上限 4→8
	weather._field_diffusion = clampf(diffusion, 0.0, 0.5)
	weather._field_condensation_gain = maxf(0.0, condensation_gain)
	weather._field_precip_decay = clampf(precip_decay, 0.0, 1.0)
	weather._field_precip_carryover_max = clampf(precip_carryover_max, 0.0, 1.0)
	weather._field_vapor_precip_sink = clampf(vapor_precip_sink, 0.0, 1.0)
	weather._field_vapor_relax_rate = clampf(vapor_relax_rate, 0.0, 1.0)
	weather._field_orographic_lift_gain = maxf(0.0, orographic_lift_gain)
	weather._field_orographic_lift_cap = clampf(orographic_lift_cap, 0.0, 1.0)
	weather._field_wet_terrain_precip_damping = clampf(wet_terrain_precip_damping, 0.0, 1.0)
	weather._field_lake_precip_damping = clampf(lake_precip_damping, 0.0, 1.0)
	weather._field_lake_evap_scale = clampf(lake_evap_scale, 0.0, 1.0)
	weather._field_extreme_precip_soft_cap = clampf(extreme_precip_soft_cap, 0.0, 1.0)
	weather._field_extreme_precip_softness = clampf(extreme_precip_softness, 0.0, 1.0)
	weather._field_convergence_gain = maxf(0.0, convergence_gain)
	weather._field_convergence_refresh_stride = clampi(convergence_refresh_stride, 1, 12)
	weather._field_ocean_evap_gain = maxf(0.0, ocean_evap_gain)
	weather._field_land_evapotranspiration_gain = maxf(0.0, land_evapotranspiration_gain)
	weather._field_precip_rh_threshold = clampf(precip_rh_threshold, 0.40, 0.95)
	weather._field_ocean_precip_suppression = clampf(ocean_precip_suppression, 0.0, 1.0)
	weather._field_frontogenesis_gain = maxf(0.0, frontogenesis_gain)
	weather._field_rain_shadow_drying = clampf(rain_shadow_drying, 0.0, 1.0)
	weather._field_vapor_transport_gain = clampf(vapor_transport_gain, 0.0, 1.0)
	weather._snowpack_accum_gain = clampf(snowpack_accum_gain, 0.0, 1.0)
	weather._snowpack_melt_temp_gain = clampf(snowpack_melt_temp_gain, 0.0, 1.0)
	weather._snowpack_melt_sun_gain = clampf(snowpack_melt_sun_gain, 0.0, 1.0)
	weather._snowpack_cover_low = clampf(snowpack_cover_low, 0.0, 0.5)
	weather._snowpack_cover_full = maxf(weather._snowpack_cover_low + 0.001, clampf(snowpack_cover_full, 0.0, 1.0))
	weather._snow_accum_days_req = clampi(snow_accum_days_req, 1, 8)
	weather._snowline_temp_threshold = clampf(snowline_temp_threshold, 0.0, 1.0)
	weather._snowline_band = clampf(snowline_band, 0.02, 0.6)
	weather._weather_temp_anomaly_cap = clampf(weather_temp_anomaly_cap, 0.0, 0.10)
	if weather._cp_for_front_flag != null:
		if weather._cp_for_front_flag.get("weather_cold_precip_as_blizzard") != null:
			weather._cold_precip_as_blizzard = bool(weather._cp_for_front_flag.weather_cold_precip_as_blizzard)
		if weather._cp_for_front_flag.get("weather_snow_classification_margin") != null:
			weather._snow_classification_margin = clampf(float(weather._cp_for_front_flag.weather_snow_classification_margin), 0.0, 0.12)
		if weather._cp_for_front_flag.get("weather_wet_terrain_precip_damping") != null:
			weather._field_wet_terrain_precip_damping = clampf(float(weather._cp_for_front_flag.weather_wet_terrain_precip_damping), 0.0, 1.0)
		if weather._cp_for_front_flag.get("weather_lake_precip_damping") != null:
			weather._field_lake_precip_damping = clampf(float(weather._cp_for_front_flag.weather_lake_precip_damping), 0.0, 1.0)
		if weather._cp_for_front_flag.get("weather_lake_evap_scale") != null:
			weather._field_lake_evap_scale = clampf(float(weather._cp_for_front_flag.weather_lake_evap_scale), 0.0, 1.0)
		if weather._cp_for_front_flag.get("weather_extreme_precip_soft_cap") != null:
			weather._field_extreme_precip_soft_cap = clampf(float(weather._cp_for_front_flag.weather_extreme_precip_soft_cap), 0.0, 1.0)
		if weather._cp_for_front_flag.get("weather_extreme_precip_softness") != null:
			weather._field_extreme_precip_softness = clampf(float(weather._cp_for_front_flag.weather_extreme_precip_softness), 0.0, 1.0)
		if weather._cp_for_front_flag.get("weather_land_evapotranspiration_gain") != null:
			weather._field_land_evapotranspiration_gain = maxf(0.0, float(weather._cp_for_front_flag.weather_land_evapotranspiration_gain))
		if weather._cp_for_front_flag.get("weather_precip_rh_threshold") != null:
			weather._field_precip_rh_threshold = clampf(float(weather._cp_for_front_flag.weather_precip_rh_threshold), 0.40, 0.95)
		if weather._cp_for_front_flag.get("weather_ocean_precip_suppression") != null:
			weather._field_ocean_precip_suppression = clampf(float(weather._cp_for_front_flag.weather_ocean_precip_suppression), 0.0, 1.0)
		if weather._cp_for_front_flag.get("weather_frontogenesis_gain") != null:
			weather._field_frontogenesis_gain = maxf(0.0, float(weather._cp_for_front_flag.weather_frontogenesis_gain))
		if weather._cp_for_front_flag.get("weather_rain_shadow_drying") != null:
			weather._field_rain_shadow_drying = clampf(float(weather._cp_for_front_flag.weather_rain_shadow_drying), 0.0, 1.0)
		if weather._cp_for_front_flag.get("weather_vapor_transport_gain") != null:
			weather._field_vapor_transport_gain = clampf(float(weather._cp_for_front_flag.weather_vapor_transport_gain), 0.0, 1.0)
	weather._field_summary_limit = clampi(summary_limit, 1, 12)
	if not enabled:
		weather._weather_field.clear()

# v11 风场采样统一入口：
#   - 开关为 true 且能反查到 cell 且 cell.wind_vector 足够大 → 直接返回 cell.wind_vector。
#     这是地形扰动后的 per-cell 实际风，本身已含山脈绕流、海岸热力加速和压力场响应。
#   - fallback（开关为 false / 反查失败 / wind_vector 太小）
#     C3 plan (vector_atlas removal)：原 fallback 调 world.sample_wind(pos)
#     从 wind_field_buffer 双线性采样，但 buffer 已停止 bake（is_empty）。
#     新 fallback：直接走 WindBelt.wind_at(ny, season_phase) 的纯纬度风基线。
