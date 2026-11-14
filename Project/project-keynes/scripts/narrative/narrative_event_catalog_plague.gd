class_name NarrativeEventCatalogPlague
extends RefCounted

## 疫与医包：热病来了以后，人怎么过日子（7 条，全部孤立）。
##
##   疫船（沿海+人口，era 2–8）· 隔离（人口+屋，era 2–9）· 产褥热（人口，era 1–8）
##   药圃（人口+屋，era 1–7）· 医院（屋+人口，era 5–9）
##   疫苗（屋+学者，era 6–9）· 庸医（人口，era 2–9）
##
## 没有一条接链：不写旗标、不排后续，全部走 PULSE_SAMPLED 自己进池。
## 两个"赌一把"：隔离只封病家、疫苗先拿孩子试，其余十九条结果都是定的。
##
## 数值口径：这一包不解释病理，只结账。代价落在出生率、主食开销、本地人头上的摊派、
## 与人心（unrest / market 类事件权重）上；产出修正只用来表示一条街停了工这种后果。
## 时代白话一律说热病、烂喉、痘，不写真实疫病名，也不借真实人物。

const Ids = preload("res://scripts/narrative/narrative_event_ids.gd")
const Shared = preload("res://scripts/narrative/narrative_event_shared.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")
const VegetationTypeScript = preload("res://scripts/geography/vegetation_type.gd")

const PACK_ID := &"plague"
const PREFIX := "evt.plague."

const CAST := [
	"铁角湾", "柳七", "白布条", "烂泥渡", "陆阿满", "记名册", "石灰",
	"葛四婶", "铜盆", "邢先生", "费伯", "苦蒿", "药圃",
	"沈司医", "痘痂", "岑九",
]

const MUL_110 := 72090
const MUL_115 := 75366
const MUL_120 := 78643
const MUL_130 := 85197


static func meta() -> Dictionary:
	return {
		"id": PACK_ID,
		"title": "疫与医",
		"theme": "热病过境时，人怎么分饭、封街、洗手、试药",
		"era_band": "1-9",
		"prefix": PREFIX,
		"scale": "7 条中观/微观孤立",
		"cast": CAST,
		"node_ids": [
			String(Ids.EVT_PLAGUE_SHIP),
			String(Ids.EVT_PLAGUE_QUARANTINE),
			String(Ids.EVT_PLAGUE_MIDWIFE),
			String(Ids.EVT_PLAGUE_HERBS),
			String(Ids.EVT_PLAGUE_HOSPITAL),
			String(Ids.EVT_PLAGUE_VACCINE),
			String(Ids.EVT_PLAGUE_QUACK),
		],
	}


static func append(catalog) -> void:
	if catalog == null:
		return
	var Op = NarrativeConditionScript.Op
	var Ch = NarrativeEventDefinitionScript.TriggerChannel

	# ═══ 一 · 疫船 ═════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_PLAGUE_SHIP),
		"title": "{settlement_name}·疫船",
		"body_text": "铁角湾口外停着一条三桅船，锚链放到了底，船头挂一条湿透的白布条。柳七划小艇过去看了一眼，回来说舱里躺着七八个人，身上烫得能烙饼，还有人气着要往岸上跳。船主站在船尾喊，货是盐和铁，卸了就走，人死不死跟岸上没关系。码头上扛包的都停了手，谁也不敢去接缆；粮行的伙计把秤收了，说这一船货进了仓，米价就得自己往上蹦。柳七把小艇拴回桩上，蹲在岸边等一句准话。",
		"image_key": "hydrology.water",
		"ai_visual_prompt": "A three-masted ship anchored outside a small harbour, a strip of white cloth on its bow, a rowboat with one man watching from the water",
		"tags": ["plague", "market", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 720,
		"min_era_index": 2,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.IS_COASTAL, "bool_value": true},
			{"op": Op.POPULATION_GTE, "int_value": 12},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.02},
				"multiplier_q16": MUL_120,
				"reason": "码头上有人做买卖，才有人敢接这条船",
			},
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "salt", "float_value": 1.05},
				"add_weight": 20,
				"reason": "盐一紧，就有人想赌这一船",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
				"add_weight": 15,
				"reason": "屋挤在一处，病传得快",
			},
		],
		"options": [
			Shared.option(
				"let_it_dock", "准它进港卸货",
				"货卸了，病也上了岸",
				"盐包一袋袋过秤，当天夜里码头就有人发起热来。柳七把自家门板卸下来，抬了三趟人。",
				[
					Shared.trade_capacity(5, 360),
					Shared.manufacturing(4, 360),
					Shared.birth(-4, 540),
				]),
			Shared.option(
				"burn_it_off", "放火烧船，赶走",
				"口外烧了一夜",
				"火从后舱烧到桅杆，烧了一夜。船主跳了水，捞上来的时候手里还攥着半张货单。",
				[
					Shared.manufacturing(-4, 540),
					Shared.staple(4, 540),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
			Shared.option(
				"hold_at_anchor", "扣在口外，送水送饭",
				"小艇一天两趟",
				"小艇一天两趟，饭桶用绳子吊上去，空桶再吊下来。到第九天，船上没人应声了。",
				[
					Shared.cash_in(1.2, 360,
						"向本地人数最多的{primary_profession}征收其现金的 1.2%（护港摊派，按户收）"),
					Shared.staple(3, 360),
				]),
		],
	}))

	# ═══ 二 · 隔离 ═════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_PLAGUE_QUARANTINE),
		"title": "{settlement_name}·隔离",
		"body_text": "烂泥渡最先病倒的是个挑水的，第二天他隔壁两家也躺下了。县里来人，把三条巷子的口用板子拦住，拦板一人高的地方系一条白布条。陆阿满被派去送饭，一天两趟，饭桶放在巷口的石墩上，人退开十步，等里面的人自己来提。他手里有一本记名册，谁家几口人，谁家昨天没出来提饭，都要画一笔。有人说这样封着，饿死的人会比病死的人多；也有人说，白布条一解，全城都得躺下。石灰堆在巷口，风一吹就起白烟。",
		"image_key": "map.construction",
		"ai_visual_prompt": "A narrow lane blocked by planks with a white cloth strip, a meal bucket left on a stone, lime dust blowing at dusk",
		"tags": ["plague", "unrest", "people"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 105,
		"cooldown_days": 660,
		"min_era_index": 2,
		"max_era_index": 9,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 12},
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
				"add_weight": 25,
				"multiplier_q16": MUL_110,
				"reason": "巷子越密，越封不住",
			},
			{
				"condition": {"op": Op.COHORT_SATISFACTION_LTE, "float_value": 0.45},
				"add_weight": 20,
				"reason": "人心已经散了，封街就有人翻墙",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "agricultural_worker", "float_value": 0.25},
				"multiplier_q16": MUL_115,
				"reason": "种地的人一天不出门，地就荒一天",
			},
		],
		"options": [
			Shared.option(
				"nail_the_lanes", "钉死巷口，谁也不许出",
				"巷口钉死了",
				"板子钉到第三层，里面有人拿扁担往外捅。第七天，送饭的换成了穿号衣的人。",
				[
					Shared.manufacturing(-4, 540),
					Shared.staple(5, 540),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
			Shared.gamble(
				"seal_only_the_sick", "只封病家，别家照常",
				Shared.branch(39322, "册子停在第四页", # 六成
					"送饭的册子停在第四页，往后再没添新名字。撤板子那天，有人在墙根晒被子。",
					[
						Shared.agriculture(3, 360),
						Shared.cash_out(1.0, 360),
					]),
				Shared.branch(26214, "板子撤早了", # 四成
					"板子撤到一半，隔壁巷子又倒下两个。县里重新钉，钉得比上回还密。",
					[
						Shared.birth(-5, 540),
						Shared.bias(Ids.TAG_UNREST, 1.25, 540),
					])),
			Shared.option(
				"move_them_out", "抬到城外，雇人照看",
				"棚子搭在河滩上",
				"棚子四面透风，但离井远。雇来的人一天三十文，先付了半个月。",
				[
					Shared.cash_in(1.5, 540,
						"向本地人数最多的{primary_profession}征收其现金的 1.5%（雇人照看的工钱）"),
					Shared.birth(-3, 540),
					Shared.knowledge(3, 360),
				]),
		],
	}))

	# ═══ 三 · 产褥热 ═══════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_PLAGUE_MIDWIFE),
		"title": "{settlement_name}·产褥热",
		"body_text": "葛四婶的手接了三代人，指甲缝里是洗不掉的褐色。邢先生从外头回来，说产后的热病是从手上带进去的，接生之前要用铜盆里的滚水烫过，指甲剪到肉。葛四婶听着，把手在围裙上擦了两下，说她接生的孩子没一个坏的，倒是先生们开的方子吃死过人。可这半个月，烂泥渡那边连着走了两个产妇，都是她接的。她把铜盆端到门口，看里面的水汽一点点散掉，没有伸手。",
		"image_key": "family.house",
		"ai_visual_prompt": "An old midwife with stained hands standing at a doorway beside a steaming copper basin, a young physician with a bag behind her",
		"tags": ["plague", "people", "faith"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 1,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 10},
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 1},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
				"add_weight": 15,
				"reason": "人口聚起来，产床就不够用",
			},
			{
				"condition": {"op": Op.COHORT_SATISFACTION_LTE, "float_value": 0.50},
				"add_weight": 20,
				"reason": "日子紧的人家，请不起大夫",
			},
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "wheat_grain", "float_value": 1.10},
				"add_weight": 15,
				"reason": "粮贵，产妇吃得更少",
			},
		],
		"options": [
			Shared.option(
				"boil_the_basin", "洗手，用滚水烫过",
				"水凉了再换一盆",
				"她把指甲剪到肉，手背烫得发红。那一年接生的孩子，活下来的比往年多。",
				[
					Shared.birth(6, 540),
					Shared.tools(3, 540),
					Shared.knowledge(2, 360),
				]),
			Shared.option(
				"keep_the_old_way", "照老规矩，不洗",
				"褐色洗不掉",
				"她照旧不洗，只在围裙上擦两下。第二年开春，又有两家在产床上没了人。",
				[
					Shared.birth(-5, 540),
					Shared.knowledge(-2, 360),
				]),
			Shared.option(
				"wash_in_summer_only", "入夏才洗，冬天省柴",
				"水只在伏天烧",
				"三伏天她烧水，进了腊月就省了。她说手冻裂了容易烂，这话没人听得懂，只当她舍不得柴。",
				[
					Shared.birth(2, 540),
					Shared.knowledge(-3, 540),
				]),
		],
	}))

	# ═══ 四 · 药圃 ═════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_PLAGUE_HERBS),
		"title": "{settlement_name}·药圃",
		"body_text": "坡上那片药圃是费伯一锄一锄开出来的，最里头长着苦蒿。叶子揉碎了有股冲鼻的苦味，煮水喝下去，烧能退半截。这一季病人多，来讨药的人排到篱笆外头。费伯说苦蒿成片要三年，根一断，坡上就得空上几年；来讨药的人说，眼下这个人今夜就要烧过去。他蹲下去，把锄头横在垄上，问了一句，采几把，谁说了算。",
		"image_key": "economy.resource",
		"ai_visual_prompt": "A hillside herb plot fenced with thorn branches, an old gatherer squatting with a hoe across the rows, a queue of villagers at the gate",
		"tags": ["plague", "people", "land"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 660,
		"min_era_index": 1,
		"max_era_index": 7,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 10},
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 1},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.VEGETATION_IN,
					"int_list": [VegetationTypeScript.VEG.TEMPERATE_DECIDUOUS,
						VegetationTypeScript.VEG.TEMPERATE_CONIFER,
						VegetationTypeScript.VEG.SUBTROPICAL_FOREST,
						VegetationTypeScript.VEG.TEMPERATE_GRASSLAND]},
				"multiplier_q16": MUL_120,
				"reason": "坡上有林子，才长得住药",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
				"add_weight": 20,
				"reason": "有人家，才有人开圃",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "agricultural_worker", "float_value": 0.30},
				"add_weight": 10,
				"reason": "种地的人也认得几味草",
			},
		],
		"options": [
			Shared.option(
				"dig_it_all", "连根挖，先救眼前",
				"坡上只剩翻过的土",
				"连根挖了三天，坡上只剩翻过的土。第二年开春再去看，一株苦蒿也没冒头。",
				[
					Shared.birth(5, 540),
					Shared.agriculture(-4, 540),
				]),
			Shared.option(
				"leaves_only", "只摘叶，把根留住",
				"叶子摘了一半",
				"只摘叶，根留在土里。那年冬天烧退得慢，扛不住的人比往年多几个。",
				[
					Shared.birth(-3, 540),
					Shared.knowledge(3, 360),
				]),
			Shared.option(
				"fence_and_buy", "封了坡，去外头买药",
				"药从水路来",
				"坡用荆条围了，药从水路运来，一包一包拆开验。费伯每天去坡上转一圈，什么也不采。",
				[
					Shared.cash_in(1.5, 540,
						"向本地人数最多的{primary_profession}征收其现金的 1.5%（买药摊派）"),
					Shared.manufacturing(-3, 540),
				]),
		],
	}))

	# ═══ 五 · 医院 ═════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_PLAGUE_HOSPITAL),
		"title": "{settlement_name}·医院",
		"body_text": "邢先生在烂泥渡头上租了两间空仓，摆了十二张床，床板是从旧戏台上拆的。开张半个月，床上躺满了人，多半是扛包的、拉纤的、给人洗衣裳的。他不收诊金，药钱记在一本记名册上，到月底一算，亏空比上个月又厚了一层。管账的伙计说，照这样下去，仓租下个月就付不出，药铺也不肯再赊。墙角撒过石灰，扫起来还是一层灰。邢先生把册子翻到最后一页，指头在那片空白上按了按，合上。",
		"image_key": "family.house",
		"ai_visual_prompt": "Two rented warehouses turned into a ward, rows of plank beds with the poor, a physician holding a ledger open at a blank page",
		"tags": ["plague", "people", "market"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 780,
		"min_era_index": 5,
		"max_era_index": 9,
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
			{"op": Op.POPULATION_GTE, "int_value": 18},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 5},
				"add_weight": 25,
				"multiplier_q16": MUL_110,
				"reason": "屋多了，才腾得出两间空仓",
			},
			{
				"condition": {"op": Op.COHORT_SATISFACTION_LTE, "float_value": 0.40},
				"add_weight": 25,
				"reason": "人已经撑不住了，才会来躺这两间仓",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "industrial_worker", "float_value": 0.08},
				"multiplier_q16": MUL_115,
				"reason": "做工的人一病，整条街就停了",
			},
		],
		"options": [
			Shared.option(
				"ask_the_treasury", "请国库支一份钱粮",
				"县里只批了一半",
				"县里批了一半，另一半让医馆自己想办法。床没减，饭减了一顿。",
				[
					Shared.cash_out(1.5, 540),
					Shared.knowledge(4, 360),
					Shared.manufacturing(-3, 540),
				]),
			Shared.option(
				"levy_the_households", "按户摊一份药钱",
				"收钱的走到第三趟",
				"钱是收上来了。收钱的人走到第三趟，门口就有人把门关了。",
				[
					Shared.cash_in(2.0, 540),
					Shared.birth(2, 540),
				]),
			Shared.option(
				"let_the_firms_endow", "请商号认捐，名字刻门上",
				"牌上刻了名字",
				"捐得多的刻在前头。穷人还是睡在最后两张床上，风从门缝里进来。",
				[
					Shared.cash_out(1.0, 540),
					Shared.bias(Ids.TAG_MARKET, 1.15, 540),
					Shared.knowledge(-2, 540),
				]),
		],
	}))

	# ═══ 六 · 疫苗 ═════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_PLAGUE_VACCINE),
		"title": "{settlement_name}·疫苗",
		"body_text": "沈司医从南边回来，怀里一小包痘痂，油纸包着，外头再套一层布袋。他说把痂研成末，吹进孩子的鼻孔，出过一次轻的，往后就不再出重的。城里没人肯先试，连药铺的伙计都把袖子放下来，退到门后。柳七家的老二前年出痘，烧了九天，退下来的时候耳朵就听不见了；可要拿孩子去试一样没验过的东西，柳七把手按在门框上，没有点头。沈司医把油纸包收回怀里，说他再等一年，等南边的信。这一年里还会有多少孩子烧过去，他不说。",
		"image_key": "country.economy",
		"ai_visual_prompt": "A physician unwrapping a small oil-paper packet of dried scabs, a father with his hand flat on a doorframe, neighbours watching from behind a counter",
		"tags": ["plague", "people", "era"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 840,
		"min_era_index": 6,
		"max_era_index": 9,
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "scholar", "float_value": 0.01},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "scholar", "float_value": 0.03},
				"multiplier_q16": MUL_130,
				"reason": "有读书人，才有人肯试",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
				"add_weight": 20,
				"reason": "有屋子收得住孩子",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 7},
				"add_weight": 15,
				"reason": "时候到了，南边的信才有人信",
			},
		],
		"options": [
			Shared.gamble(
				"try_it_on_a_child", "挑一个孩子先试",
				Shared.branch(42598, "胳膊上起了两个小疱", # 六成半
					"胳膊上起了两个小疱，烧两天就退了。转过年来，城里出痘的孩子多半只出一身疹子。",
					[
						Shared.birth(6, 540),
						Shared.knowledge(5, 360),
						Shared.cash_out(1.0, 540),
					]),
				Shared.branch(22938, "试的那个孩子没了", # 三成半
					"试的那个孩子烧到第四天就没了。柳七把人埋了，回头把剩下的痘痂全烧了。",
					[
						Shared.birth(-7, 540),
						Shared.bias(Ids.TAG_UNREST, 1.30, 540),
					])),
			Shared.option(
				"wait_one_more_year", "再等一年，等南边的信",
				"信到的时候是冬天",
				"信上说南边试过了，管用。这一年里，城里又添了十几座小坟。",
				[
					Shared.knowledge(-4, 540),
					Shared.birth(-4, 540),
				]),
			Shared.option(
				"buy_a_volunteer", "出钱买人来试",
				"有人为了钱来",
				"来的是寡妇家的孩子，价钱谈了三回。钱是各户凑上来的，寡妇领了，没回头。",
				[
					Shared.cash_in(2.0, 540,
						"向本地人数最多的{primary_profession}征收其现金的 2%（凑给试药人家的钱）"),
					Shared.birth(-2, 540),
					Shared.cash_out(1.0, 540),
				]),
		],
	}))

	# ═══ 七 · 庸医 ═════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_PLAGUE_QUACK),
		"title": "{settlement_name}·庸医",
		"body_text": "岑九在集市口摆一张桌子，桌上七个一模一样的瓶子，瓶口用红布扎着。他说这药治一切热病、烂喉、身上起的东西，一瓶下去当天见效。来买的人从烂泥渡一路排到卖鱼的摊子前头，比邢先生那边多出三倍。邢先生站在对面看了一炷香，看见有人把药瓶揣进怀里，那人的孩子正烧得眼睛发直。他回身去抓药，手在药柜上停了停，说这药里就是糖水和烧酒。说这话的时候，排队的人往他这边看了一眼，又转回去了。",
		"image_key": "country.economy",
		"ai_visual_prompt": "A quack's table at a market corner with seven identical bottles tied with red cloth, a long queue, a physician watching from across the street",
		"tags": ["plague", "market", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 660,
		"min_era_index": 2,
		"max_era_index": 9,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 12},
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 1},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.COHORT_SATISFACTION_LTE, "float_value": 0.45},
				"add_weight": 25,
				"reason": "大夫治不好的时候，人就去找便宜的",
			},
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "wheat_grain", "float_value": 1.15},
				"add_weight": 20,
				"reason": "粮一贵，买药的钱就只够买一瓶",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.01},
				"multiplier_q16": MUL_115,
				"reason": "集市上有人流，摊子才摆得下去",
			},
		],
		"options": [
			Shared.option(
				"drive_him_out", "赶出城，砸了摊子",
				"摊子砸了，人还在",
				"瓶子碎了一地，糖水渗进土里。第三天，他在城外柳树下又摆了一张。",
				[
					Shared.knowledge(3, 360),
					Shared.bias(Ids.TAG_UNREST, 1.25, 540),
				]),
			Shared.option(
				"tax_him", "让他摆，抽他的税",
				"官凭贴在摊角上",
				"一张官凭贴在摊子角上，每月抽钱。买药的人看见官凭，买得更放心了。",
				[
					Shared.cash_in(1.5, 540),
					Shared.birth(-3, 540),
				]),
			Shared.option(
				"test_it_in_the_street", "当街验他的药",
				"碗里的东西分了三层",
				"碗里的东西沉淀一夜，分成三层。看的人少了一半，剩下一半说大夫是嫉妒他。",
				[
					Shared.knowledge(-3, 540),
					Shared.cash_out(0.5, 540),
				]),
		],
	}))
