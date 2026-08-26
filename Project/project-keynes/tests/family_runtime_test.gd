extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const FamilyTraitCatalogScript = preload("res://scripts/family/family_trait_catalog.gd")

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
	var default_profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	_expect("ordinary family cell threshold defaults to 150",
		int(default_profile.get("family_min_population_per_active", 0)) == 150)
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("family surname catalog compiles", bool(compiled.get("ok", false))
		and int(compiled.get("family_catalog_hash", 0)) != 0
		and not (compiled.get("family_surname_ids", PackedStringArray()) as PackedStringArray).is_empty()
		and int(compiled.get("person_catalog_hash", 0)) != 0
		and not (compiled.get("person_given_name_ids", PackedStringArray()) as PackedStringArray).is_empty())
	if not bool(compiled.get("ok", false)):
		return
	var behavior_kinds: PackedInt32Array = compiled.get(
		"family_trait_behavior_selector_kinds", PackedInt32Array())
	var behavior_axes: PackedInt32Array = compiled.get(
		"family_trait_behavior_axes", PackedInt32Array())
	var behavior_ids: PackedInt32Array = compiled.get(
		"family_trait_behavior_selector_ids", PackedInt32Array())
	var exact_selector_compile := not behavior_kinds.is_empty()
	for selector_kind in behavior_kinds:
		exact_selector_compile = exact_selector_compile and int(selector_kind) == 0
	var hunting_building := (compiled.building_type_ids as PackedStringArray).find(
		"stone_age_hunting_camp")
	var hunter_profession := (compiled.profession_ids as PackedStringArray).find("hunter")
	var hunting_building_resolved := false
	var hunting_profession_resolved := false
	for selector_index in range(behavior_ids.size()):
		hunting_building_resolved = hunting_building_resolved or (
			int(behavior_axes[selector_index]) == 0
			and int(behavior_ids[selector_index]) == hunting_building)
		hunting_profession_resolved = hunting_profession_resolved or (
			int(behavior_axes[selector_index]) == 1
			and int(behavior_ids[selector_index]) == hunter_profession)
	_expect("family selectors compile tags and categories to exact dense CSR edges",
		exact_selector_compile and hunting_building_resolved
		and hunting_profession_resolved)
	var score_terms: PackedInt32Array = compiled.get(
		"family_trait_behavior_score_terms", PackedInt32Array())
	var condition_offsets: PackedInt32Array = compiled.get(
		"family_trait_behavior_condition_offsets", PackedInt32Array())
	var tech_offsets: PackedInt32Array = compiled.get(
		"family_trait_technology_prerequisite_offsets", PackedInt32Array())
	var trait_ids: PackedStringArray = compiled.get(
		"family_trait_ids", PackedStringArray())
	_expect("family behavior score_term, condition, and technology columns compile",
		score_terms.size() == behavior_axes.size()
		and condition_offsets.size() == behavior_axes.size() + 1
		and tech_offsets.size() == trait_ids.size() + 1
		and (score_terms.is_empty() or int(score_terms[0]) >= 0))
	_assert_family_effect_display_copy(compiled)
	var bad_trait_catalog: Resource = FamilyTraitCatalogScript.load_default().duplicate(true)
	var bad_traits: Array = bad_trait_catalog.get("traits")
	var bad_trait: Resource = bad_traits[0].duplicate(true)
	var bad_behaviors: Array = bad_trait.get("behaviors")
	var bad_behavior: Resource = bad_behaviors[0].duplicate(true)
	bad_behavior.set("selector_id", &"family.selector.does_not_exist")
	bad_behaviors[0] = bad_behavior
	bad_trait.set("behaviors", bad_behaviors)
	bad_traits[0] = bad_trait
	bad_trait_catalog.set("traits", bad_traits)
	var bad_selector_result: Dictionary = bad_trait_catalog.call(
		"compile_native_columns", compiled)
	_expect("unknown family selector is rejected at the cold catalog boundary",
		not bool(bad_selector_result.get("ok", true))
		and String(bad_selector_result.get("reason", ""))
			== "family_trait_behavior_selector_unknown")
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	_test_formal_capital_v2_packet_fallback(catalog)
	_test_opening_capital_keeps_anonymous_majority(catalog)
	_test_ordinary_family_minimum(catalog)
	# Keep one catalog trait outside the deterministic core roll so mutation
	# ordering and core-removal protection can be exercised in this fixture.
	catalog.family_core_trait_min = 2
	catalog.family_core_trait_max = 2
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
	var reward_building_id := building_ids.find("method_gathering_ground_r1")
	var owner_sig := signatures.find("forager|default")
	var merchant_sig := signatures.find("merchant|default")
	var target_margins: PackedInt32Array = catalog.building_target_operating_margin_q16
	target_margins[building_id] = 0
	catalog.building_target_operating_margin_q16 = target_margins
	var output_offsets: PackedInt32Array = catalog.building_output_offsets
	var output_quantities: PackedInt64Array = catalog.building_output_quantities
	output_quantities[int(output_offsets[building_id])] = 7000000000
	catalog.building_output_quantities = output_quantities
	var construction_days: PackedInt32Array = catalog.building_construction_days
	# Keep legal family investment from completing extra 0-day buildings, and
	# make paid recipes unaffordable so they cannot start.
	construction_days.fill(30)
	construction_days[reward_building_id] = 5
	catalog.building_construction_days = construction_days
	var construction_quantities: PackedInt64Array = catalog.building_construction_quantities
	var construction_offsets: PackedInt32Array = catalog.building_construction_offsets
	for type_id in range(building_ids.size()):
		if type_id == reward_building_id:
			continue
		var qty_begin := int(construction_offsets[type_id])
		var qty_end := int(construction_offsets[type_id + 1])
		for item in range(qty_begin, qty_end):
			construction_quantities[item] = 1000000000000
	catalog.building_construction_quantities = construction_quantities
	var birth_rates: PackedInt64Array = catalog.signature_birth_rate_q32
	birth_rates.fill(0)
	catalog.signature_birth_rate_q32 = birth_rates
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
		"population": PackedInt64Array([20, 30]),
		"funds": PackedInt64Array([1000000000000000, 1000000000000000]),
	}, {
		"stock": stock,
		"building_cells": PackedInt32Array([0]),
		"building_type_ids": PackedInt32Array([building_id]),
		"building_owner_signature_ids": PackedInt32Array([owner_sig]),
		"building_counts": PackedInt64Array([10]),
	})
	_expect("family fixture bootstraps", bool(boot.get("ok", false)))
	if not bool(boot.get("ok", false)):
		print("bootstrap failure=", boot)
		return
	var day0 := _run_day(ext, 0)
	if not bool(day0.get("done", false)) or bool(day0.get("fatal", false)) \
			or int(day0.get("population_error", 1)) != 0 \
			or int(day0.get("money_error", 1)) != 0 \
			or int(day0.get("goods_error", 1)) != 0:
		print("family day0 diagnostic=", day0)
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
	var cell_population := int(ext.get_population_cell_snapshot(0).population)
	_expect("family exposes surname, conserved wealth claim and population",
		bool(family.get("ok", false)) and String(family.get("surname", "")) != ""
		and int(family.get("population", 0)) >= 20
		and int(family.get("population", 0)) <= cell_population / 2
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

	var initial_traits: Dictionary = ext.get_family_traits(family_handle)
	var initial_trait_keys: PackedStringArray = initial_traits.get(
		"trait_keys", PackedStringArray())
	var initial_core: PackedByteArray = initial_traits.get("core", PackedByteArray())
	_expect("family deterministically rolls exactly two immutable core traits",
		bool(initial_traits.get("ok", false)) and initial_trait_keys.size() == 2
		and initial_core.size() == 2 and int(initial_core[0]) == 1
		and int(initial_core[1]) == 1)
	var all_trait_keys: PackedStringArray = catalog.family_trait_ids
	var additional_trait := ""
	var consumption_only_trait := ""
	var exclusion_offsets: PackedInt32Array = catalog.family_trait_exclusion_offsets
	var exclusion_ids: PackedInt32Array = catalog.family_trait_exclusions
	var behavior_offsets: PackedInt32Array = catalog.family_trait_behavior_offsets
	var rolled_ids := {}
	for trait_key in initial_trait_keys:
		var rolled_id := all_trait_keys.find(String(trait_key))
		if rolled_id >= 0:
			rolled_ids[rolled_id] = true
	for trait_index in range(all_trait_keys.size()):
		var candidate := String(all_trait_keys[trait_index])
		if initial_trait_keys.has(candidate):
			continue
		var conflicts := false
		var begin := int(exclusion_offsets[trait_index])
		var end := int(exclusion_offsets[trait_index + 1])
		for edge in range(begin, end):
			if rolled_ids.has(int(exclusion_ids[edge])):
				conflicts = true
				break
		if conflicts:
			continue
		for rolled_id in rolled_ids.keys():
			var rolled_begin := int(exclusion_offsets[int(rolled_id)])
			var rolled_end := int(exclusion_offsets[int(rolled_id) + 1])
			for edge in range(rolled_begin, rolled_end):
				if int(exclusion_ids[edge]) == trait_index:
					conflicts = true
					break
			if conflicts:
				break
		if conflicts:
			continue
		if additional_trait.is_empty():
			additional_trait = candidate
		var invest_or_career := false
		var behavior_begin := int(behavior_offsets[trait_index])
		var behavior_end := int(behavior_offsets[trait_index + 1])
		for behavior_index in range(behavior_begin, behavior_end):
			var axis := int(behavior_axes[behavior_index])
			if axis == 0 or axis == 1:
				invest_or_career = true
				break
		if not invest_or_career:
			consumption_only_trait = candidate
			break
	if not consumption_only_trait.is_empty():
		additional_trait = consumption_only_trait
	_expect("catalog leaves an additional trait available", not additional_trait.is_empty())
	var additional_id := all_trait_keys.find(additional_trait)
	var strength_min: PackedInt32Array = catalog.family_trait_strength_min_q16
	var strength_max: PackedInt32Array = catalog.family_trait_strength_max_q16
	var target_strength := int(strength_max[additional_id]) if additional_id >= 0 else 65536
	var trait_commands: Dictionary = ext.submit_family_trait_commands({
		"protocol_version": 1,
		# Submitted in reverse semantic order; priority/sequence must grant before set.
		"operations": PackedInt32Array([3, 1, 2]),
		"family_handles": PackedInt64Array([family_handle, family_handle, family_handle]),
		"trait_keys": PackedStringArray([additional_trait, additional_trait,
			String(initial_trait_keys[0])]),
		"strength_q16": PackedInt32Array([target_strength,
			int(strength_min[additional_id]) if additional_id >= 0 else 65536, 0]),
		"effective_days": PackedInt64Array([10, 10, 10]),
		"priorities": PackedInt32Array([200, 100, 50]),
		"sequences": PackedInt64Array([2, 1, 0]),
	})
	_expect("ordered family trait mutation batch is accepted",
		bool(trait_commands.get("ok", false)))

	var branches: Dictionary = ext.get_family_branches(family_handle, 0, 64)
	var branch_handles: PackedInt64Array = branches.get(
		"branch_handles", PackedInt64Array())
	_expect("family exposes a generation-safe local influence branch",
		bool(branches.get("ok", false)) and not branch_handles.is_empty()
		and int(branch_handles[0]) != 0)
	if branch_handles.is_empty():
		return
	var branch_handle := int(branch_handles[0])
	var population_before_reward := int(ext.get_population_cell_snapshot(0).population)
	var family_population_before_reward := int(
		ext.get_family_snapshot(family_handle).population)
	var building_before_reward: Dictionary = ext.get_building_cell_snapshot(0)
	var counts_before: PackedInt64Array = building_before_reward.get(
		"building_counts_by_type", PackedInt64Array())
	var reward_submit: Dictionary = ext.submit_economy_commands({
		"opcodes": PackedInt32Array([14, 15]),
		"effective_days": PackedInt64Array([10, 10]),
		"sequences": PackedInt64Array([100, 101]),
		"target_handles": PackedInt64Array([branch_handle, branch_handle]),
		"i32_0": PackedInt32Array([0, 0]),
		"i32_1": PackedInt32Array([reward_building_id, -1]),
		"i64_0": PackedInt64Array([1, 3]),
		"i64_1": PackedInt64Array([9001, 9002]),
	})
	_expect("family building and population rewards are accepted",
		bool(reward_submit.get("ok", false)))
	ext.set_economy_trace_filter({"cells": PackedInt32Array([0])})
	var reward_day := _run_day(ext, 2)
	_expect("family reward commit conserves population money and goods",
		bool(reward_day.get("done", false)) and not bool(reward_day.get("fatal", false))
		and int(reward_day.get("population_error", 1)) == 0
		and int(reward_day.get("money_error", 1)) == 0
		and int(reward_day.get("goods_error", 1)) == 0)
	_expect("family work counters remain bounded by sparse active edges",
		int(reward_day.get("family_count", 0)) == 1
		and int(reward_day.get("family_branch_count", 0)) == 1
		and int(reward_day.get("family_trait_roll_count", 0)) == 3
		and int(reward_day.get("family_membership_edges_processed", 0)) <= 4
		and int(reward_day.get("family_ownership_edges_processed", 0)) <= 4)
	_expect("family population reward adds exact local membership",
		int(ext.get_population_cell_snapshot(0).population) == population_before_reward + 3
		and int(ext.get_family_snapshot(family_handle).population)
			== family_population_before_reward + 3)
	var mutated_traits: Dictionary = ext.get_family_traits(family_handle)
	var mutated_keys: PackedStringArray = mutated_traits.get(
		"trait_keys", PackedStringArray())
	var mutated_strengths: PackedInt32Array = mutated_traits.get(
		"strength_q16", PackedInt32Array())
	var additional_row := mutated_keys.find(additional_trait)
	_expect("core removal is rejected and ordered grant/set reaches target strength",
		mutated_keys.has(initial_trait_keys[0]) and additional_row >= 0
		and int(mutated_strengths[additional_row]) == target_strength)
	var pending_reward: Dictionary = ext.get_building_cell_snapshot(0)
	var pending_types: PackedInt32Array = pending_reward.get(
		"construction_type_ids", PackedInt32Array())
	if not pending_types.has(reward_building_id) \
			or int(reward_day.get("rejected_commands", -1)) != 0:
		print("reward pending diagnostic=", pending_types,
			" consumed=", reward_day.get("construction_goods_consumed", -1),
			" rejected=", reward_day.get("rejected_commands", -1),
			" reason=", reward_day.get("last_building_rejection_reason", ""))
	_expect("free building waits its normal construction duration without materials",
		pending_types.has(reward_building_id)
		and int(reward_day.get("rejected_commands", -1)) == 0
		and String(reward_day.get("last_building_rejection_reason", "")) == "")
	var economy_events: Dictionary = ext.poll_economy_events({
		"consumer_id": &"family_reward_test", "max_events": 256})
	var event_schema: Dictionary = ext.get_economy_event_schema()
	var event_kinds: Dictionary = event_schema.get("kinds", {})
	_expect("population reward writes an explicit population-source ledger event",
		(economy_events.get("kind", PackedInt32Array()) as PackedInt32Array).has(
			int(event_kinds.get("POPULATION_SOURCE", -1))))

	var completion_day := _run_day(ext, 3)
	var completed_reward: Dictionary = ext.get_building_cell_snapshot(0)
	var counts_after: PackedInt64Array = completed_reward.get(
		"building_counts_by_type", PackedInt64Array())
	var industries_after: Dictionary = ext.get_family_industries(
		family_handle, 0, 64)
	var owned_after: PackedInt64Array = industries_after.get(
		"owned_counts", PackedInt64Array())
	var total_owned := 0
	for owned_count in owned_after:
		total_owned += int(owned_count)
	if int(counts_after[reward_building_id]) != int(
			counts_before[reward_building_id]) + 1 \
			or total_owned != 2:
		print("reward completion diagnostic before=", counts_before[reward_building_id],
			" after=", counts_after[reward_building_id], " total_owned=", total_owned,
			" industries=", industries_after)
	_expect("free building completes into the sponsoring family branch",
		bool(completion_day.get("done", false))
		and int(completion_day.get("population_error", 1)) == 0
		and int(completion_day.get("money_error", 1)) == 0
		and int(completion_day.get("goods_error", 1)) == 0
		and int(counts_after[reward_building_id])
			== int(counts_before[reward_building_id]) + 1
		and total_owned == 2)
	var gameplay_events: Dictionary = ext.poll_gameplay_events({
		"consumer_id": &"family_reward_test", "max_events": 256})
	_expect("reward building completion is excluded from recursive gameplay facts",
		not (gameplay_events.get("type", PackedInt32Array()) as PackedInt32Array).has(6))

	person_count_before = int(ext.get_family_notable_people(
		family_handle, 0, 64).get("total", 0))
	var person_before_save: Dictionary = ext.get_notable_person_snapshot(person_handle)
	var hash_before := int(ext.get_economy_state_hash())
	var save_begin: Dictionary = ext.begin_economy_save(65536)
	_expect("PKEC v42 save begins", bool(save_begin.get("ok", false))
		and int(save_begin.get("schema_version", 0)) == 45)
	var chunks: Array[PackedByteArray] = []
	for _i in 512:
		var chunk: PackedByteArray = ext.read_economy_save_chunk(65536)
		if chunk.is_empty():
			break
		chunks.append(chunk)
	_expect("PKEC v42 save completes", not chunks.is_empty()
		and bool(ext.end_economy_save().get("ok", false)))
	var legacy_chunk := chunks[0].duplicate()
	legacy_chunk[4] = 31
	legacy_chunk[5] = 0
	var legacy := _new_ext(catalog)
	_expect("legacy restore country bootstraps", _configure_country(
		legacy, catalog, 260801))
	_expect("legacy restore economy configures", bool(legacy.configure_economy(
		catalog, profile, 1, 260801).get("ok", false)))
	legacy.begin_economy_restore()
	var legacy_result: Dictionary = legacy.feed_economy_restore_chunk(legacy_chunk)
	_expect("PKEC v31 and earlier return an explicit incompatibility error",
		not bool(legacy_result.get("ok", true))
		and String(legacy_result.get("reason", ""))
			== "economy_save_v31_or_earlier_unsupported")
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
	_expect("PKEC v42 restores family and important-person authority",
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
		and int(restored_family.get("owned_buildings", 0)) == 2)
	var restored_person: Dictionary = restored.get_notable_person_snapshot(person_handle)
	_expect("generation-safe important-person handle and job survive restore",
		bool(restored_person.get("ok", false))
		and int(person_before_save.get("building_handle", 0)) != 0
		and int(restored_person.get("building_handle", 0))
			== int(person_before_save.get("building_handle", 0)))
	print("=== native notable-family runtime %s ===" % [
		"PASS" if failures == 0 else "FAIL"])


func _test_opening_capital_keeps_anonymous_majority(catalog: Dictionary) -> void:
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.family_runtime_mode = "ACTIVE"
	profile.family_min_settlement_tier = 0
	profile.family_review_days = 1
	profile.family_min_population_per_active = 1
	profile.notable_person_runtime_mode = "ACTIVE"
	profile.starvation_death_rate_q32 = 0
	var birth_rates: PackedInt64Array = catalog.signature_birth_rate_q32
	birth_rates.fill(0)
	catalog.signature_birth_rate_q32 = birth_rates
	var building_id := (catalog.building_type_ids as PackedStringArray).find(
		"gathering_ground")
	var owner_sig := (catalog.signature_keys as PackedStringArray).find(
		"forager|default")
	var unemployed_sig := (catalog.signature_keys as PackedStringArray).find(
		"unemployed|default")
	var ext := _new_ext(catalog)
	_expect("opening-majority country bootstraps", _configure_country(
		ext, catalog, 260803))
	_expect("opening-majority economy configures", bool(ext.configure_economy(
		catalog, profile, 1, 260803).get("ok", false)))
	var stock := PackedInt64Array()
	stock.resize((catalog.good_ids as PackedStringArray).size())
	stock.fill(100000000)
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0]),
		"signature_ids": PackedInt32Array([owner_sig, unemployed_sig]),
		"population": PackedInt64Array([2, 18]),
		"funds": PackedInt64Array([1000000000000000, 1000000000000000]),
		"forced_named_cells": PackedInt32Array([0]),
		"founder_family_cells": PackedInt32Array([0]),
		"founder_family_building_type_ids": PackedInt32Array([building_id]),
		"founder_family_owner_signature_ids": PackedInt32Array([owner_sig]),
	}, {
		"stock": stock,
		"building_cells": PackedInt32Array([0]),
		"building_type_ids": PackedInt32Array([building_id]),
		"building_owner_signature_ids": PackedInt32Array([owner_sig]),
		"building_counts": PackedInt64Array([1]),
	})
	_expect("opening 20-person capital creates one founder family of two operators",
		bool(boot.get("ok", false))
		and int(boot.get("founder_family_count", 0)) == 1)
	if not bool(boot.get("ok", false)):
		print("opening-majority bootstrap failure=", boot)
		return
	var day0 := _run_day(ext, 0)
	if not bool(day0.get("done", false)) or bool(day0.get("fatal", false)) \
			or int(day0.get("population_error", 1)) != 0:
		print("opening-majority day0 diagnostic=", day0)
	_expect("opening-majority day conserves population",
		bool(day0.get("done", false)) and int(day0.get("population_error", 1)) == 0)
	var page: Dictionary = ext.get_family_cell_snapshot(0, 0, 64)
	_expect("opening capital still has exactly one family",
		bool(page.get("ok", false)) and int(page.get("total", 0)) == 1)
	if int(page.get("total", 0)) != 1:
		return
	var family_handle := int((page.family_handles as PackedInt64Array)[0])
	var family_pop := int(ext.get_family_snapshot(family_handle).population)
	var cell_pop := int(ext.get_population_cell_snapshot(0).population)
	_expect("opening family stays the two gathering operators, not the whole town",
		cell_pop == 20 and family_pop == 2)


func _test_ordinary_family_minimum(catalog: Dictionary) -> void:
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.family_runtime_mode = "ACTIVE"
	profile.family_min_settlement_tier = 0
	profile.family_review_days = 1
	profile.family_min_population_per_active = 1
	profile.notable_person_runtime_mode = "OFF"
	profile.starvation_death_rate_q32 = 0
	var building_id := (catalog.building_type_ids as PackedStringArray).find(
		"gathering_ground")
	var owner_sig := (catalog.signature_keys as PackedStringArray).find(
		"forager|default")
	var merchant_sig := (catalog.signature_keys as PackedStringArray).find(
		"merchant|default")
	var target_margins: PackedInt32Array = catalog.building_target_operating_margin_q16
	target_margins[building_id] = 0
	catalog.building_target_operating_margin_q16 = target_margins
	var output_offsets: PackedInt32Array = catalog.building_output_offsets
	var output_quantities: PackedInt64Array = catalog.building_output_quantities
	output_quantities[int(output_offsets[building_id])] = 7000000000
	catalog.building_output_quantities = output_quantities
	var ext := _new_ext(catalog)
	_expect("small-owner fixture country bootstraps",
		_configure_country(ext, catalog, 260804))
	_expect("small-owner fixture economy configures",
		bool(ext.configure_economy(catalog, profile, 1, 260804).get("ok", false)))
	var stock := PackedInt64Array()
	stock.resize((catalog.good_ids as PackedStringArray).size())
	stock.fill(100000000)
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0]),
		"signature_ids": PackedInt32Array([owner_sig, merchant_sig]),
		"population": PackedInt64Array([10, 140]),
		"funds": PackedInt64Array([1000000000000000, 1000000000000000]),
	}, {
		"stock": stock,
		"building_cells": PackedInt32Array([0]),
		"building_type_ids": PackedInt32Array([building_id]),
		"building_owner_signature_ids": PackedInt32Array([owner_sig]),
		"building_counts": PackedInt64Array([1]),
	})
	_expect("small-owner fixture bootstraps", bool(boot.get("ok", false)))
	if not bool(boot.get("ok", false)):
		return
	var day0 := _run_day(ext, 0)
	var families: Dictionary = ext.get_family_cell_snapshot(0, 0, 64)
	_expect("ordinary family below 20 founders is rejected",
		bool(day0.get("done", false))
		and int(day0.get("population_error", 1)) == 0
		and int(families.get("total", 0)) == 0)


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


func _assert_family_effect_display_copy(compiled: Dictionary) -> void:
	var trait_catalog: Resource = FamilyTraitCatalogScript.load_default()
	var required_traits := {
		"c001_gluttony": "暴食",
		"c002_carnivore": "肉食",
		"c019_austere": "节俭",
		"i006_gathering": "采集",
		"i007_hunting": "狩猎",
		"i008_fishing": "渔",
		"i012_mining": "采矿",
		"j001_wild": "采集",
	}
	var trait_ok: bool = trait_catalog != null and trait_catalog.traits.size() == 98
	var seen_required := {}
	if trait_catalog != null:
		for definition in trait_catalog.traits:
			var key := String(definition.key)
			var description := String(definition.description)
			var display_name := String(definition.display_name)
			if display_name.is_empty() or description.is_empty():
				trait_ok = false
			if required_traits.has(key):
				seen_required[key] = true
				var needle := String(required_traits[key])
				trait_ok = trait_ok and (
					display_name.find(needle) >= 0 or description.find(needle) >= 0)
		trait_ok = trait_ok and seen_required.size() == required_traits.size()
	_expect("all family traits have Chinese mechanical descriptions", trait_ok)
	var copy_script = load("res://scripts/family/family_buff_copy.gd")
	_expect("preference copy interpolates placeholder ranges from rolled strength",
		String(copy_script.interpolate_preference(
			"主食、蔬果与蛋白质需求的消费量均增加 X%",
			"X∈[15%,40%]", 9830, 9830, 26214))
		== "主食、蔬果与蛋白质需求的消费量均增加 15%"
		and String(copy_script.interpolate_preference(
			"蛋白质需求的消费量增加 X%，蔬果需求的消费量减少 Y%",
			"X∈[20%,60%]；Y∈[10%,30%]", 26214, 9830, 26214))
		== "蛋白质需求的消费量增加 60%，蔬果需求的消费量减少 30%")
	_expect("effect copy selects the active prestige statement",
		String(copy_script.statement_for_prestige(PackedStringArray([
			"威望Ⅰ：人口增长率提高2%。",
			"威望Ⅱ：人口增长率提高4%。",
			"威望Ⅲ：人口增长率提高6%。",
			"威望Ⅳ：人口增长率提高8%。",
			"威望Ⅴ：人口增长率提高10%。",
		]), 3)).find("6%") >= 0)
	var modifier_catalog: Resource = load("res://data/modifiers/default_modifier_catalog.tres")
	var modifier_names := {}
	if modifier_catalog != null:
		for definition in modifier_catalog.definitions:
			var key := String(definition.key)
			if key.begins_with("family."):
				modifier_names[key] = String(definition.display_name)
	var modifiers_ok: bool = not modifier_names.is_empty()
	for display_name in modifier_names.values():
		modifiers_ok = modifiers_ok and not String(display_name).is_empty() \
			and String(display_name).find(".") < 0
	_expect("family modifier definitions have Chinese display names", modifiers_ok)
	var trigger_catalog: Resource = load("res://data/triggers/default_trigger_catalog.tres")
	var trigger_names := {}
	if trigger_catalog != null:
		for definition in trigger_catalog.definitions:
			var key := String(definition.key)
			if key.begins_with("family."):
				trigger_names[key] = String(definition.display_name)
	var triggers_ok: bool = not trigger_names.is_empty()
	for display_name in trigger_names.values():
		triggers_ok = triggers_ok and not String(display_name).is_empty() \
			and String(display_name).find(".") < 0
	_expect("family trigger definitions have Chinese display names",
		triggers_ok
		and String(trigger_names.get("family.build_hunting_bonus", "")) == "狩猎营地馈赠"
		and String(trigger_names.get("family.trade_population_bonus", "")) == "商路人口奖励"
		and String(trigger_names.get("family.build_fishing_bonus", "")) == "渔营馈赠"
		and String(trigger_names.get("family.build_pastoral_bonus", "")) == "牧营馈赠"
		and String(trigger_names.get("family.build_masonry_bonus", "")) == "土坯场馈赠"
		and String(trigger_names.get("family.farm_population_bonus", "")) == "农门招佃"
		and String(trigger_names.get("family.knowledge_population_bonus", "")) == "学徒迁入")
	var facade = load("res://scripts/economy/economy_facade.gd").new()
	facade._load_family_effect_displays()
	_expect("facade maps trait descriptions and family effect display names",
		String(facade._family_trait_descriptions.get("i012_mining", "")).find("采矿") >= 0
		and String((facade._family_effect_displays.get(
			"family.effect.rain_prayer", {}) as Dictionary).get(
			"display_name", "")) == "求雨"
		and String((facade._family_effect_displays.get(
			"family.effect.rain_prayer", {}) as Dictionary).get(
			"description", "")).find("降雨触发下限降低2%") >= 0
		and String((facade._family_modifier_displays.get(
			"family.city.extractive_output_boost", {}) as Dictionary).get(
			"display_name", "")) == "采掘产出加成"
		and String((facade._family_trigger_displays.get(
			"family.trade_population_bonus", {}) as Dictionary).get(
			"display_name", "")) == "商路人口奖励")
	var baseline: Dictionary = trait_catalog.compile_native_columns(compiled)
	var baseline_hash := int(baseline.get("family_trait_catalog_hash", 0))
	var mutated: Resource = trait_catalog.duplicate(false)
	var mutated_traits: Array[Resource] = []
	for definition in trait_catalog.traits:
		var copy: Resource = definition.duplicate(false)
		copy.description = "%s extra" % String(copy.description)
		mutated_traits.append(copy)
	mutated.traits = mutated_traits
	var mutated_result: Dictionary = mutated.compile_native_columns(compiled)
	_expect("family trait descriptions do not change family_trait_catalog_hash",
		baseline_hash != 0
		and int(mutated_result.get("family_trait_catalog_hash", 0)) == baseline_hash
		and not bool(baseline.has("family_trait_descriptions")))
