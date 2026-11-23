extends RefCounted

const WARMUP_FRAMES := 60
const SAMPLE_FRAMES := 240


static func open_game(tree: SceneTree, config: NewGameConfig) -> PlayerGame:
	var flow := tree.root.get_node("GameFlow")
	var started: Dictionary = flow.begin_new_game(config)
	if not bool(started.ok):
		push_error("Could not start the player scene: %s" % str(started))
		return null
	while tree.current_scene == null and flow._transition_active:
		await tree.process_frame
	var game := tree.current_scene as PlayerGame
	if game == null:
		push_error("The game flow did not open the player scene.")
		return null
	# Freeze the calendar before PlayerGame starts generation. The explored
	# fixture can still admit its two explicit days through the runtime host.
	game._world_clock.pause(true)
	var host := game._runtime_host
	if host.session_config().is_empty():
		return null
	while not host.is_runtime_ready_for_ticks() and host.last_world_generation_error.is_empty():
		await tree.process_frame
	if not host.is_runtime_ready_for_ticks():
		push_error(host.last_world_generation_error_text())
		return null
	var loading := game.get_node("UI/UIRoot/ModalLayer/WorldLoadingOverlay") as Control
	while loading.visible:
		await loading.visibility_changed
	host.fit_camera()
	return game


static func record(game: PlayerGame, scene: String, scale: int, omitted: String) -> bool:
	var renderer := game._renderer
	var window := game.get_tree().root
	var land := renderer._world_quad
	var water := renderer._water_quad
	if renderer._mobile_quality_tier_define != "MOBILE_QUALITY_LOW" or game.visual_quality != 0:
		push_error("The renderer must use MOBILE_QUALITY_LOW. Set PK_MOBILE_SHADER_TIER on desktop.")
		return false
	if land == null or water == null or land.mesh == null or water.mesh == null \
			or land.get_viewport() != water.get_viewport():
		push_error("The player scene must draw separate land and water meshes into the same target.")
		return false
	if not _omit_draw(renderer, omitted):
		push_error("No canvas items found for the requested layer: %s" % omitted)
		return false
	var terrain := land.get_viewport()
	if (terrain == window) != (scale == 100):
		push_error("The terrain is drawing into the wrong target at %d%%." % scale)
		return false
	var viewports: Dictionary[String, Viewport] = {"window": window}
	if terrain != window:
		viewports["terrain"] = terrain
	for viewport in viewports.values():
		RenderingServer.viewport_set_measure_render_time(viewport.get_viewport_rid(), true)
	for _frame in WARMUP_FRAMES:
		await RenderingServer.frame_post_draw

	var camera := game._camera
	var view := camera.current_world_view_rect()
	var day := game._world_clock.day_index()
	var window_size := window.size
	var vsync := DisplayServer.window_get_vsync_mode()
	var max_fps := Engine.max_fps
	var driver := RenderingServer.get_current_rendering_driver_name()
	var report := {
		"scene": scene,
		"omitted_layer": omitted,
		"scale_percent": scale,
		"day": day,
		"speed": game._world_clock.speed_multiplier,
		"camera_center": [camera.position.x, camera.position.y],
		"camera_zoom": camera.zoom.x,
		"godot": Engine.get_version_info().string,
		"os": OS.get_name(),
		"driver": driver,
		"adapter": RenderingServer.get_video_adapter_name(),
		"engine_max_fps": max_fps,
		"vsync_mode": vsync,
		"display_refresh_hz": DisplayServer.screen_get_refresh_rate(),
	}
	report["start_unix_s"] = Time.get_unix_time_from_system()
	var samples := await _sample(viewports)
	report["end_unix_s"] = Time.get_unix_time_from_system()

	# Read back only after timing. Texture metadata can differ from the
	# physical backing image at a non-unit window stretch.
	var window_px := _draw_size(window)
	var terrain_px := window_px if terrain == window else _draw_size(terrain)
	var fog_enabled := game._runtime_host.is_fog_of_war_enabled()
	var fog := renderer.fog_of_war_layer()
	var fog_px := Vector2i.ZERO
	if fog_enabled and fog != null and fog._sub_viewport != null:
		fog_px = _draw_size(fog._sub_viewport)
	var sizes_ok := window_px.x > 0 and terrain_px == Vector2i(Vector2(window_px) * (scale / 100.0)) \
		and (not fog_enabled or fog_px == Vector2i(Vector2(window_px) * 0.5))
	report["window_px"] = [window_px.x, window_px.y]
	report["land_water_px"] = [terrain_px.x, terrain_px.y]
	report["vegetation_px"] = [window_px.x, window_px.y]
	report["fog_px"] = [fog_px.x, fog_px.y] if fog_enabled else null
	report["sizes_ok"] = sizes_ok

	var timings_ok := true
	var gpu_timings_ok := true
	for metric in samples:
		var values: Array = samples[metric]
		report[metric] = _summary(values)
		if metric.ends_with("_gpu_ms"):
			gpu_timings_ok = gpu_timings_ok and values.size() == SAMPLE_FRAMES
		else:
			timings_ok = timings_ok and values.size() == SAMPLE_FRAMES
	report["avg_fps"] = 1000.0 / report.frame_interval_ms.mean if report.frame_interval_ms.samples > 0 else null
	var fixed_view: bool = camera.current_world_view_rect().is_equal_approx(view) \
		and game._world_clock.day_index() == day and Engine.max_fps == max_fps \
		and DisplayServer.window_get_vsync_mode() == vsync and window.size == window_size
	report["fixed_view"] = fixed_view
	# Godot 4.6's Metal driver returns zero GPU timestamps. Keep the valid
	# frame and CPU data and require the GPU timing from the system trace.
	report["gpu_timing_source"] = "godot" if gpu_timings_ok else "system_trace_required"
	report["ok"] = sizes_ok and timings_ok and fixed_view and (gpu_timings_ok or driver == "metal")
	print("[mobile-terrain-draw] ", JSON.stringify(report))
	for viewport in viewports.values():
		RenderingServer.viewport_set_measure_render_time(viewport.get_viewport_rid(), false)
	return report.ok


static func _omit_draw(renderer: HexRenderer, omitted: String) -> bool:
	if omitted.is_empty():
		return true
	var items: Array[CanvasItem] = []
	match omitted:
		"land":
			items.append(renderer._world_quad)
		"water":
			items.append(renderer._water_quad)
		"vegetation":
			if is_instance_valid(renderer._detail_family_layer):
				items.append(renderer._detail_family_layer)
			for layer in renderer._detail_layers:
				if is_instance_valid(layer):
					items.append(layer)
	# Exclude only the draw. The fog culler may change visible on the same item,
	# and per-layer scripts keep running with the same settings.
	for item in items:
		item.visibility_layer = 0
	return not items.is_empty()


static func _draw_size(viewport: Viewport) -> Vector2i:
	var image := viewport.get_texture().get_image()
	return image.get_size() if image != null and not image.is_empty() else Vector2i.ZERO


static func _sample(viewports: Dictionary[String, Viewport]) -> Dictionary:
	var frames: Array[float] = []
	var draws: Array[int] = []
	var samples: Dictionary[String, Array] = {}
	var ids: Dictionary[String, RID] = {}
	for name in viewports:
		samples[name + "_draw_cpu_ms"] = []
		samples[name + "_draw_gpu_ms"] = []
		ids[name] = viewports[name].get_viewport_rid()
	var previous := Time.get_ticks_usec()
	for _frame in SAMPLE_FRAMES:
		await RenderingServer.frame_post_draw
		var now := Time.get_ticks_usec()
		var count := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
		if count > 0 and now > previous:
			frames.append(float(now - previous) / 1000.0)
			draws.append(count)
			for name in ids:
				var id := ids[name]
				_append_timing(samples[name + "_draw_cpu_ms"], RenderingServer.viewport_get_measured_render_time_cpu(id))
				_append_timing(samples[name + "_draw_gpu_ms"], RenderingServer.viewport_get_measured_render_time_gpu(id))
		previous = now
	samples["frame_interval_ms"] = frames
	samples["draw_calls"] = draws
	return samples


static func _append_timing(values: Array, elapsed: float) -> void:
	# Zero is also Godot's value for unavailable measurement. Preserve the
	# sample count so an unavailable timer cannot be read as zero draw cost.
	if is_finite(elapsed) and elapsed > 0.0:
		values.append(elapsed)


static func _summary(values: Array) -> Dictionary:
	if values.is_empty():
		return {"samples": 0, "mean": null, "median": null, "p95": null}
	var sorted := values.duplicate()
	sorted.sort()
	var count := sorted.size()
	var total := 0.0
	for sample in sorted:
		total += sample
	var middle := count >> 1
	var median: float = (sorted[middle - 1] + sorted[middle]) / 2.0 if count % 2 == 0 else sorted[middle]
	return {"samples": count, "mean": total / count, "median": median, "p95": sorted[ceili(0.95 * count) - 1]}
