extends RefCounted

## Display helpers borrow the host per call; state and signal receivers stay there.


static func army_dossier(host, handle: int, same_cell: Array = []) -> Dictionary:
	if handle == 0:
		return {"ok": false, "reason": "military_army_unknown"}
	var detail: Dictionary = {}
	if host._facade != null and host._facade.has_method("army"):
		var fetched = host._facade.call("army", handle)
		if fetched is Dictionary and bool((fetched as Dictionary).get("ok", false)):
			detail = fetched
	if detail.is_empty():
		return {"ok": false, "reason": "military_army_unknown"}
	var info = host.army_detail(detail, detail)
	var owner_slot = int(detail.get("owner_slot", -1))
	var player_slot = int(host._snapshot.get("country_slot", -1))
	var heads = maxi(0, int(detail.get("headcount", 0)))
	var morale = host._ratio(detail.get("morale_q16", host.Q16))
	var pay = host._ratio(detail.get("pay_ratio_q16", host.Q16))
	var supply = host._ratio(detail.get("supply_ratio_q16", host.Q16))
	var ration = host._ratio(detail.get("ration_ratio_q16", host.Q16))
	var attack = host._raw_q16(detail.get("attack_q16", 0))
	var defense = host._raw_q16(detail.get("defense_q16", 0))
	var speed = host._raw_q16(detail.get("speed_q16", host.Q16))
	# 编成条按「兵种 + 品阶」分段（最多 6 段，其余归入"其他"）：
	# 一条比例带 + 一份图例就够读出编成，不再另开一张重复的名录表。
	var lots: Array = []
	for raw in host._as_array(detail.get("composition", null)):
		var lot = host._as_dict(raw)
		var unit = int(lot.get("unit", -1))
		var quality = clampi(int(round(float(lot.get("quality_q8", 256)) / host.Q8)), 1, 5)
		var count = maxi(0, int(lot.get("count", 0)))
		if count <= 0:
			continue
		lots.append({
			"label": "%s %s" % [host.unit_name(unit), String(host.QUALITY_NAMES[quality])],
			"count": count,
			"color": host.class_color(unit),
		})
	lots.sort_custom(func(a, b) -> bool: return int(a.count) > int(b.count))
	var segments: Array = []
	var divisor = maxf(1.0, float(heads))
	var rest = 0
	for i in lots.size():
		var lot: Dictionary = lots[i]
		if i >= 5:
			rest += int(lot.count)
			continue
		segments.append({
			"label": String(lot.label),
			"text": host._count(lot.count),
			"value": float(lot.count) / divisor,
			"color": lot.color,
		})
	if rest > 0:
		segments.append({
			"label": "其他",
			"text": host._count(rest),
			"value": float(rest) / divisor,
			"color": UITokens.DOSSIER_UMBER,
		})
	var badges: Array = []
	for warning in info.get("warnings", []):
		var entry = host._as_dict(warning)
		badges.append({
			"text": String(entry.get("label", "")),
			"accent": UITokens.DOSSIER_OXBLOOD if String(entry.get("tone", "")) == "risk" \
				else UITokens.DOSSIER_BRASS,
		})
	var same_rows: Array = []
	for raw in same_cell:
		var other = host._as_dict(raw)
		var other_handle = int(other.get("handle", 0))
		if other_handle == 0 or other_handle == handle:
			continue
		same_rows.append({
			"id": other_handle,
			"cells": {
				"name": {"text": host.army_name(other), "icon": "military.banner",
					"sub": host.cell_name(int(other.get("cell", -1)))},
				"heads": {"text": host._count(other.get("headcount", 0)),
					"sort": float(other.get("headcount", 0))},
				"owner": {"text": host.country_name(int(other.get("owner_slot", -1)))},
			},
		})
	var own = owner_slot >= 0 and owner_slot == player_slot
	var exploration = host._exploration_state(detail)
	var explore_live = host._exploration_has_live_order(detail)
	var engaged = int(detail.get("engagement", -1)) >= 0
	var explore_reason = ""
	if engaged:
		explore_reason = "交战中无法开始探路。"
	var actions = [
		{"id": "locate", "label": "定位", "enabled": true},
		{"id": "move", "label": "移动", "enabled": own},
		{"id": "area", "label": "军事控制", "enabled": own},
		{"id": "explore", "label": "探路", "enabled": own and not engaged,
			"reason": explore_reason},
		{"id": "stop", "label": "停止任务",
			"enabled": own and (int(detail.get("mission", 0)) != 0 or explore_live)},
	]
	var remaining = 0
	var path = detail.get("path", null)
	if path is PackedInt32Array or path is Array:
		remaining = path.size()
	var note = ""
	if remaining > 0 and int(detail.get("mission", 0)) != 3:
		note = "%s · 剩 %d 格" % [
			String(host.MISSION_LABELS.get(int(detail.get("mission", 0)), "行军")), remaining]
	var dominant_unit = -1
	if not host._as_array(detail.get("composition", null)).is_empty():
		dominant_unit = int(host._as_dict(host._as_array(detail.get("composition", null))[0]).get("unit", -1))
	return {
		"ok": true, "kind": "army", "identity": "army:%d" % handle,
		"kicker": "部队档案", "title": String(info.get("name", "部队")),
		"subtitle": "%s · %s · %s" % [
			host.cell_name(int(detail.get("cell", -1))), host.country_name(owner_slot),
			String(host.STANCE_LABELS.get(int(detail.get("stance", 0)), "固守"))],
		"icon": host.unit_icon(dominant_unit) if dominant_unit >= 0 else &"military.banner",
		"accent": CountryBorderLayer.country_color(owner_slot, player_slot,
			UITokens.DOSSIER_OXBLOOD),
		"kpis": [
			{"id": "heads", "title": "兵力", "value": float(heads), "kind": "count",
				"icon": &"military.unit.line", "caption": "%d 类兵种" % segments.size()},
			{"id": "morale", "title": "士气", "value": morale, "kind": "percent",
				"icon": &"military.army.morale", "caption": "",
				"tone": "risk" if morale < 0.4 else ("warn" if morale < 0.6 else "")},
			{"id": "supply", "title": "补给", "value": supply, "kind": "percent",
				"icon": &"military.army.supply", "caption": "口粮 %s" % host._percent(ration),
				"tone": "risk" if supply < 0.5 else ("warn" if supply < 0.8 else "")},
			{"id": "pay", "title": "军饷", "value": pay, "kind": "percent",
				"icon": &"military.army.pay", "caption": "",
				"tone": "risk" if pay < 0.6 else ("warn" if pay < 0.85 else "")},
		],
		"focus_cell": int(detail.get("cell", -1)),
		"selected": handle,
		"army": {
			"own": own,
			"stance": int(detail.get("stance", 0)),
			"mission_text": host._mission_text(detail),
			# 攻 / 防 / 速 是平级战力数据：同一行、同一字号、同一墨色。
			"peer_stats": [
				{"label": "攻击", "text": "%.1f" % attack, "color": UITokens.DOSSIER_INK},
				{"label": "防御", "text": "%.1f" % defense, "color": UITokens.DOSSIER_INK},
				{"label": "速度", "text": "%.1f" % speed, "color": UITokens.DOSSIER_INK},
			],
			"composition": {"title": "", "total": "%s 人" % host._count(heads),
				"segments": segments},
			"supply_rows": info.get("supply", []),
			"badges": badges,
			"note": note,
			"actions": actions,
			"exploration": exploration.duplicate(),
			"same_cell_rows": same_rows,
		},
	}


static func front_dossier(host, sector: Dictionary) -> Dictionary:
	if not bool(sector.get("ok", false)):
		return {}
	var player_slot = int(sector.get("player_slot", -1))
	var edge_key = int(sector.get("edge_key", -1))
	var side_rows: Array = host._as_array(sector.get("sides", null))
	var owners = sector.get("owners", PackedInt32Array())
	# 两个交战方：扇区内地块的归属。一侧此刻没有部队时也要能写出国名。
	var belligerents: Array = []
	if owners is PackedInt32Array:
		for slot in owners:
			if int(slot) >= 0 and not belligerents.has(int(slot)):
				belligerents.append(int(slot))
	belligerents.sort()
	var own_slot = -1
	var enemy_slot = -1
	if belligerents.has(player_slot):
		own_slot = player_slot
		for slot in belligerents:
			if int(slot) != player_slot:
				enemy_slot = int(slot)
				break
	elif not belligerents.is_empty():
		own_slot = int(belligerents[0])
		if belligerents.size() > 1:
			enemy_slot = int(belligerents[1])
	host._dossier_army_cache.clear()
	var own = host._side_totals(side_rows, own_slot)
	var enemy = host._side_totals(side_rows, enemy_slot)
	var advance = float(sector.get("advance", -1.0))
	var active_count = int(sector.get("active_count", 0))
	var edge_count = int(sector.get("edge_count", 0))
	var focused = int(sector.get("focus_cell", -1))
	var versus_rows = [
		host._versus_row("兵力", float(own.heads), float(enemy.heads),
			host._count(own.heads), host._count(enemy.heads)),
		host._versus_row("攻击", float(own.attack), float(enemy.attack),
			"%.1f" % float(own.attack), "%.1f" % float(enemy.attack)),
		host._versus_row("防御", float(own.defense), float(enemy.defense),
			"%.1f" % float(own.defense), "%.1f" % float(enemy.defense)),
		host._versus_row("士气", float(own.morale), float(enemy.morale),
			host._percent(own.morale), host._percent(enemy.morale)),
		host._versus_row("补给", float(own.supply), float(enemy.supply),
			host._percent(own.supply), host._percent(enemy.supply)),
	]
	var footnote_parts = PackedStringArray()
	if advance >= 0.0:
		footnote_parts.append("推进 %s" % host._percent(advance))
	footnote_parts.append("交战 %d 段" % active_count)
	footnote_parts.append("接触 %d 边" % edge_count)
	var army_rows: Array = []
	host._append_side_army_rows(army_rows, side_rows, own_slot)
	host._append_side_army_rows(army_rows, side_rows, enemy_slot)
	army_rows.sort_custom(func(a, b) -> bool:
		return float(a.cells.heads.sort) > float(b.cells.heads.sort))
	var engagements: Array = host._as_array(sector.get("engagements", null))
	var rows: Array = []
	for raw in engagements:
		var engagement = host._as_dict(raw)
		var progress = clampf(float(engagement.get("progress", 0.0)), 0.0, 1.0)
		var attacker = int(engagement.get("attacker", -1))
		rows.append({
			"id": int(host._pair_key_for(
				int(engagement.get("cell_a", -1)), int(engagement.get("cell_b", -1)))),
			"tooltip": "%s ↔ %s" % [
				host.cell_name(int(engagement.get("cell_a", -1))),
				host.cell_name(int(engagement.get("cell_b", -1)))],
			"cells": {
				"zone": {"text": host.zone_name(int(engagement.get("cell_a", -1)))},
				"progress": {"text": host._percent(progress), "value": progress,
					"bar_color": UITokens.DOSSIER_VERDIGRIS \
						if attacker == player_slot else UITokens.DOSSIER_OXBLOOD},
				"attacker": {"text": host.country_name(attacker)},
			},
		})
	rows.sort_custom(func(a, b) -> bool:
		return float(a.cells.progress.value) > float(b.cells.progress.value))
	var left_name = "—" if own_slot < 0 else host.country_name(own_slot)
	var right_name = "—" if enemy_slot < 0 else host.country_name(enemy_slot)
	return {
		"ok": true, "kind": "front", "identity": "front:%d" % edge_key,
		"kicker": "战线档案",
		"title": host.zone_name(focused) if focused >= 0 else "战线",
		"subtitle": "%s ↔ %s" % [left_name, right_name],
		"icon": &"military.war.front",
		"accent": CountryBorderLayer.country_color(
			own_slot if own_slot >= 0 else player_slot, player_slot,
			UITokens.DOSSIER_BRASS),
		"focus_cell": focused,
		"selected": edge_key,
		"front": {
			"versus": {
				"rows": versus_rows,
				"own_color": CountryBorderLayer.country_color(own_slot, player_slot,
					UITokens.DOSSIER_VERDIGRIS),
				"enemy_color": CountryBorderLayer.country_color(enemy_slot, player_slot,
					UITokens.DOSSIER_OXBLOOD),
				"own_label": "我方" if own_slot == player_slot else left_name,
				"enemy_label": "敌方" if enemy_slot != player_slot else right_name,
			},
			"footnote": " · ".join(footnote_parts),
			"army_rows": army_rows.slice(0, 8),
			"army_visible": not army_rows.is_empty(),
			"engagement_rows": rows.slice(0, 8),
			"engagement_visible": not rows.is_empty(),
		},
	}


static func _side_totals(host, sides: Array, slot: int) -> Dictionary:
	var out = {"heads": 0, "attack": 0.0, "defense": 0.0, "morale": 0.0, "supply": 0.0}
	if slot < 0:
		return out
	var weight = 0.0
	for raw in sides:
		var side = host._as_dict(raw)
		if int(side.get("slot", -1)) != slot:
			continue
		out["heads"] = int(out["heads"]) + int(side.get("heads", 0))
		var handles = side.get("handles", null)
		if not (handles is Array or handles is PackedInt64Array):
			continue
		var limit = mini(handles.size(), host.DOSSIER_SIDE_ARMY_CAP)
		for i in limit:
			var detail = host._dossier_army(int(handles[i]))
			if detail.is_empty():
				continue
			out["attack"] = float(out["attack"]) + host._raw_q16(detail.get("attack_q16", 0))
			out["defense"] = float(out["defense"]) + host._raw_q16(detail.get("defense_q16", 0))
			var heads = float(maxi(1, int(detail.get("headcount", 0))))
			out["morale"] = float(out["morale"]) \
				+ host._ratio(detail.get("morale_q16", host.Q16)) * heads
			out["supply"] = float(out["supply"]) \
				+ host._ratio(detail.get("supply_ratio_q16", host.Q16)) * heads
			weight += heads
	if weight > 0.0:
		out["morale"] = float(out["morale"]) / weight
		out["supply"] = float(out["supply"]) / weight
	return out


static func _dossier_army(host, handle: int) -> Dictionary:
	if host._dossier_army_cache.has(handle):
		return host._dossier_army_cache[handle]
	var detail: Dictionary = {}
	if host._facade != null and host._facade.has_method("army"):
		var fetched = host._facade.call("army", handle)
		if fetched is Dictionary and bool((fetched as Dictionary).get("ok", false)):
			detail = fetched
	if host._dossier_army_cache.size() < 64:
		host._dossier_army_cache[handle] = detail
	return detail


static func _append_side_army_rows(host, out: Array, sides: Array, slot: int) -> void:
	if slot < 0:
		return
	for raw in sides:
		var side = host._as_dict(raw)
		if int(side.get("slot", -1)) != slot:
			continue
		var handles = side.get("handles", null)
		if not (handles is Array or handles is PackedInt64Array):
			continue
		for i in mini(handles.size(), host.DOSSIER_SIDE_ARMY_CAP):
			var detail = host._dossier_army(int(handles[i]))
			if detail.is_empty():
				continue
			out.append({
				"id": int(handles[i]),
				"cells": {
					"name": {"text": host.army_name(detail)},
					"heads": {"text": host._count(detail.get("headcount", 0)),
						"sort": float(detail.get("headcount", 0))},
					"attack": {"text": "%.1f" % host._raw_q16(detail.get("attack_q16", 0))},
					"owner": {"text": host.country_name(slot)},
				},
			})
