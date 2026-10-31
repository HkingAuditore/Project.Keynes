extends SceneTree

## AUTHORITY COMBINATIONS + MAIN-THREAD/WORKER PARITY for the derived cell layer.
##
## WHY THIS FILE EXISTS
##
## Plan v3 §18.1 lists `四种权威组合、跨 slice、输入暂缺、权威翻转` as unfinished and the
## §18.3 table (line 1666) still records it as `worker 夹具长期阻塞`. Plan §14.1 also
## schedules a fixture `ideology_cell_layer_worker_test.gd` for exactly these four
## combinations, and that file has never existed.
##
## The blocking claim was that a worker world cannot be driven from a `SceneTree`
## script. That is false: `ideology_x9b_family_target_worker_test.gd` builds a real
## production worker world (16x12, `runtime_authority_domain_mask`, `force_on`,
## `runtime_parity_forcing`) and passes 22/0. This fixture uses the same construction
## and the same wait helper, and it is the first fixture in the tree to combine
## WORKER AUTHORITY with the DERIVED CELL FRONT.
##
## WHAT IS ENUMERATED (§18.1)
##
## Authority is decided by two independent gates, and both are readable in code:
##
##   GATE 1 — the global ACTIVE gate. `WorldRuntimeHost._start_production_shadow_worker`
##   (`world_runtime_host.gd:828-895`) only sets `simulation_thread_mode = ACTIVE`,
##   `graph_coverage_complete = true` and `authoritative_domain_mask` when
##   `ClimateAuthorityPolicy.resolve()` says enabled (`climate_authority_policy.gd:64`).
##   With `threshold_cells = 0` in this build, `auto` and `force_on` are the SAME
##   decision, so the gate collapses to `enabled = requested && override != force_off`.
##   `_enumerate_authority_combinations()` computes all six cells of that matrix
##   instead of asserting a summary of it.
##
##   GATE 2 — the twelve-domain mask, one bit per `RuntimeDomainId`
##   (`runtime_pod_protocol.h:526-573`): INPUT_CAPTURE 0x001 … IDEOLOGY 0x010 …
##   COMMIT 0x800. `world_ext_simulation_host.cpp:605-638` explicitly allows a
##   PARTIAL mask ("掩码里没点到的域仍在主线程") and ORs COMMIT in, so a mask that
##   clears the ideology bit really does leave ideology on the main thread while the
##   worker owns the other domains. The mask is also DEFERRED: it stays 0 in the
##   report until the worker reaches its ready state
##   (`native_simulation_host.cpp:16079`), which is why every mask assertion below is
##   made after driving days, never at build time.
##
## The combinations this fixture CONFIGURES and asserts:
##
##   K1  no ACTIVE worker at all      `runtime_shadow_on_generate = false`,
##                                    climate authority off -> no worker thread,
##                                    every domain main-thread. This is the
##                                    main-thread REFERENCE leg and it is the only
##                                    leg that builds a derived front end to end.
##   P1  ACTIVE worker, mask 0xF8F    worker owns 8 domains; IDEOLOGY 0x010,
##                                    EFFECT 0x020 and MODIFIER 0x040 stay on the
##                                    main thread. A feasibility probe only: what is
##                                    asserted is `ready == (mask != 0)`, and the
##                                    measured outcome is printed either way.
##   K3  ACTIVE worker, mask 0xFFF    worker owns IDEOLOGY; the main-thread ideology
##                                    day is SUPPRESSED (`world_ext_ideology.cpp:323`)
##                                    and `run_ideology_daily` reports
##                                    `path=IDEOLOGY_WORKER`. The card equips through
##                                    the worker queue; the derived front is measured
##                                    here (§18.2 "worker").
##   K4  K3 + ideology parity         `set_runtime_ideology_parity_enabled(true)`
##                                    asks the main thread to publish a per-day
##                                    reference hash for the worker to compare
##                                    against (`native_simulation_host.cpp:3963`).
##   K2  ACTIVE worker, mask 0xFEF    the SAME world as K3 after an authority flip:
##                                    IDEOLOGY returns to the main thread while the
##                                    worker keeps the other eleven domains (including
##                                    EFFECT). The main thread then rebuilds the front
##                                    from the state the worker had already mirrored
##                                    -- which is what makes the two legs comparable
##                                    cell for cell.
##
## The combinations this fixture does NOT configure, and why:
##
##   K5  mask 0xF7F (what every other ideology worker fixture uses): clears
##       GAMEPLAY_EFFECT 0x080, not IDEOLOGY. It cannot change the ideology result,
##       so it is reported as a duplicate of K3 rather than measured again.
##   K6  `force_off` while `requested = true`: identical to K1 by construction of
##       `ClimateAuthorityPolicy.resolve`, which is why K1 covers it.
##   K7  a worker world with a HAND-BUILT MapData: plan §14.3 M1-8 measured a
##       `0xC0000005` in `world_ext_economy.cpp:929-930`. Every world here comes from
##       `host.generate_world()`, the only path that works.
##
## AUTHORITY FLIP (§18.1 `权威翻转`, plan §9.7) is performed ONCE at runtime with no
## world regeneration (K3 -> K2). It is verified by asking the runtime which writer
## owns the domain (`run_ideology_daily` reports `path`/`suppressed`) AND by the
## worker's own mask ledger, never by assuming the restart took.
##
## PARITY (§18.2 `新路径主线程／worker／恢复结果一致`)
##
## The comparison is per CELL, exactly, on `derived_present`, `derived_add` and the
## merged `value` of both stats the cards write, plus the front's `cell_count`,
## `contribution_count` and `layer_generation`. Non-vacuity is enforced four ways:
##
##   1. every capture asserts at least one cell is covered;
##   2. the birth-factor add is asserted to equal the SUM of the two cards' catalog
##      magnitudes (computed from `evaluate_effect_program_magnitude`, not hardcoded)
##      and the housing add is asserted NEGATIVE (the sign comes from the definition);
##   3. an in-memory negative control proves the comparator can fail;
##   4. the K1 leg proves the layer MOVES when the input changes (generation 1 -> 2,
##      add_sum 0.0500030518 -> 0.1000061035), and the K1-vs-K2 cross-world check
##      proves the main thread reproduces the same front in two independent worlds.
##
## THE EQUALITY ASSERTION BETWEEN THE LEGS IS NOT MADE, and that is deliberate: the
## two legs DISAGREE (the worker leg has no layer at all), so asserting equality
## would fail this fixture for the defect it exists to report, and asserting nothing
## would be the "two empty results" trap. The disagreement itself is asserted, with
## its exact shape, under the name `PARITY[FINDING]`.
##
## WHAT THIS FIXTURE CANNOT SHOW, SAID PLAINLY
##
##   * The derived cell front is not part of any worker POD section: the modifier POD
##     snapshot carries rows and buckets only (no derived fields in
##     `runtime_pod_protocol.h`), so whatever the worker does with the layer cannot
##     reach the main thread through `apply_runtime_modifier_snapshot`. K3 measures
##     whether the main-thread reader sees a worker-produced layer or a frozen one.
##   * B2's "64 countries" clause is measured against the production world path, which
##     caps countries at `NewGameConfig.MAX_FOREIGN_COUNT = 12` (+1 player). The
##     measurement is a refusal, printed with the number.
##   * The support gate needs a class-opinion snapshot that only the worker path
##     publishes in this build; the main-thread legs therefore zero the authored
##     stance table through the production `configure_ideologies()` API, exactly as
##     `ideology_cell_layer_realworld_over32_test.gd` does. That changes WHICH cards
##     may be equipped, never what a derived program computes.
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_worker_authority_parity_test.gd

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

const MASK_ALL := 0xFFF
## K2: ideology + effect + modifier stay on the main thread, so the whole
## ideology -> effect transition handshake is local.
const MASK_MAIN_IDEOLOGY := MASK_ALL \
	& ~DOMAIN_IDEOLOGY & ~DOMAIN_EFFECT & ~DOMAIN_MODIFIER
## K2s: the split (ideology main, effect worker).
const MASK_SPLIT_IDEOLOGY_MAIN := MASK_ALL & ~DOMAIN_IDEOLOGY
## The mask every existing ideology worker fixture uses. It clears GAMEPLAY_EFFECT
## (0x080), NOT ideology — asserted below so nobody reads it as "ideology off".
const MASK_WITHOUT_GAMEPLAY_EFFECT := 0xFFF & ~DOMAIN_GAMEPLAY_EFFECT

const CARD_A := "idea.public_hygiene"
const CARD_B := "idea.fire_keeping"
## A third card used only to probe the split-authority equip handshake. Kind 12,
## own territory, one derived program.
const CARD_C := "idea.kin_hearth"
const PROGRAM_A := "ideology.effect.public_hygiene_l1"
const PROGRAM_B := "ideology.effect.fire_keeping_l1"
## The stat `public_hygiene_l1` adds to and `fire_keeping_l1` adds to as well, so a
## cell covered by both carries a TWO-SOURCE fold and a stale front cannot hide.
const STAT_ADD := "economy.city.birth_factor"
## The stat `public_hygiene_l1`'s second (`.cut`) command writes.
const STAT_CUT := "economy.city.need.housing.consumption_factor"
const TAG_A := "cell.settlement"
const TAG_B := "cell.terrain.tundra"
const POPULATION_Q16 := 800 * Q16_ONE
const L2_THRESHOLD_Q16 := 524288

const OP_DISCOVER := 1
const OP_GRANT_POINTS := 2
const OP_EQUIP := 5
const OP_UNEQUIP := 6
const OP_ADD_UNDERSTANDING := 8

## A day is sliced; one call is not a day.
const MAX_SLICES_PER_DAY := 256
## Hang detectors, not performance gates.
const DAY_WAIT_MS := 9000
const POD_WAIT_MS := 5000
const STATE_WAIT_MS := 15000
const MASK_WAIT_MS := 12000
## Whole-run guard: the brief allows ~10 minutes; stop driving days past this and
## report a budget stop instead of hanging the session.
const GLOBAL_BUDGET_MS := 540000
## The worker faults a day at `RUNTIME_DAY_STALL_PEER_FAULT_TIMEOUT_MS = 5000`
## (`runtime_pod_protocol.h:54`) when a peer does not answer. The Country peer
## transport returns at most `max_results` per call, so one call per day is not
## enough once a scenario queues hundreds of commands.
const PEER_PASSES := 6
const PEER_BATCH := 96

## B2 = "同 B1，worker": 64 countries x 12 in-place cards.
const B2_ASKED_COUNTRIES := 64
const B2_ASKED_CARDS := 12
const B2_WIDTH := 32
const B2_HEIGHT := 16
## B1's twelve legal kind-12 cards, reused verbatim so B2 is "the same scenario".
const B2_CARD_KEYS: Array = [
	"idea.fire_keeping", "idea.kin_hearth", "idea.hunting_tradition",
	"idea.ever_normal_granary", "idea.open_ports", "idea.village_compact",
	"idea.three_field_rotation", "idea.scholar_office", "idea.standardization",
	"idea.household_weaving", "idea.coppice_rotation", "idea.public_hygiene",
]

const WorkerWaitHelper = preload("res://tests/ideology/ideology_worker_wait_helper.gd")
const DrawGateHelper = preload("res://tests/ideology/ideology_draw_gate_helper.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")
const ClimateAuthorityPolicyScript = preload("res://scripts/game/climate_authority_policy.gd")
const IdeologyProfileScript = preload("res://scripts/ideology/ideology_profile.gd")

var _checks := 0
var _failures := 0
var _next_sequence := 1
var _run_started_ms := 0
var _budget_exhausted := false
var _worlds: Array = []
var _fronts: Dictionary = {}
var _effect_cursor := 0


func _init() -> void:
	call_deferred("_run_and_finish")


func _run_and_finish() -> void:
	var code := await _run()
	print("=== ideology worker authority parity: %d checks, %d failures ===" % [
		_checks, _failures])
	quit(code if code != 0 else (0 if _failures == 0 else 1))


func _run() -> int:
	_run_started_ms = Time.get_ticks_msec()
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt unavailable")
		return 1
	_enumerate_authority_combinations()
	_negative_control()
	await _phase_k1()
	await _phase_modifier_main_probe()
	await _phase_k3_k4_k2()
	await _phase_b2()
	_teardown_all()
	return 0


# =========================================================================
# Phase 0: the gate matrix, computed instead of asserted
# =========================================================================
func _enumerate_authority_combinations() -> void:
	print("[AUTH] RuntimeDomainId bits: input_capture=0x%03X climate=0x%03X "
		% [DOMAIN_INPUT_CAPTURE, DOMAIN_CLIMATE]
		+ "country=0x%03X trigger_input=0x%03X ideology=0x%03X effect=0x%03X "
		% [DOMAIN_COUNTRY, DOMAIN_TRIGGER_INPUT, DOMAIN_IDEOLOGY,
			DOMAIN_EFFECT]
		+ "modifier=0x%03X gameplay_effect=0x%03X economy=0x%03X "
		% [DOMAIN_MODIFIER, DOMAIN_GAMEPLAY_EFFECT, DOMAIN_ECONOMY]
		+ "events=0x%03X visual=0x%03X commit=0x%03X"
		% [DOMAIN_EVENTS, DOMAIN_VISUAL, DOMAIN_COMMIT])
	_expect("AUTH: the ideology bit is domain 5 -> 0x010",
		DOMAIN_IDEOLOGY == 0x010, str(DOMAIN_IDEOLOGY))
	_expect("AUTH: 0xFEF is exactly 0xFFF with the ideology bit cleared",
		MASK_SPLIT_IDEOLOGY_MAIN == 0xFFF - DOMAIN_IDEOLOGY,
		"0x%03X" % MASK_SPLIT_IDEOLOGY_MAIN)
	_expect("AUTH: K2's mask keeps ideology/effect/modifier on the main thread",
		MASK_MAIN_IDEOLOGY == 0xF8F
			and (MASK_MAIN_IDEOLOGY & DOMAIN_IDEOLOGY) == 0
			and (MASK_MAIN_IDEOLOGY & DOMAIN_EFFECT) == 0
			and (MASK_MAIN_IDEOLOGY & DOMAIN_MODIFIER) == 0
			and (MASK_MAIN_IDEOLOGY & DOMAIN_CLIMATE) != 0,
		"0x%03X" % MASK_MAIN_IDEOLOGY)
	_expect("AUTH: the mask every existing worker fixture uses (0xF7F) still "
		+ "GRANTS ideology -- it clears GAMEPLAY_EFFECT 0x080",
		(MASK_WITHOUT_GAMEPLAY_EFFECT & DOMAIN_IDEOLOGY) != 0
			and (MASK_WITHOUT_GAMEPLAY_EFFECT & DOMAIN_GAMEPLAY_EFFECT) == 0,
		"0x%03X" % MASK_WITHOUT_GAMEPLAY_EFFECT)

	# GATE 1, all six cells. `ClimateAuthorityPolicy.resolve` is the function
	# `WorldRuntimeHost._resolve_climate_authority_policy` calls, so this is the
	# production decision, not a paraphrase of it.
	var policy = ClimateAuthorityPolicyScript.new()
	var enabled_by_key := {}
	for requested in [false, true]:
		for mode in ["auto", "force_on", "force_off"]:
			var set_result: Dictionary = policy.set_override_mode(mode)
			_expect("AUTH: override '%s' is accepted" % mode,
				bool(set_result.get("ok", false)), str(set_result))
			var verdict: Dictionary = policy.resolve(bool(requested), CELLS)
			var enabled := bool(verdict.get("enabled", false))
			enabled_by_key["%s/%s" % [str(requested), mode]] = enabled
			print("[AUTH] gate1 requested=%s override=%-9s -> active=%s "
				% [str(requested), mode, str(enabled)]
				+ "reason=%s threshold_cells=%s"
				% [String(verdict.get("reason", "?")),
					str(verdict.get("threshold_cells", "?"))])
	_expect("AUTH: requested=false is inactive under every override",
		not bool(enabled_by_key["false/auto"])
			and not bool(enabled_by_key["false/force_on"])
			and not bool(enabled_by_key["false/force_off"]),
		str(enabled_by_key))
	_expect("AUTH: requested=true + force_off is inactive",
		not bool(enabled_by_key["true/force_off"]), str(enabled_by_key))
	_expect("AUTH: requested=true + force_on is active",
		bool(enabled_by_key["true/force_on"]), str(enabled_by_key))
	_expect("AUTH: requested=true + auto is active in this build "
		+ "(threshold_cells=0 -> 'no affordable size, keep on')",
		bool(enabled_by_key["true/auto"]), str(enabled_by_key))
	print("[AUTH] combinations CONFIGURED: K1 no-worker | K2 mask 0x%03X "
		% MASK_MAIN_IDEOLOGY
		+ "(ideology main) | K2s mask 0x%03X (split: ideology main, effect "
		% MASK_SPLIT_IDEOLOGY_MAIN
		+ "worker) | K3 mask 0xFFF (ideology worker) | K4 K3+ideology-parity. "
		+ "NOT configured: K5 0xF7F (ideology bit same as K3) | K6 force_off "
		+ "(identical to K1) | K7 hand-built MapData (crashes, plan M1-8).")


## The comparator must be able to say "different", in memory, before it is trusted
## with two worlds. Flips one presence byte and moves one add by 1e-9.
func _negative_control() -> void:
	var probe := {
		"present": PackedByteArray([1, 1, 0]),
		"add": PackedFloat64Array([0.05, 0.0, 0.0]),
		"value": PackedFloat64Array([1.05, 1.0, 1.0]),
	}
	var same := {
		"present": PackedByteArray([1, 1, 0]),
		"add": PackedFloat64Array([0.05, 0.0, 0.0]),
		"value": PackedFloat64Array([1.05, 1.0, 1.0]),
	}
	var same_diff := _compare_probes(same, probe)
	_expect("NEG: identical probes compare equal with 0 mismatches",
		int(same_diff["mismatches"]) == 0, str(same_diff))
	var moved := {
		"present": PackedByteArray([1, 0, 0]),
		"add": PackedFloat64Array([0.05 + 1e-9, 0.0, 0.0]),
		"value": PackedFloat64Array([1.05, 1.0, 1.0]),
	}
	var moved_diff := _compare_probes(moved, probe)
	_expect("NEG: one flipped presence byte and one 1e-9 add are BOTH reported",
		int(moved_diff["mismatches"]) == 2
			and float(moved_diff["max_abs_add_diff"]) > 0.0,
		str(moved_diff))


# =========================================================================
# Phase 1: K1 — no ACTIVE worker at all
# =========================================================================
func _phase_k1() -> void:
	print("[K1] building world: runtime_shadow_on_generate=false, climate "
		+ "authority off -> no worker thread, every domain main-thread")
	var w := await _build_world({
		"name": "K1-no-worker",
		"width": WIDTH, "height": HEIGHT, "seed": SEED,
		"foreign_count": 1,
		"authority": false,
		"shadow_on_generate": false,
		"parity_forcing": false,
		"mask": MASK_ALL,
	})
	if w.is_empty():
		_fail("K1: the no-worker world builds")
		return
	_worlds.append(w)
	_zero_support_gates(w, "K1")
	_install_selector_fixture(w, "K1")
	_drive_days(w, 2)
	_expect("K1: no domain is worker-authoritative (the worker was never started)",
		not bool(w["last_suppressed"]), str(w["last_ideology"]))
	if not await _equip_card(w, CARD_A, "K1"):
		return
	if not await _await_front(w, 1, "K1 card A", 12):
		return
	var f1 := _capture_front(w, "K1-A")
	_fronts["K1-A"] = f1
	_magnitude_checks(w, f1, "K1-A", 1)
	if not await _equip_card(w, CARD_B, "K1"):
		return
	# FIXED DAY COUNT, not a contribution-count wait: two cards writing the same stat
	# merge into ONE contribution slot per cell, so `contribution_count` does not
	# change when the second card lands -- only `sum_add` does. A count-based wait
	# returns immediately and captures the front before the rebuild (measured in the
	# first working run of this fixture: generation 1->1 and add 0.05 where the fold
	# is 0.10).
	_drive_days(w, 6)
	var f2 := _capture_front(w, "K1-AB")
	_fronts["K1-AB"] = f2
	_magnitude_checks(w, f2, "K1-AB", 2)
	# The SECOND card must MOVE the layer. `contribution_count` is the wrong witness:
	# both cards write the same stat, so they merge into ONE contribution slot per
	# cell and only `sum_add` grows (measured: generation 1->2 with contributions
	# 2->2). The two witnesses used here are the layer generation and the summed add.
	_expect("K1: the second card moves the front (a two-source fold, not a no-op)",
		int(f2["layer_generation"]) > int(f1["layer_generation"])
			and float((f2[STAT_ADD] as Dictionary)["add_sum"])
				> float((f1[STAT_ADD] as Dictionary)["add_sum"]),
		"generation %d->%d add_sum %.10f->%.10f contributions %d->%d" % [
			int(f1["layer_generation"]), int(f2["layer_generation"]),
			float((f1[STAT_ADD] as Dictionary)["add_sum"]),
			float((f2[STAT_ADD] as Dictionary)["add_sum"]),
			int(f1["contribution_count"]), int(f2["contribution_count"])])


# =========================================================================
# Phase 2: the worker combinations
#   P1  mask 0xF8F — ideology+effect+MODIFIER on the main thread: does it run?
#   K3  mask 0xFFF — the worker owns ideology
#   K4  K3 + ideology parity
#   K2  flip to 0xFEF — the main thread owns ideology again (authority flip)
# =========================================================================
## P1 is a FEASIBILITY probe, not a scenario: plan §18.1 asks which authority
## combinations exist in this build, so a mask that cannot produce a running worker
## is a measurement, not a failure of the run. Nothing here asserts that the
## combination must work; it asserts the invariant that a worker which never became
## ready never reports an authority mask either.
func _phase_modifier_main_probe() -> void:
	print("[P1] probing mask 0x%03X (ideology, effect and MODIFIER all on the main "
		% MASK_MAIN_IDEOLOGY + "thread)")
	var w := await _build_world({
		"name": "P1-modifier-main",
		"width": WIDTH, "height": HEIGHT, "seed": SEED,
		"foreign_count": 1,
		"authority": true,
		"shadow_on_generate": true,
		"parity_forcing": true,
		"mask": MASK_MAIN_IDEOLOGY,
	})
	if w.is_empty():
		_fail("P1: the world builds")
		return
	w["health_is_measurement"] = true
	_worlds.append(w)
	_drive_days(w, 6)
	var report: Dictionary = w["ext"].get_runtime_thread_report()
	var mask := int(report.get("authoritative_domain_mask", -1))
	var ready := bool(report.get("simulation_worker_ready", false))
	var blocker := String(report.get("simulation_worker_blocker",
		report.get("coverage_blocker", "")))
	print("[P1] mask=0x%03X worker_ready=%s reported_mask=0x%03X blocker='%s' "
		% [MASK_MAIN_IDEOLOGY, str(ready), mask, blocker]
		+ "state=%s fault='%s' days=%d"
		% [String(report.get("simulation_host_state", "?")),
			String(report.get("fault_code", "")), int(w["tick"])])
	_expect("P1: a worker that never became ready never reports an authority mask "
		+ "(the two are 0/false together, or both set)",
		ready == (mask != 0), "ready=%s mask=0x%03X" % [str(ready), mask])
	if ready:
		print("[P1] this combination DID come up in this run; the earlier failure "
			+ "to reach a ready worker with mask 0x%03X is not reproduced here"
			% MASK_MAIN_IDEOLOGY)
	else:
		print("[P1][FINDING] mask 0x%03X keeps MODIFIER on the main thread and the "
			% MASK_MAIN_IDEOLOGY
			+ "worker never becomes ready: blocker='%s'. This combination exists in "
			% blocker
			+ "the mask space and cannot be run, so it cannot be part of any "
			+ "four-combination acceptance.")


func _phase_k3_k4_k2() -> void:
	print("[K3] building world: ACTIVE worker, mask 0xFFF (the worker owns "
		+ "ideology; the main-thread ideology day is suppressed)")
	var w := await _build_world({
		"name": "K3-worker-ideology",
		"width": WIDTH, "height": HEIGHT, "seed": SEED,
		"foreign_count": 1,
		"authority": true,
		"shadow_on_generate": true,
		"parity_forcing": true,
		"mask": MASK_ALL,
	})
	if w.is_empty():
		_fail("K3: the ACTIVE worker world builds")
		return
	_worlds.append(w)
	_install_selector_fixture(w, "K3")
	_drive_days(w, 3)
	var report: Dictionary = w["ext"].get_runtime_thread_report()
	var mask := int(report.get("authoritative_domain_mask", -1))
	print("[K3] worker report after 3 days: state=%s mode=%s mask=0x%03X "
		% [String(report.get("simulation_host_state", "?")),
			String(report.get("simulation_thread_mode", "?")), mask]
		+ "ready=%s fault='%s'"
		% [str(report.get("simulation_worker_ready", "?")),
			String(report.get("fault_code", ""))])
	_expect("K3: the worker reports mask 0xFFF, so it owns the ideology domain",
		mask == MASK_ALL and (mask & DOMAIN_IDEOLOGY) != 0,
		"mask=0x%03X blocker='%s'" % [mask, String(report.get(
			"simulation_worker_blocker", ""))])
	_expect("K3: the main-thread ideology day IS suppressed (path=IDEOLOGY_WORKER)",
		bool(w["last_suppressed"])
			and String((w["last_ideology"] as Dictionary).get("path", "")) \
				== "IDEOLOGY_WORKER",
		str(w["last_ideology"]))
	# The equip goes through the worker's own queue and its own ACK peers, which is
	# the configuration every existing worker fixture uses.
	var equipped := await _equip_card(w, CARD_A, "K3")
	print("[K3] equip outcome=%s main-thread snapshot levels=%s locations=%s"
		% [str(equipped), str(_snapshot(w).get("levels", PackedInt32Array())),
			str(_snapshot(w).get("locations", PackedInt32Array()))])
	# NOT `_await_front` here: the worker leg has no front to wait for. The statement
	# below is asserted as the MEASURED REALITY of this build, phrased as a positive
	# claim about the runtime's own counters so that a fix which makes the worker
	# materialise the layer fails this check instead of silently passing it.
	_drive_days(w, 6)
	var f_worker := _capture_front(w, "K3-A")
	_fronts["K3-A"] = f_worker
	print("[K3][FINDING] worker authority: card live (locations=%s) but the derived "
		% str(_snapshot(w).get("locations", PackedInt32Array()))
		+ "front is installed=%s cell_count=%d contributions=%d; the shard ran "
		% [str(f_worker["installed"]), int(f_worker["cell_count"]),
			int(f_worker["contribution_count"])]
		+ "cell_layer_rebuild_visits=%d with basis dates confirmed=%d eligible=%d"
		% [int(f_worker["cell_layer_rebuild_visits"]),
			int(f_worker["basis_confirmed_day"]),
			int(f_worker["basis_eligible_day"])])
	# FLIPPED 2026-10-29: this asserted the DEFECT ("stays EMPTY"). The defect is fixed.
	#
	# The host pump was landed, then made REACHABLE by adding
	# `MapGenerator::step_ideology_derived_rebuild`. This leg drives `host.run_daily_tick()`,
	# so it exercises the production path: installed=false/cells=0 became
	# installed=true/cells=2, and rebuild_visits went 8 -> 26.
	_expect("PARITY[FIXED]: under worker authority the derived front is INSTALLED and "
		+ "covers cells, driven through the host tick path -- the worker-authority "
		+ "derived-layer defect is closed",
		bool(f_worker["installed"]) and int(f_worker["cell_count"]) > 0
			and int(f_worker["cell_layer_rebuild_visits"]) > 0,
		"installed=%s cells=%d visits=%d confirmed=%d eligible=%d"
			% [str(f_worker["installed"]), int(f_worker["cell_count"]),
				int(f_worker["cell_layer_rebuild_visits"]),
				int(f_worker["basis_confirmed_day"]),
				int(f_worker["basis_eligible_day"])])

	# ── K4: ask for the ideology parity reference ────────────────────────
	var parity_on: Dictionary = w["ext"].set_runtime_ideology_parity_enabled(true)
	_expect("K4: set_runtime_ideology_parity_enabled(true) is accepted",
		bool(parity_on.get("ok", false)), str(parity_on))
	_drive_days(w, 3)
	var parity: Dictionary = w["ext"].get_runtime_thread_report()
	var compared := int(parity.get("ideology_parity_compared_count", -1))
	var matched := int(parity.get("ideology_parity_matched_count", -1))
	var published := int(parity.get("ideology_parity_reference_publish_count", -1))
	var skipped := int(parity.get("ideology_parity_reference_skipped_count", -1))
	var skip_reason := String(parity.get(
		"ideology_parity_reference_skip_reason", ""))
	print("[K4] ideology parity: compared=%d matched=%d reference_published=%d "
		% [compared, matched, published]
		+ "reference_skipped=%d reason='%s' worker_committed_day=%s"
		% [skipped, skip_reason,
			str(parity.get("ideology_pod_committed_day", "?"))])
	# Measured reality, asserted as such: the built-in comparator counts ZERO
	# compared days whenever the worker owns ideology, because the main thread
	# returns "suppressed" and publishes no reference
	# (`world_ext_ideology.cpp:323-333` + `native_simulation_host.cpp:3969-3986`).
	_expect("K4: the built-in ideology parity comparator counted 0 compared days "
		+ "while the worker owns the domain (measured reality, not a pass)",
		compared == 0,
		"compared=%d matched=%d published=%d skipped=%d reason=%s"
			% [compared, matched, published, skipped, skip_reason])
	_expect("K4: and the reference publisher was never even asked -- publish_count, "
		+ "skipped_count and the skip reason are all zero/empty, so there is no "
		+ "'refused' ledger entry to read either (measured)",
		published == 0 and skipped == 0 and skip_reason.is_empty(),
		"published=%d skipped=%d reason='%s'"
			% [published, skipped, skip_reason])
	var f_c4 := _capture_front(w, "K4-A")
	_fronts["K4-A"] = f_c4
	var k4_diff: Dictionary = _compare_fronts(f_worker, f_c4)
	_expect("K4: enabling the parity reference does not disturb the worker front",
		bool(k4_diff["exact"]), str(_compare_summary(k4_diff)))

	# ── authority flip K3 -> K2 (same world, no regeneration) ────────────
	if not await _flip_authority(w, MASK_SPLIT_IDEOLOGY_MAIN, "K3->K2"):
		return
	# From here on this world MEASURES the split combination, so a peer stall is data
	# rather than a fixture failure (measured: the worker faults with
	# `day_wait_peer_stall_timeout` a couple of days after the ideology domain
	# leaves it).
	w["health_is_measurement"] = true
	_expect("K2: after the flip the main thread owns the ideology day again "
		+ "(not suppressed)",
		not bool(w["last_suppressed"]), str(w["last_ideology"]))
	_drive_days(w, 8)
	var f_main := _capture_front(w, "K2-A")
	_fronts["K2-A"] = f_main

	# THE §18.2 NUMBER: per-cell, worker leg vs main-thread leg, same world, same
	# confirmed basis, only the writer of the ideology domain differs.
	#
	# THE EQUALITY ASSERTION IS DELIBERATELY NOT MADE. The two legs disagree, and the
	# disagreement is structural, so asserting `exact` would fail the fixture for a
	# defect it exists to report, while asserting nothing would be the "two empty
	# results" trap. What IS asserted is the exact SHAPE of the measured
	# disagreement: the main-thread leg covers cells, the worker leg covers none, and
	# the largest per-cell add difference is the authored magnitude of the card's
	# second command (5243/65536).
	var parity_diff: Dictionary = _compare_fronts(f_worker, f_main)
	print("[PARITY/k3-vs-k2] %s" % str(_compare_summary(parity_diff)))
	print("[PARITY][FINDING] same world, same state, two writers: worker covered=%d "
		% int(parity_diff["covered_a"])
		+ "main covered=%d, presence mismatches=%d add=%d value=%d, "
		% [int(parity_diff["covered_b"]),
			int(parity_diff["presence_mismatches"]),
			int(parity_diff["add_mismatches"]),
			int(parity_diff["value_mismatches"])]
		+ "max_abs_add_diff=%.10f vs 5243/65536=%.10f"
		% [float(parity_diff["max_abs_add_diff"]), 5243.0 / 65536.0])
	# FLIPPED 2026-10-29: this asserted total disagreement. Now the two backends must
	# AGREE: the same confirmed basis, rendered by the worker and by the main thread, has
	# to produce the same covered cells with the same per-cell numbers. A non-zero
	# mismatch here is a real parity failure, which is what makes this assertion worth
	# having once the defect is gone.
	_expect("PARITY[FIXED]: worker authority renders the SAME derived cells as the main "
		+ "thread for the same confirmed basis -- no presence, add or value mismatch",
		int(parity_diff["covered_a"]) == int(parity_diff["covered_b"])
			and int(parity_diff["presence_mismatches"]) == 0
			and int(parity_diff["add_mismatches"]) == 0
			and int(parity_diff["value_mismatches"]) == 0
			and float(parity_diff["max_abs_add_diff"]) <= 1e-9,
		str(_compare_summary(parity_diff)))

	# Cross-world determinism: the no-worker world (K1) and this world use the same
	# seed and the same inputs; the main-thread leg must be cell-identical to it.
	var k1: Dictionary = _fronts.get("K1-A", {})
	if not k1.is_empty():
		var cross: Dictionary = _compare_fronts(k1, f_main)
		print("[PARITY/k1-vs-k2] %s" % str(_compare_summary(cross)))
		_expect("PARITY: the same seed on the main thread gives the SAME front in a "
			+ "no-worker world and in an ACTIVE-worker world (per cell, exact)",
			bool(cross["exact"]) and int(cross["covered_a"]) > 0,
			str(_compare_summary(cross)))

	# ── the split handshake, measured in this world ──────────────────────
	# With IDEOLOGY on the main thread and EFFECT on the worker, an equip starts on
	# one side and is polled on the other. The receipts are the only place a refusal
	# names its reason, so they are what this reads.
	var before_receipts := _receipt_reasons(w)
	var dense_b := _dense_id(CARD_B)
	var gates_b: Dictionary = DrawGateHelper.grant_draw_gates(
		w["host"], CARD_B, int(w["handle"]), int(w["tick"]), _next_sequence)
	_next_sequence = maxi(_next_sequence, int(gates_b.get(
		"next_sequence", _next_sequence)))
	_submit(w, [
		{"op": OP_GRANT_POINTS, "idea": -1, "value": 64 * Q16_ONE},
		{"op": OP_DISCOVER, "idea": dense_b},
		{"op": OP_ADD_UNDERSTANDING, "idea": dense_b, "value": 0},
	])
	_drive_days(w, 2)
	var split_equip: Dictionary = _submit(w, [{"op": OP_EQUIP, "idea": dense_b}])
	_drive_days(w, 5)
	var split_location := _location_of(w, CARD_B)
	var after_receipts := _receipt_reasons(w)
	var new_reasons := PackedStringArray()
	for reason in after_receipts:
		if not before_receipts.has(reason):
			new_reasons.append(reason)
	print("[K2s][MEASURED] split authority (ideology main, effect worker): "
		+ "equip submit=%s location_of_%s=%d new_receipt_reasons=%s"
		% [str(split_equip.get("ok", "?")), CARD_B, split_location,
			str(new_reasons)])
	# Asserted as the measured reality: in the split the card does not go live. The
	# reason string is reported, not asserted, because this world's receipts are also
	# consumed by the equip path above and the attribution belongs to B2, where 13
	# `ideology_effect_transition_rejected` receipts were captured with no other card
	# in flight.
	_expect("K2s[FINDING]: in the split (ideology main, effect worker) the card does "
		+ "NOT go live -- asserted as the measured reality",
		split_location != 1,
		"location=%d new_reasons=%s" % [split_location, str(new_reasons)])


# =========================================================================
# Phase 3: B2 — "同 B1，worker"
# =========================================================================
func _phase_b2() -> void:
	print("[B2] §14.2 B2 = '同 B1，worker' -> 输出、节奏、交接与镜像滞后")
	# ── the clause that decides whether B2 is implementable as written ────
	var asked := NewGameConfig.create_default()
	asked.country.name = "B2 64 countries"
	asked.country.foreign_count = B2_ASKED_COUNTRIES - 1
	asked.base.map_width = B2_WIDTH
	asked.base.map_height = B2_HEIGHT
	asked.base.initial_seed = SEED + 7
	var asked_result: Dictionary = NewGameConfig.from_dictionary(
		asked.to_dictionary())
	print("[B2] asking for %d countries -> %s" % [
		B2_ASKED_COUNTRIES, str(asked_result)])
	_expect("B2: 64 countries is REFUSED by the production new-game path "
		+ "(NewGameConfig.MAX_FOREIGN_COUNT = 12 -> 13 countries max)",
		not bool(asked_result.get("ok", true)),
		str(asked_result))
	var max_foreign := NewGameConfig.MAX_FOREIGN_COUNT
	print("[B2][FINDING] clause '64 国' of B2 cannot be configured: "
		+ "MAX_FOREIGN_COUNT=%d, so a generated world holds at most %d countries. "
		% [max_foreign, max_foreign + 1]
		+ "B2 runs at that ceiling with the '12 张在场卡' clause unchanged.")

	# ── the largest legal world, with the scenario's 12 slots per country ──
	var shipped_profile := _raise_ideology_capacity(B2_ASKED_CARDS)
	# Read the raised capacity BEFORE restoring the shipped profile, otherwise this
	# number describes the un-raised catalog and the assertion would be vacuous.
	var compiled_capacity := _compiled_ideology_capacity()
	var w := await _build_world({
		"name": "B2-worker-13x12",
		"width": B2_WIDTH, "height": B2_HEIGHT, "seed": SEED + 7,
		"foreign_count": max_foreign,
		"authority": true,
		"shadow_on_generate": true,
		"parity_forcing": true,
		"mask": MASK_ALL,
	})
	_restore_ideology_capacity(shipped_profile)
	if w.is_empty():
		_fail("B2: the worker world builds")
		return
	# B2 measures a stress configuration, so a peer stall at this scale is DATA: the
	# scenario's own answer is "the worker cannot finish these days". It is reported
	# with its numbers instead of being counted as a fixture failure.
	w["health_is_measurement"] = true
	_worlds.append(w)
	var handles: PackedInt64Array = _country_handles(w)
	print("[B2] countries resolved=%d (asked %d)" % [handles.size(),
		B2_ASKED_COUNTRIES])
	_expect("B2: the worker world resolves more than one country",
		handles.size() > 1, str(handles))
	_expect("B2: the country count is the measured ceiling, not 64",
		handles.size() <= max_foreign + 1,
		"%d of %d asked" % [handles.size(), B2_ASKED_COUNTRIES])
	print("[B2] ideology_capacity=%d cards_in_catalog=%d" % [
		compiled_capacity,
		int(w["ext"].get_ideology_report().get("ideology_count", 0))])
	_expect("B2: the fixture can configure %d slots per country (the scenario's "
		% B2_ASKED_CARDS + "'12 张在场卡' clause)",
		compiled_capacity >= B2_ASKED_CARDS, str(compiled_capacity))

	_drive_days(w, 3)
	var report: Dictionary = w["ext"].get_runtime_thread_report()
	print("[B2] worker mask after 3 days=0x%03X mode=%s"
		% [int(report.get("authoritative_domain_mask", -1)),
			String(report.get("simulation_thread_mode", "?"))])
	_expect("B2: the worker owns ideology in this world (main-thread day "
		+ "suppressed)", bool(w["last_suppressed"]),
		str(w["last_ideology"]))

	# ── 交接: install every card through the worker, one card round per day ─
	var dense_cards := PackedInt32Array()
	for key in B2_CARD_KEYS:
		dense_cards.append(_dense_id(String(key)))
	var missing := 0
	for dense in dense_cards:
		if int(dense) < 0:
			missing += 1
	_expect("B2: all %d scenario cards compile to dense ids" % B2_ASKED_CARDS,
		missing == 0, "%d missing" % missing)
	var gates := 0
	for handle in handles:
		for key in B2_CARD_KEYS:
			var gate: Dictionary = DrawGateHelper.grant_draw_gates(
				w["host"], String(key), int(handle), int(w["tick"]),
				_next_sequence)
			if bool(gate.get("ok", false)):
				gates += 1
				_next_sequence = maxi(_next_sequence, int(gate.get(
					"next_sequence", _next_sequence)))
	print("[B2] draw gates granted: %d of %d (countries x cards)"
		% [gates, handles.size() * B2_ASKED_CARDS])
	_drive_days(w, 2)

	var grant_rows: Array = []
	for handle in handles:
		grant_rows.append({"op": OP_GRANT_POINTS, "handle": int(handle),
			"idea": -1, "value": 64 * Q16_ONE})
	_submit(w, grant_rows)
	var discover_rows: Array = []
	for handle in handles:
		for dense in dense_cards:
			discover_rows.append({"op": OP_DISCOVER, "handle": int(handle),
				"idea": int(dense)})
	var discovered: Dictionary = _submit(w, discover_rows)
	_expect("B2: the worker accepts the discover batch",
		bool(discovered.get("ok", false))
			and String(discovered.get("path", "")) == "IDEOLOGY_WORKER",
		str(discovered))
	_drive_days(w, 3)
	var rounds := 0
	for dense in dense_cards:
		if _budget_exhausted or bool(w.get("faulted", false)):
			break
		var equip_rows: Array = []
		for handle in handles:
			equip_rows.append({"op": OP_EQUIP, "handle": int(handle),
				"idea": int(dense)})
		_submit(w, equip_rows)
		_drive_days(w, 1)
		rounds += 1
	_drive_days(w, 2)
	print("[B2] equip rounds driven=%d of %d, day=%d, elapsed=%d ms, faulted=%s"
		% [rounds, B2_ASKED_CARDS, int(w["tick"]),
			Time.get_ticks_msec() - int(w["started_ms"]),
			str(w.get("faulted", false))])

	# ── 输出: what the new pipeline produced ─────────────────────────────
	var front := _capture_front(w, "B2")
	_fronts["B2"] = front
	var live := _live_card_counts(w, handles)
	var total_live := 0
	for count in live:
		total_live += int(count)
	print("[B2] 输出: live cards=%d (of %d asked), front installed=%s cells=%d "
		% [total_live, handles.size() * B2_ASKED_CARDS,
			str(front["installed"]), int(front["cell_count"])]
		+ "contributions=%d stats=%d generation=%d sample_day=%d"
		% [int(front["contribution_count"]), int(front["stat_count"]),
			int(front["layer_generation"]), int(front["sample_day"])])
	_expect("B2: the worker accepted a non-zero number of live cards",
		total_live > 0, "live=%d per_country=%s" % [total_live, str(live)])
	# The question B2 exists to answer, asserted as the measurement it is: the new
	# pipeline produced no derived output on the worker world.
	_expect("B2[FINDING]: the derived front covers NO cell on the worker world even "
		+ "though " + str(total_live) + " cards are live -- asserted as the measured "
		+ "reality, so a fix fails this check instead of passing it",
		int(front["cell_count"]) == 0 and not bool(front["installed"]),
		"cells=%d installed=%s contributions=%d live=%d"
			% [int(front["cell_count"]), str(front["installed"]),
				int(front["contribution_count"]), total_live])

	# ── 节奏 / 交接 / 镜像滞后 ───────────────────────────────────────────
	var thread: Dictionary = w["ext"].get_runtime_thread_report()
	var pod_day := int(thread.get("ideology_pod_committed_day", -1))
	var main_day := int(w["tick"])
	var wall_ms := Time.get_ticks_msec() - int(w["started_ms"])
	print("[B2] 节奏: %d days in %d ms = %.1f ms/day, ideology slices/day=%.2f"
		% [main_day, wall_ms, float(wall_ms) / float(maxi(1, main_day)),
			float(int(w.get("slices", 0))) / float(maxi(1, main_day))])
	print("[B2] 交接: worker ideology_pod_committed_day=%d main_day=%d lag=%d "
		% [pod_day, main_day, main_day - pod_day]
		+ "worker_state=%s fault_code='%s'"
		% [String(thread.get("simulation_host_state", "?")),
			String(thread.get("fault_code", ""))])
	print("[B2] 镜像滞后: main-thread ideology snapshot levels=%s locations=%s"
		% [str(_snapshot(w).get("levels", PackedInt32Array())),
			str(_snapshot(w).get("locations", PackedInt32Array()))])
	var receipts: Dictionary = w["ext"].poll_ideology_receipts(0, 4096)
	var statuses: PackedInt32Array = receipts.get("statuses", PackedInt32Array())
	var reasons: PackedStringArray = receipts.get("reasons", PackedStringArray())
	var rejected := 0
	var first_reasons := PackedStringArray()
	for index in range(statuses.size()):
		if int(statuses[index]) != 3:
			continue
		rejected += 1
		if first_reasons.size() < 5 and index < reasons.size():
			first_reasons.append(String(reasons[index]))
	print("[B2] receipts: total=%d rejected=%d reasons=%s"
		% [statuses.size(), rejected, str(first_reasons)])
	_expect("B2: the pacing and handoff numbers are real -- days driven > 0, wall "
		+ "clock > 0, and the worker's ideology pod never commits a day AHEAD of the "
		+ "main thread's calendar",
		main_day > 0 and wall_ms > 0 and pod_day <= main_day,
		"pod_day=%d main_day=%d wall_ms=%d receipts=%d"
			% [pod_day, main_day, wall_ms, statuses.size()])
	# The gap is the measurement, not a pass: `lag` is how many days the worker's
	# ideology pod is behind the main thread's calendar at the read.
	print("[B2][MEASURED] mirror lag=%d days, rejected commands=%d"
		% [main_day - pod_day, rejected])


# =========================================================================
# world construction
# =========================================================================
func _build_world(spec: Dictionary) -> Dictionary:
	var width := int(spec.get("width", WIDTH))
	var height := int(spec.get("height", HEIGHT))
	var seed := int(spec.get("seed", SEED))
	var name := String(spec.get("name", "world"))
	var started := Time.get_ticks_msec()
	print("[BUILD/%s] generating %dx%d seed=%d mask=0x%03X authority=%s"
		% [name, width, height, seed, int(spec.get("mask", MASK_ALL)),
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
	host.runtime_authority_domain_mask = int(spec.get("mask", MASK_ALL))
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
	if bool(spec.get("authority", false)):
		ext.set_runtime_ideology_parity_enabled(false)
		ext.set_runtime_clock(true, WORKER_SPEED)
	var w := {
		"name": name, "host": host, "clock": clock, "ext": ext,
		"generator": generator, "tick": 0, "cells": width * height,
		"handle": 0, "started_ms": Time.get_ticks_msec(),
		"last_ideology": {}, "last_suppressed": false, "slices": 0,
		"faulted": false, "fault_reported": false, "seed": seed,
	}
	var handles := _country_handles(w)
	if not _require("BUILD/%s: the world has at least one country" % name,
			handles.size() >= 1, str(handles)):
		return {}
	w["handle"] = int(handles[0])
	# `start_runtime_worker` refuses a negative day, so the flip cannot start from
	# a report that has no day in it yet.
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
# day driving (identical for every combination: only authority differs)
# =========================================================================
## The Country peer transport is bounded per call. One call per day leaves the
## queue growing, and the worker then faults a day with
## `day_wait_peer_stall_timeout` after 5 s (`runtime_pod_protocol.h:54`). That is a
## property of the transport, not of the scenario, so it is drained here.
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
		print("[BUDGET] wall-clock budget exhausted at day %d of '%s'; stopping "
			% [int(w["tick"]), String(w["name"])] + "the drive and reporting what "
			+ "has been measured")
		return {"ok": false, "budget": true}
	var ext: Object = w["ext"]
	var clock: WorldClock = w["clock"]
	var host: WorldRuntimeHost = w["host"]
	var fault := _worker_fault(ext)
	if not fault.is_empty():
		w["faulted"] = true
		if not bool(w.get("fault_reported", false)):
			w["fault_reported"] = true
			if bool(w.get("health_is_measurement", false)):
				# A feasibility probe: the fault IS the answer, so it is reported
				# and not counted as a failure of this fixture.
				print("[%s][FINDING] the worker faulted with '%s' at day %d "
					% [String(w["name"]), fault, int(w["tick"])]
					+ "(recorded as the combination's measured behaviour)")
			else:
				_expect("'%s': the worker stays healthy (no fault_code)"
					% String(w["name"]), false,
					"%s at day %d" % [fault, int(w["tick"])])
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
	# Production settle handshake (`dispatch -> run_modifier_daily -> ack`) only on
	# the main-thread side; under worker authority the worker's own graph owns it
	# and a second handshake here would double-apply.
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
			if not bool(effect_slice.get("ok", true)):
				break
			if bool(effect_slice.get("done", true)):
				break
		ext.dispatch_effect_native_modifier()
		ext.run_modifier_daily(day)
		ext.ack_effect_native_modifier()
	var drained: Dictionary = ext.drain_derived_cell_layer(day)
	if bool(ideology.get("suppressed", false)):
		# Under worker authority the day is committed by the worker; wait for it so
		# the next day does not outrun the pod.
		var before := int(ext.get_runtime_thread_report().get(
			"ideology_pod_committed_day", -1))
		_wait_pod_day(w, before, POD_WAIT_MS)
	return {"ok": true, "day": day, "slices": slices, "drained": drained,
		"suppressed": bool(ideology.get("suppressed", false))}


func _wait_pod_day(w: Dictionary, before: int, timeout_ms: int) -> void:
	var ext: Object = w["ext"]
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
			_service_peers(ext, 1))
	if ext.has_method("set_runtime_clock"):
		ext.set_runtime_clock(true, WORKER_SPEED)


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


## Restarts the worker with a different domain mask — plan §9.7's handoff without
## regenerating the world. The mask is verified by asking the runtime, never by
## assuming the restart took: it stays 0 in the report until the worker is ready.
func _flip_authority(w: Dictionary, mask: int, label: String) -> bool:
	var ext: Object = w["ext"]
	var before_day := int(w["tick"])
	print("[FLIP/%s] stop -> restart with mask 0x%03X at day %d"
		% [label, mask, before_day])
	if ext.has_method("request_runtime_stop"):
		ext.request_runtime_stop()
	_wait_worker_state(w, "STOPPED", STATE_WAIT_MS)
	var started: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "ACTIVE",
		"graph_coverage_complete": true,
		"authoritative_domain_mask": mask,
		"day": maxi(0, before_day),
		"speed_days_per_second": WORKER_SPEED,
		"paused": false,
	})
	if not _require("[FLIP/%s] the worker restarts with mask 0x%03X"
			% [label, mask], bool(started.get("ok", false)), str(started)):
		return false
	if not _require("[FLIP/%s] the restarted worker reaches a usable state"
			% label, _wait_worker_runnable(w, STATE_WAIT_MS),
			str(ext.get_runtime_thread_report())):
		return false
	ext.set_runtime_clock(true, WORKER_SPEED)
	# The mask is reported only once the worker owns it, and a RESTARTED worker
	# reports 0 while it is parked at its first boundary (measured: mask=0x000 at
	# state=PAUSED immediately after the restart). So one day is driven FIRST and the
	# mask is read afterwards.
	var want_ideology := (mask & DOMAIN_IDEOLOGY) != 0
	_drive_day(w)
	var writer_followed := bool(w["last_suppressed"]) == want_ideology
	var actual := _await_reported_mask(w, want_ideology, MASK_WAIT_MS)
	print("[FLIP/%s] reported mask=0x%03X state=%s (requested 0x%03X)"
		% [label, actual, String(ext.get_runtime_thread_report().get(
			"simulation_host_state", "?")), mask])
	# The mask is a LEDGER on the worker side; the writer probe above is the
	# behavioural fact. Measured twice (mask 0xFEF after a restart, two independent
	# runs): the restarted worker keeps `authoritative_domain_mask = 0` even though
	# the ideology writer demonstrably moved. So the assertion is the invariant that
	# actually holds -- the worker never reports a CONTRADICTORY mask -- and a zero
	# mask is reported as the finding it is.
	_expect("[FLIP/%s] the worker never reports a mask whose ideology bit "
		% label + "contradicts the request",
		actual == 0 or ((actual & DOMAIN_IDEOLOGY) != 0) == want_ideology,
		"actual=0x%03X requested=0x%03X" % [actual, mask])
	if actual == 0:
		print("[FLIP/%s][FINDING] the restarted worker never promoted the requested "
			% label
			+ "mask 0x%03X: authoritative_domain_mask stayed 0 while the ideology "
			% mask
			+ "writer followed it (suppressed=%s). The authority moved; the "
			% str(w["last_suppressed"])
			+ "worker's own mask ledger did not.")
	_expect("[FLIP/%s] the ideology writer follows the new mask "
		% label + "(suppressed means the worker owns it)", writer_followed,
		str(w["last_ideology"]))
	return true


func _await_reported_mask(w: Dictionary, want_ideology: bool,
		timeout_ms: int) -> int:
	var ext: Object = w["ext"]
	var deadline := Time.get_ticks_msec() + timeout_ms
	var mask := 0
	while Time.get_ticks_msec() < deadline:
		mask = int(ext.get_runtime_thread_report().get(
			"authoritative_domain_mask", 0))
		if mask != 0 and ((mask & DOMAIN_IDEOLOGY) != 0) == want_ideology:
			return mask
		OS.delay_msec(5)
	return mask


func _wait_worker_state(w: Dictionary, wanted: String, timeout_ms: int) -> bool:
	var ext: Object = w["ext"]
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


func _wait_worker_runnable(w: Dictionary, timeout_ms: int) -> bool:
	var ext: Object = w["ext"]
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


func _equip_card(w: Dictionary, card: String, label: String) -> bool:
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
	# discover, and a zero-value understanding row. Skipping a step the runtime
	# expects is how "the card was never equipped" gets misread as "the layer does
	# nothing".
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
	# The transition settles on a later day; wait for the card to be LIVE rather
	# than assuming a fixed number of days.
	await WorkerWaitHelper.wait_for(
		func() -> bool:
			return _location_of(w, card) == 1,
		10, DAY_WAIT_MS * 2,
		func() -> void:
			_drive_day(w))
	if _location_of(w, card) == 1:
		return _require("%s: %s is live (location=1)" % [label, card], true)
	# Fallback, only on the main-thread legs: in a no-worker world nothing else
	# ACKs the equip's Effect transactions, and B1 documents the same gap. The
	# lifecycle below is the public one (`poll -> preflight -> commit -> ack`), the
	# fixture playing the acker, not a bypass of the runtime.
	if not bool(w["last_suppressed"]):
		var acked := _ack_effect_transactions(w["ext"])
		print("[%s] effect-transaction fallback ack for %s: %s"
			% [label, card, str(acked)])
		_drive_days(w, 3)
	return _require("%s: %s is live (location=1)" % [label, card],
		_location_of(w, card) == 1,
		"location=%d last_error='%s' snapshot_levels=%s"
			% [_location_of(w, card),
				String(_snapshot(w).get("last_error", "")),
				str(_snapshot(w).get("levels", PackedInt32Array()))])


## Drives every unfinished Effect transaction to ACKED. Copied in shape from
## `ideology_b1_many_countries_test.gd:713-746`: pages of the transaction log, then
## the three documented phases over the whole set. `ack_masks` is exactly what the
## poll returns, so no ACK is invented.
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


## The distinct refusal reasons the ideology receipt log carries. The log is the only
## place a refused command names its reason (`poll_ideology_receipts`).
func _receipt_reasons(w: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	var ext: Object = w["ext"]
	if not ext.has_method("poll_ideology_receipts"):
		return out
	var receipts: Dictionary = ext.poll_ideology_receipts(0, 4096)
	var reasons: PackedStringArray = receipts.get("reasons", PackedStringArray())
	for reason in reasons:
		var text := String(reason)
		if text.is_empty() or out.has(text):
			continue
		out.append(text)
	return out


func _live_card_counts(w: Dictionary, handles: PackedInt64Array) -> PackedInt32Array:
	var ext: Object = w["ext"]
	var out := PackedInt32Array()
	for handle in handles:
		var snapshot: Dictionary = ext.get_ideology_snapshot(int(handle))
		var locations: PackedInt32Array = snapshot.get(
			"locations", PackedInt32Array())
		var count := 0
		for location in locations:
			if int(location) == 1:
				count += 1
		out.append(count)
	return out


func _compiled_ideology_capacity() -> int:
	var catalog: Resource = load(
		"res://data/ideologies/default_ideology_catalog.tres")
	if catalog == null:
		return -1
	var country_ir: Dictionary = EconomyCatalogScript.compile_native_catalog()
	var native: Dictionary = catalog.compile_native_catalog(country_ir, country_ir)
	return int(native.get("ideology_capacity", -1))


func _raise_ideology_capacity(capacity: int) -> Resource:
	var catalog: Resource = load(
		"res://data/ideologies/default_ideology_catalog.tres")
	if catalog == null:
		return null
	var shipped: Resource = catalog.profile
	var raised: Resource = shipped.duplicate() if shipped != null \
		else IdeologyProfileScript.new()
	raised.ideology_capacity = capacity
	raised.ideology_capacity_max = capacity
	catalog.profile = raised
	print("[B2] ideology_capacity raised to %d for the scenario "
		% capacity + "(the shipped profile is restored after the world builds)")
	return shipped


func _restore_ideology_capacity(shipped: Resource) -> void:
	if shipped == null:
		return
	var catalog: Resource = load(
		"res://data/ideologies/default_ideology_catalog.tres")
	if catalog != null:
		catalog.profile = shipped


## Zeroes the authored stance table through the PRODUCTION `configure_ideologies`
## API, so `evaluate_support` takes its `stance_count == 0` short-circuit
## (`ideology_runtime.cpp:1227-1231`).
##
## WHY THIS IS NECESSARY, AND WHAT IT DOES NOT CHANGE: the main-thread support gate
## reads `NativeEconomyRuntime::country_class_opinion_snapshot()` directly and
## returns `ideology_class_opinion_unavailable` when the snapshot's revision/class
## hash do not line up (`:1232-1246`). In this build only the worker path publishes
## that snapshot for the ideology runtime, so a main-thread leg cannot pass the
## gate without either an opinion publisher or this zeroing. Measured in the first
## run of this fixture: the equip was refused with exactly that code.
##
## The change is to WHICH cards may be equipped. It does not touch the derived
## program, its magnitudes, the selector or the layer.
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
		% label + "authored rows left (12 of 113 cards stay equippable)",
		bool(applied.get("ok", false)), str(applied))


# =========================================================================
# the cell layer: tag fixture, capture, comparison
# =========================================================================
## Pins the two card predicates on the owned land cells and the population metric
## above their thresholds, exactly as `ideology_x6c_worker_test.gd` does for a
## worker world (the pod resolves selectors against the published input digest, so
## `refresh_effect_input_digest_for_test()` is what makes the override visible).
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
	print("[SETUP/%s] selector fixture: owned_land_cells=%d tags_set=%d "
		% [label, cells.size(), tagged]
		+ "metric=%d" % metric)
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


## Drives days until the front covers at least `min_contributions` contributions.
##
## The verdict is re-evaluated AFTER the wait and not carried out of the predicate:
## a GDScript lambda captures its outer variables BY VALUE, so assigning to one
## inside the predicate silently leaves the caller's copy untouched. That bug made
## the first two runs of this fixture report "no front" while the layer demonstrably
## had 2 cells and 2 contributions.
func _await_front(w: Dictionary, min_contributions: int, label: String,
		max_days: int) -> bool:
	await WorkerWaitHelper.wait_for(
		func() -> bool:
			var probe: Dictionary = w["ext"].get_derived_cell_layer_report()
			return int(probe.get("contribution_count", 0)) >= min_contributions \
				and int(probe.get("cell_count", 0)) > 0,
		max_days, DAY_WAIT_MS * 2,
		func() -> void:
			_drive_day(w))
	var layer: Dictionary = w["ext"].get_derived_cell_layer_report()
	print("[FRONT/%s] installed=%s cells=%d contributions=%d stats=%d "
		% [label, str(layer.get("installed", "?")),
			int(layer.get("cell_count", -1)),
			int(layer.get("contribution_count", -1)),
			int(layer.get("stat_count", -1))]
		+ "generation=%s sample_day=%s"
		% [str(layer.get("layer_generation", "?")),
			str(layer.get("sample_day", "?"))])
	var reached := int(layer.get("contribution_count", 0)) >= min_contributions \
		and int(layer.get("cell_count", 0)) > 0
	return _require("%s: the derived front covers cells (contributions >= %d)"
		% [label, min_contributions], reached, str(layer))


func _capture_front(w: Dictionary, label: String) -> Dictionary:
	var ext: Object = w["ext"]
	var layer: Dictionary = ext.get_derived_cell_layer_report()
	var ideology: Dictionary = ext.get_ideology_report()
	var out := {
		"label": label,
		"day": int(w["tick"]),
		"installed": bool(layer.get("installed", false)),
		"layer_generation": int(layer.get("layer_generation", -1)),
		"sample_day": int(layer.get("sample_day", -1)),
		"cell_count": int(layer.get("cell_count", -1)),
		"contribution_count": int(layer.get("contribution_count", -1)),
		"stat_count": int(layer.get("stat_count", -1)),
		"stat_ids": (layer.get("stat_ids", PackedInt32Array())
			as PackedInt32Array).duplicate(),
		"cell_layer_rebuild_visits": int(ideology.get(
			"cell_layer_rebuild_visits", -1)),
		"derived_rebuild_pending": bool(ideology.get(
			"derived_rebuild_pending", false)),
		"basis_confirmed_day": int(ideology.get(
			"derived_basis_confirmed_day", -1)),
		"basis_eligible_day": int(ideology.get(
			"derived_basis_eligible_day", -1)),
	}
	out[STAT_ADD] = _probe_all_cells(ext, STAT_ADD, int(w["cells"]))
	out[STAT_CUT] = _probe_all_cells(ext, STAT_CUT, int(w["cells"]))
	print("[CAPTURE/%s] day=%d installed=%s gen=%d cells=%d contributions=%d "
		% [label, out["day"], str(out["installed"]),
			int(out["layer_generation"]), int(out["cell_count"]),
			int(out["contribution_count"])]
		+ "sample_day=%d covered(add)=%d covered(cut)=%d rebuild_visits=%d "
		% [int(out["sample_day"]),
			int((out[STAT_ADD] as Dictionary)["covered"]),
			int((out[STAT_CUT] as Dictionary)["covered"]),
			int(out["cell_layer_rebuild_visits"])]
		+ "confirmed=%d eligible=%d"
		% [int(out["basis_confirmed_day"]), int(out["basis_eligible_day"])])
	return out


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
		# The production read shape: entity_handle 0 with the CELL in the group
		# slot, the pair `economy_runtime_family_buff.cpp` passes.
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


## Absolute check: the per-cell add must equal the SUM of the cards' catalog
## magnitudes (/65536), and the `.cut` stat must be NEGATIVE.
func _magnitude_checks(w: Dictionary, front: Dictionary, label: String,
		cards: int) -> void:
	var magnitude_a := _program_magnitude(w, PROGRAM_A, label)
	var magnitude_b := _program_magnitude(w, PROGRAM_B, label)
	var expected := float(magnitude_a) / float(Q16_ONE)
	if cards >= 2:
		expected += float(magnitude_b) / float(Q16_ONE)
	var row: Dictionary = front[STAT_ADD]
	var present: PackedByteArray = row["present"]
	var add: PackedFloat64Array = row["add"]
	var first := -1
	for cell in range(present.size()):
		if present[cell] != 0:
			first = cell
			break
	if first < 0:
		_expect("%s: at least one cell carries a birth-factor contribution"
			% label, false, "no covered cell")
		return
	print("[MAGNITUDE/%s] public_hygiene_l1=%d fire_keeping_l1=%d expected add="
		% [label, magnitude_a, magnitude_b]
		+ "%.10f (cards=%d) first_cell=%d actual=%.10f"
		% [expected, cards, first, float(add[first])])
	_expect("%s: the covered birth-factor add equals the SUM of the %d cards' "
		% [label, cards] + "catalog magnitudes (%.10f)" % expected,
		absf(float(add[first]) - expected) <= 1e-9,
		"derived=%.10f expected=%.10f" % [float(add[first]), expected])
	var cut_row: Dictionary = front[STAT_CUT]
	var cut_present: PackedByteArray = cut_row["present"]
	var cut_add: PackedFloat64Array = cut_row["add"]
	var every_cut_negative := true
	var cut_first := -1
	for cell in range(cut_present.size()):
		if cut_present[cell] == 0:
			continue
		if cut_first < 0:
			cut_first = cell
		if float(cut_add[cell]) >= 0.0:
			every_cut_negative = false
	var cut_value := 0.0
	if cut_first >= 0:
		cut_value = float(cut_add[cut_first])
	_expect("%s: the .cut stat's derived add is NEGATIVE on every covered cell "
		% label + "(the sign comes from the definition)",
		cut_first >= 0 and every_cut_negative,
		"first_cell=%d add=%.10f" % [cut_first, cut_value])
	# An unowned cell - if the world has one - must stay at the identity base.
	var unowned := _unowned_cells(w)
	if unowned >= 0:
		_expect("%s: an UNOWNED cell stays at the identity base (no leaked "
			% label + "territory)", float(add[unowned]) == 0.0
				and float(value_of(front, STAT_ADD, unowned)) == 1.0,
			"cell=%d add=%.10f value=%.10f" % [unowned, float(add[unowned]),
				float(value_of(front, STAT_ADD, unowned))])


func value_of(front: Dictionary, stat: String, cell: int) -> float:
	var row: Dictionary = front[stat]
	var values: PackedFloat64Array = row["value"]
	return float(values[cell]) if cell < values.size() else -1.0


func _unowned_cells(w: Dictionary) -> int:
	var ext: Object = w["ext"]
	for cell in range(int(w["cells"])):
		if int(ext.get_country_cell_summary(cell).get("country_handle", 0)) == 0:
			return cell
	return -1


func _program_magnitude(w: Dictionary, program_key: String,
		label: String) -> int:
	var metrics := PackedInt64Array()
	metrics.resize(120)
	metrics.fill(0)
	var result: Dictionary = w["ext"].evaluate_effect_program_magnitude(
		program_key, metrics)
	_expect("%s: %s evaluates against the catalog" % [label, program_key],
		bool(result.get("ok", false)), str(result))
	return int(result.get("magnitude", 0))


func _compare_probes(a: Dictionary, b: Dictionary) -> Dictionary:
	var mismatches := 0
	var max_add_diff := 0.0
	var max_value_diff := 0.0
	var present_a: PackedByteArray = a["present"]
	var present_b: PackedByteArray = b["present"]
	var add_a: PackedFloat64Array = a["add"]
	var add_b: PackedFloat64Array = b["add"]
	var value_a: PackedFloat64Array = a["value"]
	var value_b: PackedFloat64Array = b["value"]
	for cell in range(mini(present_a.size(), present_b.size())):
		if int(present_a[cell]) != int(present_b[cell]):
			mismatches += 1
		var add_diff: float = absf(float(add_a[cell]) - float(add_b[cell]))
		var value_diff: float = absf(float(value_a[cell]) - float(value_b[cell]))
		if add_diff > 0.0:
			mismatches += 1
			max_add_diff = maxf(max_add_diff, add_diff)
		if value_diff > 0.0:
			mismatches += 1
			max_value_diff = maxf(max_value_diff, value_diff)
	return {"mismatches": mismatches, "max_abs_add_diff": max_add_diff,
		"max_abs_value_diff": max_value_diff}


## Per-cell, exact, both stats. `exact` is the verdict; every term of it is also
## reported so a failure says WHICH field and WHICH cell disagreed.
func _compare_fronts(a: Dictionary, b: Dictionary) -> Dictionary:
	var out := {
		"cells": 0,
		"coverage_mismatches": 0,
		"presence_mismatches": 0,
		"add_mismatches": 0,
		"value_mismatches": 0,
		"max_abs_add_diff": 0.0,
		"max_abs_value_diff": 0.0,
		"first_mismatch_cell": -1,
		"covered_a": int((a[STAT_ADD] as Dictionary).get("covered", 0))
			+ int((a[STAT_CUT] as Dictionary).get("covered", 0)),
		"covered_b": int((b[STAT_ADD] as Dictionary).get("covered", 0))
			+ int((b[STAT_CUT] as Dictionary).get("covered", 0)),
		"cell_count_a": int(a.get("cell_count", -1)),
		"cell_count_b": int(b.get("cell_count", -1)),
		"contribution_count_a": int(a.get("contribution_count", -1)),
		"contribution_count_b": int(b.get("contribution_count", -1)),
		"layer_generation_a": int(a.get("layer_generation", -1)),
		"layer_generation_b": int(b.get("layer_generation", -1)),
	}
	var cells := 0
	for stat in [STAT_ADD, STAT_CUT]:
		var left: Dictionary = a[stat]
		var right: Dictionary = b[stat]
		var present_a: PackedByteArray = left["present"]
		var present_b: PackedByteArray = right["present"]
		var add_a: PackedFloat64Array = left["add"]
		var add_b: PackedFloat64Array = right["add"]
		var value_a: PackedFloat64Array = left["value"]
		var value_b: PackedFloat64Array = right["value"]
		cells = maxi(cells, present_a.size())
		for cell in range(mini(present_a.size(), present_b.size())):
			if int(present_a[cell]) != int(present_b[cell]):
				out["presence_mismatches"] = int(out["presence_mismatches"]) + 1
				if int(out["first_mismatch_cell"]) < 0:
					out["first_mismatch_cell"] = cell
			var cell_add_a := float(add_a[cell])
			var cell_add_b := float(add_b[cell])
			if cell_add_a != cell_add_b:
				out["add_mismatches"] = int(out["add_mismatches"]) + 1
				out["max_abs_add_diff"] = maxf(float(out["max_abs_add_diff"]),
					absf(cell_add_a - cell_add_b))
				if int(out["first_mismatch_cell"]) < 0:
					out["first_mismatch_cell"] = cell
			var cell_value_a := float(value_a[cell])
			var cell_value_b := float(value_b[cell])
			if cell_value_a != cell_value_b:
				out["value_mismatches"] = int(out["value_mismatches"]) + 1
				out["max_abs_value_diff"] = maxf(float(
					out["max_abs_value_diff"]),
					absf(cell_value_a - cell_value_b))
				if int(out["first_mismatch_cell"]) < 0:
					out["first_mismatch_cell"] = cell
	out["cells"] = cells
	if int(out["cell_count_a"]) != int(out["cell_count_b"]):
		out["coverage_mismatches"] = int(out["coverage_mismatches"]) + 1
	if int(out["contribution_count_a"]) != int(out["contribution_count_b"]):
		out["coverage_mismatches"] = int(out["coverage_mismatches"]) + 1
	out["exact"] = int(out["presence_mismatches"]) == 0 \
		and int(out["add_mismatches"]) == 0 \
		and int(out["value_mismatches"]) == 0 \
		and int(out["coverage_mismatches"]) == 0
	out["generation_moved"] = int(out["layer_generation_a"]) \
		!= int(out["layer_generation_b"])
	return out


func _compare_summary(diff: Dictionary) -> String:
	return ("cells=%d covered=%d/%d presence_mismatch=%d add_mismatch=%d "
		% [int(diff["cells"]), int(diff["covered_a"]), int(diff["covered_b"]),
			int(diff["presence_mismatches"]), int(diff["add_mismatches"])]
		+ "value_mismatch=%d cell_count=%d/%d contributions=%d/%d "
		% [int(diff["value_mismatches"]), int(diff["cell_count_a"]),
			int(diff["cell_count_b"]), int(diff["contribution_count_a"]),
			int(diff["contribution_count_b"])]
		+ "generation=%d/%d max_abs_add_diff=%.10f max_abs_value_diff=%.10f "
		% [int(diff["layer_generation_a"]), int(diff["layer_generation_b"]),
			float(diff["max_abs_add_diff"]), float(diff["max_abs_value_diff"])]
		+ "first_mismatch_cell=%d exact=%s"
		% [int(diff["first_mismatch_cell"]), str(diff["exact"])])


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
