extends RefCounted

const EconomyDossiers = preload("res://scripts/ui/cell_inspector/economy_dossier_models.gd")

const Recipes = preload("res://scripts/ui/cell_inspector/construction_recipes.gd")
const BuildingDossier = preload("res://scripts/ui/cell_inspector/building_dossier.gd")

const FamilyWorkspaceProjection = preload("res://scripts/ui/family_workspace_projection.gd")
const SATISFACTION_DIMENSION_NAMES = ["生存", "基本生活", "舒适", "奢侈", "收入增长", "储蓄", "税负", "社会发展"]
const SATISFACTION_DIMENSION_EXPLANATIONS = ["热量与御寒的生理满足率；不足会限制综合满意度。", "基本生活实际消费相对生活目标的完整度；综合各项满足率与最短缺的一项，目标不随预算和物价缩减。", "实际享受到的舒适消费相对生活目标的满足率；存款不直接加分。", "实际享受到的奢侈与身份消费相对生活目标的满足率；存款不直接加分。", "近期收入相对长期收入基线的变化。", "剩余存款可支撑的基础生活月数。", "本期净税负相对毛收入的压力。", "本地聚落等级、国家技术进度和建成产业种类。"]
const DOSSIER_INCOME_COLORS: Array[Color] = [UITokens.DOSSIER_VERDIGRIS, UITokens.DOSSIER_BRASS, UITokens.DOSSIER_SLATE, UITokens.DOSSIER_UMBER]
const DOSSIER_EXPENSE_COLORS: Array[Color] = [UITokens.DOSSIER_OXBLOOD, UITokens.DOSSIER_BRASS, UITokens.DOSSIER_UMBER, UITokens.DOSSIER_SLATE]

const TEMPERATURE_HISTORY_CAPACITY = 32
const TEMPERATURE_HISTORY_CACHE_LIMIT = 64
const DETAIL_HISTORY_CAPACITY = 48
const DETAIL_HISTORY_LOOKBACK = 7
## 原生金额单位是 1/10000 货币；只有视图层才把它换算成金币读数。
const MONEY_SCALE = 10000.0

# 对象详情弹窗：行类型 → 页签 / 行列表键 / 中文类型名。
const OBJECT_DETAIL_TAB = {
	"cohort": "population",
	"building": "buildings",
	"good": "market",
	"resource": "geography",
	"family": "families",
}
const OBJECT_DETAIL_ROWS = {
	"cohort": "cohort_rows",
	"building": "building_rows",
	"good": "market_rows",
	"resource": "resource_rows",
	"family": "family_rows",
}
const OBJECT_TYPE_LABELS = {
	"cohort": "阶层",
	"building": "建筑",
	"good": "物资",
	"resource": "自然资源",
	"family": "家族",
}
# 对象类型 → 关联税种（税收契约：所得税按职业、营业税按建筑类型、
# 交易税与进出口关税按物资；自然资源没有适用税种）。
const OBJECT_TAX_KINDS = {
	"cohort": ["income"],
	"building": ["business"],
	"good": ["consumption", "import", "export"],
}
const TAX_KIND_IDS = {"income": 0, "consumption": 1, "business": 2,
	"import": 3, "export": 4}
const TAX_KIND_LABELS = {"income": "所得税", "consumption": "交易税",
	"business": "营业税", "import": "进口关税", "export": "出口关税"}
const TAX_DEFAULT_LABELS = {"income": "此地所得税", "consumption": "此地交易税",
	"business": "此地营业税", "import": "此地进口税", "export": "此地出口税"}
const TAX_KIND_ACCENTS = {"income": UITokens.ACCENT, "consumption": UITokens.GOOD,
	"business": UITokens.CLIMATE, "import": UITokens.WATER, "export": UITokens.WATER}
const TRADE_ORDER_PAGE_SIZE = 12
const TRADE_ORDER_PAGE_CACHE_LIMIT = 8
const TRADE_ORDER_MODEL_CACHE_LIMIT = 16
const TRADE_ORDER_NAME_CACHE_LIMIT = 256

## 营造窗口一页的建筑条目数。一页 = 16 条同时报价：够填满视口，又让
## 「打开 / 切部门 / 翻页 / 每日刷新」的原生报价调用保持在毫秒级。
const CONSTRUCTION_PAGE_SIZE = 16
## Building kinds are compiled to dense ints; 3 == state-owned (barracks /
## fortification / war college). The dedicated military department lists them
## from MilitaryCatalog's `state_buildings` and quotes their economy type IDs.
const STATE_BUILDING_KIND = 3
## 军事部门不是经济目录里的部门：条目来自 MilitaryCatalog 的 `state_buildings`，
## 命令走军事运行时的 `state.build`，与经济侧的 `construction.build` 是两条通道
## （见 docs/ui/military-cell-tab.md §2.1）。这个 id 故意不并入 economy 的
## sector 表，避免被 `construction_candidates` 当成经济部门下标。
const CONSTRUCTION_MILITARY_SECTOR = "military"
## 军事页的三行官营建筑，顺序即行序；`role` 对齐 MilitaryStateRole (military_core.h)。
const STATE_BUILDING_ROLES: Array[Dictionary] = [
	{"id": "barracks", "label": "兵营", "role": 0},
	{"id": "fortification", "label": "城防", "role": 1},
	{"id": "war_college", "label": "军校", "role": 2},
]
## Same order as MilitaryUnitClass (military_core.h), used for unit icon keys.
const MILITARY_UNIT_CLASS_IDS: Array[String] = ["line", "mobile", "artillery"]
## 维护快照的 `kind`：0 = 建筑组，1 = 装备组（D7 契约）。地块档案只读建筑组。
## `object_id` 是目录 `state_buildings` 的稠密下标，与 `state_building_materials()`
## 用的是同一套下标。
const MAINTENANCE_KIND_BUILDING = 0
const MAINTENANCE_REASON_TEXT: Array[String] = ["—", "缺货", "预算不足", "运输未到"]
const CONSTRUCTION_SECTOR_LABELS = {
	"agriculture": "农业",
	"extractive": "采掘",
	"manufacturing": "制造",
	"energy": "能源",
	"knowledge": "知识",
	"military": "军事",
}
const CONSTRUCTION_SECTOR_ICONS = {
	"agriculture": &"economy.building.farm",
	"extractive": &"economy.building.mine",
	"manufacturing": &"economy.building.factory",
	"energy": &"economy.building.power",
	"knowledge": &"economy.building.science",
	"military": &"military.building.barracks",
}
## 营造目录的排序档。三档都遵守「可建优先」，档位只决定可建项之间的次序。
const CONSTRUCTION_SORT_IDS = ["recommended", "cost", "newest"]
## 原生报价的拒绝码 → 玩家可读的短因由（行内标签用，长解释在 hover 里）。
const CONSTRUCTION_REASON_TEXT = {
	"construction_cell_not_owned": "非本国领土",
	"construction_technology_locked": "科技未解锁",
	"construction_obsolete": "已被高阶取代",
	"construction_conditions_failed": "地块不符",
	"construction_resource_unavailable": "自然资源不足",
	"construction_materials_insufficient": "建材不足",
	"construction_market_short": "市场缺货",
	"construction_treasury_cash_insufficient": "资金不足",
	"construction_market_unavailable": "市场不可结算",
	"construction_owner_signature_unavailable": "无合适业主",
	"construction_target_invalid": "目标无效",
}
## one-tick memo for the (large) cell building snapshot: the buildings tab and
## the construction window share one read per cell per committed day.

static func family_workspace_model(detail: Dictionary) -> Dictionary:
	return FamilyWorkspaceProjection.family_workspace_model(detail)


## Facade snapshots may contain the same presentation row through multiple legacy
## lanes.  The workspace is a player-facing projection, so collapse only rows that
## are semantically identical; effects retain their cell in the key to preserve
## same-name effects bound to different branches.

static func _family_unique_traits(rows: Array) -> Array:
	return FamilyWorkspaceProjection._family_unique_traits(rows)



static func _family_unique_preferences(rows: Array) -> Array:
	return FamilyWorkspaceProjection._family_unique_preferences(rows)



static func _family_unique_rows(rows: Array, key_fields: Array) -> Array:
	return FamilyWorkspaceProjection._family_unique_rows(rows, key_fields)



static func _family_text_key(value: Variant) -> String:
	return FamilyWorkspaceProjection._family_text_key(value)



static func _parse_leading_float(text: Variant, fallback: float = 0.0) -> float:
	return EconomyDossiers._parse_leading_float(text, fallback)


static func _detail_row_value_map(detail_rows: Array) -> Dictionary:
	return EconomyDossiers._detail_row_value_map(detail_rows)


static func good_dossier_model(row: Dictionary) -> Dictionary:
	return EconomyDossiers.good_dossier_model(row)


static func cohort_dossier_model(row: Dictionary) -> Dictionary:
	return EconomyDossiers.cohort_dossier_model(row)


static func building_dossier_model(row: Dictionary) -> Dictionary:
	return BuildingDossier.building_dossier_model(row)


static func build_object_detail(host, cell: HexCell, request: Dictionary) -> Dictionary:
	if cell == null or host._map == null:
		return {}
	var kind = String(request.get("kind", ""))
	var row_id = String(request.get("row_id", ""))
	if not host.OBJECT_DETAIL_TAB.has(kind) or row_id.is_empty():
		return {}
	var idx = int(cell.index)
	if VisionSolver.displayed_fog_state(host._map, idx) != VisionSolver.FOG_VISIBLE:
		return {}
	var category = host.build_tab_category(cell, String(host.OBJECT_DETAIL_TAB[kind]))
	var row = {}
	var category_rows = host._Overview_delegate._rows_from_category(host, category, String(host.OBJECT_DETAIL_ROWS[kind]))
	for raw in category_rows:
		var candidate: Dictionary = raw
		if String(candidate.get("id", "")) == row_id:
			row = candidate
			break
	# 阶层行的 id 携带原生 (generation<<32|slot) handle，跨仿真日会随
	# slot 回收/迁移而失效；点击到重建之间若落了一次提交，按职业名
	# 回退匹配继任 cohort，保证点击总是打开同一职业的详情。
	if row.is_empty() and kind == "cohort":
		var fallback_profession = String(request.get("profession_id", ""))
		if not fallback_profession.is_empty():
			for raw in category_rows:
				var candidate: Dictionary = raw
				if String(candidate.get("profession_id", "")) == fallback_profession:
					row = candidate
					break
	if row.is_empty():
		if bool(category.get("data_pending", false)):
			return {"data_pending": true}
		return {}
	if kind == "family":
		var facade = host._generator.get_economy_facade() if host._generator != null \
			and host._generator.has_method("get_economy_facade") else null
		var family_handle = int(row.get("family_handle", 0))
		if facade != null and facade.has_method("family_snapshot"):
			var family_snapshot: Dictionary = facade.family_snapshot(family_handle)
			if bool(family_snapshot.get("ok", false)):
				row.merge(host._Overview_delegate._family_detail_fields(host, family_snapshot), true)
				var family_name = String(family_snapshot.get("family_name", "")).strip_edges()
				if not family_name.is_empty():
					row["name"] = family_name
			row["notable_person_rows"] = host._Overview_delegate._family_notable_person_rows(host,
				facade, family_handle)
			if facade.has_method("get_family_traits"):
				var traits: Dictionary = facade.get_family_traits(family_handle)
				if bool(traits.get("ok", false)):
					row["trait_rows"] = host._Overview_delegate._family_trait_rows(host, traits)
					row["behavior_rows"] = host._family_behavior_rows(traits, idx)
			if facade.has_method("family_branches"):
				var branches: Dictionary = facade.family_branches(
					family_handle, 0, 64)
				if bool(branches.get("ok", false)):
					row["branch_rows"] = host._Overview_delegate._family_branch_rows(host, branches)
					var modifier_rows: Array = []
					var trigger_rows: Array = []
					var effect_rows: Array = []
					var branch_cells: PackedInt32Array = branches.get(
						"cell_indices", PackedInt32Array())
					for branch_cell in branch_cells:
						if not facade.has_method("get_family_branch_effects"):
							break
						var effects: Dictionary = facade.get_family_branch_effects(
							family_handle, int(branch_cell))
						if not bool(effects.get("ok", false)):
							continue
						modifier_rows.append_array(
							host._family_modifier_rows(effects))
						trigger_rows.append_array(
							host._family_trigger_rows(effects))
						effect_rows.append_array(
							host._family_bound_effect_rows(effects))
						if int(branch_cell) == idx:
							row["prestige_level"] = int(
								effects.get("prestige_level", 0))
							row["prestige_score_q16"] = int(
								effects.get("prestige_score_q16", 0))
							row["prestige_score"] = host._q16_percent_text(int(
								effects.get("prestige_score_q16", 0)))
					row["modifier_rows"] = modifier_rows
					row["trigger_rows"] = trigger_rows
					row["effect_rows"] = effect_rows
	var item_id = host.TaxProjection._object_tax_item_id(host, kind, row)
	var country = host._Overview_delegate._country_summary(host, idx)
	var off = HexUtils.cube_to_offset(cell.q, cell.r)
	var payload = {
		"kind": kind,
		"row_id": String(row.get("id", row_id)),
		"item_id": item_id,
		"name": host._object_display_name(kind, row, idx),
		"icon": String(row.get("icon", "resource")),
		"accent": row.get("accent", UITokens.ACCENT),
		"subtitle": "%s · 区域 %d, %d · %s" % [
			String(host.OBJECT_TYPE_LABELS[kind]), off.x + 1, off.y + 1,
			String(country.get("country_name", "无主之地"))],
		"tax_context": category.get("tax_context", {}),
		"row": row,
	}
	if kind == "good":
		# 逐单商路页：只在物资详情打开时按需构建；ViewModel 按 generation 缓存，
		# 日 tick 与 200ms live patch 只会命中模型缓存。
		payload["trade_orders"] = host.trade_orders_model(
			idx,
			String(row.get("good_id", "")),
			int(request.get("orders_offset", 0)),
			host.TRADE_ORDER_PAGE_SIZE,
			int(category.get("economy_generation", -1)),
			int(category.get("sample_day", host._Geography_delegate._current_sample_day(host))))
	return payload


static func build_family_detail(host, cell: HexCell, request: Dictionary) -> Dictionary:
	if String(request.get("kind", "")) != "family":
		return {}
	var detail = host.build_object_detail(cell, request)
	if bool(detail.get("data_pending", false)):
		return detail
	if detail.is_empty() or String(detail.get("kind", "")) != "family":
		return {}
	return host.family_workspace_model(detail)


static func _tax_lanes_from_policy(host,
		policy: Dictionary,
		object_kind: String,
		item_id: String,
		editable: bool
) -> Array:
	var lanes: Array = []
	if item_id.is_empty():
		return lanes
	var country_defaults = host.TaxProjection._tax_basis_points_array(host, policy,
		"country_default_rates_basis_points", "country_default_rates")
	var local_defaults = host.TaxProjection._tax_basis_points_array(host, policy,
		"local_default_rates_basis_points", "local_default_rates")
	var local_flags: PackedByteArray = policy.get(
		"has_local_default", PackedByteArray())
	var local_modes: PackedInt32Array = policy.get(
		"local_default_assessment_modes", PackedInt32Array())
	var country_modes: PackedInt32Array = policy.get(
		"country_default_assessment_modes", PackedInt32Array())
	for kind_value in host.OBJECT_TAX_KINDS.get(object_kind, []):
		var kind = String(kind_value)
		var group: Dictionary = policy.get(kind, {})
		var ids: PackedStringArray = group.get("item_ids", PackedStringArray())
		var item_index = ids.find(item_id)
		var rates = host.TaxProjection._tax_group_basis_points(host, group, "final_base_rates")
		if item_index < 0 or item_index >= rates.size():
			continue
		var effective = host.TaxProjection._tax_group_basis_points(host, group, "effective_rates", rates)
		var modes: PackedInt32Array = group.get(
			"assessment_modes", PackedInt32Array())
		var item_flags: PackedByteArray = group.get(
			"has_local_item", PackedByteArray())
		var country_bases = host.TaxProjection._tax_group_basis_points(host, group, "country_base_rates")
		var kind_id = int(host.TAX_KIND_IDS.get(kind, -1))
		var inherited = int(local_defaults[kind_id]) \
			if kind_id >= 0 and kind_id < local_flags.size() \
			and local_flags[kind_id] != 0 and kind_id < local_defaults.size() \
			else (int(country_bases[item_index]) \
				if item_index < country_bases.size() else (int(country_defaults[kind_id]) \
					if kind_id >= 0 and kind_id < country_defaults.size() else 0))
		var inherited_mode = int(local_modes[kind_id]) \
			if kind_id >= 0 and kind_id < local_flags.size() \
			and local_flags[kind_id] != 0 and kind_id < local_modes.size() \
			else (int(country_modes[kind_id]) \
				if kind_id >= 0 and kind_id < country_modes.size() else 0)
		var mode = int(modes[item_index]) if item_index < modes.size() else inherited_mode
		lanes.append({
			"scope": "item", "kind": kind,
			"kind_label": String(host.TAX_KIND_LABELS.get(kind, kind)),
			"accent": host.TAX_KIND_ACCENTS.get(kind, UITokens.ACCENT),
			"item_id": item_id, "base": int(rates[item_index]),
			"effective": int(effective[item_index]) \
				if item_index < effective.size() else int(rates[item_index]),
			"mode": mode, "effective_mode": mode,
			"has_override": item_index < item_flags.size() \
				and item_flags[item_index] != 0,
			"default_rate": inherited, "default_mode": inherited_mode,
			"editable": editable,
		})
	return lanes


static func _building_category(host, snapshot: Dictionary, cell_idx: int = -1) -> Dictionary:
	return Recipes._building_category(host, snapshot, cell_idx)
