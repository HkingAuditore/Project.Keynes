extends DossierPage

## 贸易：上一结算日进出口对冲、贸易伙伴净额、逐物资进出口账簿。
## 贸易是国家口径，单城市范围下仍显示全国数据并给出提示。
## 已作为「市场」章的下半段（market_page.tscn 里的 TradeSection）嵌入，
## chapter_id 由宿主指定，本场景不自带。

const GOODS_COLUMNS := [
	{"id": "name", "label": "物资", "kind": "text", "expand": true, "min_width": 110.0},
	{"id": "import", "label": "进口额", "kind": "money", "width": 78.0},
	{"id": "export", "label": "出口额", "kind": "money", "width": 78.0},
	{"id": "net", "label": "净出口", "kind": "diverging", "width": 116.0},
	{"id": "tariff", "label": "关税", "kind": "money", "width": 66.0, "optional": true},
	{"id": "cumulative", "label": "累计进 / 出", "kind": "text", "width": 128.0, "optional": true,
		"sortable": false},
]

@onready var _top: GridContainer = %Top
@onready var _balance: DossierDivergingBar = %BalanceBar
@onready var _balance_note: Label = %BalanceNote
@onready var _scope_note: Label = %ScopeNote
@onready var _partners: DossierBarList = %PartnerList
@onready var _partner_empty: Label = %PartnerEmpty
@onready var _content: Control = %Content
@onready var _goods: DossierLedgerTable = %GoodsTable
@onready var _empty: Label = %EmptyLabel


func _ready() -> void:
	_partners.diverging = true
	_partners.label_width = 96.0
	_partners.value_width = 132.0
	_goods.set_columns(GOODS_COLUMNS, "import")
	_goods.empty_text = "上一结算日没有成交的外贸订单"


func refresh(vm: EconomyDossierViewModel, _filter = null) -> void:
	var model := vm.trade_model()
	if not bool(model.get("ok", false)):
		_show_empty(_empty, _content, "对外贸易尚未开展：%s" % String(model.get("reason", "暂无贸易伙伴")))
		return
	_show_empty(_empty, _content, "")
	_scope_note.visible = vm.scope_cell >= 0
	var imports := float(model.imports)
	var exports := float(model.exports)
	_balance.set_values("进口", imports, money(imports), "出口", exports, money(exports))
	_balance_note.text = "%s %s · 关税净收入 %s\n累计进口 %s · 累计出口 %s" % [
		"顺差" if exports >= imports else "逆差", money(absf(exports - imports)),
		money(float(model.tariff)), money(float(model.cumulative_imports)),
		money(float(model.cumulative_exports))]
	_refresh_partners(model.partners)
	var peak := 0.0
	for row in model.goods:
		peak = maxf(peak, absf(float(row.net)))
	var rows: Array = []
	for row in model.goods:
		var net := float(row.net)
		rows.append({"id": int(row.id),
			"tooltip": "%s\n进口 %s 单位 · 出口 %s 单位" % [row.name,
				count(float(row.import_qty)), count(float(row.export_qty))],
			"cells": {
				"name": {"text": String(row.name)},
				"import": {"text": money(float(row["import"])), "value": float(row["import"])},
				"export": {"text": money(float(row["export"])), "value": float(row["export"])},
				"net": {"value": net / peak if peak > 0.0 else 0.0, "text": money(net), "sort": net},
				"tariff": {"text": money(float(row.tariff)), "value": float(row.tariff)},
				"cumulative": {"text": "%s / %s" % [money(float(row.cumulative_import)),
					money(float(row.cumulative_export))]},
			}})
	_goods.set_rows(rows)


func _refresh_partners(partners: Array) -> void:
	var peak := 0.0
	for row in partners:
		peak = maxf(peak, absf(float(row["export"]) - float(row["import"])))
	var rows: Array = []
	for row in partners:
		var net := float(row["export"]) - float(row["import"])
		rows.append({"id": int(row.id), "label": String(row.name),
			"value": net / peak if peak > 0.0 else 0.0,
			"text": "进 %s / 出 %s" % [money(float(row["import"])), money(float(row["export"]))],
			"tooltip": "%s：%d 笔订单，净出口 %s" % [row.name, int(row.orders), money(net)]})
	_partners.set_rows(rows)
	_show_empty(_partner_empty, _partners, "" if not rows.is_empty() else "暂无贸易伙伴")


func _apply_narrow() -> void:
	_top.columns = 1 if _narrow else 2
