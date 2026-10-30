extends DossierPage

## 产业：选中建筑的营收去向与运营诊断 + 全部建筑类型账簿（按部门筛选），
## 下方接投资风向（资本流向 / 受阻原因 / 在建项目）——两者共用同一份经济快照。

const COLUMNS := [
	{"id": "name", "label": "建筑", "kind": "text", "expand": true, "min_width": 128.0},
	{"id": "units", "label": "数量", "kind": "number", "width": 56.0},
	{"id": "utilization", "label": "利用率", "kind": "bar", "width": 100.0},
	{"id": "margin", "label": "利润率", "kind": "diverging", "width": 108.0},
	{"id": "revenue", "label": "营收 / 日", "kind": "money", "width": 82.0},
	{"id": "mix", "label": "营收去向", "kind": "stacked", "width": 116.0, "optional": true,
		"sortable": false, "tooltip": "原料 / 工资 / 维护与税 / 利润"},
	{"id": "fill", "label": "岗位填充", "kind": "bar", "width": 92.0, "optional": true},
	{"id": "arrears", "label": "欠薪", "kind": "number", "width": 58.0, "optional": true},
	{"id": "blocker", "label": "扩产卡点", "kind": "text", "width": 112.0, "optional": true},
]
const MIX_COLORS := [Color(0.55, 0.47, 0.36), UITokens.FAMILY_GREEN, UITokens.FAMILY_OXBLOOD,
	UITokens.FAMILY_BRASS]

var _selected := -1

@onready var _detail_grid: GridContainer = %DetailGrid
@onready var _detail_title: Label = %DetailTitle
@onready var _detail_meta: Label = %DetailMeta
@onready var _mix_bar: DossierStackedBar = %MixBar
@onready var _advice: Label = %AdviceLabel
@onready var _count_label: Label = %CountLabel
@onready var _table: DossierLedgerTable = %BuildingTable
@onready var _empty: Label = %EmptyLabel
@onready var _invest: DossierPage = %InvestmentSection
@onready var _invest_kicker: Label = %InvestmentKicker


func _ready() -> void:
	_table.set_columns(COLUMNS, "revenue")
	_table.empty_text = "该部门暂无建筑"
	_table.row_selected.connect(_on_row_selected)


func focus_item(item) -> void:
	# 合并章：建筑 id 是整数，投资风向的卡点类别是字符串，按类型分流。
	if item is String and _invest != null:
		_invest.focus_item(item)
		return
	_selected = int(item)


## 共用的页内锚点：卡点跳转落到「资本与在建」这一段时，外壳拿这个偏移去滚动视口。
## 锚在小标题而不是区段本体上，否则跳过去第一眼是内容、看不到自己落在哪一段。
func section_offset(section: String) -> float:
	if section == "investment" and _invest_kicker != null:
		return _invest_kicker.position.y
	return 0.0


func refresh(vm: EconomyDossierViewModel, filter = null) -> void:
	_refresh_industry(vm, filter)
	# 投资风向与建筑台账共用同一份经济快照，这里只是把模型再喂一遍，
	# investment_model() 走的是同一轮 memo，不产生额外原生查询。
	if _invest != null:
		_invest.refresh(vm, filter)


func _refresh_industry(vm: EconomyDossierViewModel, filter = null) -> void:
	var model := vm.industry_model(int(filter) if filter != null else -1)
	if not bool(model.get("ok", false)):
		_show_empty(_empty, null, String(model.get("reason", "")))
		return
	var source: Array = model.rows
	var built: Array = source.filter(func(r): return float(r.units) > 0.0 or float(r.pending) > 0.0)
	_empty.visible = false
	_count_label.text = "%d 类建筑 · 共 %s 座" % [built.size(),
		count(built.reduce(func(acc, r): return acc + float(r.units), 0.0))]
	var selected: Dictionary = {}
	var rows: Array = []
	for row in built:
		if int(row.id) == _selected:
			selected = row
		rows.append(_ledger_row(row))
	if selected.is_empty() and not built.is_empty():
		selected = built[0]
		for row in built:
			if float(row.revenue) > float(selected.revenue):
				selected = row
		_selected = int(selected.id)
	_table.selected_id = _selected
	_table.set_rows(rows)
	_refresh_detail(selected)


func _ledger_row(row: Dictionary) -> Dictionary:
	var units := float(row.units)
	var revenue := float(row.revenue)
	var idle := units <= 0.0
	return {"id": int(row.id), "muted": idle or float(row.suspended) >= units,
		"tooltip": "%s · %s\n%d 座（停业 %d，在建 %d），分布于 %d 处" % [row.name, row.sector_name,
			int(units), int(row.suspended), int(row.pending), int(row.cells)],
		"cells": {
			"name": {"text": String(row.name), "dot": row.color,
				"sub": "在建 %d" % int(row.pending) if float(row.pending) > 0.0 else ""},
			"units": {"text": "%d" % int(units), "value": units,
				"color": UITokens.DOSSIER_OXBLOOD if float(row.suspended) > 0.0 else UITokens.DOSSIER_INK},
			"utilization": {"value": float(row.utilization), "text": percent(float(row.utilization)),
				"bar_color": satisfaction_color(float(row.utilization))},
			"margin": {"value": float(row.margin), "text": percent(float(row.margin))},
			"revenue": {"text": money(revenue), "value": revenue},
			"mix": {"segments": _mix_segments(row), "sort": revenue},
			"fill": {"value": float(row.fill_rate), "text": percent(float(row.fill_rate)),
				"bar_color": satisfaction_color(float(row.fill_rate)),
				"sort": float(row.fill_rate) if float(row.jobs_required) > 0.0 else 2.0},
			"arrears": {"text": percent(float(row.arrears_rate)) if float(row.arrears_rate) > 0.0 else "—",
				"value": float(row.arrears_rate),
				"color": UITokens.DOSSIER_OXBLOOD if float(row.arrears_rate) > 0.0 else UITokens.DOSSIER_INK_MUTED},
			"blocker": {"text": String(row.blocker) if not String(row.blocker).is_empty() else "—",
				"color": UITokens.DOSSIER_OXBLOOD if not String(row.blocker).is_empty() else UITokens.DOSSIER_INK_MUTED},
		}}


func _mix_segments(row: Dictionary) -> Array:
	var values := [float(row.input_cost), float(row.wages), float(row.maintenance),
		maxf(0.0, float(row.profit))]
	var labels := ["原料", "工资", "维护与税", "利润"]
	var segments: Array = []
	for i in range(values.size()):
		segments.append({"label": labels[i], "value": values[i], "color": MIX_COLORS[i],
			"text": money(values[i])})
	return segments


func _refresh_detail(row: Dictionary) -> void:
	if row.is_empty():
		_detail_title.text = "暂无建筑"
		_detail_meta.text = ""
		_mix_bar.set_segments("每日营收去向", [], "")
		_advice.text = "该范围内还没有运营中的建筑。"
		return
	_detail_title.text = String(row.name)
	_detail_meta.text = "%s · %d 座 · %d 处 · 利用率 %s" % [row.sector_name, int(row.units),
		int(row.cells), percent(float(row.utilization))]
	var loss := minf(0.0, float(row.profit))
	var support := float(row.get("support", 0.0))
	_mix_bar.set_segments("每日收入去向", _mix_segments(row),
		"营收 %s%s%s" % [money(float(row.revenue)),
			" + 扶持 %s" % money(support) if support > 0.0 else "",
			" · 亏损 %s" % money(-loss) if loss < 0.0 else ""])
	_advice.text = "\n".join(diagnose(row))


static func diagnose(row: Dictionary) -> PackedStringArray:
	var lines := PackedStringArray()
	if float(row.suspended) > 0.0:
		lines.append("· %d 座因亏损停业" % int(row.suspended))
	if float(row.profit) < 0.0:
		lines.append("· 营收不抵成本，每日亏损 %s" % money(-float(row.profit)))
	if float(row.units) > 0.0 and float(row.utilization) < 0.6:
		lines.append("· 产能利用仅 %s" % percent(float(row.utilization)))
	if float(row.jobs_required) > 0.0 and float(row.fill_rate) < 0.9:
		lines.append("· 岗位空缺 %s，劳动力不足" % percent(1.0 - float(row.fill_rate)))
	if float(row.arrears_rate) > 0.0:
		lines.append("· 欠薪 %s，资金周转困难" % percent(float(row.arrears_rate)))
	if float(row.discard_rate) > 0.05:
		lines.append("· %s 的产出因卖不出去被丢弃" % percent(float(row.discard_rate)))
	var category := String(row.blocker_category)
	if not category.is_empty():
		var meta: Dictionary = EconomyDossierViewModel.BOTTLENECK_META.get(category, {})
		lines.append("· 扩产受阻：%s（%s）" % [row.blocker, meta.get("advice", "")])
	if lines.is_empty():
		lines.append("· 运营正常，没有明显卡点")
	return lines


func _on_row_selected(id) -> void:
	_selected = int(id)
	navigate_requested.emit(chapter_id, {})


func _apply_narrow() -> void:
	_detail_grid.columns = 1 if _narrow else 3
	if _invest != null:
		_invest.set_narrow(_narrow, _layout_width)
