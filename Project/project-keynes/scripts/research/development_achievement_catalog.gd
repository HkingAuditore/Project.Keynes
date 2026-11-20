class_name DevelopmentAchievementCatalog
extends RefCounted

## Static authoring only. Economy publishes committed metric samples, Trigger
## owns consecutive progress, and Country owns the resulting permanent signal.

enum MetricType {
	POPULATION = 1,
	MAX_SETTLEMENT_TIER = 2,
	SETTLEMENT_COUNT = 3,
	BUILDING_INSTALLED = 4,
	BUILDING_ACTIVE = 5,
	INDUSTRY_EMPLOYMENT = 6,
	INDUSTRY_OUTPUT = 7,
	SATISFACTION_Q16 = 8,
	TRADE_QUANTITY = 9,
	TRADE_BASE_VALUE = 10,
	TRADE_ORDER_COUNT = 11,
	TRADE_GOOD_VARIETY = 12,
	TRADE_PARTNER_COUNT = 13,
	PRODUCED_GOOD_VARIETY = 14,
}

enum SubjectKind {
	ANY = 0,
	SECTOR = 1,
	BUILDING = 2,
	BUILDING_FAMILY = 3,
	GOOD = 4,
}

const ERA_IDS := [
	"stone", "agrarian", "kingdom", "empire", "exploration", "enlightenment",
	"steam", "electrical", "atomic", "information", "intelligent",
]
const SECTOR_IDS := ["agriculture", "extractive", "manufacturing", "energy", "knowledge"]
const SECTOR_NAMES := ["农业", "采掘", "制造", "能源", "知识"]
const GOODS_SCALE := 1000
const Q16_ONE := 65536


static func definitions() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	_add(out, "development.commodity_crop_variety_2", "两类商品作物形成产出", "exploration",
		"形成至少两类商品作物的实际产出", MetricType.PRODUCED_GOOD_VARIETY,
		SubjectKind.GOOD, ["seed_cotton", "cotton_fiber", "flax_fiber", "spices", "latex"], 2, 1)
	_add(out, "development.commodity_crop_facilities_4_180d", "商品作物设施稳定经营", "exploration",
		"保持 4 座商品作物设施活跃 180 日", MetricType.BUILDING_ACTIVE,
		SubjectKind.BUILDING, ["cotton_garden", "household_flax_plot", "spice_shade_garden"], 4, 180)
	_add(out, "development.commodity_crop_trade_value_100000", "商品作物贸易资本", "exploration",
		"累计完成 10 万基础价值的商品作物贸易", MetricType.TRADE_BASE_VALUE,
		SubjectKind.GOOD, ["seed_cotton", "cotton_fiber", "flax_fiber", "spices", "latex"], 100000, 1)
	_add(out, "development.agricultural_employment_100_360d", "农业就业体系", "exploration",
		"保持 100 人农业就业 360 日", MetricType.INDUSTRY_EMPLOYMENT,
		SubjectKind.SECTOR, ["agriculture"], 100, 360)

	var population_thresholds := [100, 500, 2500, 12500, 62500, 312500]
	var population_eras := ["stone", "agrarian", "kingdom", "empire", "steam", "atomic"]
	var population_days := [90, 90, 180, 360, 720, 1095]
	for i in range(population_thresholds.size()):
		var threshold := int(population_thresholds[i])
		var days := int(population_days[i])
		_add(out, "development.population.%d_%dd" % [threshold, days],
			"人口规模 %d" % threshold, population_eras[i],
			"保持国家人口达到 %d 人共 %d 日" % [threshold, days],
			MetricType.POPULATION, SubjectKind.ANY, [], threshold, days)

	for row in [[1, 90, "agrarian"], [2, 180, "kingdom"], [3, 360, "empire"],
			[4, 720, "steam"], [5, 1095, "atomic"]]:
		_add(out, "development.settlement.tier_%d_%dd" % [row[0], row[1]],
			"聚落等级 %d" % row[0], row[2],
			"保持至少一座等级 %d 聚落共 %d 日" % [row[0], row[1]],
			MetricType.MAX_SETTLEMENT_TIER, SubjectKind.ANY, [], row[0], row[1])
	for row in [[2, 2, 180, "kingdom"], [3, 4, 360, "empire"],
			[4, 8, 720, "electrical"], [5, 16, 1095, "information"]]:
		_add(out, "development.settlements.tier_%d_count_%d_%dd" % [row[0], row[1], row[2]],
			"多聚落体系", row[3],
			"保持 %d 座等级 %d 以上聚落共 %d 日" % [row[1], row[0], row[2]],
			MetricType.SETTLEMENT_COUNT, SubjectKind.ANY, [str(row[0])], row[1], row[2])

	var building_thresholds := [2, 4, 8, 16, 32, 64]
	var building_eras := ["agrarian", "kingdom", "empire", "steam", "electrical", "information"]
	var building_days := [90, 180, 360, 360, 720, 1095]
	for i in range(building_thresholds.size()):
		var threshold := int(building_thresholds[i])
		var days := int(building_days[i])
		_add(out, "development.buildings.active_%d_%dd" % [threshold, days],
			"活跃产业规模 %d" % threshold, building_eras[i],
			"保持 %d 座生产设施活跃共 %d 日" % [threshold, days],
			MetricType.BUILDING_ACTIVE, SubjectKind.ANY, [], threshold, days)

	var employment_thresholds := [10, 50, 250, 1250, 6250]
	var employment_eras := ["kingdom", "empire", "steam", "atomic", "information"]
	var employment_days := [90, 180, 360, 720, 1095]
	for sector in range(SECTOR_IDS.size()):
		for i in range(employment_thresholds.size()):
			var threshold := int(employment_thresholds[i])
			var days := int(employment_days[i])
			_add(out, "development.employment.%s.%d_%dd" % [SECTOR_IDS[sector], threshold, days],
				"%s就业 %d" % [SECTOR_NAMES[sector], threshold], employment_eras[i],
				"保持%s就业达到 %d 人共 %d 日" % [SECTOR_NAMES[sector], threshold, days],
				MetricType.INDUSTRY_EMPLOYMENT, SubjectKind.SECTOR,
				[SECTOR_IDS[sector]], threshold, days)

	for sector in range(SECTOR_IDS.size()):
		for row in [[100, 180, "kingdom"], [1000, 360, "empire"],
				[10000, 720, "steam"], [100000, 1095, "atomic"]]:
			_add(out, "development.output.%s.%d_%dd" % [SECTOR_IDS[sector], row[0], row[1]],
				"%s产出规模 %d" % [SECTOR_NAMES[sector], row[0]], row[2],
				"保持%s周期折算产出达到 %d 共 %d 日" % [SECTOR_NAMES[sector], row[0], row[1]],
				MetricType.INDUSTRY_OUTPUT, SubjectKind.SECTOR,
				[SECTOR_IDS[sector]], int(row[0]) * GOODS_SCALE, row[1])

	var satisfaction_values := [50, 55, 60, 65, 70]
	var satisfaction_eras := ["kingdom", "enlightenment", "electrical", "information", "intelligent"]
	var satisfaction_days := [180, 360, 720, 1095, 1095]
	for i in range(satisfaction_values.size()):
		var percent := int(satisfaction_values[i])
		var days := int(satisfaction_days[i])
		_add(out, "development.satisfaction.%d_%dd" % [percent, days],
			"综合满意度 %d%%" % percent, satisfaction_eras[i],
			"保持人口加权综合满意度达到 %d%% 共 %d 日" % [percent, days],
			MetricType.SATISFACTION_Q16, SubjectKind.ANY, [], Q16_ONE * percent / 100, days)

	for row in [[2, "exploration"], [4, "enlightenment"], [8, "atomic"], [16, "information"]]:
		_add(out, "development.trade.goods_%d" % row[0], "贸易商品 %d 类" % row[0], row[1],
			"累计贸易覆盖 %d 类商品" % row[0], MetricType.TRADE_GOOD_VARIETY,
			SubjectKind.ANY, [], row[0], 1)
	for row in [[1, "exploration"], [2, "steam"], [4, "atomic"], [8, "information"]]:
		_add(out, "development.trade.partners_%d" % row[0], "贸易伙伴 %d 个" % row[0], row[1],
			"累计与 %d 个伙伴完成贸易" % row[0], MetricType.TRADE_PARTNER_COUNT,
			SubjectKind.ANY, [], row[0], 1)
	for row in [[100, "exploration"], [1000, "steam"], [10000, "atomic"], [100000, "information"]]:
		_add(out, "development.trade.quantity_%d" % row[0], "累计贸易量 %d" % row[0], row[1],
			"累计贸易量达到 %d 个显示单位" % row[0], MetricType.TRADE_QUANTITY,
			SubjectKind.ANY, [], int(row[0]) * GOODS_SCALE, 1)
		_add(out, "development.trade.value_%d" % (int(row[0]) * 10),
			"累计贸易价值 %d" % (int(row[0]) * 10), row[1],
			"累计贸易基础价值达到 %d" % (int(row[0]) * 10), MetricType.TRADE_BASE_VALUE,
			SubjectKind.ANY, [], int(row[0]) * 10, 1)

	# ─── 作物实践经验 ────────────────────────────────────────────────────────
	# 这是一类「干过才算懂」的门槛，供 research_routes 引用：主体是货物，指标是
	# 该货物所属建筑的合计日产出。阈值取「一阶采集建筑额定日产量的约 50%」：
	#   玉米/小麦/块茎/稻 1718 → 800，韧皮 3714 → 1800，香料 375 → 180，乳胶 5850 → 2900。
	# 之所以不用 100%：劳动力与投入不足时实际产出低于额定，取半额才不会误伤正常
	# 经营的暖区国家。
	# 棉花是例外，取 700 而不是 50%（593）：野生棉丛走 foraging_plants 气候档
	# （floor 0.35，temp±0.45），寒带开局仍能以 35% 地板产出约 415/日。700 把门槛
	# 推到 temp≈0.37 以上，刚好把 cold_highland（≤0.34）挡在外面——这正是本条
	# 门槛存在的理由。
	_add(out, "development.cotton_practice_700_180d", "棉花种植实践", "agrarian",
		"保持棉类建筑合计日产出达到 0.7 以上共 180 日", MetricType.INDUSTRY_OUTPUT,
		SubjectKind.GOOD, ["seed_cotton", "cotton_fiber"], 700, 180)
	_add(out, "development.fiber_practice_1800_180d", "纤维作物收制实践", "agrarian",
		"保持纤维类建筑合计日产出达到 1.8 以上共 180 日", MetricType.INDUSTRY_OUTPUT,
		SubjectKind.GOOD, ["flax_fiber", "bast_fiber"], 1800, 180)
	_add(out, "development.spice_practice_180_180d", "香料园圃实践", "agrarian",
		"保持香料类建筑合计日产出达到 0.18 以上共 180 日", MetricType.INDUSTRY_OUTPUT,
		SubjectKind.GOOD, ["spices"], 180, 180)
	_add(out, "development.rice_practice_800_180d", "稻作经营实践", "agrarian",
		"保持稻作建筑合计日产出达到 0.8 以上共 180 日", MetricType.INDUSTRY_OUTPUT,
		SubjectKind.GOOD, ["rice_grain"], 800, 180)
	_add(out, "development.grain_practice_800_180d", "谷物经营实践", "agrarian",
		"保持谷物建筑合计日产出达到 0.8 以上共 180 日", MetricType.INDUSTRY_OUTPUT,
		SubjectKind.GOOD, ["wheat_grain", "corn_grain", "potatoes"], 800, 180)
	_add(out, "development.latex_practice_2900_180d", "树液采割实践", "exploration",
		"保持乳胶采集建筑合计日产出达到 2.9 以上共 180 日", MetricType.INDUSTRY_OUTPUT,
		SubjectKind.GOOD, ["latex"], 2900, 180)

	# ─── 产业族实践经验 ──────────────────────────────────────────────────────
	# 作物之外的产业分支按「货物族」合并成一条信号：一族一条，而不是一建筑一条。
	# 原因是 max_state_instances 是全局 (definition, country) 上限，每个新 definition
	# 都会乘上国家数；逐建筑展开会直接顶爆。阈值同样取该族最低阶建筑的 50%。
	_add(out, "development.stone_clay_practice_1300_180d", "石料与黏土采制实践", "agrarian",
		"保持石料/黏土类建筑合计日产出达到 1.3 以上共 180 日", MetricType.INDUSTRY_OUTPUT,
		SubjectKind.GOOD, ["raw_stone", "clay"], 1300, 180)
	_add(out, "development.ore_metal_practice_542_180d", "矿石与金属冶炼实践", "agrarian",
		"保持矿石/金属类建筑合计日产出达到 0.54 以上共 180 日", MetricType.INDUSTRY_OUTPUT,
		SubjectKind.GOOD, ["wrought_iron", "copper", "tin_ore", "iron_ore", "lead_ore"], 542, 180)
	_add(out, "development.timber_practice_541_180d", "木料采制实践", "agrarian",
		"保持木料类建筑合计日产出达到 0.54 以上共 180 日", MetricType.INDUSTRY_OUTPUT,
		SubjectKind.GOOD, ["logs", "lumber"], 541, 180)
	_add(out, "development.salt_practice_625_180d", "制盐实践", "agrarian",
		"保持制盐建筑合计日产出达到 0.63 以上共 180 日", MetricType.INDUSTRY_OUTPUT,
		SubjectKind.GOOD, ["salt"], 625, 180)
	_add(out, "development.livestock_practice_812_180d", "畜牧与屠宰实践", "agrarian",
		"保持畜牧/屠宰类建筑合计日产出达到 0.81 以上共 180 日", MetricType.INDUSTRY_OUTPUT,
		SubjectKind.GOOD, ["game_meat", "livestock_products", "meat", "wool", "leather",
			"dairy_products"], 812, 180)
	_add(out, "development.textile_practice_406_180d", "纺织成衣实践", "agrarian",
		"保持纺织/成衣类建筑合计日产出达到 0.41 以上共 180 日", MetricType.INDUSTRY_OUTPUT,
		SubjectKind.GOOD, ["cloth", "clothing"], 406, 180)
	_add(out, "development.ceramic_glass_practice_1772_180d", "陶器与玻璃烧制实践", "agrarian",
		"保持陶器/玻璃类建筑合计日产出达到 1.77 以上共 180 日", MetricType.INDUSTRY_OUTPUT,
		SubjectKind.GOOD, ["pottery", "glass"], 1772, 180)
	_add(out, "development.fuel_practice_1083_180d", "燃料烧制与采掘实践", "agrarian",
		"保持燃料类建筑合计日产出达到 1.08 以上共 180 日", MetricType.INDUSTRY_OUTPUT,
		SubjectKind.GOOD, ["charcoal", "coal", "coke"], 1083, 180)
	return out


static func signal_rows() -> Array:
	var out: Array = []
	for definition in definitions():
		out.append([definition.signal_id, definition.display_name, 10, 0,
			["category.development", "era.%s" % definition.era_id], [], [], true])
	return out


static func compile_native_catalog(signal_ids: PackedStringArray) -> Dictionary:
	var ids := PackedStringArray()
	var signal_indices := PackedInt32Array()
	var names := PackedStringArray()
	var era_indices := PackedInt32Array()
	var objective_texts := PackedStringArray()
	var metric_types := PackedInt32Array()
	var subject_kinds := PackedInt32Array()
	var subject_offsets := PackedInt32Array([0])
	var subject_ids := PackedStringArray()
	var qualifier_thresholds := PackedInt64Array()
	var duration_days := PackedInt32Array()
	var seen := {}
	for definition in definitions():
		var id := String(definition.signal_id)
		var signal_index := signal_ids.find(id)
		var era_index := ERA_IDS.find(String(definition.era_id))
		if not id.begins_with("development.") or seen.has(id) or signal_index < 0 or era_index < 0:
			return {"ok": false, "reason": "development_achievement_invalid", "id": id}
		seen[id] = true
		ids.append(id)
		signal_indices.append(signal_index)
		names.append(String(definition.display_name))
		era_indices.append(era_index)
		objective_texts.append(String(definition.objective_text))
		metric_types.append(int(definition.metric_type))
		subject_kinds.append(int(definition.subject_kind))
		for subject_id in definition.subject_ids:
			subject_ids.append(String(subject_id))
		subject_offsets.append(subject_ids.size())
		qualifier_thresholds.append(int(definition.qualifier_threshold))
		duration_days.append(int(definition.duration_days))
	return {
		"ok": true,
		"development_metric_ids": ids,
		"development_metric_signal_indices": signal_indices,
		"development_metric_display_names": names,
		"development_metric_era_indices": era_indices,
		"development_metric_objective_texts": objective_texts,
		"development_metric_types": metric_types,
		"development_metric_subject_kinds": subject_kinds,
		"development_metric_subject_offsets": subject_offsets,
		"development_metric_subject_ids": subject_ids,
		"development_metric_qualifier_thresholds": qualifier_thresholds,
		"development_metric_duration_days": duration_days,
	}


static func _add(out: Array[Dictionary], signal_id: String, display_name: String,
		era_id: String, objective_text: String, metric_type: int, subject_kind: int,
		subject_ids: Array, qualifier_threshold: int, duration_days: int) -> void:
	out.append({
		"signal_id": signal_id,
		"display_name": display_name,
		"era_id": era_id,
		"objective_text": objective_text,
		"metric_type": metric_type,
		"subject_kind": subject_kind,
		"subject_ids": subject_ids.duplicate(),
		"qualifier_threshold": qualifier_threshold,
		"duration_days": duration_days,
	})
