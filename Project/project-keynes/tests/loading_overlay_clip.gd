extends SceneTree

## Captures the loading paper-strip animation without starting a world.
## The art motion and the progress value are intentionally independent.
var _overlay: WorldLoadingOverlay
var _dir := ""
var _frame := 0
var _next_usec := 0

func _initialize() -> void:
	_dir = OS.get_environment("PK_LOADING_CLIP_DIR")
	if _dir.is_empty():
		_dir = "user://loading_overlay_clip"
	DirAccess.make_dir_recursive_absolute(_dir)
	call_deferred("_run")

func _run() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(Vector2i(1366, 768))
	_overlay = load("res://scenes/ui/world_loading_overlay.tscn").instantiate() as WorldLoadingOverlay
	root.add_child(_overlay)
	_overlay.show_message("正在展开地图台")
	_overlay.set_layout_state({"initial_seed": 20260723, "num_continents": 2, "continent_size": .72, "sea_level": .46})
	await process_frame
	for i in range(90):
		_overlay.set_progress("terrain" if i < 58 else "encode", float(i) / 89.0)
		await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("%s/frame_%04d.png" % [_dir, _frame])
		_frame += 1
	_overlay.hide_completed()
	await create_timer(.4).timeout
	print("[loading-overlay-clip] %d frames -> %s" % [_frame, _dir])
	quit(0)
