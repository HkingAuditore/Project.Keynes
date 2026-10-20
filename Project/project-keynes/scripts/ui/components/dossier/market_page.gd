extends DossierPage

## 市场：按类别排列的供需热力网格 + 选中物资的供需、库存、价格与外贸，
## 下方接全国进出口（贸易差额 / 伙伴 / 物资账簿）——市场按范围取数，贸易恒为全国口径。
## 价格走势只在本页打开期间按结算日采样，保存在页面本地，不进存档。

const PRICE_CAPACITY := 120

var _selected := ""
var _price_history: Dictionary = {}
var _history_scope := -3
var _history_day := -1

@onready var _body: GridContainer = %Body
@onready var _count_label: Label = %CountLabel
@onready var _grid: DossierHeatGrid = %HeatGrid
@onready var _empty: Label = %EmptyLabel
@onready var _detail_title: Label = %DetailTitle
@onready var _detail_meta: Label = %DetailMeta
@onready var _supply_bar: DossierDivergingBar = %SupplyBar
@onready var _stats: DossierBarList = %StatsList
@onready var _trade_bar: DossierDivergingBar = %TradeBar
@onready var _price_card: DossierKpiCard = %PriceCard
@onready var _trade: DossierPage = %TradeSection
@onready var _trade_kicker: Label = %TradeSectionKicker


func _ready() -> void:
	_grid.cell_selected.connect(_on_cell_selected)
	_stats.label_width = 72.0
	_stats.value_width = 76.0
	_price_card.show_divider = false


func focus_item(item) -> void:
	_selected = String(item)


## 共用的页内锚点：卡点跳转落到「全国进出口」一段时，外壳拿这个偏移去滚动视口。
## 锚在小标题而不是区段本体上，否则跳过去第一眼是内容、看不到自己落在哪一段。
func section_offset(section: String) -> float:
	if section == "trade" and _trade_kicker != null:
		return _trade_kicker.position.y
	return 0.0


func refresh(vm: EconomyDossierViewModel, filter = null) -> void:
	_refresh_market(vm, filter)
	# 贸易不响应范围与类别筛选，这里只是顺带把它的账簿刷新一次。
	if _trade != null:
		_trade.refresh(vm, filter)


func _refresh_market(vm: EconomyDossierViewModel, filter = null) -> void:
	var model := vm.market_model(String(filter) if filter != null else "")
	if not bool(model.get("ok", false)):
		_show_empty(_empty, _grid, String(model.get("reason", "")))
		return
	var cells: Array = model.cells
	_show_empty(_empty, _grid, "" if not cells.is_empty() else "该类别下没有物资")
	_sample_prices(vm, cells)
	var short_count := 0
	var surplus_count := 0
	var selected: Dictionary = {}
	for cell in cells:
		var heat := float(cell.heat)
		if heat >= 0.02:
			short_count += 1
		elif heat <= -0.02:
			surplus_count += 1
		cell["status"] = _status_text(cell)
		cell["tooltip"] = "%s\n需求 %s · 供给 %s\n价格指数 %.2f" % [cell.name,
			count(float(cell.demand)), count(float(cell.supply)), float(cell.price_index)]
		if String(cell.id) == _selected:
			selected = cell
	if selected.is_empty() and not cells.is_empty():
		selected = cells[0]
		for cell in cells:
			if _attention(cell) > _attention(selected):
				selected = cell
		_selected = String(selected.id)
	_count_label.text = "%d 种物资 · 短缺 %d · 积压 %d" % [cells.size(), short_count, surplus_count]
	_grid.selected_id = _selected
	_grid.set_cells(model.groups, cells)
	_refresh_detail(selected)


## 默认选中最值得关注的物资：短缺优先，其次是积压。
static func _attention(cell: Dictionary) -> float:
	var heat := float(cell.heat)
	return heat if heat > 0.0 else -heat * 0.5


static func _status_text(cell: Dictionary) -> String:
	var shortage := float(cell.shortage)
	if shortage >= 0.02:
		return "缺 " + percent(shortage)
	var days := float(cell.days_of_stock)
	if float(cell.demand) <= 0.0 and float(cell.supply) <= 0.0:
		return "无交易"
	if days >= 999.0:
		return "库存充裕"
	return "库存 %d 日" % int(days)


func _sample_prices(vm: EconomyDossierViewModel, cells: Array) -> void:
	if _history_scope != vm.scope_cell:
		_history_scope = vm.scope_cell
		_price_history.clear()
		_history_day = -1
	var history := vm.history()
	var day := history.latest_day() if history != null else -1
	if day >= 0 and day == _history_day:
		return
	_history_day = day
	for cell in cells:
		var id := String(cell.id)
		var series: PackedFloat32Array = _price_history.get(id, PackedFloat32Array())
		series.append(float(cell.price_index))
		if series.size() > PRICE_CAPACITY:
			series = series.slice(series.size() - PRICE_CAPACITY)
		_price_history[id] = series


func _refresh_detail(cell: Dictionary) -> void:
	if cell.is_empty():
		_detail_title.text = "未选择物资"
		_detail_meta.text = ""
		return
	_detail_title.text = String(cell.name)
	var group_name := ""
	for group in EconomyDossierViewModel.GOOD_GROUPS:
		if String(group.id) == String(cell.group):
			group_name = String(group.name)
	_detail_meta.text = "%s · %d 个市场，其中 %d 个短缺" % [group_name, int(cell.market_cells),
		int(cell.shortage_cells)]
	_supply_bar.set_values("需求", float(cell.demand), count(float(cell.demand)),
		"供给", float(cell.supply), count(float(cell.supply)))
	var days := float(cell.days_of_stock)
	var price_index := float(cell.price_index)
	_stats.set_rows([
		{"id": "shortage", "label": "短缺率", "value": float(cell.shortage),
			"text": percent(float(cell.shortage)), "color": UITokens.DOSSIER_OXBLOOD},
		{"id": "stock", "label": "库存可用", "value": clampf(days / 120.0, 0.0, 1.0),
			"text": "充裕" if days >= 999.0 else "%d 日" % int(days),
			"color": UITokens.DOSSIER_VERDIGRIS},
		{"id": "price", "label": "价格指数", "value": clampf(price_index / 2.0, 0.0, 1.0),
			"marker": 0.5, "text": "%.2f 倍" % price_index,
			"color": UITokens.DOSSIER_OXBLOOD if price_index > 1.05
				else (UITokens.DOSSIER_VERDIGRIS if price_index < 0.95 else UITokens.DOSSIER_BRASS),
			"tooltip": "竖线为成本锚价格（1.0 倍）"},
	])
	_trade_bar.set_values("进口", float(cell["import"]), count(float(cell["import"])),
		"出口", float(cell["export"]), count(float(cell["export"])))
	var series: PackedFloat32Array = _price_history.get(String(cell.id), PackedFloat32Array())
	var delta := NAN
	if series.size() >= 2:
		delta = series[series.size() - 1] - series[maxi(0, series.size() - 8)]
	_price_card.set_metric({"id": "price_index", "title": "价格走势", "value": price_index,
		"kind": "index", "positive_good": false, "spark": series, "delta": delta,
		"caption": "单价 %s · 本次打开期间" % money(float(cell.price)),
		"icon": &"metric.goods"})


func _on_cell_selected(id: String) -> void:
	_selected = id
	navigate_requested.emit(chapter_id, {})


func _apply_narrow() -> void:
	_body.columns = 1 if _narrow else 2
	if _trade != null:
		_trade.set_narrow(_narrow, _layout_width)
