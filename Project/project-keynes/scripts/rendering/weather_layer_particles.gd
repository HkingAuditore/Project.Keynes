extends RefCounted

## Particle-pool update helper; WeatherLayer remains the sole state owner.

static func sync_particles_pool(host, fronts: Array) -> void:
	if host._particles_pool.is_empty():
		return
	if not host._FRONT_PARTICLES_ENABLED:
		for i in range(host.MAX_WEATHER_FRONTS):
			host._disable_particle_slot(host._particles_pool[i], i)
		return
	var n: int = mini(fronts.size(), host.MAX_WEATHER_FRONTS)
	for i in range(host.MAX_WEATHER_FRONTS):
		var node: GPUParticles2D = host._particles_pool[i]
		if i >= n:
			host._disable_particle_slot(node, i)
			continue
		var f = fronts[i]
		var wt: int = host._front_type(f)
		# v-data-driven：是否出粒子完全来自 profile.has_particles，不再判 type。
		var profile := WeatherProfileRegistry.get_profile(wt)
		if profile == null or not profile.has_particles:
			host._disable_particle_slot(node, i)
			continue

		# 类型变了才重新配置 process_material（避免每帧重建）
		if host._particles_type_cache[i] != wt:
			host._configure_particles_for_type(node, wt)
			host._particles_type_cache[i] = wt
			# Phase A 止血：换类型后强制重新下发 amount / visibility_rect
			# （新类型的合法范围可能与旧 cache 完全不同）
			host._particles_amount_cache[i] = -1
			host._particles_vis_radius_cache[i] = -1.0

		# 每次都更新位置 / emitter 半径 / intensity 调强度
		node.position = host._front_center(f)
		# v9.perf：每个 slot 自己设 visibility_rect = ±radius，让引擎能正确剂除而不是
		# 默认那个 (-100,-100,200,200) 小框（front 半径常常远超 100）
		# Phase A 止血：仅当 bound_r 相对缓存值变化 > 5% 时才重写 visibility_rect，
		# 避免每帧因微小数值波动触发 Rect2 重新分配 / culler 重新评估。
		var r: float = maxf(host._front_radius(f), 1.0)
		var bound_r: float = r * maxf(maxf(host._front_major_scale(f), host._front_minor_scale(f)), 1.0)
		var cached_vis_r: float = host._particles_vis_radius_cache[i]
		if cached_vis_r <= 0.0 or absf(bound_r - cached_vis_r) > cached_vis_r * 0.05:
			node.visibility_rect = Rect2(-bound_r, -bound_r, bound_r * 2.0, bound_r * 2.0)
			host._particles_vis_radius_cache[i] = bound_r
		# v-data-driven：降水密度制——amount 随覆盖面积缩放，所有阈值从 profile 取。
		# _rain_density_boost_enabled=false 时回落到全局常量下限（上一轮更保守的数值）。
		var area: float = PI * r * host._front_major_scale(f) * r * host._front_minor_scale(f)
		var lo: int
		var hi: int
		if host._rain_density_boost_enabled:
			lo = profile.particle_amount_min
			hi = profile.particle_amount_max
		else:
			# 兼容：关闭 boost 时使用之前的保守上下限。
			var is_snow_fallback: bool = (wt == host._WT_BLIZZARD)
			lo = host._SNOW_AMOUNT_MIN if is_snow_fallback else host._RAIN_AMOUNT_MIN
			hi = host._SNOW_AMOUNT_MAX if is_snow_fallback else host._RAIN_AMOUNT_MAX
		var desired: int = clampi(
			int(ceil(area * profile.particle_density_per_px2)), lo, hi
		)
		# Phase A 止血：amount 每帧 ±1 振荡会触发 GPUParticles 内部缓冲重建（明显卡顿）。
		# 仅当 |Δ| > 5 时才下发；这对应面积变化约 3%，肉眼不可察。
		var cached_amt: int = host._particles_amount_cache[i]
		if cached_amt < 0 or absi(desired - cached_amt) > 5:
			node.amount = desired
			host._particles_amount_cache[i] = desired
		var max_fall_speed: float = maxf(profile.particle_velocity_max, 1.0)
		var local_fall_budget: float = r * host._front_minor_scale(f) * 1.15
		var bounded_lifetime: float = clampf(
			local_fall_budget / max_fall_speed,
			0.38,
			profile.particle_lifetime
		)
		if not is_equal_approx(node.lifetime, bounded_lifetime):
			node.lifetime = bounded_lifetime
		var pm := node.process_material as ParticleProcessMaterial
		if pm != null:
			pm.emission_box_extents = Vector3(
				r * host._front_major_scale(f),
				r * host._front_minor_scale(f),
				1.0
			)
		# 发射范围用材质的世界单位表达；节点只负责定位。
		# 不再缩放 GPUParticles2D，否则粒子速度和贴图也会被放大，雨雪会飞出天气区域。
		node.rotation = 0.0
		node.scale = Vector2.ONE
		# modulate.a 反映视觉强度；逻辑 intensity 仍保持原值，但表现层用非线性曲线
		# 抬高中低强度天气，避免雨雪刚生成/衰减后几乎不可见。
		var visual_intensity: float = host._front_visual_intensity(host._front_intensity(f))
		var precip_amount: float = host._front_precip_amount(f)
		var alpha_fade: float = clampf(maxf(visual_intensity, precip_amount) / 0.10, 0.0, 1.0)
		var alpha: float = clampf(0.28 + precip_amount * 0.48, 0.0, 0.78) \
				* alpha_fade * host._strength
		# TOD 染色：雨雪粒子是前景特效，不能像地表一样被夜晚二次压暗。
		# 使用带下限的 TOD 色温，只保留昼夜冷暖倾向，保证午夜雨雪仍然可读。
		var base_col: Color = profile.particle_base_color
		var night_particle_scale: float = 1.0 - 0.18 * host._tod_night_factor
		var tint_r: float = host._particle_tod_tint_component(host._tod_sun_color.r, host._tod_ambient_color.r)
		var tint_g: float = host._particle_tod_tint_component(host._tod_sun_color.g, host._tod_ambient_color.g)
		var tint_b: float = host._particle_tod_tint_component(host._tod_sun_color.b, host._tod_ambient_color.b)
		node.modulate = Color(
			clampf(base_col.r * tint_r * night_particle_scale * host._tod_exposure, 0.0, 1.0),
			clampf(base_col.g * tint_g * night_particle_scale * host._tod_exposure, 0.0, 1.0),
			clampf(base_col.b * tint_b * night_particle_scale * host._tod_exposure, 0.0, 1.0),
			alpha * clampf(maxf(base_col.a, 0.72), 0.0, 1.0)
		)
		node.visible = true
		# v9.perf：从 DISABLED → INHERIT 才会真正开始 process / 渲染粒子
		node.process_mode = Node.PROCESS_MODE_INHERIT
		node.emitting = true
# v9.perf：把 slot 完整地"睡眠"掉（不可见 + 不 process + 标记类型缓存清零）
