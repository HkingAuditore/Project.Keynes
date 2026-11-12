class_name NarrativeEventCatalogAtom
extends RefCounted

## 原子包：era 8–10 的七条孤立事件。
##
## 这一包不写技术，写国家能力落下来时人站在哪一格：
##   反应堆要水，水是从下游稻田里挪的；废料要地方，地方是别人家的滩；
##   天上的东西看得见车辙，也看得见谁家夜里还亮着灯；电视只有一个台，播什么由谁定；
##   全城的账并进一张网，先没位置的是抄账的人；行踪都查得到，查到哪一层是个政治问题；
##   产线不要人了，剩下的人还得吃饭。
##
## 代价一律落在具体的人身上：值夜的、抄账的、被调岗的、搬走的人家。
## 三条选项的代价货币互不相同：掉产出 / 摊派现金 / 抬风险 / 涨开销。

const Ids = preload("res://scripts/narrative/narrative_event_ids.gd")
const Shared = preload("res://scripts/narrative/narrative_event_shared.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")

const PACK_ID := &"atom"
const PREFIX := "evt.atom."

const CAST := [
	"邝其昌", "卫砚生", "汤知白", "郁长庚", "闻玉山", "苗青禾", "应连生", "费守拙", "游照川", "尹四",
	"砂洲", "冷河湾", "白茅滩", "铁砧坳", "铅箱", "封条", "夜班表", "名册", "台标", "交换机", "纸带", "天线",
]

const MUL_110 := 72090
const MUL_115 := 75366
const MUL_120 := 78643
const MUL_125 := 81920


static func meta() -> Dictionary:
	return {
		"id": PACK_ID,
		"title": "原子",
		"theme": "国家能力落下来时，人站在哪一格",
		"era_band": "8-10",
		"prefix": PREFIX,
		"scale": "3 宏观 + 3 中观 + 1 微观，全部孤立",
		"cast": CAST,
		"node_ids": [
			String(Ids.EVT_ATOM_REACTOR),
			String(Ids.EVT_ATOM_WASTE),
			String(Ids.EVT_ATOM_SATELLITE),
			String(Ids.EVT_ATOM_CHANNEL),
			String(Ids.EVT_ATOM_NETWORK),
			String(Ids.EVT_ATOM_PRIVACY),
			String(Ids.EVT_ATOM_AUTOMATION),
		],
	}


static func append(catalog) -> void:
	if catalog == null:
		return
	var Op = NarrativeConditionScript.Op
	var Ch = NarrativeEventDefinitionScript.TriggerChannel

	# ═══ 核站 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_ATOM_REACTOR),
		"title": "{settlement_name}·核站",
		"body_text": "反应堆的地基打在砂洲城外，离最近的院子只隔一道土坡。冷却水得从冷河湾引，渠一开，下游三个村的稻田就少灌一季。邝其昌把水位表按在桌上，说泵一开就不能停，停了堆芯要热。卫砚生算的是另一笔：渠首的闸门归谁管，出了事谁签字。夜里浇地的老农蹲在渠边，看水往坡上去。上头的人明天来听答复，图纸摊在桌上，一角压着石头。",
		"image_key": "map.construction",
		"ai_visual_prompt": "A reactor foundation at the edge of a river town, an irrigation ditch being dug uphill, engineers and farmers arguing over a water gauge",
		"tags": ["atom", "unrest", "era"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 98,
		"cooldown_days": 900,
		"min_era_index": 8,
		"max_era_index": 10,
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 5},
			{"op": Op.POPULATION_GTE, "int_value": 20},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 7},
				"add_weight": 15,
				"reason": "厂多了，才用得上这么多电",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "industrial_worker", "float_value": 0.05},
				"add_weight": 20,
				"multiplier_q16": MUL_115,
				"reason": "厂里的人多，先喊缺电的是他们",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 9},
				"add_weight": 15,
				"reason": "老电站撑不住了",
			},
		],
		"options": [
			Shared.option(
				"draw_from_the_river", "从冷河湾引水",
				"渠首的闸",
				"渠挖了一个夏天，水上了坡。渠首的闸门挂了锁，钥匙在邝其昌腰上，他睡觉也压着。",
				[
					Shared.energy(7, 540),
					Shared.manufacturing(3, 540),
					Shared.agriculture(-4, 540),
				]),
			Shared.option(
				"build_cooling_towers", "修冷却塔，水自己转",
				"塔下的白汽",
				"塔修起来，白汽一夜到天亮。摊派的钱按户收，交不出的记在账上，利滚利。",
				[
					Shared.energy(5, 540),
					Shared.knowledge(3, 540),
					Shared.cash_in(1.5, 360),
					Shared.build_cost(3, 540),
				]),
			Shared.gamble(
				"run_it_low", "低功率先转起来",
				Shared.branch(42598, "灯先亮了", # 65%
					"它转起来了，声音比想的低。城里的灯先亮了一半，另一半等明年。",
					[
						Shared.energy(6, 540),
						Shared.knowledge(5, 540),
						Shared.research_signal("breakthrough.electrification", "电气化"),
					]),
				Shared.branch(22938, "堆芯发烫", # 35%
					"表针往上走，止不住。撤出来的人站在坡上，看白汽从缝里冒。当夜下了雨。",
					[
						Shared.energy(-6, 540),
						Shared.birth(-4, 540),
						Shared.bias(Ids.TAG_UNREST, 1.30, 540),
					])),
		],
	}))

	# ═══ 废料 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_ATOM_WASTE),
		"title": "{settlement_name}·废料",
		"body_text": "用过的东西从堆里捞出来，装进铅箱，编号，封条压上骑缝章。往哪儿放，城里吵了半个月。白茅滩的地软，挖三丈就出水；铁砧坳是石头，可离井太近。汤知白说石头不漏，应连生说井就在下头。守夜的人在坑口搭了草棚，一夜添两回灯油。封条上写着明年开春再验，验完那一栏空着，风把纸角掀起又落下。",
		"image_key": "economy.resource",
		"ai_visual_prompt": "Lead-lined boxes sealed with paper strips stacked beside a freshly dug pit, a straw watch hut and an oil lamp at night",
		"tags": ["atom", "unrest", "land"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 92,
		"cooldown_days": 780,
		"min_era_index": 8,
		"max_era_index": 10,
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 5},
			{"op": Op.POPULATION_GTE, "int_value": 18},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 6},
				"add_weight": 15,
				"reason": "机器多的城，废料也多",
			},
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 24},
				"add_weight": 10,
				"reason": "人多，坑就离院子近",
			},
			{
				"condition": {"op": Op.MOISTURE_GTE, "float_value": 0.45},
				"add_weight": 15,
				"multiplier_q16": MUL_120,
				"reason": "地下潮，埋了也怕渗",
			},
		],
		"options": [
			Shared.option(
				"bury_in_the_stone", "埋进铁砧坳",
				"石缝封了",
				"石场封了口子，碾盘停了三座。汤知白每天去看一回，用脚踩踩新土。",
				[
					Shared.extraction(-3, 540),
					Shared.knowledge(2, 540),
					Shared.bias(Ids.TAG_UNREST, 0.90, 360),
				]),
			Shared.option(
				"haul_it_north", "运去北边的旧矿",
				"车皮夜里走",
				"车皮都在夜里走，走一趟三天。钱按户摊，铁铺的人说，这是替全城出的。",
				[
					Shared.cash_in(2.0, 360),
					Shared.manufacturing(2, 540),
					Shared.knowledge(3, 540),
				]),
			Shared.option(
				"leave_it_open", "敞着放，派人看着",
				"草棚里的灯",
				"草棚里点着灯，一夜添两回油，看一夜的人补半升米。应连生守了四十天，回家那天先洗了三遍手。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
					Shared.cash_out(1.5, 540),
					Shared.knowledge(2, 540),
				]),
		],
	}))

	# ═══ 卫星 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_ATOM_SATELLITE),
		"title": "{settlement_name}·卫星",
		"body_text": "天线架在铁砧坳的坡上，铁架子比水塔还高，风大的时候整座架子会哼。游照川说它看得见河对岸的车辙，也看得见谁家夜里还亮着灯。苗青禾想用它看云，好早两天报雨；管仓的人想用它数来往的车。开机的头一晚，屏上过了一片田，田里有人在烧秸秆。游照川把镜头停在那儿，问这算不算看见。批文上写的是看天，他把镜头挪开半步，又挪回去。",
		"image_key": "map.construction",
		"ai_visual_prompt": "A tall lattice antenna on a rocky ridge above a river town, a small screen showing a field with burning stubble",
		"tags": ["atom", "era"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 840,
		"min_era_index": 9,
		"max_era_index": 10,
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 6},
			{"op": Op.POPULATION_GTE, "int_value": 20},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 9},
				"add_weight": 20,
				"reason": "这年头才够得着天上",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 7},
				"add_weight": 15,
				"reason": "配得起机房和电",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "scholar", "float_value": 0.02},
				"add_weight": 15,
				"reason": "有人会读那些图",
			},
		],
		"options": [
			Shared.option(
				"open_the_scope", "谁想看都能看",
				"屏前一屋子人",
				"登记簿写了半个月，看的人排到门外。苗青禾的报雨晚了两个时辰，云已经到头顶。",
				[
					Shared.knowledge(-3, 540),
					Shared.bias(Ids.TAG_UNREST, 0.90, 540),
					Shared.country_sector("knowledge", 4, 540),
				]),
			Shared.option(
				"seal_it_for_the_state", "只给官府用",
				"门上了锁",
				"机房加了哨，画面上只看得到官仓和渡口。管仓的人每天抄一遍，抄完锁进柜子。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.25, 540),
					Shared.knowledge(4, 540),
					Shared.country_sector("knowledge", 5, 540),
				]),
			Shared.option(
				"rent_half_of_it", "租一半给人看地",
				"看一亩收一斗",
				"看一亩收一斗，钱进国库，数目对不上。账房查了半个月，先记在粮行头上。",
				[
					Shared.cash_in(1.5, 360),
					Shared.manufacturing(2, 540),
					Shared.knowledge(2, 540),
				]),
		],
	}))

	# ═══ 电视 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_ATOM_CHANNEL),
		"title": "{settlement_name}·电视",
		"body_text": "转播塔立起来那天，全城只有一台机器能发信号，晚上七点开，十一点关。台标是一只展翅的鸟，画了七稿，最后用的是最不像鸟的那一稿。郁长庚管节目，他想播戏，说人累了一天，得看点别的；闻玉山管电，说播戏费电，播通知省。头一晚播的是征粮通告，播完没人吭声。第二天有人来问，能不能播一场球。郁长庚把节目单摊开，笔尖停在那个空格上。",
		"image_key": "country.economy",
		"ai_visual_prompt": "A single broadcast tower above a town, a room of neighbours watching one small screen at night, a bird emblem painted on the wall",
		"tags": ["atom", "people", "era"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 88,
		"cooldown_days": 720,
		"min_era_index": 8,
		"max_era_index": 10,
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
			{"op": Op.POPULATION_GTE, "int_value": 20},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 24},
				"add_weight": 15,
				"reason": "人挤在一处，一台机器就够全城看",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 5},
				"add_weight": 10,
				"reason": "有厂房，才凑得出那台机器",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 9},
				"add_weight": 10,
				"multiplier_q16": MUL_110,
				"reason": "夜里也供电了",
			},
		],
		"options": [
			Shared.option(
				"notices_only", "只播通告和天气",
				"夜里没人开",
				"节目单只剩两栏，戏班子散了，锣鼓搬进仓房。有人吃完饭还是把机器打开，看一会儿雪花。",
				[
					Shared.knowledge(-3, 540),
					Shared.manufacturing(2, 540),
					Shared.bias(Ids.TAG_UNREST, 0.95, 540),
				]),
			Shared.option(
				"plays_and_ballgames", "播戏，也播球",
				"半个城在听",
				"球赛那晚，街上没人。电费摊到户上，交不出的人家少看半个月。",
				[
					Shared.cash_in(1.0, 360),
					Shared.knowledge(3, 540),
					Shared.bias(Ids.TAG_UNREST, 0.85, 540),
				]),
			Shared.option(
				"let_the_villages_send", "各乡自己送节目",
				"各唱各的调",
				"各乡把自家的戏送来，口音不一样，播到一半有人上门吵。一个月后定下轮流，谁先谁后抽了签。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
					Shared.knowledge(4, 540),
					Shared.birth(2, 540),
				]),
		],
	}))

	# ═══ 网络 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_ATOM_NETWORK),
		"title": "{settlement_name}·网络",
		"body_text": "交换机搬进原来放粮的屋子，墙上钉了一排铁架子，线从架上垂下来，像晾着的面。全城的账要并成一张，粮行的、铁铺的、渡口的，都得报。费守拙带着几个学徒抄了三个月，抄到眼红，纸带上打的孔比字还多。苗青禾说并了以后，谁家余多少粮一眼就看得出；粮行的人说，那不如把仓门敞开。并网头一天只并上七家。剩下的三十几家把账簿抱回去，说等明年。",
		"image_key": "country.economy",
		"ai_visual_prompt": "A switchboard installed in an old grain warehouse, cables hanging like drying noodles, clerks copying ledgers by lamplight",
		"tags": ["atom", "market", "labor"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 94,
		"cooldown_days": 840,
		"min_era_index": 9,
		"max_era_index": 10,
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 6},
			{"op": Op.POPULATION_GTE, "int_value": 25},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 8},
				"add_weight": 20,
				"reason": "摊子大了，纸账记不过来",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.02},
				"add_weight": 15,
				"reason": "商号多，账才并得起来",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 9},
				"add_weight": 10,
				"reason": "机房和线路都齐了",
			},
		],
		"options": [
			Shared.option(
				"merge_everything", "全并进去",
				"账成了一张",
				"并网那天，费守拙在机房坐到天亮。铺线的钱按铺面摊，粮行先交了，账还是对不上。",
				[
					Shared.cash_in(2.0, 360),
					Shared.knowledge(5, 540),
					Shared.country_sector("manufacturing", 3, 540),
					Shared.research_signal("breakthrough.industrial_organization", "工业组织"),
				]),
			Shared.option(
				"state_granaries_only", "只并官仓和税册",
				"两本账",
				"官仓的数清了，街面的账还在纸上。抄账的人被调去录单，纸账没人管，虫蛀了边。",
				[
					Shared.knowledge(-3, 540),
					Shared.manufacturing(2, 540),
					Shared.bias(Ids.TAG_UNREST, 0.90, 540),
				]),
			Shared.option(
				"half_and_half", "一半并，一半留纸",
				"两边对不上",
				"月底对账，两边差了三船粮。谁改的，说不清，先按纸上的记，机房的人不肯签。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.25, 540),
					Shared.knowledge(2, 540),
					Shared.manufacturing(-2, 540),
				]),
		],
	}))

	# ═══ 隐私 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_ATOM_PRIVACY),
		"title": "{settlement_name}·隐私",
		"body_text": "城门口的灯换成新的，进出的车马都要记一笔，记在夜班表的背面。卫砚生手下有六个人轮值，最忙的一晚记了两百多行。名册越厚，来查的人越多：查丢牛的，查逃役的，查谁家半夜运粮出城。尹四说查得细，贼不敢动；住在冷河湾的老妇来问，能不能只记她儿子的名字，别记他几点回来。卫砚生把笔放下，翻到那一页，没写。",
		"image_key": "family.house",
		"ai_visual_prompt": "A gate lantern at night, a watchman's ledger opened to a half-filled page, an old woman standing at the gate",
		"tags": ["atom", "unrest", "people"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 780,
		"min_era_index": 9,
		"max_era_index": 10,
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 5},
			{"op": Op.POPULATION_GTE, "int_value": 20},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 24},
				"add_weight": 15,
				"reason": "人多，门口就难认",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 6},
				"add_weight": 10,
				"reason": "仓库多，进出的事也多",
			},
			{
				"condition": {"op": Op.COHORT_SATISFACTION_LTE, "float_value": 0.45},
				"add_weight": 15,
				"multiplier_q16": MUL_125,
				"reason": "人心里有火，官面上更想盯人",
			},
		],
		"options": [
			Shared.option(
				"to_each_household", "查到户，全部留底",
				"名册堆到房梁",
				"名册堆到房梁，查一个人要翻半天。尹四说这活干不动了，没人接，灯还是照样亮。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
					Shared.knowledge(3, 540),
					Shared.manufacturing(2, 540),
				]),
			Shared.option(
				"to_the_gate_only", "只查到街口",
				"门房换了锁",
				"门房换了新锁，守夜的人领了器械，钱从街上摊。丢牛的事多了一回，也没人再提。",
				[
					Shared.tools(3, 540),
					Shared.bias(Ids.TAG_UNREST, 0.90, 540),
					Shared.manufacturing(2, 540),
				]),
			Shared.option(
				"names_without_hours", "只记名字，不记时辰",
				"那一页空着",
				"名册只记名字，不记几点回来。抄写的工钱从街上摊，商号出了大半。卫砚生把那页空着，交上去时没解释。",
				[
					Shared.cash_in(1.2, 360),
					Shared.knowledge(-2, 540),
					Shared.bias(Ids.TAG_UNREST, 0.95, 540),
				]),
		],
	}))

	# ═══ 自动化 ═══════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_ATOM_AUTOMATION),
		"title": "{settlement_name}·自动化",
		"body_text": "新产线装在西头的厂房里，从进料到装箱，中间没有人。尹四原来带十六个人看机床，如今夜班表上只剩他一个名字，他看灯：绿灯亮着，就不用管。苗青禾算过，一条线省下的人够开两处新工地，可新工地还没影。被调走的人领了三个月粮，第四个月开始自己找活。有人蹲在厂门口，等哪台机器坏了好进去修。尹四下班前总要摸一遍那排铁壳子，还是热的。",
		"image_key": "map.construction",
		"ai_visual_prompt": "A machine line running without workers, one man walking past a row of warm metal housings, idle men waiting outside the gate",
		"tags": ["atom", "labor", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 96,
		"cooldown_days": 900,
		"min_era_index": 9,
		"max_era_index": 10,
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 6},
			{"op": Op.POPULATION_GTE, "int_value": 25},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 8},
				"add_weight": 20,
				"reason": "厂子成片，才腾得出一条整线",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "industrial_worker", "float_value": 0.08},
				"add_weight": 20,
				"multiplier_q16": MUL_120,
				"reason": "看机床的人多，换起来才省得多",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 9},
				"add_weight": 10,
				"reason": "机器自己能咬牙做了",
			},
		],
		"options": [
			Shared.option(
				"run_the_line", "全线开，减人",
				"灯亮着，人走了",
				"线开足了，厂里只剩巡灯的人。被调走的人领了三个月粮，第四个月没人再提。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.35, 540),
					Shared.manufacturing(6, 540),
					Shared.country_sector("manufacturing", 4, 540),
					Shared.research_signal("breakthrough.automation", "自动化"),
				]),
			Shared.option(
				"keep_the_hands", "留着人，慢一点",
				"人比机器慢",
				"线开一半，人手都留着。产量上不去，接的单退了两家，工钱照发。",
				[
					Shared.manufacturing(-3, 540),
					Shared.knowledge(2, 540),
					Shared.bias(Ids.TAG_UNREST, 0.85, 540),
				]),
			Shared.option(
				"send_them_to_the_ditch", "把人送去修渠",
				"渠边多了人",
				"调走的人去了渠上，头一个月住棚子，安置的钱从街上摊。苗青禾去看过一回，说那边缺筐。",
				[
					Shared.cash_in(2.0, 360),
					Shared.agriculture(3, 540),
					Shared.bias(Ids.TAG_UNREST, 0.90, 540),
				]),
		],
	}))
