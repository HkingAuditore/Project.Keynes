extends SceneTree

const CountryTestHelper = preload("res://tests/country_test_helper.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")
const ModifierFacadeScript = preload("res://scripts/modifier/modifier_facade.gd")

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	print("runtime ideology IDP1 save: %d checks, %d failures" % [
		_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt unavailable")
		return
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("economy catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		return
	var native_catalog := compiled.duplicate(true)
	native_catalog.erase("ok")
	var ext: Object = DCWorldExt.new()
	ext.create_entities(1)
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_weather_precip", &"cell_snow_cover",
			&"cell_weather_intensity", &"cell_elevation"]:
		var float_slot: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(float_slot, 0, PackedFloat32Array([0.5]))
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation",
			&"cell_is_water", &"cell_has_river"]:
		var byte_slot: int = ext.register_component(slot_name, 2, 1, false)
		ext.write_u8_range(byte_slot, 0, PackedByteArray([0]))
	var reserve_slots: PackedStringArray = native_catalog.building_resource_reserve_slots
	var extra_slots: PackedStringArray = native_catalog.building_resource_extra_slots
	for index in reserve_slots.size():
		var reserve_slot: int = ext.register_component(
			StringName(reserve_slots[index]), 0, 1, false)
		var extra_slot: int = ext.register_component(
			StringName(extra_slots[index]), 0, 1, false)
		ext.write_f32_range(reserve_slot, 0, PackedFloat32Array([1000000.0]))
		ext.write_f32_range(extra_slot, 0, PackedFloat32Array([0.0]))
	_expect("country configures", CountryTestHelper.configure_all_technologies(
		ext, native_catalog, 1, 20260909))
	var modifier := ModifierFacadeScript.new()
	_expect("modifier configures", bool(modifier.configure(ext, 1).get("ok", false)))
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.market_runtime_mode = "ACTIVE"
	profile.market_cycle_days = 1
	profile.worker_enabled = false
	_expect("economy configures", bool(ext.configure_economy(
		native_catalog, profile, 1, 20260909).get("ok", false)))
	var signatures: PackedStringArray = compiled.signature_keys
	var selected := PackedInt32Array([
		signatures.find("hunter|default"),
		signatures.find("sharecropper|default"),
		signatures.find("corvee_worker|default"),
		signatures.find("scholar|default"),
	])
	_expect("political-class signatures exist", selected.find(-1) == -1)
	_expect("economy bootstraps", bool(ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0, 0, 0]),
		"signature_ids": selected,
		"population": PackedInt64Array([100, 100, 100, 100]),
		"funds": PackedInt64Array([0, 0, 0, 0]),
	}, {}).get("ok", false)))
	_expect("country worker snapshot publishes", bool(
		ext.capture_country_runtime_snapshot().get("ok", false)))
	_expect("country worker catalog publishes", bool(
		ext.capture_country_pod_catalog().get("ok", false)))
	var economy_done := _run_economy(ext, 0)
	var opinion_snapshot: Dictionary = ext.get_country_class_opinion_snapshot()
	_expect("economy publishes committed opinion", economy_done
		and int(opinion_snapshot.get("revision", 0)) > 0)
	_expect("ideology worker opinion publication succeeds", bool(
		ext.publish_ideology_worker_inputs().get("ok", false)))
	var effect_catalog: Resource = EffectDomainCatalogScript.build()
	_expect("Effect catalog builds", effect_catalog != null)
	if effect_catalog == null:
		return
	_expect("Effect configures", bool(ext.configure_effects(
		effect_catalog.compile_native_catalog()).get("ok", false)))
	var ideology_catalog: Resource = IdeologyCatalogScript.load_default()
	var ideology_ir: Dictionary = ideology_catalog.compile_native_catalog(
		native_catalog, native_catalog)
	_expect("ideology catalog compiles", bool(ideology_ir.get("ok", false)))
	if not bool(ideology_ir.get("ok", false)):
		return
	ideology_ir.erase("ok")
	var configured: Dictionary = ext.configure_ideologies(ideology_ir)
	_expect("ideology worker configures", bool(configured.get("ok", false))
		and bool(configured.get("worker_shadow_configured", false)))
	_expect("ideology worker receives opinion snapshot",
		bool(configured.get("worker_opinion_published", false)))

	var started: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "SHADOW",
		"graph_coverage_complete": false,
		"day": 0,
		"speed_days_per_second": 0.0,
		"paused": false,
	})
	_expect("SHADOW worker starts", bool(started.get("ok", false)))
	var ready_report := _wait_for_ideology(ext)
	_expect("SHADOW worker report is available", not ready_report.is_empty())
	var saved: Dictionary = _request_save(ext, 2026090901)
	_expect("PKSR writes an independent IDP1 section",
		bool(saved.get("ready", false))
		and (int(saved.get("section_mask", 0)) & (1 << 8)) != 0
		and int(saved.get("ideology_bytes", 0)) > 0)
	var save_bytes: PackedByteArray = saved.get("bytes", PackedByteArray())
	var saved_hash := int(ready_report.get("ideology_pod_state_hash", 0))
	_stop(ext)

	var restored: Dictionary = ext.restore_runtime_bundle(save_bytes)
	_expect("IDP1 bundle restores transactionally", bool(restored.get("restored", false)))
	var restarted: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "SHADOW",
		"graph_coverage_complete": false,
		"day": 0,
		"speed_days_per_second": 0.0,
		"paused": true,
	})
	var restored_report: Dictionary = ext.get_runtime_thread_report()
	_expect("restored IDP1 state is published before worker activity",
		bool(restarted.get("ok", false))
		and int(restored_report.get("ideology_pod_state_hash", 0)) == saved_hash)
	_stop(ext)

	var tampered := save_bytes.duplicate()
	if tampered.size() > 0:
		tampered[tampered.size() - 1] = tampered[tampered.size() - 1] ^ 0x40
	var rejected: Dictionary = ext.restore_runtime_bundle(tampered)
	_expect("tampered outer checksum rejects the complete bundle",
		not bool(rejected.get("restored", false)))
	_expect("failed restore leaves the prior worker snapshot intact",
		int(ext.get_runtime_thread_report().get("ideology_pod_state_hash", 0)) == saved_hash)


func _run_economy(ext: Object, day: int) -> bool:
	for _slice in 512:
		var report: Dictionary = ext.run_economy_slice({
			"day_index": day,
			"tick_index": day * 1000 + _slice,
		})
		if bool(report.get("done", false)):
			return true
	return false


func _wait_for_ideology(ext: Object) -> Dictionary:
	var report: Dictionary = {}
	var deadline := Time.get_ticks_msec() + 1500
	while Time.get_ticks_msec() < deadline:
		report = ext.get_runtime_thread_report()
		if bool(report.get("ideology_pod_ready", false)):
			return report
		OS.delay_msec(5)
	return report


func _request_save(ext: Object, request_id: int) -> Dictionary:
	var request: Dictionary = ext.request_runtime_save(request_id)
	if not bool(request.get("pending", false)):
		return request
	var saved: Dictionary = {}
	var deadline := Time.get_ticks_msec() + 1500
	while Time.get_ticks_msec() < deadline:
		saved = ext.poll_runtime_save(request_id)
		if bool(saved.get("ready", false)):
			return saved
		OS.delay_msec(5)
	return saved


func _stop(ext: Object) -> void:
	ext.request_runtime_stop()
	var deadline := Time.get_ticks_msec() + 1500
	while Time.get_ticks_msec() < deadline:
		if str(ext.get_runtime_thread_report().get("state", "")) == "STOPPED":
			return
		OS.delay_msec(5)


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_fail(label)


func _fail(label: String) -> void:
	_failures += 1
	push_error("[FAIL] %s" % label)
