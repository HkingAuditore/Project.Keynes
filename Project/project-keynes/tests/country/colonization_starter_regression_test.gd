extends "res://tests/family/family_colonization_runtime_test.gd"


func _run() -> void:
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		return
	compiled.erase("ok")
	# Kit procurement settles through the Country treasury, so fund the
	# fixture; locked tools must stay out of the kit rather than block it.
	var fixture := _make_fixture(compiled, 260920, 1000000, {}, PackedStringArray([
		"tech.gathering", "tech.early_trade", "tech.deadwood_collection",
		"tech.hunting", "tech.hide_scraping",
	]), 1, 1000000000000)
	var ext: Object = fixture.ext
	var country := int(fixture.country_handle)
	var started := _start_single_colonization(ext, country, "starter kit", 920)
	_expect("starter kit departs with tools still locked",
		bool(started.get("ok", false))
		and String(started.get("code", "")) == "colonization_started")
	if String(started.get("code", "")) != "colonization_started":
		print("starter_result=", started)
	var snap: Dictionary = ext.get_family_expedition_snapshot(country,
		int(started.get("expedition_handle", 0)))
	var cargo: PackedInt32Array = snap.get("cargo_good_ids", PackedInt32Array())
	_expect("locked tools are not packed into the kit",
		not cargo.has((compiled.good_ids as PackedStringArray).find("tools")))
	_expect("starter departure conserves goods and population",
		int(ext.get_economy_report().get("goods_error", -1)) == 0
		and int(ext.get_economy_report().get("population_error", -1)) == 0)
	# DCWorldExt is RefCounted; releasing the local reference is sufficient.
	ext = null
