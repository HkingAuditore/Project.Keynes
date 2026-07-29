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
	_expect("economy replaces taxation in country actions",
		buttons.has("economy") and not buttons.has("taxation"))
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
	for section_id in ["technology", "politics", "economy", "military", "diplomacy"]:
		var button := buttons.get(section_id) as Button
		_expect("%s action exists" % section_id, button != null)
		if button != null:
			button.pressed.emit()
			await process_frame
			_expect("%s panel opens" % section_id,
				panel.is_panel_open() and panel.current_section() == section_id)
	_expect("opening country affairs does not pause", clock.paused == paused_before)

	ui.open_country_section("economy")
	await process_frame
	var model: Dictionary = panel.get("_model")
	_expect("country summary is available", bool(model.get("available", false)))
	_expect("country summary has a name", not String(model.get("country_name", "")).is_empty())
	_expect("country summary has territory", int(model.get("territory_count", 0)) > 0)
	var treasury: Dictionary = model.get("treasury", {})
	_expect("economy summary exposes the native treasury",
		bool(treasury.get("available", false)) \
			and int(treasury.get("cash", -1)) == int(model.get("cash", -2)))
	var economy := panel.get("_economy_workspace") as Control
	_expect("economy workspace opens for the economy action",
		economy != null and economy.visible and panel.current_section() == "economy")
	_expect("economy workspace shows current treasury cash",
		economy != null and String(economy.call("cash_text")) \
			== String(treasury.get("cash_text", "")))
	_expect("economy workspace renders every nonzero treasury good",
		economy != null and int(economy.call("visible_good_count")) \
			== int(treasury.get("nonzero_good_count", -1)))

	var presented := CountryViewModel.present_treasury({
		"ok": true,
		"cash": 123456789,
		"good_ids": PackedStringArray(["grain"]),
		"quantities": PackedInt64Array([1250]),
	})
	var presented_goods: Array = presented.get("goods", [])
	var grain_profile = GoodProfileRegistry.profile_by_id("grain")
	_expect("treasury presentation localizes goods",
		presented_goods.size() == 1 and grain_profile != null \
			and String(presented_goods[0].get("display_name", "")) \
				== String(grain_profile.display_name))
	_expect("treasury presentation applies fixed-point scales",
		String(presented.get("cash_text", "")) == "1.23万" \
			and String(presented_goods[0].get("quantity_text", "")) == "1.25")
	var synthetic_model := {
		"available": true,
		"country_name": "测试国家",
		"treasury": presented,
	}
	economy.call("set_model", synthetic_model)
	var economy_id: int = economy.get_instance_id()
	var grain_row_id := int(economy.call("good_row_instance_id", "grain"))
	var updated_presented := CountryViewModel.present_treasury({
		"ok": true,
		"cash": 223456789,
		"good_ids": PackedStringArray(["grain"]),
		"quantities": PackedInt64Array([2500]),
	})
	synthetic_model["treasury"] = updated_presented
	economy.call("refresh_model", synthetic_model)
	_expect("daily economy refresh preserves workspace and treasury rows",
		economy.get_instance_id() == economy_id \
			and int(economy.call("good_row_instance_id", "grain")) == grain_row_id)
	_expect("daily economy refresh patches visible values",
		String(economy.call("cash_text")) == "2.23万" \
			and String(economy.call("good_value_text", "grain")) == "2.5")

	ui.open_country_section("technology")
	await process_frame
	var workspace := panel.get("_technology_workspace") as Control
	var tree: Control = workspace.tree_view() if workspace != null else null
	var tree_id := tree.get_instance_id() if tree != null else 0
	ui.refresh_country_summary()
	_expect("daily research refresh preserves the tree view",
		tree != null and tree.get_instance_id() == tree_id)
	_expect("technology tree draws itself instead of spawning nodes",
		tree != null and tree.get_child_count() == 0)

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
	ui.open_country_section("economy")
	await process_frame
	var goods_scroll := economy.get("_scroll") as ScrollContainer
	_expect("compact economy treasury uses a bounded vertical scroll",
		goods_scroll != null \
			and goods_scroll.horizontal_scroll_mode == ScrollContainer.SCROLL_MODE_DISABLED \
			and compact_rect.encloses(goods_scroll.get_global_rect()))
	_expect("compact layout narrows the research policy column",
		(panel.get("_technology_workspace") as Control).get("_policy_panel") \
			.custom_minimum_size.x == TechnologyWorkspace.POLICY_WIDTH_COMPACT)
	root.size = Vector2i(1280, 720)
	await process_frame
	await process_frame
	_expect("Lucide country icon is registered",
		IconBadge.texture_for_key("technology", IconBadge.FAMILY_LUCIDE) != null)
	_expect("economy country icon reuses the treasury asset",
		IconCatalog.texture_for_key(&"country.economy") != null)
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
