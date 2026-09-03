extends SceneTree

func _initialize() -> void:
	_inspect_path("user://saves/autosave.pksv")
	_inspect_path("user://saves/autosave.pksv.bak")
	quit(0)


func _inspect_path(path: String) -> void:
	print("=== %s ===" % path)
	if not FileAccess.file_exists(path):
		print("missing")
		return
	var file := FileAccess.open(path, FileAccess.READ)
	var magic := file.get_buffer(4).get_string_from_ascii()
	var version := file.get_32()
	var header_length := file.get_32()
	var header = JSON.parse_string(file.get_buffer(header_length).get_string_from_utf8())
	print("day=%s country=%s" % [str(header.get("day", "?")), str(header.get("country_name", "?"))])
	var payload_start := file.get_position()
	for raw in header.get("sections", []):
		var entry := raw as Dictionary
		if String(entry.get("id", "")) != "pkfg":
			continue
		file.seek(payload_start + int(entry.offset))
		var compressed := file.get_buffer(int(entry.length))
		var bytes := compressed.decompress(int(entry.uncompressed_length), FileAccess.COMPRESSION_ZSTD)
		var pkfg = bytes_to_var(bytes)
		if not pkfg is Dictionary:
			print("pkfg not dict")
			return
		var explored := PackedByteArray(pkfg.get("explored", PackedByteArray()))
		var nonzero := 0
		for b in explored:
			if int(b) != 0:
				nonzero += 1
		print("pkfg version=%s cells=%s explored_nonzero=%d/%d intel_cells=%d" % [
			str(pkfg.get("version", "")),
			str(pkfg.get("cells", "")),
			nonzero,
			explored.size(),
			PackedInt32Array(pkfg.get("building_intel_cells", PackedInt32Array())).size(),
		])
		return
	print("no pkfg section")
