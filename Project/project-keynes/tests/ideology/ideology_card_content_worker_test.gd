extends SceneTree

## C0 acceptance ON THE WORKER PATH. The game only ever runs the worker, so this
## file -- not `ideology_card_content_test.gd` -- is what "C0 passed" means.
##
## Why a second file
## -----------------
## `ideology_card_content_test.gd` drives `DCWorldExt` with a synthetic 12-cell
## catalog fixture on the main thread. That is a fast unit test, and it cannot
## prove anything about the path the game takes: a real `WorldRuntimeHost` worker,
## EFFECT owned by the worker, and the modifier rows arriving back through the
## worker transport. This file runs that path.
##
## The fixture is `runtime_ideology_parity_test.gd::_run_production_shadow_parity`
## (the known-good way to make the worker advance headless days) with one change:
## the forwarder is told EFFECT belongs to the worker
## (`set_effect_forwarder_authority_for_test(1)`, the seam documented in
## `ideology_effect_worker_forward_test.gd`). Everything else stays production:
## real `WorldRuntimeHost`, real `MapGenerator`, real clock, real worker thread.
##
## What is asserted, per card
## --------------------------
##  1. the card adopts on the worker path (slot occupied), and
##  2. the national stat reads the DESIGN value from the design table, not the
##     main-thread fixture's constant, and
##  3. `list_modifiers` shows the row that carries it.
##
## Card values come from `docs/plans/ideology-build-redesign.md` §5, the same
## numbers `ideology_card_content_test.gd` pins on the main thread. A card whose
## worker-path value differs from the main-thread value is the defect this file
## exists to find.
##
## Fixture notes (all learned in the parity test)
## ----------------------------------------------
##  * `add_child(host)` then `await process_frame`: `_init()` runs before the tree
##    is entered, so `generate_world()` returns silently otherwise.
##  * `runtime_climate_authority_enabled = false` + `runtime_parity_forcing = true`
##    is the only combination where the worker's climate commit happens while
##    IDEOLOGY is NOT granted to it -- granting IDEOLOGY would suppress
##    `run_ideology_daily` and there would be nothing to observe.
##  * The clock must be pulsed to `PAUSED` around each day, and the hard barriers
##    must be drained, or the worker never commits.
##  * `OS.delay_msec` instead of `await` inside the tick loop: the tree must not
##    advance a frame mid-day or the deadline logic drifts.

const CountryCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")

const WIDTH := 16
const HEIGHT := 12
const SEED := 20261022
const WORKER_SPEED := 10.0
const Q16_ONE := 65536
const MODIFIER_DOMAIN_COUNTRY := 1
## Days to drive after adopting. The worker needs a warm-up before its first
## committed day, so this is "enough to settle", not "exactly one".
const SETTLE_TICKS := 5
## Authority bit for IDEOLOGY. `runtime_domain_mask()` in `runtime_pod_protocol.h`
## is `1u << (domain_id - 1)`, and `RuntimeDomainId::IDEOLOGY = 5`, so the bit is
## `1 << 4 = 0x10`. (`0x20` is EFFECT, id 6 -- assuming `1 << id` would silently
## test the wrong domain, and it would PASS against a 0xFFF mask, so the expected
## value has to be exact.)
const IDEOLOGY_BIT := 0x10
const EFFECT_BIT := 0x20

## `card key -> (stat, design value at L1)`, from the design doc §5.
##
## ONE card is exercised per process: `C0_ONLY_CARD=<key>` picks it. See
## `_run_worker_card_acceptance` for the measured reasons (a second equip wedges the
## day loop; unequip does not free the slot).
const CARDS := [
	{"key": "terrace_farming",
	 "stat": "country.output.terrain.hill.agriculture_factor", "value": 1.10},
	{"key": "water_works",
	 "stat": "country.output.terrain.floodplain.agriculture_factor", "value": 1.08},
	{"key": "forager_band",
	 "stat": "country.output.terrain.forest.agriculture_factor", "value": 1.08},
	{"key": "riverside_camp",
	 "stat": "country.output.terrain.floodplain.agriculture_factor", "value": 1.06},
	{"key": "seasonal_calendar",
	 "stat": "country.climate.cold_stress_factor", "value": 0.94},
	{"key": "pit_dwelling",
	 "stat": "country.construction.cost_factor", "value": 0.95},
	{"key": "hydroelectric",
	 "stat": "country.output.terrain.floodplain.energy_factor", "value": 1.12},
	{"key": "land_tax_reform",
	 "stat": "country.tax.income.tenant_farmer.rate_bp", "value": 0.90},
	# 消费税制 is ADDITIVE (`operation = Add`, in basis points). A ratio assert is
	# meaningless for it, so the row names an ADD expectation instead: reading with
	# base 0 returns the raw additive delta, which must be 300 bp ("+3 个百分点").
	{"key": "excise",
	 "stat": "country.tax.consumption.jewelry.rate_bp", "value": 300.0,
	 "additive": true},
]

var _checks := 0
var _failures := 0
var _next_sequence := 1
var _only_card := OS.get_environment("C0_ONLY_CARD").strip_edges()


func _init() -> void:
	call_deferred("_run_and_finish")


func _run_and_finish() -> void:
	var code := await _run()
	print("=== ideology card content worker: %d checks, %d failures ===" % [
		_checks, _failures])
	quit(code if code != 0 else (0 if _failures == 0 else 1))


func _run() -> int:
	if not ClassDB.class_exists("DCWorldExt"):
		_printerr_stage("DCWorldExt unavailable")
		_fail("DCWorldExt unavailable")
		return 3
	return await _run_worker_card_acceptance()


func _run_worker_card_acceptance() -> int:
	var built := await _build_world()
	if built.is_empty():
		return 6
	var host: WorldRuntimeHost = built["host"]
	var clock: WorldClock = built["clock"]
	var ext = built["ext"]
	var handle: int = int(built["handle"])
	var tick: int = int(built["tick"])
	var ids: PackedStringArray = built["ids"]

	# THE production-path gate: IDEOLOGY must be OWNED BY THE WORKER.
	#
	# `RuntimeDomainId::IDEOLOGY = 5` and the mask is `1 << (id - 1)`
	# (`runtime_pod_protocol.h:566`), so the authority bit is `0x10`. Asserting the
	# bit is what distinguishes "the worker did it" from "the main thread did it
	# while a worker watched". `0x20` is EFFECT -- asserted separately so a mix-up
	# cannot pass as a full mask.
	var thread_report: Dictionary = ext.get_runtime_thread_report()
	var granted := int(thread_report.get("authoritative_domain_mask", 0))
	if not _require("worker owns IDEOLOGY (authoritative_domain_mask & 0x10)",
			(granted & IDEOLOGY_BIT) != 0,
			"mask=0x%X state=%s" % [granted,
				String(thread_report.get("simulation_host_state", ""))]):
		_teardown(host, clock)
		return 8
	_expect("worker owns EFFECT too (0x20), so the card's rows are worker-authored",
		(granted & EFFECT_BIT) != 0, "mask=0x%X" % granted)
	_expect("worker owns the whole twelve-stage mask (0xFFF) like player_game.gd",
		(granted & 0xFFF) == 0xFFF, "mask=0x%X" % granted)

	# ONE world, and every C0 card must be PRESENT and resolvable in the worker's
	# catalog. That part needs no slot and covers all nine.
	var missing := PackedStringArray()
	for row_value in CARDS:
		var key := String((row_value as Dictionary)["key"])
		if ids.find("idea.%s" % key) < 0:
			missing.append(key)
	if not _require("all nine C0 cards are in the worker catalog",
			missing.is_empty(), "missing=%s" % ", ".join(missing)):
		_teardown(host, clock)
		return 7

	# One card per world.
	#
	# Measured 2026-10-22 on this fixture:
	#   * a SECOND equip in the same world wedges the day loop
	#     (`[runtime-day-wait] stall=0x1` repeats until the run is killed);
	#   * unequip does not release the ideology slot (`slots_used 1 -> 1`), so the
	#     cabinet never frees up for the next card.
	# Both are runtime issues recorded for session R in `09-content-status.md`
	# §3.7, not content issues. Running ONE card per process is therefore the only
	# shape that completes: `C0_ONLY_CARD=<key>` selects it, and a batch runner
	# invokes this file once per card.
	var chosen := _only_card
	if chosen.is_empty():
		chosen = String((CARDS[0] as Dictionary)["key"])
		printerr("[stage] C0_ONLY_CARD unset; defaulting to %s" % chosen)
	for row_value in CARDS:
		var row: Dictionary = row_value
		var key := String(row["key"])
		if key != chosen:
			continue
		var dense := ids.find("idea.%s" % key)
		var additive := bool(row.get("additive", false))
		# The pod's DISCOVER runs `requirements_met`
		# (`runtime_ideology_pod.cpp`): the era-milestone technology AND every authored
		# research signal (terrace_farming needs `landform.mountain`). A 16x12 world
		# does not discover those on its own in a few days, and the pod answers a
		# gate miss with the generic `ideology_worker_rejected`. Granting them here is
		# what the production game reaches through research, and the facade is the
		# same command path the GM/research UI uses.
		_stage("%s: satisfy draw gates" % key)
		_grant_draw_gates(host, "idea.%s" % key, handle, tick)
		_stage("%s: read base" % key)
		# An additive card is measured as a DELTA: reading with base 0 isolates the
		# sum_add component, so the assert is "+300 bp", not "x1.30" (which depends
		# on the world's current tax rate and would be a different number in play).
		var before := _read(ext, handle, String(row["stat"]), 0.0 if additive else 1.0)
		_expect("%s/%s reads the base before equip" % [key, row["stat"]],
			_is_close(before, 0.0 if additive else 1.0, 0.0001), "%.5f" % before)
		_stage("%s: discover+equip" % key)
		# On this path `run_ideology_daily` is suppressed and the POD owns the card
		# state, so DISCOVER then EQUIP are two separate daily plans: the pod's
		# `EQUIP` requires `known_bits`, which only the DISCOVER command sets. Sending
		# both in one batch would have the EQUIP rejected with `ideology_unknown`
		# (`runtime_ideology_pod.cpp:1309`) and the rejection is silent from here.
		var discovered: Dictionary = ext.submit_ideology_commands(_commands([
			{"op": 1, "day": tick, "handle": handle, "idea": dense},
		]))
		if not _require("%s: worker accepts discover" % key,
				bool(discovered.get("ok", false)), str(discovered)):
			continue
		tick = _drive_days(host, clock, ext, tick, 2)
		var submitted: Dictionary = ext.submit_ideology_commands(_commands([
			{"op": 5, "day": tick, "handle": handle, "idea": dense},
		]))
		if not _require("%s: worker accepts equip" % key,
				bool(submitted.get("ok", false)), str(submitted)):
			continue
		_stage("%s: drive worker days" % key)
		tick = _drive_days(host, clock, ext, tick, SETTLE_TICKS)
		_stage("%s: assert" % key)
		var snapshot: Dictionary = ext.get_ideology_snapshot(handle)
		var thread: Dictionary = ext.get_runtime_thread_report()
		var ideo: Dictionary = ext.get_ideology_report()
		_expect("%s occupies an ideology slot on the worker path" % key,
			int(snapshot.get("ideology_slots_used", 0)) >= 1,
			"slots_used=%d materialized=%s pod_gen=%d pod_day=%d accrue=%s "
			% [int(snapshot.get("ideology_slots_used", -1)),
				str(snapshot.get("materialized", "?")),
				int(thread.get("ideology_pod_snapshot_generation", -1)),
				int(thread.get("ideology_parity_worker_committed_day", -2)),
				str(ideo.get("points_accrue_result", "?"))]
			+ "receipts=%s known=%s"
			% [str(ext.poll_ideology_receipts(0, 8)) if ext.has_method(
					"poll_ideology_receipts") else "n/a",
				str(snapshot.get("known_ids", PackedInt32Array()))])
		var rows: Dictionary = ext.list_modifiers(MODIFIER_DOMAIN_COUNTRY, handle, "")
		var applied := PackedStringArray(rows.get("definition_keys", PackedStringArray()))
		_expect("%s applied a national modifier row on the worker path" % key,
			not applied.is_empty(), "rows=%s" % str(applied))
		var after := _read(ext, handle, String(row["stat"]), 0.0 if additive else 1.0)
		var expected := float(row["value"])
		var ratio := after - before if additive else (
			after / before if not is_zero_approx(before) else 0.0)
		_expect("%s/%s equals the design value %.4f on the worker path"
			% [key, row["stat"], expected],
			_is_close(ratio, expected, 0.5 if additive else 0.0005),
			"before=%.5f after=%.5f ratio=%.5f expected=%.5f rows=%s"
			% [before, after, ratio, expected, str(applied)])
		# ── the two §3.7 issues, re-checked on the PRODUCTION path ──────────
		#
		# The previous round measured these under SHADOW + the test seam. Now that
		# the worker really owns IDEOLOGY, ask again with real assertions instead of
		# asserting the gap.
		_stage("%s: unequip" % key)
		ext.submit_ideology_commands(_commands([
			{"op": 6, "day": tick, "handle": handle, "idea": dense}]))
		tick = _drive_days(host, clock, ext, tick, 3)
		var released: Dictionary = ext.get_ideology_snapshot(handle)
		_expect("%s releases its ideology slot on unequip (production path)" % key,
			int(released.get("ideology_slots_used", -1)) == 0,
			"slots_used=%d" % int(released.get("ideology_slots_used", -1)))
		var rows_after: Dictionary = ext.list_modifiers(
			MODIFIER_DOMAIN_COUNTRY, handle, "")
		var left := PackedStringArray(rows_after.get(
			"definition_keys", PackedStringArray()))
		_expect("%s retires its national modifier row on unequip (production path)"
			% key, not left.has("ideology.%s.l1" % key), "rows=%s" % str(left))
		_expect("%s restores %s to the base on unequip (production path)" % [key, row["stat"]],
			_is_close(_read(ext, handle, String(row["stat"]),
				0.0 if additive else 1.0),
				0.0 if additive else 1.0, 0.0005),
			"after=%.5f rows=%s" % [_read(ext, handle, String(row["stat"]),
				0.0 if additive else 1.0), str(left)])
		# The other §3.7 issue: does a SECOND equip still wedge the day loop?
		# Re-equip the same card and require the day loop to keep committing, which
		# is what `[runtime-day-wait] stall=0x1` used to break.
		_stage("%s: re-equip (stall probe)" % key)
		ext.submit_ideology_commands(_commands([
			{"op": 5, "day": tick, "handle": handle, "idea": dense}]))
		var day_before := int(ext.get_runtime_thread_report().get(
			"ideology_parity_worker_committed_day", -1))
		tick = _drive_days(host, clock, ext, tick, 3)
		var day_after := int(ext.get_runtime_thread_report().get(
			"ideology_parity_worker_committed_day", -1))
		_expect("%s: worker keeps committing days after a second equip" % key,
			day_after > day_before,
			"worker_committed_day %d -> %d" % [day_before, day_after])
		# R-3b: the reason the probe above used to fail. `step_ideology_instance_refresh`
		# requested a boundary turn whenever it lost the economy input lock and never
		# completed it, so the worker parked between semantic days for the rest of the
		# session (`native_simulation_host.cpp:15284`) -- every later day was a no-op.
		# The counter is now per client and the ideology path completes on both exits,
		# so a session that is still making progress must show ZERO outstanding
		# requests. Asserting it here is what makes the stall a test failure rather
		# than a silently shorter run.
		var final_report: Dictionary = ext.get_runtime_thread_report()
		var outstanding := int(final_report.get(
			"main_boundary_service_requests", -1))
		_expect("%s: no client is left waiting for a boundary turn (outstanding=%d)"
			% [key, outstanding], outstanding == 0,
			("ideology=%s trigger=%s state=%s") % [
				str(final_report.get("main_boundary_service_ideology", "?")),
				str(final_report.get("main_boundary_service_trigger", "?")),
				str(final_report.get("simulation_host_state", "?"))])

	_teardown(host, clock)
	return 0


## Builds one world exactly like the PRODUCTION player session
## (`scripts/game/player_game.gd::_configure_runtime`, lines 89-117), which is the
## only path the game takes:
##
##   runtime_climate_authority_enabled = true      # line 93
##   runtime_economy_auto_pod_active   = true      # line 94
##   runtime_authority_domain_mask     = 0xFFF     # line 98
##   set_climate_authority_override("force_on")    # line 116-117
##
## Deliberately NOT used any more:
##   * `runtime_climate_authority_enabled = false` -- that is SHADOW, where the
##     worker compares but the main thread keeps authority, so IDEOLOGY never runs
##     on the worker and the whole acceptance would be measuring the wrong path;
##   * `set_effect_forwarder_authority_for_test(...)` -- a test seam. In production
##     EFFECT authority follows the granted mask.
##
## `runtime_parity_forcing` and `set_runtime_ideology_parity_enabled` are kept: they
## only make the host RECORD a parity reference, they do not move authority.
func _build_world() -> Dictionary:
	var clock := WorldClock.new()
	clock.auto_start = false
	clock.initial_speed = 1.0
	clock.debug_step_log = false
	get_root().add_child(clock)
	clock.pause(true)
	var host := WorldRuntimeHost.new()
	host.map_width = WIDTH
	host.map_height = HEIGHT
	host.initial_seed = SEED
	host.generate_test_economy_data = false
	host.test_economy_population_scale = 100
	# ── production authority, verbatim from player_game.gd ──────────────────
	host.runtime_climate_authority_enabled = true
	host.runtime_economy_auto_pod_active = true
	host.runtime_authority_domain_mask = 0xFFF
	host.runtime_parity_forcing = true
	get_root().add_child(host)
	await process_frame
	host.configure(null, null, clock)
	# Pinned before generation, exactly like the production comment says
	# ("生成前钉死 force_on，避免 AUTO 策略或 GM 残值把会话退回 SHADOW").
	host.set_climate_authority_override("force_on")
	var config := NewGameConfig.create_default()
	config.country.name = "C0 Worker"
	config.country.foreign_count = 1
	config.base.map_width = WIDTH
	config.base.map_height = HEIGHT
	config.base.initial_seed = SEED
	config.apply_land_layout("two")
	var session: Dictionary = host.configure_session({
		"kind": "new_game", "config": config.to_dictionary()})
	if not _require("worker session configures", bool(session.get("ok", false)),
			str(session)):
		return {}
	await host.generate_world(SEED)
	var generator: MapGenerator = host.get_generator()
	if not _require("production world generation succeeded", generator != null):
		return {}
	var ext = generator.get_data_core_world_ext()
	if not _require("production DCWorldExt is bound", ext != null):
		return {}
	var country_ir: Dictionary = CountryCatalogScript.compile_native_catalog()
	var catalog: Resource = load("res://data/ideologies/default_ideology_catalog.tres")
	var native: Dictionary = catalog.compile_native_catalog(country_ir, country_ir)
	ext.set_runtime_ideology_parity_enabled(true)
	ext.set_runtime_clock(true, WORKER_SPEED)
	_wait_worker_paused(ext)
	var handle := 0
	for cell in range(WIDTH * HEIGHT):
		handle = int(ext.get_country_cell_summary(cell).get("country_handle", 0))
		if handle != 0:
			break
	if not _require("worker path resolves the player country", handle != 0):
		return {}
	var tick := _drive_days(host, clock, ext, 0, 3)
	return {"host": host, "clock": clock, "ext": ext, "handle": handle,
		"tick": tick, "ids": native["ideology_ids"]}


## Grants the era technology and research signals a card's DISCOVER is gated on,
## through the same `CountryFacade` the research UI uses.
##
## The pod's `requirements_met` ANDs every requirement, so one missing signal makes
## DISCOVER return `ideology_discovery_not_allowed` -- which reaches GDScript as the
## generic `ideology_worker_rejected`. That is a fixture gap, not a content defect:
## in a real game the player's territory provides the signal.
func _grant_draw_gates(host: WorldRuntimeHost, card_id: String, handle: int,
		day: int) -> void:
	var catalog: Resource = load("res://data/ideologies/default_ideology_catalog.tres")
	if catalog == null:
		return
	var definition: Resource = null
	for row in catalog.definitions:
		if row != null and String(row.id) == card_id:
			definition = row
			break
	if definition == null:
		return
	var generator: MapGenerator = host.get_generator()
	if generator == null or not generator.has_method("get_country_facade"):
		return
	var facade = generator.get_country_facade()
	if facade == null:
		return
	var sequence := 900000
	for requirement in definition.draw_requirements:
		if requirement == null:
			continue
		var key := String(requirement.key)
		if int(requirement.kind) == 1:
			# GRANT_TECHNOLOGY: (handle, technology_id, effective_day, sequence).
			var granted: Dictionary = facade.grant_technology(
				handle, StringName(key), day, sequence)
			sequence += 1
			printerr("[gate] %s tech=%s ok=%s %s" % [card_id, key,
				str(granted.get("ok", false)), String(granted.get("reason", ""))])
		elif int(requirement.kind) == 2:
			# DISCOVER_COUNTRY_SIGNAL: (handle, signal_id, cell, source_kind,
			# effective_day, sequence) -- six arguments, and `source_kind` sits
			# BEFORE the day. Passing five silently shifts them.
			var discovered: Dictionary = facade.discover_research_signal(
				handle, StringName(key), 0, 0, day, sequence)
			sequence += 1
			printerr("[gate] %s signal=%s ok=%s %s" % [card_id, key,
				str(discovered.get("ok", false)),
				String(discovered.get("reason", ""))])


## Drives `days` worker days exactly like the parity driver: pulse the clock, drain
## the hard barriers, service the country worker peer, publish opinion inputs
## before stepping, then wait for the parked state.
func _drive_days(host: WorldRuntimeHost, clock: WorldClock, ext: Object,
		first_tick: int, days: int) -> int:
	var tick := first_tick
	for _day in range(days):
		tick += 1
		clock.current_day = float(tick)
		host.run_daily_tick(tick, clock.season_phase_for_day(tick))
		host.finish_daily_tick(0.0, {})
		var pulses := 0
		while _has_hard_barrier(clock) and pulses < 400:
			clock.simulation_backpressure_pulse.emit(tick)
			pulses += 1
		if ext.has_method("service_country_worker_peer_adapter"):
			ext.service_country_worker_peer_adapter(64, true)
		if ext.has_method("publish_ideology_worker_inputs"):
			ext.publish_ideology_worker_inputs()
		ext.set_runtime_clock(false, WORKER_SPEED)
		var deadline := Time.get_ticks_msec() + 2500
		while Time.get_ticks_msec() < deadline:
			if ext.has_method("service_country_worker_peer_adapter"):
				ext.service_country_worker_peer_adapter(64, true)
			OS.delay_msec(2)
			var state := String(ext.get_runtime_thread_report().get(
				"simulation_host_state", ""))
			if state == "PAUSED":
				break
		ext.set_runtime_clock(true, WORKER_SPEED)
		_wait_worker_paused(ext)
		OS.delay_msec(2)
	return tick


## `evaluate_modifier_stat(domain, entity_handle, group_handle, stat, base)`.
## Passing `base = 0.0` isolates the ADDITIVE part, which is how an additive card
## (消费税制) is measured: its design value is "+300 bp", not a ratio.
func _read(ext: Object, handle: int, stat: String, base: float = 1.0) -> float:
	return float(ext.evaluate_modifier_stat(MODIFIER_DOMAIN_COUNTRY, handle, 0, stat, base))


func _has_hard_barrier(clock: WorldClock) -> bool:
	for source in [&"economy_day_barrier", &"country_day_barrier",
			&"ideology_day_barrier", &"bio_occupancy_day_barrier",
			&"native_daily_day_barrier"]:
		if clock._simulation_backpressure_sources.has(source):
			return true
	return false


func _wait_worker_paused(ext, timeout_msec: int = 2500) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_msec
	while Time.get_ticks_msec() < deadline:
		var state := String(ext.get_runtime_thread_report().get(
			"simulation_host_state", ""))
		if state == "PAUSED":
			return true
		if state in ["STOPPED", "FAULTED"]:
			return false
		OS.delay_msec(2)
	return false


func _teardown(host: WorldRuntimeHost, clock: WorldClock) -> void:
	host.free()
	clock.free()


func _commands(rows: Array[Dictionary]) -> Dictionary:
	var count := rows.size()
	var opcodes := PackedInt32Array()
	var days := PackedInt64Array()
	var prio := PackedInt32Array()
	var prod := PackedInt32Array()
	var seqs := PackedInt64Array()
	var handles := PackedInt64Array()
	var ideas := PackedInt32Array()
	var values := PackedInt64Array()
	var gens := PackedInt64Array()
	var choices := PackedInt32Array()
	var gates := PackedInt32Array()
	for row in rows:
		opcodes.append(int(row.get("op", 0)))
		days.append(int(row.get("day", 0)))
		prio.append(0)
		prod.append(1)
		seqs.append(_next_sequence)
		_next_sequence += 1
		handles.append(int(row.get("handle", 0)))
		ideas.append(int(row.get("idea", -1)))
		values.append(int(row.get("value", 0)))
		gens.append(0)
		choices.append(-1)
		gates.append(-1)
	return {"opcodes": opcodes, "effective_days": days, "source_priorities": prio,
		"producer_ids": prod, "sequences": seqs, "country_handles": handles,
		"ideology_ids": ideas, "values_q16": values, "offer_generations": gens,
		"choice_indices": choices, "gate_ids": gates}


func _stage(text: String) -> void:
	printerr("[stage] %s" % text)


func _printerr_stage(text: String) -> void:
	printerr("[stage] %s" % text)


func _is_close(value: float, expected: float, tolerance: float) -> bool:
	return absf(value - expected) <= tolerance


func _expect(label: String, condition: bool, detail: String = "") -> void:
	_checks += 1
	if condition:
		return
	_failures += 1
	if detail.is_empty():
		push_error("[FAIL] %s" % label)
	else:
		push_error("[FAIL] %s (%s)" % [label, detail])


func _require(label: String, condition: bool, detail: String = "") -> bool:
	_expect(label, condition, detail)
	return condition


func _fail(label: String) -> void:
	_expect(label, false)
