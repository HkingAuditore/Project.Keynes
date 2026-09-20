extends "res://tests/family_colonization_runtime_test.gd"


func _run() -> void:
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		return
	compiled.erase("ok")
	var fixture := _make_fixture(compiled, 260920, 1000000, {}, PackedStringArray([
		"tech.gathering", "tech.early_trade", "tech.deadwood_collection",
		"tech.hunting", "tech.hide_scraping",
	]))
	var ext: Object = fixture.ext
	var country := int(fixture.country_handle)
	var started := _start_single_colonization(ext, country, "starter kit", 920)
	_expect("starter kit departs with tools still locked",
		bool(started.get("ok", false))
		and String(started.get("code", "")) == "colonization_started")
	if String(started.get("code", "")) != "colonization_started":
		print("starter_result=", started)
	_expect("starter departure conserves goods and population",
		int(ext.get_economy_report().get("goods_error", -1)) == 0
		and int(ext.get_economy_report().get("population_error", -1)) == 0)
	ext.free()
