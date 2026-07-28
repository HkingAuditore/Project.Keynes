extends SceneTree


var _failures := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	root.size = Vector2i(1280, 720)
	var packed := load("res://scenes/player_game.tscn") as PackedScene
	var game := packed.instantiate()
	var runtime: WorldRuntimeHost = game.get_node("RuntimeHost")
	root.add_child(game)
	await runtime.world_ready
	await process_frame
	await process_frame

	var ui := game.get_node("UI") as GameUIManager
	var clock := game.get_node("WorldClock") as WorldClock
	var bar := game.get_node_or_null("UI/CountryActionBar") as CountryActionBar
	var panel := game.get_node_or_null("UI/CountryPanel") as CountryPanel
	_expect("country action bar exists", bar != null)
	_expect("country panel exists", panel != null)
	if bar == null or panel == null:
		_finish()
		return
	_expect("country panel starts closed", not panel.is_panel_open())
	var buttons: Dictionary = bar.get("_buttons")
	_expect("country action bar has five sections", buttons.size() == 5)
	for button_value in buttons.values():
		var action := button_value as Button
		var action_icons := action.find_children("*", "TextureRect", true, false) \
			if action != null else []
		_expect("country action uses icon only",
			action != null and action.text.is_empty() \
			and action.find_children("*", "Label", true, false).is_empty())
		_expect("country action icon is compact",
			action_icons.size() == 1 and (action_icons[0] as TextureRect) \
				.custom_minimum_size.x == CountryActionBar.ICON_SIZE)
		_expect("country action has no nested badge",
			action != null and action.find_children("*", "IconBadge", true, false).is_empty())
	_expect("country action bar is compact", bar.size.x <= 322.0)
	var paused_before := clock.paused
	for section_id in ["technology", "politics", "taxation", "military", "diplomacy"]:
		var button := buttons.get(section_id) as Button
		_expect("%s action exists" % section_id, button != null)
		if button != null:
			button.pressed.emit()
			await process_frame
			_expect("%s panel opens" % section_id,
				panel.is_panel_open() and panel.current_section() == section_id)
	_expect("opening country affairs does not pause", clock.paused == paused_before)

	var model: Dictionary = panel.get("_model")
	_expect("country summary is available", bool(model.get("available", false)))
	_expect("country summary has a name", not String(model.get("country_name", "")).is_empty())
	_expect("country summary has territory", int(model.get("territory_count", 0)) > 0)
	var summary_values: Dictionary = panel.get("_summary_values")
	var territory_label := summary_values.get("territory") as Label
	var territory_id := territory_label.get_instance_id() if territory_label != null else 0
	ui.refresh_country_summary()
	_expect("daily summary refresh preserves nodes",
		territory_label != null and territory_label.get_instance_id() == territory_id)

	var layout := panel.layout_diagnostics()
	var dialog_rect: Rect2 = layout.get("dialog_rect", Rect2())
	var viewport_rect: Rect2 = layout.get("viewport_rect", root.get_visible_rect())
	_expect("country dialog stays in viewport", viewport_rect.encloses(dialog_rect))
	_expect("country dialog clears top bar", dialog_rect.position.y >= PlayerTopBar.BAR_HEIGHT)
	_expect("country dialog fills available viewport width",
		dialog_rect.size.x >= viewport_rect.size.x - UITokens.SPACE_SM * 2.0 - 1.0)
	_expect("country dialog fills available viewport height",
		dialog_rect.size.y >= viewport_rect.size.y - PlayerTopBar.BAR_HEIGHT \
			- CountryActionBar.BAR_HEIGHT - UITokens.SPACE_SM * 2.0 - 1.0)
	root.size = Vector2i(640, 480)
	await process_frame
	await process_frame
	var compact_layout := panel.layout_diagnostics()
	var compact_rect: Rect2 = compact_layout.get("dialog_rect", Rect2())
	var compact_viewport: Rect2 = compact_layout.get("viewport_rect", root.get_visible_rect())
	_expect("compact country dialog stays in viewport",
		compact_viewport.encloses(compact_rect))
	_expect("compact country dialog fills available viewport width",
		compact_rect.size.x >= compact_viewport.size.x - UITokens.SPACE_SM * 2.0 - 1.0)
	_expect("compact country dialog fills available viewport height",
		compact_rect.size.y >= compact_viewport.size.y - PlayerTopBar.BAR_HEIGHT \
			- CountryActionBar.BAR_HEIGHT - UITokens.SPACE_SM * 2.0 - 1.0)
	_expect("compact summary uses two columns",
		(panel.get("_summary_grid") as GridContainer).columns == 2)
	_expect("compact tabs wrap to three columns",
		(panel.get("_tabs_grid") as GridContainer).columns == 3)
	root.size = Vector2i(1280, 720)
	await process_frame
	await process_frame
	_expect("Lucide country icon is registered",
		IconBadge.texture_for_key("technology", IconBadge.FAMILY_LUCIDE) != null)
	_expect("Tabler summary icon is registered",
		IconBadge.texture_for_key("territory", IconBadge.FAMILY_TABLER) != null)

	var unavailable := CountryViewModel.new().build()
	_expect("missing country context returns recoverable unavailable state",
		not bool(unavailable.get("available", true)) and not String(unavailable.get("reason", "")).is_empty())
	var capture_path := OS.get_environment("PK_COUNTRY_UI_CAPTURE_PATH")
	if not capture_path.is_empty():
		await process_frame
		await process_frame
		var image := root.get_texture().get_image()
		_expect("country UI capture is nonblank", image != null and not image.is_empty())
		if image != null and not image.is_empty():
			_expect("country UI capture saves", image.save_png(capture_path) == OK)

	var escape := InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.pressed = true
	game._unhandled_key_input(escape)
	await create_timer(UITokens.ANIM_FAST + 0.05).timeout
	_expect("Escape closes country panel", not panel.is_panel_open())
	_expect("Escape close preserves pause state", clock.paused == paused_before)
	_finish()


func _expect(label: String, condition: bool) -> void:
	if condition:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		push_error("  [FAIL] %s" % label)


func _finish() -> void:
	print("=== player country UI smoke: %d failures ===" % _failures)
	quit(0 if _failures == 0 else 1)
