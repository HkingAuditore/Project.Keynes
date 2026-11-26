extends RefCounted

## Applies weather table inputs, fog layers, particles, and overlay materials.

static func _push_overlay_runtime_state(layer: WeatherLayer) -> void:
	if layer._overlay_mat == null:
		return
	layer._push_wind_luts()
	# [cell-field-overlays 2026-11-18] 材质重建/首次 setup 后必须重推一次（force）：缓存里的
	# "上次推的值"在新 ShaderMaterial 上不存在。
	layer._push_weather_table(true)
	# [cell-field-overlays 2026-11-18 / O2] 场函数路径的世界坐标 / per-cell 表绑定。
	layer._push_cell_field_uniforms()
	if layer._map_index_atlas_tex != null:
		layer._overlay_mat.set_shader_parameter("map_index_atlas", layer._map_index_atlas_tex)
	if layer._weather_lut_tex != null:
		layer._overlay_mat.set_shader_parameter("weather_lut", layer._weather_lut_tex)
	layer._overlay_mat.set_shader_parameter("lut_dims", Vector2(layer._weather_lut_dims.x, layer._weather_lut_dims.y))
	layer._overlay_mat.set_shader_parameter("world_origin", layer._world_bounds.position)
	layer._overlay_mat.set_shader_parameter("world_size", layer._world_bounds.size)
	layer._overlay_mat.set_shader_parameter("wrap_origin_x", 0.0)
	layer._overlay_mat.set_shader_parameter("wrap_period_x", layer._wrap_period_x)

	layer._overlay_mat.set_shader_parameter("hex_world_diameter", 2.0 * layer._hex_size)
	layer._overlay_mat.set_shader_parameter("world_time", layer._world_time)
	layer._overlay_mat.set_shader_parameter("weather_strength", layer._strength)
	layer._overlay_mat.set_shader_parameter("cloud_opacity_scale", layer._cloud_opacity_scale)
	layer._overlay_mat.set_shader_parameter("weather_overlay_quality", layer._weather_quality())
	layer._overlay_mat.set_shader_parameter("weather_debug_view", layer._weather_debug_view)
	layer._overlay_mat.set_shader_parameter("day_night_enabled", layer._day_night_enabled)
	layer._overlay_mat.set_shader_parameter("tod_sun_dir", layer._tod_sun_dir)
	layer._overlay_mat.set_shader_parameter("tod_exposure", layer._tod_exposure)
	layer._overlay_mat.set_shader_parameter("cloud_tod_tint_enabled", layer._cloud_tod_tint_enabled)
	# [cylindrical-earth-daylight] 云光照真源相位（首帧 / 重建材质时兜底推一次，运行时由 setter 增量刷新）。
	layer._overlay_mat.set_shader_parameter("season_phase", layer._season_phase)
	layer._overlay_mat.set_shader_parameter("day_phase", layer._day_phase)
	layer._overlay_mat.set_shader_parameter("axial_tilt_rad", layer._axial_tilt_rad)
	layer._overlay_mat.set_shader_parameter("tod_debug_sun_position_enabled", layer._tod_debug_sun_position_enabled)
	layer._overlay_mat.set_shader_parameter("tod_debug_sun_uv", layer._tod_debug_sun_uv)
	layer._overlay_mat.set_shader_parameter("tod_debug_sun_height_scale", layer._tod_debug_sun_height_scale)
	layer._overlay_mat.set_shader_parameter("eternal_min_elevation_rad", layer._eternal_min_elevation_rad)
	layer._overlay_mat.set_shader_parameter("eternal_max_hour_angle_rad", layer._eternal_max_hour_angle_rad)
	layer._push_weather_profile_uniforms_to_overlay()
	layer._push_fronts_to_overlay(layer._front_visual_snapshots)
	layer._push_fog_mask_uniforms()
	layer._push_edge_transition_data()


static func set_wind_luts(layer: WeatherLayer, current: Texture2D, previous: Texture2D, has_previous: bool) -> void:
	# 复用云影场在天气提交边界上传的风场，不重复生成或上传全图。
	layer._wind_lut_tex = current
	layer._wind_lut_prev_tex = previous
	layer._has_wind_prev = has_previous
	layer._push_wind_luts()


static func _push_wind_luts(layer: WeatherLayer) -> void:
	if layer._overlay_mat == null:
		return
	layer._overlay_mat.set_shader_parameter("has_local_wind", layer._wind_lut_tex != null)
	layer._overlay_mat.set_shader_parameter("has_wind_prev", layer._has_wind_prev)
	if layer._wind_lut_tex != null:
		layer._overlay_mat.set_shader_parameter("wind_lut", layer._wind_lut_tex)
		layer._overlay_mat.set_shader_parameter("wind_lut_prev", layer._wind_lut_prev_tex)


static func _uses_weather_endpoints(layer: WeatherLayer) -> bool:
	return layer.weather_cell_field_enabled and RenderingServer.get_rendering_device() != null


# [cell-field-overlays 2026-11-18] weather_table（offset 空间，4 层）+ 层号双缓冲的推送。
#
#   weather_table        : sampler2DArray（O2 的 weather_overlay 用 texelFetch 三格取值）
#   weather_table_size   : (map_w, map_h) —— shader 推 offset 的模数，**不**从别的 uniform 反推
#   weather_table_bound  : 数据是否就绪（false ⇒ shader 必须退回 weather_lut 旧路径）
#   weather_cur_layer    : 当前层号 0/1；prev = 1 - weather_cur_layer
#   weather_prev_layer   : 1 - cur（风的 A/B 是 2 + cur / 2 + prev，由 shader 自己加基址）
#
# 失效时把 bound 推 false 并解除纹理绑定：绝不把上一张地图/上一次提交的层号留在材质上。


static func _push_weather_table(layer: WeatherLayer, force: bool = false) -> void:
	if layer._overlay_mat == null:
		return
	var tex: Texture2DArray = layer._world_ref.weather_table_tex if layer._world_ref != null else null
	var bound: bool = tex != null and layer._world_ref.weather_table_valid
	var cur: int = int(layer._world_ref.weather_table_cur) if bound else -1
	var revision: int = layer._world_ref.weather_lut_update_usec if bound else -1
	if not force and revision == layer._endpoints_revision and tex == layer._wx_pushed_weather_table \
			and cur == layer._wx_pushed_weather_cur and bound == layer._wx_pushed_weather_bound:
		return
	layer._endpoints_revision = revision
	layer._wx_pushed_weather_table = tex
	layer._wx_pushed_weather_cur = cur
	layer._wx_pushed_weather_bound = bound
	layer._overlay_mat.set_shader_parameter("weather_table", tex if bound else null)
	layer._overlay_mat.set_shader_parameter("weather_table_bound", bound)
	if layer._uses_weather_endpoints() and bound:
		var dimensions: Vector2i = layer._world_ref.weather_table_dims * 2
		if layer._endpoints == null:
			layer._endpoints = preload("res://scripts/rendering/render_data_table.gd").new()
			layer._endpoints.configure(layer, dimensions, preload("res://shaders/weather_cell_endpoints.gdshader"))
		layer._endpoints.resize_table(dimensions)
		layer._endpoints.material.set_shader_parameter("source_table", tex)
		layer._endpoints.material.set_shader_parameter("current_layer", cur)
		layer._endpoints.refresh()
		layer._overlay_mat.set_shader_parameter("weather_endpoints", layer._endpoints.get_texture())
	elif layer._endpoints != null:
		layer._overlay_mat.set_shader_parameter("weather_endpoints", null)
		layer._endpoints.queue_free()
		layer._endpoints = null
	# 尺寸与层号只在 bound 时有意义；不 bound 时推 0 / -1，任何误读都落在合法范围外
	# （shader 的 bound 早退先挡住，这里只是不让残值看起来"像对的"）。
	layer._overlay_mat.set_shader_parameter("weather_table_size",
		Vector2(float(layer._world_ref.weather_table_dims.x), float(layer._world_ref.weather_table_dims.y)) \
		if bound else Vector2.ZERO)
	layer._overlay_mat.set_shader_parameter("weather_cur_layer", cur)
	layer._overlay_mat.set_shader_parameter("weather_prev_layer", (1 - cur) if bound else -1)
	# [cell-field-overlays 2026-11-18 / O2] 开关开着但表没就绪：shader 侧会整段空返回
	# （没有云），只在日志里报**一次** —— 否则 GM 面板上看到的是"开关打开了、天气没了"，
	# 属于最难查的一类静默。bound 恢复后重新武装，下次再失效还会报一次。
	if layer._world_ref != null and not bound and layer.weather_cell_field_enabled and not layer._wx_cell_field_warned:
		layer._wx_cell_field_warned = true
		push_warning("[weather-layer/cell-field] weather_cell_field_enabled=true 但 "
			+ "weather_table 未发布（reason 见 cell_lut_baker 的 weather_table_reason）⇒"
			+ " overlay 退化为无云。检查 bake 是否跑过、风场字节是否可用。")
	elif bound:
		layer._wx_cell_field_warned = false


# [cell-field-overlays 2026-11-18 / O2 + O23] 场函数路径的其余 uniform（方案 §3.2 / §3.4）。
#
#   hex_size       : 世界单位 / hex（= 半径）。**唯一** hex 尺寸来源；新代码不从
#                    hex_world_diameter 反推（那个 uniform 三处默认值不同，方案 §1.4）
#   map_dims       : (map_w, map_h)，与 cell_table / weather_table 同源
#   cell_table*    : 迷雾门控用（layer2.R = 知识度 k），缺数据一律推 false
#   weather_warp_* : 查表前的低频域扭曲（方案 §3.4 / §8-2）—— 天气云**自己的形态**参数
#   fog_field_band : 迷雾门控的 k 带宽，必须与迷雾显示同值（方案 §3.7）
#   fog_warp_*     : [O23] 迷雾门控**取 k 用的扭曲**，必须与迷雾显示同值。与 weather_warp_*
#                    分开是本任务的核心：云的形态用天气的，k 的取样位置用迷雾的。
#                    这三条（band / warp_*）的值一律取自 FogOfWarLayer 的常量，本文件不定义。
#
# 旧路径的 shader 不声明这些 uniform，"多推"是空操作 —— 所以这里不做开关判断，
# 保证开关翻转后新材质上一定拿得到全部值（ShaderMaterial 重建会丢掉已推的参数）。


static func _push_cell_field_uniforms(layer: WeatherLayer) -> void:
	if layer._overlay_mat == null:
		return
	layer._overlay_mat.set_shader_parameter("hex_size", layer._hex_size)
	layer._overlay_mat.set_shader_parameter("map_dims", layer._resolve_map_dims())
	layer._overlay_mat.set_shader_parameter("weather_warp_freq", WeatherLayer.WEATHER_WARP_FREQ_DEFAULT)
	layer._overlay_mat.set_shader_parameter("weather_warp_amp", WeatherLayer.WEATHER_WARP_AMP_DEFAULT)
	layer._overlay_mat.set_shader_parameter("fog_field_band", layer._fog_field_band)
	layer._overlay_mat.set_shader_parameter("fog_warp_freq", WeatherLayer.FogOfWarLayerScript.FOG_WARP_FREQ)
	layer._overlay_mat.set_shader_parameter("fog_warp_amp", WeatherLayer.FogOfWarLayerScript.FOG_WARP_AMP)
	var table: Texture2DArray = null
	var dims := Vector2i.ZERO
	var bound := false
	if layer._world_ref != null:
		table = layer._world_ref.cell_table_tex
		dims = layer._world_ref.cell_table_dims
		bound = bool(layer._world_ref.cell_table_bound) and table != null \
			and dims.x > 0 and dims.y > 0
	if bound:
		layer._overlay_mat.set_shader_parameter("cell_table", table)
		layer._overlay_mat.set_shader_parameter("cell_table_size", Vector2(dims.x, dims.y))
	else:
		# 缺数据一律推 false + 解除绑定：shader 侧 bound 早退，绝不读不存在的层。
		layer._overlay_mat.set_shader_parameter("cell_table", null)
		layer._overlay_mat.set_shader_parameter("cell_table_size", Vector2.ZERO)
	layer._overlay_mat.set_shader_parameter("cell_table_bound", bound)


## 地图尺寸（map_w, map_h）。优先用**表自己的尺寸**（weather_table_dims，O1 起与
## cell_table_dims 同源）；没有表时退回 MapData 的宽高；都没有则 ZERO（shader 的
## bound 早退会挡住一切读取）。


static func _resolve_map_dims(layer: WeatherLayer) -> Vector2:
	if layer._world_ref != null:
		var dims: Vector2i = layer._world_ref.weather_table_dims
		if dims.x > 0 and dims.y > 0:
			return Vector2(dims.x, dims.y)
		dims = layer._world_ref.cell_table_dims
		if dims.x > 0 and dims.y > 0:
			return Vector2(dims.x, dims.y)
	if layer._weather_map != null and layer._weather_map.width > 0 and layer._weather_map.height > 0:
		return Vector2(layer._weather_map.width, layer._weather_map.height)
	return Vector2.ZERO


## 迷雾带宽（gap 单位）。方案 §3.7：天气的迷雾门控与迷雾显示必须用同一个 k 函数 +
## **同一组参数**，所以初值直接取 FogOfWarLayer 的真源（[O23]：本文件不再有 0.6 这个
## 字面量；唯一的 0.6 在 fog_of_war_layer.gd::FOG_FIELD_BAND）。


static func set_fog_field_band(layer: WeatherLayer, v: float = WeatherLayer.FogOfWarLayerScript.FOG_FIELD_BAND) -> void:
	layer._fog_field_band = clampf(v, 0.0001, 0.86)
	if layer._overlay_mat != null:
		layer._overlay_mat.set_shader_parameter("fog_field_band", layer._fog_field_band)


static func _push_curtain_runtime_state(layer: WeatherLayer) -> void:
	if layer._curtains.materials.is_empty():
		return
	layer._curtains.invalidate_inputs()
	var flags := WeatherLayer.WeatherCellCurtains.weather_profile_flags()
	for mat in layer._curtains.materials:
		if layer._weather_lut_tex != null:
			mat.set_shader_parameter("weather_lut", layer._weather_lut_tex)
		if layer._world_ref != null and layer._world_ref.weather_lut_prev_tex != null:
			mat.set_shader_parameter("weather_lut_prev", layer._world_ref.weather_lut_prev_tex)
		mat.set_shader_parameter("lut_dims", Vector2(layer._weather_lut_dims.x, layer._weather_lut_dims.y))
		mat.set_shader_parameter("world_time", layer._world_time)
		mat.set_shader_parameter("weather_strength", layer._strength)
		mat.set_shader_parameter("cell_curtain_quality", layer._weather_quality())
		mat.set_shader_parameter("hex_world_diameter", 2.0 * layer._hex_size)
		mat.set_shader_parameter("day_night_enabled", layer._day_night_enabled)
		mat.set_shader_parameter("season_phase", layer._season_phase)
		mat.set_shader_parameter("day_phase", layer._day_phase)
		mat.set_shader_parameter("axial_tilt_rad", layer._axial_tilt_rad)
		mat.set_shader_parameter("tod_debug_sun_position_enabled", layer._tod_debug_sun_position_enabled)
		mat.set_shader_parameter("tod_debug_sun_uv", layer._tod_debug_sun_uv)
		mat.set_shader_parameter("tod_debug_sun_height_scale", layer._tod_debug_sun_height_scale)
		mat.set_shader_parameter("eternal_min_elevation_rad", layer._eternal_min_elevation_rad)
		mat.set_shader_parameter("eternal_max_hour_angle_rad", layer._eternal_max_hour_angle_rad)
		mat.set_shader_parameter("tod_exposure", layer._tod_exposure)
		mat.set_shader_parameter("weather_profile_flags", flags)
		# [parallax-rain] 俯视投影参数
		mat.set_shader_parameter("camera_pitch", layer._camera_pitch)
		mat.set_shader_parameter("wind_dir", layer._wind_dir)
		mat.set_shader_parameter("wind_strength", layer._wind_strength)
	layer._push_fog_mask_uniforms()


static func _load_overlay_shader(layer: WeatherLayer) -> void:
	# Web 首帧编译预算：桌面版 weather_overlay.gdshader（35KB 全屏 canvas）在 ANGLE 上首绘
	# 约 45 秒，是"进世界卡在 98%"的唯一原因（探针：跳过天气层之后整条加载链 7.2 秒 ready）。
	# [web-weather-min] 现在 web 走裁剪变体（见 WEB_WEATHER_MIN_DEFINE 与 shader 头部注释），
	# 不再默认 stub；下面这个分支只是应急回退开关（PK_WEB_ENABLE_WEATHER_SHADERS=false）。
	if not WeatherLayer.PK_WEB_ENABLE_WEATHER_SHADERS and OS.has_feature("web"):
		var stub := Shader.new()
		stub.code = "shader_type canvas_item;\nvoid fragment() { COLOR = vec4(0.0); }\n"
		layer._overlay_mat = ShaderMaterial.new()
		layer._overlay_mat.shader = stub
		layer._overlay_quad.material = layer._overlay_mat
		print("[weather_layer] web: overlay shader stubbed (web-min variant disabled by flag)")
		return
	var shader := ResourceLoader.load(WeatherLayer.OVERLAY_SHADER_PATH, "Shader",
		ResourceLoader.CACHE_MODE_IGNORE) as Shader
	if shader == null:
		push_warning("WeatherLayer: shader not found at %s" % WeatherLayer.OVERLAY_SHADER_PATH)
		return
	var shader_tier := layer._weather_shader_tier()
	var tier_quality := CloudShadowField.quality_for_tier(layer._weather_quality(), shader_tier)
	var prefix := "#define %s\n" % ["PK_WEATHER_LOW", "PK_WEATHER_MID", "PK_WEATHER_HIGH"][tier_quality]
	# 平台裁剪宏必须排在质量档宏之前：web 变体要能压过 MOBILE_QUALITY_* 的分支判断。
	if OS.has_feature("web"):
		prefix += WeatherLayer.WEB_WEATHER_MIN_DEFINE
	if layer._visual_tiles_active():
		prefix += "#define MAP_VISUAL_TILED\n"
	if shader_tier != "" and DCFeatureFlags.uses_shader_quality_tier():
		prefix += layer._shader_quality_define_prefix(shader_tier)
	# [cell-field-overlays 2026-11-18 / O2] 场函数开关：**独立**于地形开关，只改这份 program。
	# 放最后：define 顺序不影响 #ifdef 判定，而 cloud_weather_quality_test 断言前缀仍然
	# begins_with("#define PK_WEATHER_")（质量档必须排第一）。
	if layer.weather_cell_field_enabled:
		prefix += WeatherLayer.CELL_FIELD_DEFINE
		if layer._uses_weather_endpoints():
			prefix += "#define PK_WEATHER_CELL_ENDPOINTS\n"
	if not prefix.is_empty():
		shader = shader.duplicate() as Shader
		shader.code = prefix + shader.code
	layer._overlay_mat = ShaderMaterial.new()
	layer._overlay_mat.shader = shader
	layer._overlay_quad.material = layer._overlay_mat
	# 切档建立新材质，旧材质的提交缓存不能阻止 LUT/插值参数重新绑定。
	layer._wx_pushed_weather_lut = null
	layer._wx_pushed_weather_prev = null
	layer._wx_pushed_lerp = -1.0
	# [cell-field-overlays 2026-11-18 / O2] weather_table / cell_table 的缓存同理：新材质上
	# 一个参数都没有，必须让下一次 _push_* 真正写一遍。
	layer._wx_pushed_weather_table = null
	layer._wx_pushed_weather_cur = -2
	layer._wx_pushed_weather_bound = false
	layer._push_visual_tile_uniforms()
	layer._push_edge_transition_data()


static func _load_curtain_shader(layer: WeatherLayer) -> void:
	var tier := layer._weather_shader_tier()
	var prefix := layer._shader_quality_define_prefix(tier) if tier != "" and DCFeatureFlags.uses_shader_quality_tier() else ""
	if layer._curtains.load_materials(layer._curtain_layer_capacity(), prefix):
		layer._push_curtain_runtime_state()


static func _rebuild_curtain_layers(layer: WeatherLayer) -> void:
	var capacity := layer._curtain_layer_capacity() if WeatherLayer._CELL_CURTAIN_ENABLED else 0
	if layer._curtains.rebuild(layer._weather_map, layer._hex_size, layer._wrap_period_x, capacity):
		var update_usec: int = layer._world_ref.weather_lut_update_usec if layer._world_ref != null else 0
		layer._refresh_curtain_instances(update_usec, true)


static func _refresh_curtain_instances(layer: WeatherLayer, update_usec: int, blending: bool) -> void:
	layer._curtains.refresh_instances(update_usec, blending, layer._world_ref, layer._weather_lut_tex,
		layer._weather_lut_dims, layer._weather_shader_tier(), layer._desired_curtain_layer_count())


static func _curtain_layer_capacity(layer: WeatherLayer) -> int:
	if OS.has_feature("mobile"):
		if layer._weather_detail == 2:
			return 2
		return WeatherLayer._CURTAIN_LAYER_COUNT_MOBILE
	return WeatherLayer._CURTAIN_LAYER_COUNT_DESKTOP


static func _desired_curtain_layer_count(layer: WeatherLayer) -> int:
	if not WeatherLayer._CELL_CURTAIN_ENABLED:
		return 0
	if layer._weather_lut_dims.x <= 0 or layer._weather_lut_dims.y <= 0:
		return 0
	if layer._strength <= 0.001:
		return 0
	if OS.has_feature("mobile"):
		return layer._curtain_layer_capacity()
	match layer._weather_quality():
		0:
			return 1
		1:
			return 1
		_:
			return layer._curtain_layer_capacity()


static func _update_curtain_visibility(layer: WeatherLayer) -> void:
	layer._curtains.update_visibility(layer._desired_curtain_layer_count())

# ─── 粒子池初始化 ────────────────────────────────────────────────────────
# 16 个 GPUParticles2D，每个有自己的 ParticleProcessMaterial（避免共享导致全部 front
# 用一份配置）。process_material 的 emission_sphere_radius / direction / lifetime
# 在 _sync_particles_pool 里根据 front type 调整。

# v-data-driven：每种天气的 amount / lifetime / texture / process_material
# 全部来自 WeatherProfile；不再在 _init_particles_pool 里写死。
# _particles_pool 中每个节点保持未赋材质状态，由 _configure_particles_for_type 首次切换时赋值。


static func _init_particles_pool(layer: WeatherLayer) -> void:
	# Fix #7B (2026-06-15): mobile 完全跳过 GPU 粒子池构造。
	# log_next.txt 实测 fronts=12 时 primitives 1644→5418，~3700 增量主要来自
	# 12 个 GPUParticles2D 实例（每个 amount=80-900 粒子，按 area 缩放）。
	# Adreno 830 上 GPUParticles 内部 visibility_rect / process_material 切换
	# 累积明显帧消耗。雨/雪视觉降级为 weather_overlay shader 内的 streak/grain
	# effect（line 405-460 那段），mobile 玩家仍能看到天气表现。
	# _sync_particles_pool 入口的 'if _particles_pool.is_empty(): return' 守卫
	# 保证空池不会触发 NPE。
	if OS.has_feature("mobile"):
		layer._fallback_particle_texture = layer._build_fallback_particle_texture()
		layer._process_material_cache.clear()
		layer._particles_pool.clear()
		layer._particles_type_cache.clear()
		layer._particles_amount_cache.clear()
		layer._particles_vis_radius_cache.clear()
		return
	layer._fallback_particle_texture = layer._build_fallback_particle_texture()
	layer._process_material_cache.clear()
	layer._particles_pool.clear()
	layer._particles_type_cache.clear()
	layer._particles_amount_cache.clear()
	layer._particles_vis_radius_cache.clear()
	for i in range(WeatherLayer.MAX_WEATHER_FRONTS):
		var p := GPUParticles2D.new()
		p.name = "Particles_%d" % i
		p.amount = 80  # 占位，_configure_particles_for_type 会覆盖为 profile.particle_amount_min
		p.lifetime = 1.6
		p.preprocess = 0.0  # v9.perf：preprocess 启动时一次性 GPU 模拟，对每个 slot 都跑代价大；改为 0
		p.one_shot = false
		p.explosiveness = 0.0
		p.emitting = false
		p.visible = false
		p.local_coords = false
		p.z_as_relative = true
		p.z_index = 0
		# v9.perf：闲置粒子完全停 process，避免 16 个常驻 GPUParticles 每帧 GPU/CPU 开销
		p.process_mode = Node.PROCESS_MODE_DISABLED
		# 不预设 process_material / texture——首次 _configure_particles_for_type 才赋。
		layer._particles_root.add_child(p)
		layer._particles_pool.append(p)
		layer._particles_type_cache.append(WeatherLayer._WT_CLEAR)
		layer._particles_amount_cache.append(-1)        # -1 = 强制首次写入
		layer._particles_vis_radius_cache.append(-1.0)  # 同上

# v-data-driven：每个 slot 在第一次切换 type 时调用（避免每帧重建）。
# 所有参数从 WeatherProfile 读取；process_material 每个 slot 独立，
# 这样 _sync_particles_pool 可以按 front 的长短轴写发射盒，互不覆盖。


static func _configure_particles_for_type(layer: WeatherLayer, node: GPUParticles2D, wt: int) -> void:
	var profile := WeatherProfileRegistry.get_profile(wt)
	if profile == null:
		return
	node.amount = maxi(profile.particle_amount_min, 1)
	node.lifetime = profile.particle_lifetime
	node.process_material = layer._build_process_material_from_profile(profile)
	var tex: Texture2D = profile.particle_texture
	if tex == null:
		tex = layer._fallback_particle_texture
	node.texture = tex

# 构造 per-weather ParticleProcessMaterial，从 profile 字段逐一填入。
# emission_box_extents 由 _sync_particles_pool 按每个 front 的长短轴更新。


static func _build_process_material_from_profile(layer: WeatherLayer, profile: WeatherProfile) -> ParticleProcessMaterial:
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3.ONE
	pm.direction = profile.particle_direction
	pm.spread = profile.particle_spread
	pm.gravity = profile.particle_gravity
	pm.initial_velocity_min = profile.particle_velocity_min
	pm.initial_velocity_max = profile.particle_velocity_max
	pm.angular_velocity_min = profile.particle_angular_velocity_min
	pm.angular_velocity_max = profile.particle_angular_velocity_max
	pm.scale_min = profile.particle_scale_min
	pm.scale_max = profile.particle_scale_max
	pm.color = profile.particle_base_color
	return pm

# 懒加载 + 缓存：每种 WeatherType 至多一份 ParticleProcessMaterial。


static func _get_or_build_process_material(layer: WeatherLayer, wt: int) -> ParticleProcessMaterial:
	if layer._process_material_cache.has(wt):
		return layer._process_material_cache[wt]
	var profile := WeatherProfileRegistry.get_profile(wt)
	if profile == null or not profile.has_particles:
		return null
	var pm := layer._build_process_material_from_profile(profile)
	layer._process_material_cache[wt] = pm
	return pm

# 兜底贴图：1×1 全白 RGBA8，当 profile.particle_texture 为 null 时使用，
# 避免空引用崩溃（需求 3.5）。


static func _build_fallback_particle_texture(layer: WeatherLayer) -> ImageTexture:
	var data := PackedByteArray([255, 255, 255, 255])
	var img := Image.create_from_data(1, 1, false, Image.FORMAT_RGBA8, data)
	return ImageTexture.create_from_image(img)


static func _build_full_quad(layer: WeatherLayer, bounds: Rect2, wrap_period_x: float = 0.0) -> Mesh:
	var p := bounds.position
	var s := bounds.size
	if wrap_period_x > 0.0001:
		p.x = 0.0
		s.x = wrap_period_x
	var verts := PackedVector2Array()
	var indices := PackedInt32Array()
	var tile_offsets := PackedFloat32Array([0.0])
	if wrap_period_x > 0.0001:
		tile_offsets = PackedFloat32Array([-wrap_period_x, 0.0, wrap_period_x])
	for ox in tile_offsets:
		var base := verts.size()
		var tp := p + Vector2(float(ox), 0.0)
		verts.append(tp)
		verts.append(tp + Vector2(s.x, 0.0))
		verts.append(tp + s)
		verts.append(tp + Vector2(0.0, s.y))
		indices.append_array(PackedInt32Array([base, base + 1, base + 2, base, base + 2, base + 3]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
