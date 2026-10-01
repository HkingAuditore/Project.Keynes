extends SceneTree

## Population-milestone family founding: player-owned cells open a 1-of-3
## offer that waits for a choice; AUTO mode and non-player cells pick natively.

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
	print("=== family founding offer runtime test ===")
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("economy catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		return
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	_prepare_catalog(catalog)
	_test_player_offer_waits_and_resolves(catalog)
	_test_auto_mode_founds_without_offer(catalog)
	_test_small_cohort_opens_no_offer(catalog)
	_test_offer_survives_save_restore(catalog)
	print("=== family founding offer runtime test: %s ===" % [
		"PASS" if failures == 0 else "FAIL (%d)" % failures])


func _prepare_catalog(catalog: Dictionary) -> void:
	var building_id := (catalog.building_type_ids as PackedStringArray).find(
		"gathering_ground")
	var target_margins: PackedInt32Array = catalog.building_target_operating_margin_q16
	target_margins[building_id] = 0
	catalog.building_target_operating_margin_q16 = target_margins
	var output_offsets: PackedInt32Array = catalog.building_output_offsets
	var output_quantities: PackedInt64Array = catalog.building_output_quantities
	output_quantities[int(output_offsets[building_id])] = 7000000000
	catalog.building_output_quantities = output_quantities
	var construction_days: PackedInt32Array = catalog.building_construction_days
	construction_days.fill(30)
	catalog.building_construction_days = construction_days


func _profile(mode: String) -> Dictionary:
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.family_runtime_mode = "ACTIVE"
	profile.family_review_days = 1
	profile.family_milestone_populations = PackedInt64Array([100, 200, 500])
	profile.family_min_founder_people = 30
	profile.family_founding_choice_mode = mode
	profile.notable_person_runtime_mode = "OFF"
	profile.starvation_death_rate_q32 = 0
	return profile


func _boot(catalog: Dictionary, mode: String, owner_people: int, seed: int) -> Object:
	var building_id := (catalog.building_type_ids as PackedStringArray).find(
		"gathering_ground")
	var owner_sig := (catalog.signature_keys as PackedStringArray).find(
		"forager|default")
	var merchant_sig := (catalog.signature_keys as PackedStringArray).find(
		"merchant|default")
	var ext := _new_ext(catalog)
	if not _configure_country(ext, catalog, seed):
		return null
	if not bool(ext.configure_economy(catalog, _profile(mode), 1, seed).get("ok", false)):
		return null
	var stock := PackedInt64Array()
	stock.resize((catalog.good_ids as PackedStringArray).size())
	stock.fill(100000000)
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0]),
		"signature_ids": PackedInt32Array([owner_sig, merchant_sig]),
		"population": PackedInt64Array([owner_people, 140]),
		"funds": PackedInt64Array([1000000000000000, 1000000000000000]),
	}, {
		"stock": stock,
		"building_cells": PackedInt32Array([0]),
		"building_type_ids": PackedInt32Array([building_id]),
		"building_owner_signature_ids": PackedInt32Array([owner_sig]),
		# One owner post per forager keeps the whole cohort in the owner
		# signature instead of re-sorting surplus foragers into other jobs.
		"building_counts": PackedInt64Array([owner_people]),
	})
	return ext if bool(boot.get("ok", false)) else null


func _test_player_offer_waits_and_resolves(catalog: Dictionary) -> void:
	# 240 foragers + 140 merchants: the first house takes up to half the city
	# (190), which still leaves 50 foragers for the 200-person milestone.
	var ext := _boot(catalog, "PLAYER", 240, 261001)
	_expect("player fixture boots", ext != null)
	if ext == null:
		return
	var families_before := int(ext.get_family_cell_snapshot(0, 0, 64).get("total", 0))
	_run_day(ext, 0)
	var offers: Dictionary = ext.get_family_founding_offers(0, 16)
	var rows: Array = offers.get("offers", [])
	_expect("player milestone opens exactly one offer",
		bool(offers.get("ok", false)) and int(offers.get("total", 0)) == 1)
	if rows.is_empty():
		return
	var offer: Dictionary = rows[0]
	var candidates: Array = offer.get("candidates", [])
	var surnames := {}
	var stable_ids := {}
	var founders_ok := true
	for card in candidates:
		surnames[String(card.get("surname_id", ""))] = true
		stable_ids[int(card.get("stable_id", 0))] = true
		founders_ok = founders_ok and int(card.get("founders", 0)) >= 30
	_expect("offer carries three distinct candidate houses",
		candidates.size() == 3 and stable_ids.size() == 3 and surnames.size() == 3)
	_expect("every candidate brings at least 30 founders", founders_ok)
	_expect("offer is OPEN, player-owned, at the 100 milestone",
		String(offer.get("status", "")) == "OPEN"
		and bool(offer.get("player_choice", false))
		and int(offer.get("milestone_population", 0)) == 100)
	_expect("no family appears before the player chooses",
		int(ext.get_family_cell_snapshot(0, 0, 64).get("total", 0)) == families_before)
	_run_day(ext, 1)
	var still: Dictionary = ext.get_family_founding_offers(0, 16)
	_expect("pending offer is not duplicated while waiting",
		int(still.get("total", 0)) == 1 and int((still.offers[0] as Dictionary).get(
			"offer_id", 0)) == int(offer.get("offer_id", 0)))
	var stale: Dictionary = ext.submit_family_founding_choice(
		int(offer.get("offer_id", 0)), int(offer.get("generation", 0)) + 1, 1, 1, 1)
	_expect("stale generation is rejected",
		not bool(stale.get("ok", true))
		and String(stale.get("reason", "")) == "family_founding_offer_stale")
	var chosen: Dictionary = candidates[1]
	var submit: Dictionary = ext.submit_family_founding_choice(
		int(offer.get("offer_id", 0)), int(offer.get("generation", 0)), 1, 1, 2)
	_expect("valid choice is queued", bool(submit.get("ok", false)))
	var pending: Dictionary = ext.get_family_founding_offers(0, 16)
	_expect("queued choice reports SELECTED_PENDING",
		String((pending.offers[0] as Dictionary).get("status", "")) == "SELECTED_PENDING")
	var duplicate: Dictionary = ext.submit_family_founding_choice(
		int(offer.get("offer_id", 0)), int(offer.get("generation", 0)), 0, 1, 3)
	_expect("second choice for the same offer is rejected",
		not bool(duplicate.get("ok", true)))
	_run_day(ext, 2)
	var families: Dictionary = ext.get_family_cell_snapshot(0, 0, 64)
	var stable_list: PackedInt64Array = families.get("stable_ids", PackedInt64Array())
	_expect("chosen house is founded with its offered identity",
		stable_list.has(int(chosen.get("stable_id", 0))))
	var others_absent := true
	for index in [0, 2]:
		others_absent = others_absent and not stable_list.has(
			int((candidates[index] as Dictionary).get("stable_id", 0)))
	_expect("the two unchosen houses never appear", others_absent)
	_expect("resolved offer leaves the pending list",
		int(ext.get_family_founding_offers(0, 16).get("total", -1)) == 0)
	# The next milestone is reviewed on the following FAMILY_COMMIT.
	_run_day(ext, 3)
	var after: Dictionary = ext.get_family_founding_offers(0, 16)
	var next_rows: Array = after.get("offers", [])
	_expect("next milestone opens a fresh offer after resolution",
		next_rows.size() == 1 and int((next_rows[0] as Dictionary).get(
			"milestone_population", 0)) == 200
		and int((next_rows[0] as Dictionary).get("offer_id", 0))
			!= int(offer.get("offer_id", 0)))


func _test_auto_mode_founds_without_offer(catalog: Dictionary) -> void:
	var ext := _boot(catalog, "AUTO", 240, 261002)
	_expect("auto fixture boots", ext != null)
	if ext == null:
		return
	var families_before := int(ext.get_family_cell_snapshot(0, 0, 64).get("total", 0))
	_run_day(ext, 0)
	var report: Dictionary = ext.get_economy_report() \
		if ext.has_method("get_economy_report") else {}
	_expect("AUTO mode leaves no pending offer",
		int(ext.get_family_founding_offers(0, 16).get("total", -1)) == 0)
	_expect("AUTO mode founds a family at the first milestone",
		int(ext.get_family_cell_snapshot(0, 0, 64).get("total", 0)) > families_before)
	if not report.is_empty():
		_expect("AUTO resolution is counted",
			int(report.get("family_offers_auto_resolved", 0)) >= 1)


func _test_small_cohort_opens_no_offer(catalog: Dictionary) -> void:
	# 20 owner-signature people cannot supply 30 founders even though the cell
	# (160 people) crosses the 100 milestone.
	var ext := _boot(catalog, "PLAYER", 20, 261003)
	_expect("small fixture boots", ext != null)
	if ext == null:
		return
	_run_day(ext, 0)
	_expect("no offer when no candidate can bring 30 founders",
		int(ext.get_family_founding_offers(0, 16).get("total", -1)) == 0)


func _test_offer_survives_save_restore(catalog: Dictionary) -> void:
	var ext := _boot(catalog, "PLAYER", 240, 261004)
	if ext == null:
		_expect("save fixture boots", false)
		return
	_run_day(ext, 0)
	var before: Dictionary = ext.get_family_founding_offers(0, 16)
	var hash_before := int(ext.get_economy_state_hash())
	var save_begin: Dictionary = ext.begin_economy_save(4096)
	_expect("PKEC v55 save begins", bool(save_begin.get("ok", false))
		and int(save_begin.get("schema_version", 0)) == 55)
	var chunks: Array[PackedByteArray] = []
	for _i in 4096:
		var chunk: PackedByteArray = ext.read_economy_save_chunk(4096)
		if chunk.is_empty():
			break
		chunks.append(chunk)
	_expect("save completes", bool(ext.end_economy_save().get("ok", false)))
	var restored := _new_ext(catalog)
	_configure_country(restored, catalog, 261004)
	restored.configure_economy(catalog, _profile("PLAYER"), 1, 261004)
	restored.begin_economy_restore()
	var chunks_ok := true
	for chunk in chunks:
		chunks_ok = chunks_ok and bool(
			restored.feed_economy_restore_chunk(chunk).get("ok", false))
	var restore_end: Dictionary = restored.end_economy_restore()
	_expect("restore accepts founding section", chunks_ok
		and bool(restore_end.get("ok", false)))
	if not bool(restore_end.get("ok", false)):
		print("restore end diagnostic=", restore_end)
	_expect("state hash round-trips with a pending offer",
		int(restored.get_economy_state_hash()) == hash_before)
	var after: Dictionary = restored.get_family_founding_offers(0, 16)
	_expect("pending offer and its cards survive restore",
		int(after.get("total", 0)) == int(before.get("total", -1))
		and int(after.get("total", 0)) == 1
		and str((after.offers[0] as Dictionary).get("candidates"))
			== str((before.offers[0] as Dictionary).get("candidates")))


func _new_ext(catalog: Dictionary) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(1)
	var modifier_catalog: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	modifier_catalog.erase("ok")
	ext.configure_modifiers(modifier_catalog, 1)
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_weather_precip", &"cell_snow_cover",
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
		"country_ids": PackedStringArray(["country.family_founding_test"]),
		"country_names": PackedStringArray(["立族测试国"]),
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
