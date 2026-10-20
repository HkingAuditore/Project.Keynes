extends SceneTree

var failures: Array[String] = []
var directory := ""

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	directory = OS.get_environment("PK_MENU_QA_DIR")
	if directory.is_empty(): directory="user://menu_atlas_qa"
	DirAccess.make_dir_recursive_absolute(directory)
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	change_scene_to_file("res://scenes/main_menu.tscn")
	await process_frame
	await process_frame
	await process_frame
	var menu: Control = current_scene as Control
	for physical in [Vector2i(1280,720),Vector2i(1366,768),Vector2i(1920,1080),Vector2i(2560,1080)]:
		DisplayServer.window_set_size(physical)
		for scale in [100,125,150]:
			root.content_scale_factor = float(scale)/100.0
			await process_frame
			await process_frame
			for page in ["home","new","load","settings"]:
				menu.call("_show_"+ ("new_game" if page=="new" else "load_game" if page=="load" else page))
				await create_timer(.48).timeout
				var bounds: Rect2 = menu.get_viewport_rect()
				var target := menu.get_node("%StartButton") as Control if page=="new" else menu.get_node("%NewGameButton") as Control if page=="home" else menu.get_node("%LoadBackButton") as Control if page=="load" else menu.get_node("%ApplySettingsButton") as Control
				if not bounds.grow(1).encloses(target.get_global_rect()):
					failures.append("%s %s %d action overflow %s in %s" % [page,physical,scale,target.get_global_rect(),bounds])
				await RenderingServer.frame_post_draw
				root.get_texture().get_image().save_png("%s/%s_%dx%d_%d.png" % [directory,page,physical.x,physical.y,scale])
	menu.hide()
	var loading := load("res://scenes/ui/world_loading_overlay.tscn").instantiate() as WorldLoadingOverlay
	root.add_child(loading)
	loading.show_message("正在生成世界")
	loading.set_layout_state({"num_continents":2,"seed":20260723})
	loading.set_progress("encode",.85)
	await create_timer(.65).timeout
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(directory+"/loading.png")
	loading.queue_free()
	menu.queue_free()
	await process_frame
	for failure in failures: push_error(failure)
	print("[menu-atlas-visual] %d failures, %s" % [failures.size(),directory])
	quit(0 if failures.is_empty() else 1)
