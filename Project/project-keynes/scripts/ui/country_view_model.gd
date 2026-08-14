class_name CountryViewModel
extends RefCounted

const TechnologyCatalogScript = preload("res://scripts/economy/technology_catalog.gd")
const ResearchSignalCatalogScript = preload("res://scripts/research/research_signal_catalog.gd")
const GoodProfileRegistryScript = preload("res://scripts/data/good_profile_registry.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const DevelopmentAchievementCatalogScript = preload(
	"res://scripts/research/development_achievement_catalog.gd")

# Catalog content (display names, icons, technology requirements) is static for
# the whole session; the cache is built once so daily refreshes cost nothing.
static var _tax_content_cache: Dictionary = {}

var _generator = null


func set_context(generator) -> void:
	_generator = generator


func build(include_treasury: bool = false) -> Dictionary:
	if _generator == null or not _generator.has_method("gameplay_start_report") \
			or not _generator.has_method("get_country_facade"):
		return _unavailable_model("国家档案尚未就绪")
	var start_report: Dictionary = _generator.gameplay_start_report()
	var start_cell := int(start_report.get("cell", -1))
	var facade = _generator.get_country_facade()
	if not bool(start_report.get("ok", false)) or facade == null or start_cell < 0:
		return _unavailable_model("当前会话没有可用的玩家国家")
	var summary: Dictionary = facade.cell_summary(start_cell)
	if not bool(summary.get("ok", false)) or not bool(summary.get("owned", false)):
		return _unavailable_model("玩家国家档案暂不可用")
	var country_handle := int(summary.get("country_handle", 0))
	var research: Dictionary = facade.research_snapshot(country_handle)
	research["research_signal_snapshot"] = facade.research_signal_snapshot(country_handle)
	var tax_policy: Dictionary = facade.tax_policy_snapshot(country_handle) \
		if facade.has_method("tax_policy_snapshot") else {}
	var fiscal: Dictionary = facade.fiscal_snapshot(country_handle) \
		if facade.has_method("fiscal_snapshot") else {}
	var economy_facade = _generator.get_economy_facade() \
		if _generator.has_method("get_economy_facade") else null
	var trade_summary: Dictionary = economy_facade.country_trade_snapshot(
		country_handle, "summary", 0, 1) \
		if economy_facade != null and economy_facade.has_method(
			"country_trade_snapshot") else {"ok": false,
			"reason": "country trade API unavailable"}
	var country_snapshot: Dictionary = facade.snapshot(country_handle) \
		if facade.has_method("snapshot") else {}
	var ideology := _ideology_model(country_handle)
	var treasury := _treasury_model(facade, country_handle) if include_treasury \
		else _unavailable_treasury("当前页面未请求国库明细")
	var treasury_available := bool(treasury.get("available", false))
	var cash := int(treasury.get("cash", 0)) if treasury_available \
		else int(summary.get("cash", 0))
	research["country_cash"] = cash
	var development := _development_model(country_handle, research)
	return {
		"available": true,
		"country_name": String(summary.get("country_name", "未命名国家")),
		"country_id": String(summary.get("country_id", "")),
		"territory_count": int(summary.get("territory_count", 0)),
		"cash": cash,
		"nonzero_good_count": int(treasury.get("nonzero_good_count", 0)) \
			if treasury_available else int(summary.get("nonzero_good_count", 0)),
		"technology_count": int(summary.get("technology_count", 0)),
		"country_handle": country_handle,
		"country_facade": facade,
		"treasury": treasury,
		"tax_policy": tax_policy,
		"tax_presentation": present_tax_policy(tax_policy,
			country_snapshot.get("technology_ids", PackedStringArray())),
		"fiscal": fiscal,
		"trade_summary": trade_summary,
		"economy_facade": economy_facade,
		"current_day": int(facade.report().get("last_committed_day", -1)),
		"research": research,
		"development": development,
		"technology_definitions": TechnologyCatalogScript.public_definitions(),
		"technology_eras": TechnologyCatalogScript.public_era_metadata(),
		"technology_domains": TechnologyCatalogScript.public_domain_metadata(),
		"technology_visual_edges": TechnologyCatalogScript.public_visual_edges(),
		"technology_lanes": TechnologyCatalogScript.public_lane_metadata(),
		"research_signal_definitions": ResearchSignalCatalogScript.public_metadata(),
		"ideology": ideology,
	}


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
		return {"available": false, "reason": "理念运行时不可用。"}
	var facade = _generator.get_ideology_facade()
	if facade == null or not facade.has_method("is_configured") or not facade.is_configured():
		return {"available": false, "reason": "理念运行时尚未配置。"}
	var snapshot: Dictionary = facade.snapshot(country_handle)
	var catalog: Dictionary = facade.catalog_view()
	if not bool(snapshot.get("ok", false)) or not bool(catalog.get("ok", false)):
		return {"available": false, "reason": String(snapshot.get("reason",
			catalog.get("reason", "理念快照不可用。")))}
	return {"available": true, "facade": facade, "snapshot": snapshot, "catalog": catalog}


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


# Tax pages list only the content the country's completed technologies unlock,
# mirroring NativeEconomyRuntime's executable `tech.*` requirement semantics:
# an item with no `tech.*` tag is always available, and non-tech tag namespaces
# are metadata only.
static func present_tax_policy(tax_policy: Dictionary, completed_technologies) -> Dictionary:
	if not bool(tax_policy.get("ok", false)):
		return {"ok": false}
	var completed := {}
	for tech_id in completed_technologies:
		completed[String(tech_id)] = true
	var professions := _present_items(
			tax_policy.get("profession_ids", PackedStringArray()), "profession", completed, false)
	var goods := _present_items(
		tax_policy.get("good_ids", PackedStringArray()), "good", completed, true)
	var tariff_goods := _present_items(
		tax_policy.get("good_ids", PackedStringArray()), "good", completed,
		true, true)
	var buildings := _present_items(
			tax_policy.get("building_type_ids", PackedStringArray()), "building", completed, false)
	return {
		"ok": true,
		"income": professions,
		"consumption": goods,
		"import": tariff_goods,
		"export": tariff_goods,
		"business": buildings,
	}


static func _present_items(ids: PackedStringArray, kind: String,
		completed: Dictionary, allow_tradeable: bool = false,
		tradeable_only: bool = false) -> Dictionary:
	var content := _tax_content(kind)
	var unlocked: Array[Dictionary] = []
	for raw_id in ids:
		var stable_id := String(raw_id)
		var item: Dictionary = content.get(stable_id, {})
		if item.is_empty():
			continue
		if tradeable_only and not bool(item.get("tradeable", false)):
			continue
		var locked := false
		for tech_id in item.get("tech_required", []):
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
				content[String(profile.id)] = _content_entry(
					profile.id, profile.display_name,
					String(IconCatalog.building_semantic(
						String(profile.id), primary_good, kind_code)),
					profile.technology_tags)
	_tax_content_cache[kind] = content
	return content


static func _content_entry(stable_id, display_name: String, icon_key: String,
		technology_tags: PackedStringArray, tradeable: bool = false) -> Dictionary:
	var required: Array[String] = []
	for tag in technology_tags:
		var normalized := String(tag).strip_edges()
		if normalized.begins_with("tech."):
			required.append(normalized)
	var resolved_name := display_name.strip_edges()
	return {
		"display_name": resolved_name if resolved_name != "" else String(stable_id),
		"icon_key": icon_key,
		"tech_required": required,
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
