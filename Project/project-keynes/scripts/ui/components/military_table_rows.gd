extends RefCounted

## Shapes barracks, training, army and convoy ledger rows. The workspace retains selection, signals and command controls.

static func _apply_barracks(_barracks_table, rows: Array) -> void:
	var table_rows: Array = []
	for row in rows:
		var paused := bool(row.paused)
		var tone := UITokens.DOSSIER_INK_MUTED if paused or bool(row.disrepair) \
			else UITokens.DOSSIER_VERDIGRIS
		table_rows.append({
			"id": int(row.cell),
			"muted": paused or bool(row.disrepair),
			"tooltip": "%s · %s\n在驻 %d / 兵额 %d · 空额 %d · 征召中 %d\n点击在地图上定位" % [
				String(row.name), String(row.status), int(row.present), int(row.posts),
				int(row.open), int(row.pending)],
			"cells": {
				"name": {"text": String(row.name),
					"icon": String(row.get("icon", "military.building.barracks")),
					"sub": "" if String(row.status) == "招募中" else String(row.status)},
				"posts": {"text": _compact_count(row.posts)},
				"fill": {"text": _compact_count(row.present), "value": float(row.fill),
					"bar_color": tone, "sort": float(row.fill)},
				"quota": {"text": _count(row.quota)},
				"actions": {},
			},
			"actions": [] if bool(row.disrepair) else [{
				"id": "resume" if paused else "pause",
				"icon": "action.play" if paused else "action.pause",
				"tooltip": "恢复招募" if paused else "暂停招募"}],
		})
	_barracks_table.set_rows(table_rows)


static func _apply_training(_training_table, rows: Array) -> void:
	var table_rows: Array = []
	for row in rows:
		var ready := bool(row.ready)
		table_rows.append({
			"id": int(row.id),
			"muted": not ready,
			"tooltip": "%s：%s → %s（%s）\n%s · %s" % [String(row.cell_text), String(row.from_label),
				String(row.to_label), String(row.quality_text), String(row.progress_text),
				"装备已到位" if ready else "等待装备到货"],
			"cells": {
				"unit": {"text": String(row.to_label), "icon": String(row.icon),
					"sub": String(row.cell_text)},
				"count": {"text": _count(row.count)},
				"progress": {"text": String(row.progress_text) if ready else "等装备",
					"value": float(row.progress),
					"bar_color": UITokens.DOSSIER_VERDIGRIS if ready else UITokens.DOSSIER_BRASS},
			},
		})
	_training_table.set_rows(table_rows)


static func _apply_army_rows(_army_table, rows: Array) -> void:
	var table_rows: Array = []
	for row in rows:
		table_rows.append({
			"id": int(row.handle),
			"tooltip": "%s · %s\n%s%s\n点击打开军务档案" % [String(row.name),
				String(row.cell_text), String(row.mission),
				("\n" + String(row.warning)) if not String(row.warning).is_empty() else ""],
			"cells": {
				"name": {"text": String(row.name), "icon": "military.banner",
					"sub": String(row.warning) if not String(row.warning).is_empty() else String(row.cell_text),
					"color": UITokens.DOSSIER_OXBLOOD if bool(row.critical) else UITokens.DOSSIER_INK},
				"heads": {"text": _count(row.headcount), "sort": float(row.headcount)},
				"power": {"text": "%.1f / %.1f" % [float(row.attack), float(row.defense)]},
				"morale": {"text": _percent(row.morale), "value": float(row.morale),
					"bar_color": _tone(float(row.morale))},
				"supply": {"text": _percent(row.supply), "value": float(row.supply),
					"bar_color": _tone(float(row.supply))},
				"actions": {},
			},
			"actions": [
				{"id": "locate", "icon": "action.pin",
					"tooltip": "在地图上定位这支部队"},
				{"id": "dossier", "icon": "summary.overview",
					"tooltip": "打开军务档案（编成 / 补给 / 指令）"},
			],
		})
	_army_table.set_rows(table_rows)


static func _apply_convoys(_convoy_table, convoys: Array) -> void:
	var rows: Array = []
	for row in convoys:
		var risk := float(row.risk)
		rows.append({
			"id": int(row.id),
			"tooltip": "%s\n%s · 被截风险 %s · %d 日后到达" % [String(row.route), String(row.goods),
				_percent(risk), int(row.eta)],
			"cells": {
				"route": {"text": String(row.route), "icon": "military.ledger.convoy"},
				"goods": {"text": String(row.goods)},
				"risk": {"text": _percent(risk), "value": risk,
					"bar_color": UITokens.DOSSIER_OXBLOOD if risk >= 0.25
						else (UITokens.DOSSIER_BRASS if risk >= 0.08 else UITokens.DOSSIER_VERDIGRIS)},
				"eta": {"text": "%d 日" % int(row.eta), "sort": float(row.eta)},
			},
		})
	_convoy_table.set_rows(rows)


static func _count(value) -> String:
	return UITokens.format_compact_number_cn(float(value), 1)


static func _compact_count(value) -> String:
	return UITokens.format_compact_number_cn(float(value), 0 if float(value) < 10000.0 else 1)


static func _percent(value) -> String:
	return "%d%%" % int(round(clampf(float(value), 0.0, 1.0) * 100.0))


static func _tone(value: float) -> Color:
	if value < 0.35:
		return UITokens.DOSSIER_OXBLOOD
	return UITokens.DOSSIER_BRASS if value < 0.6 else UITokens.DOSSIER_VERDIGRIS
