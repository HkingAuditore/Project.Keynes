class_name NarrativeEventCatalogAges
extends RefCounted

## 历代补空：八条孤立事件，专门填既有内容没有覆盖的时代空档。
##
##   era 0–2：第一把种子、第一座坟、泥人（石器到农耕）
##   era 4–6：迷路的商队、针（探索到启蒙）
##   era 7–10：最后的林子、信号塔、机器听见（电气到信息）
##
## 全部是脉冲入口，不接链条；但都带两三条权重规则，随建筑、职业、价格、满意度分层。
## 代价货币刻意错开：种子=口粮，坟=知识，泥人=柴，商队=商路，针=风险，塔=人心，机器=出生，林子=产能。

const Ids = preload("res://scripts/narrative/narrative_event_ids.gd")
const Shared = preload("res://scripts/narrative/narrative_event_shared.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")
const VegetationTypeScript = preload("res://scripts/geography/vegetation_type.gd")

const PACK_ID := &"ages"
const PREFIX := "evt.ages."

const CAST := [
	"阿禾", "石伯", "老陶", "甘棠", "陆沉", "麦芒", "郝梁", "屈木", "阿卜",
	"陶罐", "界石", "铁针", "信号塔", "青背岭", "泥人",
]

const MUL_110 := 72090
const MUL_115 := 75366
const MUL_120 := 78643
const MUL_125 := 81920
const MUL_130 := 85197


static func meta() -> Dictionary:
	return {
		"id": PACK_ID,
		"title": "历代",
		"theme": "时代空档里的八件小事",
		"era_band": "0-10",
		"prefix": PREFIX,
		"scale": "8 条微观/中观孤立",
		"cast": CAST,
		"node_ids": [
			String(Ids.EVT_AGES_FIRST_SEED),
			String(Ids.EVT_AGES_FIRST_GRAVE),
			String(Ids.EVT_AGES_CLAY_FIGURE),
			String(Ids.EVT_AGES_CARAVAN_LOST),
			String(Ids.EVT_AGES_COMPASS_DOUBT),
			String(Ids.EVT_AGES_SIGNAL_TOWER),
			String(Ids.EVT_AGES_MACHINE_HEARS),
			String(Ids.EVT_AGES_LAST_FOREST),
		],
	}


static func append(catalog) -> void:
	if catalog == null:
		return
	var Op = NarrativeConditionScript.Op
	var Ch = NarrativeEventDefinitionScript.TriggerChannel

	# ═══ 第一把种子 ═══════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_AGES_FIRST_SEED),
		"title": "{settlement_name}·第一把种子",
		"body_text": "秋天最后一把谷子，阿禾把它装进一只陶罐，罐口用泥封了。场院里的人围着看，谁都知道这一罐是明年的种。有人问能不能先吃一半，阿禾没答，把罐子抱进屋里。夜里他起来看过两回，罐子还在。第二天早上，罐口上的泥裂了一道缝，他用手指把缝抹平，抹完又朝窗外看了一眼。",
		"image_key": "family.house",
		"ai_visual_prompt": "A clay jar sealed with mud held by a villager, people watching around a threshing floor at the end of harvest",
		"tags": ["ages", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 900,
		"min_era_index": 0,
		"max_era_index": 1,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 6},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "agricultural_worker", "float_value": 0.30},
				"add_weight": 25,
				"multiplier_q16": MUL_120,
				"reason": "靠种地吃饭的人多，种子才金贵",
			},
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 12},
				"add_weight": 15,
				"reason": "人多了，一罐种子不够分",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
				"add_weight": 10,
				"reason": "有了仓房，才谈得上留种",
			},
		],
		"options": [
			Shared.option(
				"keep_the_seed", "留种，明年再种",
				"种子埋进土里",
				"种子埋进土里那天，阿禾在田边站了很久。冬天有人饿死，也有人把谷壳磨了掺在粥里。第二年穗子出来，谁也没提去年冬天。",
				[
					Shared.agriculture(4, 540),
					Shared.staple(4, 360),
				]),
			Shared.option(
				"grind_it_and_eat", "磨了吃，过冬要紧",
				"磨盘响了半夜",
				"磨盘响了半夜，第二天锅里有了稠粥。开春别人下种，阿禾家的田只撒了薄薄一层。那年秋天，他家的穗子比别家矮一截。",
				[
					Shared.staple(-4, 180),
					Shared.agriculture(-3, 360),
				]),
			Shared.option(
				"share_with_neighbours", "分给邻人，一起种",
				"七户人家各拿一份",
				"陶罐里的谷子分成七份，七户人家各拿一份。有人嫌分得不匀，在祠堂门口吵了一架。第二年春天，七块地一起下种，出苗的日子差了三天。",
				[
					Shared.birth(4, 540),
					Shared.knowledge(3, 540),
					Shared.bias(Ids.TAG_PEOPLE, 1.10, 540),
				]),
		],
	}))

	# ═══ 第一座坟 ═════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_AGES_FIRST_GRAVE),
		"title": "{settlement_name}·第一座坟",
		"body_text": "石伯死在冬天，身子停在屋里三天。大家争论埋在哪里：坡上离水远，路口离人近。老陶说，埋在路口，过路的人看见就知道这里有人住。有人不同意，说晦气。最后他们抬着石伯上了坡，路上歇了两回。坑挖到一半，铲子碰到一块石头，谁也搬不动。老陶蹲在坑边看了半天，说那就把石头留着。",
		"image_key": "family.house",
		"ai_visual_prompt": "Villagers carrying a body up a slope in winter, a half-dug grave with a large stone in it",
		"tags": ["ages", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 85,
		"cooldown_days": 900,
		"min_era_index": 0,
		"max_era_index": 2,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 8},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 16},
				"add_weight": 20,
				"multiplier_q16": MUL_115,
				"reason": "人多，死人的事也多了",
			},
			{
				"condition": {"op": Op.SATISFACTION_LTE, "float_value": 0.50},
				"add_weight": 20,
				"reason": "日子难过，才要一个说法",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
				"add_weight": 10,
				"reason": "有了固定的住处，才有固定的坟",
			},
		],
		"options": [
			Shared.option(
				"pile_stones", "堆石为记",
				"石堆垒到齐腰高",
				"石堆垒到齐腰高，没有字。第二年春天，有人在石堆上放了一束干草。再后来，过路的人也会放一块石头，堆子一年比一年大。",
				[
					Shared.knowledge(3, 540),
					Shared.manufacturing(2, 360),
					Shared.bias(Ids.TAG_PEOPLE, 1.10, 540),
				]),
			Shared.option(
				"bury_and_forget", "埋了就忘，省下力气",
				"坑填平了",
				"坑填平了，上面撒了把谷壳，怕人认出来。那年春耕多翻了两亩地，秋天多收了两担。后来没人记得石伯埋在哪，连他儿子也说不清。",
				[
					Shared.agriculture(2, 360),
					Shared.knowledge(-3, 360),
				]),
			Shared.option(
				"bury_at_the_crossroads", "葬在路口，让过路人看见",
				"坟堆在路口",
				"坟堆在路口，来往的人都要绕一步。办丧事那天吃了半扇猪，粮缸见了底。第二年春上，有人在坟边搭了个棚子卖水。",
				[
					Shared.birth(3, 540),
					Shared.staple(3, 360),
					Shared.bias(Ids.TAG_UNREST, 0.90, 360),
				]),
		],
	}))

	# ═══ 泥人 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_AGES_CLAY_FIGURE),
		"title": "{settlement_name}·泥人",
		"body_text": "老陶的小女儿在河边捏了个泥人，有鼻子有眼，晒干了摆在窗台上。过路的人看了，说这东西像个守门的。老陶把它放进窑里，烧了一夜。第二天出窑，泥人裂了一道纹，还是站着。街坊都来看，有人问能不能也捏一个，有人问烧这个有什么用。老陶把泥人放回窗台，没说话。",
		"image_key": "map.construction",
		"ai_visual_prompt": "A small fired clay figure with a crack, standing on a windowsill, neighbours gathered at a kiln",
		"tags": ["ages", "craft"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 80,
		"cooldown_days": 720,
		"min_era_index": 0,
		"max_era_index": 2,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 8},
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 1},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "artisan", "float_value": 0.05},
				"add_weight": 20,
				"multiplier_q16": MUL_120,
				"reason": "有匠人，才烧得出东西",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
				"add_weight": 15,
				"reason": "窑不止一座",
			},
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 14},
				"add_weight": 10,
				"reason": "看热闹的人多",
			},
		],
		"options": [
			Shared.option(
				"fire_more_figures", "让他捏，烧成陶",
				"窗台上摆了一排",
				"窑里又烧了两回，窗台上摆了一排泥人，有守门的，有抱鱼的。柴用得比往年多，冬天屋里冷了一截。来换泥人的人带的是盐和皮子。",
				[
					Shared.manufacturing(4, 540),
					Shared.knowledge(3, 540),
					Shared.staple(3, 360),
				]),
			Shared.option(
				"put_it_away", "收起来，别耽误活",
				"泥人进了柜子",
				"泥人收进柜子，上面压了一摞麻布。老陶照旧做他的盆和罐，只是收工前会往柜子看一眼。那年冬天，别处来的匠人带了一种带花纹的罐子，卖得比他的好。",
				[
					Shared.manufacturing(-2, 360),
					Shared.knowledge(-2, 360),
					Shared.bias(Ids.TAG_UNREST, 0.90, 360),
				]),
			Shared.option(
				"let_everyone_make_one", "让全城都来捏",
				"河边坐满了人",
				"河边坐满了人，泥不够用，挖到别人家的地头上。有人捏了自家的牛，有人捏了死去的孩子。烧出来的东西摆了半条街，也有人在夜里偷偷把别人的泥人砸了。",
				[
					Shared.knowledge(5, 540),
					Shared.birth(3, 540),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
		],
	}))

	# ═══ 迷路的商队 ═══════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_AGES_CARAVAN_LOST),
		"title": "{settlement_name}·迷路的商队",
		"body_text": "一支外邦商队在西边的岔路上走错了，二十几匹牲口在城外趴了两天。领队的阿卜会说几句本地话，比划着问去大集的路。他们的货是盐和一种没见过的布，包在油布里，没受潮。城里有人主张把货扣下，说外邦人不敢怎么样；也有人想请他们留下，在城南开一间铺子。甘棠蹲在车边看那匹病马，说再走三天，这队人得折一半。",
		"image_key": "country.economy",
		"ai_visual_prompt": "A foreign caravan resting outside a town wall, bales of salt and unfamiliar cloth, a sick horse in the traces",
		"tags": ["ages", "market", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 4,
		"max_era_index": 6,
		"conditions": [
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.01},
			{"op": Op.POPULATION_GTE, "int_value": 12},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.04},
				"add_weight": 25,
				"multiplier_q16": MUL_120,
				"reason": "城里做买卖的人多，消息传得快",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
				"add_weight": 20,
				"reason": "有货栈，才留得住人",
			},
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 20},
				"add_weight": 15,
				"reason": "城大，买得起那批布",
			},
		],
		"options": [
			Shared.option(
				"guide_them_out", "引路出关",
				"商队上路了",
				"甘棠派了两个人带路，送到岔路口。阿卜留下一匹布和一袋盐，说下回还走这条道。第二年秋天，城外的车辙比往年深了一指。",
				[
					Shared.trade_capacity(6, 360),
					Shared.cash_out(1.5, 360),
					Shared.knowledge(2, 360),
					Shared.bias(Ids.TAG_FRONTIER, 1.10, 540),
				]),
			Shared.option(
				"seize_the_goods", "扣下货，充公",
				"货进了官仓",
				"货进了官仓，盐和布都记了数。阿卜在城门口站了一天，第二天带着人走了。那年冬天，西边的岔路上多了几个骑马的人，专抢落单的车。",
				[
					Shared.cash_in(2.0, 360),
					Shared.manufacturing(-3, 360),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
			Shared.option(
				"ask_them_to_stay", "请他们留下开店",
				"城南多了一间铺子",
				"城南多了一间铺子，门口挂的招牌是两种字。阿卜的货比本地便宜一成，本地的布行联合起来不跟他做生意。他家的孩子在巷子里跟人打架，学话学得很快。",
				[
					Shared.trade_capacity(4, 540),
					Shared.knowledge(3, 540),
					Shared.staple(3, 360),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
		],
	}))

	# ═══ 针 ═══════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_AGES_COMPASS_DOUBT),
		"title": "{settlement_name}·针",
		"body_text": "甘棠从外邦水手那里换来一枚针，装在一只木盒里，针总指着一个方向，不管盒子怎么转。他把盒子放在船头，说有了这个，出海不用再看星星。陆沉看了半天，说这东西要是错了，船就回不来。城里有人说是妖术，要求把盒子收走。甘棠把盒子盖上，又打开，针还在转，慢慢停住。",
		"image_key": "hydrology.water",
		"ai_visual_prompt": "A needle in a wooden box on a ship's bow, a boatman and a star-gazer arguing over it, sailors watching",
		"tags": ["ages", "knowledge", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 720,
		"min_era_index": 4,
		"max_era_index": 6,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 12},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "scholar", "float_value": 0.01},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "scholar", "float_value": 0.03},
				"add_weight": 25,
				"multiplier_q16": MUL_120,
				"reason": "有人算得清，也有人说得清",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
				"add_weight": 20,
				"reason": "码头和学堂都在城里",
			},
			{
				"condition": {"op": Op.IS_COASTAL, "bool_value": true},
				"add_weight": 20,
				"reason": "靠海的人才知道这东西值钱",
			},
		],
		"options": [
			Shared.gamble(
				"trust_the_needle", "信它，出海",
				Shared.branch(39322, "船回来了", # 60%
					"船出去了十一天，回来时船舷上多了一道白痕。甘棠把针盒擦干净，说这一趟没看星星。陆沉在岸上等着，第一句话问的是：针偏了没有。",
					[
						Shared.trade_capacity(6, 360),
						Shared.knowledge(4, 540),
						Shared.research_signal("contact.maritime_vessel", "远洋航路"),
						Shared.bias(Ids.TAG_UNREST, 1.10, 540),
					]),
				Shared.branch(26214, "船没回来", # 40%
					"船没回来。半个月后，下游捞上来一块船板，漆还是新的。甘棠把针盒锁进柜子，陆沉再没提过看星星的事；城里有人说，那盒子本来就不该上船。",
					[
						Shared.manufacturing(-3, 540),
						Shared.knowledge(-2, 360),
						Shared.bias(Ids.TAG_UNREST, 1.30, 540),
					])),
			Shared.option(
				"test_it_on_the_river", "先在河上试",
				"针盒上了小船",
				"针盒上了一只小船，在河上走了三天。船老大说，盒子指的方向跟岸上的塔差了一点。陆沉把差的那一点记在纸上，说这一点，够船在海上偏出去很远。",
				[
					Shared.knowledge(3, 540),
					Shared.trade_capacity(2, 360),
					Shared.tools(4, 360),
				]),
			Shared.option(
				"lock_it_away", "收进库里，别惹事",
				"盒子进了库房",
				"盒子进了库房，钥匙交给陆沉。城里安静了，教门的人不再上门。三年后有外邦船停在港外，用的也是这样的盒子，甘棠在码头上一直看到日头偏西。",
				[
					Shared.knowledge(-3, 360),
					Shared.bias(Ids.TAG_FAITH, 1.15, 540),
					Shared.bias(Ids.TAG_UNREST, 0.90, 360),
				]),
		],
	}))

	# ═══ 信号塔 ═══════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_AGES_SIGNAL_TOWER),
		"title": "{settlement_name}·信号塔",
		"body_text": "青背岭上立起一座木塔，塔顶挂一盏灯。麦芒说，船在海上看见灯，就知道港口在哪，不会撞上暗礁。塔要人守，灯要油，钱从哪儿出，还没定。郝梁算了一笔账：官家出钱，灯就归官家；商号出钱，灯就归商号，进港的船要交一份灯钱。麦芒把灯罩擦了一遍，说灯先点上，钱的事明天再说。",
		"image_key": "map.construction",
		"ai_visual_prompt": "A wooden signal tower with a lamp on a ridge above a harbour, a clerk and a merchant arguing at its base",
		"tags": ["ages", "market", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 8,
		"max_era_index": 10,
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 5},
			{"op": Op.POPULATION_GTE, "int_value": 20},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.IS_COASTAL, "bool_value": true},
				"add_weight": 25,
				"multiplier_q16": MUL_120,
				"reason": "有港，灯才有用",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.03},
				"add_weight": 20,
				"reason": "跑船的人愿意出灯钱",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 7},
				"add_weight": 15,
				"reason": "货多了，夜航的船也多",
			},
		],
		"options": [
			Shared.option(
				"build_it_public", "官府出钱建",
				"灯亮了",
				"灯亮了，第一夜就有三条船顺着光进了港。守塔的人轮班，油钱从公账上走。郝梁在账本上添了一行，写完抬头看了看塔，说这灯太亮，费油。",
				[
					Shared.trade_capacity(5, 540),
					Shared.cash_out(2.5, 360),
					Shared.bias(Ids.TAG_LABOR, 1.10, 540),
				]),
			Shared.option(
				"let_the_merchants_build", "让商号建，收他们的费",
				"塔下多了一间小屋",
				"塔下多了一间小屋，屋里坐着收灯钱的人。进港的船按吨位交钱，不交的就在外面等天亮。有船长把船停在光外，摸着黑进港，撞坏了一条。",
				[
					Shared.trade_capacity(7, 540),
					Shared.cash_in(2.0, 360),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
			Shared.option(
				"no_tower", "不建，省钱",
				"塔基空着",
				"塔基空着，长了一圈草。那年冬天，一条船在港外触礁，货漂了一夜。麦芒在岸上看着，没说话；郝梁把算过的账本翻出来，又合上。",
				[
					Shared.manufacturing(-2, 360),
					Shared.bias(Ids.TAG_UNREST, 1.10, 540),
				]),
		],
	}))

	# ═══ 机器听见 ═════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_AGES_MACHINE_HEARS),
		"title": "{settlement_name}·机器听见",
		"body_text": "仓库里装了一台机器，能听见人说话，也能把谁干了多少记下来。麦芒说，装上它，夜里少点两个人，账也不会错。工人站在机器底下，说话的声音低了一截。有人问，机器听不听得见咳嗽；没人答。郝梁把机器上的灰擦掉，说这东西比人记得准。月底排班表出来，两个名字被挪到了夜班，其中一个上个月刚死了娘。",
		"image_key": "map.construction",
		"ai_visual_prompt": "Workers standing under a listening machine in a warehouse, a shift board with names moved to the night column",
		"tags": ["ages", "labor", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 720,
		"min_era_index": 9,
		"max_era_index": 10,
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 6},
			{"op": Op.POPULATION_GTE, "int_value": 25},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.UNEMPLOYMENT_GTE, "float_value": 0.10},
				"add_weight": 25,
				"multiplier_q16": MUL_115,
				"reason": "等着上工的人排到门口",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "industrial_worker", "float_value": 0.10},
				"add_weight": 25,
				"reason": "场里全是吃工时饭的人",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 8},
				"add_weight": 15,
				"reason": "仓库越多，机器越划算",
			},
		],
		"options": [
			Shared.option(
				"install_everywhere", "全城都装",
				"排班表贴满了街",
				"排班表贴满了街，名字后面跟着数目。夜里少点了两个人，货出得比上月快。有人开始在机器底下故意咳嗽，咳得很大声；机器没有反应。",
				[
					Shared.manufacturing(7, 540),
					Shared.birth(-5, 540),
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
				]),
			Shared.option(
				"warehouse_only", "只装在仓库",
				"只有仓库听得见",
				"只有仓库听得见。别处的工人照旧按班头走，仓库里的人开始自己记数，怕机器记错。麦芒说这样也好，至少夜里还有人说话。",
				[
					Shared.manufacturing(3, 540),
					Shared.knowledge(4, 540),
					Shared.bias(Ids.TAG_UNREST, 1.05, 360),
				]),
			Shared.option(
				"tear_it_out", "把机器拆掉",
				"墙上留下四个孔",
				"机器拆下来，墙上留下四个孔。仓库又回到靠嗓子喊的日子，账偶尔出错。那年冬天出了两次错，一次多发了工钱，一次少发了，少发的那次没人吭声。",
				[
					Shared.manufacturing(-4, 360),
					Shared.knowledge(2, 360),
					Shared.bias(Ids.TAG_UNREST, 0.90, 540),
				]),
		],
	}))

	# ═══ 最后的林子 ═══════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_AGES_LAST_FOREST),
		"title": "{settlement_name}·最后的林子",
		"body_text": "城边最后一片林子，屈木守了三代。树砍到坡腰，再砍就要砍到水源头。城里要修新仓，木料不够，有人出价买这片林子，价钱够全城吃一冬。石伯站在坡上看着，屈木用袖子把青石上的土擦了一遍，石上的字快磨平了。他说，林子没了，水就没了；买树的人说，水是天上下的。两拨人站在坡上，谁也不让。",
		"image_key": "economy.resource",
		"ai_visual_prompt": "A forest reduced to the lower slope, a forester wiping a boundary stone, a timber buyer with a purse",
		"tags": ["ages", "land", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 900,
		"min_era_index": 7,
		"max_era_index": 10,
		"conditions": [
			{"op": Op.VEGETATION_IN, "int_list": [
				VegetationTypeScript.VEG.TAIGA,
				VegetationTypeScript.VEG.TEMPERATE_DECIDUOUS,
				VegetationTypeScript.VEG.TEMPERATE_CONIFER,
				VegetationTypeScript.VEG.SUBTROPICAL_FOREST,
				VegetationTypeScript.VEG.TROPICAL_RAINFOREST,
				VegetationTypeScript.VEG.TROPICAL_DRY_FOREST,
				VegetationTypeScript.VEG.CLOUD_FOREST,
				VegetationTypeScript.VEG.MONSOON_FOREST]},
			{"op": Op.POPULATION_GTE, "int_value": 15},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "forestry_worker", "float_value": 0.05},
				"add_weight": 25,
				"multiplier_q16": MUL_120,
				"reason": "靠林子吃饭的人还在",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 5},
				"add_weight": 20,
				"reason": "新仓旧仓都要木料",
			},
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 25},
				"add_weight": 15,
				"reason": "人多了，水和柴都紧",
			},
		],
		"options": [
			Shared.option(
				"protect_the_forest", "划为禁伐",
				"界石重新埋了一遍",
				"青石重新埋了一遍，屈木在石面上刻了新字。新仓的木料从外县买，多花了两成钱。那年夏天雨下得匀，坡下的泉眼没有断。",
				[
					Shared.knowledge(3, 540),
					Shared.birth(3, 540),
					Shared.manufacturing(-4, 360),
					Shared.bias(Ids.TAG_UNREST, 0.90, 540),
				]),
			Shared.option(
				"cut_it_all", "全砍了，改田",
				"坡上光了",
				"坡上光了，木头堆在城门口，新仓当年就立起来。第二年春汛，坡下的田里盖了一层黄泥，渠里淤了半尺。屈木搬去了别的村，地界上的青石不知被谁挖走。",
				[
					Shared.manufacturing(6, 540),
					Shared.agriculture(-3, 540),
					Shared.bias(Ids.TAG_UNREST, 1.25, 540),
				]),
			Shared.option(
				"sell_the_timber", "卖给人，换钱",
				"林子卖了",
				"林子卖给了外县的木商，砍了三年才砍完。钱进了公账，当年冬天全城吃了顿饱饭。第四年，坡上的草长不起来，风一过就起土。",
				[
					Shared.cash_in(2.0, 360),
					Shared.manufacturing(2, 360),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
		],
	}))
