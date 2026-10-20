extends "res://tests/economy/goods_storage_schema_test.gd"

# Reuse the existing native economy fixture; only run this persistence case.
func _run() -> void:
	var catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	var profile := _native_profile(false, 1)
	var source := _new_ext(1, 0.1)
	_expect("country bootstraps", CountryTestHelper.configure_all_technologies(source, catalog, 1, 42))
	_expect("economy configures", bool(source.configure_economy(catalog, profile, 1, 42).get("ok", false)))
	var signature := (catalog.signature_keys as PackedStringArray).find("worker|default")
	source.bootstrap_economy({"cell_indices": PackedInt32Array([0]),
		"signature_ids": PackedInt32Array([signature]), "population": PackedInt64Array([100]),
		"funds": PackedInt64Array([10000000])}, {})
	_expect("economy commits", bool(_run_day(source, 0).get("done", false)))
	source.begin_country_save(65536)
	var country_chunks: Array[PackedByteArray] = []
	while true:
		var bytes: PackedByteArray = source.read_country_save_chunk(65536)
		if bytes.is_empty():
			break
		country_chunks.append(bytes)
	source.end_country_save()
	source.begin_economy_save(65536)
	var chunks: Array[PackedByteArray] = []
	while true:
		var bytes: PackedByteArray = source.read_economy_save_chunk(65536)
		if bytes.is_empty():
			break
		chunks.append(bytes)
	source.end_economy_save()
	var empty_signature := 0
	var used := PackedInt32Array()
	for chunk in chunks:
		if chunk.decode_u16(6) == 1:
			for lane in 64:
				var at := 16 + 12 + lane * 122
				if chunk[at] != 0:
					used.append(chunk.decode_u32(at + 1))
	while used.has(empty_signature):
		empty_signature += 1
	var empty_at := -1
	var page_chunk := -1
	for i in chunks.size():
		var chunk := chunks[i]
		if chunk.decode_u16(6) == 0:
			chunk.encode_s64(32, chunk.decode_s64(32) + 1)
		elif chunk.decode_u16(6) == 1 and page_chunk < 0:
			for lane in 64:
				var at := 16 + 12 + lane * 122
				if chunk[at] == 0:
					chunk[at] = 1
					chunk.encode_u32(at + 1, empty_signature)
					chunk.encode_u32(at + 5, 7)
					chunk.encode_s64(at + 9, 0)
					chunk.encode_s64(at + 17, 0)
					empty_at = at
					page_chunk = i
					break
		chunks[i] = chunk
	_expect("fixture adds an allocated empty handle", page_chunk >= 0)
	if page_chunk < 0:
		_finish()
		return
	var target := _restore_fixture(catalog, profile, country_chunks, chunks)
	_expect("zero population lane restores", bool(target.result.get("ok", false)))
	if bool(target.result.get("ok", false)):
		var saved: Dictionary = target.ext.capture_economy_ecp2(0)
		_expect("empty handle can be saved again", bool(saved.get("ok", false)))
		var before: int = target.ext.get_economy_state_hash()
		var restored: Dictionary = target.ext.restore_economy_ecp2(saved.get("bytes", PackedByteArray()))
		_expect("ECP2 restores empty handle exactly", bool(restored.get("ok", false))
			and int(target.ext.get_economy_state_hash()) == before)
	var invalid := chunks[page_chunk].duplicate()
	invalid.encode_s64(empty_at + 9, -1)
	chunks[page_chunk] = invalid
	var negative := _restore_fixture(catalog, profile, country_chunks, chunks)
	_expect("negative population remains rejected",
		String(negative.result.get("reason", "")) == "restore_cohort_record_invalid")
	invalid.encode_s64(empty_at + 9, 0)
	invalid.encode_s64(empty_at + 71, 1) # employee_employed
	chunks[page_chunk] = invalid
	var employed := _restore_fixture(catalog, profile, country_chunks, chunks)
	_expect("empty lane cannot hold jobs",
		String(employed.result.get("reason", "")) == "restore_cohort_employment_invalid")
	_finish()


func _restore_fixture(catalog: Dictionary, profile: Dictionary,
		country_chunks: Array[PackedByteArray], chunks: Array[PackedByteArray]) -> Dictionary:
	var ext := _new_ext(1, 0.1)
	ext.configure_economy(catalog, profile, 1, 42)
	ext.begin_country_restore()
	for chunk in country_chunks:
		ext.feed_country_restore_chunk(chunk)
	ext.end_country_restore()
	ext.begin_economy_restore()
	for chunk in chunks:
		var fed: Dictionary = ext.feed_economy_restore_chunk(chunk)
		if not bool(fed.get("ok", false)):
			return {"ext": ext, "result": fed}
	return {"ext": ext, "result": ext.end_economy_restore()}
