extends SceneTree

## PROBE: copy runtime_country_parity_test's production SHADOW driver verbatim,
## add the ideology hand-off per tick, and see whether the parity comparison
## actually happens.
##
## This exists because the previous round concluded "single-world dual authority
## is impossible" from a DIFFERENT driver (climate authority ON, mask forced to
## 0xFFF & ~0x10, clock free-running). runtime_country_parity_test proves that
## conclusion wrong: it uses climate authority OFF, steps the worker clock one
## day at a time, and compares 30 days. The G7 SHADOW Ideology stage
## (native_simulation_host.cpp, "G7 SHADOW stage") runs under exactly that
## configuration because forced climate commits still set climate_ok.

const MAP_WIDTH := 30
const MAP_HEIGHT := 20
const SEED := 20260910
const WORKER_SPEED := 10.0
const SOAK_DAYS := 12

var _checks := 0
var _failures := 0


func _init() -> void:
	call_deferred("_run_and_finish")


func _run_and_finish() -> void:
	await _run()
	print("=== shadow-driver probe: %d checks, %d failures ===" % [_checks, _failures])
	quit(0)


func _run() -> void:
	var clock: WorldClock = WorldClock.new()
	clock.auto_start = false
	clock.initial_speed = 1.0
	clock.debug_step_log = false
	get_root().add_child(clock)
	clock.pause(true)

	var host: WorldRuntimeHost = WorldRuntimeHost.new()
	host.map_width = MAP_WIDTH
	host.map_height = MAP_HEIGHT
	host.initial_seed = SEED
	host.generate_test_economy_data = false
	host.test_economy_population_scale = 100
	host.runtime_parity_forcing = true
	# Verbatim from country parity: NO climate authority, do not touch the mask.
	host.runtime_climate_authority_enabled = false
	get_root().add_child(host)
	await process_frame
	host.configure(null, null, clock)

	var config := NewGameConfig.create_default()
	config.country.name = "Ideology Parity"
	config.country.foreign_count = 2
	config.base.map_width = MAP_WIDTH
	config.base.map_height = MAP_HEIGHT
	config.base.initial_seed = SEED
	config.apply_land_layout("two")
	var session: Dictionary = host.configure_session({
		"kind": "new_game", "config": config.to_dictionary()})
	if not bool(session.get("ok", false)):
		print("    session failed: ", session)
		return

	await host.generate_world(SEED)
	var generator: MapGenerator = host.get_generator()
	if generator == null:
		print("    no generator")
		return
	var ext: Object = generator.get_data_core_world_ext()
	if ext == null:
		print("    no ext")
		return

	ext.set_runtime_climate_parity_forcing(true)
	var clocked: Dictionary = ext.set_runtime_clock(true, WORKER_SPEED)
	print("    clock: ", clocked)
	print("    paused: ", _wait_worker_paused(ext))

	var report: Dictionary = {}
	var tick := 0
	var budget := SOAK_DAYS * 2 + 4
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
		if ext.has_method("service_country_worker_peer_adapter"):
			ext.service_country_worker_peer_adapter(64, true)
		report = ext.get_runtime_thread_report()
		var consumed_before := int(report.get("climate_trace_consumed", 0))
		var trace_available := int(report.get("climate_trace_consumable", 0)) > 0
		# Publish the fresh opinion BEFORE stepping the worker. The order matters:
		# if the worker plans the day first it settles against the PREVIOUS
		# Economy revision while the main thread settles the current one, and the
		# two sides then accrue different amounts for reasons that have nothing to
		# do with Ideology. Same snapshot first, then both sides run.
		ext.publish_ideology_worker_inputs()
		# Single-step the worker exactly like country parity does.
		ext.set_runtime_clock(false, WORKER_SPEED)
		var deadline := Time.get_ticks_msec() + (2500 if trace_available else 50)
		while Time.get_ticks_msec() < deadline:
			if ext.has_method("service_country_worker_peer_adapter"):
				ext.service_country_worker_peer_adapter(64, true)
			OS.delay_msec(2)
			report = ext.get_runtime_thread_report()
			if (tick == 1 and int(report.get(
					"climate_trace_consumed", 0)) > consumed_before) \
					or (tick > 1 and int(report.get(
						"ideology_pod_snapshot_generation", 0)) > 0
						and int(report.get("climate_trace_consumed", 0)) > consumed_before):
				break
		# Main thread now settles the SAME opinion revision the worker just used.
		#
		# BUT only once the worker exists. Accrual sets a per-country baseline from
		# the first observation it sees, and the high-water mark only ever rises, so
		# whichever side accrues FIRST fixes its own starting point. Letting the
		# main thread accrue revisions 1..2 while the worker had not started yet
		# gave it a baseline from 9 buildings; the worker then started at revision 3
		# and baselined at 10, and the one-off catch-up the main thread earned can
		# never be repaid. Withholding the main-thread day until the worker has
		# bootstrapped makes both sides observe their first revision together.
		var daily: Dictionary = {}
		if int(report.get("ideology_pod_snapshot_generation", 0)) > 0:
			daily = ext.run_ideology_daily(tick)
		ext.set_runtime_clock(true, WORKER_SPEED)
		_wait_worker_paused(ext)
		OS.delay_msec(2)
		report = ext.get_runtime_thread_report()
		var d: Dictionary = ext.get_ideology_report()
		var biz: Dictionary = ext.get_ideology_business_state()
		print("    t=%d mask=0x%x pod_gen=%d countries=%d accrue=%d cmp=%d matched=%d field=%s ref_pub=%s" % [
			tick, int(report.get("authoritative_domain_mask", 0)),
			int(report.get("ideology_pod_snapshot_generation", 0)),
			int(d.get("countries_allocated", -1)),
			int(d.get("points_accrue_result", -99)),
			int(report.get("ideology_parity_compared_count", 0)),
			int(report.get("ideology_parity_matched_count", 0)),
			str(report.get("ideology_parity_field", "")),
			str(daily.get("parity_reference_published", "?"))])
		print("        main pts=%s | econ_rev=%d accrue=%d ref_buildings=%s" % [
			str(biz.get("points_q16", [])),
			int(ext.get_economy_report().get("class_opinion_revision", -1)),
			int(d.get("points_accrue_result", -99)),
			str(report.get("ideology_parity_points_diff", {}).get(
				"reference_baseline_buildings", "?"))])
		if int(report.get("ideology_parity_compared_count", 0)) >= SOAK_DAYS:
			break

	print("    FINAL compared=%d matched=%d mismatch_day=%d field=%s" % [
		int(report.get("ideology_parity_compared_count", -1)),
		int(report.get("ideology_parity_matched_count", -1)),
		int(report.get("ideology_parity_first_mismatch_day", -1)),
		str(report.get("ideology_parity_field", "?"))])
	print("    diff: ", report.get("ideology_parity_points_diff", {}))
	print("    ledger: pub=%d countries=%d skipped=%d" % [
		int(report.get("ideology_parity_reference_publish_count", -1)),
		int(report.get("ideology_parity_reference_published_countries", -1)),
		int(report.get("ideology_parity_reference_skipped_count", -1))])


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
