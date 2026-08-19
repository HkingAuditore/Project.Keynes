extends SceneTree


class FakePlayerController extends Node:
	var succeed := false
	var calls: Array[Dictionary] = []

	func request_command(id: StringName, args: Dictionary = {}) -> Dictionary:
		calls.append({"id": id, "args": args.duplicate(true)})
		return {"ok": succeed, "reason": "rejected for test",
			"effective_day": 11}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var failures := PackedStringArray()
	var root := Control.new()
	root.theme = load("res://assets/themes/player_ui_theme.tres") as Theme
	get_root().add_child(root)
	var inspector := (load("res://scenes/ui/inspector_panel.tscn") as PackedScene) \
		.instantiate() as InspectorPanel
	root.add_child(inspector)
	var controller := FakePlayerController.new()
	root.add_child(controller)
	inspector.set_player_controller(controller)
	var detail_requests := 0
	inspector.object_details_requested.connect(func(_request: Dictionary) -> void:
		detail_requests += 1)
	inspector.set_model_for_selection(_model(5))
	inspector.select_tab("population")

	var cohort_list = inspector.get("_cohort_list")
	inspector.show_object_detail({
		"kind": "cohort", "name": "工匠", "row": {
			"tax_lanes": [_model(5).categories.population.cohort_rows[0].tax_lanes[0]],
		}, "tax_context": _model(5).categories.population.tax_context,
	})
	if inspector._object_detail_dialog.tax_editors().size() != 1:
		failures.append("cohort detail showed two income tax layers")
	if (inspector.get("_page_tax_editors") as Array).size() != 1:
		failures.append("population page did not expose the cell income default")
	var cohort_page_tax := inspector.get("_page_tax_section") as Control
	if cohort_page_tax != null and cohort_page_tax.visible:
		failures.append("cohort detail left the page income default visible")
	var row_editor := (inspector._object_detail_dialog.tax_editors()[0] \
		as TaxLaneEditor)
	# Live detail refreshes must not replace a tax editor while its LineEdit owns focus.
	var editor_instance_id := row_editor.get_instance_id()
	var refreshed_payload := {
		"kind": "cohort", "name": "工匠（刷新）", "row": {
			"tax_lanes": [_model(5).categories.population.cohort_rows[0].tax_lanes[0]],
		}, "tax_context": _model(5).categories.population.tax_context,
	}
	row_editor._spin.get_line_edit().grab_focus()
	inspector.refresh_object_detail(refreshed_payload)
	await process_frame
	if (inspector._object_detail_dialog.tax_editors()[0] as TaxLaneEditor).get_instance_id() \
			!= editor_instance_id \
			or inspector._object_detail_dialog.title_text() != "工匠":
		failures.append("live detail refresh replaced a focused tax editor")
	row_editor._spin.get_line_edit().release_focus()
	await process_frame
	await process_frame
	if inspector._object_detail_dialog.title_text() != "工匠（刷新）":
		failures.append("deferred detail refresh did not apply after tax edit ended")
	row_editor = (inspector._object_detail_dialog.tax_editors()[0] as TaxLaneEditor)
	var base_rate := int(row_editor.lane_data().get("base", -1))
	row_editor._spin.set_value_no_signal(base_rate + 3)
	row_editor._on_text_submitted("")
	if row_editor._spin.value != base_rate \
			or not (inspector.get("_pending_tax") as Dictionary).is_empty():
		failures.append("failed override did not restore the authoritative row rate")
	if detail_requests != 0 or not inspector.detail_open():
		failures.append("tax editor input did not remain in the left detail workspace")

	controller.succeed = true
	row_editor._spin.set_value_no_signal(base_rate + 4)
	row_editor._on_text_submitted("")
	var row_key := "cell:5/income/artisan"
	var pending := inspector.get("_pending_tax") as Dictionary
	if not pending.has(row_key) or not row_editor.is_pending() \
			or StringName(controller.calls[-1].id) != &"country.tax.cell.set_override":
		failures.append("successful row override did not enter stable-key pending")
	inspector.select_tab("geography")
	await process_frame
	inspector.select_tab("population")
	await process_frame
	inspector.show_object_detail({
		"kind": "cohort", "name": "工匠", "row": {
			"tax_lanes": [_model(5).categories.population.cohort_rows[0].tax_lanes[0]],
		}, "tax_context": _model(5).categories.population.tax_context,
	})
	row_editor = (inspector._object_detail_dialog.tax_editors()[0] \
		as TaxLaneEditor)
	if inspector._object_detail_dialog.tax_editors().size() != 1:
		failures.append("tab round-trip restored two income tax layers in cohort detail")
	if not row_editor.is_pending() or int(row_editor._spin.value) != base_rate + 4:
		failures.append("tab round-trip lost the pending row rate or marker")

	pending.clear()
	row_editor.resolve_pending()
	inspector._on_tax_reset_requested("item", "income", "artisan")
	if not pending.has(row_key) \
			or StringName(controller.calls[-1].id) != &"country.tax.cell.clear_override":
		failures.append("row reset did not queue clear_override")

	pending.clear()
	row_editor.resolve_pending()
	var page_editors: Array = inspector.get("_page_tax_editors")
	if page_editors.is_empty():
		failures.append("page default editor was not rebuilt after tab round-trip")
	var default_editor := page_editors[0] as TaxLaneEditor \
		if not page_editors.is_empty() else null
	if default_editor == null:
		failures.append("page default edit did not queue set_default")
	else:
		inspector._on_tax_override_requested("default", "income", "", 17)
		var default_key := "cell:5/income/default"
		if not pending.has(default_key) or not default_editor.is_pending() \
				or StringName(controller.calls[-1].id) != &"country.tax.cell.set_default":
			failures.append("page default edit did not queue set_default")

		pending.clear()
		default_editor.resolve_pending()
		inspector._on_tax_reset_requested("default", "income", "")
		if not pending.has(default_key) \
				or StringName(controller.calls[-1].id) != &"country.tax.cell.clear_default":
			failures.append("page default reset did not queue clear_default")

		pending.clear()
		default_editor.resolve_pending()
		inspector._on_clear_all_tax_confirmed()
	var clear_key := "cell:5/all"
	if not pending.has(clear_key) \
			or StringName(controller.calls[-1].id) != &"country.tax.cell.clear_all":
		failures.append("confirmed clear-all did not queue the existing clear_all command")
	var clear_ctx: Dictionary = (_model(5).categories.population.tax_context as Dictionary) \
		.duplicate(true)
	clear_ctx["current_day"] = 11
	clear_ctx["policy_version"] = 8
	inspector._resolve_tax_pending(clear_ctx)
	if pending.has(clear_key):
		failures.append("policy version advance did not resolve clear-all pending")

	inspector.close_detail()
	inspector.set_model_for_selection(_building_model(5))
	inspector.select_tab("buildings")
	var building_model := _building_model(5)
	var building_page_editors: Array = inspector.get("_page_tax_editors")
	if building_page_editors.is_empty():
		failures.append("buildings page did not expose the cell business default")
	else:
		var page_editor := building_page_editors[0] as TaxLaneEditor
		var page_base := int(page_editor.lane_data().get("base", 0))
		var page_draft := page_base + 6 if page_base <= 94 else page_base - 6
		page_editor._spin.set_value_no_signal(page_draft)
		page_editor._on_value_changed(page_draft)
		inspector.apply_live_patch({
			"tab_id": "buildings",
			"category": building_model.categories.buildings,
		})
		await process_frame
		if int(page_editor._spin.value) != page_draft or not page_editor.is_editing():
			failures.append("live patch snapped the cell business default back to inherit")
		var page_wait := Time.get_ticks_msec()
		while Time.get_ticks_msec() - page_wait < int(
				(TaxLaneEditor.COMMIT_DELAY_SEC + 0.08) * 1000.0):
			await process_frame
		page_editor = (inspector.get("_page_tax_editors") as Array)[0] as TaxLaneEditor \
			if not (inspector.get("_page_tax_editors") as Array).is_empty() else null
		if page_editor == null \
				or StringName(controller.calls[-1].id) != &"country.tax.cell.set_default" \
				or int(controller.calls[-1].args.get("rate_percent", -1)) != page_draft \
				or not page_editor.is_pending():
			failures.append("cell business default spin edit did not commit after arrow input")
		else:
			var stale_category: Dictionary = (building_model.categories.buildings \
				as Dictionary).duplicate(true)
			var stale_context: Dictionary = (stale_category.get("tax_context", {}) \
				as Dictionary).duplicate(true)
			stale_context["current_day"] = 11
			stale_context["policy_version"] = 8
			stale_category["tax_context"] = stale_context
			inspector.apply_live_patch({
				"tab_id": "buildings",
				"category": stale_category,
			})
			page_editor = (inspector.get("_page_tax_editors") as Array)[0] as TaxLaneEditor \
				if not (inspector.get("_page_tax_editors") as Array).is_empty() else null
			if page_editor == null or not page_editor.is_pending() \
					or int(page_editor._spin.value) != page_draft:
				failures.append("next-day live patch with unchanged inherit snapshot snapped pending cell business tax")
			else:
				var committed_lane: Dictionary = ((stale_context.get(
					"default_lanes", []) as Array)[0] as Dictionary).duplicate(true)
				committed_lane["base"] = page_draft
				committed_lane["effective"] = page_draft
				committed_lane["has_override"] = true
				var committed_context := stale_context.duplicate(true)
				committed_context["default_lanes"] = [committed_lane]
				var committed_category := stale_category.duplicate(true)
				committed_category["tax_context"] = committed_context
				inspector.apply_live_patch({
					"tab_id": "buildings",
					"category": committed_category,
				})
				page_editor = (inspector.get("_page_tax_editors") as Array)[0] \
					as TaxLaneEditor if not (inspector.get("_page_tax_editors") \
					as Array).is_empty() else null
				if page_editor == null or page_editor.is_pending() \
						or int(page_editor._spin.value) != page_draft:
					failures.append("matching snapshot did not resolve pending cell business tax")
		page_editor = (inspector.get("_page_tax_editors") as Array)[0] as TaxLaneEditor \
			if not (inspector.get("_page_tax_editors") as Array).is_empty() else null
		if page_editor != null:
			page_editor.resolve_pending()
			(inspector.get("_pending_tax") as Dictionary).clear()
			var typed_rate := 22
			page_editor._spin.set_value_no_signal(page_base)
			page_editor._on_text_submitted(str(typed_rate))
			if StringName(controller.calls[-1].id) != &"country.tax.cell.set_default" \
					or int(controller.calls[-1].args.get("rate_percent", -1)) != typed_rate \
					or int(page_editor._spin.value) != typed_rate:
				failures.append("Enter submitted the stale SpinBox value instead of typed text")
	var building_row: Dictionary = building_model.categories.buildings.building_rows[0]
	var building_defaults: Array = (building_model.categories.buildings.tax_context \
		as Dictionary).get("default_lanes", []) as Array
	var mixed_building_lanes: Array = []
	var building_item_lanes: Array = building_row.get("tax_lanes", [])
	if not building_item_lanes.is_empty():
		mixed_building_lanes.append(building_item_lanes[0])
	if not building_defaults.is_empty():
		mixed_building_lanes.append(building_defaults[0])
	var building_payload := {
		"kind": "building", "name": "铁匠铺",
		"row": {"tax_lanes": mixed_building_lanes},
		"tax_context": building_model.categories.buildings.tax_context,
	}
	inspector.show_object_detail(building_payload)
	if inspector._object_detail_dialog.tax_editors().is_empty():
		failures.append("building detail did not expose a business tax editor")
	else:
		var biz_editor := inspector._object_detail_dialog.tax_editors()[0] \
			as TaxLaneEditor
		var biz_id := biz_editor.get_instance_id()
		var biz_base := int(biz_editor.lane_data().get("base", 0))
		var biz_draft := biz_base + 7 if biz_base <= 93 else biz_base - 7
		biz_editor._spin.set_value_no_signal(biz_draft)
		biz_editor._on_value_changed(biz_draft)
		inspector.refresh_object_detail(building_payload)
		await process_frame
		biz_editor = inspector._object_detail_dialog.tax_editors()[0] as TaxLaneEditor
		if biz_editor.get_instance_id() != biz_id \
				or int(biz_editor._spin.value) != biz_draft:
			failures.append("live detail refresh snapped building business tax back to inherit")
		var biz_wait := Time.get_ticks_msec()
		while Time.get_ticks_msec() - biz_wait < int(
				(TaxLaneEditor.COMMIT_DELAY_SEC + 0.08) * 1000.0):
			await process_frame
		var biz_editors: Array = inspector._object_detail_dialog.tax_editors()
		biz_editor = biz_editors[0] as TaxLaneEditor if not biz_editors.is_empty() else null
		if biz_editor == null \
				or StringName(controller.calls[-1].id) != &"country.tax.cell.set_override" \
				or int(controller.calls[-1].args.get("rate_percent", -1)) != biz_draft \
				or not biz_editor.is_pending():
			failures.append("building business tax spin edit did not commit after arrow input")
	_assert_object_tax_layer(failures, inspector, 1, "building", "business")

	inspector.close_detail()
	inspector.set_model_for_selection(_market_model(5))
	inspector.select_tab("market")
	var market_page_editors: Array = inspector.get("_page_tax_editors")
	if market_page_editors.is_empty():
		failures.append("market page did not expose cell consumption/tariff defaults")
	else:
		var consumption_editor: TaxLaneEditor = null
		for editor_value in market_page_editors:
			var editor := editor_value as TaxLaneEditor
			if editor != null and String(editor.lane_data().get("kind", "")) == "consumption":
				consumption_editor = editor
				break
		if consumption_editor == null:
			failures.append("market page did not expose the cell consumption default")
		else:
			var market_base := int(consumption_editor.lane_data().get("base", 0))
			var market_draft := market_base + 5 if market_base <= 95 else market_base - 5
			consumption_editor._spin.set_value_no_signal(market_draft)
			consumption_editor._on_value_changed(market_draft)
			inspector.apply_live_patch({
				"tab_id": "market",
				"category": _market_model(5).categories.market,
			})
			await process_frame
			if int(consumption_editor._spin.value) != market_draft \
					or not consumption_editor.is_editing():
				failures.append("live patch snapped the cell consumption default back to inherit")
	var market_row: Dictionary = _market_model(5).categories.market.market_rows[0]
	var market_defaults: Array = (_market_model(5).categories.market.tax_context \
		as Dictionary).get("default_lanes", []) as Array
	var mixed_good_lanes: Array = []
	for lane_value in market_defaults:
		mixed_good_lanes.append(lane_value)
	for lane_value in market_row.get("tax_lanes", []):
		mixed_good_lanes.append(lane_value)
	inspector.show_object_detail({
		"kind": "good", "name": "谷物", "row": {"tax_lanes": mixed_good_lanes},
		"tax_context": _market_model(5).categories.market.tax_context,
	})
	_assert_object_tax_layer(failures, inspector, 3, "good", "")

	inspector.close_detail()
	inspector._mark_tax_pending(row_key, base_rate + 1)
	inspector.set_model_for_selection(_model(6))
	if not (inspector.get("_pending_tax") as Dictionary).is_empty():
		failures.append("new cell selection retained stale Inspector pending state")

	if failures.is_empty():
		print("[inspector-tax-interaction] PASS")
		quit(0)
	else:
		for failure in failures:
			push_error("[inspector-tax-interaction] FAIL: %s" % failure)
		quit(1)


func _model(cell_idx: int) -> Dictionary:
	var lane := {
		"scope": "item", "kind": "income", "kind_label": "所得税",
		"item_id": "artisan", "base": 10, "effective": 10,
		"default_rate": 8, "has_override": true, "editable": true,
	}
	var default_lane := lane.duplicate(true)
	default_lane["scope"] = "default"
	default_lane["item_id"] = ""
	default_lane["kind_label"] = "此地所得税"
	default_lane["default_rate"] = 8
	default_lane["has_override"] = false
	default_lane["base"] = 8
	default_lane["effective"] = 8
	return {
		"cell_index": cell_idx,
		"header": {"title": "测试地块", "subtitle": "区域 1, 1"},
		"score": {},
		"summary_cards": [],
		"tabs": [
			{"id": "geography", "label": "地理", "icon": "geo"},
			{"id": "population", "label": "人口", "icon": "growth"},
		],
		"categories": {
			"geography": {},
			"population": {
				"tax_context": {
					"available": true, "editable": true, "cell": cell_idx,
					"current_day": 10, "policy_version": 7,
					"default_lanes": [default_lane],
				},
				"cohort_rows": [{
					"id": "cohort_1", "profession_id": "artisan",
					"name": "工匠", "population": "100", "tax_lanes": [lane],
				}],
			},
		},
	}


func _building_model(cell_idx: int) -> Dictionary:
	var lane := {
		"scope": "item", "kind": "business", "kind_label": "营业税",
		"item_id": "forge", "base": 12, "effective": 12,
		"default_rate": 4, "has_override": true, "editable": true,
	}
	var default_lane := lane.duplicate(true)
	default_lane["scope"] = "default"
	default_lane["item_id"] = ""
	default_lane["kind_label"] = "此地营业税"
	default_lane["has_override"] = false
	default_lane["base"] = 4
	default_lane["effective"] = 4
	return {
		"cell_index": cell_idx,
		"header": {"title": "测试地块", "subtitle": "区域 1, 1"},
		"score": {},
		"summary_cards": [],
		"tabs": [
			{"id": "geography", "label": "地理", "icon": "geo"},
			{"id": "buildings", "label": "建筑", "icon": "building"},
		],
		"categories": {
			"geography": {},
			"buildings": {
				"tax_context": {
					"available": true, "editable": true, "cell": cell_idx,
					"current_day": 10, "policy_version": 7,
					"default_lanes": [default_lane],
				},
				"building_rows": [{
					"id": "building_1", "building_type_id": "forge",
					"name": "铁匠铺", "tax_lanes": [lane],
				}],
			},
		},
	}


func _market_model(cell_idx: int) -> Dictionary:
	var item_lanes: Array = []
	var default_lanes: Array = []
	var label_pairs := {
		"consumption": ["消费税", "此地消费税"],
		"import": ["进口关税", "此地进口税"],
		"export": ["出口关税", "此地出口税"],
	}
	for kind in ["consumption", "import", "export"]:
		var pair: Array = label_pairs[kind]
		item_lanes.append({
			"scope": "item", "kind": kind, "kind_label": pair[0],
			"item_id": "grain", "base": 6, "effective": 6,
			"default_rate": 2, "has_override": true, "editable": true,
		})
		default_lanes.append({
			"scope": "default", "kind": kind, "kind_label": pair[1],
			"item_id": "", "base": 2, "effective": 2,
			"default_rate": 2, "has_override": false, "editable": true,
		})
	return {
		"cell_index": cell_idx,
		"header": {"title": "测试地块", "subtitle": "区域 1, 1"},
		"score": {},
		"summary_cards": [],
		"tabs": [
			{"id": "geography", "label": "地理", "icon": "geo"},
			{"id": "market", "label": "市场", "icon": "resource"},
		],
		"categories": {
			"geography": {},
			"market": {
				"tax_context": {
					"available": true, "editable": true, "cell": cell_idx,
					"current_day": 10, "policy_version": 7,
					"default_lanes": default_lanes,
				},
				"market_rows": [{
					"id": "market_1", "good_id": "grain",
					"name": "谷物", "tax_lanes": item_lanes,
				}],
			},
		},
	}


func _assert_object_tax_layer(
		failures: PackedStringArray,
		inspector: InspectorPanel,
		expected_count: int,
		object_kind: String,
		expected_kind: String
) -> void:
	var editors: Array = inspector._object_detail_dialog.tax_editors()
	if editors.size() != expected_count:
		failures.append("%s detail showed %d tax layers instead of %d" % [
			object_kind, editors.size(), expected_count])
	for editor_value in editors:
		var data := (editor_value as TaxLaneEditor).lane_data()
		if String(data.get("scope", "")) == "default":
			failures.append("%s detail kept the cell default tax layer" % object_kind)
		if not expected_kind.is_empty() \
				and String(data.get("kind", "")) != expected_kind:
			failures.append("%s detail bound the wrong tax kind" % object_kind)
	var page_section := inspector.get("_page_tax_section") as Control
	if page_section != null and page_section.visible:
		failures.append("%s detail left the page default tax visible" % object_kind)
	inspector.close_detail()
	page_section = inspector.get("_page_tax_section") as Control
	if page_section != null and not page_section.visible:
		failures.append("closing %s detail did not restore the page default tax" % object_kind)
