# Display projection helpers for EconomyFacade. The facade remains the state owner.
extends RefCounted

const FamilyTraitCatalogScript = preload("res://scripts/family/family_trait_catalog.gd")
const FamilyEffectCatalogScript = preload("res://scripts/family/family_effect_catalog.gd")
const FamilyBuffCopyScript = preload("res://scripts/family/family_buff_copy.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const TriggerCatalogScript = preload("res://scripts/trigger/trigger_catalog.gd")

static func mapped_names(stable_ids: PackedStringArray, table: Dictionary) -> PackedStringArray:
	var names := PackedStringArray()
	for stable_id in stable_ids:
		names.append(String(table.get(String(stable_id), String(stable_id))))
	return names

static func need_display_name(host, stable_id: String) -> String:
	return String(host._need_display_names.get(stable_id, stable_id))

static func building_display_name(host, building_index: int) -> String:
	var ids: PackedStringArray = host._catalog.get("building_type_ids", PackedStringArray())
	if building_index < 0 or building_index >= ids.size():
		return "建筑 %d" % building_index
	var stable_id := String(ids[building_index])
	return String(host._building_display_names.get(stable_id, stable_id))

static func good_display_name(host, good_index: int) -> String:
	var ids: PackedStringArray = host._catalog.get("good_ids", PackedStringArray())
	if good_index < 0 or good_index >= ids.size():
		return "物资 %d" % good_index
	var stable_id := String(ids[good_index])
	return String(host._good_display_names.get(stable_id, stable_id))

static func profession_display_name(host, profession_id: StringName) -> String:
	var stable_id := String(profession_id)
	return String(host._profession_display_names.get(stable_id, stable_id))

static func compose_family_display_name(
		settlement_name: String,
		surname: String,
		format: String = "CITY_SURNAME_SUFFIX",
		separator: String = "-",
		suffix: String = "氏") -> String:
	var stem := surname.strip_edges()
	if stem.is_empty():
		stem = "家族"
	var settlement := settlement_name.strip_edges()
	if settlement.is_empty():
		if format == "CITY_SURNAME_SUFFIX" and not suffix.is_empty() \
				and not stem.ends_with(suffix):
			return "%s%s" % [stem, suffix]
		return stem
	match format:
		"CITY_SEPARATOR_SURNAME":
			return "%s%s%s" % [settlement, separator, stem]
		"CITY_SURNAME":
			return "%s%s" % [settlement, stem]
		_:
			return "%s%s%s" % [settlement, stem, suffix]

static func settlement_display_name(host, cell: int) -> String:
	return String(settlement_name_lookup(host).get(cell, "地块 %d" % (cell + 1)))

static func settlement_name_lookup(host) -> Dictionary:
	var lookup := {}
	var settlements: Dictionary = host.named_settlement_snapshot()
	var cells: PackedInt32Array = settlements.get("cell_indices", PackedInt32Array())
	var names: PackedStringArray = settlements.get("settlement_names", PackedStringArray())
	for i in range(mini(cells.size(), names.size())):
		lookup[int(cells[i])] = String(names[i])
	return lookup

static func attach_family_display_names(host, snapshot: Dictionary) -> void:
	var surnames: PackedStringArray = snapshot.get("surnames", PackedStringArray())
	var origin_cells: PackedInt32Array = snapshot.get("origin_cells", PackedInt32Array())
	var culture_groups: PackedInt32Array = snapshot.get(
		"culture_group_ids", PackedInt32Array())
	var formats: PackedStringArray = host._catalog.get(
		"family_culture_group_naming_formats", PackedStringArray())
	var separators: PackedStringArray = host._catalog.get(
		"family_culture_group_separators", PackedStringArray())
	var suffixes: PackedStringArray = host._catalog.get(
		"family_culture_group_suffixes", PackedStringArray())
	var settlements := settlement_name_lookup(host)
	var family_names := PackedStringArray()
	var origin_settlement_names := PackedStringArray()
	for i in range(surnames.size()):
		var origin_cell := int(origin_cells[i]) if i < origin_cells.size() else -1
		var settlement_name := String(settlements.get(origin_cell, ""))
		var group := int(culture_groups[i]) if i < culture_groups.size() else -1
		var format := "CITY_SURNAME_SUFFIX"
		var separator := "-"
		var suffix := "氏"
		if group >= 0 and group < formats.size():
			format = String(formats[group])
		if group >= 0 and group < separators.size():
			separator = String(separators[group])
		if group >= 0 and group < suffixes.size():
			suffix = String(suffixes[group])
		origin_settlement_names.append(settlement_name)
		family_names.append(compose_family_display_name(
			settlement_name, String(surnames[i]), format, separator, suffix))
	snapshot["origin_settlement_names"] = origin_settlement_names
	snapshot["family_names"] = family_names

static func attach_notable_person_page_names(host, page: Dictionary, surname: String,
		surnames_by_family: Dictionary = {}) -> void:
	var given_indices: PackedInt32Array = page.get(
		"given_name_indices", PackedInt32Array())
	var disambiguators: PackedInt32Array = page.get(
		"name_disambiguators", PackedInt32Array())
	var families: PackedInt64Array = page.get("family_handles", PackedInt64Array())
	var given_catalog: PackedStringArray = host._catalog.get(
		"person_given_name_text", PackedStringArray())
	var given_names := PackedStringArray()
	var full_names := PackedStringArray()
	for i in given_indices.size():
		var given_idx := int(given_indices[i])
		var given := given_catalog[given_idx] \
			if given_idx >= 0 and given_idx < given_catalog.size() else ""
		var row_surname := surname
		if not surnames_by_family.is_empty() and i < families.size():
			row_surname = String(surnames_by_family.get(families[i], ""))
		var disambiguator := int(disambiguators[i]) \
			if i < disambiguators.size() else 0
		given_names.append(given)
		full_names.append(format_person_name(row_surname, given, disambiguator))
	page["given_names"] = given_names
	page["full_names"] = full_names

static func format_person_name(surname: String, given_name: String,
		disambiguator: int) -> String:
	var base := surname + given_name
	return base if disambiguator <= 0 else "%s·%d" % [base, disambiguator + 1]

static func attach_building_display_metadata(host, snapshot: Dictionary) -> void:
	var type_ids: PackedStringArray = snapshot.get("building_type_ids", PackedStringArray())
	var type_names := PackedStringArray()
	for stable_id in type_ids:
		type_names.append(String(host._building_display_names.get(String(stable_id), String(stable_id))))
	var profession_ids: PackedStringArray = host._catalog.get("profession_ids", PackedStringArray())
	var profession_names := PackedStringArray()
	for stable_id in profession_ids:
		profession_names.append(String(host._profession_display_names.get(String(stable_id), String(stable_id))))
	snapshot["building_type_display_names"] = type_names
	snapshot["profession_stable_ids"] = profession_ids
	snapshot["profession_display_names"] = profession_names
	for key in [
		"signature_profession_ids", "building_owner_profession_ids", "building_owner_slots",
		"building_employee_offsets", "building_employee_profession_ids", "building_employee_slots",
		"building_input_offsets", "building_input_good_ids", "building_input_quantities",
		"building_input_required_q16",
		"building_input_category_ids", "building_input_min_quality_levels",
		"building_input_candidate_offsets", "building_input_candidate_good_ids",
		"building_input_candidate_efficiency_q16", "building_upgrade_family_ids",
		"building_construction_candidate_offsets", "building_construction_candidate_good_ids",
		"building_construction_candidate_efficiency_q16",
		"building_upgrade_family_indices", "building_upgrade_tiers",
		"building_production_climate_profile_indices", "production_climate_profile_ids",
		"building_behavior_ids",
		"building_output_offsets", "building_output_good_ids", "building_output_quantities",
		"building_resource_ids", "building_resource_offsets", "building_production_resource_ids",
		"building_production_resource_quantities", "building_production_resource_modes",
		"building_production_resource_access_modes",
		"building_resource_generation_offsets",
		"building_resource_generation_ids", "building_resource_generation_quantities",
		"building_resource_generation_floor_q16", "building_kinds",
		"building_technology_tag_offsets", "building_technology_tags", "good_ids",
		"good_category_ids", "good_substitution_category_offsets",
		"good_substitution_category_ids", "good_storage_modes", "good_monetary_issue_values",
		"good_production_quality_levels", "good_production_efficiency_q16",
		"good_technology_tag_offsets", "good_technology_tags",
	]:
		snapshot[key] = host._catalog.get(key)

static func attach_population_display_metadata(host, snapshot: Dictionary) -> void:
	var profession_ids: PackedStringArray = snapshot.get(
		"profession_stable_ids", PackedStringArray())
	var ethnicity_ids: PackedStringArray = snapshot.get(
		"ethnicity_stable_ids", PackedStringArray())
	var profession_names := PackedStringArray()
	var ethnicity_names := PackedStringArray()
	for stable_id in profession_ids:
		profession_names.append(String(host._profession_display_names.get(
			String(stable_id), String(stable_id))))
	for stable_id in ethnicity_ids:
		ethnicity_names.append(String(host._ethnicity_display_names.get(
			String(stable_id), String(stable_id))))
	snapshot["profession_display_names"] = profession_names
	snapshot["ethnicity_display_names"] = ethnicity_names

static func register_modifier_display_names(host) -> void:
	# Modifier lines on idea cards are rendered from selector-addressable stat keys
	# such as country.output.building.iron_tool_workshop_factor. The card formatter
	# resolves the trailing stable id through this registry, so it always matches
	# the name the economy UI shows instead of leaking the raw slug.
	ModifierCatalogScript.register_display_names(&"building", host._building_display_names)
	ModifierCatalogScript.register_display_names(&"good", host._good_display_names)
	ModifierCatalogScript.register_display_names(&"profession", host._profession_display_names)
	ModifierCatalogScript.register_display_names(&"need", host._need_display_names)

static func load_family_effect_displays(host) -> void:
	host._family_trait_descriptions.clear()
	host._family_trait_copy.clear()
	host._family_trait_effect_keys.clear()
	host._family_effect_displays.clear()
	host._family_modifier_displays.clear()
	host._family_trigger_displays.clear()
	var trait_catalog = FamilyTraitCatalogScript.load_default()
	if trait_catalog != null:
		for definition in trait_catalog.traits:
			if definition == null:
				continue
			var trait_key := String(definition.key).strip_edges()
			if trait_key.is_empty():
				continue
			host._family_trait_descriptions[trait_key] = String(
				definition.description).strip_edges()
			var primary_axis := -1
			if definition.behaviors is Array and not definition.behaviors.is_empty() \
					and definition.behaviors[0] != null:
				primary_axis = int(definition.behaviors[0].get("axis"))
			host._family_trait_copy[trait_key] = {
				"display_name": String(definition.display_name).strip_edges(),
				"template": String(definition.get("description_template")).strip_edges(),
				"range_text": String(definition.get("range_text")).strip_edges(),
				"strength_min_q16": int(definition.strength_min_q16),
				"strength_max_q16": int(definition.strength_max_q16),
				"primary_axis": primary_axis,
			}
			var effect_keys := PackedStringArray()
			var seen := {}
			for effect in definition.modifiers:
				if effect == null:
					continue
				var modifier_key := String(effect.definition_key).strip_edges()
				if modifier_key.is_empty() or seen.has(modifier_key):
					continue
				seen[modifier_key] = true
				effect_keys.append(modifier_key)
			for binding in definition.triggers:
				if binding == null:
					continue
				for raw_key in binding.definition_keys_by_tier:
					var trigger_key := String(raw_key).strip_edges()
					if trigger_key.is_empty() or seen.has(trigger_key):
						continue
					seen[trigger_key] = true
					effect_keys.append(trigger_key)
			host._family_trait_effect_keys[trait_key] = effect_keys
	var effect_catalog = FamilyEffectCatalogScript.load_default()
	if effect_catalog != null:
		for definition in effect_catalog.effects:
			store_family_effect_display(host, definition)
	var modifier_catalog = ModifierCatalogScript.load_default()
	if modifier_catalog != null:
		for definition in modifier_catalog.definitions:
			store_effect_display(host._family_modifier_displays, definition)
	var trigger_catalog = TriggerCatalogScript.load_default()
	if trigger_catalog != null:
		for definition in trigger_catalog.definitions:
			store_effect_display(host._family_trigger_displays, definition)
		for definition in TriggerCatalogScript._family_buff_definitions():
			store_effect_display(host._family_trigger_displays, definition)

static func store_effect_display(table: Dictionary, definition: Resource) -> void:
	if definition == null:
		return
	var key := String(definition.get("key")).strip_edges()
	if key.is_empty():
		return
	table[key] = {
		"display_name": String(definition.get("display_name")).strip_edges(),
		"description": String(definition.get("description")).strip_edges(),
	}

static func store_family_effect_display(host, definition: Resource) -> void:
	if definition == null:
		return
	var raw := String(definition.get("key")).strip_edges()
	if raw.is_empty():
		return
	var program_key := raw if raw.begins_with("family.effect.") \
		else "family.effect.%s" % raw
	var entry := {
		"display_name": String(definition.get("display_name")).strip_edges(),
		"description": String(definition.get("description")).strip_edges(),
		"prestige_descriptions": FamilyBuffCopyScript.prestige_statements(
			String(definition.get("description")),
			definition.get("prestige_descriptions")),
	}
	host._family_effect_displays[program_key] = entry
	host._family_effect_displays[raw] = entry

static func family_trait_description_column(host, trait_keys: PackedStringArray,
		strengths: PackedInt32Array = PackedInt32Array()) -> PackedStringArray:
	var descriptions := PackedStringArray()
	for index in range(trait_keys.size()):
		var trait_key := String(trait_keys[index])
		var copy: Dictionary = host._family_trait_copy.get(trait_key, {})
		var template := String(copy.get("template", "")).strip_edges()
		if template.is_empty():
			descriptions.append(String(host._family_trait_descriptions.get(trait_key, "")))
			continue
		var strength := int(strengths[index]) if index < strengths.size() \
			else int(copy.get("strength_min_q16", 65536))
		descriptions.append(FamilyBuffCopyScript.interpolate_preference(
			template,
			String(copy.get("range_text", "")),
			strength,
			int(copy.get("strength_min_q16", 0)),
			int(copy.get("strength_max_q16", 0))))
	return descriptions

static func family_trait_effect_display_names(host, trait_keys: PackedStringArray) -> PackedStringArray:
	var names := PackedStringArray()
	var seen := {}
	for trait_key in trait_keys:
		var effect_keys: PackedStringArray = host._family_trait_effect_keys.get(
			String(trait_key), PackedStringArray())
		for effect_key in effect_keys:
			var display := effect_display_name(host, String(effect_key))
			if display.is_empty() or seen.has(display):
				continue
			seen[display] = true
			names.append(display)
	return names

static func effect_display_name(host, effect_key: String) -> String:
	var family_effect: Dictionary = host._family_effect_displays.get(effect_key, {})
	var family_name := String(family_effect.get("display_name", ""))
	if not family_name.is_empty():
		return family_name
	var modifier: Dictionary = host._family_modifier_displays.get(effect_key, {})
	var modifier_name := String(modifier.get("display_name", ""))
	if not modifier_name.is_empty():
		return modifier_name
	var trigger: Dictionary = host._family_trigger_displays.get(effect_key, {})
	var trigger_name := String(trigger.get("display_name", ""))
	if not trigger_name.is_empty():
		return trigger_name
	return ""

static func mapped_effect_names(keys: PackedStringArray, table: Dictionary) -> PackedStringArray:
	var names := PackedStringArray()
	for key in keys:
		var entry: Dictionary = table.get(String(key), {})
		var display := String(entry.get("display_name", "")).strip_edges()
		names.append(display if not display.is_empty() else String(key))
	return names

static func mapped_effect_descriptions(keys: PackedStringArray, table: Dictionary) -> PackedStringArray:
	var descriptions := PackedStringArray()
	for key in keys:
		var entry: Dictionary = table.get(String(key), {})
		descriptions.append(String(entry.get("description", "")).strip_edges())
	return descriptions

static func mapped_effect_current_descriptions(host, keys: PackedStringArray,
		prestige_level: int) -> PackedStringArray:
	var descriptions := PackedStringArray()
	for key in keys:
		var entry: Dictionary = host._family_effect_displays.get(String(key), {})
		var statements: PackedStringArray = entry.get(
			"prestige_descriptions", PackedStringArray())
		var current := FamilyBuffCopyScript.statement_for_prestige(
			statements, prestige_level)
		if current.is_empty():
			current = String(entry.get("description", "")).strip_edges()
		descriptions.append(current)
	return descriptions

static func mapped_effect_prestige_descriptions(host, keys: PackedStringArray) -> Array:
	var out: Array = []
	for key in keys:
		var entry: Dictionary = host._family_effect_displays.get(String(key), {})
		var statements: PackedStringArray = entry.get(
			"prestige_descriptions", PackedStringArray())
		out.append(statements)
	return out

static func family_max_prestige_level(host, family_handle: int) -> int:
	var branches: Dictionary = host.family_branches(family_handle, 0, 64)
	if not bool(branches.get("ok", false)):
		return 0
	var prestige := 0
	var levels: PackedInt32Array = branches.get("prestige_levels", PackedInt32Array())
	for level in levels:
		prestige = maxi(prestige, int(level))
	return prestige


## Headless A/B only: PK_ECONOMY_FORCE_CADENCE="market,plan,investment" (days)
## replaces the measured-ms cadence, which otherwise varies with machine load
## and makes two runs of the same seed diverge.

static func apply_forced_cadence_env(profile: Dictionary) -> void:
	var parts := OS.get_environment("PK_ECONOMY_FORCE_CADENCE").split(",", false)
	if parts.size() != 3:
		return
	profile["economy_cadence_force_market_days"] = int(parts[0])
	profile["economy_cadence_force_plan_days"] = int(parts[1])
	profile["economy_cadence_force_investment_days"] = int(parts[2])

static func load_display_names(directory: String) -> Dictionary:
	var result := {}
	# [pk-export-remap] 见 economy_catalog.gd::_load_resources() 同名注释——导出
	# 包里 DirAccess 看到的是带 .remap 后缀的目录项，用 ResourceLoader.list_directory()
	# 才能拿到 x.tres 逻辑名。
	var paths := PackedStringArray()
	for file_name in ResourceLoader.list_directory(directory):
		if file_name.get_extension().to_lower() == "tres":
			paths.append("%s/%s" % [directory, file_name])
	paths.sort()
	for path in paths:
		var profile = ResourceLoader.load(path, "Resource")
		if profile == null:
			continue
		var stable_id := String(profile.get("id"))
		if stable_id == "":
			continue
		var display_name := String(profile.get("display_name"))
		result[stable_id] = display_name if display_name != "" else stable_id
	return result
