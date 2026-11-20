extends "res://tests/family/family_colonization_runtime_test.gd"

## 锁定「无法同时派遣多支开拓队」（2026-11-21 玩家上报）。
##
## 玩家连续派出第二支队伍时派不出去。目标行为：同一国家在任意时刻可以有
## 多支活动队伍，只要它们的目标格不同（同一目标按设计仍是
## `colonization_duplicate_target`，见 family-colonization-runtime.md
## 「活动目标索引以 (country_handle,target_cell) 哈希 O(1) 判重」）。
##
## 本用例只断言玩家可见结果：两支不同目标的队伍都必须被接受、同时出现在
## 在途列表里、且各自保留自己的来源/目标/人数。

func _init() -> void:
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("economy catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		quit(1)
		return
	compiled.erase("ok")
	_two_targets_two_parties(compiled.duplicate(true))
	_same_target_stays_single(compiled.duplicate(true))
	print("=== colonization multi dispatch: %d failures ===" % _failures)
	quit(0 if _failures == 0 else 1)


## 从指定来源给指定目标报一次价并立刻派遣。
func _start_from(ext: Object, country: int, source_cell: int, target_cell: int,
		family_handle: int, population: int, sequence: int) -> Dictionary:
	var quotes: Dictionary = ext.get_family_colonization_quotes(country,
		target_cell, family_handle, 0, 0, 64)
	if not bool(quotes.get("ok", false)) or int(quotes.get("total", 0)) != 1:
		return {"ok": false, "code": "no_quote", "quotes": quotes}
	var token := int((quotes.quote_tokens as PackedInt64Array)[0])
	var start_day: int = _economy_command_day(ext)
	var started: Dictionary = ext.start_family_colonization(country,
		family_handle, source_cell, target_cell, population, token, start_day,
		sequence)
	started["start_day"] = start_day
	started["quote_token"] = token
	return started


func _founder_family(ext: Object) -> int:
	var families: Dictionary = ext.get_family_cell_snapshot(0, 0, 64)
	if int(families.get("total", 0)) != 1:
		return 0
	return int((families.family_handles as PackedInt64Array)[0])


func _two_targets_two_parties(catalog: Dictionary) -> void:
	# 同一座城、同一个家族、连续两支队伍，分别去两个不同的绿地目标。
	# 这正是玩家「连续派出多支开拓队」的操作。
	var fixture := _make_fixture(catalog, 2611211, 1000000, {},
		PackedStringArray(), 1, 1000000000000)
	var ext: Object = fixture.ext
	var country := int(fixture.country_handle)
	if ext == null or country == 0:
		return
	var family := _founder_family(ext)
	_expect("multi dispatch fixture has a founder family", family != 0)
	if family == 0:
		return
	var first: Dictionary = _start_from(ext, country, 0, 1, family, 3, 2611211)
	print("[multi-dispatch/first] ok=", bool(first.get("ok", false)),
		" code=", String(first.get("code", "")),
		" handle=", int(first.get("expedition_handle", -1)))
	if not bool(first.get("ok", false)):
		print("[multi-dispatch/first] ", first)
		_expect("the first party is accepted", false)
		return
	# 出发或筹备都算「派成功」：绿地缺料时按设计进 PREPARING，人留在源地。
	var accepted := ["colonization_started", "colonization_preparing"]
	_expect("the first party is accepted as a real expedition",
		accepted.has(String(first.get("code", "")))
		and int(first.get("expedition_handle", 0)) > 0)
	var second: Dictionary = _start_from(ext, country, 0, 2, family, 3, 2611212)
	print("[multi-dispatch/second] ok=", bool(second.get("ok", false)),
		" code=", String(second.get("code", "")),
		" handle=", int(second.get("expedition_handle", -1)),
		" message=", String(second.get("message", "")),
		" quotes=", second.get("quotes", {}))
	_expect("a second party towards another target is accepted",
		bool(second.get("ok", false)))
	_expect("the second party is a separate expedition, not a re-issued first one",
		accepted.has(String(second.get("code", "")))
		and int(second.get("expedition_handle", 0)) > 0
		and int(second.get("expedition_handle", 0))
			!= int(first.get("expedition_handle", 0)))
	if not bool(second.get("ok", false)):
		return
	var page: Dictionary = ext.get_family_expeditions(country, 0, 64)
	var targets: PackedInt32Array = page.get("target_cells", PackedInt32Array())
	var populations: PackedInt64Array = page.get("populations",
		PackedInt64Array())
	var sources: PackedInt32Array = page.get("source_cells", PackedInt32Array())
	print("[multi-dispatch/page] total=", int(page.get("total", -1)),
		" targets=", targets, " sources=", sources, " populations=", populations)
	_expect("both parties are listed at the same time",
		int(page.get("total", 0)) == 2)
	_expect("both parties keep their own target",
		targets.size() == 2 and int(targets[0]) != int(targets[1])
		and targets.has(1) and targets.has(2))
	_expect("both parties keep their own source",
		sources.size() == 2 and int(sources[0]) == 0 and int(sources[1]) == 0)
	_expect("both parties keep their own population",
		populations.size() == 2 and int(populations[0]) == 3
		and int(populations[1]) == 3)
	var report: Dictionary = ext.get_economy_report()
	_expect("two simultaneous parties keep the economy consistent",
		not bool(report.get("fatal", false))
		and int(report.get("population_error", -1)) == 0
		and int(report.get("money_error", -1)) == 0
		and int(report.get("goods_error", -1)) == 0)
	for handle in [int(first.get("expedition_handle", 0)),
			int(second.get("expedition_handle", 0))]:
		var snap: Dictionary = ext.get_family_expedition_snapshot(country, handle)
		print("[multi-dispatch/snapshot] handle=", handle,
			" state=", int(snap.get("state", -1)),
			" target=", int(snap.get("target_cell", -1)),
			" blocker=", String(snap.get("kit_blocker", "")),
			" rejection=", String(snap.get("kit_procurement_rejection", "")))


func _same_target_stays_single(catalog: Dictionary) -> void:
	# 同一目标仍只允许一支队伍：这一条是既有设计，不是本次缺陷，
	# 但它必须带明确原因码，否则玩家分不清「派不出去」和「已有人去了」。
	var fixture := _make_fixture(catalog, 2611213, 1000000)
	var ext: Object = fixture.ext
	var country := int(fixture.country_handle)
	if ext == null or country == 0:
		return
	var family := _founder_family(ext)
	if family == 0:
		_expect("same-target fixture has a founder family", false)
		return
	var first: Dictionary = _start_from(ext, country, 0, 2, family, 3, 2611213)
	if not bool(first.get("ok", false)):
		print("[multi-dispatch/same-target-first] ", first)
		_expect("the same-target fixture starts one party", false)
		return
	var second: Dictionary = _start_from(ext, country, 0, 2, family, 3, 2611214)
	print("[multi-dispatch/same-target] okay=", bool(second.get("ok", false)),
		" code=", String(second.get("code", "")))
	_expect("a second party to an occupied target is refused by design",
		not bool(second.get("ok", false))
		and String(second.get("code", "")) == "colonization_duplicate_target")
