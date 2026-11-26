extends RefCounted

## Formats treasury, procurement, and tax policy values.


static func procurement_model(economy_facade, country_handle: int) -> Dictionary:
	if economy_facade == null or country_handle == 0 \
			or not economy_facade.has_method("country_procurement_snapshot"):
		return {"available": false}
	var snapshot = economy_facade.country_procurement_snapshot(country_handle)
	return CountryViewModel.present_procurement(snapshot if snapshot is Dictionary else {})



static func present_procurement(snapshot: Dictionary) -> Dictionary:
	if snapshot.is_empty() or (snapshot.has("ok") and not bool(snapshot.get("ok", false))):
		return {"available": false,
			"reason": String(snapshot.get("reason", "国家购买数据暂不可用"))}
	var out := {"available": true}
	for key in ["policy_enabled", "era_active"]:
		out[key] = bool(snapshot.get(key, false))
	for key in ["treasury_share_bp", "research_share_bp", "national_daily_budget",
			"research_daily_budget", "other_daily_budget", "era_daily_budget",
			"colonization_daily_budget", "era_cash_spent_total", "era_last_epoch_cash",
			"research_cash_spent_last_epoch", "colonization_cash_spent_last_epoch",
			"trade_orders_total"]:
		out[key] = int(snapshot.get(key, 0))
	# 通道份额可以是 -1（沿用原生自动分配），不能用上面那批「缺省为 0」的循环。
	for key in ["era_share_bp", "colonization_share_bp"]:
		out[key] = int(snapshot.get(key, -1))
	return out



static func _treasury_model(owner: CountryViewModel, facade, country_handle: int) -> Dictionary:
	if facade == null or not facade.has_method("treasury_snapshot"):
		return owner._unavailable_treasury("国家国库查询暂不可用")
	return CountryViewModel.present_treasury(facade.treasury_snapshot(country_handle))



static func present_treasury(snapshot: Dictionary) -> Dictionary:
	if not bool(snapshot.get("ok", false)):
		return CountryViewModel._unavailable_treasury_static(
			String(snapshot.get("reason", "国库数据暂不可用")))
	var good_ids: PackedStringArray = snapshot.get("good_ids", PackedStringArray())
	var quantities: PackedInt64Array = snapshot.get("quantities", PackedInt64Array())
	if good_ids.size() != quantities.size():
		return CountryViewModel._unavailable_treasury_static("国家国库物资数据不完整")
	var goods: Array[Dictionary] = []
	for index in range(good_ids.size()):
		var stable_id := String(good_ids[index])
		var quantity := int(quantities[index])
		if quantity == 0:
			continue
		var profile = CountryViewModel.GoodProfileRegistryScript.profile_by_id(stable_id)
		var display_name := String(profile.display_name) \
			if profile != null and not String(profile.display_name).is_empty() else stable_id
		goods.append({
			"id": stable_id,
			"display_name": display_name,
			"icon": String(CountryViewModel.GoodProfileRegistryScript.icon_key(stable_id)),
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
	return CountryViewModel._present_tax_policy(tax_policy, completed_technologies, availability)



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
	var buildings := CountryViewModel._present_items(
			tax_policy.get("building_type_ids", PackedStringArray()), "building", completed,
		false, false, building_filter, availability.has("building"))
	# 职业没有独立科技门槛；快照缺失时从已解锁建筑的岗位推导，不能回退到全职业。
	if not availability.has("profession"):
		var building_content := CountryViewModel.CountryCatalogPresentation._tax_content("building")
		for row in buildings.get("unlocked", []):
			var building_item: Dictionary = building_content.get(String(row.get("id", "")), {})
			var owner := String(building_item.get("owner_profession_id", ""))
			if not owner.is_empty():
				profession_filter[owner] = true
			for employee in building_item.get("employee_profession_ids", PackedStringArray()):
				profession_filter[String(employee)] = true
	var professions := CountryViewModel._present_items(
		tax_policy.get("profession_ids", PackedStringArray()), "profession", completed,
		false, false, profession_filter, true)
	var goods := CountryViewModel._present_items(
		tax_policy.get("good_ids", PackedStringArray()), "good", completed,
		false, false, good_filter, availability.has("good"))
	var tariff_goods := CountryViewModel._present_items(
		tax_policy.get("good_ids", PackedStringArray()), "good", completed,
		false, true, good_filter, availability.has("good"))
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
	var content := CountryViewModel.CountryCatalogPresentation._tax_content(kind)
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



static func _unavailable_treasury(owner: CountryViewModel, reason: String) -> Dictionary:
	return CountryViewModel._unavailable_treasury_static(reason)



static func _unavailable_treasury_static(reason: String) -> Dictionary:
	return {
		"available": false,
		"reason": reason,
		"cash": 0,
		"cash_text": "",
		"nonzero_good_count": 0,
		"goods": [],
	}
