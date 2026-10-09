class_name CountryViewModel
extends RefCounted

const TechnologyCatalogScript = preload("res://scripts/economy/technology_catalog.gd")
const ResearchSignalCatalogScript = preload("res://scripts/research/research_signal_catalog.gd")
const GoodProfileRegistryScript = preload("res://scripts/data/good_profile_registry.gd")
const ResourceProfileRegistryScript = preload(
	"res://scripts/data/resource_profile_registry.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const DevelopmentAchievementCatalogScript = preload(
	"res://scripts/research/development_achievement_catalog.gd")

# Catalog content (display names, icons, technology requirements) is static for
# the whole session; the cache is built once so daily refreshes cost nothing.
static var _tax_content_cache: Dictionary = {}

var _generator = null
var _section_cache: Dictionary = {}
var _section_cache_revisions: Dictionary = {}
var _static_catalog_cache: Dictionary = {}


func set_context(generator) -> void:
	_generator = generator
	_section_cache.clear()
	_section_cache_revisions.clear()


func invalidate_cache(domains: int = -1) -> void:
	if domains < 0:
		_section_cache.clear()
		_section_cache_revisions.clear()
		return
	if (domains & 1) != 0:
		_section_cache.erase("technology")
		_section_cache_revisions.erase("technology")
	if (domains & 2) != 0:
		_section_cache.erase("economy")
		_section_cache_revisions.erase("economy")
	if (domains & 4) != 0:
		_section_cache.erase("ideology")
		_section_cache_revisions.erase("ideology")


func cached_section(section_id: String) -> Dictionary:
	return _section_cache.get(section_id, {})


func build_static_catalog() -> Dictionary:
	if _static_catalog_cache.is_empty():
		var technology_definitions := TechnologyCatalogScript.public_definitions()
		var lanes := TechnologyCatalogScript.public_lane_metadata()
		var application_definitions := _application_definitions(
			TechnologyCatalogScript.public_application_intersections(), lanes)
		var combined_definitions: Array = technology_definitions.duplicate(true)
		combined_definitions.append_array(application_definitions)
		var visual_edges: Array = TechnologyCatalogScript.public_visual_edges()
		visual_edges.append_array(
			TechnologyCatalogScript.public_application_visual_edges())
		_static_catalog_cache = {
			"technology_definitions": combined_definitions,
			"technology_research_definition_count": technology_definitions.size(),
			"technology_application_definitions": application_definitions,
			"technology_eras": TechnologyCatalogScript.public_era_metadata(),
			"technology_domains": TechnologyCatalogScript.public_domain_metadata(),
			"technology_visual_edges": visual_edges,
			"technology_lanes": lanes,
			"research_signal_definitions": ResearchSignalCatalogScript.public_metadata(),
		}
	return _static_catalog_cache


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


func player_completed_technology_ids() -> PackedStringArray:
	if _generator == null or not _generator.has_method("gameplay_start_report") \
			or not _generator.has_method("get_country_facade"):
		return PackedStringArray()
	var start_report: Dictionary = _generator.gameplay_start_report()
	var start_cell := int(start_report.get("cell", -1))
	var facade = _generator.get_country_facade()
	if not bool(start_report.get("ok", false)) or facade == null or start_cell < 0 \
			or not facade.has_method("snapshot"):
		return PackedStringArray()
	var summary: Dictionary = facade.cell_summary(start_cell)
	if not bool(summary.get("ok", false)) or not bool(summary.get("owned", false)):
		return PackedStringArray()
	var snapshot: Dictionary = facade.snapshot(int(summary.get("country_handle", 0)))
	if not bool(snapshot.get("ok", false)):
		return PackedStringArray()
	return snapshot.get("technology_ids", PackedStringArray())


# Lightweight player research states for HUD completion toasts. Avoids building the
# full technology workspace model when the country panel is closed.
func player_research_states() -> PackedInt32Array:
	var context := _country_context()
	if not bool(context.get("ok", false)):
		return PackedInt32Array()
	var facade = context.facade
	if facade == null or not facade.has_method("research_snapshot"):
		return PackedInt32Array()
	var research: Dictionary = facade.research_snapshot(int(context.country_handle))
	var states = research.get("technology_states", null)
	return states if states is PackedInt32Array else PackedInt32Array()


func _build_full_legacy(section_id: String = "technology") -> Dictionary:
	var normalized_section := section_id if section_id in [
		"technology", "economy", "ideology"] else "technology"
	if _section_cache.has(normalized_section):
		return _section_cache[normalized_section]
	# Keep the pre-snapshot path intentionally verbose for debug/A-B comparison.
	# It must not call the compact section bridge, otherwise the fallback would
	# measure the same query contract as the production event-driven path.
	var context := _country_context()
	if not bool(context.get("ok", false)):
		return _unavailable_model(String(context.get("reason", "国家档案暂不可用")))
	var facade = context.facade
	var economy_facade = _generator.get_economy_facade() \
		if _generator.has_method("get_economy_facade") else null
	var country_handle := int(context.country_handle)
	var start_cell := int(context.start_cell)
	var summary: Dictionary = context.summary
	var research: Dictionary = facade.research_snapshot(country_handle) \
		if facade.has_method("research_snapshot") else {}
	research["research_signal_snapshot"] = facade.research_signal_snapshot(
		country_handle) if facade.has_method("research_signal_snapshot") else {}
	var tax_policy: Dictionary = facade.tax_policy_snapshot(country_handle) \
		if facade.has_method("tax_policy_snapshot") else {}
	var fiscal: Dictionary = facade.fiscal_snapshot(country_handle) \
		if facade.has_method("fiscal_snapshot") else {}
	var trade_summary: Dictionary = economy_facade.country_trade_snapshot(
		country_handle, "summary", 0, 1) if economy_facade != null and \
		economy_facade.has_method("country_trade_snapshot") else {
			"ok": false, "reason": "country trade API unavailable"}
	var country_snapshot: Dictionary = facade.snapshot(country_handle) \
		if facade.has_method("snapshot") else {}
	var tax_availability := _tax_availability(economy_facade, start_cell)
	var ideology := _ideology_model(country_handle)
	var treasury := _treasury_model(facade, country_handle)
	var treasury_available := bool(treasury.get("available", false))
	var cash := int(treasury.get("cash", 0)) if treasury_available \
		else int(summary.get("cash", 0))
	research["country_cash"] = cash
	var development := _development_model(country_handle, research)
	var revision_components := {
		"country_state_version": int(summary.get("state_version", 0)),
		"country_generation": int(facade.report().get("generation", 0)),
	}
	var model := {
		"available": true,
		"country_name": String(summary.get("country_name", "未命名国家")),
		"country_id": String(summary.get("country_id", "")),
		"territory_count": int(summary.get("territory_count", 0)),
		"cash": cash,
		"nonzero_good_count": int(treasury.get("nonzero_good_count", 0)) \
			if treasury_available else int(summary.get("nonzero_good_count", 0)),
		"technology_count": int(summary.get("technology_count", 0)),
		"country_handle": country_handle,
		"country_state_version": int(summary.get("state_version", 0)),
		"country_generation": int(facade.report().get("generation", 0)),
		"revision": int(summary.get("state_version", 0)),
		"revision_components": revision_components,
		"economy_trade_revision": int(trade_summary.get("revision", 0)),
		"economy_class_opinion_revision": 0,
		"ideology_support_revision": int(ideology.get("snapshot", {}).get(
			"support_revision", 0)),
		"country_facade": facade,
		"treasury": treasury,
		"tax_policy": tax_policy,
		"tax_presentation": present_tax_policy(tax_policy,
			country_snapshot.get("technology_ids", PackedStringArray()),
			tax_availability),
		"fiscal": fiscal,
		"trade_summary": trade_summary,
		"economy_facade": economy_facade,
		"current_day": int(facade.report().get("last_committed_day", -1)),
		"research": research,
		"development": development,
		"ideology": ideology,
	}
	if normalized_section == "technology":
		model.merge(build_static_catalog(), true)
	_section_cache[normalized_section] = model
	_section_cache_revisions[normalized_section] = revision_components
	return model


func build_legacy(section_id: String = "technology") -> Dictionary:
	# Explicit A/B/debug entry point. Production event-driven callers use build().
	return _build_full_legacy(section_id)


func _country_context() -> Dictionary:
	if _generator == null or not _generator.has_method("gameplay_start_report") \
			or not _generator.has_method("get_country_facade"):
		return {"ok": false, "reason": "国家档案尚未就绪"}
	var start_report: Dictionary = _generator.gameplay_start_report()
	var start_cell := int(start_report.get("cell", -1))
	var facade = _generator.get_country_facade()
	if not bool(start_report.get("ok", false)) or facade == null or start_cell < 0:
		return {"ok": false, "reason": "当前会话没有可用的玩家国家"}
	var summary: Dictionary = facade.cell_summary(start_cell)
	if not bool(summary.get("ok", false)) or not bool(summary.get("owned", false)):
		return {"ok": false, "reason": "玩家国家档案暂不可用"}
	return {
		"ok": true,
		"start_cell": start_cell,
		"facade": facade,
		"summary": summary,
		"country_handle": int(summary.get("country_handle", 0)),
	}


func _section_mask(section_id: String) -> int:
	return int({"technology": 1, "economy": 2, "ideology": 4}.get(section_id, 1))


func build_summary_snapshot(country_handle: int, summary: Dictionary,
		ui_snapshot: Dictionary = {}) -> Dictionary:
	var shell: Dictionary = ui_snapshot.get("summary", summary) \
		if bool(ui_snapshot.get("ok", false)) else summary
	var revision_components: Dictionary = ui_snapshot.get(
		"revision_components", {}).duplicate(false)
	var published_day := int(ui_snapshot.get("published_day", -1))
	if published_day < 0 and _generator != null and \
			_generator.has_method("get_country_facade"):
		var facade = _generator.get_country_facade()
		if facade != null and facade.has_method("report"):
			published_day = int(facade.report().get("last_committed_day", -1))
	return {
		"available": true,
		"country_name": String(shell.get("country_name", "未命名国家")),
		"country_id": String(shell.get("country_id", "")),
		"territory_count": int(shell.get("territory_count", 0)),
		"technology_count": int(shell.get("technology_count", 0)),
		"country_handle": country_handle,
		"country_state_version": int(ui_snapshot.get("country_state_version", 0)),
		"country_generation": int(ui_snapshot.get("country_generation", 0)),
		"revision": int(ui_snapshot.get("revision",
			ui_snapshot.get("country_state_version", 0))),
		"revision_components": revision_components,
		"economy_trade_revision": int(ui_snapshot.get(
			"economy_trade_revision", 0)),
		"economy_class_opinion_revision": int(ui_snapshot.get(
			"economy_class_opinion_revision", 0)),
		"ideology_support_revision": int(ui_snapshot.get(
			"ideology_support_revision", 0)),
		"current_day": published_day,
	}


func build_technology_snapshot(country_handle: int, facade,
		ui_snapshot: Dictionary) -> Dictionary:
	var compact_ok := bool(ui_snapshot.get("ok", false))
	var compact_research = ui_snapshot.get("research", null) if compact_ok else null
	var compact_states = compact_research.get("technology_states", null) \
		if compact_research is Dictionary else null
	var compact_research_ok: bool = compact_research is Dictionary \
		and (not compact_research.has("ok") or bool(compact_research.get("ok", false))) \
		and compact_states is PackedInt32Array and not (compact_states as PackedInt32Array).is_empty()
	var research: Dictionary = compact_research if compact_research_ok \
		else (facade.research_snapshot(country_handle) \
		if facade != null and facade.has_method("research_snapshot") else {})
	var compact_signals = ui_snapshot.get("research_signals", null) if compact_ok else null
	var signals_ok: bool = compact_signals is Dictionary \
		and (not compact_signals.has("ok") or bool(compact_signals.get("ok", false)))
	research["research_signal_snapshot"] = compact_signals if signals_ok \
		else (facade.research_signal_snapshot(country_handle) \
		if facade != null and facade.has_method("research_signal_snapshot") else {})
	return {
		"research": research,
		"development": _development_model(country_handle, research),
	}


func build_economy_snapshot(country_handle: int, facade, economy_facade,
		ui_snapshot: Dictionary, start_cell: int) -> Dictionary:
	var compact_ok := bool(ui_snapshot.get("ok", false))
	var tax_policy: Dictionary = ui_snapshot.get("tax_policy", {}) if compact_ok \
		else (facade.tax_policy_snapshot(country_handle) \
		if facade != null and facade.has_method("tax_policy_snapshot") else {})
	var fiscal: Dictionary = ui_snapshot.get("fiscal", {}) if compact_ok \
		else (facade.fiscal_snapshot(country_handle) \
		if facade != null and facade.has_method("fiscal_snapshot") else {})
	var trade_summary: Dictionary = ui_snapshot.get("trade_summary", {}) if compact_ok \
		else (economy_facade.country_trade_snapshot(country_handle, "summary", 0, 1) \
		if economy_facade != null and economy_facade.has_method(
			"country_trade_snapshot") else {"ok": false,
			"reason": "country trade API unavailable"})
	var country_snapshot: Dictionary = ui_snapshot.get("country_snapshot", {}) if compact_ok \
		else (facade.snapshot(country_handle) \
		if facade != null and facade.has_method("snapshot") else {})
	var tax_availability := _tax_availability(economy_facade, start_cell)
	var treasury: Dictionary = present_treasury(ui_snapshot.get("treasury", {})) \
		if compact_ok else _treasury_model(facade, country_handle)
	return {
		"treasury": treasury,
		"tax_policy": tax_policy,
		"tax_presentation": present_tax_policy(tax_policy,
			country_snapshot.get("technology_ids", PackedStringArray()),
			tax_availability),
		"fiscal": fiscal,
		"trade_summary": trade_summary,
	}


func build_ideology_snapshot(country_handle: int, ui_snapshot: Dictionary) -> Dictionary:
	var native_ideology: Dictionary = ui_snapshot.get("ideology", {})
	var ideology_facade = _generator.get_ideology_facade() \
		if _generator != null and _generator.has_method("get_ideology_facade") else null
	if bool(native_ideology.get("ok", false)) and ideology_facade != null:
		return {
			"ideology": _decorate_ideology({
				"available": true,
				"facade": ideology_facade,
				"snapshot": native_ideology,
				"catalog": ideology_facade.catalog_view(),
			}),
		}
	return {"ideology": _ideology_model(country_handle)}


func build(section_id: String = "technology") -> Dictionary:
	var normalized_section := section_id if section_id in [
		"technology", "economy", "ideology"] else "technology"
	if _section_cache.has(normalized_section):
		return _section_cache[normalized_section]
	var context := _country_context()
	if not bool(context.get("ok", false)):
		return _unavailable_model(String(context.get("reason", "国家档案暂不可用")))
	var facade = context.facade
	var country_handle := int(context.country_handle)
	var ui_snapshot: Dictionary = facade.ui_snapshot(country_handle,
		_section_mask(normalized_section)) if facade.has_method("ui_snapshot") else {}
	var summary_snapshot := build_summary_snapshot(country_handle,
		context.summary, ui_snapshot)
	var economy_facade = _generator.get_economy_facade() \
		if _generator.has_method("get_economy_facade") else null
	var section_snapshot: Dictionary = {}
	match normalized_section:
		"technology":
			section_snapshot = build_technology_snapshot(country_handle, facade, ui_snapshot)
		"economy":
			section_snapshot = build_economy_snapshot(country_handle, facade,
				economy_facade, ui_snapshot, int(context.start_cell))
		"ideology":
			section_snapshot = build_ideology_snapshot(country_handle, ui_snapshot)
	var treasury: Dictionary = section_snapshot.get("treasury", {})
	var treasury_available := bool(treasury.get("available", false))
	var cash := int(treasury.get("cash", 0)) if treasury_available \
		else int(context.summary.get("cash", 0))
	var model := summary_snapshot.duplicate(false)
	model["cash"] = cash
	model["nonzero_good_count"] = int(treasury.get("nonzero_good_count", 0)) \
		if treasury_available else int(context.summary.get("nonzero_good_count", 0))
	model["country_facade"] = facade
	model["economy_facade"] = economy_facade
	model.merge(section_snapshot, true)
	if normalized_section == "technology":
		var research: Dictionary = model.get("research", {})
		research["country_cash"] = cash
		model["research"] = research
		model.merge(build_static_catalog(), true)
	_section_cache[normalized_section] = model
	_section_cache_revisions[normalized_section] = model.get(
		"revision_components", {}).duplicate(false)
	return model


func _tax_availability(economy_facade, cell: int) -> Dictionary:
	var availability := {}
	if economy_facade == null or cell < 0:
		return availability

	if economy_facade.has_method("market_cell_snapshot"):
		var market: Dictionary = economy_facade.market_cell_snapshot(cell)
		var good_ids: PackedStringArray = market.get("good_ids", PackedStringArray())
		var good_available: PackedByteArray = market.get(
			"good_technology_available", PackedByteArray())
		if bool(market.get("ok", false)) and good_ids.size() == good_available.size():
			var goods := {}
			for index in range(good_ids.size()):
				if good_available[index] != 0:
					goods[String(good_ids[index])] = true
			availability["good"] = goods

	if economy_facade.has_method("building_cell_snapshot"):
		var buildings: Dictionary = economy_facade.building_cell_snapshot(cell)
		var building_ids: PackedStringArray = buildings.get(
			"building_type_ids", PackedStringArray())
		var building_available: PackedByteArray = buildings.get(
			"building_technology_available", PackedByteArray())
		if bool(buildings.get("ok", false)) \
				and building_ids.size() == building_available.size():
			var building_filter := {}
			for index in range(building_ids.size()):
				if building_available[index] != 0:
					building_filter[String(building_ids[index])] = true
			availability["building"] = building_filter

	var professions := {}
	var population_valid := false
	if economy_facade.has_method("population_cell_snapshot"):
		var population: Dictionary = economy_facade.population_cell_snapshot(cell)
		var population_profession_ids: PackedInt32Array = population.get(
			"profession_ids", PackedInt32Array())
		var profession_stable_ids: PackedStringArray = population.get(
			"profession_stable_ids", PackedStringArray())
		# An empty profession row set is still an authoritative snapshot: it means
		# this cell currently has no cohorts, not that the population query failed.
		population_valid = bool(population.get("ok", false)) \
				and not profession_stable_ids.is_empty()
		if population_valid:
			for profession_index in population_profession_ids:
				if profession_index >= 0 and profession_index < profession_stable_ids.size():
					professions[String(profession_stable_ids[profession_index])] = true

	# A profession is tax-relevant once it exists in the country or is a role of
	# a building whose complete native technology/dependency gate is open.
	if availability.has("building"):
		var building_content := _tax_content("building")
		for raw_building_id in (availability["building"] as Dictionary).keys():
			var building_item: Dictionary = building_content.get(String(raw_building_id), {})
			if building_item.is_empty():
				continue
			var owner_profession := String(building_item.get("owner_profession_id", ""))
			if not owner_profession.is_empty():
				professions[owner_profession] = true
			var employee_professions: PackedStringArray = building_item.get(
				"employee_profession_ids", PackedStringArray())
			for profession_id in employee_professions:
				professions[String(profession_id)] = true
	if population_valid or availability.has("building"):
		availability["profession"] = professions
	return availability


func _development_model(country_handle: int, research: Dictionary) -> Dictionary:
	const era_ids := DevelopmentAchievementCatalogScript.ERA_IDS
	var definitions: Array[Dictionary] = DevelopmentAchievementCatalogScript.definitions()
	var states: PackedInt32Array = research.get("technology_states", PackedInt32Array())
	var technology_definitions: Array = TechnologyCatalogScript.public_definitions()
	var highest_era := 0
	for index in range(mini(states.size(), technology_definitions.size())):
		if int(states[index]) <= 0:
			continue
		var era_index := era_ids.find(String((technology_definitions[index] as Dictionary).get("era_id", "")))
		if era_index >= 0:
			highest_era = maxi(highest_era, era_index)
	var progress_by_signal := {}
	var trigger = _generator.get_trigger_facade() \
		if _generator != null and _generator.has_method("get_trigger_facade") else null
	if trigger != null and trigger.has_method("development_progress"):
		for era_index in range(highest_era + 1):
			var raw: Dictionary = trigger.development_progress(country_handle, String(era_ids[era_index]))
			if not bool(raw.get("ok", false)):
				continue
			var metric_ids: PackedInt32Array = raw.get("metric_ids", PackedInt32Array())
			var values: PackedInt64Array = raw.get("current_values", PackedInt64Array())
			var qualifiers: PackedInt64Array = raw.get("qualifier_thresholds", PackedInt64Array())
			var consecutive: PackedInt64Array = raw.get("consecutive_days", PackedInt64Array())
			var target_days: PackedInt32Array = raw.get("target_days", PackedInt32Array())
			var completed: PackedInt32Array = raw.get("completed", PackedInt32Array())
			for cursor in range(metric_ids.size()):
				var metric_index := int(metric_ids[cursor])
				if metric_index < 0 or metric_index >= definitions.size():
					continue
				var definition: Dictionary = definitions[metric_index]
				progress_by_signal[String(definition.get("signal_id", ""))] = {
					"metric_id": metric_index,
					"current_value": int(values[cursor]) if cursor < values.size() else 0,
					"qualifier_threshold": int(qualifiers[cursor]) if cursor < qualifiers.size() else int(definition.get("qualifier_threshold", 0)),
					"consecutive_days": int(consecutive[cursor]) if cursor < consecutive.size() else 0,
					"target_days": int(target_days[cursor]) if cursor < target_days.size() else int(definition.get("duration_days", 1)),
					"completed": int(completed[cursor]) if cursor < completed.size() else 0,
				}
	# A completed permanent signal remains explainable even if its Trigger state
	# has been compacted or the cold query is temporarily unavailable.
	var signal_snapshot: Dictionary = research.get("research_signal_snapshot", {})
	var signal_ids: PackedInt32Array = signal_snapshot.get("signal_ids", PackedInt32Array())
	var signal_metadata: Array = ResearchSignalCatalogScript.public_metadata()
	for signal_index in signal_ids:
		if signal_index < 0 or signal_index >= signal_metadata.size():
			continue
		var signal_id := String((signal_metadata[signal_index] as Dictionary).get("id", ""))
		if signal_id.begins_with("development.") and not progress_by_signal.has(signal_id):
			progress_by_signal[signal_id] = {"completed": 1}
	var era_id := String(era_ids[highest_era])
	var objectives: Array[Dictionary] = []
	for definition in definitions:
		if String(definition.get("era_id", "")) == era_id:
			objectives.append(definition.duplicate(true))
	return {
		"ok": true,
		"era_id": era_id,
		"era_index": highest_era,
		"objectives": objectives,
		"progress_by_signal": progress_by_signal,
	}


func _ideology_model(country_handle: int) -> Dictionary:
	if _generator == null or not _generator.has_method("get_ideology_facade"):
		return {"available": false, "reason": "理念事务暂不可用。"}
	var facade = _generator.get_ideology_facade()
	if facade == null or not facade.has_method("is_configured") or not facade.is_configured():
		return {"available": false, "reason": "理念事务尚未就绪。"}
	var snapshot: Dictionary = facade.snapshot(country_handle)
	var catalog: Dictionary = facade.catalog_view()
	if not bool(snapshot.get("ok", false)) or not bool(catalog.get("ok", false)):
		return {"available": false, "reason": ideology_player_reason(String(snapshot.get("reason",
			catalog.get("reason", "理念档案暂不可用。"))))}
	return _decorate_ideology({
		"available": true, "facade": facade, "snapshot": snapshot, "catalog": catalog,
	})


func _decorate_ideology(ideology: Dictionary) -> Dictionary:
	var presentation := present_ideology(
		ideology.get("snapshot", {}), ideology.get("catalog", {}))
	ideology["presentation"] = presentation
	return ideology


static func present_ideology(snapshot: Dictionary, catalog: Dictionary) -> Dictionary:
	var catalog_capacity := int(catalog.get("ideology_capacity", 0))
	var catalog_spirits := int(catalog.get("national_spirit_capacity", 0))
	var catalog_cost := int(catalog.get("offer_cost_q16", 65536))
	var catalog_start := int(catalog.get("starting_points_q16", 0))
	var materialized := bool(snapshot.get("materialized",
		snapshot.has("ideology_slots_capacity")))
	var slots_capacity := int(snapshot.get("ideology_slots_capacity", catalog_capacity))
	var spirit_capacity := int(snapshot.get("national_spirit_slots_capacity", catalog_spirits))
	var offer_cost := int(snapshot.get("offer_cost_q16", catalog_cost))
	var points := int(snapshot.get("ideology_points_q16", 0))
	if not materialized:
		slots_capacity = catalog_capacity if slots_capacity <= 0 else slots_capacity
		spirit_capacity = catalog_spirits if spirit_capacity <= 0 else spirit_capacity
		if not snapshot.has("ideology_points_q16") or points <= 0:
			points = int(snapshot.get("starting_points_q16", catalog_start))
	var offer_active := bool(snapshot.get("offer_active", false))
	var known: PackedInt32Array = snapshot.get("known_ids", PackedInt32Array())
	var can_open_offer := not offer_active and points >= offer_cost
	var offer_hint := "抽取一次，从三条道路中选择其一。"
	if offer_active:
		offer_hint = "三选一已打开，请选择一条道路。"
	elif points < offer_cost:
		offer_hint = "抽取需 %s 理念点。" % _q16_display(offer_cost)
	var empty_insights: Array = [
		{
			"icon": &"country.politics",
			"accent": UITokens.ACCENT,
			"text": "消耗理念点抽取三选一，选定后进入国家收藏。",
		},
		{
			"icon": &"country.economy",
			"accent": UITokens.RESOURCE,
			"text": "每条道路改变不同的产出、贸易、研究或建设系数。",
		},
		{
			"icon": &"country.affairs",
			"accent": UITokens.BRASS_HIGHLIGHT,
			"text": "装备占用意识形态槽；理解度积累后可晋升为民族精神。",
		},
		{
			"icon": &"country.economy",
			"accent": UITokens.RESOURCE,
			"text": "阶层民意决定能否推行、废止或晋升一条理念。",
		},
	]
	return {
		"points": points,
		"points_text": _q16_display(points),
		"slots_used": int(snapshot.get("ideology_slots_used", 0)),
		"slots_capacity": slots_capacity,
		"spirits_used": int(snapshot.get("national_spirit_slots_used", 0)),
		"spirits_capacity": spirit_capacity,
		"offer_cost_q16": offer_cost,
		"offer_cost_text": _q16_display(offer_cost),
		"offer_active": offer_active,
		"can_open_offer": can_open_offer,
		"offer_hint": offer_hint,
		"known_count": known.size(),
		"empty": known.is_empty() and not offer_active,
		"empty_title": "尚未形成国家理念",
		"empty_detail": "内阁还没有选定一条可推行的道路。",
		"empty_insights": empty_insights,
	}


static func present_ideology_card(metadata: Dictionary, level: int = 0) -> Dictionary:
	var effect_sets: Array = metadata.get("level_effect_lines", [])
	var current_lines := PackedStringArray()
	if level >= 0 and level < effect_sets.size():
		current_lines = PackedStringArray(effect_sets[level])
	elif not effect_sets.is_empty():
		current_lines = PackedStringArray(effect_sets[0])
	var insight_items: Array = []
	var icon := String(metadata.get("icon_key", "country.politics"))
	for line in current_lines:
		var text := String(line).strip_edges()
		if text.is_empty():
			continue
		insight_items.append({
			"text": text,
			"icon": icon,
			"accent": UITokens.RESOURCE,
		})
	var badges: Array = []
	var rivals: PackedStringArray = metadata.get("exclusion_rivals", PackedStringArray())
	if not rivals.is_empty():
		badges.append({
			"text": "与%s互斥" % "、".join(rivals),
			"accent": UITokens.WARN,
			"tooltip": "同一经济秩序不能同时推行这些道路。",
		})
	if effect_sets.size() >= 2 and level + 1 < effect_sets.size():
		var high := PackedStringArray(effect_sets[level + 1])
		if not high.is_empty():
			badges.append({
				"text": "满级效果翻倍",
				"accent": UITokens.BRASS_HIGHLIGHT,
				"tooltip": "、".join(high),
			})
	var synergy_names: PackedStringArray = metadata.get("synergy_names", PackedStringArray())
	if not synergy_names.is_empty():
		badges.append({
			"text": "联动 %s" % "、".join(synergy_names),
			"accent": UITokens.CLIMATE,
			"tooltip": String(metadata.get("synergy_tooltip", "")),
		})
	return {
		"display_name": String(metadata.get("display_name",
			metadata.get("name_key", ""))),
		"detail": String(metadata.get("detail_key", "")),
		"icon_key": icon,
		"effects": insight_items,
		"badges": badges,
		"summary": "、".join(current_lines),
	}


static func _q16_display(value: int) -> String:
	return "%.2f" % (float(value) / 65536.0)


static func ideology_player_reason(reason: String) -> String:
	match reason:
		"ideology_points_insufficient":
			return "理念点不足。"
		"ideology_offer_pending":
			return "已有一次三选一待选择。"
		"ideology_offer_pool_insufficient":
			return "当前可抽取的理念不足三次。"
		"ideology_offer_weight_invalid":
			return "当前没有可抽取的理念。"
		"ideology_runtime_unconfigured", "ideology_runtime_unavailable", \
				"DCWorldExt ideology API unavailable":
			return "理念事务暂不可用。"
		"ideology_country_handle_stale", "ideology_country_state_unavailable":
			return "国家档案已更新，请稍后重试。"
		"正在载入已提交数据":
			return "正在整理内阁档案。"
		_:
			return reason if not reason.is_empty() else "理念事务暂不可用。"


func _treasury_model(facade, country_handle: int) -> Dictionary:
	if facade == null or not facade.has_method("treasury_snapshot"):
		return _unavailable_treasury("国家国库查询暂不可用")
	return present_treasury(facade.treasury_snapshot(country_handle))


static func present_treasury(snapshot: Dictionary) -> Dictionary:
	if not bool(snapshot.get("ok", false)):
		return _unavailable_treasury_static(
			String(snapshot.get("reason", "国家国库快照暂不可用")))
	var good_ids: PackedStringArray = snapshot.get("good_ids", PackedStringArray())
	var quantities: PackedInt64Array = snapshot.get("quantities", PackedInt64Array())
	if good_ids.size() != quantities.size():
		return _unavailable_treasury_static("国家国库物资数据不完整")
	var goods: Array[Dictionary] = []
	for index in range(good_ids.size()):
		var stable_id := String(good_ids[index])
		var quantity := int(quantities[index])
		if quantity == 0:
			continue
		var profile = GoodProfileRegistryScript.profile_by_id(stable_id)
		var display_name := String(profile.display_name) \
			if profile != null and not String(profile.display_name).is_empty() else stable_id
		goods.append({
			"id": stable_id,
			"display_name": display_name,
			"icon": String(GoodProfileRegistryScript.icon_key(stable_id)),
			"quantity": quantity,
			"quantity_text": UITokens.format_compact_number_cn(float(quantity) / 1000.0, 3),
			"virtual": profile != null and String(profile.get("category_id")) == "knowledge",
		})
	# Native snapshot order is catalog order, so a fixed good (e.g. 科技值) would
	# otherwise pin the first slot forever; real stock first by quantity, virtual
	# knowledge goods last.
	goods.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var a_virtual := bool(a.get("virtual", false))
		var b_virtual := bool(b.get("virtual", false))
		if a_virtual != b_virtual:
			return b_virtual
		if int(a.get("quantity", 0)) != int(b.get("quantity", 0)):
			return int(a.get("quantity", 0)) > int(b.get("quantity", 0))
		return String(a.get("display_name", "")) < String(b.get("display_name", "")))
	var cash := int(snapshot.get("cash", 0))
	return {
		"available": true,
		"cash": cash,
		"cash_text": UITokens.format_compact_number_cn(float(cash) / 10000.0, 2),
		"nonzero_good_count": goods.size(),
		"goods": goods,
	}


# Tax pages list only content available to the country at the selected starting
# cell.  The native economy masks include dependency branches that static
# profile tags cannot express; completed technologies remain the deterministic
# fallback for callers that present a standalone policy dictionary.
static func present_tax_policy(tax_policy: Dictionary, completed_technologies,
		availability: Dictionary = {}) -> Dictionary:
	return _present_tax_policy(tax_policy, completed_technologies, availability)


static func _present_tax_policy(tax_policy: Dictionary, completed_technologies,
		availability: Dictionary) -> Dictionary:
	if not bool(tax_policy.get("ok", false)):
		return {"ok": false}
	var completed := {}
	for tech_id in completed_technologies:
		completed[String(tech_id)] = true
	var profession_filter: Dictionary = availability.get("profession", {})
	var good_filter: Dictionary = availability.get("good", {})
	var building_filter: Dictionary = availability.get("building", {})
	var professions := _present_items(
		tax_policy.get("profession_ids", PackedStringArray()), "profession", completed,
		false, false, profession_filter, availability.has("profession"))
	var goods := _present_items(
		tax_policy.get("good_ids", PackedStringArray()), "good", completed,
		false, false, good_filter, availability.has("good"))
	var tariff_goods := _present_items(
		tax_policy.get("good_ids", PackedStringArray()), "good", completed,
		true, true)
	var buildings := _present_items(
			tax_policy.get("building_type_ids", PackedStringArray()), "building", completed,
		false, false, building_filter, availability.has("building"))
	return {
		"ok": true,
		"income": professions,
		"consumption": goods,
		"import": tariff_goods,
		"export": tariff_goods,
		"business": buildings,
		"default_assessment_modes": tax_policy.get(
			"default_assessment_modes", PackedInt32Array()),
		"absolute_amounts": tax_policy.get("absolute_amounts", {}),
	}


static func _present_items(ids: PackedStringArray, kind: String,
		completed: Dictionary, allow_tradeable: bool = false,
		tradeable_only: bool = false, available_ids: Dictionary = {},
		enforce_available: bool = false) -> Dictionary:
	var content := _tax_content(kind)
	var unlocked: Array[Dictionary] = []
	for raw_id in ids:
		var stable_id := String(raw_id)
		var item: Dictionary = content.get(stable_id, {})
		if item.is_empty():
			continue
		if enforce_available and not available_ids.has(stable_id):
			continue
		if tradeable_only and not bool(item.get("tradeable", false)):
			continue
		var locked := false
		var direct_requirements: Array = item.get("tech_required", [])
		if not direct_requirements.is_empty():
			var direct_ready := false
			for tech_id in direct_requirements:
				if completed.has(String(tech_id)):
					direct_ready = true
					break
			locked = not direct_ready
		if not locked:
			for tech_id in item.get("tech_required_all", []):
				if not completed.has(String(tech_id)):
					locked = true
					break
		if locked and not (allow_tradeable and bool(item.get("tradeable", false))):
			continue
		unlocked.append({
			"id": stable_id,
			"display_name": String(item.get("display_name", stable_id)),
			"icon_key": String(item.get("icon_key", "")),
		})
	return {"unlocked": unlocked, "total_count": ids.size()}


static func _tax_content(kind: String) -> Dictionary:
	if _tax_content_cache.has(kind):
		return _tax_content_cache[kind]
	var content := {}
	match kind:
		"good":
			for profile in GoodProfileRegistryScript.ordered():
				content[String(profile.id)] = _content_entry(
					profile.id, profile.display_name,
					String(GoodProfileRegistryScript.icon_key(profile)),
					profile.technology_tags,
					bool(profile.trade_enabled) and String(profile.storage_mode) == "stock")
		"profession":
			for profile in _load_profiles(EconomyCatalogScript.PROFESSION_DIR):
				content[String(profile.id)] = _content_entry(
					profile.id, profile.display_name,
					String(IconCatalog.profession_semantic(String(profile.id))),
					profile.technology_tags)
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


func _unavailable_treasury(reason: String) -> Dictionary:
	return _unavailable_treasury_static(reason)


static func _unavailable_treasury_static(reason: String) -> Dictionary:
	return {
		"available": false,
		"reason": reason,
		"cash": 0,
		"cash_text": "—",
		"nonzero_good_count": 0,
		"goods": [],
	}


func _unavailable_model(reason: String) -> Dictionary:
	return {
		"available": false,
		"country_name": "国家事务",
		"reason": reason,
		"territory_count": 0,
		"cash": 0,
		"nonzero_good_count": 0,
		"technology_count": 0,
		"treasury": _unavailable_treasury(reason),
	}
