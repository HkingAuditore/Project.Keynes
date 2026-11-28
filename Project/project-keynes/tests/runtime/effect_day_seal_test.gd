extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const RULE_STAT := "country.k3_day_seal_probe"
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
	_expect("Effect host stage & transport queue C++ self-test passes",
		bool(probe_ext.call("runtime_effect_host_stage_self_test")))
	probe_ext = null

	var country_catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("K3 Country catalog compiles", bool(country_catalog.get("ok", false)))
	if not bool(country_catalog.get("ok", false)):
		_finish()
		return
	country_catalog.erase("ok")

	var rules := _build_rules()
	var post_seal_pre_settle := _run_path(country_catalog, rules, true, 9601)
	var post_settle := _run_path(country_catalog, rules, false, 9602)

	print("[k3-day-seal] pre_settle day1=(intents=%d hash=%d fire=%d) day2=(intents=%d hash=%d fire=%d metric=%d)" % [
		int(post_seal_pre_settle.get("day1_intents", -1)),
		int(post_seal_pre_settle.get("day1_hash", 0)),
		int(post_seal_pre_settle.get("day1_fire", -1)),
		int(post_seal_pre_settle.get("day2_intents", -1)),
		int(post_seal_pre_settle.get("day2_hash", 0)),
		int(post_seal_pre_settle.get("day2_fire", -1)),
		int(post_seal_pre_settle.get("day2_metric", -1)),
	])
	print("[k3-day-seal] post_settle day1=(intents=%d hash=%d fire=%d) day2=(intents=%d hash=%d fire=%d metric=%d)" % [
		int(post_settle.get("day1_intents", -1)),
		int(post_settle.get("day1_hash", 0)),
		int(post_settle.get("day1_fire", -1)),
		int(post_settle.get("day2_intents", -1)),
		int(post_settle.get("day2_hash", 0)),
		int(post_settle.get("day2_fire", -1)),
		int(post_settle.get("day2_metric", -1)),
	])

	_expect("post-seal pre-settle enqueue must not emit intents on sealed day 1",
		int(post_seal_pre_settle.get("day1_intents", -1)) == 0)
	_expect("post-seal pre-settle enqueue must not fire on sealed day 1",
		int(post_seal_pre_settle.get("day1_fire", -1)) == 0)
	_expect("day 1 intent count matches between post-seal pre-settle and post-settle",
		int(post_seal_pre_settle.get("day1_intents", -1)) == int(post_settle.get("day1_intents", -2)))
	_expect("day 1 Effect POD state hash matches between post-seal pre-settle and post-settle",
		int(post_seal_pre_settle.get("day1_hash", 0)) == int(post_settle.get("day1_hash", -1)))
	_expect("post-seal pre-settle enqueue fires on next open day 2",
		int(post_seal_pre_settle.get("day2_fire", 0)) == 1 and
		int(post_seal_pre_settle.get("day2_metric", -1)) == 77)
	_expect("post-settle enqueue fires on next open day 2",
		int(post_settle.get("day2_fire", 0)) == 1 and
		int(post_settle.get("day2_metric", -1)) == 77)
	_expect("day 2 Effect POD state hash matches between post-seal pre-settle and post-settle",
		int(post_seal_pre_settle.get("day2_hash", 0)) == int(post_settle.get("day2_hash", -1)))

	var day1_bundle: PackedByteArray = post_seal_pre_settle.get("day1_bundle", PackedByteArray())
	_expect("day 1 save bundle contains ETQ2 transport marker",
		_has_marker(day1_bundle, 69, 84, 81, 50))
	_expect("day 1 save bundle does not contain legacy ETQ1 marker",
		not _has_marker(day1_bundle, 69, 84, 81, 49))
	_verify_pending_restore(country_catalog, rules, day1_bundle,
		int(post_settle.get("day2_hash", 0)))

	_finish()

func _build_rules() -> Dictionary:
	var definition_key := "test.k3_day_seal_bonus"
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
		"term_values": PackedFloat64Array([5.0]),
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
	command.command_key = "test.k3_day_seal_apply"
	var effect := EffectDefinition.new()
	effect.key = "test.k3_day_seal_effect"
	effect.instructions = [constant, emit]
	effect.commands = [command]
	var effects := EffectCatalog.new()
	effects.metric_keys = PackedStringArray(["k3.metric"])
	effects.definitions = [effect]

	return {
		"modifier": modifiers,
		"effect": effects.compile_native_catalog(),
		"program": String(effect.key),
	}

func _setup_world(ext: Object, country_catalog: Dictionary, rules: Dictionary) -> int:
	ext.create_entities(2)
	var mod_cfg: Dictionary = ext.configure_modifiers(rules.modifier, 2)
	_expect("K3 Modifier configures", bool(mod_cfg.get("ok", false)) and bool(mod_cfg.get("modifier_pod_ready", false)))
	var eff_cfg: Dictionary = ext.configure_effects(rules.effect)
	_expect("K3 Effect configures", bool(eff_cfg.get("ok", false)) and bool(eff_cfg.get("effect_pod_ready", false)))
	_expect("K3 Country configures", bool(ext.configure_country(country_catalog,
		{"country_runtime_mode": "ACTIVE", "starting_technology_ids": PackedStringArray()},
		2, 4242).get("ok", false)))
	_expect("K3 Country bootstraps", bool(ext.bootstrap_country({}, PackedByteArray([0, 0])).get("ok", false)))
	_expect("K3 Country catalog captures", bool(ext.capture_country_pod_catalog().get("ok", false)))
	_expect("K3 Country snapshot captures", bool(ext.capture_country_runtime_snapshot().get("ok", false)))
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
	_expect("K3 inline runtime starts", bool(started.get("ok", false)))
	return int(ext.get_country_cell_summary(0).get("country_handle", 0))

func _capture_input(ext: Object, day: int) -> void:
	var generation := int(ext.get_runtime_thread_report().get("simulation_environment_generation", 0)) + 1
	_expect("K3 day %d input seals" % day, bool(ext.capture_runtime_inputs({
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

func _queue_probe_effect(ext: Object, rules: Dictionary, target: int) -> void:
	var queued: Dictionary = ext.queue_effect_pod_instance({
		"instance_id": 2001,
		"generation": 1,
		"program_key": rules.program,
		"source_id": 2001,
		"source_handle": target,
		"target_handle": target,
		"target_generation": 1,
		"next_due_day": 1,
		"active": true,
	})
	_expect("K3 queue probe instance succeeds", bool(queued.get("ok", false)))
	var metric: Dictionary = ext.queue_effect_pod_metric({
		"instance_id": 2001,
		"generation": 1,
		"metric_id": 0,
		"revision": 3,
		"value": 77,
	})
	_expect("K3 queue probe metric succeeds", bool(metric.get("ok", false)))

func _save_bundle(ext: Object, request_id: int) -> Dictionary:
	_expect("K3 save request %d accepted" % request_id, bool(ext.request_runtime_save(request_id).get("ok", false)))
	var saved: Dictionary = {}
	var deadline := Time.get_ticks_msec() + 2000
	while Time.get_ticks_msec() < deadline:
		saved = ext.poll_runtime_save(request_id)
		if bool(saved.get("ready", false)) or not bool(saved.get("ok", true)):
			break
		OS.delay_msec(2)
	_expect("K3 save request %d ready" % request_id, bool(saved.get("ready", false)))
	return saved

func _stop_world(ext: Object) -> void:
	ext.request_runtime_stop()
	var deadline := Time.get_ticks_msec() + 2000
	while Time.get_ticks_msec() < deadline:
		if bool(ext.get_runtime_thread_report().get("simulation_executor_exited", false)):
			break
		OS.delay_msec(2)
	_expect("K3 runtime stops cleanly", bool(ext.get_runtime_thread_report().get("simulation_executor_exited", false)))

func _run_path(country_catalog: Dictionary, rules: Dictionary, enqueue_before_settle: bool,
		save_id: int) -> Dictionary:
	var ext := DCWorldExt.new()
	var target := _setup_world(ext, country_catalog, rules)
	_expect("K3 target country handle is non-zero", target != 0)

	# Seal day 1 inputs first (next_environment_day becomes 2 -> command_seal_day == 2).
	_capture_input(ext, 1)
	if enqueue_before_settle:
		_queue_probe_effect(ext, rules, target)

	_expect("K3 inline day 1 commits", bool(ext.run_native_daily_inline_day().get("ok", false)))
	var report1: Dictionary = ext.get_runtime_thread_report()
	_expect("K3 day 1 effect snapshot applies", bool(ext.apply_runtime_effect_snapshot(0).get("ok", false)))
	var info1: Dictionary = ext.explain_effect(2001)
	var day1_fire := int(info1.get("fire_sequence", 0)) if bool(info1.get("ok", false)) else 0

	var day1_bundle := PackedByteArray()
	if enqueue_before_settle:
		var saved1 := _save_bundle(ext, save_id)
		day1_bundle = saved1.get("bytes", PackedByteArray())
	else:
		_queue_probe_effect(ext, rules, target)

	_capture_input(ext, 2)
	_expect("K3 inline day 2 commits", bool(ext.run_native_daily_inline_day().get("ok", false)))
	var report2: Dictionary = ext.get_runtime_thread_report()
	_expect("K3 day 2 effect snapshot applies", bool(ext.apply_runtime_effect_snapshot(0).get("ok", false)))
	var info2: Dictionary = ext.explain_effect(2001)
	var day2_fire := int(info2.get("fire_sequence", 0)) if bool(info2.get("ok", false)) else 0
	var day2_metric := int(ext.query_effect_instance_metric(2001, 0).get("value", -1))

	_stop_world(ext)
	return {
		"day1_intents": int(report1.get("effect_pod_intent_count", -1)),
		"day1_hash": int(report1.get("effect_pod_state_hash", 0)),
		"day1_fire": day1_fire,
		"day2_intents": int(report2.get("effect_pod_intent_count", -1)),
		"day2_hash": int(report2.get("effect_pod_state_hash", 0)),
		"day2_fire": day2_fire,
		"day2_metric": day2_metric,
		"day1_bundle": day1_bundle,
	}

func _verify_pending_restore(country_catalog: Dictionary, rules: Dictionary, bytes: PackedByteArray,
		expected_day2_hash: int) -> void:
	var ext := DCWorldExt.new()
	ext.create_entities(2)
	_expect("K3 restore target Modifier configures",
		bool(ext.configure_modifiers(rules.modifier, 2).get("ok", false)))
	_expect("K3 restore target Effect configures",
		bool(ext.configure_effects(rules.effect).get("ok", false)))
	_expect("K3 restore target Country configures",
		bool(ext.configure_country(country_catalog,
			{"country_runtime_mode": "ACTIVE", "starting_technology_ids": PackedStringArray()},
			2, 4242).get("ok", false)))
	_expect("K3 restore target Country bootstraps",
		bool(ext.bootstrap_country({}, PackedByteArray([0, 0])).get("ok", false)))
	_expect("K3 restore target Country catalog captures",
		bool(ext.capture_country_pod_catalog().get("ok", false)))
	_expect("K3 restore target Country snapshot captures",
		bool(ext.capture_country_runtime_snapshot().get("ok", false)))
	_capture_input(ext, 1)

	var restored: Dictionary = ext.restore_runtime_bundle(bytes)
	_expect("K3 restore_runtime_bundle succeeds", bool(restored.get("restored", false)))
	var started: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "ACTIVE",
		"graph_coverage_complete": true,
		"native_daily_inline": true,
		"authoritative_domain_mask": AUTHORITATIVE_MASK,
		"day": 1,
		"speed_days_per_second": 0.0,
		"paused": true,
	})
	_expect("K3 restored runtime restarts", bool(started.get("ok", false)))
	_capture_input(ext, 2)
	_expect("K3 restored inline day 2 commits", bool(ext.run_native_daily_inline_day().get("ok", false)))
	var report2: Dictionary = ext.get_runtime_thread_report()
	_expect("K3 restored day 2 effect snapshot applies",
		bool(ext.apply_runtime_effect_snapshot(0).get("ok", false)))
	var info2: Dictionary = ext.explain_effect(2001)
	_expect("K3 restored pending queue fires on day 2 with preserved metric",
		bool(info2.get("ok", false)) and
		int(info2.get("fire_sequence", 0)) == 1 and
		int(ext.query_effect_instance_metric(2001, 0).get("value", -1)) == 77)
	_expect("K3 restored day 2 Effect POD state hash matches post-settle baseline",
		int(report2.get("effect_pod_state_hash", 0)) == expected_day2_hash)
	_stop_world(ext)

	# Production startup path must fail-closed on legacy ETQ1 (not silently clear queue).
	var legacy_bytes := bytes.duplicate()
	var etq_pos := -1
	for i in range(legacy_bytes.size() - 12):
		if legacy_bytes[i] == 0x45 and legacy_bytes[i + 1] == 0x54 and legacy_bytes[i + 2] == 0x51 and legacy_bytes[i + 3] == 0x32:
			etq_pos = i
	if etq_pos >= 0:
		legacy_bytes[etq_pos + 3] = 0x31 # '2' -> '1' (ETQ1)
		var csum := 1469598103934665603
		for i in range(legacy_bytes.size() - 8):
			csum = (csum ^ int(legacy_bytes[i])) * 1099511628211
		legacy_bytes.encode_u64(legacy_bytes.size() - 8, csum)
		var rej_ext := DCWorldExt.new()
		rej_ext.create_entities(2)
		rej_ext.configure_modifiers(rules.modifier, 2)
		rej_ext.configure_effects(rules.effect)
		rej_ext.configure_country(country_catalog,
			{"country_runtime_mode": "ACTIVE", "starting_technology_ids": PackedStringArray()},
			2, 4242)
		rej_ext.bootstrap_country({}, PackedByteArray([0, 0]))
		rej_ext.capture_country_pod_catalog()
		rej_ext.capture_country_runtime_snapshot()
		_capture_input(rej_ext, 1)
		var rej_bundle: Dictionary = rej_ext.restore_runtime_bundle(legacy_bytes)
		_expect("K3 legacy ETQ1 bundle passes container checksum", bool(rej_bundle.get("restored", false)))
		var rej_start: Dictionary = rej_ext.start_runtime_worker({
			"simulation_thread_mode": "ACTIVE",
			"graph_coverage_complete": true,
			"native_daily_inline": true,
			"authoritative_domain_mask": AUTHORITATIVE_MASK,
			"day": 1,
			"speed_days_per_second": 0.0,
			"paused": true,
		})
		_expect("K3 production startup rejects legacy ETQ1 fail-closed",
			not bool(rej_start.get("ok", true)))
		_stop_world(rej_ext)

func _has_marker(bytes: PackedByteArray, b0: int, b1: int, b2: int, b3: int) -> bool:
	if bytes.size() < 4:
		return false
	for i in range(bytes.size() - 3):
		if bytes[i] == b0 and bytes[i + 1] == b1 and bytes[i + 2] == b2 and bytes[i + 3] == b3:
			return true
	return false

func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_fail(label)

func _fail(label: String) -> void:
	_failures += 1
	push_error("[FAIL] %s" % label)

func _finish() -> void:
	print("=== K3 effect day seal: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)
