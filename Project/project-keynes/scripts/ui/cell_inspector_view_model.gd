extends RefCounted
class_name CellInspectorViewModel

const TEMPERATURE_HISTORY_CAPACITY := 32
const TEMPERATURE_HISTORY_CACHE_LIMIT := 64

var _map: MapData
var _generator
var _view_adapter: DCViewAdapter
var _world_clock: WorldClock
var _sea_level: float = 0.42
var _hex_size: float = 22.0
var _resource_prev_reserves: Dictionary = {}
var _temperature_histories: Dictionary = {}
var _temperature_history_order: Array[int] = []


func set_context(map: MapData, generator, view_adapter: DCViewAdapter, world_clock: WorldClock, sea_level: float, hex_size: float) -> void:
	_map = map
	_generator = generator
	_view_adapter = view_adapter
	_world_clock = world_clock
	_sea_level = sea_level
	_hex_size = hex_size
	_resource_prev_reserves.clear()
	_temperature_histories.clear()
	_temperature_history_order.clear()


func observe_temperature(cell: HexCell, day_idx: int = -1) -> void:
	if cell == null or _map == null:
		return
	var idx := int(cell.index)
	_record_temperature_sample(
		idx,
		day_idx if day_idx >= 0 else _current_sample_day(),
		_temp(cell, idx)
	)


func build(cell: HexCell) -> Dictionary:
	if cell == null or _map == null:
		return {}
	var idx := int(cell.index)
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
	var resource_state := _resource_state(idx, is_water)
	var resource_summary := _resource_summary(resource_state)
	var population_snapshot := _population_snapshot(idx)
	var market_snapshot := _market_snapshot(idx)
	var habitability := _habitability_score(temp, moist, vitality, elev, passable_land, is_water)
	var resource_label := String(resource_summary.get("label", "—"))
	var tabs := [
		{"id": "geography", "label": "地理信息", "icon": "geo"},
		{"id": "population", "label": "人口信息", "icon": "growth"},
		{"id": "market", "label": "市场信息", "icon": "resource"},
		{"id": "natural_resources", "label": "自然资源", "icon": "eco"},
	]
	return {
		"header": _build_header(off, terrain_v, landform_v),
		"score": {
			"id": "habitability",
			"title": "适宜度",
			"value": habitability,
			"caption": _score_caption(habitability),
			"accent": _score_color(habitability),
		},
		"summary_cards": _summary_cards(temp, moist, population_snapshot,
			market_snapshot, resource_label, resource_summary),
		"tabs": tabs,
		"categories": {
			"geography": _geography_information_category(cell, idx, terrain_v,
				landform_v, vegetation_v, cover_v, elev, temp, moist, base_moist,
				wf, snow, vitality, passable_land, is_water),
			"population": _population_category(population_snapshot),
			"market": _market_category(market_snapshot),
			"natural_resources": _resources_category(resource_state),
		},
	}


func build_live_patch(cell: HexCell, current_tab: String) -> Dictionary:
	if cell == null or _map == null:
		return {}
	var idx := int(cell.index)
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
	var resource_state := _resource_state(idx, is_water)
	var resource_summary := _resource_summary(resource_state)
	var population_snapshot := _population_snapshot(idx)
	var market_snapshot := _market_snapshot(idx)
	var habitability := _habitability_score(temp, moist, vitality, elev, passable_land, is_water)
	var resource_label := String(resource_summary.get("label", "—"))
	var tab_id := current_tab if current_tab != "" else "geography"
	var category: Dictionary
	match tab_id:
		"geography":
			category = _geography_information_category(cell, idx, terrain_v,
				landform_v, vegetation_v, cover_v, elev, temp, moist, base_moist,
				wf, snow, vitality, passable_land, is_water)
		"natural_resources":
			category = _resources_category(resource_state)
		"population":
			category = _population_category(population_snapshot)
		"market":
			category = _market_category(market_snapshot)
		_:
			tab_id = "geography"
			category = _geography_information_category(cell, idx, terrain_v,
				landform_v, vegetation_v, cover_v, elev, temp, moist, base_moist,
				wf, snow, vitality, passable_land, is_water)
	return {
		"header": _build_header(off, terrain_v, landform_v),
		"score": {
			"id": "habitability",
			"title": "适宜度",
			"value": habitability,
			"caption": _score_caption(habitability),
			"accent": _score_color(habitability),
		},
		"summary_cards": _summary_cards(temp, moist, population_snapshot,
			market_snapshot, resource_label, resource_summary),
		"tab_id": tab_id,
		"category": category,
	}


func _build_header(
		off: Vector2i,
		terrain_v: int,
		landform_v: int
) -> Dictionary:
	return {
		"title": "%s · %s" % [LandformType.name_cn(landform_v), TerrainType.terrain_name_cn(terrain_v)],
		"subtitle": "区域 %d, %d" % [off.x + 1, off.y + 1],
	}


func _summary_cards(
		temp: float,
		moist: float,
		population_snapshot: Dictionary,
		market_snapshot: Dictionary,
		resource_label: String,
		resource_summary: Dictionary
) -> Array:
	var population_ready := bool(population_snapshot.get("ok", false))
	var population_value := "%s 人" % UITokens.format_compact_number_cn(
		float(population_snapshot.get("population", 0)), 1) if population_ready else "未就绪"
	var stock_total := _sum_i64(market_snapshot.get("stock", PackedInt64Array()))
	var market_ready := bool(market_snapshot.get("ok", false))
	var market_value := "%s 单位" % UITokens.format_compact_number_cn(
		float(stock_total) / 1000.0, 1) if market_ready else "未就绪"
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
			"id": "summary_population",
			"title": "人口",
			"value": population_value,
			"subtitle": "%d 个阶层" % int(population_snapshot.get("cohort_count", 0)) if population_ready else "未生成测试或正式人口",
			"accent": UITokens.ACCENT,
			"icon": "growth",
		},
		{
			"id": "summary_market",
			"title": "市场",
			"value": market_value,
			"subtitle": "%d 种物资" % int((market_snapshot.get("good_ids", PackedStringArray()) as PackedStringArray).size()) if market_ready else "原生市场未就绪",
			"accent": UITokens.RESOURCE,
			"icon": "resource",
		},
		{
			"id": "summary_resource",
			"title": "资源",
			"value": String(resource_summary.get("summary_value", resource_label)),
			"subtitle": "",
			"accent": UITokens.RESOURCE,
			"trend": String(resource_summary.get("trend", "")),
			"icon": "resource",
		},
	]


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
		{"id": "geography_terrain", "title": "地形", "value": TerrainType.terrain_name_cn(terrain_v), "subtitle": "移动成本 %d" % TerrainType.get_move_cost(terrain_v), "accent": UITokens.GEO, "icon": "surface"},
		{"id": "geography_landform", "title": "地貌", "value": LandformType.name_cn(landform_v), "subtitle": "陆路%s" % ("可通" if passable_land else "阻断"), "accent": UITokens.GEO, "icon": "geo"},
		{"id": "geography_cover", "title": "地表覆盖", "value": CoverType.name_cn(cover_v), "subtitle": "", "accent": UITokens.WATER, "icon": "surface"},
	]
	physical_metrics.append_array(geography.get("metrics", []))
	var climate_metrics: Array = climate.get("metrics", []).duplicate()
	climate_metrics.append_array(hydrology.get("metrics", []))
	climate_metrics.append({"id": "climate_weather", "title": "当前天气", "value": _weather_name(cell, idx), "subtitle": _intensity_text(_weather_intensity(cell, idx)), "accent": UITokens.WATER, "icon": "weather"})
	var climate_gauges: Array = climate.get("gauges", []).duplicate()
	climate_gauges.append_array(hydrology.get("gauges", []))
	return {
		"sections": [
			{
				"id": "physical_geography",
				"title": "地形与地貌",
				"icon": "geo",
				"accent": UITokens.GEO,
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
				"metrics": ecology.get("metrics", []),
				"gauges": ecology.get("gauges", []),
				"charts": ecology.get("charts", []),
			},
		],
	}


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
			{"id": "geography_elevation_gauge", "label": "高程剖面", "value": elev, "accent": UITokens.GEO, "marker": _sea_level, "status_label": _elevation_band(elev, _sea_level), "value_text": _relative_sea_level_text(elev, _sea_level)},
		],
	}


func _climate_category(cell: HexCell, idx: int, temp: float, moist: float, base_moist: float, wf: Dictionary) -> Dictionary:
	return {
		"metrics": [
			{"id": "climate_precip", "title": "降水", "value": _precip_band(float(wf["precip"])), "subtitle": _cloud_band(float(wf["cloud"])), "accent": UITokens.WATER, "icon": "weather"},
		],
		"gauges": [
			{"id": "climate_temp_gauge", "label": "温度指数", "value": temp, "accent": UITokens.CLIMATE, "status_label": _temperature_band(temp), "value_text": "%.2f" % temp},
			{"id": "climate_moisture_gauge", "label": "湿度指数", "value": moist, "accent": UITokens.WATER, "marker": base_moist, "status_label": _moisture_band(moist), "value_text": "%.2f" % moist},
		],
		"charts": [_temperature_chart("climate_temperature", "近期温度变化", idx, temp)],
	}


func _hydrology_category(cell: HexCell, idx: int, wf: Dictionary, snow: float, is_water: bool) -> Dictionary:
	var ocean := _ocean_current(cell, idx)
	var wind := _wind_vector(cell, idx)
	var upwelling := _upwelling(cell, idx)
	var metrics := [
		{"id": "hydrology_wind", "title": "风场", "value": "%.3f" % _wind_speed(cell, idx), "subtitle": _dir_degrees_text(wind), "accent": UITokens.ACCENT, "icon": "wind"},
	]
	if is_water:
		metrics.append({"id": "hydrology_current", "title": "洋流", "value": "%.3f" % ocean.length(), "subtitle": _dir_degrees_text(ocean), "accent": UITokens.WATER, "icon": "water"})
		metrics.append({"id": "hydrology_upwelling", "title": "上升流", "value": "%+.3f" % upwelling, "subtitle": "", "accent": UITokens.WATER, "icon": "trend_up"})
	return {
		"metrics": metrics,
		"gauges": [
			{"id": "hydrology_vapor_gauge", "label": "水汽指数", "value": float(wf["vapor"]), "accent": UITokens.WATER, "status_label": _moisture_band(float(wf["vapor"])), "value_text": "%.2f" % float(wf["vapor"])},
			{"id": "hydrology_cloud_gauge", "label": "云量指数", "value": float(wf["cloud"]), "accent": UITokens.WATER, "status_label": _cloud_band(float(wf["cloud"])), "value_text": "%.2f" % float(wf["cloud"])},
			{"id": "hydrology_precip_gauge", "label": "降水指数", "value": float(wf["precip"]), "accent": UITokens.WATER, "status_label": _precip_band(float(wf["precip"])), "value_text": "%.2f" % float(wf["precip"])},
			{"id": "hydrology_snow_gauge", "label": "雪盖/海冰", "value": snow, "accent": UITokens.WATER, "status_label": _cover_intensity_band(snow), "value_text": "%.2f" % snow},
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
			{"id": "ecology_vegetation", "title": "植被", "value": VegetationType.name_cn(vegetation_v), "subtitle": "基线 %s" % VegetationType.name_cn(cell.base_vegetation), "accent": UITokens.ECO, "icon": "eco"},
		],
		"gauges": [
			{"id": "ecology_regen_gauge", "label": "恢复潜力", "value": regen, "accent": UITokens.ECO, "status_label": _vitality_band(regen), "value_text": "%.2f" % regen},
			{"id": "ecology_heat_gauge", "label": "热胁迫", "value": stress_heat, "accent": UITokens.CLIMATE, "status_label": _stress_band(stress_heat), "value_text": "%.2f" % stress_heat},
			{"id": "ecology_drought_gauge", "label": "旱胁迫", "value": stress_drought, "accent": UITokens.WARN, "status_label": _stress_band(stress_drought), "value_text": "%.2f" % stress_drought},
			{"id": "ecology_cold_gauge", "label": "冷胁迫", "value": stress_cold, "accent": UITokens.WATER, "status_label": _stress_band(stress_cold), "value_text": "%.2f" % stress_cold},
		],
		"charts": [{"id": "ecology_history", "title": "植被历史", "values": _history_values(cell), "accent": UITokens.ECO}],
	}


func _resources_category(resource_state: Array) -> Dictionary:
	var rows := []
	var insights := []
	if resource_state.is_empty():
		return {"insights": [{"text": "尚未配置自然资源类型。", "accent": UITokens.TEXT_MUTED}]}
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


func _population_snapshot(cell_idx: int) -> Dictionary:
	if _generator == null or not _generator.has_method("get_economy_facade"):
		return {}
	var facade = _generator.get_economy_facade()
	if facade == null or not facade.has_method("population_cell_snapshot"):
		return {}
	return facade.population_cell_snapshot(cell_idx)


func _market_snapshot(cell_idx: int) -> Dictionary:
	if _generator == null or not _generator.has_method("get_economy_facade"):
		return {}
	var facade = _generator.get_economy_facade()
	if facade == null or not facade.has_method("market_cell_snapshot"):
		return {}
	return facade.market_cell_snapshot(cell_idx)


func _population_category(snapshot: Dictionary) -> Dictionary:
	if snapshot.is_empty() or not bool(snapshot.get("ok", false)):
		return {"insights": [{"id": "population_unavailable", "text": "阶层运行时尚未就绪。", "accent": UITokens.TEXT_MUTED, "icon": "growth"}]}
	if not snapshot.has("populations"):
		return {"insights": [{"id": "population_details_unavailable", "text": "无法读取最新阶层明细。", "accent": UITokens.RISK, "icon": "growth"}]}
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
	var satisfaction: PackedInt32Array = snapshot.get("satisfaction_by_cohort_q16", PackedInt32Array())
	var merchant_flags: PackedByteArray = snapshot.get("merchant_flags", PackedByteArray())
	var owner_employed: PackedInt64Array = snapshot.get("owner_employed_by_cohort", PackedInt64Array())
	var employee_employed: PackedInt64Array = snapshot.get("employee_employed_by_cohort", PackedInt64Array())
	var demand_offsets: PackedInt32Array = snapshot.get("demand_good_offsets", PackedInt32Array())
	var demand_good_indices: PackedInt32Array = snapshot.get("demand_good_indices", PackedInt32Array())
	var demand_quantities: PackedInt64Array = snapshot.get("demand_per_capita_daily", PackedInt64Array())
	var demand_good_ids: PackedStringArray = snapshot.get("demand_good_stable_ids", PackedStringArray())
	for i in range(populations.size()):
		var profession_id := String(profession_ids[profession_indices[i]]) if profession_indices[i] >= 0 and profession_indices[i] < profession_ids.size() else "unknown"
		var ethnicity_id := String(ethnicity_ids[ethnicity_indices[i]]) if ethnicity_indices[i] >= 0 and ethnicity_indices[i] < ethnicity_ids.size() else "unknown"
		var profession_name := String(profession_names[profession_indices[i]]) if profession_indices[i] >= 0 and profession_indices[i] < profession_names.size() else profession_id
		var ethnicity_name := String(ethnicity_names[ethnicity_indices[i]]) if ethnicity_indices[i] >= 0 and ethnicity_indices[i] < ethnicity_names.size() else ethnicity_id
		var sat := float(satisfaction[i]) / 65536.0 if i < satisfaction.size() else 0.0
		var population := int(populations[i])
		var cohort_funds := int(funds[i]) if i < funds.size() else 0
		var wealth_pc := cohort_funds / maxi(population, 1)
		var owners := int(owner_employed[i]) if i < owner_employed.size() else 0
		var employees := int(employee_employed[i]) if i < employee_employed.size() else 0
		var demand_by_good := {}
		if demand_offsets.size() == populations.size() + 1:
			var begin := clampi(int(demand_offsets[i]), 0, demand_good_indices.size())
			var end := clampi(int(demand_offsets[i + 1]), begin, demand_good_indices.size())
			for cursor in range(begin, end):
				var good_idx := int(demand_good_indices[cursor])
				if good_idx >= 0 and good_idx < demand_good_ids.size() and cursor < demand_quantities.size():
					demand_by_good[good_idx] = int(demand_quantities[cursor])
		var demand_rows := []
		for good_idx in range(demand_good_ids.size()):
			var stable_id := String(demand_good_ids[good_idx])
			var profile = GoodProfileRegistry.profile_by_id(stable_id)
			var display_name := String(profile.display_name) if profile != null and String(profile.display_name) != "" else stable_id
			var quantity := int(demand_by_good.get(good_idx, 0))
			demand_rows.append({
				"id": "demand_%s" % stable_id,
				"name": display_name,
				"value": "%.3f 单位/人/日" % (float(quantity) / 1000.0),
				"icon": "resource",
				"visible": quantity > 0,
			})
		rows.append({
			"id": "cohort_%s" % str(handles[i] if i < handles.size() else i),
			"name": "%s · %s" % [profession_name, ethnicity_name],
			"population": "%s 人" % UITokens.format_compact_number_cn(float(population), 1),
			"wealth": "人均 %s" % _money_text(wealth_pc),
			"status": "%s就业 %s · 满足 %.1f%%" % [
				"商人 · " if i < merchant_flags.size() and merchant_flags[i] != 0 else "",
				UITokens.format_compact_number_cn(float(owners + employees), 1), sat * 100.0],
			"accent": UITokens.ACCENT,
			"icon": "growth",
			"demand_rows": demand_rows,
			"visible": true,
		})
	var insights := []
	if rows.is_empty():
		insights.append({"id": "population_empty", "text": "此地块尚无人口。可在世界生成页启用测试人口，或由正式数据源导入。", "accent": UITokens.TEXT_MUTED, "icon": "growth"})
	elif not bool(snapshot.get("demand_preview_environment_ready", false)):
		insights.append({"id": "population_demand_neutral_environment", "text": "环境快照暂不可用，预计需求使用最近冻结或中性环境。", "accent": UITokens.WARN, "icon": "weather"})
	return {
		"insights": insights,
		"metrics": [
			{"id": "population_total", "title": "总人口", "value": "%s 人" % UITokens.format_compact_number_cn(float(snapshot.get("population", 0)), 1), "subtitle": "%d 个阶层" % int(snapshot.get("cohort_count", 0)), "accent": UITokens.ACCENT, "icon": "growth"},
			{"id": "population_funds", "title": "总资金", "value": _money_text(int(snapshot.get("funds", 0))), "subtitle": "收入 %s · 支出 %s" % [_money_text(int(snapshot.get("epoch_income", 0))), _money_text(int(snapshot.get("epoch_expense", 0)))], "accent": UITokens.RESOURCE, "icon": "resource"},
		],
		"cohort_rows": rows,
	}


func _market_category(snapshot: Dictionary) -> Dictionary:
	if snapshot.is_empty() or not bool(snapshot.get("ok", false)):
		return {"insights": [{"id": "market_unavailable", "text": "市场运行时尚未就绪。", "accent": UITokens.TEXT_MUTED, "icon": "resource"}]}
	if not snapshot.has("good_ids"):
		return {"insights": [{"id": "market_details_unavailable", "text": "无法读取最新市场明细。", "accent": UITokens.RISK, "icon": "resource"}]}
	var rows := []
	var good_ids: PackedStringArray = snapshot.get("good_ids", PackedStringArray())
	var stock: PackedInt64Array = snapshot.get("stock", PackedInt64Array())
	var prices: PackedInt32Array = snapshot.get("price", PackedInt32Array())
	var demand_ema: PackedInt64Array = snapshot.get("demand_ema", PackedInt64Array())
	var shortage_q16: PackedInt32Array = snapshot.get("shortage_q16", PackedInt32Array())
	for i in range(good_ids.size()):
		var stable_id := String(good_ids[i])
		var profile = GoodProfileRegistry.profile_by_id(stable_id)
		var display_name := String(profile.display_name) if profile != null else stable_id
		rows.append({
			"id": "market_%s" % stable_id,
			"name": display_name,
			"value": "%s 单位" % UITokens.format_compact_number_cn(float(stock[i]) / 1000.0, 2),
			"density": "价格 %s" % _money_text(prices[i] if i < prices.size() else 0),
			"delta": "需求EMA %s · 短缺 %.1f%%" % [
				UITokens.format_compact_number_cn(float(demand_ema[i]) / 1000.0, 2) if i < demand_ema.size() else "0",
				float(shortage_q16[i]) * 100.0 / 65536.0 if i < shortage_q16.size() else 0.0,
			],
			"accent": UITokens.RESOURCE,
			"icon": "resource",
			"visible": true,
		})
	return {
		"insights": [],
		"metrics": [
			{"id": "market_id", "title": "本地市场", "value": "#%d" % int(snapshot.get("market_id", -1)), "subtitle": "原生 MarketStore", "accent": UITokens.RESOURCE, "icon": "resource"},
			{"id": "merchant_funds", "title": "商人资金", "value": _money_text(_sum_i64(snapshot.get("merchant_funds", PackedInt64Array()))), "subtitle": "%s 人共同持有库存" % UITokens.format_compact_number_cn(float(_sum_i64(snapshot.get("merchant_population", PackedInt64Array()))), 1), "accent": UITokens.ACCENT, "icon": "resource"},
		],
		"resource_rows": rows,
	}


func _sum_i64(values: PackedInt64Array) -> int:
	var total := 0
	for value in values:
		total += int(value)
	return total


func _money_text(subunits: int) -> String:
	return UITokens.format_compact_number_cn(float(subunits) / 10000.0, 2)


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


func _resource_state(idx: int, is_water: bool) -> Array:
	ResourceProfileRegistry.ensure_loaded()
	var items: Array = []
	for p in ResourceProfileRegistry.ordered():
		var resource_id := String(p.id)
		var name_cn: String = String(p.display_name) if String(p.display_name) != "" else String(p.id)
		var available := not (bool(p.land_only) and is_water)
		var reference_reserve := _resource_reference_reserve(p)
		var reserve := 0.0
		var delta := 0.0
		if bool(p.land_only) and is_water:
			items.append({
				"id": resource_id,
				"name": name_cn,
				"icon": _resource_icon(resource_id, name_cn),
				"available": false,
				"reserve": 0.0,
				"delta": 0.0,
				"density_ratio": 0.0,
				"rank": -1.0,
			})
			continue
		reserve = _resource_reserve(p, idx)
		var field: String = ResourceProfileRegistry.reserve_map_field(p)
		var key := "%d:%s" % [idx, field]
		if _resource_prev_reserves.has(key):
			delta = reserve - float(_resource_prev_reserves[key])
		_resource_prev_reserves[key] = reserve
		var density_ratio := reserve / reference_reserve
		var relative_delta := absf(delta) / reference_reserve
		items.append({
			"id": resource_id,
			"name": name_cn,
			"icon": _resource_icon(resource_id, name_cn),
			"available": available,
			"reserve": reserve,
			"delta": delta,
			"density_ratio": density_ratio,
			"rank": density_ratio + relative_delta * 8.0,
		})
	return items


func _resource_summary(resource_state: Array) -> Dictionary:
	var best: Dictionary = {}
	for raw in resource_state:
		var item: Dictionary = raw
		if not bool(item.get("available", true)):
			continue
		if float(item.get("reserve", 0.0)) <= 0.000001:
			continue
		if best.is_empty() or float(item.get("rank", 0.0)) > float(best.get("rank", 0.0)):
			best = item
	if best.is_empty():
		return {"label": "—", "summary_value": "无可用资源", "subtitle": "无可用资源", "trend": ""}
	var reserve := float(best.get("reserve", 0.0))
	var delta := float(best.get("delta", 0.0))
	var density_ratio := float(best.get("density_ratio", 0.0))
	var density := _resource_density_band(density_ratio)
	return {
		"label": String(best.get("name", "资源")),
		"summary_value": "%s · %s" % [String(best.get("name", "资源")), density],
		"subtitle": "%s · %s" % [density, _resource_index_text(reserve)],
		"trend": _trend_arrow(delta),
	}


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
	# 初始储量各因子直接相加；地貌和植被各只命中一项，因此取各自最大正权重。
	var initial_peak := float(profile.init_base)
	initial_peak += maxf(float(profile.init_temp), 0.0)
	initial_peak += maxf(float(profile.init_moisture), 0.0)
	initial_peak += maxf(float(profile.init_elevation), 0.0)
	initial_peak += maxf(float(profile.init_river), 0.0)
	initial_peak += maxf(float(profile.init_volcano), 0.0)
	initial_peak += maxf(float(profile.init_noise), 0.0)
	initial_peak += maxf(float(profile.init_climate_fit), 0.0)
	initial_peak += _max_positive_weight(profile.init_landform_weights)
	initial_peak += _max_positive_weight(profile.init_vegetation_weights)

	# 可再生资源还要容纳最适气候下的长期平衡储量 P / decay_self。
	var runtime_peak := 0.0
	if float(profile.decay_self) > 0.000001:
		var peak_production := float(profile.gen_base) + float(profile.gen_self) - float(profile.decay_base)
		peak_production += maxf(float(profile.gen_temp) - float(profile.decay_temp), 0.0)
		peak_production += maxf(float(profile.gen_moisture) - float(profile.decay_moisture), 0.0)
		runtime_peak = maxf(peak_production, 0.0) / float(profile.decay_self)
	return maxf(maxf(initial_peak, runtime_peak), 1.0)


func _max_positive_weight(weights: Dictionary) -> float:
	var result := 0.0
	for raw in weights.values():
		result = maxf(result, float(raw))
	return result


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


func _trend_arrow(v: float) -> String:
	if v > 0.0001: return "trend_up"
	if v < -0.0001: return "trend_down"
	return "trend_flat"


func _daily_delta_text(v: float) -> String:
	if absf(v) < 0.0001:
		return "日变 约0"
	return "日变 %s%s" % ["+" if v > 0.0 else "", UITokens.format_compact_number_cn(v, 2)]


func _relative_sea_level_text(elev: float, sea: float) -> String:
	var delta := elev - sea
	return "Δ海面 %+.2f" % delta


func _resource_index_text(v: float) -> String:
	return "储量 %s" % UITokens.format_compact_number_cn(v, 2)


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


func _resource_icon(resource_id: String, name: String) -> String:
	if resource_id in ["timber", "rubber_tree", "medicinal_herbs", "spice_plants"] or name.contains("木"):
		return "eco"
	if resource_id in ["fertile_soil", "wheat", "rice", "corn", "potato", "flax", "cotton"]:
		return "crop"
	if resource_id in ["horses", "wild_game", "cattle", "sheep", "pigs"]:
		return "livestock"
	if resource_id in ["oil", "natural_gas"]:
		return "fuel"
	return "resource"


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
	if t < 0.55: return "温暖"
	if t < 0.75: return "炎热"
	return "酷热"


func _moisture_band(m: float) -> String:
	if m < 0.20: return "极干"
	if m < 0.40: return "干燥"
	if m < 0.60: return "适中"
	if m < 0.80: return "湿润"
	return "极湿"
