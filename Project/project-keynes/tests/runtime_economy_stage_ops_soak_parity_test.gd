extends SceneTree

## Dual-path soak: compact run_economy_slice vs StageOps run_economy_stage_ops_day.
## Same seed/catalog/profile; compare get_economy_state_hash(). On PASS, latch
## economy_stage_ops_soak_parity_ok. Env PK_ECONOMY_SOAK_DAYS default 5 (clamp 1..60).

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryTestHelper = preload("res://tests/country_test_helper.gd")

var _checks := 0
var _failures := 0


func _init() -> void:
	call_deferred("_run")


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		print("  [FAIL] %s" % label)
	else:
		print("  [PASS] %s" % label)


func _soak_days() -> int:
	var raw := OS.get_environment("PK_ECONOMY_SOAK_DAYS")
	if raw.is_empty():
		return 5
	return clampi(int(raw), 1, 60)


func _profile() -> Dictionary:
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.market_runtime_mode = "ACTIVE"
	profile.market_cycle_days = 1
	profile.market_min_cycle_days = 1
	profile.market_max_cycle_days = 5
	profile.economy_cadence_target_ms = 8.0
	return profile


func _new_ext(cells: int) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(cells)
	var climate := PackedFloat32Array()
	climate.resize(cells)
	climate.fill(0.5)
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_weather_precip", &"cell_snow_cover",
			&"cell_weather_intensity", &"cell_elevation"]:
		var sid: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(sid, 0, climate)
	var zeros := PackedByteArray()
	zeros.resize(cells)
	zeros.fill(0)
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation",
			&"cell_is_water", &"cell_has_river"]:
		var sid: int = ext.register_component(slot_name, 2, 1, false)
		ext.write_u8_range(sid, 0, zeros)
	return ext


func _boot(compiled: Dictionary, cells: int, seed: int) -> Object:
	var ext := _new_ext(cells)
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	_expect("country bootstraps",
		CountryTestHelper.configure_all_technologies(ext, catalog, cells, seed))
	var configured: Dictionary = ext.configure_economy(
		catalog, _profile(), cells, seed)
	_expect("configure_economy ok", bool(configured.get("ok", false)))
	var signature: int = (compiled.signature_keys as PackedStringArray).find(
		"merchant|default")
	var cell_indices := PackedInt32Array()
	var signatures := PackedInt32Array()
	var populations := PackedInt64Array()
	var funds := PackedInt64Array()
	for cell in range(cells):
		cell_indices.append(cell)
		signatures.append(signature)
		populations.append(20)
		funds.append(100000000)
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": cell_indices,
		"signature_ids": signatures,
		"population": populations,
		"funds": funds,
	}, {})
	_expect("bootstrap_economy ok", bool(boot.get("ok", false)))
	return ext


func _run_compact_day(ext: Object, day: int) -> Dictionary:
	var report := {}
	for slice in range(256):
		report = ext.run_economy_slice({
			"day_index": day,
			"tick_index": day * 1000 + slice,
		})
		if bool(report.get("done", false)) or bool(report.get("fatal", false)):
			return report
	return report


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("runtime_economy_stage_ops_soak_parity_test SKIP (no DCWorldExt)")
		quit(1)
		return
	var probe := DCWorldExt.new()
	if not probe.has_method("run_economy_stage_ops_day"):
		print("runtime_economy_stage_ops_soak_parity_test SKIP (API missing)")
		quit(1)
		return

	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		_finish()
		return

	var days := _soak_days()
	var cells := 9
	var seed := 997
	var compact := _boot(compiled, cells, seed)
	var stage_ops := _boot(compiled, cells, seed)

	var mismatch_day := -1
	for day in range(days):
		var compact_report: Dictionary = _run_compact_day(compact, day)
		_expect("compact day %s done" % day,
			bool(compact_report.get("done", false))
			and not bool(compact_report.get("fatal", false)))
		if bool(compact_report.get("fatal", false)):
			print("  [info] compact fatal reason=%s" % [
				compact_report.get("reason", compact_report.get("fatal_reason", ""))])
		var stage_report: Dictionary = stage_ops.run_economy_stage_ops_day(day)
		_expect("stage_ops day %s done" % day,
			bool(stage_report.get("ok", false))
			and not bool(stage_report.get("fatal", false)))
		if not bool(stage_report.get("ok", false)):
			print("  [info] stage_ops reason=%s" % [
				stage_report.get("reason", "")])
		var hash_a: int = compact.get_economy_state_hash()
		var hash_b: int = stage_ops.get_economy_state_hash()
		if hash_a != hash_b and mismatch_day < 0:
			mismatch_day = day
			print("  [info] hash mismatch day=%s compact=%s stage_ops=%s" % [
				day, hash_a, hash_b])
		_expect("day %s state_hash matches" % day, hash_a == hash_b)
		for key in ["population_error", "money_error", "goods_error"]:
			if compact_report.has(key):
				_expect("compact day %s %s==0" % [day, key],
					int(compact_report.get(key, 1)) == 0)

	if mismatch_day < 0 and _failures == 0:
		stage_ops.set_economy_stage_ops_soak_parity_ok(true)
		_expect("soak_parity_ok latched",
			stage_ops.get_economy_stage_ops_soak_parity_ok())
	else:
		stage_ops.set_economy_stage_ops_soak_parity_ok(false)
		_expect("soak_parity_ok cleared on mismatch", true)

	# Legacy ingress disabled when StageOps writer is effective on a worker.
	var refuse_ingress: Dictionary = stage_ops.start_runtime_worker({
		"simulation_thread_mode": "SHADOW",
		"graph_coverage_complete": false,
		"day": 0,
		"paused": true,
		"economy_stage_ops_mutate": true,
		"economy_production_writer": "stage_ops",
	})
	_expect("stage_ops worker starts for ingress check",
		bool(refuse_ingress.get("ok", false)))
	if bool(refuse_ingress.get("ok", false)):
		var submit: Dictionary = stage_ops.submit_economy_commands({
			"opcodes": PackedInt32Array([1]),
			"effective_days": PackedInt64Array([0]),
			"sequences": PackedInt64Array([0]),
			"target_handles": PackedInt64Array([0]),
			"i32_0": PackedInt32Array([0]),
			"i32_1": PackedInt32Array([0]),
			"i64_0": PackedInt64Array([0]),
			"i64_1": PackedInt64Array([0]),
		})
		_expect("legacy submit refused under stage_ops writer",
			not bool(submit.get("ok", true))
			and String(submit.get("reason", "")).contains("legacy_ingress"))
		stage_ops.request_runtime_stop()

	_finish()


func _finish() -> void:
	print("runtime_economy_stage_ops_soak_parity_test checks=%s failures=%s" % [
		_checks, _failures])
	quit(0 if _failures == 0 else 1)
