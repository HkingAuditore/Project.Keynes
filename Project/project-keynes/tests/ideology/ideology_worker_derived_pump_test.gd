extends SceneTree

## DOES THE DERIVED CELL LAYER ACTUALLY APPEAR WHEN THE WORKER OWNS IDEOLOGY?
##
## WHY THIS FILE EXISTS
##
## `run_ideology_daily` returns `suppressed` under IDEOLOGY worker authority and it was
## the only production caller of `step_derived_rebuild`, so under worker authority the
## rebuild was never started and the derived cell layer produced NOTHING. A pump was
## landed for it (`DCWorldExt::step_ideology_derived_rebuild`, bound to GDScript, same
## `try_lock_economy_input_capture()` boundary as `step_ideology_instance_refresh`), and
## the full verifier went green with 62 fixtures -- but none of those fixtures can show
## the layer APPEARING, because the previous worker fixture
## (`ideology_worker_authority_parity_test.gd`) drives simulation days by hand and its
## `rebuild_visits` stayed at 8 with `installed=false`.
##
## This fixture answers the one question those 62 could not: with the pump actually
## called, does the layer install, and does it agree, cell for cell, with a leg where
## the ideology domain is written by the main thread?
##
## HOW THE PUMP IS DRIVEN (and why not through the host)
##
## The pump is invoked from `world_runtime_host.gd`'s
## `_step_ideology_instance_refresh_if_authoritative`, i.e. from the tick path. A `-s`
## fixture has no tick loop, so this fixture calls the BOUND METHOD itself:
##
##     ext.step_ideology_derived_rebuild(day)
##
## It returns a Dictionary, and the important shapes are:
##
##     { ok:true,  done:true,  pending:false, day:N }                     -> ran, finished
##     { ok:false, done:false, pending:true,  day:N }                     -> more slices
##     { ok:true,  done:false, pending:true,  day:N, code:"economy_day_inflight" }
##                                                                       -> LOCK BUSY
##
## The last one is NOT a failure. The worker holds the economy-input-capture mutex for
## the whole semantic day transaction (`native_simulation_host.cpp:15607-15609`), so a
## call landing inside that transaction cannot take the boundary. The facade then asks
## the worker to park at its next boundary (`request_main_boundary_service(IDEOLOGY)`)
## and the caller is expected to come back. `ok == false` is NOT a failure either: the
## sharded rebuild returns false from its collect step to mean "more slices are needed",
## which is why the loop below keys on `done`/`pending` and never on `ok`.
##
## A single attempt per day is therefore not enough, so this fixture retries, and
## RECORDS the attempts per day: "it worked" without that accounting could be luck.
##
## THE THREE LEGS
##
##   W  0xFFF  the worker owns ideology. This is the leg that used to produce nothing.
##              `run_ideology_daily` is suppressed, so the ONLY thing that can start
##              the derived rebuild here is the pump.
##   S  0xFEF  the mask the task names for the main-thread leg (0xFFF - 0x010).
##              MEASURED, not assumed: this leg builds and runs, but it never gets the
##              card live, because an equip started by the main-thread ideology runtime
##              needs the Effect day to settle its transition and `run_effect_daily`
##              reports `suppressed` here (EFFECT 0x020 is still worker-owned,
##              `world_ext_effect.cpp:844-852`). The equip is refused with
##              `ideology_effect_transition_rejected`, exactly the receipt the parity
##              fixture's B2 phase captured for the same split. 0xFCF (effect moved to
##              the main thread too) was tried by hand this round and additionally
##              stalls the worker with `day_wait_peer_stall_timeout` -- the same fault
##              the parity fixture records a couple of days after the ideology domain
##              leaves the worker. That second measurement is why this fixture does not
##              build a 0xFCF world; `MASK_SPLIT_WITH_EFFECT` is kept only so the
##              arithmetic of the two split masks is asserted.
##              The split leg is kept in the run so its numbers are reported, but it
##              cannot be the comparison leg (a card that never settles has no derived
##              program to compare).
##   M  no ACTIVE worker at all: every domain, ideology included, on the main thread,
##              and `run_ideology_daily` -- the production caller -- drives the rebuild.
##              This is the main-thread reference the worker leg is compared against,
##              built from the same seed with the same selector fixture. It is the same
##              construction `ideology_worker_authority_parity_test.gd` uses for its K1
##              leg, and the only leg in this build where the main thread produces a
##              derived front end to end without a worker owning any domain.
##
## WHAT IS ASSERTED (the four things that make this a proof)
##
##   1. THE LAYER APPEARS. `get_derived_cell_layer_report()` reports `installed=true`,
##      `cell_count>0` and `contribution_count>0` on the worker leg, and the numbers are
##      printed, not just asserted.
##   2. IT AGREES WITH THE MAIN-THREAD LEG. `get_effective_stat_value` is compared on
##      every one of the world's cells for `economy.city.birth_factor`; the maximum
##      absolute difference is reported and it must be 0.
##   3. NON-VACUITY. `cell_layer_rebuild_visits` grows from its starting value, the
##      `layer_generation` bumps off its starting value, the day the layer was first seen
##      installed is recorded, and the installed `derived_add` is checked against the
##      catalog magnitude of the card's own program -- so "the two legs agree" is the
##      agreement of the authored contribution, not of two zeros. An in-memory negative
##      control proves the comparator can say "different".
##   4. THE RETRY ACCOUNTING. Every pumped day records how many calls it took, how many
##      of those came back `economy_day_inflight`, and whether the first call got the
##      lock.
##
## WHAT IS REPORTED AND NOT ASSERTED
##
## The observed `confirmed_day` / `eligible_day` in the worker leg (plan 9.3). The
## eligible day is the earliest day a projection may be adopted, so the first installed
## day cannot precede it -- that IS asserted. The exact pair is printed because it
## mirrors the worker's `committed_day`, which advances on the worker's own clock.
##
## WHAT THIS FIXTURE DOES NOT PROVE
##
## It proves the C++ facade and the rebuild work when the pump is CALLED. It does not
## prove the production tick loop calls it: `world_runtime_host.gd:1413` guards the pump
## with `_generator.has_method("step_ideology_derived_rebuild")` and `MapGenerator`
## exposes `step_ideology_instance_refresh` but no such wrapper, so the guard is false
## and the tick-path pump is unreachable. That is measured and printed as `[HOST-PATH]`.
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_worker_derived_pump_test.gd

const WIDTH := 16
const HEIGHT := 12
const CELLS: int = WIDTH * HEIGHT
const SEED := 20261029
const WORKER_SPEED := 10.0
const Q16_ONE := 65536

# RuntimeDomainId -> bit, read out of `runtime_pod_protocol.h`.
const DOMAIN_EFFECT := 0x020
const DOMAIN_IDEOLOGY := 0x010
# 0xFFF grants every domain to the worker.
const MASK_WORKER_IDEOLOGY := 0xFFF
# The mask the task names for the main-thread leg: 0xFFF - 0x010. NOT 0xF7F, which
# clears GAMEPLAY_EFFECT 0x080 and still leaves ideology worker-owned.
const MASK_SPLIT := 0xFFF - 0x010
# Also measured (see the doc comment): ideology AND effect on the main thread. Moving
# the effect domain is what a split world would need to settle an equip, and it stalls
# the worker, so it is not the comparison leg either.
const MASK_SPLIT_WITH_EFFECT := 0xFFF - 0x010 - 0x020

const CARD := "idea.public_hygiene"
const PROGRAM := "ideology.effect.public_hygiene_l1"
const STAT_ADD := "economy.city.birth_factor"
const TAG_A := "cell.settlement"
const TAG_B := "cell.terrain.tundra"
const POPULATION_Q16 := 800 * Q16_ONE

const OP_DISCOVER := 1
const OP_GRANT_POINTS := 2
const OP_EQUIP := 5
const OP_ADD_UNDERSTANDING := 8

const MAX_SLICES_PER_DAY := 256
# A day is retried this many times. Measured contention ("the busiest day took it 8/8")
# is why the budget is 8 and not 2.
const ATTEMPTS_PER_DAY := 8
const ATTEMPT_SLEEP_MS := 2
# Days budgeted for the worker leg AFTER the card is live. The measured basis dates in
# this scenario are confirmed=D / eligible=D+1 well before day 10, so 22 is generous.
const PUMP_DAYS := 22
const MAIN_LEG_DAYS := 26
const SPLIT_LEG_DAYS := 8
const DAY_WAIT_MS := 9000
const POD_WAIT_MS := 4000
const GLOBAL_BUDGET_MS := 540000
const PEER_PASSES := 6
const PEER_BATCH := 96
const INFLIGHT_CODE := "economy_day_inflight"

const WorkerWaitHelper = preload("res://tests/ideology/ideology_worker_wait_helper.gd")
const DrawGateHelper = preload("res://tests/ideology/ideology_draw_gate_helper.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")

var _checks := 0
var _failures := 0
var _next_sequence := 1
var _run_started_ms := 0
var _budget_exhausted := false
var _worlds: Array = []
var _effect_cursor := 0


func _init() -> void:
	call_deferred("_run_and_finish")


func _run_and_finish() -> void:
	var code := await _run()
	print("=== ideology worker derived pump: %d checks, %d failures ===" % [
		_checks, _failures])
	quit(code if code != 0 else (0 if _failures == 0 else 1))


func _run() -> int:
	_run_started_ms = Time.get_ticks_msec()
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt unavailable")
		return 1
	_gate_facts()
	var worker_leg := await _run_worker_leg()
	var target_day := int(worker_leg.get("day", 0)) if not worker_leg.is_empty() else 0
	await _run_split_leg()
	var main_leg := await _run_main_leg(target_day)
	_compare_legs(worker_leg, main_leg)
	_teardown_all()
	return 0


# =========================================================================
# Phase 0: the mask facts, computed not assumed
# =========================================================================
func _gate_facts() -> void:
	_expect("GATE: 0xFFF grants the ideology bit to the worker",
		(MASK_WORKER_IDEOLOGY & DOMAIN_IDEOLOGY) != 0,
		"0x%03X" % MASK_WORKER_IDEOLOGY)
	_expect("GATE: the split mask is 0xFFF - 0x010 = 0xFEF and clears only the "
		+ "ideology bit",
		MASK_SPLIT == 0xFEF and (MASK_SPLIT & DOMAIN_IDEOLOGY) == 0
			and (MASK_SPLIT & DOMAIN_EFFECT) != 0
			and MASK_SPLIT == (MASK_WORKER_IDEOLOGY - DOMAIN_IDEOLOGY)
			and MASK_SPLIT_WITH_EFFECT == (MASK_SPLIT - DOMAIN_EFFECT),
		"0x%03X / 0x%03X" % [MASK_SPLIT, MASK_SPLIT_WITH_EFFECT])


# =========================================================================
# Phase 1: the worker leg -- the leg that used to produce nothing
# =========================================================================
func _run_worker_leg() -> Dictionary:
	print("[W] building world: ACTIVE worker, mask 0x%03X (the worker owns ideology; "
		% MASK_WORKER_IDEOLOGY + "the main-thread ideology day is suppressed)")
	var w := await _build_world({
		"name": "W-worker-ideology",
		"width": WIDTH, "height": HEIGHT, "seed": SEED,
		"foreign_count": 1,
		"authority": true,
		"shadow_on_generate": true,
		"parity_forcing": true,
		"mask": MASK_WORKER_IDEOLOGY,
	}, true)
	if w.is_empty():
		_fail("W: the ACTIVE worker world builds")
		return {}
	_worlds.append(w)
	w["pump"] = true
	_install_selector_fixture(w, "W")
	var opening := _layer_state(w["ext"])
	w["visits_at_start"] = int(opening["cell_layer_rebuild_visits"])
	w["generation_at_start"] = int(opening["layer_generation"])
	print("[W] starting counters: rebuild_visits=%d layer_generation=%d installed=%s "
		% [int(w["visits_at_start"]), int(w["generation_at_start"]),
			str(opening["installed"])]
		+ "cells=%d contributions=%d"
		% [int(opening["cell_count"]), int(opening["contribution_count"])])
	_drive_days(w, 3)
	var report: Dictionary = w["ext"].get_runtime_thread_report()
	var mask := int(report.get("authoritative_domain_mask", -1))
	print("[W] worker report after 3 days: state=%s mode=%s mask=0x%03X ready=%s "
		% [String(report.get("simulation_host_state", "?")),
			String(report.get("simulation_thread_mode", "?")), mask,
			str(report.get("simulation_worker_ready", "?"))]
		+ "fault='%s' pod_day=%s"
		% [String(report.get("fault_code", "")),
			str(report.get("ideology_pod_committed_day", "?"))])
	_expect("W: the worker reports mask 0x%03X, so it owns the ideology domain "
		% MASK_WORKER_IDEOLOGY + "(the mask is DEFERRED and reads 0x000 until the pod "
		+ "is ready, so it is read after days, not at build time)",
		mask == MASK_WORKER_IDEOLOGY and (mask & DOMAIN_IDEOLOGY) != 0,
		"mask=0x%03X blocker='%s'" % [mask, String(report.get(
			"simulation_worker_blocker", ""))])
	_expect("W: the main-thread ideology day IS suppressed (path=IDEOLOGY_WORKER), "
		+ "which is exactly why the derived rebuild needs the pump",
		bool(w["last_suppressed"])
			and String((w["last_ideology"] as Dictionary).get("path", "")) \
				== "IDEOLOGY_WORKER",
		str(w["last_ideology"]))
	_report_host_path(w)
	await _equip_card(w, CARD, "W", 10)
	# ---- the pump, day by day, with the retry accounting ----------------
	var first_day := int(w["tick"])
	for _index in range(PUMP_DAYS):
		if bool(w.get("faulted", false)) or _budget_exhausted:
			break
		_drive_day(w)
		if int(w["first_installed_day"]) >= 0:
			break
	var day_at_capture := int(w["tick"])
	var final := _layer_state(w["ext"])
	print("[W] after %d pumped days (day %d -> %d): installed=%s cells=%d "
		% [int(w.get("pumped_days", 0)), first_day, day_at_capture,
			str(final["installed"]), int(final["cell_count"])]
		+ "contributions=%d stats=%d generation=%d sample_day=%d rebuild_visits=%d "
		% [int(final["contribution_count"]), int(final["stat_count"]),
			int(final["layer_generation"]), int(final["sample_day"]),
			int(final["cell_layer_rebuild_visits"])]
		+ "confirmed=%d eligible=%d gated=%d fault='%s'"
		% [int(final["basis_confirmed_day"]), int(final["basis_eligible_day"]),
			int(final["gated_by_eligibility"]), _worker_fault(w["ext"])])
	_print_pump_table(w)

	# ---- assertion 1: the layer appears --------------------------------
	_expect("W[LAYER]: the derived cell layer appears under worker authority "
		+ "(installed=true, cell_count>0, contribution_count>0)",
		bool(final["installed"]) and int(final["cell_count"]) > 0
			and int(final["contribution_count"]) > 0,
		"installed=%s cells=%d contributions=%d visits=%d day=%d fault='%s'"
			% [str(final["installed"]), int(final["cell_count"]),
				int(final["contribution_count"]),
				int(final["cell_layer_rebuild_visits"]), day_at_capture,
				_worker_fault(w["ext"])])
	# ---- assertion 3: non-vacuity --------------------------------------
	_expect("W[NON-VACUITY]: the rebuild really ran -- cell_layer_rebuild_visits "
		+ "grew from its starting value",
		int(final["cell_layer_rebuild_visits"]) > int(w["visits_at_start"]),
		"visits %d -> %d" % [int(w["visits_at_start"]),
			int(final["cell_layer_rebuild_visits"])])
	_expect("W[NON-VACUITY]: the installed layer bumped layer_generation off its "
		+ "starting value (0 means the front was never installed)",
		int(final["layer_generation"]) > int(w["generation_at_start"]),
		"generation %d -> %d" % [int(w["generation_at_start"]),
			int(final["layer_generation"])])
	_expect("W[NON-VACUITY]: the day the layer was first seen installed is recorded",
		int(w["first_installed_day"]) > 0,
		"first_installed_day=%d pumped_days=%d"
			% [int(w["first_installed_day"]), int(w.get("pumped_days", 0))])
	# Plan 9.3, as an assertion rather than a print: a projection is confirmed on day D
	# and eligible no earlier than D+1, so the layer cannot install BEFORE its
	# eligibility day.
	var eligible_at_install := int(w.get("eligible_at_first_install", -1))
	_expect("W[9.3]: the layer did not install before the basis eligibility day "
		+ "(confirmed=D, eligible=D+1)",
		int(w["first_installed_day"]) >= 0
			and eligible_at_install >= 0
			and int(w["first_installed_day"]) >= eligible_at_install
			and eligible_at_install == int(w.get("confirmed_at_first_install", -2)) + 1,
		"first_installed_day=%d confirmed=%d eligible=%d"
			% [int(w["first_installed_day"]),
				int(w.get("confirmed_at_first_install", -1)), eligible_at_install])
	_expect("W[9.3]: the worker leg mirrored real basis dates (they used to be -1/-1, "
		+ "which left the eligibility gate permanently open)",
		int(final["basis_confirmed_day"]) >= 0
			and int(final["basis_eligible_day"]) == int(final["basis_confirmed_day"]) + 1,
		"confirmed=%d eligible=%d" % [int(final["basis_confirmed_day"]),
			int(final["basis_eligible_day"])])
	# ---- assertion 4: the retry accounting is complete -----------------
	var days: Array = w.get("days", [])
	var pumped := 0
	var attempts_total := 0
	var inflight_total := 0
	var first_lock_days := 0
	var bad_rows := 0
	for row_value in days:
		var row: Dictionary = row_value
		if not bool(row.get("pumped", false)):
			continue
		pumped += 1
		attempts_total += int(row["attempts"])
		inflight_total += int(row["inflight"])
		if bool(row["first_lock"]):
			first_lock_days += 1
		if int(row["attempts"]) < 1 or int(row["attempts"]) > ATTEMPTS_PER_DAY \
				or int(row["inflight"]) < 0 \
				or int(row["inflight"]) > int(row["attempts"]):
			bad_rows += 1
	print("[W][RETRY] pumped_days=%d calls=%d inflight=%d first_call_got_lock=%d/%d "
		% [pumped, attempts_total, inflight_total, first_lock_days, pumped]
		+ "incomplete_rows=%d" % bad_rows)
	_expect("W[RETRY]: every pumped day recorded a complete attempt ledger "
		+ "(1..%d calls, inflight <= calls)" % ATTEMPTS_PER_DAY,
		pumped > 0 and bad_rows == 0,
		"pumped=%d bad_rows=%d calls=%d inflight=%d"
			% [pumped, bad_rows, attempts_total, inflight_total])
	# ---- the absolute magnitude: the number that agrees is the AUTHORED one ----
	var probe := _probe_all_cells(w["ext"], STAT_ADD, int(w["cells"]))
	var magnitude := _program_magnitude(w, PROGRAM, "W")
	var expected := float(magnitude) / float(Q16_ONE)
	var first_cell := -1
	var present: PackedByteArray = probe["present"]
	for cell in range(present.size()):
		if present[cell] != 0:
			first_cell = cell
			break
	var observed := 0.0
	if first_cell >= 0:
		observed = float((probe["add"] as PackedFloat64Array)[first_cell])
	print("[W][MAGNITUDE] %s magnitude=%d expected add=%.10f observed=%.10f "
		% [PROGRAM, magnitude, expected, observed]
		+ "covered=%d at cell %d"
		% [int(probe["covered"]), first_cell])
	_expect("W[MAGNITUDE]: the worker leg's installed add equals the catalog magnitude "
		+ "of the card's own program -- the layer carries the authored contribution, "
		+ "not an accidental zero",
		first_cell >= 0 and absf(observed - expected) <= 1e-9 and int(probe["covered"]) > 0,
		"first_cell=%d observed=%.10f expected=%.10f covered=%d"
			% [first_cell, observed, expected, int(probe["covered"])])
	return {
		"world": w, "day": day_at_capture, "state": final, "probe": probe,
		"magnitude": magnitude, "expected": expected,
	}


# =========================================================================
# Phase 2: the split leg the task names (mask 0xFEF) -- measured, not assumed
# =========================================================================
func _run_split_leg() -> Dictionary:
	print("[S] building world: ACTIVE worker, mask 0x%03X (IDEOLOGY 0x010 on the main "
		% MASK_SPLIT + "thread, EFFECT 0x020 still on the worker)")
	var w := await _build_world({
		"name": "S-split-ideology-main",
		"width": WIDTH, "height": HEIGHT, "seed": SEED,
		"foreign_count": 1,
		"authority": true,
		"shadow_on_generate": true,
		"parity_forcing": true,
		"mask": MASK_SPLIT,
	}, true)
	if w.is_empty():
		_fail("S: the split world builds")
		return {}
	_worlds.append(w)
	w["pump"] = false
	_zero_support_gates(w, "S")
	_install_selector_fixture(w, "S")
	_drive_days(w, 3)
	var report: Dictionary = w["ext"].get_runtime_thread_report()
	var mask := int(report.get("authoritative_domain_mask", -1))
	print("[S] worker report after 3 days: state=%s mask=0x%03X (requested 0x%03X) "
		% [String(report.get("simulation_host_state", "?")), mask, MASK_SPLIT]
		+ "fault='%s'" % String(report.get("fault_code", "")))
	_expect("S: the worker reports mask 0x%03X, so ideology is NOT worker "
		% MASK_SPLIT + "authoritative on this leg",
		mask == MASK_SPLIT and (mask & DOMAIN_IDEOLOGY) == 0,
		"mask=0x%03X blocker='%s'" % [mask, String(report.get(
			"simulation_worker_blocker", ""))])
	_expect("S: the main thread owns the ideology day (NOT suppressed), so "
		+ "`run_ideology_daily` -- not the pump -- would be the production caller here",
		not bool(w["last_suppressed"]), str(w["last_ideology"]))
	var last_effect: Dictionary = w.get("last_effect", {})
	print("[S] effect day: suppressed=%s path='%s'"
		% [str(last_effect.get("suppressed", false)),
			String(last_effect.get("path", ""))])
	_expect("S: the EFFECT day IS suppressed here (path=EFFECT_WORKER), so the Effect "
		+ "transaction an equip starts cannot be settled by this main thread -- the "
		+ "structural reason this mask cannot be the comparison leg",
		bool(last_effect.get("suppressed", false))
			and String(last_effect.get("path", "")) == "EFFECT_WORKER",
		"last_effect=%s" % str(last_effect))
	# `require_live = false`: this leg is a MEASUREMENT, not the comparison leg. The
	# check that the card never goes live would be a check for a capability this build
	# does not have, so what is asserted here is the mechanism (EFFECT_WORKER) and the
	# invariant below, and the outcome is printed.
	var equipped := await _equip_card(w, CARD, "S", 6, false)
	print("[S] equip outcome=%s location=%d last_error='%s'"
		% [str(equipped), _location_of(w, CARD),
			String(_snapshot(w).get("last_error", ""))])
	for _index in range(SPLIT_LEG_DAYS):
		if bool(w.get("faulted", false)) or _budget_exhausted:
			break
		_drive_day(w)
	var day := int(w["tick"])
	var state := _layer_state(w["ext"])
	var live := _location_of(w, CARD) == 1
	var installed := bool(state["installed"]) and int(state["cell_count"]) > 0
	print("[S][FINDING] after %d days: card_live=%s installed=%s cells=%d "
		% [day, str(live), str(installed), int(state["cell_count"])]
		+ "contributions=%d confirmed=%d eligible=%d rebuild_visits=%d fault='%s'"
		% [int(state["contribution_count"]), int(state["basis_confirmed_day"]),
			int(state["basis_eligible_day"]),
			int(state["cell_layer_rebuild_visits"]), _worker_fault(w["ext"])])
	# The invariant that holds in both worlds, so this is not a bug pinned as truth:
	# a leg installs a front exactly when a card is live on it.
	_expect("S: the split leg installs a front exactly when its card went live (both "
		+ "are reported above; this leg measured card_live=false, so there is nothing "
		+ "to compare against the worker leg on this mask)",
		installed == live and (live or not installed),
		"card_live=%s installed=%s cells=%d" % [str(live), str(installed),
			int(state["cell_count"])])
	return {"world": w, "day": day, "state": state, "live": live}


# =========================================================================
# Phase 3: the main-thread reference leg -- no ACTIVE worker at all
# =========================================================================
func _run_main_leg(target_day: int) -> Dictionary:
	print("[M] building world: no ACTIVE worker (climate authority off), so every "
		+ "domain -- ideology included -- is on the main thread and "
		+ "`run_ideology_daily` is the production caller of the derived rebuild")
	var w := await _build_world({
		"name": "M-main-ideology",
		"width": WIDTH, "height": HEIGHT, "seed": SEED,
		"foreign_count": 1,
		"authority": false,
		"shadow_on_generate": false,
		"parity_forcing": false,
		"mask": MASK_WORKER_IDEOLOGY,
	}, false)
	if w.is_empty():
		_fail("M: the no-worker main-thread world builds")
		return {}
	_worlds.append(w)
	w["pump"] = false
	# The support gate on a main-thread leg reads a class-opinion snapshot that only the
	# worker path publishes in this build, so the authored stance table is zeroed through
	# the production `configure_ideologies` API -- the same necessity
	# `ideology_worker_authority_parity_test.gd` documents for its main-thread legs. It
	# changes WHICH cards may be equipped, never what a derived program computes.
	_zero_support_gates(w, "M")
	_install_selector_fixture(w, "M")
	var opening := _layer_state(w["ext"])
	w["visits_at_start"] = int(opening["cell_layer_rebuild_visits"])
	w["generation_at_start"] = int(opening["layer_generation"])
	_drive_days(w, 3)
	_expect("M: no domain is worker-authoritative on this leg (the worker was never "
		+ "started), so the main thread owns the ideology day",
		not bool(w["last_suppressed"]), str(w["last_ideology"]))
	await _equip_card(w, CARD, "M", 10)
	var first_day := int(w["tick"])
	for _index in range(MAIN_LEG_DAYS):
		if bool(w.get("faulted", false)) or _budget_exhausted:
			break
		_drive_day(w)
		if int(w["first_installed_day"]) >= 0 and int(w["tick"]) >= target_day:
			break
	var day_at_capture := int(w["tick"])
	var final := _layer_state(w["ext"])
	print("[M] after day %d -> %d: installed=%s cells=%d contributions=%d "
		% [first_day, day_at_capture, str(final["installed"]),
			int(final["cell_count"]), int(final["contribution_count"])]
		+ "stat_count=%d generation=%d sample_day=%d rebuild_visits=%d confirmed=%d "
		% [int(final["stat_count"]), int(final["layer_generation"]),
			int(final["sample_day"]), int(final["cell_layer_rebuild_visits"]),
			int(final["basis_confirmed_day"])]
		+ "eligible=%d" % int(final["basis_eligible_day"]))
	_expect("M[LAYER]: the main-thread leg installs the layer (the reference the worker "
		+ "leg is compared against is not empty)",
		bool(final["installed"]) and int(final["cell_count"]) > 0
			and int(final["contribution_count"]) > 0,
		"installed=%s cells=%d contributions=%d day=%d"
			% [str(final["installed"]), int(final["cell_count"]),
				int(final["contribution_count"]), day_at_capture])
	var probe := _probe_all_cells(w["ext"], STAT_ADD, int(w["cells"]))
	print("[M] probe: covered=%d add_sum=%.10f"
		% [int(probe["covered"]), float(probe["add_sum"])])
	return {
		"world": w, "day": day_at_capture, "state": final, "probe": probe,
	}


# =========================================================================
# Phase 4: the per-cell comparison
# =========================================================================
func _compare_legs(worker_leg: Dictionary, main_leg: Dictionary) -> void:
	_negative_control()
	if worker_leg.is_empty() or main_leg.is_empty():
		_fail("PARITY: both legs produced a capture (a leg could not be measured)")
		return
	var diff := _compare_probes(worker_leg["probe"], main_leg["probe"])
	var worker_state: Dictionary = worker_leg["state"]
	var main_state: Dictionary = main_leg["state"]
	var worker_covered := int((worker_leg["probe"] as Dictionary)["covered"])
	var main_covered := int((main_leg["probe"] as Dictionary)["covered"])
	print("[PARITY] cells compared=%d covered(worker)=%d covered(main)=%d "
		% [int(diff["cells"]), worker_covered, main_covered]
		+ "presence_mismatch=%d max_abs_add_diff=%.10f max_abs_value_diff=%.10f "
		% [int(diff["presence_mismatch"]), float(diff["max_abs_add_diff"]),
			float(diff["max_abs_value_diff"])]
		+ "cell_count=%d/%d contributions=%d/%d generation=%d/%d day=%d/%d"
		% [int(worker_state["cell_count"]), int(main_state["cell_count"]),
			int(worker_state["contribution_count"]),
			int(main_state["contribution_count"]),
			int(worker_state["layer_generation"]),
			int(main_state["layer_generation"]),
			int(worker_leg["day"]), int(main_leg["day"])])
	_expect("PARITY: every cell of %s agrees between the two legs -- the max absolute "
		% STAT_ADD + "difference is exactly 0 and both legs cover the same cells",
		int(diff["cells"]) == CELLS and int(diff["presence_mismatch"]) == 0
			and float(diff["max_abs_add_diff"]) == 0.0
			and float(diff["max_abs_value_diff"]) == 0.0
			and worker_covered > 0 and worker_covered == main_covered,
		"cells=%d presence_mismatch=%d max_abs_add_diff=%.10f "
			% [int(diff["cells"]), int(diff["presence_mismatch"]),
				float(diff["max_abs_add_diff"])]
			+ "max_abs_value_diff=%.10f covered=%d/%d"
			% [float(diff["max_abs_value_diff"]), worker_covered, main_covered])
	_expect("PARITY: the two legs report the same front shape (cell_count and "
		+ "contribution_count), so the agreement is over the same structure",
		int(worker_state["cell_count"]) == int(main_state["cell_count"])
			and int(worker_state["contribution_count"]) \
				== int(main_state["contribution_count"]),
		"cell_count=%d/%d contributions=%d/%d"
			% [int(worker_state["cell_count"]), int(main_state["cell_count"]),
				int(worker_state["contribution_count"]),
				int(main_state["contribution_count"])])


## The comparator must be able to say "different", in memory, before it is trusted with
## two worlds. Flips one presence byte and moves one add by 1e-9.
func _negative_control() -> void:
	var probe := {
		"present": PackedByteArray([1, 1, 0]),
		"add": PackedFloat64Array([0.05, 0.0, 0.0]),
		"value": PackedFloat64Array([1.05, 1.0, 1.0]),
	}
	var same_diff := _compare_probes(probe, probe)
	_expect("NEG: identical probes compare equal with 0 mismatches",
		int(same_diff["presence_mismatch"]) == 0
			and float(same_diff["max_abs_add_diff"]) == 0.0, str(same_diff))
	var moved := {
		"present": PackedByteArray([1, 0, 0]),
		"add": PackedFloat64Array([0.05 + 1e-9, 0.0, 0.0]),
		"value": PackedFloat64Array([1.05, 1.0, 1.0]),
	}
	var moved_diff := _compare_probes(moved, probe)
	_expect("NEG: one flipped presence byte and one 1e-9 add are BOTH reported",
		int(moved_diff["presence_mismatch"]) == 1
			and float(moved_diff["max_abs_add_diff"]) > 0.0, str(moved_diff))


# =========================================================================
# the host tick path, measured rather than assumed
# =========================================================================
## `world_runtime_host.gd:1413` only pumps when the GENERATOR exposes the facade method.
## That guard is measured here: if it is false, the production tick loop cannot reach
## the pump and only a direct call (what this fixture does) can.
func _report_host_path(w: Dictionary) -> void:
	var host = w["host"]
	var generator = w["generator"]
	var ext: Object = w["ext"]
	var ext_has: bool = ext.has_method("step_ideology_derived_rebuild")
	var generator_has: bool = generator != null \
		and generator.has_method("step_ideology_derived_rebuild")
	var host_setter: bool = host != null \
		and host.has_method("_step_ideology_instance_refresh_if_authoritative")
	print("[HOST-PATH] DCWorldExt.step_ideology_derived_rebuild bound=%s | "
		% str(ext_has)
		+ "MapGenerator exposes it=%s | host pump function present=%s"
		% [str(generator_has), str(host_setter)])
	_expect("HOST-PATH: the facade is BOUND on DCWorldExt, so a caller can step the "
		+ "derived rebuild directly under worker authority",
		ext_has, "ext.has_method(step_ideology_derived_rebuild)=false")
	if not generator_has:
		print("[HOST-PATH][FINDING] the production tick path cannot reach the pump: "
			+ "`world_runtime_host.gd:_step_ideology_instance_refresh_if_authoritative` "
			+ "guards it with `_generator.has_method(\"step_ideology_derived_rebuild\")` "
			+ "and MapGenerator has no such wrapper (it has "
			+ "`step_ideology_instance_refresh` only), so the guard is false and the "
			+ "tick-path pump never runs. This fixture therefore calls the bound method "
			+ "itself, exactly as the task requires.")


# =========================================================================
# world construction
# =========================================================================
func _build_world(spec: Dictionary, worker: bool) -> Dictionary:
	var width := int(spec.get("width", WIDTH))
	var height := int(spec.get("height", HEIGHT))
	var seed := int(spec.get("seed", SEED))
	var name := String(spec.get("name", "world"))
	var started := Time.get_ticks_msec()
	print("[BUILD/%s] generating %dx%d seed=%d mask=0x%03X authority=%s"
		% [name, width, height, seed, int(spec.get("mask", MASK_WORKER_IDEOLOGY)),
			str(spec.get("authority", false))])
	var clock := WorldClock.new()
	clock.auto_start = false
	clock.initial_speed = 1.0
	clock.debug_step_log = false
	get_root().add_child(clock)
	clock.pause(true)
	var host := WorldRuntimeHost.new()
	host.map_width = width
	host.map_height = height
	host.initial_seed = seed
	host.generate_test_economy_data = true
	host.test_economy_population_scale = 100
	host.runtime_climate_authority_enabled = bool(spec.get("authority", false))
	host.runtime_shadow_on_generate = bool(spec.get("shadow_on_generate", true))
	host.runtime_economy_auto_pod_active = true
	host.runtime_authority_domain_mask = int(spec.get("mask", MASK_WORKER_IDEOLOGY))
	host.runtime_parity_forcing = bool(spec.get("parity_forcing", false))
	get_root().add_child(host)
	await process_frame
	host.configure(null, null, clock)
	if bool(spec.get("authority", false)):
		host.set_climate_authority_override("force_on")
	var config := NewGameConfig.create_default()
	config.country.name = "W %s" % name
	config.country.foreign_count = int(spec.get("foreign_count", 1))
	config.base.map_width = width
	config.base.map_height = height
	config.base.initial_seed = seed
	config.apply_land_layout("two")
	var session: Dictionary = host.configure_session({
		"kind": "new_game", "config": config.to_dictionary()})
	if not _require("BUILD/%s: the session configures" % name,
			bool(session.get("ok", false)), str(session)):
		return {}
	await host.generate_world(seed)
	var generator: MapGenerator = host.get_generator()
	if not _require("BUILD/%s: production world generation succeeded" % name,
			generator != null):
		return {}
	var ext: Object = generator.get_data_core_world_ext()
	if not _require("BUILD/%s: production DCWorldExt is bound" % name, ext != null):
		return {}
	if worker:
		ext.set_runtime_ideology_parity_enabled(false)
		ext.set_runtime_clock(true, WORKER_SPEED)
	var w := {
		"name": name, "host": host, "clock": clock, "ext": ext,
		"generator": generator, "tick": 0, "cells": width * height,
		"handle": 0, "started_ms": Time.get_ticks_msec(),
		"last_ideology": {}, "last_suppressed": false, "last_effect": {},
		"slices": 0, "faulted": false, "fault_reported": false, "seed": seed,
		"pump": false, "days": [], "pumped_days": 0,
		"first_installed_day": -1, "confirmed_at_first_install": -1,
		"eligible_at_first_install": -1,
	}
	var handles := _country_handles(w)
	if not _require("BUILD/%s: the world has at least one country" % name,
			handles.size() >= 1, str(handles)):
		return {}
	w["handle"] = int(handles[0])
	w["tick"] = maxi(0, _world_day(ext))
	print("[BUILD/%s] ready in %d ms: countries=%d handle=%d start_day=%d"
		% [name, Time.get_ticks_msec() - started, handles.size(),
			int(w["handle"]), int(w["tick"])])
	return w


func _country_handles(w: Dictionary) -> PackedInt64Array:
	var ext: Object = w["ext"]
	var seen := {}
	var out := PackedInt64Array()
	for cell in range(int(w["cells"])):
		var summary: Dictionary = ext.get_country_cell_summary(cell)
		var handle := int(summary.get("country_handle", 0))
		if handle == 0 or seen.has(handle):
			continue
		seen[handle] = true
		out.append(handle)
	return out


# =========================================================================
# day driving
# =========================================================================
## The Country peer transport is bounded per call. One call per day leaves the queue
## growing, and the worker then faults a day with `day_wait_peer_stall_timeout` after
## 5 s. That is a property of the transport, not of this scenario, so it is drained.
func _service_peers(ext: Object, passes: int = PEER_PASSES) -> void:
	if not ext.has_method("service_country_worker_peer_adapter"):
		return
	for _pass in range(passes):
		ext.service_country_worker_peer_adapter(PEER_BATCH, true)


func _drive_days(w: Dictionary, days: int) -> void:
	for _index in range(days):
		_drive_day(w)


func _drive_day(w: Dictionary) -> Dictionary:
	if bool(w.get("faulted", false)):
		return {"ok": false, "faulted": true}
	if _budget_exhausted:
		return {"ok": false, "budget": true}
	if Time.get_ticks_msec() - _run_started_ms > GLOBAL_BUDGET_MS:
		_budget_exhausted = true
		print("[BUDGET] wall-clock budget exhausted at day %d of '%s'"
			% [int(w["tick"]), String(w["name"])])
		return {"ok": false, "budget": true}
	var ext: Object = w["ext"]
	var clock: WorldClock = w["clock"]
	var host: WorldRuntimeHost = w["host"]
	var fault := _worker_fault(ext)
	if not fault.is_empty():
		w["faulted"] = true
		if not bool(w.get("fault_reported", false)):
			w["fault_reported"] = true
			print("[%s][FINDING] the worker faulted with '%s' at day %d -- the "
				% [String(w["name"]), fault, int(w["tick"])]
				+ "remaining days are not driven and what was measured is reported")
		return {"ok": false, "fault": fault}
	w["tick"] = int(w["tick"]) + 1
	var day := int(w["tick"])
	clock.current_day = float(day)
	_service_peers(ext)
	if ext.has_method("publish_ideology_worker_inputs"):
		ext.publish_ideology_worker_inputs()
	host.run_daily_tick(day, clock.season_phase_for_day(day))
	host.finish_daily_tick(0.0, {})
	var pulses := 0
	while _has_hard_barrier(clock) and pulses < 400:
		clock.simulation_backpressure_pulse.emit(day)
		pulses += 1
	# Production settle handshake (`dispatch -> run_modifier_daily -> ack`) only on the
	# main-thread side; under worker authority the worker's own graph owns it and a
	# second handshake here would double-apply.
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
	w["last_ideology"] = ideology
	w["last_suppressed"] = bool(ideology.get("suppressed", false))
	w["slices"] = int(w.get("slices", 0)) + slices
	if not bool(ideology.get("suppressed", false)):
		for _slice in range(16):
			var effect_slice: Dictionary = ext.run_effect_daily(day)
			w["last_effect"] = effect_slice
			if not bool(effect_slice.get("ok", true)):
				break
			if bool(effect_slice.get("done", true)):
				break
		ext.dispatch_effect_native_modifier()
		ext.run_modifier_daily(day)
		ext.ack_effect_native_modifier()
	# ---- THE PUMP, and it is the whole point of this fixture -------------
	var pump := {}
	if bool(w.get("pump", false)):
		pump = _pump_derived(w, day)
		w["pumped_days"] = int(w.get("pumped_days", 0)) + 1
	var drained: Dictionary = ext.drain_derived_cell_layer(day)
	if bool(ideology.get("suppressed", false)):
		# Under worker authority the day is committed by the worker; wait for it so the
		# mirrored basis dates do not fall behind the calendar the pump is using.
		var before := int(ext.get_runtime_thread_report().get(
			"ideology_pod_committed_day", -1))
		_await_pod_day(w, before, POD_WAIT_MS)
	_record_day(w, day, pump, drained)
	return {"ok": true, "day": day, "slices": slices, "drained": drained,
		"pump": pump, "suppressed": bool(ideology.get("suppressed", false))}


## Calls the BOUND facade until it reports the rebuild finished, and accounts for every
## call. `economy_day_inflight` = the worker held the economy-input-capture boundary for
## its own day transaction; the facade has asked it to park, so a short sleep gives it
## the boundary window the next call needs. That is normal contention, not a failure.
##
## `ok == false` from the facade is NOT a failure: `step_derived_rebuild` returns false
## from its collect step to mean "the fold happens in later steps"
## (`ideology_runtime.cpp:7686`). Only `done && !pending` means finished.
func _pump_derived(w: Dictionary, day: int) -> Dictionary:
	var ext: Object = w["ext"]
	var calls := 0
	var inflight := 0
	var done := false
	var first_lock := false
	var pending := false
	var code := ""
	while calls < ATTEMPTS_PER_DAY:
		calls += 1
		var stepped: Dictionary = ext.step_ideology_derived_rebuild(day)
		code = String(stepped.get("code", ""))
		if code == INFLIGHT_CODE:
			inflight += 1
			OS.delay_msec(ATTEMPT_SLEEP_MS)
			continue
		if calls == 1:
			first_lock = true
		pending = bool(stepped.get("pending", true))
		if bool(stepped.get("done", false)) and not pending:
			done = true
			break
	return {"attempts": calls, "inflight": inflight, "acquired": calls - inflight,
		"done": done, "pending": pending, "first_lock": first_lock, "code": code}


func _record_day(w: Dictionary, day: int, pump: Dictionary, drained: Dictionary) -> void:
	var state := _layer_state(w["ext"])
	var pumped := not pump.is_empty()
	if pumped:
		print("[PUMP/%s] day=%d calls=%d acquired=%d inflight=%d first_call_got_lock=%s "
			% [String(w["name"]), day, int(pump.get("attempts", 0)),
				int(pump.get("acquired", 0)), int(pump.get("inflight", 0)),
				str(pump.get("first_lock", false))]
			+ "done=%s pending=%s drain_steps=%d | installed=%s cells=%d "
			% [str(pump.get("done", false)), str(pump.get("pending", false)),
				int(drained.get("steps", -1)), str(state["installed"]),
				int(state["cell_count"])]
			+ "contributions=%d gen=%d confirmed=%d eligible=%d gated=%d"
			% [int(state["contribution_count"]), int(state["layer_generation"]),
				int(state["basis_confirmed_day"]),
				int(state["basis_eligible_day"]),
				int(state["gated_by_eligibility"])])
	var row := {
		"day": day, "pumped": pumped, "attempts": int(pump.get("attempts", 0)),
		"acquired": int(pump.get("acquired", 0)),
		"inflight": int(pump.get("inflight", 0)),
		"first_lock": bool(pump.get("first_lock", false)),
		"done": bool(pump.get("done", false)),
		"drain_steps": int(drained.get("steps", -1)),
		"installed": bool(state["installed"]),
		"cells": int(state["cell_count"]),
		"contributions": int(state["contribution_count"]),
		"generation": int(state["layer_generation"]),
		"confirmed": int(state["basis_confirmed_day"]),
		"eligible": int(state["basis_eligible_day"]),
		"gated": int(state["gated_by_eligibility"]),
	}
	(w["days"] as Array).append(row)
	if int(w["first_installed_day"]) < 0 and bool(state["installed"]) \
			and int(state["cell_count"]) > 0:
		w["first_installed_day"] = day
		w["confirmed_at_first_install"] = int(state["basis_confirmed_day"])
		w["eligible_at_first_install"] = int(state["basis_eligible_day"])
		print("[%s][LAYER] the derived cell layer is installed for the first time on "
			% String(w["name"])
			+ "day %d: cells=%d contributions=%d generation=%d (confirmed=%d "
			% [day, int(state["cell_count"]),
				int(state["contribution_count"]), int(state["layer_generation"]),
				int(state["basis_confirmed_day"])]
			+ "eligible=%d)" % int(state["basis_eligible_day"]))


func _print_pump_table(w: Dictionary) -> void:
	var days: Array = w.get("days", [])
	print("[%s][TABLE] day | calls | acquired | inflight | done | first_lock | "
		% String(w["name"])
		+ "drain_steps | installed | cells | contributions | gen")
	for row_value in days:
		var row: Dictionary = row_value
		if not bool(row.get("pumped", false)):
			continue
		print("  %3d | %5d | %8d | %8d | %5s | %10s | %11d | %9s | %5d | %13d | %3d"
			% [int(row["day"]), int(row["attempts"]), int(row["acquired"]),
				int(row["inflight"]), str(row["done"]), str(row["first_lock"]),
				int(row["drain_steps"]), str(row["installed"]),
				int(row["cells"]), int(row["contributions"]),
				int(row["generation"])])


func _await_pod_day(w: Dictionary, before: int, timeout_ms: int) -> int:
	var ext: Object = w["ext"]
	var deadline := Time.get_ticks_msec() + timeout_ms
	var day := before
	while Time.get_ticks_msec() < deadline:
		var report: Dictionary = ext.get_runtime_thread_report()
		day = int(report.get("ideology_pod_committed_day", -1))
		if day > before:
			break
		if String(report.get("simulation_host_state", "")) in ["STOPPED", "FAULTED"]:
			break
		_service_peers(ext, 1)
		OS.delay_msec(2)
	return day


func _has_hard_barrier(clock: Object) -> bool:
	return bool(clock.has_hard_barrier()) if clock.has_method(
		"has_hard_barrier") else false


func _worker_fault(ext: Object) -> String:
	if ext == null or not ext.has_method("get_runtime_thread_report"):
		return ""
	return String(ext.get_runtime_thread_report().get("fault_code", ""))


func _world_day(ext: Object) -> int:
	if ext == null or not ext.has_method("get_runtime_thread_report"):
		return 0
	var report: Dictionary = ext.get_runtime_thread_report()
	for key in ["world_day", "ideology_pod_committed_day", "day"]:
		if report.has(key):
			return int(report[key])
	return 0


# =========================================================================
# ideology commands
# =========================================================================
func _submit(w: Dictionary, rows: Array) -> Dictionary:
	var ext: Object = w["ext"]
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
	var tick := int(w["tick"])
	for row_value in rows:
		var row: Dictionary = row_value
		opcodes.append(int(row.get("op", 0)))
		days.append(int(row.get("day", tick)))
		producers.append(1)
		sequences.append(_next_sequence)
		_next_sequence += 1
		handles.append(int(row.get("handle", w["handle"])))
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


func _equip_card(w: Dictionary, card: String, label: String,
		wait_days: int = 10, require_live: bool = true) -> bool:
	var dense := _dense_id(card)
	if dense < 0:
		_fail("%s: %s is absent from the compiled catalog" % [label, card])
		return false
	var gate: Dictionary = DrawGateHelper.grant_draw_gates(
		w["host"], card, int(w["handle"]), int(w["tick"]), _next_sequence)
	if not _require("%s: %s draw gates clear" % [label, card],
			bool(gate.get("ok", false)), str(gate)):
		return false
	_next_sequence = maxi(_next_sequence, int(gate.get(
		"next_sequence", _next_sequence)))
	_drive_day(w)
	# The same three-step preamble B1 uses for every card: one point grant, the
	# discover, and a zero-value understanding row. Skipping a step the runtime expects
	# is how "the card was never equipped" gets misread as "the layer does nothing".
	var preamble: Dictionary = _submit(w, [
		{"op": OP_GRANT_POINTS, "idea": -1, "value": 64 * Q16_ONE},
		{"op": OP_DISCOVER, "idea": dense},
		{"op": OP_ADD_UNDERSTANDING, "idea": dense, "value": 0},
	])
	if not _require("%s: %s grant/discover/understanding accepted"
			% [label, card], bool(preamble.get("ok", false)), str(preamble)):
		return false
	_drive_days(w, 2)
	var equipped: Dictionary = _submit(w, [{"op": OP_EQUIP, "idea": dense}])
	if not _require("%s: %s equip accepted" % [label, card],
			bool(equipped.get("ok", false)), str(equipped)):
		return false
	# The transition settles on a later day; wait for the card to be LIVE rather than
	# assuming a fixed number of days.
	await WorkerWaitHelper.wait_for(
		func() -> bool:
			return _location_of(w, card) == 1,
		wait_days, DAY_WAIT_MS * 2,
		func() -> void:
			_drive_day(w))
	if _location_of(w, card) == 1:
		if not require_live:
			return true
		return _require("%s: %s is live (location=1)" % [label, card], true)
	# Fallback, only on the main-thread legs: nothing else ACKs the equip's Effect
	# transactions there. The lifecycle below is the public one
	# (`poll -> preflight -> commit -> ack`), the fixture playing the acker.
	if not bool(w["last_suppressed"]):
		var acked := _ack_effect_transactions(w["ext"])
		print("[%s] effect-transaction fallback ack for %s: %s"
			% [label, card, str(acked)])
		_drive_days(w, 3)
	if not require_live:
		return _location_of(w, card) == 1
	return _require("%s: %s is live (location=1)" % [label, card],
		_location_of(w, card) == 1,
		"location=%d last_error='%s' snapshot_levels=%s"
			% [_location_of(w, card),
				String(_snapshot(w).get("last_error", "")),
				str(_snapshot(w).get("levels", PackedInt32Array()))])


## Drives every unfinished Effect transaction to ACKED, copied in shape from
## `ideology_b1_many_countries_test.gd:713-746`.
func _ack_effect_transactions(ext: Object) -> Dictionary:
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


func _snapshot(w: Dictionary) -> Dictionary:
	var ext: Object = w["ext"]
	return ext.get_ideology_snapshot(int(w["handle"]))


func _location_of(w: Dictionary, card: String) -> int:
	var dense := _dense_id(card)
	if dense < 0:
		return -1
	var snapshot := _snapshot(w)
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


## Zeroes the authored stance table through the PRODUCTION `configure_ideologies` API so
## `evaluate_support` takes its `stance_count == 0` short-circuit. The main-thread
## support gate reads `NativeEconomyRuntime::country_class_opinion_snapshot()` directly
## and refuses with `ideology_class_opinion_unavailable` when the snapshot does not line
## up; in this build only the worker path publishes that snapshot, so a main-thread leg
## cannot pass the gate without this. It changes WHICH cards may be equipped, never what
## a derived program computes.
func _zero_support_gates(w: Dictionary, label: String) -> bool:
	var economy_ir: Dictionary = EconomyCatalogScript.compile_native_catalog()
	var country_ir: Dictionary = economy_ir.duplicate(false)
	var compiled: Dictionary = IdeologyCatalogScript.load_default(
		).compile_native_catalog(country_ir, economy_ir)
	if not bool(compiled.get("ok", false)):
		return _require("%s: the ideology catalog compiles" % label, false,
			str(compiled.get("reason", "")))
	var native := compiled.duplicate(false)
	native.erase("ok")
	var count := (native["ideology_ids"] as PackedStringArray).size()
	var zeros := PackedInt32Array()
	zeros.resize(count + 1)
	native["stance_offsets"] = zeros
	native["stance_class_indices"] = PackedInt32Array()
	native["stance_adopt_q16"] = PackedInt32Array()
	native["stance_repeal_q16"] = PackedInt32Array()
	native["stance_promote_q16"] = PackedInt32Array()
	native["stance_adopt_min_q16"] = PackedInt32Array()
	native["stance_repeal_min_q16"] = PackedInt32Array()
	native["stance_promote_min_q16"] = PackedInt32Array()
	var thresholds := PackedInt32Array()
	thresholds.resize(count)
	native["adopt_thresholds_q16"] = thresholds
	native["repeal_thresholds_q16"] = thresholds.duplicate()
	native["promote_thresholds_q16"] = thresholds.duplicate()
	native["world_seed"] = int(w.get("seed", SEED))
	var applied: Dictionary = w["ext"].configure_ideologies(native)
	print("[%s] support gates zeroed: cards=%d applied=%s" % [label, count,
		str(applied.get("ok", "?"))])
	return _require("%s: the stance table is zeroed so the support gate has no "
		% label + "authored rows left", bool(applied.get("ok", false)), str(applied))


# =========================================================================
# the cell layer: tag fixture, capture, comparison
# =========================================================================
## Pins the two card predicates on the owned land cells and the population metric above
## their thresholds, exactly as `ideology_x6c_worker_test.gd` does for a worker world.
## `refresh_effect_input_digest_for_test()` is what makes the override visible to the
## pod, which resolves selectors against the published input digest.
func _install_selector_fixture(w: Dictionary, label: String) -> void:
	var ext: Object = w["ext"]
	if not ext.has_method("set_cell_tag_override_for_test"):
		return
	var cleared: Dictionary = ext.clear_cell_tag_overrides_for_test()
	_require("%s: prior tag overrides cleared" % label,
		bool(cleared.get("ok", false)), str(cleared))
	var metric := _effect_metric_id("cell.population")
	if metric >= 0:
		var population: Dictionary = ext.set_effect_metric_override_for_test(
			metric, POPULATION_Q16, true)
		_require("%s: cell.population pinned" % label,
			bool(population.get("ok", false)), str(population))
	var cells := _owned_land_cells(w, 8)
	var tagged := 0
	for cell in cells:
		for tag in [TAG_A, TAG_B]:
			var result: Dictionary = ext.set_cell_tag_override_for_test(
				String(tag), int(cell), true)
			if bool(result.get("ok", false)):
				tagged += 1
	print("[SETUP/%s] selector fixture: owned_land_cells=%d tags_set=%d metric=%d"
		% [label, cells.size(), tagged, metric])
	ext.refresh_effect_input_digest_for_test()


func _owned_land_cells(w: Dictionary, limit: int) -> PackedInt32Array:
	var ext: Object = w["ext"]
	var out := PackedInt32Array()
	var map = w["host"].get_current_map() if w["host"].has_method(
		"get_current_map") else null
	for cell in range(int(w["cells"])):
		var summary: Dictionary = ext.get_country_cell_summary(cell)
		if int(summary.get("country_handle", 0)) != int(w["handle"]):
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


func _layer_state(ext: Object) -> Dictionary:
	var layer: Dictionary = ext.get_derived_cell_layer_report()
	var ideology: Dictionary = ext.get_ideology_report()
	return {
		"installed": bool(layer.get("installed", false)),
		"cell_count": int(layer.get("cell_count", -1)),
		"contribution_count": int(layer.get("contribution_count", -1)),
		"stat_count": int(layer.get("stat_count", -1)),
		"layer_generation": int(layer.get("layer_generation", -1)),
		"sample_day": int(layer.get("sample_day", -1)),
		"cell_layer_rebuild_visits": int(ideology.get(
			"cell_layer_rebuild_visits", -1)),
		"derived_rebuild_pending": bool(ideology.get(
			"derived_rebuild_pending", false)),
		"basis_confirmed_day": int(ideology.get(
			"derived_basis_confirmed_day", -1)),
		"basis_eligible_day": int(ideology.get(
			"derived_basis_eligible_day", -1)),
		"gated_by_eligibility": int(ideology.get(
			"derived_rebuild_gated_by_eligibility", -1)),
	}


## The production read shape: entity_handle 0 with the CELL in the group slot, the pair
## `economy_runtime_family_buff.cpp` passes.
func _probe_all_cells(ext: Object, stat: String, cells: int) -> Dictionary:
	var present := PackedByteArray()
	present.resize(cells)
	var add := PackedFloat64Array()
	add.resize(cells)
	var value := PackedFloat64Array()
	value.resize(cells)
	var covered := 0
	var add_sum := 0.0
	for cell in range(cells):
		var probe: Dictionary = ext.get_effective_stat_value(stat, cell, 0, 1.0)
		if not bool(probe.get("ok", false)):
			continue
		present[cell] = 1 if bool(probe.get("derived_present", false)) else 0
		add[cell] = float(probe.get("derived_add", 0.0))
		value[cell] = float(probe.get("value", 1.0))
		if present[cell] != 0:
			covered += 1
			add_sum += add[cell]
	return {"present": present, "add": add, "value": value,
		"covered": covered, "add_sum": add_sum}


func _compare_probes(a: Dictionary, b: Dictionary) -> Dictionary:
	var cells := 0
	var presence_mismatch := 0
	var add_mismatch := 0
	var value_mismatch := 0
	var max_add_diff := 0.0
	var max_value_diff := 0.0
	var present_a: PackedByteArray = a["present"]
	var present_b: PackedByteArray = b["present"]
	var add_a: PackedFloat64Array = a["add"]
	var add_b: PackedFloat64Array = b["add"]
	var value_a: PackedFloat64Array = a["value"]
	var value_b: PackedFloat64Array = b["value"]
	for cell in range(mini(present_a.size(), present_b.size())):
		cells += 1
		if int(present_a[cell]) != int(present_b[cell]):
			presence_mismatch += 1
		var add_diff: float = absf(float(add_a[cell]) - float(add_b[cell]))
		if add_diff != 0.0:
			add_mismatch += 1
			max_add_diff = maxf(max_add_diff, add_diff)
		var value_diff: float = absf(float(value_a[cell]) - float(value_b[cell]))
		if value_diff != 0.0:
			value_mismatch += 1
			max_value_diff = maxf(max_value_diff, value_diff)
	return {"cells": cells, "presence_mismatch": presence_mismatch,
		"add_mismatch": add_mismatch, "value_mismatch": value_mismatch,
		"max_abs_add_diff": max_add_diff, "max_abs_value_diff": max_value_diff}


func _program_magnitude(w: Dictionary, program_key: String, label: String) -> int:
	var metrics := PackedInt64Array()
	metrics.resize(120)
	metrics.fill(0)
	var result: Dictionary = w["ext"].evaluate_effect_program_magnitude(
		program_key, metrics)
	_expect("%s: %s evaluates against the catalog" % [label, program_key],
		bool(result.get("ok", false)), str(result))
	return int(result.get("magnitude", 0))


# =========================================================================
# teardown + assertions
# =========================================================================
func _teardown_all() -> void:
	for index in range(_worlds.size() - 1, -1, -1):
		var w: Dictionary = _worlds[index]
		var ext: Object = w.get("ext", null)
		if ext != null and ext.has_method("request_runtime_stop"):
			ext.request_runtime_stop()
		var host: Object = w.get("host", null)
		if host != null and is_instance_valid(host):
			host.queue_free()
		var clock: Object = w.get("clock", null)
		if clock != null and is_instance_valid(clock):
			clock.queue_free()
	_worlds.clear()


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
