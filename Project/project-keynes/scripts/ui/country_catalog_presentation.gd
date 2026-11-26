extends RefCounted

const GoodProfileRegistryScript = preload("res://scripts/data/good_profile_registry.gd")
const ResourceProfileRegistryScript = preload("res://scripts/data/resource_profile_registry.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
static var _tax_content_cache: Dictionary = {}


static func _application_definitions(raw_applications: Array, lanes: Array) -> Array:
	var building_content := _tax_content("building")
	var good_content := _tax_content("good")
	var resource_names := {}
	for profile in ResourceProfileRegistryScript.ordered():
		resource_names[String(profile.id)] = String(profile.display_name)
	var lane_names := {}
	for lane_value in lanes:
		var lane: Dictionary = lane_value
		lane_names[String(lane.get("id", ""))] = String(lane.get(
			"display_name", lane.get("id", "")))
	var out: Array = []
	for raw_value in raw_applications:
		var raw: Dictionary = raw_value
		var buildings: Array = []
		var effects: Array = []
		var chain_ids := PackedStringArray()
		var maturity_names := PackedStringArray()
		var progression_roles := PackedStringArray()
		var progression_step := 0
		var required_inputs: Array = []
		var required_resources: Array = []
		var has_location_conditions := false
		var seen_inputs := {}
		var seen_resources := {}
		for building_id_value in raw.get("building_ids", PackedStringArray()):
			var building_id := String(building_id_value)
			var building: Dictionary = building_content.get(building_id, {})
			var display_name := String(building.get("display_name", building_id))
			buildings.append({
				"id": building_id,
				"display_name": display_name,
				"industry_chain_id": String(building.get("industry_chain_id", "")),
				"progression_step": int(building.get("progression_step", 0)),
				"maturity_display_name": String(building.get(
					"maturity_display_name", "")),
				"progression_role": String(building.get("progression_role", "")),
			})
			var building_step := int(building.get("progression_step", 0))
			var building_maturity := String(building.get(
				"maturity_display_name", ""))
			var effect_name := display_name
			if building_step > 0:
				effect_name += "（产业步骤 %d%s）" % [building_step,
					" · %s" % building_maturity if not building_maturity.is_empty() else ""]
			effects.append({"kind": "building", "id": building_id,
				"display_name": effect_name})
			var chain_id := String(building.get("industry_chain_id", ""))
			if not chain_id.is_empty() and not chain_ids.has(chain_id):
				chain_ids.append(chain_id)
			var maturity_name := String(building.get("maturity_display_name", ""))
			if not maturity_name.is_empty() and not maturity_names.has(maturity_name):
				maturity_names.append(maturity_name)
			var role := String(building.get("progression_role", ""))
			if not role.is_empty() and not progression_roles.has(role):
				progression_roles.append(role)
			progression_step = maxi(progression_step,
				int(building.get("progression_step", 0)))
			for input_id_value in building.get("input_good_ids", PackedStringArray()):
				var input_id := String(input_id_value)
				if seen_inputs.has(input_id):
					continue
				seen_inputs[input_id] = true
				var input: Dictionary = good_content.get(input_id, {})
				required_inputs.append({"id": input_id, "display_name": String(
					input.get("display_name", input_id))})
			for resource_id_value in building.get("resource_ids", PackedStringArray()):
				var resource_id := String(resource_id_value)
				if seen_resources.has(resource_id):
					continue
				seen_resources[resource_id] = true
				required_resources.append({"id": resource_id,
					"display_name": String(resource_names.get(
						resource_id, resource_id))})
			has_location_conditions = has_location_conditions \
				or bool(building.get("has_location_conditions", false))
		var required_ids := PackedStringArray(raw.get(
			"required_technology_ids", PackedStringArray()))
		var industry_chain_id := String(raw.get("industry_chain_id",
			raw.get("branch_family_id", "")))
		var layout_lane := String(raw.get("layout_lane",
			raw.get("branch_family_id", industry_chain_id)))
		if layout_lane.is_empty():
			layout_lane = String(raw.get("branch_family_id", industry_chain_id))
		out.append({
			"id": String(raw.get("id", "")),
			"display_name": String(raw.get("display_name", "")),
			"description": String(raw.get("description", "")),
			"era_id": String(raw.get("era_id", "")),
			"domain_id": String(raw.get("domain_id", "")),
			"branch_family_id": String(raw.get("branch_family_id", "")),
			"industry_chain_id": industry_chain_id,
			"industry_chain_display_name": String(lane_names.get(
				industry_chain_id, industry_chain_id)),
			"layout_lane": layout_lane,
			"anchor_kind": "application",
			"node_role": "application",
			"is_application": true,
			"cost_points": 0,
			"required_technology_ids": required_ids,
			"application_foundation_ids": required_ids,
			"primary_technology_id": String(required_ids[0]) \
				if not required_ids.is_empty() else "",
			"building_ids": PackedStringArray(raw.get(
				"building_ids", PackedStringArray())),
			"building_unlocks": buildings,
			"content_effects": effects,
			"industry_chain_ids": chain_ids,
			"progression_step": progression_step,
			"maturity_display_names": maturity_names,
			"progression_roles": progression_roles,
			"required_input_good_ids": required_inputs,
			"required_resource_ids": required_resources,
			"required_tile_condition_ids": ([{
				"id": "building_location",
				"display_name": "建筑选址条件",
			}] if has_location_conditions else []),
		})
	return out


static func _tax_content(kind: String) -> Dictionary:
	if _tax_content_cache.has(kind):
		return _tax_content_cache[kind]
	var content := {}
	match kind:
		"good":
			for profile in GoodProfileRegistryScript.ordered():
				var good_entry := _content_entry(
					profile.id, profile.display_name,
					String(GoodProfileRegistryScript.icon_key(profile)),
					profile.technology_tags,
					bool(profile.trade_enabled) and String(profile.storage_mode) == "stock")
				good_entry["category_id"] = String(profile.get("category_id"))
				good_entry["storage_mode"] = String(profile.get("storage_mode"))
				content[String(profile.id)] = good_entry
		"profession":
			for profile in _load_profiles(EconomyCatalogScript.PROFESSION_DIR):
				var prof_entry := _content_entry(
					profile.id, profile.display_name,
					String(IconCatalog.profession_semantic(String(profile.id))),
					profile.technology_tags)
				prof_entry["profession_class_id"] = String(profile.get("profession_class_id"))
				prof_entry["entry_savings_days"] = int(profile.get("entry_savings_days"))
				prof_entry["state_service_only"] = bool(profile.get("state_service_only"))
				content[String(profile.id)] = prof_entry
		"building":
			for profile in _load_profiles(EconomyCatalogScript.BUILDING_DIR):
				var primary_good := String(profile.output_good_ids[0]) \
					if not profile.output_good_ids.is_empty() else ""
				var kind_code := 0 if profile.building_kind == "collector" \
					else (2 if profile.building_kind == "service" else 1)
				var entry := _content_entry(
					profile.id, profile.display_name,
					String(IconCatalog.building_semantic(
						String(profile.id), primary_good, kind_code)),
					profile.technology_tags, false, profile.required_technology_tags)
				entry["owner_profession_id"] = String(profile.owner_profession_id)
				entry["employee_profession_ids"] = profile.employee_profession_ids
				entry["industry_chain_id"] = String(profile.industry_chain_id)
				entry["progression_step"] = int(profile.progression_step)
				entry["maturity_display_name"] = String(profile.maturity_display_name)
				entry["progression_role"] = String(profile.progression_role)
				entry["predecessor_building_ids"] = profile.predecessor_building_ids
				entry["terminal_reason"] = String(profile.terminal_reason)
				entry["input_good_ids"] = profile.input_good_ids
				entry["output_good_ids"] = profile.output_good_ids
				entry["resource_ids"] = profile.resource_ids
				entry["has_location_conditions"] = not profile.condition_opcodes.is_empty()
				content[String(profile.id)] = entry
	_tax_content_cache[kind] = content
	return content


static func _content_entry(stable_id, display_name: String, icon_key: String,
		technology_tags: PackedStringArray, tradeable: bool = false,
		required_technology_tags: PackedStringArray = PackedStringArray()) -> Dictionary:
	var required: Array[String] = []
	for tag in technology_tags:
		var normalized := String(tag).strip_edges()
		if normalized.begins_with("tech."):
			required.append(normalized)
	var required_all: Array[String] = []
	for tag in required_technology_tags:
		var normalized := String(tag).strip_edges()
		if normalized.begins_with("tech."):
			required_all.append(normalized)
	var resolved_name := display_name.strip_edges()
	return {
		"display_name": resolved_name if resolved_name != "" else String(stable_id),
		"icon_key": icon_key,
		"tech_required": required,
		"tech_required_all": required_all,
		"tradeable": tradeable,
	}


static func _load_profiles(dir_path: String) -> Array:
	# [pk-export-remap] 见 economy_catalog.gd::_load_resources() 同名注释——导出
	# 包里 DirAccess 看到的是带 .remap 后缀的目录项，用 ResourceLoader.list_directory()
	# 才能拿到 x.tres 逻辑名。
	var paths := PackedStringArray()
	for file_name in ResourceLoader.list_directory(dir_path):
		if file_name.get_extension().to_lower() == "tres":
			paths.append("%s/%s" % [dir_path, file_name])
	paths.sort()
	var profiles: Array = []
	for path in paths:
		var resource = ResourceLoader.load(path, "Resource")
		if resource != null and String(resource.get("id")) != "":
			profiles.append(resource)
	profiles.sort_custom(func(a, b) -> bool: return String(a.id) < String(b.id))
	return profiles
