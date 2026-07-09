extends RefCounted
class_name CellInspectorViewModel

var _map: MapData
var _generator
var _view_adapter: DCViewAdapter
var _world_clock: WorldClock
var _sea_level: float = 0.42
var _hex_size: float = 22.0
var _resource_prev_reserves: Dictionary = {}


func set_context(map: MapData, generator, view_adapter: DCViewAdapter, world_clock: WorldClock, sea_level: float, hex_size: float) -> void:
	_map = map
	_generator = generator
	_view_adapter = view_adapter
	_world_clock = world_clock
	_sea_level = sea_level
	_hex_size = hex_size


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
	var habitability := _habitability_score(temp, moist, vitality, elev, passable_land, is_water)
	var risk := _risk_score(wf, snow, cell, idx)
	var ecology_label := _vitality_band(vitality) if not is_water else "水域"
	var resource_label := String(resource_summary.get("label", "—"))
	var weather_label := _weather_name(cell, idx)
	var tabs := [
		{"id": "overview", "label": "总览", "icon": "overview"},
		{"id": "geography", "label": "地势", "icon": "geo"},
		{"id": "climate", "label": "气候", "icon": "sun"},
		{"id": "hydrology", "label": "水文", "icon": "water"},
		{"id": "ecology", "label": "生态", "icon": "eco"},
		{"id": "resources", "label": "资源", "icon": "resource"},
		{"id": "history", "label": "记录", "icon": "history"},
	]
	return {
		"header": {
			"title": "%s · %s" % [LandformType.name_cn(landform_v), TerrainType.terrain_name_cn(terrain_v)],
			"subtitle": "cube(%d,%d,%d) · offset(%d,%d)" % [cell.q, cell.r, cell.s, off.x, off.y],
			"badges": _header_badges(terrain_v, landform_v, vegetation_v, cover_v, weather_label),
		},
		"score": {
			"title": "地块适宜度",
			"value": habitability,
			"caption": _score_caption(habitability),
			"accent": _score_color(habitability),
		},
		"summary_cards": [
			{"title": "地势", "value": _elevation_band(elev, _sea_level), "subtitle": _elevation_index_text(elev), "accent": UITokens.GEO, "icon": "geo"},
			{"title": "气候", "value": "%s/%s" % [_temperature_band(temp), _moisture_band(moist)], "subtitle": "T=%.2f · M=%.2f" % [temp, moist], "accent": UITokens.CLIMATE, "icon": "☼"},
			{"title": "生态", "value": ecology_label, "subtitle": VegetationType.name_cn(vegetation_v), "accent": UITokens.ECO, "icon": "♣"},
			{"title": "资源", "value": resource_label, "subtitle": String(resource_summary.get("subtitle", "")), "accent": UITokens.RESOURCE, "trend": String(resource_summary.get("trend", "")), "icon": "◆"},
		],
		"tabs": tabs,
		"categories": {
			"overview": _overview_category(cell, idx, habitability, risk, resource_summary, terrain_v, landform_v, vegetation_v, cover_v, temp, moist, wf, vitality, is_water),
			"geography": _geography_category(cell, idx, off, terrain_v, landform_v, elev, passable_land),
			"climate": _climate_category(cell, idx, temp, moist, base_moist, wf),
			"hydrology": _hydrology_category(cell, idx, wf, snow, is_water),
			"ecology": _ecology_category(cell, idx, vegetation_v, cover_v, vitality, is_water),
			"resources": _resources_category(resource_state),
			"history": _history_category(cell),
		},
	}


func _overview_category(cell: HexCell, idx: int, habitability: float, risk: float, resource_summary: Dictionary, terrain_v: int, landform_v: int, vegetation_v: int, cover_v: int, temp: float, moist: float, wf: Dictionary, vitality: float, is_water: bool) -> Dictionary:
	var insights := [
		{"text": "风险 %d%% · %s" % [int(round(risk * 100.0)), _risk_caption(risk)], "accent": _risk_color(risk)},
		{"text": "资源 · %s" % String(resource_summary.get("label", "—")), "accent": UITokens.RESOURCE},
	]
	return {
		"insights": insights,
		"metrics": [
			{"title": "地表", "value": LandformType.name_cn(landform_v), "subtitle": TerrainType.terrain_name_cn(terrain_v), "accent": UITokens.GEO, "icon": "▰"},
			{"title": "天气", "value": _weather_name(cell, idx), "subtitle": "I=%.2f" % _weather_intensity(cell, idx), "accent": UITokens.WATER, "icon": "☁"},
			{"title": "植被", "value": VegetationType.name_cn(vegetation_v), "subtitle": "V=%.2f" % vitality, "accent": UITokens.ECO, "icon": "♣"},
			{"title": "覆盖", "value": CoverType.name_cn(cover_v), "subtitle": "雪 S=%.2f" % _snow_cover(cell, idx), "accent": UITokens.WATER, "icon": "✦"},
		],
		"badges": _header_badges(terrain_v, landform_v, vegetation_v, cover_v, _weather_name(cell, idx)),
		"charts": [{"title": "近期生态轨迹", "values": _history_values(cell), "accent": UITokens.ECO}],
	}


func _geography_category(cell: HexCell, idx: int, off: Vector2i, terrain_v: int, landform_v: int, elev: float, passable_land: bool) -> Dictionary:
	var feats := PackedStringArray()
	if _has_river(cell, idx): feats.append("河流")
	if cell.has_volcano: feats.append("火山")
	if cell.is_lake_seed: feats.append("湖泊种子")
	return {
		"insights": [
			{"text": "%s · %s · %s" % [_elevation_index_text(elev), _relative_sea_level_text(elev, _sea_level), _elevation_band(elev, _sea_level)], "accent": UITokens.GEO},
			{"text": "陆 %s · 海 %s · 移动 %d" % ["可通" if passable_land else "阻断", "可通" if cell.passable_sea else "阻断", TerrainType.get_move_cost(terrain_v)], "accent": UITokens.ACCENT},
		],
		"metrics": [
			{"title": "地形", "value": TerrainType.terrain_name_cn(terrain_v), "subtitle": LandformType.name_cn(landform_v), "accent": UITokens.GEO, "icon": "▰"},
			{"title": "特征", "value": "无" if feats.is_empty() else ", ".join(feats), "subtitle": "", "accent": UITokens.WATER, "icon": "✦"},
			{"title": "高程", "value": _elevation_index_text(elev), "subtitle": _relative_sea_level_text(elev, _sea_level), "accent": UITokens.GEO, "icon": "geo"},
			{"title": "坐标", "value": "%d,%d,%d" % [cell.q, cell.r, cell.s], "subtitle": "cube", "accent": UITokens.ACCENT, "icon": "⌖"},
		],
		"gauges": [
			{"label": "高程剖面", "value": elev, "accent": UITokens.GEO, "marker": _sea_level, "status_label": _elevation_band(elev, _sea_level), "value_text": _relative_sea_level_text(elev, _sea_level)},
		],
	}


func _climate_category(cell: HexCell, idx: int, temp: float, moist: float, base_moist: float, wf: Dictionary) -> Dictionary:
	var anomaly: float = _world_clock.climate_anomaly if _world_clock != null else 0.0
	var sun_text := _sun_text(cell)
	return {
		"insights": [
			{"text": sun_text, "accent": UITokens.CLIMATE},
			{"text": "全球异常 %+.2f" % anomaly, "accent": UITokens.CLIMATE},
		],
		"metrics": [
			{"title": "气候型", "value": "%s/%s" % [_temperature_band(temp), _moisture_band(moist)], "subtitle": "归一气候指数", "accent": UITokens.CLIMATE, "icon": "sun"},
			{"title": "降水型", "value": _precip_band(float(wf["precip"])), "subtitle": _cloud_band(float(wf["cloud"])), "accent": UITokens.WATER, "icon": "water"},
		],
		"gauges": [
			{"label": "温度指数", "value": temp, "accent": UITokens.CLIMATE, "status_label": _temperature_band(temp), "value_text": "T=%.2f" % temp},
			{"label": "湿度指数", "value": moist, "accent": UITokens.WATER, "marker": base_moist, "status_label": _moisture_band(moist), "value_text": "M=%.2f" % moist},
			{"label": "云量指数", "value": float(wf["cloud"]), "accent": UITokens.WATER, "status_label": _cloud_band(float(wf["cloud"])), "value_text": "C=%.2f" % float(wf["cloud"])},
			{"label": "降水指数", "value": float(wf["precip"]), "accent": UITokens.WATER, "status_label": _precip_band(float(wf["precip"])), "value_text": "P=%.2f" % float(wf["precip"])},
		],
		"charts": [{"title": "温度记忆", "values": _temperature_memory(cell, idx, temp), "accent": UITokens.CLIMATE}],
	}


func _hydrology_category(cell: HexCell, idx: int, wf: Dictionary, snow: float, is_water: bool) -> Dictionary:
	var ocean := _ocean_current(cell, idx)
	var wind := _wind_vector(cell, idx)
	var upwelling := _upwelling(cell, idx)
	return {
		"insights": [
			{"text": "风 %s · 洋流 %s" % [_dir_degrees_text(wind), _dir_degrees_text(ocean)], "accent": UITokens.ACCENT},
		],
		"metrics": [
			{"title": "洋流", "value": "%.3f" % ocean.length() if is_water else "—", "subtitle": _dir_degrees_text(ocean), "accent": UITokens.WATER, "icon": "≈"},
			{"title": "风", "value": "%.3f" % _wind_speed(cell, idx), "subtitle": _dir_degrees_text(wind), "accent": UITokens.ACCENT, "icon": "↗"},
			{"title": "上升流", "value": "%+.3f" % upwelling if is_water else "—", "subtitle": "", "accent": UITokens.WATER, "icon": "↑"},
		],
		"gauges": [
			{"label": "水汽指数", "value": float(wf["vapor"]), "accent": UITokens.WATER, "status_label": _moisture_band(float(wf["vapor"])), "value_text": "V=%.2f" % float(wf["vapor"])},
			{"label": "云量指数", "value": float(wf["cloud"]), "accent": UITokens.WATER, "status_label": _cloud_band(float(wf["cloud"])), "value_text": "C=%.2f" % float(wf["cloud"])},
			{"label": "降水指数", "value": float(wf["precip"]), "accent": UITokens.WATER, "status_label": _precip_band(float(wf["precip"])), "value_text": "P=%.2f" % float(wf["precip"])},
			{"label": "雪盖/海冰", "value": snow, "accent": UITokens.WATER, "status_label": _cover_intensity_band(snow), "value_text": "S=%.2f" % snow},
		],
	}


func _ecology_category(cell: HexCell, idx: int, vegetation_v: int, cover_v: int, vitality: float, is_water: bool) -> Dictionary:
	var stress_heat: float = _adapter_float("get_vegetation_heat_stress", idx, cell.vegetation_heat_stress)
	var stress_drought: float = _adapter_float("get_vegetation_drought_stress", idx, cell.vegetation_drought_stress)
	var stress_cold: float = _adapter_float("get_vegetation_cold_stress", idx, cell.vegetation_cold_stress)
	var regen: float = _adapter_float("get_vegetation_regen_score", idx, cell.vegetation_regen_score)
	var countdown := _succession_text(cell)
	return {
		"insights": [
			{"text": "%s · %s" % [VegetationType.name_cn(vegetation_v), CoverType.name_cn(cover_v)], "accent": UITokens.ECO},
			{"text": "生命 %s · %s" % ["—" if is_water else "V=%.2f" % vitality, countdown], "accent": UITokens.ECO if vitality >= 0.45 else UITokens.RISK},
		],
		"metrics": [
			{"title": "植被", "value": VegetationType.name_cn(vegetation_v), "subtitle": VegetationType.name_cn(cell.base_vegetation), "accent": UITokens.ECO, "icon": "♣"},
			{"title": "覆盖", "value": CoverType.name_cn(cover_v), "subtitle": _cover_intensity_band(_snow_cover(cell, idx)), "accent": UITokens.WATER, "icon": "✦"},
			{"title": "再生", "value": "%.2f" % regen, "subtitle": "", "accent": UITokens.ECO, "icon": "↟"},
		],
		"gauges": [
			{"label": "热胁迫", "value": stress_heat, "accent": UITokens.CLIMATE, "status_label": _stress_band(stress_heat), "value_text": "H=%.2f" % stress_heat},
			{"label": "旱胁迫", "value": stress_drought, "accent": UITokens.WARN, "status_label": _stress_band(stress_drought), "value_text": "D=%.2f" % stress_drought},
			{"label": "冷胁迫", "value": stress_cold, "accent": UITokens.WATER, "status_label": _stress_band(stress_cold), "value_text": "C=%.2f" % stress_cold},
		],
		"charts": [{"title": "植被历史", "values": _history_values(cell), "accent": UITokens.ECO}],
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
	for data in sorted:
		var item: Dictionary = data
		if not bool(item.get("available", true)):
			continue
		var reserve := float(item.get("reserve", 0.0))
		var delta := float(item.get("delta", 0.0))
		if reserve <= 0.000001:
			continue
		var density := _resource_density_band(reserve)
		rows.append({
			"name": String(item.get("name", "资源")),
			"value": _resource_index_text(reserve),
			"density": density,
			"delta": _daily_delta_text(delta),
			"accent": UITokens.RESOURCE,
			"icon": _resource_icon(String(item.get("name", ""))),
		})
		if notable_count < 3 and (reserve > 0.65 or absf(delta) > 0.0005):
			insights.append({"text": "%s · %s · %s" % [String(item.get("name", "资源")), density, _daily_delta_text(delta)], "accent": UITokens.RESOURCE})
			notable_count += 1
	if rows.is_empty():
		return {"insights": [{"text": "此地块无可显示自然资源。", "accent": UITokens.TEXT_MUTED}]}
	if insights.is_empty():
		insights.append({"text": "资源平缓", "accent": UITokens.TEXT_MUTED})
	return {"insights": insights, "resource_rows": rows}


func _history_category(cell: HexCell) -> Dictionary:
	return {
		"insights": [{"text": _history_sentence(cell), "accent": UITokens.ECO}],
		"charts": [
			{"title": "近期植被序列", "values": _history_values(cell), "accent": UITokens.ECO},
			{"title": "温度记忆", "values": _temperature_memory(cell, int(cell.index), _temp(cell, int(cell.index))), "accent": UITokens.CLIMATE},
		],
		"badges": _history_badges(cell),
	}


func _header_badges(terrain_v: int, landform_v: int, vegetation_v: int, cover_v: int, weather_label: String) -> Array:
	return [
		{"text": TerrainType.terrain_name_cn(terrain_v), "accent": UITokens.GEO},
		{"text": LandformType.name_cn(landform_v), "accent": UITokens.GEO},
		{"text": VegetationType.name_cn(vegetation_v), "accent": UITokens.ECO},
		{"text": CoverType.name_cn(cover_v), "accent": UITokens.WATER},
		{"text": weather_label, "accent": UITokens.WATER},
	]


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
		var name_cn: String = String(p.display_name) if String(p.display_name) != "" else String(p.id)
		var available := not (bool(p.land_only) and is_water)
		var reserve := 0.0
		var delta := 0.0
		if bool(p.land_only) and is_water:
			items.append({"name": name_cn, "available": false, "reserve": 0.0, "delta": 0.0, "rank": -1.0})
			continue
		reserve = _resource_reserve(p, idx)
		var field: String = ResourceProfileRegistry.reserve_map_field(p)
		var key := "%d:%s" % [idx, field]
		if _resource_prev_reserves.has(key):
			delta = reserve - float(_resource_prev_reserves[key])
		_resource_prev_reserves[key] = reserve
		items.append({
			"name": name_cn,
			"available": available,
			"reserve": reserve,
			"delta": delta,
			"rank": reserve + absf(delta) * 8.0,
		})
	return items


func _resource_summary(resource_state: Array) -> Dictionary:
	var best: Dictionary = {}
	for raw in resource_state:
		var item: Dictionary = raw
		if not bool(item.get("available", true)):
			continue
		if best.is_empty() or float(item.get("rank", 0.0)) > float(best.get("rank", 0.0)):
			best = item
	if best.is_empty():
		return {"label": "—", "subtitle": "无可用资源", "trend": ""}
	var reserve := float(best.get("reserve", 0.0))
	var delta := float(best.get("delta", 0.0))
	return {
		"label": String(best.get("name", "资源")),
		"subtitle": "%s · %s" % [_resource_density_band(reserve), _resource_index_text(reserve)],
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


func _habitability_score(temp: float, moist: float, vitality: float, elev: float, passable_land: bool, is_water: bool) -> float:
	if is_water:
		return clampf((1.0 - absf(temp - 0.48) / 0.52) * 0.35 + moist * 0.20 + 0.20, 0.0, 1.0)
	var temp_score := clampf(1.0 - absf(temp - 0.52) / 0.52, 0.0, 1.0)
	var moist_score := clampf(1.0 - absf(moist - 0.58) / 0.58, 0.0, 1.0)
	var elev_score := clampf(1.0 - maxf(elev - 0.78, 0.0) / 0.22, 0.0, 1.0)
	var pass_score := 1.0 if passable_land else 0.25
	return clampf(temp_score * 0.28 + moist_score * 0.24 + vitality * 0.24 + elev_score * 0.14 + pass_score * 0.10, 0.0, 1.0)


func _risk_score(wf: Dictionary, snow: float, cell: HexCell, idx: int) -> float:
	var weather := _weather_intensity(cell, idx)
	var precip := float(wf["precip"])
	var cloud := float(wf["cloud"])
	var wind := clampf(_wind_speed(cell, idx), 0.0, 1.0)
	return clampf(precip * 0.32 + cloud * 0.18 + snow * 0.20 + weather * 0.20 + wind * 0.10, 0.0, 1.0)


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


func _risk_color(v: float) -> Color:
	if v >= 0.66: return UITokens.RISK
	if v >= 0.35: return UITokens.WARN
	return UITokens.GOOD


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


func _sun_text(cell: HexCell) -> String:
	if _generator == null or _world_clock == null:
		return "日射 · —"
	var phase: float = _world_clock.season_phase()
	var subsolar_deg: float = rad_to_deg(_generator._subsolar_lat_rad(phase))
	var ny: float = _generator.cell_ny(cell)
	var dev: float = _generator._insol_dev(ny, phase)
	return "日射 %+.0f%% · 直射 %+.0f°" % [dev * 100.0, subsolar_deg]


func _succession_text(cell: HexCell) -> String:
	if cell._vitality_low_streak > 0:
		var rem: int = int(_generator._c().succession_degrade_days if _generator != null else 180) - int(cell._vitality_low_streak)
		return "退化倒计时 %d 天" % maxi(rem, 0) if rem <= 45 else "存在退化压力"
	if cell._vitality_high_streak > 0:
		var rem2: int = int(_generator._c().succession_upgrade_days if _generator != null else 360) - int(cell._vitality_high_streak)
		return "升级倒计时 %d 天" % maxi(rem2, 0) if rem2 <= 60 else "存在恢复趋势"
	return "暂无演替倒计时"


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


func _temperature_memory(cell: HexCell, idx: int, current_temp: float) -> Array:
	var t30: float = _view_adapter.get_temp_30d(idx) if _view_adapter != null else float(cell.temp_30d_mean)
	var t365: float = _view_adapter.get_temp_365d(idx) if _view_adapter != null else float(cell.temp_365d_mean)
	return _densify_series([t365, (t365 + t30) * 0.5, t30, current_temp], 9)


func _trend_arrow(v: float) -> String:
	if v > 0.0001: return "↑"
	if v < -0.0001: return "↓"
	return "→"


func _daily_delta_text(v: float) -> String:
	if absf(v) < 0.0001:
		return "日变 约0"
	return "日变 %s%s" % ["+" if v > 0.0 else "", UITokens.format_compact_number_cn(absf(v), 2)]


func _elevation_index_text(elev: float) -> String:
	return "h=%.2f" % elev


func _relative_sea_level_text(elev: float, sea: float) -> String:
	var delta := elev - sea
	return "Δ海面 %+.2f" % delta


func _resource_index_text(v: float) -> String:
	return "储量 %s" % UITokens.format_compact_number_cn(v, 2)


func _risk_caption(v: float) -> String:
	if v < 0.25: return "安定"
	if v < 0.50: return "注意"
	if v < 0.75: return "紧张"
	return "危险"


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


func _resource_icon(name: String) -> String:
	if name.contains("木") or name.contains("橡胶"):
		return "♣"
	if name.contains("麦") or name.contains("稻") or name.contains("玉米") or name.contains("土豆") or name.contains("土壤"):
		return "✤"
	if name.contains("马"):
		return "♞"
	if name.contains("煤") or name.contains("石") or name.contains("铁") or name.contains("铜") or name.contains("金") or name.contains("银") or name.contains("盐") or name.contains("稀土") or name.contains("硝"):
		return "◆"
	if name.contains("油") or name.contains("气"):
		return "◈"
	return "◇"


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
