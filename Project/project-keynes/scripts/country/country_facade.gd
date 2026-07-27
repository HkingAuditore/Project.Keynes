class_name CountryFacade
extends RefCounted

signal country_committed(report: Dictionary)

const DEFAULT_PROFILE_PATH := "res://data/country/default_country.tres"
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryProfileScript = preload("res://scripts/data/country_profile.gd")

enum Opcode {
	CREATE_COUNTRY = 1,
	RENAME_COUNTRY = 2,
	TRANSFER_TERRITORY = 3,
	GRANT_TECHNOLOGY = 4,
}

var _world_ext: Object = null
var _profile = null
var _catalog: Dictionary = {}
var _configured: bool = false
var _last_event_id: int = 0

func configure(world_ext: Object, cell_count: int, seed: int,
		profile = null, compiled_catalog: Dictionary = {}) -> Dictionary:
	_world_ext = world_ext
	_profile = profile
	if _profile == null:
		_profile = ResourceLoader.load(DEFAULT_PROFILE_PATH, "Resource")
	if _world_ext == null or not _world_ext.has_method("configure_country"):
		return {"ok": false, "reason": "DCWorldExt country API unavailable"}
	if _profile == null:
		return {"ok": false, "reason": "CountryProfile unavailable"}
	_catalog = compiled_catalog.duplicate(true) if not compiled_catalog.is_empty() \
		else EconomyCatalogScript.compile_native_catalog()
	if not bool(_catalog.get("ok", true)):
		return _catalog
	var native_catalog := _catalog.duplicate(false)
	native_catalog.erase("ok")
	var result: Dictionary = _world_ext.configure_country(
		native_catalog, _profile.to_native_profile(), cell_count, seed)
	_configured = bool(result.get("ok", false))
	return result

func bootstrap(is_water: PackedByteArray, packet: Dictionary = {}) -> Dictionary:
	if not _configured:
		return {"ok": false, "reason": "country facade is not configured"}
	return _world_ext.bootstrap_country(packet, is_water)

func submit(commands: Array[Dictionary]) -> Dictionary:
	if not _configured:
		return {"ok": false, "reason": "country facade is not configured"}
	var batch := {
		"opcodes": PackedInt32Array(),
		"effective_days": PackedInt64Array(),
		"sequences": PackedInt64Array(),
		"target_handles": PackedInt64Array(),
		"cell_indices": PackedInt32Array(),
		"aux_i32": PackedInt32Array(),
		"stable_ids": PackedStringArray(),
		"display_names": PackedStringArray(),
	}
	for command in commands:
		batch.opcodes.append(int(command.get("opcode", 0)))
		batch.effective_days.append(int(command.get("effective_day", 0)))
		batch.sequences.append(int(command.get("sequence", 0)))
		batch.target_handles.append(int(command.get("target_handle", 0)))
		batch.cell_indices.append(int(command.get("cell", -1)))
		batch.aux_i32.append(int(command.get("technology", -1)))
		batch.stable_ids.append(String(command.get("stable_id", "")))
		batch.display_names.append(String(command.get("display_name", "")))
	return _world_ext.submit_country_commands(batch)

func create_country(stable_id: StringName, display_name: String, first_cell: int,
		effective_day: int, sequence: int) -> Dictionary:
	return submit([{"opcode": Opcode.CREATE_COUNTRY, "stable_id": String(stable_id),
		"display_name": display_name, "cell": first_cell,
		"effective_day": effective_day, "sequence": sequence}])

func rename_country(handle: int, display_name: String,
		effective_day: int, sequence: int) -> Dictionary:
	return submit([{"opcode": Opcode.RENAME_COUNTRY, "target_handle": handle,
		"display_name": display_name, "effective_day": effective_day, "sequence": sequence}])

func transfer_territory(cell: int, target_handle: int,
		effective_day: int, sequence: int) -> Dictionary:
	return submit([{"opcode": Opcode.TRANSFER_TERRITORY, "target_handle": target_handle,
		"cell": cell, "effective_day": effective_day, "sequence": sequence}])

func grant_technology(handle: int, technology_id: StringName,
		effective_day: int, sequence: int) -> Dictionary:
	var ids: PackedStringArray = _catalog.get("technology_ids", PackedStringArray())
	var technology := ids.find(String(technology_id))
	if technology < 0:
		return {"ok": false, "reason": "unknown technology id: %s" % String(technology_id)}
	return submit([{"opcode": Opcode.GRANT_TECHNOLOGY, "target_handle": handle,
		"technology": technology, "effective_day": effective_day, "sequence": sequence}])

func cell_summary(cell: int) -> Dictionary:
	return _world_ext.get_country_cell_summary(cell) if _configured else {}

func snapshot(handle: int) -> Dictionary:
	return _world_ext.get_country_snapshot(handle) if _configured else {}

func treasury_snapshot(handle: int) -> Dictionary:
	return _world_ext.get_country_treasury_snapshot(handle) if _configured else {}

func report() -> Dictionary:
	return _world_ext.get_country_report() if _configured else {"configured": false}

func dispatch_committed_events(result: Dictionary) -> void:
	if not _configured or int(result.get("changed_countries", 0)) <= 0:
		return
	var events: Dictionary = _world_ext.poll_country_events(_last_event_id, 512)
	var ids: PackedInt64Array = events.get("event_ids", PackedInt64Array())
	if not ids.is_empty():
		_last_event_id = int(ids[ids.size() - 1])
	country_committed.emit(result.duplicate(true))

func is_configured() -> bool:
	return _configured

func world_ext() -> Object:
	return _world_ext

func native_catalog() -> Dictionary:
	return _catalog.duplicate(false)

func begin_save(chunk_bytes: int = -1) -> Dictionary:
	if not _configured:
		return {"ok": false, "reason": "not configured"}
	return _world_ext.begin_country_save(
		int(_profile.save_chunk_bytes) if chunk_bytes < 0 else chunk_bytes)

func read_save_chunk(chunk_bytes: int = -1) -> PackedByteArray:
	if not _configured:
		return PackedByteArray()
	return _world_ext.read_country_save_chunk(
		int(_profile.save_chunk_bytes) if chunk_bytes < 0 else chunk_bytes)

func end_save() -> Dictionary:
	return _world_ext.end_country_save() if _configured else {"ok": false, "reason": "not configured"}

func restore_bytes(bytes: PackedByteArray, chunk_bytes: int = 4194304) -> Dictionary:
	if not _configured:
		return {"ok": false, "reason": "not configured"}
	var begun: Dictionary = _world_ext.begin_country_restore()
	if not bool(begun.get("ok", false)):
		return begun
	var cursor := 0
	while cursor < bytes.size():
		var fed: Dictionary = _world_ext.feed_country_restore_chunk(
			bytes.slice(cursor, mini(cursor + chunk_bytes, bytes.size())))
		if not bool(fed.get("ok", false)):
			return fed
		cursor += chunk_bytes
	return _world_ext.end_country_restore()
