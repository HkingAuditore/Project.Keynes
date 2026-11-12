class_name NarrativeEventCatalogFamily2
extends RefCounted

## 家族桥包：十条读家族快照、改写家族特质的事件。
##
## 与 family 包的分工：
##   family  写「一家人的一件小事」，机制上是通用杠杆；
##   family2 写「本地最大族与官府的一次交易」，机制上真的读家族、真的改家族。
##
## 读：`primary_family_*`（人口占比、威望档、拥有建筑、名人）。
## 写：GRANT / REMOVE_FAMILY_TRAIT，走 queue_family_trait_mutation。
## 约束：特质只是家族身份/偏好，不是“加威望”；现金转移仍落在本地人数最多的那群人，
## 标签不写“这个族出钱/得钱”。无族时条件不成立，效果静默模拟。

const Ids = preload("res://scripts/narrative/narrative_event_ids.gd")
const Shared = preload("res://scripts/narrative/narrative_event_shared.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")
const NarrativeEffectSpecScript = preload("res://scripts/narrative/narrative_effect_spec.gd")

const PACK_ID := &"family2"
const PREFIX := "evt.family2."

const CAST := [
	"周敬之", "李七", "韩仓", "韦顺", "罗阿石", "邬三", "常五", "苗大", "葛六", "石宝",
	"西街", "南门", "族仓", "族学", "祠堂", "船行",
]

const MUL_110 := 72090
const MUL_115 := 75366
const MUL_120 := 78643
const MUL_125 := 81920
const MUL_130 := 85197


static func _grant(trait_key: String, display_name: String) -> Dictionary:
	return {
		"kind": NarrativeEffectSpecScript.Kind.GRANT_FAMILY_TRAIT,
		"target_key": trait_key,
		"magnitude_q16": 65536,
		"duration_days": 1,
		"custom_label": "本地最大族「{family_name}」获特质「%s」，永久" % display_name,
	}


static func _remove(trait_key: String, display_name: String) -> Dictionary:
	return {
		"kind": NarrativeEffectSpecScript.Kind.REMOVE_FAMILY_TRAIT,
		"target_key": trait_key,
		"duration_days": 1,
		"custom_label": "本地最大族「{family_name}」失去特质「%s」" % display_name,
	}


static func meta() -> Dictionary:
	return {
		"id": PACK_ID,
		"title": "家族桥",
		"theme": "本地最大族与官府",
		"era_band": "1-9",
		"prefix": PREFIX,
		"scale": "10 条中观/微观孤立",
		"cast": CAST,
		"node_ids": [
			String(Ids.EVT_FAMILY2_SCHOOL),
			String(Ids.EVT_FAMILY2_GRANARY),
			String(Ids.EVT_FAMILY2_FEUD),
			String(Ids.EVT_FAMILY2_LOAN),
			String(Ids.EVT_FAMILY2_OFFICE),
			String(Ids.EVT_FAMILY2_MIGRATION),
			String(Ids.EVT_FAMILY2_GUILD),
			String(Ids.EVT_FAMILY2_MARRIAGE),
			String(Ids.EVT_FAMILY2_RELIEF),
			String(Ids.EVT_FAMILY2_SEA),
		],
	}


static func append(catalog) -> void:
	if catalog == null:
		return
	var Op = NarrativeConditionScript.Op
	var Ch = NarrativeEventDefinitionScript.TriggerChannel

	# ═══ 族学 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY2_SCHOOL),
		"title": "{settlement_name}·族学",
		"body_text": "西街的周敬之把祠堂东厢腾出来，摆了六张矮桌，请了个落第的书生。他说族里出钱，族里的孩子先读，读得好的再往外送。韦顺拿着册子算了一笔：纸、墨、灯油、先生的束脩，一年下来不是小数。李七在旁边说，族里出钱，往后族里说话就更响。周敬之没理他，把第一本蒙书放在桌上，书角压着一块镇纸。",
		"image_key": "family.house",
		"ai_visual_prompt": "A clan hall side room turned into a school, low desks, a failed scholar, account books and a paperweight",
		"tags": ["family", "school", "court"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 2,
		"max_era_index": 7,
		"conditions": [
			{"op": Op.HAS_NOTABLE_FAMILY, "bool_value": true},
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 3},
				"add_weight": 25,
				"multiplier_q16": MUL_115,
				"reason": "这一族在这一带说话有分量",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
				"add_weight": 15,
				"reason": "有祠堂也有空屋",
			},
		],
		"options": [
			Shared.option(
				"fund_the_school", "族里出钱办",
				"东厢坐满了",
				"东厢坐满了，最小的孩子够不着桌沿，垫了两块砖。周敬之每月来看一回，只看册子，不听先生讲。那年冬天，族里出了第一个能写全篇的孩子。",
				[
					_grant("i005_knowledge", "学术赞助"),
					Shared.knowledge(4, 540),
					Shared.cash_out(1.5, 360),
				]),
			Shared.option(
				"let_them_run_it", "让族里自己办，官府给块匾",
				"匾挂上了",
				"匾挂上那天，李七在门口放了一挂鞭。官府没出钱，也没派人，只来过一个书办，站在门口看了一会儿。第二年，族里把东厢又扩了一间。",
				[
					_grant("i005_knowledge", "学术赞助"),
					Shared.knowledge(2, 540),
					Shared.bias(Ids.TAG_COURT, 1.15, 540),
				]),
			Shared.option(
				"repair_the_granary", "不办，先把仓修好",
				"东厢又锁上了",
				"东厢又锁上了，桌凳搬回仓里垫粮。先生走的时候，周敬之送到巷口，给了两匹布。那年秋雨大，仓没漏，族学的事没人再提。",
				[
					Shared.knowledge(-3, 360),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
		],
	}))

	# ═══ 族仓 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY2_GRANARY),
		"title": "{settlement_name}·族仓",
		"body_text": "南门李氏的族仓在巷子最里头，仓门上了两把锁。韩仓说今年收成好，李氏把粮压在仓里不卖，市上的米价一天一个样。李七说族里的粮，族里做主；韦顺说再这样下去，城里要出事。周敬之站在仓门口，看着门上的锁，没让人开。巷口排队的人越来越多，有人开始敲自己的空碗。",
		"image_key": "country.economy",
		"ai_visual_prompt": "A clan granary with two locks on the door, a queue of townspeople with empty bowls, an official arguing with the clan",
		"tags": ["family", "market", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 720,
		"min_era_index": 2,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.FAMILY_POP_SHARE_GTE, "float_value": 0.25},
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "wheat_grain", "float_value": 1.15},
				"add_weight": 25,
				"multiplier_q16": MUL_125,
				"reason": "米价一高，仓里的粮就扎眼",
			},
			{
				"condition": {"op": Op.FAMILY_POP_SHARE_GTE, "float_value": 0.35},
				"add_weight": 20,
				"reason": "这一族占了半城的人",
			},
		],
		"options": [
			Shared.option(
				"let_them_hold", "准他囤，价高再卖",
				"仓门没开",
				"仓门没开，市上的米价又往上走了一截。李氏在仓里换了新锁，钥匙分给三房。冬天来的时候，巷口多了几个不认得的人。",
				[
					_grant("i001_agrarian", "重农"),
					Shared.agriculture(-3, 360),
					Shared.trade_capacity(3, 360),
				]),
			Shared.option(
				"buy_at_the_listed_price", "平价征粮",
				"仓门开了",
				"仓门开了，粮按官价过秤，李氏的人站在旁边记数。队伍排到天黑，米价没动，李氏把仓门开了一半。李七把账本合上，说这笔账族里记着。",
				[
					Shared.cash_in(1.0, 360),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
			Shared.option(
				"ask_them_to_open", "让他开仓放粮",
				"门口支起了粥锅",
				"仓门口支起粥锅，李氏自己掌勺。头三天队伍很长，第四天短了。周敬之在巷口看了一会儿，让人把官仓的封条重新贴好，没再提征粮。",
				[
					_grant("j017_loyal", "老实"),
					Shared.staple(-5, 360),
					Shared.cash_out(1.0, 360),
				]),
		],
	}))

	# ═══ 争产 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY2_FEUD),
		"title": "{settlement_name}·争产",
		"body_text": "周家两房为一口井和半亩宅基地翻了脸。老大把老二的农具扔到街上，老二堵了老大出门的路。族里请周敬之断，周敬之说自己也是周家人，断不了。韦顺被请来，坐在祠堂门槛上，听完两边的说法，把册子合上，说要断可以，断完这个族就散了。院里的人都看着他，井台上的绳子还挂着，桶在井里。",
		"image_key": "family.house",
		"ai_visual_prompt": "Two branches of a clan quarrelling in a courtyard, farm tools thrown into the street, a well bucket hanging",
		"tags": ["family", "law", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 720,
		"min_era_index": 1,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.FAMILY_OWNS_BUILDINGS_GTE, "int_value": 1},
			{"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 1},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.FAMILY_POP_SHARE_GTE, "float_value": 0.20},
				"add_weight": 20,
				"multiplier_q16": MUL_120,
				"reason": "人多的族，分家就是分城",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
				"add_weight": 15,
				"reason": "有宅有井，才争得起来",
			},
		],
		"options": [
			Shared.option(
				"judge_for_the_elder", "官府断，判给长房",
				"井归了长房",
				"井归长房，次房的人把自家的桶砸了。判词贴在祠堂门口，第二天被人撕了半边。韦顺重新抄了一份，贴在原来的位置。",
				[
					Shared.cash_in(1.0, 360),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
			Shared.option(
				"let_them_split_it", "让他们自己分，分完再说",
				"井台砌了一道墙",
				"井台砌了一道墙，两家各开一个口。墙砌好那天，两边的人都来打水，桶碰在一起，谁也没让。水还是那口井的水。",
				[
					Shared.manufacturing(-3, 360),
					Shared.bias(Ids.TAG_UNREST, 1.25, 540),
				]),
			Shared.option(
				"suppress_it", "压下去，谁闹谁担",
				"两房都不闹了",
				"两房都不闹了，井上的绳子收进屋。周敬之把两把锁都收进匣子，说等他想明白再分。那年冬天，两房的人见面不说话，井台上落了雪，没人扫。",
				[
					_grant("j016_shrewd", "精明"),
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
				]),
		],
	}))

	# ═══ 借粮 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY2_LOAN),
		"title": "{settlement_name}·借粮",
		"body_text": "度支房的钱不够发饷，韦顺把账本摊在周敬之面前，说想向族里借一笔。周敬之没看账本，先问拿什么作抵。韦顺说拿明年的盐课。李七在旁边笑了一声，说盐课去年也押过。韩仓把仓门开了一条缝，让韦顺看里头的粮，说粮可以借，息要按族里的规矩算。韦顺把账本翻到最后一页，那页是空的。",
		"image_key": "country.economy",
		"ai_visual_prompt": "An official borrowing from a clan, a granary door ajar, an account book with a blank last page",
		"tags": ["family", "fiscal"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 720,
		"min_era_index": 2,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 3},
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 4},
				"add_weight": 25,
				"multiplier_q16": MUL_120,
				"reason": "只有这种族拿得出这笔钱",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 5},
				"add_weight": 15,
				"reason": "度支房开始按月算账",
			},
		],
		"options": [
			Shared.option(
				"borrow_from_the_clan", "向族借，押盐课",
				"借券画了押",
				"借券画了押，周敬之把盐课的文书锁进族里的柜子。饷发下去那天，营里没闹。第二年盐课下来，度支房的人先去族里赎文书。",
				[
					Shared.cash_in(1.5, 360),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
					_grant("i028_counter", "逆周期经营"),
				]),
			Shared.option(
				"levy_instead", "加征，不借",
				"告示贴在城门上",
				"告示贴在城门上，按亩加征。第一天收上来的钱不够一半，第二天有人把告示撕了。韦顺带人去催，回来时鞋上全是泥。",
				[
					Shared.cash_in(2.0, 360),
					Shared.agriculture(-3, 360),
					Shared.bias(Ids.TAG_UNREST, 1.35, 540),
				]),
			Shared.option(
				"cut_the_budget", "减开支，不借",
				"衙门的灯少点了一盏",
				"衙门的灯少点了一盏，差役减了两个。度支房把明年的工钱压了一成，工匠在门口等了一炷香，走了。韦顺把账本合上，说这样也能过。",
				[
					Shared.manufacturing(-3, 360),
					Shared.bias(Ids.TAG_LABOR, 0.90, 360),
				]),
		],
	}))

	# ═══ 求官 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY2_OFFICE),
		"title": "{settlement_name}·求官",
		"body_text": "周敬之想把孙子送进衙门。他没提送礼，只说孩子认字，会算，能吃苦。韦顺说如今补一个缺，要三个人作保。李七说作保的人得先看周家能出多少。周敬之把手里的茶碗放下，碗底在桌上磕了一声。韦顺把名册翻开，翻到空白的那一页，笔尖悬着。里屋的帘子动了一下，有人在后头听。",
		"image_key": "family.house",
		"ai_visual_prompt": "A clan elder asking an official for a post, a roster open at a blank page, a brush hovering",
		"tags": ["family", "court"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 85,
		"cooldown_days": 720,
		"min_era_index": 3,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 3},
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 4},
				"add_weight": 20,
				"multiplier_q16": MUL_115,
				"reason": "族大势大，缺一个名分",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "scholar", "float_value": 0.01},
				"add_weight": 15,
				"reason": "城里有人替他说得上话",
			},
		],
		"options": [
			Shared.option(
				"give_him_the_post", "给官，三家作保",
				"名册上添了一行",
				"名册上添了个名字，三个保人挤在一处画押。周家的孙子第二天就来点卯，来得比谁都早。韦顺把笔搁在砚台上，说这一缺，往后就姓周了。",
				[
					_grant("j020_gentry", "士绅门第"),
					Shared.build_cost(3, 540),
					Shared.bias(Ids.TAG_COURT, 1.15, 540),
				]),
			Shared.option(
				"keep_the_exam", "不收，照旧考",
				"名册合上了",
				"名册合上了，韦顺把空页折了个角。周敬之站起来，茶碗还在桌上，没喝完。那年考试，周家的孙子没去，听说在家里读了一冬天的书。",
				[
					Shared.knowledge(-3, 360),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
			Shared.option(
				"sell_the_post", "收钱，补别人的缺",
				"缺给了别家",
				"缺给了一个出得起钱的别家子弟，那人第一天就把公文拿倒了。韦顺站在旁边看着，没提醒。周敬之听说以后，把家里的书都收进了箱子。",
				[
					Shared.cash_in(2.0, 360),
					Shared.bias(Ids.TAG_UNREST, 1.25, 540),
				]),
		],
	}))

	# ═══ 迁族 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY2_MIGRATION),
		"title": "{settlement_name}·迁族",
		"body_text": "南门李氏要走。李七说族里在城外买了地，这边的宅子和井都卖了，走一半人。韩仓把族仓最后一批粮装车，车辙压过门槛。韦顺劝他们留，说城里正缺人。李七说缺人的时候想起我们，收税的时候也想起我们。周敬之站在巷口，看车一辆一辆过去，没有拦。最后一辆车上坐着一个老人，怀里抱着一块牌位。",
		"image_key": "family.house",
		"ai_visual_prompt": "A clan loading carts to leave a town, an elder on the last cart holding an ancestral tablet",
		"tags": ["family", "people", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 85,
		"cooldown_days": 900,
		"min_era_index": 2,
		"max_era_index": 9,
		"conditions": [
			{"op": Op.FAMILY_POP_SHARE_GTE, "float_value": 0.30},
			{"op": Op.COHORT_SATISFACTION_LTE, "float_value": 0.50},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.FAMILY_POP_SHARE_GTE, "float_value": 0.40},
				"add_weight": 25,
				"multiplier_q16": MUL_125,
				"reason": "走一半人，城就空一半",
			},
			{
				"condition": {"op": Op.SATISFACTION_LTE, "float_value": 0.45},
				"add_weight": 20,
				"reason": "日子过不下去，才想着搬",
			},
		],
		"options": [
			Shared.option(
				"let_them_go", "放他们走",
				"南门的宅子空了",
				"南门的宅子空了，井台上长了草。李氏在城外的新地开了渠，第二年秋天的粮价没往上走。韦顺在册子上把李氏的名字划掉，划得很轻。",
				[
					_grant("i025_pioneer", "拓荒者"),
					Shared.birth(-4, 540),
					Shared.agriculture(3, 360),
				]),
			Shared.option(
				"forbid_the_sale", "强留，不许卖宅",
				"宅子没卖成",
				"宅子没卖成，李七在祠堂里坐了一夜。第二天，一半人走了，一半人留下。留下的那半，见了官府的人就低头。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
					Shared.manufacturing(2, 360),
				]),
			Shared.option(
				"give_them_land", "分地留人",
				"城外的荒地分了",
				"城外的荒地分了，李氏的人没走。渠修到坡下，第一年种的是豆。李七在分地的文书上按了手印，按完把印泥盒盖好，还给了韦顺。",
				[
					Shared.cash_out(1.5, 360),
					Shared.agriculture(4, 540),
				]),
		],
	}))

	# ═══ 族与行会 ═════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY2_GUILD),
		"title": "{settlement_name}·族与行会",
		"body_text": "罗阿石的作坊挂上了李七家的灯笼：族里出钱，他出工，行会的人看不下去。行会的老执事来问，这算族里的作坊，还是行会的作坊。罗阿石说算族里的，钱是族里出的。执事把行会的册子拍在案上，说册子上没有李家的名字。门外站着一排学徒，谁也没说话，灯笼在风里晃。",
		"image_key": "map.construction",
		"ai_visual_prompt": "A workshop with a clan lantern, a guild steward slamming a roster on the desk, apprentices watching",
		"tags": ["family", "labor", "market"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 720,
		"min_era_index": 3,
		"max_era_index": 7,
		"conditions": [
			{"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 2},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "artisan", "float_value": 0.08},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.FAMILY_OWNS_BUILDINGS_GTE, "int_value": 2},
				"add_weight": 25,
				"multiplier_q16": MUL_120,
				"reason": "族里已经有铺面",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "artisan", "float_value": 0.12},
				"add_weight": 15,
				"reason": "匠户多，行会才管得着",
			},
		],
		"options": [
			Shared.option(
				"two_plaques", "让族入行会，挂两块牌",
				"门口挂了两块牌",
				"门口挂了两块牌，一块写族名，一块写行会。罗阿石的交椅摆在中间，谁来了都先看牌子。那年行会收份子，李家交得比谁都快。",
				[
					_grant("j004_craft", "工匠世家"),
					Shared.manufacturing(4, 540),
					Shared.tools(5, 540),
				]),
			Shared.option(
				"guild_rules", "行会自治，族不插手",
				"灯笼摘了",
				"灯笼摘了，作坊归行会管。罗阿石还是掌柜，只是每月要去行会点卯。李家的人从此不从这条巷子过。",
				[
					Shared.manufacturing(3, 540),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
			Shared.option(
				"break_the_lantern", "官府压制，拆灯笼",
				"灯笼踩扁了",
				"灯笼被踩扁在门口，罗阿石蹲下去捡，捡了一半又放下。行会的人把册子收走，作坊停了三天。第四天开门，门口只剩一根空竿。",
				[
					_remove("j004_craft", "工匠世家"),
					Shared.manufacturing(-3, 360),
					Shared.cash_in(1.0, 360),
				]),
		],
	}))

	# ═══ 联姻 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY2_MARRIAGE),
		"title": "{settlement_name}·联姻",
		"body_text": "周家和李家要结亲。周敬之要李家把城南的铺面写进婚书，李家只肯写一半。韦顺两头跑，鞋底磨薄了一层。李七说铺面是族里的公产，写进去要全族按手印。周敬之的儿媳在里屋听着，手里的线断了两次。李家的老人把族谱摊在膝上，翻到联姻那一页，指头在纸上停了很久。祠堂的灯点到后半夜，婚书还空着一行。",
		"image_key": "family.house",
		"ai_visual_prompt": "A marriage contract on a clan hall table with one blank line, a woman winding thread behind a curtain",
		"tags": ["family", "people"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 85,
		"cooldown_days": 720,
		"min_era_index": 1,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 2},
			{"op": Op.POPULATION_GTE, "int_value": 12},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 3},
				"add_weight": 20,
				"multiplier_q16": MUL_115,
				"reason": "两家都要脸面",
			},
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 18},
				"add_weight": 15,
				"reason": "城大了，联姻才有利可图",
			},
		],
		"options": [
			Shared.option(
				"sign_as_asked", "结亲，按周家写的",
				"婚书按了三个印",
				"婚书按了三个印，铺面写了两间。酒席摆在祠堂，李家的老人坐在末席。周敬之的儿媳进门那天，李七在门口放了一挂鞭，放完就走了。",
				[
					_grant("i026_magnate", "家大业大"),
					Shared.birth(4, 540),
					Shared.cash_out(1.0, 360),
				]),
			Shared.option(
				"call_it_off", "不结，各走各的",
				"婚书烧了",
				"婚书在祠堂门口烧了，纸灰被风卷到井台上。两家从此不走动，城南的铺面各自换了招牌。周敬之的儿媳后来嫁去了外县。",
				[
					Shared.bias(Ids.TAG_COURT, 1.15, 540),
					Shared.knowledge(-2, 360),
				]),
			Shared.option(
				"let_them_settle", "让两家自己谈，官府不插手",
				"婚书空着一行",
				"婚书空着一行，两家各自按了半个手印。酒席没办，只送了一担礼。那年冬天，两家在城南合开了一间铺子，招牌上两个姓。",
				[
					Shared.staple(3, 360),
					Shared.birth(2, 540),
				]),
		],
	}))

	# ═══ 族赈 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY2_RELIEF),
		"title": "{settlement_name}·族赈",
		"body_text": "城里断粮的第三天，李氏的族仓开了。李七在仓门口支了张桌，按户发粮，发到第三排，粮不够了。韩仓说仓里还有种粮。李七说种粮不能动。韦顺站在旁边，看见队伍里有几个不是本族的人，也排在里头。他低头在册子上写了个数，写完又划掉，重写了一行。李七没赶那些人，把最后一斗分了。分完，他把空斗倒扣在桌上。",
		"image_key": "family.house",
		"ai_visual_prompt": "A clan granary distributing grain, a half-empty measure overturned on a table, a mixed queue",
		"tags": ["family", "unrest", "people"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 1,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 2},
			{"op": Op.COHORT_SATISFACTION_LTE, "float_value": 0.50},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.COHORT_SATISFACTION_LTE, "float_value": 0.40},
				"add_weight": 25,
				"multiplier_q16": MUL_125,
				"reason": "再不放粮就要出事",
			},
			{
				"condition": {"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 3},
				"add_weight": 15,
				"reason": "这一族仓里有底",
			},
		],
		"options": [
			Shared.option(
				"let_the_clan_feed", "让族开仓，官府记一笔",
				"仓门口的队散了",
				"仓门口的队散了，李氏的粮发完了。韦顺在册子上记了一笔，写的是“借”。李七看见了，没说话，把册子推回去；第二年秋收，族里也没来讨这笔粮。",
				[
					_grant("j017_loyal", "老实"),
					Shared.staple(-5, 360),
					Shared.cash_in(1.5, 360),
				]),
			Shared.option(
				"open_the_state_granary", "官府自己赈",
				"官仓开了",
				"官仓开了，队伍排到城门口。粮价当天落下去，李氏的仓门一直关着。韩仓在门口站了半天，说早该这样，声音很小。",
				[
					Shared.cash_out(2.0, 360),
					Shared.staple(-4, 360),
					Shared.knowledge(2, 360),
				]),
			Shared.option(
				"let_them_endure", "不管，让他们自己撑",
				"队伍散了",
				"队伍散了，有人去城外挖野菜。李氏的仓门开了一条缝，又关上。那年冬天，城里少了些人，族里的册子也薄了。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
					Shared.staple(4, 360),
				]),
		],
	}))

	# ═══ 族船 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY2_SEA),
		"title": "{settlement_name}·族船",
		"body_text": "周家的船队从南边回来，船底补过三回，舱里装的是香料和铜。周敬之想把船队做大，要官府给一张出海的凭。韦顺说得先看朝廷的意思。李七说等朝廷的意思，船早烂在港里。港口的税吏站在栈桥上，手里拿着册子，问船是谁家的。周敬之报了族名，税吏把册子翻到最后一页。",
		"image_key": "hydrology.water",
		"ai_visual_prompt": "A clan trading fleet back in harbour, patched hulls, spices and copper in the hold, a tax clerk on the pier",
		"tags": ["family", "sea", "market"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 720,
		"min_era_index": 4,
		"max_era_index": 7,
		"conditions": [
			{"op": Op.IS_COASTAL, "bool_value": true},
			{"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 3},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 4},
				"add_weight": 20,
				"multiplier_q16": MUL_120,
				"reason": "这种族才养得起船队",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.03},
				"add_weight": 15,
				"reason": "港口的货有人接",
			},
		],
		"options": [
			Shared.gamble(
				"charter_the_fleet", "准族出海，抽一份税",
				Shared.branch(39322, "凭状发了", # 60%
					"凭状发了，周家的船队添了两条新船。税吏每月上码头一次，按舱抽一份。李七说抽得太狠，周敬之没接话，把凭状裱起来挂在祠堂。",
					[
						_grant("i029_coastal", "沿海资本"),
						Shared.trade_capacity(5, 540),
						Shared.cash_in(1.0, 360),
					]),
				Shared.branch(26214, "船没回来", # 40%
					"船队在南边遇了风，回来时少了一条。周敬之在码头站到天黑，税吏来问明年的凭状还续不续。他没答，把祠堂的门关上了。",
					[
						Shared.manufacturing(-3, 360),
						Shared.cash_out(1.5, 360),
						Shared.bias(Ids.TAG_UNREST, 1.30, 540),
					])),
			Shared.option(
				"state_fleet", "官营船队，族里出人",
				"船头换了旗",
				"船头换了官旗，周家的人还在船上，工钱按月发。第一趟走的是官货，回来时舱里空了一半。周敬之站在码头看，没上船。",
				[
					Shared.cash_out(2.5, 360),
					Shared.trade_capacity(4, 540),
					Shared.manufacturing(3, 540),
				]),
			Shared.option(
				"close_the_sea", "禁海，船都封了",
				"船拖上了岸",
				"船拖上岸，底朝上扣在滩上。周家的水手散了，有的去了外县。税吏的册子合上，最后一页还是空的。",
				[
					Shared.manufacturing(-3, 360),
					Shared.bias(Ids.TAG_UNREST, 1.25, 540),
				]),
		],
	}))
