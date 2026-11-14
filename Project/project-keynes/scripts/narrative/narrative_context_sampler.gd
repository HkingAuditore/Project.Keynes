class_name NarrativeContextSampler
extends RefCounted

const TerrainTypeScript = preload("res://scripts/geography/terrain_type.gd")
const LandformTypeScript = preload("res://scripts/geography/landform_type.gd")
const VegetationTypeScript = preload("res://scripts/geography/vegetation_type.gd")
const HexUtilsScript = preload("res://scripts/geography/hex_utils.gd")

const ERA_NAMES := [
	"石器时代", "农耕时代", "青铜与城邦时代", "古典王国时代", "帝国与封建时代",
	"文艺复兴与航海时代", "工场手工业时代", "蒸汽工业时代", "电气与钢铁时代", "原子与信息时代", "智能与生态时代",
]

## 生计覆盖率（收入/支出 Q16）低于此值视为「严重入不敷出」：收入盖不住一半开销。
## 门槛取 0.5 而不是 0.9：实测样本里 0.9 以下常年占人口两成以上（含失业与刚生成的 cohort），
## 拿它当饥荒信号会天天触发；0.5 以下在正常格子约占 6%，才是真饥荒。
const SUBSISTENCE_COVERAGE_Q16 := 32768


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
		# 军事/战争事实：默认不可用；有军事门面时填一次国家快照。
		"military_available": false,
		"at_war": false,
		"war_count": 0,
		"wars": [],
		"soldiers_total": 0,
		"soldiers_in_armies": 0,
		"war_score_min_q16": 0,
		"war_losses_total": 0,
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
	# 军事门面：一次国家快照，不依赖国家门面是否存在。
	var military_facade = generator.get_military_facade() \
		if generator.has_method("get_military_facade") else null
	if military_facade != null and military_facade.has_method("is_configured") \
			and military_facade.is_configured() \
			and military_facade.has_method("country_snapshot"):
		var msnap: Dictionary = military_facade.country_snapshot(player_country_handle)
		if bool(msnap.get("ok", false)):
			var wars: Array = msnap.get("wars", [])
			var min_score := 0
			var losses := 0
			for raw_war in wars:
				if not raw_war is Dictionary:
					continue
				min_score = mini(min_score, int((raw_war as Dictionary).get("score_q16", 0)))
				losses += int((raw_war as Dictionary).get("attacker_losses", 0)) \
					+ int((raw_war as Dictionary).get("defender_losses", 0))
			ctx["military_available"] = true
			ctx["wars"] = wars
			ctx["war_count"] = int(msnap.get("wars_active", wars.size()))
			ctx["at_war"] = int(ctx["war_count"]) > 0
			ctx["soldiers_total"] = int(msnap.get("soldiers_total", 0))
			ctx["soldiers_in_armies"] = int(msnap.get("soldiers_in_armies", 0))
			ctx["war_score_min_q16"] = min_score
			ctx["war_losses_total"] = losses
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
		story_flags: Dictionary = {},
		include_cohort_details: bool = false
) -> Dictionary:
	var ctx := country_ctx.duplicate(true)
	ctx["cell_idx"] = cell_idx
	ctx["settlement_name"] = "边陲聚落"
	ctx["terrain"] = 2
	ctx["terrain_name"] = "平原"
	ctx["landform"] = 4
	ctx["landform_name"] = "平原"
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
	ctx["primary_cohort_profession_id"] = ""
	ctx["primary_cohort_profession_name"] = ""
	# 人群事实默认值：没有经济门面时事件仍可评估，只是人群条件一律不成立。
	ctx["human_context_available"] = false
	ctx["neediest_cohort_handle"] = 0
	ctx["neediest_cohort_satisfaction"] = 1.0
	ctx["subsistence_shortfall_population"] = 0
	ctx["subsistence_shortfall_ratio"] = 0.0
	ctx["unemployed_population"] = 0
	ctx["unemployment_ratio"] = 0.0
	ctx["profession_population_by_id"] = {}
	ctx["profession_share_by_id"] = {}
	ctx["dominant_profession_id"] = ""
	ctx["dominant_profession_name"] = ""
	ctx["dominant_profession_population"] = 0
	ctx["dominant_profession_share"] = 0.0
	# 家族事实：默认不可用；只有取明细的扫描（脉冲/事实/探针/结算）才读一次快照。
	ctx["family_available"] = false
	ctx["family_count"] = 0
	ctx["primary_family_handle"] = 0
	ctx["primary_family_name"] = ""
	ctx["primary_family_prestige"] = 0
	ctx["primary_family_prestige_score_q16"] = 0
	ctx["primary_family_population"] = 0
	ctx["primary_family_population_share"] = 0.0
	ctx["primary_family_owned_buildings"] = 0
	ctx["primary_family_notable_people"] = 0
	ctx["primary_family_trait_keys"] = PackedStringArray()
	ctx["primary_family_trait_names"] = PackedStringArray()
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
	# 范围效果的目标池：己方领土内、1 环 / 2 环、陆地、去重、按索引升序。
	# 没有 map 或没有领土时保持空数组——叙事效果不会越权影响外国格。
	ctx["nearby_owned_cells_r1"] = PackedInt32Array()
	ctx["nearby_owned_cells_r2"] = PackedInt32Array()

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
			ctx["vegetation_name"] = VegetationTypeScript.name_cn(veg_v)
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
			var nearby := _sample_nearby_owned_cells(
				map, cell, cell_idx, country_ctx.get("territory_cells", PackedInt32Array()))
			ctx["nearby_owned_cells_r1"] = nearby[0]
			ctx["nearby_owned_cells_r2"] = nearby[1]

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
		# 人口明细是「事件写人」的前提：贫困、缺口、失业、职业构成都只能从 cohort 表里读。
		# native 的明细快照只遍历该格队列（通常个位数），20 天一次抽样 8 格，成本可忽略；
		# 因此这里始终取明细，不再按 include_cohort_details 省这一趟。
		var pop_snap: Dictionary = economy_facade.population_cell_snapshot(
			cell_idx, include_cohort_details)
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
		var coverage_raw: Variant = pop_snap.get("livelihood_coverage_by_cohort_q16", null)
		var coverage: PackedInt64Array = coverage_raw if coverage_raw is PackedInt64Array \
			else PackedInt64Array()
		var sat_raw: Variant = pop_snap.get("satisfaction_by_cohort_q16", null)
		var cohort_sat: PackedInt32Array = sat_raw if sat_raw is PackedInt32Array \
			else PackedInt32Array()
		var unemployed_raw: Variant = pop_snap.get("unemployed_by_cohort", null)
		var unemployed: PackedInt64Array = unemployed_raw if unemployed_raw is PackedInt64Array \
			else PackedInt64Array()
		var profession_raw: Variant = pop_snap.get("profession_ids", null)
		var cohort_profession: PackedInt32Array = profession_raw if profession_raw is PackedInt32Array \
			else PackedInt32Array()

		var best_handle := 0
		var best_pop := -1
		var best_cash := 0
		var best_profession_pid := -1
		var neediest_handle := 0
		var neediest_sat_q16 := 0x7FFFFFFF
		var shortfall_pop := 0
		var unemployed_pop := 0
		var profession_pop: Dictionary = {}
		var total_pop := 0
		var catalog_professions: PackedStringArray = economy_facade._catalog.get(
			"profession_ids", PackedStringArray()) if "_catalog" in economy_facade \
			else PackedStringArray()
		var count := mini(handles.size(), pops.size())
		for i in range(count):
			var p := maxi(0, int(pops[i]))
			var handle := int(handles[i])
			if p <= 0 or handle == 0:
				continue
			total_pop += p
			var cash := int(funds[i]) if i < funds.size() else 0
			var sat_q16 := int(cohort_sat[i]) if i < cohort_sat.size() else 0
			if p > best_pop:
				best_pop = p
				best_handle = handle
				best_cash = cash
				best_profession_pid = int(cohort_profession[i]) \
					if i < cohort_profession.size() else -1
			if i < coverage.size() and int(coverage[i]) < SUBSISTENCE_COVERAGE_Q16:
				# 全员失业的 cohort 收入为 0、覆盖率天然是 0；它属于「没活干」，
				# 由 unemployment_ratio 单独统计，不再重复计入「干着活却养不活家」的短缺人口。
				var cohort_unemployed := int(unemployed[i]) if i < unemployed.size() else 0
				if cohort_unemployed < p:
					shortfall_pop += p
			if i < cohort_sat.size() and sat_q16 < neediest_sat_q16:
				neediest_sat_q16 = sat_q16
				neediest_handle = handle
			if i < unemployed.size():
				unemployed_pop += maxi(0, int(unemployed[i]))
			if i < cohort_profession.size():
				var pid := int(cohort_profession[i])
				var stable_id := String(catalog_professions[pid]) \
					if pid >= 0 and pid < catalog_professions.size() else ""
				if not stable_id.is_empty():
					profession_pop[stable_id] = int(profession_pop.get(stable_id, 0)) + p

		ctx["primary_cohort_handle"] = best_handle
		ctx["primary_cohort_cash"] = best_cash
		# 效果标签要写清「钱给了谁」：把收款的 cohort 的职业名一起带出去。
		var primary_profession_id := String(catalog_professions[best_profession_pid]) \
			if best_profession_pid >= 0 and best_profession_pid < catalog_professions.size() else ""
		ctx["primary_cohort_profession_id"] = primary_profession_id
		if primary_profession_id.is_empty():
			ctx["primary_cohort_profession_name"] = ""
		elif economy_facade.has_method("profession_display_name"):
			ctx["primary_cohort_profession_name"] = economy_facade.profession_display_name(
				primary_profession_id)
		else:
			ctx["primary_cohort_profession_name"] = primary_profession_id
		if int(ctx["population"]) <= 0 and total_pop > 0:
			ctx["population"] = total_pop

		# ─── 人群事实：让事件能写「谁」，而不是只写「本地」 ──────────────────
		# 只有取明细时才成立：触发扫描若要吃人群条件，调用方必须传 include_cohort_details=true。
		if include_cohort_details:
			var dominant_id := ""
			var dominant_pop := 0
			for stable_id in profession_pop:
				if int(profession_pop[stable_id]) > dominant_pop:
					dominant_pop = int(profession_pop[stable_id])
					dominant_id = String(stable_id)

			ctx["human_context_available"] = total_pop > 0
			ctx["neediest_cohort_handle"] = neediest_handle
			ctx["neediest_cohort_satisfaction"] = (
				float(neediest_sat_q16) / 65536.0) if neediest_sat_q16 != 0x7FFFFFFF else 1.0
			ctx["subsistence_shortfall_population"] = shortfall_pop
			ctx["subsistence_shortfall_ratio"] = float(shortfall_pop) / float(maxi(1, total_pop))
			ctx["unemployed_population"] = unemployed_pop
			ctx["unemployment_ratio"] = float(unemployed_pop) / float(maxi(1, total_pop))
			ctx["profession_population_by_id"] = profession_pop
			ctx["profession_share_by_id"] = {}
			for stable_id in profession_pop:
				ctx["profession_share_by_id"][String(stable_id)] = float(
					profession_pop[stable_id]) / float(maxi(1, total_pop))
			ctx["dominant_profession_id"] = dominant_id
			ctx["dominant_profession_population"] = dominant_pop
			ctx["dominant_profession_share"] = float(dominant_pop) / float(maxi(1, total_pop))
			if dominant_id.is_empty():
				ctx["dominant_profession_name"] = ""
			elif economy_facade.has_method("profession_display_name"):
				ctx["dominant_profession_name"] = economy_facade.profession_display_name(dominant_id)
			else:
				ctx["dominant_profession_name"] = dominant_id

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

	# 家族上下文与 cohort 明细同一条契约：只在扫描/结算路径取，入队汇总不取。
	if include_cohort_details and economy_facade.has_method("family_cell_snapshot"):
		_sample_primary_family(economy_facade, cell_idx, ctx)
	return ctx


## 本格最大族 = 快照第一条（原生已按 population desc, stable_id asc 排序）。
## 威望是「每族 × 每格」的影响力，不是全国声望；无族时保持默认值。
static func _sample_primary_family(economy_facade, cell_idx: int, ctx: Dictionary) -> void:
	var snapshot: Dictionary = economy_facade.family_cell_snapshot(cell_idx, 0, 8)
	if not bool(snapshot.get("ok", false)):
		return
	var handles: PackedInt64Array = snapshot.get("family_handles", PackedInt64Array())
	if handles.is_empty():
		return
	var names: PackedStringArray = snapshot.get("family_names", PackedStringArray())
	var surnames: PackedStringArray = snapshot.get("surnames", PackedStringArray())
	var disambiguators: PackedInt32Array = snapshot.get(
		"surname_disambiguators", PackedInt32Array())
	var populations: PackedInt64Array = snapshot.get("populations", PackedInt64Array())
	var prestige_levels: PackedInt32Array = snapshot.get(
		"prestige_levels", PackedInt32Array())
	var prestige_scores: PackedInt32Array = snapshot.get(
		"prestige_scores", PackedInt32Array())
	var owned: PackedInt64Array = snapshot.get("owned_buildings", PackedInt64Array())
	var notables: PackedInt32Array = snapshot.get(
		"notable_person_counts", PackedInt32Array())

	var family_name := String(names[0]) if names.size() > 0 else ""
	if family_name.strip_edges().is_empty() and surnames.size() > 0:
		family_name = String(surnames[0])
		if disambiguators.size() > 0 and int(disambiguators[0]) > 0:
			family_name += "（%d）" % (int(disambiguators[0]) + 1)
	var population := int(populations[0]) if populations.size() > 0 else 0
	var cell_population := maxi(1, int(ctx.get("population", 0)))

	ctx["family_available"] = true
	ctx["family_count"] = handles.size()
	ctx["primary_family_handle"] = int(handles[0])
	ctx["primary_family_name"] = family_name
	ctx["primary_family_prestige"] = int(prestige_levels[0]) \
		if prestige_levels.size() > 0 else 0
	ctx["primary_family_prestige_score_q16"] = int(prestige_scores[0]) \
		if prestige_scores.size() > 0 else 0
	ctx["primary_family_population"] = population
	ctx["primary_family_population_share"] = clampf(
		float(population) / float(cell_population), 0.0, 1.0)
	ctx["primary_family_owned_buildings"] = int(owned[0]) if owned.size() > 0 else 0
	ctx["primary_family_notable_people"] = int(notables[0]) if notables.size() > 0 else 0
	# 这个族本来是什么：B 层事件按既有特质分支（一次 committed read）。
	if economy_facade.has_method("get_family_traits"):
		var traits: Dictionary = economy_facade.get_family_traits(int(handles[0]))
		if bool(traits.get("ok", false)):
			ctx["primary_family_trait_keys"] = traits.get(
				"trait_keys", PackedStringArray())
			ctx["primary_family_trait_names"] = traits.get(
				"display_names", PackedStringArray())


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


## 范围效果的目标池：从当前格 BFS 1 环 / 2 环，只保留「己方领土 + 陆地」的格子。
##
## 返回 `[r1, r2]`，两环互不重叠——适配器按「当前格 + r1(radius>=1) + r2(radius==2)」拼目标列表，
## 重叠会让同一格被施加两次。
##   * 领土：只有 `territory_cells` 里的格子；空领土直接返回空数组（不越权影响外国格）。
##   * 陆地：`LandformType.is_water` 或地块自带 `is_water` 标记的水面一律排除。
##   * 扩展：BFS 会穿过非己方 / 水面格子继续找 2 环，否则被外国或河流隔开的己方地块会漏。
##   * 确定性：每个环去重后按索引升序，不依赖字典遍历顺序。
static func _sample_nearby_owned_cells(map, origin_cell, cell_idx: int, territory_cells) -> Array:
	var ring1: Dictionary = {}
	var ring2: Dictionary = {}
	if map == null or origin_cell == null or not map.has_method("get_neighbors"):
		return [PackedInt32Array(), PackedInt32Array()]
	var owned := _territory_set(territory_cells)
	if owned.is_empty():
		return [PackedInt32Array(), PackedInt32Array()]

	var visited: Dictionary = {cell_idx: true}
	var frontier: Array = [origin_cell]
	for ring in range(1, 3):
		var next_frontier: Array = []
		for current in frontier:
			for n_cell in map.get_neighbors(current):
				if n_cell == null:
					continue
				var n_idx := int(n_cell.index)
				if n_idx < 0 or n_idx == cell_idx or visited.has(n_idx):
					continue
				visited[n_idx] = true
				next_frontier.append(n_cell)
				if not owned.has(n_idx) or _is_water_cell(n_cell):
					continue
				if ring == 1:
					ring1[n_idx] = true
				else:
					ring2[n_idx] = true
		frontier = next_frontier

	return [_sorted_cell_indices(ring1), _sorted_cell_indices(ring2)]


static func _territory_set(territory_cells) -> Dictionary:
	var owned: Dictionary = {}
	if territory_cells == null:
		return owned
	for idx in territory_cells:
		owned[int(idx)] = true
	return owned


static func _sorted_cell_indices(marks: Dictionary) -> PackedInt32Array:
	if marks.is_empty():
		return PackedInt32Array()
	var keys: Array = marks.keys()
	keys.sort()
	var out := PackedInt32Array()
	out.resize(keys.size())
	for i in range(keys.size()):
		out[i] = int(keys[i])
	return out


static func _is_water_cell(cell) -> bool:
	if cell == null:
		return true
	if "landform" in cell and LandformTypeScript.is_water(int(cell.landform)):
		return true
	if "is_water" in cell:
		var flag: Variant = cell.is_water
		if flag is bool and bool(flag):
			return true
	return false
