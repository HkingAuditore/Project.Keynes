extends SceneTree


func _initialize() -> void:
	call_deferred("_capture")


func _capture() -> void:
	var scene_path := OS.get_environment("PK_UI_CAPTURE_SCENE") \
		if OS.has_environment("PK_UI_CAPTURE_SCENE") else "res://scenes/main_menu.tscn"
	if OS.has_environment("PK_UI_CAPTURE_WIDTH") and OS.has_environment("PK_UI_CAPTURE_HEIGHT"):
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		DisplayServer.window_set_size(Vector2i(
			int(OS.get_environment("PK_UI_CAPTURE_WIDTH")),
			int(OS.get_environment("PK_UI_CAPTURE_HEIGHT"))))
		await process_frame
	var error := change_scene_to_file(scene_path)
	if error != OK:
		push_error("main menu capture: scene change failed (%s)" % error)
		quit(1)
		return
	for _frame in range(3):
		await process_frame
	var page := OS.get_environment("PK_UI_CAPTURE_PAGE") \
		if OS.has_environment("PK_UI_CAPTURE_PAGE") else "home"
	if current_scene != null and scene_path == "res://scenes/main_menu.tscn":
		match page:
			"new": current_scene.call("_show_new_game")
			"load": current_scene.call("_show_load_game")
			"settings": current_scene.call("_show_settings")
	for _frame in range(8):
		await process_frame
	var image := root.get_texture().get_image()
	if image == null or image.is_empty():
		push_error("main menu capture: viewport image is empty")
		quit(1)
		return
	var path := OS.get_environment("PK_UI_CAPTURE_PATH") \
		if OS.has_environment("PK_UI_CAPTURE_PATH") else "user://main_menu_capture.png"
	var save_error := image.save_png(path)
	if save_error != OK:
		push_error("main menu capture: PNG write failed (%s)" % save_error)
		quit(1)
		return
	var sampled_nonblack := 0
	for y in range(0, image.get_height(), maxi(1, image.get_height() / 32)):
		for x in range(0, image.get_width(), maxi(1, image.get_width() / 32)):
			if image.get_pixel(x, y).get_luminance() > 0.015:
				sampled_nonblack += 1
	print("main menu capture: %dx%d nonblack_samples=%d path=%s" % [
		image.get_width(), image.get_height(), sampled_nonblack, path])
	quit(0 if sampled_nonblack > 64 else 1)
