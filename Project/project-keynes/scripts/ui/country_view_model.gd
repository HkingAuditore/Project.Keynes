class_name CountryViewModel
extends RefCounted

const TechnologyCatalogScript = preload("res://scripts/economy/technology_catalog.gd")
const GoodProfileRegistryScript = preload("res://scripts/data/good_profile_registry.gd")

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
		})
	var cash := int(snapshot.get("cash", 0))
	return {
		"available": true,
		"cash": cash,
		"cash_text": UITokens.format_compact_number_cn(float(cash) / 10000.0, 2),
		"nonzero_good_count": goods.size(),
		"goods": goods,
	}


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
