class_name StratumUnrestService
extends RefCounted

## Bridges native stratum mobilization facts to the narrative event chain and,
## for AI countries, to automatic resolutions. Player choices are applied while
## the narrative popup holds the clock paused, so the economy is idle.

const GameplayEventBusScript = preload("res://scripts/data_core/gameplay_event_bus.gd")
const NarrativeRngScript = preload("res://scripts/narrative/narrative_rng.gd")
const RebellionContentScript = preload("res://scripts/politics/stratum_rebellion_content.gd")

const CONSUMER_ID := &"stratum_unrest_service"
const SCHEMA_VERSION := 1
const FLAG_PLAYER := 1
const FLAG_CAPITAL := 2
const FLAG_INDEPENDENCE := 8

var _generator = null
var _map = null
var _clock = null
var _narrative = null
var _economy = null
var _country = null
var _military = null
var _player_handle := 0
var _world_seed := 1

var _last_fact_id := -1
var _last_day := -1
var _sequence := 1
## Deferred AI facts: applying the sparse row from the main thread while the
## economy worker may be settling is unsafe, so AI resolutions run only when the
## clock is paused (the normal case when a narrative popup is open).
var _pending_ai: Array[Dictionary] = []
## cell/owner pairs waiting for the D+1 country batch.
var _pending_independence: Array[Dictionary] = []


func configure(generator, map, clock, narrative, economy, country, military,
		player_handle: int, world_seed: int) -> void:
	_generator = generator
	_map = map
	_clock = clock
	_narrative = narrative
	_economy = economy
	_country = country
	_military = military
	_player_handle = player_handle
	_world_seed = maxi(1, world_seed)
	if _narrative != null and _narrative.has_signal("offer_resolved"):
		if not _narrative.offer_resolved.is_connected(on_offer_resolved):
			_narrative.offer_resolved.connect(on_offer_resolved)


func set_player_country_handle(handle: int) -> void:
	_player_handle = handle


func set_facades(economy, country, military) -> void:
	_economy = economy
	_country = country
	_military = military


func step_daily(day: int) -> void:
	if day <= _last_day:
		return
	_last_day = day
	_poll_facts(day)
	_process_pending_ai(day)
	_process_independence(day)


func on_offer_resolved(record: Dictionary) -> void:
	var meta: Dictionary = record.get("meta", {})
	if String(meta.get("kind", "")) != "rebellion":
		return
	var actions: Array = meta.get("actions", [])
	var costs: Array = meta.get("cost_bps", [])
	var option_index := int(record.get("chosen_option_index", -1))
	if option_index < 0 or option_index >= actions.size():
		return
	var cell := int(meta.get("cell", -1))
	var profession := int(meta.get("profession", -1))
	var stage := int(meta.get("stage", 1))
	var owner_handle := int(meta.get("owner_handle", 0))
	var action := int(actions[option_index])
	var cost_bp := int(costs[option_index]) if option_index < costs.size() else 0
	var success := int(record.get("rolled_outcome_index", 1)) == 0
	if _economy == null or not _economy.is_configured():
		return
	if action in [RebellionContentScript.ACTION_CONCEDE,
			RebellionContentScript.ACTION_BRIBE]:
		_pay_concession(cell, cost_bp, int(record.get("day", _last_day)))
	_economy.apply_mobilization_result(cell, profession, action, success)
	if action == RebellionContentScript.ACTION_ABANDON or \
			(stage >= 4 and not success):
		_queue_independence(cell, owner_handle)


func export_state() -> Dictionary:
	return {
		"schema": "PKStratumUnrest",
		"version": SCHEMA_VERSION,
		"last_fact_id": _last_fact_id,
		"last_day": _last_day,
		"sequence": _sequence,
		"pending_ai": _pending_ai.duplicate(true),
		"pending_independence": _pending_independence.duplicate(true),
	}


func restore_state(state: Dictionary) -> Dictionary:
	if String(state.get("schema", "")) != "PKStratumUnrest":
		return {"ok": true}
	if int(state.get("version", 0)) != SCHEMA_VERSION:
		return {"ok": false, "reason": "stratum_unrest_schema_incompatible"}
	_last_fact_id = int(state.get("last_fact_id", -1))
	_last_day = int(state.get("last_day", -1))
	_sequence = maxi(1, int(state.get("sequence", 1)))
	_pending_ai = (state.get("pending_ai", []) as Array).duplicate(true)
	_pending_independence = (
		state.get("pending_independence", []) as Array).duplicate(true)
	return {"ok": true}


# ─── facts ────────────────────────────────────────────────────────────────

func _poll_facts(day: int) -> void:
	if _generator == null or not _generator.has_method("get_gameplay_event_bus"):
		return
	var bus = _generator.get_gameplay_event_bus()
	if bus == null or not bus.is_available():
		return
	var batch: Dictionary = bus.poll_events(CONSUMER_ID, 32, 0, true, _last_fact_id)
	var count := int(batch.get("count", 0))
	if count <= 0:
		return
	var event_ids: PackedInt64Array = batch.get("event_id", PackedInt64Array())
	var types: PackedInt32Array = batch.get("type", PackedInt32Array())
	var cells: PackedInt32Array = batch.get("cell_idx", PackedInt32Array())
	var p0: PackedInt32Array = batch.get("payload_i0", PackedInt32Array())
	var p1: PackedInt32Array = batch.get("payload_i1", PackedInt32Array())
	var p2: PackedInt32Array = batch.get("payload_i2", PackedInt32Array())
	var p3: PackedInt32Array = batch.get("payload_i3", PackedInt32Array())
	var flags: PackedInt32Array = batch.get("flags", PackedInt32Array())
	for i in range(count):
		if i < event_ids.size():
			_last_fact_id = maxi(_last_fact_id, int(event_ids[i]))
		if i >= types.size() or int(types[i]) != GameplayEventBusScript.EVENT_STRATUM_MOBILIZATION:
			continue
		var cell := int(cells[i]) if i < cells.size() else -1
		var stage := int(p0[i]) if i < p0.size() else 0
		var previous := int(p1[i]) if i < p1.size() else 0
		var profession := int(p2[i]) if i < p2.size() else -1
		var country_slot := int(p3[i]) if i < p3.size() else -1
		var flag_bits := int(flags[i]) if i < flags.size() else 0
		if cell < 0 or profession < 0 or stage <= 0:
			continue
		var summary: Dictionary = _country.cell_summary(cell) if _country != null else {}
		var owner_handle := int(summary.get("country_handle", 0))
		if owner_handle == 0:
			continue
		if (flag_bits & FLAG_INDEPENDENCE) != 0:
			_queue_independence(cell, owner_handle)
			continue
		if owner_handle == _player_handle:
			if (flag_bits & FLAG_CAPITAL) == 0 and stage > previous:
				_offer_player(cell, profession, stage, owner_handle, day)
		# AI facts need no service action: native auto-resolves the stage and the
		# independence bit was already queued by the branch above.


# ─── player chain ─────────────────────────────────────────────────────────

func _offer_player(cell: int, profession: int, stage: int,
		owner_handle: int, day: int) -> void:
	if _narrative == null or _economy == null or not _economy.is_configured():
		return
	var actions: Array = RebellionContentScript.actions_for_stage(stage)
	var probabilities := {}
	var costs: Array = []
	for i in range(actions.size()):
		var action := int(actions[i])
		var odds: Dictionary = _economy.mobilization_odds(cell, profession, action, 0)
		var cost_bp := int(odds.get("cost_bp", 0))
		costs.append(cost_bp)
		if action == RebellionContentScript.ACTION_IGNORE:
			probabilities[i] = PackedInt32Array([0, 65536])
		elif action == RebellionContentScript.ACTION_ABANDON:
			probabilities[i] = PackedInt32Array([65536, 0])
		else:
			var p := int(odds.get("p_success_q16", 32768))
			probabilities[i] = PackedInt32Array([p, 65536 - p])
	var settlement: String = _economy.settlement_display_name(cell)
	if settlement.is_empty():
		settlement = "本地"
	var profession_name := _profession_name(profession)
	var profession_key := ""
	var ids: PackedStringArray = _economy.profession_ids()
	if profession >= 0 and profession < ids.size():
		profession_key = String(ids[profession])
	var def = RebellionContentScript.build(
		stage, profession_name, settlement, actions, probabilities, costs,
		profession_key)
	var chain_salt := int(NarrativeRngScript.hash64(
		_world_seed, day, _player_handle, cell, profession * 31 + stage) & 0x7fffffff)
	var meta := {
		"kind": "rebellion",
		"cell": cell,
		"profession": profession,
		"stage": stage,
		"owner_handle": owner_handle,
		"actions": actions,
		"cost_bps": costs,
	}
	_narrative.enqueue_event_offer(
		def, cell, day, StringName("rebellion:%d:%d" % [cell, profession]),
		true, {"settlement_name": settlement}, probabilities, chain_salt, meta)


func _pay_concession(cell: int, cost_bp: int, day: int) -> void:
	if cost_bp <= 0 or _country == null or _economy == null:
		return
	var country_snapshot: Dictionary = _country.snapshot(_player_handle)
	var treasury_cash := int(country_snapshot.get("cash", 0))
	var amount := int(treasury_cash * cost_bp / 10000)
	if amount <= 0:
		return
	var cohort_handle := _primary_cohort(cell)
	if cohort_handle == 0:
		return
	_sequence += 1
	_economy.transfer_country_cash_to_cohort(
		_player_handle, cohort_handle, amount, day, _sequence)


func _primary_cohort(cell: int) -> int:
	if _economy == null:
		return 0
	var snapshot: Dictionary = _economy.population_cell_snapshot(cell, true)
	var handles: PackedInt64Array = snapshot.get("handles", PackedInt64Array())
	var populations: PackedInt64Array = snapshot.get("populations", PackedInt64Array())
	var best := 0
	var best_pop := -1
	for i in range(mini(handles.size(), populations.size())):
		if int(populations[i]) > best_pop:
			best_pop = int(populations[i])
			best = int(handles[i])
	return best


func _profession_name(profession: int) -> String:
	if _economy == null:
		return "本地阶层"
	var ids: PackedStringArray = _economy.profession_ids()
	if profession < 0 or profession >= ids.size():
		return "本地阶层"
	var key := String(ids[profession])
	const NAMES := {
		"soldier": "军士", "farmer": "农户", "subsistence_farmer": "小农",
		"tenant_farmer": "佃户", "sharecropper": "分成佃农",
		"agricultural_worker": "农工", "artisan": "匠户",
		"apprentice": "学徒", "journeyman": "帮工", "guild_master": "行会师傅",
		"miner": "矿工", "industrial_worker": "工厂工人", "worker": "工人",
		"merchant": "商人", "scholar": "读书人", "scribe": "书吏",
		"serf": "农奴", "unemployed": "失业者", "landlord": "地主",
		"industrialist": "厂主",
	}
	return String(NAMES.get(key, key))


# ─── AI resolution ────────────────────────────────────────────────────────

func _process_pending_ai(day: int) -> void:
	if _pending_ai.is_empty() or _economy == null:
		return
	# Only mutate the sparse rows while the clock is paused: the economy worker
	# is idle at a narrative/decision boundary in that state.
	if _clock != null and not bool(_clock.paused):
		return
	var pending := _pending_ai.duplicate()
	_pending_ai.clear()
	for item in pending:
		var cell := int(item.get("cell", -1))
		var profession := int(item.get("profession", -1))
		var stage := int(item.get("stage", 1))
		var owner_handle := int(item.get("owner_handle", 0))
		var has_garrison := _cell_has_garrison(cell)
		var action := RebellionContentScript.ACTION_REPRESS if has_garrison \
			else RebellionContentScript.ACTION_IGNORE
		var success := false
		if has_garrison:
			success = (int(NarrativeRngScript.hash64(
				_world_seed, day, owner_handle, cell, profession * 17 + stage)) % 2) == 0
		_economy.apply_mobilization_result(cell, profession, action, success)
		if stage >= 4 and not success:
			_queue_independence(cell, owner_handle)


func _cell_has_garrison(cell: int) -> bool:
	if _military == null or not _military.has_method("cell_snapshot"):
		return false
	var snapshot: Dictionary = _military.cell_snapshot(cell)
	return int(snapshot.get("present", 0)) > 0 or \
		int(snapshot.get("garrison", 0)) > 0


# ─── independence ─────────────────────────────────────────────────────────

func _queue_independence(cell: int, owner_handle: int) -> void:
	for item in _pending_independence:
		if int(item.get("cell", -1)) == cell:
			return
	_pending_independence.append({
		"cell": cell,
		"owner_handle": owner_handle,
		"queued_day": _last_day,
		"stable_id": "rebel.%d.%d" % [cell, _last_day],
	})


func _process_independence(day: int) -> void:
	if _pending_independence.is_empty() or _country == null:
		return
	var remaining: Array[Dictionary] = []
	for item in _pending_independence:
		var cell := int(item.get("cell", -1))
		var owner_handle := int(item.get("owner_handle", 0))
		var summary: Dictionary = _country.cell_summary(cell)
		var current := int(summary.get("country_handle", 0))
		if current != owner_handle:
			# The country batch already landed. The old sovereign declares war
			# (forced: a fresh rebel state has no soldiers) and its local
			# garrison follows the city.
			_sequence += 1
			if _military != null:
				if _military.has_method("declare_war_forced"):
					_military.declare_war_forced(owner_handle, current)
				else:
					_military.declare_war(owner_handle, current)
				if _military.has_method("transfer_cell_garrison"):
					_military.transfer_cell_garrison(owner_handle, cell, current)
			continue
		if day <= int(item.get("queued_day", day)):
			remaining.append(item)
			continue
		if int(summary.get("territory_count", 1)) <= 1:
			# Last cell cannot be transferred; the action already applied its
			# failure effects (org/cooldown), so just drop the queue entry.
			continue
		var settlement: String = _economy.settlement_display_name(cell)
		if settlement.is_empty():
			settlement = "边地"
		var stable_id := String(item.get("stable_id", "rebel.%d" % cell))
		_sequence += 1
		_country.create_country(StringName(stable_id), "%s自治" % settlement,
			cell, day, _sequence)
		remaining.append(item)
	_pending_independence = remaining


