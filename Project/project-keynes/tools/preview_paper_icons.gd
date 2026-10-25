extends SceneTree

## 用真实 IconBadge 和 IconButton 展示已接入的语义图标，供美术复核。
var _output := "res://../../artifacts/paper-icons"

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("output="):
			_output = argument.trim_prefix("output=")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_output))
	root.size = Vector2i(1280, 900)
	root.content_scale_factor = 1.0
	root.content_scale_size = Vector2i(1280, 900)
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	for domain in ["good.", "profession.", "resource.", "economy.building", "hud.", "all_ui"]:
		var background := ColorRect.new()
		background.color = Color("e9dfc9")
		background.size = Vector2(1280, 900)
		background.theme = load("res://assets/themes/player_session_theme.tres")
		root.add_child(background)
		var title := Label.new()
		title.position = Vector2(28, 18)
		title.text = {"good.": "物资 · 彩铅纸贴", "profession.": "职业 · 彩铅纸贴",
			"resource.": "自然资源 · 彩铅纸贴", "economy.building": "建筑 · 彩铅纸贴",
			"hud.": "地图工具栏 · 彩铅纸贴", "all_ui": "全部界面标识 · 彩铅剪纸"}[domain]
		title.add_theme_font_size_override("font_size", 28)
		title.add_theme_color_override("font_color", Color("392b20"))
		background.add_child(title)
		var keys: Array[StringName] = []
		var candidate_keys: Array = IconCatalog.registered_keys() if domain == "all_ui" else IconCatalog.PAPER_TEXTURES.keys()
		for key in candidate_keys:
			if (domain == "all_ui" and not String(key).begins_with("good.") \
					and not String(key).begins_with("profession.") and not String(key).begins_with("resource.")) \
					or String(key).begins_with(domain) or (domain == "hud." and key in [
				&"geography.elevation", &"geography.surface", &"geography.terrain",
				&"climate.temperature", &"climate.humidity", &"climate.wind",
				&"ecology.growth", &"ecology.vegetation", &"hydrology.current"]):
				keys.append(key)
		var columns := 14 if domain in ["good.", "all_ui"] else 9
		var height := 68.0 if domain == "all_ui" else (79.0 if domain == "good." else 130.0)
		for i in range(keys.size()):
			var origin := Vector2(24 + (i % columns) * (1232.0 / columns),
				70 + (i / columns) * height)
			var badge := IconBadge.new()
			badge.position = origin
			badge.size = Vector2(56, 56) if domain in ["good.", "all_ui"] else Vector2(88, 88)
			background.add_child(badge)
			badge.set_semantic(keys[i])
			var caption := Label.new()
			caption.position = origin + Vector2(0, badge.size.y)
			caption.size.x = 1232.0 / columns - 2
			caption.clip_text = true
			caption.text = String(keys[i]).trim_prefix(domain).trim_prefix(".")
			caption.add_theme_font_size_override("font_size", 10)
			caption.add_theme_color_override("font_color", Color("392b20"))
			background.add_child(caption)
		if domain == "hud.":
			var states := ["normal", "hover", "pressed", "disabled"]
			var labels := ["常态", "悬停", "选中", "禁用"]
			for i in range(states.size()):
				var tile := PanelContainer.new()
				tile.position = Vector2(35 + i * 190, 550)
				tile.size = Vector2(148, 96)
				tile.add_theme_stylebox_override("panel",
					background.theme.get_stylebox(states[i], "PKHUDButton"))
				background.add_child(tile)
				var caption := Label.new()
				caption.text = labels[i]
				caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				caption.add_theme_color_override("font_color", Color("392b20"))
				tile.add_child(caption)
		if domain == "economy.building":
			var products := ["copper_ore", "copper", "grain", "fish", "logs", "technology_points"]
			for i in range(products.size()):
				var badge := IconBadge.new()
				badge.position = Vector2(30 + i * 160, 440)
				badge.size = Vector2(92, 92)
				background.add_child(badge)
				badge.set_semantic(IconCatalog.building_semantic(
					"preview", products[i], 0 if i in [0, 2, 3, 4] else 1))
			for icon_size in [16, 24, 32, 48]:
				var button := Button.new()
				button.position = Vector2(30 + icon_size * 6, 640)
				button.size = Vector2(72, 64)
				background.add_child(button)
				IconButton.apply(button, &"good.grain", icon_size)
		await process_frame
		await process_frame
		await RenderingServer.frame_post_draw
		var result := root.get_texture().get_image().save_png(
			_output.path_join(domain.trim_suffix(".").replace(".", "_") + ".png"))
		if result != OK:
			push_error("paper icon capture failed")
			quit(1)
			return
		background.queue_free()
		await process_frame
	print("[paper-icons-preview] captured six catalogs")
	quit()
