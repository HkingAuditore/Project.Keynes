extends SceneTree

const Reader = preload("res://scripts/game/save_container_reader.gd")
const Repository = preload("res://scripts/game/save_repository.gd")
const TEST_DIR := "user://test_save_container_validation"
var checks := 0
var failures := 0

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	_cleanup()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TEST_DIR))
	var bytes := PackedByteArray([1, 2, 3])
	var compressed := bytes.compress(FileAccess.COMPRESSION_ZSTD)
	var header := {"magic": "PKSV", "format_version": 2, "sections": [{
		"id": "preview", "offset": 0, "length": compressed.size(),
		"uncompressed_length": bytes.size(), "sha256": Reader.sha256(bytes)}]}
	_write(header, compressed)
	_expect("valid file can load", bool(Reader.read_container(_path(), true).ok))
	var bad := header.duplicate(true)
	bad.sections[0].uncompressed_length = Reader.MAX_SECTION_BYTES + 1
	_reject("oversized decompression", bad, compressed)
	bad = header.duplicate(true)
	bad.sections[0].length = 9223372036854775807
	_reject("overflowing encoded length", bad, compressed)
	for value in [-1, 0.5, "0", null, true, {}, []]:
		bad = header.duplicate(true)
		bad.sections[0].offset = value
		_reject("invalid offset type/value", bad, compressed)
	bad = header.duplicate(true)
	bad.sections.append(bad.sections[0].duplicate(true))
	_reject("duplicate section identity", bad, compressed)
	bad.sections[1].id = "second"
	_reject("overlapping payload ranges", bad, compressed)
	bad = header.duplicate(true)
	bad.sections[0].length = compressed.size() + 1
	_reject("truncated payload", bad, compressed)
	bad = header.duplicate(true)
	bad.sections[0].sha256 = "q".repeat(64)
	_reject("invalid digest", bad, compressed)
	bad = header.duplicate(true)
	bad.sections = [null]
	_reject("non-object table entry", bad, compressed)
	bad = header.duplicate(true)
	bad.sections = {}
	_reject("non-array table", bad, compressed)
	bad = header.duplicate(true)
	bad.country_name = {}
	_reject("malformed display metadata", bad, compressed)
	bad = header.duplicate(true)
	bad.provider_manifest = [{"provider_id": "pkcn", "schema_version": [], "sections": []}]
	_reject("malformed provider metadata", bad, compressed)
	bad = header.duplicate(true)
	bad.sections[0].uncompressed_length = 0
	_reject("empty decoded section with encoded payload", bad, compressed)
	bad = header.duplicate(true)
	bad.sections.clear()
	for i in range(3):
		var entry: Dictionary = header.sections[0].duplicate(true)
		entry.id = "part_%d" % i
		entry.offset = i
		entry.length = 1
		entry.uncompressed_length = Reader.MAX_SECTION_BYTES
		bad.sections.append(entry)
	_reject("excessive combined decoded size", bad, compressed)
	var file := FileAccess.open(_path(), FileAccess.WRITE)
	file.store_buffer("PKSV".to_ascii_buffer())
	file.store_32(2)
	file.store_32(Reader.MAX_HEADER_BYTES + 1)
	file.close()
	_expect("oversized header rejected before allocation", Reader.read_container(_path()).get("code") == "save_header_invalid")
	_benchmark_listing()
	_cleanup()
	print("save container validation: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _reject(label: String, header: Dictionary, payload: PackedByteArray) -> void:
	_write(header, payload)
	_expect(label + " (metadata)", not bool(Reader.read_container(_path()).ok))
	_expect(label + " (full load)", not bool(Reader.read_container(_path(), true).ok))
	_expect(label + " (preview)", not bool(Reader.read_container(_path(), false, false, "preview").ok))

func _benchmark_listing() -> void:
	var repository = Repository.new(TEST_DIR)
	var bytes := PackedByteArray()
	bytes.resize(16 * 1024 * 1024)
	bytes.fill(42)
	for slot in Repository.SLOT_IDS:
		_expect("benchmark fixture writes", bool(repository.write_slot(slot, {}, {"payload": bytes}).ok))
	var started := Time.get_ticks_usec()
	var slots: Array = repository.list_slots()
	var header_usec := Time.get_ticks_usec() - started
	started = Time.get_ticks_usec()
	var verified: Array = repository.list_slots(true)
	var full_usec := Time.get_ticks_usec() - started
	_expect("header and verified lists expose same valid slots", slots.size() == verified.size() and bool(verified[0].integrity_checked) and not bool(slots[0].integrity_checked))
	print("save listing (four 16 MiB payloads): headers=%.3f ms full=%.3f ms" % [header_usec / 1000.0, full_usec / 1000.0])

func _write(header: Dictionary, payload: PackedByteArray) -> void:
	var file := FileAccess.open(_path(), FileAccess.WRITE)
	var encoded := JSON.stringify(header).to_utf8_buffer()
	file.store_buffer("PKSV".to_ascii_buffer())
	file.store_32(2)
	file.store_32(encoded.size())
	file.store_buffer(encoded)
	file.store_buffer(payload)
	file.close()

func _path() -> String:
	return TEST_DIR.path_join("malformed.pksv")

func _cleanup() -> void:
	for file in DirAccess.get_files_at(TEST_DIR) if DirAccess.dir_exists_absolute(TEST_DIR) else []:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_DIR.path_join(file)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_DIR))

func _expect(label: String, condition: bool) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("[FAIL] " + label)
