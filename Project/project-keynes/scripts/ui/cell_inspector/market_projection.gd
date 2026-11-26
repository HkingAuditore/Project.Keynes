extends RefCounted

## Builds market, demand, and trade-order projections from published values.

const TRADE_ORDER_PAGE_SIZE = 12


static func _demand_good_metadata(host, snapshot: Dictionary, cohort_idx: int) -> Dictionary:
	var h = host
	var populations: PackedInt64Array = snapshot.get("populations", PackedInt64Array())
	var good_ids: PackedStringArray = snapshot.get("demand_good_stable_ids", PackedStringArray())
	var need_ids: PackedStringArray = snapshot.get("demand_need_stable_ids", PackedStringArray())
	var need_offsets: PackedInt32Array = snapshot.get("demand_need_offsets", PackedInt32Array())
	var need_indices: PackedInt32Array = snapshot.get("demand_need_indices", PackedInt32Array())
	var need_variant_offsets: PackedInt32Array = snapshot.get(
		"demand_need_variant_offsets", PackedInt32Array())
	var variant_component_offsets: PackedInt32Array = snapshot.get(
		"demand_variant_component_offsets", PackedInt32Array())
	var component_good_indices: PackedInt32Array = snapshot.get(
		"demand_component_good_indices", PackedInt32Array())
	var component_quantities: PackedInt64Array = snapshot.get(
		"demand_component_per_capita_daily", PackedInt64Array())
	if cohort_idx < 0 or cohort_idx >= populations.size() \
			or need_offsets.size() != populations.size() + 1 \
			or need_variant_offsets.size() != need_indices.size() + 1 \
			or variant_component_offsets.is_empty() \
			or component_good_indices.size() != component_quantities.size() \
			or variant_component_offsets[-1] != component_good_indices.size():
		return {"ok": false}
	var need_begin = int(need_offsets[cohort_idx])
	var need_end = int(need_offsets[cohort_idx + 1])
	if need_begin < 0 or need_end < need_begin or need_end > need_indices.size():
		return {"ok": false}
	var good_metadata = {}
	for need_cursor in range(need_begin, need_end):
		var need_idx = int(need_indices[need_cursor])
		if need_idx < 0 or need_idx >= need_ids.size():
			return {"ok": false}
		var variant_begin = int(need_variant_offsets[need_cursor])
		var variant_end = int(need_variant_offsets[need_cursor + 1])
		if variant_begin < 0 or variant_end < variant_begin \
				or variant_end + 1 > variant_component_offsets.size():
			return {"ok": false}
		var need_id = String(need_ids[need_idx])
		var need_name = host._PopulationMarket_delegate._need_display_name(host, need_id)
		for variant_cursor in range(variant_begin, variant_end):
			var component_begin = int(variant_component_offsets[variant_cursor])
			var component_end = int(variant_component_offsets[variant_cursor + 1])
			if component_begin < 0 or component_end < component_begin \
					or component_end > component_good_indices.size():
				return {"ok": false}
			var component_count = component_end - component_begin
			for component_cursor in range(component_begin, component_end):
				var good_idx = int(component_good_indices[component_cursor])
				if good_idx < 0 or good_idx >= good_ids.size():
					return {"ok": false}
				var stable_id = String(good_ids[good_idx])
				var metadata: Dictionary = good_metadata.get(stable_id, {
					"need_ids": [],
					"need_names": [],
					"has_bundle": false,
					"has_substitute": false,
				})
				var metadata_need_ids: Array = metadata.get("need_ids", [])
				var metadata_need_names: Array = metadata.get("need_names", [])
				if not metadata_need_ids.has(need_id):
					metadata_need_ids.append(need_id)
					if not metadata_need_names.has(need_name):
						metadata_need_names.append(need_name)
				metadata["need_ids"] = metadata_need_ids
				metadata["need_names"] = metadata_need_names
				metadata["has_bundle"] = bool(metadata.get("has_bundle", false)) \
					or component_count > 1
				metadata["has_substitute"] = bool(metadata.get("has_substitute", false)) \
					or variant_end - variant_begin > 1
				good_metadata[stable_id] = metadata
	return {
		"ok": true,
		"good_metadata": good_metadata,
	}



static func _need_display_name(host, stable_id: String) -> String:
	var h = host
	if not host._need_display_names_loaded:
		host._need_display_names = EconomyCatalog.need_display_names()
		host._need_display_names_loaded = true
	return String(host._need_display_names.get(stable_id, stable_id))



static func _market_category(host, snapshot: Dictionary) -> Dictionary:
	var h = host
	if host._snapshot_pending(snapshot):
		return host._pending_category()
	if snapshot.is_empty() or not bool(snapshot.get("ok", false)):
		return {"insights": [{"id": "market_unavailable", "text": "市场情报暂不可用。", "accent": UITokens.TEXT_MUTED, "icon": "resource"}]}
	if not snapshot.has("good_ids"):
		return {"insights": [{"id": "market_details_unavailable", "text": "无法读取最新市场明细。", "accent": UITokens.RISK, "icon": "resource"}]}
	var rows = []
	var good_ids: PackedStringArray = snapshot.get("good_ids", PackedStringArray())
	var stock: PackedInt64Array = snapshot.get("stock", PackedInt64Array())
	var prices: PackedInt32Array = snapshot.get("price", PackedInt32Array())
	var demand_ema: PackedInt64Array = snapshot.get("demand_ema", PackedInt64Array())
	var business_demand_ema: PackedInt64Array = snapshot.get("business_demand_ema", PackedInt64Array())
	var offered_supply_ema: PackedInt64Array = snapshot.get("offered_supply_ema", PackedInt64Array())
	var cost_anchor: PackedInt32Array = snapshot.get("cost_anchor_price", PackedInt32Array())
	var reference_ceiling: PackedInt32Array = snapshot.get("price_reference_ceiling", PackedInt32Array())
	var base_ceiling: PackedInt32Array = snapshot.get("price_base_ceiling", PackedInt32Array())
	var effective_ceiling: PackedInt32Array = snapshot.get("price_effective_ceiling", PackedInt32Array())
	var target_ceiling: PackedInt32Array = snapshot.get("price_target_ceiling", PackedInt32Array())
	var confirmation_days: PackedInt32Array = snapshot.get("price_ceiling_confirmation_days", PackedInt32Array())
	var shortage_q16: PackedInt32Array = snapshot.get("shortage_q16", PackedInt32Array())
	var technology_available: PackedByteArray = snapshot.get(
		"good_technology_available", PackedByteArray())
	var trade_enabled: PackedByteArray = snapshot.get(
		"good_trade_enabled", PackedByteArray())
	var trade_inbound: PackedInt64Array = snapshot.get(
		"trade_inbound", PackedInt64Array())
	var trade_outbound: PackedInt64Array = snapshot.get(
		"trade_outbound", PackedInt64Array())
	var trade_import_ema: PackedInt64Array = snapshot.get(
		"trade_import_ema", PackedInt64Array())
	var trade_export_ema: PackedInt64Array = snapshot.get(
		"trade_export_ema", PackedInt64Array())
	var enforce_technology = technology_available.size() == good_ids.size()
	var market_id = int(snapshot.get("market_id", snapshot.get("cell_idx", -1)))
	var sample_day = int(snapshot.get("sample_day", h._Geography_delegate._current_sample_day(h)))
	if market_id >= 0:
		host._PopulationMarket_delegate._ensure_detail_history_cell(host, market_id)
	var should_sample_market = market_id >= 0 and sample_day >= 0 \
		and sample_day != host._detail_history_market_day
	if should_sample_market:
		host._detail_history_market_day = sample_day
	var in_transit_kinds = 0
	for i in range(good_ids.size()):
		if enforce_technology and technology_available[i] == 0:
			continue
		var stable_id = String(good_ids[i])
		var profile = GoodProfileRegistry.profile_by_id(stable_id)
		var display_name = String(profile.display_name) if profile != null else stable_id
		var stock_raw = int(stock[i]) if i < stock.size() else 0
		var stock_units = float(stock_raw) / 1000.0
		var price_raw = int(prices[i]) if i < prices.size() else 0
		var price_val = float(price_raw) / 10000.0
		var anchor_raw = int(cost_anchor[i]) if i < cost_anchor.size() else 0
		var anchor_val = float(anchor_raw) / 10000.0
		var price_index = float(price_raw) / float(anchor_raw) if anchor_raw > 0 else 1.0
		var hh_demand_units = float(demand_ema[i]) / 1000.0 if i < demand_ema.size() else 0.0
		var biz_demand_units = float(business_demand_ema[i]) / 1000.0 if i < business_demand_ema.size() else 0.0
		var total_demand_units = hh_demand_units + biz_demand_units
		var supply_units = float(offered_supply_ema[i]) / 1000.0 if i < offered_supply_ema.size() else 0.0
		var stock_daily = host._sample_daily_delta(host._market_prev_stock,
			"%d:%s" % [market_id, stable_id], stock_units, sample_day)
		var shortage = float(shortage_q16[i]) * 100.0 / 65536.0 if i < shortage_q16.size() else 0.0
		var allow_trade = host._Construction_delegate._market_trade_enabled(host, trade_enabled, i)
		var inbound = host._Construction_delegate._packed_i64_at(host, trade_inbound, i) if allow_trade else 0
		var outbound = host._Construction_delegate._packed_i64_at(host, trade_outbound, i) if allow_trade else 0
		var import_flow = host._Construction_delegate._packed_i64_at(host, trade_import_ema, i) if allow_trade else 0
		var export_flow = host._Construction_delegate._packed_i64_at(host, trade_export_ema, i) if allow_trade else 0
		var inbound_units = float(inbound) / 1000.0
		var outbound_units = float(outbound) / 1000.0
		var import_flow_units = float(import_flow) / 1000.0
		var export_flow_units = float(export_flow) / 1000.0
		var in_transit = inbound > 0 or outbound > 0
		if in_transit:
			in_transit_kinds += 1
		if should_sample_market:
			host._PopulationMarket_delegate._record_good_history(host, stable_id, price_val, price_index, stock_units, shortage / 100.0)
		var good_hist: Dictionary = host._good_history.get(stable_id, {})
		var price_series: PackedFloat32Array = good_hist.get("price", PackedFloat32Array())
		var stock_series: PackedFloat32Array = good_hist.get("stock", PackedFloat32Array())
		var stock_plain = host._Construction_delegate._goods_unit_text(host, stock_raw)
		# 列表副行只给数量：列头已写「库存」，每行再带一次「单位」只是噪音。
		var stock_text = UITokens.format_compact_number_cn(stock_units, 2)
		var anchor_text = h._money_text(anchor_raw) if anchor_raw > 0 else "—"
		var days_of_stock = stock_units / total_demand_units if total_demand_units > 0.001 \
			else (999.0 if stock_units > 0.001 else 0.0)
		var detail_rows = [
			{"id": "household_demand", "name": "居民需求", "value": UITokens.format_compact_number_cn(hh_demand_units, 2)},
			{"id": "business_demand", "name": "产业需求", "value": UITokens.format_compact_number_cn(biz_demand_units, 2)},
			{"id": "supply", "name": "供给", "value": UITokens.format_compact_number_cn(supply_units, 2)},
			{"id": "cost_anchor", "name": "成本锚", "value": anchor_text},
			{"id": "price_index", "name": "价格倍率", "value": "%.2f 倍" % price_index if anchor_raw > 0 else "—"},
			{"id": "shortage", "name": "短缺", "value": "%.1f%%" % shortage},
		]
		if inbound > 0:
			detail_rows.append({"id": "trade_inbound", "name": "运入",
				"value": h._Construction_delegate._goods_unit_text(h, inbound)})
		if outbound > 0:
			detail_rows.append({"id": "trade_outbound", "name": "运出",
				"value": h._Construction_delegate._goods_unit_text(h, outbound)})
		if import_flow > 0:
			detail_rows.append({"id": "trade_import_flow", "name": "进口均量",
				"value": h._Construction_delegate._goods_unit_text(h, import_flow)})
		if export_flow > 0:
			detail_rows.append({"id": "trade_export_flow", "name": "出口均量",
				"value": h._Construction_delegate._goods_unit_text(h, export_flow)})
		rows.append({
			"id": "market_%s" % stable_id,
			"name": display_name,
			"good_id": stable_id,
			"stock": "%s · 在途" % stock_text if in_transit else stock_text,
			"stock_plain": stock_plain,
			"stock_units_float": stock_units,
			"days_of_stock_float": days_of_stock,
			"price": h._money_text(price_raw),
			"price_float": price_val,
			"cost_anchor_text": anchor_text,
			"cost_anchor_float": anchor_val,
			"price_index_float": price_index,
			"household_demand_float": hh_demand_units,
			"business_demand_float": biz_demand_units,
			"supply_float": supply_units,
			"shortage_float": shortage / 100.0,
			"inbound_float": inbound_units,
			"outbound_float": outbound_units,
			"import_flow_float": import_flow_units,
			"export_flow_float": export_flow_units,
			"price_spark": price_series,
			"price_delta": CellInspectorViewModel._PopulationMarket._series_lookback_delta(price_series),
			"stock_spark": stock_series,
			"stock_delta": stock_daily,
			"delta": h._daily_delta_text(stock_daily),
			"risk": "短缺" if shortage >= 25.0 else "",
			"trade_inbound": h._Construction_delegate._goods_unit_text(h, inbound) if inbound > 0 else "",
			"trade_outbound": h._Construction_delegate._goods_unit_text(h, outbound) if outbound > 0 else "",
			"detail_rows": detail_rows,
			"accent": UITokens.RISK if shortage >= 25.0 else UITokens.RESOURCE,
			"icon": GoodProfileRegistry.icon_key(stable_id),
			"visible": true,
			"_rank": (0 if shortage >= 25.0 else (1 if in_transit else (
				2 if i < stock.size() and stock[i] > 0 else 3))) * 100000 + rows.size(),
		})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["_rank"]) < int(b["_rank"]))
	for row_value in rows:
		(row_value as Dictionary).erase("_rank")
	var trade_net = int(snapshot.get("merchant_trade_sale_cash", 0)) \
		- int(snapshot.get("merchant_trade_purchase_cash", 0))
	var arrival_days = host._Construction_delegate._trade_arrival_days(host,
		int(snapshot.get("trade_next_arrival_day", -1)), sample_day)
	var market_insights = []
	if in_transit_kinds > 0:
		market_insights.append({
			"id": "market_trade_in_transit",
			"text": h._Construction_delegate._market_trade_insight_text(h, in_transit_kinds, arrival_days),
			"accent": UITokens.ACCENT,
			"icon": "metric.trade",
		})
	return {
		"insights": market_insights,
		"metrics": [
			{"id": "merchant_cash", "title": "商家现金", "money": true, "value": h._money_text(int(snapshot.get("merchant_cash", 0))), "subtitle": "", "accent": UITokens.ACCENT, "icon": "resource"},
			{"id": "merchant_trade_net", "title": "贸易净额", "money": true, "value": h._money_text(trade_net), "subtitle": "", "accent": UITokens.ACCENT if trade_net == 0 else (UITokens.GOOD if trade_net > 0 else UITokens.RISK), "icon": "resource"},
		],
		"sections": [{
			"id": "merchant_accounts",
			"title": "商家账目",
			"icon": "resource",
			"accent": UITokens.RESOURCE,
			"collapsed": true,
			"metrics": [
				{"id": "merchant_inventory_liquidation", "title": "库存估值", "money": true, "value": h._money_text(int(snapshot.get("merchant_inventory_liquidation_value", 0))), "subtitle": "", "tooltip": "按零售价估算的库存价值。", "accent": UITokens.RESOURCE, "icon": "resource"},
				{"id": "merchant_assets", "title": "商业资产", "money": true, "value": h._money_text(int(snapshot.get("merchant_economic_assets", 0))), "subtitle": "", "tooltip": "现金加库存估值。", "accent": UITokens.GOOD, "icon": "resource"},
				{"id": "merchant_coverage", "title": "周转覆盖", "value": "%s 期" % UITokens.format_compact_number_cn(float(snapshot.get("merchant_liquidity_coverage_q16", 65536)) / 65536.0, 1), "subtitle": "", "tooltip": "现金可支撑的经营期数。", "accent": UITokens.ACCENT, "icon": "resource"},
				{"id": "merchant_margin", "title": "采购毛利", "money": true, "value": h._money_text(int(snapshot.get("merchant_procurement_margin_value", 0))), "subtitle": "", "accent": UITokens.GOOD, "icon": "resource"},
			],
		}],
		"market_rows": rows,
		"list_header": {"lead": "商品 · 库存", "indent": 39.0, "columns": [
			{"text": "价格", "width": 84.0}]},
		# 物资详情逐单商路用：订单页只会在 committed generation 变化后失效。
		"economy_generation": int(snapshot.get("economy_generation", -1)),
		"sample_day": sample_day,
	}


# ─── 物资详情 · 逐单商路 ──────────────────────────────────────────────────
# 对象详情打开后按需查询；页缓存按 committed generation，行缓存再叠加
# sample_day 与视野 revision，因此日 tick / 200ms live patch 不会重复查询原生。
# 对端名称只为 FOG_VISIBLE 的格子读取；不可见对端在本层遮蔽，不查询名称。


static func trade_orders_model(host, cell_idx: int, good_id: String, offset: int = 0,
		limit: int = TRADE_ORDER_PAGE_SIZE, generation: int = -1,
		sample_day: int = -1) -> Dictionary:
	var h = host
	if host._map == null or cell_idx < 0:
		return h._PopulationMarket_delegate._trade_orders_failure(h, "", "trade_orders_map_unavailable")
	if VisionSolver.displayed_fog_state(host._map, cell_idx) != VisionSolver.FOG_VISIBLE:
		return h._PopulationMarket_delegate._trade_orders_failure(h, "此地不在当前视野内。", "cell_not_visible")
	var facade = host._economy_facade()
	if facade == null or not facade.has_method("trade_orders_for_cell"):
		return h._PopulationMarket_delegate._trade_orders_failure(h, "贸易数据暂不可用。", "trade_order_api_unavailable")
	var good_index = host._PopulationMarket_delegate._trade_order_good_index(host, facade, good_id)
	if good_index < 0:
		return h._PopulationMarket_delegate._trade_orders_failure(h, "物资不在当前列表中。", "unknown_good")
	var page_limit = clampi(limit, 1, 64)
	var page_offset = maxi(0, offset)
	var resolved_sample_day = sample_day if sample_day >= 0 else host._Geography_delegate._current_sample_day(host)
	if generation >= 0 and generation != host._trade_order_generation:
		host._trade_order_generation = generation
		host._trade_order_pages.clear()
		host._trade_order_models.clear()
		host._trade_order_names.clear()
	if generation >= 0:
		var page_key = host._PopulationMarket_delegate._trade_order_page_key(host,
			cell_idx, good_index, generation, page_offset, page_limit)
		var page: Dictionary = host._trade_order_pages.get(page_key, {})
		if page.is_empty():
			page = host._PopulationMarket_delegate._query_trade_order_page(host,
				facade, cell_idx, good_index, page_offset, page_limit)
			if bool(page.get("pending", false)):
				return host._PopulationMarket_delegate._trade_orders_pending_model(host,
					page, page_offset, page_limit, resolved_sample_day, generation)
			if not bool(page.get("ok", false)):
				return h._PopulationMarket_delegate._trade_orders_failure(h, "贸易流水暂不可用。",
					String(page.get("reason", "trade_order_query_failed")))
			host._trade_order_pages[page_key] = page
			CellInspectorViewModel._PopulationMarket._trim_dictionary(host._trade_order_pages, host.TRADE_ORDER_PAGE_CACHE_LIMIT)
			# 总数缩小导致请求 offset 越界时，把原生钳制后的末页别名回请求 key，
			# 避免之后每次刷新都重新查询一次。
			var effective = int(page.get("page_begin", page_offset))
			if effective != page_offset:
				host._trade_order_pages[host._PopulationMarket_delegate._trade_order_page_key(host,
					cell_idx, good_index, generation, effective, page_limit)] = page
		var model_key = "%s|%d|%d" % [page_key, resolved_sample_day,
			int(host._map.vision_revision)]
		var cached_model: Dictionary = host._trade_order_models.get(model_key, {})
		if not cached_model.is_empty():
			return cached_model
		var built = host._PopulationMarket_delegate._build_trade_orders_model(host, page, resolved_sample_day, generation)
		host._trade_order_models[model_key] = built
		CellInspectorViewModel._PopulationMarket._trim_dictionary(host._trade_order_models, host.TRADE_ORDER_MODEL_CACHE_LIMIT)
		return built
	# generation 缺失只可能出现在旧桥/异常路径：退化为每次有界查询，不保留页缓存。
	var uncached_page = host._PopulationMarket_delegate._query_trade_order_page(host,
		facade, cell_idx, good_index, page_offset, page_limit)
	if bool(uncached_page.get("pending", false)):
		return host._PopulationMarket_delegate._trade_orders_pending_model(host,
			uncached_page, page_offset, page_limit, resolved_sample_day, generation)
	if not bool(uncached_page.get("ok", false)):
		return h._PopulationMarket_delegate._trade_orders_failure(h, "贸易流水暂不可用。",
			String(uncached_page.get("reason", "trade_order_query_failed")))
	return host._PopulationMarket_delegate._build_trade_orders_model(host,
		uncached_page, resolved_sample_day, generation)



static func _trade_order_page_key(host, cell_idx: int, good_index: int, generation: int,
		offset: int, limit: int) -> String:
	var h = host
	return "%d|%d|%d|%d|%d" % [cell_idx, good_index, generation, offset, limit]



static func _query_trade_order_page(host, facade, cell_idx: int, good_index: int,
		offset: int, limit: int) -> Dictionary:
	var h = host
	var page: Dictionary = facade.trade_orders_for_cell(
		cell_idx, offset, limit, good_index)
	host._trade_order_query_count += 1
	if h._snapshot_pending(page) or String(page.get("reason", "")) == "economy_read_view_pending":
		page["pending"] = true
	return page



static func _trade_order_good_index(host, facade, good_id: String) -> int:
	var h = host
	var stable_id = good_id.strip_edges()
	if stable_id.is_empty():
		return -1
	if host._trade_order_good_indices.is_empty():
		var ids: PackedStringArray = facade.good_ids() \
			if facade.has_method("good_ids") else PackedStringArray()
		for index in range(ids.size()):
			host._trade_order_good_indices[String(ids[index])] = index
	return int(host._trade_order_good_indices.get(stable_id, -1))



static func _economy_facade(host):
	var h = host
	if h._generator == null or not h._generator.has_method("get_economy_facade"):
		return null
	return host._generator.get_economy_facade()



static func _trade_orders_failure(host, text: String, reason: String) -> Dictionary:
	var h = host
	return {"ok": false, "pending": false, "reason": reason,
		"rows": [], "rows_by_id": {}, "total": 0, "offset": 0,
		"limit": h.TRADE_ORDER_PAGE_SIZE, "has_more": false,
		"page_label": "", "hint": text, "empty_text": text,
		"signature": "", "sample_day": -1, "economy_generation": -1}



static func _trade_orders_pending_model(host, page: Dictionary, offset: int, limit: int,
		sample_day: int, generation: int) -> Dictionary:
	var h = host
	return {"ok": false, "pending": true,
		"reason": String(page.get("reason", "economy_read_view_pending")),
		"rows": [], "rows_by_id": {}, "total": 0, "offset": offset,
		"limit": limit, "has_more": false, "page_label": "",
		"hint": "经济结算中，沿用上次结果。",
		"empty_text": "经济结算中，暂无可读订单。",
		"signature": "", "sample_day": sample_day,
		"economy_generation": generation}



static func _trim_dictionary(cache: Dictionary, limit: int) -> void:
	while cache.size() > limit:
		cache.erase(cache.keys()[0])



static func _build_trade_orders_model(host, page: Dictionary,
		sample_day: int, generation: int) -> Dictionary:
	var h = host
	# 倒计时按 UI 当前世界日计算：订单页的 native sample_day 是上一次 committed
	# 边界，若拿它当“今天”，快进期间剩余天数会一直卡住。generation 只用于缓存。
	var day = sample_day
	if day < 0:
		day = host._Geography_delegate._current_sample_day(host)
	var order_ids: PackedInt64Array = page.get("order_ids", PackedInt64Array())
	var directions: PackedInt32Array = page.get("directions", PackedInt32Array())
	var sources: PackedInt32Array = page.get("source_cells", PackedInt32Array())
	var destinations: PackedInt32Array = page.get(
		"destination_cells", PackedInt32Array())
	var departure_days: PackedInt64Array = page.get(
		"departure_days", PackedInt64Array())
	var arrival_days: PackedInt64Array = page.get(
		"arrival_days", PackedInt64Array())
	var cash_escrows: PackedInt64Array = page.get(
		"cash_escrow", PackedInt64Array())
	var capacity_works: PackedInt64Array = page.get(
		"capacity_work", PackedInt64Array())
	var cargo_delivered: PackedByteArray = page.get(
		"cargo_delivered", PackedByteArray())
	var order_flags: PackedByteArray = page.get("order_flags", PackedByteArray())
	var line_offsets: PackedInt32Array = page.get("line_offsets", PackedInt32Array())
	var line_quantities: PackedInt64Array = page.get(
		"line_quantities", PackedInt64Array())
	var line_unit_prices: PackedInt32Array = page.get(
		"line_unit_prices", PackedInt32Array())
	var line_destination_prices: PackedInt32Array = page.get(
		"line_destination_prices", PackedInt32Array())
	var line_base_values: PackedInt64Array = page.get(
		"line_base_values", PackedInt64Array())
	var rows: Array = []
	var rows_by_id: Dictionary = {}
	var page_units = 0
	var waiting_receivers = 0
	var first_arrival = -1
	for i in range(order_ids.size()):
		var order_id = int(order_ids[i])
		var direction = int(directions[i]) if i < directions.size() else 0
		var source_cell = int(sources[i]) if i < sources.size() else -1
		var destination_cell = int(destinations[i]) if i < destinations.size() else -1
		var counterpart = source_cell if direction > 0 else destination_cell
		var departure = int(departure_days[i]) if i < departure_days.size() else day
		var arrival = int(arrival_days[i]) if i < arrival_days.size() else day
		var line_begin = int(line_offsets[i]) if i < line_offsets.size() else 0
		var line_end = int(line_offsets[i + 1]) if i + 1 < line_offsets.size() \
			else line_begin
		var quantity = 0
		var base_value = 0
		var source_price = 0
		var destination_price = 0
		for line in range(line_begin, line_end):
			quantity += int(line_quantities[line]) if line < line_quantities.size() else 0
			base_value += int(line_base_values[line]) if line < line_base_values.size() else 0
			if line < line_unit_prices.size() and source_price <= 0:
				source_price = int(line_unit_prices[line])
			if line < line_destination_prices.size() and destination_price <= 0:
				destination_price = int(line_destination_prices[line])
		var delivered = int(cargo_delivered[i]) if i < cargo_delivered.size() else 0
		var flags = int(order_flags[i]) if i < order_flags.size() else 0
		var counterpart_visible: bool = counterpart >= 0 and VisionSolver.displayed_fog_state(
			host._map, counterpart) == VisionSolver.FOG_VISIBLE
		var counterpart_name = "视野外"
		var counterpart_sub = ""
		if counterpart_visible:
			counterpart_name = host._PopulationMarket_delegate._trade_counterpart_name(host, counterpart)
			var coord = host._PopulationMarket_delegate._trade_counterpart_coord(host, counterpart)
			if counterpart_name.is_empty():
				counterpart_name = coord
			elif not coord.is_empty():
				counterpart_sub = coord
			if (flags & 1) != 0:
				counterpart_sub = "跨国" if counterpart_sub.is_empty() \
					else "跨国 · %s" % counterpart_sub
		var remaining = maxi(0, arrival - day)
		var span = maxi(1, arrival - departure)
		var progress = clampf(float(day - departure) / float(span), 0.0, 1.0)
		var route_text = "今日到达" if remaining <= 0 else "剩 %d 日" % remaining
		var status_text = "待收款" if delivered != 0 else "在途"
		if delivered != 0:
			waiting_receivers += 1
		var price_text = "—"
		if counterpart_visible and source_price > 0 and destination_price > 0:
			price_text = "%s → %s" % [
				host._money_text(source_price), host._money_text(destination_price)]
		page_units += quantity
		if first_arrival < 0 or arrival < first_arrival:
			first_arrival = arrival
		var escrow = int(cash_escrows[i]) if i < cash_escrows.size() else 0
		var capacity = int(capacity_works[i]) if i < capacity_works.size() else 0
		var row_id = "trade_order_%d" % order_id
		var row = {
			"id": row_id,
			"tooltip": h._PopulationMarket_delegate._trade_order_tooltip(h, order_id, direction, counterpart_name,
				counterpart_visible, quantity, source_price, destination_price,
				base_value, escrow, capacity, departure, arrival, remaining,
				delivered, flags),
			"muted": delivered != 0,
			"locate_cell": counterpart if counterpart_visible else -1,
			"cells": {
				"dir": {"text": "运入" if direction > 0 else "运出",
					"color": UITokens.DOSSIER_VERDIGRIS if direction > 0
						else UITokens.DOSSIER_OXBLOOD},
				"counterpart": {"text": counterpart_name,
					"sub": counterpart_sub},
				"quantity": {"text": h._Construction_delegate._goods_unit_text(h, quantity),
					"value": float(quantity) / 1000.0, "sort": quantity},
				"price": {"text": price_text,
					"sort": destination_price if counterpart_visible else 0},
				"route": {"text": route_text, "value": progress,
					"sort": remaining,
					"bar_color": UITokens.DOSSIER_BRASS if remaining > 0
						else UITokens.DOSSIER_VERDIGRIS},
				"status": {"text": status_text,
					"color": UITokens.DOSSIER_INK_MUTED if delivered != 0
						else UITokens.DOSSIER_BRASS},
			},
		}
		rows.append(row)
		rows_by_id[row_id] = row
	var total = int(page.get("total", rows.size()))
	var page_begin = int(page.get("page_begin", 0))
	var page_label = ""
	if total > rows.size() or page_begin > 0:
		page_label = "%d-%d / %d" % [
			page_begin + 1, page_begin + rows.size(), total]
	var page_text = "%d 笔 · %s 单位" % [rows.size(),
		UITokens.format_compact_number_cn(float(page_units) / 1000.0, 2)]
	if waiting_receivers > 0:
		page_text += " · 待收款 %d 笔" % waiting_receivers
	if first_arrival >= 0 and not rows.is_empty():
		page_text += " · 最近到达 %s" % WorldClock.date_text_for_day(first_arrival)
	var ids = PackedStringArray()
	for value in order_ids:
		ids.append(str(int(value)))
	return {
		"ok": true,
		"pending": false,
		"reason": "",
		"rows": rows,
		"rows_by_id": rows_by_id,
		"total": total,
		"offset": page_begin,
		"limit": int(page.get("limit", rows.size())),
		"has_more": bool(page.get("has_more", false)),
		"page_label": page_label,
		"hint": page_text,
		"empty_text": "",
		"signature": "%d|%d|%d|%d|%d|%s" % [generation, day, page_begin,
			total, int(h._map.vision_revision), ",".join(ids)],
		"sample_day": day,
		"economy_generation": generation,
	}



static func _trade_counterpart_name(host, cell_idx: int) -> String:
	var h = host
	if host._trade_order_names.has(cell_idx):
		return String(host._trade_order_names[cell_idx])
	var summary = host._Overview_delegate._population_summary(host, cell_idx)
	if not bool(summary.get("ok", false)):
		return ""
	var name = String(summary.get("settlement_name", "")).strip_edges()
	if host._trade_order_names.size() > host.TRADE_ORDER_NAME_CACHE_LIMIT:
		host._trade_order_names.clear()
	host._trade_order_names[cell_idx] = name
	return name



static func _trade_counterpart_coord(host, cell_idx: int) -> String:
	var h = host
	var cell: HexCell = host._map.cell_at(cell_idx) if host._map != null else null
	if cell == null:
		return "地块 %d" % (cell_idx + 1)
	var off = HexUtils.cube_to_offset(cell.q, cell.r)
	return "区域 %d, %d" % [off.x + 1, off.y + 1]



static func _trade_order_tooltip(host, order_id: int, direction: int, counterpart_name: String,
		counterpart_visible: bool, quantity: int, source_price: int,
		destination_price: int, base_value: int, escrow: int, capacity: int,
		departure: int, arrival: int, remaining: int, delivered: int,
		flags: int) -> String:
	var lines = PackedStringArray()
	lines.append("订单 #%d · %s" % [order_id,
		"运入" if direction > 0 else "运出"])
	if counterpart_visible:
		lines.append("对端：%s" % counterpart_name)
	else:
		lines.append("对端：视野外（仅显示本地订单事实）")
	lines.append("货物：%s · 货值 %s" % [
		host._Construction_delegate._goods_unit_text(host, quantity), host._money_text(base_value)])
	if counterpart_visible and source_price > 0 and destination_price > 0:
		lines.append("单价：%s → %s" % [
			host._money_text(source_price), host._money_text(destination_price)])
	lines.append("出发 %s → 到达 %s（%s）" % [
		WorldClock.date_text_for_day(departure), WorldClock.date_text_for_day(arrival),
		"今日到达" if remaining <= 0 else "剩余 %d 日" % remaining])
	lines.append("托管现金 %s · 运力 %s" % [
		host._money_text(escrow),
		UITokens.format_compact_number_cn(float(capacity), 1)])
	if delivered != 0:
		lines.append("货物已交付，卖方现金待收款。")
	var notes = PackedStringArray()
	if (flags & 1) != 0:
		notes.append("跨国贸易")
	if (flags & 2) != 0:
		notes.append("救济运输")
	if (flags & 4) != 0:
		notes.append("进口补贴")
	if (flags & 8) != 0:
		notes.append("出口补贴")
	if (flags & 16) != 0:
		notes.append("进口税")
	if (flags & 32) != 0:
		notes.append("出口税")
	if not notes.is_empty():
		lines.append(" · ".join(notes))
	return "\n".join(lines)
