extends SceneTree

## Windowed coast fixture for #62. Run the same script on the baseline and candidate.
const Water = preload("res://scripts/rendering/renderer_shader_water.gd")
const Table = preload("res://scripts/rendering/render_data_table.gd")
const DrawCapture = preload("res://tests/rendering/mobile_terrain_draw_capture.gd")
const WebAutotest = preload("res://scripts/game/web_autotest.gd")
const COAST_START := Vector2(1059.36376953125, 924.0)
const COAST_END := COAST_START + Vector2(320, 0)
const ZOOM := 1.75
const ROUTE_SECONDS := 60.0

var _pass_stamps := {}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if DisplayServer.get_name() == "headless" or RenderingServer.get_rendering_device() == null:
		push_error("The coast fixture requires a windowed rendering device.")
		quit(1)
		return
	await process_frame
	var args := OS.get_cmdline_user_args()
	var quality := "medium" if args.has("--medium") else "high"
	var settings := root.get_node("GameSettings")
	var applied: Dictionary = settings.update({"render_quality": quality, "graphics_custom": false,
		"window_mode": "windowed", "resolution_width": 1600, "resolution_height": 960,
		"vsync": true, "autosave_enabled": false}, false)
	if not applied.ok:
		push_error("Could not apply the coast fixture settings.")
		quit(1)
		return
	# Keep the whole route visible while the calendar stays fixed.
	Engine.set_meta("pk_fog_off", true)
	var config := WebAutotest.build_config({"seed": 20260718, "width": 60, "height": 40})
	config.country.foreign_count = 3
	var game := await DrawCapture.open_game(self, config)
	if game == null:
		quit(1)
		return
	var renderer := game._renderer
	var table: SubViewport = renderer._ripple_table
	var water := renderer._water_quad
	var camera := game._camera
	var detail := 1 if quality == "medium" else 2
	var ok: bool = table != null and water != null and water.mesh != null \
		and renderer._graphics_details.water_detail == detail \
		and renderer._water_mat.get_shader_parameter(&"water_ripple_lattice") == table.get_texture() \
		and renderer._water_mat.get_shader_parameter(&"water_waves_enabled") == true
	if ok:
		renderer.set_clock_running(false)
		renderer._world_time = 0.0
		camera.restore_view_state(COAST_START, ZOOM)
		_set_view(camera, COAST_START)
		ok = _has_coast(game)
	else:
		push_error("The requested preset must bind the ripple table and enable waves.")
	if ok:
		for frame in DrawCapture.WARMUP_FRAMES:
			await RenderingServer.frame_post_draw
		if args.has("--check-pixels"):
			ok = await _compare_coast(game)
		else:
			ok = await _capture(game, quality)
	var closed := await game._runtime_host.close_world()
	game.queue_free()
	await process_frame
	UITokens.release_cached_fonts()
	quit(0 if ok and closed.ok else 1)


func _set_view(camera: MapCamera, center: Vector2) -> void:
	camera.position = center
	camera._clamp_position()
	camera.force_update_scroll()
	camera._emit_view_changed_if_needed()


func _has_coast(game: PlayerGame) -> bool:
	var map := game._runtime_host.current_map()
	var view := game._camera.current_world_view_rect()
	for progress: float in [0.0, 0.5, 1.0]:
		var origin := COAST_START.lerp(COAST_END, progress) - view.size / 2.0
		var land := 0
		var water := 0
		for y in range(1, 9):
			for x in range(1, 9):
				var point := origin + view.size * Vector2(x / 9.0, y / 9.0)
				var cube := HexUtils.world_to_wrapped_cube(point, game._renderer.hex_size, map.width, map.height)
				if cube.x == 2147483647:
					continue
				var offset := HexUtils.cube_to_offset(cube.x, cube.y)
				var cell := offset.y * map.width + offset.x
				if map.is_water_arr[cell] == 0:
					land += 1
				else:
					water += 1
		if land == 0 or water == 0:
			push_error("The camera must show land and water at each coast checkpoint.")
			return false
	return true


func _compare_coast(game: PlayerGame) -> bool:
	var renderer := game._renderer
	# Read just the land and water result, without UI, weather overlays or units.
	renderer.set_terrain_render_scale(75, root.msaa_2d)
	var water := renderer._water_quad
	var coast := water.get_viewport()
	var lattice: SubViewport = renderer._ripple_table
	var material := renderer._water_mat
	var full = Table.new()
	full.configure(water, lattice.size, preload("res://shaders/water_ripple_lattice.gdshader"))
	var equal := true
	var reference: Image
	var time_per_phase := 1.15 / renderer.water_flow_advection
	for phase: float in [0.5 / 0.06, 0.5 / 0.04, 1.0 / 0.04]:
		# The boundaries change the second page, first page, then both pages.
		for side: float in [-0.001, 0.001]:
			await process_frame
			_set_view(game._camera, COAST_START.lerp(COAST_END, 0.5))
			renderer._world_time = phase * time_per_phase + side
			material.set_shader_parameter(&"water_ripple_lattice", lattice.get_texture())
			await RenderingServer.frame_post_draw
			var current := coast.get_texture().get_image()
			full.material.set_shader_parameter(&"cycles", _cycles(lattice))
			full.refresh()
			material.set_shader_parameter(&"water_ripple_lattice", full.get_texture())
			await RenderingServer.frame_post_draw
			reference = coast.get_texture().get_image()
			var same := current != null and reference != null and not current.is_empty() \
				and current.get_size() == reference.get_size() and current.get_data() == reference.get_data()
			print("[water-ripple-coast] threshold=%.5f side=%.3f equal=%s" % [phase, side, same])
			equal = equal and same
	# Make sure equivalence was measured where the water shader reads the table.
	var flat := Image.create_empty(lattice.size.x, lattice.size.y, false, Image.FORMAT_RGBAH)
	material.set_shader_parameter(&"water_ripple_lattice", ImageTexture.create_from_image(flat))
	await RenderingServer.frame_post_draw
	var changed := coast.get_texture().get_image()
	var samples_table := changed != null and reference != null and not changed.is_empty() \
		and changed.get_size() == reference.get_size() and changed.get_data() != reference.get_data()
	material.set_shader_parameter(&"water_ripple_lattice", lattice.get_texture())
	full.queue_free()
	print("[water-ripple-coast] pixel parity=%s visible table effect=%s" % [equal, samples_table])
	return equal and samples_table


func _capture(game: PlayerGame, quality: String) -> bool:
	var renderer := game._renderer
	var terrain := renderer._water_quad.get_viewport()
	var scale: int = renderer._graphics_details.terrain_scale_percent
	var window_size := root.size
	var day := game._world_clock.day_index()
	var counts := [0, 0, 0, 0, 0]
	var rows: Array[Dictionary] = []
	var previous := Vector4.ZERO
	var last_draw := Time.get_ticks_usec()
	var epoch := Time.get_unix_time_from_system() - last_draw / 1000000.0
	var table: SubViewport
	var table_rect: ColorRect
	var stamp_prefix := ""
	var valid := true
	var reached_end := false
	while valid and not reached_end:
		await process_frame
		var frame := rows.size()
		var begin := Time.get_ticks_usec()
		var start_time: float = renderer._world_time
		var center := COAST_START.lerp(COAST_END, minf(start_time / ROUTE_SECONDS, 1.0))
		_set_view(game._camera, center)
		if frame == 0:
			renderer._ripple_table.free()
			renderer._ripple_table = null
			Water._bind_ripple_lattice(renderer)
			table = renderer._ripple_table
			table_rect = table.get_child(0) as ColorRect
			var rid := table.get_viewport_rid()
			stamp_prefix = str(rid.get_id())
			RenderingServer.viewport_set_measure_render_time(rid, true)
		await RenderingServer.frame_post_draw
		var end := Time.get_ticks_usec()
		var cycles := _cycles(table)
		var first := cycles.x != previous.x or cycles.y != previous.y
		var second := cycles.z != previous.z or cycles.w != previous.w
		var kind := 4 if frame == 0 else int(first) | (int(second) << 1)
		var rect := table_rect.get_rect() if kind != 0 else Rect2()
		var calls := table.get_render_info(Viewport.RENDER_INFO_TYPE_CANVAS,
			Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME) if kind != 0 else 0
		rows.append({"frame": frame, "begin_us": begin, "end_us": end, "kind": kind,
			"world_time": renderer._world_time,
			"cycles": [cycles.x, cycles.y, cycles.z, cycles.w],
			"table_rect": [rect.position.x, rect.position.y, rect.size.x, rect.size.y],
			"table_draws": calls, "app_interval_ms": (end - last_draw) / 1000.0})
		counts[kind] += 1
		last_draw = end
		previous = cycles
		valid = valid and game._camera.get_screen_center_position().is_equal_approx(center) \
			and root.size == window_size and game._world_clock.day_index() == day \
			and is_equal_approx(game._camera.zoom.x, ZOOM) and renderer._water_quad.is_visible_in_tree() \
			and calls == int(kind != 0) and (frame == 0 or renderer._world_time > start_time)
		RenderingServer.call_on_render_thread(_read_timestamps.bind(stamp_prefix))
		if frame == 0:
			# Advance the renderer's ordinary 1x display clock on the frozen map.
			renderer.set_simulation_speed_multiplier(1.0)
			renderer.set_clock_running(true)
		reached_end = start_time >= ROUTE_SECONDS
	renderer.set_clock_running(false)
	var device := RenderingServer.get_rendering_device()
	# Timestamp queries return after the graphics driver's frame delay.
	for frame in range(device.get_frame_delay() + 1):
		await RenderingServer.frame_post_draw
		RenderingServer.call_on_render_thread(_read_timestamps.bind(stamp_prefix))
	await process_frame
	var window_px := DrawCapture._draw_size(root)
	var terrain_px := DrawCapture._draw_size(terrain) if terrain != root else window_px
	var refreshed: int = counts[1] + counts[2] + counts[3] + counts[4]
	valid = valid and reached_end and counts.min() > 0 and _pass_stamps.size() == refreshed \
		and window_px.x > 0 and terrain_px.x > 0
	var path := "user://water-ripple-coast-%d.json" % OS.get_process_id()
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("Could not save coast timing data.")
		return false
	file.store_string(JSON.stringify({"ok": valid, "quality": quality, "driver": RenderingServer.get_current_rendering_driver_name(),
		"table_mode": "changed_pages" if table.has_method("update_cycles") else "full",
		"adapter": RenderingServer.get_video_adapter_name(), "model": OS.get_model_name(),
		"godot": Engine.get_version_info().string, "process_id": OS.get_process_id(), "epoch_unix_s": epoch,
		"vsync": DisplayServer.window_get_vsync_mode(), "max_fps": Engine.max_fps,
		"scale_percent": scale, "window_px": [window_px.x, window_px.y], "terrain_px": [terrain_px.x, terrain_px.y],
		"counts": counts, "frames": rows, "table_stamps": _pass_stamps.values()}))
	file.close()
	print("[water-ripple-coast] valid=%s counts=%s timings=%s" % [valid, counts, ProjectSettings.globalize_path(path)])
	return valid


func _read_timestamps(id: String) -> void:
	var rd := RenderingServer.get_rendering_device()
	var begin_cpu := 0
	var begin_gpu := 0
	for index in rd.get_captured_timestamps_count():
		var tag := rd.get_captured_timestamp_name(index)
		if tag == "vp_begin_" + id:
			begin_cpu = rd.get_captured_timestamp_cpu_time(index)
			begin_gpu = rd.get_captured_timestamp_gpu_time(index)
		elif tag == "vp_end_" + id and begin_cpu > 0:
			var end_cpu := rd.get_captured_timestamp_cpu_time(index)
			var end_gpu := rd.get_captured_timestamp_gpu_time(index)
			_store_stamp.call_deferred(begin_cpu, end_cpu - begin_cpu, end_gpu - begin_gpu)


func _store_stamp(begin_us: int, cpu_us: int, gpu_ns: int) -> void:
	_pass_stamps[begin_us] = {"begin_us": begin_us, "cpu_us": cpu_us, "gpu_ns": gpu_ns if gpu_ns > 0 else null}


func _cycles(table: SubViewport) -> Vector4:
	var cycles: Variant = table.material.get_shader_parameter(&"cycles")
	return cycles if cycles is Vector4 else Vector4.ZERO
