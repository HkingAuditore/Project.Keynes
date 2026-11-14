class_name NarrativeEventCatalog
extends Resource

## 默认事件库。所有玩家可见文本只写事实与数值：
## 标题 = 地点·事件，正文 ≤ 2 句（触发条件），选项 = 动作，结果 = 后果，
## 效果标签 = 对象 + 幅度 + 时长。不写场景、修辞、感叹与人物对白。

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
		"body_text": "一个多月没下透雨，田里的土裂成一块一块，脚踩上去发脆。村口的水塘见了底，塘底的泥上留着几道鱼印。里正蹲在田埂上，把一棵旱死的苗连根拔起来，根上没带土。",
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
		"body_text": "夜里起了北风，天亮时草叶上全是白霜。井台结了一层薄冰，打水的人先用石头把冰砸开。街上卖炭的车还没进城，柴铺门口已经排了人，有人把身上的旧袄又裹紧一层。",
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
		"body_text": "海面上起了一层细密的泡，水色比往常深。老渔人把船撑到外海的浅滩，看见水里黑压压一片，鱼群挤着往上游。他回头朝岸上喊了一声，声音被风刮散，岸上的人只看见他挥手。",
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
		"body_text": "上游的雪化了，河水一天涨一尺。渡口的木桩先被淹了，接着是低处的田。水退下去以后，田里盖了一层黄泥，踩上去陷到脚踝。老农蹲下去抓了一把泥，说这泥肥，可今年的苗没了。",
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
		"body_text": "粮行的门开得比往常早，队伍已经排到街角。{good_name}的价牌一天换两回，掌柜说仓库里也没多少了。有人一次买走三袋，后面的人伸手去拦，被伙计挡开。",
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
		"body_text": "老匠把凿子的角度改了改，又用一块硬木做了个卡子，把料卡住。同样的铁，他多打出一把锄头，刃口还更直。徒弟在旁边看，学着做了第二个卡子，做得歪，老匠没骂，拿过来重新削。",
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
		"body_text": "二十来个人堵在衙门口，为首的手里捧着一只空碗。碗里没有粮，碗底沾着几粒去年的陈米。韦顺出来问话，人群里有人说，税再这么收，锅就揭不开了。后面的人跟着应，声音不高，也没人往前挤。",
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
		"body_text": "民夫在{landform_name}的断崖下歇脚，有人拿石块敲着玩，敲下一块发绿的石头。石头上有一道一道的纹，压手。领工的接过去看了看，又敲了两下，把石头揣进怀里，让民夫把这一段崖壁都清出来。",
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
		"body_text": "凿到第七天，岩壁透了，一股凉风从缝里出来。火把伸进去，照见一条暗河，水声在洞子里转。河边的石壁上全是黑亮的矿脉，有人伸手去摸，被领队的喝住。",
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
		"body_text": "水渠引到坡下，木轮带着风箱一进一出，炉火比从前旺。矿石从地底一筐一筐运上来，倒进炉口，铁水顺着槽流进范里。老匠用铁钩拨了拨浮渣，说这一炉能出三件家伙。",
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
