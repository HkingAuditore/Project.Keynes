extends RefCounted

## Stateless collaborator for ShrubLayer.

static func set_extreme_weather_ground_effect_enabled(host, v: bool) -> void:

	host.extreme_weather_ground_effect_enabled = v
	if host._shader_mat != null:
		host._push_world_uniform(
			"extreme_weather_ground_effect_enabled",
			host.extreme_weather_ground_effect_enabled
		)
	if host._weather_layer != null:
		host._weather_layer.set_extreme_weather_ground_effect_enabled(
			host.extreme_weather_ground_effect_enabled
		)


static func set_perf_sampler_enabled(host, v: bool) -> void:

	host.perf_sampler_enabled = v
	if host.perf_sampler_enabled:
		if host._perf_sampler == null:
			host._perf_sampler = host.PerfSampler.new()
			host._perf_sampler.set_label("HexRenderer")
		else:
			host._perf_sampler.reset()
	else:
		host._perf_sampler = null

# ─── Pass 2（任务 2）：apply_tod + 新增开关 setter ──────────────────────────
# 地表 shader 与 WeatherLayer 的 overlay shader。首帧必须显式调用以避免

static func apply_tod(host, profile: TODProfile) -> void:

	if profile == null:
		return
	if host._shader_mat != null:
		host._push_world_uniform("tod_sun_dir", profile.sun_dir)
		host._push_world_uniform(
			"tod_sun_color",
			Vector3(profile.sun_color.r, profile.sun_color.g, profile.sun_color.b)
		)
		host._push_world_uniform(
			"tod_ambient_color",
			Vector3(profile.ambient_color.r, profile.ambient_color.g, profile.ambient_color.b)
		)
		host._push_world_uniform("tod_night_factor", profile.night_factor)
		host._push_world_uniform("tod_exposure", profile.exposure)
	if host._weather_layer != null and host._weather_layer.has_method("apply_tod"):
		host._weather_layer.apply_tod(profile)
	# 植被/点缀层随昼夜统一着色（修复"树草常亮"）。缓存供新生成层补推。
	host._tod_sun_color = profile.sun_color
	host._tod_ambient_color = profile.ambient_color
	host._tod_night_factor = profile.night_factor
	host._tod_exposure = profile.exposure
	host._tod_sun_dir = profile.sun_dir.normalized()
	host._tod_valid = true
	if host._cloud_shadow_field != null:
		host._cloud_shadow_field.set_night_factor(host._tod_night_factor if host.day_night_enabled else 0.0)
	host._push_water_lighting_uniforms()
	if host._building_visual_layer != null:
		host._building_visual_layer.set_tod(
			host._tod_sun_color, host._tod_ambient_color, host._tod_night_factor, host._tod_exposure)
		host._building_visual_layer.set_tod_sun_dir(host._tod_sun_dir)
	host._for_each_vegetation_layer(func(layer: ShrubLayer) -> void:
		layer.set_tod(host._tod_sun_color, host._tod_ambient_color, host._tod_night_factor, host._tod_exposure)
		if layer.has_method("set_tod_sun_dir"):
			layer.set_tod_sun_dir(host._tod_sun_dir)
	)
	host._sync_detail_and_activity_materials()


static func set_rain_density_boost_enabled(host, v: bool) -> void:

	if host._weather_layer != null and host._weather_layer.has_method("set_rain_density_boost_enabled"):
		host._weather_layer.set_rain_density_boost_enabled(v)


static func set_cloud_tod_tint_enabled(host, v: bool) -> void:

	host.cloud_tod_tint_enabled = v
	if host._shader_mat != null:
		host._push_world_uniform("cloud_tod_tint_enabled", host.cloud_tod_tint_enabled)
	if host._weather_layer != null and host._weather_layer.has_method("set_cloud_tod_tint_enabled"):
		host._weather_layer.set_cloud_tod_tint_enabled(v)



static func set_day_night_enabled(host, v: bool) -> void:

	host.day_night_enabled = v
	host._push_world_uniform("sky_global_day_weight", host._global_sky_day_weight())
	if host._sky_background != null:
		host._sky_background.set_global_time(host._day_phase, host.day_night_enabled)
	host._push_water_lighting_uniforms()
	if host._shader_mat != null:
		host._push_world_uniform("day_night_enabled", host.day_night_enabled)
	if host._weather_layer != null:
		host._weather_layer.set_day_night_enabled(host.day_night_enabled)
	if host._fog_layer != null:
		host._fog_layer.set_day_night_enabled(host.day_night_enabled)
	if host._building_visual_layer != null:
		host._building_visual_layer.set_day_night_enabled(host.day_night_enabled)
	# [cylindrical-earth-daylight] 植被/点缀层昼夜总开关随地形同步（关闭=永昼）。
	host._for_each_vegetation_layer(func(layer: ShrubLayer) -> void:
		layer.set_day_night_enabled(host.day_night_enabled)
	)
	host._sync_detail_and_activity_materials()
	if host._cloud_shadow_field != null:
		host._cloud_shadow_field.set_night_factor(
			host._tod_night_factor if host.day_night_enabled else 0.0)


# [parallax-rain] 俯视雨幕参数 setter

static func set_camera_pitch_deg(host, deg: float) -> void:

	host.camera_pitch_deg = clampf(deg, 0.0, 90.0)
	host._camera_pitch = deg_to_rad(host.camera_pitch_deg)
	if host._weather_layer != null and host._weather_layer.has_method("set_camera_pitch"):
		host._weather_layer.set_camera_pitch(host._camera_pitch)


static func set_wind(host, dir: Vector2, strength: float) -> void:

	host.wind_dir = dir
	host.wind_strength = clampf(strength, -1.0, 1.0)
	host._wind_dir = dir.normalized() if dir.length_squared() > 0.0001 else Vector2(0.3, 1.0)
	host._wind_strength = host.wind_strength
	if host._weather_layer != null and host._weather_layer.has_method("set_wind"):
		host._weather_layer.set_wind(host._wind_dir, host._wind_strength)

# Upload active weather fronts to both the terrain shader and the weather layer.
# Diag log（2026-05-10 引入用于诊断 weather_layer logs 缺失）：本次收尾把
# "每帧必报"收紧为"前 3 次 + 数量变化时报"，避免 release log 刷屏；要恢复
# 详细日志只需把 _set_weather_fronts_log_budget 改大 / 把 last_n 重置为 -1。

static func set_weather_fronts(host, fronts: Array) -> void:

	# Fix #7A (2026-06-15): mobile 限 fronts 上限 4（桌面继续 16）。
	# log_next.txt 实测 fronts=12 时 draw_calls 32→41 / primitives 1644→5418，
	# 主要来自 12 个 GPUParticles2D 实例（每个 ~300 粒子）+ overlay shader
	# 内 16-loop 内部计算。截断到 4 减少：
	#   - GPUParticles primitives: ~3600→1200 (-2400)
	#   - 内部 16-loop 早 break（weather_front_count uniform 写 4）
	# 选 4 而非 0 保留视觉效果："最近 4 个 front 仍可见，远处天气只在 cell 数据上推进"。
	if OS.has_feature("mobile") and fronts.size() > 4:
		fronts = fronts.slice(0, 4)
	var n_now: int = fronts.size()
	var should_log: bool = false
	if host._set_weather_fronts_log_count < host._set_weather_fronts_log_budget:
		should_log = true
	elif n_now != host._set_weather_fronts_last_n:
		should_log = true
	if should_log:
		host._set_weather_fronts_log_count += 1
		host._set_weather_fronts_last_n = n_now
		print("[hex-renderer] set_weather_fronts(n=%d) layer=%s" % [
			n_now,
			"WeatherLayer" if host._weather_layer != null else
			"<null,fallback>",
		])
	if host._weather_layer != null:
		host._weather_layer.set_weather_fronts(fronts)
	else:
		_push_weather_fronts_to_shader(host, fronts)


static func set_weather_field_texture(host, tex: Texture2D) -> void:

	if host._weather_layer != null and host._weather_layer.has_method("set_weather_field_texture"):
		host._weather_layer.set_weather_field_texture(tex)
	# map-visual-overhaul-v1：主地图 shader 已不再消费 weather_field_tex，
	# 海面天气视觉迁移到 weather_overlay 三层独立云。这里只转发给 weather_layer。

# map-visual-overhaul-v1：主地形材质的 weather_field_tex 通道已删除；
# 此函数保留为空 stub，让外部脚本（main.gd 等）历史调用点在过渡期不崩溃。

static func refresh_terrain_weather_field_tex(host) -> void:

	pass


static func _on_weather_layer_visual_fronts_changed(host, fronts: Array) -> void:

	_push_weather_fronts_to_shader(host, fronts)


static func _push_weather_fronts_to_shader(host, fronts: Array) -> void:

	host.RendererWeatherInputs._push_weather_fronts_to_shader(
		host._shader_mat,
		host._push_world_uniform,
		host._update_detail_wind_field,
		fronts)

# 阶段 D：由天气锋面聚合出植被风场。方向 = Σ(主轴·强度) 归一化；附加风强 =
# 各锋面 max(强度, 降水)·强度 的峰值。无锋面（n==0）时退回轻柔常量盛行风。

static func _update_detail_wind_field(host, fronts: Array, n: int) -> void:

	if n <= 0:
		host._detail_wind_dir = Vector2(1.0, 0.18)
		host._detail_wind_boost = 0.0
		return
	var dir = Vector2.ZERO
	var boost = 0.0
	for i in range(n):
		var f = fronts[i]
		var intensity = _front_intensity(host, f)
		if intensity <= 0.001:
			continue
		var ax = _front_axis(host, f)
		if ax.length() <= 0.0001:
			continue
		# 主轴是无向的，统一指向 +x 半平面再按强度加权，避免反向相消。
		if ax.x < 0.0:
			ax = -ax
		dir += ax.normalized() * intensity
		boost = maxf(boost, maxf(intensity, _front_precip_amount(host, f)) * intensity)
	host._detail_wind_dir = dir.normalized() if dir.length() > 0.0001 else Vector2(1.0, 0.18)
	host._detail_wind_boost = clampf(boost, 0.0, 1.0)





static func _front_intensity(host, front) -> float:

	return host.RendererWeatherInputs._front_intensity(front)


static func _front_axis(host, front) -> Vector2:

	return host.RendererWeatherInputs._front_axis(front)





static func _front_precip_amount(host, front) -> float:

	return host.RendererWeatherInputs._front_precip_amount(front)




