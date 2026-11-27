extends RefCounted

## Decorates committed rows with tax policy and localized tax lane data.


static func _decorate_category_with_tax(owner: CellInspectorViewModel,
		cell_idx: int,
		tab_id: String,
		category: Dictionary
) -> Dictionary:
	var tab_contract: Dictionary = {
		"population": {"row_key": "cohort_rows", "object_kind": "cohort",
			"tax_kinds": ["income"]},
		"market": {"row_key": "market_rows", "object_kind": "good",
			"tax_kinds": ["consumption", "import", "export"]},
		"buildings": {"row_key": "building_rows", "object_kind": "building",
			"tax_kinds": ["business"]},
	}.get(tab_id, {})
	if tab_contract.is_empty():
		return category
	var context := owner._tax_context_for_cell(cell_idx, tab_contract.get("tax_kinds", []))
	category["tax_context"] = context
	if not bool(context.get("available", false)):
		return category
	var policy: Dictionary = context.get("policy", {})
	var row_key := String(tab_contract.get("row_key", ""))
	var object_kind := String(tab_contract.get("object_kind", ""))
	var rows: Array = category.get(row_key, [])
	for row_value in rows:
		var row: Dictionary = row_value
		var item_id := owner.TaxProjection._object_tax_item_id(owner, object_kind, row)
		row["tax_lanes"] = owner._tax_lanes_from_policy(
			policy, object_kind, item_id, bool(context.get("editable", false)))
	# The raw snapshot is only an internal construction aid. Components consume the
	# bounded lane dictionaries and must never retain the facade snapshot itself.
	context.erase("policy")
	category["tax_context"] = context
	return category



static func _tax_context_for_cell(owner: CellInspectorViewModel, cell_idx: int, kinds: Array) -> Dictionary:
	# default_lanes 是地块税种默认，供人口/市场/建筑页渲染；对象详情只用 row.tax_lanes。
	var country := owner._Overview_delegate._country_summary(owner, cell_idx)
	if not bool(country.get("ok", false)) or not bool(country.get("owned", false)):
		return {"available": false, "editable": false,
			"reason": "", "cell": cell_idx,
			"default_lanes": []}
	var facade = owner._generator.get_country_facade() if owner._generator != null \
		and owner._generator.has_method("get_country_facade") else null
	if facade == null or not facade.has_method("cell_tax_policy_snapshot"):
		return {"available": false, "editable": false,
			"reason": "税收政策暂不可用", "cell": cell_idx,
			"default_lanes": []}
	var policy: Dictionary = facade.cell_tax_policy_snapshot(cell_idx)
	if not bool(policy.get("ok", false)):
		return {"available": false, "editable": false,
			"reason": String(policy.get("reason", "税收政策暂不可用")),
			"cell": cell_idx, "default_lanes": []}
	var owner_handle := int(policy.get(
		"country_handle", country.get("country_handle", 0)))
	var editable := owner_handle == owner._player_country_handle()
	var defaults: Array = []
	var reset_targets: Array = []
	var country_defaults := owner.TaxProjection._tax_basis_points_array(owner, policy,
		"country_default_rates_basis_points", "country_default_rates")
	var local_defaults := owner.TaxProjection._tax_basis_points_array(owner, policy,
		"local_default_rates_basis_points", "local_default_rates")
	var local_flags: PackedByteArray = policy.get(
		"has_local_default", PackedByteArray())
	var country_modes: PackedInt32Array = policy.get(
		"country_default_assessment_modes", PackedInt32Array())
	var local_modes: PackedInt32Array = policy.get(
		"local_default_assessment_modes", PackedInt32Array())
	for kind_value in kinds:
		var kind := String(kind_value)
		var kind_id := int(CellInspectorViewModel.TAX_KIND_IDS.get(kind, -1))
		if kind_id < 0:
			continue
		var inherited := int(country_defaults[kind_id]) \
			if kind_id < country_defaults.size() else 0
		var inherited_mode := int(country_modes[kind_id]) \
			if kind_id < country_modes.size() else 0
		var overridden := kind_id < local_flags.size() and local_flags[kind_id] != 0
		var rate := int(local_defaults[kind_id]) \
			if overridden and kind_id < local_defaults.size() else inherited
		var mode := int(local_modes[kind_id]) \
			if overridden and kind_id < local_modes.size() else inherited_mode
		defaults.append({
			"scope": "default", "kind": kind,
			"kind_label": String(CellInspectorViewModel.TAX_DEFAULT_LABELS.get(kind,
				CellInspectorViewModel.TAX_KIND_LABELS.get(kind, kind))),
			"accent": CellInspectorViewModel.TAX_KIND_ACCENTS.get(kind, UITokens.ACCENT),
			"item_id": "", "base": rate, "effective": rate,
			"mode": mode, "effective_mode": mode,
			"default_rate": inherited, "default_mode": inherited_mode,
			"has_override": overridden,
			"editable": editable,
		})
		if overridden:
			reset_targets.append({"scope": "default", "kind": kind, "item_id": ""})
		# 从政策快照取全部覆盖，包含当前名录中未出现的职业、物资和建筑。
		var group: Dictionary = policy.get(kind, {})
		var item_ids: PackedStringArray = group.get("item_ids", PackedStringArray())
		var item_flags: PackedByteArray = group.get("has_local_item", PackedByteArray())
		for item_index in range(mini(item_ids.size(), item_flags.size())):
			if item_flags[item_index] != 0:
				reset_targets.append({"scope": "item", "kind": kind,
					"item_id": String(item_ids[item_index])})
	return {
		"available": true,
		"editable": editable,
		"country_name": String(country.get("country_name", "")),
		"country_handle": owner_handle,
		"cell": cell_idx,
		"current_day": int(facade.report().get("last_committed_day", -1)) \
			if facade.has_method("report") else -1,
		"policy_version": int(policy.get("policy_version", -1)),
		"default_lanes": defaults,
		"reset_targets": reset_targets,
		"policy": policy,
	}



static func _tax_lanes_from_policy(owner: CellInspectorViewModel,
		policy: Dictionary,
		object_kind: String,
		item_id: String,
		editable: bool
) -> Array:
	return CellInspectorViewModel._ObjectDossiers._tax_lanes_from_policy(owner, policy, object_kind, item_id, editable)



static func _tax_basis_points_array(owner: CellInspectorViewModel, policy: Dictionary, preferred_key: String,
		legacy_key: String) -> PackedInt32Array:
	var preferred: PackedInt32Array = policy.get(preferred_key, PackedInt32Array())
	if not preferred.is_empty():
		return preferred
	var legacy: PackedInt32Array = policy.get(legacy_key, PackedInt32Array())
	var converted := PackedInt32Array()
	converted.resize(legacy.size())
	for i in legacy.size():
		converted[i] = int(legacy[i]) * 100
	return converted



static func _tax_group_basis_points(owner: CellInspectorViewModel, group: Dictionary, key: String,
		fallback: PackedInt32Array = PackedInt32Array()) -> PackedInt32Array:
	var preferred: PackedInt32Array = group.get(
		"%s_basis_points" % key, PackedInt32Array())
	if not preferred.is_empty():
		return preferred
	var legacy: PackedInt32Array = group.get(key, fallback)
	if legacy.is_empty():
		return fallback
	var converted := PackedInt32Array()
	converted.resize(legacy.size())
	for i in legacy.size():
		converted[i] = int(legacy[i]) * 100
	return converted



static func _object_tax_item_id(owner: CellInspectorViewModel, kind: String, row: Dictionary) -> String:
	match kind:
		"cohort":
			return String(row.get("profession_id", ""))
		"building":
			return String(row.get("building_type_id", ""))
		"good":
			return String(row.get("good_id", ""))
	return ""
