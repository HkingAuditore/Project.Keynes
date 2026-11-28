extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const RULE_STAT := "country.k4_independent_binding_order_probe"
const AUTHORITATIVE_MASK := 0x863

var _checks := 0
var _failures := 0

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt unavailable")
		_finish()
		return

	var probe_ext: Object = ClassDB.instantiate("DCWorldExt")
	_expect("Effect POD C++ self-test passes (includes K4 order & unsorted restore rejection)",
		bool(probe_ext.call("runtime_effect_pod_self_test")))
	probe_ext = null

	var country_catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("K4 Country catalog compiles", bool(country_catalog.get("ok", false)))
	if not bool(country_catalog.get("ok", false)):
		_finish()
		return
	country_catalog.erase("ok")

	var rules := _build_rules()
	var run_ab := _run_order(country_catalog, rules, [1001, 1002], 1001, 9501)
	var run_ba := _run_order(country_catalog, rules, [1002, 1001], 1001, 9501)

	var hash_ab := int(run_ab.get("state_hash", 0))
	var hash_ba := int(run_ba.get("state_hash", 0))
	var bytes_ab: PackedByteArray = run_ab.get("bytes", PackedByteArray())
	var bytes_ba: PackedByteArray = run_ba.get("bytes", PackedByteArray())
	var efp_ab: PackedByteArray = _extract_efp1(bytes_ab)
	var efp_ba: PackedByteArray = _extract_efp1(bytes_ba)

	print("[k4-order] hash_ab=%d hash_ba=%d bytes_ab=%d bytes_ba=%d efp_ab=%d efp_ba=%d efp_eq=%s" % [
		hash_ab, hash_ba, bytes_ab.size(), bytes_ba.size(),
		efp_ab.size(), efp_ba.size(), str(efp_ab == efp_ba),
	])

	_expect("both runs produced non-zero Effect POD state hashes", hash_ab != 0 and hash_ba != 0)
	_expect("Effect POD state hash is independent of binding insertion order", hash_ab == hash_ba)
	_expect("both runs produced non-empty EFP1 payloads", not efp_ab.is_empty() and not efp_ba.is_empty())
	_expect("EFP1 payload bytes are identical regardless of insertion order", efp_ab == efp_ba)
	_expect("full PKSR save bundle is identical regardless of insertion order", bytes_ab == bytes_ba)

	# Verify save -> restore roundtrip preserves both active and retired bindings.
	_verify_roundtrip(country_catalog, rules, bytes_ab, 9503)
	_verify_roundtrip(country_catalog, rules, bytes_ba, 9504)

	_finish()

func _build_rules() -> Dictionary:
	var definition_key := "test.k4_order_bonus"
	var modifiers := {
		"protocol_version": 3,
		"stat_keys": PackedStringArray([RULE_STAT]),
		"stat_domains": PackedInt32Array([1]),
		"stat_min_values": PackedFloat64Array([0.0]),
		"stat_max_values": PackedFloat64Array([100.0]),
		"stat_persistable": PackedByteArray([1]),
		"definition_keys": PackedStringArray([definition_key]),
		"definition_versions": PackedInt32Array([1]),
		"definition_domains": PackedInt32Array([1]),
		"definition_policies": PackedInt32Array([1]),
		"definition_max_stacks": PackedInt32Array([1]),
		"definition_default_duration": PackedInt32Array([-1]),
		"definition_term_offsets": PackedInt32Array([0, 1]),
		"term_stat_ids": PackedInt32Array([0]),
		"term_operations": PackedInt32Array([0]),
		"term_values": PackedFloat64Array([3.0]),
	}

	var constant := EffectInstruction.new()
	constant.op = 1
	constant.value_q16 = 65536
	var emit := EffectInstruction.new()
	emit.op = 11
	emit.arg0 = 0
	var command := EffectCommand.new()
	command.action = 1
	command.domain = 1
	command.opcode = 1
	command.definition_key = definition_key
	command.command_key = "test.k4_order_apply"
	var effect := EffectDefinition.new()
	effect.key = "test.k4_order_effect"
	effect.instructions = [constant, emit]
	effect.commands = [command]
	var effects := EffectCatalog.new()
	effects.metric_keys = PackedStringArray(["k4.metric"])
	effects.definitions = [effect]

	return {
		"modifier": modifiers,
		"effect": effects.compile_native_catalog(),
		"program": String(effect.key),
	}

func _setup_world(ext: Object, country_catalog: Dictionary, rules: Dictionary) -> int:
	ext.create_entities(2)
	var mod_cfg: Dictionary = ext.configure_modifiers(rules.modifier, 2)
	_expect("K4 Modifier configures", bool(mod_cfg.get("ok", false)) and bool(mod_cfg.get("modifier_pod_ready", false)))
	var eff_cfg: Dictionary = ext.configure_effects(rules.effect)
	_expect("K4 Effect configures", bool(eff_cfg.get("ok", false)) and bool(eff_cfg.get("effect_pod_ready", false)))
	_expect("K4 Country configures", bool(ext.configure_country(country_catalog,
		{"country_runtime_mode": "ACTIVE", "starting_technology_ids": PackedStringArray()},
		2, 4242).get("ok", false)))
	_expect("K4 Country bootstraps", bool(ext.bootstrap_country({}, PackedByteArray([0, 0])).get("ok", false)))
	_expect("K4 Country catalog captures", bool(ext.capture_country_pod_catalog().get("ok", false)))
	_expect("K4 Country snapshot captures", bool(ext.capture_country_runtime_snapshot().get("ok", false)))
	_capture_input(ext, 0)
	var started: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "ACTIVE",
		"graph_coverage_complete": true,
		"native_daily_inline": true,
		"authoritative_domain_mask": AUTHORITATIVE_MASK,
		"day": 0,
		"speed_days_per_second": 0.0,
		"paused": true,
	})
	_expect("K4 inline runtime starts", bool(started.get("ok", false)))
	return int(ext.get_country_cell_summary(0).get("country_handle", 0))

func _capture_input(ext: Object, day: int) -> void:
	var generation := int(ext.get_runtime_thread_report().get("simulation_environment_generation", 0)) + 1
	_expect("K4 day %d input seals" % day, bool(ext.capture_runtime_inputs({
		"generation": generation,
		"day": day,
		"terrain": PackedByteArray([1, 1]),
		"landform": PackedByteArray([0, 0]),
		"climate_map_width": 2,
		"climate_map_height": 1,
		"climate_catalog_hash": 7,
		"cell_temp": PackedFloat32Array([15.0, 15.0]),
		"cell_moisture": PackedFloat32Array([0.5, 0.5]),
		"has_river": PackedByteArray([0, 0]),
		"neighbor_indices": PackedInt32Array([-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1]),
	}).get("ok", false)))

func _save_bundle(ext: Object, request_id: int) -> Dictionary:
	_expect("K4 save request %d accepted" % request_id, bool(ext.request_runtime_save(request_id).get("ok", false)))
	var saved: Dictionary = {}
	var deadline := Time.get_ticks_msec() + 2000
	while Time.get_ticks_msec() < deadline:
		saved = ext.poll_runtime_save(request_id)
		if bool(saved.get("ready", false)) or not bool(saved.get("ok", true)):
			break
		OS.delay_msec(2)
	_expect("K4 save request %d ready" % request_id, bool(saved.get("ready", false)))
	return saved

func _stop_world(ext: Object) -> void:
	ext.request_runtime_stop()
	var deadline := Time.get_ticks_msec() + 2000
	while Time.get_ticks_msec() < deadline:
		if bool(ext.get_runtime_thread_report().get("simulation_executor_exited", false)):
			break
		OS.delay_msec(2)
	_expect("K4 runtime stops cleanly", bool(ext.get_runtime_thread_report().get("simulation_executor_exited", false)))

func _run_order(country_catalog: Dictionary, rules: Dictionary, ids: Array, retire_id: int, save_id: int) -> Dictionary:
	var ext := DCWorldExt.new()
	var target := _setup_world(ext, country_catalog, rules)
	_expect("K4 target country handle is non-zero", target != 0)
	for id_value in ids:
		var id := int(id_value)
		var queued: Dictionary = ext.queue_effect_pod_instance({
			"instance_id": id,
			"generation": 1,
			"program_key": rules.program,
			"source_id": id,
			"source_handle": target,
			"target_handle": target,
			"target_generation": 1,
			"next_due_day": 1,
			"active": true,
		})
		_expect("K4 queue instance %d" % id, bool(queued.get("ok", false)))
		var metric: Dictionary = ext.queue_effect_pod_metric({
			"instance_id": id,
			"generation": 1,
			"metric_id": 0,
			"revision": 5,
			"value": id * 10,
		})
		_expect("K4 queue metric %d" % id, bool(metric.get("ok", false)))

	var removed: Dictionary = ext.queue_effect_pod_remove(retire_id, 1)
	_expect("K4 queue remove %d" % retire_id, bool(removed.get("ok", false)))

	_capture_input(ext, 1)
	_expect("K4 inline day 1 commits", bool(ext.run_native_daily_inline_day().get("ok", false)))

	var report: Dictionary = ext.get_runtime_thread_report()
	var state_hash := int(report.get("effect_pod_state_hash", 0))
	var applied: Dictionary = ext.apply_runtime_effect_snapshot(0)
	_expect("K4 effect snapshot applies", bool(applied.get("ok", false)))

	var retired_info: Dictionary = ext.explain_effect(retire_id)
	var active_id := 1002 if retire_id == 1001 else 1001
	var active_info: Dictionary = ext.explain_effect(active_id)
	_expect("K4 retired binding %d is retained in snapshot" % retire_id,
		bool(retired_info.get("ok", false)) and
		int(retired_info.get("fire_sequence", -1)) == 0 and
		int(ext.query_effect_instance_metric(retire_id, 0).get("value", -1)) == retire_id * 10)
	_expect("K4 active binding %d is retained in snapshot" % active_id,
		bool(active_info.get("ok", false)) and
		int(active_info.get("fire_sequence", 0)) == 1 and
		int(ext.query_effect_instance_metric(active_id, 0).get("value", -1)) == active_id * 10)

	var saved := _save_bundle(ext, save_id)
	var bytes: PackedByteArray = saved.get("bytes", PackedByteArray())
	_stop_world(ext)
	return {
		"state_hash": state_hash,
		"bytes": bytes,
	}

func _verify_roundtrip(country_catalog: Dictionary, rules: Dictionary, bytes: PackedByteArray,
		save_id: int) -> void:
	var ext := DCWorldExt.new()
	ext.create_entities(2)
	_expect("K4 restore target Modifier configures",
		bool(ext.configure_modifiers(rules.modifier, 2).get("ok", false)))
	_expect("K4 restore target Effect configures",
		bool(ext.configure_effects(rules.effect).get("ok", false)))
	_expect("K4 restore target Country configures",
		bool(ext.configure_country(country_catalog,
			{"country_runtime_mode": "ACTIVE", "starting_technology_ids": PackedStringArray()},
			2, 4242).get("ok", false)))
	_expect("K4 restore target Country bootstraps",
		bool(ext.bootstrap_country({}, PackedByteArray([0, 0])).get("ok", false)))
	_expect("K4 restore target Country catalog captures",
		bool(ext.capture_country_pod_catalog().get("ok", false)))
	_expect("K4 restore target Country snapshot captures",
		bool(ext.capture_country_runtime_snapshot().get("ok", false)))
	_capture_input(ext, 1)

	var restored: Dictionary = ext.restore_runtime_bundle(bytes)
	_expect("K4 restore_runtime_bundle succeeds", bool(restored.get("restored", false)))
	var started: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "ACTIVE",
		"graph_coverage_complete": true,
		"native_daily_inline": true,
		"authoritative_domain_mask": AUTHORITATIVE_MASK,
		"day": 1,
		"speed_days_per_second": 0.0,
		"paused": true,
	})
	_expect("K4 restored runtime restarts", bool(started.get("ok", false)))
	var saved_again := _save_bundle(ext, save_id)
	var bytes_again: PackedByteArray = saved_again.get("bytes", PackedByteArray())
	var efp_again: PackedByteArray = _extract_efp1(bytes_again)
	_expect("K4 roundtrip produces non-empty EFP1 payload", not efp_again.is_empty())
	_expect("K4 roundtrip EFP1 matches original EFP1", efp_again == _extract_efp1(bytes))

	_capture_input(ext, 2)
	_expect("K4 restored inline day 2 commits", bool(ext.run_native_daily_inline_day().get("ok", false)))
	var applied: Dictionary = ext.apply_runtime_effect_snapshot(0)
	_expect("K4 restored effect snapshot applies", bool(applied.get("ok", false)))
	var retired_after: Dictionary = ext.explain_effect(1001)
	var active_after: Dictionary = ext.explain_effect(1002)
	_expect("K4 roundtrip retains retired binding 1001 without re-firing",
		bool(retired_after.get("ok", false)) and
		int(retired_after.get("fire_sequence", -1)) == 0 and
		int(ext.query_effect_instance_metric(1001, 0).get("value", -1)) == 10010)
	_expect("K4 roundtrip retains active binding 1002 and advances it on day 2",
		bool(active_after.get("ok", false)) and
		int(active_after.get("fire_sequence", 0)) == 2 and
		int(ext.query_effect_instance_metric(1002, 0).get("value", -1)) == 10020)
	_stop_world(ext)

func _extract_efp1(bundle: PackedByteArray) -> PackedByteArray:
	if bundle.size() < 16:
		return PackedByteArray()
	var start := -1
	for i in range(bundle.size() - 3):
		if bundle[i] == 69 and bundle[i + 1] == 70 and bundle[i + 2] == 80 and bundle[i + 3] == 49:
			start = i
			break
	if start < 0:
		return PackedByteArray()
	var end_marker := -1
	for i in range(start + 4, bundle.size() - 11):
		if bundle[i] == 69 and bundle[i + 1] == 78 and bundle[i + 2] == 68 and bundle[i + 3] == 33:
			end_marker = i + 12
			break
	if end_marker < 0 or end_marker > bundle.size():
		return PackedByteArray()
	return bundle.slice(start, end_marker)

func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_fail(label)

func _fail(label: String) -> void:
	_failures += 1
	push_error("[FAIL] %s" % label)

func _finish() -> void:
	print("=== K4 effect independent binding order: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)
