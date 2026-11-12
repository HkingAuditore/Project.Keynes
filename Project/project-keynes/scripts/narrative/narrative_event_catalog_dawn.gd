class_name NarrativeEventCatalogDawn
extends RefCounted

## 黎明包：era 0–2 的七条孤立事件。
##
##   圈墙（第一道墙）/ 分地（博弈）/ 公井 / 集市 / 铁匠 / 盟誓 / 械斗。
##   七条全是脉冲入口，不接链、不写标记；都带两三条权重规则，吃建筑、职业、
##   价格、湿度、满意度分层。
##
## 代价货币刻意错开，同一事件的三条选项各付一种：
##   墙=人头摊派 / 误农时 / 粮价；地=摊派+风险 / 人心 / 农时；
##   井=误工 / 人心 / 孩子；市=秩序 / 货量 / 粮价；
##   匠=守夜人不平 / 农时 / 摊派；誓=人口 / 口粮 / 人心；斗=人心 / 公账 / 农时。

const Ids = preload("res://scripts/narrative/narrative_event_ids.gd")
const Shared = preload("res://scripts/narrative/narrative_event_shared.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")

const PACK_ID := &"dawn"
const PREFIX := "evt.dawn."

const CAST := [
	"阿禾", "石伯", "老陶", "谷生", "阿雉", "泥鳅",
	"青背岭", "滩头", "界石", "陶罐",
]

const MUL_110 := 72090
const MUL_115 := 75366
const MUL_120 := 78643
const MUL_130 := 85197


static func meta() -> Dictionary:
	return {
		"id": PACK_ID,
		"title": "黎明",
		"theme": "谁圈墙、谁分地、谁先打水",
		"era_band": "0-2",
		"prefix": PREFIX,
		"scale": "7 条中观/微观孤立",
		"cast": CAST,
		"node_ids": [
			String(Ids.EVT_DAWN_FIRST_WALL),
			String(Ids.EVT_DAWN_DIVIDE_FIELDS),
			String(Ids.EVT_DAWN_COMMON_WELL),
			String(Ids.EVT_DAWN_FIRST_MARKET),
			String(Ids.EVT_DAWN_FIRST_SMITH),
			String(Ids.EVT_DAWN_OATH_STONE),
			String(Ids.EVT_DAWN_WATER_BRAWL),
		],
	}


static func append(catalog) -> void:
	if catalog == null:
		return
	var Op = NarrativeConditionScript.Op
	var Ch = NarrativeEventDefinitionScript.TriggerChannel

	# ═══ 第一道墙 ═════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_DAWN_FIRST_WALL),
		"title": "{settlement_name}·第一道墙",
		"body_text": "青背岭下这片屋，东头没遮没拦，夜里风从坡上直灌进来。石伯主张圈一道石墙，说开春前丢过两只羊，脚印一直通到滩头。石头在河滩上，一块一块背上来，背一天够垒三尺。谷生不干，说地里正忙，抽人去背石头，秋后要少收两成。老陶算的是另一笔，墙一围，墙外那几块地就没人敢种。三个人蹲在墙基上争到天黑，石伯把第一块石头搬正，手掌在上面按了按。",
		"image_key": "map.construction",
		"ai_visual_prompt": "Villagers stacking a low stone wall around a settlement at dawn, stones carried up from a river beach, a half-dug ditch beside the wall base",
		"tags": ["dawn", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 0,
		"max_era_index": 2,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 8},
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 1},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
				"add_weight": 20,
				"reason": "屋挤在一处，才圈得起来",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "agricultural_worker", "float_value": 0.45},
				"add_weight": 0,
				"multiplier_q16": MUL_120,
				"reason": "种地的人多，怕被抢",
			},
			{
				"condition": {"op": Op.COHORT_SATISFACTION_LTE, "float_value": 0.45},
				"add_weight": 15,
				"reason": "心里没底，就想圈起来",
			},
		],
		"options": [
			Shared.option(
				"build_it", "把墙垒起来",
				"墙垒到胸口高",
				"石头一块一块码上去，码到胸口高，墙根留了一道缝给孩子钻。谷生背了七天石头，秋收晚了三天。",
				[
					Shared.cash_in(1.0, 360),
					Shared.agriculture(3, 540),
					Shared.bias(Ids.TAG_UNREST, 0.90, 540),
				]),
			Shared.option(
				"dig_a_ditch", "挖沟，不垒墙",
				"沟比墙深",
				"沟挖了一人多深，土堆在里侧当埂。开春下雨，沟里积了水，泥鳅在里头摸鱼，摸回一裤腿。",
				[
					Shared.agriculture(-3, 360),
					Shared.manufacturing(2, 360),
					Shared.extraction(2, 360),
				]),
			Shared.option(
				"wait", "先不修，看看再说",
				"墙基长草了",
				"墙基放了一季，草从石缝里长出来。夜里坡上有动静，第二天羊少了一只，谁也没敢往滩头那边找。",
				[
					Shared.staple(3, 360),
					Shared.agriculture(2, 360),
				]),
		],
	}))

	# ═══ 分地（博弈）═══════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_DAWN_DIVIDE_FIELDS),
		"title": "{settlement_name}·分地",
		"body_text": "河湾那片好地，今年要分到各户名下。阿禾要按人头分，一户几口就几垄，说人多的家吃得多，分少了要饿。老陶要按户分，说户是老的、地也是老的，新来的分一份就走，地就荒了。两拨人在滩头量地，草绳拉了三遍，量出来的数对不上。谷生把草绳往地上一扔，说再量下去麦子都黄了。泥鳅趴在田埂上，用树枝在泥里一道一道划，划到最后自己也认不出哪道是哪家的。",
		"image_key": "economy.resource",
		"ai_visual_prompt": "Villagers measuring a river-bend field with a rope, wooden stakes driven into the soil, a child drawing lines in the mud",
		"tags": ["dawn", "land", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 720,
		"min_era_index": 1,
		"max_era_index": 2,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 10},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "agricultural_worker", "float_value": 0.30},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "agricultural_worker", "float_value": 0.40},
				"add_weight": 20,
				"reason": "靠这块地吃饭的人多",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
				"add_weight": 15,
				"reason": "屋散在田边，各说各的地界",
			},
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "wheat_grain", "float_value": 1.15},
				"add_weight": 20,
				"multiplier_q16": MUL_110,
				"reason": "粮贵了，一分地都是口粮",
			},
		],
		"options": [
			Shared.gamble(
				"by_head", "按人头平分",
				Shared.branch(39322, "绳子量到最后一垄", # 60%
					"绳子量到最后一垄，天已经黑了。阿禾把自己那垄让给泥鳅家半分，第二天有人跟着让，也有人趁黑把地头的犁沟往外重犁了一尺。",
					[
						Shared.cash_in(1.0, 360),
						Shared.agriculture(5, 540),
					]),
				Shared.branch(26214, "绳子被人夺了", # 40%
					"第二次量地，两家人夺绳子，绳子断在中间。地没分成，麦子黄在地里，收了七成。",
					[
						Shared.cash_in(2.0, 360),
						Shared.birth(-5, 540),
					])),
			Shared.option(
				"by_household", "按户分，老户先挑",
				"界桩一早就埋好",
				"削尖的木桩天没亮就砸进土里，老户挑的是靠河的垄。新来的几家分到坡上，土薄，种一年就板结。谷生把自家那根木桩拔了，扛回滩头。",
				[
					Shared.agriculture(4, 540),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
					Shared.knowledge(2, 360),
				]),
			Shared.option(
				"common_plough", "先不分，合着种",
				"地还是那块地",
				"地还是那块地，谁家出几个人、收几成，全凭老陶一句话。第一年收得还行，第二年下种时没人肯先出种子。泥鳅家的那块田荒了半边，草长得比苗高。",
				[
					Shared.agriculture(-4, 360),
					Shared.knowledge(2, 360),
					Shared.manufacturing(2, 360),
				]),
		],
	}))

	# ═══ 公井 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_DAWN_COMMON_WELL),
		"title": "{settlement_name}·公井",
		"body_text": "坡下那口井，水甜，一桶提上来不洒。今年井壁塌了半边，得有人下去垒石。石伯说自己腰弯不下去，谷生说可以下，条件是先把井归谁定下来。阿雉天不亮就去打水，桶在井台上一溜排开，排到日头出来还没轮上她。有人说井归全寨，谁修谁先打；也有人说修的人出了力，水就该先紧着他家。阿雉把桶提回去，半桶水晃到门口只剩一瓢。",
		"image_key": "hydrology.water",
		"ai_visual_prompt": "A stone-lined well with a collapsed side, buckets queued on the well platform at dawn, a young woman carrying a half bucket home",
		"tags": ["dawn", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 0,
		"max_era_index": 2,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 10},
			{"op": Op.MOISTURE_LTE, "float_value": 0.50},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.MOISTURE_LTE, "float_value": 0.35},
				"add_weight": 25,
				"multiplier_q16": MUL_115,
				"reason": "地干，水比粮金贵",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
				"add_weight": 15,
				"reason": "屋离井远，排队的就多",
			},
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 16},
				"add_weight": 10,
				"reason": "人多，一桶水要分三家",
			},
		],
		"options": [
			Shared.option(
				"all_hands", "全寨出力，井归全寨",
				"井台砌了一圈石头",
				"井台砌了一圈石头，孩子趴在井沿数圈数。井归全寨，谁先到谁先打，日头出来前井边排着七八只桶。",
				[
					Shared.agriculture(-3, 360),
					Shared.birth(3, 540),
					Shared.manufacturing(2, 360),
				]),
			Shared.option(
				"one_household", "让一户包修，打水交粮",
				"井边多了个看井的人",
				"井边多了个看井的老汉，桶放下去要先交一捧粮或半张皮子。交了的人打满桶，不交的等到晌午，水浑了才轮上。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
					Shared.cash_in(1.5, 360),
					Shared.manufacturing(2, 360),
				]),
			Shared.option(
				"no_well", "不修了，去河里挑",
				"扁担压弯了两根",
				"扁担压弯了两根，挑一趟要半个时辰。阿雉挑水回来，路上歇三回，桶里的水晃出去一半，剩下的浑。",
				[
					Shared.birth(-4, 540),
					Shared.agriculture(2, 360),
				]),
		],
	}))

	# ═══ 集市 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_DAWN_FIRST_MARKET),
		"title": "{settlement_name}·集市",
		"body_text": "滩头那块平地，入秋支起了十几副摊子，盐、皮子、陶罐摆了一地。外地来的换盐人问，摆一天要交什么。老陶说这地是大家的，不该收；也有人说摊子踩坏了路、留下一地粪，总得有人扫。更麻烦的是秤：一根横木两头挂筐，各家的筐大小不一，一筐谷换一筐盐，换着换着就吵起来。阿禾提议让老陶管秤，说他的陶罐都是照一个模子做的。老陶把横木提起来掂了掂，没应。",
		"image_key": "country.economy",
		"ai_visual_prompt": "A first market on a river beach, hides, salt and clay pots laid out, a beam with two hanging baskets used as a scale",
		"tags": ["dawn", "market"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 1,
		"max_era_index": 2,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 12},
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "artisan", "float_value": 0.05},
				"add_weight": 20,
				"multiplier_q16": MUL_120,
				"reason": "有匠人，才有东西可换",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
				"add_weight": 15,
				"reason": "屋多了，各家缺的东西也多",
			},
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "salt", "float_value": 1.15},
				"add_weight": 15,
				"reason": "盐贵，远处的人才肯来",
			},
		],
		"options": [
			Shared.option(
				"free_stalls", "不收地租，谁来都摆",
				"摊子摆到了路中间",
				"摊子摆到路中间，人挤得推车过不去。换了三天，两家人为一个位置打起来，摊子翻了，盐撒了一地，扫到天黑才扫完。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
					Shared.trade_capacity(5, 540),
					Shared.manufacturing(3, 540),
				]),
			Shared.option(
				"fee_and_scale", "收地租，公家管秤",
				"横木上刻了道印",
				"横木上刻了一道印，一筐就是一筐。交过地租的摊子排在里头，没交的挪到外圈。老陶每天收工前把横木擦一遍，擦完挂回柱子上。",
				[
					Shared.manufacturing(-2, 360),
					Shared.cash_in(1.5, 360),
					Shared.trade_capacity(6, 540),
				]),
			Shared.option(
				"let_them_weigh", "各家自己的筐，各管各",
				"吵到日头偏西",
				"一筐谷换一筐盐，谁家的筐大谁占便宜。吵到日头偏西，谷子还是那堆谷子，盐少了半袋。阿禾把自己家的筐换成了小一号的。",
				[
					Shared.staple(3, 360),
					Shared.trade_capacity(4, 540),
					Shared.knowledge(2, 360),
				]),
		],
	}))

	# ═══ 铁匠 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_DAWN_FIRST_SMITH),
		"title": "{settlement_name}·铁匠",
		"body_text": "河滩上冲下来一块黑石头，砸开以后里头发亮，比骨头硬。谷生把它架在火上烧，烧红了拿石头砸了半天，敲出一小块能弯的黑片。寨里人都来看，问这东西做什么用。石伯说要打犁头，翻地能省一半力气；守夜的人说要打刀，坡上那些偷羊的才怕；老陶说要打钉子，屋梁和拉犁的木架都松了。三样东西，只有一块黑石头。谷生把石头放下，看火里那块还红着的黑片，谁也没先开口。",
		"image_key": "economy.resource",
		"ai_visual_prompt": "A black lump from a river beach heated in a fire and hammered on a stone, villagers arguing around the forge, a red-hot sliver of metal",
		"tags": ["dawn", "labor"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 900,
		"min_era_index": 1,
		"max_era_index": 2,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 10},
			{"op": Op.HAS_NATURAL_RESOURCE, "int_value": 1},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "miner", "float_value": 0.03},
				"add_weight": 20,
				"multiplier_q16": MUL_120,
				"reason": "有人认得石头里的东西",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
				"add_weight": 15,
				"reason": "屋要梁，车要轴，都缺硬家伙",
			},
			{
				"condition": {"op": Op.HAS_RIVER, "bool_value": true},
				"add_weight": 15,
				"reason": "河滩上冲下来的黑块不止一块",
			},
		],
		"options": [
			Shared.option(
				"plough_first", "先打犁头",
				"犁头套上了木架",
				"犁头套上木架，头一天翻的地比往年深半尺。守夜的人站在地头看，手里的木棍往地上戳了戳，没说话。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.10, 360),
					Shared.agriculture(5, 540),
					Shared.tools(-3, 360),
				]),
			Shared.option(
				"blade_first", "先打一把刀",
				"刀口开在石头上",
				"刀口在石头上开了三回，砍木棍不卷。坡上偷羊的那伙人半个月没露面，守夜的人夜里敢往远处走两步。",
				[
					Shared.agriculture(-3, 360),
					Shared.manufacturing(2, 360),
					Shared.research_signal("resource.iron_ore", "黑石"),
				]),
			Shared.option(
				"nails_first", "先打钉子",
				"屋梁上多了几个黑点",
				"屋梁和拉犁的木架上多了几个黑点，走起来不晃了。老陶把剩下的碎块收进陶罐，埋在自己床底下。",
				[
					Shared.cash_in(1.2, 360),
					Shared.manufacturing(4, 540),
					Shared.build_cost(3, 540),
				]),
		],
	}))

	# ═══ 盟誓 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_DAWN_OATH_STONE),
		"title": "{settlement_name}·盟誓",
		"body_text": "青背岭那头的猎户和滩头种地的人，为坡上的林子争了两年，打到第三回，两边都死了人。这回他们说，在坡顶那块卧石上盟誓。押什么却谈不拢：猎户要押孩子，一家出一个，住到对方屋里去；种地的只肯押牲口和明年的种子。阿禾说，押孩子是押给自家看的，押种子是押给天看的。老陶伸手按着卧石，用尖石把两家的记号凿上去，凿到一半，回头问要不要再凿一道横。",
		"image_key": "map.construction",
		"ai_visual_prompt": "Two kin groups swearing an oath at a boundary stone on a ridge, marks being chiselled into the stone, a goat and a sack of seed set beside it",
		"tags": ["dawn", "people"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 900,
		"min_era_index": 1,
		"max_era_index": 2,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 10},
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.COHORT_SATISFACTION_LTE, "float_value": 0.50},
				"add_weight": 20,
				"multiplier_q16": MUL_115,
				"reason": "两边心里都有旧账",
			},
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 16},
				"add_weight": 15,
				"reason": "人多了，界上的事就多",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
				"add_weight": 10,
				"reason": "有仓有屋，才押得起种子",
			},
		],
		"options": [
			Shared.option(
				"children", "各押一个孩子",
				"两个孩子换了屋",
				"两个孩子换了屋，头一个月谁也不肯吃饭。第二个月，猎户家的那个学会了扶犁，种地那家的那个学会了看脚印。",
				[
					Shared.birth(-4, 540),
					Shared.knowledge(3, 540),
					Shared.agriculture(2, 360),
				]),
			Shared.option(
				"beasts", "押牲口和明年的种子",
				"种子分了两份",
				"种子分两份，一份留在滩头，一份抬上青背岭。抬上去的那份被猎户家的孩子偷吃了半袋，两边又吵了一回，没动手。",
				[
					Shared.staple(3, 360),
					Shared.agriculture(3, 540),
					Shared.manufacturing(2, 360),
				]),
			Shared.option(
				"cut_only", "只在石头上刻道痕",
				"石头上多了一道横",
				"那块卧石上多了一道横，谁也没押东西。第一年两边各守各的，第二年坡上的林子又被砍了一小片，没人提那道横。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
					Shared.knowledge(2, 360),
					Shared.agriculture(2, 360),
				]),
		],
	}))

	# ═══ 械斗 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_DAWN_WATER_BRAWL),
		"title": "{settlement_name}·械斗",
		"body_text": "上游的人上月垒了一道石堰，把水拦进自家那片地。下游的田裂了口子，禾苗卷了叶。谷生带着十几个人上去，把堰扒开一个口子；上游的人拎着木棍下来，两边在河湾打了一场，断了三根棍子，一个人的胳膊折了。阿禾赶到时，两边还在对骂，堰上的口子正往外淌水。石伯顺着堰走过去，看了半天，伸手摸了摸那道口子的边。",
		"image_key": "hydrology.water",
		"ai_visual_prompt": "Two groups fighting with wooden staves at a breached stone weir on a river, cracked fields downstream, water pouring through the gap",
		"tags": ["dawn", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 720,
		"min_era_index": 1,
		"max_era_index": 2,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 12},
			{"op": Op.MOISTURE_LTE, "float_value": 0.40},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.MOISTURE_LTE, "float_value": 0.28},
				"add_weight": 25,
				"multiplier_q16": MUL_130,
				"reason": "旱得狠，水就是命",
			},
			{
				"condition": {"op": Op.HAS_RIVER, "bool_value": true},
				"add_weight": 20,
				"reason": "有河可抢，才打得起来",
			},
			{
				"condition": {"op": Op.SATISFACTION_LTE, "float_value": 0.45},
				"add_weight": 15,
				"reason": "肚子空着，棍子举得快",
			},
		],
		"options": [
			Shared.option(
				"cut_them_off", "把水断了",
				"堰上的口子扒开了",
				"堰被整个扒开，水顺着河床往下走，下游的田连夜灌了一遍。上游的人天亮前下来垒石头，两边在河湾又打了一回，这回动的是石块。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
					Shared.agriculture(4, 360),
				]),
			Shared.option(
				"pay_grain", "赔粮讲和",
				"公中的粮抬上了堰",
				"公中的粮抬上堰，一家一袋，抬了两趟。上游的人收了粮，把堰改低了一尺，水从缺口往下走。谷生站在堰下，看水头推着草叶过来。",
				[
					Shared.cash_out(1.5, 360),
					Shared.agriculture(2, 540),
					Shared.knowledge(2, 540),
				]),
			Shared.option(
				"new_channel", "另挖一条渠",
				"渠绕过了那道坡",
				"渠绕过坡脚，挖了整一个月，占了自家三垄地。通水那天，泥鳅跳进渠里，水只到膝盖，他还是躺下去泡了一回。",
				[
					Shared.agriculture(-4, 540),
					Shared.knowledge(2, 540),
					Shared.birth(2, 540),
				]),
		],
	}))
