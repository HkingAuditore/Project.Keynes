extends RefCounted
class_name DiplomacyViewModel

## 外交章的只读视图模型。
##
## 三个章节各自回答一个问题：
##   总览 —— 世界上还有谁、在跟谁打、我还能出多少兵；
##   国家 —— 已发现国家的名录与单国档案（宣战在这里）；
##   战事 —— 我方参战的每一场战争，点开看战争分、战线与近日战事（议和在这里）。
##
## 它不查新的模拟状态：国家壳、军事快照、领土镜像都是 CountryViewModel 已经装好的
## 那几份；战争卡、战线、战事记录与割地候选直接复用 `MilitaryViewModel`，命名
## （国名 / 地名）也走同一处，避免第二个真相。
##
## 迷雾规则（与 `VisionSolver.fog_state` 同一条降级规则）：任一格已探索即视为
## 「已发现」；`fog_solved == false`（视野未解算 / 测试挂载）时按全通处理。
## 已发现但当前无通视的国家标「已探明」，只此一个区别——不另造第二套迷雾模型。

const MilitaryViewModelScript = preload("res://scripts/ui/military_view_model.gd")
const CountryMapQueryScript = preload("res://scripts/ui/country_map_query.gd")

const MONEY_SCALE := 10000.0
const ERA_LABELS: Array[String] = ["石器", "农耕", "王国", "帝国", "探索", "启蒙",
	"蒸汽", "电气", "原子", "信息", "智能"]
const CHAPTERS: Array[Dictionary] = [
	{"id": "overview", "label": "总览", "icon": &"summary.overview"},
	{"id": "countries", "label": "国家", "icon": &"country.world"},
	{"id": "wars", "label": "战事", "icon": &"military.war.front"},
]
const MAX_POWER_ROWS := 6
const MAX_LOG_ROWS := 5
const MAX_FRONT_ROWS := 6
const MAX_INSIGHTS := 3

var _model: Dictionary = {}
var _vm = null
var _generator = null
## 会话地图（`MapData`）：领土镜像 / 视野 / 邻接都从它读，优先级见 `_map()`。
var _map_obj = null
var _country_facade = null
var _military_facade = null
var _player_controller = null
var _country_handle := 0
var _player_slot := -1
var _day := -1
var _available := false
var _reason := ""
var _military_available := false
var _military_reason := ""

## 名单按「日 / 国家代际 / 视野修订 / 本国槽位」缓存：一次刷新只扫一遍地图，
## 之后同一帧里多处取名单都是免费读。
var _session_signature := ""
var _roster_signature := ""
var _roster: Array = []
var _row_by_id: Dictionary = {}
var _row_by_handle: Dictionary = {}
var _owners := PackedInt32Array()
var _handle_by_slot: Dictionary = {}
var _war_entries: Array = []
var _war_entries_signature := ""
var _sheet_cache: Dictionary = {}


func configure(model: Dictionary) -> void:
	_model = model if model != null else {}
	var section := _as_dict(_model.get("diplomacy", null))
	_generator = section.get("generator", _model.get("generator", null))
	_map_obj = section.get("map", _model.get("map", null))
	_country_facade = section.get("country_facade", _model.get("country_facade", null))
	_military_facade = section.get("military_facade", null)
	_country_handle = int(section.get("country_handle", _model.get("country_handle", 0)))
	_day = int(section.get("day", _model.get("current_day", -1)))
	_available = bool(section.get("available", false))
	_reason = String(section.get("reason", ""))
	_military_available = bool(section.get("military_available", false))
	_military_reason = String(section.get("military_reason", ""))
	if _vm == null:
		_vm = MilitaryViewModelScript.new()
	_vm.configure(_model)
	_vm.set_player_controller(_player_controller)
	_player_slot = _resolve_player_slot()
	_session_signature = _signature_now()


func set_player_controller(controller) -> void:
	_player_controller = controller
	if _vm != null:
		_vm.set_player_controller(controller)


func available() -> bool:
	return _available


func reason() -> String:
	return _reason if not _reason.is_empty() else "外交档案暂不可用"


func military_available() -> bool:
	return _military_available and _vm != null and _vm.available()


func military_reason() -> String:
	return _military_reason if not _military_reason.is_empty() else "军事机构尚未接通"


## 内层军事视图模型。战事与割地候选都从它来，面板不另建一份。
func view_military():
	return _vm


func country_handle() -> int:
	return _country_handle


func day() -> int:
	return _day


func build(chapter_id: String, state: Dictionary = {}) -> Dictionary:
	if not _available:
		return {"ok": false, "reason": reason()}
	match chapter_id:
		"overview":
			return overview_model()
		"countries":
			return countries_model(int(state.get("country", 0)))
		"wars":
			return wars_model(int(state.get("war", 0)))
	return {"ok": false, "reason": "未知章节"}


# ── 总览 ─────────────────────────────────────────────────────────────────

func overview_model() -> Dictionary:
	var rows := war_rows()
	var soldiers := _player_soldiers()
	var occupied := _occupied_cells()
	return {
		"ok": true,
		"kpis": [
			{"id": "countries", "title": "已知国家", "kind": "count",
				"value": float(roster().size()), "caption": "已接触",
				"icon": "country.world"},
			{"id": "wars", "title": "交战中", "kind": "count",
				"value": float(rows.size()),
				"caption": ("%d 国" % _war_enemy_count()) if not rows.is_empty() else "无战事",
				"icon": "military.war.front",
				"tone": "risk" if not rows.is_empty() else ""},
			{"id": "soldiers", "title": "我方兵力", "kind": "count",
				"value": float(maxi(soldiers, 0)),
				"caption": "可战" if soldiers > 0 else "无兵可战",
				"icon": "military.army.attack",
				"tone": "risk" if soldiers <= 0 else ""},
			{"id": "occupied", "title": "占领格", "kind": "count",
				"value": float(maxi(occupied, 0)),
				"caption": "我方控制" if occupied > 0 else "未占敌土",
				"icon": "military.plan.target"},
		],
		"wars": rows,
		"powers": _power_rows(),
		"insights": _overview_insights(rows, soldiers),
	}


## 列强榜：按领土排序，`marker` 是本国的同一标尺位置——一眼看出谁大谁小。
func _power_rows() -> Array:
	var countries := roster()
	if countries.is_empty():
		return []
	var sorted := countries.duplicate()
	sorted.sort_custom(func(a, b): return int(a.cells) > int(b.cells))
	var top: Array = sorted.slice(0, MAX_POWER_ROWS)
	var mine := int(_model.get("territory_count", 0))
	var peak := mine
	for row in top:
		peak = maxi(peak, int(row.cells))
	if peak <= 0:
		return []
	var out: Array = []
	for row in top:
		var at_war := String(_as_dict(row.relation).get("state", "")) == "war"
		out.append({
			"id": "power_%d" % int(row.id),
			"label": String(row.name),
			"text": "%d 格" % int(row.cells),
			"value": float(row.cells) / float(peak),
			# 基线只在本国不是最大时才有信息量；本国最大时它就是标尺末端，
			# 画上去会被读成"轨道终点"。
			"marker": (float(mine) / float(peak)) if (mine > 0 and mine < peak) else -1.0,
			"color": UITokens.DOSSIER_OXBLOOD if at_war else UITokens.DOSSIER_BRASS,
			"tooltip": "%s · %d 格%s" % [String(row.name), int(row.cells),
				" · 正在交战" if at_war else ""],
		})
	return out


func _overview_insights(wars: Array, soldiers: int) -> Array:
	var out: Array = []
	if soldiers <= 0 and military_available():
		out.append({"icon": "status.warning", "accent": UITokens.RISK,
			"text": "无兵可战"})
	if wars.size() >= 2:
		out.append({"icon": "military.war.front", "accent": UITokens.RISK,
			"text": "同时在打 %d 国" % wars.size()})
	var strongest := _strongest_neighbour()
	if not strongest.is_empty():
		out.append({"icon": "country.world", "accent": UITokens.ACCENT,
			"text": "最强邻邦 %s，边域 %d 面" % [String(strongest.name),
				int(strongest.border_edges)]})
	return out.slice(0, MAX_INSIGHTS)


func _strongest_neighbour() -> Dictionary:
	var best: Dictionary = {}
	for row in roster():
		if not bool(row.adjacent):
			continue
		if best.is_empty() or int(row.cells) > int(best.cells):
			best = row
	return best


func _war_enemy_count() -> int:
	var seen := {}
	for entry in _entries():
		seen[int(entry.enemy_slot)] = true
	return seen.size()


# ── 国家 ─────────────────────────────────────────────────────────────────

func countries_model(selected: int) -> Dictionary:
	var rows := roster()
	if rows.is_empty():
		return {"ok": true, "rows": [], "selected": 0, "sheet": {},
			"empty": roster_empty_text()}
	var current := selected
	if _row(current).is_empty():
		current = int(rows[0].id)
	return {
		"ok": true,
		"rows": rows,
		"selected": current,
		"sheet": country_sheet(current),
		"empty": "",
	}


## 名录行（供 DossierLedgerTable）。已发现国家、排除本国。
func roster() -> Array:
	if not _available:
		return []
	if _session_signature == _roster_signature:
		return _roster
	_rebuild_roster(_session_signature)
	return _roster


func roster_empty_text() -> String:
	if _generator == null:
		return "外交档案尚未接通"
	if _owners.is_empty():
		return "尚未读到领土归属"
	return "尚未接触任何国家"


func _signature_now() -> String:
	var generation := 0
	if _country_facade != null and _country_facade.has_method("report"):
		var report = _country_facade.call("report")
		if report is Dictionary:
			generation = int((report as Dictionary).get("generation", 0))
	var vision := 0
	var map = _map()
	if map != null:
		vision = int(map.get("vision_revision"))
	return "%d|%d|%d|%d" % [_day, generation, vision, _player_slot]


func _rebuild_roster(signature: String) -> void:
	_roster_signature = signature
	_roster = []
	_row_by_id.clear()
	_row_by_handle.clear()
	_handle_by_slot.clear()
	_sheet_cache.clear()
	_war_entries_signature = ""
	_owners = CountryMapQueryScript.owner_map(_generator, _model, _map())
	if _owners.is_empty():
		return
	var map = _map()
	var fog_solved := map != null and bool(map.get("fog_solved"))
	var visible := PackedByteArray()
	var explored := PackedByteArray()
	if map != null:
		var visible_value = map.get("visible_arr")
		if visible_value is PackedByteArray:
			visible = visible_value
		var explored_value = map.get("explored_arr")
		if explored_value is PackedByteArray:
			explored = explored_value
	# 单遍统计每个槽位的格数 / 通视 / 已探明 / 代表格。O(格数)，且只在签名变化时发生。
	var stats := {}
	for cell in range(_owners.size()):
		var slot := int(_owners[cell])
		if slot < 0:
			continue
		var entry: Dictionary = {}
		if stats.has(slot):
			entry = stats[slot]
		else:
			entry = {"cells": 0, "visible": 0, "explored": 0, "first": cell}
			stats[slot] = entry
		entry.cells = int(entry.cells) + 1
		if cell < visible.size() and int(visible[cell]) != 0:
			entry.visible = int(entry.visible) + 1
		if cell < explored.size() and int(explored[cell]) != 0:
			entry.explored = int(entry.explored) + 1
	var borders := {}
	if _player_slot >= 0:
		borders = CountryMapQueryScript.border_edge_counts(_owners,
			CountryMapQueryScript.neighbors_of(_generator, _map()), _player_slot)
	var slots: Array = stats.keys()
	slots.sort()
	for slot_value in slots:
		var slot := int(slot_value)
		if slot == _player_slot:
			continue
		var entry: Dictionary = stats[slot]
		# 已探索才算「已发现」。视野未解算（fog_solved == false）时全员列入。
		if fog_solved and int(entry.explored) <= 0:
			continue
		_roster.append(_roster_row_for(slot, entry, borders))
	_roster.sort_custom(_compare_rows)
	for row in _roster:
		_row_by_id[int(row.id)] = row
		if int(row.handle) != 0:
			_row_by_handle[int(row.handle)] = row


## 交战中 → 接壤 → 领土大。同分按槽位稳定排序，刷新时行的顺序不会跳。
static func _compare_rows(a: Dictionary, b: Dictionary) -> bool:
	var a_war := String(_as_dict(a.relation).get("state", "")) == "war"
	var b_war := String(_as_dict(b.relation).get("state", "")) == "war"
	if a_war != b_war:
		return a_war
	if bool(a.adjacent) != bool(b.adjacent):
		return bool(a.adjacent)
	if int(a.cells) != int(b.cells):
		return int(a.cells) > int(b.cells)
	return int(a.slot) < int(b.slot)


func _roster_row_for(slot: int, entry: Dictionary, borders: Dictionary) -> Dictionary:
	var first_cell := int(entry.first)
	var handle := _handle_for_slot(slot, first_cell)
	var summary := _cell_summary(first_cell)
	var display_name := String(summary.get("country_name", "")).strip_edges()
	if display_name.is_empty():
		display_name = CountryMapQueryScript.country_name(_country_facade, handle)
	if display_name.is_empty():
		display_name = "第 %d 国" % (slot + 1)
	var era := -1
	if handle != 0 and _country_facade != null \
			and _country_facade.has_method("current_era_index"):
		era = int(_country_facade.call("current_era_index", handle))
	var row := {
		"id": handle if handle != 0 else -1 - slot,
		"slot": slot,
		"handle": handle,
		"name": display_name,
		"cells": int(entry.cells),
		"explored_cells": int(entry.explored),
		"visible_cells": int(entry.visible),
		"contact": "visible" if int(entry.visible) > 0 else "explored",
		"adjacent": borders.has(slot),
		"border_edges": int(borders.get(slot, 0)),
		"era": era,
		"era_label": era_label(era),
		"technology_count": int(summary.get("technology_count", 0)),
		"territory_count": int(summary.get("territory_count", int(entry.cells))),
		"capital_cell": first_cell,
		"relation": _relation_for_slot(slot),
	}
	# 门控在行上先算好，名录与档案读同一个结论（不重复问运行期）。
	var gate := _declare_gate_for_row(row)
	row["can_declare"] = bool(gate.get("enabled", false))
	row["declare_reason"] = String(gate.get("reason", ""))
	return row


func _row(row_id: int) -> Dictionary:
	if row_id == 0:
		return {}
	if _row_by_id.is_empty():
		for row in roster():
			_row_by_id[int(row.id)] = row
	return _as_dict(_row_by_id.get(row_id, null))


func _row_for_handle(handle: int) -> Dictionary:
	if handle == 0:
		return {}
	if _row_by_handle.is_empty():
		for row in roster():
			if int(row.handle) != 0:
				_row_by_handle[int(row.handle)] = row
	return _as_dict(_row_by_handle.get(handle, null))


## 单国档案。军事读数只在这里取——名录行不带，避免四十国 × 全局扫描。
func country_sheet(row_id: int) -> Dictionary:
	if not _available:
		return {"ok": false, "reason": reason()}
	var row := _row(row_id)
	if row.is_empty():
		return {"ok": false, "reason": "该国不在外交名录中。"}
	var key := "sheet_%d_%d" % [row_id, _day]
	if _sheet_cache.has(key):
		return _sheet_cache[key]
	var sheet := _build_sheet(row)
	_sheet_cache[key] = sheet
	return sheet


func _build_sheet(row: Dictionary) -> Dictionary:
	var handle := int(row.handle)
	var summary := _cell_summary(int(row.capital_cell))
	var territory := int(summary.get("territory_count", int(row.cells)))
	var technology := int(summary.get("technology_count", int(row.technology_count)))
	var cash := int(summary.get("cash", 0))
	var soldiers := -1
	var posts := 0
	var barracks := 0
	var armies := 0
	if military_available() and handle != 0 and _military_facade != null \
			and _military_facade.has_method("country_snapshot"):
		var snapshot = _military_facade.call("country_snapshot", handle)
		if snapshot is Dictionary and bool((snapshot as Dictionary).get("ok", false)):
			soldiers = int((snapshot as Dictionary).get("soldiers_total", 0))
			posts = int((snapshot as Dictionary).get("post_count", 0))
			barracks = _as_array((snapshot as Dictionary).get("barracks", [])).size()
			if _military_facade.has_method("armies"):
				armies = _as_array(_military_facade.call("armies", handle)).size()
	var facts: Array = [
		{"id": "territory", "title": "领土", "value": "%d 格" % territory,
			"subtitle": "已探明 %d" % int(row.explored_cells),
			"icon": "metric.territory", "accent": UITokens.ACCENT},
		{"id": "technology", "title": "科技", "value": "%d 项" % technology,
			"icon": "country.technology", "accent": UITokens.CLIMATE},
		{"id": "era", "title": "纪元", "value": String(row.era_label),
			"icon": "system.calendar", "accent": UITokens.ACCENT},
	]
	if soldiers >= 0:
		facts.append({"id": "soldiers", "title": "兵力",
			"value": _count(soldiers),
			"subtitle": ("%d 支野战军" % armies) if armies > 0 else "",
			"icon": "military.army.attack",
			"accent": UITokens.RISK if soldiers > _player_soldiers() else UITokens.ACCENT})
		facts.append({"id": "barracks", "title": "兵营", "value": "%d 座" % barracks,
			"subtitle": ("兵额 %s" % _count(posts)) if posts > 0 else "",
			"icon": "military.plan.barracks", "accent": UITokens.ACCENT})
	else:
		facts.append({"id": "soldiers", "title": "兵力", "value": "未见其境",
			"icon": "military.army.attack", "accent": UITokens.ACCENT})
	facts.append({"id": "cash", "title": "国库", "value": _money_text(cash),
		"money": true, "icon": "metric.treasury", "accent": UITokens.RESOURCE})
	return {
		"ok": true,
		"id": int(row.id),
		"handle": handle,
		"slot": int(row.slot),
		"name": String(row.name),
		"contact": String(row.contact),
		"contact_text": "通视" if String(row.contact) == "visible" else "已探明",
		"era_label": String(row.era_label),
		"facts": facts,
		"compare": _compare_bars(row, soldiers),
		"relation": row.relation,
		"locate_cell": int(row.capital_cell),
		"declare": _declare_gate_for_row(row),
		"peace_war_id": int(_as_dict(row.relation).get("war_id", 0)),
		"note": _sheet_note(row),
	}


## 国力对比：两条同标尺的两段条。对方军事读数未知时只留领土一条。
func _compare_bars(row: Dictionary, soldiers: int) -> Array:
	var bars: Array = []
	var mine_territory := int(_model.get("territory_count", 0))
	var theirs_territory := int(row.territory_count)
	if mine_territory > 0 or theirs_territory > 0:
		bars.append({
			"id": "territory",
			"title": "领土对比",
			"total": "%d 格" % (mine_territory + theirs_territory),
			"segments": [
				{"id": "mine", "label": "本国", "text": "%d 格" % mine_territory,
					"value": float(mine_territory), "color": UITokens.DOSSIER_BRASS},
				{"id": "theirs", "label": String(row.name),
					"text": "%d 格" % theirs_territory,
					"value": float(theirs_territory),
					"color": UITokens.DOSSIER_SLATE},
			],
		})
	var mine_soldiers := maxi(_player_soldiers(), 0)
	if soldiers > 0 or mine_soldiers > 0:
		bars.append({
			"id": "soldiers",
			"title": "兵力对比",
			"total": "%s 人" % _count(mine_soldiers + maxi(soldiers, 0)),
			"segments": [
				{"id": "mine", "label": "本国", "text": _count(mine_soldiers),
					"value": float(mine_soldiers), "color": UITokens.DOSSIER_VERDIGRIS},
				{"id": "theirs", "label": String(row.name),
					"text": _count(maxi(soldiers, 0)),
					"value": float(maxi(soldiers, 0)),
					"color": UITokens.DOSSIER_OXBLOOD},
			],
		})
	return bars


func _sheet_note(row: Dictionary) -> String:
	var relation := _as_dict(row.relation)
	if String(relation.get("state", "")) == "war":
		return "正在交战 · 第 %d 日 · 战争分 %s" % [int(relation.get("days", 0)),
			String(relation.get("score_text", "0"))]
	if bool(row.adjacent):
		return "接壤 · 边域 %d 面" % int(row.border_edges)
	return "不接壤 · 跋涉不易"


## 宣战门控。原生只校验「有兵、未交战、无停战」（`MilitaryCore::apply_war_command`），
## 接壤不是前置——海军科技下远洋同样可及，所以这里也只按原生规则给结论。
func declare_gate(handle: int) -> Dictionary:
	if not _available:
		return {"enabled": false, "reason": reason()}
	if handle == 0:
		return {"enabled": false, "reason": "未建立往来"}
	var row := _row_for_handle(handle)
	if row.is_empty():
		return {"enabled": false, "reason": "未建立往来"}
	return _declare_gate_for_row(row)


func _declare_gate_for_row(row: Dictionary) -> Dictionary:
	var relation := _as_dict(row.relation)
	if String(relation.get("state", "")) == "war":
		return {"enabled": false, "reason": "正在交战",
			"peace_war_id": int(relation.get("war_id", 0))}
	if not military_available():
		return {"enabled": false, "reason": "军事尚未接通"}
	if _player_soldiers() <= 0:
		return {"enabled": false, "reason": "无兵可战 · 先在军事中募兵"}
	return {"enabled": true, "reason": ""}


# ── 战事 ─────────────────────────────────────────────────────────────────

func wars_model(selected: int) -> Dictionary:
	var rows := war_rows()
	if rows.is_empty():
		return {"ok": true, "rows": [], "selected": 0, "sheet": {},
			"empty": wars_empty_text()}
	var current := selected
	var found := false
	for row in rows:
		if int(row.id) == current:
			found = true
	if not found:
		current = int(rows[0].id)
	return {
		"ok": true,
		"rows": rows,
		"selected": current,
		"sheet": war_sheet(current),
		"empty": "",
	}


func wars_empty_text() -> String:
	if not military_available():
		return military_reason()
	return ""


func war_rows() -> Array:
	var rows: Array = []
	for entry in _entries():
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


func war_sheet(war_id: int) -> Dictionary:
	if not _available:
		return {"ok": false, "reason": reason()}
	var entry: Dictionary = {}
	for candidate in _entries():
		if int(_as_dict(candidate.card).get("id", 0)) == war_id:
			entry = candidate
			break
	if entry.is_empty():
		return {"ok": false, "reason": "该战争已经结束。"}
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
	for row_value in _vm.front_rows().slice(0, MAX_FRONT_ROWS):
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
	for row_value in _vm.war_log().slice(0, MAX_LOG_ROWS):
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


## 战争行的原始快照与映射卡配对。`war_cards()` 按快照顺序产出，所以按下标对齐。
func _entries() -> Array:
	if _vm == null:
		return []
	var signature := "%d|%d" % [_day, int(_as_dict(_vm.snapshot()).get("wars_active", -1))]
	if signature == _war_entries_signature and not _war_entries.is_empty():
		return _war_entries
	_war_entries_signature = signature
	_war_entries = []
	if not _vm.available():
		return _war_entries
	var raw_wars := _as_array(_vm.snapshot().get("wars", null))
	var cards: Array = _vm.war_cards()
	for index in range(raw_wars.size()):
		var raw := _as_dict(raw_wars[index])
		var card := _as_dict(cards[index]) if index < cards.size() else {}
		if card.is_empty():
			continue
		var enemy_slot := _enemy_slot_of(raw)
		_war_entries.append({
			"raw": raw,
			"card": card,
			"enemy_slot": enemy_slot,
			"enemy_handle": _handle_for_slot(enemy_slot) if enemy_slot >= 0 else 0,
		})
	return _war_entries


func _enemy_slot_of(war: Dictionary) -> int:
	if _player_slot < 0:
		return -1
	var attacker := int(war.get("attacker_slot", -1))
	var defender := int(war.get("defender_slot", -1))
	return defender if attacker == _player_slot else attacker


func _relation_for_slot(slot: int) -> Dictionary:
	for entry in _entries():
		if int(entry.enemy_slot) != slot:
			continue
		var card := _as_dict(entry.card)
		return {
			"state": "war",
			"war_id": int(card.get("id", 0)),
			"days": int(card.get("days", 0)),
			"score_text": String(card.get("score_text", "0")),
			"role": String(card.get("role", "")),
		}
	return {"state": "peace", "war_id": 0, "days": 0, "score_text": "", "role": ""}


# ── 会话读取 ─────────────────────────────────────────────────────────────

## 会话地图：模型显式给的优先，其次 fixture 的 `current_map()`。
func _map():
	if _map_obj != null:
		return _map_obj
	return CountryMapQueryScript.map_of(_generator)


func _resolve_player_slot() -> int:
	if _vm != null and _vm.available():
		var slot := int(_as_dict(_vm.snapshot()).get("country_slot", -1))
		if slot >= 0:
			return slot
	return CountryMapQueryScript.slot_of_handle(_country_handle)


func _handle_for_slot(slot: int, first_cell: int = -1) -> int:
	if slot < 0:
		return 0
	if _handle_by_slot.has(slot):
		return int(_handle_by_slot[slot])
	var handles := _as_dict(_as_dict(_model.get("military", null)).get(
		"country_handles", null))
	var first_cells := {}
	if first_cell >= 0:
		first_cells[slot] = first_cell
	var handle := CountryMapQueryScript.handle_for_slot(_owners, slot,
		_country_facade, handles, first_cells)
	_handle_by_slot[slot] = handle
	return handle


func _cell_summary(cell: int) -> Dictionary:
	if cell < 0 or _country_facade == null \
			or not _country_facade.has_method("cell_summary"):
		return {}
	var summary = _country_facade.call("cell_summary", cell)
	if not (summary is Dictionary) or not bool((summary as Dictionary).get("ok", false)):
		return {}
	return summary


func _player_soldiers() -> int:
	if not military_available():
		return 0
	return int(_as_dict(_vm.snapshot()).get("soldiers_total", 0))


## 我方控制、但归属不是本国的格数（= 占着别人的地）。
func _occupied_cells() -> int:
	if not military_available() or _military_facade == null \
			or not _military_facade.has_method("control_snapshot"):
		return 0
	var control = _military_facade.call("control_snapshot")
	if not (control is Dictionary) or not bool((control as Dictionary).get("ok", false)):
		return 0
	var cells = (control as Dictionary).get("cells", PackedInt32Array())
	var controllers = (control as Dictionary).get("controller_slots", PackedInt32Array())
	if not (cells is PackedInt32Array) or not (controllers is PackedInt32Array):
		return 0
	var owners := _owners
	if owners.is_empty():
		owners = CountryMapQueryScript.owner_map(_generator, _model, _map())
	var occupied := 0
	var total := mini((cells as PackedInt32Array).size(),
		(controllers as PackedInt32Array).size())
	for index in range(total):
		if int((controllers as PackedInt32Array)[index]) != _player_slot:
			continue
		var cell := int((cells as PackedInt32Array)[index])
		if cell < 0 or cell >= owners.size():
			continue
		if int(owners[cell]) != _player_slot:
			occupied += 1
	return occupied


# ── 命名与格式化 ─────────────────────────────────────────────────────────

func country_name(slot: int) -> String:
	if _vm != null:
		return _vm.country_name(slot)
	return "第 %d 国" % (slot + 1)


func cell_name(cell: int) -> String:
	if _vm != null:
		return _vm.cell_name(cell)
	return ("地块 #%d" % cell) if cell >= 0 else "—"


func zone_name(cell: int) -> String:
	if _vm != null:
		return _vm.zone_name(cell)
	return cell_name(cell)


static func era_label(era: int) -> String:
	if era < 0:
		return "—"
	return String(ERA_LABELS[clampi(era, 0, ERA_LABELS.size() - 1)])


static func _count(raw) -> String:
	return UITokens.format_compact_number_cn(float(raw), 1)


static func _money_text(raw) -> String:
	return UITokens.format_compact_number_cn(float(raw) / MONEY_SCALE, 2)


static func _as_dict(value) -> Dictionary:
	return value if value is Dictionary else {}


static func _as_array(value) -> Array:
	return value if value is Array else []
