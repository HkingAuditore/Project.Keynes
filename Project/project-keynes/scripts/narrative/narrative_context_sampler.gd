class_name NarrativeContextSampler
extends RefCounted

const TerrainTypeScript = preload("res://scripts/geography/terrain_type.gd")
const LandformTypeScript = preload("res://scripts/geography/landform_type.gd")
const HexUtilsScript = preload("res://scripts/geography/hex_utils.gd")

const ERA_NAMES := [
	"石器时代", "农耕时代", "青铜与城邦时代", "古典王国时代", "帝国与封建时代",
	"文艺复兴与航海时代", "工场手工业时代", "蒸汽工业时代", "电气与钢铁时代", "原子与信息时代", "智能与生态时代",
]


static func sample_country_context(
		map,
		generator,
		player_country_handle: int,
		day: int,
		story_flags: Dictionary = {}
) -> Dictionary:
	var ctx := {
		"day": day,
		"country_handle": player_country_handle,
		"country_name": "我国",
		"era_index": 0,
		"era_name": ERA_NAMES[0],
		"technology_ids": PackedStringArray(),
		"technologies": PackedStringArray(),
		"territory_cells": PackedInt32Array(),
		"treasury_cash": 0,
		"treasury_goods_by_id": {},
		"story_flags": {},
	}
	for k in story_flags:
		var key_str := String(k)
		if key_str.begins_with("country:"):
			var bare := key_str.trim_prefix("country:")
			ctx.story_flags[bare] = story_flags[k]
			ctx.story_flags[key_str] = story_flags[k]
		elif not key_str.begins_with("cell:"):
			ctx.story_flags[key_str] = story_flags[k]

	if generator == null or player_country_handle <= 0:
		return ctx
	var country_facade = generator.get_country_facade() \
		if generator.has_method("get_country_facade") else null
	if country_facade == null:
		return ctx

	if country_facade.has_method("snapshot"):
		var snap: Dictionary = country_facade.snapshot(player_country_handle)
		if bool(snap.get("ok", false)):
			var cname := String(snap.get("display_name", snap.get("country_name", ""))).strip_edges()
			if not cname.is_empty():
				ctx.country_name = cname
			var techs: PackedStringArray = snap.get("technology_ids", PackedStringArray())
			ctx.technology_ids = techs
			ctx.technologies = techs
			ctx.territory_cells = snap.get("territory_cells", PackedInt32Array())

	if country_facade.has_method("current_era_index"):
		var era_idx := maxi(0, int(country_facade.current_era_index(player_country_handle)))
		ctx.era_index = era_idx
		if era_idx >= 0 and era_idx < ERA_NAMES.size():
			ctx.era_name = ERA_NAMES[era_idx]

	if country_facade.has_method("treasury_snapshot"):
		var treas: Dictionary = country_facade.treasury_snapshot(player_country_handle)
		if bool(treas.get("ok", false)):
			ctx.treasury_cash = int(treas.get("cash", 0))
			var good_ids: PackedStringArray = treas.get("good_ids", PackedStringArray())
			var quantities: PackedInt64Array = treas.get("quantities", PackedInt64Array())
			var goods_map := {}
			var n := mini(good_ids.size(), quantities.size())
			for i in range(n):
				goods_map[String(good_ids[i])] = int(quantities[i])
			ctx.treasury_goods_by_id = goods_map

	return ctx


static func sample_cell_context(
		cell_idx: int,
		country_ctx: Dictionary,
		map,
		generator,
		view_adapter = null,
		story_flags: Dictionary = {}
) -> Dictionary:
	var ctx := country_ctx.duplicate(true)
	ctx["cell_idx"] = cell_idx
	ctx["settlement_name"] = "边陲聚落"
	ctx["terrain"] = 2
	ctx["terrain_name"] = "平原"
	ctx["terrain_key"] = "plain"
	ctx["landform"] = 4
	ctx["landform_name"] = "平原"
	ctx["landform_key"] = "plain"
	ctx["vegetation"] = 0
	ctx["cover"] = 0
	ctx["elevation"] = 0.5
	ctx["has_river"] = false
	ctx["is_coastal"] = false
	ctx["temperature"] = 18.0
	ctx["temperature_c"] = 18.0
	ctx["moisture"] = 0.5
	ctx["snow_cover"] = 0.0
	ctx["weather_precip"] = 0.0
	ctx["precipitation"] = 0.0
	ctx["weather_vapor"] = 0.0
	ctx["weather_cloud"] = 0.0
	ctx["ocean_current_speed"] = 0.0
	ctx["ocean_upwelling"] = 0.0
	ctx["population"] = 0
	ctx["satisfaction"] = 0.65
	ctx["satisfaction_norm"] = 0.65
	ctx["satisfaction_q16"] = 42598
	ctx["primary_cohort_handle"] = 0
	ctx["primary_cohort_cash"] = 0
	ctx["building_counts_by_id"] = {}
	ctx["building_counts"] = {}
	ctx["total_buildings"] = 0
	ctx["building_count"] = 0
	ctx["market_stocks_by_id"] = {}
	ctx["market_stocks"] = {}
	ctx["market_price_ratios_by_id"] = {}
	ctx["market_price_ratios"] = {}
	ctx["shortage_good_ids"] = PackedStringArray()
	ctx["shortage_goods"] = PackedStringArray()
	ctx["natural_resources_by_id"] = {}
	ctx["natural_resources"] = {}
	ctx["highlight_good_name"] = "粮食"

	var merged_flags: Dictionary = ctx.get("story_flags", {}).duplicate()
	var cell_prefix := "cell:%d:" % cell_idx
	for k in story_flags:
		var key_str := String(k)
		if key_str.begins_with(cell_prefix):
			var bare := key_str.trim_prefix(cell_prefix)
			merged_flags[bare] = story_flags[k]
			merged_flags[key_str] = story_flags[k]
	ctx["story_flags"] = merged_flags

	if map != null and cell_idx >= 0 and cell_idx < map.cell_count():
		var cell = map.cell_at(cell_idx)
		if cell != null:
			ctx["q"] = int(cell.q)
			ctx["r"] = int(cell.r)
			var terrain_v: int = int(view_adapter.get_terrain(cell_idx)) \
				if view_adapter != null and view_adapter.has_method("get_terrain") \
				else int(cell.terrain)
			var landform_v: int = int(view_adapter.get_landform(cell_idx)) \
				if view_adapter != null and view_adapter.has_method("get_landform") \
				else int(cell.landform)
			var veg_v: int = int(view_adapter.get_vegetation(cell_idx)) \
				if view_adapter != null and view_adapter.has_method("get_vegetation") \
				else int(cell.vegetation)
			var cover_v: int = int(view_adapter.get_cover(cell_idx)) \
				if view_adapter != null and view_adapter.has_method("get_cover") \
				else int(cell.cover)
			var temp_v: float = float(view_adapter.get_temperature(cell_idx)) \
				if view_adapter != null and view_adapter.has_method("get_temperature") \
				else float(cell.temperature)
			var moist_v: float = float(view_adapter.get_moisture(cell_idx)) \
				if view_adapter != null and view_adapter.has_method("get_moisture") \
				else float(cell.moisture)
			var elev_v: float = float(view_adapter.get_elevation(cell_idx)) \
				if view_adapter != null and view_adapter.has_method("get_elevation") \
				else float(cell.height)
			var snow_v: float = float(view_adapter.get_snow_cover(cell_idx)) \
				if view_adapter != null and view_adapter.has_method("get_snow_cover") \
				else float(cell.snow_cover)
			var precip_v: float = float(view_adapter.get_weather_precip(cell_idx)) \
				if view_adapter != null and view_adapter.has_method("get_weather_precip") \
				else float(cell.weather_precip)
			var has_river_v: bool = bool(view_adapter.get_has_river(cell_idx)) \
				if view_adapter != null and view_adapter.has_method("get_has_river") \
				else bool(cell.has_river)

			ctx["terrain"] = terrain_v
			ctx["terrain_name"] = TerrainTypeScript.terrain_name_cn(terrain_v)
			ctx["landform"] = landform_v
			ctx["landform_name"] = LandformTypeScript.name_cn(landform_v)
			ctx["vegetation"] = veg_v
			ctx["cover"] = cover_v
			ctx["temperature"] = temp_v
			ctx["temperature_c"] = temp_v
			ctx["moisture"] = moist_v
			ctx["elevation"] = elev_v
			ctx["snow_cover"] = snow_v
			ctx["weather_precip"] = precip_v
			ctx["precipitation"] = precip_v
			ctx["has_river"] = has_river_v

			# Check coastal & ocean currents / upwelling from self and adjacent water cells
			var is_coastal := landform_v == LandformTypeScript.LF.COAST \
				or landform_v == LandformTypeScript.LF.DELTA
			var max_current := _cell_ocean_current_speed(map, cell, cell_idx)
			var max_upwelling := _cell_ocean_upwelling(map, cell, cell_idx)
			if map.has_method("get_neighbors"):
				for n_cell in map.get_neighbors(cell):
					if n_cell == null:
						continue
					var n_lf := int(n_cell.landform)
					if LandformTypeScript.is_water(n_lf):
						is_coastal = true
						max_current = maxf(max_current, _cell_ocean_current_speed(map, n_cell, int(n_cell.index)))
						max_upwelling = maxf(max_upwelling, _cell_ocean_upwelling(map, n_cell, int(n_cell.index)))
			ctx["is_coastal"] = is_coastal
			ctx["ocean_current_speed"] = max_current
			ctx["ocean_upwelling"] = max_upwelling
			ctx["natural_resources_by_id"] = _sample_cell_resources(map, cell, cell_idx)
			ctx["natural_resources"] = ctx["natural_resources_by_id"]

	if generator == null:
		return ctx
	var economy_facade = generator.get_economy_facade() \
		if generator.has_method("get_economy_facade") else null
	if economy_facade == null:
		return ctx

	if economy_facade.has_method("settlement_display_name"):
		var sname := String(economy_facade.settlement_display_name(cell_idx)).strip_edges()
		if not sname.is_empty():
			ctx["settlement_name"] = sname

	if economy_facade.has_method("population_cell_summary"):
		var pop_sum: Dictionary = economy_facade.population_cell_summary(cell_idx)
		if bool(pop_sum.get("ok", false)) or pop_sum.has("population"):
			ctx["population"] = int(pop_sum.get("population", 0))
			if pop_sum.has("composite_satisfaction_q16"):
				var sat_q16 := int(pop_sum.get("composite_satisfaction_q16", 42598))
				ctx["satisfaction_q16"] = sat_q16
				ctx["satisfaction"] = clampf(float(sat_q16) / 65536.0, 0.0, 1.0)
				ctx["satisfaction_norm"] = ctx["satisfaction"]

	if economy_facade.has_method("population_cell_snapshot"):
		var pop_snap: Dictionary = economy_facade.population_cell_snapshot(cell_idx, false)
		# [snapshot-type-guard 2026-11-02] include_details=false 时 native 只回标量汇总，
		# `funds` 可能是 int 而不是 PackedInt64Array（真机每天一条
		# "Trying to assign value of type 'int' to PackedInt64Array"）。
		# 这里按类型取，缺数组就走"没有明细"的分支，不再打断叙事采样。
		var handles_raw: Variant = pop_snap.get("handles", null)
		var pops_raw: Variant = pop_snap.get("populations", null)
		var funds_raw: Variant = pop_snap.get("funds", null)
		var handles: PackedInt64Array = handles_raw if handles_raw is PackedInt64Array \
			else PackedInt64Array()
		var pops: PackedInt64Array = pops_raw if pops_raw is PackedInt64Array \
			else PackedInt64Array()
		var funds: PackedInt64Array = funds_raw if funds_raw is PackedInt64Array \
			else PackedInt64Array()
		var best_handle := 0
		var best_pop := -1
		var best_cash := 0
		var count := mini(handles.size(), pops.size())
		for i in range(count):
			var p := int(pops[i])
			if p > best_pop and int(handles[i]) != 0:
				best_pop = p
				best_handle = int(handles[i])
				best_cash = int(funds[i]) if i < funds.size() else 0
		ctx["primary_cohort_handle"] = best_handle
		ctx["primary_cohort_cash"] = best_cash
		if int(ctx["population"]) <= 0 and best_pop > 0:
			var sum_pop := 0
			for p in pops:
				sum_pop += maxi(0, int(p))
			ctx["population"] = sum_pop

	if economy_facade.has_method("building_cell_snapshot"):
		var b_snap: Dictionary = economy_facade.building_cell_snapshot(cell_idx)
		var b_ids: PackedStringArray = b_snap.get("building_stable_ids",
			b_snap.get("building_type_ids", PackedStringArray()))
		var b_counts: PackedInt64Array = b_snap.get("counts",
			b_snap.get("building_counts", PackedInt64Array()))
		var counts_map := {}
		var total_b := 0
		var n_b := mini(b_ids.size(), b_counts.size())
		for i in range(n_b):
			var c := maxi(0, int(b_counts[i]))
			if c > 0:
				var bid := String(b_ids[i])
				counts_map[bid] = int(counts_map.get(bid, 0)) + c
				total_b += c
		ctx["building_counts_by_id"] = counts_map
		ctx["building_counts"] = counts_map
		ctx["total_buildings"] = total_b
		ctx["building_count"] = total_b

	if economy_facade.has_method("market_cell_snapshot"):
		var m_snap: Dictionary = economy_facade.market_cell_snapshot(cell_idx)
		var g_ids: PackedStringArray = m_snap.get("good_stable_ids",
			m_snap.get("good_ids", PackedStringArray()))
		var stocks: PackedInt64Array = m_snap.get("stocks",
			m_snap.get("quantities", PackedInt64Array()))
		var prices: PackedInt64Array = m_snap.get("prices", PackedInt64Array())
		var base_prices: PackedInt64Array = m_snap.get("base_prices", PackedInt64Array())
		var shortages := PackedStringArray()
		var stocks_map := {}
		var ratios_map := {}
		var highest_ratio := 1.0
		var highest_good_id := ""
		for i in range(g_ids.size()):
			var gid := String(g_ids[i])
			var st := int(stocks[i]) if i < stocks.size() else 0
			stocks_map[gid] = st
			var ratio := 1.0
			if i < prices.size() and i < base_prices.size() and int(base_prices[i]) > 0:
				ratio = float(prices[i]) / float(base_prices[i])
			ratios_map[gid] = ratio
			if ratio >= 1.30:
				shortages.append(gid)
			if ratio > highest_ratio:
				highest_ratio = ratio
				highest_good_id = gid
		ctx["market_stocks_by_id"] = stocks_map
		ctx["market_stocks"] = stocks_map
		ctx["market_price_ratios_by_id"] = ratios_map
		ctx["market_price_ratios"] = ratios_map
		ctx["shortage_good_ids"] = shortages
		ctx["shortage_goods"] = shortages
		if not highest_good_id.is_empty() and economy_facade.has_method("good_display_name"):
			var catalog_goods: PackedStringArray = economy_facade._catalog.get("good_ids", PackedStringArray()) \
				if "_catalog" in economy_facade else PackedStringArray()
			var g_idx := catalog_goods.find(highest_good_id)
			if g_idx >= 0:
				ctx["highlight_good_name"] = economy_facade.good_display_name(g_idx)

	return ctx


static func _cell_ocean_current_speed(map, cell, cell_idx: int) -> float:
	if map != null and "ocean_current_speed_arr" in map and cell_idx < map.ocean_current_speed_arr.size():
		return float(map.ocean_current_speed_arr[cell_idx])
	if cell != null and "ocean_current_speed" in cell:
		return float(cell.ocean_current_speed)
	if cell != null and "ocean_current" in cell and cell.ocean_current is Vector2:
		return (cell.ocean_current as Vector2).length()
	return 0.0


static func _cell_ocean_upwelling(map, cell, cell_idx: int) -> float:
	if map != null and "upwelling_arr" in map and cell_idx < map.upwelling_arr.size():
		return float(map.upwelling_arr[cell_idx])
	if cell != null and "upwelling" in cell:
		return float(cell.upwelling)
	return 0.0


static func _sample_cell_resources(map, cell, cell_idx: int) -> Dictionary:
	var out := {}
	if cell != null and "natural_resources" in cell and cell.natural_resources is Dictionary:
		for k in cell.natural_resources:
			out[String(k)] = int(cell.natural_resources[k])
	elif map != null and map.has_method("cell_resource_reserves"):
		var res = map.cell_resource_reserves(cell_idx)
		if res is Dictionary:
			for k in res:
				out[String(k)] = int(res[k])
	return out
