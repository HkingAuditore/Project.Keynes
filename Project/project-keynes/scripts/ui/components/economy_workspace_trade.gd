extends RefCounted

## Display helpers borrow the host per call; state and signal receivers stay there.


static func _trade_cache_key(host) -> String:
	return "%s:%d" % [host._trade_view, host._trade_offset]


static func _trade_good_name(host, good_index: int) -> String:
	var economy = host._model.get("economy_facade", null)
	if economy != null and economy.has_method("good_display_name"):
		return String(economy.good_display_name(good_index))
	var good_ids: PackedStringArray = host._model.get("trade_summary", {}).get(
		"good_ids", PackedStringArray())
	return String(good_ids[good_index]) if good_index >= 0 and good_index < good_ids.size() \
		else "物资 %d" % good_index


static func _trade_partner_name(host, handle: int, slot: int) -> String:
	if handle > 0 and host._partner_name_cache.has(handle):
		return String(host._partner_name_cache[handle])
	var facade = host._model.get("country_facade", null)
	if facade != null and handle > 0 and facade.has_method("snapshot"):
		var snapshot: Dictionary = facade.snapshot(handle)
		if bool(snapshot.get("ok", false)):
			var name = String(snapshot.get("country_name",
				snapshot.get("display_name", "")))
			if not name.is_empty():
				host._partner_name_cache[handle] = name
				return name
	return "国家 %d" % slot


static func _refresh_trade_page(host, wanted: Dictionary) -> void:
	host._apply_trade_summary_cards()
	var economy = host._model.get("economy_facade", null)
	var country_handle = int(host._model.get("country_handle", 0))
	if economy == null or country_handle <= 0 or not economy.has_method(
			"country_trade_snapshot"):
		host._empty_label.text = "贸易数据暂不可用"
		host._empty_label.visible = true
		host._set_status("国家贸易查询暂不可用", true)
		return
	var summary: Dictionary = host._model.get("trade_summary", {})
	var revision = int(summary.get("revision", -1))
	if revision != host._trade_revision:
		host._trade_revision = revision
		host._trade_cache.clear()
	var cache_key = host._trade_cache_key()
	var page: Dictionary = host._trade_cache.get(cache_key, {})
	if page.is_empty():
		page = economy.country_trade_snapshot(country_handle, host._trade_view,
			host._trade_offset, 32)
		if bool(page.get("ok", false)):
			host._trade_cache[cache_key] = page
	if not bool(page.get("ok", false)):
		host._empty_label.text = String(page.get("reason", "贸易数据暂不可用"))
		host._empty_label.visible = true
		host._set_status("", false)
		return
	var total = int(page.get("total", 0))
	var begin = int(page.get("offset", host._trade_offset))
	var has_more = bool(page.get("has_more", false))
	host._trade_offset = begin
	host._trade_page_label.text = "%d-%d / %d" % [
		begin + 1 if total > 0 else 0,
		mini(begin + 32, total), total]
	host._trade_prev.disabled = begin <= 0
	host._trade_next.disabled = not has_more
	var row_count = 0
	if host._trade_view == "goods":
		var goods: PackedInt32Array = page.get("goods", PackedInt32Array())
		var imports: PackedInt64Array = page.get("import_quantity", PackedInt64Array())
		var exports: PackedInt64Array = page.get("export_quantity", PackedInt64Array())
		var import_base: PackedInt64Array = page.get("import_base", PackedInt64Array())
		var export_base: PackedInt64Array = page.get("export_base", PackedInt64Array())
		var import_tariff: PackedInt64Array = page.get("import_tariff", PackedInt64Array())
		var export_tariff: PackedInt64Array = page.get("export_tariff", PackedInt64Array())
		var cumulative_imports: PackedInt64Array = page.get(
			"cumulative_import_quantity", PackedInt64Array())
		var cumulative_exports: PackedInt64Array = page.get(
			"cumulative_export_quantity", PackedInt64Array())
		var cumulative_import_base: PackedInt64Array = page.get(
			"cumulative_import_base", PackedInt64Array())
		var cumulative_export_base: PackedInt64Array = page.get(
			"cumulative_export_base", PackedInt64Array())
		var cumulative_import_tariff: PackedInt64Array = page.get(
			"cumulative_import_tariff", PackedInt64Array())
		var cumulative_export_tariff: PackedInt64Array = page.get(
			"cumulative_export_tariff", PackedInt64Array())
		for index in range(goods.size()):
			var key = "goods:%d" % int(goods[index])
			var row = host._ensure_trade_row(key)
			var imported = int(imports[index]) if index < imports.size() else 0
			var exported = int(exports[index]) if index < exports.size() else 0
			var import_value = int(import_base[index]) if index < import_base.size() else 0
			var export_value = int(export_base[index]) if index < export_base.size() else 0
			var tariff = int(import_tariff[index]) if index < import_tariff.size() else 0
			tariff += int(export_tariff[index]) if index < export_tariff.size() else 0
			var all_imported = int(cumulative_imports[index]) \
				if index < cumulative_imports.size() else 0
			var all_exported = int(cumulative_exports[index]) \
				if index < cumulative_exports.size() else 0
			var all_import_value = int(cumulative_import_base[index]) \
				if index < cumulative_import_base.size() else 0
			var all_export_value = int(cumulative_export_base[index]) \
				if index < cumulative_export_base.size() else 0
			var all_tariff = int(cumulative_import_tariff[index]) \
				if index < cumulative_import_tariff.size() else 0
			all_tariff += int(cumulative_export_tariff[index]) \
				if index < cumulative_export_tariff.size() else 0
			(row.name as Label).text = host._trade_good_name(int(goods[index]))
			(row.detail as Label).text = "累计 %s / %s" % [
				host._money(all_import_value), host._money(all_export_value)]
			(row.quantity as Label).text = "%d / %d" % [imported, exported]
			(row.base as Label).text = host._money(import_value + export_value)
			(row.tariff as Label).text = host._money(tariff)
			(row.control as Control).tooltip_text = \
				"上一批：进口 %s，出口 %s，关税净额 %s\n累计：进口 %s（%d），出口 %s（%d），关税净额 %s" % [
					host._money(import_value), host._money(export_value), host._money(tariff),
					host._money(all_import_value), all_imported,
					host._money(all_export_value), all_exported, host._money(all_tariff)]
			wanted[key] = true
			row_count += 1
	else:
		var partners: PackedInt32Array = page.get("partners", PackedInt32Array())
		var handles: PackedInt64Array = page.get("partner_handles", PackedInt64Array())
		var imports: PackedInt64Array = page.get("import_quantity", PackedInt64Array())
		var exports: PackedInt64Array = page.get("export_quantity", PackedInt64Array())
		var import_base: PackedInt64Array = page.get("import_base", PackedInt64Array())
		var export_base: PackedInt64Array = page.get("export_base", PackedInt64Array())
		var orders: PackedInt64Array = page.get("order_count", PackedInt64Array())
		var cumulative_imports: PackedInt64Array = page.get(
			"cumulative_import_quantity", PackedInt64Array())
		var cumulative_exports: PackedInt64Array = page.get(
			"cumulative_export_quantity", PackedInt64Array())
		var cumulative_import_base: PackedInt64Array = page.get(
			"cumulative_import_base", PackedInt64Array())
		var cumulative_export_base: PackedInt64Array = page.get(
			"cumulative_export_base", PackedInt64Array())
		var cumulative_orders: PackedInt64Array = page.get(
			"cumulative_order_count", PackedInt64Array())
		for index in range(partners.size()):
			var slot = int(partners[index])
			var handle = int(handles[index]) if index < handles.size() else 0
			var key = "partners:%d" % handle if handle > 0 else "partners:slot:%d" % slot
			var row = host._ensure_trade_row(key)
			var imported = int(imports[index]) if index < imports.size() else 0
			var exported = int(exports[index]) if index < exports.size() else 0
			var import_value = int(import_base[index]) if index < import_base.size() else 0
			var export_value = int(export_base[index]) if index < export_base.size() else 0
			var all_imported = int(cumulative_imports[index]) \
				if index < cumulative_imports.size() else 0
			var all_exported = int(cumulative_exports[index]) \
				if index < cumulative_exports.size() else 0
			var all_import_value = int(cumulative_import_base[index]) \
				if index < cumulative_import_base.size() else 0
			var all_export_value = int(cumulative_export_base[index]) \
				if index < cumulative_export_base.size() else 0
			var all_orders = int(cumulative_orders[index]) \
				if index < cumulative_orders.size() else 0
			(row.name as Label).text = host._trade_partner_name(handle, slot)
			(row.detail as Label).text = "订单 %d · 累计 %d" % [
				int(orders[index]) if index < orders.size() else 0, all_orders]
			(row.quantity as Label).text = "%d / %d" % [imported, exported]
			(row.base as Label).text = host._money(import_value + export_value)
			(row.tariff as Label).text = "净额 %s" % host._money(export_value - import_value)
			(row.control as Control).tooltip_text = \
				"上一批：进口 %s，出口 %s\n累计：进口 %s（%d），出口 %s（%d），净出口 %s" % [
					host._money(import_value), host._money(export_value),
					host._money(all_import_value), all_imported,
					host._money(all_export_value), all_exported,
					host._money(all_export_value - all_import_value)]
			wanted[key] = true
			row_count += 1
	host._empty_label.visible = false
	host._set_status("")


static func _ensure_trade_row(host, key: String) -> Dictionary:
	if host._trade_rows.has(key):
		return host._trade_rows[key]
	var panel = host.TradeRowScene.instantiate() as PanelContainer
	panel.name = "Trade_%s" % key.replace(":", "_")
	var badge = panel.get_node("Body/Icon") as IconBadge
	badge.set_semantic(&"metric.trade", UITokens.ACCENT)
	host._flow.add_child(panel)
	host._watch_card_hover(panel)
	var result = {"control": panel,
		"name": panel.get_node("Body/Name") as Label,
		"detail": panel.get_node("Body/Detail") as Label,
		"quantity": panel.get_node("Body/Quantity") as Label,
		"base": panel.get_node("Body/Base") as Label,
		"tariff": panel.get_node("Body/Tariff") as Label,
		"page": "trade", "item_id": key}
	host._trade_rows[key] = result
	return result


static func _apply_trade_summary_cards(host) -> void:
	var summary: Dictionary = host._model.get("trade_summary", {})
	var available = bool(summary.get("ok", false))
	var imports = int(summary.get("previous_import_base", 0))
	var exports = int(summary.get("previous_export_base", 0))
	var net = int(summary.get("previous_net_export_base", exports - imports))
	var tariff = int(summary.get("previous_tariff_net_income", 0))
	var cumulative_imports = int(summary.get("cumulative_import_base", 0))
	var cumulative_exports = int(summary.get("cumulative_export_base", 0))
	var cumulative_tariff = int(summary.get("cumulative_tariff_net_income", 0))
	host._tax_card.set_data("昨日进口额", host._money(imports), "累计 %s" % host._money(cumulative_imports),
		UITokens.GOOD, "", "metric.trade", true)
	host._subsidy_card.set_data("昨日出口额", host._money(exports), "累计 %s" % host._money(cumulative_exports),
		UITokens.RESOURCE, "", "metric.trade", true)
	host._fulfillment_card.set_data("昨日净出口", host._money(net), "累计 %s" % host._money(
		cumulative_exports - cumulative_imports),
		UITokens.ACCENT, "", "metric.trade", true)
	host._cash_card.set_data("关税净收入", host._money(tariff) if available else "—",
		"累计 %s" % host._money(cumulative_tariff), UITokens.BRASS_HIGHLIGHT, "", "tax.tariff", true)
