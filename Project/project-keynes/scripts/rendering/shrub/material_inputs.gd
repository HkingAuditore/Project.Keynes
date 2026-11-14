extends RefCounted

const VegetationShaderVariants = preload("res://scripts/rendering/vegetation_shader_variants.gd")
const PK_WEB_ENABLE_VEG_NEAR_FORMS = VegetationShaderVariants.PK_WEB_ENABLE_VEG_NEAR_FORMS
const PK_WEB_VEG_NEAR_FULL_FORMS = VegetationShaderVariants.PK_WEB_VEG_NEAR_FULL_FORMS

## Stateless collaborator for ShrubLayer.

static func set_world_time(host, v: float) -> void:

	if host._material != null:
		host._material.set_shader_parameter("world_time", v)



static func set_season_phase(host, v: float) -> void:

	if host._material != null:
		host._material.set_shader_parameter("season_phase", v)
	if host._shadow_material != null:
		host._shadow_material.set_shader_parameter("season_phase", v)



static func set_day_phase(host, v: float) -> void:

	var p = fposmod(v, 1.0)
	if host._material != null:
		host._material.set_shader_parameter("day_phase", p)
	if host._shadow_material != null:
		host._shadow_material.set_shader_parameter("day_phase", p)



static func set_world_material_inputs(host, world: WorldData, bounds: Rect2, _use_cell_indirection: bool) -> void:

	host._world = world
	host._bounds = bounds
	host._native_delta_common_knobs = {}
	# 不能只看「_world 切换前后 tiled 是否变化」：setup 已把 _world 设成 tiled 后，
	# 后续 _apply_uniforms 再调本函数时 was_tiled 已是 true，会永久跳过变体刷新，
	# 植被 shader 卡在 legacy（采 map_index_atlas）而世界走 tiled（不绑 atlas）→ 全图消失。
	_ensure_shader_matches_tiles(host, )



static func _visual_tiles_active(host) -> bool:

	return host._world != null and host._world.visual_tiles != null \
		and bool(host._world.visual_tiles.ready) \
		and String(host._world.visual_tiles.layout.mode) == "tiled"



static func _shader_is_tiled_variant(host, mat: ShaderMaterial) -> bool:

	return mat != null and mat.shader != null \
		and mat.shader.code.begins_with("#define MAP_VISUAL_TILED")


# 按当前 _visual_tiles_active() 对齐主/投影 shader 变体；不一致则重建，否则只 sync。

static func _ensure_shader_matches_tiles(host) -> void:

	_ensure_resources(host, )
	var want_tiled = _visual_tiles_active(host, )
	var main_ok = _shader_is_tiled_variant(host, host._material) == want_tiled
	var shadow_ok = host._shadow_material == null \
		or _shader_is_tiled_variant(host, host._shadow_material) == want_tiled
	# _ready() 的早编是"远景保护变体"（见 _web_veg_form_defines()）。它不能只看
	# tiled 位是否一致：world 不是 tiled 时 tiled 位恰好都是 false，会永久停在
	# 远景观感，所以这里单独判一次。
	if main_ok and shadow_ok and not _shader_is_web_far_prototype(host, host._material):
		_sync_world_material_inputs(host, true)
	else:
		_refresh_shader_variants(host, )


# web 近景 form 打开时，_ready() 会先编一份 PK_VEG_FAR_ONLY 的便宜变体，
# setup() 拿到 world 后必须换成真实档位（即使 tiled 位没变）。

static func _shader_is_web_far_prototype(host, mat: ShaderMaterial) -> bool:

	if not (host.PK_WEB_ENABLE_VEG_NEAR_FORMS and OS.has_feature("web")):
		return false
	return mat != null and mat.shader != null \
		and mat.shader.code.contains("#define PK_VEG_FAR_ONLY")


# [cylindrical-earth-daylight] 昼夜光照与地形同源（逐像素经纬度晨昏线）。
# 昼夜色/昼夜系数已在 shader 内按本实例经纬度逐像素求解，这里只需同步全局曝光；
# sun/ambient/night_factor 形参保留仅为调用方兼容，不再消费。

static func set_tod(host, _sun_color: Color, _ambient_color: Color, _night_factor: float, exposure: float) -> void:

	if host._material == null:
		return
	host._material.set_shader_parameter("tod_exposure", exposure)



static func set_world_sky_lighting(host, source: ShaderMaterial) -> void:

	if host._material == null or source == null:
		return
	for name in ["sky_ibl_bound", "sky_ambient_strength", "sky_day_sh_l1", "sky_night_sh_l1"]:
		var value: Variant = source.get_shader_parameter(name)
		if value != null:
			host._material.set_shader_parameter(name, value)



static func set_tod_sun_dir(host, dir: Vector3) -> void:

	var d = dir.normalized()
	if d.length_squared() <= 0.000001:
		d = Vector3(0.4, -0.7, 0.6).normalized()
	if host._material != null:
		host._material.set_shader_parameter("tod_sun_dir", d)
	if host._shadow_material != null:
		host._shadow_material.set_shader_parameter("tod_sun_dir", d)



static func set_tod_debug_sun_position(host, enabled: bool, uv: Vector2) -> void:

	var p = Vector2(fposmod(uv.x, 1.0), clampf(uv.y, 0.0, 1.0))
	if host._material != null:
		host._material.set_shader_parameter("tod_debug_sun_position_enabled", enabled)
		host._material.set_shader_parameter("tod_debug_sun_uv", p)
	if host._shadow_material != null:
		host._shadow_material.set_shader_parameter("tod_debug_sun_position_enabled", enabled)
		host._shadow_material.set_shader_parameter("tod_debug_sun_uv", p)




static func set_eternal_daylight_parameters(host, min_elevation: float, max_hour_angle: float) -> void:

	host._eternal_min_elevation_rad = min_elevation
	host._eternal_max_hour_angle_rad = max_hour_angle
	if host._material != null:
		host._material.set_shader_parameter("eternal_min_elevation_rad", min_elevation)
		host._material.set_shader_parameter("eternal_max_hour_angle_rad", max_hour_angle)
	if host._shadow_material != null:
		host._shadow_material.set_shader_parameter("eternal_min_elevation_rad", min_elevation)
		host._shadow_material.set_shader_parameter("eternal_max_hour_angle_rad", max_hour_angle)



static func set_tod_debug_sun_height_scale(host, v: float) -> void:

	var scale = clampf(v, 0.2, 1.5)
	if host._material != null:
		host._material.set_shader_parameter("tod_debug_sun_height_scale", scale)
	if host._shadow_material != null:
		host._shadow_material.set_shader_parameter("tod_debug_sun_height_scale", scale)


# 地轴倾角(rad)：与地形 axial_tilt_rad 同源，驱动晨昏线的季节赤纬。

static func set_axial_tilt_rad(host, v: float) -> void:

	if host._material != null:
		host._material.set_shader_parameter("axial_tilt_rad", v)
	if host._shadow_material != null:
		host._shadow_material.set_shader_parameter("axial_tilt_rad", v)


# 昼夜总开关：关闭时植被退化为永昼（与地形 day_night_enabled 一致）。

static func set_day_night_enabled(host, v: bool) -> void:

	if host._material != null:
		host._material.set_shader_parameter("day_night_enabled", v)
	if host._shadow_material != null:
		host._shadow_material.set_shader_parameter("day_night_enabled", v)


# 阶段 D：全局盛行风方向 + 实时天气附加风强（风暴/季风）。每帧由 hex_renderer 推送。

static func set_wind_field(host, dir: Vector2, boost: float) -> void:

	if host._material == null:
		return
	var d = dir if dir.length() > 0.0001 else Vector2(1.0, 0.18)
	host._material.set_shader_parameter("wind_dir", d.normalized())
	host._material.set_shader_parameter("weather_wind_boost", maxf(boost, 0.0))



static func set_terrain_horizon_inputs(host, tex: Texture2D, bound: bool, strength: float, softness: float,
		max_angle: float, cast_floor: float, debug_view: int, coarse_normal_strength: float) -> void:

	if host._material == null:
		return
	# tiled 变体采 visual_horizon_tiles（由 _sync_world_material_inputs 绑定）；legacy tex 可空。
	# bound 必须由调用方按实际就绪态传入，不能再隐含「tex!=null」。
	if not _visual_tiles_active(host, ):
		host._material.set_shader_parameter("terrain_horizon_tex", tex)
	host._material.set_shader_parameter("terrain_horizon_tex_bound", bound)
	host._material.set_shader_parameter("terrain_horizon_strength", clampf(strength, 0.0, 1.5))
	host._material.set_shader_parameter("terrain_horizon_softness", clampf(softness, 0.01, 1.0))
	host._material.set_shader_parameter("terrain_horizon_max_angle", clampf(max_angle, 0.30, 1.5708))
	host._material.set_shader_parameter("terrain_horizon_cast_floor", clampf(cast_floor, 0.35, 1.0))
	host._material.set_shader_parameter("terrain_horizon_debug_view", clampi(debug_view, 0, 2))
	host._material.set_shader_parameter("hillshade_coarse_strength", clampf(coarse_normal_strength, 0.0, 3.0))


# [terrain-gi 2026-07-31] 天空可见度 LUT 与强度。lut 必须是 HexRenderer.build_gi_horizon_lut
# 的产物（按同一 terrain_horizon_max_angle 预计算），否则植被与地形的 AO 会错位。
# lut 为空 → gi_lut_bound=false → 植被退回启发式谷地 AO。

static func set_terrain_gi_inputs(host, lut: PackedVector3Array, ao_strength: float, ao_floor: float,
		bent_strength: float, normal_floor: float) -> void:

	if host._material == null:
		return
	var bound: bool = lut.size() == 16
	host._material.set_shader_parameter("gi_lut_bound", bound)
	if bound:
		host._material.set_shader_parameter("gi_horizon_lut", lut)
	host._material.set_shader_parameter("gi_ao_strength", clampf(ao_strength, 0.0, 1.0))
	host._material.set_shader_parameter("gi_ao_floor", clampf(ao_floor, 0.0, 1.0))
	host._material.set_shader_parameter("gi_bent_strength", clampf(bent_strength, 0.0, 1.0))
	host._material.set_shader_parameter("gi_normal_floor", clampf(normal_floor, 0.0, 1.0))


# 注入 C++ DCWorldExt。可传 null 关闭 native 路径（强制 GDScript fallback）。

static func set_world_ext(host, ext) -> void:

	host._world_ext = ext



static func set_chunked_multimesh_enabled(host, enabled: bool, chunk_size_cells: int = 8) -> void:

	var next_size = maxi(2, chunk_size_cells)
	if host._chunked_multimesh_enabled == enabled and host._chunk_size_cells == next_size:
		return
	host._chunked_multimesh_enabled = enabled
	host._chunk_size_cells = next_size
	host._invalidate_chunk_spatial_cache()
	host._active_instance_count_valid = false
	if host._map != null:
		_rebuild_or_defer(host, )



static func set_visual_quality(host, q: int) -> void:

	var next_q = clampi(q, 0, 2)
	if host._visual_quality == next_q:
		return
	var change_web_program = OS.has_feature("web") and ((host._visual_quality >= 2) != (next_q >= 2))
	host._visual_quality = next_q
	if change_web_program:
		_refresh_shader_variants(host, )
	host._native_delta_common_knobs = {}
	if host._map != null:
		_rebuild_or_defer(host, )



static func set_mobile_quality_tier(host, q: int) -> void:

	var next_q = clampi(q, 0, 2)
	if host._mobile_quality_tier == next_q:
		return
	host._mobile_quality_tier = next_q
	host._native_delta_common_knobs = {}
	_refresh_shader_variants(host, )
	if OS.has_feature("mobile") and host._map != null:
		_rebuild_or_defer(host, )



static func set_cloud_shadow_field(host, texture: Texture2D, direct_enabled: bool,
		wrap_origin_uv: float, wrap_period_uv: float) -> void:

	var shader_changed = host._cloud_shadow_direct != direct_enabled
	host._cloud_shadow_direct = direct_enabled
	if texture != null:
		host._cloud_shadow_texture = texture
	host._cloud_shadow_wrap_origin_uv = wrap_origin_uv
	host._cloud_shadow_wrap_period_uv = maxf(wrap_period_uv, 0.0)
	if shader_changed:
		_refresh_shader_variants(host, )
	else:
		_push_cloud_shadow_uniforms(host, )
	for raw_material in host._family_materials:
		_push_cloud_shadow_uniforms_to(host, raw_material as ShaderMaterial)



static func _push_cloud_shadow_uniforms(host) -> void:

	_push_cloud_shadow_uniforms_to(host, host._material)
	_push_cloud_shadow_uniforms_to(host, host._shadow_material)



static func _push_cloud_shadow_uniforms_to(host, material: ShaderMaterial) -> void:

	if material == null or material.shader == null \
			or not material.shader.code.contains("#define PK_CLOUD_SHADOW_DIRECT"):
		return
	if host._cloud_shadow_texture != null:
		material.set_shader_parameter("cloud_shadow_tex", host._cloud_shadow_texture)
	material.set_shader_parameter("cloud_shadow_field_bound",
		host._cloud_shadow_direct and host._cloud_shadow_texture != null)
	material.set_shader_parameter("cloud_shadow_wrap_origin_uv", host._cloud_shadow_wrap_origin_uv)
	material.set_shader_parameter("cloud_shadow_wrap_period_uv", host._cloud_shadow_wrap_period_uv)



static func _rebuild_or_defer(host) -> void:

	if host._defer_initial_rebuild and host._chunked_multimesh_enabled:
		host.clear()
		host._last_rebuild_reason = "cache_invalidated_until_prefetch"
	else:
		host._rebuild_instances()



static func _ensure_resources(host) -> void:

	if host._mmi == null:
		host._mmi = MultiMeshInstance2D.new()
		host._mmi.name = "ShrubMultiMesh"
		host.add_child(host._mmi)
	if host._material == null:
		var shader = host._compiled_shader(_shader_quality_define_prefix(host, ) + host._SHADER_CODE, "body")
		host._material = ShaderMaterial.new()
		host._material.shader = shader
		host._material.set_shader_parameter("world_time", 0.0)
		host._material.set_shader_parameter("season_phase", 1.0)
		host._material.set_shader_parameter("day_phase", 0.25)
		host._material.set_shader_parameter("axial_tilt_rad", 0.41)
		host._material.set_shader_parameter("eternal_min_elevation_rad", host._eternal_min_elevation_rad)
		host._material.set_shader_parameter("eternal_max_hour_angle_rad", host._eternal_max_hour_angle_rad)
		host._material.set_shader_parameter("day_night_enabled", true)
		host._bind_crown_art(host._material)
		host._mmi.material = host._material
	if host._shadow_material == null:
		var shadow_shader = host._compiled_shader(
			_shader_quality_define_prefix(host, ) + host._SHADOW_SHADER_CODE, "shadow")
		host._shadow_material = ShaderMaterial.new()
		host._shadow_material.shader = shadow_shader
		host._shadow_material.set_shader_parameter("season_phase", 1.0)
		host._shadow_material.set_shader_parameter("day_phase", 0.25)
		host._shadow_material.set_shader_parameter("axial_tilt_rad", 0.41)
		host._shadow_material.set_shader_parameter("eternal_min_elevation_rad", host._eternal_min_elevation_rad)
		host._shadow_material.set_shader_parameter("eternal_max_hour_angle_rad", host._eternal_max_hour_angle_rad)
		host._shadow_material.set_shader_parameter("day_night_enabled", true)
	if host._shadow_blob_mesh == null:
		host._shadow_blob_mesh = host._build_shadow_blob_mesh()
	if host._shadow_multimesh == null:
		host._shadow_multimesh = MultiMesh.new()
		host._shadow_multimesh.transform_format = MultiMesh.TRANSFORM_2D
		host._shadow_multimesh.use_colors = true
		host._shadow_multimesh.use_custom_data = true
		host._shadow_multimesh.mesh = host._shadow_blob_mesh
		host._shadow_multimesh.instance_count = 0
		host._shadow_multimesh.visible_instance_count = 0
	if host._shadow_mmi == null:
		host._shadow_mmi = MultiMeshInstance2D.new()
		host._shadow_mmi.name = "ShrubShadowMultiMesh"
		# 低 z（相对层 z 减 1）：渲染在地形之上、植株之下。
		host._shadow_mmi.z_index = -1
		host._shadow_mmi.material = host._shadow_material
		host._shadow_mmi.multimesh = host._shadow_multimesh
		host._shadow_mmi.visible = false
		host.add_child(host._shadow_mmi)
	_apply_profile_uniforms(host, )
	_sync_world_material_inputs(host, false)
	_push_cloud_shadow_uniforms(host, )


# ─── web 近景 vegetation form 开关（2026-10-31）──────────────────────────────
# 背景：整套近景 form（broadleaf/conifer/palm/...）在 web 上首次绘制编译要 45s 级，
# 当时的止损是把近景整段关掉 —— _shader_quality_define_prefix() 里给 web 加
# PK_VEG_FAR_ONLY，vegetation_impostor 的 fragment 只剩 vf_far()，vegetation_forms
# 里那一整套近景函数没人引用，编译器把它们全丢掉。
#
# 现在加载链路已经改成"进世界后分帧补 chunk"，唯一的风险回到"首次绘制 vegetation
# shader 编译"这一项，所以把近景放回来，但默认只编 4 个主力家族（PK_VEG_NEAR_MIN）。
#
# 三个档位只改下面两个常量，不用动 shader：
#   PK_WEB_ENABLE_VEG_NEAR_FORMS = false
#       → 老行为：PK_VEG_FAR_ONLY，近景 0 个 form（远景软盘），编译最省。
#   = true 且 PK_WEB_VEG_NEAR_FULL_FORMS = false（当前默认）
#       → PK_VEG_NEAR_MIN：阔叶 / 针叶 / 灌木 / 草丛 4 个家族走近景，
#         其余 13 个 form 直接落到 vf_far。
#   = true 且 PK_WEB_VEG_NEAR_FULL_FORMS = true
#       → 桌面同款全 17 个 form，最费编译时间（验证用，不要当默认）。
# 回退：把 PK_WEB_ENABLE_VEG_NEAR_FORMS 改回 false，重新导出一版 web 即可，
# shader 源文件不用改；首次编译成本仍然可以从 WebTelemetry 的 veg_shader 事件读。


## 受限平台（web / mobile）共用的 compile-time 档位宏（shader_quality.gdshaderinc
## 按这三个宏展开 PK_QUALITY_* / PK_MOBILE_ANY）。
## 分支与改动前的 `match _mobile_quality_tier` 逐字一致（不 clamp：0→LOW / 2→HIGH /
## 其余→MID），保证 mobile 侧的输出与改动前逐字节相同。

static func _shader_quality_define_prefix(host, force_far_only: bool = false) -> String:

	var tiled = _visual_tiles_active(host, )
	if OS.has_feature("web"):
		var web_prefix = host.web_define_prefix(host.WEB_SHADER_QUALITY_TIER, tiled, host._world != null, force_far_only,
			host._visual_quality >= 2 and bool(Engine.get_meta("pk_web_pc_high_boot", false)))
		if host._cloud_shadow_direct:
			web_prefix += "#define PK_CLOUD_SHADOW_DIRECT\n"
		return web_prefix
	# 非 web：桌面只有 tiled 前缀，与改动前逐字节相同；mobile 与 web 同属受限平台，
	# 但档位来自推送值、form 档在非 web 上恒为空串（也逐字节同改动前）。
	if not OS.has_feature("mobile"):
		var desktop_prefix = "#define MAP_VISUAL_TILED\n" if tiled else ""
		if host._cloud_shadow_direct:
			desktop_prefix += "#define PK_CLOUD_SHADOW_DIRECT\n"
		return desktop_prefix
	var prefix = "#define MAP_VISUAL_TILED\n" if tiled else ""
	prefix += host.quality_tier_defines(host._mobile_quality_tier)
	if host._cloud_shadow_direct:
		prefix += "#define PK_CLOUD_SHADOW_DIRECT\n"
	return prefix


## 实例侧包装：非 web 恒空串。真逻辑在 `web_form_defines()`。

static func _web_veg_form_defines(host) -> String:

	if not OS.has_feature("web"):
		return ""
	return host.web_form_defines(host._world != null)



static func _refresh_shader_variants(host) -> void:

	if host._material == null and host._shadow_material == null:
		return
	var prefix = _shader_quality_define_prefix(host, )
	if host._material != null:
		var shader = host._compiled_shader(prefix + host._SHADER_CODE, "body")
		host._material.shader = shader
		if host._mmi != null:
			host._mmi.material = host._material
	if host._shadow_material != null:
		var shadow_shader = host._compiled_shader(prefix + host._SHADOW_SHADER_CODE, "shadow")
		host._shadow_material.shader = shadow_shader
		if host._shadow_mmi != null:
			host._shadow_mmi.material = host._shadow_material
	_apply_profile_uniforms(host, )
	_sync_world_material_inputs(host, false)
	_push_cloud_shadow_uniforms(host, )
	for raw_material in host._family_materials:
		_push_cloud_shadow_uniforms_to(host, raw_material as ShaderMaterial)
	# 运行期换档（tier / tiled）也要能看到编译成本；_map 为空说明还没进世界，
	# 等 setup() 那次统一上报。
	if host._map != null:
		host._report_veg_shader_cost()



static func _apply_profile_uniforms(host) -> void:

	if host._material == null:
		return
	var cfg = host._profile()
	host.z_index = int(cfg.render_z_index)
	host._material.set_shader_parameter("wind_strength", cfg.wind_strength)
	host._material.set_shader_parameter("dry_yellow_strength", cfg.dry_yellow_strength)
	host._material.set_shader_parameter("wet_green_strength", cfg.wet_green_strength)
	host._material.set_shader_parameter("lush_green_strength", cfg.lush_green_strength)
	host._material.set_shader_parameter("heat_red_strength", cfg.heat_red_strength)
	host._material.set_shader_parameter("autumn_red_strength", cfg.autumn_red_strength)
	host._material.set_shader_parameter("temperature_color_strength", cfg.temperature_color_strength)
	host._material.set_shader_parameter("moisture_color_strength", cfg.moisture_color_strength)
	host._material.set_shader_parameter("snow_white_strength", cfg.snow_white_strength)
	host._material.set_shader_parameter("stress_hide_strength", cfg.stress_hide_strength)
	host._material.set_shader_parameter("snow_hide_strength", cfg.snow_hide_strength)
	host._material.set_shader_parameter("disappear_alpha_threshold", cfg.disappear_alpha_threshold)
	host._material.set_shader_parameter("vitality_dead_threshold", cfg.vitality_dead_threshold)
	host._material.set_shader_parameter("vitality_healthy_threshold", cfg.vitality_healthy_threshold)
	host._material.set_shader_parameter("vitality_alpha_power", cfg.vitality_alpha_power)
	host._material.set_shader_parameter("vitality_size_min", cfg.vitality_size_min)
	host._material.set_shader_parameter("vitality_size_max", cfg.vitality_size_max)
	host._material.set_shader_parameter("vitality_low_color_strength", cfg.vitality_low_color_strength)
	host._material.set_shader_parameter("vitality_high_color_strength", cfg.vitality_high_color_strength)
	host._material.set_shader_parameter("vitality_color_contrast", cfg.vitality_color_contrast)
	host._material.set_shader_parameter("color_saturation_gain", cfg.color_saturation_gain)
	host._material.set_shader_parameter("color_value_gain", cfg.color_value_gain)
	host._material.set_shader_parameter("snow_body_color_retention", cfg.snow_body_color_retention)
	host._material.set_shader_parameter("snow_alpha_loss_strength", cfg.snow_alpha_loss_strength)
	host._material.set_shader_parameter("lod_alpha", host._lod_alpha)
	var style = host.detail_style_shading()
	for param in ["detail_form", "veg_response", "phenology_response", "phenology_color_dominance",
			"albedo_light_floor", "aquatic_response", "bloom_strength", "snow_burial",
			"snow_size_floor"]:
		host._material.set_shader_parameter(param, style[param])

	# [veg-normal-shading] 法线辅助着色 uniform + 性能分档（q2 才采高度图邻域算谷地 AO）。
	var tier = host._active_quality_tier()
	var shading_on: bool = bool(cfg.get("shading_enabled")) if cfg.get("shading_enabled") != null else true
	host._material.set_shader_parameter("shading_enabled", 1.0 if shading_on else 0.0)
	host._material.set_shader_parameter("veg_shade_quality", tier)
	host._material.set_shader_parameter(
		"terrain_normal_influence",
		host._profile_float(&"terrain_normal_influence", 1.0))
	host._material.set_shader_parameter(
		"sun_shade_strength",
		host._profile_float(&"sun_shade_strength", 0.55))
	host._material.set_shader_parameter(
		"ambient_floor",
		host._profile_float(&"ambient_floor", 0.18))
	host._material.set_shader_parameter(
		"contact_ao_strength",
		host._profile_float(&"contact_ao_strength", 0.42))
	host._material.set_shader_parameter(
		"terrain_valley_ao_strength",
		host._profile_float(&"terrain_valley_ao_strength", 0.40))
	host._material.set_shader_parameter(
		"terrain_valley_ao_gain",
		host._profile_float(&"terrain_valley_ao_gain", 6.0))

	# [veg-cast-shadow] 投影 pass 外观/淡出 uniform（与植株共享活力/积雪阈值，保证一致淡出）。
	if host._shadow_material != null:
		var sc = cfg.get("shadow_color")
		host._shadow_material.set_shader_parameter("shadow_color", sc if sc is Color else Color(0.05, 0.06, 0.08, 1.0))
		var shadow_strength = host._profile_float(&"shadow_strength", 0.32)
		if DCFeatureFlags.uses_shader_quality_tier() and host._active_quality_tier() >= 2:
			shadow_strength *= 0.5
		host._shadow_strength_base = shadow_strength
		host._push_shadow_strength()
		host._shadow_material.set_shader_parameter("lod_alpha", host._lod_alpha)
		host._shadow_material.set_shader_parameter(
			"shadow_length_scale",
			host._profile_float(&"shadow_length_scale", 1.0))
		host._shadow_material.set_shader_parameter(
			"shadow_max_len",
			host._profile_float(&"shadow_max_length", 3.6))
		host._shadow_material.set_shader_parameter(
			"shadow_min_sun_elevation",
			host._profile_float(&"shadow_min_sun_elevation", 0.16))
		host._shadow_material.set_shader_parameter(
			"shadow_foot_radius",
			host._profile_float(&"shadow_foot_radius", 0.55))
		host._shadow_material.set_shader_parameter(
			"shadow_edge_softness",
			host._profile_float(&"shadow_edge_softness", 0.25))
		host._shadow_material.set_shader_parameter("vitality_dead_threshold", cfg.vitality_dead_threshold)
		host._shadow_material.set_shader_parameter("vitality_healthy_threshold", cfg.vitality_healthy_threshold)
		host._shadow_material.set_shader_parameter("vitality_alpha_power", cfg.vitality_alpha_power)
		host._shadow_material.set_shader_parameter("snow_hide_strength", cfg.snow_hide_strength)
		host._shadow_material.set_shader_parameter("aquatic_response", 1.0 if host._spawn_domain() == host.SPAWN_WATER else 0.0)
	host._sync_shadow_layer(true)



static func _sync_world_material_inputs(host, _use_cell_indirection: bool) -> void:

	if host._material == null:
		return
	var bounds = host._bounds
	var wrap_period = HexUtils.wrap_period_x(host._map.width, host._hex_size) if host._map != null else 0.0
	host._material.set_shader_parameter("world_origin", bounds.position)
	host._material.set_shader_parameter("world_size", bounds.size)
	host._material.set_shader_parameter("wrap_origin_x", 0.0)
	host._material.set_shader_parameter("wrap_period_x", wrap_period)
	if host._shadow_material != null:
		host._shadow_material.set_shader_parameter("world_origin", bounds.position)
		host._shadow_material.set_shader_parameter("world_size", bounds.size)
		host._shadow_material.set_shader_parameter("wrap_origin_x", 0.0)
		host._shadow_material.set_shader_parameter("wrap_period_x", wrap_period)
	if host._world == null:
		host._material.set_shader_parameter("lut_dims", Vector2.ONE)
		if host._shadow_material != null:
			host._shadow_material.set_shader_parameter("lut_dims", Vector2.ONE)
		return
	var tiled = _visual_tiles_active(host, )
	var tiles = host._world.visual_tiles if tiled else null
	if tiled:
		host._material.set_shader_parameter("visual_map_index_tiles", tiles.map_index)
		host._material.set_shader_parameter("visual_height_tiles", tiles.height)
		host._material.set_shader_parameter("visual_terrain_normal_tiles", tiles.terrain_normal)
		host._material.set_shader_parameter("visual_horizon_tiles", tiles.horizon)
		_push_visual_tile_layout(host, host._material, tiles.layout)
	else:
		host._material.set_shader_parameter("map_index_atlas", host._world.enum_atlas_tex)
	host._material.set_shader_parameter("dyn_lut", host._world.dyn_lut_tex)
	host._material.set_shader_parameter("eco_lut", host._world.eco_lut_tex)
	host._material.set_shader_parameter("lut_dims", Vector2(host._world.lut_dims.x, host._world.lut_dims.y))
	# [veg-normal-shading] 地形宏观法线 + 高度图（与地形 brdf 同源数据），植被 shader 用于 NdotL/谷地 AO。
	if not tiled:
		host._material.set_shader_parameter("terrain_normal_tex", host._world.terrain_normal_tex)
		host._material.set_shader_parameter("height_tex", host._world.height_tex)
		host._material.set_shader_parameter("terrain_horizon_tex", host._world.terrain_horizon_tex)
	host._material.set_shader_parameter("terrain_normal_tex_bound",
		tiles.terrain_normal != null if tiled else host._world.terrain_normal_tex != null)
	host._material.set_shader_parameter("hm_resolution", Vector2(tiles.layout.logical_size) if tiled \
		else Vector2(host._world.hm_size.x, host._world.hm_size.y))
	host._material.set_shader_parameter("terrain_horizon_tex_bound",
		bool(tiles.horizon_ready) if tiled else host._world.terrain_horizon_tex != null)
	# [veg-cast-shadow] 投影 pass 需要 cell 索引/动态态做夜侧与枯死/积雪淡出。
	if host._shadow_material != null:
		if tiled:
			host._shadow_material.set_shader_parameter("visual_map_index_tiles", tiles.map_index)
			_push_visual_tile_layout(host, host._shadow_material, tiles.layout)
		else:
			host._shadow_material.set_shader_parameter("map_index_atlas", host._world.enum_atlas_tex)
		host._shadow_material.set_shader_parameter("dyn_lut", host._world.dyn_lut_tex)
		host._shadow_material.set_shader_parameter("lut_dims", Vector2(host._world.lut_dims.x, host._world.lut_dims.y))



static func _push_visual_tile_layout(host, material: ShaderMaterial, layout) -> void:

	material.set_shader_parameter("visual_domain_origin", layout.visual_domain.position)
	material.set_shader_parameter("visual_domain_size", layout.visual_domain.size)
	material.set_shader_parameter("visual_grid_size", Vector2(layout.grid_size))
	material.set_shader_parameter("visual_interior_size", Vector2(layout.interior_size))
	material.set_shader_parameter("visual_layer_size", Vector2(layout.layer_size))
	material.set_shader_parameter("visual_logical_resolution", Vector2(layout.logical_size))
	material.set_shader_parameter("visual_gutter_px", float(layout.gutter_px))



