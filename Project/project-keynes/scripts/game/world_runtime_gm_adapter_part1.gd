extends RefCounted

## Extracted world_runtime_gm_adapter.gd group 1; state stays with host.

func dump_render_profile(host) -> Dictionary:
	var fps: float = Engine.get_frames_per_second()
	var proc_ms: float = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var phys_ms: float = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	var nav_ms: float = Performance.get_monitor(Performance.TIME_NAVIGATION_PROCESS) * 1000.0
	# 120 帧采样 + 直方图 + SUS 关联：区分"60FPS 帧与 30FPS 帧混合"和"全部稳定 25ms"。
	const _SAMPLE_FRAMES: int = 120
	var frame_samples: PackedFloat32Array = PackedFloat32Array()
	frame_samples.resize(_SAMPLE_FRAMES)
	var sus_tick_marks: PackedByteArray = PackedByteArray()
	sus_tick_marks.resize(_SAMPLE_FRAMES)
	var sus_tick_count_t0: int = host._fast_tick_count
	var sample_t0: int = Time.get_ticks_usec()
	for i in range(_SAMPLE_FRAMES):
		var t0: int = Time.get_ticks_usec()
		var sus_before: int = host._fast_tick_count
		await host.get_tree().process_frame
		frame_samples[i] = float(Time.get_ticks_usec() - t0) / 1000.0
		sus_tick_marks[i] = 1 if host._fast_tick_count > sus_before else 0
	var sample_total_ms: float = float(Time.get_ticks_usec() - sample_t0) / 1000.0
	var sus_ticks_in_window: int = host._fast_tick_count - sus_tick_count_t0
	var arr: Array = []
	for i in range(_SAMPLE_FRAMES):
		arr.append(frame_samples[i])
	arr.sort()
	var f_min: float = arr[0]
	var f_max: float = arr[_SAMPLE_FRAMES - 1]
	var f_p50: float = arr[_SAMPLE_FRAMES / 2]
	var f_p95: float = arr[int(_SAMPLE_FRAMES * 0.95)]
	var f_avg: float = sample_total_ms / float(_SAMPLE_FRAMES)
	# 直方图：每 4ms 一个 bin，0-40ms 共 10 个 bin，> 40ms 算 overflow
	var bins: PackedInt32Array = PackedInt32Array()
	bins.resize(11)
	for v in arr:
		var idx: int = int(v / 4.0)
		if idx >= 10:
			idx = 10
		bins[idx] += 1
	var sus_frame_total_ms: float = 0.0
	var non_sus_frame_total_ms: float = 0.0
	var sus_count: int = 0
	var non_sus_count: int = 0
	for i in range(_SAMPLE_FRAMES):
		if sus_tick_marks[i] == 1:
			sus_frame_total_ms += frame_samples[i]
			sus_count += 1
		else:
			non_sus_frame_total_ms += frame_samples[i]
			non_sus_count += 1
	var sus_frame_avg: float = sus_frame_total_ms / float(maxi(1, sus_count))
	var non_sus_frame_avg: float = non_sus_frame_total_ms / float(maxi(1, non_sus_count))
	var draw_calls: float = Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	var primitives: float = Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	var objects: float = Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
	var vram_total: float = Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0
	var vram_tex: float = Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0
	var vram_buf: float = Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED) / 1048576.0
	var nodes: float = Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	var resources: float = Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)
	var orphan_nodes: float = Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)
	# Godot 4 没有单独的 GPU 时间 monitor；TIME_PROCESS 含 GDScript + render submit。
	var rs_view_calls: int = -1
	var rs_view_prims: int = -1
	if Engine.has_singleton("RenderingServer"):
		rs_view_calls = int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))
		rs_view_prims = int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME))
	var msaa_setting: int = ProjectSettings.get_setting("rendering/anti_aliasing/quality/msaa_3d", 0)
	var fxaa_setting: bool = bool(ProjectSettings.get_setting("rendering/anti_aliasing/quality/use_fxaa", false))
	var vsync_setting: int = int(DisplayServer.window_get_vsync_mode())  # 0=Disabled, 1=Enabled, 2=Adaptive, 3=Mailbox
	var max_fps_setting: int = int(Engine.max_fps)
	var dt: Dictionary = Time.get_datetime_dict_from_system()
	var stamp: String = "%04d-%02d-%02d %02d:%02d:%02d" % [
		int(dt.get("year", 0)), int(dt.get("month", 0)), int(dt.get("day", 0)),
		int(dt.get("hour", 0)), int(dt.get("minute", 0)), int(dt.get("second", 0)),
	]
	var lines = PackedStringArray()
	lines.append("[render-profile] === GPU / Frame metrics @ frame %d (player GM) %s ===" % [Engine.get_frames_drawn(), stamp])
	lines.append("  FPS=%.1f  process(sample)=%.2fms  physics=%.2fms  nav=%.2fms" % [fps, proc_ms, phys_ms, nav_ms])
	lines.append("  frame wall ms over %d samples: min=%.2f avg=%.2f p50=%.2f p95=%.2f max=%.2f" % [_SAMPLE_FRAMES, f_min, f_avg, f_p50, f_p95, f_max])
	lines.append("  sus_ticks=%d/%d sus_frame_avg=%.2fms non_sus_frame_avg=%.2fms" % [sus_count, _SAMPLE_FRAMES, sus_frame_avg, non_sus_frame_avg])
	lines.append("  histogram (4ms bins): [0-4)=%d [4-8)=%d [8-12)=%d [12-16)=%d [16-20)=%d [20-24)=%d [24-28)=%d [28-32)=%d [32-36)=%d [36-40)=%d [40+)=%d" % [
		bins[0], bins[1], bins[2], bins[3], bins[4], bins[5], bins[6], bins[7], bins[8], bins[9], bins[10]
	])
	lines.append("  vsync_mode=%d  max_fps=%d  (0=Off 1=On 2=Adaptive 3=Mailbox)" % [vsync_setting, max_fps_setting])
	lines.append("  draw_calls=%d  primitives=%d  objects=%d (Performance monitor)" % [int(draw_calls), int(primitives), int(objects)])
	lines.append("  RenderingServer view_calls=%d view_prims=%d" % [rs_view_calls, rs_view_prims])
	lines.append("  vram total=%.1f MB  tex=%.1f MB  buf=%.1f MB" % [vram_total, vram_tex, vram_buf])
	lines.append("  nodes=%d resources=%d orphan_nodes=%d" % [int(nodes), int(resources), int(orphan_nodes)])
	lines.append("  msaa=%d  fxaa=%s  mobile=%s  sus_ticks_in_window=%d" % [
		msaa_setting, str(fxaa_setting), str(OS.has_feature("mobile")), sus_ticks_in_window
	])
	for line in lines:
		print(line)

	var export_dir: String = _render_profile_export_dir()
	DirAccess.make_dir_recursive_absolute(export_dir)
	var file_stamp: String = stamp.replace("-", "").replace(":", "").replace(" ", "_")
	var txt_path: String = export_dir.path_join("render_profile_%s_%03d.txt" % [file_stamp, Time.get_ticks_msec() % 1000])
	var csv_path: String = export_dir.path_join("render_profile_log.csv")
	var tf = FileAccess.open(txt_path, FileAccess.WRITE)
	if tf == null:
		var err: int = FileAccess.get_open_error()
		push_error("[render-profile] open txt failed path=%s err=%d" % [txt_path, err])
		return {"ok": false, "error": "open txt failed err=%d" % err}
	for line in lines:
		tf.store_line(line)
	tf.close()
	# 累积 CSV：一行一次 dump，列序固定，方便掉帧前后两行直接 diff。
	var csv_exists: bool = FileAccess.file_exists(csv_path)
	var cf = FileAccess.open(csv_path, FileAccess.READ_WRITE) if csv_exists else FileAccess.open(csv_path, FileAccess.WRITE)
	if cf == null:
		var err2: int = FileAccess.get_open_error()
		push_error("[render-profile] open csv failed path=%s err=%d" % [csv_path, err2])
		return {"ok": true, "txt_path": txt_path, "csv_path": "", "error": "csv open failed err=%d" % err2}
	if csv_exists:
		cf.seek_end()
	else:
		cf.store_line("timestamp,frame,fps,process_ms,physics_ms,nav_ms,"
			+ "wall_min_ms,wall_avg_ms,wall_p50_ms,wall_p95_ms,wall_max_ms,"
			+ "sus_count,sus_frame_avg_ms,non_sus_frame_avg_ms,sus_ticks_in_window,"
			+ "hist_0_4,hist_4_8,hist_8_12,hist_12_16,hist_16_20,hist_20_24,hist_24_28,hist_28_32,hist_32_36,hist_36_40,hist_40_plus,"
			+ "vsync_mode,max_fps,draw_calls,primitives,objects,rs_view_calls,rs_view_prims,"
			+ "vram_total_mb,vram_tex_mb,vram_buf_mb,nodes,resources,orphan_nodes,msaa,fxaa,mobile")
	var row = PackedStringArray([
		stamp, str(Engine.get_frames_drawn()), "%.1f" % fps, "%.3f" % proc_ms, "%.3f" % phys_ms, "%.3f" % nav_ms,
		"%.3f" % f_min, "%.3f" % f_avg, "%.3f" % f_p50, "%.3f" % f_p95, "%.3f" % f_max,
		str(sus_count), "%.3f" % sus_frame_avg, "%.3f" % non_sus_frame_avg, str(sus_ticks_in_window),
		str(bins[0]), str(bins[1]), str(bins[2]), str(bins[3]), str(bins[4]), str(bins[5]),
		str(bins[6]), str(bins[7]), str(bins[8]), str(bins[9]), str(bins[10]),
		str(vsync_setting), str(max_fps_setting), str(int(draw_calls)), str(int(primitives)), str(int(objects)),
		str(rs_view_calls), str(rs_view_prims),
		"%.1f" % vram_total, "%.1f" % vram_tex, "%.1f" % vram_buf,
		str(int(nodes)), str(int(resources)), str(int(orphan_nodes)),
		str(msaa_setting), str(fxaa_setting), str(OS.has_feature("mobile")),
	])
	cf.store_line(",".join(row))
	cf.close()
	print("[render-profile] dumped txt=%s csv=%s" % [txt_path, csv_path])
	return {"ok": true, "txt_path": txt_path, "csv_path": csv_path}


static func _render_profile_export_dir() -> String:
	if OS.has_feature("mobile"):
		return ProjectSettings.globalize_path("user://perf").simplify_path()
	return ProjectSettings.globalize_path("res://").path_join("../../tmp").simplify_path()



func set_perf_recorder(host, recorder: RefCounted) -> void:
	host._perf_recorder = recorder



func get_perf_recorder(host) -> RefCounted:
	return host._perf_recorder



func set_tile_data_recorder(host, recorder: RefCounted) -> void:
	host._tile_data_recorder = recorder



func get_tile_data_recorder(host) -> RefCounted:
	return host._tile_data_recorder



func set_economy_data_recorder(host, recorder: RefCounted) -> void:
	host._economy_data_recorder = recorder



func get_economy_data_recorder(host) -> RefCounted:
	return host._economy_data_recorder



func get_gm_capabilities(host) -> Dictionary:
	var technologies = PackedStringArray()
	var goods = PackedStringArray()
	var buildings = PackedStringArray()
	if host._generator != null:
		var country = host._generator.get_country_facade() if host._generator.has_method("get_country_facade") else null
		if country != null and country.has_method("native_catalog"):
			technologies = country.native_catalog().get("technology_ids", PackedStringArray())
		var economy = host._generator.get_economy_facade() if host._generator.has_method("get_economy_facade") else null
		if economy != null:
			if economy.has_method("good_ids"):
				goods = economy.good_ids()
			if economy.has_method("building_type_ids"):
				buildings = economy.building_type_ids()
	var capabilities = {
		"sections": PackedStringArray(["overview", "selected"]),
		"commands": host._gm_command_specs(technologies, goods, buildings),
		"toggles": [
			{"id": "simulation.paused", "label": "暂停模拟", "group": "模拟"},
			{"id": "ui.suppress_popups", "label": "屏蔽事件与报告弹窗", "group": "界面"},
			{"id": "simulation.climate_worker_authority", "label": "Climate worker 权威", "group": "模拟"},
			{"id": "simulation.click_claim_territory", "label": "点击地块接管领土", "group": "模拟"},
			{"id": "system.autosave", "label": "自动存档（每年）", "group": "系统"},
			{"id": "visual.day_night", "label": "昼夜循环", "group": "视觉"},
			{"id": "visual.fog_of_war", "label": "战争迷雾", "group": "视觉"},
			{"id": "visual.water_effect", "label": "水面效果", "group": "视觉"},
			{"id": "visual.ocean_current", "label": "洋流显示", "group": "视觉"},
			{"id": "visual.extreme_weather", "label": "极端天气地表效果", "group": "视觉"},
			{"id": "diagnostics.perf_sampler", "label": "渲染性能采样", "group": "诊断"},
			{"id": "diagnostics.pk_log", "label": "诊断日志", "group": "诊断"},
			{"id": "diagnostics.terrain_material_gate", "label": "材质贴图门禁视图（绿=激活）", "group": "诊断"},
			{"id": "diagnostics.cell_index_view", "label": "Cell 索引视图（每格一色，全黑=索引图失效）", "group": "诊断"},
			{"id": "diagnostics.enum_lut_view", "label": "enum_lut 直读视图（分区着色，全黑=LUT 读成零）", "group": "诊断"},
			{"id": "diagnostics.water_branch_view", "label": "陆/水分支视图（绿=陆地 白=海冰 蓝=海洋）", "group": "诊断"},
			{"id": "diagnostics.pre_adjust_view", "label": "全局调整前的颜色（对比正常画面）", "group": "诊断"},
			{"id": "diagnostics.base_color_view", "label": "光照前的地表底色", "group": "诊断"},
			{"id": "diagnostics.river_flow_view", "label": "河流 flow 视图（红=判定为河，整屏红=flow_tex 未绑定）", "group": "诊断"},
			{"id": "diagnostics.static_color_view", "label": "河流层之前的静态底色", "group": "诊断"},
			{"id": "diagnostics.flow_texsize_view", "label": "flow_tex 采样器尺寸（12 位条：derived_size=正常 4×4=兜底白纹理）", "group": "诊断"},
			{"id": "diagnostics.flow_texel_view", "label": "flow texelFetch 取样（绕过过滤/wrap）", "group": "诊断"},
			{"id": "diagnostics.dump_flow_tex_report", "label": "输出 FlowTex 完整诊断（CPU/材质/sampler/GPU）",
				"group": "诊断", "kind": "button", "icon": &"summary.overview",
				"tooltip": "打印 Web FlowTex 的生成、编码、上传、绑定、Shader 变体和 GPU 实际读取信息"},
			{"id": "diagnostics.dyn_lut_view", "label": "dyn_lut 直读视图（R温度 G湿度 B雪，全黑=读成零）", "group": "诊断"},
			{"id": "diagnostics.eco_lut_view", "label": "eco_lut 视图（主地形已退役，灰占位；植被层仍用）", "group": "诊断"},
			{"id": "diagnostics.sky_visibility_view", "label": "天空可见度视图（灰阶，越黑=AO 压得越狠）", "group": "诊断"},
			{"id": "diagnostics.gi_off", "label": "关闭地形 GI（AO/bent/弹射归零，回退到接入前）", "group": "诊断"},
			{"id": "diagnostics.terrain_materials", "label": "地形材质贴图（A/B，近景看颗粒）", "group": "诊断"},
		],
	}
	capabilities["toggles"].append({
		"id": "diagnostics.dynamic_visual_atlas_upload",
		"label": "Dynamic Atlas 上传",
		"group": "诊断",
	})
	return capabilities



func get_gm_snapshot(host, section: String, _context: Dictionary = {}) -> Dictionary:
	match section:
		"overview":
			return {"ok": true, "revision": host._fast_tick_count, "data": host._gm_overview_snapshot()}
		"selected":
			if host._selected_cell == null or host._current_map == null:
				return {"ok": false, "code": "no_selection", "message": "尚未选中地块。", "data": {}}
			return {"ok": true, "revision": host._fast_tick_count,
				"data": host._gm_selected_snapshot(int(host._selected_cell.index))}
	return {"ok": false, "code": "unknown_section", "message": "未知 GM 数据页。", "data": {}}



func execute_gm_command(host, command_id: String, raw_args: Dictionary) -> Dictionary:
	var spec = host._gm_find_command_spec(command_id)
	if spec.is_empty():
		return host._gm_error("unknown_command", "未知指令：%s" % command_id)
	var validated = host._gm_validate_args(spec, raw_args)
	if not bool(validated.get("ok", false)):
		return validated
	var args: Dictionary = validated.get("args", {})
	if command_id == "diagnostics.dump_atlas_river_probe":
		var probe_baker = host._gm_map_baker()
		if probe_baker == null or not probe_baker.has_method("dump_river_atlas_probe"):
			return host._gm_error("baker_unavailable", "MapBaker 尚未就绪，无法导出采样。")
		return probe_baker.dump_river_atlas_probe()
	if host._world_clock == null and command_id.begins_with("time."):
		return host._gm_error("clock_unavailable", "时钟尚未就绪。")
	if command_id == "time.pause":
		var state = String(args.get("state", "toggle"))
		var paused = not host._world_clock.paused if state == "toggle" else state == "on"
		if host._runtime_worker_fault_paused and not paused:
			return host._gm_error("runtime_faulted",
				"运行时已故障（%s），禁止继续推进日历。" % String(
					host._runtime_last_fault_diagnostics.get("fault_code", "faulted")))
		host._world_clock.pause(paused)
		host.on_clock_running_changed(not paused)
		host.gm_toggle_changed.emit("simulation.paused", paused)
		return host._gm_ok("模拟已%s。" % ("暂停" if paused else "继续"), false, -1)
	if command_id == "time.speed":
		if host._runtime_worker_fault_paused:
			return host._gm_error("runtime_faulted",
				"运行时已故障（%s），禁止改速推进。" % String(
					host._runtime_last_fault_diagnostics.get("fault_code", "faulted")))
		var speed = float(args.get("value", 1.0))
		host._world_clock.set_speed(speed)
		host.on_clock_running_changed(true)
		return host._gm_ok("速度已设为 %d 倍。" % int(speed), false, -1)

	if host._generator == null or host._world_clock == null:
		return host._gm_error("world_not_ready", "世界尚未生成，无法提交该指令。")
	var effective_day = int(args.get("day", host._world_clock.day_index() + 1))
	if effective_day <= host._world_clock.day_index():
		return host._gm_error("effective_day_invalid", "生效日必须晚于当前游戏日。")
	var sequence = host._gm_sequence
	host._gm_sequence += 2 if command_id == "economy.mint_to_treasury" else 1
	var result: Dictionary
	if command_id.begins_with("country."):
		result = host._gm_execute_country_command(command_id, args, effective_day, sequence)
	else:
		result = host._gm_execute_economy_command(command_id, args, effective_day, sequence)
	if not bool(result.get("ok", false)):
		return host._gm_error(String(result.get("reason", "command_rejected")),
			"指令被运行时拒绝：%s" % String(result.get("reason", "unknown")), result)
	var response = host._gm_ok("指令已排入第 %d 日的权威命令队列。" % effective_day, true, effective_day)
	response["data"] = result
	return response



func get_gm_toggle_state(host, toggle_id: String) -> Dictionary:
	if host._world_clock == null and toggle_id == "simulation.paused":
		return host._gm_error("clock_unavailable", "时钟尚未就绪。")
	match toggle_id:
		"simulation.paused":
			return {"ok": true, "enabled": host._world_clock.paused}
		"ui.suppress_popups":
			return {"ok": true, "enabled": host._gm_suppress_popups}
		"simulation.climate_worker_authority":
			return {"ok": true, "enabled": host.runtime_climate_authority_enabled}
		"simulation.click_claim_territory":
			return {"ok": true, "enabled": host._gm_click_claim_territory_enabled}
		"system.autosave":
			var save_service = host._game_save_service()
			if save_service == null:
				return host._gm_error("save_service_unavailable", "存档服务尚未就绪。")
			return {"ok": true, "enabled": bool(save_service.call("is_autosave_enabled"))}
		"visual.day_night":
			return {"ok": true, "enabled": host.day_night_enabled}
		"visual.fog_of_war":
			return {"ok": true, "enabled": host.is_fog_of_war_enabled()}
		"visual.water_effect":
			return host._gm_renderer_toggle_state("water_effect_enabled")
		"visual.ocean_current":
			return host._gm_renderer_toggle_state("ocean_current_enabled")
		"visual.extreme_weather":
			return host._gm_renderer_toggle_state("extreme_weather_ground_effect_enabled")
		"diagnostics.dynamic_visual_atlas_upload":
			return {"ok": true, "enabled": not bool(Engine.get_meta(&"force_disable_dva_upload", false))}
		"diagnostics.atlas_river_probe":
			var probe_baker = host._gm_map_baker()
			if probe_baker == null or not probe_baker.has_method("get_river_atlas_probe_state"):
				return host._gm_error("baker_unavailable", "MapBaker 尚未就绪。")
			var probe_state: Dictionary = probe_baker.get_river_atlas_probe_state()
			probe_state["ok"] = true
			return probe_state
		"diagnostics.perf_sampler":
			return host._gm_renderer_toggle_state("perf_sampler_enabled")
		"diagnostics.pk_log":
			return {"ok": true, "enabled": PKLog.enabled}
		"diagnostics.terrain_material_gate":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			return {"ok": true, "enabled": host._renderer.terrain_surface_debug_view == 7}
		"diagnostics.cell_index_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			return {"ok": true, "enabled": host._renderer.terrain_surface_debug_view == 1}
		"diagnostics.enum_lut_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			return {"ok": true, "enabled": host._renderer.terrain_surface_debug_view == 8}
		"diagnostics.water_branch_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			return {"ok": true, "enabled": host._renderer.terrain_surface_debug_view == 13}
		"diagnostics.pre_adjust_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			return {"ok": true, "enabled": host._renderer.terrain_surface_debug_view == 11}
		"diagnostics.base_color_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			return {"ok": true, "enabled": host._renderer.terrain_surface_debug_view == 12}
		"diagnostics.river_flow_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			return {"ok": true, "enabled": host._renderer.terrain_surface_debug_view == 14}
		"diagnostics.static_color_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			return {"ok": true, "enabled": host._renderer.terrain_surface_debug_view == 15}
		"diagnostics.flow_texsize_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			return {"ok": true, "enabled": host._renderer.terrain_surface_debug_view == 16}
		"diagnostics.flow_texel_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			return {"ok": true, "enabled": host._renderer.terrain_surface_debug_view == 17}
		"diagnostics.dyn_lut_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			return {"ok": true, "enabled": host._renderer.terrain_surface_debug_view == 9}
		"diagnostics.eco_lut_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			return {"ok": true, "enabled": host._renderer.terrain_surface_debug_view == 10}
		"diagnostics.sky_visibility_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			return {"ok": true, "enabled": host._renderer.gi_debug_view == 1}
		"diagnostics.gi_off":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			return {"ok": true, "enabled": not host._gi_saved_strengths.is_empty()}
		"diagnostics.terrain_materials":
			return host._gm_renderer_toggle_state("terrain_materials_enabled")
	return host._gm_error("unknown_toggle", "未知 GM 开关。")



func set_gm_toggle(host, toggle_id: String, enabled: bool) -> Dictionary:
	match toggle_id:
		"ui.suppress_popups":
			host._gm_suppress_popups = enabled
		"simulation.paused":
			if host._world_clock == null:
				return host._gm_error("clock_unavailable", "时钟尚未就绪。")
			if host._runtime_worker_fault_paused and not enabled:
				return host._gm_error("runtime_faulted",
					"运行时已故障（%s），禁止继续推进日历。" % String(
						host._runtime_last_fault_diagnostics.get("fault_code", "faulted")))
			host._world_clock.pause(enabled)
			host.on_clock_running_changed(not enabled)
		"simulation.climate_worker_authority":
			host.set_runtime_climate_authority_enabled(enabled)
		"simulation.click_claim_territory":
			return host._gm_set_click_claim_territory_enabled(enabled)
		"system.autosave":
			var save_service = host._game_save_service()
			if save_service == null:
				return host._gm_error("save_service_unavailable", "存档服务尚未就绪。")
			var autosave_result: Dictionary = save_service.call("set_autosave_enabled", enabled)
			if not bool(autosave_result.get("ok", false)):
				return host._gm_error(String(autosave_result.get("code", "autosave_toggle_failed")),
					String(autosave_result.get("message", "自动存档开关保存失败。")))
		"visual.day_night":
			host.set_day_night_enabled(enabled)
		"visual.fog_of_war":
			host.set_fog_of_war_enabled(enabled)
		"visual.water_effect":
			if not host._gm_call_renderer_toggle("set_water_effect_enabled", enabled):
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
		"visual.ocean_current":
			if not host._gm_call_renderer_toggle("set_ocean_current_enabled", enabled):
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
		"visual.extreme_weather":
			if not host._gm_call_renderer_toggle("set_extreme_weather_ground_effect_enabled", enabled):
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
		"diagnostics.dynamic_visual_atlas_upload":
			Engine.set_meta(&"force_disable_dva_upload", not enabled)
		"diagnostics.atlas_river_probe":
			var probe_baker = host._gm_map_baker()
			if probe_baker == null or not probe_baker.has_method("set_river_atlas_probe_enabled"):
				return host._gm_error("baker_unavailable", "MapBaker 尚未就绪。")
			var probe_state: Dictionary = probe_baker.set_river_atlas_probe_enabled(enabled, host._current_map)
			probe_state["ok"] = true
			host.gm_toggle_changed.emit(toggle_id, bool(probe_state.get("enabled", enabled)))
			return probe_state
		"diagnostics.perf_sampler":
			if not host._gm_call_renderer_toggle("set_perf_sampler_enabled", enabled):
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
		"diagnostics.pk_log":
			PKLog.enabled = enabled
		"diagnostics.terrain_material_gate":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			host._renderer.terrain_surface_debug_view = 7 if enabled else 0
			host._print_terrain_material_gate_state()
		"diagnostics.cell_index_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			host._renderer.terrain_surface_debug_view = 1 if enabled else 0
			if enabled:
				host._print_cell_index_view_state()
		"diagnostics.enum_lut_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			host._renderer.terrain_surface_debug_view = 8 if enabled else 0
			if enabled:
				host._print_enum_lut_view_state()
		"diagnostics.water_branch_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			host._renderer.terrain_surface_debug_view = 13 if enabled else 0
			if enabled:
				print("[water-branch-view] 绿=陆地管线 / 白=B_SEA_ICE（cid<0 会无条件赋成它）"
					+ " / 蓝=B_OCEAN / 青=COAST / 深蓝=LAKE / 品红=REEF / 黄=KELP")
		"diagnostics.pre_adjust_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			host._renderer.terrain_surface_debug_view = 11 if enabled else 0
		"diagnostics.base_color_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			host._renderer.terrain_surface_debug_view = 12 if enabled else 0
		"diagnostics.river_flow_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			host._renderer.terrain_surface_debug_view = 14 if enabled else 0
			if enabled:
				host._print_river_flow_state()
		"diagnostics.static_color_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			host._renderer.terrain_surface_debug_view = 15 if enabled else 0
		"diagnostics.flow_texsize_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			host._renderer.terrain_surface_debug_view = 16 if enabled else 0
			if enabled:
				print("[flow-texsize-view] 12 位二进制条：上半屏=宽 下半屏=高，左起最高位，"
					+ "白=1 深蓝=0，每 4 位一条红分隔")
				host._print_terrain_sampler_inventory()
		"diagnostics.flow_texel_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			host._renderer.terrain_surface_debug_view = 17 if enabled else 0
			if enabled:
				print("[flow-texel-view] texelFetch 整数取样，绕过 filter_linear 与 wrap uv；"
					+ "恢复出细红河线 = 问题在过滤/采样状态而非纹理内容")
		"diagnostics.dyn_lut_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			host._renderer.terrain_surface_debug_view = 9 if enabled else 0
			if enabled:
				host._print_daily_lut_upload_state("dyn")
		"diagnostics.eco_lut_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			host._renderer.terrain_surface_debug_view = 10 if enabled else 0
			if enabled:
				host._print_daily_lut_upload_state("eco")
		"diagnostics.sky_visibility_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			host._renderer.gi_debug_view = 1 if enabled else 0
			if enabled:
				host._print_terrain_gi_state("sky-visibility-view")
		"diagnostics.gi_off":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			host._set_terrain_gi_disabled(enabled)
		"diagnostics.terrain_materials":
			if not host._gm_call_renderer_toggle("set_terrain_materials_enabled", enabled):
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
		_:
			return host._gm_error("unknown_toggle", "未知 GM 开关。")
	var actual_enabled = bool(host.get_gm_toggle_state(toggle_id).get("enabled", enabled))
	host.gm_toggle_changed.emit(toggle_id, actual_enabled)
	return {"ok": true, "enabled": actual_enabled}



func _gm_command_specs(host, technologies: PackedStringArray = PackedStringArray(),
		goods: PackedStringArray = PackedStringArray(),
		buildings: PackedStringArray = PackedStringArray()) -> Array:
	return host.HostGmCommands._gm_command_specs(technologies, goods, buildings)



func _gm_overview_snapshot(host) -> Dictionary:
	var calendar = host._world_clock.calendar_date() if host._world_clock != null else {}
	var country_report = host._generator.get_country_report() if host._generator != null and host._generator.has_method("get_country_report") else {}
	var economy_report = host._generator.get_economy_report() if host._generator != null and host._generator.has_method("get_economy_report") else {}
	host._observe_economy_fatal(economy_report)
	return {
		"world": {"ready": host._current_map != null, "seed": host._last_seed,
			"width": host._current_map.width if host._current_map != null else 0,
			"height": host._current_map.height if host._current_map != null else 0,
			"cells": host._current_map.cell_count() if host._current_map != null else 0},
		"clock": {"day_index": host._world_clock.day_index() if host._world_clock != null else -1,
			"year": int(calendar.get("year", 0)), "month": int(calendar.get("month", 0)),
			"day": int(calendar.get("day", 0)), "paused": host._world_clock.paused if host._world_clock != null else true,
			"speed": host._world_clock.speed_multiplier if host._world_clock != null else 0.0},
		"runtime": {"fast_tick": host._fast_tick_count, "last_tick_ms": host._last_fast_tick_ms,
			"sus": host.get_sus_last_tick_summary(), "timing": host._last_tick_timing.duplicate(false)},
		"country": country_report,
		"economy": economy_report,
		"recorders": host._gm_recorder_snapshot(),
	}


## 任何一种经济 fatal 都要留下能定位的现场，不只是守恒失败。
## 历史行为是只在 money_conservation_failed 时落盘，而且字段集是钱专用的；
## 于是 country_worker_cohort_cash_boundary_invalid 这类边界停机，玩家拿到的
## 也是一份钱的报表，里面既没有 stage 也没有触发的命令。
## 每帧调一次的运行时健康巡检。卡死检测很便宜，逐帧跑；fatal 需要拉整份经济
## 报告，按 _RUNTIME_HEALTH_POLL_MSEC 限频。


func _poll_runtime_health(host) -> void:
	host._poll_simulation_stall_watchdog()
	if host._generator == null or not host._runtime_ready_for_ticks:
		return
	var now_msec = Time.get_ticks_msec()
	if now_msec < host._runtime_health_next_poll_msec:
		return
	host._runtime_health_next_poll_msec = now_msec + host._RUNTIME_HEALTH_POLL_MSEC
	if not host._generator.has_method("get_economy_report"):
		return
	host._observe_economy_fatal(host._generator.get_economy_report())



func _observe_economy_fatal(host, report: Dictionary) -> void:
	if not bool(report.get("fatal", false)):
		return
	var reason = String(report.get("fatal_reason", "unknown"))
	if host._economy_fatal_dumped_reason == reason:
		return
	host._economy_fatal_dumped_reason = reason
	host.RuntimeForensics.capture_and_dump(reason, host._generator, host._world_clock,
		"economy_fatal", {"source": "world_runtime_host"})


## 卡死看门狗。
##
## 权威日停在原地而时钟还在跑，这在玩家侧的表现就是"游戏卡住了"，但进程既没崩
## 也没报错，除了等没有任何产物。这里把它变成一次取证：超过阈值就抓现场，之后
## 按固定间隔复抓，让"卡了多久、卡在哪个 stage"可比对。
## 只观察不干预 —— 不暂停时钟、不改权威，避免看门狗本身成为新的行为变量。


func _poll_simulation_stall_watchdog(host) -> void:
	if host._world_clock == null or not host._runtime_ready_for_ticks:
		return
	if host._world_clock.paused or host._world_clock.speed_multiplier <= 0.0 \
			or host._runtime_worker_fault_paused:
		host._stall_watchdog_day = -1
		return
	var day = host._world_clock.day_index()
	var now_msec = Time.get_ticks_msec()
	if day != host._stall_watchdog_day:
		host._stall_watchdog_day = day
		host._stall_watchdog_day_started_msec = now_msec
		host._stall_watchdog_next_report_msec = 0
		return
	var stalled_ms = now_msec - host._stall_watchdog_day_started_msec
	if host.stall_watchdog_threshold_msec <= 0 \
			or stalled_ms < host.stall_watchdog_threshold_msec:
		return
	if now_msec < host._stall_watchdog_next_report_msec:
		return
	host._stall_watchdog_next_report_msec = now_msec + host.STALL_WATCHDOG_REPEAT_MSEC
	push_warning("[runtime-stall] day=%d stalled for %d ms at speed=%.1f" % [
		day, stalled_ms, host._world_clock.speed_multiplier])
	# Web：把 day barrier 的关键诊断塞进事件流（小 payload，不走 JSON 转储），
	# 这样就能直接看出是哪个域没 commit。字段名以 graph_keys 事件里的真实键为准。
	var barrier_diag = host._web_barrier_diag()
	var graph_keys = PackedStringArray(barrier_diag.get("_keys", PackedStringArray()))
	barrier_diag.erase("_keys")
	# 首次进世界时把 report 的可用键名发一次，避免再猜字段名。
	if not host._web_graph_keys_emitted and not graph_keys.is_empty():
		host._web_graph_keys_emitted = true
		WebTelemetry.emit("graph_keys", {"keys": Array(graph_keys)})
	WebTelemetry.emit("stall", {"day": day, "dur": stalled_ms,
		"fast_ticks": host._fast_tick_count, "paused": host._world_clock.paused,
		"diag": barrier_diag})
	host.RuntimeForensics.capture_and_dump("simulation_day_stalled", host._generator,
		host._world_clock, "stall", {
			"stalled_day": day,
			"stalled_ms": stalled_ms,
			"fast_tick_count": host._fast_tick_count,
			"last_fast_tick_ms": host._last_fast_tick_ms,
			"last_tick_timing": host._last_tick_timing.duplicate(false),
			"sus_last_tick": host.get_sus_last_tick_summary(),
		})


## Web 诊断：从 runtime perf snapshot 里挑出 day barrier / 权威相关的真实字段。
## 键名以 graph_keys 事件为准（simulation_worker_ready / domain_authority_* 等）。


func _web_barrier_diag(host) -> Dictionary:
	var out = {}
	if host._generator == null or not host._generator.has_method("get_runtime_perf_snapshot"):
		return out
	var graph: Dictionary = host._generator.get_runtime_perf_snapshot(0)
	out["_keys"] = PackedStringArray(graph.keys())
	for key in ["simulation_thread_mode", "requested_simulation_thread_mode",
			"graph_coverage_state", "simulation_worker_ready",
			"simulation_host_state", "required_domain_mask",
			"implemented_domain_mask", "missing_domain_mask",
			"pod_completed_domain_mask", "domain_authority_planned_mask",
			"domain_authority_committed_mask", "domain_authority_ack_count",
			"domain_authority_fallback_reason", "worker_fault_count", "fault_code",
			"pod_completed_stage_count", "pod_work_units", "pod_intent_count",
			"pod_fallback_count",
			# P0：worker 为什么起不来 / 被降级。这五个是"只读一次 diag 就能定性"
			# 的最小集合，与 get_runtime_perf_snapshot 同名同义。
			#   worker_thread_create_failed → std::thread 真的创建失败
			#   active_gate_blocked         → 被 ACTIVE 准入门挡下（配置/覆盖问题）
			#   graph_coverage_complete     → 整日屏障是否已证明覆盖
			#   requested_authority_mask    → 到底请求了哪些域
			#   graph_coverage_complete=false + 请求非空 ⇒ worker 跑了但没提交过整日
			"worker_thread_create_failed", "active_gate_blocked",
			"graph_coverage_complete", "requested_authority_mask",
			"native_daily_inline",
			# P1/P2：预发布与 peer 归属。
			"environment_ring_pending", "environment_frames_ahead",
			# [worker 计时分解] C++ 侧一直在累计（RuntimeWorkerTiming::snapshot() →
			# `worker_time_<phase>_us`），但这份 diag 白名单没带它们，于是"worker 比
			# 主线程慢 8 倍"只能靠 cd/clk 速率间接推断。带上 8 个分项后一条 diag 就能
			# 区分"worker 在算"（execute）与"worker 在等"（input_wait / clock_wait /
			# boundary_wait / paused），这是决定"优化图"还是"改交付方式"的分水岭。
			"worker_time_execute_us", "worker_time_input_wait_us",
			"worker_time_clock_wait_us", "worker_time_boundary_wait_us",
			"worker_time_overhead_us", "worker_time_paused_us",
			"worker_time_save_build_us", "worker_time_save_pause_us",
			"worker_time_total_us",
			"environment_publish_callsite_mask", "day_wait_day",
			"day_wait_missing_mask", "day_wait_env_day",
			"country_peer_resolved_in_worker", "country_peer_resolved_by_main"]:
		if graph.has(key):
			out[key] = graph[key]
	# 时钟侧限流状态不在 graph 字典里，直接取。
	if host._world_clock != null:
		out["worker_lead_days"] = host._world_clock.get_worker_lead_days() \
			if host._world_clock.has_method("get_worker_lead_days") else 0
		out["max_worker_lead_days"] = host._world_clock.get_max_worker_lead_days() \
			if host._world_clock.has_method("get_max_worker_lead_days") else 0
		out["lead_blocked_frames"] = host._world_clock.get_lead_blocked_frame_count() \
			if host._world_clock.has_method("get_lead_blocked_frame_count") else 0
		out["worker_lag_days"] = host._world_clock.get_worker_lag_days() \
			if host._world_clock.has_method("get_worker_lag_days") else 0
		out["max_worker_lag_days"] = host._world_clock.get_max_worker_lag_days() \
			if host._world_clock.has_method("get_max_worker_lag_days") else 0
		out["lag_blocked_frames"] = host._world_clock.get_lag_blocked_frame_count() \
			if host._world_clock.has_method("get_lag_blocked_frame_count") else 0
	out["environment_prefetch_days"] = host._environment_prefetch_days_active
	out["environment_lead_budget_days"] = host._max_worker_lead_days
	out["web_worker"] = host._web_worker_requested()
	# web worker 的启动结论 + 内联回退状态。这两项让"为什么没起"不用再 grep 日志：
	#   web_worker_start_code == ""            → 还没走到启动（世界还没生成完）
	#   == "ok"                                → 起来了
	#   == "runtime_worker_start_failed"       → host start() 拒绝（看 fault_code，
	#                                            常见 worker_thread_create_failed）
	#   == "runtime_thread_mode_hot_switch.."  → 上一代 worker 没退干净
	#   == "authority_policy_disabled:<reason>"→ 策略没给 ACTIVE，已回退内联
	#   == "inline_flag_mismatch"              → config 没生效（配置 bug）
	out["web_worker_started"] = host._web_worker_start_ok
	out["web_worker_start_code"] = host._web_worker_start_code
	out["web_worker_inline_fallback"] = host._web_worker_inline_fallback
	out["native_daily_inline_active"] = host._native_daily_inline_active
	# 长跑内存曲线：web 的 wasm32 堆是 2 GiB 硬上限，超了就是
	# "Cannot enlarge memory" + 每次鼠标事件一条 "table index is out of bounds"。
	# 把真实堆大小和引擎自报的静态内存一起打进 diag，就能在崩之前看到斜率。
	out["wasm_heap_mb"] = WebTelemetry.wasm_heap_mb()
	out["memory_static_mb"] = WebTelemetry.memory_mb()
	return out

