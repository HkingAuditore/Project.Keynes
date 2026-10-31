extends SceneTree

## 顶栏国库/人口纸签的悬浮卡回归。
##
## 守住的契约：
##   1) 收支模型与经济卷宗同口径：拆成「收入构成 / 支出构成」两段可读的构成条，
##      净额与结算日一起给出；没有结算数据时给一句说明而不是空白卡；
##   2) 阶层模型按人口排序、按占比折叠「其他阶层」，每行都带满意度与生活档；
##   3) 卡片贴在被悬浮纸签下方，越界时收进视口，放不下就翻到上方；
##   4) 卡片不参与命中测试，不会抢地图点击或打断纸签的 hover；
##   5) 顶栏纸签真的发 hover/press 信号，点击落点由 GameUIManager 决定章节。

const CARD_SCENE := "res://scenes/ui/hud_status_card.tscn"
const BAR_SCENE := "res://scenes/ui/player_top_bar.tscn"
const THEME_PATH := "res://assets/themes/player_session_theme.tres"
const Q16 := 65536.0

var failures := 0
var _hovered: Array = []
var _pressed: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_check_models()
	await _check_card_scene()
	await _check_top_bar_signals()
	print("hud_status_card_test: %s" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)


func _check_models() -> void:
	var treasury := HudStatusViewModel.build_treasury(true, 1234560000, _fiscal_stub())
	_check("国库卡读到币值与结算日",
		String(treasury.get("value", "")) == UITokens.format_compact_number_cn(123456.0, 2)
		and bool(treasury.get("value_money", false))
		and String(treasury.get("meta", "")) == "第 42 日")
	_check("国库卡按收入/支出拆出构成段",
		bool(treasury.get("ok", false))
		and (treasury.income_bar.segments as Array).size() == 2
		and (treasury.expense_bar.segments as Array).size() == 1
		and String(treasury.income_bar.title) == "收入构成"
		and String(treasury.expense_bar.title) == "支出构成")
	_check("国库卡给出净额且方向正确",
		String(treasury.get("net_text", "")).begins_with("+")
		and bool(treasury.get("net_positive", false)))
	var empty_treasury := HudStatusViewModel.build_treasury(false, 0, {})
	_check("没有结算快照时国库卡给说明而不是空白",
		not bool(empty_treasury.get("ok", true))
		and not String(empty_treasury.get("note", "")).is_empty()
		and String(empty_treasury.get("value", "x")) == "—")

	var population := HudStatusViewModel.build_population(
		_professions_stub(), _summary_stub())
	var rows: Array = population.get("rows", [])
	_check("人口卡按人口降序给出职业行并折叠尾部",
		bool(population.get("ok", false)) and rows.size() == 6
		and String(rows[0].id) == "household_farmer"
		and String(rows[0].share_text) == "53%"
		and String(rows[5].id) == "other"
		and String(rows[0].icon) == "profession.household_farmer"
		and bool(rows[5].folded))
	_check("人口卡每行都带满意度与生活档",
		String(rows[0].satisfaction_text) == "80%"
		and String(rows[0].living_text) == "小康"
		and String(rows[0].living_icon) == "population.living.comfortable"
		and String(rows[1].living_text) == "温饱"
		and rows.size() > 1 and rows[0].satisfaction_color is Color)
	_check("人口卡的构成条段数与行数一致",
		(population.share_bar.segments as Array).size() == rows.size())
	_check("人口卡页头给出总人口与国家满意度",
		String(population.get("value", "")) == UITokens.format_compact_number_cn(7550.0, 0)
		and String(population.get("meta", "")) == "满意度 90%")
	var empty_population := HudStatusViewModel.build_population(
		{"ok": false, "reason": "professions_pending"}, {})
	_check("人口快照不可用时给原因而不是空行",
		not bool(empty_population.get("ok", true))
		and String(empty_population.get("note", "")) == "professions_pending"
		and (empty_population.get("rows", []) as Array).is_empty())


func _check_card_scene() -> void:
	root.content_scale_size = Vector2i.ZERO
	root.size = Vector2i(1600, 900)
	var host := Control.new()
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	host.theme = load(THEME_PATH)
	root.add_child(host)
	var card := (load(CARD_SCENE) as PackedScene).instantiate() as HudStatusCard
	_check("悬浮卡场景可以实例化", card != null)
	if card == null:
		host.queue_free()
		return
	host.add_child(card)
	await process_frame

	var treasury := HudStatusViewModel.build_treasury(true, 1234560000, _fiscal_stub())
	card.show_card(treasury, Rect2(16.0, 16.0, 140.0, 50.0))
	await process_frame
	_check("国库卡打开后显示收入/支出两条构成条",
		card.visible and card.kind() == "treasury"
		and (card.get_node("%IncomeBar") as DossierStackedBar).visible
		and (card.get_node("%ExpenseBar") as DossierStackedBar).segment_count() == 1
		and not (card.get_node("%PopulationBody") as Control).visible)
	_check("国库卡页头与页脚文案正确",
		(card.get_node("%ValueLabel") as Label).text
			== UITokens.format_compact_number_cn(123456.0, 2)
		and not (card.get_node("%ValueLabel") as Label).text.contains("¥")
		and (card.get_node("%ValueIcon") as TextureRect).visible
		and (card.get_node("%ValueIcon") as TextureRect).texture == MoneyDisplay.ICON
		and (card.get_node("%MetaLabel") as Label).text == "第 42 日"
		and (card.get_node("%FooterLabel") as Label).text.contains("总览"))
	_check("卡片贴在纸签下方且整张卡落在视口内",
		is_equal_approx(card.position.y, 16.0 + 50.0 + HudStatusCard.ANCHOR_GAP)
		and is_equal_approx(card.position.x, 16.0)
		and card.get_global_rect().end.x <= root.get_visible_rect().size.x
		and card.get_global_rect().end.y <= root.get_visible_rect().size.y)
	await _capture("hud_card_treasury")
	_check("卡片与子控件都不参与命中测试",
		card.mouse_filter == Control.MOUSE_FILTER_IGNORE
		and (card.get_node("%IncomeBar") as Control).mouse_filter == Control.MOUSE_FILTER_IGNORE
		and (card.get_node("Paper") as Control).mouse_filter == Control.MOUSE_FILTER_IGNORE)

	var population := HudStatusViewModel.build_population(
		_professions_stub(), _summary_stub())
	card.show_card(population, Rect2(300.0, 16.0, 110.0, 50.0))
	await process_frame
	var rows: Array = population.get("rows", [])
	var row_host := card.get_node("%StratumRows") as VBoxContainer
	var visible_rows := 0
	for child in row_host.get_children():
		if (child as Control).visible:
			visible_rows += 1
	_check("人口卡切页后只显示职业行",
		card.kind() == "population"
		and (card.get_node("%PopulationBody") as Control).visible
		and not (card.get_node("%TreasuryBody") as Control).visible
		and visible_rows == rows.size() and visible_rows <= row_host.get_child_count())
	_check("人口卡页头不显示金币图标",
		not (card.get_node("%ValueIcon") as TextureRect).visible
		and not (card.get_node("%NetRow") as Control).visible)
	_check("职业行绑定了名称、人口、占比、满意度与生活档",
		(row_host.get_child(0) as HudPopulationRow).get_node("%NameLabel").text \
			== String(rows[0].name)
		and (row_host.get_child(0) as HudPopulationRow).get_node("%People").text \
			== String(rows[0].population_text)
		and (row_host.get_child(0) as HudPopulationRow).get_node("%Share").text \
			== String(rows[0].share_text)
		and (row_host.get_child(0) as HudPopulationRow).get_node("%Satisfaction").text \
			.contains(String(rows[0].satisfaction_text)))
	await _capture("hud_card_population")
	_check("人口卡页脚指向民生章节",
		(card.get_node("%FooterLabel") as Label).text.contains("阶层民生"))

	# 贴到底部时卡片要翻到纸签上方，否则会被视口切掉。
	var viewport_height := root.get_visible_rect().size.y
	card.show_card(population, Rect2(300.0, viewport_height - 60.0, 110.0, 50.0))
	await process_frame
	_check("贴近视口底部时卡片翻到纸签上方",
		card.get_global_rect().end.y <= viewport_height
		and card.position.y < viewport_height - 60.0)
	card.hide_card(true)
	await process_frame
	_check("收卡后不可见且不再报告 kind", not card.visible and card.kind().is_empty())
	host.queue_free()
	await process_frame


func _check_top_bar_signals() -> void:
	root.content_scale_size = Vector2i.ZERO
	var host := Control.new()
	host.theme = load(THEME_PATH)
	host.size = Vector2(1600.0, 200.0)
	root.add_child(host)
	var bar := (load(BAR_SCENE) as PackedScene).instantiate() as PlayerTopBar
	host.add_child(bar)
	bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	bar.offset_bottom = PlayerTopBar.BAR_HEIGHT
	bar.status_hovered.connect(func(kind: String, entered: bool) -> void:
		_hovered.append([kind, entered]))
	bar.status_pressed.connect(func(kind: String) -> void: _pressed.append(kind))
	await process_frame
	bar.set_country_status(1234560000.0, true, 6789, true)
	await process_frame

	(bar.get_node("%TreasuryButton") as Button).mouse_entered.emit()
	(bar.get_node("%TreasuryButton") as Button).mouse_exited.emit()
	(bar.get_node("%TreasuryButton") as Button).pressed.emit()
	(bar.get_node("%PopulationButton") as Button).mouse_entered.emit()
	(bar.get_node("%PopulationButton") as Button).pressed.emit()
	_check("国库纸签发出 hover 与点击信号",
		_hovered.size() >= 2 and _hovered[0] == ["treasury", true]
		and _hovered[1] == ["treasury", false]
		and _pressed.size() >= 1 and _pressed[0] == "treasury")
	_check("人口纸签发出 hover 与点击信号",
		_hovered.size() >= 3 and _hovered[-1] == ["population", true]
		and _pressed[-1] == "population")
	var treasury_anchor := bar.status_anchor("treasury")
	var population_anchor := bar.status_anchor("population")
	_check("纸签矩形可用于定位悬浮卡",
		treasury_anchor.size.x > 0.0 and population_anchor.position.x > treasury_anchor.position.x)
	host.queue_free()
	await process_frame


func _fiscal_stub() -> Dictionary:
	return {
		"ok": true,
		"tax_kinds": PackedStringArray(["income", "consumption", "business", "import", "export"]),
		"collected": PackedInt64Array([5000000, 4000000, 0, 0, 0]),
		"subsidy_paid": PackedInt64Array([0, 0, 1000000, 0, 0]),
		"subsidy_requested": PackedInt64Array([0, 0, 1200000, 0, 0]),
		"tax_base": PackedInt64Array([10000000, 8000000, 0, 0, 0]),
		"sample_day": 41,
	}


func _professions_stub() -> Dictionary:
	return {
		"ok": true,
		"profession_stable_ids": PackedStringArray([
			"household_farmer", "worker", "merchant", "artisan", "scholar",
			"serf", "landlord", "unemployed"]),
		"profession_display_names": PackedStringArray([
			"自耕农", "工人", "商人", "工匠", "学者", "农奴", "地主", "失业者"]),
		"population": PackedInt64Array([4000, 2000, 500, 400, 300, 200, 100, 50]),
		"satisfaction_q16": PackedInt32Array([
			int(0.80 * Q16), int(0.60 * Q16), int(0.90 * Q16), int(0.50 * Q16),
			int(0.70 * Q16), int(0.30 * Q16), int(0.95 * Q16), int(0.20 * Q16)]),
		"living_standard_level_q16": PackedInt32Array([
			int(4 * Q16), int(3 * Q16), int(5 * Q16), int(3 * Q16),
			int(4 * Q16), int(1 * Q16), int(6 * Q16), int(1 * Q16)]),
	}


func _summary_stub() -> Dictionary:
	return {"ok": true, "population": 7550, "satisfaction_q16": int(0.90 * Q16),
		"living_standard_level_q16": int(4 * Q16), "living_standard_level_valid": true}


func _capture(label: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute("res://test_output/hud_status")
	root.get_texture().get_image().save_png("res://test_output/hud_status/%s.png" % label)
	print("[capture] %s" % label)


func _check(label: String, ok: bool) -> void:
	if ok:
		print("[PASS] " + label)
	else:
		failures += 1
		push_error("[FAIL] " + label)
