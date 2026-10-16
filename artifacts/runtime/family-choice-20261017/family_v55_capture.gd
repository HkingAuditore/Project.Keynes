extends "res://tests/family_founding_offer_runtime_test.gd"

func _init() -> void:
	var catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	catalog.erase("ok")
	_prepare_catalog(catalog)
	var ext := _boot(catalog, "PLAYER", 240, 261004)
	_run_day(ext, 0)
	var file := FileAccess.open("res://tmp/family_v55_fixture.bin", FileAccess.WRITE)
	file.store_64(ext.get_economy_state_hash())
	ext.begin_economy_save(4096)
	for i in 4096:
		var chunk: PackedByteArray = ext.read_economy_save_chunk(4096)
		if chunk.is_empty():
			break
		file.store_32(chunk.size())
		file.store_buffer(chunk)
	file.close()
	print(ext.end_economy_save())
	quit()
