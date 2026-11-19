extends "res://tests/runtime/background_daily_self_sufficiency_test.gd"

const LAST_DISPLAY_DAY := 6
var _inline := false


class InlineHost extends WorldRuntimeHost:
	func _native_daily_inline_requested() -> bool:
		return true


func _create_host() -> WorldRuntimeHost:
	return InlineHost.new() if _inline else WorldRuntimeHost.new()


func _run() -> void:
	await _run_world(false)
	_inline = true
	var daily := await _run_world(false)
	var skipped := await _run_world(true)
	_expect("skipped display reads converge for every resource cell",
		daily.get("resources", []) == skipped.get("resources", []) and daily.has("resources"))
	_expect("species display takes the latest complete bitmap",
		daily.get("occupancy", []) == skipped.get("occupancy", []) and daily.has("occupancy"))
	_expect("the pending patch contains earlier-only cells",
		int(skipped.get("cells", 0)) > int(daily.get("cells", 0)))
	print("ECOLOGY_DISPLAY_PATCH=" + JSON.stringify({
		"last_day": LAST_DISPLAY_DAY, "daily_last_cells": daily.get("cells"),
		"skipped_cells": skipped.get("cells"),
	}))
	_finish()


func _sample_world(host: WorldRuntimeHost, clock: WorldClock, skip_display: bool) -> Dictionary:
	if not _inline:
		await _verify_running_configuration_boundary(host, clock)
		await _verify_display_failure_does_not_hold_tail(host, clock)
		return {}
	host.set_process(false)
	var ext: Object = host.get_generator().get_data_core_world_ext()
	_expect("inline fixture uses the formal executor", bool(ext.get_runtime_thread_report().get("native_daily_inline", false)))
	var patch := {}
	for day in range(1, LAST_DISPLAY_DAY + 1):
		if not _direct_commit(host, clock, day):
			return {}
		if not skip_display or day == 1 or day == LAST_DISPLAY_DAY:
			patch = ext.apply_runtime_economy_resource_writeback()
			_expect("resource display takes the accumulated rows", bool(patch.get("applied", false)))
			_expect("species display installs a whole bitmap", bool(ext.apply_runtime_species_writeback().get("applied", false)))
	var map := host.current_map()
	var resources: Array = []
	for profile in ResourceProfileRegistry.ordered():
		resources.append(map.get(ResourceProfileRegistry.reserve_map_field(profile)))
		var slot := ResourceProfileRegistry.extra_change_cpp_name(profile)
		resources.append(ext.snapshot_f32(ext.component_id(slot)))
		_expect("resource change lane covers the map", (resources[-1] as PackedFloat32Array).size() == map.cell_count())
	var occupancy := map.bio_occupancy_bits_arr.duplicate()
	_expect("a second take is empty", not bool(ext.apply_runtime_economy_resource_writeback().get("applied", true)))
	if skip_display:
		await _verify_in_place_restore(host, clock, ext, occupancy)
	return {"resources": resources, "occupancy": occupancy, "cells": patch.get("cells", 0)}


func _verify_running_configuration_boundary(host: WorldRuntimeHost, clock: WorldClock) -> void:
	var economy = host.get_generator().get_economy_facade()
	var ext: Object = economy.world_ext()
	clock.set_speed(SPEED)
	_publish_day(host, clock, 1)
	var settled := await _wait_golden_read_boundary(host, economy, 1)
	_expect("the first worker day is settled and idle", settled)
	if not settled:
		return
	var before: Dictionary = ext.get_runtime_thread_report()
	var result: Dictionary = ext.configure_economy_natural_resources(ResourceProfileRegistry.build_pass_knobs())
	_expect("running resource reconfiguration is refused", not bool(result.get("ok", true))
		and result.get("code") == "natural_resource_configuration_requires_stopped_executor")
	var capture: Dictionary = ext.capture_economy_ecp2(0)
	_expect("direct ECP2 capture is refused", not bool(capture.get("ok", true))
		and capture.get("reason") == "economy_ecp2_requires_stopped_executor")
	ext.set_runtime_clock(true, SPEED)
	var archive := await _capture_native_save(ext)
	var ecp2: PackedByteArray = archive.get("economy_ecp2", PackedByteArray())
	_expect("the executor can freeze an ECP2 while running", not ecp2.is_empty())
	var restore: Dictionary = ext.restore_economy_ecp2(ecp2)
	_expect("direct ECP2 restore is refused even with a valid archive", not bool(restore.get("ok", true))
		and restore.get("reason") == "economy_ecp2_requires_stopped_executor")
	ext.set_runtime_clock(false, SPEED)
	_publish_day(host, clock, 2)
	settled = await _wait_golden_read_boundary(host, economy, 2)
	var after: Dictionary = ext.get_runtime_thread_report()
	_expect("the second day commits after refused calls", settled and after.get("fault_code", "missing") == "")
	print("ECOLOGY_RUNNING_BOUNDARY=" + JSON.stringify({
		"before_day": before.get("simulation_committed_day"),
		"before_inflight": before.get("worker_day_inflight"),
		"config": result, "ecp2_capture": capture, "ecp2_restore": restore,
		"after_day": after.get("simulation_committed_day"), "fault": after.get("fault_code"),
	}))


func _direct_commit(host: WorldRuntimeHost, clock: WorldClock, day: int) -> bool:
	var generator := host.get_generator()
	var ext: Object = generator.get_data_core_world_ext()
	clock.current_day = float(day + 1)
	host._apply_climate_writeback_if_authoritative(generator.get_runtime_control_state())
	var capture: Dictionary = generator.publish_environment_through(
		day, clock.season_phase_for_day(day + 1), MapGenerator.ENV_CALLSITE_INLINE_DAY)
	_expect("direct environment is available on day %d" % day, bool(capture.get("ok", false)))
	var result: Dictionary = ext.run_native_daily_inline_day()
	var committed := bool(result.get("ok", false)) and int(result.get("committed_day", -1)) == day
	_expect("directly driven inline commit reaches day %d" % day, committed)
	if not committed:
		print("ECOLOGY_DIRECT_COMMIT=" + JSON.stringify({"capture": capture, "result": result}))
	return committed


func _verify_display_failure_does_not_hold_tail(host: WorldRuntimeHost, clock: WorldClock) -> void:
	var economy = host.get_generator().get_economy_facade()
	var ext: Object = economy.world_ext()
	var map := host.current_map()
	var keys := PackedStringArray(["cell_res_pasture_reserve", "cell_bio_occupancy_bits"])
	# Damage just the installation destinations. Vision still has a valid
	# previous MapData view, and the executor owns both authoritative columns.
	var old_reserve := map.res_pasture_reserve_arr
	var old_occupancy := map.bio_occupancy_bits_arr
	map.res_pasture_reserve_arr = PackedFloat32Array()
	map.bio_occupancy_bits_arr = PackedInt32Array()
	ext.refresh_slots_from_map_keys(keys)
	map.res_pasture_reserve_arr = old_reserve
	map.bio_occupancy_bits_arr = old_occupancy
	_publish_day(host, clock, 3)
	_expect("display installation failure leaves the day tail acknowledged",
		await _wait_golden_read_boundary(host, economy, 3))
	var resources: Dictionary = ext.apply_runtime_economy_resource_writeback()
	var species: Dictionary = ext.apply_runtime_species_writeback()
	_expect("both display writes actually failed", resources.get("code") == "resource_writeback_slot_shape_invalid"
		and species.get("reason") == "bio_writeback_slot_shape_invalid")
	ext.refresh_slots_from_map_keys(keys)
	_expect("an unavailable display destination does not discard a pending resource patch",
		bool(ext.apply_runtime_economy_resource_writeback().get("applied", false)))
	_expect("the latest species bitmap is still available",
		bool(ext.apply_runtime_species_writeback().get("applied", false)))
	print("ECOLOGY_DISPLAY_FAILURE=" + JSON.stringify({"resources": resources, "species": species,
		"acknowledged_day": host._runtime_tail_completed_day}))


func _capture_native_save(ext: Object) -> Dictionary:
	var request: Dictionary = ext.request_runtime_save(901)
	_expect("executor boundary accepts a checkpoint", bool(request.get("ok", false)))
	for _slice in range(MAX_SLICES_PER_DAY):
		var result: Dictionary = ext.poll_runtime_save(901)
		if bool(result.get("ready", false)) or not bool(result.get("ok", false)):
			return result
		await process_frame
	return {}


func _verify_in_place_restore(host: WorldRuntimeHost, clock: WorldClock, ext: Object,
		old_occupancy: PackedInt32Array) -> void:
	var archive := await _capture_native_save(ext)
	var bytes: PackedByteArray = archive.get("bytes", PackedByteArray())
	_expect("same-instance test captured a runtime archive", bool(archive.get("ready", false)) and not bytes.is_empty())
	if bytes.is_empty():
		return
	var ecp2: PackedByteArray = archive.get("economy_ecp2", PackedByteArray())
	var map := host.current_map()
	var blank := PackedInt32Array()
	blank.resize(old_occupancy.size())
	_expect("the reused instance has a different bitmap", old_occupancy != blank)
	ext.request_runtime_stop()
	_expect("inline executor is stopped", bool(ext.get_runtime_thread_report().get("simulation_executor_exited", false)))
	# Install the restored geography column exactly where the world provider does.
	map.bio_occupancy_bits_arr = blank
	ext.refresh_slots_from_map_keys(PackedStringArray(["cell_bio_occupancy_bits"]))
	var restored: Dictionary = ext.restore_runtime_bundle(bytes, ecp2)
	_expect("same native instance accepts a true restore", bool(restored.get("ok", false)))
	var country: Dictionary = ext.restore_country_runtime_checkpoint(archive.get("country_pkcn", PackedByteArray()))
	_expect("same native instance restores PKCN first", bool(country.get("ok", false)))
	_expect("same native instance restores ECP2 after PKCN", bool(ext.restore_economy_ecp2(ecp2).get("ok", false)))
	var started: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "ACTIVE", "graph_coverage_complete": true,
		"native_daily_inline": true, "authoritative_domain_mask": 0xFFF,
		"day": LAST_DISPLAY_DAY, "paused": true, "speed_days_per_second": 0.0,
	})
	_expect("same native instance restarts from the archive", bool(started.get("ok", false)))
	if not bool(started.get("ok", false)):
		print("ECOLOGY_SAME_INSTANCE_START=" + JSON.stringify(started))
		return
	if _direct_commit(host, clock, LAST_DISPLAY_DAY + 1):
		var result: Dictionary = ext.apply_runtime_species_writeback()
		_expect("restored geography replaces the old bitmap on first commit",
			bool(result.get("applied", false)) and map.bio_occupancy_bits_arr == blank)
		print("ECOLOGY_IN_PLACE_RESTORE=" + JSON.stringify({
			"old_sha256": _digest(old_occupancy.to_byte_array().hex_encode()),
			"blank": map.bio_occupancy_bits_arr == blank, "day": LAST_DISPLAY_DAY + 1,
		}))
