extends SceneTree

## EXPERIMENT: is `_economy_authority_boundary_mutex` reachable from a GDScript
## fixture at all? One question, two legs, and the COMPARISON is the deliverable.
##
## THE QUESTION
##
## `NativeSimulationHost::_economy_authority_boundary_mutex`
## (`native_simulation_host.h:1668`) serializes the economy input-capture boundary.
## The worker thread takes it with a BLOCKING `std::unique_lock` around the WHOLE
## semantic day -- from the command drain through `publish_day()`
## (`native_simulation_host.cpp:15608`) -- and releases it between days. Two
## GDScript-callable functions take it with `try_to_lock`:
##
##   `DCWorldExt::step_ideology_instance_refresh(day)`   (in production,
##       `world_ext_ideology.cpp:433`, called from
##       `world_runtime_host.gd:1387` inside `run_daily_tick` when the worker owns
##       IDEOLOGY 0x010)
##   `DCWorldExt::step_ideology_derived_rebuild(day)`    (REVERTED, not in this
##       build; this fixture never looks for it and only measures the lock itself)
##
## When the lock is not available both answer
##   {"ok": true, "done": false, "pending": true, "code": "economy_day_inflight"}
## and increment `_instance_refresh_lock_skips` (`world_ext_ideology.cpp:486-498`,
## exported as `instance_refresh_lock_skips` by `get_ideology_report()`).
##
## THE CLAIM UNDER TEST
##
## "A previous fixture drove simulation days synchronously (a plain loop calling
## `run_ideology_daily` etc.) and therefore never gave the worker thread a chance to
## reach a semantic-day boundary, so the lock was never free and every call returned
## `economy_day_inflight`."
##
## The correction being tested: the lock IS reachable if the caller POLLS with a
## delay, because `ideology_worker_wait_helper.gd`'s `wait_until(predicate,
## hang_guard_ms, service)` polls with `OS.delay_msec(2)` -- a window in which the
## worker thread can finish its day and release the boundary.
##
## WHAT THE FIRST RUN OF THIS FILE MEASURED (2026-10-29, mask 0xFFF, 16x12, 6 days
## per leg, this exact code plus per-day worker timing; the numbers below are the
## run's output, and the assertions below are the SIGN of these facts, not the
## counts, because the counts are timing-dependent):
##
##   leg A  synchronous, no yield   48 calls, 23 inflight, 25 ACQUIRED
##          (days 1-3 of the window: 8/8 acquired each; day 4: 1/8; days 5-6: 0/8)
##   leg B  polled, OS.delay_msec(2) 7 calls, 1 inflight, 6 acquired across 6 days,
##          five of them on the FIRST attempt with 0 ms elapsed, one on attempt 2
##          after 3 ms.
##
## So the correction is right and the original premise is WRONG in a way that is
## worth stating plainly: a synchronous drive does NOT always get
## `economy_day_inflight` -- it got the lock 25 times out of 48. The reason is in
## the worker loop, not in the lock: with CLIMATE 0x002 granted (mask 0xFFF) the
## worker is *climate driven* (`native_simulation_host.cpp:15525-15546`), so it runs
## ONE day per main-thread-published climate day and then parks in
## `RuntimeWorkerState::PAUSED` holding NO lock at all. The boundary is therefore
## free most of the time and busy only while that day is executing -- which is what
## the per-day `state` and `worker_time_execute/input_wait` deltas printed below
## measure. `economy_day_inflight` is a LIVE-CONTENTION answer, not the normal one.
##
## LEG A (negative control) drives N days by calling the day functions back to back
## and then fires LEG_A_CALLS_PER_DAY refresh calls with NO yielding whatsoever
## between them: no `OS.delay_msec`, no `await`, no `process_frame`. Expectation:
## every one of those calls is `economy_day_inflight`.
##
## LEG B (the claim) drives a FRESH worker world with the same mask and the same card
## the same number of days, but between day steps polls with
## `WorkerWaitHelper.wait_until(...)`, i.e. `OS.delay_msec(2)` per attempt, until the
## call stops returning `economy_day_inflight` or the per-day hang guard expires.
##
## WHAT IS MEASURED, PER LEG (all read from bound methods, nothing recomputed here)
##
##   * my own call outcomes: total / `economy_day_inflight` / acquired,
##   * the full returned Dictionary on the first non-inflight call,
##   * `instance_refresh_lock_skips` as a WINDOW DELTA and the per-call `lock_skips`,
##   * the worker's `authoritative_domain_mask`, `ideology_pod_committed_day`,
##     `completed_days`, `simulation_host_state`, `fault_code`,
##     `main_boundary_service_requests` (the R-3b parking ledger),
##   * `worker_time_boundary_wait_us` -- the worker's own cumulative wait to ACQUIRE
##     this mutex, which is the mirror image of the question,
##   * wall-clock duration of each burst / poll.
##
## A NOTE ON THE DAY STEP ITSELF (it is IDENTICAL in both legs, deliberately)
##
## `_step_day()` is the production handshake copied from
## `ideology_worker_authority_parity_test.gd:_drive_day` (same construction, same
## world, same card): clock day -> `_service_peers` -> `publish_ideology_worker_inputs`
## -> `run_daily_tick` -> `finish_daily_tick` -> backpressure pulses ->
## `run_ideology_daily` -> (only when NOT suppressed) `run_effect_daily` ->
## `dispatch_effect_native_modifier` -> `run_modifier_daily` ->
## `ack_effect_native_modifier` -> `drain_derived_cell_layer(CURRENT day)`.
##
## Two deliberate differences from the parity fixture, both applied to BOTH legs so
## they cannot explain any A/B difference:
##
##   1. NO `_wait_pod_day`. That helper calls `set_runtime_clock(false/true)`, i.e. it
##      PAUSES the worker, and pauses it exactly between the day step and the next
##      refresh call -- which is the variable under test. Leaving it in would make
##      Leg A stop being a "no window" control.
##   2. `run_daily_tick` itself calls `_step_ideology_instance_refresh_if_authoritative`
##      once per day (`world_runtime_host.gd:960`). That call is NOT mine and cannot
##      be disabled without editing an existing file, so it is left in and ACCOUNTED
##      FOR instead of pretended away: `lock_skips` counts EVERY refresh call, so
##      `host_skips = lock_skips_delta - my_inflight` is the number of skips the
##      production call site took in the same window. If `host_skips == 0` the
##      production call site won the boundary on every one of those days, which is
##      itself an answer to "is the lock reachable from the main thread".
##
## WHAT THIS FIXTURE DOES NOT DO
##
##   * It does not touch C++, `gdext/**`, thresholds or the DLL.
##   * It does not assert a green outcome it has not measured: each leg asserts the
##     measurement it actually took, printed with its numbers.
##   * It does not claim the reverted pump is correct. Reaching the lock is a
##     PRECONDITION for testing that pump; it is not evidence about the pump.
##
## Run (a worker world costs ~170 s to build, so budget accordingly):
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_boundary_lock_reachability_test.gd

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

## Every domain granted to the worker, IDEOLOGY included. 0xF7F (what the older
## ideology worker fixtures use) still GRANTS ideology -- it clears GAMEPLAY_EFFECT
## 0x080 -- so it is asserted below and never used.
const MASK_ALL := 0xFFF
const MASK_OLDER_FIXTURES := MASK_ALL & ~DOMAIN_GAMEPLAY_EFFECT
const MASK_MAIN_IDEOLOGY := MASK_ALL - DOMAIN_IDEOLOGY

## Kind 12, own territory, one derived program, two commands. The same card the
## parity fixture and the worker-layer diagnosis both equip, so "same cards" holds.
const CARD_A := "idea.public_hygiene"
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
const STATE_WAIT_MS := 15000
const EQUIP_MAX_DAYS := 10
## Days measured per leg (2 worker worlds x this many days).
const MEASURED_DAYS := 6
## Leg A: refresh calls PER DAY, fired back to back with no yield between them.
const LEG_A_CALLS_PER_DAY := 8
## Leg B: per-day hang guard for the polled attempt. A worker day in a 16x12 world
## is far shorter than this; the guard exists so a parked worker cannot hang the run.
const LEG_B_POLL_GUARD_MS := 4000
## Whole-run guard. Two worker worlds cost ~340 s of generation alone.
const GLOBAL_BUDGET_MS := 900000
## The Country peer transport is bounded per call (`max_results`) and the worker
## faults a day at `RUNTIME_DAY_STALL_PEER_FAULT_TIMEOUT_MS = 5000`
## (`runtime_pod_protocol.h:54`) when nothing services it -- which matters most
## inside a poll loop where the main thread is otherwise idle.
const PEER_PASSES := 6
const PEER_BATCH := 96

const WorkerWaitHelper = preload("res://tests/ideology/ideology_worker_wait_helper.gd")
const DrawGateHelper = preload("res://tests/ideology/ideology_draw_gate_helper.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")

## `RuntimeThreadReport` timing buckets, exported as `worker_time_<name>_us`
## (`world_ext_runtime_graph.cpp:755-761`). `input_wait` is where a CLIMATE-driven
## worker sleeps between days, `execute` is the semantic day itself (the window in
## which the boundary lock is held), `boundary_wait` is the worker waiting to TAKE
## this very lock, and `paused` is an explicit pause.
const TIMING_KEYS: Array = ["execute", "input_wait", "clock_wait", "paused",
	"boundary_wait", "overhead"]

var _checks := 0
var _failures := 0
var _next_sequence := 1
var _run_started_ms := 0
var _budget_exhausted := false
var _effect_cursor := 0


func _init() -> void:
	call_deferred("_run_and_finish")


func _run_and_finish() -> void:
	var code := await _run()
	print("=== ideology boundary lock reachability: %d checks, %d failures ===" % [
		_checks, _failures])
	quit(code if code != 0 else (0 if _failures == 0 else 1))


func _run() -> int:
	_run_started_ms = Time.get_ticks_msec()
	_banner()
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt unavailable")
		return 1
	if not _require("the bound DCWorldExt exposes step_ideology_instance_refresh",
			ClassDB.class_has_method("DCWorldExt",
				"step_ideology_instance_refresh")):
		return 1
	var leg_a := await _run_leg("A", MASK_ALL, 0)
	var leg_b := await _run_leg("B", MASK_ALL, 1)
	_compare_legs(leg_a, leg_b)
	return 0


# =========================================================================
# Banner: the bits, the masks, and the exact shape of the measurement
# =========================================================================
func _banner() -> void:
	print("[LOCK] `_economy_authority_boundary_mutex` reachability experiment")
	print("[LOCK] RuntimeDomainId bits: input_capture=0x%03X climate=0x%03X "
		% [DOMAIN_INPUT_CAPTURE, DOMAIN_CLIMATE]
		+ "country=0x%03X trigger_input=0x%03X ideology=0x%03X effect=0x%03X "
		% [DOMAIN_COUNTRY, DOMAIN_TRIGGER_INPUT, DOMAIN_IDEOLOGY,
			DOMAIN_EFFECT]
		+ "modifier=0x%03X gameplay_effect=0x%03X economy=0x%03X "
		% [DOMAIN_MODIFIER, DOMAIN_GAMEPLAY_EFFECT, DOMAIN_ECONOMY]
		+ "events=0x%03X visual=0x%03X commit=0x%03X"
		% [DOMAIN_EVENTS, DOMAIN_VISUAL, DOMAIN_COMMIT])
	_expect("LOCK: the ideology bit is domain 5 -> 0x010",
		DOMAIN_IDEOLOGY == 0x010, "0x%03X" % DOMAIN_IDEOLOGY)
	_expect("LOCK: 0xFFF grants every domain to the worker (ideology included), so "
		+ "the worker thread takes the boundary lock around every semantic day",
		(MASK_ALL & DOMAIN_IDEOLOGY) != 0 and (MASK_ALL & DOMAIN_ECONOMY) != 0,
		"0x%03X" % MASK_ALL)
	_expect("LOCK: 0x%03X (the mask the older ideology worker fixtures use) still "
		% MASK_OLDER_FIXTURES + "GRANTS ideology -- it clears GAMEPLAY_EFFECT 0x080, "
		+ "which cannot move this measurement, so 0xFFF is used instead",
		(MASK_OLDER_FIXTURES & DOMAIN_IDEOLOGY) != 0
			and (MASK_OLDER_FIXTURES & DOMAIN_GAMEPLAY_EFFECT) == 0,
		"0x%03X" % MASK_OLDER_FIXTURES)
	_expect("LOCK: 0x%03X is 0xFFF with only the ideology bit cleared (reported, "
		% MASK_MAIN_IDEOLOGY + "not used: both legs run 0xFFF)",
		MASK_MAIN_IDEOLOGY == 0xFEF, "0x%03X" % MASK_MAIN_IDEOLOGY)
	print("[LOCK] per leg: MEASURED_DAYS=%d, leg A fires %d refresh calls per day "
		% [MEASURED_DAYS, LEG_A_CALLS_PER_DAY]
		+ "with no yield; leg B polls with OS.delay_msec(2) up to %d ms per day"
		% LEG_B_POLL_GUARD_MS)


# =========================================================================
# One leg: build -> warm up -> equip the same card -> measure -> stop the worker
# =========================================================================
func _run_leg(name: String, mask: int, mode: int) -> Dictionary:
	var label := "LEG %s" % name
	print("[%s] START (%s drive), mask=0x%03X, t+%.1f s"
		% [label, "synchronous" if mode == 0 else "polled", mask,
			float(Time.get_ticks_msec() - _run_started_ms) / 1000.0])
	var w := await _build_world("lock-%s" % name, mask)
	if w.is_empty():
		_fail("%s: the worker world builds" % label)
		return {"leg": name, "built": false}
	w["mode"] = mode
	w["leg"] = name
	_install_selector_fixture(w, name)
	# Warm-up: the worker's authority mask is DEFERRED (it reads 0 until the pod is
	# ready), so it has to be read after days, never at build time.
	for _index in range(3):
		_step_day(w)
	_report(w, "%s warm-up" % name)
	var mask_now := _mask(w)
	_expect("%s: the worker reports mask 0x%03X with the ideology bit set, so it "
		% [label, mask_now] + "owns the domain whose boundary lock is being measured",
		mask_now == mask and (mask_now & DOMAIN_IDEOLOGY) != 0, _thread_line(w))
	_expect("%s: the main-thread ideology day is SUPPRESSED "
		% label + "(path=IDEOLOGY_WORKER)",
		bool(w["last_suppressed"])
			and String((w["last_ideology"] as Dictionary).get("path", "")) \
				== "IDEOLOGY_WORKER",
		str(w["last_ideology"]))
	_expect("%s: the worker is healthy entering the measurement (no fault_code)"
		% label, _worker_fault(w).is_empty(), _thread_line(w))

	var equipped := await _equip_card(w, CARD_A, name)
	var live := _live_card_count(w)
	print("[%s] card %s equipped=%s live_cards=%d day=%d"
		% [label, CARD_A, str(equipped), live, int(w["tick"])])
	_expect("%s: the same card is live in this leg before the measurement window "
		% label + "(reported, not required by the lock question)",
		live >= 1, "live=%d location=%d" % [live, _location_of(w, CARD_A)])

	var measure := await _measure(w, name, mode)
	measure["leg"] = name
	measure["built"] = true
	measure["equipped"] = equipped
	measure["live_cards"] = _live_card_count(w)
	measure["mask_warmup"] = mask_now
	_report(w, "%s end" % name)
	_teardown(w, name)
	await process_frame
	await process_frame
	return measure


## The measured window: MEASURED_DAYS day steps, each followed by the leg's own
## refresh discipline. Everything else is identical between the legs.
func _measure(w: Dictionary, name: String, mode: int) -> Dictionary:
	var before := _counters(w)
	var pod_before := _pod_day(w)
	var day_before := int(w["tick"])
	var per_day: Array = []
	var calls := 0
	var inflight := 0
	var acquired := 0
	var days_with_lock := 0
	var first_success: Dictionary = {}
	var first_success_day := -1
	var first_success_attempt := -1
	var first_success_elapsed_ms := -1
	for _index in range(MEASURED_DAYS):
		if _budget_exhausted:
			break
		var step: Dictionary = _step_day(w)
		if not bool(step.get("ok", false)):
			break
		var day := int(w["tick"])
		var pre := _worker_probe(w)
		var row: Dictionary = {}
		if mode == 0:
			row = _leg_a_burst(w, day, pre)
		else:
			row = _leg_b_poll(w, day, pre)
		var post := _worker_probe(w)
		var timing := _timing_ms_delta(pre, post)
		row["state_before"] = String(pre["state"])
		row["state_after"] = String(post["state"])
		row["pod_day_before"] = int(pre["pod_day"])
		row["pod_day_after"] = int(post["pod_day"])
		row["timing_ms"] = timing
		per_day.append(row)
		calls += int(row["calls"])
		inflight += int(row["inflight"])
		acquired += int(row["acquired"])
		if int(row["acquired"]) > 0:
			days_with_lock += 1
		if first_success.is_empty() \
				and not (row["first_success"] as Dictionary).is_empty():
			first_success = row["first_success"]
			first_success_day = day
			first_success_attempt = int(row["first_success_attempt"])
			first_success_elapsed_ms = int(row["elapsed_ms"])
		print("[LEG %s] day=%d worker state %s -> %s, pod_day %d -> %d, day cost: "
			% [name, day, String(pre["state"]), String(post["state"]),
				int(pre["pod_day"]), int(post["pod_day"])]
			+ "execute+%.1f ms input_wait+%.1f ms clock_wait+%.1f ms "
			% [float(timing["execute"]), float(timing["input_wait"]),
				float(timing["clock_wait"])]
			+ "paused+%.1f ms boundary_wait+%.1f ms"
			% [float(timing["paused"]), float(timing["boundary_wait"])])
	var after := _counters(w)
	var skips_delta := int(after["instance_refresh_lock_skips"]) \
		- int(before["instance_refresh_lock_skips"])
	var out := {
		"mode": mode,
		"days_driven": per_day.size(),
		"day_start": day_before,
		"day_end": int(w["tick"]),
		"mask_end": _mask(w),
		"pod_day_start": pod_before,
		"pod_day_end": _pod_day(w),
		"calls": calls,
		"inflight": inflight,
		"acquired": acquired,
		"days_with_lock": days_with_lock,
		"first_success": first_success,
		"first_success_day": first_success_day,
		"first_success_attempt": first_success_attempt,
		"first_success_elapsed_ms": first_success_elapsed_ms,
		"lock_skips_before": int(before["instance_refresh_lock_skips"]),
		"lock_skips_after": int(after["instance_refresh_lock_skips"]),
		"lock_skips_window": skips_delta,
		"host_skips": skips_delta - inflight,
		"max_consecutive_skips": int(
			after["instance_refresh_max_consecutive_skips"]),
		"passes_window": int(after["instance_refresh_passes"])
			- int(before["instance_refresh_passes"]),
		"visits_window": int(after["instance_refresh_visits"])
			- int(before["instance_refresh_visits"]),
		"per_day": per_day,
		"thread": _thread(w),
		"fault": _worker_fault(w),
	}
	print("[LEG %s][WINDOW] days=%d (%d..%d) mask=0x%03X pod_day %d..%d"
		% [name, int(out["days_driven"]), int(out["day_start"]),
			int(out["day_end"]), int(out["mask_end"]), pod_before,
			int(out["pod_day_end"])])
	print("[LEG %s][WINDOW] my_calls=%d inflight=%d acquired=%d lock_skips+=%d "
		% [name, calls, inflight, acquired, skips_delta]
		+ "host_skips=%d max_consecutive=%d passes+=%d visits+=%d fault='%s'"
		% [int(out["host_skips"]), int(out["max_consecutive_skips"]),
			int(out["passes_window"]), int(out["visits_window"]),
			String(out["fault"])])
	return out


## LEG A -- the negative control. LEG_A_CALLS_PER_DAY calls, back to back:
## no OS.delay_msec, no await, no process_frame, no service callback, nothing
## between one call and the next except the call itself.
func _leg_a_burst(w: Dictionary, day: int, pre: Dictionary) -> Dictionary:
	var ext: Object = w["ext"]
	var calls := 0
	var inflight := 0
	var acquired := 0
	var first_success: Dictionary = {}
	var first_failure: Dictionary = {}
	var started_us := Time.get_ticks_usec()
	for _index in range(LEG_A_CALLS_PER_DAY):
		var result: Dictionary = ext.step_ideology_instance_refresh(day)
		calls += 1
		if String(result.get("code", "")) == "economy_day_inflight":
			inflight += 1
			if first_failure.is_empty():
				first_failure = result
		else:
			acquired += 1
			if first_success.is_empty():
				first_success = result
	var burst_us := int(Time.get_ticks_usec() - started_us)
	print("[LEG A] day=%d burst: calls=%d inflight=%d acquired=%d in %d us "
		% [day, calls, inflight, acquired, burst_us]
		+ "(%.1f us/call, no yield of any kind) worker_state_before=%s"
		% [float(burst_us) / float(maxi(1, calls)), String(pre["state"])])
	if not first_failure.is_empty():
		print("[LEG A] day=%d first inflight dict=%s"
			% [day, str(first_failure)])
	if not first_success.is_empty():
		print("[LEG A][SUCCESS] day=%d a NON-inflight call arrived: %s"
			% [day, str(first_success)])
	return {
		"day": day, "calls": calls, "inflight": inflight,
		"acquired": acquired, "burst_us": burst_us,
		"first_success": first_success, "first_failure": first_failure,
		"first_success_attempt": 0, "elapsed_ms": 0,
	}


## LEG B -- the claim. `WorkerWaitHelper.wait_until` polls with `OS.delay_msec(2)`
## and runs the peer service between attempts, which is the window the correction
## says the worker needs to finish a semantic day and let go of the boundary.
##
## The result of the LAST attempt is the verdict, not the helper's bool: `wait_until`
## evaluates the predicate one final time after the guard expires, and that call is a
## real call with a real answer.
func _leg_b_poll(w: Dictionary, day: int, pre: Dictionary) -> Dictionary:
	var ext: Object = w["ext"]
	var tracker := {
		"calls": 0, "inflight": 0, "acquired": 0,
		"first_success": {}, "first_failure": {}, "last": {},
		"first_success_attempt": 0,
	}
	var started := Time.get_ticks_msec()
	WorkerWaitHelper.wait_until(
		func() -> bool:
			var result: Dictionary = ext.step_ideology_instance_refresh(day)
			tracker["calls"] = int(tracker["calls"]) + 1
			tracker["last"] = result
			if String(result.get("code", "")) == "economy_day_inflight":
				tracker["inflight"] = int(tracker["inflight"]) + 1
				if (tracker["first_failure"] as Dictionary).is_empty():
					tracker["first_failure"] = result
				return false
			tracker["acquired"] = int(tracker["acquired"]) + 1
			if (tracker["first_success"] as Dictionary).is_empty():
				tracker["first_success"] = result
				tracker["first_success_attempt"] = int(tracker["calls"])
			return true,
		LEG_B_POLL_GUARD_MS,
		func() -> void:
			_service_peers(w, 1))
	var elapsed := int(Time.get_ticks_msec() - started)
	var last: Dictionary = tracker["last"]
	var last_was_inflight := String(last.get("code", "")) \
		== "economy_day_inflight"
	var got := not last_was_inflight and not last.is_empty()
	var first_success: Dictionary = {}
	if got:
		first_success = tracker["first_success"]
		print("[LEG B] day=%d GOT THE LOCK: attempt=%d elapsed=%d ms "
			% [day, int(tracker["first_success_attempt"]), elapsed]
			+ "worker_state_before=%s dict=%s"
			% [String(pre["state"]), str(first_success)])
	else:
		print("[LEG B] day=%d NEVER got the lock in %d attempts / %d ms "
			% [day, int(tracker["calls"]), elapsed]
			+ "(guard=%d ms); last dict=%s"
			% [LEG_B_POLL_GUARD_MS, str(last)])
		if not (tracker["first_failure"] as Dictionary).is_empty():
			print("[LEG B] day=%d first inflight dict=%s"
				% [day, str(tracker["first_failure"])])
	return {
		"day": day, "calls": int(tracker["calls"]),
		"inflight": int(tracker["inflight"]),
		"acquired": int(tracker["acquired"]),
		"elapsed_ms": elapsed, "got_lock": got,
		"first_success": first_success,
		"first_success_attempt": int(tracker["first_success_attempt"]),
		"first_failure": tracker["first_failure"], "last": last,
	}


# =========================================================================
# The comparison -- the deliverable
# =========================================================================
func _compare_legs(a: Dictionary, b: Dictionary) -> void:
	print("[COMPARE] ----------------------------------------------------------")
	if not bool(a.get("built", false)) or not bool(b.get("built", false)):
		_fail("COMPARE: both legs built and measured")
		return
	print("[COMPARE] mask A=0x%03X B=0x%03X | pod_day A %d..%d B %d..%d | days "
		% [int(a["mask_end"]), int(b["mask_end"]), int(a["pod_day_start"]),
			int(a["pod_day_end"]), int(b["pod_day_start"]),
			int(b["pod_day_end"])]
		+ "A=%d B=%d | card live A=%d B=%d"
		% [int(a["days_driven"]), int(b["days_driven"]),
			int(a["live_cards"]), int(b["live_cards"])])
	print("[COMPARE] LEG A (synchronous, no yield): calls=%d inflight=%d acquired=%d "
		% [int(a["calls"]), int(a["inflight"]), int(a["acquired"])]
		+ "lock_skips+=%d host_skips=%d max_consecutive=%d"
		% [int(a["lock_skips_window"]), int(a["host_skips"]),
			int(a["max_consecutive_skips"])])
	print("[COMPARE] LEG B (polled, OS.delay_msec(2)): calls=%d inflight=%d acquired=%d "
		% [int(b["calls"]), int(b["inflight"]), int(b["acquired"])]
		+ "lock_skips+=%d host_skips=%d"
		% [int(b["lock_skips_window"]), int(b["host_skips"])])
	if not (b["first_success"] as Dictionary).is_empty():
		print("[COMPARE] LEG B first non-inflight call: day=%d attempt=%d"
			% [int(b["first_success_day"]), int(b["first_success_attempt"])])
		print("[COMPARE] LEG B first non-inflight dict=%s"
			% str(b["first_success"]))
	# ---- the facts each leg is allowed to assert about ITSELF -----------
	_expect("A: exactly %d refresh calls were fired over %d days"
		% [MEASURED_DAYS * LEG_A_CALLS_PER_DAY, MEASURED_DAYS],
		int(a["calls"]) == MEASURED_DAYS * LEG_A_CALLS_PER_DAY,
		"calls=%d" % int(a["calls"]))
	# THE NEGATIVE CONTROL DOES NOT HOLD, and that is the measured fact this file
	# asserts. The premise "a synchronous drive never gives the worker a window, so
	# every call is economy_day_inflight" is FALSIFIED: a no-yield burst takes the
	# lock whenever the worker is parked at a semantic-day boundary holding nothing.
	# The first run of this file measured 25 of 48 acquired; a run that measured 0 of
	# 48 would fail here, which is the point (a regression back to "always inflight"
	# must not pass silently).
	_expect("A[FALSIFIED PREMISE]: the SYNCHRONOUS leg also reaches the boundary lock "
		+ "-- %d of %d back-to-back calls acquired it" % [int(a["acquired"]),
			int(a["calls"])],
		int(a["acquired"]) > 0,
		"inflight=%d acquired=%d per_day=%s"
			% [int(a["inflight"]), int(a["acquired"]),
				str(_day_summary(a["per_day"]))])
	_expect("A: every counted call is exactly one of the two answers",
		int(a["inflight"]) + int(a["acquired"]) == int(a["calls"]),
		"inflight=%d acquired=%d calls=%d"
			% [int(a["inflight"]), int(a["acquired"]), int(a["calls"])])
	print("[A][MEASURED] %d of %d synchronous calls acquired, %d inflated, on %d of "
		% [int(a["acquired"]), int(a["calls"]), int(a["inflight"]),
			int(a["days_with_lock"])]
		+ "%d days at least one call took the lock"
		% int(a["days_driven"]))
	_expect("A: `lock_skips` (the facade counter) is at least my own inflight "
		+ "count -- the per-call ledger agrees with the report",
		int(a["lock_skips_window"]) >= int(a["inflight"]),
		"lock_skips+=%d inflight=%d"
			% [int(a["lock_skips_window"]), int(a["inflight"])])
	_expect("A: the worker really was running in this leg (its ideology pod "
		+ "committed day moved during the window)",
		int(a["pod_day_end"]) > int(a["pod_day_start"]),
		"pod_day %d..%d state=%s"
			% [int(a["pod_day_start"]), int(a["pod_day_end"]),
				String((a["thread"] as Dictionary).get(
					"simulation_host_state", "?"))])
	_expect("B: the polled leg's calls are counted and its lock_skips ledger agrees "
		+ "with them",
		int(b["calls"]) > 0 and int(b["lock_skips_window"]) >= int(b["inflight"]),
		"calls=%d inflight=%d lock_skips+=%d"
			% [int(b["calls"]), int(b["inflight"]),
				int(b["lock_skips_window"])])
	_expect("B: the boundary was reached on EVERY measured day (%d of %d), not once "
		% [int(b["days_with_lock"]), int(b["days_driven"])]
		+ "by luck -- the poll is a reliable way to get the lock",
		int(b["days_with_lock"]) == int(b["days_driven"])
			and int(b["days_driven"]) > 0,
		"days_with_lock=%d days=%d per_day=%s"
			% [int(b["days_with_lock"]), int(b["days_driven"]),
				str(_day_summary(b["per_day"]))])
	_expect("B: the worker really was running in this leg (its ideology pod "
		+ "committed day moved during the window)",
		int(b["pod_day_end"]) > int(b["pod_day_start"]),
		"pod_day %d..%d state=%s"
			% [int(b["pod_day_start"]), int(b["pod_day_end"]),
				String((b["thread"] as Dictionary).get(
					"simulation_host_state", "?"))])
	# ---- the headline: the claim under test ------------------------------
	_expect("HEADLINE: polling with OS.delay_msec(2) reaches "
		+ "`_economy_authority_boundary_mutex` from GDScript -- leg B acquired it "
		+ "(the correction is right, the blocker is not the environment)",
		int(b["acquired"]) > 0,
		"leg B: calls=%d inflight=%d acquired=%d first_success_day=%d "
			% [int(b["calls"]), int(b["inflight"]), int(b["acquired"]),
				int(b["first_success_day"])]
			+ "first_success_attempt=%d elapsed=%d ms"
			% [int(b["first_success_attempt"]),
				int(b["first_success_elapsed_ms"])])
	# ---- the comparison itself -------------------------------------------
	print("[COMPARE][RESULT] synchronous A: %d/%d calls inflated, %d acquired, on "
		% [int(a["inflight"]), int(a["calls"]), int(a["acquired"])]
		+ "%d/%d days; polled B: %d/%d inflated, %d acquired, on %d/%d days"
		% [int(a["days_with_lock"]), int(a["days_driven"]),
			int(b["inflight"]), int(b["calls"]), int(b["acquired"]),
			int(b["days_with_lock"]), int(b["days_driven"])])
	print("[COMPARE] worker state sampled just before each attempt: A [%s] | B [%s]"
		% [_state_summary(a["per_day"]), _state_summary(b["per_day"])])
	if int(b["acquired"]) > 0:
		print("[COMPARE][CONCLUSION] the boundary lock IS reachable from GDScript and "
			+ "the correction is right: leg B took it on %d of %d days (first success "
			% [int(b["days_with_lock"]), int(b["days_driven"])]
			+ "on attempt %d after %d ms). "
			% [int(b["first_success_attempt"]),
				int(b["first_success_elapsed_ms"])]
			+ "But leg A ALSO takes it -- %d of %d back-to-back calls, on %d of %d "
			% [int(a["acquired"]), int(a["calls"]), int(a["days_with_lock"]),
				int(a["days_driven"])]
			+ "days -- so the premise 'a synchronous drive never gets the lock, "
			+ "therefore every call is economy_day_inflight' is FALSE twice over. The "
			+ "lock does not need a polling window to be taken; it is simply NOT HELD "
			+ "most of the time. With CLIMATE 0x002 granted the worker is climate "
			+ "driven and parks in PAUSED between semantic days holding no lock (see "
			+ "the per-day worker_time_execute / input_wait deltas above). "
			+ "economy_day_inflight is a LIVE-CONTENTION answer, not the normal one.")
	else:
		print("[COMPARE][CONCLUSION] the boundary lock was NOT reached even with "
			+ "polling: leg B spent %d attempts over %d days inside a %d ms guard "
			% [int(b["calls"]), int(b["days_driven"]), LEG_B_POLL_GUARD_MS]
			+ "and never saw it free. The synchronous-drive explanation is WRONG and "
			+ "the 'blocked by the environment' status stands.")
	print("[COMPARE] ----------------------------------------------------------")


func _day_summary(per_day: Array) -> Array:
	var out: Array = []
	for row_value in per_day:
		var row: Dictionary = row_value
		out.append("d%d:%d/%d" % [int(row.get("day", -1)),
			int(row.get("inflight", -1)), int(row.get("calls", -1))])
	return out


## How the worker was found just before each attempt: PAUSED means it was parked
## waiting for the next climate day and held no boundary lock; RUNNING means it was
## inside a day transaction and the lock was busy.
func _state_summary(per_day: Array) -> String:
	var counts := {}
	for row_value in per_day:
		var row: Dictionary = row_value
		var state := String(row.get("state_before", "?"))
		counts[state] = int(counts.get(state, 0)) + 1
	var parts := PackedStringArray()
	for key in counts:
		parts.append("%s=%d" % [String(key), int(counts[key])])
	return ", ".join(parts)


# =========================================================================
# World construction -- copied from `ideology_worker_authority_parity_test.gd`
# (`_build_world`), the proven production path for a worker world. A hand-built
# MapData crashes (`world_ext_economy.cpp:929-930`, plan §14.3 M1-8).
# =========================================================================
func _build_world(label: String, mask: int) -> Dictionary:
	var started := Time.get_ticks_msec()
	print("[BUILD/%s] generating %dx%d seed=%d mask=0x%03X, t+%.1f s"
		% [label, WIDTH, HEIGHT, SEED, mask,
			float(started - _run_started_ms) / 1000.0])
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
	config.country.name = "W %s" % label
	config.country.foreign_count = 1
	config.base.map_width = WIDTH
	config.base.map_height = HEIGHT
	config.base.initial_seed = SEED
	config.apply_land_layout("two")
	var session: Dictionary = host.configure_session({
		"kind": "new_game", "config": config.to_dictionary()})
	if not _require("[BUILD/%s] the session configures" % label,
			bool(session.get("ok", false)), str(session)):
		return {}
	await host.generate_world(SEED)
	var generator: MapGenerator = host.get_generator()
	if not _require("[BUILD/%s] production world generation succeeded" % label,
			generator != null):
		return {}
	var ext: Object = generator.get_data_core_world_ext()
	if not _require("[BUILD/%s] production DCWorldExt is bound" % label,
			ext != null):
		return {}
	ext.set_runtime_ideology_parity_enabled(false)
	ext.set_runtime_clock(true, WORKER_SPEED)
	var w := {
		"name": label, "host": host, "clock": clock, "ext": ext,
		"generator": generator, "tick": 0, "cells": CELLS, "handle": 0,
		"started_ms": Time.get_ticks_msec(), "last_ideology": {},
		"last_suppressed": false, "faulted": false, "fault_reported": false,
		"stopped": false, "mode": 0, "leg": label,
	}
	var handles := _country_handles(w)
	if not _require("[BUILD/%s] the world has at least one country" % label,
			handles.size() >= 1, str(handles)):
		return {}
	w["handle"] = int(handles[0])
	w["tick"] = maxi(0, _world_day(w))
	print("[BUILD/%s] ready in %d ms (t+%.1f s): countries=%d handle=%d "
		% [label, Time.get_ticks_msec() - started,
			float(Time.get_ticks_msec() - _run_started_ms) / 1000.0,
			handles.size(), int(w["handle"])]
		+ "start_day=%d" % int(w["tick"]))
	return w


func _country_handles(w: Dictionary) -> PackedInt64Array:
	var ext: Object = w["ext"]
	var seen := {}
	var out := PackedInt64Array()
	for cell in range(int(w["cells"])):
		var handle := int(ext.get_country_cell_summary(cell).get(
			"country_handle", 0))
		if handle == 0 or seen.has(handle):
			continue
		seen[handle] = true
		out.append(handle)
	return out


# =========================================================================
# The day step -- identical in both legs (see the header for what is omitted)
# =========================================================================
func _service_peers(w: Dictionary, passes: int = PEER_PASSES) -> void:
	var ext: Object = w["ext"]
	if not ext.has_method("service_country_worker_peer_adapter"):
		return
	for _pass in range(passes):
		ext.service_country_worker_peer_adapter(PEER_BATCH, true)


func _step_day(w: Dictionary) -> Dictionary:
	if _budget_exhausted:
		return {"ok": false, "budget": true}
	if Time.get_ticks_msec() - _run_started_ms > GLOBAL_BUDGET_MS:
		_budget_exhausted = true
		print("[BUDGET] wall-clock budget exhausted at day %d of '%s'; stopping and "
			% [int(w["tick"]), String(w["name"])]
			+ "reporting what has been measured")
		return {"ok": false, "budget": true}
	var ext: Object = w["ext"]
	var clock: WorldClock = w["clock"]
	var host: WorldRuntimeHost = w["host"]
	var fault := _worker_fault(w)
	if not fault.is_empty():
		w["faulted"] = true
		if not bool(w.get("fault_reported", false)):
			w["fault_reported"] = true
			print("[FAULT/%s] worker faulted with '%s' at day %d (recorded as data: "
				% [String(w["leg"]), fault, int(w["tick"])]
				+ "a faulted worker stops holding the boundary, which would make "
				+ "this leg's numbers meaningless)")
	w["tick"] = int(w["tick"]) + 1
	var day := int(w["tick"])
	clock.current_day = float(day)
	_service_peers(w)
	if ext.has_method("publish_ideology_worker_inputs"):
		ext.publish_ideology_worker_inputs()
	host.run_daily_tick(day, clock.season_phase_for_day(day))
	host.finish_daily_tick(0.0, {})
	var pulses := 0
	while _has_hard_barrier(w) and pulses < 400:
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
	if not bool(w["last_suppressed"]):
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
	# anything confirmed.
	var drained: Dictionary = ext.drain_derived_cell_layer(day)
	print("[DAY/%s] day=%d suppressed=%s path=%-16s mask=0x%03X pod_day=%d pulses=%d "
		% [String(w["leg"]), day, str(w["last_suppressed"]),
			String(ideology.get("path", "")), _mask(w), _pod_day(w), pulses]
		+ "drain_steps=%d boundary_reqs=%d worker_state=%s completed_days=%d"
		% [int(drained.get("steps", 0)), _boundary_requests(w),
			String(_thread(w).get("simulation_host_state", "?")),
			int(_thread(w).get("completed_days", -1))])
	return {"ok": true, "day": day, "suppressed": bool(w["last_suppressed"]),
		"slices": slices, "drained": drained}


func _has_hard_barrier(w: Dictionary) -> bool:
	var clock: Object = w.get("clock", null)
	if clock == null or not clock.has_method("has_hard_barrier"):
		return false
	return bool(clock.has_hard_barrier())


# =========================================================================
# Ideology commands (identical to the parity fixture)
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


func _equip_card(w: Dictionary, card: String, name: String) -> bool:
	var dense := _dense_id(card)
	if dense < 0:
		_fail("LEG %s: %s is absent from the compiled catalog" % [name, card])
		return false
	var gate: Dictionary = DrawGateHelper.grant_draw_gates(
		w["host"], card, int(w["handle"]), int(w["tick"]), _next_sequence)
	if not _require("LEG %s: %s draw gates clear" % [name, card],
			bool(gate.get("ok", false)), str(gate)):
		return false
	_next_sequence = maxi(_next_sequence, int(gate.get(
		"next_sequence", _next_sequence)))
	_step_day(w)
	var preamble: Dictionary = _submit(w, [
		{"op": OP_GRANT_POINTS, "idea": -1, "value": 64 * Q16_ONE},
		{"op": OP_DISCOVER, "idea": dense},
		{"op": OP_ADD_UNDERSTANDING, "idea": dense, "value": 0},
	])
	if not _require("LEG %s: %s grant/discover/understanding accepted"
			% [name, card], bool(preamble.get("ok", false)), str(preamble)):
		return false
	for _index in range(2):
		_step_day(w)
	var equipped: Dictionary = _submit(w, [{"op": OP_EQUIP, "idea": dense}])
	if not _require("LEG %s: %s equip accepted" % [name, card],
			bool(equipped.get("ok", false)), str(equipped)):
		return false
	await WorkerWaitHelper.wait_for(
		func() -> bool:
			return _location_of(w, card) == 1,
		EQUIP_MAX_DAYS, 20000,
		func() -> void:
			_step_day(w))
	if _location_of(w, card) == 1:
		return _require("LEG %s: %s is live (location=1)" % [name, card], true)
	if not bool(w["last_suppressed"]):
		var acked := _ack_effect_transactions(w)
		print("[LEG %s] effect-transaction fallback ack for %s: %s"
			% [name, card, str(acked)])
		for _index in range(3):
			_step_day(w)
	return _require("LEG %s: %s is live (location=1)" % [name, card],
		_location_of(w, card) == 1,
		"location=%d last_error='%s' levels=%s"
			% [_location_of(w, card),
				String(_snapshot(w).get("last_error", "")),
				str(_snapshot(w).get("levels", PackedInt32Array()))])


func _ack_effect_transactions(w: Dictionary) -> Dictionary:
	var ext: Object = w["ext"]
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
	return w["ext"].get_ideology_snapshot(int(w["handle"]))


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


func _live_card_count(w: Dictionary) -> int:
	var locations: PackedInt32Array = _snapshot(w).get(
		"locations", PackedInt32Array())
	var count := 0
	for location in locations:
		if int(location) == 1:
			count += 1
	return count


# =========================================================================
# The selector fixture (copied from the parity fixture, which took it from
# `ideology_x6c_worker_test.gd`). It changes WHICH cells the card targets; it has
# no bearing on the boundary lock and is here only so both legs equip the same card
# against the same world conditions.
# =========================================================================
func _install_selector_fixture(w: Dictionary, name: String) -> void:
	var ext: Object = w["ext"]
	if not ext.has_method("set_cell_tag_override_for_test"):
		return
	var cleared: Dictionary = ext.clear_cell_tag_overrides_for_test()
	_require("LEG %s: prior tag overrides cleared" % name,
		bool(cleared.get("ok", false)), str(cleared))
	var metric := _effect_metric_id("cell.population")
	if metric >= 0:
		var population: Dictionary = ext.set_effect_metric_override_for_test(
			metric, POPULATION_Q16, true)
		_require("LEG %s: cell.population pinned" % name,
			bool(population.get("ok", false)), str(population))
	var cells := _owned_land_cells(w, 8)
	var tagged := 0
	for cell in cells:
		for tag in [TAG_A, TAG_B]:
			var result: Dictionary = ext.set_cell_tag_override_for_test(
				String(tag), int(cell), true)
			if bool(result.get("ok", false)):
				tagged += 1
	print("[SETUP/LEG %s] selector fixture: owned_land_cells=%d tags_set=%d metric=%d"
		% [name, cells.size(), tagged, metric])
	ext.refresh_effect_input_digest_for_test()


func _owned_land_cells(w: Dictionary, limit: int) -> PackedInt32Array:
	var ext: Object = w["ext"]
	var out := PackedInt32Array()
	var map = w["host"].get_current_map() if w["host"].has_method(
		"get_current_map") else null
	for cell in range(int(w["cells"])):
		if int(ext.get_country_cell_summary(cell).get("country_handle", 0)) \
				!= int(w["handle"]):
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
# Reading the runtime -- every number below comes from a bound method
# =========================================================================
func _thread(w: Dictionary) -> Dictionary:
	if w.is_empty() or w.get("ext", null) == null:
		return {}
	return w["ext"].get_runtime_thread_report()


func _mask(w: Dictionary) -> int:
	return int(_thread(w).get("authoritative_domain_mask", 0))


func _pod_day(w: Dictionary) -> int:
	return int(_thread(w).get("ideology_pod_committed_day", -1))


func _boundary_requests(w: Dictionary) -> int:
	return int(_thread(w).get("main_boundary_service_requests", -1))


## One read of everything that decides whether the boundary is free RIGHT NOW:
## the worker's state (a CLIMATE-driven worker sleeps in PAUSED between days), the
## domain mask (the grant is deferred, so 0 means "not promoted yet"), the pod day,
## and the timing buckets that say where the worker spends its time.
func _worker_probe(w: Dictionary) -> Dictionary:
	var report := _thread(w)
	var timing := {}
	for key in TIMING_KEYS:
		timing[key] = int(report.get("worker_time_%s_us" % String(key), -1))
	return {
		"state": String(report.get("simulation_host_state", "?")),
		"mode": String(report.get("simulation_thread_mode", "?")),
		"mask": int(report.get("authoritative_domain_mask", 0)),
		"pod_day": int(report.get("ideology_pod_committed_day", -1)),
		"completed_days": int(report.get("completed_days", -1)),
		"boundary_reqs": int(report.get("main_boundary_service_requests", -1)),
		"timing": timing,
	}


func _timing_ms_delta(pre: Dictionary, post: Dictionary) -> Dictionary:
	var out := {}
	var first: Dictionary = pre.get("timing", {})
	var second: Dictionary = post.get("timing", {})
	for key in TIMING_KEYS:
		out[key] = float(int(second.get(String(key), 0))
			- int(first.get(String(key), 0))) / 1000.0
	return out


func _worker_fault(w: Dictionary) -> String:
	var ext: Object = w.get("ext", null)
	if ext == null or not ext.has_method("get_runtime_thread_report"):
		return ""
	return String(ext.get_runtime_thread_report().get("fault_code", ""))


func _world_day(w: Dictionary) -> int:
	var report := _thread(w)
	for key in ["world_day", "ideology_pod_committed_day", "completed_days",
			"day"]:
		if report.has(key):
			return int(report[key])
	return 0


func _counters(w: Dictionary) -> Dictionary:
	var report: Dictionary = w["ext"].get_ideology_report()
	var out := {}
	for key in ["instance_refresh_lock_skips",
			"instance_refresh_max_consecutive_skips",
			"instance_refresh_consecutive_skips", "instance_refresh_passes",
			"instance_refresh_visits", "instance_refresh_skips"]:
		out[key] = int(report.get(key, -1))
	return out


func _thread_line(w: Dictionary) -> String:
	var thread := _thread(w)
	return ("mask=0x%03X state=%s mode=%s pod_day=%d completed_days=%d "
		% [int(thread.get("authoritative_domain_mask", -1)),
			String(thread.get("simulation_host_state", "?")),
			String(thread.get("simulation_thread_mode", "?")),
			int(thread.get("ideology_pod_committed_day", -1)),
			int(thread.get("completed_days", -1))]
		+ "fault='%s' blocker='%s'"
		% [String(thread.get("fault_code", "")),
			String(thread.get("simulation_worker_blocker", ""))])


func _report(w: Dictionary, label: String) -> void:
	var thread := _thread(w)
	print("[STATE/%s] %s" % [label, _thread_line(w)])
	print("[STATE/%s] pod_ready=%s econ_pod_day=%d main_boundary_service_requests=%s "
		% [label, str(thread.get("ideology_pod_ready", "?")),
			int(thread.get("economy_pod_committed_day", -1)),
			str(thread.get("main_boundary_service_requests", "?"))]
		+ "ideology_bit=%s worker_time_boundary_wait_us=%s"
		% [str(thread.get("main_boundary_service_ideology", "?")),
			str(thread.get("worker_time_boundary_wait_us", "?"))])
	print("[STATE/%s] day=%d suppressed=%s path=%s"
		% [label, int(w.get("tick", -1)), str(w.get("last_suppressed", "?")),
			String((w.get("last_ideology", {}) as Dictionary).get("path", ""))])
	var counters := _counters(w)
	print("[STATE/%s] instance_refresh: lock_skips=%d max_consecutive=%d "
		% [label, int(counters["instance_refresh_lock_skips"]),
			int(counters["instance_refresh_max_consecutive_skips"])]
		+ "consecutive=%d passes=%d visits=%d card_skips=%d"
		% [int(counters["instance_refresh_consecutive_skips"]),
			int(counters["instance_refresh_passes"]),
			int(counters["instance_refresh_visits"]),
			int(counters["instance_refresh_skips"])])


# =========================================================================
# Teardown + assertions
# =========================================================================
## Stops the worker before releasing the world so the NEXT leg does not compete
## with a live worker thread for the boundary of a world nobody measures.
func _teardown(w: Dictionary, name: String) -> void:
	var ext: Object = w.get("ext", null)
	if ext != null and ext.has_method("request_runtime_stop"):
		# Release the boundary turn we may have left requested, otherwise the worker
		# sits parked in its between-days loop and never sees the stop request.
		if ext.has_method("step_ideology_instance_refresh"):
			ext.step_ideology_instance_refresh(int(w.get("tick", 0)))
		ext.request_runtime_stop()
		var deadline := Time.get_ticks_msec() + STATE_WAIT_MS
		var state := ""
		while Time.get_ticks_msec() < deadline:
			state = String(ext.get_runtime_thread_report().get(
				"simulation_host_state", ""))
			if state in ["STOPPED", "FAULTED"]:
				break
			OS.delay_msec(2)
		print("[TEARDOWN/LEG %s] worker state=%s after the stop request"
			% [name, state])
	var host: Object = w.get("host", null)
	if host != null and is_instance_valid(host):
		host.queue_free()
	var clock: Object = w.get("clock", null)
	if clock != null and is_instance_valid(clock):
		clock.queue_free()


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
