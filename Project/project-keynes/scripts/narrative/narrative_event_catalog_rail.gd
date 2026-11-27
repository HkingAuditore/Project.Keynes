class_name NarrativeEventCatalogRail
extends RefCounted

## 铁路包：七条孤立事件，钢轨穿过田、城、河与山（era 6–8）。
##
##   征地 · 车站 · 时刻表 · 票价 · 桥 · 隧道 · 货场
##
## 全部是脉冲入口，不接链、不留标记：一件事进来，三个选项，各自结账。
## 器物只到蒸汽为止——钢轨、道钉、枕木、时刻表、车票、号志灯、蒸汽机车；
## 没有内燃、没有电气化，也没有一条线能一次修成。
##
## 代价货币刻意错开（测试按代价指纹逐条比对）：
##   征地——掉农业 / 抬工具开销 / 抬风险
##   车站——征商款 / 占农地 / 货运拖延
##   时刻表——校钟开销 / 压制造业 / 抬市场风险
##   票价——商户分摊 / 长途货改道 / 穷人挤不上车
##   桥——合龙赌一次（赌输掉制造业 + 抬动荡）/ 再等一季要现钱 / 填石毁田抬粮价
##   隧道——停工压制造业 / 借债买设备 / 停掘掉知识
##   货场——路局抽成 + 脚行闹 / 包干压制造业 / 混管抬工具开销

const Ids = preload("res://scripts/narrative/narrative_event_ids.gd")
const Shared = preload("res://scripts/narrative/narrative_event_shared.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")
const TerrainTypeScript = preload("res://scripts/geography/terrain_type.gd")

const PACK_ID := &"rail"
const PREFIX := "evt.rail."

const CAST := [
	"铁路局", "征地章程", "旧城商会", "蒸汽干线",
	"调度时刻表", "标准时制", "三等票价", "铁路债券",
	"钢梁大桥", "穿山隧道", "脚行工会", "铁路货场",
]

const MUL_110 := 72090
const MUL_115 := 75366
const MUL_120 := 78643
const MUL_125 := 81920
const MUL_130 := 85197
const MUL_135 := 88474


static func meta() -> Dictionary:
	return {
		"id": PACK_ID,
		"title": "铁路",
		"theme": "一条钢轨怎样穿过田、城、河与山",
		"era_band": "6-8",
		"prefix": PREFIX,
		"scale": "7 条中观/微观孤立",
		"cast": CAST,
		"node_ids": [
			String(Ids.EVT_RAIL_LAND),
			String(Ids.EVT_RAIL_STATION),
			String(Ids.EVT_RAIL_TIMETABLE),
			String(Ids.EVT_RAIL_FARE),
			String(Ids.EVT_RAIL_BRIDGE),
			String(Ids.EVT_RAIL_TUNNEL),
			String(Ids.EVT_RAIL_FREIGHT),
		],
	}


static func append(catalog) -> void:
	if catalog == null:
		return
	var Op = NarrativeConditionScript.Op
	var Ch = NarrativeEventDefinitionScript.TriggerChannel

	# ═══ 征地 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_RAIL_LAND),
		"title": "{settlement_name}·铁道征地",
		"body_text": "铁路局为贯通{settlement_name}蒸汽干线所划定的测绘路线，径直穿过城郊大片肥沃水田。尽管征地章程允诺按亩折算数年收成并一次结清补偿，当地自耕农仍强烈抵制，指控祖辈经营的良田远非官定市价可比。工程总监警告，改线绕坡将大幅拉长工期与钢轨耗费，而强行推进又恐激起乡野抗拒。",
		"image_key": "map.construction",
		"ai_visual_prompt": "Survey stakes driven through a flooded rice field, a railway clerk unrolling a compensation schedule on the ridge, a farmer kneeling at a stake",
		"tags": ["rail", "land", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 6,
		"max_era_index": 8,
		"required_technologies": ["tech.rail_logistics"],
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
			{"op": Op.POPULATION_GTE, "int_value": 15},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 5},
				"add_weight": 20,
				"multiplier_q16": MUL_115,
				"reason": "屋多，线就不好绕",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "agricultural_worker", "float_value": 0.15},
				"add_weight": 25,
				"multiplier_q16": MUL_120,
				"reason": "种地的人多，征的就是他们的田",
			},
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 25},
				"add_weight": 20,
				"reason": "人稠地窄，一亩也含糊不得",
			},
		],
		"options": [
			Shared.option(
				"buy_it_out", "依章程足额买断，强力清场",
				"良田易轨",
				"国库拨款按章程结清地款，路基迅速穿过水田。干线得以笔直铺设，但大片良田被占令本地农产下滑，口粮供给趋紧。",
				[
					Shared.agriculture(-18, 540),
					Shared.cash_out(5, 360),
					Shared.staple(12, 540),
				]),
			Shared.option(
				"move_the_line", "修改勘测路线，绕坡避开农田",
				"绕坡保田",
				"铁路改由荒坡蜿蜒绕行，水田得以保全且农产微增。但额外路基工程大幅增加了工具与工料消耗，制造产能短期受挤压。",
				[
					Shared.tools(18, 540),
					Shared.manufacturing(-10, 360),
					Shared.agriculture(10, 540),
					Shared.bias(Ids.TAG_LAND, 1.15, 540),
				]),
			Shared.option(
				"hold_the_paper", "暂扣补偿款项，搁置征地争议",
				"僵持误工",
				"征地款迟迟未发，农田与测桩陷入长期拉锯。铁路施工被迫停滞，工料积压拖累制造，乡野怨气与口粮压力随之攀升。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
					Shared.staple(15, 540),
					Shared.manufacturing(-8, 360),
				]),
		],
	}))

	# ═══ 车站 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_RAIL_STATION),
		"title": "{settlement_name}·车站选址",
		"body_text": "{settlement_name}蒸汽干线的枢纽车站选址陷入激烈角力。铁路局与旧城商会中的大商户力主将站台直插旧城核心商街，哪怕须拆迁半条手工业作坊街区也在所不惜；而城郊地主与新兴实业派则主张在城外荒滩建站，既免去高昂拆迁风波，又能为日后工业扩张留足腹地。两份规划图已并呈市政案头。",
		"image_key": "map.construction",
		"ai_visual_prompt": "Two station site plans pinned on a shop counter with inkstones, a blacksmith covering his own shop on the drawing, a sample rail spike beside them",
		"tags": ["rail", "market", "land"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 720,
		"min_era_index": 6,
		"max_era_index": 8,
		"required_technologies": ["tech.rail_logistics"],
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
			{"op": Op.POPULATION_GTE, "int_value": 15},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 5},
				"add_weight": 20,
				"multiplier_q16": MUL_115,
				"reason": "城里挤，站台没处放",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.02},
				"add_weight": 0,
				"multiplier_q16": MUL_120,
				"reason": "铺面都在争站口",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 7},
				"add_weight": 15,
				"reason": "车次密了，站就小了",
			},
		],
		"options": [
			Shared.option(
				"tear_the_street", "拆迁旧城街区，站台直入商埠",
				"破旧立站",
				"旧城商街被征拆过半，商户补缴的摊派充实了国库，站口直连商埠令贸易运力大增。但大批传统作坊被迫迁散，制造产能受损。",
				[
					Shared.cash_in(4, 360),
					Shared.trade_capacity(10, 540),
					Shared.manufacturing(-12, 540),
				]),
			Shared.option(
				"build_on_the_flats", "城外荒滩设站，预留工业腹地",
				"城郊新站",
				"车站立于城外空地并迅速吸引新式工场集聚，制造业产能显著跃升。然而配套修路推高了营造耗费，周边耕地亦被大片侵占。",
				[
					Shared.manufacturing(15, 540),
					Shared.build_cost(10, 540),
					Shared.agriculture(-12, 540),
				]),
			Shared.option(
				"make_a_road_first", "先筑城郊便道，暂设临时停靠",
				"权宜便道",
				"财政拨款先修土路衔接城外岔道，避免了激烈拆迁并略微改善商路。但雨季泥泞严重拖慢货流周转，本地制造与市面皆受其累。",
				[
					Shared.bias(Ids.TAG_MARKET, 1.20, 540),
					Shared.manufacturing(-10, 540),
					Shared.trade_capacity(6, 540),
					Shared.cash_out(3, 180),
				]),
		],
	}))

	# ═══ 时刻表 ═══════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_RAIL_TIMETABLE),
		"title": "{settlement_name}·标准时制",
		"body_text": "蒸汽列车班次加密后，{settlement_name}沿线各城各自为政的报时习惯彻底失灵。鼓楼、市政厅与码头的钟表前后相差可达一刻，导致铁路局的调度时刻表频频紊乱，货栈装卸与乘客换乘屡屡脱节。铁路局要求全国强制推行统一的标准时制，而传统行会与地方官绅则坚称应以城中鼓楼古钟为尊。",
		"image_key": "country.economy",
		"ai_visual_prompt": "A hand-drawn railway timetable pinned to a dispatch office wall, a dispatcher with a pencil, station clocks and a bell tower beyond the window",
		"tags": ["rail", "market", "labor"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 720,
		"min_era_index": 6,
		"max_era_index": 8,
		"required_technologies": ["tech.rail_logistics"],
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
			{"op": Op.POPULATION_GTE, "int_value": 18},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 26},
				"add_weight": 25,
				"multiplier_q16": MUL_115,
				"reason": "人多了，误一刻就是一堆人",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 6},
				"add_weight": 20,
				"reason": "货栈多，表就有用",
			},
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "wheat_grain", "float_value": 1.15},
				"add_weight": 15,
				"multiplier_q16": MUL_110,
				"reason": "粮价高，谁都催车",
			},
		],
		"options": [
			Shared.option(
				"follow_the_drum_tower", "校准全城钟表，统归市政标准",
				"统一校准",
				"当局斥资购置精密校时器具统一全城钟表，虽增加了仪器耗材开支，却令全境工业协同与近代计量观念迈上新台阶。",
				[
					Shared.knowledge(12, 540),
					Shared.tools(18, 540),
					Shared.country_sector("manufacturing", 10, 540),
				]),
			Shared.option(
				"follow_the_railway", "强制推行铁路时，全城依表运转",
				"铁道标准时",
				"列车严格按铁路局时刻表准点发车，跨城贸易运力与科学时间观念大增。但旧式作坊一时难以适应新节奏，本地制造短期受挫。",
				[
					Shared.trade_capacity(12, 540),
					Shared.manufacturing(-12, 540),
					Shared.knowledge(10, 540),
				]),
			Shared.option(
				"each_station_its_own", "维持各城旧钟，各站自行对表",
				"调度紊乱",
				"各站沿用地方旧时，单线区间屡现对开避让延误，商贸纠纷频发。虽乡村农时未受干扰，本地工商业效率却因此折损。",
				[
					Shared.bias(Ids.TAG_MARKET, 1.25, 540),
					Shared.manufacturing(-10, 540),
					Shared.agriculture(10, 540),
				]),
		],
	}))

	# ═══ 票价 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_RAIL_FARE),
		"title": "{settlement_name}·客运票制",
		"body_text": "{settlement_name}车站的三等票价再度上调，引发底层民众与脚行工会的强烈抗议。铁路局辩称，高昂的煤炭消耗与铁路债券还本压力迫使其必须维持客运盈利。代表短途佣工与商贩的请愿书则痛陈，过高的通行门槛正在割裂城乡人员往来，要求市政当局出面干预定价机制。",
		"image_key": "country.economy",
		"ai_visual_prompt": "A third-class fare board written in charcoal beside a ticket window, a woman counting coins below it, a signal lamp with soot on the glass",
		"tags": ["rail", "market", "labor", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 105,
		"cooldown_days": 720,
		"min_era_index": 6,
		"max_era_index": 8,
		"required_technologies": ["tech.rail_logistics"],
		"conditions": [
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.02},
			{"op": Op.POPULATION_GTE, "int_value": 18},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.05},
				"add_weight": 0,
				"multiplier_q16": MUL_125,
				"reason": "商人多，票价就是他们的生意",
			},
			{
				"condition": {"op": Op.COHORT_SATISFACTION_LTE, "float_value": 0.45},
				"add_weight": 30,
				"reason": "日子紧的人，先算路费",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
				"add_weight": 15,
				"reason": "来往的人多，板上的字改得勤",
			},
		],
		"options": [
			Shared.option(
				"cut_the_third_class", "核减三等客票，摊征商户补贴",
				"薄利广运",
				"三等车厢载客量激增，城乡人口流动与商旅吞吐同步跃升。路局的客运缺口则通过向本地商号摊征附加费予以填补。",
				[
					Shared.cash_in(3, 360),
					Shared.trade_capacity(10, 540),
					Shared.birth(10, 540),
				]),
			Shared.option(
				"charge_by_distance", "推行阶梯里程制，优待短途",
				"里程分档",
				"短途通勤变得平易，城郊佣工与口粮周转随之改善，贸易运力小幅上升。但长途原料转运负担加重，拖累了本地制造产能。",
				[
					Shared.manufacturing(-12, 540),
					Shared.trade_capacity(8, 540),
					Shared.staple(-10, 540),
				]),
			Shared.option(
				"add_a_slow_train", "维持现行资费，增开站站慢车",
				"慢车分流",
				"低速慢车加挂于干线之后，货运与工业通勤得以维持运转。但漫长候车与资费门槛未解，底层乘客的不满情绪持续累积。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.25, 540),
					Shared.manufacturing(10, 540),
					Shared.trade_capacity(6, 540),
				]),
		],
	}))

	# ═══ 桥（本包唯一博弈）══════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_RAIL_BRIDGE),
		"title": "{settlement_name}·铁桥合龙",
		"body_text": "横跨大河的{settlement_name}钢梁大桥进入最后合龙关头，悬吊梁段却与桥墩存在一臂偏差。汛期将至，浮船随时被迫撤离。施工总包方主张趁烈日钢梁热胀立即强行落梁，抢通蒸汽干线；铁路局总工则严词反对，要求停工一季待枯水期重搭支墩，另有地方官提议干脆在下游浅滩填石筑堤过河。",
		"image_key": "map.construction",
		"ai_visual_prompt": "The last span of an iron railway bridge hanging over a river, scaffolding one arm's width apart, a worker smoking on the beam, two engineers arguing over drawings",
		"tags": ["rail", "land", "labor"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 110,
		"cooldown_days": 900,
		"min_era_index": 6,
		"max_era_index": 8,
		"required_technologies": ["tech.rail_logistics"],
		"conditions": [
			{"op": Op.HAS_RIVER, "bool_value": true},
			{"op": Op.POPULATION_GTE, "int_value": 15},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.TERRAIN_IN, "int_list": [TerrainTypeScript.TERRAIN.PLAIN]},
				"add_weight": 20,
				"reason": "河面平缓，桥才修得起来",
			},
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 24},
				"add_weight": 20,
				"multiplier_q16": MUL_115,
				"reason": "两岸都要过河的人多",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 5},
				"add_weight": 20,
				"reason": "货等着过河",
			},
		],
		"options": [
			Shared.gamble(
				"close_it_today", "趁汛前强行落梁，赌一次合龙",
				Shared.branch(39322, "铁桥顺利合龙", # 60%
					"钢梁在正午精准落位并锁紧铆钉，两岸干线如期贯通。尽管加急施工略微推高营造耗费，贸易运力与制造产出随即大振。",
					[
						Shared.manufacturing(12, 540),
						Shared.trade_capacity(15, 540),
						Shared.build_cost(8, 540),
					]),
				Shared.branch(26214, "梁体倾覆事故", # 40%
					"强行合龙导致梁端撞毁桥墩，数名桥工随钢梁坠河遇难。重大工程惨剧重创本地制造业与人口元气，全城舆论哗然。",
					[
						Shared.manufacturing(-24, 540),
						Shared.bias(Ids.TAG_UNREST, 1.35, 540),
						Shared.population_rate(-5),
					])),
			Shared.option(
				"wait_one_season", "遵从总工意见，待枯水期重筑",
				"稳妥延期",
				"工程暂停一季，当局通过附加征费维持待工开销，稳住了桥工安全与地方人心，滞留劳力亦顺势支援了沿岸农事。",
				[
					Shared.cash_in(4, 360),
					Shared.agriculture(10, 540),
					Shared.bias(Ids.TAG_UNREST, 0.90, 540),
				]),
			Shared.option(
				"fill_the_shallows", "下游浅滩填石筑堤，强渡大河",
				"填堤毁田",
				"征取两岸田土筑起的石堤虽勉强维系了少量通车，却在头场秋汛中被冲毁半截。沿岸农产大减、口粮趋紧且制造受拖累。",
				[
					Shared.agriculture(-15, 540),
					Shared.staple(18, 540),
					Shared.manufacturing(-10, 540),
					Shared.trade_capacity(6, 540),
				]),
		],
	}))

	# ═══ 隧道 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_RAIL_TUNNEL),
		"title": "{settlement_name}·穿山隧道",
		"body_text": "为让蒸汽干线穿越{settlement_name}背后山岭，铁路局采取东西对向掘进修筑穿山隧道。然而山体富含磁铁矿脉，罗盘与传统水准仪均出现偏差，双方掘进半年后已无法确认轴线是否对齐。总包工头主张凭经验继续猛掘，工程师则要求从山脊开凿通风竖井或停工重聘外埠测绘专家复核。",
		"image_key": "map.construction",
		"ai_visual_prompt": "Two tunnel headings driven from opposite sides of a mountain, a signal lamp over a water basin, a knotted measuring rope and a spirit level on a sleeper",
		"tags": ["rail", "labor"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 780,
		"min_era_index": 6,
		"max_era_index": 8,
		"required_technologies": ["tech.rail_logistics"],
		"conditions": [
			{"op": Op.TERRAIN_IN, "int_list": [
				TerrainTypeScript.TERRAIN.HILL, TerrainTypeScript.TERRAIN.MOUNTAIN]},
			{"op": Op.POPULATION_GTE, "int_value": 12},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.TERRAIN_IN, "int_list": [
					TerrainTypeScript.TERRAIN.MOUNTAIN]},
				"add_weight": 20,
				"reason": "山越厚，越得两头挖",
			},
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 20},
				"add_weight": 20,
				"reason": "人手够，两班才倒得过来",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
				"add_weight": 15,
				"multiplier_q16": MUL_110,
				"reason": "料场就设在洞口",
			},
		],
		"options": [
			Shared.option(
				"trust_the_rope", "沿旧线继续对掘，抢通隧道",
				"险中贯通",
				"东西掌子面虽略有错位，经紧急扩凿后终获贯通，采掘与干线运力皆得提振。但仓促修整耗去大量工料，拖累本地制造产出。",
				[
					Shared.manufacturing(-15, 540),
					Shared.extraction(12, 540),
					Shared.trade_capacity(6, 540),
				]),
			Shared.option(
				"sink_a_shaft", "西头停掘，自山脊开凿竖井",
				"竖井校线",
				"地方摊筹资金开凿通风竖井，精准校准了隧道轴线并积累了地质测绘经验。但竖井施工消耗大批工具，短期压低了采掘产出。",
				[
					Shared.cash_in(5, 360),
					Shared.tools(15, 540),
					Shared.extraction(-10, 540),
					Shared.knowledge(10, 540),
				]),
			Shared.option(
				"call_a_surveyor", "停工半月，延请外埠测绘专家",
				"外聘复测",
				"外埠测绘团队重新标定轴线并引入新式蒸汽机械理念。但全线停工延误了商货预期，依赖外援亦令本地工程学界颜面受挫。",
				[
					Shared.knowledge(-10, 540),
					Shared.bias(Ids.TAG_MARKET, 1.15, 360),
					Shared.research_signal("breakthrough.steam_power", "蒸汽动力"),
				]),
		],
	}))

	# ═══ 货场 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_RAIL_FREIGHT),
		"title": "{settlement_name}·货场管辖权",
		"body_text": "{settlement_name}的铁路货场爆发激烈的装卸权之争。铁路局指责传统脚行工会效率低下、蓄意滞压车皮，要求将货场收归路局直营并启用机械装卸；脚行工会则联合站外苦力坚决抵制，宣称失去按车包干的生计将令数十户家庭陷入绝境。夹在中间的旧城商会催促当局速作裁断，免得大宗铁料与商货继续积压。",
		"image_key": "country.economy",
		"ai_visual_prompt": "A rail freight yard walled with sleepers, porters unloading iron ingots, a railway notice pasted on the sleeper wall, a foreman chalking car numbers",
		"tags": ["rail", "market", "labor", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 6,
		"max_era_index": 8,
		"required_technologies": ["tech.rail_logistics"],
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.02},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.05},
				"add_weight": 0,
				"multiplier_q16": MUL_120,
				"reason": "商货多，货场就是咽喉",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 6},
				"add_weight": 20,
				"reason": "仓房连着货场，谁都想插一手",
			},
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "wrought_iron", "float_value": 1.15},
				"add_weight": 15,
				"reason": "铁贵，压车就是压钱",
			},
		],
		"options": [
			Shared.option(
				"give_it_to_the_railway", "货场收归铁路局，实行直营",
				"路局直营",
				"铁路局接管装卸并统一征收站台作业费，车皮周转与制造供给大为提速。大批被裁汰的脚行苦力集结抗议，劳工矛盾随之升温。",
				[
					Shared.manufacturing(12, 540),
					Shared.cash_in(3, 360),
					Shared.bias(Ids.TAG_LABOR, 1.20, 540),
				]),
			Shared.option(
				"give_it_to_the_porters", "维持脚行包干，安抚底层劳工",
				"脚行包干",
				"脚行保住了按车包干的特权，劳工骚动随之平息。但低效装卸导致车皮严重压站，制造原料断档且本地生活物资周转趋紧。",
				[
					Shared.manufacturing(-12, 540),
					Shared.staple(15, 540),
					Shared.bias(Ids.TAG_LABOR, 0.85, 540),
				]),
			Shared.option(
				"split_the_yard", "划界分治，路局与脚行各管半场",
				"双轨分管",
				"货场中线筑墙分治，路局紧急调拨锻铁补充站务，整体贸易运力略有改善。但两套过磅与调度并行，大幅推高了工具损耗。",
				[
					Shared.tools(18, 540),
					Shared.stock("wrought_iron", 12),
					Shared.trade_capacity(8, 540),
				]),
		],
	}))
