extends SceneTree

## 纸徽合并速览（国家概况 + 时代晋升，一张纸笺、无滚动）+ 晋升大典。
##   godot --headless --path . --script res://tests/ui/era_advancement_panel_test.gd
## 非 headless 运行时截图到 <repo>/tmp/era_advancement_qa/。

var failures := 0
const STATUSES := ["locked", "ready", "purchasing", "paused", "completing", "max"]
const RuleCatalog = preload("res://scripts/era/era_advancement_catalog.gd")


func _initialize() -> void:
	call_deferred("_run")


## long=true：6 条问题、4 种物资、10 条加成、超长条件文案 —— 用来压版面。
static func _snapshot(status: String, long := false) -> Dictionary:
	var at_max := status == "max"
	var met := 1 if status == "locked" else 3
	var conditions := [
		{"key": "tech", "label": "本时代科技完成 50%", "current": 7, "target": 10,
			"met": status != "locked", "text": "7 / 10 项"},
		{"key": "population", "label": "国家人口", "current": 4200, "target": 3000,
			"met": true, "text": "4200 / 3000 人"},
		{"key": "buildings", "label": "建筑数量", "current": 18, "target": 40,
			"met": false, "text": "18 / 40 座"},
		{"key": "trade", "label": "本时代贸易次数", "current": 66 if status != "locked" else 10,
			"target": 50, "met": status != "locked", "text": "66 / 50 次"},
	]
	if status == "locked":
		conditions[0].current = 4
	if long:
		conditions[0].label = "完成本时代科技的一半（不含里程碑与应用节点）"
		conditions[0].text = "35 / 36 项（共 72 项，需完成 50%）"
	# 与无经济门面时的实机快照一致：name 直接是内部 id，由 VM 回落到中文名。
	var costs := [
		{"good_id": "logs", "name": "logs", "required": 40000, "in_treasury": 40000, "ratio": 1.0},
		{"good_id": "gathered_plants", "name": "gathered_plants", "required": 60000, "in_treasury": 25000, "ratio": 0.42},
		{"good_id": "game_meat", "name": "game_meat ", "required": 30000, "in_treasury": 0, "ratio": 0.0},
	]
	if long:
		costs.append({"good_id": "pottery", "name": "pottery", "required": 98765000,
			"in_treasury": 12345000, "ratio": 0.125})
		costs.append({"good_id": "tools", "name": "", "required": 50000, "in_treasury": 0, "ratio": 0.0})
	var buffs := PackedStringArray(["农业部门产出 +4%", "人口自然死亡率 -4%", "采集产出 +6%",
		"建筑建造效率 +5%", "国内流通效率 +3%", "解锁时代奖励三选一"])
	if long:
		buffs = PackedStringArray()
		for i in range(10):
			buffs.append("第 %d 项时代加成：某某产业产出与效率显著提高 +%d%%" % [i + 1, 5 + i])
	var progress := {"locked": 0.0, "ready": 0.0, "purchasing": 0.45, "paused": 0.62,
		"completing": 1.0, "max": 0.0}
	return {
		"ok": true,
		"current_era_index": 10 if at_max else 0,
		"current_era_name": "智能时代" if at_max else "石器时代",
		"next_era_index": -1 if at_max else 1,
		"next_era_name": "" if at_max else "农耕时代",
		"status": status,
		"conditions": [] if at_max else conditions,
		"conditions_met": 0 if at_max else met,
		"conditions_required": 2,
		"can_start": status == "ready",
		"territory_count": 12,
		"frozen_territory_count": 12 if status in ["purchasing", "paused", "completing"] else 0,
		"costs": [] if at_max else costs,
		"progress": float(progress.get(status, 0.0)),
		"buffs_preview": buffs,
		"budget": {"national_daily": 245000, "era_daily": 61250,
			"treasury_share_bp": 200, "research_share_bp": 5000},
	}


static func _overview(long := false) -> Dictionary:
	var alerts: Array = [
		{"key": "vacancies", "icon": "situation.vacant_jobs", "label": "岗位空缺严重",
			"tooltip": "岗位空缺严重：10.00%"},
	]
	if long:
		alerts = []
		for spec in [["unemployment", "situation.unemployment", "失业率偏高"],
				["survival", "situation.food_shortage", "生存满意度不足"],
				["consumer_shortage", "situation.consumer_shortage", "纺织与消费品短缺"],
				["industrial_shortage", "situation.industry_shortage", "工业物资短缺"],
				["vacancies", "situation.vacant_jobs", "岗位空缺严重"],
				["extra", "situation.food_shortage", "额外的长长长长问题标签"]]:
			alerts.append({"key": spec[0], "icon": spec[1], "label": spec[2],
				"tooltip": "%s：测试提示" % spec[2]})
	return {
		"country_name": "伊斯坦布尔联合王国与海峡诸邦" if long else "测试王国",
		"gdp": "123.45亿" if long else "23.46万", "per_capita_gdp": "34.56",
		"territory": "36", "cpi": "1.50×", "ppi": "1.25×", "satisfaction": "90.0%",
		"living_standard": "4.50级·小康", "alerts": alerts,
		"gdp_tooltip": "年度 GDP：本年累计产值",
	}


func _run() -> void:
	root.mode = Window.MODE_WINDOWED
	root.content_scale_size = Vector2i.ZERO
	root.size = Vector2i(1600, 960)
	var host := Control.new()
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(host)
	var bg := ColorRect.new()
	bg.color = Color(0.22, 0.30, 0.26)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	host.add_child(bg)
	var badge := load("res://scenes/ui/era_indicator.tscn").instantiate() as EraIndicator
	host.add_child(badge)
	var panel: EraAdvancementPanel = load("res://scenes/ui/era_advancement_panel.tscn").instantiate() as EraAdvancementPanel
	host.add_child(panel)
	host.move_child(panel, badge.get_index())
	await process_frame
	badge.set_model({"era_index": 0, "era_id": "stone", "era_name": "石器时代"})
	await _check_panel(panel, badge)
	await _check_fit(panel, badge)
	await _check_view_model()
	await _check_ceremony(host, badge)
	host.queue_free()
	await process_frame
	print("era_advancement_panel_test: %s" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)


static func _has_scroll(node: Node) -> bool:
	if node is ScrollContainer or node is ScrollBar:
		return true
	for child in node.get_children():
		if _has_scroll(child):
			return true
	return false


func _tip(panel: EraAdvancementPanel, needle: String) -> bool:
	# 截断/摘要的全文必须能在分区提示里找到。
	var canvas := panel.get_node("%Canvas") as Control
	for region in canvas.get("_regions"):
		if String(region[1]).contains(needle):
			return true
	return false


func _drawn_has(panel: EraAdvancementPanel, text: String) -> bool:
	return panel.drawn_texts().has(text)


func _drawn_contains(panel: EraAdvancementPanel, needle: String) -> bool:
	for text in panel.drawn_texts():
		if text.contains(needle):
			return true
	return false


func _count_drawn(panel: EraAdvancementPanel, needle: String) -> int:
	var hits := 0
	for text in panel.drawn_texts():
		if text.contains(needle):
			hits += 1
	return hits


func _drawn_count(panel: EraAdvancementPanel, needle: String) -> int:
	var count := 0
	for text in panel.drawn_texts():
		count += text.count(needle)
	return count


func _all_buffs_drawn(panel: EraAdvancementPanel, snapshot: Dictionary) -> bool:
	for buff in snapshot.buffs_preview:
		var found := false
		for text in panel.drawn_texts():
			var shown: String = text.trim_prefix("· ").trim_suffix("…")
			if not shown.is_empty() and String(buff).begins_with(shown):
				found = true
				break
		if not found:
			print("[buffs] missing %s" % buff)
			return false
	return true


## 规则/计数/时代名/状态在整张纸上各出现一次。
func _check_once(panel: EraAdvancementPanel, status: String) -> void:
	await process_frame
	var counts := {
		"规则": _drawn_count(panel, RuleCatalog.CONDITIONS_RULE_TEXT),
		"已满足": _drawn_count(panel, "已满足"),
		"时代晋升": _drawn_count(panel, "时代晋升"),
		"农耕时代": _drawn_count(panel, "农耕时代"),
		"status": _drawn_count(panel, String(panel.model().get("status_chip", "?"))),
	}
	var expected := {"规则": 1, "已满足": 0, "时代晋升": 1, "农耕时代": 1, "status": 1}
	if status == "max":
		expected = {"规则": 0, "已满足": 0, "时代晋升": 1, "农耕时代": 0, "status": 1}
	_check("%s: rule, count, era name and status each drawn exactly once %s" % [status, str(counts)],
		counts == expected)


func _check_panel(panel: EraAdvancementPanel, badge: EraIndicator) -> void:
	var commands: Array[StringName] = []
	panel.command_requested.connect(func(command: StringName) -> void: commands.append(command))
	var action: Button = panel.action_button()
	panel.set_reward_available(true)
	panel.open(_snapshot("locked"), _overview())
	badge.set_expanded(panel.wants_expanded_badge())
	await create_timer(0.35).timeout
	_check("merged sheet opens visible", panel.is_open())
	_check("merged sheet contains no scroll container or scrollbar", not _has_scroll(panel))
	_check("overview data lives in the same sheet (left column)",
		String(panel.overview_model().get("country_name", "")) == "测试王国"
		and _tip(panel, "年度 GDP"))
	_check("pending reward shows a single 领取时代奖励 button",
		(panel.get_node("%RewardLink") as Button).visible)
	_check("locked: start disabled; hint names the nearest missing condition only",
		action.visible and action.text == "开始晋升" and action.disabled
		and panel.action_hint() == "差 22 座建筑" and not panel.action_hint().contains("任选"))
	_check("locked: condition count reads 已满足 1/2",
		String(panel.model().get("conditions_text", "")) == "已满足 1/2")
	await _check_once(panel, "locked")
	_check("condition values use 'n / m 单位'", _drawn_has(panel, "18 / 40 座")
		and _drawn_has(panel, "4200 / 3000 人"))
	_check("cost chips show Chinese names, never ids", _drawn_has(panel, "原木")
		and _drawn_has(panel, "采集植物食物") and _drawn_has(panel, "野味")
		and not _drawn_contains(panel, "logs") and not _drawn_contains(panel, "_"))
	_check("budget readout is not repeated in the sheet (it lives in the treasury panel)",
		not _drawn_contains(panel, "时代收购") and not _drawn_contains(panel, "每日"))
	_check("locked draws no upgrade percentage", not _drawn_contains(panel, "45%"))
	_check("territory note lives only in the kicker tooltip",
		_tip(panel, "12 个地块") and not _drawn_contains(panel, "地块计价")
		and not _drawn_contains(panel, "地块预估"))
	_check("every buff is listed in full, no '等 N 项'", _all_buffs_drawn(panel, _snapshot("locked"))
		and not _drawn_contains(panel, "等 "))
	_check("left column drops the duplicated 当前时代 metric", not _drawn_has(panel, "当前时代"))
	await _capture("merged_locked")

	panel.set_snapshot(_snapshot("ready"))
	_check("ready: start enabled", action.text == "开始晋升" and not action.disabled)
	_check("ready: count clamps to 2/2", String(panel.model().get("conditions_text", "")) == "已满足 2/2")
	action.emit_signal("pressed")
	_check("ready: press emits era.advance.start",
		commands.size() == 1 and commands[0] == &"era.advance.start")
	_check("pressing locks the button until the snapshot changes", action.disabled)
	panel.show_command_result({"ok": false, "code": "x", "message": "条件已失效"})
	_check("rejected command re-enables and shows the reason",
		not action.disabled and panel.action_hint() == "条件已失效")
	panel.show_command_result({"ok": true})
	await _capture("merged_ready")

	panel.set_snapshot(_snapshot("purchasing"))
	_check("purchasing: pause button", action.text == "暂停升级" and not action.disabled)
	_check("purchasing: frozen territory note",
		String(panel.model().get("territory_note", "")) == "按 12 个地块计价")
	await process_frame
	_check("purchasing: status chip carries state and the single percentage", _drawn_has(panel, "升级中 45%")
		and panel.action_hint().is_empty())
	await _check_once(panel, "purchasing")
	_check("purchasing: percentage appears exactly once",
		_count_drawn(panel, "45%") == 1)
	action.emit_signal("pressed")
	_check("purchasing: press emits era.advance.pause", commands.back() == &"era.advance.pause")
	badge.set_advancement("purchasing", 0.45)
	var mat := (badge.get_node("Badge/Icon") as TextureRect).material as ShaderMaterial
	_check("badge gold fill follows procurement progress",
		bool(mat.get_shader_parameter("purchasing"))
		and is_equal_approx(float(mat.get_shader_parameter("progress")), 0.45))
	_check("badge tooltip reports procurement, not milestone research",
		(badge.get_node("Hit") as Button).tooltip_text.contains("收购物资中 · 45%"))
	await create_timer(0.3).timeout
	await _capture("merged_purchasing")

	panel.set_snapshot(_snapshot("paused"))
	_check("paused: resume button", action.text == "继续升级" and not action.disabled)
	action.emit_signal("pressed")
	_check("paused: press emits era.advance.resume", commands.back() == &"era.advance.resume")
	panel.set_snapshot(_snapshot("paused"))
	badge.set_advancement("paused", 0.62)
	_check("badge paused fill is static",
		bool(mat.get_shader_parameter("paused")) and not bool(mat.get_shader_parameter("purchasing")))
	await create_timer(0.3).timeout
	await _capture("merged_paused")

	panel.set_snapshot(_snapshot("completing"))
	_check("completing: button disabled", action.disabled and action.text == "晋升中…")
	await _capture("merged_completing")

	var unfunded := _snapshot("purchasing")
	unfunded.budget = {"national_daily": 0, "era_daily": 0, "treasury_share_bp": 0, "research_share_bp": 0}
	panel.set_snapshot(unfunded)
	var link := panel.get_node("%TreasuryLink") as Button
	var opened := [0]
	panel.treasury_requested.connect(func() -> void: opened[0] += 1)
	link.emit_signal("pressed")
	await process_frame
	_check("zero budget shows a clickable 尚未分配预算 link instead of 0",
		link.visible and link.text.contains("尚未分配预算") and opened[0] == 1
		and not _drawn_has(panel, "时代收购 · 每日 "))
	_check("zero budget link sits in its own row above 晋升后获得 (no overlap)",
		link.visible and link.get_rect().end.y <= panel.buff_head_y())

	panel.set_snapshot(_snapshot("max"))
	_check("max: no action button and no treasury link",
		not action.visible and not link.visible)
	await _check_once(panel, "max")
	await _capture("merged_max")

	panel.set_snapshot({"ok": false})
	_check("unavailable snapshot hides the action", not action.visible)

	var closes := [0]
	panel.close_requested.connect(func() -> void: closes[0] += 1)
	var esc := InputEventAction.new()
	esc.action = &"ui_cancel"
	esc.pressed = true
	panel._input(esc)
	_check("Esc requests close", closes[0] == 1)
	panel.close(true)
	_check("close hides the panel", not panel.visible)


## 全部状态 × 长文本 × 视口 × UI 缩放：纸笺高度固定、落在安全区内、不与纸徽重叠、无滚动。
func _check_fit(panel: EraAdvancementPanel, badge: EraIndicator) -> void:
	var cases := [
		[Vector2i(1280, 720), 1.0], [Vector2i(1920, 1080), 1.0], [Vector2i(1280, 720), 1.25],
	]
	for case in cases:
		var dims: Vector2i = case[0]
		var factor: float = case[1]
		root.size = dims
		root.content_scale_factor = factor
		await create_timer(0.12).timeout
		var view := root.get_visible_rect().size
		var all_ok := true
		var heights := {}
		for status in STATUSES:
			panel.set_reward_available(true)
			panel.open(_snapshot(status, true), _overview(true))
			badge.set_expanded(panel.wants_expanded_badge())
			# 等开合动画（纵向 10px 回弹）结束再量。
			await create_timer(0.25).timeout
			var sheet: Rect2 = panel.sheet_rect()
			heights[roundi(sheet.size.y)] = true
			var badge_bottom: float = (UITokens.ERA_BADGE_OPEN_Y if panel.wants_expanded_badge() \
				else UITokens.ERA_BADGE_REST_Y) + UITokens.ERA_BADGE_SIZE
			var ok: bool = sheet.position.y >= 0.0 and sheet.end.y <= view.y - 8.0 \
				and sheet.position.x >= 0.0 and sheet.end.x <= view.x \
				and sheet.position.y >= badge_bottom and not _has_scroll(panel)
			if not ok:
				print("[fit] %s x%.2f %s sheet=%s view=%s badge_bottom=%.0f" % [dims, factor, status,
					sheet, view, badge_bottom])
			all_ok = all_ok and ok
			if status == "purchasing" and is_equal_approx(factor, 1.0):
				await create_timer(0.25).timeout
				await _capture("merged_long_%dx%d" % [dims.x, dims.y])
		_check("all 6 statuses with long texts fit %s @%.0f%% without scroll" % [dims, factor * 100.0],
			all_ok)
		if heights.size() != 1:
			print("[fit] heights=%s" % str(heights.keys()))
		_check("sheet height is identical for every status %s @%.0f%%" % [dims, factor * 100.0],
			heights.size() == 1)
		if is_equal_approx(factor, 1.0):
			_check("sheet width stays within 760-920 at %s" % dims,
				panel.sheet_rect().size.x >= 760.0 and panel.sheet_rect().size.x <= 920.0)
	_check("long alerts collapse into +N chip with full tooltip", _tip(panel, "额外的长长长长问题标签"))
	panel.open(_snapshot("purchasing", true), _overview(true))
	await process_frame
	_check("5 costs collapse into 3 chips + '+2 种' with tooltip", _tip(panel, "金属工具："))
	_check("10 buffs are all listed (multi-column), none folded",
		_all_buffs_drawn(panel, _snapshot("purchasing", true)))
	_check("truncated long condition keeps its full text in tooltip", _tip(panel, "不含里程碑与应用节点"))
	for status in ["locked", "ready", "purchasing", "paused", "max"]:
		for dims in [Vector2i(1280, 720), Vector2i(1920, 1080)]:
			root.size = dims
			root.content_scale_factor = 1.0
			panel.open(_snapshot(status), _overview())
			badge.set_expanded(panel.wants_expanded_badge())
			badge.set_advancement(status, float(_snapshot(status).progress))
			await create_timer(0.3).timeout
			await _capture("merged_%s_%dx%d" % [status, dims.x, dims.y])
	root.content_scale_factor = 1.0
	root.size = Vector2i(1600, 960)
	panel.close(true)
	badge.set_expanded(false)
	await process_frame


func _check_view_model() -> void:
	var vm := EraIndicatorViewModel.new()
	var model := vm.present_advancement(_snapshot("purchasing"))
	_check("vm formats goods in GOODS_SCALE", String(model.costs[1].required_text) == "60"
		and String(model.costs[1].stock_text) == "25" and String(model.costs[1].value_text) == "25 / 60")
	_check("vm resolves goods icons through IconCatalog",
		StringName(model.costs[0].icon) == IconCatalog.good_semantic("logs"))
	var long_model := vm.present_advancement(_snapshot("purchasing", true))
	var names_ok := true
	for row: Dictionary in long_model.costs:
		names_ok = names_ok and String(row.name) != String(row.good_id) \
			and not String(row.name).contains("_") and not String(row.name).is_empty()
	_check("every cost name is a Chinese display name, not its good_id", names_ok
		and String(long_model.costs[2].name) == "野味" and String(long_model.costs[4].name) == "金属工具")
	_check("delta hint: 2 missing → '还差 2 项条件'", EraIndicatorViewModel.delta_hint("locked",
		[], 0, 2) == "还差 2 项条件")
	_check("vm converts budget from MONEY_SCALE", is_equal_approx(float(model.era_daily), 6.125))
	_check("vm progress is formatted once in the status chip",
		is_equal_approx(float(model.progress), 0.45) and String(model.status_chip).ends_with("45%"))
	_check("vm keeps era ids aligned with era icons",
		String(model.current.id) == "stone" and String(model.next.id) == "agrarian")
	_check("milestone research fields are gone",
		not vm.build({"technology_states": PackedInt32Array([5])}).has("researching"))
	await process_frame


func _check_ceremony(host: Control, badge: EraIndicator) -> void:
	var scene := load("res://scenes/ui/era_ascension_ceremony.tscn") as PackedScene
	# 1) 完整播放：逐帧推进直到自行释放。
	var ceremony := scene.instantiate() as EraAscensionCeremony
	host.add_child(ceremony)
	var landed := [0]
	var finished := [0]
	ceremony.emblem_landed.connect(func() -> void: landed[0] += 1)
	ceremony.finished.connect(func() -> void: finished[0] += 1)
	var buffs := PackedStringArray(["粮食产出 +10%", "定居点人口上限 +15%", "解锁时代奖励三选一"])
	ceremony.play({"old_era_id": "stone", "new_era_id": "agrarian", "new_era_name": "农耕时代",
		"subtitle": EraIndicatorViewModel.era_flavor("agrarian"), "buffs": buffs,
		"target": badge.icon_origin()})
	var total: float = ceremony.total_duration()
	_check("ceremony lasts 6-8 s", total >= 6.0 and total <= 8.0)
	_check("ceremony is modal (stops mouse)", ceremony.mouse_filter == Control.MOUSE_FILTER_STOP)
	_check("cannot skip before 1 s", not ceremony.skip() and ceremony.is_playing())
	var shots := {1.7: "ceremony_burn", 2.35: "ceremony_burst", 3.7: "ceremony_title",
		5.2: "ceremony_buffs", 6.85: "ceremony_flight"}
	var headless := DisplayServer.get_name() == "headless"
	var weak: WeakRef = weakref(ceremony)
	var title_seen := false
	var frames := 0
	var deadline := Time.get_ticks_msec() + 20000
	while weak.get_ref() != null and frames < 2000 and Time.get_ticks_msec() < deadline:
		var step := 1.0 / 30.0
		var before: float = ceremony.elapsed()
		if headless:
			ceremony.set_process(false)
			ceremony.advance(step)
		else:
			await process_frame
		if weak.get_ref() == null:
			break
		var now: float = ceremony.elapsed()
		if now > 4.1 and not title_seen:
			var title := ceremony.get_node("%Title") as Label
			title_seen = title.text == "进入 农耕时代" and title.modulate.a > 0.9
		for mark in shots:
			if before < float(mark) and now >= float(mark):
				await _capture(String(shots[mark]))
		frames += 1 if headless else 0
		if headless:
			await process_frame
	await process_frame
	_check("title reads 进入 农耕时代", title_seen)
	_check("ceremony completes and frees itself", weak.get_ref() == null)
	_check("full play emits landed and finished once", landed[0] == 1 and finished[0] == 1)

	# 2) 跳过：1 秒后点击即直接飞回并收尾。
	var skipped := scene.instantiate() as EraAscensionCeremony
	host.add_child(skipped)
	var skip_landed := [0]
	var skip_finished := [0]
	skipped.emblem_landed.connect(func() -> void: skip_landed[0] += 1)
	skipped.finished.connect(func() -> void: skip_finished[0] += 1)
	skipped.play({"old_era_id": "agrarian", "new_era_id": "kingdom", "new_era_name": "王国时代",
		"buffs": PackedStringArray(), "target": badge.icon_origin()})
	skipped.set_process(false)
	skipped.advance(1.2)
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	skipped._gui_input(click)
	var weak_skip: WeakRef = weakref(skipped)
	var skip_time := 0.0
	while skipped.is_playing() and skip_time < 3.0:
		skipped.advance(1.0 / 30.0)
		skip_time += 1.0 / 30.0
	await process_frame
	_check("click after 1 s skips to the flight and finishes quickly",
		weak_skip.get_ref() == null and skip_time < 1.2)
	_check("skip still lands the emblem on the badge", skip_landed[0] == 1 and skip_finished[0] == 1)

	# 3) Esc 跳过 + 世界切换 abort 不发信号。
	var aborted := scene.instantiate() as EraAscensionCeremony
	host.add_child(aborted)
	var abort_signals := [0]
	aborted.emblem_landed.connect(func() -> void: abort_signals[0] += 1)
	aborted.finished.connect(func() -> void: abort_signals[0] += 1)
	aborted.play({"old_era_id": "kingdom", "new_era_id": "empire", "new_era_name": "帝国时代",
		"buffs": PackedStringArray(["a"]), "target": null})
	aborted.set_process(false)
	aborted.advance(1.5)
	var key := InputEventKey.new()
	key.keycode = KEY_ESCAPE
	key.pressed = true
	aborted._input(key)
	_check("Esc skips after 1 s", aborted.elapsed() >= aborted.total_duration() - FADE_TAIL)
	var weak_abort: WeakRef = weakref(aborted)
	aborted.abort()
	await process_frame
	_check("abort frees without emitting", weak_abort.get_ref() == null and abort_signals[0] == 0)


const FADE_TAIL := 1.5


func _capture(label: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	var absolute := ProjectSettings.globalize_path("res://").path_join("../../tmp/era_advancement_qa").simplify_path()
	DirAccess.make_dir_recursive_absolute(absolute)
	root.get_texture().get_image().save_png(absolute.path_join("%s.png" % label))
	print("[capture] %s -> %s" % [label, absolute])


func _check(label: String, ok: bool) -> void:
	if ok:
		print("[PASS] " + label)
	else:
		failures += 1
		push_error("[FAIL] " + label)
