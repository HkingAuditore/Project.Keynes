class_name EffectFacade
extends RefCounted

signal transactions_available(batch: Dictionary)

const EffectCatalogScript = preload("res://scripts/effect/effect_catalog.gd")

var _world_ext: Object
var _clock: WorldClock
var _catalog: Resource
var _configured := false
var _last_transaction_id := 0
var _adapters: Dictionary = {}
var _last_report: Dictionary = {}
var _modifier_pending: Dictionary = {}
var _legacy_fallback_transactions := 0
var _native_claimed_transactions_skipped := 0

func _adapter_ack_bit(action: int) -> int:
	return (1 << (action - 1)) if action >= 1 and action <= 6 else 0

func configure(world_ext: Object, clock: WorldClock = null,
		catalog: Resource = null) -> Dictionary:
	_world_ext = world_ext
	_clock = clock
	_catalog = catalog if catalog != null else EffectCatalogScript.load_default()
	if _world_ext == null or not _world_ext.has_method("configure_effects"):
		return {"ok": false, "reason": "DCWorldExt effect API unavailable"}
	if _catalog == null or not _catalog.has_method("compile_native_catalog"):
		return {"ok": false, "reason": "EffectCatalog unavailable"}
	var compiled: Dictionary = _catalog.compile_native_catalog()
	if not bool(compiled.get("ok", false)):
		return compiled
	compiled.erase("ok")
	var result: Dictionary = _world_ext.configure_effects(compiled)
	_configured = bool(result.get("ok", false))
	_last_transaction_id = 0
	_modifier_pending.clear()
	_legacy_fallback_transactions = 0
	_native_claimed_transactions_skipped = 0
	return result

func register_adapter(action: int, domain: int, command_key: StringName,
		adapter: Callable) -> void:
	if adapter.is_valid():
		_adapters[_adapter_key(action, domain, command_key)] = adapter


func register_domain_adapters(modifier_facade: ModifierFacade = null,
		country_facade: CountryFacade = null,
		economy_facade: EconomyFacade = null) -> void:
	# Technology and family/person commands intentionally terminate at the
	# existing Modifier Runtime queue. Effect Runtime never mutates a domain
	# store directly; the adapter only creates the domain command.
	if modifier_facade != null:
		register_adapter(1, ModifierFacade.Domain.COUNTRY, &"technology.modifier",
			Callable(self, "_adapt_technology_modifier").bind(modifier_facade, country_facade))
		register_adapter(1, ModifierFacade.Domain.ECONOMY, &"family.modifier",
			Callable(self, "_adapt_family_modifier").bind(modifier_facade))
		register_adapter(1, ModifierFacade.Domain.GAMEPLAY, &"person.modifier",
			Callable(self, "_adapt_person_modifier").bind(modifier_facade))


func _adapt_technology_modifier(command: Dictionary, modifier_facade: ModifierFacade,
		country_facade: CountryFacade = null) -> Dictionary:
	if String(command.get("phase", "commit")) == "preflight":
		return {"ok": true, "ack_mask": _adapter_ack_bit(1)}
	var technology_index := int(command.get("transaction", {}).get("source_instance_id", 0)) & 0xffff
	var technology_key := "technology.%d" % technology_index
	if country_facade != null:
		var ids: PackedStringArray = country_facade.native_catalog().get(
			"technology_ids", PackedStringArray())
		if technology_index > 0 and technology_index - 1 < ids.size():
			technology_key = "technology.%s" % String(ids[technology_index - 1]).trim_prefix("tech.")
	return _queue_modifier_once(command, modifier_facade,
		ModifierFacade.Domain.COUNTRY, StringName(technology_key),
		{"domain": ModifierFacade.Domain.COUNTRY, "scope": ModifierFacade.Scope.ENTITY,
		"entity_handle": int(command.get("target_handle", 0))},
		{"type": 0x54454348, "id": technology_index}, -1, 1,
		int(command.get("transaction", {}).get("effective_day", 0)), 180,
		ModifierFacade.Q16_ONE)


func _adapt_family_modifier(command: Dictionary, modifier_facade: ModifierFacade) -> Dictionary:
	if String(command.get("phase", "commit")) == "preflight":
		return {"ok": true, "ack_mask": _adapter_ack_bit(1)}
	var key := String(command.get("definition_key", ""))
	var branch_stable_id := int(command.get("target_handle", 0))
	var settlement_cell := int(command.get("target_generation", -1))
	var magnitude := clampi(int(command.get("value_q16", 0)), 0, 4 * ModifierFacade.Q16_ONE)
	return _queue_modifier_once(command, modifier_facade,
		ModifierFacade.Domain.ECONOMY, StringName(key),
		{"domain": ModifierFacade.Domain.ECONOMY, "scope": ModifierFacade.Scope.GROUP,
		"group_handle": settlement_cell},
		{"type": 0x46414d494c59, "id": branch_stable_id}, -1, 1,
		int(command.get("transaction", {}).get("effective_day", 0)), 160,
		magnitude)


func _adapt_person_modifier(command: Dictionary, modifier_facade: ModifierFacade) -> Dictionary:
	if String(command.get("phase", "commit")) == "preflight":
		return {"ok": true, "ack_mask": _adapter_ack_bit(1)}
	var key := String(command.get("definition_key", ""))
	return _queue_modifier_once(command, modifier_facade,
		ModifierFacade.Domain.GAMEPLAY, StringName(key),
		{"domain": ModifierFacade.Domain.GAMEPLAY, "scope": ModifierFacade.Scope.ENTITY,
		"entity_handle": int(command.get("target_handle", 0))},
		{"type": 0x504552534f4e, "id": int(command.get("transaction", {}).get("source_instance_id", 0))},
		-1, 1, int(command.get("transaction", {}).get("effective_day", 0)), 170,
		maxi(1, int(command.get("value_q16", ModifierFacade.Q16_ONE))))


func _queue_modifier_once(command: Dictionary, modifier_facade: ModifierFacade,
		domain: int, definition_key: StringName, target: Dictionary,
		source: Dictionary, duration_days: int, initial_stacks: int,
		effective_day: int, producer_id: int, magnitude_q16: int) -> Dictionary:
	var idempotency_key := int(command.get("idempotency_key", 0))
	if idempotency_key == 0:
		return {"ok": false, "reason": "effect_modifier_idempotency_missing"}
	var pending_request := int(_modifier_pending.get(idempotency_key, 0))
	if pending_request > 0:
		var result: Dictionary = modifier_facade.get_command_result(pending_request)
		if bool(result.get("ok", false)):
			_modifier_pending.erase(idempotency_key)
			return {"ok": true, "ack_mask": _adapter_ack_bit(1), "request_id": pending_request}
		if bool(result.get("pending", false)) or String(result.get("reason", "")) == "modifier_request_unknown":
			return {"ok": false, "reason": "effect_modifier_commit_pending",
				"request_id": pending_request}
		# A terminal Modifier rejection remains associated with this Effect
		# idempotency key; do not enqueue a duplicate request on every retry.
		return {"ok": false, "reason": String(result.get("reason", "effect_modifier_rejected")),
			"request_id": pending_request}
	var request_id := modifier_facade.queue_apply(definition_key, target, source,
		duration_days, initial_stacks, effective_day, producer_id, magnitude_q16)
	if request_id <= 0:
		return {"ok": false, "reason": "effect_modifier_enqueue_failed"}
	_modifier_pending[idempotency_key] = request_id
	return {"ok": false, "reason": "effect_modifier_commit_pending",
		"request_id": request_id}

func submit_instances(batch: Dictionary) -> Dictionary:
	return _world_ext.submit_effect_instances(batch) if _configured else {
		"ok": false, "reason": "effect_runtime_unconfigured"}

func submit_family_effect_source(instance_id: int, definition_key: StringName,
		generation: int, source_kind: int, source_id: int, source_handle: int,
		target_handle: int, target_generation: int, activation_sequence: int,
		stack_count: int = 1, level: int = 0, effective_day: int = -1) -> Dictionary:
	## Trait sources are structural Economy authority and deliberately cannot
	## enter through this facade. The other source owners provide their own
	## stable identity and monotonic activation sequence.
	if not _configured:
		return {"ok": false, "reason": "effect_runtime_unconfigured"}
	if instance_id <= 0 or generation <= 0 or source_kind < 1 or source_kind > 5 \
			or source_id == 0 or target_generation <= 0 \
			or activation_sequence <= 0 or stack_count <= 0:
		return {"ok": false, "reason": "family_effect_source_invalid"}
	var stable_key := String(definition_key).strip_edges()
	if stable_key.is_empty():
		return {"ok": false, "reason": "family_effect_definition_missing"}
	if not stable_key.begins_with("family.effect."):
		stable_key = "family.effect.%s" % stable_key
	var day := effective_day
	if day < 0:
		day = _clock.day_index() if _clock != null else 0
	return submit_instances({
		"instance_ids": PackedInt64Array([instance_id]),
		"program_keys": PackedStringArray([stable_key]),
		"generations": PackedInt32Array([generation]),
		"source_types": PackedInt32Array([0x46465800 | source_kind]),
		"source_kinds": PackedInt32Array([source_kind]),
		"source_ids": PackedInt64Array([source_id]),
		"source_handles": PackedInt64Array([source_handle]),
		"target_handles": PackedInt64Array([target_handle]),
		"target_generations": PackedInt32Array([target_generation]),
		"levels": PackedInt32Array([level]),
		"stack_counts": PackedInt32Array([stack_count]),
		"activation_sequences": PackedInt64Array([activation_sequence]),
		"next_due_days": PackedInt64Array([day]),
		"active": PackedByteArray([1]),
	})

func retire_family_effect_source(instance_id: int, generation: int,
		effective_day: int = -1) -> Dictionary:
	if not _configured or instance_id <= 0 or generation <= 0:
		return {"ok": false, "reason": "family_effect_source_invalid"}
	var day := effective_day
	if day < 0:
		day = _clock.day_index() if _clock != null else 0
	return _world_ext.retire_effect_instance(instance_id, generation, day)


func submit_person_modifier_instance(instance_id: int, person_handle: int,
		person_generation: int, definition_key: StringName,
		effective_day: int = -1, active: bool = true) -> Dictionary:
	## PersonStore remains authoritative; this only registers a person-scoped
	## effect instance for the next Effect -> Modifier safe-boundary dispatch.
	if not _configured:
		return {"ok": false, "reason": "effect_runtime_unconfigured"}
	if definition_key.is_empty():
		return {"ok": false, "reason": "person_effect_definition_missing"}
	var day := effective_day
	if day < 0:
		day = _clock.day_index() if _clock != null else 0
	return submit_instances({
		"instance_ids": PackedInt64Array([instance_id]),
		"program_keys": PackedStringArray(["person.modifier.%s" % String(definition_key)]),
		"generations": PackedInt32Array([person_generation]),
		"source_types": PackedInt32Array([0x50455253]),
		"source_ids": PackedInt64Array([instance_id]),
		"source_handles": PackedInt64Array([person_handle]),
		"target_handles": PackedInt64Array([person_handle]),
		"target_generations": PackedInt32Array([person_generation]),
		"levels": PackedInt32Array([0]),
		"next_due_days": PackedInt64Array([day]),
		"active": PackedByteArray([1 if active else 0]),
	})

func submit_snapshots(batch: Dictionary) -> Dictionary:
	return _world_ext.submit_effect_snapshots(batch) if _configured else {
		"ok": false, "reason": "effect_runtime_unconfigured"}

func is_configured() -> bool:
	return _configured

func world_ext() -> Object:
	return _world_ext

func report() -> Dictionary:
	if not _configured:
		return {"configured": false}
	var out: Dictionary = _world_ext.get_effect_report()
	out["legacy_fallback_transactions"] = _legacy_fallback_transactions
	out["native_claimed_transactions_skipped"] = _native_claimed_transactions_skipped
	return out

func explain(instance_id: int) -> Dictionary:
	return _world_ext.explain_effect(instance_id) if _configured else {
		"ok": false, "reason": "effect_runtime_unconfigured"}

func dispatch_transactions() -> Dictionary:
	if not _configured:
		return {"ok": false, "reason": "effect_runtime_unconfigured", "dispatched": 0}
	var batch: Dictionary = _world_ext.poll_effect_transactions(_last_transaction_id, 128)
	if not bool(batch.get("ok", false)):
		return batch
	_native_claimed_transactions_skipped += int(batch.get("native_claimed_transactions", 0))
	var ids: PackedInt64Array = batch.get("transaction_ids", PackedInt64Array())
	if ids.is_empty():
		return {"ok": true, "dispatched": 0, "transactions": 0,
			"native_claimed_transactions": int(batch.get("native_claimed_transactions", 0))}
	var offsets: PackedInt32Array = batch.get("command_offsets", PackedInt32Array([0]))
	var idempotency_keys: PackedInt64Array = batch.get(
		"command_idempotency_keys", PackedInt64Array())
	var dispatched := 0
	var missing := 0
	var contiguous_cursor := _last_transaction_id
	for tx_index in range(ids.size()):
		var required := int(batch.required_ack_masks[tx_index])
		var received := int(batch.received_ack_masks[tx_index])
		var ack_mask := received
		var transaction_id := int(ids[tx_index])
		var status := int(batch.statuses[tx_index])
		var tx := {
			"transaction_id": transaction_id,
			"source_instance_id": int(batch.source_instance_ids[tx_index]),
			"effective_day": int(batch.effective_days[tx_index]),
		}
		var begin := int(offsets[tx_index])
		var end := int(offsets[tx_index + 1])
		var all_ok := true
		var commands: Array[Dictionary] = []
		var adapters: Array[Callable] = []
		for command_index in range(begin, end):
			var action := int(batch.command_actions[command_index])
			var domain := int(batch.command_domains[command_index])
			var command_key := StringName(batch.command_keys[command_index])
			var adapter: Callable = _find_adapter(action, domain, command_key)
			if not adapter.is_valid():
				all_ok = false
				missing += 1
				continue
			var command := {
				"action": action,
				"domain": domain,
				"opcode": int(batch.command_opcodes[command_index]),
				"target_handle": int(batch.command_targets[command_index]),
				"target_generation": int(batch.command_target_generations[command_index]),
				"value_q16": int(batch.command_values_q16[command_index]),
				"duration_days": int(batch.command_duration_days[command_index]),
				"stacks": int(batch.command_stacks[command_index]),
				"command_key": command_key,
				"definition_key": StringName(batch.command_definition_keys[command_index]),
				"payload_i0": int(batch.command_payload_i0[command_index]),
				"payload_i1": int(batch.command_payload_i1[command_index]),
				"payload_i2": int(batch.command_payload_i2[command_index]),
				"payload_i3": int(batch.command_payload_i3[command_index]),
				"idempotency_key": int(idempotency_keys[command_index]) \
					if command_index < idempotency_keys.size() else 0,
				"transaction": tx,
			}
			commands.append(command)
			adapters.append(adapter)
		if not all_ok:
			# Preserve the contiguous-prefix cursor. A missing adapter remains
			# pollable and blocks later transactions until the adapter is present.
			break

		# Adapters preflight without mutation, then commit at their own safe
		# boundary. They must deduplicate `idempotency_key` across retries.
		if required != 0 and status == 1: # PLANNED
			for command_index in range(commands.size()):
				var preflight_command: Dictionary = commands[command_index].duplicate(true)
				preflight_command["phase"] = &"preflight"
				var preflight_result = adapters[command_index].call(preflight_command)
				if not (preflight_result is Dictionary and bool(preflight_result.get("ok", false))):
					all_ok = false
					break
			if not all_ok:
				break
			var preflight: Dictionary = _world_ext.preflight_effect_transactions({
				"transaction_ids": PackedInt64Array([transaction_id]),
				"ack_masks": PackedInt32Array([required]),
			})
			if not bool(preflight.get("ok", false)):
				break
			status = 2 # PREFLIGHTED
		for command_index in range(commands.size()):
			var commit_command: Dictionary = commands[command_index].duplicate(true)
			commit_command["phase"] = &"commit"
			var result = adapters[command_index].call(commit_command)
			var action := int(commands[command_index].get("action", 0))
			if result is Dictionary and bool(result.get("ok", false)):
				var bit := int(result.get("ack_mask", _adapter_ack_bit(action)))
				ack_mask |= bit
			else:
				all_ok = false
		if all_ok and (ack_mask & required) == required:
			if required != 0 and status == 2: # PREFLIGHTED -> COMMITTED
				var committed: Dictionary = _world_ext.commit_effect_transactions({
					"transaction_ids": PackedInt64Array([transaction_id]),
					"ack_masks": PackedInt32Array([required]),
				})
				if not bool(committed.get("ok", false)):
					break
			var acked: Dictionary = _world_ext.ack_effect_transactions({
				"transaction_ids": PackedInt64Array([transaction_id]),
				"ack_masks": PackedInt32Array([ack_mask]),
			})
			if not bool(acked.get("ok", false)):
				break
			dispatched += 1
			contiguous_cursor = transaction_id
		else:
			# A failed adapter leaves the transaction PREFLIGHTED/COMMITTED and
			# keeps it pollable for an idempotent retry on the next safe boundary.
			break
	_last_transaction_id = contiguous_cursor
	_legacy_fallback_transactions += dispatched
	transactions_available.emit(batch)
	return {"ok": true, "dispatched": dispatched, "transactions": ids.size(),
		"missing_adapters": missing, "last_transaction_id": _last_transaction_id,
		"native_claimed_transactions": int(batch.get("native_claimed_transactions", 0))}

func _adapter_key(action: int, domain: int, command_key: StringName) -> String:
	return "%d:%d:%s" % [action, domain, String(command_key)]

func _find_adapter(action: int, domain: int, command_key: StringName) -> Callable:
	var exact: Callable = _adapters.get(_adapter_key(action, domain, command_key), Callable())
	if exact is Callable and exact.is_valid():
		return exact
	var domain_default: Callable = _adapters.get(_adapter_key(action, domain, &""), Callable())
	return domain_default if domain_default is Callable else Callable()
