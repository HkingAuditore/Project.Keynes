class_name TriggerFacade
extends RefCounted

signal effects_available(batch: Dictionary)

const TriggerCatalogScript = preload("res://scripts/trigger/trigger_catalog.gd")
const GameplayEventBusScript = preload("res://scripts/data_core/gameplay_event_bus.gd")

enum Action { MODIFIER_APPLY = 1, MODIFIER_REMOVE = 2, MODIFIER_REFRESH = 3,
	MODIFIER_SET_STACKS = 4, COUNTRY_COMMAND = 10, ECONOMY_COMMAND = 11,
	GAMEPLAY_COMMAND = 12, PUBLISH_EVENT = 13, CUSTOM_DOMAIN_COMMAND = 14 }

var _world_ext: Object
var _clock: WorldClock
var _event_bus: GameplayEventBus
var _modifier_facade: ModifierFacade
var _catalog: Resource
var _configured := false
var _event_consumer: StringName = &"trigger_runtime"
var _last_effect_id := 0
var _adapters: Dictionary = {}
var _last_report: Dictionary = {}

func configure(world_ext: Object, event_bus: GameplayEventBus, clock: WorldClock = null,
		modifier_facade: ModifierFacade = null, catalog: Resource = null) -> Dictionary:
	_world_ext = world_ext; _event_bus = event_bus; _clock = clock
	_modifier_facade = modifier_facade
	_catalog = catalog if catalog != null else TriggerCatalogScript.load_default()
	if _world_ext == null or not _world_ext.has_method("configure_triggers"):
		return {"ok": false, "reason": "DCWorldExt trigger API unavailable"}
	if _catalog == null or not _catalog.has_method("compile_native_catalog"):
		return {"ok": false, "reason": "TriggerCatalog unavailable"}
	var compiled: Dictionary = _catalog.compile_native_catalog()
	if not bool(compiled.get("ok", false)): return compiled
	compiled.erase("ok")
	var result: Dictionary = _world_ext.configure_triggers(compiled)
	_configured = bool(result.get("ok", false))
	_last_effect_id = 0
	return result

func register_effect_adapter(action: int, adapter: Callable) -> void:
	if adapter.is_valid(): _adapters[action] = adapter

func register_domain_effect_adapter(action: int, domain: int,
		command_key: StringName, adapter: Callable) -> void:
	if adapter.is_valid():
		_adapters[_adapter_key(action, domain, command_key)] = adapter

func is_configured() -> bool: return _configured
func world_ext() -> Object: return _world_ext
func report() -> Dictionary: return _world_ext.get_trigger_report() if _configured else {"configured": false}

func ingest_committed_events(day_index: int, max_events: int = 512) -> Dictionary:
	if not _configured or _event_bus == null or not _event_bus.is_available():
		return {"ok": false, "reason": "trigger_event_bus_unavailable", "count": 0}
	var raw: Dictionary = _event_bus.poll_events(_event_consumer, max_events, 0, false)
	var ids: PackedInt64Array = raw.get("event_id", PackedInt64Array())
	if ids.is_empty(): return {"ok": true, "count": 0, "accepted": 0}
	var count := ids.size()
	var sources := PackedInt32Array(); var days := PackedInt64Array()
	var types := PackedInt32Array(); var schemas := PackedInt32Array()
	var entities := PackedInt64Array(); var groups := PackedInt64Array(); var values := PackedInt64Array()
	var p0 := PackedInt64Array(); var p1 := PackedInt64Array(); var p2 := PackedInt64Array(); var p3 := PackedInt64Array()
	var source_arr: PackedInt32Array = raw.get("source", PackedInt32Array())
	var type_arr: PackedInt32Array = raw.get("type", PackedInt32Array())
	var schema_arr: PackedInt32Array = raw.get("payload_schema", PackedInt32Array())
	var entity_arr: PackedInt32Array = raw.get("entity_id", PackedInt32Array())
	var entity_handle_arr: PackedInt64Array = raw.get("entity_handle", PackedInt64Array())
	var cell_arr: PackedInt32Array = raw.get("cell_idx", PackedInt32Array())
	var value_arr: PackedInt64Array = raw.get("value_i64", PackedInt64Array())
	var raw_p0: PackedInt32Array = raw.get("payload_i0", PackedInt32Array())
	var raw_p1: PackedInt32Array = raw.get("payload_i1", PackedInt32Array())
	var raw_p2: PackedInt32Array = raw.get("payload_i2", PackedInt32Array())
	var raw_p3: PackedInt32Array = raw.get("payload_i3", PackedInt32Array())
	for i in count:
		sources.append(int(source_arr[i]) if i < source_arr.size() else 0)
		days.append(day_index); types.append(int(type_arr[i]) if i < type_arr.size() else 0)
		schemas.append(int(schema_arr[i]) if i < schema_arr.size() else 0)
		var entity := int(entity_handle_arr[i]) if i < entity_handle_arr.size() else \
			(int(entity_arr[i]) if i < entity_arr.size() else 0)
		var cell := int(cell_arr[i]) if i < cell_arr.size() else 0
		entities.append(entity); groups.append(cell)
		values.append(int(value_arr[i]) if i < value_arr.size() else 1)
		p0.append(int(raw_p0[i]) if i < raw_p0.size() else 0); p1.append(int(raw_p1[i]) if i < raw_p1.size() else 0)
		p2.append(int(raw_p2[i]) if i < raw_p2.size() else 0); p3.append(int(raw_p3[i]) if i < raw_p3.size() else 0)
	var result: Dictionary = _world_ext.submit_trigger_events({
		"count": count, "event_ids": ids, "source_ids": sources, "days": days,
		"event_types": types, "payload_schemas": schemas, "entity_handles": entities,
		"group_handles": groups, "values": values, "payload_i0": p0, "payload_i1": p1,
		"payload_i2": p2, "payload_i3": p3,
	})
	var accepted := int(result.get("accepted", 0))
	# The runtime only advances its source cursor for accepted rows. ACKing the
	# journal at the last accepted row is safe for the synchronous contiguous bus.
	if bool(result.get("ok", false)) and accepted == count:
		_event_bus.ack_events(_event_consumer, int(ids[ids.size() - 1]))
	return result

func dispatch_effects(max_effects: int = 512) -> Dictionary:
	if not _configured: return {"ok": false, "reason": "trigger_runtime_not_configured"}
	var batch: Dictionary = _world_ext.poll_trigger_effects(_last_effect_id, max_effects)
	var ids: PackedInt64Array = batch.get("effect_ids", PackedInt64Array())
	if ids.is_empty(): return {"ok": true, "dispatched": 0, "pending": int(batch.get("count", 0))}
	var dispatched := 0
	for i in ids.size():
		var effect := _effect_at(batch, i)
		if not _dispatch_one(effect): break
		dispatched += 1
		_last_effect_id = int(ids[i])
	if dispatched > 0:
		_world_ext.ack_trigger_effects(_last_effect_id)
	var out := {"ok": dispatched == ids.size(), "dispatched": dispatched, "pending": ids.size() - dispatched}
	effects_available.emit(batch)
	return out

func _effect_at(batch: Dictionary, i: int) -> Dictionary:
	var get_i64 := func(key: String, fallback := 0) -> int: var a: PackedInt64Array = batch.get(key, PackedInt64Array()); return int(a[i]) if i < a.size() else fallback
	var get_i32 := func(key: String, fallback := 0) -> int: var a: PackedInt32Array = batch.get(key, PackedInt32Array()); return int(a[i]) if i < a.size() else fallback
	var get_s := func(key: String) -> String: var a: PackedStringArray = batch.get(key, PackedStringArray()); return String(a[i]) if i < a.size() else ""
	return {"effect_id": get_i64.call("effect_ids"), "effective_day": get_i64.call("effective_days"),
		"source_priority": get_i32.call("source_priorities"), "trigger_id": get_i32.call("trigger_ids"),
		"trigger_key": get_s.call("trigger_keys"), "target_handle": get_i64.call("target_handles"),
		"target_generation": get_i32.call("target_generations"), "fire_sequence": get_i64.call("fire_sequences"),
		"action": get_i32.call("actions"), "domain": get_i32.call("domains"), "opcode": get_i32.call("opcodes"),
		"resolved_value": get_i64.call("resolved_values"), "duration_days": get_i32.call("duration_days", -1),
		"stacks": get_i32.call("stacks", 1), "command_key": get_s.call("command_keys"),
		"definition_key": get_s.call("definition_keys"), "payload_i0": get_i64.call("payload_i0"),
		"payload_i1": get_i64.call("payload_i1"), "payload_i2": get_i64.call("payload_i2"), "payload_i3": get_i64.call("payload_i3")}

func _dispatch_one(effect: Dictionary) -> bool:
	var action := int(effect.action)
	if action == Action.MODIFIER_APPLY and _modifier_facade != null:
		var modifier_key := String(effect.definition_key)
		if modifier_key.is_empty(): modifier_key = String(effect.trigger_key)
		return _modifier_facade.queue_apply(StringName(modifier_key),
			{"domain": int(effect.domain), "scope": 2, "entity_handle": int(effect.target_handle)},
			{"type": 8, "id": int(effect.trigger_id)}, int(effect.duration_days), int(effect.stacks),
			int(effect.effective_day), int(effect.source_priority)) > 0
	if action == Action.MODIFIER_REMOVE or action == Action.MODIFIER_REFRESH or action == Action.MODIFIER_SET_STACKS:
		if _modifier_facade == null: return false
		var domain := int(effect.domain); var handle := int(effect.target_handle); var day := int(effect.effective_day)
		if action == Action.MODIFIER_REMOVE: return _modifier_facade.queue_remove(handle, domain, day, int(effect.source_priority)) > 0
		if action == Action.MODIFIER_REFRESH: return _modifier_facade.queue_refresh(handle, domain, int(effect.duration_days), day, int(effect.source_priority)) > 0
		return _modifier_facade.queue_set_stacks(handle, domain, int(effect.stacks), day, int(effect.source_priority)) > 0
	if action == Action.PUBLISH_EVENT and _event_bus != null:
		var published: Dictionary = _event_bus.publish_event(int(effect.opcode), int(effect.target_handle),
			int(effect.effective_day), 0, GameplayEventBusScript.SOURCE_GDSCRIPT, 0, 0,
			int(effect.payload_i0), int(effect.payload_i1), int(effect.payload_i2), int(effect.payload_i3))
		return int(published.get("published", 0)) > 0
	var adapter_key := _adapter_key(action, int(effect.domain), StringName(effect.command_key))
	var adapter = _adapters.get(adapter_key, _adapters.get(action, Callable()))
	if adapter is Callable and adapter.is_valid():
		var result = adapter.call(effect)
		return bool(result) if result is bool else bool(result.get("ok", false)) if result is Dictionary else false
	return false

func _adapter_key(action: int, domain: int, command_key: StringName) -> StringName:
	return StringName("%d:%d:%s" % [action, domain, String(command_key)])
