extends SceneTree

# CLM2 roundtrip at the GDScript layer (plan step P4).
#
# The C++ side already self-tests RuntimeClimateAuthority::serialize/deserialize,
# but nothing checked that a bundle carrying the CLIMATE section actually survives
# the GDScript save boundary. It did not: GameSaveCoordinator validated the PKSR
# header with `section_mask == 1`, while the host always writes at least
# RUNTIME_ENVELOPE|DOMAIN_POD and adds CLIMATE once the climate store has cells.
# That equality rejected every real bundle. Because the production path never
# starts a worker yet, the whole branch was unreachable and the defect stayed
# latent. This test pins the header contract, the validator, and the restore.

const MAP_WIDTH := 30
const MAP_HEIGHT := 20
const SEED := 20260906
const WORKER_SPEED_DAYS_PER_SECOND := 400.0
const MAX_BARRIER_PULSES_PER_DAY := 400
const WORKER_WAIT_TIMEOUT_MSEC := 5000
const WORKER_POLL_MSEC := 2
const MAX_SAVE_POLL_MSEC := 5000
const CLIMATE_DAYS_BEFORE_SAVE := 3

# The header contract under test. GameSaveCoordinator delegates its bundle
# validation to this script, which is also the only part of the save path that can
# be loaded outside a full scene tree (the coordinator itself reads the
# GameSettings autoload, which a `-s` script run does not register).
const Header = preload("res://scripts/game/pksr_bundle_header.gd")

const OFFSET_MAGIC := Header.OFFSET_MAGIC
const OFFSET_VERSION := Header.OFFSET_VERSION
const OFFSET_COMMITTED_DAY := Header.OFFSET_COMMITTED_DAY
const OFFSET_DOMAIN_ABI := Header.OFFSET_DOMAIN_ABI
const OFFSET_SECTION_MASK := Header.OFFSET_SECTION_MASK

const SECTION_RUNTIME_ENVELOPE := Header.SECTION_RUNTIME_ENVELOPE
const SECTION_DOMAIN_POD := Header.SECTION_DOMAIN_POD
const SECTION_CLIMATE := Header.SECTION_CLIMATE
const SECTION_COUNTRY := Header.SECTION_COUNTRY

var _checks := 0
var _failures := 0


func _init() -> void:
	var code := await _run()
	print("checks: %d, failures: %d" % [_checks, _failures])
	if _failures == 0:
		print("runtime climate save roundtrip: PASS")
	quit(code if code != 0 else (0 if _failures == 0 else 1))


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		printerr("FAIL: %s" % label)


func _run() -> int:
	print("=== CLM2 save roundtrip (GDScript layer) ===")
	if not ClassDB.class_exists("DCWorldExt"):
		_expect("DCWorldExt available", false)
		return 3

	var clock := WorldClock.new()
	clock.auto_start = false
	clock.initial_speed = 1.0
	clock.debug_step_log = false
	get_root().add_child(clock)
	clock.pause(true)

	var host := WorldRuntimeHost.new()
	host.map_width = MAP_WIDTH
	host.map_height = MAP_HEIGHT
	host.initial_seed = SEED
	host.generate_test_economy_data = true
	host.test_economy_population_scale = 0
	host.runtime_parity_forcing = true
	# This harness measures CLM2 bytes on the SHADOW trace path. ACTIVE
	# suppresses production Climate and would starve climate_pod_parity_compared.
	host.runtime_climate_authority_enabled = false
	get_root().add_child(host)
	host.configure(null, null, clock)

	await host.generate_world(SEED)
	var generator: MapGenerator = host.get_generator()
	if generator == null:
		_expect("world generation succeeded", false)
		return 4
	var ext = generator.get_data_core_world_ext()
	for method in ["start_runtime_worker", "request_runtime_save",
			"poll_runtime_save", "restore_runtime_bundle"]:
		_expect("%s is exported" % method, ext != null and ext.has_method(method))
	if _failures > 0:
		return 4

	# generate_world already started SHADOW. Reconfigure cadence and keep forcing.
	ext.set_runtime_climate_parity_forcing(true)
	var clocked: Dictionary = ext.set_runtime_clock(true, WORKER_SPEED_DAYS_PER_SECOND) \
		if ext.has_method("set_runtime_clock") else {}
	if not bool(clocked.get("ok", false)):
		_expect("worker clock reconfigured (%s)" % String(clocked.get("code", "unknown")), false)
		return 6

	var climate_days := _tick_until_climate_committed(ext, host, clock)
	_expect("the worker committed at least %d climate day(s)" % CLIMATE_DAYS_BEFORE_SAVE,
		climate_days >= CLIMATE_DAYS_BEFORE_SAVE)
	var pre_save_report: Dictionary = ext.get_runtime_thread_report()
	var pre_save_climate_hash := int(pre_save_report.get("climate_pod_state_hash", 0))
	_expect("the climate store reduced to a non-zero hash before saving",
		pre_save_climate_hash != 0)

	var polled := _capture_bundle(ext)
	if not bool(polled.get("ready", false)):
		_expect("save bundle became ready (%s)" % String(polled.get("code", "timeout")), false)
		_teardown(host, clock)
		return 7
	var bytes: PackedByteArray = polled.get("bytes", PackedByteArray())
	_check_header(bytes, polled)
	_check_coordinator_validator(bytes, polled)

	# restore_bundle refuses to run against a live worker, which is the same
	# ordering the load path uses: stop, restore, then start on the restored state.
	ext.set_runtime_climate_parity_forcing(false)
	ext.request_runtime_stop()
	_expect("the worker reached STOPPED before restore", _await_stopped(ext))
	_check_restore(ext, bytes, polled, pre_save_climate_hash)

	ext.request_runtime_stop()
	OS.delay_msec(100)
	_teardown(host, clock)
	await process_frame
	return 0


func _check_header(bytes: PackedByteArray, polled: Dictionary) -> void:
	_expect("bundle is long enough for the v2 header and tail", bytes.size() >= 2161)
	if bytes.size() < OFFSET_SECTION_MASK + 4:
		return
	_expect("bundle is PKSR",
		bytes.slice(OFFSET_MAGIC, OFFSET_MAGIC + 4).get_string_from_ascii() == "PKSR")
	_expect("bundle version is 2", int(bytes.decode_u32(OFFSET_VERSION)) == 2)
	var abi := int(bytes.decode_u32(OFFSET_DOMAIN_ABI))
	_expect("runtime domain ABI in the header matches the host report (%d)" % abi,
		abi == int(polled.get("runtime_domain_abi_version", -1)))
	var section_mask := int(bytes.decode_u32(OFFSET_SECTION_MASK))
	_expect("section_mask in the header matches the host report (0x%X)" % section_mask,
		section_mask == int(polled.get("section_mask", -1)))
	_expect("the runtime envelope section is present",
		(section_mask & SECTION_RUNTIME_ENVELOPE) != 0)
	_expect("the domain POD section is present",
		(section_mask & SECTION_DOMAIN_POD) != 0)
	# This is the point of the test: a live climate store must reach the save as
	# its own CLM2 section, and the old `section_mask == 1` check could not
	# possibly accept that.
	_expect("the CLIMATE section is present", (section_mask & SECTION_CLIMATE) != 0)
	_expect("the CLIMATE payload is non-empty", int(polled.get("climate_bytes", 0)) > 0)
	_expect("the Country section is present", (section_mask & SECTION_COUNTRY) != 0)
	_expect("the Country payload and canonical PKCN are non-empty",
		int(polled.get("country_bytes", 0)) > 0
		and not (polled.get("country_pkcn", PackedByteArray()) as PackedByteArray).is_empty())
	_expect("committed_day in the header is non-negative",
		bytes.decode_s64(OFFSET_COMMITTED_DAY) >= 0)
	print("  section_mask=0x%X climate_bytes=%d country_bytes=%d domain_pod_bytes=%d committed_day=%d" % [
		section_mask, int(polled.get("climate_bytes", 0)),
		int(polled.get("country_bytes", 0)),
		int(polled.get("domain_pod_bytes", 0)), bytes.decode_s64(OFFSET_COMMITTED_DAY)])


func _check_coordinator_validator(bytes: PackedByteArray, polled: Dictionary) -> void:
	_expect("the validator accepts a bundle carrying the CLIMATE section",
		Header.valid(bytes, polled))
	_expect("the validator accepts the bundle without a cross-check dictionary",
		Header.valid(bytes))
	_expect("the header helper reports the CLIMATE section",
		Header.has_climate_section(bytes))
	_expect("the header helper reports the Country section",
		Header.has_country_section(bytes))

	# The regression this test exists for: the coordinator used to require
	# `section_mask == 1`, which no bundle with a live climate store can satisfy.
	_expect("the old section_mask == 1 rule would have rejected this bundle",
		int(bytes.decode_u32(OFFSET_SECTION_MASK)) != 1)

	# An unknown section bit means the writer knows something this build does
	# not, so it has to be refused rather than partially restored.
	var unknown_section := bytes.duplicate()
	unknown_section.encode_u32(OFFSET_SECTION_MASK,
		int(bytes.decode_u32(OFFSET_SECTION_MASK)) | 0x100)
	_expect("the validator rejects an unknown section bit",
		not Header.valid(unknown_section))

	# Dropping the envelope bit leaves nothing to restore from.
	var no_envelope := bytes.duplicate()
	no_envelope.encode_u32(OFFSET_SECTION_MASK,
		int(bytes.decode_u32(OFFSET_SECTION_MASK)) & ~SECTION_RUNTIME_ENVELOPE)
	_expect("the validator rejects a bundle without the envelope section",
		not Header.valid(no_envelope))

	# A header that disagrees with the host's own report means codec drift.
	var drifted := polled.duplicate()
	drifted["section_mask"] = int(bytes.decode_u32(OFFSET_SECTION_MASK)) ^ SECTION_CLIMATE
	_expect("the validator rejects a header that contradicts the host report",
		not Header.valid(bytes, drifted))

	# PKSR v1 carried no section header and must not be guessed at.
	var v1 := bytes.duplicate()
	v1.encode_u32(OFFSET_VERSION, 1)
	_expect("the validator rejects PKSR v1", not Header.valid(v1))

	var short_bundle := bytes.slice(0, Header.MIN_BUNDLE_SIZE - 1)
	_expect("the validator rejects a bundle shorter than the v2 minimum",
		not Header.valid(short_bundle))


func _check_restore(ext, bytes: PackedByteArray, polled: Dictionary,
		pre_save_climate_hash: int) -> void:
	# A truncated tail and a corrupted CLM2 payload have to be caught here, not
	# adopted as climate state. Test the rejections before the accept, so the
	# host is not already holding a pending bundle when they run.
	var truncated := bytes.slice(0, bytes.size() - 24)
	var refused: Dictionary = ext.restore_runtime_bundle(truncated)
	_expect("restore rejects a truncated bundle (%s)" % String(refused.get("code", "")),
		not bool(refused.get("ok", true)))

	var corrupted := bytes.duplicate()
	var climate_probe := _find_climate_section_offset(corrupted)
	_expect("the CLM2 marker is locatable in the bundle tail", climate_probe >= 0)
	if climate_probe >= 0:
		corrupted[climate_probe] = (corrupted[climate_probe] + 1) & 0xFF
		var rejected: Dictionary = ext.restore_runtime_bundle(corrupted)
		_expect("restore rejects a corrupted CLIMATE payload (%s)" % String(
			rejected.get("code", "")), not bool(rejected.get("ok", true)))

	var restored: Dictionary = ext.restore_runtime_bundle(bytes)
	_expect("restore accepts the bundle (%s)" % String(restored.get("code", "")),
		bool(restored.get("ok", false)))
	if not bool(restored.get("ok", false)):
		return

	# The bundle is only adopted when the next start consumes it, so the actual
	# roundtrip assertion is what the worker reports after restarting on it.
	var restarted: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "SHADOW",
		"graph_coverage_complete": false,
		"speed_days_per_second": WORKER_SPEED_DAYS_PER_SECOND,
		"paused": true,
	})
	_expect("the worker restarts on the restored bundle (%s)" % String(
		restarted.get("code", "unknown")), bool(restarted.get("ok", false)))
	if not bool(restarted.get("ok", false)):
		return
	# start() returns before the worker has published its first report, so the
	# restored day is not observable yet. The outer report prefixes the host's
	# scalars, hence simulation_committed_day rather than committed_day.
	var saved_day := int(polled.get("committed_day", -2))
	var report: Dictionary = _await_restored_day(ext, saved_day)
	_expect("the restored worker resumes at the saved day (%d vs %d)" % [
			int(report.get("simulation_committed_day", -1)), saved_day],
		int(report.get("simulation_committed_day", -1)) == saved_day)
	_expect("the restored generation matches the saved one",
		int(report.get("generation", -1)) == int(polled.get("generation", -2)))
	_expect("the restored envelope state hash matches the saved one",
		int(report.get("state_hash", 0)) == int(polled.get("state_hash", -1)))

	# The worker republishes climate_pod_state_hash only after it plans a day, and
	# planning would advance the state this test is trying to compare. So take the
	# roundtrip at the byte level instead: saving the restored worker again, before
	# it advances, must reproduce the same CLM2 payload.
	var resaved := _capture_bundle(ext, 2)
	_expect("the restored worker can be saved again (%s)" % String(
		resaved.get("code", "timeout")), bool(resaved.get("ready", false)))
	if not bool(resaved.get("ready", false)):
		return
	var resaved_bytes: PackedByteArray = resaved.get("bytes", PackedByteArray())
	_expect("the re-save still carries the CLIMATE section",
		Header.has_climate_section(resaved_bytes))
	var original_climate := _climate_section(bytes)
	var roundtripped_climate := _climate_section(resaved_bytes)
	_expect("the CLM2 payload survives save -> restore -> save unchanged (%d vs %d bytes)" % [
			original_climate.size(), roundtripped_climate.size()],
		original_climate.size() > 0 and original_climate == roundtripped_climate)
	print("  CLM2 roundtrip: %d bytes, saved_day=%d, pre_save_climate_hash=%d" % [
		original_climate.size(), saved_day, pre_save_climate_hash])


# The first byte of the CLM2 payload, or -1. The section sits after the producer
# cursors and the DPD2 section, whose sizes are not fixed, so scan for the marker
# rather than computing an offset that would silently drift.
func _find_climate_section_offset(bytes: PackedByteArray) -> int:
	var marker := 0x324D4C43  # "CLM2" little-endian
	var cursor := OFFSET_SECTION_MASK + 4
	while cursor + 12 <= bytes.size():
		if int(bytes.decode_u32(cursor)) == marker:
			var size := int(bytes.decode_u32(cursor + 4))
			if size > 0 and cursor + 8 + size + 8 <= bytes.size():
				return cursor + 8
		cursor += 1
	return -1


func _climate_section(bytes: PackedByteArray) -> PackedByteArray:
	var offset := _find_climate_section_offset(bytes)
	if offset < 0:
		return PackedByteArray()
	var size := int(bytes.decode_u32(offset - 4))
	return bytes.slice(offset, offset + size)


func _capture_bundle(ext, request_id: int = 1) -> Dictionary:
	var requested: Dictionary = ext.request_runtime_save(request_id)
	if not bool(requested.get("ok", false)):
		return {"ready": false, "code": String(requested.get("code", "request_failed"))}
	var deadline := Time.get_ticks_msec() + MAX_SAVE_POLL_MSEC
	while Time.get_ticks_msec() < deadline:
		var polled: Dictionary = ext.poll_runtime_save(request_id)
		if bool(polled.get("ready", false)):
			return polled
		if not bool(polled.get("ok", true)):
			return {"ready": false, "code": String(polled.get("code", "poll_failed"))}
		OS.delay_msec(WORKER_POLL_MSEC)
	return {"ready": false, "code": "save_poll_timeout"}


# Ticks the production path and lets the worker consume one trace frame per tick
# until enough climate days have been compared. Returns the number of days that
# actually reached the climate store.
func _tick_until_climate_committed(ext, host: WorldRuntimeHost,
		clock: WorldClock) -> int:
	var committed := 0
	var tick := 0
	var budget := CLIMATE_DAYS_BEFORE_SAVE * 8 + 24
	while committed < CLIMATE_DAYS_BEFORE_SAVE and tick < budget:
		tick += 1
		var phase := clock.season_phase_for_day(tick)
		clock.current_day = float(tick)
		host.run_daily_tick(tick, phase)
		host.finish_daily_tick(0.0, {})
		var pulses := 0
		while _has_hard_barrier(clock) and pulses < MAX_BARRIER_PULSES_PER_DAY:
			clock.simulation_backpressure_pulse.emit(tick)
			pulses += 1
		var consumed_before := int(ext.get_runtime_thread_report().get(
			"climate_trace_consumed", 0))
		ext.set_runtime_clock(false, WORKER_SPEED_DAYS_PER_SECOND)
		var deadline := Time.get_ticks_msec() + WORKER_WAIT_TIMEOUT_MSEC
		while Time.get_ticks_msec() < deadline:
			if int(ext.get_runtime_thread_report().get("climate_trace_consumed", 0)) \
					> consumed_before:
				break
			OS.delay_msec(WORKER_POLL_MSEC)
		ext.set_runtime_clock(true, WORKER_SPEED_DAYS_PER_SECOND)
		OS.delay_msec(WORKER_POLL_MSEC)
		if bool(ext.get_runtime_thread_report().get("climate_pod_parity_compared", false)):
			committed += 1
	return committed


func _await_restored_day(ext, expected_day: int) -> Dictionary:
	var deadline := Time.get_ticks_msec() + WORKER_WAIT_TIMEOUT_MSEC
	var report: Dictionary = ext.get_runtime_thread_report()
	while Time.get_ticks_msec() < deadline:
		report = ext.get_runtime_thread_report()
		if int(report.get("simulation_committed_day", -1)) == expected_day:
			return report
		OS.delay_msec(WORKER_POLL_MSEC)
	return report


func _await_stopped(ext) -> bool:
	var deadline := Time.get_ticks_msec() + WORKER_WAIT_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if String(ext.get_runtime_thread_report().get("simulation_host_state", "")) \
				== "STOPPED":
			return true
		OS.delay_msec(WORKER_POLL_MSEC)
	return false


func _has_hard_barrier(clock: WorldClock) -> bool:
	return clock._simulation_backpressure_sources.has(&"country_day_barrier") \
		or clock._simulation_backpressure_sources.has(&"economy_day_barrier")


func _teardown(host: WorldRuntimeHost, clock: WorldClock) -> void:
	host.free()
	clock.free()
