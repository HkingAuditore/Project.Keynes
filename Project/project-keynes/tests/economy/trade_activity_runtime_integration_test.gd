extends SceneTree

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
	var game: Node = load("res://scenes/player_game.tscn").instantiate()
	var host: WorldRuntimeHost = game.get_node("RuntimeHost")
	host.fog_of_war_enabled = false
	root.add_child(game)
	await host.world_ready
	for frame in 4: await process_frame
	var clock: WorldClock = game.get_node("WorldClock")
	var camera: MapCamera = game.get_node("MapCamera")
	var activity: TradeActivityLayer = game.get_node("WorldRoot/TradeActivityLayer")
	var generator = host.get("_generator")
	var ext: Object = generator.get_data_core_world_ext()
	var map: MapData = host.current_map()
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
	expect("formal player scene owns the trade batch", activity != null)
	var renderer: HexRenderer = game.get_node("WorldRoot/HexRenderer")
	expect("renderer registers the production trade lighting consumer", renderer._trade_visual_layer == activity)
	renderer.set_day_phase(0.36)
	expect("day phase reaches both trade passes", is_equal_approx(float(activity._material.get_shader_parameter("day_phase")), 0.36)
		and is_equal_approx(float(activity._shadow_material.get_shader_parameter("day_phase")), 0.36))
	var world: WorldData = renderer._world
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
	game.queue_free()
	await process_frame
	print("=== trade activity production integration: %d failures ===" % _failures)
	quit(0 if _failures == 0 else 1)
