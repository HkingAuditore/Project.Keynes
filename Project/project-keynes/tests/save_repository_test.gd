extends SceneTree

const RepositoryScript = preload("res://scripts/game/save_repository.gd")
const TEST_DIR := "user://test_game_flow_saves"
var _checks := 0
var _failures := 0


func _init() -> void:
	_cleanup()
	var repository = RepositoryScript.new(TEST_DIR)
	var empty_slots: Array = repository.list_slots()
	_expect("empty repository exposes four empty slots", empty_slots.size() == 4 \
		and not bool(empty_slots[0].exists) and not bool(empty_slots[3].exists))
	var sections := {
		"config": {"version": 1, "country": "Test"},
		"bytes": PackedByteArray([1, 2, 3, 4]),
		"preview": PackedByteArray([137, 80, 78, 71]),
	}
	var written: Dictionary = repository.write_slot("manual_1", {
		"country_name": "Test", "day": 12, "seed": 42, "width": 40, "height": 28,
		"saved_at": "test",
	}, sections)
	_expect("write succeeds", bool(written.ok))
	_expect("new save declares technology industry revision 2",
		int(written.header.get("technology_industry_revision", 0)) == 2)
	var loaded: Dictionary = repository.load_slot("manual_1")
	_expect("load succeeds", bool(loaded.ok))
	_expect("variant section round trips", bytes_to_var(loaded.section_bytes.config).country == "Test")
	_expect("raw section round trips", loaded.section_bytes.bytes == PackedByteArray([1, 2, 3, 4]))
	_expect("single preview section loads without decoding the container",
		repository.load_preview("manual_1").get("bytes", PackedByteArray()) == sections.preview)
	var slots: Array = repository.list_slots()
	_expect("four fixed slots", slots.size() == 4)
	_expect("metadata visible", bool(slots[0].loadable) and String(slots[0].country_name) == "Test")

	var replacement := sections.duplicate(true)
	replacement.config.country = "Replacement"
	_expect("overwrite succeeds", bool(repository.write_slot("manual_1", {
		"country_name": "Replacement", "day": 13, "seed": 43,
		"width": 40, "height": 28, "saved_at": "replacement",
	}, replacement).ok))
	_corrupt_last_byte("manual_1.pksv")
	var recovered: Dictionary = repository.load_slot("manual_1")
	_expect("corrupt replacement recovers the last verified backup",
		bool(recovered.get("ok", false)) \
		and bytes_to_var(recovered.section_bytes.config).country == "Test")

	repository.write_slot("manual_2", written.header, sections)
	_rewrite_legacy_industry_header("manual_2.pksv")
	var legacy_slots := repository.list_slots()
	_expect("legacy industry save stays visible and disabled",
		bool(legacy_slots[1].exists) and not bool(legacy_slots[1].loadable) \
		and String(legacy_slots[1].reason).contains("旧产业科技规则"))
	_expect("missing industry revision is reported as revision 1",
		int(legacy_slots[1].technology_industry_revision) == 1)
	_expect("legacy industry save preview remains readable",
		repository.load_preview("manual_2").get("bytes", PackedByteArray()) \
		== sections.preview)
	var legacy_load := repository.load_slot("manual_2")
	_expect("legacy industry save is rejected before load",
		not bool(legacy_load.get("ok", false)) \
		and String(legacy_load.get("code", "")) \
		== "technology_industry_revision_incompatible")
	repository.write_slot("manual_3", written.header, sections)
	_rewrite_incompatible_header("manual_3.pksv")
	_expect("native-incompatible save preview remains readable",
		repository.load_preview("manual_3").get("bytes", PackedByteArray()) \
		== sections.preview)
	repository.write_slot("autosave", written.header, sections)
	_corrupt_last_byte("autosave.pksv")
	var invalid_slots := repository.list_slots()
	_expect("legacy save stays visible and disabled",
		bool(invalid_slots[1].exists) and not bool(invalid_slots[1].loadable) \
		and not String(invalid_slots[1].reason).is_empty())
	_expect("incompatible save stays visible and disabled",
		bool(invalid_slots[2].exists) and not bool(invalid_slots[2].loadable) \
		and not String(invalid_slots[2].reason).is_empty())
	_expect("checksum-corrupt save stays visible and disabled",
		bool(invalid_slots[3].exists) and not bool(invalid_slots[3].loadable) \
		and not String(invalid_slots[3].reason).is_empty())
	_cleanup()
	print("save repository: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _cleanup() -> void:
	var absolute := ProjectSettings.globalize_path(TEST_DIR)
	if DirAccess.dir_exists_absolute(absolute):
		for file_name in DirAccess.get_files_at(TEST_DIR):
			DirAccess.remove_absolute(absolute.path_join(file_name))
		DirAccess.remove_absolute(absolute)


func _corrupt_last_byte(file_name: String) -> void:
	var path := "%s/%s" % [TEST_DIR, file_name]
	var file := FileAccess.open(path, FileAccess.READ_WRITE)
	if file == null or file.get_length() <= 0:
		return
	file.seek(file.get_length() - 1)
	var value := file.get_8()
	file.seek(file.get_length() - 1)
	file.store_8(value ^ 0xff)
	file.close()


func _write_truncated(file_name: String) -> void:
	var file := FileAccess.open("%s/%s" % [TEST_DIR, file_name], FileAccess.WRITE)
	if file != null:
		file.store_buffer(PackedByteArray([80, 75, 83, 86]))
		file.close()


func _rewrite_incompatible_header(file_name: String) -> void:
	_rewrite_header(file_name, false)


func _rewrite_legacy_industry_header(file_name: String) -> void:
	_rewrite_header(file_name, true)


func _rewrite_header(file_name: String, erase_industry_revision: bool) -> void:
	var path := "%s/%s" % [TEST_DIR, file_name]
	var source := FileAccess.open(path, FileAccess.READ)
	if source == null or source.get_length() < 12:
		return
	var magic := source.get_buffer(4)
	var version := source.get_32()
	var header_length := source.get_32()
	var header = JSON.parse_string(source.get_buffer(header_length).get_string_from_utf8())
	if not header is Dictionary:
		return
	var payload := source.get_buffer(source.get_length() - source.get_position())
	source.close()
	if erase_industry_revision:
		header.erase("technology_industry_revision")
	else:
		header.generator_hash = "0".repeat(64)
	var header_bytes := JSON.stringify(header).to_utf8_buffer()
	var output := FileAccess.open(path, FileAccess.WRITE)
	output.store_buffer(magic)
	output.store_32(version)
	output.store_32(header_bytes.size())
	output.store_buffer(header_bytes)
	output.store_buffer(payload)
	output.close()


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("[FAIL] %s" % label)
