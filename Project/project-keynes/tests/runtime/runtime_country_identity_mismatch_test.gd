extends SceneTree

## P1-a: a save whose COUNTRY bytes came from a different archive than its ECONOMY
## bytes must FAIL to start the worker.
##
## Why this test exists: on the worker-start path Economy is applied BEFORE Country
## (`native_simulation_host.cpp`), so the archive's `country_generation`/`country_hash`
## cannot match the live Country runtime yet. The R-4 fix DEFERS that comparison instead
## of dropping it: the expected identity is recorded during the apply and verified again
## once the PKCN checkpoint is installed. This test is the thing that proves the second
## half runs. Without it, pairing A's Country with B's Economy loads silently -- the
## exact corruption the original gate existed to catch.
##
## Structure: capture two independent archives whose countries differ, replace the
## country identity recorded by A's valid ECP2 payload with B's identity, and require
## the worker start to fail. A positive control (A's own bundle) runs first, so
## "the splice was rejected" cannot pass just because every restore fails.
##
## Run: godot --headless --path Project/project-keynes \
##        -s tests/runtime/runtime_country_identity_mismatch_test.gd

const CountryTestHelper = preload("res://tests/country/country_test_helper.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")
const ModifierFacadeScript = preload("res://scripts/modifier/modifier_facade.gd")

var _checks := 0
var _failures := 0


func _init() -> void:
	call_deferred("_run_and_finish")


func _run_and_finish() -> void:
	_run()
	print("runtime country identity mismatch: %d checks, %d failures" % [
		_checks, _failures])
	print("[exit] ok")
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt unavailable")
		return
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	if not _require("economy catalog compiles", bool(compiled.get("ok", false)),
			String(compiled.get("reason", ""))):
		return
	var save_a := _capture_save(compiled, 20260909, 3, 1, "Archive A")
	if save_a.is_empty():
		return
	var save_b := _capture_save(compiled, 20260910, 4, 1, "Archive B")
	if save_b.is_empty():
		return
	var a_bundle: PackedByteArray = save_a.get("bundle", PackedByteArray())
	var a_country: PackedByteArray = save_a.get(
		"country_section", PackedByteArray())
	var b_country: PackedByteArray = save_b.get(
		"country_section", PackedByteArray())
	var a_ecp2: PackedByteArray = save_a.get(
		"economy_ecp2", PackedByteArray())
	var a_generation := int(save_a.get("country_section_generation", 0))
	var a_hash := int(save_a.get("country_section_hash", 0))
	var b_generation := int(save_b.get("country_section_generation", 0))
	var b_hash := int(save_b.get("country_section_hash", 0))
	_expect("archive A carries a valid CPD2 section (%d bytes)" %
		a_country.size(), _valid_country_section(a_country), str(a_country.size()))
	_expect("archive B carries a different valid CPD2 section (%d bytes, %d vs %d)" %
		[b_country.size(), a_country.size(), b_country.size()],
		_valid_country_section(b_country) and b_country != a_country,
		"identical=%s" % str(a_country == b_country))
	if a_bundle.is_empty() or not _valid_country_section(a_country) or \
			not _valid_country_section(b_country) or b_country == a_country or \
			a_ecp2.is_empty() or a_generation == 0 or a_hash == 0 or \
			b_generation == 0 or b_hash == 0:
		return
	# POSITIVE CONTROL. Without it, "the mismatch failed" would also hold if restore
	# were broken for every input.
	var bound_ecp2 := _rewrite_ecp2_country_identity(
		a_ecp2, a_generation, a_hash)
	if not _require("A's ECP2 payload validates for identity rewriting",
			not bound_ecp2.is_empty(), "ECP2 rewrite failed"):
		return
	var control_bundle := _splice_economy(a_bundle, bound_ecp2)
	if not _require("A's economy identity binds to its country checkpoint",
			not control_bundle.is_empty(), "ECP2 identity splice failed"):
		return
	var control := _restore_and_start(compiled, control_bundle, save_a)
	_expect("control: a matching archive starts the worker (code=%s)" % String(
			control.get("code", "ok")), bool(control.get("ok", false)),
		_brief(control))
	if bool(control.get("ok", false)):
		_expect("control: the restored worker commits real days",
			_commit_restored_days(control.get("ext"),
				int(save_a.get("cell_count", 0))),
			_brief(control.get("ext").get_runtime_thread_report()))
	# THE TEST: A's valid CPD2 paired with an ECP2 header that records B's Country
	# identity. Mutating the ECP2 payload and repairing its envelope checksums reaches
	# the deferred Country gate instead of failing early on a corrupt bundle.
	var foreign_ecp2 := _rewrite_ecp2_country_identity(
		bound_ecp2, b_generation, b_hash)
	if not _require("the foreign ECP2 identity rewrites validly",
			not foreign_ecp2.is_empty(), "ECP2 rewrite failed"):
		return
	var swapped := _splice_economy(a_bundle, foreign_ecp2)
	if not _require("the foreign economy identity splices into A's bundle",
			not swapped.is_empty(), "ECP2 identity splice failed"):
		return
	# The bundle still carries A's CPD2 and PKCN; only ECP2's expected Country identity
	# is foreign. A's checkpoint must therefore install successfully and then fail the
	# deferred identity comparison.
	var mismatched := _restore_and_start(compiled, swapped, save_a)
	_expect("mismatched archive is REJECTED (ok=%s code=%s)" % [
			str(mismatched.get("ok", false)), String(mismatched.get("code", ""))],
		not bool(mismatched.get("ok", false)) and String(
			mismatched.get("code", "")).begins_with(
				"economy_country_identity_mismatch"), _brief(mismatched))
	# The failure must be the identity check. A decode error would also "fail", and
	# this test would then stop protecting anything the day the bundle format moves.
	var code := String(mismatched.get("code", ""))
	_expect("rejection names the deferred country identity (code=%s)" % code,
		code.begins_with("economy_country_identity_mismatch"), code)


## Builds a complete archive through the same production configure sequence the IDP2
## roundtrip test uses, runs `days` committed economy days, then captures the bundle.
func _capture_save(compiled: Dictionary, seed: int, days: int,
		cell_count: int, country_name: String) -> Dictionary:
	var native_catalog := compiled.duplicate(true)
	native_catalog.erase("ok")
	var ext: Object = DCWorldExt.new()
	ext.create_entities(cell_count)
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_weather_precip", &"cell_snow_cover",
			&"cell_weather_intensity", &"cell_elevation"]:
		var float_slot: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(float_slot, 0, PackedFloat32Array([0.5]))
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation",
			&"cell_is_water", &"cell_has_river"]:
		var byte_slot: int = ext.register_component(slot_name, 2, 1, false)
		ext.write_u8_range(byte_slot, 0, PackedByteArray([0]))
	for slot_name in native_catalog.building_resource_reserve_slots:
		var reserve_slot: int = ext.register_component(
			StringName(slot_name), 0, 1, false)
		ext.write_f32_range(reserve_slot, 0, PackedFloat32Array([1000000.0]))
	for slot_name in native_catalog.building_resource_extra_slots:
		var extra_slot: int = ext.register_component(
			StringName(slot_name), 0, 1, false)
		ext.write_f32_range(extra_slot, 0, PackedFloat32Array([0.0]))
	if not _require("seed %d: country configures (%d countries)" % [
			seed, cell_count],
			CountryTestHelper.configure_all_technologies(
				ext, native_catalog, cell_count, seed), ""):
		return {}
	var modifier := ModifierFacadeScript.new()
	if not _require("seed %d: modifier configures" % seed,
			bool(modifier.configure(ext, 1).get("ok", false)), ""):
		return {}
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.market_runtime_mode = "ACTIVE"
	profile.market_cycle_days = 1
	profile.worker_enabled = false
	if not _require("seed %d: economy configures" % seed,
			bool(ext.configure_economy(native_catalog, profile, cell_count, seed).get("ok", false)),
			""):
		return {}
	var signatures: PackedStringArray = compiled.signature_keys
	var selected := PackedInt32Array([
		signatures.find("hunter|default"),
		signatures.find("sharecropper|default"),
		signatures.find("corvee_worker|default"),
		signatures.find("scholar|default"),
	])
	if not _require("seed %d: political-class signatures exist" % seed,
			selected.find(-1) == -1, str(selected)):
		return {}
	if not _require("seed %d: economy bootstraps" % seed, bool(ext.bootstrap_economy({
			"cell_indices": PackedInt32Array([0, 0, 0, 0]),
			"signature_ids": selected,
			"population": PackedInt64Array([100, 100, 100, 100]),
			"funds": PackedInt64Array([0, 0, 0, 0]),
		}, {}).get("ok", false)), ""):
		return {}
	var country_handle := int(ext.get_country_cell_summary(0).get(
		"country_handle", 0))
	if not _require("seed %d: country handle resolves" % seed,
			country_handle != 0, str(country_handle)):
		return {}
	if not _require("seed %d: country rename queues" % seed,
			bool(ext.submit_country_commands(_country_commands([{
				"opcode": 2, "day": 0, "sequence": 1,
				"handle": country_handle, "name": country_name,
			}])).get("ok", false)), ""):
		return {}
	if not _require("seed %d: country rename commits" % seed,
			bool(ext.run_country_slice({"day_index": 0}).get("ok", false)), ""):
		return {}
	if not _require("seed %d: initial Country snapshot publishes" % seed,
			bool(ext.capture_country_runtime_snapshot().get("ok", false)),
			"publish_country_snapshot"):
		return {}
	ext.capture_country_pod_catalog()
	# Advance a different number of days per archive so the country generation and
	# state hash genuinely disagree. `capture_country_runtime_snapshot` is re-called
	# afterwards: the checkpoint the bundle carries is the LAST published one, so
	# capturing only at the start would ship the bootstrapped identity for both archives
	# -- which is exactly what made the first version of this test vacuous (identical
	# 38037-byte country sections).
	var days_ran := 0
	for day in range(days):
		if not _run_economy(ext, day):
			break
		days_ran += 1
	ext.capture_country_pod_catalog()
	var generation_after := int(ext.get_country_state_hash())
	_expect("seed %d: the country actually advanced (%d day(s), hash=%d)" % [
			seed, days_ran, generation_after], days_ran > 0,
		"no economy day completed, so this archive cannot differ from another")
	var effect_catalog: Resource = EffectDomainCatalogScript.build()
	if effect_catalog == null:
		_fail("seed %d: Effect catalog unavailable" % seed)
		return {}
	ext.configure_effects(effect_catalog.compile_native_catalog())
	var ideology_catalog: Resource = IdeologyCatalogScript.load_default()
	var ideology_ir: Dictionary = ideology_catalog.compile_native_catalog(
		native_catalog, native_catalog)
	if bool(ideology_ir.get("ok", false)):
		ideology_ir.erase("ok")
		ext.configure_ideologies(ideology_ir)
	# The pod only becomes ready once it has an opinion snapshot to plan with; without it
	# the save request answers `runtime_save_failed`, because the IDP2 section is written
	# from the ideology pod. The roundtrip test performs the same two calls before
	# saving, so this mirrors a proven sequence rather than guessing.
	if ext.has_method("get_country_class_opinion_snapshot"):
		ext.get_country_class_opinion_snapshot()
	if ext.has_method("publish_ideology_worker_inputs"):
		ext.publish_ideology_worker_inputs()
	# The save path needs a STARTED worker: `request_runtime_save` answers
	# `save_request_busy` when no worker is running (`request_save` returns false and
	# the code falls through to that branch). SHADOW at speed 0 keeps the worker alive
	# without letting it advance the world between capture and save.
	var started: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "SHADOW",
		"graph_coverage_complete": false,
		"day": 0,
		"speed_days_per_second": 0.0,
		"paused": false,
	})
	if not _require("seed %d: SHADOW worker starts for capture" % seed,
			bool(started.get("ok", false)), _brief(started)):
		return {}
	# The save path answers `runtime_save_failed` until the worker's pods are ready --
	# the IDP2 section is written from the ideology pod, so the request is refused while
	# that pod is still bootstrapping. The roundtrip test waits for exactly this.
	var ready := false
	var ready_deadline := Time.get_ticks_msec() + 8000
	while Time.get_ticks_msec() < ready_deadline:
		if bool(ext.get_runtime_thread_report().get("ideology_pod_ready", false)):
			ready = true
			break
		OS.delay_msec(5)
	if not _require("seed %d: worker pods become ready before the save" % seed, ready,
			"ideology_pod_ready stayed false"):
		return {}
	var captured := _request_save(ext, seed)
	if not bool(captured.get("ready", false)):
		_fail("seed %d: save capture failed (%s)" % [seed, _brief(captured)])
		return {}
	var bundle: PackedByteArray = captured.get("bytes", PackedByteArray())
	var country_section := _country_section(bundle)
	var country_pkcn: PackedByteArray = captured.get(
		"country_pkcn", PackedByteArray())
	if not _require("seed %d: save provider returns the captured Country PKCN" % seed,
			not country_pkcn.is_empty(), _brief(captured)):
		return {}
	return {
		"bundle": bundle,
		"country_section": country_section,
		"country_section_generation": int(country_section.decode_u64(32)),
		"country_section_hash": int(country_section.decode_u64(48)),
		"country_pkcn": country_pkcn,
		"economy_ecp2": captured.get("economy_ecp2", PackedByteArray()),
		"entity_count": cell_count,
		"cell_count": cell_count,
		"seed": seed,
	}


## Requests a runtime save and polls until it is ready.
##
## `capture_runtime_bundle` does not exist on DCWorldExt -- the save path is the
## request/poll pair the IDP2 roundtrip test uses, which is also the production shape.
func _request_save(ext: Object, request_id: int) -> Dictionary:
	var request: Dictionary = ext.request_runtime_save(request_id)
	# `save_request_busy` means a previous request is still outstanding (the save path
	# is asynchronous). Wait for it to drain instead of failing: this test captures two
	# archives back to back.
	var busy_deadline := Time.get_ticks_msec() + 8000
	while String(request.get("code", "")) == "save_request_busy" and \
			Time.get_ticks_msec() < busy_deadline:
		OS.delay_msec(20)
		ext.poll_runtime_save(request_id)
		request = ext.request_runtime_save(request_id)
	if not bool(request.get("pending", false)):
		return request
	var saved: Dictionary = {}
	var deadline := Time.get_ticks_msec() + 8000
	while Time.get_ticks_msec() < deadline:
		saved = ext.poll_runtime_save(request_id)
		if bool(saved.get("ready", false)):
			return saved
		OS.delay_msec(5)
	return saved


## Restores `bundle` into a fresh runtime and starts the worker.
func _restore_and_start(compiled: Dictionary, bundle: PackedByteArray,
		fixture: Dictionary) -> Dictionary:
	if bundle.is_empty():
		return {"ok": false, "code": "empty_bundle"}
	var native_catalog := compiled.duplicate(true)
	native_catalog.erase("ok")
	var entity_count := int(fixture.get("entity_count", 0))
	var cell_count := int(fixture.get("cell_count", 0))
	var seed := int(fixture.get("seed", 0))
	if entity_count <= 0 or cell_count <= 0 or seed == 0:
		return {"ok": false, "code": "restore_fixture_metadata_invalid"}
	var ext: Object = DCWorldExt.new()
	ext.create_entities(entity_count)
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_weather_precip", &"cell_snow_cover",
			&"cell_weather_intensity", &"cell_elevation"]:
		var float_slot: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(float_slot, 0, PackedFloat32Array([0.5]))
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation",
			&"cell_is_water", &"cell_has_river"]:
		var byte_slot: int = ext.register_component(slot_name, 2, 1, false)
		ext.write_u8_range(byte_slot, 0, PackedByteArray([0]))
	for slot_name in native_catalog.building_resource_reserve_slots:
		var reserve_slot: int = ext.register_component(
			StringName(slot_name), 0, 1, false)
		ext.write_f32_range(reserve_slot, 0, PackedFloat32Array([1000000.0]))
	for slot_name in native_catalog.building_resource_extra_slots:
		var extra_slot: int = ext.register_component(
			StringName(slot_name), 0, 1, false)
		ext.write_f32_range(extra_slot, 0, PackedFloat32Array([0.0]))
	var reserved_slot: int = ext.register_component(&"cell_country_slot", 1, 1, false)
	ext.write_i32_range(reserved_slot, 0, PackedInt32Array([-1]))
	if not CountryTestHelper.configure_all_technologies(
			ext, native_catalog, cell_count, seed):
		return {"ok": false, "code": "restore_country_configure_failed"}
	if not bool(ext.capture_country_runtime_snapshot().get("ok", false)):
		return {"ok": false, "code": "restore_country_snapshot_publish_failed"}
	ext.capture_country_pod_catalog()
	var modifier := ModifierFacadeScript.new()
	modifier.configure(ext, 1)
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.market_runtime_mode = "ACTIVE"
	profile.market_cycle_days = 1
	profile.worker_enabled = false
	if not bool(ext.configure_economy(
			native_catalog, profile, cell_count, seed).get("ok", false)):
		return {"ok": false, "code": "restore_economy_configure_failed"}
	var effect_catalog: Resource = EffectDomainCatalogScript.build()
	if effect_catalog != null:
		ext.configure_effects(effect_catalog.compile_native_catalog())
	var ideology_catalog: Resource = IdeologyCatalogScript.load_default()
	var ideology_ir: Dictionary = ideology_catalog.compile_native_catalog(
		native_catalog, native_catalog)
	if bool(ideology_ir.get("ok", false)):
		ideology_ir.erase("ok")
		ext.configure_ideologies(ideology_ir)
	var restored: Dictionary = ext.restore_runtime_bundle(bundle)
	if not bool(restored.get("ok", false)):
		return {"ok": false, "code": String(restored.get("code", "restore_failed"))}
	var country_restored: Dictionary = ext.restore_country_runtime_checkpoint(
		fixture.get("country_pkcn", PackedByteArray()))
	if not bool(country_restored.get("ok", false)):
		return {"ok": false, "code": String(country_restored.get("code",
			"restore_country_failed"))}
	# NativeSimulationHost bootstraps the worker POD from its published Country
	# snapshot, not directly from the PKCN payload restored above. Recapture after
	# the restore so the ACTIVE control starts from the saved generation/day.
	if not bool(ext.capture_country_runtime_snapshot().get("ok", false)):
		return {"ok": false, "code": "restore_country_snapshot_republish_failed"}
	ext.capture_country_pod_catalog()
	var restore_day := int(country_restored.get("committed_day", -1))
	if restore_day < 0:
		return {"ok": false, "code": "restore_country_day_invalid"}
	var terrain := PackedByteArray()
	terrain.resize(cell_count)
	terrain.fill(1)
	var temperature := PackedFloat32Array()
	temperature.resize(cell_count)
	temperature.fill(15.0)
	var moisture := PackedFloat32Array()
	moisture.resize(cell_count)
	moisture.fill(0.5)
	var neighbor_offsets := PackedInt32Array()
	neighbor_offsets.resize(cell_count + 1)
	var inputs: Dictionary = ext.capture_runtime_inputs({
		"generation": 1,
		"day": restore_day,
		"terrain": terrain,
		"neighbor_offsets": neighbor_offsets,
		"neighbor_indices": PackedInt32Array(),
		"cell_temp": temperature,
		"cell_moisture": moisture,
		"cell_plant_available_water": moisture,
	})
	if not bool(inputs.get("ok", false)):
		return {"ok": false, "code": String(inputs.get("code",
			"restore_runtime_inputs_failed"))}
	if ext.configure_runtime_graph({
			"enabled": true,
			"day": restore_day,
		}) != 0:
		return {"ok": false, "code": "restore_runtime_graph_failed"}
	var started: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "ACTIVE",
		"graph_coverage_complete": true,
		# Climate is deliberately not in this focused mask: this fixture has no
		# WorldRuntimeHost to publish its OF-reference trace. Country + Economy
		# prove the restore can run; the mismatch gate is checked synchronously
		# while the restore bundle is consumed.
		"authoritative_domain_mask": 0x104,
		"economy_production_writer": "compact_slice",
		"day": restore_day,
		"speed_days_per_second": 4.0,
		"paused": false,
	})
	var out := started.duplicate(true)
	if not bool(out.get("ok", false)):
		var thread_report: Dictionary = ext.get_runtime_thread_report()
		out["code"] = String(thread_report.get("fault_code",
			started.get("code", started.get("reason",
				"runtime_worker_start_failed"))))
	out["ok"] = bool(started.get("ok", false))
	out["ext"] = ext
	return out


func _run_economy(ext: Object, day: int) -> bool:
	if not ext.has_method("run_economy_slice"):
		return false
	for slice in range(2048):
		var result: Dictionary = ext.run_economy_slice({
			"day_index": day, "tick_index": day * 1000 + slice})
		if bool(result.get("done", false)):
			return true
		if bool(result.get("fatal", false)):
			return false
	return false


## Replace A's ECP2 payload with one that records a different Country identity and
## repair both PKSR checksums.
func _splice_economy(bundle: PackedByteArray,
		new_economy: PackedByteArray) -> PackedByteArray:
	if bundle.size() < 16 or new_economy.is_empty():
		return PackedByteArray()
	const marker := 0x32504345 # "ECP2" little-endian.
	var offset := -1
	var cursor := 89
	while cursor + 16 <= bundle.size():
		if int(bundle.decode_u32(cursor)) == marker:
			var size := int(bundle.decode_u32(cursor + 4))
			if size == new_economy.size() and cursor + 8 + size + 8 <= bundle.size():
				offset = cursor
				break
		cursor += 1
	if offset < 0:
		return PackedByteArray()
	var old_size := int(bundle.decode_u32(offset + 4))
	var tail_offset := offset + 8 + old_size + 8
	var out := PackedByteArray()
	out.append_array(bundle.slice(0, offset))
	var header := bundle.slice(offset, offset + 8)
	header.encode_u32(4, new_economy.size())
	out.append_array(header)
	out.append_array(new_economy)
	var section_checksum := PackedByteArray()
	section_checksum.resize(8)
	section_checksum.encode_u64(0, _fnv(new_economy))
	out.append_array(section_checksum)
	out.append_array(bundle.slice(tail_offset, bundle.size()))
	if out.size() < 8:
		return PackedByteArray()
	out.encode_u64(out.size() - 8, _fnv(out.slice(0, out.size() - 8)))
	return out


## Rewrites the Country generation/hash in ECP2's embedded PKEC HEADER chunk and
## repairs ECP2's content hash. The wire stays valid; only the expected identity
## changes.
func _rewrite_ecp2_country_identity(ecp2: PackedByteArray, generation: int,
		hash: int) -> PackedByteArray:
	if ecp2.size() < 64 or ecp2.decode_u32(0) != 0x32504345:
		return PackedByteArray()
	var out := ecp2.duplicate()
	const pkec_marker := 0x43454b50 # "PKEC" little-endian.
	var envelope_size := int(out.decode_u32(24))
	if envelope_size < 16 or 28 + envelope_size > out.size():
		return PackedByteArray()
	var header_offset := -1
	var cursor := 28
	var envelope_end := 28 + envelope_size
	while cursor + 80 <= envelope_end:
		if out.decode_u32(cursor) == pkec_marker and \
				out.decode_u16(cursor + 6) == 0:
			header_offset = cursor
			break
		cursor += 1
	if header_offset < 0:
		return PackedByteArray()
	out.encode_u64(header_offset + 64, generation)
	out.encode_u64(header_offset + 72, hash)
	out.encode_u64(16, _fnv(out.slice(24, out.size())))
	return out


func _country_section(bundle: PackedByteArray) -> PackedByteArray:
	const marker := 0x32445043 # "CPD2" little-endian.
	var cursor := 89
	while cursor + 16 <= bundle.size():
		if int(bundle.decode_u32(cursor)) == marker:
			var size := int(bundle.decode_u32(cursor + 4))
			if size >= 104 and cursor + 8 + size + 8 <= bundle.size() and \
					int(bundle.decode_u32(cursor + 8)) == marker:
				return bundle.slice(cursor + 8, cursor + 8 + size)
		cursor += 1
	return PackedByteArray()


func _valid_country_section(section: PackedByteArray) -> bool:
	return section.size() >= 104 and section.decode_u32(0) == 0x32445043 and \
		section.decode_u32(4) == 2 and section.decode_u32(8) == 13


func _country_commands(rows: Array[Dictionary]) -> Dictionary:
	var out := {
		"opcodes": PackedInt32Array(),
		"effective_days": PackedInt64Array(),
		"sequences": PackedInt64Array(),
		"target_handles": PackedInt64Array(),
		"cell_indices": PackedInt32Array(),
		"aux_i32": PackedInt32Array(),
		"domain_i32": PackedInt32Array(),
		"position_i32": PackedInt32Array(),
		"weight0_bp": PackedInt32Array(),
		"weight1_bp": PackedInt32Array(),
		"weight2_bp": PackedInt32Array(),
		"weight3_bp": PackedInt32Array(),
		"value_i64": PackedInt64Array(),
		"tax_kinds": PackedInt32Array(),
		"tax_item_indices": PackedInt32Array(),
		"tax_rate_basis_points": PackedInt32Array(),
		"tax_assessment_modes": PackedInt32Array(),
		"stable_ids": PackedStringArray(),
		"display_names": PackedStringArray(),
	}
	for row: Dictionary in rows:
		out.opcodes.append(int(row.get("opcode", 0)))
		out.effective_days.append(int(row.get("day", 0)))
		out.sequences.append(int(row.get("sequence", 0)))
		out.target_handles.append(int(row.get("handle", 0)))
		out.cell_indices.append(int(row.get("cell", -1)))
		out.aux_i32.append(int(row.get("aux", -1)))
		out.domain_i32.append(int(row.get("domain", -1)))
		out.position_i32.append(int(row.get("position", -1)))
		var weights: PackedInt32Array = row.get(
			"weights", PackedInt32Array([0, 0, 0, 0]))
		out.weight0_bp.append(weights[0])
		out.weight1_bp.append(weights[1])
		out.weight2_bp.append(weights[2])
		out.weight3_bp.append(weights[3])
		out.value_i64.append(int(row.get("value", 0)))
		out.tax_kinds.append(int(row.get("tax_kind", -1)))
		out.tax_item_indices.append(int(row.get("tax_item", -1)))
		out.tax_rate_basis_points.append(int(row.get("tax_rate_bp", 0)))
		out.tax_assessment_modes.append(int(row.get("tax_mode", 0)))
		out.stable_ids.append(String(row.get("stable_id", "")))
		out.display_names.append(String(row.get("name", "")))
	return out


func _commit_restored_days(ext: Object, cell_count: int) -> bool:
	if ext == null:
		return false
	var report: Dictionary = ext.get_runtime_thread_report()
	var before := int(report.get("simulation_committed_day", -1))
	var clocked: Dictionary = ext.set_runtime_clock(false, 4.0)
	if not bool(clocked.get("ok", false)):
		return false
	var deadline := Time.get_ticks_msec() + 12000
	while Time.get_ticks_msec() < deadline:
		ext.capture_economy_day_inputs(-1)
		ext.advance_runtime_pulse(0, 0.0, 1.0, 4000)
		if ext.has_method("service_country_worker_peer_adapter"):
			ext.service_country_worker_peer_adapter(64, true)
		var live: Dictionary = ext.get_runtime_thread_report()
		if int(live.get("simulation_committed_day", -1)) > before:
			ext.set_runtime_clock(true, 4.0)
			return true
		OS.delay_msec(5)
	var final_report: Dictionary = ext.get_runtime_thread_report()
	printerr("[identity-control] commit timeout: %s" % JSON.stringify(final_report))
	ext.set_runtime_clock(true, 4.0)
	return false


func _fnv(bytes: PackedByteArray, hash: int = 1469598103934665603) -> int:
	const prime := 1099511628211
	for byte in bytes:
		hash = (hash ^ byte) * prime
	return hash


func _brief(result: Dictionary) -> String:
	var code := String(result.get("code", result.get("reason", "")))
	return code if not code.is_empty() else str(result)


func _expect(label: String, condition: bool, detail: String = "") -> void:
	_checks += 1
	if condition:
		return
	_failures += 1
	printerr("ERROR: [FAIL] %s%s" % [label,
		(" (%s)" % detail) if not detail.is_empty() else ""])


func _require(label: String, condition: bool, detail: String = "") -> bool:
	_expect(label, condition, detail)
	return condition


func _fail(reason: String) -> void:
	_failures += 1
	printerr("ERROR: [FAIL] %s" % reason)
