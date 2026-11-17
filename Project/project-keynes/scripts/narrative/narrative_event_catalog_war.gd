class_name NarrativeEventCatalogWar
extends RefCounted

## 战争包：六条事实驱动 + 六条战时脉冲。
##
## 事实驱动（GameplayEventBus，narrative_event_service 的类型号）：
##   40 宣战 / 41 战事结束 / 42 会战 / 43 城池易手 / 44 部队被歼 / 45 国家被吞并
## 战时脉冲（读军事快照）：
##   征兵、欠饷、伤兵、难民、军市、战后清算
##
## 门槛只用三个新算子：AT_WAR(45)、SOLDIERS_TOTAL_GTE(46)、WAR_GOING_BADLY(47)。
## 效果仍用通用杠杆（现金、主食、出生、部门产出、军粮、动荡权重），不新增写接口。

const Ids = preload("res://scripts/narrative/narrative_event_ids.gd")
const Shared = preload("res://scripts/narrative/narrative_event_shared.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")
const NarrativeEffectSpecScript = preload("res://scripts/narrative/narrative_effect_spec.gd")

const PACK_ID := &"war"
const PREFIX := "evt.war."

const CAST := [
	"韦顺", "韩仓", "李七", "周敬之", "罗阿石", "柳嫂", "邬三", "常五", "苗大", "石宝",
	"城门", "官道", "城隍庙", "官仓", "驿站",
]

const MUL_090 := 58982
const MUL_110 := 72090
const MUL_115 := 75366
const MUL_120 := 78643
const MUL_125 := 81920
const MUL_130 := 85197
const MUL_135 := 88474


static func _grant(trait_key: String, display_name: String) -> Dictionary:
	return {
		"kind": NarrativeEffectSpecScript.Kind.GRANT_FAMILY_TRAIT,
		"target_key": trait_key,
		"magnitude_q16": 65536,
		"duration_days": 1,
		"custom_label": "本地最大族「{family_name}」获特质「%s」，永久" % display_name,
	}


static func meta() -> Dictionary:
	return {
		"id": PACK_ID,
		"title": "战争",
		"theme": "战事落到城里",
		"era_band": "2-10",
		"prefix": PREFIX,
		"scale": "6 条事实驱动 + 6 条中观/微观脉冲 + 3 节家族从军链",
		"cast": CAST,
		"node_ids": [
			String(Ids.EVT_WAR_DECLARATION),
			String(Ids.EVT_WAR_VICTORY),
			String(Ids.EVT_WAR_BATTLE),
			String(Ids.EVT_WAR_CITY_TAKEN),
			String(Ids.EVT_WAR_ARMY_LOST),
			String(Ids.EVT_WAR_ANNEXED),
			String(Ids.EVT_WAR_CONSCRIPTION),
			String(Ids.EVT_WAR_ARREARS),
			String(Ids.EVT_WAR_WOUNDED),
			String(Ids.EVT_WAR_REFUGEES),
			String(Ids.EVT_WAR_ARMY_MARKET),
			String(Ids.EVT_WAR_AFTERMATH),
			String(Ids.EVT_WAR_KINDRED_LEVY),
			String(Ids.EVT_WAR_KINDRED_WAIT),
			String(Ids.EVT_WAR_KINDRED_SHRINE),
		],
	}


static func append(catalog) -> void:
	if catalog == null:
		return
	var Op = NarrativeConditionScript.Op
	var Ch = NarrativeEventDefinitionScript.TriggerChannel

	# ═══ 事实 · 宣战（40）═════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_WAR_DECLARATION),
		"title": "{settlement_name}·宣战",
		"body_text": "告示贴在城门上，红纸黑字，写到“敢有异议者”就没有了。韦顺在门洞里数人头，数到一半，队伍里有人问打多久。他说不知道。粮车从街上过，车辙压过新贴的告示，字被碾掉一半。城外的官道上，已经有人在往回走。韦顺把告示的四角重新按了一遍，按到最后一角，手停住了。",
		"image_key": "country.military",
		"ai_visual_prompt": "A war proclamation pasted on a city gate, a grain cart rolling over it, people leaving on the road beyond",
		"tags": ["war", "unrest"],
		"trigger_channel": Ch.FACT_DRIVEN,
		"fact_event_type": 40,
		"base_weight": 120,
		"cooldown_days": 30,
		"min_era_index": 2,
		"max_era_index": 10,
		"conditions": [
			{"op": Op.AT_WAR, "bool_value": true},
			{"op": Op.POPULATION_GTE, "int_value": 8},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 15},
				"add_weight": 20,
				"reason": "城越大，动静越大",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
				"add_weight": 10,
				"reason": "有仓有场，才征得动",
			},
		],
		"options": [
			Shared.option(
				"levy_grain", "加征粮秣",
				"粮车连夜出城",
				"粮车连夜出城，车辙压过告示，字被碾掉一半。第二天的队伍短了些，骂声多了些。韦顺把收上来的数目记在册子上，写完把笔搁下。",
				[
					Shared.cash_in(1.5, 360),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
			Shared.option(
				"open_the_granary", "开官仓先垫",
				"官仓的门开了",
				"官仓的门开了，米按户发下去。队伍里有人问这是不是白给，管仓的韩仓没答。仓里的粮少了一截，账上记的是“军需”。",
				[
					Shared.cash_out(2.0, 360),
					Shared.staple(-3, 360),
				]),
			Shared.option(
				"wait_and_see", "缓办，看看再说",
				"告示被雨泡烂了",
				"告示被雨泡烂了，没人重贴。征粮的事拖了半个月，前线的催单来了三回。韦顺把催单压在砚台下，压得整整齐齐。",
				[
					Shared.manufacturing(-2, 360),
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
				]),
		],
	}))

	# ═══ 事实 · 战事结束（41）═════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_WAR_VICTORY),
		"title": "{settlement_name}·捷报",
		"body_text": "捷报是夜里到的，驿站的人敲了三下门。韦顺披着衣服出来，接过一卷纸，纸上写着斩获的数目。城里有人放起了爆竹，也有人在巷子口烧纸。第二天，衙门门口贴出抚恤的名单，名字写得很密，一张纸不够，又续了一张。韦顺把两张名单对齐，用浆糊粘在一起，粘完退后一步看了看。",
		"image_key": "country.military",
		"ai_visual_prompt": "A victory dispatch arriving at night, firecrackers and paper offerings in the same lane, a casualty list pasted at the yamen",
		"tags": ["war", "unrest"],
		"trigger_channel": Ch.FACT_DRIVEN,
		"fact_event_type": 41,
		"base_weight": 120,
		"cooldown_days": 30,
		"min_era_index": 2,
		"max_era_index": 10,
		"conditions": [
			{"op": Op.AT_WAR, "bool_value": false},
			{"op": Op.POPULATION_GTE, "int_value": 8},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 15},
				"add_weight": 20,
				"reason": "城越大，名单越长",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
				"add_weight": 10,
				"reason": "有衙门才办得成抚恤",
			},
		],
		"options": [
			Shared.option(
				"parade_the_victory", "大办凯旋",
				"队伍从城门走到衙门口",
				"队伍从城门走到衙门口，鼓乐吹了一路。韦顺站在台阶上，看见队伍末尾有几个空着的位子。爆竹放完，街上落了一层红纸。",
				[
					Shared.cash_out(2.0, 360),
					Shared.birth(3, 540),
					Shared.bias(Ids.TAG_COURT, 1.15, 540),
				]),
			Shared.option(
				"pay_the_families", "先发抚恤",
				"名单上的名字一个个划掉",
				"名单上的名字一个个划掉，领钱的人在衙门口排了两行。韦顺把最后一笔发完，天色已经暗了。街上没有放爆竹。",
				[
					Shared.cash_out(2.5, 360),
					Shared.staple(-3, 360),
				]),
			Shared.option(
				"reward_the_officers", "封赏报功，其余不问",
				"军功簿添了几页",
				"军功簿添了几页，赏银从库里抬出来。抚恤的名单还贴在墙上，风吹得卷了边。有人站在名单前看了很久，没找到自己的名字。",
				[
					Shared.cash_in(1.0, 360),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
		],
	}))

	# ═══ 事实 · 会战（42）═════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_WAR_BATTLE),
		"title": "{settlement_name}·战报",
		"body_text": "战报只有一行字：某日，某地，胜负未分。随报来的还有一车伤兵，卸在城隍庙门口。医官数了数，说能救的不到一半。韦顺站在车边，看见一个兵的手还攥着半块饼，饼已经硬了。医官把盐水桶拎到门口，桶沿上结了一圈白霜，也没人顾得上擦。韦顺把饼从他手里取下来，放在车辕上。",
		"image_key": "country.military",
		"ai_visual_prompt": "A cart of wounded soldiers unloaded at a city god temple, a clerk counting them, a soldier's hand clutching a stale pancake",
		"tags": ["war", "unrest"],
		"trigger_channel": Ch.FACT_DRIVEN,
		"fact_event_type": 42,
		"base_weight": 120,
		"cooldown_days": 20,
		"min_era_index": 2,
		"max_era_index": 10,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 8},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.SOLDIERS_TOTAL_GTE, "int_value": 100},
				"add_weight": 25,
				"reason": "兵多，伤亡也多",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
				"add_weight": 10,
				"reason": "有庙有仓，才安置得下",
			},
		],
		"options": [
			Shared.option(
				"send_to_the_physician", "送医官那里",
				"庙里摆满了门板",
				"庙里摆满了门板，伤兵一个挨一个。医官用盐水洗伤口，洗到第三桶，水就红了。韦顺在门口站了一会儿，没进去。",
				[
					Shared.cash_out(1.5, 360),
					Shared.birth(2, 540),
				]),
			Shared.option(
				"send_them_home", "送回原籍",
				"牛车一辆辆出城",
				"牛车一辆辆出城，车上铺着干草。能坐起来的靠在车栏上，坐不起来的躺着。城门更夫数了数车，没数人。",
				[
					Shared.cash_out(1.0, 360),
					Shared.bias(Ids.TAG_UNREST, 1.10, 540),
				]),
			Shared.option(
				"leave_them_there", "就地安置，不问了",
				"庙门从里面关上了",
				"庙门从里面关上了，门口留了一只水缸。第三天，缸空了。韦顺让人又送了一缸，没问里面还有几个人。",
				[
					# 留在庙里的活人从此算本地人口；「不问了」是不管，不是不存在。
					Shared.population_rate(3, "本地人口 +3%（伤兵留居本地）"),
					Shared.manufacturing(-2, 360),
					Shared.bias(Ids.TAG_UNREST, 1.25, 540),
				]),
		],
	}))

	# ═══ 事实 · 城池易手（43）═════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_WAR_CITY_TAKEN),
		"title": "{settlement_name}·易手",
		"body_text": "城破的那天，官仓的门是开的。韦顺带人进去清点，粮还在，账没了。街上有人摆摊卖旧衣裳，说是从北边来的。新派的县吏在衙门口贴告示，字是新的，纸是旧的，边上还留着上一张的半行字。韦顺把旧告示撕下来，撕到一半，纸背面的字露出来，是上一任县吏的名字。",
		"image_key": "country.military",
		"ai_visual_prompt": "A captured city with an open granary, second-hand clothes sold in the street, a new notice pasted over an old one",
		"tags": ["war", "market", "unrest"],
		"trigger_channel": Ch.FACT_DRIVEN,
		"fact_event_type": 43,
		"base_weight": 120,
		"cooldown_days": 30,
		"min_era_index": 2,
		"max_era_index": 10,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 8},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 15},
				"add_weight": 20,
				"reason": "城大，接手的人多",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
				"add_weight": 10,
				"reason": "有仓有街，才接手得下来",
			},
		],
		"options": [
			Shared.option(
				"pacify_and_open", "安民，开仓",
				"官仓的粮按户发",
				"官仓的粮按户发下去，领粮的人排到街尾。新县吏站在仓门口，把告示念了一遍。念完，队伍里有人问，旧钱还能不能使。",
				[
					Shared.staple(-3, 360),
					Shared.cash_out(1.5, 360),
				]),
			Shared.option(
				"let_the_troops_loot", "纵兵三日",
				"街上关了三天的门",
				"街上关了三天的门，第四天门开了，铺子少了几家。韦顺在官仓门口捡到一本账，账上最后一行写着“借”。",
				[
					Shared.cash_in(2.0, 360),
					Shared.bias(Ids.TAG_UNREST, 1.40, 720),
				]),
			Shared.option(
				"seal_everything", "封仓待命",
				"封条贴了两道",
				"封条贴了两道，门口站着兵。领粮的人来了两回，第三回不来了。仓里的粮放着，账上的数目一天比一天对不上。",
				[
					Shared.manufacturing(-2, 360),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
		],
	}))

	# ═══ 事实 · 部队被歼（44）═════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_WAR_ARMY_LOST),
		"title": "{settlement_name}·败信",
		"body_text": "败报是一封没有落款的信。信上说，那支兵在河谷里没了，旗子没找回来。韦顺把信读了三遍，读到第三遍，才看见末尾有一行小字：活着回来的，都在城外。他放下信，先去开了城门。名册是旧的，纸边卷着，他一页一页翻，翻到最后一页，停住了。他把名册合上，塞进袖子，出门时被门槛绊了一下。",
		"image_key": "country.military",
		"ai_visual_prompt": "An unsigned defeat letter on a desk, the city gate opened for a few survivors waiting outside",
		"tags": ["war", "unrest"],
		"trigger_channel": Ch.FACT_DRIVEN,
		"fact_event_type": 44,
		"base_weight": 120,
		"cooldown_days": 30,
		"min_era_index": 2,
		"max_era_index": 10,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 8},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.SOLDIERS_TOTAL_GTE, "int_value": 100},
				"add_weight": 20,
				"reason": "兵多，败起来也大",
			},
			{
				"condition": {"op": Op.COHORT_SATISFACTION_LTE, "float_value": 0.50},
				"add_weight": 15,
				"reason": "人心本来就不稳",
			},
		],
		"options": [
			Shared.option(
				"take_the_survivors_in", "开门收容",
				"城门外站着一群人",
				"城门外站着一群人，甲都卸了，有人光着脚。韦顺让人支起锅，先给口热的。点名的时候，点到一半，名册上的人应不出来。",
				[
					# 「先给口热的」之后活下来的人留在城里；birth(2) 说的是往后十年多生，
					# 跟这些当下就要吃饭的人不是一件事。
					Shared.population_rate(25, "本地人口 +25%（溃兵收容）"),
					Shared.cash_out(1.5, 360),
				]),
			Shared.option(
				"blame_the_general", "追责主将",
				"主将的印被收了",
				"主将的印被收了，人押在衙门的偏房里。审了三天，供词写了七页。第四天，偏房的门开着，人不见了。",
				[
					Shared.knowledge(-2, 360),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
			Shared.option(
				"call_them_deserters", "不认，按逃兵办",
				"城门没开",
				"城门没开，城下的人等到天黑，散了。第二天，官道上多了几具尸首，没人认领。韦顺把名册合上，合得很轻。",
				[
					Shared.manufacturing(-2, 360),
					Shared.bias(Ids.TAG_UNREST, 1.35, 720),
				]),
		],
	}))

	# ═══ 事实 · 国家被吞并（45）═══════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_WAR_ANNEXED),
		"title": "{settlement_name}·旧印",
		"body_text": "邻国的印被送来了，装在一只木匣里，匣盖上的漆还没干。韦顺把印翻过来看，底下的字磨平了。来的人说，从今往后，那边的路引要换。李七在巷口问旧钱还能不能使，钱摊把牌子翻了个面。匣子放在案上，谁也没去盖，漆味在屋里散了两天。韦顺让书办把旧路引的式样抄了一份。",
		"image_key": "country.military",
		"ai_visual_prompt": "A conquered country's seal in a wooden box with wet lacquer, merchants asking about old coins at a street exchange",
		"tags": ["war", "market", "unrest"],
		"trigger_channel": Ch.FACT_DRIVEN,
		"fact_event_type": 45,
		"base_weight": 120,
		"cooldown_days": 60,
		"min_era_index": 3,
		"max_era_index": 10,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 8},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.03},
				"add_weight": 20,
				"reason": "商人最关心旧钱",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
				"add_weight": 10,
				"reason": "城大，换牌子的人多",
			},
		],
		"options": [
			Shared.gamble(
				"keep_the_old_coin", "旧钱照收",
				Shared.branch(39322, "钱摊的牌子又翻回来", # 60%
					"钱摊的牌子又翻回来，旧钱照收，折价一成。商人排着队来换，队伍从巷口排到河边。韦顺在册子上记了个数，写完看了看那只木匣。",
					[
						Shared.trade_capacity(5, 540),
						Shared.bias(Ids.TAG_UNREST, 1.20, 540),
					]),
				Shared.branch(26214, "旧钱没人敢收", # 40%
					"旧钱没人敢收，钱摊当天就关了门。商人把成串的旧钱堆在衙门口，堆了半人高。韦顺让人搬进库房，库房的门关不上。",
					[
						Shared.manufacturing(-3, 540),
						Shared.cash_out(1.5, 360),
						Shared.bias(Ids.TAG_UNREST, 1.30, 540),
					])),
			Shared.option(
				"devalue_the_old_coin", "旧钱折价",
				"折价三成",
				"折价三成，告示贴在钱摊边上。有人当场把一串钱拆开，一枚一枚数。数完，他把钱揣回怀里，走了。",
				[
					Shared.cash_in(1.5, 360),
					Shared.bias(Ids.TAG_UNREST, 1.25, 540),
				]),
			Shared.option(
				"void_the_old_coin", "一律作废",
				"旧钱堆在衙门口",
				"旧钱堆在衙门口，像一堆废铜。来换新钱的人排了两天，第三天不来了。城里的铺子开始以物易物。",
				[
					Shared.manufacturing(-3, 540),
					Shared.bias(Ids.TAG_UNREST, 1.30, 720),
				]),
		],
	}))

	preload("res://scripts/narrative/narrative_event_catalog_war_pulse.gd").append(catalog)
