extends RefCounted


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

func _weather_field(host, cell: HexCell, idx: int) -> Dictionary:
	var h = host
	var has_wf: bool = host._view_adapter.get_weather_field_init(idx) if host._view_adapter != null else bool(cell.weather_field_initialized)
	var precip: float = host._view_adapter.get_weather_precip(idx) if host._view_adapter != null else float(cell.weather_precip)
	var vapor: float = host._view_adapter.get_weather_vapor(idx) if host._view_adapter != null else float(cell.weather_vapor)
	var cloud: float = host._view_adapter.get_weather_cloud(idx) if host._view_adapter != null else float(cell.weather_cloud)
	if not has_wf:
		precip = float(cell.current_state.get("weather_precip", precip))
		vapor = float(cell.current_state.get("weather_vapor", vapor))
		cloud = float(cell.current_state.get("weather_cloud", cloud))
	return {"precip": clampf(precip, 0.0, 1.0), "vapor": clampf(vapor, 0.0, 1.0), "cloud": clampf(cloud, 0.0, 1.0)}



func _resource_visibility_context(host, cell_idx: int) -> Dictionary:
	var h = host
	var context = {
		"enforce_discovery": false,
		"technology_ids": PackedStringArray(),
		"enforce_extraction": false,
		"extractable_resource_ids": {},
	}
	if h._generator == null or not h._generator.has_method("get_country_facade"):
		return context
	var country_facade = host._generator.get_country_facade()
	if country_facade == null or not country_facade.has_method("cell_summary") \
			or not country_facade.has_method("snapshot"):
		return context
	var summary: Dictionary = country_facade.cell_summary(cell_idx)
	if not bool(summary.get("ok", false)):
		return context
	# 检查器是玩家视角：迷雾已经挡住未探索格，认矿用观察者已掌握科技，
	# 不能用地块所有者（无主地没有科技）的空集合把真实储量显示成「未配置」。
	var viewer = host._completed_technology_ids(country_facade, host._player_country_handle())
	if not bool(viewer.get("ok", false)) and bool(summary.get("owned", false)):
		viewer = host._completed_technology_ids(
			country_facade, int(summary.get("country_handle", -1)))
	if bool(viewer.get("ok", false)):
		context.enforce_discovery = true
		context.technology_ids = viewer.get("technology_ids", PackedStringArray())
	elif not bool(summary.get("owned", false)):
		context.enforce_discovery = true
	var extractable = host._extractable_resource_ids(host._building_snapshot(cell_idx))
	if bool(extractable.get("ok", false)):
		context.enforce_extraction = true
		context.extractable_resource_ids = extractable.ids
	return context



func _completed_technology_ids(host, country_facade, handle: int) -> Dictionary:
	var h = host
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

func player_technology_ids(host, ) -> PackedStringArray:
	var h = host
	var day = host._current_sample_day()
	if day == host._technology_day:
		return host._technology_ids_cache
	host._technology_day = day
	host._technology_ids_cache = PackedStringArray()
	host._technology_ids_resolved = false
	if h._generator == null or not h._generator.has_method("get_country_facade"):
		return host._technology_ids_cache
	var viewer = host._completed_technology_ids(
		host._generator.get_country_facade(), host._player_country_handle())
	if bool(viewer.get("ok", false)):
		h._technology_ids_cache = viewer.get("technology_ids", PackedStringArray())
		host._technology_ids_resolved = true
	return host._technology_ids_cache



func _extractable_resource_ids(host, snapshot: Dictionary) -> Dictionary:
	var h = host
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
	var ids = {}
	for type_id in range(kinds.size()):
		if kinds[type_id] != 0 or available[type_id] == 0:
			continue
		var begin = int(offsets[type_id])
		var end = int(offsets[type_id + 1])
		if begin < 0 or end < begin or end > resource_indices.size():
			return {"ok": false}
		for edge in range(begin, end):
			var resource_idx = int(resource_indices[edge])
			if resource_idx < 0 or resource_idx >= resource_ids.size():
				return {"ok": false}
			ids[StringName(resource_ids[resource_idx])] = true
	return {"ok": true, "ids": ids}



func _resource_state(host, idx: int, is_water: bool, visibility: Dictionary = {}) -> Array:
	var h = host
	ResourceProfileRegistry.ensure_loaded()
	var items: Array = []
	var enforce_discovery = bool(visibility.get("enforce_discovery", false))
	var technology_ids: PackedStringArray = visibility.get(
		"technology_ids", PackedStringArray())
	var enforce_extraction = bool(visibility.get("enforce_extraction", false))
	var extractable_resource_ids: Dictionary = visibility.get("extractable_resource_ids", {})
	var habitat_mask = 1 if not is_water else 0
	if host._map != null and idx >= 0 and idx < host._map.resource_habitat_mask_arr.size():
		habitat_mask = int(host._map.resource_habitat_mask_arr[idx])
	var sample_day = host._current_sample_day()
	for p in ResourceProfileRegistry.ordered():
		if enforce_discovery and not ResourceProfileRegistry.discovery_visible(p, technology_ids):
			continue
		var resource_id = String(p.id)
		var name_cn: String = String(p.display_name) if String(p.display_name) != "" else String(p.id)
		var available = ResourceProfileRegistry.habitat_available(p, habitat_mask)
		var extractable = not enforce_extraction or extractable_resource_ids.has(StringName(p.id))
		var reference_reserve = host._resource_reference_reserve(p)
		var reserve = 0.0
		var delta = 0.0
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
		reserve = host._resource_reserve(p, idx)
		var field: String = ResourceProfileRegistry.reserve_map_field(p)
		var key = "%d:%s" % [idx, field]
		delta = host._sample_daily_delta(host._resource_prev_reserves, key, reserve, sample_day)
		var density_ratio = reserve / reference_reserve
		var relative_delta = absf(delta) / reference_reserve
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



func _resource_reserve(host, profile, idx: int) -> float:
	var h = host
	if host._map == null:
		return 0.0
	var field: String = ResourceProfileRegistry.reserve_map_field(profile)
	if field == "":
		return 0.0
	var arr: PackedFloat32Array = host._map.get(field)
	if idx >= 0 and idx < arr.size():
		return float(arr[idx])
	return 0.0



func _resource_reference_reserve(host, profile: ResourceProfile) -> float:
	var h = host
	return ResourceProfileRegistry.reference_reserve(profile)



func _habitability_score(host, temp: float, moist: float, vitality: float, elev: float, passable_land: bool, is_water: bool) -> float:
	var h = host
	if is_water:
		return clampf((1.0 - absf(temp - 0.48) / 0.52) * 0.35 + moist * 0.20 + 0.20, 0.0, 1.0)
	var temp_score = clampf(1.0 - absf(temp - 0.52) / 0.52, 0.0, 1.0)
	var moist_score = clampf(1.0 - absf(moist - 0.58) / 0.58, 0.0, 1.0)
	var elev_score = clampf(1.0 - maxf(elev - 0.78, 0.0) / 0.22, 0.0, 1.0)
	var pass_score = 1.0 if passable_land else 0.25
	return clampf(temp_score * 0.28 + moist_score * 0.24 + vitality * 0.24 + elev_score * 0.14 + pass_score * 0.10, 0.0, 1.0)



func _score_caption(host, v: float) -> String:
	var h = host
	if v >= 0.80: return "优良"
	if v >= 0.62: return "可发展"
	if v >= 0.42: return "有约束"
	if v >= 0.24: return "困难"
	return "严峻"



func _score_color(host, v: float) -> Color:
	var h = host
	if v >= 0.70: return UITokens.GOOD
	if v >= 0.45: return UITokens.WARN
	return UITokens.RISK



func _terrain(host, cell: HexCell, idx: int) -> int:
	var h = host
	return host._view_adapter.get_terrain(idx) if host._view_adapter != null else int(cell.terrain)



func _landform(host, cell: HexCell, idx: int) -> int:
	var h = host
	return host._view_adapter.get_landform(idx) if host._view_adapter != null else int(cell.landform)



func _vegetation(host, cell: HexCell, idx: int) -> int:
	var h = host
	return host._view_adapter.get_vegetation(idx) if host._view_adapter != null else int(cell.vegetation)



func _cover(host, cell: HexCell, idx: int) -> int:
	var h = host
	return host._view_adapter.get_cover(idx) if host._view_adapter != null else int(cell.cover)



func _temp(host, cell: HexCell, idx: int) -> float:
	var h = host
	return clampf(host._view_adapter.get_temp(idx) if host._view_adapter != null else float(cell.temperature), 0.0, 1.0)



func _moisture(host, cell: HexCell, idx: int) -> float:
	var h = host
	return clampf(host._view_adapter.get_moisture(idx) if host._view_adapter != null else float(cell.moisture), 0.0, 1.0)



func _base_moisture(host, cell: HexCell, idx: int) -> float:
	var h = host
	return clampf(host._view_adapter.get_base_moisture(idx) if host._view_adapter != null else float(cell.base_moisture), 0.0, 1.0)



func _elevation(host, cell: HexCell, idx: int) -> float:
	var h = host
	return clampf(host._view_adapter.get_elevation(idx) if host._view_adapter != null else float(cell.elevation), 0.0, 1.0)



func _snow_cover(host, cell: HexCell, idx: int) -> float:
	var h = host
	return clampf(host._view_adapter.get_snow_cover(idx) if host._view_adapter != null else float(cell.snow_cover), 0.0, 1.0)



func _vitality(host, cell: HexCell, landform_v: int) -> float:
	var h = host
	return 0.0 if LandformType.is_water(landform_v) else clampf(float(cell.vegetation_vitality), 0.0, 1.0)



func _weather_intensity(host, cell: HexCell, idx: int) -> float:
	var h = host
	return clampf(host._view_adapter.get_weather_intensity(idx) if host._view_adapter != null else float(cell.weather_intensity), 0.0, 1.0)



func _weather_name(host, cell: HexCell, idx: int) -> String:
	var h = host
	var has_wf: bool = host._view_adapter.get_weather_field_init(idx) if host._view_adapter != null else bool(cell.weather_field_initialized)
	var wt: int = (host._view_adapter.get_weather_type(idx) if host._view_adapter != null else int(cell.weather_type)) if has_wf else WeatherType.WT.CLEAR
	var wi: float = host._weather_intensity(cell, idx) if has_wf else 0.0
	if wt == WeatherType.WT.CLEAR or wi <= 0.05:
		return "晴朗"
	return WeatherType.name_cn(wt)



func _has_river(host, cell: HexCell, idx: int) -> bool:
	var h = host
	return host._view_adapter.get_has_river(idx) if host._view_adapter != null else bool(cell.has_river)



func _ocean_current(host, cell: HexCell, idx: int) -> Vector2:
	var h = host
	return host._view_adapter.get_ocean_current(idx) if host._view_adapter != null else cell.ocean_current



func _wind_vector(host, cell: HexCell, idx: int) -> Vector2:
	var h = host
	return host._view_adapter.get_wind_vector(idx) if host._view_adapter != null else cell.wind_vector



func _wind_speed(host, cell: HexCell, idx: int) -> float:
	var h = host
	var speed: float = host._view_adapter.get_wind_speed(idx) if host._view_adapter != null else float(cell.wind_speed)
	if speed <= 0.0001:
		speed = host._wind_vector(cell, idx).length()
	return speed



func _upwelling(host, cell: HexCell, idx: int) -> float:
	var h = host
	return host._view_adapter.get_upwelling_strength(idx) if host._view_adapter != null else float(cell.upwelling_strength)



func _adapter_float(host, method: String, idx: int, fallback: float) -> float:
	var h = host
	if host._view_adapter != null and host._view_adapter.has_method(method):
		return clampf(float(host._view_adapter.call(method, idx)), 0.0, 1.0)
	return clampf(fallback, 0.0, 1.0)



func _history_values(host, cell: HexCell) -> Array:
	var h = host
	var values = []
	var hist: Array = cell.vegetation_history if not cell.vegetation_history.is_empty() else cell.biome_history
	for raw in hist:
		values.append(float(raw))
	if values.size() < 2:
		values.append(float(cell.vegetation))
		values.append(float(cell.vegetation))
	return host._densify_series(values, 9)



func _temperature_chart(host, chart_id: String, title: String, idx: int, current_temp: float) -> Dictionary:
	var h = host
	return {
		"id": chart_id,
		"title": title,
		"values": h._temperature_memory(idx, current_temp),
		"accent": UITokens.CLIMATE,
		"min_value": 0.0,
		"max_value": 1.0,
		"window_size": h.TEMPERATURE_HISTORY_CAPACITY,
		"value_text": "现值 %.2f" % current_temp,
	}



func _temperature_memory(host, idx: int, current_temp: float) -> Array:
	var h = host
	var series: Dictionary = host._temperature_histories.get(idx, {})
	if series.is_empty():
		return [current_temp]
	return (series.get("values", []) as Array).duplicate()



func _record_temperature_sample(host, idx: int, day_idx: int, value: float) -> void:
	var h = host
	if not host._temperature_histories.has(idx):
		if host._temperature_history_order.size() >= host.TEMPERATURE_HISTORY_CACHE_LIMIT:
			var evicted_idx: int = int(host._temperature_history_order.pop_front())
			host._temperature_histories.erase(evicted_idx)
		host._temperature_history_order.append(idx)
		h._temperature_histories[idx] = {"days": [], "values": []}
	var series: Dictionary = host._temperature_histories[idx]
	var days: Array = series.get("days", [])
	var samples: Array = series.get("values", [])
	var sample_value = clampf(value, 0.0, 1.0)
	if not days.is_empty():
		var last_idx = days.size() - 1
		var last_day = int(days[last_idx])
		if day_idx < last_day:
			return
		if day_idx == last_day:
			samples[last_idx] = sample_value
			series["values"] = samples
			host._temperature_histories[idx] = series
			return
	days.append(day_idx)
	samples.append(sample_value)
	while samples.size() > host.TEMPERATURE_HISTORY_CAPACITY:
		days.pop_front()
		samples.pop_front()
	series["days"] = days
	series["values"] = samples
	host._temperature_histories[idx] = series



func _current_sample_day(host, ) -> int:
	var h = host
	return host._world_clock.day_index() if host._world_clock != null else 0



func _daily_delta_text(host, v: float) -> String:
	var h = host
	if is_nan(v):
		return ""
	if absf(v) < 0.0001:
		return ""
	return "%s%s" % ["+" if v > 0.0 else "", UITokens.format_compact_number_cn(v, 2)]



func _sample_daily_delta(host, cache: Dictionary, key: String, value: float, day: int) -> float:
	var h = host
	if not cache.has(key):
		cache[key] = {"value": value, "day": day, "daily": NAN}
		return NAN
	var previous: Dictionary = cache[key]
	var previous_day = int(previous.get("day", day))
	if day <= previous_day:
		return float(previous.get("daily", NAN))
	var daily = (value - float(previous.get("value", value))) / float(day - previous_day)
	cache[key] = {"value": value, "day": day, "daily": daily}
	return daily



func _relative_sea_level_text(host, elev: float, sea: float) -> String:
	var h = host
	var delta = elev - sea
	return "Δ海面 %+.2f" % delta



func _resource_index_text(host, v: float) -> String:
	var h = host
	return UITokens.format_compact_number_cn(v, 2)



func _intensity_text(host, v: float) -> String:
	var h = host
	if v < 0.15: return "强度轻微"
	if v < 0.40: return "强度中等"
	if v < 0.70: return "强度明显"
	return "强度剧烈"



func _cloud_band(host, v: float) -> String:
	var h = host
	if v < 0.15: return "晴空"
	if v < 0.45: return "少云"
	if v < 0.75: return "多云"
	return "阴云"



func _precip_band(host, v: float) -> String:
	var h = host
	if v < 0.05: return "无雨"
	if v < 0.25: return "微雨"
	if v < 0.55: return "降雨"
	if v < 0.80: return "强雨"
	return "暴雨"



func _cover_intensity_band(host, v: float) -> String:
	var h = host
	if v < 0.05: return ""
	if v < 0.25: return "薄"
	if v < 0.55: return "中"
	if v < 0.80: return "厚"
	return "封冻"



func _stress_band(host, v: float) -> String:
	var h = host
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



func _history_badges(host, cell: HexCell) -> Array:
	var h = host
	var badges = []
	var hist: Array = cell.vegetation_history if not cell.vegetation_history.is_empty() else cell.biome_history
	var start = maxi(hist.size() - 6, 0)
	for i in range(start, hist.size()):
		badges.append({"text": VegetationType.name_cn(int(hist[i])), "accent": UITokens.ECO})
	return badges



func _densify_series(host, source: Array, target_count: int) -> Array:
	var h = host
	if source.size() <= 1 or target_count <= source.size():
		return source
	var result = []
	for i in range(target_count):
		var t = float(i) / float(target_count - 1)
		var pos = t * float(source.size() - 1)
		var left = int(floor(pos))
		var right = mini(left + 1, source.size() - 1)
		var a = float(source[left])
		var b = float(source[right])
		result.append(lerpf(a, b, pos - float(left)))
	return result



func _dir_degrees_text(host, v: Vector2) -> String:
	var h = host
	if v.length() < 0.0001:
		return ""
	return "%.0f°" % fposmod(rad_to_deg(atan2(v.y, v.x)), 360.0)



func _vitality_band(host, v: float) -> String:
	var h = host
	if v < 0.15: return "濒死"
	if v < 0.40: return "枯萎"
	if v < 0.70: return "亚健康"
	if v < 0.90: return "健康"
	return "繁茂"



func _elevation_band(host, elev: float, sea: float) -> String:
	var h = host
	if elev < sea * 0.30: return "深海"
	if elev < sea * 0.85: return "近海"
	if elev < sea: return "浅海"
	var land = (elev - sea) / maxf(1.0 - sea, 0.001)
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



func _temperature_band(host, t: float) -> String:
	var h = host
	return host.temperature_band(t)



func _moisture_band(host, m: float) -> String:
	var h = host
	if m < 0.20: return "极干"
	if m < 0.40: return "干燥"
	if m < 0.60: return "适中"
	if m < 0.80: return "湿润"
	return "极湿"
