class_name NarrativeEventCatalogPeople
extends RefCounted

## 「地块上的人」事件包：让玩家的决定落到具体的人身上。
##
## 与水利链的分工：
##   waterworks 写「一件事如何改变一个地方」（工程、工期、长尾）；
##   people     写「一群人在这一刻怎么活」（饥荒、安置、怨气）。
##
## 这一包用到的人群杠杆（后台见 native_simulation_host_narrative.cpp 与 runtime_narrative.cpp）：
##   SUBSISTENCE_SHORTFALL_GTE  严重入不敷出人口占比（生计覆盖率 < 0.5，且非全员失业）
##   UNEMPLOYMENT_GTE           失业人口占比
##   PROFESSION_SHARE_GTE       某职业人口占比（target_key = 职业 stable id）
##   COHORT_SATISFACTION_LTE    最不满那一群的满意度
##   TREASURY_CASH_TO_COHORT    国库 → 本地人数最多的那一群；标签用 {primary_profession} 写清职业
##   MARKET_ADD_STOCK           本地市场增补库存（官府调拨；确定发生、无来源——
##                              不要用 COUNTRY_GOOD_TO_MARKET：玩家无法收购物资，国库通常没有存粮）
##
## 文本笔法：写场景，不写摘要；具体的名字与物件；不要「某某说：『……』」的引语块；
## 结尾落在一个画面上。

const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")
const NarrativeEffectSpecScript = preload("res://scripts/narrative/narrative_effect_spec.gd")

const EVENT_HUNGRY := &"evt.people.hungry_crowd"
const EVENT_AFTERMATH := &"evt.people.gruel_aftermath"

const FLAG_GRUEL := &"flag_gruel_kitchen"
const FLAG_RELIEF_WORKS := &"flag_relief_works"
const FLAG_REFUSED := &"flag_hungry_refused"

const MUL_130 := 85197
const MUL_150 := 98304

static func _pct(percent: float) -> int:
	return int(round(percent * 65536.0 / 100.0))


static func append_people_events(catalog) -> void:
	if catalog == null:
		return
	var Op = NarrativeConditionScript.Op
	var Kind = NarrativeEffectSpecScript.Kind
	var Ch = NarrativeEventDefinitionScript.TriggerChannel

	# ═══ 城门外的人 ═══════════════════════════════════════════════════════
	# 触发不是「气候干旱」，而是人真的活不下去：该格严重入不敷出的人口占到一定比例。
	# 权重继续吃失业、粮价与最不满那一群的满意度——同一场饥荒，越惨越容易弹出。
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(EVENT_HUNGRY),
		"title": "{settlement_name}·城门外的人",
		"body_text": "大批因生计断绝而逃荒的流民聚集在{settlement_name}城门外，形销骨立，恳求官府开仓济困。城防守备紧闭城门不敢轻放，担忧骤增的饥民冲垮本就吃紧的治安与口粮储备。地方官署紧急呈报三策：由官府调拨存粮入市并设点施赈、动用国库资金雇佣本地居民以工代赈修筑堤防，抑或干脆闭门驱离流民，将动荡风险挡在城墙之外。",
		"image_key": "family.house",
		"ai_visual_prompt": "Hungry rural families waiting outside the mud walls of an ancient town gate at dusk",
		"tags": ["society", "famine", "unrest", "people"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 120,
		"cooldown_days": 240,
		"one_shot": false,
		"conditions": [
			# 干着活却连一半开销都盖不住的人占到一成半：这才叫饥荒，不是「月末手紧」。
			{"op": Op.SUBSISTENCE_SHORTFALL_GTE, "float_value": 0.15},
			{"op": Op.POPULATION_GTE, "int_value": 8},
			# 官仓调拨要落到本地市场，市场必须有商人（原生 ADD_STOCK 无商人会整批拒绝）。
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.001},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.UNEMPLOYMENT_GTE, "float_value": 0.15},
				"add_weight": 40,
				"multiplier_q16": MUL_130,
				"reason": "城里也没活干",
			},
			{
				"condition": {
					"op": Op.MARKET_GOOD_PRICE_RATIO_GTE,
					"target_key": "wheat_grain",
					"float_value": 1.25,
				},
				"add_weight": 50,
				"reason": "粮价高，赈济也买不起",
			},
			{
				"condition": {"op": Op.COHORT_SATISFACTION_LTE, "float_value": 0.40},
				"add_weight": 30,
				"reason": "最穷的一群已经在闹",
			},
		],
		"options": [
			{
				"option_id": "open_the_granary",
				"text": "调粮入市，西门设粥棚",
				"outcomes": [
					{
						"probability_q16": 65536,
						"outcome_title": "开仓赈济秩序暂稳",
						"outcome_narrative": "官府调拨的小麦迅速注入本地市场，城外随即支起粥棚按日施赈。汹涌的饥民情绪得以安抚，然如何善后安置这批流民很快将成为新的考验。",
						"effects": [
							{
								"kind": Kind.MARKET_ADD_STOCK,
								"target_key": "wheat_grain",
								"int_value": 300000,
								"custom_label": "本地市场增补小麦 300 单位（官府调拨）",
							},
							{
								"kind": Kind.SET_STORY_FLAG,
								"target_key": String(FLAG_GRUEL),
								"duration_days": 365,
								"custom_label": "标记「粥棚已设」",
							},
							{
								"kind": Kind.SCHEDULE_FOLLOWUP_EVENT,
								"target_key": String(EVENT_AFTERMATH),
								"tag_key": "chain_people",
								"duration_days": 45,
								"custom_label": "45 日后「粥棚撤了」",
							},
						],
					},
				],
			},
			{
				"option_id": "relief_through_works",
				"text": "拨款以工代赈，修筑旧堤",
				"outcomes": [
					{
						"probability_q16": 65536,
						"outcome_title": "工赈并行农防加固",
						"outcome_narrative": "国库拨出专款雇佣本地居民修筑水利堤防，工钱按日结算。城内生计得以稳固、农田防洪大有改观，唯城外流民仍待后续处置。",
						"effects": [
							{
								"kind": Kind.TREASURY_CASH_TO_COHORT,
								"ratio_bp": 250,
								"custom_label": "国库拨付本地人数最多的{primary_profession}作工钱，占国库现金 2.5%",
							},
							{
								"kind": Kind.CITY_MODIFIER,
								"target_key": "economy.city.building.agriculture_output_factor",
								"magnitude_q16": _pct(4),
								"duration_days": 360,
								"custom_label": "本地农业 +4%，360 日",
							},
							{
								"kind": Kind.SET_STORY_FLAG,
								"target_key": String(FLAG_RELIEF_WORKS),
								"duration_days": 365,
								"custom_label": "标记「以工代赈」",
							},
							{
								"kind": Kind.SCHEDULE_FOLLOWUP_EVENT,
								"target_key": String(EVENT_AFTERMATH),
								"tag_key": "chain_people",
								"duration_days": 60,
								"custom_label": "60 日后「粥棚撤了」",
							},
						],
					},
				],
			},
			{
				"option_id": "bar_the_gate",
				"text": "紧闭城门，强行驱离",
				"outcomes": [
					{
						"probability_q16": 42598, # 65%
						"outcome_title": "闭门驱散怨气暗涌",
						"outcome_narrative": "城防守备严阵以待，绝望的流民在城下滞留至夜方才四散离去。城内虽免于一时粮耗，但沿途饿殍与冷酷政令令地方动荡风险显著上升。",
						"effects": [
							{
								"kind": Kind.SET_STORY_FLAG,
								"target_key": String(FLAG_REFUSED),
								"duration_days": 365,
								"custom_label": "标记「闭门不纳」",
							},
							{
								"kind": Kind.ADD_EVENT_WEIGHT_BIAS,
								"tag_key": "unrest",
								"int_value": 0,
								"magnitude_q16": MUL_130,
								"duration_days": 240,
								"custom_label": "动荡类事件权重 ×1.3，240 日",
							},
						],
					},
					{
						"probability_q16": 22938, # 35%
						"outcome_title": "饥民夜哗粮行遭劫",
						"outcome_narrative": "走投无路的饥民于深夜砸毁城外粮行哄抢存粮，守军苦战至拂晓方将人群驱过河去。农商秩序深受波及，全境动荡危机骤然加剧。",
						"effects": [
							{
								"kind": Kind.CITY_MODIFIER,
								"target_key": "economy.city.building.agriculture_output_factor.cut",
								"magnitude_q16": _pct(8),
								"duration_days": 180,
								"custom_label": "本地农业 -8%，180 日",
							},
							{
								"kind": Kind.ADD_EVENT_WEIGHT_BIAS,
								"tag_key": "unrest",
								"int_value": 0,
								"magnitude_q16": MUL_150,
								"duration_days": 240,
								"custom_label": "动荡类事件权重 ×1.5，240 日",
							},
						],
					},
				],
			},
		],
	}))

	# ═══ 粥棚撤了 ═════════════════════════════════════════════════════════
	# 赈济不是句号。活下来的人要一个名分：上户籍分田（长期产能，但本地人忌惮）
	# 还是发路费送回原籍（省钱、无后续，但也没有新户）。这一步让玩家为「仁政」付第二次账。
	#
	# 两路善后共用这一幕：来源由排程区分，不能再写 required_story_flags——
	# 该字段是 AND 语义（两个标记都要有），而这里需要的是 OR。
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(EVENT_AFTERMATH),
		"title": "{settlement_name}·粥棚撤了",
		"body_text": "紧急赈济告一段落，活下来的流民已在{settlement_name}城郊搭起成片棚屋，短期内不愿散去。地方官署呈上空白的流民遣返册与新户编籍册请示裁断，若将其正式编入户籍并分授荒田，可为本地补充宝贵的青壮劳力，但势必招致本地旧户的排斥与摩擦。若由官府押送遣返原籍，则虽可省去治理隐忧，却也白白流失这批现成的人手。",
		"image_key": "family.house",
		"ai_visual_prompt": "Makeshift huts outside an ancient town wall, officials registering families with bamboo scrolls",
		"tags": ["society", "people", "settlement", "chain"],
		"trigger_channel": Ch.SCHEDULED_ONLY,
		"base_weight": 180,
		"cooldown_days": 30,
		"one_shot": true,
		"options": [
			{
				"option_id": "register_as_tenants",
				"text": "编入户籍，分田安置",
				"outcomes": [
					{
						"probability_q16": 65536,
						"outcome_title": "流民落籍新旧磨合",
						"outcome_narrative": "大批流民正式入籍领田，简陋棚屋陆续改建为定居房舍，本地人口与农业产出同步增长。然旧户对新附移民颇存芥蒂，基层摩擦有所抬头。",
						"effects": [
							{
								"kind": Kind.ADD_POPULATION,
								"ratio_bp": 1200, # +12%：册上真多了人，当天就要吃饭
								"duration_days": 1,
								"custom_label": "本地人口 +12%（流民编入户籍）",
							},
							{
								"kind": Kind.CITY_MODIFIER,
								"target_key": "economy.city.building.agriculture_output_factor",
								"magnitude_q16": _pct(5),
								"duration_days": 540,
								"custom_label": "本地农业 +5%，540 日",
							},
							{
								"kind": Kind.ADD_EVENT_WEIGHT_BIAS,
								"tag_key": "unrest",
								"int_value": 0,
								"magnitude_q16": 75366, # 1.15x
								"duration_days": 180,
								"custom_label": "动荡类事件权重 ×1.15，180 日",
							},
						],
					},
				],
			},
			{
				"option_id": "send_them_home",
				"text": "押送遣返，不予入籍",
				"outcomes": [
					{
						"probability_q16": 65536,
						"outcome_title": "流民遣散劳力外流",
						"outcome_narrative": "官署组织车队将城外流民悉数遣返原籍，棚区随之清空。此举避免了新旧户籍之争，却也令本地错失劳力补充，短期农事略显人手不足。",
						"effects": [
							{
								"kind": Kind.CITY_MODIFIER,
								"target_key": "economy.city.building.agriculture_output_factor.cut",
								"magnitude_q16": _pct(2),
								"duration_days": 180,
								"custom_label": "本地农业 -2%，180 日（少了一批人手）",
							},
							{
								"kind": Kind.CLEAR_STORY_FLAG,
								"target_key": String(FLAG_GRUEL),
								"custom_label": "清除标记「粥棚已设」",
							},
						],
					},
				],
			},
		],
	}))
