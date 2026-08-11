extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const EffectCatalogScript = preload("res://scripts/effect/effect_catalog.gd")

var _failures := 0


func _init() -> void:
	_run()
	print("=== family colonization runtime: %d failures ===" % _failures)
	quit(0 if _failures == 0 else 1)


func _expect(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures += 1


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("[SKIP] DCWorldExt unavailable")
		return
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("economy catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		return
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var fixture := _make_fixture(catalog, 260810)
	var ext: Object = fixture.ext
	var country_handle := int(fixture.country_handle)
	if ext == null or country_handle == 0:
		return
	var families: Dictionary = ext.get_family_cell_snapshot(0, 0, 64)
	_expect("founder family is available as a source branch",
		bool(families.get("ok", false)) and int(families.get("total", 0)) == 1)
	if int(families.get("total", 0)) != 1:
		return
	var family_handle := int((families.family_handles as PackedInt64Array)[0])
	var source_before := int(ext.get_population_cell_snapshot(0).population)
	var family_before: Dictionary = ext.get_family_snapshot(family_handle)
	fixture.map.visible_arr[1] = 0
	fixture.map.vision_revision += 1
	var hidden_route: Dictionary = ext.get_family_colonization_quotes(
		country_handle, 2, family_handle, 0, 0, 64)
	_expect("a route with any fogged intermediate cell produces no quote",
		bool(hidden_route.get("ok", false)) and int(hidden_route.get("total", -1)) == 0)
	fixture.map.visible_arr[1] = 1
	fixture.map.vision_revision += 1

	var quotes: Dictionary = ext.get_family_colonization_quotes(
		country_handle, 2, family_handle, 0, 0, 64)
	_expect("one reverse Dijkstra returns the owned family branch",
		bool(quotes.get("ok", false)) and int(quotes.get("total", 0)) == 1
		and int((quotes.route_costs as PackedInt32Array)[0]) == 4
		and int(quotes.get("expansions", 9000)) <= 8192)
	if int(quotes.get("total", 0)) != 1:
		print("quotes=", quotes)
		return
	var token := int((quotes.quote_tokens as PackedInt64Array)[0])
	var detail: Dictionary = ext.get_family_colonization_quote_detail(token)
	_expect("quote detail freezes route and cumulative enter costs",
		(detail.route_cells as PackedInt32Array) == PackedInt32Array([0, 1, 2])
		and (detail.cumulative_costs as PackedInt32Array) == PackedInt32Array([0, 2, 4]))

	# A revision-only vision change is accepted when the deterministic route hash
	# remains unchanged. The command extracts real population immediately.
	fixture.map.vision_revision += 1
	var started: Dictionary = ext.start_family_colonization(country_handle,
		family_handle, 0, 2, 1, token, 0, 1)
	_expect("revision-only requote validation accepts an unchanged route",
		bool(started.get("ok", false)) and int(started.get("arrival_day", -1)) == 4)
	if not bool(started.get("ok", false)):
		print("start=", started)
		return
	var expedition_handle := int(started.expedition_handle)
	var in_transit: Dictionary = ext.get_family_expedition_snapshot(
		country_handle, expedition_handle)
	_expect("departure moves population into sparse transit custody",
		int(ext.get_population_cell_snapshot(0).population) == source_before - 1
		and int(in_transit.population) == 1
		and int(ext.get_family_snapshot(family_handle).population) ==
			int(family_before.population))
	var saved := _save_economy(ext)
	var restored_fixture := _make_fixture(catalog.duplicate(true), 260810)
	var restored: Object = restored_fixture.ext
	var restored_result := _restore_economy(restored, saved.get("chunks", []))
	var restored_page: Dictionary = restored.get_family_expeditions(
		int(restored_fixture.country_handle), 0, 64)
	if not bool(restored_result.get("ok", false)) or int(
			restored_page.get("total", 0)) != 1:
		print("restore=", restored_result, " page=", restored_page,
			" saved_schema=", saved.get("schema", 0))
	_expect("PKEC v34 restores in-flight route, payload and due heap exactly",
		int(saved.get("schema", 0)) == 34
		and bool(restored_result.get("ok", false))
		and int(restored_page.get("total", 0)) == 1
		and int(restored.get_economy_state_hash()) == int(ext.get_economy_state_hash()))
	var duplicate: Dictionary = ext.start_family_colonization(country_handle,
		family_handle, 0, 2, 1, token, 0, 2)
	_expect("country and target active index rejects duplicates in O(1)",
		String(duplicate.get("code", "")) == "colonization_duplicate_target")

	var cancelled: Dictionary = ext.cancel_family_colonization(
		country_handle, expedition_handle, 1, 3)
	var returning: Dictionary = ext.get_family_expedition_snapshot(
		country_handle, expedition_handle)
	_expect("cancellation derives return duration from progressed route cost",
		bool(cancelled.get("ok", false)) and int(returning.state) == 3
		and int(returning.due_day) == 2)
	_run_day(ext, 2)
	ext.capture_economy_trade_topology(fixture.neighbors, fixture.terrain,
		fixture.passable, fixture.costs, 1)
	_expect("return restores the original source even without ownership checks",
		int(ext.get_family_expeditions(country_handle, 0, 64).total) == 0
		and int(ext.get_population_cell_snapshot(0).population) == source_before)
	var receipts: Dictionary = ext.get_family_colonization_receipts(
		country_handle, 0, 64)
	var codes := PackedStringArray()
	for receipt in receipts.get("receipts", []):
		codes.append(String(receipt.get("code", "")))
	_expect("event receipts publish start, cancellation and return",
		codes.has("STARTED") and codes.has("CANCELLED_RETURNING")
		and codes.has("RETURNED"))
	var report: Dictionary = ext.get_economy_report()
	_expect("diagnostics expose sparse-heap and stage timing counters",
		report.has("family_expedition_active_count")
		and report.has("colonization_route_query_ms")
		and int(report.family_expedition_active_count) == 0)

	var second_quotes: Dictionary = ext.get_family_colonization_quotes(
		country_handle, 2, family_handle, 0, 0, 64)
	_expect("returned source can be quoted again after the transit release",
		bool(second_quotes.get("ok", false)) and
		int(second_quotes.get("total", 0)) == 1)
	if int(second_quotes.get("total", 0)) != 1:
		return
	var second_token := int((second_quotes.quote_tokens as PackedInt64Array)[0])
	var second_start: Dictionary = ext.start_family_colonization(country_handle,
		family_handle, 0, 2, 1, second_token, 2, 4)
	_expect("second expedition starts for the cross-domain arrival path",
		bool(second_start.get("ok", false)))
	_run_day(ext, 6)
	var premature_economy_dispatch: Dictionary = ext.dispatch_effect_native_economy()
	var country_dispatch: Dictionary = ext.dispatch_effect_native_country()
	var country_commit: Dictionary = ext.run_country_slice({"day_index": 6})
	var country_ack: Dictionary = ext.ack_effect_native_country()
	var economy_dispatch: Dictionary = ext.dispatch_effect_native_economy()
	_run_day(ext, 6)
	var economy_ack: Dictionary = ext.ack_effect_native_economy()
	_expect("arrival claims neutral territory and settles custody through two ACKs",
		int(premature_economy_dispatch.get("submitted_transactions", -1)) == 0
		and int(country_dispatch.get("submitted_transactions", 0)) == 1
		and bool(country_commit.get("ok", false))
		and int(country_ack.get("acknowledged", 0)) == 1
		and int(economy_dispatch.get("submitted_transactions", 0)) == 1
		and int(economy_ack.get("acknowledged", 0)) == 1
		and int(ext.get_country_cell_summary(2).country_handle) == country_handle
		and int(ext.get_family_expeditions(country_handle, 0, 64).total) == 0
		and int(ext.get_population_cell_snapshot(2).population) == 1)


func _make_fixture(catalog: Dictionary, seed: int) -> Dictionary:
	var map := MapData.new(3, 1)
	for q in range(3):
		var cell := HexCell.new(q, 0)
		cell.terrain = TerrainType.TERRAIN.PLAIN
		cell.landform = LandformType.LF.PLAIN
		map.set_cell(cell)
	map._build_indices()
	map.init_soa_from_bake()
	map.visible_arr.fill(1)
	map.explored_arr.fill(1)
	map.vision_revision = 1
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	_expect("map binds to native world", bool(ext.bind_map_data(map)))
	var modifier_catalog: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	modifier_catalog.erase("ok")
	_expect("modifier runtime configures", bool(ext.configure_modifiers(
		modifier_catalog, 3).get("ok", false)))
	var effect_catalog := EffectCatalogScript.new()
	_expect("effect runtime configures for built-in colonization transactions",
		bool(ext.configure_effects(effect_catalog.compile_native_catalog()).get(
			"ok", false)))
	var country_profile := {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": catalog.technology_ids,
	}
	_expect("country runtime configures", bool(ext.configure_country(
		catalog, country_profile, 3, seed).get("ok", false)))
	var technology_indices := PackedInt32Array()
	technology_indices.resize((catalog.technology_ids as PackedStringArray).size())
	for index in range(technology_indices.size()):
		technology_indices[index] = index
	_expect("one-cell country bootstraps", bool(ext.bootstrap_country({
		"country_ids": PackedStringArray(["country.colonization_test"]),
		"country_names": PackedStringArray(["开拓测试国"]),
		"country_cash": PackedInt64Array([0]),
		"territory_offsets": PackedInt32Array([0, 1]),
		"territory_cells": PackedInt32Array([0]),
		"technology_offsets": PackedInt32Array([0, technology_indices.size()]),
		"technology_indices": technology_indices,
		"treasury_offsets": PackedInt32Array([0, 0]),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}, PackedByteArray([0, 0, 0])).get("ok", false)))
	var country_handle := int(ext.get_country_cell_summary(0).country_handle)
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.family_runtime_mode = "ACTIVE"
	profile.family_min_settlement_tier = 0
	profile.family_min_population_per_active = 1
	profile.notable_person_runtime_mode = "ACTIVE"
	profile.starvation_death_rate_q32 = 0
	var birth_rates: PackedInt64Array = catalog.signature_birth_rate_q32
	birth_rates.fill(0)
	catalog.signature_birth_rate_q32 = birth_rates
	_expect("economy runtime configures", bool(ext.configure_economy(
		catalog, profile, 3, seed).get("ok", false)))
	var neighbors := PackedInt32Array()
	neighbors.resize(18)
	neighbors.fill(-1)
	neighbors[0] = 1
	neighbors[9] = 0
	neighbors[6] = 2
	neighbors[15] = 1
	var terrain := PackedByteArray([2, 2, 2])
	var passable := PackedByteArray()
	var costs := PackedInt32Array()
	passable.resize(256)
	costs.resize(256)
	passable[2] = 1
	costs[2] = 2
	_expect("packed six-neighbor topology configures", bool(
		ext.capture_economy_trade_topology(neighbors, terrain, passable,
			costs, 1).get("ok", false)))
	var signatures: PackedStringArray = catalog.signature_keys
	var forager := signatures.find("forager|default")
	var merchant := signatures.find("merchant|default")
	var building := (catalog.building_type_ids as PackedStringArray).find(
		"gathering_ground")
	var stock := PackedInt64Array()
	stock.resize(3 * (catalog.good_ids as PackedStringArray).size())
	stock.fill(1000000)
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0]),
		"signature_ids": PackedInt32Array([forager, merchant]),
		"population": PackedInt64Array([10, 2]),
		"funds": PackedInt64Array([1000000, 1000000]),
		"forced_named_cells": PackedInt32Array([0]),
	}, {
		"stock": stock,
		"building_cells": PackedInt32Array([0]),
		"building_type_ids": PackedInt32Array([building]),
		"building_owner_signature_ids": PackedInt32Array([forager]),
		"building_counts": PackedInt64Array([1]),
		"founder_family_cells": PackedInt32Array([0]),
		"founder_family_building_type_ids": PackedInt32Array([building]),
		"founder_family_owner_signature_ids": PackedInt32Array([forager]),
	})
	_expect("economy and founder family bootstrap", bool(boot.get("ok", false)))
	return {"ext": ext, "map": map, "country_handle": country_handle,
		"neighbors": neighbors, "terrain": terrain,
		"passable": passable, "costs": costs}


func _run_day(ext: Object, day: int) -> Dictionary:
	var report := {}
	for slice in range(512):
		report = ext.run_economy_slice({
			"day_index": day,
			"tick_index": day * 1000 + slice,
		})
		if bool(report.get("done", false)):
			return report
	return report


func _save_economy(ext: Object) -> Dictionary:
	var begin: Dictionary = ext.begin_economy_save(65536)
	if not bool(begin.get("ok", false)):
		return begin
	var chunks: Array[PackedByteArray] = []
	while true:
		var chunk: PackedByteArray = ext.read_economy_save_chunk(65536)
		if chunk.is_empty():
			break
		chunks.append(chunk)
	var ended: Dictionary = ext.end_economy_save()
	return {"ok": bool(ended.get("ok", false)),
		"schema": int(begin.get("schema_version", 0)), "chunks": chunks}


func _restore_economy(ext: Object, chunks: Array) -> Dictionary:
	var begin: Dictionary = ext.begin_economy_restore()
	if not bool(begin.get("ok", false)):
		return begin
	for chunk in chunks:
		var fed: Dictionary = ext.feed_economy_restore_chunk(chunk)
		if not bool(fed.get("ok", false)):
			return fed
	return ext.end_economy_restore()
