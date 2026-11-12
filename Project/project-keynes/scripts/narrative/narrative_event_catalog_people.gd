class_name NarrativeEventCatalogPeople
extends RefCounted

## 「地块上的人」事件包：让玩家的决定落到具体的人身上。
##
## 与水利链的分工：
##   waterworks 写「一件事如何改变一个地方」（工程、工期、长尾）；
##   people     写「一群人在这一刻怎么活」（饥荒、安置、怨气）。
##
## 这一包用到的人群杠杆（见 narrative_context_sampler / narrative_condition）：
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
		"body_text": "城门外聚了几百个人。脸是黄的，眼睛陷进去，站都站不直。他们说是从下游来的，井干了，东家也跑了，一路走到这里。守门的兵把门闩上，不敢开，也不敢赶。城墙上的人往下看，谁都没说话。王顺在门洞底下站了很久，手里的册子翻来翻去，一页也没写。他把册子合上，又翻开，笔尖在纸上洇出一个点，还是没落下去。",
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
				"text": "开仓，在西门设粥棚",
				"outcomes": [
					{
						"probability_q16": 65536,
						"outcome_title": "粥棚立起来",
						"outcome_narrative": "官仓的粮车进了城，市上的粮行重新开了门。西门的粥棚是几家铺子凑起来的，队伍从城门排到河埠。第七天，队伍里少了几张脸，王顺没问他们去了哪里。",
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
				"text": "雇本地人修堤，按日发钱",
				"outcomes": [
					{
						"probability_q16": 65536,
						"outcome_title": "工钱按日发",
						"outcome_narrative": "官府雇了城里的人去修旧堤，工钱当天结算。城外的饥民隔着河看，有人问要不要短工，工头说人数够了。",
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
				"text": "关门，把人赶走",
				"outcomes": [
					{
						"probability_q16": 42598, # 65%
						"outcome_title": "人群散了",
						"outcome_narrative": "人群在城下站到天黑，慢慢散了。城门再开的时候，官道边上多了几座新坟。王顺让人去问是谁家的，问了一圈，没人知道。",
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
						"outcome_title": "三更的砸门声",
						"outcome_narrative": "三更，城外有人砸了粮行的门。守兵点了火把，天亮时才把人群赶过河。河面上漂着几块木板，是粮行的门板。",
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
		"body_text": "粥棚撤了。活下来的人在城外搭起棚屋，用捡来的木板和破席。城门吏王顺捧着两本册子来找你：一本记流民，一本记新户。两本都还空着。他说，这些人有手艺，也有力气，就缺一个名分。王顺把册子往前递了递，纸边卷着。说完他站着没走，等你回话。",
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
				"text": "给他们上户籍，分田",
				"outcomes": [
					{
						"probability_q16": 65536,
						"outcome_title": "他们有了户籍",
						"outcome_narrative": "棚屋换成了土墙房，孩子被记进新册。秋后，这批人缴了第一回租；城里的老户在背后叫他们「粥棚户」。王顺听见了，没管。",
						"effects": [
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
				"text": "遣返原籍，不设户籍",
				"outcomes": [
					{
						"probability_q16": 65536,
						"outcome_title": "车把他们送走",
						"outcome_narrative": "官车把他们送回下游。有人到家时，村里的井已经重新淘过；也有人在半路留下来，没人再记得他的名字。王顺把两本册子都收起来，第二年又拿出来用。",
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
