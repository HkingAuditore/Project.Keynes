extends SceneTree

const TaxMergeTest := preload("res://tests/ui/inspector_tax_merge_test.gd")
const EconomyCatalogScript := preload("res://scripts/economy/economy_catalog.gd")
const EconomyFacadeDisplayScript := preload(
	"res://scripts/economy/economy_facade_display.gd")
const TaxGroupMapScript := preload("res://scripts/country/tax_group_map.gd")

class FakePlayerController extends Node:
	var succeed := false
	var calls: Array[Dictionary] = []

	func request_command(id: StringName, args: Dictionary = {}) -> Dictionary:
		calls.append({"id": id, "args": args.duplicate(true)})
		return {"ok": succeed, "reason": "rejected for test",
			"effective_day": 11}


## 整组断言的三个假件：真目录列 + 一份税快照 + 记录命令。
class FakeTaxGroupEconomy extends RefCounted:
	var columns: Dictionary = {}

	func construction_type_columns() -> Dictionary:
		return columns


class FakeTaxGroupCountry extends RefCounted:
	var building_ids := PackedStringArray()
	var good_ids := PackedStringArray()
	var profession_ids := PackedStringArray()

	func cell_summary(_cell: int) -> Dictionary:
		return {"ok": true, "owned": true, "country_handle": 7}

	## 形状照原生 country_runtime_queries.cpp:674-676：三份 id 都在顶层，
	## income/business/consumption 里只有 rates/has_override 那些列。
	func tax_policy_snapshot(_handle: int) -> Dictionary:
		return {"ok": true, "country_handle": 7,
			"profession_ids": profession_ids,
			"good_ids": good_ids,
			"building_type_ids": building_ids}


class FakeTaxGroupController extends Node:
	var calls: Array[Dictionary] = []
	var economy = null
	var country = null

	func request_command(id: StringName, args: Dictionary = {}) -> Dictionary:
		calls.append({"id": id, "args": args.duplicate(true)})
		return {"ok": true, "effective_day": 12, "sequence": calls.size()}

	func get_economy_facade():
		return economy

	func get_country_facade():
		return country


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var failures := PackedStringArray()
	get_root().size = Vector2i(1280, 720)
	get_root().gui_embed_subwindows = true
	var view_model := CellInspectorViewModel.new()
	var generator := TaxMergeTest.FakeGenerator.new()
	view_model.set_context(null, generator, null, null, 0.42, 22.0)
	for spec in [["population", ["income"], 2],
			["market", ["consumption", "import", "export"], 4],
			["buildings", ["business"], 2]]:
		var category := view_model._decorate_category_with_tax(0, spec[0], {})
		var targets: Array = category.tax_context.get("reset_targets", [])
		if targets.size() != spec[2]:
			failures.append("%s reset omitted overrides absent from the visible list" % spec[0])
		for target in targets:
			if String(target.kind) not in spec[1]:
				failures.append("%s reset included another category's tax kind" % spec[0])
	var root := Control.new()
	root.theme = load("res://assets/themes/player_ui_theme.tres") as Theme
	get_root().add_child(root)
	var inspector := (load("res://scenes/ui/inspector_panel.tscn") as PackedScene) \
		.instantiate() as InspectorPanel
	root.add_child(inspector)
	inspector.show()
	var controller := FakePlayerController.new()
	root.add_child(controller)
	inspector.set_player_controller(controller)
	# Lambdas capture locals by value; count through a shared array.
	var detail_requests: Array[int] = [0]
	inspector.object_details_requested.connect(func(_request: Dictionary) -> void:
		detail_requests[0] += 1)
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
	if row_editor.is_visible_in_tree():
		failures.append("overview exposed the cohort tax editor")
	inspector._object_detail_dialog._on_chapter_selected("operations")
	if not row_editor.is_visible_in_tree():
		failures.append("operations did not expose the cohort tax editor")
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
	# 这一档真实的计税模式：下面 :357 的 _mark_tax_pending 要按它记账，不能写死 0。
	# 编辑器会在 :354 的 close_detail() 里被释放，所以必须在这里先取。
	var row_mode := int(row_editor.lane_data().get("mode",
		TaxLaneEditor.TAX_MODE_PERCENT_BP))
	row_editor._spin.set_value_no_signal(TaxLaneEditor.basis_points_to_percent(base_rate + 300))
	row_editor._on_text_submitted("")
	if not is_equal_approx(row_editor._spin.value,
			TaxLaneEditor.basis_points_to_percent(base_rate)) \
			or not (inspector.get("_pending_tax") as Dictionary).is_empty():
		failures.append("failed override did not restore the authoritative row rate")
	if detail_requests[0] != 0 or not inspector.detail_open():
		failures.append("tax editor input did not remain in the left detail workspace")

	controller.succeed = true
	row_editor._spin.set_value_no_signal(TaxLaneEditor.basis_points_to_percent(base_rate + 400))
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
	if not row_editor.is_pending() or not is_equal_approx(row_editor._spin.value,
			TaxLaneEditor.basis_points_to_percent(base_rate + 400)):
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
		inspector._on_tax_override_requested("default", "income", "", 1700)
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
		var before_reset := controller.calls.size()
		inspector._request_category_tax_reset()
		inspector._clear_tax_confirmation.hide()
		inspector._on_category_tax_reset_confirmed()
		if controller.calls.size() != before_reset + 1 \
				or StringName(controller.calls[-1].id) != &"country.tax.cell.clear_override" \
				or int(controller.calls[-1].args.kind) != 0:
			failures.append("population reset did not isolate the income override")
	var clear_key := "cell:5/income/artisan"
	if not pending.has(clear_key):
		failures.append("category reset did not retain pending state")
	var clear_ctx: Dictionary = (_model(5).categories.population.tax_context as Dictionary) \
		.duplicate(true)
	clear_ctx["current_day"] = 11
	clear_ctx["policy_version"] = 8
	clear_ctx["reset_targets"] = []
	inspector._resolve_tax_pending(clear_ctx)
	if pending.has(clear_key):
		failures.append("policy version advance did not resolve category reset pending")

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
		var page_draft := page_base + 600 if page_base <= 9400 else page_base - 600
		var page_draft_percent := TaxLaneEditor.basis_points_to_percent(page_draft)
		page_editor._spin.set_value_no_signal(page_draft_percent)
		page_editor._on_value_changed(page_draft_percent)
		inspector.apply_live_patch({
			"tab_id": "buildings",
			"category": building_model.categories.buildings,
		})
		await process_frame
		if not is_equal_approx(page_editor._spin.value, page_draft_percent) or not page_editor.is_editing():
			failures.append("live patch snapped the cell business default back to inherit")
		var page_wait := Time.get_ticks_msec()
		while Time.get_ticks_msec() - page_wait < int(
				(TaxLaneEditor.COMMIT_DELAY_SEC + 0.08) * 1000.0):
			await process_frame
		page_editor = (inspector.get("_page_tax_editors") as Array)[0] as TaxLaneEditor \
			if not (inspector.get("_page_tax_editors") as Array).is_empty() else null
		if page_editor == null \
				or StringName(controller.calls[-1].id) != &"country.tax.cell.set_default" \
				or int(controller.calls[-1].args.get("rate_basis_points", -1)) != page_draft \
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
					or not is_equal_approx(page_editor._spin.value, page_draft_percent):
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
						or not is_equal_approx(page_editor._spin.value, page_draft_percent):
					failures.append("matching snapshot did not resolve pending cell business tax")
		page_editor = (inspector.get("_page_tax_editors") as Array)[0] as TaxLaneEditor \
			if not (inspector.get("_page_tax_editors") as Array).is_empty() else null
		if page_editor != null:
			page_editor.resolve_pending()
			(inspector.get("_pending_tax") as Dictionary).clear()
			var typed_rate := 2200
			page_editor._spin.set_value_no_signal(TaxLaneEditor.basis_points_to_percent(page_base))
			page_editor._on_text_submitted(str(TaxLaneEditor.basis_points_to_percent(typed_rate)))
			if StringName(controller.calls[-1].id) != &"country.tax.cell.set_default" \
					or int(controller.calls[-1].args.get("rate_basis_points", -1)) != typed_rate \
					or not is_equal_approx(page_editor._spin.value,
						TaxLaneEditor.basis_points_to_percent(typed_rate)):
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
		var biz_draft := biz_base + 700 if biz_base <= 9300 else biz_base - 700
		var biz_draft_percent := TaxLaneEditor.basis_points_to_percent(biz_draft)
		biz_editor._spin.set_value_no_signal(biz_draft_percent)
		biz_editor._on_value_changed(biz_draft_percent)
		inspector.refresh_object_detail(building_payload)
		await process_frame
		biz_editor = inspector._object_detail_dialog.tax_editors()[0] as TaxLaneEditor
		if biz_editor.get_instance_id() != biz_id \
				or not is_equal_approx(biz_editor._spin.value, biz_draft_percent):
			failures.append("live detail refresh snapped building business tax back to inherit")
		var biz_wait := Time.get_ticks_msec()
		while Time.get_ticks_msec() - biz_wait < int(
				(TaxLaneEditor.COMMIT_DELAY_SEC + 0.08) * 1000.0):
			await process_frame
		var biz_editors: Array = inspector._object_detail_dialog.tax_editors()
		biz_editor = biz_editors[0] as TaxLaneEditor if not biz_editors.is_empty() else null
		if biz_editor == null \
				or StringName(controller.calls[-1].id) != &"country.tax.cell.set_override" \
				or int(controller.calls[-1].args.get("rate_basis_points", -1)) != biz_draft \
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
			var market_draft := market_base + 500 if market_base <= 9500 else market_base - 500
			var market_draft_percent := TaxLaneEditor.basis_points_to_percent(market_draft)
			consumption_editor._spin.set_value_no_signal(market_draft_percent)
			consumption_editor._on_value_changed(market_draft_percent)
			inspector.apply_live_patch({
				"tab_id": "market",
				"category": _market_model(5).categories.market,
			})
			await process_frame
			if not is_equal_approx(consumption_editor._spin.value, market_draft_percent) \
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
	# 补全 5 个参数：receipt 传空字典（这行不验回执，下面验的是换格子后 pending 被清掉），
	# op 传 "set"，mode 用该档真实值（上面取的 row_mode）。
	inspector._mark_tax_pending(row_key, base_rate + 1, {}, "set", row_mode)
	inspector.set_model_for_selection(_model(6))
	if not (inspector.get("_pending_tax") as Dictionary).is_empty():
		failures.append("new cell selection retained stale Inspector pending state")
	for spec in [["population", _model(5), [0]],
			["market", _market_model(5), [1, 3, 4]],
			["buildings", _building_model(5), [2]]]:
		inspector.close_detail()
		inspector.set_model_for_selection(spec[1])
		inspector.select_tab(spec[0])
		var reset_button := inspector.get("_reset_tax_button") as Button
		var tax_section := inspector.get("_page_tax_section") as Control
		if reset_button == null or not tax_section.is_ancestor_of(reset_button):
			failures.append("%s reset was not placed in its tax section" % spec[0])
		var header := tax_section.get_node("Header") as Button
		header.button_pressed = true
		await create_timer(UITokens.ANIM_FAST + 0.05).timeout
		var body := tax_section.get_node("Body") as Control
		if body.position.y < header.position.y + header.size.y:
			failures.append("expanded tax controls overlapped the section heading")
		var before := controller.calls.size()
		inspector._request_category_tax_reset()
		inspector._clear_tax_confirmation.hide()
		inspector._on_category_tax_reset_confirmed()
		if controller.calls.size() - before != spec[2].size():
			failures.append("%s reset did not clear every item override" % spec[0])
		for call_index in range(before, controller.calls.size()):
			var call: Dictionary = controller.calls[call_index]
			if int(call.args.kind) not in spec[2] \
					or StringName(call.id) != &"country.tax.cell.clear_override":
				failures.append("%s reset changed another category's taxes" % spec[0])
		before = controller.calls.size()
		inspector._request_category_tax_reset()
		inspector._clear_tax_confirmation.hide()
		inspector.select_tab("geography")
		inspector._on_category_tax_reset_confirmed()
		if controller.calls.size() != before:
			failures.append("stale reset confirmation changed a different category")

	await _run_tax_group_assertions(failures)

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
		"item_id": "artisan", "base": 1000, "effective": 1000,
		"default_rate": 800, "has_override": true, "editable": true,
	}
	var default_lane := lane.duplicate(true)
	default_lane["scope"] = "default"
	default_lane["item_id"] = ""
	default_lane["kind_label"] = "此地所得税"
	default_lane["default_rate"] = 800
	default_lane["has_override"] = false
	default_lane["base"] = 800
	default_lane["effective"] = 800
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
					"reset_targets": [{"scope": "item", "kind": lane.kind, "item_id": lane.item_id}],
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
		"item_id": "forge", "base": 1200, "effective": 1200,
		"default_rate": 400, "has_override": true, "editable": true,
	}
	var default_lane := lane.duplicate(true)
	default_lane["scope"] = "default"
	default_lane["item_id"] = ""
	default_lane["kind_label"] = "此地营业税"
	default_lane["has_override"] = false
	default_lane["base"] = 400
	default_lane["effective"] = 400
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
					"reset_targets": [{"scope": "item", "kind": lane.kind, "item_id": lane.item_id}],
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
		"consumption": ["交易税", "此地交易税"],
		"import": ["进口关税", "此地进口税"],
		"export": ["出口关税", "此地出口税"],
	}
	for kind in ["consumption", "import", "export"]:
		var pair: Array = label_pairs[kind]
		item_lanes.append({
			"scope": "item", "kind": kind, "kind_label": pair[0],
			"item_id": "grain", "base": 600, "effective": 600,
			"default_rate": 200, "has_override": true, "editable": true,
		})
		default_lanes.append({
			"scope": "default", "kind": kind, "kind_label": pair[1],
			"item_id": "", "base": 200, "effective": 200,
			"default_rate": 200, "has_override": false, "editable": true,
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
					"reset_targets": item_lanes,
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
	inspector._object_detail_dialog._on_chapter_selected("overview")
	for editor in editors:
		if (editor as Control).is_visible_in_tree():
			failures.append("%s overview exposed tax controls" % object_kind)
	inspector._object_detail_dialog._on_chapter_selected("operations")
	for editor in editors:
		if not (editor as Control).is_visible_in_tree():
			failures.append("%s operations hid tax controls" % object_kind)
	var page_section := inspector.get("_page_tax_section") as Control
	if page_section != null and page_section.visible:
		failures.append("%s detail left the page default tax visible" % object_kind)
	inspector.close_detail()
	page_section = inspector.get("_page_tax_section") as Control
	if page_section != null and not page_section.visible:
		failures.append("closing %s detail did not restore the page default tax" % object_kind)


# ===========================================================================
# 对象详情「整组设为」的行为断言：只加断言，不动被测代码。
# 四条：①整组下发的 id 逐个等于 build_axis 的组；②「全部」449 切 256+193；
# ③只 1 项时按钮禁用、切轴后旧选择被清掉；④不为了让测试变绿而放宽任何一条。
# ===========================================================================

func _run_tax_group_assertions(failures: PackedStringArray) -> void:
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	if not bool(compiled.get("ok", false)):
		failures.append("tax group assertions need the real catalog: %s" % String(
			compiled.get("reason", "")))
		return
	var columns: Dictionary = EconomyFacadeDisplayScript.construction_type_columns(
		compiled, _good_display_names())
	var building_ids: PackedStringArray = columns.get(
		"building_type_ids", PackedStringArray())
	if building_ids.size() != 449:
		failures.append("real catalog carries %d buildings, expected 449" % building_ids.size())
		return
	# 挑一座「产物组只有 1 项」的建筑：第 3 条与「切轴旧选择被清掉」都靠它。
	var single := _single_member_building(columns)
	if single.is_empty():
		failures.append("no building sits in a single-member output group; "
			+ "assertions 3 cannot run")
		return

	var controller := FakeTaxGroupController.new()
	controller.economy = FakeTaxGroupEconomy.new()
	controller.country = FakeTaxGroupCountry.new()
	controller.economy.columns = columns
	controller.country.building_ids = building_ids
	controller.country.good_ids = columns.get("good_ids", PackedStringArray())
	controller.country.profession_ids = columns.get(
		"profession_ids", PackedStringArray())

	get_root().size = Vector2i(1280, 720)
	var root := Control.new()
	root.theme = load("res://assets/themes/player_ui_theme.tres") as Theme
	get_root().add_child(root)
	root.add_child(controller)
	var panel := (load("res://scenes/ui/inspector_panel.tscn") as PackedScene) \
		.instantiate() as InspectorPanel
	root.add_child(panel)
	panel.show()
	panel.set_player_controller(controller)
	panel.set_model_for_selection(_group_building_model(5, single))
	panel.select_tab("buildings")
	await process_frame
	if int(panel.get("_tax_page_cell")) != 5:
		failures.append("group assertions need the detail cell to be 5, got %d" % int(
			panel.get("_tax_page_cell")))

	panel.show_object_detail({
		"kind": "building", "name": "整组测试建筑",
		"row": {"tax_lanes": [_group_lane(single)]},
		"tax_context": {
			"available": true, "editable": true, "cell": 5,
			"current_day": 10, "policy_version": 7,
		},
	})
	await process_frame
	var dialog := panel._object_detail_dialog
	var box := dialog.find_child("TaxGroupBox", true, false) as Control
	if box == null:
		# 先把事实说清楚：控件没建出来。数据层断言照跑，不让整条测试变成一片红。
		failures.append("object detail built no TaxGroupBox: 整组设为 never reaches the player")
	else:
		await _assert_group_box(failures, panel, box, columns, single)
	await _assert_group_data_path(failures, panel, columns, building_ids, single)
	await _assert_all_dossiers(failures, panel, columns)


## 三个档案都要把入口渲出来，并逐轴报「这一轴下该对象那一组有几项」。
## 这条是 Chief 明确要的：入口出来了没有 + 每轴可有几组。
func _assert_all_dossiers(failures: PackedStringArray, panel: InspectorPanel,
		columns: Dictionary) -> void:
	var specs := [
		{"kind": "building", "subject": "building", "lane_kind": "business",
			"lane_label": "营业税", "title": "建筑", "tax_kind": 2},
		{"kind": "good", "subject": "good", "lane_kind": "consumption",
			"lane_label": "交易税", "title": "物资", "tax_kind": 1},
		{"kind": "cohort", "subject": "profession", "lane_kind": "income",
			"lane_label": "所得税", "title": "阶层", "tax_kind": 0},
	]
	for spec_value in specs:
		var spec: Dictionary = spec_value
		var subject := String(spec["subject"])
		var title := String(spec["title"])
		var ids: PackedStringArray = columns.get(_subject_id_column(subject),
			PackedStringArray())
		if ids.is_empty():
			failures.append("%s dossier has no ids to group" % title)
			continue
		var sample := String(ids[0])
		panel.show_object_detail({
			"kind": String(spec["kind"]), "name": "整组测试",
			"row": {"tax_lanes": [{
				"scope": "item", "kind": String(spec["lane_kind"]),
				"kind_label": String(spec["lane_label"]), "item_id": sample,
				"base": 1000, "effective": 1000, "default_rate": 500,
				"has_override": true, "editable": true}]},
			"tax_context": {"available": true, "editable": true, "cell": 5,
				"current_day": 10, "policy_version": 7},
		})
		await process_frame
		var box := panel._object_detail_dialog.find_child(
			"TaxGroupBox", true, false) as Control
		if box == null:
			failures.append("%s dossier built no TaxGroupBox" % title)
			continue
		var axis_picker := box.get_node("Axis") as OptionButton
		var axes: Array = panel.tax_group_axes(subject)
		if axis_picker == null or axis_picker.item_count != axes.size():
			failures.append("%s dossier shows %d axes, host offers %d" % [
				title, axis_picker.item_count if axis_picker != null else -1, axes.size()])
			continue
		var parts := PackedStringArray()
		for axis_value in axes:
			var axis: Dictionary = axis_value
			var axis_id := String(axis.get("id", ""))
			var info: Dictionary = panel.tax_group_ids_for(axis_id, sample, subject)
			if not bool(info.get("ok", false)):
				failures.append("%s dossier axis %s returned no group" % [title, axis_id])
				continue
			parts.append("%s=%d" % [String(axis.get("label", axis_id)),
				int(info.get("count", 0))])
		print("    [tax-group] %s 轴 %d 条 · %s" % [title, axes.size(), ", ".join(parts)])
		# 再真按一次「全部」：三个档案都得走到命令层，批次与项数要对得上。
		var apply_button := box.get_node("Apply") as Button
		var controller = panel.get("_player_controller")
		var all_index := _axis_index(axes, "all_items")
		if apply_button == null or controller == null or all_index < 0:
			failures.append("%s dossier has no Apply button or no 全部 axis" % title)
			continue
		axis_picker.select(all_index)
		axis_picker.item_selected.emit(all_index)
		await process_frame
		var before: int = controller.calls.size()
		apply_button.pressed.emit()
		var issued: int = controller.calls.size() - before
		var expected_batches: int = int(ceil(float(ids.size()) / 256.0))
		var total := 0
		for call_index in range(before, controller.calls.size()):
			var args: Dictionary = controller.calls[call_index]["args"]
			var sent: PackedStringArray = args.get("item_ids", PackedStringArray())
			total += sent.size()
			if int(args.get("kind", -1)) != int(spec["tax_kind"]):
				failures.append("%s dossier sent tax kind %d instead of %d" % [
					title, int(args.get("kind", -1)), int(spec["tax_kind"])])
		if issued != expected_batches or total != ids.size():
			failures.append("%s dossier 全部 apply issued %d batches / %d items, "
				% [title, issued, total] + "expected %d / %d" % [expected_batches, ids.size()])
		print("    [tax-group] %s 按下「整组设为」: %d 批 / %d 项" % [title, issued, total])


## 控件层的三条（第 1、2、3 条）。只有 TaxGroupBox 真的建出来才跑。
func _assert_group_box(failures: PackedStringArray, panel: InspectorPanel,
		box: Control, columns: Dictionary, single: String) -> void:
	var axis_picker := box.get_node("Axis") as OptionButton
	var note := box.get_node("Note") as Label
	var rate := box.get_node("Rate") as SpinBox
	var apply_button := box.get_node("Apply") as Button
	if axis_picker == null or apply_button == null or rate == null or note == null:
		failures.append("TaxGroupBox is missing one of Axis/Note/Rate/Apply")
		return
	var axes: Array = panel.tax_group_axes("building")
	var era_index := _axis_index(axes, "era")
	var all_index := _axis_index(axes, "all_items")
	var output_index := _axis_index(axes, "output_good")
	if era_index < 0 or all_index < 0 or output_index < 0:
		failures.append("building detail axes lost era/all_items/output_good: %s" % str(axes))
		return
	var controller := panel.get("_player_controller") as FakeTaxGroupController

	# ---- 第 1 条：按「时代」轴整组设值，下发的 id 逐个等于 build_axis 的组 ----
	axis_picker.select(era_index)
	axis_picker.item_selected.emit(era_index)
	await process_frame
	if apply_button.disabled:
		failures.append("era group left 整组设为 disabled for a multi-member group")
	var expected := _axis_group_ids(columns, "era", "building", single)
	if expected.size() < 2:
		failures.append("era group holds %d item(s); the id-by-id check needs at least 2" % expected.size())
	rate.set_value_no_signal(5.0)
	var before := controller.calls.size()
	apply_button.pressed.emit()
	var issued := controller.calls.size() - before
	if issued != 1:
		failures.append("era group issued %d commands instead of 1" % issued)
	else:
		var call: Dictionary = controller.calls[before]
		if StringName(call["id"]) != &"country.tax.set_override_group":
			failures.append("era group used %s instead of country.tax.set_override_group" % String(
				call["id"]))
		var args: Dictionary = call["args"]
		if int(args.get("kind", -1)) != 2:
			failures.append("building detail sent tax kind %d instead of 2" % int(
				args.get("kind", -1)))
		if int(args.get("rate_basis_points", -1)) != 500:
			failures.append("era group sent rate %d instead of 500" % int(
				args.get("rate_basis_points", -1)))
		var sent: PackedStringArray = args.get("item_ids", PackedStringArray())
		if sent.size() != expected.size():
			failures.append("era group sent %d ids, build_axis says %d" % [
				sent.size(), expected.size()])
		else:
			for index in range(sent.size()):
				if String(sent[index]) != String(expected[index]):
					failures.append("era group id #%d is %s, build_axis says %s" % [
						index, String(sent[index]), String(expected[index])])
					break

	# ---- 第 2 条：「全部项目」449 切成 256 + 193 ----
	axis_picker.select(all_index)
	axis_picker.item_selected.emit(all_index)
	await process_frame
	before = controller.calls.size()
	apply_button.pressed.emit()
	issued = controller.calls.size() - before
	if issued != 2:
		failures.append("all-items group issued %d batches instead of 2" % issued)
	else:
		var first: PackedStringArray = controller.calls[before]["args"].get(
			"item_ids", PackedStringArray())
		var second: PackedStringArray = controller.calls[before + 1]["args"].get(
			"item_ids", PackedStringArray())
		if first.size() != 256 or second.size() != 193:
			failures.append("all-items chunks are %d + %d instead of 256 + 193" % [
				first.size(), second.size()])
		var overlap := 0
		for stable in first:
			if second.has(stable):
				overlap += 1
		if overlap != 0:
			failures.append("all-items chunks overlap on %d ids" % overlap)
		if first.size() + second.size() != 449:
			failures.append("all-items chunks cover %d ids instead of 449" % (
				first.size() + second.size()))

	# ---- 第 3 条：只 1 项的组禁用；切轴后旧选择被清掉 ----
	axis_picker.select(output_index)
	axis_picker.item_selected.emit(output_index)
	await process_frame
	if not apply_button.disabled:
		failures.append("single-member output group left 整组设为 enabled")
	if not note.text.contains("仅 1 项"):
		failures.append("single-member group note was \"%s\"" % note.text)
	# 切轴后 state 里不能再留着「全部」那一批：直接 emit 绕过 disabled，看它到底发什么。
	before = controller.calls.size()
	apply_button.pressed.emit()
	if controller.calls.size() != before:
		var kept: PackedStringArray = controller.calls[before]["args"].get(
			"item_ids", PackedStringArray())
		if kept.size() != 1 or String(kept[0]) != single:
			failures.append("axis switch kept a stale group: it sent %d ids" % kept.size())


## 数据层的三条同款断言：不依赖控件，验的是宿主 API 本身。
func _assert_group_data_path(failures: PackedStringArray, panel: InspectorPanel,
		columns: Dictionary, building_ids: PackedStringArray, single: String) -> void:
	var era_info: Dictionary = panel.tax_group_ids_for("era", single, "building")
	if not bool(era_info.get("ok", false)):
		failures.append("host tax_group_ids_for(era) returned nothing")
	else:
		var expected := _axis_group_ids(columns, "era", "building", single)
		var actual: PackedStringArray = era_info.get("item_ids", PackedStringArray())
		if actual.size() != expected.size():
			failures.append("host era group has %d ids, build_axis %d" % [
				actual.size(), expected.size()])
		else:
			for index in range(actual.size()):
				if String(actual[index]) != String(expected[index]):
					failures.append("host era id #%d is %s, build_axis says %s" % [
						index, String(actual[index]), String(expected[index])])
					break
	var all_info: Dictionary = panel.tax_group_ids_for("all_items", single, "building")
	var all_ids: PackedStringArray = all_info.get("item_ids", PackedStringArray())
	if all_ids.size() != building_ids.size():
		failures.append("host all-items group holds %d ids, snapshot has %d" % [
			all_ids.size(), building_ids.size()])
	var controller := panel.get("_player_controller") as FakeTaxGroupController
	var before := controller.calls.size()
	var result: Dictionary = panel.request_tax_group_override(2, all_ids, 500)
	var issued := controller.calls.size() - before
	if issued != 2:
		failures.append("host all-items override issued %d batches instead of 2" % issued)
	else:
		var first: PackedStringArray = controller.calls[before]["args"].get(
			"item_ids", PackedStringArray())
		var second: PackedStringArray = controller.calls[before + 1]["args"].get(
			"item_ids", PackedStringArray())
		if first.size() != 256 or second.size() != 193:
			failures.append("host chunks are %d + %d instead of 256 + 193" % [
				first.size(), second.size()])
		if int(result.get("chunks", -1)) != 2 or int(result.get("submitted", -1)) != 449:
			failures.append("host reported %s chunks / %s submitted, expected 2 / 449" % [
				str(result.get("chunks", -1)), str(result.get("submitted", -1))])


## 产物组只有 1 项的那座建筑（449 座里确实存在；找不到就直接报失败）。
func _single_member_building(columns: Dictionary) -> String:
	var built: Dictionary = TaxGroupMapScript.build_axis(
		columns, TaxGroupMapScript.AXIS_OUTPUT_GOOD, TaxGroupMapScript.SUBJECT_BUILDING)
	if not bool(built.get("ok", false)):
		return ""
	var ids: PackedStringArray = columns.get("building_type_ids", PackedStringArray())
	var counts: PackedInt32Array = built.get("group_counts", PackedInt32Array())
	var indices: PackedInt32Array = built.get("member_group_indices", PackedInt32Array())
	for member in range(indices.size()):
		if member < ids.size() and int(counts[int(indices[member])]) == 1:
			return String(ids[member])
	return ""


## build_axis 算出的某一组，按 catalog 顺序给出 id——第 1、3 条的期望值。
func _axis_group_ids(columns: Dictionary, axis: String, subject: String,
		item_id: String) -> PackedStringArray:
	var out := PackedStringArray()
	var built: Dictionary = TaxGroupMapScript.build_axis(columns, axis, subject)
	if not bool(built.get("ok", false)):
		return out
	var member_ids: PackedStringArray = columns.get(_subject_id_column(subject),
		PackedStringArray())
	var member := member_ids.find(item_id)
	var indices: PackedInt32Array = built.get("member_group_indices", PackedInt32Array())
	if member < 0 or member >= indices.size():
		return out
	var group := int(indices[member])
	if group < 0 or group >= int(built.get("group_count", 0)):
		return out
	for index in TaxGroupMapScript.members_in_group(indices, group):
		if index >= 0 and index < member_ids.size():
			out.append(String(member_ids[index]))
	return out


func _subject_id_column(subject: String) -> String:
	match subject:
		TaxGroupMapScript.SUBJECT_GOOD:
			return "good_ids"
		TaxGroupMapScript.SUBJECT_PROFESSION:
			return "profession_ids"
	return "building_type_ids"


func _axis_index(axes: Array, axis_id: String) -> int:
	for index in range(axes.size()):
		if String((axes[index] as Dictionary).get("id", "")) == axis_id:
			return index
	return -1


func _good_display_names() -> Dictionary:
	var out := {}
	var dir := "res://data/goods"
	for file_name in ResourceLoader.list_directory(dir):
		if file_name.get_extension().to_lower() != "tres":
			continue
		var profile = ResourceLoader.load("%s/%s" % [dir, file_name], "Resource")
		if profile == null:
			continue
		var stable_id := String(profile.get("id"))
		var display_name := String(profile.get("display_name"))
		out[stable_id] = display_name if display_name != "" else stable_id
	return out


func _group_lane(item_id: String) -> Dictionary:
	return {
		"scope": "item", "kind": "business", "kind_label": "营业税",
		"item_id": item_id, "base": 1200, "effective": 1200,
		"default_rate": 400, "has_override": true, "editable": true,
	}


func _group_building_model(cell_idx: int, item_id: String) -> Dictionary:
	var lane := _group_lane(item_id)
	var default_lane := lane.duplicate(true)
	default_lane["scope"] = "default"
	default_lane["item_id"] = ""
	default_lane["kind_label"] = "此地营业税"
	default_lane["has_override"] = false
	default_lane["base"] = 400
	default_lane["effective"] = 400
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
					"reset_targets": [{"scope": "item", "kind": lane.kind,
						"item_id": lane.item_id}],
				},
				"building_rows": [{
					"id": "building_group_1", "building_type_id": item_id,
					"name": "整组测试建筑", "tax_lanes": [lane],
				}],
			},
		},
	}

