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
	"长老会", "氏族", "粮窖", "公墓", "陶窑", "祭祀",
	"商队", "海务司", "罗盘", "行会",
	"港务局", "信号塔", "工业资本", "监测系统", "生态红线", "林务委员会",
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
		"title": "{settlement_name}·留种之议",
		"body_text": "秋收告罄，{settlement_name}的粮窖仅余最后一批饱满谷种。氏族长老会主张严封谷种以备来年春播，否则聚落将彻底丧失农耕根基，被迫退回采集渔猎。但严冬将至，口粮吃紧的各户要求立即开窖分食，直言若挨不过寒冬便无来年可言。留种还是济急，这一抉择已摆上部落议事席。",
		"image_key": "family.house",
		"ai_visual_prompt": "A clay jar sealed with mud held by a villager, people watching around a threshing floor at the end of harvest",
		"tags": ["ages", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 900,
		"min_era_index": 0,
		"max_era_index": 1,
		"required_technologies": ["tech.crop_domestication"],
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
				"keep_the_seed", "严封粮窖，保住来年谷种",
				"春播有继",
				"粮窖被泥封看守，部落在严冬里勒紧裤带，口粮损耗加剧。开春时饱满谷种如期入土，新季农耕得以延续。",
				[
					Shared.agriculture(12, 540),
					Shared.staple(12, 360),
				]),
			Shared.option(
				"grind_it_and_eat", "开窖分食，先渡今冬荒年",
				"权济寒冬",
				"谷种被磨成口粮分予各户，聚落得以安然过冬，饥荒压力骤减。但来年春播无良种可用，田亩收成明显下滑。",
				[
					Shared.staple(-12, 180),
					Shared.agriculture(-10, 360),
				]),
			Shared.option(
				"share_with_neighbours", "各氏族均分谷种，共担春播",
				"分户共耕",
				"谷种按户分给相邻氏族共同保管耕作，既稳住了人心，也交流了选种经验，聚落人丁随之兴旺。",
				[
					Shared.birth(12, 540),
					Shared.knowledge(10, 540),
					Shared.bias(Ids.TAG_PEOPLE, 1.10, 540),
				]),
		],
	}))

	# ═══ 第一座坟 ═════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_AGES_FIRST_GRAVE),
		"title": "{settlement_name}·定居公墓",
		"body_text": "随着{settlement_name}转向定居，如何安葬逝者成为氏族面临的新礼制难题。长老会提议在高坡划定固定公墓并举行祭祀，以此凝聚共同祖先记忆；务实派却主张简葬于荒野，将劳力与牲畜留给春耕。另有部落首领建议将坟茔筑于通衢路口，向往来外族宣示这片土地已有定居之主。",
		"image_key": "family.house",
		"ai_visual_prompt": "Villagers carrying a body up a slope in winter, a half-dug grave with a large stone in it",
		"tags": ["ages", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 85,
		"cooldown_days": 900,
		"min_era_index": 0,
		"max_era_index": 2,
		"required_technologies": ["tech.settled_knowledge"],
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
				"pile_stones", "高坡立冢，堆石为祭祀之记",
				"祖灵有归",
				"高坡垒起石冢作为共同墓地，各氏族依例祭祀并传述先祖旧事，聚落工匠与礼俗传承皆有所进益。",
				[
					Shared.knowledge(10, 540),
					Shared.manufacturing(8, 360),
					Shared.bias(Ids.TAG_PEOPLE, 1.10, 540),
				]),
			Shared.option(
				"bury_and_forget", "从简掩埋，省力以赴农事",
				"简葬务农",
				"丧仪一切从简，省下的青壮劳力尽数投入开荒耕作，当年田产略有盈余。但缺乏共同祭仪，部族记忆日渐淡薄。",
				[
					Shared.agriculture(8, 360),
					Shared.knowledge(-10, 360),
				]),
			Shared.option(
				"bury_at_the_crossroads", "筑坟于路口，宣示定居地权",
				"路口示疆",
				"隆重的丧祭耗去不少口粮储备，却让往来部族知晓此处已成定居之邦。氏族凝聚力增强，聚落人口趋于稳定。",
				[
					Shared.birth(10, 540),
					Shared.staple(10, 360),
					Shared.bias(Ids.TAG_UNREST, 0.90, 360),
				]),
		],
	}))

	# ═══ 泥人 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_AGES_CLAY_FIGURE),
		"title": "{settlement_name}·陶俑与窑火",
		"body_text": "{settlement_name}的陶窑近日烧制出一批人形陶偶，形态古拙却颇受各氏族追捧，甚至被视作护宅与祭祀之器。专司日用陶罐的匠师担忧，烧造无用玩物会耗费大量柴薪与窑位，挤压炊具与储粮器皿的供给。然而主持祭祀的群体认为，精致陶偶既可凝聚信仰，亦能作为稀缺礼器与邻部交换盐货。",
		"image_key": "map.construction",
		"ai_visual_prompt": "A small fired clay figure with a crack, standing on a windowsill, neighbours gathered at a kiln",
		"tags": ["ages", "craft"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 80,
		"cooldown_days": 720,
		"min_era_index": 0,
		"max_era_index": 2,
		"required_technologies": ["tech.hand_pottery"],
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
				"fire_more_figures", "准许专窑烧造礼器陶偶",
				"窑火日精",
				"陶窑分出专炉烧造陶偶，制陶控火技艺大进，精巧器物更吸引邻部前来易货。但额外柴薪消耗令冬日生计略显吃紧。",
				[
					Shared.manufacturing(12, 540),
					Shared.knowledge(10, 540),
					Shared.staple(10, 360),
				]),
			Shared.option(
				"put_it_away", "禁造玩物，专注日用陶器",
				"严守实用",
				"长老会下令陶窑只准烧制盆罐，部落秩序井然却错失工艺革新契机。不久后邻部精绘陶器流入，反令本地匠作相形见绌。",
				[
					Shared.manufacturing(-8, 360),
					Shared.knowledge(-8, 360),
					Shared.bias(Ids.TAG_UNREST, 0.90, 360),
				]),
			Shared.option(
				"let_everyone_make_one", "开放河泥与公窑，鼓励民创",
				"百态陶风",
				"各户纷纷塑像烧窑，聚落工艺审美与文化活力大振。然而争抢河泥与窑位引发多起纠纷，地方摩擦随之抬头。",
				[
					Shared.knowledge(15, 540),
					Shared.birth(10, 540),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
		],
	}))

	# ═══ 迷路的商队 ═══════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_AGES_CARAVAN_LOST),
		"title": "{settlement_name}·迷途商队",
		"body_text": "一支满载精盐与异域织物的外邦商队在西境荒道迷途，疲敝不堪地滞留于{settlement_name}城外。地方官吏中有人主张借口盘查扣押货物充公，以充实国库；城内行会则担心外商落户会冲击本地布帛销路，力主将其礼送出境。亦有通商派建议拨给商栈准其常驻，借此开辟新的陆路货源。",
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
				"guide_them_out", "官派向导护送，结好商路",
				"商道渐通",
				"朝廷拨款雇请向导护送商队重返正途，外邦商号感念信义，此后逐年遣队来贸，本国商路吞吐与域外见闻皆得增益。",
				[
					Shared.trade_capacity(15, 360),
					Shared.cash_out(4, 360),
					Shared.knowledge(8, 360),
					Shared.bias(Ids.TAG_FRONTIER, 1.10, 540),
				]),
			Shared.option(
				"seize_the_goods", "扣押无凭商货，充入官库",
				"商誉受损",
				"精盐与织物被悉数没收充公，国库获一笔横财。但外商愤而远遁，西境商旅视本地为畏途，边道劫掠与地方不安随之滋生。",
				[
					Shared.cash_in(5, 360),
					Shared.manufacturing(-10, 360),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
			Shared.option(
				"ask_them_to_stay", "特许留城设栈，引入外贸",
				"异邦商栈",
				"外商获准在城南开设货栈，带来新式织法与远方货源。本地行会不满外人夺利而屡起抵制，城中商贸摩擦与生活开销一时俱增。",
				[
					Shared.trade_capacity(10, 540),
					Shared.knowledge(10, 540),
					Shared.staple(10, 360),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
		],
	}))

	# ═══ 针 ═══════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_AGES_COMPASS_DOUBT),
		"title": "{settlement_name}·磁针与海图",
		"body_text": "{settlement_name}的海务司近日购得一具外邦磁针罗盘，无论船身如何转向，指针始终稳指一端。航海行会振奋不已，宣称凭此即可摆脱观星束缚，在阴云大雾中直航远海。但钦天学者警告，尚未校验磁偏误差便贸然远航极易船毁人亡，守旧教团更斥之为惑众异术，力主封禁。",
		"image_key": "hydrology.water",
		"ai_visual_prompt": "A needle in a wooden box on a ship's bow, a boatman and a star-gazer arguing over it, sailors watching",
		"tags": ["ages", "knowledge", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 720,
		"min_era_index": 4,
		"max_era_index": 6,
		"required_technologies": ["tech.magnetic_navigation"],
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
				"trust_the_needle", "配发远洋试航，开拓新路",
				Shared.branch(39322, "盲航凯旋", # 60%
					"试航船队仅凭罗盘穿越连日阴雾并顺利返港，远洋航路图得以补全。尽管守旧派仍心怀忌惮，海务与学界已为之震动。",
					[
						Shared.trade_capacity(15, 360),
						Shared.knowledge(12, 540),
						Shared.research_signal("contact.maritime_vessel", "远洋航路"),
						Shared.bias(Ids.TAG_UNREST, 1.10, 540),
					]),
				Shared.branch(26214, "试航失联", # 40%
					"远航船队因未修正磁偏误入暗礁区，逾期未归，仅余残骸漂回近海。舆论哗然，海务改革受挫，守旧之声一时大炽。",
					[
						Shared.manufacturing(-10, 540),
						Shared.knowledge(-8, 360),
						Shared.bias(Ids.TAG_UNREST, 1.30, 540),
					])),
			Shared.option(
				"test_it_on_the_river", "先于内河校验，测录误差",
				"稳步勘校",
				"学者与舵手在内河航道反复比对磁针与岸标，详录偏角数据。虽耗去一批仪具工料，却为日后远航奠定了可靠基准。",
				[
					Shared.knowledge(10, 540),
					Shared.trade_capacity(6, 360),
					Shared.tools(12, 360),
				]),
			Shared.option(
				"lock_it_away", "封存官库，平息教团非议",
				"束之高阁",
				"罗盘被锁入官库，教团与守旧派的攻讦随之平息。但数年后外邦商船凭同类仪具纵横近海，本国航海技艺已落后一筹。",
				[
					Shared.knowledge(-10, 360),
					Shared.bias(Ids.TAG_FAITH, 1.15, 540),
					Shared.bias(Ids.TAG_UNREST, 0.90, 360),
				]),
		],
	}))

	# ═══ 信号塔 ═══════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_AGES_SIGNAL_TOWER),
		"title": "{settlement_name}·导航信号塔",
		"body_text": "随着夜间航运量激增，{settlement_name}港务局提议在高地兴建全天候电气导航信号塔，为进港货轮提供高频无线电信标。财政部门指出，公营建塔与常年电力运维是一笔不小的持续支出。工业资本与航运财团则愿全额出资承建，条件是取得特许经营权并按吨位向每艘进港船只征收导航费。",
		"image_key": "map.construction",
		"ai_visual_prompt": "A wooden signal tower with a lamp on a ridge above a harbour, a clerk and a merchant arguing at its base",
		"tags": ["ages", "market", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 8,
		"max_era_index": 10,
		"required_technologies": ["tech.radio", "tech.electric_grid"],
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
				"build_it_public", "国家拨款公建，免费开放信标",
				"公营信标启用",
				"国有导航信号塔按期并网运行，全天候引导货轮安全靠泊，港口吞吐稳步提升。财政为此承担了持续的建设与运维开销。",
				[
					Shared.trade_capacity(12, 540),
					Shared.cash_out(6, 360),
					Shared.bias(Ids.TAG_LABOR, 1.10, 540),
				]),
			Shared.option(
				"let_the_merchants_build", "授予航运财团特许经营",
				"私营收费信标",
				"财团迅速建成高功率信号塔并上缴特许分成，港口运力大增。但高额导航费激怒了中小船东，偷航避费引发数起事故与抗议。",
				[
					Shared.trade_capacity(14, 540),
					Shared.cash_in(5, 360),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
			Shared.option(
				"no_tower", "搁置建塔计划，压缩基建开支",
				"暗夜滞航",
				"信号塔计划被无限期搁置，恶劣天气下货轮频频在外海滞留甚至触礁。供应链延误波及本地工厂，港务舆论一片哗然。",
				[
					Shared.manufacturing(-8, 360),
					Shared.bias(Ids.TAG_UNREST, 1.10, 540),
				]),
		],
	}))

	# ═══ 机器听见 ═════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_AGES_MACHINE_HEARS),
		"title": "{settlement_name}·全时监测系统",
		"body_text": "{settlement_name}的大型仓储与工业园区率先试装了一套自动声纹与工效监测系统，可实时记录每名工人的交谈频次、停顿时长与分拣效率，并据此自动重排夜班表。工业资本盛赞其大幅压低管理损耗与差错率。劳工团体则痛斥这套算法监控侵犯人格尊严、令职场高压失控，要求内阁立即立法予以规制。",
		"image_key": "map.construction",
		"ai_visual_prompt": "Workers standing under a listening machine in a warehouse, a shift board with names moved to the night column",
		"tags": ["ages", "labor", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 720,
		"min_era_index": 9,
		"max_era_index": 10,
		"required_technologies": ["tech.digital_computing"],
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
				"install_everywhere", "全城工业区推广监测系统",
				"算法高压",
				"全时监测覆盖各大厂区，排班与物流效率大幅攀升。但无处不在的绩效压榨令劳工身心俱疲，生育意愿下滑，罢工暗流涌动。",
				[
					Shared.manufacturing(20, 540),
					Shared.birth(-15, 540),
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
				]),
			Shared.option(
				"warehouse_only", "限定仓储核验，禁止监控工位",
				"分级规制",
				"内阁颁布细则，将监测系统严格限定于货品核验环节并引入独立审计。生产效率稳步提高，数据治理经验亦得以积累。",
				[
					Shared.manufacturing(10, 540),
					Shared.knowledge(12, 540),
					Shared.bias(Ids.TAG_UNREST, 1.05, 360),
				]),
			Shared.option(
				"tear_it_out", "全面拆除设备，保护劳工隐私",
				"隐私立法",
				"监测终端被悉数拆除，企业不得不回归人工排班与核账，工业效率短期回落。劳资对立随之缓和，人本治理赢得舆论赞誉。",
				[
					Shared.manufacturing(-12, 360),
					Shared.knowledge(8, 360),
					Shared.bias(Ids.TAG_UNREST, 0.90, 540),
				]),
		],
	}))

	# ═══ 最后的林子 ═══════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_AGES_LAST_FOREST),
		"title": "{settlement_name}·水源林红线",
		"body_text": "{settlement_name}近郊仅存的一片原生水源林正面临工业扩张的吞噬。随着新厂区与仓储扩建，木材原料严重短缺，工业资本与开发商联名请求放开林地采伐或整体拍卖，声称所得收益足以支撑全城数季建设。林务委员会则紧急呈报，该片林带维系着全流域地下水位，一旦越过生态红线，下游农田与城市供水都将付出长远代价。",
		"image_key": "economy.resource",
		"ai_visual_prompt": "A forest reduced to the lower slope, a forester wiping a boundary stone, a timber buyer with a purse",
		"tags": ["ages", "land", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 900,
		"min_era_index": 7,
		"max_era_index": 10,
		"required_technologies": ["tech.factory_system"],
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
				"protect_the_forest", "划定生态红线，严禁采伐",
				"固本护源",
				"原生林被划为永久禁伐区，本地建材供给趋紧，制造部门成本上升。但流域水源得以保全，生态研究与宜居环境惠及全城。",
				[
					Shared.knowledge(10, 540),
					Shared.birth(10, 540),
					Shared.manufacturing(-12, 360),
					Shared.bias(Ids.TAG_UNREST, 0.90, 540),
				]),
			Shared.option(
				"cut_it_all", "全面采伐林地，改作垦殖",
				"竭泽而渔",
				"林木被迅速伐尽并投入厂区建设，制造业短期大振。然而次年汛期水土严重流失，泥沙淤塞下游沟渠，农产减收且民怨四起。",
				[
					Shared.manufacturing(18, 540),
					Shared.agriculture(-10, 540),
					Shared.bias(Ids.TAG_UNREST, 1.25, 540),
				]),
			Shared.option(
				"sell_the_timber", "拍卖林木采伐权，充实国库",
				"变现林权",
				"采伐特许权高价售予外地木业财团，国库进账可观并短暂带动加工业。但裸露山坡风沙渐起，环保团体与市民抗议不断。",
				[
					Shared.cash_in(5, 360),
					Shared.manufacturing(8, 360),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
		],
	}))
