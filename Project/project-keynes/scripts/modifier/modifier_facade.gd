class_name ModifierFacade
extends RefCounted

signal modifier_events_available(batch: Dictionary)

enum Domain { CLIMATE, COUNTRY, ECONOMY, GAMEPLAY }
enum Scope { GLOBAL, GROUP, ENTITY }
enum Opcode { APPLY = 1, REMOVE = 2, REFRESH = 3, SET_STACKS = 4 }

const PROTOCOL_VERSION := 1
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")

var _world_ext: Object
var _clock: WorldClock
var _catalog: Resource
var _configured := false
var _producer_sequence := 0
var _last_event_id := 0


func configure(world_ext: Object, cell_count: int, clock: WorldClock = null,
		catalog: Resource = null) -> Dictionary:
	_world_ext = world_ext
	_clock = clock
	_catalog = catalog if catalog != null else ModifierCatalogScript.load_default()
	if _world_ext == null or not _world_ext.has_method("configure_modifiers"):
		return {"ok": false, "reason": "DCWorldExt modifier API unavailable"}
	if _catalog == null:
		return {"ok": false, "reason": "ModifierCatalog unavailable"}
	var compiled: Dictionary = _catalog.compile_native_catalog()
	if not bool(compiled.get("ok", false)):
		return compiled
	compiled.erase("ok")
	var result: Dictionary = _world_ext.configure_modifiers(compiled, cell_count)
	_configured = bool(result.get("ok", false))
	return result


func queue_apply(definition_key: StringName, target: Dictionary, source: Dictionary,
		duration_days: int = -2, initial_stacks: int = 1,
		effective_day: int = -1, producer_id: int = 100) -> int:
	return _queue(Opcode.APPLY, definition_key, target, source, duration_days,
		initial_stacks, 0, effective_day, producer_id)


func queue_remove(modifier_handle: int, domain: int, effective_day: int = -1,
		producer_id: int = 100) -> int:
	return _queue(Opcode.REMOVE, &"", {"domain": domain}, {}, -1, 1,
		modifier_handle, effective_day, producer_id)


func queue_refresh(modifier_handle: int, domain: int, duration_days: int,
		effective_day: int = -1, producer_id: int = 100) -> int:
	return _queue(Opcode.REFRESH, &"", {"domain": domain}, {}, duration_days, 1,
		modifier_handle, effective_day, producer_id)


func queue_set_stacks(modifier_handle: int, domain: int, stacks: int,
		effective_day: int = -1, producer_id: int = 100) -> int:
	return _queue(Opcode.SET_STACKS, &"", {"domain": domain}, {}, -1, stacks,
		modifier_handle, effective_day, producer_id)


func _queue(opcode: int, definition_key: StringName, target: Dictionary,
		source: Dictionary, duration_days: int, stacks: int, modifier_handle: int,
		effective_day: int, producer_id: int) -> int:
	if not _configured:
		return 0
	_producer_sequence += 1
	var day := effective_day
	if day < 0:
		day = _clock.day_index() if _clock != null else 0
	var batch := {
		"protocol_version": PROTOCOL_VERSION,
		"opcodes": PackedInt32Array([opcode]),
		"producer_ids": PackedInt32Array([producer_id]),
		"sequences": PackedInt64Array([_producer_sequence]),
		"effective_days": PackedInt64Array([day]),
		"definition_keys": PackedStringArray([String(definition_key)]),
		"domains": PackedInt32Array([int(target.get("domain", -1))]),
		"scopes": PackedInt32Array([int(target.get("scope", Scope.ENTITY))]),
		"entity_handles": PackedInt64Array([int(target.get("entity_handle", 0))]),
		"group_handles": PackedInt64Array([int(target.get("group_handle", 0))]),
		"source_types": PackedInt64Array([int(source.get("type", 0))]),
		"source_ids": PackedInt64Array([int(source.get("id", 0))]),
		"duration_days": PackedInt32Array([duration_days]),
		"stacks": PackedInt32Array([stacks]),
		"modifier_handles": PackedInt64Array([modifier_handle]),
	}
	var result: Dictionary = _world_ext.submit_modifier_commands(batch)
	var ids: PackedInt64Array = result.get("request_ids", PackedInt64Array())
	return int(ids[0]) if bool(result.get("ok", false)) and not ids.is_empty() else 0


func get_command_result(request_id: int) -> Dictionary:
	return _world_ext.get_modifier_command_result(request_id) if _configured else {}


func list_for_target(domain: int, entity_handle: int,
		stat_key: StringName = &"") -> Dictionary:
	return _world_ext.list_modifiers(domain, entity_handle, String(stat_key)) \
		if _configured else {}


func explain_stat(domain: int, entity_handle: int, group_handle: int,
		stat_key: StringName, base_value: float) -> Dictionary:
	return _world_ext.explain_modifier_stat(domain, entity_handle, group_handle,
		String(stat_key), base_value) if _configured else {}


func report() -> Dictionary:
	return _world_ext.get_modifier_report() if _configured else {"configured": false}


func dispatch_events() -> void:
	if not _configured:
		return
	var batch: Dictionary = _world_ext.poll_modifier_events(_last_event_id, 512)
	var ids: PackedInt64Array = batch.get("event_ids", PackedInt64Array())
	if ids.is_empty():
		return
	_last_event_id = int(ids[ids.size() - 1])
	modifier_events_available.emit(batch)


func is_configured() -> bool:
	return _configured


func world_ext() -> Object:
	return _world_ext
