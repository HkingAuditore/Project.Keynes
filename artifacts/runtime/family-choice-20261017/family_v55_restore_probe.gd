extends "res://tests/family_founding_offer_runtime_test.gd"

func _init() -> void:
	var catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	catalog.erase("ok")
	_prepare_catalog(catalog)
	var ext := _new_ext(catalog)
	_configure_country(ext, catalog, 261004)
	ext.configure_economy(catalog, _profile("PLAYER"), 1, 261004)
	var file := FileAccess.open("res://tmp/family_v55_fixture.bin", FileAccess.READ)
	var expected := file.get_64()
	ext.begin_economy_restore()
	var accepted := true
	while file.get_position() < file.get_length():
		var chunk := file.get_buffer(file.get_32())
		var fed: Dictionary = ext.feed_economy_restore_chunk(chunk)
		accepted = accepted and bool(fed.get("ok", false))
		if not bool(fed.get("ok", false)): print(fed)
	var end: Dictionary = ext.end_economy_restore()
	_expect("real v55 save restores with its original hash", accepted and bool(end.get("ok", false))
		and expected == int(ext.get_economy_state_hash()))
	if not bool(end.get("ok", false)): print(end)
	quit(0 if failures == 0 else 1)
