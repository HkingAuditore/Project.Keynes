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
	var row_editor := (inspector._object_detail_dialog.tax_editors()[1] \
		as TaxLaneEditor)
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
	row_editor = (inspector._object_detail_dialog.tax_editors()[1] \
		as TaxLaneEditor)
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
	var default_editor := (inspector._object_detail_dialog.tax_editors()[0] \
		as TaxLaneEditor)
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
	inspector._resolve_tax_pending({"current_day": 11, "policy_version": 8})
	if pending.has(clear_key):
		failures.append("policy version advance did not resolve clear-all pending")

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
