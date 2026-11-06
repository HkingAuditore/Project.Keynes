extends DossierPage

## 人口与民生：同一页给两个分组口径的账簿 + 选中项的满意度雷达、分档满足率、
## 短缺需求、同阶层职业与城市分布。
##
## - 阶层：九个展示阶层，回答「社会结构长什么样」；
## - 职业：原生 professions 视图逐职业一行，回答「到底是谁、多少人、过得如何」。
## 两个视角读同一份快照与同一份 8 维基线，切视角只换分组，不换口径。

## 列顺序就是「挤窄时先丢谁」的优先级：可选列从表尾开始丢，所以满意度与占比
## 必须排在金额前面——民生页要回答的是「谁过得不好」，人均收支在右侧详情卡里
## 单独有一张读数卡，不必挤在逐行账簿里抢位置。
const COLUMNS := [
	{"id": "name", "label": "阶层", "kind": "text", "expand": true, "min_width": 112.0},
	{"id": "population", "label": "人口", "kind": "number", "width": 70.0, "optional": true,
		"tooltip": "该行的人数"},
	{"id": "share", "label": "人口占比", "short_label": "占比", "kind": "bar", "width": 112.0},
	{"id": "satisfaction", "label": "满意度", "kind": "bar", "width": 108.0},
	{"id": "income", "label": "人均收入", "short_label": "收入", "kind": "money", "width": 78.0,
		"optional": true, "tooltip": "人均每日收入"},
	{"id": "expense", "label": "人均支出", "short_label": "支出", "kind": "money", "width": 78.0,
		"optional": true, "tooltip": "人均每日支出"},
	{"id": "survival", "label": "生存", "kind": "bar", "width": 96.0, "optional": true,
		"tooltip": "生存档需求的满足率"},
]

var _selected := -1
var _selected_profession := ""
var _mode := "stratum"
var _applied_mode := ""
## 最近一次渲染用的模型：版面跨过窄/宽断点时只用它重排行，不再查原生。
var _last_model: Dictionary = {}

@onready var _body: GridContainer = %Body
@onready var _table: DossierLedgerTable = %StrataTable
@onready var _list_kicker: Label = %ListKicker
@onready var _detail_title: Label = %DetailTitle
@onready var _detail_meta: Label = %DetailMeta
@onready var _radar: DossierRadarChart = %Radar
@onready var _tiers: DossierBarList = %TierList
@onready var _sat_trend: DossierKpiCard = %SatisfactionTrend
@onready var _income_trend: DossierKpiCard = %IncomeTrend
@onready var _needs: DossierBarList = %NeedsList
@onready var _needs_empty: Label = %NeedsEmpty
@onready var _prof_kicker: Label = %ProfessionKicker
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
	# 职业行可点：在阶层视角里点一个职业＝下钻到职业视角，在职业视角里点＝换选中项。
	_professions.selectable = true
	_professions.row_selected.connect(_on_profession_selected)
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


## 章节页面的 focus 载荷：int = 阶层下标，String = 职业稳定 id。
func focus_item(item) -> void:
	if item is String:
		if not String(item).is_empty():
			_selected_profession = String(item)
		return
	if item is float or item is int:
		_selected = int(item)


func refresh(vm: EconomyDossierViewModel, filter = null) -> void:
	_mode = String(filter) if filter is String and not String(filter).is_empty() else "stratum"
	if _mode != _applied_mode:
		_apply_mode()
	var model := vm.strata_model(_selected, _mode, _selected_profession)
	if not bool(model.get("ok", false)):
		return
	_last_model = model
	_refresh_ledger(model)
	_refresh_detail(model.selected, model.national_dims)


func _apply_mode() -> void:
	_applied_mode = _mode
	var profession_mode := _mode == "profession"
	# 表头第一列的名字要跟着分组口径走，否则职业行会顶着「阶层」表头。
	var columns: Array = COLUMNS.duplicate(true)
	columns[0].label = "职业" if profession_mode else "阶层"
	_table.set_columns(columns, "share")
	_list_kicker.text = "职业与所属阶层" if profession_mode else "阶层"
	_prof_kicker.text = "同阶层职业" if profession_mode else "职业构成"


func _refresh_ledger(model: Dictionary) -> void:
	var rows: Array = []
	if _mode == "profession":
		_selected_profession = String(model.get("selected_id", _selected_profession))
		for row in model.professions:
			var people := float(row.population)
			rows.append({"id": String(row.id), "muted": people <= 0.0,
				"tooltip": "%s · %s · %d 个聚落 · %s 人" % [String(row.name),
					String(row.stratum_name), int(row.cell_count), count(people)],
				"cells": _ledger_cells(row)})
		_table.selected_id = _selected_profession
	else:
		_selected = int(model.get("selected_index", _selected))
		for row in model.rows:
			var people := float(row.population)
			rows.append({"id": int(row.index), "muted": people <= 0.0,
				"tooltip": "%s · %d 种职业 · %s 人" % [String(row.name),
					(row.professions as Array).size(), count(people)],
				"cells": _ledger_cells(row)})
		_table.selected_id = _selected
	_table.set_rows(rows)


## 阶层行与职业行共用同一套列：两边字段名一致，所以表格列不必分两套。
## 职业行在单列（窄）版面下额外用副标题写出所属阶层；双列版面里名字列只有
## 100px 出头，硬塞阶层名会被截成半个字（"自…"），不如交给图标配色与悬停提示。
func _ledger_cells(row: Dictionary) -> Dictionary:
	var people := float(row.get("population", 0.0))
	var alive := people > 0.0
	var stratum_name := String(row.get("stratum_name", ""))
	return {
		"name": {"text": String(row.name),
			"sub": stratum_name if _body.columns == 1 else "",
			"icon": row.icon, "icon_color": row.color,
			"sort": String(row.get("name", "")) if _mode == "profession" \
				else int(row.get("index", 0))},
		"population": {"text": count(people) if alive else "", "value": people},
		"share": {"value": float(row.get("share", 0.0)), "bar_color": row.color,
			"text": percent(float(row.get("share", 0.0)))},
		"income": {"text": money(float(row.get("income_per_capita", 0.0))),
			"value": float(row.get("income_per_capita", 0.0))},
		"expense": {"text": money(float(row.get("expense_per_capita", 0.0))),
			"value": float(row.get("expense_per_capita", 0.0))},
		"satisfaction": {"value": float(row.satisfaction) if alive else 0.0,
			"bar_color": satisfaction_color(float(row.satisfaction)),
			"text": percent(float(row.satisfaction)) if alive else ""},
		"survival": {"value": float(row.survival) if alive else 0.0,
			"bar_color": satisfaction_color(float(row.survival)),
			"text": percent(float(row.survival)) if alive else ""},
	}


func _refresh_detail(selected: Dictionary, national: PackedFloat32Array) -> void:
	if selected.is_empty():
		_detail_title.text = "暂无人口"
		_detail_meta.text = ""
		return
	var people := float(selected.population)
	var meta := PackedStringArray()
	var stratum_name := String(selected.get("stratum_name", ""))
	if not stratum_name.is_empty():
		meta.append(stratum_name)
	meta.append("%s 人" % count(people))
	meta.append("就业 %s" % count(float(selected.get("employed", 0.0))))
	meta.append("失业 %s" % count(float(selected.get("unemployed", 0.0))))
	_detail_title.text = String(selected.name)
	_detail_meta.text = " · ".join(meta)
	var dims: PackedFloat32Array = selected.dims
	_radar.set_values(PackedStringArray(EconomyDossierViewModel.SATISFACTION_DIMENSIONS), dims,
		national, selected.color)
	var tier_rows: Array = []
	for i in range(mini(EconomyDossierViewModel.CONSUMPTION_TIER_COUNT, dims.size())):
		tier_rows.append({"id": i, "label": EconomyDossierViewModel.SATISFACTION_DIMENSIONS[i],
			"value": maxf(0.0, dims[i]), "text": percent(dims[i]) if dims[i] >= 0.0 else "不适用", "color": satisfaction_color(dims[i]),
			"marker": national[i] if i < national.size() else -1.0,
			"tooltip": "%s需求满足率 %s" % [
				EconomyDossierViewModel.SATISFACTION_DIMENSIONS[i], percent(dims[i])]})
	_tiers.set_rows(tier_rows)
	var survival_caption := "生存 %s" % percent(float(selected.get("survival", 0.0)))
	var living := String(selected.get("living_name", ""))
	if not living.is_empty():
		survival_caption += " · %s" % living
	_sat_trend.set_metric({"id": "stratum_satisfaction", "title": "满意度趋势",
		"value": float(selected.satisfaction), "kind": "percent", "positive_good": true,
		"caption": survival_caption, "icon": &"population.heart",
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
	_refresh_professions(selected)
	var city_rows: Array = []
	for city in selected.get("cities", []):
		city_rows.append({"id": int(city.cell), "label": String(city.name),
			"value": float(city.satisfaction), "color": satisfaction_color(float(city.satisfaction)),
			"text": "%s 人 · %s" % [count(float(city.population)), percent(float(city.satisfaction))],
			"tooltip": "切换到此城市范围"})
	_cities.set_rows(city_rows)
	_show_empty(_cities_empty, _cities, "")


## 职业构成：阶层视角下列出该阶层的全部职业（不再截断到前 6），
## 职业视角下列出同阶层的其他职业作为对照；两处都可点。
func _refresh_professions(selected: Dictionary) -> void:
	var profession_rows: Array = []
	for profession in selected.get("professions", []):
		var people := float(profession.population)
		if people <= 0.0:
			continue
		profession_rows.append({"id": String(profession.id), "label": String(profession.name),
			"value": float(profession.get("share", 0.0)),
			"text": "%s · 满意 %s" % [count(people), percent(float(profession.satisfaction))],
			"color": selected.color,
			"tooltip": "%s 人 · 人均 %s / 日 · 点击只看该职业" % [count(people),
				money(float(profession.get("income_per_capita", 0.0)))]})
	_professions.selected_id = _selected_profession if _mode == "profession" else null
	_professions.set_rows(profession_rows)


func _on_row_selected(id) -> void:
	if _mode == "profession":
		_selected_profession = String(id)
		navigate_requested.emit(chapter_id, {"mode": "profession", "focus": _selected_profession})
		return
	_selected = int(id)
	navigate_requested.emit(chapter_id, {})


## 点职业 = 下钻。章节外壳负责把视角切到「职业」并把选中项带回来。
func _on_profession_selected(id) -> void:
	_selected_profession = String(id)
	navigate_requested.emit(chapter_id, {"mode": "profession", "focus": _selected_profession})


static func _series_delta(series: PackedFloat32Array) -> float:
	if series.size() < 2:
		return NAN
	var lookback := mini(7, series.size() - 1)
	var latest := series[series.size() - 1]
	var earlier := series[series.size() - 1 - lookback]
	return latest - earlier if not is_nan(latest) and not is_nan(earlier) else NAN


func _apply_narrow() -> void:
	# 断点可能在 _ready 之前就下发（卷宗在 NOTIFICATION_RESIZED 里调 set_narrow），
	# 那时 @onready 节点还是 null，等 _ready 后的第一次布局再说。
	if _body == null:
		return
	var columns := 1 if _narrow else 2
	if _body.columns == columns:
		return
	_body.columns = columns
	# 职业行的副标题只在单列版面出现（双列时名字列放不下），所以跨断点要重排行。
	if not _last_model.is_empty():
		_refresh_ledger(_last_model)
