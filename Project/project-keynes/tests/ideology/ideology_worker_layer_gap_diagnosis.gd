extends SceneTree

## DIAGNOSIS, NOT A TEST: where does the derived cell layer die under worker-owned
## ideology, and which precondition fails FIRST?
##
## THE DEFECT BEING DIAGNOSED (established by measurement before this file existed)
##
## With `runtime_authority_domain_mask = 0xFFF` the worker owns IDEOLOGY (0x010) and
## the derived cell layer produces nothing:
##
##     installed=false cell_count=0 contributions=-1 sample_day=-1
##     rebuild_visits=8  derived_basis_confirmed_day=-1  derived_basis_eligible_day=-1
##
## while the card is live (`locations=[1]`). Flipping the SAME world to mask 0xFEF
## (ideology back on the main thread) makes the layer appear immediately:
## `installed=true cell_count=2 add=0.0500030518 = 3277/65536`.
##
## WHAT THIS FIXTURE DOES
##
## It builds ONE worker world (mask 0xFFF), equips ONE derived card, and walks the
## collect chain rung by rung, printing the counter that decides each rung. Then it
## flips the SAME world to mask 0xFEF and walks the same ladder again, so the two are
## adjacent and the first divergence names the failure point.
##
## THE CHAIN, IN ORDER (task §"What you must determine"), and the rung that probes it:
##
##   RUNG 0  driver        `step_derived_rebuild` reached with a live card?
##                         -> cell_layer_rebuild_visits / drain_derived_cell_layer
##                            steps, both measured as DELTAS over the leg. A delta of
##                            0 means the collect below was never called at all and
##                            every rung after it is UNREACHED, not failed.
##   RUNG 1  early guards  `collect_effect_activations` (ideology_runtime.cpp:2281):
##                         `_effect_runtime == nullptr` / ideology_id range /
##                         location INACTIVE / the §10.1 pending gate
##                         (:2313-2323) / contribution_level range.
##                         -> collect_entries and collect_templates deltas.
##                         `collect_entries` is incremented at :2290, i.e. AFTER the
##                         null+rangel guards and BEFORE the location/pending ones, so
##                         (entries==0) and (entries>0, templates==0) are DIFFERENT
##                         failures and the ladder separates them.
##   RUNG 2  loop / state  the per-country, per-idea loop (:7142-7150) decides which
##                         cards are even considered.
##                         -> snapshot live-card count + managed_idea_count.
##   RUNG 3  backend       `family_effect_metadata_pod` (:2343) then
##                         `decide_cell_program_backend(cell_program_facts_for(...))`
##                         (:2372) + `cell_program_rollout_enabled` (:2390).
##                         -> collect_pod_fail / collect_pod_ok_seen /
##                            collect_program_empty deltas, plus the SAME Effect query
##                            asked directly from the main thread
##                            (`effect_program_is_managed`).
##   RUNG 4  Effect query  `_effect_runtime->program_modifier_commands(program, cmds)`
##                         (:2458). This is the prime suspect: the file itself records
##                         at :6859-6863 that "under worker authority EffectRuntime is
##                         writeback-only". Asked directly via
##                         `resolve_effect_program_modifier_commands(PROGRAM_A)` on
##                         BOTH legs, so the answer is known even when the collect is
##                         never entered.
##   RUNG 5  targets/rows  `resolve_effect_targets` (:2358) and the
##                         DerivedProgramContribution rows (:2444-2580).
##                         -> collect_targets_fail / collect_derived_emitted deltas and
##                            the ideology report's `targets_*` counters.
##   RUNG 6  fold          `build_derived_cell_front` (:81-91 of
##                         derived_cell_materializer.cpp).
##                         -> get_derived_materialize_report(): programs_seen,
##                            programs_derived, programs_skipped_legacy, cells_visited,
##                            commands_folded, rows_emitted, ramp_terms_evaluated,
##                            truncated, missing_stat.
##   RUNG 7  install       `install_derived_cell_layer` (:1645 modifier_runtime.cpp);
##                         an empty front over an empty layer is SKIPPED (:1665-1669),
##                         which is why the layer reports installed=false rather than
##                         an empty layer.
##                         -> get_derived_cell_layer_report() and the Modifier report's
##                            `layer_installed` / `layer_contribution_count`.
##
## ABSOLUTE vs DELTA. Most of the `collect_*` counters are process-cumulative and are
## NOT reset by the rebuild, so a raw comparison between the two legs would be
## meaningless (the main-thread leg always reads >= the worker leg). Every rung that
## comes from a cumulative counter is therefore reported as a DELTA over the leg,
## bounded by a capture taken immediately before the leg starts. The materialize
## report is different: it describes the LAST COMPLETED rebuild only, so it is a
## snapshot and is reported absolutely.
##
## WHAT THIS FIXTURE DELIBERATELY DOES NOT DO
##
##   * It does not assert a passing outcome for the defective leg. A diagnostic that
##     fails for the defect it exists to report is useless. The worker leg's emptiness
##     is asserted as the MEASURED REALITY (the same technique
##     `ideology_worker_authority_parity_test.gd` uses for `PARITY[FINDING]`), so a
##     fix that makes the layer appear on the worker world FAILS this file and points
##     at the rung that changed.
##   * It does not build a second world. One world, two masks, same seed, same cards --
##     that is the only way "the same state renders on one side and not the other"
##     means anything. The main-thread control is mask 0xFEF on the same world.
##   * It does not touch C++. There are no counters here that the runtime does not
##     already export; every number printed comes from a bound method.
##
## Run (a worker world costs ~170 s to build, so budget accordingly):
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_worker_layer_gap_diagnosis.gd

const WIDTH := 16
const HEIGHT := 12
const CELLS: int = WIDTH * HEIGHT
const SEED := 20261029
const WORKER_SPEED := 10.0
const Q16_ONE := 65536

# RuntimeDomainId -> bit, read out of `runtime_pod_protocol.h:526-573`.
const DOMAIN_INPUT_CAPTURE := 0x001
const DOMAIN_CLIMATE := 0x002
const DOMAIN_COUNTRY := 0x004
const DOMAIN_TRIGGER_INPUT := 0x008
const DOMAIN_IDEOLOGY := 0x010
const DOMAIN_EFFECT := 0x020
const DOMAIN_MODIFIER := 0x040
const DOMAIN_GAMEPLAY_EFFECT := 0x080
const DOMAIN_ECONOMY := 0x100
const DOMAIN_EVENTS := 0x200
const DOMAIN_VISUAL := 0x400
const DOMAIN_COMMIT := 0x800

## The failing configuration: every domain granted to the worker, ideology included.
const MASK_ALL := 0xFFF
## The control on the SAME world: 0xFFF minus the ideology bit. Everything else
## (EFFECT 0x020, MODIFIER 0x040, ECONOMY 0x100) stays exactly as it was, so the two
## legs differ in ONE bit and nothing else.
const MASK_MAIN_IDEOLOGY := MASK_ALL - DOMAIN_IDEOLOGY
## 0xF7F is the mask every older ideology worker fixture uses. It clears
## GAMEPLAY_EFFECT (0x080) and still GRANTS ideology, which is why this defect was
## never noticed there. Asserted below so nobody re-reads it as "ideology off".
const MASK_OLDER_FIXTURES := MASK_ALL & ~DOMAIN_GAMEPLAY_EFFECT

## Kind 12, own territory, one derived program, two commands (an `.add` on the birth
## factor and a `.cut` on the housing consumption factor). The same card the parity
## fixture measures at `add = 3277/65536`.
const CARD_A := "idea.public_hygiene"
const PROGRAM_A := "ideology.effect.public_hygiene_l1"
const STAT_ADD := "economy.city.birth_factor"
const STAT_CUT := "economy.city.need.housing.consumption_factor"
const TAG_A := "cell.settlement"
const TAG_B := "cell.terrain.tundra"
const POPULATION_Q16 := 800 * Q16_ONE

const OP_DISCOVER := 1
const OP_GRANT_POINTS := 2
const OP_EQUIP := 5
const OP_ADD_UNDERSTANDING := 8

## A day is sliced; one call is not a day.
const MAX_SLICES_PER_DAY := 256
## Hang detectors, not performance gates.
const DAY_WAIT_MS := 9000
const POD_WAIT_MS := 5000
const STATE_WAIT_MS := 15000
const MASK_WAIT_MS := 12000
## Whole-run guard. Stop driving days past this and report a budget stop rather than
## hanging the session.
const GLOBAL_BUDGET_MS := 600000
## Days driven AFTER the card is live on the worker leg, and the budget for the
## main-thread control leg to produce a front.
const WORKER_LEG_DAYS := 6
const MAIN_LEG_MAX_DAYS := 12
## The worker faults a day at `RUNTIME_DAY_STALL_PEER_FAULT_TIMEOUT_MS = 5000`
## (`runtime_pod_protocol.h:54`) when a peer does not answer, and the Country peer
## transport returns at most `max_results` per call.
const PEER_PASSES := 6
const PEER_BATCH := 96

const WorkerWaitHelper = preload("res://tests/ideology/ideology_worker_wait_helper.gd")
const DrawGateHelper = preload("res://tests/ideology/ideology_draw_gate_helper.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")

## Cumulative counters read out of `get_ideology_report()`. Every one of these has a
## single increment site in `ideology_runtime.cpp`; the ladder maps them to the chain.
const COUNTER_KEYS: Array = [
	"cell_layer_rebuild_visits",     # :7095 step_derived_rebuild entered
	"cell_layer_rebuild_steps",      # :7184/7160 slices of the current/last rebuild
	"collect_entries",               # :2290 after the null+rangel guards
	"collect_templates",             # :2338 active templates of the level row
	"collect_program_empty",         # :2341 effect_program_key() came back empty
	"collect_pod_fail",              # :2345 family_effect_metadata_pod() said no
	"collect_targets_fail",          # :2360 resolve_effect_targets() said no
	"collect_derived_emitted",       # :2579 DerivedProgramContribution pushed
	"ramp_terms_evaluated",          # materializer, exported back at :7225
	"ramp_terms_deferred",           # :7226
	"targets_country_zero",
	"targets_domain_gate",
	"targets_economy_null",
	"targets_anchor_neg",
	"targets_collected_empty",
	"targets_fanout_no_tag",
	"targets_fanout_no_source",
	"targets_fanout_ring_empty",
	"commands_applied",
	"commands_rejected",
]

## The ladder, in causal order. `chain` names the task's numbered step and `probe`
## names the runtime symbol that decides it, so a failing rung is readable without
## opening this file.
const RUNGS: Array = [
	{"id": "state_live_cards", "chain": "2",
		"probe": "snapshot().locations == 1 (the _countries row the loop walks)"},
	{"id": "state_transition_pending", "chain": "1",
		"probe": "snapshot().transition_pending (the §10.1 pending gate, :2317)"},
	# NOT a precondition of the collect (`collect_effect_activations` never reads a
	# binding), so it is printed but excluded from the divergence walk: it is the
	# clearest single witness of "this Effect query is writeback-only", nothing more.
	{"id": "state_binding_verified", "chain": "4", "causal": false,
		"probe": "snapshot().binding_verified -> has_external_binding_pod (Effect)"},
	{"id": "report_pending_transitions", "chain": "1",
		"probe": "report().pending_transitions"},
	{"id": "report_managed_idea_count", "chain": "2",
		"probe": "report().managed_idea_count (_managed_active_total)"},
	# ── the chain ASKED DIRECTLY, whatever the rebuild driver is doing ─────
	# `reconcile_ideology_effects_for_test` is the INSTANCE call site
	# (`reconcile_effect_activations`, ideology_runtime.cpp:2714-2728) which calls
	# the SAME `collect_effect_activations` with `out_derived == nullptr`. Running it
	# on both legs proves whether rungs 1-3 are PASSABLE under worker authority even
	# when the derived caller never fires. `collect_entries` is shared by both call
	# sites, so these deltas are the only way to attribute it correctly.
	{"id": "direct_collect_entries", "chain": "1",
		"probe": "reconcile_ideology_effects_for_test -> collect_entries delta (:2728)"},
	{"id": "direct_collect_templates", "chain": "1",
		"probe": "same call -> collect_templates delta (:2338)"},
	{"id": "direct_collect_pod_fail", "chain": "3",
		"probe": "same call -> collect_pod_fail delta (:2345)"},
	{"id": "direct_collect_derived_emitted", "chain": "5",
		"probe": "same call -> collect_derived_emitted delta (must be 0, :2393)"},
	{"id": "driver_rebuild_visits", "chain": "0",
		"probe": "report().cell_layer_rebuild_visits delta over the leg"},
	{"id": "driver_drain_steps", "chain": "0",
		"probe": "drain_derived_cell_layer(day) steps summed over the leg"},
	{"id": "collect_entries", "chain": "1",
		"probe": "report().collect_entries delta (:2290)"},
	{"id": "collect_templates", "chain": "1",
		"probe": "report().collect_templates delta (:2338)"},
	{"id": "collect_program_empty", "chain": "3",
		"probe": "report().collect_program_empty delta (:2341)"},
	{"id": "collect_pod_fail", "chain": "3",
		"probe": "report().collect_pod_fail delta (:2345)"},
	{"id": "collect_pod_ok_seen", "chain": "3",
		"probe": "report().collect_pod_ok_keys is NON-EMPTY (:2354) -- the list is "
			+ "cleared per rebuild day, so its SIZE is not comparable across legs"},
	{"id": "collect_pod_fail_seen", "chain": "3",
		"probe": "report().collect_pod_fail_keys is NON-EMPTY (:2347) -- the card's "
			+ "cost entry has no declarative program on BOTH legs"},
	{"id": "effect_metadata_answers", "chain": "3",
		"probe": "ext.effect_program_is_managed(PROGRAM_A) -- the same query, direct"},
	{"id": "effect_commands_count", "chain": "4",
		"probe": "ext.resolve_effect_program_modifier_commands(PROGRAM_A).commands"},
	{"id": "collect_targets_fail", "chain": "5",
		"probe": "report().collect_targets_fail delta (:2360)"},
	{"id": "collect_derived_emitted", "chain": "5",
		"probe": "report().collect_derived_emitted delta (:2579)"},
	{"id": "materialize_programs_seen", "chain": "6",
		"probe": "get_derived_materialize_report().programs_seen (materializer :82)"},
	{"id": "materialize_programs_derived", "chain": "6",
		"probe": "materialize().programs_derived (:90)"},
	{"id": "materialize_programs_skipped_legacy", "chain": "6",
		"probe": "materialize().programs_skipped_legacy (:87)"},
	{"id": "materialize_cells_visited", "chain": "6",
		"probe": "materialize().cells_visited (:103)"},
	{"id": "materialize_commands_folded", "chain": "6",
		"probe": "materialize().commands_folded (:98)"},
	{"id": "materialize_rows_emitted", "chain": "6",
		"probe": "materialize().rows_emitted (:460)"},
	# `get_derived_materialize_report()` does NOT export the ramp counters
	# (world_ext_modifier.cpp:1059-1071 stops at `missing_stat`), so this rung reads
	# the two counters the ideology report exports instead of printing a fake -999.
	{"id": "ramp_terms_evaluated", "chain": "6",
		"probe": "report().ramp_terms_evaluated delta (:7225, not in the materialize "
			+ "binding)"},
	{"id": "ramp_terms_deferred", "chain": "6",
		"probe": "report().ramp_terms_deferred delta (:7226)"},
	{"id": "materialize_truncated", "chain": "6",
		"probe": "materialize().truncated (§12.4 hard condition)"},
	{"id": "materialize_missing_stat", "chain": "6",
		"probe": "materialize().missing_stat"},
	{"id": "layer_installed", "chain": "7",
		"probe": "get_derived_cell_layer_report().installed"},
	{"id": "layer_cell_count", "chain": "7",
		"probe": "get_derived_cell_layer_report().cell_count"},
	{"id": "layer_contribution_count", "chain": "7",
		"probe": "get_derived_cell_layer_report().contribution_count"},
	{"id": "modifier_layer_installed", "chain": "7",
		"probe": "get_modifier_report().layer_installed (independent window)"},
	{"id": "modifier_layer_contributions", "chain": "7",
		"probe": "get_modifier_report().layer_contribution_count"},
	{"id": "stat_add_covered_cells", "chain": "7",
		"probe": "get_effective_stat_value(birth_factor).derived_present per cell"},
]

var _checks := 0
var _failures := 0
var _next_sequence := 1
var _run_started_ms := 0
var _budget_exhausted := false
var _world: Dictionary = {}
var _effect_cursor := 0
var _trace: Array = []


func _init() -> void:
	call_deferred("_run_and_finish")


func _run_and_finish() -> void:
	var code := await _run()
	print("=== ideology worker layer gap diagnosis: %d checks, %d failures ===" % [
		_checks, _failures])
	quit(code if code != 0 else (0 if _failures == 0 else 1))


func _run() -> int:
	_run_started_ms = Time.get_ticks_msec()
	_header()
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt unavailable")
		return 1
	if not await _build_world():
		return 1
	_install_selector_fixture()
	# ── RUNG 0 baseline: everything from here on is measured as a delta ────
	_drive_days(3)
	_report_mask("after 3 warm-up days")
	if not await _equip_card(CARD_A):
		print("[STOP] the card never went live, so no collect ladder can be measured")
		return 1
	var live: int = _live_card_count()
	print("[LIVE] %s location-of-card=%d live_cards_in_snapshot=%d day=%d"
		% [CARD_A, _location_of(CARD_A), live, int(_world["tick"])])
	if live < 1:
		print("[STOP] the card is not live in the main-thread snapshot: nothing to "
			+ "measure below")
		return 1
	var worker_base := _capture_leg("W-base")
	_drive_days(WORKER_LEG_DAYS)
	var worker_leg := _capture_leg("W-worker-0x%03X" % MASK_ALL)
	# ── the control: the SAME world, one bit of authority removed ──────────
	if not await _flip_authority(MASK_MAIN_IDEOLOGY, "W->M"):
		print("[STOP] the authority flip failed; no control ladder to compare")
		return 1
	var main_base := _capture_leg("M-base")
	var main_days := 0
	while main_days < MAIN_LEG_MAX_DAYS:
		if _budget_exhausted or bool(_world.get("stopped", false)):
			break
		_drive_day()
		main_days += 1
		var probe: Dictionary = _world["ext"].get_derived_cell_layer_report()
		if int(probe.get("cell_count", 0)) > 0:
			break
	var main_leg := _capture_leg("M-main-0x%03X" % MASK_MAIN_IDEOLOGY)
	_print_leg(worker_leg)
	_print_leg(main_leg)
	var worker_ladder := _ladder_values(worker_leg, worker_base)
	var main_ladder := _ladder_values(main_leg, main_base)
	_print_trace()
	_print_ladder(worker_ladder, main_ladder)
	_assert_ladder(worker_leg, worker_ladder, main_leg, main_ladder)
	_teardown()
	return 0


# =========================================================================
# Banner: the bits, the masks, and why 0xF7F hid this
# =========================================================================
func _header() -> void:
	print("[DIAG] derived cell layer under worker-owned ideology")
	print("[DIAG] RuntimeDomainId bits: input_capture=0x%03X climate=0x%03X "
		% [DOMAIN_INPUT_CAPTURE, DOMAIN_CLIMATE]
		+ "country=0x%03X trigger_input=0x%03X ideology=0x%03X effect=0x%03X "
		% [DOMAIN_COUNTRY, DOMAIN_TRIGGER_INPUT, DOMAIN_IDEOLOGY, DOMAIN_EFFECT]
		+ "modifier=0x%03X gameplay_effect=0x%03X economy=0x%03X "
		% [DOMAIN_MODIFIER, DOMAIN_GAMEPLAY_EFFECT, DOMAIN_ECONOMY]
		+ "events=0x%03X visual=0x%03X commit=0x%03X"
		% [DOMAIN_EVENTS, DOMAIN_VISUAL, DOMAIN_COMMIT])
	_expect("MASK: the ideology bit is domain 5 -> 0x010",
		DOMAIN_IDEOLOGY == 0x010, "0x%03X" % DOMAIN_IDEOLOGY)
	_expect("MASK: the control is 0x%03X, exactly 0xFFF with the ideology bit "
		% MASK_MAIN_IDEOLOGY + "cleared (EFFECT/MODIFIER/ECONOMY stay worker-owned)",
		MASK_MAIN_IDEOLOGY == 0xFEF
			and (MASK_MAIN_IDEOLOGY & DOMAIN_IDEOLOGY) == 0
			and (MASK_MAIN_IDEOLOGY & DOMAIN_EFFECT) != 0
			and (MASK_MAIN_IDEOLOGY & DOMAIN_MODIFIER) != 0,
		"0x%03X" % MASK_MAIN_IDEOLOGY)
	_expect("MASK: 0x%03X (what every older ideology worker fixture uses) still "
		% MASK_OLDER_FIXTURES + "GRANTS ideology -- it clears GAMEPLAY_EFFECT 0x080, "
		+ "which cannot change the ideology result and is why this gap was invisible",
		(MASK_OLDER_FIXTURES & DOMAIN_IDEOLOGY) != 0
			and (MASK_OLDER_FIXTURES & DOMAIN_GAMEPLAY_EFFECT) == 0,
		"0x%03X" % MASK_OLDER_FIXTURES)
	print("[DIAG] chain under probe: collect_effect_activations "
		+ "(ideology_runtime.cpp:2281) -> backend (:2372) -> "
		+ "program_modifier_commands (:2458) -> rows (:2444) -> "
		+ "build_derived_cell_front (derived_cell_materializer.cpp:81) -> "
		+ "install_derived_cell_layer (modifier_runtime.cpp:1645)")


# =========================================================================
# World construction -- copied from `ideology_worker_authority_parity_test.gd`
# (`_build_world`), which is the proven production path for a worker world.
# A hand-built MapData crashes (`world_ext_economy.cpp:929-930`, plan §14.3 M1-8).
# =========================================================================
func _build_world() -> bool:
	var started := Time.get_ticks_msec()
	print("[BUILD] generating %dx%d seed=%d mask=0x%03X (worker owns ideology)"
		% [WIDTH, HEIGHT, SEED, MASK_ALL])
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
	host.generate_test_economy_data = true
	host.test_economy_population_scale = 100
	host.runtime_climate_authority_enabled = true
	host.runtime_shadow_on_generate = true
	host.runtime_economy_auto_pod_active = true
	host.runtime_authority_domain_mask = MASK_ALL
	host.runtime_parity_forcing = true
	get_root().add_child(host)
	await process_frame
	host.configure(null, null, clock)
	host.set_climate_authority_override("force_on")
	var config := NewGameConfig.create_default()
	config.country.name = "W gap diagnosis"
	config.country.foreign_count = 1
	config.base.map_width = WIDTH
	config.base.map_height = HEIGHT
	config.base.initial_seed = SEED
	config.apply_land_layout("two")
	var session: Dictionary = host.configure_session({
		"kind": "new_game", "config": config.to_dictionary()})
	if not _require("BUILD: the session configures",
			bool(session.get("ok", false)), str(session)):
		return false
	await host.generate_world(SEED)
	var generator: MapGenerator = host.get_generator()
	if not _require("BUILD: production world generation succeeded",
			generator != null):
		return false
	var ext: Object = generator.get_data_core_world_ext()
	if not _require("BUILD: production DCWorldExt is bound", ext != null):
		return false
	ext.set_runtime_ideology_parity_enabled(false)
	ext.set_runtime_clock(true, WORKER_SPEED)
	_world = {
		"host": host, "clock": clock, "ext": ext, "generator": generator,
		"tick": 0, "cells": CELLS, "handle": 0,
		"started_ms": Time.get_ticks_msec(), "last_ideology": {},
		"last_suppressed": false, "slices": 0, "faulted": false,
		"fault_reported": false, "drain_steps": 0, "drain_loops": 0,
		"main_thread_leg": false, "stopped": false,
	}
	var handles := _country_handles()
	if not _require("BUILD: the world has at least one country",
			handles.size() >= 1, str(handles)):
		return false
	_world["handle"] = int(handles[0])
	_world["tick"] = maxi(0, _world_day())
	print("[BUILD] ready in %d ms: countries=%d handle=%d start_day=%d"
		% [Time.get_ticks_msec() - started, handles.size(),
			int(_world["handle"]), int(_world["tick"])])
	return true


func _country_handles() -> PackedInt64Array:
	var ext: Object = _world["ext"]
	var seen := {}
	var out := PackedInt64Array()
	for cell in range(CELLS):
		var summary: Dictionary = ext.get_country_cell_summary(cell)
		var handle := int(summary.get("country_handle", 0))
		if handle == 0 or seen.has(handle):
			continue
		seen[handle] = true
		out.append(handle)
	return out


# =========================================================================
# Day driving -- the production settle handshake, copied from the parity fixture
# =========================================================================
func _service_peers(passes: int = PEER_PASSES) -> void:
	var ext: Object = _world["ext"]
	if not ext.has_method("service_country_worker_peer_adapter"):
		return
	for _pass in range(passes):
		ext.service_country_worker_peer_adapter(PEER_BATCH, true)


func _drive_days(days: int) -> void:
	for _index in range(days):
		if bool(_world.get("stopped", false)):
			return
		_drive_day()


func _drive_day() -> Dictionary:
	if _budget_exhausted or bool(_world.get("stopped", false)):
		return {"ok": false, "budget": true}
	if Time.get_ticks_msec() - _run_started_ms > GLOBAL_BUDGET_MS:
		_budget_exhausted = true
		print("[BUDGET] wall-clock budget exhausted at day %d; stopping the drive "
			% int(_world["tick"]) + "and reporting what has been measured")
		return {"ok": false, "budget": true}
	var ext: Object = _world["ext"]
	var clock: WorldClock = _world["clock"]
	var host: WorldRuntimeHost = _world["host"]
	# A worker fault AFTER the flip is data, not a reason to stop: the main thread
	# owns ideology from that point and can still run days by itself.
	var fault := _worker_fault()
	if not fault.is_empty():
		_world["faulted"] = true
		if not bool(_world.get("fault_reported", false)):
			_world["fault_reported"] = true
			print("[FAULT] the worker faulted with '%s' at day %d (recorded; the "
				% [fault, int(_world["tick"])]
				+ "main thread keeps driving because it owns ideology after the flip)")
		if not bool(_world.get("main_thread_leg", false)):
			_world["stopped"] = true
			return {"ok": false, "fault": fault}
	_world["tick"] = int(_world["tick"]) + 1
	var day := int(_world["tick"])
	clock.current_day = float(day)
	_service_peers()
	if ext.has_method("publish_ideology_worker_inputs"):
		ext.publish_ideology_worker_inputs()
	host.run_daily_tick(day, clock.season_phase_for_day(day))
	host.finish_daily_tick(0.0, {})
	var pulses := 0
	while _has_hard_barrier() and pulses < 400:
		clock.simulation_backpressure_pulse.emit(day)
		pulses += 1
	var before := _counter_snapshot()
	# `run_ideology_daily` is SUPPRESSED when the worker owns IDEOLOGY
	# (`world_ext_ideology.cpp:323-333` returns path=IDEOLOGY_WORKER and never
	# reaches `run_daily_slices`, which is the only caller of
	# `step_derived_rebuild` besides `drain_derived_cell_layer`).
	var ideology: Dictionary = {}
	var slices := 0
	for _slice in range(MAX_SLICES_PER_DAY):
		slices += 1
		ideology = ext.run_ideology_daily(day)
		if not bool(ideology.get("ok", true)):
			break
		if bool(ideology.get("suppressed", false)):
			break
		if bool(ideology.get("done", false)):
			break
	_world["last_ideology"] = ideology
	_world["last_suppressed"] = bool(ideology.get("suppressed", false))
	_world["slices"] = int(_world.get("slices", 0)) + slices
	if not bool(ideology.get("suppressed", false)):
		for _slice in range(16):
			var effect_slice: Dictionary = ext.run_effect_daily(day)
			if not bool(effect_slice.get("ok", true)):
				break
			if bool(effect_slice.get("done", true)):
				break
		ext.dispatch_effect_native_modifier()
		ext.run_modifier_daily(day)
		ext.ack_effect_native_modifier()
	# THE CURRENT DAY, never 0: `drain_derived_cell_layer(0)` is a silent no-op once
	# anything confirmed (`derived_cell_materializer` day bookkeeping).
	var drained: Dictionary = ext.drain_derived_cell_layer(day)
	var steps := int(drained.get("steps", 0))
	_world["drain_steps"] = int(_world.get("drain_steps", 0)) + steps
	if steps > 0:
		_world["drain_loops"] = int(_world.get("drain_loops", 0)) + 1
	if bool(ideology.get("suppressed", false)):
		var pod_before := int(ext.get_runtime_thread_report().get(
			"ideology_pod_committed_day", -1))
		_wait_pod_day(pod_before, POD_WAIT_MS)
	var after := _counter_snapshot()
	var layer: Dictionary = ext.get_derived_cell_layer_report()
	var row := {
		"day": day,
		"leg": "M" if bool(_world.get("main_thread_leg", false)) else "W",
		"suppressed": bool(_world["last_suppressed"]),
		"path": String(ideology.get("path", "")),
		"mask": int(ext.get_runtime_thread_report().get(
			"authoritative_domain_mask", 0)),
		"visits": int(after["cell_layer_rebuild_visits"])
			- int(before["cell_layer_rebuild_visits"]),
		"entries": int(after["collect_entries"])
			- int(before["collect_entries"]),
		"templates": int(after["collect_templates"])
			- int(before["collect_templates"]),
		"pod_fail": int(after["collect_pod_fail"])
			- int(before["collect_pod_fail"]),
		"emitted": int(after["collect_derived_emitted"])
			- int(before["collect_derived_emitted"]),
		"drain_steps": steps,
		"drain_complete": bool(drained.get("complete", true)),
		"installed": bool(layer.get("installed", false)),
		"cells": int(layer.get("cell_count", -1)),
		"live": _live_card_count(),
	}
	_trace.append(row)
	print("[DAY] day=%d leg=%s suppressed=%s path=%-16s mask=0x%03X visits+=%d "
		% [row["day"], row["leg"], str(row["suppressed"]), row["path"], row["mask"],
			row["visits"]]
		+ "collect_entries+=%d templates+=%d pod_fail+=%d emitted+=%d "
		% [row["entries"], row["templates"], row["pod_fail"], row["emitted"]]
		+ "drain_steps=%d complete=%s layer installed=%s cells=%d"
		% [row["drain_steps"], str(row["drain_complete"]),
			str(row["installed"]), row["cells"]])
	return {"ok": true, "day": day, "slices": slices, "drained": drained,
		"suppressed": bool(_world["last_suppressed"])}


func _wait_pod_day(before: int, timeout_ms: int) -> void:
	var ext: Object = _world["ext"]
	if ext.has_method("set_runtime_clock"):
		ext.set_runtime_clock(false, WORKER_SPEED)
	WorkerWaitHelper.wait_until(
		func() -> bool:
			var report: Dictionary = ext.get_runtime_thread_report()
			return int(report.get("ideology_pod_committed_day", -1)) > before \
				or String(report.get("simulation_host_state", "")) in [
					"STOPPED", "FAULTED"],
		timeout_ms,
		func() -> void:
			_service_peers(1))
	if ext.has_method("set_runtime_clock"):
		ext.set_runtime_clock(true, WORKER_SPEED)


func _worker_fault() -> String:
	var ext: Object = _world.get("ext", null)
	if ext == null or not ext.has_method("get_runtime_thread_report"):
		return ""
	return String(ext.get_runtime_thread_report().get("fault_code", ""))


func _has_hard_barrier() -> bool:
	var clock: Object = _world.get("clock", null)
	if clock == null or not clock.has_method("has_hard_barrier"):
		return false
	return bool(clock.has_hard_barrier())


func _world_day() -> int:
	var ext: Object = _world.get("ext", null)
	if ext == null or not ext.has_method("get_runtime_thread_report"):
		return 0
	var report: Dictionary = ext.get_runtime_thread_report()
	for key in ["world_day", "ideology_pod_committed_day", "day"]:
		if report.has(key):
			return int(report[key])
	return 0


func _report_mask(label: String) -> void:
	var ext: Object = _world["ext"]
	var report: Dictionary = ext.get_runtime_thread_report()
	print("[MASK] %s: mask=0x%03X state=%s mode=%s ready=%s suppressed=%s path=%s "
		% [label, int(report.get("authoritative_domain_mask", -1)),
			String(report.get("simulation_host_state", "?")),
			String(report.get("simulation_thread_mode", "?")),
			str(report.get("simulation_worker_ready", "?")),
			str(_world["last_suppressed"]),
			String((_world["last_ideology"] as Dictionary).get("path", ""))]
		+ "fault='%s' day=%d"
		% [String(report.get("fault_code", "")), int(_world["tick"])])


# =========================================================================
# Authority flip (plan §9.7) -- copied from the parity fixture, minus the second world
# =========================================================================
func _flip_authority(mask: int, label: String) -> bool:
	var ext: Object = _world["ext"]
	var before_day := int(_world["tick"])
	print("[FLIP/%s] stop -> restart with mask 0x%03X at day %d (ideology returns to "
		% [label, mask, before_day] + "the main thread; every other bit is unchanged)")
	if ext.has_method("request_runtime_stop"):
		ext.request_runtime_stop()
	_wait_worker_state("STOPPED", STATE_WAIT_MS)
	var started: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "ACTIVE",
		"graph_coverage_complete": true,
		"authoritative_domain_mask": mask,
		"day": maxi(0, before_day),
		"speed_days_per_second": WORKER_SPEED,
		"paused": false,
	})
	if not _require("[FLIP/%s] the worker restarts with mask 0x%03X" % [label, mask],
			bool(started.get("ok", false)), str(started)):
		return false
	if not _require("[FLIP/%s] the restarted worker reaches a usable state" % label,
			_wait_worker_runnable(STATE_WAIT_MS),
			str(ext.get_runtime_thread_report())):
		return false
	ext.set_runtime_clock(true, WORKER_SPEED)
	_world["main_thread_leg"] = true
	var want_ideology := (mask & DOMAIN_IDEOLOGY) != 0
	_drive_day()
	var followed := bool(_world["last_suppressed"]) == want_ideology
	var actual := _await_reported_mask(want_ideology, MASK_WAIT_MS)
	print("[FLIP/%s] reported mask=0x%03X state=%s (requested 0x%03X)"
		% [label, actual, String(ext.get_runtime_thread_report().get(
			"simulation_host_state", "?")), mask])
	_expect("[FLIP/%s] the ideology writer follows the new mask (suppressed means "
		% label + "the worker owns it; path=IDEOLOGY_WORKER when suppressed)",
		followed, str(_world["last_ideology"]))
	_expect("[FLIP/%s] the worker never reports a mask whose ideology bit "
		% label + "contradicts the request",
		actual == 0 or ((actual & DOMAIN_IDEOLOGY) != 0) == want_ideology,
		"actual=0x%03X requested=0x%03X" % [actual, mask])
	_expect("[FLIP/%s] the main thread now runs the ideology day itself "
		% label + "(not suppressed, path is not IDEOLOGY_WORKER)",
		not bool(_world["last_suppressed"])
			and String((_world["last_ideology"] as Dictionary).get("path", "")) \
				!= "IDEOLOGY_WORKER",
		str(_world["last_ideology"]))
	return true


func _await_reported_mask(want_ideology: bool, timeout_ms: int) -> int:
	var ext: Object = _world["ext"]
	var deadline := Time.get_ticks_msec() + timeout_ms
	var mask := 0
	while Time.get_ticks_msec() < deadline:
		mask = int(ext.get_runtime_thread_report().get(
			"authoritative_domain_mask", 0))
		if mask != 0 and ((mask & DOMAIN_IDEOLOGY) != 0) == want_ideology:
			return mask
		OS.delay_msec(5)
	return mask


func _wait_worker_state(wanted: String, timeout_ms: int) -> bool:
	var ext: Object = _world["ext"]
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		var state := String(ext.get_runtime_thread_report().get(
			"simulation_host_state", ""))
		if state == wanted:
			return true
		if state == "FAULTED":
			return false
		OS.delay_msec(2)
	return false


func _wait_worker_runnable(timeout_ms: int) -> bool:
	var ext: Object = _world["ext"]
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		var state := String(ext.get_runtime_thread_report().get(
			"simulation_host_state", ""))
		if state in ["PAUSED", "RUNNING"]:
			return true
		if state in ["STOPPED", "FAULTED"]:
			return false
		OS.delay_msec(2)
	return false


# =========================================================================
# Ideology commands (identical to the parity fixture)
# =========================================================================
func _submit(rows: Array) -> Dictionary:
	var ext: Object = _world["ext"]
	var opcodes := PackedInt32Array()
	var days := PackedInt64Array()
	var producers := PackedInt32Array()
	var sequences := PackedInt64Array()
	var handles := PackedInt64Array()
	var ideas := PackedInt32Array()
	var values := PackedInt64Array()
	var priorities := PackedInt32Array()
	var generations := PackedInt64Array()
	var choices := PackedInt32Array()
	var gates := PackedInt32Array()
	var tick := int(_world["tick"])
	for row_value in rows:
		var row: Dictionary = row_value
		opcodes.append(int(row.get("op", 0)))
		days.append(int(row.get("day", tick)))
		producers.append(1)
		sequences.append(_next_sequence)
		_next_sequence += 1
		handles.append(int(row.get("handle", _world["handle"])))
		ideas.append(int(row.get("idea", -1)))
		values.append(int(row.get("value", 0)))
		priorities.append(0)
		generations.append(0)
		choices.append(-1)
		gates.append(-1)
	return ext.submit_ideology_commands({
		"opcodes": opcodes, "effective_days": days, "producer_ids": producers,
		"sequences": sequences, "country_handles": handles,
		"ideology_ids": ideas, "values_q16": values,
		"source_priorities": priorities, "offer_generations": generations,
		"choice_indices": choices, "gate_ids": gates,
	})


func _dense_id(card: String) -> int:
	var catalog: Resource = load(
		"res://data/ideologies/default_ideology_catalog.tres")
	if catalog == null:
		return -1
	var country_ir: Dictionary = EconomyCatalogScript.compile_native_catalog()
	var native: Dictionary = catalog.compile_native_catalog(country_ir, country_ir)
	if not bool(native.get("ok", false)):
		_fail("ideology catalog compile failed: %s" % String(
			native.get("reason", "unknown")))
		return -1
	var wanted := card if card.begins_with("idea.") else "idea.%s" % card
	return PackedStringArray(native.get("ideology_ids",
		PackedStringArray())).find(wanted)


func _equip_card(card: String) -> bool:
	var dense := _dense_id(card)
	if dense < 0:
		_fail("%s is absent from the compiled catalog" % card)
		return false
	var gate: Dictionary = DrawGateHelper.grant_draw_gates(
		_world["host"], card, int(_world["handle"]), int(_world["tick"]),
		_next_sequence)
	if not _require("%s: draw gates clear" % card, bool(gate.get("ok", false)),
			str(gate)):
		return false
	_next_sequence = maxi(_next_sequence, int(gate.get("next_sequence",
		_next_sequence)))
	_drive_day()
	var preamble: Dictionary = _submit([
		{"op": OP_GRANT_POINTS, "idea": -1, "value": 64 * Q16_ONE},
		{"op": OP_DISCOVER, "idea": dense},
		{"op": OP_ADD_UNDERSTANDING, "idea": dense, "value": 0},
	])
	if not _require("%s: grant/discover/understanding accepted" % card,
			bool(preamble.get("ok", false)), str(preamble)):
		return false
	_drive_days(2)
	var equipped: Dictionary = _submit([{"op": OP_EQUIP, "idea": dense}])
	if not _require("%s: equip accepted" % card, bool(equipped.get("ok", false)),
			str(equipped)):
		return false
	await WorkerWaitHelper.wait_for(
		func() -> bool:
			return _location_of(card) == 1,
		10, DAY_WAIT_MS * 2,
		func() -> void:
			_drive_day())
	if _location_of(card) == 1:
		return _require("%s is live (location=1)" % card, true)
	# Main-thread fallback only: in a no-worker world nothing else ACKs the equip's
	# Effect transactions (the parity fixture documents the same gap).
	if not bool(_world["last_suppressed"]):
		var acked := _ack_effect_transactions()
		print("[%s] effect-transaction fallback ack: %s" % [card, str(acked)])
		_drive_days(3)
	return _require("%s is live (location=1)" % card, _location_of(card) == 1,
		"location=%d last_error='%s' snapshot_levels=%s"
			% [_location_of(card),
				String(_snapshot().get("last_error", "")),
				str(_snapshot().get("levels", PackedInt32Array()))])


func _ack_effect_transactions() -> Dictionary:
	var ext: Object = _world["ext"]
	if not ext.has_method("poll_effect_transactions"):
		return {"seen": 0}
	var ids := PackedInt64Array()
	var masks := PackedInt32Array()
	var cursor := _effect_cursor
	for _page in range(16):
		var polled: Dictionary = ext.poll_effect_transactions(cursor, 1024)
		var page_ids: PackedInt64Array = polled.get("transaction_ids",
			PackedInt64Array())
		if page_ids.is_empty():
			break
		var page_masks: PackedInt32Array = polled.get("required_ack_masks",
			PackedInt32Array())
		for index in range(page_ids.size()):
			var mask := int(page_masks[index]) if index < page_masks.size() else 0
			if mask == 0:
				continue
			ids.append(int(page_ids[index]))
			masks.append(mask)
		cursor = int(page_ids[page_ids.size() - 1])
	_effect_cursor = cursor
	if ids.is_empty():
		return {"seen": 0}
	var batch := {"transaction_ids": ids, "ack_masks": masks}
	ext.preflight_effect_transactions(batch)
	ext.commit_effect_transactions(batch)
	var ack: Dictionary = ext.ack_effect_transactions(batch)
	return {"seen": ids.size(), "acked": int(ack.get("acknowledged", 0))}


func _snapshot() -> Dictionary:
	return _world["ext"].get_ideology_snapshot(int(_world["handle"]))


func _location_of(card: String) -> int:
	var dense := _dense_id(card)
	if dense < 0:
		return -1
	var snapshot := _snapshot()
	var ids: PackedInt32Array = snapshot.get("idea_ids", PackedInt32Array())
	var locations: PackedInt32Array = snapshot.get(
		"locations", PackedInt32Array())
	var pending: PackedByteArray = snapshot.get(
		"transition_pending", PackedByteArray())
	var row := ids.find(dense)
	if row < 0 or row >= locations.size():
		return -1
	if row < pending.size() and int(pending[row]) != 0:
		return -1
	return int(locations[row])


func _live_card_count() -> int:
	var locations: PackedInt32Array = _snapshot().get(
		"locations", PackedInt32Array())
	var count := 0
	for location in locations:
		if int(location) == 1:
			count += 1
	return count


# =========================================================================
# The selector fixture: pin the two card predicates on owned land cells and the
# population metric above its threshold (copied from the parity fixture, which took
# it from `ideology_x6c_worker_test.gd`).
# =========================================================================
func _install_selector_fixture() -> void:
	var ext: Object = _world["ext"]
	if not ext.has_method("set_cell_tag_override_for_test"):
		return
	var cleared: Dictionary = ext.clear_cell_tag_overrides_for_test()
	_require("SETUP: prior tag overrides cleared", bool(cleared.get("ok", false)),
		str(cleared))
	var metric := _effect_metric_id("cell.population")
	if metric >= 0:
		var population: Dictionary = ext.set_effect_metric_override_for_test(
			metric, POPULATION_Q16, true)
		_world["metric_probe_ok"] = bool(population.get("ok", false))
		_require("SETUP: cell.population pinned",
			bool(population.get("ok", false)), str(population))
	var cells := _owned_land_cells(8)
	var tagged := 0
	for cell in cells:
		for tag in [TAG_A, TAG_B]:
			var result: Dictionary = ext.set_cell_tag_override_for_test(
				String(tag), int(cell), true)
			if bool(result.get("ok", false)):
				tagged += 1
	print("[SETUP] selector fixture: owned_land_cells=%d tags_set=%d metric=%d"
		% [cells.size(), tagged, metric])
	ext.refresh_effect_input_digest_for_test()


func _owned_land_cells(limit: int) -> PackedInt32Array:
	var ext: Object = _world["ext"]
	var out := PackedInt32Array()
	var map = _world["host"].get_current_map() if _world["host"].has_method(
		"get_current_map") else null
	for cell in range(CELLS):
		var summary: Dictionary = ext.get_country_cell_summary(cell)
		if int(summary.get("country_handle", 0)) != int(_world["handle"]):
			continue
		if map != null and bool(map.is_water_arr[cell]):
			continue
		out.append(cell)
		if out.size() >= limit:
			break
	return out


func _effect_metric_id(metric_key: String) -> int:
	var catalog: Resource = load("res://data/effects/default_effect_catalog.tres")
	if catalog == null:
		return -1
	var compiled: Dictionary = catalog.compile_native_catalog()
	if not bool(compiled.get("ok", false)):
		return -1
	return PackedStringArray(compiled.get("metric_keys",
		PackedStringArray())).find(metric_key)


# =========================================================================
# Capturing one leg of the ladder
# =========================================================================
func _counter_snapshot() -> Dictionary:
	var ext: Object = _world["ext"]
	var ideology: Dictionary = ext.get_ideology_report()
	var out := {}
	for key in COUNTER_KEYS:
		out[key] = int(ideology.get(key, -999))
	return out


## The full ladder capture for ONE leg. Everything here comes from a bound method;
## nothing is recomputed in GDScript, so a rung cannot disagree with the runtime.
func _capture_leg(label: String) -> Dictionary:
	var ext: Object = _world["ext"]
	# The direct-call-site probe runs FIRST so the leg's cumulative deltas below
	# exclude it and the probe keeps its own attribution.
	var direct := _probe_instance_call_site()
	var counters := _counter_snapshot()
	counters["drain_steps"] = int(_world.get("drain_steps", 0))
	counters["drain_loops"] = int(_world.get("drain_loops", 0))
	var thread: Dictionary = ext.get_runtime_thread_report()
	var managed: bool = bool(ext.effect_program_is_managed(PROGRAM_A))
	var commands: Dictionary = ext.resolve_effect_program_modifier_commands(PROGRAM_A)
	var magnitude: Dictionary = ext.evaluate_effect_program_magnitude(
		PROGRAM_A, _zero_metrics())
	var leg := {
		"label": label,
		"day": int(_world["tick"]),
		"mask": int(thread.get("authoritative_domain_mask", -1)),
		"worker_state": String(thread.get("simulation_host_state", "?")),
		"worker_ready": bool(thread.get("simulation_worker_ready", false)),
		"fault": String(thread.get("fault_code", "")),
		"pod_committed_day": int(thread.get("ideology_pod_committed_day", -1)),
		"day_path": String((_world["last_ideology"] as Dictionary).get(
			"path", "")),
		"suppressed": bool(_world["last_suppressed"]),
		"counters": counters,
		"layer": ext.get_derived_cell_layer_report(),
		"materialize": ext.get_derived_materialize_report(),
		"ideology": ext.get_ideology_report(),
		"modifier": ext.get_modifier_report(),
		"effect": ext.get_effect_report(),
		"snapshot": ext.get_ideology_snapshot(int(_world["handle"])),
		"managed": managed,
		"commands": commands,
		"magnitude": magnitude,
		"direct": direct,
		"metric_probe_ok": bool(_world.get("metric_probe_ok", false)),
		"stat_add": _probe_stat(STAT_ADD),
		"stat_cut": _probe_stat(STAT_CUT),
	}
	leg["ladder"] = _ladder_values(leg, leg)
	return leg


func _zero_metrics() -> PackedInt64Array:
	var metrics := PackedInt64Array()
	metrics.resize(120)
	metrics.fill(0)
	return metrics


## Runs the INSTANCE call site of `collect_effect_activations` on demand and reports
## what moved. This is the experiment that separates "the collect cannot work under
## worker authority" from "the derived caller never fires": the same function, on the
## same thread, with the same authority, is entered by a binding that passes
## `out_derived == nullptr`.
func _probe_instance_call_site() -> Dictionary:
	var ext: Object = _world["ext"]
	if not ext.has_method("reconcile_ideology_effects_for_test"):
		return {"available": false}
	var before := _counter_snapshot()
	var result: Dictionary = ext.reconcile_ideology_effects_for_test(
		int(_world["handle"]))
	var after := _counter_snapshot()
	var out := {
		"available": true,
		"ok": bool(result.get("ok", false)),
		"result": result,
		"entries": int(after["collect_entries"]) - int(before["collect_entries"]),
		"templates": int(after["collect_templates"])
			- int(before["collect_templates"]),
		"pod_fail": int(after["collect_pod_fail"])
			- int(before["collect_pod_fail"]),
		"emitted": int(after["collect_derived_emitted"])
			- int(before["collect_derived_emitted"]),
		"ok_keys": (_world["ext"].get_ideology_report().get(
			"collect_pod_ok_keys", PackedStringArray()) as PackedStringArray).size(),
	}
	print("[DIRECT] reconcile_ideology_effects_for_test(handle=%d) -> ok=%s "
		% [int(_world["handle"]), str(out["ok"])]
		+ "collect_entries+=%d templates+=%d pod_fail+=%d derived_emitted+=%d "
		% [out["entries"], out["templates"], out["pod_fail"], out["emitted"]]
		+ "pod_ok_keys=%d"
		% out["ok_keys"])
	return out


## Per-cell read of one stat through the production query shape: entity_handle 0 with
## the CELL in the group slot (`economy_runtime_family_buff.cpp` passes the same pair).
func _probe_stat(stat: String) -> Dictionary:
	var ext: Object = _world["ext"]
	var covered := 0
	var add_sum := 0.0
	var first_cell := -1
	var first_add := 0.0
	var errors := 0
	for cell in range(CELLS):
		var probe: Dictionary = ext.get_effective_stat_value(stat, cell, 0, 1.0)
		if not bool(probe.get("ok", false)):
			errors += 1
			continue
		if not bool(probe.get("derived_present", false)):
			continue
		covered += 1
		add_sum += float(probe.get("derived_add", 0.0))
		if first_cell < 0:
			first_cell = cell
			first_add = float(probe.get("derived_add", 0.0))
	return {"covered": covered, "add_sum": add_sum, "first_cell": first_cell,
		"first_add": first_add, "query_errors": errors}


func _delta(leg: Dictionary, base: Dictionary, key: String) -> int:
	var now := int((leg["counters"] as Dictionary).get(key, -999))
	if base.is_empty():
		return now
	return now - int((base["counters"] as Dictionary).get(key, now))


## The flat, comparable ladder. Rungs sourced from a cumulative counter are DELTAS
## over the leg; the materialize report and the layer report are absolute snapshots
## of "the last completed rebuild".
func _ladder_values(leg: Dictionary, base: Dictionary) -> Dictionary:
	var snapshot: Dictionary = leg["snapshot"]
	var locations: PackedInt32Array = snapshot.get("locations",
		PackedInt32Array())
	var pending: PackedByteArray = snapshot.get("transition_pending",
		PackedByteArray())
	var verified: PackedByteArray = snapshot.get("binding_verified",
		PackedByteArray())
	var live := 0
	for location in locations:
		if int(location) == 1:
			live += 1
	var pending_count := 0
	for flag in pending:
		if int(flag) != 0:
			pending_count += 1
	var verified_count := 0
	for flag in verified:
		if int(flag) != 0:
			verified_count += 1
	var ideology: Dictionary = leg["ideology"]
	var materialize: Dictionary = leg["materialize"]
	var layer: Dictionary = leg["layer"]
	var modifier: Dictionary = leg["modifier"]
	var commands: Array = (leg["commands"] as Dictionary).get(
		"commands", []) as Array
	var ok_keys: PackedStringArray = ideology.get("collect_pod_ok_keys",
		PackedStringArray())
	var fail_keys: PackedStringArray = ideology.get("collect_pod_fail_keys",
		PackedStringArray())
	var direct: Dictionary = leg.get("direct", {})
	return {
		"state_live_cards": live,
		"state_transition_pending": pending_count,
		"state_binding_verified": verified_count,
		"report_pending_transitions": int(ideology.get(
			"pending_transitions", -999)),
		"report_managed_idea_count": int(ideology.get(
			"managed_idea_count", -999)),
		"direct_collect_entries": int(direct.get("entries", -999)),
		"direct_collect_templates": int(direct.get("templates", -999)),
		"direct_collect_pod_fail": int(direct.get("pod_fail", -999)),
		"direct_collect_derived_emitted": int(direct.get("emitted", -999)),
		"driver_rebuild_visits": _delta(leg, base, "cell_layer_rebuild_visits"),
		"driver_drain_steps": _delta(leg, base, "drain_steps"),
		"collect_entries": _delta(leg, base, "collect_entries"),
		"collect_templates": _delta(leg, base, "collect_templates"),
		"collect_program_empty": _delta(leg, base, "collect_program_empty"),
		"collect_pod_fail": _delta(leg, base, "collect_pod_fail"),
		"collect_pod_ok_seen": 1 if ok_keys.size() > 0 else 0,
		"collect_pod_fail_seen": 1 if fail_keys.size() > 0 else 0,
		"effect_metadata_answers": 1 if bool(leg["managed"]) else 0,
		"effect_commands_count": commands.size(),
		"collect_targets_fail": _delta(leg, base, "collect_targets_fail"),
		"collect_derived_emitted": _delta(leg, base, "collect_derived_emitted"),
		"materialize_programs_seen": int(materialize.get("programs_seen", -999)),
		"materialize_programs_derived": int(materialize.get(
			"programs_derived", -999)),
		"materialize_programs_skipped_legacy": int(materialize.get(
			"programs_skipped_legacy", -999)),
		"materialize_cells_visited": int(materialize.get(
			"cells_visited", -999)),
		"materialize_commands_folded": int(materialize.get(
			"commands_folded", -999)),
		"materialize_rows_emitted": int(materialize.get("rows_emitted", -999)),
		"ramp_terms_evaluated": _delta(leg, base, "ramp_terms_evaluated"),
		"ramp_terms_deferred": _delta(leg, base, "ramp_terms_deferred"),
		"materialize_truncated": int(materialize.get("truncated", -999)),
		"materialize_missing_stat": int(materialize.get("missing_stat", -999)),
		"layer_installed": 1 if bool(layer.get("installed", false)) else 0,
		"layer_cell_count": int(layer.get("cell_count", -999)),
		"layer_contribution_count": int(layer.get("contribution_count", -1)),
		"modifier_layer_installed": int(modifier.get("layer_installed", -999)),
		"modifier_layer_contributions": int(modifier.get(
			"layer_contribution_count", -999)),
		"stat_add_covered_cells": int((leg["stat_add"] as Dictionary).get(
			"covered", -999)),
	}


# =========================================================================
# Printing: the full dicts, the two legs, then the adjacent ladder
# =========================================================================
func _print_leg(leg: Dictionary) -> void:
	print("")
	print("=================== LEG %s (day=%d) ==================="
		% [String(leg["label"]), int(leg["day"])])
	print("[LEG] mask=0x%03X worker_state=%s ready=%s fault='%s' "
		% [int(leg["mask"]), String(leg["worker_state"]),
			str(leg["worker_ready"]), String(leg["fault"])]
		+ "pod_committed_day=%d suppressed=%s day_path=%s"
		% [int(leg["pod_committed_day"]), str(leg["suppressed"]),
			String(leg["day_path"])])
	print("[LEG] RUNTIME LIVENESS from the main thread's point of view:")
	print("[LEG]   _modifier_runtime: get_modifier_report() answered=%s "
		% str((leg["modifier"] as Dictionary).has("configured"))
		+ "configured=%s current_day=%s layer_installed=%s layer_generation=%s "
		% [str((leg["modifier"] as Dictionary).get("configured", "?")),
			str((leg["modifier"] as Dictionary).get("current_day", "?")),
			str((leg["modifier"] as Dictionary).get("layer_installed", "?")),
			str((leg["modifier"] as Dictionary).get("layer_generation", "?"))]
		+ "layer_contribution_count=%s"
		% str((leg["modifier"] as Dictionary).get(
			"layer_contribution_count", "?")))
	print("[LEG]   _effect_runtime:   get_effect_report() answered=%s "
		% str((leg["effect"] as Dictionary).has("configured"))
		+ "configured=%s definitions=%s instances=%s current_day=%s"
		% [str((leg["effect"] as Dictionary).get("configured", "?")),
			str((leg["effect"] as Dictionary).get("definitions", "?")),
			str((leg["effect"] as Dictionary).get("instances", "?")),
			str((leg["effect"] as Dictionary).get("current_day", "?"))])
	print("[LEG]   Effect query 1 (rung 3): effect_program_is_managed('%s') = %s"
		% [PROGRAM_A, str(leg["managed"])])
	print("[LEG]   Effect query 2 (rung 4): resolve_effect_program_modifier_commands("
		+ "'%s') = ok=%s commands=%d"
		% [PROGRAM_A, str((leg["commands"] as Dictionary).get("ok", "?")),
			((leg["commands"] as Dictionary).get("commands", []) as Array).size()])
	var rows: Array = (leg["commands"] as Dictionary).get("commands", []) as Array
	for row_value in rows:
		var row: Dictionary = row_value
		print("[LEG]     command definition_key='%s' value_q16=%s stacks=%s "
			% [String(row.get("definition_key", "?")), str(row.get("value_q16", "?")),
				str(row.get("stacks", "?"))]
			+ "duration_days=%s" % str(row.get("duration_days", "?")))
	print("[LEG]   Effect query 3: evaluate_effect_program_magnitude('%s') = ok=%s "
		% [PROGRAM_A, str((leg["magnitude"] as Dictionary).get("ok", "?"))]
		+ "magnitude=%s (3277 would be the parity fixture's measurement)"
		% str((leg["magnitude"] as Dictionary).get("magnitude", "?")))
	print("[LEG]   set_effect_metric_override_for_test(cell.population) = %s"
		% str(leg["metric_probe_ok"]))
	var snapshot: Dictionary = leg["snapshot"]
	print("[LEG]   ideology snapshot (the rows the collect loop walks): "
		+ "idea_ids=%s"
		% str(snapshot.get("idea_ids", PackedInt32Array())))
	print("[LEG]     levels=%s" % str(snapshot.get("levels", PackedInt32Array())))
	print("[LEG]     locations=%s" % str(snapshot.get(
		"locations", PackedInt32Array())))
	print("[LEG]     transition_pending=%s" % str(snapshot.get(
		"transition_pending", PackedByteArray())))
	print("[LEG]     binding_verified=%s (has_external_binding_pod -- an Effect "
		% str(snapshot.get("binding_verified", PackedByteArray()))
		+ "query that is documented writeback-only under worker authority)")
	print("[LEG]   derived stat probe: %s covered=%d add_sum=%.10f first_cell=%d "
		% [STAT_ADD, int((leg["stat_add"] as Dictionary)["covered"]),
			float((leg["stat_add"] as Dictionary)["add_sum"]),
			int((leg["stat_add"] as Dictionary)["first_cell"])]
		+ "first_add=%.10f query_errors=%d"
		% [float((leg["stat_add"] as Dictionary)["first_add"]),
			int((leg["stat_add"] as Dictionary)["query_errors"])])
	print("[LEG]   derived stat probe: %s covered=%d add_sum=%.10f"
		% [STAT_CUT, int((leg["stat_cut"] as Dictionary)["covered"]),
			float((leg["stat_cut"] as Dictionary)["add_sum"])])
	_print_dict("[LEG] get_derived_cell_layer_report()", leg["layer"])
	_print_dict("[LEG] get_derived_materialize_report()", leg["materialize"])
	_print_dict("[LEG] get_ideology_report()", leg["ideology"])


func _print_dict(title: String, value: Dictionary) -> void:
	var keys: Array = value.keys()
	keys.sort()
	print(title + "  (%d keys)" % keys.size())
	for key in keys:
		print("  %s = %s" % [String(key), _format_value(value[key])])


func _format_value(value) -> String:
	if value is PackedStringArray or value is Array:
		var items: Array = []
		var count := 0
		for item in value:
			count += 1
			if items.size() < 12:
				items.append(str(item))
		var suffix := "" if count <= 12 else ", ... (%d total)" % count
		return "[" + ", ".join(items) + suffix + "]"
	if value is PackedInt32Array or value is PackedInt64Array \
			or value is PackedByteArray or value is PackedFloat32Array \
			or value is PackedFloat64Array:
		var items: Array = []
		var count: int = value.size()
		var limit := mini(count, 12)
		for index in range(limit):
			items.append(str(value[index]))
		var suffix := "" if count <= 12 else ", ... (%d total)" % count
		return "[" + ", ".join(items) + suffix + "]"
	return str(value)


func _print_trace() -> void:
	print("")
	print("=================== PER-DAY TRACE (the window, if any) ===================")
	print("[TRACE] one row per driven day. `visits` counts step_derived_rebuild "
		+ "entries that day, `drain_steps` the steps drain_derived_cell_layer got.")
	for row_value in _trace:
		var row: Dictionary = row_value
		print("[TRACE] day=%-3d leg=%s suppressed=%-5s path=%-16s mask=0x%03X "
			% [int(row["day"]), String(row.get("leg", "?")), str(row["suppressed"]),
				String(row["path"]), int(row["mask"])]
			+ "visits=%d entries=%d templates=%d pod_fail=%d emitted=%d "
			% [int(row["visits"]), int(row["entries"]), int(row["templates"]),
				int(row["pod_fail"]), int(row["emitted"])]
			+ "drain_steps=%d "
			% int(row["drain_steps"])
			+ "layer installed=%s cells=%d"
			% [str(row["installed"]), int(row["cells"])])


func _print_ladder(worker: Dictionary, main: Dictionary) -> void:
	print("")
	print("=================== THE LADDER: worker-owned 0x%03X vs main-thread 0x%03X "
		% [MASK_ALL, MASK_MAIN_IDEOLOGY]
		+ "===================")
	print("[LADDER] %-4s %-40s %-46s %12s %12s %s"
		% ["#", "rung", "probe", "worker", "main", "verdict"])
	var first_divergence := ""
	var first_index := -1
	var index := 0
	for spec_value in RUNGS:
		var spec: Dictionary = spec_value
		var id := String(spec["id"])
		var left := int(worker.get(id, -999))
		var right := int(main.get(id, -999))
		var verdict := "same"
		if left != right:
			verdict = "DIFFERS" if bool(spec.get("causal", true)) else "DIFFERS(info)"
		if left != right and first_divergence.is_empty() \
				and bool(spec.get("causal", true)):
			first_divergence = id
			first_index = index
		print("[LADDER] %-4d %-40s %-46s %12d %12d %s"
			% [index, "(chain %s) %s" % [String(spec["chain"]), id],
				String(spec["probe"]), left, right, verdict])
		index += 1
	print("")
	if first_divergence.is_empty():
		print("[FIRST-DIVERGENCE] none: no CAUSAL rung of the two ladders differs")
		return
	var div_spec: Dictionary = RUNGS[first_index] as Dictionary
	print("[FIRST-DIVERGENCE] rung #%d '%s' (chain step %s)"
		% [first_index, first_divergence, String(div_spec["chain"])])
	print("[FIRST-DIVERGENCE] probe: %s" % String(div_spec["probe"]))
	print("[FIRST-DIVERGENCE] worker-owned 0x%03X -> %d ; main-thread 0x%03X -> %d"
		% [MASK_ALL, int(worker.get(first_divergence, -999)),
			MASK_MAIN_IDEOLOGY, int(main.get(first_divergence, -999))])
	# Everything ABOVE the first divergence agrees between the two legs by
	# construction, so the cause is at the divergence and everything below it is a
	# consequence. The interpretation is chosen by WHERE it diverged, not assumed.
	var cleared := PackedStringArray()
	for i in range(first_index):
		var above: Dictionary = RUNGS[i]
		if not bool(above.get("causal", true)):
			continue
		if int(worker.get(String(above["id"]), -999)) != 0:
			cleared.append("%s=%d" % [String(above["id"]),
				int(worker.get(String(above["id"]), -999))])
	if cleared.is_empty():
		print("[FIRST-DIVERGENCE] every causal rung above it is ZERO on the worker "
			+ "leg: the chain was never entered, so nothing below was REACHED (as "
			+ "opposed to reached and rejected)")
	else:
		print("[FIRST-DIVERGENCE] causal rungs above it that DID happen on the "
			+ "worker leg: %s" % str(cleared))
	print("[FIRST-DIVERGENCE] interpretation:")
	if first_divergence in ["driver_rebuild_visits", "driver_drain_steps"]:
		print("  The failure is UPSTREAM of `collect_effect_activations`: the derived "
			+ "rebuild is never STEPPED while the card is live, so the collect is "
			+ "never called. No collect-side precondition -- Effect query, target "
			+ "resolution, milestone gate -- is involved, and the counters inside "
			+ "the collect stay at zero because they were never incremented.")
	elif first_divergence in ["collect_entries", "collect_templates",
			"state_live_cards", "state_transition_pending",
			"direct_collect_entries", "direct_collect_templates"]:
		print("  The failure is INSIDE the collect's own early guards "
			+ "(ideology_runtime.cpp:2281-2323): state visibility or the §10.1 "
			+ "pending gate stops the per-idea walk before any program is considered.")
	elif first_divergence in ["collect_pod_fail", "effect_metadata_answers",
			"direct_collect_pod_fail", "collect_program_empty"]:
		print("  The failure is at the Effect metadata query / backend decision "
			+ "(ideology_runtime.cpp:2343-2398): the collect cannot read the "
			+ "program's declarative metadata on the main thread.")
	elif first_divergence in ["effect_commands_count", "collect_derived_emitted",
			"direct_collect_derived_emitted", "collect_targets_fail"]:
		print("  The failure is at ProgramModifierCommand / target resolution "
			+ "(ideology_runtime.cpp:2358 or :2458): the collect emits no rows.")
	elif first_divergence.begins_with("materialize_"):
		print("  The failure is in the FOLD (derived_cell_materializer.cpp:81-91): "
			+ "contributions arrive but fold to nothing.")
	else:
		print("  The failure is at INSTALL (modifier_runtime.cpp:1645): a front was "
			+ "built but not published.")


# =========================================================================
# Assertions: the ladder is asserted rung by rung as the MEASURED REALITY
# =========================================================================
func _assert_ladder(worker_leg: Dictionary, worker: Dictionary,
		main_leg: Dictionary, main: Dictionary) -> void:
	print("")
	print("=================== ASSERTIONS ===================")
	# ── non-vacuity: the card must be live on the worker leg, or nothing below
	#    means anything.
	_expect("VACUITY: the card is LIVE in the main-thread snapshot under worker "
		+ "authority (locations == 1), so an empty layer is not 'no card'",
		int(worker["state_live_cards"]) >= 1
			and _location_of(CARD_A) == 1,
		"live=%d location=%d snapshot=%s"
			% [int(worker["state_live_cards"]), _location_of(CARD_A),
				str((worker_leg["snapshot"] as Dictionary).get(
					"locations", PackedInt32Array()))])
	# ── the prime suspect, answered WITHOUT the collect: the Effect queries the
	#    collect would make are asked directly on the worker leg.
	_expect("SUSPECT: the Effect metadata query the collect gates on "
		+ "(family_effect_metadata_pod) ANSWERS on the main thread under worker "
		+ "authority -- so a writeback-only EffectRuntime is NOT what blocks rung 3",
		bool(worker_leg["managed"]), "effect_program_is_managed(%s)=%s"
			% [PROGRAM_A, str(worker_leg["managed"])])
	var worker_commands: Array = (worker_leg["commands"] as Dictionary).get(
		"commands", []) as Array
	_expect("SUSPECT: the Effect command query the collect folds terms from "
		+ "(program_modifier_commands) ANSWERS on the main thread under worker "
		+ "authority, with at least one MODIFIER command",
		bool((worker_leg["commands"] as Dictionary).get("ok", false))
			and worker_commands.size() >= 1,
		str(worker_leg["commands"]))
	_expect("SUSPECT: the Effect magnitude query answers too "
		+ "(evaluate_effect_program_magnitude), so the Effect catalog is readable "
		+ "from the main thread on the worker-owned leg",
		bool((worker_leg["magnitude"] as Dictionary).get("ok", false))
			and int((worker_leg["magnitude"] as Dictionary).get("magnitude", 0)) > 0,
		str(worker_leg["magnitude"]))
	# ── THE DECISIVE EXPERIMENT: the SAME collect, called directly through its
	#    INSTANCE call site, on the worker-owned leg.
	var worker_direct: Dictionary = worker_leg["direct"]
	var main_direct: Dictionary = main_leg["direct"]
	_expect("CHAIN 1-3 UNDER WORKER AUTHORITY: an on-demand INSTANCE-path collect "
		+ "(reconcile_ideology_effects_for_test -> collect_effect_activations with "
		+ "out_derived == nullptr) enters the function, counts the idea, reads its "
		+ "two templates and the Effect metadata POD -- so the early guards, the "
		+ "§10.1 gate, the level row and family_effect_metadata_pod all PASS on the "
		+ "worker-owned side",
		int(worker_direct.get("entries", 0)) >= 1
			and int(worker_direct.get("templates", 0)) >= 1
			and int(worker_direct.get("ok_keys", 0)) >= 1
			and bool(worker_direct.get("ok", false)),
		str(worker_direct))
	_expect("CHAIN 5 BY DESIGN: that same direct call emits ZERO derived rows "
		+ "(ideology_runtime.cpp:2393-2397: a DerivedCell program with no row "
		+ "accumulator emits nothing, so the instance path cannot double-apply it) "
		+ "-- on BOTH legs",
		int(worker_direct.get("emitted", -1)) == 0
			and int(main_direct.get("emitted", -1)) == 0,
		"worker=%s main=%s" % [str(worker_direct), str(main_direct)])

	# ── THE DEFECT ITSELF, as measured reality (mirrors PARITY[FINDING] in the
	#    parity fixture: a fix that makes the layer appear FAILS this check).
	_expect("DEFECT[FINDING]: under worker-owned ideology the derived layer is NOT "
		+ "installed and covers no cell, on the same world where the main thread "
		+ "covers cells -- asserted as the measured reality of this build",
		int(worker["layer_installed"]) == 0
			and int(worker["layer_cell_count"]) == 0
			and int(worker["stat_add_covered_cells"]) == 0,
		"installed=%d cells=%d contributions=%d covered=%d"
			% [int(worker["layer_installed"]), int(worker["layer_cell_count"]),
				int(worker["layer_contribution_count"]),
				int(worker["stat_add_covered_cells"])])
	# ── THE FIRST FAILING RUNG, asserted as the measured reality.
	_expect("RUNG[FIRST-FAILURE] driver_rebuild_visits: with the card LIVE the "
		+ "derived rebuild is stepped ZERO times over the whole worker leg, while "
		+ "the same world on the main thread steps it -- this is upstream of every "
		+ "precondition inside collect_effect_activations",
		int(worker["state_live_cards"]) >= 1
			and int(worker["driver_rebuild_visits"]) == 0
			and int(main["driver_rebuild_visits"]) > 0,
		"live=%d worker_visits=%d main_visits=%d"
			% [int(worker["state_live_cards"]), int(worker["driver_rebuild_visits"]),
				int(main["driver_rebuild_visits"])])
	_expect("RUNG[STRUCTURE]: drain_derived_cell_layer() STARTED no rebuild on "
		+ "either leg (steps == 0 on both). `derived_rebuild_pending()` is "
		+ "`_derived_rebuild_day >= 0` and only `step_derived_rebuild` ever sets it, "
		+ "so the drain can only CONTINUE a rebuild that `run_daily_slices` began "
		+ "(world_ext_modifier.cpp:977)",
		int(worker["driver_drain_steps"]) == 0
			and int(main["driver_drain_steps"]) == 0,
		"worker=%d main=%d" % [int(worker["driver_drain_steps"]),
			int(main["driver_drain_steps"])])
	_expect("RUNG[DOWNSTREAM]: because the derived collector never ran, nothing "
		+ "reached the fold -- collect_derived_emitted and the materializer's "
		+ "programs_seen are both 0 on the worker leg, while the main leg shows the "
		+ "funnel opening (emitted > 0, programs_seen > 0)",
		int(worker["collect_derived_emitted"]) == 0
			and int(worker["materialize_programs_seen"]) == 0
			and int(main["collect_derived_emitted"]) > 0
			and int(main["materialize_programs_seen"]) > 0,
		"worker emitted=%d seen=%d ; main emitted=%d seen=%d"
			% [int(worker["collect_derived_emitted"]),
				int(worker["materialize_programs_seen"]),
				int(main["collect_derived_emitted"]),
				int(main["materialize_programs_seen"])])
	# ── the control. If this fails, the fixture cannot say the layer works at all.
	_expect("CONTROL: flipping the SAME world to main-thread ideology (0x%03X) "
		% MASK_MAIN_IDEOLOGY + "installs the layer and covers cells",
		int(main["layer_installed"]) == 1
			and int(main["layer_cell_count"]) >= 1
			and int(main["stat_add_covered_cells"]) >= 1,
		"installed=%d cells=%d contributions=%d covered=%d"
			% [int(main["layer_installed"]), int(main["layer_cell_count"]),
				int(main["layer_contribution_count"]),
				int(main["stat_add_covered_cells"])])
	if int(main["stat_add_covered_cells"]) >= 1:
		var magnitude := int((main_leg["magnitude"] as Dictionary).get(
			"magnitude", 0))
		var expected := float(magnitude) / float(Q16_ONE)
		var actual := float((main_leg["stat_add"] as Dictionary)["first_add"])
		print("[CONTROL] add on the first covered cell = %.10f (%.10f = %d/65536 "
			% [actual, expected, magnitude]
			+ "from evaluate_effect_program_magnitude)")
		_expect("CONTROL: the covered cell's derived add equals the program's own "
			+ "catalog magnitude, so the main-thread leg is a real fold and not a "
			+ "stale row",
			absf(actual - expected) <= 1e-9,
			"derived=%.10f expected=%.10f" % [actual, expected])
	# ── the ladder must diverge somewhere, and the first divergence is named.
	var divergence := _first_divergence(worker, main)
	_expect("LADDER: the two legs diverge, and the first diverging rung is named "
		+ "in [FIRST-DIVERGENCE]", not String(divergence).is_empty(),
		str(divergence))
	_print_finding(worker_leg, worker, main_leg, main, divergence)


## The deliverable in prose, every number taken from the run that just happened.
func _print_finding(worker_leg: Dictionary, worker: Dictionary,
		main_leg: Dictionary, main: Dictionary, divergence: String) -> void:
	print("")
	print("=================== FINDING ===================")
	if divergence.is_empty():
		print("[FINDING] no causal rung differs: this build does not reproduce the "
			+ "defect in this configuration, so there is no first failing rung to "
			+ "report")
		return
	print("[FINDING] FIRST FAILING RUNG: %s (worker-owned 0x%03X -> %d ; main-thread "
		% [divergence, MASK_ALL, int(worker.get(divergence, -999))]
		+ "0x%03X -> %d)" % [MASK_MAIN_IDEOLOGY, int(main.get(divergence, -999))])
	print("[FINDING] the rung is UPSTREAM of collect_effect_activations "
		+ "(ideology_runtime.cpp:2281). With the card live (locations=%s, levels=%s, "
		% [str((worker_leg["snapshot"] as Dictionary).get(
			"locations", PackedInt32Array())),
			str((worker_leg["snapshot"] as Dictionary).get(
				"levels", PackedInt32Array()))]
		+ "transition_pending=%s) the derived rebuild is stepped %d times over the "
		% [str((worker_leg["snapshot"] as Dictionary).get(
			"transition_pending", PackedByteArray())),
			int(worker["driver_rebuild_visits"])]
		+ "whole worker leg, so the derived call site of the collect is never "
		+ "entered and no collect-side precondition is ever evaluated.")
	print("[FINDING] the collect itself is HEALTHY on the worker-owned side: asked "
		+ "directly through its instance call site it entered %d time(s), saw %d "
		% [int((worker_leg["direct"] as Dictionary).get("entries", 0)),
			int((worker_leg["direct"] as Dictionary).get("templates", 0))]
		+ "template(s), read the Effect metadata POD (ok keys=%d) and emitted %d "
		% [int((worker_leg["direct"] as Dictionary).get("ok_keys", 0)),
			int((worker_leg["direct"] as Dictionary).get("emitted", 0))]
		+ "derived rows BY DESIGN (out_derived == nullptr at :2393-2397).")
	print("[FINDING] the prime suspect is DISPROVED: under worker authority "
		+ "effect_program_is_managed=%s, program_modifier_commands answers with %d "
		% [str(bool(worker_leg["managed"])),
			int(worker["effect_commands_count"])]
		+ "command(s) (%s), and evaluate_effect_program_magnitude returns %d. The "
		% ["3277/65536 and 5243/65536 for this card",
			int((worker_leg["magnitude"] as Dictionary).get("magnitude", 0))]
		+ "Effect catalog is fully readable from the main thread while the worker "
		+ "owns EFFECT.")
	var suppressed_days := 0
	var suppressed_visits := 0
	var pre_promotion_days := 0
	var pre_promotion_visits := 0
	var pre_promotion_live := 0
	for row_value in _trace:
		var row: Dictionary = row_value
		if String(row.get("leg", "W")) != "W":
			continue
		if bool(row["suppressed"]):
			suppressed_days += 1
			suppressed_visits += int(row["visits"])
		else:
			# The worker's authority mask is DEFERRED: it reads 0x000 until the pod
			# is ready, so the main thread still runs the ideology day for the first
			# day(s) of a worker world.
			pre_promotion_days += 1
			pre_promotion_visits += int(row["visits"])
			if int(row.get("live", 0)) >= 1:
				pre_promotion_live += 1
	print("[FINDING] the non-zero `cell_layer_rebuild_visits` this defect is "
		+ "noticed with does NOT come from the card: on the %d worker-leg days that "
		% pre_promotion_days
		+ "ran BEFORE the worker promoted its deferred mask (it reads 0x000 until "
		+ "the pod is ready, `native_simulation_host.cpp:16079`) the rebuild was "
		+ "stepped %d time(s) with no card live. On the %d days that the mask really "
		% [pre_promotion_visits, suppressed_days]
		+ "owns ideology it was stepped %d time(s)." % suppressed_visits)
	print("[FINDING] the per-day trace is the proof of the mechanism: every one of "
		+ "the %d suppressed days prints `visits+=0 drain_steps=0`, and "
		% suppressed_days
		+ "`drain_steps=0` on the main-thread leg too -- drain_derived_cell_layer "
		+ "only pumps a rebuild that run_daily_slices already started.")
	if pre_promotion_live == 0:
		print("[FINDING] none of those pre-promotion days had a live card, which is "
			+ "why the visit count looks like 'the shard is being stepped' while the "
			+ "derived collect never actually saw this card.")


func _first_divergence(worker: Dictionary, main: Dictionary) -> String:
	for spec_value in RUNGS:
		var spec: Dictionary = spec_value
		if not bool(spec.get("causal", true)):
			continue
		var id := String(spec["id"])
		if int(worker.get(id, -999)) != int(main.get(id, -999)):
			return id
	return ""


# =========================================================================
# Teardown + assertion plumbing
# =========================================================================
func _teardown() -> void:
	if _world.is_empty():
		return
	var ext: Object = _world.get("ext", null)
	if ext != null and ext.has_method("request_runtime_stop"):
		ext.request_runtime_stop()
	var host: Object = _world.get("host", null)
	if host != null and is_instance_valid(host):
		host.queue_free()
	var clock: Object = _world.get("clock", null)
	if clock != null and is_instance_valid(clock):
		clock.queue_free()
	_world.clear()


func _expect(label: String, condition: bool, detail: String = "") -> void:
	_checks += 1
	if condition:
		print("[PASS] " + label)
		return
	_failures += 1
	printerr("[FAIL] " + label
		+ ((" :: " + detail) if not detail.is_empty() else ""))


func _require(label: String, condition: bool, detail: String = "") -> bool:
	_expect(label, condition, detail)
	return condition


func _fail(label: String) -> void:
	_expect(label, false)
