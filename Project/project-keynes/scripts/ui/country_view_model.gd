class_name CountryViewModel
extends RefCounted

const TechnologyCatalogScript = preload("res://scripts/economy/technology_catalog.gd")
const GoodProfileRegistryScript = preload("res://scripts/data/good_profile_registry.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")

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
	var tax_policy: Dictionary = facade.tax_policy_snapshot(country_handle) \
		if facade.has_method("tax_policy_snapshot") else {}
	var fiscal: Dictionary = facade.fiscal_snapshot(country_handle) \
		if facade.has_method("fiscal_snapshot") else {}
	var country_snapshot: Dictionary = facade.snapshot(country_handle) \
		if facade.has_method("snapshot") else {}
	var treasury := _treasury_model(facade, country_handle) if include_treasury \
		else _unavailable_treasury("当前页面未请求国库明细")
	var treasury_available := bool(treasury.get("available", false))
	var cash := int(treasury.get("cash", 0)) if treasury_available \
		else int(summary.get("cash", 0))
	research["country_cash"] = cash
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
		"current_day": int(facade.report().get("last_committed_day", -1)),
		"research": research,
		"technology_definitions": TechnologyCatalogScript.public_definitions(),
		"technology_eras": TechnologyCatalogScript.public_era_metadata(),
		"technology_domains": TechnologyCatalogScript.public_domain_metadata(),
	}


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
		tax_policy.get("profession_ids", PackedStringArray()), "profession", completed)
	var goods := _present_items(
		tax_policy.get("good_ids", PackedStringArray()), "good", completed)
	var buildings := _present_items(
		tax_policy.get("building_type_ids", PackedStringArray()), "building", completed)
	return {
		"ok": true,
		"income": professions,
		"consumption": goods,
		"import": goods,
		"export": goods,
		"business": buildings,
	}


static func _present_items(ids: PackedStringArray, kind: String,
		completed: Dictionary) -> Dictionary:
	var content := _tax_content(kind)
	var unlocked: Array[Dictionary] = []
	for raw_id in ids:
		var stable_id := String(raw_id)
		var item: Dictionary = content.get(stable_id, {})
		if item.is_empty():
			continue
		var locked := false
		for tech_id in item.get("tech_required", []):
			if not completed.has(String(tech_id)):
				locked = true
				break
		if locked:
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
					profile.technology_tags)
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
		technology_tags: PackedStringArray) -> Dictionary:
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
	}


static func _load_profiles(dir_path: String) -> Array:
	var paths := PackedStringArray()
	for file_name in DirAccess.get_files_at(dir_path):
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
