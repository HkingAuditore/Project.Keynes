extends RefCounted

## Builds and refreshes the economy workspace's active page.


static func _refresh_page(owner: EconomyWorkspace) -> void:
	if owner._flow == null or owner._model.is_empty():
		return
	var wanted := {}
	if owner._page == "trade":
		if owner._tax_groups != null:
			owner._tax_groups.hide_all_groups(owner._default_tax_host, owner._tax_group_list, owner._flow, owner._rows)
		owner._refresh_trade_page(wanted)
		owner._sync_visibility(wanted)
		return
	owner._apply_default_summary_cards()
	if owner._page == "treasury":
		if owner._tax_groups != null:
			owner._tax_groups.hide_all_groups(owner._default_tax_host, owner._tax_group_list, owner._flow, owner._rows)
		owner._apply_goods((owner._model.get("treasury", {}) as Dictionary).get("goods", []), wanted)
		owner._sync_visibility(wanted)
		owner._set_status("")
		return
	var policy: Dictionary = owner._model.get("tax_policy", {})
	if not bool(policy.get("ok", false)):
		if owner._tax_groups != null:
			owner._tax_groups.hide_all_groups(owner._default_tax_host, owner._tax_group_list, owner._flow, owner._rows)
		owner._sync_visibility(wanted)
		owner._empty_label.visible = false
		owner._set_status(String(policy.get("reason", "税收政策暂不可用")))
		return
	var presentation: Dictionary = owner._model.get("tax_presentation", {})
	var page_pres: Dictionary = presentation.get(owner._page, {})
	var defaults := owner._basis_points_array(policy.get("default_rates_basis_points", PackedInt32Array()),
		policy.get("default_rates", PackedInt32Array()))
	var default_modes: PackedInt32Array = policy.get(
		"default_assessment_modes", PackedInt32Array())
	var default_card := owner._ensure_card(owner._page, "__default__", owner._default_title(),
		String(&"tax.default"), true)
	var default_data := {}
	for kind in owner._page_kinds(owner._page):
		var kind_id := int(EconomyWorkspace.TAX_KIND[kind])
		default_data[kind] = {"base": int(defaults[kind_id]),
			"effective": int(defaults[kind_id]), "has_override": false,
			"mode": int(default_modes[kind_id]) if kind_id < default_modes.size() \
				else EconomyWorkspace.TAX_MODE_PERCENT_BP}
	owner._update_card(default_card, default_data)
	wanted["%s:__default__" % owner._page] = true
	var index_by_id := {}
	var ids := owner._item_ids(policy)
	for index in range(ids.size()):
		index_by_id[String(ids[index])] = index
	var kind_groups := {}
	for kind in owner._page_kinds(owner._page):
		kind_groups[kind] = policy.get(kind, {})
	var tariff_ids := {}
	for item in presentation.get("import", {}).get("unlocked", []):
		tariff_ids[String(item.get("id", ""))] = true
	var unlocked: Array = page_pres.get("unlocked", [])
	for item_value in unlocked:
		var item: Dictionary = item_value
		var stable_id := String(item.get("id", ""))
		if not index_by_id.has(stable_id):
			continue
		var index: int = index_by_id[stable_id]
		var kind_data := {}
		var complete := true
		for kind in owner._page_kinds(owner._page):
			if kind in ["import", "export"] and not tariff_ids.has(stable_id):
				continue
			var group: Dictionary = kind_groups[kind]
			var rates := owner._group_basis_points(group, "rates")
			if index >= rates.size():
				complete = false
				break
			var effective := owner._group_basis_points(group, "effective_rates", rates)
			var flags: PackedByteArray = group.get("has_override", PackedByteArray())
			var modes: PackedInt32Array = group.get(
				"assessment_modes", PackedInt32Array())
			kind_data[kind] = {
				"base": int(rates[index]),
				"effective": int(effective[index]) if index < effective.size() \
					else int(rates[index]),
				"has_override": index < flags.size() and flags[index] != 0,
				"mode": int(modes[index]) if index < modes.size() \
					else EconomyWorkspace.TAX_MODE_PERCENT_BP,
			}
		if not complete:
			continue
		var card := owner._ensure_card(owner._page, stable_id,
			String(item.get("display_name", stable_id)),
			String(item.get("icon_key", "")), false, kind_data.keys())
		owner._update_card(card, kind_data)
		wanted["%s:%s" % [owner._page, stable_id]] = true
	owner._sync_visibility(wanted)
	if owner._tax_groups != null:
		owner._tax_groups.sync_groups(owner._page, wanted, owner._default_tax_host, owner._tax_group_list,
			owner._flow, owner._rows, owner._group_axis_picker, owner._expand_all_button)
	owner._set_status("")
	owner._apply_filter()



static func _select_trade_view(owner: EconomyWorkspace, view: String) -> void:
	if view != "goods" and view != "partners":
		return
	owner._trade_view = view
	owner._trade_offset = 0
	if owner._trade_goods_button != null:
		owner._trade_goods_button.button_pressed = view == "goods"
	if owner._trade_partners_button != null:
		owner._trade_partners_button.button_pressed = view == "partners"
	owner._refresh_page()



static func _trade_previous_page(owner: EconomyWorkspace) -> void:
	owner._trade_offset = maxi(0, owner._trade_offset - 32)
	owner._refresh_page()



static func _trade_next_page(owner: EconomyWorkspace) -> void:
	var cached: Dictionary = owner._trade_cache.get(owner._trade_cache_key(), {})
	if not bool(cached.get("has_more", false)):
		return
	owner._trade_offset += 32
	owner._refresh_page()



static func _trade_cache_key(owner: EconomyWorkspace) -> String:
	return EconomyWorkspace.TradePresentation._trade_cache_key(owner)



static func _trade_good_name(owner: EconomyWorkspace, good_index: int) -> String:
	return EconomyWorkspace.TradePresentation._trade_good_name(owner, good_index)



static func _trade_partner_name(owner: EconomyWorkspace, handle: int, slot: int) -> String:
	return EconomyWorkspace.TradePresentation._trade_partner_name(owner, handle, slot)



static func _refresh_trade_page(owner: EconomyWorkspace, wanted: Dictionary) -> void:
	EconomyWorkspace.TradePresentation._refresh_trade_page(owner, wanted)



static func _ensure_trade_row(owner: EconomyWorkspace, key: String) -> Dictionary:
	return EconomyWorkspace.TradePresentation._ensure_trade_row(owner, key)



static func _apply_trade_summary_cards(owner: EconomyWorkspace) -> void:
	EconomyWorkspace.TradePresentation._apply_trade_summary_cards(owner)



static func _apply_default_summary_cards(owner: EconomyWorkspace) -> void:
	var treasury: Dictionary = owner._model.get("treasury", {})
	var fiscal: Dictionary = owner._model.get("fiscal", {})
	var available := bool(owner._model.get("available", false))
	var collected := owner._sum_i64(fiscal.get("collected", PackedInt64Array()))
	var subsidy := owner._sum_i64(fiscal.get("subsidy_paid", PackedInt64Array()))
	var requested := owner._sum_i64(fiscal.get("subsidy_requested", PackedInt64Array()))
	var reserved := owner._sum_i64(fiscal.get("subsidy_reserved", PackedInt64Array()))
	var cumulative_subsidy := owner._sum_i64(fiscal.get(
		"cumulative_subsidy_paid", PackedInt64Array()))
	var fulfillment := 1.0 if requested <= 0 else float(subsidy) / float(requested)
	owner._cash_card.set_data("国库现金",
		String(treasury.get("cash_text", "—")) if available else "—",
		String(owner._model.get("country_name", "玩家国家")), UITokens.RESOURCE, "", "metric.treasury",
		true)
	owner._tax_card.set_data("昨日税收", owner._money(collected), "所得税 / 交易税 / 营业税",
		UITokens.BRASS_HIGHLIGHT, "", "tax.section", true)
	var subsidy_gap := maxi(0, requested - subsidy)
	owner._subsidy_card.set_data("补贴缺口", owner._money(subsidy_gap),
		"本批实付 %s · 累计实付 %s" % [owner._money(subsidy), owner._money(cumulative_subsidy)],
		UITokens.CLIMATE if subsidy_gap <= 0 else UITokens.RISK, "", "tax.income", true)
	owner._fulfillment_card.set_data("补贴兑现率", "%.1f%%" % (fulfillment * 100.0),
		("未预留，等待国库预算" if requested > 0 and subsidy == 0 and reserved == 0
		 else "昨日申请 · 预留 %s" % owner._money(reserved)),
		UITokens.ACCENT, "", "tax.default")



static func _sync_visibility(owner: EconomyWorkspace, wanted: Dictionary) -> void:
	for row_value in owner._rows.values():
		var card: Dictionary = row_value
		var control := card.control as Control
		var should_show := wanted.has("%s:%s" % [String(card.page), String(card.item_id)])
		if control.visible != should_show:
			control.visible = should_show
	for row_value in owner._trade_rows.values():
		var card: Dictionary = row_value
		var control := card.control as Control
		var should_show := wanted.has("%s:%s" % [String(card.page), String(card.item_id)])
		if control.visible != should_show:
			control.visible = should_show


# 物资税卡片共用物资目录，各税种仍独立提交。
static func _page_kinds(owner: EconomyWorkspace, page: String) -> Array:
	return ["consumption", "import", "export"] if page == "consumption" else [page]



static func _kind_page(owner: EconomyWorkspace, kind: String) -> String:
	return "consumption" if kind == "import" or kind == "export" else kind



static func _default_title(owner: EconomyWorkspace) -> String:
	return "默认物资税率" if owner._page == "consumption" else "默认税率"


## 触摸键盘的标题：卡片名 + 可见的税种名。单一税种时那一列本来就不渲染，
## 标题只留卡片名，免得写成「所得税 · 所得税」。
static func _pad_title(owner: EconomyWorkspace, label: String, kind_label: Label) -> String:
	if kind_label != null and kind_label.visible and not kind_label.text.is_empty():
		return "%s · %s" % [label, kind_label.text]
	return label


## 当前这条税率行用的口径（给触摸键盘定位选中态）。
static func _pad_mode(owner: EconomyWorkspace, key: String, kind: String) -> int:
	var card: Dictionary = owner._rows.get(key, {})
	if card.is_empty():
		return EconomyWorkspace.TAX_MODE_PERCENT_BP
	return owner._card_mode(card, kind)


## 只改口径、不提交：下拉随之同步，SpinBox 的量程/单位换到新口径并归零。
## 真正的税率由调用方随后一条命令提交。
static func _apply_tax_mode(owner: EconomyWorkspace, card: Dictionary, kind: String, spin: SpinBox, mode: int) -> void:
	(card.assessment_modes as Dictionary)[kind] = mode
	var button := (card.modes as Dictionary).get(kind) as OptionButton
	if button != null:
		var index := button.get_item_index(mode)
		if index >= 0 and button.selected != index:
			button.select(index)
	owner._configure_spin_for_mode(spin, mode)
	owner._set_spin_basis_points(spin, 0, mode)



static func _item_ids(owner: EconomyWorkspace, policy: Dictionary) -> PackedStringArray:
	if owner._page == "income":
		return policy.get("profession_ids", PackedStringArray())
	if owner._page == "business":
		return policy.get("building_type_ids", PackedStringArray())
	return policy.get("good_ids", PackedStringArray())



static func _basis_points_array(owner: EconomyWorkspace, preferred, fallback) -> PackedInt32Array:
	var source: PackedInt32Array = preferred if preferred is PackedInt32Array else PackedInt32Array()
	if not source.is_empty():
		return source
	var legacy: PackedInt32Array = fallback if fallback is PackedInt32Array else PackedInt32Array()
	var converted := PackedInt32Array()
	converted.resize(legacy.size())
	for i in legacy.size():
		converted[i] = int(legacy[i]) * 100
	return converted
