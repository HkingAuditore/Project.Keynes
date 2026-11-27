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
	"使团", "外邦", "符节", "国书", "礼单", "印泥", "丝绸", "驿馆", "边市", "盟约",
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
		"body_text": "西方汗国的使团率领三艘巨舰停泊于外港，递交了盖有王印的国书与朱砂礼单。来使宣称此行系平等邦交的互赠而非藩属纳贡，礼单上却逐项列明了索要回礼的品目与定额。港务官员查验后密报，商船底舱满载优质海盐，显然意在借外交礼仪换取免税贸易与丰厚回赐。若在日落前不作答复，船队便将扬帆北去。",
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
				"take_and_return", "全额收礼，照单厚赐",
				"厚往薄来",
				"满载丝绸与漆器的回礼船队随使团离港，换来了稳固的跨海商路与制造订单。然而这笔体面的外交开支最终摊派给了地方民众。",
				[
					Shared.cash_in(4, 540, "向本地人数最多的{primary_profession}征收其现金的 4%（礼单摊派）"),
					Shared.trade_capacity(12, 540),
					Shared.manufacturing(10, 540),
				]),
			Shared.option(
				"take_salt_only", "收下海盐，折半回礼",
				"礼节有亏",
				"海盐悉数入仓以平抑本地食盐与主食开销，但缩水的回礼激怒了外邦使团。船队次日便愤然撤离，本地外贸与手工业随之下滑。",
				[
					Shared.manufacturing(-10, 540),
					Shared.staple(-8, 360),
					Shared.bias(Ids.TAG_MARKET, 0.90, 540),
				]),
			Shared.option(
				"keep_them_out", "拒之港外，不予接纳",
				"闭港拒使",
				"强硬驱离外邦使团捍卫了朝廷威严，也减少了边防摩擦的风险。但失去这批海盐补给后，本地民生开销随之加重。",
				[
					Shared.staple(12, 360),
					Shared.bias(Ids.TAG_FRONTIER, 0.90, 540),
				]),
		],
	}))

	# ═══ 通译 ═════════════════════════════════════════════════════════════
	# 商人够多、人口够多，才有"两边都能说话"的人。
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_ENVOY_INTERPRETER),
		"title": "{settlement_name}·通译",
		"body_text": "西方商队携大批盐铁抵达，要求就关税与交易定额展开谈判，而官署内精通双语的通译仅有一人。此人长年游走于外邦商团与本地官府之间，熟悉双方礼单与公文印泥的规制，却也因两头领薪而屡遭猜忌。本土商帮代表警告，此人往年曾向外邦泄露底价；但若临阵撤换，谈判恐将陷入僵局。",
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
				"give_him_office", "授予官职，正式纳用",
				"通译入仕",
				"通译获授正式官身与俸禄，凭借其人脉迅速敲定了有利的贸易协定。本地商运与作坊皆受其惠，唯独地方需承担其署衙开支。",
				[
					Shared.cash_in(3, 360, "向本地人数最多的{primary_profession}征收其现金的 3%（通译的俸与纸墨）"),
					Shared.trade_capacity(10, 540),
					Shared.manufacturing(8, 540),
				]),
			Shared.option(
				"let_him_run_both", "维持现状，不授名分",
				"双面掮客",
				"未获正式任命的通译继续在两方之间穿梭牟利，虽极大活跃了边境贸易，但政务机密屡屡外泄，引发官民广泛不安。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
					Shared.trade_capacity(15, 540),
				]),
			Shared.option(
				"use_our_own", "撤换通译，起用本国文吏",
				"谈判受挫",
				"新任文吏因语言生疏频频误解条款，谈判拖延数日无果。外邦商队最终转赴下游盟邦交易，本地制造业蒙受了订单损失。",
				[
					Shared.manufacturing(-10, 540),
					Shared.bias(Ids.TAG_UNREST, 0.90, 540),
				]),
		],
	}))

	# ═══ 边市 ═════════════════════════════════════════════════════════════
	# 商人更多。开不开边市，铁器算不算违禁。
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_ENVOY_BORDER),
		"title": "{settlement_name}·边市",
		"body_text": "边境的边市木栅刚刚落成，外邦商队牵来大批良马与食盐，点名换购我方的铁锅、农具与铁钉。依照旧法，铁器属于严禁出境的战略物资，持符节镇守关口的军官坚决反对放行。然而商帮算过细账，外邦愿以三倍溢价收购，若以民用农具名义放行，可换回足以充盈仓廪的紧缺食盐。禁令与厚利摆在案头，亟待裁断。",
		"image_key": "country.economy",
		"ai_visual_prompt": "A border market of fresh wooden fencing, iron pots and ploughs on one side, horses on the other, a gate officer holding a law scroll",
		"tags": ["envoy", "market", "frontier"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 3,
		"max_era_index": 7,
		"required_technologies": ["tech.iron_smelting"],
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
				"open_ban_iron", "开放边市，严禁铁器出关",
				"限贸开市",
				"边市如期开放，但严密的稽查将铁器悉数拦在关内。外邦商队虽颇感失望，仍以陶器与杂货达成了交易，边境秩序得以维持。",
				[
					Shared.cash_in(3, 540, "向本地人数最多的{primary_profession}征收其现金的 3%（设卡与守栅的工食）"),
					Shared.trade_capacity(15, 540),
					Shared.bias(Ids.TAG_UNREST, 0.90, 540),
				]),
			Shared.option(
				"open_sell_anything", "全面放开，允许铁器交易",
				"铁利通边",
				"大量铁制农具与器皿涌向境外，本地贸易与冶铁作坊迎来繁荣。然而不久后哨探回报，外邦骑兵已开始将我方铁料改铸为兵刃。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.25, 540),
					Shared.trade_capacity(16, 540),
					Shared.manufacturing(10, 540),
				]),
			Shared.option(
				"keep_it_shut", "关闭边市，恪守旧禁",
				"封关守禁",
				"边市大门紧闭，战略铁料未曾外流分毫。但断绝边境互市导致紧缺物资无法补充，入冬前本地民生与主食开销明显攀升。",
				[
					Shared.staple(10, 360),
					Shared.bias(Ids.TAG_UNREST, 0.90, 540),
				]),
		],
	}))

	# ═══ 背盟 ═════════════════════════════════════════════════════════════
	# 城里像样、人口够多，才有一份值得背的盟约。这一条走两条分支的博弈。
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_ENVOY_OATH),
		"title": "{settlement_name}·背盟",
		"body_text": "与邻邦签署的盟约墨迹犹在，今春对方骑兵却悍然渡河，以追捕逃奴为名侵占我方数座边境村落。外邦使团随即递交国书，轻描淡写地将其归咎于边将擅自行动，并无归还之意。前线守军回报对岸营火连绵，显然早有预谋。若履约出兵必将耗费巨资，若吞声忍让则国威扫地，今后恐再无邻邦敬畏我朝盟约。",
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
				"honour_the_oath", "依约兴师，强硬反击",
				Shared.branch(42598, "敌军退却",
					"我军大旗刚抵河岸，对岸敌营便连夜后撤。外邦使团仓皇致歉并重申盟约，此番果断出兵不仅提振了军备效率，也稳固了边境商路。",
					[
						Shared.cash_in(5, 540, "向本地人数最多的{primary_profession}征收其现金的 5%（出兵的开拔钱）"),
						Shared.supply(10, 540),
						Shared.trade_capacity(10, 540),
					]),
				Shared.branch(22938, "河滩血战",
					"两军在河滩爆发激烈冲突，双方各有伤亡后各自撤军。战事虽未演变为全面战争，但抚恤与补械的摊派令地方财政备受压力。",
					[
						Shared.cash_in(6, 540, "向本地人数最多的{primary_profession}征收其现金的 6%（抚恤与补械）"),
						Shared.supply(8, 360),
						Shared.bias(Ids.TAG_UNREST, 0.90, 540),
					])),
			Shared.option(
				"tear_it_up", "封存国书，拒绝出兵",
				"吞声避战",
				"盟约被束之高阁，朝廷避免了高昂的战争开支并保住了境内安宁。但外邦商队见我朝软弱随即改道，本地原料供应与制造业受挫。",
				[
					Shared.manufacturing(-12, 540),
					Shared.supply(8, 360),
					Shared.bias(Ids.TAG_UNREST, 0.90, 540),
				]),
			Shared.option(
				"stall_the_army", "陈兵城外，虚张声势",
				"按兵对峙",
				"大军在城外扎营示威却按兵不动，既未渡河收复失地，也未撤回营房。这种首鼠两端的姿态虽保住了农时，却令国内舆情汹涌。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
					Shared.agriculture(8, 540),
					Shared.supply(8, 360),
				]),
		],
	}))

	# ═══ 婚约 ═════════════════════════════════════════════════════════════
	# 人口够多、城里有两处像样的屋子，才谈得上"嫁过去的是人，押过去的是信"。
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_ENVOY_MARRIAGE),
		"title": "{settlement_name}·婚约",
		"body_text": "西方汗国遣使团前来求亲，指名迎娶我朝宗室一位通晓文墨的贵女，并备下六车丝绸作为聘礼。礼单之上附带苛刻条件，要求随嫁大批工匠与良种，以借联姻之名汲取我方工艺。财政官员核算后指出，筹办此番厚嫁的开销远超数年商税；然而断然拒绝又恐触怒强邻，令边疆再起衅端。回话的期限就在入秋之前。",
		"image_key": "family.house",
		"ai_visual_prompt": "Six gift carts of silk before a hall, a gift list with one name at its head, a young woman returning a tally token in a corridor",
		"tags": ["envoy", "court", "people"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 900,
		"min_era_index": 3,
		"max_era_index": 7,
		"required_technologies": ["tech.weaving"],
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
				"send_her_with_gifts", "应允联姻，厚礼陪嫁",
				"和亲通好",
				"绵延数里的送亲车队渡河西去，两邦借由姻亲关系确立了长期通商协定。虽然陪嫁摊派加重了地方负担，但宫廷与边疆局势皆趋缓和。",
				[
					Shared.cash_in(5, 540, "向本地人数最多的{primary_profession}征收其现金的 5%（陪嫁摊派）"),
					Shared.trade_capacity(15, 540),
					Shared.bias(Ids.TAG_COURT, 0.90, 540),
				]),
			Shared.option(
				"send_the_list_only", "婉拒婚事，仅遣使回礼",
				"留人还礼",
				"外邦使团将未署名的礼单原样退回，并盖上了措辞严厉的火漆印。工匠与人才得以留在国内充实文教与制造，但边境紧张气氛陡增。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
					Shared.manufacturing(10, 540),
					Shared.knowledge(8, 540),
				]),
			Shared.option(
				"wait_for_autumn", "拖延答复，以待时变",
				"使团拂袖",
				"朝廷迟迟未予明确答复，外邦使团在驿馆苦候两月后不辞而别。虽避免了直接冲突与赔嫁支出，但双边商贸与本地制造均陷入冷淡。",
				[
					Shared.manufacturing(-10, 540),
					Shared.bias(Ids.TAG_UNREST, 0.90, 540),
				]),
		],
	}))

	# ═══ 马礼 ═════════════════════════════════════════════════════════════
	# 有商人、人口够。二十匹好马进门，回什么礼才不失体面。
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_ENVOY_HORSES),
		"title": "{settlement_name}·马礼",
		"body_text": "外邦使团驱赶二十匹精壮骏马入城，递上礼单声称系汗王睦邻之礼。工坊匠师查验后发现，这批战马不仅骨架上乘，所钉蹄铁的锻造工艺亦颇为精良。按照邦交惯例，受礼一方须回赠价值更高的国礼以示大国气度，但官仓现存丝绸仅足半数。若以铁器充抵恐资敌，若筹款采买则耗费民力，如何回礼关乎国体。",
		"image_key": "economy.resource",
		"ai_visual_prompt": "Twenty well-groomed horses with cloth-wrapped hooves led into a stable, a groom inspecting a hoof, a gift list drying on a desk",
		"tags": ["envoy", "market"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 3,
		"max_era_index": 7,
		"required_technologies": ["tech.iron_smelting"],
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
				"return_silk", "收下骏马，筹购丝绸回赠",
				"丝马互市",
				"骏马悉数编入马政储备，朝廷筹集四车上等丝绸体面回赠。此举既充实了本地马匹存量，也进一步拓宽了双方的贸易渠道。",
				[
					Shared.cash_in(4, 540, "向本地人数最多的{primary_profession}征收其现金的 4%（回礼的丝绸摊派）"),
					Shared.stock("horses", 10),
					Shared.trade_capacity(10, 540),
				]),
			Shared.option(
				"return_iron", "收下骏马，以铁器折抵回礼",
				"铁器出关",
				"大批铁制农具与未开刃铁器被装车送往外邦，本地冶铁作坊与商贸一时兴旺。但外邦使臣意味深长的神情，却让朝中主战派倍感忧虑。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
					Shared.manufacturing(12, 540),
					Shared.trade_capacity(10, 540),
				]),
			Shared.option(
				"send_them_back", "婉言谢绝，原样退还骏马",
				"却礼自守",
				"马队沿着来路原样撤回，朝廷免去了沉重的回礼开销。但此番冷遇令外邦商旅望而却步，本地制造与市场活跃度随之降温。",
				[
					Shared.manufacturing(-10, 540),
					Shared.bias(Ids.TAG_MARKET, 0.90, 540),
				]),
		],
	}))

	# ═══ 密约 ═════════════════════════════════════════════════════════════
	# 城里像样、人口够多，才有资格收到一份不能给人看的条款。era 4–7。
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_ENVOY_SECRET),
		"title": "{settlement_name}·密约",
		"body_text": "外邦使团呈上的正式国书夹层中，暗藏着一份未盖王印的秘密条款，详述了两国在边境河道分兵与过桥的默契安排。密使宣称此约绝不可示于第三人，所用印泥亦为特制，事后无从查证。枢密幕僚验看后坦言，密约真伪难辨，极可能是对方派系私下试探，但其条款却对我方极为有利。签与不签，皆是一场豪赌。",
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
				"sign_and_lock", "密签条款，锁入机要库房",
				"密约归档",
				"密约签署后被严密封存，朝廷筹措了一笔隐秘定金以示诚意。此后边境军需与商路调度果然顺畅许多，只是这笔见不得光的交易随时可能反噬。",
				[
					Shared.cash_in(5, 540, "向本地人数最多的{primary_profession}征收其现金的 5%（密约的定金）"),
					Shared.trade_capacity(15, 540),
					Shared.supply(10, 540),
				]),
			Shared.option(
				"refuse_and_copy", "拒绝签署，留存抄本备查",
				"留档拒签",
				"朝廷退回密约正本的抄件，仅将情报归档交由智囊研判。虽然双边商贸与本地制造因信任受挫而短暂遇冷，但情报体系借此摸清了对手底牌。",
				[
					Shared.manufacturing(-10, 540),
					Shared.knowledge(12, 540),
					Shared.bias(Ids.TAG_COURT, 0.90, 540),
				]),
			Shared.option(
				"sign_half", "部分签署，留白核心条款",
				"留白博弈",
				"朝廷刻意在关键条文处留白，借机换取了眼前的贸易与制造红利。半年后外邦就模糊地带发难，双方陷入了旷日持久的外交扯皮与猜忌。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.25, 540),
					Shared.trade_capacity(8, 540),
					Shared.manufacturing(8, 540),
				]),
		],
	}))
