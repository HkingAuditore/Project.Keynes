class_name CellInspectorViewModel
extends RefCounted

const LiveProjection = preload("res://scripts/ui/cell_inspector_live_projection.gd")

const TaxProjection = preload("res://scripts/ui/cell_inspector_tax.gd")

const MaintenancePresentation = preload("res://scripts/ui/military_maintenance_presentation.gd")

const ConstructionFoldState = preload("res://scripts/ui/cell_inspector/construction_fold_state.gd")

const PopulationPresentation = preload("res://scripts/ui/cell_inspector/population_presentation.gd")
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
	return PopulationPresentation._local_gdp(_gdp_ledger, cell_idx)


func observe_temperature(cell: HexCell, day_idx: int = -1) -> void:
	if cell == null or _map == null:
		return
	var idx := int(cell.index)
	_Geography_delegate._record_temperature_sample(self,
		idx,
		day_idx if day_idx >= 0 else _Geography_delegate._current_sample_day(self),
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
	return LiveProjection.build(self, cell)


func _build_unexplored_model(cell: HexCell) -> Dictionary:
	return LiveProjection._build_unexplored_model(self, cell)


func drawn_cell_summary(cell: HexCell) -> Dictionary:
	return LiveProjection.drawn_cell_summary(self, cell)


func live_patch_revision(cell: HexCell, current_tab: String) -> Dictionary:
	return LiveProjection.live_patch_revision(self, cell, current_tab)


func build_live_patch(
		cell: HexCell,
		current_tab: String,
		include_category: bool = true,
		population_summary_override: Dictionary = {},
		include_details: bool = true
) -> Dictionary:
	return LiveProjection.build_live_patch(self, cell, current_tab, include_category, population_summary_override, include_details)


func build_tab_category(cell: HexCell, tab_id: String) -> Dictionary:
	return LiveProjection.build_tab_category(self, cell, tab_id)


func _build_tab_category(cell: HexCell, tab_id: String) -> Dictionary:
	return LiveProjection._build_tab_category(self, cell, tab_id)


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

func _military_barracks_count(snapshot: Dictionary) -> int:
	return _Military_delegate._military_barracks_count(self, snapshot)

func _country_cash() -> int:
	return _Military_delegate._country_cash(self)



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

## 悬停与地理档案共用占据位、名称和科技识别规则。
func local_species_badges(idx: int, technology_ids: PackedStringArray) -> Array:
	return _cell_bio_badges(idx, {
		"enforce_discovery": true, "technology_ids": technology_ids,
	})


func _cell_bio_badges(idx: int, visibility: Dictionary = {}) -> Array:
	return _Overview_delegate._cell_bio_badges(self, idx, visibility)

func _geography_category(cell: HexCell, idx: int, terrain_v: int, elev: float, passable_land: bool) -> Dictionary:
	return _Overview_delegate._geography_category(self, cell, idx, terrain_v, elev, passable_land)

func _resources_category(resource_state: Array, visibility: Dictionary = {}) -> Dictionary:
	return _Overview_delegate._resources_category(self, resource_state, visibility)

static func _snapshot_pending(snapshot: Dictionary) -> bool:
	return _Overview._snapshot_pending(snapshot)

static func _pending_category() -> Dictionary:
	return _Overview._pending_category()

func population_summary(cell_idx: int) -> Dictionary:
	return _Overview_delegate.population_summary(self, cell_idx)

func country_summary(cell_idx: int) -> Dictionary:
	return _Overview_delegate.country_summary(self, cell_idx)

func sample_day() -> int:
	return _Overview_delegate.sample_day(self)

func _family_category(snapshot: Dictionary) -> Dictionary:
	return _Overview_delegate._family_category(self, snapshot)

func _family_behavior_rows(snapshot: Dictionary, cell_idx: int = -1) -> Array:
	return _Overview_delegate._family_behavior_rows(self, snapshot, cell_idx)

static func family_behavior_rows_for_cell(snapshot: Dictionary, facade,
		cell_idx: int) -> Array:
	return _Overview.family_behavior_rows_for_cell(snapshot, facade, cell_idx)

static func _family_behavior_icon(axis: int, stable_id: String, name_text: String = "") -> StringName:
	return _Overview._family_behavior_icon(axis, stable_id, name_text)

func _family_behavior_visibility(cell_idx: int) -> Dictionary:
	return _Overview_delegate._family_behavior_visibility(self, cell_idx)

static func _family_behavior_selector_visible(axis: int, stable_id: String,
		visibility: Dictionary) -> bool:
	return _Overview._family_behavior_selector_visible(axis, stable_id, visibility)

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

func _population_category(snapshot: Dictionary, market_snapshot: Dictionary = {},
		cell_idx: int = -1) -> Dictionary:
	return _PopulationMarket_delegate._population_category(self, snapshot, market_snapshot, cell_idx)

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

func _satisfaction_dimension_rows(dims: PackedInt32Array, dimension_count: int,
		cohort_idx: int, worst_dimension: int) -> Array:
	return _PopulationMarket_delegate._satisfaction_dimension_rows(self, dims, dimension_count, cohort_idx, worst_dimension)

func _satisfaction_accent(value: float) -> Color:
	return _PopulationMarket_delegate._satisfaction_accent(self, value)

func _market_category(snapshot: Dictionary) -> Dictionary:
	return _PopulationMarket_delegate._market_category(self, snapshot)

func trade_orders_model(cell_idx: int, good_id: String, offset: int = 0,
		limit: int = TRADE_ORDER_PAGE_SIZE, generation: int = -1,
		sample_day: int = -1) -> Dictionary:
	return _PopulationMarket_delegate.trade_orders_model(self, cell_idx, good_id, offset, limit, generation, sample_day)

func _economy_facade():
	return _PopulationMarket_delegate._economy_facade(self)

func _building_category(snapshot: Dictionary, cell_idx: int = -1) -> Dictionary:
	return _Construction_delegate._building_category(self, snapshot, cell_idx)

func build_construction_entry(cell_idx: int) -> Dictionary:
	return _Construction_delegate.build_construction_entry(self, cell_idx)

func build_construction_model(cell_idx: int, sector_id: String = "",
		search: String = "", sort_id: String = "recommended",
		offset: int = 0) -> Dictionary:
	return _Construction_delegate.build_construction_model(self, cell_idx, sector_id, search, sort_id, offset)

func _country_allows_treasury_construction(summary: Dictionary) -> bool:
	return _Construction.country_allows_treasury_construction(summary)


var _construction_folds = ConstructionFoldState.new()


func _construction_fold_state() -> Dictionary:
	return _construction_folds.snapshot()


func toggle_construction_fold(action: Dictionary) -> bool:
	return _construction_folds.toggle(action)


func _construction_page_rows(entries: Array, quotes: Dictionary,
		snapshot: Dictionary, economy, market: Dictionary,
		maturity_names: PackedStringArray) -> Array:
	return _Construction_delegate._construction_page_rows(self, entries, quotes, snapshot, economy, market, maturity_names)

func _construction_local_stock(market: Dictionary) -> Dictionary:
	return _Construction_delegate._construction_local_stock(self, market)

func _unlocked_good_ids(snapshot: Dictionary) -> Dictionary:
	return _Construction_delegate._unlocked_good_ids(self, snapshot)

func _construction_reason_text(code: String, materials: Array, local_stock: Dictionary) -> String:
	return _Construction_delegate._construction_reason_text(self, code, materials, local_stock)

func _construction_material_status_rows(materials: Array, local_stock: Dictionary) -> Array:
	return _Construction_delegate._construction_material_status_rows(self, materials, local_stock)

func _construction_materials_text(materials: Array) -> String:
	return _Construction_delegate._construction_materials_text(self, materials)

func _construction_tooltip(entry: Dictionary, item: Dictionary, materials: Array,
		local_stock: Dictionary, placement: Dictionary, job_spec: Dictionary,
		unlocked_goods: Dictionary, days: int, maturity: String, reason_text: String) -> String:
	return _Construction_delegate._construction_tooltip(self, entry, item, materials, local_stock,
		placement, job_spec, unlocked_goods, days, maturity, reason_text)

func _format_input_candidate_label(good_id: String, efficiency_q16: int) -> String:
	return _Construction_delegate._format_input_candidate_label(self, good_id, efficiency_q16)

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

func _construction_profession_name(profession_id: String) -> String:
	return _Construction_delegate._construction_profession_name(self, profession_id)

func _building_icon(type_id: String, snapshot: Dictionary = {}, type_idx: int = -1) -> StringName:
	return _Construction_delegate._building_icon(self, type_id, snapshot, type_idx)

func _good_display_name(stable_id: String) -> String:
	return _Construction_delegate._good_display_name(self, stable_id)

func _resource_display_name(stable_id: String) -> String:
	return _Construction_delegate._resource_display_name(self, stable_id)

func _sum_i64(values: PackedInt64Array) -> int:
	return _Construction_delegate._sum_i64(self, values)

func _money_text(subunits: int) -> String:
	return _Construction_delegate._money_text(self, subunits)

func _weather_field(cell: HexCell, idx: int) -> Dictionary:
	return _Geography_delegate._weather_field(self, cell, idx)

func _resource_visibility_context(cell_idx: int) -> Dictionary:
	return _Geography_delegate._resource_visibility_context(self, cell_idx)

func player_technology_ids() -> PackedStringArray:
	return _Geography_delegate.player_technology_ids(self)

func _resource_state(idx: int, is_water: bool, visibility: Dictionary = {}) -> Array:
	return _Geography_delegate._resource_state(self, idx, is_water, visibility)

func _resource_reserve(profile, idx: int) -> float:
	return _Geography_delegate._resource_reserve(self, profile, idx)

func _landform(cell: HexCell, idx: int) -> int:
	return _Geography_delegate._landform(self, cell, idx)

func _cover(cell: HexCell, idx: int) -> int:
	return _Geography_delegate._cover(self, cell, idx)

func _temp(cell: HexCell, idx: int) -> float:
	return _Geography_delegate._temp(self, cell, idx)

func _elevation(cell: HexCell, idx: int) -> float:
	return _Geography_delegate._elevation(self, cell, idx)

func _has_river(cell: HexCell, idx: int) -> bool:
	return _Geography_delegate._has_river(self, cell, idx)

func _daily_delta_text(v: float) -> String:
	return _Geography_delegate._daily_delta_text(self, v)

func _sample_daily_delta(cache: Dictionary, key: String, value: float, day: int) -> float:
	return _Geography_delegate._sample_daily_delta(self, cache, key, value, day)

static func resource_density_level(v: float) -> int:
	return _Geography.resource_density_level(v)

static func resource_density_band(v: float) -> String:
	return _Geography.resource_density_band(v)

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
	return TaxProjection._decorate_category_with_tax(self, cell_idx, tab_id, category)


func _tax_context_for_cell(cell_idx: int, kinds: Array) -> Dictionary:
	return TaxProjection._tax_context_for_cell(self, cell_idx, kinds)


func _tax_lanes_from_policy(
		policy: Dictionary,
		object_kind: String,
		item_id: String,
		editable: bool
) -> Array:
	return TaxProjection._tax_lanes_from_policy(self, policy, object_kind, item_id, editable)


# 弹窗标题永远是用户可读名：行内 name 缺失或退化为原始 stable id 时，
# 用最新人口快照的平行数组把 profession_id 翻译回本地化名；仍失败才落到类型名。
func _object_display_name(kind: String, row: Dictionary, cell_idx: int) -> String:
	var name := String(row.get("name", ""))
	if kind == "cohort":
		var profession_id := String(row.get("profession_id", ""))
		if name.is_empty() or name == profession_id:
			var localized := _profession_name_for_id(_Overview_delegate._population_snapshot(self, cell_idx), profession_id)
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
	var country := _Overview_delegate._country_summary(self, cell_idx)
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
			var summary := _Overview_delegate._country_summary(self, start_cell)
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
