class_name SaveRepository
extends RefCounted

const FORMAT_VERSION := 1
const MAGIC := "PKSV"
const TECHNOLOGY_INDUSTRY_REVISION := 2
const LEGACY_TECHNOLOGY_INDUSTRY_REVISION := 1
const LEGACY_INDUSTRY_REASON := "该存档使用旧产业科技规则，无法载入当前版本。请新建游戏或从兼容版本继续。"
const SAVE_DIR := "user://saves"
const SLOT_IDS := ["manual_1", "manual_2", "manual_3", "autosave"]
var _save_dir: String


func _init(save_dir: String = SAVE_DIR) -> void:
	_save_dir = save_dir


func list_slots() -> Array:
	_ensure_directory()
	var slots: Array = []
	for slot_id in SLOT_IDS:
		var path := _slot_path(slot_id)
		var read := _read_container(path, false, true)
		if not bool(read.get("ok", false)):
			var backup := _read_container(path + ".bak", false, true)
			if bool(backup.get("ok", false)):
				read = backup
		var header: Dictionary = read.get("header", {})
		slots.append({
			"slot_id": slot_id,
			"exists": FileAccess.file_exists(path) or FileAccess.file_exists(path + ".bak"),
			"loadable": bool(read.get("ok", false)) and _compatible(header),
			"reason": _reason_for(read, header),
			"country_name": String(header.get("country_name", "")),
			"day": int(header.get("day", 0)),
			"seed": int(header.get("seed", 0)),
			"width": int(header.get("width", 0)),
			"height": int(header.get("height", 0)),
			"saved_at": String(header.get("saved_at", "")),
			"technology_industry_revision": _technology_industry_revision(header),
			"provider_manifest": header.get("provider_manifest", []),
		})
	return slots


func write_slot(slot_id: String, header_fields: Dictionary, sections: Dictionary) -> Dictionary:
	if slot_id not in SLOT_IDS:
		return _error("slot_invalid", "存档槽位无效。")
	_ensure_directory()
	var section_table: Array = []
	var blocks: Array[PackedByteArray] = []
	var offset := 0
	var section_ids := sections.keys()
	section_ids.sort()
	for raw_id in section_ids:
		var section_id := String(raw_id)
		var bytes: PackedByteArray = sections[raw_id] if sections[raw_id] is PackedByteArray \
			else var_to_bytes(sections[raw_id])
		var compressed: PackedByteArray = PackedByteArray() if bytes.is_empty() \
			else bytes.compress(FileAccess.COMPRESSION_ZSTD)
		section_table.append({
			"id": section_id,
			"offset": offset,
			"length": compressed.size(),
			"uncompressed_length": bytes.size(),
			"sha256": _sha256(bytes),
		})
		blocks.append(compressed)
		offset += compressed.size()
	var header := header_fields.duplicate(true)
	header.merge({
		"magic": MAGIC,
		"format_version": FORMAT_VERSION,
		"technology_industry_revision": TECHNOLOGY_INDUSTRY_REVISION,
		"application_version": ProjectSettings.get_setting("application/config/version", "dev"),
		"generator_hash": compatibility_hash(),
		"sections": section_table,
	}, true)
	var header_bytes := JSON.stringify(header).to_utf8_buffer()
	var path := _slot_path(slot_id)
	var temp_path := path + ".tmp"
	var file := FileAccess.open(temp_path, FileAccess.WRITE)
	if file == null:
		return _error("save_open_failed", "无法创建临时存档文件。")
	file.store_buffer(MAGIC.to_ascii_buffer())
	file.store_32(FORMAT_VERSION)
	file.store_32(header_bytes.size())
	file.store_buffer(header_bytes)
	for block in blocks:
		file.store_buffer(block)
	file.flush()
	file.close()
	var verified := _read_container(temp_path, true)
	if not bool(verified.get("ok", false)):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(temp_path))
		return _error("save_verify_failed", "临时存档校验失败：%s" % String(verified.get("message", "")))
	var absolute := ProjectSettings.globalize_path(path)
	var absolute_temp := ProjectSettings.globalize_path(temp_path)
	var absolute_backup := ProjectSettings.globalize_path(path + ".bak")
	if FileAccess.file_exists(path + ".bak"):
		DirAccess.remove_absolute(absolute_backup)
	if FileAccess.file_exists(path):
		var backup_error := DirAccess.rename_absolute(absolute, absolute_backup)
		if backup_error != OK:
			return _error("save_backup_failed", "无法备份旧存档。")
	var replace_error := DirAccess.rename_absolute(absolute_temp, absolute)
	if replace_error != OK:
		if FileAccess.file_exists(path + ".bak"):
			DirAccess.rename_absolute(absolute_backup, absolute)
		return _error("save_replace_failed", "无法替换存档文件。")
	return {"ok": true, "code": "ok", "message": "", "path": path, "header": header}


func load_slot(slot_id: String) -> Dictionary:
	if slot_id not in SLOT_IDS:
		return _error("slot_invalid", "存档槽位无效。")
	var path := _slot_path(slot_id)
	var result := _read_container(path, true)
	if not bool(result.get("ok", false)):
		result = _read_container(path + ".bak", true)
	if not bool(result.get("ok", false)):
		return result
	if not _compatible(result.header):
		if _technology_industry_revision(result.header) != TECHNOLOGY_INDUSTRY_REVISION:
			return _error("technology_industry_revision_incompatible", LEGACY_INDUSTRY_REASON)
		return _error("save_incompatible", "存档由不兼容的生成器或版本创建。")
	result["slot_id"] = slot_id
	return result


func load_preview(slot_id: String) -> Dictionary:
	if slot_id not in SLOT_IDS:
		return _error("slot_invalid", "存档槽位无效。")
	var path := _slot_path(slot_id)
	var result := _read_section(path, "preview", false)
	if not bool(result.get("ok", false)):
		result = _read_section(path + ".bak", "preview", false)
	return result


func delete_manual_slot(slot_id: String) -> Dictionary:
	if slot_id not in ["manual_1", "manual_2", "manual_3"]:
		return _error("slot_invalid", "只能删除手动存档。")
	for suffix in ["", ".bak", ".tmp"]:
		var path: String = _slot_path(slot_id) + String(suffix)
		if FileAccess.file_exists(path):
			var error := DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
			if error != OK:
				return _error("save_delete_failed", "无法删除存档。")
	return {"ok": true, "code": "ok", "message": ""}


static func compatibility_hash() -> String:
	# Provider manifests and native schema readers own PKCN/PKEC/PKCM/PKGP
	# compatibility; keep the container hash stable so legacy saves can migrate.
	var input := "project-keynes|generator-v1|datacore-schema|pkcn|pkec-v19"
	return _sha256(input.to_utf8_buffer())


func _read_container(path: String, read_sections: bool,
		validate_sections: bool = false) -> Dictionary:
	if not FileAccess.file_exists(path):
		return _error("save_missing", "存档不存在。")
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() < 12:
		return _error("save_truncated", "存档已截断。")
	var magic := file.get_buffer(4).get_string_from_ascii()
	var version := file.get_32()
	var header_length := file.get_32()
	if magic != MAGIC or version != FORMAT_VERSION or header_length <= 0 \
			or header_length > file.get_length() - 12:
		return _error("save_header_invalid", "存档头无效。")
	var parsed = JSON.parse_string(file.get_buffer(header_length).get_string_from_utf8())
	if not parsed is Dictionary:
		return _error("save_header_invalid", "存档头无法解析。")
	var header := parsed as Dictionary
	var result := {"ok": true, "code": "ok", "message": "", "header": header}
	if not read_sections and not validate_sections:
		return result
	var payload_start := file.get_position()
	var decoded := {}
	for raw in header.get("sections", []):
		var entry := raw as Dictionary
		var offset := int(entry.get("offset", -1))
		var length := int(entry.get("length", -1))
		var uncompressed := int(entry.get("uncompressed_length", -1))
		if offset < 0 or length < 0 or uncompressed < 0 \
				or payload_start + offset + length > file.get_length():
			return _error("save_section_truncated", "存档 section 已截断。")
		file.seek(payload_start + offset)
		var bytes := PackedByteArray()
		if uncompressed > 0:
			bytes = file.get_buffer(length).decompress(
				uncompressed, FileAccess.COMPRESSION_ZSTD)
		if bytes.size() != uncompressed:
			return _error("save_section_decompress_failed", "存档 section 解压失败。")
		var digest := _sha256(bytes)
		if digest != String(entry.get("sha256", "")):
			return _error("save_section_checksum_failed", "存档 section 校验失败。")
		if read_sections:
			decoded[String(entry.get("id", ""))] = bytes
	if read_sections:
		result["section_bytes"] = decoded
	return result


func _read_section(path: String, section_id: String,
		require_compatibility: bool = true) -> Dictionary:
	if not FileAccess.file_exists(path):
		return _error("save_missing", "存档不存在。")
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() < 12:
		return _error("save_truncated", "存档已截断。")
	var magic := file.get_buffer(4).get_string_from_ascii()
	var version := file.get_32()
	var header_length := file.get_32()
	if magic != MAGIC or version != FORMAT_VERSION or header_length <= 0 \
			or header_length > file.get_length() - 12:
		return _error("save_header_invalid", "存档头无效。")
	var parsed = JSON.parse_string(file.get_buffer(header_length).get_string_from_utf8())
	if not parsed is Dictionary:
		return _error("save_header_invalid", "存档头无法解析。")
	var header := parsed as Dictionary
	if require_compatibility and not _compatible(header):
		return _error("save_incompatible", "存档版本不兼容。")
	var payload_start := file.get_position()
	for raw in header.get("sections", []):
		var entry := raw as Dictionary
		if String(entry.get("id", "")) != section_id:
			continue
		var offset := int(entry.get("offset", -1))
		var length := int(entry.get("length", -1))
		var uncompressed := int(entry.get("uncompressed_length", -1))
		if offset < 0 or length < 0 or uncompressed < 0 \
				or payload_start + offset + length > file.get_length():
			return _error("save_section_truncated", "存档 section 已截断。")
		file.seek(payload_start + offset)
		var bytes := PackedByteArray()
		if uncompressed > 0:
			bytes = file.get_buffer(length).decompress(
				uncompressed, FileAccess.COMPRESSION_ZSTD)
		if bytes.size() != uncompressed:
			return _error("save_section_decompress_failed", "存档 section 解压失败。")
		if _sha256(bytes) != String(entry.get("sha256", "")):
			return _error("save_section_checksum_failed", "存档 section 校验失败。")
		return {"ok": true, "code": "ok", "message": "", "bytes": bytes,
			"header": header}
	return _error("save_provider_missing", "存档缺少预览 section。")


func _compatible(header: Dictionary) -> bool:
	return int(header.get("format_version", -1)) == FORMAT_VERSION \
		and String(header.get("generator_hash", "")) == compatibility_hash() \
		and _technology_industry_revision(header) == TECHNOLOGY_INDUSTRY_REVISION


func _reason_for(read: Dictionary, header: Dictionary) -> String:
	if not bool(read.get("ok", false)):
		return String(read.get("message", "存档损坏。"))
	if _technology_industry_revision(header) != TECHNOLOGY_INDUSTRY_REVISION:
		return LEGACY_INDUSTRY_REASON
	return "" if _compatible(header) else "存档版本或生成器不兼容。"


func _technology_industry_revision(header: Dictionary) -> int:
	return int(header.get("technology_industry_revision",
		LEGACY_TECHNOLOGY_INDUSTRY_REVISION))


func _slot_path(slot_id: String) -> String:
	return "%s/%s.pksv" % [_save_dir, slot_id]


func _ensure_directory() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_save_dir))


static func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "message": message}


static func _sha256(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	if not bytes.is_empty():
		context.update(bytes)
	return context.finish().hex_encode()
