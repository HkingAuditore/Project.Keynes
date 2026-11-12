class_name NarrativeEventCatalogEra
extends RefCounted

## 高时代包：国家能力、标准、排班、一张安静的书桌（4 条）。
##
## 四条都是孤立事件，但彼此有软边：
##   大工程读劳动包的「十小时制」标记（工时定了，工程才招得到人）；
##   标准之争读「河鼓已响」（工程成功了，标准才有人抢）；
##   排班读「标准未定」（规矩没定，人头先乱）；
##   安静的房间读「两套工价」（工价没统一，院里也在算人头）。
##
## 这一包的代价货币是国家能力：工期、标准、人的时间；知识点降一律写本地 `.cut`，
## 因为全国部门产出没有负向键。

const Ids = preload("res://scripts/narrative/narrative_event_ids.gd")
const Shared = preload("res://scripts/narrative/narrative_event_shared.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")

const PACK_ID := &"era"
const PREFIX := "evt.era."

const CAST := [
	"邵伯钧", "谭三保", "邱秉文", "麦允中", "龚守义", "霍见山", "池砚秋", "岑九", "亓南枝", "鲁敬亭",
	"砾川", "白碑原", "灰岭", "度量衡局", "第九设计院", "河鼓", "卡尺", "秒表", "标准动作表",
]

const MUL_110 := 72090
const MUL_115 := 75366
const MUL_120 := 78643
const MUL_125 := 81920


static func meta() -> Dictionary:
	return {
		"id": PACK_ID,
		"title": "高时代",
		"theme": "国家能力、标准与人的时间",
		"era_band": "8-10",
		"prefix": PREFIX,
		"scale": "2 宏观 + 1 中观 + 1 微观，全部孤立",
		"cast": CAST,
		"node_ids": [
			String(Ids.EVT_ERA_GREAT_WORKS),
			String(Ids.EVT_ERA_STANDARD_WAR),
			String(Ids.EVT_ERA_ALGORITHM_SHIFT),
			String(Ids.EVT_ERA_QUIET_ROOM),
		],
	}


static func append(catalog) -> void:
	if catalog == null:
		return
	var Op = NarrativeConditionScript.Op
	var Ch = NarrativeEventDefinitionScript.TriggerChannel

	# ═══ 大工程 ═══════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_ERA_GREAT_WORKS),
		"title": "{settlement_name}·大工程",
		"body_text": "白碑原的风把图纸掀起一角，邵伯钧用扳手压住。纸上那个东西叫「河鼓」，占着七十里荒地，全国凑得出的好钢正一车一车往这儿拉。地勘说底下是空的，还得再往下打三十丈。测线穿过谭三保家的祖坟，他把地契摊在桌上，说坟不挪。会计邱秉文把账本合上，不报数了。上头只问一句：几时能响。邵伯钧把扳手拿开，纸角立刻卷起来，他用手掌按住。",
		"image_key": "map.construction",
		"ai_visual_prompt": "A huge engineering site on a plain, blueprints pinned by a wrench, survey stakes crossing an old graveyard, steel arriving by rail",
		"tags": ["era", "science", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 900,
		"one_shot": true,
		"min_era_index": 8,
		"max_era_index": 10,
		"required_events_completed": [String(Ids.EVT_LABOR_FACTORY_ACT)],
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 25},
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 5},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 9},
				"add_weight": 20,
				"multiplier_q16": MUL_120,
				"reason": "工业底子厚了，才敢想这件事",
			},
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_HOURS_TEN)},
				"add_weight": 20,
				"reason": "工时定了，工程招得到人",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 7},
				"add_weight": 25,
				"multiplier_q16": MUL_115,
				"reason": "配套的厂都在本地",
			},
		],
		"options": [
			Shared.option(
				"fund_to_the_deadline", "再拨一笔，按期点火",
				"两班换三班",
				"钱拨下去，工地上的灯再没灭过。村子在夜里搬完，棺材抬上卡车，没人说话。邵伯钧在工棚里签第三张领料单，手边那份饭没动过。",
				[
					Shared.cash_out(3.0, 90),
					Shared.manufacturing(5, 540),
					Shared.country_sector("knowledge", 6, 540),
					Shared.bias(Ids.TAG_UNREST, 1.30, 360),
				]),
			Shared.gamble(
				"light_it_early", "提前点火",
				Shared.branch(42598, "响了三秒", # 65%
					"它响了三秒，比图上画的小。观测棚的玻璃全碎了，没人去捡。邵伯钧蹲在土里，两只手还在抖。",
					[
						Shared.knowledge(6, 540),
						Shared.country_sector("knowledge", 6, 540),
						Shared.research_signal("breakthrough.electrification", "电气化"),
						Shared.flag(Ids.FLAG_HEGU_FIRED, 900, "标记「河鼓已响」"),
					]),
				Shared.branch(22938, "火从缝里回来", # 35%
					"管子裂了，火从缝里倒灌。抬出来的人裹着同一条毯子。名单上有十九个名字，划掉了十八个。",
					[
						Shared.birth(-6, 540),
						Shared.knowledge(-5, 360),
						Shared.bias(Ids.TAG_UNREST, 1.30, 720),
					])),
			Shared.option(
				"wait_for_the_steel", "等钢够了再说",
				"图纸进柜",
				"工地停了，塔吊还立着，钢梁上落了一层雪。邱秉文把账本锁回铁柜，钥匙挂回腰上。谭三保来问过一次，没人给他准话。",
				[
					Shared.knowledge(-4, 540),
					Shared.manufacturing(-3, 540),
					Shared.bias(Ids.TAG_UNREST, 1.10, 540),
				]),
		],
	}))

	# ═══ 标准 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_ERA_STANDARD_WAR),
		"title": "{settlement_name}·标准",
		"body_text": "两条铁路在砾川城外接上了，一宽一窄，货卸下来，人扛过去，再装车。度量衡局的麦允中带着一箱量具来开会。北线的人说他们的轨铺了二十年，南线调度霍见山说他们的车皮能进山。做扣件的龚守义不争，两种他都做，模具锁在抽屉里，图纸在他手上。会开到第三天，桌上多了一张纸：谁定下标准，谁的厂今后只开一种模。麦允中把量具一件一件摆开，最后一件是卡尺，垫布忘在旅馆了。他把卡尺搁在桌沿上，谁也没敢碰。",
		"image_key": "map.construction",
		"ai_visual_prompt": "Two railway gauges meeting outside a town, a box of measuring tools and a caliper on a conference table",
		"tags": ["era", "market", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 720,
		"one_shot": true,
		"min_era_index": 9,
		"max_era_index": 10,
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 5},
			{"op": Op.POPULATION_GTE, "int_value": 25},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.001},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_HEGU_FIRED)},
				"add_weight": 20,
				"multiplier_q16": MUL_120,
				"reason": "河鼓响了，厂里只肯认一种模",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "artisan", "float_value": 0.05},
				"add_weight": 20,
				"reason": "做扣件的人已经在城里",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 7},
				"add_weight": 25,
				"reason": "厂多，标准才值钱",
			},
		],
		"options": [
			Shared.option(
				"pick_the_northern_gauge", "定北线的轨",
				"排到坡下",
				"站里的车皮一条线排到坡下，等着换轮。山里的煤堆在坡上，没人拉，自己烧起来。霍见山递了辞呈，桌上没人接。",
				[
					Shared.trade_capacity(8, 540),
					Shared.build_cost(5, 900),
					Shared.manufacturing(-5, 540),
					Shared.bias(Ids.TAG_UNREST, 1.30, 360),
				]),
			Shared.option(
				"take_a_cut_per_piece", "按件抽成",
				"一件记一笔",
				"龚守义的模具搬进了度量衡局的库房，每出一件扣件，账上记一笔。厂里的工价压下去两成，第二天来了七成人，谁也没吭声。",
				[
					Shared.cash_in(2.0, 270),
					Shared.stock("wrought_iron", 20),
					Shared.country_sector("manufacturing", 5, 540),
					Shared.bias(Ids.TAG_UNREST, 1.30, 360),
				]),
			Shared.option(
				"add_a_transfer_station", "加一个换装站",
				"站台添了一张桌",
				"换装站搭在两条轨中间，扛包的、箍桶的、记账的，一夜之间都有了活。货在站上多停一天，这笔钱谁也没算。麦允中的量具还锁在箱子里，垫布后来找着了。",
				[
					Shared.manufacturing(4, 540),
					Shared.tools(8, 540),
					Shared.flag(Ids.FLAG_STD_OPEN, 900, "标记「标准未定」"),
				]),
		],
	}))

	# ═══ 排班 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_ERA_ALGORITHM_SHIFT),
		"title": "{settlement_name}·排班",
		"body_text": "灰岭的装卸场挂了一块新板，板上全是格子，一个格子里一个名字。池砚秋是计时员，手里一块秒表，一叠写着「标准动作」的纸。上个月一车煤卸完要半晌，纸上写着两刻。岑九卸了十二年煤，说照纸那么干，腰撑不到年底。池砚秋没接话，把岑九的名字挪到夜班那一格。板子最下面一行小字：请假，先找人替。铃响了，没人走，都站着看那块板。池砚秋最后走，拿袖子把格子擦了一遍。",
		"image_key": "map.construction",
		"ai_visual_prompt": "A shift board covered in name slots at a coal yard, a timekeeper with a stopwatch, workers standing still at the bell",
		"tags": ["era", "labor", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 110,
		"cooldown_days": 540,
		"min_era_index": 9,
		"max_era_index": 10,
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 5},
			{"op": Op.POPULATION_GTE, "int_value": 30},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.UNEMPLOYMENT_GTE, "float_value": 0.10},
				"add_weight": 30,
				"multiplier_q16": MUL_110,
				"reason": "等着上工的人排到门口",
			},
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_STD_OPEN)},
				"add_weight": 0,
				"multiplier_q16": MUL_115,
				"reason": "规矩没定，人头先乱",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "industrial_worker", "float_value": 0.10},
				"add_weight": 20,
				"reason": "场里全是吃工时饭的人",
			},
		],
		"options": [
			Shared.option(
				"follow_the_board", "照表排，慢的换掉",
				"格子满了",
				"表贴到每个场，慢的人第二天就不来了。岑九去了西头的旧场，工钱少一半。板上的格子填满，池砚秋把秒表收进兜里，走路时一直按着。",
				[
					Shared.manufacturing(6, 540),
					Shared.country_sector("manufacturing", 5, 540),
					Shared.birth(-6, 540),
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
				]),
			Shared.option(
				"pilot_one_yard", "只在新场试",
				"两本账",
				"新场照表排，老场照旧。两本工价册子摆在池砚秋桌上，谁也合不上。年底要结账，她把两本都塞进抽屉，锁了。",
				[
					Shared.manufacturing(4, 540),
					Shared.flag(Ids.FLAG_SHIFT_PENDING, 720, "标记「两套工价」"),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
			Shared.gamble(
				"let_workers_fill_it", "表交给工人自己填",
				Shared.branch(39322, "格子空了一半", # 60%
					"表交回场里，工人自己填。头一个月慢，第三个月比表上还快。岑九把名字写在白班那一格，第一次没写夜班。",
					[
						Shared.manufacturing(6, 720),
						Shared.birth(5, 540),
						Shared.bias(Ids.TAG_UNREST, 1.20, 540),
					]),
				Shared.branch(26214, "板子从墙上扯下来", # 40%
					"两班人抢同一台吊车，货压在场上。第三天打起来，板子被人从墙上扯下来。池砚秋去捡那些格子，捡了半筐。",
					[
						Shared.manufacturing(-6, 540),
						Shared.staple(10, 360),
						Shared.bias(Ids.TAG_UNREST, 1.30, 540),
					])),
		],
	}))

	# ═══ 安静的房间 ═══════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_ERA_QUIET_ROOM),
		"title": "{settlement_name}·安静的房间",
		"body_text": "第九设计院三楼，机器一开，地板跟着抖。亓南枝在纸上算了四十天，卡在最后一步。她找管楼的鲁敬亭，要把整层停机三天。鲁敬亭翻登记本：这一层的机时排满了，灰岭的矿上来算通风，铁路来算车皮，还有一家算明年的汛。停机可以，违约金谁付。亓南枝把草稿推过去，最上面一行被橡皮擦破了。鲁敬亭从抽屉里摸出一把铜钥，插进去转了两下，停住了。",
		"image_key": "map.construction",
		"ai_visual_prompt": "A shaking third-floor office above machinery, a researcher's worn draft, a caretaker trying keys from a drawer",
		"tags": ["era", "scholar", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 120,
		"cooldown_days": 480,
		"min_era_index": 8,
		"max_era_index": 10,
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
			{"op": Op.POPULATION_GTE, "int_value": 12},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "scholar", "float_value": 0.03},
				"add_weight": 25,
				"multiplier_q16": MUL_120,
				"reason": "院里有算得动这一步的人",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 6},
				"add_weight": 20,
				"reason": "机器越多，屋子越吵",
			},
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_SHIFT_PENDING)},
				"add_weight": 0,
				"multiplier_q16": MUL_110,
				"reason": "两套工价没合成一套，院里也在算人头",
			},
		],
		"options": [
			Shared.option(
				"stop_the_floor", "停三天，赔钱",
				"最后一行",
				"三楼停了三天，矿上的通风算到一半搁着。亓南枝第四天早上写出最后一行，笔尖把纸戳破了。违约金从院里的账上划走，鲁敬亭把铜钥收回抽屉，还是那把。",
				[
					Shared.cash_out(2.0, 90),
					Shared.knowledge(6, 540),
					Shared.extraction(-4, 540),
					Shared.country_sector("knowledge", 6, 720),
				]),
			Shared.option(
				"felt_the_walls", "贴毡，机器照开",
				"账上写修缮",
				"那间屋子四面贴了毡，机器照开，亓南枝说还是抖。隔壁两个组也来要毡，鲁敬亭只给了一间。毡钱记在院里，账上写的是修缮。",
				[
					Shared.cash_out(2.0, 180),
					Shared.knowledge(2, 540),
					Shared.extraction(3, 540),
					Shared.bias(Ids.TAG_UNREST, 1.20, 360),
				]),
			Shared.option(
				"queue_for_next_month", "排到下月机时",
				"抽屉里",
				"机时排到下月，亓南枝把草稿锁进抽屉。第二个月她没来要机时。别处的院先登了那一步，报纸送到门口，鲁敬亭看了一眼，压在最下面。",
				[
					Shared.knowledge(-4, 540),
					Shared.bias(Ids.TAG_UNREST, 1.10, 540),
				]),
		],
	}))
