class_name NarrativeEventCatalogTech
extends RefCounted

## 技术包：六条，各自只认一门具体科技。
##
## 之前所有事件都按「时代」粗分，没有一条读 `HAS_TECHNOLOGY`——同样的蒸汽时代，
## 研没研出蒸汽动力遇到的事是一样的。这一包把六门科技接成事件门槛，
## 让「先点什么科技」在叙事层也有回报。
##
## 科技 id 取自 `data/technology/technology_network.json`：
##   tech.irrigation / tech.movable_type_printing / tech.gunpowder_weapons /
##   tech.steam_power / tech.rail_logistics / tech.synthetic_fertilizer

const Ids = preload("res://scripts/narrative/narrative_event_ids.gd")
const Shared = preload("res://scripts/narrative/narrative_event_shared.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")

const PACK_ID := &"tech"
const PREFIX := "evt.tech."

const CAST := [
	"水利司", "分水册", "书业行会", "活字印坊",
	"兵部", "火器局", "蒸汽工场", "织造行会",
	"铁路局", "车马行", "农政署", "合成肥料",
]

const MUL_110 := 72090
const MUL_115 := 75366
const MUL_120 := 78643
const MUL_125 := 81920


static func meta() -> Dictionary:
	return {
		"id": PACK_ID,
		"title": "技术",
		"theme": "一门科技落到城里",
		"era_band": "2-10",
		"prefix": PREFIX,
		"scale": "6 条中观孤立",
		"cast": CAST,
		"node_ids": [
			String(Ids.EVT_TECH_IRRIGATION),
			String(Ids.EVT_TECH_PRINTING),
			String(Ids.EVT_TECH_GUNPOWDER),
			String(Ids.EVT_TECH_STEAM),
			String(Ids.EVT_TECH_RAIL),
			String(Ids.EVT_TECH_FERTILIZER),
		],
	}


static func append(catalog) -> void:
	if catalog == null:
		return
	var Op = NarrativeConditionScript.Op
	var Ch = NarrativeEventDefinitionScript.TriggerChannel

	# ═══ 灌溉 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_TECH_IRRIGATION),
		"title": "{settlement_name}·分水之争",
		"body_text": "新修的灌溉干渠通抵{settlement_name}，但干渠闸口有限，上下游农田随即爆发争水纠纷。上游田亩连片的大户依仗水利司旧例，要求按亩配水以保最大产出；下游小户却屡屡夜掘堤口，主张按户轮灌才算公允。若不尽快颁定统一的分水册，农时将误且乡野械斗恐难避免。",
		"image_key": "hydrology.water",
		"ai_visual_prompt": "A single irrigation sluice at a village, water roster on a millstone, a line drawn in mud, farmers on both banks",
		"tags": ["tech", "land", "agriculture"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 2,
		"max_era_index": 6,
		"conditions": [
			{"op": Op.HAS_TECHNOLOGY, "target_key": "tech.irrigation"},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "agricultural_worker", "float_value": 0.15},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "wheat_grain", "float_value": 1.10},
				"add_weight": 20,
				"multiplier_q16": MUL_115,
				"reason": "粮价高，水就更金贵",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "agricultural_worker", "float_value": 0.25},
				"add_weight": 15,
				"reason": "种地的人多，水才不够分",
			},
		],
		"options": [
			Shared.option(
				"by_acre", "依田亩配水，优先保障大田",
				"按亩定例",
				"分水册按田亩多寡排定次序，上游连片良田灌溉充足，农产稳步增长。但下游小户浇灌屡屡误时，乡间积怨随之加剧。",
				[
					Shared.agriculture(10, 540),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
			Shared.option(
				"by_household", "按户均轮灌，兼顾下游小农",
				"均户轮灌",
				"官府拨款修筑分水闸并推行按户轮灌，小农口粮得以宽裕，乡野安宁。但频繁启闭耗费国库开支，上游大户颇有微词。",
				[
					Shared.staple(-10, 360),
					Shared.cash_out(3, 360),
				]),
			Shared.option(
				"official_roster", "官定分水册，征收水税专管",
				"官印征费",
				"水利司加派巡渠官吏并按水册征收水税，国库添了一笔固定岁入。然而额外摊派惹怒了上下游农户，抗税与私掘时有发生。",
				[
					Shared.cash_in(3, 360),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
		],
	}))

	# ═══ 印刷 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_TECH_PRINTING),
		"title": "{settlement_name}·活字盗印",
		"body_text": "{settlement_name}新兴的活字印坊连夜赶印大批经史典籍，成本骤降之下，寒门学子争相购阅。然而执掌雕版旧业的书业行会联名控告印坊窃取祖传刻本，要求官府查抄活字并严惩盗印。学界普遍乐见典籍广传，行会则威胁若不保护版刻专权，将撤回对地方商税的承保。",
		"image_key": "country.technology",
		"ai_visual_prompt": "A print shop at dawn with movable type, two editions side by side, an old publisher arguing with the printer",
		"tags": ["tech", "school", "market"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 720,
		"min_era_index": 3,
		"max_era_index": 7,
		"conditions": [
			{"op": Op.HAS_TECHNOLOGY, "target_key": "tech.movable_type_printing"},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "scholar", "float_value": 0.01},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
				"add_weight": 20,
				"multiplier_q16": MUL_120,
				"reason": "城里有印坊，也有书铺",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "scholar", "float_value": 0.02},
				"add_weight": 15,
				"reason": "读书人多，书才卖得动",
			},
		],
		"options": [
			Shared.option(
				"ban_the_pirates", "严查私印，维护书业行会专权",
				"查抄活字",
				"官差起获私印活字并向书业行会征收护版规费，国库小有所得。但典籍供给重回垄断，寒门向学之路再度受阻。",
				[
					Shared.knowledge(-8, 360),
					Shared.cash_in(3, 360),
				]),
			Shared.option(
				"let_it_spread", "放任活字翻印，任由典籍广传",
				"文风广布",
				"活字印坊迅速扩张，圣贤经典与实用算册遍及闾巷，地方学风大盛。但传统雕版书坊接连倒闭，手工业产值短期受挫。",
				[
					Shared.knowledge(10, 540),
					Shared.manufacturing(-8, 360),
				]),
			Shared.option(
				"official_print", "设立官印局，统购活字校刊",
				"官刊定本",
				"朝廷拨款组建官印局，由旧书坊负责校勘、新印坊承印官本。典籍流通与校勘质量皆得保障，唯财政需承担持续补贴。",
				[
					Shared.cash_out(4, 360),
					Shared.knowledge(8, 540),
				]),
		],
	}))

	# ═══ 火药 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_TECH_GUNPOWDER),
		"title": "{settlement_name}·火炮与城防",
		"body_text": "{settlement_name}火器局新铸的重炮在试射中一举轰塌了旧式石垣，令城防体系顿时陷入过时危机。兵部守将力主大举改筑城墙、加厚棱堡与马面以抵御敌军炮火；火器局工师则主张将有限军费尽数投入扩产火炮，以攻代守方为上策。军费预算捉襟见肘，两派奏议同时呈至御前。",
		"image_key": "country.military",
		"ai_visual_prompt": "A newly cast cannon before a breached stone wall, an old brick with a previous dynasty's stamp exposed",
		"tags": ["tech", "war", "frontier"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 720,
		"min_era_index": 4,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.HAS_TECHNOLOGY, "target_key": "tech.gunpowder_weapons"},
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.AT_WAR, "bool_value": true},
				"add_weight": 25,
				"multiplier_q16": MUL_120,
				"reason": "在打仗，墙和炮都要紧",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 5},
				"add_weight": 10,
				"reason": "炮多了，城墙就不够厚",
			},
		],
		"options": [
			Shared.option(
				"thicken_the_wall", "拨款改筑城垣，加厚防炮马面",
				"固守新垣",
				"国库拨款征调石匠加厚城垣并增设炮台，朝堂守成派深感满意。但庞大的土木工程推高了营造耗费，短期财政承压。",
				[
					Shared.cash_out(5, 360),
					Shared.build_cost(8, 540),
					Shared.bias(Ids.TAG_COURT, 1.15, 540),
				]),
			Shared.option(
				"cast_more_cannons", "扩建火器局，加铸野战重炮",
				"铸炮强军",
				"军费悉数注入火器局开炉铸炮，冶铁与军工制造技艺突飞猛进。虽旧墙豁口暂未修补，城头火力已令周边邻邦忌惮。",
				[
					Shared.cash_out(6, 360),
					Shared.manufacturing(12, 540),
				]),
			Shared.option(
				"do_neither", "缩减军费开支，暂以木栅修补",
				"防务松弛",
				"两项提案皆被搁置，城墙豁口仅以木栅草草遮蔽。火器局匠师寒心散去，城防空虚的消息令地方人心惶惶。",
				[
					Shared.knowledge(-8, 360),
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
				]),
		],
	}))

	# ═══ 蒸汽 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_TECH_STEAM),
		"title": "{settlement_name}·蒸汽机房",
		"body_text": "第一座大型蒸汽工场在{settlement_name}点火试产，轰鸣的动力织机瞬间将布匹日产推上新台阶。然而传统织造行会面临灭顶之灾，大批手摇织户被迫停机，纷纷向市政当局递交请愿书要求限制机器扩张。资本家则警告，若因顾忌旧行会而延误机械化，本地纺织业将被外埠廉价机布彻底吞噬。",
		"image_key": "country.technology",
		"ai_visual_prompt": "A steam engine inside a weaving workshop, trembling beams, a broken handloom next door, coal shovel by the furnace",
		"tags": ["tech", "labor", "market"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 6,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.HAS_TECHNOLOGY, "target_key": "tech.steam_power"},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "artisan", "float_value": 0.08},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
				"add_weight": 20,
				"multiplier_q16": MUL_120,
				"reason": "有工场才装得下机器",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "artisan", "float_value": 0.12},
				"add_weight": 15,
				"reason": "织户多，才有人被机器挤掉",
			},
		],
		"options": [
			Shared.option(
				"build_the_mill", "国库注资扩厂，全面机械化",
				"烟囱林立",
				"财政贴息助建大规模蒸汽工场，高耸烟囱成为城市新景，本地制造业产能大幅跃升。传统手工织坊随之成片退出舞台。",
				[
					Shared.cash_out(5, 360),
					Shared.manufacturing(15, 540),
				]),
			Shared.gamble(
				"share_with_weavers", "撮合织造行会入股合营",
				Shared.branch(39322, "合营分红", # 60%
					"织户以手织机与资金入股蒸汽工场，新旧产能顺利整合。首年分红按契兑付，国库税收、制造产出与外销运力同步增长。",
					[
						Shared.cash_in(3, 360),
						Shared.manufacturing(10, 540),
						Shared.trade_capacity(8, 540),
					]),
				Shared.branch(26214, "退股风波", # 40%
					"织造行会不满工场利润分配而集体撤股，被迫由官府出面垫资善后。工厂停摆减产，城内劳资与行会矛盾骤然激化。",
					[
						Shared.cash_out(4, 360),
						Shared.manufacturing(-10, 360),
						Shared.bias(Ids.TAG_UNREST, 1.25, 540),
					])),
			Shared.option(
				"wait_and_watch", "暂缓审批扩建，观望行会动向",
				"机房封存",
				"蒸汽设备被蒙布封存以安抚旧行会，错失了抢占市场的先机。技术革新停滞不前，商界与失意工匠的怨气仍在暗中滋长。",
				[
					Shared.knowledge(-8, 360),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
		],
	}))

	# ═══ 铁路 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_TECH_RAIL),
		"title": "{settlement_name}·铁道通车",
		"body_text": "铁路局干线正式贯通{settlement_name}城郊，蒸汽列车的汽笛彻底改写了陆路物流格局。铁路货运运力惊人且成本远低于传统驿道，令垄断本地短途转运数十年的车马行陷入绝境。商会催促市政厅立即拨地兴建站前货栈以承接工业货流，车马行则集结失业车夫堵在站口，要求当局安置生计。",
		"image_key": "country.technology",
		"ai_visual_prompt": "A rammed-earth station platform on opening day, a carter holding his whip outside the crowd, white steam over the platform",
		"tags": ["tech", "market", "rail"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 7,
		"max_era_index": 9,
		"conditions": [
			{"op": Op.HAS_TECHNOLOGY, "target_key": "tech.rail_logistics"},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.03},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.05},
				"add_weight": 20,
				"multiplier_q16": MUL_125,
				"reason": "商人多，货就多",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 5},
				"add_weight": 15,
				"reason": "城大，站才养得住",
			},
		],
		"options": [
			Shared.option(
				"build_the_warehouse", "拨款兴建站前货栈，对接干线",
				"铁道枢纽",
				"大型货栈紧邻站台落成，原料与成品得以直接装车外运，本地制造业效率显著提升。传统车马行自此彻底退出干线运输。",
				[
					Shared.cash_out(5, 360),
					Shared.manufacturing(12, 540),
				]),
			Shared.option(
				"retrain_the_carters", "收编车马行转任站台装卸",
				"车夫转业",
				"当局向车马行征收转业登记费并将其编入站台装卸队，国库小有进账。但收入落差令大批老车夫心怀怨怼，罢工风潮暗涌。",
				[
					Shared.cash_in(3, 360),
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
				]),
			Shared.option(
				"wait_and_see", "暂缓站区配套，任由市场自调",
				"露天积货",
				"站台长期缺乏仓储设施，货物露天堆放损耗严重，列车频频过站不停。商界痛斥市政失职，物流革新停滞不前。",
				[
					Shared.knowledge(-8, 360),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
		],
	}))

	# ═══ 化肥 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_TECH_FERTILIZER),
		"title": "{settlement_name}·化肥推广",
		"body_text": "农政署向{settlement_name}调拨了首批工业合成肥料，试种田块的谷穗长势惊人，单产跃升显著。然而随行农学家与老农联合呈报，过量施用已导致表土板结、蚯蚓锐减，长期恐透支地力。面对日益增长的城市口粮需求，是全面补贴推广还是谨慎分区试行，内阁必须定夺。",
		"image_key": "climate.rain",
		"ai_visual_prompt": "Fertilizer sacks stacked by a clan hall, an old farmer smelling a handful, a spade turning over soil with few worms",
		"tags": ["tech", "agriculture", "land"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 8,
		"max_era_index": 10,
		"conditions": [
			{"op": Op.HAS_TECHNOLOGY, "target_key": "tech.synthetic_fertilizer"},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "agricultural_worker", "float_value": 0.10},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 20},
				"add_weight": 20,
				"multiplier_q16": MUL_115,
				"reason": "人多，地不够种",
			},
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "wheat_grain", "float_value": 1.15},
				"add_weight": 15,
				"reason": "粮价高，才舍得下本",
			},
		],
		"options": [
			Shared.option(
				"spread_it", "财政补贴，全境推广合成肥料",
				"丰产透支",
				"国库全额补贴化肥下乡，当季粮食单产大幅跃升，有效缓解了城市供给。但次年耕地显露板结迹象，农政署不得不着手监测土质。",
				[
					Shared.cash_out(5, 360),
					Shared.agriculture(15, 540),
				]),
			Shared.option(
				"half_first", "有偿配售半数田亩，对比试种",
				"分区对照",
				"农政署有偿配售化肥并划定半数耕地对照试种，国库收回部分成本且总产小幅增长。但未获配额的农户怨言四起，基层摩擦加剧。",
				[
					Shared.cash_in(3, 360),
					Shared.agriculture(8, 540),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
			Shared.option(
				"leave_it", "封存化肥，优先保护土壤生态",
				"休养地力",
				"这批合成肥料被封存停用，土壤生态与长期农艺观察得以留存。但缺少增产手段令当季农业产出回落，口粮供应略显吃紧。",
				[
					Shared.agriculture(-10, 360),
					Shared.knowledge(5, 360),
				]),
		],
	}))
