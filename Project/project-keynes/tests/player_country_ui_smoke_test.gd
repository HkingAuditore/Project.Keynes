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
	var bar := game.get_node_or_null("UI/UIRoot/HUDLayer/CountryActionBar") as CountryActionBar
	var panel := game.get_node_or_null("UI/UIRoot/PanelLayer/CountryPanel") as CountryPanel
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
	for section_id in ["technology", "economy"]:
		var button := buttons.get(section_id) as Button
		_expect("%s action exists" % section_id, button != null)
		if button != null:
			_expect("%s action enabled" % section_id, not button.disabled)
			button.pressed.emit()
			await process_frame
			_expect("%s panel opens" % section_id,
				panel.is_panel_open() and panel.current_section() == section_id)
	for section_id in ["politics", "military", "diplomacy"]:
		var button := buttons.get(section_id) as Button
		_expect("%s action exists" % section_id, button != null)
		_expect("%s action is disabled" % section_id,
			button != null and button.disabled and button.tooltip_text.contains("尚未开放"))
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
	economy.call("select_page_for_test", "income")
	var policy: Dictionary = model.get("tax_policy", {})
	var presentation: Dictionary = model.get("tax_presentation", {})
	var income_pres: Dictionary = presentation.get("income", {})
	var unlocked_professions: Array = income_pres.get("unlocked", [])
	var first_profession := String((unlocked_professions[0] as Dictionary).get("id", "")) \
		if not unlocked_professions.is_empty() else ""
	var first_tax_row_id := int(economy.call(
		"tax_row_instance_id", "income", first_profession))
	_expect("income tax page renders default and unlocked profession rows",
		bool(policy.get("ok", false)) and bool(presentation.get("ok", false)) and
		int(economy.call("tax_row_count", "income")) ==
			unlocked_professions.size() + 1 and first_tax_row_id != 0)
	_expect("income tax rows use localized profession names",
		not unlocked_professions.is_empty() and String(economy.call(
			"tax_row_name_text", "income", first_profession)) ==
			String((unlocked_professions[0] as Dictionary).get("display_name", "")))
	var default_rates: PackedInt32Array = policy.get(
		"default_rates", PackedInt32Array())
	var income_default := int(default_rates[0]) if not default_rates.is_empty() else 0
	var preview_default := 79 if income_default == 80 else 80
	economy.call("preview_default_rate_for_test", "income", "income", preview_default)
	_expect("default tax edits preview immediately on inherited rows",
		int(economy.call("tax_row_rate", "income", "__default__", "income")) ==
			preview_default and
		(first_profession.is_empty() or int(economy.call(
			"tax_row_rate", "income", first_profession, "income")) ==
				preview_default))
	economy.call("refresh_model", model)
	await create_timer(EconomyWorkspace.LIVE_REFRESH_INTERVAL_MSEC / 1000.0 + 0.05).timeout
	_expect("authoritative refresh does not snap back an active tax preview",
		first_profession.is_empty() or int(economy.call(
			"tax_row_rate", "income", first_profession, "income")) ==
				preview_default)
	economy.call("set_model", model)
	_expect("reopening tax workspace clears unconfirmed previews",
		int(economy.call("tax_row_rate", "income", "__default__", "income")) ==
			income_default and
		(first_profession.is_empty() or int(economy.call(
			"tax_row_rate", "income", first_profession, "income")) ==
				income_default))
	economy.call("preview_default_rate_for_test", "income", "income", preview_default)
	economy.call("confirm_default_rate_for_test", "income", "income")
	_expect("confirmed default tax keeps its optimistic next-day presentation",
		int(economy.call("pending_default_rate_for_test", "income")) ==
			preview_default and
		(first_profession.is_empty() or int(economy.call(
			"tax_row_rate", "income", first_profession, "income")) ==
				preview_default))
	economy.call("refresh_model", model)
	await create_timer(EconomyWorkspace.LIVE_REFRESH_INTERVAL_MSEC / 1000.0 + 0.05).timeout
	_expect("stale policy snapshots preserve the confirmed default tax",
		first_profession.is_empty() or int(economy.call(
			"tax_row_rate", "income", first_profession, "income")) ==
				preview_default)
	var unlocked_profession_ids := {}
	for item in unlocked_professions:
		unlocked_profession_ids[String((item as Dictionary).get("id", ""))] = true
	var locked_profession := ""
	for raw_id in policy.get("profession_ids", PackedStringArray()):
		if not unlocked_profession_ids.has(String(raw_id)):
			locked_profession = String(raw_id)
			break
	_expect("locked professions stay hidden from the income page",
		locked_profession == "" or int(economy.call(
			"tax_row_instance_id", "income", locked_profession)) == 0)
	economy.call("select_page_for_test", "tariff")
	var import_pres: Dictionary = presentation.get("import", {})
	_expect("tariff page is editable but marked pending foreign trade",
		int(economy.call("tax_row_count", "tariff")) ==
			(import_pres.get("unlocked", []) as Array).size() + 1 and
		not String(economy.call("tax_status_text")).is_empty())
	economy.call("select_page_for_test", "income")
	economy.call("refresh_model", model)
	_expect("daily tax refresh reuses cached row nodes",
		first_tax_row_id == 0 or int(economy.call(
			"tax_row_instance_id", "income", first_profession)) ==
			first_tax_row_id)
	economy.call("select_page_for_test", "treasury")

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
	# 合成财政快照期间暂停仿真日 tick：否则真实 country_committed 会把
	# 真实模型刷进工作区，覆盖合成快照，断言结果取决于时钟落点。
	var economy_race_paused := clock.paused
	clock.paused = true
	var live_summary := synthetic_model.duplicate(true)
	live_summary["current_day"] = 100
	live_summary["fiscal"] = {
		"collected": PackedInt64Array([10000, 0, 0, 0, 0]),
	}
	economy.call("set_model", live_summary)
	_expect("economy summary paints immediately when opened",
		String(economy.call("tax_text")) == "1")
	var burst_summary := live_summary.duplicate(true)
	burst_summary["current_day"] = 101
	burst_summary["fiscal"] = {
		"collected": PackedInt64Array([20000, 0, 0, 0, 0]),
	}
	economy.call("refresh_model", burst_summary)
	burst_summary = burst_summary.duplicate(true)
	burst_summary["current_day"] = 102
	burst_summary["fiscal"] = {
		"collected": PackedInt64Array([30000, 0, 0, 0, 0]),
	}
	economy.call("refresh_model", burst_summary)
	_expect("rapid economy ticks retain the stable rendered summary",
		String(economy.call("tax_text")) == "1")
	# 慢帧环境下（无头 + 原生仿真占帧）SceneTreeTimer 与 _process 的
	# 200ms 窗口对齐是竞态；改为轮询截止，语义不变：合并后的更新必须
	# 应用最新财政快照。
	var coalesce_deadline := Time.get_ticks_msec() + 2000
	while String(economy.call("tax_text")) != "3" \
			and Time.get_ticks_msec() < coalesce_deadline:
		await process_frame
	_expect("coalesced economy summary applies the newest fiscal snapshot",
		String(economy.call("tax_text")) == "3")
	clock.paused = economy_race_paused

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

	# ── 地块对象详情弹窗 ─────────────────────────────────────
	var right_panel := ui.get("_right_panel") as InspectorPanel
	var detail_dialog = ui.get("_object_detail_dialog")
	var inspector_vm := ui.get("_inspector_view_model") as CellInspectorViewModel
	var country_facade = ui.get("_country_facade")
	var selected_cell := ui.get("_selected_cell") as HexCell
	_expect("object detail dialog is wired into the UI",
		detail_dialog != null and right_panel != null and inspector_vm != null)
	_expect("player start cell stays selected for object details", selected_cell != null)
	var sample_profession_id := ""
	if detail_dialog != null and right_panel != null and inspector_vm != null \
			and selected_cell != null and country_facade != null:
		right_panel.select_tab("population")
		await process_frame
		var cohort_list = right_panel.get("_cohort_list")
		var cohort_rows: Dictionary = cohort_list.get("_row_refs") \
			if cohort_list != null else {}
		_expect("population tab builds cohort rows", not cohort_rows.is_empty())
		if not cohort_rows.is_empty():
			var cohort_row_id := String(cohort_rows.keys()[0])
			var cohort_refs := cohort_rows.values()[0] as Dictionary
			var chevron := cohort_refs.get("chevron") as Button
			_expect("cohort row exposes a dedicated expansion chevron", chevron != null)
			if chevron != null:
				chevron.button_pressed = true
				_expect("chevron expands the cohort row in place",
					cohort_list.is_expanded(cohort_row_id) and not detail_dialog.is_open())
				chevron.button_pressed = false
				_expect("chevron collapses the cohort row",
					not cohort_list.is_expanded(cohort_row_id))
			var cohort_payload := inspector_vm.build_object_detail(
				selected_cell, {"kind": "cohort", "row_id": cohort_row_id})
			sample_profession_id = String(cohort_payload.get("item_id", ""))
			_expect("cohort detail payload carries all required keys",
				cohort_payload.has("row") and cohort_payload.has("tax") \
					and cohort_payload.has("subtitle") \
					and cohort_payload.has("country_facade") \
					and not sample_profession_id.is_empty())
			var stale_payload := inspector_vm.build_object_detail(
				selected_cell, {"kind": "cohort", "row_id": "cohort_stale_handle",
					"profession_id": sample_profession_id})
			_expect("stale cohort handles fall back to the same profession row",
				String((stale_payload.get("row", {}) as Dictionary) \
					.get("profession_id", "")) == sample_profession_id)
			_expect("cohort row carries its stable profession id",
				not String((cohort_payload.get("row", {}) as Dictionary) \
					.get("profession_id", "")).is_empty())
			(cohort_refs.get("button") as Button).pressed.emit()
			await process_frame
			_expect("cohort row click opens the object detail dialog",
				detail_dialog.is_open())
			_expect("cohort dialog header names the object and cell",
				not detail_dialog.title_text().is_empty() \
					and detail_dialog.subtitle_text().contains("阶层") \
					and detail_dialog.subtitle_text().contains("区域"))
			var cohort_row_data := (cohort_list.get("_row_data") as Dictionary) \
				.get(cohort_row_id, {}) as Dictionary
			_expect("cohort dialog title shows the localized profession name",
				detail_dialog.title_text() == String(cohort_row_data.get("name", "")))
			_expect("cohort name falls back to the localized profession name",
				String(inspector_vm._object_display_name("cohort",
					{"profession_id": sample_profession_id}, int(selected_cell.index)))
					== String(cohort_row_data.get("name", "")))
			var cohort_grid_columns := detail_dialog.fact_grid_columns() as Array[int]
			_expect("cohort dialog balances eight facts as a 4x2 grid",
				cohort_grid_columns.size() == 1 and cohort_grid_columns[0] == 4)
			_expect("cohort dialog shows one editable income tax lane",
				detail_dialog.tax_lane_count() == 1 and detail_dialog.tax_lane_editable())
			if detail_dialog.is_open() and detail_dialog.tax_lane_count() == 1:
				var income_data := ((detail_dialog.get("_lanes") as Dictionary) \
					.get("income", {}) as Dictionary).get("data", {}) as Dictionary
				_expect("income lane binds the cohort profession id",
					String(income_data.get("item_id", "")) == sample_profession_id)
				var current_day := int(detail_dialog.get("_current_day"))
				var base_rate := int(detail_dialog.tax_lane_rate("income"))
				var new_rate := base_rate + 1 if base_rate < 100 else base_rate - 1
				detail_dialog.set_lane_rate_for_test("income", new_rate)
				detail_dialog.confirm_lane_for_test("income")
				var pending_map: Dictionary = detail_dialog.get("_pending")
				var pending_entry := pending_map.get("income", {}) as Dictionary
				_expect("income tax override enters pending for the next day",
					pending_map.size() == 1 \
						and int(pending_entry.get("effective_day", -1)) == current_day + 1)
				_expect("income tax override reaches the native command queue",
					bool(detail_dialog.last_command_ok()) \
						and int(detail_dialog.last_command_pending()) >= 1)
				var queued_after_override := int(detail_dialog.last_command_pending())
				detail_dialog.reset_lane_for_test("income")
				_expect("lane reset queues a clear-override command for the next day",
					bool(detail_dialog.last_command_ok()) \
						and int(detail_dialog.last_command_pending()) \
							== queued_after_override + 1 \
						and detail_dialog.status_text().contains("生效"))
			detail_dialog.close_dialog()
			_expect("cohort dialog closes", not detail_dialog.is_open())

		right_panel.select_tab("buildings")
		await process_frame
		var building_list = right_panel.get("_building_list")
		var building_rows: Dictionary = building_list.get("_row_refs") \
			if building_list != null else {}
		_expect("buildings tab builds building rows", not building_rows.is_empty())
		if not building_rows.is_empty():
			((building_rows.values()[0] as Dictionary).get("button") as Button) \
				.pressed.emit()
			await process_frame
			var business_data := ((detail_dialog.get("_lanes") as Dictionary) \
				.get("business", {}) as Dictionary).get("data", {}) as Dictionary
			_expect("building row click opens a dialog with an editable business lane",
				detail_dialog.is_open() and detail_dialog.tax_lane_count() == 1 \
					and detail_dialog.tax_lane_editable() \
					and not String(business_data.get("item_id", "")).is_empty())
			detail_dialog.close_dialog()

		right_panel.select_tab("market")
		await process_frame
		var market_list = right_panel.get("_market_list")
		var market_rows: Dictionary = market_list.get("_row_refs") \
			if market_list != null else {}
		_expect("market tab builds good rows", not market_rows.is_empty())
		if not market_rows.is_empty():
			((market_rows.values()[0] as Dictionary).get("button") as Button) \
				.pressed.emit()
			await process_frame
			_expect("good row click opens a dialog with consumption and tariff lanes",
				detail_dialog.is_open() and detail_dialog.tax_lane_count() == 3 \
					and detail_dialog.tax_lane_editable())
			var import_data := ((detail_dialog.get("_lanes") as Dictionary) \
				.get("import", {}) as Dictionary).get("data", {}) as Dictionary
			_expect("tariff lanes are marked pending foreign trade",
				String(import_data.get("placeholder_note", "")).contains("待跨国贸易接入"))
			detail_dialog.close_dialog()

		right_panel.select_tab("geography")
		await process_frame
		var resource_list = right_panel.get("_resource_list")
		var resource_rows: Dictionary = resource_list.get("_row_refs") \
			if resource_list != null else {}
		var visible_resource: Dictionary = {}
		for refs_value in resource_rows.values():
			var refs := refs_value as Dictionary
			if (refs.get("panel") as Control).visible:
				visible_resource = refs
				break
		if visible_resource.is_empty():
			print("  [SKIP] no visible natural resource rows on the player start cell")
		else:
			(visible_resource.get("button") as Button).pressed.emit()
			await process_frame
			_expect("resource row click opens a detail-only dialog without tax lanes",
				detail_dialog.is_open() and detail_dialog.tax_lane_count() == 0 \
					and not detail_dialog.title_text().is_empty())
			var resource_grid_columns := detail_dialog.fact_grid_columns() as Array[int]
			_expect("resource dialog lays four facts as a 2x2 grid",
				resource_grid_columns.size() == 1 and resource_grid_columns[0] == 2)
			detail_dialog.close_dialog()

		var cell_idx := int(selected_cell.index)
		var map := ui.get("_map") as MapData
		var unowned_idx := -1
		if map != null:
			for i in range(map.cell_count()):
				var summary: Dictionary = country_facade.cell_summary(i)
				if not bool(summary.get("ok", false)) \
						or not bool(summary.get("owned", false)):
					unowned_idx = i
					break
		_expect("world has unowned cells for tax gating", unowned_idx >= 0)
		if unowned_idx >= 0 and not sample_profession_id.is_empty():
			var unowned_slice := inspector_vm.tax_slice_for_object(
				unowned_idx, "cohort", sample_profession_id)
			_expect("unowned cells hide the tax section",
				not bool(unowned_slice.get("available", true)))
			var owned_slice := inspector_vm.tax_slice_for_object(
				cell_idx, "cohort", sample_profession_id)
			_expect("player cell tax slice is available and editable",
				bool(owned_slice.get("available", false)) \
					and bool(owned_slice.get("editable", false)))
			var player_handle := int(inspector_vm._player_country_handle())
			_expect("player handle matches the start cell owner",
				player_handle >= 0 \
					and player_handle == int(owned_slice.get("country_handle", -2)))
	right_panel.select_tab("geography")
	await process_frame

	# 50x soak: daily refreshes may patch values, but the player-facing controls,
	# keyed rows and navigation state must survive at least 30 committed days.
	ui.open_country_section("economy")
	await process_frame
	var inspector_id := right_panel.get_instance_id()
	var inspector_scroll := right_panel.get("_scroll") as ScrollContainer
	var inspector_scroll_id := inspector_scroll.get_instance_id()
	inspector_scroll.scroll_vertical = mini(48, int(inspector_scroll.get_v_scroll_bar().max_value))
	var inspector_scroll_before := inspector_scroll.scroll_vertical
	var economy_workspace_id := economy.get_instance_id()
	var economy_scroll := economy.get("_scroll") as ScrollContainer
	var economy_scroll_id := economy_scroll.get_instance_id()
	economy_scroll.scroll_vertical = mini(32, int(economy_scroll.get_v_scroll_bar().max_value))
	var economy_scroll_before := economy_scroll.scroll_vertical
	var soak_tax_row_id := int(economy.call(
		"tax_row_instance_id", "income", first_profession))
	var speed_before := clock.speed_multiplier
	var soak_start_day := clock.day_index()
	clock.pause(false)
	clock.set_speed(50.0)
	var soak_deadline := Time.get_ticks_msec() + 30000
	while clock.day_index() < soak_start_day + 30 \
			and Time.get_ticks_msec() < soak_deadline:
		await process_frame
	clock.set_speed(speed_before)
	_expect("50x soak advances at least 30 simulation days",
		clock.day_index() >= soak_start_day + 30)
	_expect("50x soak preserves Inspector and scroll node identities",
		right_panel.get_instance_id() == inspector_id \
			and inspector_scroll.get_instance_id() == inspector_scroll_id)
	_expect("50x soak preserves Inspector tab and scroll position",
		right_panel.current_tab() == "geography" \
			and inspector_scroll.scroll_vertical == inspector_scroll_before)
	_expect("50x soak preserves economy workspace and scroll identity",
		economy.get_instance_id() == economy_workspace_id \
			and economy_scroll.get_instance_id() == economy_scroll_id \
			and economy_scroll.scroll_vertical == economy_scroll_before)
	_expect("50x soak reuses stable economy tax rows",
		soak_tax_row_id != 0 and int(economy.call(
			"tax_row_instance_id", "income", first_profession)) == soak_tax_row_id)
	_expect("50x soak preserves the technology tree node",
		tree != null and tree.get_instance_id() == tree_id and tree.get_child_count() == 0)
	_expect("50x soak leaves core country actions clickable",
		not (buttons.get("technology") as Button).disabled \
			and not (buttons.get("economy") as Button).disabled)

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
