extends RefCounted
class_name AnnualReportViewModel

## 年度报告视图模型。
##
## 原则：**只加不改**。`chapters[i].rows[j]` 的既有 key（label/current/previous/delta/rate）
## 与 `full_text` 的输出顺序都被测试与"复制全文"依赖，不允许改动语义。
## 新增的 `value / before / unit / note / direction` 是给纸本长卷的图表与账簿用的原始量，
## 全部由同一份 native 快照派生，不引入第二套口径。

const ERA_IDS := ["stone", "agrarian", "kingdom", "empire", "exploration", "enlightenment", "steam", "electrical", "atomic", "information", "intelligent"]
const ERA_NAMES := ["石器时代", "农耕时代", "王国时代", "帝国时代", "探索时代", "启蒙时代", "蒸汽时代", "电气时代", "原子时代", "信息时代", "智能时代"]
const TIERS := ["无人区", "聚落", "乡村", "小镇", "县城", "城市", "都市", "特大都市"]
const CHAPTER_TITLES := ["年度总述", "国民经济", "人口与民生", "产业与建设", "城乡与国土", "科技与文明", "市场与财政", "资源与年度问题", "发展考核"]
const CHAPTER_ICONS := [&"country.economy", &"country.economy", &"family.house", &"economy.building", &"country.politics", &"country.technology", &"economy.building.transport", &"geo", &"technology.milestone"]
## Chapter titles, number bands, charts and ledgers carry the data themselves.
const CHAPTER_LEADS := ["", "", "", "", "", "", "", "", ""]
const SCORE_LABELS := ["综合满意度", "基本需求满足", "就业状况", "产业有效运转", "GDP 增长", "人均 GDP 增长", "人口增长", "建筑增长", "聚落发展", "科技进步"]
const SCORE_WEIGHTS := [20.0, 20.0, 15.0, 15.0, 8.0, 6.0, 5.0, 3.0, 3.0, 5.0]
const GRADE_BANDS_V1 := [
	{"grade": "SS", "min": 94.0, "max": 100.0},
	{"grade": "S", "min": 86.0, "max": 94.0},
	{"grade": "A", "min": 75.0, "max": 86.0},
	{"grade": "B", "min": 60.0, "max": 75.0},
	{"grade": "C", "min": 45.0, "max": 60.0},
	{"grade": "D", "min": 30.0, "max": 45.0},
	{"grade": "E", "min": 0.0, "max": 30.0},
]
const GRADE_BANDS_V2 := [
	{"grade": "SS", "min": 98.0, "max": 100.0},
	{"grade": "S", "min": 93.0, "max": 98.0},
	{"grade": "A", "min": 84.0, "max": 93.0},
	{"grade": "B", "min": 72.0, "max": 84.0},
	{"grade": "C", "min": 52.0, "max": 72.0},
	{"grade": "D", "min": 32.0, "max": 52.0},
	{"grade": "E", "min": 0.0, "max": 32.0},
]
const DIMENSION_NAMES := ["生计", "基本生活", "舒适生活", "奢侈消费", "收入", "储蓄", "税负", "发展"]
const TAX_KEYS := [
	["income_tax", "所得税"], ["consumption_tax", "消费税"], ["business_tax", "营业税"],
	["import_tax", "进口关税"], ["export_tax", "出口关税"],
]
const METRICS := [
	["gdp", "全年国内生产总值（GDP）", "money", 1], ["revenue", "生产经营收入", "money", 1],
	["input_cost", "中间投入", "money", 1], ["maintenance", "维护支出", "money", 1],
	["wages", "工资实付总额", "money", 1], ["profit", "经营盈余", "money", 1],
	["household_income", "居民收入", "money", 1], ["household_expense", "居民消费支出", "money", 1],
	["funds", "年末居民资金", "money", 1],
	["population", "年末总人口", "people", 2], ["births", "本年出生人口", "people", 2],
	["deaths", "本年死亡人口", "people", 2], ["employed", "年末就业人口", "people", 2],
	["satisfaction", "年末综合满意度", "ratio", 2], ["survival", "年末基本需求满足", "ratio", 2],
	["families", "年末显赫家族", "count", 2], ["persons", "年末重要人物", "count", 2],
	["buildings", "年末建筑总量", "count", 3], ["built", "本年竣工建筑", "count", 3],
	["removed", "本年主动拆除建筑", "count", 3], ["pending_buildings", "年末在建建筑", "count", 3],
	["suspended", "年末停产建筑", "count", 3], ["utilization", "年末产能利用率", "ratio", 3],
	["job_capacity", "年末工作岗位", "count", 3], ["wages_due", "应付工资总额", "money", 3],
	["output", "本年商品产量", "goods", 3], ["sold", "本年商品售出量", "goods", 3],
	["discarded", "本年废弃产出", "goods", 3],
	["territory", "年末领土格数", "count", 4], ["settlements", "年末有人口聚落", "count", 4],
	["settlements_founded", "本年新增聚落", "count", 4], ["settlements_lost", "本年消失聚落", "count", 4],
	["settlements_upgraded", "本年聚落升级次数", "count", 4], ["settlements_downgraded", "本年聚落降级次数", "count", 4],
	["technologies", "年末已掌握科技", "count", 5], ["research_purchased", "累计科研采购增加", "goods", 5],
	["research_consumed", "本年科技点使用", "goods", 5],
	["trade_value", "本年跨国贸易成交额", "money", 6], ["trade_quantity", "本年跨国贸易成交量", "goods", 6],
	["trade_orders", "本年跨国贸易成交单数", "count", 6], ["income_tax", "所得税收入", "money", 6],
	["consumption_tax", "消费税收入", "money", 6], ["business_tax", "营业税收入", "money", 6],
	["import_tax", "进口关税收入", "money", 6], ["export_tax", "出口关税收入", "money", 6],
	["subsidies", "财政补贴实付", "money", 6], ["producer_support", "生产扶持实收", "money", 6],
	["treasury", "年末国库资金", "money", 6],
	["resource_extracted", "本年自然资源提取量", "goods", 7], ["climate_loss", "气候造成的产量损失", "goods", 7],
]
const STOCKS := ["funds", "population", "employed", "satisfaction", "survival", "families", "persons", "buildings", "pending_buildings", "suspended", "utilization", "job_capacity", "territory", "settlements", "technologies", "treasury"]

static func build(report: Dictionary, previous: Dictionary = {}, catalogs: Dictionary = {}) -> Dictionary:
	if not bool(report.get("ok", false)):
		return {"available": false, "title": "国家年度发展报告", "chapters": [], "full_text": "尚无年度报告。"}
	var totals: Dictionary = report.get("totals", {})
	var before: Dictionary = previous.get("totals", {})
	var opening: Dictionary = report.get("opening", {})
	var closing: Dictionary = report.get("closing", {})
	var era: int = clampi(int(report.get("era", 0)), 0, ERA_IDS.size() - 1)
	var complete: bool = bool(report.get("complete", false))
	var year: int = int(report.get("year", 0)) + 1
	var has_previous: bool = not previous.is_empty()
	var chapters: Array[Dictionary] = []
	for i in CHAPTER_TITLES.size():
		chapters.append({
			"title": CHAPTER_TITLES[i], "icon": CHAPTER_ICONS[i], "number": i + 1,
			"lead": CHAPTER_LEADS[i], "rows": [], "details": [],
			"figures": [], "visuals": [], "margin_notes": [], "has_previous": false,
		})
	var gdp: int = int(totals.get("gdp", 0))
	var population: int = int(totals.get("population", 0))
	var new_tech: PackedInt64Array = report.get("new_technologies", PackedInt64Array())
	var qualities: PackedInt64Array = report.get("quality_average", PackedInt64Array())
	var avg_sat: int = int(qualities[0]) if qualities.size() > 0 else 0
	var avg_survival: int = int(qualities[1]) if qualities.size() > 1 else 0
	var per_capita: Variant = float(gdp) / population if population > 0 else null
	var previous_population: int = int(before.get("population", 0))
	var previous_pc: Variant = float(before.get("gdp", 0)) / previous_population if previous_population > 0 else null

	# ── 01 年度总述 ────────────────────────────────────────────────────────
	# 本章不放正文：四个总量已由数字带逐项列示（并带同比），章首那行 lead 交代了
	# 「这是本年总量与上年对照」。此前的叙述句、风险提示句与「见后文」都是解释性文字，
	# 已按「只说这是什么数据」的口径删除。

	# ── 指标行（沿用原口径，附加原始量） ────────────────────────────────────
	for spec in METRICS:
		var baseline: Variant = before.get(spec[0], null)
		if baseline == null and STOCKS.has(spec[0]):
			baseline = opening.get(spec[0], null)
		chapters[int(spec[3])].rows.append(_row(String(spec[1]), totals.get(spec[0], null), baseline, String(spec[2])))
	chapters[1].rows.insert(1, _row("人均年度 GDP（按年末人口）", per_capita, previous_pc, "money"))

	var births: int = int(totals.get("births", 0))
	var deaths: int = int(totals.get("deaths", 0))
	var migration: int = population - int(opening.get("population", 0)) - births + deaths
	chapters[2].details.append("自然增长 %s；迁移及领土调整的净影响 %s。" % [_signed(births - deaths, "people"), _signed(migration, "people")])
	chapters[2].rows.append(_row("全年平均综合满意度", avg_sat, _previous_quality(previous, 0), "ratio"))
	chapters[2].rows.append(_row("全年平均基本需求满足", avg_survival, _previous_quality(previous, 1), "ratio"))
	chapters[2].rows.append(_row("年末失业人口", maxi(0, population - int(totals.get("employed", 0))), null, "people"))

	var dimensions: PackedInt64Array = closing.get("satisfaction_dimensions", PackedInt64Array())
	var old_dimensions: PackedInt64Array = previous.get("closing", {}).get("satisfaction_dimensions", PackedInt64Array())
	for i in mini(dimensions.size(), DIMENSION_NAMES.size()):
		chapters[2].rows.append(_row("全年平均" + DIMENSION_NAMES[i] + "满意度", dimensions[i] if dimensions[i] >= 0 else null, old_dimensions[i] if i < old_dimensions.size() and old_dimensions[i] >= 0 else null, "ratio"))
	var profession_names: PackedStringArray = catalogs.get("profession_names", PackedStringArray())
	for row in closing.get("professions", []):
		var id: int = int(row.get("id", -1))
		var label: String = profession_names[id] if id >= 0 and id < profession_names.size() else "职业 %d" % (id + 1)
		chapters[2].details.append("%s：人口 %s，综合满意度 %s，资金 %s。" % [label, format_value(row.get("count", 0), "people"), format_value(row.get("value", 0), "ratio"), format_value(row.get("secondary", 0), "money")])

	var building_names: PackedStringArray = catalogs.get("building_names", PackedStringArray())
	var industry_rows: Array = []
	for row in report.get("industry_totals", []):
		var id: int = int(row.get("id", -1))
		var label: String = building_names[id] if id >= 0 and id < building_names.size() else "建筑类型 %d" % (id + 1)
		industry_rows.append({"id": id, "label": label, "value": _normalized(row.get("value", 0), "money"), "secondary": _normalized(row.get("secondary", 0), "money")})
		chapters[3].details.append("%s：增加值 %s，实付工资 %s。" % [label, format_value(row.get("value", 0), "money"), format_value(row.get("secondary", 0), "money")])

	var tiers: PackedInt64Array = closing.get("tiers", PackedInt64Array())
	var previous_closing: Dictionary = previous.get("closing", opening)
	var old_tiers: PackedInt64Array = previous_closing.get("tiers", PackedInt64Array())
	for i in range(1, mini(TIERS.size(), tiers.size())):
		chapters[4].rows.append(_row(TIERS[i] + "数量", tiers[i], old_tiers[i] if i < old_tiers.size() else null, "count"))
	var town_rows: Array = closing.get("towns", [])
	for town in town_rows:
		var prior: Dictionary = {}
		for old in previous_closing.get("towns", []):
			if int(old.get("cell", -1)) == int(town.get("cell", -2)):
				prior = old
				break
		var change := "本年新增归属记录" if prior.is_empty() else "人口增减 %s，建筑增减 %s，等级 %s → %s" % [_signed(int(town.get("population", 0)) - int(prior.get("population", 0)), "people"), _signed(int(town.get("buildings", 0)) - int(prior.get("buildings", 0)), "count"), TIERS[clampi(int(prior.get("tier", 0)), 0, 7)], TIERS[clampi(int(town.get("tier", 0)), 0, 7)]]
		chapters[4].details.append("地块 %d · %s：人口 %s，建筑 %s。%s。" % [int(town.get("cell", 0)), TIERS[clampi(int(town.get("tier", 0)), 0, 7)], format_value(town.get("population", 0), "people"), format_value(town.get("buildings", 0), "count"), change])

	var technology_names: PackedStringArray = catalogs.get("technology_names", PackedStringArray())
	for id in new_tech:
		chapters[5].details.append(technology_names[id] if id >= 0 and id < technology_names.size() else "科技 %d" % (id + 1))
	if new_tech.is_empty():
		chapters[5].details.append("本年未新增完成科技。")

	var good_names: PackedStringArray = catalogs.get("good_names", PackedStringArray())
	var good_rows: Array = closing.get("goods", [])
	for row in good_rows:
		var id: int = int(row.get("id", -1))
		var label: String = good_names[id] if id >= 0 and id < good_names.size() else "商品 %d" % (id + 1)
		chapters[6].details.append("%s：年末市场库存 %s，现价库存估值 %s，本国市场最大缺货比例 %s。" % [label, format_value(row.get("count", 0), "goods"), format_value(row.get("value", 0), "money"), format_value(row.get("secondary", 0), "ratio")])

	var resource_names: PackedStringArray = catalogs.get("resource_names", PackedStringArray())
	# 「认没认出来」由目录给（下标同 resource_names）。缺省表示调用方没报告，
	# 那时不过滤 —— 与效果徽章同一条纪律：没报告 ≠ 是 0。
	var resource_discovered: PackedByteArray = catalogs.get("resource_discovered", PackedByteArray())
	var resource_rows: Array = []
	for row in report.get("resource_totals", []):
		var id: int = int(row.get("id", -1))
		# 原生是按"领土上有这份储量"出行的，所以还没认出来的矿种也会带着剩余量出现。
		# 年报不该替玩家提前翻牌：认矿门控（ResourceProfile.discovery_technology_tags）
		# 与地图覆盖层、悬停卡完全一致，没认出来就不列。
		if id >= 0 and id < resource_discovered.size() and resource_discovered[id] == 0:
			continue
		var label: String = resource_names[id] if id >= 0 and id < resource_names.size() else "资源 %d" % (id + 1)
		resource_rows.append({"id": id, "label": label, "value": _normalized(row.get("value", 0), "goods"), "remaining": _normalized(row.get("count", 0), "goods")})
		chapters[7].details.append("%s：本年提取 %s，最近记录剩余 %s。" % [label, format_value(row.get("value", 0), "goods"), format_value(row.get("count", 0), "goods")])
	if resource_rows.is_empty():
		chapters[7].details.append("本年尚无已掌握的资源。")

	var parts: PackedInt64Array = report.get("score_parts", PackedInt64Array())
	for i in mini(parts.size(), SCORE_LABELS.size()):
		chapters[8].details.append("%s：%.2f / %.0f 分" % [SCORE_LABELS[i], float(parts[i]) / 100.0, SCORE_WEIGHTS[i]])
	var cap: int = int(report.get("grade_cap", -1))
	if cap >= 0:
		chapters[8].details.append("评级上限：%s" % ("D" if cap == 5 else "B"))

	# 每章是否真有可比行：决定账簿要不要保留「上年/增减」两列。
	# 首年所有章都没有基线，这两列整列删掉，而不是逐行刷「无可比数据」。
	for chapter in chapters:
		var any_baseline := false
		for row in chapter.rows:
			if bool(row.get("has_baseline", false)):
				any_baseline = true
				break
		chapter["has_previous"] = any_baseline
	var score_value: float = build_score(report)
	var reward_text: String = points_text(int(report.get("reward_q16", 0)))
	_attach_figures(chapters, totals, before, opening, avg_sat, avg_survival, new_tech, gdp, population, births, deaths, score_value, String(report.get("grade", "—")), reward_text)
	_attach_visuals(chapters, report, tiers, old_tiers, dimensions, old_dimensions, industry_rows, resource_rows, parts, score_value)
	_attach_notes(chapters, totals, has_previous)

	var title: String = "第 %d 年 · 国家年度发展报告" % year
	var full_lines: Array[String] = [String(report.get("country_name", "本国")), title, "文明阶段：" + ERA_NAMES[era], ""]
	for chapter in chapters:
		full_lines.append("%s\n" % String(chapter.title))
		full_lines.append(String(chapter.lead))
		if not chapter.rows.is_empty():
			full_lines.append("指标｜本年｜上年（首年为期初）｜增减｜增幅")
		for row in chapter.rows:
			full_lines.append("%s｜%s｜%s｜%s｜%s" % [row.label, row.current, row.previous, row.delta, row.rate])
		for detail in chapter.details:
			full_lines.append(String(detail))
		full_lines.append("")
	full_lines.append("原始年度账目（金额单位为 1/10000 游戏货币，商品单位为 1/1000，比例单位为 1/65536）")
	for spec in METRICS:
		if totals.has(spec[0]):
			full_lines.append("%s：%d" % [spec[1], int(totals[spec[0]])])
	full_lines.append("年度额外理念奖励原值（Q16）：%d" % int(report.get("reward_q16", 0)))
	var months_gdp: PackedInt64Array = report.get("monthly_gdp", PackedInt64Array())
	var months_population: PackedInt64Array = report.get("monthly_population", PackedInt64Array())
	if complete and not months_gdp.is_empty():
		full_lines.append("月度统计附表：月份｜已结算 GDP 原值（1/10000 游戏货币）｜月末人口")
		for month in mini(months_gdp.size(), months_population.size()):
			full_lines.append("%d｜%d｜%d" % [month + 1, months_gdp[month], months_population[month]])

	var tax_parts: Array = []
	for spec in TAX_KEYS:
		var amount: int = int(totals.get(spec[0], 0))
		if amount != 0:
			tax_parts.append({"key": String(spec[0]), "label": String(spec[1]), "value": _normalized(amount, "money")})
	tax_parts.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.value) > float(b.value))
	var tax_total: float = 0.0
	for part in tax_parts:
		tax_total += float(part.value)

	return {
		"available": true, "id": int(report.get("id", 0)), "title": title,
		"country_name": String(report.get("country_name", "本国")), "era_name": ERA_NAMES[era],
		"art_path": "res://assets/ui/annual_chronicle/%s.png" % ERA_IDS[era],
		"grade": String(report.get("grade", "—")), "grade_index": int(report.get("grade_index", 6)),
		"score": float(report.get("score_bp", 0)) / 100.0, "complete": complete,
		"reward_text": points_text(int(report.get("reward_q16", 0))), "reward_settled": bool(report.get("reward_settled", false)),
		"chapters": chapters, "full_text": "\n".join(full_lines),
		"kpis": [_row("全年 GDP", gdp, before.get("gdp", null), "money"), _row("年末人口", population, before.get("population", opening.get("population", null)), "people"), _row("全年平均满意度", avg_sat, _previous_quality(previous, 0), "ratio"), _row("新增科技", new_tech.size(), null, "count")],
		"monthly_gdp": report.get("monthly_gdp", PackedInt64Array()),
		"monthly_population": report.get("monthly_population", PackedInt64Array()),
		# ── 纸本长卷新增：图表与账簿所需的原始量（只加不改） ──────────────
		"year": year, "era_index": era, "score_bp": int(report.get("score_bp", 0)),
		"score_value": float(report.get("score_bp", 0)) / 100.0,
		"grade_cap": cap, "has_previous": has_previous,
		"grade_bands": GRADE_BANDS_V1 if int(report.get("scoring_version", 1)) == 1 else GRADE_BANDS_V2,
		"months": months_gdp.size(),
		"score_parts": parts, "score_labels": PackedStringArray(SCORE_LABELS),
		"score_weights": PackedFloat32Array(SCORE_WEIGHTS),
		"dimension_names": PackedStringArray(DIMENSION_NAMES),
		"satisfaction_dimensions": dimensions,
		"satisfaction_dimensions_previous": old_dimensions,
		"tiers": tiers, "tiers_previous": old_tiers, "tier_names": PackedStringArray(TIERS),
		"industry_rows": industry_rows, "resource_rows": resource_rows,
		"tax_parts": tax_parts, "tax_total": tax_total,
		"trade": {"value": _normalized(totals.get("trade_value", 0), "money"), "quantity": _normalized(totals.get("trade_quantity", 0), "goods"), "orders": _normalized(totals.get("trade_orders", 0), "count")},
		"population_flow": {"births": births, "deaths": deaths, "net": births - deaths, "migration": migration},
	}


# ── 数字带（每章 2–4 个巨数） ────────────────────────────────────────────────

static func _attach_figures(chapters: Array[Dictionary], totals: Dictionary, before: Dictionary, opening: Dictionary, avg_sat: int, avg_survival: int, new_tech: PackedInt64Array, gdp: int, population: int, births: int, deaths: int, score: float, grade: String, reward_text: String) -> void:
	# 总述页放满六个关键量：四项总量之外补人均 GDP 与基本需求满足，
	# 让这一屏本身就是一个 2×3 的指标网格，而不是四个数加一整片白。
	var per_capita: Variant = float(gdp) / float(population) if population > 0 else null
	var previous_population: int = int(before.get("population", 0))
	var previous_per_capita: Variant = float(before.get("gdp", 0)) / float(previous_population) if previous_population > 0 else null
	chapters[0].figures = [
		_figure("全年 GDP", gdp, before.get("gdp", null), "money", "accent"),
		_figure("人均 GDP", per_capita, previous_per_capita, "money"),
		_figure("年末人口", population, before.get("population", opening.get("population", null)), "people"),
		_figure("平均满意度", avg_sat, null, "ratio"),
		_figure("基本需求满足", avg_survival, null, "ratio"),
		_figure("新增科技", new_tech.size(), null, "count"),
	]
	chapters[1].figures = [
		_figure("增加值", totals.get("gdp", 0), before.get("gdp", null), "money", "accent"),
		_figure("经营收入", totals.get("revenue", 0), before.get("revenue", null), "money"),
		_figure("经营盈余", totals.get("profit", 0), before.get("profit", null), "money"),
	]
	chapters[2].figures = [
		_figure("年末人口", population, before.get("population", opening.get("population", null)), "people", "accent"),
		_figure("自然增长", births - deaths, null, "people"),
		_figure("平均满意度", avg_sat, null, "ratio"),
	]
	chapters[3].figures = [
		_figure("建筑总量", totals.get("buildings", 0), before.get("buildings", null), "count", "accent"),
		_figure("本年竣工", totals.get("built", 0), null, "count"),
		_figure("停产", totals.get("suspended", 0), null, "count"),
	]
	chapters[4].figures = [
		_figure("有人口聚落", totals.get("settlements", 0), before.get("settlements", null), "count", "accent"),
		_figure("领土格数", totals.get("territory", 0), before.get("territory", null), "count"),
		_figure("升级次数", totals.get("settlements_upgraded", 0), null, "count"),
	]
	chapters[5].figures = [
		_figure("已掌握科技", totals.get("technologies", 0), before.get("technologies", null), "count", "accent"),
		_figure("本年新增", new_tech.size(), null, "count"),
		_figure("科研投入", totals.get("research_consumed", 0), null, "goods"),
	]
	chapters[6].figures = [
		_figure("贸易成交额", totals.get("trade_value", 0), before.get("trade_value", null), "money", "accent"),
		_figure("年末国库", totals.get("treasury", 0), before.get("treasury", null), "money"),
		_figure("税收合计", int(totals.get("income_tax", 0)) + int(totals.get("consumption_tax", 0)) + int(totals.get("business_tax", 0)) + int(totals.get("import_tax", 0)) + int(totals.get("export_tax", 0)), null, "money"),
	]
	chapters[7].figures = [
		_figure("资源提取", totals.get("resource_extracted", 0), before.get("resource_extracted", null), "goods", "accent"),
		_figure("气候损失", totals.get("climate_loss", 0), before.get("climate_loss", null), "goods"),
		_figure("停产建筑", totals.get("suspended", 0), null, "count"),
	]
	chapters[8].figures = [
		{"label": "综合得分", "text": "%.2f" % score, "raw": score, "unit": "", "delta": "—", "direction": 0, "tone": "accent"},
		{"label": "评级", "text": grade, "raw": null, "unit": "", "delta": "—", "direction": 0, "tone": "plain"},
		{"label": "理念奖励", "text": reward_text, "raw": null, "unit": "点", "delta": "—", "direction": 0, "tone": "plain"},
	]


# ── 可视化描述（决定每章挂哪张图、顺序与降级） ─────────────────────────────

static func _attach_visuals(chapters: Array[Dictionary], report: Dictionary, tiers: PackedInt64Array, old_tiers: PackedInt64Array, dimensions: PackedInt64Array, old_dimensions: PackedInt64Array, industry_rows: Array, resource_rows: Array, parts: PackedInt64Array, score: float) -> void:
	chapters[1].visuals.append({"kind": "month_area", "gdp": _normalize_series(report.get("monthly_gdp", PackedInt64Array()), "money"), "population": _normalize_series(report.get("monthly_population", PackedInt64Array()), "people")})
	chapters[2].visuals.append({"kind": "radar", "names": PackedStringArray(DIMENSION_NAMES), "values": _ratio_series(dimensions), "previous": _ratio_series(old_dimensions)})
	chapters[3].visuals.append({"kind": "bars", "rows": industry_rows, "unit": "", "label": "行业增加值"})
	chapters[4].visuals.append({"kind": "stairs", "names": PackedStringArray(TIERS), "values": _count_series(tiers), "previous": _count_series(old_tiers)})
	chapters[5].visuals.append({"kind": "era", "index": clampi(int(report.get("era", 0)), 0, ERA_IDS.size() - 1), "names": PackedStringArray(ERA_NAMES)})
	var tax_parts: Array = []
	var totals: Dictionary = report.get("totals", {})
	for spec in TAX_KEYS:
		var amount: int = int(totals.get(spec[0], 0))
		if amount != 0:
			tax_parts.append({"key": String(spec[0]), "label": String(spec[1]), "value": float(amount) / 10000.0})
	tax_parts.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.value) > float(b.value))
	if not tax_parts.is_empty():
		chapters[6].visuals.append({"kind": "tax", "parts": tax_parts})
	chapters[7].visuals.append({"kind": "bars", "rows": resource_rows, "unit": "", "label": "资源提取量"})
	if parts.size() >= SCORE_LABELS.size():
		chapters[8].visuals.append({"kind": "score_parts", "parts": parts, "labels": PackedStringArray(SCORE_LABELS), "weights": PackedFloat32Array(SCORE_WEIGHTS)})
	chapters[8].visuals.append({"kind": "grade_ruler", "score": score, "grade": String(report.get("grade", "—")), "grade_index": int(report.get("grade_index", 6)), "cap": int(report.get("grade_cap", -1)), "complete": bool(report.get("complete", false))})


# ── 边注（短句，只在真正有话说时才出现） ────────────────────────────────────

static func _attach_notes(chapters: Array[Dictionary], totals: Dictionary, has_previous: bool) -> void:
	if not has_previous:
		chapters[0].margin_notes.append("首年：以年初为期初基准，不列同比。")
		chapters[1].margin_notes.append("首年：期初即基准，增减栏留空。")
		chapters[2].margin_notes.append("首年：期初即基准，增减栏留空。")
	var revenue: float = float(totals.get("revenue", 0))
	if revenue > 0.0:
		chapters[1].margin_notes.append("工资实付占经营收入 %.1f%%，中间投入与维护合计 %.1f%%。" % [float(totals.get("wages", 0)) * 100.0 / revenue, (float(totals.get("input_cost", 0)) + float(totals.get("maintenance", 0))) * 100.0 / revenue])
	var gdp: float = float(totals.get("gdp", 0))
	if gdp > 0.0:
		chapters[6].margin_notes.append("五项税收合计相当于增加值的 %.1f%%。" % [(float(totals.get("income_tax", 0)) + float(totals.get("consumption_tax", 0)) + float(totals.get("business_tax", 0)) + float(totals.get("import_tax", 0)) + float(totals.get("export_tax", 0))) * 100.0 / gdp])


# ── 派生工具 ────────────────────────────────────────────────────────────────

static func _figure(label: String, value: Variant, previous: Variant, kind: String, tone: String = "plain") -> Dictionary:
	var current_text: String = format_value(value, kind)
	var delta_text: String = "—"
	var direction: int = 0
	if value != null and previous != null:
		var change: float = float(value) - float(previous)
		delta_text = ("%+.2f 个百分点" % (change / 655.36)) if kind == "ratio" else _signed(change, kind)
		direction = 1 if change > 0.0 else (-1 if change < 0.0 else 0)
	return {
		"label": label, "text": current_text, "raw": _normalized(value, kind),
		"unit": unit_suffix(kind), "delta": delta_text, "direction": direction, "tone": tone,
	}


static func _normalized(value: Variant, kind: String) -> Variant:
	if value == null:
		return null
	var number: float = float(value)
	match kind:
		"ratio": return number * 100.0 / 65536.0
		"money": return number / 10000.0
		"goods": return number / 1000.0
		_: return number


static func _normalize_series(values: PackedInt64Array, kind: String) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.resize(values.size())
	for i in values.size():
		out[i] = float(_normalized(values[i], kind))
	return out


static func _ratio_series(values: PackedInt64Array) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	for value in values:
		out.append(-1.0 if value < 0 else float(_normalized(value, "ratio")))
	return out


static func _count_series(values: PackedInt64Array) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	for value in values:
		out.append(float(value))
	return out


static func build_score(report: Dictionary) -> float:
	return float(report.get("score_bp", 0)) / 100.0


static func unit_suffix(kind: String) -> String:
	# 单位只留一处。format_value 已经把「%」写进比例、「人」写进人口，
	# 这里再返回一次会让数字带把单位排两遍，读作「91.6%%」「46 人人」。
	return ""


static func _previous_quality(previous: Dictionary, index: int) -> Variant:
	var values: PackedInt64Array = previous.get("quality_average", PackedInt64Array())
	return values[index] if index >= 0 and index < values.size() else null


static func _row(label: String, value: Variant, previous: Variant, kind: String, note: String = "") -> Dictionary:
	var delta: String = "—"
	var rate: String = "无可比数据"
	var direction: int = 0
	if value != null and previous != null:
		var change: float = float(value) - float(previous)
		delta = "%+.2f 个百分点" % (change / 655.36) if kind == "ratio" else _signed(change, kind)
		if float(previous) > 0.0 and kind != "ratio":
			rate = "%+.2f%%" % (change * 100.0 / float(previous))
		direction = 1 if change > 0.0 else (-1 if change < 0.0 else 0)
	return {
		"label": label, "current": format_value(value, kind), "previous": format_value(previous, kind),
		"delta": delta, "rate": rate,
		"kind": kind, "unit": unit_suffix(kind), "note": note, "direction": direction,
		"value": _normalized(value, kind), "before": _normalized(previous, kind),
		"has_baseline": value != null and previous != null,
	}


static func format_value(value: Variant, kind: String) -> String:
	if value == null:
		return "无可比数据"
	var number: float = float(value)
	if kind == "ratio":
		return "%.1f%%" % (number * 100.0 / 65536.0)
	if kind == "money":
		return UITokens.format_compact_number_cn(number / 10000.0)
	if kind == "goods":
		return UITokens.format_compact_number_cn(number / 1000.0)
	if kind == "number":
		return UITokens.format_compact_number_cn(number)
	return UITokens.format_compact_number_cn(number) + (" 人" if kind == "people" else "")


static func _signed(value: Variant, kind: String) -> String:
	return ("+" if float(value) > 0 else "") + format_value(value, kind)


static func points_text(value: int) -> String:
	return ("%.2f" % (float(value) / 65536.0)).trim_suffix("0").trim_suffix("0").trim_suffix(".")
