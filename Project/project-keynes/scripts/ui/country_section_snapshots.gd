extends RefCounted

## Builds the country dossier's section snapshots.


static func build_summary_snapshot(owner: CountryViewModel, country_handle: int, summary: Dictionary,
		ui_snapshot: Dictionary = {}) -> Dictionary:
	var shell: Dictionary = ui_snapshot.get("summary", summary) \
		if bool(ui_snapshot.get("ok", false)) else summary
	var revision_components: Dictionary = ui_snapshot.get(
		"revision_components", {}).duplicate(false)
	var published_day := int(ui_snapshot.get("published_day", -1))
	if published_day < 0 and owner._generator != null and \
			owner._generator.has_method("get_country_facade"):
		var facade = owner._generator.get_country_facade()
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



static func build_technology_snapshot(owner: CountryViewModel, country_handle: int, facade,
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
		"development": owner._development_model(country_handle, research),
	}



static func build_economy_snapshot(owner: CountryViewModel, country_handle: int, facade, economy_facade,
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
	var tax_availability := owner._tax_availability(economy_facade, start_cell)
	var treasury: Dictionary = CountryViewModel.present_treasury(ui_snapshot.get("treasury", {})) \
		if compact_ok else owner._treasury_model(facade, country_handle)
	return {
		"treasury": treasury,
		"tax_policy": tax_policy,
		"tax_presentation": CountryViewModel.present_tax_policy(tax_policy,
			country_snapshot.get("technology_ids", PackedStringArray()),
			tax_availability),
		"fiscal": fiscal,
		"trade_summary": trade_summary,
	}



static func build_ideology_snapshot(owner: CountryViewModel, country_handle: int, ui_snapshot: Dictionary) -> Dictionary:
	var native_ideology: Dictionary = ui_snapshot.get("ideology", {})
	var ideology_facade = owner._generator.get_ideology_facade() \
		if owner._generator != null and owner._generator.has_method("get_ideology_facade") else null
	if bool(native_ideology.get("ok", false)) and ideology_facade != null:
		if ideology_facade != owner._ideology_catalog_facade:
			owner._ideology_catalog_facade = ideology_facade
			owner._ideology_catalog_cache = {}
		var ideology_catalog := owner._ideology_catalog_cache
		if ideology_catalog.is_empty():
			ideology_catalog = ideology_facade.catalog_view()
			if bool(ideology_catalog.get("ok", false)):
				owner._ideology_catalog_cache = ideology_catalog
		return {
			"ideology": owner._decorate_ideology({
				"available": true,
				"facade": ideology_facade,
				"snapshot": native_ideology,
				"catalog": ideology_catalog,
			}, country_handle),
		}
	return {"ideology": owner._ideology_model(country_handle)}



static func build_politics_snapshot(owner: CountryViewModel, country_handle: int, ui_snapshot: Dictionary) -> Dictionary:
	var ideology := owner.build_ideology_snapshot(country_handle, ui_snapshot)
	var country_facade = owner._generator.get_country_facade() \
		if owner._generator != null and owner._generator.has_method("get_country_facade") else null
	var native: Dictionary = ui_snapshot.get("politics", {})
	if native.is_empty() and country_facade != null and \
		country_facade.has_method("political_regime_snapshot"):
		native = country_facade.political_regime_snapshot(country_handle)
	var catalog := owner._political_regime_catalog_cache
	if country_facade != null and country_facade != owner._political_regime_catalog_facade:
		owner._political_regime_catalog_facade = country_facade
		owner._political_regime_catalog_cache = {}
		catalog = {}
	if catalog.is_empty() and country_facade != null and \
		country_facade.has_method("political_regime_catalog_view"):
		catalog = country_facade.political_regime_catalog_view()
		if bool(catalog.get("ok", false)):
			owner._political_regime_catalog_cache = catalog
	var regime := CountryViewModel._present_political_regime(native, catalog,
		owner._present_profession_ids(country_handle))
	return {
		"politics": {"available": bool(regime.get("available", false)),
			"regime": regime, "ideology": ideology.get("ideology", {})},
		# Existing IdeologyWorkspace consumes this top-level row. Keeping the
		# child payload here avoids rebuilding or duplicating the ideology UI.
		"ideology": ideology.get("ideology", {}),
	}


## 本国当前实际存在的职业（有人口队列）。读不到时返回 null，调用方不做过滤。
static func _present_profession_ids(owner: CountryViewModel, country_handle: int):
	var economy = owner._generator.get_economy_facade() \
		if owner._generator != null and owner._generator.has_method("get_economy_facade") else null
	if economy == null or not economy.has_method("country_economy_overview"):
		return null
	var page: Dictionary = economy.country_economy_overview(country_handle, "professions")
	if not bool(page.get("ok", false)):
		return null
	var present := {}
	var ids: PackedStringArray = page.get("profession_stable_ids", PackedStringArray())
	var population: PackedInt64Array = page.get("population", PackedInt64Array())
	for i in range(ids.size()):
		if i >= population.size() or int(population[i]) > 0:
			present[String(ids[i])] = true
	return present



static func _present_political_regime(snapshot: Dictionary,
		catalog: Dictionary, present_professions = null) -> Dictionary:
	if not bool(catalog.get("ok", false)):
		return {"available": false, "reason": "体制目录尚未就绪。"}
	var definitions: Array = RegimePresenter.enrich(catalog.get("definitions", []),
		present_professions)
	var raw_regime_key = snapshot.get("regime_key",
		snapshot.get("regime_stable_id", ""))
	var regime_id := String(raw_regime_key)
	if regime_id.is_empty() or raw_regime_key is int:
		var dense := int(snapshot.get("regime_index", snapshot.get("regime_id_index", -1)))
		if dense >= 0 and dense < definitions.size():
			regime_id = String((definitions[dense] as Dictionary).get("id", ""))
	if regime_id.is_empty():
		regime_id = "local_council"
	var current: Dictionary = {}
	for raw_definition in definitions:
		var definition: Dictionary = raw_definition
		if String(definition.get("id", "")) == regime_id:
			current = definition.duplicate(true)
			break
	if current.is_empty():
		return {"available": false, "reason": "当前体制不在本局目录中。"}
	var capability_keys := PackedStringArray(current.get("capability_keys", PackedStringArray()))
	var capability_bits := int(snapshot.get("capability_bits", 0))
	var can_build := capability_keys.has("treasury_construction") \
		or (capability_bits & 1) != 0
	var current_capabilities: Array = []
	if can_build:
		current_capabilities.append({"label": "国库建造"})
	var gates := {}
	for raw_definition in definitions:
		var definition: Dictionary = raw_definition
		var id := String(definition.get("id", ""))
		var keys := PackedStringArray(definition.get("capability_keys", PackedStringArray()))
		var has_build := keys.has("treasury_construction")
		if id == regime_id and capability_bits != 0:
			has_build = (capability_bits & 1) != 0
		gates[id] = {"treasury_construction": has_build}
	return {
		"available": true,
		"regime_id": regime_id,
		"display_name": String(current.get("display_name", regime_id)),
		"detail": String(current.get("detail", "")),
		"icon_key": current.get("icon_key", &"country.politics"),
		"capability_keys": capability_keys,
		"capability_bits": capability_bits,
		"can_treasury_construction": can_build,
		"current_id": regime_id,
		"current_name": String(current.get("display_name", regime_id)),
		"current_detail": String(current.get("detail", "")),
		"current_capabilities": current_capabilities,
		"options": definitions,
		"definitions": definitions,
		"feature_gates": gates,
		"revision": int(snapshot.get("revision", snapshot.get("state_version", 0))),
	}
