class_name NarrativeEventCatalogFamily3
extends RefCounted

## 家族桥第二批：十二条。
##
## A 层（6 条，现有桥）：乳母、祠堂、牌坊、包税、族丁、义庄——族与官府的交易。
## B 层（6 条，读既有特质）：重农族、商帮、工匠族、书香门第、家大业大、沿海资本——
##   “这个族本来是什么，所以这件事只能这样办”。
##
## 约束：一条只改一个特质；三个选项代价货币不同；门槛至少一个家族维度 + 一个非家族维度；
## 撤特质只用于“这个族不再是原来的族”，不做惩罚性撤销。

const Ids = preload("res://scripts/narrative/narrative_event_ids.gd")
const Shared = preload("res://scripts/narrative/narrative_event_shared.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")
const NarrativeEffectSpecScript = preload("res://scripts/narrative/narrative_effect_spec.gd")

const TraitEvents = preload("res://scripts/narrative/narrative_event_catalog_family3_traits.gd")
const TraitChanges = preload("res://scripts/narrative/narrative_event_family_trait_changes.gd")

const PACK_ID := &"family3"
const PREFIX := "evt.family3."

const CAST := [
	"周敬之", "周朴", "李七", "李潮", "韩仓", "韦顺", "罗阿石", "柳嫂", "邬三", "常五",
	"苗大", "葛六", "石宝", "西街", "南门", "祠堂", "族仓", "船行", "行会",
]

const MUL_110 := 72090
const MUL_115 := 75366
const MUL_120 := 78643
const MUL_125 := 81920
const MUL_130 := 85197
const MUL_135 := 88474


static func meta() -> Dictionary:
	return {
		"id": PACK_ID,
		"title": "家族桥（二）",
		"theme": "族本来是什么，事情就只能怎么办",
		"era_band": "1-9",
		"prefix": PREFIX,
		"scale": "12 条中观/微观孤立",
		"cast": CAST,
		"node_ids": [
			String(Ids.EVT_FAMILY3_WET_NURSE),
			String(Ids.EVT_FAMILY3_ANCESTRAL_HALL),
			String(Ids.EVT_FAMILY3_SCHOLAR_BOARD),
			String(Ids.EVT_FAMILY3_TAX_FARM),
			String(Ids.EVT_FAMILY3_PRIVATE_ARM),
			String(Ids.EVT_FAMILY3_CHARITY_ESTATE),
			String(Ids.EVT_FAMILY3_ENCLOSURE_RESIST),
			String(Ids.EVT_FAMILY3_CHARTER_GUILD),
			String(Ids.EVT_FAMILY3_CRAFT_SPLIT),
			String(Ids.EVT_FAMILY3_LETTERS_RAID),
			String(Ids.EVT_FAMILY3_MAGNATE_TAX),
			String(Ids.EVT_FAMILY3_COASTAL_SHIFT),
		],
	}


static func append(catalog) -> void:
	if catalog == null:
		return
	var Op = NarrativeConditionScript.Op
	var Ch = NarrativeEventDefinitionScript.TriggerChannel

	# ═══ 乳母（A）════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY3_WET_NURSE),
		"title": "{settlement_name}·乳母",
		"body_text": "周敬之的孙子是柳嫂的奶喂大的。柳嫂的丈夫死在河工上，她带着一个儿子在城西住。如今周家要把孩子接回正屋，柳嫂来讨一个说法：孩子认不认她这门亲。韦顺说按规矩，奶妈不算亲眷；李七说城里人都看着。柳嫂站在祠堂门口，手里拎着一只布包，包的是孩子小时候穿的虎头鞋。周敬之没让她进门，也没让她走。",
		"image_key": "family.house",
		"ai_visual_prompt": "A wet nurse at a clan hall door holding a cloth bundle of tiny tiger-head shoes, an elder hesitating inside",
		"tags": ["family", "people"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 85,
		"cooldown_days": 900,
		"min_era_index": 1,
		"max_era_index": 6,
		"conditions": [
			{"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 1},
			{"op": Op.POPULATION_GTE, "int_value": 10},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 2},
				"add_weight": 20,
				"multiplier_q16": MUL_115,
				"reason": "族里有脸面，才怕人说",
			},
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 18},
				"add_weight": 15,
				"reason": "城大了，闲话传得快",
			},
		],
		"options": [
			Shared.option(
				"acknowledge_her", "认这门亲",
				"孩子叫了一声娘",
				"孩子叫了一声娘，柳嫂把布包放在门槛上，没进去。族里给她在城西置了一间屋，逢年过节送一份粮。李七说这不合规矩，周敬之没接话。",
				[
					TraitChanges.grant("j017_loyal", "老实"),
					Shared.birth(3, 540),
					Shared.bias(Ids.TAG_COURT, 1.15, 540),
				]),
			Shared.option(
				"pay_her_off", "赏钱打发",
				"布包收下了",
				"布包收下了，柳嫂数了钱，数完又放回桌上两枚。她走的时候没回头，虎头鞋留在门槛上。周家把鞋收进箱子，再没拿出来。",
				[
					Shared.cash_out(1.0, 360),
				]),
			Shared.option(
				"refuse_her", "不认这门亲",
				"门关上了",
				"门关上了，柳嫂在门口站到天黑。第二天，城西的人都在说周家的事。族里的孩子在外面被人问起，答不上来。",
				[
					Shared.knowledge(-2, 360),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
		],
	}))

	# ═══ 祠堂（A）════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY3_ANCESTRAL_HALL),
		"title": "{settlement_name}·祠堂",
		"body_text": "西街周氏的祠堂要扩，扩出来的地基压着官道。周朴说族里出钱，不用官府管；韦顺说官道是官道，压一寸也要报。工匠已经放了线，线从祠堂门槛一直拉到街心。过路的车马绕了三天，车夫开始骂。周敬之让人把线收了半尺，第二天又放回去。巷子里的老人说，祠堂的门朝哪开是族里的事，门外的路是大家的事。",
		"image_key": "family.house",
		"ai_visual_prompt": "A clan hall expansion line running from the threshold into a busy street, carts detouring, masons waiting",
		"tags": ["family", "court", "law"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 85,
		"cooldown_days": 720,
		"min_era_index": 2,
		"max_era_index": 7,
		"conditions": [
			{"op": Op.FAMILY_OWNS_BUILDINGS_GTE, "int_value": 1},
			{"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 2},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.FAMILY_OWNS_BUILDINGS_GTE, "int_value": 2},
				"add_weight": 20,
				"multiplier_q16": MUL_115,
				"reason": "族里的屋子已经连成片",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
				"add_weight": 15,
				"reason": "街面挤，扩一寸都扎眼",
			},
		],
		"options": [
			Shared.option(
				"let_him_expand", "准他把祠堂扩出去",
				"官道让了半尺",
				"官道让了半尺，车马从新墙根下过。周朴在祠堂里摆了三天酒，族里的人都来了。韦顺站在门口，把批文折好，递给身后的书吏。",
				[
					TraitChanges.grant("j020_gentry", "士绅门第"),
					Shared.build_cost(3, 540),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
			Shared.option(
				"half_the_size", "只准缩一半",
				"墙退了三尺",
				"墙退了三尺，祠堂比原图小了一间。周朴没来上梁，说身子不舒服。工匠把剩下的砖码在墙根，码得很齐。",
				[
					Shared.manufacturing(-2, 360),
					Shared.cash_in(1.0, 360),
				]),
			Shared.option(
				"forbid_it", "不许他动土",
				"线收了",
				"线收了，工匠散了。周朴在祠堂里坐了一下午，把族谱从头翻到尾。那年祭祖，来的人比往年少了一半。",
				[
					Shared.knowledge(-2, 360),
					Shared.bias(Ids.TAG_UNREST, 1.25, 540),
				]),
		],
	}))

	# ═══ 牌坊（A）════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY3_SCHOLAR_BOARD),
		"title": "{settlement_name}·牌坊",
		"body_text": "族学里的周家孙子中了榜，周朴要立牌坊。石料从南山运来，匠人说牌坊要立在三岔口，来往的人都看得见。韦顺提醒，立牌坊要报，报上去要等。李七说等批下来，喜气都凉了。石料堆在路口，占了半条街，孩子爬到石头上玩。周朴说牌子立起来，族里这些年的书就没白读。",
		"image_key": "family.house",
		"ai_visual_prompt": "Cut stone blocks piled at a crossroads for a memorial arch, children climbing them, an official with a report",
		"tags": ["family", "school", "court"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 85,
		"cooldown_days": 720,
		"min_era_index": 3,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 3},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "scholar", "float_value": 0.01},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 4},
				"add_weight": 20,
				"multiplier_q16": MUL_115,
				"reason": "族里等这块牌子等了几代",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "scholar", "float_value": 0.02},
				"add_weight": 15,
				"reason": "城里读书人多，牌子才有人看",
			},
		],
		"options": [
			Shared.option(
				"raise_the_arch", "把牌坊立起来",
				"牌坊立在三岔口",
				"牌坊立在三岔口，石匠把最后一块斗拱吊上去，围观的人往后退了一步。周朴在牌坊下一直站到点灯，没说话。韦顺的批文晚了半个月才到。",
				[
					TraitChanges.grant("j009_letters", "书香门第"),
					Shared.knowledge(3, 540),
					Shared.cash_out(1.0, 360),
				]),
			Shared.option(
				"turn_it_into_money", "折成现钱",
				"石料卖了",
				"石料卖了，钱进了族里的公匣。周朴说这样也好，牌子在心里。那年族学添了十张桌子，先生多请了一个。",
				[
					Shared.cash_in(1.5, 360),
					Shared.knowledge(-1, 360),
				]),
			Shared.option(
				"wait", "牌子先不立",
				"石料堆了一年",
				"石料堆了一年，边角被雨泡出青苔。孩子不再爬了，路过的人也不看了。第二年，周家又有人中榜，石料还是那堆。",
				[
					Shared.knowledge(-2, 360),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
		],
	}))

	# ═══ 包税（A）════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY3_TAX_FARM),
		"title": "{settlement_name}·包税",
		"body_text": "县里的税要包出去，周敬之想接。他说族里有账房、有仓、有车，收税比衙门快。韦顺说包税要垫钱，收不齐要赔。李七说去年南门李氏包了一季，赔了两头牛。周敬之把算盘拨了一遍，拨到最后一档，停了。窗外下着雨，衙门口排着交税的人。他把算盘珠子一颗颗归位，归到最后，手停住了。",
		"image_key": "country.economy",
		"ai_visual_prompt": "A clan elder at an abacus considering a tax-farming contract, taxpayers queuing in the rain outside a yamen",
		"tags": ["family", "fiscal", "market"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 720,
		"min_era_index": 3,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 4},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.02},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 5},
				"add_weight": 20,
				"multiplier_q16": MUL_120,
				"reason": "只有这种族垫得起",
			},
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "wheat_grain", "float_value": 1.15},
				"add_weight": 15,
				"reason": "粮价一高，税就难收",
			},
		],
		"options": [
			Shared.option(
				"take_the_farm", "包给族里",
				"税册换了手",
				"税册换了手，族里的账房搬进衙门东厢。头一季收得比往年快，第二季遇上旱，赔进去一笔。周敬之把赔的钱记在族账上，没让官府知道。",
				[
					TraitChanges.grant("i019_trade", "商路人脉"),
					Shared.cash_in(2.0, 360),
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
				]),
			Shared.option(
				"keep_it_official", "官府自己收",
				"税册还在衙门",
				"税册还在衙门，差役加了两个。收税的队伍照旧排到街口，只是慢了些。周敬之不再提这件事，把算盘收进柜子。",
				[
					Shared.cash_in(1.0, 360),
					Shared.manufacturing(-2, 360),
				]),
			Shared.option(
				"decline", "不包出去",
				"没人接这活",
				"没人接这活，税还是照收，只是收得更慢。那年冬天，衙门的灯点到很晚。周敬之在族里说，这种钱不能挣。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.10, 540),
				]),
		],
	}))

	# ═══ 族丁（A）════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY3_PRIVATE_ARM),
		"title": "{settlement_name}·族丁",
		"body_text": "周家的族丁已经有二十来个，白天在祠堂后头练，晚上各回各家。周朴说要添到五十，护着族里的仓和船。韦顺说朝廷有规矩，民间的丁不能过数。周敬之没说话，把名册翻到最后一页，那一页是新添的。练丁的喊声从墙外传进来，一声一声。名册上的名字，有一半是族里佃户的儿子。",
		"image_key": "map.construction",
		"ai_visual_prompt": "Clan retainers drilling behind an ancestral hall, a register open at a newly added page, an official watching",
		"tags": ["family", "frontier", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 85,
		"cooldown_days": 720,
		"min_era_index": 3,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 4},
			{"op": Op.FAMILY_OWNS_BUILDINGS_GTE, "int_value": 2},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 5},
				"add_weight": 20,
				"multiplier_q16": MUL_120,
				"reason": "族里养得起这么多人",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 4},
				"add_weight": 10,
				"reason": "兵戈的年代，护院才有用",
			},
		],
		"options": [
			Shared.option(
				"let_him_drill", "准他养到五十",
				"墙外的喊声更齐了",
				"墙外的喊声更齐了，五十个人分作五队，队头都姓周。族里的仓和船再没丢过东西。韦顺来点过一次名，点完把册子合上，什么也没说。",
				[
					TraitChanges.grant("j016_shrewd", "精明"),
					Shared.supply(8, 360),
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
				]),
			Shared.option(
				"disband_them", "把人遣散",
				"祠堂后头空了",
				"祠堂后头空了，兵器收进库房。周朴把名册烧了，灰埋在后院。族里的船丢了一趟货，没人再提。",
				[
					Shared.cash_out(1.5, 360),
					TraitChanges.grant("j017_loyal", "老实"),
				]),
			Shared.option(
				"absorb_them", "收进官册",
				"名册成了两份",
				"名册成了两份，一份在族里，一份在衙门。族丁改叫乡勇，粮由官府发一半。周朴说这样也好，至少名正言顺。",
				[
					Shared.supply(8, 360),
					Shared.cash_in(1.0, 360),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
		],
	}))

	# ═══ 义庄（A）════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY3_CHARITY_ESTATE),
		"title": "{settlement_name}·义庄",
		"body_text": "李氏要设义庄，赡族里的孤寡。李七说族里出田，官府给个名分就行。韦顺说名分好给，田契要过官。义庄的屋子已经收拾出来，门口挂着一块没写字的木牌。第一批领粮的名单贴在墙上，字是李七自己写的。他说义庄的田是族里公田，租子归义庄，不归哪一房。木牌上的字，他写了三遍。",
		"image_key": "family.house",
		"ai_visual_prompt": "A charity estate house with a blank wooden plaque, a list of names pasted on the wall, sacks of grain inside",
		"tags": ["family", "people", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 85,
		"cooldown_days": 720,
		"min_era_index": 2,
		"max_era_index": 9,
		"conditions": [
			{"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 2},
			{"op": Op.POPULATION_GTE, "int_value": 15},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 3},
				"add_weight": 15,
				"multiplier_q16": MUL_115,
				"reason": "族里有田，才设得起义庄",
			},
			{
				"condition": {"op": Op.COHORT_SATISFACTION_LTE, "float_value": 0.50},
				"add_weight": 20,
				"reason": "日子难过，孤寡先撑不住",
			},
		],
		"options": [
			Shared.option(
				"let_him_found_it", "准他设义庄",
				"木牌写上了字",
				"木牌写上了字，第一批粮发出去，领粮的人排到巷口。李七站在门口，一个一个念名字。周敬之送来一担米，没进门。",
				[
					TraitChanges.grant("j017_loyal", "老实"),
					Shared.staple(-4, 360),
					Shared.cash_in(0.5, 360),
				]),
			Shared.option(
				"match_half", "官府配一半",
				"官仓出了三成",
				"官仓出了三成，族里出了两成。义庄门口挂了官府的牌，领粮的人多了两成。李七说这样也好，至少不会断。",
				[
					Shared.cash_out(2.0, 360),
					Shared.staple(-3, 360),
					Shared.knowledge(2, 360),
				]),
			Shared.option(
				"refuse", "不许他设",
				"木牌摘了",
				"木牌摘了，屋子改作仓房。李七把摘下的木牌和名单捆在一起，放在门槛上，自己站在巷口看了一会儿。那年冬天，巷子尽头多了两个要饭的。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
					Shared.staple(3, 360),
				]),
		],
	}))

	TraitEvents.append(catalog, MUL_115, MUL_120)
