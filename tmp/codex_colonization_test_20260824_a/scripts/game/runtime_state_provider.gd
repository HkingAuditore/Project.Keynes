class_name RuntimeStateProvider
extends RefCounted

var _provider_id: StringName
var _schema_version := 0
var _section_ids := PackedStringArray()
var _can_save_callback: Callable
var _write_callback: Callable
var _restore_callback: Callable
var _hash_callback: Callable


func configure(provider_id_value: StringName, schema_version_value: int,
		section_ids_value: PackedStringArray, can_save_callback: Callable,
		write_callback: Callable, restore_callback: Callable,
		hash_callback: Callable) -> RuntimeStateProvider:
	_provider_id = provider_id_value
	_schema_version = schema_version_value
	_section_ids = section_ids_value.duplicate()
	_can_save_callback = can_save_callback
	_write_callback = write_callback
	_restore_callback = restore_callback
	_hash_callback = hash_callback
	return self


func provider_id() -> StringName:
	return _provider_id


func schema_version() -> int:
	return _schema_version


func section_ids() -> PackedStringArray:
	return _section_ids.duplicate()


func can_save(context: Dictionary) -> Dictionary:
	if not _can_save_callback.is_valid():
		return _error("save_provider_unavailable", "Provider cannot validate save state.")
	var result = _can_save_callback.call(context)
	return result if result is Dictionary else _error(
		"save_provider_contract_invalid", "Provider returned an invalid save check.")


func write_sections(context: Dictionary) -> Dictionary:
	if not _write_callback.is_valid():
		return _error("save_provider_unavailable", "Provider cannot write state.")
	var result = _write_callback.call(context)
	if not result is Dictionary or not bool(result.get("ok", false)):
		return result if result is Dictionary else _error(
			"save_provider_contract_invalid", "Provider returned invalid sections.")
	var sections: Dictionary = result.get("sections", {})
	for section_id in _section_ids:
		if not sections.has(section_id):
			return _error("save_provider_missing", "%s did not write %s." % [
				String(_provider_id), section_id])
	return result


func restore_sections(sections: Dictionary, context: Dictionary) -> Dictionary:
	for section_id in _section_ids:
		if not sections.has(section_id):
			return _error("save_provider_missing", "Save is missing %s." % section_id)
	if not _restore_callback.is_valid():
		return _error("load_provider_unavailable", "Provider cannot restore state.")
	var result = _restore_callback.call(sections, context)
	return result if result is Dictionary else _error(
		"load_provider_contract_invalid", "Provider returned an invalid restore result.")


func state_hash(context: Dictionary) -> String:
	if not _hash_callback.is_valid():
		return ""
	return str(_hash_callback.call(context))


func manifest_entry(context: Dictionary) -> Dictionary:
	return {
		"provider_id": String(_provider_id),
		"schema_version": _schema_version,
		"sections": Array(_section_ids),
		"state_hash": state_hash(context),
	}


static func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "message": message}
