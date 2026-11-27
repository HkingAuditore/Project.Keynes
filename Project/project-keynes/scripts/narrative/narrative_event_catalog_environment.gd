extends RefCounted

## Environmental entries in the default narrative catalog, in their sampling order.

const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")
const NarrativeEffectSpecScript = preload("res://scripts/narrative/narrative_effect_spec.gd")


static func append(catalog) -> void:
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
