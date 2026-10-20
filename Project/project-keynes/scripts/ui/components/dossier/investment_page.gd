extends DossierPage

## 投资风向：资本正在流向哪些部门（在建）、什么挡住了扩产（受阻原因）、
## 哪些物资的需求压力最可能吸引下一轮投资。
## 已作为「产业」章的下半段（industry_page.tscn 里的 InvestmentSection）嵌入，
## chapter_id 由宿主指定，本场景不自带。

const PENDING_COLUMNS := [
	{"id": "name", "label": "在建建筑", "kind": "text", "expand": true, "min_width": 120.0},
	{"id": "units", "label": "数量", "kind": "number", "width": 64.0},
	{"id": "groups", "label": "项目组", "kind": "number", "width": 64.0},
	{"id": "days", "label": "最早完工", "kind": "number", "width": 84.0},
]

var _selected_category := ""

@onready var _top: GridContainer = %Top
@onready var _body: GridContainer = %Body
@onready var _flow_bar: DossierStackedBar = %FlowBar
@onready var _flow_note: Label = %FlowNote
@onready var _pressure: DossierBarList = %PressureList
@onready var _pressure_empty: Label = %PressureEmpty
@onready var _categories: DossierBarList = %CategoryList
@onready var _category_empty: Label = %CategoryEmpty
@onready var _reason_title: Label = %ReasonTitle
@onready var _reason_advice: Label = %ReasonAdvice
@onready var _reasons: DossierBarList = %ReasonList
@onready var _sectors: DossierBarList = %SectorList
@onready var _pending: DossierLedgerTable = %PendingTable


func _ready() -> void:
	_pressure.label_width = 84.0
	_pressure.value_width = 120.0
	_categories.selectable = true
	_categories.label_width = 128.0
	_categories.value_width = 64.0
	_categories.row_height = 30.0
	_categories.row_selected.connect(_on_category_selected)
	_reasons.label_width = 112.0
	_reasons.value_width = 56.0
	_sectors.label_width = 64.0
	_sectors.value_width = 56.0
	_pending.set_columns(PENDING_COLUMNS, "units")
	_pending.empty_text = "当前没有在建项目"


func focus_item(item) -> void:
	_selected_category = String(item)


func refresh(vm: EconomyDossierViewModel, _filter = null) -> void:
	var model := vm.investment_model()
	if not bool(model.get("ok", false)):
		return
	var pending_total := int(model.pending_total)
	_flow_bar.set_segments("在建项目 · 按部门", model.flow, "%d 座" % pending_total)
	var sufficient := float(model.sufficient_units)
	_flow_note.text = ("%d 组建筑产能已足够，暂不扩产" % int(sufficient)) if sufficient > 0.0 \
		else "资本流向由各城市商人按利润与需求自主决定"
	_refresh_pressure(model.pressure)
	_refresh_categories(model.categories)
	var rows: Array = []
	for row in model.pending:
		rows.append({"id": int(row.id), "cells": {
			"name": {"text": String(row.name)},
			"units": {"text": "%d" % int(row.units), "value": float(row.units)},
			"groups": {"text": "%d" % int(row.groups), "value": float(row.groups)},
			"days": {"text": "%d 日" % int(row.days_left) if int(row.days_left) > 0 else "即将完工",
				"value": float(row.days_left)},
		}})
	_pending.set_rows(rows)


func _refresh_pressure(pressure: Array) -> void:
	var rows: Array = []
	for row in pressure:
		rows.append({"id": int(row.row), "label": String(row.name), "value": float(row.pressure),
			"text": "供给 %s · 价 %.2f" % [percent(float(row.cover)), float(row.price_index)],
			"color": UITokens.DOSSIER_OXBLOOD if float(row.pressure) >= 0.5 else UITokens.DOSSIER_BRASS,
			"tooltip": "%s：短缺 %s，供给覆盖需求 %s，价格为成本锚的 %.2f 倍" % [
				row.name, percent(float(row.shortage)), percent(float(row.cover)), float(row.price_index)]})
	_pressure.set_rows(rows)
	_show_empty(_pressure_empty, _pressure, "" if not rows.is_empty() else "供需大体平衡，没有明显的投资缺口")


func _refresh_categories(categories: Array) -> void:
	var active: Array = categories.filter(func(c): return float(c.total) > 0.0)
	var peak := 0.0
	for category in active:
		peak = maxf(peak, float(category.total))
	var rows: Array = []
	var selected: Dictionary = {}
	for category in active:
		if String(category.id) == _selected_category:
			selected = category
		rows.append({"id": String(category.id), "label": String(category.label),
			"icon": category.icon, "value": float(category.total) / peak if peak > 0.0 else 0.0,
			"text": "%d 组" % int(category.total), "color": UITokens.DOSSIER_OXBLOOD,
			"tooltip": String(category.advice)})
	if selected.is_empty() and not active.is_empty():
		selected = active[0]
		_selected_category = String(selected.id)
	_categories.selected_id = _selected_category
	_categories.set_rows(rows)
	_show_empty(_category_empty, _categories,
		"" if not rows.is_empty() else "没有扩产受阻的记录")
	_refresh_reason(selected)


func _refresh_reason(category: Dictionary) -> void:
	if category.is_empty():
		_reason_title.text = "扩产顺畅"
		_reason_advice.text = "所有考察过的扩产机会都已落地或产能已足够。"
		_reasons.set_rows([])
		_sectors.set_rows([])
		return
	_reason_title.text = String(category.label)
	_reason_advice.text = String(category.advice)
	var total := maxf(1.0, float(category.total))
	var reason_rows: Array = []
	for reason in category.reasons:
		reason_rows.append({"id": int(reason.reason), "label": String(reason.label),
			"value": float(reason.count) / total, "text": "%d 组" % int(reason.count),
			"color": UITokens.DOSSIER_OXBLOOD})
	_reasons.set_rows(reason_rows)
	var by_sector: PackedFloat32Array = category.by_sector
	var sector_rows: Array = []
	for sector in EconomyDossierViewModel.SECTORS:
		var value := by_sector[int(sector.id)] if int(sector.id) < by_sector.size() else 0.0
		if value <= 0.0:
			continue
		sector_rows.append({"id": int(sector.id), "label": String(sector.name), "icon": sector.icon,
			"value": value / total, "text": "%d 组" % int(value), "color": sector.color})
	_sectors.set_rows(sector_rows)


func _on_category_selected(id) -> void:
	_selected_category = String(id)
	navigate_requested.emit(chapter_id, {})


func _apply_narrow() -> void:
	_top.columns = 1 if _narrow else 2
	_body.columns = 1 if _narrow else 2
