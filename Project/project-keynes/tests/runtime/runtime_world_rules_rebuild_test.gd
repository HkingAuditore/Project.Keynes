extends "res://tests/runtime/runtime_world_lifecycle_test.gd"

const RULE_STAT := "country.world_rules_probe"
var _mask := 0x867

func _finish() -> void:
	await _run()
	_expect("all rule rebuild scenarios ran", _checks >= 400)
	print("runtime world rules rebuild: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _configuration(inline_mode: bool) -> Dictionary:
	var result: Dictionary = super._configuration(inline_mode)
	result.authoritative_domain_mask = _mask
	return result

func _run() -> int:
	var country: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("rule fixture Country catalog compiles", country.get("ok", false))
	country.erase("ok")
	for inline_mode in [false, true]:
		await _effect_rules(country, inline_mode)
		await _trigger_rules(country, inline_mode)
		await _production_rules(country, inline_mode)
	return 0

func _rules(variant: int) -> Dictionary:
	var definition_key := "test.world_rules_bonus_%d" % variant
	var modifiers := {"protocol_version": 3,
		"stat_keys": PackedStringArray([RULE_STAT]), "stat_domains": PackedInt32Array([1]),
		"stat_min_values": PackedFloat64Array([0.0]), "stat_max_values": PackedFloat64Array([100.0]),
		"stat_persistable": PackedByteArray([1]),
		"definition_keys": PackedStringArray([definition_key]), "definition_versions": PackedInt32Array([1]),
		"definition_domains": PackedInt32Array([1]), "definition_policies": PackedInt32Array([1]),
		"definition_max_stacks": PackedInt32Array([1]), "definition_default_duration": PackedInt32Array([-1]),
		"definition_term_offsets": PackedInt32Array([0, 1]), "term_stat_ids": PackedInt32Array([0]),
		"term_operations": PackedInt32Array([0]), "term_values": PackedFloat64Array([2.0 + variant])}

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
	command.command_key = "test.world_rules_apply_%d" % variant
	var effect := EffectDefinition.new()
	effect.key = "test.world_rules_effect_%d" % variant
	effect.instructions = [constant, emit]
	effect.commands = [command]
	var effects := EffectCatalog.new()
	effects.definitions = [effect]

	var reward := TriggerEffect.new()
	reward.action = 13
	reward.domain = 3
	reward.command_key = "test.world_rules_event_%d" % variant
	reward.value_mode = 0
	reward.value = 41 + variant
	var trigger := TriggerDefinition.new()
	trigger.key = "test.world_rules_trigger_%d" % variant
	trigger.source_id = 1
	trigger.event_type = 7
	trigger.threshold = 1
	trigger.mode = 1
	trigger.condition_ops = PackedInt32Array([1])
	trigger.effects = [reward]
	var triggers := TriggerCatalog.new()
	triggers.source_count = 4
	triggers.event_type_span = 32
	triggers.definitions = [trigger]
	return {"modifier": modifiers,
		"effect": effects.compile_native_catalog(), "trigger": triggers.compile_native_catalog(),
		"program": String(effect.key), "bonus": 2.0 + variant, "event_value": reward.value}

func _configure_rules(ext: Object, rules: Dictionary) -> void:
	var modifiers: Dictionary = ext.configure_modifiers(rules.modifier, 2)
	if not modifiers.get("ok", false): print("[world-rules] Modifier: ", modifiers)
	_expect("Modifier rules configure", modifiers.get("ok", false) and modifiers.get("modifier_pod_ready", false))
	var effects: Dictionary = ext.configure_effects(rules.effect)
	_expect("Effect rules configure", effects.get("ok", false) and effects.get("effect_pod_ready", false))
	var triggers: Dictionary = ext.configure_triggers(rules.trigger)
	if not triggers.get("ok", false): print("[world-rules] Trigger: ", triggers)
	_expect("Trigger rules configure", triggers.get("ok", false) and triggers.get("pod_shadow_ok", false))

func _advance(ext: Object, inline_mode: bool, day: int) -> bool:
	_capture_input(ext, day)
	if not inline_mode:
		ext.set_runtime_clock(false, 1.0)
	var deadline := Time.get_ticks_msec() + 3000
	while Time.get_ticks_msec() < deadline:
		if inline_mode:
			ext.run_native_daily_inline_day()
		if int(ext.get_runtime_thread_report().get("simulation_committed_day", -1)) == day:
			break
		await process_frame
	if not inline_mode:
		ext.set_runtime_clock(true, 0.0)
	var committed: bool = ext.get_runtime_thread_report().get("simulation_committed_day", -1) == day
	_expect("rules day %d commits" % day, committed)
	return committed

func _instance(ext: Object, program: String, id: int, target: int) -> Dictionary:
	return ext.queue_effect_pod_instance({"instance_id": id, "generation": 1,
		"program_key": program, "source_id": id, "source_handle": target,
		"target_handle": target, "target_generation": 1, "next_due_day": 1, "active": true})

func _event(ext: Object, id: int) -> Dictionary:
	return ext.submit_trigger_events({"event_ids": PackedInt64Array([id]),
		"source_ids": PackedInt32Array([1]), "days": PackedInt64Array([1]),
		"event_types": PackedInt32Array([7]), "payload_schemas": PackedInt32Array([0]),
		"entity_handles": PackedInt64Array([0]), "group_handles": PackedInt64Array([0]),
		"values": PackedInt64Array([1]), "payload_i0": PackedInt64Array([0]),
		"payload_i1": PackedInt64Array([0]), "payload_i2": PackedInt64Array([0]),
		"payload_i3": PackedInt64Array([0])})

func _effect_rules(country: Dictionary, inline_mode: bool) -> void:
	_mask = 0x867
	var ext := DCWorldExt.new()
	ext.create_entities(2)
	for variant in 3:
		# Change definitions once, then rebuild again with the same definitions.
		var rules := _rules(mini(variant, 1))
		if variant < 2:
			_configure_rules(ext, rules)
		if variant > 0:
			_expect("old world admits a decoy Effect input", _instance(ext, rules.program, 9000, 4294967296).get("ok", false))
		_setup_country(ext, country, 100 + variant)
		_expect("Effect world starts", ext.start_runtime_worker(_configuration(inline_mode)).get("ok", false))
		var target := int(ext.get_country_cell_summary(0).get("country_handle", 0))
		_expect("new world begins without old bonuses", is_equal_approx(ext.evaluate_modifier_stat(1, target, 0, RULE_STAT, 0.0), 0.0))
		_expect("new world resolves its current Effect program", _instance(ext, rules.program, 100 + variant, target).get("ok", false))
		if await _advance(ext, inline_mode, 1):
			var applied: Dictionary = ext.apply_runtime_modifier_snapshot(0)
			if not applied.get("ok", false): print("[world-rules] snapshot: ", applied)
			_expect("new Modifier snapshot applies", applied.get("ok", false))
			_expect("Effect applies exactly its new definition", is_equal_approx(ext.evaluate_modifier_stat(1, target, 0, RULE_STAT, 0.0), float(rules.bonus)))
			var report: Dictionary = ext.get_runtime_thread_report()
			_expect("Effect and Modifier are both active", report.get("effect_pod_ready", false) and report.get("modifier_pod_ready", false))
			var effect_applied: Dictionary = ext.apply_runtime_effect_snapshot(0)
			_expect("new Effect snapshot applies", effect_applied.get("ok", false))
			var instance: Dictionary = ext.explain_effect(100 + variant)
			_expect("the current Effect program actually ran", instance.get("ok", false) and instance.get("program_key", "") == rules.program and instance.get("next_due_day", 0) == 2)
			_expect("old Effect input is absent from the new world", not ext.explain_effect(9000).get("ok", true))
		await _stop(ext)
		_expect("same-world rule executor restarts", ext.start_runtime_worker(_configuration(not inline_mode)).get("ok", false))
		if await _advance(ext, not inline_mode, 2):
			var resumed_modifier: Dictionary = ext.apply_runtime_modifier_snapshot(0)
			_expect("same-world Modifier snapshot advances", resumed_modifier.get("ok", false) and resumed_modifier.get("applied", false))
			_expect("same-world bonus survives executor replacement", is_equal_approx(ext.evaluate_modifier_stat(1, target, 0, RULE_STAT, 0.0), float(rules.bonus)))
			var resumed_effect: Dictionary = ext.apply_runtime_effect_snapshot(0)
			_expect("same-world Effect snapshot advances", resumed_effect.get("ok", false) and resumed_effect.get("applied", false))
			_expect("same-world Effect continues its previous instance", ext.explain_effect(100 + variant).get("next_due_day", 0) == 3)
		await _stop(ext)

func _trigger_rules(country: Dictionary, inline_mode: bool) -> void:
	_mask = 0x80f
	var ext := DCWorldExt.new()
	for variant in 3:
		var rules := _rules(mini(variant, 1))
		if variant < 2:
			_configure_rules(ext, rules)
		if variant > 0:
			_expect("old world admits a decoy Trigger event", _event(ext, 9000).get("ok", false))
		_setup_country(ext, country, 200 + variant)
		_expect("Trigger world starts", ext.start_runtime_worker(_configuration(inline_mode)).get("ok", false))
		_expect("new Trigger world accepts event one", _event(ext, 1).get("ok", false))
		if await _advance(ext, inline_mode, 1):
			var intent: Dictionary = ext.poll_trigger_worker_intent()
			_expect("new Trigger rule emits its result", intent.get("available", false))
			_expect("new Trigger result has the current authored value", int(intent.get("value", -1)) == int(rules.event_value))
			_expect("new world has no old Trigger results", not ext.poll_trigger_worker_intent().get("available", true))
			_expect("Trigger is configured even when an ACK is pending", ext.get_runtime_thread_report().get("trigger_pod_fallback_reason", "") != "trigger_pod_not_configured")
			_expect("new Trigger result accepts its acknowledgement", ext.submit_trigger_worker_ack(intent).get("ok", false))
			if await _advance(ext, inline_mode, 2):
				var applied: Dictionary = ext.apply_runtime_trigger_snapshot(0)
				if not applied.get("applied", false): print("[world-rules] Trigger snapshot: ", applied)
				_expect("new Trigger snapshot applies", applied.get("ok", false) and applied.get("applied", false))
		await _stop(ext)

func _production_rules(country: Dictionary, inline_mode: bool) -> void:
	_mask = 0x86f
	var effects: Dictionary = preload("res://scripts/effect/effect_domain_catalog.gd").build().compile_native_catalog()
	var triggers: Dictionary = TriggerCatalog.load_default().compile_native_catalog()
	var modifiers: Dictionary = ModifierCatalog.load_default().compile_native_catalog()
	var ideology: Dictionary = preload("res://scripts/ideology/ideology_catalog.gd").load_default().compile_native_catalog(country, country)
	_expect("production Ideology rules compile", ideology.get("ok", false))
	ideology.erase("ok")
	ideology.world_seed = 12345
	var ext := DCWorldExt.new()
	for variant in 3:
		if variant > 0:
			var rejected: Dictionary = ext.configure_country({}, {"country_runtime_mode": "ACTIVE"}, 2, 999)
			_expect("invalid world is rejected with rules intact", not rejected.get("ok", true))
			_expect("the previous rule world restarts after rejection", ext.start_runtime_worker(_configuration(inline_mode)).get("ok", false))
			await _advance(ext, inline_mode, 2)
			var retained: Dictionary = ext.get_runtime_thread_report()
			_expect("rejection preserves every running rule owner", retained.get("effect_pod_ready", false) and retained.get("modifier_pod_ready", false) and retained.get("trigger_pod_ready", false))
			await _stop(ext)
		# Also allow a new world to reuse its already-validated rule definitions.
		if variant < 2:
			_configure_rules(ext, {"modifier": modifiers, "effect": effects, "trigger": triggers})
		_setup_country(ext, country, 300 + variant)
		if variant == 0:
			var configured: Dictionary = ext.configure_ideologies(ideology)
			_expect("production Ideology worker rules configure", configured.get("ok", false) and configured.get("worker_shadow_configured", false))
		_expect("production rule world starts", ext.start_runtime_worker(_configuration(inline_mode)).get("ok", false))
		if await _advance(ext, inline_mode, 1):
			var report: Dictionary = ext.get_runtime_thread_report()
			_expect("all production rule owners remain ready", report.get("effect_pod_ready", false) and report.get("modifier_pod_ready", false) and report.get("trigger_pod_ready", false))
			await _save_rule_sections(ext, 800 + variant)
		await _stop(ext)

func _save_rule_sections(ext: Object, request: int) -> void:
	_expect("configured rule world accepts a save", ext.request_runtime_save(request).get("ok", false))
	var deadline := Time.get_ticks_msec() + 3000
	var saved := {}
	while Time.get_ticks_msec() < deadline:
		saved = ext.poll_runtime_save(request)
		if saved.get("ready", false) or not saved.get("ok", true):
			break
		await process_frame
	_expect("rebuilt rule world reaches a save boundary", saved.get("ready", false))
	_expect("rebuilt world retains its configured Ideology rules", int(saved.get("ideology_bytes", 0)) > 0)
