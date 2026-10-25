extends SceneTree

class FakeController extends RefCounted:
	var commands: Array[Dictionary] = []
	func request_command(id: StringName, args: Dictionary) -> Dictionary:
		commands.append({"id": id, "args": args.duplicate(true)})
		return {"ok": true, "effective_day": 2, "sequence": commands.size()}

var _failures := PackedStringArray()

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	root.size = Vector2i(1280, 720)
	var background := ColorRect.new()
	background.color = Color("e4d9bf")
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(background)
	var workspace := load("res://scenes/ui/economy_workspace.tscn").instantiate() as EconomyWorkspace
	workspace.theme = load("res://assets/themes/player_session_theme.tres")
	root.add_child(workspace)
	workspace.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	workspace.offset_left = 24
	workspace.offset_top = 24
	workspace.offset_right = -24
	workspace.offset_bottom = -24
	workspace.set_compact(true)
	var controller := FakeController.new()
	workspace.set_player_controller(controller)
	var policy := {"ok": true, "policy_version": 1,
		"default_rates_basis_points": PackedInt32Array([0, 100, 0, 200, 300]),
		"good_ids": PackedStringArray(["grain", "electricity"])}
	for kind in ["consumption", "import", "export"]:
		var rate := 100 if kind == "consumption" else (200 if kind == "import" else 300)
		policy[kind] = {"rates_basis_points": PackedInt32Array([rate, rate]),
			"effective_rates_basis_points": PackedInt32Array([rate, rate]),
			"has_override": PackedByteArray([0, 0])}
	var grain := {"id": "grain", "display_name": "谷物", "icon_key": "good.grain"}
	var electricity := {"id": "electricity", "display_name": "电力", "icon_key": "good.electricity"}
	var model := {"available": true, "current_day": 1, "country_name": "测试国家",
		"tax_policy": policy, "tax_presentation": {
			"consumption": {"unlocked": [grain, electricity], "total_count": 2},
			"import": {"unlocked": [grain], "total_count": 2},
			"export": {"unlocked": [grain], "total_count": 2}}}
	workspace.set_model(model)
	workspace.select_page_for_test("consumption")
	await process_frame
	var rows: Dictionary = workspace.get("_rows")
	var card: Dictionary = rows["consumption:grain"]
	var power: Dictionary = rows["consumption:electricity"]
	_expect("one goods page replaces the tariff page", not EconomyWorkspace.TAX_PAGE_IDS.has("tariff"))
	_expect("one card has all three independent taxes", card.spins.has_all(["consumption", "import", "export"]))
	_expect("nontradeable goods only have transaction tax", power.spins.keys() == ["consumption"])
	_expect("goods are not duplicated", workspace.tax_row_count("consumption") == 3)
	for kind in ["consumption", "import", "export"]:
		workspace.preview_item_rate_for_test("consumption", "grain", kind, 7)
		(card.spins[kind] as SpinBox).get_line_edit().text = "7"
		workspace.confirm_item_rate_for_test("consumption", "grain", kind)
		var command: Dictionary = controller.commands.back()
		_expect("%s command keeps its tax kind and good" % kind,
			command.id == &"country.tax.set_override" and command.args.kind == EconomyWorkspace.TAX_KIND[kind]
			and command.args.item_id == &"grain" and command.args.rate_basis_points == 700)
	workspace.refresh_model(model)
	await create_timer(0.25).timeout
	for kind in ["consumption", "import", "export"]:
		_expect("%s pending edit survives refresh" % kind,
			workspace.tax_row_rate("consumption", "grain", kind) == 7)
	_expect("refresh keeps the same goods card", workspace.tax_row_instance_id("consumption", "grain") == card.control.get_instance_id())
	workspace.call("_on_reset_pressed", "consumption:grain", "import")
	_expect("reset only clears the selected import override",
		controller.commands.back().id == &"country.tax.clear_override"
		and controller.commands.back().args.kind == 3
		and workspace.tax_row_rate("consumption", "grain", "consumption") == 7
		and workspace.tax_row_rate("consumption", "grain", "export") == 7)
	workspace.preview_default_rate_for_test("consumption", "export", 5)
	workspace.confirm_default_rate_for_test("consumption", "export")
	_expect("default tariff edits use the merged card",
		controller.commands.back().id == &"country.tax.set_default"
		and controller.commands.back().args.kind == 4)
	for viewport_size in [Vector2i(960, 720), Vector2i(1280, 720)]:
		root.size = viewport_size
		await process_frame
		await process_frame
		var scroll: ScrollContainer = workspace.get("_scroll")
		for item in [card, power, rows["consumption:__default__"]]:
			var control := item.control as Control
			_expect("%s fits at %d pixels" % [item.item_id, viewport_size.x],
				control.get_global_rect().end.x <= scroll.get_global_rect().end.x + 0.5)
	await create_timer(0.4).timeout
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("capture=") and DisplayServer.get_name() != "headless":
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(argument.trim_prefix("capture="))
	for failure in _failures:
		push_error(failure)
	print("[goods-tax-workspace] %d failures" % _failures.size())
	workspace.queue_free()
	background.queue_free()
	await process_frame
	quit(0 if _failures.is_empty() else 1)

func _expect(label: String, condition: bool) -> void:
	print("[%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures.append(label)
