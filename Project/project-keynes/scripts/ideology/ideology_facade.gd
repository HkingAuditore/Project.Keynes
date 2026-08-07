class_name IdeologyFacade
extends RefCounted

const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")

enum Opcode { DISCOVER_IDEOLOGY = 1, GRANT_IDEOLOGY_POINTS = 2, OPEN_IDEOLOGY_OFFER = 3,
	CHOOSE_IDEOLOGY_OFFER = 4, EQUIP_IDEOLOGY = 5, UNEQUIP_IDEOLOGY = 6,
	PROMOTE_NATIONAL_SPIRIT = 7, ADD_UNDERSTANDING = 8, SET_IDEOLOGY_GATE = 9 }

var _world_ext: Object
var _catalog: Resource
var _native_catalog: Dictionary = {}
var _country_catalog: Dictionary = {}
var _configured := false

func configure(world_ext: Object, country_catalog: Dictionary, catalog: Resource = null) -> Dictionary:
	_world_ext = world_ext
	_country_catalog = country_catalog.duplicate(false)
	_catalog = catalog if catalog != null else IdeologyCatalogScript.load_default()
	if _world_ext == null or not _world_ext.has_method("configure_ideologies"):
		return {"ok": false, "reason": "DCWorldExt ideology API unavailable"}
	if _catalog == null or not _catalog.has_method("compile_native_catalog"):
		return {"ok": false, "reason": "IdeologyCatalog unavailable"}
	_native_catalog = _catalog.compile_native_catalog(country_catalog)
	if not bool(_native_catalog.get("ok", false)): return _native_catalog
	var native := _native_catalog.duplicate(false)
	native.erase("ok")
	var result: Dictionary = _world_ext.configure_ideologies(native)
	_configured = bool(result.get("ok", false))
	return result

func submit(commands: Array[Dictionary]) -> Dictionary:
	if not _configured: return {"ok": false, "reason": "ideology_runtime_unconfigured"}
	var batch := {"opcodes": PackedInt32Array(), "effective_days": PackedInt64Array(),
		"source_priorities": PackedInt32Array(), "sequences": PackedInt64Array(),
		"country_handles": PackedInt64Array(), "ideology_ids": PackedInt32Array(),
		"values_q16": PackedInt64Array(), "offer_generations": PackedInt64Array(),
		"choice_indices": PackedInt32Array(), "gate_ids": PackedInt32Array()}
	for command in commands:
		batch.opcodes.append(int(command.get("opcode", 0)))
		batch.effective_days.append(int(command.get("effective_day", 0)))
		batch.source_priorities.append(int(command.get("source_priority", 0)))
		batch.sequences.append(int(command.get("sequence", 0)))
		batch.country_handles.append(int(command.get("country_handle", 0)))
		batch.ideology_ids.append(_idea_id(command.get("ideology_id", -1)))
		batch.values_q16.append(int(command.get("value_q16", 0)))
		batch.offer_generations.append(int(command.get("offer_generation", 0)))
		batch.choice_indices.append(int(command.get("choice_index", -1)))
		batch.gate_ids.append(_gate_id(command.get("gate_id", -1)))
	return _world_ext.submit_ideology_commands(batch)

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
func report() -> Dictionary: return _world_ext.get_ideology_report() if _configured else {"configured": false}
func catalog_view() -> Dictionary: return _catalog.catalog_view(_country_catalog) if _catalog != null else {"ok": false}
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
