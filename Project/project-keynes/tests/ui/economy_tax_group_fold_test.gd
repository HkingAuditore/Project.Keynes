extends SceneTree

## 验证国家财政总面板的「按组折叠税卡 + 折叠态整组编辑（含百分比/定额）+ 混合态 + 整组重置 + 按组展开微调 + 256 分块」。

const PlayerCommandValidation := preload("res://scripts/game/player_command_validation.gd")
const TaxGrouping := preload("res://scripts/ui/components/economy_tax_grouping.gd")

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
	_check_validation_refuses_bad_group_inputs()
	_check_axes_and_merchant_classification()
	await _check_goods_group_fold_and_independent_kinds()
	await _check_business_chunking_and_absolute_mode()
	for failure in _failures:
		push_error(failure)
	print("[economy-tax-group-fold] %d failures" % _failures.size())
	quit(0 if _failures.is_empty() else 1)


func _check_validation_refuses_bad_group_inputs() -> void:
	var noop := func(_id: StringName) -> bool: return false
	var r_empty := PlayerCommandValidation._validate_command_args(
		null, null, noop, &"country.tax.set_override_group",
		{"kind": 2, "item_ids": PackedStringArray(), "rate_basis_points": 500})
	_expect("validation refuses empty set_override_group", not bool(r_empty.get("ok", true)))
	var r_clear_empty := PlayerCommandValidation._validate_command_args(
		null, null, noop, &"country.tax.clear_override_group",
		{"kind": 2, "item_ids": PackedStringArray()})
	_expect("validation refuses empty clear_override_group", not bool(r_clear_empty.get("ok", true)))
	var r_bad_mode := PlayerCommandValidation._validate_command_args(
		null, null, noop, &"country.tax.set_override_group",
		{"kind": 2, "item_ids": PackedStringArray(["farm"]), "rate_basis_points": 500, "tax_assessment_mode": 9})
	_expect("validation refuses invalid tax_assessment_mode", not bool(r_bad_mode.get("ok", true)))
	var r_bad_pct := PlayerCommandValidation._validate_command_args(
		null, null, noop, &"country.tax.set_override_group",
		{"kind": 2, "item_ids": PackedStringArray(["farm"]), "rate_basis_points": 20000, "tax_assessment_mode": 0})
	_expect("validation refuses out-of-range percent rate", not bool(r_bad_pct.get("ok", true)))
	var r_bad_abs := PlayerCommandValidation._validate_command_args(
		null, null, noop, &"country.tax.set_override_group",
		{"kind": 2, "item_ids": PackedStringArray(["farm"]), "rate_basis_points": 2000000000, "tax_assessment_mode": 1})
	_expect("validation refuses out-of-range absolute amount", not bool(r_bad_abs.get("ok", true)))


func _check_axes_and_merchant_classification() -> void:
	const TaxGroupMapScript := preload("res://scripts/country/tax_group_map.gd")
	var good_axes := TaxGrouping.axes_for_page("consumption", true)
	var labels: Array[String] = []
	for a in good_axes:
		labels.append(String((a as Dictionary).get("label", "")))
	_expect("goods layer axis renamed to 按产品性质", labels.has("按产品性质") and not labels.has("按三层"))
	_expect("rate_band axis removed from grouping axes", not labels.has("按当前税率"))
	var catalog := {
		"profession_ids": PackedStringArray([
			"merchant", "miner", "forager", "unemployed",
			"landlord", "industrialist", "guild_master", "manager", "ship_officer",
		]),
		"profession_class_ids": PackedStringArray([
			"general", "worker", "farmer", "general",
			"general", "general", "general", "general", "general",
		]),
		"building_economic_sectors": PackedInt32Array([1, 1, 1, 1, 0]),
		"building_owner_profession_ids": PackedInt32Array([0, 0, 0, 0, 2]),
		"building_employee_offsets": PackedInt32Array([0, 1, 2, 3, 4, 4]),
		"building_employee_profession_ids": PackedInt32Array([1, 1, 1, 1]),
	}
	var by_sector := TaxGroupMapScript.build_axis(catalog, "sector", "profession")
	var m_group := int((by_sector.member_group_indices as PackedInt32Array)[0])
	_expect("merchant placed in commerce instead of extractive",
		String((by_sector.group_ids as PackedStringArray)[m_group]) == "commerce"
		and String((by_sector.group_labels as PackedStringArray)[m_group]) == "商业与贸易")
	var by_class := TaxGroupMapScript.build_axis(catalog, "profession_class", "profession")
	var class_gids: PackedStringArray = by_class.group_ids
	var class_labels: PackedStringArray = by_class.group_labels
	var class_idx: PackedInt32Array = by_class.member_group_indices
	_expect("merchant placed in commerce class",
		class_gids[class_idx[0]] == "commerce" and class_labels[class_idx[0]] == "商业")
	_expect("ship_officer placed in commerce class",
		class_gids[class_idx[8]] == "commerce")
	_expect("landlord and industrialist placed in major_owner class",
		class_gids[class_idx[4]] == "major_owner"
		and class_gids[class_idx[5]] == "major_owner"
		and class_labels[class_idx[4]] == "大业主")
	_expect("guild_master and manager placed in small_owner class",
		class_gids[class_idx[6]] == "small_owner"
		and class_gids[class_idx[7]] == "small_owner"
		and class_labels[class_idx[6]] == "小业主")
	var fam_labels: Dictionary = TaxGroupMapScript.family_label_map()
	_expect("branch family tax labels use concise names",
		String(fam_labels.get("backbone.food_storage", "")) == "食品业"
		and String(fam_labels.get("branch.textile_fibers", "")) == "纺织服装"
		and String(fam_labels.get("branch.heavy_industry", "")) == "重工业"
		and String(fam_labels.get("branch.forest_biomass", "")) == "林业与造纸")


func _check_goods_group_fold_and_independent_kinds() -> void:
	var workspace := load("res://scenes/ui/economy_workspace.tscn").instantiate() as EconomyWorkspace
	workspace.theme = load("res://assets/themes/player_session_theme.tres")
	root.add_child(workspace)
	workspace.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var controller := FakeController.new()
	controller.economy.columns = {
		"good_ids": PackedStringArray(["grain", "wheat_grain", "electricity"]),
		"good_layer_ids": PackedStringArray(["raw", "raw", "finished"]),
		"building_type_ids": PackedStringArray(["farm_a"]),
	}
	workspace.set_player_controller(controller)
	var policy := {
		"ok": true, "policy_version": 1,
		"default_rates_basis_points": PackedInt32Array([0, 100, 0, 200, 300]),
		"default_assessment_modes": PackedInt32Array([0, 0, 0, 0, 0]),
		"good_ids": PackedStringArray(["grain", "wheat_grain", "electricity"]),
	}
	for kind in ["consumption", "import", "export"]:
		var rate := 100 if kind == "consumption" else (200 if kind == "import" else 300)
		policy[kind] = {
			"rates_basis_points": PackedInt32Array([rate, rate, rate]),
			"effective_rates_basis_points": PackedInt32Array([rate, rate, rate]),
			"has_override": PackedByteArray([0, 0, 0]),
			"assessment_modes": PackedInt32Array([0, 0, 0]),
		}
	var grain := {"id": "grain", "display_name": "谷物", "icon_key": "good.grain"}
	var wheat := {"id": "wheat_grain", "display_name": "小麦", "icon_key": "good.grain"}
	var power := {"id": "electricity", "display_name": "电力", "icon_key": "good.electricity"}
	var model := {
		"available": true, "current_day": 1, "country_name": "测试国",
		"tax_policy": policy,
		"tax_presentation": {
			"consumption": {"unlocked": [grain, wheat, power], "total_count": 3},
			"import": {"unlocked": [grain, wheat], "total_count": 3},
			"export": {"unlocked": [grain, wheat], "total_count": 3},
		},
	}
	workspace.set_model(model)
	workspace.select_page_for_test("consumption")
	await process_frame
	var groups = workspace.get("_tax_groups")
	var keys: Array = groups.group_keys_for_test()
	_expect("goods page renders collapsible groups by default", keys.size() >= 1)
	var raw_key := String(keys[0])
	var raw_entry: Dictionary = groups._groups_by_key[raw_key]
	await process_frame
	_expect("group title label has visible non-zero width",
		not (raw_entry.title as Label).text.is_empty()
		and (raw_entry.title as Label).size.x >= 20.0)
	# 模拟不暂停游戏时持续 tick 刷新：默认税率卡与组头输入框正在输入时，焦点与文本不能被刷掉。
	var default_card: Dictionary = (workspace.get("_rows") as Dictionary)["consumption:__default__"]
	var default_line := ((default_card.spins as Dictionary)["consumption"] as SpinBox).get_line_edit()
	default_line.grab_focus()
	await process_frame
	default_line.text = "12"
	var group_line := ((raw_entry.spins as Dictionary)["consumption"] as SpinBox).get_line_edit()
	var tick_model := model.duplicate(true)
	tick_model["current_day"] = 2
	workspace.set_model(tick_model)
	await process_frame
	_expect("live tick refresh preserves focus and draft text on default tax card",
		default_line.has_focus() and default_line.text == "12")
	group_line.grab_focus()
	await process_frame
	group_line.text = "9.5"
	tick_model["current_day"] = 3
	workspace.set_model(tick_model)
	await process_frame
	_expect("live tick refresh preserves focus and draft text on group header spin",
		group_line.has_focus() and group_line.text == "9.5")
	group_line.release_focus()
	await process_frame
	_expect("group starts collapsed by default", not (raw_entry.members_margin as Control).visible)
	# 在折叠状态下直接修改组头的「交易税」，验证只发 kind=1，不动进口/出口。
	controller.commands.clear()
	var set_res: Dictionary = groups.submit_group_rate(raw_key, "consumption", 850, 0)
	_expect("group set succeeds in collapsed state", bool(set_res.get("ok", false)))
	_expect("group set emits single kind command without touching tariffs",
		controller.commands.size() == 1
		and controller.commands[0].id == &"country.tax.set_override_group"
		and int(controller.commands[0].args.kind) == 1
		and int(controller.commands[0].args.rate_basis_points) == 850
		and int(controller.commands[0].args.tax_assessment_mode) == 0)
	_expect("import rate untouched after setting consumption group",
		workspace.tax_row_rate("consumption", "grain", "import") == 2)
	# 展开后微调其中一项，组头应立刻变为混合态。
	(raw_entry.toggle as Button).button_pressed = true
	await process_frame
	_expect("toggling group expands members", (raw_entry.members_margin as Control).visible)
	var grain_card: Dictionary = (workspace.get("_rows") as Dictionary)["consumption:grain"]
	workspace.preview_item_rate_for_test("consumption", "grain", "consumption", 15)
	((grain_card.spins as Dictionary)["consumption"] as SpinBox).get_line_edit().text = "15"
	workspace.confirm_item_rate_for_test("consumption", "grain", "consumption")
	await process_frame
	var lane_state: Dictionary = (raw_entry.lane_states as Dictionary).get("consumption", {})
	_expect("editing one member turns group header into mixed state",
		bool(lane_state.get("mixed", false))
		and ((raw_entry.spins as Dictionary)["consumption"] as SpinBox).get_line_edit().placeholder_text == "混合")
	# 一键重置整组覆盖
	controller.commands.clear()
	var clr_res: Dictionary = groups.submit_group_clear(raw_key, "consumption")
	_expect("group clear emits clear_override_group",
		bool(clr_res.get("ok", false))
		and controller.commands.size() == 1
		and controller.commands[0].id == &"country.tax.clear_override_group"
		and int(controller.commands[0].args.kind) == 1)
	workspace.queue_free()
	await process_frame


func _check_business_chunking_and_absolute_mode() -> void:
	var workspace := load("res://scenes/ui/economy_workspace.tscn").instantiate() as EconomyWorkspace
	workspace.theme = load("res://assets/themes/player_session_theme.tres")
	root.add_child(workspace)
	workspace.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var controller := FakeController.new()
	var b_ids := PackedStringArray()
	var b_sectors := PackedInt32Array()
	var b_rates := PackedInt32Array()
	var b_flags := PackedByteArray()
	var b_modes := PackedInt32Array()
	var unlocked: Array = []
	for i in range(300):
		var bid := "farm_%d" % i
		b_ids.append(bid)
		b_sectors.append(0)
		b_rates.append(0)
		b_flags.append(0)
		b_modes.append(0)
		unlocked.append({"id": bid, "display_name": "农场 %d" % i, "icon_key": "building.farm"})
	controller.economy.columns = {
		"building_type_ids": b_ids,
		"building_economic_sectors": b_sectors,
	}
	workspace.set_player_controller(controller)
	var policy := {
		"ok": true, "policy_version": 1,
		"default_rates_basis_points": PackedInt32Array([0, 0, 0, 0, 0]),
		"default_assessment_modes": PackedInt32Array([0, 0, 0, 0, 0]),
		"building_type_ids": b_ids,
		"business": {
			"rates_basis_points": b_rates,
			"effective_rates_basis_points": b_rates,
			"has_override": b_flags,
			"assessment_modes": b_modes,
		},
	}
	workspace.set_model({
		"available": true, "current_day": 1, "country_name": "测试国",
		"tax_policy": policy,
		"tax_presentation": {"business": {"unlocked": unlocked, "total_count": 300}},
	})
	workspace.select_page_for_test("business")
	var groups = workspace.get("_tax_groups")
	groups.set_axis_for_test("business", "sector")
	await process_frame
	var keys: Array = groups.group_keys_for_test()
	_expect("300 buildings collapse into one sector group", keys.size() == 1)
	controller.commands.clear()
	var abs_res: Dictionary = groups.submit_group_rate(String(keys[0]), "business", 50000, 1)
	_expect("300-item absolute group set chunks into 256 + 44",
		bool(abs_res.get("ok", false))
		and int(abs_res.get("chunks", 0)) == 2
		and controller.commands.size() == 2
		and (controller.commands[0].args.item_ids as PackedStringArray).size() == 256
		and (controller.commands[1].args.item_ids as PackedStringArray).size() == 44
		and int(controller.commands[0].args.tax_assessment_mode) == 1
		and int(controller.commands[1].args.tax_assessment_mode) == 1)
	workspace.queue_free()
	await process_frame


func _expect(label: String, condition: bool) -> void:
	print("[%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures.append(label)
