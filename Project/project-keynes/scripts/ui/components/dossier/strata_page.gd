extends DossierPage

## 阶层民生：八个展示阶层的账簿 + 选中阶层的满意度雷达、分档满足率、
## 短缺需求、职业构成与城市分布。

const COLUMNS := [
	{"id": "name", "label": "阶层", "kind": "text", "expand": true, "min_width": 112.0},
	{"id": "share", "label": "人口占比", "kind": "bar", "width": 118.0},
	{"id": "income", "label": "人均收入", "kind": "number", "width": 78.0,
		"tooltip": "人均每日收入"},
	{"id": "expense", "label": "人均支出", "kind": "number", "width": 78.0, "optional": true,
		"tooltip": "人均每日支出"},
	{"id": "satisfaction", "label": "满意度", "kind": "bar", "width": 112.0},
	{"id": "survival", "label": "温饱", "kind": "bar", "width": 100.0, "optional": true,
		"tooltip": "生存档需求的满足率"},
]

var _selected := -1

@onready var _body: GridContainer = %Body
@onready var _table: DossierLedgerTable = %StrataTable
@onready var _detail_title: Label = %DetailTitle
@onready var _detail_meta: Label = %DetailMeta
@onready var _radar: DossierRadarChart = %Radar
@onready var _tiers: DossierBarList = %TierList
@onready var _sat_trend: DossierKpiCard = %SatisfactionTrend
@onready var _income_trend: DossierKpiCard = %IncomeTrend
@onready var _needs: DossierBarList = %NeedsList
@onready var _needs_empty: Label = %NeedsEmpty
@onready var _professions: DossierBarList = %ProfessionList
@onready var _cities: DossierBarList = %CitiesList
@onready var _cities_empty: Label = %CitiesEmpty


func _ready() -> void:
	_table.set_columns(COLUMNS, "share")
	_table.row_selected.connect(_on_row_selected)
	_tiers.label_width = 64.0
	_tiers.value_width = 48.0
	_needs.label_width = 84.0
	_needs.value_width = 56.0
	_professions.label_width = 96.0
	_professions.value_width = 92.0
	_cities.label_width = 96.0
	_cities.value_width = 92.0
	_cities.selectable = true
	_cities.row_selected.connect(func(cell): scope_requested.emit(int(cell)))
	_radar.custom_minimum_size = Vector2(184.0, 184.0)
	for card in [_sat_trend, _income_trend]:
		(card as Control).custom_minimum_size.x = 112.0
	_sat_trend.show_divider = true
	_income_trend.show_divider = false


func focus_item(item) -> void:
	_selected = int(item)


func refresh(vm: EconomyDossierViewModel, _filter = null) -> void:
	var model := vm.strata_model(_selected)
	if not bool(model.get("ok", false)):
		return
	_selected = int(model.get("selected_index", _selected))
	_table.selected_id = _selected
	var rows: Array = []
	for row in model.rows:
		var people := float(row.population)
		rows.append({"id": int(row.index), "muted": people <= 0.0,
			"tooltip": "%s · %d 种职业" % [row.name, (row.professions as Array).size()],
			"cells": {
				"name": {"text": String(row.name), "icon": row.icon, "icon_color": row.color,
					"sort": int(row.index)},
				"share": {"value": float(row.get("share", 0.0)), "bar_color": row.color,
					"text": percent(float(row.get("share", 0.0)))},
				"income": {"text": money(float(row.get("income_per_capita", 0.0))),
					"value": float(row.get("income_per_capita", 0.0))},
				"expense": {"text": money(float(row.get("expense_per_capita", 0.0))),
					"value": float(row.get("expense_per_capita", 0.0))},
				"satisfaction": {"value": float(row.satisfaction) if people > 0.0 else 0.0,
					"bar_color": satisfaction_color(float(row.satisfaction)),
					"text": percent(float(row.satisfaction)) if people > 0.0 else "—"},
				"survival": {"value": float(row.survival) if people > 0.0 else 0.0,
					"bar_color": satisfaction_color(float(row.survival)),
					"text": percent(float(row.survival)) if people > 0.0 else "—"},
			}})
	_table.set_rows(rows)
	_refresh_detail(model.get("selected", {}), model.get("national_dims", PackedFloat32Array()))


func _refresh_detail(selected: Dictionary, national: PackedFloat32Array) -> void:
	if selected.is_empty():
		_detail_title.text = "暂无人口"
		_detail_meta.text = ""
		return
	var people := float(selected.population)
	_detail_title.text = String(selected.name)
	_detail_meta.text = "%s 人 · 就业 %s · 失业 %s" % [count(people),
		count(float(selected.employed)), count(float(selected.unemployed))]
	var dims: PackedFloat32Array = selected.dims
	_radar.set_values(PackedStringArray(EconomyDossierViewModel.SATISFACTION_DIMENSIONS), dims,
		national, selected.color)
	var tier_rows: Array = []
	for i in range(mini(EconomyDossierViewModel.CONSUMPTION_TIER_COUNT, dims.size())):
		tier_rows.append({"id": i, "label": EconomyDossierViewModel.SATISFACTION_DIMENSIONS[i],
			"value": dims[i], "text": percent(dims[i]), "color": satisfaction_color(dims[i]),
			"marker": national[i] if i < national.size() else -1.0,
			"tooltip": "%s需求满足率 %s（竖线为全国平均 %s）" % [
				EconomyDossierViewModel.SATISFACTION_DIMENSIONS[i], percent(dims[i]),
				percent(national[i] if i < national.size() else 0.0)]})
	_tiers.set_rows(tier_rows)
	_sat_trend.set_metric({"id": "stratum_satisfaction", "title": "满意度趋势",
		"value": float(selected.satisfaction), "kind": "percent", "positive_good": true,
		"caption": "温饱 %s" % percent(float(selected.survival)), "icon": &"population.heart",
		"spark": selected.get("satisfaction_trend", PackedFloat32Array()),
		"delta": _series_delta(selected.get("satisfaction_trend", PackedFloat32Array()))})
	_income_trend.set_metric({"id": "stratum_income", "title": "人均收入 / 日",
		"value": float(selected.get("income_per_capita", 0.0)), "kind": "money",
		"positive_good": true,
		"caption": "支出 %s" % money(float(selected.get("expense_per_capita", 0.0))),
		"icon": &"family.metric.wealth",
		"spark": selected.get("income_trend", PackedFloat32Array()),
		"delta": _series_delta(selected.get("income_trend", PackedFloat32Array()))})
	var need_rows: Array = []
	for need in selected.get("worst_needs", []):
		need_rows.append({"id": int(need.index), "label": String(need.name),
			"value": float(need.share), "text": percent(float(need.share)),
			"color": UITokens.DOSSIER_OXBLOOD,
			"tooltip": "%s 人最缺的是%s" % [count(float(need.population)), need.name]})
	_needs.set_rows(need_rows)
	_show_empty(_needs_empty, _needs, "" if not need_rows.is_empty() else "没有明显的短缺需求")
	var profession_rows: Array = []
	var professions: Array = selected.get("professions", [])
	for i in range(mini(6, professions.size())):
		var profession: Dictionary = professions[i]
		if float(profession.population) <= 0.0:
			continue
		profession_rows.append({"id": String(profession.id), "label": String(profession.name),
			"value": float(profession.population) / people if people > 0.0 else 0.0,
			"text": "%s · 满意 %s" % [count(float(profession.population)),
				percent(float(profession.satisfaction))],
			"color": selected.color})
	_professions.set_rows(profession_rows)
	var city_rows: Array = []
	for city in selected.get("cities", []):
		city_rows.append({"id": int(city.cell), "label": String(city.name),
			"value": float(city.satisfaction), "color": satisfaction_color(float(city.satisfaction)),
			"text": "%s 人 · %s" % [count(float(city.population)), percent(float(city.satisfaction))],
			"tooltip": "点击切换到 %s 的卷宗" % city.name})
	_cities.set_rows(city_rows)
	_show_empty(_cities_empty, _cities, "" if not city_rows.is_empty() else "暂无城市分布")


func _on_row_selected(id) -> void:
	_selected = int(id)
	_table.selected_id = _selected
	_table.queue_redraw()
	navigate_requested.emit(chapter_id, {})


static func _series_delta(series: PackedFloat32Array) -> float:
	if series.size() < 2:
		return NAN
	var lookback := mini(7, series.size() - 1)
	var latest := series[series.size() - 1]
	var earlier := series[series.size() - 1 - lookback]
	return latest - earlier if not is_nan(latest) and not is_nan(earlier) else NAN


func _apply_narrow() -> void:
	_body.columns = 1 if _narrow else 2
