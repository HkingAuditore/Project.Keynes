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
var _needs_player_recovery := true
var _pending_stage_checks: Array[Dictionary] = []
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
	if _narrative != null:
		_narrative.bind_rebellion(prepare_player_offer, resolve_player_choice)


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
	var player_stages := {}
	_poll_facts(player_stages)
	if _needs_player_recovery:
		_recover_player_unrest(day, player_stages)
	_process_stage_checks(player_stages)
	_process_pending_ai(day)
	_process_independence(day)
	for key: Vector2i in player_stages:
		_offer_player(key.x, key.y, int(player_stages[key]), _player_handle, day)


func resolve_player_choice(offer: Dictionary, option_index: int, outcome: Dictionary,
		effective_day: int, sequence_alloc: Callable) -> Dictionary:
	var meta: Dictionary = offer["meta"]
	if meta.get("rebellion_obsolete", false):
		return {"ok": true, "outcome": _obsolete_outcome()}
	if _economy == null or not _economy.is_configured():
		return {"ok": false, "code": "mobilization_unavailable", "message": "组织度结算尚未就绪。"}
	var option: Dictionary = offer["options"][option_index]
	var cell := int(meta["cell"])
	var profession := int(meta["profession"])
	var stage := int(meta["stage"])
	var owner := int(meta["owner_handle"])
	var action := int(meta["actions"][option_index])
	var success := bool(outcome["rebellion_success"])
	var cash := int(option.get("rebellion_cash", 0))
	var sequence := 0
	if cash > 0:
		if sequence_alloc.is_valid():
			sequence = int(sequence_alloc.call())
		else:
			_sequence += 1
			sequence = _sequence
	var result: Dictionary = _economy.resolve_player_mobilization({
		"cell": cell, "profession": profession, "stage": stage, "action": action,
		"owner_handle": owner, "success": success, "cash": cash,
		"cohort_handle": int(option.get("rebellion_cohort", 0)),
		"effective_day": effective_day, "sequence": sequence,
	})
	if not result.get("ok", false):
		var code := String(result.get("code", "mobilization_rejected"))
		if code == "mobilization_choice_stale":
			return {"ok": true, "outcome": _obsolete_outcome()}
		return {"ok": false, "code": code, "message": "本次措施尚未执行，请稍后再试。"}
	var secession := _can_secede(cell, owner) and (action == RebellionContentScript.ACTION_ABANDON
		or bool(result.get("independence_pending", false)) or (stage == 4 and not success))
	if secession:
		_queue_independence(cell, owner)
	elif not success and stage < 4:
		# A choice can move the row before the next epoch clears its staged facts.
		_pending_stage_checks.append({
			"cell": cell, "profession": profession, "stage": stage, "owner_handle": owner,
		})
	var settled := RebellionContentScript.outcome(success, stage, action,
		int(outcome["probability_q16"]), int(result.get("queued_cash", 0)), secession)
	return {"ok": true, "outcome": settled, "applied_summaries": settled["effect_summaries"]}


static func _obsolete_outcome() -> Dictionary:
	return {"probability_q16": 65536, "probability_percent": 100,
		"outcome_title": "局势已变", "outcome_narrative": "这份处置已经过时。",
		"effect_summaries": PackedStringArray(["原处置作废"])}


func export_state() -> Dictionary:
	return {
		"schema": "PKStratumUnrest",
		"version": SCHEMA_VERSION,
		"last_fact_id": _last_fact_id,
		"last_day": _last_day,
		"sequence": _sequence,
		"pending_ai": _pending_ai.duplicate(true),
		"pending_independence": _pending_independence.duplicate(true),
		"pending_stage_checks": _pending_stage_checks.duplicate(true),
		"needs_player_recovery": _needs_player_recovery,
	}


func restore_state(state: Dictionary) -> Dictionary:
	if String(state.get("schema", "")) != "PKStratumUnrest":
		_last_fact_id = -1
		_last_day = -1
		_sequence = 1
		_needs_player_recovery = true
		_pending_ai.clear()
		_pending_independence.clear()
		_pending_stage_checks.clear()
		return {"ok": true}
	if int(state.get("version", 0)) != SCHEMA_VERSION:
		return {"ok": false, "reason": "stratum_unrest_schema_incompatible"}
	_last_fact_id = int(state.get("last_fact_id", -1))
	_last_day = int(state.get("last_day", -1))
	_sequence = maxi(1, int(state.get("sequence", 1)))
	_pending_ai.assign(state.get("pending_ai", []).duplicate(true))
	_pending_independence.assign(state.get("pending_independence", []).duplicate(true))
	_pending_stage_checks.assign(state.get("pending_stage_checks", []).duplicate(true))
	_needs_player_recovery = bool(state.get("needs_player_recovery", true))
	return {"ok": true}


# ─── facts ────────────────────────────────────────────────────────────────

func _poll_facts(player_stages: Dictionary) -> void:
	if _generator == null or not _generator.has_method("get_gameplay_event_bus"):
		return
	var bus = _generator.get_gameplay_event_bus()
	if bus == null or not bus.is_available():
		return
	var batch: Dictionary = bus.poll_events(CONSUMER_ID, 0,
		GameplayEventBusScript.EVENT_STRATUM_MOBILIZATION, false, _last_fact_id)
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
		if cell < 0 or profession < 0:
			continue
		var summary: Dictionary = _country.cell_summary(cell) if _country != null else {}
		var owner_handle := int(summary.get("country_handle", 0))
		if owner_handle == 0 or int(summary.get("country_slot", -1)) != country_slot:
			continue
		if (flag_bits & FLAG_INDEPENDENCE) != 0:
			if not _needs_player_recovery or (_row_flags(cell, profession) & FLAG_INDEPENDENCE) != 0:
				_queue_independence(cell, owner_handle)
			continue
		if owner_handle == _player_handle and not _needs_player_recovery:
			if (flag_bits & FLAG_CAPITAL) == 0 and stage > previous:
				player_stages[Vector2i(cell, profession)] = stage
		# AI facts need no service action: native auto-resolves the stage and the
		# independence bit was already queued by the branch above.


# ─── player chain ─────────────────────────────────────────────────────────

func _row_flags(cell: int, profession: int) -> int:
	if _economy == null or not _economy.is_configured():
		return 0
	var snapshot: Dictionary = _economy.cell_mobilization_snapshot(cell)
	for row in snapshot.get("rows", []):
		if int(row.get("profession", -1)) == profession:
			return int(row.get("flags", 0))
	return 0


func _recover_player_unrest(day: int, player_stages: Dictionary) -> void:
	if _country == null or _economy == null or not _economy.is_configured() \
			or _player_handle <= 0:
		return
	var country: Dictionary = _country.snapshot(_player_handle)
	if not bool(country.get("ok", false)):
		return
	var complete := true
	var capital := int(country.get("capital_cell", -1))
	for cell in country.get("territory_cells", PackedInt32Array()):
		if cell == capital:
			continue
		var snapshot: Dictionary = _economy.cell_mobilization_snapshot(cell)
		if not bool(snapshot.get("ok", false)):
			complete = false
			continue
		for row in snapshot.get("rows", []):
			var profession := int(row.get("profession", -1))
			var stage := int(row.get("stage", 0))
			if (int(row.get("flags", 0)) & FLAG_INDEPENDENCE) != 0:
				_queue_independence(cell, _player_handle)
			elif stage > 0 and profession >= 0 and int(row.get("cooldown_until_day", -1)) <= day:
				player_stages[Vector2i(cell, profession)] = stage
	_needs_player_recovery = not complete


func _process_stage_checks(player_stages: Dictionary) -> void:
	if _pending_stage_checks.is_empty() or _country == null or _economy == null:
		return
	var checks := _pending_stage_checks
	_pending_stage_checks = []
	for check in checks:
		var cell := int(check["cell"])
		var owner := int(check["owner_handle"])
		var summary: Dictionary = _country.cell_summary(cell)
		if owner != _player_handle or owner != int(summary.get("country_handle", 0)):
			continue
		var snapshot: Dictionary = _economy.cell_mobilization_snapshot(cell)
		if not bool(snapshot.get("ok", false)):
			_pending_stage_checks.append(check)
			continue
		var profession := int(check["profession"])
		for row in snapshot.get("rows", []):
			if int(row.get("profession", -1)) != profession:
				continue
			var stage := int(row.get("stage", 0))
			if (int(row.get("flags", 0)) & FLAG_INDEPENDENCE) != 0:
				_queue_independence(cell, owner)
			elif stage > int(check["stage"]):
				player_stages[Vector2i(cell, profession)] = stage
			else:
				# The committed view can still precede the player's decision.
				_pending_stage_checks.append(check)
			break


func _offer_player(cell: int, profession: int, stage: int,
		owner_handle: int, day: int) -> void:
	if _narrative == null or _economy == null or not _economy.is_configured():
		return
	var chain_id := StringName("rebellion:%d:%d" % [cell, profession])
	var offers: Array = _narrative.ready_queue()
	offers.append(_narrative.active_offer(false))
	for offer in offers:
		if StringName(offer.get("chain_id", "")) == chain_id \
				and int(offer.get("meta", {}).get("stage", 0)) == stage:
			return
	var actions: Array = RebellionContentScript.actions_for_stage(stage)
	var settlement: String = _economy.settlement_display_name(cell)
	if settlement.is_empty():
		settlement = "本地"
	var profession_name := _profession_name(profession)
	var profession_key := ""
	var ids: PackedStringArray = _economy.profession_ids()
	if profession >= 0 and profession < ids.size():
		profession_key = String(ids[profession])
	var def = RebellionContentScript.build(
		stage, profession_name, settlement, actions, profession_key)
	var chain_salt := int(NarrativeRngScript.hash64(
		_world_seed, day, _player_handle, cell, profession * 31 + stage) & 0x7fffffff)
	var meta := {
		"kind": "rebellion",
		"cell": cell,
		"profession": profession,
		"stage": stage,
		"owner_handle": owner_handle,
		"actions": actions,
	}
	_narrative.enqueue_event_offer(
		def, cell, day, chain_id,
		true, {"settlement_name": settlement}, {}, chain_salt, meta)


func prepare_player_offer(offer: Dictionary) -> bool:
	if _country == null or _economy == null or not _economy.is_configured():
		return false
	var meta: Dictionary = offer["meta"]
	var cell := int(meta["cell"])
	var profession := int(meta["profession"])
	var stage := int(meta["stage"])
	var owner := int(meta["owner_handle"])
	var cell_summary: Dictionary = _country.cell_summary(cell)
	var options: Array = offer["options"]
	var actions: Array = meta["actions"]
	var baseline: Dictionary = _economy.mobilization_odds(cell, profession, int(actions[0]), 0)
	if baseline.get("busy", false):
		return false
	for index in range(options.size()):
		options[index]["text"] = RebellionContentScript.option_text(stage, int(actions[index]))
	if (owner != _player_handle or owner != int(cell_summary.get("country_handle", 0))
			or not baseline.get("ok", false) or int(baseline.get("stage", stage)) != stage):
		meta["rebellion_obsolete"] = true
		for option: Dictionary in options:
			option["outcomes"] = [_obsolete_outcome()]
			option["tooltip_hint"] = ""
		offer["stratum_choices_prepared"] = true
		return true

	var country_snapshot: Dictionary = _country.snapshot(owner)
	var secession_possible := _can_secede(cell, owner, country_snapshot)
	var cost_bp := int(baseline.get("cost_bp", 0))
	# Only concession and bribery pay the existing treasury expense. Both roll
	# with the same commitment that is handed to the native settlement command.
	var treasury := maxi(0, int(country_snapshot.get("cash", 0)))
	@warning_ignore("integer_division")
	var amount := (treasury / 10000) * cost_bp + (treasury % 10000) * cost_bp / 10000
	var cohort := 0
	if stage < 4 and amount > 0:
		var population: Dictionary = _economy.population_cell_snapshot(cell, true)
		if population.get("busy", false):
			return false
		cohort = _primary_cohort(population)
	for index in range(options.size()):
		var action := int(actions[index])
		var option: Dictionary = options[index]
		var paid := cohort != 0 and action in [RebellionContentScript.ACTION_CONCEDE,
			RebellionContentScript.ACTION_BRIBE]
		var cash := amount if paid else 0
		var p := 0
		if action == RebellionContentScript.ACTION_ABANDON:
			p = 65536
			option["eligible"] = secession_possible
			option["ineligible_reason"] = "首都或仅存的一座城不能放弃。" if not secession_possible else ""
		elif action != RebellionContentScript.ACTION_IGNORE:
			var odds := baseline
			if index != 0 or paid:
				odds = _economy.mobilization_odds(cell, profession, action, cost_bp if paid else 0)
			if not odds.get("ok", false):
				return false
			p = clampi(int(odds["p_success_q16"]), 0, 65536)
		var branches: Array[Dictionary] = []
		if p > 0:
			branches.append(RebellionContentScript.outcome(true, stage, action, p, cash,
				action == RebellionContentScript.ACTION_ABANDON and secession_possible))
		if p < 65536:
			var secession := secession_possible and (stage == 4
				or (stage == 3 and action == RebellionContentScript.ACTION_REPRESS))
			branches.append(RebellionContentScript.outcome(false, stage, action, 65536 - p, cash, secession))
		option["outcomes"] = branches
		option["rebellion_cash"] = cash
		option["rebellion_cohort"] = cohort if paid else 0
		option["tooltip_hint"] = RebellionContentScript.tooltip(action, paid)
	offer["stratum_choices_prepared"] = true
	return true


func _can_secede(cell: int, owner: int, country_snapshot: Dictionary = {}) -> bool:
	if country_snapshot.is_empty():
		country_snapshot = _country.snapshot(owner)
	return (int(country_snapshot.get("territory_count", 0)) > 1
		and int(country_snapshot.get("capital_cell", -1)) != cell)


static func _primary_cohort(snapshot: Dictionary) -> int:
	var handles: PackedInt64Array = snapshot.get("handles", PackedInt64Array())
	var populations: PackedInt64Array = snapshot.get("populations", PackedInt64Array())
	var best := 0
	var best_pop := 0
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


