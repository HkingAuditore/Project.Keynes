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
var _market_prev_stock: Dictionary = {}
var _temperature_histories: Dictionary = {}
var _temperature_history_order: Array[int] = []
var _need_display_names: Dictionary = {}
var _need_display_names_loaded := false


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
	var population_summary := _population_summary(idx)
	var country_summary := _country_summary(idx)
	var habitability := _habitability_score(temp, moist, vitality, elev, passable_land, is_water)
	var tabs := [
		{"id": "geography", "label": "地理信息", "icon": "geo"},
		{"id": "population", "label": "人口信息", "icon": "growth"},
		{"id": "market", "label": "市场信息", "icon": "resource"},
		{"id": "buildings", "label": "建筑", "icon": "building"},
		{"id": "natural_resources", "label": "自然资源", "icon": "eco"},
	]
	return {
		"header": _build_header(off, terrain_v, landform_v, country_summary),
		"score": {
			"id": "habitability",
			"title": "适宜度",
			"value": habitability,
			"caption": _score_caption(habitability),
			"accent": _score_color(habitability),
		},
		"summary_cards": _summary_cards(temp, moist, population_summary, country_summary),
		"tabs": tabs,
		"categories": {
			"geography": _geography_information_category(cell, idx, terrain_v,
				landform_v, vegetation_v, cover_v, elev, temp, moist, base_moist,
				wf, snow, vitality, passable_land, is_water),
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
	var habitability := _habitability_score(temp, moist, vitality, elev, passable_land, is_water)
	var tab_id := current_tab if current_tab != "" else "geography"
	var population_summary: Dictionary
	var country_summary := _country_summary(idx)
	var category: Dictionary
	if tab_id == "population":
		population_summary = _population_snapshot(idx)
		category = _population_category(population_summary, _market_snapshot(idx))
	else:
		population_summary = _population_summary(idx)
		category = _geography_information_category(cell, idx, terrain_v,
			landform_v, vegetation_v, cover_v, elev, temp, moist, base_moist,
			wf, snow, vitality, passable_land, is_water) if tab_id == "geography" \
			else build_tab_category(cell, tab_id)
	if category.is_empty():
		tab_id = "geography"
		category = _geography_information_category(cell, idx, terrain_v,
			landform_v, vegetation_v, cover_v, elev, temp, moist, base_moist,
			wf, snow, vitality, passable_land, is_water)
	return {
		"header": _build_header(off, terrain_v, landform_v, country_summary),
		"score": {
			"id": "habitability",
			"title": "适宜度",
			"value": habitability,
			"caption": _score_caption(habitability),
			"accent": _score_color(habitability),
		},
		"summary_cards": _summary_cards(temp, moist, population_summary, country_summary),
		"tab_id": tab_id,
		"category": category,
	}


func build_tab_category(cell: HexCell, tab_id: String) -> Dictionary:
	if cell == null or _map == null:
		return {}
	var idx := int(cell.index)
	match tab_id:
		"population":
			return _population_category(_population_snapshot(idx), _market_snapshot(idx))
		"market":
			return _market_category(_market_snapshot(idx))
		"buildings":
			return _building_category(_building_snapshot(idx))
		"natural_resources":
			return _resources_category(_resource_state(
				idx, LandformType.is_water(_landform(cell, idx)),
				_resource_visibility_context(idx)))
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
			return _geography_information_category(
				cell, idx, terrain_v, landform_v, vegetation_v, cover_v, elev,
				temp, moist, base_moist, _weather_field(cell, idx),
				_snow_cover(cell, idx), _vitality(cell, landform_v),
				TerrainType.is_passable_land(terrain_v), is_water)
	return {}


func _build_header(
		off: Vector2i,
		terrain_v: int,
		landform_v: int,
		country_summary: Dictionary
) -> Dictionary:
	var country_name := String(country_summary.get("country_name", "无主地"))
	return {
		"title": "%s · %s" % [LandformType.name_cn(landform_v), TerrainType.terrain_name_cn(terrain_v)],
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
			"id": "summary_country",
			"title": "国家",
			"value": String(country_summary.get("country_name", "无主地")),
			"subtitle": "%s · 物资 %d 类 · 科技 %d 项" % [
				_money_text(int(country_summary.get("cash", 0))),
				int(country_summary.get("nonzero_good_count", 0)),
				int(country_summary.get("technology_count", 0)),
			],
			"accent": UITokens.RESOURCE,
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


func _population_summary(cell_idx: int) -> Dictionary:
	if _generator == null or not _generator.has_method("get_economy_facade"):
		return {}
	var facade = _generator.get_economy_facade()
	if facade == null or not facade.has_method("population_cell_summary"):
		return {}
	return facade.population_cell_summary(cell_idx)


func _country_summary(cell_idx: int) -> Dictionary:
	if _generator == null or not _generator.has_method("get_country_facade"):
		return {"country_name": "无主地"}
	var facade = _generator.get_country_facade()
	if facade == null or not facade.has_method("cell_summary"):
		return {"country_name": "无主地"}
	var summary: Dictionary = facade.cell_summary(cell_idx)
	return summary if bool(summary.get("ok", false)) else {"country_name": "无主地"}


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


func _population_category(snapshot: Dictionary, market_snapshot: Dictionary = {}) -> Dictionary:
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
	var satisfaction: PackedInt32Array = snapshot.get(
		"survival_satisfaction_by_cohort_q16",
		snapshot.get("satisfaction_by_cohort_q16", PackedInt32Array()))
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
	var local_prices := {}
	var local_technology_available := {}
	var enforce_local_technology := false
	if bool(market_snapshot.get("ok", false)):
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
		var demand_groups := []
		var demand_total := 0
		var demand_total_cost := 0
		var demand_cost_available := true
		var demand_names := PackedStringArray()
		var demand_metadata := _demand_good_metadata(snapshot, i)
		var good_metadata: Dictionary = demand_metadata.get("good_metadata", {}) \
			if bool(demand_metadata.get("ok", false)) else {}
		var visible_demand_count := 0
		for good_idx in range(demand_good_ids.size()):
			var stable_id := String(demand_good_ids[good_idx])
			var profile = GoodProfileRegistry.profile_by_id(stable_id)
			var display_name := String(profile.display_name) if profile != null and String(profile.display_name) != "" else stable_id
			var quantity := int(demand_by_good.get(good_idx, 0))
			var has_price := local_prices.has(stable_id)
			var price := int(local_prices.get(stable_id, 0))
			var daily_cost := quantity * price / 1000 if has_price else 0
			var metadata: Dictionary = good_metadata.get(stable_id, {})
			var unlocked_alternative := not metadata.is_empty() and enforce_local_technology \
				and bool(local_technology_available.get(stable_id, false))
			var visible := quantity > 0 or unlocked_alternative
			if visible:
				visible_demand_count += 1
			if quantity > 0:
				demand_total += quantity
				if has_price:
					demand_total_cost += daily_cost
				else:
					demand_cost_available = false
				if demand_names.size() < 3:
					demand_names.append(display_name)
			var need_names: Array = metadata.get("need_names", [])
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
				"has_bundle": bool(metadata.get("has_bundle", false)),
				"has_substitute": bool(metadata.get("has_substitute", false)),
				"is_unallocated_alternative": quantity <= 0 and unlocked_alternative,
				"icon": "resource",
				"visible": visible,
			})
		demand_groups = _group_demand_rows_by_usage(demand_rows)
		var income_rows := []
		var expense_rows := []
		if settlement_available and settlement_offsets.size() == populations.size() + 1:
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
			"name": "%s · %s" % [profession_name, ethnicity_name],
			"population": "%s 人" % UITokens.format_compact_number_cn(float(population), 1),
			"wealth": "人均 %s" % _money_text(wealth_pc),
			"income": "+%s" % _money_text(income_pc) if settlement_available else "+—",
			"expense": "−%s" % _money_text(expense_pc) if settlement_available else "−—",
			"net": "%s%s" % ["+" if net_pc > 0 else ("−" if net_pc < 0 else ""), _money_text(absi(net_pc))] if settlement_available else "—",
			"net_positive": net_pc >= 0,
			"status": "%s就业 %s · 生存满足 %.1f%% · 结算 %d日" % [
				"商人 · " if i < merchant_flags.size() and merchant_flags[i] != 0 else "",
				UITokens.format_compact_number_cn(float(owners + employees), 1), sat * 100.0, settlement_days],
			"accent": UITokens.ACCENT,
			"icon": "growth",
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
		insights.append({"id": "population_empty", "text": "此地块尚无人口。可在世界生成页启用测试人口，或由正式数据源导入。", "accent": UITokens.TEXT_MUTED, "icon": "growth"})
	elif not bool(snapshot.get("demand_preview_environment_ready", false)):
		insights.append({"id": "population_demand_neutral_environment", "text": "环境快照暂不可用，预计需求使用最近冻结或中性环境。", "accent": UITokens.WARN, "icon": "weather"})
	if not rows.is_empty() and settlement_pending:
		insights.append({"id": "population_settlement_pending", "text": "已开始追踪此地；下次结算后可查看精确收支来源。", "accent": UITokens.TEXT_MUTED, "icon": "history"})
	return {
		"insights": insights,
		"metrics": [
			{"id": "population_total", "title": "总人口", "value": "%s 人" % UITokens.format_compact_number_cn(float(snapshot.get("population", 0)), 1), "subtitle": "%d 个阶层" % int(snapshot.get("cohort_count", 0)), "accent": UITokens.ACCENT, "icon": "growth"},
			{"id": "population_funds", "title": "总资金", "value": _money_text(int(snapshot.get("funds", 0))), "subtitle": "收入 %s · 支出 %s" % [_money_text(int(snapshot.get("epoch_income", 0))), _money_text(int(snapshot.get("epoch_expense", 0)))], "accent": UITokens.RESOURCE, "icon": "resource"},
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
		groups[group_idx] = group
	return groups


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
		return {"insights": [{"id": "market_unavailable", "text": "市场运行时尚未就绪。", "accent": UITokens.TEXT_MUTED, "icon": "resource"}]}
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
	var enforce_technology := technology_available.size() == good_ids.size()
	var market_id := int(snapshot.get("market_id", snapshot.get("cell_idx", -1)))
	var sample_day := _current_sample_day()
	for i in range(good_ids.size()):
		if enforce_technology and technology_available[i] == 0:
			continue
		var stable_id := String(good_ids[i])
		var profile = GoodProfileRegistry.profile_by_id(stable_id)
		var display_name := String(profile.display_name) if profile != null else stable_id
		var stock_daily := _sample_daily_delta(_market_prev_stock,
			"%d:%s" % [market_id, stable_id], float(stock[i]) / 1000.0, sample_day)
		var shortage := float(shortage_q16[i]) * 100.0 / 65536.0 if i < shortage_q16.size() else 0.0
		rows.append({
			"id": "market_%s" % stable_id,
			"name": display_name,
			"stock": "%s 单位" % UITokens.format_compact_number_cn(float(stock[i]) / 1000.0, 2),
			"price": _money_text(prices[i] if i < prices.size() else 0),
			"delta": _daily_delta_text(stock_daily),
			"risk": "短缺" if shortage >= 25.0 else "",
			"detail_rows": [
				{"id": "household_demand", "name": "居民需求", "value": UITokens.format_compact_number_cn(float(demand_ema[i]) / 1000.0, 2) if i < demand_ema.size() else "0"},
				{"id": "business_demand", "name": "产业需求", "value": UITokens.format_compact_number_cn(float(business_demand_ema[i]) / 1000.0, 2) if i < business_demand_ema.size() else "0"},
				{"id": "supply", "name": "供给", "value": UITokens.format_compact_number_cn(float(offered_supply_ema[i]) / 1000.0, 2) if i < offered_supply_ema.size() else "0"},
				{"id": "cost_anchor", "name": "成本锚", "value": _money_text(int(cost_anchor[i])) if i < cost_anchor.size() and cost_anchor[i] > 0 else "—"},
				{"id": "shortage", "name": "短缺", "value": "%.1f%%" % shortage},
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
		"market_rows": rows,
	}


func _building_category(snapshot: Dictionary) -> Dictionary:
	if snapshot.is_empty() or not bool(snapshot.get("ok", false)):
		return {"insights": [{"id": "buildings_unavailable", "text": "建筑运行时尚未就绪。", "accent": UITokens.TEXT_MUTED, "icon": "building"}]}
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
	var owner_slots: PackedInt64Array = snapshot.get("building_owner_slots", PackedInt64Array())
	var period_days := maxi(1, int(snapshot.get("period_days", 1)))
	for i in range(group_types.size()):
		var type_idx := int(group_types[i])
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
			var utilization := int(planned_utilization[i]) if i < planned_utilization.size() else 65536
			owner_required = int(owner_physical_capacity * utilization / 65536.0)
			if owner_required == 0 and owner_physical_capacity > 0 and utilization > 0:
				owner_required = 1
		var owner_actual := int(filled_owner[i]) if i < filled_owner.size() else 0
		var owner_open := int(owner_openings[i]) if i < owner_openings.size() else maxi(0, owner_required - owner_actual)
		var job_rows := [
			{"id": "owner_job", "name": "业主（本期岗位） · %s" % _owner_profession_name(snapshot, int(owner_signatures[i]) if i < owner_signatures.size() else -1), "value": "%d / %d" % [owner_actual, owner_required], "ratio": float(owner_actual) / float(owner_required) if owner_required > 0 else 1.0},
		]
		if role_offsets.size() == group_types.size() + 1:
			for role in range(role_offsets[i], role_offsets[i + 1]):
				var required := int(role_required[role]) if role < role_required.size() else 0
				var filled := int(role_filled[role]) if role < role_filled.size() else 0
				job_rows.append({
					"id": "job_%d" % role,
					"name": "雇员 · %s" % _profession_name(snapshot, int(role_professions[role]) if role < role_professions.size() else -1),
					"value": "%d / %d" % [filled, required],
					"ratio": float(filled) / float(required) if required > 0 else 1.0,
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
		var status_parts: Array[String] = ["本期到岗 %d/%d" % [staffing_actual, staffing_required]]
		if owner_open > 0:
			status_parts.append("招聘空缺 %d" % owner_open)
		var idle_owner_capacity := maxi(0, owner_physical_capacity - owner_required)
		if idle_owner_capacity > 0:
			status_parts.append("闲置产能 %d 席" % idle_owner_capacity)
		status_parts.append("实际产能 %.1f%%" % (
			float(capacity_q16[i]) * 100.0 / 65536.0 if i < capacity_q16.size() else 0.0))
		var status := " · ".join(status_parts)
		if i < wage_suspended.size() and int(wage_suspended[i]) != 0:
			status = "工资未足额支付 · 本期停产"
		if i < capacity_q16.size() and int(capacity_q16[i]) == 0 and _building_resource_depleted(snapshot, type_idx):
			status = "资源短缺"
		rows.append({
			"id": "building_%d_%d" % [type_idx, i],
			"name": String(type_names[type_idx]) if type_idx >= 0 and type_idx < type_names.size() else (String(type_ids[type_idx]) if type_idx >= 0 and type_idx < type_ids.size() else "建筑"),
			"count": "%d 栋" % count,
			"owner": "业主 · %s" % _owner_profession_name(snapshot, int(owner_signatures[i]) if i < owner_signatures.size() else -1),
			"status": status,
			"profit": "%s%s" % ["+" if profit > 0 else "", _money_text(profit)],
			"profit_label": "利润" if profit >= 0 else "亏损",
			"accent": UITokens.GOOD if profit > 0 else (UITokens.RISK if profit < 0 else UITokens.TEXT_MUTED),
			"icon": "building", "job_rows": job_rows,
			"production_rows": production_rows, "finance": finance, "visible": true,
		})
	_append_construction_rows(rows, snapshot, type_ids, type_names)
	var total_count := _sum_i64(snapshot.get("building_counts_by_type", PackedInt64Array()))
	return {
		"insights": [{"id": "buildings_empty", "text": "此地块当前没有建筑。", "accent": UITokens.TEXT_MUTED, "icon": "building"}] if rows.is_empty() else [],
		"metrics": [{"id": "building_total", "title": "建筑总数", "value": "%s 栋" % UITokens.format_compact_number_cn(float(total_count), 1), "subtitle": "%d 个业主建筑组" % group_types.size(), "accent": UITokens.ACCENT, "icon": "building"}],
		"building_rows": rows,
	}


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
		var label := _good_display_name(String(good_ids[good_idx]))
		var efficiency := int(efficiencies[candidate_idx]) if candidate_idx < efficiencies.size() else 65536
		if efficiency != 65536:
			label += " %.0f%%" % (float(efficiency) * 100.0 / 65536.0)
		labels.append(label)
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
		rows.append({"id": "construction_%d_%d" % [type_idx, i], "name": String(type_names[type_idx]) if type_idx >= 0 and type_idx < type_names.size() else (String(type_ids[type_idx]) if type_idx >= 0 and type_idx < type_ids.size() else "建筑"), "count": "%d 栋" % (int(counts[i]) if i < counts.size() else 0), "owner": "业主 · %s" % _owner_profession_name(snapshot, int(owners[i]) if i < owners.size() else -1), "status": "建造中 · 第 %d 日完工" % (int(ready_days[i]) if i < ready_days.size() else 0), "profit": "—", "profit_label": "未投产", "accent": UITokens.WARN, "icon": "building", "job_rows": [], "production_rows": [], "finance": {}, "visible": true})


func _owner_profession_name(snapshot: Dictionary, signature_idx: int) -> String:
	var signature_professions: PackedInt32Array = snapshot.get("signature_profession_ids", PackedInt32Array())
	return _profession_name(snapshot, int(signature_professions[signature_idx]) if signature_idx >= 0 and signature_idx < signature_professions.size() else -1)


func _profession_name(snapshot: Dictionary, profession_idx: int) -> String:
	var names: PackedStringArray = snapshot.get("profession_display_names", PackedStringArray())
	var ids: PackedStringArray = snapshot.get("profession_stable_ids", PackedStringArray())
	if profession_idx >= 0 and profession_idx < names.size(): return String(names[profession_idx])
	return String(ids[profession_idx]) if profession_idx >= 0 and profession_idx < ids.size() else "未知阶层"


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
	context.enforce_discovery = true
	if bool(summary.get("owned", false)):
		var country: Dictionary = country_facade.snapshot(int(summary.get("country_handle", 0)))
		if not bool(country.get("ok", false)):
			context.enforce_discovery = false
		else:
			context.technology_ids = country.get("technology_ids", PackedStringArray())
	var extractable := _extractable_resource_ids(_building_snapshot(cell_idx))
	if bool(extractable.get("ok", false)):
		context.enforce_extraction = true
		context.extractable_resource_ids = extractable.ids
	return context


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
		if enforce_extraction and not extractable_resource_ids.has(StringName(p.id)):
			continue
		var resource_id := String(p.id)
		var name_cn: String = String(p.display_name) if String(p.display_name) != "" else String(p.id)
		var available := ResourceProfileRegistry.habitat_available(p, habitat_mask)
		var reference_reserve := _resource_reference_reserve(p)
		var reserve := 0.0
		var delta := 0.0
		if not available:
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
		delta = _sample_daily_delta(_resource_prev_reserves, key, reserve, sample_day)
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
	# bootstrap 中地质省/矿带使用中心化场；这里取其理论最大正贡献，避免矿产密度被高估。
	initial_peak += maxf(float(profile.init_province) * 0.90, 0.0)
	initial_peak += maxf(float(profile.init_belt) * 0.56, 0.0)
	initial_peak += _max_positive_weight(profile.init_landform_weights)
	initial_peak += _max_positive_weight(profile.init_vegetation_weights)
	initial_peak *= maxf(float(profile.init_reserve_scale), 0.0)
	initial_peak = maxf(initial_peak, float(profile.init_min_reserve))
	initial_peak *= ResourceProfileRegistry.CELL_AREA_RESOURCE_SCALE

	# 可再生资源还要容纳最适气候下的长期平衡储量 P / decay_self。
	var runtime_peak := 0.0
	if float(profile.ecology_capacity) > 0.0:
		runtime_peak = float(profile.ecology_capacity) * \
			ResourceProfileRegistry.CELL_AREA_RESOURCE_SCALE
	elif float(profile.decay_self) > 0.000001:
		var peak_production := float(profile.gen_base) + float(profile.gen_self) - float(profile.decay_base)
		peak_production += maxf(float(profile.gen_temp) - float(profile.decay_temp), 0.0)
		peak_production += maxf(float(profile.gen_moisture) - float(profile.decay_moisture), 0.0)
		runtime_peak = maxf(peak_production, 0.0) * \
			ResourceProfileRegistry.CELL_AREA_RESOURCE_SCALE / float(profile.decay_self)
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


func _resource_icon(resource_id: String, name: String) -> String:
	if resource_id in ["timber", "rubber_tree", "medicinal_herbs", "spice_plants"] or name.contains("木"):
		return "eco"
	if resource_id in ["fertile_soil", "wheat", "rice", "corn", "potato", "flax", "cotton"]:
		return "crop"
	if resource_id in ["pasture", "wild_game"]:
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
