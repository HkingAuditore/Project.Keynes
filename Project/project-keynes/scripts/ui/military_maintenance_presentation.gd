extends RefCounted

const MAINTENANCE_REASON_TEXT: Array[String] = ["—", "缺货", "预算不足", "运输未到"]

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


static func building_upkeep(host, row: Dictionary) -> int:
	return int(round(maxf(0.0, float(row.get("upkeep", 0.0))) * host.MONEY_SCALE))


static func _state_building_current_upkeep(host, role: String, tiers: Array, current: Dictionary,
		snapshot: Dictionary, count: int) -> int:
	var counts = snapshot.get("barracks_tiers")
	if role != "barracks" or not counts is PackedInt32Array:
		return building_upkeep(host, current.get("row", {})) * count
	var daily := 0
	for entry: Dictionary in tiers:
		var tier := int(entry.row.get("tier", -1))
		if tier >= 0 and tier < counts.size():
			daily += building_upkeep(host, entry.row) * int(counts[tier])
	return daily


static func building_hover_preview(host, role: String, row: Dictionary, disrepair: bool,
		current_daily: int, future_daily: int, maintenance: Dictionary = {}) -> Dictionary:
	var outputs: Array = []
	if not row.is_empty():
		match role:
			"barracks":
				outputs.append({"name": "驻军名额", "icon": &"military.banner",
					"text": "+%s 人" % host._count_text(int(row.get("capacity", 0)))})
			"fortification":
				var bonus := float(row.get("fort_bonus", 0.0)) * (0.5 if disrepair else 1.0)
				outputs.append({"name": "守备加成", "icon": &"military.building.fortification",
					"text": "+%d%%" % int(round(bonus * 100.0))})
			"war_college":
				outputs.append({"name": "训练速度", "icon": &"military.plan.training",
					"text": "×%s" % host._one_decimal(float(row.get("training_speed", 1.0)))})

	var upkeep: Array = []
	if current_daily > 0:
		upkeep.append({"name": "当前日维护费", "icon": &"metric.treasury",
			"text": "%s 金币/日" % host._money_text(current_daily)})
	if future_daily >= 0 and future_daily != current_daily:
		upkeep.append({"name": "建成后日维护费", "icon": &"metric.treasury",
			"text": "%s 金币/日" % host._money_text(future_daily)})
	if not maintenance.is_empty():
		var supply := {"name": "物资维护满足率", "icon": &"metric.goods",
			"text": "%.0f%%" % (clampi(int(maintenance.get("ratio_bp", 0)), 0, 10000) / 100.0)}
		var issue := int(maintenance.get("shortage_reason", 0))
		var supply_status := PackedStringArray()
		if bool(int(maintenance.get("disrepair", 0))):
			supply_status.append("失修")
		if issue > 0 and issue < MAINTENANCE_REASON_TEXT.size():
			supply_status.append(MAINTENANCE_REASON_TEXT[issue])
		if not supply_status.is_empty():
			supply["detail"] = " · ".join(supply_status)
			supply["detail_accent"] = UITokens.DOSSIER_OXBLOOD
		upkeep.append(supply)
		var cover := int(maintenance.get("days_cover_x10", -1))
		if cover >= 0:
			upkeep.append({"name": "储备可用", "icon": &"system.calendar",
				"text": cover_days_text(cover)})
	return {"outputs_title": "建成收益" if future_daily >= 0 else "建筑效果",
		"outputs": outputs, "upkeep": upkeep}


static func _state_building_maintenance_text(row: Dictionary) -> String:
	if row.is_empty():
		return ""
	var parts = PackedStringArray()
	parts.append("满足 %d%%" % (clampi(int(row.get("ratio_bp", 0)), 0, 10000) / 100))
	var days = int(row.get("days_cover_x10", -1))
	if days >= 0:
		parts.append("可用 %s" % cover_days_text(days))
	if int(row.get("disrepair", 0)) != 0:
		parts.append("失修")
	var reason = int(row.get("shortage_reason", 0))
	if reason > 0 and reason < MAINTENANCE_REASON_TEXT.size():
		parts.append(MAINTENANCE_REASON_TEXT[reason])
	return " · ".join(parts)


static func _state_building_effect(host, role_id: String, row: Dictionary,
		disrepair: bool) -> String:
	var h = host
	match role_id:
		"barracks":
			return "兵额 +%s" % h._count_text(int(row.get("capacity", 0)))
		"fortification":
			var bonus = float(row.get("fort_bonus", 0.0))
			if disrepair:
				bonus *= 0.5
			return "守备 +%d%%" % int(round(bonus * 100.0))
		_:
			var speed = float(row.get("training_speed", 1.0))
			return "训练 ×%s" % h._one_decimal(speed)


static func _state_building_lock_tooltip(host, role_rows: Array, researched: PackedStringArray,
		gate_known: bool) -> String:
	var h = host
	for entry in role_rows:
		var tech = String(entry.row.get("unlock_tech_id", ""))
		if tech.is_empty() or (gate_known and researched.has(tech)):
			continue
		var tech_name = host._technology_display_name(tech)
		return "需 %s" % tech_name if not tech_name.is_empty() else ""
	return ""
