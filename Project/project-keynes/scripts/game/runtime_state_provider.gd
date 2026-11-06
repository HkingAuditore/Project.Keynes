class_name RuntimeStateProvider
extends RefCounted

var _provider_id: StringName
var _schema_version := 0
var _section_ids := PackedStringArray()
var _can_save_callback: Callable
var _write_callback: Callable
var _restore_callback: Callable
var _hash_callback: Callable
var _manifest_identity_callback: Callable
var _accepted_schemas := PackedInt32Array()
var _allow_missing_archive := false
var _adapter_owner: RefCounted
var _decode_callback: Callable
var _context_binding: Callable
var _codecs: Dictionary = {}
var _restore_reads := PackedStringArray()


func retain_adapter(adapter: RefCounted) -> RuntimeStateProvider:
	_adapter_owner = adapter
	return self


func configure_context_binding(binding: Callable) -> RuntimeStateProvider:
	_context_binding = binding
	return self


func configure_decoder(callback: Callable) -> RuntimeStateProvider:
	_decode_callback = callback
	return self


func configure_codecs(codecs: Dictionary) -> RuntimeStateProvider:
	_codecs = codecs.duplicate()
	return self


func configure_restore_reads(reads: PackedStringArray) -> RuntimeStateProvider:
	_restore_reads = reads.duplicate()
	return self


func _bound_context(context: Dictionary) -> Dictionary:
	return _context_binding.call(context) if _context_binding.is_valid() else context


## Decode and validate every module before installing any world state.
## Extensions default to opaque bytes and may override this method for a custom codec.
func decode_sections(archive: Dictionary) -> Dictionary:
	if _decode_callback.is_valid():
		var owned_archive := {}
		for section_id in _section_ids:
			if archive.has(section_id):
				owned_archive[section_id] = archive[section_id]
		return _checked_sections(_decode_callback.call(owned_archive))
	var decoded := {}
	for section_id in _section_ids:
		if not archive.has(section_id) and not _allow_missing_archive:
			return _error("save_provider_missing", "存档缺少模块数据：%s" % section_id)
		var bytes: PackedByteArray = archive.get(section_id, PackedByteArray())
		var codec := String(_codecs.get(section_id, "bytes"))
		var value = bytes
		if codec == "variant":
			value = {} if bytes.is_empty() and _allow_missing_archive else bytes_to_var(bytes)
			if not value is Dictionary:
				return _error("save_section_decode_failed", "无法解析存档 section：%s" % section_id)
		elif codec != "bytes":
			return _error("save_codec_unknown", "模块未实现存档解析器：%s" % codec)
		decoded[section_id] = value
	return {"ok": true, "sections": decoded}


func configure(provider_id_value: StringName, schema_version_value: int,
		section_ids_value: PackedStringArray, can_save_callback: Callable,
		write_callback: Callable, restore_callback: Callable,
		hash_callback: Callable) -> RuntimeStateProvider:
	_provider_id = provider_id_value
	_schema_version = schema_version_value
	_accepted_schemas = PackedInt32Array([schema_version_value])
	_section_ids = section_ids_value.duplicate()
	_can_save_callback = can_save_callback
	_write_callback = write_callback
	_restore_callback = restore_callback
	_hash_callback = hash_callback
	return self


func provider_id() -> StringName:
	return _provider_id


func registration_valid() -> bool:
	return _provider_id != &"" and _schema_version > 0 and not _section_ids.is_empty() \
		and _schema_version in _accepted_schemas \
		and _can_save_callback.is_valid() and _write_callback.is_valid() \
		and _restore_callback.is_valid() and _hash_callback.is_valid()


## Declares the provider-owned identity that the whole-package manifest must
## carry next to `schema_version` (plan 11.5). `callback(context)` returns a
## Dictionary of extra manifest fields, or {} when the identity cannot be
## stated. Optional: providers that never call this write exactly the four
## fixed keys they always wrote.
func configure_manifest_identity(callback: Callable) -> RuntimeStateProvider:
	_manifest_identity_callback = callback
	return self


func schema_version() -> int:
	return _schema_version


func configure_compatibility(schemas: PackedInt32Array, allow_missing: bool = false) -> RuntimeStateProvider:
	_accepted_schemas = schemas.duplicate()
	_allow_missing_archive = allow_missing
	return self


func allows_missing_archive() -> bool:
	return _allow_missing_archive


func accepts_manifest(entry: Dictionary) -> bool:
	if int(entry.get("schema_version", -1)) not in _accepted_schemas:
		return false
	var actual := PackedStringArray(entry.get("sections", []))
	var expected := _section_ids.duplicate()
	actual.sort()
	expected.sort()
	return actual == expected


func section_ids() -> PackedStringArray:
	return _section_ids.duplicate()


func can_save(context: Dictionary) -> Dictionary:
	if not _can_save_callback.is_valid():
		return _error("save_provider_unavailable", "Provider cannot validate save state.")
	var result = _can_save_callback.call(_bound_context(context))
	return result if result is Dictionary else _error(
		"save_provider_contract_invalid", "Provider returned an invalid save check.")


func write_sections(context: Dictionary) -> Dictionary:
	if not _write_callback.is_valid():
		return _error("save_provider_unavailable", "Provider cannot write state.")
	var result = _write_callback.call(_bound_context(context))
	if not result is Dictionary or not bool(result.get("ok", false)):
		return result if result is Dictionary else _error(
			"save_provider_contract_invalid", "Provider returned invalid sections.")
	return _checked_sections(result)


func _checked_sections(result) -> Dictionary:
	if not result is Dictionary:
		return _error("save_provider_contract_invalid", "模块未返回存档结果。")
	if not bool(result.get("ok", false)):
		return result
	var sections = result.get("sections")
	if not sections is Dictionary:
		return _error("save_provider_contract_invalid", "模块未返回存档片段。")
	for section_id in _section_ids:
		if not sections.has(section_id):
			return _error("save_provider_missing", "%s did not write %s." % [
				String(_provider_id), section_id])
	if sections.size() != _section_ids.size():
		return _error("save_provider_undeclared_section", "模块返回了未声明的存档片段。")
	return result


func restore_sections(sections: Dictionary, context: Dictionary) -> Dictionary:
	for section_id in _section_ids:
		if not sections.has(section_id):
			return _error("save_provider_missing", "Save is missing %s." % section_id)
	if not _restore_callback.is_valid():
		return _error("load_provider_unavailable", "Provider cannot restore state.")
	var inputs := sections
	if _context_binding.is_valid():
		inputs = {}
		for section_id in _section_ids + _restore_reads:
			if not sections.has(section_id):
				return _error("save_provider_missing", "存档缺少依赖数据：%s" % section_id)
			inputs[section_id] = sections[section_id]
	var result = _restore_callback.call(inputs, _bound_context(context))
	return result if result is Dictionary else _error(
		"load_provider_contract_invalid", "Provider returned an invalid restore result.")


func state_hash(context: Dictionary) -> String:
	if not _hash_callback.is_valid():
		return ""
	var hash_context := {"current_provider_sections": context.get("current_provider_sections", {})} \
		if _context_binding.is_valid() else context
	return str(_hash_callback.call(hash_context))


func manifest_entry(context: Dictionary, include_state_hash: bool = true) -> Dictionary:
	var entry := {
		"provider_id": String(_provider_id),
		"schema_version": _schema_version,
		"sections": Array(_section_ids),
		"state_hash": state_hash(context) if include_state_hash else "",
	}
	# Plan 11.5: some providers own an identity that is NOT a version number and
	# is not derivable from the section bytes -- the ideology provider's execution
	# contract is a hash of the rule versions and the catalogs it was configured
	# with. Such a provider declares it here so the WHOLE-PACKAGE manifest carries
	# it; a provider that declares nothing keeps the four fixed keys byte for byte.
	# The callback returns {} when the identity cannot be stated (no runtime yet,
	# or the owner is unconfigured), and an absent key is a fact the load gate
	# treats as UNSTATED rather than as "matches" -- see
	# `game_save_coordinator.gd:_execution_contract_verdict`.
	if _manifest_identity_callback.is_valid():
		var identity = _manifest_identity_callback.call(_bound_context(context))
		if identity is Dictionary:
			for key in identity:
				var field := String(key)
				if not entry.has(field):
					entry[field] = identity[key]
	return entry


static func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "message": message}
