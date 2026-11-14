extends RefCounted
class_name CellInspectorViewModel
const FamilyWorkspaceProjection = preload("res://scripts/ui/family_workspace_projection.gd")


const TEMPERATURE_HISTORY_CAPACITY := 32
const TEMPERATURE_HISTORY_CACHE_LIMIT := 64
const DETAIL_HISTORY_CAPACITY := 48
const DETAIL_HISTORY_LOOKBACK := 7
## 原生金额单位是 1/10000 货币；只有视图层才把它换算成金币读数。
const MONEY_SCALE := 10000.0

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

## 营造窗口一页的建筑条目数。一页 = 16 条同时报价：够填满视口，又让
## 「打开 / 切部门 / 翻页 / 每日刷新」的原生报价调用保持在毫秒级。
const CONSTRUCTION_PAGE_SIZE := 16
## Building kinds are compiled to dense ints; 3 == state-owned (barracks /
## fortification / war college). The dedicated military department lists them
## from MilitaryCatalog's `state_buildings` and quotes their economy type IDs.
const STATE_BUILDING_KIND := 3
## 军事部门不是经济目录里的部门：条目来自 MilitaryCatalog 的 `state_buildings`，
## 命令走军事运行时的 `state.build`，与经济侧的 `construction.build` 是两条通道
## （见 docs/ui/military-cell-tab.md §2.1）。这个 id 故意不并入 economy 的
## sector 表，避免被 `construction_candidates` 当成经济部门下标。
const CONSTRUCTION_MILITARY_SECTOR := "military"
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
const MAINTENANCE_KIND_BUILDING := 0
const MAINTENANCE_REASON_TEXT: Array[String] = ["—", "缺货", "预算不足", "运输未到"]
const CONSTRUCTION_SECTOR_LABELS := {
	"agriculture": "农业",
	"extractive": "采掘",
	"manufacturing": "制造",
	"energy": "能源",
	"knowledge": "知识",
	"military": "军事",
}
const CONSTRUCTION_SECTOR_ICONS := {
	"agriculture": &"economy.building.farm",
	"extractive": &"economy.building.mine",
	"manufacturing": &"economy.building.factory",
	"energy": &"economy.building.power",
	"knowledge": &"economy.building.science",
	"military": &"military.building.barracks",
}
## 营造目录的排序档。三档都遵守「可建优先」，档位只决定可建项之间的次序。
const CONSTRUCTION_SORT_IDS := ["recommended", "cost", "newest"]
## 原生报价的拒绝码 → 玩家可读的短因由（行内标签用，长解释在 hover 里）。
const CONSTRUCTION_REASON_TEXT := {
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
	"political_regime_lacks_treasury_construction": "当前体制不开放国库建造",
}
## one-tick memo for the (large) cell building snapshot: the buildings tab and
## the construction window share one read per cell per committed day.
var _building_snapshot_memo: Dictionary = {}

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
## 格级综合满意度：忙时读不到就沿用上次成功值，避免页头在综合/生存口径间闪跳。
var _cell_composite_cache: Dictionary = {}
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
## 上面那次查询是否真的读到了国家快照（false = 科技闸门未知，UI 不过滤）。
var _technology_ids_resolved := false
var _technology_names: Dictionary = {}
var _research_signal_catalog: Dictionary = {}
var _technology_catalog: Dictionary = {}
## 军事目录（官营建筑行 + 兵种名）按 facade 身份缓存：整局不变。
var _military_catalog_facade = null
var _military_catalog_rows: Array = []
var _military_unit_names: Dictionary = {}
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
	_cell_composite_cache.clear()
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
	_technology_ids_resolved = false
	_technology_names.clear()
	_military_catalog_facade = null
	_military_catalog_rows = []
	_military_unit_names = {}
	_trade_order_generation = -1
	_trade_order_pages.clear()
	_trade_order_models.clear()
	_trade_order_names.clear()
	_trade_order_good_indices.clear()
	_trade_order_query_count = 0
	_building_snapshot_memo.clear()


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
		# 军事页签只在有军事绑定、且这是陆地格时出现：水域永远不会归属任何国家。
		if not LandformType.is_water(_landform(cell, idx)) and _military_facade() != null:
			tabs.append({"id": "military", "label": "军事", "icon": "country.military"})
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
			"kicker": "区域 %d, %d" % [off.x + 1, off.y + 1],
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
		# 页头「满意度」读的是格级综合值：它变了而生存没变时也必须打补丁。
		int(roundf(_cell_composite_satisfaction(idx) * 1000.0)) if intel_visible else -1,
		int(population_summary.get("job_capacity", 0)),
		int(population_summary.get("jobs_filled", 0)),
		int(population_summary.get("employed_population", 0)),
		int(population_summary.get("unemployed_population", 0)),
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
		"military":
			return _military_category(idx)
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
	return _ObjectDossiers.build_object_detail(self, cell, request)


## 家族专用档案册契约。保留 build_object_detail() 作为现有 facade、迷雾门控
## 与低频查询的唯一入口，再把兼容行数据整理成专用组件无需二次解析的结构。
func build_family_detail(cell: HexCell, request: Dictionary) -> Dictionary:
	return _ObjectDossiers.build_family_detail(self, cell, request)


const _ObjectDossiers = preload("res://scripts/ui/cell_inspector/object_dossiers.gd")
const _Military = preload("res://scripts/ui/cell_inspector/military.gd")
const _Overview = preload("res://scripts/ui/cell_inspector/overview.gd")
const _PopulationMarket = preload("res://scripts/ui/cell_inspector/population_market.gd")
const _Construction = preload("res://scripts/ui/cell_inspector/construction.gd")
const _Geography = preload("res://scripts/ui/cell_inspector/geography.gd")
var _Military_delegate = _Military.new()
var _Overview_delegate = _Overview.new()
var _PopulationMarket_delegate = _PopulationMarket.new()
var _Construction_delegate = _Construction.new()
var _Geography_delegate = _Geography.new()

static func family_workspace_model(detail: Dictionary) -> Dictionary:
	return _ObjectDossiers.family_workspace_model(detail)

static func _family_unique_traits(rows: Array) -> Array:
	return _ObjectDossiers._family_unique_traits(rows)

static func _family_unique_preferences(rows: Array) -> Array:
	return _ObjectDossiers._family_unique_preferences(rows)

static func _family_unique_rows(rows: Array, key_fields: Array) -> Array:
	return _ObjectDossiers._family_unique_rows(rows, key_fields)

static func _family_text_key(value: Variant) -> String:
	return _ObjectDossiers._family_text_key(value)

static func _parse_leading_float(text: Variant, fallback: float = 0.0) -> float:
	return _ObjectDossiers._parse_leading_float(text, fallback)

static func _detail_row_value_map(detail_rows: Array) -> Dictionary:
	return _ObjectDossiers._detail_row_value_map(detail_rows)

static func good_dossier_model(row: Dictionary) -> Dictionary:
	return _ObjectDossiers.good_dossier_model(row)

static func cohort_dossier_model(row: Dictionary) -> Dictionary:
	return _ObjectDossiers.cohort_dossier_model(row)

static func building_dossier_model(row: Dictionary) -> Dictionary:
	return _ObjectDossiers.building_dossier_model(row)

func _military_facade():
	return _Military_delegate._military_facade(self)

func _military_category(cell_idx: int) -> Dictionary:
	return _Military_delegate._military_category(self, cell_idx)

func _military_cell_model(facade, snapshot: Dictionary, country: Dictionary,
		cell_idx: int) -> Dictionary:
	return _Military_delegate._military_cell_model(self, facade, snapshot, country, cell_idx)

func _military_maintenance_rows(facade, cell_idx: int) -> Dictionary:
	return _Military_delegate._military_maintenance_rows(self, facade, cell_idx)

func _military_barracks_count(snapshot: Dictionary) -> int:
	return _Military_delegate._military_barracks_count(self, snapshot)

func _military_training_speed(catalog_rows: Array, college_tier: int) -> float:
	return _Military_delegate._military_training_speed(self, catalog_rows, college_tier)

func _military_can_build(snapshot: Dictionary, country: Dictionary) -> bool:
	return _Military_delegate._military_can_build(self, snapshot, country)

func _military_troop_rows(snapshot: Dictionary) -> Array:
	return _Military_delegate._military_troop_rows(self, snapshot)

func _military_training_rows(snapshot: Dictionary, units: Dictionary) -> Array:
	return _Military_delegate._military_training_rows(self, snapshot, units)

func _state_building_entry(role_def: Dictionary, snapshot: Dictionary,
		catalog_rows: Array, researched: PackedStringArray, gate_known: bool,
		can_build: bool, facade = null, cell_idx: int = -1,
		maintenance_by_index: Dictionary = {}) -> Dictionary:
	return _Military_delegate._state_building_entry(self, role_def, snapshot, catalog_rows, researched, gate_known, can_build, facade, cell_idx, maintenance_by_index)

func _state_building_cost(facade, building_index: int,
		building_row: Dictionary, cash_available: int, cell_idx: int,
		treasury_cache: Dictionary = {}, market_cache: Dictionary = {},
		standing_row: Dictionary = {}, held_count: int = 0) -> Dictionary:
	return _Military_delegate._state_building_cost(self, facade, building_index, building_row, cash_available, cell_idx, treasury_cache, market_cache, standing_row, held_count)

func _state_building_economy_quote(facade, building_index: int,
		building_row: Dictionary, country_handle: int, cell_idx: int,
		_cash_available: int, standing_row: Dictionary = {},
		held_count: int = 0) -> Dictionary:
	return _Military_delegate._state_building_economy_quote(self, facade, building_index, building_row, country_handle, cell_idx, _cash_available, standing_row, held_count)

func _state_building_standing_cost(building_row: Dictionary,
		count: int = 1) -> Dictionary:
	return _Military_delegate._state_building_standing_cost(self, building_row, count)

func _state_building_upkeep_after_text(build_row: Dictionary,
		standing_row: Dictionary, held_count: int) -> String:
	return _Military_delegate._state_building_upkeep_after_text(self, build_row, standing_row, held_count)

func _state_building_upkeep_text(building_row: Dictionary,
		count: int = 1, existing: bool = true) -> String:
	return _Military_delegate._state_building_upkeep_text(self, building_row, count, existing)

func _empty_state_building_cost() -> Dictionary:
	return _Military_delegate._empty_state_building_cost(self)

func _state_building_materials_text(materials: Array) -> String:
	return _Military_delegate._state_building_materials_text(self, materials)

func _state_building_cost_tooltip(display_name: String, effect: String,
		cost: Dictionary) -> String:
	return _Military_delegate._state_building_cost_tooltip(self, display_name, effect, cost)

func _treasury_good_stock() -> Dictionary:
	return _Military_delegate._treasury_good_stock(self)

func _country_cash() -> int:
	return _Military_delegate._country_cash(self)

func _state_building_role_rows(catalog_rows: Array, role: int) -> Array:
	return _Military_delegate._state_building_role_rows(self, catalog_rows, role)

func _state_building_at_tier(role_rows: Array, tier: int) -> Dictionary:
	return _Military_delegate._state_building_at_tier(self, role_rows, tier)

func _state_building_pending(catalog_rows: Array, snapshot: Dictionary,
		role: int) -> Dictionary:
	return _Military_delegate._state_building_pending(self, catalog_rows, snapshot, role)

func _state_building_unlocked(row: Dictionary, researched: PackedStringArray,
		gate_known: bool) -> bool:
	return _Military_delegate._state_building_unlocked(self, row, researched, gate_known)

static func _state_building_maintenance_text(row: Dictionary) -> String:
	return _Military._state_building_maintenance_text(row)

static func _maintenance_days_text(days_cover_x10: int) -> String:
	return _Military._maintenance_days_text(days_cover_x10)

func _state_building_effect(role_id: String, row: Dictionary,
		disrepair: bool) -> String:
	return _Military_delegate._state_building_effect(self, role_id, row, disrepair)

func _state_building_lock_tooltip(role_rows: Array, researched: PackedStringArray,
		gate_known: bool) -> String:
	return _Military_delegate._state_building_lock_tooltip(self, role_rows, researched, gate_known)

func _technology_display_name(tech_id: String) -> String:
	return _Military_delegate._technology_display_name(self, tech_id)

func _military_catalog_cache(facade) -> Dictionary:
	return _Military_delegate._military_catalog_cache(self, facade)

static func _one_decimal(value: float) -> String:
	return _Military._one_decimal(value)

static func _count_text(value: int) -> String:
	return _Military._count_text(value)

func _build_header(
	off: Vector2i,
	terrain_v: int,
	landform_v: int,
	country_summary: Dictionary,
	population_summary: Dictionary = {},
	intel_visible: bool = true,
	_has_river: bool = false
) -> Dictionary:
	return _Overview_delegate._build_header(self, off, terrain_v, landform_v, country_summary, population_summary, intel_visible, _has_river)

func _ownership_text(country_summary: Dictionary, intel_visible: bool) -> String:
	return _Overview_delegate._ownership_text(self, country_summary, intel_visible)

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
	return _Overview_delegate._kpis(self, intel_visible, temp, moist, habitability, is_water, population_summary, country_summary, cell_idx)

func _gdp_kpi(cell_idx: int) -> Dictionary:
	return _Overview_delegate._gdp_kpi(self, cell_idx)

func _cell_composite_satisfaction(cell_idx: int) -> float:
	return _Overview_delegate._cell_composite_satisfaction(self, cell_idx)

func _primary_resource_kpi(cell_idx: int, is_water: bool) -> Dictionary:
	return _Overview_delegate._primary_resource_kpi(self, cell_idx, is_water)

func _overview_category(cell: HexCell, idx: int, cover_v: int) -> Dictionary:
	return _Overview_delegate._overview_category(self, cell, idx, cover_v)

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
	return _Overview_delegate._geography_information_category(self, cell, idx, terrain_v, landform_v, vegetation_v, cover_v, elev, temp, moist, base_moist, wf, snow, vitality, passable_land, is_water)

func _append_resources_to_geography(category: Dictionary, idx: int,
		is_water: bool) -> void:
	return _Overview_delegate._append_resources_to_geography(self, category, idx, is_water)

func _append_bio_facts_to_geography(category: Dictionary, idx: int,
		visibility: Dictionary = {}) -> void:
	return _Overview_delegate._append_bio_facts_to_geography(self, category, idx, visibility)

func _cell_bio_badges(idx: int, visibility: Dictionary = {}) -> Array:
	return _Overview_delegate._cell_bio_badges(self, idx, visibility)

func _ensure_research_signal_catalog() -> Dictionary:
	return _Overview_delegate._ensure_research_signal_catalog(self)

func _ensure_technology_catalog() -> Dictionary:
	return _Overview_delegate._ensure_technology_catalog(self)

func _rows_from_category(category: Dictionary, rows_key: String) -> Array:
	return _Overview_delegate._rows_from_category(self, category, rows_key)

func _geography_category(cell: HexCell, idx: int, terrain_v: int, elev: float, passable_land: bool) -> Dictionary:
	return _Overview_delegate._geography_category(self, cell, idx, terrain_v, elev, passable_land)

func _passage_text(passable_land: bool, passable_sea: bool, terrain_v: int) -> String:
	return _Overview_delegate._passage_text(self, passable_land, passable_sea, terrain_v)

func _climate_category(cell: HexCell, idx: int, temp: float, moist: float, base_moist: float, wf: Dictionary) -> Dictionary:
	return _Overview_delegate._climate_category(self, cell, idx, temp, moist, base_moist, wf)

func _hydrology_category(_cell: HexCell, _idx: int, _wf: Dictionary, snow: float, is_water: bool) -> Dictionary:
	return _Overview_delegate._hydrology_category(self, _cell, _idx, _wf, snow, is_water)

func _ecology_category(cell: HexCell, idx: int, vegetation_v: int, vitality: float) -> Dictionary:
	return _Overview_delegate._ecology_category(self, cell, idx, vegetation_v, vitality)

func _resources_category(resource_state: Array, visibility: Dictionary = {}) -> Dictionary:
	return _Overview_delegate._resources_category(self, resource_state, visibility)

func _history_category(cell: HexCell) -> Dictionary:
	return _Overview_delegate._history_category(self, cell)

static func _snapshot_pending(snapshot: Dictionary) -> bool:
	return _Overview._snapshot_pending(snapshot)

static func _pending_category() -> Dictionary:
	return _Overview._pending_category()

func _population_snapshot(cell_idx: int, include_details: bool = true) -> Dictionary:
	return _Overview_delegate._population_snapshot(self, cell_idx, include_details)

func _population_summary(cell_idx: int) -> Dictionary:
	return _Overview_delegate._population_summary(self, cell_idx)

func _country_summary(cell_idx: int) -> Dictionary:
	return _Overview_delegate._country_summary(self, cell_idx)

func population_summary(cell_idx: int) -> Dictionary:
	return _Overview_delegate.population_summary(self, cell_idx)

func country_summary(cell_idx: int) -> Dictionary:
	return _Overview_delegate.country_summary(self, cell_idx)

func sample_day() -> int:
	return _Overview_delegate.sample_day(self)

func _market_snapshot(cell_idx: int) -> Dictionary:
	return _Overview_delegate._market_snapshot(self, cell_idx)

func _building_snapshot(cell_idx: int) -> Dictionary:
	return _Overview_delegate._building_snapshot(self, cell_idx)

func _family_cell_snapshot(cell_idx: int) -> Dictionary:
	return _Overview_delegate._family_cell_snapshot(self, cell_idx)

func _family_category(snapshot: Dictionary) -> Dictionary:
	return _Overview_delegate._family_category(self, snapshot)

func _family_detail_fields(snapshot: Dictionary) -> Dictionary:
	return _Overview_delegate._family_detail_fields(self, snapshot)

func _family_trait_rows(snapshot: Dictionary) -> Array:
	return _Overview_delegate._family_trait_rows(self, snapshot)

func _family_behavior_rows(snapshot: Dictionary, cell_idx: int = -1) -> Array:
	return _Overview_delegate._family_behavior_rows(self, snapshot, cell_idx)

static func family_behavior_rows_for_cell(snapshot: Dictionary, facade,
		cell_idx: int) -> Array:
	return _Overview.family_behavior_rows_for_cell(snapshot, facade, cell_idx)

static func _family_behavior_rows_for_visibility(snapshot: Dictionary,
		visibility: Dictionary) -> Array:
	return _Overview._family_behavior_rows_for_visibility(snapshot, visibility)

static func _family_behavior_icon(axis: int, stable_id: String, name_text: String = "") -> StringName:
	return _Overview._family_behavior_icon(axis, stable_id, name_text)

func _family_behavior_visibility(cell_idx: int) -> Dictionary:
	return _Overview_delegate._family_behavior_visibility(self, cell_idx)

static func _family_behavior_visibility_for_cell(facade, cell_idx: int) -> Dictionary:
	return _Overview._family_behavior_visibility_for_cell(facade, cell_idx)

static func _family_behavior_visible_professions(buildings: Dictionary,
		population: Dictionary) -> Dictionary:
	return _Overview._family_behavior_visible_professions(buildings, population)

static func _add_profession_id(target: Dictionary, catalog: PackedStringArray,
		dense_id: int) -> void:
	return _Overview._add_profession_id(target, catalog, dense_id)

static func _family_behavior_visible_needs(catalog: Dictionary,
		market_good_ids: PackedStringArray,
		good_available: PackedByteArray) -> Dictionary:
	return _Overview._family_behavior_visible_needs(catalog, market_good_ids, good_available)

static func _family_behavior_selector_visible(axis: int, stable_id: String,
		visibility: Dictionary) -> bool:
	return _Overview._family_behavior_selector_visible(axis, stable_id, visibility)

func _family_branch_rows(snapshot: Dictionary) -> Array:
	return _Overview_delegate._family_branch_rows(self, snapshot)

func _family_bound_effect_rows(snapshot: Dictionary) -> Array:
	return _Overview_delegate._family_bound_effect_rows(self, snapshot)

func _family_modifier_rows(snapshot: Dictionary) -> Array:
	return _Overview_delegate._family_modifier_rows(self, snapshot)

func _family_trigger_rows(snapshot: Dictionary) -> Array:
	return _Overview_delegate._family_trigger_rows(self, snapshot)

static func _prestige_text(level: int) -> String:
	return _Overview._prestige_text(level)

static func _q16_percent_text(value: int) -> String:
	return _Overview._q16_percent_text(value)

func _family_notable_person_rows(facade, family_handle: int) -> Array:
	return _Overview_delegate._family_notable_person_rows(self, facade, family_handle)

func _gdp_metrics(cell_idx: int) -> Array:
	return _PopulationMarket_delegate._gdp_metrics(self, cell_idx)

func _population_category(snapshot: Dictionary, market_snapshot: Dictionary = {},
		cell_idx: int = -1) -> Dictionary:
	return _PopulationMarket_delegate._population_category(self, snapshot, market_snapshot, cell_idx)

func _group_demand_rows_by_usage(rows: Array) -> Array:
	return _PopulationMarket_delegate._group_demand_rows_by_usage(self, rows)

func _ensure_detail_history_cell(cell_idx: int) -> void:
	return _PopulationMarket_delegate._ensure_detail_history_cell(self, cell_idx)

func _append_history_sample(bucket: Dictionary, key: String, value: float) -> PackedFloat32Array:
	return _PopulationMarket_delegate._append_history_sample(self, bucket, key, value)

static func _series_lookback_delta(series: PackedFloat32Array) -> float:
	return _PopulationMarket._series_lookback_delta(series)

func _record_cohort_history(cohort_key: String, sat: float, net_val: float,
		income_val: float, wealth_val: float) -> void:
	return _PopulationMarket_delegate._record_cohort_history(self, cohort_key, sat, net_val, income_val, wealth_val)

func _record_good_history(good_id: String, price_val: float, price_index: float,
		stock_units: float, shortage_ratio: float) -> void:
	return _PopulationMarket_delegate._record_good_history(self, good_id, price_val, price_index, stock_units, shortage_ratio)

func _record_building_history(building_key: String, profit_val: float,
		utilization_ratio: float) -> void:
	return _PopulationMarket_delegate._record_building_history(self, building_key, profit_val, utilization_ratio)

func _compute_cell_avg_satisfaction_dims(populations: PackedInt64Array,
		dims: PackedInt32Array, dimension_count: int) -> PackedFloat32Array:
	return _PopulationMarket_delegate._compute_cell_avg_satisfaction_dims(self, populations, dims, dimension_count)

func _cohort_satisfaction_dims_float(dims: PackedInt32Array, dimension_count: int,
		cohort_idx: int) -> PackedFloat32Array:
	return _PopulationMarket_delegate._cohort_satisfaction_dims_float(self, dims, dimension_count, cohort_idx)

func _living_standard_name(level: int) -> String:
	return _PopulationMarket_delegate._living_standard_name(self, level)

func _living_standard_icon(level: int) -> String:
	return _PopulationMarket_delegate._living_standard_icon(self, level)

func _living_standard_accent(level: int) -> Color:
	return _PopulationMarket_delegate._living_standard_accent(self, level)

func _satisfaction_dimension_name(dimension: int) -> String:
	return _PopulationMarket_delegate._satisfaction_dimension_name(self, dimension)

func _satisfaction_dimension_rows(dims: PackedInt32Array, dimension_count: int,
		cohort_idx: int, worst_dimension: int) -> Array:
	return _PopulationMarket_delegate._satisfaction_dimension_rows(self, dims, dimension_count, cohort_idx, worst_dimension)

func _satisfaction_accent(value: float) -> Color:
	return _PopulationMarket_delegate._satisfaction_accent(self, value)

func _demand_good_metadata(snapshot: Dictionary, cohort_idx: int) -> Dictionary:
	return _PopulationMarket_delegate._demand_good_metadata(self, snapshot, cohort_idx)

func _need_display_name(stable_id: String) -> String:
	return _PopulationMarket_delegate._need_display_name(self, stable_id)

func _market_category(snapshot: Dictionary) -> Dictionary:
	return _PopulationMarket_delegate._market_category(self, snapshot)

func trade_orders_model(cell_idx: int, good_id: String, offset: int = 0,
		limit: int = TRADE_ORDER_PAGE_SIZE, generation: int = -1,
		sample_day: int = -1) -> Dictionary:
	return _PopulationMarket_delegate.trade_orders_model(self, cell_idx, good_id, offset, limit, generation, sample_day)

func _trade_order_page_key(cell_idx: int, good_index: int, generation: int,
		offset: int, limit: int) -> String:
	return _PopulationMarket_delegate._trade_order_page_key(self, cell_idx, good_index, generation, offset, limit)

func _query_trade_order_page(facade, cell_idx: int, good_index: int,
		offset: int, limit: int) -> Dictionary:
	return _PopulationMarket_delegate._query_trade_order_page(self, facade, cell_idx, good_index, offset, limit)

func _trade_order_good_index(facade, good_id: String) -> int:
	return _PopulationMarket_delegate._trade_order_good_index(self, facade, good_id)

func _economy_facade():
	return _PopulationMarket_delegate._economy_facade(self)

func _trade_orders_failure(text: String, reason: String) -> Dictionary:
	return _PopulationMarket_delegate._trade_orders_failure(self, text, reason)

func _trade_orders_pending_model(page: Dictionary, offset: int, limit: int,
		sample_day: int, generation: int) -> Dictionary:
	return _PopulationMarket_delegate._trade_orders_pending_model(self, page, offset, limit, sample_day, generation)

static func _trim_dictionary(cache: Dictionary, limit: int) -> void:
	return _PopulationMarket._trim_dictionary(cache, limit)

func _build_trade_orders_model(page: Dictionary,
		sample_day: int, generation: int) -> Dictionary:
	return _PopulationMarket_delegate._build_trade_orders_model(self, page, sample_day, generation)

func _trade_counterpart_name(cell_idx: int) -> String:
	return _PopulationMarket_delegate._trade_counterpart_name(self, cell_idx)

func _trade_counterpart_coord(cell_idx: int) -> String:
	return _PopulationMarket_delegate._trade_counterpart_coord(self, cell_idx)

func _trade_order_tooltip(order_id: int, direction: int, counterpart_name: String,
		counterpart_visible: bool, quantity: int, source_price: int,
		destination_price: int, base_value: int, escrow: int, capacity: int,
		departure: int, arrival: int, remaining: int, delivered: int,
		flags: int) -> String:
	return _PopulationMarket_delegate._trade_order_tooltip(self, order_id, direction, counterpart_name, counterpart_visible, quantity, source_price, destination_price, base_value, escrow, capacity, departure, arrival, remaining, delivered, flags)

func _building_category(snapshot: Dictionary, cell_idx: int = -1) -> Dictionary:
	return _Construction_delegate._building_category(self, snapshot, cell_idx)

func build_construction_entry(cell_idx: int) -> Dictionary:
	return _Construction_delegate.build_construction_entry(self, cell_idx)

func build_construction_model(cell_idx: int, sector_id: String = "",
		search: String = "", sort_id: String = "recommended",
		offset: int = 0) -> Dictionary:
	return _Construction_delegate.build_construction_model(self, cell_idx, sector_id, search, sort_id, offset)

## Capability is published by Country and copied into cell_summary. UI treats
## the value as a read-only hint only; PlayerController and Economy apply the
## same gate again at their command boundaries.
func _country_allows_treasury_construction(summary: Dictionary) -> bool:
	var politics: Variant = summary.get("politics", {})
	if politics is Dictionary:
		if politics.has("can_treasury_construction"):
			return bool(politics.get("can_treasury_construction", false))
		if politics.has("capability_bits"):
			return (int(politics.get("capability_bits", 0)) & 1) != 0
	if summary.has("can_treasury_construction"):
		return bool(summary.get("can_treasury_construction", false))
	if summary.has("capability_bits"):
		return (int(summary.get("capability_bits", 0)) & 1) != 0
	return false


func _construction_header(cell_idx: int) -> Dictionary:
	return _Construction_delegate._construction_header(self, cell_idx)

func _construction_catalog_count(snapshot: Dictionary) -> int:
	return _Construction_delegate._construction_catalog_count(self, snapshot)

func _construction_military_count() -> int:
	return _Construction_delegate._construction_military_count(self)

func _construction_military_rows(cell_idx: int, search: String) -> Array:
	return _Construction_delegate._construction_military_rows(self, cell_idx, search)

func _construction_military_occupied(catalog_rows: Array, snapshot: Dictionary) -> Dictionary:
	return _Construction_delegate._construction_military_occupied(self, catalog_rows, snapshot)

func _construction_military_row(facade, index: int, row: Dictionary,
		snapshot: Dictionary, researched: PackedStringArray, gate_known: bool,
		can_build: bool, cash: int, cell_idx: int, occupied: Dictionary,
		treasury_stock: Dictionary, market_stock: Dictionary) -> Dictionary:
	return _Construction_delegate._construction_military_row(self, facade, index, row, snapshot, researched, gate_known, can_build, cash, cell_idx, occupied, treasury_stock, market_stock)

func _construction_military_block_text(snapshot: Dictionary) -> String:
	return _Construction_delegate._construction_military_block_text(self, snapshot)

func _state_building_pending_by_index(snapshot: Dictionary, index: int) -> int:
	return _Construction_delegate._state_building_pending_by_index(self, snapshot, index)

func _construction_military_page(model: Dictionary, rows: Array,
		sort: String, requested_offset: int) -> Dictionary:
	return _Construction_delegate._construction_military_page(self, model, rows, sort, requested_offset)

static func _construction_military_before(a: Dictionary, b: Dictionary,
		sort: String) -> bool:
	return _Construction._construction_military_before(a, b, sort)

func _construction_building_snapshot(cell_idx: int) -> Dictionary:
	return _Construction_delegate._construction_building_snapshot(self, cell_idx)

func _construction_sector_name(sector_ids: PackedStringArray, sector_index: int) -> String:
	return _Construction_delegate._construction_sector_name(self, sector_ids, sector_index)

func _construction_sort_entries(selected: String) -> Array:
	return _Construction_delegate._construction_sort_entries(self, selected)

func _construction_sector_entries(sector_ids: PackedStringArray,
		counts: Dictionary, selected: String) -> Array:
	return _Construction_delegate._construction_sector_entries(self, sector_ids, counts, selected)

func _construction_page_label(offset: int, count: int, total: int) -> String:
	return _Construction_delegate._construction_page_label(self, offset, count, total)

func _construction_local_stock(market: Dictionary) -> Dictionary:
	return _Construction_delegate._construction_local_stock(self, market)

func _construction_entries(candidates: PackedInt32Array, quotes: Dictionary,
		snapshot: Dictionary, market: Dictionary, durations: PackedInt32Array,
		maturity_ranks: PackedInt32Array) -> Array:
	return _Construction_delegate._construction_entries(self, candidates, quotes, snapshot, market, durations, maturity_ranks)

static func _construction_entry_before(a: Dictionary, b: Dictionary,
		sort: String) -> bool:
	return _Construction._construction_entry_before(a, b, sort)

func _construction_daily_score(type_id: int, snapshot: Dictionary,
		prices: Dictionary) -> int:
	return _Construction_delegate._construction_daily_score(self, type_id, snapshot, prices)

func _construction_flow_value(snapshot: Dictionary, type_id: int, kind: String,
		good_ids: PackedStringArray, prices: Dictionary) -> int:
	return _Construction_delegate._construction_flow_value(self, snapshot, type_id, kind, good_ids, prices)

func _construction_price_by_good(market: Dictionary) -> Dictionary:
	return _Construction_delegate._construction_price_by_good(self, market)

func _construction_page_rows(entries: Array, quotes: Dictionary,
		snapshot: Dictionary, economy, market: Dictionary,
		maturity_names: PackedStringArray) -> Array:
	return _Construction_delegate._construction_page_rows(self, entries, quotes, snapshot, economy, market, maturity_names)

func _construction_materials_text(materials: Array) -> String:
	return _Construction_delegate._construction_materials_text(self, materials)

func _construction_reason_text(code: String, materials: Array,
		local_stock: Dictionary) -> String:
	return _Construction_delegate._construction_reason_text(self, code, materials, local_stock)

func _construction_tooltip(entry: Dictionary, item: Dictionary, materials: Array,
		local_stock: Dictionary, placement: Dictionary, job_spec: Dictionary,
		unlocked_goods: Dictionary, days: int, maturity: String,
		reason_text: String) -> String:
	return _Construction_delegate._construction_tooltip(self, entry, item, materials, local_stock, placement, job_spec, unlocked_goods, days, maturity, reason_text)

func _construction_job_text(job_spec: Dictionary) -> String:
	return _Construction_delegate._construction_job_text(self, job_spec)

func _construction_recipe_side(rows: Array) -> String:
	return _Construction_delegate._construction_recipe_side(self, rows)

func _goods_scaled(value: int) -> String:
	return _Construction_delegate._goods_scaled(self, value)

func _construction_recipe_rows(placement: Dictionary, ids_key: String,
		quantities_key: String, label: String) -> Array:
	return _Construction_delegate._construction_recipe_rows(self, placement, ids_key, quantities_key, label)

func _construction_input_recipe_rows(placement: Dictionary,
		unlocked_goods: Dictionary) -> Array:
	return _Construction_delegate._construction_input_recipe_rows(self, placement, unlocked_goods)

func _construction_input_candidate_label(placement: Dictionary, input_idx: int,
		unlocked_goods: Dictionary) -> String:
	return _Construction_delegate._construction_input_candidate_label(self, placement, input_idx, unlocked_goods)

func _unlocked_good_ids(snapshot: Dictionary) -> Dictionary:
	return _Construction_delegate._unlocked_good_ids(self, snapshot)

func _construction_profession_name(profession_id: String) -> String:
	return _Construction_delegate._construction_profession_name(self, profession_id)

func _append_recipe_rows(rows: Array, snapshot: Dictionary, type_idx: int, kind: String,
		actual_total: int, building_count: int, period_days: int, group_idx: int = -1) -> void:
	return _Construction_delegate._append_recipe_rows(self, rows, snapshot, type_idx, kind, actual_total, building_count, period_days, group_idx)

func _selected_input_short_label(snapshot: Dictionary, input_idx: int, local_input_idx: int,
		group_idx: int, fallback_id: String) -> String:
	return _Construction_delegate._selected_input_short_label(self, snapshot, input_idx, local_input_idx, group_idx, fallback_id)

func _input_candidate_label(snapshot: Dictionary, input_idx: int, local_input_idx: int,
		group_idx: int, fallback_id: String) -> String:
	return _Construction_delegate._input_candidate_label(self, snapshot, input_idx, local_input_idx, group_idx, fallback_id)

func _append_resource_recipe_rows(rows: Array, snapshot: Dictionary, type_idx: int,
		actual_total: int, building_count: int, period_days: int) -> void:
	return _Construction_delegate._append_resource_recipe_rows(self, rows, snapshot, type_idx, actual_total, building_count, period_days)

func _append_resource_generation_rows(rows: Array, snapshot: Dictionary, type_idx: int,
		actual_total: int, building_count: int, period_days: int) -> void:
	return _Construction_delegate._append_resource_generation_rows(self, rows, snapshot, type_idx, actual_total, building_count, period_days)

func _building_resource_depleted(snapshot: Dictionary, type_idx: int) -> bool:
	return _Construction_delegate._building_resource_depleted(self, snapshot, type_idx)

func _resource_effective_text(snapshot: Dictionary, resource_idx: int, access_mode: int = 0) -> String:
	return _Construction_delegate._resource_effective_text(self, snapshot, resource_idx, access_mode)

func _append_construction_rows(rows: Array, snapshot: Dictionary, type_ids: PackedStringArray, type_names: PackedStringArray) -> void:
	return _Construction_delegate._append_construction_rows(self, rows, snapshot, type_ids, type_names)

func _building_icon(type_id: String, snapshot: Dictionary = {}, type_idx: int = -1) -> StringName:
	return _Construction_delegate._building_icon(self, type_id, snapshot, type_idx)

func _owner_profession_name(snapshot: Dictionary, signature_idx: int) -> String:
	return _Construction_delegate._owner_profession_name(self, snapshot, signature_idx)

func _profession_name(snapshot: Dictionary, profession_idx: int) -> String:
	return _Construction_delegate._profession_name(self, snapshot, profession_idx)

func _format_input_candidate_label(good_id: String, efficiency_q16: int) -> String:
	return _Construction_delegate._format_input_candidate_label(self, good_id, efficiency_q16)

func _good_display_name(stable_id: String) -> String:
	return _Construction_delegate._good_display_name(self, stable_id)

func _resource_display_name(stable_id: String) -> String:
	return _Construction_delegate._resource_display_name(self, stable_id)

func _fill_percent(filled: int, required: int) -> float:
	return _Construction_delegate._fill_percent(self, filled, required)

func _actual_daily_rate(actual_total: int, building_count: int, period_days: int) -> String:
	return _Construction_delegate._actual_daily_rate(self, actual_total, building_count, period_days)

func _sum_i64(values: PackedInt64Array) -> int:
	return _Construction_delegate._sum_i64(self, values)

func _money_text(subunits: int) -> String:
	return _Construction_delegate._money_text(self, subunits)

func _goods_unit_text(subunits: int) -> String:
	return _Construction_delegate._goods_unit_text(self, subunits)

func _packed_i64_at(values: PackedInt64Array, index: int) -> int:
	return _Construction_delegate._packed_i64_at(self, values, index)

func _market_trade_enabled(enabled: PackedByteArray, index: int) -> bool:
	return _Construction_delegate._market_trade_enabled(self, enabled, index)

func _trade_arrival_days(next_arrival_day: int, sample_day: int) -> int:
	return _Construction_delegate._trade_arrival_days(self, next_arrival_day, sample_day)

func _market_trade_insight_text(in_transit_kinds: int, arrival_days: int) -> String:
	return _Construction_delegate._market_trade_insight_text(self, in_transit_kinds, arrival_days)

func _cashflow_source_name(source_id: String, income: bool) -> String:
	return _Construction_delegate._cashflow_source_name(self, source_id, income)

func _has_cashflow_row(rows: Array, source_id: String) -> bool:
	return _Construction_delegate._has_cashflow_row(self, rows, source_id)

func _weather_field(cell: HexCell, idx: int) -> Dictionary:
	return _Geography_delegate._weather_field(self, cell, idx)

func _resource_visibility_context(cell_idx: int) -> Dictionary:
	return _Geography_delegate._resource_visibility_context(self, cell_idx)

func _completed_technology_ids(country_facade, handle: int) -> Dictionary:
	return _Geography_delegate._completed_technology_ids(self, country_facade, handle)

func player_technology_ids() -> PackedStringArray:
	return _Geography_delegate.player_technology_ids(self)

func _extractable_resource_ids(snapshot: Dictionary) -> Dictionary:
	return _Geography_delegate._extractable_resource_ids(self, snapshot)

func _resource_state(idx: int, is_water: bool, visibility: Dictionary = {}) -> Array:
	return _Geography_delegate._resource_state(self, idx, is_water, visibility)

func _resource_reserve(profile, idx: int) -> float:
	return _Geography_delegate._resource_reserve(self, profile, idx)

func _resource_reference_reserve(profile: ResourceProfile) -> float:
	return _Geography_delegate._resource_reference_reserve(self, profile)

func _habitability_score(temp: float, moist: float, vitality: float, elev: float, passable_land: bool, is_water: bool) -> float:
	return _Geography_delegate._habitability_score(self, temp, moist, vitality, elev, passable_land, is_water)

func _score_caption(v: float) -> String:
	return _Geography_delegate._score_caption(self, v)

func _score_color(v: float) -> Color:
	return _Geography_delegate._score_color(self, v)

func _terrain(cell: HexCell, idx: int) -> int:
	return _Geography_delegate._terrain(self, cell, idx)

func _landform(cell: HexCell, idx: int) -> int:
	return _Geography_delegate._landform(self, cell, idx)

func _vegetation(cell: HexCell, idx: int) -> int:
	return _Geography_delegate._vegetation(self, cell, idx)

func _cover(cell: HexCell, idx: int) -> int:
	return _Geography_delegate._cover(self, cell, idx)

func _temp(cell: HexCell, idx: int) -> float:
	return _Geography_delegate._temp(self, cell, idx)

func _moisture(cell: HexCell, idx: int) -> float:
	return _Geography_delegate._moisture(self, cell, idx)

func _base_moisture(cell: HexCell, idx: int) -> float:
	return _Geography_delegate._base_moisture(self, cell, idx)

func _elevation(cell: HexCell, idx: int) -> float:
	return _Geography_delegate._elevation(self, cell, idx)

func _snow_cover(cell: HexCell, idx: int) -> float:
	return _Geography_delegate._snow_cover(self, cell, idx)

func _vitality(cell: HexCell, landform_v: int) -> float:
	return _Geography_delegate._vitality(self, cell, landform_v)

func _weather_intensity(cell: HexCell, idx: int) -> float:
	return _Geography_delegate._weather_intensity(self, cell, idx)

func _weather_name(cell: HexCell, idx: int) -> String:
	return _Geography_delegate._weather_name(self, cell, idx)

func _has_river(cell: HexCell, idx: int) -> bool:
	return _Geography_delegate._has_river(self, cell, idx)

func _ocean_current(cell: HexCell, idx: int) -> Vector2:
	return _Geography_delegate._ocean_current(self, cell, idx)

func _wind_vector(cell: HexCell, idx: int) -> Vector2:
	return _Geography_delegate._wind_vector(self, cell, idx)

func _wind_speed(cell: HexCell, idx: int) -> float:
	return _Geography_delegate._wind_speed(self, cell, idx)

func _upwelling(cell: HexCell, idx: int) -> float:
	return _Geography_delegate._upwelling(self, cell, idx)

func _adapter_float(method: String, idx: int, fallback: float) -> float:
	return _Geography_delegate._adapter_float(self, method, idx, fallback)

func _history_values(cell: HexCell) -> Array:
	return _Geography_delegate._history_values(self, cell)

func _temperature_chart(chart_id: String, title: String, idx: int, current_temp: float) -> Dictionary:
	return _Geography_delegate._temperature_chart(self, chart_id, title, idx, current_temp)

func _temperature_memory(idx: int, current_temp: float) -> Array:
	return _Geography_delegate._temperature_memory(self, idx, current_temp)

func _record_temperature_sample(idx: int, day_idx: int, value: float) -> void:
	return _Geography_delegate._record_temperature_sample(self, idx, day_idx, value)

func _current_sample_day() -> int:
	return _Geography_delegate._current_sample_day(self)

func _daily_delta_text(v: float) -> String:
	return _Geography_delegate._daily_delta_text(self, v)

func _sample_daily_delta(cache: Dictionary, key: String, value: float, day: int) -> float:
	return _Geography_delegate._sample_daily_delta(self, cache, key, value, day)

func _relative_sea_level_text(elev: float, sea: float) -> String:
	return _Geography_delegate._relative_sea_level_text(self, elev, sea)

func _resource_index_text(v: float) -> String:
	return _Geography_delegate._resource_index_text(self, v)

func _intensity_text(v: float) -> String:
	return _Geography_delegate._intensity_text(self, v)

func _cloud_band(v: float) -> String:
	return _Geography_delegate._cloud_band(self, v)

func _precip_band(v: float) -> String:
	return _Geography_delegate._precip_band(self, v)

func _cover_intensity_band(v: float) -> String:
	return _Geography_delegate._cover_intensity_band(self, v)

func _stress_band(v: float) -> String:
	return _Geography_delegate._stress_band(self, v)

static func resource_density_level(v: float) -> int:
	return _Geography.resource_density_level(v)

static func resource_density_band(v: float) -> String:
	return _Geography.resource_density_band(v)

func _history_badges(cell: HexCell) -> Array:
	return _Geography_delegate._history_badges(self, cell)

func _densify_series(source: Array, target_count: int) -> Array:
	return _Geography_delegate._densify_series(self, source, target_count)

func _dir_degrees_text(v: Vector2) -> String:
	return _Geography_delegate._dir_degrees_text(self, v)

func _vitality_band(v: float) -> String:
	return _Geography_delegate._vitality_band(self, v)

func _elevation_band(elev: float, sea: float) -> String:
	return _Geography_delegate._elevation_band(self, elev, sea)

static func temperature_band(t: float) -> String:
	return _Geography.temperature_band(t)

func _temperature_band(t: float) -> String:
	return _Geography_delegate._temperature_band(self, t)

func _moisture_band(m: float) -> String:
	return _Geography_delegate._moisture_band(self, m)

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
			"reason": "", "cell": cell_idx,
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
	var reset_targets: Array = []
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


func _tax_lanes_from_policy(
		policy: Dictionary,
		object_kind: String,
		item_id: String,
		editable: bool
) -> Array:
	return _ObjectDossiers._tax_lanes_from_policy(self, policy, object_kind, item_id, editable)


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


## 军事绑定来自 MapGenerator（E 接线）。没有它就整个页签不出现，见 build()。
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


const SATISFACTION_DIMENSION_EXPLANATIONS := [
	"热量与御寒的生理满足率；不足会限制综合满意度。",
	"基本生活实际消费相对生活目标的完整度；综合各项满足率与最短缺的一项，目标不随预算和物价缩减。",
	"实际享受到的舒适消费相对生活目标的满足率；存款不直接加分。",
	"实际享受到的奢侈与身份消费相对生活目标的满足率；存款不直接加分。",
	"近期收入相对长期收入基线的变化。",
	"剩余存款可支撑的基础生活月数。",
	"本期净税负相对毛收入的压力。",
	"本地聚落等级、国家技术进度和建成产业种类。",
]

const SATISFACTION_DIMENSION_NAMES := [
	"生存", "基本生活", "舒适", "奢侈", "收入增长", "储蓄", "税负", "社会发展",
]
