class_name NarrativeEventCatalogRail
extends RefCounted

## 铁路包：七条孤立事件，钢轨穿过田、城、河与山（era 6–8）。
##
##   征地 · 车站 · 时刻表 · 票价 · 桥 · 隧道 · 货场
##
## 全部是脉冲入口，不接链、不留标记：一件事进来，三个选项，各自结账。
## 器物只到蒸汽为止——钢轨、道钉、枕木、时刻表、车票、号志灯、蒸汽机车；
## 没有内燃、没有电气化，也没有一条线能一次修成。
##
## 代价货币刻意错开（测试按代价指纹逐条比对）：
##   征地——掉农业 / 抬工具开销 / 抬风险
##   车站——征商款 / 占农地 / 货运拖延
##   时刻表——校钟开销 / 压制造业 / 抬市场风险
##   票价——商户分摊 / 长途货改道 / 穷人挤不上车
##   桥——合龙赌一次（赌输掉制造业 + 抬动荡）/ 再等一季要现钱 / 填石毁田抬粮价
##   隧道——停工压制造业 / 借债买设备 / 停掘掉知识
##   货场——路局抽成 + 脚行闹 / 包干压制造业 / 混管抬工具开销

const Ids = preload("res://scripts/narrative/narrative_event_ids.gd")
const Shared = preload("res://scripts/narrative/narrative_event_shared.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")
const TerrainTypeScript = preload("res://scripts/geography/terrain_type.gd")

const PACK_ID := &"rail"
const PREFIX := "evt.rail."

const CAST := [
	"罗季常", "汤有德", "边守拙", "麦仲平", "岑玉墀", "樊有光",
	"邬守业", "桑延龄", "贺长庚", "荣宝珊",
	"石桥集", "南塘坡", "柳树屯", "铁匠营", "砖桥口",
	"道钉", "枕木", "号志灯", "车票", "里程桩",
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
		"title": "铁路",
		"theme": "一条钢轨怎样穿过田、城、河与山",
		"era_band": "6-8",
		"prefix": PREFIX,
		"scale": "7 条中观/微观孤立",
		"cast": CAST,
		"node_ids": [
			String(Ids.EVT_RAIL_LAND),
			String(Ids.EVT_RAIL_STATION),
			String(Ids.EVT_RAIL_TIMETABLE),
			String(Ids.EVT_RAIL_FARE),
			String(Ids.EVT_RAIL_BRIDGE),
			String(Ids.EVT_RAIL_TUNNEL),
			String(Ids.EVT_RAIL_FREIGHT),
		],
	}


static func append(catalog) -> void:
	if catalog == null:
		return
	var Op = NarrativeConditionScript.Op
	var Ch = NarrativeEventDefinitionScript.TriggerChannel

	# ═══ 征地 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_RAIL_LAND),
		"title": "{settlement_name}·征地",
		"body_text": "测线的木桩从石桥集北头一直钉到南塘坡，钉进罗季常家的水田，钉子下到泥里时歪了一下。路局的汤有德把补偿章程摊在田埂上，纸角压着半块砖，说按亩折算，一亩赔三年的收成，银钱一次付清。罗季常蹲下去拔那根桩，拔不动，桩底下垫了石头。他说这田是他爷爷一担一担挑土垫起来的，章程上没有这一条。汤有德没答话，从怀里取出印泥盒，盒盖裂了，红印泥干成一圈。田里的水正顺着桩洞往外渗，渗到脚边。",
		"image_key": "map.construction",
		"ai_visual_prompt": "Survey stakes driven through a flooded rice field, a railway clerk unrolling a compensation schedule on the ridge, a farmer kneeling at a stake",
		"tags": ["rail", "land", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 6,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
			{"op": Op.POPULATION_GTE, "int_value": 15},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 5},
				"add_weight": 20,
				"multiplier_q16": MUL_115,
				"reason": "屋多，线就不好绕",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "agricultural_worker", "float_value": 0.15},
				"add_weight": 25,
				"multiplier_q16": MUL_120,
				"reason": "种地的人多，征的就是他们的田",
			},
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 25},
				"add_weight": 20,
				"reason": "人稠地窄，一亩也含糊不得",
			},
		],
		"options": [
			Shared.option(
				"buy_it_out", "按章程买断",
				"银子压在砖下",
				"银子用油纸包着，压在田埂那块砖底下。罗季常数了一遍，没有再数第二遍。桩子拔了，田中间留下一个碗大的洞。",
				[
					Shared.agriculture(-6, 540),
					Shared.cash_out(2.0, 360),
					Shared.staple(4, 540),
				]),
			Shared.option(
				"move_the_line", "改线，绕开这片田",
				"线从坡上走",
				"线改了，从坡上绕过去，多出七里。桩子一根根拔起来，钉进别家的地里。罗季常站在田头，看最后一根桩从水里起出来。",
				[
					Shared.tools(6, 540),
					Shared.manufacturing(-3, 360),
					Shared.agriculture(3, 540),
					Shared.bias(Ids.TAG_LAND, 1.15, 540),
				]),
			Shared.option(
				"hold_the_paper", "先不给钱，拖着",
				"桩子泡在水里",
				"桩子在田里泡了一秋，漆掉了，字也看不清。罗季常照旧插秧，插到桩子跟前就绕开。路局的车在坡下等了三天，走了。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
					Shared.staple(5, 540),
					Shared.manufacturing(-2, 360),
				]),
		],
	}))

	# ═══ 车站 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_RAIL_STATION),
		"title": "{settlement_name}·车站",
		"body_text": "车站的图样铺在聚丰号的柜台上，两种画法各压着一块砚台。一种把站台塞进旧城的砖桥口，要拆掉半条街，连麦仲平的铁匠铺一起；一种画在城外的空地上，四周是芦苇，离最近的住户有两里。路局的边守拙说旧城的地基是老的，铺轨得往下挖三尺才见硬土。麦仲平把两只手按在图上，手掌正好盖住自己的铺子。荣宝珊从外头进来，鞋上带着泥，说城外那片地是她家的，价钱可以谈。柜台上搁着一枚道钉，是照新轨打的样，谁也没有去动它。",
		"image_key": "map.construction",
		"ai_visual_prompt": "Two station site plans pinned on a shop counter with inkstones, a blacksmith covering his own shop on the drawing, a sample rail spike beside them",
		"tags": ["rail", "market", "land"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 720,
		"min_era_index": 6,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
			{"op": Op.POPULATION_GTE, "int_value": 15},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 5},
				"add_weight": 20,
				"multiplier_q16": MUL_115,
				"reason": "城里挤，站台没处放",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.02},
				"add_weight": 0,
				"multiplier_q16": MUL_120,
				"reason": "铺面都在争站口",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 7},
				"add_weight": 15,
				"reason": "车次密了，站就小了",
			},
		],
		"options": [
			Shared.option(
				"tear_the_street", "修进旧城，拆半条街",
				"半条街空了",
				"拆到第三家，砖桥口的铺面就空了。铁匠铺的炉子搬到城外的棚子里，头一炉铁没烧透。麦仲平在废墟上捡回半截门框。",
				[
					Shared.cash_in(1.5, 360),
					Shared.trade_capacity(4, 540),
					Shared.manufacturing(-4, 540),
				]),
			Shared.option(
				"build_on_the_flats", "修在城外空地",
				"站台立在芦苇里",
				"站台立在芦苇中间，头一班车到的时候，来看热闹的人比乘客多。荣宝珊收了她家那片地的钱，转身在站前开了间茶棚。",
				[
					Shared.manufacturing(5, 540),
					Shared.build_cost(4, 540),
					Shared.agriculture(-4, 540),
				]),
			Shared.option(
				"make_a_road_first", "先修一条便道",
				"车停在三里外",
				"车停在三里外的岔路口，人扛着货走一段土路进城。下雨那几天，路上全是泥。麦仲平把铁匠铺的招牌摘下来，擦了一遍。",
				[
					Shared.bias(Ids.TAG_MARKET, 1.20, 540),
					Shared.manufacturing(-3, 540),
					Shared.trade_capacity(2, 540),
					Shared.cash_out(1.0, 180),
				]),
		],
	}))

	# ═══ 时刻表 ═══════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_RAIL_TIMETABLE),
		"title": "{settlement_name}·时刻表",
		"body_text": "调度室的墙上钉着一张表，纸上画满横线，线的尽头写着站名，字小得要凑近才看得清。路局的岑玉墀每天清早在表上改一处，改完把橡皮屑吹到地上。城里的钟不止一口，鼓楼的、衙门的、铁匠营的、码头的，各走各的，前后能差一刻。樊有光管着货栈的装卸，说车按表到，货不按表来，早到半个时辰，站台上就堆不下。邬守业是养路工，他的表是日头，太阳偏西就收工。岑玉墀把铅笔搁下，问在场的人，以哪口钟为准。没有人先开口，鼓楼那边正好敲了一下。",
		"image_key": "country.economy",
		"ai_visual_prompt": "A hand-drawn railway timetable pinned to a dispatch office wall, a dispatcher with a pencil, station clocks and a bell tower beyond the window",
		"tags": ["rail", "market", "labor"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 720,
		"min_era_index": 6,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
			{"op": Op.POPULATION_GTE, "int_value": 18},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 26},
				"add_weight": 25,
				"multiplier_q16": MUL_115,
				"reason": "人多了，误一刻就是一堆人",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 6},
				"add_weight": 20,
				"reason": "货栈多，表就有用",
			},
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "wheat_grain", "float_value": 1.15},
				"add_weight": 15,
				"multiplier_q16": MUL_110,
				"reason": "粮价高，谁都催车",
			},
		],
		"options": [
			Shared.option(
				"follow_the_drum_tower", "以鼓楼钟为准",
				"全城对一次表",
				"衙门的人抬着梯子去鼓楼，把钟摆调了半刻。头一个月，车来得早，人来得晚，站台上全是跑着的人。",
				[
					Shared.knowledge(4, 540),
					Shared.tools(6, 540),
					Shared.country_sector("manufacturing", 4, 540),
				]),
			Shared.option(
				"follow_the_railway", "以路局的表为准",
				"车不等钟",
				"车按路局的表开，鼓楼的钟慢了一刻也没人管。樊有光的货栈改了三次上工时辰，末一次他干脆住在站里。",
				[
					Shared.trade_capacity(5, 540),
					Shared.manufacturing(-4, 540),
					Shared.knowledge(3, 540),
				]),
			Shared.option(
				"each_station_its_own", "各站各用各的表",
				"两趟车对开",
				"各站照自己的表发车，两趟车在单线上对开，退到岔道里等了一个时辰。岑玉墀把铅笔削断了两回。",
				[
					Shared.bias(Ids.TAG_MARKET, 1.25, 540),
					Shared.manufacturing(-3, 540),
					Shared.agriculture(3, 540),
				]),
		],
	}))

	# ═══ 票价 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_RAIL_FARE),
		"title": "{settlement_name}·票价",
		"body_text": "售票口开在站房西侧，一块木板钉在墙上，板上用炭写着三等车厢的价钱，写了两遍，后一遍把前一遍盖住。罗季常的媳妇要去柳树屯看她娘，站在板底下把铜钱数了两遍，还差几文。桑延龄是站里的票房先生，说票价是路局定的，他只管收钱。贺长庚替人扛包，一天挣的够坐一趟短途，他说坐车的人不怕贵，怕的是空着肚子坐。站台上那盏号志灯白天也点着，灯罩上落了一层煤灰。罗季常把铜钱从媳妇手里接过去，添了几枚，塞回她手心。",
		"image_key": "country.economy",
		"ai_visual_prompt": "A third-class fare board written in charcoal beside a ticket window, a woman counting coins below it, a signal lamp with soot on the glass",
		"tags": ["rail", "market", "labor", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 105,
		"cooldown_days": 720,
		"min_era_index": 6,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.02},
			{"op": Op.POPULATION_GTE, "int_value": 18},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.05},
				"add_weight": 0,
				"multiplier_q16": MUL_125,
				"reason": "商人多，票价就是他们的生意",
			},
			{
				"condition": {"op": Op.COHORT_SATISFACTION_LTE, "float_value": 0.45},
				"add_weight": 30,
				"reason": "日子紧的人，先算路费",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
				"add_weight": 15,
				"reason": "来往的人多，板上的字改得勤",
			},
		],
		"options": [
			Shared.option(
				"cut_the_third_class", "把三等票价压下来",
				"三等车厢挤满",
				"票价压下来，三等车厢挤得插不进脚，连车顶上都坐着人。桑延龄卖票卖到手腕发酸，路局少了一笔进项。",
				[
					Shared.cash_in(1.0, 360),
					Shared.trade_capacity(4, 540),
					Shared.birth(3, 540),
				]),
			Shared.option(
				"charge_by_distance", "按里程定价",
				"短途便宜长途贵",
				"短途的票价降了，长途的涨了一截。扛包的人坐得起短途了，往柳树屯看娘的还是走着回去。",
				[
					Shared.manufacturing(-4, 540),
					Shared.trade_capacity(3, 540),
					Shared.staple(-3, 540),
				]),
			Shared.option(
				"add_a_slow_train", "不降价，加开慢车",
				"慢车挂在后头",
				"慢车挂在快车后头，见站就停，票价照旧。挤不上快车的人在站台上坐成一排，等到天黑。贺长庚把扁担横在膝上。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.25, 540),
					Shared.manufacturing(3, 540),
					Shared.trade_capacity(2, 540),
				]),
		],
	}))

	# ═══ 桥（本包唯一博弈）══════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_RAIL_BRIDGE),
		"title": "{settlement_name}·桥",
		"body_text": "铁桥的最后一孔梁悬在河面上，两头的脚手架差着一臂宽。合龙的时辰是请人看过的，就在这两天；过了这几天，河上的水要涨，浮船得撤走。桥工的头儿邬守业主张现在就落梁，他说钢梁在日头下晒了一天，胀出来的那点尺寸正好补缝。路局的岑玉墀不肯，说差一臂就是差一臂，宁可再等一季，等水退了从河滩上搭枕木垛。河风把两人的图纸吹得哗哗响，脚手架上有个工人一直没下来，靠在梁头抽烟，烟灰掉进河里。岑玉墀抬头看他，手还按在图上。",
		"image_key": "map.construction",
		"ai_visual_prompt": "The last span of an iron railway bridge hanging over a river, scaffolding one arm's width apart, a worker smoking on the beam, two engineers arguing over drawings",
		"tags": ["rail", "land", "labor"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 110,
		"cooldown_days": 900,
		"min_era_index": 6,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.HAS_RIVER, "bool_value": true},
			{"op": Op.POPULATION_GTE, "int_value": 15},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.TERRAIN_IN, "int_list": [TerrainTypeScript.TERRAIN.PLAIN]},
				"add_weight": 20,
				"reason": "河面平缓，桥才修得起来",
			},
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 24},
				"add_weight": 20,
				"multiplier_q16": MUL_115,
				"reason": "两岸都要过河的人多",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 5},
				"add_weight": 20,
				"reason": "货等着过河",
			},
		],
		"options": [
			Shared.gamble(
				"close_it_today", "今天就把梁落下",
				Shared.branch(39322, "梁落到位上", # 60%
					"梁落下去，缝比预想的窄，垫片只塞了两片。河对岸的人先喊起来，声音顺着水面传过来。",
					[
						Shared.manufacturing(4, 540),
						Shared.trade_capacity(6, 540),
						Shared.build_cost(3, 540),
					]),
				Shared.branch(26214, "梁头磕在桥墩上", # 40%
					"梁头磕在桥墩上，崩掉一块角，两个人跟着梁掉下去，捞上来一个。河上的浮船撤了，桥工裹着褂子在岸上坐了一夜。",
					[
						Shared.manufacturing(-8, 540),
						Shared.bias(Ids.TAG_UNREST, 1.35, 540),
						Shared.birth(-4, 540),
					])),
			Shared.option(
				"wait_one_season", "再等一季",
				"水退了再动手",
				"水退下去，河滩露出来，枕木垛一层层码上去。桥工这一季的工钱照付，路局的账房把本子翻了三遍。",
				[
					Shared.cash_in(1.5, 360),
					Shared.agriculture(3, 540),
					Shared.bias(Ids.TAG_UNREST, 0.90, 540),
				]),
			Shared.option(
				"fill_the_shallows", "从下游浅滩填石",
				"一条石堤过河",
				"石堤从浅滩上垒过去，取的是两岸的田土。头一场水就冲掉半截，剩下的一半还露在水面上，桩子歪着。",
				[
					Shared.agriculture(-5, 540),
					Shared.staple(6, 540),
					Shared.manufacturing(-3, 540),
					Shared.trade_capacity(2, 540),
				]),
		],
	}))

	# ═══ 隧道 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_RAIL_TUNNEL),
		"title": "{settlement_name}·隧道",
		"body_text": "隧道从铁匠营背后的山嘴进去，两头同时开凿，一头往东，一头往西，说好要在山肚子里碰面。掌子面上挂着一盏号志灯，灯下摆一只水盆，水面上的气泡往哪边偏，就说哪边的风在动。樊有光管东头的尺，他师父传下来一根麻绳，绳上打了结，量一次挪一个结。西头的罗季常不信麻绳，他叫人把水准器架在枕木上，说磁针在这一带是歪的。两边已经掘了半年，中间还隔着一层岩，声音传不过来，只能靠敲钢管。昨夜东头听见三下回音，没有人敢断定是不是自己敲的。",
		"image_key": "map.construction",
		"ai_visual_prompt": "Two tunnel headings driven from opposite sides of a mountain, a signal lamp over a water basin, a knotted measuring rope and a spirit level on a sleeper",
		"tags": ["rail", "labor"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 780,
		"min_era_index": 6,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.TERRAIN_IN, "int_list": [
				TerrainTypeScript.TERRAIN.HILL, TerrainTypeScript.TERRAIN.MOUNTAIN]},
			{"op": Op.POPULATION_GTE, "int_value": 12},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.TERRAIN_IN, "int_list": [
					TerrainTypeScript.TERRAIN.MOUNTAIN]},
				"add_weight": 20,
				"reason": "山越厚，越得两头挖",
			},
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 20},
				"add_weight": 20,
				"reason": "人手够，两班才倒得过来",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
				"add_weight": 15,
				"multiplier_q16": MUL_110,
				"reason": "料场就设在洞口",
			},
		],
		"options": [
			Shared.option(
				"trust_the_rope", "照麻绳的线接着挖",
				"两头碰上了",
				"两头在第三年春天碰上了，错开不到一尺，用钢钎一撬就通。樊有光把那根麻绳解下来，绕在自己腰上。",
				[
					Shared.manufacturing(-5, 540),
					Shared.extraction(4, 540),
					Shared.trade_capacity(2, 540),
				]),
			Shared.option(
				"sink_a_shaft", "西头停工，打竖井",
				"从山脊往下打",
				"竖井从山脊往下打，绞车一天提上来几十筐碎石。西头的掌子面停下，风从井里灌进去，灯烧得比原来亮。",
				[
					Shared.cash_in(2.0, 360),
					Shared.tools(5, 540),
					Shared.extraction(-3, 540),
					Shared.knowledge(3, 540),
				]),
			Shared.option(
				"call_a_surveyor", "先停半月，请测量师",
				"从外县请来的人",
				"测量师从外县来，箱子里装着三脚架和铜尺。他在山嘴上架了三天，最后把线往南挪了两丈。罗季常看着那根标杆，没有说话。",
				[
					Shared.knowledge(-3, 540),
					Shared.bias(Ids.TAG_MARKET, 1.15, 360),
					Shared.research_signal("breakthrough.steam_power", "蒸汽动力"),
				]),
		],
	}))

	# ═══ 货场 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_RAIL_FREIGHT),
		"title": "{settlement_name}·货场",
		"body_text": "货场在站房北边，一片夯实的黄土，四周垒着枕木当矮墙。路局要把货场收回去，自己管装卸，说脚行的人手脚慢，一车皮货卸半天，车皮压在站里腾不出来。脚行的头儿贺长庚不认这个账，他的本子上记着三十几号人的工钱，都是按车算的。汤有德把告示贴在枕木墙上，浆糊还没干，边角就被风掀起来。麦仲平是货栈的东家，两头都欠着，站在货场中间看人卸一车锻铁，铁锭砸在黄土上，砸出一个坑。贺长庚背靠着枕木，拿一截粉笔把车号一个个描粗。",
		"image_key": "country.economy",
		"ai_visual_prompt": "A rail freight yard walled with sleepers, porters unloading iron ingots, a railway notice pasted on the sleeper wall, a foreman chalking car numbers",
		"tags": ["rail", "market", "labor", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 6,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.02},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.05},
				"add_weight": 0,
				"multiplier_q16": MUL_120,
				"reason": "商货多，货场就是咽喉",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 6},
				"add_weight": 20,
				"reason": "仓房连着货场，谁都想插一手",
			},
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "wrought_iron", "float_value": 1.15},
				"add_weight": 15,
				"reason": "铁贵，压车就是压钱",
			},
		],
		"options": [
			Shared.option(
				"give_it_to_the_railway", "货场归铁路",
				"路局自己管装卸",
				"路局自己的人进场上工，头一个星期卸得比脚行快。贺长庚的三十几号人散了一半，另一半在站外等活。",
				[
					Shared.manufacturing(4, 540),
					Shared.cash_in(1.0, 360),
					Shared.bias(Ids.TAG_LABOR, 1.20, 540),
				]),
			Shared.option(
				"give_it_to_the_porters", "货场归脚行",
				"按车包干",
				"按车包干，脚行的人天不亮就进场上垛，货压上三五天也没人催。麦仲平算过账，车皮周转慢了两成。",
				[
					Shared.manufacturing(-4, 540),
					Shared.staple(5, 540),
					Shared.bias(Ids.TAG_LABOR, 0.85, 540),
				]),
			Shared.option(
				"split_the_yard", "一半归铁路，一半留脚行",
				"货场从中间砌墙",
				"货场从中间砌了一道矮墙，两边各开一个门。车皮在墙外等着过磅，脚行的人隔着墙递话，谁也不知道该听哪边。",
				[
					Shared.tools(6, 540),
					Shared.stock("wrought_iron", 12),
					Shared.trade_capacity(3, 540),
				]),
		],
	}))
