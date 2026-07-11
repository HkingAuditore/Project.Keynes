class_name EconomyFacade
extends RefCounted

const DEFAULT_PROFILE_PATH := "res://data/economy/default_economy.tres"
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const EconomyProfileScript = preload("res://scripts/data/economy_profile.gd")

enum Opcode {
	TRANSFER_TO_COHORT = 1,
	MINT_TO_COHORT = 2,
	BURN_FROM_COHORT = 3,
	ADD_STOCK = 4,
	REMOVE_STOCK = 5,
	ADD_POPULATION = 6,
	MOVE_POPULATION = 7,
	CHANGE_SIGNATURE = 8,
	TRANSFER_FROM_COHORT = 9,
	BUILD = 10,
	DEMOLISH = 11,
}

var _world_ext: Object = null
var _profile = null
var _catalog: Dictionary = {}
var _configured: bool = false
var _population_cache: Dictionary = {}
var _market_cache: Dictionary = {}
var _profession_display_names: Dictionary = {}
var _ethnicity_display_names: Dictionary = {}
var _building_cache: Dictionary = {}

func configure(world_ext: Object, cell_count: int, seed: int, profile = null) -> Dictionary:
	_world_ext = world_ext
	_profile = profile
	if _profile == null:
		_profile = ResourceLoader.load(DEFAULT_PROFILE_PATH, "Resource")
	if _world_ext == null or not _world_ext.has_method("configure_economy"):
		return {"ok": false, "reason": "DCWorldExt economy API unavailable"}
	if _profile == null:
		return {"ok": false, "reason": "EconomyProfile unavailable"}
	_catalog = EconomyCatalogScript.compile_native_catalog()
	if not bool(_catalog.get("ok", false)):
		return _catalog
	var native_catalog := _catalog.duplicate()
	native_catalog.erase("ok")
	_profession_display_names = _load_display_names(EconomyCatalogScript.PROFESSION_DIR)
	_ethnicity_display_names = _load_display_names(EconomyCatalogScript.ETHNICITY_DIR)
	var result: Dictionary = _world_ext.configure_economy(
		native_catalog, _profile.to_native_profile(), cell_count, seed)
	_configured = bool(result.get("ok", false))
	_population_cache.clear()
	_market_cache.clear()
	_building_cache.clear()
	return result

func bootstrap(population_packet: Dictionary = {}, market_packet: Dictionary = {},
		building_packet: Dictionary = {}) -> Dictionary:
	if not _configured:
		return {"ok": false, "reason": "economy facade is not configured"}
	var packet := population_packet
	if packet.is_empty():
		packet = {
			"cell_indices": PackedInt32Array(),
			"signature_ids": PackedInt32Array(),
			"population": PackedInt64Array(),
			"funds": PackedInt64Array(),
		}
	var markets := market_packet.duplicate(true)
	for key in building_packet:
		markets[key] = building_packet[key]
	return _world_ext.bootstrap_economy(packet, markets)

func submit(commands: Array[Dictionary]) -> Dictionary:
	if not _configured:
		return {"ok": false, "reason": "economy facade is not configured"}
	var batch := {
		"opcodes": PackedInt32Array(),
		"effective_days": PackedInt64Array(),
		"sequences": PackedInt64Array(),
		"target_handles": PackedInt64Array(),
		"i32_0": PackedInt32Array(),
		"i32_1": PackedInt32Array(),
		"i64_0": PackedInt64Array(),
		"i64_1": PackedInt64Array(),
	}
	for command in commands:
		batch.opcodes.append(int(command.get("opcode", 0)))
		batch.effective_days.append(int(command.get("effective_day", 0)))
		batch.sequences.append(int(command.get("sequence", 0)))
		batch.target_handles.append(int(command.get("target_handle", 0)))
		batch.i32_0.append(int(command.get("i32_0", 0)))
		batch.i32_1.append(int(command.get("i32_1", 0)))
		batch.i64_0.append(int(command.get("i64_0", 0)))
		batch.i64_1.append(int(command.get("i64_1", 0)))
	return _world_ext.submit_economy_commands(batch)

func add_stock(cell_idx: int, good_id: StringName, quantity: int,
		effective_day: int, sequence: int) -> Dictionary:
	var goods: PackedStringArray = _catalog.get("good_ids", PackedStringArray())
	var good_idx: int = goods.find(String(good_id))
	if good_idx < 0:
		return {"ok": false, "reason": "unknown good id: %s" % String(good_id)}
	return submit([{
		"opcode": Opcode.ADD_STOCK,
		"effective_day": effective_day,
		"sequence": sequence,
		"target_handle": 0,
		"i32_0": cell_idx,
		"i32_1": good_idx,
		"i64_0": quantity,
		"i64_1": 0,
	}])

func population_cell_snapshot(cell_idx: int) -> Dictionary:
	if not _configured:
		return {}
	var snapshot: Dictionary = _world_ext.get_population_cell_snapshot(cell_idx)
	var has_details := snapshot.has("populations")
	if has_details:
		_attach_population_display_metadata(snapshot)
		snapshot["details_available"] = true
		snapshot["details_pending"] = false
		_population_cache[cell_idx] = snapshot.duplicate(true)
		return snapshot.duplicate(true)
	if _population_cache.has(cell_idx):
		var cached := (_population_cache[cell_idx] as Dictionary).duplicate(true)
		cached["stale_while_busy"] = bool(snapshot.get("busy", false))
		return cached
	snapshot["details_available"] = false
	snapshot["details_pending"] = bool(snapshot.get("busy", false)) \
		and not bool(snapshot.get("details_available", false))
	return snapshot.duplicate(true)

func market_cell_snapshot(cell_idx: int) -> Dictionary:
	if not _configured:
		return {}
	var snapshot: Dictionary = _world_ext.get_market_cell_snapshot(cell_idx)
	var has_details := snapshot.has("good_ids")
	if has_details:
		snapshot["details_available"] = true
		snapshot["details_pending"] = false
		_market_cache[cell_idx] = snapshot.duplicate(true)
		return snapshot.duplicate(true)
	if _market_cache.has(cell_idx):
		var cached := (_market_cache[cell_idx] as Dictionary).duplicate(true)
		cached["stale_while_busy"] = bool(snapshot.get("busy", false))
		return cached
	snapshot["details_available"] = false
	snapshot["details_pending"] = bool(snapshot.get("busy", false)) \
		and not bool(snapshot.get("details_available", false))
	return snapshot.duplicate(true)

func building_cell_snapshot(cell_idx: int) -> Dictionary:
	if not _configured:
		return {}
	var snapshot: Dictionary = _world_ext.get_building_cell_snapshot(cell_idx)
	if snapshot.has("building_type_ids"):
		_building_cache[cell_idx] = snapshot.duplicate(true)
		return snapshot.duplicate(true)
	return (_building_cache.get(cell_idx, snapshot) as Dictionary).duplicate(true)

func building_type_id(building_id: StringName) -> int:
	var ids: PackedStringArray = _catalog.get("building_type_ids", PackedStringArray())
	return ids.find(String(building_id))

func building_job_spec(building_id: StringName) -> Dictionary:
	var type_ids: PackedStringArray = _catalog.get("building_type_ids", PackedStringArray())
	var type_id := type_ids.find(String(building_id))
	if type_id < 0:
		return {"ok": false, "reason": "unknown building type: %s" % String(building_id)}
	var profession_ids: PackedStringArray = _catalog.get("profession_ids", PackedStringArray())
	var owner_professions: PackedInt32Array = _catalog.get(
		"building_owner_profession_ids", PackedInt32Array())
	var owner_slots: PackedInt64Array = _catalog.get("building_owner_slots", PackedInt64Array())
	var employee_offsets: PackedInt32Array = _catalog.get(
		"building_employee_offsets", PackedInt32Array())
	var employee_professions: PackedInt32Array = _catalog.get(
		"building_employee_profession_ids", PackedInt32Array())
	var employee_slots: PackedInt64Array = _catalog.get(
		"building_employee_slots", PackedInt64Array())
	if type_id >= owner_professions.size() or type_id >= owner_slots.size() or \
			type_id + 1 >= employee_offsets.size():
		return {"ok": false, "reason": "building job catalog shape invalid"}
	var owner_profession_idx := int(owner_professions[type_id])
	if owner_profession_idx < 0 or owner_profession_idx >= profession_ids.size():
		return {"ok": false, "reason": "building owner profession invalid"}
	var role_professions := PackedStringArray()
	var role_slots := PackedInt64Array()
	for role in range(employee_offsets[type_id], employee_offsets[type_id + 1]):
		var profession_idx := int(employee_professions[role])
		if profession_idx < 0 or profession_idx >= profession_ids.size():
			return {"ok": false, "reason": "building employee profession invalid"}
		role_professions.append(profession_ids[profession_idx])
		role_slots.append(employee_slots[role])
	return {
		"ok": true,
		"type_id": type_id,
		"stable_id": String(building_id),
		"owner_profession": profession_ids[owner_profession_idx],
		"owner_slots": owner_slots[type_id],
		"employee_professions": role_professions,
		"employee_slots": role_slots,
	}

func build(cell_idx: int, building_id: StringName, count: int, owner_handle: int,
		effective_day: int, sequence: int) -> Dictionary:
	var type_id := building_type_id(building_id)
	if type_id < 0 or count <= 0:
		return {"ok": false, "reason": "invalid building type or count"}
	return submit([{
		"opcode": Opcode.BUILD,
		"effective_day": effective_day,
		"sequence": sequence,
		"target_handle": owner_handle,
		"i32_0": cell_idx,
		"i32_1": type_id,
		"i64_0": count,
		"i64_1": 0,
	}])

func demolish(cell_idx: int, building_id: StringName, count: int, owner_handle: int,
		effective_day: int, sequence: int) -> Dictionary:
	var type_id := building_type_id(building_id)
	if type_id < 0 or count <= 0:
		return {"ok": false, "reason": "invalid building type or count"}
	return submit([{
		"opcode": Opcode.DEMOLISH,
		"effective_day": effective_day,
		"sequence": sequence,
		"target_handle": owner_handle,
		"i32_0": cell_idx,
		"i32_1": type_id,
		"i64_0": count,
		"i64_1": 0,
	}])

func report() -> Dictionary:
	return _world_ext.get_economy_report() if _configured else {"configured": false}

func signature_id(profession_id: StringName, ethnicity_id: StringName) -> int:
	var key := "%s|%s" % [String(profession_id), String(ethnicity_id)]
	var keys: PackedStringArray = _catalog.get("signature_keys", PackedStringArray())
	return keys.find(key)

func good_ids() -> PackedStringArray:
	return (_catalog.get("good_ids", PackedStringArray()) as PackedStringArray).duplicate()

func _attach_population_display_metadata(snapshot: Dictionary) -> void:
	var profession_ids: PackedStringArray = snapshot.get(
		"profession_stable_ids", PackedStringArray())
	var ethnicity_ids: PackedStringArray = snapshot.get(
		"ethnicity_stable_ids", PackedStringArray())
	var profession_names := PackedStringArray()
	var ethnicity_names := PackedStringArray()
	for stable_id in profession_ids:
		profession_names.append(String(_profession_display_names.get(
			String(stable_id), String(stable_id))))
	for stable_id in ethnicity_ids:
		ethnicity_names.append(String(_ethnicity_display_names.get(
			String(stable_id), String(stable_id))))
	snapshot["profession_display_names"] = profession_names
	snapshot["ethnicity_display_names"] = ethnicity_names

static func _load_display_names(directory: String) -> Dictionary:
	var result := {}
	var paths := PackedStringArray()
	for file_name in DirAccess.get_files_at(directory):
		if file_name.get_extension().to_lower() == "tres":
			paths.append("%s/%s" % [directory, file_name])
	paths.sort()
	for path in paths:
		var profile = ResourceLoader.load(path, "Resource")
		if profile == null:
			continue
		var stable_id := String(profile.get("id"))
		if stable_id == "":
			continue
		var display_name := String(profile.get("display_name"))
		result[stable_id] = display_name if display_name != "" else stable_id
	return result

func begin_save() -> Dictionary:
	return _world_ext.begin_economy_save(_profile.save_chunk_bytes) if _configured else {"ok": false, "reason": "not configured"}

func read_save_chunk() -> PackedByteArray:
	return _world_ext.read_economy_save_chunk(_profile.save_chunk_bytes) if _configured else PackedByteArray()

func end_save() -> Dictionary:
	return _world_ext.end_economy_save() if _configured else {"ok": false, "reason": "not configured"}

func world_ext() -> Object:
	return _world_ext

func profile():
	return _profile

func is_configured() -> bool:
	return _configured
