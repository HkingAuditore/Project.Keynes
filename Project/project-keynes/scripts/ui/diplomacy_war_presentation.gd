extends RefCounted

## 整理外交页战事列表与详情的展示数据。
const MAX_LOG_ROWS := 5
const MAX_FRONT_ROWS := 6


static func build_rows(entries: Array) -> Array:
	var rows: Array = []
	for entry in entries:
		var card := _as_dict(entry.card)
		var fully := bool(card.get("fully_occupied", false))
		rows.append({
			"id": int(card.get("id", 0)),
			"enemy_slot": int(entry.enemy_slot),
			"enemy_handle": int(entry.enemy_handle),
			"enemy_name": String(card.get("enemy_name", "敌国")),
			"role": String(card.get("role", "")),
			"days": int(card.get("days", 0)),
			"score": float(card.get("score", 0.0)),
			"score_text": String(card.get("score_text", "0")),
			"losses_text": String(card.get("losses_text", "")),
			"fully_occupied": fully,
			"status": "全境沦陷" if fully
				else ("交战中" if bool(card.get("battle", false)) else "对峙"),
		})
	return rows


static func build_sheet(entry: Dictionary, front_rows: Array, war_log: Array) -> Dictionary:
	var card := _as_dict(entry.card)
	var score := float(card.get("score", 0.0))
	var parts := _as_array(card.get("score_parts", []))
	var score_rows: Array = []
	if parts.is_empty():
		score_rows.append({"id": "score", "label": "战争分",
			"text": String(card.get("score_text", "0")),
			"value": clampf(score / 100.0, -1.0, 1.0),
			"color": UITokens.DOSSIER_VERDIGRIS if score >= 0.0 else UITokens.DOSSIER_OXBLOOD})
	else:
		score_rows = parts
	var fronts: Array = []
	var focus_cell := -1
	for row_value in front_rows.slice(0, MAX_FRONT_ROWS):
		var row := _as_dict(row_value)
		var cell := int(row.get("cell", -1))
		if focus_cell < 0:
			focus_cell = cell
		fronts.append({
			"id": String(row.get("id", "")),
			"label": String(row.get("zone", "")),
			"text": String(row.get("text", "")),
			"value": float(row.get("progress", 0.0)),
			"cell": cell,
			"color": UITokens.DOSSIER_OXBLOOD if float(row.get("progress", 0.0)) > 0.001
				else UITokens.DOSSIER_SLATE,
		})
	var engagement := _as_dict(card.get("engagement"))
	if focus_cell < 0 and not engagement.is_empty():
		focus_cell = int(engagement.get("cell_a", -1))
	var log: Array = []
	for row_value in war_log.slice(0, MAX_LOG_ROWS):
		var row := _as_dict(row_value)
		log.append({"day": int(row.get("day", 0)), "kind": String(row.get("kind", "战事")),
			"text": String(row.get("text", ""))})
	return {
		"ok": true,
		"id": int(card.get("id", 0)),
		"enemy_slot": int(entry.enemy_slot),
		"enemy_handle": int(entry.enemy_handle),
		"enemy_name": String(card.get("enemy_name", "敌国")),
		"role": String(card.get("role", "")),
		"days": int(card.get("days", 0)),
		"score": score,
		"score_text": String(card.get("score_text", "0")),
		"score_rows": score_rows,
		"score_estimated": parts.is_empty(),
		"losses_text": String(card.get("losses_text", "")),
		"fully_occupied": bool(card.get("fully_occupied", false)),
		"battle": bool(card.get("battle", false)),
		"engagement_text": String(engagement.get("label", "")) if not engagement.is_empty() else "",
		"focus_cell": focus_cell,
		"fronts": fronts,
		"log": log,
	}


static func _as_dict(value) -> Dictionary:
	return value if value is Dictionary else {}

static func _as_array(value) -> Array:
	return value if value is Array else []
