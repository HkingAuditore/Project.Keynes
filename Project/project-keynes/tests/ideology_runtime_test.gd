extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const ModifierFacadeScript = preload("res://scripts/modifier/modifier_facade.gd")
const Q16_ONE := 65536

var _checks := 0
var _failures := 0

func _init() -> void:
	_run()
	print("ideology runtime: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("[SKIP] DCWorldExt unavailable")
		return
	var country_ir: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("country catalog compiles", bool(country_ir.get("ok", false)))
	if not bool(country_ir.get("ok", false)):
		return
	var ext := _country_ext(country_ir)
	var modifier := ModifierFacadeScript.new()
	_expect("modifier runtime configures", bool(modifier.configure(ext, 1).get("ok", false)))
	_expect("effect runtime configures", bool(ext.configure_effects(_effect_catalog().compile_native_catalog()).get("ok", false)))
	var country: Dictionary = ext.get_country_cell_summary(0)
	var handle := int(country.get("country_handle", 0))
	_expect("country bootstrap supplies a generation-safe handle", handle != 0)
	var catalog := _catalog()
	_expect("ideology catalog configures", bool(ext.configure_ideologies(catalog).get("ok", false)))
	_expect("discover / points queue", bool(ext.submit_ideology_commands(_commands([
		{"op": 1, "day": 0, "handle": handle, "idea": 0},
		{"op": 2, "day": 0, "handle": handle, "value": 3 * Q16_ONE},
	])).get("ok", false)))
	_expect("initial ideology commands apply", bool(ext.run_ideology_daily(0).get("ok", false)))
	var snapshot: Dictionary = ext.get_ideology_snapshot(handle)
	_expect("discovery keeps inactive idea known", (snapshot.known_ids as PackedInt32Array).has(0)
		and int(snapshot.locations[0]) == 0 and int(snapshot.levels[0]) == 0)
	_expect("offer creates deterministic three unique choices", bool(ext.submit_ideology_commands(_commands([
		{"op": 3, "day": 1, "handle": handle},
	])).get("ok", false)) and bool(ext.run_ideology_daily(1).get("ok", false)))
	snapshot = ext.get_ideology_snapshot(handle)
	var offer: PackedInt32Array = snapshot.offer_ids
	_expect("offer persists and cards are unique", bool(snapshot.offer_active) and offer.size() == 3
		and offer[0] != offer[1] and offer[0] != offer[2] and offer[1] != offer[2])
	var offer_generation := int(snapshot.offer_generation)
	_expect("stale offer generation is rejected", bool(ext.submit_ideology_commands(_commands([
		{"op": 4, "day": 2, "handle": handle, "offer": offer_generation + 1, "choice": 0},
	])).get("ok", false)) and bool(ext.run_ideology_daily(2).get("ok", false))
		and bool(ext.get_ideology_snapshot(handle).offer_active))
	_expect("valid choice resolves the persisted offer", bool(ext.submit_ideology_commands(_commands([
		{"op": 4, "day": 3, "handle": handle, "offer": offer_generation, "choice": 0},
	])).get("ok", false)) and bool(ext.run_ideology_daily(3).get("ok", false))
		and not bool(ext.get_ideology_snapshot(handle).offer_active))
	_expect("equip starts an ACK-gated ideology transition", bool(ext.submit_ideology_commands(_commands([
		{"op": 5, "day": 4, "handle": handle, "idea": 0},
	])).get("ok", false)) and bool(ext.run_ideology_daily(4).get("ok", false)))
	snapshot = ext.get_ideology_snapshot(handle)
	_expect("equipped ideology reserves capacity and reports pending",
		int(snapshot.locations[0]) == 1 and int(snapshot.ideology_slots_used) == 1
		and int(snapshot.understanding_q16[0]) >= Q16_ONE and snapshot.transition_pending[0] != 0
		and snapshot.binding_verified[0] != 0
		and (snapshot.transition_transaction_ids as PackedInt64Array).size() == 1
		and int(snapshot.transition_transaction_statuses[0]) == 1)
	_commit_effect(ext, 4)
	ext.run_ideology_daily(5)
	snapshot = ext.get_ideology_snapshot(handle)
	_expect("tier replacement stays pending until the new Effect ACK", int(snapshot.levels[0]) == 1
		and snapshot.transition_pending[0] != 0)
	_commit_effect(ext, 5)
	ext.run_ideology_daily(6)
	snapshot = ext.get_ideology_snapshot(handle)
	_expect("level confirms only after Effect ACK", int(snapshot.levels[0]) == 1
		and snapshot.transition_pending[0] == 0)
	_expect("promotion is irreversible and releases ideology capacity", bool(ext.submit_ideology_commands(_commands([
		{"op": 7, "day": 7, "handle": handle, "idea": 0},
	])).get("ok", false)) and bool(ext.run_ideology_daily(7).get("ok", false)))
	snapshot = ext.get_ideology_snapshot(handle)
	_expect("national spirit remains active outside ideology slots", int(snapshot.locations[0]) == 2
		and int(snapshot.ideology_slots_used) == 0 and int(snapshot.national_spirit_slots_used) == 1)
	var effect_bytes: PackedByteArray = ext.capture_effect_state()
	_expect("PKEF captures the active ideology external binding", not effect_bytes.is_empty()
		and int(ext.get_effect_report().get("external_bindings", 0)) >= 1)
	var bytes: PackedByteArray = ext.capture_ideology_state()
	_expect("PKID capture is nonempty", not bytes.is_empty())
	var restored := _country_ext(country_ir)
	var restored_modifier := ModifierFacadeScript.new()
	_expect("restored modifier runtime configures", bool(restored_modifier.configure(restored, 1).get("ok", false)))
	_expect("restored effect runtime configures", bool(restored.configure_effects(_effect_catalog().compile_native_catalog()).get("ok", false)))
	_expect("restored ideology catalog configures", bool(restored.configure_ideologies(catalog).get("ok", false)))
	_expect("PKID rejects an active idea without its PKEF binding", not bool(restored.restore_ideology_state(bytes).get("ok", true)))
	_expect("PKEF then PKID round trip restores exact snapshot", bool(restored.restore_effect_state(effect_bytes).get("ok", false))
		and bool(restored.restore_ideology_state(bytes).get("ok", false))
		and int(restored.get_ideology_snapshot(handle).locations[0]) == 2)
	_expect("additional ideology discovery/equip queues a strict pending source",
		bool(ext.submit_ideology_commands(_commands([
			{"op": 1, "day": 8, "handle": handle, "idea": 1},
			{"op": 5, "day": 8, "handle": handle, "idea": 1},
		])).get("ok", false)) and bool(ext.run_ideology_daily(8).get("ok", false)))
	var pending_effect_bytes: PackedByteArray = ext.capture_effect_state()
	var pending_ideology_bytes: PackedByteArray = ext.capture_ideology_state()
	var pending_restored := _country_ext(country_ir)
	var pending_modifier := ModifierFacadeScript.new()
	_expect("pending restore modifier configures", bool(pending_modifier.configure(pending_restored, 1).get("ok", false)))
	_expect("pending restore Effect configures", bool(pending_restored.configure_effects(_effect_catalog().compile_native_catalog()).get("ok", false)))
	_expect("pending restore Ideology configures", bool(pending_restored.configure_ideologies(catalog).get("ok", false)))
	_expect("matching PKEF pending transactions restore with PKID", bool(pending_restored.restore_effect_state(pending_effect_bytes).get("ok", false))
		and bool(pending_restored.restore_ideology_state(pending_ideology_bytes).get("ok", false)))
	var stale_restored := _country_ext(country_ir)
	var stale_modifier := ModifierFacadeScript.new()
	_expect("stale restore modifier configures", bool(stale_modifier.configure(stale_restored, 1).get("ok", false)))
	_expect("stale restore Effect configures", bool(stale_restored.configure_effects(_effect_catalog().compile_native_catalog()).get("ok", false)))
	_expect("stale restore Ideology configures", bool(stale_restored.configure_ideologies(catalog).get("ok", false)))
	_expect("PKID rejects an unknown pending ideology transaction", bool(stale_restored.restore_effect_state(pending_effect_bytes).get("ok", false))
		and not bool(stale_restored.restore_ideology_state(bytes).get("ok", true)))
	_test_effect_link_after_ideology_configuration(country_ir, catalog)
	_test_native_publish_event_adapter(country_ir)


func _test_effect_link_after_ideology_configuration(country_ir: Dictionary, catalog: Dictionary) -> void:
	# Production startup configures Country + Ideology before the shared Effect
	# catalog. This regression fixture verifies that the later Effect configure
	# call attaches to an already-created NativeIdeologyRuntime.
	var ext := _country_ext(country_ir)
	var modifier := ModifierFacadeScript.new()
	_expect("late-link modifier runtime configures", bool(modifier.configure(ext, 1).get("ok", false)))
	_expect("ideology configures before EffectRuntime", bool(ext.configure_ideologies(catalog).get("ok", false)))
	_expect("EffectRuntime links to existing ideology runtime", bool(ext.configure_effects(_effect_catalog().compile_native_catalog()).get("ok", false)))
	var country: Dictionary = ext.get_country_cell_summary(0)
	var handle := int(country.get("country_handle", 0))
	_expect("late-link discover queues", bool(ext.submit_ideology_commands(_commands([
		{"op": 1, "day": 0, "handle": handle, "idea": 0},
		{"op": 5, "day": 1, "handle": handle, "idea": 0},
	])).get("ok", false)))
	ext.run_ideology_daily(0)
	ext.run_ideology_daily(1)
	var snapshot: Dictionary = ext.get_ideology_snapshot(handle)
	_expect("late-linked equip starts its Effect transition", int(snapshot.locations[0]) == 1 \
		and int(snapshot.transition_pending[0]) != 0)

func _test_native_publish_event_adapter(country_ir: Dictionary) -> void:
	var ext := _country_ext(country_ir)
	var modifier := ModifierFacadeScript.new()
	_expect("event adapter modifier runtime configures", bool(modifier.configure(ext, 1).get("ok", false)))
	_expect("event adapter EffectRuntime configures", bool(ext.configure_effects(_event_effect_catalog().compile_native_catalog()).get("ok", false)))
	var catalog := _catalog()
	catalog.level_on_enter_offsets = PackedInt32Array([0, 3, 3, 3, 3, 3])
	catalog.on_enter_actions = PackedInt32Array([4, 5, 6])
	catalog.on_enter_domains = PackedInt32Array([3, 4, 6])
	catalog.on_enter_opcodes = PackedInt32Array([8001, 7001, 1])
	catalog.on_enter_values_q16 = PackedInt64Array([16, 17, 18])
	catalog.on_enter_duration_days = PackedInt32Array([-1, -1, -1])
	catalog.on_enter_stacks = PackedInt32Array([1, 1, 1])
	catalog.on_enter_command_keys = PackedStringArray(["ideology.test_gameplay", "ideology.test_event", "ideology.test_custom"])
	catalog.on_enter_definition_keys = PackedStringArray(["ideology.test_gameplay", "ideology.test_event", "ideology.test_custom"])
	catalog.on_enter_payload_i0 = PackedInt64Array([10, 11, 12])
	catalog.on_enter_payload_i1 = PackedInt64Array([20, 12, 13])
	catalog.on_enter_payload_i2 = PackedInt64Array([30, 13, 14])
	catalog.on_enter_payload_i3 = PackedInt64Array([40, 14, 15])
	_expect("event/gameplay/custom adapter ideology catalog configures", bool(ext.configure_ideologies(catalog).get("ok", false)))
	var handle := int(ext.get_country_cell_summary(0).get("country_handle", 0))
	_expect("event adapter queues discovery/equip", bool(ext.submit_ideology_commands(_commands([
		{"op": 1, "day": 0, "handle": handle, "idea": 0},
		{"op": 5, "day": 1, "handle": handle, "idea": 0},
	])).get("ok", false)))
	ext.run_ideology_daily(0)
	ext.run_ideology_daily(1)
	_expect("event adapter evaluates", bool(ext.run_effect_daily(1).get("ok", false)))
	_expect("event adapter dispatches native modifier", int(ext.dispatch_effect_native_modifier().get("submitted_transactions", 0)) == 1)
	var gameplay_dispatch: Dictionary = ext.dispatch_effect_native_gameplay()
	_expect("event/gameplay/custom dispatches native gameplay", int(gameplay_dispatch.get("submitted_transactions", 0)) == 3
		and int(gameplay_dispatch.get("submitted_commands", 0)) == 3)
	var poll: Dictionary = ext.poll_effect_transactions(0, 16)
	_expect("native ideology transactions never enter GDScript fallback polling",
		int(poll.get("count", 0)) == 0 and int(poll.get("native_claimed_transactions", 0)) >= 2)
	ext.run_modifier_daily(1)
	ext.ack_effect_native_modifier()
	var gameplay: Dictionary = ext.run_gameplay_effects(1)
	_expect("Gameplay/PublishEvent/Custom commits exactly once to the native journal",
		bool(gameplay.get("ok", false)) and int(gameplay.get("committed", 0)) == 3)
	_expect("native gameplay ACK succeeds", int(ext.ack_effect_native_gameplay().get("acknowledged", 0)) == 3)
	ext.run_ideology_daily(2)
	var journal: Dictionary = ext.snapshot_gameplay_event_journal({})
	_expect("journal persists Effect idempotency evidence", int(journal.get("version", 0)) == 4
		and (journal.effect_idempotency_keys as PackedInt64Array).size() == 3)
	var journal_restored: Object = ClassDB.instantiate("DCWorldExt")
	_expect("journal restores Effect idempotency evidence", bool(journal_restored.restore_gameplay_event_journal(journal).get("ok", false))
		and int(journal_restored.get_gameplay_event_bus_report().get("effect_idempotency_count", 0)) == 3)

func _country_ext(country_ir: Dictionary) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(1)
	var catalog := country_ir.duplicate(true)
	catalog.erase("ok")
	var profile := {"country_runtime_mode": "ACTIVE", "starting_technology_ids": PackedStringArray(["tech.hunting"])}
	assert(bool(ext.configure_country(catalog, profile, 1, 97).get("ok", false)))
	assert(bool(ext.bootstrap_country({}, PackedByteArray([0])).get("ok", false)))
	return ext

func _catalog() -> Dictionary:
	var ids := PackedStringArray(["idea.alpha", "idea.beta", "idea.gamma", "idea.delta"])
	var levels := PackedInt64Array([0, 2 * Q16_ONE, 0, 0, 0])
	return {
		"protocol_version": 1, "ideology_capacity": 2, "national_spirit_capacity": 1,
		"offer_choice_count": 3, "offer_cost_q16": Q16_ONE, "max_commands_per_slice": 64,
		"ideology_ids": ids, "acquisition_flags": PackedByteArray([3, 2, 2, 2]),
		"rarity_weights": PackedInt32Array([1, 1, 1, 1]),
		"ideology_slot_costs": PackedInt32Array([1, 1, 1, 1]),
		"spirit_slot_costs": PackedInt32Array([1, 1, 1, 1]),
		"national_spirit_min_levels": PackedInt32Array([1, 0, 0, 0]),
		"level_offsets": PackedInt32Array([0, 2, 3, 4, 5]),
		"level_thresholds_q16": levels,
		"level_daily_understanding_q16": PackedInt64Array([Q16_ONE, Q16_ONE, 0, 0, 0]),
		"technology_requirement_offsets": PackedInt32Array([0, 0, 0, 0, 0]),
		"technology_requirements": PackedInt32Array(),
		"signal_requirement_offsets": PackedInt32Array([0, 0, 0, 0, 0]),
		"signal_requirements": PackedInt32Array(),
		"gate_requirement_offsets": PackedInt32Array([0, 0, 0, 0, 0]),
		"gate_requirements": PackedInt32Array(),
		"level_persistent_offsets": PackedInt32Array([0, 1, 2, 3, 3, 3]),
		"persistent_actions": PackedInt32Array([1, 1, 1]), "persistent_domains": PackedInt32Array([1, 1, 1]),
		"persistent_opcodes": PackedInt32Array([1, 1, 1]), "persistent_values_q16": PackedInt64Array([Q16_ONE, 2 * Q16_ONE, Q16_ONE]),
		"persistent_duration_days": PackedInt32Array([-1, -1, -1]), "persistent_stacks": PackedInt32Array([1, 1, 1]),
		"persistent_command_keys": PackedStringArray(["ideology.persistent", "ideology.persistent", "ideology.persistent"]), "persistent_definition_keys": PackedStringArray(["country.economic_mobilization", "country.economic_mobilization", "country.economic_mobilization"]),
		"persistent_payload_i0": PackedInt64Array([0, 0, 0]), "persistent_payload_i1": PackedInt64Array([0, 0, 0]),
		"persistent_payload_i2": PackedInt64Array([0, 0, 0]), "persistent_payload_i3": PackedInt64Array([0, 0, 0]),
		"level_on_enter_offsets": PackedInt32Array([0, 0, 0, 0, 0, 0]),
		"on_enter_actions": PackedInt32Array(), "on_enter_domains": PackedInt32Array(),
		"on_enter_opcodes": PackedInt32Array(), "on_enter_values_q16": PackedInt64Array(),
		"on_enter_duration_days": PackedInt32Array(), "on_enter_stacks": PackedInt32Array(),
		"on_enter_command_keys": PackedStringArray(), "on_enter_definition_keys": PackedStringArray(),
		"on_enter_payload_i0": PackedInt64Array(), "on_enter_payload_i1": PackedInt64Array(),
		"on_enter_payload_i2": PackedInt64Array(), "on_enter_payload_i3": PackedInt64Array(),
	}

func _effect_catalog() -> Resource:
	var catalog := EffectCatalog.new()
	var definition := EffectDefinition.new()
	definition.key = &"ideology.command"
	definition.cadence_days = 3650
	var end := EffectInstruction.new()
	end.op = 12
	definition.instructions = [end]
	var command := EffectCommand.new()
	command.action = 1
	command.domain = 1
	command.opcode = 1
	command.target_resolver = 1
	command.value_mode = 0
	command.command_key = &"ideology.persistent"
	command.definition_key = &"country.economic_mobilization"
	definition.commands = [command]
	catalog.definitions = [definition]
	return catalog

func _event_effect_catalog() -> Resource:
	var catalog := _effect_catalog()
	var definition: EffectDefinition = catalog.definitions[0]
	var gameplay := EffectCommand.new()
	gameplay.action = 4 # native Gameplay consumer
	gameplay.domain = 3
	gameplay.opcode = 8001
	gameplay.target_resolver = 1
	gameplay.value_mode = 0
	gameplay.value_q16 = 16
	gameplay.duration_days = -1
	gameplay.stacks = 1
	gameplay.command_key = &"ideology.test_gameplay"
	gameplay.definition_key = &"ideology.test_gameplay"
	gameplay.payload_i0 = 10
	gameplay.payload_i1 = 20
	gameplay.payload_i2 = 30
	gameplay.payload_i3 = 40
	var event := EffectCommand.new()
	event.action = 5 # PUBLISH_EVENT
	event.domain = 4 # native Gameplay journal adapter
	event.opcode = 7001
	event.target_resolver = 1
	event.value_mode = 0
	event.value_q16 = 17
	event.duration_days = -1
	event.stacks = 1
	event.command_key = &"ideology.test_event"
	event.definition_key = &"ideology.test_event"
	event.payload_i0 = 11
	event.payload_i1 = 12
	event.payload_i2 = 13
	event.payload_i3 = 14
	var custom := EffectCommand.new()
	custom.action = 6 # registered CustomDomain audit consumer
	custom.domain = 6
	custom.opcode = 1
	custom.target_resolver = 1
	custom.value_mode = 0
	custom.value_q16 = 18
	custom.duration_days = -1
	custom.stacks = 1
	custom.command_key = &"ideology.test_custom"
	custom.definition_key = &"ideology.test_custom"
	custom.payload_i0 = 12
	custom.payload_i1 = 13
	custom.payload_i2 = 14
	custom.payload_i3 = 15
	definition.commands.append(gameplay)
	definition.commands.append(event)
	definition.commands.append(custom)
	return catalog

func _commit_effect(ext: Object, day: int) -> void:
	_expect("effect evaluates ideology transaction", bool(ext.run_effect_daily(day).get("ok", false)))
	var dispatch: Dictionary = ext.dispatch_effect_native_modifier()
	_expect("effect dispatches native ideology modifier", bool(dispatch.get("ok", false))
		and int(dispatch.get("submitted_transactions", 0)) > 0)
	var fallback_poll: Dictionary = ext.poll_effect_transactions(0, 16)
	_expect("native ideology modifier is excluded from GDScript fallback polling",
		int(fallback_poll.get("count", 0)) == 0 and int(fallback_poll.get("native_claimed_transactions", 0)) > 0)
	_expect("modifier commits ideology transaction", bool(ext.run_modifier_daily(day).get("ok", false)))
	_expect("effect observes ideology modifier ACK", bool(ext.ack_effect_native_modifier().get("ok", false)))

func _commands(rows: Array[Dictionary]) -> Dictionary:
	var out := {"opcodes": PackedInt32Array(), "effective_days": PackedInt64Array(),
		"source_priorities": PackedInt32Array(), "sequences": PackedInt64Array(),
		"country_handles": PackedInt64Array(), "ideology_ids": PackedInt32Array(),
		"values_q16": PackedInt64Array(), "offer_generations": PackedInt64Array(),
		"choice_indices": PackedInt32Array(), "gate_ids": PackedInt32Array()}
	for row in rows:
		out.opcodes.append(int(row.op)); out.effective_days.append(int(row.day))
		out.source_priorities.append(0); out.sequences.append(int(row.day) + int(row.op))
		out.country_handles.append(int(row.handle)); out.ideology_ids.append(int(row.get("idea", -1)))
		out.values_q16.append(int(row.get("value", 0))); out.offer_generations.append(int(row.get("offer", 0)))
		out.choice_indices.append(int(row.get("choice", -1))); out.gate_ids.append(-1)
	return out

func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if condition:
		print("  [OK] %s" % label)
	else:
		_failures += 1
		push_error("[FAIL] %s" % label)
