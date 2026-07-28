class_name CountryViewModel
extends RefCounted

const TechnologyCatalogScript = preload("res://scripts/economy/technology_catalog.gd")

var _generator = null


func set_context(generator) -> void:
	_generator = generator


func build() -> Dictionary:
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
	research["country_cash"] = int(summary.get("cash", 0))
	return {
		"available": true,
		"country_name": String(summary.get("country_name", "未命名国家")),
		"country_id": String(summary.get("country_id", "")),
		"territory_count": int(summary.get("territory_count", 0)),
		"cash": int(summary.get("cash", 0)),
		"nonzero_good_count": int(summary.get("nonzero_good_count", 0)),
		"technology_count": int(summary.get("technology_count", 0)),
		"country_handle": country_handle,
		"country_facade": facade,
		"research": research,
		"technology_definitions": TechnologyCatalogScript.public_definitions(),
		"technology_eras": TechnologyCatalogScript.public_era_metadata(),
		"technology_domains": TechnologyCatalogScript.public_domain_metadata(),
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
	}
