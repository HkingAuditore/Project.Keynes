class_name NarrativeEventCatalogTech
extends RefCounted

## 技术包：六条，各自只认一门具体科技。
##
## 之前所有事件都按「时代」粗分，没有一条读 `HAS_TECHNOLOGY`——同样的蒸汽时代，
## 研没研出蒸汽动力遇到的事是一样的。这一包把六门科技接成事件门槛，
## 让「先点什么科技」在叙事层也有回报。
##
## 科技 id 取自 `data/technology/technology_network.json`：
##   tech.irrigation / tech.movable_type_printing / tech.gunpowder_weapons /
##   tech.steam_power / tech.rail_logistics / tech.synthetic_fertilizer

const Ids = preload("res://scripts/narrative/narrative_event_ids.gd")
const Shared = preload("res://scripts/narrative/narrative_event_shared.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")

const PACK_ID := &"tech"
const PREFIX := "evt.tech."

const CAST := [
	"韦顺", "韩仓", "李七", "周敬之", "罗阿石", "柳嫂", "邬三", "常五", "苗大", "石宝",
	"祠堂", "族仓", "城南", "官道",
]

const MUL_110 := 72090
const MUL_115 := 75366
const MUL_120 := 78643
const MUL_125 := 81920


static func meta() -> Dictionary:
	return {
		"id": PACK_ID,
		"title": "技术",
		"theme": "一门科技落到城里",
		"era_band": "2-10",
		"prefix": PREFIX,
		"scale": "6 条中观孤立",
		"cast": CAST,
		"node_ids": [
			String(Ids.EVT_TECH_IRRIGATION),
			String(Ids.EVT_TECH_PRINTING),
			String(Ids.EVT_TECH_GUNPOWDER),
			String(Ids.EVT_TECH_STEAM),
			String(Ids.EVT_TECH_RAIL),
			String(Ids.EVT_TECH_FERTILIZER),
		],
	}


static func append(catalog) -> void:
	if catalog == null:
		return
	var Op = NarrativeConditionScript.Op
	var Ch = NarrativeEventDefinitionScript.TriggerChannel

	# ═══ 灌溉 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_TECH_IRRIGATION),
		"title": "{settlement_name}·水册",
		"body_text": "渠修到村口，水口只有一个。上游的田先浇，下游的人半夜去扒口子，被巡渠的撞见。里正把水册摊在碾盘上，说按亩分，一亩一炷香。常五说自家地少，按户分才公平。韦顺把锹插在渠边，拿树枝在泥里画了一道线，说线以上先浇。线画完，上游的人先应了声。常五没再争，把铁锹扛上肩。",
		"image_key": "hydrology.water",
		"ai_visual_prompt": "A single irrigation sluice at a village, water roster on a millstone, a line drawn in mud, farmers on both banks",
		"tags": ["tech", "land", "agriculture"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 2,
		"max_era_index": 6,
		"conditions": [
			{"op": Op.HAS_TECHNOLOGY, "target_key": "tech.irrigation"},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "agricultural_worker", "float_value": 0.15},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "wheat_grain", "float_value": 1.10},
				"add_weight": 20,
				"multiplier_q16": MUL_115,
				"reason": "粮价高，水就更金贵",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "agricultural_worker", "float_value": 0.25},
				"add_weight": 15,
				"reason": "种地的人多，水才不够分",
			},
		],
		"options": [
			Shared.option(
				"by_acre", "按亩分水",
				"水册按亩写",
				"水册按亩写，上游的田先浇，一亩一炷香。常五把自家那几行看了三遍，没说话。渠水下去以后，下游的田还是晚了两天。",
				[
					Shared.agriculture(3, 540),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
			Shared.option(
				"by_household", "按户分水",
				"水口按户轮",
				"水口按户轮，一家一昼夜。上游的人夜里守着，下游的人白天守着，谁也没多浇。轮完一轮，渠底露了泥。",
				[
					Shared.staple(-3, 360),
					Shared.cash_out(1.0, 360),
				]),
			Shared.option(
				"official_roster", "官定水册",
				"水册盖了官印",
				"水册盖了官印，按亩按户都写在上面。巡渠的加了两个，工钱从水费里出。常五把水费交了，回头看了一眼那条线。",
				[
					Shared.cash_in(1.0, 360),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
		],
	}))

	# ═══ 印刷 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_TECH_PRINTING),
		"title": "{settlement_name}·盗印",
		"body_text": "印坊的活字排了一夜，天亮时《四书》的墨还没干。书价落到从前一半，买书的人排到巷口。书坊的旧主拿着原版来告，说印坊盗印，字是他家刻的。罗阿石说，字是字，书是书。韦顺把两本书并排放在案上，纸色不一样，字口也不一样。旧主伸手去翻，被印坊的伙计挡开。案上的墨还没干透。",
		"image_key": "country.technology",
		"ai_visual_prompt": "A print shop at dawn with movable type, two editions side by side, an old publisher arguing with the printer",
		"tags": ["tech", "school", "market"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 720,
		"min_era_index": 3,
		"max_era_index": 7,
		"conditions": [
			{"op": Op.HAS_TECHNOLOGY, "target_key": "tech.movable_type_printing"},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "scholar", "float_value": 0.01},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
				"add_weight": 20,
				"multiplier_q16": MUL_120,
				"reason": "城里有印坊，也有书铺",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "scholar", "float_value": 0.02},
				"add_weight": 15,
				"reason": "读书人多，书才卖得动",
			},
		],
		"options": [
			Shared.option(
				"ban_the_pirates", "查禁盗印",
				"印坊的版被起走",
				"印坊的版被起走，活字撒了一地。第二天书又卖回原来的价，买书的人少了一半。旧主把原版收进柜子，钥匙挂回腰上。",
				[
					Shared.knowledge(-2, 360),
					Shared.cash_in(1.0, 360),
				]),
			Shared.option(
				"let_it_spread", "放任不管",
				"书价没再涨",
				"书钱没再往上走，印坊的活字越排越多。旧主的书铺关了门，伙计去了印坊。那年冬天，城里的孩子多了几本翻烂的《四书》。",
				[
					Shared.knowledge(3, 540),
					Shared.manufacturing(-2, 360),
				]),
			Shared.option(
				"official_print", "官印官卖",
				"官印的书盖了戳",
				"官印的书盖了戳，价钱定在半价。印坊替官府印，旧主替官府校。两家人坐在一条板凳上，谁也没看谁。",
				[
					Shared.cash_out(1.5, 360),
					Shared.knowledge(2, 540),
				]),
		],
	}))

	# ═══ 火药 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_TECH_GUNPOWDER),
		"title": "{settlement_name}·炮位",
		"body_text": "炮铸出来了，试放那天，城外的石墙被轰开一个口子。苗大说要改城墙，把马面加厚；工房说该多铸几门炮，墙再厚也挡不住炮。两种说法都递到衙门，预算只够一样。韦顺去看那段墙，豁口里露出旧砖，砖上还有前朝的印。他伸手摸了摸豁口，砖是凉的。守备站在后头，没说话。",
		"image_key": "country.military",
		"ai_visual_prompt": "A newly cast cannon before a breached stone wall, an old brick with a previous dynasty's stamp exposed",
		"tags": ["tech", "war", "frontier"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 720,
		"min_era_index": 4,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.HAS_TECHNOLOGY, "target_key": "tech.gunpowder_weapons"},
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.AT_WAR, "bool_value": true},
				"add_weight": 25,
				"multiplier_q16": MUL_120,
				"reason": "在打仗，墙和炮都要紧",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 5},
				"add_weight": 10,
				"reason": "炮多了，城墙就不够厚",
			},
		],
		"options": [
			Shared.option(
				"thicken_the_wall", "把城墙加厚",
				"马面加了三尺",
				"马面加了三尺，旧砖被新砖包进去。石匠说这样能扛几炮，守备没说能扛几炮。炮位留在城头，炮口朝着城外。",
				[
					Shared.cash_out(2.0, 360),
					Shared.build_cost(3, 540),
					Shared.bias(Ids.TAG_COURT, 1.15, 540),
				]),
			Shared.option(
				"cast_more_cannons", "多铸几门炮",
				"工房连夜开炉",
				"工房连夜开炉，铁水映红了半条街。新炮排在城头，旧墙的豁口还没补。守备去看了一回，说炮是好炮。",
				[
					Shared.cash_out(2.5, 360),
					Shared.manufacturing(4, 540),
				]),
			Shared.option(
				"do_neither", "两样都不办",
				"豁口拿木栅拦上",
				"豁口拿木栅拦上，砖头堆在墙根。工房的人把炮图收起来，守备再没来过。那年秋天，墙根下的草长到了栅栏顶。",
				[
					Shared.knowledge(-2, 360),
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
				]),
		],
	}))

	# ═══ 蒸汽 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_TECH_STEAM),
		"title": "{settlement_name}·蒸汽房",
		"body_text": "蒸汽机搬进工场那天，房梁震了一整天。织机转得快了，女工的手跟不上，断线接不过来。罗阿石算了一笔账：机器烧的煤比人工贵，可出的布多。隔壁的织户来看了两回，回去把自己的机子砸了。李七站在门口，看了一会儿，说这机器一天吃多少煤。罗阿石没答，把炉门添了一铲。",
		"image_key": "country.technology",
		"ai_visual_prompt": "A steam engine inside a weaving workshop, trembling beams, a broken handloom next door, coal shovel by the furnace",
		"tags": ["tech", "labor", "market"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 6,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.HAS_TECHNOLOGY, "target_key": "tech.steam_power"},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "artisan", "float_value": 0.08},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
				"add_weight": 20,
				"multiplier_q16": MUL_120,
				"reason": "有工场才装得下机器",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "artisan", "float_value": 0.12},
				"add_weight": 15,
				"reason": "织户多，才有人被机器挤掉",
			},
		],
		"options": [
			Shared.option(
				"build_the_mill", "把厂办起来",
				"厂房的烟囱立起来",
				"厂房的烟囱立起来，煤从城外一车一车运。布一匹一匹堆进仓里，织户的机子一台一台停。罗阿石在账房坐到半夜，把工钱算到每一匹布上。",
				[
					Shared.cash_out(2.0, 360),
					Shared.manufacturing(5, 540),
				]),
			Shared.gamble(
				"share_with_weavers", "让织户合营",
				Shared.branch(39322, "织户入了股", # 60%
					"织户入了股，机器还是那台，织机多了二十张。李七把第一年的红利用纸包着发下去，纸包上写着各家的姓。",
					[
						Shared.cash_in(1.0, 360),
						Shared.manufacturing(3, 540),
						Shared.trade_capacity(3, 540),
					]),
				Shared.branch(26214, "织户退了股", # 40%
					"织户退了股，把股钱拍在柜台上。机器照转，厂里少了二十张手织机。罗阿石把退股的字据叠好，压在账本底下。",
					[
						Shared.cash_out(1.5, 360),
						Shared.manufacturing(-3, 360),
						Shared.bias(Ids.TAG_UNREST, 1.25, 540),
					])),
			Shared.option(
				"wait_and_watch", "暂时不收",
				"机器用布盖起来",
				"机器用布盖起来，煤堆在墙角。罗阿石说再等等，等织户想明白。李七说等他们想明白，布早就堆在仓里卖不动。",
				[
					Shared.knowledge(-2, 360),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
		],
	}))

	# ═══ 铁路 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_TECH_RAIL),
		"title": "{settlement_name}·车站",
		"body_text": "铁路修到城外，站台是一片夯土。通车头一天，来看的人挤满了坡。韩仓说，往后粮不用车马了；赶车的把式站在人群外，手里还攥着鞭子。李七去问运费，回来的时候脸色不好，说比车马便宜一半。坡上的人还在数车厢，一节一节地数。火车头冒出的白气，把站台罩住了。",
		"image_key": "country.technology",
		"ai_visual_prompt": "A rammed-earth station platform on opening day, a carter holding his whip outside the crowd, white steam over the platform",
		"tags": ["tech", "market", "rail"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 7,
		"max_era_index": 9,
		"conditions": [
			{"op": Op.HAS_TECHNOLOGY, "target_key": "tech.rail_logistics"},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.03},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.05},
				"add_weight": 20,
				"multiplier_q16": MUL_125,
				"reason": "商人多，货就多",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 5},
				"add_weight": 15,
				"reason": "城大，站才养得住",
			},
		],
		"options": [
			Shared.option(
				"build_the_warehouse", "先建货栈",
				"货栈挨着站台",
				"货栈挨着站台，粮包从车厢直接扛进去。韩仓在门口记账，笔没停过。赶车的把式把鞭子挂在墙上，再没取下来。",
				[
					Shared.cash_out(2.0, 360),
					Shared.manufacturing(4, 540),
				]),
			Shared.option(
				"retrain_the_carters", "让把式转行",
				"鞭子换成了秤",
				"把式转行去扛包，鞭子换成秤。李七给他们发了工钱，说往后靠力气吃饭。有人干了一个月，还是回乡下租了头驴。",
				[
					Shared.cash_in(1.0, 360),
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
				]),
			Shared.option(
				"wait_and_see", "不建，先看",
				"站台还是夯土",
				"站台还是夯土，货堆在露天，下雨就盖席。李七说再等等，等运费落定。火车一天过两趟，没停。",
				[
					Shared.knowledge(-2, 360),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
		],
	}))

	# ═══ 化肥 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_TECH_FERTILIZER),
		"title": "{settlement_name}·地力",
		"body_text": "肥田粉从城里运来，一袋一袋码在祠堂门口。苗大抓了一把闻，说味道像硝。农技员说一亩撒多少有定数，撒多了烧苗。第一块田试下来，稻秆比往年高出一截，可地里的蚯蚓少了。石宝把土翻开，看了半天。他把土放回原处，拍了拍手上的泥。苗大问他看出什么，石宝说土里有虫。",
		"image_key": "climate.rain",
		"ai_visual_prompt": "Fertilizer sacks stacked by a clan hall, an old farmer smelling a handful, a spade turning over soil with few worms",
		"tags": ["tech", "agriculture", "land"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 8,
		"max_era_index": 10,
		"conditions": [
			{"op": Op.HAS_TECHNOLOGY, "target_key": "tech.synthetic_fertilizer"},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "agricultural_worker", "float_value": 0.10},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 20},
				"add_weight": 20,
				"multiplier_q16": MUL_115,
				"reason": "人多，地不够种",
			},
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "wheat_grain", "float_value": 1.15},
				"add_weight": 15,
				"reason": "粮价高，才舍得下本",
			},
		],
		"options": [
			Shared.option(
				"spread_it", "全面推广",
				"田里都撒了肥",
				"田里都撒了肥，稻秆高过膝盖。第一年收成好，第二年土发硬，犁要往下多压两寸。石宝说这土像是被抽干了。",
				[
					Shared.cash_out(2.0, 360),
					Shared.agriculture(5, 540),
				]),
			Shared.option(
				"half_first", "先试一半",
				"一半田撒，一半不撒",
				"一半田撒，一半不撒。秋收的时候，两块田的稻穗差了一截。苗大把两把稻穗并排放在祠堂门口，让人自己看。",
				[
					Shared.cash_in(1.0, 360),
					Shared.agriculture(2, 540),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
			Shared.option(
				"leave_it", "先放着不用",
				"肥袋堆在祠堂角落",
				"肥袋堆在祠堂角落，袋子受了潮，结成一团。农技员来问过两回，没人应。那年冬天，蚯蚓又回到了田里。",
				[
					Shared.agriculture(-3, 360),
					Shared.knowledge(1, 360),
				]),
		],
	}))
