class_name NarrativeEventCatalogWilds
extends RefCounted

## 风土：八条孤立事件，写自然与地块（不接链条，单条收束）。
##
##   枯井 · 蝗 · 狼冬 · 盐霜 · 塌方 · 渡口 · 苇火 · 倒春寒
##
## 这一包全部是脉冲入口；八条各带两三条权重规则，随建筑、职业构成、价格、时代、满意度浮动。
## 代价货币刻意错开：水、口粮、牲畜、地力、路、船、苇席、种粮。
## 没有负向全国贸易容量这种键，所以「路不通」一律写成本地制造 `.cut` 或主食开销上升。

const Ids = preload("res://scripts/narrative/narrative_event_ids.gd")
const Shared = preload("res://scripts/narrative/narrative_event_shared.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")
const TerrainTypeScript = preload("res://scripts/geography/terrain_type.gd")
const VegetationTypeScript = preload("res://scripts/geography/vegetation_type.gd")

const PACK_ID := &"wilds"
const PREFIX := "evt.wilds."

const CAST := [
	"郑阿土", "韩四", "陆春生", "冯灶", "姜九", "董阿婆", "万德昌", "邵九", "冯石", "柳七", "韦三",
	"灰峪", "白碱洼", "柳湾", "苇子洼", "南洼", "三节井绳", "木盐耙", "苇箔刀", "六尺板船",
]

const MUL_085 := 55706
const MUL_090 := 58982
const MUL_110 := 72090
const MUL_115 := 75366
const MUL_120 := 78643
const MUL_125 := 81920
const MUL_130 := 85197


static func meta() -> Dictionary:
	return {
		"id": PACK_ID,
		"title": "风土",
		"theme": "水、蝗、雪、盐、路、船、火、霜",
		"era_band": "1-8",
		"prefix": PREFIX,
		"scale": "8 条中观孤立",
		"cast": CAST,
		"node_ids": [
			String(Ids.EVT_WILDS_DRY_WELL),
			String(Ids.EVT_WILDS_LOCUST),
			String(Ids.EVT_WILDS_WOLF_WINTER),
			String(Ids.EVT_WILDS_SALT_BLOOM),
			String(Ids.EVT_WILDS_LANDSLIDE),
			String(Ids.EVT_WILDS_RIVER_FORD),
			String(Ids.EVT_WILDS_REED_FIRE),
			String(Ids.EVT_WILDS_COLD_SPRING),
		],
	}


static func append(catalog) -> void:
	if catalog == null:
		return
	var Op = NarrativeConditionScript.Op
	var Ch = NarrativeEventDefinitionScript.TriggerChannel

	# ═══ 枯井 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_WILDS_DRY_WELL),
		"title": "{settlement_name}·枯井",
		"body_text": "灰峪的井见了底。郑阿土把吊桶放下去，三节井绳在井壁上磨出声，半天才碰着水。提上来的水是浑的，桶底沉着半指泥，倒进桶里能看见草屑。渠水就是从这口井放的，麦正灌浆，地裂着口子。井台上排着七八只水桶，桶底都蹭着泥。郑阿土说，先留人喝的，渠口拿石板压上。韩四把铁锹插进渠口的泥里，两只手按着锹把，不让人动。",
		"image_key": "hydrology.water",
		"ai_visual_prompt": "A village well nearly dry, buckets queued on the stone platform, a farmer pressing a spade into an irrigation ditch",
		"tags": ["land", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 720,
		"min_era_index": 2,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 10},
			{"op": Op.MOISTURE_LTE, "float_value": 0.35},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
				"add_weight": 20,
				"reason": "还有几口井",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "agricultural_worker", "float_value": 0.40},
				"add_weight": 0,
				"multiplier_q16": MUL_120,
				"reason": "靠地吃饭的人多",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 6},
				"add_weight": 10,
				"reason": "镇上买得起抽水机",
			},
		],
		"options": [
			Shared.option(
				"plug_the_ditch", "压住渠口，先留人喝",
				"井台边的水桶满了",
				"石板压在渠口，头一夜就有人来掀，被韩四撞见，两个人在泥里滚了一身。水够喝了，麦却黄了尖。",
				[
					Shared.agriculture(-5, 540),
					Shared.birth(3, 540),
					Shared.bias(Ids.TAG_UNREST, 0.85, 540),
				]),
			Shared.option(
				"open_the_ditch", "开渠浇地，人省着喝",
				"渠水流进了麦地",
				"渠口挖开，水顺着垄沟走，韩四跟在后面培土，一锹一锹。井又往下凿了三尺，掏出来的泥堆在井台边，像个小坟。那年麦收得不错，入秋村里有两个孩子没站住。",
				[
					Shared.agriculture(5, 540),
					Shared.birth(-4, 540),
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
					Shared.research_signal("breakthrough.hydraulic_engineering", "深井暗渠"),
				]),
			Shared.option(
				"share_and_wait", "先分着用，等雨",
				"井台边上没人来了",
				"头一个月还排队，后来谁家先到谁打，打不上就回去。郑阿土把三节井绳收进屋，挂在梁上。第二年开春，井里能照见底。",
				[
					Shared.manufacturing(3, 540),
					Shared.agriculture(-3, 900),
					Shared.staple(4, 900),
					Shared.bias(Ids.TAG_UNREST, 1.20, 900),
				]),
		],
	}))

	# ═══ 蝗 ═══════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_WILDS_LOCUST),
		"title": "{settlement_name}·蝗",
		"body_text": "陆春生坐在田埂上，把镰刀横在膝上，看见地上多了一层会动的灰。蝗虫从东边的荒草滩过来，先落在最外那两亩黍子上，秆子一点点弯。他脱下褂子抽，抽一下飞起一片，落回去还是一片。冯灶从磨坊跑来，说割一条三丈宽的带子，烧了。陆春生掏出火镰，火石在裤腿上蹭两下，没打着。东边的风把灰吹到他脸上。他弯下腰，先割了第一把黍子。",
		"image_key": "economy.resource",
		"ai_visual_prompt": "A farmer in a millet field covered by a moving grey layer of locusts, another man running from a mill with a fire striker",
		"tags": ["land", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 110,
		"cooldown_days": 720,
		"min_era_index": 1,
		"max_era_index": 7,
		"conditions": [
			{"op": Op.TERRAIN_IN, "int_list": [
				TerrainTypeScript.TERRAIN.PLAIN, TerrainTypeScript.TERRAIN.FLOODPLAIN]},
			{"op": Op.POPULATION_GTE, "int_value": 10},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "agricultural_worker", "float_value": 0.45},
				"add_weight": 0,
				"multiplier_q16": MUL_125,
				"reason": "田就是全部的活",
			},
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "wheat_grain", "float_value": 1.20},
				"add_weight": 20,
				"reason": "仓里没粮，田里更不能丢",
			},
			{
				"condition": {"op": Op.SATISFACTION_LTE, "float_value": 0.50},
				"add_weight": 15,
				"reason": "人心本来就浮",
			},
		],
		"options": [
			Shared.option(
				"burn_a_strip", "割三丈带子，放火烧",
				"烧出一条黑带子",
				"火从地头起来，烧了小半个时辰，焦味压过草味。蝗虫飞到黑带子边上，停了一阵，往北去了。陆春生站在灰里，脚底下是他家那两亩黍子。",
				[
					Shared.agriculture(4, 360),
					Shared.staple(5, 360),
					Shared.bias(Ids.TAG_UNREST, 1.10, 360),
				]),
			Shared.gamble(
				"flood_the_field", "引渠水灌田，赌一把",
				Shared.branch(36045, "水漫过去，蝗没落", # 55%
					"渠水放了一天一夜，田里积起一层浅水。蝗虫落在水上，翅膀湿了飞不起来，被孩子拿竹竿往沟里扫。",
					[
						Shared.cash_out(1.5, 360),
						Shared.agriculture(6, 540),
						Shared.country_sector("agriculture", 3, 540),
					]),
				Shared.branch(29491, "水泡了苗，蝗还是吃了", # 45%
					"水放多了，苗泡两天就发黄。蝗虫从西边绕进来，落在泡过的田里，把剩下的啃到根。陆春生把一截断秆叼在嘴里，用手背抹了把脸上的土。",
					[
						Shared.cash_out(1.5, 360),
						Shared.agriculture(-6, 540),
						Shared.staple(8, 540),
					])),
			Shared.option(
				"wait_for_the_county", "等县里来人再说",
				"县里没来人",
				"等了六天，差役来看一眼，说这个不归他管。蝗虫往南去了，南边是别人的田。陆春生把镰刀磨了一遍，没下地。",
				[
					Shared.extraction(2, 360),
					Shared.agriculture(-4, 900),
					Shared.staple(6, 900),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
		],
	}))

	# ═══ 狼冬 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_WILDS_WOLF_WINTER),
		"title": "{settlement_name}·狼冬",
		"body_text": "雪下了三天，姜九的羊圈塌了一角。夜里狼在坡上叫，不远，羊挤成一堆，小的压在底下叫不出声。他抱一捆柴在圈门口点着，火不大，狼不退。村东头董阿婆的孙子天黑还没回来，她站在雪地里喊，喊一声，坡上就静一下。她的鞋陷进雪里，拔出来只剩一只。姜九腰里别着柴刀，圈里有一百多只羊。他往坡上走了两步，又回头看了看羊圈的门。",
		"image_key": "economy.resource",
		"ai_visual_prompt": "A collapsed sheep pen in heavy snow, wolves on the slope, an old woman calling into the dark, a shepherd with a billhook",
		"tags": ["land", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 1,
		"max_era_index": 6,
		"conditions": [
			{"op": Op.TEMP_LTE, "float_value": 0.0},
			{"op": Op.POPULATION_GTE, "int_value": 8},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
				"add_weight": 15,
				"reason": "圈都挨着坡",
			},
			{
				"condition": {"op": Op.ERA_LTE, "int_value": 2},
				"add_weight": 15,
				"reason": "墙是土打的，栏是柴扎的",
			},
			{
				"condition": {"op": Op.SATISFACTION_GTE, "float_value": 0.60},
				"add_weight": 0,
				"multiplier_q16": MUL_085,
				"reason": "日子过得下去，肯守夜",
			},
		],
		"options": [
			Shared.option(
				"keep_watch", "全村守夜，羊赶进屋",
				"一夜一夜地守",
				"男人分三班，火堆在圈门口没断过。第四天夜里狼下了坡，被火逼回去，踩塌一段篱笆。董阿婆的孙子在草垛里睡着，天亮才被找出来。",
				[
					Shared.agriculture(4, 540),
					Shared.cash_out(1.5, 360),
					Shared.staple(3, 360),
					Shared.bias(Ids.TAG_UNREST, 0.90, 360),
				]),
			Shared.option(
				"feed_them_outside", "丢几只羊在村外",
				"树底下的羊没剩",
				"天没亮，树底下只剩绳子和一摊红。那几天狼没再下坡。圈里的羊少了几只，董阿婆的孙子那个冬天没喝上奶。",
				[
					Shared.staple(6, 540),
					Shared.agriculture(-3, 540),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
			Shared.option(
				"fires_only", "村口点火，不派人",
				"火点了三夜就灭了",
				"头三夜有人添柴，第四夜下大雪，谁也没出去。开春数羊，少了十一只。姜九在坡上找到两个羊头，骨头被啃得很干净。",
				[
					Shared.bias(Ids.TAG_UNREST, 0.90, 360),
					Shared.birth(-4, 900),
					Shared.agriculture(-3, 900),
				]),
		],
	}))

	# ═══ 盐霜 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_WILDS_SALT_BLOOM),
		"title": "{settlement_name}·盐霜",
		"body_text": "开春化雪，白碱洼的地上一层白，脚踩上去咯吱响。万德昌把手掌按进地里，抓一把，用舌尖舔了舔，说这是好盐，晒一晒就能卖。陆春生今年要在这块地下种，犁头翻起来，土还是白的。万德昌的木盐耙靠在车上，木齿磨得发亮。洗地要水，水在五里外的渠里，一亩地要挑三十担。万德昌把盐耙从车上抽下来，扛在肩上，等人开口。",
		"image_key": "economy.resource",
		"ai_visual_prompt": "White salt crust on a field, a salt merchant tasting it, a farmer holding a plough, a wooden rake on a cart",
		"tags": ["land", "market"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 720,
		"min_era_index": 2,
		"max_era_index": 7,
		"conditions": [
			{"op": Op.MOISTURE_LTE, "float_value": 0.30},
			{"op": Op.POPULATION_GTE, "int_value": 12},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.001},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "salt", "float_value": 1.15},
				"add_weight": 20,
				"reason": "盐贵，刮了就能卖",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 1},
				"add_weight": 15,
				"reason": "场子现成",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 5},
				"add_weight": 10,
				"reason": "知道地里的白霜能洗",
			},
		],
		"options": [
			Shared.option(
				"scrape_the_salt", "刮盐，卖给盐商",
				"白霜刮成了堆",
				"万德昌雇了十几个人，用木耙把白霜刮成堆，装麻袋往城里运。刮过的地方露出湿土，一脚踩下去一个坑。第二年陆春生的犁翻上来，土还是白的。",
				[
					Shared.extraction(6, 540),
					Shared.stock("salt", 20),
					Shared.agriculture(-4, 540),
				]),
			Shared.option(
				"wash_the_field", "挑水洗地，压盐",
				"渠水漫过白地",
				"一亩三十担，挑了整整一春，肩膀磨破一层。水漫过去，盐往下走，土色深了些。麦种下去出得晚，收得也少，地算是保住了。",
				[
					Shared.agriculture(5, 540),
					Shared.cash_out(2.0, 360),
					Shared.staple(-4, 540),
					Shared.bias(Ids.TAG_UNREST, 1.10, 360),
				]),
			Shared.option(
				"sow_anyway", "先照常下种，看苗",
				"苗出得稀稀拉拉",
				"种下去了，出苗的不到一半，剩下的地方白霜又上来。陆春生俯下身，把没出苗的土扒开看，种子还在，就是没动。",
				[
					Shared.manufacturing(2, 360),
					Shared.agriculture(-4, 900),
					Shared.staple(5, 900),
				]),
		],
	}))

	# ═══ 塌方 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_WILDS_LANDSLIDE),
		"title": "{settlement_name}·塌方",
		"body_text": "雨下了两天，灰峪南坡塌了半边。土石压在官道上，最厚的地方没到人腰。冯石赶的车堵在山这头三天，车上的铁件卸下来，一件件搬不过去。塌下来的断面露出一条发黑的石线，邵九用锤子敲下一块，说这是铁。清路要人，半个月；顺着石线挖，也要人。冯石坐在车辕上啃干粮，脚边一堆卸下的铁件。他把一块石头揣进怀里，站起来去牵马。",
		"image_key": "economy.resource",
		"ai_visual_prompt": "A landslide blocking a mountain road, an exposed dark ore seam, a cart with iron parts unloaded, a miner testing the rock",
		"tags": ["land", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 2,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.TERRAIN_IN, "int_list": [
				TerrainTypeScript.TERRAIN.MOUNTAIN, TerrainTypeScript.TERRAIN.HILL]},
			{"op": Op.POPULATION_GTE, "int_value": 8},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
				"add_weight": 20,
				"reason": "矿上等着这条路",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "miner", "float_value": 0.15},
				"add_weight": 0,
				"multiplier_q16": MUL_120,
				"reason": "吃这口饭的人多",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 6},
				"add_weight": 10,
				"reason": "有炸药，清得快",
			},
		],
		"options": [
			Shared.option(
				"clear_the_road", "先清路，铁件运过去",
				"路通了，铁件运下山",
				"清路清了十三天，最后一车土推到沟里。冯石的车第一个过去，铁件重新装上，绳子勒进车辕。邵九站在坡上看，手里还捏着那块石头。",
				[
					Shared.trade_capacity(5, 540),
					Shared.manufacturing(4, 540),
					Shared.bias(Ids.TAG_LABOR, 1.10, 540),
				]),
			Shared.option(
				"follow_the_seam", "顺石线开矿，路先搁着",
				"井口开在塌方上",
				"顺着石线挖进去两丈，就是成片的铁。矿石用筐往下背，人走的是那条被埋了一半的旧路。山下的粮车绕远，砂石路上翻过一辆。",
				[
					Shared.extraction(6, 540),
					Shared.research_signal("resource.iron_ore", "铁帽石"),
					Shared.manufacturing(-3, 540),
					Shared.staple(5, 540),
				]),
			Shared.option(
				"take_the_long_way", "绕道走，先不动路",
				"车都走河滩",
				"河滩上压出两道新车辙，底盘低的车要人抬。入冬路面冻上，车辙冻成沟。冯石把车拆了，铁件一件一件背过山。",
				[
					Shared.extraction(2, 360),
					Shared.staple(4, 900),
					Shared.bias(Ids.TAG_UNREST, 1.15, 900),
				]),
		],
	}))

	# ═══ 渡口 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_WILDS_RIVER_FORD),
		"title": "{settlement_name}·渡口",
		"body_text": "柳湾只有一只六尺板船，柳七撑了十九年。上游下了雨，水涨到木桩的第二道刻痕，篙要插到底才使得上劲。船一趟装六个人，多一个就往下沉。船帮上补过三次，钉子锈成红点。岸上等着的是挑柴的、赶集的，还有万德昌的一车盐。柳七一天撑八趟，收的钱一半交给县里。他把船靠住，没解缆，蹲下来把缆绳在桩上多绕了一圈。",
		"image_key": "hydrology.water",
		"ai_visual_prompt": "A small wooden ferry boat at a river crossing, a ferryman coiling the rope, travellers and a salt cart waiting on the bank",
		"tags": ["land", "market"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 720,
		"min_era_index": 1,
		"max_era_index": 7,
		"conditions": [
			{"op": Op.HAS_RIVER, "bool_value": true},
			{"op": Op.POPULATION_GTE, "int_value": 10},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.10},
				"add_weight": 20,
				"reason": "过河的全是货",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 1},
				"add_weight": 15,
				"reason": "市就在岸上",
			},
			{
				"condition": {"op": Op.ERA_LTE, "int_value": 3},
				"add_weight": 15,
				"reason": "没有桥，只能靠船",
			},
		],
		"options": [
			Shared.option(
				"add_a_boat", "添一只船，雇人撑",
				"第二只船下了水",
				"新船比旧船短两尺，好掉头。柳七带了个十六岁的徒弟，撑篙的姿势教了三天。岸上等船的人少了，挑柴的不用再抱着扁担等到天黑。",
				[
					Shared.trade_capacity(6, 540),
					Shared.cash_out(1.5, 360),
					Shared.build_cost(3, 540),
					Shared.bias(Ids.TAG_UNREST, 1.05, 360),
				]),
			Shared.option(
				"farm_out_the_crossing", "渡口包给他，涨船钱",
				"船钱涨了，船还是那只",
				"过路钱翻了一倍，柳七自己抽三成。挑柴的把柴卸在岸边等人来收，等不到的又挑回去。那车盐在岸上搁了两天，万德昌在船上骂了半天。",
				[
					Shared.cash_in(1.5, 540),
					Shared.trade_capacity(3, 540),
					Shared.staple(4, 540),
					Shared.bias(Ids.TAG_UNREST, 1.25, 540),
				]),
			Shared.option(
				"keep_it_as_it_is", "船照旧，不加人",
				"船板薄了一层",
				"柳七一天撑十趟，船底在浅滩上蹭，年年要补。补船的木头从上游放下来，钱是柳七自己出的。第三年冬天他把船拖上岸，船底翻开全是虫眼。",
				[
					Shared.manufacturing(-3, 900),
					Shared.staple(4, 900),
					Shared.bias(Ids.TAG_UNREST, 0.90, 360),
				]),
		],
	}))

	# ═══ 苇火 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_WILDS_REED_FIRE),
		"title": "{settlement_name}·苇火",
		"body_text": "苇子洼的火从北边来，先烧的是去年割下没运走的干苇。风往南压，压着韦三的席场。东边隔着一条水沟，是陆春生的稻田。韦三站在自家地界上，手里拎着苇箔刀。割一条隔离带要二十个人，一个上午。他身后堆着三百领没卖出去的席，垛得比人高。烟压得很低，呛得人睁不开眼。韦三把刀往地上一插，转身回去拿火镰。",
		"image_key": "economy.resource",
		"ai_visual_prompt": "A reed marsh fire pushing south toward a matting yard, a reed cutter with a knife, a rice field across a ditch",
		"tags": ["land", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 720,
		"min_era_index": 1,
		"max_era_index": 6,
		"conditions": [
			{"op": Op.VEGETATION_IN, "int_list": [
				VegetationTypeScript.VEG.MARSH,
				VegetationTypeScript.VEG.SWAMP,
				VegetationTypeScript.VEG.PEAT_BOG]},
			{"op": Op.POPULATION_GTE, "int_value": 8},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "forestry_worker", "float_value": 0.20},
				"add_weight": 15,
				"reason": "苇子就是柴山",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "fisher", "float_value": 0.10},
				"add_weight": 15,
				"reason": "鱼窝在苇子里",
			},
			{
				"condition": {"op": Op.ERA_LTE, "int_value": 4},
				"add_weight": 10,
				"reason": "火一过就没人拦得住",
			},
		],
		"options": [
			Shared.option(
				"cut_a_firebreak", "抢割隔离带，保住席场",
				"割出一道空场",
				"二十个人割了一个上午，苇子堆在场边，来不及打捆。火到空场就停了，席场还在。那年冬天苇席少编三百领，钱是实的。",
				[
					Shared.manufacturing(4, 540),
					Shared.agriculture(3, 540),
					Shared.staple(3, 360),
				]),
			Shared.option(
				"let_it_burn", "让它烧到河边",
				"火烧到河边自己灭了",
				"火烧了两天，灰落了一层在稻田里，黑得发亮。第二年稻子长得比往年高。韦三的席场没了，湖边的人一个夏天没打着几条鱼。",
				[
					Shared.agriculture(5, 540),
					Shared.manufacturing(-4, 540),
					Shared.staple(4, 540),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
			Shared.option(
				"watch_the_wind", "看风向，风变再说",
				"夜里风转了",
				"第三天夜里风从南转成东，火头偏了，绕过场院进了稻田。稻子烧了大半，韦三的席场反倒保住。陆春生在地头站了很久，把烧黑的稻穗一把一把揪下来。",
				[
					Shared.agriculture(-5, 900),
					Shared.manufacturing(-3, 900),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
		],
	}))

	# ═══ 倒春寒 ═══════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_WILDS_COLD_SPRING),
		"title": "{settlement_name}·倒春寒",
		"body_text": "南洼的秧田里苗刚出土，一寸高，绿得发白。夜里霜下来了，早上田埂上的草叶都是硬的，畦边的水洼结着薄冰，一踩就碎。董阿婆用手去摸，苗尖一碰就断。仓里还剩两斗谷种，补种赶得上，只是晚一茬，秋天要少吃半个月。她儿子说再等等，太阳一出来就没事。董阿婆回家把盖被的旧棉絮抱出来，一块一块压在秧畦上。",
		"image_key": "family.house",
		"ai_visual_prompt": "Frost on young rice seedlings in a nursery bed, an old woman pressing old cotton wadding over the seedlings",
		"tags": ["land", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 1,
		"max_era_index": 6,
		"conditions": [
			{"op": Op.TEMP_LTE, "float_value": 6.0},
			{"op": Op.POPULATION_GTE, "int_value": 10},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "agricultural_worker", "float_value": 0.45},
				"add_weight": 0,
				"multiplier_q16": MUL_125,
				"reason": "全村的苗都在这一畦",
			},
			{
				"condition": {"op": Op.SATISFACTION_LTE, "float_value": 0.55},
				"add_weight": 15,
				"reason": "补种的种粮拿不出来",
			},
			{
				"condition": {"op": Op.ERA_LTE, "int_value": 3},
				"add_weight": 15,
				"reason": "没有暖房，只有草席",
			},
		],
		"options": [
			Shared.option(
				"smoke_the_field", "夜里熏烟，护住秧苗",
				"田里一夜都是烟",
				"湿柴压着火，烟顺着垄沟爬，把秧畦盖住。天亮看，苗尖还是绿的，只焦了最外一圈。烧掉的柴够做半个月的饭，董阿婆的儿子去更远的坡上砍。",
				[
					Shared.agriculture(5, 540),
					Shared.cash_out(1.5, 360),
					Shared.staple(3, 360),
					Shared.bias(Ids.TAG_UNREST, 0.90, 360),
				]),
			Shared.option(
				"resow_with_stored_grain", "拿剩的谷种补种",
				"补种的苗晚了一茬",
				"两斗谷种全下了地，苗出得齐。秋天割的时候比别家晚半个月。交完租，仓里剩的粮要省着吃，孩子先吃稀的。",
				[
					Shared.staple(6, 360),
					Shared.agriculture(3, 540),
					Shared.birth(-3, 360),
				]),
			Shared.option(
				"wait_for_the_sun", "先不补，等太阳",
				"太阳出来了，苗没起来",
				"第二天日头很好，化了的霜水积在畦里。苗烂在泥里，一拔就断。董阿婆把棉絮抱回屋，搭在绳上晒，一句话没说。",
				[
					Shared.agriculture(-5, 900),
					Shared.bias(Ids.TAG_UNREST, 1.25, 900),
				]),
		],
	}))
