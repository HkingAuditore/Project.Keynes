extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const FamilyEffectCatalogScript = preload("res://scripts/family/family_effect_catalog.gd")
const FamilyEffectDefinitionScript = preload("res://scripts/family/family_effect_definition.gd")

var _failures: Array[String] = []


func _expect(label: String, condition: bool) -> void:
	if not condition:
		_failures.append(label)


func _append_modifier_definition(catalog: Dictionary, definition_key: String,
		stat_key: String, factor: float) -> bool:
	var stat_keys: PackedStringArray = catalog.get("stat_keys", PackedStringArray())
	var stat_id := stat_keys.find(stat_key)
	if stat_id < 0:
		return false
	var definition_keys: PackedStringArray = catalog.definition_keys
	var definition_versions: PackedInt32Array = catalog.definition_versions
	var definition_domains: PackedInt32Array = catalog.definition_domains
	var definition_policies: PackedInt32Array = catalog.definition_policies
	var definition_max_stacks: PackedInt32Array = catalog.definition_max_stacks
	var definition_durations: PackedInt32Array = catalog.definition_default_duration
	var definition_offsets: PackedInt32Array = catalog.definition_term_offsets
	var term_stats: PackedInt32Array = catalog.term_stat_ids
	var term_operations: PackedInt32Array = catalog.term_operations
	var term_values: PackedFloat64Array = catalog.term_values
	definition_keys.append(definition_key)
	definition_versions.append(1)
	definition_domains.append(2)
	definition_policies.append(1) # UNIQUE_SOURCE
	definition_max_stacks.append(1)
	definition_durations.append(-1)
	term_stats.append(stat_id)
	term_operations.append(2) # MULTIPLY
	term_values.append(factor)
	definition_offsets.append(term_values.size())
	catalog.definition_keys = definition_keys
	catalog.definition_versions = definition_versions
	catalog.definition_domains = definition_domains
	catalog.definition_policies = definition_policies
	catalog.definition_max_stacks = definition_max_stacks
	catalog.definition_default_duration = definition_durations
	catalog.definition_term_offsets = definition_offsets
	catalog.term_stat_ids = term_stats
	catalog.term_operations = term_operations
	catalog.term_values = term_values
	return true


func _family_effect(key: String, selector_id: String,
		modifier_definition_key: String) -> Resource:
	var command := EffectCommand.new()
	command.action = 1 # MODIFIER_COMMAND
	command.domain = 2 # Economy
	command.opcode = 1 # APPLY
	command.target_resolver = 1 # TARGET_INSTANCE
	command.command_key = &"family.effect.output.test"
	command.definition_key = StringName(modifier_definition_key)
	var effect := FamilyEffectDefinitionScript.new()
	effect.key = StringName(key)
	effect.source_kind = FamilyEffectDefinitionScript.SourceKind.RANDOM_POOL
	effect.random_pool_eligible = true
	effect.target_domain = FamilyEffectDefinitionScript.TargetDomain.BUILDING_RESOURCE
	effect.operation = FamilyEffectDefinitionScript.Operation.MULTIPLY
	effect.target_selector_kind = FamilyEffectDefinitionScript.TargetSelectorKind.SELECTOR_ID
	effect.target_selector_id = StringName(selector_id)
	effect.commands = [command]
	return effect


func _configure_cells(ext: Object, cell_count: int, economy: Dictionary) -> void:
	ext.create_entities(cell_count)
	var zero_f := PackedFloat32Array()
	zero_f.resize(cell_count)
	zero_f.fill(0.0)
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_weather_precip", &"cell_snow_cover",
			&"cell_weather_intensity", &"cell_elevation"]:
		var sid: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(sid, 0, zero_f)
	var zero_u8 := PackedByteArray()
	zero_u8.resize(cell_count)
	zero_u8.fill(0)
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation",
			&"cell_is_water", &"cell_has_river"]:
		var sid: int = ext.register_component(slot_name, 2, 1, false)
		ext.write_u8_range(sid, 0, zero_u8)
	for index in range((economy.building_resource_ids as PackedStringArray).size()):
		var reserve_sid: int = ext.register_component(StringName(
			(economy.building_resource_reserve_slots as PackedStringArray)[index]),
			0, 1, false)
		var extra_sid: int = ext.register_component(StringName(
			(economy.building_resource_extra_slots as PackedStringArray)[index]),
			0, 1, false)
		ext.write_f32_range(reserve_sid, 0, zero_f)
		ext.write_f32_range(extra_sid, 0, zero_f)


func _run_economy_day(ext: Object, day: int) -> Dictionary:
	var report := {}
	for slice in range(256):
		report = ext.run_economy_slice({"day_index": day, "tick_index": slice})
		if bool(report.get("done", false)):
			return report
	return report


func _test_catalog_semantics(economy: Dictionary,
		modifier_catalog: Dictionary, good_id: String,
		building_id: String, resource_id: String) -> void:
	var family_catalog := FamilyEffectCatalogScript.new()
	family_catalog.effects = [
		_family_effect("good", good_id, "test.family.good.output"),
		_family_effect("building", building_id, "test.family.building.output"),
		_family_effect("resource", resource_id, "test.family.resource.regen"),
	]
	var valid: Dictionary = family_catalog.validate_domain_bindings(
		economy, modifier_catalog)
	_expect("exact good/building/resource selectors validate", bool(valid.get("ok", false)))

	var wrong := modifier_catalog.duplicate(true)
	var definition_keys: PackedStringArray = wrong.definition_keys
	var definition_offsets: PackedInt32Array = wrong.definition_term_offsets
	var term_stats: PackedInt32Array = wrong.term_stat_ids
	var stat_keys: PackedStringArray = wrong.stat_keys
	var definition_id := definition_keys.find("test.family.good.output")
	var wrong_stat := stat_keys.find(
		"economy.city.good.%s.consumption_factor" % good_id)
	if definition_id >= 0 and wrong_stat >= 0:
		term_stats[definition_offsets[definition_id]] = wrong_stat
	wrong.term_stat_ids = term_stats
	var rejected: Dictionary = family_catalog.validate_domain_bindings(economy, wrong)
	_expect("selector rejects semantically different modifier stat",
		not bool(rejected.get("ok", true)) and String(rejected.get("reason", "")) ==
			"family_effect_selector_modifier_stat_mismatch")


func _test_sparse_good_output(economy: Dictionary,
		modifier_catalog: Dictionary, good_id: String) -> void:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	_configure_cells(ext, 2, economy)
	var native_modifier := modifier_catalog.duplicate(true)
	native_modifier.erase("ok")
	_expect("modifier catalog configures", bool(ext.configure_modifiers(
		native_modifier, 2).get("ok", false)))
	var native_economy := economy.duplicate(true)
	native_economy.erase("ok")
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	_expect("economy configures", bool(ext.configure_economy(
		native_economy, profile, 2, 8102).get("ok", false)))
	var signature_ids: PackedStringArray = economy.signature_keys
	var unemployed := signature_ids.find("unemployed|default")
	_expect("test signature exists", unemployed >= 0)
	_expect("economy bootstraps", bool(ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 1]),
		"signature_ids": PackedInt32Array([unemployed, unemployed]),
		"population": PackedInt64Array([10, 10]),
		"funds": PackedInt64Array([100000, 100000]),
	}, {}).get("ok", false)))
	var submitted: Dictionary = ext.submit_modifier_commands({
		"protocol_version": 2,
		"opcodes": PackedInt32Array([1]),
		"producer_ids": PackedInt32Array([161]),
		"sequences": PackedInt64Array([1]),
		"effective_days": PackedInt64Array([0]),
		"definition_keys": PackedStringArray(["test.family.good.output"]),
		"domains": PackedInt32Array([2]),
		"scopes": PackedInt32Array([1]),
		"entity_handles": PackedInt64Array([0]),
		"group_handles": PackedInt64Array([0]),
		"source_types": PackedInt64Array([0x46414d45]),
		"source_ids": PackedInt64Array([1]),
		"duration_days": PackedInt32Array([-1]),
		"stacks": PackedInt32Array([1]),
		"magnitude_q16": PackedInt32Array([65536]),
		"modifier_handles": PackedInt64Array([0]),
	})
	_expect("cell-zero exact output modifier submits", bool(submitted.get("ok", false)))
	_expect("modifier boundary commits", bool(ext.run_modifier_daily(0).get("ok", false)))
	var report := _run_economy_day(ext, 0)
	if not bool(report.get("done", false)) or bool(report.get("fatal", false)):
		print("family_effect_output_runtime_test report=", report)
	var full_report: Dictionary = ext.get_economy_report()
	_expect("economy day completes", bool(report.get("done", false)) and
		not bool(report.get("fatal", false)))
	_expect("cell-zero output remains one sparse override",
		int(full_report.get("city_good_output_override_count", -1)) == 1 and
		int(full_report.get("city_good_output_override_cell_count", -1)) == 1 and
		int(full_report.get("city_good_output_non_neutral_shared_count", -1)) == 0 and
		int(full_report.get("city_good_output_shared_count", -1)) ==
			(economy.good_ids as PackedStringArray).size())
	_expect("unrelated cell stays neutral", is_equal_approx(float(
		ext.evaluate_modifier_stat(2, 0, 1,
			"economy.city.good.%s.output_factor" % good_id, 1.0)), 1.0))

	# Producer 161 ENTITY targets may name either a family or a local branch.
	# Both stores use generation-safe handles, so an out-of-range index with a
	# non-zero generation must survive ingress but be rejected at safe commit.
	var stale_family_or_branch_handle := int((7 << 32) | 0x7ffffffe)
	var stale_submit: Dictionary = ext.submit_modifier_commands({
		"protocol_version": 2,
		"opcodes": PackedInt32Array([1]),
		"producer_ids": PackedInt32Array([161]),
		"sequences": PackedInt64Array([2]),
		"effective_days": PackedInt64Array([1]),
		"definition_keys": PackedStringArray(["test.family.good.output"]),
		"domains": PackedInt32Array([2]),
		"scopes": PackedInt32Array([2]), # ENTITY
		"entity_handles": PackedInt64Array([stale_family_or_branch_handle]),
		"group_handles": PackedInt64Array([0]),
		"source_types": PackedInt64Array([0x46414d45]),
		"source_ids": PackedInt64Array([2]),
		"duration_days": PackedInt32Array([-1]),
		"stacks": PackedInt32Array([1]),
		"magnitude_q16": PackedInt32Array([65536]),
		"modifier_handles": PackedInt64Array([0]),
	})
	var stale_request_ids: PackedInt64Array = stale_submit.get(
		"request_ids", PackedInt64Array())
	_expect("stale family/branch command enters typed queue",
		bool(stale_submit.get("ok", false)) and stale_request_ids.size() == 1)
	var stale_boundary: Dictionary = ext.run_modifier_daily(1)
	_expect("stale family/branch safe boundary completes without applying",
		bool(stale_boundary.get("ok", false)) and
		int(stale_boundary.get("commands_applied", -1)) == 0)
	if stale_request_ids.size() == 1:
		var stale_result: Dictionary = ext.get_modifier_command_result(
			int(stale_request_ids[0]))
		_expect("stale family/branch handle is explicitly rejected",
			not bool(stale_result.get("ok", true)) and
			String(stale_result.get("reason", "")) ==
				"modifier_family_effect_handle_stale")


func _init() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("family_effect_output_runtime_test: SKIP")
		quit(0)
		return
	var economy: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("economy catalog compiles", bool(economy.get("ok", false)))
	var goods: PackedStringArray = economy.get("good_ids", PackedStringArray())
	var buildings: PackedStringArray = economy.get(
		"building_type_ids", PackedStringArray())
	var resources: PackedStringArray = economy.get(
		"building_resource_ids", PackedStringArray())
	if goods.is_empty() or buildings.is_empty() or resources.is_empty():
		_expect("selector catalogs are non-empty", false)
		_finish()
		return
	var good_id := String(goods[0])
	var building_id := String(buildings[0])
	var resource_id := String(resources[0])
	var modifier_catalog: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	_expect("modifier catalog compiles", bool(modifier_catalog.get("ok", false)))
	_expect("good output stat generated", _append_modifier_definition(
		modifier_catalog, "test.family.good.output",
		"economy.city.good.%s.output_factor" % good_id, 1.2))
	_expect("building output stat generated", _append_modifier_definition(
		modifier_catalog, "test.family.building.output",
		"economy.city.building.%s.output_factor" % building_id, 1.1))
	_expect("resource regen stat generated", _append_modifier_definition(
		modifier_catalog, "test.family.resource.regen",
		"economy.city.resource.%s.regen_factor" % resource_id, 1.15))
	_test_catalog_semantics(economy, modifier_catalog, good_id, building_id, resource_id)
	_test_sparse_good_output(economy, modifier_catalog, good_id)
	_finish()


func _finish() -> void:
	if _failures.is_empty():
		print("family_effect_output_runtime_test: PASS")
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		print("family_effect_output_runtime_test: FAIL (%d)" % _failures.size())
		quit(1)
