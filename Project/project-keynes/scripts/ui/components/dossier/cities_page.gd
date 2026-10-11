extends DossierPage

## 城市：已命名城市逐行对比，未命名村落合并为一行。点击行切换卷宗范围，
## 行尾操作可切换范围或在地图上定位。

const COLUMNS := [
	{"id": "name", "label": "城市", "kind": "text", "expand": true, "min_width": 120.0},
	{"id": "population", "label": "人口", "kind": "number", "width": 70.0},
	{"id": "income", "label": "人均收入", "kind": "number", "width": 78.0},
	{"id": "satisfaction", "label": "满意度", "kind": "bar", "width": 108.0},
	{"id": "fill", "label": "岗位填充", "kind": "bar", "width": 96.0, "optional": true},
	{"id": "unemployment", "label": "失业率", "kind": "number", "width": 62.0, "optional": true},
	{"id": "buildings", "label": "建筑", "kind": "number", "width": 66.0, "optional": true,
		"tooltip": "建筑数（停业数）"},
	{"id": "shortage", "label": "最缺物资", "kind": "text", "width": 118.0, "optional": true},
	{"id": "actions", "label": "", "kind": "actions", "width": 60.0, "sortable": false},
]
const ACTIONS := [
	{"id": "scope", "icon": &"action.chevron_right", "tooltip": "切换到该城市的卷宗"},
	{"id": "locate", "icon": &"action.pin", "tooltip": "关闭面板并在地图上定位"},
]

@onready var _summary: Label = %SummaryLabel
@onready var _table: DossierLedgerTable = %CityTable
@onready var _empty: Label = %EmptyLabel


func _ready() -> void:
	_table.set_columns(COLUMNS, "population")
	_table.empty_text = "本国尚无聚落"
	_table.row_selected.connect(_on_row_selected)
	_table.row_action.connect(_on_row_action)


func refresh(vm: EconomyDossierViewModel, _filter = null) -> void:
	var model := vm.cities_model()
	if not bool(model.get("ok", false)):
		_show_empty(_empty, _table, String(model.get("reason", "")))
		return
	_show_empty(_empty, _table, "")
	var rows: Array = []
	var city_count := 0
	var village_count := 0
	for row in model.rows:
		var village := bool(row.village)
		if village:
			village_count = int(row.count)
		else:
			city_count += 1
		rows.append(_ledger_row(row, vm.scope_cell))
	_summary.text = "%d 座城市%s" % [city_count,
		" · 另有 %d 处未命名村落" % village_count if village_count > 0 else ""]
	_table.selected_id = vm.scope_cell if vm.scope_cell >= 0 else null
	_table.set_rows(rows)


func _ledger_row(row: Dictionary, scope: int) -> Dictionary:
	var village := bool(row.village)
	var shortage := float(row.get("shortage", 0.0))
	var shortage_text := "—"
	if shortage > 0.02 and not String(row.get("shortage_good", "")).is_empty():
		shortage_text = "%s %s" % [row.shortage_good, percent(shortage)]
	return {"id": int(row.id), "muted": village,
		"tooltip": "%s\n人口 %s · 每日收入 %s\n建筑 %d 座（停业 %d），每日利润 %s" % [
			row.name, count(float(row.population)), money(float(row.income)),
			int(row.units), int(row.suspended), money(float(row.profit))],
		"actions": [] if village else ACTIONS,
		"cells": {
			"name": {"text": String(row.name), "sub": String(row.get("tier", "")),
				"strong": int(row.id) == scope},
			"population": {"text": count(float(row.population)), "value": float(row.population)},
			"income": {"text": money(float(row.income_per_capita)),
				"value": float(row.income_per_capita)},
			"satisfaction": {"value": float(row.satisfaction), "text": percent(float(row.satisfaction)),
				"bar_color": satisfaction_color(float(row.satisfaction))},
			"fill": {"value": float(row.fill_rate), "text": percent(float(row.fill_rate)),
				"bar_color": satisfaction_color(float(row.fill_rate))},
			"unemployment": {"text": percent(float(row.unemployment)), "value": float(row.unemployment),
				"color": UITokens.DOSSIER_OXBLOOD if float(row.unemployment) > 0.1 else UITokens.DOSSIER_INK},
			"buildings": {"text": "%d%s" % [int(row.units),
				"（%d）" % int(row.suspended) if float(row.suspended) > 0.0 else ""],
				"value": float(row.units)},
			"shortage": {"text": shortage_text, "value": shortage,
				"color": UITokens.DOSSIER_OXBLOOD if shortage >= EconomyDossierViewModel.SHORTAGE_ALERT
					else UITokens.DOSSIER_INK_SOFT},
		}}


func _on_row_selected(id) -> void:
	if int(id) >= 0:
		scope_requested.emit(int(id))


func _on_row_action(id, action_id: String) -> void:
	if int(id) < 0:
		return
	match action_id:
		"scope":
			scope_requested.emit(int(id))
		"locate":
			locate_requested.emit(int(id))
