extends SceneTree

const Model = preload("res://scripts/ui/annual_report_view_model.gd")
const Fixture = preload("res://tests/ui/annual_report_test.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	root.content_scale_factor = 1.0
	root.size = Vector2i(1920, 1080)
	var workspace = load("res://scenes/ui/annual_report_workspace.tscn").instantiate()
	root.add_child(workspace)
	workspace.present(Model.build(Fixture.fixture()), true)
	workspace.finish_opening()
	await process_frame
	await process_frame
	var vp: Vector2 = root.get_visible_rect().size
	print("vp =", vp, " cover.get_viewport_rect =", workspace.cover().get_viewport_rect().size)
	print("paper column =", AnnualReportTokens.paper_column(vp))
	print("sheet top gap =", AnnualReportTokens.sheet_head_gap(vp),
			" foot gap =", AnnualReportTokens.sheet_foot_gap(vp))
	var cover = workspace.cover()
	print("cover size =", cover.size, " page_height=", cover.page_height())
	var names := ["_art_clip", "_art", "_wash", "_kicker", "_title", "_rule", "_country", "_seal", "_score", "_reward", "_ruler", "_cue"]
	for n in names:
		var c = cover.get(n)
		if c == null:
			print("  ", n, " = null")
			continue
		print("  ", n, " pos=", c.position, " size=", c.size, " visible=", c.visible,
			(" font=%d" % c.get_theme_font_size("font_size")) if c is Label else "")
	for n in ["_numerals", "_captions", "_deltas"]:
		var arr: Array = cover.get(n)
		for i in arr.size():
			print("  ", n, i, " pos=", arr[i].position, " size=", arr[i].size, " font=", arr[i].get_theme_font_size("font_size"), " vis=", arr[i].visible, " text=", arr[i].text)
	print("clip_children=", cover.get("_art_clip").clip_children, "  CLIP_ONLY=", CanvasItem.CLIP_CHILDREN_ONLY)
	workspace.queue_free()
	await process_frame
	quit(0)
