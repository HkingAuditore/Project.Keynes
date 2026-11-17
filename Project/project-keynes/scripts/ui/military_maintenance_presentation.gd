extends RefCounted

static func goods_text(milli: int) -> String:
	var value := maxi(0, milli)
	if value <= 0:
		return "—"
	if value >= 10000000:
		return "%d" % (value / 1000)
	return "%d.%d" % [value / 1000, (value % 1000) / 100]


static func cover_days_text(days_cover_x10: int) -> String:
	if days_cover_x10 < 0:
		return "—"
	if days_cover_x10 % 10 == 0:
		return "%d 日" % (days_cover_x10 / 10)
	return "%d.%d 日" % [days_cover_x10 / 10, days_cover_x10 % 10]


static func maintenance_signature(rows: Array, summary: Dictionary) -> int:
	var signature := 17
	for row in rows:
		var entry: Dictionary = row
		signature = signature * 31 + int(entry.get("need", 0))
		signature = signature * 31 + int(entry.get("stock", 0))
		signature = signature * 31 + int(entry.get("inbound", 0))
		signature = signature * 31 + int(entry.get("ratio", 0))
		signature = signature * 31 + int(entry.get("days_cover", -1))
		signature = signature * 31 + (1 if bool(entry.get("disrepair", false)) else 0)
		signature = signature * 31 + int(entry.get("shortage_reason", 0))
	signature = signature * 31 + int(summary.get("weighted_ratio_bp", 0))
	return signature


static func maintenance_detail_rows(rows) -> Array:
	var out: Array = []
	if not rows is Array:
		return out
	for row_value in (rows as Array):
		if not row_value is Dictionary:
			continue
		var row: Dictionary = row_value
		var days_cover := int(row.get("days_cover_x10", -1))
		out.append({
			"id": String(row.get("id", "")),
			"name": String(row.get("name", "")),
			"kind": int(row.get("kind", 0)),
			"kind_name": String(row.get("kind_name", "")),
			"cell": int(row.get("cell", -1)),
			"units": maxi(0, int(row.get("units", 0))),
			"need": maxi(0, int(row.get("daily_need_goods", 0))),
			"stock": maxi(0, int(row.get("stock_goods", 0))),
			"inbound": maxi(0, int(row.get("inbound_goods", 0))),
			"ratio": clampi(int(row.get("ratio_bp", 0)), 0, 10000),
			"days_cover": days_cover,
			"days_text": cover_days_text(days_cover),
			"disrepair": int(row.get("disrepair", 0)) != 0,
			"shortage_reason": int(row.get("shortage_reason", 0)),
			"reason_text": String(row.get("reason_text", "—")),
			"need_text": goods_text(int(row.get("daily_need_goods", 0))),
			"inbound_text": goods_text(int(row.get("inbound_goods", 0))),
		})
	return out
