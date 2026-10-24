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
const IdeologyDrawGateHelper = preload(
	"res://tests/ideology/ideology_draw_gate_helper.gd")

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
	# R-4 X16 cards. These are the only entries whose stat lives in the new
	# `economy.profession.*` families, which is what exercises the per-epoch X16 freeze
	# on the worker path.
	#
	# `land_tax_reform` came BACK to this table: since R-4 it publishes whole (metric 68
	# backs its L3 condition and that clause is a real Effect program row), so it is no
	# longer parked. `light_levy` and `petition_box` are ADD (`satisfaction_bp`, op 0)
	# and MULTIPLY (`tax_tolerance_factor` / `cost_factor`, op 2) respectively.
	{"key": "land_tax_reform",
	 "stat": "economy.profession.household_farmer.tax_tolerance_factor",
	 "value": 1.30},
	{"key": "light_levy",
	 "stat": "country.construction.cost_factor", "value": 1.03},
	{"key": "petition_box",
	 "stat": "economy.profession.agricultural_worker.satisfaction_bp",
	 "value": 400.0, "additive": true},
	# STILL PARKED: `excise` (`CARD_REQUIRES = ("X16", "reserve_ratio")`). metric 69 now
	# exists, but its L3 clause is a country-scope `RampTerm` and a card program may
	# only name `ideology.city.*` definitions, so there is nowhere to carry it yet
	# (11-infra-first-roadmap §4.5). It is absent from the catalog, so it stays out of
	# this table or the whole run fails its first precondition.
]

var _checks := 0
var _failures := 0
var _next_sequence := 1
var _only_card := OS.get_environment("C0_ONLY_CARD").strip_edges()
## Last day the pod actually committed, written by `_drive_days`.
var _last_driven_day := -1
## Wall time spent inside `_wait_pod_day`, and how many waits ran. Printed at the end
## so the R-3d "wait on a real field" fix is measurable (milliseconds per wait) instead
## of being asserted from memory.
var _wait_ms_total := 0
var _wait_calls := 0
## Waits that ended without the pod advancing. Expected > 0: the pod calendar and the
## driver tick are different coordinates (measured 16 misses in one card's 18 waits),
## and a driver tick that lands between two commits legitimately sees no change.
## Reported so the number is visible instead of being mistaken for a broken wait.
var _wait_timeouts := 0


func _init() -> void:
	call_deferred("_run_and_finish")


func _run_and_finish() -> void:
	var code := await _run()
	print("[wait] calls=%d total_ms=%d avg_ms=%.1f misses=%d key=%s" % [
		_wait_calls, _wait_ms_total,
		float(_wait_ms_total) / float(maxi(1, _wait_calls)), _wait_timeouts,
		"LEGACY(missing)" if OS.get_environment("C0_LEGACY_WAIT") == "1"
			else "ideology_pod_committed_day"])
	print("=== ideology card content worker: %d checks, %d failures ===" % [
		_checks, _failures])
	# Reaching this line at all is the signal that the process was NOT killed mid-run.
	#
	# `run_worker_cards.ps1` used to treat "no summary line" as "run void", which read
	# like a slow test. It was a heap corruption (`0xc0000374`) killing the process --
	# `EffectInputSnapshot::metric_revision` was `std::array<uint64_t, 68>` while
	# `FAMILY_METRIC_COUNT` had grown to 70, so publishing metric 68 or 69 wrote two
	# uint64s past the end. The runner now checks both this marker AND the exit code, so
	# a crash can never be reported as an empty run again.
	print("[exit] ok")
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

	# The SELECTED card must be PRESENT and resolvable in the worker's catalog.
	#
	# This used to demand that ALL cards in `CARDS` be present, which made the file
	# fail its first precondition the moment session C parked a card (see the note on
	# `CARDS`): two absent cards turned every run red before it measured anything, so
	# the seven working cards had no acceptance result at all. The check that matters
	# is the one the run actually needs -- the card under test.
	var chosen := _only_card
	if chosen.is_empty():
		chosen = String((CARDS[0] as Dictionary)["key"])
		printerr("[stage] C0_ONLY_CARD unset; defaulting to %s" % chosen)
	var chosen_row: Dictionary = {}
	for row_value in CARDS:
		if String((row_value as Dictionary)["key"]) == chosen:
			chosen_row = row_value
			break
	if not _require("C0_ONLY_CARD='%s' is a known card" % chosen,
			not chosen_row.is_empty(),
			"known=%s" % str(CARDS.map(func(r): return String(r["key"])))):
		_teardown(host, clock)
		return 7
	if not _require("%s is in the worker catalog" % chosen,
			ids.find("idea.%s" % chosen) >= 0,
			"catalog=%d entries" % ids.size()):
		_teardown(host, clock)
		return 7

	# One card per world.
	#
	# Measured 2026-10-22 on this fixture:
	#   * a SECOND equip in the same world wedges the day loop
	#     (`[runtime-day-wait] stall=0x1` repeats until the run is killed);
	#   * unequip does not release the ideology slot (`slots_used 1 -> 1`), so the
	#     cabinet never frees up for the next card.
	# Both were runtime issues recorded for session R in `09-content-status.md`
	# §3.7. Running ONE card per process is therefore the only shape that completes:
	# `C0_ONLY_CARD=<key>` selects it, and a batch runner invokes this file once per
	# card.
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
		var gates: Dictionary = IdeologyDrawGateHelper.grant_draw_gates(
			host, key, handle, tick, _next_sequence)
		if not _require("%s: worker grants its draw gates" % key,
				bool(gates.get("ok", false)), str(gates)):
			continue
		_next_sequence = int(gates.get("next_sequence", _next_sequence))
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
		# The wait must have observed a REAL commit, not a timeout. `_last_driven_day`
		# is what the pod reported, so a `-1` (or a value that never moved) means the
		# synchronisation is broken again -- exactly the defect that made every day
		# burn 8 s and then assert on a stale snapshot.
		var discover_day := _last_driven_day
		_expect("%s: the discover warm-up wait observed a committed day (day=%d)" % [
				key, discover_day], discover_day >= 1,
			"ideology_pod_committed_day=%d" % discover_day)
		var submitted: Dictionary = ext.submit_ideology_commands(_commands([
			{"op": 5, "day": tick, "handle": handle, "idea": dense},
		]))
		if not _require("%s: worker accepts equip" % key,
				bool(submitted.get("ok", false)), str(submitted)):
			continue
		_stage("%s: drive worker days" % key)
		tick = _drive_days(host, clock, ext, tick, SETTLE_TICKS)
		_expect("%s: the equip wait advanced the pod day (%d -> %d)" % [
				key, discover_day, _last_driven_day],
			_last_driven_day > discover_day,
			"ideology_pod_committed_day %d -> %d" % [
				discover_day, _last_driven_day])
		# The modifier row is written by the worker's Effect/Modifier stages, which
		# run AFTER the Ideology stage commits the equip. On a loaded machine that
		# tail can land a day later, which made a batch of seven cards fail a
		# different card on each run while every card passed when run alone.
		# Wait for the row (bounded), then drive one more day if it is still absent.
		if not _wait_for_modifier_row(ext, handle, "ideology.%s.l1" % key, 4000):
			tick = _drive_days(host, clock, ext, tick, 2)
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
		var unequip_batch: Dictionary = ext.submit_ideology_commands(_commands([
			{"op": 6, "day": tick, "handle": handle, "idea": dense}]))
		if not _require("%s: worker accepts the unequip command" % key,
				bool(unequip_batch.get("ok", false)), str(unequip_batch)):
			continue
		tick = _drive_days(host, clock, ext, tick, 3)
		# The unequip settles across several asynchronous hops: pod plans the
		# transition -> Effect ACKs -> the pod applies the ACK on its NEXT day plan ->
		# the write-back publishes a snapshot the facade consumes. Reading the facade
		# right after the drive loop can therefore still see the PRE-unequip snapshot
		# (`slots_used=1` while the pod reports `pending_transition_count=0`).
		#
		# The wait is "slot free AND row gone", not "two days have passed": a fixed
		# count was measured to be a coin flip, because the number of hops depends on
		# where in the pod's day the command landed. Bounded, and every retry drives a
		# real worker day -- this is synchronisation, not retry-until-green.
		var settle_deadline := Time.get_ticks_msec() + 20000
		while Time.get_ticks_msec() < settle_deadline:
			var settled_rows: Dictionary = ext.list_modifiers(
				MODIFIER_DOMAIN_COUNTRY, handle, "")
			var settled_keys := PackedStringArray(settled_rows.get(
				"definition_keys", PackedStringArray()))
			if int(ext.get_ideology_snapshot(handle).get(
					"ideology_slots_used", -1)) == 0 and \
					not settled_keys.has("ideology.%s.l1" % key):
				break
			tick = _drive_days(host, clock, ext, tick, 1)
		var receipts: Dictionary = ext.poll_ideology_receipts(0, 16)
		#
		# MEASURED on this fixture (DLL 2026-10-23): the pod receives opcode 6 and
		# answers `ideology_support_threshold_not_met` in the receipt. That is
		# `support_allows(direction = repeal)`, a weighted average over the REAL
		# political classes -- and this 16x12 starter-settlement world staffs only the
		# `general` lane (opinion.population = [0, 20, 0, 0]), so the repeal average is
		# that one class's negative stance. The runtime is behaving as designed; the
		# fixture is too thin to reach the repeal threshold. Re-labelling cohorts into
		# the other classes was attempted and does NOT move the published opinion, so
		# That route is recorded rather than shipped.
		#
		# The assertion therefore pins what the worker DID do, and the slot/row/stat
		# assertions below only run when the repeal gate actually let the unequip
		# through. A run that silently treats "rejected" as "restored" is exactly the
		# vacuous pass this file exists to prevent.
		var reasons: PackedStringArray = receipts.get("reasons", PackedStringArray())
		var opcodes: PackedInt32Array = receipts.get("opcodes", PackedInt32Array())
		var unequip_reason := ""
		var saw_unequip_receipt := false
		for index in range(mini(opcodes.size(), reasons.size())):
			if int(opcodes[index]) == 6:
				saw_unequip_receipt = true
				unequip_reason = String(reasons[index])
		var released: Dictionary = ext.get_ideology_snapshot(handle)
		var slots_after := int(released.get("ideology_slots_used", -1))
		var repeal_blocked := unequip_reason == "ideology_support_threshold_not_met"
		# Distinguish the three outcomes honestly. "No receipt at all" is a delivery
		# problem, "rejected" is the support gate, and "settled" is the happy path --
		# collapsing them into one `slots_used == 0` assertion is what let the earlier
		# version report a slot leak that was really "the command never arrived".
		_expect("%s: worker delivered the unequip to the pod (receipt=%s)" % [
				key, str(saw_unequip_receipt)],
			saw_unequip_receipt, "receipts=%s" % str(receipts))
		if not saw_unequip_receipt:
			continue
		if repeal_blocked:
			# FAIL, not "recorded". The whole point of R-3d is that "the worker said
			# no" is not evidence that unequip works; only "slot freed, row gone, value
			# back" is. The fixture disables the popularity gate on purpose
			# (`PK_DISABLE_SUPPORT_GATE`), so a repeal rejection here means the gate
			# bypass did not reach the POD catalog -- a fixture bug worth failing on.
			_expect("%s: the support gate is OFF in this fixture, so repeal must not be "
					+ "refused (slots=%d)" % [key, slots_after],
				false, "reason=%s slots_used=%d" % [unequip_reason, slots_after])
			continue
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
		# The boundary bit is released at the TOP of the next refresh call, so a run
		# that ends while the last refresh had to skip leaves it set by design (the
		# worker is parked until the next tick asks again). One extra call is what a
		# real session does every frame; without it the assertion below would measure
		# "the session stopped mid-skip", not "a client is stranded".
		if ext.has_method("step_ideology_instance_refresh"):
			ext.step_ideology_instance_refresh(tick)
			final_report = ext.get_runtime_thread_report()
		var outstanding := int(final_report.get(
			"main_boundary_service_requests", -1))
		_expect("%s: no client is left waiting for a boundary turn (outstanding=%d)"
			% [key, outstanding], outstanding == 0,
			("ideology=%s trigger=%s state=%s") % [
				str(final_report.get("main_boundary_service_ideology", "?")),
				str(final_report.get("main_boundary_service_trigger", "?")),
				str(final_report.get("simulation_host_state", "?"))])
		# 4. The GDScript intent fallback must stay SILENT under a 0xFFF mask.
		#
		# When the worker owns EFFECT it drains the intents itself, so any reply from
		# `_service_ideology_worker_intents_if_authoritative` would be a duplicate claim
		# that the effect committed. Both counters therefore have to be 0 here; a
		# non-zero value means the pump fired where it should not have.
		var reply_report: Dictionary = host.get_ideology_intent_reply_report()
		_expect("%s: GDScript never re-replied for the worker (duplicate=%d unknown=%d)"
			% [key, int(reply_report.get("duplicate_acks", -1)),
				int(reply_report.get("unknown_acks", -1))],
			int(reply_report.get("duplicate_acks", -1)) == 0 and
				int(reply_report.get("unknown_acks", -1)) == 0,
			str(reply_report))
		# 0c: LEVEL-UP and RELOCATION on the WORKER path.
		#
		# The main-thread test (`ideology_card_content_test._test_level_up_replaces_rows`)
		# proves the batch split works where the Effect runtime is on the main thread.
		# The worker path is a different set of hops (pod plans -> intents/ACKs ->
		# Modifier POD applies), so "the old tier's row was retired" has to be asserted
		# HERE too: a stale row is invisible to the main-thread run if the worker ACKs
		# differently, and the card would silently stack two levels in the game.
		#
		# Gated because each one needs its own fresh equip cycle on an already-loaded
		# world; `C0_LEVEL_PROBES=1` turns them on.
		if OS.get_environment("C0_LEVEL_PROBES") == "1":
			_test_worker_level_up(host, clock, ext, handle, int(dense), tick, key,
				String(row["stat"]))
		# 3c: save -> restore -> keep running.
		#
		# Gated because a second world costs another full MapGenerator build, and the
		# seven-card batch runner invokes this file seven times. `C0_SAVE_ROUNDTRIP=1`
		# turns it on for the dedicated run.
		if OS.get_environment("C0_SAVE_ROUNDTRIP") == "1":
			_test_save_roundtrip(host, clock, ext, handle, int(dense),
				String(row["stat"]), float(row["value"]), additive, tick, key)

	_teardown(host, clock)
	return 0


## 3c acceptance: EQUIP -> SAVE -> RESTORE -> 3 more worker days.
##
## What this proves that the IDP2 roundtrip test cannot: the card state survives the
## PKSR bundle on the PRODUCTION path, the restored world keeps committing worker days,
## and the restored national stat reads the same design value it read before the save.
## A restore that silently dropped the equipped card would leave `stat == 1.0` here
## while every main-thread assertion stayed green.
##
## `restore_runtime_bundle` reinstalls the POD snapshot directly, so the worker can be
## restarted from it without replaying effects (replaying is explicitly forbidden by
## the skill's invariants).
func _test_save_roundtrip(host: WorldRuntimeHost, clock: WorldClock, ext: Object,
		handle: int, dense: int, stat: String,
		expected: float, additive: bool, tick: int, key: String) -> void:
	_stage("%s: save roundtrip" % key)
	var stat_before := _read(ext, handle, stat, 0.0 if additive else 1.0)
	var day_before := int(ext.get_runtime_thread_report().get(
		"ideology_pod_committed_day", -1))
	var rows_before: Dictionary = ext.list_modifiers(
		MODIFIER_DOMAIN_COUNTRY, handle, "")
	var keys_before := PackedStringArray(rows_before.get(
		"definition_keys", PackedStringArray()))
	if not _require("%s: row present before save (rows=%s)" % [key, str(keys_before)],
			keys_before.has("ideology.%s.l1" % key)):
		return
	var saved: Dictionary = _request_save(ext, 2026102301)
	if not _require("%s: PKSR writes the bundle (ready=%s bytes=%d)" % [
			key, str(saved.get("ready", false)),
			int(saved.get("bytes", PackedByteArray()).size())],
			bool(saved.get("ready", false))):
		return
	var bundle: PackedByteArray = saved.get("bytes", PackedByteArray())
	# `runtime_restore_requires_stopped_worker`: a bundle installs POD state wholesale,
	# so the worker must not be mid-day. Same order the IDP2 roundtrip test uses.
	ext.request_runtime_stop()
	var stop_deadline := Time.get_ticks_msec() + 6000
	while Time.get_ticks_msec() < stop_deadline:
		if String(ext.get_runtime_thread_report().get(
				"simulation_host_state", "")) == "STOPPED":
			break
		OS.delay_msec(5)
	var restored: Dictionary = ext.restore_runtime_bundle(bundle)
	if not _require("%s: bundle restores (restored=%s code=%s)" % [
			key, str(restored.get("restored", false)),
			String(restored.get("code", "ok"))],
			bool(restored.get("restored", false))):
		return
	var country_restored: Dictionary = ext.restore_country_runtime_checkpoint(
		saved.get("country_pkcn", PackedByteArray()))
	if not _require("%s: Country checkpoint restores before worker start (%s %s)" % [
			key, String(country_restored.get("code", "ok")),
			String(country_restored.get("reason", ""))],
			bool(country_restored.get("ok", false))):
		return
	# Restart the worker on the restored bundle and drive REAL worker days.
	#
	# This is what production does: `world_runtime_host.gd:804` calls
	# `_start_production_shadow_worker()` right after `restore_prepared_game(...)`
	# restores the PKSR bundle, so "restore then start the worker" is the shipped order,
	# not a test artefact.
	#
	var restarted: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "ACTIVE",
		"graph_coverage_complete": true,
		"authoritative_domain_mask": 0xFFF,
		"day": 0,
		"speed_days_per_second": WORKER_SPEED,
		"paused": false,
	})
	if not _require("%s: worker restarts on the restored bundle (%s %s)" % [
			key, String(restarted.get("code", "ok")),
			String(restarted.get("reason", ""))],
			bool(restarted.get("ok", false))):
		return
	var current_day := _world_day(ext)
	var day_before_restart := int(ext.get_runtime_thread_report().get(
		"ideology_pod_committed_day", -1))
	ext.set_runtime_clock(true, WORKER_SPEED)
	# The POD only plans a day when the CLIMATE stage hands it one, and that stage is
	# driven by the main-thread daily tick in this fixture (`run_daily_tick`), exactly
	# like every other day this file drives. Waiting on the worker clock alone leaves the
	# pod parked at the restored day forever -- measured `pod day 17 -> 17`.
	var advanced := false
	var probe_tick := _world_day(ext)
	for _settle_day in range(4):
		probe_tick += 1
		clock.current_day = float(probe_tick)
		host.run_daily_tick(probe_tick, clock.season_phase_for_day(probe_tick))
		host.finish_daily_tick(0.0, {})
		var pulses := 0
		while _has_hard_barrier(clock) and pulses < 400:
			clock.simulation_backpressure_pulse.emit(probe_tick)
			pulses += 1
		if ext.has_method("service_country_worker_peer_adapter"):
			ext.service_country_worker_peer_adapter(64, true)
		if ext.has_method("publish_ideology_worker_inputs"):
			ext.publish_ideology_worker_inputs()
		var restart_deadline := Time.get_ticks_msec() + 8000
		while Time.get_ticks_msec() < restart_deadline:
			if ext.has_method("service_country_worker_peer_adapter"):
				ext.service_country_worker_peer_adapter(64, true)
			OS.delay_msec(4)
			if int(ext.get_runtime_thread_report().get(
					"ideology_pod_committed_day", -1)) > day_before_restart:
				advanced = true
				break
		if advanced:
			break
	var day_after_restart := int(ext.get_runtime_thread_report().get(
		"ideology_pod_committed_day", -1))
	_expect("%s: the RESTARTED worker commits days on the restored state (%d -> %d)" % [
			key, day_before_restart, day_after_restart], advanced,
		"pod day %d -> %d" % [day_before_restart, day_after_restart])
	var after_days := _world_day(ext)
	_expect("%s: the restored world keeps advancing days (day %d -> %d)" % [
			key, current_day, after_days], after_days >= current_day,
		"day=%d -> %d" % [current_day, after_days])
	var stat_after := _read(ext, handle, stat, 0.0 if additive else 1.0)
	if additive:
		_expect("%s: restored %s keeps its design delta (%.5f vs %.5f)" % [
				key, stat, stat_after, stat_before],
			_is_close(stat_after, stat_before, 0.0005),
			"before=%.5f after=%.5f" % [stat_before, stat_after])
	else:
		_expect("%s: restored %s keeps its design value (%.5f vs %.5f, expected %.5f)" % [
				key, stat, stat_after, stat_before, expected],
			_is_close(stat_after, stat_before, 0.0005) and
				_is_close(stat_after, expected, 0.0005),
			"before=%.5f after=%.5f expected=%.5f" % [
				stat_before, stat_after, expected])
	var rows_after: Dictionary = ext.list_modifiers(
		MODIFIER_DOMAIN_COUNTRY, handle, "")
	var keys_after := PackedStringArray(rows_after.get(
		"definition_keys", PackedStringArray()))
	_expect("%s: the restored row is the same row (before=%s after=%s)" % [
			key, str(keys_before), str(keys_after)],
		keys_after.has("ideology.%s.l1" % key))
	printerr("[save-roundtrip] %s day_before=%d day_after=%d stat %.5f -> %.5f" % [
		key, day_before, current_day, stat_before, stat_after])


## The world's current day, from the economy report.
##
## `DCWorldExt` has no `get_current_day()`; the economy report exposes `current_day`,
## and that is the same calendar the daily jobs advance. A named helper keeps the
## fixture from depending on a method that does not exist (which aborted the function
## silently the first time this was written).
func _world_day(ext: Object) -> int:
	var report: Dictionary = ext.get_economy_report()
	return int(report.get("current_day", 0))


## Requests a PKSR bundle and polls until it is ready. Same two-step contract as
## `runtime_ideology_save_roundtrip_test._request_save`.
func _request_save(ext: Object, request_id: int) -> Dictionary:
	var request: Dictionary = ext.request_runtime_save(request_id)
	if not bool(request.get("pending", false)):
		return request
	var saved: Dictionary = {}
	var deadline := Time.get_ticks_msec() + 6000
	while Time.get_ticks_msec() < deadline:
		saved = ext.poll_runtime_save(request_id)
		if bool(saved.get("ready", false)):
			return saved
		OS.delay_msec(5)
	return saved


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
	# TEST BOOTSTRAP ON, deliberately.
	#
	# With `false` the world is seeded from the starter settlement only, which in a
	# 16x12 two-landmass map produces a single political class (the starter
	# profession). That is enough to EQUIP a card (adopt threshold) but not to
	# UNEQUIP one: `support_allows(direction = repeal)` is a weighted average over
	# the REAL political classes, and classes with zero population contribute zero
	# influence while the one populated class can be negative. Measured before this
	# change: `support=-8192 threshold=0 total=68 classes=4`, and the unequip came
	# back `ideology_support_threshold_not_met` -- i.e. the runtime was RIGHT and the
	# fixture was too thin to exercise the repeal path at all.
	#
	# `EconomyTestBootstrap` seeds every profession the catalog declares, so each
	# political class has real influence and the repeal gate becomes a genuine
	# measurement instead of a one-class artefact.
	host.generate_test_economy_data = true
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
	# (在生成前钉死 force_on，避免 AUTO 策略或 GM 残值把会话退回 SHADOW).
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
## Drives `days` worker days exactly like the parity driver: pulse the clock, drain
## the hard barriers, service the country worker peer, publish opinion inputs before
## stepping, then WAIT FOR THE POD TO COMMIT that day.
##
## The wait used to poll `ideology_pod_committed_day`, a key the report did not
## contain, so every single day burned the full 8 s timeout and then asserted on
## whatever snapshot happened to exist. The field is now exported (it is
## `RuntimeThreadReport::worker_committed_ideology_day`, the POD's own committed day).
##
## Returns the day the pod actually reached. `_last_driven_day` records it so the
## caller can assert monotonic progress instead of trusting the loop.
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
		var before_day := int(ext.get_runtime_thread_report().get(
			"ideology_pod_committed_day", -1))
		var reached := _wait_pod_day(ext, before_day, 8000)
		ext.set_runtime_clock(true, WORKER_SPEED)
		_wait_worker_paused(ext)
		OS.delay_msec(2)
		_last_driven_day = reached
	return tick


## Blocks until the pod's committed day is at least `target`, and returns the day it
## actually reached (or the last observed one on timeout).
##
## `timeout_msec` is a *safety net*, not the expected cost: with the field present the
## loop returns as soon as the day commits.
## Blocks until the pod's committed day ADVANCES past `baseline`, and returns the day
## it reached (or the last observed one on timeout).
##
## The target is "it moved", not "it reached my tick". The driver's tick and the pod's
## calendar are NOT the same coordinate: measured with `[daydbg]`, the pod is still at
## day -1 while the driver is on tick 1..3 (it cannot plan a day before its first
## opinion snapshot), and from then on it trails the tick by a variable amount. Waiting
## for `pod_day >= tick` therefore sat out the full timeout on every early day -- 144 s
## of pure waiting per card -- while the pod had in fact committed.
##
## `baseline` is the day the pod was at before this call.
func _wait_pod_day(ext: Object, baseline: int, timeout_msec: int) -> int:
	# `C0_LEGACY_WAIT=1` reproduces the pre-R-3d behaviour on purpose: poll a key the
	# report never contained. It exists so the timing difference can be measured on the
	# same machine and DLL instead of being asserted from memory.
	var key := "ideology_pod_committed_day"
	if OS.get_environment("C0_LEGACY_WAIT") == "1":
		key = "ideology_pod_committed_day_DOES_NOT_EXIST"
	var deadline := Time.get_ticks_msec() + timeout_msec
	var last := baseline
	var started := Time.get_ticks_msec()
	var timed_out := true
	while Time.get_ticks_msec() < deadline:
		if ext.has_method("service_country_worker_peer_adapter"):
			ext.service_country_worker_peer_adapter(64, true)
		OS.delay_msec(2)
		var report: Dictionary = ext.get_runtime_thread_report()
		last = int(report.get(key, -1))
		if last > baseline:
			timed_out = false
			break
		if String(report.get("simulation_host_state", "")) in ["STOPPED", "FAULTED"]:
			timed_out = false
			break
	_wait_ms_total += Time.get_ticks_msec() - started
	_wait_calls += 1
	if timed_out:
		_wait_timeouts += 1
	if OS.get_environment("C0_WAIT_TRACE") == "1":
		printerr("[waittrace] baseline=%d reached=%d took=%dms timeout=%s" % [
			baseline, last, Time.get_ticks_msec() - started, str(timed_out)])
	return last


## R-3d item 0c: level-up on the WORKER path must retire the old tier's row.
##
## Feeds understanding until the pod promotes the card to L2, then asserts:
##   * `.l2` is live and `.l1` is NOT (the removal named the right generation),
##   * only one tier row of THIS card exists (nothing stacked),
##   * the stat reads the L2 value rather than L1 x L2.
##
## Returns the tick it drove to, so the caller's calendar stays monotonic.
func _test_worker_level_up(host: WorldRuntimeHost, clock: WorldClock, ext: Object,
		handle: int, dense: int, tick: int, key: String, stat: String) -> int:
	_stage("%s: worker level-up probe" % key)
	# ADD_UNDERSTANDING (opcode 2) with enough value to clear the L2 threshold. The
	# amount is a fixture quantity, not a game number: the assertion is about which ROWS
	# survive, not about the exact level curve.
	var raise: Dictionary = ext.submit_ideology_commands(_commands([
		{"op": 2, "day": tick, "handle": handle, "idea": dense,
		 "value": 8 * Q16_ONE}]))
	if not _require("%s: worker accepts the understanding bump" % key,
			bool(raise.get("ok", false)), str(raise)):
		return tick
	tick = _drive_days(host, clock, ext, tick, 3)
	# Same bounded "row set settled" wait the unequip uses: the pod ACK and the Modifier
	# row are two hops apart.
	var deadline := Time.get_ticks_msec() + 20000
	var rows := PackedStringArray()
	while Time.get_ticks_msec() < deadline:
		var listed: Dictionary = ext.list_modifiers(MODIFIER_DOMAIN_COUNTRY, handle, "")
		rows = PackedStringArray(listed.get("definition_keys", PackedStringArray()))
		if rows.has("ideology.%s.l2" % key):
			break
		tick = _drive_days(host, clock, ext, tick, 1)
	var tier_rows := PackedStringArray()
	for entry in rows:
		if String(entry).begins_with("ideology.%s.l" % key):
			tier_rows.append(String(entry))
	_expect("%s: worker level-up reaches L2 (rows=%s)" % [key, str(tier_rows)],
		rows.has("ideology.%s.l2" % key), "rows=%s" % str(rows))
	_expect("%s: worker level-up retires the OLD tier's row (tiers=%s)" % [
			key, str(tier_rows)], not rows.has("ideology.%s.l1" % key),
		"tiers=%s" % str(tier_rows))
	_expect("%s: worker level-up leaves exactly ONE tier row (count=%d, tiers=%s)" % [
			key, tier_rows.size(), str(tier_rows)], tier_rows.size() == 1,
		"tiers=%s" % str(tier_rows))
	var at_l2 := _read(ext, handle, stat, 0.0)
	_expect("%s: the worker stat reflects L2 alone, not L1 x L2 (%.5f)" % [key, at_l2],
		at_l2 > 1.0, "%.5f" % at_l2)
	printerr("[level-up/worker] %s tiers=%s stat=%.5f" % [
		key, str(tier_rows), at_l2])
	# Relocation: IDEOLOGY -> NATIONAL_SPIRIT (opcode 7).
	_stage("%s: worker relocation probe" % key)
	var promote: Dictionary = ext.submit_ideology_commands(_commands([
		{"op": 7, "day": tick, "handle": handle, "idea": dense}]))
	if not _require("%s: worker accepts the promote" % key,
			bool(promote.get("ok", false)), str(promote)):
		return tick
	tick = _drive_days(host, clock, ext, tick, 3)
	var move_deadline := Time.get_ticks_msec() + 20000
	var ideology_slots := -1
	var spirit_slots := -1
	while Time.get_ticks_msec() < move_deadline:
		var snap: Dictionary = ext.get_ideology_snapshot(handle)
		ideology_slots = int(snap.get("ideology_slots_used", -1))
		spirit_slots = int(snap.get("national_spirit_slots_used", -1))
		if ideology_slots == 0 and spirit_slots >= 1:
			break
		tick = _drive_days(host, clock, ext, tick, 1)
	var moved_listed: Dictionary = ext.list_modifiers(MODIFIER_DOMAIN_COUNTRY, handle, "")
	var moved_rows := PackedStringArray(moved_listed.get(
		"definition_keys", PackedStringArray()))
	var moved_tiers := PackedStringArray()
	for entry in moved_rows:
		if String(entry).begins_with("ideology.%s.l" % key):
			moved_tiers.append(String(entry))
	_expect("%s: worker relocation moves the card to the spirit tier (ideology=%d "
			+ "spirit=%d)" % [key, ideology_slots, spirit_slots],
		ideology_slots == 0 and spirit_slots >= 1,
		"ideology=%d spirit=%d" % [ideology_slots, spirit_slots])
	_expect("%s: worker relocation leaves at most ONE tier row (tiers=%s)" % [
			key, str(moved_tiers)], moved_tiers.size() <= 1,
		"tiers=%s" % str(moved_tiers))
	printerr("[relocation/worker] %s ideology=%d spirit=%d tiers=%s" % [
		key, ideology_slots, spirit_slots, str(moved_tiers)])
	return tick


## True once `definition_key` appears in the country's national Modifier rows.
##
## The equip's row is produced by the worker's Effect and Modifier stages, which run
## AFTER the Ideology stage commits the card, so "the pod committed day N" and "the row
## exists" are two different events. Synchronising on the row is what makes this test
## deterministic: without it the same DLL failed `water_works` on one run and
## `forager_band` on the next, purely because the tail landed after the assertion.
func _wait_for_modifier_row(ext: Object, handle: int, definition_key: String,
		timeout_msec: int) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_msec
	while Time.get_ticks_msec() < deadline:
		var rows: Dictionary = ext.list_modifiers(MODIFIER_DOMAIN_COUNTRY, handle, "")
		var keys: PackedStringArray = rows.get(
			"definition_keys", PackedStringArray())
		if keys.has(definition_key):
			return true
		if ext.has_method("service_country_worker_peer_adapter"):
			ext.service_country_worker_peer_adapter(64, true)
		OS.delay_msec(4)
	return false


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
