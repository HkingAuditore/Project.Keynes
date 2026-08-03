extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")

var failures := 0


func _init() -> void:
	_run()
	quit(0 if failures == 0 else 1)


func _expect(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		failures += 1


func _run() -> void:
	print("=== native notable-family runtime test ===")
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("family surname catalog compiles", bool(compiled.get("ok", false))
		and int(compiled.get("family_catalog_hash", 0)) != 0
		and not (compiled.get("family_surname_ids", PackedStringArray()) as PackedStringArray).is_empty()
		and int(compiled.get("person_catalog_hash", 0)) != 0
		and not (compiled.get("person_given_name_ids", PackedStringArray()) as PackedStringArray).is_empty())
	if not bool(compiled.get("ok", false)):
		return
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	_test_formal_capital_v2_packet_fallback(catalog)
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.family_runtime_mode = "ACTIVE"
	profile.family_min_settlement_tier = 0
	profile.family_review_days = 1
	profile.family_min_population_per_active = 1
	profile.family_decline_reviews = 2
	profile.notable_person_runtime_mode = "ACTIVE"
	profile.notable_person_max_per_family = 4
	profile.starvation_death_rate_q32 = 0
	var building_ids: PackedStringArray = catalog.building_type_ids
	var signatures: PackedStringArray = catalog.signature_keys
	var building_id := building_ids.find("gathering_ground")
	var owner_sig := signatures.find("forager|default")
	var merchant_sig := signatures.find("merchant|default")
	var target_margins: PackedInt32Array = catalog.building_target_operating_margin_q16
	target_margins[building_id] = 0
	catalog.building_target_operating_margin_q16 = target_margins
	var output_offsets: PackedInt32Array = catalog.building_output_offsets
	var output_quantities: PackedInt64Array = catalog.building_output_quantities
	output_quantities[int(output_offsets[building_id])] = 7000000000
	catalog.building_output_quantities = output_quantities
	var ext := _new_ext(catalog)
	_expect("country bootstraps", _configure_country(ext, catalog, 260801))
	_expect("economy configures", bool(ext.configure_economy(
		catalog, profile, 1, 260801).get("ok", false)))
	var stock := PackedInt64Array()
	stock.resize((catalog.good_ids as PackedStringArray).size())
	stock.fill(100000000)
	stock[(catalog.good_ids as PackedStringArray).find("gathered_plants")] = 0
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0]),
		"signature_ids": PackedInt32Array([owner_sig, merchant_sig]),
		"population": PackedInt64Array([10, 2]),
		"funds": PackedInt64Array([1000000000000000, 1000000000000000]),
	}, {
		"stock": stock,
		"building_cells": PackedInt32Array([0]),
		"building_type_ids": PackedInt32Array([building_id]),
		"building_owner_signature_ids": PackedInt32Array([owner_sig]),
		"building_counts": PackedInt64Array([1]),
	})
	_expect("family fixture bootstraps", bool(boot.get("ok", false)))
	if not bool(boot.get("ok", false)):
		print("bootstrap failure=", boot)
		return
	var day0 := _run_day(ext, 0)
	_expect("family day conserves all ledgers", bool(day0.get("done", false))
		and not bool(day0.get("fatal", false))
		and int(day0.get("population_error", 1)) == 0
		and int(day0.get("money_error", 1)) == 0
		and int(day0.get("goods_error", 1)) == 0)
	var page: Dictionary = ext.get_family_cell_snapshot(0, 0, 64)
	_expect("one notable family forms from actual owner operators",
		bool(page.get("ok", false)) and int(page.get("total", 0)) == 1)
	if int(page.get("total", 0)) != 1:
		var diagnostic: Dictionary = ext.get_building_cell_snapshot(0)
		var population_diagnostic: Dictionary = ext.get_population_cell_snapshot(0)
		print("family page=", page, " owner=", diagnostic.filled_owner,
			" projected=", diagnostic.projected_owner_income_per_day,
			" margin=", diagnostic.realized_profit_margin_q16,
			" revenue=", diagnostic.last_revenue,
			" retained=", diagnostic.last_retained,
			" tier=", population_diagnostic.prosperity_tier,
			" population=", population_diagnostic.population,
			" funds=", population_diagnostic.funds)
		return
	var family_handle := int((page.family_handles as PackedInt64Array)[0])
	var family: Dictionary = ext.get_family_snapshot(family_handle)
	var profession_rows: PackedInt32Array = family.get(
		"profession_ids", PackedInt32Array())
	var owner_profession := int(
		(catalog.signature_profession_ids as PackedInt32Array)[owner_sig])
	var owner_row := profession_rows.find(owner_profession)
	_expect("family exposes surname, conserved wealth claim and population",
		bool(family.get("ok", false)) and String(family.get("surname", "")) != ""
		and int(family.get("population", 0)) > 0
		and int(family.get("cash_claim", -1)) >= 0)
	_expect("family profession statistics include owner employment",
		owner_row >= 0
		and int((family.profession_people as PackedInt64Array)[owner_row]) > 0
		and int((family.profession_owner_employed as PackedInt64Array)[owner_row]) > 0)
	var industries: Dictionary = ext.get_family_industries(family_handle, 0, 64)
	_expect("family owns one aggregated building and fills its owner post",
		int(industries.get("total", 0)) == 1
		and int((industries.owned_counts as PackedInt64Array)[0]) == 1
		and int((industries.filled_owner as PackedInt64Array)[0]) > 0)
	var buildings: Dictionary = ext.get_building_cell_snapshot(0)
	_expect("building snapshot publishes ownership CSR",
		(buildings.family_ownership_handles as PackedInt64Array).has(family_handle)
		and int((buildings.family_owned_counts as PackedInt64Array)[0]) == 1)
	var people_page: Dictionary = ext.get_family_notable_people(family_handle, 0, 64)
	_expect("family promotes a sparse important person",
		bool(people_page.get("ok", false)) and int(people_page.get("total", 0)) == 1)
	if int(people_page.get("total", 0)) != 1:
		return
	var person_handle := int((people_page.person_handles as PackedInt64Array)[0])
	var day1 := _run_day(ext, 1)
	_expect("important-person attribution day conserves all ledgers",
		bool(day1.get("done", false)) and not bool(day1.get("fatal", false))
		and int(day1.get("population_error", 1)) == 0
		and int(day1.get("money_error", 1)) == 0
		and int(day1.get("goods_error", 1)) == 0)
	_expect("important-person commit reports bounded sparse work",
		int(day1.get("notable_person_count", 0)) > 0
		and int(day1.get("person_jobs_bound", 0)) > 0
		and int(day1.get("person_need_edges_processed", 0)) > 0)
	var person: Dictionary = ext.get_notable_person_snapshot(person_handle)
	_expect("important person has a traceable name, profession and owner building",
		bool(person.get("ok", false)) and String(person.get("surname", "")) != ""
		and String(person.get("given_name", "")) != ""
		and int(person.get("profession_id", -1)) == owner_profession
		and int(person.get("job_kind", 0)) == 1
		and int(person.get("building_handle", 0)) != 0)
	_expect("important-person wealth is a conserved cohort claim",
		int(person.get("cash_claim", -1)) >= 0
		and int(person.get("estimated_net_worth", -1)) >= int(person.get("cash_claim", 0)))
	var person_needs: Dictionary = ext.get_notable_person_needs(person_handle, 0, 64)
	_expect("important person exposes realized need demand and spending attribution",
		bool(person_needs.get("ok", false))
		and int(person_needs.get("total", 0)) > 0
		and (person_needs.get("desired_period_units", PackedInt64Array()) as PackedInt64Array).size()
			== int(person_needs.get("total", 0)))
	var building_people: Dictionary = ext.get_building_notable_people(
		int(person.get("building_handle", 0)), 0, 64)
	_expect("building reverse index returns its important owner",
		bool(building_people.get("ok", false))
		and (building_people.person_handles as PackedInt64Array).has(person_handle))
	var person_count_before := int(ext.get_family_notable_people(
		family_handle, 0, 64).get("total", 0))

	var hash_before := int(ext.get_economy_state_hash())
	var save_begin: Dictionary = ext.begin_economy_save(65536)
	_expect("PKEC v29 save begins", bool(save_begin.get("ok", false))
		and int(save_begin.get("schema_version", 0)) == 29)
	var chunks: Array[PackedByteArray] = []
	for _i in 512:
		var chunk: PackedByteArray = ext.read_economy_save_chunk(65536)
		if chunk.is_empty():
			break
		chunks.append(chunk)
	_expect("PKEC v29 save completes", not chunks.is_empty()
		and bool(ext.end_economy_save().get("ok", false)))
	var restored := _new_ext(catalog)
	_expect("restore country bootstraps", _configure_country(
		restored, catalog, 260801))
	_expect("restore economy configures", bool(restored.configure_economy(
		catalog, profile, 1, 260801).get("ok", false)))
	_expect("restore begins", bool(restored.begin_economy_restore().get("ok", false)))
	for chunk in chunks:
		_expect("restore chunk accepted", bool(
			restored.feed_economy_restore_chunk(chunk).get("ok", false)))
	var restore_end: Dictionary = restored.end_economy_restore()
	_expect("PKEC v29 restores family and important-person authority",
		bool(restore_end.get("ok", false))
		and int(restore_end.get("restored_families", 0)) == 1
		and int(restore_end.get("restored_persons", 0)) == person_count_before
		and int(restore_end.get("restored_person_needs", 0)) > 0)
	if not bool(restore_end.get("ok", false)) \
			or int(restore_end.get("restored_persons", 0)) != person_count_before \
			or int(restore_end.get("restored_person_needs", 0)) <= 0:
		print("restore end diagnostic=", restore_end)
	_expect("family save hash round-trips",
		int(restored.get_economy_state_hash()) == hash_before)
	var restored_family: Dictionary = restored.get_family_snapshot(family_handle)
	_expect("generation-safe family handle survives restore",
		bool(restored_family.get("ok", false))
		and int(restored_family.get("owned_buildings", 0)) == 1)
	var restored_person: Dictionary = restored.get_notable_person_snapshot(person_handle)
	_expect("generation-safe important-person handle and job survive restore",
		bool(restored_person.get("ok", false))
		and int(restored_person.get("building_handle", 0))
			== int(person.get("building_handle", 0)))
	print("=== native notable-family runtime %s ===" % [
		"PASS" if failures == 0 else "FAIL"])


func _test_formal_capital_v2_packet_fallback(catalog: Dictionary) -> void:
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.family_runtime_mode = "ACTIVE"
	profile.notable_person_runtime_mode = "ACTIVE"
	profile.starvation_death_rate_q32 = 0
	var building_id := (catalog.building_type_ids as PackedStringArray).find(
		"gathering_ground")
	var owner_sig := (catalog.signature_keys as PackedStringArray).find(
		"forager|default")
	var merchant_sig := (catalog.signature_keys as PackedStringArray).find(
		"merchant|default")
	var ext := _new_ext(catalog)
	_expect("formal fallback country bootstraps", _configure_country(
		ext, catalog, 260802))
	_expect("formal fallback economy configures", bool(ext.configure_economy(
		catalog, profile, 1, 260802).get("ok", false)))
	var stock := PackedInt64Array()
	stock.resize((catalog.good_ids as PackedStringArray).size())
	stock.fill(100000000)
	# Intentionally omit all founder_family_* columns. This reproduces the v2
	# packet that a long-lived editor may still emit while starting a formal game.
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0]),
		"signature_ids": PackedInt32Array([owner_sig, merchant_sig]),
		"population": PackedInt64Array([3, 2]),
		"funds": PackedInt64Array([100000000, 100000000]),
		"forced_named_cells": PackedInt32Array([0]),
	}, {
		"stock": stock,
		"building_cells": PackedInt32Array([0]),
		"building_type_ids": PackedInt32Array([building_id]),
		"building_owner_signature_ids": PackedInt32Array([owner_sig]),
		"building_counts": PackedInt64Array([1]),
	})
	_expect("native formal fallback derives one founder family and person",
		bool(boot.get("ok", false))
		and int(boot.get("founder_family_count", 0)) == 1
		and int(boot.get("founder_person_count", 0)) == 1)
	var families: Dictionary = ext.get_family_cell_snapshot(0, 0, 64)
	_expect("formal fallback is immediately visible to the inspector",
		bool(families.get("ok", false))
		and int(families.get("total", 0)) == 1
		and not (families.get(
			"notable_person_counts", PackedInt32Array()) as PackedInt32Array).is_empty()
		and int((families.notable_person_counts as PackedInt32Array)[0]) == 1)


func _new_ext(catalog: Dictionary) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(1)
	var modifier_catalog: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	modifier_catalog.erase("ok")
	ext.configure_modifiers(modifier_catalog, 1)
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_snow_cover",
			&"cell_weather_intensity", &"cell_elevation"]:
		var sid: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(sid, 0, PackedFloat32Array([0.5]))
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation",
			&"cell_is_water", &"cell_has_river"]:
		var sid: int = ext.register_component(slot_name, 2, 1, false)
		ext.write_u8_range(sid, 0, PackedByteArray([0]))
	for i in range((catalog.building_resource_ids as PackedStringArray).size()):
		var reserve_sid: int = ext.register_component(StringName(
			(catalog.building_resource_reserve_slots as PackedStringArray)[i]), 0, 1, false)
		var extra_sid: int = ext.register_component(StringName(
			(catalog.building_resource_extra_slots as PackedStringArray)[i]), 0, 1, false)
		ext.write_f32_range(reserve_sid, 0, PackedFloat32Array([1000000.0]))
		ext.write_f32_range(extra_sid, 0, PackedFloat32Array([0.0]))
	return ext


func _configure_country(ext: Object, catalog: Dictionary, seed: int) -> bool:
	var technology_indices := PackedInt32Array()
	technology_indices.resize((catalog.technology_ids as PackedStringArray).size())
	for index in range(technology_indices.size()):
		technology_indices[index] = index
	var configured: Dictionary = ext.configure_country(catalog, {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": catalog.technology_ids,
	}, 1, seed)
	if not bool(configured.get("ok", false)):
		return false
	return bool(ext.bootstrap_country({
		"country_ids": PackedStringArray(["country.family_test"]),
		"country_names": PackedStringArray(["家族测试国"]),
		"country_cash": PackedInt64Array([0]),
		"territory_offsets": PackedInt32Array([0, 1]),
		"territory_cells": PackedInt32Array([0]),
		"technology_offsets": PackedInt32Array([0, technology_indices.size()]),
		"technology_indices": technology_indices,
		"treasury_offsets": PackedInt32Array([0, 0]),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}, PackedByteArray([0])).get("ok", false))


func _run_day(ext: Object, day: int) -> Dictionary:
	var report := {}
	var simulation_day := day * 5
	for slice in 512:
		report = ext.run_economy_slice({
			"day_index": simulation_day,
			"tick_index": simulation_day * 1000 + slice,
		})
		if bool(report.get("done", false)):
			return report
	return report
