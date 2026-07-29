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
	SET_RESEARCH_WEIGHTS = 5,
	ENQUEUE_RESEARCH = 6,
	REMOVE_RESEARCH = 7,
	MOVE_RESEARCH = 8,
	SET_RESEARCH_BUDGET = 9,
	REVEAL_ALL_TECHNOLOGIES = 10,
	SET_TAX_DEFAULT = 11,
	SET_TAX_OVERRIDE = 12,
	CLEAR_TAX_OVERRIDE = 13,
}

enum TaxKind {
	INCOME = 0,
	CONSUMPTION = 1,
	BUSINESS = 2,
	IMPORT = 3,
	EXPORT = 4,
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
		"domain_i32": PackedInt32Array(),
		"position_i32": PackedInt32Array(),
		"weight0_bp": PackedInt32Array(),
		"weight1_bp": PackedInt32Array(),
		"weight2_bp": PackedInt32Array(),
		"weight3_bp": PackedInt32Array(),
		"value_i64": PackedInt64Array(),
		"tax_kinds": PackedInt32Array(),
		"tax_item_indices": PackedInt32Array(),
		"tax_rate_percent": PackedInt32Array(),
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
		batch.domain_i32.append(int(command.get("domain", -1)))
		batch.position_i32.append(int(command.get("position", -1)))
		var weights: PackedInt32Array = command.get("weights_bp",
			PackedInt32Array([0, 0, 0, 0]))
		for domain in range(4):
			batch["weight%d_bp" % domain].append(
				int(weights[domain]) if domain < weights.size() else 0)
		batch.value_i64.append(int(command.get("value", 0)))
		batch.tax_kinds.append(int(command.get("tax_kind", -1)))
		batch.tax_item_indices.append(int(command.get("tax_item", -1)))
		batch.tax_rate_percent.append(int(command.get("tax_rate_percent", 0)))
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

func set_research_weights(handle: int, weights_bp: PackedInt32Array,
		effective_day: int, sequence: int) -> Dictionary:
	if weights_bp.size() != 4:
		return {"ok": false, "reason": "research weights require four domains"}
	return submit([{"opcode": Opcode.SET_RESEARCH_WEIGHTS, "target_handle": handle,
		"weights_bp": weights_bp, "effective_day": effective_day, "sequence": sequence}])

func enqueue_research(handle: int, technology_id: StringName, domain: int,
		position: int, effective_day: int, sequence: int) -> Dictionary:
	var technology := _technology_index(technology_id)
	if technology < 0:
		return {"ok": false, "reason": "unknown technology id: %s" % String(technology_id)}
	return submit([{"opcode": Opcode.ENQUEUE_RESEARCH, "target_handle": handle,
		"technology": technology, "domain": domain, "position": position,
		"effective_day": effective_day, "sequence": sequence}])

func remove_research(handle: int, technology_id: StringName,
		effective_day: int, sequence: int) -> Dictionary:
	var technology := _technology_index(technology_id)
	if technology < 0:
		return {"ok": false, "reason": "unknown technology id: %s" % String(technology_id)}
	return submit([{"opcode": Opcode.REMOVE_RESEARCH, "target_handle": handle,
		"technology": technology, "effective_day": effective_day, "sequence": sequence}])

func move_research(handle: int, technology_id: StringName, domain: int,
		position: int, effective_day: int, sequence: int) -> Dictionary:
	var technology := _technology_index(technology_id)
	if technology < 0:
		return {"ok": false, "reason": "unknown technology id: %s" % String(technology_id)}
	return submit([{"opcode": Opcode.MOVE_RESEARCH, "target_handle": handle,
		"technology": technology, "domain": domain, "position": position,
		"effective_day": effective_day, "sequence": sequence}])

func set_research_budget(handle: int, enabled: bool, daily_cash_limit: int,
		effective_day: int, sequence: int) -> Dictionary:
	return submit([{"opcode": Opcode.SET_RESEARCH_BUDGET, "target_handle": handle,
		"technology": 1 if enabled else 0, "value": maxi(0, daily_cash_limit),
		"effective_day": effective_day, "sequence": sequence}])

func reveal_all_technologies(handle: int, effective_day: int,
		sequence: int) -> Dictionary:
	return submit([{"opcode": Opcode.REVEAL_ALL_TECHNOLOGIES,
		"target_handle": handle, "effective_day": effective_day, "sequence": sequence}])


func set_tax_default(handle: int, kind: int, rate_percent: int,
		effective_day: int, sequence: int) -> Dictionary:
	if kind < TaxKind.INCOME or kind > TaxKind.EXPORT:
		return {"ok": false, "reason": "invalid tax kind"}
	if rate_percent < -100 or rate_percent > 100:
		return {"ok": false, "reason": "tax rate must be within -100..100"}
	return submit([{
		"opcode": Opcode.SET_TAX_DEFAULT,
		"target_handle": handle,
		"tax_kind": kind,
		"tax_rate_percent": rate_percent,
		"effective_day": effective_day,
		"sequence": sequence,
	}])


func set_tax_override(handle: int, kind: int, item_id: StringName,
		rate_percent: int, effective_day: int, sequence: int) -> Dictionary:
	var item := _tax_item_index(kind, item_id)
	if item < 0:
		return {"ok": false, "reason": "unknown tax item: %s" % String(item_id)}
	if rate_percent < -100 or rate_percent > 100:
		return {"ok": false, "reason": "tax rate must be within -100..100"}
	return submit([{
		"opcode": Opcode.SET_TAX_OVERRIDE,
		"target_handle": handle,
		"tax_kind": kind,
		"tax_item": item,
		"tax_rate_percent": rate_percent,
		"effective_day": effective_day,
		"sequence": sequence,
	}])


func clear_tax_override(handle: int, kind: int, item_id: StringName,
		effective_day: int, sequence: int) -> Dictionary:
	var item := _tax_item_index(kind, item_id)
	if item < 0:
		return {"ok": false, "reason": "unknown tax item: %s" % String(item_id)}
	return submit([{
		"opcode": Opcode.CLEAR_TAX_OVERRIDE,
		"target_handle": handle,
		"tax_kind": kind,
		"tax_item": item,
		"effective_day": effective_day,
		"sequence": sequence,
	}])


func tax_policy_snapshot(handle: int) -> Dictionary:
	return _world_ext.get_country_tax_policy_snapshot(handle) if _configured else {}


func fiscal_snapshot(handle: int) -> Dictionary:
	return _world_ext.get_country_fiscal_snapshot(handle) if _configured \
			and _world_ext.has_method("get_country_fiscal_snapshot") else {}


func _tax_item_index(kind: int, item_id: StringName) -> int:
	var key := ""
	match kind:
		TaxKind.INCOME:
			key = "profession_ids"
		TaxKind.CONSUMPTION, TaxKind.IMPORT, TaxKind.EXPORT:
			key = "good_ids"
		TaxKind.BUSINESS:
			key = "building_type_ids"
		_:
			return -1
	var ids: PackedStringArray = _catalog.get(key, PackedStringArray())
	return ids.find(String(item_id))

func research_snapshot(handle: int) -> Dictionary:
	return _world_ext.get_country_research_snapshot(handle) if _configured else {}

func _technology_index(technology_id: StringName) -> int:
	var ids: PackedStringArray = _catalog.get("technology_ids", PackedStringArray())
	return ids.find(String(technology_id))

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
