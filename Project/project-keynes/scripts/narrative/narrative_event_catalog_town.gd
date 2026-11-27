class_name NarrativeEventCatalogTown
extends RefCounted

## 市井：八条孤立事件，写一条街上的纠纷、脸面、规矩和钱（不接链条，单条收束）。
##
##   更夫 · 丐头 · 私钱 · 火 · 摊 · 谣言 · 出殡 · 井水
##
## 这一包全部是脉冲入口；八条各带两三条权重规则，随建筑、职业构成、价格、时代、满意度浮动。
## 代价货币刻意错开：钱、名声、产能、民心、未来；每条的三个选项付的账都不一样。

const Ids = preload("res://scripts/narrative/narrative_event_ids.gd")
const Shared = preload("res://scripts/narrative/narrative_event_shared.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")

const PACK_ID := &"town"
const PREFIX := "evt.town."

const CAST := [
	"市政署", "商会", "行会", "巡防司", "常平仓", "公产基金", "市集特许", "钱监", "水务局", "街坊公议",
]

const MUL_075 := 49152
const MUL_080 := 52429
const MUL_085 := 55706
const MUL_105 := 68813
const MUL_110 := 72090
const MUL_115 := 75366
const MUL_120 := 78643
const MUL_125 := 81920
const MUL_130 := 85197
const MUL_135 := 88474


static func meta() -> Dictionary:
	return {
		"id": PACK_ID,
		"title": "市井",
		"theme": "一条街上的规矩",
		"era_band": "2-9",
		"prefix": PREFIX,
		"scale": "8 条中观/微观孤立",
		"cast": CAST,
		"node_ids": [
			String(Ids.EVT_TOWN_NIGHT_WATCH),
			String(Ids.EVT_TOWN_BEGGAR_GUILD),
			String(Ids.EVT_TOWN_FALSE_COIN),
			String(Ids.EVT_TOWN_FIRE),
			String(Ids.EVT_TOWN_STALL_FIGHT),
			String(Ids.EVT_TOWN_RUMOR),
			String(Ids.EVT_TOWN_GUILD_FUNERAL),
			String(Ids.EVT_TOWN_WELL_DISPUTE),
		],
	}


static func append(catalog) -> void:
	if catalog == null:
		return
	var Op = NarrativeConditionScript.Op
	var Ch = NarrativeEventDefinitionScript.TriggerChannel

	# ═══ 更夫 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_TOWN_NIGHT_WATCH),
		"title": "{settlement_name}·市政夜巡",
		"body_text": "随着{settlement_name}坊市扩张，原有的夜间巡防体制已难覆盖新建街区，近来商栈与工坊屡遭窃案。商会代表联名向市政署递交陈情，要求立即扩编巡防司人手，但对按铺面规模加征巡防捐颇有微词。地方财政官则指出，若全由国库垫付巡夜开销，势必挤占其他市政预算；而部分老资格守夜人亦反对引入新制，唯恐世袭差事旁落。如何平衡治安投入与商民税负，已成当务之急。",
		"image_key": "family.house",
		"ai_visual_prompt": "A night watchman with a wooden clapper in a gate tower, shopkeepers counting coins below, a constable with an abacus",
		"tags": ["town", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 2,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 12},
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
				"add_weight": 20,
				"reason": "街巷多了，火烛也多",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.03},
				"add_weight": 0,
				"multiplier_q16": MUL_120,
				"reason": "铺子怕偷",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 7},
				"add_weight": 0,
				"multiplier_q16": MUL_075,
				"reason": "街口装了电灯，梆子显得多余",
			},
		],
		"options": [
			Shared.option(
				"tax_the_shops", "征收铺捐，扩编巡防",
				"夜巡扩编落地",
				"市政署按铺面等级摊派巡防捐，巡防司得以增设双班夜哨。商栈失窃案随即锐减，工坊得以安心赶工，虽有中小商贩抱怨税负加重，整体治安已显著改观。",
				[
					Shared.cash_in(4, 540, "向本地人数最多的{primary_profession}征收其现金的 4%（铺捐转拨更夫）"),
					Shared.manufacturing(10, 540),
					Shared.bias(Ids.TAG_UNREST, 0.85, 540),
				]),
			Shared.option(
				"let_the_family_watch", "国库补贴旧制守夜",
				"旧制勉强维持",
				"朝廷拨款补贴原有守夜人手，未动商铺分毫。然而旧有巡逻编组难以兼顾偏远街区，入冬后窃案再度抬头，各商栈只得自行雇佣护院，街面猜忌日深。",
				[
					Shared.cash_out(3, 360),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
			Shared.option(
				"wait_until_spring", "暂缓扩编，维持现状",
				"治安持续恶化",
				"市政署搁置了巡防改革方案，夜间巡逻仍捉襟见肘。随着入室盗窃频发，工坊被迫缩短夜班工时，商民对地方治理的不满在坊间迅速蔓延。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.30, 720),
					Shared.manufacturing(-10, 540),
				]),
		],
	}))

	# ═══ 丐头 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_TOWN_BEGGAR_GUILD),
		"title": "{settlement_name}·流民秩序",
		"body_text": "{settlement_name}繁华街区近来涌入大批无业流民，其首领竟以维持街面整洁为名，向沿街商号定期收取规费。凡按期交纳者门前清静无事，拒交者则屡遭聚众滋扰。商会内部对此意见分裂，部分大商号主张花钱消灾，另一派则痛斥此举形同私税，要求市政署派巡防司彻底清剿。但负责治安的官吏警告，强行驱逐大批流民若无安置去处，恐在城郊酿成更大动荡。",
		"image_key": "family.house",
		"ai_visual_prompt": "A beggar chief with a cracked bowl on stone steps, shopkeepers handing wrapped coins, a constable watching from the lane",
		"tags": ["town", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 2,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 12},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.001},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.04},
				"add_weight": 20,
				"reason": "铺子门前要干净",
			},
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "wheat_grain", "float_value": 1.15},
				"add_weight": 0,
				"multiplier_q16": MUL_130,
				"reason": "米贵了，街上的人多起来",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 5},
				"add_weight": 0,
				"multiplier_q16": MUL_085,
				"reason": "巡警房管得过来了",
			},
		],
		"options": [
			Shared.option(
				"accept_the_rule", "划区收编，纳入规管",
				"灰产转为规管",
				"市政署在城郊划定收容区，将流民首领纳入街面杂役编外管理，并从商铺规费中抽成入库。商业区秩序迅速恢复，但城郊收容区内的隐性矛盾仍被压在台面之下。",
				[
					Shared.manufacturing(10, 540),
					Shared.cash_in(3, 540, "向本地人数最多的{primary_profession}征收其现金的 3%（铺子那笔钱里抽一份）"),
					Shared.bias(Ids.TAG_UNREST, 0.80, 540),
				]),
			Shared.option(
				"drive_him_out", "出动巡防，强制清剿",
				"清剿激化对立",
				"巡防司耗费公帑逮捕流民首领并将闲散人员驱出城区。虽一时震慑了私收规费之风，但被逐流民在城外聚拢滋事，商路受阻，坊市人心愈发惶惶。",
				[
					Shared.cash_out(4, 360),
					Shared.bias(Ids.TAG_UNREST, 1.35, 720),
					Shared.manufacturing(-10, 540),
				]),
			Shared.option(
				"look_the_other_way", "默许现状，暂不介入",
				"政令形同虚设",
				"市政署仅张贴禁令便不再深究，商号与地下帮派在暗中达成了脆弱的妥协。街面生意虽未停摆，但官府公信力大损，各方势力皆在试探法度底线。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.20, 720),
					Shared.manufacturing(8, 540),
				]),
		],
	}))

	# ═══ 私钱 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_TOWN_FALSE_COIN),
		"title": "{settlement_name}·私铸货币",
		"body_text": "由于官铸货币近来成色渐薄，{settlement_name}暗中出现了多处私铸炉灶，所出私钱反比官钱厚重压手。商会旗下商号起初尚存顾忌，但见市面信誉倾斜，已开始备秤验重、公然流通私钱。钱监官员紧急上书，痛陈铸币权乃国家命脉，绝不容民间染指；市政署却忧虑，若此时由巡防司强行查抄私炉，恐引发市面通货骤紧，反致工商业陷入停滞。",
		"image_key": "country.economy",
		"ai_visual_prompt": "A secret coin furnace smoking at night behind a house, thick coins on a small scale in a shop, an official sniffing outside the wall",
		"tags": ["town", "market", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 720,
		"min_era_index": 3,
		"max_era_index": 7,
		"required_technologies": ["tech.currency"],
		"conditions": [
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.02},
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.04},
				"add_weight": 20,
				"reason": "钱在铺子里过手最多",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 5},
				"add_weight": 0,
				"multiplier_q16": MUL_120,
				"reason": "官钱越铸越薄",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
				"add_weight": 10,
				"reason": "炉子藏在后院，烟从墙头出去",
			},
		],
		"options": [
			Shared.option(
				"take_the_furnace", "收编私炉，改隶钱监",
				"私炉收归官营",
				"国库拨款收购私铸工坊，将熟练炉匠一并编入钱监体系，统一铸造新式官币。铸币权得以保全，全国制造工艺亦受益于炉匠技术，但民间工匠对官营压价渐生怨怼。",
				[
					Shared.cash_out(5, 720),
					Shared.country_sector("manufacturing", 8, 540),
					Shared.bias(Ids.TAG_UNREST, 0.85, 540),
					Shared.bias(Ids.TAG_LABOR, 1.10, 540),
				]),
			Shared.option(
				"seal_the_furnace", "依法封炉，没收铜铁",
				"严厉取缔私铸",
				"巡防司雷霆查封私铸作坊，拆毁炉膛并将查获的金属充入市面储备。官府权威虽得以维护，但本地作坊资金链受创，商民对成色不足的官币益发不满。",
				[
					Shared.stock("wrought_iron", 15),
					Shared.manufacturing(-12, 540),
					Shared.bias(Ids.TAG_UNREST, 1.30, 720),
				]),
			Shared.option(
				"pretend_not_to_know", "默许流通，择优征税",
				"双轨通货并行",
				"市政署对私钱睁一只眼闭一只眼，唯独在征收赋税时要求折算足色好钱。市面交易借此保持活跃，但货币主权旁落，潜藏的金融与社会风险正悄然积聚。",
				[
					Shared.cash_in(3, 540, "向本地人数最多的{primary_profession}征收其现金的 3%（秋税收进好钱）"),
					Shared.manufacturing(10, 540),
					Shared.bias(Ids.TAG_UNREST, 1.20, 720),
				]),
		],
	}))

	# ═══ 火 ═══════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_TOWN_FIRE),
		"title": "{settlement_name}·城区大火",
		"body_text": "{settlement_name}密集的木构坊市突发大火，烈风裹挟火头迅速向东蔓延，逼近储备全城冬粮的常平仓与多处手工业作坊。巡防司组织人链提水扑救，但水源吃紧，火势仍呈失控之势。行会代表恳请优先保住沿街作坊与商栈，粮政官吏则严词警告，一旦常平仓付之一炬，全城今冬必陷粮荒。市政署必须在强拆民居开辟隔离带与集中兵力死守粮仓之间立刻拍板。",
		"image_key": "map.construction",
		"ai_visual_prompt": "A street fire at night, door planks used as shields, a bucket line from water vats, a woman looking back at her millstone",
		"tags": ["town", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 720,
		"min_era_index": 3,
		"max_era_index": 9,
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
			{"op": Op.POPULATION_GTE, "int_value": 15},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 5},
				"add_weight": 25,
				"reason": "木屋挨着木屋",
			},
			{
				"condition": {"op": Op.ERA_LTE, "int_value": 4},
				"add_weight": 0,
				"multiplier_q16": MUL_120,
				"reason": "还没有救火的机器",
			},
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "wheat_grain", "float_value": 1.10},
				"add_weight": 0,
				"multiplier_q16": MUL_115,
				"reason": "粮贵，仓里堆得满",
			},
		],
		"options": [
			Shared.option(
				"pull_down_the_east_row", "强拆民房，开辟火路",
				"断火止损成功",
				"巡防司果断拆除东侧连片木屋，火势抵近隔离带后终于受控，核心作坊得以保全。国库拨款抚恤拆迁户，但无家可归的怨气与重建建材紧缺仍困扰着市政署。",
				[
					Shared.cash_out(5, 540),
					Shared.manufacturing(10, 540),
					Shared.build_cost(10, 540),
					Shared.bias(Ids.TAG_UNREST, 1.10, 540),
				]),
			Shared.option(
				"save_the_granary", "全力护卫常平粮仓",
				"粮仓无恙工坊损",
				"救火力量尽数压向常平仓，全城冬粮安然无恙，稳住了基本口粮供应。然而周边数座工坊与商铺未能幸免，本地制造业元气大伤，受灾坊民怨声载道。",
				[
					Shared.staple(-15, 540),
					Shared.manufacturing(-12, 540),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
			Shared.gamble(
				"bet_on_the_wind", "固守要冲，待风势转弱",
				Shared.branch(39322, "风息火灭侥幸过关", # 60%
					"风势在午夜前骤然减弱，火头烧尽外围棚屋后自行熄灭。核心街区与粮仓仅受轻微波及，但险象环生的救灾过程仍令坊间对市政应急能力颇有微词。",
					[
						Shared.manufacturing(-8, 360),
						Shared.staple(10, 360),
						Shared.bias(Ids.TAG_UNREST, 1.05, 360),
					]),
				Shared.branch(26214, "风向骤变火烧连营", # 40%
					"大风突转北向，烈焰越过仓墙直扑核心商业区，大片工坊与商栈化为焦土。此次惨重火灾不仅重创本地产能与口粮储备，更导致人口折损与深重创伤。",
					[
						Shared.manufacturing(-18, 720),
						Shared.staple(18, 540),
						Shared.population_rate(-8),
					])),
		],
	}))

	# ═══ 摊 ═══════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_TOWN_STALL_FIGHT),
		"title": "{settlement_name}·市集特许",
		"body_text": "{settlement_name}主干道桥口的黄金地段长期供不应求，近期爆发了激烈的摊位归属纠纷。按月向市政署缴纳市集特许费的持证商户指责大批无证商贩占道抢客，严重侵蚀合法商税收益；流动商贩则辩称官定摊费过高，普通小民唯有摆散摊方能糊口。商会要求官府严厉维护特许契约的严肃性，而基层官吏却担心一味驱逐会激化底层生计矛盾，令街面秩序失控。",
		"image_key": "country.economy",
		"ai_visual_prompt": "Two food stalls squeezed into a bridge corner, a stew pot and a tea stove, a constable standing between them",
		"tags": ["town", "market"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 85,
		"cooldown_days": 720,
		"min_era_index": 2,
		"max_era_index": 7,
		"conditions": [
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.02},
			{"op": Op.POPULATION_GTE, "int_value": 12},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.05},
				"add_weight": 20,
				"reason": "摊子挤在桥口",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
				"add_weight": 0,
				"multiplier_q16": MUL_115,
				"reason": "街面窄，好位置就那几个",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 6},
				"add_weight": 0,
				"multiplier_q16": MUL_120,
				"reason": "巡警房开始管占道",
			},
		],
		"options": [
			Shared.option(
				"honour_the_receipt", "维护特许，清退无证摊",
				"特许契约得以维护",
				"市政署强令无证商贩迁入偏僻巷道，严格保障持证商户的独占区位。摊税如期入库，商业秩序趋于规范，但失去生计渠道的底层商贩积怨日深。",
				[
					Shared.cash_in(3, 540, "向本地人数最多的{primary_profession}征收其现金的 3%（摊地钱照收）"),
					Shared.manufacturing(8, 540),
					Shared.bias(Ids.TAG_UNREST, 1.10, 540),
				]),
			Shared.option(
				"draw_a_line", "划界并征，一律纳捐",
				"全面划界征税",
				"官府在要冲重新划定摊位标线，将所有流动商贩一并纳入摊税名册。财政收入随之增加，但加重的交易成本很快转嫁至日用饮食，令市民与商贩两头不悦。",
				[
					Shared.cash_in(4, 540, "向本地人数最多的{primary_profession}征收其现金的 4%（两家都交地钱）"),
					Shared.staple(10, 540),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
			Shared.option(
				"let_them_quarrel", "暂缓裁决，听凭自理",
				"市集陷入混乱",
				"市政署迟迟未作裁断，持证商户与流动商贩的摩擦愈演愈烈。多名纳捐商户愤而撤摊停业，桥口商贸日渐萧条，官府的市集管理威信也随之扫地。",
				[
					Shared.manufacturing(-10, 540),
					Shared.bias(Ids.TAG_UNREST, 1.25, 720),
				]),
		],
	}))

	# ═══ 谣言 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_TOWN_RUMOR),
		"title": "{settlement_name}·粮荒谣言",
		"body_text": "一则关于常平仓存粮即将外调、官仓已空的流言在{settlement_name}迅速发酵，短短数日便演变为全城范围的抢购潮。各大商号门前大排长龙，市民纷纷取出积蓄囤积口粮与药材，商会成员虽极力辟谣却收效甚微。巡防司主张立刻追查谣言源头、严惩造谣者以儆效尤；市政署部分幕僚则认为堵不如疏，唯有直接公开仓廪实况，方能彻底平息市场恐慌。",
		"image_key": "country.economy",
		"ai_visual_prompt": "A crowd queuing outside a grain shop, a woman at a well with a bucket, empty medicine drawers in an apothecary",
		"tags": ["town", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 720,
		"min_era_index": 2,
		"max_era_index": 9,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 12},
			{"op": Op.COHORT_SATISFACTION_LTE, "float_value": 0.55},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.SATISFACTION_LTE, "float_value": 0.45},
				"add_weight": 0,
				"multiplier_q16": MUL_125,
				"reason": "心里本来就有火",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.04},
				"add_weight": 15,
				"reason": "铺子里的话传得快",
			},
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "wheat_grain", "float_value": 1.15},
				"add_weight": 20,
				"reason": "米价一抬头，什么话都有人信",
			},
		],
		"options": [
			Shared.option(
				"open_the_granary", "开仓示众，刊布实账",
				"公开账目平息恐慌",
				"市政署敞开常平仓大门允许市民代表查验，并刊印详尽存粮告示广为张贴。粮价随即回落，抢购潮迅速退去，官府借此积累了印务公示的治理经验，唯行政耗费颇多。",
				[
					Shared.staple(-15, 540),
					Shared.manufacturing(-10, 540),
					Shared.research_signal("breakthrough.printing", "印版告示"),
				]),
			Shared.option(
				"arrest_the_woman", "严查源头，重罚造谣者",
				"高压弹压适得其反",
				"巡防司动用经费抓捕数名传谣者并游街示众。明面上的议论虽骤然消声，但私下里的猜疑却愈演愈烈，官民之间的信任裂痕进一步扩大。",
				[
					Shared.cash_out(3, 360),
					Shared.bias(Ids.TAG_UNREST, 1.35, 720),
					Shared.manufacturing(8, 360),
				]),
			Shared.option(
				"let_it_cool", "冷处理，待恐慌自息",
				"囤积推高粮价",
				"官府选择置之不理，恐慌情绪在沉默中持续放大。各大粮栈趁机抬高标价，民众生活成本骤增，坊间怨气积聚，连带正常工商业生产也受到拖累。",
				[
					Shared.staple(18, 720),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
					Shared.manufacturing(-10, 540),
				]),
		],
	}))

	# ═══ 出殡 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_TOWN_GUILD_FUNERAL),
		"title": "{settlement_name}·行会公产",
		"body_text": "{settlement_name}德高望重的行会领袖日前辞世，行会执事团以维护行业体面与凝聚力为由，提议动用行会公产基金举办极为隆重的丧仪排场。然而公产基金本由各作坊按月集资而成，初衷系用于抚恤伤残匠人与接济遗属。广大基层匠人对此强烈不满，质疑执事团借礼制之名挥霍公款；市政署若介入裁定，则需在尊重行业传统与规范公益财务之间作出取舍。",
		"image_key": "family.house",
		"ai_visual_prompt": "A guild funeral courtyard with stacked carrying poles, an old woman with a key ring on the threshold, an apprentice counting poles",
		"tags": ["town", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 85,
		"cooldown_days": 720,
		"min_era_index": 2,
		"max_era_index": 8,
		"required_technologies": ["tech.market_institutions"],
		"conditions": [
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "artisan", "float_value": 0.08},
			{"op": Op.POPULATION_GTE, "int_value": 12},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.001},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "artisan", "float_value": 0.12},
				"add_weight": 20,
				"reason": "行会人多，排场就有人看",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 6},
				"add_weight": 0,
				"multiplier_q16": MUL_085,
				"reason": "杠房改用马车，排场省了",
			},
			{
				"condition": {"op": Op.SATISFACTION_LTE, "float_value": 0.55},
				"add_weight": 15,
				"reason": "匠人心里有气，丧事容易出事",
			},
		],
		"options": [
			Shared.option(
				"full_pomp", "批准厚葬，彰显行会威仪",
				"盛大丧仪耗资不菲",
				"市政署批准并补贴了盛大丧仪，纸扎礼器需求大增，沿街铺面一时兴盛。行会高层的颜面得以保全，但公产基金几近见底，基层匠人对执事团的怨愤随之加深。",
				[
					Shared.cash_out(5, 540),
					Shared.stock("paper", 10),
					Shared.manufacturing(10, 360),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
			Shared.option(
				"keep_the_fund", "厉行节葬，保全公产基金",
				"公产章程得以确立",
				"丧仪一切从简，公产基金被严格锁定用于抚恤帮工与遗属。此举赢得广大匠人拥护，行会趁势拟定了更规范的互助章程，劳工组织意识亦随之抬头。",
				[
					Shared.cash_out(3, 360),
					Shared.bias(Ids.TAG_UNREST, 0.85, 540),
					Shared.research_signal("breakthrough.industrial_organization", "公匣与帮工章程"),
					Shared.bias(Ids.TAG_LABOR, 1.10, 540),
				]),
			Shared.option(
				"wait_three_days", "暂缓发丧，令各户分摊",
				"分摊丧费引发众怒",
				"官府驳回动用公产的请求，改令各作坊另行凑集丧费并从中抽成入库。发丧一拖再拖，匠人停工抗议，行会内部与官民之间的裂痕双双加剧。",
				[
					Shared.manufacturing(-12, 360),
					Shared.bias(Ids.TAG_UNREST, 1.30, 720),
					Shared.cash_in(3, 540, "向本地人数最多的{primary_profession}征收其现金的 3%（各家凑的丧仪，抽一份入官）"),
				]),
		],
	}))

	# ═══ 井水 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_TOWN_WELL_DISPUTE),
		"title": "{settlement_name}·公私水权",
		"body_text": "{settlement_name}赖以维生的公共主井近来水位骤降，经水务局查勘，系上游数户私有园圃私自掘渠截引地下水源所致。街坊公议连日向市政署施压，指责上游截流危及全城饮水安全，要求即刻强行填渠。上游业主却据理力争，坚称沟渠开凿于自家地界之内，若贸然断水将致本季蔬果绝收。如何在保障公共用水底线与保护私有产权之间划清红线，考验着官府的决断。",
		"image_key": "hydrology.water",
		"ai_visual_prompt": "A shallow well with muddy water, a hand-dug ditch running to a vegetable plot, neighbours arguing at the well platform",
		"tags": ["town", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 720,
		"min_era_index": 2,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 14},
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
				"add_weight": 20,
				"reason": "巷子两头都盖了房",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 6},
				"add_weight": 0,
				"multiplier_q16": MUL_085,
				"reason": "接了水管，井不那么要紧",
			},
			{
				"condition": {"op": Op.SATISFACTION_LTE, "float_value": 0.55},
				"add_weight": 0,
				"multiplier_q16": MUL_120,
				"reason": "心里有火，为半桶水也能打起来",
			},
		],
		"options": [
			Shared.option(
				"cut_the_ditch", "强行填渠，收归公水",
				"水源重归公用",
				"水务局动用公款雇工填平私渠，公共主井的水位在数日后逐渐回升。城区饮水危机得以解除，但上游农园收成锐减，业主群体的不满情绪持续发酵。",
				[
					Shared.cash_out(3, 360),
					Shared.agriculture(-12, 540),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
			Shared.option(
				"dig_a_second_well", "征资另凿副井分流",
				"副井完工缓解水荒",
				"市政署向相关户主摊派工程款，在下游另凿副井供浆洗与作坊使用。新井虽水质偏苦仅作杂用，却有效分担了主井压力，唯连带推高了本地营建成本。",
				[
					Shared.cash_in(4, 540, "向本地人数最多的{primary_profession}征收其现金的 4%（按户摊井钱）"),
					Shared.manufacturing(10, 540),
					Shared.build_cost(10, 540),
				]),
			Shared.option(
				"post_a_schedule", "颁布轮灌水令，限期取水",
				"水令难行纠纷再起",
				"水务局张贴了分时取水章程，却未配备足够人手稽查。告示很快遭人撕毁，上游私截依旧，城区每日为争水爆发口角，工坊日常运作亦受波及。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.30, 720),
					Shared.manufacturing(-10, 540),
				]),
		],
	}))
