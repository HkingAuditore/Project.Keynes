extends SceneTree

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	root.size = Vector2i(1720, 420)
	var background := ColorRect.new()
	background.color = Color(0.91, 0.84, 0.67)
	background.size = Vector2(1720, 420)
	root.add_child(background)
	var host := Control.new()
	host.theme = load("res://assets/themes/player_session_theme.tres")
	root.add_child(host)
	var script = load("res://scripts/ui/components/ideology_point_scroll.gd")
	var widths := [420.0, 1000.0, 1660.0]
	for index in widths.size():
		var bar = script.new()
		host.add_child(bar)
		bar.position = Vector2(24, 24 + index * 120)
		bar.size = Vector2(widths[index], 64)
		bar.set_points(int([0.0, 3.0, 9.2][index] * 65536), 6 * 65536, 13107, true, true)
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var result := image.save_png("res://tmp/ideology_scroll_qa/preview.png")
	print("scroll QA capture: ", result)
	quit(result)
