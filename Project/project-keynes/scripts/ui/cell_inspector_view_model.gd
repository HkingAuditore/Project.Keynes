extends RefCounted
class_name CellInspectorViewModel

const TEMPERATURE_HISTORY_CAPACITY := 32
const TEMPERATURE_HISTORY_CACHE_LIMIT := 64
const DETAIL_HISTORY_CAPACITY := 48
const DETAIL_HISTORY_LOOKBACK := 7

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
# 交易税与进出口关税按物资；自然资源没有适用税种）。
const OBJECT_TAX_KINDS := {
	"cohort": ["income"],
	"building": ["business"],
	"good": ["consumption", "import", "export"],
}
const TAX_KIND_IDS := {"income": 0, "consumption": 1, "business": 2,
	"import": 3, "export": 4}
const TAX_KIND_LABELS := {"income": "所得税", "consumption": "交易税",
	"business": "营业税", "import": "进口关税", "export": "出口关税"}
const TAX_DEFAULT_LABELS := {"income": "此地所得税", "consumption": "此地交易税",
	"business": "此地营业税", "import": "此地进口税", "export": "此地出口税"}
const TAX_KIND_ACCENTS := {"income": UITokens.ACCENT, "consumption": UITokens.GOOD,
	"business": UITokens.CLIMATE, "import": UITokens.WATER, "export": UITokens.WATER}
const TRADE_ORDER_PAGE_SIZE := 12
const TRADE_ORDER_PAGE_CACHE_LIMIT := 8
const TRADE_ORDER_MODEL_CACHE_LIMIT := 16
const TRADE_ORDER_NAME_CACHE_LIMIT := 256

var _map: MapData
var _generator
var _gdp_ledger: EconomyGdpLedger = null
var _view_adapter: DCViewAdapter
var _world_clock: WorldClock
var _sea_level: float = 0.42
var _hex_size: float = 22.0
var _resource_prev_reserves: Dictionary = {}
var _market_prev_stock: Dictionary = {}
## 经济线程日内忙时读数会返回 pending；页头沿用该格上次成功的摘要，
## 免得 KPI 在“有人定居 / 无人之地”两套布局间来回跳。
var _population_summary_cache: Dictionary = {}
var _category_cache_cell := -1
var _category_cache: Dictionary = {}
var _temperature_histories: Dictionary = {}
var _temperature_history_order: Array[int] = []
var _detail_history_cell := -1
var _detail_history_market_day := -1
var _detail_history_pop_day := -1
var _detail_history_building_day := -1
var _good_history: Dictionary = {}
var _cohort_history: Dictionary = {}
var _building_history: Dictionary = {}
var _need_display_names: Dictionary = {}
var _need_display_names_loaded := false
var _player_country_resolved := false
var _player_country_handle_cache := -1
## 悬停卡与侧栏共用「玩家已掌握科技」口径：按模拟日缓存一次，避免每格重查。
var _technology_day := -999
var _technology_ids_cache := PackedStringArray()
var _research_signal_catalog: Dictionary = {}
var _technology_catalog: Dictionary = {}
## 物资详情逐单商路：页缓存按 committed generation，行缓存再叠加 sample_day/视野 revision。
var _trade_order_generation := -1
var _trade_order_pages: Dictionary = {}
var _trade_order_models: Dictionary = {}
var _trade_order_names: Dictionary = {}
var _trade_order_good_indices: Dictionary = {}
var _trade_order_query_count := 0


func set_context(map: MapData, generator, view_adapter: DCViewAdapter, world_clock: WorldClock, sea_level: float, hex_size: float) -> void:
	_map = map
	_generator = generator
	_view_adapter = view_adapter
	_world_clock = world_clock
	_sea_level = sea_level
	_hex_size = hex_size
	_resource_prev_reserves.clear()
	_market_prev_stock.clear()
	_population_summary_cache.clear()
	_category_cache.clear()
	_category_cache_cell = -1
	_temperature_histories.clear()
	_temperature_history_order.clear()
	_detail_history_cell = -1
	_detail_history_market_day = -1
	_detail_history_pop_day = -1
	_detail_history_building_day = -1
	_good_history.clear()
	_cohort_history.clear()
	_building_history.clear()
	_player_country_resolved = false
	_player_country_handle_cache = -1
	_technology_day = -999
	_technology_ids_cache = PackedStringArray()
	_trade_order_generation = -1
	_trade_order_pages.clear()
	_trade_order_models.clear()
	_trade_order_names.clear()
	_trade_order_good_indices.clear()
	_trade_order_query_count = 0


## 年度产值账本由 GameUIManager 持有并推进；地块档案只读它的逐格累计值。
func set_gdp_ledger(ledger: EconomyGdpLedger) -> void:
	_gdp_ledger = ledger


## 本地年度产值快照。纯内存读取，不触发任何原生查询；未跟踪的格返回空字典，
## 调用方据此决定是否渲染这两格（他国 / 无主 / 无人聚落都不给）。
func _local_gdp(cell_idx: int) -> Dictionary:
	if _gdp_ledger == null or not _gdp_ledger.ready():
		return {}
	if not _gdp_ledger.tracks_cell(cell_idx):
		return {}
	var population := _gdp_ledger.cell_population(cell_idx)
	if population <= 0:
		return {}
	return {
		"ytd": _gdp_ledger.cell_ytd(cell_idx),
		"per_day": _gdp_ledger.cell_per_day(cell_idx),
		"population": population,
		"per_capita": _gdp_ledger.cell_per_capita(cell_idx),
		"national_per_capita": _gdp_ledger.national_per_capita(),
		"days_counted": _gdp_ledger.days_counted(),
		"days_per_year": _gdp_ledger.days_per_year(),
		"year_index": _gdp_ledger.year_index(),
	}


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
	var geography_category := _geography_information_category(cell, idx, terrain_v,
		landform_v, vegetation_v, cover_v, elev, temp, moist, base_moist,
		wf, snow, vitality, passable_land, is_water)
	if intel_visible:
		_append_resources_to_geography(geography_category, idx, is_water)
	return {
		"cell_index": idx,
		"header": _build_header(off, terrain_v, landform_v, country_summary,
			population_summary, intel_visible, _has_river(cell, idx)),
		"kpis": _kpis(intel_visible, temp, moist, habitability, is_water,
			population_summary, country_summary, idx),
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
			"kicker": "地块档案 · 区域 %d, %d" % [off.x + 1, off.y + 1],
			"title": "未探索区域",
			"subtitle": "尚未进入视野，地理、人口与市场皆不可知",
		},
		"kpis": [],
		"tabs": [],
		"categories": {},
	}


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
		int(population_summary.get("job_capacity", 0)),
		int(population_summary.get("jobs_filled", 0)),
		int(population_summary.get("carrying_k_eff", 0)),
		int(population_summary.get("food_access_q16", 0)),
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
			category = _population_category(population_summary, market, idx)
			category = _decorate_category_with_tax(idx, tab_id, category)
			if bool(category.get("data_pending", false)):
				population_summary = _population_summary(idx)
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
			population_summary, intel_visible, _has_river(cell, idx)),
		"kpis": _kpis(intel_visible, temp, moist, habitability, is_water,
			population_summary, country_summary, idx),
		"tab_id": tab_id,
	}
	if include_category:
		patch["category"] = category
	return patch


func build_tab_category(cell: HexCell, tab_id: String) -> Dictionary:
	if cell == null or _map == null:
		return {}
	var idx := int(cell.index)
	if VisionSolver.fog_state(_map, idx) != VisionSolver.FOG_VISIBLE and tab_id != "geography":
		_category_cache.clear()
		return {}
	if idx != _category_cache_cell:
		_category_cache_cell = idx
		_category_cache.clear()
	var category := _build_tab_category(cell, tab_id)
	if bool(category.get("data_pending", false)):
		var cached: Dictionary = _category_cache.get(tab_id, {})
		if not cached.is_empty():
			category = cached.duplicate(true)
			category["data_pending"] = true
	elif not category.is_empty():
		_category_cache[tab_id] = category.duplicate(true)
	return category


func _build_tab_category(cell: HexCell, tab_id: String) -> Dictionary:
	if cell == null or _map == null:
		return {}
	var idx := int(cell.index)
	# 兜底：页签栏本来就不会给出被门控掉的页签，但延迟请求可能跨越一次视野变化。
	if VisionSolver.fog_state(_map, idx) != VisionSolver.FOG_VISIBLE and tab_id != "geography":
		return {}
	match tab_id:
		"population":
			return _decorate_category_with_tax(idx, tab_id,
				_population_category(_population_snapshot(idx), _market_snapshot(idx), idx))
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
		if bool(category.get("data_pending", false)):
			return {"data_pending": true}
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
	var payload := {
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
	if kind == "good":
		# 逐单商路页：只在物资详情打开时按需构建；ViewModel 按 generation 缓存，
		# 日 tick 与 200ms live patch 只会命中模型缓存。
		payload["trade_orders"] = trade_orders_model(
			idx,
			String(row.get("good_id", "")),
			int(request.get("orders_offset", 0)),
			TRADE_ORDER_PAGE_SIZE,
			int(category.get("economy_generation", -1)),
			int(category.get("sample_day", _current_sample_day())))
	return payload


## 家族专用档案册契约。保留 build_object_detail() 作为现有 facade、迷雾门控
## 与低频查询的唯一入口，再把兼容行数据整理成专用组件无需二次解析的结构。
func build_family_detail(cell: HexCell, request: Dictionary) -> Dictionary:
	if String(request.get("kind", "")) != "family":
		return {}
	var detail := build_object_detail(cell, request)
	if bool(detail.get("data_pending", false)):
		return detail
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
	var default_prestige_level := int(row.get("prestige_level", 0))
	for effect_idx in range(effects.size()):
		var eff: Dictionary = effects[effect_idx]
		if not eff.has("prestige_level"):
			eff["prestige_level"] = default_prestige_level
		if not eff.has("tier_statements") or (eff.get("tier_statements", []) as Array).is_empty():
			var raw_text := String(eff.get("detail", eff.get("value", "")))
			var parsed_tiers := FamilyBuffCopy.prestige_statements(raw_text)
			var tier_list: Array = []
			for st in parsed_tiers:
				tier_list.append(String(st))
			eff["tier_statements"] = tier_list
		effects[effect_idx] = eff
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
	var notable_count := maxi(int(row.get("notable_people", 0)), people.size())
	var branch_count := maxi(1, branches.size())
	var cash_text := String(row.get("cash_claim", ""))
	var asset_text := String(row.get("productive_asset_value", ""))
	var wealth_caption := "现金 %s · 产业 %s" % [cash_text, asset_text] \
		if not cash_text.is_empty() and not asset_text.is_empty() \
		else ("现金 %s" % cash_text if not cash_text.is_empty() else "家族名下净值")
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
			"origin_settlement_name": String(row.get("origin_settlement_name", "")),
			"decline_reviews": int(row.get("decline_reviews", 0)),
		},
		"summary": [
			{"id": "population", "label": "本家族人口",
				"value": String(row.get("population", "0")),
				"caption": "分支 %d 处 · 名人 %d 人" % [branch_count, notable_count],
				"icon": "family.metric.population"},
			{"id": "net_worth", "label": "净资产",
				"value": String(row.get("net_worth", row.get("cash_claim", "0"))),
				"caption": wealth_caption,
				"icon": "family.metric.wealth"},
			{"id": "owned_buildings", "label": "产业数",
				"value": String(row.get("owned_buildings", "0")),
				"caption": "名下控股建筑规模",
				"icon": "family.metric.buildings"},
			{"id": "founded_day", "label": "创立时间",
				"value": "第%d日" % int(row.get("founded_day", 0)),
				"caption": "威望 %s · 得分 %s" % [_prestige_text(level), _q16_percent_text(prestige_q16)],
				"icon": "family.metric.time"},
		],
		"pages": {
			"overview": {
				"traits": overview_traits,
				"preferences": overview_preferences.slice(0, 4),
				"effects": effects.slice(0, 4),
				"people": people.slice(0, 5),
				"branches": branches.slice(0, 3),
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
		var detail_text := String(item.get("detail", ""))
		var detail_key := _family_text_key(detail_text)
		var effect_key := _family_text_key(item.get("effect_summary", ""))
		if not effect_key.is_empty() and effect_key == detail_key:
			item["effect_summary"] = ""
			effect_key = ""
		if not item.has("badges"):
			item["badges"] = FamilyBuffCopy.extract_trait_badges(detail_text)
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
		var factor_pct := float(item.get("factor_percent",
			_parse_leading_float(item.get("value", "100"), 100.0)))
		item["factor_percent"] = factor_pct
		if not item.has("factor_text"):
			item["factor_text"] = "%.1f%%" % factor_pct
		var axis := int(item.get("axis", 0))
		var stable_id := String(item.get("stable_id", ""))
		if stable_id.is_empty() and String(item.get("id", "")).contains(":"):
			stable_id = String(item.get("id", "")).get_slice(":", 1)
			item["stable_id"] = stable_id
		if not item.has("icon") or String(item.get("icon", "")).is_empty():
			item["icon"] = String(_family_behavior_icon(
				axis, stable_id, String(item.get("name", ""))))
		var signed_delta := factor_pct - 100.0
		item["signed_delta_percent"] = signed_delta
		item["delta_text"] = "%s%.0f%%" % [
			"+" if signed_delta >= 0.0 else "−", absf(signed_delta)]
		item["bar_ratio"] = clampf(factor_pct / 200.0, 0.0, 1.0)
		var axis_key := _family_text_key(item.get("axis", item.get("axis_name", "")))
		var key := "%s|%s" % [axis_key, _family_text_key(item.get("name", ""))]
		var deviation := absf(factor_pct - 100.0)
		item["deviation"] = deviation
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


const DOSSIER_INCOME_COLORS: Array[Color] = [
	UITokens.DOSSIER_VERDIGRIS,
	UITokens.DOSSIER_BRASS,
	UITokens.DOSSIER_SLATE,
	UITokens.DOSSIER_UMBER,
]
const DOSSIER_EXPENSE_COLORS: Array[Color] = [
	UITokens.DOSSIER_OXBLOOD,
	UITokens.DOSSIER_BRASS,
	UITokens.DOSSIER_UMBER,
	UITokens.DOSSIER_SLATE,
]


static func _parse_leading_float(text: Variant, fallback: float = 0.0) -> float:
	if text is float or text is int:
		return float(text)
	var raw := String(text).strip_edges().replace("−", "-").replace("+", "")
	if raw.is_empty() or raw == "—":
		return fallback
	var mult := 1.0
	if raw.find("亿") >= 0:
		mult = 100000000.0
	elif raw.find("万") >= 0:
		mult = 10000.0
	var num_str := ""
	var dot_seen := false
	for idx in range(raw.length()):
		var ch := raw[idx]
		if (ch >= "0" and ch <= "9") or (ch == "-" and num_str.is_empty()):
			num_str += ch
		elif ch == "." and not dot_seen:
			dot_seen = true
			num_str += ch
		elif not num_str.is_empty():
			break
	if num_str.is_empty() or num_str == "-" or num_str == ".":
		return fallback
	return float(num_str) * mult


static func _detail_row_value_map(detail_rows: Array) -> Dictionary:
	var out := {}
	for raw in detail_rows:
		if not (raw is Dictionary):
			continue
		var item: Dictionary = raw
		var id_key := String(item.get("id", ""))
		var name_key := String(item.get("name", ""))
		var val := String(item.get("value", ""))
		if not id_key.is_empty():
			out[id_key] = val
		if not name_key.is_empty():
			out[name_key] = val
	return out


## 物资详情卷宗视图模型：提炼 4 格 KPI、诊断批注、供需对冲条、价格锚点刻度条与贸易对冲条。
static func good_dossier_model(row: Dictionary) -> Dictionary:
	var detail_map := _detail_row_value_map(row.get("detail_rows", []))
	var stock_plain := String(row.get("stock_plain", row.get("stock", "0 单位")))
	var stock_units := float(row.get("stock_units_float", _parse_leading_float(stock_plain, 0.0)))
	var price_text := String(row.get("price", "—"))
	var price_val := float(row.get("price_float", _parse_leading_float(price_text, 0.0)))
	var anchor_text := String(row.get("cost_anchor_text", detail_map.get("cost_anchor", detail_map.get("成本锚", "—"))))
	var anchor_val := float(row.get("cost_anchor_float", _parse_leading_float(anchor_text, 0.0)))
	var has_anchor := anchor_val > 0.00001 and anchor_text != "—" and not anchor_text.is_empty()
	var price_index := float(row.get("price_index_float",
		(price_val / anchor_val) if has_anchor else 1.0))
	var hh_demand := float(row.get("household_demand_float",
		_parse_leading_float(detail_map.get("household_demand", detail_map.get("居民需求", "0")), 0.0)))
	var biz_demand := float(row.get("business_demand_float",
		_parse_leading_float(detail_map.get("business_demand", detail_map.get("产业需求", "0")), 0.0)))
	var total_demand := hh_demand + biz_demand
	var supply_units := float(row.get("supply_float",
		_parse_leading_float(detail_map.get("supply", detail_map.get("供给", "0")), 0.0)))
	var shortage_ratio := float(row.get("shortage_float",
		_parse_leading_float(detail_map.get("shortage", detail_map.get("短缺", "0")), 0.0) / 100.0))
	if shortage_ratio <= 0.0 and String(row.get("risk", "")) == "短缺":
		shortage_ratio = 0.25
	var days_of_stock := float(row.get("days_of_stock_float",
		stock_units / total_demand if total_demand > 0.001 else (999.0 if stock_units > 0.001 else 0.0)))
	var delta_text := String(row.get("delta", "—"))
	var inbound_text := String(row.get("trade_inbound", detail_map.get("trade_inbound", detail_map.get("运入", ""))))
	var outbound_text := String(row.get("trade_outbound", detail_map.get("trade_outbound", detail_map.get("运出", ""))))
	var inbound_units := float(row.get("inbound_float", _parse_leading_float(inbound_text, 0.0)))
	var outbound_units := float(row.get("outbound_float", _parse_leading_float(outbound_text, 0.0)))
	var import_flow_units := float(row.get("import_flow_float",
		_parse_leading_float(detail_map.get("trade_import_flow", detail_map.get("进口均量", "0")), 0.0)))
	var export_flow_units := float(row.get("export_flow_float",
		_parse_leading_float(detail_map.get("trade_export_flow", detail_map.get("出口均量", "0")), 0.0)))

	var price_tone := "risk" if price_index >= 1.35 else ("warn" if price_index >= 1.15 else "")
	var price_index_caption := "贴近成本锚"
	if has_anchor:
		if price_index > 1.05:
			price_index_caption = "高于成本锚 %.0f%%" % minf(999.0, (price_index - 1.0) * 100.0)
		elif price_index < 0.95:
			price_index_caption = "低于成本锚 %.0f%%" % ((1.0 - price_index) * 100.0)
	else:
		price_index_caption = "尚无本地成本锚"

	var stock_caption := "日变 %s" % delta_text if delta_text != "—" else "无日常消耗"
	if total_demand > 0.001:
		stock_caption = "库存充裕" if days_of_stock >= 180.0 else ("可支 %d 日" % int(days_of_stock))

	var balance_text := "静态库存"
	if shortage_ratio >= 0.02 or String(row.get("risk", "")) != "":
		balance_text = "短缺 %.0f%%" % (shortage_ratio * 100.0) if shortage_ratio >= 0.02 else String(row.get("risk", "短缺"))
	elif supply_units > total_demand * 1.15 and supply_units > 0.01:
		balance_text = "供过于求"
	elif total_demand > 0.001 or supply_units > 0.001:
		balance_text = "供需平衡"
	var net_supply := supply_units - total_demand
	var balance_caption := "日均供需持平"
	if net_supply < -0.01:
		balance_caption = "日缺口 %s" % UITokens.format_compact_number_cn(absf(net_supply), 2)
	elif net_supply > 0.01:
		balance_caption = "日盈余 +%s" % UITokens.format_compact_number_cn(net_supply, 2)
	elif delta_text != "—":
		balance_caption = "日变 %s" % delta_text

	var kpis := [
		{
			"id": "good_price",
			"title": "本地时价",
			"value": price_val,
			"kind": "text",
			"text": price_text,
			"caption": "锚价 %s" % anchor_text if has_anchor else "本地零售单价",
			"tone": price_tone,
			"positive_good": false,
			"spark": row.get("price_spark", PackedFloat32Array()),
			"delta": float(row.get("price_delta", NAN)),
			"icon": &"metric.goods",
		},
		{
			"id": "good_anchor_ratio",
			"title": "价格锚比",
			"value": price_index,
			"kind": "text",
			"text": "%.2f 倍" % price_index if has_anchor else "—",
			"caption": price_index_caption,
			"tone": price_tone,
			"positive_good": false,
			"icon": &"trend.up" if price_index > 1.05 else (&"trend.down" if price_index < 0.95 else &"trend.flat"),
		},
		{
			"id": "good_stock",
			"title": "本地库存",
			"value": stock_units,
			"kind": "text",
			"text": UITokens.format_compact_number_cn(stock_units, 1),
			"caption": stock_caption,
			"tone": "risk" if (total_demand > 0.01 and days_of_stock < 3.0) else "",
			"positive_good": true,
			"spark": row.get("stock_spark", PackedFloat32Array()),
			"delta": float(row.get("stock_delta", NAN)),
			"icon": &"economy.resource",
			"tooltip": "本地库存：%s\n%s" % [stock_plain, stock_caption],
		},
		{
			"id": "good_balance",
			"title": "供需状态",
			"value": shortage_ratio,
			"kind": "text",
			"text": balance_text,
			"caption": balance_caption,
			"tone": "risk" if shortage_ratio >= 0.25 else ("warn" if shortage_ratio >= 0.05 or net_supply < -0.05 else ""),
			"positive_good": false,
			"icon": &"status.warning" if shortage_ratio >= 0.25 else &"summary.overview",
		},
	]

	# 物资卷宗不再附修饰性批注；短缺/盈余由 KPI 与条形图直接表达。
	var insights := []

	var flow_peak := maxf(maxf(total_demand, supply_units), 0.001)
	var demand_supply_bars := [
		{
			"id": "hh_demand",
			"label": "居民需求",
			"icon": &"population.heart",
			"value": clampf(hh_demand / flow_peak, 0.0, 1.0) if (total_demand > 0.0 or supply_units > 0.0) else 0.0,
			"text": "%s/日" % UITokens.format_compact_number_cn(hh_demand, 2),
			"color": UITokens.DOSSIER_OXBLOOD,
			"tooltip": "本地各阶层居民日常消费需求：%s 单位/日" % UITokens.format_compact_number_cn(hh_demand, 2),
		},
		{
			"id": "biz_demand",
			"label": "产业需求",
			"icon": &"economy.building.factory",
			"value": clampf(biz_demand / flow_peak, 0.0, 1.0) if (total_demand > 0.0 or supply_units > 0.0) else 0.0,
			"text": "%s/日" % UITokens.format_compact_number_cn(biz_demand, 2),
			"color": UITokens.DOSSIER_BRASS,
			"tooltip": "本地生产建筑与在建工程的原料需求：%s 单位/日" % UITokens.format_compact_number_cn(biz_demand, 2),
		},
		{
			"id": "local_supply",
			"label": "本地供给",
			"icon": &"economy.building.farm",
			"value": clampf(supply_units / flow_peak, 0.0, 1.0) if (total_demand > 0.0 or supply_units > 0.0) else 0.0,
			"text": "%s/日" % UITokens.format_compact_number_cn(supply_units, 2),
			"color": UITokens.DOSSIER_VERDIGRIS,
			"tooltip": "本地建筑向市场提供的日常供给：%s 单位/日" % UITokens.format_compact_number_cn(supply_units, 2),
		},
	]

	var price_stock_bars := [
		{
			"id": "price_anchor_bar",
			"label": "价格指数",
			"icon": &"metric.goods",
			"value": clampf(price_index / 2.0, 0.0, 1.0) if has_anchor else 0.5,
			"marker": 0.5,
			"text": ("%.2f 倍" % price_index) if has_anchor else price_text,
			"color": UITokens.DOSSIER_OXBLOOD if price_index > 1.05 else (UITokens.DOSSIER_VERDIGRIS if price_index < 0.95 else UITokens.DOSSIER_BRASS),
			"tooltip": "竖线刻度为成本锚基准（1.00 倍 = %s），当前时价 %s" % [anchor_text, price_text],
		},
		{
			"id": "shortage_bar",
			"label": "短缺率",
			"icon": &"status.warning",
			"value": clampf(shortage_ratio, 0.0, 1.0),
			"text": "%.1f%%" % (shortage_ratio * 100.0),
			"color": UITokens.DOSSIER_OXBLOOD if shortage_ratio >= 0.25 else (UITokens.DOSSIER_BRASS if shortage_ratio >= 0.05 else UITokens.DOSSIER_VERDIGRIS),
			"tooltip": "买方未能买到所需物资的比例：%.1f%%" % (shortage_ratio * 100.0),
		},
		{
			"id": "stock_days_bar",
			"label": "库存保障",
			"icon": &"economy.resource",
			"value": clampf(days_of_stock / 60.0, 0.0, 1.0) if stock_units > 0.0 else 0.0,
			"text": "充裕" if (days_of_stock >= 180.0 and stock_units > 0.0) else ("%d 日" % int(days_of_stock) if total_demand > 0.001 else stock_plain),
			"color": UITokens.DOSSIER_VERDIGRIS if days_of_stock >= 15.0 else (UITokens.DOSSIER_BRASS if days_of_stock >= 5.0 else UITokens.DOSSIER_OXBLOOD),
			"tooltip": "按当前日需求估算，现有库存（%s）可支撑的天数" % stock_plain,
		},
	]

	var trade_peak := maxf(maxf(inbound_units, outbound_units), maxf(maxf(import_flow_units, export_flow_units), 0.001))
	var has_any_trade := inbound_units > 0.0 or outbound_units > 0.0 or import_flow_units > 0.0 or export_flow_units > 0.0
	var trade_bars := [
		{
			"id": "trade_import_flow",
			"label": "日均进口",
			"icon": &"trend.up",
			"value": clampf(import_flow_units / trade_peak, 0.0, 1.0) if has_any_trade else 0.0,
			"text": "%s/日" % UITokens.format_compact_number_cn(import_flow_units, 2),
			"color": UITokens.DOSSIER_VERDIGRIS,
			"tooltip": "外地向本地市场输入的日均流量",
		},
		{
			"id": "trade_export_flow",
			"label": "日均出口",
			"icon": &"trend.down",
			"value": clampf(export_flow_units / trade_peak, 0.0, 1.0) if has_any_trade else 0.0,
			"text": "%s/日" % UITokens.format_compact_number_cn(export_flow_units, 2),
			"color": UITokens.DOSSIER_OXBLOOD,
			"tooltip": "本地市场向外地输出的日均流量",
		},
		{
			"id": "trade_inbound",
			"label": "在途运入",
			"icon": &"tax.tariff",
			"value": clampf(inbound_units / trade_peak, 0.0, 1.0) if has_any_trade else 0.0,
			"text": "%s 单位" % UITokens.format_compact_number_cn(inbound_units, 2),
			"color": UITokens.DOSSIER_SLATE,
			"tooltip": "商队正在运往本地的在途货物总量",
		},
		{
			"id": "trade_outbound",
			"label": "在途运出",
			"icon": &"tax.tariff",
			"value": clampf(outbound_units / trade_peak, 0.0, 1.0) if has_any_trade else 0.0,
			"text": "%s 单位" % UITokens.format_compact_number_cn(outbound_units, 2),
			"color": UITokens.DOSSIER_BRASS,
			"tooltip": "商队正从本地运往外地的在途货物总量",
		},
	]

	return {
		"kpis": kpis,
		"insights": insights,
		"supply_demand_bar": {
			"left_label": "本地需求",
			"left_value": total_demand,
			"left_text": "%s/日" % UITokens.format_compact_number_cn(total_demand, 2),
			"right_label": "本地供给",
			"right_value": supply_units,
			"right_text": "%s/日" % UITokens.format_compact_number_cn(supply_units, 2),
		},
		"demand_supply_bars": demand_supply_bars,
		"price_stock_bars": price_stock_bars,
		"trade_flow_bar": {
			"left_label": "外销流出",
			"left_value": export_flow_units + outbound_units,
			"left_text": "%s/日" % UITokens.format_compact_number_cn(export_flow_units, 2),
			"right_label": "采购流入",
			"right_value": import_flow_units + inbound_units,
			"right_text": "%s/日" % UITokens.format_compact_number_cn(import_flow_units, 2),
		},
		"trade_bars": trade_bars,
	}


## 阶层详情卷宗视图模型：提炼 4 格 KPI、7 档生活水平刻度、8 维满意度雷达/短板条、
## 收支对冲与堆叠条、按用途分组的消费结构条，以及零消费替代品折叠摘要。
static func cohort_dossier_model(row: Dictionary) -> Dictionary:
	var pop_text := String(row.get("population", "—"))
	var pop_raw := int(row.get("population_raw", int(_parse_leading_float(pop_text, 0.0))))
	var employed_raw := int(row.get("employed_raw", -1))
	var identity_text := String(row.get("cohort_identity", "本地人口"))
	if identity_text.is_empty():
		identity_text = "本地常住"
	var wealth_text := String(row.get("wealth", "—")).trim_prefix("人均 ").strip_edges()
	var living_name := String(row.get("living_standard", "待评估"))
	var living_level := int(row.get("living_level", -1))
	if living_level < 0:
		living_level = ["赤贫", "挣扎", "贫困", "温饱", "小康", "富裕", "奢华"].find(living_name)
	var sat_text := String(row.get("satisfaction", "—"))
	var sat_float := float(row.get("satisfaction_float", _parse_leading_float(sat_text, 0.0) / 100.0))
	var worst_dim_name := String(row.get("worst_dimension", "—"))
	var income_text := String(row.get("income", "—"))
	var expense_text := String(row.get("expense", "—"))
	var net_text := String(row.get("net", "—"))
	var income_float := float(row.get("income_pc_float", absf(_parse_leading_float(income_text, 0.0))))
	var expense_float := float(row.get("expense_pc_float", absf(_parse_leading_float(expense_text, 0.0))))
	var net_float := float(row.get("net_pc_float", _parse_leading_float(net_text, income_float - expense_float)))
	var net_positive := bool(row.get("net_positive", net_float >= -1e-6))

	var pop_caption := identity_text
	if employed_raw >= 0:
		pop_caption = "就业 %s 人 · %s" % [
			UITokens.format_compact_number_cn(float(employed_raw), 1), identity_text]

	var kpis := [
		{
			"id": "cohort_population",
			"title": "阶层人口",
			"value": float(pop_raw),
			"kind": "text",
			"text": pop_text,
			"caption": pop_caption,
			"positive_good": true,
			"icon": StringName(row.get("icon", "population.profession.worker")),
		},
		{
			"id": "cohort_living",
			"title": "生活水平",
			"value": float(maxi(0, living_level)),
			"kind": "text",
			"text": living_name,
			"caption": "人均存款 %s" % wealth_text,
			"tone": "risk" if (living_level >= 0 and living_level <= 1) else ("warn" if living_level == 2 else ""),
			"positive_good": true,
			"icon": &"family.metric.wealth",
		},
		{
			"id": "cohort_satisfaction",
			"title": "综合满意度",
			"value": sat_float,
			"kind": "text",
			"text": sat_text,
			"caption": ("短板：%s" % worst_dim_name) if (not worst_dim_name.is_empty() and worst_dim_name != "—") else "各维均衡",
			"tone": "risk" if sat_float < 0.40 else ("warn" if sat_float < 0.65 else ""),
			"positive_good": true,
			"spark": row.get("satisfaction_spark", PackedFloat32Array()),
			"delta": float(row.get("satisfaction_delta", NAN)),
			"icon": &"population.heart",
		},
		{
			"id": "cohort_net",
			"title": "人均日净收",
			"value": net_float,
			"kind": "text",
			"text": net_text,
			"caption": "收 %s · 支 %s" % [income_text, expense_text],
			"tone": "" if net_positive else "risk",
			"positive_good": true,
			"spark": row.get("net_spark", PackedFloat32Array()),
			"delta": float(row.get("net_delta", NAN)),
			"icon": &"trend.up" if net_positive else &"trend.down",
		},
	]

	var sat_rows: Array = row.get("satisfaction_rows", [])
	var dims_float: PackedFloat32Array = row.get("satisfaction_dims_float", PackedFloat32Array())
	var ref_dims_float: PackedFloat32Array = row.get("cell_reference_dims_float", PackedFloat32Array())
	var radar_axes := PackedStringArray(SATISFACTION_DIMENSION_NAMES)
	var radar_values := dims_float.duplicate()
	if radar_values.size() != SATISFACTION_DIMENSION_NAMES.size():
		radar_values.resize(SATISFACTION_DIMENSION_NAMES.size())
		for d in range(SATISFACTION_DIMENSION_NAMES.size()):
			radar_values[d] = sat_float
		for raw_s in sat_rows:
			if not (raw_s is Dictionary):
				continue
			var sdict: Dictionary = raw_s
			var sname := String(sdict.get("name", ""))
			var sidx := SATISFACTION_DIMENSION_NAMES.find(sname)
			if sidx >= 0:
				radar_values[sidx] = clampf(_parse_leading_float(sdict.get("value", "0"), 0.0) / 100.0, 0.0, 1.0)

	var dimension_bars := []
	if not sat_rows.is_empty():
		for idx in range(sat_rows.size()):
			var sdict: Dictionary = sat_rows[idx]
			if not bool(sdict.get("visible", true)):
				continue
			var sname := String(sdict.get("name", ""))
			var sval_text := String(sdict.get("value", "0%"))
			var sval := clampf(_parse_leading_float(sval_text, 0.0) / 100.0, 0.0, 1.0)
			var is_worst := bool(sdict.get("worst", sname == worst_dim_name))
			var marker := ref_dims_float[idx] if idx < ref_dims_float.size() and bool(sdict.get("applicable", true)) else -1.0
			var color := UITokens.DOSSIER_OXBLOOD if (is_worst or sval < 0.45) \
				else (UITokens.DOSSIER_BRASS if sval < 0.72 else UITokens.DOSSIER_VERDIGRIS)
			dimension_bars.append({
				"id": String(sdict.get("id", "dim_%d" % idx)),
				"label": sname,
				"value": sval,
				"marker": marker,
				"text": sval_text,
				"color": color if bool(sdict.get("applicable", true)) else UITokens.DOSSIER_RULE,
				"text_color": UITokens.DOSSIER_INK_MUTED if not bool(sdict.get("applicable", true)) else (UITokens.DOSSIER_OXBLOOD if is_worst else UITokens.DOSSIER_INK),
				"tooltip": String(sdict.get("tooltip", "")) + "\n" + "%s满意度 %s%s%s" % [
					sname, sval_text,
					"（当前最短板）" if is_worst else "",
					("（本地均值 %.0f%%）" % (marker * 100.0)) if marker >= 0.0 else ""],
			})

	# 阶层卷宗不再附修饰性批注；短板与收支由条形图/KPI 表达。
	var insights := []

	var income_segments := []
	var income_rows: Array = row.get("income_rows", [])
	for idx in range(income_rows.size()):
		var ir: Dictionary = income_rows[idx]
		if not bool(ir.get("visible", true)):
			continue
		var vtext := String(ir.get("value", ""))
		var vnum := maxf(0.0001, float(ir.get("raw_per_capita", absf(_parse_leading_float(vtext, 0.0)))))
		income_segments.append({
			"label": String(ir.get("name", "收入")),
			"value": vnum,
			"text": vtext,
			"color": DOSSIER_INCOME_COLORS[idx % DOSSIER_INCOME_COLORS.size()],
		})

	var expense_segments := []
	var expense_rows: Array = row.get("expense_rows", [])
	for idx in range(expense_rows.size()):
		var er: Dictionary = expense_rows[idx]
		if not bool(er.get("visible", true)):
			continue
		var vtext := String(er.get("value", ""))
		var vnum := maxf(0.0001, float(er.get("raw_per_capita", absf(_parse_leading_float(vtext, 0.0)))))
		expense_segments.append({
			"label": String(er.get("name", "支出")),
			"value": vnum,
			"text": vtext,
			"color": DOSSIER_EXPENSE_COLORS[idx % DOSSIER_EXPENSE_COLORS.size()],
		})

	var demand_groups: Array = row.get("demand_groups", [])
	var demand_tier_bars := []
	for idx in range(demand_groups.size()):
		var grp: Dictionary = demand_groups[idx]
		var gname := String(grp.get("name", "消费"))
		var sat_str := String(grp.get("satisfaction", ""))
		var sat_ratio := float(grp.get("satisfaction_ratio",
			_parse_leading_float(sat_str, 100.0) / 100.0 if not sat_str.is_empty() else 1.0))
		var clamped_sat := clampf(sat_ratio, 0.0, 1.0)
		var grp_cost_raw := int(grp.get("daily_cost_raw", 0))
		var right_text := sat_str.trim_prefix("满足 ") if not sat_str.is_empty() else "%.0f%%" % (clamped_sat * 100.0)
		if grp_cost_raw > 0:
			right_text = "%s · 支 %s" % [
				right_text,
				UITokens.format_compact_number_cn(float(grp_cost_raw) / 10000.0, 2)]
		demand_tier_bars.append({
			"id": String(grp.get("id", "tier_%d" % idx)),
			"label": gname,
			"icon": &"population.heart",
			"value": clamped_sat,
			"text": right_text,
			"color": UITokens.DOSSIER_OXBLOOD if clamped_sat < 0.45 else (UITokens.DOSSIER_BRASS if clamped_sat < 0.75 else UITokens.DOSSIER_VERDIGRIS),
			"tooltip": "用途【%s】%s" % [gname, sat_str if not sat_str.is_empty() else right_text],
		})

	var demand_rows: Array = row.get("demand_rows", [])
	var active_candidates := []
	var inactive_names := PackedStringArray()
	var peak_metric := 0.0001
	for raw_d in demand_rows:
		if not (raw_d is Dictionary):
			continue
		var drow: Dictionary = raw_d
		if not bool(drow.get("visible", true)):
			continue
		var dname := String(drow.get("name", ""))
		var qty_float := float(drow.get("quantity_raw", -1)) / 1000.0 \
			if drow.has("quantity_raw") \
			else _parse_leading_float(drow.get("quantity", drow.get("value", "0")), 0.0)
		var cost_float := float(drow.get("daily_cost_raw", -1)) / 10000.0 \
			if int(drow.get("daily_cost_raw", -1)) >= 0 \
			else _parse_leading_float(drow.get("daily_cost", "0"), 0.0)
		if qty_float <= 0.00001:
			if not dname.is_empty():
				inactive_names.append(dname)
			continue
		var metric := cost_float if cost_float > 0.00001 else qty_float
		peak_metric = maxf(peak_metric, metric)
		active_candidates.append({
			"row": drow,
			"qty": qty_float,
			"cost": cost_float,
			"metric": metric,
		})
	active_candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.metric) > float(b.metric))

	var active_demand_bars := []
	for item in active_candidates:
		var drow: Dictionary = item.row
		var dname := String(drow.get("name", ""))
		var qty_text := String(drow.get("quantity", ""))
		if qty_text.is_empty():
			qty_text = String(drow.get("value", "")).replace(" 单位/人/日", "")
		var cost_text := String(drow.get("daily_cost", ""))
		var right_text := "%s/日" % qty_text
		if not cost_text.is_empty() and cost_text != "—":
			right_text = "支 %s · %s" % [cost_text, qty_text]
		var wealth_delta := int(drow.get("wealth_delta_raw", 0))
		var price_delta := int(drow.get("price_delta_raw", 0))
		var drivers := PackedStringArray()
		if wealth_delta > 0:
			drivers.append("财富拉动 +%s" % UITokens.format_compact_number_cn(float(wealth_delta) / 1000.0, 3))
		elif wealth_delta < 0:
			drivers.append("贫困抑制 %s" % UITokens.format_compact_number_cn(float(wealth_delta) / 1000.0, 3))
		if price_delta < 0:
			drivers.append("高价抑制 %s" % UITokens.format_compact_number_cn(float(price_delta) / 1000.0, 3))
		elif price_delta > 0:
			drivers.append("低价促进 +%s" % UITokens.format_compact_number_cn(float(price_delta) / 1000.0, 3))
		var need_names: Array = drow.get("need_names", [])
		var tip_lines := PackedStringArray([
			"%s：%s 单位/人/日" % [dname, qty_text],
		])
		if not cost_text.is_empty() and cost_text != "—":
			tip_lines.append("单价 %s · 日均开销 %s/人" % [String(drow.get("price", "—")), cost_text])
		if not need_names.is_empty():
			tip_lines.append("满足用途：%s" % "、".join(need_names))
		if not drivers.is_empty():
			tip_lines.append("弹性归因：%s" % "，".join(drivers))
		var bar_color := UITokens.DOSSIER_BRASS
		if price_delta < -10:
			bar_color = UITokens.DOSSIER_OXBLOOD
		elif wealth_delta > 10:
			bar_color = UITokens.DOSSIER_VERDIGRIS
		active_demand_bars.append({
			"id": String(drow.get("id", "demand_" + dname)),
			"label": dname,
			"icon": StringName(drow.get("icon", &"metric.goods")),
			"value": clampf(float(item.metric) / peak_metric, 0.0, 1.0),
			"text": right_text,
			"color": bar_color,
			"tooltip": "\n".join(tip_lines),
		})

	var inactive_summary := ""
	if not inactive_names.is_empty():
		var preview := PackedStringArray()
		for idx in range(mini(4, inactive_names.size())):
			preview.append(inactive_names[idx])
		inactive_summary = "未采购替代品：另有 %s%s（共 %d 种）已解锁商品因本地无货或性价比偏低暂未消费。" % [
			"、".join(preview),
			" 等" if inactive_names.size() > preview.size() else "",
			inactive_names.size(),
		]

	return {
		"kpis": kpis,
		"insights": insights,
		"living_level": living_level,
		"living_name": living_name,
		"wealth_text": wealth_text,
		"radar_axes": radar_axes,
		"radar_values": radar_values,
		"radar_reference": ref_dims_float,
		"dimension_bars": dimension_bars,
		"cashflow_bar": {
			"left_label": "人均日支",
			"left_value": expense_float,
			"left_text": expense_text,
			"right_label": "人均日收",
			"right_value": income_float,
			"right_text": income_text,
		},
		"income_segments": income_segments,
		"expense_segments": expense_segments,
		"demand_tier_bars": demand_tier_bars,
		"active_demand_bars": active_demand_bars,
		"inactive_alternatives_summary": inactive_summary,
	}


## 建筑详情卷宗视图模型：提炼 4 格 KPI、经营诊断批注、产能与气候适宜横条、
## 岗位配置横条、投入产出结构横条（折叠未使用的可选替代原料），以及营收与成本堆叠对冲。
static func building_dossier_model(row: Dictionary) -> Dictionary:
	var count_text := String(row.get("count", "1 栋"))
	var count_raw := maxi(1, int(row.get("count_raw", int(_parse_leading_float(count_text, 1.0)))))
	var owner_raw := String(row.get("owner", "业主 · 本地产业"))
	var owner_short := owner_raw.trim_prefix("业主 · ").strip_edges()
	var status_text := String(row.get("status", "正常运转"))
	var profit_label := String(row.get("profit_label", "利润"))
	var profit_text := String(row.get("profit", "—"))
	var profit_val := float(row.get("profit_float", _parse_leading_float(profit_text, 0.0)))

	var job_rows: Array = row.get("job_rows", [])
	var staff_actual := int(row.get("staffing_actual_raw", -1))
	var staff_req := int(row.get("staffing_required_raw", -1))
	if staff_actual < 0 or staff_req < 0:
		staff_actual = 0
		staff_req = 0
		for raw_j in job_rows:
			if not (raw_j is Dictionary):
				continue
			var jval := String((raw_j as Dictionary).get("value", ""))
			var slash := jval.find("/")
			if slash >= 0:
				staff_actual += int(_parse_leading_float(jval.substr(0, slash), 0.0))
				staff_req += int(_parse_leading_float(jval.substr(slash + 1), 0.0))
	var staff_ratio := float(staff_actual) / float(staff_req) if staff_req > 0 else 1.0
	var staff_text := "%d / %d" % [staff_actual, staff_req] if staff_req > 0 else "—"

	var actual_util := float(row.get("actual_utilization_float", -1.0))
	var planned_util := float(row.get("planned_utilization_float", 1.0))
	if actual_util < 0.0:
		var cap_pos := status_text.find("产能")
		if cap_pos >= 0:
			actual_util = clampf(_parse_leading_float(status_text.substr(cap_pos + 2), 100.0) / 100.0, 0.0, 1.0)
		elif status_text.find("停") >= 0 or profit_text.find("停") >= 0:
			actual_util = 0.0
		else:
			actual_util = 1.0

	var state_summary: Dictionary = row.get("state_summary", {})
	var is_halted := not state_summary.is_empty() or status_text.find("停") >= 0
	var util_text := String(state_summary.get("label", "停产")) if is_halted \
		else ("%.0f%%" % (actual_util * 100.0))
	var util_caption := "正常运转"
	if is_halted:
		util_caption = String(state_summary.get("detail", "本期暂停生产"))
	elif planned_util < 0.995:
		util_caption = "计划限产 %.0f%%" % (planned_util * 100.0)
	elif actual_util < 0.995:
		util_caption = "受人力或环境制约"
	else:
		util_caption = "满负荷运转"

	var finance: Dictionary = row.get("finance", {})
	var rev_text := String(finance.get("revenue", "—"))
	var cost_text := String(finance.get("cost", "—"))
	var profit_positive := bool(finance.get("profit_positive", not profit_text.begins_with("-") and not profit_text.begins_with("−") and not is_halted))
	var profit_caption := status_text
	if not finance.is_empty():
		profit_caption = "收 %s · 支 %s" % [rev_text, cost_text]

	var kpis := [
		{
			"id": "building_scale",
			"title": "建筑规模",
			"value": float(count_raw),
			"kind": "text",
			"text": count_text,
			"caption": "业主：%s" % owner_short if not owner_short.is_empty() else status_text,
			"positive_good": true,
			"icon": StringName(row.get("icon", &"economy.building")),
		},
		{
			"id": "building_utilization",
			"title": "产能出力",
			"value": actual_util,
			"kind": "text",
			"text": util_text,
			"caption": util_caption,
			"tone": "risk" if (is_halted or actual_util < 0.25) else ("warn" if actual_util < 0.75 else ""),
			"positive_good": true,
			"spark": row.get("utilization_spark", PackedFloat32Array()),
			"delta": float(row.get("utilization_delta", NAN)),
			"icon": &"economy.building.factory",
		},
		{
			"id": "building_staffing",
			"title": "岗位到岗",
			"value": staff_ratio,
			"kind": "text",
			"text": staff_text,
			"caption": ("到岗 %.0f%%" % (staff_ratio * 100.0)) if staff_req > 0 else "无需专职岗位",
			"tone": "risk" if (staff_req > 0 and staff_ratio < 0.5) else ("warn" if (staff_req > 0 and staff_ratio < 0.99) else ""),
			"positive_good": true,
			"icon": &"population.profession.worker",
		},
		{
			"id": "building_profit",
			"title": "本期%s" % profit_label if profit_label in ["利润", "亏损"] else profit_label,
			"value": profit_val,
			"kind": "text",
			"text": profit_text,
			"caption": profit_caption,
			"tone": "risk" if (is_halted or not profit_positive) else "",
			"positive_good": true,
			"spark": row.get("profit_spark", PackedFloat32Array()),
			"delta": float(row.get("profit_delta", NAN)),
			"icon": &"trend.up" if (profit_positive and not is_halted) else &"trend.down",
		},
	]

	# 仅保留真实经营异常；气候减产与「正常运转」叙述性批注去掉。
	var insights := []
	if not state_summary.is_empty():
		var slabel := String(state_summary.get("label", "经营异常"))
		var sdetail := String(state_summary.get("detail", ""))
		var smeta := String(state_summary.get("meta", ""))
		var line := "%s：%s" % [slabel, sdetail] if not sdetail.is_empty() else slabel
		if not smeta.is_empty():
			line += "（%s）" % smeta
		insights.append({
			"id": "building_state_alert",
			"text": line,
			"accent": UITokens.DOSSIER_OXBLOOD,
			"icon": "status.warning",
		})

	var capacity_bars := [
		{
			"id": "cap_actual",
			"label": "实际产能",
			"icon": &"economy.building.factory",
			"value": clampf(actual_util, 0.0, 1.0),
			"marker": clampf(planned_util, 0.0, 1.0) if planned_util < 0.995 else -1.0,
			"text": "%.0f%%" % (actual_util * 100.0),
			"color": UITokens.DOSSIER_OXBLOOD if actual_util < 0.25 else (UITokens.DOSSIER_BRASS if actual_util < 0.75 else UITokens.DOSSIER_VERDIGRIS),
			"tooltip": "实际产能利用率 %.1f%%（计划上限 %.1f%%）" % [actual_util * 100.0, planned_util * 100.0],
		},
	]
	if bool(row.get("has_climate_profile", false)):
		var climate_cap := clampf(float(row.get("climate_capacity_float", 1.0)), 0.0, 1.0)
		var temp_fit := clampf(float(row.get("temperature_fit_float", 1.0)), 0.0, 1.0)
		var water_fit := clampf(float(row.get("water_fit_float", 1.0)), 0.0, 1.0)
		capacity_bars.append({
			"id": "cap_climate",
			"label": "气候出力",
			"icon": &"climate",
			"value": climate_cap,
			"text": "%.0f%%" % (climate_cap * 100.0),
			"color": UITokens.DOSSIER_VERDIGRIS if climate_cap >= 0.90 else (UITokens.DOSSIER_BRASS if climate_cap >= 0.60 else UITokens.DOSSIER_OXBLOOD),
			"tooltip": "温度适宜度 %.1f%% · 水分适宜度 %.1f%% · 综合气候出力 %.1f%%" % [
				temp_fit * 100.0, water_fit * 100.0, climate_cap * 100.0],
		})
		if temp_fit < 0.995 or water_fit < 0.995:
			capacity_bars.append({
				"id": "cap_temp",
				"label": "温度适宜",
				"value": temp_fit,
				"text": "%.0f%%" % (temp_fit * 100.0),
				"color": UITokens.DOSSIER_VERDIGRIS if temp_fit >= 0.85 else UITokens.DOSSIER_BRASS,
			})
			capacity_bars.append({
				"id": "cap_water",
				"label": "水分适宜",
				"value": water_fit,
				"text": "%.0f%%" % (water_fit * 100.0),
				"color": UITokens.DOSSIER_SLATE if water_fit >= 0.85 else UITokens.DOSSIER_BRASS,
			})

	var job_bars := []
	for idx in range(job_rows.size()):
		var raw_j = job_rows[idx]
		if not (raw_j is Dictionary):
			continue
		var jdict: Dictionary = raw_j
		if not bool(jdict.get("visible", true)):
			continue
		var jname := String(jdict.get("name", "岗位"))
		var jval := String(jdict.get("value", "0 / 0"))
		var jratio := float(jdict.get("ratio", -1.0))
		if jratio < 0.0:
			var slash := jval.find("/")
			if slash >= 0:
				var f := _parse_leading_float(jval.substr(0, slash), 0.0)
				var r := _parse_leading_float(jval.substr(slash + 1), 0.0)
				jratio = f / r if r > 0.0 else 1.0
			else:
				jratio = 1.0
		var clamped_j := clampf(jratio, 0.0, 1.0)
		var is_owner_row := jname.begins_with("业主")
		job_bars.append({
			"id": String(jdict.get("id", "job_%d" % idx)),
			"label": jname,
			"icon": &"family.metric.wealth" if is_owner_row else &"population.profession.worker",
			"value": clamped_j,
			"text": jval.split("（")[0].strip_edges(),
			"color": UITokens.DOSSIER_OXBLOOD if clamped_j < 0.50 else (UITokens.DOSSIER_BRASS if clamped_j < 0.99 else UITokens.DOSSIER_VERDIGRIS),
			"tooltip": "%s：%s" % [jname, jval],
		})

	var prod_rows: Array = row.get("production_rows", [])
	var production_candidates := []
	var unused_input_notes := PackedStringArray()
	var prod_peak := 0.001
	var has_natural_input := false
	var has_natural_gen := false
	for raw_p in prod_rows:
		if not (raw_p is Dictionary):
			continue
		var pdict: Dictionary = raw_p
		var pid := String(pdict.get("id", ""))
		if pid.begins_with("natural_input"):
			has_natural_input = true
		elif pid.begins_with("natural_generation"):
			has_natural_gen = true

	for idx in range(prod_rows.size()):
		var raw_p = prod_rows[idx]
		if not (raw_p is Dictionary):
			continue
		var pdict: Dictionary = raw_p
		var pid := String(pdict.get("id", "prod_%d" % idx))
		if pid in ["climate_fit", "climate_lost_output", "input_none", "output_none"]:
			continue
		# 仅在同时有培育与消耗时才显示“自然资源净额”，避免与单向消耗行重复。
		if pid == "resource_net" and not (has_natural_input and has_natural_gen):
			continue
		var full_name := String(pdict.get("name", ""))
		var short_name := String(pdict.get("short_name", full_name))
		var val_str := String(pdict.get("value", ""))
		var rate_num := float(pdict.get("daily_per_building_float", absf(_parse_leading_float(val_str, 0.0))))
		var is_input := pid.begins_with("input_") or full_name.begins_with("原材料")
		if is_input and rate_num <= 0.00001:
			var cand_desc := String(pdict.get("candidates_detail", full_name.trim_prefix("原材料 · ")))
			if not cand_desc.is_empty() and cand_desc != "无":
				unused_input_notes.append(cand_desc)
			continue
		if short_name.length() > 14 and short_name.find("/") >= 0:
			var first_part := short_name.split("/")[0].strip_edges()
			short_name = "%s等" % first_part
		var compact_val := val_str.replace(" 单位/栋/日", "/栋/日")
		prod_peak = maxf(prod_peak, rate_num)
		var bar_color := UITokens.DOSSIER_VERDIGRIS
		var icon_key := &"metric.goods"
		if pid.begins_with("output_") or full_name.begins_with("产出"):
			bar_color = UITokens.DOSSIER_VERDIGRIS
			icon_key = &"metric.goods"
		elif pid.begins_with("natural_") or pid == "resource_net":
			bar_color = UITokens.DOSSIER_SLATE if val_str.find("不足") < 0 else UITokens.DOSSIER_OXBLOOD
			icon_key = &"economy.resource"
		else:
			bar_color = UITokens.DOSSIER_BRASS
			icon_key = &"economy.building.factory"
		production_candidates.append({
			"id": pid,
			"label": short_name,
			"icon": icon_key,
			"rate": rate_num,
			"text": compact_val,
			"color": bar_color,
			"tooltip": "%s：%s" % [full_name, val_str],
		})

	var production_bars := []
	for item in production_candidates:
		var rate := float(item.rate)
		production_bars.append({
			"id": item.id,
			"label": item.label,
			"icon": item.icon,
			"value": clampf(rate / prod_peak, 0.08 if rate > 0.0 else 0.0, 1.0),
			"text": item.text,
			"color": item.color,
			"tooltip": item.tooltip,
		})

	var unused_inputs_summary := ""
	if not unused_input_notes.is_empty():
		unused_inputs_summary = "可选增产投入（当前未消耗）：%s。" % "；".join(unused_input_notes)

	var cash_rev := float(finance.get("cash_revenue_float", 0.0))
	var in_kind_rev := float(finance.get("in_kind_float", 0.0))
	var subsidy_rev := float(finance.get("subsidy_float", 0.0))
	var total_rev := float(finance.get("revenue_float", _parse_leading_float(rev_text, cash_rev + in_kind_rev)))
	var input_cost_val := float(finance.get("input_cost_float", 0.0))
	var wages_val := float(finance.get("wages_paid_float", 0.0))
	var tax_val := float(finance.get("business_tax_float", 0.0))
	var total_cost := float(finance.get("cost_float", _parse_leading_float(cost_text, input_cost_val + wages_val + tax_val)))

	# 兼容未携带细分浮点字段的旧字典（按 breakdown 解析）
	if cash_rev <= 0.0 and in_kind_rev <= 0.0 and total_rev > 0.0:
		cash_rev = total_rev
	var revenue_segments := []
	if cash_rev > 0.0001:
		revenue_segments.append({
			"label": "市场销售",
			"value": cash_rev,
			"text": String(finance.get("cash_revenue_text", UITokens.format_compact_number_cn(cash_rev, 2))),
			"color": UITokens.DOSSIER_VERDIGRIS,
		})
	if in_kind_rev > 0.0001:
		revenue_segments.append({
			"label": "自用留存折算",
			"value": in_kind_rev,
			"text": String(finance.get("in_kind_text", UITokens.format_compact_number_cn(in_kind_rev, 2))),
			"color": UITokens.DOSSIER_BRASS,
		})
	if subsidy_rev > 0.0001:
		revenue_segments.append({
			"label": "经营补贴",
			"value": subsidy_rev,
			"text": String(finance.get("subsidy_text", UITokens.format_compact_number_cn(subsidy_rev, 2))),
			"color": UITokens.DOSSIER_SLATE,
		})

	var cost_segments := []
	if input_cost_val > 0.0001:
		cost_segments.append({
			"label": "原料采购",
			"value": input_cost_val,
			"text": String(finance.get("input_cost_text", UITokens.format_compact_number_cn(input_cost_val, 2))),
			"color": UITokens.DOSSIER_OXBLOOD,
		})
	if wages_val > 0.0001:
		cost_segments.append({
			"label": "雇员工资",
			"value": wages_val,
			"text": String(finance.get("wages_paid_text", UITokens.format_compact_number_cn(wages_val, 2))),
			"color": UITokens.DOSSIER_BRASS,
		})
	if tax_val > 0.0001:
		cost_segments.append({
			"label": "营业税费",
			"value": tax_val,
			"text": String(finance.get("business_tax_text", UITokens.format_compact_number_cn(tax_val, 2))),
			"color": UITokens.DOSSIER_UMBER,
		})

	var finance_note := ""
	if cost_segments.is_empty() and not finance.is_empty():
		finance_note = "本期无外购原料、雇员薪资与营业税支出（业主自营收益已计入总收入）。"

	return {
		"kpis": kpis,
		"insights": insights,
		"capacity_bars": capacity_bars,
		"job_bars": job_bars,
		"production_bars": production_bars,
		"unused_inputs_summary": unused_inputs_summary,
		"finance_diverging_bar": {
			"left_label": "本期总成本",
			"left_value": total_cost,
			"left_text": cost_text if cost_text != "—" else "0",
			"right_label": "税后总收入",
			"right_value": total_rev,
			"right_text": rev_text if rev_text != "—" else "0",
		},
		"revenue_segments": revenue_segments,
		"cost_segments": cost_segments,
		"finance_note": finance_note,
		"finance_warning": String(finance.get("warning", "")),
	}


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
	var country_defaults := _tax_basis_points_array(policy,
		"country_default_rates_basis_points", "country_default_rates")
	var local_defaults := _tax_basis_points_array(policy,
		"local_default_rates_basis_points", "local_default_rates")
	var local_flags: PackedByteArray = policy.get(
		"has_local_default", PackedByteArray())
	var country_modes: PackedInt32Array = policy.get(
		"country_default_assessment_modes", PackedInt32Array())
	var local_modes: PackedInt32Array = policy.get(
		"local_default_assessment_modes", PackedInt32Array())
	for kind_value in kinds:
		var kind := String(kind_value)
		var kind_id := int(TAX_KIND_IDS.get(kind, -1))
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
			"kind_label": String(TAX_DEFAULT_LABELS.get(kind,
				TAX_KIND_LABELS.get(kind, kind))),
			"accent": TAX_KIND_ACCENTS.get(kind, UITokens.ACCENT),
			"item_id": "", "base": rate, "effective": rate,
			"mode": mode, "effective_mode": mode,
			"default_rate": inherited, "default_mode": inherited_mode,
			"has_override": overridden,
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
	var country_defaults := _tax_basis_points_array(policy,
		"country_default_rates_basis_points", "country_default_rates")
	var local_defaults := _tax_basis_points_array(policy,
		"local_default_rates_basis_points", "local_default_rates")
	var local_flags: PackedByteArray = policy.get(
		"has_local_default", PackedByteArray())
	var local_modes: PackedInt32Array = policy.get(
		"local_default_assessment_modes", PackedInt32Array())
	var country_modes: PackedInt32Array = policy.get(
		"country_default_assessment_modes", PackedInt32Array())
	for kind_value in OBJECT_TAX_KINDS.get(object_kind, []):
		var kind := String(kind_value)
		var group: Dictionary = policy.get(kind, {})
		var ids: PackedStringArray = group.get("item_ids", PackedStringArray())
		var item_index := ids.find(item_id)
		var rates := _tax_group_basis_points(group, "final_base_rates")
		if item_index < 0 or item_index >= rates.size():
			continue
		var effective := _tax_group_basis_points(group, "effective_rates", rates)
		var modes: PackedInt32Array = group.get(
			"assessment_modes", PackedInt32Array())
		var item_flags: PackedByteArray = group.get(
			"has_local_item", PackedByteArray())
		var country_bases := _tax_group_basis_points(group, "country_base_rates")
		var kind_id := int(TAX_KIND_IDS.get(kind, -1))
		var inherited := int(local_defaults[kind_id]) \
			if kind_id >= 0 and kind_id < local_flags.size() \
			and local_flags[kind_id] != 0 and kind_id < local_defaults.size() \
			else (int(country_bases[item_index]) \
				if item_index < country_bases.size() else (int(country_defaults[kind_id]) \
					if kind_id >= 0 and kind_id < country_defaults.size() else 0))
		var inherited_mode := int(local_modes[kind_id]) \
			if kind_id >= 0 and kind_id < local_flags.size() \
			and local_flags[kind_id] != 0 and kind_id < local_modes.size() \
			else (int(country_modes[kind_id]) \
				if kind_id >= 0 and kind_id < country_modes.size() else 0)
		var mode := int(modes[item_index]) if item_index < modes.size() else inherited_mode
		lanes.append({
			"scope": "item", "kind": kind,
			"kind_label": String(TAX_KIND_LABELS.get(kind, kind)),
			"accent": TAX_KIND_ACCENTS.get(kind, UITokens.ACCENT),
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


func _tax_basis_points_array(policy: Dictionary, preferred_key: String,
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


func _tax_group_basis_points(group: Dictionary, key: String,
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
	population_summary: Dictionary = {},
	intel_visible: bool = true,
	has_river: bool = false
) -> Dictionary:
	# terrain_v is the legacy-stable bioclimatic/biome axis. Keep its value in
	# the compact header; the detailed climate-zone label lives in the geography tab.
	var land_title := "%s · %s" % [
		LandformType.name_cn(landform_v), TerrainType.terrain_name_cn(terrain_v)]
	var title := land_title
	var meta := PackedStringArray()
	meta.append(_ownership_text(country_summary, intel_visible))
	if bool(population_summary.get("settlement_name_active", false)):
		title = "%s · %s" % [
			String(population_summary.get("settlement_name", "")),
			String(population_summary.get("prosperity_name", ""))]
		meta.append(land_title)
	if has_river:
		meta.append("临河")
	if not intel_visible:
		meta.append("视野之外 · 仅存地理记忆")
	return {
		"kicker": "地块档案 · 区域 %d, %d" % [off.x + 1, off.y + 1],
		"title": title,
		"subtitle": " · ".join(meta),
	}


func _ownership_text(country_summary: Dictionary, intel_visible: bool) -> String:
	if not intel_visible:
		return "归属未知"
	if not bool(country_summary.get("owned", false)):
		return "无主之地"
	var country_name := String(country_summary.get("country_name", "未知国家"))
	if int(country_summary.get("country_handle", -1)) == _player_country_handle():
		return "%s · 本国领土" % country_name
	return country_name


## 页头四格 KPI：有人定居看民生（人口/粮食/就业/满足），
## 无人之地看开拓价值（适宜度/潜在承载/气候/归属）。
func _kpis(
	intel_visible: bool,
	temp: float,
	moist: float,
	habitability: float,
	is_water: bool,
	population_summary: Dictionary,
	country_summary: Dictionary,
	cell_idx: int = -1
) -> Array:
	var climate_kpi := {
		"id": "kpi_climate", "title": "气候", "icon": &"climate.sun", "kind": "text",
		"text": _temperature_band(temp), "caption": _moisture_band(moist),
		"tooltip": "气温 %s · 湿度 %s" % [_temperature_band(temp), _moisture_band(moist)],
	}
	var suitability_kpi := {
		"id": "kpi_suitability", "title": "适宜度", "icon": &"summary.overview",
		"kind": "percent", "value": habitability, "caption": _score_caption(habitability),
		"tooltip": "由气温、湿度、植被活力、海拔与通行综合估算的定居条件。",
	}
	if not intel_visible:
		return [suitability_kpi, climate_kpi, {
			"id": "kpi_intel", "title": "情报", "icon": &"system.unknown", "kind": "text",
			"text": "视野之外", "caption": "人口与市场未知",
		}]
	var population := int(population_summary.get("population", 0))
	var carrying := int(population_summary.get("carrying_k_eff", 0))
	var ownership := _ownership_text(country_summary, true)
	if bool(population_summary.get("pending", false)):
		return [suitability_kpi, climate_kpi, {
			"id": "kpi_owner", "title": "归属", "icon": &"metric.territory", "kind": "text",
			"text": String(country_summary.get("country_name", "无主之地")) \
				if bool(country_summary.get("owned", false)) else "无主",
			"caption": ownership, "tooltip": ownership,
		}, {
			"id": "kpi_population", "title": "人口", "icon": &"ecology.growth", "kind": "text",
			"text": "读取中", "caption": "下一日刷新",
		}]
	if population <= 0 or not bool(population_summary.get("ok", false)):
		var owned := bool(country_summary.get("owned", false))
		var prospect_kpi := {
			"id": "kpi_carrying", "title": "潜在承载", "icon": &"ecology.growth",
			"kind": "count", "value": float(carrying), "caption": "",
			"tooltip": "按本地粮食产能估算，此地最多能养活的人口。",
		}
		if carrying <= 0:
			prospect_kpi = _primary_resource_kpi(cell_idx, is_water)
		return [suitability_kpi, prospect_kpi, climate_kpi, {
			"id": "kpi_owner", "title": "归属", "icon": &"metric.territory", "kind": "text",
			"text": String(country_summary.get("country_name", "无主之地")) if owned else "无主",
			"caption": "" if owned else "可开拓",
			"tooltip": ownership,
		}]
	var food_access := float(population_summary.get("food_access_q16", 65536)) / 65536.0
	var jobs_capacity := int(population_summary.get("job_capacity", 0))
	var jobs_filled := int(population_summary.get("jobs_filled", 0))
	var openings := int(population_summary.get("job_openings", 0))
	var satisfaction := float(population_summary.get("satisfaction_q16", 0)) / 65536.0
	var over_capacity := carrying > 0 and population > carrying
	return [{
		"id": "kpi_population", "title": "人口", "icon": &"ecology.growth", "kind": "count",
		"value": float(population),
		"caption": "",
	}, {
		"id": "kpi_food", "title": "粮食", "icon": &"economy.crop", "kind": "percent",
		"value": food_access, "positive_good": true,
		"caption": "本地不产粮" if carrying <= 0 else (
			"超出承载 %s" % UITokens.format_compact_number_cn(float(carrying), 1)
			if over_capacity else ""),
		"tone": "risk" if over_capacity or food_access < 0.8 else "",
		"tooltip": "实际取得的口粮占所需口粮的比例；承载力为本地粮食可养活的人口。",
	}, {
		"id": "kpi_jobs", "title": "就业", "icon": &"economy.building",
		"kind": "percent" if jobs_capacity > 0 else "text",
		"value": float(jobs_filled) / float(jobs_capacity) if jobs_capacity > 0 else 0.0,
		"text": "无岗位",
		"caption": "空缺 %s 岗" % UITokens.format_compact_number_cn(float(openings), 1) \
			if jobs_capacity > 0 and openings > 0 else "",
		"tooltip": "已到岗 %d / 岗位 %d" % [jobs_filled, jobs_capacity],
	}, {
		"id": "kpi_satisfaction", "title": "需求满足", "icon": &"family.house",
		"kind": "percent", "value": satisfaction,
		"caption": "" if satisfaction >= 0.85 else (
			"勉强维持" if satisfaction >= 0.6 else "生计困难"),
		"tone": "risk" if satisfaction < 0.6 else "",
		"tooltip": "居民基本需求（食物、衣着等）得到满足的程度。",
	}]


func _primary_resource_kpi(cell_idx: int, is_water: bool) -> Dictionary:
	var kpi := {"id": "kpi_resource", "title": "主要资源", "icon": &"economy.resource",
		"kind": "text", "text": "无", "caption": ""}
	if cell_idx < 0:
		return kpi
	var best: Dictionary = {}
	var visible_count := 0
	for raw in _resource_state(cell_idx, is_water, _resource_visibility_context(cell_idx)):
		var item: Dictionary = raw
		if not bool(item.get("available", true)) or float(item.get("reserve", 0.0)) <= 0.000001:
			continue
		visible_count += 1
		if best.is_empty() or float(item.get("rank", 0.0)) > float(best.get("rank", 0.0)):
			best = item
	if best.is_empty():
		return kpi
	kpi["text"] = String(best.get("name", "资源"))
	kpi["caption"] = "另有 %d 种" % (visible_count - 1) if visible_count > 1 else ""
	kpi["tooltip"] = "此地储量最可观的自然资源；完整清单见地理页。"
	return kpi


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
	if is_water:
		ecology["gauges"] = []
		ecology["metrics"] = (ecology.get("metrics", []) as Array).slice(0, 1)
	var physical_metrics := [
		{"id": "geography_landform", "title": "地貌", "value": LandformType.name_cn(landform_v), "subtitle": "", "accent": UITokens.GEO, "icon": "geo"},
	]
	physical_metrics.append_array(geography.get("metrics", []))
	if cover_v != CoverType.CV.NONE:
		physical_metrics.append({"id": "geography_cover", "title": "地表覆盖", "value": CoverType.name_cn(cover_v), "subtitle": "", "accent": UITokens.WATER, "icon": "surface"})
	# Keep the legacy metric id for live-patch compatibility, but render the
	# value in the climate section under its actual biome/climate-zone meaning.
	var climate_metrics: Array = [
		{"id": "geography_terrain", "title": "气候区", "value": TerrainType.terrain_name_cn(terrain_v), "subtitle": "", "accent": UITokens.CLIMATE, "icon": "climate"},
		{"id": "climate_weather", "title": "当前天气", "value": _weather_name(cell, idx), "subtitle": "", "accent": UITokens.WATER, "icon": "weather"},
	]
	climate_metrics.append_array(climate.get("metrics", []))
	climate_metrics.append_array(hydrology.get("metrics", []))
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
				"title": "气候与水文",
				"icon": "water",
				"accent": UITokens.WATER,
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
	resource_section["icon"] = "resource"
	resource_section["accent"] = UITokens.RESOURCE
	if resource_section.has("resource_rows"):
		var any_change := false
		for row in resource_section["resource_rows"]:
			if String((row as Dictionary).get("delta", "—")) != "—":
				any_change = true
				break
		var columns := [{"text": "丰度", "width": 40.0}, {"text": "储量", "width": 70.0}]
		if any_change:
			columns.append({"text": "日变化", "width": 64.0})
		else:
			for row in resource_section["resource_rows"]:
				(row as Dictionary)["delta"] = ""
		resource_section["list_header"] = {"lead": "资源", "indent": 37.0, "columns": columns}
	var sections: Array = category.get("sections", [])
	sections.insert(mini(1, sections.size()), resource_section)
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
		"collapsed": true,
		"summary": "%d 种" % badges.size(),
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
	var metrics := [{
		"id": "geography_passage",
		"title": "通行",
		"value": _passage_text(passable_land, cell.passable_sea, terrain_v),
		"subtitle": "",
		"accent": UITokens.ACCENT if passable_land or cell.passable_sea else UITokens.RISK,
		"icon": "target",
	}]
	if not feats.is_empty():
		metrics.append({
			"id": "geography_features",
			"title": "地理特征",
			"value": "、".join(feats),
			"subtitle": "",
			"accent": UITokens.WATER,
			"icon": "water",
		})
	return {
		"metrics": metrics,
		"gauges": [
			{"id": "geography_elevation_gauge", "label": "海拔", "value": elev, "accent": UITokens.GEO, "marker": _sea_level, "status_label": "", "value_text": _elevation_band(elev, _sea_level), "tooltip": "竖线为海平面"},
		],
	}


func _passage_text(passable_land: bool, passable_sea: bool, terrain_v: int) -> String:
	if not passable_land:
		return "可航行" if passable_sea else "无法通行"
	var cost := TerrainType.get_move_cost(terrain_v)
	var land := "平坦易行" if cost <= 1 else ("崎岖难行" if cost == 2 else "险峻难行")
	return "%s · 可通航" % land if passable_sea else land


func _climate_category(cell: HexCell, idx: int, temp: float, moist: float, base_moist: float, wf: Dictionary) -> Dictionary:
	return {
		"metrics": [
			{"id": "climate_precip", "title": "降水", "value": _precip_band(float(wf["precip"])), "subtitle": "", "accent": UITokens.WATER, "icon": "weather"},
		],
		"gauges": [
			{"id": "climate_temp_gauge", "label": "气温", "value": temp, "accent": UITokens.CLIMATE, "status_label": "", "value_text": _temperature_band(temp)},
			{"id": "climate_moisture_gauge", "label": "湿度", "value": moist, "accent": UITokens.WATER, "marker": base_moist, "status_label": "", "value_text": _moisture_band(moist), "tooltip": "竖线为此地常年湿度"},
		],
		"charts": [_temperature_chart("climate_temperature", "近期气温", idx, temp)],
	}


func _hydrology_category(_cell: HexCell, _idx: int, _wf: Dictionary, snow: float, is_water: bool) -> Dictionary:
	var metrics := []
	if snow >= 0.05:
		metrics.append({"id": "hydrology_snow", "title": "海冰" if is_water else "积雪", "value": _cover_intensity_band(snow), "subtitle": "", "accent": UITokens.WATER, "icon": "water"})
	return {"metrics": metrics, "gauges": []}


func _ecology_category(cell: HexCell, idx: int, vegetation_v: int, vitality: float) -> Dictionary:
	var stress_heat: float = _adapter_float("get_vegetation_heat_stress", idx, cell.vegetation_heat_stress)
	var stress_drought: float = _adapter_float("get_vegetation_drought_stress", idx, cell.vegetation_drought_stress)
	var stress_cold: float = _adapter_float("get_vegetation_cold_stress", idx, cell.vegetation_cold_stress)
	var regen: float = _adapter_float("get_vegetation_regen_score", idx, cell.vegetation_regen_score)
	var insights := []
	var stress_name := "热"
	var stress := stress_heat
	if stress_drought > stress:
		stress_name = "干旱"
		stress = stress_drought
	if stress_cold > stress:
		stress_name = "寒冷"
		stress = stress_cold
	var baseline_name := VegetationType.name_cn(cell.base_vegetation)
	var current_name := VegetationType.name_cn(vegetation_v)
	return {
		"insights": insights,
		"metrics": [
			{"id": "ecology_vegetation", "title": "当前植被", "value": current_name, "subtitle": "" if baseline_name == current_name else "未开发时为%s" % baseline_name, "accent": UITokens.ECO, "icon": "eco"},
			{"id": "ecology_pressure", "title": "主要压力", "value": "无明显压力" if stress < 0.20 else "%s胁迫%s" % [stress_name, _stress_band(stress)], "subtitle": "", "accent": UITokens.RISK if stress >= 0.50 else UITokens.ACCENT, "icon": "warning"},
		],
		"gauges": [
			{"id": "ecology_vitality_gauge", "label": "植被活力", "value": vitality, "accent": UITokens.ECO, "status_label": "", "value_text": _vitality_band(vitality)},
			{"id": "ecology_regen_gauge", "label": "恢复潜力", "value": regen, "accent": UITokens.ECO, "status_label": "", "value_text": _vitality_band(regen)},
		],
		"charts": [{"id": "ecology_history", "title": "植被演替", "values": _history_values(cell), "accent": UITokens.ECO}],
	}


func _resources_category(resource_state: Array, visibility: Dictionary = {}) -> Dictionary:
	var rows := []
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
	var visible_count := 0
	for data in sorted:
		var item: Dictionary = data
		if not bool(item.get("available", true)):
			continue
		var reserve := float(item.get("reserve", 0.0))
		var delta := float(item.get("delta", 0.0))
		var density := resource_density_band(float(item.get("density_ratio", 0.0)))
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
		if reserve > 0.000001:
			visible_count += 1
	if visible_count == 0:
		return {
			"insights": [{"id": "resource_empty", "text": "此地块当前无可显示自然资源。", "accent": UITokens.TEXT_MUTED, "icon": "resource"}],
			"resource_rows": rows,
		}
	return {"resource_rows": rows, "summary": "%d 种" % visible_count}


func _history_category(cell: HexCell) -> Dictionary:
	return {
		"insights": [],
		"charts": [
			{"id": "history_vegetation", "title": "近期植被序列", "values": _history_values(cell), "accent": UITokens.ECO},
			_temperature_chart("history_temperature", "近期温度变化", int(cell.index), _temp(cell, int(cell.index))),
		],
		"badges": _history_badges(cell),
	}


static func _snapshot_pending(snapshot: Dictionary) -> bool:
	return bool(snapshot.get("busy", false)) or bool(snapshot.get("read_view_pending", false))


static func _pending_category() -> Dictionary:
	return {"data_pending": true, "insights": [{"id": "snapshot_pending",
		"text": "正在读取最新档案…", "accent": UITokens.TEXT_MUTED, "icon": "history"}]}


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
	var summary: Dictionary = facade.population_cell_summary(cell_idx)
	if bool(summary.get("ok", false)):
		if _population_summary_cache.size() > 256:
			_population_summary_cache.clear()
		_population_summary_cache[cell_idx] = summary
		return summary
	if bool(summary.get("busy", false)) or bool(summary.get("read_view_pending", false)):
		var cached: Dictionary = _population_summary_cache.get(cell_idx, {})
		if not cached.is_empty():
			return cached
		summary["pending"] = true
	return summary


func _country_summary(cell_idx: int) -> Dictionary:
	if _generator == null or not _generator.has_method("get_country_facade"):
		return {"country_name": "无主之地"}
	var facade = _generator.get_country_facade()
	if facade == null or not facade.has_method("cell_summary"):
		return {"country_name": "无主之地"}
	var summary: Dictionary = facade.cell_summary(cell_idx)
	return summary if bool(summary.get("ok", false)) else {"country_name": "无主之地"}


## 悬停卡复用的公开入口：「无主之地」文案与 pending 回退只允许一份实现。
func population_summary(cell_idx: int) -> Dictionary:
	return _population_summary(cell_idx)


func country_summary(cell_idx: int) -> Dictionary:
	return _country_summary(cell_idx)


func sample_day() -> int:
	return _current_sample_day()


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
	if _snapshot_pending(snapshot):
		return _pending_category()
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
	var source_cell := int(snapshot.get("cell_idx", -1))
	var country := _country_summary(source_cell) if source_cell >= 0 else {}
	var player_owned := bool(country.get("owned", false)) \
		and int(country.get("country_handle", 0)) == _player_country_handle()
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
			"source_cell": source_cell,
			"can_dispatch": player_owned and i < populations.size() and populations[i] > 1,
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
	if rows.is_empty():
		return {"insights": [{"id": "families_empty", "text": "此地尚无显赫家族。",
			"accent": UITokens.TEXT_MUTED, "icon": "family.house"}], "family_rows": rows}
	return {"family_rows": rows, "list_header": {"lead": "家族 · 族人 · 产业",
		"indent": 41.0, "columns": [{"text": "威望", "width": 64.0}]}}


func _family_detail_fields(snapshot: Dictionary) -> Dictionary:
	return {
		"population": UITokens.format_compact_number_cn(float(snapshot.get("population", 0)), 1),
		"cash_claim": _money_text(int(snapshot.get("cash_claim", 0))),
		"productive_asset_value": _money_text(int(snapshot.get("building_asset_value",
			snapshot.get("productive_asset_value", 0)))),
		"net_worth": _money_text(int(snapshot.get("net_worth", 0))),
		"owned_buildings": UITokens.format_compact_number_cn(float(snapshot.get("owned_buildings", 0)), 1),
		"notable_people": int(snapshot.get("notable_person_count", 0)),
		"founded_day": int(snapshot.get("founded_day", 0)),
		"decline_reviews": int(snapshot.get("decline_reviews", 0)),
		"origin_cell": int(snapshot.get("origin_cell", -1)),
		"origin_settlement_name": String(snapshot.get("origin_settlement_name", "")),
	}


func _family_trait_rows(snapshot: Dictionary) -> Array:
	var rows: Array = []
	var names: PackedStringArray = snapshot.get("display_names", PackedStringArray())
	var keys: PackedStringArray = snapshot.get("trait_keys", PackedStringArray())
	var core: PackedByteArray = snapshot.get("core", PackedByteArray())
	var descriptions: PackedStringArray = snapshot.get("descriptions", PackedStringArray())
	var effect_names: PackedStringArray = snapshot.get("effect_display_names", PackedStringArray())
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
			"badges": FamilyBuffCopy.extract_trait_badges(detail),
			"effect_names": effect_names,
			# 当前 facade 只提供一份说明文本；不要把它伪装成第二份效果摘要。
			"effect_summary": "",
			"tooltip": detail,
		})
	return rows


func _family_behavior_rows(snapshot: Dictionary, cell_idx: int = -1) -> Array:
	var visibility := _family_behavior_visibility(cell_idx)
	return _family_behavior_rows_for_visibility(snapshot, visibility)


static func family_behavior_rows_for_cell(snapshot: Dictionary, facade,
		cell_idx: int) -> Array:
	var visibility := _family_behavior_visibility_for_cell(facade, cell_idx)
	# 派遣快照未就绪时不泄露整张目录；只显示已确认可见的选择器。
	for axis in ["buildings", "goods", "professions", "needs"]:
		visibility["enforce_" + axis] = true
	return _family_behavior_rows_for_visibility(snapshot, visibility)


static func _family_behavior_rows_for_visibility(snapshot: Dictionary,
		visibility: Dictionary) -> Array:
	var rows: Array = []
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
		var display_name := String(names[index]) if index < names.size() else "目标 %d" % index
		var signed_delta := factor_percent - 100.0
		rows.append({
			"id": "%d:%s" % [axis, stable_id],
			"stable_id": stable_id,
			"axis": axis,
			"axis_name": axis_name,
			"name": display_name,
			"icon": String(_family_behavior_icon(axis, stable_id, display_name)),
			"factor_q16": factor_q16,
			"factor_percent": factor_percent,
			"factor_text": _q16_percent_text(factor_q16),
			"signed_delta_percent": signed_delta,
			"delta_text": "%s%.0f%%" % [
				"+" if signed_delta >= 0.0 else "−", absf(signed_delta)],
			"bar_ratio": clampf(factor_percent / 200.0, 0.0, 1.0),
			"deviation": absf(factor_percent - 100.0),
			"value": "%s偏好 · %s" % [axis_name, _q16_percent_text(factor_q16)],
		})
	return rows


static func _family_behavior_icon(axis: int, stable_id: String, name_text: String = "") -> StringName:
	match axis:
		0:
			if not stable_id.is_empty():
				if stable_id.contains("hearth"): return &"economy.building.hearth"
				if stable_id.contains("gathering"): return &"economy.building.gathering"
				if stable_id.contains("merchant") or stable_id.contains("market") or stable_id.contains("trade"): return &"economy.building.market"
				if stable_id.contains("fish"): return &"economy.building.fishing"
				if stable_id.contains("hunting"): return &"economy.building.hunting"
				if stable_id.contains("kitchen") or stable_id.contains("food") or stable_id.contains("slaughter"): return &"economy.building.food"
				if stable_id.contains("farm") or stable_id.contains("estate") or stable_id.contains("pasture") or stable_id.contains("rice") or stable_id.contains("wheat") or stable_id.contains("cotton") or stable_id.contains("flax"): return &"economy.building.farm"
				if stable_id.contains("timber") or stable_id.contains("lumber"): return &"economy.building.forestry"
				if stable_id.contains("mine") or stable_id.contains("ore") or stable_id.contains("quarry") or stable_id.contains("stone") or stable_id.contains("coal") or stable_id.contains("salt"): return &"economy.building.mine"
				if stable_id.contains("workshop") or stable_id.contains("kiln") or stable_id.contains("smith") or stable_id.contains("tailor") or stable_id.contains("tannery"): return &"economy.building.workshop"
				if stable_id.contains("plant") or stable_id.contains("works") or stable_id.contains("mill") or stable_id.contains("factory"): return &"economy.building.factory"
			if name_text.contains("农") or name_text.contains("田") or name_text.contains("牧"): return &"economy.building.farm"
			if name_text.contains("矿") or name_text.contains("石") or name_text.contains("盐"): return &"economy.building.mine"
			if name_text.contains("商") or name_text.contains("市") or name_text.contains("贸"): return &"economy.building.market"
			if name_text.contains("林") or name_text.contains("木"): return &"economy.building.forestry"
			if name_text.contains("猎"): return &"economy.building.hunting"
			if name_text.contains("渔"): return &"economy.building.fishing"
			return &"economy.building"
		1:
			var prof_icon := IconCatalog.profession_semantic(stable_id)
			if prof_icon != &"system.unknown":
				return prof_icon
			if name_text.contains("采集"): return &"profession.forager"
			if name_text.contains("猎"): return &"profession.hunter"
			if name_text.contains("商"): return &"profession.merchant"
			if name_text.contains("矿"): return &"profession.miner"
			if name_text.contains("农"): return &"profession.agricultural_worker"
			if name_text.contains("渔"): return &"profession.fisher"
			if name_text.contains("匠") or name_text.contains("工"): return &"profession.artisan"
			if name_text.contains("学") or name_text.contains("研"): return &"profession.scholar"
			return &"population.profession.worker"
		2:
			if stable_id.contains("food") or stable_id.contains("staple") or stable_id.contains("protein") or name_text.contains("食") or name_text.contains("饮") or name_text.contains("温饱"):
				return &"economy.building.food"
			if stable_id.contains("cloth") or name_text.contains("衣") or name_text.contains("服"):
				return &"good.clothing"
			if stable_id.contains("heat") or stable_id.contains("fuel") or name_text.contains("暖") or name_text.contains("火"):
				return &"economy.building.hearth"
			if stable_id.contains("hous") or stable_id.contains("shelter") or name_text.contains("居") or name_text.contains("宅"):
				return &"population.living.poor"
			if stable_id.contains("lux") or name_text.contains("奢") or name_text.contains("礼"):
				return &"population.living.luxury"
			return &"population.heart"
		3:
			var good_icon := IconCatalog.good_semantic(stable_id)
			if good_icon != &"system.unknown":
				return good_icon
			return &"metric.goods"
		_:
			return &"summary.overview"


func _family_behavior_visibility(cell_idx: int) -> Dictionary:
	var facade = _generator.get_economy_facade() if _generator != null \
		and _generator.has_method("get_economy_facade") else null
	return _family_behavior_visibility_for_cell(facade, cell_idx)


static func _family_behavior_visibility_for_cell(facade, cell_idx: int) -> Dictionary:
	var result := {"buildings": {}, "goods": {}, "professions": {}, "needs": {},
		"enforce_buildings": false, "enforce_goods": false,
		"enforce_professions": false, "enforce_needs": false}
	if cell_idx < 0:
		return result
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
	var populations: PackedInt64Array = snapshot.get("populations", PackedInt64Array())
	var cash_claims: PackedInt64Array = snapshot.get("cash_claims", PackedInt64Array())
	var building_assets: PackedInt64Array = snapshot.get("building_asset_values", PackedInt64Array())
	var satisfactions: PackedInt32Array = snapshot.get("satisfactions_q16", PackedInt32Array())
	var demo_shares: PackedInt32Array = snapshot.get("demography_shares_q16", PackedInt32Array())
	var target_shares: PackedInt32Array = snapshot.get("target_shares_q16", PackedInt32Array())
	var settlement_names: PackedStringArray = snapshot.get("settlement_names", PackedStringArray())
	for index in range(cells.size()):
		var level := int(levels[index]) if index < levels.size() else 0
		var target := int(targets[index]) if index < targets.size() else level
		var cell := int(cells[index])
		var score_q16 := int(scores[index]) if index < scores.size() else 0
		var population_q16 := int(population_shares[index]) if index < population_shares.size() else 0
		var cash_q16 := int(cash_shares[index]) if index < cash_shares.size() else 0
		var building_q16 := int(building_shares[index]) if index < building_shares.size() else 0
		var pop_count := int(populations[index]) if index < populations.size() else 0
		var cash_val := int(cash_claims[index]) if index < cash_claims.size() else 0
		var asset_val := int(building_assets[index]) if index < building_assets.size() else 0
		var sat_q16 := int(satisfactions[index]) if index < satisfactions.size() else 0
		var demo_q16 := int(demo_shares[index]) if index < demo_shares.size() else 0
		var target_q16 := int(target_shares[index]) if index < target_shares.size() else 0
		var settlement := String(settlement_names[index]).strip_edges() \
			if index < settlement_names.size() else ""
		var loc_label := "%s（地块 %d）" % [settlement, cell] \
			if not settlement.is_empty() else "地块 %d" % cell
		rows.append({
			"id": "branch:%d" % cell,
			"kind": "branch",
			"cell": cell,
			"settlement_name": settlement,
			"location_label": loc_label,
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
			"population_count": pop_count,
			"population_count_text": "%s 人" % UITokens.format_compact_number_cn(float(pop_count), 1),
			"cash_amount_text": _money_text(cash_val),
			"building_asset_text": _money_text(asset_val),
			"satisfaction_q16": sat_q16,
			"satisfaction_percent": float(sat_q16) * 100.0 / 65536.0,
			"satisfaction_text": _q16_percent_text(sat_q16),
			"demography_share_text": _q16_percent_text(demo_q16),
			"target_share_text": _q16_percent_text(target_q16),
			"target_level": target,
			"target_label": _prestige_text(target),
			"review_streak": int(streaks[index]) if index < streaks.size() else 0,
			"name": "%s · 威望 %s" % [loc_label, _prestige_text(level)],
			"value": "总分 %s · 人口 %s / 现金 %s / 建筑 %s · 目标 %s（%d/2）" % [
				_q16_percent_text(score_q16), _q16_percent_text(population_q16),
				_q16_percent_text(cash_q16), _q16_percent_text(building_q16),
				_prestige_text(target), int(streaks[index]) if index < streaks.size() else 0],
		})
	return rows


func _family_bound_effect_rows(snapshot: Dictionary) -> Array:
	var rows: Array = []
	var cell := int(snapshot.get("cell_idx", -1))
	var prestige_level := int(snapshot.get("prestige_level", 0))
	var settlement_name := String(snapshot.get("settlement_name", "")).strip_edges()
	var keys: PackedStringArray = snapshot.get(
		"effect_definition_keys", PackedStringArray())
	var names: PackedStringArray = snapshot.get(
		"effect_display_names", PackedStringArray())
	var descriptions: PackedStringArray = snapshot.get(
		"effect_descriptions", PackedStringArray())
	var current_descriptions: PackedStringArray = snapshot.get(
		"effect_current_descriptions", PackedStringArray())
	var prestige_tiers_all: Array = snapshot.get("effect_prestige_descriptions", [])
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
		var tier_statements: Array = []
		if index < prestige_tiers_all.size() and prestige_tiers_all[index] is PackedStringArray:
			for st in (prestige_tiers_all[index] as PackedStringArray):
				tier_statements.append(String(st))
		elif index < prestige_tiers_all.size() and prestige_tiers_all[index] is Array:
			for st in (prestige_tiers_all[index] as Array):
				tier_statements.append(String(st))
		if tier_statements.is_empty():
			for st in FamilyBuffCopy.prestige_statements(detail):
				tier_statements.append(String(st))
		rows.append({
			"id": "effect:%d:%s" % [cell, key],
			"kind": "effect",
			"cell": cell,
			"settlement_name": settlement_name,
			"prestige_level": prestige_level,
			"tier_statements": tier_statements,
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
		var profession_id := String(person.get("profession_stable_id", ""))
		var building := String(person.get("building_type_display_name", ""))
		var detail_parts: Array[String] = []
		if not profession.is_empty():
			detail_parts.append(profession)
		detail_parts.append(job_text)
		if not building.is_empty():
			detail_parts.append(building)
		var cash_val := int(person.get("cash_claim", 0))
		var attr_asset_val := int(person.get("attributed_asset_value", 0))
		var net_worth_val := int(person.get("estimated_net_worth", cash_val + attr_asset_val))
		var equity_q32 := int(person.get("family_equity_share_q32", 0))
		var equity_pct := clampf(float(equity_q32) * 100.0 / 4294967296.0, 0.0, 100.0)
		var job_inc := maxi(0, int(person.get("epoch_job_income", 0)))
		var biz_res := int(person.get("epoch_business_result", 0))
		var cons_exp := maxi(0, int(person.get("epoch_consumption_expense", 0)))
		var tax_exp := maxi(0, int(person.get("epoch_tax", 0)))
		var total_inc := job_inc + maxi(0, biz_res)
		var total_exp := cons_exp + tax_exp + maxi(0, -biz_res)
		var net_flow := total_inc - total_exp
		var sat_q16 := int(person.get("needs_satisfaction_q16", 0))
		rows.append({
			"id": "person:%d" % int(person_handle),
			"kind": "person",
			"person_handle": int(person_handle),
			"portrait_key": "family.workspace.person",
			"name": String(person.get("full_name", "未命名人物")),
			"role": job_text,
			"profession": profession,
			"profession_id": profession_id,
			"profession_icon": String(IconCatalog.profession_semantic(profession_id)),
			"building": building,
			"cell_idx": int(person.get("cell_idx", -1)),
			"notable_since_day": int(person.get("notable_since_day", 0)),
			"cash_claim_text": _money_text(cash_val),
			"attributed_asset_text": _money_text(attr_asset_val),
			"net_worth_val": net_worth_val,
			"net_worth_text": _money_text(net_worth_val),
			"equity_share_percent": equity_pct,
			"equity_share_text": "%.1f%%" % equity_pct,
			"income_val": total_inc,
			"expense_val": total_exp,
			"income_text": _money_text(total_inc),
			"expense_text": _money_text(total_exp),
			"net_cashflow_val": net_flow,
			"net_cashflow_text": "%s%s" % [
				"+" if net_flow >= 0 else "−", _money_text(absi(net_flow))],
			"satisfaction_q16": sat_q16,
			"satisfaction_percent": float(sat_q16) * 100.0 / 65536.0,
			"satisfaction_text": _q16_percent_text(sat_q16),
			"value": " · ".join(detail_parts),
		})
	return rows


## 本地年度产值与人均年度产值。数据全在内存账本里，不发起任何原生查询；
## 未跟踪的格返回空数组，调用方不会多出两格空白指标。
## 金额格式沿用本页邻居（居民存款 / 粮食产出）的 _money_text 约定，不额外加货币符号。
func _gdp_metrics(cell_idx: int) -> Array:
	var gdp := _local_gdp(cell_idx)
	if gdp.is_empty():
		return []
	var ytd := float(gdp.get("ytd", 0.0))
	var per_day := float(gdp.get("per_day", 0.0))
	var days := int(gdp.get("days_counted", 0))
	var days_per_year := maxi(1, int(gdp.get("days_per_year", 365)))
	# 事实表单行只有 44px，副行留给「年度走到哪一天」——累计值最容易被误读成
	# 全年完成额，日均产值挪进 tooltip，不占可见宽度。
	var metrics := [{
		"id": "population_gdp", "title": "本地年度产值",
		"value": _money_text(int(round(ytd))),
		"subtitle": "已计 %d/%d 天" % [days, days_per_year],
		"accent": UITokens.ECO, "icon": "metric.treasury",
		"tooltip": "收入法：建筑营收 − 中间投入 − 维护（= 工资 + 营业盈余，不含营业税）。本年度逐经济周期累计，与全国口径一致。\n日均产值 %s。" % _money_text(int(round(per_day))),
	}]
	var per_capita := float(gdp.get("per_capita", NAN))
	var national_per_capita := float(gdp.get("national_per_capita", NAN))
	if is_nan(per_capita):
		return metrics
	var subtitle := ""
	# 标题已写明「人均」，副行不再重复这两个字，省下的宽度留给大额数字。
	if not is_nan(national_per_capita) and national_per_capita > 0.0:
		var gap := (per_capita - national_per_capita) / national_per_capita * 100.0
		subtitle = "全国 %s（%s%.0f%%）" % [
			_money_text(int(round(national_per_capita))),
			"+" if gap >= 0.0 else "", gap]
	metrics.append({
		"id": "population_gdp_per_capita", "title": "人均年度产值",
		"value": _money_text(int(round(per_capita))),
		"subtitle": subtitle, "accent": UITokens.ACCENT,
		"icon": "family.metric.wealth",
		"tooltip": "本地产值 ÷ 本地人口。括号内是与全国人均的差距，正为高于全国。",
	})
	return metrics


func _population_category(snapshot: Dictionary, market_snapshot: Dictionary = {},
		cell_idx: int = -1) -> Dictionary:
	if _snapshot_pending(snapshot):
		return _pending_category()
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
	var epoch_tax_paid: PackedInt64Array = snapshot.get(
		"epoch_tax_paid_by_cohort", PackedInt64Array())
	var epoch_subsidy_received: PackedInt64Array = snapshot.get(
		"epoch_subsidy_received_by_cohort", PackedInt64Array())
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
	var pop_cell_idx := int(snapshot.get("cell_idx", -1))
	var pop_sample_day := int(snapshot.get("sample_day", _current_sample_day()))
	if pop_cell_idx >= 0:
		_ensure_detail_history_cell(pop_cell_idx)
	var should_sample_pop := not list_only and pop_cell_idx >= 0 \
		and pop_sample_day >= 0 and pop_sample_day != _detail_history_pop_day
	if should_sample_pop:
		_detail_history_pop_day = pop_sample_day
	var cell_avg_dims := _compute_cell_avg_satisfaction_dims(
		populations, satisfaction_dims, dimension_count)
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
		var cohort_dims_float := PackedFloat32Array() if list_only \
			else _cohort_satisfaction_dims_float(satisfaction_dims, dimension_count, i)
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
				var income_pc_flow := income_value / maxi(population, 1)
				var expense_pc_flow := expense_value / maxi(population, 1)
				if income_value > 0:
					income_rows.append({"id": "income_%s" % source_id, "source_id": source_id, "name": _cashflow_source_name(source_id, true), "value": "+%s/人" % _money_text(income_pc_flow), "raw_per_capita": float(income_pc_flow) / 10000.0, "visible": true})
				if expense_value > 0:
					expense_rows.append({"id": "expense_%s" % source_id, "source_id": source_id, "name": _cashflow_source_name(source_id, false), "value": "−%s/人" % _money_text(expense_pc_flow), "raw_per_capita": float(expense_pc_flow) / 10000.0, "visible": true})
		# Fiscal attribution is authoritative even when the detailed cashflow trace
		# has expired or was intentionally omitted from this snapshot.
		var tax_paid_pc := int(epoch_tax_paid[i]) / maxi(population, 1) \
			if i < epoch_tax_paid.size() else 0
		var subsidy_received_pc := int(epoch_subsidy_received[i]) / maxi(population, 1) \
			if i < epoch_subsidy_received.size() else 0
		var has_tax_detail := _has_cashflow_row(expense_rows, "income_tax") \
			or _has_cashflow_row(expense_rows, "consumption_tax") \
			or _has_cashflow_row(expense_rows, "business_tax")
		var has_subsidy_detail := _has_cashflow_row(income_rows, "income_subsidy") \
			or _has_cashflow_row(income_rows, "consumption_subsidy") \
			or _has_cashflow_row(income_rows, "business_subsidy")
		if tax_paid_pc > 0 and not has_tax_detail:
			expense_rows.append({"id": "expense_fiscal_tax", "source_id": "fiscal_tax", "name": "税费（本批）", "value": "−%s/人" % _money_text(tax_paid_pc), "raw_per_capita": float(tax_paid_pc) / 10000.0, "visible": true})
		if subsidy_received_pc > 0 and not has_subsidy_detail:
			income_rows.append({"id": "income_fiscal_subsidy", "source_id": "fiscal_subsidy", "name": "财政补贴（本批）", "value": "+%s/人" % _money_text(subsidy_received_pc), "raw_per_capita": float(subsidy_received_pc) / 10000.0, "visible": true})
		var income_pc := int(settlement_income_by_cohort[i]) / maxi(population, 1) \
			if settlement_available and i < settlement_income_by_cohort.size() else 0
		var expense_pc := int(settlement_expense_by_cohort[i]) / maxi(population, 1) \
			if settlement_available and i < settlement_expense_by_cohort.size() else 0
		if not has_subsidy_detail:
			income_pc += subsidy_received_pc
		if not has_tax_detail:
			expense_pc += tax_paid_pc
		var net_pc := income_pc - expense_pc
		var cohort_hist_key := "%s|%s" % [profession_id, ethnicity_id]
		if should_sample_pop:
			_record_cohort_history(cohort_hist_key, sat,
				float(net_pc) / 10000.0, float(income_pc) / 10000.0,
				float(wealth_pc) / 10000.0)
		var cohort_hist: Dictionary = _cohort_history.get(cohort_hist_key, {})
		var sat_series: PackedFloat32Array = cohort_hist.get("satisfaction", PackedFloat32Array())
		var net_series: PackedFloat32Array = cohort_hist.get("net", PackedFloat32Array())
		var demand_count := visible_demand_count
		var demand_group_count := demand_groups.size()
		var demand_subtitle := "主要：%s%s" % ["、".join(demand_names), " 等" if demand_count > demand_names.size() else ""] if demand_count > 0 else "当前无消费需求"
		var row_dict := {
			"id": "cohort_%s" % str(handles[i] if i < handles.size() else i),
			"name": profession_name,
			"cohort_identity": ethnicity_name,
			"profession_id": profession_id,
			"cohort_handle": int(handles[i]) if i < handles.size() else -1,
			"population": "%s 人" % UITokens.format_compact_number_cn(float(population), 1),
			"population_raw": population,
			"employed_raw": owners + employees,
			"owners_raw": owners,
			"employees_raw": employees,
			"wealth": _money_text(wealth_pc),
			"wealth_raw": float(wealth_pc) / 10000.0,
			"income": "+%s" % _money_text(income_pc) if settlement_available or subsidy_received_pc > 0 else "+—",
			"expense": "−%s" % _money_text(expense_pc) if settlement_available or tax_paid_pc > 0 else "−—",
			"net": "%s%s" % ["+" if net_pc > 0 else ("−" if net_pc < 0 else ""), _money_text(absi(net_pc))] if settlement_available or subsidy_received_pc > 0 or tax_paid_pc > 0 else "—",
			"income_pc_float": float(income_pc) / 10000.0,
			"expense_pc_float": float(expense_pc) / 10000.0,
			"net_pc_float": float(net_pc) / 10000.0,
			"net_positive": net_pc >= 0,
			"status": "%s%s · 满意度 %.1f%% · 就业 %s · 结算 %d日" % [
				"商人 · " if i < merchant_flags.size() and merchant_flags[i] != 0 else "",
				ethnicity_name, sat * 100.0,
				UITokens.format_compact_number_cn(float(owners + employees), 1), settlement_days],
			"accent": UITokens.ACCENT,
			"icon": IconCatalog.profession_semantic(profession_id),
			"living_level": living_level,
			"living_icon": _living_standard_icon(living_level),
			"living_accent": _living_standard_accent(living_level),
			"living_standard": living_name,
			"satisfaction": "%.1f%%" % (sat * 100.0),
			"satisfaction_float": sat,
			"satisfaction_rows": dimension_rows,
			"satisfaction_dims_float": cohort_dims_float,
			"cell_reference_dims_float": cell_avg_dims,
			"worst_dimension": _satisfaction_dimension_name(worst_dimension),
			"worst_dimension_index": worst_dimension,
			"satisfaction_spark": sat_series,
			"satisfaction_delta": _series_lookback_delta(sat_series),
			"net_spark": net_series,
			"net_delta": _series_lookback_delta(net_series),
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
		}
		rows.append(row_dict)
	# 仅保留空态批注；承载/口粮/投资受阻改为由 gauges 与指标表达。
	var insights := []
	if rows.is_empty():
		insights.append({"id": "population_empty", "text": "此地尚无人口。", "accent": UITokens.TEXT_MUTED, "icon": "growth"})
	var job_capacity := int(snapshot.get("job_capacity", 0))
	var jobs_filled := int(snapshot.get("jobs_filled", 0))
	var job_openings := int(snapshot.get("job_openings", 0))
	var carrying_k_eff := int(snapshot.get("carrying_k_eff", 0))
	var local_food_daily := int(snapshot.get("local_food_output_eq_per_day", 0))
	var effective_food_daily := int(snapshot.get("effective_food_supply_eq_per_day", 0))
	var food_access := float(snapshot.get("food_access_q16", 65536)) / 65536.0
	var population_total := int(snapshot.get("population", 0))
	var gauges := []
	if population_total > 0:
		gauges.append({"id": "population_food_gauge", "label": "口粮保障",
			"value": clampf(food_access, 0.0, 1.0),
			"accent": UITokens.GOOD if food_access >= 0.95 else (
				UITokens.WARN if food_access >= 0.8 else UITokens.RISK),
			"value_text": "%.0f%%" % (food_access * 100.0),
			"status_label": "充足" if food_access >= 0.95 else (
				"偏紧" if food_access >= 0.8 else "不足"),
			"tooltip": "居民实际取得的口粮占所需口粮的比例。"})
	if carrying_k_eff > 0:
		var load := float(population_total) / float(carrying_k_eff)
		gauges.append({"id": "population_carrying_gauge", "label": "承载占用",
			"value": clampf(load, 0.0, 1.0),
			"accent": UITokens.RISK if load > 1.0 else (UITokens.WARN if load > 0.85 else UITokens.ECO),
			"value_text": "%s / %s 人" % [
				UITokens.format_compact_number_cn(float(population_total), 1),
				UITokens.format_compact_number_cn(float(carrying_k_eff), 1)],
			"tooltip": "现有人口与本地粮食可养活人口之比；超过上限后人口不再增长。"})
	if job_capacity > 0:
		gauges.append({"id": "population_jobs_gauge", "label": "岗位到岗",
			"value": clampf(float(jobs_filled) / float(job_capacity), 0.0, 1.0),
			"accent": UITokens.ACCENT,
			"value_text": "%s / %s" % [
				UITokens.format_compact_number_cn(float(jobs_filled), 1),
				UITokens.format_compact_number_cn(float(job_capacity), 1)],
			"status_label": "空缺 %s" % UITokens.format_compact_number_cn(float(job_openings), 1) \
				if job_openings > 0 else "满员",
			"tooltip": "本地建筑提供的岗位中已有人到岗的数量。"})
	var epoch_income := int(snapshot.get("epoch_income", 0))
	var epoch_expense := int(snapshot.get("epoch_expense", 0))
	var epoch_net := epoch_income - epoch_expense
	var identities := {}
	for row in rows:
		identities[String((row as Dictionary).get("cohort_identity", ""))] = true
	var mixed_identity := identities.size() > 1
	if not mixed_identity:
		for row in rows:
			(row as Dictionary)["cohort_identity"] = ""
	var local_metrics := [
		{"id": "population_funds", "title": "居民存款", "value": _money_text(int(snapshot.get("funds", 0))), "subtitle": "本期%s %s" % ["结余" if epoch_net >= 0 else "亏空", _money_text(absi(epoch_net))], "accent": UITokens.ACCENT if epoch_net >= 0 else UITokens.RISK, "icon": "resource"},
		_food_output_metric(snapshot, local_food_daily, effective_food_daily),
	]
	# 产值两格只在账本已跟踪该格时出现；他国 / 无主 / 无人聚落不加，指标行不会空转。
	local_metrics.append_array(_gdp_metrics(cell_idx))
	return {
		"insights": insights,
		"gauges": gauges,
		"metrics": local_metrics,
		"cohort_rows": rows,
		"list_header": {"lead": "阶层 · 族群 · 生活" if mixed_identity else "阶层 · 生活",
			"indent": 41.0, "columns": [
			{"text": "人口", "width": 54.0}, {"text": "人均存款/净收", "width": 72.0}]},
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
		var group_cost_raw := 0
		var group_qty_raw := 0
		for group_row in group_rows:
			var rdict := group_row as Dictionary
			var value := int(rdict.get("need_satisfaction_q16", -1))
			if value >= 0:
				satisfaction_total += value
				satisfaction_count += 1
			var q_raw := int(rdict.get("quantity_raw", 0))
			if q_raw > 0:
				group_qty_raw += q_raw
				var c_raw := int(rdict.get("daily_cost_raw", 0))
				if c_raw > 0:
					group_cost_raw += c_raw
		var sat_ratio := float(satisfaction_total) / 65536.0 / float(satisfaction_count) \
			if satisfaction_count > 0 else -1.0
		group["satisfaction_ratio"] = sat_ratio
		group["daily_cost_raw"] = group_cost_raw
		group["quantity_raw"] = group_qty_raw
		group["satisfaction"] = "满足 %.0f%%" % (sat_ratio * 100.0) \
			if sat_ratio >= 0.0 else ""
		groups[group_idx] = group
	return groups


func _ensure_detail_history_cell(cell_idx: int) -> void:
	if cell_idx >= 0 and cell_idx != _detail_history_cell:
		_detail_history_cell = cell_idx
		_detail_history_market_day = -1
		_detail_history_pop_day = -1
		_detail_history_building_day = -1
		_good_history.clear()
		_cohort_history.clear()
		_building_history.clear()


func _append_history_sample(bucket: Dictionary, key: String, value: float) -> PackedFloat32Array:
	var series: PackedFloat32Array = bucket.get(key, PackedFloat32Array())
	series.append(value)
	if series.size() > DETAIL_HISTORY_CAPACITY:
		series = series.slice(series.size() - DETAIL_HISTORY_CAPACITY)
	bucket[key] = series
	return series


static func _series_lookback_delta(series: PackedFloat32Array) -> float:
	if series.size() < 2:
		return NAN
	var lookback := mini(DETAIL_HISTORY_LOOKBACK, series.size() - 1)
	var latest := series[series.size() - 1]
	var earlier := series[series.size() - 1 - lookback]
	return latest - earlier if not is_nan(latest) and not is_nan(earlier) else NAN


func _record_cohort_history(cohort_key: String, sat: float, net_val: float,
		income_val: float, wealth_val: float) -> void:
	var bucket: Dictionary = _cohort_history.get(cohort_key, {})
	_append_history_sample(bucket, "satisfaction", sat)
	_append_history_sample(bucket, "net", net_val)
	_append_history_sample(bucket, "income", income_val)
	_append_history_sample(bucket, "wealth", wealth_val)
	_cohort_history[cohort_key] = bucket


func _record_good_history(good_id: String, price_val: float, price_index: float,
		stock_units: float, shortage_ratio: float) -> void:
	var bucket: Dictionary = _good_history.get(good_id, {})
	_append_history_sample(bucket, "price", price_val)
	_append_history_sample(bucket, "price_index", price_index)
	_append_history_sample(bucket, "stock", stock_units)
	_append_history_sample(bucket, "shortage", shortage_ratio)
	_good_history[good_id] = bucket


func _record_building_history(building_key: String, profit_val: float,
		utilization_ratio: float) -> void:
	var bucket: Dictionary = _building_history.get(building_key, {})
	_append_history_sample(bucket, "profit", profit_val)
	_append_history_sample(bucket, "utilization", utilization_ratio)
	_building_history[building_key] = bucket


func _compute_cell_avg_satisfaction_dims(populations: PackedInt64Array,
		dims: PackedInt32Array, dimension_count: int) -> PackedFloat32Array:
	var avg := PackedFloat32Array()
	if dimension_count <= 0 or populations.is_empty():
		return avg
	avg.resize(dimension_count)
	var dim_pop := PackedInt64Array()
	dim_pop.resize(dimension_count)
	for i in range(populations.size()):
		var pop := maxi(0, int(populations[i]))
		var begin := i * dimension_count
		if pop <= 0 or begin < 0 or begin + dimension_count > dims.size():
			continue
		for d in range(dimension_count):
			if dims[begin + d] >= 0:
				avg[d] += (float(dims[begin + d]) / 65536.0) * float(pop)
				dim_pop[d] += pop
	for d in range(dimension_count):
		avg[d] = clampf(avg[d] / float(dim_pop[d]), 0.0, 1.0) if dim_pop[d] > 0 else -1.0
	return avg


func _cohort_satisfaction_dims_float(dims: PackedInt32Array, dimension_count: int,
		cohort_idx: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if dimension_count <= 0:
		return out
	var begin := cohort_idx * dimension_count
	if begin < 0 or begin + dimension_count > dims.size():
		return out
	out.resize(dimension_count)
	for d in range(dimension_count):
		out[d] = clampf(float(dims[begin + d]) / 65536.0, 0.0, 1.0) if dims[begin + d] >= 0 else -1.0
	return out


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
const SATISFACTION_DIMENSION_EXPLANATIONS := [
	"热量与御寒的生理满足率；不足会限制综合满意度。",
	"基本生活实际消费相对生活目标的满足率；目标不随本轮预算和物价缩减。",
	"实际享受到的舒适消费相对生活目标的满足率；存款不直接加分。",
	"实际享受到的奢侈与身份消费相对生活目标的满足率；存款不直接加分。",
	"近期收入相对长期收入基线的变化。",
	"剩余存款可支撑的基础生活月数；六个月达到满分。",
	"本期净税负相对毛收入的压力，税负越轻分数越高。",
	"本地聚落等级、国家技术进度和建成产业种类。",
]

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
		var applicable := dims[begin + dimension] >= 0
		var value := float(dims[begin + dimension]) / 65536.0
		var is_worst := applicable and dimension == worst_dimension
		rows.append({
			"id": "satisfaction_dim_%d" % dimension,
			"name": _satisfaction_dimension_name(dimension),
			"value": "%.1f%%" % (value * 100.0) if applicable else "不适用",
			"applicable": applicable,
			"tooltip": String(SATISFACTION_DIMENSION_EXPLANATIONS[dimension]) if applicable else "当前阶层尚无此档已解锁的生活需求；不参与综合满意度。",
			"accent": UITokens.DOSSIER_INK_MUTED if not applicable else (UITokens.RISK if is_worst else _satisfaction_accent(value)),
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
	if _snapshot_pending(snapshot):
		return _pending_category()
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
	var reference_ceiling: PackedInt32Array = snapshot.get("price_reference_ceiling", PackedInt32Array())
	var base_ceiling: PackedInt32Array = snapshot.get("price_base_ceiling", PackedInt32Array())
	var effective_ceiling: PackedInt32Array = snapshot.get("price_effective_ceiling", PackedInt32Array())
	var target_ceiling: PackedInt32Array = snapshot.get("price_target_ceiling", PackedInt32Array())
	var confirmation_days: PackedInt32Array = snapshot.get("price_ceiling_confirmation_days", PackedInt32Array())
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
	var sample_day := int(snapshot.get("sample_day", _current_sample_day()))
	if market_id >= 0:
		_ensure_detail_history_cell(market_id)
	var should_sample_market := market_id >= 0 and sample_day >= 0 \
		and sample_day != _detail_history_market_day
	if should_sample_market:
		_detail_history_market_day = sample_day
	var in_transit_kinds := 0
	for i in range(good_ids.size()):
		if enforce_technology and technology_available[i] == 0:
			continue
		var stable_id := String(good_ids[i])
		var profile = GoodProfileRegistry.profile_by_id(stable_id)
		var display_name := String(profile.display_name) if profile != null else stable_id
		var stock_raw := int(stock[i]) if i < stock.size() else 0
		var stock_units := float(stock_raw) / 1000.0
		var price_raw := int(prices[i]) if i < prices.size() else 0
		var price_val := float(price_raw) / 10000.0
		var anchor_raw := int(cost_anchor[i]) if i < cost_anchor.size() else 0
		var anchor_val := float(anchor_raw) / 10000.0
		var price_index := float(price_raw) / float(anchor_raw) if anchor_raw > 0 else 1.0
		var hh_demand_units := float(demand_ema[i]) / 1000.0 if i < demand_ema.size() else 0.0
		var biz_demand_units := float(business_demand_ema[i]) / 1000.0 if i < business_demand_ema.size() else 0.0
		var total_demand_units := hh_demand_units + biz_demand_units
		var supply_units := float(offered_supply_ema[i]) / 1000.0 if i < offered_supply_ema.size() else 0.0
		var stock_daily := _sample_daily_delta(_market_prev_stock,
			"%d:%s" % [market_id, stable_id], stock_units, sample_day)
		var shortage := float(shortage_q16[i]) * 100.0 / 65536.0 if i < shortage_q16.size() else 0.0
		var allow_trade := _market_trade_enabled(trade_enabled, i)
		var inbound := _packed_i64_at(trade_inbound, i) if allow_trade else 0
		var outbound := _packed_i64_at(trade_outbound, i) if allow_trade else 0
		var import_flow := _packed_i64_at(trade_import_ema, i) if allow_trade else 0
		var export_flow := _packed_i64_at(trade_export_ema, i) if allow_trade else 0
		var inbound_units := float(inbound) / 1000.0
		var outbound_units := float(outbound) / 1000.0
		var import_flow_units := float(import_flow) / 1000.0
		var export_flow_units := float(export_flow) / 1000.0
		var in_transit := inbound > 0 or outbound > 0
		if in_transit:
			in_transit_kinds += 1
		if should_sample_market:
			_record_good_history(stable_id, price_val, price_index, stock_units, shortage / 100.0)
		var good_hist: Dictionary = _good_history.get(stable_id, {})
		var price_series: PackedFloat32Array = good_hist.get("price", PackedFloat32Array())
		var stock_series: PackedFloat32Array = good_hist.get("stock", PackedFloat32Array())
		var stock_plain := _goods_unit_text(stock_raw)
		var anchor_text := _money_text(anchor_raw) if anchor_raw > 0 else "—"
		var days_of_stock := stock_units / total_demand_units if total_demand_units > 0.001 \
			else (999.0 if stock_units > 0.001 else 0.0)
		var detail_rows := [
			{"id": "household_demand", "name": "居民需求", "value": UITokens.format_compact_number_cn(hh_demand_units, 2)},
			{"id": "business_demand", "name": "产业需求", "value": UITokens.format_compact_number_cn(biz_demand_units, 2)},
			{"id": "supply", "name": "供给", "value": UITokens.format_compact_number_cn(supply_units, 2)},
			{"id": "cost_anchor", "name": "成本锚", "value": anchor_text},
			{"id": "price_index", "name": "价格倍率", "value": "%.2f 倍" % price_index if anchor_raw > 0 else "—"},
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
			"stock_units_float": stock_units,
			"days_of_stock_float": days_of_stock,
			"price": _money_text(price_raw),
			"price_float": price_val,
			"cost_anchor_text": anchor_text,
			"cost_anchor_float": anchor_val,
			"price_index_float": price_index,
			"household_demand_float": hh_demand_units,
			"business_demand_float": biz_demand_units,
			"supply_float": supply_units,
			"shortage_float": shortage / 100.0,
			"inbound_float": inbound_units,
			"outbound_float": outbound_units,
			"import_flow_float": import_flow_units,
			"export_flow_float": export_flow_units,
			"price_spark": price_series,
			"price_delta": _series_lookback_delta(price_series),
			"stock_spark": stock_series,
			"stock_delta": stock_daily,
			"delta": _daily_delta_text(stock_daily),
			"risk": "短缺" if shortage >= 25.0 else "",
			"trade_inbound": _goods_unit_text(inbound) if inbound > 0 else "",
			"trade_outbound": _goods_unit_text(outbound) if outbound > 0 else "",
			"detail_rows": detail_rows,
			"accent": UITokens.RISK if shortage >= 25.0 else UITokens.RESOURCE,
			"icon": GoodProfileRegistry.icon_key(stable_id),
			"visible": true,
			"_rank": (0 if shortage >= 25.0 else (1 if in_transit else (
				2 if i < stock.size() and stock[i] > 0 else 3))) * 100000 + rows.size(),
		})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["_rank"]) < int(b["_rank"]))
	for row_value in rows:
		(row_value as Dictionary).erase("_rank")
	var trade_net := int(snapshot.get("merchant_trade_sale_cash", 0)) \
		- int(snapshot.get("merchant_trade_purchase_cash", 0))
	var arrival_days := _trade_arrival_days(
		int(snapshot.get("trade_next_arrival_day", -1)), sample_day)
	var market_insights := []
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
			{"id": "merchant_cash", "title": "商家现金", "value": _money_text(int(snapshot.get("merchant_cash", 0))), "subtitle": "", "accent": UITokens.ACCENT, "icon": "resource"},
			{"id": "merchant_trade_net", "title": "贸易净额", "value": _money_text(trade_net), "subtitle": "", "accent": UITokens.ACCENT if trade_net == 0 else (UITokens.GOOD if trade_net > 0 else UITokens.RISK), "icon": "resource"},
		],
		"sections": [{
			"id": "merchant_accounts",
			"title": "商家账目",
			"icon": "resource",
			"accent": UITokens.RESOURCE,
			"collapsed": true,
			"metrics": [
				{"id": "merchant_inventory_liquidation", "title": "库存估值", "value": _money_text(int(snapshot.get("merchant_inventory_liquidation_value", 0))), "subtitle": "", "tooltip": "按零售价估算的库存价值。", "accent": UITokens.RESOURCE, "icon": "resource"},
				{"id": "merchant_assets", "title": "商业资产", "value": _money_text(int(snapshot.get("merchant_economic_assets", 0))), "subtitle": "", "tooltip": "现金加库存估值。", "accent": UITokens.GOOD, "icon": "resource"},
				{"id": "merchant_coverage", "title": "周转覆盖", "value": "%.1f 期" % (float(snapshot.get("merchant_liquidity_coverage_q16", 65536)) / 65536.0), "subtitle": "", "tooltip": "现金可支撑的经营期数。", "accent": UITokens.ACCENT, "icon": "resource"},
				{"id": "merchant_margin", "title": "采购毛利", "value": _money_text(int(snapshot.get("merchant_procurement_margin_value", 0))), "subtitle": "", "accent": UITokens.GOOD, "icon": "resource"},
			],
		}],
		"market_rows": rows,
		"list_header": {"lead": "商品 · 库存", "indent": 39.0, "columns": [
			{"text": "价格", "width": 84.0}]},
		# 物资详情逐单商路用：订单页只会在 committed generation 变化后失效。
		"economy_generation": int(snapshot.get("economy_generation", -1)),
		"sample_day": sample_day,
	}


# ─── 物资详情 · 逐单商路 ──────────────────────────────────────────────────
# 对象详情打开后按需查询；页缓存按 committed generation，行缓存再叠加
# sample_day 与视野 revision，因此日 tick / 200ms live patch 不会重复查询原生。
# 对端名称只为 FOG_VISIBLE 的格子读取；不可见对端在本层遮蔽，不查询名称。

func trade_orders_model(cell_idx: int, good_id: String, offset: int = 0,
		limit: int = TRADE_ORDER_PAGE_SIZE, generation: int = -1,
		sample_day: int = -1) -> Dictionary:
	if _map == null or cell_idx < 0:
		return _trade_orders_failure("此地暂无可读贸易流水。", "trade_orders_map_unavailable")
	if VisionSolver.fog_state(_map, cell_idx) != VisionSolver.FOG_VISIBLE:
		return _trade_orders_failure("此地不在当前视野内。", "cell_not_visible")
	var facade = _economy_facade()
	if facade == null or not facade.has_method("trade_orders_for_cell"):
		return _trade_orders_failure("贸易数据暂不可用。", "trade_order_api_unavailable")
	var good_index := _trade_order_good_index(facade, good_id)
	if good_index < 0:
		return _trade_orders_failure("物资不在当前目录中。", "unknown_good")
	var page_limit := clampi(limit, 1, 64)
	var page_offset := maxi(0, offset)
	var resolved_sample_day := sample_day if sample_day >= 0 else _current_sample_day()
	if generation >= 0 and generation != _trade_order_generation:
		_trade_order_generation = generation
		_trade_order_pages.clear()
		_trade_order_models.clear()
		_trade_order_names.clear()
	if generation >= 0:
		var page_key := _trade_order_page_key(
			cell_idx, good_index, generation, page_offset, page_limit)
		var page: Dictionary = _trade_order_pages.get(page_key, {})
		if page.is_empty():
			page = _query_trade_order_page(
				facade, cell_idx, good_index, page_offset, page_limit)
			if bool(page.get("pending", false)):
				return _trade_orders_pending_model(
					page, page_offset, page_limit, resolved_sample_day, generation)
			if not bool(page.get("ok", false)):
				return _trade_orders_failure("贸易流水暂不可用。",
					String(page.get("reason", "trade_order_query_failed")))
			_trade_order_pages[page_key] = page
			_trim_dictionary(_trade_order_pages, TRADE_ORDER_PAGE_CACHE_LIMIT)
			# 总数缩小导致请求 offset 越界时，把原生钳制后的末页别名回请求 key，
			# 避免之后每次刷新都重新查询一次。
			var effective := int(page.get("page_begin", page_offset))
			if effective != page_offset:
				_trade_order_pages[_trade_order_page_key(
					cell_idx, good_index, generation, effective, page_limit)] = page
		var model_key := "%s|%d|%d" % [page_key, resolved_sample_day,
			int(_map.vision_revision)]
		var cached_model: Dictionary = _trade_order_models.get(model_key, {})
		if not cached_model.is_empty():
			return cached_model
		var built := _build_trade_orders_model(page, resolved_sample_day, generation)
		_trade_order_models[model_key] = built
		_trim_dictionary(_trade_order_models, TRADE_ORDER_MODEL_CACHE_LIMIT)
		return built
	# generation 缺失只可能出现在旧桥/异常路径：退化为每次有界查询，不保留页缓存。
	var uncached_page := _query_trade_order_page(
		facade, cell_idx, good_index, page_offset, page_limit)
	if bool(uncached_page.get("pending", false)):
		return _trade_orders_pending_model(
			uncached_page, page_offset, page_limit, resolved_sample_day, generation)
	if not bool(uncached_page.get("ok", false)):
		return _trade_orders_failure("贸易流水暂不可用。",
			String(uncached_page.get("reason", "trade_order_query_failed")))
	return _build_trade_orders_model(
		uncached_page, resolved_sample_day, generation)


func _trade_order_page_key(cell_idx: int, good_index: int, generation: int,
		offset: int, limit: int) -> String:
	return "%d|%d|%d|%d|%d" % [cell_idx, good_index, generation, offset, limit]


func _query_trade_order_page(facade, cell_idx: int, good_index: int,
		offset: int, limit: int) -> Dictionary:
	var page: Dictionary = facade.trade_orders_for_cell(
		cell_idx, offset, limit, good_index)
	_trade_order_query_count += 1
	if _snapshot_pending(page) or String(page.get("reason", "")) == "economy_read_view_pending":
		page["pending"] = true
	return page


func _trade_order_good_index(facade, good_id: String) -> int:
	var stable_id := good_id.strip_edges()
	if stable_id.is_empty():
		return -1
	if _trade_order_good_indices.is_empty():
		var ids: PackedStringArray = facade.good_ids() \
			if facade.has_method("good_ids") else PackedStringArray()
		for index in range(ids.size()):
			_trade_order_good_indices[String(ids[index])] = index
	return int(_trade_order_good_indices.get(stable_id, -1))


func _economy_facade():
	if _generator == null or not _generator.has_method("get_economy_facade"):
		return null
	return _generator.get_economy_facade()


func _trade_orders_failure(text: String, reason: String) -> Dictionary:
	return {"ok": false, "pending": false, "reason": reason,
		"rows": [], "rows_by_id": {}, "total": 0, "offset": 0,
		"limit": TRADE_ORDER_PAGE_SIZE, "has_more": false,
		"page_label": "", "hint": text, "empty_text": text,
		"signature": "", "sample_day": -1, "economy_generation": -1}


func _trade_orders_pending_model(page: Dictionary, offset: int, limit: int,
		sample_day: int, generation: int) -> Dictionary:
	return {"ok": false, "pending": true,
		"reason": String(page.get("reason", "economy_read_view_pending")),
		"rows": [], "rows_by_id": {}, "total": 0, "offset": offset,
		"limit": limit, "has_more": false, "page_label": "",
		"hint": "经济结算中，沿用上次结果。",
		"empty_text": "经济结算中，暂无可读订单。",
		"signature": "", "sample_day": sample_day,
		"economy_generation": generation}


static func _trim_dictionary(cache: Dictionary, limit: int) -> void:
	while cache.size() > limit:
		cache.erase(cache.keys()[0])


func _build_trade_orders_model(page: Dictionary,
		sample_day: int, generation: int) -> Dictionary:
	# 倒计时按 UI 当前世界日计算：订单页的 native sample_day 是上一次 committed
	# 边界，若拿它当“今天”，快进期间剩余天数会一直卡住。generation 只用于缓存。
	var day := sample_day
	if day < 0:
		day = _current_sample_day()
	var order_ids: PackedInt64Array = page.get("order_ids", PackedInt64Array())
	var directions: PackedInt32Array = page.get("directions", PackedInt32Array())
	var sources: PackedInt32Array = page.get("source_cells", PackedInt32Array())
	var destinations: PackedInt32Array = page.get(
		"destination_cells", PackedInt32Array())
	var departure_days: PackedInt64Array = page.get(
		"departure_days", PackedInt64Array())
	var arrival_days: PackedInt64Array = page.get(
		"arrival_days", PackedInt64Array())
	var cash_escrows: PackedInt64Array = page.get(
		"cash_escrow", PackedInt64Array())
	var capacity_works: PackedInt64Array = page.get(
		"capacity_work", PackedInt64Array())
	var cargo_delivered: PackedByteArray = page.get(
		"cargo_delivered", PackedByteArray())
	var order_flags: PackedByteArray = page.get("order_flags", PackedByteArray())
	var line_offsets: PackedInt32Array = page.get("line_offsets", PackedInt32Array())
	var line_quantities: PackedInt64Array = page.get(
		"line_quantities", PackedInt64Array())
	var line_unit_prices: PackedInt32Array = page.get(
		"line_unit_prices", PackedInt32Array())
	var line_destination_prices: PackedInt32Array = page.get(
		"line_destination_prices", PackedInt32Array())
	var line_base_values: PackedInt64Array = page.get(
		"line_base_values", PackedInt64Array())
	var rows: Array = []
	var rows_by_id: Dictionary = {}
	var page_units := 0
	var waiting_receivers := 0
	var first_arrival := -1
	for i in range(order_ids.size()):
		var order_id := int(order_ids[i])
		var direction := int(directions[i]) if i < directions.size() else 0
		var source_cell := int(sources[i]) if i < sources.size() else -1
		var destination_cell := int(destinations[i]) if i < destinations.size() else -1
		var counterpart := source_cell if direction > 0 else destination_cell
		var departure := int(departure_days[i]) if i < departure_days.size() else day
		var arrival := int(arrival_days[i]) if i < arrival_days.size() else day
		var line_begin := int(line_offsets[i]) if i < line_offsets.size() else 0
		var line_end := int(line_offsets[i + 1]) if i + 1 < line_offsets.size() \
			else line_begin
		var quantity := 0
		var base_value := 0
		var source_price := 0
		var destination_price := 0
		for line in range(line_begin, line_end):
			quantity += int(line_quantities[line]) if line < line_quantities.size() else 0
			base_value += int(line_base_values[line]) if line < line_base_values.size() else 0
			if line < line_unit_prices.size() and source_price <= 0:
				source_price = int(line_unit_prices[line])
			if line < line_destination_prices.size() and destination_price <= 0:
				destination_price = int(line_destination_prices[line])
		var delivered := int(cargo_delivered[i]) if i < cargo_delivered.size() else 0
		var flags := int(order_flags[i]) if i < order_flags.size() else 0
		var counterpart_visible: bool = counterpart >= 0 and VisionSolver.fog_state(
			_map, counterpart) == VisionSolver.FOG_VISIBLE
		var counterpart_name := "视野外"
		var counterpart_sub := ""
		if counterpart_visible:
			counterpart_name = _trade_counterpart_name(counterpart)
			var coord := _trade_counterpart_coord(counterpart)
			if counterpart_name.is_empty():
				counterpart_name = coord
			elif not coord.is_empty():
				counterpart_sub = coord
			if (flags & 1) != 0:
				counterpart_sub = "跨国" if counterpart_sub.is_empty() \
					else "跨国 · %s" % counterpart_sub
		var remaining := maxi(0, arrival - day)
		var span := maxi(1, arrival - departure)
		var progress := clampf(float(day - departure) / float(span), 0.0, 1.0)
		var route_text := "今日到达" if remaining <= 0 else "剩 %d 日" % remaining
		var status_text := "待收款" if delivered != 0 else "在途"
		if delivered != 0:
			waiting_receivers += 1
		var price_text := "—"
		if counterpart_visible and source_price > 0 and destination_price > 0:
			price_text = "%s → %s" % [
				_money_text(source_price), _money_text(destination_price)]
		page_units += quantity
		if first_arrival < 0 or arrival < first_arrival:
			first_arrival = arrival
		var escrow := int(cash_escrows[i]) if i < cash_escrows.size() else 0
		var capacity := int(capacity_works[i]) if i < capacity_works.size() else 0
		var row_id := "trade_order_%d" % order_id
		var row := {
			"id": row_id,
			"tooltip": _trade_order_tooltip(order_id, direction, counterpart_name,
				counterpart_visible, quantity, source_price, destination_price,
				base_value, escrow, capacity, departure, arrival, remaining,
				delivered, flags),
			"muted": delivered != 0,
			"locate_cell": counterpart if counterpart_visible else -1,
			"cells": {
				"dir": {"text": "运入" if direction > 0 else "运出",
					"color": UITokens.DOSSIER_VERDIGRIS if direction > 0
						else UITokens.DOSSIER_OXBLOOD},
				"counterpart": {"text": counterpart_name,
					"sub": counterpart_sub},
				"quantity": {"text": _goods_unit_text(quantity),
					"value": float(quantity) / 1000.0, "sort": quantity},
				"price": {"text": price_text,
					"sort": destination_price if counterpart_visible else 0},
				"route": {"text": route_text, "value": progress,
					"sort": remaining,
					"bar_color": UITokens.DOSSIER_BRASS if remaining > 0
						else UITokens.DOSSIER_VERDIGRIS},
				"status": {"text": status_text,
					"color": UITokens.DOSSIER_INK_MUTED if delivered != 0
						else UITokens.DOSSIER_BRASS},
			},
		}
		rows.append(row)
		rows_by_id[row_id] = row
	var total := int(page.get("total", rows.size()))
	var page_begin := int(page.get("page_begin", 0))
	var page_label := ""
	if total > rows.size() or page_begin > 0:
		page_label = "%d-%d / %d" % [
			page_begin + 1, page_begin + rows.size(), total]
	var page_text := "%d 笔 · %s 单位" % [rows.size(),
		UITokens.format_compact_number_cn(float(page_units) / 1000.0, 2)]
	if waiting_receivers > 0:
		page_text += " · 待收款 %d 笔" % waiting_receivers
	if first_arrival >= 0 and not rows.is_empty():
		page_text += " · 最近到达 第 %d 天" % (first_arrival + 1)
	var ids := PackedStringArray()
	for value in order_ids:
		ids.append(str(int(value)))
	return {
		"ok": true,
		"pending": false,
		"reason": "",
		"rows": rows,
		"rows_by_id": rows_by_id,
		"total": total,
		"offset": page_begin,
		"limit": int(page.get("limit", rows.size())),
		"has_more": bool(page.get("has_more", false)),
		"page_label": page_label,
		"hint": page_text,
		"empty_text": "本地目前没有该物资的在途商队。",
		"signature": "%d|%d|%d|%d|%d|%s" % [generation, day, page_begin,
			total, int(_map.vision_revision), ",".join(ids)],
		"sample_day": day,
		"economy_generation": generation,
	}


func _trade_counterpart_name(cell_idx: int) -> String:
	if _trade_order_names.has(cell_idx):
		return String(_trade_order_names[cell_idx])
	var summary := _population_summary(cell_idx)
	if not bool(summary.get("ok", false)):
		return ""
	var name := String(summary.get("settlement_name", "")).strip_edges()
	if _trade_order_names.size() > TRADE_ORDER_NAME_CACHE_LIMIT:
		_trade_order_names.clear()
	_trade_order_names[cell_idx] = name
	return name


func _trade_counterpart_coord(cell_idx: int) -> String:
	var cell: HexCell = _map.cell_at(cell_idx) if _map != null else null
	if cell == null:
		return "地块 %d" % (cell_idx + 1)
	var off := HexUtils.cube_to_offset(cell.q, cell.r)
	return "区域 %d, %d" % [off.x + 1, off.y + 1]


func _trade_order_tooltip(order_id: int, direction: int, counterpart_name: String,
		counterpart_visible: bool, quantity: int, source_price: int,
		destination_price: int, base_value: int, escrow: int, capacity: int,
		departure: int, arrival: int, remaining: int, delivered: int,
		flags: int) -> String:
	var lines := PackedStringArray()
	lines.append("订单 #%d · %s" % [order_id,
		"运入" if direction > 0 else "运出"])
	if counterpart_visible:
		lines.append("对端：%s" % counterpart_name)
	else:
		lines.append("对端：视野外（仅显示本地订单事实）")
	lines.append("货物：%s · 货值 %s" % [
		_goods_unit_text(quantity), _money_text(base_value)])
	if counterpart_visible and source_price > 0 and destination_price > 0:
		lines.append("单价：%s → %s" % [
			_money_text(source_price), _money_text(destination_price)])
	lines.append("出发 第 %d 天 → 到达 第 %d 天（%s）" % [
		departure + 1, arrival + 1,
		"今日到达" if remaining <= 0 else "剩余 %d 日" % remaining])
	lines.append("托管现金 %s · 运力 %s" % [
		_money_text(escrow),
		UITokens.format_compact_number_cn(float(capacity), 1)])
	if delivered != 0:
		lines.append("货物已交付，卖方现金待收款。")
	var notes := PackedStringArray()
	if (flags & 1) != 0:
		notes.append("跨国贸易")
	if (flags & 2) != 0:
		notes.append("救济运输")
	if (flags & 4) != 0:
		notes.append("进口补贴")
	if (flags & 8) != 0:
		notes.append("出口补贴")
	if (flags & 16) != 0:
		notes.append("进口税")
	if (flags & 32) != 0:
		notes.append("出口税")
	if not notes.is_empty():
		lines.append(" · ".join(notes))
	return "\n".join(lines)


func _building_category(snapshot: Dictionary, cell_idx: int = -1) -> Dictionary:
	if _snapshot_pending(snapshot):
		return _pending_category()
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
	var last_business_tax: PackedInt64Array = snapshot.get(
		"last_business_tax_paid", PackedInt64Array())
	var last_business_subsidy: PackedInt64Array = snapshot.get(
		"last_business_subsidy_received", PackedInt64Array())
	var last_input_cost: PackedInt64Array = snapshot.get("last_input_cost", PackedInt64Array())
	var last_wages: PackedInt64Array = snapshot.get("last_wages_paid", PackedInt64Array())
	var last_wages_due: PackedInt64Array = snapshot.get("last_wages_due", PackedInt64Array())
	var last_operating_cost: PackedInt64Array = snapshot.get("last_operating_cost", PackedInt64Array())
	var last_in_kind: PackedInt64Array = snapshot.get(
		"last_in_kind_livelihood_value", PackedInt64Array())
	var opportunity_owner_income: PackedInt64Array = snapshot.get(
		"opportunity_owner_income_per_day", PackedInt64Array())
	var opportunity_capacity: PackedInt64Array = snapshot.get(
		"opportunity_executable_capacity_q16", PackedInt64Array())
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
	var bld_sample_day := int(snapshot.get("sample_day", _current_sample_day()))
	if cell_idx >= 0:
		_ensure_detail_history_cell(cell_idx)
	var should_sample_bld := cell_idx >= 0 and bld_sample_day >= 0 \
		and bld_sample_day != _detail_history_building_day
	if should_sample_bld:
		_detail_history_building_day = bld_sample_day
	var total_profit := 0
	var halted_groups := 0
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
		# In-kind owner retention is part of the same economic income as cash
		# receipts. A self-consuming producer must not be shown as loss-making
		# merely because it has no merchant sale.
		var in_kind_income := int(last_in_kind[i]) if i < last_in_kind.size() else 0
		var profit := revenue + in_kind_income - operating_cost
		var business_tax := int(last_business_tax[i]) \
			if i < last_business_tax.size() else 0
		var business_subsidy := int(last_business_subsidy[i]) \
			if i < last_business_subsidy.size() else 0
		var owner_physical_capacity := int(owner_capacity[i]) if i < owner_capacity.size() else \
			(count * int(owner_slots[type_idx]) if type_idx >= 0 and type_idx < owner_slots.size() else count)
		var owner_required := int(owner_required_by_group[i]) if i < owner_required_by_group.size() else 0
		if i >= owner_required_by_group.size():
			owner_required = owner_physical_capacity
		var owner_actual := int(filled_owner[i]) if i < filled_owner.size() else 0
		var owner_open := int(owner_openings[i]) if i < owner_openings.size() else maxi(0, owner_required - owner_actual)
		var operating_state := int(operating_states[i]) if i < operating_states.size() else 0
		var opportunity_income := int(opportunity_owner_income[i]) \
			if i < opportunity_owner_income.size() else 0
		var opportunity_capacity_value := int(opportunity_capacity[i]) \
			if i < opportunity_capacity.size() else 0
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
		var has_outputs := production_rows.size() != output_row_begin
		if not has_outputs:
			production_rows.append({"id": "output_none", "name": "产出", "value": "无", "icon": "resource", "accent": UITokens.TEXT_MUTED})
		var has_climate_profile := type_idx >= 0 \
			and type_idx < building_climate_profiles.size() \
			and int(building_climate_profiles[type_idx]) >= 0
		var temp_fit := 100.0
		var water_fit := 100.0
		var climate_capacity := 100.0
		var climate_lost_daily_text := ""
		if has_climate_profile:
			temp_fit = float(temperature_fit_q16[i]) * 100.0 / 65536.0 \
				if i < temperature_fit_q16.size() else 100.0
			water_fit = float(water_fit_q16[i]) * 100.0 / 65536.0 \
				if i < water_fit_q16.size() else 100.0
			climate_capacity = float(climate_capacity_q16[i]) * 100.0 / 65536.0 \
				if i < climate_capacity_q16.size() else 100.0
			production_rows.append({"id": "climate_fit", "name": "气候适宜度",
				"value": "温度 %.1f%% · 水分 %.1f%% · 能力 %.1f%%" % [
					temp_fit, water_fit, climate_capacity], "icon": "climate",
				"accent": UITokens.GOOD if climate_capacity >= 99.9 else UITokens.WARN})
			var lost_output := int(climate_lost_output[i]) \
				if i < climate_lost_output.size() else 0
			if lost_output > 0:
				climate_lost_daily_text = _actual_daily_rate(lost_output, count, period_days)
				production_rows.append({"id": "climate_lost_output", "name": "气候减产",
					"value": climate_lost_daily_text,
					"icon": "warning", "accent": UITokens.WARN})
		var finance_breakdown := "现金 %s · 自用折算 %s · 原料 %s · 工资 %s · 营业税 %s" % [
			_money_text(revenue), _money_text(in_kind_income), _money_text(input_cost),
			_money_text(wages), _money_text(business_tax)]
		if business_subsidy > 0:
			finance_breakdown += " · 经营补贴 %s" % _money_text(business_subsidy)
		var finance := {
			"revenue": _money_text(revenue + in_kind_income),
			"revenue_float": float(revenue + in_kind_income) / 10000.0,
			"cash_revenue_float": float(revenue) / 10000.0,
			"cash_revenue_text": _money_text(revenue),
			"in_kind_float": float(in_kind_income) / 10000.0,
			"in_kind_text": _money_text(in_kind_income),
			"subsidy_float": float(business_subsidy) / 10000.0,
			"subsidy_text": _money_text(business_subsidy),
			"cost": _money_text(operating_cost),
			"cost_float": float(operating_cost) / 10000.0,
			"input_cost_float": float(input_cost) / 10000.0,
			"input_cost_text": _money_text(input_cost),
			"wages_paid_float": float(wages) / 10000.0,
			"wages_paid_text": _money_text(wages),
			"business_tax_float": float(business_tax) / 10000.0,
			"business_tax_text": _money_text(business_tax),
			"profit": "%s%s" % ["+" if profit > 0 else "", _money_text(profit)],
			"profit_float": float(profit) / 10000.0,
			"profit_positive": profit >= 0,
			"breakdown": finance_breakdown,
			"revenue_label": "税后总收入（含自用）",
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
				status_parts.append("缺业主 %d" % owner_open)
			status_parts.append("产能 %.0f%%" % actual_percent)
			if has_outputs and planned_percent < 99.5:
				status_parts.append("限产 %.0f%%" % planned_percent)
			state_label = " · ".join(status_parts)
		var pending_state := int(pending_operating_states[i]) \
			if i < pending_operating_states.size() else 255
		if pending_state == 0 and operating_state != 0:
			state_meta += (" · " if not state_meta.is_empty() else "") + "下期恢复正常经营"
		elif pending_state == 1 and operating_state != 1:
			state_meta += (" · " if not state_meta.is_empty() else "") + "下期转入亏损停产"
		var headline_profit_label := "利润" if profit >= 0 else "亏损"
		var headline_profit := "%s%s" % ["+" if profit > 0 else "", _money_text(profit)]
		# A vacant but executable owner-operated group has no realized cash flow
		# yet. Do not present that zero settlement as an already-realized loss;
		# expose the read-only opportunity quote until an owner is attached.
		if owner_actual == 0 and opportunity_capacity_value > 0:
			headline_profit_label = "机会收益"
			headline_profit = "%s%s" % ["+" if opportunity_income > 0 else "",
				_money_text(opportunity_income)]
		if is_loss_suspended:
			headline_profit_label = "状态"
			headline_profit = "停产"
		elif not is_available:
			headline_profit_label = "状态"
			headline_profit = "停用"
		if is_loss_suspended:
			finance.warning = "停产中 · 利润率取自上一经营期"
		var bld_hist_key := "%d|%d" % [type_idx, int(owner_signatures[i]) if i < owner_signatures.size() else i]
		if should_sample_bld:
			_record_building_history(bld_hist_key, float(profit) / 10000.0,
				clampf(actual_percent / 100.0, 0.0, 1.0))
		var bld_hist: Dictionary = _building_history.get(bld_hist_key, {})
		var profit_series: PackedFloat32Array = bld_hist.get("profit", PackedFloat32Array())
		var util_series: PackedFloat32Array = bld_hist.get("utilization", PackedFloat32Array())
		rows.append({
			"id": "building_%d_%d" % [type_idx, i],
			"name": String(type_names[type_idx]) if type_idx >= 0 and type_idx < type_names.size() else (String(type_ids[type_idx]) if type_idx >= 0 and type_idx < type_ids.size() else "建筑"),
			"building_type_id": building_id,
			"count": "%d 栋" % count,
			"count_raw": count,
			"owner": "业主 · %s" % _owner_profession_name(snapshot, int(owner_signatures[i]) if i < owner_signatures.size() else -1),
			"status": state_label,
			"staffing_actual_raw": staffing_actual,
			"staffing_required_raw": staffing_required,
			"actual_utilization_float": clampf(actual_percent / 100.0, 0.0, 1.0),
			"planned_utilization_float": clampf(planned_percent / 100.0, 0.0, 1.0),
			"has_climate_profile": has_climate_profile,
			"temperature_fit_float": clampf(temp_fit / 100.0, 0.0, 1.0),
			"water_fit_float": clampf(water_fit / 100.0, 0.0, 1.0),
			"climate_capacity_float": clampf(climate_capacity / 100.0, 0.0, 1.0),
			"climate_lost_daily_text": climate_lost_daily_text,
			"state_summary": {"label": state_label, "detail": state_detail,
				"meta": state_meta, "accent": state_accent,
				"icon": "warning"} \
				if show_state_summary else {},
			"profit": headline_profit,
			"profit_float": float(profit) / 10000.0,
			"profit_label": headline_profit_label,
			"profit_spark": profit_series,
			"profit_delta": _series_lookback_delta(profit_series),
			"utilization_spark": util_series,
			"utilization_delta": _series_lookback_delta(util_series),
			"accent": state_accent if show_state_summary else (UITokens.GOOD if profit > 0 else (UITokens.RISK if profit < 0 else UITokens.TEXT_MUTED)),
			"icon": _building_icon(building_id, snapshot, type_idx), "job_rows": job_rows,
			"production_rows": production_rows, "finance": finance, "visible": true,
		})
		total_profit += profit
		if show_state_summary:
			halted_groups += 1
	_append_construction_rows(rows, snapshot, type_ids, type_names)
	var total_count := _sum_i64(snapshot.get("building_counts_by_type", PackedInt64Array()))
	var metrics := [{"id": "building_total", "title": "建筑总数", "value": "%s 栋" % UITokens.format_compact_number_cn(float(total_count), 1), "subtitle": "%d 处停产" % halted_groups if halted_groups > 0 else "", "accent": UITokens.RISK if halted_groups > 0 else UITokens.ACCENT, "icon": "building"}]
	if group_types.size() > 0:
		metrics.append({"id": "building_profit_total", "title": "本期利润", "value": "%s%s" % ["+" if total_profit > 0 else "", _money_text(total_profit)], "subtitle": "", "tooltip": "本期各建筑利润合计，自用产出按市价折算。", "accent": UITokens.GOOD if total_profit >= 0 else UITokens.RISK, "icon": "resource"})
	var category := {
		"insights": [{"id": "buildings_empty", "text": "此地块当前没有建筑。", "accent": UITokens.TEXT_MUTED, "icon": "building"}] if rows.is_empty() else [],
		"metrics": metrics,
		"construction": build_construction_options(cell_idx),
		"building_rows": rows,
	}
	if not rows.is_empty():
		category["list_header"] = {"lead": "建筑 · 业主 · 状况", "indent": 41.0, "columns": [
			{"text": "数量", "width": 44.0}, {"text": "利润", "width": 78.0}]}
	return category


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
	var divisor := maxi(1, building_count) * maxi(1, period_days)
	for cursor in range(begin, end):
		var good_idx := int(good_indices[cursor]) if cursor < good_indices.size() else -1
		var stable_id := String(good_ids[good_idx]) if good_idx >= 0 and good_idx < good_ids.size() else "unknown"
		var quantity := int(quantities[cursor]) if cursor < quantities.size() else 0
		var actual := int(float(actual_total) * float(quantity) / float(recipe_total)) if recipe_total > 0 else 0
		var good_label := _input_candidate_label(
			snapshot, cursor, cursor - begin, group_idx, stable_id) \
			if kind == "input" else _good_display_name(stable_id)
		var short_good := _selected_input_short_label(
			snapshot, cursor, cursor - begin, group_idx, stable_id) \
			if kind == "input" else _good_display_name(stable_id)
		rows.append({
			"id": "%s_%d" % [kind, cursor],
			"name": "%s · %s" % ["原材料" if kind == "input" else "产出", good_label],
			"short_name": "%s · %s" % ["投入" if kind == "input" else "产出", short_good],
			"candidates_detail": good_label if kind == "input" else "",
			"daily_per_building_float": float(actual) / 1000.0 / float(divisor),
			"value": _actual_daily_rate(actual, building_count, period_days),
			"icon": "resource",
			"accent": UITokens.RESOURCE,
		})


func _selected_input_short_label(snapshot: Dictionary, input_idx: int, local_input_idx: int,
		group_idx: int, fallback_id: String) -> String:
	var good_ids: PackedStringArray = snapshot.get("good_ids", PackedStringArray())
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
				return _good_display_name(String(good_ids[selected_good]))
	var offsets: PackedInt32Array = snapshot.get(
		"building_input_candidate_offsets", PackedInt32Array())
	var candidates: PackedInt32Array = snapshot.get(
		"building_input_candidate_good_ids", PackedInt32Array())
	if input_idx >= 0 and input_idx + 1 < offsets.size():
		var first_idx := int(offsets[input_idx])
		var count_cand := int(offsets[input_idx + 1]) - first_idx
		if count_cand > 0 and first_idx >= 0 and first_idx < candidates.size():
			var good_idx := int(candidates[first_idx])
			if good_idx >= 0 and good_idx < good_ids.size():
				var base_name := _good_display_name(String(good_ids[good_idx]))
				return "%s等" % base_name if count_cand > 1 else base_name
	return _good_display_name(fallback_id)


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


func _food_output_metric(snapshot: Dictionary, local_daily: int, effective_daily: int) -> Dictionary:
	var per_person := int(snapshot.get("carrying_survival_food_per_person", 0))
	var metric := {"id": "population_food_output", "title": "本地口粮", "accent": UITokens.ACCENT,
		"icon": "crop", "subtitle": "",
		"tooltip": "本地每日产出的口粮按最低生存口粮折算的可养活人数。"}
	var local_persons := float(snapshot.get("local_food_capacity_persons", -1))
	var effective_persons := float(snapshot.get("effective_food_capacity_persons", -1))
	if local_persons < 0.0 and per_person > 0:
		local_persons = float(local_daily) / float(per_person)
		effective_persons = float(effective_daily) / float(per_person)
	if local_persons < 0.0:
		metric["value"] = "有产出" if local_daily > 0 else "无产出"
		return metric
	metric["value"] = "够 %s 人" % UITokens.format_compact_number_cn(local_persons, 1)
	if effective_persons > local_persons:
		metric["tooltip"] = "%s\n计入输入粮食后可养活 %s 人。" % [metric["tooltip"],
			UITokens.format_compact_number_cn(effective_persons, 1)]
	return metric


func _money_text(subunits: int) -> String:
	if subunits != 0 and absi(subunits) < 100:
		return "%.4f" % (float(subunits) / 10000.0)
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
		"consumption_tax": return "交易税"
		"business_tax": return "营业税"
		"income_subsidy": return "收入补贴"
		"consumption_subsidy": return "消费补贴"
		"business_subsidy": return "经营补贴"
		"fiscal_escrow": return "财政托管"
		_: return "其他收入" if income else "其他支出"


func _has_cashflow_row(rows: Array, source_id: String) -> bool:
	for row_value in rows:
		if row_value is Dictionary and String((row_value as Dictionary).get("id", "")) == \
			("income_" + source_id if String((row_value as Dictionary).get("id", "")).begins_with("income_") else "expense_" + source_id):
			return true
	return false


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


## 悬停卡认矿用：玩家视角、按模拟日缓存。夜里一天只查一次；
## 与经济/科技提交无关的重复悬停不再触发国家快照。
func player_technology_ids() -> PackedStringArray:
	var day := _current_sample_day()
	if day == _technology_day:
		return _technology_ids_cache
	_technology_day = day
	_technology_ids_cache = PackedStringArray()
	if _generator == null or not _generator.has_method("get_country_facade"):
		return _technology_ids_cache
	var viewer := _completed_technology_ids(
		_generator.get_country_facade(), _player_country_handle())
	if bool(viewer.get("ok", false)):
		_technology_ids_cache = viewer.get("technology_ids", PackedStringArray())
	return _technology_ids_cache


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


func _history_values(cell: HexCell) -> Array:
	var values := []
	var hist: Array = cell.vegetation_history if not cell.vegetation_history.is_empty() else cell.biome_history
	for raw in hist:
		values.append(float(raw))
	if values.size() < 2:
		values.append(float(cell.vegetation))
		values.append(float(cell.vegetation))
	return _densify_series(values, 9)


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
		return "—"
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


## 资源丰度 5 档。侧栏与悬停卡共用；返回 1..5 供密度点阵直接使用。
static func resource_density_level(v: float) -> int:
	if v < 0.05: return 1
	if v < 0.25: return 2
	if v < 0.55: return 3
	if v < 0.80: return 4
	return 5


static func resource_density_band(v: float) -> String:
	return ["贫乏", "稀少", "可采", "富集", "丰饶"][resource_density_level(v) - 1]


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


## 温度 8 档。悬停卡与侧栏同源，避免两处阈值各自漂移。
static func temperature_band(t: float) -> String:
	if t < 0.06: return "极寒"
	if t < 0.20: return "严寒"
	if t < 0.30: return "寒冷"
	if t < 0.40: return "凉爽"
	if t < 0.55: return "温和"
	if t < 0.75: return "温暖"
	if t < 0.90: return "炎热"
	return "酷热"


func _temperature_band(t: float) -> String:
	return temperature_band(t)


func _moisture_band(m: float) -> String:
	if m < 0.20: return "极干"
	if m < 0.40: return "干燥"
	if m < 0.60: return "适中"
	if m < 0.80: return "湿润"
	return "极湿"
