extends SceneTree

## 财政页的通道份额滑条（需求 3.1 / 3.2 / 7.3）。
##
## 覆盖：时代收购与开拓两条滑条确实挂在对应撕纸板块里、三项份额之和的
## 可拖上限互相收窄、拖动预览不提交/松手提交一次、超额时被夹在剩余额度上、
## 三项全 0 的暂停态文案，以及提交经 PlayerController 带着四项份额走
## `procurement.set_policy`。不依赖原生快照，纯 UI 契约。
##
## godot --headless --path Project/project-keynes \
##   --script res://tests/ui/fiscal_channel_slider_test.gd

const FiscalPageScript = preload("res://scripts/ui/components/fiscal_budget_page.gd")
const ChannelSliderScript = preload("res://scripts/ui/components/channel_share_slider.gd")
const BudgetSliderScript = preload("res://scripts/ui/components/budget_share_slider.gd")
const NationalSliderScript = preload(
	"res://scripts/ui/components/national_procurement_slider.gd")

var _failures := 0


class ControllerStub extends RefCounted:
	var commands: Array = []
	var policy := {"treasury_share_bp": 200, "research_share_bp": 5000,
		"era_share_bp": -1, "colonization_share_bp": -1}

	func request_command(id: StringName, args: Dictionary = {}) -> Dictionary:
		commands.append({"id": id, "args": args.duplicate(true)})
		if id == &"procurement.set_policy":
			policy = {
				"treasury_share_bp": int(args.get("treasury_share_bp", 0)),
				"research_share_bp": int(args.get("research_share_bp", 0)),
				"era_share_bp": int(args.get("era_share_bp", -1)),
				"colonization_share_bp": int(args.get("colonization_share_bp", -1)),
			}
		return {"ok": true, "code": "", "message": ""}

	func get_procurement_policy() -> Dictionary:
		return policy.duplicate()


func _init() -> void:
	get_root().size = Vector2i(1280, 720)
	_test_channel_slider_basics()
	_test_ceiling_clamps_drag()
	await _test_fiscal_page_mounts()
	await _test_three_way_sum_constraint()
	await _test_all_paused_copy()
	await _test_commit_carries_four_shares()
	print("=== fiscal channel slider: %d failures ===" % _failures)
	quit(0 if _failures == 0 else 1)


func _expect(label: String, condition: bool) -> void:
	if condition:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		push_error("  [FAIL] %s" % label)


func _test_channel_slider_basics() -> void:
	var slider := ChannelSliderScript.new() as Control
	get_root().add_child(slider)
	slider.size = Vector2(406.0, ChannelSliderScript.CHANNEL_CONDENSED_HEIGHT)
	slider.set_channel_state(2500, 10000000, true, true, 10000)
	_expect("channel slider reads its share as a percentage of national procurement",
		slider.hint_text() == "占国家购买 25%")
	_expect("channel slider converts the share into a daily amount",
		slider.daily_budget() == 2500000
		and slider.display_text() == "每日 %s" % ChannelSliderScript.amount_text(2500000))
	slider.set_channel_state(0, 10000000, true, true, 10000)
	_expect("zero share reads as paused", slider.hint_text() == "未分配，采购暂停"
		and slider.display_text() == "暂停采购" and slider.daily_budget() == 0)
	slider.set_channel_state(2500, 10000000, false, true, 10000)
	_expect("a channel without demand does not claim budget",
		slider.hint_text() == "当前没有待办需求" and slider.daily_budget() == 0)
	slider.set_channel_state(2500, 10000000, true, false, 10000)
	_expect("disabled channel keeps readable copy and drops the amount",
		slider.hint_text() == "暂不可用" and slider.display_text().is_empty())
	slider.set_channel_state(2500, 10000000, true, true, 10000, true)
	_expect("auto-allocated channel says so", slider.hint_text() == "自动分配 25%"
		and slider.is_auto_allocated())
	slider.queue_free()


func _test_ceiling_clamps_drag() -> void:
	var slider := ChannelSliderScript.new() as Control
	get_root().add_child(slider)
	slider.size = Vector2(406.0, ChannelSliderScript.CHANNEL_HEIGHT)
	# 科技 40% + 另一通道 20% 已占用 → 本通道最多 40%。
	slider.set_channel_state(1000, 10000000, true, true, 4000)
	_expect("ceiling narrows the effective range",
		slider.effective_max_bp() == 4000 and slider.max_bp() == 10000)
	var commits: Array = []
	slider.share_committed.connect(func(bp: int) -> void: commits.append(bp))
	var track: Rect2 = slider._track_rect()
	var y: float = track.position.y + 4.0
	_press(slider, Vector2(track.position.x + track.size.x * 0.6, y))
	_move(slider, Vector2(track.end.x + 120.0, y))
	_release(slider, Vector2(track.end.x + 120.0, y))
	_expect("dragging past the ceiling clamps at the remaining allowance",
		commits == [4000] and slider.share_bp() == 4000)
	# 收窄上限时，超出的份额被同步压回去。
	slider.set_ceiling_bp(1500)
	_expect("lowering the ceiling pulls the share down",
		slider.share_bp() == 1500 and slider.effective_max_bp() == 1500)
	slider.set_ceiling_bp(-1)
	_expect("clearing the ceiling restores the full range",
		slider.effective_max_bp() == 10000 and slider.ceiling_bp() == -1)
	slider.queue_free()


func _make_page(controller) -> Control:
	var page := FiscalPageScript.new() as Control
	get_root().add_child(page)
	page.size = Vector2(900.0, 620.0)
	page.set_player_controller(controller)
	return page


func _test_fiscal_page_mounts() -> void:
	var controller := ControllerStub.new()
	var page := _make_page(controller)
	page.set_model(_model({}), true)
	await process_frame
	_expect("fiscal page mounts the national slider", page.national_slider() != null)
	_expect("fiscal page mounts the era channel slider", page.era_slider() != null)
	_expect("fiscal page mounts the colonization channel slider",
		page.colonization_slider() != null)
	_expect("era slider lives in the era section",
		page.era_slider() != null and page.era_slider().get_parent() != null
		and page.era_slider().get_parent() == page.section_body("era"))
	_expect("colonization slider lives in the colonization section",
		page.colonization_slider() != null
		and page.colonization_slider().get_parent()
			== page.section_body("colonization"))
	page.queue_free()


func _test_three_way_sum_constraint() -> void:
	var controller := ControllerStub.new()
	# 科技 60% → 余下两条通道合计最多 40%。
	controller.policy = {"treasury_share_bp": 200, "research_share_bp": 6000,
		"era_share_bp": -1, "colonization_share_bp": -1}
	var page := _make_page(controller)
	page.set_model(_model({"available": true, "policy_enabled": true,
		"treasury_share_bp": 200, "research_share_bp": 6000,
		"national_daily_budget": 20000000, "research_daily_budget": 12000000,
		"other_daily_budget": 8000000, "era_active": true,
		"era_daily_budget": 4000000, "colonization_daily_budget": 4000000,
		"era_share_bp": -1, "colonization_share_bp": -1}), true)
	await process_frame
	var era: Control = page.era_slider()
	var colonization: Control = page.colonization_slider()
	_expect("auto channels show the derived share from the snapshot",
		era.share_bp() == 2000 and era.is_auto_allocated())
	_expect("auto channels are still capped by the research share",
		era.effective_max_bp() == 4000 and colonization.effective_max_bp() == 4000)
	# 手动把开拓设成 30%：时代上限应随之收窄到 10%（100% - 科技 60% - 开拓 30%）。
	controller.policy = {"treasury_share_bp": 200, "research_share_bp": 6000,
		"era_share_bp": -1, "colonization_share_bp": 3000}
	page.refresh_live(_model({"available": true, "policy_enabled": true,
		"treasury_share_bp": 200, "research_share_bp": 6000,
		"national_daily_budget": 20000000, "research_daily_budget": 12000000,
		"other_daily_budget": 8000000, "era_active": true,
		"era_daily_budget": 4000000, "colonization_daily_budget": 6000000,
		"era_share_bp": -1, "colonization_share_bp": 3000}))
	_expect("a manual colonization share narrows the era ceiling",
		era.effective_max_bp() == 1000 and colonization.effective_max_bp() == 4000)
	page.queue_free()


func _test_all_paused_copy() -> void:
	var controller := ControllerStub.new()
	controller.policy = {"treasury_share_bp": 200, "research_share_bp": 0,
		"era_share_bp": 0, "colonization_share_bp": 0}
	var page := _make_page(controller)
	page.set_model(_model({"available": true, "policy_enabled": true,
		"treasury_share_bp": 200, "research_share_bp": 0,
		"national_daily_budget": 20000000, "research_daily_budget": 0,
		"other_daily_budget": 20000000, "era_active": true,
		"era_daily_budget": 0, "colonization_daily_budget": 0,
		"era_share_bp": 0, "colonization_share_bp": 0}), true)
	await process_frame
	_expect("all three shares at zero reads as 全部暂停",
		page.section_value_text("era") == "全部暂停"
		and page.section_value_text("colonization") == "全部暂停")
	var detail := _detail_text(page, "colonization")
	_expect("the paused block explains all three channels stopped",
		detail.contains("三条通道全部暂停采购"))
	page.queue_free()


func _test_commit_carries_four_shares() -> void:
	var controller := ControllerStub.new()
	controller.policy = {"treasury_share_bp": 200, "research_share_bp": 6000,
		"era_share_bp": 2000, "colonization_share_bp": 2000}
	var page := _make_page(controller)
	page.set_model(_model({"available": true, "policy_enabled": true,
		"treasury_share_bp": 200, "research_share_bp": 6000,
		"national_daily_budget": 20000000, "research_daily_budget": 12000000,
		"other_daily_budget": 8000000, "era_active": true,
		"era_daily_budget": 1600000, "colonization_daily_budget": 1600000,
		"era_share_bp": 2000, "colonization_share_bp": 2000}), true)
	await process_frame
	var captured: Array = []
	page.procurement_committed.connect(
		func(treasury: int, research: int, era: int, colonization: int) -> void:
			captured.append({"treasury": treasury, "research": research,
				"era": era, "colonization": colonization}))
	# 真实拖动路径：滑条先把份额挪到新位置，松手再发提交信号。
	page.era_slider().set_channel_state(3500, 20000000, true, true, 4000, false)
	page.era_slider().share_committed.emit(3500)
	_expect("committing a channel emits all four shares",
		captured.size() == 1 and int(captured[0].treasury) == 200
		and int(captured[0].research) == 6000
		and int(captured[0].era) == 3500
		and int(captured[0].colonization) == 2000)
	page.national_slider().policy_committed.emit(400)
	_expect("committing the national share keeps both channel shares",
		captured.size() == 2 and int(captured[1].treasury) == 400
		and int(captured[1].research) == 6000
		and int(captured[1].era) == 3500
		and int(captured[1].colonization) == 2000)
	page.queue_free()


func _detail_text(page: Control, section_id: String) -> String:
	var body := page.section_body(section_id) as VBoxContainer
	if body == null:
		return ""
	for child in body.get_children():
		if child is Label:
			return (child as Label).text
	return ""


func _model(procurement: Dictionary) -> Dictionary:
	return {
		"available": true,
		"country_name": "测试国",
		"current_day": 4,
		"cash": 1000000000,
		"treasury": {"available": true, "cash": 1000000000, "cash_text": "10万",
			"nonzero_good_count": 0, "goods": []},
		"procurement": procurement,
		"military": {"available": false},
	}


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
