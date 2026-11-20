extends RefCounted

const DAYS := 80
const TREATY_DAY := 56
const MARCH_TARGET := 4064
const WAR_DECLARED := 40
const CONTROL_CHANGED := 43
const MILITARY_SOURCE := 5
const ASSAULT_STANCE := 2

var economy: EconomyFacade
var ext: DCWorldExt
var commands: Array = []
var evidence := {
	"recruited_heads": 0, "field_heads": 0, "unexplored_entries": 0,
	"trail_days": 0, "field_ration_days": 0, "control_changes": 0,
	"control_days_with_vision": 0, "vision_observation_days": 0,
	"species_observation_days": 0, "military_facts_ingested": 0,
	"production_introduction_days": 0, "production_introductions_consumed": 0,
	"new_occupancy_from_production": 0,
}

var _host: WorldRuntimeHost
var _check: Callable
var _military
var _country
var _map: MapData
var _capital: int
var _player: int
var _enemy := 0
var _militia: int
var _army := 0
var _march_target := -1
var _explored_before_orders := PackedByteArray()
var _prior_species: PackedInt32Array
var _prior_ration := -1
var _prior_fact_id := 0
var _fact_ids := PackedInt64Array()
var _sequence := 920000


func _init(host: WorldRuntimeHost, check: Callable, restored_day: int = 0) -> void:
	_host = host
	_check = check
	var generator := host.get_generator()
	economy = generator.get_economy_facade()
	ext = economy.world_ext()
	_military = generator.get_military_facade()
	_country = generator.get_country_facade()
	_map = host.current_map()
	_capital = int(generator.gameplay_start_report().get("cell", -1))
	_player = int(ext.get_country_cell_summary(_capital).get("country_handle", 0))
	_militia = _military.unit_ids().find("militia")
	if restored_day >= 23:
		_march_target = MARCH_TARGET
	var armies: Array = _military.armies(_player)
	if not armies.is_empty():
		_army = int(armies[0].handle)
	for cell in _map.cell_count():
		if _map.country_slot_arr[cell] > 0:
			_enemy = int(ext.get_country_cell_summary(cell).get("country_handle", 0))
			if _enemy != 0:
				break
	_prior_species = _map.bio_occupancy_bits_arr.duplicate()
	economy.construction_command_settled.connect(_print_construction)
	_host.simulation_committed.connect(_issue_military_on_boundary)


func _print_construction(receipt: Dictionary) -> void:
	if int(receipt.get("sequence", -1)) > 920000:
		print("BACKGROUND_MILITARY_CONSTRUCTION=" + JSON.stringify(receipt))


func ready() -> bool:
	var valid := _capital >= 0 and _militia >= 0 and _player > 0 and _enemy > 0
	_check.call("military scenario opens with a player, a militia unit and a foreign country", valid)
	return valid


func issue_for_day(day: int) -> void:
	match day:
		1:
			for tech in [&"tech.military.war_bands", &"tech.wild_flax_collection",
					&"tech.herd_management"]:
				_sequence += 1
				var grant: Dictionary = _country.grant_technology(_player, tech, 2, _sequence, true)
				_record(grant, {"op": "grant", "country": _player, "tech": tech,
					"effective_day": 2, "sequence": _sequence})
		4:
			_build(&"warrior_lodge", day + 1)
			_build(&"bast_fiber_camp", day + 1)
			_build(&"pastoral_camp", day + 1)
			# With this seed, bast fiber reaches 1810 in the first diffusion.
			_transfer(1810, _player, day + 1)
		12:
			# The second diffusion establishes maize here. Claim it early so
			# the species observation can use yesterday's territory eligibility.
			_transfer(2287, _player, day + 1)
		23:
			_march_target = _find_march_target()
			_check.call("march route has unexplored land and reaches the fixture destination",
				_march_target == MARCH_TARGET)
			if _march_target >= 0:
				_transfer(_march_target, _enemy, day + 1)
		29, 36, 43, 50:
			# Exercise additional discoveries away from the march as well.
			for cell in _map.cell_count():
				if cell != _march_target and _map.is_water_arr[cell] == 0 \
						and _map.country_slot_arr[cell] < 0 and _map.physical_visible_arr[cell] == 0 \
						and _map.cell_research_signal_offsets[cell + 1] > _map.cell_research_signal_offsets[cell]:
					_transfer(cell, _player, day + 1)
					break


# Submit while the previous day's notification is being delivered. At that
# point both the old military formula and the Country seal target this day.
func _issue_military_on_boundary(_from_day: int, finished_day: int, _generation: int) -> void:
	var day := finished_day + 1
	match day:
		6:
			var state_building: int = _military.state_building_ids().find("warrior_lodge")
			_record(_military.build_state_building(_player, _capital, state_building),
				{"op": "military.build", "cell": _capital, "building": state_building, "effective_day": day})
			_record(_military.set_levy_enabled(_player, true),
				{"op": "military.levy", "country": _player, "effective_day": day})
			_record(_military.set_target(_player, 0, 4),
				{"op": "military.target", "country": _player, "mode": 0, "value": 4, "effective_day": day})
		20:
			_record(_military.create_army(_player, _capital, {_militia: 4}),
				{"op": "military.create_army", "cell": _capital, "unit": _militia, "heads": 4,
					"effective_day": day})
		23:
			_record(_military.declare_war_forced(_player, _enemy),
				{"op": "military.declare_war", "country": _player, "enemy": _enemy, "effective_day": day})
		25:
			if _march_target >= 0:
				var route: Dictionary = _military.preview_path(_army, _march_target)
				var cells: PackedInt32Array = route.get("cells", PackedInt32Array())
				# The target is enemy land. Explore the neutral approach first.
				var approach := cells[cells.size() - 2] if cells.size() >= 2 else -1
				if approach >= 0:
					_explored_before_orders = _map.explored_arr.duplicate()
					_record(_military.explore_army(_army, approach, PackedInt32Array([approach]), 1),
						{"op": "military.explore", "army": _army, "cell": approach, "effective_day": day})
		39:
			if _march_target >= 0:
				_record(_military.move_army(_army, _march_target),
					{"op": "military.move", "army": _army, "cell": _march_target, "effective_day": day})
				_record(_military.submit([{"op": "army.stance", "army": _army, "count": ASSAULT_STANCE}]),
					{"op": "military.stance", "army": _army, "stance": ASSAULT_STANCE, "effective_day": day})
		TREATY_DAY:
			var wars: Array = _military.country_snapshot(_player).get("wars", [])
			_check.call("the peace treaty cedes an enemy-owned cell", not wars.is_empty()
				and int(ext.get_country_cell_summary(_march_target).get("country_handle", 0)) == _enemy)
			if not wars.is_empty():
				var treaty := {"op": "peace.respond", "country": _player, "other": int(wars[0].war_id),
					"count": 1, "terms": [{"kind": "cede", "cell": _march_target}]}
				_record(_military.submit([treaty]), treaty.merged({"effective_day": day}))


func _build(id: StringName, effective_day: int) -> void:
	var profile: Resource = load("res://data/economy/buildings/%s.tres" % id)
	var market_id := int(economy.market_cell_snapshot(_capital).get("market_id", -1))
	var good_ids := economy.good_ids()
	for index in profile.construction_good_ids.size():
		var good := good_ids.find(profile.construction_good_ids[index])
		var amount := int(profile.construction_quantities[index])
		_sequence += 1
		_record(ext.submit_economy_pod_commands({
			"request_ids": PackedInt64Array([_sequence]),
			"opcodes": PackedInt32Array([EconomyFacade.Opcode.ADD_STOCK]),
			"payload0s": PackedInt64Array([amount]),
			"target_cells": PackedInt32Array([market_id]),
			"target_countries": PackedInt64Array([good]),
		}), {"op": "add_construction_stock", "market": market_id, "good": good, "amount": amount,
			"effective_day": effective_day, "sequence": _sequence})
	_sequence += 1
	_record(economy.treasury_sponsored_build(_player, _capital, id, effective_day, _sequence),
		{"op": "build", "cell": _capital, "building": id, "effective_day": effective_day,
			"sequence": _sequence})


func _transfer(cell: int, country: int, day: int) -> void:
	_sequence += 1
	_record(_country.transfer_territory(cell, country, day, _sequence, true),
		{"op": "transfer", "cell": cell, "country": country, "effective_day": day, "sequence": _sequence})


func _record(receipt: Dictionary, command: Dictionary) -> void:
	_check.call("military scenario admitted %s: %s" % [command.op, receipt], bool(receipt.get("ok", false)))
	if String(command.op).begins_with("military.") or receipt.has("effective_day"):
		_check.call("military scenario kept the effective day for %s" % command.op,
			int(receipt.get("effective_day", -1)) == int(command.effective_day))
	commands.append(command)


func _find_march_target() -> int:
	if _army == 0:
		return -1
	var origin := HexUtils.offset_to_cube(_capital % _map.width, _capital / _map.width)
	for cell in _map.cell_count():
		if _map.is_water_arr[cell] != 0 or _map.country_slot_arr[cell] >= 0 or _map.explored_arr[cell] != 0:
			continue
		var distance := HexUtils.cube_distance(origin,
			HexUtils.offset_to_cube(cell % _map.width, cell / _map.width))
		if distance < 4 or distance > 7:
			continue
		var route: Dictionary = _military.preview_path(_army, cell)
		if not bool(route.get("ok", false)):
			continue
		for step in route.cells:
			if step != cell and _map.explored_arr[step] == 0:
				return cell
	return -1


func collect_day(day: int) -> void:
	var forces: Dictionary = _military.country_snapshot(_player)
	evidence.recruited_heads = maxi(evidence.recruited_heads, int(forces.get("soldiers_total", 0)))
	evidence.field_heads = maxi(evidence.field_heads, int(forces.get("soldiers_in_armies", 0)))
	var armies: Array = _military.armies(_player)
	if not armies.is_empty():
		_army = int(armies[0].handle)
		var army: Dictionary = _military.army(_army)
		var cell := int(army.cell)
		if int(army.moved_day) == day and not _explored_before_orders.is_empty() \
				and _explored_before_orders[cell] == 0 and _map.explored_arr[cell] != 0:
			evidence.unexplored_entries += 1
		var ration := int(army.ration_ratio_q16)
		if cell != _capital and int(army.lane_population) > 0 and ration != _prior_ration:
			evidence.field_ration_days += 1
		_prior_ration = ration
		var consumed := int(_military.report().get("ledger_consumed", 0))
		if day in [20, 23, 26, 27, 30, 35, 42, 50, 64]:
			print("BACKGROUND_MILITARY_MOVEMENT=" + JSON.stringify({
				"day": day, "cell": cell, "mission": army.mission, "path": army.path,
				"target": _march_target, "points": army.move_points_q16,
				"organization": army.organization_q16, "ration": ration,
				"stock": army.ration_stock, "lane_heads": army.lane_population,
				"ledger_consumed": consumed, "pending": _military.report().get("pending_intents"),
				"engagement": army.engagement,
			}))
	var commit: Dictionary = _host._runtime_last_commit
	evidence.trail_days += int(int(commit.get("military_trail_cells", 0)) > 0)
	evidence.vision_observation_days += int(int(commit.get("vision_observations", 0)) > 0)
	evidence.species_observation_days += int(int(commit.get("species_observations", 0)) > 0)
	for event in _military.poll_events(_prior_fact_id):
		_prior_fact_id = int(event.id)
		if int(event.type) == CONTROL_CHANGED:
			evidence.control_changes += 1
			if bool(commit.get("vision_solved", false)):
				evidence.control_days_with_vision += 1
	if day == TREATY_DAY + 1:
		var ceded := int(ext.get_country_cell_summary(_march_target).get("country_handle", 0)) == _player
		evidence.control_changes += int(ceded)
		evidence.control_days_with_vision += int(ceded and bool(commit.get("vision_solved", false))
			and _map.physical_visible_arr[_march_target] != 0)
	var batch: Dictionary = ext.poll_gameplay_events({"type": WAR_DECLARED, "after_event_id": 0})
	for index in int(batch.get("count", 0)):
		if int(batch.source[index]) == MILITARY_SOURCE and not _fact_ids.has(batch.event_id[index]):
			_fact_ids.append(batch.event_id[index])
	var cursors: Array = ext.get_trigger_report().get("source_cursors", [])
	if cursors.size() > MILITARY_SOURCE:
		evidence.military_facts_ingested = 0
		for id in _fact_ids:
			evidence.military_facts_ingested += int(id <= int(cursors[MILITARY_SOURCE]))
	# Between diffusion days occupancy can only gain bits through Economy's
	# introduction batch. Count genuinely newly occupied production sites.
	if day % 8 != 0 and (_map.bio_occupancy_bits_arr[_capital] & ~_prior_species[_capital]) != 0:
		evidence.new_occupancy_from_production += 1
	_prior_species = _map.bio_occupancy_bits_arr.duplicate()
	if day >= 15:
		var ledger := economy.building_cell_snapshot(_capital)
		var introduction := false
		for row in ledger.group_type_ids.size():
			var id: String = ledger.building_type_ids[ledger.group_type_ids[row]]
			if id in ["bast_fiber_camp", "pastoral_camp"]:
				introduction = introduction or (int(ledger.state_day) == day and int(ledger.last_output[row]) > 0)
		# Require the Economy output and its native introduction drain on the
		# same day. Habitat checks may reject an introduction after the drain.
		evidence.production_introduction_days += int(introduction)
		if introduction:
			evidence.production_introductions_consumed += int(
				_host._runtime_last_commit.get("species_introductions_consumed", 0))


func check_coverage() -> void:
	for label in evidence:
		if label == "new_occupancy_from_production":
			continue
		var minimum := 2 if String(label).ends_with("observation_days") else 1
		_check.call("military scenario coverage %s >= %d (actual %d)" % [
			label, minimum, evidence[label]], int(evidence[label]) >= minimum)


static func settle_clock_day(host: WorldRuntimeHost, clock: WorldClock,
		tree: SceneTree, day: int) -> bool:
	clock.current_day = float(day + 1)
	host._on_clock_day_changed(day + 1)
	var deadline := Time.get_ticks_usec() + 60000000
	while Time.get_ticks_usec() < deadline:
		host._process(0.0)
		var status := host.get_generator().get_runtime_control_state()
		if status.get("simulation_host_state") == "FAULTED":
			return false
		if host._runtime_commit_day == day and int(status.get("simulation_committed_day", -1)) == day:
			return true
		await tree.process_frame
	return false


static func stop_at_committed_day(host: WorldRuntimeHost, tree: SceneTree) -> bool:
	var generator := host.get_generator()
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		var report := generator.get_runtime_thread_report()
		if int(report.get("worker_day_inflight", 0)) == 0:
			break
		await tree.process_frame
	if Time.get_ticks_msec() >= deadline:
		return false
	if not bool(generator.request_runtime_stop(true).get("ok", false)):
		return false
	while Time.get_ticks_msec() < deadline:
		if bool(generator.get_runtime_control_state().get("simulation_executor_exited", false)):
			return true
		await tree.process_frame
	return false
