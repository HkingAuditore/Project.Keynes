extends RefCounted
class_name CellHoverViewModel

## 地块悬停卡的唯一数据来源。
##
## 只回答四个问题：这是什么 / 归谁 / 有多少人 / 有什么。
## 刻意不复用 CellInspectorViewModel.build()：那是完整档案（历史曲线、市场、
## 建造选项、家族），逐格悬停跑一遍会拖住 50x 模拟；它的 _population_summary_cache
## 也不按日失效，与悬停共用会读到旧人口。
##
## 但三条政策必须共用侧栏的实现：无主地文案、pending 回退、玩家科技视角。

const PAYLOAD_LIMIT := 256
const COUNTRY_LIMIT := 128
const TERRAIN_LIMIT := 64
const RESOURCE_TOP_N := 3
const RESOURCE_EPSILON := 0.000001
const EMPTY_SETTLED_TIER := "无人区"

var _map: MapData
var _generator = null
var _inspector: CellInspectorViewModel
var _world_clock: WorldClock

## cache_key = "cell_idx:day:country_slot"。聚落命名/人口/归属都按日提交，
## 所以日是最小失效单位；科技发现同样按日推进。
var _payloads: Dictionary = {}
var _payload_order: Array = []
var _country_names: Dictionary = {}
var _terrain_colors: Dictionary = {}
var _stats := {"population_calls": 0, "country_calls": 0, "builds": 0, "hits": 0}


func set_context(map: MapData, generator, inspector: CellInspectorViewModel,
		world_clock: WorldClock) -> void:
	_map = map
	_generator = generator
	_inspector = inspector
	_world_clock = world_clock
	_payloads.clear()
	_payload_order.clear()
	_country_names.clear()
	_terrain_colors.clear()
	_stats = {"population_calls": 0, "country_calls": 0, "builds": 0, "hits": 0}
	ResourceProfileRegistry.ensure_loaded()
	TerrainProfileRegistry.ensure_loaded()


func debug_stats() -> Dictionary:
	return {
		"payload_entries": _payloads.size(),
		"country_names": _country_names.size(),
		"population_calls": int(_stats["population_calls"]),
		"country_calls": int(_stats["country_calls"]),
		"builds": int(_stats["builds"]),
		"hits": int(_stats["hits"]),
	}


## 气候带（纬度 5 档）。阈值与 InfoPanelController._climate_zone_name 同口径，
## 不要改用 data_overlay_baker 的等分五档——那会让悬停与地块面板互相打脸。
static func climate_zone_name(lat_norm: float) -> String:
	var d := absf(clampf(lat_norm, 0.0, 1.0) - 0.5)
	if d < 0.10: return "热带"
	if d < 0.20: return "副热带"
	if d < 0.32: return "温带"
	if d < 0.42: return "副极地"
	return "极地"


func build(cell: HexCell) -> Dictionary:
	if cell == null or _map == null:
		return {"ok": false, "reason": "no_map"}
	var idx := int(cell.index)
	if idx < 0:
		idx = _map.index_of(cell)
	if idx < 0:
		return {"ok": false, "reason": "cell_index_invalid"}

	var day := _day()
	var slot := _country_slot(idx)
	var key := "%d:%d:%d" % [idx, day, slot]
	var cached: Dictionary = _payloads.get(key, {})
	if not cached.is_empty():
		_stats["hits"] = int(_stats["hits"]) + 1
		return cached

	var payload := _compose(cell, idx, day, slot)
	payload["cache_key"] = key
	_stats["builds"] = int(_stats["builds"]) + 1
	_store_payload(key, payload)
	return payload


# ───────────────────────────── 组装 ─────────────────────────────

func _compose(cell: HexCell, idx: int, day: int, slot: int) -> Dictionary:
	var terrain_v := _int_at(_map.terrain_arr, idx, int(cell.terrain))
	var landform_v := _int_at(_map.landform_arr, idx, int(cell.landform))
	var is_water := _bool_at(_map.is_water_arr, idx, LandformType.is_water(landform_v))
	var terrain_name := TerrainType.terrain_name_cn(terrain_v)
	var landform_name := LandformType.name_cn(landform_v)

	var lat := _float_at(_map.cell_lat_norm_arr, idx, _fallback_lat(cell))
	var zone := climate_zone_name(lat)
	var temp := _float_at(_map.temp_arr, idx, float(cell.temperature))
	var temp_band := CellInspectorViewModel.temperature_band(temp)

	var country := _country(idx, slot, is_water)
	var population := _population(idx)

	var tech_ids := PackedStringArray()
	if _inspector != null:
		tech_ids = _inspector.player_technology_ids()
	var resources := _resources(idx, is_water, tech_ids)

	var tags := _tags(landform_name, terrain_name, zone, temp_band,
		_terrain_color(terrain_v), is_water)
	var settlement_name := String(population.get("settlement_name", ""))
	var name_active := bool(population.get("settlement_name_active", false))
	var settled := bool(population.get("settled", false))
	var title_kind := "settlement" if settled and name_active and not settlement_name.is_empty() else "landform"
	var title := settlement_name if title_kind == "settlement" else landform_name

	var tier := String(population.get("tier", ""))
	if not settled and tier == EMPTY_SETTLED_TIER:
		tier = ""

	var resource_rows: Array = resources.get("rows", [])
	var resource_gated := bool(resources.get("gated", false))
	var resource_note := ""
	if resource_rows.is_empty():
		resource_note = "当前科技尚未识别此地资源" if resource_gated else "此地无明显自然资源"

	return {
		"ok": true,
		"cell_index": idx,
		"day": day,
		"is_water": is_water,
		"title": title,
		"title_kind": title_kind,
		"region": _region_text(cell),
		"country_name": String(country.get("name", "")),
		"country_owned": bool(country.get("owned", false)),
		"country_known": bool(country.get("known", true)),
		"terrain_name": terrain_name,
		"landform_name": landform_name,
		"climate_zone": zone,
		"tags": tags,
		"population": int(population.get("population", 0)),
		"population_text": String(population.get("text", "")),
		"population_pending": bool(population.get("pending", false)),
		"settled": settled,
		"settlement_name": settlement_name,
		"settlement_tier": tier,
		"tier_pending": bool(population.get("pending", false)),
		"resources": resource_rows,
		"resource_note": resource_note,
		"resource_gated": resource_gated,
	}


func _country(idx: int, slot: int, is_water: bool) -> Dictionary:
	if slot < 0:
		return {"name": "无主海域" if is_water else "无主之地", "owned": false, "known": true}
	if _inspector == null:
		return {"name": "归属未知", "owned": false, "known": false}
	_stats["country_calls"] = int(_stats["country_calls"]) + 1
	var summary: Dictionary = _inspector.country_summary(idx)
	if not bool(summary.get("ok", false)):
		return {"name": "归属未知", "owned": false, "known": false}
	var handle := int(summary.get("country_handle", -1))
	var owned := bool(summary.get("owned", false))
	var country_name := String(_country_names.get(handle, ""))
	if country_name.is_empty():
		country_name = String(summary.get("country_name", ""))
		if handle > 0 and not country_name.is_empty():
			if _country_names.size() >= COUNTRY_LIMIT:
				_country_names.clear()
			_country_names[handle] = country_name
	if country_name.is_empty():
		country_name = "归属未知" if not owned else "未知国家"
	return {"name": country_name, "owned": owned, "known": true}


func _population(idx: int) -> Dictionary:
	if _inspector == null:
		return {"settled": false, "text": "无人定居", "population": 0, "pending": false}
	_stats["population_calls"] = int(_stats["population_calls"]) + 1
	var summary: Dictionary = _inspector.population_summary(idx)
	var pending := bool(summary.get("pending", false))
	var population := int(summary.get("population", 0))
	var settled := population > 0
	var text := ""
	if pending and population <= 0:
		text = "统计中…"
	elif population <= 0:
		text = "无人定居"
	else:
		text = UITokens.format_compact_number_cn(float(population), 1)
	return {
		"settled": settled,
		"population": population,
		"text": text,
		"pending": pending,
		"settlement_name": String(summary.get("settlement_name", "")),
		"settlement_name_active": bool(summary.get("settlement_name_active", false)),
		"tier": String(summary.get("prosperity_name", "")),
	}


func _resources(idx: int, is_water: bool, tech_ids: PackedStringArray) -> Dictionary:
	var habitat_mask := 1 if not is_water else 0
	if idx < _map.resource_habitat_mask_arr.size():
		habitat_mask = int(_map.resource_habitat_mask_arr[idx])
	var rows: Array = []
	var hidden_by_tech := 0
	for profile in ResourceProfileRegistry.ordered():
		if not ResourceProfileRegistry.habitat_available(profile, habitat_mask):
			continue
		if not ResourceProfileRegistry.discovery_visible(profile, tech_ids):
			hidden_by_tech += 1
			continue
		var field := ResourceProfileRegistry.reserve_map_field(profile)
		if field.is_empty():
			continue
		var reserve_array = _map.get(field)
		if not (reserve_array is PackedFloat32Array):
			continue
		var reserve := 0.0
		if idx < reserve_array.size():
			reserve = float(reserve_array[idx])
		if reserve <= RESOURCE_EPSILON:
			continue
		var reference := maxf(ResourceProfileRegistry.reference_reserve(profile), RESOURCE_EPSILON)
		var ratio := reserve / reference
		rows.append({
			"id": String(profile.id),
			"name": String(profile.display_name) if String(profile.display_name) != "" else String(profile.id),
			"icon": ResourceProfileRegistry.icon_key(profile),
			"reserve": reserve,
			"density_ratio": ratio,
			"density_level": CellInspectorViewModel.resource_density_level(ratio),
			"density_name": CellInspectorViewModel.resource_density_band(ratio),
		})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var da := float(a.get("density_ratio", 0.0))
		var db := float(b.get("density_ratio", 0.0))
		if not is_equal_approx(da, db):
			return da > db
		return float(a.get("reserve", 0.0)) > float(b.get("reserve", 0.0))
	)
	if rows.size() > RESOURCE_TOP_N:
		rows = rows.slice(0, RESOURCE_TOP_N)
	return {"rows": rows, "gated": hidden_by_tech > 0}


## 三枚纸签：地貌 → 地形 → 气候带。
## 地形名常自带气候前缀（「温带草原」），此时气候签补温度档，避免两枚签读起来重复。
func _tags(landform_name: String, terrain_name: String, zone: String,
		temp_band: String, terrain_color: Color, is_water: bool) -> Array:
	var tags: Array = []
	if not landform_name.is_empty():
		tags.append({"kind": "landform", "name": landform_name, "color": UITokens.DOSSIER_UMBER})
	if not terrain_name.is_empty() and terrain_name != landform_name and not is_water:
		# 水面地形名多是「海洋·海滨」这类地貌细化，和地貌纸签说的是同一件事；
		# 水面只要地貌 + 气候带两枚，信息密度更高。
		tags.append({"kind": "terrain", "name": terrain_name, "color": terrain_color})
	var climate_text := zone
	# 地形名里已经带了气候区名（如"温带森林"里的"温带"），纸签只补更细的温度档，
	# 免得同一句话在两张纸签上重复；也省下卡片本来就紧张的横向空间。
	if not zone.is_empty() and terrain_name.find(zone) >= 0 and not temp_band.is_empty():
		climate_text = temp_band
	if not climate_text.is_empty():
		tags.append({"kind": "climate", "name": climate_text, "color": UITokens.CLIMATE})
	if is_water and tags.size() > 2:
		tags = tags.slice(0, 2)
	return tags


func _terrain_color(terrain_v: int) -> Color:
	var cached: Color = _terrain_colors.get(terrain_v, Color(0, 0, 0, 0))
	if cached.a > 0.0:
		return cached
	var profile := TerrainProfileRegistry.get_profile(terrain_v)
	var color := UITokens.ECO
	if profile != null:
		color = profile.base_color
	if _terrain_colors.size() >= TERRAIN_LIMIT:
		_terrain_colors.clear()
	_terrain_colors[terrain_v] = color
	return color


# ───────────────────────────── 读取工具 ─────────────────────────────

func _day() -> int:
	if _inspector != null:
		return _inspector.sample_day()
	if _world_clock != null:
		return _world_clock.day_index()
	return 0


func _country_slot(idx: int) -> int:
	if idx < 0 or idx >= _map.country_slot_arr.size():
		return -1
	return int(_map.country_slot_arr[idx])


func _fallback_lat(cell: HexCell) -> float:
	if _map == null or _map.height <= 1:
		return 0.5
	return float(cell.r) / float(_map.height - 1)


func _region_text(cell: HexCell) -> String:
	var off := HexUtils.cube_to_offset(cell.q, cell.r)
	return "区域 %d, %d" % [off.x + 1, off.y + 1]


func _int_at(array, idx: int, fallback: int) -> int:
	if array == null or idx < 0 or idx >= array.size():
		return fallback
	return int(array[idx])


func _float_at(array, idx: int, fallback: float) -> float:
	if array == null or idx < 0 or idx >= array.size():
		return fallback
	return float(array[idx])


func _bool_at(array, idx: int, fallback: bool) -> bool:
	if array == null or idx < 0 or idx >= array.size():
		return fallback
	return int(array[idx]) != 0


func _store_payload(key: String, payload: Dictionary) -> void:
	if _payloads.size() >= PAYLOAD_LIMIT:
		var drop := _payload_order.slice(0, PAYLOAD_LIMIT / 4)
		_payload_order = _payload_order.slice(drop.size(), _payload_order.size())
		for stale in drop:
			_payloads.erase(stale)
	_payloads[key] = payload
	_payload_order.append(key)
