extends SceneTree

## 财政页的军事预算板块（任务 5 只读 → 任务 9 可编辑）。
##
## 覆盖：三条支出通道以「实付」语义展示、招募集训行展示在训与待装备、
## 「招募本身不拨款」说明常驻、军事快照缺席时整块降级为占位；
## 以及任务 9 的可编辑部分：军事总预算份额 + 三条通道占比滑条、
## 三通道份额之和约束（可拖上限收窄而非事后报错）、高优先级超支与
## 低优先级待购的区分、`set_state` 渲染过程零命令。
##
## godot --headless --path Project/project-keynes \
##   --script res://tests/ui/fiscal_military_block_test.gd

const FiscalPageScript = preload("res://scripts/ui/components/fiscal_budget_page.gd")
const MilitaryBlockScript = preload(
	"res://scripts/ui/components/military_spending_block.gd")
const ChannelSliderScript = preload(
	"res://scripts/ui/components/military_channel_slider.gd")
const ViewModelScript = preload("res://scripts/ui/country_view_model.gd")

var _failures := 0


class ControllerStub extends RefCounted:
	var commands: Array = []
	var policy := {"treasury_share_bp": 200, "research_share_bp": 5000,
		"era_share_bp": -1, "colonization_share_bp": -1}

	func request_command(id: StringName, args: Dictionary = {}) -> Dictionary:
		commands.append({"id": id, "args": args.duplicate(true)})
		return {"ok": true, "code": "", "message": ""}

	func get_procurement_policy() -> Dictionary:
		return policy.duplicate()


func _init() -> void:
	get_root().size = Vector2i(1280, 720)
	_test_view_model_derives_daily_spend()
	_test_view_model_carries_envelope_fields()
	_test_block_renders_three_paid_rows()
	_test_block_shows_training_queue()
	_test_block_degrades_when_unavailable()
	_test_block_renders_budget_sliders()
	_test_channel_ceiling_narrows_with_others()
	_test_overspend_versus_deferred()
	_test_disabled_envelope_reads_as_legacy()
	await _test_fiscal_page_mounts_editable_block()
	await _test_layout_fits_narrow_viewports()
	print("=== fiscal military block: %d failures ===" % _failures)
	quit(0 if _failures == 0 else 1)


func _expect(label: String, condition: bool) -> void:
	if condition:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		push_error("  [FAIL] %s" % label)


## 原生只上报 30 日滑窗累计，视图层统一折成日均；三个通道口径必须相同。
func _test_view_model_derives_daily_spend() -> void:
	var model := ViewModelScript.military_spending_model(_snapshot())
	_expect("military spending model is available with a policy snapshot",
		bool(model.get("available", false)))
	_expect("payroll window folds into a daily figure",
		int(model.get("wage_paid_window", 0)) == 3000000
		and int(model.get("wage_paid_last_period", -1)) == 100000)
	_expect("upkeep window folds into a daily figure",
		int(model.get("maintenance_paid_window", 0)) == 1500000
		and int(model.get("maintenance_paid_last_period", -1)) == 50000)
	_expect("procurement window folds into a daily figure",
		int(model.get("procurement_paid_window", 0)) == 600000
		and int(model.get("procurement_paid_last_period", -1)) == 20000)
	_expect("the window length is reported so the copy can say per day",
		int(model.get("window_days", 0)) == 30)
	_expect("recruitment is explicitly outside the budget envelope",
		not bool(model.get("recruitment_funded", true)))


## 任务 9 的可编辑 UI 靠这组字段工作：份额、日额、结算结果都要在模型里。
func _test_view_model_carries_envelope_fields() -> void:
	var model := ViewModelScript.military_spending_model(_snapshot())
	_expect("the model exposes the envelope switch",
		bool(model.get("envelope_enabled", false)))
	_expect("the model exposes the total share and the three channel shares",
		int(model.get("budget_share_bp", -1)) == 3000
		and int(model.get("budget_wage_bp", -1)) == 5000
		and int(model.get("budget_upkeep_bp", -1)) == 3000
		and int(model.get("budget_procurement_bp", -1)) == 2000)
	_expect("channel ceilings come from the native split",
		int(model.get("wage_budget_daily", -1)) == 900000
		and int(model.get("upkeep_budget_daily", -1)) == 540000
		and int(model.get("procurement_budget_daily", -1)) == 360000)
	_expect("overspend is reported per high-priority channel",
		int(model.get("wage_overspend", -1)) == 120000
		and int(model.get("upkeep_overspend", -1)) == 0)
	_expect("deferred units are reported for the low-priority channel",
		int(model.get("procurement_deferred_units", -1)) == 37)


## 只有训练队列里还没拿到装备的兵才算「待装备」。
func _test_block_shows_training_queue() -> void:
	var model := ViewModelScript.military_spending_model(_snapshot())
	_expect("waiting equipment counts only rows without gear",
		int(model.get("waiting_equipment", -1)) == 140)
	_expect("soldiers in training are reported separately",
		int(model.get("soldiers_training", -1)) == 200)


func _test_block_renders_three_paid_rows() -> void:
	var block := MilitaryBlockScript.new() as Control
	get_root().add_child(block)
	block.set_state(ViewModelScript.military_spending_model(_snapshot()))
	_expect("the block reports itself available", block.is_available())
	_expect("payroll row shows the daily paid amount",
		block.row_text("wage_paid_last_period")
			== MilitaryBlockScript.amount_text(100000))
	_expect("upkeep row shows the daily paid amount",
		block.row_text("maintenance_paid_last_period")
			== MilitaryBlockScript.amount_text(50000))
	_expect("procurement row shows the daily paid amount",
		block.row_text("procurement_paid_last_period")
			== MilitaryBlockScript.amount_text(20000))
	_expect("the block total is the sum of the three rows",
		block.spend_total() == 170000)
	_expect("training row reports both counts",
		block.training_text().contains("在训 200 人")
		and block.training_text().contains("待装备 140 件"))
	_expect("the block spells out that recruitment is not funded",
		block.note_text().contains("招募本身不拨款"))
	block.queue_free()


## 没有军事政策时整块降级：不显示 0 值行，避免被读成"这些通道不花钱"。
func _test_block_degrades_when_unavailable() -> void:
	var block := MilitaryBlockScript.new() as Control
	get_root().add_child(block)
	var model := ViewModelScript.military_spending_model(
		{"ok": true, "has_policy": false})
	_expect("a snapshot without policy yields an unavailable model",
		not bool(model.get("available", true)))
	block.set_state(model)
	_expect("unavailable block keeps a readable placeholder",
		not block.empty_text().is_empty() and not block.is_available())
	_expect("unavailable block shows no spend rows at all",
		block.spend_total() == 0)
	block.queue_free()


## 任务 9 主体：四项滑条都要在，且读数与原生份额一致。
func _test_block_renders_budget_sliders() -> void:
	var block := MilitaryBlockScript.new() as Control
	get_root().add_child(block)
	block.set_state(ViewModelScript.military_spending_model(_snapshot()))
	var envelope = block.envelope_slider()
	_expect("the block mounts the military envelope slider", envelope != null)
	_expect("the envelope slider shows the native total share",
		envelope != null and int(envelope.share_bp()) == 3000)
	_expect("the envelope slider is editable with a player session",
		envelope != null and envelope.is_interactive())
	for channel_id in ["wage", "upkeep", "procurement"]:
		_expect("the block mounts the %s channel slider" % channel_id,
			block.channel_slider(channel_id) != null)
	_expect("the three channel shares sum to the native total",
		block.channel_share_total() == 10000)
	_expect("the envelope reads the daily ceiling from the split",
		envelope != null and int(envelope.daily_envelope()) == 1800000)
	_expect("budget total is the sum of the three channel ceilings",
		block.budget_total() == 1800000)
	block.queue_free()


## 三项之和 <= 100%：拖到边缘就停住，而不是提交后才报错。
## 用一份份额只占 70% 的配置，才能看出上限真在按另两项收窄。
func _test_channel_ceiling_narrows_with_others() -> void:
	var block := MilitaryBlockScript.new() as Control
	get_root().add_child(block)
	var snapshot := _snapshot()
	snapshot["budget_wage_bp"] = 4000
	snapshot["budget_upkeep_bp"] = 2000
	snapshot["procurement_share_bp"] = 1000
	block.set_state(ViewModelScript.military_spending_model(snapshot))
	var wage = block.channel_slider("wage")
	var upkeep = block.channel_slider("upkeep")
	var procurement = block.channel_slider("procurement")
	# 上限 = 100% - 另两项：军饷 10000-2000-1000=7000，维护 10000-4000-1000=5000，
	# 采购 10000-4000-2000=4000。三条都留出了正好等于"剩余额度"的空间。
	_expect("the wage ceiling leaves exactly the remaining room",
		wage != null and int(wage.effective_max_bp()) == 7000)
	_expect("the upkeep ceiling leaves exactly the remaining room",
		upkeep != null and int(upkeep.effective_max_bp()) == 5000)
	_expect("the procurement ceiling leaves exactly the remaining room",
		procurement != null and int(procurement.effective_max_bp()) == 4000)
	# 三项上限都到达时之和恰为 200%：这是"每项都能独自吃掉余额"的正确含义，
	# 约束靠同时只能有一个在拖来保证，不必让三者上限互斥。
	_expect("shares never exceed the envelope as reported",
		block.channel_share_total() == 7000)
	block.queue_free()
	block.queue_free()


## 高优先级超支画铁锈红 + 超支标签；低优先级只报待购，绝不画超支。
func _test_overspend_versus_deferred() -> void:
	var block := MilitaryBlockScript.new() as Control
	get_root().add_child(block)
	var model := ViewModelScript.military_spending_model(_snapshot())
	block.set_state(model)
	var wage = block.channel_slider("wage")
	_expect("a high-priority channel over its share is flagged",
		wage != null and wage.is_overspent())
	_expect("a high-priority channel at its share is not flagged",
		block.channel_slider("upkeep") != null
		and not block.channel_slider("upkeep").is_overspent())
	var procurement = block.channel_slider("procurement")
	_expect("the low-priority channel never reports overspend",
		procurement != null and not procurement.is_overspent())
	_expect("the low-priority channel reports the deferred shortfall instead",
		procurement != null and procurement.has_deferred())
	_expect("the deferred wording says 待购 rather than 超支",
		block.channel_note("procurement").contains("待购")
		and not block.channel_note("procurement").contains("超支"))
	_expect("the overspend wording names the overspent amount",
		block.channel_note("wage").contains("超支"))
	_expect("the summary names both the envelope and the shortfall",
		block.summary_text().contains("每日信封")
		and block.summary_text().contains("待购"))
	block.queue_free()


## `budget_share_bp <= 0` 是「没有信封」，不是「军费归零」：读数必须说清楚，
## 且三条通道滑条不可拖（否则玩家会以为拖了有效）。
func _test_disabled_envelope_reads_as_legacy() -> void:
	var block := MilitaryBlockScript.new() as Control
	get_root().add_child(block)
	var snapshot := _snapshot()
	snapshot["budget_enabled"] = false
	snapshot["budget_share_bp"] = 0
	snapshot["budget_envelope_daily"] = 0
	snapshot["budget_wage_daily"] = -1
	snapshot["budget_upkeep_daily"] = -1
	snapshot["budget_procurement_daily"] = -1
	block.set_state(ViewModelScript.military_spending_model(snapshot))
	_expect("an absent envelope is not reported as an enabled one",
		not block.is_envelope_enabled())
	_expect("the summary explains the legacy cash-driven path",
		block.summary_text().contains("未启用"))
	_expect("channel sliders are locked without an envelope",
		block.channel_slider("wage") != null
		and not block.channel_slider("wage").is_interactive())
	_expect("the envelope slider still reads zero rather than hiding",
		block.envelope_slider() != null
		and int(block.envelope_slider().share_bp()) == 0)
	_expect("no budget total is claimed without an envelope",
		block.budget_total() == 0)
	block.queue_free()


func _test_fiscal_page_mounts_editable_block() -> void:
	var controller := ControllerStub.new()
	var page := FiscalPageScript.new() as Control
	get_root().add_child(page)
	page.size = Vector2(900.0, 620.0)
	page.set_player_controller(controller)
	page.set_model(_page_model(), true)
	await process_frame
	var block: Control = page.military_block()
	_expect("the fiscal page mounts the military block",
		block != null and block.get_parent() != null)
	_expect("the military block lives in the military section",
		block != null and block.get_parent() == page.section_body("military"))
	_expect("the military block feeds on the model",
		block != null and block.is_available()
		and block.row_text("wage_paid_last_period")
			== MilitaryBlockScript.amount_text(100000))
	_expect("the section header reads the daily envelope",
		page.section_value_text("military") == "180/日")
	_expect("the envelope slider is live on the fiscal page",
		block != null and block.envelope_slider() != null
		and block.envelope_slider().is_interactive())
	var detail := _detail_text(page, "military")
	_expect("the section note names all three channel ceilings",
		detail.contains("每日信封") and detail.contains("军饷")
		and detail.contains("维护") and detail.contains("采购"))
	# 渲染过程零命令：只有玩家提交滑条时才发 military.policy.set_budget。
	_expect("rendering the block issues no command at all",
		controller.commands.is_empty())
	# 玩家拖完松手：板块发意图，财政页原样转发，-1 不得被折成 0。
	var forwarded: Array = []
	page.military_budget_committed.connect(func(total: int, wage: int, upkeep: int,
			procurement: int) -> void:
		forwarded.append([total, wage, upkeep, procurement]))
	block.budget_committed.emit(4000, -1, -1, -1)
	await process_frame
	_expect("the page forwards exactly one budget intent",
		forwarded.size() == 1)
	if forwarded.size() == 1:
		var payload: Array = forwarded[0]
		_expect("the total share is forwarded unchanged",
			int(payload[0]) == 4000)
		_expect("untouched channels stay -1 instead of being zeroed",
			int(payload[1]) == -1 and int(payload[2]) == -1 and int(payload[3]) == -1)
	# 单通道提交必须带上当前总份额，否则原生会把它当成"总份额不改"以外的语义。
	forwarded.clear()
	block.budget_committed.emit(int(block.envelope_slider().share_bp()), 4500, -1, -1)
	await process_frame
	if forwarded.size() == 1:
		var payload: Array = forwarded[0]
		_expect("a channel commit carries the current total share",
			int(payload[0]) == 3000 and int(payload[1]) == 4500
			and int(payload[2]) == -1)
	_expect("forwarding still issues no command by itself",
		controller.commands.is_empty())
	page.queue_free()


func _test_layout_fits_narrow_viewports() -> void:
	await _run_layout_probe(Vector2i(1280, 720))
	# 手机横屏：逻辑高 873 一档，宽度按 20:9 折算约 1940 物理像素。
	await _run_layout_probe(Vector2i(1664, 786))


func _run_layout_probe(viewport_size: Vector2i) -> void:
	get_root().size = viewport_size
	var controller := ControllerStub.new()
	var page := FiscalPageScript.new() as Control
	get_root().add_child(page)
	page.set_size(Vector2(viewport_size))
	page.set_player_controller(controller)
	page.set_model(_page_model(), true)
	await process_frame
	await process_frame
	var block: Control = page.military_block()
	var scroll: ScrollContainer = page.get("_scroll")
	var limit := scroll.get_global_rect().end.x + 0.5
	_expect("the military block fits inside %dx%d" % [viewport_size.x, viewport_size.y],
		block != null and block.get_global_rect().end.x <= limit)
	if block != null:
		_expect("the envelope slider fits inside %dx%d" % [
			viewport_size.x, viewport_size.y],
			block.envelope_slider().get_global_rect().end.x <= limit)
		for channel_id in ["wage", "upkeep", "procurement"]:
			var slider = block.channel_slider(channel_id)
			_expect("the %s slider fits inside %dx%d" % [
				channel_id, viewport_size.x, viewport_size.y],
				slider != null and slider.get_global_rect().end.x <= limit)
	_expect("the fiscal page scrolls vertically at %dx%d" % [
		viewport_size.x, viewport_size.y],
		scroll.horizontal_scroll_mode == ScrollContainer.SCROLL_MODE_DISABLED)
	page.queue_free()
	await process_frame


func _detail_text(page: Control, section_id: String) -> String:
	var body := page.section_body(section_id) as VBoxContainer
	if body == null:
		return ""
	for child in body.get_children():
		if child is Label:
			return (child as Label).text
	return ""


## 财政页的最小可用模型：四个分区都要有数据，否则板块会互相挤压。
func _page_model() -> Dictionary:
	return {
		"available": true,
		"country_name": "测试国",
		"current_day": 4,
		"cash": 1000000000,
		"treasury": {"available": true, "cash": 1000000000, "cash_text": "10万",
			"nonzero_good_count": 0, "goods": []},
		"procurement": {"available": true, "policy_enabled": true,
			"treasury_share_bp": 200, "research_share_bp": 5000,
			"national_daily_budget": 20000000, "research_daily_budget": 10000000,
			"other_daily_budget": 10000000, "era_daily_budget": 5000000,
			"colonization_daily_budget": 5000000, "era_active": true,
			"era_share_bp": -1, "colonization_share_bp": -1},
		"military": ViewModelScript.military_spending_model(_snapshot()),
	}


## 军事国家快照的裁剪版：只放板块真正消费的字段，其余留空。
##
## 信封按 3% / 国库 60000000（MONEY_SCALE）算：信封 1800000，
## 三条通道 50% / 30% / 20% → 900000 / 540000 / 360000。
## 军饷实付 100000/日，但上一轮需求 1020000 超过了 900000 的份额 → 超支 120000。
## 采购被配额截断 37 件 → 待购。
func _snapshot() -> Dictionary:
	return {
		"ok": true,
		"has_policy": true,
		"procurement_share_bp": 2000,
		"spend_payroll_30": 3000000,
		"spend_upkeep_30": 1500000,
		"spend_procurement_30": 600000,
		"soldiers_training": 200,
		"training": [
			{"equipment_ready": false, "count": 140},
			{"equipment_ready": true, "count": 60},
		],
		"budget_enabled": true,
		"budget_share_bp": 3000,
		"budget_wage_bp": 5000,
		"budget_upkeep_bp": 3000,
		"budget_envelope_daily": 1800000,
		"budget_wage_daily": 900000,
		"budget_upkeep_daily": 540000,
		"budget_procurement_daily": 360000,
		"budget_wage_demand": 1020000,
		"budget_wage_arrears": 0,
		"budget_wage_overspend": 120000,
		"budget_upkeep_demand": 540000,
		"budget_upkeep_arrears": 0,
		"budget_upkeep_overspend": 0,
		"budget_procurement_used": 360000,
		"budget_procurement_deferred_units": 37,
	}
