# military_runtime_smoke_test.gd
# Headless full-world military smoke test:
#   godot --headless --path . -s res://tests/military/military_runtime_smoke_test.gd
#
# Boots a real formal-start world through WorldRuntimeHost (same driver as
# tests/game/headless_perf_record.gd), then as the player country: sets a
# headcount target, builds barracks at the capital, advances ~60 days, creates
# an army, picks a foreign target (adjacent if any, else nearest foreign cell),
# declares war, moves the army and advances to 120 days. Asserts no script
# errors, non-negative report counters, soldiers > 0 after recruitment, and a
# PKMI encode -> restore -> state_hash round trip. Prints SKIP and exits 0 when
# the military bindings are missing.
extends SceneTree

const SEED := 20260727
const MAP_W := 60
const MAP_H := 40
const FOREIGN_COUNT := 3
const RECRUIT_DAYS := 60
const WARMUP_DAYS := 6
const TOTAL_DAYS := 120
const TARGET_HEADCOUNT := 12
const BARRACKS_TO_BUILD := 3
const PIPELINE_DEPTH := 3
const MAX_BARRIER_PULSES_PER_DAY := 4096

## Report keys that are counters and must never be negative.
const COUNTER_KEYS := ["armies_active", "armies_moving", "engagements_active",
	"wars_active", "soldiers_total", "astar_expansions", "area_evals",
	"threat_field_cells", "convoys_due", "convoy_hops", "front_edges_touched",
	"vision_patch_cells", "event_coalesced", "intents_emitted", "pending_intents",
	"sequence_cursor", "ledger_received", "ledger_consumed", "ledger_stock",
	"ledger_transit"]


class ErrorCounter extends Logger:
	var errors := PackedStringArray()
	var _mutex := Mutex.new()

	func _log_error(function: String, file: String, line: int, code: String,
			rationale: String, _editor_notify: bool, error_type: int,
			_script_backtrace: Array[ScriptBacktrace]) -> void:
		# error_type 1 = warning; everything else (error / script / shader) counts.
		if error_type == 1:
			return
		_mutex.lock()
		errors.append("%s:%d %s %s %s" % [file, line, function, code, rationale])
		_mutex.unlock()

	func _log_message(_message: String, _error: bool) -> void:
		pass


var _failures := PackedStringArray()
var _logger: ErrorCounter = null
var _clock: WorldClock = null
var _host: WorldRuntimeHost = null
var _day := 0


func _init() -> void:
	# Nodes added during SceneTree._init are not inside the tree yet, and
	# WorldRuntimeHost.generate_world bails out when !is_inside_tree().
	await process_frame
	var code: int = await _run()
	if _logger != null:
		OS.remove_logger(_logger)
	quit(code)


func _run() -> int:
	if not ClassDB.class_exists("DCWorldExt"):
		print("SKIP DCWorldExt unavailable")
		return 0
	var probe = ClassDB.instantiate("DCWorldExt")
	if probe == null or not probe.has_method("configure_military") \
			or not probe.has_method("run_military_daily"):
		print("SKIP military bindings missing in loaded dots_ext")
		return 0
	probe = null
	if ClassDB.class_exists("Logger"):
		_logger = ErrorCounter.new()
		OS.add_logger(_logger)

	_clock = WorldClock.new()
	_clock.auto_start = false
	_clock.initial_speed = 50.0
	_clock.debug_step_log = false
	get_root().add_child(_clock)
	_clock.set_speed(50.0)
	_clock.pause(true)
	_host = WorldRuntimeHost.new()
	_host.map_width = MAP_W
	_host.map_height = MAP_H
	_host.initial_seed = SEED
	get_root().add_child(_host)
	_host.configure(null, null, _clock)
	var config := NewGameConfig.create_default()
	config.country.name = "Military Smoke"
	config.country.foreign_count = FOREIGN_COUNT
	config.base.map_width = MAP_W
	config.base.map_height = MAP_H
	config.base.initial_seed = SEED
	var session: Dictionary = _host.configure_session({
		"kind": "new_game", "config": config.to_dictionary()})
	_expect("formal session configured", bool(session.get("ok", false)), str(session))
	await _host.generate_world(SEED)
	var map: MapData = _host.get_current_map()
	var generator := _host.get_generator()
	_expect("world generated", map != null and generator != null)
	if map == null or generator == null:
		return _finish()
	var runtime_ext = generator.get_data_core_world_ext() \
		if generator.has_method("get_data_core_world_ext") else null
	if _host.runtime_climate_authority_enabled and runtime_ext != null \
			and runtime_ext.has_method("set_runtime_clock"):
		runtime_ext.set_runtime_clock(false, 50.0)

	var facade = generator.get_military_facade() \
		if generator.has_method("get_military_facade") else null
	_expect("map_generator.get_military_facade() is configured",
		facade != null and facade.is_configured(),
		"" if facade == null else str(facade.configure_result()))
	if facade == null or not facade.is_configured():
		return _finish()
	_expect("military terrain pushed", facade.terrain_ready())
	var country = generator.get_country_facade()
	var start: Dictionary = generator.gameplay_start_report()
	var capital := int(start.get("cell", -1))
	var player := int(country.cell_summary(capital).get("country_handle", 0))
	_expect("player country resolved", capital >= 0 and player != 0,
		"cell=%d handle=%d" % [capital, player])
	if player == 0:
		return _finish()
	print("[military-smoke] graph_active=%s capital=%d player=%d" % [
		str(generator.runtime_graph_active()), capital, player])

	# Native gap: MilitaryCore opens a country slot only inside
	# capture_military_digest (first run_military_daily), so commands submitted
	# before the first military day are rejected with command_unknown_country.
	# Probe that once, then warm up until the slot exists.
	var early: Dictionary = facade.set_target(player, 0, TARGET_HEADCOUNT)
	print("[military-smoke] pre-first-step set_target=%s" % JSON.stringify(early))
	await _advance_to(WARMUP_DAYS)
	_print_progress("warmup")
	_expect("player military slot opened after warmup",
		bool(facade.country_snapshot(player).get("ok", false)),
		str(facade.country_snapshot(player).get("reason", "")))

	# --- force target + barracks (first barracks row of the catalog) ---
	# Two production facts this test has to follow:
	#  1. every shipped barracks carries a gate technology, so there is no
	#     "tech-free barracks" to select any more;
	#  2. `state.build` alone no longer builds: the economy bills the real
	#     materials through `treasury_sponsored_build` (which refuses with
	#     `construction_technology_locked` until the country holds the gate tech)
	#     and only then does `state.build` book the core's construction cache.
	# The old single-call path therefore built nothing at all.
	var econ_for_build = generator.get_economy_facade() \
		if generator.has_method("get_economy_facade") else null
	var barracks := _barracks_index(facade.catalog())
	_expect("catalog has a barracks row", barracks >= 0)
	var target: Dictionary = facade.set_target(player, 0, TARGET_HEADCOUNT)
	_expect("force.set_target accepted", bool(target.get("ok", false)), str(target))
	if barracks >= 0 and econ_for_build != null:
		var rows: Array = facade.catalog().get("state_buildings", [])
		var tech := String((rows[barracks] as Dictionary).get("unlock_tech_id", ""))
		if not tech.is_empty():
			var granted: Dictionary = country.grant_technology(player, StringName(tech),
				_day + 1, _day * 1000 + 1)
			print("[military-smoke] gate tech %s -> %s" % [tech,
				JSON.stringify(_compact(granted))])
		var econ_id := int(facade.state_building_economy_id(barracks))
		var type_ids: PackedStringArray = econ_for_build.building_type_ids()
		for _i in range(BARRACKS_TO_BUILD):
			if econ_id < 0 or econ_id >= type_ids.size():
				_expect("state building resolves to an economy type", false,
					"id=%d" % econ_id)
				break
			var sponsored: Dictionary = econ_for_build.treasury_sponsored_build(
				player, capital, StringName(type_ids[econ_id]), _day + 1,
				_day * 1000 + 10 + _i)
			var booked: Dictionary = facade.build_state_building(player, capital, barracks)
			_expect("state.build accepted at capital",
				bool(sponsored.get("ok", false)) and bool(booked.get("ok", false)),
				"%s / %s" % [JSON.stringify(_compact(sponsored)),
					JSON.stringify(_compact(booked))])

	await _advance_to(RECRUIT_DAYS)
	_print_progress("recruit")
	var report: Dictionary = facade.report()
	var snapshot: Dictionary = facade.country_snapshot(player)
	print("[military-smoke] day=%d report=%s" % [_day, JSON.stringify(_compact(report))])
	print("[military-smoke] player snapshot soldiers_total=%s posts=%s barracks=%s" % [
		str(snapshot.get("soldiers_total")), str(snapshot.get("post_count")),
		JSON.stringify(snapshot.get("barracks", []))])
	var econ = generator.get_economy_facade() \
		if generator.has_method("get_economy_facade") else null
	var population: Dictionary = econ.population_cell_snapshot(capital) \
		if econ != null else {}
	# Diagnostic: which professions actually hold the capital's people. A move
	# that lands in the wrong signature shows up here as a shifted lane.
	print("[military-smoke] capital population=%s soldier_cohort=%d unemployed=%d" % [
		str(population.get("population", "?")), _profession_population(population, "soldier"),
		_profession_population(population, "unemployed")])
	_expect("military stepped through the recruit window",
		int(report.get("last_step_day", -1)) >= RECRUIT_DAYS - 8,
		"last_step_day=%d" % int(report.get("last_step_day", -1)))
	_expect("barracks completed (posts > 0)", int(snapshot.get("post_count", 0)) > 0,
		str(snapshot.get("post_count")))
	_expect_counters(report, "day %d" % _day)
	_expect("soldiers > 0 after recruitment", int(snapshot.get("soldiers_total", 0)) > 0,
		"soldiers_total=%d pending_intents=%d reconcile_delta=%d" % [
			int(snapshot.get("soldiers_total", 0)), int(report.get("pending_intents", 0)),
			int(report.get("reconcile_delta", 0))])
	# Military lots and the Economy soldier cohort are the same people: a lot
	# without a cohort (or the reverse) means a receipt was reconciled wrongly.
	# The population read comes from the worker's committed view, so it is retried
	# (`_cell_soldiers`): a single busy read reports 0 for every cell.
	var soldier_cohort := await _cell_soldiers(econ, capital)
	_expect("Economy soldier cohort matches the military roster",
		soldier_cohort >= 0 and soldier_cohort == int(snapshot.get("soldiers_total", 0)),
		"economy=%d military=%d" % [soldier_cohort, int(snapshot.get("soldiers_total", 0))])

	# --- army, target country, war, move ---
	# Let the pipeline drain before freezing the recruit quota at the committed
	# baseline. Two things would otherwise move the home cell's
	# soldier cohort between the baseline and the embark: the barracks still has a
	# post open (a new enlistment), and Economy converts a pre-booked enlist intent
	# on its own epoch boundary (a head the roster already counts but the committed
	# cohort shows late). Both would make the drop differ from the embarked count
	# even though the embark itself is exact.
	for _settle in range(4):
		await _advance_to(_day + 3)
		var settled := await _cell_soldiers(econ, capital)
		var settled_snapshot: Dictionary = facade.country_snapshot(player)
		var pending_enlist := 0
		for barracks_row in settled_snapshot.get("barracks", []):
			pending_enlist += int((barracks_row as Dictionary).get("pending_enlist", 0))
		# A rolling Economy read can cross the same D+1 enlist receipt that the
		# Military view has not consumed yet. Freeze only after both committed
		# views agree and the barracks has no enlistment still in flight.
		if settled >= 0 and settled == int(settled_snapshot.get("soldiers_total", -1)) \
				and pending_enlist == 0:
			soldier_cohort = settled
			break
		soldier_cohort = settled
	print("[military-smoke] embark baseline day=%d capital_soldier=%d" % [_day,
		soldier_cohort])
	var frozen: Dictionary = facade.set_target(player, 0,
		int(soldier_cohort))
	_expect("force.set_target freezes the roster before the embark",
		bool(frozen.get("ok", false)), str(frozen))
	var created: Dictionary = facade.create_army(player, capital, {})
	_expect("army.create accepted", bool(created.get("ok", false)), str(created))
	var foreign := _foreign_target(map, country, player)
	print("[military-smoke] foreign target=%s" % JSON.stringify(foreign))
	_expect("a foreign country exists", int(foreign.get("handle", 0)) != 0)
	if int(foreign.get("handle", 0)) != 0:
		var war: Dictionary = facade.declare_war(player, int(foreign.handle))
		_expect("war.declare accepted", bool(war.get("ok", false)), str(war))
	# The formation materialises on the next military day, and its Economy lane row
	# is created by the epoch that applies the embark command, so wait for both
	# instead of assuming a fixed number of days: the whole bridge runs a few days
	# behind the driver and the Economy commits on its own cadence.
	var armies: Array = []
	var army_row: Dictionary = {}
	var handle := 0
	for _wait in range(12):
		armies = facade.armies(player)
		if not armies.is_empty():
			handle = int((armies[0] as Dictionary).get("handle", 0))
			army_row = facade.army(handle)
			# Wait for the lane commit, not just for the intent: personnel counts
			# the in-flight heads too, so breaking on it alone reads the cohort
			# before Economy has moved them (flaky by one epoch).
			if int(army_row.get("personnel", 0)) > 0 \
					and int(army_row.get("personnel_pending", 0)) == 0:
				break
		await _advance_to(_day + 1)
	_expect("player army exists after army.create", not armies.is_empty(),
		"armies=%d" % armies.size())

	# --- army personnel lane: embark (army-personnel contract §2.3) ---
	# army.create boards the capital's soldier lots into the formation, so the home
	# cell's soldier cohort must drop by exactly those heads while the formation's
	# personnel (the Economy lane row, keyed by army handle) grows to the same
	# number. Headcount and lane cannot disagree: they are the same people.
	var army_lane := false
	var embarked := 0
	var personnel_before := -1
	if not armies.is_empty():
		handle = int((armies[0] as Dictionary).get("handle", 0))
		army_row = facade.army(handle)
		army_lane = bool(army_row.get("lane_supported", false))
		embarked = int(army_row.get("headcount", 0))
		var capital_soldiers := await _cell_soldiers(econ, capital)
		var military_after: Dictionary = facade.country_snapshot(player)
		var military_garrisoned := int(military_after.get("soldiers_garrisoned", -1))
		var military_total_after := int(military_after.get("soldiers_total", -1))
		print("[military-smoke] embark day=%d army=%d headcount=%d personnel=%s pending=%s capital_soldier=%d (before create=%d) lane=%s" % [
			_day, handle, embarked, str(army_row.get("personnel", -1)),
			str(army_row.get("personnel_pending", -1)), capital_soldiers, soldier_cohort,
			str(army_lane)])
		_expect("army.create boarded heads into the formation", embarked > 0,
			"headcount=%d" % embarked)
		if army_lane:
			# Economy's selected-cell view is a rolling committed read and may lag
			# the command's effective day. Compare the same post-embark boundary on
			# both sides: the cell cohort must equal Military's remaining garrison,
			# which is the total roster minus the embarked formation.
			_expect("home cell soldier cohort drops by the embarked count",
				capital_soldiers >= 0 and military_garrisoned >= 0 \
					and military_total_after >= embarked \
					and military_garrisoned == military_total_after - embarked \
					and capital_soldiers == military_garrisoned \
					and capital_soldiers == soldier_cohort - embarked,
				"capital=%d baseline=%d military_garrisoned=%d military_total=%d embarked=%d" % [
					capital_soldiers, soldier_cohort, military_garrisoned, military_total_after, embarked])
			_expect("army personnel equals the embarked count",
				int(army_row.get("personnel", -1)) == embarked,
				"personnel=%s headcount=%d" % [str(army_row.get("personnel", -1)),
					embarked])
		else:
			print("[military-smoke] SKIP army personnel lane assertions: the loaded economy has no lane bindings (army_lane_supported=%s)" % str(
				facade.last_daily_report().get("army_lane_supported", false)))

	# --- army pay: the wages follow the people (army-pay contract §4.1) ---
	# The heads are in the formation's Economy lane, so their pay must land there
	# (opcode 34) instead of the garrison cell they left. Three things are checked
	# over a measured window: the lane's cash RISES, the treasury pays exactly the
	# embarked heads x the shared daily wage (no double pay, nothing dropped), and
	# the home cell no longer collects for heads that are not standing on it.
	var pay_baseline := await _pay_window(facade, country, player, handle, econ)
	if bool(pay_baseline.get("ok", false)):
		# The window has to span real military days: the payroll is emitted once per
		# stepped day, so a zero-day window compares a reading with itself.
		const PAY_WINDOW_DAYS := 8
		await _advance_to(_day + PAY_WINDOW_DAYS)
		var pay := await _pay_window(facade, country, player, handle, econ)
		var wage := int(pay_baseline.get("wage", 0))
		var pay_days := int(pay.get("days", 0)) - int(pay_baseline.get("days", 0))
		var heads := int(pay_baseline.get("heads", 0))
		var lane_before := int(pay_baseline.get("lane_funds", 0))
		var lane_after := int(pay.get("lane_funds", 0))
		var cash_out := int(pay_baseline.get("cash", 0)) - int(pay.get("cash", 0))
		var payroll := int(pay.get("payroll_army", 0))
		var expected_payroll := heads * wage
		# Treasury outflow tracks embarked heads x the daily wage. Two things widen
		# the band beyond 10%:
		#   * the LAST day's debit can still be in flight at the read (the peer
		#     settles the treasury side on the committed-day boundary, so an 8-day
		#     window usually shows 7 settled days = one full payroll short);
		#   * other cash movements (procurement, upkeep, tax) share the window.
		# One day of payroll is therefore the real floor of the tolerance, not the
		# 10% noise term.
		var one_day := heads * wage
		var expected := mini(one_day * pay_days, maxi(0, int(pay_baseline.get("cash", 0))))
		var tolerance := maxi(maxi(1, int(expected / 10.0)), one_day)
		print("[military-smoke] army pay day=%d heads=%d wage=%d days=%d lane %d->%d cash_out=%d expected=%d payroll_army=%d payroll_garrison=%d expected_army_pay=%d pay_ratio=%s" % [
			_day, heads, wage, pay_days, lane_before, lane_after, cash_out, expected,
			payroll, int(pay.get("payroll_garrison", 0)), expected_payroll,
			str(pay.get("pay_ratio_q16", -1))])
		_expect("army pay lands in the formation's lane (lane cash rises)",
			pay_days > 0 and lane_after > lane_before,
			"lane %d -> %d over %d days" % [lane_before, lane_after, pay_days])
		_expect("treasury outflow tracks embarked heads x the daily wage",
			expected > 0 and absi(cash_out - expected) <= tolerance,
			"out=%d expected=%d (heads x wage x days, cash-clipped) tol=%d (one day=%d)" % [
				cash_out, expected, tolerance, one_day])
		# The ARMY share of the day's payroll is the embarked heads' pay and
		# nothing else: if the home cell still collected for them the army rows
		# would be empty and this would be zero; if both paid, it would be double.
		var payroll_tolerance := maxi(1, int(expected_payroll / 10.0))
		_expect("garrison pay no longer covers the embarked heads",
			expected_payroll > 0 and absi(payroll - expected_payroll) <= payroll_tolerance,
			"payroll_army=%d expected=%d (heads x wage) tol=%d garrison_share=%d" % [
				payroll, expected_payroll, payroll_tolerance,
				int(pay.get("payroll_garrison", 0))])
	else:
		print("[military-smoke] SKIP army pay assertions: %s" % str(pay_baseline.get("reason", "")))

	if handle != 0:
		# The march target is the foreign cell when the formation can actually walk
		# there; on a seed where that country has no land bridge the path tool says
		# so and the march assertions would be vacuous (the formation never moves),
		# so fall back to the farthest land cell a few steps from the capital.
		var march_cell := int(foreign.get("cell", -1))
		var preview: Dictionary = facade.preview_path(handle, march_cell) \
			if march_cell >= 0 else {"ok": false}
		if not bool(preview.get("ok", false)):
			march_cell = _land_cell_within(map, capital, 4)
			preview = facade.preview_path(handle, march_cell) if march_cell >= 0 \
				else {"ok": false}
		print("[military-smoke] preview_path=%s" % JSON.stringify(_compact(preview)))
		# --- army personnel lane: a march moves lots, never people (§5.7) ---
		# The formation keeps its personnel while its ration store drains: people
		# consume from army stock wherever the formation happens to stand.
		var before_move: Dictionary = facade.army(handle)
		personnel_before = int(before_move.get("personnel", -1))
		var ration_before := int(before_move.get("ration_stock", 0))
		var cell_before := int(before_move.get("cell", -1))
		var moved: Dictionary = facade.move_army(handle, march_cell)
		_expect("army.move accepted", bool(moved.get("ok", false)), str(moved))
		await _advance_to(_day + 6)
		var after_move: Dictionary = facade.army(handle)
		var personnel_after := int(after_move.get("personnel", -1))
		var ration_after := int(after_move.get("ration_stock", 0))
		var cell_after := int(after_move.get("cell", -1))
		print("[military-smoke] march day=%d cell %d->%d (target %d) personnel %d->%d ration %d->%d" % [
			_day, cell_before, cell_after, march_cell, personnel_before, personnel_after,
			ration_before, ration_after])
		if before_move.has("personnel"):
			_expect("army personnel is unchanged by a march",
				personnel_before > 0 and personnel_after == personnel_before,
				"%d -> %d" % [personnel_before, personnel_after])
		else:
			print("[military-smoke] SKIP march personnel assertion: get_military_army has no personnel field (older DLL)")
		if army_lane and ration_before > 0:
			_expect("army ration stock falls while marching", ration_after < ration_before,
				"%d -> %d" % [ration_before, ration_after])
		else:
			print("[military-smoke] SKIP ration-stock assertion (lane=%s stock=%d)" % [
				str(army_lane), ration_before])
		# --- army personnel lane: split / transfer move people with the lots ---
		# Contract-2 §1.2: army.split boards the moved lots into a new formation and
		# those heads leave the source lane for the new one (Economy opcode 33). The
		# conserved quantity is the SUM over both formations: the people are the same
		# people, they just changed book. The same rule holds for army.transfer —
		# a partial transfer moves the heads that left (33), the whole formation
		# folds its lane into the receiver (32, army.merge semantics).
		var detached := 0
		var lane_baseline := 0
		# Gate on the loaded economy build: without opcode 33 the split still moves
		# the lots but the lanes stay put, so these assertions would fail by design
		# on an older DLL. `army_split_lane_supported` is the bridge's own probe.
		var split_lane := bool(facade.last_daily_report().get(
			"army_split_lane_supported", false))
		if army_lane and split_lane and personnel_after > 0:
			var parent_row: Dictionary = facade.army(handle)
			lane_baseline = int(parent_row.get("personnel", personnel_after))
			var headcount_baseline := int(parent_row.get("headcount", 0))
			var split_unit := -1
			var split_heads := 0
			var composition: Array = parent_row.get("composition", [])
			for row in composition:
				var unit_id := int((row as Dictionary).get("unit", -1))
				var unit_heads := int((row as Dictionary).get("count", 0))
				if unit_id < 0 or unit_heads < 2:
					continue
				split_unit = unit_id
				split_heads = maxi(1, int(unit_heads / 3.0))
				if split_heads >= unit_heads:
					split_heads = unit_heads - 1
				break
			if split_unit >= 0 and split_heads > 0:
				var split_result: Dictionary = facade.submit([{"op": "army.split",
					"country": player, "army": handle,
					"units": {split_unit: split_heads}}])
				_expect("army.split accepted", bool(split_result.get("ok", false)),
					str(split_result))
				# The formation and its lane row appear on their own days, so wait
				# for both instead of assuming a fixed delay (same contract as the
				# embark above).
				for _wait in range(10):
					await _advance_to(_day + 2)
					detached = _other_army(facade.armies(player), handle)
					if detached != 0 \
							and int(facade.army(detached).get("personnel", 0)) > 0:
						break
				_expect("army.split created a second formation", detached != 0,
					"armies=%d" % facade.armies(player).size())
			else:
				print("[military-smoke] SKIP split assertion: no multi-head unit in the composition")
			if detached != 0:
				var split_parent: Dictionary = facade.army(handle)
				var split_child: Dictionary = facade.army(detached)
				var parent_people := int(split_parent.get("personnel", -1))
				var child_people := int(split_child.get("personnel", -1))
				var parent_heads := int(split_parent.get("headcount", 0))
				var child_heads := int(split_child.get("headcount", 0))
				print("[military-smoke] split day=%d parent=%d detached=%d personnel %d+%d (baseline %d) headcount %d+%d (baseline %d)" % [
					_day, handle, detached, parent_people, child_people, lane_baseline,
					parent_heads, child_heads, headcount_baseline])
				_expect("split conserves personnel across both formations",
					child_people > 0 and parent_people + child_people == lane_baseline,
					"%d + %d != %d" % [parent_people, child_people, lane_baseline])
				_expect("split conserves the military headcount",
					parent_heads + child_heads == headcount_baseline,
					"%d + %d != %d" % [parent_heads, child_heads, headcount_baseline])
				# The detached formation is a real formation: it marches on its own
				# and its people travel with it (contract §3.1). The parent stays
				# where it is with its own people.
				var detached_cell := int(split_child.get("cell", -1))
				var detach_target := _march_target(map, facade, detached, detached_cell, 4)
				if detach_target >= 0:
					var detach_move: Dictionary = facade.move_army(detached, detach_target)
					_expect("detached army.move accepted",
						bool(detach_move.get("ok", false)), str(detach_move))
					await _advance_to(_day + 4)
					var after_detach: Dictionary = facade.army(detached)
					var parent_hold: Dictionary = facade.army(handle)
					var moved_people := int(after_detach.get("personnel", -1))
					var held_people := int(parent_hold.get("personnel", -1))
					print("[military-smoke] detached march day=%d cell %d->%d (target %d) personnel %d->%d parent cell %d personnel %d" % [
						_day, detached_cell, int(after_detach.get("cell", -1)),
						detach_target, child_people, moved_people,
						int(parent_hold.get("cell", -1)), held_people])
					_expect("detached formation marches independently",
						int(after_detach.get("cell", -1)) != detached_cell,
						"%d -> %s (target %d)" % [detached_cell,
							str(after_detach.get("cell", -1)), detach_target])
					_expect("detached personnel travels with the formation",
						moved_people > 0 and moved_people == child_people,
						"%d -> %d" % [child_people, moved_people])
					_expect("parent formation keeps its own people during child march",
						held_people == parent_people,
						"cell %s personnel %d -> %d" % [
							str(parent_hold.get("cell", -1)), parent_people, held_people])
					_expect("split total stays conserved after the march",
						held_people + moved_people == lane_baseline,
						"%d + %d != %d" % [held_people, moved_people, lane_baseline])
				else:
					print("[military-smoke] SKIP detached march assertion: no reachable land cell near %d" % detached_cell)
				# --- army.transfer: partial (33) then whole formation (32) ---
				# Transfer requires both formations in one cell, but the detached
				# one just marched away to prove it travels with its people.
				var parent_cell_now := int(facade.army(handle).get("cell", -1))
				var det_cell_now := int(facade.army(detached).get("cell", -1))
				if det_cell_now != parent_cell_now:
					facade.submit([{"op": "army.move", "army": detached,
						"cell": parent_cell_now}])
					await _advance_to(_day + 6)
				var total_before := _army_personnel(facade, handle) \
					+ _army_personnel(facade, detached)
				var partial: Dictionary = facade.submit([{"op": "army.transfer",
					"country": player, "army": handle, "other": detached,
					"units": {-1: 1}}])
				_expect("army.transfer (partial) accepted",
					bool(partial.get("ok", false)), str(partial))
				await _advance_to(_day + 4)
				var after_partial := _army_personnel(facade, handle) \
					+ _army_personnel(facade, detached)
				print("[military-smoke] transfer partial day=%d total %d -> %d" % [
					_day, total_before, after_partial])
				_expect("partial transfer conserves personnel",
					total_before > 0 and after_partial == total_before,
					"%d -> %d" % [total_before, after_partial])
				var whole: Dictionary = facade.submit([{"op": "army.transfer",
					"country": player, "army": handle, "other": detached,
					"units": {-1: 1000000}}])
				_expect("army.transfer (whole formation) accepted",
					bool(whole.get("ok", false)), str(whole))
				await _advance_to(_day + 4)
				var merged_parent: Dictionary = facade.army(handle)
				var after_whole := _army_personnel(facade, handle) \
					+ _army_personnel(facade, detached)
				print("[military-smoke] transfer whole day=%d total %d -> %d (parent %s detached %s)" % [
					_day, total_before, after_whole,
					str(merged_parent.get("personnel", -1)),
					str(_army_personnel(facade, detached))])
				_expect("whole-formation transfer conserves personnel",
					after_whole == total_before,
					"%d -> %d" % [total_before, after_whole])
				# Keep the station assertion below on the current book.
				personnel_after = int(merged_parent.get("personnel", personnel_after))
		else:
			print("[military-smoke] SKIP split/transfer lane assertions (lane=%s split_lane=%s personnel=%d)" % [
				str(army_lane), str(split_lane), personnel_after])
		# --- army personnel lane: station returns the people to the cell ---
		# army.station disembarks at the formation's own cell; the lane row is
		# emptied and the heads must reappear in that cell. The conserved quantity
		# is the cell's POPULATION (contract §2.3): the Economy keeps one living
		# merchant on every populated cell, so a garrison that disbands in a cell
		# with no civilians turns exactly one of its own heads into that cell's
		# market maker. (Skipping that repair is not an option: the cell's
		# household revenue would have no owner and settle into
		# market_revenue_has_no_merchant_owner.)
		var station_row_before: Dictionary = facade.army(handle)
		var station_cell := int(station_row_before.get("cell", cell_after))
		var people_at_station := await _cell_population(econ, station_cell)
		var soldiers_at_station := await _cell_soldiers(econ, station_cell)
		var station: Dictionary = facade.submit([
			{"op": "army.stop", "country": player, "army": handle},
			{"op": "army.station", "country": player, "army": handle}])
		_expect("army.station accepted", bool(station.get("ok", false)), str(station))
		await _advance_to(_day + 4)
		var people_after_station := await _cell_population(econ, station_cell)
		var soldiers_after_station := await _cell_soldiers(econ, station_cell)
		var station_row: Dictionary = facade.army(handle)
		print("[military-smoke] station day=%d cell=%d population %d->%d soldier %d->%d armies=%d" % [
			_day, station_cell, people_at_station, people_after_station,
			soldiers_at_station, soldiers_after_station,
			facade.armies(player).size()])
		_expect("army.station disbanded the formation",
			not bool(station_row.get("ok", false)),
			str(station_row.get("reason", "")))
		if army_lane and people_at_station >= 0 and personnel_after > 0:
			var returned := people_after_station - people_at_station
			var market_makers := returned - (soldiers_after_station - soldiers_at_station)
			_expect("army personnel returns to the destination cell",
				returned == personnel_after and market_makers >= 0 \
					and market_makers <= 1,
				"cell=%d population %d->%d (+%d of +%d) soldier %d->%d market_makers=%d" % [
					station_cell, people_at_station, people_after_station, returned,
					personnel_after, soldiers_at_station, soldiers_after_station,
					market_makers])
		else:
			print("[military-smoke] SKIP station personnel assertion (lane=%s cell_pop=%d personnel=%d)" % [
				str(army_lane), people_at_station, personnel_after])
		# --- army pay: the garrison resumes once the formation disbands (§4.1) ---
		# The formation is gone, so its lane no longer exists and its pay rows stop.
		# The heads are back in the cell's soldier cohort, so the garage payroll row
		# must pick them up again: `payroll` returns to (cell soldier cohort) x wage.
		# Without this, army pay could silently keep paying a dead lane (or drop the
		# returned heads entirely) and nobody would notice from the lane alone.
		if army_lane and soldiers_after_station > 0 \
				and bool(facade.last_daily_report().get("army_pay_supported", false)):
			# The pay split in the report belongs to the day just stepped, so step a
			# few days with the formation gone before reading it: a stale report would
			# still describe the last day the army existed. The lot return, the lane
			# release and the Economy's cell cohort each settle on their own day, so
			# the window is generous and the assertion reads the MILITARY roster (which
			# is what the wage path iterates), not the lagging Economy cohort.
			await _advance_to(_day + 6)
			var resumed := await _pay_window(facade, country, player, 0, econ)
			var resumed_snapshot: Dictionary = facade.country_snapshot(player)
			var resumed_wage := int(resumed_snapshot.get("daily_wage", 0))
			var resumed_daily := int(resumed.get("payroll_garrison", 0))
			var garrisoned := int(resumed_snapshot.get("soldiers_garrisoned", 0))
			var resumed_expected := garrisoned * resumed_wage
			var resumed_tolerance := maxi(1, int(resumed_expected / 10.0))
			print("[military-smoke] garrison resume day=%d cell=%d garrisoned=%d wage=%d payroll_garrison=%d payroll_army=%d expected=%d (army had paid %d for %d heads)" % [
				_day, station_cell, garrisoned, resumed_wage, resumed_daily,
				int(resumed.get("payroll_army", 0)), resumed_expected,
				int(pay_baseline.get("heads", 0)) * int(pay_baseline.get("wage", 0)),
				int(pay_baseline.get("heads", 0))])
			_expect("the garrison resumes paying the returned heads after disband",
				resumed_expected > 0 \
					and absi(resumed_daily - resumed_expected) <= resumed_tolerance,
				"payroll_garrison=%d expected=%d (garrisoned x wage) tol=%d" % [resumed_daily,
					resumed_expected, resumed_tolerance])
			_expect("army pay stops once the formation is disbanded",
				int(resumed.get("payroll_army", -1)) == 0,
				"payroll_army=%s" % str(resumed.get("payroll_army", -1)))
		else:
			print("[military-smoke] SKIP garrison-resume assertion (lane=%s cell_soldier=%d)" % [
				str(army_lane), soldiers_after_station])

	await _advance_to(TOTAL_DAYS)
	report = facade.report()
	snapshot = facade.country_snapshot(player)
	print("[military-smoke] day=%d report=%s" % [_day, JSON.stringify(_compact(report))])
	print("[military-smoke] armies=%s wars=%s" % [JSON.stringify(facade.armies(player)),
		JSON.stringify(snapshot.get("wars", []))])
	_expect("military stepped to the end of the run",
		int(report.get("last_step_day", -1)) >= TOTAL_DAYS - 8,
		"last_step_day=%d" % int(report.get("last_step_day", -1)))
	_expect_counters(report, "day %d" % _day)
	if int(foreign.get("handle", 0)) != 0 and int(snapshot.get("soldiers_total", 0)) > 0:
		_expect("war is active", int(snapshot.get("wars_active", 0)) > 0,
			str(snapshot.get("wars", [])))
	var job = generator.get_military_daily_job() \
		if generator.has_method("get_military_daily_job") else null
	if job != null:
		print("[military-smoke] events_forwarded=%d" % int(job.events_forwarded()))
		_check_bus_source(generator, int(job.events_forwarded()))

	# --- PKMI round trip ---
	var hash_before := int(facade.state_hash())
	var bytes: PackedByteArray = facade.encode_state()
	_expect("PKMI encodes", not bytes.is_empty(), "bytes=%d" % bytes.size())
	if not bytes.is_empty():
		var restored: Dictionary = facade.restore_state(bytes)
		_expect("PKMI restores", bool(restored.get("ok", false)), str(restored))
		var hash_after := int(facade.state_hash())
		_expect("PKMI encode -> restore preserves state_hash", hash_after == hash_before,
			"%d -> %d" % [hash_before, hash_after])
		var again: PackedByteArray = facade.encode_state()
		_expect("PKMI re-encode is byte identical", again == bytes,
			"%d vs %d bytes" % [again.size(), bytes.size()])
	return _finish()


# ------------------------------------------------------------------ driver

func _advance_to(target_day: int) -> void:
	var generator := _host.get_generator()
	while _day < target_day:
		_day += 1
		_clock.current_day = float(_day)
		var phase := _clock.season_phase_for_day(_day)
		if _host.runtime_climate_authority_enabled:
			var capacity_deadline := Time.get_ticks_usec() + 60000000
			while not bool(_host.wait_for_climate_consumed(0).get("ok", true)) \
					and Time.get_ticks_usec() < capacity_deadline:
				_host._consume_runtime_commit_if_ready()
				await process_frame
			_host._consume_runtime_commit_if_ready()
		_host.run_daily_tick(_day, phase)
		_host.finish_daily_tick(0.0, {})
		if _host.runtime_climate_authority_enabled:
			var deadline := Time.get_ticks_usec() + 60000000
			while Time.get_ticks_usec() < deadline:
				_host._consume_runtime_commit_if_ready()
				var progress: Dictionary = generator.get_runtime_thread_report()
				if int(progress.get("simulation_committed_day",
						progress.get("committed_day", -1))) >= _day - 1 - PIPELINE_DEPTH:
					break
				await process_frame
		var pulses := 0
		while _has_hard_barrier() and pulses < MAX_BARRIER_PULSES_PER_DAY:
			_clock.simulation_backpressure_pulse.emit(_day)
			pulses += 1
			await process_frame
		if _has_hard_barrier():
			_expect("hard barrier drains at day %d" % _day, false)
			return
		if bool(generator.get_economy_report().get("fatal", false)):
			_expect("economy stays non-fatal (day %d)" % _day, false,
				str(generator.get_economy_report().get("fatal_reason", "")))
			return
	# Let the host drain committed military days (whole-graph ACTIVE replays
	# at most 4 per frame) before the caller inspects state.
	for _frame in range(64):
		_host._consume_runtime_commit_if_ready()
		var facade = generator.get_military_facade()
		if facade == null or int(facade.report().get("last_step_day", -1)) \
				>= _day - 1 - PIPELINE_DEPTH:
			break
		await process_frame


func _has_hard_barrier() -> bool:
	return _clock._simulation_backpressure_sources.has(&"country_day_barrier") \
		or _clock._simulation_backpressure_sources.has(&"economy_day_barrier")


func _print_progress(label: String) -> void:
	var generator := _host.get_generator()
	var thread: Dictionary = generator.get_runtime_thread_report()
	var facade = generator.get_military_facade()
	var mil: Dictionary = facade.report() if facade != null else {}
	print("[military-smoke] progress %s driver_day=%d committed=%s host_mil=%s last_step_day=%s should_run(next)=%s state=%s" % [
		label, _day,
		str(thread.get("simulation_committed_day", thread.get("committed_day", "?"))),
		JSON.stringify(_compact(_host.military_report())) if _host.has_method("military_report") else "?",
		str(mil.get("last_step_day", "?")),
		str(facade.should_run(int(mil.get("last_step_day", 0)) + 1)) if facade != null else "?",
		str(thread.get("simulation_host_state", "?"))])


# ------------------------------------------------------------------ helpers

static func _barracks_index(catalog: Dictionary) -> int:
	# Prefer a barracks whose gate technology is already empty (cheapest to
	# grant); otherwise the first barracks row is fine, because the caller grants
	# its gate technology before ordering the sponsored build.
	var buildings: Array = catalog.get("state_buildings", [])
	var first := -1
	for index in range(buildings.size()):
		var building: Dictionary = buildings[index]
		if int(building.get("role", -1)) != 0:
			continue
		if first < 0:
			first = index
		if String(building.get("unlock_tech_id", "")).is_empty():
			return index
	return first


## Adjacent foreign country (shares a hex edge with player territory) when one
## exists, else the nearest foreign-owned land cell by land BFS from the
## player's territory.
func _foreign_target(map: MapData, country, player: int) -> Dictionary:
	var count := map.cell_count()
	var owner := PackedInt64Array()
	owner.resize(count)
	for cell in range(count):
		owner[cell] = int(country.cell_summary(cell).get("country_handle", 0))
	var neighbors := map.neighbor_indices_packed()
	var dist := PackedInt32Array()
	dist.resize(count)
	dist.fill(-1)
	var queue := PackedInt32Array()
	for cell in range(count):
		if owner[cell] == player:
			dist[cell] = 0
			queue.append(cell)
	var head := 0
	while head < queue.size():
		var cell := int(queue[head])
		head += 1
		for direction in range(6):
			var nb := int(neighbors[cell * 6 + direction])
			if nb < 0 or dist[nb] >= 0:
				continue
			if owner[nb] != 0 and owner[nb] != player:
				return {"handle": int(owner[nb]), "cell": nb,
					"adjacent": dist[cell] == 0, "distance": dist[cell] + 1}
			if map.is_water_arr[nb] != 0:
				continue
			dist[nb] = dist[cell] + 1
			queue.append(nb)
	# No land path: fall back to any foreign cell.
	for cell in range(count):
		if owner[cell] != 0 and owner[cell] != player:
			return {"handle": int(owner[cell]), "cell": cell, "adjacent": false,
				"distance": -1}
	return {}


## Farthest passable land cell within `steps` hex steps of `from` (BFS in
## neighbour order, so it is deterministic). Used as the march target when this
## seed's foreign country has no land bridge from the capital and the formation
## would otherwise never move.
static func _land_cell_within(map: MapData, from: int, steps: int) -> int:
	var count := map.cell_count()
	if from < 0 or from >= count:
		return -1
	var neighbors := map.neighbor_indices_packed()
	var dist := PackedInt32Array()
	dist.resize(count)
	dist.fill(-1)
	dist[from] = 0
	var queue := PackedInt32Array()
	queue.append(from)
	var best := -1
	var best_dist := 0
	var head := 0
	while head < queue.size():
		var cell := int(queue[head])
		head += 1
		if dist[cell] >= steps:
			continue
		for direction in range(6):
			var nb := int(neighbors[cell * 6 + direction])
			if nb < 0 or dist[nb] >= 0:
				continue
			if map.is_water_arr[nb] != 0:
				continue
			dist[nb] = dist[cell] + 1
			queue.append(nb)
			if dist[nb] > best_dist:
				best_dist = dist[nb]
				best = nb
	return best


## Nearest passable land cell to `from` (BFS order, deterministic) that the
## formation's own path tool accepts, so a split/transfer assertion is never
## vacuous on a seed whose neighbourhood is closed. -1 when none within `steps`.
static func _march_target(map: MapData, facade, army: int, from: int, steps: int) -> int:
	for candidate in _land_cells_within(map, from, steps):
		var preview: Dictionary = facade.preview_path(army, int(candidate))
		if bool(preview.get("ok", false)):
			return int(candidate)
	return -1


## Land cells reachable within `steps` hex steps of `from`, nearest first.
static func _land_cells_within(map: MapData, from: int, steps: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var count := map.cell_count()
	if from < 0 or from >= count:
		return out
	var neighbors := map.neighbor_indices_packed()
	var dist := PackedInt32Array()
	dist.resize(count)
	dist.fill(-1)
	dist[from] = 0
	var queue := PackedInt32Array()
	queue.append(from)
	var head := 0
	while head < queue.size():
		var cell := int(queue[head])
		head += 1
		if dist[cell] >= steps:
			continue
		for direction in range(6):
			var nb := int(neighbors[cell * 6 + direction])
			if nb < 0 or dist[nb] >= 0:
				continue
			if map.is_water_arr[nb] != 0:
				continue
			dist[nb] = dist[cell] + 1
			queue.append(nb)
			out.append(nb)
	return out


## Handle of the formation in `rows` that is not `known` (0 when there is none).
static func _other_army(rows: Array, known: int) -> int:
	for row in rows:
		var candidate := int((row as Dictionary).get("handle", 0))
		if candidate != 0 and candidate != known:
			return candidate
	return 0


## Economy lane heads of one formation; 0 when the handle no longer resolves
## (a formation merged away is gone, not negative).
static func _army_personnel(facade, army: int) -> int:
	if army == 0:
		return 0
	var row: Dictionary = facade.army(army)
	if not bool(row.get("ok", false)):
		return 0
	return int(row.get("personnel", 0))


## One reading of the army-pay bookkeeping, for a before/after comparison.
## `payroll_army` is the payroll the day's ARMY rows carried (what left the
## treasury for the formations' lanes), `payroll_garrison` the cell rows' share:
## the two are the same-day split, not the 30-day EWMA, so they can be compared
## with heads x wage directly. `ok` is false when the loaded build has no
## army-pay support, so the caller skips instead of failing on an older DLL.
## `army_handle` 0 reads the garrison-only book (no lane): used after a disband,
## when the heads are back in the cell.
func _pay_window(facade, country, player: int, army_handle: int, econ) -> Dictionary:
	if not bool(facade.last_daily_report().get("army_pay_supported", false)):
		return {"ok": false, "reason": "the loaded economy has no opcode 34 (army_pay_supported=false)"}
	if country == null:
		return {"ok": false, "reason": "no country runtime"}
	var snapshot: Dictionary = facade.country_snapshot(player)
	var cash := int(country.treasury_snapshot(player).get("cash", 0))
	var heads := 0
	var lane_funds := -1
	if army_handle != 0:
		var row: Dictionary = facade.army(army_handle)
		if not bool(row.get("ok", false)):
			return {"ok": false, "reason": "formation %d is gone" % army_handle}
		lane_funds = int(row.get("lane_funds", -1))
		if lane_funds < 0:
			return {"ok": false, "reason": "the economy reports no lane cash (lane_funds=%d)" % lane_funds}
		heads = int(row.get("personnel", 0))
	return {
		"ok": true,
		"days": _day,
		"heads": heads,
		"wage": int(snapshot.get("daily_wage", 0)),
		"lane_funds": lane_funds,
		"cash": cash,
		"payroll_army": int(facade.last_daily_report().get("payroll_army", 0)),
		"payroll_garrison": int(facade.last_daily_report().get("payroll_garrison", 0)),
		"pay_ratio_q16": int(snapshot.get("pay_ratio_30_q16", -1)),
	}


func _check_bus_source(generator, forwarded: int) -> void:
	var bus = generator.get_gameplay_event_bus() \
		if generator.has_method("get_gameplay_event_bus") else null
	if bus == null or not bus.is_available() or forwarded <= 0:
		print("[military-smoke] bus source check skipped (forwarded=%d)" % forwarded)
		return
	var replay: Dictionary = bus.replay_events(0, TOTAL_DAYS + 8, 0, 0)
	var types: PackedInt32Array = replay.get("type", PackedInt32Array())
	var sources: PackedInt32Array = replay.get("source", PackedInt32Array())
	var military := 0
	var bad := 0
	for i in range(mini(types.size(), sources.size())):
		if int(types[i]) < 40 or int(types[i]) > 47:
			continue
		military += 1
		if int(sources[i]) != GameplayEventBus.SOURCE_MILITARY:
			bad += 1
	print("[military-smoke] bus military events=%d wrong_source=%d" % [military, bad])
	if military > 0:
		_expect("military bus events carry SOURCE_MILITARY", bad == 0)


func _expect_counters(report: Dictionary, label: String) -> void:
	var negative := PackedStringArray()
	for key in COUNTER_KEYS:
		if report.has(key) and int(report[key]) < 0:
			negative.append("%s=%d" % [key, int(report[key])])
	_expect("report counters non-negative (%s)" % label, negative.is_empty(),
		", ".join(negative))


## Economy soldier heads at one cell. Retried because whole-graph ACTIVE serves
## the population read from the worker's committed view, so the first read of a
## key can be `economy_read_view_pending`. -1 when it never becomes readable.
func _cell_soldiers(econ, cell: int) -> int:
	if econ == null or cell < 0:
		return -1
	var snapshot: Dictionary = econ.population_cell_snapshot(cell)
	for _attempt in range(8):
		if snapshot.has("populations") and snapshot.has("profession_stable_ids"):
			return _profession_population(snapshot, "soldier")
		await process_frame
		snapshot = econ.population_cell_snapshot(cell)
	return -1


## Economy total population at one cell. Same retry contract as _cell_soldiers.
func _cell_population(econ, cell: int) -> int:
	if econ == null or cell < 0:
		return -1
	var snapshot: Dictionary = econ.population_cell_snapshot(cell)
	for _attempt in range(8):
		if snapshot.has("population"):
			return int(snapshot.get("population", -1))
		await process_frame
		snapshot = econ.population_cell_snapshot(cell)
	return -1


static func _profession_population(snapshot: Dictionary, stable_id: String) -> int:
	var catalog_ids: PackedStringArray = snapshot.get("profession_stable_ids", PackedStringArray())
	var rows: PackedInt32Array = snapshot.get("profession_ids", PackedInt32Array())
	var pops: PackedInt64Array = snapshot.get("populations", PackedInt64Array())
	var total := 0
	for row in range(mini(rows.size(), pops.size())):
		var profession := int(rows[row])
		if profession >= 0 and profession < catalog_ids.size() \
				and String(catalog_ids[profession]) == stable_id:
			total += int(pops[row])
	return total


static func _compact(value: Dictionary) -> Dictionary:
	var out := {}
	for key in value.keys():
		var item = value[key]
		if item is Array or item is Dictionary or typeof(item) >= TYPE_PACKED_BYTE_ARRAY:
			continue
		out[key] = item
	return out


func _expect(label: String, ok: bool, detail := "") -> void:
	print("  [%s] %s%s" % ["PASS" if ok else "FAIL", label,
		"" if detail.is_empty() else " :: " + detail])
	if not ok:
		_failures.append(label)


func _finish() -> int:
	if _logger != null:
		var errors := _logger.errors
		var shown := mini(errors.size(), 20)
		for i in range(shown):
			print("  [error] " + errors[i])
		_expect("no push_error / script errors", errors.is_empty(),
			"%d errors" % errors.size())
	print("military runtime smoke: %d failures" % _failures.size())
	for failure in _failures:
		print("  FAILED: " + failure)
	return 0 if _failures.is_empty() else 1
