extends RefCounted
const ShaderVariants = preload("res://scripts/rendering/renderer_shader_variants.gd")
const ActivityLighting = preload("res://scripts/rendering/renderer_activity_lighting.gd")
const RendererCloudShadowBinding = preload("res://scripts/rendering/renderer_cloud_shadow_binding.gd")
const WaterRippleLattice = preload("res://scripts/rendering/water_ripple_lattice.gd")

const PK_WEB_TEXTURE_BUDGET_DEFINE = ShaderVariants.PK_WEB_TEXTURE_BUDGET_DEFINE
const QUALITY_PREFIX_LOW = ShaderVariants.QUALITY_PREFIX_LOW
const WORLD_MAP_WEB_MIN_DEFINE = ShaderVariants.WORLD_MAP_WEB_MIN_DEFINE
const WORLD_MAP_WEB_NO_MICRO_DEFINE = ShaderVariants.WORLD_MAP_WEB_NO_MICRO_DEFINE
const WORLD_MAP_WEB_LAND_ONLY_DEFINE = ShaderVariants.WORLD_MAP_WEB_LAND_ONLY_DEFINE
const WORLD_MAP_WEB_HORIZON_DEFINE = ShaderVariants.WORLD_MAP_WEB_HORIZON_DEFINE
const WORLD_MAP_WEB_PREFIX = ShaderVariants.WORLD_MAP_WEB_PREFIX
const WORLD_MAP_WEB_PREFIX_MICRO = ShaderVariants.WORLD_MAP_WEB_PREFIX_MICRO
const PK_WEB_MICRO_BOOT_META = ShaderVariants.PK_WEB_MICRO_BOOT_META
const WORLD_MAP_WEB_HIGH_BASE = ShaderVariants.WORLD_MAP_WEB_HIGH_BASE
const WORLD_MAP_WEB_HIGH_PREFIX = ShaderVariants.WORLD_MAP_WEB_HIGH_PREFIX
const WATER_WEB_HIGH_PREFIX = ShaderVariants.WATER_WEB_HIGH_PREFIX
const WATER_SHADER_PATH = ShaderVariants.WATER_SHADER_PATH
const WATER_PASS_PREFIX = ShaderVariants.WATER_PASS_PREFIX
const SPLIT_LAND_ONLY_DEFINE = ShaderVariants.SPLIT_LAND_ONLY_DEFINE
const SPLIT_WATER_ONLY_DEFINE = ShaderVariants.SPLIT_WATER_ONLY_DEFINE
const WORLD_MAP_SHADER_PATH = ShaderVariants.WORLD_MAP_SHADER_PATH
const CELL_FIELD_DEFINE = ShaderVariants.CELL_FIELD_DEFINE
const WATER_FIELD_MATCHES_LAND_DEFINE = ShaderVariants.WATER_FIELD_MATCHES_LAND_DEFINE
const CELL_FIELD_SETTING = ShaderVariants.CELL_FIELD_SETTING
const PK_WEB_CELL_FIELD_BOOT_META = ShaderVariants.PK_WEB_CELL_FIELD_BOOT_META
const CELL_FIELD_VERDICT_PASS = ShaderVariants.CELL_FIELD_VERDICT_PASS
const CELL_FIELD_VERDICT_FAIL = ShaderVariants.CELL_FIELD_VERDICT_FAIL
const CELL_FIELD_VERDICT_SKIPPED = ShaderVariants.CELL_FIELD_VERDICT_SKIPPED
const PK_WEB_CELL_FIELD_FORCE_META = ShaderVariants.PK_WEB_CELL_FIELD_FORCE_META

## Updates the world and water materials and manages the separate water draw pass.

static func _web_weather_layer_draw_allowed(host) -> bool:
	if not OS.has_feature("web"):
		return true
	if not host.PK_WEB_ENABLE_WEATHER_LAYER:
		return false
	return host.visual_quality >= 2 or host._mobile_quality_tier_define == "MOBILE_QUALITY_HIGH"


## 上一次推给天气层的门状态（只用于首帧/切档时打一行诊断）。


## 把「web + 是否高画质」推给 WeatherLayer 的画质门。
## 门状态在 WeatherLayer 内部与 fronts/LUT 条件取与，所以关着门时它不会被
## setup()/fronts 更新重新显示。画质设置、shader 档位切换都调这里。

static func _apply_weather_layer_render_gate(host) -> void:
	if host._weather_layer == null or not host._weather_layer.has_method("set_render_gate"):
		return
	var allowed: bool = _web_weather_layer_draw_allowed(host)
	host._weather_layer.set_render_gate(allowed)
	if OS.has_feature("web") and allowed != host._weather_gate_last_drawn:
		host._weather_gate_last_drawn = allowed
		print("[hex_renderer] web: WeatherLayer drawn=%s (visual_quality=%d tier=%s; web draws only at 高画质)" % [
			str(allowed), host.visual_quality, host._mobile_quality_tier_define])

static func sync_ripple_lattice(host) -> void:
	if host._ripple_table == null:
		return
	var phase: float = host._world_time * (host.water_flow_advection / 1.15)
	host._ripple_table.update_cycles(Vector4(floorf(phase * 0.04), floorf(phase * 0.04 + 0.5),
		floorf(phase * 0.06), floorf(phase * 0.06 + 0.5)))


static func _bind_ripple_lattice(host) -> void:
	if not host._water_uniform_names.has(&"water_ripple_lattice"):
		if host._ripple_table != null:
			host._ripple_table.queue_free()
			host._ripple_table = null
		return
	if host._ripple_table == null:
		host._ripple_table = WaterRippleLattice.new()
		host._ripple_table.setup(host._water_quad)
		sync_ripple_lattice(host)
	host._water_mat.set_shader_parameter("water_ripple_lattice", host._ripple_table.get_texture())


## [land-water-split 2026-11-02] 世界地图材质的统一 uniform 推送口。
## 陆地材质 _shader_mat 是权威；拆分后水面 program 必须与陆地**逐项同值**，否则两片
## 之间会有色差。这里把键值同时镜像给水面材质（只在它真的声明过该键时写，紧凑水的
## uniform 集合与主材质不同）。运行期 94 个 setter 的推送全部经过本函数，
## 保证 season / TOD / fog / 羊皮纸 / camera zoom / water 调参 / LUT 等不会只到一半。

static func _push_world_uniform(host, key: Variant, value: Variant) -> void:
	var key_name = StringName(key)
	if host._land_base_cache != null:
		host._land_base_cache.parameter_changed(key_name, value)
	if host._shader_mat != null:
		host._shader_mat.set_shader_parameter(key_name, value)
	if host._water_mat != null and not host._water_uniform_names.is_empty() \
			and host._water_uniform_names.has(key_name):
		host._water_mat.set_shader_parameter(key_name, value)


static func _global_sky_day_weight(host) -> float:
	if not host.day_night_enabled:
		return 1.0
	return smoothstep(-0.14, 0.14, sin(6.283185307179586 * host._day_phase))


static func configure_shader_clock(host, apply: Callable) -> void:
	host._apply_shader_clock = apply
	if host._apply_shader_clock.is_valid():
		host._apply_shader_clock.call(host.shader_days_per_game_year)


static func _push_eternal_daylight_uniforms(host) -> void:
	var min_elevation = deg_to_rad(host.eternal_min_elevation_deg)
	var max_hour_angle = deg_to_rad(host.eternal_max_hour_angle_deg)
	_push_world_uniform(host, "eternal_min_elevation_rad", min_elevation)
	_push_world_uniform(host, "eternal_max_hour_angle_rad", max_hour_angle)
	_push_water_lighting_uniforms(host)
	if host._building_visual_layer != null and host._building_visual_layer.has_method("set_eternal_daylight_parameters"):
		host._building_visual_layer.set_eternal_daylight_parameters(min_elevation, max_hour_angle)
	if host._weather_layer != null and host._weather_layer.has_method("set_eternal_daylight_parameters"):
		host._weather_layer.set_eternal_daylight_parameters(min_elevation, max_hour_angle)
	if host._fog_layer != null and host._fog_layer.has_method("set_eternal_daylight_parameters"):
		host._fog_layer.set_eternal_daylight_parameters(min_elevation, max_hour_angle)
	_for_each_vegetation_layer(host, func(layer) -> void:
		if layer.has_method("set_eternal_daylight_parameters"):
			layer.set_eternal_daylight_parameters(min_elevation, max_hour_angle)
	)
	ActivityLighting._sync_detail_and_activity_materials(host)


static func _bind_world_lighting_profile(host) -> void:
	if host._sky_background != null:
		var bounds = host._world.world_bounds if host._world != null else Rect2()
		host._sky_background.setup(bounds, host.world_lighting_profile, host._day_phase, host.day_night_enabled)
	if host._shader_mat != null:
		host._push_world_lighting_profile()


static func _shader_declares_uniform(host, shader: Shader, uniform_name: StringName) -> bool:
	if shader == null:
		return false
	for uniform in shader.get_shader_uniform_list():
		if StringName(uniform.get("name", "")) == uniform_name:
			return true
	return false


const WATER_PARAM_NAMES: Array[StringName] = [
	&"water_effect_enabled",
	&"ocean_current_enabled",
	&"water_waves_enabled",
	&"water_fresnel_enabled",
	&"water_sparkle_enabled",
	&"caustics_enabled",
	&"shallow_transparency_enabled",
	&"water_flow_wave_density",
	&"water_flow_advection",
	&"water_flow_wave_amplitude",
	&"water_flow_crest_strength",
	&"water_mark_strength",
	&"water_mark_coverage",
	&"water_base_normal_strength",
	&"water_base_normal_scale",
	&"water_wave_shade_strength",
	&"water_ripple_strength",
	&"water_ripple_detail_mix",
	&"water_ripple_scale",
	&"water_flow_drift_base",
	&"water_flow_drift_current",
	&"water_mark_length",
	&"water_mark_speed",
	&"water_rough_min",
	&"water_rough_max",
	&"water_rough_scale",
	&"water_rough_coverage",
	&"ocean_current_strength",
	&"water_reflection_strength",
	&"water_sss_strength",
	&"water_sss_power",
	&"water_sss_color",
	&"caustics_strength",
	&"shallow_transparency_factor",
	&"deep_ocean_contrast",
	&"deep_ocean_color_richness",
	&"deep_ocean_current_tint_strength",
	&"deep_ocean_latitude_tint_strength",
	&"deep_ocean_abyss_tint_strength",
	&"deep_ocean_patch_boost",
	&"water_cartoon_color_strength",
	&"water_calm_noise_brightness",
	&"water_calm_noise_tint_strength",
	&"water_wave_line_strength",
	&"water_domain_warp_strength",
	&"water_biome_blend_radius",
	&"water_transition_softness",
	&"estuary_plume_strength",
	&"lake_water_color",
	&"river_flow_enabled",
	&"river_flow_speed",
	&"river_flow_freq",
	&"water_wave_patch_strength",
	&"water_wave_patch_scale",
	&"water_detail_normal_strength",
	&"water_detail_normal_scale",
	&"water_detail_normal_warp",
]

## 水面参数的运行期推送：_shader_mat 还没创建（场景反序列化阶段）时安全跳过，
## 之后由 _push_water_params_to() 补推初值。

static func _push_water_param(host, key: StringName, value: Variant) -> void:
	if host._shader_mat != null:
		_push_world_uniform(host, key, value)


static func _assign_water_param(host, key: StringName, value: Variant) -> Variant:
	_push_water_param(host, key, value)
	return value


static func _assign_world_uniform(host, key: StringName, value: Variant) -> Variant:
	if host._shader_mat != null:
		_push_world_uniform(host, key, value)
	return value


static func _assign_shader_days_per_game_year(host, value: Variant) -> Variant:
	if host._apply_shader_clock.is_valid():
		host._apply_shader_clock.call(value)
	return value


static func _assign_weather_cloud_opacity(host, value: Variant) -> Variant:
	if host._weather_layer != null and is_instance_valid(host._weather_layer):
		host._weather_layer.set_cloud_opacity_scale(value)
	return value


static func _assign_cloud_shadow_debug_view(host, value: Variant) -> Variant:
	if host._cloud_shadow_field != null:
		host._cloud_shadow_field.set_debug_view(value)
	return value


static func _apply_surface_debug_view(host, was_split: bool) -> void:
	host._push_world_uniform("terrain_surface_debug_view", host.terrain_surface_debug_view)
	# [web-water-pass] 诊断色由 pass 1 整屏输出，水面 pass 必须整体让位。
	if host._water_mat != null:
		host._water_mat.set_shader_parameter(
			"terrain_surface_debug_view", host.terrain_surface_debug_view)
	# [land-water-split 2026-11-02] debug 视图必须回退单 program + 整张 quad
	# （13/14/16/17 等要全屏覆盖；gi_debug_view 只在陆地管线里，水面 program 复现不了）。
	# 拆分状态翻转时重编变体 + 重铺几何 + 重推全部 uniform。
	if was_split != host._split_active():
		host._refresh_split_configuration()


static func _apply_split_land_water_passes(host) -> void:
	# 重新允许尝试：上一次编译失败可能只是临时状态（shader 刚被编辑/驱动抖动）。
	host._split_program_failed = false
	host._water_pass_failed = false
	host._refresh_split_configuration()


## [cell-field 2026-11-18] export 开关（terrain_cell_field_enabled）翻转后的重建入口。
## PK_CELL_FIELD 是**编译期** define，光推 uniform 不够：必须重编陆地 program + 重选
## 水面 program（两个前缀都会变）。模板与 split_land_water_passes 一致 ——
## _refresh_split_configuration() 会重载 shader、重铺几何、重推全部 uniform，并在末尾按
## 新前缀建/拆水面 pass。
## [W6 2026-11-18] 开关打开却仍不启用，现在只剩**一个**原因：boot 自检结论不允许
## （fail / 受限平台上的 skipped / 尚未判定）。打一行警告：否则 GM 面板上看到的是
## 「开关打开了但画面没变」，属于最难查的一类静默。
static func _apply_cell_field_enabled(host) -> void:
	if host.terrain_cell_field_enabled and not ShaderVariants._cell_field_active(host):
		# [cell-field-web 2026-11-18] 把 boot 自检结论报出来：fail 时的现象与"未判定"
		# 完全一样（开关打开、画面没变），但处置方式相反（前者是硬件/驱动真的不行，后者是
		# 自检还没跑 —— 桌面 Compatibility 的调用点见 renderer_scene_services.gd::_ready）。
		push_warning("[hex_renderer/cell-field] PK_CELL_FIELD 未启用：boot 自检=%s、"
			% (ShaderVariants.cell_field_boot_verdict() if not ShaderVariants.cell_field_boot_verdict().is_empty()
				else "未判定")
			+ "强制开关=%s。W6 起变体准入恒真（预算 / world-min 两条排除已撤销），"
			% (ShaderVariants.cell_field_url_forced_verdict() if not ShaderVariants.cell_field_url_forced_verdict().is_empty()
				else "无")
			+ "所以只剩自检结论挡着：fail 的机器见遥测 cell_field_probe_fail，"
			+ "未判定的机器应确认 boot 探针调用点跑过。")
	host._refresh_split_configuration()


## 调试控制台 / GM 面板用的两个总开关入口（属性本身已带内联 setter，这里只多刷一次光照 uniform）。

static func set_water_effect_enabled(host, v: bool) -> void:
	host.water_effect_enabled = v
	_push_water_lighting_uniforms(host)


static func set_ocean_current_enabled(host, v: bool) -> void:
	host.ocean_current_enabled = v
	_push_water_lighting_uniforms(host)


static func set_map_baker(host, baker) -> void:
	host._map_baker = baker


static func set_ocean_current_debug(host, v: bool) -> void:
	host._ocean_current_debug = v
	if host._shader_mat != null:
		host._push_world_uniform("ocean_current_debug", host._ocean_current_debug)
	# 方案 0：仅当切到 true 且贴图缺失时才 lazy bake upwelling_tex。
	if host._ocean_current_debug and host._world != null and host._world.upwelling_tex == null \
			and host._map_baker != null and host._map_baker.has_method("rebake_upwelling_tex_for_debug"):
		var t0 := Time.get_ticks_msec()
		if host._map_baker.rebake_upwelling_tex_for_debug(host._world):
			print("[VisualOverhaul] ocean_current_debug → lazy baked upwelling_tex in %dms"
					% (Time.get_ticks_msec() - t0))
		if host._shader_mat != null:
			host._push_world_uniform("ocean_upwelling_tex", host._world.upwelling_tex)


static func get_ocean_current_debug(host) -> bool:
	return host._ocean_current_debug


## 把全部水面参数一次推给指定材质（主地形材质 / 独立水面材质）。

static func _push_water_params_to(host, sm: ShaderMaterial) -> void:
	if sm == null:
		return
	for n in host.WATER_PARAM_NAMES:
		sm.set_shader_parameter(n, host.get(n))
	sm.set_shader_parameter("water_detail_override", host._graphics_details.water_detail)


## 拆分状态 / 覆盖 mesh 开关翻转后的统一重建入口：重新选 program 变体 + 重铺几何
## + 重推全部 uniform（其末尾会按新的拆分状态建/拆水面 pass）。

static func _refresh_split_configuration(host) -> void:
	if not host.is_inside_tree() or host._world_quad == null:
		return
	if host._map == null or host._world == null:
		return
	host._load_shader()
	host._apply_world_quad_geometry()
	if host._shader_mat != null:
		host._apply_uniforms()


## 水面 program shader 变体编不过 → 整条拆分回退单 program（推迟到下一帧，避免在
## _sync_water_quad 的内部重入 _apply_uniforms）。只用于非 Web；Web 保持既有的
## "land-only + 暗海蓝占位"降级。

static func _apply_split_program_fallback(host) -> void:
	if not host._split_program_failed:
		return
	if host._world_quad == null or host._shader_mat == null:
		return
	push_warning("[hex_renderer/land-water-split] water program failed to compile; "
		+ "falling back to the single terrain program")
	host._load_shader()
	if host._map == null or host._world == null:
		return
	host._apply_world_quad_geometry()
	if host._shader_mat != null:
		host._apply_uniforms()


## 建/拆 + 几何 + uniform 全量对齐。重建材质、切换档位和换图走 _apply_uniforms()，
## 单项水面设置跨越编译变体时也会走这里。

static func _sync_water_quad(host) -> void:
	if not ShaderVariants._water_pass_active(host) or host._world_quad == null or host._world == null \
			or host._water_pass_failed:
		_drop_water_quad(host)
		return
	_ensure_water_quad(host)


## 无条件保证「节点存在 + 几何/树序/变体正确 + uniform 全量推送」。
## 与平台判定（_water_pass_active）分开，是为了让测试能直接驱动这条创建路径
## （见 tests/world/web_water_pass_node_test.gd / land_water_split_node_test.gd）。

static func _ensure_water_quad(host) -> void:
	var kind = ShaderVariants._resolved_water_program_kind(host)
	# tiled 布局切换会换掉 map_index/height 的 sampler **类型**（sampler2D ↔
	# sampler2DArray），variant 必须跟着重编；画质换档会换 MOBILE_QUALITY_* 前缀。
	# 两个维度任一变化都重建，不能复用旧的材质。稳态下是两次字符串比较。
	var prefix = ShaderVariants._water_program_prefix(host, kind)
	if host._water_quad != null and (host._water_variant_prefix != prefix or host._water_variant_kind != kind):
		_drop_water_quad(host)
	if host._water_quad == null:
		_create_water_quad(host, prefix, kind)
	if host._water_quad == null or not is_instance_valid(host._water_quad):
		return
	host._water_quad.mesh = _water_quad_mesh(host, host._world_quad.mesh)
	host._water_quad.visible = host._world_quad.visible
	_apply_water_uniforms(host)


## 拆分时水面 mesh 用覆盖 mesh；未启用 / 构建失败 ⇒ 与陆地共享整张 quad。

static func _water_quad_mesh(host, fallback: Mesh) -> Mesh:
	if host._coverage_water_mesh != null:
		return host._coverage_water_mesh
	return fallback


## 拆掉第二 pass 的节点与材质。先隐藏再 queue_free：queue_free 到帧末才生效，
## 不隐藏的话换档那一帧还会按旧变体多画一次水面。

static func _drop_water_quad(host) -> void:
	if host._water_quad != null:
		host._water_quad.visible = false
		host._water_quad.queue_free()
		host._water_quad = null
	host._water_mat = null
	if host._ripple_table != null:
		host._ripple_table.queue_free()
		host._ripple_table = null
	host._water_variant_prefix = ""
	host._water_variant_kind = ""
	host._water_program_kind = ""
	host._water_uses_world_map = false
	host._water_uniform_names.clear()


static func _create_water_quad(host, prefix: String, kind: String) -> void:
	# 刻意用 ResourceLoader.load 而不是 preload 常量：preload 是编译期的，桌面端
	# 也会把这份 shader 资源拉进依赖图。只有水面 pass 真的存在时才执行。
	var world_map_based = kind != "web_min"
	var water_path = host.WORLD_MAP_SHADER_PATH if world_map_based else host.WATER_SHADER_PATH
	var shader = ResourceLoader.load(
		water_path, "Shader", ResourceLoader.CACHE_MODE_IGNORE) as Shader
	if shader == null:
		push_warning("HexRenderer: water pass shader missing at %s" % water_path)
		return
	var variant = shader.duplicate() as Shader
	# tiled 与否必须与 world_map 用同一个宏（visual_tile_sampling 据此在
	# sampler2D / sampler2DArray 之间二选一）；quality / texture-budget / WATER_ONLY
	# 已在 prefix 里。紧凑水面程序再追加自己的 WATER_PASS_PREFIX（字节契约）。
	variant.code = prefix + ("" if world_map_based else WATER_PASS_PREFIX) + shader.code
	# 编译自检：shader 语言层编不过时 get_shader_uniform_list() 返回空。桌面/移动
	# 此时**整条拆分回退单 program**（不能只回退一半：陆地 program 此时不带水面分支，
	# 只回退水会露出空洞）。Web 维持既有降级：不建第二 pass，屏幕是 pass 1 的暗海蓝
	# 占位色（可控、可读）。驱动层失败（FXC）这里抓不到，那种情况同样退回占位色。
	if variant.get_shader_uniform_list().is_empty():
		host._water_pass_failed = true
		push_error("HexRenderer: water pass shader failed to compile (%s, kind=%s, prefix=%s)"
			% [water_path, kind, prefix.replace("\n", "|")])
		if not OS.has_feature("web"):
			host._split_program_failed = true
			host.call_deferred("_apply_split_program_fallback")
		return
	host._water_variant_prefix = prefix
	host._water_variant_kind = kind
	host._water_program_kind = kind
	host._water_uses_world_map = world_map_based
	host._water_uniform_names.clear()
	for param in variant.get_shader_uniform_list():
		host._water_uniform_names[StringName(param.name)] = true
	host._water_mat = ShaderMaterial.new()
	host._water_mat.shader = variant
	host._water_quad = MeshInstance2D.new()
	host._water_quad.name = "WorldWaterQuad"
	# z_index 与 _world_quad 同为 0（CanvasItem 先按 z_index、再按树序绘制），树序由
	# move_child 钉死在 _world_quad 紧后面 ⇒ 水面盖住陆地、又被灌草(1)/建筑(2)/树冠(3)盖住。
	# 必须 move_child 而不是依赖 add_child 顺序：画质从 MID 换回 LOW 时本节点是**后来**
	# 才创建的，直接 add_child 会排到植被层后面 → 水面盖住整片植被。
	host._water_quad.z_index = 0
	# FPS 探针（toggle_world_shader_disabled）关闭主 shader 时，两片必须一起关。
	host._water_quad.material = null if host._shader_disabled_by_toggle else host._water_mat
	host._graphics_details.attach_water_surface(host)
	_bind_ripple_lattice(host)
	# 预热对账：label 必须与 WebShaderWarmup 清单里那份（文件名去扩展名）逐字一致，
	# 否则 material_variant 事件永远对不上 warmup_shader 的 fp。桌面/移动拆分变体
	# 没有预热条目（不在 web 上编），不打 label。
	match kind:
		"high":
			WebTelemetry.note_variant("world_water_high", variant.code)
		"web_min":
			WebTelemetry.note_variant("world_water_web", variant.code)
	print("[hex_renderer] water pass created (pass 2 of 2; kind=%s)" % kind)


## 水面 pass 的 uniform 全量推送。web_min（紧凑水面）刻意只有 16 个（4 sampler +
## 12 标量/vec），与 world_map 的 186 个无关：这是它的全部输入。
## [land-water-split 2026-11-02] 走 world_map 的水面 program（Web HIGH / 桌面拆分）
## 复用主材质的整表拷贝（与 Web HIGH 原有逻辑同一份），保证 season/TOD/fog/羊皮纸/
## 光照/wrap/cell LUT/water_depth/noise 与陆地**逐项同值**；之后运行期的增量变化由
## _push_world_uniform() 镜像。
## 分工：几何/调色板/迷雾在各自已有的推送点补推（_push_fog_uniforms /
## _push_cell_lut_dims / _sync_cell_lut_textures / setter），这里负责"材质重建后
## 一次性把全部输入对齐"，与 _apply_uniforms() 的职责一一对应。

static func _apply_water_uniforms(host) -> void:
	host.RendererLightingBindings._apply_water_uniforms(
		host._shader_mat,
		host._water_mat,
		host._water_uses_world_map,
		host._world,
		host.parchment_strength,
		host.parchment_tint,
		host.terrain_ecotone_width,
		host.terrain_surface_debug_view,
		host._push_visual_tile_layout_uniforms,
		host._push_water_fog_uniforms,
		host._push_water_lighting_uniforms,
		host._push_water_params_to,
		host._visual_tiles_active,
		host._wrap_period_x,
		host._graphics_details.water_flowmap_enabled())


static func _push_water_lighting_uniforms(host) -> void:
	if host._water_mat == null:
		return
	host._water_mat.set_shader_parameter("visual_quality", host.visual_quality)
	host._water_mat.set_shader_parameter("season_phase", host._season_phase)
	host._water_mat.set_shader_parameter("day_phase", host._day_phase)
	host._water_mat.set_shader_parameter("axial_tilt_rad", deg_to_rad(host.axial_tilt_deg))
	host._water_mat.set_shader_parameter("day_night_enabled", host.day_night_enabled)
	host._water_mat.set_shader_parameter("water_effect_enabled", host.water_effect_enabled)
	host._water_mat.set_shader_parameter("ocean_current_enabled", host.ocean_current_enabled)
	host._water_mat.set_shader_parameter("tod_sun_dir", host._tod_sun_dir)
	host._water_mat.set_shader_parameter("tod_exposure", host._tod_exposure)
	host._water_mat.set_shader_parameter("tod_debug_sun_position_enabled", host._tod_debug_sun_position_enabled)
	host._water_mat.set_shader_parameter("tod_debug_sun_uv", host._tod_debug_sun_uv)
	host._water_mat.set_shader_parameter("tod_debug_sun_height_scale", host._tod_debug_sun_height_scale)
	host._water_mat.set_shader_parameter("eternal_min_elevation_rad", deg_to_rad(host.eternal_min_elevation_deg))
	host._water_mat.set_shader_parameter("eternal_max_hour_angle_rad", deg_to_rad(host.eternal_max_hour_angle_deg))


static func _configure_cloud_shadow_field(host) -> void:
	RendererCloudShadowBinding._configure_cloud_shadow_field(host)


static func _push_cloud_shadow_tuning(host) -> void:
	RendererCloudShadowBinding._push_cloud_shadow_tuning(host)


static func _push_cloud_shadow_material_inputs(host) -> void:
	RendererCloudShadowBinding._push_cloud_shadow_material_inputs(host)


## 迷雾口径与主地形**同一批值**：fog_k 来自同一张 enum_lut 的 A 通道，
## fog_early_out / fog_gray 的开关也必须是同一份（_push_fog_uniforms 里调用）。
## [land-water-split 2026-11-02] fog_unexplored_color 必须推：拆 mesh 后纯水 block
## 没有陆地 pass 兜底，水面 program 要自己画同一个迷雾色（Web 紧凑水面程序同样声明
## 了这个 uniform）。两片画同色是幂等的。

static func _push_water_fog_uniforms(host) -> void:
	if host._water_mat == null:
		return
	host._water_mat.set_shader_parameter("fog_gray_enabled", host._fog_enabled)
	host._water_mat.set_shader_parameter(
		"fog_early_out_enabled", host._effective_fog_early_out())
	host._water_mat.set_shader_parameter("fog_unexplored_color", FogOfWarLayer.UNEXPLORED_COLOR)


# Shader quality tier（mobile/web）：由 player_game / main._push_visual_toggles 推过来。
# 空字符串 = 桌面端 / 不 prepend define。可选值 "MOBILE_QUALITY_LOW" / "MID" / "HIGH"。


static func set_mobile_quality_tier(host, tier_define: String) -> void:
	var veg_tier = _mobile_quality_tier_from_define(host, tier_define)
	if host._resource_visual_layer != null:
		host._resource_visual_layer.set_quality(host.visual_quality, veg_tier if not tier_define.is_empty() else -1)
	_for_each_vegetation_layer(host, func(layer: ShrubLayer) -> void:
		layer.set_mobile_quality_tier(veg_tier)
	)
	if host._detail_family_layer != null and is_instance_valid(host._detail_family_layer) and host._map != null:
		host._detail_family_layer.configure(host._detail_layers, host.detail_scatter_family_renderer_enabled)
		if host.detail_scatter_family_renderer_enabled and host._camera_view_initialized:
			host._queue_missing_prefetch_detail_chunks()
			host._reactivate_deferred_detail_chunks()
	host._mark_detail_budget_total_dirty()
	host._apply_detail_global_budget()
	if host._weather_layer != null and host._weather_layer.has_method("set_mobile_quality_tier"):
		host._weather_layer.set_mobile_quality_tier(tier_define)
	if host._fog_layer != null:
		host._fog_layer.set_mobile_quality_tier(tier_define)
		host._apply_fog_early_out()
	if host._mobile_quality_tier_define == tier_define:
		return
	host._mobile_quality_tier_define = tier_define
	# web：?tier=high 这类 QA 档也算「高画质」，档位变化后重算天气层画质门。
	_apply_weather_layer_render_gate(host)
	# 重新加载 shader 让 #define 生效（hot toggle 时也走这条）
	if host._shader_mat != null:
		host._load_shader()
		# 关键：_load_shader 创建了新 ShaderMaterial 实例（disk source_mat.duplicate()），
		# 原本的 atlas uniform (height_tex/enum_atlas/dyn_atlas_smooth_atlas 等) 都是 null。
		# 必须重新 push 所有 uniform，否则 fragment 拿到 null texture → 输出全白 / 失败。
		# bug fix（log_next.txt 2026-06-15 14:13 shader.dyn_atlas_smooth=<null> 即症状）。
		if host._map != null and host._world != null and host._shader_mat != null:
			host._apply_uniforms()
	_configure_cloud_shadow_field(host)
	_push_cloud_shadow_material_inputs(host)


static func _mobile_quality_tier_from_define(host, tier_define: String) -> int:
	match tier_define:
		"MOBILE_QUALITY_LOW":
			return 0
		"MOBILE_QUALITY_HIGH":
			return 2
		_:
			return 1


static func _for_each_vegetation_layer(host, callable: Callable) -> void:
	for layer in host._detail_layers:
		if layer != null:
			callable.call(layer)


static func set_simulation_speed_multiplier(host, multiplier: float) -> void:
	host._simulation_speed_multiplier = maxf(0.0, multiplier)
	host._clock_speed_multiplier = host._simulation_speed_multiplier


static func set_clock_running(host, running: bool) -> void:
	host._clock_running = running


static func _visual_tiles_active(host) -> bool:
	return ShaderVariants._visual_tiles_active(host)


static func micro_url_value_enabled(raw: String) -> bool:
	return ShaderVariants.micro_url_value_enabled(raw)


static func web_map_micro_url_enabled() -> bool:
	return ShaderVariants.web_map_micro_url_enabled()


static func web_map_web_prefix_active() -> String:
	return ShaderVariants.web_map_web_prefix_active()


static func web_warmup_program_prefixes() -> Dictionary:
	return ShaderVariants.web_warmup_program_prefixes()


static func _web_pc_high_active(host) -> bool:
	return ShaderVariants._web_pc_high_active(host)


static func _cloud_shadow_direct_active(host) -> bool:
	return ShaderVariants._cloud_shadow_direct_active(host)


static func _world_map_web_min_active(host) -> bool:
	return ShaderVariants._world_map_web_min_active(host)


static func cell_field_setting_enabled() -> bool:
	return ShaderVariants.cell_field_setting_enabled()


static func cellfield_url_verdict(raw: String) -> String:
	return ShaderVariants.cellfield_url_verdict(raw)


static func cell_field_url_forced_verdict() -> String:
	return ShaderVariants.cell_field_url_forced_verdict()


static func cell_field_boot_verdict() -> String:
	return ShaderVariants.cell_field_boot_verdict()


static func cell_field_boot_decided() -> bool:
	return ShaderVariants.cell_field_boot_decided()


static func set_cell_field_boot_verdict(verdict: String) -> bool:
	return ShaderVariants.set_cell_field_boot_verdict(verdict)


static func reset_cell_field_boot_state() -> void:
	ShaderVariants.reset_cell_field_boot_state()


static func cell_field_boot_allows() -> bool:
	return ShaderVariants.cell_field_boot_allows()


static func cell_field_prefix_for_variant(budget_variant: bool, world_min: bool,
		enabled: bool) -> String:
	return ShaderVariants.cell_field_prefix_for_variant(budget_variant, world_min, enabled)


static func _cell_field_active(host) -> bool:
	return ShaderVariants._cell_field_active(host)


static func cell_field_variant_allowed(budget_variant: bool, world_min: bool) -> bool:
	return ShaderVariants.cell_field_variant_allowed(budget_variant, world_min)


static func _cell_field_prefix(host) -> String:
	return ShaderVariants._cell_field_prefix(host)


static func _split_active(host) -> bool:
	return ShaderVariants._split_active(host)


static func _water_pass_active(host) -> bool:
	return ShaderVariants._water_pass_active(host)


static func _resolved_water_program_kind(host) -> String:
	return ShaderVariants._resolved_water_program_kind(host)


static func _water_program_prefix(host, kind: String) -> String:
	return ShaderVariants._water_program_prefix(host, kind)


static func _is_world_map_shader_path(host, path: String) -> bool:
	return ShaderVariants._is_world_map_shader_path(host, path)


static func _desktop_sky_quality_prefix(host) -> String:
	return ShaderVariants._desktop_sky_quality_prefix(host)


static func _apply_shader_variant_prefix(host, shader: Shader, source_path: String) -> Shader:
	return ShaderVariants._apply_shader_variant_prefix(host, shader, source_path)


static func _shader_quality_define_prefix(host, tier_define: String) -> String:
	return ShaderVariants._shader_quality_define_prefix(host, tier_define)


static func configure_trade_visuals(host, layer: TradeActivityLayer, world: WorldData) -> void:
	ActivityLighting.configure_trade_visuals(host, layer, world)


static func configure_military_visuals(host, layer: MilitaryArmyTokenLayer) -> void:
	ActivityLighting.configure_military_visuals(host, layer)


static func _instance_daylight_parameters(host) -> Dictionary:
	return ActivityLighting._instance_daylight_parameters(host)


static func _sync_trade_daylight(host) -> void:
	ActivityLighting._sync_trade_daylight(host)


static func _sync_military_daylight(host) -> void:
	ActivityLighting._sync_military_daylight(host)


static func _sync_detail_and_activity_materials(host) -> void:
	ActivityLighting._sync_detail_and_activity_materials(host)
