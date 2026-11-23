extends Node

## coast-pan-v1: four identical passes through the original iPhone reference coastline.
const GraphicsQualitySettings = preload("res://scripts/game/graphics_quality_settings.gd")
const DrawCapture = preload("res://scripts/diagnostics/coast_pan_capture.gd")
const WebAutotest = preload("res://scripts/game/web_autotest.gd")
const MAP_SIZE := Vector2i(60, 40)
const WINDOW_SIZE := Vector2i(1600, 960)
const SEED := 20260718
const FOREIGN_COUNT := 3

var _checks := 0
var _failures := 0


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	if not get_tree().root.is_node_ready():
		await get_tree().root.ready
	await get_tree().process_frame
	DisplayServer.screen_set_keep_on(true)
	if DisplayServer.get_name() == "headless" or RenderingServer.get_current_rendering_method() != "mobile":
		push_error("Coast pan requires a window and the Mobile renderer.")
		get_tree().quit(1)
		return
	Engine.set_meta("pk_fog_off", false)
	var settings := get_tree().root.get_node("GameSettings")
	# Set every draw option so earlier custom settings cannot leak into a trial.
	var applied: Dictionary = settings.update({
		"window_mode": "windowed",
		"resolution_width": WINDOW_SIZE.x,
		"resolution_height": WINDOW_SIZE.y,
		"ui_scale_percent": 100,
		"ui_layout_mode": "fit",
		"ui_layout_scale": 100,
		"vsync": true,
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
	var game := await DrawCapture.open_game(get_tree(), config)
	if game == null:
		get_tree().quit(1)
		return
	var clock := game._world_clock
	var host := game._runtime_host
	var map := host.current_map()
	var ready := map != null and host.is_runtime_ready_for_ticks()
	_check(ready, "formal new game publishes the map and starts the executor")
	if not ready:
		get_tree().quit(1)
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
	_check(host.is_fog_of_war_enabled(), "fog enabled")
	_check(visible > 0 and visible <= explored, "opening visibility")
	await _prepare_explored_map(host, map)
	_check(_count_remembered_land(map) * 2 > map.is_water_arr.count(0), "explored land")
	_check(map.explored_arr.count(0) > 0, "unexplored cells remain")
	settings.update({"map_render_scale": 100}, false)
	var profile := GraphicsQualitySettings.resolve(settings.values(), true)
	_check(profile.render_quality == "low" and profile.map_render_scale == 100
		and profile.fog_render_scale == 50 and profile.frame_rate_limit == 0
		and profile.water_detail == 0 and profile.vegetation_detail == 0
		and profile.weather_detail == 0 and not profile.cloud_shadow, "mobile low profile")
	_check(Engine.max_fps == 0 and DisplayServer.window_get_vsync_mode() == DisplayServer.VSYNC_ENABLED,
		"uncapped engine with display synchronization")
	var folder := "user://coast-pan/%d-%d" % [int(Time.get_unix_time_from_system()), OS.get_process_id()]
	_check(DirAccess.make_dir_recursive_absolute(folder) == OK, "create results directory")
	if _failures == 0:
		_check(await DrawCapture.record_coast(game, map, folder), "four complete coast passes")
	var closed := await host.close_world()
	_check(closed.ok, "formal session closes")
	game.queue_free()
	await get_tree().process_frame
	var status := FileAccess.open(folder.path_join("outcome.txt"), FileAccess.WRITE)
	_check(status != null, "write capture outcome")
	if status != null:
		status.store_line("%d checks, %d failures" % [_checks, _failures])
		status.close()
	print("[coast-pan] %d failures; %s" % [_failures, ProjectSettings.globalize_path(folder)])
	if not OS.has_feature("mobile") or _failures > 0:
		get_tree().quit(int(_failures > 0))


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
			await get_tree().process_frame
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


func _check(ok: bool, description: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		push_error(description)
