extends "res://tests/satisfaction_runtime_test.gd"


func _init() -> void:
	call_deferred("_run_ui")


func _run_ui() -> void:
	root.size = Vector2i(1280, 720)
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	var runtime := _configured_world(compiled, 4020, true, false,
		{"funds": 20000000000, "fixed_demand": true, "block_comfort": true})
	_run_cycle(runtime, 0)
	var snapshot: Dictionary = runtime.get_population_cell_snapshot(0)
	var explained: Dictionary = runtime.explain_cohort_satisfaction(snapshot.handles[0])
	var dims: PackedInt32Array = explained.dim_values_q16
	var vm := CellInspectorViewModel.new()
	var rows: Array = vm._satisfaction_dimension_rows(dims, 8, 0, int(explained.worst_dimension_id))
	var values: PackedFloat32Array = vm._cohort_satisfaction_dims_float(dims, 8, 0)
	_expect("an absent consumption tier is N/A in the detail rows", rows[3].value == "不适用")
	_expect("an absent consumption tier stays absent in radar data", values[3] == -1.0)
	_expect("comfort tooltip explains realized consumption", "实际享受" in String(rows[2].tooltip))
	var combined := dims.duplicate()
	combined.append_array(dims)
	combined[2] = 65535
	combined[10] = -1
	var averages: PackedFloat32Array = vm._compute_cell_avg_satisfaction_dims(
		PackedInt64Array([4, 100]), combined, 8)
	_expect("inapplicable population does not dilute dimension averages", averages[2] > 0.999)
	var row := {
		"population": "400 人", "population_raw": 400, "employed_raw": 0,
		"wealth": "人均 5000", "living_level": int(explained.living_standard_level), "living_standard": "温饱",
		"satisfaction": "%.1f%%" % (float(explained.composite_q16) * 100.0 / 65536.0),
		"satisfaction_float": float(explained.composite_q16) / 65536.0,
		"satisfaction_rows": rows, "satisfaction_dims_float": values,
		"cell_reference_dims_float": values, "worst_dimension": rows[int(explained.worst_dimension_id)].name,
		"income": "0", "expense": "0", "net": "0",
	}
	var model: Dictionary = CellInspectorViewModel.cohort_dossier_model(row)
	_expect("the dossier preserves N/A instead of fabricating a percentage",
		model.dimension_bars[3].text == "不适用" and model.radar_values[3] == -1.0)
	var container := Control.new()
	container.theme = load("res://assets/themes/player_session_theme.tres") as Theme
	root.add_child(container)
	container.position = Vector2(330, 12)
	container.size = Vector2(620, 696)
	var paper := ColorRect.new()
	paper.color = UITokens.DOSSIER_PAPER
	container.add_child(paper)
	paper.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	paper.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var dialog := load("res://scenes/ui/object_detail_dialog.tscn").instantiate() as ObjectDetailDialog
	container.add_child(dialog)
	dialog.set_embedded(true)
	dialog.show_details({"kind": "cohort", "name": "猎人", "subtitle": "有储蓄，舒适消费缺货",
		"icon": "profession.hunter", "row": row})
	await process_frame
	await process_frame
	_expect("the rendered dossier keeps eight dimension rows", dialog._cohort_refs.dimension_bars.row_count() == 8)
	if "--screenshot" in OS.get_cmdline_user_args():
		await create_timer(0.8).timeout
		await RenderingServer.frame_post_draw
		var image := root.get_texture().get_image()
		_expect("the screenshot saves", image.save_png("res://tmp/consumption_satisfaction_ui.png") == OK)
	container.queue_free()
	await process_frame
	print("=== consumption satisfaction UI %s: checks=%d failures=%d ===" % [
		"PASS" if _failures == 0 else "FAIL", _checks, _failures])
	quit(0 if _failures == 0 else 1)
