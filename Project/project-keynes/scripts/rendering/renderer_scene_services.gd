extends RefCounted

## Stateless collaborator for ShrubLayer.

# ─── 任务 1：性能采样器（30 秒窗口内 avg + P95） ───────────────────────
# 统计窗口通过 ring buffer，不分配；每 REPORT_INTERVAL_SEC 打印一次结果。
# 默认关闭，只有 perf_sampler_enabled == true 时才统计与打印。
## Ring-buffer frame sampler owned by the renderer-services collaborator. The
## host keeps only the RefCounted instance and the on/off switch.
class PerfSampler extends RefCounted:
	const REPORT_INTERVAL_SEC: float = 30.0
	const MAX_SAMPLES: int = 1800  # 30s × 60fps
	var _samples: PackedFloat32Array
	var _write_idx: int = 0
	var _count: int = 0
	var _elapsed: float = 0.0
	var _label: String = "PerfSampler"

	func _init() -> void:
		_samples = PackedFloat32Array()
		_samples.resize(MAX_SAMPLES)

	func set_label(l: String) -> void:
		_label = l

	func push_frame_ms(frame_ms: float) -> void:
		_samples[_write_idx] = frame_ms
		_write_idx = (_write_idx + 1) % MAX_SAMPLES
		if _count < MAX_SAMPLES:
			_count += 1
		_elapsed += frame_ms / 1000.0
		if _elapsed >= REPORT_INTERVAL_SEC:
			_report()
			_elapsed = 0.0

	func reset() -> void:
		_write_idx = 0
		_count = 0
		_elapsed = 0.0

	func _report() -> void:
		if _count <= 0:
			return
		var sorted := PackedFloat32Array()
		sorted.resize(_count)
		for i in range(_count):
			sorted[i] = _samples[i]
		var arr := Array(sorted)
		arr.sort()
		var total: float = 0.0
		for v in arr:
			total += float(v)
		var avg: float = total / float(_count)
		var p95_idx: int = clampi(int(float(_count) * 0.95), 0, _count - 1)
		var p95: float = float(arr[p95_idx])
		var avg_fps: float = 1000.0 / maxf(avg, 0.001)
		print_rich(
			"[color=cyan][%s][/color] 30s samples=%d  avg=%.2fms (%.1f FPS)  P95=%.2fms" %
			[_label, _count, avg, avg_fps, p95]
		)


static func _after_hex_size(host) -> void:

	if host.is_inside_tree():
		host._rebuild()


static func _after_world_material(host) -> void:

	if host.is_inside_tree():
		host._load_shader()
		if host._map != null and host._world != null:
			host._rebuild()


static func _after_world_lighting_profile(host) -> void:

	if host.is_inside_tree():
		host._bind_world_lighting_profile()

static func _ready(host) -> void:

	# [parallax-rain] 初始化俯视角度
	host._camera_pitch = deg_to_rad(host.camera_pitch_deg)
	host._wind_dir = host.wind_dir.normalized() if host.wind_dir.length_squared() > 0.0001 else Vector2(0.3, 1.0)
	host._wind_strength = host.wind_strength
	host._sky_background = host.WorldSkyBackgroundScript.new()
	host._sky_background.name = "WorldSkyBackground"
	host.add_child(host._sky_background)
	host._world_quad = MeshInstance2D.new()
	host._world_quad.name = "WorldQuad"
	host._world_quad.z_index = 0
	host.add_child(host._world_quad)
	host._building_visual_layer = host.BuildingVisualLayerScript.new()
	host._building_visual_layer.name = "BuildingVisualLayer"
	host.add_child(host._building_visual_layer)
	host._resource_visual_layer = host.ResourceVisualLayerScript.new()
	host._resource_visual_layer.name = "ResourceVisualLayer"
	host.add_child(host._resource_visual_layer)
	if host._building_visual_layer.has_method("set_world_ext"):
		host._building_visual_layer.set_world_ext(host._world_ext)
	# Buildings share the same astronomical daylight state as terrain,
	# weather, fog and vegetation. Push cached values immediately because this
	# layer is created before the first WorldClock/TODProfile notification.
	host._building_visual_layer.set_season_phase(host._season_phase)
	host._building_visual_layer.set_day_phase(host._day_phase)
	host._building_visual_layer.set_axial_tilt_rad(deg_to_rad(host.axial_tilt_deg))
	host._building_visual_layer.set_eternal_daylight_parameters(deg_to_rad(host.eternal_min_elevation_deg), deg_to_rad(host.eternal_max_hour_angle_deg))
	host._building_visual_layer.set_day_night_enabled(host.day_night_enabled)
	host._building_visual_layer.set_tod_debug_sun_position(
		host._tod_debug_sun_position_enabled, host._tod_debug_sun_uv)
	host._building_visual_layer.set_tod_debug_sun_height_scale(
		host._tod_debug_sun_height_scale)
	host._building_visual_layer.set_tod_sun_dir(host._tod_sun_dir)
	host._building_visual_layer.set_tod(
		host._tod_sun_color, host._tod_ambient_color, host._tod_night_factor, host._tod_exposure)
	host._spawn_detail_layers()
	host._cloud_shadow_field = host.CloudShadowFieldScript.new()
	host._cloud_shadow_field.name = "CloudShadowField"
	host.add_child(host._cloud_shadow_field)
	host._cloud_shadow_field.process_priority = 1001
	# v9.split：天气表现层。始终创建；web 侧不再 stub，而是走 weather_layer 内部的
	# 裁剪变体（`#define PK_WEB_WEATHER_MIN`，见 weather_layer.gd 的 WEB_WEATHER_MIN_DEFINE）。
	# 历史：完整 weather_overlay.gdshader 首次编译在 ANGLE 上要 45 秒（进世界卡 98%
	# 的元凶）；裁剪变体把云路径的 fbm/sin/循环全部去掉后编译成本降到可接受。
	if host.PK_WEB_MINIMAL_LAYERS and OS.has_feature("web") and not host.PK_WEB_LAYER_WEATHER:
		host._weather_layer = null
	else:
		host._weather_layer = WeatherLayer.new()
	host._weather_layer.name = "WeatherLayer"
	host._weather_layer.visual_fronts_changed.connect(host._on_weather_layer_visual_fronts_changed)
	host.add_child(host._weather_layer)
	# 帧间插值时序:让 weather_layer._process 最晚执行,保证在 LUT 烘焙(SUS/DC 系统)之后、同帧渲染前
	# 检测到 weather_lut_update_usec 变化并把 weather_lerp 归 0 → 消除"curr 已换帧但 lerp 还未重置"的一帧频闪。
	host._weather_layer.process_priority = 1000
	# web：低 / 中 / auto 画质不绘制天气层，只有高画质才画。
	# 用画质门而不是一次性 host.visible=false：WeatherLayer._refresh_visibility() 会在
	# setup()/fronts 更新时把 host.visible 重新置 true，只有门能挡住那次重开。
	host._apply_weather_layer_render_gate()
	if host._world != null and host._weather_layer.has_method("set_world_ref"):
		host._weather_layer.set_world_ref(host._world)  # 帧间插值:供 weather_layer 取 weather_lut_prev_tex
	# 国界线（z=6，在数据 overlay 之上）与视野迷雾（z=12，盖住天气/高亮/国界）。
	# 与 WeatherLayer 同套：代码创建 + 世界坐标几何，不进 .tscn。
	if host.PK_WEB_MINIMAL_LAYERS and OS.has_feature("web") and not host.PK_WEB_LAYER_BORDER:
		host._border_layer = null
	else:
		host._border_layer = CountryBorderLayer.new()
	host._border_layer.name = "CountryBorderLayer"
	host.add_child(host._border_layer)
	if host.PK_WEB_MINIMAL_LAYERS and OS.has_feature("web") and not host.PK_WEB_LAYER_FOG:
		host._fog_layer = null
	else:
		host._fog_layer = FogOfWarLayer.new()
	host._fog_layer.name = "FogOfWarLayer"
	host.add_child(host._fog_layer)
	_load_shader(host, )
	if host._map != null and host._world != null:
		host._rebuild()
	host.set_process(true)


## Web 天气层是否允许**绘制**。桌面 / 移动恒 true（不受画质设置影响）。
## 「高画质」= 玩家设置「高」（visual_quality >= 2），或 QA 的 ?tier=high
## （autotest 直接把 mobile tier 推到 HIGH，此路径按高画质处理）。

static func _process(host, delta: float) -> void:

	host._poll_shader_hot_reload(delta)
	if host._shader_mat == null:
		return
	host._sync_cell_lut_dims()
	host._sync_cell_lut_textures()
	if host._clock_running:
		host._world_time += delta * host._clock_speed_multiplier
	host._push_world_uniform("world_time", host._world_time)
	if host._cloud_shadow_field != null and is_instance_valid(host._cloud_shadow_field) \
			and host._cloud_shadow_field.has_method("set_world_time"):
		host._cloud_shadow_field.set_world_time(host._world_time)
	var wind_boost = host._detail_wind_boost * host.weather_strength
	if host.detail_scatter_family_renderer_enabled and host._detail_family_layer != null \
			and is_instance_valid(host._detail_family_layer):
		host._detail_family_layer.set_frame_state(host._world_time, host._detail_wind_dir, wind_boost)
	else:
		host._for_each_vegetation_layer(func(layer: ShrubLayer) -> void:
			layer.set_world_time(host._world_time)
			layer.set_wind_field(host._detail_wind_dir, wind_boost)
		)
	_sweep_dormant_detail_chunks(host, )
	var drain_started_usec = Time.get_ticks_usec()
	if host._resource_visual_layer != null:
		host._resource_visual_layer.prepare_frame(host._world_time, host._tod_sun_dir, {
			"season_phase": host._season_phase,
			"day_phase": host._day_phase,
			"axial_tilt_rad": deg_to_rad(host.axial_tilt_deg),
			"day_night_enabled": host.day_night_enabled,
			"tod_debug_sun_position_enabled": host._tod_debug_sun_position_enabled,
			"tod_debug_sun_uv": host._tod_debug_sun_uv,
			"tod_debug_sun_height_scale": host._tod_debug_sun_height_scale,
			"eternal_min_elevation_rad": deg_to_rad(host.eternal_min_elevation_deg),
			"eternal_max_hour_angle_rad": deg_to_rad(host.eternal_max_hour_angle_deg),
			"tod_sun_dir": host._tod_sun_dir,
			"tod_exposure": host._tod_exposure,
			"wind_dir": host._detail_wind_dir,
			"weather_wind_boost": wind_boost})
	host._resource_visual_cpu_ms = float(Time.get_ticks_usec() - drain_started_usec) / 1000.0
	host._drain_detail_refresh_queue()
	host._last_detail_drain_ms = float(Time.get_ticks_usec() - drain_started_usec) / 1000.0
	# 加载期把散布构建 defer 给这条运行期路径，所以这里必须有一个"永不出现"的兜底。
	host._poll_deferred_detail_fill_watchdog()
	# 任务 1：性能采样（仅当 perf_sampler_enabled 为 true 时启用）
	if host._perf_sampler != null:
		host._perf_sampler.push_frame_ms(delta * 1000.0)



static func set_world_ext(host, ext) -> void:

	host._world_ext = ext
	if host._building_visual_layer != null and host._building_visual_layer.has_method("set_world_ext"):
		host._building_visual_layer.set_world_ext(ext)
	for layer in host._detail_layers:
		if layer != null and layer.has_method("set_world_ext"):
			layer.set_world_ext(ext)



static func _poll_shader_hot_reload(host, delta: float) -> void:

	if not host.shader_hot_reload_enabled:
		return
	host._shader_hot_reload_accum += delta
	if host._shader_hot_reload_accum < maxf(host.shader_hot_reload_interval, 0.1):
		return
	host._shader_hot_reload_accum = 0.0

	var shader_mtime: int = _file_modified_time(host, host._active_shader_source_path)
	var material_mtime: int = _file_modified_time(host, host._active_material_source_path)
	var shader_changed: bool = shader_mtime > 0 and host._shader_source_mtime > 0 \
			and shader_mtime != host._shader_source_mtime
	var material_changed: bool = material_mtime > 0 and host._material_source_mtime > 0 \
			and material_mtime != host._material_source_mtime
	if not shader_changed and not material_changed:
		if host._shader_source_mtime == 0:
			host._shader_source_mtime = shader_mtime
		if host._material_source_mtime == 0:
			host._material_source_mtime = material_mtime
		return

	# [land-water-split 2026-11-02] shader 源文件热重载：两片 program 都要从磁盘重新
	# 取（水面 program 可能是同一份 world_map.gdshader 的另一个变体）。上一次编译失败
	# 可能只是编辑中的临时状态，这里清掉失败标记重新尝试。
	host._water_pass_failed = false
	host._split_program_failed = false
	host._drop_water_quad()
	host._load_shader()
	if host._map != null and host._world != null and host._shader_mat != null:
		host._apply_uniforms()
	host._push_cloud_shadow_material_inputs()
	print("[HexRenderer] hot-reloaded world shader/material")



static func _file_modified_time(_host, path: String) -> int:

	if path == "":
		return 0
	var fs_path := path
	if path.begins_with("res://") or path.begins_with("user://"):
		fs_path = ProjectSettings.globalize_path(path)
	return int(FileAccess.get_modified_time(fs_path))


static func _refresh_shader_hot_reload_baseline(host) -> void:

	host._shader_source_mtime = _file_modified_time(host, host._active_shader_source_path)
	host._material_source_mtime = _file_modified_time(host, host._active_material_source_path)


static func get_last_detail_drain_ms(host) -> float:

	return host._last_detail_drain_ms



static func _sweep_dormant_detail_chunks(host) -> void:

	if not host.detail_scatter_family_renderer_enabled or not host._camera_view_initialized:
		return
	var now_msec = Time.get_ticks_msec()
	if now_msec < host._detail_next_resident_sweep_msec:
		return
	host._detail_next_resident_sweep_msec = now_msec + 250
	var retention_msec = maxi(250, int(round(host.detail_scatter_resident_retention_seconds * 1000.0)))
	var evicted = 0
	for layer in host._detail_layers:
		if layer != null and is_instance_valid(layer) \
				and layer.has_method("evict_dormant_detail_chunks"):
			evicted += int(layer.evict_dormant_detail_chunks(now_msec, retention_msec))
	if host._detail_family_layer != null and is_instance_valid(host._detail_family_layer) \
			and host._detail_family_layer.has_method("evict_dormant_chunks"):
		var family_evicted = int(
			host._detail_family_layer.evict_dormant_chunks(now_msec, retention_msec))
		host._detail_evicted_superchunks += family_evicted
		evicted += family_evicted
	if evicted > 0:
		host._mark_detail_budget_total_dirty()


static func _load_shader(host) -> void:

	# PROBE(2026-10-30)：web 上把世界地图材质换成 3 行 shader，用来确认那次
	# ~45s 首帧到底是不是 world_map.gdshader 的编译开销。
	# 确认后把 PK_WEB_TRIVIAL_WORLD_SHADER_PROBE 置回 false，并改成裁剪版变体。
	if host.PK_WEB_TRIVIAL_WORLD_SHADER_PROBE and OS.has_feature("web"):
		var probe_shader = Shader.new()
		probe_shader.code = "shader_type canvas_item;\nvoid fragment() { COLOR = vec4(0.15, 0.25, 0.4, 1.0); }\n"
		var probe_mat = ShaderMaterial.new()
		probe_mat.shader = probe_shader
		host._shader_mat = probe_mat
		host._active_material_source_path = "<web-probe>"
		host._active_shader_source_path = "<web-probe>"
		if host._world_quad != null:
			host._world_quad.material = probe_mat
		print("[probe] web trivial world shader active (45s first-frame isolation)")
		return
	var next_mat: ShaderMaterial = null
	# 新材质从 .tres 重建，lut_dims 回到默认 (1,1)；作废记录让 _sync_cell_lut_dims
	# 在 _apply_uniforms 万一没跟上时也能补推。
	host._pushed_lut_dims = Vector2i.ZERO
	host._active_material_source_path = ""
	host._active_shader_source_path = ""

	if host.world_material != null:
		var source_mat = host.world_material
		host._active_material_source_path = source_mat.resource_path
		if source_mat.resource_path != "":
			var disk_mat = ResourceLoader.load(
				source_mat.resource_path,
				"ShaderMaterial",
				ResourceLoader.CACHE_MODE_IGNORE
			) as ShaderMaterial
			if disk_mat != null:
				source_mat = disk_mat
				host._active_material_source_path = disk_mat.resource_path
		next_mat = source_mat.duplicate() as ShaderMaterial
		if next_mat != null:
			var shader = _load_fresh_shader_for_material(host, next_mat)
			if shader != null:
				next_mat.shader = shader
			if next_mat.shader != null:
				host._lut_bound.clear()
				host._shader_mat = next_mat
				host._world_quad.material = host._shader_mat
				host._refresh_shader_hot_reload_baseline()
				_validate_world_program_variant(host, )
				return
		push_warning("HexRenderer: world_material has no shader; falling back to %s" % host.shader_path)

	var fallback_shader = ResourceLoader.load(host.shader_path, "Shader", ResourceLoader.CACHE_MODE_IGNORE) as Shader
	if fallback_shader == null:
		push_warning("HexRenderer: shader not found at %s" % host.shader_path)
		host._world_quad.material = null
		return
	host._shader_mat = ShaderMaterial.new()
	host._shader_mat.shader = host._apply_shader_variant_prefix(fallback_shader, host.shader_path)
	host._world_quad.material = host._shader_mat
	host._active_shader_source_path = host.shader_path
	host._refresh_shader_hot_reload_baseline()
	_validate_world_program_variant(host, )


## [land-water-split 2026-11-02] 陆地 program 自检：拆分激活时主材质是 land-only 变体，
## 若它在 shader 语言层编不过（get_shader_uniform_list 为空），整条拆分回退单 program，
## 否则水面会被 discard 成背景空洞。递归深度恒为 1（置位后 _split_active() 为 false）。
## Web 保持既有行为（LAND_ONLY 前缀是字节契约，不做运行期换变体）。

static func _validate_world_program_variant(host) -> void:

	if host._shader_mat == null or host._shader_mat.shader == null:
		return
	if OS.has_feature("web"):
		return
	if not host._split_active():
		return
	if not host._shader_mat.shader.get_shader_uniform_list().is_empty():
		return
	push_error("HexRenderer: split land program failed to compile; falling back to "
		+ "the single terrain program")
	host._split_program_failed = true
	_load_shader(host, )


static func _load_fresh_shader_for_material(host, mat: ShaderMaterial) -> Shader:

	var source_path = host.shader_path
	if mat.shader != null and mat.shader.resource_path != "":
		source_path = mat.shader.resource_path
	host._active_shader_source_path = source_path
	if source_path == "":
		return mat.shader
	var shader = ResourceLoader.load(source_path, "Shader", ResourceLoader.CACHE_MODE_IGNORE) as Shader
	if shader == null:
		push_warning("HexRenderer: shader not found at %s" % source_path)
		return mat.shader
	# mobile/web 质量档编译时变体：prepend #define MOBILE_QUALITY_*
	# 让 GPU 编译独立 shader 二进制。tier 由 player_game / main 推送。
	return host._apply_shader_variant_prefix(shader, source_path)



static func set_map(host, map: MapData, world: WorldData = null) -> void:

	if host._world != null and world != null and host._world != world \
			and host._visual_tile_horizon_baker != null:
		host._visual_tile_horizon_baker.cancel()
	host._map = map
	host._world = world
	host._bind_world_lighting_profile()
	# _ready() loads the shader before a generated world exists, so it necessarily
	# selects the legacy variant. Re-select after world injection; setting array
	# uniforms on that legacy shader is ignored and leaves map_index_atlas unbound.
	if host.is_inside_tree() and host._world_quad != null:
		var load_t0 = Time.get_ticks_usec()
		_load_shader(host, )
		print("[loading-renderer-step] shader %.1fms" % [float(Time.get_ticks_usec()-load_t0)/1000.0])
	if host._weather_layer != null and host._weather_layer.has_method("set_world_ref"):
		host._weather_layer.set_world_ref(host._world)  # 帧间插值:weather_lut_prev_tex 源
	# [terrain-horizon-gpu 2026-07-03] map_baker 若登记了 GPU 离屏烘焙，这里在场景树内发起。
	var horizon_t0 = Time.get_ticks_usec()
	host._maybe_bake_terrain_horizon_gpu()
	print("[loading-renderer-step] horizon %.1fms" % [float(Time.get_ticks_usec()-horizon_t0)/1000.0])
	if host.is_inside_tree():
		host._rebuild()


static func set_map_cooperative(host, map: MapData, world: WorldData = null) -> void:

	if host._world != null and world != null and host._world != world \
			and host._visual_tile_horizon_baker != null:
		host._visual_tile_horizon_baker.cancel()
	host._map = map
	host._world = world
	host._bind_world_lighting_profile()
	# _ready() loads the shader before a generated world exists, so it necessarily
	# selects the legacy variant. Re-select after world injection; setting array
	# uniforms on that legacy shader is ignored and leaves map_index_atlas unbound.
	if host.is_inside_tree() and host._world_quad != null:
		var load_t0 = Time.get_ticks_usec()
		_load_shader(host, )
		print("[loading-renderer-step] shader %.1fms" % [float(Time.get_ticks_usec()-load_t0)/1000.0])
	if host._weather_layer != null and host._weather_layer.has_method("set_world_ref"):
		host._weather_layer.set_world_ref(host._world)  # 帧间插值:weather_lut_prev_tex 源
	# [terrain-horizon-gpu 2026-07-03] map_baker 若登记了 GPU 离屏烘焙，这里在场景树内发起。
	var horizon_t0 = Time.get_ticks_usec()
	host._maybe_bake_terrain_horizon_gpu()
	print("[loading-renderer-step] horizon %.1fms" % [float(Time.get_ticks_usec()-horizon_t0)/1000.0])
	if host.is_inside_tree():
		await host._rebuild_cooperative()




static func configure_building_visuals(host, catalog: Dictionary,
		intel: BuildingVisualIntelCache) -> Dictionary:

	if host._building_visual_layer == null:
		return {"ok": false, "reason": "building_visual_layer_unavailable"}
	if host._resource_visual_layer != null:
		host._resource_visual_layer.set_quality(host.visual_quality,
			host._mobile_quality_tier_from_define(host._mobile_quality_tier_define) if not host._mobile_quality_tier_define.is_empty() else -1)
		var resource_result: Dictionary = host._resource_visual_layer.configure(host._map, host._world, host.hex_size, intel)
		host._resource_visual_layer.set_terrain_lighting(host._shader_mat)
		if not bool(resource_result.get("ok", false)):
			push_error("Resource visual catalog: %s" % str(resource_result))
	var building_result: Dictionary = host._building_visual_layer.configure(
		host._map, host._world, host.hex_size, catalog, intel)
	# [building-terrain-light 2026-10-18] 高画质建筑与地形共用 horizon/GI 与地表法线。
	host._building_visual_layer.set_terrain_lighting(host._shader_mat)
	host._push_cloud_shadow_material_inputs()
	return building_result



static func set_resource_visual_context(host, fog_enabled: bool, seed_value: int = 0) -> void:

	if host._resource_visual_layer != null:
		host._resource_visual_layer.set_context(fog_enabled, seed_value)



static func set_resource_visual_filter(host, stable_id: String) -> void:

	if host._resource_visual_layer != null:
		host._resource_visual_layer.set_filter(stable_id)



static func set_resource_visual_lens(host, enabled: bool) -> void:

	if host._resource_visual_layer != null:
		host._resource_visual_layer.set_lens(enabled)



static func resource_visual_lens_enabled(host) -> bool:

	return host._resource_visual_layer != null and host._resource_visual_layer.lens_enabled()



static func resource_visual_diagnostics(host) -> Dictionary:

	return host._resource_visual_layer.diagnostics() if host._resource_visual_layer != null else {}



static func update_building_visual_intel(host, intel: BuildingVisualIntelCache,
		changed_cells: PackedInt32Array) -> void:

	if host._resource_visual_layer != null:
		host._resource_visual_layer.notify_cells(changed_cells)
	if host._building_visual_layer != null:
		host._building_visual_layer.update_intel(intel, changed_cells)
	var core_buckets = intel.settlement_core_buckets()
	host._for_each_vegetation_layer(func(layer: ShrubLayer) -> void:
		if layer.has_method("set_settlement_core_buckets"):
			layer.set_settlement_core_buckets(core_buckets)
	)
	if not changed_cells.is_empty():
		# Vegetation candidates overlap adjacent hexes by design. A tree whose
		# source is a neighbouring cell can already occupy this settlement core,
		# so rebuilding only the changed cell leaves stale cross-cell canopies.
		host.queue_detail_scatter_refresh(
			_expand_building_detail_refresh_cells(host, changed_cells))



static func _expand_building_detail_refresh_cells(host, 
		changed_cells: PackedInt32Array) -> PackedInt32Array:

	if host._map == null or changed_cells.is_empty():
		return changed_cells
	var count = host._map.cell_count()
	var neighbours: PackedInt32Array = host._map.neighbor_indices_packed() \
		if host._map.has_indices() else PackedInt32Array()
	var selected = {}
	for cell_idx in changed_cells:
		if cell_idx < 0 or cell_idx >= count:
			continue
		selected[cell_idx] = true
		if neighbours.size() < count * 6:
			continue
		var base = cell_idx * 6
		for direction in 6:
			var neighbour = int(neighbours[base + direction])
			if neighbour >= 0 and neighbour < count:
				selected[neighbour] = true
	var ordered: Array = selected.keys()
	ordered.sort()
	return PackedInt32Array(ordered)



static func building_visual_diagnostics(host) -> Dictionary:

	return host._building_visual_layer.diagnostics() \
		if host._building_visual_layer != null else {"ok": false}



static func building_settlement_core_bucket(host, cell_idx: int) -> int:

	return host._building_visual_layer.settlement_core_bucket(cell_idx) \
		if host._building_visual_layer != null else 0


static func get_world_bounds(host) -> Rect2:

	if host._world != null:
		return host._world.world_bounds
	if host._map != null and host._map.cell_count() > 0:
		return MapBaker.compute_world_bounds(host._map.width, host._map.height, host.hex_size)
	return Rect2()

## 国界线层。领土变更（country_committed）后由 WorldRuntimeHost 调 rebuild()。
# Keep this accessor's boundary a native Node type. In Godot 4.6.3, resolving
# CountryBorderLayer as this return type from WorldRuntimeHost/PlayerGame keeps
# the callers' script dependency graph alive at shutdown (even without a world).
# The layer itself and its owned field remain strongly typed.

static func country_border_layer(host) -> Node2D:

	return host._border_layer

## 视野迷雾层。迷雾值本身走 enum_lut.a，本层只负责画云。

static func fog_of_war_layer(host) -> FogOfWarLayer:

	return host._fog_layer

## 同时开关迷雾层与主地形的迷雾响应。fog 关时主地形完全恢复改造前的行为
## （灰化与早退都是纯 uniform 分支，关掉即零成本）。
## early_out 是可开关的性能实验：净收益取决于厚云是否真的比被跳过的地形便宜，
## 必须靠 headless perf A/B 决定，默认关。它还要求迷雾层在未探索处输出常量色，
## 因此只有迷雾最低档才真正放行（见 _apply_fog_early_out）。

static func set_fog_of_war_enabled(host, enabled: bool, early_out: bool = false) -> void:

	host._fog_enabled = enabled
	host._fog_early_out = early_out
	if host._fog_layer != null:
		host._fog_layer.set_enabled(enabled)
	_push_fog_uniforms(host, )



static func is_fog_of_war_enabled(host) -> bool:

	return host._fog_enabled



static func _push_fog_uniforms(host) -> void:

	# 天气屏蔽与主地形灰化共用同一张 enum_lut，只是消费点不同。
	if host._weather_layer != null:
		host._weather_layer.set_fog_mask(
			host._fog_enabled, host._world.enum_lut_tex if host._world != null else null)
	if host._shader_mat == null:
		return
	host._push_world_uniform("fog_gray_enabled", host._fog_enabled)
	host._push_world_uniform("fog_early_out_enabled", _effective_fog_early_out(host, ))
	host._push_world_uniform("fog_unexplored_color", FogOfWarLayer.UNEXPLORED_COLOR)
	# [web-water-pass] 水面 pass 共用同一份迷雾开关。放在这里而不是 _apply_uniforms
	# 里，是因为迷雾状态会在运行期翻转（_apply_fog_early_out / set_fog_enabled），
	# 而这两个入口都已经汇到本函数。
	host._push_water_fog_uniforms()


## 早退要求迷雾层在未探索处画的是一个常量色 —— 地形被完全盖住，跳过才不可见。
## 迷雾一旦上体积云光照（q1+），颜色随位置/时间变化，早退分支那块常量色会露成
## 死斑。所以请求的 early_out 还要与迷雾层的实际档位取与。

static func _effective_fog_early_out(host) -> bool:

	if not (host._fog_enabled and host._fog_early_out):
		return false
	return host._fog_layer != null and host._fog_layer.supports_terrain_early_out()



static func _apply_fog_early_out(host) -> void:

	if host._shader_mat != null:
		host._push_world_uniform("fog_early_out_enabled", _effective_fog_early_out(host, ))
	# [web-water-pass] 这个开关单独翻转的路径（set_mobile_quality_tier / 迷雾层档位
	# 变化）不走 _push_fog_uniforms，漏推会让水面 pass 在未探索区域继续画水 ——
	# 那一块本该由 pass 1 的 fog_unexplored_color 独占。
	host._push_water_fog_uniforms()

# Phase 1：让 main.gd 在 WorldClock day_changed 时推进 shader 季节相位

static func set_season_phase(host, phase: float) -> void:

	host._season_phase = phase
	host._push_water_lighting_uniforms()
	if host._shader_mat != null:
		host._push_world_uniform("season_phase", host._season_phase)
	if host._building_visual_layer != null:
		host._building_visual_layer.set_season_phase(host._season_phase)
	if host._weather_layer != null:
		host._weather_layer.set_season_phase(host._season_phase)
	if host._fog_layer != null:
		host._fog_layer.set_season_phase(host._season_phase)
	host._for_each_vegetation_layer(func(layer: ShrubLayer) -> void:
		layer.set_season_phase(host._season_phase)
	)
	host._sync_detail_and_activity_materials()


static func set_climate_anomaly(host, v: float) -> void:

	host._climate_anomaly = v
	if host._shader_mat != null:
		host._push_world_uniform("climate_anomaly", host._climate_anomaly)

# True Insolation-Driven（Phase F）：旧兼容 setter。运行时和 shader 统一保持
# insolation 分支，bool 只保留给旧材质参数兼容。

static func set_true_insolation_enabled(host, v: bool) -> void:

	var _unused_v: bool = v
	host.true_insolation_enabled = true
	if host._shader_mat != null:
		host._push_world_uniform("true_insolation_enabled", host.true_insolation_enabled)

# 任务 2：昼夜相位。由 main.gd 接收 WorldClock.day_phase_changed 信号后转发。
# 同时写入地形 shader 与 weather overlay shader（两者都需要昼夜相位。但后者

static func set_day_phase(host, v: float) -> void:

	host._day_phase = fposmod(v, 1.0)
	host._push_world_uniform("sky_global_day_weight", host._global_sky_day_weight())
	if host._sky_background != null:
		host._sky_background.set_global_time(host._day_phase, host.day_night_enabled)
	host._push_water_lighting_uniforms()
	if host._shader_mat != null:
		host._push_world_uniform("day_phase", host._day_phase)
	if host._building_visual_layer != null:
		host._building_visual_layer.set_day_phase(host._day_phase)
	if host._weather_layer != null:
		host._weather_layer.set_day_phase(host._day_phase)
	if host._fog_layer != null:
		host._fog_layer.set_day_phase(host._day_phase)
	host._for_each_vegetation_layer(func(layer: ShrubLayer) -> void:
		layer.set_day_phase(host._day_phase)
	)
	host._sync_detail_and_activity_materials()



static func set_tod_debug_sun_position(host, enabled: bool, uv: Vector2) -> void:

	host._tod_debug_sun_position_enabled = enabled
	host._tod_debug_sun_uv = Vector2(fposmod(uv.x, 1.0), clampf(uv.y, 0.0, 1.0))
	if host._shader_mat != null:
		host._push_world_uniform("tod_debug_sun_position_enabled", host._tod_debug_sun_position_enabled)
		host._push_world_uniform("tod_debug_sun_uv", host._tod_debug_sun_uv)
	if host._weather_layer != null and host._weather_layer.has_method("set_tod_debug_sun_position"):
		host._weather_layer.set_tod_debug_sun_position(host._tod_debug_sun_position_enabled, host._tod_debug_sun_uv)
	if host._fog_layer != null:
		host._fog_layer.set_tod_debug_sun_position(host._tod_debug_sun_position_enabled, host._tod_debug_sun_uv)
	if host._building_visual_layer != null:
		host._building_visual_layer.set_tod_debug_sun_position(
			host._tod_debug_sun_position_enabled, host._tod_debug_sun_uv)
	host._for_each_vegetation_layer(func(layer: ShrubLayer) -> void:
		if layer.has_method("set_tod_debug_sun_position"):
			layer.set_tod_debug_sun_position(host._tod_debug_sun_position_enabled, host._tod_debug_sun_uv)
	)
	host._sync_detail_and_activity_materials()



static func set_tod_debug_sun_height_scale(host, v: float) -> void:

	host._tod_debug_sun_height_scale = clampf(v, 0.2, 1.5)
	if host._shader_mat != null:
		host._push_world_uniform("tod_debug_sun_height_scale", host._tod_debug_sun_height_scale)
	if host._weather_layer != null and host._weather_layer.has_method("set_tod_debug_sun_height_scale"):
		host._weather_layer.set_tod_debug_sun_height_scale(host._tod_debug_sun_height_scale)
	if host._fog_layer != null:
		host._fog_layer.set_tod_debug_sun_height_scale(host._tod_debug_sun_height_scale)
	if host._building_visual_layer != null:
		host._building_visual_layer.set_tod_debug_sun_height_scale(
			host._tod_debug_sun_height_scale)
	host._for_each_vegetation_layer(func(layer: ShrubLayer) -> void:
		if layer.has_method("set_tod_debug_sun_height_scale"):
			layer.set_tod_debug_sun_height_scale(host._tod_debug_sun_height_scale)
	)
	host._sync_detail_and_activity_materials()

# ─── 任务 1：视觉总开关 setter ─────────────────────────────────────────
#   2) 把对应 uniform 推到 shader（名字与后续任务 shader 分支匹配）；

static func set_visual_quality(host, q: int) -> void:

	var was_cloud_direct = host._cloud_shadow_direct_active()
	var was_web_pc_high = host._web_pc_high_active()
	var old_sky_quality_prefix = host._desktop_sky_quality_prefix()
	host.visual_quality = clampi(q, 0, 2)
	var sky_variant_changed = old_sky_quality_prefix != host._desktop_sky_quality_prefix()
	if (was_cloud_direct != host._cloud_shadow_direct_active() \
			or was_web_pc_high != host._web_pc_high_active() or sky_variant_changed) \
			and host._shader_mat != null:
		_load_shader(host, )
		if host._world != null and host._map != null:
			host._apply_uniforms()
	host._push_water_lighting_uniforms()
	if host._resource_visual_layer != null:
		host._resource_visual_layer.set_quality(host.visual_quality,
			host._mobile_quality_tier_from_define(host._mobile_quality_tier_define) if not host._mobile_quality_tier_define.is_empty() else -1)
	if host._shader_mat != null:
		host._push_world_uniform("visual_quality", host.visual_quality)
	if host._weather_layer != null:
		host._weather_layer.set_visual_quality(host.visual_quality)
	# web：切画质立即应用天气层画质门（低/中 → 不画；高 → 画）。
	host._apply_weather_layer_render_gate()
	if host._fog_layer != null:
		host._fog_layer.set_visual_quality(host.visual_quality)
		_apply_fog_early_out(host, )
	if host._building_visual_layer != null:
		host._building_visual_layer.set_visual_quality(host.visual_quality)
	host._for_each_vegetation_layer(func(layer: ShrubLayer) -> void:
		layer.set_visual_quality(host.visual_quality)
	)
	if host._detail_family_layer != null and is_instance_valid(host._detail_family_layer) and host._map != null:
		host._detail_family_layer.configure(host._detail_layers, host.detail_scatter_family_renderer_enabled)
		if host.detail_scatter_family_renderer_enabled and host._camera_view_initialized:
			host._queue_missing_prefetch_detail_chunks()
			host._reactivate_deferred_detail_chunks()
	# 画质切换沿用运行期分层下发，避免设置变化再次制造全层同步尖峰。
	host._mark_detail_budget_total_dirty()
	host._apply_detail_global_budget()
	host._configure_cloud_shadow_field()
	host._push_cloud_shadow_material_inputs()



static func set_terrain_materials_enabled(host, enabled: bool) -> void:

	host.terrain_materials_enabled = enabled
	if host._shader_mat != null:
		host._push_world_uniform("terrain_materials_enabled", enabled)


## [pixel-scale-detail 2026-11-03] 一个物理像素覆盖的世界单位数（含 content_scale）。
## 与 shader 里 `fwidth(wp)` 同量纲：1/pixel_world_size = 世界单位在屏幕上的像素数。
## 移动端 content_scale_mode=CANVAS_ITEMS 时 canvas_scale ≈1.375，只拿 camera_zoom 会
## 把"纹素占几像素"低估 37%，近景细节门控全部提前关闭。

