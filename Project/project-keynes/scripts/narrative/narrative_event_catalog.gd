class_name NarrativeEventCatalog
extends Resource

## 默认事件库。采用大战略政务叙事笔法：
## 标题 = 地点·事件，正文以执政者高位视角交代局势、利益博弈与战略两难，
## 选项 = 明确政令，结果 = 制度后果，效果标签 = 对象 + 幅度 + 时长。

const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")
const NarrativeWeightRuleScript = preload("res://scripts/narrative/narrative_weight_rule.gd")
const NarrativeEffectSpecScript = preload("res://scripts/narrative/narrative_effect_spec.gd")
const NarrativeOutcomeScript = preload("res://scripts/narrative/narrative_outcome.gd")
const NarrativeOptionScript = preload("res://scripts/narrative/narrative_option.gd")
const NarrativeEventCatalogWaterworksScript = preload("res://scripts/narrative/narrative_event_catalog_waterworks.gd")
const NarrativeEventCatalogPeopleScript = preload("res://scripts/narrative/narrative_event_catalog_people.gd")
const NarrativeEventRegistryScript = preload("res://scripts/narrative/narrative_event_registry.gd")

@export var events: Array[Resource] = []

var _by_id: Dictionary = {}
var _by_channel: Dictionary = {}
var _indexed: bool = false


func rebuild_index() -> void:
	_by_id.clear()
	_by_channel.clear()
	for raw in events:
		if raw == null:
			continue
		var def: NarrativeEventDefinition = raw as NarrativeEventDefinition
		if def == null or def.event_id == &"":
			continue
		_by_id[def.event_id] = def
		_by_id[String(def.event_id)] = def
		var ch := int(def.trigger_channel)
		var bucket: Array = _by_channel.get(ch, [])
		bucket.append(def)
		_by_channel[ch] = bucket
	_indexed = true


func register_event(def: NarrativeEventDefinition) -> void:
	if def == null or def.event_id == &"":
		return
	for i in range(events.size()):
		var existing := events[i] as NarrativeEventDefinition
		if existing != null and existing.event_id == def.event_id:
			events[i] = def
			rebuild_index()
			return
	events.append(def)
	rebuild_index()


func get_event(event_id: StringName) -> NarrativeEventDefinition:
	if not _indexed:
		rebuild_index()
	if _by_id.has(event_id):
		return _by_id[event_id]
	var key_str := String(event_id)
	if _by_id.has(key_str):
		return _by_id[key_str]
	return null


func events_for_channel(channel: int) -> Array[NarrativeEventDefinition]:
	if not _indexed:
		rebuild_index()
	var out: Array[NarrativeEventDefinition] = []
	for item in _by_channel.get(channel, []):
		if item is NarrativeEventDefinition:
			out.append(item)
	return out


func all_events() -> Array[NarrativeEventDefinition]:
	if not _indexed:
		rebuild_index()
	var out: Array[NarrativeEventDefinition] = []
	for item in events:
		if item is NarrativeEventDefinition:
			out.append(item)
	return out


static func build_default_catalog() -> NarrativeEventCatalog:
	var catalog := NarrativeEventCatalog.new()
	var Op = NarrativeConditionScript.Op
	var Kind = NarrativeEffectSpecScript.Kind
	var Ch = NarrativeEventDefinitionScript.TriggerChannel

	# 1. 气候：干旱
	catalog.events.append(NarrativeEventDefinitionScript.from_dict({
		"event_id": "evt.climate.severe_drought",
		"title": "{settlement_name}·旱灾",
		"body_text": "持续逾月的酷热与少雨令{settlement_name}周边土地龟裂，蓄水设施见底，当季农作物面临大面积减产。地方呈报的灾情日益紧迫：若不及时介入赈济与调水，粮食短缺将迅速演变为人口流失与社会动荡。",
		"min_era_index": 1,
		"image_key": "climate.sun",
		"ai_visual_prompt": "Parched cracked farmland under a scorching sun in an ancient agrarian settlement, villagers digging irrigation ditches",
		"tags": ["climate", "drought", "agriculture", "crisis"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 110,
		"cooldown_days": 180,
		"conditions": [
			{"op": Op.TEMP_GTE, "float_value": 22.0},
			{"op": Op.MOISTURE_LTE, "float_value": 0.42},
			{"op": Op.POPULATION_GTE, "int_value": 5},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.TEMP_GTE, "float_value": 28.0},
				"add_weight": 40,
				"multiplier_q16": 98304,
				"reason": "高温",
			},
		],
		"options": [
			{
				"option_id": "relief_and_irrigation",
				"text": "开仓赈济，凿井引水",
				"outcomes": [
					{
						"probability_q16": 65536,
						"outcome_title": "旱情缓解",
						"effects": [
							{
								"kind": Kind.TREASURY_CASH_TO_COHORT,
								"ratio_bp": 400,
								"custom_label": "国库拨付本地人数最多的{primary_profession}，占国库现金 4%",
							},
							{
								"kind": Kind.CITY_MODIFIER,
								"target_key": "economy.city.building.agriculture_output_factor",
								"magnitude_q16": 9830,
								"duration_days": 90,
								"custom_label": "本地农业产出 +15%，90 日",
							},
							{
								# Satisfaction is a country x profession Modifier stat, so
								# this is the definition that carries the basis points.
								# magnitude 1.0 applies the authored value unchanged.
								"kind": Kind.COUNTRY_MODIFIER,
								"target_key": "narrative.relief.agrarian_satisfaction",
								"magnitude_q16": 65536,
								"duration_days": 120,
								"custom_label": "农耕各阶层满意度 +3.5~4，120 日",
							},
						],
					},
				],
			},
			{
				"option_id": "endure_drought",
				"text": "限量配给，待雨复耕",
				"outcomes": [
					{
						"probability_q16": 65536,
						"outcome_title": "人口增长放缓",
						"effects": [
							{
								"kind": Kind.CITY_MODIFIER,
								"target_key": "economy.city.birth_factor.cut",
								"magnitude_q16": 13107,
								"duration_days": 60,
								"custom_label": "本地人口出生率 -20%，60 日",
							},
						],
					},
				],
			},
			{
				"option_id": "divert_upstream_water",
				"text": "凿穿山涧，引水灌田",
				"outcomes": [
					{
						"probability_q16": 42598, # 65%
						"outcome_title": "引水成功",
						"effects": [
							{
								"kind": Kind.CITY_MODIFIER,
								"target_key": "economy.city.building.agriculture_output_factor",
								"magnitude_q16": 16384,
								"duration_days": 120,
								"custom_label": "本地农业产出 +25%，120 日",
							},
						],
					},
					{
						"probability_q16": 22938, # 35%
						"outcome_title": "引水失败",
						"effects": [
							{
								"kind": Kind.ADD_EVENT_WEIGHT_BIAS,
								"tag_key": "unrest",
								"int_value": 0,
								"magnitude_q16": 98304,
								"duration_days": 180,
								"custom_label": "动荡类事件权重 ×1.5，180 日",
							},
						],
					},
				],
			},
		],
	}))

	# 2. 气候：寒潮
	catalog.events.append(NarrativeEventDefinitionScript.from_dict({
		"event_id": "evt.climate.bitter_frost",
		"title": "{settlement_name}·寒潮",
		"body_text": "骤降的强寒潮席卷{settlement_name}，霜冻封锁了水源与交通，燃料与御寒物资的供应骤然紧张。地方官员警告，若不尽快动用储备保障越冬，严寒不仅会令户外生产停摆，更将直接威胁底层民众的生存。",
		"min_era_index": 0,
		"image_key": "climate.weather",
		"ai_visual_prompt": "Snowstorm hitting a settlement in winter, warm bonfires burning in the town square",
		"tags": ["climate", "cold", "winter"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 180,
		"conditions": [
			{"op": Op.TEMP_LTE, "float_value": 2.0},
			{"op": Op.POPULATION_GTE, "int_value": 5},
		],
		"options": [
			{
				"option_id": "distribute_fuel",
				"text": "发放薪柴与御寒物资",
				"outcomes": [
					{
						"probability_q16": 65536,
						"outcome_title": "安然越冬",
						"effects": [
							{
								"kind": Kind.TREASURY_CASH_TO_COHORT,
								"ratio_bp": 300,
								"custom_label": "国库拨付本地人数最多的{primary_profession}，占国库现金 3%",
							},
							{
								"kind": Kind.CITY_MODIFIER,
								"target_key": "family.city.production_boost",
								"magnitude_q16": 72090,
								"duration_days": 75,
								"custom_label": "本地综合生产效率 +2.2%，75 日",
							},
						],
					},
				],
			},
			{
				"option_id": "hunker_down",
				"text": "暂停户外劳作",
				"outcomes": [
					{
						"probability_q16": 65536,
						"outcome_title": "冬季停摆",
						"effects": [
							{
								"kind": Kind.SET_STORY_FLAG,
								"target_key": "flag_winter_hardship",
								"duration_days": 90,
								"custom_label": "标记「凛冬考验」，90 日",
							},
						],
					},
				],
			},
		],
	}))

	# 3. 海洋：上升流渔汛
	catalog.events.append(NarrativeEventDefinitionScript.from_dict({
		"event_id": "evt.ocean.upwelling_bonanza",
		"title": "{settlement_name}·大渔汛",
		"body_text": "冷暖洋流在{settlement_name}近海交汇，带来了罕见的特大渔汛，外海浅滩鱼群密布。地方商贾与渔业团体呼吁立刻组织大规模船队抢捕并扩建加工设施，而海务官员则建议划定轮捕区域，以防竭泽而渔。",
		"min_era_index": 0,
		"image_key": "hydrology.water",
		"ai_visual_prompt": "Abundant coastal fishing fleet hauling overflowing nets in a vibrant bay with ocean currents",
		"tags": ["ocean", "maritime", "prosperity", "harvest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 120,
		"cooldown_days": 200,
		"conditions": [
			{"op": Op.IS_COASTAL, "bool_value": true},
			{"op": Op.POPULATION_GTE, "int_value": 5},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.OCEAN_UPWELLING_GTE, "float_value": 0.15},
				"add_weight": 80,
				"multiplier_q16": 117965,
				"reason": "上升流强",
			},
			{
				"condition": {"op": Op.OCEAN_CURRENT_SPEED_GTE, "float_value": 0.20},
				"add_weight": 40,
				"multiplier_q16": 85197,
				"reason": "洋流活跃",
			},
		],
		"options": [
			{
				"option_id": "organize_fleet_and_salting",
				"text": "组织船队围捕，扩建盐腌场",
				"outcomes": [
					{
						"probability_q16": 65536,
						"outcome_title": "鱼获入库",
						"effects": [
							{
								"kind": Kind.MARKET_ADD_STOCK,
								"target_key": "fish",
								"int_value": 8000,
								"custom_label": "本地市场新增鱼类 8 单位",
							},
							{
								"kind": Kind.COUNTRY_MODIFIER,
								"target_key": "family.country.trade_capacity",
								"magnitude_q16": 65536,
								"duration_days": 120,
								"custom_label": "全国贸易容量 +6%，120 日",
							},
						],
					},
				],
			},
			{
				"option_id": "sustainable_harvest",
				"text": "划定禁渔区，轮捕",
				"outcomes": [
					{
						"probability_q16": 65536,
						"outcome_title": "持续产出",
						"effects": [
							{
								"kind": Kind.CITY_MODIFIER,
								"target_key": "economy.city.building.agriculture_output_factor",
								"magnitude_q16": 7864,
								"duration_days": 180,
								"custom_label": "本地农业产出 +12%，180 日",
							},
						],
					},
				],
			},
		],
	}))

	# 4. 地理：春汛
	catalog.events.append(NarrativeEventDefinitionScript.from_dict({
		"event_id": "evt.geography.river_flood",
		"title": "{settlement_name}·春汛",
		"body_text": "上游融雪引发的春汛正猛烈冲击{settlement_name}沿河地带，低洼农田与渡口设施已遭漫灌。水利官员提出可趁势筑堰导流、引洪淤灌以肥沃来年土壤，但此举伴随堤坝溃决的风险；保守派则主张立刻组织民众撤往高地避险。",
		"min_era_index": 1,
		"image_key": "hydrology.water",
		"ai_visual_prompt": "Swollen river flooding fertile alluvial plains near a settlement, workers building embankments",
		"tags": ["geography", "flood", "agriculture"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 105,
		"cooldown_days": 180,
		"conditions": [
			{"op": Op.HAS_RIVER, "bool_value": true},
			{"op": Op.POPULATION_GTE, "int_value": 5},
		],
		"options": [
			{
				"option_id": "build_levees_and_silt_fields",
				"text": "筑堰导流，引洪淤灌",
				"outcomes": [
					{
						"probability_q16": 45875, # 70%
						"outcome_title": "淤灌成功",
						"effects": [
							{
								"kind": Kind.CITY_MODIFIER,
								"target_key": "economy.city.building.agriculture_output_factor",
								"magnitude_q16": 13107,
								"duration_days": 150,
								"custom_label": "本地农业产出 +20%，150 日",
							},
						],
					},
					{
						"probability_q16": 19661, # 30%
						"outcome_title": "堤坝决口",
						"effects": [
							{
								"kind": Kind.TREASURY_CASH_TO_COHORT,
								"ratio_bp": 300,
								"custom_label": "国库拨付本地人数最多的{primary_profession}，占国库现金 3%",
							},
						],
					},
				],
			},
			{
				"option_id": "evacuate_to_high_ground",
				"text": "撤往高地",
				"outcomes": [
					{
						"probability_q16": 65536,
						"outcome_title": "人员无损",
						"effects": [
							{
								"kind": Kind.CITY_MODIFIER,
								"target_key": "family.city.production_boost",
								"magnitude_q16": 68813,
								"duration_days": 45,
								"custom_label": "本地综合生产效率 +2.1%，45 日",
							},
						],
					},
				],
			},
		],
	}))

	# 5. 市场：物资短缺
	catalog.events.append(NarrativeEventDefinitionScript.from_dict({
		"event_id": "evt.market.grain_panic",
		"title": "{settlement_name}·物资短缺",
		"body_text": "{settlement_name}的市场上爆发了针对{good_name}的恐慌性抢购，货源告急且报价连日剧烈波动。囤积与争执已在各大市集蔓延，财政部门建议由国库出资平准补贴，商会则主张放开价格管制以高价吸引外地货源。",
		"min_era_index": 1,
		"image_key": "country.economy",
		"ai_visual_prompt": "Bustling historical marketplace with merchants arguing over grain sacks and price boards",
		"tags": ["market", "commerce", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 115,
		"cooldown_days": 150,
		"conditions": [
			{"op": Op.MARKET_GOOD_SHORTAGE},
			{"op": Op.POPULATION_GTE, "int_value": 8},
		],
		"options": [
			{
				"option_id": "stabilize_market_by_subsidy",
				"text": "平准补贴，整顿市场",
				"outcomes": [
					{
						"probability_q16": 65536,
						"outcome_title": "价格回落",
						"effects": [
							{
								"kind": Kind.TREASURY_CASH_TO_COHORT,
								"ratio_bp": 350,
								"custom_label": "国库拨付本地人数最多的{primary_profession}，占国库现金 3.5%",
							},
							{
								"kind": Kind.CITY_MODIFIER,
								"target_key": "family.city.production_boost",
								"magnitude_q16": 72090,
								"duration_days": 60,
								"custom_label": "本地综合生产效率 +2.2%，60 日",
							},
						],
					},
				],
			},
			{
				"option_id": "free_market_arbitrage",
				"text": "高价招引外地行商",
				"outcomes": [
					{
						"probability_q16": 45875, # 70%
						"outcome_title": "商队入市",
						"effects": [
							{
								"kind": Kind.COHORT_CASH_TO_TREASURY,
								"ratio_bp": 250,
								"custom_label": "向本地人数最多的{primary_profession}征收其现金的 2.5%",
							},
							{
								"kind": Kind.COUNTRY_MODIFIER,
								"target_key": "family.country.trade_capacity",
								"magnitude_q16": 65536,
								"duration_days": 90,
								"custom_label": "全国贸易容量 +6%，90 日",
							},
						],
					},
					{
						"probability_q16": 19661, # 30%
						"outcome_title": "商路未通",
						"effects": [
							{
								"kind": Kind.ADD_EVENT_WEIGHT_BIAS,
								"tag_key": "unrest",
								"int_value": 0,
								"magnitude_q16": 91750,
								"duration_days": 120,
								"custom_label": "动荡类事件权重 ×1.4，120 日",
							},
						],
					},
				],
			},
		],
	}))

	# 6. 工业：工匠改良
	catalog.events.append(NarrativeEventDefinitionScript.from_dict({
		"event_id": "evt.industry.artisan_innovation",
		"title": "{settlement_name}·工匠改良",
		"body_text": "{settlement_name}的工坊在工具成型与冶锻工艺上取得突破，借由新型夹具大幅降低了废料损耗并提升了出品精度。工务部门主张嘉奖发明者并向全城推广新法，财政官吏则看中其中的丰厚利差，提议收归官办专营。",
		"min_era_index": 2,
		"image_key": "map.construction",
		"ai_visual_prompt": "Master craftsmen in a historical workshop demonstrating a new tool jig and pulley mechanism",
		"tags": ["industry", "innovation", "prosperity"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 210,
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
			{"op": Op.POPULATION_GTE, "int_value": 10},
		],
		"options": [
			{
				"option_id": "sponsor_workshop_trial",
				"text": "赏赐匠人，推广新法",
				"outcomes": [
					{
						"probability_q16": 65536,
						"outcome_title": "新法推广",
						"effects": [
							{
								"kind": Kind.TREASURY_CASH_TO_COHORT,
								"ratio_bp": 200,
								"custom_label": "国库拨付本地人数最多的{primary_profession}，占国库现金 2%",
							},
							{
								"kind": Kind.CITY_MODIFIER,
								"target_key": "economy.city.building.manufacturing_output_factor",
								"magnitude_q16": 13107,
								"duration_days": 150,
								"custom_label": "本地制造产出 +20%，150 日",
							},
							{
								"kind": Kind.CITY_MODIFIER,
								"target_key": "economy.city.building.knowledge_output_factor",
								"magnitude_q16": 9830,
								"duration_days": 150,
								"custom_label": "本地知识产出 +15%，150 日",
							},
						],
					},
				],
			},
			{
				"option_id": "keep_craft_secret",
				"text": "列为官办专营",
				"outcomes": [
					{
						"probability_q16": 65536,
						"outcome_title": "专营收益入库",
						"effects": [
							{
								"kind": Kind.COHORT_CASH_TO_TREASURY,
								"ratio_bp": 300,
								"custom_label": "向本地人数最多的{primary_profession}征收其现金的 3%",
							},
						],
					},
				],
			},
		],
	}))

	# 7. 社会：民生请愿
	catalog.events.append(NarrativeEventDefinitionScript.from_dict({
		"event_id": "evt.society.livelihood_petition",
		"title": "{settlement_name}·民生请愿",
		"body_text": "{settlement_name}的生计压力已触及临界点，大批居民聚集在地方官署门前递交联名请愿，控诉赋役沉重、生计难以为继。虽然人群尚且克制，但地方治安部门警告，若不尽快在扶持民生与严明法度之间做出决断，怨气恐将演变为更大规模的骚乱。",
		"min_era_index": 1,
		"image_key": "family.house",
		"ai_visual_prompt": "Town elders and workers presenting a scroll petition at the steps of a civic hall",
		"tags": ["society", "unrest", "livelihood"],
		"trigger_channel": Ch.FACT_DRIVEN,
		"fact_event_type": 8, # GameplayEventBus.EVENT_ECONOMY_SOCIAL_PRESSURE
		"base_weight": 130,
		"trigger_chance_q16": 45875,
		"cooldown_days": 150,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 5},
		],
		"options": [
			{
				"option_id": "accept_petition_and_aid",
				"text": "拨款扶持当地营生",
				"outcomes": [
					{
						"probability_q16": 65536,
						"outcome_title": "民心平复",
						"effects": [
							{
								"kind": Kind.TREASURY_CASH_TO_COHORT,
								"ratio_bp": 350,
								"custom_label": "国库拨付本地人数最多的{primary_profession}，占国库现金 3.5%",
							},
							{
								"kind": Kind.CITY_MODIFIER,
								"target_key": "economy.city.building.manufacturing_output_factor",
								"magnitude_q16": 1311,
								"duration_days": 90,
								"custom_label": "本地制造产出 +2%，90 日",
							},
						],
					},
				],
			},
			{
				"option_id": "enforce_order",
				"text": "申明法度，照常劳作",
				"outcomes": [
					{
						"probability_q16": 65536,
						"outcome_title": "请愿平息",
						"effects": [
							{
								"kind": Kind.SET_STORY_FLAG,
								"target_key": "flag_unrest_simmering",
								"duration_days": 120,
								"custom_label": "标记「暗流涌动」，120 日",
							},
						],
					},
				],
			},
		],
	}))

	# 8. 事件链 1/3：矿脉露头
	catalog.events.append(NarrativeEventDefinitionScript.from_dict({
		"event_id": "evt.chain.strange_outcrop",
		"title": "{settlement_name}·矿脉露头（1/3）",
		"body_text": "工程队在{settlement_name}周边的{landform_name}断崖作业时，意外发现了质地致密、纹路奇特的富矿露头。矿务官吏查验样品后判断地底极可能蕴藏大型矿脉，建议拨款组建专业勘探队深掘，而保守派则倾向于仅开采地表以规避风险。",
		"min_era_index": 2,
		"image_key": "economy.resource",
		"ai_visual_prompt": "Ancient prospectors discovering a glowing metallic ore vein on a rocky cliffside",
		"tags": ["chain", "prospecting", "discovery", "extractive"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 110,
		"cooldown_days": 360,
		"one_shot": true,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 5},
		],
		"on_trigger_effects": [
			{
				"kind": Kind.ADD_EVENT_WEIGHT_BIAS,
				"tag_key": "prospecting",
				"int_value": 0,
				"magnitude_q16": 98304,
				"duration_days": 365,
				"custom_label": "勘探类事件权重 ×1.5，365 日",
			},
		],
		"options": [
			{
				"option_id": "fund_deep_expedition",
				"text": "组建勘探队，向地底深掘",
				"outcomes": [
					{
						"probability_q16": 65536,
						"outcome_title": "勘探队入洞",
						"effects": [
							{
								"kind": Kind.TREASURY_CASH_TO_COHORT,
								"ratio_bp": 250,
								"custom_label": "国库拨付本地人数最多的{primary_profession}，占国库现金 2.5%",
							},
							{
								"kind": Kind.SET_STORY_FLAG,
								"target_key": "flag_deep_prospecting",
								"duration_days": 365,
								"scope_to_cell": false,
								"custom_label": "标记「深层勘探」，365 日",
							},
							{
								"kind": Kind.SCHEDULE_FOLLOWUP_EVENT,
								"target_key": "evt.chain.subterranean_cavern",
								"tag_key": "chain_strange_outcrop",
								"duration_days": 15,
								"custom_label": "15 日后触发「地底矿洞」",
							},
						],
					},
				],
			},
			{
				"option_id": "surface_strip_mining",
				"text": "仅采地表露头",
				"outcomes": [
					{
						"probability_q16": 65536,
						"outcome_title": "浅层开采",
						"effects": [
							{
								"kind": Kind.CITY_MODIFIER,
								"target_key": "economy.city.building.extractive_output_factor",
								"magnitude_q16": 9830,
								"duration_days": 90,
								"custom_label": "本地采掘产出 +15%，90 日",
							},
						],
					},
				],
			},
		],
	}))

	# 9. 事件链 2/3：地底矿洞
	catalog.events.append(NarrativeEventDefinitionScript.from_dict({
		"event_id": "evt.chain.subterranean_cavern",
		"title": "{settlement_name}·地底矿洞（2/3）",
		"body_text": "深层勘探队掘穿岩壁后，在{settlement_name}地底发现了一处规模惊人的天然溶洞，一条奔涌的暗河旁裸露着成片高品位矿脉。工务官员主张立刻引暗河水力就地兴建冶炼工坊，而学者团则呼吁先全面测绘地质与水文结构。",
		"image_key": "economy.resource",
		"ai_visual_prompt": "Underground cavern with glowing mineral veins and a subterranean river, ancient miners holding torches",
		"tags": ["chain", "prospecting", "discovery", "extractive"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 150,
		"cooldown_days": 360,
		"one_shot": true,
		"required_events_completed": ["evt.chain.strange_outcrop"],
		"required_story_flags": ["flag_deep_prospecting"],
		"options": [
			{
				"option_id": "build_underground_waterwheel_foundry",
				"text": "引暗河水力建工坊，开发富矿",
				"outcomes": [
					{
						"probability_q16": 52429, # 80%
						"outcome_title": "水力工坊建成",
						"effects": [
							{
								"kind": Kind.CITY_MODIFIER,
								"target_key": "economy.city.building.extractive_output_factor",
								"magnitude_q16": 16384,
								"duration_days": 180,
								"custom_label": "本地采掘产出 +25%，180 日",
							},
							{
								"kind": Kind.SET_STORY_FLAG,
								"target_key": "flag_cavern_mastered",
								"duration_days": 365,
								"scope_to_cell": false,
								"custom_label": "标记「暗河工坊建成」，365 日",
							},
							{
								"kind": Kind.SCHEDULE_FOLLOWUP_EVENT,
								"target_key": "evt.chain.ancient_foundry_legacy",
								"tag_key": "chain_strange_outcrop",
								"duration_days": 15,
								"custom_label": "15 日后触发「矿冶重镇」",
							},
						],
					},
					{
						"probability_q16": 13107, # 20%
						"outcome_title": "工程延期",
						"effects": [
							{
								"kind": Kind.CITY_MODIFIER,
								"target_key": "economy.city.building.extractive_output_factor",
								"magnitude_q16": 9830,
								"duration_days": 120,
								"custom_label": "本地采掘产出 +15%，120 日",
							},
						],
					},
				],
			},
			{
				"option_id": "scholar_study_minerals",
				"text": "召学者测绘地质水文",
				"outcomes": [
					{
						"probability_q16": 65536,
						"outcome_title": "测绘完成",
						"effects": [
							{
								"kind": Kind.COUNTRY_MODIFIER,
								"target_key": "ideology.country.output.knowledge_factor.gain",
								"magnitude_q16": 9830,
								"duration_days": 180,
								"custom_label": "全国知识部门产出 +15%，180 日",
							},
						],
					},
				],
			},
		],
	}))

	# 10. 事件链 3/3：矿冶重镇
	catalog.events.append(NarrativeEventDefinitionScript.from_dict({
		"event_id": "evt.chain.ancient_foundry_legacy",
		"title": "{settlement_name}·矿冶重镇（3/3）",
		"body_text": "随着暗河水力工坊全面投产，{settlement_name}的采掘与冶炼产能实现了跨越式增长，源源不断的矿石与金属制品正输往全国。这座曾经偏僻的聚落已然崛起为名副其实的矿冶枢纽，堪称我国工业与工程史上的典范。",
		"image_key": "map.construction",
		"ai_visual_prompt": "Grand prosperous foundry town with waterwheels, glowing furnaces and trade caravans",
		"tags": ["chain", "prospecting", "industry", "prosperity"],
		"trigger_channel": Ch.SCHEDULED_ONLY,
		"base_weight": 200,
		"cooldown_days": 365,
		"one_shot": true,
		"required_events_completed": ["evt.chain.subterranean_cavern"],
		"options": [
			{
				"option_id": "proclaim_national_foundry_hub",
				"text": "定为矿冶示范重镇",
				"outcomes": [
					{
						"probability_q16": 65536,
						"outcome_title": "矿冶重镇",
						"effects": [
							{
								"kind": Kind.CITY_MODIFIER,
								"target_key": "economy.city.building.manufacturing_output_factor",
								"magnitude_q16": 16384,
								"duration_days": 365,
								"custom_label": "本地制造产出 +25%，365 日",
							},
							{
								"kind": Kind.COUNTRY_MODIFIER,
								"target_key": "ideology.country.output.extractive_factor.gain",
								"magnitude_q16": 9830,
								"duration_days": 365,
								"custom_label": "全国采掘部门产出 +15%，365 日",
							},
						],
					},
				],
			},
		],
	}))

	# 11. 水利工程链（渠议 → 渠成 / 中辍 → 渠田连岁）
	# 架空世界内的地方志式内容；写法说明见 narrative_event_catalog_waterworks.gd 文件头。
	NarrativeEventCatalogWaterworksScript.append_waterworks_events(catalog)

	# 12. 「地块上的人」事件包（饥民叩关 → 粥棚之后）
	# 使用人群条件（入不敷出/失业/职业占比）与「国库→贫户」守恒转账。
	NarrativeEventCatalogPeopleScript.append_people_events(catalog)

	# 13. 主题事件网（8 个内容包，见 narrative_event_registry.gd）
	# 注册顺序即抽样顺序：先局势（宫廷/边镇/信仰），再产业（财政/工业），最后风物（高时代/人与家/地块）。
	NarrativeEventRegistryScript.append_all(catalog)

	catalog.rebuild_index()
	return catalog
