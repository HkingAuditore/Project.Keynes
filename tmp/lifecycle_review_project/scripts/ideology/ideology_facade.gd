class_name IdeologyFacade
extends RefCounted

signal command_settled(result: Dictionary)

const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")

enum Opcode { DISCOVER_IDEOLOGY = 1, GRANT_IDEOLOGY_POINTS = 2, OPEN_IDEOLOGY_OFFER = 3,
	CHOOSE_IDEOLOGY_OFFER = 4, EQUIP_IDEOLOGY = 5, UNEQUIP_IDEOLOGY = 6,
	PROMOTE_NATIONAL_SPIRIT = 7, ADD_UNDERSTANDING = 8, SET_IDEOLOGY_GATE = 9 }

var _world_ext: Object
var _catalog: Resource
var _native_catalog: Dictionary = {}
var _country_catalog: Dictionary = {}
var _economy_catalog: Dictionary = {}
var _configured := false
var _receipt_cursor := 0

func configure(world_ext: Object, country_catalog: Dictionary,
		catalog: Resource = null, economy_catalog: Dictionary = {}) -> Dictionary:
	_world_ext = world_ext
	_country_catalog = country_catalog.duplicate(false)
	_economy_catalog = economy_catalog.duplicate(false)
	_catalog = catalog if catalog != null else IdeologyCatalogScript.load_default()
	if _world_ext == null or not _world_ext.has_method("configure_ideologies"):
		return {"ok": false, "reason": "DCWorldExt ideology API unavailable"}
	if _catalog == null or not _catalog.has_method("compile_native_catalog"):
		return {"ok": false, "reason": "IdeologyCatalog unavailable"}
	_native_catalog = _catalog.compile_native_catalog(
		country_catalog, economy_catalog)
	if not bool(_native_catalog.get("ok", false)): return _native_catalog
	var native := _native_catalog.duplicate(false)
	native.erase("ok")
	var result: Dictionary = _world_ext.configure_ideologies(native)
	_configured = bool(result.get("ok", false))
	return result

func submit(commands: Array[Dictionary]) -> Dictionary:
	if not _configured: return {"ok": false, "reason": "ideology_runtime_unconfigured"}
	var batch := {"opcodes": PackedInt32Array(), "effective_days": PackedInt64Array(),
		"producer_ids": PackedInt32Array(),
		"source_priorities": PackedInt32Array(), "sequences": PackedInt64Array(),
		"country_handles": PackedInt64Array(), "ideology_ids": PackedInt32Array(),
		"values_q16": PackedInt64Array(), "offer_generations": PackedInt64Array(),
		"choice_indices": PackedInt32Array(), "gate_ids": PackedInt32Array()}
	for command in commands:
		batch.opcodes.append(int(command.get("opcode", 0)))
		batch.effective_days.append(int(command.get("effective_day", 0)))
		batch.producer_ids.append(int(command.get("producer_id", 1)))
		batch.source_priorities.append(int(command.get("source_priority", 0)))
		batch.sequences.append(int(command.get("sequence", 0)))
		batch.country_handles.append(int(command.get("country_handle", 0)))
		batch.ideology_ids.append(_idea_id(command.get("ideology_id", -1)))
		batch.values_q16.append(int(command.get("value_q16", 0)))
		batch.offer_generations.append(int(command.get("offer_generation", 0)))
		batch.choice_indices.append(int(command.get("choice_index", -1)))
		batch.gate_ids.append(_gate_id(command.get("gate_id", -1)))
	return _world_ext.submit_ideology_commands(batch)

func drain_receipts(limit: int = 256) -> Dictionary:
	if not _configured or not _world_ext.has_method("poll_ideology_receipts"):
		return {"ok": false, "reason": "ideology_receipts_unavailable"}
	var result: Dictionary = _world_ext.poll_ideology_receipts(_receipt_cursor, limit)
	if not bool(result.get("ok", false)):
		return result
	var receipt_ids: PackedInt64Array = result.get("receipt_ids", PackedInt64Array())
	var producer_ids: PackedInt32Array = result.get("producer_ids", PackedInt32Array())
	var sequences: PackedInt64Array = result.get("sequences", PackedInt64Array())
	var statuses: PackedInt32Array = result.get("statuses", PackedInt32Array())
	var opcodes: PackedInt32Array = result.get("opcodes", PackedInt32Array())
	var handles: PackedInt64Array = result.get("country_handles", PackedInt64Array())
	var ideology_ids: PackedInt32Array = result.get("ideology_ids", PackedInt32Array())
	var settled_days: PackedInt64Array = result.get("settled_days", PackedInt64Array())
	var reasons: PackedStringArray = result.get("reasons", PackedStringArray())
	for index in range(receipt_ids.size()):
		_receipt_cursor = maxi(_receipt_cursor, int(receipt_ids[index]))
		if index >= producer_ids.size() or int(producer_ids[index]) != 1:
			continue
		command_settled.emit({
			"ok": index < statuses.size() and int(statuses[index]) != 3,
			"receipt_id": int(receipt_ids[index]),
			"sequence": int(sequences[index]) if index < sequences.size() else 0,
			"status": int(statuses[index]) if index < statuses.size() else 0,
			"opcode": int(opcodes[index]) if index < opcodes.size() else 0,
			"country_handle": int(handles[index]) if index < handles.size() else 0,
			"ideology_id": int(ideology_ids[index]) if index < ideology_ids.size() else -1,
			"settled_day": int(settled_days[index]) if index < settled_days.size() else -1,
			"reason": String(reasons[index]) if index < reasons.size() else "",
		})
	return result

func request_offer(handle: int, effective_day: int, sequence: int) -> Dictionary:
	return submit([{ "opcode": Opcode.OPEN_IDEOLOGY_OFFER, "country_handle": handle,
		"effective_day": effective_day, "sequence": sequence }])
func choose_offer(handle: int, offer_generation: int, choice_index: int, effective_day: int, sequence: int) -> Dictionary:
	return submit([{ "opcode": Opcode.CHOOSE_IDEOLOGY_OFFER, "country_handle": handle,
		"offer_generation": offer_generation, "choice_index": choice_index,
		"effective_day": effective_day, "sequence": sequence }])
func equip(handle: int, ideology_id, effective_day: int, sequence: int) -> Dictionary:
	return _idea_command(Opcode.EQUIP_IDEOLOGY, handle, ideology_id, 0, effective_day, sequence)
func unequip(handle: int, ideology_id, effective_day: int, sequence: int) -> Dictionary:
	return _idea_command(Opcode.UNEQUIP_IDEOLOGY, handle, ideology_id, 0, effective_day, sequence)
func promote(handle: int, ideology_id, effective_day: int, sequence: int) -> Dictionary:
	return _idea_command(Opcode.PROMOTE_NATIONAL_SPIRIT, handle, ideology_id, 0, effective_day, sequence)
func discover(handle: int, ideology_id, effective_day: int, sequence: int) -> Dictionary:
	return _idea_command(Opcode.DISCOVER_IDEOLOGY, handle, ideology_id, 0, effective_day, sequence)
func grant_points(handle: int, value_q16: int, effective_day: int, sequence: int) -> Dictionary:
	return _idea_command(Opcode.GRANT_IDEOLOGY_POINTS, handle, -1, value_q16, effective_day, sequence)
func add_understanding(handle: int, ideology_id, value_q16: int, effective_day: int, sequence: int) -> Dictionary:
	return _idea_command(Opcode.ADD_UNDERSTANDING, handle, ideology_id, value_q16, effective_day, sequence)
func set_gate(handle: int, gate_id, enabled: bool, effective_day: int, sequence: int) -> Dictionary:
	return submit([{ "opcode": Opcode.SET_IDEOLOGY_GATE, "country_handle": handle, "gate_id": gate_id,
		"value_q16": 1 if enabled else 0, "effective_day": effective_day, "sequence": sequence }])
func snapshot(handle: int) -> Dictionary: return _world_ext.get_ideology_snapshot(handle) if _configured else {"ok": false, "reason": "ideology_runtime_unconfigured"}
func explain_ideology(handle: int, ideology_id) -> Dictionary: return _world_ext.explain_ideology(handle, _idea_id(ideology_id)) if _configured else {"ok": false, "reason": "ideology_runtime_unconfigured"}
func explain_ideologies(handle: int, ideology_ids: PackedInt32Array = PackedInt32Array()) -> Dictionary:
	return _world_ext.explain_ideologies(handle, ideology_ids) \
		if _configured and _world_ext.has_method("explain_ideologies") \
		else {"ok": false, "reason": "ideology_batch_explain_unavailable"}
func report() -> Dictionary: return _world_ext.get_ideology_report() if _configured else {"configured": false}
func catalog_view() -> Dictionary: return _catalog.catalog_view(_country_catalog, _economy_catalog) if _catalog != null else {"ok": false}
func native_catalog() -> Dictionary: return _native_catalog.duplicate(false)
func world_ext() -> Object: return _world_ext
func is_configured() -> bool: return _configured
func _idea_command(opcode: int, handle: int, ideology_id, value_q16: int, effective_day: int, sequence: int) -> Dictionary:
	return submit([{ "opcode": opcode, "country_handle": handle, "ideology_id": ideology_id,
		"value_q16": value_q16, "effective_day": effective_day, "sequence": sequence }])
func _idea_id(value) -> int:
	if value is StringName or value is String: return PackedStringArray(_native_catalog.get("ideology_ids", PackedStringArray())).find(String(value))
	return int(value)
func _gate_id(value) -> int:
	if value is StringName or value is String: return PackedStringArray(_native_catalog.get("gate_keys", PackedStringArray())).find(String(value))
	return int(value)
