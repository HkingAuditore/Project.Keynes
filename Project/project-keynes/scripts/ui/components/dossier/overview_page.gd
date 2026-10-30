extends DossierPage

## 总览：同一页只看四件事——国库收支（结构与方向）、人均产出、生活水平、物价。
## 居民收支、阶层满意度、卡点、产值与短缺都有各自的章节，这里不再重复。
##
## 每块图形按数据的形状选：收支的结构用堆叠占比、方向用折线；
## 生活水平是有序台阶看档位；物价是相对成本锚的偏离看方向与裂口；
## 人均产出是逐日波动的流量，用读数配迷你走势。

const CASHFLOW_COLUMNS := [
	{"id": "name", "label": "税种", "kind": "text", "expand": true, "min_width": 96.0},
	{"id": "base", "label": "税基", "kind": "money", "width": 112.0},
	{"id": "collected", "label": "实收", "kind": "money", "width": 112.0},
	{"id": "requested", "label": "补贴申请", "kind": "money", "width": 112.0},
	{"id": "paid", "label": "补贴实付", "kind": "money", "width": 112.0},
]
## 收支块左右并排需要约 760px；更窄时把折线折到堆叠条下面。
const CASHFLOW_STACK_WIDTH := 760.0
const FLOW_BARS_WIDTH := 430.0

@onready var _header: HBoxContainer = %CashflowHeader
@onready var _day: Label = %CashflowDay
@onready var _toggle: Button = %CashflowToggle
@onready var _body: BoxContainer = %CashflowBody
@onready var _bars: VBoxContainer = %FlowBars
@onready var _income_bar: DossierStackedBar = %IncomeBar
@onready var _expense_bar: DossierStackedBar = %ExpenseBar
@onready var _trend: DossierTrendLines = %TrendChart
@onready var _detail: DossierLedgerTable = %CashflowDetail
@onready var _columns: GridContainer = %Columns
@onready var _lower: GridContainer = %Lower
@onready var _per_capita: DossierSparkValue = %PerCapitaValue
@onready var _living: DossierLevelLadder = %LivingLadder
@onready var _prices: DossierDeviationAxis = %PriceAxis
@onready var _sectors: DossierBarList = %SectorList
@onready var _shortages: DossierBarList = %ShortageList
@onready var _shortage_empty: Label = %ShortageEmpty

var _detail_open := false
var _detail_rows: Array = []
var _detail_signature := ""


func _ready() -> void:
	_toggle.pressed.connect(_toggle_detail)
	_detail.set_columns(CASHFLOW_COLUMNS, "")
	_detail.row_height = 26.0
	_detail.selected_id = null
	_sectors.selectable = true
	_sectors.label_width = 76.0
	_sectors.value_width = 150.0
	_sectors.row_selected.connect(func(id): navigate_requested.emit("industry", {"sector": int(id)}))
	_shortages.selectable = true
	_shortages.label_width = 96.0
	_shortages.value_width = 64.0
	_shortages.row_selected.connect(func(id): navigate_requested.emit("market",
		{"focus": String(id)}))
	%SectorLink.pressed.connect(func(): navigate_requested.emit("industry", {"sector": -1}))
	%ShortageLink.pressed.connect(func(): navigate_requested.emit("market", {}))
	_apply_detail_visibility()


func refresh(vm: EconomyDossierViewModel, _filter = null) -> void:
	var model := vm.overview_model()
	if not bool(model.get("ok", false)):
		return
	_refresh_cashflow(model.get("cashflow", {}))
	_refresh_per_capita(model.get("per_capita", {}))
	_refresh_living(model.get("living", {}))
	_refresh_prices(model.get("price", {}))
	_refresh_sectors(model.sectors)
	_refresh_shortages(model.shortages)


# ── 国库收支 ────────────────────────────────────────────────────────────

## 收支块只读财政快照与国库日序列；快照缺席时整块（含标题与明细）收起。
func _refresh_cashflow(cashflow: Dictionary) -> void:
	var ok := bool(cashflow.get("ok", false))
	_header.visible = ok
	_body.visible = ok
	if not ok:
		_detail.visible = false
		return
	_day.text = String(cashflow.get("day_text", ""))
	_income_bar.set_segments("收入", cashflow.get("income_segments", []),
		String(cashflow.get("income_text", "")), true)
	_expense_bar.set_segments("支出", cashflow.get("expense_segments", []),
		String(cashflow.get("expense_text", "")), true)
	_trend.set_series(cashflow.get("income_series", PackedFloat32Array()),
		cashflow.get("expense_series", PackedFloat32Array()),
		String(cashflow.get("net_text", "")), bool(cashflow.get("net_positive", true)))
	# 明细只在结算日或金额变化时重灌：同一批数据每秒重设 5 行会让账簿反复起补间。
	var signature := "%s|%s" % [String(cashflow.get("day_text", "")),
		String(cashflow.get("net_text", ""))]
	if signature != _detail_signature:
		_detail_signature = signature
		_detail_rows = cashflow.get("detail_rows", [])
		_detail.set_rows(_detail_rows)
	_detail.visible = _detail_open


func _toggle_detail() -> void:
	_detail_open = not _detail_open
	_apply_detail_visibility()


func _apply_detail_visibility() -> void:
	_detail.visible = _detail_open and not _detail_rows.is_empty()
	_toggle.text = "明细 ▴" if _detail_open else "明细 ▾"


# ── 人均 ────────────────────────────────────────────────────────────────

func _refresh_per_capita(per_capita: Dictionary) -> void:
	_per_capita.set_value({
		"value": float(per_capita.get("value", 0.0)),
		"delta": float(per_capita.get("delta", NAN)),
		"spark": per_capita.get("trend", PackedFloat32Array()),
		"kind": "money",
		"caption": String(per_capita.get("caption", "")),
	})
	_per_capita.tooltip_text = "当日全国产值 ÷ 人口；年度累计人均见上方横幅。"


func _refresh_living(living: Dictionary) -> void:
	_living.set_level(float(living.get("level", NAN)), int(living.get("max", 6)),
		String(living.get("name", "")))
	_living.tooltip_text = "人口加权后的生活水平档位：0 赤贫 … 6 奢华"


# ── 物价 ────────────────────────────────────────────────────────────────

## CPI / PPI 是相对成本锚（100）的偏离，两根指针共用一根轴，
## 指针间距就是消费端与出厂端的价格裂口。
func _refresh_prices(price: Dictionary) -> void:
	_prices.set_indices(price.get("rows", []))
	var spread := float(price.get("spread", NAN))
	var tips := PackedStringArray()
	for row in price.get("rows", []):
		tips.append(String(row.get("tooltip", "")))
	if not is_nan(spread):
		tips.insert(0, "CPI − PPI：%+.1f 点" % spread)
	_prices.tooltip_text = "\n".join(tips)


# ── 产业 / 物资 ─────────────────────────────────────────────────────────

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


## 三栏需要约 900px；中等宽度先折成两栏，窄版面单列。
## 收支块自己再收一档：太窄时折线落到堆叠条下面，而不是被挤成一条缝。
func _apply_narrow() -> void:
	var wanted := 3
	if _layout_width > 0.0 and _layout_width < 620.0:
		wanted = 1
	elif _layout_width > 0.0 and _layout_width < 900.0:
		wanted = 2
	elif _narrow:
		wanted = 1
	_columns.columns = wanted
	_lower.columns = 1 if wanted == 1 else 2
	var stacked := _layout_width > 0.0 and _layout_width < CASHFLOW_STACK_WIDTH
	_body.vertical = stacked
	_bars.custom_minimum_size.x = 0.0 if stacked else FLOW_BARS_WIDTH
