extends "res://tests/ui/inspector_live_patch_test.gd"

## 复用现有 UI 回归样本，在真实场景中验收字体、纸贴和滚动布局；不启动模拟。
const OUTPUT := "res://../../artifacts/ui-readability"


func _run() -> void:
	root.content_scale_factor = 1.0
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	for dimensions in [Vector2i(1280, 720), Vector2i(1920, 1080)]:
		root.size = dimensions
		var viewport := SubViewport.new()
		viewport.size = dimensions
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		root.add_child(viewport)
		var page := Control.new()
		page.size = dimensions
		page.theme = load("res://assets/themes/player_session_theme.tres")
		viewport.add_child(page)
		var background := ColorRect.new()
		background.color = Color(0.16, 0.22, 0.21)
		background.size = dimensions
		page.add_child(background)
		var top := load("res://scenes/ui/player_top_bar.tscn").instantiate() as PlayerTopBar
		page.add_child(top)
		top.update_time_state(99, 12, 28, true, 10.0)
		var toolbar := load("res://scenes/ui/map_overlay_toolbar.tscn").instantiate() as MapOverlayToolbar
		page.add_child(toolbar)
		var country := load("res://scenes/ui/country_action_bar.tscn").instantiate() as CountryActionBar
		page.add_child(country)
		country.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
		country.offset_right = -500.0
		country.offset_left = country.offset_right - 412.0
		country.offset_left = float(dimensions.x) - 912.0
		country.offset_top = -102.0
		country.offset_bottom = -16.0
		var panel := load("res://scenes/ui/inspector_panel.tscn").instantiate() as InspectorPanel
		page.add_child(panel)
		panel.offset_top = PlayerTopBar.BAR_HEIGHT + 12.0
		panel.set_model_for_selection(_make_model())
		panel.visible = true
		for tab in ["geography", "population", "market", "buildings"]:
			panel.select_tab(tab)
			await create_timer(0.5).timeout
			await RenderingServer.frame_post_draw
			var path := "%s/%s_%dx%d.png" % [OUTPUT, tab, dimensions.x, dimensions.y]
			viewport.get_texture().get_image().save_png(path)
			print("[readability] %s" % ProjectSettings.globalize_path(path))
		viewport.queue_free()
		await process_frame
	quit()
