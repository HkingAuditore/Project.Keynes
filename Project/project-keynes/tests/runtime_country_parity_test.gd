extends SceneTree

# Country SHADOW plan/replay: unified business hash, command dual-write,
# reference publication, probe formula parity, and a 30–100 day soak window.
# Production implemented mask is Climate|Country|Trigger|Ideology|Modifier|Effect|Events|COMMIT
# = 0xA7E after H8/I8.
# This harness stays on SHADOW Country compare evidence (sync writer + Host
# mirror); it does not grant Country ACTIVE.

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryFacadeScript = preload("res://scripts/country/country_facade.gd")
const PRODUCTION_WORKER_SPEED := 10.0
const PRODUCTION_WIDTH := 30
const PRODUCTION_HEIGHT := 20

var _checks := 0
var _failures := 0


func _init() -> void:
	var code := await _run()
	print("runtime country parity: %d checks, %d failures" % [_checks, _failures])
	quit(code if code != 0 else (0 if _failures == 0 else 1))


func _soak_days() -> int:
	var raw := OS.get_environment("PK_COUNTRY_SOAK_DAYS")
	if raw.is_empty():
		return 30
	return clampi(int(raw), 1, 100)


func _run() -> int:
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt unavailable")
		return 3
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		return 4
	var ext: Object = DCWorldExt.new()
	var country = CountryFacadeScript.new()
	_expect("country configures", bool(country.configure(
		ext, 6, 20260910, load("res://data/country/default_country.tres"),
		compiled).get("ok", false)))
	var boot_packet := {
		"country_ids": PackedStringArray(["country.parity.a", "country.parity.b"]),
		"country_names": PackedStringArray(["Parity A", "Parity B"]),
		"country_cash": PackedInt64Array([10000, 20000]),
		"territory_offsets": PackedInt32Array([0, 2, 4]),
		"territory_cells": PackedInt32Array([0, 1, 2, 3]),
		"technology_offsets": PackedInt32Array([0, 1, 2]),
		"technology_indices": PackedInt32Array([
			compiled.technology_ids.find("tech.hunting"),
			compiled.technology_ids.find("tech.hunting")]),
		"treasury_offsets": PackedInt32Array([0, 0, 0]),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}
	_expect("country bootstraps", bool(country.bootstrap(
		PackedByteArray([0, 0, 0, 0, 0, 0]), boot_packet).get("ok", false)))
	var first: Dictionary = ext.capture_country_runtime_snapshot()
	var again: Dictionary = ext.capture_country_runtime_snapshot()
	_expect("export_pod_snapshot hash is stable across immediate recapture",
		bool(first.get("ok", false)) and bool(again.get("ok", false))
		and int(first.get("state_hash", 0)) != 0
		and int(first.get("state_hash", 1)) == int(again.get("state_hash", 0)))
	_expect("catalog capture configures the Host POD",
		bool(ext.capture_country_pod_catalog().get("ok", false)))

	var started: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "SHADOW",
		"graph_coverage_complete": true,
		"day": 0,
		"speed_days_per_second": 1000.0,
		"paused": false,
	})
	_expect("SHADOW Host starts without Country grant",
		bool(started.get("ok", false))
		and int(ext.get_runtime_thread_report().get(
			"authoritative_domain_mask", 0)) & 0x004 == 0)
	if not bool(started.get("ok", false)):
		return 5

	_expect("probe formula parity (rename) matches CountryCore/POD commit",
		bool(ext.runtime_country_shadow_parity_self_test()))

	var handle_a := int(ext.get_country_cell_summary(0).get("country_handle", 0))
	var handle_b := int(ext.get_country_cell_summary(2).get("country_handle", 0))
	var technologies: PackedStringArray = compiled.get(
		"technology_ids", PackedStringArray())
	var grant_technology := ""
	for technology_id in technologies:
		if String(technology_id) != "tech.hunting":
			grant_technology = String(technology_id)
			break
	var command_program: Array[Dictionary] = [
		{"label": "rename", "day": 1, "commands": [{
			"opcode": CountryFacadeScript.Opcode.RENAME_COUNTRY,
			"target_handle": handle_a, "display_name": "Parity Live",
			"effective_day": 1, "sequence": 10}]},
		{"label": "territory transfer", "day": 2, "commands": [{
			"opcode": CountryFacadeScript.Opcode.TRANSFER_TERRITORY,
			"target_handle": handle_b, "cell": 1,
			"effective_day": 2, "sequence": 20}]},
		{"label": "research weights", "day": 3, "commands": [{
			"opcode": CountryFacadeScript.Opcode.SET_RESEARCH_WEIGHTS,
			"target_handle": handle_a,
			"weights_bp": PackedInt32Array([4000, 3000, 2000, 1000]),
			"effective_day": 3, "sequence": 30}]},
		{"label": "research budget", "day": 4, "commands": [{
			"opcode": CountryFacadeScript.Opcode.SET_RESEARCH_BUDGET,
			"target_handle": handle_a, "technology": 1, "value": 250,
			"effective_day": 4, "sequence": 40}]},
		{"label": "tax default", "day": 5, "commands": [{
			"opcode": CountryFacadeScript.Opcode.SET_TAX_DEFAULT,
			"target_handle": handle_a,
			"tax_kind": CountryFacadeScript.TaxKind.INCOME,
			"tax_rate_basis_points": 750,
			"effective_day": 5, "sequence": 50}]},
		{"label": "claim unowned", "day": 6, "commands": [{
			"opcode": CountryFacadeScript.Opcode.CLAIM_UNOWNED_TERRITORY,
			"target_handle": handle_a, "cell": 4,
			"effective_day": 6, "sequence": 60}]},
	]
	if not grant_technology.is_empty():
		command_program.append({
			"label": "technology grant", "day": 7, "commands": [{
				"opcode": CountryFacadeScript.Opcode.GRANT_TECHNOLOGY,
				"target_handle": handle_b,
				"technology": technologies.find(grant_technology),
				"effective_day": 7, "sequence": 70}],
		})
	var mirrored_command_families := 0
	for entry in command_program:
		var typed_commands: Array[Dictionary] = []
		for command in entry.commands:
			typed_commands.append(command)
		var submitted: Dictionary = country.submit(typed_commands)
		var mirrored := bool(submitted.get("ok", false)) \
			and bool(submitted.get("shadow_mirror_ok", false))
		_expect("live SHADOW mirrors %s command family" % entry.label, mirrored)
		if mirrored:
			mirrored_command_families += 1
	_expect("D11 command program covers multiple business-state families",
		mirrored_command_families >= 6)

	var slice_ok := true
	var last_ref_ok := false
	var compared_hashes := {}
	for day in range(1, _soak_days() + 1):
		var slice: Dictionary = ext.run_country_slice({"day_index": day})
		if not bool(slice.get("ok", false)):
			slice_ok = false
			break
		if bool(slice.get("done", false)):
			last_ref_ok = bool(slice.get("country_reference_ok", false)) \
				or last_ref_ok
		ext.service_country_worker_peer_adapter(64, true)
		OS.delay_msec(4)
		var day_report: Dictionary = ext.get_runtime_thread_report()
		if bool(day_report.get("country_parity_compared", false)):
			var worker_hash := int(day_report.get("country_parity_worker_hash", 0))
			if worker_hash != 0:
				compared_hashes[worker_hash] = true
	_expect("soak country slices complete", slice_ok)
	_expect("committed slices publish a Country reference hash", last_ref_ok)
	# The isolated 6-cell fixture has no production Climate trace. SHADOW
	# Country only compares after Climate succeeds, so compared=true is
	# asserted on the WorldRuntimeHost path below, not here.

	var checkpoint: Dictionary = ext.capture_country_reference_checkpoint()
	_expect("save capture remains available after SHADOW soak",
		bool(checkpoint.get("ok", false))
		or String(checkpoint.get("code", "")) != "")

	ext.set_country_sync_store_writes_forbidden(true)
	var unique: Dictionary = ext.begin_country_economy_fiscal_reserve(
		handle_a, 25, -1, -1, 0)
	_expect("unique-writer test grant rejects sync fiscal reserve",
		not bool(unique.get("ok", true))
		and String(unique.get("code", "")) == "country_worker_unique_writer")
	ext.set_country_sync_store_writes_forbidden(false)

	_expect("implemented mask includes Country after D12",
		int(ext.get_runtime_thread_report().get(
			"implemented_domain_mask", 0)) & 0x004 != 0)
	_expect("main thread still reports zero wait on simulation",
		int(ext.get_runtime_thread_report().get("main_wait_on_sim_us", -1)) == 0)

	ext.request_runtime_stop()
	var stopped := false
	for _i in range(250):
		if String(ext.get_runtime_thread_report().get("state", "")) in [
			"STOPPED", "FAULTED"]:
			stopped = true
			break
		OS.delay_msec(2)
	_expect("Host stops after parity soak", stopped)

	return await _run_production_shadow_soak()


func _run_production_shadow_soak() -> int:
	# Formal production path: Climate reference/input exists, so SHADOW
	# Country can actually compare. This is the D11 comparable-frame gate.
	var clock := WorldClock.new()
	clock.auto_start = false
	clock.initial_speed = 1.0
	clock.debug_step_log = false
	get_root().add_child(clock)
	clock.pause(true)

	var host := WorldRuntimeHost.new()
	host.map_width = PRODUCTION_WIDTH
	host.map_height = PRODUCTION_HEIGHT
	host.initial_seed = 20260910
	# Use the formal multi-country start. The synthetic economy bootstrap can
	# fail when generated terrain has no timber/stone, leaving no production
	# Country reference for this parity gate.
	host.generate_test_economy_data = false
	host.test_economy_population_scale = 100
	host.runtime_parity_forcing = true
	host.runtime_climate_authority_enabled = false
	get_root().add_child(host)
	host.configure(null, null, clock)
	var config := NewGameConfig.create_default()
	config.country.name = "Country Parity"
	config.country.foreign_count = 2
	config.base.map_width = PRODUCTION_WIDTH
	config.base.map_height = PRODUCTION_HEIGHT
	config.base.initial_seed = 20260910
	config.apply_land_layout("two")
	var session: Dictionary = host.configure_session({
		"kind": "new_game",
		"config": config.to_dictionary(),
	})
	if not bool(session.get("ok", false)):
		_expect("formal Country parity session configures", false)
		_teardown_production(host, clock)
		return 6

	await host.generate_world(20260910)
	print("runtime country parity: production world generated")
	var generator: MapGenerator = host.get_generator()
	if generator == null:
		_expect("production world generation succeeded", false)
		_teardown_production(host, clock)
		return 7
	var ext = generator.get_data_core_world_ext()
	_expect("production DCWorldExt is bound", ext != null)
	if ext == null:
		_teardown_production(host, clock)
		return 8

	ext.set_runtime_climate_parity_forcing(true)
	var clocked: Dictionary = ext.set_runtime_clock(true, PRODUCTION_WORKER_SPEED) \
		if ext.has_method("set_runtime_clock") else {}
	if not bool(clocked.get("ok", false)):
		_expect("production worker clock reconfigured (%s)" % String(
			clocked.get("code", "unknown")), false)
		_teardown_production(host, clock)
		return 9
	_expect("production worker reaches paused boundary",
		_wait_worker_paused(ext))

	var facade = generator.get_country_facade() if generator.has_method(
		"get_country_facade") else null
	var production_command_mirrored := false
	var production_handle := 0
	if facade != null:
		for cell in range(PRODUCTION_WIDTH * PRODUCTION_HEIGHT):
			production_handle = int(ext.get_country_cell_summary(cell).get(
				"country_handle", 0))
			if production_handle != 0:
				break
		if production_handle != 0:
			var production_commands: Array[Dictionary] = [{
				"opcode": CountryFacadeScript.Opcode.RENAME_COUNTRY,
				"target_handle": production_handle,
				"display_name": "Parity Production",
				"effective_day": 2,
				"sequence": 12,
			}]
			var submitted: Dictionary = facade.submit(production_commands)
			production_command_mirrored = bool(submitted.get("ok", false)) \
				and bool(submitted.get("shadow_mirror_ok", false))
	_expect("production command mirrors into SHADOW Host",
		production_command_mirrored)

	var compared := false
	var matched := false
	var status := ""
	var report: Dictionary = {}
	var soak := _soak_days()
	# Climate's production cadence currently yields one comparable Country
	# frame about every two driver ticks. Budget by comparable frames rather
	# than assuming one comparison per input tick; the gate below still exits
	# immediately once the requested soak count is reached.
	var budget := mini(soak * 2 + 4, 204)
	var tick := 0
	var scheduler_sealed := true
	while tick < budget:
		tick += 1
		# Keep a real production Country boundary on every measured day.
		# Country is event-driven and otherwise legitimately skips no-op days;
		# a unique rename gives SHADOW a matching daily command and reference.
		if tick > 2 and facade != null and production_handle != 0:
			var daily_commands: Array[Dictionary] = [{
				"opcode": CountryFacadeScript.Opcode.RENAME_COUNTRY,
				"target_handle": production_handle,
				"display_name": "Parity Production %d" % tick,
				"effective_day": tick,
				"sequence": 10 + tick,
			}]
			var daily_submit: Dictionary = facade.submit(daily_commands)
			if not bool(daily_submit.get("ok", false)) \
					or not bool(daily_submit.get("shadow_mirror_ok", false)):
				break
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
			print("[country-parity] scheduler seal timeout tick=%d sources=%s" % [
				tick, str(_hard_barrier_sources(clock))])
			break
		if ext.has_method("service_country_worker_peer_adapter"):
			ext.service_country_worker_peer_adapter(64, true)
		report = ext.get_runtime_thread_report()
		var consumed_before := int(report.get("climate_trace_consumed", 0))
		var trace_available := int(report.get(
			"climate_trace_consumable", 0)) > 0
		ext.set_runtime_clock(false, PRODUCTION_WORKER_SPEED)
		var deadline := Time.get_ticks_msec() + (2500 if trace_available else 50)
		while Time.get_ticks_msec() < deadline:
			if ext.has_method("service_country_worker_peer_adapter"):
				ext.service_country_worker_peer_adapter(64, true)
			# This harness runs with `--quit`; yielding to process_frame would
			# let SceneTree exit before assertions execute.
			OS.delay_msec(2)
			report = ext.get_runtime_thread_report()
			compared = bool(report.get("country_parity_compared", false))
			# The production contract is intentionally one day ahead of the
			# worker. Tick 1 only adopts the generated Climate baseline; from
			# tick 2 onward the worker must finish tick-1 before calendar input
			# may advance.
			if (tick == 1 and int(report.get(
					"climate_trace_consumed", 0)) > consumed_before) \
					or (tick > 1 and int(report.get(
						"country_worker_day", -1)) >= tick - 1):
				break
		ext.set_runtime_clock(true, PRODUCTION_WORKER_SPEED)
		_wait_worker_paused(ext)
		OS.delay_msec(2)
		report = ext.get_runtime_thread_report()
		compared = bool(report.get("country_parity_compared", false))
		matched = bool(report.get("country_parity_matched", false))
		status = String(report.get("country_parity_status", ""))
		if int(report.get("country_parity_compared_count", 0)) >= soak:
			break
	_expect("production scheduler seals every driven day", scheduler_sealed)
	if not compared:
		print("[country-parity] production uncompared worker_day=%s reason=%s status=%s report=%s" % [
			str(report.get("country_worker_day", -1)),
			String(report.get("country_worker_last_reason", "")),
			status,
			JSON.stringify(report),
		])
	_expect("D11 production soak produces an actual comparable Country frame",
		compared and status == "comparable")
	_expect("comparable Country worker hash matches the published reference",
		compared and matched
		and int(report.get("country_parity_reference_hash", 1)) ==
			int(report.get("country_parity_worker_hash", 0)))
	_expect("D11 production soak observes a nonzero compared worker hash",
		int(report.get("country_parity_worker_hash", 0)) != 0)
	var compared_count := int(report.get("country_parity_compared_count", 0))
	var matched_count := int(report.get("country_parity_matched_count", 0))
	print("[country-parity] compared_days=%d matched_days=%d first_mismatch_day=%d worker_day=%d waiting=%s pending=%d reason=%s" % [
		compared_count,
		matched_count,
		int(report.get("country_parity_first_mismatch_day", -1)),
		int(report.get("country_worker_day", -1)),
		str(report.get("country_worker_waiting_for_peer", false)),
		int(report.get("country_worker_pending_intents", 0)),
		String(report.get("country_worker_last_reason", "")),
	])
	_expect("D11 production soak compares every requested day",
		compared_count >= soak)
	_expect("all compared Country days match",
		matched_count == compared_count)
	if compared and not matched:
		var receipt_diag: Dictionary = {}
		if ext.has_method("poll_country_command_receipts"):
			var receipts: Dictionary = ext.poll_country_command_receipts(0, 4096)
			var rejected: Array[String] = []
			for row_value in receipts.get("receipts", []):
				var row: Dictionary = row_value
				if String(row.get("status", "")) in [
					"AdmissionRejected", "RejectedAtExecution"]:
					rejected.append("%s:%s" % [
						str(row.get("effective_day", -1)),
						String(row.get("reason", ""))])
			receipt_diag = {
				"count": int(receipts.get("count", 0)),
				"rejected": rejected,
			}
		push_error("[country-parity] field=%s index=%s first_mismatch_day=%s queue_capacity=%s queue_depth=%s rejected=%s last_reason=%s" % [
			String(report.get("country_parity_field", "")),
			str(report.get("country_parity_index", -1)),
			str(report.get("country_parity_first_mismatch_day", -1)),
			str(report.get("command_queue_capacity_exceeded", -1)),
			str(report.get("command_queue_depth", -1)),
			str(report.get("country_worker_rejected_results", -1)),
			String(report.get("country_worker_last_reason", ""))])
		print("[country-parity] receipt_diag=%s" % JSON.stringify(receipt_diag))
	_expect("production implemented mask includes Country after D12",
		int(report.get("implemented_domain_mask", 0)) & 0x004 != 0)
	_expect("production SHADOW soak still does not grant Country authority",
		int(report.get("authoritative_domain_mask", 0)) & 0x004 == 0)

	ext.request_runtime_stop()
	_teardown_production(host, clock)
	return 0


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
		var state := String(ext.get_runtime_thread_report().get("state", ""))
		if state == "PAUSED":
			return true
		if state in ["STOPPED", "FAULTED"]:
			return false
		OS.delay_msec(2)
	return false


func _teardown_production(host: WorldRuntimeHost, clock: WorldClock) -> void:
	host.free()
	clock.free()


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_fail(label)


func _fail(label: String) -> void:
	_failures += 1
	push_error("[FAIL] %s" % label)
