extends RefCounted

# G5 collaborator. The host owns all mutable state; it is passed per call.

func _apply_overlay_mode(host, mode: int) -> void:
	# 需求 6.4：防止快速连切残留旧 uniform——每次切换都强制 bake + 重绑 tex。
	# Reference-impl Pass #2 守门：DEMO_THERMAL_GRADIENT 开关关闭时，即便外部
	# 强行调到该 mode（例如旧存档 / 调试脚本），也要降级回退到 NONE 避免画错。
	if mode == OverlayMode.MODE.DEMO_THERMAL_GRADIENT \
			and not host._is_demo_thermal_gradient_enabled():
		push_warning("[Overlay] DEMO_THERMAL_GRADIENT 开关已关，回退到 NONE")
		mode = 0
	host._overlay_mode = mode
	host._overlay_error_msg = ""
	if host._overlay_layer == null:
		return
	host._overlay_layer.set_mode(mode)
	if mode == 0:
		# NONE：清空数据纹理避免残影，节点 visible 由 set_mode 内部处理。
		host._overlay_layer.set_data_texture(null)
		host._overlay_stats = {}
		if host._overlay_legend != null:
			host._overlay_legend.update_for_mode(0)
		return
	host._refresh_overlay_data()
	if host._overlay_legend != null:
		host._overlay_legend.update_for_mode(host._overlay_mode)
		host._update_overlay_pointer_for_cell()


func _set_overlay_alpha(host, v: float) -> void:
	host._overlay_alpha = clampf(v, 0.0, 1.0)
	if host._overlay_layer != null:
		host._overlay_layer.set_alpha(host._overlay_alpha)

# 每日（或 regenerate 后）重烘焙一次数据纹理；NONE 模式直接早返。
# 任一环节抛错都把 overlay 强制回退到 NONE（需求 6.5）。
#
# debug-overlay-perf v1（2026-06-12）：
# 1) 持久化 _overlay_tex + _overlay_buf 传给 baker，复用 GPU 资源 + CPU buf。
#    避免每帧 ImageTexture.create_from_image 触发 1080×574 RGBA8 重分配
#    （单次同步阻塞 5-15ms，是温度/天气 overlay 卡顿主因）。
# 2) 调用方有责任在 derived_size 真的变化或 mode 切换时把 _overlay_tex 置 null；
#    本函数会安全检测并重建。
# 3) bake 返回的 buf 写回 _overlay_buf 做下次复用（PackedByteArray 是 CoW，
#    赋值是引用，几乎零成本）。

func _refresh_overlay_data(host) -> void:
	if host._overlay_layer == null or host._overlay_mode == 0:
		return
	if host._current_map == null or host._world_data == null:
		# 地图尚未生成（理论上 _ready 里不会走到这里，保险兜底）
		return
	# 消费 dirty 标记。即便没 dirty 也允许执行（例如 _apply_overlay_mode 切换
	# mode 时强制重 bake），仅作为统计参考。
	host._overlay_dirty = false
	var cp = null
	if host._generator != null:
		cp = host._generator._c()
	var phase: float = 0.0
	if host._world_clock != null:
		phase = host._world_clock.season_phase()
	var t0 = Time.get_ticks_usec()
	var result: Dictionary = {}
	# GDScript 没有 try/except；这里做显式的接口存在性检查 + 结果字段校验。
	if DataOverlayBaker == null:
		host._disable_overlay_due_to_error("DataOverlayBaker not loaded")
		return
	var overlay_adapter: DCViewAdapter = host._view_adapter
	if host._generator != null and host._generator.has_method("get_data_core_world"):
		var dc_world = host._generator.get_data_core_world()
		if dc_world != null and dc_world.has_method("is_bound") and dc_world.is_bound():
			overlay_adapter = DCViewAdapter.World.new(dc_world, host._current_map)
	# DOTS（debug-overlay-perf v2，2026-06-12）：取 DCWorldExt C++ co-processor 传给
	# baker，让它把 O(n_pixels) 的内层像素 fan-out 下沉 C++（encode_overlay_atlas）。
	# null / 旧 DLL / SoA 未建时 baker 内部透明回退 GDScript fan-out。
	var overlay_ext = null
	if host._generator != null and host._generator.has_method("get_data_core_world_ext"):
		overlay_ext = host._generator.get_data_core_world_ext()
	result = DataOverlayBaker.bake(
		host._current_map, host._world_data, host._overlay_mode, cp, phase, overlay_adapter,
		host._overlay_tex, host._overlay_buf, overlay_ext
	)
	host._overlay_last_bake_ms = (Time.get_ticks_usec() - t0) / 1000.0
	var tex = result.get("texture", null)
	if tex == null:
		host._disable_overlay_due_to_error("bake returned null texture")
		return
	# 持久化复用资源。bake 在 derived_size 变化时会自己 fallback 到新建，
	# 这里直接吸收返回值即可（同一个 ImageTexture 实例时是 no-op 赋值）。
	host._overlay_tex = tex
	var ret_buf = result.get("buf", null)
	if ret_buf is PackedByteArray:
		host._overlay_buf = ret_buf
	host._overlay_layer.set_data_texture(tex)
	host._overlay_stats = result.get("stats", {})
	# 记录 fan-out 路径（gdext_fanout / gdscript_fanout / gdscript_fanout_soa），
	# 供 Telemetry / DebugConsole 诊断 overlay 是否走到 C++。
	host._overlay_bake_path = String(result.get("path", "gdscript_fanout"))


func _disable_overlay_due_to_error(host, msg: String) -> void:
	push_warning("[Overlay] disabled: %s" % msg)
	host._overlay_error_msg = msg
	host._overlay_mode = 0
	if host._overlay_layer != null:
		host._overlay_layer.force_disable()
		host._overlay_layer.set_data_texture(null)

# 公共 getter：DebugConsole / Legend 读取当前状态

func get_overlay_mode(host) -> int:
	return host._overlay_mode


func get_overlay_alpha(host) -> float:
	return host._overlay_alpha


func get_overlay_stats(host) -> Dictionary:
	return host._overlay_stats


func get_overlay_last_bake_ms(host) -> float:
	return host._overlay_last_bake_ms


func get_overlay_bake_path(host) -> String:
	return host._overlay_bake_path


func get_overlay_error_msg(host) -> String:
	return host._overlay_error_msg

# 诊断动作（Debug 控制台复用）：打印洋流热输运摘要，等价于 F7 的处理逻辑。

func _update_overlay_pointer_for_cell(host) -> void:
	if host._overlay_legend == null or host._selected_cell == null:
		return
	if host._overlay_mode == 0:
		host._overlay_legend.clear_pointer()
		return
	if OverlayMode.is_vector(host._overlay_mode):
		# B.1：通过 ViewAdapter 读 wind_vector / ocean_current
		var ov_idx: int = int(host._selected_cell.index)
		var ov_ad: DCViewAdapter = host._view_adapter
		var vec: Vector2 = Vector2.ZERO
		var norm_max: float = 1.0
		match host._overlay_mode:
			OverlayMode.MODE.WIND_DIR:
				vec = ov_ad.get_wind_vector(ov_idx) if ov_ad != null else host._selected_cell.wind_vector
				# 与 baker 同源（DataOverlayBaker.WIND_SPEED_NORM_MAX = 1.7）
				norm_max = 1.7
			OverlayMode.MODE.OCEAN_CURRENT_DIR:
				vec = ov_ad.get_ocean_current(ov_idx) if ov_ad != null else host._selected_cell.ocean_current
				# 与 baker 同源（DataOverlayBaker.OCEAN_CURRENT_NORM_MAX = 0.8）
				norm_max = 0.8
		var mag: float = vec.length()
		if mag < 0.0001:
			host._overlay_legend.clear_pointer()
			return
		var hue: float = fposmod(atan2(vec.y, vec.x) / TAU + 0.5, 1.0)
		var intensity: float = clampf(mag / norm_max, 0.0, 1.0)
		host._overlay_legend.update_pointer_vector(hue, intensity)
		return
	if OverlayMode.is_discrete(host._overlay_mode):
		host._overlay_legend.clear_pointer()
		return
	# B.1：通过 ViewAdapter 读 temperature / moisture / base_moisture
	var ovs_idx: int = int(host._selected_cell.index)
	var ovs_ad: DCViewAdapter = host._view_adapter
	var v: float = NAN
	match host._overlay_mode:
		OverlayMode.MODE.TEMPERATURE:
			var t_v: float = ovs_ad.get_temp(ovs_idx) if ovs_ad != null else float(host._selected_cell.temperature)
			v = clampf(t_v, 0.0, 1.0)
		OverlayMode.MODE.PRECIPITATION:
			# 与 baker 同源：降水 overlay 直接读取 weather pass 输出。
			var precip: float = ovs_ad.get_weather_precip(ovs_idx) if ovs_ad != null else float(host._selected_cell.weather_precip)
			v = clampf(precip / DataOverlayBaker.PRECIPITATION_NORM_MAX, 0.0, 1.0)
		OverlayMode.MODE.HUMIDITY:
			var m_v: float = ovs_ad.get_moisture(ovs_idx) if ovs_ad != null else float(host._selected_cell.moisture)
			v = clampf(m_v, 0.0, 1.0)
		OverlayMode.MODE.VEGETATION_VITALITY:
			# vegetation_vitality 无 SoA 对位（HexCell-only），仍直读
			v = clampf(float(host._selected_cell.vegetation_vitality), 0.0, 1.0)
	if is_nan(v):
		host._overlay_legend.clear_pointer()
	else:
		host._overlay_legend.update_pointer(v)


# ─── DataCore CLI Helpers（dots-foundation-and-weather-migration） ────────
# dots-flag-prune-pr1 (2026-05-22)：use_data_core / use_data_core_weather flag
# 已删除——DataCore 现恒走单路径。原 --data-core / --no-data-core /
# --data-core-weather / --no-data-core-weather / --validate-weather 五个 CLI
# 开关随之废弃（解析时打 deprecated 提示，不再写 ClimateProfile）。
# 仅保留 --soak-dump= CLI（DCSoakDump 路径独立于 flag）。


func _mobile_quality_tier_to_define(host, tier: int) -> String:
	match tier:
		0: return "MOBILE_QUALITY_LOW"   # ≤4 sample
		1: return "MOBILE_QUALITY_MID"   # ≤6 sample
		2: return "MOBILE_QUALITY_HIGH"  # ≤9 sample
		_: return "MOBILE_QUALITY_MID"


# Mobile debug overlay cycle handler：手指点 Quality 按钮 0→1→2→0 循环 + 重 push shader。

func cycle_mobile_quality_tier(host) -> void:
	host.mobile_quality_tier = (host.mobile_quality_tier + 1) % 3
	print("[mobile/quality-tier] 切到 tier=%d (%s)" % [
		host.mobile_quality_tier, host._mobile_quality_tier_to_define(host.mobile_quality_tier)
	])
	host._push_visual_toggles()


# ─── 任务 1：视觉总开关推送 ─────────────────────────────────────────────
# 把六个 @export 开关一次性推到 HexRenderer / WeatherLayer。
# 开关 → 具体 shader 分支的绑定由后续任务消费这些 setter 完成。

func _push_visual_toggles(host) -> void:
	if host._visual_bootstrap == null:
		host._visual_bootstrap = DCVisualBootstrap.new(host)
	host._visual_bootstrap.push_visual_toggles()

func _push_visual_toggles_legacy(host) -> void:
	# 实测证据（log_next.txt 2026-06-15 11:32）：
	#   shader=ON  非 SUS 帧 avg=27.90ms（直方图主峰 [24-28)=59 帧）
	#   shader=OFF 非 SUS 帧 avg= 8.42ms（直方图主峰 [8-12)=92 帧）
	#   主地形 fragment shader 占 19.5ms / 帧 = ~70% 帧时间
	# visual_quality=0 跳过：河岸 fbm 扰动 / river flow / shore 4 对角 sample /
	#   fbm octave / 多层云 / day_night / 部分 hillshade。预期 frame ms 12-16ms
	#   → 60 FPS 可达（vsync_mode=1 锁 60Hz/120Hz）。
	# 桌面端继续走 @export default visual_quality=1。
	# mobile/web：auto 压到 LOW；mobile 开 terrain horizon 时仍可抬到 HIGH。
	if DCFeatureFlags.uses_shader_quality_tier():
		if OS.has_feature("mobile") and host.mobile_terrain_horizon_enabled:
			if host.mobile_quality_tier < 2:
				host.mobile_quality_tier = 2
				print("[mobile/terrain-horizon] 启用后强制 mobile_quality_tier=2 (HIGH)")
			if host.visual_quality < 1:
				host.visual_quality = 1
				print("[mobile/terrain-horizon] 启用后保持 visual_quality>=1")
		elif host.render_quality_mode < 0 and host.visual_quality > 0:
			host.visual_quality = 0
			host.mobile_quality_tier = 0
			var plat := "web" if DCFeatureFlags.is_web() else "mobile"
			print("[%s/visual-quality] 强制 visual_quality=0 + tier=LOW (受限平台默认)" % plat)
	if host._renderer != null:
		# 编译期质量档必须在 set_visual_quality 之前推送。
		if DCFeatureFlags.uses_shader_quality_tier() and host._renderer.has_method("set_mobile_quality_tier"):
			var tier_define: String = host._mobile_quality_tier_to_define(host.mobile_quality_tier)
			host._renderer.set_mobile_quality_tier(tier_define)
		host._renderer.set_visual_quality(host.visual_quality)
		# 60 FPS 优化（2026-06-14 路线 B）：ecology_visual_quality 也锁 0。
		# 之前 main.gd 从来没 push 过这个值，renderer @export default=2 一直生效。
		# eco_q≥2 跑 snowline_visual_strength（额外 fbm + bloom）+ 跨 cell 平滑等。
		if DCFeatureFlags.uses_shader_quality_tier() and host._renderer.has_method("set_ecology_visual_quality"):
			host._renderer.set_ecology_visual_quality(0)
		host._renderer.set_day_night_enabled(host.day_night_enabled)
		host._renderer.set_extreme_weather_ground_effect_enabled(
			host.extreme_weather_ground_effect_enabled
		)
		host._renderer.set_perf_sampler_enabled(host.perf_sampler_enabled)
		# Pass 2：把 Pass 2 的三个模块开关也一次性推下去
		if host._renderer.has_method("set_rain_density_boost_enabled"):
			host._renderer.set_rain_density_boost_enabled(host.rain_density_boost_enabled)
		if host._renderer.has_method("set_cloud_tod_tint_enabled"):
			host._renderer.set_cloud_tod_tint_enabled(host.cloud_tod_tint_enabled)
		# weather_layer 之前没被 push visual_quality，1046 行 shader 一直跑 quality=2。
		# 这次先推下去，后续按需调。
		var weather_layer_node = host._renderer.get_node_or_null("WeatherLayer")
		if weather_layer_node != null and weather_layer_node.has_method("set_visual_quality"):
			weather_layer_node.set_visual_quality(host.visual_quality)

		# Water Visual Overhaul：把本轮的 13 个参数 + 5 个子开关一起推下去。
		# visual_quality==0 时，各子特性由 renderer/shader 内部做降级，不在这里改值。

# ─── Pass 2：TOD 中枢初始化与广播 ─────────────────────────────────────
# 唯一一处构造 TODProfile 的地方。@export 参数校验：night_factor_min <0.35
# 时（过黑）在日志里 push_warning，避免用户无意退回上一轮过暗模式（需求 2.6）。

func _init_tod_profile(host) -> void:
	host._tod_profile = TODProfile.new()
	host._tod_profile.configure(
		host.daylight_ratio, host.night_factor_min, host.night_factor_max, host.tod_exposure
	)
	if host.night_factor_min < 0.35:
		push_warning(
			"[TOD] night_factor_min=%.2f < 0.35：夜晚可能过暗无法操作" % host.night_factor_min
		)

# 按当前 day_phase 重算 TOD 并广播给 renderer / weather_layer。
# 被 _on_day_phase_changed 和 _ready 初始化阶段各调用一次。

func _recompute_and_push_tod(host, day_phase: float) -> void:
	if host._tod_profile == null:
		return
	host._tod_profile.recompute(day_phase, host.day_night_enabled)
	if not host.day_night_enabled:
		host._tod_profile.sun_dir = host._debug_tod_light_dir()
	host._push_tod_debug_sun_uv()
	if host._renderer != null and host._renderer.has_method("apply_tod"):
		host._renderer.apply_tod(host._tod_profile)

func set_day_night_enabled(host, v: bool) -> void:
	host.day_night_enabled = v
	if host._renderer != null:
		host._renderer.set_day_night_enabled(host.day_night_enabled)
	host._push_tod_debug_sun_uv()
	host._update_tod_sun_handle_visibility()
	host._recompute_and_push_tod(host._current_visual_day_phase())
	if host._debug_console != null and host._debug_console.has_method("request_state_sync"):
		host._debug_console.request_state_sync()

func set_debug_tod_light_angle_deg(host, v: float) -> void:
	host._debug_tod_light_angle_deg = clampf(v, -180.0, 180.0)
	if not host.day_night_enabled:
		host._recompute_and_push_tod(host._current_visual_day_phase())

func get_debug_tod_light_angle_deg(host) -> float:
	return host._debug_tod_light_angle_deg

func set_debug_tod_light_elevation_deg(host, v: float) -> void:
	host._debug_tod_light_elevation_deg = clampf(v, 8.0, 85.0)
	if not host.day_night_enabled:
		host._recompute_and_push_tod(host._current_visual_day_phase())

func get_debug_tod_light_elevation_deg(host) -> float:
	return host._debug_tod_light_elevation_deg

func set_debug_tod_sun_position(host, v: float) -> void:
	host.set_debug_tod_sun_uv(Vector2(v, host.get_debug_tod_sun_uv().y))

func get_debug_tod_sun_position(host) -> float:
	if host._debug_tod_sun_uv_override_enabled:
		host._debug_tod_sun_position = host._debug_tod_sun_uv.x
	elif host._world_clock != null:
		host._debug_tod_sun_position = host._world_clock.visual_day_phase
	return host._debug_tod_sun_position

func set_debug_tod_sun_uv(host, uv: Vector2) -> void:
	host._debug_tod_sun_uv = Vector2(fposmod(uv.x, 1.0), clampf(uv.y, 0.0, 1.0))
	host._debug_tod_sun_uv_override_enabled = true
	host._debug_tod_sun_position = host._debug_tod_sun_uv.x
	if host._world_clock != null:
		host._world_clock.visual_day_phase = host._debug_tod_sun_position
	host._on_day_phase_changed(host._debug_tod_sun_position)
	host._push_tod_debug_sun_uv()
	host._position_tod_sun_handle()
	if host._debug_console != null and host._debug_console.has_method("request_state_sync"):
		host._debug_console.request_state_sync()

func get_debug_tod_sun_uv(host) -> Vector2:
	if host._debug_tod_sun_uv_override_enabled:
		return host._debug_tod_sun_uv
	return host._current_tod_sun_uv()

func set_debug_tod_sun_height_scale(host, v: float) -> void:
	host._debug_tod_sun_height_scale = clampf(v, 0.2, 1.5)
	if host._renderer != null and host._renderer.has_method("set_tod_debug_sun_height_scale"):
		host._renderer.set_tod_debug_sun_height_scale(host._debug_tod_sun_height_scale)

func get_debug_tod_sun_height_scale(host) -> float:
	return host._debug_tod_sun_height_scale

func set_debug_tod_sun_handle_visible(host, v: bool) -> void:
	host._debug_tod_sun_handle_requested = v
	if v and not host._debug_tod_sun_uv_override_enabled:
		host._debug_tod_sun_uv = host._current_tod_sun_uv()
	if host._renderer != null and host._renderer.has_method("set_tod_debug_sun_height_scale"):
		host._renderer.set_tod_debug_sun_height_scale(host._debug_tod_sun_height_scale)
	host._push_tod_debug_sun_uv()
	host._update_tod_sun_handle_visibility()

func _current_visual_day_phase(host) -> float:
	if host._world_clock != null:
		return host._world_clock.visual_day_phase
	return host._debug_tod_sun_position

func _debug_tod_light_dir(host) -> Vector3:
	var azimuth: float = deg_to_rad(host._debug_tod_light_angle_deg)
	var elevation: float = deg_to_rad(host._debug_tod_light_elevation_deg)
	var horiz: float = cos(elevation)
	return Vector3(cos(azimuth) * horiz, sin(azimuth) * horiz, sin(elevation)).normalized()

func _push_tod_debug_sun_uv(host) -> void:
	if host._renderer != null and host._renderer.has_method("set_tod_debug_sun_position"):
		host._renderer.set_tod_debug_sun_position(
			(not host.day_night_enabled) or host._debug_tod_sun_uv_override_enabled,
			host.get_debug_tod_sun_uv()
		)

func _current_tod_sun_uv(host) -> Vector2:
	var phase: float = host._current_visual_day_phase()
	var tilt: float = deg_to_rad(23.5)
	if host._renderer != null:
		tilt = deg_to_rad(float(host._renderer.axial_tilt_deg))
	var season_phase: float = host._world_clock.season_phase() if host._world_clock != null else 1.0
	var year_progress: float = fposmod(season_phase, 4.0) * 0.25
	var decl: float = tilt * cos(TAU * year_progress)
	var lat_signed: float = clampf(decl / (PI * 0.5), -1.0, 1.0)
	return Vector2(fposmod(phase, 1.0), lat_signed * 0.5 + 0.5)

func _position_tod_sun_handle(host) -> void:
	if host._tod_sun_handle_btn == null or host._renderer == null or host._camera == null:
		return
	var bounds: Rect2 = host._renderer.get_world_bounds()
	if bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
		return
	var uv: Vector2 = host.get_debug_tod_sun_uv()
	var world_pos := bounds.position + Vector2(uv.x * bounds.size.x, uv.y * bounds.size.y)
	var screen_pos := host._world_to_screen(world_pos)
	host._tod_sun_handle_btn.position = screen_pos - host._tod_sun_handle_btn.size * 0.5

func _screen_to_sun_uv(host, screen_pos: Vector2) -> Vector2:
	if host._renderer == null or host._camera == null:
		return host.get_debug_tod_sun_uv()
	var bounds: Rect2 = host._renderer.get_world_bounds()
	if bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
		return host.get_debug_tod_sun_uv()
	var world_pos := host._screen_to_world(screen_pos)
	var u := (world_pos.x - bounds.position.x) / bounds.size.x
	var v := (world_pos.y - bounds.position.y) / bounds.size.y
	return Vector2(fposmod(u, 1.0), clampf(v, 0.0, 1.0))

func _screen_to_world(host, screen_pos: Vector2) -> Vector2:
	if host._camera == null:
		return Vector2.ZERO
	var vp_center := host.get_viewport().get_visible_rect().size * 0.5
	return host._camera.position + (screen_pos - vp_center) / host._camera.zoom.x

func _world_to_screen(host, world_pos: Vector2) -> Vector2:
	if host._camera == null:
		return Vector2.ZERO
	var vp_center := host.get_viewport().get_visible_rect().size * 0.5
	return vp_center + (world_pos - host._camera.position) * host._camera.zoom.x

# ─── 地块选择 / 信息面板 ─────────────────────────────────────────────────

func _sync_overlay_to_world(host) -> void:
	if host._overlay_layer == null:
		return
	if host._renderer != null:
		host._overlay_layer.set_bounds(host._renderer.get_world_bounds())
	if host._overlay_layer.has_method("set_horizontal_wrap"):
		host._overlay_layer.set_horizontal_wrap(host._map_wrap_period_x())
	host._overlay_layer.set_alpha(host._overlay_alpha)
	host._overlay_layer.set_mode(host._overlay_mode)

# ─── Reference-impl Pass #2 helpers (demo-only, performance-charter §12.6) ───
# _is_demo_thermal_gradient_enabled / _run_demo_thermal_gradient_pass_if_enabled
# 是参考实现的"接入主流程模板"。如果未来要把这套通信契约升级为真实游戏机制，
# 应该在这里复制一套（替换为真实 component / pass / map field 名）。

# 首次诊断打印去重表：每条 reason 仅打印一次，避免每帧刷屏。

func _map_wrap_period_x(host) -> float:
	if host._current_map == null:
		return 0.0
	return HexUtils.wrap_period_x(host._current_map.width, host.hex_size)

func _cell_display_world(host, cell: HexCell) -> Vector2:
	if cell == null:
		return Vector2.ZERO
	var canonical := HexUtils.cube_to_world(cell.q, cell.r, host.hex_size)
	var ref_x := host._camera.position.x if host._camera != null else canonical.x
	return HexUtils.nearest_display_world(canonical, ref_x, host._map_wrap_period_x())

func _select_cell(host, cell: HexCell) -> void:
	host._selected_cell = cell
	var display_world := host._cell_display_world(cell)
	host._highlight.set_cell_display(cell, host.hex_size, display_world, host._map_wrap_period_x())
	host._right_panel.visible = true
	# 0.4.2 — controller 持有自己的 _selected_cell 副本；这里同步推一次。
	if host._info_panel_controller != null:
		host._info_panel_controller.set_selected_cell(cell)
	host._ensure_emergent_labels()
	host._refresh_info_panel()
	# 选中切换与面板首次打开走立即刷新，不等墙钟节流窗口。refresh_info_panel 不含
	# climate_line，所以这里必须真的跑一遍四行而不是只标脏。
	host._selected_cell_lines_dirty = true
	host._selected_cell_lines_next_refresh_ms = 0
	host._refresh_selected_cell_lines_if_due()
	# Legend 指针：选中后把当前 cell 的通道值映射到色带位置。
	host._update_overlay_pointer_for_cell()
	# 保留用户当前缩放/位置（不再 fit 重置视图）；仅当选中地块被右侧面板/顶栏
	# 遮挡时，平滑平移把它移到可见安全区，避免"点一下就跳回整图"的体验。
	if host._camera != null and cell != null:
		host._camera.ensure_point_visible(display_world, host._map_safe_area())
	# [TEMP DEBUG] sea-ice-render-source-unify 阶段 A 同源校验：
	# 选中任意 cell 时打印 (sea_ice_fraction_cpu, dyn_atlas_smooth.A_byte, biome)。
	# 期望：q01_byte_ice(frac_cpu) == dyn_smooth.A_byte。
	# 若 MISMATCH → GD↔C++ 编码漂移或 buffer 滞后；
	# 若 MATCH 但 shader 端依然不冰 → shader uniform/纹理上传链有问题。
	# 验证完成后请删除这段调试调用。
	if cell != null and host._renderer != null and host._renderer.has_method("debug_sea_ice_probe"):
		host._renderer.debug_sea_ice_probe(cell)

func _clear_selection(host) -> void:
	host._selected_cell = null
	# 0.4.2 — 同步清掉 controller 的 selection（否则 refresh_* 会读到旧 cell 引用）
	if host._info_panel_controller != null:
		host._info_panel_controller.set_selected_cell(null)
	if host._highlight != null:
		host._highlight.clear()
	if host._right_panel != null:
		host._right_panel.visible = false
	if host._overlay_legend != null:
		host._overlay_legend.clear_pointer()
	# 关闭面板不再重置视图：保留用户当前缩放/位置。需要回到整图请用顶栏 Fit 按钮。

# 计算地图的"可见安全区"：扣掉顶部 TopBar 和右侧 RightPanel（仅在可见时扣除）。
# 被 fit_to_viewport 使用，保证整张地图都落在未被 UI 覆盖的矩形内。

func _map_safe_area(host) -> Rect2:
	var vp := host.get_viewport().get_visible_rect().size
	var top_h: float = 40.0  # TopBar = PanelContainer offset_bottom=36 + 少量安全边距
	if OS.has_feature("mobile"):
		top_h = host.MOBILE_TOPBAR_SAFE_TOP + host.MOBILE_TOPBAR_HEIGHT
	var right_w: float = 0.0
	if host._right_panel != null and host._right_panel.visible:
		# RightPanel.custom_minimum_size.x 若为 0 则用 size.x 回退
		var w: float = host._right_panel.custom_minimum_size.x
		if w <= 0.0:
			w = host._right_panel.size.x
		right_w = w
	var safe := Rect2(Vector2(0.0, top_h), Vector2(maxf(vp.x - right_w, 1.0), maxf(vp.y - top_h, 1.0)))
	return safe

# 0.4.2 — main.gd 拆分推荐顺序 step 1：refresh_info_panel 系列已搬到
# [`ui/info_panel_controller.gd`](ui/info_panel_controller.gd)。
# 6 个 forwarder 保留 main 命名空间内的旧 api（_refresh_info_panel /
# _refresh_weather_line / _refresh_climate_line / _refresh_vitality_line /
# _ensure_emergent_labels / _refresh_emergent_lines），其余 callsite 零改动。
# 5 个文字档位 helper（_vitality_band / _elevation_band / _climate_zone_name /
# _temperature_band / _moisture_band）+ 5 个 _emergent_* Label 字段已完全删除。
