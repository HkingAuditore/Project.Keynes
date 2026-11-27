extends RefCounted

const OverviewHeader = preload("res://scripts/ui/cell_inspector/overview_header_projection.gd")

const FamilyCategory = preload("res://scripts/ui/cell_inspector/family_category.gd")

const OverviewEmployment = preload("res://scripts/ui/cell_inspector/overview_employment.gd")

const FamilyWorkspaceProjection = preload("res://scripts/ui/family_workspace_projection.gd")

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

func _build_header(host,
	off: Vector2i,
	terrain_v: int,
	landform_v: int,
	country_summary: Dictionary,
	population_summary: Dictionary = {},
	intel_visible: bool = true,
	_has_river: bool = false
) -> Dictionary:
	return OverviewHeader._build_header(host, off, terrain_v, landform_v, country_summary, population_summary, intel_visible, _has_river)


func _ownership_text(host, country_summary: Dictionary, intel_visible: bool) -> String:
	return OverviewHeader._ownership_text(host, country_summary, intel_visible)


func _kpis(host,
	intel_visible: bool,
	temp: float,
	moist: float,
	habitability: float,
	is_water: bool,
	population_summary: Dictionary,
	country_summary: Dictionary,
	cell_idx: int = -1
) -> Array:
	return OverviewHeader._kpis(host, intel_visible, temp, moist, habitability, is_water, population_summary, country_summary, cell_idx)


func _gdp_kpi(host, cell_idx: int) -> Dictionary:
	return OverviewHeader._gdp_kpi(host, cell_idx)


func _cell_composite_satisfaction(host, cell_idx: int) -> float:
	return OverviewHeader._cell_composite_satisfaction(host, cell_idx)


func _primary_resource_kpi(host, cell_idx: int, is_water: bool) -> Dictionary:
	return OverviewHeader._primary_resource_kpi(host, cell_idx, is_water)


func _overview_category(host, cell: HexCell, idx: int, cover_v: int) -> Dictionary:
	var h = host
	return {
		"metrics": [
			{"id": "overview_weather", "title": "当前天气", "value": h._Geography_delegate._weather_name(h, cell, idx), "subtitle": h._Geography_delegate._intensity_text(h, h._Geography_delegate._weather_intensity(h, cell, idx)), "accent": UITokens.WATER, "icon": "weather"},
			{"id": "overview_cover", "title": "地表覆盖", "value": CoverType.name_cn(cover_v), "subtitle": "", "accent": UITokens.GEO, "icon": "surface"},
		],
	}



func _geography_information_category(host,
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
	var h = host
	var geography = host._geography_category(cell, idx, terrain_v, elev, passable_land)
	var climate = host._Overview_delegate._climate_category(host, cell, idx, temp, moist, base_moist, wf)
	var hydrology = host._Overview_delegate._hydrology_category(host, cell, idx, wf, snow, is_water)
	var ecology = host._Overview_delegate._ecology_category(host, cell, idx, vegetation_v, vitality)
	if is_water:
		ecology["gauges"] = []
		ecology["metrics"] = (ecology.get("metrics", []) as Array).slice(0, 1)
	var physical_metrics = [
		{"id": "geography_landform", "title": "地貌", "value": LandformType.name_cn(landform_v), "subtitle": "", "accent": UITokens.GEO, "icon": "geo"},
	]
	physical_metrics.append_array(geography.get("metrics", []))
	if cover_v != CoverType.CV.NONE:
		physical_metrics.append({"id": "geography_cover", "title": "地表覆盖", "value": CoverType.name_cn(cover_v), "subtitle": "", "accent": UITokens.WATER, "icon": "surface"})
	# Keep the legacy metric id for live-patch compatibility, but render the
	# value in the climate section under its actual biome/climate-zone meaning.
	var climate_metrics: Array = [
		{"id": "geography_terrain", "title": "气候区", "value": TerrainType.terrain_name_cn(terrain_v), "subtitle": "", "accent": UITokens.CLIMATE, "icon": "climate"},
		{"id": "climate_weather", "title": "当前天气", "value": h._Geography_delegate._weather_name(h, cell, idx), "subtitle": "", "accent": UITokens.WATER, "icon": "weather"},
	]
	climate_metrics.append_array(climate.get("metrics", []))
	climate_metrics.append_array(hydrology.get("metrics", []))
	var climate_gauges: Array = climate.get("gauges", []).duplicate()
	climate_gauges.append_array(hydrology.get("gauges", []))
	var category = {
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
	host._Overview_delegate._append_bio_facts_to_geography(host, category, idx, host._resource_visibility_context(idx))
	return category



func _append_resources_to_geography(host, category: Dictionary, idx: int,
		is_water: bool) -> void:
	var h = host
	var visibility = host._resource_visibility_context(idx)
	var resource_section = host._resources_category(
		host._resource_state(idx, is_water, visibility), visibility)
	if resource_section.is_empty():
		return
	resource_section["id"] = "natural_resources"
	resource_section["title"] = "自然资源"
	resource_section["icon"] = "resource"
	resource_section["accent"] = UITokens.RESOURCE
	if resource_section.has("resource_rows"):
		var any_change = false
		for row in resource_section["resource_rows"]:
			if String((row as Dictionary).get("delta", "—")) != "—":
				any_change = true
				break
		var columns = [{"text": "丰度", "width": 40.0}, {"text": "储量", "width": 70.0}]
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

func _append_bio_facts_to_geography(host, category: Dictionary, idx: int,
		visibility: Dictionary = {}) -> void:
	var h = host
	var badges = host._cell_bio_badges(idx, visibility)
	if badges.is_empty():
		return
	var section = {
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



func _cell_bio_badges(host, idx: int, visibility: Dictionary = {}) -> Array:
	var h = host
	if host._map == null or idx < 0:
		return []
	var catalog = host._Overview_delegate._ensure_research_signal_catalog(host)
	if catalog.is_empty():
		return []
	if idx >= host._map.bio_occupancy_bits_arr.size():
		return []
	var bits = int(host._map.bio_occupancy_bits_arr[idx])
	if bits == 0:
		return []
	var kinds: PackedInt32Array = catalog.get("research_signal_kinds", PackedInt32Array())
	var names: PackedStringArray = catalog.get("research_signal_display_names", PackedStringArray())
	var signal_ids: PackedStringArray = catalog.get("research_signal_ids", PackedStringArray())
	var occupancy_bits: PackedInt32Array = catalog.get("research_signal_occupancy_bit", PackedInt32Array())
	var kind_count = mini(kinds.size(), mini(names.size(), mini(signal_ids.size(), occupancy_bits.size())))
	var enforce_discovery = bool(visibility.get("enforce_discovery", false))
	var technology_ids: PackedStringArray = visibility.get(
		"technology_ids", PackedStringArray())
	var technology_catalog = {}
	if enforce_discovery:
		technology_catalog = host._Overview_delegate._ensure_technology_catalog(host)
	var badges = []
	for signal_index in range(kind_count):
		if int(kinds[signal_index]) != ResearchSignalDefinition.Kind.BIO:
			continue
		var bit = int(occupancy_bits[signal_index])
		if bit < 0 or bit >= 32 or (bits & (1 << bit)) == 0:
			continue
		var signal_id = String(signal_ids[signal_index])
		if enforce_discovery and not TechnologyCatalog.signal_named_by_completed_technologies(
				signal_id, technology_ids, technology_catalog):
			continue
		var display_name = String(names[signal_index])
		if display_name.is_empty():
			continue
		badges.append({
			"id": signal_id,
			"text": display_name,
			"accent": UITokens.ECO,
		})
	return badges



func _ensure_research_signal_catalog(host, ) -> Dictionary:
	var h = host
	if not host._research_signal_catalog.is_empty():
		return host._research_signal_catalog
	var compiled: Dictionary = ResearchSignalCatalog.compile_native_catalog()
	if not bool(compiled.get("ok", false)):
		return {}
	host._research_signal_catalog = compiled
	return host._research_signal_catalog



func _ensure_technology_catalog(host, ) -> Dictionary:
	var h = host
	if not host._technology_catalog.is_empty():
		return host._technology_catalog
	var compiled: Dictionary = TechnologyCatalog.compile_native_catalog()
	if not bool(compiled.get("ok", false)):
		return {}
	host._technology_catalog = compiled
	return host._technology_catalog



func _rows_from_category(host, category: Dictionary, rows_key: String) -> Array:
	var h = host
	var rows: Array = category.get(rows_key, [])
	if not rows.is_empty():
		return rows
	for raw_section in category.get("sections", []):
		var section: Dictionary = raw_section
		rows = section.get(rows_key, [])
		if not rows.is_empty():
			return rows
	return []



func _geography_category(host, cell: HexCell, idx: int, terrain_v: int, elev: float, passable_land: bool) -> Dictionary:
	var h = host
	var feats = PackedStringArray()
	if h._has_river(cell, idx): feats.append("河流")
	if cell.has_volcano: feats.append("火山")
	var metrics = [{
		"id": "geography_passage",
		"title": "通行",
		"value": h._Overview_delegate._passage_text(h, passable_land, cell.passable_sea, terrain_v),
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
			{"id": "geography_elevation_gauge", "label": "海拔", "value": elev, "accent": UITokens.GEO, "marker": h._sea_level, "status_label": "海平面", "value_text": h._elevation_band(elev, h._sea_level), "tooltip": ""},
		],
	}



func _passage_text(host, passable_land: bool, passable_sea: bool, terrain_v: int) -> String:
	var h = host
	if not passable_land:
		return "可航行" if passable_sea else "无法通行"
	var cost = TerrainType.get_move_cost(terrain_v)
	var land = "平坦易行" if cost <= 1 else ("崎岖难行" if cost == 2 else "险峻难行")
	return "%s · 可通航" % land if passable_sea else land



func _climate_category(host, cell: HexCell, idx: int, temp: float, moist: float, base_moist: float, wf: Dictionary) -> Dictionary:
	var h = host
	return {
		"metrics": [
			{"id": "climate_precip", "title": "降水", "value": h._Geography_delegate._precip_band(h, float(wf["precip"])), "subtitle": "", "accent": UITokens.WATER, "icon": "weather"},
		],
		"gauges": [
			{"id": "climate_temp_gauge", "label": "气温", "value": temp, "accent": UITokens.CLIMATE, "status_label": "", "value_text": h._temperature_band(temp)},
			{"id": "climate_moisture_gauge", "label": "湿度", "value": moist, "accent": UITokens.WATER, "marker": base_moist, "status_label": "常年湿度", "value_text": h._moisture_band(moist), "tooltip": ""},
		],
		"charts": [h._Geography_delegate._temperature_chart(h, "climate_temperature", "近期气温", idx, temp)],
	}



func _hydrology_category(host, _cell: HexCell, _idx: int, _wf: Dictionary, snow: float, is_water: bool) -> Dictionary:
	var h = host
	var metrics = []
	if snow >= 0.05:
		metrics.append({"id": "hydrology_snow", "title": "海冰" if is_water else "积雪", "value": h._Geography_delegate._cover_intensity_band(h, snow), "subtitle": "", "accent": UITokens.WATER, "icon": "water"})
	return {"metrics": metrics, "gauges": []}



func _ecology_category(host, cell: HexCell, idx: int, vegetation_v: int, vitality: float) -> Dictionary:
	var h = host
	var stress_heat: float = h._Geography_delegate._adapter_float(h, "get_vegetation_heat_stress", idx, cell.vegetation_heat_stress)
	var stress_drought: float = h._Geography_delegate._adapter_float(h, "get_vegetation_drought_stress", idx, cell.vegetation_drought_stress)
	var stress_cold: float = h._Geography_delegate._adapter_float(h, "get_vegetation_cold_stress", idx, cell.vegetation_cold_stress)
	var regen: float = h._Geography_delegate._adapter_float(h, "get_vegetation_regen_score", idx, cell.vegetation_regen_score)
	var insights = []
	var stress_name = "热"
	var stress = stress_heat
	if stress_drought > stress:
		stress_name = "干旱"
		stress = stress_drought
	if stress_cold > stress:
		stress_name = "寒冷"
		stress = stress_cold
	var baseline_name = VegetationType.name_cn(cell.base_vegetation)
	var current_name = VegetationType.name_cn(vegetation_v)
	return {
		"insights": insights,
		"metrics": [
			{"id": "ecology_vegetation", "title": "当前植被", "value": current_name, "subtitle": "" if baseline_name == current_name else "未开发时为%s" % baseline_name, "accent": UITokens.ECO, "icon": "eco"},
			{"id": "ecology_pressure", "title": "主要压力", "value": "无明显压力" if stress < 0.20 else "%s胁迫%s" % [stress_name, h._Geography_delegate._stress_band(h, stress)], "subtitle": "", "accent": UITokens.RISK if stress >= 0.50 else UITokens.ACCENT, "icon": "warning"},
		],
		"gauges": [
			{"id": "ecology_vitality_gauge", "label": "植被活力", "value": vitality, "accent": UITokens.ECO, "status_label": "", "value_text": h._vitality_band(vitality)},
			{"id": "ecology_regen_gauge", "label": "恢复潜力", "value": regen, "accent": UITokens.ECO, "status_label": "", "value_text": h._vitality_band(regen)},
		],
		"charts": [{"id": "ecology_history", "title": "植被演替", "values": h._Geography_delegate._history_values(h, cell), "accent": UITokens.ECO}],
	}



func _resources_category(host, resource_state: Array, visibility: Dictionary = {}) -> Dictionary:
	var h = host
	var rows = []
	ResourceProfileRegistry.ensure_loaded()
	if ResourceProfileRegistry.count() <= 0:
		return {}
	if resource_state.is_empty():
		var gated = bool(visibility.get("enforce_discovery", false))
		if not gated:
			return {}
		return {"insights": [{
			"id": "resource_undiscovered",
			"text": "当前科技尚未识别此地资源。",
			"accent": UITokens.TEXT_MUTED,
			"icon": "resource",
		}]}
	var sorted = resource_state.duplicate()
	sorted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("rank", 0.0)) > float(b.get("rank", 0.0))
	)
	var visible_count = 0
	for data in sorted:
		var item: Dictionary = data
		if not bool(item.get("available", true)):
			continue
		var reserve = float(item.get("reserve", 0.0))
		var delta = float(item.get("delta", 0.0))
		var density = h.resource_density_band(float(item.get("density_ratio", 0.0)))
		rows.append({
			"id": String(item.get("id", item.get("name", "resource"))),
			"name": String(item.get("name", "资源")),
			"value": h._Geography_delegate._resource_index_text(h, reserve),
			"density": density,
			"delta": h._daily_delta_text(delta),
			"extractable": bool(item.get("extractable", true)),
			"accent": UITokens.RESOURCE,
			"icon": String(item.get("icon", "resource")),
			"visible": reserve > 0.000001,
		})
		if reserve > 0.000001:
			visible_count += 1
	if visible_count == 0:
		return {}
	return {"resource_rows": rows, "summary": "%d 种" % visible_count}



func _history_category(host, cell: HexCell) -> Dictionary:
	var h = host
	return {
		"insights": [],
		"charts": [
			{"id": "history_vegetation", "title": "近期植被序列", "values": h._Geography_delegate._history_values(h, cell), "accent": UITokens.ECO},
			h._Geography_delegate._temperature_chart(h, "history_temperature", "近期温度变化", int(cell.index), h._temp(cell, int(cell.index))),
		],
		"badges": h._Geography_delegate._history_badges(h, cell),
	}



static func _snapshot_pending(snapshot: Dictionary) -> bool:
	return bool(snapshot.get("busy", false)) or bool(snapshot.get("read_view_pending", false))



static func _pending_category() -> Dictionary:
	return {"data_pending": true, "insights": [{"id": "snapshot_pending",
		"text": "正在读取最新数据…", "accent": UITokens.TEXT_MUTED, "icon": "history"}]}



func _population_snapshot(host, cell_idx: int, include_details: bool = true) -> Dictionary:
	var h = host
	if h._generator == null or not h._generator.has_method("get_economy_facade"):
		return {}
	var facade = host._generator.get_economy_facade()
	if facade == null or not facade.has_method("population_cell_snapshot"):
		return {}
	return facade.population_cell_snapshot(cell_idx, include_details)



func _population_summary(host, cell_idx: int) -> Dictionary:
	var h = host
	if h._generator == null or not h._generator.has_method("get_economy_facade"):
		return {}
	var facade = host._generator.get_economy_facade()
	if facade == null or not facade.has_method("population_cell_summary"):
		return {}
	var summary: Dictionary = facade.population_cell_summary(cell_idx)
	if bool(summary.get("ok", false)):
		if host._population_summary_cache.size() > 256:
			host._population_summary_cache.clear()
			host._cell_composite_cache.clear()
		host._population_summary_cache[cell_idx] = summary
		return summary
	if bool(summary.get("busy", false)) or bool(summary.get("read_view_pending", false)):
		var cached: Dictionary = host._population_summary_cache.get(cell_idx, {})
		if not cached.is_empty():
			return cached
		summary["pending"] = true
	return summary



func _country_summary(host, cell_idx: int) -> Dictionary:
	var h = host
	if h._generator == null or not h._generator.has_method("get_country_facade"):
		return {"country_name": "无主之地"}
	var facade = host._generator.get_country_facade()
	if facade == null or not facade.has_method("cell_summary"):
		return {"country_name": "无主之地"}
	var summary: Dictionary = facade.cell_summary(cell_idx)
	return summary if bool(summary.get("ok", false)) else {"country_name": "无主之地"}


## 悬停卡复用的公开入口：「无主之地」文案与 pending 回退只允许一份实现。

func population_summary(host, cell_idx: int) -> Dictionary:
	var h = host
	return host._Overview_delegate._population_summary(host, cell_idx)



func country_summary(host, cell_idx: int) -> Dictionary:
	var h = host
	return host._Overview_delegate._country_summary(host, cell_idx)



func sample_day(host, ) -> int:
	var h = host
	return host._Geography_delegate._current_sample_day(host)



func _market_snapshot(host, cell_idx: int) -> Dictionary:
	var h = host
	if h._generator == null or not h._generator.has_method("get_economy_facade"):
		return {}
	var facade = host._generator.get_economy_facade()
	if facade == null or not facade.has_method("market_cell_snapshot"):
		return {}
	return facade.market_cell_snapshot(cell_idx)



func _building_snapshot(host, cell_idx: int) -> Dictionary:
	var h = host
	if h._generator == null or not h._generator.has_method("get_economy_facade"):
		return {}
	var facade = host._generator.get_economy_facade()
	if facade == null or not facade.has_method("building_cell_snapshot"):
		return {}
	return facade.building_cell_snapshot(cell_idx)



func _family_cell_snapshot(host, cell_idx: int) -> Dictionary:
	var h = host
	if h._generator == null or not h._generator.has_method("get_economy_facade"):
		return {}
	var facade = host._generator.get_economy_facade()
	if facade == null or not facade.has_method("family_cell_snapshot"):
		return {}
	return facade.family_cell_snapshot(cell_idx, 0, 64)



func _family_category(host, snapshot: Dictionary) -> Dictionary:
	return FamilyCategory._family_category(host, snapshot)


func _family_detail_fields(host, snapshot: Dictionary) -> Dictionary:
	return FamilyCategory._family_detail_fields(host, snapshot)


func _family_trait_rows(host, snapshot: Dictionary) -> Array:
	return FamilyCategory._family_trait_rows(host, snapshot)


func _family_behavior_rows(host, snapshot: Dictionary, cell_idx: int = -1) -> Array:
	return FamilyCategory._family_behavior_rows(host, snapshot, cell_idx)


static func family_behavior_rows_for_cell(snapshot: Dictionary, facade,
		cell_idx: int) -> Array:
	return FamilyCategory.family_behavior_rows_for_cell(snapshot, facade, cell_idx)


static func _family_behavior_rows_for_visibility(snapshot: Dictionary,
		visibility: Dictionary) -> Array:
	return FamilyCategory._family_behavior_rows_for_visibility(snapshot, visibility)


static func _family_behavior_icon(axis: int, stable_id: String, name_text: String = "") -> StringName:
	return FamilyCategory._family_behavior_icon(axis, stable_id, name_text)


func _family_behavior_visibility(host, cell_idx: int) -> Dictionary:
	return FamilyCategory._family_behavior_visibility(host, cell_idx)


static func _family_behavior_visibility_for_cell(facade, cell_idx: int) -> Dictionary:
	return FamilyCategory._family_behavior_visibility_for_cell(facade, cell_idx)


static func _family_behavior_visible_professions(buildings: Dictionary,
		population: Dictionary) -> Dictionary:
	return FamilyCategory._family_behavior_visible_professions(buildings, population)


static func _add_profession_id(target: Dictionary, catalog: PackedStringArray,
		dense_id: int) -> void:
	FamilyCategory._add_profession_id(target, catalog, dense_id)


static func _family_behavior_visible_needs(catalog: Dictionary,
		market_good_ids: PackedStringArray,
		good_available: PackedByteArray) -> Dictionary:
	return FamilyCategory._family_behavior_visible_needs(catalog, market_good_ids, good_available)


static func _family_behavior_selector_visible(axis: int, stable_id: String,
		visibility: Dictionary) -> bool:
	return FamilyCategory._family_behavior_selector_visible(axis, stable_id, visibility)


func _family_branch_rows(host, snapshot: Dictionary) -> Array:
	return FamilyCategory._family_branch_rows(host, snapshot)


func _family_bound_effect_rows(host, snapshot: Dictionary) -> Array:
	return FamilyCategory._family_bound_effect_rows(host, snapshot)


func _family_modifier_rows(host, snapshot: Dictionary) -> Array:
	return FamilyCategory._family_modifier_rows(host, snapshot)


func _family_trigger_rows(host, snapshot: Dictionary) -> Array:
	return FamilyCategory._family_trigger_rows(host, snapshot)


static func _prestige_text(level: int) -> String:
	return FamilyCategory._prestige_text(level)


static func _q16_percent_text(value: int) -> String:
	return FamilyCategory._q16_percent_text(value)


func _family_notable_person_rows(host, facade, family_handle: int) -> Array:
	return FamilyCategory._family_notable_person_rows(host, facade, family_handle)
