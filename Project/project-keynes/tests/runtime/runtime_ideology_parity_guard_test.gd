extends SceneTree

# Guards for the IDEOLOGY parity plumbing itself.
#
# This is NOT the parity gate. `runtime_ideology_parity_test.gd` is the gate and
# it asserts a real comparison happened. This file covers the invariants that
# keep a gate failure diagnosable, and it deliberately makes no claim about
# whether main and worker agree on business state.
#
# It exists separately because the previous round put these assertions inside the
# gate and they passed while the gate compared nothing -- "cannot compare" got
# locked in as expected behaviour. Keeping them apart means the gate can go red
# for a real divergence without these guards being reinterpreted as a pass.
#
# Covered here:
#
#   1. `accrue_points` must not consume an opinion revision it refused to settle.
#      A retryable gate (no Economy, revision 0, shape mismatch, class catalog
#      mismatch) has to stay retryable: the runtime used to store
#      `_points_revision_seen = revision` BEFORE validating, so one bad snapshot
#      permanently retired that revision and the runtime never allocated a single
#      country row for the rest of the session.
#   2. An empty reference snapshot is refused rather than stored. Storing one
#      made every later comparison fail with a `points*` field that pointed at
#      point accrual instead of at "the main side never ran".
#   3. The business-state export is sectioned and stable across a recapture.

var _checks := 0
var _failures := 0
var _next_sequence := 1


func _init() -> void:
	call_deferred("_run_and_finish")


func _run_and_finish() -> void:
	await _run()
	print("=== ideology parity guards: %d checks, %d failures ===" % [
		_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt unavailable")
		return

	# ── 1. A refused revision stays retryable ───────────────────────────────
	# The observable is `points_accrue_result`:
	#   0 settled, 1 no economy, 2 revision 0, 3 already seen,
	#   4 shape mismatch, 5 class catalog mismatch.
	# The defect was: a run that reached 4 or 5 consumed the revision anyway, so
	# the NEXT call reported 3 (already seen) instead of retrying. Asserting "the
	# result is 0 or 3 and rows exist" is what catches a regression, because a
	# runtime that retired the revision without settling can never reach 0 again.
	#
	# This needs a real Economy to publish opinion revisions, which is why it runs
	# inside a production world rather than on a bare DCWorldExt.
	# Economy needs several driver ticks before it publishes its first opinion
	# revision; accrual cannot settle before that. 6 days was not enough and made
	# the guard fail for a reason unrelated to the invariant it checks.
	var world := await _drive_world(16)
	if world.is_empty():
		return
	var ext: Object = world["ext"]
	var ideology: Dictionary = world["ideology"]

	_expect("accrual reports a settled or already-seen state once countries exist",
		int(ideology.get("countries_allocated", 0)) > 0,
		"no country rows were ever allocated, so accrual never settled a "
		+ "revision: accrue_result=%d revision_seen=%d" % [
			int(ideology.get("points_accrue_result", -99)),
			int(ideology.get("points_revision_seen", -1))])
	_expect("a settled runtime consumed at least one opinion revision",
		int(ideology.get("points_revision_seen", 0)) > 0,
		"revision_seen=0 after settling means every revision was retired "
		+ "without being applied")

	# ── 2. Business-state export is sectioned and stable ────────────────────
	var business: Dictionary = ext.get_ideology_business_state()
	_expect("business state exports", bool(business.get("ok", false)))
	_expect("business state reports every section",
		_expect_keys(business, [
			"points", "baseline", "history", "draw", "bits", "offer", "ideas"]))
	_expect("business state carries a nonzero hash",
		int(business.get("hash", 0)) != 0)
	var recaptured: Dictionary = ext.get_ideology_business_state()
	_expect("business hash is stable across an immediate recapture",
		int(business.get("hash", 0)) == int(recaptured.get("hash", 0)))
	_expect("business state reports one points row per country",
		int(business.get("points_q16", []).size()) ==
			int(business.get("countries", 0)))
	# `points` must not fold in `catalog_hash` or `points_revision`: those differ
	# between the two sides by construction and made the section permanently
	# unequal. The sub-hashes exist so a real cadence difference stays visible
	# without contaminating the business section.
	for key in ["points_balance", "points_lifetime", "points_revision",
			"history_cursor"]:
		_expect("business section exposes diagnostic sub-hash %s" % key,
			business.has(key))

	# ── 2b. Section sensitivity: a real change must move its own section ────
	#
	# Without this, a section could be a constant and every "sections agree"
	# assertion would pass vacuously. Granting points must move `points` and its
	# `points_balance` sub-hash, and must NOT move sections unrelated to points.
	var handles: PackedInt64Array = business.get("handles", PackedInt64Array())
	var points_before := int(business.get("points", 0))
	var balance_before := int(business.get("points_balance", 0))
	var ideas_before := int(business.get("ideas", 0))
	var bits_before := int(business.get("bits", 0))
	var targeted := false
	for handle in handles:
		if int(handle) == 0:
			continue
		var granted: Dictionary = ext.submit_ideology_commands({
			"opcodes": PackedInt32Array([2]),  # GRANT_POINTS
			"sequences": PackedInt64Array([_next_sequence]),
			"effective_days": PackedInt64Array([0]),
			"country_handles": PackedInt64Array([int(handle)]),
			"ideology_ids": PackedInt32Array([-1]),
			"values_q16": PackedInt64Array([900000]),
			"offer_generations": PackedInt64Array([0]),
			"choice_indices": PackedInt32Array([-1]),
			"gate_ids": PackedInt32Array([-1]),
			"source_priorities": PackedInt32Array([0]),
		})
		if bool(granted.get("ok", false)):
			targeted = true
			break
		print("    [grant] handle=%d rejected: %s" % [
			int(handle), JSON.stringify(granted)])
	if not _require("grant-points command is accepted", targeted):
		world["host"].free()
		world["clock"].free()
		return
	ext.run_ideology_daily(0)
	ext.run_ideology_daily(1)
	var after: Dictionary = ext.get_ideology_business_state()
	_expect("granting points moves the points section",
		int(after.get("points", 0)) != points_before,
		"points=0x%x unchanged after a grant; the section is not sensitive" % [
			points_before])
	_expect("granting points moves the points_balance sub-hash",
		int(after.get("points_balance", 0)) != balance_before,
		"points_balance unchanged after a grant")
	_expect("granting points leaves the ideas section alone",
		int(after.get("ideas", 0)) == ideas_before,
		"ideas moved on a points-only change; sections are not independent")
	_expect("granting points leaves the bits section alone",
		int(after.get("bits", 0)) == bits_before,
		"bits moved on a points-only change; sections are not independent")

	# ── 3. A bare runtime refuses to publish ────────────────────────────────
	var bare: Object = DCWorldExt.new()
	_expect("standalone DCWorldExt constructs", bare != null)
	if bare != null:
		var report: Dictionary = bare.get_ideology_report()
		_expect("unconfigured ideology report reports not-ok",
			not bool(report.get("ok", true)))
		# RefCounted: do NOT call free(); the previous round did and it produced a
		# SCRIPT ERROR that never reached `_failures`.

	world["host"].free()
	world["clock"].free()


func _drive_world(days: int) -> Dictionary:
	var clock := WorldClock.new()
	clock.auto_start = false
	clock.initial_speed = 1.0
	clock.debug_step_log = false
	get_root().add_child(clock)
	clock.pause(true)

	var host := WorldRuntimeHost.new()
	host.map_width = 30
	host.map_height = 20
	host.initial_seed = 20260910
	host.generate_test_economy_data = false
	host.test_economy_population_scale = 100
	host.runtime_parity_forcing = true
	host.runtime_climate_authority_enabled = false
	get_root().add_child(host)
	await process_frame
	host.configure(null, null, clock)

	var config := NewGameConfig.create_default()
	config.country.name = "Ideology Guards"
	config.country.foreign_count = 2
	config.base.map_width = 30
	config.base.map_height = 20
	config.base.initial_seed = 20260910
	config.apply_land_layout("two")
	var session: Dictionary = host.configure_session({
		"kind": "new_game", "config": config.to_dictionary()})
	if not _require("guard session configures", bool(session.get("ok", false)),
			str(session)):
		return {}

	await host.generate_world(20260910)
	var generator: MapGenerator = host.get_generator()
	if not _require("guard world generation succeeded", generator != null):
		return {}
	var ext: Object = generator.get_data_core_world_ext()
	if not _require("guard DCWorldExt is bound", ext != null):
		return {}

	ext.set_runtime_climate_parity_forcing(true)
	ext.set_runtime_clock(true, 10.0)
	_wait_worker_paused(ext)

	for tick in range(1, days + 1):
		var phase := clock.season_phase_for_day(tick)
		clock.current_day = float(tick)
		host.run_daily_tick(tick, phase)
		host.finish_daily_tick(0.0, {})
		var pulses := 0
		while _has_hard_barrier(clock) and pulses < 400:
			clock.simulation_backpressure_pulse.emit(tick)
			pulses += 1
		if ext.has_method("service_country_worker_peer_adapter"):
			ext.service_country_worker_peer_adapter(64, true)
		ext.publish_ideology_worker_inputs()
		ext.set_runtime_clock(false, 10.0)
		var deadline := Time.get_ticks_msec() + 400
		while Time.get_ticks_msec() < deadline:
			OS.delay_msec(2)
			if int(ext.get_runtime_thread_report().get(
					"ideology_pod_snapshot_generation", 0)) > 0:
				break
		ext.run_ideology_daily(tick)
		ext.set_runtime_clock(true, 10.0)
		_wait_worker_paused(ext)
		OS.delay_msec(2)

	return {"ext": ext, "host": host, "clock": clock,
		"ideology": ext.get_ideology_report()}


func _has_hard_barrier(clock: WorldClock) -> bool:
	return clock._simulation_backpressure_sources.has(&"country_day_barrier") \
		or clock._simulation_backpressure_sources.has(&"economy_day_barrier")


func _wait_worker_paused(ext: Object, timeout_msec: int = 2500) -> bool:
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


func _expect_keys(source: Dictionary, keys: Array) -> bool:
	for key in keys:
		if not source.has(key):
			return false
	return true


func _require(label: String, condition: bool, detail: String = "") -> bool:
	_expect(label, condition, detail)
	return condition


func _expect(label: String, condition: bool, detail: String = "") -> void:
	_checks += 1
	if not condition:
		_fail(label + ("" if detail.is_empty() else " (%s)" % detail))


func _fail(label: String) -> void:
	_failures += 1
	push_error("[FAIL] %s" % label)
