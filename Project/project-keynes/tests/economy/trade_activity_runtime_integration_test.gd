extends SceneTree

signal world_prepared

## Formal player scene and full ACTIVE worker. Observe only; no synthetic
## trade orders, play callbacks or mutations of the production economy.
var _failures := 0
var _capture_dir := ""

func _init() -> void:
	call_deferred("_run")

func expect(label: String, passed: bool) -> void:
	print("[%s] %s" % ["PASS" if passed else "FAIL", label])
	if not passed: _failures += 1

func _run() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("capture_dir="):
			_capture_dir = argument.trim_prefix("capture_dir=")
	root.size = Vector2i(1280, 720)
	var config := NewGameConfig.create_default()
	config.base.map_width = 40
	config.base.map_height = 28
	config.base.initial_seed = 1
	config.country.foreign_count = 5
	root.get_node("GameFlow").set("_pending_request", {
		"kind": "new_game", "config": config.to_dictionary()})
	var scene := load("res://scenes/player_game.tscn") as PackedScene
	if scene == null:
		expect("formal player scene loads", false)
		await _finish(null)
		return
	var game := scene.instantiate()
	var host := game.get_node_or_null("RuntimeHost") as WorldRuntimeHost
	var clock := game.get_node_or_null("WorldClock") as WorldClock
	var camera := game.get_node_or_null("MapCamera") as MapCamera
	var renderer := game.get_node_or_null("WorldRoot/HexRenderer") as HexRenderer
	var activity := game.get_node_or_null("WorldRoot/TradeActivityLayer") as TradeActivityLayer
	expect("formal player scene owns the trade batch", activity != null)
	expect("formal player scene has the runtime host, clock, camera and renderer",
		host != null and clock != null and camera != null and renderer != null)
	if _failures != 0:
		await _finish(game)
		return
	host.fog_of_war_enabled = false
	host.world_ready.connect(func(_map, _world, _generator, _view_adapter) -> void:
		world_prepared.emit(), CONNECT_ONE_SHOT)
	host.world_generation_failed.connect(func(reason: String) -> void:
		expect("world generation failed: %s" % reason, false)
		world_prepared.emit(), CONNECT_ONE_SHOT)
	root.add_child.call_deferred(game)
	await world_prepared
	if _failures != 0:
		await _finish(game)
		return
	var world := host.world_data()
	var map := host.current_map()
	var generator := host.get_generator()
	var ext: Object = generator.get_data_core_world_ext() if generator != null else null
	expect("runtime host exposes the generated world data", world != null)
	expect("runtime host exposes the generated map and simulation worker", map != null and ext != null)
	if _failures != 0:
		await _finish(game)
		return
	for frame in 4: await process_frame
	camera.restore_view_state(Vector2(40.0 * sqrt(3.0) * host.hex_size / 2.0,
		28.0 * 1.5 * host.hex_size / 2.0), Vector2(0.6, 0.6))
	camera.force_update_scroll()
	clock.set_speed(50.0)
	var observed := false
	var progressed := false
	var deadline := Time.get_ticks_msec() + 6000
	var peak_vehicles := 0
	while Time.get_ticks_msec() < deadline:
		var status: Dictionary = ext.get_runtime_thread_report()
		if bool(status.get("fatal", false)):
			break
		progressed = progressed or int(status.get("simulation_committed_day", -1)) > 10
		var visible_count := int(activity.debug_snapshot().vehicle_count)
		peak_vehicles = maxi(peak_vehicles, visible_count)
		if visible_count > 0:
			observed = true
			break
		await create_timer(0.1).timeout
	clock.pause(true)
	var runtime: Dictionary = ext.get_runtime_thread_report()
	print("[trade-integration] ", {"runtime": runtime.get("authoritative_domain_mask", 0),
		"day": runtime.get("simulation_committed_day", -1), "visual": activity.debug_snapshot(),
		"trade": ext.get_economy_report().get("trade_orders_dispatched", -1),
		"cells": map.cell_count()})
	expect("renderer registers the production trade lighting consumer", renderer._trade_visual_layer == activity)
	renderer.set_day_phase(0.36)
	expect("day phase reaches both trade passes", is_equal_approx(float(activity._material.get_shader_parameter("day_phase")), 0.36)
		and is_equal_approx(float(activity._shadow_material.get_shader_parameter("day_phase")), 0.36))
	var tiled: bool = world.visual_tiles != null and world.visual_tiles.ready and world.visual_tiles.layout.mode == "tiled"
	var normal: Variant = world.visual_tiles.terrain_normal if tiled else world.terrain_normal_tex
	expect("trade binds the real map normal field and availability", bool(activity._material.get_shader_parameter("terrain_normal_tex_bound")) == (normal != null)
		and activity._material.get_shader_parameter("visual_terrain_normal_tiles" if tiled else "terrain_normal_tex") == normal)
	expect("production worker advances", progressed)
	expect("economy worker authority is ACTIVE", (int(runtime.get("authoritative_domain_mask", 0)) & 0x100) != 0)
	expect("new worlds do not invent decorative trade", observed or
		int(ext.get_economy_report().get("trade_orders_dispatched", 0)) == 0)
	expect("vehicle cap holds during fast-forward", peak_vehicles <= 96)
	expect("observer does not fault the production worker", not bool(runtime.get("fatal", false)))
	if observed and not _capture_dir.is_empty() and DisplayServer.get_name() != "headless":
		for frame in 12: await process_frame
		await RenderingServer.frame_post_draw
		DirAccess.make_dir_recursive_absolute(_capture_dir)
		root.get_texture().get_image().save_png(_capture_dir.path_join("production_trade.png"))
	await _finish(game)

func _finish(game: Node) -> void:
	if game != null:
		game.queue_free()
		await process_frame
	print("=== trade activity production integration: %d failures ===" % _failures)
	quit(0 if _failures == 0 else 1)
