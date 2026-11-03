extends RefCounted
class_name MilitaryPeaceViewModel

## Read-only model for MilitaryPeaceWindow (design §12.3 / §14.3).
##
## The peace window is a second consumer of the same war data the military
## workspace already shows, so this class deliberately wraps a configured
## MilitaryViewModel instead of re-deriving the cession and ownership rules:
## every number is either a public MilitaryViewModel call or a facade read
## (price / willingness / gap). Nothing here writes back, and no node is created
## — the window only writes values into a static scene.
##
## Why `ceding_cells` is computed twice: `MilitaryViewModel.ceded_cells()`
## treats a missing checkbox entry as checked (the old inline editor shipped
## every occupied cell pre-ticked). A peace draft starts empty, so every
## candidate is first pinned to false and the draft then re-enables the picked
## ones. When `ceded_cells()` grows a `default_checked` parameter this shim goes
## away; until then it keeps the default in one place (here) instead of changing
## the meaning for the workspace.

const MilitaryViewModelScript = preload("res://scripts/ui/military_view_model.gd")

const Q16 := 65536.0
## Same order as the bridge's `band` strings (world_ext_military.cpp).
const BAND_NAMES: Array[String] = ["low", "mid", "high"]
## The list is one self-drawn control; past this the map is the only practical
## way to pick a cell, so the list truncates and says how many are left.
const MAX_LIST_CELLS := 256
const MAX_LOG_ROWS := 3

var _model: Dictionary = {}
var _vm


func configure(model: Dictionary) -> void:
	_model = model if model != null else {}
	if _vm == null:
		_vm = MilitaryViewModelScript.new()
	_vm.configure(_model)


func view_model():
	return _vm


func available() -> bool:
	return _vm != null and _vm.available()


func reason() -> String:
	if _vm == null:
		return "军事数据暂不可用"
	var text := String(_vm.reason())
	return text if not text.is_empty() else "军事数据暂不可用"


## A fresh draft is a white peace: it is the only term that can never be
## rejected for price, so the window opens with a valid, submittable deal.
static func empty_draft() -> Dictionary:
	return {
		"white": true,
		"annex": false,
		"lump": false,
		"amount": 0.0,
		"install": false,
		"install_amount": 0.0,
		"install_count": 4,
		"ceding": {},
	}


static func selected_cells(draft: Dictionary) -> PackedInt32Array:
	var cells := PackedInt32Array()
	var ceding := {}
	var raw = draft.get("ceding", {})
	if raw is Dictionary:
		ceding = raw
	var keys: Array = ceding.keys()
	keys.sort()
	for key in keys:
		if bool(ceding[key]):
			cells.append(int(key))
	return cells


## Bridge term array for the current draft, in the same schema
## `encode_peace_terms()` accepts (`white` / `cede` / `annex` / `lump_sum` /
## `installments`). White peace is exclusive: it is the status quo, so nothing
## else is sent with it.
static func peace_terms(draft: Dictionary) -> Array:
	if bool(draft.get("white", false)):
		return [{"kind": "white"}]
	var terms: Array = []
	for cell in selected_cells(draft):
		terms.append({"kind": "cede", "cell": int(cell)})
	if bool(draft.get("annex", false)):
		terms.append({"kind": "annex"})
	if bool(draft.get("lump", false)) and float(draft.get("amount", 0.0)) > 0.0:
		terms.append({"kind": "lump_sum", "amount": float(draft.get("amount", 0.0))})
	if bool(draft.get("install", false)) \
			and float(draft.get("install_amount", 0.0)) > 0.0:
		terms.append({
			"kind": "installments",
			"amount": float(draft.get("install_amount", 0.0)),
			"n": clampi(int(draft.get("install_count", 4)), 2, 12),
		})
	return terms


## Everything the window draws, for one war and one draft.
func peace_model(war_id: int, draft: Dictionary) -> Dictionary:
	if not available():
		return {"ok": false, "reason": reason()}
	var war := _war_row(war_id)
	if war.is_empty():
		return {"ok": false, "reason": "该战争已经结束。", "war": {}}
	var card: Dictionary = _vm.war_card(war)
	var enemy_slot := _enemy_slot(war)
	var cession := _cession(war, draft)
	var enemy_owned := _enemy_owned(enemy_slot)
	var candidates := int(cession.get("total", 0))
	var fully_occupied := bool(card.get("fully_occupied", false))
	var can_annex := fully_occupied and candidates > 0 \
		and (enemy_owned < 0 or candidates >= enemy_owned)
	var terms := peace_terms(draft)
	return {
		"ok": true,
		"day": int(_model.get("current_day", -1)),
		"war": card,
		"enemy_slot": enemy_slot,
		"situation": _situation(card, cession, enemy_owned),
		"cession": cession,
		"annex": {
			"can": can_annex,
			"fully_occupied": fully_occupied,
			"enemy_owned": enemy_owned,
		},
		"terms": _evaluate(war_id, float(card.get("score", 0.0)), terms),
	}


# ── war row / cession ────────────────────────────────────────────────────

## Raw snapshot row for one war. `war_card()` and `ceded_cells()` both read the
## slot fields from it, so the mapped card alone is not enough to ask them.
func _war_row(war_id: int) -> Dictionary:
	var wars: Array = _vm.snapshot().get("wars", [])
	for index in range(wars.size()):
		var row = wars[index]
		if row is Dictionary and int((row as Dictionary).get("war_id", 0)) == war_id:
			return row as Dictionary
	return {}


func _enemy_slot(war: Dictionary) -> int:
	var mine := int(_vm.snapshot().get("country_slot", -1))
	if int(war.get("attacker_slot", -1)) == mine:
		return int(war.get("defender_slot", -1))
	return int(war.get("attacker_slot", -1))


func _cession(war: Dictionary, draft: Dictionary) -> Dictionary:
	var all: Dictionary = _vm.ceded_cells(war, {})
	var checked := {}
	for row in all.get("rows", []):
		checked[int((row as Dictionary).get("id", -1))] = false
	var picked := {}
	var raw = draft.get("ceding", {})
	if raw is Dictionary:
		picked = raw
	for key in picked.keys():
		if bool(picked[key]):
			checked[int(key)] = true
	var result: Dictionary = _vm.ceded_cells(war, checked)
	var rows: Array = result.get("rows", [])
	var total := int(result.get("total", 0))
	var capped := rows.size() > MAX_LIST_CELLS
	if capped:
		rows = rows.slice(0, MAX_LIST_CELLS)
	# Every candidate belongs to the same enemy, so the per-row "原属〈国〉" note
	# only repeats the window title and steals the label column.
	var cleaned: Array = []
	for row_value in rows:
		var row: Dictionary = (row_value as Dictionary).duplicate()
		row["note"] = ""
		cleaned.append(row)
	return {
		"rows": cleaned,
		"cells": result.get("cells", PackedInt32Array()),
		"total": total,
		"checked": int(result.get("checked", 0)),
		"capped": capped,
	}


## Cells the enemy still owns. -1 = the owner map is not readable on this mount
## (no generator, no fixture stand-in); the annex gate then falls back to the
## full-occupation flag alone instead of inventing a count.
func _enemy_owned(enemy_slot: int) -> int:
	if enemy_slot < 0:
		return -1
	var owners := _owner_array()
	if owners.is_empty():
		return -1
	var count := 0
	for index in range(owners.size()):
		if int(owners[index]) == enemy_slot:
			count += 1
	return count


func _owner_array() -> PackedInt32Array:
	var generator = _model.get("generator", null)
	if generator == null:
		var section = _model.get("military", null)
		if section is Dictionary:
			generator = (section as Dictionary).get("generator", null)
	if generator != null and generator.has_method("get_data_core_world_ext"):
		var ext = generator.call("get_data_core_world_ext")
		if ext != null and ext.has_method("get_country_cell_snapshot"):
			var owners = ext.call("get_country_cell_snapshot")
			if owners is PackedInt32Array:
				return owners
	var stand_in = {}
	var military = _model.get("military", null)
	if military is Dictionary:
		var cell_owners = (military as Dictionary).get("cell_owners", null)
		if cell_owners is Dictionary:
			stand_in = cell_owners
	var rows = stand_in.get("owners", PackedInt32Array())
	return rows if rows is PackedInt32Array else PackedInt32Array()


# ── situation / evaluation ───────────────────────────────────────────────

func _situation(card: Dictionary, cession: Dictionary, enemy_owned: int) -> Dictionary:
	var fronts: Array = _vm.front_rows()
	var engagement = card.get("engagement", {})
	var engaged := engagement is Dictionary and not (engagement as Dictionary).is_empty()
	var log: Array = []
	for row_value in _vm.war_log().slice(0, MAX_LOG_ROWS):
		var row: Dictionary = row_value
		log.append({
			"day": int(row.get("day", 0)),
			"kind": String(row.get("kind", "战事")),
			"text": String(row.get("text", "")),
		})
	return {
		"kpis": _kpis(card, cession, enemy_owned, fronts.size(), engaged, engagement),
		"parts": card.get("score_parts", []),
		"log": log,
		"days": int(card.get("days", 0)),
		"losses_text": String(card.get("losses_text", "")),
		"fully_occupied": bool(card.get("fully_occupied", false)),
		"enemy_owned": enemy_owned,
		"front_count": fronts.size(),
		"engaged": engaged,
	}


func _kpis(card: Dictionary, cession: Dictionary, enemy_owned: int, front_count: int,
		engaged: bool, engagement) -> Array:
	var score := float(card.get("score", 0.0))
	var occupied := int(cession.get("total", 0))
	var enemy_caption := ""
	if enemy_owned >= 0:
		enemy_caption = "敌国共 %d 格" % enemy_owned
	var engagement_caption := "对峙"
	if engaged:
		var row: Dictionary = engagement
		engagement_caption = "交战中 · 推进 %s" % String(row.get("progress_text", "—"))
	return [
		{"id": "score", "title": "战争分", "kind": "text",
			"text": String(card.get("score_text", "0")),
			"caption": String(card.get("role", "")),
			"icon": "military.war.front",
			"tone": "risk" if score < 0.0 else ""},
		{"id": "occupied", "title": "我方占领", "kind": "count",
			"value": float(occupied), "caption": enemy_caption,
			"icon": "military.plan.target"},
		{"id": "enemy", "title": "敌方残土", "kind": "count",
			"value": float(maxi(enemy_owned, 0)), "caption": enemy_caption,
			"icon": "metric.territory"},
		{"id": "front", "title": "战线", "kind": "count",
			"value": float(front_count), "caption": engagement_caption,
			"icon": "military.war.battle"},
	]


## Native evaluator is authoritative; the local estimate only runs when the
## facade is absent (fixtures, an old bridge) and is flagged as such.
func _evaluate(war_id: int, war_score: float, terms: Array) -> Dictionary:
	var facade = _vm.facade()
	if facade != null and facade.has_method("evaluate_peace"):
		var native = facade.call("evaluate_peace", war_id, _vm.country_handle(), terms)
		if native is Dictionary and bool((native as Dictionary).get("ok", false)):
			var data: Dictionary = native
			var band := BAND_NAMES.find(String(data.get("band", "low")))
			return {
				"ok": true,
				"estimated": false,
				"price": float(data.get("price", 0.0)),
				"willing": float(data.get("willing", 0.0)),
				"gap": float(int(data.get("gap_q16", 0))) / Q16,
				"band": maxi(band, 0),
				"reason": String(data.get("reason", "")),
				"terms": terms,
				"count": terms.size(),
			}
	var local: Dictionary = _vm.evaluate_peace(war_id, war_score, terms)
	var price := float(local.get("price", 0.0))
	# The local fallback predates the cede term and prices `ceding` bundles by
	# count; a ceded cell is at least `max(2, cell_value)` points in the native
	# table, so the floor is added here instead of showing a free land grab.
	for term_value in terms:
		if String((term_value as Dictionary).get("kind", "")) == "cede":
			price += 2.0
	var available := maxf(0.0, war_score)
	var band := 0
	if available > 0.0:
		band = 2 if price <= available * 0.6 else (1 if price <= available else 0)
	return {
		"ok": bool(local.get("ok", true)),
		"estimated": true,
		"price": price,
		"willing": -1.0,
		"gap": 0.0,
		"band": band,
		"reason": String(local.get("reason", "")),
		"terms": terms,
		"count": terms.size(),
	}
