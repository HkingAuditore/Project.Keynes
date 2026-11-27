extends RefCounted

## Builds and refreshes goods and trade-order detail.


static func _build_good_details(owner: ObjectDetailDialog, row: Dictionary, tax_context: Variant) -> void:
	# show_details 会重建整个卷宗节点；签名/模型必须清空，否则同身份重建后
	# _apply_trade_orders 会误判“数据未变”而跳过填表。
	owner._trade_orders_signature = ""
	owner._trade_orders_model = {}
	var root := ObjectDetailDialog.GoodDossierScene.instantiate() as VBoxContainer
	owner._content.add_child(root)
	var overview_page := root.get_node("%OverviewPage") as VBoxContainer
	var operations_page := root.get_node("%OperationsPage") as VBoxContainer
	var notes := root.get_node("%Notes") as InspectorNoteList
	var supply_demand_bar := root.get_node("%SupplyDemandBar") as DossierDivergingBar
	# 与 DemandSupplyBars 同为本地供需读数，二选一渲染避免同值重复。
	supply_demand_bar.visible = false
	var demand_supply_bars := root.get_node("%DemandSupplyBars") as DossierBarList
	var price_stock_bars := root.get_node("%PriceStockBars") as DossierBarList
	var trade_flow_bar := root.get_node("%TradeFlowBar") as DossierDivergingBar
	var trade_bars := root.get_node("%TradeBars") as DossierBarList
	var trade_empty_note := root.get_node("%TradeEmptyNote") as Label
	var orders_table := root.get_node("%TradeOrdersTable") as DossierLedgerTable
	var orders_hint := root.get_node("%TradeOrdersHint") as Label
	var orders_footer := root.get_node("%TradeOrdersFooter") as Control
	var orders_page_label := root.get_node("%TradeOrdersPage") as Label
	var orders_prev := root.get_node("%TradeOrdersPrev") as Button
	var orders_next := root.get_node("%TradeOrdersNext") as Button

	demand_supply_bars.label_width = 96.0
	demand_supply_bars.value_width = 76.0
	price_stock_bars.label_width = 96.0
	price_stock_bars.value_width = 76.0
	trade_bars.label_width = 96.0
	trade_bars.value_width = 76.0
	orders_table.set_columns(owner._trade_order_columns(), "", true)
	orders_table.row_height = 28.0
	orders_table.focus_mode = Control.FOCUS_NONE
	orders_table.row_selected.connect(owner._on_trade_order_row_selected)
	IconButton.apply(orders_prev, &"action.back", IconButton.MEDIUM, "上一页")
	IconButton.apply(orders_next, &"action.chevron_right", IconButton.MEDIUM, "下一页")
	orders_prev.focus_mode = Control.FOCUS_NONE
	orders_next.focus_mode = Control.FOCUS_NONE
	orders_prev.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	orders_next.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	orders_prev.pressed.connect(owner._request_trade_orders_page.bind(-1))
	orders_next.pressed.connect(owner._request_trade_orders_page.bind(1))

	owner._fact_columns = [2]
	owner._good_refs = {
		"root": root,
		"overview_page": overview_page,
		"operations_page": operations_page,
		"notes": notes,
		"supply_demand_bar": supply_demand_bar,
		"demand_supply_bars": demand_supply_bars,
		"price_stock_bars": price_stock_bars,
		"trade_flow_bar": trade_flow_bar,
		"trade_bars": trade_bars,
		"trade_empty_note": trade_empty_note,
		"orders_table": orders_table,
		"orders_hint": orders_hint,
		"orders_footer": orders_footer,
		"orders_page": orders_page_label,
		"orders_prev": orders_prev,
		"orders_next": orders_next,
	}
	owner._section_targets["overview"] = overview_page
	owner._section_targets["operations"] = operations_page
	owner._build_tax_section("good", tax_context, row, operations_page)
	owner._apply_good_dossier_data(row, false)



static func _patch_good_dossier(owner: ObjectDetailDialog, row: Dictionary) -> void:
	owner._apply_good_dossier_data(row, true)



static func _apply_good_dossier_data(owner: ObjectDetailDialog, row: Dictionary, live_patch: bool) -> void:
	var dossier := CellInspectorViewModel.good_dossier_model(row)
	owner._apply_kpis(dossier.get("kpis", []), live_patch)
	var notes := owner._good_refs.get("notes") as InspectorNoteList
	if notes != null:
		var insights: Array = dossier.get("insights", [])
		notes.set_notes(insights)
		notes.visible = not insights.is_empty()
	var sd: Dictionary = dossier.get("supply_demand_bar", {})
	var sd_bar := owner._good_refs.get("supply_demand_bar") as DossierDivergingBar
	if sd_bar != null:
		sd_bar.set_values(
			String(sd.get("left_label", "本地需求")),
			float(sd.get("left_value", 0.0)),
			String(sd.get("left_text", "0")),
			String(sd.get("right_label", "本地供给")),
			float(sd.get("right_value", 0.0)),
			String(sd.get("right_text", "0"))
		)
	var ds_bars := owner._good_refs.get("demand_supply_bars") as DossierBarList
	if ds_bars != null:
		ds_bars.set_rows(dossier.get("demand_supply_bars", []))
	var ps_bars := owner._good_refs.get("price_stock_bars") as DossierBarList
	if ps_bars != null:
		ps_bars.set_rows(dossier.get("price_stock_bars", []))
	var tf: Dictionary = dossier.get("trade_flow_bar", {})
	var tf_bar := owner._good_refs.get("trade_flow_bar") as DossierDivergingBar
	if tf_bar != null:
		tf_bar.set_values(
			String(tf.get("left_label", "外销流出")),
			float(tf.get("left_value", 0.0)),
			String(tf.get("left_text", "0")),
			String(tf.get("right_label", "采购流入")),
			float(tf.get("right_value", 0.0)),
			String(tf.get("right_text", "0"))
		)
	var t_bars := owner._good_refs.get("trade_bars") as DossierBarList
	if t_bars != null:
		t_bars.set_rows(dossier.get("trade_bars", []))
	var empty_note := owner._good_refs.get("trade_empty_note") as Label
	if empty_note != null:
		var has_trade := float(tf.get("left_value", 0.0)) > 0.0001 \
			or float(tf.get("right_value", 0.0)) > 0.0001
		empty_note.text = "当前无在途商队与跨区贸易流水。"
		empty_note.visible = not has_trade


# ─── 物资详情 · 逐单商路 ──────────────────────────────────────────────
# 数据由 CellInspectorViewModel.trade_orders_model 生成；这里只做控件 patch，
# 不重建节点树，也不在日 tick 里自行查询/计算。
static func _trade_order_columns(owner: ObjectDetailDialog) -> Array:
	return [
		{"id": "dir", "label": "方向", "width": 42.0},
		{"id": "counterpart", "label": "对端", "expand": true, "min_width": 78.0},
		{"id": "quantity", "label": "数量", "width": 52.0, "kind": "number"},
		{"id": "price", "label": "单价", "width": 92.0, "kind": "money", "optional": true},
		{"id": "route", "label": "行程", "width": 82.0, "kind": "bar"},
		{"id": "status", "label": "状态", "width": 44.0, "optional": true},
	]



static func _apply_trade_orders(owner: ObjectDetailDialog, model_value: Variant) -> void:
	var table := owner._good_refs.get("orders_table") as DossierLedgerTable
	if table == null:
		return
	var hint := owner._good_refs.get("orders_hint") as Label
	var footer := owner._good_refs.get("orders_footer") as Control
	var page_label := owner._good_refs.get("orders_page") as Label
	var prev := owner._good_refs.get("orders_prev") as Button
	var next := owner._good_refs.get("orders_next") as Button
	var model: Dictionary = model_value if model_value is Dictionary else {}
	if model.is_empty():
		owner._trade_orders_signature = ""
		owner._trade_orders_model = {}
		table.empty_text = ""
		table.set_rows([])
		if hint != null:
			hint.text = ""
			hint.visible = false
		if footer != null:
			footer.visible = false
		return
	if bool(model.get("pending", false)):
		# 结算中：保留上一页；现有 200ms 重试会在 committed 后拿到新页。
		if hint != null:
			hint.text = String(model.get("hint", "经济结算中，沿用上次结果。"))
		return
	if not bool(model.get("ok", false)):
		owner._trade_orders_signature = ""
		owner._trade_orders_model = {}
		table.empty_text = String(model.get("empty_text", "贸易流水暂不可用。"))
		table.set_rows([])
		if hint != null:
			hint.text = String(model.get("hint", "贸易流水暂不可用。"))
		if footer != null:
			footer.visible = false
		return
	var signature := String(model.get("signature", ""))
	if signature == owner._trade_orders_signature:
		return
	owner._trade_orders_signature = signature
	owner._trade_orders_model = model
	table.empty_text = String(model.get("empty_text", ""))
	table.set_rows(model.get("rows", []))
	if hint != null:
		hint.text = String(model.get("hint", ""))
	if page_label != null:
		page_label.text = String(model.get("page_label", ""))
	var limit := maxi(1, int(model.get("limit", 12)))
	var total := maxi(0, int(model.get("total", 0)))
	if footer != null:
		footer.visible = total > limit
	if prev != null:
		prev.disabled = int(model.get("offset", 0)) <= 0
	if next != null:
		next.disabled = not bool(model.get("has_more", false))



static func _request_trade_orders_page(owner: ObjectDetailDialog, step: int) -> void:
	if owner._trade_orders_model.is_empty():
		return
	var limit := maxi(1, int(owner._trade_orders_model.get("limit", 12)))
	var total := maxi(0, int(owner._trade_orders_model.get("total", 0)))
	var offset := int(owner._trade_orders_model.get("offset", 0))
	var target := offset + step * limit
	var max_offset := maxi(0, ((maxi(total, 1) - 1) / limit) * limit)
	target = clampi(target, 0, max_offset)
	if target == offset and step != 0:
		return
	owner.trade_orders_page_requested.emit(target)



static func _on_trade_order_row_selected(owner: ObjectDetailDialog, row_id: Variant) -> void:
	var rows_by_id: Dictionary = owner._trade_orders_model.get("rows_by_id", {})
	var row: Dictionary = rows_by_id.get(row_id, {})
	var cell := int(row.get("locate_cell", -1))
	if cell >= 0:
		owner.trade_order_locate_requested.emit(cell)


# ─── 测试钩子（逐单商路） ─────────────────────────────────────────────
static func trade_orders_row_count(owner: ObjectDetailDialog) -> int:
	var table := owner._good_refs.get("orders_table") as DossierLedgerTable
	return table.row_count() if table != null else 0



static func trade_orders_hint_text(owner: ObjectDetailDialog) -> String:
	var hint := owner._good_refs.get("orders_hint") as Label
	return hint.text if hint != null else ""



static func trade_orders_offset(owner: ObjectDetailDialog) -> int:
	return int(owner._trade_orders_model.get("offset", 0))



static func trade_orders_page_text(owner: ObjectDetailDialog) -> String:
	var label := owner._good_refs.get("orders_page") as Label
	return label.text if label != null else ""



static func current_trade_orders_model(owner: ObjectDetailDialog) -> Dictionary:
	return owner._trade_orders_model
