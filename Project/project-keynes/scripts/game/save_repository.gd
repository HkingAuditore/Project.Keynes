class_name SaveRepository
extends RefCounted

const ContainerReader = preload("res://scripts/game/save_container_reader.gd")
const FORMAT_VERSION := ContainerReader.FORMAT_VERSION
const MAGIC := "PKSV"
const LEGACY_FORMAT_REASON := "该存档使用 PKSV v1 格式，与当前 PKSV v2 不兼容。旧存档会保留，但不能载入。"
const TECHNOLOGY_INDUSTRY_REVISION := 2
const LEGACY_TECHNOLOGY_INDUSTRY_REVISION := 1
const LEGACY_INDUSTRY_REASON := "该存档使用旧产业科技规则，无法载入当前版本。请新建游戏或从兼容版本继续。"
const SAVE_DIR := "user://saves"
const SLOT_IDS := ["manual_1", "manual_2", "manual_3", "autosave"]
var _save_dir: String


## 诊断用存档目录重定向。给定一份玩家 .pksv 后，复现工具把它拷进一个临时目录再
## 指向这里，这样"加载玩家存档续跑"不需要覆盖玩家自己的槽位。仅调试构建生效，
## 导出的正式版本永远用 SAVE_DIR。
const SAVE_DIR_OVERRIDE_ENV := "PK_SAVE_DIR"


func _init(save_dir: String = "") -> void:
	if save_dir.is_empty():
		save_dir = SAVE_DIR
		if OS.is_debug_build():
			var override := OS.get_environment(SAVE_DIR_OVERRIDE_ENV).strip_edges()
			if not override.is_empty():
				save_dir = override
				print("[save-repository] slot directory overridden to %s" % override)
	_save_dir = save_dir


## Header-only by default. Full checks run in the background or on actual load.
func list_slots(validate_sections: bool = false) -> Array:
	_ensure_directory()
	var slots: Array = []
	for slot_id in SLOT_IDS:
		var path := _slot_path(slot_id)
		var read := _read_container(path, false, validate_sections)
		if not bool(read.get("ok", false)):
			var backup := _read_container(path + ".bak", false, validate_sections)
			if bool(backup.get("ok", false)):
				read = backup
		var header: Dictionary = read.get("header", {})
		var format_version := int(read.get("format_version", -1))
		if format_version < 0:
			format_version = _peek_format_version(path)
			if format_version < 0:
				format_version = _peek_format_version(path + ".bak")
		var exists := FileAccess.file_exists(path) or FileAccess.file_exists(path + ".bak")
		slots.append({
			"slot_id": slot_id,
			"exists": exists,
			"integrity_checked": validate_sections and bool(read.get("ok", false)),
			"loadable": bool(read.get("ok", false)) and _compatible(header),
			"incompatible": exists and (not bool(read.get("ok", false)) or not _compatible(header)),
			"format_version": format_version,
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


func verify_slots_background(completion: Array) -> void:
	completion.append(list_slots(true))


## WorkerThreadPool 入口：调用方先把全部 section 冻结为 PackedByteArray。
## completion 只由此任务写，调用方在 wait_for_task_completion 后读取。
func write_slot_background(slot_id: String, header_fields: Dictionary,
		sections: Dictionary, completion: Array[Dictionary],
		provider_hash_payloads: Array = []) -> void:
	var header := header_fields.duplicate(true)
	var manifest: Array = header.get("provider_manifest", [])
	var seen := {}
	for payload in provider_hash_payloads:
		var index := int(payload.get("manifest_index", -1))
		if index < 0 or index >= manifest.size() or seen.has(index) \
				or not payload.get("bytes") is PackedByteArray:
			completion.append(_error("save_provider_hash_invalid", "Provider hash payload is invalid."))
			return
		seen[index] = true
		var state_hash := _sha256(payload.bytes)
		if payload.has("expected_hash") and state_hash != String(payload.expected_hash):
			completion.append(_error("save_provider_hash_mismatch", "Provider hash differs from the boundary reference."))
			return
		manifest[index]["state_hash"] = state_hash
	completion.append(write_slot(slot_id, header, sections))


func write_slot(slot_id: String, header_fields: Dictionary, sections: Dictionary) -> Dictionary:
	if slot_id not in SLOT_IDS:
		return _error("slot_invalid", "存档槽位无效。")
	_ensure_directory()
	var section_table: Array = []
	var normalized_sections: Dictionary = sections.duplicate(true)
	# PKSV v2 always carries the runtime section.  Low-level repository tests and
	# legacy callers may omit it; an empty section keeps the container shape
	# valid while the runtime coordinator supplies the authoritative payload.
	if not normalized_sections.has("simulation_runtime"):
		normalized_sections["simulation_runtime"] = PackedByteArray()
	if normalized_sections.size() > ContainerReader.MAX_SECTIONS:
		return _error("save_too_large", "存档数据数量超过容量限制。")
	var total_bytes := 0
	var blocks: Array[PackedByteArray] = []
	var offset := 0
	var section_ids := normalized_sections.keys()
	section_ids.sort()
	for raw_id in section_ids:
		if not raw_id is String or raw_id.is_empty():
			return _error("save_section_table_invalid", "存档数据名称无效。")
		var section_id := String(raw_id)
		var bytes: PackedByteArray = normalized_sections[raw_id] if normalized_sections[raw_id] is PackedByteArray \
			else var_to_bytes(normalized_sections[raw_id])
		if bytes.size() > ContainerReader.MAX_SECTION_BYTES \
				or bytes.size() > ContainerReader.MAX_TOTAL_BYTES - total_bytes:
			return _error("save_too_large", "存档数据超过容量限制。")
		total_bytes += bytes.size()
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
	if header_bytes.size() > ContainerReader.MAX_HEADER_BYTES:
		return _error("save_too_large", "存档头超过容量限制。")
	# Validate the on-disk JSON types, including packed provider section arrays.
	var encoded_header = JSON.parse_string(header_bytes.get_string_from_utf8())
	if not encoded_header is Dictionary:
		return _error("save_header_invalid", "存档头无法编码。")
	var checked := ContainerReader.validate_header(encoded_header, offset)
	if not bool(checked.ok):
		return checked
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
		var backup := _read_container(path + ".bak", true)
		if bool(backup.get("ok", false)):
			result = backup
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
	return ContainerReader.read_container(path, read_sections, validate_sections)


func _read_section(path: String, section_id: String,
		require_compatibility: bool = true) -> Dictionary:
	var result := ContainerReader.read_container(path, false, false, section_id)
	if bool(result.get("ok", false)) and require_compatibility and not _compatible(result.header):
		return _error("save_incompatible", "存档版本不兼容。")
	return result


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


func _peek_format_version(path: String) -> int:
	if not FileAccess.file_exists(path):
		return -1
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() < 8:
		return -1
	if file.get_buffer(4).get_string_from_ascii() != MAGIC:
		return -1
	return file.get_32()


func _ensure_directory() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_save_dir))


static func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "message": message}


static func _sha256(bytes: PackedByteArray) -> String:
	return ContainerReader.sha256(bytes)
