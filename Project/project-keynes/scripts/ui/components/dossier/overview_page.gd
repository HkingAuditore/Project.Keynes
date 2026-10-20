extends DossierPage

## 总览：收支构成、八阶层满意度、当前卡点、产业部门与最缺物资。

@onready var _columns: GridContainer = %Columns
@onready var _lower: GridContainer = %Lower
@onready var _income_bar: DossierStackedBar = %IncomeBar
@onready var _expense_bar: DossierStackedBar = %ExpenseBar
@onready var _flow_note: Label = %FlowNote
@onready var _strata_grid: GridContainer = %StrataGrid
@onready var _bottlenecks: DossierBarList = %BottleneckList
@onready var _bottleneck_empty: Label = %BottleneckEmpty
@onready var _bottleneck_detail: Label = %BottleneckDetail
@onready var _sectors: DossierBarList = %SectorList
@onready var _shortages: DossierBarList = %ShortageList
@onready var _shortage_empty: Label = %ShortageEmpty

var _bottleneck_rows: Array = []


func _ready() -> void:
	_bottlenecks.selectable = true
	_bottlenecks.label_width = 128.0
	_bottlenecks.value_width = 52.0
	_bottlenecks.row_height = 30.0
	_bottlenecks.row_selected.connect(_on_bottleneck_selected)
	_sectors.selectable = true
	_sectors.label_width = 76.0
	_sectors.value_width = 150.0
	_sectors.row_selected.connect(func(id): navigate_requested.emit("industry", {"sector": int(id)}))
	_shortages.selectable = true
	_shortages.label_width = 96.0
	_shortages.value_width = 64.0
	_shortages.row_selected.connect(func(id): navigate_requested.emit("market",
		{"focus": String(id)}))
	for gauge in _strata_grid.get_children():
		if gauge is DossierRingGauge:
			gauge.custom_minimum_size = Vector2(72.0, 98.0)
			gauge.pressed.connect(func(id): navigate_requested.emit("strata", {"focus": int(id)}))
	%StrataLink.pressed.connect(func(): navigate_requested.emit("strata", {}))
	%SectorLink.pressed.connect(func(): navigate_requested.emit("industry", {"sector": -1}))
	%ShortageLink.pressed.connect(func(): navigate_requested.emit("market", {}))


func refresh(vm: EconomyDossierViewModel, _filter = null) -> void:
	var model := vm.overview_model()
	if not bool(model.get("ok", false)):
		return
	_income_bar.set_segments("收入来源", model.income_segments,
		money(float(model.income_total)))
	_expense_bar.set_segments("支出去向", model.expense_segments,
		money(float(model.expense_total)))
	var net := float(model.income_total) - float(model.expense_total)
	_flow_note.text = "每日%s %s · 按已提交结算日的居民账户合计" % [
		"结余" if net >= 0.0 else "赤字", money(absf(net))]
	_refresh_strata(model.strata)
	_refresh_bottlenecks(model.bottlenecks)
	_refresh_sectors(model.sectors)
	_refresh_shortages(model.shortages)


func _refresh_strata(strata: Array) -> void:
	var gauges := _strata_grid.get_children()
	for i in range(gauges.size()):
		var gauge := gauges[i] as DossierRingGauge
		if gauge == null:
			continue
		if i >= strata.size():
			gauge.visible = false
			continue
		var row: Dictionary = strata[i]
		var people := float(row.population)
		gauge.visible = true
		gauge.modulate.a = 1.0 if people > 0.0 else 0.4
		var tooltip := "%s\n人口 %s（%s）\n人均收入 %s / 日\n温饱满足 %s" % [
			row.name, count(people), percent(float(row.get("share", 0.0))),
			money(float(row.get("income_per_capita", 0.0))), percent(float(row.survival))]
		gauge.set_gauge(int(row.index), String(row.name),
			float(row.satisfaction) if people > 0.0 else 0.0,
			percent(float(row.get("share", 0.0))) if people > 0.0 else "无人口",
			satisfaction_color(float(row.satisfaction)) if people > 0.0 else UITokens.DOSSIER_INK_MUTED,
			tooltip)


func _refresh_bottlenecks(bottlenecks: Array) -> void:
	_bottleneck_rows = bottlenecks
	var rows: Array = []
	for entry in bottlenecks:
		var details := PackedStringArray()
		for line in entry.details:
			details.append(String(line))
		rows.append({"id": String(entry.id), "label": String(entry.label), "icon": entry.icon,
			"value": float(entry.severity), "text": percent(float(entry.severity)),
			"color": UITokens.DOSSIER_OXBLOOD if float(entry.severity) >= 0.25 else UITokens.DOSSIER_BRASS,
			"tooltip": "%s\n%s\n%s" % [entry.label, "\n".join(details), entry.advice]})
	_bottlenecks.set_rows(rows)
	_show_empty(_bottleneck_empty, _bottlenecks,
		"" if not rows.is_empty() else "暂未发现明显卡点：岗位、资金、原料与销路都在正常范围内")
	if bottlenecks.is_empty():
		_bottleneck_detail.visible = false
		return
	var top: Dictionary = bottlenecks[0]
	var lines := PackedStringArray()
	for line in top.details:
		lines.append(String(line))
	_bottleneck_detail.visible = true
	_bottleneck_detail.text = "最突出：%s。%s" % ["；".join(lines), top.advice]


func _on_bottleneck_selected(id) -> void:
	for entry in _bottleneck_rows:
		if String(entry.id) == String(id):
			# section 是合并篇章后的页内锚点（如「利润」落在产业章的投资风向一段），
			# 由外壳负责把视口滚过去。
			var payload := {"bottleneck": String(id)}
			var section := String(entry.get("section", ""))
			if not section.is_empty():
				payload["section"] = section
			navigate_requested.emit(String(entry.chapter), payload)
			return


func _refresh_sectors(sectors: Array) -> void:
	var peak := 0.0
	for sector in sectors:
		peak = maxf(peak, float(sector.revenue))
	var rows: Array = []
	for sector in sectors:
		var units := float(sector.units)
		var text := "%s · 利用 %s" % [money(float(sector.revenue)), percent(float(sector.utilization))] \
			if units > 0.0 else "尚无建筑"
		rows.append({"id": int(sector.id), "label": String(sector.name), "icon": sector.icon,
			"value": float(sector.revenue) / peak if peak > 0.0 else 0.0,
			"text": text, "color": sector.color,
			"tooltip": "%s：%d 座建筑（停业 %d，在建 %d）\n产值 %s / 日 · 成本 %s / 日\n岗位填充 %s" % [
				sector.name, int(units), int(sector.suspended), int(sector.pending),
				money(float(sector.revenue)), money(float(sector.cost)), percent(float(sector.fill_rate))]})
	_sectors.set_rows(rows)


func _refresh_shortages(shortages: Array) -> void:
	var rows: Array = []
	for good in shortages:
		rows.append({"id": String(good.id), "label": String(good.name),
			"value": float(good.shortage), "text": "缺 " + percent(float(good.shortage)),
			"color": UITokens.DOSSIER_OXBLOOD if float(good.shortage) >= EconomyDossierViewModel.SHORTAGE_ALERT
				else UITokens.DOSSIER_BRASS,
			"tooltip": "%s：需求中有 %s 未被满足" % [good.name, percent(float(good.shortage))]})
	_shortages.set_rows(rows)
	_show_empty(_shortage_empty, _shortages, "" if not rows.is_empty() else "各类物资供应充足")


## 三栏需要约 960px（八枚环形仪表一行四枚）；中等宽度先把卡点栏折到第二行。
func _apply_narrow() -> void:
	var wanted := 3
	if _layout_width > 0.0 and _layout_width < 600.0:
		wanted = 1
	elif _layout_width > 0.0 and _layout_width < 960.0:
		wanted = 2
	elif _narrow:
		wanted = 1
	_columns.columns = wanted
	_lower.columns = 1 if wanted == 1 else 2
