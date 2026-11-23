extends SceneTree

## Checks the Issue #54 map, visibility cases and benchmark settings.
## --explored prepares exploration memory with fog still enabled.
## --fog-off selects the separate diagnostic. --measure runs the actual player scene.
## --check-exit runs that scene and checks teardown without taking draw samples.
const GraphicsQualitySettings = preload("res://scripts/game/graphics_quality_settings.gd")
const DrawCapture = preload("res://tests/rendering/mobile_terrain_draw_capture.gd")
const ResourceGeometry = preload("res://scripts/rendering/resource_visual_geometry.gd")
const WebAutotest = preload("res://scripts/game/web_autotest.gd")
const MAP_SIZE := Vector2i(60, 40)
const WINDOW_SIZE := Vector2i(1600, 960)
const SEED := 20260718
const FOREIGN_COUNT := 3

var _checks := 0
var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if not root.is_node_ready():
		await root.ready
	await process_frame
	var args := OS.get_cmdline_user_args()
	var fog_enabled := not args.has("--fog-off")
	var explored_fixture := args.has("--explored")
	var measure := args.has("--measure")
	var check_exit := args.has("--check-exit")
	var use_player_scene := measure or check_exit
	var omitted_layer := ""
	if explored_fixture and not fog_enabled:
		push_error("--explored requires fog. Run --fog-off separately.")
		quit(1)
		return
	if measure and check_exit:
		push_error("Run --measure and --check-exit separately.")
		quit(1)
		return
	for arg in args:
		if arg in ["--explored", "--fog-off", "--measure", "--check-exit"]:
			continue
		var layer := arg.trim_prefix("--omit-")
		if not measure or not omitted_layer.is_empty() or not arg.begins_with("--omit-") \
				or layer not in ["land", "water", "vegetation"]:
			push_error("Use --measure with at most one of --omit-land, --omit-water, --omit-vegetation.")
			quit(1)
			return
		omitted_layer = layer
	if measure and (DisplayServer.get_name() == "headless"
			or RenderingServer.get_current_rendering_method() != "mobile"
			or RenderingServer.get_rendering_device() == null):
		push_error("--measure requires a window and the Mobile renderer. No draw samples recorded.")
		quit(1)
		return
	Engine.set_meta("pk_fog_off", not fog_enabled)
	var settings := root.get_node("GameSettings")
	# Set every draw option so earlier custom settings cannot leak into a trial.
	var applied: Dictionary = settings.update({
		"window_mode": "windowed",
		"resolution_width": WINDOW_SIZE.x,
		"resolution_height": WINDOW_SIZE.y,
		"ui_scale_percent": 100,
		"ui_layout_mode": "fit",
		"ui_layout_scale": 100,
		"vsync": false,
		"render_quality": "low",
		"graphics_custom": true,
		"map_render_scale": 100,
		"fog_render_scale": 50,
		"water_detail": 0,
		"vegetation_detail": 0,
		"weather_detail": 0,
		"cloud_shadow": false,
		"frame_rate_limit": 0,
		"autosave_enabled": false,
	}, false)
	_check(applied.ok, "benchmark settings apply without saving")
	var config := WebAutotest.build_config({"seed": SEED, "width": MAP_SIZE.x, "height": MAP_SIZE.y})
	config.country.foreign_count = FOREIGN_COUNT
	var game: PlayerGame
	var clock: WorldClock
	var host: WorldRuntimeHost
	if use_player_scene:
		game = await DrawCapture.open_game(self, config)
		_check(game != null, "formal new game accepts the benchmark config")
		if game == null:
			quit(1)
			return
		clock = game._world_clock
		host = game._runtime_host
	else:
		clock = WorldClock.new()
		clock.auto_start = false
		root.add_child(clock)
		host = WorldRuntimeHost.new()
		root.add_child(host)
		host.configure(null, null, clock)
		var started := host.configure_session({"kind": "new_game", "config": config.to_dictionary()})
		_check(started.ok, "formal new game accepts the benchmark config")
		if not started.ok:
			quit(1)
			return
		await host.generate_world()
	var map := host.current_map()
	var ready := map != null and host.is_runtime_ready_for_ticks()
	_check(ready, "formal new game publishes the map and starts the executor")
	if not ready:
		quit(1)
		return
	var countries: Dictionary[int, bool] = {}
	for slot in map.country_slot_arr:
		if slot >= 0:
			countries[slot] = true
	var explored := map.explored_arr.count(1)
	var visible := map.visible_arr.count(1)
	_check(Vector2i(map.width, map.height) == MAP_SIZE and host.last_seed() == SEED,
		"generated seed and world size match the benchmark")
	_check(countries.size() == FOREIGN_COUNT + 1, "four countries own starting territory")
	_check(clock.speed_multiplier == 1.0 and clock.day_index() == 0, "opening date at 1x")
	_check(explored > 0 and explored < map.cell_count(), "opening fog memory is only partly explored")
	_check(host.is_fog_of_war_enabled() == fog_enabled, "requested fog mode reaches the world")
	if fog_enabled:
		_check(visible > 0 and visible <= explored, "opening visibility stays within exploration memory")
	else:
		_check(visible == map.cell_count() and map.fog_k_arr.count(255) == map.cell_count(),
			"fog-off shows every cell without exploring it")
	_check(Engine.max_fps == 0, "engine frame cap disabled")

	var remembered_land := 0
	if explored_fixture:
		await _prepare_explored_map(host, map)
		remembered_land = _count_remembered_land(map)
		_check(host.is_fog_of_war_enabled(), "exploration leaves fog enabled")
		_check(remembered_land * 2 > map.is_water_arr.count(0), "most land remains explored under fog")
		_check(map.explored_arr.count(0) > 0, "the explored fixture keeps unexplored cells")

	var scene := ("explored" if explored_fixture else "opening") if fog_enabled else "fog-off"
	var capture_ready := measure and _failures == 0
	for percent in [100, 75]:
		settings.update({"map_render_scale": percent}, false)
		_check_profile(settings.values(), percent, false)
		_check_profile(settings.values(), percent, true)
		if capture_ready:
			var captured := await DrawCapture.record(game, scene, percent, omitted_layer)
			_check(captured, "valid windowed draw samples and sizes at %d%%" % percent)
	print("[mobile-terrain-baseline] scene=%s seed=%d map=%s countries=%d fog=%s explored=%d visible=%d remembered_land=%d/%d" %
		[scene, host.last_seed(), MAP_SIZE, countries.size(), host.is_fog_of_war_enabled(),
			map.explored_arr.count(1), map.visible_arr.count(1), remembered_land, map.is_water_arr.count(0)])

	var font_probes: Array[WeakRef] = []
	if check_exit:
		font_probes = _probe_cached_fonts()
	var closed := await host.close_world()
	_check(closed.ok, "formal session closes")
	if game != null:
		game.queue_free()
	else:
		host.queue_free()
		clock.queue_free()
	await process_frame
	if use_player_scene:
		_check(not is_instance_valid(game), "player scene is released before font cleanup")
		# Godot 4.6.3 cleans the text server before releasing script statics.
		UITokens.release_cached_fonts()
		for font_ref in font_probes:
			_check(font_ref.get_ref() == null, "cached UI font is released before engine cleanup")
	else:
		await _check_vegetation_omission()
	print("mobile terrain baseline: %d checks, %d failures" % [_checks, _failures])
	quit(int(_failures != 0))


func _probe_cached_fonts() -> Array[WeakRef]:
	var probes: Array[WeakRef] = []
	for font: Font in [UITokens.dossier_font("sans"), UITokens.annual_font("label")]:
		var size := font.get_string_size("粮食", HORIZONTAL_ALIGNMENT_LEFT, -1, 18)
		_check(size.x > 0, "cached UI font shapes a line before cleanup")
		probes.append(weakref(font))
	return probes


func _prepare_explored_map(host: WorldRuntimeHost, map: MapData) -> void:
	var opening_owners := map.country_slot_arr.duplicate()
	var opening_visible := map.visible_arr.duplicate()
	# Use temporary territory as observation points. The executor publishes both
	# the reveal and the later loss of sight, leaving real exploration memory.
	var locations := PackedInt32Array()
	for row in range(2, map.height, 4):
		for column in range(2, map.width, 4):
			var cell: int = row * map.width + column
			if map.is_water_arr[cell] == 0 and opening_owners[cell] < 0:
				locations.append(cell)
	var country := host.get_generator().get_country_facade() as CountryFacade
	var player := host._resolve_player_country_handle()
	for day in [1, 2]:
		var batch: Array[Dictionary] = []
		for cell in locations:
			batch.append({"opcode": CountryFacade.Opcode.TRANSFER_TERRITORY,
				"cell": cell, "target_handle": player if day == 1 else 0,
				"effective_day": day, "sequence": day * map.cell_count() + cell})
		var accepted := country.submit(batch, true)
		_check(accepted.ok, "exploration territory commands admitted for day %d" % day)
		if not accepted.ok:
			return
		var admitted := host._admit_runtime_calendar(day + 1)
		_check(admitted == day, "executor admits exactly day %d at 1x" % day)
		if admitted != day:
			return
		while host._runtime_commit_day < day and not host.is_runtime_fault_paused():
			await process_frame
		_check(host._runtime_commit_day == day, "executor publishes day %d" % day)
		if host._runtime_commit_day != day:
			return
	_check(map.country_slot_arr == opening_owners, "exploration restores the opening borders")
	_check(map.visible_arr == opening_visible, "temporary sight returns to the opening extent")


func _count_remembered_land(map: MapData) -> int:
	var count := 0
	for cell in map.cell_count():
		if map.is_water_arr[cell] == 0 and map.explored_arr[cell] != 0 and map.visible_arr[cell] == 0:
			count += 1
	return count


func _check_profile(values: Dictionary, percent: int, mobile: bool) -> void:
	var profile := GraphicsQualitySettings.resolve(values, mobile)
	_check(values.window_mode == "windowed" and not values.vsync
		and Vector2i(values.resolution_width, values.resolution_height) == WINDOW_SIZE,
		"window preferences match the benchmark")
	_check(profile.render_quality == "low" and profile.map_render_scale == percent
		and profile.fog_render_scale == 50 and profile.frame_rate_limit == 0,
		"both platforms resolve the same %d%% low profile" % percent)
	_check(profile.water_detail == 0 and profile.vegetation_detail == 0
		and profile.weather_detail == 0 and not profile.cloud_shadow,
		"map scale preserves low water, vegetation, weather and cloud shadows")


func _check_vegetation_omission() -> void:
	var renderer := HexRenderer.new()
	var resources := ResourceVisualLayer.new()
	root.add_child(resources)
	renderer._resource_visual_layer = resources
	resources.set_quality(0, 0)
	resources._world = WorldData.new()
	resources._world.wrap_period_x = 800.0
	resources._camera = Rect2(-1600.0, -100.0, 3200.0, 1600.0)
	var cover := resources.ground_cover()
	cover.configure([], 22.0, Vector2i.ONE, Rect2(0.0, 0.0, 800.0, 300.0), 800.0, null, null)
	var plants := _upload_resource_batch(resources, Vector2i.ZERO, 0)
	var animals := _upload_resource_batch(resources, Vector2i.ZERO, 1)
	var minerals := _upload_resource_batch(resources, Vector2i.ZERO, 2)
	var mask := root.canvas_cull_mask
	_check(cover.visible and cover._mesh_inst.mesh != null and (cover.visibility_layer & mask) != 0,
		"the low-quality scene has a drawable ground-cover pass")
	_check(plants != null and animals != null and minerals != null, "resource batches upload before omission")
	_check(DrawCapture._omit_draw(renderer, "vegetation"), "vegetation omission selects resource vegetation")
	_check(cover.visible and (cover.visibility_layer & mask) == 0,
		"vegetation omission blocks ground-cover drawing while preserving its visibility state")
	var streamed := _upload_resource_batch(resources, Vector2i(1, 0), 0)
	await process_frame
	_check(_batch_uses_mask(plants, 0), "vegetation omission blocks the existing plant batch and wrap copies")
	_check(_batch_uses_mask(streamed, 0), "vegetation omission blocks a newly uploaded plant batch and wrap copies")
	_check(_batch_uses_mask(animals, 1) and _batch_uses_mask(minerals, 1) and resources.visibility_layer == 1,
		"resource omission preserves animal and mineral batches and their wrap copies")
	resources.queue_free()
	renderer.free()
	await process_frame


func _upload_resource_batch(layer: ResourceVisualLayer, key: Vector2i, family: int) -> MultiMeshInstance2D:
	layer._active[key] = true
	var buffer := PackedFloat32Array([8.0, 0.0, 0.0, 120.0, 0.0, 8.0, 0.0, 60.0,
		0.0, 1.0, 1.0, 4.0 if family == 0 else 1.0, 0.0, 0.0, 0.0, 3.0])
	if not ResourceGeometry._install_upload(layer, {"key": key, "revision": layer._revision,
			"family": family, "buffer": buffer}):
		return null
	return layer._resident[key][family]


func _batch_uses_mask(batch: MultiMeshInstance2D, mask: int) -> bool:
	if batch == null or not batch.visible or batch.visibility_layer != mask:
		return false
	var copies: Array[MultiMeshInstance2D] = batch.get_meta("wraps", [])
	return copies.size() == 2 and copies[0].visible and copies[1].visible \
		and copies[0].visibility_layer == mask and copies[1].visibility_layer == mask


func _check(ok: bool, description: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		push_error(description)
