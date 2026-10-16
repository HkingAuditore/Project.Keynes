extends "res://tests/family_founding_offer_runtime_test.gd"

## Exercise actual cohort migration, pending branch proposals, conserved whole-
## branch transfer, later arrivals, and both pending/resolved save boundaries.
const SPLIT_SEED := 261017
var _foreign_target := false
var _fixture_cells := 2

func _init() -> void:
	var catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	catalog.erase("ok")
	_prepare_catalog(catalog)
	_test_split_choice(catalog)
	_test_newly_acquired_player_cell(catalog)
	print("=== family split choice runtime: %d failures ===" % failures)
	quit(0 if failures == 0 else 1)

func _split_profile() -> Dictionary:
	var profile := _profile("PLAYER")
	profile.family_milestone_populations = PackedInt64Array([1000000])
	profile.notable_person_runtime_mode = "ACTIVE"
	return profile

func _split_world(catalog: Dictionary) -> Object:
	var ext := _new_ext(catalog)
	_configure_country(ext, catalog, SPLIT_SEED)
	ext.configure_economy(catalog, _split_profile(), 2, SPLIT_SEED)
	ext.start_runtime_worker({"simulation_thread_mode": "OFF", "economy_production_writer": "compact_slice"})
	return ext

func _test_split_choice(catalog: Dictionary) -> void:
	var ext := _split_world(catalog)
	var owner := (catalog.signature_keys as PackedStringArray).find("forager|default")
	var merchant := (catalog.signature_keys as PackedStringArray).find("merchant|default")
	var building := (catalog.building_type_ids as PackedStringArray).find("gathering_ground")
	var stock := PackedInt64Array()
	stock.resize(_fixture_cells * (catalog.good_ids as PackedStringArray).size())
	stock.fill(100000000)
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0]),
		"signature_ids": PackedInt32Array([owner, merchant]),
		"population": PackedInt64Array([600, 100]),
		"funds": PackedInt64Array([1000000000000000, 1000000000000000]),
	}, {
		"founder_family_cells": PackedInt32Array([0]),
		"founder_family_building_type_ids": PackedInt32Array([building]),
		"founder_family_owner_signature_ids": PackedInt32Array([owner]),
		"stock": stock,
		"building_cells": PackedInt32Array([0, 1]),
		"building_type_ids": PackedInt32Array([building, building]),
		"building_owner_signature_ids": PackedInt32Array([owner, owner]),
		"building_counts": PackedInt64Array([300, 300]),
	})
	_expect("split fixture bootstraps", bool(boot.get("ok", false)))
	var initial: Dictionary = ext.get_family_cell_snapshot(0, 0, 64)
	_expect("fixture has one starter family", int(initial.get("total", 0)) == 1)
	if int(initial.get("total", 0)) == 0:
		print("bootstrap diagnostic=", boot)
		return
	var parent := int(initial.family_handles[0])
	var surname := String(initial.surnames[0])
	_move_owner(ext, owner, 450, 0, 1)
	var report := _run_day(ext, 0)
	_expect("migration day conserves ledgers", _conserved(report))
	var offers: Dictionary = ext.get_family_founding_offers(0, 16)
	_expect("player branch opens a split proposal", int(offers.get("total", 0)) == 1)
	if int(offers.get("total", 0)) != 1:
		print("offers=", offers, " branches=", ext.get_family_branches(parent, 0, 64))
		return
	var offer: Dictionary = offers.offers[0]
	var cards: Array = offer.candidates
	_expect("three proposals preserve the surname and reference the parent",
		String(offer.get("kind", "")) == "SPLIT" and cards.size() == 3
		and int(offer.get("source_family_handle", 0)) == parent
		and cards.all(func(card: Dictionary) -> bool: return String(card.get("surname", "")) == surname))
	var before: Dictionary = ext.get_family_cell_snapshot(1, 0, 64)
	_expect("pending proposals create no new family", int(before.total) == 1
		and int(before.family_handles[0]) == parent)
	var restored := _roundtrip(ext, catalog)
	_expect("pending split survives save and restore", int(restored.get_family_founding_offers(0, 16).get("total", 0)) == 1)
	ext = restored
	_run_day(ext, 1)
	_expect("waiting neither auto-splits nor duplicates the proposal",
		int(ext.get_family_founding_offers(0, 16).get("total", 0)) == 1
		and int(ext.get_family_cell_snapshot(1, 0, 64).family_handles[0]) == parent)
	var submit: Dictionary = ext.submit_family_founding_choice(int(offer.offer_id), int(offer.generation), 1, 1, 2)
	_expect("split choice is accepted", bool(submit.get("ok", false)))
	report = _run_day(ext, 2)
	_expect("split selection conserves ledgers", _conserved(report))
	var after: Dictionary = ext.get_family_cell_snapshot(1, 0, 64)
	var chosen: Dictionary = cards[1]
	_expect("whole local branch has one chosen identity and keeps its surname",
		int(after.total) == 1 and int(after.stable_ids[0]) == int(chosen.stable_id)
		and String(after.surnames[0]) == surname and int(after.family_handles[0]) != parent)
	var child := int(after.family_handles[0])
	var origin: Dictionary = ext.get_family_cell_snapshot(0, 0, 64)
	_expect("parent remains in the original city", (origin.family_handles as PackedInt64Array).has(parent))
	_expect("resolved split leaves no pending offer", int(ext.get_family_founding_offers(0, 16).get("total", -1)) == 0)
	var traits: Dictionary = ext.get_family_traits(child)
	var actual_traits := {}
	var chosen_traits := {}
	for i in (traits.get("trait_keys", PackedStringArray()) as PackedStringArray).size():
		actual_traits[String(traits.trait_keys[i])] = int(traits.strength_q16[i])
	for i in (chosen.get("trait_keys", PackedStringArray()) as PackedStringArray).size():
		chosen_traits[String(chosen.trait_keys[i])] = int(chosen.trait_strength_q16[i])
	_expect("chosen traits match the frozen proposal", not actual_traits.is_empty() and actual_traits == chosen_traits)
	ext = _roundtrip(ext, catalog)
	_move_owner(ext, owner, 40, 15, 3)
	report = _run_day(ext, 3)
	_expect("later parent arrivals conserve ledgers", _conserved(report))
	after = ext.get_family_cell_snapshot(1, 0, 64)
	_expect("later parent arrivals keep their identity alongside the independent child",
		int(after.total) == 2 and (after.family_handles as PackedInt64Array).has(parent)
		and (after.family_handles as PackedInt64Array).has(child)
		and int(ext.get_family_founding_offers(0, 16).get("total", -1)) == 0)
	ext = _roundtrip(ext, catalog)
	after = ext.get_family_cell_snapshot(1, 0, 64)
	_expect("parent and child remain separate after save and restore",
		int(after.total) == 2 and (after.family_handles as PackedInt64Array).has(parent)
		and (after.family_handles as PackedInt64Array).has(child))

func _move_owner(ext: Object, signature: int, count: int, day: int, sequence: int) -> void:
	var cohorts: Dictionary = ext.get_population_cell_snapshot(0)
	var signatures: PackedInt32Array = cohorts.signature_ids
	var index := signatures.find(signature)
	_expect("source owner cohort exists", index >= 0)
	if index < 0:
		return
	var submitted: Dictionary = ext.submit_economy_commands({
		"opcodes": PackedInt32Array([7]), "effective_days": PackedInt64Array([day]),
		"sequences": PackedInt64Array([sequence]),
		"target_handles": PackedInt64Array([int(cohorts.handles[index])]),
		"i32_0": PackedInt32Array([1]), "i32_1": PackedInt32Array([0]),
		"i64_0": PackedInt64Array([count]), "i64_1": PackedInt64Array([0]),
	})
	_expect("migration command queues", bool(submitted.get("ok", false)))
	if not bool(submitted.get("ok", false)): print("migration diagnostic=", submitted)

func _roundtrip(ext: Object, catalog: Dictionary) -> Object:
	var before := int(ext.get_economy_state_hash())
	ext.begin_economy_save(4096)
	var chunks: Array[PackedByteArray] = []
	for i in 4096:
		var chunk: PackedByteArray = ext.read_economy_save_chunk(4096)
		if chunk.is_empty(): break
		chunks.append(chunk)
	_expect("split save completes", bool(ext.end_economy_save().get("ok", false)))
	var restored := _split_world(catalog)
	restored.begin_economy_restore()
	var valid := true
	for chunk in chunks:
		valid = valid and bool(restored.feed_economy_restore_chunk(chunk).get("ok", false))
	var end: Dictionary = restored.end_economy_restore()
	_expect("split restore preserves state hash", valid and bool(end.get("ok", false))
		and int(restored.get_economy_state_hash()) == before)
	if not bool(end.get("ok", false)): print("restore diagnostic=", end)
	return restored

func _conserved(report: Dictionary) -> bool:
	return bool(report.get("done", false)) and not bool(report.get("fatal", false)) \
		and int(report.get("population_error", 1)) == 0 and int(report.get("money_error", 1)) == 0 \
		and int(report.get("goods_error", 1)) == 0

func _test_newly_acquired_player_cell(catalog: Dictionary) -> void:
	_fixture_cells = 3
	_foreign_target = true
	var ext := _new_ext(catalog)
	_configure_country(ext, catalog, SPLIT_SEED)
	_foreign_target = false
	var profile := _profile("PLAYER")
	ext.configure_economy(catalog, profile, 3, SPLIT_SEED)
	ext.start_runtime_worker({"simulation_thread_mode": "OFF", "economy_production_writer": "compact_slice"})
	var owner := (catalog.signature_keys as PackedStringArray).find("forager|default")
	var merchant := (catalog.signature_keys as PackedStringArray).find("merchant|default")
	var building := (catalog.building_type_ids as PackedStringArray).find("gathering_ground")
	var stock := PackedInt64Array()
	stock.resize(_fixture_cells * (catalog.good_ids as PackedStringArray).size())
	stock.fill(100000000)
	ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([1, 1]), "signature_ids": PackedInt32Array([owner, merchant]),
		"population": PackedInt64Array([240, 140]),
		"funds": PackedInt64Array([1000000000000000, 1000000000000000]),
	}, {"stock": stock, "building_cells": PackedInt32Array([1]),
		"building_type_ids": PackedInt32Array([building]),
		"building_owner_signature_ids": PackedInt32Array([owner]),
		"building_counts": PackedInt64Array([240])})
	var opening: Dictionary = ext.run_economy_slice({"day_index": 0, "tick_index": 0, "slice_budget_ms": 0.1})
	_expect("territory fixture pauses inside a frozen economy epoch", not bool(opening.get("done", false)))
	var country := int(ext.get_country_cell_summary(0).country_handle)
	var facade := CountryFacade.new()
	facade._world_ext = ext
	facade._configured = true
	var queued := facade.submit([{"opcode": 3, "effective_day": 0, "sequence": 91,
		"target_handle": country, "cell": 1}])
	var claimed: Dictionary = ext.run_country_slice({"day_index": 0})
	_expect("Country transfers the foreign cell after economy begins", bool(queued.get("ok", false))
		and bool(claimed.get("ok", false)) and int(ext.get_country_cell_summary(1).country_handle) == country)
	var report := _run_day(ext, 0)
	_expect("newly acquired player's ordinary family waits for support", _conserved(report)
		and int(ext.get_family_cell_snapshot(1, 0, 64).get("total", -1)) == 0
		and int(ext.get_family_founding_offers(0, 16).get("total", 0)) == 1)
	if not _conserved(report) or int(ext.get_family_founding_offers(0, 16).get("total", 0)) != 1:
		print("claim diagnostic=", {"fatal": report.get("fatal"), "reason": report.get("reason"),
			"population_error": report.get("population_error"), "money_error": report.get("money_error"),
			"goods_error": report.get("goods_error"), "done": report.get("done"),
			"offers": ext.get_family_founding_offers(0, 16), "families": ext.get_family_cell_snapshot(1, 0, 64)})


func _new_ext(catalog: Dictionary) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(_fixture_cells)
	var modifier_catalog: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	modifier_catalog.erase("ok")
	ext.configure_modifiers(modifier_catalog, _fixture_cells)
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_weather_precip", &"cell_snow_cover",
			&"cell_weather_intensity", &"cell_elevation"]:
		var sid: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(sid, 0, PackedFloat32Array([0.5, 0.5]))
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation",
			&"cell_is_water", &"cell_has_river"]:
		var sid: int = ext.register_component(slot_name, 2, 1, false)
		ext.write_u8_range(sid, 0, PackedByteArray([0, 0]))
	for i in range((catalog.building_resource_ids as PackedStringArray).size()):
		var reserve_sid: int = ext.register_component(StringName(
			(catalog.building_resource_reserve_slots as PackedStringArray)[i]), 0, 1, false)
		var extra_sid: int = ext.register_component(StringName(
			(catalog.building_resource_extra_slots as PackedStringArray)[i]), 0, 1, false)
		ext.write_f32_range(reserve_sid, 0, PackedFloat32Array([1000000.0, 1000000.0]))
		ext.write_f32_range(extra_sid, 0, PackedFloat32Array([0.0, 0.0]))
	return ext


func _configure_country(ext: Object, catalog: Dictionary, seed: int) -> bool:
	var technology_indices := PackedInt32Array()
	technology_indices.resize((catalog.technology_ids as PackedStringArray).size())
	for index in range(technology_indices.size()):
		technology_indices[index] = index
	var technology_count := technology_indices.size()
	if _foreign_target:
		technology_indices.append_array(technology_indices.duplicate())
	var configured: Dictionary = ext.configure_country(catalog, {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": catalog.technology_ids,
	}, _fixture_cells, seed)
	if not bool(configured.get("ok", false)):
		return false
	return bool(ext.bootstrap_country({
		"country_ids": PackedStringArray(["country.family_founding_test", "country.foreign"]) if _foreign_target else PackedStringArray(["country.family_founding_test"]),
		"country_names": PackedStringArray(["立族测试国", "外国"]) if _foreign_target else PackedStringArray(["立族测试国"]),
		"country_cash": PackedInt64Array([0, 0]) if _foreign_target else PackedInt64Array([0]),
		"territory_offsets": PackedInt32Array([0, 1, 3]) if _foreign_target else PackedInt32Array([0, 2]),
		"territory_cells": PackedInt32Array([0, 1, 2]) if _foreign_target else PackedInt32Array([0, 1]),
		"technology_offsets": PackedInt32Array([0, technology_count, technology_count * 2]) if _foreign_target else PackedInt32Array([0, technology_count]),
		"technology_indices": technology_indices,
		"treasury_offsets": PackedInt32Array([0, 0, 0]) if _foreign_target else PackedInt32Array([0, 0]),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}, PackedByteArray([0, 0, 0]) if _foreign_target else PackedByteArray([0, 0])).get("ok", false))


