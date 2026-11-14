extends RefCounted

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
	var h = host
	# terrain_v is the legacy-stable bioclimatic/biome axis. Keep its value in
	# the compact header; the detailed climate-zone label lives in the geography tab.
	var land_title = "%s · %s" % [
		LandformType.name_cn(landform_v), TerrainType.terrain_name_cn(terrain_v)]
	var title = land_title
	var meta = PackedStringArray()
	meta.append(host._ownership_text(country_summary, intel_visible))
	if bool(population_summary.get("settlement_name_active", false)):
		title = "%s · %s" % [
			String(population_summary.get("settlement_name", "")),
			String(population_summary.get("prosperity_name", ""))]
		# 地名已经交代“这是什么地方”，地形/地貌/临河都在默认打开的「地理」页里，
		# 副标题只留归属，不再把地理栏抄一遍。
	if not intel_visible:
		meta.append("视野之外 · 仅存地理记忆")
	return {
		"kicker": "区域 %d, %d" % [off.x + 1, off.y + 1],
		"title": title,
		"subtitle": " · ".join(meta),
	}



func _ownership_text(host, country_summary: Dictionary, intel_visible: bool) -> String:
	var h = host
	if not intel_visible:
		return "归属未知"
	if not bool(country_summary.get("owned", false)):
		return "无主之地"
	var country_name = String(country_summary.get("country_name", "未知国家"))
	if int(country_summary.get("country_handle", -1)) == h._player_country_handle():
		return "%s · 本国领土" % country_name
	return country_name


## 页头四格 KPI：有人定居看民生（人口/GDP/满意度/就业率），
## 无人之地看开拓价值（适宜度/潜在承载/气候/归属）。

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
	var h = host
	var climate_kpi = {
		"id": "kpi_climate", "title": "气候", "icon": &"climate.sun", "kind": "text",
		"text": h._temperature_band(temp), "caption": h._moisture_band(moist),
		"tooltip": "气温 %s · 湿度 %s" % [h._temperature_band(temp), h._moisture_band(moist)],
	}
	var suitability_kpi = {
		"id": "kpi_suitability", "title": "适宜度", "icon": &"summary.overview",
		"kind": "percent", "value": habitability, "caption": h._score_caption(habitability),
		"tooltip": "由气温、湿度、植被活力、海拔与通行综合估算的定居条件。",
	}
	if not intel_visible:
		return [suitability_kpi, climate_kpi, {
			"id": "kpi_intel", "title": "情报", "icon": &"system.unknown", "kind": "text",
			"text": "视野之外", "caption": "人口与市场未知",
		}]
	var population = int(population_summary.get("population", 0))
	var carrying = int(population_summary.get("carrying_k_eff", 0))
	var ownership = host._ownership_text(country_summary, true)
	if bool(population_summary.get("pending", false)):
		return [suitability_kpi, climate_kpi, {
			"id": "kpi_owner", "title": "归属", "icon": &"metric.territory", "kind": "text",
			"text": String(country_summary.get("country_name", "无主之地")) \
				if bool(country_summary.get("owned", false)) else "无主",
			"caption": ownership, "tooltip": ownership,
		}, {
			"id": "kpi_population", "title": "人口", "icon": &"family.metric.population", "kind": "text",
			"text": "读取中", "caption": "下一日刷新",
		}]
	if population <= 0 or not bool(population_summary.get("ok", false)):
		var owned = bool(country_summary.get("owned", false))
		var prospect_kpi = {
			"id": "kpi_carrying", "title": "潜在承载", "icon": &"ecology.growth",
			"kind": "count", "value": float(carrying), "caption": "",
			"tooltip": "按本地粮食产能估算，此地最多能养活的人口。",
		}
		if carrying <= 0:
			prospect_kpi = host._primary_resource_kpi(cell_idx, is_water)
		return [suitability_kpi, prospect_kpi, climate_kpi, {
			"id": "kpi_owner", "title": "归属", "icon": &"metric.territory", "kind": "text",
			"text": String(country_summary.get("country_name", "无主之地")) if owned else "无主",
			"caption": "" if owned else "可开拓",
			"tooltip": ownership,
		}]
	var jobs_capacity = int(population_summary.get("job_capacity", 0))
	var jobs_filled = int(population_summary.get("jobs_filled", 0))
	var employed_population = int(population_summary.get("employed_population", 0))
	var unemployed_population = int(population_summary.get("unemployed_population", 0))
	var openings = int(population_summary.get("job_openings", 0))
	# 页头与全国经济、阶层、城市、年度报告用同一个口径：人口就业率。
	# 综合不可读时才退回 cell summary 的生存值，并在提示里说明口径。
	var survival_q16 = int(population_summary.get("satisfaction_q16", 0))
	var composite = host._cell_composite_satisfaction(cell_idx)
	var satisfaction = composite if composite >= 0.0 else float(survival_q16) / 65536.0
	var satisfaction_tooltip = "综合满意度：生存、基本生活、舒适、奢侈、收入、储蓄、税负、社会发展八维按人口加权。生存与基本生活不足会限制总分；有相应需求的阶层，还需改善舒适和奢侈生活才能获得高分。当前生存 %s，分项见「人口」页。" % h._q16_percent_text(survival_q16)
	if composite < 0.0:
		satisfaction_tooltip = "生存满意度（综合满意度暂不可读）：口粮与御寒衣着两项里较差的那一项，不含舒适与奢侈需求。"
	var over_capacity = carrying > 0 and population > carrying
	var carrying_text = UITokens.format_compact_number_cn(float(carrying), 1)
	# 页头四格是玩家扫一眼就要读懂的四件事：人头、产值、满意度、就业率。
	# 标签压到最短（2~3 字），口径全放进悬停提示，卡面只留大数字和一行副行。
	return [{
		"id": "kpi_population", "title": "人口", "icon": &"family.metric.population",
		"kind": "count", "value": float(population),
		"caption": "超承载 %s" % carrying_text if over_capacity else "",
		"tooltip": "本格各阶层人口合计 %d 人。%s" % [population,
			"已超出本地粮食承载 %s 人。" % carrying_text if over_capacity
			else "本地粮食可承载 %s 人。" % carrying_text],
	}, host._gdp_kpi(cell_idx), {
		"id": "kpi_satisfaction", "title": "满意度", "icon": &"population.heart",
		"kind": "percent", "value": satisfaction,
		"caption": "" if satisfaction >= 0.85 else (
			"勉强维持" if satisfaction >= 0.6 else "生计困难"),
		"tone": "risk" if satisfaction < 0.6 else "",
		"tooltip": satisfaction_tooltip,
	}, {
		"id": "kpi_jobs", "title": "就业率", "icon": &"population.profession.worker",
		"kind": "percent" if population_summary.get("population", 0) > 0 else "text",
		"value": float(employed_population) / float(population_summary.get("population", 0)) \
			if int(population_summary.get("population", 0)) > 0 else 0.0,
		"text": "无人",
		"caption": "失业 %s 人" % UITokens.format_compact_number_cn(float(unemployed_population), 1) \
			if unemployed_population > 0 else "",
		"tooltip": "已就业 %d / 人口 %d；岗位已到岗 %d / 岗位 %d，空缺 %d。" % [
			employed_population, int(population_summary.get("population", 0)),
			jobs_filled, jobs_capacity, openings],
	}]


## 页头 GDP：本地年内累计产值。年度产值账本未就绪、或这块地不在本国聚落表里
## （他国城市、无产值聚落）时给「—」，不编 0——0 会被读成「本地确实没有产出」。
## 金额只给数字，金币图标由卡面按 kind == "money" 画。

func _gdp_kpi(host, cell_idx: int) -> Dictionary:
	var h = host
	var gdp = host._local_gdp(cell_idx)
	if gdp.is_empty():
		return {
			"id": "kpi_gdp", "title": "GDP", "icon": &"metric.treasury",
			"kind": "text", "text": "—", "caption": "统计中",
			"tooltip": "本地年内累计产值，按已提交的经济周期累计；首个结算周期完成前显示「—」。",
		}
	var ytd = float(gdp.get("ytd", 0.0)) / h.MONEY_SCALE
	var per_day = float(gdp.get("per_day", 0.0)) / h.MONEY_SCALE
	var days = int(gdp.get("days_counted", 0))
	var days_per_year = maxi(1, int(gdp.get("days_per_year", 365)))
	var per_day_text = UITokens.format_compact_number_cn(per_day, 1)
	return {
		"id": "kpi_gdp", "title": "GDP", "icon": &"metric.treasury",
		"kind": "money", "value": ytd, "decimals": 0,
		"caption": "日均 %s" % per_day_text,
		"tooltip": "本地年内累计产值（已计 %d/%d 天）。收入法：建筑营收 − 中间投入 − 维护 = 工资 + 营业盈余，不含营业税。日均 %s。" % [days, days_per_year, per_day_text],
	}


## 格级综合满意度（人口加权八维，已按实际适用的生活条件封顶）。走原生只读聚合接口，
## 只遍历本格 cohort，且同一已提交状态内由 read view 缓存，页头每日刷新不额外开扫描。
## 不可用时返回 -1.0，调用方退回生存口径并在提示里说明。

func _cell_composite_satisfaction(host, cell_idx: int) -> float:
	var h = host
	if cell_idx < 0:
		return -1.0
	var facade = host._economy_facade()
	if facade == null or not facade.has_method("cell_satisfaction_attractiveness"):
		return -1.0
	var attractiveness: Dictionary = facade.cell_satisfaction_attractiveness(cell_idx)
	if bool(attractiveness.get("ok", false)):
		var q16 = int(attractiveness.get("composite_q16", -1))
		if q16 >= 0:
			var value = clampf(float(q16) / 65536.0, 0.0, 1.0)
			if host._cell_composite_cache.size() > 256:
				host._cell_composite_cache.clear()
			host._cell_composite_cache[cell_idx] = value
			return value
	# 忙时/首次结算前沿用上次成功值；真的没有就退回生存口径。
	return float(host._cell_composite_cache.get(cell_idx, -1.0))



func _primary_resource_kpi(host, cell_idx: int, is_water: bool) -> Dictionary:
	var h = host
	var kpi = {"id": "kpi_resource", "title": "主要资源", "icon": &"economy.resource",
		"kind": "text", "text": "", "caption": ""}
	if cell_idx < 0:
		return kpi
	var best: Dictionary = {}
	var visible_count = 0
	for raw in host._resource_state(cell_idx, is_water, host._resource_visibility_context(cell_idx)):
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



func _overview_category(host, cell: HexCell, idx: int, cover_v: int) -> Dictionary:
	var h = host
	return {
		"metrics": [
			{"id": "overview_weather", "title": "当前天气", "value": h._weather_name(cell, idx), "subtitle": h._intensity_text(h._weather_intensity(cell, idx)), "accent": UITokens.WATER, "icon": "weather"},
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
	var climate = host._climate_category(cell, idx, temp, moist, base_moist, wf)
	var hydrology = host._hydrology_category(cell, idx, wf, snow, is_water)
	var ecology = host._ecology_category(cell, idx, vegetation_v, vitality)
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
		{"id": "climate_weather", "title": "当前天气", "value": h._weather_name(cell, idx), "subtitle": "", "accent": UITokens.WATER, "icon": "weather"},
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
	host._append_bio_facts_to_geography(category, idx, host._resource_visibility_context(idx))
	return category



func _append_resources_to_geography(host, category: Dictionary, idx: int,
		is_water: bool) -> void:
	var h = host
	var visibility = host._resource_visibility_context(idx)
	var resource_section = host._resources_category(
		host._resource_state(idx, is_water, visibility), visibility)
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
	var catalog = host._ensure_research_signal_catalog()
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
		technology_catalog = host._ensure_technology_catalog()
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
		"value": h._passage_text(passable_land, cell.passable_sea, terrain_v),
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
			{"id": "climate_precip", "title": "降水", "value": h._precip_band(float(wf["precip"])), "subtitle": "", "accent": UITokens.WATER, "icon": "weather"},
		],
		"gauges": [
			{"id": "climate_temp_gauge", "label": "气温", "value": temp, "accent": UITokens.CLIMATE, "status_label": "", "value_text": h._temperature_band(temp)},
			{"id": "climate_moisture_gauge", "label": "湿度", "value": moist, "accent": UITokens.WATER, "marker": base_moist, "status_label": "常年湿度", "value_text": h._moisture_band(moist), "tooltip": ""},
		],
		"charts": [h._temperature_chart("climate_temperature", "近期气温", idx, temp)],
	}



func _hydrology_category(host, _cell: HexCell, _idx: int, _wf: Dictionary, snow: float, is_water: bool) -> Dictionary:
	var h = host
	var metrics = []
	if snow >= 0.05:
		metrics.append({"id": "hydrology_snow", "title": "海冰" if is_water else "积雪", "value": h._cover_intensity_band(snow), "subtitle": "", "accent": UITokens.WATER, "icon": "water"})
	return {"metrics": metrics, "gauges": []}



func _ecology_category(host, cell: HexCell, idx: int, vegetation_v: int, vitality: float) -> Dictionary:
	var h = host
	var stress_heat: float = h._adapter_float("get_vegetation_heat_stress", idx, cell.vegetation_heat_stress)
	var stress_drought: float = h._adapter_float("get_vegetation_drought_stress", idx, cell.vegetation_drought_stress)
	var stress_cold: float = h._adapter_float("get_vegetation_cold_stress", idx, cell.vegetation_cold_stress)
	var regen: float = h._adapter_float("get_vegetation_regen_score", idx, cell.vegetation_regen_score)
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
			{"id": "ecology_pressure", "title": "主要压力", "value": "无明显压力" if stress < 0.20 else "%s胁迫%s" % [stress_name, h._stress_band(stress)], "subtitle": "", "accent": UITokens.RISK if stress >= 0.50 else UITokens.ACCENT, "icon": "warning"},
		],
		"gauges": [
			{"id": "ecology_vitality_gauge", "label": "植被活力", "value": vitality, "accent": UITokens.ECO, "status_label": "", "value_text": h._vitality_band(vitality)},
			{"id": "ecology_regen_gauge", "label": "恢复潜力", "value": regen, "accent": UITokens.ECO, "status_label": "", "value_text": h._vitality_band(regen)},
		],
		"charts": [{"id": "ecology_history", "title": "植被演替", "values": h._history_values(cell), "accent": UITokens.ECO}],
	}



func _resources_category(host, resource_state: Array, visibility: Dictionary = {}) -> Dictionary:
	var h = host
	var rows = []
	ResourceProfileRegistry.ensure_loaded()
	if ResourceProfileRegistry.count() <= 0:
		return {"insights": [{
			"id": "resource_unconfigured",
			"text": "尚未配置自然资源类型。",
			"accent": UITokens.TEXT_MUTED,
			"icon": "resource",
		}]}
	if resource_state.is_empty():
		var gated = bool(visibility.get("enforce_discovery", false))
		return {"insights": [{
			"id": "resource_undiscovered" if gated else "resource_empty",
			"text": "当前科技尚未识别此地资源。" if gated \
				else "此地块当前无可显示自然资源。",
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
			"value": h._resource_index_text(reserve),
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
		return {
			"insights": [{"id": "resource_empty", "text": "此地块当前无可显示自然资源。", "accent": UITokens.TEXT_MUTED, "icon": "resource"}],
			"resource_rows": rows,
		}
	return {"resource_rows": rows, "summary": "%d 种" % visible_count}



func _history_category(host, cell: HexCell) -> Dictionary:
	var h = host
	return {
		"insights": [],
		"charts": [
			{"id": "history_vegetation", "title": "近期植被序列", "values": h._history_values(cell), "accent": UITokens.ECO},
			h._temperature_chart("history_temperature", "近期温度变化", int(cell.index), h._temp(cell, int(cell.index))),
		],
		"badges": h._history_badges(cell),
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
	return host._population_summary(cell_idx)



func country_summary(host, cell_idx: int) -> Dictionary:
	var h = host
	return host._country_summary(cell_idx)



func sample_day(host, ) -> int:
	var h = host
	return host._current_sample_day()



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
	var h = host
	if host._snapshot_pending(snapshot):
		return host._pending_category()
	if snapshot.is_empty() or not bool(snapshot.get("ok", false)):
		return {"insights": [{"id": "families_unavailable", "text":
			"家族情报：无", "accent": UITokens.TEXT_MUTED,
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
	var source_cell = int(snapshot.get("cell_idx", -1))
	var country = host._country_summary(source_cell) if source_cell >= 0 else {}
	var player_owned = bool(country.get("owned", false)) \
		and int(country.get("country_handle", 0)) == h._player_country_handle()
	for i in range(surnames.size()):
		var suffix = "" if i >= disambiguators.size() or disambiguators[i] == 0 \
			else "（%d）" % (int(disambiguators[i]) + 1)
		var family_handle = int(handles[i]) if i < handles.size() else 0
		var display_name = String(family_names[i]).strip_edges() \
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
			"cash_claim": h._money_text(int(cash_claims[i])) if i < cash_claims.size() else h._money_text(0),
			"prestige": h._prestige_text(int(prestige_levels[i])) \
				if i < prestige_levels.size() else "0",
			"accent": UITokens.ACCENT,
			"icon": "family.house",
		})
	if rows.is_empty():
		return {"insights": [{"id": "families_empty", "text":
			"显赫家族：无",
			"accent": UITokens.TEXT_MUTED, "icon": "family.house"}]}
	if rows.is_empty():
		return {"insights": [{"id": "families_empty", "text": "显赫家族：无",
			"accent": UITokens.TEXT_MUTED, "icon": "family.house"}], "family_rows": rows}
	return {"family_rows": rows, "list_header": {"lead": "家族 · 族人 · 产业",
		"indent": 41.0, "columns": [{"text": "威望", "width": 64.0}]}}



func _family_detail_fields(host, snapshot: Dictionary) -> Dictionary:
	var h = host
	return {
		"population": UITokens.format_compact_number_cn(float(snapshot.get("population", 0)), 1),
		"cash_claim": h._money_text(int(snapshot.get("cash_claim", 0))),
		"productive_asset_value": h._money_text(int(snapshot.get("building_asset_value",
			snapshot.get("productive_asset_value", 0)))),
		"net_worth": h._money_text(int(snapshot.get("net_worth", 0))),
		"owned_buildings": UITokens.format_compact_number_cn(float(snapshot.get("owned_buildings", 0)), 1),
		"notable_people": int(snapshot.get("notable_person_count", 0)),
		"founded_day": int(snapshot.get("founded_day", 0)),
		"decline_reviews": int(snapshot.get("decline_reviews", 0)),
		"origin_cell": int(snapshot.get("origin_cell", -1)),
		"origin_settlement_name": String(snapshot.get("origin_settlement_name", "")),
	}



func _family_trait_rows(host, snapshot: Dictionary) -> Array:
	var h = host
	var rows: Array = []
	var names: PackedStringArray = snapshot.get("display_names", PackedStringArray())
	var keys: PackedStringArray = snapshot.get("trait_keys", PackedStringArray())
	var core: PackedByteArray = snapshot.get("core", PackedByteArray())
	var descriptions: PackedStringArray = snapshot.get("descriptions", PackedStringArray())
	var effect_names: PackedStringArray = snapshot.get("effect_display_names", PackedStringArray())
	for index in range(keys.size()):
		var detail = String(descriptions[index]).strip_edges() \
			if index < descriptions.size() else ""
		var is_core = index < core.size() and int(core[index]) != 0
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



func _family_behavior_rows(host, snapshot: Dictionary, cell_idx: int = -1) -> Array:
	var h = host
	var visibility = host._family_behavior_visibility(cell_idx)
	return host._family_behavior_rows_for_visibility(snapshot, visibility)



static func family_behavior_rows_for_cell(snapshot: Dictionary, facade,
		cell_idx: int) -> Array:
	var visibility = _family_behavior_visibility_for_cell(facade, cell_idx)
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
	var axis_names = ["投资", "职业", "需求", "商品消费"]
	for index in range(axes.size()):
		var axis = int(axes[index])
		var stable_id = String(stable_ids[index]) if index < stable_ids.size() else ""
		if not _family_behavior_selector_visible(axis, stable_id, visibility):
			continue
		var factor_q16 = int(factors[index]) if index < factors.size() else 65536
		var factor_percent = float(factor_q16) * 100.0 / 65536.0
		var axis_name: String = axis_names[axis] if axis >= 0 \
			and axis < axis_names.size() else "行为"
		var display_name = String(names[index]) if index < names.size() else "目标 %d" % index
		var signed_delta = factor_percent - 100.0
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
	return FamilyWorkspaceProjection._family_behavior_icon(axis, stable_id, name_text)



func _family_behavior_visibility(host, cell_idx: int) -> Dictionary:
	var h = host
	var facade = host._generator.get_economy_facade() if host._generator != null \
		and h._generator.has_method("get_economy_facade") else null
	return host._family_behavior_visibility_for_cell(facade, cell_idx)



static func _family_behavior_visibility_for_cell(facade, cell_idx: int) -> Dictionary:
	var result = {"buildings": {}, "goods": {}, "professions": {}, "needs": {},
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
		var need_visibility = _family_behavior_visible_needs(
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
	var hired = {}
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
	var can_resolve_roles = not catalog.is_empty() \
		and owners.size() == type_ids.size() \
		and employee_offsets.size() == type_ids.size() + 1
	if can_resolve_roles:
		for type_index in range(type_ids.size()):
			var present = type_index < type_counts.size() \
				and int(type_counts[type_index]) > 0
			var unlocked = type_index < type_available.size() \
				and int(type_available[type_index]) != 0
			var constructible = type_index < type_constructible.size() \
				and int(type_constructible[type_index]) != 0
			if not present and not unlocked and not constructible:
				continue
			_add_profession_id(hired, catalog, int(owners[type_index]))
			var begin = int(employee_offsets[type_index])
			var end = int(employee_offsets[type_index + 1])
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
		var filtered = {}
		for profession_id in hired.keys():
			var index = catalog.find(String(profession_id))
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
	var market_unlocks = {}
	for index in range(market_good_ids.size()):
		market_unlocks[String(market_good_ids[index])] = int(good_available[index]) != 0
	var visible = {}
	for entry in range(need_entries.size()):
		var need_index = int(need_entries[entry])
		if need_index < 0 or need_index >= need_ids.size():
			return {"ok": false}
		var variant_begin = int(need_variant_offsets[entry])
		var variant_end = int(need_variant_offsets[entry + 1])
		if variant_begin < 0 or variant_end <= variant_begin \
				or variant_end > variant_component_offsets.size() - 1:
			return {"ok": false}
		# A need is available when one complete substitute bundle can be bought
		# locally; partially unlocked bundles must not leak the preference row.
		for variant in range(variant_begin, variant_end):
			var component_begin = int(variant_component_offsets[variant])
			var component_end = int(variant_component_offsets[variant + 1])
			if component_begin < 0 or component_end <= component_begin \
					or component_end > component_good_ids.size():
				return {"ok": false}
			var variant_unlocked = true
			for component in range(component_begin, component_end):
				var good_index = int(component_good_ids[component])
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



func _family_branch_rows(host, snapshot: Dictionary) -> Array:
	var h = host
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
		var level = int(levels[index]) if index < levels.size() else 0
		var target = int(targets[index]) if index < targets.size() else level
		var cell = int(cells[index])
		var score_q16 = int(scores[index]) if index < scores.size() else 0
		var population_q16 = int(population_shares[index]) if index < population_shares.size() else 0
		var cash_q16 = int(cash_shares[index]) if index < cash_shares.size() else 0
		var building_q16 = int(building_shares[index]) if index < building_shares.size() else 0
		var pop_count = int(populations[index]) if index < populations.size() else 0
		var cash_val = int(cash_claims[index]) if index < cash_claims.size() else 0
		var asset_val = int(building_assets[index]) if index < building_assets.size() else 0
		var sat_q16 = int(satisfactions[index]) if index < satisfactions.size() else 0
		var demo_q16 = int(demo_shares[index]) if index < demo_shares.size() else 0
		var target_q16 = int(target_shares[index]) if index < target_shares.size() else 0
		var settlement = String(settlement_names[index]).strip_edges() \
			if index < settlement_names.size() else ""
		var loc_label = "%s（地块 %d）" % [settlement, cell] \
			if not settlement.is_empty() else "地块 %d" % cell
		rows.append({
			"id": "branch:%d" % cell,
			"kind": "branch",
			"cell": cell,
			"settlement_name": settlement,
			"location_label": loc_label,
			"prestige_level": level,
			"prestige_label": h._prestige_text(level),
			"prestige_score_q16": score_q16,
			"prestige_percent": float(score_q16) * 100.0 / 65536.0,
			"prestige_text": h._q16_percent_text(score_q16),
			"population_share_q16": population_q16,
			"population_share_text": h._q16_percent_text(population_q16),
			"cash_share_q16": cash_q16,
			"cash_share_text": h._q16_percent_text(cash_q16),
			"building_share_q16": building_q16,
			"building_share_text": h._q16_percent_text(building_q16),
			"population_count": pop_count,
			"population_count_text": "%s 人" % UITokens.format_compact_number_cn(float(pop_count), 1),
			"cash_amount_text": h._money_text(cash_val),
			"building_asset_text": h._money_text(asset_val),
			"satisfaction_q16": sat_q16,
			"satisfaction_percent": float(sat_q16) * 100.0 / 65536.0,
			"satisfaction_text": h._q16_percent_text(sat_q16),
			"demography_share_text": h._q16_percent_text(demo_q16),
			"target_share_text": h._q16_percent_text(target_q16),
			"target_level": target,
			"target_label": h._prestige_text(target),
			"review_streak": int(streaks[index]) if index < streaks.size() else 0,
			"name": "%s · 威望 %s" % [loc_label, h._prestige_text(level)],
			"value": "总分 %s · 人口 %s / 现金 %s / 建筑 %s · 目标 %s（%d/2）" % [
				host._q16_percent_text(score_q16), host._q16_percent_text(population_q16),
				host._q16_percent_text(cash_q16), host._q16_percent_text(building_q16),
				host._prestige_text(target), int(streaks[index]) if index < streaks.size() else 0],
		})
	return rows



func _family_bound_effect_rows(host, snapshot: Dictionary) -> Array:
	var h = host
	var rows: Array = []
	var cell = int(snapshot.get("cell_idx", -1))
	var prestige_level = int(snapshot.get("prestige_level", 0))
	var settlement_name = String(snapshot.get("settlement_name", "")).strip_edges()
	var keys: PackedStringArray = snapshot.get(
		"effect_definition_keys", PackedStringArray())
	var names: PackedStringArray = snapshot.get(
		"effect_display_names", PackedStringArray())
	var descriptions: PackedStringArray = snapshot.get(
		"effect_descriptions", PackedStringArray())
	var current_descriptions: PackedStringArray = snapshot.get(
		"effect_current_descriptions", PackedStringArray())
	var prestige_tiers_all: Array = snapshot.get("effect_prestige_descriptions", [])
	var seen = {}
	for index in range(keys.size()):
		var key = String(keys[index]).strip_edges()
		if key.is_empty() or seen.has(key):
			continue
		seen[key] = true
		var display = String(names[index]).strip_edges() \
			if index < names.size() else ""
		if display.is_empty():
			display = key
		var detail = String(descriptions[index]).strip_edges() \
			if index < descriptions.size() else ""
		var current = String(current_descriptions[index]).strip_edges() \
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



func _family_modifier_rows(host, snapshot: Dictionary) -> Array:
	var h = host
	var rows: Array = []
	var cell = int(snapshot.get("cell_idx", -1))
	var keys: PackedStringArray = snapshot.get(
		"modifier_definition_keys", PackedStringArray())
	var names: PackedStringArray = snapshot.get(
		"modifier_display_names", PackedStringArray())
	var descriptions: PackedStringArray = snapshot.get(
		"modifier_descriptions", PackedStringArray())
	var magnitudes: PackedInt32Array = snapshot.get(
		"modifier_magnitude_q16", PackedInt32Array())
	for index in range(keys.size()):
		var key = String(keys[index])
		var display = String(names[index]).strip_edges() \
			if index < names.size() else ""
		if display.is_empty():
			display = key
		var detail = String(descriptions[index]).strip_edges() \
			if index < descriptions.size() else ""
		var magnitude_q16 = int(magnitudes[index]) if index < magnitudes.size() else 0
		rows.append({
			"id": "modifier:%d:%s" % [cell, key],
			"kind": "modifier",
			"cell": cell,
			"modifier_key": key,
			"title": display,
			"magnitude_q16": magnitude_q16,
			"magnitude_percent": float(magnitude_q16) * 100.0 / 65536.0,
			"magnitude_text": h._q16_percent_text(magnitude_q16),
			"name": "地块 %d · %s" % [cell, display],
			"value": "效果幅度 %s" % h._q16_percent_text(magnitude_q16),
			"detail": detail,
			"tooltip": detail,
		})
	return rows



func _family_trigger_rows(host, snapshot: Dictionary) -> Array:
	var h = host
	var rows: Array = []
	var cell = int(snapshot.get("cell_idx", -1))
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
		var key = String(keys[index])
		var display = String(names[index]).strip_edges() \
			if index < names.size() else ""
		if display.is_empty():
			display = key
		var detail = String(descriptions[index]).strip_edges() \
			if index < descriptions.size() else ""
		var progress_value = int(progress[index]) if index < progress.size() else 0
		var threshold_value = int(thresholds[index]) if index < thresholds.size() else 0
		var completed_value = int(completed[index]) if index < completed.size() else 0
		var reward_target = int(targets[index]) if index < targets.size() else 0
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
	return FamilyWorkspaceProjection._prestige_text(level)



static func _q16_percent_text(value: int) -> String:
	return FamilyWorkspaceProjection._q16_percent_text(value)



func _family_notable_person_rows(host, facade, family_handle: int) -> Array:
	var h = host
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
		var job_kind = int(person.get("job_kind", 0))
		var job_text = "家族成员"
		if job_kind == 1:
			job_text = "产业所有者"
		elif job_kind == 2:
			job_text = "产业雇员"
		var profession = String(person.get("profession_display_name", ""))
		var profession_id = String(person.get("profession_stable_id", ""))
		var building = String(person.get("building_type_display_name", ""))
		var detail_parts: Array[String] = []
		if not profession.is_empty():
			detail_parts.append(profession)
		detail_parts.append(job_text)
		if not building.is_empty():
			detail_parts.append(building)
		var cash_val = int(person.get("cash_claim", 0))
		var attr_asset_val = int(person.get("attributed_asset_value", 0))
		var net_worth_val = int(person.get("estimated_net_worth", cash_val + attr_asset_val))
		var equity_q32 = int(person.get("family_equity_share_q32", 0))
		var equity_pct = clampf(float(equity_q32) * 100.0 / 4294967296.0, 0.0, 100.0)
		var job_inc = maxi(0, int(person.get("epoch_job_income", 0)))
		var biz_res = int(person.get("epoch_business_result", 0))
		var cons_exp = maxi(0, int(person.get("epoch_consumption_expense", 0)))
		var tax_exp = maxi(0, int(person.get("epoch_tax", 0)))
		var total_inc = job_inc + maxi(0, biz_res)
		var total_exp = cons_exp + tax_exp + maxi(0, -biz_res)
		var net_flow = total_inc - total_exp
		var sat_q16 = int(person.get("needs_satisfaction_q16", 0))
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
			"cash_claim_text": h._money_text(cash_val),
			"attributed_asset_text": h._money_text(attr_asset_val),
			"net_worth_val": net_worth_val,
			"net_worth_text": h._money_text(net_worth_val),
			"equity_share_percent": equity_pct,
			"equity_share_text": "%.1f%%" % equity_pct,
			"income_val": total_inc,
			"expense_val": total_exp,
			"income_text": h._money_text(total_inc),
			"expense_text": h._money_text(total_exp),
			"net_cashflow_val": net_flow,
			"net_cashflow_text": "%s%s" % [
				"+" if net_flow >= 0 else "−", h._money_text(absi(net_flow))],
			"satisfaction_q16": sat_q16,
			"satisfaction_percent": float(sat_q16) * 100.0 / 65536.0,
			"satisfaction_text": h._q16_percent_text(sat_q16),
			"value": " · ".join(detail_parts),
		})
	return rows


## 本地年度产值与人均年度产值。数据全在内存账本里，不发起任何原生查询；
## 未跟踪的格返回空数组，调用方不会多出两格空白指标。
## 金额格式沿用本页邻居（居民存款 / 粮食产出）的 host._money_text 约定，不额外加货币符号。## 金额格式沿用本页邻居（居民存款 / 粮食产出）的 _money_text 约定，不额外加货币符号。
