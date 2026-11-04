extends RefCounted

## One parser for metadata, preview, verification and full loads. Never allocate
## a compressed/decompressed block before validating the complete section table.
const FORMAT_VERSION := 2
const MAGIC := "PKSV"
const LEGACY_FORMAT_REASON := "该存档使用 PKSV v1 格式，与当前 PKSV v2 不兼容。旧存档会保留，但不能载入。"
const MAX_HEADER_BYTES := 1024 * 1024
const MAX_SECTIONS := 128
const MAX_SECTION_BYTES := 512 * 1024 * 1024
const MAX_TOTAL_BYTES := 1024 * 1024 * 1024


static func read_container(path: String, read_sections: bool = false,
		validate_sections: bool = false, section_id: String = "") -> Dictionary:
	if not FileAccess.file_exists(path):
		return _error("save_missing", "存档不存在。")
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() < 12:
		return _error("save_truncated", "存档已截断。")
	var magic := file.get_buffer(4).get_string_from_ascii()
	var version := file.get_32()
	var header_length := file.get_32()
	if magic != MAGIC:
		return _error("save_header_invalid", "存档头无效。")
	if version != FORMAT_VERSION:
		var error := _error("save_format_version_incompatible", LEGACY_FORMAT_REASON \
			if version == 1 else "存档格式版本不受支持。")
		error["format_version"] = version
		return error
	if header_length <= 0 or header_length > MAX_HEADER_BYTES \
			or header_length > file.get_length() - 12:
		return _error("save_header_invalid", "存档头长度无效。")
	var parsed = JSON.parse_string(file.get_buffer(header_length).get_string_from_utf8())
	if not parsed is Dictionary:
		return _error("save_header_invalid", "存档头无法解析。")
	var header: Dictionary = parsed
	var payload_start := file.get_position()
	var checked := validate_header(header, file.get_length() - payload_start)
	if not bool(checked.ok):
		return checked
	var result := {"ok": true, "code": "ok", "message": "", "header": header,
		"format_version": version}
	if not read_sections and not validate_sections and section_id.is_empty():
		return result
	var decoded := {}
	for entry in header.sections:
		if not section_id.is_empty() and entry.id != section_id:
			continue
		file.seek(payload_start + int(entry.offset))
		var length := int(entry.length)
		var uncompressed := int(entry.uncompressed_length)
		var compressed := file.get_buffer(length)
		if compressed.size() != length:
			return _error("save_section_truncated", "存档数据已截断。")
		var bytes := PackedByteArray()
		if uncompressed > 0:
			bytes = compressed.decompress(uncompressed, FileAccess.COMPRESSION_ZSTD)
		if bytes.size() != uncompressed:
			return _error("save_section_decompress_failed", "存档数据解压失败。")
		if sha256(bytes) != entry.sha256:
			return _error("save_section_checksum_failed", "存档数据校验失败。")
		if not section_id.is_empty():
			result["bytes"] = bytes
			return result
		if read_sections:
			decoded[entry.id] = bytes
	if not section_id.is_empty():
		return _error("save_provider_missing", "存档缺少所需数据。")
	if read_sections:
		result["section_bytes"] = decoded
	return result


static func validate_header(header: Dictionary, payload_length: int) -> Dictionary:
	if header.get("magic") != MAGIC or not _integer(header.get("format_version"), FORMAT_VERSION) \
			or int(header.format_version) != FORMAT_VERSION:
		return _error("save_header_invalid", "存档头格式无效。")
	for key in ["country_name", "saved_at", "generator_hash", "reason", "application_version"]:
		if header.has(key) and not header[key] is String:
			return _error("save_header_invalid", "存档头字段类型无效。")
	for key in ["day", "width", "height", "technology_industry_revision"]:
		if header.has(key) and not _integer(header[key], 9007199254740991):
			return _error("save_header_invalid", "存档头数值无效。")
	if header.has("seed") and not _integer(header.seed, 9007199254740991, -9007199254740991):
		return _error("save_header_invalid", "存档种子无效。")
	var manifest = header.get("provider_manifest", [])
	if not manifest is Array or manifest.size() > MAX_SECTIONS:
		return _error("save_header_invalid", "存档版本清单无效。")
	var providers := {}
	for entry in manifest:
		if not entry is Dictionary or not entry.get("provider_id") is String \
				or providers.has(entry.provider_id) or not _integer(entry.get("schema_version"), 2147483647) \
				or not entry.get("sections", []) is Array:
			return _error("save_header_invalid", "存档版本清单无效。")
		providers[entry.provider_id] = true
		for id in entry.get("sections", []):
			if not id is String:
				return _error("save_header_invalid", "存档版本清单无效。")
	var sections = header.get("sections")
	if not sections is Array or sections.is_empty() or sections.size() > MAX_SECTIONS:
		return _error("save_section_table_invalid", "存档数据目录无效。")
	var ids := {}
	var intervals: Array = []
	var total := 0
	for entry in sections:
		if not entry is Dictionary or not entry.get("id") is String \
				or entry.id.is_empty() or ids.has(entry.id) \
				or not _integer(entry.get("offset"), MAX_TOTAL_BYTES) \
				or not _integer(entry.get("length"), MAX_SECTION_BYTES) \
				or not _integer(entry.get("uncompressed_length"), MAX_SECTION_BYTES) \
				or not _digest(entry.get("sha256")):
			return _error("save_section_table_invalid", "存档数据目录无效或超过容量限制。")
		ids[entry.id] = true
		var offset := int(entry.offset)
		var length := int(entry.length)
		var size := int(entry.uncompressed_length)
		if offset > payload_length or length > payload_length - offset:
			return _error("save_section_truncated", "存档数据已截断。")
		if (length == 0) != (size == 0) or size > MAX_TOTAL_BYTES - total:
			return _error("save_section_table_invalid", "存档数据大小无效或超过容量限制。")
		total += size
		if length > 0:
			intervals.append([offset, offset + length])
	intervals.sort_custom(func(a, b): return a[0] < b[0])
	var previous_end := 0
	for interval in intervals:
		if interval[0] < previous_end:
			return _error("save_section_table_invalid", "存档数据范围重叠。")
		previous_end = interval[1]
	return {"ok": true}


static func _integer(value, maximum: int, minimum: int = 0) -> bool:
	if not (value is int or value is float):
		return false
	return is_finite(float(value)) and value >= minimum and value <= maximum \
		and value == floor(value)


static func _digest(value) -> bool:
	if not value is String or value.length() != 64:
		return false
	for c in value:
		if c not in "0123456789abcdef":
			return false
	return true


static func sha256(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	if not bytes.is_empty():
		context.update(bytes)
	return context.finish().hex_encode()


static func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "message": message}
