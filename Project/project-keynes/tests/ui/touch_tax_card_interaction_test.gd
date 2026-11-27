extends SceneTree

## 验证移动端（触摸档）点击默认税卡、分组内成员税卡、整组调税按钮时，
## 均能正常弹出 TouchTaxSheet 侧滑抽屉并提交税率修改，同时拖动列表不误触。

const TouchUI := preload("res://scripts/ui/touch_ui.gd")

class FakeEconomyFacade extends RefCounted:
	var columns: Dictionary = {}
	func construction_type_columns() -> Dictionary:
		return columns

class FakeController extends RefCounted:
	var commands: Array[Dictionary] = []
	var economy := FakeEconomyFacade.new()
	func get_economy_facade():
		return economy
	func request_command(id: StringName, args: Dictionary) -> Dictionary:
		commands.append({"id": id, "args": args.duplicate(true)})
		return {"ok": true, "effective_day": 2, "sequence": commands.size()}

var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	root.size = Vector2i(1280, 720)
	await process_frame
	_expect("mobile touch profile active", TouchUI.is_touch())
	await _check_touch_tax_card_tap_and_commit()
	for failure in _failures:
		push_error(failure)
	print("[touch-tax-card-interaction] %d failures" % _failures.size())
	quit(0 if _failures.is_empty() else 1)


func _check_touch_tax_card_tap_and_commit() -> void:
	var layer := CanvasLayer.new()
	root.add_child(layer)
	var workspace := load("res://scenes/ui/economy_workspace.tscn").instantiate() as EconomyWorkspace
	workspace.theme = load("res://assets/themes/player_session_theme.tres")
	layer.add_child(workspace)
	workspace.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var controller := FakeController.new()
	controller.economy.columns = {
		"good_ids": PackedStringArray(["grain", "wheat_grain"]),
		"good_layer_ids": PackedStringArray(["raw", "raw"]),
		"building_type_ids": PackedStringArray([]),
	}
	workspace.set_player_controller(controller)

	var policy := {
		"ok": true, "policy_version": 1,
		"default_rates_basis_points": PackedInt32Array([0, 500, 0, 200, 300]),
		"default_assessment_modes": PackedInt32Array([0, 0, 0, 0, 0]),
		"good_ids": PackedStringArray(["grain", "wheat_grain"]),
	}
	for kind in ["consumption", "import", "export"]:
		var rate := 500 if kind == "consumption" else (200 if kind == "import" else 300)
		policy[kind] = {
			"rates_basis_points": PackedInt32Array([rate, rate]),
			"effective_rates_basis_points": PackedInt32Array([rate, rate]),
			"has_override": PackedByteArray([0, 0]),
			"assessment_modes": PackedInt32Array([0, 0]),
		}
	var grain := {"id": "grain", "display_name": "谷物", "icon_key": "good.grain"}
	var wheat := {"id": "wheat_grain", "display_name": "小麦", "icon_key": "good.grain"}
	var model := {
		"available": true, "current_day": 1, "country_name": "测试国",
		"tax_policy": policy,
		"tax_presentation": {
			"consumption": {"unlocked": [grain, wheat], "total_count": 2},
			"import": {"unlocked": [grain, wheat], "total_count": 2},
			"export": {"unlocked": [grain, wheat], "total_count": 2},
		},
	}
	workspace.set_model(model)
	workspace.select_page_for_test("consumption")
	await process_frame
	await process_frame

	var rows: Dictionary = workspace.get("_rows")
	var default_card: Dictionary = rows.get("consumption:__default__", {})
	var default_panel := default_card.get("control") as Control
	_expect("default tax card exists and visible",
		default_panel != null and default_panel.is_visible_in_tree())

	# 1. 轻点默认税卡（经过 sync_groups 重挂到 DefaultTaxHost）应弹出 TouchTaxSheet。
	await _tap_control(default_panel)
	var sheet := layer.get_node_or_null("TouchTaxSheet") as Control
	_expect("tapping default tax card opens TouchTaxSheet",
		sheet != null and sheet.visible)
	if sheet != null and sheet.visible:
		(sheet.get_node("%Plus5") as Button).pressed.emit()
		(sheet.get_node("%ConfirmButton") as Button).pressed.emit()
		await process_frame
		_expect("confirming default card closes TouchTaxSheet", not sheet.visible)
		_expect("confirming default card submits set_default command",
			controller.commands.size() == 1
			and controller.commands[0].id == &"country.tax.set_default"
			and int((controller.commands[0].args as Dictionary).get("rate_basis_points", -1)) == 1000)

	# 2. 展开分组后，轻点被重挂到组内 Members 的成员税卡，应弹出 TouchTaxSheet 并可提交覆盖税率。
	var groups = workspace.get("_tax_groups")
	var group_keys: Array = groups.group_keys_for_test()
	_expect("at least one tax group exists", group_keys.size() >= 1)
	if group_keys.size() >= 1:
		var group_key := String(group_keys[0])
		var group_entry: Dictionary = groups._groups_by_key[group_key]
		var toggle := group_entry.get("toggle") as Button
		toggle.button_pressed = true
		toggle.toggled.emit(true)
		await process_frame
		await process_frame

		var grain_card: Dictionary = rows.get("consumption:grain", {})
		var grain_panel := grain_card.get("control") as Control
		_expect("grouped member tax card visible after expanding group",
			grain_panel != null and grain_panel.is_visible_in_tree())
		if grain_panel != null and grain_panel.is_visible_in_tree():
			# 2a. 超过拖拽容差的滑动不应误触弹层。
			await _drag_control(grain_panel, Vector2(0.0, 40.0))
			sheet = layer.get_node_or_null("TouchTaxSheet") as Control
			_expect("dragging across tax card does not open TouchTaxSheet",
				sheet == null or not sheet.visible)

			# 2b. 轻点成员税卡应弹出 TouchTaxSheet 并能提交修改。
			var prev_cmds := controller.commands.size()
			await _tap_control(grain_panel)
			sheet = layer.get_node_or_null("TouchTaxSheet") as Control
			_expect("tapping grouped member tax card opens TouchTaxSheet",
				sheet != null and sheet.visible)
			if sheet != null and sheet.visible:
				_expect("sheet title matches tapped tax card",
					(sheet.get_node("%Title") as Label).text == "谷物")
				(sheet.get_node("%Preset3") as Button).pressed.emit()
				(sheet.get_node("%ConfirmButton") as Button).pressed.emit()
				await process_frame
				_expect("confirming member card submits set_override command",
					controller.commands.size() == prev_cmds + 1
					and controller.commands[prev_cmds].id == &"country.tax.set_override"
					and String((controller.commands[prev_cmds].args as Dictionary).get("item_id", "")) == "grain"
					and int((controller.commands[prev_cmds].args as Dictionary).get("rate_basis_points", -1)) == 1500)

		# 3. 点击分组头部的「整组调税」按钮应弹出 TouchTaxSheet 并能提交整组税率。
		var group_edit := (group_entry.get("control") as Control).get_node_or_null("Header/Row/GroupTouchEdit") as Button
		_expect("group touch edit button is visible in touch profile",
			group_edit != null and group_edit.visible)
		if group_edit != null and group_edit.visible:
			var prev_group_cmds := controller.commands.size()
			group_edit.pressed.emit()
			await process_frame
			sheet = layer.get_node_or_null("TouchTaxSheet") as Control
			_expect("pressing group edit button opens TouchTaxSheet",
				sheet != null and sheet.visible)
			if sheet != null and sheet.visible:
				(sheet.get_node("%Preset2") as Button).pressed.emit()
				(sheet.get_node("%ConfirmButton") as Button).pressed.emit()
				await process_frame
				_expect("confirming group sheet submits set_override_group command",
					controller.commands.size() == prev_group_cmds + 1
					and controller.commands[prev_group_cmds].id == &"country.tax.set_override_group"
					and int((controller.commands[prev_group_cmds].args as Dictionary).get("rate_basis_points", -1)) == 1000)

	layer.queue_free()
	await process_frame


func _tap_control(control: Control) -> void:
	var center := control.get_global_rect().get_center()
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = center
	press.global_position = center
	root.push_input(press)
	await process_frame
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = center
	release.global_position = center
	root.push_input(release)
	await process_frame


func _drag_control(control: Control, delta: Vector2) -> void:
	var start := control.get_global_rect().get_center()
	var end := start + delta
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = start
	press.global_position = start
	root.push_input(press)
	await process_frame
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = end
	release.global_position = end
	root.push_input(release)
	await process_frame


func _expect(label: String, condition: bool) -> void:
	if not condition:
		_failures.append("FAIL: %s" % label)
