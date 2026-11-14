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
				"城门外站着几十个人",
				"城门外站着几十个人，甲都卸了，有人光着脚。韦顺让人支起锅，先给口热的。点名的时候，点到一半，名册上的人应不出来。",
				[
					Shared.cash_out(1.5, 360),
					Shared.birth(2, 540),
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

	# ═══ 脉冲 · 征兵 ══════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_WAR_CONSCRIPTION),
		"title": "{settlement_name}·征丁",
		"body_text": "征丁的告示贴到里巷，一户出一个。韦顺拿着册子挨门点，点到第三家，门里说人不在。他往里看了一眼，灶是热的。巷子尽头，有人翻墙走了，墙头踩塌了一块土。邬三在册子上按了手印，按完把手在裤子上擦了擦。册子合上，纸被汗浸软了，他换了一本新的。巷口的狗叫了两声，没人出来看。",
		"image_key": "country.military",
		"ai_visual_prompt": "A conscription notice in a narrow lane, a clerk at a door, a man climbing over a wall at the end",
		"tags": ["war", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 110,
		"cooldown_days": 360,
		"min_era_index": 2,
		"max_era_index": 9,
		"conditions": [
			{"op": Op.AT_WAR, "bool_value": true},
			{"op": Op.POPULATION_GTE, "int_value": 10},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.SOLDIERS_TOTAL_GTE, "int_value": 200},
				"add_weight": 25,
				"multiplier_q16": MUL_120,
				"reason": "兵不够，征得就急",
			},
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 20},
				"add_weight": 15,
				"reason": "人多，抽得出来",
			},
		],
		"options": [
			Shared.option(
				"take_them_by_the_roll", "按册强征",
				"册子上的名字一个个划",
				"册子上的名字一个个划，划到第三页，差役押着人往外走。灶上的锅还热着，没人管。那年秋收，田里少了一半人。",
				[
					Shared.birth(-3, 540),
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
				]),
			Shared.option(
				"let_them_buy_out", "出钱免役",
				"免役的钱进了库",
				"免役的钱进了库，交得起的人留了下来。交不起的，还是被带走了。名单上的空行，韦顺用墨涂掉。",
				[
					Shared.cash_in(1.5, 360),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
			Shared.option(
				"halve_the_levy", "缓征一半",
				"册子只用了半本",
				"册子只用了半本，剩下的折角压着。前线的催单又来了，韦顺把催单和册子放在一起，没回。",
				[
					Shared.manufacturing(-2, 360),
					Shared.bias(Ids.TAG_UNREST, 1.10, 540),
				]),
		],
	}))

	# ═══ 脉冲 · 欠饷 ══════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_WAR_ARREARS),
		"title": "{settlement_name}·欠饷",
		"body_text": "营里的饷拖了两个月。兵在衙门口站成一排，不喊，也不走。韦顺出来说话，说库里的银子在路上。队伍里有人笑了一声。笑完，队伍往前挪了半步。韩仓把库房的账本抱出来，翻给韦顺看，最后一页是空的。韦顺把封条按了按，封条还是去年那张。队伍里有人开始数台阶。",
		"image_key": "country.military",
		"ai_visual_prompt": "Soldiers standing silently outside a yamen over unpaid wages, an official speaking from the steps",
		"tags": ["war", "unrest", "fiscal"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 110,
		"cooldown_days": 300,
		"min_era_index": 3,
		"max_era_index": 10,
		"conditions": [
			{"op": Op.AT_WAR, "bool_value": true},
			{"op": Op.SOLDIERS_TOTAL_GTE, "int_value": 100},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.SOLDIERS_TOTAL_GTE, "int_value": 300},
				"add_weight": 25,
				"reason": "兵越多，欠得越多",
			},
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "wheat_grain", "float_value": 1.10},
				"add_weight": 15,
				"reason": "粮价一高，饷更不够吃",
			},
		],
		"options": [
			Shared.option(
				"pay_in_full", "把钱补上",
				"银子抬进营里",
				"银子抬进营里，一箱一箱摆在台子上。兵排队领，领完回营。韦顺看着最后一箱抬走，库房的门没关，里面空了一半。",
				[
					Shared.cash_out(2.5, 360),
					Shared.bias(Ids.TAG_UNREST, 0.90, 360),
				]),
			Shared.option(
				"issue_promises", "先打白条",
				"白条按了印",
				"白条按了印，一张一张发下去。有兵把白条折好，塞进绑腿里；也有兵当场撕了，纸屑落在台阶上。",
				[
					Shared.manufacturing(-2, 360),
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
				]),
			Shared.option(
				"discharge_half", "裁掉一半",
				"营里空了一半",
				"营里空了一半，被裁的人领了半个月的饷。他们出营的时候，把兵器交在门口，堆成一小垛。韦顺站在垛边，没说话。",
				[
					Shared.cash_in(1.0, 360),
					Shared.bias(Ids.TAG_UNREST, 1.40, 720),
				]),
		],
	}))

	# ═══ 脉冲 · 伤兵 ══════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_WAR_WOUNDED),
		"title": "{settlement_name}·伤兵",
		"body_text": "城隍庙里躺满了伤兵，医官只有两个。药不够，用盐水洗。一个兵问，断了腿还能不能回家种地。医官没答，把布条缠紧了些。柳嫂在庙门口支了一口锅，烧水给伤兵喝，水是井里现打的。韦顺让人去药铺赊几斤草药，药铺的掌柜没要押。庙外的柳树上，拴着几匹没人来牵的马。",
		"image_key": "country.military",
		"ai_visual_prompt": "Wounded soldiers in a temple, a physician washing wounds with salt water, riderless horses tied outside",
		"tags": ["war", "people"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 300,
		"min_era_index": 2,
		"max_era_index": 10,
		"conditions": [
			{"op": Op.AT_WAR, "bool_value": true},
			{"op": Op.SOLDIERS_TOTAL_GTE, "int_value": 150},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.SOLDIERS_TOTAL_GTE, "int_value": 400},
				"add_weight": 25,
				"reason": "仗打得大，伤兵就多",
			},
			{
				"condition": {"op": Op.COHORT_SATISFACTION_LTE, "float_value": 0.50},
				"add_weight": 15,
				"reason": "家里也等着人",
			},
		],
		"options": [
			Shared.option(
				"more_physicians", "加派医官",
				"庙里多了三张门板",
				"庙里多了三张门板，医官从一个变成三个。药还是不够，盐水换成了草药水。那个断了腿的兵，最后能拄着棍站起来了。",
				[
					Shared.cash_out(2.0, 360),
					Shared.birth(3, 540),
				]),
			Shared.option(
				"send_them_home", "送回乡里",
				"牛车一辆辆出城",
				"牛车一辆辆出城，车上铺着干草。能坐起来的靠在车栏上，坐不起来的躺着。城门口的名册上，一天划掉十几个名字。",
				[
					Shared.cash_out(1.0, 360),
					Shared.staple(3, 540),
				]),
			Shared.option(
				"only_the_savable", "只留能治的",
				"庙门从里面关上了",
				"庙门从里面关上了，能治的留下，治不了的抬到后院。后院的草席不够，有人躺在石板上。第三天，后院空了。",
				[
					Shared.knowledge(-2, 360),
					Shared.bias(Ids.TAG_UNREST, 1.25, 540),
				]),
		],
	}))

	# ═══ 脉冲 · 难民 ══════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_WAR_REFUGEES),
		"title": "{settlement_name}·城下的人",
		"body_text": "北边来的人堵在城门口，说要进去。守门的问有没有路引，头一个人从怀里掏出一张湿纸。韦顺站在门楼上往下看，看见人群里有孩子骑在大人肩上。城里的米价，昨天又涨了一回。守门的把门闩抬起来，又放下，抬了三次。韦顺让人去问，回来的人说，是北边三个县的。他把手按在城垛上，砖是凉的。",
		"image_key": "country.military",
		"ai_visual_prompt": "Refugees crowding a city gate, one holding a soaked travel permit, a child on an adult's shoulders seen from the wall",
		"tags": ["war", "unrest", "people"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 110,
		"cooldown_days": 300,
		"min_era_index": 2,
		"max_era_index": 10,
		"conditions": [
			{"op": Op.AT_WAR, "bool_value": true},
			{"op": Op.POPULATION_GTE, "int_value": 12},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.WAR_GOING_BADLY, "bool_value": true},
				"add_weight": 30,
				"multiplier_q16": MUL_125,
				"reason": "仗打得不好，跑的人就多",
			},
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 20},
				"add_weight": 15,
				"reason": "大城才有门楼可站",
			},
		],
		"options": [
			Shared.option(
				"open_the_gate", "开门收容",
				"城门开了一条缝",
				"城门开了一条缝，人挤着进来。当天夜里，城里的米价又涨了一回。韦顺让人在庙里铺草，草不够，有人睡在街上。",
				[
					Shared.staple(4, 540),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
			Shared.option(
				"camp_outside", "城外设棚",
				"城外的空地上支起了席棚",
				"城外的空地上支起了席棚，粥棚摆在棚口。城里的人不许出去，城外的人不许进来。第三天，席棚边上多了几个坟头。",
				[
					Shared.cash_out(1.5, 360),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
			Shared.option(
				"keep_the_gate_shut", "不放进来",
				"城门没开",
				"城门没开，人群在城下站了两天。第三天早上，城下空了，雪地上留着几行脚印。守门的把门闩抬起来，又放下。",
				[
					Shared.staple(-2, 360),
					Shared.bias(Ids.TAG_UNREST, 1.35, 720),
				]),
		],
	}))

	# ═══ 脉冲 · 军市 ══════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_WAR_ARMY_MARKET),
		"title": "{settlement_name}·军市",
		"body_text": "军营外头自发成了一个市，卖酒的、补鞋的、卖药的都有。税吏去收摊钱，被几个兵围住。韦顺赶到时，税吏的帽子在泥里，摊子上的酒坛碎了一个，酒味压过了马粪味。李七来看了两回，第二回带了两个伙计。韦顺把帽子从泥里捡起来，拍了拍，扣回税吏头上。酒味到第二天还没散。",
		"image_key": "country.economy",
		"ai_visual_prompt": "An improvised market outside an army camp, a tax clerk surrounded by soldiers, a broken wine jar in the mud",
		"tags": ["war", "market"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 300,
		"min_era_index": 3,
		"max_era_index": 10,
		"conditions": [
			{"op": Op.AT_WAR, "bool_value": true},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.02},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.SOLDIERS_TOTAL_GTE, "int_value": 200},
				"add_weight": 20,
				"reason": "兵多，市就大",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.05},
				"add_weight": 15,
				"reason": "商人闻着味就来了",
			},
		],
		"options": [
			Shared.option(
				"run_it_officially", "官营军市",
				"市口立了一块木牌",
				"市口立了一块木牌，写着官营。摊子照摆，钱交给官设的柜上。酒坛又添了几个，一碗酒比外面少半碗。",
				[
					Shared.cash_in(1.5, 360),
					Shared.bias(Ids.TAG_UNREST, 1.10, 540),
				]),
			Shared.option(
				"farm_it_out", "包给商人",
				"市口换了招牌",
				"市口换了招牌，李家出了保证金，摊钱归他收。兵的酒钱涨了，补鞋的也涨了。韦顺从市口过，没停。",
				[
					Shared.cash_in(2.0, 360),
					Shared.bias(Ids.TAG_LABOR, 1.15, 540),
				]),
			Shared.option(
				"shut_it_down", "把摊子收了",
				"摊子收了",
				"摊子收了，市口空出来。兵的酒没处买，夜里翻墙出去。韦顺让人把墙加高了两尺，墙根下多了几架梯子。",
				[
					Shared.manufacturing(-2, 360),
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
				]),
		],
	}))

	# ═══ 脉冲 · 战后 ══════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_WAR_AFTERMATH),
		"title": "{settlement_name}·战后",
		"body_text": "仗打完了，城里的男人少了一批。田里荒着，官仓里也空。韦顺把两本册子并排放着，一本记阵亡，一本记欠税。他先翻开了记阵亡的那本，翻到一半，又合上了。窗外的田里，草已经长到人腰高。他起身去开窗，窗纸破了一个洞。他把两本册子叠在一起，抱着去了库房，库房的锁锈了，他拧了两下才开。",
		"image_key": "country.military",
		"ai_visual_prompt": "Two ledgers side by side after a war, one for the dead and one for unpaid taxes, empty fields beyond the window",
		"tags": ["war", "unrest", "fiscal"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 600,
		"min_era_index": 2,
		"max_era_index": 10,
		"conditions": [
			{"op": Op.AT_WAR, "bool_value": false},
			{"op": Op.POPULATION_GTE, "int_value": 12},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.SOLDIERS_TOTAL_GTE, "int_value": 100},
				"add_weight": 20,
				"reason": "兵多，阵亡册就厚",
			},
			{
				"condition": {"op": Op.COHORT_SATISFACTION_LTE, "float_value": 0.50},
				"add_weight": 15,
				"reason": "日子紧，欠税也追不动",
			},
		],
		"options": [
			Shared.option(
				"pay_the_dead", "抚恤阵亡",
				"阵亡册上的名字一个个对",
				"阵亡册上的名字一个个对，对到天黑，还有两页。领钱的人在衙门口等着，没人催。韦顺把最后一笔发完，把册子锁进柜子。",
				[
					Shared.cash_out(2.5, 360),
					Shared.birth(2, 540),
				]),
			Shared.option(
				"settle_the_fields", "招人垦荒",
				"荒田插了木牌",
				"荒田插了木牌，写着谁开归谁。第一批去的是没分到地的人，第二批是从北边回来的。犁不够，有人用锄头翻。",
				[
					Shared.cash_out(1.5, 360),
					Shared.agriculture(4, 540),
					Shared.manufacturing(-2, 360),
				]),
			Shared.option(
				"collect_the_taxes", "先追欠税",
				"欠税册翻开了",
				"欠税册翻开了，一家一家追。追到第三家，那家的男人跪在门口，说他儿子没回来。韦顺把册子合上，站了一会儿，又翻开。",
				[
					Shared.cash_in(2.0, 360),
					Shared.bias(Ids.TAG_UNREST, 1.25, 540),
				]),
		],
	}))

	# ═══ 链 · 族中子弟从军（1/3）════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_WAR_KINDRED_LEVY),
		"title": "{settlement_name}·族里出人",
		"body_text": "征丁的册子送到族里，指名要一个男丁。周朴说族里出人，不能让人说周家躲在后面。李七说族里出人容易，回来难。韦顺把册子摊在桌上，笔尖在名字那一格停了很久。院里站着一个后生，手里拎着一双新鞋，鞋底还是白的。周朴看了他一眼，把茶碗里的水泼在台阶上。后生把鞋换了，旧鞋留在门槛上。",
		"image_key": "family.house",
		"ai_visual_prompt": "A conscription roster in a clan courtyard, a young man changing into new shoes, old shoes left on the threshold",
		"tags": ["war", "family"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 900,
		"min_era_index": 2,
		"max_era_index": 9,
		"conditions": [
			{"op": Op.AT_WAR, "bool_value": true},
			{"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 2},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 3},
				"add_weight": 20,
				"multiplier_q16": MUL_115,
				"reason": "族里有头脸，推不掉",
			},
			{
				"condition": {"op": Op.SOLDIERS_TOTAL_GTE, "int_value": 100},
				"add_weight": 15,
				"reason": "兵不够，才点到族里",
			},
		],
		"options": [
			Shared.option(
				"send_a_son", "让族里出人",
				"名字写上了册子",
				"名字写上了册子，周朴把新鞋塞给后生，鞋是新的，人还不会穿。后生跟着差役出巷口，回头看了一眼。",
				[
					Shared.flag(Ids.FLAG_WAR_KINDRED_SENT, 1825, "族中子弟从军"),
					Shared.schedule(Ids.EVT_WAR_KINDRED_WAIT, 150, "家书", &"war_kindred"),
					Shared.cash_out(1.0, 360),
				]),
			Shared.option(
				"buy_him_out", "出钱买免",
				"册子上的名字划掉了",
				"册子上的名字划掉了，钱装进一只布袋。差役掂了掂，没说话。后生留在族里，那双新鞋收进了柜子。",
				[
					Shared.cash_out(1.5, 360),
					Shared.bias(Ids.TAG_COURT, 1.15, 540),
				]),
			Shared.option(
				"take_another", "抽别家的人",
				"别家的门被敲响了",
				"别家的门被敲响了，巷子里传出哭声。周朴站在自家门口，没出去。第二天，族里的孩子被人扔了石头。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.35, 720),
				]),
		],
	}))

	# ═══ 链 · 家书（2/3）══════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_WAR_KINDRED_WAIT),
		"title": "{settlement_name}·家书",
		"body_text": "信是秋天到的，封口的火漆裂了。韦顺拆开，里面只有半张纸，写着“人没找到”。他把纸翻过来，背面是空的。周朴在祠堂里坐了一夜，第二天让人去问，问了三回，回话都一样。李七说，没消息也算消息。韦顺把半张纸夹进册子里，册子合上时，纸角露在外头。他把册子翻到那页，名字旁边空着一格，他没填。",
		"image_key": "country.military",
		"ai_visual_prompt": "A letter with a cracked wax seal and only half a page, a clan elder sitting alone in an ancestral hall at night",
		"tags": ["war", "family"],
		"trigger_channel": Ch.SCHEDULED_ONLY,
		"required_story_flags": [String(Ids.FLAG_WAR_KINDRED_SENT)],
		"one_shot": true,
		"base_weight": 100,
		"cooldown_days": 0,
		"min_era_index": 2,
		"max_era_index": 9,
		"conditions": [],
		"weight_rules": [],
		"options": [
			Shared.option(
				"no_one_found", "没有找到人",
				"族里立了衣冠冢",
				"族里立了衣冠冢，埋的是那双旧鞋。周朴让人在冢前种了一棵树，树苗是从城外挖的。没有人哭。",
				[
					Shared.clear_flag(Ids.FLAG_WAR_KINDRED_SENT, "家书已读"),
					Shared.flag(Ids.FLAG_WAR_KINDRED_DEAD, 1825, "族中子弟阵亡"),
					Shared.schedule(Ids.EVT_WAR_KINDRED_SHRINE, 240, "立祠", &"war_kindred"),
					Shared.bias(Ids.TAG_UNREST, 1.25, 540),
				]),
			Shared.option(
				"he_came_back", "人回来了",
				"门槛上的旧鞋不见了",
				"人回来了，少了一条腿，拄着棍。周朴让人把门槛锯低了一寸。那双旧鞋不知被谁收走，门口空了。",
				[
					Shared.clear_flag(Ids.FLAG_WAR_KINDRED_SENT, "家书已读"),
					Shared.birth(2, 540),
					Shared.cash_out(1.0, 360),
				]),
			Shared.option(
				"no_news", "一直没有消息",
				"册子上的名字空着",
				"一直没有消息，册子上的名字空着。周朴说再等等，李七说等不起了。那年冬天，族里没有再提这个人。",
				[
					Shared.clear_flag(Ids.FLAG_WAR_KINDRED_SENT, "家书已读"),
					Shared.manufacturing(-2, 360),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
		],
	}))

	# ═══ 链 · 立祠（3/3）══════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_WAR_KINDRED_SHRINE),
		"title": "{settlement_name}·立祠",
		"body_text": "族里要立祠。周朴说名字要刻在族谱上，刻深一点。韦顺说刻名字容易，往后每年谁来上香。祠堂的梁上还挂着去年的白布，没摘。石匠在门口等，凿子放在脚边。李七蹲在门槛上，拿手指头在灰里写了一个字，又抹掉。周朴没看那个字，只问石匠，碑要多高。石匠说碑要青石，周朴说青石贵，先用河边的。",
		"image_key": "family.house",
		"ai_visual_prompt": "A clan hall with last year's white mourning cloth still on the beam, a stonemason waiting with a chisel, a name written in dust",
		"tags": ["war", "family", "faith"],
		"trigger_channel": Ch.SCHEDULED_ONLY,
		"required_story_flags": [String(Ids.FLAG_WAR_KINDRED_DEAD)],
		"one_shot": true,
		"base_weight": 100,
		"cooldown_days": 0,
		"min_era_index": 2,
		"max_era_index": 9,
		"conditions": [],
		"weight_rules": [],
		"options": [
			Shared.option(
				"carve_the_name", "把名字刻上",
				"碑立在祠堂西侧",
				"碑立在祠堂西侧，名字刻得很深。周朴每年亲自去描一遍红。族里的孩子经过，会念那个名字。",
				[
					_grant("j020_gentry", "士绅门第"),
					Shared.knowledge(2, 540),
					Shared.cash_out(1.5, 360),
				]),
			Shared.option(
				"no_shrine", "不给他立祠",
				"白布摘了",
				"白布摘了，祠堂的梁上留着一道印。周朴说人死如灯灭，李七没接话。那年祭祖，族里少摆了一副碗筷。",
				[
					Shared.knowledge(-2, 360),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
			Shared.option(
				"only_the_genealogy", "只记在族谱里",
				"族谱添了一行",
				"族谱添了一行，字比别的行小。韦顺说这样也好，省得年年修碑。周朴把族谱合上，放回柜子最高一格。",
				[
					Shared.knowledge(1, 360),
					Shared.bias(Ids.TAG_COURT, 1.15, 540),
				]),
		],
	}))
