extends RefCounted

## Builds the inspector header and summary indicators for a selected cell.

const OverviewEmployment = preload("res://scripts/ui/cell_inspector/overview_employment.gd")


static func _build_header(host,
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
	meta.append(host._Overview_delegate._ownership_text(host, country_summary, intel_visible))
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



static func _ownership_text(host, country_summary: Dictionary, intel_visible: bool) -> String:
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

static func _kpis(host,
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
		"kind": "percent", "value": habitability, "caption": h._Geography_delegate._score_caption(h, habitability),
		"tooltip": "由气温、湿度、植被活力、海拔与通行综合估算的定居条件。",
	}
	if not intel_visible:
		return [suitability_kpi, climate_kpi, {
			"id": "kpi_intel", "title": "情报", "icon": &"system.unknown", "kind": "text",
			"text": "视野之外", "caption": "人口与市场未知",
		}]
	var population = int(population_summary.get("population", 0))
	var carrying = int(population_summary.get("carrying_k_eff", 0))
	var ownership = host._Overview_delegate._ownership_text(host, country_summary, true)
	if bool(population_summary.get("pending", false)):
		return [suitability_kpi, climate_kpi, {
			"id": "kpi_owner", "title": "归属", "icon": &"metric.territory", "kind": "text",
			"text": String(country_summary.get("country_name", "无主之地")) \
				if bool(country_summary.get("owned", false)) else "无主",
			"caption": ownership, "tooltip": ownership,
		}, {
			"id": "kpi_population", "title": "人口", "icon": &"family.metric.population", "kind": "text",
			"text": "—", "caption": "",
		}]
	if population <= 0 or not bool(population_summary.get("ok", false)):
		var owned = bool(country_summary.get("owned", false))
		var prospect_kpi = {
			"id": "kpi_carrying", "title": "潜在承载", "icon": &"ecology.growth",
			"kind": "count", "value": float(carrying), "caption": "",
			"tooltip": "按本地粮食产能估算，此地最多能养活的人口。",
		}
		if carrying <= 0:
			prospect_kpi = host._Overview_delegate._primary_resource_kpi(host, cell_idx, is_water)
		return [suitability_kpi, prospect_kpi, climate_kpi, {
			"id": "kpi_owner", "title": "归属", "icon": &"metric.territory", "kind": "text",
			"text": String(country_summary.get("country_name", "无主之地")) if owned else "无主",
			"caption": "" if owned else "可开拓",
			"tooltip": ownership,
		}]
	var jobs_capacity = int(population_summary.get("job_capacity", 0))
	var jobs_filled = int(population_summary.get("jobs_filled", 0))
	var employment := OverviewEmployment.from_snapshot(population_summary)
	var employed_population := employment[0]
	var unemployed_population := employment[1]
	var openings = int(population_summary.get("job_openings", 0))
	# 页头与全国经济、阶层、城市、年度报告用同一个口径：人口就业率。
	# 综合不可读时才退回 cell summary 的生存值，并在提示里说明口径。
	var survival_q16 = int(population_summary.get("satisfaction_q16", 0))
	var composite = host._Overview_delegate._cell_composite_satisfaction(host, cell_idx)
	var satisfaction = composite if composite >= 0.0 else float(survival_q16) / 65536.0
	var satisfaction_tooltip = "生存满足 %s；生活短板见人口页。" % h._q16_percent_text(survival_q16)
	if composite < 0.0:
		satisfaction_tooltip = "仅含口粮与御寒满足情况。"
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

static func _gdp_kpi(host, cell_idx: int) -> Dictionary:
	var h = host
	var gdp = host._local_gdp(cell_idx)
	if gdp.is_empty():
		return {
			"id": "kpi_gdp", "title": "GDP", "icon": &"metric.treasury",
			"kind": "text", "text": "—", "caption": "统计中",
			"tooltip": "本年累计产值",
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

static func _cell_composite_satisfaction(host, cell_idx: int) -> float:
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



static func _primary_resource_kpi(host, cell_idx: int, is_water: bool) -> Dictionary:
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
