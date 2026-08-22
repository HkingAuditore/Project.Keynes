extends RefCounted
class_name CellInspectorViewModel

const TEMPERATURE_HISTORY_CAPACITY := 32
const TEMPERATURE_HISTORY_CACHE_LIMIT := 64

# 对象详情弹窗：行类型 → 页签 / 行列表键 / 中文类型名。
const OBJECT_DETAIL_TAB := {
	"cohort": "population",
	"building": "buildings",
	"good": "market",
	"resource": "geography",
	"family": "families",
}
const OBJECT_DETAIL_ROWS := {
	"cohort": "cohort_rows",
	"building": "building_rows",
	"good": "market_rows",
	"resource": "resource_rows",
	"family": "family_rows",
}
const OBJECT_TYPE_LABELS := {
	"cohort": "阶层",
	"building": "建筑",
	"good": "物资",
	"resource": "自然资源",
	"family": "家族",
}
# 对象类型 → 关联税种（税收契约：所得税按职业、营业税按建筑类型、
# 消费税与进出口关税按物资；自然资源没有适用税种）。
const OBJECT_TAX_KINDS := {
	"cohort": ["income"],
	"building": ["business"],
	"good": ["consumption", "import", "export"],
}
const TAX_KIND_IDS := {"income": 0, "consumption": 1, "business": 2,
	"import": 3, "export": 4}
const TAX_KIND_LABELS := {"income": "所得税", "consumption": "消费税",
	"business": "营业税", "import": "进口关税", "export": "出口关税"}
const TAX_DEFAULT_LABELS := {"income": "此地所得税", "consumption": "此地消费税",
	"business": "此地营业税", "import": "此地进口税", "export": "此地出口税"}
const TAX_KIND_ACCENTS := {"income": UITokens.ACCENT, "consumption": UITokens.GOOD,
	"business": UITokens.CLIMATE, "import": UITokens.WATER, "export": UITokens.WATER}

var _map: MapData
var _generator
var _view_adapter: DCViewAdapter
var _world_clock: WorldClock
var _sea_level: float = 0.42
var _hex_size: float = 22.0
var _resource_prev_reserves: Dictionary = {}
var _market_prev_stock: Dictionary = {}
var _temperature_histories: Dictionary = {}
var _temperature_history_order: Array[int] = []
var _need_display_names: Dictionary = {}
var _need_display_names_loaded := false
var _player_country_resolved := false
var _player_country_handle_cache := -1
var _research_signal_catalog: Dictionary = {}
var _technology_catalog: Dictionary = {}


func set_context(map: MapData, generator, view_adapter: DCViewAdapter, world_clock: WorldClock, sea_level: float, hex_size: float) -> void:
	_map = map
	_generator = generator
	_view_adapter = view_adapter
	_world_clock = world_clock
	_sea_level = sea_level
	_hex_size = hex_size
	_resource_prev_reserves.clear()
	_market_prev_stock.clear()
	_temperature_histories.clear()
	_temperature_history_order.clear()
	_player_country_resolved = false
	_player_country_handle_cache = -1


func observe_temperature(cell: HexCell, day_idx: int = -1) -> void:
	if cell == null or _map == null:
		return
	var idx := int(cell.index)
	_record_temperature_sample(
		idx,
		day_idx if day_idx >= 0 else _current_sample_day(),
		_temp(cell, idx)
	)


func set_inspector_trace_cell(cell_idx: int) -> void:
	if _generator == null or not _generator.has_method("get_economy_facade"):
		return
	var facade = _generator.get_economy_facade()
	if facade != null and facade.has_method("set_inspector_trace_cell"):
		facade.set_inspector_trace_cell(cell_idx)


## 三态门控：未探索只给一条占位，不碰任何经济/人口/国家查询；已探索但当前
## 不可见只给地理页签——地理是「记忆中的地形」，人口/市场/建筑/自然资源都是
## 需要在场才看得到的实时情报。页签不在列表里，build_tab_category 就永远不会
## 被请求，被过滤掉的那几次经济查询也就一并省掉了。
func build(cell: HexCell) -> Dictionary:
	if cell == null or _map == null:
		return {}
	var idx := int(cell.index)
	var fog := VisionSolver.fog_state(_map, idx)
	if fog == VisionSolver.FOG_UNEXPLORED:
		return _build_unexplored_model(cell)
	var intel_visible := fog == VisionSolver.FOG_VISIBLE
	var off := HexUtils.cube_to_offset(cell.q, cell.r)
	var terrain_v := _terrain(cell, idx)
	var landform_v := _landform(cell, idx)
	var vegetation_v := _vegetation(cell, idx)
	var cover_v := _cover(cell, idx)
	var temp := _temp(cell, idx)
	_record_temperature_sample(idx, _current_sample_day(), temp)
	var moist := _moisture(cell, idx)
	var base_moist := _base_moisture(cell, idx)
	var elev := _elevation(cell, idx)
	var wf := _weather_field(cell, idx)
	var vitality := _vitality(cell, landform_v)
	var snow := _snow_cover(cell, idx)
	var is_water := LandformType.is_water(landform_v)
	var passable_land := TerrainType.is_passable_land(terrain_v)
	var population_summary := _population_summary(idx) if intel_visible else {}
	var country_summary := _country_summary(idx) if intel_visible else {}
	var habitability := _habitability_score(temp, moist, vitality, elev, passable_land, is_water)
	var tabs := [{"id": "geography", "label": "地理", "icon": "geo"}]
	if intel_visible:
		tabs.append_array([
			{"id": "population", "label": "人口", "icon": "growth"},
			{"id": "families", "label": "家族", "icon": "family.house"},
			{"id": "market", "label": "市场", "icon": "resource"},
			{"id": "buildings", "label": "建筑", "icon": "building"},
		])
	var cards: Array = _summary_cards(temp, moist, population_summary, country_summary) \
		if intel_visible else _out_of_sight_summary_cards(temp, moist)
	var geography_category := _geography_information_category(cell, idx, terrain_v,
		landform_v, vegetation_v, cover_v, elev, temp, moist, base_moist,
		wf, snow, vitality, passable_land, is_water)
	if intel_visible:
		_append_resources_to_geography(geography_category, idx, is_water)
	return {
		"cell_index": idx,
		"header": _build_header(off, terrain_v, landform_v, country_summary,
			population_summary),
		"score": {
			"id": "habitability",
			"title": "适宜度",
			"value": habitability,
			"caption": _score_caption(habitability),
			"accent": _score_color(habitability),
		},
		"summary_cards": cards,
		"colonization_action": _colonization_action(
			idx, intel_visible, passable_land, is_water, country_summary),
		"tabs": tabs,
		"categories": {
			"geography": geography_category,
		},
	}


func _build_unexplored_model(cell: HexCell) -> Dictionary:
	var off := HexUtils.cube_to_offset(cell.q, cell.r)
	return {
		"cell_index": int(cell.index),
		"header": {
			"title": "未探索区域",
			"subtitle": "区域 %d, %d · 未探索" % [off.x + 1, off.y + 1],
		},
		"score": {},
		"summary_cards": [{
			"id": "summary_unexplored",
			"title": "情报",
			"value": "未知",
			"subtitle": "尚未进入你的视野",
			"accent": UITokens.TEXT_FAINT,
			"icon": "geo",
		}],
		"tabs": [],
		"categories": {},
	}


func _out_of_sight_summary_cards(temp: float, moist: float) -> Array:
	return [
		{
			"id": "summary_climate",
			"title": "气候",
			"value": "%s · %s" % [_temperature_band(temp), _moisture_band(moist)],
			"subtitle": "",
			"accent": UITokens.CLIMATE,
			"icon": "sun",
		},
		{
			"id": "summary_unexplored",
			"title": "情报",
			"value": "视野之外",
			"subtitle": "只记得地理，人口与市场未知",
			"accent": UITokens.TEXT_FAINT,
			"icon": "geo",
		},
	]


func live_patch_revision(cell: HexCell, current_tab: String) -> Dictionary:
	if cell == null or _map == null:
		return {}
	var idx := int(cell.index)
	var tab_id := current_tab if current_tab != "" else "geography"
	var fog := VisionSolver.fog_state(_map, idx)
	var intel_visible := fog == VisionSolver.FOG_VISIBLE
	var population_summary := _population_summary(idx) if intel_visible else {}
	var country_summary := _country_summary(idx) if intel_visible else {}
	var tax_policy_version := _cell_tax_policy_version(idx) \
		if intel_visible and tab_id in ["population", "market", "buildings"] else -1
	# fog 参与哈希：视野状态一变，页签集合也变，面板必须整体重建而不是打补丁。
	var common_state := [
		fog,
		idx,
		_terrain(cell, idx),
		_landform(cell, idx),
		_temp(cell, idx),
		_moisture(cell, idx),
		_elevation(cell, idx),
		_vitality(cell, _landform(cell, idx)),
		bool(population_summary.get("ok", false)),
		int(population_summary.get("population", 0)),
		int(population_summary.get("cohort_count", 0)),
		int(population_summary.get("funds", 0)),
		int(population_summary.get("epoch_income", 0)),
		int(population_summary.get("epoch_expense", 0)),
		int(population_summary.get("state_day", -1)),
		int(population_summary.get("satisfaction_q16", 0)),
		int(population_summary.get("prosperity_generation", 0)),
		int(population_summary.get("name_roll_generation", 0)),
		String(population_summary.get("settlement_name", "")),
		String(country_summary.get("country_name", "")),
		int(country_summary.get("cash", 0)),
		int(country_summary.get("nonzero_good_count", 0)),
		int(country_summary.get("technology_count", 0)),
	]
	return {
		"tab_id": tab_id,
		"selection_context": "%d/%d/%d" % [
			fog,
			1 if bool(country_summary.get("owned", false)) else 0,
			int(country_summary.get("country_handle", -1)),
		],
		"tabs_signature": "geography|population|families|market|buildings" \
			if intel_visible else "geography",
		"common_hash": hash(common_state),
		"category_generation": int(population_summary.get(
			"settlement_generation", -1)) if tab_id == "population" \
			else tax_policy_version \
			if tab_id == "market" or tab_id == "buildings" else -1,
		"tax_policy_version": tax_policy_version,
		"population_summary": population_summary,
	}


func build_live_patch(
		cell: HexCell,
		current_tab: String,
		include_category: bool = true,
		population_summary_override: Dictionary = {},
		include_details: bool = true
) -> Dictionary:
	if cell == null or _map == null:
		return {}
	var idx := int(cell.index)
	var fog := VisionSolver.fog_state(_map, idx)
	if fog == VisionSolver.FOG_UNEXPLORED:
		return _build_unexplored_model(cell)
	var intel_visible := fog == VisionSolver.FOG_VISIBLE
	var off := HexUtils.cube_to_offset(cell.q, cell.r)
	var terrain_v := _terrain(cell, idx)
	var landform_v := _landform(cell, idx)
	var vegetation_v := _vegetation(cell, idx)
	var cover_v := _cover(cell, idx)
	var temp := _temp(cell, idx)
	_record_temperature_sample(idx, _current_sample_day(), temp)
	var moist := _moisture(cell, idx)
	var base_moist := _base_moisture(cell, idx)
	var elev := _elevation(cell, idx)
	var wf := _weather_field(cell, idx)
	var vitality := _vitality(cell, landform_v)
	var snow := _snow_cover(cell, idx)
	var is_water := LandformType.is_water(landform_v)
	var passable_land := TerrainType.is_passable_land(terrain_v)
	var habitability := _habitability_score(temp, moist, vitality, elev, passable_land, is_water)
	var tab_id := current_tab if current_tab != "" else "geography"
	if not intel_visible:
		tab_id = "geography"
	var population_summary: Dictionary
	var country_summary := _country_summary(idx) if intel_visible else {}
	var category: Dictionary
	if not intel_visible:
		if include_category:
			category = _geography_information_category(cell, idx, terrain_v,
				landform_v, vegetation_v, cover_v, elev, temp, moist, base_moist,
				wf, snow, vitality, passable_land, is_water)
	elif tab_id == "population":
		if include_category:
			# 列表 live patch 不拉需求预览和市场价；对象详情仍走完整 snapshot。
			population_summary = _population_snapshot(idx, include_details)
			var market := _market_snapshot(idx) if include_details else {}
			category = _population_category(population_summary, market)
			category = _decorate_category_with_tax(idx, tab_id, category)
		else:
			population_summary = population_summary_override if not \
				population_summary_override.is_empty() else _population_summary(idx)
	else:
		population_summary = _population_summary(idx)
		if include_category:
			category = _geography_information_category(cell, idx, terrain_v,
				landform_v, vegetation_v, cover_v, elev, temp, moist, base_moist,
				wf, snow, vitality, passable_land, is_water) if tab_id == "geography" \
				else build_tab_category(cell, tab_id)
			if tab_id == "geography":
				_append_resources_to_geography(category, idx, is_water)
	if include_category and category.is_empty():
		tab_id = "geography"
		category = _geography_information_category(cell, idx, terrain_v,
			landform_v, vegetation_v, cover_v, elev, temp, moist, base_moist,
			wf, snow, vitality, passable_land, is_water)
		if intel_visible:
			_append_resources_to_geography(category, idx, is_water)
	var patch := {
		"header": _build_header(off, terrain_v, landform_v, country_summary,
			population_summary),
		"score": {
			"id": "habitability",
			"title": "适宜度",
			"value": habitability,
			"caption": _score_caption(habitability),
			"accent": _score_color(habitability),
		},
		"summary_cards": _summary_cards(temp, moist, population_summary, country_summary) \
			if intel_visible else _out_of_sight_summary_cards(temp, moist),
		"tab_id": tab_id,
	}
	if include_category:
		patch["category"] = category
	return patch


func build_tab_category(cell: HexCell, tab_id: String) -> Dictionary:
	if cell == null or _map == null:
		return {}
	var idx := int(cell.index)
	# 兜底：页签栏本来就不会给出被门控掉的页签，但延迟请求可能跨越一次视野变化。
	if VisionSolver.fog_state(_map, idx) != VisionSolver.FOG_VISIBLE and tab_id != "geography":
		return {}
	match tab_id:
		"population":
			return _decorate_category_with_tax(idx, tab_id,
				_population_category(_population_snapshot(idx), _market_snapshot(idx)))
		"families":
			return _family_category(_family_cell_snapshot(idx))
		"market":
			return _decorate_category_with_tax(idx, tab_id,
				_market_category(_market_snapshot(idx)))
		"buildings":
			return _decorate_category_with_tax(idx, tab_id,
				_building_category(_building_snapshot(idx), idx))
		"natural_resources":
			var visibility := _resource_visibility_context(idx)
			return _resources_category(_resource_state(
				idx, LandformType.is_water(_landform(cell, idx)), visibility),
				visibility)
		"geography":
			var terrain_v := _terrain(cell, idx)
			var landform_v := _landform(cell, idx)
			var vegetation_v := _vegetation(cell, idx)
			var cover_v := _cover(cell, idx)
			var temp := _temp(cell, idx)
			var moist := _moisture(cell, idx)
			var base_moist := _base_moisture(cell, idx)
			var elev := _elevation(cell, idx)
			var is_water := LandformType.is_water(landform_v)
			var category := _geography_information_category(
				cell, idx, terrain_v, landform_v, vegetation_v, cover_v, elev,
				temp, moist, base_moist, _weather_field(cell, idx),
				_snow_cover(cell, idx), _vitality(cell, landform_v),
				TerrainType.is_passable_land(terrain_v), is_water)
			if VisionSolver.fog_state(_map, idx) == VisionSolver.FOG_VISIBLE:
				_append_resources_to_geography(category, idx, is_water)
			return category
	return {}


## 对象详情工作区：按请求重建对应页签 category 并取出目标行，附地块坐标与
## 所属国家。只读 facade/快照数据，不触碰仿真状态；与页签一致，
## 仅当前可见（FOG_VISIBLE）地块允许打开。
func build_object_detail(cell: HexCell, request: Dictionary) -> Dictionary:
	if cell == null or _map == null:
		return {}
	var kind := String(request.get("kind", ""))
	var row_id := String(request.get("row_id", ""))
	if not OBJECT_DETAIL_TAB.has(kind) or row_id.is_empty():
		return {}
	var idx := int(cell.index)
	if VisionSolver.fog_state(_map, idx) != VisionSolver.FOG_VISIBLE:
		return {}
	var category := build_tab_category(cell, String(OBJECT_DETAIL_TAB[kind]))
	var row := {}
	var category_rows := _rows_from_category(category, String(OBJECT_DETAIL_ROWS[kind]))
	for raw in category_rows:
		var candidate: Dictionary = raw
		if String(candidate.get("id", "")) == row_id:
			row = candidate
			break
	# 阶层行的 id 携带原生 (generation<<32|slot) handle，跨仿真日会随
	# slot 回收/迁移而失效；点击到重建之间若落了一次提交，按职业名
	# 回退匹配继任 cohort，保证点击总是打开同一职业的详情。
	if row.is_empty() and kind == "cohort":
		var fallback_profession := String(request.get("profession_id", ""))
		if not fallback_profession.is_empty():
			for raw in category_rows:
				var candidate: Dictionary = raw
				if String(candidate.get("profession_id", "")) == fallback_profession:
					row = candidate
					break
	if row.is_empty():
		return {}
	if kind == "family":
		var facade = _generator.get_economy_facade() if _generator != null \
			and _generator.has_method("get_economy_facade") else null
		var family_handle := int(row.get("family_handle", 0))
		if facade != null and facade.has_method("family_snapshot"):
			var family_snapshot: Dictionary = facade.family_snapshot(family_handle)
			if bool(family_snapshot.get("ok", false)):
				row.merge(_family_detail_fields(family_snapshot), true)
				var family_name := String(family_snapshot.get("family_name", "")).strip_edges()
				if not family_name.is_empty():
					row["name"] = family_name
			row["notable_person_rows"] = _family_notable_person_rows(
				facade, family_handle)
			if facade.has_method("get_family_traits"):
				var traits: Dictionary = facade.get_family_traits(family_handle)
				if bool(traits.get("ok", false)):
					row["trait_rows"] = _family_trait_rows(traits)
					row["behavior_rows"] = _family_behavior_rows(traits, idx)
			if facade.has_method("family_branches"):
				var branches: Dictionary = facade.family_branches(
					family_handle, 0, 64)
				if bool(branches.get("ok", false)):
					row["branch_rows"] = _family_branch_rows(branches)
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
							_family_modifier_rows(effects))
						trigger_rows.append_array(
							_family_trigger_rows(effects))
						effect_rows.append_array(
							_family_bound_effect_rows(effects))
						if int(branch_cell) == idx:
							row["prestige_level"] = int(
								effects.get("prestige_level", 0))
							row["prestige_score_q16"] = int(
								effects.get("prestige_score_q16", 0))
							row["prestige_score"] = _q16_percent_text(int(
								effects.get("prestige_score_q16", 0)))
					row["modifier_rows"] = modifier_rows
					row["trigger_rows"] = trigger_rows
					row["effect_rows"] = effect_rows
	var item_id := _object_tax_item_id(kind, row)
	var country := _country_summary(idx)
	var off := HexUtils.cube_to_offset(cell.q, cell.r)
	return {
		"kind": kind,
		"row_id": String(row.get("id", row_id)),
		"item_id": item_id,
		"name": _object_display_name(kind, row, idx),
		"icon": String(row.get("icon", "resource")),
		"accent": row.get("accent", UITokens.ACCENT),
		"subtitle": "%s · 区域 %d, %d · %s" % [
			String(OBJECT_TYPE_LABELS[kind]), off.x + 1, off.y + 1,
			String(country.get("country_name", "无主之地"))],
		"tax_context": category.get("tax_context", {}),
		"row": row,
	}


## 家族专用档案册契约。保留 build_object_detail() 作为现有 facade、迷雾门控
## 与低频查询的唯一入口，再把兼容行数据整理成专用组件无需二次解析的结构。
func build_family_detail(cell: HexCell, request: Dictionary) -> Dictionary:
	if String(request.get("kind", "")) != "family":
		return {}
	var detail := build_object_detail(cell, request)
	if detail.is_empty() or String(detail.get("kind", "")) != "family":
		return {}
	return family_workspace_model(detail)


static func family_workspace_model(detail: Dictionary) -> Dictionary:
	if detail.is_empty() or String(detail.get("kind", "")) != "family":
		return {}
	var row: Dictionary = detail.get("row", {})
	var traits := _family_unique_traits(row.get("trait_rows", []))
	var preferences := _family_unique_preferences(row.get("behavior_rows", []))
	var people := _family_unique_rows(row.get("notable_person_rows", []),
		["id", "handle", "name", "role", "profession", "building"])
	var branches := _family_unique_rows(row.get("branch_rows", []),
		["id", "cell", "prestige_level", "population_share_text",
		"cash_share_text", "building_share_text"])
	var effects: Array = []
	effects.append_array(row.get("effect_rows", []))
	effects.append_array(row.get("modifier_rows", []))
	effects.append_array(row.get("trigger_rows", []))
	effects = _family_unique_rows(effects,
		["cell", "kind", "id", "title", "name", "value", "detail"])
	effects.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var cell_a := int(a.get("cell", -1))
		var cell_b := int(b.get("cell", -1))
		if cell_a != cell_b:
			return cell_a < cell_b
		return String(a.get("kind", "")) < String(b.get("kind", "")))

	var sorted_preferences := preferences.duplicate(true)
	sorted_preferences.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var axis_a := int(a.get("axis", 99))
		var axis_b := int(b.get("axis", 99))
		if axis_a != axis_b:
			return axis_a < axis_b
		return String(a.get("name", "")) < String(b.get("name", "")))
	var overview_preferences := preferences.duplicate(true)
	overview_preferences.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("deviation", 0.0)) > float(b.get("deviation", 0.0)))

	var overview_traits: Array = []
	for trait_value in traits:
		if bool((trait_value as Dictionary).get("core", false)):
			overview_traits.append(trait_value)
			if overview_traits.size() >= 2:
				break
	if overview_traits.size() < 2:
		for trait_value in traits:
			if overview_traits.has(trait_value):
				continue
			overview_traits.append(trait_value)
			if overview_traits.size() >= 2:
				break

	var prestige_q16 := int(row.get("prestige_score_q16", 0))
	var prestige_percent := float(prestige_q16) * 100.0 / 65536.0
	var level := int(row.get("prestige_level", 0))
	return {
		"kind": "family_workspace",
		"row_id": String(detail.get("row_id", "")),
		"header": {
			"name": String(detail.get("name", row.get("name", "家族档案"))),
			"subtitle": String(detail.get("subtitle", "")),
			"crest_icon": "family.workspace.crest",
			"prestige_level": level,
			"prestige_label": _prestige_text(level),
			"prestige_score_q16": prestige_q16,
			"prestige_percent": prestige_percent,
			"prestige_progress_text": _q16_percent_text(prestige_q16),
		},
		"summary": [
			{"id": "population", "label": "本家族人口",
				"value": String(row.get("population", "0")),
				"icon": "family.metric.population"},
			{"id": "net_worth", "label": "净资产",
				"value": String(row.get("net_worth", row.get("cash_claim", "0"))),
				"icon": "family.metric.wealth"},
			{"id": "owned_buildings", "label": "产业数",
				"value": String(row.get("owned_buildings", "0")),
				"icon": "family.metric.buildings"},
			{"id": "founded_day", "label": "创立时间",
				"value": "第%d日" % int(row.get("founded_day", 0)),
				"icon": "family.metric.time"},
		],
		"pages": {
			"overview": {
				"traits": overview_traits,
				"preferences": overview_preferences.slice(0, 4),
				"effects": effects.slice(0, 4),
				"people": people.slice(0, 5),
			},
			"traits": traits,
			"preferences": sorted_preferences,
			"effects": effects,
			"people": people,
			"branches": branches,
		},
		"actions": {"family_handle": int(row.get("family_handle", 0))},
	}


## Facade snapshots may contain the same presentation row through multiple legacy
## lanes.  The workspace is a player-facing projection, so collapse only rows that
## are semantically identical; effects retain their cell in the key to preserve
## same-name effects bound to different branches.
static func _family_unique_traits(rows: Array) -> Array:
	var result: Array = []
	var seen: Dictionary = {}
	for row_value in rows:
		if not row_value is Dictionary:
			continue
		var item := (row_value as Dictionary).duplicate(true)
		var detail_key := _family_text_key(item.get("detail", ""))
		var effect_key := _family_text_key(item.get("effect_summary", ""))
		if not effect_key.is_empty() and effect_key == detail_key:
			item["effect_summary"] = ""
			effect_key = ""
		var stable_id := _family_text_key(item.get("id", ""))
		var key := "id:%s" % stable_id if not stable_id.is_empty() else \
			"%s|%s|%s" % [_family_text_key(item.get("name", "")),
			detail_key, effect_key]
		if seen.has(key):
			continue
		seen[key] = true
		result.append(item)
	return result


static func _family_unique_preferences(rows: Array) -> Array:
	var result: Array = []
	var result_index: Dictionary = {}
	for row_value in rows:
		if not row_value is Dictionary:
			continue
		var item := (row_value as Dictionary).duplicate(true)
		var axis_key := _family_text_key(item.get("axis", item.get("axis_name", "")))
		var key := "%s|%s" % [axis_key, _family_text_key(item.get("name", ""))]
		var deviation := absf(float(item.get("factor_percent", 100.0)) - 100.0)
		if not result_index.has(key):
			result_index[key] = result.size()
			result.append(item)
			continue
		var index := int(result_index[key])
		var current: Dictionary = result[index]
		var current_deviation := absf(
			float(current.get("factor_percent", 100.0)) - 100.0)
		if deviation > current_deviation:
			result[index] = item
	return result


static func _family_unique_rows(rows: Array, key_fields: Array) -> Array:
	var result: Array = []
	var seen: Dictionary = {}
	for row_value in rows:
		if not row_value is Dictionary:
			continue
		var item := (row_value as Dictionary).duplicate(true)
		var parts: Array[String] = []
		for field_value in key_fields:
			parts.append(_family_text_key(item.get(str(field_value), "")))
		var key := "|".join(parts)
		if seen.has(key):
			continue
		seen[key] = true
		result.append(item)
	return result


static func _family_text_key(value: Variant) -> String:
	return str(value).strip_edges().replace(" ", "").replace("\n", "").replace("\r", "")


func _decorate_category_with_tax(
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
	var context := _tax_context_for_cell(cell_idx, tab_contract.get("tax_kinds", []))
	category["tax_context"] = context
	if not bool(context.get("available", false)):
		return category
	var policy: Dictionary = context.get("policy", {})
	var row_key := String(tab_contract.get("row_key", ""))
	var object_kind := String(tab_contract.get("object_kind", ""))
	var rows: Array = category.get(row_key, [])
	for row_value in rows:
		var row: Dictionary = row_value
		var item_id := _object_tax_item_id(object_kind, row)
		row["tax_lanes"] = _tax_lanes_from_policy(
			policy, object_kind, item_id, bool(context.get("editable", false)))
	# The raw snapshot is only an internal construction aid. Components consume the
	# bounded lane dictionaries and must never retain the facade snapshot itself.
	context.erase("policy")
	category["tax_context"] = context
	return category


func _tax_context_for_cell(cell_idx: int, kinds: Array) -> Dictionary:
	# default_lanes 是地块税种默认，供人口/市场/建筑页渲染；对象详情只用 row.tax_lanes。
	var country := _country_summary(cell_idx)
	if not bool(country.get("ok", false)) or not bool(country.get("owned", false)):
		return {"available": false, "editable": false,
			"reason": "无主之地没有税收政策", "cell": cell_idx,
			"default_lanes": []}
	var facade = _generator.get_country_facade() if _generator != null \
		and _generator.has_method("get_country_facade") else null
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
	var editable := owner_handle == _player_country_handle()
	var defaults: Array = []
	var country_defaults: PackedInt32Array = policy.get(
		"country_default_rates", PackedInt32Array())
	var local_defaults: PackedInt32Array = policy.get(
		"local_default_rates", PackedInt32Array())
	var local_flags: PackedByteArray = policy.get(
		"has_local_default", PackedByteArray())
	for kind_value in kinds:
		var kind := String(kind_value)
		var kind_id := int(TAX_KIND_IDS.get(kind, -1))
		if kind_id < 0:
			continue
		var inherited := int(country_defaults[kind_id]) \
			if kind_id < country_defaults.size() else 0
		var overridden := kind_id < local_flags.size() and local_flags[kind_id] != 0
		var rate := int(local_defaults[kind_id]) \
			if overridden and kind_id < local_defaults.size() else inherited
		defaults.append({
			"scope": "default", "kind": kind,
			"kind_label": String(TAX_DEFAULT_LABELS.get(kind,
				TAX_KIND_LABELS.get(kind, kind))),
			"accent": TAX_KIND_ACCENTS.get(kind, UITokens.ACCENT),
			"item_id": "", "base": rate, "effective": rate,
			"default_rate": inherited, "has_override": overridden,
			"editable": editable,
		})
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
		"policy": policy,
	}


func _tax_lanes_from_policy(
		policy: Dictionary,
		object_kind: String,
		item_id: String,
		editable: bool
) -> Array:
	var lanes: Array = []
	if item_id.is_empty():
		return lanes
	var country_defaults: PackedInt32Array = policy.get(
		"country_default_rates", PackedInt32Array())
	var local_defaults: PackedInt32Array = policy.get(
		"local_default_rates", PackedInt32Array())
	var local_flags: PackedByteArray = policy.get(
		"has_local_default", PackedByteArray())
	for kind_value in OBJECT_TAX_KINDS.get(object_kind, []):
		var kind := String(kind_value)
		var group: Dictionary = policy.get(kind, {})
		var ids: PackedStringArray = group.get("item_ids", PackedStringArray())
		var item_index := ids.find(item_id)
		var rates: PackedInt32Array = group.get(
			"final_base_rates", PackedInt32Array())
		if item_index < 0 or item_index >= rates.size():
			continue
		var effective: PackedInt32Array = group.get("effective_rates", rates)
		var item_flags: PackedByteArray = group.get(
			"has_local_item", PackedByteArray())
		var country_bases: PackedInt32Array = group.get(
			"country_base_rates", PackedInt32Array())
		var kind_id := int(TAX_KIND_IDS.get(kind, -1))
		var inherited := int(local_defaults[kind_id]) \
			if kind_id >= 0 and kind_id < local_flags.size() \
			and local_flags[kind_id] != 0 and kind_id < local_defaults.size() \
			else (int(country_bases[item_index]) \
				if item_index < country_bases.size() else (int(country_defaults[kind_id]) \
					if kind_id >= 0 and kind_id < country_defaults.size() else 0))
		lanes.append({
			"scope": "item", "kind": kind,
			"kind_label": String(TAX_KIND_LABELS.get(kind, kind)),
			"accent": TAX_KIND_ACCENTS.get(kind, UITokens.ACCENT),
			"item_id": item_id, "base": int(rates[item_index]),
			"effective": int(effective[item_index]) \
				if item_index < effective.size() else int(rates[item_index]),
			"has_override": item_index < item_flags.size() \
				and item_flags[item_index] != 0,
			"default_rate": inherited, "editable": editable,
		})
	return lanes


func _object_tax_item_id(kind: String, row: Dictionary) -> String:
	match kind:
		"cohort":
			return String(row.get("profession_id", ""))
		"building":
			return String(row.get("building_type_id", ""))
		"good":
			return String(row.get("good_id", ""))
	return ""


# 弹窗标题永远是用户可读名：行内 name 缺失或退化为原始 stable id 时，
# 用最新人口快照的平行数组把 profession_id 翻译回本地化名；仍失败才落到类型名。
func _object_display_name(kind: String, row: Dictionary, cell_idx: int) -> String:
	var name := String(row.get("name", ""))
	if kind == "cohort":
		var profession_id := String(row.get("profession_id", ""))
		if name.is_empty() or name == profession_id:
			var localized := _profession_name_for_id(_population_snapshot(cell_idx), profession_id)
			if not localized.is_empty():
				name = localized
	if name.is_empty():
		name = String(OBJECT_TYPE_LABELS.get(kind, "对象"))
	return name


func _profession_name_for_id(snapshot: Dictionary, profession_id: String) -> String:
	if profession_id.is_empty():
		return ""
	var ids: PackedStringArray = snapshot.get("profession_stable_ids", PackedStringArray())
	var names: PackedStringArray = snapshot.get("profession_display_names", PackedStringArray())
	var at := ids.find(profession_id)
	return String(names[at]) if at >= 0 and at < names.size() else ""


func _cell_tax_policy_version(cell_idx: int) -> int:
	var category := _cell_tax_category(cell_idx)
	var policy: Dictionary = category.get("cell_tax_policy", {})
	return int(policy.get("policy_version", -1))


func _cell_tax_category(cell_idx: int) -> Dictionary:
	var country := _country_summary(cell_idx)
	if not bool(country.get("ok", false)) or not bool(country.get("owned", false)):
		return {}
	var facade = _generator.get_country_facade() if _generator != null \
		and _generator.has_method("get_country_facade") else null
	if facade == null or not facade.has_method("cell_tax_policy_snapshot"):
		return {}
	var policy: Dictionary = facade.cell_tax_policy_snapshot(cell_idx)
	if not bool(policy.get("ok", false)):
		return {}
	policy["editable"] = int(policy.get("country_handle", 0)) == \
		_player_country_handle()
	policy["current_day"] = int(facade.report().get("last_committed_day", -1)) \
		if facade.has_method("report") else -1
	return {"cell_tax_policy": policy}


func _colonization_action(cell_idx: int, intel_visible: bool, passable_land: bool,
		is_water: bool, country_summary: Dictionary) -> Dictionary:
	var owned := bool(country_summary.get("owned", false))
	var player_owned := owned and int(country_summary.get("country_handle", 0)) \
		== _player_country_handle()
	var available := intel_visible and passable_land and not is_water \
		and (not owned or player_owned)
	var kind := "relocate" if player_owned else "colonize"
	return {
		"available": available,
		"kind": kind,
		"target_cell": cell_idx,
		"reason": "" if available else "目标必须是当前可见、可通行的无主或本国陆地。",
	}


func _player_country_handle() -> int:
	if _player_country_resolved:
		return _player_country_handle_cache
	_player_country_handle_cache = -1
	if _generator != null and _generator.has_method("gameplay_start_report"):
		var start_report: Dictionary = _generator.gameplay_start_report()
		var start_cell := int(start_report.get("cell", -1))
		if bool(start_report.get("ok", false)) and start_cell >= 0:
			var summary := _country_summary(start_cell)
			if bool(summary.get("ok", false)) and bool(summary.get("owned", false)):
				_player_country_handle_cache = int(summary.get("country_handle", -1))
				_player_country_resolved = true
	return _player_country_handle_cache


func _build_header(
	off: Vector2i,
	terrain_v: int,
	landform_v: int,
	country_summary: Dictionary,
	population_summary: Dictionary = {}
) -> Dictionary:
	var country_name := String(country_summary.get("country_name", "无主之地"))
	# terrain_v is the legacy-stable bioclimatic/biome axis. Keep its value in
	# the compact header; the detailed climate-zone label lives in the geography tab.
	var title := "%s · %s" % [
		LandformType.name_cn(landform_v), TerrainType.terrain_name_cn(terrain_v)]
	if bool(population_summary.get("settlement_name_active", false)):
		title = "%s · %s" % [
			String(population_summary.get("settlement_name", "")),
			String(population_summary.get("prosperity_name", ""))]
	return {
		"title": title,
		"subtitle": "区域 %d, %d · %s" % [off.x + 1, off.y + 1, country_name],
	}


func _summary_cards(
	temp: float,
	moist: float,
	population_snapshot: Dictionary,
	country_summary: Dictionary
) -> Array:
	var population_ready := bool(population_snapshot.get("ok", false))
	var population_value := "%s 人" % UITokens.format_compact_number_cn(
		float(population_snapshot.get("population", 0)), 1) if population_ready else "未就绪"
	var cards := [
		{
			"id": "summary_climate",
			"title": "气候",
			"value": "%s · %s" % [_temperature_band(temp), _moisture_band(moist)],
			"subtitle": "",
			"accent": UITokens.CLIMATE,
			"icon": "sun",
		},
		{
			"id": "summary_population",
			"title": "人口",
			"value": population_value,
			"subtitle": "%d 个阶层" % int(population_snapshot.get("cohort_count", 0)) if population_ready else "尚无人口",
			"accent": UITokens.ACCENT,
			"icon": "growth",
		},
		{
			"id": "summary_prosperity",
			"title": "繁荣度",
			"value": String(population_snapshot.get(
				"prosperity_name", "未就绪")) if population_ready else "未就绪",
			"subtitle": String(population_snapshot.get(
				"settlement_name", "尚未形成有名聚居地")) \
				if population_ready else "聚落尚未成形",
			"accent": UITokens.GOOD,
			"icon": "building",
		},
		{
			"id": "summary_country",
			"title": "国家",
			"value": String(country_summary.get("country_name", "无主之地")),
			"subtitle": "%s · 物资 %d 类 · 科技 %d 项" % [
				_money_text(int(country_summary.get("cash", 0))),
				int(country_summary.get("nonzero_good_count", 0)),
				int(country_summary.get("technology_count", 0)),
			],
			"accent": UITokens.RESOURCE,
			"icon": "resource",
		},
	]
	return cards


func _overview_category(cell: HexCell, idx: int, cover_v: int) -> Dictionary:
	return {
		"metrics": [
			{"id": "overview_weather", "title": "当前天气", "value": _weather_name(cell, idx), "subtitle": _intensity_text(_weather_intensity(cell, idx)), "accent": UITokens.WATER, "icon": "weather"},
			{"id": "overview_cover", "title": "地表覆盖", "value": CoverType.name_cn(cover_v), "subtitle": "", "accent": UITokens.GEO, "icon": "surface"},
		],
	}


func _geography_information_category(
		cell: HexCell,
		idx: int,
		terrain_v: int,
		landform_v: int,
		vegetation_v: int,
		cover_v: int,
		elev: float,
		temp: float,
		moist: float,
		base_moist: float,
		wf: Dictionary,
		snow: float,
		vitality: float,
		passable_land: bool,
		is_water: bool
) -> Dictionary:
	var geography := _geography_category(cell, idx, terrain_v, elev, passable_land)
	var climate := _climate_category(cell, idx, temp, moist, base_moist, wf)
	var hydrology := _hydrology_category(cell, idx, wf, snow, is_water)
	var ecology := _ecology_category(cell, idx, vegetation_v, vitality)
	var physical_metrics := [
		{"id": "geography_landform", "title": "地貌", "value": LandformType.name_cn(landform_v), "subtitle": "陆路%s" % ("可通" if passable_land else "阻断"), "accent": UITokens.GEO, "icon": "geo"},
		{"id": "geography_cover", "title": "地表覆盖", "value": CoverType.name_cn(cover_v), "subtitle": "", "accent": UITokens.WATER, "icon": "surface"},
	]
	physical_metrics.append_array(geography.get("metrics", []))
	# Keep the legacy metric id for live-patch compatibility, but render the
	# value in the climate section under its actual biome/climate-zone meaning.
	var climate_metrics: Array = [
		{"id": "geography_terrain", "title": "气候区", "value": TerrainType.terrain_name_cn(terrain_v), "subtitle": "地表通行成本 %d" % TerrainType.get_move_cost(terrain_v), "accent": UITokens.CLIMATE, "icon": "climate"},
	]
	climate_metrics.append_array(climate.get("metrics", []))
	climate_metrics.append_array(hydrology.get("metrics", []))
	climate_metrics.append({"id": "climate_weather", "title": "当前天气", "value": _weather_name(cell, idx), "subtitle": _intensity_text(_weather_intensity(cell, idx)), "accent": UITokens.WATER, "icon": "weather"})
	var climate_gauges: Array = climate.get("gauges", []).duplicate()
	climate_gauges.append_array(hydrology.get("gauges", []))
	var category := {
		"sections": [
			{
				"id": "physical_geography",
				"title": "地貌与地表",
				"icon": "geo",
				"accent": UITokens.GEO,
				"insights": geography.get("insights", []),
				"metrics": physical_metrics,
				"gauges": geography.get("gauges", []),
			},
			{
				"id": "climate_hydrology",
				"title": "气候区与水文",
				"icon": "water",
				"accent": UITokens.WATER,
				"collapsed": true,
				"metrics": climate_metrics,
				"gauges": climate_gauges,
				"charts": climate.get("charts", []),
			},
			{
				"id": "vegetation_ecology",
				"title": "植被与生态",
				"icon": "eco",
				"accent": UITokens.ECO,
				"collapsed": true,
				"insights": ecology.get("insights", []),
				"metrics": ecology.get("metrics", []),
				"gauges": ecology.get("gauges", []),
				"charts": ecology.get("charts", []),
			},
		],
	}
	_append_bio_facts_to_geography(category, idx, _resource_visibility_context(idx))
	return category


func _append_resources_to_geography(category: Dictionary, idx: int,
		is_water: bool) -> void:
	var visibility := _resource_visibility_context(idx)
	var resource_section := _resources_category(
		_resource_state(idx, is_water, visibility), visibility)
	resource_section["id"] = "natural_resources"
	resource_section["title"] = "自然资源"
	resource_section["icon"] = "eco"
	resource_section["accent"] = UITokens.RESOURCE
	var sections: Array = category.get("sections", [])
	sections.append(resource_section)
	category["sections"] = sections


## 本地物种是当前占领层目击，会随气候、植被、承载储量和人类活动变化。
## 不是可采集储量；国家知识另计，局部灭绝不会撤销已发现证据。
func _append_bio_facts_to_geography(category: Dictionary, idx: int,
		visibility: Dictionary = {}) -> void:
	var badges := _cell_bio_badges(idx, visibility)
	if badges.is_empty():
		return
	var section := {
		"id": "biogeography",
		"title": "本地物种",
		"icon": "crop",
		"accent": UITokens.ECO,
		"insights": [{
			"id": "biogeography_note",
			"text": "目击物种 · 非储量",
			"accent": UITokens.ECO,
			"icon": "crop",
		}],
		"badges": badges,
	}
	var sections: Array = category.get("sections", [])
	sections.append(section)
	category["sections"] = sections


func _cell_bio_badges(idx: int, visibility: Dictionary = {}) -> Array:
	if _map == null or idx < 0:
		return []
	var catalog := _ensure_research_signal_catalog()
	if catalog.is_empty():
		return []
	if idx >= _map.bio_occupancy_bits_arr.size():
		return []
	var bits := int(_map.bio_occupancy_bits_arr[idx])
	if bits == 0:
		return []
	var kinds: PackedInt32Array = catalog.get("research_signal_kinds", PackedInt32Array())
	var names: PackedStringArray = catalog.get("research_signal_display_names", PackedStringArray())
	var signal_ids: PackedStringArray = catalog.get("research_signal_ids", PackedStringArray())
	var occupancy_bits: PackedInt32Array = catalog.get("research_signal_occupancy_bit", PackedInt32Array())
	var kind_count := mini(kinds.size(), mini(names.size(), mini(signal_ids.size(), occupancy_bits.size())))
	var enforce_discovery := bool(visibility.get("enforce_discovery", false))
	var technology_ids: PackedStringArray = visibility.get(
		"technology_ids", PackedStringArray())
	var technology_catalog := {}
	if enforce_discovery:
		technology_catalog = _ensure_technology_catalog()
	var badges := []
	for signal_index in range(kind_count):
		if int(kinds[signal_index]) != ResearchSignalDefinition.Kind.BIO:
			continue
		var bit := int(occupancy_bits[signal_index])
		if bit < 0 or bit >= 32 or (bits & (1 << bit)) == 0:
			continue
		var signal_id := String(signal_ids[signal_index])
		if enforce_discovery and not TechnologyCatalog.signal_named_by_completed_technologies(
				signal_id, technology_ids, technology_catalog):
			continue
		var display_name := String(names[signal_index])
		if display_name.is_empty():
			continue
		badges.append({
			"id": signal_id,
			"text": display_name,
			"accent": UITokens.ECO,
		})
	return badges


func _ensure_research_signal_catalog() -> Dictionary:
	if not _research_signal_catalog.is_empty():
		return _research_signal_catalog
	var compiled: Dictionary = ResearchSignalCatalog.compile_native_catalog()
	if not bool(compiled.get("ok", false)):
		return {}
	_research_signal_catalog = compiled
	return _research_signal_catalog


func _ensure_technology_catalog() -> Dictionary:
	if not _technology_catalog.is_empty():
		return _technology_catalog
	var compiled: Dictionary = TechnologyCatalog.compile_native_catalog()
	if not bool(compiled.get("ok", false)):
		return {}
	_technology_catalog = compiled
	return _technology_catalog


func _rows_from_category(category: Dictionary, rows_key: String) -> Array:
	var rows: Array = category.get(rows_key, [])
	if not rows.is_empty():
		return rows
	for raw_section in category.get("sections", []):
		var section: Dictionary = raw_section
		rows = section.get(rows_key, [])
		if not rows.is_empty():
			return rows
	return []


func _geography_category(cell: HexCell, idx: int, terrain_v: int, elev: float, passable_land: bool) -> Dictionary:
	var feats := PackedStringArray()
	if _has_river(cell, idx): feats.append("河流")
	if cell.has_volcano: feats.append("火山")
	if cell.is_lake_seed: feats.append("湖泊种子")
	var metrics := []
	if not feats.is_empty():
		metrics.append({
			"id": "geography_features",
			"title": "地理特征",
			"value": "、".join(feats),
			"subtitle": "",
			"accent": UITokens.WATER,
			"icon": "target",
		})
	return {
		"insights": [
			{"id": "geography_passage", "text": "陆路%s · 海路%s · 移动成本 %d" % ["可通" if passable_land else "阻断", "可通" if cell.passable_sea else "阻断", TerrainType.get_move_cost(terrain_v)], "accent": UITokens.ACCENT, "icon": "target"},
		],
		"metrics": metrics,
		"gauges": [
			{"id": "geography_elevation_gauge", "label": "高程", "value": elev, "accent": UITokens.GEO, "marker": _sea_level, "status_label": _elevation_band(elev, _sea_level), "value_text": _relative_sea_level_text(elev, _sea_level)},
		],
	}


func _climate_category(cell: HexCell, idx: int, temp: float, moist: float, base_moist: float, wf: Dictionary) -> Dictionary:
	return {
		"metrics": [
			{"id": "climate_precip", "title": "降水", "value": _precip_band(float(wf["precip"])), "subtitle": _cloud_band(float(wf["cloud"])), "accent": UITokens.WATER, "icon": "weather"},
		],
		"gauges": [
			{"id": "climate_temp_gauge", "label": "温度", "value": temp, "accent": UITokens.CLIMATE, "status_label": _temperature_band(temp), "value_text": "%.0f%%" % (temp * 100.0)},
			{"id": "climate_moisture_gauge", "label": "湿度", "value": moist, "accent": UITokens.WATER, "marker": base_moist, "status_label": _moisture_band(moist), "value_text": "%.0f%%" % (moist * 100.0)},
		],
		"charts": [_temperature_chart("climate_temperature", "近期温度变化", idx, temp)],
	}


func _hydrology_category(cell: HexCell, idx: int, wf: Dictionary, snow: float, is_water: bool) -> Dictionary:
	var ocean := _ocean_current(cell, idx)
	var wind := _wind_vector(cell, idx)
	var upwelling := _upwelling(cell, idx)
	var metrics := [
		{"id": "hydrology_wind", "title": "风向", "value": _dir_degrees_text(wind), "subtitle": "", "accent": UITokens.ACCENT, "icon": "wind"},
	]
	if is_water:
		metrics.append({"id": "hydrology_current", "title": "洋流", "value": "%.3f" % ocean.length(), "subtitle": _dir_degrees_text(ocean), "accent": UITokens.WATER, "icon": "water"})
		metrics.append({"id": "hydrology_upwelling", "title": "上升流", "value": "%+.3f" % upwelling, "subtitle": "", "accent": UITokens.WATER, "icon": "trend_up"})
	return {
		"metrics": metrics,
		"gauges": [
			{"id": "hydrology_vapor_gauge", "label": "水汽", "value": float(wf["vapor"]), "accent": UITokens.WATER, "status_label": _moisture_band(float(wf["vapor"])), "value_text": "%.0f%%" % (float(wf["vapor"]) * 100.0)},
			{"id": "hydrology_cloud_gauge", "label": "云量", "value": float(wf["cloud"]), "accent": UITokens.WATER, "status_label": _cloud_band(float(wf["cloud"])), "value_text": "%.0f%%" % (float(wf["cloud"]) * 100.0)},
			{"id": "hydrology_precip_gauge", "label": "降水", "value": float(wf["precip"]), "accent": UITokens.WATER, "status_label": _precip_band(float(wf["precip"])), "value_text": "%.0f%%" % (float(wf["precip"]) * 100.0)},
			{"id": "hydrology_snow_gauge", "label": "雪盖/海冰", "value": snow, "accent": UITokens.WATER, "status_label": _cover_intensity_band(snow), "value_text": "%.0f%%" % (snow * 100.0)},
		],
	}


func _ecology_category(cell: HexCell, idx: int, vegetation_v: int, vitality: float) -> Dictionary:
	var stress_heat: float = _adapter_float("get_vegetation_heat_stress", idx, cell.vegetation_heat_stress)
	var stress_drought: float = _adapter_float("get_vegetation_drought_stress", idx, cell.vegetation_drought_stress)
	var stress_cold: float = _adapter_float("get_vegetation_cold_stress", idx, cell.vegetation_cold_stress)
	var regen: float = _adapter_float("get_vegetation_regen_score", idx, cell.vegetation_regen_score)
	var countdown := _succession_text(cell)
	var insights := []
	if countdown != "":
		insights.append({
			"id": "ecology_succession",
			"text": countdown,
			"accent": UITokens.ECO if vitality >= 0.45 else UITokens.RISK,
			"icon": "growth",
		})
	return {
		"insights": insights,
		"metrics": [
			{"id": "ecology_vegetation", "title": "当前植被", "value": VegetationType.name_cn(vegetation_v), "subtitle": "生态基线 %s" % VegetationType.name_cn(cell.base_vegetation), "accent": UITokens.ECO, "icon": "eco"},
		],
		"gauges": [
			{"id": "ecology_regen_gauge", "label": "恢复潜力", "value": regen, "accent": UITokens.ECO, "status_label": _vitality_band(regen), "value_text": "%.2f" % regen},
			{"id": "ecology_heat_gauge", "label": "热胁迫", "value": stress_heat, "accent": UITokens.CLIMATE, "status_label": _stress_band(stress_heat), "value_text": "%.2f" % stress_heat},
			{"id": "ecology_drought_gauge", "label": "旱胁迫", "value": stress_drought, "accent": UITokens.WARN, "status_label": _stress_band(stress_drought), "value_text": "%.2f" % stress_drought},
			{"id": "ecology_cold_gauge", "label": "冷胁迫", "value": stress_cold, "accent": UITokens.WATER, "status_label": _stress_band(stress_cold), "value_text": "%.2f" % stress_cold},
		],
		"charts": [{"id": "ecology_history", "title": "植被历史", "values": _history_values(cell), "accent": UITokens.ECO}],
	}


func _resources_category(resource_state: Array, visibility: Dictionary = {}) -> Dictionary:
	var rows := []
	var insights := []
	ResourceProfileRegistry.ensure_loaded()
	if ResourceProfileRegistry.count() <= 0:
		return {"insights": [{
			"id": "resource_unconfigured",
			"text": "尚未配置自然资源类型。",
			"accent": UITokens.TEXT_MUTED,
			"icon": "resource",
		}]}
	if resource_state.is_empty():
		var gated := bool(visibility.get("enforce_discovery", false))
		return {"insights": [{
			"id": "resource_undiscovered" if gated else "resource_empty",
			"text": "当前科技尚未识别此地资源。" if gated \
				else "此地块当前无可显示自然资源。",
			"accent": UITokens.TEXT_MUTED,
			"icon": "resource",
		}]}
	var sorted := resource_state.duplicate()
	sorted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("rank", 0.0)) > float(b.get("rank", 0.0))
	)
	var notable_count := 0
	var visible_count := 0
	for data in sorted:
		var item: Dictionary = data
		if not bool(item.get("available", true)):
			continue
		var reserve := float(item.get("reserve", 0.0))
		var delta := float(item.get("delta", 0.0))
		var density := _resource_density_band(float(item.get("density_ratio", 0.0)))
		rows.append({
			"id": String(item.get("id", item.get("name", "resource"))),
			"name": String(item.get("name", "资源")),
			"value": _resource_index_text(reserve),
			"density": density,
			"delta": _daily_delta_text(delta),
			"extractable": bool(item.get("extractable", true)),
			"accent": UITokens.RESOURCE,
			"icon": String(item.get("icon", "resource")),
			"visible": reserve > 0.000001,
		})
		if reserve <= 0.000001:
			continue
		visible_count += 1
		if notable_count < 3 and (reserve > 0.65 or absf(delta) > 0.0005):
			insights.append({
				"id": "resource_notable_%s" % String(item.get("id", notable_count)),
				"text": "%s · %s · %s" % [String(item.get("name", "资源")), density, _daily_delta_text(delta)],
				"accent": UITokens.RESOURCE,
				"icon": String(item.get("icon", "resource")),
			})
			notable_count += 1
	if visible_count == 0:
		return {
			"insights": [{"id": "resource_empty", "text": "此地块当前无可显示自然资源。", "accent": UITokens.TEXT_MUTED, "icon": "resource"}],
			"resource_rows": rows,
		}
	if insights.is_empty():
		insights.append({"id": "resource_stable", "text": "资源储量总体平缓", "accent": UITokens.TEXT_MUTED, "icon": "resource"})
	return {"insights": insights, "resource_rows": rows}


func _history_category(cell: HexCell) -> Dictionary:
	return {
		"insights": [{"id": "history_summary", "text": _history_sentence(cell), "accent": UITokens.ECO, "icon": "history"}],
		"charts": [
			{"id": "history_vegetation", "title": "近期植被序列", "values": _history_values(cell), "accent": UITokens.ECO},
			_temperature_chart("history_temperature", "近期温度变化", int(cell.index), _temp(cell, int(cell.index))),
		],
		"badges": _history_badges(cell),
	}


func _population_snapshot(cell_idx: int, include_details: bool = true) -> Dictionary:
	if _generator == null or not _generator.has_method("get_economy_facade"):
		return {}
	var facade = _generator.get_economy_facade()
	if facade == null or not facade.has_method("population_cell_snapshot"):
		return {}
	return facade.population_cell_snapshot(cell_idx, include_details)


func _population_summary(cell_idx: int) -> Dictionary:
	if _generator == null or not _generator.has_method("get_economy_facade"):
		return {}
	var facade = _generator.get_economy_facade()
	if facade == null or not facade.has_method("population_cell_summary"):
		return {}
	return facade.population_cell_summary(cell_idx)


func _country_summary(cell_idx: int) -> Dictionary:
	if _generator == null or not _generator.has_method("get_country_facade"):
		return {"country_name": "无主之地"}
	var facade = _generator.get_country_facade()
	if facade == null or not facade.has_method("cell_summary"):
		return {"country_name": "无主之地"}
	var summary: Dictionary = facade.cell_summary(cell_idx)
	return summary if bool(summary.get("ok", false)) else {"country_name": "无主之地"}


func _market_snapshot(cell_idx: int) -> Dictionary:
	if _generator == null or not _generator.has_method("get_economy_facade"):
		return {}
	var facade = _generator.get_economy_facade()
	if facade == null or not facade.has_method("market_cell_snapshot"):
		return {}
	return facade.market_cell_snapshot(cell_idx)


func _building_snapshot(cell_idx: int) -> Dictionary:
	if _generator == null or not _generator.has_method("get_economy_facade"):
		return {}
	var facade = _generator.get_economy_facade()
	if facade == null or not facade.has_method("building_cell_snapshot"):
		return {}
	return facade.building_cell_snapshot(cell_idx)


func _family_cell_snapshot(cell_idx: int) -> Dictionary:
	if _generator == null or not _generator.has_method("get_economy_facade"):
		return {}
	var facade = _generator.get_economy_facade()
	if facade == null or not facade.has_method("family_cell_snapshot"):
		return {}
	return facade.family_cell_snapshot(cell_idx, 0, 64)


func _family_category(snapshot: Dictionary) -> Dictionary:
	if snapshot.is_empty() or not bool(snapshot.get("ok", false)):
		return {"insights": [{"id": "families_unavailable", "text":
			"家族情报暂不可用。", "accent": UITokens.TEXT_MUTED,
			"icon": "family.house"}]}
	var handles: PackedInt64Array = snapshot.get("family_handles", PackedInt64Array())
	var surnames: PackedStringArray = snapshot.get("surnames", PackedStringArray())
	var family_names: PackedStringArray = snapshot.get(
		"family_names", PackedStringArray())
	var disambiguators: PackedInt32Array = snapshot.get(
		"surname_disambiguators", PackedInt32Array())
	var populations: PackedInt64Array = snapshot.get("populations", PackedInt64Array())
	var cash_claims: PackedInt64Array = snapshot.get("cash_claims", PackedInt64Array())
	var owned: PackedInt64Array = snapshot.get("owned_buildings", PackedInt64Array())
	var notable_people: PackedInt32Array = snapshot.get(
		"notable_person_counts", PackedInt32Array())
	var prestige_levels: PackedInt32Array = snapshot.get(
		"prestige_levels", PackedInt32Array())
	var rows: Array = []
	for i in range(surnames.size()):
		var suffix := "" if i >= disambiguators.size() or disambiguators[i] == 0 \
			else "（%d）" % (int(disambiguators[i]) + 1)
		var family_handle := int(handles[i]) if i < handles.size() else 0
		var display_name := String(family_names[i]).strip_edges() \
			if i < family_names.size() else ""
		if display_name.is_empty():
			display_name = "%s氏" % String(surnames[i])
		rows.append({
			"id": "family_%d" % family_handle,
			"family_handle": family_handle,
			"name": "%s%s" % [display_name, suffix],
			"population": UITokens.format_compact_number_cn(float(populations[i]), 1) if i < populations.size() else "0",
			"notable_people": int(notable_people[i]) if i < notable_people.size() else 0,
			"owned_buildings": UITokens.format_compact_number_cn(float(owned[i]), 1) if i < owned.size() else "0",
			"cash_claim": _money_text(int(cash_claims[i])) if i < cash_claims.size() else _money_text(0),
			"prestige": _prestige_text(int(prestige_levels[i])) \
				if i < prestige_levels.size() else "0",
			"accent": UITokens.ACCENT,
			"icon": "family.house",
		})
	if rows.is_empty():
		return {"insights": [{"id": "families_empty", "text":
			"此地尚无显赫家族。",
			"accent": UITokens.TEXT_MUTED, "icon": "family.house"}]}
	return {"family_rows": rows}


func _family_detail_fields(snapshot: Dictionary) -> Dictionary:
	return {
		"population": UITokens.format_compact_number_cn(float(snapshot.get("population", 0)), 1),
		"cash_claim": _money_text(int(snapshot.get("cash_claim", 0))),
		"productive_asset_value": _money_text(int(snapshot.get("productive_asset_value", 0))),
		"net_worth": _money_text(int(snapshot.get("net_worth", 0))),
		"owned_buildings": UITokens.format_compact_number_cn(float(snapshot.get("owned_buildings", 0)), 1),
		"notable_people": int(snapshot.get("notable_person_count", 0)),
		"founded_day": int(snapshot.get("founded_day", 0)),
		"decline_reviews": int(snapshot.get("decline_reviews", 0)),
	}


func _family_trait_rows(snapshot: Dictionary) -> Array:
	var rows: Array = []
	var names: PackedStringArray = snapshot.get("display_names", PackedStringArray())
	var keys: PackedStringArray = snapshot.get("trait_keys", PackedStringArray())
	var core: PackedByteArray = snapshot.get("core", PackedByteArray())
	var descriptions: PackedStringArray = snapshot.get("descriptions", PackedStringArray())
	for index in range(keys.size()):
		var detail := String(descriptions[index]).strip_edges() \
			if index < descriptions.size() else ""
		var is_core := index < core.size() and int(core[index]) != 0
		rows.append({
			"id": String(keys[index]),
			"key": String(keys[index]),
			"name": String(names[index]) if index < names.size() else String(keys[index]),
			"core": is_core,
			"kind": "core" if is_core else "additional",
			"kind_label": "核心特性" if is_core else "附加特性",
			"value": "核心特性" if is_core else "附加特性",
			"detail": detail,
			# 当前 facade 只提供一份说明文本；不要把它伪装成第二份效果摘要。
			"effect_summary": "",
			"tooltip": detail,
		})
	return rows


func _family_behavior_rows(snapshot: Dictionary, cell_idx: int = -1) -> Array:
	var rows: Array = []
	var visibility := _family_behavior_visibility(cell_idx)
	var axes: PackedInt32Array = snapshot.get("behavior_axes", PackedInt32Array())
	var stable_ids: PackedStringArray = snapshot.get(
		"behavior_selector_stable_ids", PackedStringArray())
	var names: PackedStringArray = snapshot.get(
		"behavior_selector_display_names", PackedStringArray())
	var factors: PackedInt32Array = snapshot.get(
		"behavior_factors_q16", PackedInt32Array())
	var axis_names := ["投资", "职业", "需求", "商品消费"]
	for index in range(axes.size()):
		var axis := int(axes[index])
		var stable_id := String(stable_ids[index]) if index < stable_ids.size() else ""
		if not _family_behavior_selector_visible(axis, stable_id, visibility):
			continue
		var factor_q16 := int(factors[index]) if index < factors.size() else 65536
		var factor_percent := float(factor_q16) * 100.0 / 65536.0
		var axis_name: String = axis_names[axis] if axis >= 0 \
			and axis < axis_names.size() else "行为"
		rows.append({
			"id": "%d:%s" % [axis, stable_id],
			"stable_id": stable_id,
			"axis": axis,
			"axis_name": axis_name,
			"name": String(names[index]) if index < names.size() else "目标 %d" % index,
			"factor_q16": factor_q16,
			"factor_percent": factor_percent,
			"factor_text": _q16_percent_text(factor_q16),
			"deviation": absf(factor_percent - 100.0),
			"value": "%s偏好 · %s" % [axis_name, _q16_percent_text(factor_q16)],
		})
	return rows


func _family_behavior_visibility(cell_idx: int) -> Dictionary:
	var result := {"buildings": {}, "goods": {}, "professions": {}, "needs": {},
		"enforce_buildings": false, "enforce_goods": false,
		"enforce_professions": false, "enforce_needs": false}
	if cell_idx < 0:
		return result
	var facade = _generator.get_economy_facade() if _generator != null \
		and _generator.has_method("get_economy_facade") else null
	if facade == null:
		return result
	var buildings: Dictionary = facade.building_cell_snapshot(cell_idx) \
		if facade.has_method("building_cell_snapshot") else {}
	var building_ids: PackedStringArray = buildings.get(
		"building_type_ids", PackedStringArray())
	var building_available: PackedByteArray = buildings.get(
		"building_technology_available", PackedByteArray())
	if building_available.size() == building_ids.size():
		result.enforce_buildings = true
		for index in range(building_ids.size()):
			if building_available[index] != 0:
				result.buildings[String(building_ids[index])] = true
	var market: Dictionary = facade.market_cell_snapshot(cell_idx) \
		if facade.has_method("market_cell_snapshot") else {}
	var good_ids: PackedStringArray = market.get("good_ids", PackedStringArray())
	var good_available: PackedByteArray = market.get(
		"good_technology_available", PackedByteArray())
	if good_available.size() == good_ids.size():
		result.enforce_goods = true
		for index in range(good_ids.size()):
			if good_available[index] != 0:
				result.goods[String(good_ids[index])] = true
		var catalog: Dictionary = facade.native_catalog() \
			if facade.has_method("native_catalog") else {}
		var need_visibility := _family_behavior_visible_needs(
			catalog, good_ids, good_available)
		if bool(need_visibility.get("ok", false)):
			result.needs = need_visibility.get("needs", {})
			result.enforce_needs = true
	var population: Dictionary = facade.population_cell_snapshot(cell_idx) \
		if facade.has_method("population_cell_snapshot") else {}
	result.professions = _family_behavior_visible_professions(buildings, population)
	result.enforce_professions = not (result.professions as Dictionary).is_empty()
	return result


static func _family_behavior_visible_professions(buildings: Dictionary,
		population: Dictionary) -> Dictionary:
	var catalog: PackedStringArray = population.get(
		"profession_stable_ids", PackedStringArray())
	if catalog.is_empty():
		catalog = buildings.get("profession_stable_ids", PackedStringArray())
	var hired := {}
	var type_ids: PackedStringArray = buildings.get(
		"building_type_ids", PackedStringArray())
	var type_available: PackedByteArray = buildings.get(
		"building_technology_available", PackedByteArray())
	var type_constructible: PackedByteArray = buildings.get(
		"building_construction_available", PackedByteArray())
	var type_counts: PackedInt64Array = buildings.get(
		"building_counts_by_type", PackedInt64Array())
	var owners: PackedInt32Array = buildings.get(
		"building_owner_profession_ids", PackedInt32Array())
	var employee_offsets: PackedInt32Array = buildings.get(
		"building_employee_offsets", PackedInt32Array())
	var employee_professions: PackedInt32Array = buildings.get(
		"building_employee_profession_ids", PackedInt32Array())
	var can_resolve_roles := not catalog.is_empty() \
		and owners.size() == type_ids.size() \
		and employee_offsets.size() == type_ids.size() + 1
	if can_resolve_roles:
		for type_index in range(type_ids.size()):
			var present := type_index < type_counts.size() \
				and int(type_counts[type_index]) > 0
			var unlocked := type_index < type_available.size() \
				and int(type_available[type_index]) != 0
			var constructible := type_index < type_constructible.size() \
				and int(type_constructible[type_index]) != 0
			if not present and not unlocked and not constructible:
				continue
			_add_profession_id(hired, catalog, int(owners[type_index]))
			var begin := int(employee_offsets[type_index])
			var end := int(employee_offsets[type_index + 1])
			for role in range(begin, end):
				if role >= 0 and role < employee_professions.size():
					_add_profession_id(hired, catalog, int(employee_professions[role]))
		hired["unemployed"] = true
		var row_professions: PackedInt32Array = population.get(
			"profession_ids", PackedInt32Array())
		for dense_id in row_professions:
			_add_profession_id(hired, catalog, int(dense_id))
	var available: PackedByteArray = population.get(
		"profession_technology_available", PackedByteArray())
	if available.size() == catalog.size() and not catalog.is_empty():
		if hired.is_empty() and not can_resolve_roles:
			for index in range(catalog.size()):
				if int(available[index]) != 0:
					hired[String(catalog[index])] = true
			return hired
		var filtered := {}
		for profession_id in hired.keys():
			var index := catalog.find(String(profession_id))
			if index >= 0 and int(available[index]) == 0:
				continue
			filtered[String(profession_id)] = true
		return filtered
	return hired


static func _add_profession_id(target: Dictionary, catalog: PackedStringArray,
		dense_id: int) -> void:
	if dense_id < 0 or dense_id >= catalog.size():
		return
	target[String(catalog[dense_id])] = true


static func _family_behavior_visible_needs(catalog: Dictionary,
		market_good_ids: PackedStringArray,
		good_available: PackedByteArray) -> Dictionary:
	var need_ids: PackedStringArray = catalog.get("need_ids", PackedStringArray())
	var good_ids: PackedStringArray = catalog.get("good_ids", PackedStringArray())
	var need_entries: PackedInt32Array = catalog.get(
		"need_stable_ids", PackedInt32Array())
	var need_variant_offsets: PackedInt32Array = catalog.get(
		"need_variant_offsets", PackedInt32Array())
	var variant_component_offsets: PackedInt32Array = catalog.get(
		"variant_component_offsets", PackedInt32Array())
	var component_good_ids: PackedInt32Array = catalog.get(
		"component_good_ids", PackedInt32Array())
	if need_ids.is_empty() or good_ids.is_empty() \
			or market_good_ids.size() != good_available.size() \
			or need_variant_offsets.size() != need_entries.size() + 1 \
			or variant_component_offsets.is_empty() \
			or variant_component_offsets[-1] != component_good_ids.size():
		return {"ok": false}
	var market_unlocks := {}
	for index in range(market_good_ids.size()):
		market_unlocks[String(market_good_ids[index])] = int(good_available[index]) != 0
	var visible := {}
	for entry in range(need_entries.size()):
		var need_index := int(need_entries[entry])
		if need_index < 0 or need_index >= need_ids.size():
			return {"ok": false}
		var variant_begin := int(need_variant_offsets[entry])
		var variant_end := int(need_variant_offsets[entry + 1])
		if variant_begin < 0 or variant_end <= variant_begin \
				or variant_end > variant_component_offsets.size() - 1:
			return {"ok": false}
		# A need is available when one complete substitute bundle can be bought
		# locally; partially unlocked bundles must not leak the preference row.
		for variant in range(variant_begin, variant_end):
			var component_begin := int(variant_component_offsets[variant])
			var component_end := int(variant_component_offsets[variant + 1])
			if component_begin < 0 or component_end <= component_begin \
					or component_end > component_good_ids.size():
				return {"ok": false}
			var variant_unlocked := true
			for component in range(component_begin, component_end):
				var good_index := int(component_good_ids[component])
				if good_index < 0 or good_index >= good_ids.size() \
						or not bool(market_unlocks.get(String(good_ids[good_index]), false)):
					variant_unlocked = false
					break
			if variant_unlocked:
				visible[String(need_ids[need_index])] = true
				break
	return {"ok": true, "needs": visible}


static func _family_behavior_selector_visible(axis: int, stable_id: String,
		visibility: Dictionary) -> bool:
	if stable_id.is_empty():
		return true
	if axis == 0 and bool(visibility.get("enforce_buildings", false)):
		return (visibility.get("buildings", {}) as Dictionary).has(stable_id)
	if axis == 3 and bool(visibility.get("enforce_goods", false)):
		return (visibility.get("goods", {}) as Dictionary).has(stable_id)
	if axis == 1 and bool(visibility.get("enforce_professions", false)):
		return (visibility.get("professions", {}) as Dictionary).has(stable_id)
	if axis == 2 and bool(visibility.get("enforce_needs", false)):
		return (visibility.get("needs", {}) as Dictionary).has(stable_id)
	return true


func _family_branch_rows(snapshot: Dictionary) -> Array:
	var rows: Array = []
	var cells: PackedInt32Array = snapshot.get("cell_indices", PackedInt32Array())
	var levels: PackedInt32Array = snapshot.get("prestige_levels", PackedInt32Array())
	var population_shares: PackedInt32Array = snapshot.get(
		"population_shares_q16", PackedInt32Array())
	var cash_shares: PackedInt32Array = snapshot.get(
		"cash_shares_q16", PackedInt32Array())
	var building_shares: PackedInt32Array = snapshot.get(
		"building_shares_q16", PackedInt32Array())
	var scores: PackedInt32Array = snapshot.get("prestige_scores_q16", PackedInt32Array())
	var targets: PackedInt32Array = snapshot.get(
		"pending_target_levels", PackedInt32Array())
	var streaks: PackedInt32Array = snapshot.get("review_streaks", PackedInt32Array())
	for index in range(cells.size()):
		var level := int(levels[index]) if index < levels.size() else 0
		var target := int(targets[index]) if index < targets.size() else level
		var cell := int(cells[index])
		var score_q16 := int(scores[index]) if index < scores.size() else 0
		var population_q16 := int(population_shares[index]) if index < population_shares.size() else 0
		var cash_q16 := int(cash_shares[index]) if index < cash_shares.size() else 0
		var building_q16 := int(building_shares[index]) if index < building_shares.size() else 0
		rows.append({
			"id": "branch:%d" % cell,
			"kind": "branch",
			"cell": cell,
			"prestige_level": level,
			"prestige_label": _prestige_text(level),
			"prestige_score_q16": score_q16,
			"prestige_percent": float(score_q16) * 100.0 / 65536.0,
			"prestige_text": _q16_percent_text(score_q16),
			"population_share_q16": population_q16,
			"population_share_text": _q16_percent_text(population_q16),
			"cash_share_q16": cash_q16,
			"cash_share_text": _q16_percent_text(cash_q16),
			"building_share_q16": building_q16,
			"building_share_text": _q16_percent_text(building_q16),
			"target_level": target,
			"target_label": _prestige_text(target),
			"review_streak": int(streaks[index]) if index < streaks.size() else 0,
			"name": "地块 %d · 威望 %s" % [cell, _prestige_text(level)],
			"value": "总分 %s · 人口 %s / 现金 %s / 建筑 %s · 目标 %s（%d/2）" % [
				_q16_percent_text(score_q16), _q16_percent_text(population_q16),
				_q16_percent_text(cash_q16), _q16_percent_text(building_q16),
				_prestige_text(target), int(streaks[index]) if index < streaks.size() else 0],
		})
	return rows


func _family_bound_effect_rows(snapshot: Dictionary) -> Array:
	var rows: Array = []
	var cell := int(snapshot.get("cell_idx", -1))
	var keys: PackedStringArray = snapshot.get(
		"effect_definition_keys", PackedStringArray())
	var names: PackedStringArray = snapshot.get(
		"effect_display_names", PackedStringArray())
	var descriptions: PackedStringArray = snapshot.get(
		"effect_descriptions", PackedStringArray())
	var current_descriptions: PackedStringArray = snapshot.get(
		"effect_current_descriptions", PackedStringArray())
	var seen := {}
	for index in range(keys.size()):
		var key := String(keys[index]).strip_edges()
		if key.is_empty() or seen.has(key):
			continue
		seen[key] = true
		var display := String(names[index]).strip_edges() \
			if index < names.size() else ""
		if display.is_empty():
			display = key
		var detail := String(descriptions[index]).strip_edges() \
			if index < descriptions.size() else ""
		var current := String(current_descriptions[index]).strip_edges() \
			if index < current_descriptions.size() else ""
		if current.is_empty():
			current = detail
		rows.append({
			"id": "effect:%d:%s" % [cell, key],
			"kind": "effect",
			"cell": cell,
			"effect_key": key,
			"title": display,
			"name": "地块 %d · %s" % [cell, display],
			"value": current,
			"detail": current,
			"tooltip": current,
		})
	return rows


func _family_modifier_rows(snapshot: Dictionary) -> Array:
	var rows: Array = []
	var cell := int(snapshot.get("cell_idx", -1))
	var keys: PackedStringArray = snapshot.get(
		"modifier_definition_keys", PackedStringArray())
	var names: PackedStringArray = snapshot.get(
		"modifier_display_names", PackedStringArray())
	var descriptions: PackedStringArray = snapshot.get(
		"modifier_descriptions", PackedStringArray())
	var magnitudes: PackedInt32Array = snapshot.get(
		"modifier_magnitude_q16", PackedInt32Array())
	for index in range(keys.size()):
		var key := String(keys[index])
		var display := String(names[index]).strip_edges() \
			if index < names.size() else ""
		if display.is_empty():
			display = key
		var detail := String(descriptions[index]).strip_edges() \
			if index < descriptions.size() else ""
		var magnitude_q16 := int(magnitudes[index]) if index < magnitudes.size() else 0
		rows.append({
			"id": "modifier:%d:%s" % [cell, key],
			"kind": "modifier",
			"cell": cell,
			"modifier_key": key,
			"title": display,
			"magnitude_q16": magnitude_q16,
			"magnitude_percent": float(magnitude_q16) * 100.0 / 65536.0,
			"magnitude_text": _q16_percent_text(magnitude_q16),
			"name": "地块 %d · %s" % [cell, display],
			"value": "效果幅度 %s" % _q16_percent_text(magnitude_q16),
			"detail": detail,
			"tooltip": detail,
		})
	return rows


func _family_trigger_rows(snapshot: Dictionary) -> Array:
	var rows: Array = []
	var cell := int(snapshot.get("cell_idx", -1))
	var keys: PackedStringArray = snapshot.get(
		"trigger_definition_keys", PackedStringArray())
	var names: PackedStringArray = snapshot.get(
		"trigger_display_names", PackedStringArray())
	var descriptions: PackedStringArray = snapshot.get(
		"trigger_descriptions", PackedStringArray())
	var progress: PackedInt64Array = snapshot.get("trigger_progress", PackedInt64Array())
	var thresholds: PackedInt64Array = snapshot.get("trigger_thresholds", PackedInt64Array())
	var completed: PackedInt32Array = snapshot.get("trigger_completed", PackedInt32Array())
	var targets: PackedInt32Array = snapshot.get(
		"trigger_reward_targets", PackedInt32Array())
	for index in range(keys.size()):
		var key := String(keys[index])
		var display := String(names[index]).strip_edges() \
			if index < names.size() else ""
		if display.is_empty():
			display = key
		var detail := String(descriptions[index]).strip_edges() \
			if index < descriptions.size() else ""
		var progress_value := int(progress[index]) if index < progress.size() else 0
		var threshold_value := int(thresholds[index]) if index < thresholds.size() else 0
		var completed_value := int(completed[index]) if index < completed.size() else 0
		var reward_target := int(targets[index]) if index < targets.size() else 0
		rows.append({
			"id": "trigger:%d:%s" % [cell, key],
			"kind": "trigger",
			"cell": cell,
			"trigger_key": key,
			"title": display,
			"progress": progress_value,
			"threshold": threshold_value,
			"progress_ratio": clampf(float(progress_value) / float(maxi(threshold_value, 1)), 0.0, 1.0),
			"completed": completed_value,
			"reward_target": reward_target,
			"name": "地块 %d · %s" % [cell, display],
			"value": "%d / %d · 已触发 %d 次 · 奖励归属 %s" % [
				progress_value, threshold_value, completed_value,
				"家族分支" if reward_target == 0 \
				else "城市公共"],
			"detail": detail,
			"tooltip": detail,
		})
	return rows


static func _prestige_text(level: int) -> String:
	return ["0", "I", "II", "III", "IV", "V"][clampi(level, 0, 5)]


static func _q16_percent_text(value: int) -> String:
	return "%.1f%%" % (float(value) * 100.0 / 65536.0)


static func _investment_block_reason_text(reason: int) -> String:
	return [
		"无阻塞", "已有待建项目", "存在停产产能", "现有岗位未填满",
		"现有产能充足", "业主生计不足", "商品销售不足", "商品丢弃过高",
		"投入链不足", "利润率不足", "回本周期过长", "发起资本不足",
		"建材组不足", "自然资源不足", "居民意愿未通过", "缺少市场信号",
		"扩建上限", "不支持的建筑类型",
	][clampi(reason, 0, 17)]


func _family_notable_person_rows(facade, family_handle: int) -> Array:
	var rows: Array = []
	if facade == null or not facade.has_method("family_notable_people") \
			or not facade.has_method("notable_person_snapshot"):
		return rows
	var page: Dictionary = facade.family_notable_people(family_handle, 0, 16)
	if not bool(page.get("ok", false)):
		return rows
	var handles: PackedInt64Array = page.get("person_handles", PackedInt64Array())
	for person_handle in handles:
		var person: Dictionary = facade.notable_person_snapshot(int(person_handle))
		if not bool(person.get("ok", false)):
			continue
		var job_kind := int(person.get("job_kind", 0))
		var job_text := "家族成员"
		if job_kind == 1:
			job_text = "产业所有者"
		elif job_kind == 2:
			job_text = "产业雇员"
		var profession := String(person.get("profession_display_name", ""))
		var building := String(person.get("building_type_display_name", ""))
		var detail_parts: Array[String] = []
		if not profession.is_empty():
			detail_parts.append(profession)
		detail_parts.append(job_text)
		if not building.is_empty():
			detail_parts.append(building)
		rows.append({
			"id": "person:%d" % int(person_handle),
			"kind": "person",
			"person_handle": int(person_handle),
			"portrait_key": "family.workspace.person",
			"name": String(person.get("full_name", "未命名人物")),
			"role": job_text,
			"profession": profession,
			"building": building,
			"value": " · ".join(detail_parts),
		})
	return rows


func _population_category(snapshot: Dictionary, market_snapshot: Dictionary = {}) -> Dictionary:
	if snapshot.is_empty() or not bool(snapshot.get("ok", false)):
		return {"insights": [{"id": "population_unavailable", "text": "人口情报暂不可用。", "accent": UITokens.TEXT_MUTED, "icon": "growth"}]}
	if not snapshot.has("populations"):
		return {"insights": [{"id": "population_details_unavailable", "text": "无法读取最新人口明细。", "accent": UITokens.RISK, "icon": "growth"}]}
	var list_only := not bool(snapshot.get("demand_preview_included", true))
	var rows := []
	var handles: PackedInt64Array = snapshot.get("handles", PackedInt64Array())
	var profession_indices: PackedInt32Array = snapshot.get("profession_ids", PackedInt32Array())
	var ethnicity_indices: PackedInt32Array = snapshot.get("ethnicity_ids", PackedInt32Array())
	var profession_ids: PackedStringArray = snapshot.get("profession_stable_ids", PackedStringArray())
	var ethnicity_ids: PackedStringArray = snapshot.get("ethnicity_stable_ids", PackedStringArray())
	var profession_names: PackedStringArray = snapshot.get("profession_display_names", PackedStringArray())
	var ethnicity_names: PackedStringArray = snapshot.get("ethnicity_display_names", PackedStringArray())
	var populations: PackedInt64Array = snapshot.get("populations", PackedInt64Array())
	var funds: PackedInt64Array = snapshot.get("funds_by_cohort", PackedInt64Array())
	var satisfaction: PackedInt32Array = snapshot.get(
		"survival_satisfaction_by_cohort_q16",
		snapshot.get("satisfaction_by_cohort_q16", PackedInt32Array()))
	# 综合满意度自 PKEC v30 起是权威列，任何 cohort 都可读，不再依赖 trace。
	var overall_satisfaction: PackedInt32Array = snapshot.get(
		"overall_satisfaction_by_cohort_q16", satisfaction)
	var living_levels: PackedInt32Array = snapshot.get(
		"living_standard_level_by_cohort", PackedInt32Array())
	var dimension_count := int(snapshot.get("satisfaction_dimension_count", 0))
	var satisfaction_dims: PackedInt32Array = snapshot.get(
		"satisfaction_dims_by_cohort_q16", PackedInt32Array())
	var worst_dimensions: PackedInt32Array = snapshot.get(
		"worst_satisfaction_dimension_by_cohort", PackedInt32Array())
	var welfare_available := bool(snapshot.get("welfare_detail_available", false))
	var welfare_need_offsets: PackedInt32Array = snapshot.get("welfare_need_offsets", PackedInt32Array())
	var welfare_need_ids: PackedInt32Array = snapshot.get("welfare_need_ids", PackedInt32Array())
	var welfare_need_satisfaction: PackedInt32Array = snapshot.get(
		"welfare_need_satisfaction_q16", PackedInt32Array())
	var merchant_flags: PackedByteArray = snapshot.get("merchant_flags", PackedByteArray())
	var owner_employed: PackedInt64Array = snapshot.get("owner_employed_by_cohort", PackedInt64Array())
	var employee_employed: PackedInt64Array = snapshot.get("employee_employed_by_cohort", PackedInt64Array())
	var settlement_available := bool(snapshot.get("settlement_detail_available", false))
	var settlement_pending := bool(snapshot.get("settlement_detail_pending", false))
	var settlement_offsets: PackedInt32Array = snapshot.get("settlement_cashflow_offsets", PackedInt32Array())
	var settlement_source_indices: PackedInt32Array = snapshot.get("settlement_cashflow_source_indices", PackedInt32Array())
	var settlement_source_ids: PackedStringArray = snapshot.get("settlement_cashflow_source_stable_ids", PackedStringArray())
	var settlement_income: PackedInt64Array = snapshot.get("settlement_cashflow_income", PackedInt64Array())
	var settlement_expense: PackedInt64Array = snapshot.get("settlement_cashflow_expense", PackedInt64Array())
	var settlement_income_by_cohort: PackedInt64Array = snapshot.get("settlement_income_by_cohort", PackedInt64Array())
	var settlement_expense_by_cohort: PackedInt64Array = snapshot.get("settlement_expense_by_cohort", PackedInt64Array())
	var settlement_days := maxi(1, int(snapshot.get("settlement_period_days", 1)))
	var demand_offsets: PackedInt32Array = snapshot.get("demand_good_offsets", PackedInt32Array())
	var demand_good_indices: PackedInt32Array = snapshot.get("demand_good_indices", PackedInt32Array())
	var demand_quantities: PackedInt64Array = snapshot.get("demand_per_capita_daily", PackedInt64Array())
	var demand_good_ids: PackedStringArray = snapshot.get("demand_good_stable_ids", PackedStringArray())
	var demand_need_ids: PackedStringArray = snapshot.get("demand_need_stable_ids", PackedStringArray())
	var attribution_good_count := int(snapshot.get("demand_attribution_good_count", 0))
	var wealth_demand_delta: PackedInt64Array = snapshot.get(
		"demand_wealth_delta_per_capita_daily", PackedInt64Array())
	var price_demand_delta: PackedInt64Array = snapshot.get(
		"demand_price_delta_per_capita_daily", PackedInt64Array())
	var local_prices := {}
	var local_technology_available := {}
	var enforce_local_technology := false
	if not list_only and bool(market_snapshot.get("ok", false)):
		var market_good_ids: PackedStringArray = market_snapshot.get("good_ids", PackedStringArray())
		var market_prices: PackedInt32Array = market_snapshot.get("price", PackedInt32Array())
		var market_technology: PackedByteArray = market_snapshot.get(
			"good_technology_available", PackedByteArray())
		enforce_local_technology = market_technology.size() == market_good_ids.size()
		for market_good_idx in range(mini(market_good_ids.size(), market_prices.size())):
			var market_good_id := String(market_good_ids[market_good_idx])
			local_prices[market_good_id] = int(market_prices[market_good_idx])
			if enforce_local_technology:
				local_technology_available[market_good_id] = market_technology[market_good_idx] != 0
	for i in range(populations.size()):
		var profession_id := String(profession_ids[profession_indices[i]]) if profession_indices[i] >= 0 and profession_indices[i] < profession_ids.size() else "unknown"
		var ethnicity_id := String(ethnicity_ids[ethnicity_indices[i]]) if ethnicity_indices[i] >= 0 and ethnicity_indices[i] < ethnicity_ids.size() else "unknown"
		var profession_name := String(profession_names[profession_indices[i]]) if profession_indices[i] >= 0 and profession_indices[i] < profession_names.size() else profession_id
		var ethnicity_name := String(ethnicity_names[ethnicity_indices[i]]) if ethnicity_indices[i] >= 0 and ethnicity_indices[i] < ethnicity_names.size() else ethnicity_id
		var sat := float(overall_satisfaction[i]) / 65536.0 if i < overall_satisfaction.size() else 0.0
		var living_level := int(living_levels[i]) if i < living_levels.size() else -1
		var living_name := _living_standard_name(living_level)
		var worst_dimension := int(worst_dimensions[i]) \
			if i < worst_dimensions.size() else -1
		var dimension_rows := [] if list_only else _satisfaction_dimension_rows(
			satisfaction_dims, dimension_count, i, worst_dimension)
		var need_satisfaction_by_id := {}
		if not list_only and welfare_need_offsets.size() == populations.size() + 1:
			var welfare_begin := clampi(int(welfare_need_offsets[i]), 0, welfare_need_ids.size())
			var welfare_end := clampi(int(welfare_need_offsets[i + 1]), welfare_begin, welfare_need_ids.size())
			for welfare_cursor in range(welfare_begin, welfare_end):
				var need_idx := int(welfare_need_ids[welfare_cursor])
				if need_idx >= 0 and need_idx < demand_need_ids.size() \
						and welfare_cursor < welfare_need_satisfaction.size():
					need_satisfaction_by_id[String(demand_need_ids[need_idx])] = int(
						welfare_need_satisfaction[welfare_cursor])
		var population := int(populations[i])
		var cohort_funds := int(funds[i]) if i < funds.size() else 0
		var wealth_pc := cohort_funds / maxi(population, 1)
		var owners := int(owner_employed[i]) if i < owner_employed.size() else 0
		var employees := int(employee_employed[i]) if i < employee_employed.size() else 0
		var demand_by_good := {}
		if not list_only and demand_offsets.size() == populations.size() + 1:
			var begin := clampi(int(demand_offsets[i]), 0, demand_good_indices.size())
			var end := clampi(int(demand_offsets[i + 1]), begin, demand_good_indices.size())
			for cursor in range(begin, end):
				var good_idx := int(demand_good_indices[cursor])
				if good_idx >= 0 and good_idx < demand_good_ids.size() and cursor < demand_quantities.size():
					demand_by_good[good_idx] = int(demand_quantities[cursor])
		var demand_rows := []
		var demand_groups := []
		var demand_total := 0
		var demand_total_cost := 0
		var demand_cost_available := true
		var demand_names := PackedStringArray()
		var visible_demand_count := 0
		if not list_only:
			var demand_metadata := _demand_good_metadata(snapshot, i)
			var good_metadata: Dictionary = demand_metadata.get("good_metadata", {}) \
				if bool(demand_metadata.get("ok", false)) else {}
			for good_idx in range(demand_good_ids.size()):
				var stable_id := String(demand_good_ids[good_idx])
				var profile = GoodProfileRegistry.profile_by_id(stable_id)
				var display_name := String(profile.display_name) if profile != null and String(profile.display_name) != "" else stable_id
				var quantity := int(demand_by_good.get(good_idx, 0))
				var has_price := local_prices.has(stable_id)
				var price := int(local_prices.get(stable_id, 0))
				var daily_cost := quantity * price / 1000 if has_price else 0
				var metadata: Dictionary = good_metadata.get(stable_id, {})
				var good_discovered := not enforce_local_technology \
					or bool(local_technology_available.get(stable_id, false))
				var unlocked_alternative := not metadata.is_empty() and enforce_local_technology \
					and good_discovered
				var visible := good_discovered and (quantity > 0 or unlocked_alternative)
				if visible:
					visible_demand_count += 1
				if visible and quantity > 0:
					demand_total += quantity
					if has_price:
						demand_total_cost += daily_cost
					else:
						demand_cost_available = false
					if demand_names.size() < 3:
						demand_names.append(display_name)
				var need_names: Array = metadata.get("need_names", [])
				var need_satisfaction_total := 0
				var need_satisfaction_count := 0
				for raw_need_id in metadata.get("need_ids", []):
					var need_id := String(raw_need_id)
					if need_satisfaction_by_id.has(need_id):
						need_satisfaction_total += int(need_satisfaction_by_id[need_id])
						need_satisfaction_count += 1
				var attribution_idx := i * attribution_good_count + good_idx
				var attribution_available := welfare_available \
					and attribution_good_count == demand_good_ids.size() \
					and attribution_idx >= 0 and attribution_idx < wealth_demand_delta.size() \
					and attribution_idx < price_demand_delta.size()
				demand_rows.append({
					"id": "demand_%s" % stable_id,
					"stable_id": stable_id,
					"name": display_name,
					"value": "%.3f 单位/人/日" % (float(quantity) / 1000.0),
					"quantity": "%.3f" % (float(quantity) / 1000.0),
					"price": _money_text(price) if has_price else "—",
					"daily_cost": _money_text(daily_cost) if has_price else "—",
					"quantity_raw": quantity,
					"price_raw": price if has_price else -1,
					"daily_cost_raw": daily_cost if has_price else -1,
					"need_ids": metadata.get("need_ids", []),
					"need_names": need_names,
					"need_satisfaction_q16": need_satisfaction_total / need_satisfaction_count \
						if need_satisfaction_count > 0 else -1,
					"attribution_available": attribution_available,
					"wealth_delta_raw": int(wealth_demand_delta[attribution_idx]) if attribution_available else 0,
					"price_delta_raw": int(price_demand_delta[attribution_idx]) if attribution_available else 0,
					"has_bundle": bool(metadata.get("has_bundle", false)),
					"has_substitute": bool(metadata.get("has_substitute", false)),
					"is_unallocated_alternative": quantity <= 0 and unlocked_alternative,
					"icon": GoodProfileRegistry.icon_key(stable_id),
					"visible": visible,
				})
			demand_groups = _group_demand_rows_by_usage(demand_rows)
		var income_rows := []
		var expense_rows := []
		if not list_only and settlement_available and settlement_offsets.size() == populations.size() + 1:
			var flow_begin := clampi(int(settlement_offsets[i]), 0, settlement_source_indices.size())
			var flow_end := clampi(int(settlement_offsets[i + 1]), flow_begin, settlement_source_indices.size())
			for flow in range(flow_begin, flow_end):
				var source_idx := int(settlement_source_indices[flow])
				var source_id := String(settlement_source_ids[source_idx]) if source_idx >= 0 and source_idx < settlement_source_ids.size() else "other"
				var income_value := int(settlement_income[flow]) if flow < settlement_income.size() else 0
				var expense_value := int(settlement_expense[flow]) if flow < settlement_expense.size() else 0
				if income_value > 0:
					income_rows.append({"id": "income_%s" % source_id, "name": _cashflow_source_name(source_id, true), "value": "+%s/人" % _money_text(income_value / maxi(population, 1)), "visible": true})
				if expense_value > 0:
					expense_rows.append({"id": "expense_%s" % source_id, "name": _cashflow_source_name(source_id, false), "value": "−%s/人" % _money_text(expense_value / maxi(population, 1)), "visible": true})
		var income_pc := int(settlement_income_by_cohort[i]) / maxi(population, 1) if settlement_available and i < settlement_income_by_cohort.size() else 0
		var expense_pc := int(settlement_expense_by_cohort[i]) / maxi(population, 1) if settlement_available and i < settlement_expense_by_cohort.size() else 0
		var net_pc := income_pc - expense_pc
		var demand_count := visible_demand_count
		var demand_group_count := demand_groups.size()
		var demand_subtitle := "主要：%s%s" % ["、".join(demand_names), " 等" if demand_count > demand_names.size() else ""] if demand_count > 0 else "当前无消费需求"
		rows.append({
			"id": "cohort_%s" % str(handles[i] if i < handles.size() else i),
			"name": profession_name,
			"cohort_identity": ethnicity_name,
			"profession_id": profession_id,
			"cohort_handle": int(handles[i]) if i < handles.size() else -1,
			"population": "%s 人" % UITokens.format_compact_number_cn(float(population), 1),
			"wealth": _money_text(wealth_pc),
			"income": "+%s" % _money_text(income_pc) if settlement_available else "+—",
			"expense": "−%s" % _money_text(expense_pc) if settlement_available else "−—",
			"net": "%s%s" % ["+" if net_pc > 0 else ("−" if net_pc < 0 else ""), _money_text(absi(net_pc))] if settlement_available else "—",
			"net_positive": net_pc >= 0,
			"status": "%s%s · 满意度 %.1f%% · 就业 %s · 结算 %d日" % [
				"商人 · " if i < merchant_flags.size() and merchant_flags[i] != 0 else "",
				ethnicity_name, sat * 100.0,
				UITokens.format_compact_number_cn(float(owners + employees), 1), settlement_days],
			"accent": UITokens.ACCENT,
			"icon": IconCatalog.profession_semantic(profession_id),
			"living_icon": _living_standard_icon(living_level),
			"living_accent": _living_standard_accent(living_level),
			"living_standard": living_name,
			"satisfaction": "%.1f%%" % (sat * 100.0),
			"satisfaction_rows": dimension_rows,
			"worst_dimension": _satisfaction_dimension_name(worst_dimension),
			"demand_rows": demand_rows,
			"demand_groups": demand_groups,
			"income_rows": income_rows,
			"expense_rows": expense_rows,
			"demand_summary": {
				"value": "%d 项用途 · %d 种商品" % [demand_group_count, demand_count],
				"subtitle": demand_subtitle,
				"total_quantity": "%.3f" % (float(demand_total) / 1000.0),
				"total_daily_cost": _money_text(demand_total_cost) if demand_cost_available else "—",
			},
			"visible": true,
		})
	var insights := []
	if rows.is_empty():
		insights.append({"id": "population_empty", "text": "此地尚无人口。", "accent": UITokens.TEXT_MUTED, "icon": "growth"})
	elif not list_only and not bool(snapshot.get("demand_preview_environment_ready", false)):
		insights.append({"id": "population_demand_neutral_environment", "text": "需求暂按一般环境估算。", "accent": UITokens.WARN, "icon": "weather"})
	if not rows.is_empty() and settlement_pending:
		insights.append({"id": "population_settlement_pending", "text": "下次结算后可看精确收支。", "accent": UITokens.TEXT_MUTED, "icon": "history"})
	var job_capacity := int(snapshot.get("job_capacity", 0))
	var jobs_filled := int(snapshot.get("jobs_filled", 0))
	var job_openings := int(snapshot.get("job_openings", 0))
	var carrying_k_eff := int(snapshot.get("carrying_k_eff", 0))
	var carrying_k_geo := int(snapshot.get("carrying_k_geo", 0))
	var carrying_surplus := float(snapshot.get("carrying_surplus_q16", 65536)) / 65536.0
	var carrying_sat := float(snapshot.get("carrying_sat_q16", 65536)) / 65536.0
	var population_total := int(snapshot.get("population", 0))
	if carrying_k_eff > 0:
		insights.append({
			"id": "population_carrying",
			"text": "承载力 %s 人 · 地力 %s · 物资 %.0f%% · 心情 %.0f%%" % [
				UITokens.format_compact_number_cn(float(carrying_k_eff), 1),
				UITokens.format_compact_number_cn(float(carrying_k_geo), 1),
				carrying_surplus * 100.0,
				carrying_sat * 100.0,
			],
			"accent": UITokens.RISK if population_total > carrying_k_eff else UITokens.GOOD,
			"icon": "growth",
		})
	if population_total > 0 and carrying_k_eff > 0 and population_total > carrying_k_eff:
		insights.append({
			"id": "population_at_carrying",
			"text": "人口已贴上格承载力，出生率落到更替水平。",
			"accent": UITokens.WARN,
			"icon": "growth",
		})
	var family_ids: PackedStringArray = snapshot.get("carrying_family_ids", PackedStringArray())
	var family_surplus: PackedInt32Array = snapshot.get(
		"carrying_family_surplus_q16", PackedInt32Array())
	var family_bindable: PackedByteArray = snapshot.get(
		"carrying_family_bindable", PackedByteArray())
	var tight_family := ""
	var tight_cover := 2.0
	for family_idx in range(mini(family_ids.size(), family_surplus.size())):
		if family_idx < family_bindable.size() and family_bindable[family_idx] == 0:
			continue
		var cover := float(family_surplus[family_idx]) / 65536.0
		if cover < tight_cover:
			tight_cover = cover
			tight_family = String(family_ids[family_idx])
	if not tight_family.is_empty() and tight_cover < 0.8:
		insights.append({
			"id": "population_carrying_family",
			"text": "物资最紧的是 %s（覆盖 %.0f%%）。" % [tight_family, tight_cover * 100.0],
			"accent": UITokens.WARN,
			"icon": "resource",
		})
	var investment_block_reason := int(snapshot.get(
		"investment_last_block_reason", 0))
	var investment_review_day := int(snapshot.get("investment_last_review_day", -1))
	if investment_review_day >= 0 and investment_block_reason > 0:
		insights.append({
			"id": "population_investment_block",
			"text": "投资受阻 · %s" % _investment_block_reason_text(investment_block_reason),
			"accent": UITokens.RISK,
			"icon": "resource",
		})
	return {
		"insights": insights,
		"metrics": [
			{"id": "population_total", "title": "总人口", "value": "%s 人" % UITokens.format_compact_number_cn(float(snapshot.get("population", 0)), 1), "subtitle": "%d 个阶层" % int(snapshot.get("cohort_count", 0)), "accent": UITokens.ACCENT, "icon": "growth"},
			{"id": "population_prosperity", "title": "繁荣度", "value": String(snapshot.get("prosperity_name", "未就绪")), "subtitle": String(snapshot.get("settlement_name", "尚未命名")), "accent": UITokens.GOOD, "icon": "building"},
			{"id": "population_funds", "title": "总资金", "value": _money_text(int(snapshot.get("funds", 0))), "subtitle": "收入 %s · 支出 %s" % [_money_text(int(snapshot.get("epoch_income", 0))), _money_text(int(snapshot.get("epoch_expense", 0)))], "accent": UITokens.RESOURCE, "icon": "resource"},
			{"id": "population_jobs", "title": "岗位容量", "value": "%s 个" % UITokens.format_compact_number_cn(float(job_capacity), 1), "subtitle": "已填 %s · 空缺 %s" % [UITokens.format_compact_number_cn(float(jobs_filled), 1), UITokens.format_compact_number_cn(float(job_openings), 1)], "accent": UITokens.GOOD if job_openings > 0 else UITokens.TEXT_MUTED, "icon": "building"},
			{"id": "population_carrying", "title": "格承载力", "value": "%s 人" % UITokens.format_compact_number_cn(float(carrying_k_eff), 1), "subtitle": "地力 %s · 物资 %.0f%% · 心情 %.0f%%" % [UITokens.format_compact_number_cn(float(carrying_k_geo), 1), carrying_surplus * 100.0, carrying_sat * 100.0], "accent": UITokens.RISK if population_total > carrying_k_eff and carrying_k_eff > 0 else UITokens.ACCENT, "icon": "growth"},
		],
		"cohort_rows": rows,
	}


func _group_demand_rows_by_usage(rows: Array) -> Array:
	var groups := []
	var group_indices := {}
	for raw_row in rows:
		var row: Dictionary = raw_row
		if not bool(row.get("visible", false)):
			continue
		var need_names: Array = row.get("need_names", [])
		var group_name := "、".join(need_names) if not need_names.is_empty() else "其他"
		if not group_indices.has(group_name):
			group_indices[group_name] = groups.size()
			groups.append({
				"id": "demand_usage_%d" % groups.size(),
				"name": group_name,
				"rows": [],
			})
		var group_idx := int(group_indices[group_name])
		var group: Dictionary = groups[group_idx]
		var group_rows: Array = group.get("rows", [])
		group_rows.append(row)
		group["rows"] = group_rows
		var satisfaction_total := 0
		var satisfaction_count := 0
		for group_row in group_rows:
			var value := int((group_row as Dictionary).get("need_satisfaction_q16", -1))
			if value >= 0:
				satisfaction_total += value
				satisfaction_count += 1
		group["satisfaction"] = "满足 %.0f%%" % (
			float(satisfaction_total) * 100.0 / 65536.0 / satisfaction_count) \
			if satisfaction_count > 0 else ""
		groups[group_idx] = group
	return groups


func _living_standard_name(level: int) -> String:
	return ["赤贫", "挣扎", "贫困", "温饱", "小康", "富裕", "奢华"][level] \
		if level >= 0 and level < 7 else "待评估"


func _living_standard_icon(level: int) -> String:
	return ["living_destitute", "living_struggling", "living_poor", "living_secure",
		"living_comfortable", "living_affluent", "living_luxury"][level] \
		if level >= 0 and level < 7 else "history"


func _living_standard_accent(level: int) -> Color:
	if level <= 0:
		return UITokens.RISK
	if level <= 2:
		return UITokens.WARN
	if level <= 4:
		return UITokens.GOOD
	return UITokens.RESOURCE


## 与原生 SAT_DIM_* 枚举同序。
const SATISFACTION_DIMENSION_NAMES := [
	"温饱", "基本生活", "舒适", "奢侈", "收入增长", "储蓄", "税负", "社会发展",
]


func _satisfaction_dimension_name(dimension: int) -> String:
	return String(SATISFACTION_DIMENSION_NAMES[dimension]) \
		if dimension >= 0 and dimension < SATISFACTION_DIMENSION_NAMES.size() \
		else "待评估"


func _satisfaction_dimension_rows(dims: PackedInt32Array, dimension_count: int,
		cohort_idx: int, worst_dimension: int) -> Array:
	var rows := []
	if dimension_count <= 0:
		return rows
	var begin := cohort_idx * dimension_count
	if begin < 0 or begin + dimension_count > dims.size():
		return rows
	for dimension in range(dimension_count):
		var value := float(dims[begin + dimension]) / 65536.0
		var is_worst := dimension == worst_dimension
		rows.append({
			"id": "satisfaction_dim_%d" % dimension,
			"name": _satisfaction_dimension_name(dimension),
			"value": "%.1f%%" % (value * 100.0),
			"accent": UITokens.RISK if is_worst else _satisfaction_accent(value),
			"worst": is_worst,
			"visible": true,
		})
	return rows


func _satisfaction_accent(value: float) -> Color:
	if value < 0.22:
		return UITokens.RISK
	if value < 0.45:
		return UITokens.WARN
	if value < 0.72:
		return UITokens.GOOD
	return UITokens.RESOURCE


func _demand_good_metadata(snapshot: Dictionary, cohort_idx: int) -> Dictionary:
	var populations: PackedInt64Array = snapshot.get("populations", PackedInt64Array())
	var good_ids: PackedStringArray = snapshot.get("demand_good_stable_ids", PackedStringArray())
	var need_ids: PackedStringArray = snapshot.get("demand_need_stable_ids", PackedStringArray())
	var need_offsets: PackedInt32Array = snapshot.get("demand_need_offsets", PackedInt32Array())
	var need_indices: PackedInt32Array = snapshot.get("demand_need_indices", PackedInt32Array())
	var need_variant_offsets: PackedInt32Array = snapshot.get(
		"demand_need_variant_offsets", PackedInt32Array())
	var variant_component_offsets: PackedInt32Array = snapshot.get(
		"demand_variant_component_offsets", PackedInt32Array())
	var component_good_indices: PackedInt32Array = snapshot.get(
		"demand_component_good_indices", PackedInt32Array())
	var component_quantities: PackedInt64Array = snapshot.get(
		"demand_component_per_capita_daily", PackedInt64Array())
	if cohort_idx < 0 or cohort_idx >= populations.size() \
			or need_offsets.size() != populations.size() + 1 \
			or need_variant_offsets.size() != need_indices.size() + 1 \
			or variant_component_offsets.is_empty() \
			or component_good_indices.size() != component_quantities.size() \
			or variant_component_offsets[-1] != component_good_indices.size():
		return {"ok": false}
	var need_begin := int(need_offsets[cohort_idx])
	var need_end := int(need_offsets[cohort_idx + 1])
	if need_begin < 0 or need_end < need_begin or need_end > need_indices.size():
		return {"ok": false}
	var good_metadata := {}
	for need_cursor in range(need_begin, need_end):
		var need_idx := int(need_indices[need_cursor])
		if need_idx < 0 or need_idx >= need_ids.size():
			return {"ok": false}
		var variant_begin := int(need_variant_offsets[need_cursor])
		var variant_end := int(need_variant_offsets[need_cursor + 1])
		if variant_begin < 0 or variant_end < variant_begin \
				or variant_end + 1 > variant_component_offsets.size():
			return {"ok": false}
		var need_id := String(need_ids[need_idx])
		var need_name := _need_display_name(need_id)
		for variant_cursor in range(variant_begin, variant_end):
			var component_begin := int(variant_component_offsets[variant_cursor])
			var component_end := int(variant_component_offsets[variant_cursor + 1])
			if component_begin < 0 or component_end < component_begin \
					or component_end > component_good_indices.size():
				return {"ok": false}
			var component_count := component_end - component_begin
			for component_cursor in range(component_begin, component_end):
				var good_idx := int(component_good_indices[component_cursor])
				if good_idx < 0 or good_idx >= good_ids.size():
					return {"ok": false}
				var stable_id := String(good_ids[good_idx])
				var metadata: Dictionary = good_metadata.get(stable_id, {
					"need_ids": [],
					"need_names": [],
					"has_bundle": false,
					"has_substitute": false,
				})
				var metadata_need_ids: Array = metadata.get("need_ids", [])
				var metadata_need_names: Array = metadata.get("need_names", [])
				if not metadata_need_ids.has(need_id):
					metadata_need_ids.append(need_id)
					if not metadata_need_names.has(need_name):
						metadata_need_names.append(need_name)
				metadata["need_ids"] = metadata_need_ids
				metadata["need_names"] = metadata_need_names
				metadata["has_bundle"] = bool(metadata.get("has_bundle", false)) \
					or component_count > 1
				metadata["has_substitute"] = bool(metadata.get("has_substitute", false)) \
					or variant_end - variant_begin > 1
				good_metadata[stable_id] = metadata
	return {
		"ok": true,
		"good_metadata": good_metadata,
	}


func _need_display_name(stable_id: String) -> String:
	if not _need_display_names_loaded:
		_need_display_names = EconomyCatalog.need_display_names()
		_need_display_names_loaded = true
	return String(_need_display_names.get(stable_id, stable_id))


func _market_category(snapshot: Dictionary) -> Dictionary:
	if snapshot.is_empty() or not bool(snapshot.get("ok", false)):
		return {"insights": [{"id": "market_unavailable", "text": "市场情报暂不可用。", "accent": UITokens.TEXT_MUTED, "icon": "resource"}]}
	if not snapshot.has("good_ids"):
		return {"insights": [{"id": "market_details_unavailable", "text": "无法读取最新市场明细。", "accent": UITokens.RISK, "icon": "resource"}]}
	var rows := []
	var good_ids: PackedStringArray = snapshot.get("good_ids", PackedStringArray())
	var stock: PackedInt64Array = snapshot.get("stock", PackedInt64Array())
	var prices: PackedInt32Array = snapshot.get("price", PackedInt32Array())
	var demand_ema: PackedInt64Array = snapshot.get("demand_ema", PackedInt64Array())
	var business_demand_ema: PackedInt64Array = snapshot.get("business_demand_ema", PackedInt64Array())
	var offered_supply_ema: PackedInt64Array = snapshot.get("offered_supply_ema", PackedInt64Array())
	var cost_anchor: PackedInt32Array = snapshot.get("cost_anchor_price", PackedInt32Array())
	var shortage_q16: PackedInt32Array = snapshot.get("shortage_q16", PackedInt32Array())
	var technology_available: PackedByteArray = snapshot.get(
		"good_technology_available", PackedByteArray())
	var trade_enabled: PackedByteArray = snapshot.get(
		"good_trade_enabled", PackedByteArray())
	var trade_inbound: PackedInt64Array = snapshot.get(
		"trade_inbound", PackedInt64Array())
	var trade_outbound: PackedInt64Array = snapshot.get(
		"trade_outbound", PackedInt64Array())
	var trade_import_ema: PackedInt64Array = snapshot.get(
		"trade_import_ema", PackedInt64Array())
	var trade_export_ema: PackedInt64Array = snapshot.get(
		"trade_export_ema", PackedInt64Array())
	var enforce_technology := technology_available.size() == good_ids.size()
	var market_id := int(snapshot.get("market_id", snapshot.get("cell_idx", -1)))
	var sample_day := _current_sample_day()
	var shortage_count := 0
	var in_transit_kinds := 0
	for i in range(good_ids.size()):
		if enforce_technology and technology_available[i] == 0:
			continue
		var stable_id := String(good_ids[i])
		var profile = GoodProfileRegistry.profile_by_id(stable_id)
		var display_name := String(profile.display_name) if profile != null else stable_id
		var stock_daily := _sample_daily_delta(_market_prev_stock,
			"%d:%s" % [market_id, stable_id], float(stock[i]) / 1000.0, sample_day)
		var shortage := float(shortage_q16[i]) * 100.0 / 65536.0 if i < shortage_q16.size() else 0.0
		if shortage >= 25.0:
			shortage_count += 1
		var allow_trade := _market_trade_enabled(trade_enabled, i)
		var inbound := _packed_i64_at(trade_inbound, i) if allow_trade else 0
		var outbound := _packed_i64_at(trade_outbound, i) if allow_trade else 0
		var import_flow := _packed_i64_at(trade_import_ema, i) if allow_trade else 0
		var export_flow := _packed_i64_at(trade_export_ema, i) if allow_trade else 0
		var in_transit := inbound > 0 or outbound > 0
		if in_transit:
			in_transit_kinds += 1
		var stock_plain := _goods_unit_text(int(stock[i]) if i < stock.size() else 0)
		var detail_rows := [
			{"id": "household_demand", "name": "居民需求", "value": UITokens.format_compact_number_cn(float(demand_ema[i]) / 1000.0, 2) if i < demand_ema.size() else "0"},
			{"id": "business_demand", "name": "产业需求", "value": UITokens.format_compact_number_cn(float(business_demand_ema[i]) / 1000.0, 2) if i < business_demand_ema.size() else "0"},
			{"id": "supply", "name": "供给", "value": UITokens.format_compact_number_cn(float(offered_supply_ema[i]) / 1000.0, 2) if i < offered_supply_ema.size() else "0"},
			{"id": "cost_anchor", "name": "成本锚", "value": _money_text(int(cost_anchor[i])) if i < cost_anchor.size() and cost_anchor[i] > 0 else "—"},
			{"id": "shortage", "name": "短缺", "value": "%.1f%%" % shortage},
		]
		if inbound > 0:
			detail_rows.append({"id": "trade_inbound", "name": "运入",
				"value": _goods_unit_text(inbound)})
		if outbound > 0:
			detail_rows.append({"id": "trade_outbound", "name": "运出",
				"value": _goods_unit_text(outbound)})
		if import_flow > 0:
			detail_rows.append({"id": "trade_import_flow", "name": "进口均量",
				"value": _goods_unit_text(import_flow)})
		if export_flow > 0:
			detail_rows.append({"id": "trade_export_flow", "name": "出口均量",
				"value": _goods_unit_text(export_flow)})
		rows.append({
			"id": "market_%s" % stable_id,
			"name": display_name,
			"good_id": stable_id,
			"stock": "%s · 在途" % stock_plain if in_transit else stock_plain,
			"stock_plain": stock_plain,
			"price": _money_text(prices[i] if i < prices.size() else 0),
			"delta": _daily_delta_text(stock_daily),
			"risk": "短缺" if shortage >= 25.0 else "",
			"trade_inbound": _goods_unit_text(inbound) if inbound > 0 else "",
			"trade_outbound": _goods_unit_text(outbound) if outbound > 0 else "",
			"detail_rows": detail_rows,
			"accent": UITokens.RISK if shortage >= 25.0 else UITokens.RESOURCE,
			"icon": GoodProfileRegistry.icon_key(stable_id),
			"visible": true,
		})
	var trade_net := int(snapshot.get("merchant_trade_sale_cash", 0)) \
		- int(snapshot.get("merchant_trade_purchase_cash", 0))
	var arrival_days := _trade_arrival_days(
		int(snapshot.get("trade_next_arrival_day", -1)), sample_day)
	var market_insights := []
	if shortage_count > 0:
		market_insights.append({
			"id": "market_shortage",
			"text": "%d 种物资短缺" % shortage_count,
			"accent": UITokens.RISK,
			"icon": "resource",
		})
	if in_transit_kinds > 0:
		market_insights.append({
			"id": "market_trade_in_transit",
			"text": _market_trade_insight_text(in_transit_kinds, arrival_days),
			"accent": UITokens.ACCENT,
			"icon": "metric.trade",
		})
	return {
		"insights": market_insights,
		"metrics": [
			{"id": "merchant_cash", "title": "可用现金", "value": _money_text(int(snapshot.get("merchant_cash", 0))), "subtitle": "", "accent": UITokens.ACCENT, "icon": "resource"},
			{"id": "market_shortage_count", "title": "短缺物资", "value": "%d 种" % shortage_count, "subtitle": "点击物资查看供需", "accent": UITokens.RISK if shortage_count > 0 else UITokens.TEXT_MUTED, "icon": "resource"},
			{"id": "merchant_trade_net", "title": "贸易净额", "value": _money_text(trade_net), "subtitle": _market_trade_subtitle(in_transit_kinds, arrival_days), "accent": UITokens.GOOD if trade_net >= 0 else UITokens.RISK, "icon": "resource"},
		],
		"sections": [{
			"id": "merchant_accounts",
			"title": "商家账目",
			"icon": "resource",
			"accent": UITokens.RESOURCE,
			"collapsed": true,
			"metrics": [
				{"id": "merchant_inventory_liquidation", "title": "库存估值", "value": _money_text(int(snapshot.get("merchant_inventory_liquidation_value", 0))), "subtitle": "按零售价估值", "accent": UITokens.RESOURCE, "icon": "resource"},
				{"id": "merchant_assets", "title": "商业资产", "value": _money_text(int(snapshot.get("merchant_economic_assets", 0))), "subtitle": "现金 + 库存", "accent": UITokens.GOOD, "icon": "resource"},
				{"id": "merchant_coverage", "title": "周转覆盖", "value": "%.1f 期" % (float(snapshot.get("merchant_liquidity_coverage_q16", 65536)) / 65536.0), "subtitle": "现金可支撑经营期数", "accent": UITokens.ACCENT, "icon": "resource"},
				{"id": "merchant_margin", "title": "采购毛利", "value": _money_text(int(snapshot.get("merchant_procurement_margin_value", 0))), "subtitle": "", "accent": UITokens.GOOD, "icon": "resource"},
			],
		}],
		"market_rows": rows,
	}


func _building_category(snapshot: Dictionary, cell_idx: int = -1) -> Dictionary:
	if snapshot.is_empty() or not bool(snapshot.get("ok", false)):
		return {"insights": [{"id": "buildings_unavailable", "text": "建筑情报暂不可用。", "accent": UITokens.TEXT_MUTED, "icon": "building"}]}
	if not snapshot.has("group_type_ids"):
		return {"insights": [{"id": "building_details_unavailable", "text": "无法读取最新建筑明细。", "accent": UITokens.RISK, "icon": "building"}]}
	var rows := []
	var type_ids: PackedStringArray = snapshot.get("building_type_ids", PackedStringArray())
	var type_names: PackedStringArray = snapshot.get("building_type_display_names", PackedStringArray())
	var group_types: PackedInt32Array = snapshot.get("group_type_ids", PackedInt32Array())
	var owner_signatures: PackedInt32Array = snapshot.get("owner_signature_ids", PackedInt32Array())
	var group_counts: PackedInt64Array = snapshot.get("group_counts", PackedInt64Array())
	var owner_capacity: PackedInt64Array = snapshot.get("owner_capacity", PackedInt64Array())
	var owner_required_by_group: PackedInt64Array = snapshot.get("owner_required", PackedInt64Array())
	var filled_owner: PackedInt64Array = snapshot.get("filled_owner", PackedInt64Array())
	var owner_openings: PackedInt64Array = snapshot.get("owner_openings", PackedInt64Array())
	var planned_utilization: PackedInt32Array = snapshot.get("planned_utilization_q16", PackedInt32Array())
	var capacity_q16: PackedInt64Array = snapshot.get("capacity_q16", PackedInt64Array())
	var temperature_fit_q16: PackedInt64Array = snapshot.get(
		"last_temperature_fit_q16", PackedInt64Array())
	var water_fit_q16: PackedInt64Array = snapshot.get(
		"last_water_fit_q16", PackedInt64Array())
	var climate_capacity_q16: PackedInt64Array = snapshot.get(
		"last_climate_capacity_q16", PackedInt64Array())
	var climate_lost_output: PackedInt64Array = snapshot.get(
		"last_climate_lost_output", PackedInt64Array())
	var building_climate_profiles: PackedInt32Array = snapshot.get(
		"building_production_climate_profile_indices", PackedInt32Array())
	var last_input: PackedInt64Array = snapshot.get("last_input", PackedInt64Array())
	var last_output: PackedInt64Array = snapshot.get("last_output", PackedInt64Array())
	var last_resource: PackedInt64Array = snapshot.get("last_resource", PackedInt64Array())
	var last_resource_generated: PackedInt64Array = snapshot.get("last_resource_generated", PackedInt64Array())
	var last_revenue: PackedInt64Array = snapshot.get("last_revenue", PackedInt64Array())
	var last_input_cost: PackedInt64Array = snapshot.get("last_input_cost", PackedInt64Array())
	var last_wages: PackedInt64Array = snapshot.get("last_wages_paid", PackedInt64Array())
	var last_wages_due: PackedInt64Array = snapshot.get("last_wages_due", PackedInt64Array())
	var last_operating_cost: PackedInt64Array = snapshot.get("last_operating_cost", PackedInt64Array())
	var role_offsets: PackedInt32Array = snapshot.get("employee_fill_offsets", PackedInt32Array())
	var role_professions: PackedInt32Array = snapshot.get("employee_profession_ids", PackedInt32Array())
	var role_required: PackedInt64Array = snapshot.get("employee_required", PackedInt64Array())
	var role_filled: PackedInt64Array = snapshot.get("employee_filled", PackedInt64Array())
	var wage_suspended: PackedByteArray = snapshot.get("wage_suspended", PackedByteArray())
	var operating_states: PackedByteArray = snapshot.get("operating_state", PackedByteArray())
	var pending_operating_states: PackedByteArray = snapshot.get(
		"pending_operating_state", PackedByteArray())
	var severe_loss_cycles: PackedInt32Array = snapshot.get(
		"severe_loss_cycles", PackedInt32Array())
	var realized_profit_margins: PackedInt32Array = snapshot.get(
		"realized_profit_margin_q16", PackedInt32Array())
	var technology_available: PackedByteArray = snapshot.get(
		"building_technology_available", PackedByteArray())
	var owner_slots: PackedInt64Array = snapshot.get("building_owner_slots", PackedInt64Array())
	var period_days := maxi(1, int(snapshot.get("period_days", 1)))
	for i in range(group_types.size()):
		var type_idx := int(group_types[i])
		var building_id := String(type_ids[type_idx]) \
			if type_idx >= 0 and type_idx < type_ids.size() else ""
		var count := int(group_counts[i]) if i < group_counts.size() else 0
		var revenue := int(last_revenue[i]) if i < last_revenue.size() else 0
		var input_cost := int(last_input_cost[i]) if i < last_input_cost.size() else 0
		var wages := int(last_wages[i]) if i < last_wages.size() else 0
		var wages_due := int(last_wages_due[i]) if i < last_wages_due.size() else wages
		var operating_cost := int(last_operating_cost[i]) if i < last_operating_cost.size() else input_cost + wages_due
		var profit := revenue - operating_cost
		var owner_physical_capacity := int(owner_capacity[i]) if i < owner_capacity.size() else \
			(count * int(owner_slots[type_idx]) if type_idx >= 0 and type_idx < owner_slots.size() else count)
		var owner_required := int(owner_required_by_group[i]) if i < owner_required_by_group.size() else 0
		if i >= owner_required_by_group.size():
			owner_required = owner_physical_capacity
		var owner_actual := int(filled_owner[i]) if i < filled_owner.size() else 0
		var owner_open := int(owner_openings[i]) if i < owner_openings.size() else maxi(0, owner_required - owner_actual)
		var operating_state := int(operating_states[i]) if i < operating_states.size() else 0
		var is_available := type_idx < 0 or type_idx >= technology_available.size() \
			or int(technology_available[type_idx]) != 0
		var is_loss_suspended := operating_state == 1
		var owner_job_value := "%d / %d" % [owner_actual, owner_required]
		if owner_required == 0 and owner_physical_capacity > 0:
			owner_job_value += "（物理容量 %d）" % owner_physical_capacity
		var job_rows := [
			{"id": "owner_job", "name": "业主 · %s" % _owner_profession_name(snapshot, int(owner_signatures[i]) if i < owner_signatures.size() else -1), "value": owner_job_value, "ratio": float(owner_actual) / float(owner_required) if owner_required > 0 else 0.0},
		]
		if role_offsets.size() == group_types.size() + 1:
			for role in range(role_offsets[i], role_offsets[i + 1]):
				var required := int(role_required[role]) if role < role_required.size() else 0
				var filled := int(role_filled[role]) if role < role_filled.size() else 0
				var role_value := "%d / %d" % [filled, required]
				if required == 0 and (is_loss_suspended or not is_available):
					role_value += "（岗位已释放）"
				job_rows.append({
					"id": "job_%d" % role,
					"name": "雇员 · %s" % _profession_name(snapshot, int(role_professions[role]) if role < role_professions.size() else -1),
					"value": role_value,
					"ratio": float(filled) / float(required) if required > 0 else 0.0,
				})
		var production_rows := []
		var input_row_begin := production_rows.size()
		_append_recipe_rows(production_rows, snapshot, type_idx, "input",
			int(last_input[i]) if i < last_input.size() else 0, count, period_days, i)
		_append_resource_generation_rows(production_rows, snapshot, type_idx,
			int(last_resource_generated[i]) if i < last_resource_generated.size() else 0,
			count, period_days)
		_append_resource_recipe_rows(production_rows, snapshot, type_idx,
			int(last_resource[i]) if i < last_resource.size() else 0, count, period_days)
		var resource_net := (int(last_resource_generated[i]) if i < last_resource_generated.size() else 0) \
			- (int(last_resource[i]) if i < last_resource.size() else 0)
		if resource_net != 0:
			production_rows.append({"id": "resource_net", "name": "自然资源净额",
				"value": _actual_daily_rate(resource_net, count, period_days),
				"icon": "eco", "accent": UITokens.GOOD if resource_net > 0 else UITokens.WARN})
		if production_rows.size() == input_row_begin:
			production_rows.append({"id": "input_none", "name": "原材料", "value": "无", "icon": "resource", "accent": UITokens.TEXT_MUTED})
		var output_row_begin := production_rows.size()
		_append_recipe_rows(production_rows, snapshot, type_idx, "output",
			int(last_output[i]) if i < last_output.size() else 0, count, period_days)
		if production_rows.size() == output_row_begin:
			production_rows.append({"id": "output_none", "name": "产出", "value": "无", "icon": "resource", "accent": UITokens.TEXT_MUTED})
		var has_climate_profile := type_idx >= 0 \
			and type_idx < building_climate_profiles.size() \
			and int(building_climate_profiles[type_idx]) >= 0
		if has_climate_profile:
			var temp_fit := float(temperature_fit_q16[i]) * 100.0 / 65536.0 \
				if i < temperature_fit_q16.size() else 100.0
			var water_fit := float(water_fit_q16[i]) * 100.0 / 65536.0 \
				if i < water_fit_q16.size() else 100.0
			var climate_capacity := float(climate_capacity_q16[i]) * 100.0 / 65536.0 \
				if i < climate_capacity_q16.size() else 100.0
			production_rows.append({"id": "climate_fit", "name": "气候适宜度",
				"value": "温度 %.1f%% · 水分 %.1f%% · 能力 %.1f%%" % [
					temp_fit, water_fit, climate_capacity], "icon": "climate",
				"accent": UITokens.GOOD if climate_capacity >= 99.9 else UITokens.WARN})
			var lost_output := int(climate_lost_output[i]) \
				if i < climate_lost_output.size() else 0
			if lost_output > 0:
				production_rows.append({"id": "climate_lost_output", "name": "气候减产",
					"value": _actual_daily_rate(lost_output, count, period_days),
					"icon": "warning", "accent": UITokens.WARN})
		var finance := {
			"revenue": _money_text(revenue),
			"cost": _money_text(operating_cost),
			"profit": "%s%s" % ["+" if profit > 0 else "", _money_text(profit)],
			"profit_positive": profit >= 0,
			"breakdown": "原料 %s · 工资 %s" % [_money_text(input_cost), _money_text(wages)],
			"warning": "工资未足额支付，生产受限" if wages < wages_due else "",
		}
		var staffing_required := owner_required
		var staffing_actual := owner_actual
		if role_offsets.size() == group_types.size() + 1:
			for role in range(role_offsets[i], role_offsets[i + 1]):
				staffing_required += int(role_required[role]) if role < role_required.size() else 0
				staffing_actual += int(role_filled[role]) if role < role_filled.size() else 0
		var planned_percent := float(planned_utilization[i]) * 100.0 / 65536.0 \
			if i < planned_utilization.size() else 100.0
		var actual_percent := float(capacity_q16[i]) * 100.0 / 65536.0 \
			if i < capacity_q16.size() else 0.0
		var state_label := "正常经营"
		var state_detail := ""
		var state_meta := ""
		var state_accent := UITokens.GOOD
		var show_state_summary := false
		if not is_available:
			state_label = "技术停用"
			state_detail = "技术条件不足，本期停产。"
			state_accent = UITokens.WARN
			show_state_summary = true
		elif is_loss_suspended:
			state_label = "亏损停产"
			state_detail = "连续亏损停产，岗位已释放。"
			var loss_count := int(severe_loss_cycles[i]) if i < severe_loss_cycles.size() else 0
			var realized_margin := float(realized_profit_margins[i]) * 100.0 / 65536.0 \
				if i < realized_profit_margins.size() else 0.0
			state_meta = "上一经营期利润率 %.1f%%" % realized_margin
			if loss_count > 0:
				state_meta += " · 连续亏损 %d 期" % loss_count
			state_accent = UITokens.RISK
			show_state_summary = true
		elif i < wage_suspended.size() and int(wage_suspended[i]) != 0:
			state_label = "资金停产"
			state_detail = "工资未付清，本期停产。"
			state_accent = UITokens.RISK
			show_state_summary = true
		elif i < capacity_q16.size() and int(capacity_q16[i]) == 0 \
				and _building_resource_depleted(snapshot, type_idx):
			state_label = "资源短缺"
			state_detail = "本地资源不足，无法生产。"
			state_accent = UITokens.WARN
			show_state_summary = true
		else:
			var status_parts: Array[String] = ["到岗 %d/%d" % [staffing_actual, staffing_required]]
			if owner_open > 0:
				status_parts.append("招聘空缺 %d" % owner_open)
			status_parts.append("计划 %.1f%%" % planned_percent)
			status_parts.append("产能 %.1f%%" % actual_percent)
			state_label = " · ".join(status_parts)
		var pending_state := int(pending_operating_states[i]) \
			if i < pending_operating_states.size() else 255
		if pending_state == 0 and operating_state != 0:
			state_meta += (" · " if not state_meta.is_empty() else "") + "下期恢复正常经营"
		elif pending_state == 1 and operating_state != 1:
			state_meta += (" · " if not state_meta.is_empty() else "") + "下期转入亏损停产"
		var headline_profit_label := "利润" if profit >= 0 else "亏损"
		var headline_profit := "%s%s" % ["+" if profit > 0 else "", _money_text(profit)]
		if is_loss_suspended:
			headline_profit_label = "状态"
			headline_profit = "停产"
		elif not is_available:
			headline_profit_label = "状态"
			headline_profit = "停用"
		if is_loss_suspended:
			finance.warning = "停产中 · 利润率取自上一经营期"
		rows.append({
			"id": "building_%d_%d" % [type_idx, i],
			"name": String(type_names[type_idx]) if type_idx >= 0 and type_idx < type_names.size() else (String(type_ids[type_idx]) if type_idx >= 0 and type_idx < type_ids.size() else "建筑"),
			"building_type_id": building_id,
			"count": "%d 栋" % count,
			"owner": "业主 · %s" % _owner_profession_name(snapshot, int(owner_signatures[i]) if i < owner_signatures.size() else -1),
			"status": state_label,
			"state_summary": {"label": state_label, "detail": state_detail,
				"meta": state_meta, "accent": state_accent,
				"icon": "warning"} \
				if show_state_summary else {},
			"profit": headline_profit,
			"profit_label": headline_profit_label,
			"accent": state_accent if show_state_summary else (UITokens.GOOD if profit > 0 else (UITokens.RISK if profit < 0 else UITokens.TEXT_MUTED)),
			"icon": _building_icon(building_id, snapshot, type_idx), "job_rows": job_rows,
			"production_rows": production_rows, "finance": finance, "visible": true,
		})
	_append_construction_rows(rows, snapshot, type_ids, type_names)
	var total_count := _sum_i64(snapshot.get("building_counts_by_type", PackedInt64Array()))
	return {
		"insights": [{"id": "buildings_empty", "text": "此地块当前没有建筑。", "accent": UITokens.TEXT_MUTED, "icon": "building"}] if rows.is_empty() else [],
		"metrics": [{"id": "building_total", "title": "建筑总数", "value": "%s 栋" % UITokens.format_compact_number_cn(float(total_count), 1), "subtitle": "%d 个业主建筑组" % group_types.size(), "accent": UITokens.ACCENT, "icon": "building"}],
		"construction": build_construction_options(cell_idx),
		"building_rows": rows,
	}


func build_construction_options(cell_idx: int, search: String = "",
		offset: int = 0) -> Dictionary:
	if cell_idx < 0 or _generator == null \
			or not _generator.has_method("get_country_facade") \
			or not _generator.has_method("get_economy_facade") \
			or not _generator.has_method("gameplay_start_report"):
		return {"available": false, "message": "建造暂不可用。"}
	var country = _generator.get_country_facade()
	var economy = _generator.get_economy_facade()
	var start: Dictionary = _generator.gameplay_start_report()
	if country == null or economy == null or not bool(start.get("ok", false)):
		return {"available": false, "message": "国家档案暂不可用。"}
	var player_summary: Dictionary = country.cell_summary(int(start.get("cell", -1)))
	var target_summary: Dictionary = country.cell_summary(cell_idx)
	var player_handle := int(player_summary.get("country_handle", 0))
	if player_handle == 0 or not bool(target_summary.get("owned", false)) \
			or int(target_summary.get("country_handle", 0)) != player_handle:
		return {"available": false, "message": "只能在玩家领土内修建建筑。"}
	var page: Dictionary = economy.treasury_construction_options(
		player_handle, cell_idx, search, offset, 32)
	if not bool(page.get("ok", false)):
		return {"available": false, "message": "暂时无法取得建造报价。"}
	var price_by_good := _construction_market_prices(cell_idx)
	var unlocked_goods := _unlocked_good_ids(_market_snapshot(cell_idx))
	for raw in page.get("items", []):
		var item: Dictionary = raw
		_decorate_construction_item(item, economy, price_by_good, unlocked_goods)
	page["available"] = true
	return page


func _construction_market_prices(cell_idx: int) -> Dictionary:
	var prices := {}
	var snapshot := _market_snapshot(cell_idx)
	var ids: PackedStringArray = snapshot.get("good_ids", PackedStringArray())
	var values: PackedInt32Array = snapshot.get("price", PackedInt32Array())
	for index in range(mini(ids.size(), values.size())):
		prices[String(ids[index])] = int(values[index])
	return prices


func _decorate_construction_item(item: Dictionary, economy, prices: Dictionary,
		unlocked_goods: Dictionary = {}) -> void:
	var building_id := String(item.get("building_id", ""))
	item["icon"] = _building_icon(building_id)
	var placement: Dictionary = economy.building_placement_spec(StringName(building_id)) \
		if economy.has_method("building_placement_spec") else {}
	var job_spec: Dictionary = economy.building_job_spec(StringName(building_id)) \
		if economy.has_method("building_job_spec") else {}
	item["inputs"] = _construction_input_recipe_rows(placement, unlocked_goods)
	item["outputs"] = _construction_recipe_rows(placement, "output_good_ids",
		"output_quantities", "产出")
	var jobs: Array = []
	if bool(job_spec.get("ok", false)):
		jobs.append({"name": _construction_profession_name(
			String(job_spec.get("owner_profession", ""))),
			"slots": int(job_spec.get("owner_slots", 0)), "owner": true})
		var professions: PackedStringArray = job_spec.get(
			"employee_professions", PackedStringArray())
		var slots: PackedInt64Array = job_spec.get(
			"employee_slots", PackedInt64Array())
		for index in range(professions.size()):
			jobs.append({"name": _construction_profession_name(String(professions[index])),
				"slots": int(slots[index]) if index < slots.size() else 0,
				"owner": false})
	item["jobs"] = jobs
	for material_value in item.get("materials", []):
		var material: Dictionary = material_value
		var good_id := String(material.get("good_id", ""))
		var unit_price := int(prices.get(good_id, 0))
		material["unit_price"] = unit_price
		material["unit_price_text"] = _money_text(unit_price) if unit_price > 0 else "—"
		material["cost_text"] = _money_text(
			int(material.get("required", 0)) * unit_price / 1000) \
			if unit_price > 0 else "—"


func _construction_recipe_rows(placement: Dictionary, ids_key: String,
		quantities_key: String, label: String) -> Array:
	var rows: Array = []
	var ids: PackedStringArray = placement.get(ids_key, PackedStringArray())
	var quantities: PackedInt64Array = placement.get(quantities_key, PackedInt64Array())
	for index in range(ids.size()):
		var good_id := String(ids[index])
		rows.append({"name": _good_display_name(good_id),
			"quantity": "%.3f /日" % (float(quantities[index]) / 1000.0) \
				if index < quantities.size() else "—",
			"label": label})
	return rows


func _construction_input_recipe_rows(placement: Dictionary,
		unlocked_goods: Dictionary) -> Array:
	var rows: Array = []
	var ids: PackedStringArray = placement.get("input_good_ids", PackedStringArray())
	var quantities: PackedInt64Array = placement.get("input_quantities", PackedInt64Array())
	for index in range(ids.size()):
		rows.append({
			"name": _construction_input_candidate_label(placement, index, unlocked_goods),
			"quantity": "%.3f /日" % (float(quantities[index]) / 1000.0) \
				if index < quantities.size() else "—",
			"label": "原材料",
		})
	return rows


func _construction_input_candidate_label(placement: Dictionary, input_idx: int,
		unlocked_goods: Dictionary) -> String:
	var ids: PackedStringArray = placement.get("input_good_ids", PackedStringArray())
	var fallback_id := String(ids[input_idx]) if input_idx >= 0 and input_idx < ids.size() else ""
	var offsets: PackedInt32Array = placement.get(
		"input_candidate_offsets", PackedInt32Array())
	var candidates: PackedStringArray = placement.get(
		"input_candidate_good_ids", PackedStringArray())
	var efficiencies: PackedInt32Array = placement.get(
		"input_candidate_efficiency_q16", PackedInt32Array())
	if input_idx < 0 or input_idx + 1 >= offsets.size():
		return _format_input_candidate_label(fallback_id, 65536)
	var entries: Array[Dictionary] = []
	for candidate_idx in range(int(offsets[input_idx]), int(offsets[input_idx + 1])):
		if candidate_idx < 0 or candidate_idx >= candidates.size():
			continue
		entries.append({
			"id": String(candidates[candidate_idx]),
			"efficiency": int(efficiencies[candidate_idx]) \
				if candidate_idx < efficiencies.size() else 65536,
		})
	var enforce := not unlocked_goods.is_empty()
	var visible: Array[Dictionary] = []
	for entry in entries:
		if not enforce or bool(unlocked_goods.get(String(entry.id), false)):
			visible.append(entry)
	if visible.is_empty():
		visible = entries
	if visible.is_empty():
		return _format_input_candidate_label(fallback_id, 65536)
	visible.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var left_efficiency := int(a.efficiency)
		var right_efficiency := int(b.efficiency)
		if left_efficiency != right_efficiency:
			return left_efficiency < right_efficiency
		return String(a.id) < String(b.id))
	var labels := PackedStringArray()
	for entry in visible:
		labels.append(_format_input_candidate_label(
			String(entry.id), int(entry.efficiency)))
	return " / ".join(labels)


func _unlocked_good_ids(snapshot: Dictionary) -> Dictionary:
	var ids: PackedStringArray = snapshot.get("good_ids", PackedStringArray())
	var available: PackedByteArray = snapshot.get(
		"good_technology_available", PackedByteArray())
	var unlocked := {}
	if ids.is_empty() or available.size() != ids.size():
		return unlocked
	for index in range(ids.size()):
		if available[index] != 0:
			unlocked[String(ids[index])] = true
	return unlocked


func _construction_profession_name(profession_id: String) -> String:
	if _generator != null and _generator.has_method("get_economy_facade"):
		var facade = _generator.get_economy_facade()
		if facade != null and facade.has_method("profession_display_name"):
			return String(facade.profession_display_name(StringName(profession_id)))
	return profession_id


func _append_recipe_rows(rows: Array, snapshot: Dictionary, type_idx: int, kind: String,
		actual_total: int, building_count: int, period_days: int, group_idx: int = -1) -> void:
	var offsets: PackedInt32Array = snapshot.get("building_%s_offsets" % kind, PackedInt32Array())
	var good_indices: PackedInt32Array = snapshot.get("building_%s_good_ids" % kind, PackedInt32Array())
	var quantities: PackedInt64Array = snapshot.get("building_%s_quantities" % kind, PackedInt64Array())
	var good_ids: PackedStringArray = snapshot.get("good_ids", PackedStringArray())
	if type_idx < 0 or type_idx + 1 >= offsets.size():
		return
	var begin := int(offsets[type_idx])
	var end := int(offsets[type_idx + 1])
	var recipe_total := 0
	for cursor in range(begin, end):
		recipe_total += int(quantities[cursor]) if cursor < quantities.size() else 0
	for cursor in range(begin, end):
		var good_idx := int(good_indices[cursor]) if cursor < good_indices.size() else -1
		var stable_id := String(good_ids[good_idx]) if good_idx >= 0 and good_idx < good_ids.size() else "unknown"
		var quantity := int(quantities[cursor]) if cursor < quantities.size() else 0
		var actual := int(float(actual_total) * float(quantity) / float(recipe_total)) if recipe_total > 0 else 0
		var good_label := _input_candidate_label(
			snapshot, cursor, cursor - begin, group_idx, stable_id) \
			if kind == "input" else _good_display_name(stable_id)
		rows.append({"id": "%s_%d" % [kind, cursor], "name": "%s · %s" % ["原材料" if kind == "input" else "产出", good_label], "value": _actual_daily_rate(actual, building_count, period_days), "icon": "resource", "accent": UITokens.RESOURCE})


func _input_candidate_label(snapshot: Dictionary, input_idx: int, local_input_idx: int,
		group_idx: int, fallback_id: String) -> String:
	var offsets: PackedInt32Array = snapshot.get(
		"building_input_candidate_offsets", PackedInt32Array())
	var candidates: PackedInt32Array = snapshot.get(
		"building_input_candidate_good_ids", PackedInt32Array())
	var efficiencies: PackedInt32Array = snapshot.get(
		"building_input_candidate_efficiency_q16", PackedInt32Array())
	var good_ids: PackedStringArray = snapshot.get("good_ids", PackedStringArray())
	if input_idx < 0 or input_idx + 1 >= offsets.size():
		return _good_display_name(fallback_id)
	var labels := PackedStringArray()
	for candidate_idx in range(offsets[input_idx], offsets[input_idx + 1]):
		var good_idx := int(candidates[candidate_idx]) if candidate_idx < candidates.size() else -1
		if good_idx < 0 or good_idx >= good_ids.size():
			continue
		var efficiency := int(efficiencies[candidate_idx]) if candidate_idx < efficiencies.size() else 65536
		labels.append(_format_input_candidate_label(String(good_ids[good_idx]), efficiency))
	var candidate_label := " / ".join(labels) \
		if not labels.is_empty() else _good_display_name(fallback_id)
	var selected_offsets: PackedInt32Array = snapshot.get(
		"group_input_selected_offsets", PackedInt32Array())
	var selected_goods: PackedInt32Array = snapshot.get(
		"group_input_selected_good_ids", PackedInt32Array())
	if group_idx >= 0 and group_idx + 1 < selected_offsets.size():
		var selected_idx := int(selected_offsets[group_idx]) + local_input_idx
		if selected_idx >= int(selected_offsets[group_idx]) \
				and selected_idx < int(selected_offsets[group_idx + 1]) \
				and selected_idx < selected_goods.size():
			var selected_good := int(selected_goods[selected_idx])
			if selected_good >= 0 and selected_good < good_ids.size():
				candidate_label += "（当前：%s）" % _good_display_name(String(good_ids[selected_good]))
	return candidate_label


func _append_resource_recipe_rows(rows: Array, snapshot: Dictionary, type_idx: int,
		actual_total: int, building_count: int, period_days: int) -> void:
	var offsets: PackedInt32Array = snapshot.get("building_resource_offsets", PackedInt32Array())
	var resource_indices: PackedInt32Array = snapshot.get("building_production_resource_ids", PackedInt32Array())
	var quantities: PackedInt64Array = snapshot.get("building_production_resource_quantities", PackedInt64Array())
	var modes: PackedInt32Array = snapshot.get("building_production_resource_modes", PackedInt32Array())
	var access_modes: PackedInt32Array = snapshot.get(
		"building_production_resource_access_modes", PackedInt32Array())
	var resource_ids: PackedStringArray = snapshot.get("building_resource_ids", PackedStringArray())
	if type_idx < 0 or type_idx + 1 >= offsets.size(): return
	var begin := int(offsets[type_idx])
	var end := int(offsets[type_idx + 1])
	var recipe_total := 0
	for cursor in range(begin, end): recipe_total += int(quantities[cursor]) if cursor < quantities.size() else 0
	for cursor in range(begin, end):
		var resource_idx := int(resource_indices[cursor]) if cursor < resource_indices.size() else -1
		var stable_id := String(resource_ids[resource_idx]) if resource_idx >= 0 and resource_idx < resource_ids.size() else "unknown"
		var quantity := int(quantities[cursor]) if cursor < quantities.size() else 0
		var mode := int(modes[cursor]) if cursor < modes.size() else 0
		var access_mode := int(access_modes[cursor]) if cursor < access_modes.size() else 0
		var actual := int(float(actual_total) * float(quantity) / float(recipe_total)) if recipe_total > 0 else 0
		var access_label := "邻域 · " if access_mode == 1 else ""
		var row_name := "自然资源 · %s%s" % [access_label, _resource_display_name(stable_id)]
		var availability := "不足" if _building_resource_depleted(snapshot, type_idx) else "充足"
		var row_value := "每栋 %.3f · %s" % [float(quantity) / 1000.0, availability] if mode == 1 \
			else "%s · %s" % [_actual_daily_rate(actual, building_count, period_days), availability]
		rows.append({"id": "natural_input_%d" % cursor,
			"name": row_name,
			"value": row_value,
			"icon": "eco", "accent": UITokens.ECO})


func _append_resource_generation_rows(rows: Array, snapshot: Dictionary, type_idx: int,
		actual_total: int, building_count: int, period_days: int) -> void:
	var offsets: PackedInt32Array = snapshot.get("building_resource_generation_offsets", PackedInt32Array())
	var resource_indices: PackedInt32Array = snapshot.get("building_resource_generation_ids", PackedInt32Array())
	var quantities: PackedInt64Array = snapshot.get("building_resource_generation_quantities", PackedInt64Array())
	var resource_ids: PackedStringArray = snapshot.get("building_resource_ids", PackedStringArray())
	if type_idx < 0 or type_idx + 1 >= offsets.size(): return
	var begin := int(offsets[type_idx])
	var end := int(offsets[type_idx + 1])
	var recipe_total := 0
	for cursor in range(begin, end): recipe_total += int(quantities[cursor]) if cursor < quantities.size() else 0
	for cursor in range(begin, end):
		var resource_idx := int(resource_indices[cursor]) if cursor < resource_indices.size() else -1
		var stable_id := String(resource_ids[resource_idx]) if resource_idx >= 0 and resource_idx < resource_ids.size() else "unknown"
		var quantity := int(quantities[cursor]) if cursor < quantities.size() else 0
		var actual := int(float(actual_total) * float(quantity) / float(recipe_total)) if recipe_total > 0 else 0
		rows.append({"id": "natural_generation_%d" % cursor,
			"name": "培育 · %s" % _resource_display_name(stable_id),
			"value": "%s · 待资源周期生效" % _actual_daily_rate(actual, building_count, period_days),
			"icon": "growth", "accent": UITokens.GOOD})


func _building_resource_depleted(snapshot: Dictionary, type_idx: int) -> bool:
	var offsets: PackedInt32Array = snapshot.get("building_resource_offsets", PackedInt32Array())
	var resource_indices: PackedInt32Array = snapshot.get("building_production_resource_ids", PackedInt32Array())
	var access_modes: PackedInt32Array = snapshot.get(
		"building_production_resource_access_modes", PackedInt32Array())
	var effective: PackedInt64Array = snapshot.get("building_resource_effective_reserve", PackedInt64Array())
	var accessible: PackedInt64Array = snapshot.get(
		"building_resource_accessible_effective_reserve", PackedInt64Array())
	if type_idx < 0 or type_idx + 1 >= offsets.size() or offsets[type_idx] == offsets[type_idx + 1]:
		return false
	for cursor in range(offsets[type_idx], offsets[type_idx + 1]):
		var resource_idx := int(resource_indices[cursor]) if cursor < resource_indices.size() else -1
		var values := accessible if cursor < access_modes.size() and int(access_modes[cursor]) == 1 else effective
		if resource_idx >= 0 and resource_idx < values.size() and int(values[resource_idx]) > 0:
			return false
	return true


func _resource_effective_text(snapshot: Dictionary, resource_idx: int, access_mode: int = 0) -> String:
	var reserves: PackedInt64Array = snapshot.get(
		"building_resource_accessible_current_reserve" if access_mode == 1 else \
		"building_resource_current_reserve", PackedInt64Array())
	var effective: PackedInt64Array = snapshot.get(
		"building_resource_accessible_effective_reserve" if access_mode == 1 else \
		"building_resource_effective_reserve", PackedInt64Array())
	var pending: PackedInt64Array = snapshot.get(
		"building_resource_accessible_pending_change" if access_mode == 1 else \
		"building_resource_pending_change", PackedInt64Array())
	var reserve := int(reserves[resource_idx]) if resource_idx >= 0 and resource_idx < reserves.size() else 0
	var available := int(effective[resource_idx]) if resource_idx >= 0 and resource_idx < effective.size() else 0
	var queued := int(pending[resource_idx]) if resource_idx >= 0 and resource_idx < pending.size() else 0
	return "%.3f（储量 %.3f，待处理 %+.3f）" % [
		float(available) / 1000.0, float(reserve) / 1000.0, float(queued) / 1000.0]


func _append_construction_rows(rows: Array, snapshot: Dictionary, type_ids: PackedStringArray, type_names: PackedStringArray) -> void:
	var types: PackedInt32Array = snapshot.get("construction_type_ids", PackedInt32Array())
	var owners: PackedInt32Array = snapshot.get("construction_owner_signature_ids", PackedInt32Array())
	var counts: PackedInt64Array = snapshot.get("construction_counts", PackedInt64Array())
	var ready_days: PackedInt64Array = snapshot.get("construction_ready_days", PackedInt64Array())
	for i in range(types.size()):
		var type_idx := int(types[i])
		var building_id := String(type_ids[type_idx]) \
			if type_idx >= 0 and type_idx < type_ids.size() else ""
		rows.append({"id": "construction_%d_%d" % [type_idx, i], "name": String(type_names[type_idx]) if type_idx >= 0 and type_idx < type_names.size() else (building_id if not building_id.is_empty() else "建筑"), "building_type_id": building_id, "count": "%d 栋" % (int(counts[i]) if i < counts.size() else 0), "owner": "业主 · %s" % _owner_profession_name(snapshot, int(owners[i]) if i < owners.size() else -1), "status": "建造中 · 第 %d 日完工" % (int(ready_days[i]) if i < ready_days.size() else 0), "profit": "—", "profit_label": "未投产", "accent": UITokens.WARN, "icon": _building_icon(building_id, snapshot, type_idx), "job_rows": [], "production_rows": [], "finance": {}, "visible": true})


func _building_icon(type_id: String, snapshot: Dictionary = {}, type_idx: int = -1) -> StringName:
	if type_id.is_empty():
		return &"economy.building"
	var output_offsets: PackedInt32Array = snapshot.get(
		"building_output_offsets", PackedInt32Array())
	var output_good_indices: PackedInt32Array = snapshot.get(
		"building_output_good_ids", PackedInt32Array())
	var good_ids: PackedStringArray = snapshot.get("good_ids", PackedStringArray())
	var kinds: PackedInt32Array = snapshot.get("building_kinds", PackedInt32Array())
	if type_idx >= 0 and type_idx + 1 < output_offsets.size():
		var output_pos := int(output_offsets[type_idx])
		if output_pos < int(output_offsets[type_idx + 1]) \
				and output_pos >= 0 and output_pos < output_good_indices.size():
			var good_idx := int(output_good_indices[output_pos])
			if good_idx >= 0 and good_idx < good_ids.size():
				var kind := int(kinds[type_idx]) if type_idx < kinds.size() else 1
				return IconCatalog.building_semantic(type_id, good_ids[good_idx], kind)
	if type_id.contains("hearth"):
		return &"economy.building.hearth"
	if type_id.contains("gathering"):
		return &"economy.building.gathering"
	if type_id.contains("merchant") or type_id.contains("market") \
			or type_id.contains("trade"):
		return &"economy.building.market"
	if type_id.contains("fish"):
		return &"economy.building.fishing"
	if type_id.contains("hunting"):
		return &"economy.building.hunting"
	if type_id.contains("kitchen") or type_id.contains("food") \
			or type_id.contains("slaughterhouse"):
		return &"economy.building.food"
	if type_id.contains("farm") or type_id.contains("estate") \
			or type_id.contains("pasture") or type_id.contains("rice") \
			or type_id.contains("potato") or type_id.contains("wheat") \
			or type_id.contains("cotton") or type_id.contains("flax") \
			or type_id.contains("rubber_tree") or type_id.contains("spice") \
			or type_id.contains("herbs"):
		return &"economy.building.farm"
	if type_id.contains("timber") or type_id.contains("lumber"):
		return &"economy.building.forestry"
	if type_id.contains("mine") or type_id.contains("ore_") \
			or type_id.contains("quarry") or type_id.contains("stone_collector") \
			or type_id.contains("coal") or type_id.contains("oil_collector") \
			or type_id.contains("natural_gas") or type_id.contains("bauxite") \
			or type_id.contains("limestone") or type_id.contains("silica") \
			or type_id.contains("phosphate") or type_id.contains("salt") \
			or type_id.contains("sulfur") or type_id.contains("rare_earth") \
			or type_id.contains("flint"):
		return &"economy.building.mine"
	if type_id.contains("power"):
		return &"economy.building.power"
	if type_id.contains("shipyard"):
		return &"economy.building.shipyard"
	if type_id.contains("rail"):
		return &"economy.building.transport"
	if type_id.contains("scientific") or type_id.contains("medicine") \
			or type_id.contains("pharmaceutical"):
		return &"economy.building.science"
	if type_id.contains("workshop") or type_id.contains("kiln") \
			or type_id.contains("smith") or type_id.contains("tailor") \
			or type_id.contains("tannery") or type_id.contains("scriptorium"):
		return &"economy.building.workshop"
	if type_id.contains("plant") or type_id.contains("works") \
			or type_id.contains("mill") or type_id.contains("factory"):
		return &"economy.building.factory"
	if type_id.contains("school") or type_id.contains("hospital") \
			or type_id.contains("office"):
		return &"economy.building.service"
	return &"economy.building"


func _owner_profession_name(snapshot: Dictionary, signature_idx: int) -> String:
	var signature_professions: PackedInt32Array = snapshot.get("signature_profession_ids", PackedInt32Array())
	return _profession_name(snapshot, int(signature_professions[signature_idx]) if signature_idx >= 0 and signature_idx < signature_professions.size() else -1)


func _profession_name(snapshot: Dictionary, profession_idx: int) -> String:
	var names: PackedStringArray = snapshot.get("profession_display_names", PackedStringArray())
	var ids: PackedStringArray = snapshot.get("profession_stable_ids", PackedStringArray())
	if profession_idx >= 0 and profession_idx < names.size(): return String(names[profession_idx])
	return String(ids[profession_idx]) if profession_idx >= 0 and profession_idx < ids.size() else "未知阶层"


func _format_input_candidate_label(good_id: String, efficiency_q16: int) -> String:
	var label := _good_display_name(good_id)
	if efficiency_q16 != 65536:
		label += " %.0f%%" % (float(efficiency_q16) * 100.0 / 65536.0)
	return label


func _good_display_name(stable_id: String) -> String:
	var profile = GoodProfileRegistry.profile_by_id(stable_id)
	return String(profile.display_name) if profile != null and String(profile.display_name) != "" else stable_id


func _resource_display_name(stable_id: String) -> String:
	for profile in ResourceProfileRegistry.ordered():
		if String(profile.id) == stable_id:
			return String(profile.display_name) if String(profile.display_name) != "" else stable_id
	return stable_id


func _fill_percent(filled: int, required: int) -> float:
	return float(filled) * 100.0 / float(required) if required > 0 else 100.0


func _actual_daily_rate(actual_total: int, building_count: int, period_days: int) -> String:
	var divisor := maxi(1, building_count) * maxi(1, period_days)
	return "%.3f 单位/栋/日" % (float(actual_total) / 1000.0 / float(divisor))


func _sum_i64(values: PackedInt64Array) -> int:
	var total := 0
	for value in values:
		total += int(value)
	return total


func _money_text(subunits: int) -> String:
	return UITokens.format_compact_number_cn(float(subunits) / 10000.0, 2)


func _goods_unit_text(subunits: int) -> String:
	return "%s 单位" % UITokens.format_compact_number_cn(float(maxi(0, subunits)) / 1000.0, 2)


func _packed_i64_at(values: PackedInt64Array, index: int) -> int:
	return int(values[index]) if index >= 0 and index < values.size() else 0


func _market_trade_enabled(enabled: PackedByteArray, index: int) -> bool:
	if enabled.is_empty() or index < 0 or index >= enabled.size():
		return true
	return enabled[index] != 0


func _trade_arrival_days(next_arrival_day: int, sample_day: int) -> int:
	if next_arrival_day < 0:
		return -1
	return maxi(0, next_arrival_day - sample_day)


func _market_trade_insight_text(in_transit_kinds: int, arrival_days: int) -> String:
	if arrival_days < 0:
		return "%d 种物资在途。" % in_transit_kinds
	if arrival_days == 0:
		return "%d 种物资在途，下一批今日到货。" % in_transit_kinds
	return "%d 种物资在途，下一批还有 %d 日到货。" % [in_transit_kinds, arrival_days]


func _market_trade_subtitle(in_transit_kinds: int, arrival_days: int) -> String:
	if in_transit_kinds <= 0:
		return "无在途"
	if arrival_days < 0:
		return "在途 %d 种" % in_transit_kinds
	if arrival_days == 0:
		return "在途 %d 种 · 今日到货" % in_transit_kinds
	return "在途 %d 种 · %d 日后到货" % [in_transit_kinds, arrival_days]


func _cashflow_source_name(source_id: String, income: bool) -> String:
	match source_id:
		"wages": return "工资"
		"owner_operations": return "业主经营"
		"merchant_household_sales": return "居民销售"
		"merchant_business_sales": return "产业供货"
		"transfer": return "转移支付"
		"household_consumption": return "生活消费"
		"production_inputs": return "生产原料"
		"owner_wages": return "雇员工资"
		"construction": return "建设"
		"merchant_procurement": return "商品收购"
		"producer_support_issuance": return "托底收购"
		"income_tax": return "所得税"
		"consumption_tax": return "消费税"
		"business_tax": return "营业税"
		"income_subsidy": return "收入补贴"
		"consumption_subsidy": return "消费补贴"
		"business_subsidy": return "经营补贴"
		"fiscal_escrow": return "财政托管"
		_: return "其他收入" if income else "其他支出"


func _weather_field(cell: HexCell, idx: int) -> Dictionary:
	var has_wf: bool = _view_adapter.get_weather_field_init(idx) if _view_adapter != null else bool(cell.weather_field_initialized)
	var precip: float = _view_adapter.get_weather_precip(idx) if _view_adapter != null else float(cell.weather_precip)
	var vapor: float = _view_adapter.get_weather_vapor(idx) if _view_adapter != null else float(cell.weather_vapor)
	var cloud: float = _view_adapter.get_weather_cloud(idx) if _view_adapter != null else float(cell.weather_cloud)
	if not has_wf:
		precip = float(cell.current_state.get("weather_precip", precip))
		vapor = float(cell.current_state.get("weather_vapor", vapor))
		cloud = float(cell.current_state.get("weather_cloud", cloud))
	return {"precip": clampf(precip, 0.0, 1.0), "vapor": clampf(vapor, 0.0, 1.0), "cloud": clampf(cloud, 0.0, 1.0)}


func _resource_visibility_context(cell_idx: int) -> Dictionary:
	var context := {
		"enforce_discovery": false,
		"technology_ids": PackedStringArray(),
		"enforce_extraction": false,
		"extractable_resource_ids": {},
	}
	if _generator == null or not _generator.has_method("get_country_facade"):
		return context
	var country_facade = _generator.get_country_facade()
	if country_facade == null or not country_facade.has_method("cell_summary") \
			or not country_facade.has_method("snapshot"):
		return context
	var summary: Dictionary = country_facade.cell_summary(cell_idx)
	if not bool(summary.get("ok", false)):
		return context
	# 检查器是玩家视角：迷雾已经挡住未探索格，认矿用观察者已掌握科技，
	# 不能用地块所有者（无主地没有科技）的空集合把真实储量显示成「未配置」。
	var viewer := _completed_technology_ids(country_facade, _player_country_handle())
	if not bool(viewer.get("ok", false)) and bool(summary.get("owned", false)):
		viewer = _completed_technology_ids(
			country_facade, int(summary.get("country_handle", -1)))
	if bool(viewer.get("ok", false)):
		context.enforce_discovery = true
		context.technology_ids = viewer.get("technology_ids", PackedStringArray())
	elif not bool(summary.get("owned", false)):
		context.enforce_discovery = true
	var extractable := _extractable_resource_ids(_building_snapshot(cell_idx))
	if bool(extractable.get("ok", false)):
		context.enforce_extraction = true
		context.extractable_resource_ids = extractable.ids
	return context


func _completed_technology_ids(country_facade, handle: int) -> Dictionary:
	if handle <= 0 or country_facade == null or not country_facade.has_method("snapshot"):
		return {"ok": false}
	var country: Dictionary = country_facade.snapshot(handle)
	if not bool(country.get("ok", false)):
		return {"ok": false}
	return {
		"ok": true,
		"technology_ids": country.get("technology_ids", PackedStringArray()),
	}


func _extractable_resource_ids(snapshot: Dictionary) -> Dictionary:
	if not bool(snapshot.get("ok", false)):
		return {"ok": false}
	var kinds: PackedInt32Array = snapshot.get("building_kinds", PackedInt32Array())
	var available: PackedByteArray = snapshot.get(
		"building_technology_available", PackedByteArray())
	var offsets: PackedInt32Array = snapshot.get(
		"building_resource_offsets", PackedInt32Array())
	var resource_indices: PackedInt32Array = snapshot.get(
		"building_production_resource_ids", PackedInt32Array())
	var resource_ids: PackedStringArray = snapshot.get(
		"building_resource_ids", PackedStringArray())
	if kinds.is_empty() or available.size() != kinds.size() or offsets.size() != kinds.size() + 1:
		return {"ok": false}
	var ids := {}
	for type_id in range(kinds.size()):
		if kinds[type_id] != 0 or available[type_id] == 0:
			continue
		var begin := int(offsets[type_id])
		var end := int(offsets[type_id + 1])
		if begin < 0 or end < begin or end > resource_indices.size():
			return {"ok": false}
		for edge in range(begin, end):
			var resource_idx := int(resource_indices[edge])
			if resource_idx < 0 or resource_idx >= resource_ids.size():
				return {"ok": false}
			ids[StringName(resource_ids[resource_idx])] = true
	return {"ok": true, "ids": ids}


func _resource_state(idx: int, is_water: bool, visibility: Dictionary = {}) -> Array:
	ResourceProfileRegistry.ensure_loaded()
	var items: Array = []
	var enforce_discovery := bool(visibility.get("enforce_discovery", false))
	var technology_ids: PackedStringArray = visibility.get(
		"technology_ids", PackedStringArray())
	var enforce_extraction := bool(visibility.get("enforce_extraction", false))
	var extractable_resource_ids: Dictionary = visibility.get("extractable_resource_ids", {})
	var habitat_mask := 1 if not is_water else 0
	if _map != null and idx >= 0 and idx < _map.resource_habitat_mask_arr.size():
		habitat_mask = int(_map.resource_habitat_mask_arr[idx])
	var sample_day := _current_sample_day()
	for p in ResourceProfileRegistry.ordered():
		if enforce_discovery and not ResourceProfileRegistry.discovery_visible(p, technology_ids):
			continue
		var resource_id := String(p.id)
		var name_cn: String = String(p.display_name) if String(p.display_name) != "" else String(p.id)
		var available := ResourceProfileRegistry.habitat_available(p, habitat_mask)
		var extractable := not enforce_extraction or extractable_resource_ids.has(StringName(p.id))
		var reference_reserve := _resource_reference_reserve(p)
		var reserve := 0.0
		var delta := 0.0
		if not available:
			items.append({
				"id": resource_id,
				"name": name_cn,
				"icon": ResourceProfileRegistry.icon_key(p),
				"available": false,
				"extractable": extractable,
				"reserve": 0.0,
				"delta": 0.0,
				"density_ratio": 0.0,
				"rank": -1.0,
			})
			continue
		reserve = _resource_reserve(p, idx)
		var field: String = ResourceProfileRegistry.reserve_map_field(p)
		var key := "%d:%s" % [idx, field]
		delta = _sample_daily_delta(_resource_prev_reserves, key, reserve, sample_day)
		var density_ratio := reserve / reference_reserve
		var relative_delta := absf(delta) / reference_reserve
		items.append({
			"id": resource_id,
			"name": name_cn,
			"icon": ResourceProfileRegistry.icon_key(p),
			"available": available,
			"extractable": extractable,
			"reserve": reserve,
			"delta": delta,
			"density_ratio": density_ratio,
			"rank": density_ratio + relative_delta * 8.0,
		})
	return items


func _resource_reserve(profile, idx: int) -> float:
	if _map == null:
		return 0.0
	var field: String = ResourceProfileRegistry.reserve_map_field(profile)
	if field == "":
		return 0.0
	var arr: PackedFloat32Array = _map.get(field)
	if idx >= 0 and idx < arr.size():
		return float(arr[idx])
	return 0.0


func _resource_reference_reserve(profile: ResourceProfile) -> float:
	return ResourceProfileRegistry.reference_reserve(profile)


func _habitability_score(temp: float, moist: float, vitality: float, elev: float, passable_land: bool, is_water: bool) -> float:
	if is_water:
		return clampf((1.0 - absf(temp - 0.48) / 0.52) * 0.35 + moist * 0.20 + 0.20, 0.0, 1.0)
	var temp_score := clampf(1.0 - absf(temp - 0.52) / 0.52, 0.0, 1.0)
	var moist_score := clampf(1.0 - absf(moist - 0.58) / 0.58, 0.0, 1.0)
	var elev_score := clampf(1.0 - maxf(elev - 0.78, 0.0) / 0.22, 0.0, 1.0)
	var pass_score := 1.0 if passable_land else 0.25
	return clampf(temp_score * 0.28 + moist_score * 0.24 + vitality * 0.24 + elev_score * 0.14 + pass_score * 0.10, 0.0, 1.0)


func _score_caption(v: float) -> String:
	if v >= 0.80: return "优良"
	if v >= 0.62: return "可发展"
	if v >= 0.42: return "有约束"
	if v >= 0.24: return "困难"
	return "严峻"


func _score_color(v: float) -> Color:
	if v >= 0.70: return UITokens.GOOD
	if v >= 0.45: return UITokens.WARN
	return UITokens.RISK


func _terrain(cell: HexCell, idx: int) -> int:
	return _view_adapter.get_terrain(idx) if _view_adapter != null else int(cell.terrain)


func _landform(cell: HexCell, idx: int) -> int:
	return _view_adapter.get_landform(idx) if _view_adapter != null else int(cell.landform)


func _vegetation(cell: HexCell, idx: int) -> int:
	return _view_adapter.get_vegetation(idx) if _view_adapter != null else int(cell.vegetation)


func _cover(cell: HexCell, idx: int) -> int:
	return _view_adapter.get_cover(idx) if _view_adapter != null else int(cell.cover)


func _temp(cell: HexCell, idx: int) -> float:
	return clampf(_view_adapter.get_temp(idx) if _view_adapter != null else float(cell.temperature), 0.0, 1.0)


func _moisture(cell: HexCell, idx: int) -> float:
	return clampf(_view_adapter.get_moisture(idx) if _view_adapter != null else float(cell.moisture), 0.0, 1.0)


func _base_moisture(cell: HexCell, idx: int) -> float:
	return clampf(_view_adapter.get_base_moisture(idx) if _view_adapter != null else float(cell.base_moisture), 0.0, 1.0)


func _elevation(cell: HexCell, idx: int) -> float:
	return clampf(_view_adapter.get_elevation(idx) if _view_adapter != null else float(cell.elevation), 0.0, 1.0)


func _snow_cover(cell: HexCell, idx: int) -> float:
	return clampf(_view_adapter.get_snow_cover(idx) if _view_adapter != null else float(cell.snow_cover), 0.0, 1.0)


func _vitality(cell: HexCell, landform_v: int) -> float:
	return 0.0 if LandformType.is_water(landform_v) else clampf(float(cell.vegetation_vitality), 0.0, 1.0)


func _weather_intensity(cell: HexCell, idx: int) -> float:
	return clampf(_view_adapter.get_weather_intensity(idx) if _view_adapter != null else float(cell.weather_intensity), 0.0, 1.0)


func _weather_name(cell: HexCell, idx: int) -> String:
	var has_wf: bool = _view_adapter.get_weather_field_init(idx) if _view_adapter != null else bool(cell.weather_field_initialized)
	var wt: int = (_view_adapter.get_weather_type(idx) if _view_adapter != null else int(cell.weather_type)) if has_wf else WeatherType.WT.CLEAR
	var wi: float = _weather_intensity(cell, idx) if has_wf else 0.0
	if wt == WeatherType.WT.CLEAR or wi <= 0.05:
		return "晴朗"
	return WeatherType.name_cn(wt)


func _has_river(cell: HexCell, idx: int) -> bool:
	return _view_adapter.get_has_river(idx) if _view_adapter != null else bool(cell.has_river)


func _ocean_current(cell: HexCell, idx: int) -> Vector2:
	return _view_adapter.get_ocean_current(idx) if _view_adapter != null else cell.ocean_current


func _wind_vector(cell: HexCell, idx: int) -> Vector2:
	return _view_adapter.get_wind_vector(idx) if _view_adapter != null else cell.wind_vector


func _wind_speed(cell: HexCell, idx: int) -> float:
	var speed: float = _view_adapter.get_wind_speed(idx) if _view_adapter != null else float(cell.wind_speed)
	if speed <= 0.0001:
		speed = _wind_vector(cell, idx).length()
	return speed


func _upwelling(cell: HexCell, idx: int) -> float:
	return _view_adapter.get_upwelling_strength(idx) if _view_adapter != null else float(cell.upwelling_strength)


func _adapter_float(method: String, idx: int, fallback: float) -> float:
	if _view_adapter != null and _view_adapter.has_method(method):
		return clampf(float(_view_adapter.call(method, idx)), 0.0, 1.0)
	return clampf(fallback, 0.0, 1.0)


func _succession_text(cell: HexCell) -> String:
	if cell._vitality_low_streak > 0:
		var rem: int = int(_generator._c().succession_degrade_days if _generator != null else 180) - int(cell._vitality_low_streak)
		return "退化倒计时 %d 天" % maxi(rem, 0) if rem <= 45 else "存在退化压力"
	if cell._vitality_high_streak > 0:
		var rem2: int = int(_generator._c().succession_upgrade_days if _generator != null else 360) - int(cell._vitality_high_streak)
		return "升级倒计时 %d 天" % maxi(rem2, 0) if rem2 <= 60 else "存在恢复趋势"
	return ""


func _history_values(cell: HexCell) -> Array:
	var values := []
	var hist: Array = cell.vegetation_history if not cell.vegetation_history.is_empty() else cell.biome_history
	for raw in hist:
		values.append(float(raw))
	if values.size() < 2:
		values.append(float(cell.vegetation))
		values.append(float(cell.vegetation))
	return _densify_series(values, 9)


func _history_sentence(cell: HexCell) -> String:
	var hist: Array = cell.vegetation_history
	if hist.is_empty():
		return "暂无记录"
	var names := PackedStringArray()
	for raw in hist:
		names.append(VegetationType.name_cn(int(raw)))
	return " → ".join(names)


func _temperature_chart(chart_id: String, title: String, idx: int, current_temp: float) -> Dictionary:
	return {
		"id": chart_id,
		"title": title,
		"values": _temperature_memory(idx, current_temp),
		"accent": UITokens.CLIMATE,
		"min_value": 0.0,
		"max_value": 1.0,
		"window_size": TEMPERATURE_HISTORY_CAPACITY,
		"value_text": "现值 %.2f" % current_temp,
	}


func _temperature_memory(idx: int, current_temp: float) -> Array:
	var series: Dictionary = _temperature_histories.get(idx, {})
	if series.is_empty():
		return [current_temp]
	return (series.get("values", []) as Array).duplicate()


func _record_temperature_sample(idx: int, day_idx: int, value: float) -> void:
	if not _temperature_histories.has(idx):
		if _temperature_history_order.size() >= TEMPERATURE_HISTORY_CACHE_LIMIT:
			var evicted_idx: int = int(_temperature_history_order.pop_front())
			_temperature_histories.erase(evicted_idx)
		_temperature_history_order.append(idx)
		_temperature_histories[idx] = {"days": [], "values": []}
	var series: Dictionary = _temperature_histories[idx]
	var days: Array = series.get("days", [])
	var samples: Array = series.get("values", [])
	var sample_value := clampf(value, 0.0, 1.0)
	if not days.is_empty():
		var last_idx := days.size() - 1
		var last_day := int(days[last_idx])
		if day_idx < last_day:
			return
		if day_idx == last_day:
			samples[last_idx] = sample_value
			series["values"] = samples
			_temperature_histories[idx] = series
			return
	days.append(day_idx)
	samples.append(sample_value)
	while samples.size() > TEMPERATURE_HISTORY_CAPACITY:
		days.pop_front()
		samples.pop_front()
	series["days"] = days
	series["values"] = samples
	_temperature_histories[idx] = series


func _current_sample_day() -> int:
	return _world_clock.day_index() if _world_clock != null else 0


func _daily_delta_text(v: float) -> String:
	if is_nan(v):
		return "—"
	if absf(v) < 0.0001:
		return "约0"
	return "%s%s" % ["+" if v > 0.0 else "", UITokens.format_compact_number_cn(v, 2)]


func _sample_daily_delta(cache: Dictionary, key: String, value: float, day: int) -> float:
	if not cache.has(key):
		cache[key] = {"value": value, "day": day, "daily": NAN}
		return NAN
	var previous: Dictionary = cache[key]
	var previous_day := int(previous.get("day", day))
	if day <= previous_day:
		return float(previous.get("daily", NAN))
	var daily := (value - float(previous.get("value", value))) / float(day - previous_day)
	cache[key] = {"value": value, "day": day, "daily": daily}
	return daily


func _relative_sea_level_text(elev: float, sea: float) -> String:
	var delta := elev - sea
	return "Δ海面 %+.2f" % delta


func _resource_index_text(v: float) -> String:
	return UITokens.format_compact_number_cn(v, 2)


func _intensity_text(v: float) -> String:
	if v < 0.15: return "强度轻微"
	if v < 0.40: return "强度中等"
	if v < 0.70: return "强度明显"
	return "强度剧烈"


func _cloud_band(v: float) -> String:
	if v < 0.15: return "晴空"
	if v < 0.45: return "少云"
	if v < 0.75: return "多云"
	return "阴云"


func _precip_band(v: float) -> String:
	if v < 0.05: return "无雨"
	if v < 0.25: return "微雨"
	if v < 0.55: return "降雨"
	if v < 0.80: return "强雨"
	return "暴雨"


func _cover_intensity_band(v: float) -> String:
	if v < 0.05: return "无"
	if v < 0.25: return "薄"
	if v < 0.55: return "中"
	if v < 0.80: return "厚"
	return "封冻"


func _stress_band(v: float) -> String:
	if v < 0.20: return "低"
	if v < 0.50: return "中"
	if v < 0.75: return "高"
	return "极高"


func _resource_density_band(v: float) -> String:
	if v < 0.05: return "贫乏"
	if v < 0.25: return "稀少"
	if v < 0.55: return "可采"
	if v < 0.80: return "富集"
	return "丰饶"


func _history_badges(cell: HexCell) -> Array:
	var badges := []
	var hist: Array = cell.vegetation_history if not cell.vegetation_history.is_empty() else cell.biome_history
	var start := maxi(hist.size() - 6, 0)
	for i in range(start, hist.size()):
		badges.append({"text": VegetationType.name_cn(int(hist[i])), "accent": UITokens.ECO})
	if badges.is_empty():
		badges.append({"text": "暂无记录", "accent": UITokens.TEXT_FAINT})
	return badges


func _densify_series(source: Array, target_count: int) -> Array:
	if source.size() <= 1 or target_count <= source.size():
		return source
	var result := []
	for i in range(target_count):
		var t := float(i) / float(target_count - 1)
		var pos := t * float(source.size() - 1)
		var left := int(floor(pos))
		var right := mini(left + 1, source.size() - 1)
		var a := float(source[left])
		var b := float(source[right])
		result.append(lerpf(a, b, pos - float(left)))
	return result


func _dir_degrees_text(v: Vector2) -> String:
	if v.length() < 0.0001:
		return "—"
	return "%.0f°" % fposmod(rad_to_deg(atan2(v.y, v.x)), 360.0)


func _vitality_band(v: float) -> String:
	if v < 0.15: return "濒死"
	if v < 0.40: return "枯萎"
	if v < 0.70: return "亚健康"
	if v < 0.90: return "健康"
	return "繁茂"


func _elevation_band(elev: float, sea: float) -> String:
	if elev < sea * 0.30: return "深海"
	if elev < sea * 0.85: return "近海"
	if elev < sea: return "浅海"
	var land := (elev - sea) / maxf(1.0 - sea, 0.001)
	if land < 0.05: return "海岸"
	if land < 0.30: return "低地"
	if land < 0.55: return "丘陵"
	if land < 0.80: return "山地"
	if land < 0.95: return "高峰"
	return "雪线以上"


func _temperature_band(t: float) -> String:
	if t < 0.06: return "极寒"
	if t < 0.20: return "严寒"
	if t < 0.30: return "寒冷"
	if t < 0.40: return "凉爽"
	if t < 0.55: return "温和"
	if t < 0.75: return "温暖"
	if t < 0.90: return "炎热"
	return "酷热"


func _moisture_band(m: float) -> String:
	if m < 0.20: return "极干"
	if m < 0.40: return "干燥"
	if m < 0.60: return "适中"
	if m < 0.80: return "湿润"
	return "极湿"
