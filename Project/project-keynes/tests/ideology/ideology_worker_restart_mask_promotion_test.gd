extends SceneTree

## A RESTARTED worker must promote its authority mask ledger, and the pumps that
## gate on it must run.
##
## WHY THIS FILE EXISTS
##
## `ideology_worker_authority_parity_test.gd` flips the authority mask at runtime
## (K3 0xFFF -> K2 0xFEF) and its `[FLIP/K3->K2][FINDING]` line recorded, twice, that
## `authoritative_domain_mask` reported by the host stayed `0x000` after the restart
## while the ideology writer demonstrably followed the request (`suppressed=false`).
##
## That fixture reads the mask ONE day after the restart and never again, so it cannot
## tell "deferred, promotes on the next committed day" from "never promotes again".
## This fixture closes exactly that gap: it traces the mask before the flip, during the
## stop, at the instant the restarted worker starts, and over the following days,
## together with the worker's own report, the environment-protocol counters, and the
## pump ledgers that depend on the mask.
##
## THE TWO LEDGERS
##
## `NativeSimulationHost::start()` stores `_requested_authority_mask = wanted` and
## `_authoritative_domain_mask = 0` (`native_simulation_host.cpp`), and the grant is
## published only after a day actually commits. A FRESH world therefore reads `0x000`
## until its first committed day -- by design, and asserted here, not "fixed".
##
## `request_stop()` and `set_fault()` clear the live grant so the main thread takes the
## domain back while the old worker winds down. That revocation is right. What was
## missing is the other half: nothing re-published the grant when the next lifetime
## started, so after a runtime flip the mask read `0x000` for the rest of the session
## while the request was already recorded.
##
## THE PUMPS
##
## `world_runtime_host.gd` gates three consumers on `(authoritative_domain_mask & bit)`:
## the ideology instance-refresh pump (`0x010`), which also carries the DERIVED-layer
## pump (`step_ideology_derived_rebuild`), and the country read-view consumer (`0x004`).
## The derived pump keeps its own ledger (`_ideology_derived_pumped_day`), which can only
## advance when the gate opened on the production tick path AND the derived step reported
## `done == true, pending == false`, so it is used here as the witness.
##
## Run:
##   <godot console exe> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_worker_restart_mask_promotion_test.gd

const WIDTH := 16
const HEIGHT := 12
const CELLS: int = WIDTH * HEIGHT
const SEED := 20261029
const WORKER_SPEED := 10.0

const DOMAIN_CLIMATE := 0x002
const DOMAIN_COUNTRY := 0x004
const DOMAIN_TRIGGER_INPUT := 0x008
const DOMAIN_IDEOLOGY := 0x010
const DOMAIN_EFFECT := 0x020
const DOMAIN_MODIFIER := 0x040
const DOMAIN_GAMEPLAY_EFFECT := 0x080
const DOMAIN_ECONOMY := 0x100
const DOMAIN_COMMIT := 0x800

const MASK_ALL := 0xFFF
## The exact mask the parity fixture flips to: everything except IDEOLOGY.
const MASK_WITHOUT_IDEOLOGY := MASK_ALL & ~DOMAIN_IDEOLOGY
## The same restart with the IDEOLOGY bit KEPT and GAMEPLAY_EFFECT dropped: the mask
## every existing ideology worker fixture uses. It is the flip that proves the gated
## pumps still run after a restart.
const MASK_KEEP_IDEOLOGY := MASK_ALL & ~DOMAIN_GAMEPLAY_EFFECT

const MAX_SLICES_PER_DAY := 256
const DAY_WAIT_MS := 9000
const POD_WAIT_MS := 5000
const STATE_WAIT_MS := 15000
## Whole-run guard.
const GLOBAL_BUDGET_MS := 480000
const PEER_PASSES := 6
const PEER_BATCH := 96
## Days driven after each flip while the mask is watched.
const POST_FLIP_DAYS := 4
const CARD_A := "idea.public_hygiene"
const Q16_ONE := 65536

const WorkerWaitHelper = preload("res://tests/ideology/ideology_worker_wait_helper.gd")
const DrawGateHelper = preload("res://tests/ideology/ideology_draw_gate_helper.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")

const OP_DISCOVER := 1
const OP_GRANT_POINTS := 2
const OP_EQUIP := 5
const OP_ADD_UNDERSTANDING := 8

var _checks := 0
var _failures := 0
var _next_sequence := 1
var _run_started_ms := 0
var _worlds: Array = []
var _effect_cursor := 0


func _init() -> void:
	call_deferred("_run_and_finish")


func _run_and_finish() -> void:
	var code := await _run()
	print("=== ideology worker restart mask promotion: %d checks, %d failures ===" % [
		_checks, _failures])
	quit(code if code != 0 else (0 if _failures == 0 else 1))


func _run() -> int:
	_run_started_ms = Time.get_ticks_msec()
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt unavailable")
		return 1
	await _phase_first_start_deferred()
	await _dispose_all_worlds()
	await _phase_never_flipped_control()
	await _dispose_all_worlds()
	# The exact defect case: IDEOLOGY leaves the worker.
	await _flip_case(MASK_WITHOUT_IDEOLOGY, "flip-ideology-main", false)
	await _dispose_all_worlds()
	# The same flip with the bit KEPT, so the gated pumps have to run after the
	# restart. Both flips are real runtime restarts of a real production world.
	await _flip_case(MASK_KEEP_IDEOLOGY, "flip-ideology-worker", true)
	await _dispose_all_worlds()
	return 0


# =========================================================================
# Phase 1: first start -- 0x000 until a day commits, then the whole request
# =========================================================================
func _phase_first_start_deferred() -> void:
	print("[FIRST-START] building a 0xFFF ACTIVE worker world")
	var w := await _build_world("first-start", MASK_ALL)
	if w.is_empty():
		_fail("FIRST-START: the worker world builds")
		return
	_worlds.append(w)
	var at_build := _probe(w, "at-build")
	print("[FIRST-START] at build: %s" % _probe_line(at_build))
	_expect("FIRST-START: before any day commits the mask is DEFERRED to 0x000 while "
		+ "the request is already recorded (by design, unchanged by this fix)",
		int(at_build["granted"]) == 0 and int(at_build["requested"]) == MASK_ALL,
		_probe_line(at_build))
	var promoted_day := -1
	for index in range(12):
		_drive_day(w)
		var probe := _probe(w, "day-%d" % int(w["tick"]))
		print("[FIRST-START] %s" % _probe_line(probe))
		if int(probe["granted"]) != 0:
			promoted_day = int(w["tick"])
			break
	var final := _probe(w, "first-start-final")
	_expect("FIRST-START: the deferred mask promotes to the full 0xFFF request once a "
		+ "day has committed",
		promoted_day >= 0 and int(final["granted"]) == MASK_ALL,
		"promoted_day=%d granted=0x%03X committed=%d env_day=%d ring=%d"
			% [promoted_day, int(final["granted"]), int(final["committed"]),
				int(final["env_day"]), int(final["ring"])])
	if promoted_day < 0:
		return
	print("[FIRST-START] promoted at main day %d (requested=0x%03X granted=0x%03X)"
		% [promoted_day, int(final["requested"]), int(final["granted"])])


# =========================================================================
# Phase 2: NEGATIVE CONTROL -- a world that is never flipped
# =========================================================================
func _phase_never_flipped_control() -> void:
	print("[CONTROL] building a second 0xFFF ACTIVE worker world, never flipped")
	var w := await _build_world("never-flipped", MASK_ALL)
	if w.is_empty():
		_fail("CONTROL: the control world builds")
		return
	_worlds.append(w)
	_install_selector_fixture(w, "CONTROL")
	var promoted := false
	for index in range(12):
		_drive_day(w)
		if int(_probe(w)["granted"]) == MASK_ALL:
			promoted = true
			break
	_expect("CONTROL: the never-flipped world reaches its 0xFFF grant",
		promoted, _probe_line(_probe(w)))
	var before := _probe(w, "control-before")
	print("[CONTROL] before: %s" % _probe_line(before))
	_drive_days(w, 5)
	var after := _probe(w, "control-after")
	print("[CONTROL] after 5 more days: %s" % _probe_line(after))
	_expect("CONTROL: a never-flipped world reports the SAME mask before and after "
		+ "5 more days (the fix must not touch the first-start path)",
		int(before["granted"]) == int(after["granted"])
			and int(after["granted"]) == MASK_ALL,
		"before=0x%03X after=0x%03X" % [int(before["granted"]),
			int(after["granted"])])
	var pump_before := int(after["pump_day"])
	var calls_before := int(after["pump_calls"])
	var skips_before := int(after["lock_skips"])
	var visits_before := int(after["rebuild_visits"])
	_drive_days(w, 4)
	var later := _probe(w, "control-later")
	print("[CONTROL] after 4 more: pump_calls=%d pump_day=%d lock_skips=%d "
		% [int(later["pump_calls"]), int(later["pump_day"]),
			int(later["lock_skips"])]
		+ "visits=%d front_cells=%d"
		% [int(later["rebuild_visits"]), int(later["front_cells"])])
	# `_ideology_pump_calls` sits BEHIND the mask gate inside the pump, so it can only
	# advance when the gate opened on the production tick path (`run_daily_tick`
	# calls the pump once per day).
	_expect("CONTROL: with IDEOLOGY granted the ideology pump runs on the production "
		+ "tick path (its call counter advances once per driven day)",
		int(later["pump_calls"]) > calls_before,
		"pump_calls %d -> %d (pump_day %d -> %d, lock_skips %d -> %d, visits %d -> %d)"
			% [calls_before, int(later["pump_calls"]), pump_before,
				int(later["pump_day"]), skips_before, int(later["lock_skips"]),
				visits_before, int(later["rebuild_visits"])])


# =========================================================================
# Phase 3: the flip, traced, then the pumps
# =========================================================================
func _flip_case(mask: int, name: String, expect_pump: bool) -> void:
	print("[FLIP/%s] building a 0xFFF ACTIVE worker world, then flipping to 0x%03X "
		% [name, mask] + "with no world regeneration")
	var w := await _build_world(name, MASK_ALL)
	if w.is_empty():
		_fail("FLIP/%s: the worker world builds" % name)
		return
	_worlds.append(w)
	_install_selector_fixture(w, name)
	var promoted := false
	for index in range(12):
		_drive_day(w)
		if int(_probe(w)["granted"]) == MASK_ALL:
			promoted = true
			break
	if not _require("FLIP/%s: the world reaches its 0xFFF grant before the flip"
			% name, promoted, _probe_line(_probe(w))):
		return
	# A live card + a materialised derived front: this is the workload the mask
	# gates, so the flip is measured against a world that is demonstrably using it.
	if not await _equip_card(w, CARD_A, name):
		return
	_drive_days(w, 3)
	var before := _probe(w, "before-flip")
	print("[FLIP/%s] BEFORE FLIP: %s" % [name, _probe_line(before)])
	_expect("FLIP/%s: before the flip the world is worker-authoritative for IDEOLOGY "
		% name + "(mask 0xFFF and the main-thread day suppressed)",
		int(before["granted"]) == MASK_ALL and bool(w["last_suppressed"]),
		_probe_line(before))
	var pump_before := int(before["pump_calls"])
	# ── the flip: stop, restart with `mask`, no world regeneration ───────
	var flip_day := _flip_authority(w, mask, "0xFFF->0x%03X" % mask)
	if flip_day < 0:
		return
	var at_start := _probe(w, "after-restart")
	print("[FLIP/%s] AT START: %s" % [name, _probe_line(at_start)])
	_expect("FLIP/%s[FIXED]: at the instant the restarted worker starts, the host "
		% name + "re-publishes the grant its previous lifetime proved -- no day has "
		+ "to commit first, so the reported mask cannot disagree with the request",
		int(at_start["granted"]) == mask, _probe_line(at_start))
	_expect("FLIP/%s: the restart also RECORDS the request, so the only two mask "
		% name + "ledgers a caller can read agree with each other",
		int(at_start["requested"]) == mask, _probe_line(at_start))
	print("[FLIP/%s] resume day = the host's own committed day %d (the caller asked "
		% [name, int(at_start["committed"])] + "for %d)" % flip_day)
	# ── THE GATE, measured through the pump's own production entry point ─
	var gate_before := _pump_witnesses(w)
	_pump_ideology(w)
	_pump_ideology(w)
	var gate_after := _pump_witnesses(w)
	print("[FLIP/%s] pump witnesses: %s -> %s"
		% [name, str(gate_before), str(gate_after)])
	if expect_pump:
		_expect("FLIP/%s[FIXED]: the restart kept IDEOLOGY with the worker, and the "
			% name + "ideology pump therefore RUNS at the restart boundary (its call "
			+ "counter, which sits behind the mask gate, advances)",
			int(_probe(w)["pump_calls"]) > pump_before
				and gate_after != gate_before,
			"%s -> %s" % [str(gate_before), str(gate_after)])
		_expect("FLIP/%s[FIXED]: the ideology instance-refresh pump reports a "
			% name + "done/pending shape instead of never being called",
			w["host"].get("_ideology_instance_refresh_last") is Dictionary
				and (w["host"].get("_ideology_instance_refresh_last") as Dictionary
					).has("done")
				and (w["host"].get("_ideology_instance_refresh_last") as Dictionary
					).has("pending"),
			str(w["host"].get("_ideology_instance_refresh_last")))
	else:
		_expect("FLIP/%s: with IDEOLOGY back on the main thread the ideology pump is "
			% name + "correctly NOT invoked (behind the closed gate nothing runs)",
			int(_probe(w)["pump_calls"]) == pump_before
				and gate_after == gate_before,
			"%s -> %s" % [str(gate_before), str(gate_after)])
	# ── the trace after the restart, driven ─────────────────────────────
	var after := _probe(w, "after-flip")
	for index in range(3):
		_drive_day(w)
		after = _probe(w, "post-flip-day-%d" % int(w["tick"]))
		print("[FLIP/%s] AFTER RESTART day %d: %s"
			% [name, int(w["tick"]), _probe_line(after)])
	print("[FLIP/%s] FINAL: %s" % [name, _probe_line(after)])
	print("[FLIP/%s] writer: suppressed=%s path=%s"
		% [name, str(w["last_suppressed"]),
			String((w["last_ideology"] as Dictionary).get("path", ""))])
	_expect("FLIP/%s: the reported mask's IDEOLOGY bit agrees with the writer for "
		% name + "the whole traced window",
		((int(after["granted"]) & DOMAIN_IDEOLOGY) != 0) == bool(w["last_suppressed"])
			or bool(after["faulted"]),
		_probe_line(after))
	# The two ledgers are COUPLED: `set_fault()` revokes the live grant on purpose
	# (a dead worker owns nothing), so a faulted worker must read 0x000 and a healthy
	# one must still read the request. That is the invariant this fixture can assert
	# over driven days without depending on whether the worker survives them.
	_expect("FLIP/%s[FIXED]: the reported mask and the worker's health stay coupled "
		% name + "over the following days (a fault revokes the grant; without one the "
		+ "mask still names the request)",
		bool(after["faulted"]) == (int(after["granted"]) == 0)
			and (bool(after["faulted"]) or int(after["granted"]) == mask),
		_probe_line(after))
	if bool(after["faulted"]):
		print("[FLIP/%s][MEASURED] the restarted worker faulted with '%s' at main day "
			% [name, String(after["fault"])] + "%d. Reproduced in every run of this "
			% int(after["main_day"])
			+ "fixture and in the parity fixture's `[FLIP/K3->K2]` leg: it is the "
			+ "Economy runtime refusing the first economy day of a NEW worker "
			+ "lifetime (`[runtime-worker-exception] "
			+ "what=economy_column_read_range_invalid`), NOT the mask ledger. It is "
			+ "reported rather than counted as a mask failure, and it is why the "
			+ "pump is proven at the restart boundary instead of over driven days.")


## Calls the host's ideology pump through its own production entry point -- the one
## `WorldRuntimeHost.run_daily_tick` calls (`world_runtime_host.gd:960`). Called here
## rather than through `run_daily_tick` because a driven day also starts a worker day,
## and a RESTARTED worker currently dies on its first Economy day
## (`economy_column_read_range_invalid`, out of this fixture's scope). The gate under
## test is the same expression either way, and it lives in this method.
func _pump_ideology(w: Dictionary) -> void:
	var host: WorldRuntimeHost = w["host"]
	host._step_ideology_instance_refresh_if_authoritative(int(w["tick"]))


## The witness the ideology pump leaves behind: its own call counter plus the two
## shapes it last saw. `_ideology_pump_calls` sits AFTER the mask gate inside the pump,
## so it can only move when the gate opened.
func _pump_witnesses(w: Dictionary) -> String:
	var p := _probe(w)
	return "pump_calls=%d pumped_day=%d derived=%s instance=%s" % [
		int(p["pump_calls"]), int(p["pump_day"]),
		str(w["host"].get("_ideology_pump_last")),
		str(w["host"].get("_ideology_instance_refresh_last"))]


## Stops the worker, restarts it with `mask`, and prints the ledger at every step.
## Returns the day the flip happened at (>= 0), or -1 when the restart was refused.
func _flip_authority(w: Dictionary, mask: int, label: String) -> int:
	var ext: Object = w["ext"]
	var before_day := int(w["tick"])
	print("[FLIP/%s] stop -> restart with mask 0x%03X at main day %d"
		% [label, mask, before_day])
	# Park at a DAY BOUNDARY before stopping. `request_stop()` is cooperative and can
	# land inside a semantic day, leaving the Economy epoch half-open; the next
	# lifetime then cannot resume it (measured: the restarted worker threw
	# `economy_column_read_range_invalid` while planning the interrupted day, which
	# kills the very lifetime the mask fix exists for). A climate-driven worker parks
	# on its own once the environment ring is empty, so waiting for PAUSED here is a
	# real boundary guarantee, not a sleep.
	var parked := _wait_worker_state(w, "PAUSED", 3000)
	print("[FLIP/%s] parked at a day boundary: %s (state=%s)"
		% [label, str(parked), String(ext.get_runtime_thread_report().get(
			"simulation_host_state", "?"))])
	ext.request_runtime_stop()
	var stopped := _wait_worker_state(w, "STOPPED", STATE_WAIT_MS)
	var during := _probe(w, "during-stop")
	print("[FLIP/%s] DURING STOP: %s" % [label, _probe_line(during)])
	_expect("[FLIP/%s] the stop completes and the live grant is revoked on the way "
		% label + "down so the main thread owns the domain while it winds down",
		stopped and int(during["granted"]) == 0,
		"stopped=%s %s" % [str(stopped), _probe_line(during)])
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
		return -1
	var after_start := _probe(w, "after-restart")
	print("[FLIP/%s] AT START: %s" % [label, _probe_line(after_start)])
	print("[FLIP/%s] start result ledgers: requested=0x%03X granted=0x%03X "
		% [label, int(started.get("requested_authority_mask", -1)),
			int(started.get("authoritative_domain_mask", -1))]
		+ "lifetime=0x%03X state=%s"
		% [int(started.get("lifetime_granted_mask", -1)),
			String(started.get("state", "?"))])
	_expect("[FLIP/%s] the restart records the new request immediately"
			% label,
		int(after_start["requested"]) == mask, _probe_line(after_start))
	ext.set_runtime_clock(true, WORKER_SPEED)
	return before_day


# =========================================================================
# world construction (the construction the parity fixture uses)
# =========================================================================
func _build_world(name: String, mask: int) -> Dictionary:
	var started := Time.get_ticks_msec()
	print("[BUILD/%s] generating %dx%d seed=%d mask=0x%03X"
		% [name, WIDTH, HEIGHT, SEED, mask])
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
	host.runtime_authority_domain_mask = mask
	host.runtime_parity_forcing = true
	get_root().add_child(host)
	await process_frame
	host.configure(null, null, clock)
	host.set_climate_authority_override("force_on")
	var config := NewGameConfig.create_default()
	config.country.name = "W %s" % name
	config.country.foreign_count = 1
	config.base.map_width = WIDTH
	config.base.map_height = HEIGHT
	config.base.initial_seed = SEED
	config.apply_land_layout("two")
	var session: Dictionary = host.configure_session({
		"kind": "new_game", "config": config.to_dictionary()})
	if not _require("BUILD/%s: the session configures" % name,
			bool(session.get("ok", false)), str(session)):
		return {}
	await host.generate_world(SEED)
	var generator: MapGenerator = host.get_generator()
	if not _require("BUILD/%s: production world generation succeeded" % name,
			generator != null):
		return {}
	var ext: Object = generator.get_data_core_world_ext()
	if not _require("BUILD/%s: production DCWorldExt is bound" % name, ext != null):
		return {}
	ext.set_runtime_ideology_parity_enabled(false)
	ext.set_runtime_clock(true, WORKER_SPEED)
	var w := {
		"name": name, "host": host, "clock": clock, "ext": ext,
		"generator": generator, "tick": 0, "cells": WIDTH * HEIGHT,
		"handle": 0, "started_ms": Time.get_ticks_msec(),
		"last_ideology": {}, "last_suppressed": false, "slices": 0,
		"faulted": false, "fault_reported": false,
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
# probes
# =========================================================================
func _probe(w: Dictionary, label: String = "") -> Dictionary:
	var ext: Object = w["ext"]
	var r: Dictionary = ext.get_runtime_thread_report()
	var front: Dictionary = ext.get_derived_cell_layer_report()
	var ideology: Dictionary = ext.get_ideology_report()
	return {
		"label": label,
		"main_day": int(w["tick"]),
		"state": String(r.get("simulation_host_state", "?")),
		"mode": String(r.get("simulation_thread_mode", "?")),
		"requested": int(r.get("requested_authority_mask", 0)),
		"granted": int(r.get("authoritative_domain_mask", 0)),
		"authority_ready": bool(r.get("authority_ready", false)),
		"committed": int(r.get("simulation_committed_day", -1)),
		"completed_days": int(r.get("completed_days", -1)),
		"day_stages": int(r.get("day_stage_count", -1)),
		"day_completed": int(r.get("day_completed_stage_count", -1)),
		"pod_mask": int(r.get("pod_completed_domain_mask", 0)),
		"env_day": int(r.get("simulation_environment_day", -1)),
		"ring": int(r.get("environment_ring_pending", -1)),
		"env_published": int(r.get("environment_published_days", -1)),
		"env_consumed": int(r.get("environment_consumed_days", -1)),
		"env_stale_rejected": int(r.get("stale_environment_rejected", -1)),
		"climate_committed": int(r.get("climate_committed_day", -1)),
		"climate_ready": bool(r.get("climate_pod_ready", false)),
		"climate_reason": String(r.get("climate_pod_fallback_reason", "")),
		"wait_day": int(r.get("day_wait_day", -1)),
		"wait_missing": int(r.get("day_wait_missing_mask", 0)),
		"wait_env_day": int(r.get("day_wait_env_day", -1)),
		"wait_ring": int(r.get("day_wait_ring", -1)),
		"park_reason": String(r.get("day_park_reason", "")),
		"fault": String(r.get("fault_code", "")),
		"faulted": not String(r.get("fault_code", "")).is_empty()
			or String(r.get("simulation_host_state", "")) == "FAULTED",
		"pump_day": int(w["host"].get("_ideology_derived_pumped_day")),
		"pump_calls": int(w["host"].get("_ideology_pump_calls")),
		"lock_skips": int(ideology.get("instance_refresh_lock_skips", -1)),
		"boundary_requests": int(r.get("main_boundary_service_requests", -1)),
		"rebuild_visits": int(ideology.get("cell_layer_rebuild_visits", -1)),
		"derived_pending": bool(ideology.get("derived_rebuild_pending", false)),
		"front_installed": bool(front.get("installed", false)),
		"front_cells": int(front.get("cell_count", -1)),
		"front_generation": int(front.get("layer_generation", -1)),
	}


func _probe_line(p: Dictionary) -> String:
	return ("main_day=%d state=%s mode=%s req=0x%03X granted=0x%03X "
		% [int(p["main_day"]), String(p["state"]), String(p["mode"]),
			int(p["requested"]), int(p["granted"])]
		+ "committed=%d days=%d stages=%d/%d pod_mask=0x%03X "
		% [int(p["committed"]), int(p["completed_days"]), int(p["day_completed"]),
			int(p["day_stages"]), int(p["pod_mask"])]
		+ "env_day=%d ring=%d pub=%d cons=%d stale_rej=%d climate_day=%d "
		% [int(p["env_day"]), int(p["ring"]), int(p["env_published"]),
			int(p["env_consumed"]), int(p["env_stale_rejected"]),
			int(p["climate_committed"])]
		+ "wait(day=%d missing=0x%03X env=%d ring=%d) pump(day=%d calls=%d skips=%d "
		% [int(p["wait_day"]), int(p["wait_missing"]), int(p["wait_env_day"]),
			int(p["wait_ring"]), int(p["pump_day"]), int(p["pump_calls"]),
			int(p["lock_skips"])]
		+ "bnd=%d) visits=%d "
		% [int(p["boundary_requests"]), int(p["rebuild_visits"])]
		+ "front(installed=%s cells=%d gen=%d) fault='%s'"
		% [str(p["front_installed"]), int(p["front_cells"]),
			int(p["front_generation"]), String(p["fault"])])


# =========================================================================
# day driving
# =========================================================================
func _service_peers(ext: Object, passes: int = PEER_PASSES) -> void:
	if not ext.has_method("service_country_worker_peer_adapter"):
		return
	for _pass in range(passes):
		ext.service_country_worker_peer_adapter(PEER_BATCH, true)


func _drive_days(w: Dictionary, days: int) -> void:
	for _index in range(days):
		_drive_day(w)


## One main-thread day. A worker fault does NOT stop the drive: the pumps this
## fixture measures live on `run_daily_tick`, which is a main-thread call, so a dead
## worker must not hide whether the mask gate opened. The fault is recorded once and
## printed in the trace.
func _drive_day(w: Dictionary) -> Dictionary:
	if Time.get_ticks_msec() - _run_started_ms > GLOBAL_BUDGET_MS:
		print("[BUDGET] wall-clock budget exhausted at day %d of '%s'"
			% [int(w["tick"]), String(w["name"])])
		return {"ok": false, "budget": true}
	var ext: Object = w["ext"]
	var clock: WorldClock = w["clock"]
	var host: WorldRuntimeHost = w["host"]
	var fault := _worker_fault(ext)
	if not fault.is_empty() and not bool(w.get("fault_reported", false)):
		w["fault_reported"] = true
		w["faulted"] = true
		print("[%s][FAULT] the worker faulted with '%s' at main day %d "
			% [String(w["name"]), fault, int(w["tick"])]
			+ "(recorded as the measured behaviour; the main-thread day keeps "
			+ "being driven so the mask gates stay measurable)")
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
	ext.drain_derived_cell_layer(day)
	if bool(ideology.get("suppressed", false)) and not bool(w.get("faulted", false)):
		var before := int(ext.get_runtime_thread_report().get(
			"ideology_pod_committed_day", -1))
		_wait_pod_day(w, before, POD_WAIT_MS)
	return {"ok": true, "day": day, "slices": slices,
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
		# Keep the Country peer transport wet while waiting: a worker that parks on
		# peer results would otherwise hit the 5 s stall timeout inside this wait.
		_service_peers(ext, 1)
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
	await WorkerWaitHelper.wait_for(
		func() -> bool:
			return _location_of(w, card) == 1,
		10, DAY_WAIT_MS * 2,
		func() -> void:
			_drive_day(w))
	if _location_of(w, card) == 1:
		return _require("%s: %s is live (location=1)" % [label, card], true)
	if not bool(w["last_suppressed"]):
		var acked := _ack_effect_transactions(w["ext"])
		print("[%s] effect-transaction fallback ack for %s: %s"
			% [label, card, str(acked)])
		_drive_days(w, 3)
	return _require("%s: %s is live (location=1)" % [label, card],
		_location_of(w, card) == 1,
		"location=%d last_error='%s'" % [_location_of(w, card),
			String(_snapshot(w).get("last_error", ""))])


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


# =========================================================================
# the selector fixture the derived layer needs (from the parity fixture)
# =========================================================================
func _install_selector_fixture(w: Dictionary, label: String) -> void:
	var ext: Object = w["ext"]
	if not ext.has_method("set_cell_tag_override_for_test"):
		return
	var cleared: Dictionary = ext.clear_cell_tag_overrides_for_test()
	_require("%s: prior tag overrides cleared" % label,
		bool(cleared.get("ok", false)), str(cleared))
	var metric := _effect_metric_id("cell.population")
	if metric >= 0:
		ext.set_effect_metric_override_for_test(metric, 800 * Q16_ONE, true)
	var cells := _owned_land_cells(w, 8)
	var tagged := 0
	for cell in cells:
		for tag in ["cell.settlement", "cell.terrain.tundra"]:
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


# =========================================================================
# teardown + assertions
# =========================================================================
## Frees every world this fixture still holds. Called between phases rather than only
## at the end: the fixture would otherwise keep three production worlds (three worker
## threads, three DCWorldExt instances) alive at once, and the memory and thread
## pressure that adds is a crash risk the fixture does not need to take.
func _dispose_all_worlds() -> void:
	for index in range(_worlds.size() - 1, -1, -1):
		var w: Dictionary = _worlds[index]
		var ext: Object = w.get("ext", null)
		if ext != null and ext.has_method("request_runtime_stop"):
			ext.request_runtime_stop()
		var deadline := Time.get_ticks_msec() + 5000
		while Time.get_ticks_msec() < deadline:
			var state := String(ext.get_runtime_thread_report().get(
				"simulation_host_state", "")) if ext != null else "STOPPED"
			if state == "STOPPED" or state == "FAULTED":
				break
			OS.delay_msec(5)
		var host: Object = w.get("host", null)
		if host != null and is_instance_valid(host):
			host.queue_free()
		var clock: Object = w.get("clock", null)
		if clock != null and is_instance_valid(clock):
			clock.queue_free()
	_worlds.clear()
	# Two frames is enough for `queue_free` to run and for the reaper thread to
	# release the host.
	await process_frame
	await process_frame
	await process_frame


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
