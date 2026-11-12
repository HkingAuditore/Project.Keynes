class_name NarrativeEventCatalogTown
extends RefCounted

## 市井：八条孤立事件，写一条街上的纠纷、脸面、规矩和钱（不接链条，单条收束）。
##
##   更夫 · 丐头 · 私钱 · 火 · 摊 · 谣言 · 出殡 · 井水
##
## 这一包全部是脉冲入口；八条各带两三条权重规则，随建筑、职业构成、价格、时代、满意度浮动。
## 代价货币刻意错开：钱、名声、产能、民心、未来；每条的三个选项付的账都不一样。

const Ids = preload("res://scripts/narrative/narrative_event_ids.gd")
const Shared = preload("res://scripts/narrative/narrative_event_shared.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")

const PACK_ID := &"town"
const PREFIX := "evt.town."

const CAST := [
	"翟老卯", "宗有粮", "卫长庚", "韩天增", "郑五斗", "卞四娘", "潘玉枝", "蔡四", "甘氏", "荀德茂", "蒯阿六", "屈老康",
	"桦树巷", "石灰巷", "砖桥口", "北门更楼", "甜水井", "永济号", "三和栈", "公顺堂", "义盛杠房", "公匣",
]

const MUL_075 := 49152
const MUL_080 := 52429
const MUL_085 := 55706
const MUL_105 := 68813
const MUL_110 := 72090
const MUL_115 := 75366
const MUL_120 := 78643
const MUL_125 := 81920
const MUL_130 := 85197
const MUL_135 := 88474


static func meta() -> Dictionary:
	return {
		"id": PACK_ID,
		"title": "市井",
		"theme": "一条街上的规矩",
		"era_band": "2-9",
		"prefix": PREFIX,
		"scale": "8 条中观/微观孤立",
		"cast": CAST,
		"node_ids": [
			String(Ids.EVT_TOWN_NIGHT_WATCH),
			String(Ids.EVT_TOWN_BEGGAR_GUILD),
			String(Ids.EVT_TOWN_FALSE_COIN),
			String(Ids.EVT_TOWN_FIRE),
			String(Ids.EVT_TOWN_STALL_FIGHT),
			String(Ids.EVT_TOWN_RUMOR),
			String(Ids.EVT_TOWN_GUILD_FUNERAL),
			String(Ids.EVT_TOWN_WELL_DISPUTE),
		],
	}


static func append(catalog) -> void:
	if catalog == null:
		return
	var Op = NarrativeConditionScript.Op
	var Ch = NarrativeEventDefinitionScript.TriggerChannel

	# ═══ 更夫 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_TOWN_NIGHT_WATCH),
		"title": "{settlement_name}·更夫",
		"body_text": "北门更楼的梆子一夜敲五遍，翟老卯敲了四十一年，今年入冬左膝先不听话。砖桥口入秋丢了三回东西：永济号丢了一串钱，三和栈丢挂在檐下的两块腊肉，公顺堂丢的是一屉药材。韩天增在柜台后头算完账，说添一个人，按铺面大小摊，一家摊得下来；这钱让郑五斗去收，收上来先补他去年垫的。翟老卯听见「添一个人」，把手从膝盖上拿开，说这活他孙子也能干。郑五斗没接话，低头把算盘珠子归到一边。散场时翟老卯把梆子从钉子上取下来，用袖子擦了一遍，又挂回去，挂得比原来高半寸。",
		"image_key": "family.house",
		"ai_visual_prompt": "A night watchman with a wooden clapper in a gate tower, shopkeepers counting coins below, a constable with an abacus",
		"tags": ["town", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 2,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 12},
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
				"add_weight": 20,
				"reason": "街巷多了，火烛也多",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.03},
				"add_weight": 0,
				"multiplier_q16": MUL_120,
				"reason": "铺子怕偷",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 7},
				"add_weight": 0,
				"multiplier_q16": MUL_075,
				"reason": "街口装了电灯，梆子显得多余",
			},
		],
		"options": [
			Shared.option(
				"tax_the_shops", "按铺面摊钱，添一班",
				"二更多了一个人",
				"新来的那个是翟老卯的孙子，十六岁，梆子拿在手里嫌沉。头一夜他跟在后头，只敲了半条街，另一半是他爷敲的。铺子门口的灯比上月多亮了半个时辰。",
				[
					Shared.cash_in(1.5, 540, "向本地人数最多的{primary_profession}征收其现金的 1.5%（铺捐转拨更夫）"),
					Shared.manufacturing(3, 540),
					Shared.bias(Ids.TAG_UNREST, 0.85, 540),
				]),
			Shared.option(
				"let_the_family_watch", "叫翟老卯带孙子守夜",
				"梆子还是那个梆子",
				"爷孙俩分前后半夜，孙子走东边，走到砖桥口就回头。第一场雪后，三和栈的檐下又少了一块腊肉。掌柜的没报官，第二天把狗牵进了院子。",
				[
					Shared.cash_out(1.0, 360),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
			Shared.option(
				"wait_until_spring", "先不添，敲到开春",
				"开春再说",
				"腊月里砖桥口又丢了两回，丢的都是挂在门外的东西。翟老卯照旧一夜五遍，走到没灯的巷口就停下来，把梆子敲得急一点，再往回走。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.30, 720),
					Shared.manufacturing(-3, 540),
				]),
		],
	}))

	# ═══ 丐头 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_TOWN_BEGGAR_GUILD),
		"title": "{settlement_name}·丐头",
		"body_text": "砖桥口的石阶空了。宗有粮把三个瞎眼乞丐领到巷子外头，一人发了一条旧席。永济号给了，三和栈给了，公顺堂拖了三天，第四天门槛上就躺了个烂腿的。韩天增把钱数好，拿纸包上，说这钱给得比丢的少。郑五斗听说这事，第二天到巷口从早坐到晚，问宗有粮收的是哪一门的钱。宗有粮把破碗在手里转了一圈，说收的是扫地的钱。当夜下雪，石阶上扫得干干净净，一个人也没有。",
		"image_key": "family.house",
		"ai_visual_prompt": "A beggar chief with a cracked bowl on stone steps, shopkeepers handing wrapped coins, a constable watching from the lane",
		"tags": ["town", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 2,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 12},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.001},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.04},
				"add_weight": 20,
				"reason": "铺子门前要干净",
			},
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "wheat_grain", "float_value": 1.15},
				"add_weight": 0,
				"multiplier_q16": MUL_130,
				"reason": "米贵了，街上的人多起来",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 5},
				"add_weight": 0,
				"multiplier_q16": MUL_085,
				"reason": "巡警房管得过来了",
			},
		],
		"options": [
			Shared.option(
				"accept_the_rule", "认下规矩，巷外划地",
				"巷子外多了一块席子地",
				"郑五斗在巷外的空地上划了界，铺了三条旧席。宗有粮把最会闹的几个安置在界里，剩下的自己走。腊月里雪大，席子上的人挤成一堆，铺子里的灯照不到那里。",
				[
					Shared.manufacturing(3, 540),
					Shared.cash_in(1.0, 540, "向本地人数最多的{primary_profession}征收其现金的 1%（铺子那笔钱里抽一份）"),
					Shared.bias(Ids.TAG_UNREST, 0.80, 540),
				]),
			Shared.option(
				"drive_him_out", "抓了宗有粮，赶出城",
				"城门口多了一排人",
				"差役把宗有粮架出城门，破碗掉在门槛上，碎了。天没亮，城门外的人把扁担横在膝上，隔着门洞往里看。门内的石阶空着，没人扫雪。",
				[
					Shared.cash_out(1.5, 360),
					Shared.bias(Ids.TAG_UNREST, 1.35, 720),
					Shared.manufacturing(-3, 540),
				]),
			Shared.option(
				"look_the_other_way", "不认也不抓，看着",
				"两张纸贴在墙上",
				"衙门的告示贴在巷口，写的是禁乞；宗有粮的人在旁边贴了一张，写的是施粥的日子。头一张被人撕了，撕得不干净，边角还挂着。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.20, 720),
					Shared.manufacturing(2, 540),
				]),
		],
	}))

	# ═══ 私钱 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_TOWN_FALSE_COIN),
		"title": "{settlement_name}·私钱",
		"body_text": "卫长庚的炉子在后院，白天不冒烟，夜里才点。他铸的钱比官钱厚一层，边上有锉过的痕，拿在手里压手。韩天增起初不肯收，收了一回，第二回就照他说的价换。永济号的柜台上摆着一只小秤，专门称这种钱。入秋官钱又薄了一层，市上买米要多搭一把钱，卫长庚的炉子就再没熄过。郑五斗带着两个差役来过一次，站在院墙外闻了半天烟味，没敲门。卫长庚把新出的一串钱埋进灶灰里，埋完把手在裤子上擦了擦。",
		"image_key": "country.economy",
		"ai_visual_prompt": "A secret coin furnace smoking at night behind a house, thick coins on a small scale in a shop, an official sniffing outside the wall",
		"tags": ["town", "market", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 720,
		"min_era_index": 3,
		"max_era_index": 7,
		"conditions": [
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.02},
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.04},
				"add_weight": 20,
				"reason": "钱在铺子里过手最多",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 5},
				"add_weight": 0,
				"multiplier_q16": MUL_120,
				"reason": "官钱越铸越薄",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
				"add_weight": 10,
				"reason": "炉子藏在后院，烟从墙头出去",
			},
		],
		"options": [
			Shared.option(
				"take_the_furnace", "收炉入官，铸官钱",
				"官炉搬到前院",
				"官炉挪到前院，门口挂了牌，卫长庚成了炉头。头一炉出的钱还是厚，第三炉就照官样薄下去。他把锉刀搁在架子上，没再动。",
				[
					Shared.cash_out(2.0, 720),
					Shared.country_sector("manufacturing", 3, 540),
					Shared.bias(Ids.TAG_UNREST, 0.85, 540),
					Shared.bias(Ids.TAG_LABOR, 1.10, 540),
				]),
			Shared.option(
				"seal_the_furnace", "封炉，照律办",
				"炉子拆了",
				"差役把炉膛拆开，砖还烫，水泼上去冒白气。卫长庚站在一边看，手里捏着一枚没锉完的钱。捏到散场，边角在他掌心压出一道红印。",
				[
					Shared.stock("wrought_iron", 15),
					Shared.manufacturing(-4, 540),
					Shared.bias(Ids.TAG_UNREST, 1.30, 720),
				]),
			Shared.option(
				"pretend_not_to_know", "装不知道",
				"秤摆在明处",
				"永济号的小秤挪到了柜台面上，谁的钱都称一称。郑五斗再来，只在门口站了站，问今年秋税怎么收。韩天增说照收，收完把那串私钱单独串起来，放进另一个抽屉。",
				[
					Shared.cash_in(1.0, 540, "向本地人数最多的{primary_profession}征收其现金的 1%（秋税收进好钱）"),
					Shared.manufacturing(3, 540),
					Shared.bias(Ids.TAG_UNREST, 1.20, 720),
				]),
		],
	}))

	# ═══ 火 ═══════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_TOWN_FIRE),
		"title": "{settlement_name}·火",
		"body_text": "火从石灰巷的草棚起，风把火头往东推。卞四娘把豆腐坊的门板卸下来挡火，门板一烤就卷。砖桥口的水缸排成一行，一桶传一桶，传到第七个人手里只剩半桶。三和栈的掌柜在墙上喊，说仓里的粮够全城吃一冬；义盛杠房的蒯阿六抱着两根杠子站在门口，说杠子烧了，这个月死人拿什么抬。风忽然转了半圈，火头贴着瓦檐往北走。卞四娘回头看自己那盘石磨，磨盘上压着一块湿布，是她出门时盖上的。",
		"image_key": "map.construction",
		"ai_visual_prompt": "A street fire at night, door planks used as shields, a bucket line from water vats, a woman looking back at her millstone",
		"tags": ["town", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 720,
		"min_era_index": 3,
		"max_era_index": 9,
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
			{"op": Op.POPULATION_GTE, "int_value": 15},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 5},
				"add_weight": 25,
				"reason": "木屋挨着木屋",
			},
			{
				"condition": {"op": Op.ERA_LTE, "int_value": 4},
				"add_weight": 0,
				"multiplier_q16": MUL_120,
				"reason": "还没有救火的机器",
			},
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "wheat_grain", "float_value": 1.10},
				"add_weight": 0,
				"multiplier_q16": MUL_115,
				"reason": "粮贵，仓里堆得满",
			},
		],
		"options": [
			Shared.option(
				"pull_down_the_east_row", "拆东头的屋，断火路",
				"一条空巷",
				"六间屋半天拆完，梁木拖到街心，火到空地上就矮了。卞四娘的石磨保住了，磨盘上那块湿布烤干，粘在石头上，撕下来带了一层灰。拆屋的人家把门框扛走，说开春再立。",
				[
					Shared.cash_out(2.0, 540),
					Shared.manufacturing(3, 540),
					Shared.build_cost(4, 540),
					Shared.bias(Ids.TAG_UNREST, 1.10, 540),
				]),
			Shared.option(
				"save_the_granary", "全扑三和栈的仓",
				"仓门熏黑了，粮是干的",
				"人全压到仓墙下，水一桶桶往瓦上泼，瓦炸了好几块。火绕过仓，从杠房那侧过去，杠子烧成炭，横在门口。卞四娘回去时，豆腐坊只剩半堵墙，石磨还在，裂了一道。",
				[
					Shared.staple(-5, 540),
					Shared.manufacturing(-4, 540),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
			Shared.gamble(
				"bet_on_the_wind", "赌风会停，先守着",
				Shared.branch(39322, "火在空地上矮下去", # 60%
					"火头蹿到巷尾的柴堆，烧了一阵，自己矮了。天亮时清点，只烧掉草棚、柴堆和两间偏房。卞四娘把湿布从磨盘上揭下来，布还湿着。",
					[
						Shared.manufacturing(-2, 360),
						Shared.staple(3, 360),
						Shared.bias(Ids.TAG_UNREST, 1.05, 360),
					]),
				Shared.branch(26214, "风从北边转回来", # 40%
					"风转回来的时候，人还压在仓墙下。火顺着瓦檐过了桦树巷，铺子的门板一间间烧穿。卞四娘的石磨裂成两半，磨眼里的粮食烧成了炭。",
					[
						Shared.manufacturing(-6, 720),
						Shared.staple(6, 540),
						Shared.birth(-5, 540),
					])),
		],
	}))

	# ═══ 摊 ═══════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_TOWN_STALL_FIGHT),
		"title": "{settlement_name}·摊",
		"body_text": "砖桥口的拐角只摆得下两个摊子。潘玉枝的卤煮锅占了里侧，地钱按月交给郑五斗，收条压在锅底下的瓦片下。蔡四的茶炉是上个月推来的，摆在桥栏边上，比她的锅靠外半步，挑夫卸了货就蹲在他那边喝。潘玉枝把收条抽出来，纸角已经油透。蔡四说他不知道这块地要交钱，知道了也不交，他一天卖不出几碗。郑五斗来得晚，站在两个摊子中间，先看锅，再看炉子。潘玉枝把勺子往锅沿上一磕，卤汤溅出来一点，落在她自己的鞋面上。",
		"image_key": "country.economy",
		"ai_visual_prompt": "Two food stalls squeezed into a bridge corner, a stew pot and a tea stove, a constable standing between them",
		"tags": ["town", "market"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 85,
		"cooldown_days": 720,
		"min_era_index": 2,
		"max_era_index": 7,
		"conditions": [
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.02},
			{"op": Op.POPULATION_GTE, "int_value": 12},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.05},
				"add_weight": 20,
				"reason": "摊子挤在桥口",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
				"add_weight": 0,
				"multiplier_q16": MUL_115,
				"reason": "街面窄，好位置就那几个",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 6},
				"add_weight": 0,
				"multiplier_q16": MUL_120,
				"reason": "巡警房开始管占道",
			},
		],
		"options": [
			Shared.option(
				"honour_the_receipt", "照收条办，挪走一家",
				"炉子挪进巷子",
				"蔡四把炉子挪进去，一早上烧不开一壶。挑夫还是往巷子里拐，靠着巷墙喝，喝完把碗放在地上。潘玉枝的锅前空出一块地，她拿水冲了三遍。",
				[
					Shared.cash_in(1.0, 540, "向本地人数最多的{primary_profession}征收其现金的 1%（摊地钱照收）"),
					Shared.manufacturing(2, 540),
					Shared.bias(Ids.TAG_UNREST, 1.10, 540),
				]),
			Shared.option(
				"draw_a_line", "划中线，两家都交",
				"地上划了一道白线",
				"郑五斗用石灰在地上划了一道线，两家各守一边。头三天没人越线，第四天挑夫把担子横在线上，两家一起骂他。潘玉枝把多交的那份钱记在收条背面，说开春再算。",
				[
					Shared.cash_in(1.5, 540, "向本地人数最多的{primary_profession}征收其现金的 1.5%（两家都交地钱）"),
					Shared.staple(3, 540),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
			Shared.option(
				"let_them_quarrel", "让他们吵，等收摊",
				"拐角空了",
				"吵了半个月，潘玉枝把锅搬回家，说等开春。蔡四的炉子还在桥栏边，火一天比一天小。入冬第一场雪，拐角上只剩一圈黑印，是锅底留下的。",
				[
					Shared.manufacturing(-3, 540),
					Shared.bias(Ids.TAG_UNREST, 1.25, 720),
				]),
		],
	}))

	# ═══ 谣言 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_TOWN_RUMOR),
		"title": "{settlement_name}·谣言",
		"body_text": "话是甘氏在井台边说的：三和栈的粮要装船往北调。她只说了一句，听的人替她补了三句，补到下午，成了「官仓已经空了，明日封门」。公顺堂的甘草一天卖空两屉，说能安神；永济号门前排了队，有人把压箱底的铜钱拿出来换米。三和栈的掌柜把仓门开了半天，让人伸头看，看的人出来还是不信。甘氏傍晚去井台打水，绳放下去，桶碰到水面的声音比昨天空。她把桶提上来，水里浮着一片草叶，她捞出来，弹掉了。",
		"image_key": "country.economy",
		"ai_visual_prompt": "A crowd queuing outside a grain shop, a woman at a well with a bucket, empty medicine drawers in an apothecary",
		"tags": ["town", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 720,
		"min_era_index": 2,
		"max_era_index": 9,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 12},
			{"op": Op.COHORT_SATISFACTION_LTE, "float_value": 0.55},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.SATISFACTION_LTE, "float_value": 0.45},
				"add_weight": 0,
				"multiplier_q16": MUL_125,
				"reason": "心里本来就有火",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.04},
				"add_weight": 15,
				"reason": "铺子里的话传得快",
			},
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "wheat_grain", "float_value": 1.15},
				"add_weight": 20,
				"reason": "米价一抬头，什么话都有人信",
			},
		],
		"options": [
			Shared.option(
				"open_the_granary", "开仓，让人自己看",
				"仓门开了半天",
				"仓门开在东墙，人排着进去，出来时手里抓一把谷子给人看。米价当天落了回去，永济号门前的队散了一半。管仓的老吏把仓门重新锁上，锁了两遍，钥匙揣进怀里按了按。",
				[
					Shared.staple(-5, 540),
					Shared.manufacturing(-3, 540),
					Shared.research_signal("breakthrough.printing", "印版告示"),
				]),
			Shared.option(
				"arrest_the_woman", "抓甘氏，押在衙门口",
				"井台上没人说话了",
				"甘氏在衙门口站了半天，脖子上挂了块纸牌。放回来那天，她照旧去井台打水，旁边的人让开半步，谁也没问。第二天井台上换了个生面孔在说话，说的还是粮。",
				[
					Shared.cash_out(1.0, 360),
					Shared.bias(Ids.TAG_UNREST, 1.35, 720),
					Shared.manufacturing(2, 360),
				]),
			Shared.option(
				"let_it_cool", "不理会，等它自己凉",
				"米价自己往上走",
				"队越排越长，前头的人把钱攥在掌心，轮到了才递过去。第三天三和栈换了价牌，牌是新写的，字比原来大。甘氏没再去排队，把家里的缸挪到墙角，缸底还剩一层。",
				[
					Shared.staple(6, 720),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
					Shared.manufacturing(-3, 540),
				]),
		],
	}))

	# ═══ 出殡 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_TOWN_GUILD_FUNERAL),
		"title": "{settlement_name}·出殡",
		"body_text": "荀德茂死在霜降前两天，义盛杠房的杠子擦了三遍。行会的人在他家院里站了一圈，执事说会首送出去得有三十六杠，鼓乐请两班，幡上的字请人写。公匣里的钱是各铺按月攒的，本来预备给死在家里的匠人买棺材、给寡妇发米。荀家的女人坐在门槛上，手里攥着块白布，说三十六杠她抬不动，也不用抬。蒯阿六把名单折起来塞进袖口，数着杠子，数到第十八根，忽然想起自己这个月还没开张。执事把公匣从柜上搬下来，放在桌上，说这钱今天得动。",
		"image_key": "family.house",
		"ai_visual_prompt": "A guild funeral courtyard with stacked carrying poles, an old woman with a key ring on the threshold, an apprentice counting poles",
		"tags": ["town", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 85,
		"cooldown_days": 720,
		"min_era_index": 2,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "artisan", "float_value": 0.08},
			{"op": Op.POPULATION_GTE, "int_value": 12},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.001},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "artisan", "float_value": 0.12},
				"add_weight": 20,
				"reason": "行会人多，排场就有人看",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 6},
				"add_weight": 0,
				"multiplier_q16": MUL_085,
				"reason": "杠房改用马车，排场省了",
			},
			{
				"condition": {"op": Op.SATISFACTION_LTE, "float_value": 0.55},
				"add_weight": 15,
				"reason": "匠人心里有气，丧事容易出事",
			},
		],
		"options": [
			Shared.option(
				"full_pomp", "按会首的排场办",
				"三十六杠出了巷",
				"三十六杠抬出桦树巷，幡上的字是请公顺堂的账房写的，写坏了三张纸。鼓乐两班在桥口对着吹，吹到第三通，前一班的人先走了。蒯阿六抬最后一杠，肩上的垫布磨破了，他换了另一边。",
				[
					Shared.cash_out(2.0, 540),
					Shared.stock("paper", 10),
					Shared.manufacturing(3, 360),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
			Shared.option(
				"keep_the_fund", "省下排场，钱留公匣",
				"杠子只用了八根",
				"出殡那天只用了八根杠，鼓乐一班，幡上的字是蒯阿六自己描的，描得歪。路两头站了些看的人。荀家的女人把公匣的簿子交给执事，说这账明年再看。",
				[
					Shared.cash_out(1.0, 360),
					Shared.bias(Ids.TAG_UNREST, 0.85, 540),
					Shared.research_signal("breakthrough.industrial_organization", "公匣与帮工章程"),
					Shared.bias(Ids.TAG_LABOR, 1.10, 540),
				]),
			Shared.option(
				"wait_three_days", "停灵三天，等各家凑",
				"三天后抬出去",
				"停了三天，院里点着香，来的人一拨比一拨少。第四天早上抬出去，杠子只用了四根。执事把借出去的钱记在簿子后头，写完把笔在砚台上按了按，没盖印。",
				[
					Shared.manufacturing(-4, 360),
					Shared.bias(Ids.TAG_UNREST, 1.30, 720),
					Shared.cash_in(1.0, 540, "向本地人数最多的{primary_profession}征收其现金的 1%（各家凑的丧仪，抽一份入官）"),
				]),
		],
	}))

	# ═══ 井水 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_TOWN_WELL_DISPUTE),
		"title": "{settlement_name}·井水",
		"body_text": "甜水井的水一天比一天低，桶放到底，提上来半桶泥。屈老康在自家院墙后头挖了一条沟，把坡上那股水引进菜地，沟沿拍得光光的。桦树巷的人天不亮去排队，排到第三家就没水，甘氏把衣裳端回家，用洗过菜的水又洗一遍。巷里推了两个人去找屈老康，他站在沟边，说沟挖在自家地里，谁家没个菜园。有人提出来要断他的沟，也有人说断了他家菜地，秋天的菜钱谁赔。甘氏没跟去，坐在井台上把井绳一圈圈绕好，绳头打了个结，比昨天多绕一圈。",
		"image_key": "hydrology.water",
		"ai_visual_prompt": "A shallow well with muddy water, a hand-dug ditch running to a vegetable plot, neighbours arguing at the well platform",
		"tags": ["town", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 720,
		"min_era_index": 2,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 14},
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
				"add_weight": 20,
				"reason": "巷子两头都盖了房",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 6},
				"add_weight": 0,
				"multiplier_q16": MUL_085,
				"reason": "接了水管，井不那么要紧",
			},
			{
				"condition": {"op": Op.SATISFACTION_LTE, "float_value": 0.55},
				"add_weight": 0,
				"multiplier_q16": MUL_120,
				"reason": "心里有火，为半桶水也能打起来",
			},
		],
		"options": [
			Shared.option(
				"cut_the_ditch", "断沟，水还给井",
				"沟填了",
				"沟填了半天，土拍实，屈老康站在边上看，手里捏着一把菜秧。水回到井里，要三天才见涨。甘氏头一个打水，桶提上来是清的，倒在盆里，盆底没有泥。",
				[
					Shared.cash_out(1.0, 360),
					Shared.agriculture(-4, 540),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
			Shared.option(
				"dig_a_second_well", "屈家出井钱，另打一口",
				"第二口井打在下游",
				"井打在下游的墙根，挖了半个月见水，水是咸的，能洗不能喝。屈老康把钱交了两份，交完扶着沟沿的木桩看了半天，没把沟填回去。桦树巷的人还是天不亮去甜水井排队，只是不再骂他。",
				[
					Shared.cash_in(1.5, 540, "向本地人数最多的{primary_profession}征收其现金的 1.5%（按户摊井钱）"),
					Shared.manufacturing(3, 540),
					Shared.build_cost(4, 540),
				]),
			Shared.option(
				"post_a_schedule", "贴张排班纸，轮着来",
				"纸被撕了",
				"纸是郑五斗写的，贴在井台的木柱上，写明了时辰。第三天早上纸没了，柱子上留着一圈浆糊印。屈老康的沟还在，水从沟里过，绕过井台往菜地去。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.30, 720),
					Shared.manufacturing(-3, 540),
				]),
		],
	}))
