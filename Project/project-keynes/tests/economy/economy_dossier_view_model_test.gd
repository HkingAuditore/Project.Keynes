extends "res://tests/economy/economy_rolling_runtime_test.gd"

## 国民经济卷宗展示层：阶层映射覆盖、卡点归类规则、各章模型与原生聚合一致、
## 趋势缓冲去重与裁剪、自绘组件可构造。


class FakeEconomyFacade:
	extends RefCounted
	var runtime: Object
	var catalog: Dictionary

	func country_economy_overview(handle: int, view: String = "summary", scope: int = -1,
			filter_id: int = -1, offset: int = 0, limit: int = 0) -> Dictionary:
		var page: Dictionary = runtime.get_country_economy_overview(
			handle, view, scope, filter_id, offset, limit)
		for pair in [["profession_stable_ids", "profession_display_names"],
				["building_stable_ids", "building_display_names"],
				["good_stable_ids", "good_display_names"], ["need_ids", "need_display_names"]]:
			if page.has(pair[0]):
				page[pair[1]] = page[pair[0]]
		return page

	func country_trade_snapshot(_handle: int, _view: String, _offset: int, _limit: int) -> Dictionary:
		return {"ok": false, "reason": "trade_off"}

	func profession_ids() -> PackedStringArray:
		return catalog.get("profession_ids", PackedStringArray())

	func building_display_name(index: int) -> String:
		var ids: PackedStringArray = catalog.get("building_type_ids", PackedStringArray())
		return String(ids[index]) if index >= 0 and index < ids.size() else str(index)

	func good_display_name(index: int) -> String:
		var ids: PackedStringArray = catalog.get("good_ids", PackedStringArray())
		return String(ids[index]) if index >= 0 and index < ids.size() else str(index)


var _scene_args: Array = []


func _init() -> void:
	_run()
	if not _scene_args.is_empty():
		await process_frame
		await _check_dossier_scene(_scene_args[0], _scene_args[1])
	print("=== economy dossier view model %s ===" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)


func _run() -> void:
	_check_strata_table()
	_check_bottleneck_rules()
	_check_cashflow()
	_check_price_and_living()
	_check_history_buffer()
	_check_components()
	_check_runtime_models()


func _check_strata_table() -> void:
	var table := SocialStrataTable.load_default()
	_expect("strata table loads", table != null)
	if table == null:
		return
	_expect("eight display strata", table.stratum_count() == 8)
	var ids := PackedStringArray()
	for path in ResourceLoader.list_directory(EconomyCatalogScript.PROFESSION_DIR):
		if path.get_extension() != "tres":
			continue
		var resource = load("%s/%s" % [EconomyCatalogScript.PROFESSION_DIR, path])
		if resource != null and String(resource.get("id")) != "":
			ids.append(String(resource.id))
	_expect("profession catalog non-empty", ids.size() >= 40)
	var unmapped := table.unmapped(ids)
	_expect("every profession maps to a stratum (unmapped: %s)" % ", ".join(unmapped),
		unmapped.is_empty())
	var seen := {}
	var duplicates := PackedStringArray()
	for index in range(table.stratum_count()):
		for profession in table.stratum(index).get("professions", []):
			if seen.has(String(profession)):
				duplicates.append(String(profession))
			seen[String(profession)] = true
	_expect("no profession listed in two strata (%s)" % ", ".join(duplicates), duplicates.is_empty())
	_expect("unknown profession falls back", table.stratum_index_for("___none___")
		== table.index_of(table.fallback_stratum))
	for index in range(table.stratum_count()):
		var icon := StringName(table.stratum(index).get("icon", ""))
		_expect("stratum %s icon resolves" % table.stratum_id(index),
			IconCatalog.has_icon(icon))
	for chapter in EconomyDossierViewModel.CHAPTERS:
		_expect("chapter %s icon resolves" % chapter.id, IconCatalog.has_icon(chapter.icon))


func _check_bottleneck_rules() -> void:
	var summary := {"building_units": 100, "wages_due_per_day": 1000, "wages_paid_per_day": 600,
		"job_capacity": 200, "job_openings": 10, "output_per_day": 100, "discarded_per_day": 0,
		"climate_lost_per_day": 0, "building_suspended_units": 0}
	var histogram := PackedInt64Array()
	histogram.resize(19)
	histogram[11] = 30
	histogram[6] = 5
	histogram[4] = 90
	histogram[14] = 80
	var investment := {"ok": true, "rejection_units": histogram}
	var result := EconomyDossierViewModel.classify_bottlenecks(summary, investment, {"ok": false})
	_expect("bottlenecks ranked", not result.is_empty())
	if result.is_empty():
		return
	_expect("arrears 40%% makes capital the top bottleneck", String(result[0].id) == "capital")
	var ids := PackedStringArray()
	for entry in result:
		ids.append(String(entry.id))
	_expect("sufficient capacity / random miss are not bottlenecks",
		not ids.has("") and result.size() <= EconomyDossierViewModel.MAX_BOTTLENECKS)
	_expect("labor bottleneck from openings", ids.has("labor"))
	_expect("demand bottleneck from sell-through rejection", ids.has("demand"))
	for i in range(1, result.size()):
		_expect("severity is descending", float(result[i - 1].severity) >= float(result[i].severity))
	var shortages := PackedInt32Array([int(0.6 * 65536.0), 0])
	var goods := {"ok": true, "shortage_q16": shortages,
		"good_stable_ids": PackedStringArray(["grain", "cloth"]),
		"good_display_names": PackedStringArray(["粮食", "布"]),
		"demand_ema": PackedInt64Array([100, 100])}
	var with_goods := EconomyDossierViewModel.classify_bottlenecks({"building_units": 10}, {}, goods)
	_expect("severe shortage becomes input bottleneck",
		with_goods.size() == 1 and String(with_goods[0].id) == "input"
		and not (with_goods[0].details as Array).is_empty()
		and String(with_goods[0].details[0]).contains("粮食"))
	_expect("healthy economy has no bottleneck", EconomyDossierViewModel.classify_bottlenecks(
		{"building_units": 10, "output_per_day": 50}, {"ok": true,
		"rejection_units": PackedInt64Array()}, {"ok": true}).is_empty())
	_expect("rejection category table covers 19 reasons",
		EconomyDossierViewModel.REJECTION_CATEGORY.size() == 19
		and EconomyDossierViewModel.REJECTION_LABELS.size() == 19)


func _check_history_buffer() -> void:
	var history := EconomyHistoryBuffer.new()
	history.reset(7)
	for day in range(EconomyHistoryBuffer.CAPACITY + 15):
		history.record(day, {"population": float(day)}, [{"satisfaction": 0.5}])
	history.record(3, {"population": -1.0})
	_expect("history trims to capacity", history.size() == EconomyHistoryBuffer.CAPACITY)
	_expect("history ignores stale days", history.latest_day() == EconomyHistoryBuffer.CAPACITY + 14)
	_expect("history delta", is_equal_approx(history.delta("population", 7), 7.0))
	_expect("stratum series aligned with days",
		history.stratum_series(0, "satisfaction").size() == history.size())
	history.reset(8)
	_expect("history reset clears", history.size() == 0 and is_nan(history.delta("population")))


## 国库收支：合计只算非零项，明细表则五类税种全列，零值写成短横线。
func _check_cashflow() -> void:
	var missing: Dictionary = EconomyDossierViewModel.build_cashflow({})
	_expect("cashflow degrades without a fiscal snapshot",
		not bool(missing.get("ok", true)) and (missing.detail_rows as Array).is_empty())
	var snapshot := {
		"ok": true, "sample_day": 41,
		"tax_kinds": PackedStringArray([
			"income", "consumption", "business", "import", "export"]),
		"collected": PackedInt64Array([500000, 120000, 30000, 0, 0]),
		"subsidy_paid": PackedInt64Array([0, 0, 40000, 0, 0]),
		"subsidy_requested": PackedInt64Array([0, 0, 50000, 0, 0]),
		"tax_base": PackedInt64Array([5000000, 2400000, 900000, 0, 0]),
	}
	var flow: Dictionary = EconomyDossierViewModel.build_cashflow(snapshot)
	_expect("cashflow ok", bool(flow.get("ok", false)))
	var rows: Array = flow.detail_rows
	_expect("cashflow details list all five tax kinds", rows.size() == 5)
	_expect("cashflow details name the kinds in native order",
		String(rows[0].cells.name.text) == "所得税"
			and String(rows[3].cells.name.text) == "进口关税")
	_expect("cashflow details blank out unused kinds",
		String(rows[3].cells.collected.text) == "—"
			and String(rows[3].cells.base.text) == "—")
	_expect("cashflow details keep the levied kinds",
		String(rows[0].cells.collected.text) == "50"
			and String(rows[2].cells.paid.text) == "4")
	_expect("cashflow totals and net reconcile",
		is_equal_approx(float(flow.income_total), 65.0)
			and is_equal_approx(float(flow.expense_total), 4.0)
			and is_equal_approx(float(flow.net), 61.0))
	_expect("cashflow formats the signed net", String(flow.net_text) == "+61"
		and bool(flow.net_positive))
	_expect("cashflow day text follows the settlement sample day",
		String(flow.day_text) == "第 42 日")
	var income_segments: Array = flow.income_segments
	var expense_segments: Array = flow.expense_segments
	_expect("cashflow stacks only the levied tax kinds, largest first",
		income_segments.size() == 3 and String(income_segments[0].label) == "所得税"
			and String(income_segments[2].label) == "营业税")
	_expect("cashflow stacks only the paid subsidy kinds",
		expense_segments.size() == 1
			and String(expense_segments[0].label) == "营业补贴")
	_expect("cashflow stack shares sum to the side total",
		is_equal_approx(float(income_segments[0].value)
			+ float(income_segments[1].value) + float(income_segments[2].value), 65.0))
	var spent: Dictionary = EconomyDossierViewModel.build_cashflow({
		"ok": true, "sample_day": 3,
		"tax_kinds": PackedStringArray(["income"]),
		"collected": PackedInt64Array([0]),
		"subsidy_paid": PackedInt64Array([250000]),
	})
	_expect("cashflow reports a deficit when only subsidies are paid",
		is_equal_approx(float(spent.net), -25.0) and not bool(spent.net_positive)
			and String(spent.net_text) == "−25")
	# 非税国库支出（科研采购、开拓采购、工程、运河）都不是税种，却真实减少国库
	# 现金，必须进支出侧与净额；否则国库现金在掉，账面净额却还是零。
	var buying: Dictionary = EconomyDossierViewModel.build_cashflow({
		"ok": true, "sample_day": 5,
		"tax_kinds": PackedStringArray([
			"income", "consumption", "business", "import", "export"]),
		"collected": PackedInt64Array([100000, 0, 0, 0, 0]),
		"subsidy_paid": PackedInt64Array([0, 0, 0, 0, 0]),
		"non_tax_outflow_kinds": PackedStringArray([
			"research_purchase", "expedition_procurement", "construction", "canal"]),
		"non_tax_outflow": PackedInt64Array([60000, 30000, 0, 10000]),
	})
	_expect("cashflow counts non-tax outflows as treasury expense",
		is_equal_approx(float(buying.expense_total), 10.0)
			and is_equal_approx(float(buying.net), 0.0))
	_expect("cashflow stacks each non-tax outflow as its own segment",
		(buying.expense_segments as Array).size() == 3
			and String(buying.expense_segments[0].label) == "科研采购"
			and String(buying.expense_segments[1].label) == "开拓采购"
			and String(buying.expense_segments[2].label) == "运河支出")
	_expect("cashflow details expose the non-tax rows after the tax ledger",
		(buying.detail_rows as Array).size() == 8
			and String(buying.detail_rows[5].cells.name.text) == "科研采购"
			and String(buying.detail_rows[5].cells.paid.text) == "6"
			and String(buying.detail_rows[6].cells.name.text) == "开拓采购"
			and String(buying.detail_rows[7].cells.name.text) == "运河支出")
	# 零额的非税项不占行：它们不是税种，写一行零值只会被读成漏税。
	_expect("cashflow skips zero non-tax outflows",
		not (buying.detail_rows as Array).any(func(row: Dictionary) -> bool:
			return String(row.get("id", "")) == "construction"))
	_expect("cashflow keeps the tax-only ledger when nothing was purchased",
		rows.size() == 5)


## 物价指数是相对成本锚的偏离：100 = 成本锚，裂口 = CPI − PPI。
func _check_price_and_living() -> void:
	var summary := {
		"ok": true,
		"consumer_price_index_q16": int(1.05 * 65536.0),
		"consumer_price_index_valid": true,
		"producer_price_index_q16": int(0.96 * 65536.0),
		"producer_price_index_valid": true,
		"living_standard_level_q16": int(2.5 * 65536.0),
		"living_standard_level_valid": true,
	}
	var price: Dictionary = EconomyDossierViewModel.price_model(summary)
	_expect("price model reads both indices", (price.rows as Array).size() == 2
		and String(price.rows[0].label) == "CPI" and String(price.rows[1].label) == "PPI")
	_expect("price model formats the index", absf(float(price.rows[0].index) - 105.0) < 0.01
		and String(price.rows[0].text) == "105.0")
	_expect("price model reports the CPI - PPI spread",
		absf(float(price.spread) - 9.0) < 0.01)
	summary["producer_price_index_valid"] = false
	var partial: Dictionary = EconomyDossierViewModel.price_model(summary)
	_expect("invalid index shows a dash instead of a zero",
		not bool(partial.rows[1].valid) and String(partial.rows[1].text) == "—"
			and is_nan(float(partial.spread)))
	var living: Dictionary = EconomyDossierViewModel.living_standard_model(summary)
	_expect("living standard maps the Q16 level onto a named rung",
		bool(living.get("ok", false)) and is_equal_approx(float(living.level), 2.5)
			and String(living.name) == "贫困" and String(living.text) == "2.5")
	_expect("living standard reports invalid when the summary has none",
		not bool(EconomyDossierViewModel.living_standard_model({"ok": true}).ok))


func _check_components() -> void:
	var kpi := DossierKpiCard.new()
	kpi.set_metric({"id": "x", "title": "人口", "value": 1234.0, "kind": "count",
		"positive_good": true, "caption": "c", "icon": &"family.metric.population",
		"spark": PackedFloat32Array([1, 2, 3]), "delta": 1.0})
	_expect("kpi formats value", not kpi.value_text().is_empty())
	var stacked := ChartAdapter.make_dossier_stacked_bar("收入", [
		{"label": "工资", "value": 2.0, "color": Color.RED, "text": "2"}], "2")
	var bars := ChartAdapter.make_dossier_bar_list([{"id": 1, "label": "a", "value": 0.5,
		"text": "50%"}], false, true)
	_expect("bar list rows", bars.row_count() == 1)
	var radar := ChartAdapter.make_dossier_radar(PackedStringArray(["a", "b", "c"]),
		PackedFloat32Array([0.1, 0.5, 0.9]), PackedFloat32Array([0.5, 0.5, 0.5]))
	var ledger := ChartAdapter.make_dossier_ledger([
		{"id": "name", "label": "名称", "kind": "text", "expand": true},
		{"id": "value", "label": "数值", "kind": "number", "width": 80.0},
		{"id": "go", "label": "", "kind": "actions", "width": 40.0, "sortable": false},
	], [
		{"id": "a", "cells": {"name": {"text": "甲"}, "value": {"text": "1", "value": 1.0}},
			"actions": [{"id": "locate", "icon": &"metric.territory", "tooltip": "定位"}]},
		{"id": "b", "cells": {"name": {"text": "乙"}, "value": {"text": "3", "value": 3.0}}},
		{"id": "c", "cells": {"name": {"text": "丙"}, "value": {"text": "2", "value": 2.0}}},
	], "value")
	_expect("ledger sorts descending by default", ledger.sorted_ids() == ["b", "c", "a"])
	var heat := DossierHeatGrid.new()
	heat.set_cells([{"id": "food", "name": "食品"}], [{"id": "grain", "name": "粮", "group": "food",
		"heat": 0.4, "price_index": 1.2}])
	_expect("heat grid cells", heat.cell_count() == 1)
	var nav := DossierChapterNav.new()
	nav.set_chapters(EconomyDossierViewModel.CHAPTERS, "overview")
	_expect("chapter nav current", nav.current == "overview")
	var ring := DossierRingGauge.new()
	ring.set_gauge("labor", "劳动力", 0.4, "空缺", UITokens.DOSSIER_OXBLOOD, "")
	var diverging := DossierDivergingBar.new()
	diverging.set_values("进口", 1.0, "1", "出口", 2.0, "2")
	var trend := DossierTrendLines.new()
	trend.set_series(PackedFloat32Array([1.0, 2.0, 3.0]),
		PackedFloat32Array([0.5, NAN, 1.0]), "+2", true)
	var ladder := DossierLevelLadder.new()
	ladder.set_level(2.5, 6, "贫困")
	var axis := DossierDeviationAxis.new()
	axis.set_indices([{"label": "CPI", "index": 105.0, "valid": true, "text": "105.0"},
		{"label": "PPI", "index": 96.0, "valid": true, "text": "96.0"}])
	var spark_value := DossierSparkValue.new()
	spark_value.set_value({"value": 1.5, "delta": 0.2, "spark": PackedFloat32Array([1.0, 1.2, 1.5]),
		"kind": "money"})
	_expect("trend lines track the daily series", trend.day_count() == 3)
	_expect("level ladder keeps its continuous level", is_equal_approx(ladder.level(), 2.5))
	_expect("deviation axis keeps both indices", axis.row_count() == 2)
	_expect("spark value formats the reading", spark_value.value_text() == "1.5")
	for control in [kpi, stacked, bars, radar, ledger, heat, nav, ring, diverging,
			trend, ladder, axis, spark_value]:
		(control as Node).free()


## 整页场景：每章都能用真实聚合刷新；切章、切范围、反复刷新不重建节点。
func _check_dossier_scene(model: Dictionary, city_cell: int) -> void:
	var scene: PackedScene = load("res://scenes/ui/economy_dossier.tscn")
	var dossier := scene.instantiate() as EconomyDossier
	_expect("dossier scene instantiates", dossier != null)
	if dossier == null:
		return
	root.add_child(dossier)
	await process_frame
	dossier.set_anchors_preset(Control.PRESET_TOP_LEFT)
	dossier.size = Vector2(1100.0, 640.0)
	dossier.set_model(model)
	_expect("dossier opens on overview", dossier.current_chapter() == "overview")
	_expect("dossier KPI strip filled", dossier.kpi_texts().size() == 5
		and not dossier.kpi_texts()[0].is_empty())
	var overview_page := dossier.page("overview")
	var income_bar := overview_page.get_node("%IncomeBar") as DossierStackedBar
	var expense_bar := overview_page.get_node("%ExpenseBar") as DossierStackedBar
	var trend := overview_page.get_node("%TrendChart") as DossierTrendLines
	_expect("overview shows the treasury cashflow block",
		income_bar != null and income_bar.visible and expense_bar.visible
			and trend != null and trend.visible)
	_expect("cashflow stacks the levied kinds and the paid subsidies",
		income_bar.segment_count() == 3 and expense_bar.segment_count() == 1)
	var detail := overview_page.get_node("%CashflowDetail") as DossierLedgerTable
	_expect("cashflow detail starts collapsed with all five tax lanes",
		detail != null and not detail.visible and detail.row_count() == 5)
	var toggle := overview_page.get_node("%CashflowToggle") as Button
	toggle.pressed.emit()
	_expect("cashflow detail expands on demand", detail.visible)
	toggle.pressed.emit()
	_expect("cashflow detail collapses again", not detail.visible)
	_expect("overview shows the per-capita and price instruments",
		overview_page.get_node("%PerCapitaValue").visible
			and overview_page.get_node("%LivingLadder").visible
			and overview_page.get_node("%PriceAxis").visible)
	var nodes := {}
	for chapter in EconomyDossierViewModel.CHAPTERS:
		var chapter_id := String(chapter.id)
		dossier.select_chapter(chapter_id)
		_expect("chapter %s selected" % chapter_id, dossier.current_chapter() == chapter_id)
		# 页头（产值横幅 + KPI 条）是总览专属，不该跟着章节跑到阶层/产业里去。
		var overview := chapter_id == "overview"
		_expect("chapter %s GDP band visibility" % chapter_id,
			dossier.gdp_band_visible() == overview)
		_expect("chapter %s KPI strip visibility" % chapter_id,
			dossier.kpi_strip_visible() == overview)
		if chapter_id not in ["tax", "treasury"]:
			var page := dossier.page(chapter_id)
			_expect("chapter %s page exists" % chapter_id, page != null and page.visible)
			nodes[chapter_id] = page
	var workspace := dossier.economy_workspace() as EconomyWorkspace
	dossier.select_chapter("tax")
	workspace.select_page_for_test("consumption")
	var tax_row := workspace.tax_row_instance_id("consumption", "__default__")
	dossier.select_chapter("treasury")
	_expect("treasury chapter hides both nested navigation rows",
		workspace.get("_page") == "treasury"
		and not (workspace.get("_tabs") as Control).visible
		and not (workspace.get("_tax_tabs") as Control).visible)
	dossier.select_chapter("tax")
	_expect("tax chapter restores its tax kind and cached editor",
		workspace.get("_page") == "consumption"
		and (workspace.get("_tax_tabs") as Control).visible
		and workspace.tax_row_instance_id("consumption", "__default__") == tax_row)
	dossier.select_chapter("strata")
	var strata_table := dossier.page("strata").get_node("%StrataTable") as DossierLedgerTable
	_expect("strata ledger has 8 rows", strata_table != null and strata_table.row_count() == 8)
	dossier.select_chapter("industry")
	# 位置要等容器重排完才有意义（页面刚从隐藏转为可见）。
	await process_frame
	await process_frame
	var industry_page := dossier.page("industry")
	var building_table := industry_page.get_node("%BuildingTable") as DossierLedgerTable
	var industry_units := float(dossier.view_model().query("summary").get("building_units", 0))
	_expect("industry ledger rows follow building units", building_table != null
		and (building_table.row_count() > 0) == (industry_units > 0.0))
	# 投资风向折进产业页：区段在页内、可被锚点定位，且不自成一个章节。
	var invest := industry_page.get_node_or_null("%InvestmentSection")
	_expect("industry chapter carries the investment section", invest != null)
	_expect("investment section is anchored below the building table",
		invest != null and industry_page.call("section_offset", "investment")
			> building_table.position.y)
	dossier.select_chapter("market")
	await process_frame
	await process_frame
	var market_page := dossier.page("market")
	var heat := market_page.get_node("%HeatGrid") as DossierHeatGrid
	_expect("market heat grid cells", heat != null and heat.cell_count() > 0)
	var trade := market_page.get_node_or_null("%TradeSection")
	_expect("market chapter carries the trade section", trade != null)
	_expect("trade section is anchored below the heat grid",
		trade != null and market_page.call("section_offset", "trade") > heat.position.y)
	# 合并后这两个 id 不该再被当成章节：外壳应当拒绝它们。
	_expect("merged chapter ids are no longer chapters",
		not dossier.call("_is_known_chapter", "investment")
			and not dossier.call("_is_known_chapter", "trade"))
	# 页内锚点：同章跳转要把视口滚到区段，而不是停在页顶。
	dossier.set_scroll_for_test(0)
	market_page.navigate_requested.emit("market", {"section": "trade"})
	for i in range(3):
		await process_frame
	_expect("same-chapter section navigation scrolls to the trade block",
		dossier.scroll_value() > 100)
	dossier.select_chapter("cities")
	var city_table := dossier.page("cities").get_node("%CityTable") as DossierLedgerTable
	_expect("cities ledger rows", city_table != null and city_table.row_count() > 0)
	dossier.set_scope(city_cell)
	_expect("scope switch leaves cities chapter", dossier.current_chapter() == "overview"
		and dossier.scope_cell() == city_cell)
	# 跨章锚点：总览点「利润过低」卡点，要直接落到产业章的投资风向一段。
	dossier.set_scroll_for_test(0)
	dossier.page("overview").navigate_requested.emit("industry", {"section": "investment"})
	for i in range(3):
		await process_frame
	_expect("cross-chapter section navigation lands in the investment block",
		dossier.current_chapter() == "industry" and dossier.scroll_value() > 100)
	dossier.select_chapter("overview")
	for i in range(20):
		dossier.set_model(model)
	for chapter_id in nodes:
		_expect("chapter %s node stable across refresh" % chapter_id,
			dossier.page(chapter_id) == nodes[chapter_id])
	dossier.set_scope(-1)
	dossier.set_compact(true)
	dossier.select_chapter("overview")
	_expect("returning to overview restores the page header",
		dossier.gdp_band_visible() and dossier.kpi_strip_visible())
	_expect("overview narrows to one column",
		(dossier.page("overview").get_node("%Columns") as GridContainer).columns == 1)
	dossier.queue_free()


func _check_runtime_models() -> void:
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		return
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var profile: Dictionary = load("res://data/economy/default_economy.tres").to_native_profile()
	profile.market_runtime_mode = "ACTIVE"
	profile.trade_runtime_mode = "OFF"
	profile.economy_cadence_force_market_days = 5
	profile.economy_cadence_force_plan_days = 10
	profile.economy_cadence_force_investment_days = 10
	var runtime := _new_runtime(compiled, catalog, profile, 92077)
	if not runtime.has_method("get_country_economy_overview"):
		_expect("overview API is bound", false)
		return
	var handle := int(runtime.get_country_cell_summary(0).get("country_handle", 0))
	for day in range(7):
		for slice in range(64):
			var report: Dictionary = runtime.run_economy_slice({
				"day_index": day, "tick_index": day * 1000 + slice})
			if bool(report.get("done", false)) or bool(report.get("fatal", false)):
				break
	var facade := FakeEconomyFacade.new()
	facade.runtime = runtime
	facade.catalog = catalog
	var history := EconomyHistoryBuffer.new()
	var table := SocialStrataTable.load_default()
	_expect("history samples committed day", history.sample(facade, handle, 50000, table))
	_expect("history dedupes same day", not history.sample(facade, handle, 50000, table))
	var vm := EconomyDossierViewModel.new(table)
	vm.configure({"available": true, "economy_facade": facade, "country_handle": handle,
		"treasury": {"cash": 50000}, "trade_summary": {"ok": false}}, history)
	_expect("view model available", vm.available())
	var kpis := vm.kpis()
	_expect("five KPIs", kpis.size() == 5)
	var summary: Dictionary = vm.query("summary")
	if kpis.size() == 5:
		_expect("population KPI equals native summary",
			is_equal_approx(float(kpis[0].value), float(summary.get("population", 0))))
		_expect("KPI sparkline comes from history", (kpis[0].spark as PackedFloat32Array).size() == 1)
	var overview := vm.overview_model()
	_expect("overview ok", bool(overview.get("ok", false)))
	_expect("overview carries cashflow, prices and living standard",
		(overview.get("cashflow", {}) as Dictionary).has("net")
			and (overview.get("price", {}) as Dictionary).has("rows")
			and (overview.get("living", {}) as Dictionary).has("level"))
	# 总览不再重复居民收支 / 阶层 / 卡点：这些都有独立章节。
	_expect("overview no longer duplicates the strata chapters",
		not overview.has("strata") and not overview.has("bottlenecks")
			and not overview.has("income_segments"))
	var strata_model := vm.strata_model(-1)
	_expect("strata model selects a populated stratum",
		bool(strata_model.get("ok", false)) and not (strata_model.get("selected", {}) as Dictionary).is_empty())
	_expect("national radar has 8 dims",
		(strata_model.get("national_dims", PackedFloat32Array()) as PackedFloat32Array).size() == 8)
	var industry := vm.industry_model(-1)
	_expect("industry model ok (%s, %d rows, %d units)" % [String(industry.get("reason", "")),
		(industry.get("rows", []) as Array).size(), int(summary.get("building_units", 0))],
		bool(industry.get("ok", false)))
	var units := 0.0
	for row in industry.get("rows", []):
		units += float(row.units)
	_expect("industry units equal summary building units",
		is_equal_approx(units, float(summary.get("building_units", 0))))
	var investment := vm.investment_model()
	_expect("investment model ok", bool(investment.get("ok", false))
		and (investment.categories as Array).size() == EconomyDossierViewModel.BOTTLENECK_ORDER.size())
	var market := vm.market_model("")
	_expect("market cells", bool(market.get("ok", false)) and not (market.cells as Array).is_empty())
	var grouped := 0
	for group in market.get("groups", []):
		grouped += int(group.count)
	_expect("market groups partition cells", grouped == (market.get("cells", []) as Array).size())
	if not (market.get("groups", []) as Array).is_empty():
		var first_group := String(market.groups[0].id)
		var filtered := vm.market_model(first_group)
		_expect("market group filter", (filtered.cells as Array).size() == int(market.groups[0].count))
	var cities := vm.cities_model()
	_expect("cities model ok", bool(cities.get("ok", false)) and not (cities.rows as Array).is_empty())
	var city_population := 0.0
	for row in cities.get("rows", []):
		city_population += float(row.population)
	_expect("cities (named + villages) cover national population",
		is_equal_approx(city_population, float(summary.get("population", 0))))
	var trade := vm.trade_model()
	_expect("trade model degrades gracefully", not bool(trade.get("ok", true)))
	# 合并后「利润过低」不再指向已消失的 investment 章，而是产业章的页内区段。
	var margin_meta: Dictionary = EconomyDossierViewModel.BOTTLENECK_META["margin"]
	_expect("margin bottleneck targets the merged industry chapter",
		String(margin_meta.get("chapter", "")) == "industry"
			and String(margin_meta.get("section", "")) == "investment")
	var chapter_ids := {}
	for chapter in EconomyDossierViewModel.CHAPTERS:
		chapter_ids[String(chapter.id)] = true
	for category in EconomyDossierViewModel.BOTTLENECK_ORDER:
		var meta: Dictionary = EconomyDossierViewModel.BOTTLENECK_META[category]
		_expect("bottleneck %s targets a live chapter" % category,
			chapter_ids.has(String(meta.get("chapter", ""))))
	var options := vm.scope_options()
	_expect("scope options start with nation", int(options[0].cell) == -1)
	var first_cell := int((vm.query("settlements").get("cell_indices", PackedInt32Array()) as PackedInt32Array)[0])
	vm.scope_cell = first_cell
	vm.begin_refresh()
	var scoped: Dictionary = vm.query("summary")
	_expect("city scope narrows population", bool(scoped.get("ok", false))
		and int(scoped.get("population", 0)) <= int(summary.get("population", 0)))
	_expect("city scope KPI 5 is output", vm.kpis().size() == 5
		and String(vm.kpis()[4].title).contains("产值"))
	_expect("scope label resolves", not vm.scope_label().is_empty())
	vm.scope_cell = -1
	_scene_args = [{"available": true, "economy_facade": facade, "country_handle": handle,
		"treasury": {"cash": 50000}, "trade_summary": {"ok": false}, "economy_history": history,
		"fiscal": {"ok": true, "sample_day": 6,
			"tax_kinds": PackedStringArray([
				"income", "consumption", "business", "import", "export"]),
			"collected": PackedInt64Array([420000, 90000, 20000, 0, 0]),
			"subsidy_paid": PackedInt64Array([0, 0, 60000, 0, 0]),
			"subsidy_requested": PackedInt64Array([0, 0, 80000, 0, 0]),
			"tax_base": PackedInt64Array([4200000, 1800000, 600000, 0, 0])}},
		first_cell]
	vm.configure({"available": false, "reason": "测试不可用"})
	_expect("unavailable reason surfaces", not vm.available()
		and vm.unavailable_reason() == "测试不可用")
