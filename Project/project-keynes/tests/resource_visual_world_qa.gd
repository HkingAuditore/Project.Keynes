extends SceneTree

const ResourceCatalog = preload("res://scripts/rendering/resource_visual_catalog.gd")

# Production new-game path: resources, existing trees and existing settlement
# geometry in one render. Does not write the player's saves or settings.
func _init() -> void:
	call_deferred("run")

func run() -> void:
	root.size = Vector2i(1440, 1000)
	var flow := root.get_node("GameFlow")
	var config := NewGameConfig.new()
	config.country.foreign_count = 0
	config.base.map_width = 40
	config.base.map_height = 28
	config.base.initial_seed = 20260727
	config.base.num_continents = 2
	config.base.continent_size = 0.9
	config.base.sea_level = 0.42
	config.base.river_count = 8
	var request: Dictionary = flow.begin_new_game(config)
	if not bool(request.get("ok", false)):
		push_error(str(request))
		quit(1)
		return
	var host: WorldRuntimeHost
	var deadline := Time.get_ticks_msec() + 150000
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if current_scene is PlayerGame:
			host = current_scene.get_node("RuntimeHost")
			if host.current_map() != null and bool(host.generator().gameplay_start_report().get("ok", false)) \
					and bool(host.get("_runtime_ready_for_ticks")):
				break
	if host == null or host.current_map() == null:
		push_error("resource world QA timed out before new game")
		quit(1)
		return
	var game := current_scene
	game.get_node("WorldClock").pause(true)
	var renderer := host.get_renderer()
	renderer.set_day_night_enabled(false)
	host.set_fog_of_war_enabled(false)
	game.get_node("UI").visible = false
	var map := host.current_map()
	var start := int(host.generator().gameplay_start_report().get("cell", 0))
	var camera := game.get_node("MapCamera") as Camera2D
	camera.position = Vector2(map.cell_pos_x_arr[start], map.cell_pos_y_arr[start]) * renderer.hex_size
	camera.zoom = Vector2(3.0, 3.0)
	camera.set("_target_zoom", Vector2(3.0, 3.0))
	for frame in 180:
		await process_frame
	var output := "res://tmp/resource_visual_qa"
	if RenderingServer.get_current_rendering_method() == "gl_compatibility":
		output += "/gl_compatibility"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(output + "/world_with_resources.png")
	renderer._resource_visual_layer.visible = false
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(output + "/world_baseline.png")
	renderer._resource_visual_layer.visible = true
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	var timings := {}
	for enabled in [false, true]:
		renderer._resource_visual_layer.visible = enabled
		var samples := []
		for frame in 45:
			await process_frame
			if frame >= 15:
				samples.append(RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid()))
		samples.sort()
		timings["resources_on_ms" if enabled else "resources_off_ms"] = samples[samples.size() / 2]
	var metrics := {"device": RenderingServer.get_video_adapter_name(),
		"renderer": RenderingServer.get_current_rendering_method(), "gpu": timings,
		"scenery": renderer.resource_visual_diagnostics()}
	var metrics_file := FileAccess.open(output + "/world_metrics.json", FileAccess.WRITE)
	metrics_file.store_string(JSON.stringify(metrics, "\t"))
	print("resource world GPU A/B: ", JSON.stringify(metrics))
	print("resource production-world QA: ", JSON.stringify(renderer.resource_visual_diagnostics()))
	var valid := int(renderer.resource_visual_diagnostics().get("instances", 0)) > 0
	# Inspect the closest real offshore deposit without fabricating reserves.
	var offshore := -1
	var closest := INF
	for cell in map.cell_count():
		if map.is_water_arr[cell] == 0 or map.res_oil_reserve_arr[cell] <= 0.0:
			continue
		var point := Vector2(map.cell_pos_x_arr[cell], map.cell_pos_y_arr[cell]) * renderer.hex_size
		var distance := camera.position.distance_squared_to(point)
		if distance < closest:
			closest = distance
			offshore = cell
	if offshore >= 0:
		camera.position = Vector2(map.cell_pos_x_arr[offshore], map.cell_pos_y_arr[offshore]) * renderer.hex_size
		camera.zoom = Vector2(6.0, 6.0)
		camera.set("_target_zoom", Vector2(6.0, 6.0))
		for frame in 180:
			await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(output + "/offshore_resources.png")
		renderer._resource_visual_layer.visible = false
		for frame in 3:
			await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(output + "/offshore_baseline.png")
		print("offshore QA: cell=", offshore, " oil_reserve=", map.res_oil_reserve_arr[offshore])
	else:
		push_error("resource QA fixture has no real offshore oil deposit")
		valid = false
	# 只选择世界里已有的动物，占领位不作测试伪造。
	var animal_cell := -1
	var animal_id := ""
	var animal_distance := INF
	var styles := ResourceCatalog.entries()
	for entry in styles:
		if String(entry.id) not in ["bio.cattle", "bio.sheep", "bio.pig", "bio.horse"]:
			continue
		for cell in map.cell_count():
			if (int(map.bio_occupancy_bits_arr[cell]) & (1 << int(entry.bit))) == 0:
				continue
			var point := Vector2(map.cell_pos_x_arr[cell], map.cell_pos_y_arr[cell]) * renderer.hex_size
			var score := camera.position.distance_squared_to(point) + float(map.snow_cover_arr[cell]) * 10000000.0
			if score < animal_distance:
				animal_distance = score
				animal_cell = cell
				animal_id = String(entry.id)
	if animal_cell >= 0:
		renderer._resource_visual_layer.visible = true
		renderer.set_resource_visual_filter(animal_id)
		camera.position = Vector2(map.cell_pos_x_arr[animal_cell], map.cell_pos_y_arr[animal_cell]) * renderer.hex_size
		camera.zoom = Vector2(6.0, 6.0)
		camera.set("_target_zoom", Vector2(6.0, 6.0))
		for frame in 180:
			await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(output + "/animals_world.png")
		print("animal QA: cell=", animal_cell, " species=", animal_id)
	else:
		print("animal QA: no matching species in this production fixture")
	game.queue_free()
	current_scene = null
	await process_frame
	quit(0 if valid else 1)
