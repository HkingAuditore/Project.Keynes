class_name NarrativeEventCatalogEnvoy
extends RefCounted

## 使节包：两个政治体之间的猜测（7 条孤立事件，era 3–7）。
##
##   era 3–7：贡船、通译、边市、背盟、婚约、马礼
##   era 4–7：密约
##
## 全部是脉冲入口，互不排程，也不读标记。七条各自站在一个"猜对面在想什么"的
## 时刻上：收下礼就等于认了什么、替谁说话、铁算不算违禁、纸上还写着盟约、
## 嫁过去的是人押过去的是信、回什么礼才不失体面、一份不能给人看的条款。
##
## 数值：全部走 narrative_event_shared.gd 的构造器，标签自动生成；城修正是
## ADD 1.0 族，负向自动切 `.cut`。
##
## 代价货币刻意错开（同一事件三条路互不相同）：
##   贡船=摊派 / 断市 / 盐贵；通译=摊派 / 风险 / 掉知识；边市=摊派 / 风险 / 盐铁贵；
##   背盟=摊派 / 断市 / 风险；婚约=摊派 / 风险 / 断市；马礼=摊派 / 风险 / 断市；
##   密约=摊派 / 断市 / 风险。
##
## 写作约束：不写真实国名与真实条约，只写方位（西边的汗国、下游的盟邦）；
## 器物走符节、国书、礼单、印泥、丝绸、马。

const Ids = preload("res://scripts/narrative/narrative_event_ids.gd")
const Shared = preload("res://scripts/narrative/narrative_event_shared.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")

const PACK_ID := &"envoy"
const PREFIX := "evt.envoy."

const CAST := [
	"苏勒", "葛逻", "何通", "康屠", "阿卜", "麦纥", "蔡五",
	"符节", "国书", "礼单", "印泥", "丝绸", "驿馆",
]

const MUL_115 := 75366
const MUL_120 := 78643
const MUL_125 := 81920


static func meta() -> Dictionary:
	return {
		"id": PACK_ID,
		"title": "使节",
		"theme": "两个政治体之间的猜测：礼、话、铁、纸",
		"era_band": "3-7",
		"prefix": PREFIX,
		"scale": "7 条中观/微观孤立",
		"cast": CAST,
		"node_ids": [
			String(Ids.EVT_ENVOY_TRIBUTE),
			String(Ids.EVT_ENVOY_INTERPRETER),
			String(Ids.EVT_ENVOY_BORDER),
			String(Ids.EVT_ENVOY_OATH),
			String(Ids.EVT_ENVOY_MARRIAGE),
			String(Ids.EVT_ENVOY_HORSES),
			String(Ids.EVT_ENVOY_SECRET),
		],
	}


static func append(catalog) -> void:
	if catalog == null:
		return
	var Op = NarrativeConditionScript.Op
	var Ch = NarrativeEventDefinitionScript.TriggerChannel

	# ═══ 贡船 ═════════════════════════════════════════════════════════════
	# 沿海、人口够多。船停在港口外，礼单已经写好了，收下就是"回礼"。
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_ENVOY_TRIBUTE),
		"title": "{settlement_name}·贡船",
		"body_text": "西边汗国的船在港口外下了锚，一共三条，最大那条的桅杆上挂着一面画着狼的旗。使臣葛逻带了国书和礼单，礼单用朱砂写，回礼该给什么、给多少，一条一条列着。他说这是回礼，不是纳贡，说完就不再看你。管码头的蔡五在舱口探头，说舱底压着一层盐包，压得船身都沉了。苏勒把符节放在案上，符节上的漆掉了一角。船就停在港口外，等到天黑就要走。",
		"image_key": "country.economy",
		"ai_visual_prompt": "Three foreign ships anchored outside a harbour, an envoy holding a vermilion gift list on the quay, dockworkers peering into a salt-loaded hold",
		"tags": ["envoy", "market"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 720,
		"min_era_index": 3,
		"max_era_index": 7,
		"conditions": [
			{"op": Op.IS_COASTAL, "bool_value": true},
			{"op": Op.POPULATION_GTE, "int_value": 15},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
				"add_weight": 20,
				"multiplier_q16": MUL_115,
				"reason": "城里有拿得出手的回礼",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "transport_worker", "float_value": 0.03},
				"add_weight": 25,
				"multiplier_q16": MUL_120,
				"reason": "码头养得起接船扛包的人",
			},
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "salt", "float_value": 1.15},
				"add_weight": 20,
				"reason": "盐贵，舱底那层盐更招人眼",
			},
		],
		"options": [
			Shared.option(
				"take_and_return", "收下，照单回礼",
				"回礼装了两条船",
				"丝绸和漆器装了两条船，跟着贡船一起走。葛逻在船头拱手，蔡五在岸上数货，数到最后一件，把册子合上了。",
				[
					Shared.cash_in(1.5, 540, "向本地人数最多的{primary_profession}征收其现金的 1.5%（礼单摊派）"),
					Shared.trade_capacity(5, 540),
					Shared.manufacturing(3, 540),
				]),
			Shared.option(
				"take_salt_only", "盐收下，礼先欠着",
				"欠着的东西最难还",
				"盐卸进官仓，回礼只给了一小半。葛逻没说什么，第二天船就走了，港里空出三段栈桥。",
				[
					Shared.manufacturing(-3, 540),
					Shared.staple(-2, 360),
					Shared.bias(Ids.TAG_MARKET, 0.90, 540),
				]),
			Shared.option(
				"keep_them_out", "把船挡在港外",
				"船在港口外停了一夜",
				"船在港口外停了一夜，天亮时收了帆，往北去了。港里的盐当天就贵了，蔡五在账上记了一笔。",
				[
					Shared.staple(4, 360),
					Shared.bias(Ids.TAG_FRONTIER, 0.90, 540),
				]),
		],
	}))

	# ═══ 通译 ═════════════════════════════════════════════════════════════
	# 商人够多、人口够多，才有"两边都能说话"的人。
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_ENVOY_INTERPRETER),
		"title": "{settlement_name}·通译",
		"body_text": "阿卜会说两种话。他替外邦商人记账，也替衙门抄文书，两边都给他钱，两边都不认他。今天西边来的车队要谈盐价和铁价，衙门里只剩他一个人听得懂那种话。康屠站在门外，把礼单卷成一卷，说这人靠不住，去年他给对面报过我们的底价。阿卜进来的时候，袖口上还沾着印泥，他先看礼单，再看你。他问，是替你们谈，还是替他们听。",
		"image_key": "country.economy",
		"ai_visual_prompt": "An interpreter with ink-stained cuffs standing between a merchant holding a rolled gift list and a magistrate's desk",
		"tags": ["envoy", "market", "people"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 720,
		"min_era_index": 3,
		"max_era_index": 7,
		"conditions": [
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.02},
			{"op": Op.POPULATION_GTE, "int_value": 12},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.04},
				"add_weight": 25,
				"multiplier_q16": MUL_120,
				"reason": "商人多，两种话天天要碰",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
				"add_weight": 15,
				"reason": "有衙门，才有名分可给",
			},
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "salt", "float_value": 1.10},
				"add_weight": 15,
				"reason": "盐价一乱，就得有人开口",
			},
		],
		"options": [
			Shared.option(
				"give_him_office", "给他名分，让他去谈",
				"他站在帘子前面",
				"阿卜换了衙门发的衣裳，站在帘子前面替我们说话。谈成之后他要了一份文书，写明他是谁的人。",
				[
					Shared.cash_in(1.0, 360, "向本地人数最多的{primary_profession}征收其现金的 1%（通译的俸与纸墨）"),
					Shared.trade_capacity(4, 540),
					Shared.manufacturing(2, 540),
				]),
			Shared.option(
				"let_him_run_both", "让他两边跑，不给名分",
				"两头都有他的位置",
				"阿卜还是两边跑。市上的价他先知道，衙门里的意思对面也先知道。有人开始绕开他去谈。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
					Shared.trade_capacity(6, 540),
				]),
			Shared.option(
				"use_our_own", "换掉他，用自己人",
				"换上来的人听得慢",
				"换上来的人只会一半的话，谈到一半要停下来问。车队等了三天，把货转去了下游的盟邦。印泥在文书上按了三回，才按对地方。",
				[
					Shared.manufacturing(-3, 540),
					Shared.bias(Ids.TAG_UNREST, 0.90, 540),
				]),
		],
	}))

	# ═══ 边市 ═════════════════════════════════════════════════════════════
	# 商人更多。开不开边市，铁器算不算违禁。
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_ENVOY_BORDER),
		"title": "{settlement_name}·边市",
		"body_text": "边市的木栅是新砍的，还带着树皮，两边的摊子隔着一条干沟。对面牵马来换铁，我们这边摆出去的是锅、犁和钉子。康屠说，按旧例铁器不许出境，可对面出三倍的价，一车铁能换回四车盐。何通把符节从梁上取下来，把律条翻到那一页，指头压在纸上，纸边都被压皱了。有人提议把铁熔了重铸成农具，样子变了，里头还是铁。栅栏外那几匹马开始刨地，鼻子喷出一团白气。",
		"image_key": "country.economy",
		"ai_visual_prompt": "A border market of fresh wooden fencing, iron pots and ploughs on one side, horses on the other, a gate officer holding a law scroll",
		"tags": ["envoy", "market", "frontier"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 3,
		"max_era_index": 7,
		"conditions": [
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.03},
			{"op": Op.POPULATION_GTE, "int_value": 12},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.05},
				"add_weight": 30,
				"multiplier_q16": MUL_125,
				"reason": "做买卖的人堵在栅栏外面",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
				"add_weight": 15,
				"reason": "城里有作坊，铁才拿得出来",
			},
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "wrought_iron", "float_value": 1.15},
				"add_weight": 20,
				"reason": "铁贵了，人人想往外卖",
			},
		],
		"options": [
			Shared.option(
				"open_ban_iron", "开市，铁器一律不准出",
				"关口上多了一把锁",
				"市开了，铁器留在这一边。对面的商人围着锅和犁看了半天，最后只买走两车陶器。何通每天黄昏亲自去锁栅门。",
				[
					Shared.cash_in(1.0, 540, "向本地人数最多的{primary_profession}征收其现金的 1%（设卡与守栅的工食）"),
					Shared.trade_capacity(6, 540),
					Shared.bias(Ids.TAG_UNREST, 0.90, 540),
				]),
			Shared.option(
				"open_sell_anything", "开市，什么都能卖",
				"铁出了关",
				"铁锅、铁犁，连打坏的刀都卖了。第七天，何通在关口上看见对面的人腰里别着用我们的钉子打的刀。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.25, 540),
					Shared.trade_capacity(8, 540),
					Shared.manufacturing(3, 540),
				]),
			Shared.option(
				"keep_it_shut", "不开市，守旧例",
				"栅栏没拆",
				"栅栏没拆，两边的人隔着干沟喊价，喊了一整天，一桩也没成。入冬前，盐涨了，铁也涨了。",
				[
					Shared.staple(3, 360),
					Shared.bias(Ids.TAG_UNREST, 0.90, 540),
				]),
		],
	}))

	# ═══ 背盟 ═════════════════════════════════════════════════════════════
	# 城里像样、人口够多，才有一份值得背的盟约。这一条走两条分支的博弈。
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_ENVOY_OATH),
		"title": "{settlement_name}·背盟",
		"body_text": "盟约签了两年，纸还压在匣子里，印泥的红已经发黑。今年开春，对面的骑兵过了河，占了三个村子，说是来追逃人。葛逻带着国书来，说这不是汗王的令，是下面的人自作主张。管兵的蔡五在城头站了一夜，回来说河对岸的火堆数不清。按盟约我们该出兵，出兵就要钱；不按盟约，往后谁还肯跟我们签。苏勒把国书摊在案上，纸角被风掀起，又落下去。",
		"image_key": "family.house",
		"ai_visual_prompt": "A two-year-old treaty sealed in red ink on a desk, a herald with a letter of credence, watchfires across a river at night",
		"tags": ["envoy", "unrest", "court"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 105,
		"cooldown_days": 900,
		"min_era_index": 3,
		"max_era_index": 7,
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
			{"op": Op.POPULATION_GTE, "int_value": 15},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 5},
				"add_weight": 20,
				"reason": "城大了，盟约上的名字才值钱",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "soldier", "float_value": 0.04},
				"add_weight": 25,
				"multiplier_q16": MUL_120,
				"reason": "城里养着兵，出不出兵是件现成的事",
			},
			{
				"condition": {"op": Op.COHORT_SATISFACTION_LTE, "float_value": 0.45},
				"add_weight": 20,
				"reason": "人心本来就不稳，谁都不想再添一件事",
			},
		],
		"options": [
			Shared.gamble(
				"honour_the_oath", "按盟约出兵",
				Shared.branch(42598, "对面退了",
					"我们的旗到了河边，对面的火堆一夜之间少了一半。葛逻送来一封国书，说这是误会，说他回去一定查。",
					[
						Shared.cash_in(2.0, 540, "向本地人数最多的{primary_profession}征收其现金的 2%（出兵的开拔钱）"),
						Shared.supply(10, 540),
						Shared.trade_capacity(4, 540),
					]),
				Shared.branch(22938, "打了一场",
					"两军在河滩上撞了一回，各自退回去收尸。盟约还压在匣子里，谁也没提它。",
					[
						Shared.cash_in(2.5, 540, "向本地人数最多的{primary_profession}征收其现金的 2.5%（抚恤与补械）"),
						Shared.supply(8, 360),
						Shared.bias(Ids.TAG_UNREST, 0.90, 540),
					])),
			Shared.option(
				"tear_it_up", "不履约，把国书收进库",
				"库里多了一卷纸",
				"国书收进库里，出兵的事再没人提。对面的商队改道走了下游，市上的铜料一夜之间断了。",
				[
					Shared.manufacturing(-4, 540),
					Shared.supply(8, 360),
					Shared.bias(Ids.TAG_UNREST, 0.90, 540),
				]),
			Shared.option(
				"stall_the_army", "只做样子，按兵不动",
				"兵在城外扎了三天",
				"兵在城外扎了三天，没过大河，也没回家。河对岸的人每天都在数这边的灶烟。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
					Shared.agriculture(2, 540),
					Shared.supply(8, 360),
				]),
		],
	}))

	# ═══ 婚约 ═════════════════════════════════════════════════════════════
	# 人口够多、城里有两处像样的屋子，才谈得上"嫁过去的是人，押过去的是信"。
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_ENVOY_MARRIAGE),
		"title": "{settlement_name}·婚约",
		"body_text": "西边汗国来求亲，要的是你族里那个会写字的姑娘。礼物装了六车，丝绸压在箱底，礼单头一行写着她的名字。何通说，嫁过去的不只是人，还有一整套陪嫁的工匠和种子。康屠算过账，这桩婚事办下来，市上三年收的税都不够。姑娘自己没说话，只在廊下站了一会儿，把苏勒递给她的符节还了回去。日子定在秋天，秋天之前得回话。",
		"image_key": "family.house",
		"ai_visual_prompt": "Six gift carts of silk before a hall, a gift list with one name at its head, a young woman returning a tally token in a corridor",
		"tags": ["envoy", "court", "people"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 900,
		"min_era_index": 3,
		"max_era_index": 7,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 12},
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
				"add_weight": 20,
				"reason": "屋子多了，陪嫁才搬得出手",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "scribe", "float_value": 0.02},
				"add_weight": 20,
				"multiplier_q16": MUL_115,
				"reason": "会写字的人家，才有人来求",
			},
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "wheat_grain", "float_value": 1.15},
				"add_weight": 15,
				"reason": "粮贵，一桩婚事能换回一冬的粮",
			},
		],
		"options": [
			Shared.option(
				"send_her_with_gifts", "把人嫁过去，厚礼陪送",
				"车队走得比礼单还长",
				"送亲的车队比礼单还长，走到河边停了一停。姑娘掀开车帘看了一眼对岸，把帘子放下了。",
				[
					Shared.cash_in(2.0, 540, "向本地人数最多的{primary_profession}征收其现金的 2%（陪嫁摊派）"),
					Shared.trade_capacity(6, 540),
					Shared.bias(Ids.TAG_COURT, 0.90, 540),
				]),
			Shared.option(
				"send_the_list_only", "人留下，只送一份礼单",
				"礼单退了回来",
				"礼单原样退回来，角上多了一个火漆印。何通把纸收好，说这一页往后还有用。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
					Shared.manufacturing(3, 540),
					Shared.knowledge(2, 540),
				]),
			Shared.option(
				"wait_for_autumn", "拖着，秋天再回话",
				"秋天到了",
				"秋天到了，话没回。对面的使臣在驿馆住了两个月，最后自己走了，走的时候没跟任何人打招呼。",
				[
					Shared.manufacturing(-3, 540),
					Shared.bias(Ids.TAG_UNREST, 0.90, 540),
				]),
		],
	}))

	# ═══ 马礼 ═════════════════════════════════════════════════════════════
	# 有商人、人口够。二十匹好马进门，回什么礼才不失体面。
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_ENVOY_HORSES),
		"title": "{settlement_name}·马礼",
		"body_text": "对面送来二十匹马，都是四岁的口，毛色刷得发亮，牵进马厩时蹄子上还裹着布。送礼的葛逻说这是汗王的一点心意，说完把礼单递上来，站在那儿等回礼。麦纥蹲在马腿边看蹄铁，说这蹄铁打得好，比我们作坊的还结实。市上的规矩是回礼要比收的多一分，可仓里剩下的丝绸只够一半。苏勒让人把马牵到后院，先不卸鞍。礼单摊在案上，墨还没干透。",
		"image_key": "economy.resource",
		"ai_visual_prompt": "Twenty well-groomed horses with cloth-wrapped hooves led into a stable, a groom inspecting a hoof, a gift list drying on a desk",
		"tags": ["envoy", "market"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 3,
		"max_era_index": 7,
		"conditions": [
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.02},
			{"op": Op.POPULATION_GTE, "int_value": 10},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.03},
				"add_weight": 25,
				"multiplier_q16": MUL_120,
				"reason": "有商人，马才卖得出去，礼才办得成",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
				"add_weight": 15,
				"reason": "有厩有坊，才看得出马蹄铁的好坏",
			},
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "wrought_iron", "float_value": 1.10},
				"add_weight": 15,
				"reason": "铁贵，回礼的账就不好算",
			},
		],
		"options": [
			Shared.option(
				"return_silk", "收下马，回赠丝绸",
				"马进了厩",
				"马进了厩，丝绸装了四车送出去。麦纥给每匹马都钉了新蹄铁，用的是仓里最后一块好铁。",
				[
					Shared.cash_in(1.5, 540, "向本地人数最多的{primary_profession}征收其现金的 1.5%（回礼的丝绸摊派）"),
					Shared.stock("horses", 10),
					Shared.trade_capacity(4, 540),
				]),
			Shared.option(
				"return_iron", "收下马，回赠铁器",
				"铁器出了关",
				"回礼里头有铁锅和铁犁，还有两把没开刃的刀。对面的使臣看了看刀，笑了，把礼单收进袖子。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
					Shared.manufacturing(4, 540),
					Shared.trade_capacity(4, 540),
				]),
			Shared.option(
				"send_them_back", "原样退回，一匹不留",
				"马队原路回去",
				"马队原路回去，蹄子踏在来时的车辙上。麦纥站在门口看了很久，说这批马蹄子好，可惜了。",
				[
					Shared.manufacturing(-3, 540),
					Shared.bias(Ids.TAG_MARKET, 0.90, 540),
				]),
		],
	}))

	# ═══ 密约 ═════════════════════════════════════════════════════════════
	# 城里像样、人口够多，才有资格收到一份不能给人看的条款。era 4–7。
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_ENVOY_SECRET),
		"title": "{settlement_name}·密约",
		"body_text": "国书的夹层里还夹着一张纸，字比正文字小，写的是两国在河上怎么分兵、谁先过桥。送书的人说这张纸不能给第三个人看，看完就烧，印泥是另配的，验不出来。何通把纸对着窗，透光看了两遍，说这上头没有汗王的印。苏勒问他信不信送书的人，何通说不信，可条款对我们有利。灯芯烧到一半，纸边上已经卷了起来。屋外有人走动，脚步声在门口停了一下。",
		"image_key": "family.house",
		"ai_visual_prompt": "A hidden clause on thin paper held against a window, a letter of credence with two different seals, a lamp burning low",
		"tags": ["envoy", "court"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 85,
		"cooldown_days": 900,
		"min_era_index": 4,
		"max_era_index": 7,
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
			{"op": Op.POPULATION_GTE, "int_value": 12},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 5},
				"add_weight": 20,
				"reason": "城大了，密约才有地方锁",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "scribe", "float_value": 0.02},
				"add_weight": 20,
				"multiplier_q16": MUL_115,
				"reason": "有人会看纸上的字，才看得出夹层",
			},
			{
				"condition": {"op": Op.COHORT_SATISFACTION_LTE, "float_value": 0.55},
				"add_weight": 15,
				"reason": "人心浮着，密约这种事就有人愿意试",
			},
		],
		"options": [
			Shared.option(
				"sign_and_lock", "签下，锁进库房",
				"两把钥匙",
				"条款签了，锁进库房最里那一格，两把钥匙，一把在你这里。何通在封皮上又压了一道印泥。",
				[
					Shared.cash_in(2.0, 540, "向本地人数最多的{primary_profession}征收其现金的 2%（密约的定金）"),
					Shared.trade_capacity(6, 540),
					Shared.supply(10, 540),
				]),
			Shared.option(
				"refuse_and_copy", "不签，抄一份送回去",
				"抄本送了回去",
				"抄本送回去，正本留下。何通把纸晾在窗台上等墨干，晾了三天，风吹走了一角。",
				[
					Shared.manufacturing(-3, 540),
					Shared.knowledge(4, 540),
					Shared.bias(Ids.TAG_COURT, 0.90, 540),
				]),
			Shared.option(
				"sign_half", "签一半，留一条空着",
				"空着的那一条",
				"空着的那一条谁也没提。半年后对面来问，何通说原本就是这样写的，说完把国书往前推了推。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.25, 540),
					Shared.trade_capacity(3, 540),
					Shared.manufacturing(2, 540),
				]),
		],
	}))
