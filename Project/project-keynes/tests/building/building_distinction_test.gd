extends SceneTree

const Economy = preload("res://scripts/economy/economy_catalog.gd")
const NETWORK := "res://data/technology/technology_network.json"
const REVIEW := "res://tools/technology_tree/building_distinction_review.json"

var failures: Array[String] = []


func _init() -> void:
	var catalog: Dictionary = Economy.compile_native_catalog()
	_check(bool(catalog.get("ok", false)), "catalog compiles: %s" % catalog)
	if not failures.is_empty():
		_finish()
		return
	var network: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(NETWORK))
	var review: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(REVIEW))
	_test_choice_classification()
	var profiles := {}
	for file in ResourceLoader.list_directory(Economy.BUILDING_DIR):
		if String(file).get_extension() != "tres":
			continue
		var profile = load("%s/%s" % [Economy.BUILDING_DIR, file])
		profiles[String(profile.id)] = profile
	for row in review.removed:
		_check(not profiles.has(String(row.id)), "removed lot returned: %s" % row.id)
		_check(profiles.has(String(row.absorbed_by)), "missing surviving route: %s" % row.absorbed_by)
	var metric_offsets: PackedInt32Array = catalog.development_metric_subject_offsets
	var metric_kinds: PackedInt32Array = catalog.development_metric_subject_kinds
	var metric_subjects: PackedStringArray = catalog.development_metric_subject_ids
	for metric in range(metric_kinds.size()):
		if int(metric_kinds[metric]) != 2:
			continue
		for edge in range(metric_offsets[metric], metric_offsets[metric + 1]):
			_check(profiles.has(String(metric_subjects[edge])), "stale development building metric: %s" % metric_subjects[edge])
	var eras := {}
	var technologies := {}
	for index in range(network.eras.size()):
		eras[String(network.eras[index].id)] = index
	for row in network.nodes:
		technologies[String(row.id)] = row
		for binding in row.get("expected_bindings", []):
			if int(binding.kind) == 2:
				_check(profiles.has(String(binding.id)), "stale building unlock: %s" % binding.id)
	var research_by_era := {}
	var choices := {}
	for id in profiles:
		var profile = profiles[id]
		var era := _era(profile, technologies, eras)
		if profile.output_good_ids == PackedStringArray(["technology_points"]):
			_check(not research_by_era.has(era), "same-era research copies: %s / %s" % [
				research_by_era.get(era, ""), id])
			research_by_era[era] = id
		if profile.output_good_ids.is_empty():
			continue # Military roles have their own physical capacity/defense contract.
		var fingerprint := _choice_fingerprint(profile, era)
		_check(not choices.has(fingerprint), "same-era recipe/job/geography copy: %s / %s" % [
			choices.get(fingerprint, ""), id])
		choices[fingerprint] = id
	_check(profiles.has("early_knowledge_institution"), "universal starter institution remains")
	_check(Economy.allows_zero_cost_construction(profiles.primitive_clay_pit)
		and profiles.primitive_clay_pit.construction_good_ids.is_empty(), "clay keeps the zero-material construction entry")
	_check(profiles.flax_retting_pit.required_technology_tags.has("tech.wild_flax_collection")
		and profiles.flax_retting_pit.required_technology_tags.has("tech.rainfed_field_system"), "retting requires a surviving upstream fiber route")
	for id in ["cottage_weaving", "improved_domestic_loom"]:
		var profile = profiles[id]
		_check(profile.building_kind == "industrial" and profile.economic_sector_id == "manufacturing",
			"weaving belongs to manufacturing: %s" % id)
		_check(profile.resource_ids.is_empty() and profile.behavior_id == "none",
			"weaving cannot produce cloth from land: %s" % id)
		_check(not profile.input_good_ids.is_empty() and profile.input_required_q16[0] == 65536,
			"weaving requires physical fiber: %s" % id)
	_check(profiles.cottage_weaving.input_good_ids.has("bast_fiber"), "household bast-fiber recipe")
	_check(profiles.improved_domestic_loom.input_good_ids.has("flax_fiber"), "improved loom uses retted fiber")
	_check(not profiles.improved_domestic_loom.input_good_ids.has("coal"), "owner-operated loom needs no coal")
	_check(profiles.textile_mill.input_good_ids.has("coal") and profiles.textile_mill.input_good_ids.has("dyestuff")
		and not profiles.textile_mill.employee_profession_ids.is_empty(), "steam mill has fuel/dye/employment tradeoff")
	_check(profiles.water_powder_mill.condition_signals == PackedInt32Array([9])
		and profiles.water_powder_mill.condition_values == PackedInt64Array([1]), "water powder mill requires a river")
	_check(profiles.steam_powder_works.input_good_ids.has("coal")
		and profiles.steam_powder_works.input_good_ids.has("machine_parts"), "steam powder works uses fuel and machinery")
	_check(profiles.sharecrop_paddy.employee_profession_ids.has("sharecropper")
		and profiles.tenant_paddy.employee_profession_ids.has("tenant_farmer"), "rice alternatives employ distinct social classes")
	_check(_has_term(technologies["tech.tide_observation"], "country.trade.speed_factor", 0.03), "tide knowledge keeps trade effect")
	_check(_has_term(technologies["tech.flood_calendar_practice"], "country.climate.flood_loss_factor", -0.06), "flood knowledge keeps loss reduction")
	for row in network.nodes:
		for term in row.get("modifier_terms", []):
			_check(String(term.stat) not in ["country.output.family.cadastral_institution_factor",
				"country.output.family.geospatial_analysis_institution_factor"], "removed institution has no phantom modifier")
	_finish()


func _era(profile, technologies: Dictionary, eras: Dictionary) -> int:
	var primary := 999
	for tag in profile.technology_tags:
		if technologies.has(String(tag)):
			primary = mini(primary, int(eras[technologies[String(tag)].era_id]))
	var result := 0 if primary == 999 else primary
	for tag in profile.required_technology_tags:
		if technologies.has(String(tag)):
			result = maxi(result, int(eras[technologies[String(tag)].era_id]))
	return result


func _choice_fingerprint(profile, era: int) -> String:
	# Ignore numeric scale and tool quality. Distinct co-product ratios, physical
	# inputs/resources, owner/employee classes, climate and geography are choices.
	var divisor := 0
	for quantity in profile.output_quantities_per_day:
		divisor = _gcd(divisor, int(quantity))
	var outputs: Array[String] = []
	for index in range(profile.output_good_ids.size()):
		outputs.append("%s:%d" % [profile.output_good_ids[index],
			int(profile.output_quantities_per_day[index]) / maxi(divisor, 1)])
	outputs.sort()
	var inputs := Array(profile.input_good_ids)
	inputs.sort()
	var resources := Array(profile.resource_ids)
	resources.sort()
	var employees := Array(profile.employee_profession_ids)
	employees.sort()
	return JSON.stringify([era, outputs, inputs, resources, profile.behavior_id,
		profile.owner_profession_id, employees, profile.production_climate_profile_id,
		profile.resource_generation_ids, profile.condition_opcodes, profile.condition_signals,
		profile.condition_compares, profile.condition_reference_ids, profile.condition_values])


func _gcd(a: int, b: int) -> int:
	while b != 0:
		var remainder := a % b
		a = b
		b = remainder
	return absi(a)


func _test_choice_classification() -> void:
	var base = load("res://data/economy/buildings/stone_age_hunting_camp.tres").duplicate(true)
	base.output_good_ids = PackedStringArray(["game_meat"])
	base.output_quantities_per_day = PackedInt64Array([1000])
	var scaled = base.duplicate(true)
	scaled.output_quantities_per_day = PackedInt64Array([2000])
	_check(_choice_fingerprint(base, 0) == _choice_fingerprint(scaled, 0), "scale alone cannot pass as a choice")
	scaled.condition_opcodes = PackedInt32Array([1])
	scaled.condition_signals = PackedInt32Array([9])
	scaled.condition_compares = PackedInt32Array([0])
	scaled.condition_reference_ids = PackedStringArray([""])
	scaled.condition_values = PackedInt64Array([1])
	_check(_choice_fingerprint(base, 0) != _choice_fingerprint(scaled, 0), "river geography is a real choice")
	scaled = base.duplicate(true)
	base.output_good_ids = PackedStringArray(["game_meat", "raw_hide"])
	base.output_quantities_per_day = PackedInt64Array([1000, 100])
	scaled.output_good_ids = base.output_good_ids
	scaled.output_quantities_per_day = PackedInt64Array([1000, 300])
	_check(_choice_fingerprint(base, 0) != _choice_fingerprint(scaled, 0), "food versus hide production mix is a real choice")


func _has_term(row: Dictionary, stat: String, value: float) -> bool:
	for term in row.get("modifier_terms", []):
		if String(term.stat) == stat and is_equal_approx(float(term.value), value):
			return true
	return false


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	for failure in failures:
		push_error(failure)
	print("building_distinction_test: %s (%d failures)" % ["PASS" if failures.is_empty() else "FAIL", failures.size()])
	quit(0 if failures.is_empty() else 1)
