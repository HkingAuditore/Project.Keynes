extends SceneTree

# Ideology dual-authority parity gate (06 搂6 step 6).
#
# THIS IS A GATE, NOT A DIAGNOSTIC. It fails whenever `compared_count == 0`,
# because "we could not compare" is the defect this test exists to catch. A run
# that cannot arrange a comparison must be red, never quietly green.
#
# The fixture is copied from `runtime_country_parity_test.gd`, which is the
# known-good way to make the worker advance headless days:
#
#   runtime_climate_authority_enabled = false   (SHADOW: main thread authoritative)
#   runtime_parity_forcing            = true
#   do NOT touch runtime_authority_domain_mask
#   step the worker clock one day at a time and wait for the Climate trace
#
# That is the only configuration in which both authorities describe the same
# day: the worker's forced climate commit sets `climate_ok`, which lets the G7
# SHADOW Ideology stage run, while IDEOLOGY is not granted to the worker, so the
# main thread's `run_ideology_daily` is NOT suppressed. Both sides compute, both
# publish, and the comparison is real.
#
# Anti-regression note (2026-10-22): an earlier round drove this incorrectly
# (climate authority ON, mask forced to 0xFFF & ~0x10, free-running clock) and
# concluded "single-world dual authority is impossible". It is not; the driver
# was wrong. Keep this file's fixture aligned with runtime_country_parity_test.

const PRODUCTION_WIDTH := 30
const PRODUCTION_HEIGHT := 20
const SEED := 20260910
const WORKER_SPEED := 10.0
# Days the fixture must actually compare. The driver needs a warm-up (the worker
# cannot plan a day before its first Climate trace and opinion snapshot), so the
# gate asks for a floor rather than an exact count.
const MIN_COMPARED_DAYS := 4

var _checks := 0
var _failures := 0


func _init() -> void:
	call_deferred("_run_and_finish")


func _run_and_finish() -> void:
	var code := await _run()
	print("=== runtime ideology parity: %d checks, %d failures ===" % [
		_checks, _failures])
	quit(code if code != 0 else (0 if _failures == 0 else 1))


func _run() -> int:
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt unavailable")
		return 3
	return await _run_production_shadow_parity()


func _run_production_shadow_parity() -> int:
	var clock := WorldClock.new()
	clock.auto_start = false
	clock.initial_speed = 1.0
	clock.debug_step_log = false
	get_root().add_child(clock)
	clock.pause(true)

	var host := WorldRuntimeHost.new()
	host.map_width = PRODUCTION_WIDTH
	host.map_height = PRODUCTION_HEIGHT
	host.initial_seed = SEED
	# The formal multi-country start: the synthetic economy bootstrap can fail on
	# generated terrain with no timber/stone, which would leave no production
	# reference for this gate.
	host.generate_test_economy_data = false
	host.test_economy_population_scale = 100
	host.runtime_parity_forcing = true
	# SHADOW. With this false the worker still commits climate (forced), which is
	# what lets its Ideology stage run while the main thread keeps authority.
	host.runtime_climate_authority_enabled = false
	get_root().add_child(host)
	# `_init()` runs before the tree is entered, so a child added there reports
	# `is_inside_tree() == false` for the rest of the frame and `generate_world()`
	# returns silently -- which downstream reads as "get_generator() is null".
	await process_frame
	host.configure(null, null, clock)

	var config := NewGameConfig.create_default()
	config.country.name = "Ideology Parity"
	config.country.foreign_count = 2
	config.base.map_width = PRODUCTION_WIDTH
	config.base.map_height = PRODUCTION_HEIGHT
	config.base.initial_seed = SEED
	config.apply_land_layout("two")
	var session: Dictionary = host.configure_session({
		"kind": "new_game",
		"config": config.to_dictionary(),
	})
	if not _require("parity session configures", bool(session.get("ok", false)),
			str(session)):
		_teardown(host, clock)
		return 6

	await host.generate_world(SEED)
	var generator: MapGenerator = host.get_generator()
	if not _require("production world generation succeeded", generator != null):
		_teardown(host, clock)
		return 7
	var ext = generator.get_data_core_world_ext()
	if not _require("production DCWorldExt is bound", ext != null):
		_teardown(host, clock)
		return 8

	ext.set_runtime_climate_parity_forcing(true)
	# Reference capture is OFF in production (03 idle-zero-cost). A parity harness
	# is the only thing that may pay for it.
	ext.set_runtime_ideology_parity_enabled(true)
	var clocked: Dictionary = ext.set_runtime_clock(true, WORKER_SPEED) \
		if ext.has_method("set_runtime_clock") else {}
	if not _require("worker clock starts (%s)" % String(
			clocked.get("code", "unknown")), bool(clocked.get("ok", false))):
		_teardown(host, clock)
		return 9
	_expect("worker reaches a paused boundary", _wait_worker_paused(ext))

	var report: Dictionary = {}
	var compared_count := 0
	var matched_count := 0
	var pod_generation := 0
	var saw_ideology_grant := false
	var indexed_out := false
	var scheduler_sealed := true
	var last_main_day := -1
	# Climate yields one comparable frame roughly every two driver ticks, so
	# budget by frames rather than assuming one comparison per input tick.
	var soak_days := _soak_days()
	var budget := mini(soak_days * 2 + 4, 204)
	var tick := 0
	while tick < budget:
		tick += 1
		var phase := clock.season_phase_for_day(tick)
		clock.current_day = float(tick)
		host.run_daily_tick(tick, phase)
		host.finish_daily_tick(0.0, {})
		var pulses := 0
		while _has_hard_barrier(clock) and pulses < 400:
			clock.simulation_backpressure_pulse.emit(tick)
			pulses += 1
		if _has_hard_barrier(clock):
			scheduler_sealed = false
			print("[ideology-parity] scheduler seal timeout tick=%d sources=%s" % [
				tick, str(_hard_barrier_sources(clock))])
			break
		if ext.has_method("service_country_worker_peer_adapter"):
			ext.service_country_worker_peer_adapter(64, true)
		report = ext.get_runtime_thread_report()
		var consumed_before := int(report.get("climate_trace_consumed", 0))
		var trace_available := int(report.get("climate_trace_consumable", 0)) > 0
		# Publish the fresh opinion BEFORE stepping the worker.
		#
		# Ordering is load-bearing. If the worker plans the day first, it settles
		# against the PREVIOUS Economy revision while the main thread settles the
		# current one, and the two sides then accrue different amounts. That is a
		# fixture artefact that reads exactly like a business divergence.
		var published: Dictionary = ext.publish_ideology_worker_inputs()
		if OS.get_environment("PK_IDEOLOGY_TRACE") == "1" and tick <= 16:
			print("  [pub %d] ok=%s rev=%d main_seen=%d settled=%s accrue=%d" % [
				tick, str(published.get("ok", "?")),
				int(published.get("revision", -1)),
				int(published.get("main_points_revision", -1)),
				str(published.get("settled_now", "?")),
				int(published.get("accrue_result", -99))])
		# Single-step the worker, exactly like the country parity driver.
		ext.set_runtime_clock(false, WORKER_SPEED)
		var deadline := Time.get_ticks_msec() + (2500 if trace_available else 50)
		while Time.get_ticks_msec() < deadline:
			if ext.has_method("service_country_worker_peer_adapter"):
				ext.service_country_worker_peer_adapter(64, true)
			# Do not yield to process_frame: this runs with --quit and the
			# SceneTree would exit before the assertions execute.
			OS.delay_msec(2)
			report = ext.get_runtime_thread_report()
			if (tick == 1 and int(report.get(
					"climate_trace_consumed", 0)) > consumed_before) \
					or (tick > 1 and int(report.get(
						"ideology_pod_snapshot_generation", 0)) > 0
						and int(report.get(
							"climate_trace_consumed", 0)) > consumed_before):
				break
		# The main thread now settles the SAME opinion revision the worker used.
		#
		# BUT only once the worker exists. Accrual sets a per-country high-water
		# baseline from the first observation it sees, and the mark only ever
		# rises -- so whichever side accrues FIRST fixes its own starting point.
		# Letting the main thread accrue revision 1 while the worker had not
		# started yet gave the main side a baseline of 9 installed buildings; the
		# worker then baselined at 10 from revision 3, and the one-off catch-up the
		# main side earned could never be repaid. The result was a permanent
		# `points_revision` mismatch on every day (`matched=5/12`).
		#
		# Withholding the main-thread day until the worker has bootstrapped makes
		# both sides observe their first revision together. `pod_generation > 0`
		# means the worker has planned at least one day.
		# Drive the main thread on the WORKER's calendar, not the driver's (R8-4).
		#
		# The two clocks are not the same: the driver ticks once per loop, the
		# worker commits when Climate hands it a day. Running `run_ideology_daily`
		# with the driver's `tick` published a reference under one day and let the
		# worker commit under another, and the comparator then had to pair
		# misaligned days. It paired them by "closest", which compared day 14
		# against day 12 and reported the date difference as a business
		# divergence.
		#
		# The comparator now refuses a non-zero distance, so the driver owes it an
		# exact match: run every main-thread day up to and including the day the
		# worker just committed. `ideology_parity_worker_committed_day` is that
		# day; before the worker has committed anything it is -1.
		# Drive the main thread on the WORKER's calendar, not the driver's (R8-4).
		#
		# The two clocks are not the same: the driver ticks once per loop, the
		# worker commits when Climate hands it a day. Running `run_ideology_daily`
		# with the driver's `tick` published a reference under one day and let the
		# worker commit under another, and the comparator then had to pair
		# misaligned days.
		#
		# The comparator refuses a non-zero distance, so the driver owes it an exact
		# match: run the day the worker just committed.
		#
		# NOTE (05 §2.7): this is still one calendar per side. R9-1 intended to bind
		# the main thread to the OPINION the worker used for this day, which needs
		# the two sides' day numbering to be the same coordinate; that join is not
		# landed, so this driver stays as it is.
		var daily: Dictionary = {}
		var worker_day := int(report.get("ideology_parity_worker_committed_day", -1))
		if worker_day >= 0 and int(report.get(
				"ideology_pod_snapshot_generation", 0)) > 0 \
				and worker_day > last_main_day:
			daily = ext.run_ideology_daily(worker_day)
			last_main_day = worker_day
		ext.set_runtime_clock(true, WORKER_SPEED)
		_wait_worker_paused(ext)
		OS.delay_msec(2)
		report = ext.get_runtime_thread_report()
		if int(report.get("authoritative_domain_mask", 0)) & 0x10 != 0:
			saw_ideology_grant = true
		compared_count = int(report.get("ideology_parity_compared_count", 0))
		matched_count = int(report.get("ideology_parity_matched_count", 0))
		pod_generation = int(report.get("ideology_pod_snapshot_generation", 0))
		if OS.get_environment("PK_IDEOLOGY_TRACE") == "1":
			var ideo_report: Dictionary = ext.get_ideology_report()
			print("  [tick %d] pod_gen=%d accrue=%d econ_rev=%d main_seen=%d cmp=%d matched=%d field=%s ref_day=%d worker_day=%d" % [
				tick, pod_generation,
				int(ideo_report.get("points_accrue_result", -99)),
				int(ext.get_economy_report().get("class_opinion_revision", -1)),
				int(ideo_report.get("points_revision_seen", -1)),
				compared_count, matched_count,
				str(report.get("ideology_parity_field", "")),
				int(report.get("ideology_parity_reference_published_day", -1)),
				int(report.get("ideology_parity_worker_committed_day", -1))])
		if compared_count >= soak_days:
			indexed_out = true
			break
		# Also stop when the driver has run out of comparable frames: the worker
		# only yields one per Climate trace, so a fixed tick budget would otherwise
		# end mid-warm-up and report a lower count than the soak asked for.
		if tick >= budget - 2 and compared_count >= MIN_COMPARED_DAYS \
				and matched_count != compared_count:
			break

	var first_mismatch := int(report.get("ideology_parity_first_mismatch_day", -1))
	var field := String(report.get("ideology_parity_field", ""))
	var diff: Dictionary = report.get("ideology_parity_points_diff", {})
	print(("[ideology-parity] compared=%d matched=%d first_mismatch_day=%d "
		+ "field=%s pod_gen=%d worker_day=%d ref_countries=%d ref_pub=%d skipped=%d "
		+ "worker_opinion_rev=%d ref_points_rev=%d paired_ref=%d paired_worker=%d") % [
			compared_count, matched_count, first_mismatch, field, pod_generation,
			int(report.get("ideology_parity_worker_committed_day", -1)),
			int(report.get("ideology_parity_reference_published_countries", -1)),
			int(report.get("ideology_parity_reference_publish_count", -1)),
			int(report.get("ideology_parity_reference_skipped_count", -1)),
			int(report.get("ideology_parity_worker_opinion_revision", -1)),
			int(diff.get("reference_revision", -1)),
			int(report.get("ideology_parity_paired_reference_day", -1)),
			int(report.get("ideology_parity_paired_worker_day", -1))])
	if not diff.is_empty():
		print("[ideology-parity] points_diff=%s" % JSON.stringify(diff))
		print("[ideology-parity] row_mismatch slot=%d ref_handle=%d worker_handle=%d ref_points=%d worker_points=%d" % [
			int(report.get("ideology_parity_row_mismatch_slot", -1)),
			int(report.get("ideology_parity_row_mismatch_reference_handle", 0)),
			int(report.get("ideology_parity_row_mismatch_worker_handle", 0)),
			int(report.get("ideology_parity_row_mismatch_reference_points", 0)),
			int(report.get("ideology_parity_row_mismatch_worker_points", 0))])

	_expect("production scheduler seals every driven day", scheduler_sealed)
	# SHADOW: the worker must never own IDEOLOGY, or the main thread would be
	# suppressed and there would be nothing to compare.
	_expect("worker never owns IDEOLOGY in this fixture", not saw_ideology_grant,
		"authoritative_domain_mask gained bit 4; the main thread would be "
		+ "suppressed and every comparison would be against nothing")
	# The worker's Ideology stage must actually run; generation 0 means it never
	# planned a day and any "match" would be vacuous.
	_expect("worker Ideology stage ran at least one day", pod_generation > 0,
		"pod_generation=%d" % pod_generation)

	# THE GATE. `compared_count == 0` is a failure: this test exists to prove a
	# comparison happens, and a run that cannot arrange one has not demonstrated
	# parity. An earlier revision of this file asserted the opposite and passed
	# green while comparing nothing.
	_expect("parity actually compared at least %d days (compared=%d)" % [
			MIN_COMPARED_DAYS, compared_count], compared_count >= MIN_COMPARED_DAYS,
		"no comparison happened; worker_committed_day=%d pod_gen=%d field=%s" % [
			int(report.get("ideology_parity_worker_committed_day", -1)),
			pod_generation, field])
	_expect("every compared ideology day matched (matched=%d compared=%d)" % [
			matched_count, compared_count], matched_count == compared_count,
		"first_mismatch_day=%d field=%s diff=%s" % [
			first_mismatch, field, JSON.stringify(diff)])
	# R8-4: no worker day may be dropped for calendar misalignment. With the
	# driver aligned on the worker's committed day this must be 0; a non-zero value
	# means the two calendars drifted apart again and the comparison is quietly
	# weaker than it looks (it would otherwise hide as "no more days to compare").
	var uncompared := int(report.get("ideology_parity_uncompared_day_offset", -1))
	_expect("no ideology day was skipped for calendar misalignment (uncompared=%d)" % [
			uncompared], uncompared == 0,
		"the two authorities ran on different calendars; last distance=%d" % [
			int(report.get("ideology_parity_last_uncompared_distance", -1))])
	if compared_count >= 1:
		_expect("a matched run has no first mismatch day", first_mismatch < 0,
			"first_mismatch_day=%d field=%s" % [first_mismatch, field])
		_expect("parity exposed a nonzero worker hash",
			int(report.get("ideology_parity_worker_hash", 0)) != 0)
		_expect("parity exposed a nonzero reference hash",
			int(report.get("ideology_parity_reference_hash", 0)) != 0)

	# Catalog hash equality is a PRECONDITION the two sides can never meet: the
	# main thread and the worker hash their catalogs with different functions.
	# It is recorded, and it must not be the thing that makes a day mismatch.
	_expect("catalog disagreement is reported, not counted as business",
		int(report.get("ideology_parity_catalog_mismatch_count", -1)) >= 0)

	_teardown(host, clock)
	return 0


func _soak_days() -> int:
	var raw := OS.get_environment("PK_IDEOLOGY_SOAK_DAYS")
	if raw.is_empty():
		return 12
	return clampi(int(raw), 1, 60)


func _has_hard_barrier(clock: WorldClock) -> bool:
	return not _hard_barrier_sources(clock).is_empty()


func _hard_barrier_sources(clock: WorldClock) -> PackedStringArray:
	var sources := PackedStringArray()
	for source in [
		&"economy_day_barrier",
		&"country_day_barrier",
		&"ideology_day_barrier",
		&"bio_occupancy_day_barrier",
		&"native_daily_day_barrier",
	]:
		if clock._simulation_backpressure_sources.has(source):
			sources.append(String(source))
	return sources


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
