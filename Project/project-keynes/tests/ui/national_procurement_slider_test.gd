extends SceneTree

## 国家购买预算滑条（国库页）与科技占比滑条（科技页）的交互回归：
## 拖动预览不提交、松手提交一次、最左端关闭、文本格式、提交经 PlayerController
## 的 procurement.set_policy，以及 unsupported_command 时科技页回退 research.set_budget。
##
## godot --headless --path Project/project-keynes --script res://tests/ui/national_procurement_slider_test.gd

const SliderScene := preload("res://scenes/ui/national_procurement_slider.tscn")
const ResearchSliderScene := preload("res://scenes/ui/procurement_budget_slider.tscn")
const EconomyWorkspaceScene := preload("res://scenes/ui/economy_workspace.tscn")
const SliderScript := preload("res://scripts/ui/components/national_procurement_slider.gd")
const CountryViewModelScript := preload("res://scripts/ui/country_view_model.gd")
const EconomyDossierViewModelScript := preload("res://scripts/ui/economy_dossier_view_model.gd")

var _failures := 0


class ControllerStub extends RefCounted:
	var commands: Array = []
	var policy := {"treasury_share_bp": 300, "research_share_bp": 4000}
	var supports_policy := true
	var has_policy_getter := true

	func request_command(id: StringName, args: Dictionary = {}) -> Dictionary:
		commands.append({"id": id, "args": args.duplicate(true)})
		if id == &"procurement.set_policy":
			if not supports_policy:
				return {"ok": false, "code": "unsupported_command", "message": "该正式玩家命令尚未开放。"}
			policy = {"treasury_share_bp": int(args.treasury_share_bp),
				"research_share_bp": int(args.research_share_bp)}
		return {"ok": true, "code": "", "message": ""}

	func get_procurement_policy() -> Dictionary:
		return policy.duplicate() if has_policy_getter else {}


func _init() -> void:
	get_root().size = Vector2i(1280, 720)
	_test_slider_drag_and_commit()
	_test_slider_text()
	_test_present_procurement()
	_test_resolve_policy()
	_test_research_share_slider()
	_test_fiscal_label()
	await _test_economy_workspace_wiring()
	print("=== national procurement slider: %d failures ===" % _failures)
	quit(0 if _failures == 0 else 1)


func _make_slider() -> Control:
	var slider := SliderScene.instantiate() as Control
	get_root().add_child(slider)
	slider.size = Vector2(406.0, 146.0)
	return slider


func _track_y(slider: Control) -> float:
	return SliderScript.TRACK_TOP + SliderScript.TRACK_HEIGHT * 0.5


func _x_for_bp(slider: Control, bp: int) -> float:
	var track: Rect2 = slider._track_rect()
	return track.position.x + track.size.x * float(bp) / float(SliderScript.MAX_TREASURY_SHARE_BP)


func _test_slider_drag_and_commit() -> void:
	var slider := _make_slider()
	slider.set_state(200, 5000, 1_000_000_000)
	var previews: Array = []
	var commits: Array = []
	slider.policy_previewed.connect(func(bp: int) -> void: previews.append(bp))
	slider.policy_committed.connect(func(bp: int) -> void: commits.append(bp))
	var y := _track_y(slider)
	_press(slider, Vector2(_x_for_bp(slider, 500), y))
	_move(slider, Vector2(_x_for_bp(slider, 640), y))
	_expect("dragging previews without committing", commits.is_empty() and previews.size() == 2)
	_expect("drag snaps to 0.1% steps", int(previews[-1]) == 640)
	_expect("set_state during a drag does not yank the grabber",
		_set_state_and_read(slider, 100, 640))
	_release(slider, Vector2(_x_for_bp(slider, 640), y))
	_expect("release commits exactly once with the dragged share",
		commits == [640] and slider.treasury_share_bp() == 640)
	_press(slider, Vector2(-30.0, y))
	_release(slider, Vector2(-30.0, y))
	_expect("the far-left end turns national procurement off",
		commits[-1] == 0 and not slider.is_enabled())
	var track_end: float = (slider._track_rect() as Rect2).end.x
	_press(slider, Vector2(track_end - 4.0, y))
	_move(slider, Vector2(track_end + 200.0, y))
	_release(slider, Vector2(track_end + 200.0, y))
	_expect("dragging beyond the right edge clamps at 10%/day",
		commits[-1] == 1000 and slider.treasury_share_bp() == 1000)
	var before := commits.size()
	_press(slider, Vector2(_x_for_bp(slider, 300), y + 40.0))
	_release(slider, Vector2(_x_for_bp(slider, 300), y + 40.0))
	_expect("pressing outside the track band does nothing", commits.size() == before)
	slider.queue_free()


func _set_state_and_read(slider: Control, bp: int, expected: int) -> bool:
	slider.set_state(bp, 5000, 1_000_000_000)
	return slider.treasury_share_bp() == expected


func _test_slider_text() -> void:
	var slider := _make_slider()
	# 国库 10 万（MONEY_SCALE 10000），2%/日 → 每日 2000。
	slider.set_state(200, 5000, 1_000_000_000)
	_expect("value text shows the estimated daily amount without a currency word",
		slider.value_text() == "每日 %s" % UITokens.format_compact_number_cn(2000.0, 2)
		and not MoneyDisplay.has_unit(slider.value_text()))
	_expect("share text states the treasury percentage", slider.share_text() == "占国库 2.0%/日")
	_expect("breakdown splits research share and gives the rest to dispatch reserve",
		slider.breakdown_text() == "科技 %s · 时代晋升 %s · 派遣储备 %s" % [
			UITokens.format_compact_number_cn(1000.0, 2),
			UITokens.format_compact_number_cn(0.0, 2),
			UITokens.format_compact_number_cn(1000.0, 2)])
	_expect("no last-epoch line without a native snapshot", slider.last_epoch_text().is_empty())
	_expect("the note explains what national procurement covers",
		slider.note_text() == "国家购买包括派遣储备、升级时代与科技投入")
	var snapshot := CountryViewModelScript.present_procurement({
		"ok": true, "policy_enabled": true, "treasury_share_bp": 200,
		"research_share_bp": 5000, "national_daily_budget": 25000000,
		"research_daily_budget": 12500000, "other_daily_budget": 12500000,
		"era_active": true, "era_daily_budget": 6250000,
		"colonization_daily_budget": 6250000, "era_last_epoch_cash": 400000,
		"research_cash_spent_last_epoch": 900000,
		"colonization_cash_spent_last_epoch": 100000,
	})
	slider.set_state(200, 5000, 1_000_000_000, snapshot)
	_expect("matching native snapshot supplies the frozen daily amount",
		slider.national_daily_budget() == 25000000
		and slider.value_text() == "每日 %s" % UITokens.format_compact_number_cn(2500.0, 2))
	_expect("breakdown uses the runtime allocation",
		slider.breakdown_text() == "科技 %s · 时代晋升 %s · 派遣储备 %s" % [
			UITokens.format_compact_number_cn(1250.0, 2),
			UITokens.format_compact_number_cn(625.0, 2),
			UITokens.format_compact_number_cn(625.0, 2)])
	_expect("last-epoch actual spend appears once the snapshot is available",
		slider.last_epoch_text().begins_with("上一周期实付 科技 %s" %
			UITokens.format_compact_number_cn(90.0, 2)))
	slider.set_state(0, 5000, 1_000_000_000, snapshot)
	_expect("off state reads 已关闭 with no breakdown",
		slider.value_text() == "已关闭" and slider.breakdown_text().is_empty()
		and slider.national_daily_budget() == 0)
	slider.queue_free()


func _test_present_procurement() -> void:
	_expect("missing facade degrades to an unavailable procurement model",
		not bool(CountryViewModelScript.procurement_model(null, 7).get("available", true)))
	_expect("failed native snapshot degrades gracefully",
		not bool(CountryViewModelScript.present_procurement(
			{"ok": false, "reason": "x"}).get("available", true)))
	var presented := CountryViewModelScript.present_procurement({"ok": true,
		"treasury_share_bp": 150, "policy_enabled": true})
	_expect("present_procurement fills every key with integer defaults",
		bool(presented.available) and int(presented.treasury_share_bp) == 150
		and int(presented.national_daily_budget) == 0
		and presented.has("colonization_cash_spent_last_epoch"))


func _test_resolve_policy() -> void:
	var controller := ControllerStub.new()
	var policy: Dictionary = SliderScript.resolve_policy(controller, {})
	_expect("session policy wins", int(policy.treasury_share_bp) == 300
		and int(policy.research_share_bp) == 4000 and String(policy.source) == "session")
	controller.has_policy_getter = false
	policy = SliderScript.resolve_policy(controller, {"available": true,
		"policy_enabled": true, "treasury_share_bp": 700, "research_share_bp": 2500})
	_expect("native snapshot is the fallback", int(policy.treasury_share_bp) == 700
		and int(policy.research_share_bp) == 2500)
	policy = SliderScript.resolve_policy(null, {})
	_expect("defaults are 2%/day and 50% research", int(policy.treasury_share_bp) == 200
		and int(policy.research_share_bp) == 5000)
	var result: Dictionary = SliderScript.submit_policy(controller, 450, 6000)
	_expect("submit_policy sends procurement.set_policy with both shares",
		bool(result.ok) and controller.commands[-1].id == &"procurement.set_policy"
		and controller.commands[-1].args == {"treasury_share_bp": 450, "research_share_bp": 6000})
	controller.supports_policy = false
	_expect("unsupported_command is detected",
		SliderScript.is_unsupported(SliderScript.submit_policy(controller, 1, 2)))


func _test_research_share_slider() -> void:
	var slider := ResearchSliderScene.instantiate() as Control
	get_root().add_child(slider)
	slider.size = Vector2(292.0, 102.0)
	slider.set_state(4000, 30000000, true)
	_expect("research slider derives the daily technology budget",
		slider.daily_research_budget() == 12000000)
	_expect("research slider preview reads 占国家购买 40% · 每日 1200",
		slider.preview_text() == "占国家购买 40%% · 每日 %s" %
			UITokens.format_compact_number_cn(1200.0, 2))
	var commits: Array = []
	slider.share_committed.connect(func(bp: int) -> void: commits.append(bp))
	var y: float = slider.TRACK_TOP + slider.TRACK_HEIGHT * 0.5
	_press(slider, Vector2(-20.0, y))
	_release(slider, Vector2(-20.0, y))
	_expect("leftmost research share is 0% (no technology purchase)",
		commits == [0] and slider.value_text() == "不购买"
		and slider.daily_research_budget() == 0)
	var span: float = slider.size.x - slider.GRABBER_RADIUS * 2.0
	_press(slider, Vector2(slider.GRABBER_RADIUS + span * 0.753, y))
	_release(slider, Vector2(slider.GRABBER_RADIUS + span * 0.753, y))
	_expect("research share snaps to whole percents", commits[-1] == 7500)
	slider.set_state(7500, 30000000, false)
	_expect("research share with national procurement off spends nothing",
		slider.daily_research_budget() == 0 and slider.preview_text().contains("已关闭"))
	slider.queue_free()


func _test_fiscal_label() -> void:
	var cashflow: Dictionary = EconomyDossierViewModelScript.build_cashflow({
		"ok": true, "tax_kinds": PackedStringArray(),
		"non_tax_outflow_kinds": PackedStringArray(["research_purchase",
			"expedition_procurement", "construction", "canal", "era_procurement"]),
		"non_tax_outflow": PackedInt64Array([0, 0, 0, 0, 50000]),
	})
	var labelled := false
	for row in cashflow.get("detail_rows", []) as Array:
		if String((row as Dictionary).id) == "era_procurement" \
				and String(((row as Dictionary).cells as Dictionary).name.text) == "时代晋升收购":
			labelled = true
	_expect("era_procurement non-tax outflow is labelled 时代晋升收购", labelled)


func _test_economy_workspace_wiring() -> void:
	var host := Control.new()
	host.size = Vector2(1240.0, 640.0)
	get_root().add_child(host)
	var workspace := EconomyWorkspaceScene.instantiate() as Control
	host.add_child(workspace)
	var controller := ControllerStub.new()
	workspace.set_player_controller(controller)
	workspace.set_model({
		"available": true, "country_name": "测试国", "current_day": 3,
		"treasury": {"available": true, "cash": 1_000_000_000, "cash_text": "10万",
			"nonzero_good_count": 0, "goods": []},
		"fiscal": {},
		"procurement": {"available": false},
	})
	await process_frame
	var page: Control = workspace.fiscal_page()
	_expect("treasury page mounts the unified budget dossier",
		page != null and page.visible)
	var constants: Dictionary = workspace.get_script().get_script_constant_map()
	var top_pages: Array = constants.get("TOP_PAGE_IDS", [])
	_expect("the separate fiscal tab is gone", not top_pages.has("fiscal"))
	var goods_scroll := workspace.get_node_or_null(
		"Column/Ledger/LedgerColumn/Scroll") as Control
	_expect("treasury goods stay visible beside the budget dossier",
		goods_scroll != null and goods_scroll.visible)
	if page == null:
		host.queue_free()
		return
	var national: Control = page.national_slider()
	var technology: Control = page.technology_slider()
	_expect("budget dossier mounts national and technology sliders",
		national != null and technology != null)
	_expect("technology slider lives in the technology section",
		technology != null and technology.get_parent() == page.section_body("technology"))
	_expect("budget dossier mounts the fixed allocation ribbon", page.ribbon() != null)
	_expect("national slider starts from the session policy",
		national != null and national.treasury_share_bp() == 300)
	if national == null or technology == null:
		host.queue_free()
		return
	controller.commands.clear()
	technology.share_committed.emit(6500)
	_expect("technology share routes procurement.set_policy through the dossier",
		controller.commands.size() == 1
		and controller.commands[-1].id == &"procurement.set_policy"
		and int(controller.commands[-1].args.research_share_bp) == 6500)
	_expect("auto channels are not pinned into manual shares by the commit",
		not controller.commands[-1].args.has("era_share_bp")
		and not controller.commands[-1].args.has("colonization_share_bp"))
	controller.commands.clear()
	national.policy_committed.emit(800)
	_expect("national share still commits with the current technology share",
		controller.commands.size() == 1
		and int(controller.commands[-1].args.treasury_share_bp) == 800
		and int(controller.commands[-1].args.research_share_bp) == 6500)
	workspace.select_page_for_test("income")
	_expect("the budget dossier belongs to the treasury page only", not page.visible)
	host.queue_free()


func _press(control: Control, position: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = position
	control._gui_input(event)


func _release(control: Control, position: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = false
	event.position = position
	control._gui_input(event)


func _move(control: Control, position: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = position
	control._gui_input(event)


func _expect(label: String, condition: bool) -> void:
	if condition:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		push_error("  [FAIL] %s" % label)
