class_name NarrativeEventCatalogSea
extends RefCounted

## 远航包：era 4–6 的七条孤立事件，全部长在沿海格上。
##
##   海图 · 季风 · 海盗 · 港口特许 · 沉船 · 船坞 · 引航
##
## 七条各自收束，不写标记、不排下一条；脉冲入口只有一个，靠建筑数、职业构成、
## 盐价与最不满那群人的满意度浮动权重。代价货币刻意错开：国库现钱、本地产出、
## 出生率、主食开销、工具开销、民怨权重——同一条事件的三个选项绝不同账。
## 器物一律用羊皮海图、铅锤、缆绳、沥青、铜罗盘、香料；这个时代的船还要等风。

const Ids = preload("res://scripts/narrative/narrative_event_ids.gd")
const Shared = preload("res://scripts/narrative/narrative_event_shared.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")

const PACK_ID := &"sea"
const PREFIX := "evt.sea."

const CAST := [
	"港务官署", "海商行会", "水手行帮", "船坞工匠", "远洋商队",
	"羊皮海图", "铜罗盘", "引水水道", "港税特许", "防务水师",
]

const MUL_110 := 72090
const MUL_115 := 75366
const MUL_120 := 78643


static func meta() -> Dictionary:
	return {
		"id": PACK_ID,
		"title": "远航",
		"theme": "一张海图领出的航路、港税与船坞",
		"era_band": "4-6",
		"prefix": PREFIX,
		"scale": "7 条中观/微观孤立",
		"cast": CAST,
		"node_ids": [
			String(Ids.EVT_SEA_CHART),
			String(Ids.EVT_SEA_MONSOON),
			String(Ids.EVT_SEA_PIRATE),
			String(Ids.EVT_SEA_CHARTER),
			String(Ids.EVT_SEA_WRECK),
			String(Ids.EVT_SEA_DRYDOCK),
			String(Ids.EVT_SEA_PILOT),
		],
	}


static func append(catalog) -> void:
	if catalog == null:
		return
	var Op = NarrativeConditionScript.Op
	var Ch = NarrativeEventDefinitionScript.TriggerChannel

	# ═══ 海图 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_SEA_CHART),
		"title": "{settlement_name}·海图",
		"body_text": "一支外邦船队在{settlement_name}口外抛锚，船主向港务官署呈上一卷羊皮海图，索价高昂却声称标注了绕行暗礁的新辟引水水道。海商行会核验后认为，若依图通航可大幅缩短远洋周期，力主动用公帑购入。然而水手行帮与老练领航员校对铜罗盘方位后提出质疑，指该图墨迹虽旧、羊皮却新，绘图者未必亲历此间水文，盲目启用恐致商船触礁倾覆。",
		"image_key": "map.expedition",
		"ai_visual_prompt": "A foreign chart unrolled on a stone quay, a sounding lead on each corner, sailors and a shipwright leaning over it, a chart corner lifting in the wind",
		"tags": ["sea", "market"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 4,
		"max_era_index": 6,
		"required_technologies": ["tech.oceanic_navigation"],
		"conditions": [
			{"op": Op.IS_COASTAL, "bool_value": true},
			{"op": Op.POPULATION_GTE, "int_value": 12},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
				"add_weight": 20,
				"reason": "码头上还有仓房",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.04},
				"add_weight": 0,
				"multiplier_q16": MUL_120,
				"reason": "商号在等这条水路",
			},
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "salt", "float_value": 1.15},
				"add_weight": 10,
				"reason": "盐贵，跑一趟值",
			},
		],
		"options": [
			Shared.option(
				"buy_the_chart", "动用公帑购入海图",
				"新航路入档",
				"港务官署购得羊皮海图并悬于公库供各船参阅。首批商船依图绕开礁区，航程较往年显著缩短，本地航海图籍也随之充实。",
				[
					Shared.cash_out(4, 540, "国库拨付本地人数最多的{primary_profession}，占国库现金 4%（图钱从库里出）"),
					Shared.trade_capacity(10, 720),
					Shared.knowledge(10, 540),
				]),
			Shared.option(
				"copy_it_first", "摹录海图，派轻舟勘验",
				"实测校正水文",
				"港务官署抽调船坞工匠与水手趁平潮试航测深，修正了图上数处礁位偏差。虽短暂耽误港口工坊作业，却换来一份可靠的水文图志。",
				[
					Shared.manufacturing(-10, 540),
					Shared.knowledge(15, 720),
					Shared.trade_capacity(6, 540),
				]),
			Shared.option(
				"send_it_back", "驳回所请，仍走旧航道",
				"墨守旧航线",
				"外邦船队被拒后起锚北去，本港商船继续沿旧道绕行。遇逆风时补给船期频频延误，城中主食周转趋紧，海商行会对此颇有微词。",
				[
					Shared.staple(12, 540),
					Shared.bias(Ids.TAG_UNREST, 1.20, 720),
				]),
		],
	}))

	# ═══ 季风 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_SEA_MONSOON),
		"title": "{settlement_name}·季风",
		"body_text": "本季信风迟迟未至，{settlement_name}的远洋商队被迫滞留港内，满载香料与货品的船舱已显返潮迹象。海商行会不断向港务官署施压，警告若继续空耗停泊时日，整季货款都将血本无归，要求一见风向微动便即刻起锚。水手行帮则坚决反对冒险离港，直言风势未稳便驶入外洋极易陷入无风死水或遭遇突袭逆风，令整支船队倾覆于深海。",
		"image_key": "hydrology.current",
		"ai_visual_prompt": "Masts with furled sails along a harbour wall, a lookout on a watchtower staring at a limp flag, a woman stitching a sail on the quay",
		"tags": ["sea", "market"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 720,
		"min_era_index": 4,
		"max_era_index": 6,
		"required_technologies": ["tech.oceanic_navigation"],
		"conditions": [
			{"op": Op.IS_COASTAL, "bool_value": true},
			{"op": Op.POPULATION_GTE, "int_value": 12},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.05},
				"add_weight": 20,
				"reason": "货压在仓里等风",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 5},
				"add_weight": 0,
				"multiplier_q16": MUL_115,
				"reason": "船大了，一天的停泊钱也多",
			},
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "salt", "float_value": 1.10},
				"add_weight": 0,
				"multiplier_q16": MUL_110,
				"reason": "盐价抬着，早到一天多赚一天",
			},
		],
		"options": [
			Shared.option(
				"wait_for_the_wind", "严令候风，稳妥出航",
				"信风既稳始启航",
				"港务官署顶住商界压力暂缓放行，港口索具与腌货作坊随之停歇半月。待风势稳固后船队平安往返，官署亦将此番风期变化载入海志。",
				[
					Shared.manufacturing(-10, 540),
					Shared.trade_capacity(10, 720),
					Shared.knowledge(8, 360),
				]),
			Shared.gamble(
				"catch_the_first_breath", "抢乘初风，全队拔锚",
				Shared.branch(39322, "抢得先机满载归", # 60%
					"船队趁初风抢先出港，在外海恰逢顺风相送，较常年提前半月抵达。整批货品毫发无损，不仅充实了港口工坊，亦缓解了城中主食负担。",
					[
						Shared.trade_capacity(15, 720),
						Shared.manufacturing(10, 540),
						Shared.staple(-10, 720),
					]),
				Shared.branch(26214, "逆风折戟损兵折船", # 40%
					"信风行至半途骤歇，返航时又遭逆风阻隔，数艘商船漂失外洋。水手折损令港城生计承压，遇难家属与行帮对官署的冒险决断怨声载道。",
					[
						Shared.population_rate(-6),
						Shared.staple(12, 540),
						Shared.bias(Ids.TAG_UNREST, 1.20, 540),
					])),
			Shared.option(
				"split_the_fleet", "拨款雇轻舟先行周转",
				"轻舟探路大船殿后",
				"国库垫资雇佣浅吃水轻舟满载急货先行，主力大船留港候风。轻舟如期回笼资金，既保住了商队信誉，也带动了本地作坊的备货运转。",
				[
					Shared.cash_out(4, 540, "国库拨付本地人数最多的{primary_profession}，占国库现金 4%（雇小船的钱先垫）"),
					Shared.trade_capacity(8, 540),
					Shared.manufacturing(8, 540),
				]),
		],
	}))

	# ═══ 海盗 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_SEA_PIRATE),
		"title": "{settlement_name}·海盗",
		"body_text": "数艘武装划桨快船盘踞在{settlement_name}口外礁区，公然截断引水水道，要求过往商船一律按货抽成方可放行。海商行会盘算后认为暂交买路钱可保本季航运不断，却也忧虑此例一开将招致无休止的勒索。水手行帮与防务水师主战派力请趁落潮突袭礁盘、一举清剿；港务官署中则有人指出贼首熟谙近海暗流，若能招安编入引航，或可化患为用。",
		"image_key": "country.military",
		"ai_visual_prompt": "Three rowing boats waiting outside a reef, a harbour crowd arguing on the quay, a woman watching the tide, a white line of surf at dusk",
		"tags": ["sea", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 720,
		"min_era_index": 4,
		"max_era_index": 6,
		"required_technologies": ["tech.oceanic_navigation"],
		"conditions": [
			{"op": Op.IS_COASTAL, "bool_value": true},
			{"op": Op.POPULATION_GTE, "int_value": 14},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.COHORT_SATISFACTION_LTE, "float_value": 0.45},
				"add_weight": 25,
				"reason": "吃不上饭的人上了船",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
				"add_weight": 0,
				"multiplier_q16": MUL_115,
				"reason": "仓里堆着货，值得来一趟",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 6},
				"add_weight": 10,
				"reason": "官船有了炮位",
			},
		],
		"options": [
			Shared.option(
				"pay_the_toll", "摊派买路钱暂保通航",
				"破财买路患根未除",
				"地方按户摊派凑齐财物送往口外，海盗暂退让出水道，港口工坊得以维持运转。然此举无异于养虎为患，来年贼众加码勒索，港城怨声渐起。",
				[
					Shared.cash_in(5, 540, "向本地人数最多的{primary_profession}征收其现金的 5%（按船摊买路钱）"),
					Shared.manufacturing(8, 540),
					Shared.bias(Ids.TAG_UNREST, 1.15, 720),
				]),
			Shared.gamble(
				"clear_them_out", "趁落潮出动水师清剿",
				Shared.branch(36045, "礁盘大捷航道肃清", # 55%
					"防务水师趁退潮合围礁盘，搁浅的贼船无处遁形。官兵悉数俘获贼众并追回大批劫货，港城补给宽裕，民心大振。",
					[
						Shared.manufacturing(12, 540),
						Shared.staple(-12, 540),
						Shared.bias(Ids.TAG_UNREST, 0.90, 720),
					]),
				Shared.branch(29491, "清剿受挫商船被劫", # 45%
					"贼众提前察觉潮信退入深水，双方苦战半日未能建功。水师与水手伤亡惨重，两艘货船遭劫，港口制造受挫且城中动荡加剧。",
					[
						Shared.population_rate(-6),
						Shared.manufacturing(-15, 720),
						Shared.bias(Ids.TAG_UNREST, 1.20, 540),
					])),
			Shared.gamble(
				"offer_them_work", "招安贼众编入引航",
				Shared.branch(42598, "化盗为吏暗流尽掌", # 65%
					"贼首受抚后交出近海暗流秘图，率部编入港口引航与缆绳工役。商船进出效率大增，唯安置这批人手令本地口粮供给略显吃紧。",
					[
						Shared.knowledge(10, 540),
						Shared.trade_capacity(10, 720),
						Shared.staple(10, 540),
					]),
				Shared.branch(22938, "招安反噬携图潜逃", # 35%
					"招安流于形式，半年后这批人摸清港防与水道后携船潜逃。外洋商路再度受阻，城中主食补给承压，舆论对官署失察大为不满。",
					[
						Shared.staple(18, 540),
						Shared.bias(Ids.TAG_UNREST, 1.30, 720),
					])),
		],
	}))

	# ═══ 港口特许 ═════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_SEA_CHARTER),
		"title": "{settlement_name}·港口特许",
		"body_text": "{settlement_name}的港口关税向由港务官署逐船核收，账目繁琐且耗费人力。海商行会中的大商号近日联名递呈，愿以预缴半数现款为条件，承包未来数年的港税特许权，声称商号代征可令国库立得实惠。水手行帮与中小船户则强烈反对，指商号一旦垄断税权必将借机加征停泊费、排挤竞争对手，要求官署维持直征或将包税权拆散制衡。",
		"image_key": "country.economy",
		"ai_visual_prompt": "A merchant accountant with an abacus on a harbour stair, a woman throwing down a coil of rope, a crowd of boatmen listening",
		"tags": ["sea", "market", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 4,
		"max_era_index": 6,
		"required_technologies": ["tech.oceanic_navigation"],
		"conditions": [
			{"op": Op.IS_COASTAL, "bool_value": true},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.03},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.06},
				"add_weight": 25,
				"reason": "商号凑得出这笔现钱",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
				"add_weight": 0,
				"multiplier_q16": MUL_115,
				"reason": "码头上的仓房多了，税也厚",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 5},
				"add_weight": 10,
				"reason": "官面上开始算三年的账",
			},
		],
		"options": [
			Shared.option(
				"farm_the_tax", "批授大商号独包港税",
				"特许包税民怨渐生",
				"包税契约签立当日，巨额现款即解入国库。但商号接管码头后旋即提高停泊苛捐，挑夫与船户罢工抗议，本地主食周转亦受波及。",
				[
					Shared.cash_in(5, 540),
					Shared.staple(10, 540),
					Shared.bias(Ids.TAG_UNREST, 1.15, 720),
				]),
			Shared.option(
				"collect_it_ourselves", "驳回包税，官署直征",
				"官署直征商路稳健",
				"国库拨款增派税吏驻港直征，虽前期行政开支不菲、核验略慢，但税则公允透明，中小商船络绎不绝，贸易运力与工坊产出同步攀升。",
				[
					Shared.cash_out(3, 540, "国库拨付本地人数最多的{primary_profession}，占国库现金 3%（两个税吏的工食）"),
					Shared.trade_capacity(8, 720),
					Shared.manufacturing(8, 540),
				]),
			Shared.option(
				"split_among_three", "拆分码头，分包三家",
				"分段竞包互相掣肘",
				"港务官署将码头分段发包给三家中小商号以防垄断，既收得部分包费又平息了民怨。然而各段边界屡起争执，装卸效率下滑拖累了港口制造。",
				[
					Shared.manufacturing(-8, 360),
					Shared.cash_in(3, 540),
					Shared.bias(Ids.TAG_UNREST, 0.90, 540),
				]),
		],
	}))

	# ═══ 沉船 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_SEA_WRECK),
		"title": "{settlement_name}·沉船",
		"body_text": "浓雾之夜，一艘隶属远洋商队的三桅大船在{settlement_name}口外触礁倾覆，破晓退潮时仅剩半截桅杆露出水面，海面漂满木箱与香料。幸存船主急报底舱尚有水手受困，船坞工匠已备好斧锯请求立刻破舱救人；海商行会则催促趁涨潮前优先抢捞浸水货箱，以免珍贵物资化为乌有。港务官署亦有人主张先封锁海滩，待官船到场清点登记再行处置。",
		"image_key": "hydrology.water",
		"ai_visual_prompt": "A three-masted ship half sunk on a reef at dawn, crates and rope floating in the surf, a shipmaster kneeling on the beach, a carpenter with an axe",
		"tags": ["sea", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 720,
		"min_era_index": 4,
		"max_era_index": 6,
		"required_technologies": ["tech.oceanic_navigation"],
		"conditions": [
			{"op": Op.IS_COASTAL, "bool_value": true},
			{"op": Op.POPULATION_GTE, "int_value": 10},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "fisher", "float_value": 0.06},
				"add_weight": 20,
				"reason": "水上的人多，出船快",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
				"add_weight": 0,
				"multiplier_q16": MUL_115,
				"reason": "滩上有仓房，捞上来有地方放",
			},
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "salt", "float_value": 1.10},
				"add_weight": 0,
				"multiplier_q16": MUL_110,
				"reason": "盐贵，一箱货值得争",
			},
		],
		"options": [
			Shared.option(
				"save_them_first", "人命为先，破舱救援",
				"竭力搜救民心归附",
				"船坞工匠冒险破开底舱救出多名幸存水手，国库随即为遇难者家庭发放抚恤。此番义举赢得港城上下交口称赞，沿海秩序更趋稳固。",
				[
					Shared.cash_out(3, 540, "国库拨付本地人数最多的{primary_profession}，占国库现金 3%（抚恤按户发）"),
					Shared.birth(8, 540),
					Shared.bias(Ids.TAG_UNREST, 0.90, 540),
				]),
			Shared.option(
				"salvage_the_cargo", "抢捞货箱，保全物资",
				"重货轻人非议四起",
				"大批货箱在涨潮前抢运上岸，充实了城中补给并减轻主食开销。然而底舱受困船员错失生机，水手行帮对官署冷酷逐利之举深感愤慨。",
				[
					Shared.population_rate(-5),
					Shared.staple(-10, 540),
					Shared.bias(Ids.TAG_UNREST, 1.10, 540),
				]),
			Shared.option(
				"close_the_beach", "封锁海滩，候官查验",
				"循章封滩错失良机",
				"港务官署拉绳封滩禁止闲人靠近，滩涂作坊被迫停工数日。待勘验官船抵达时半数漂货已被海浪卷走，仅留下一份详尽的失事档案。",
				[
					Shared.manufacturing(-10, 540),
					Shared.knowledge(8, 360),
					Shared.bias(Ids.TAG_UNREST, 1.05, 540),
				]),
		],
	}))

	# ═══ 船坞 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_SEA_DRYDOCK),
		"title": "{settlement_name}·船坞",
		"body_text": "{settlement_name}迄今缺乏正规船坞，远洋商队每次检修船底都只能趁大潮将船身拖上泥滩，不仅效率低下，且海水侵蚀令龙骨损耗极快。船坞工匠勘测后呈报，若沿滩修筑石砌干船坞，日后连外邦大船亦可承修牟利，唯上游采石与工费开支浩大。海商行会则质疑耗资堪比新造商船，主张改挖简易土坡绞盘，或干脆花钱租借外邦现成船坞。",
		"image_key": "economy.building.shipyard",
		"ai_visual_prompt": "A tidal beach with a ship careened on its side, men measuring a stone dock line, a coil of rotten rope at their feet, an old keel print in the sand",
		"tags": ["sea", "labor"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 900,
		"min_era_index": 5,
		"max_era_index": 6,
		"required_technologies": ["tech.oceanic_navigation", "tech.coastal_shipyards"],
		"conditions": [
			{"op": Op.IS_COASTAL, "bool_value": true},
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 5},
				"add_weight": 25,
				"reason": "岸上已经有一排作坊",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "artisan", "float_value": 0.10},
				"add_weight": 0,
				"multiplier_q16": MUL_120,
				"reason": "石匠木匠都凑得齐",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 6},
				"add_weight": 0,
				"multiplier_q16": MUL_110,
				"reason": "再等下去，船先烂了",
			},
		],
		"options": [
			Shared.option(
				"build_the_stone_dock", "拨款兴建石砌船坞",
				"石坞落成航运大兴",
				"国库拨出专款从上游采运石料，历时一秋终成坚固石坞。本港修船与造船产能跃升，次年便有外邦商船慕名入坞检修，港口运力大增。",
				[
					Shared.cash_out(5, 720),
					Shared.manufacturing(15, 720),
					Shared.trade_capacity(10, 720),
				]),
			Shared.option(
				"dig_an_earth_slip", "开挖土坡，架设绞盘",
				"简陋土坡难承重船",
				"官署就地挖坡并改制旧桅杆为绞盘，虽勉强疏通了中小船只周转，但大型商船仍须分段拆修，反倒牵扯工匠精力、推高营造负担。",
				[
					Shared.manufacturing(-10, 540),
					Shared.build_cost(8, 540),
					Shared.trade_capacity(6, 540),
				]),
			Shared.option(
				"rent_a_foreign_dock", "出资租借外邦船坞",
				"借坞修船耗费器械",
				"商船轮番驶往邻邦船坞检修，虽维持了航运周转并借机窥得外邦造船工艺，但往返损耗与外埠修缮令本地工具器械消耗显著上升。",
				[
					Shared.tools(12, 540),
					Shared.knowledge(8, 360),
					Shared.trade_capacity(6, 360),
				]),
		],
	}))

	# ═══ 引航 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_SEA_PILOT),
		"title": "{settlement_name}·引航",
		"body_text": "{settlement_name}口外浅滩密布，历来依赖资深领航员凭铜罗盘与潮信引导商船穿越引水水道。如今老一辈引航人年迈体衰，接班体系青黄不接，港务官署面临引航断档之危。海商行会急于维持航运效率，提议高薪礼聘外邦专业引水员应急；水手行帮则担忧外人登船会泄露本港货底与水道机密，主张由国库资助本土学徒跟船历练，或干脆在浅滩全面设立固定标桩。",
		"image_key": "hydrology.current",
		"ai_visual_prompt": "An old pilot showing a brass compass to a young apprentice on harbour steps, a shipwright and a boat owner watching",
		"tags": ["sea", "labor"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 4,
		"max_era_index": 6,
		"required_technologies": ["tech.oceanic_navigation"],
		"conditions": [
			{"op": Op.IS_COASTAL, "bool_value": true},
			{"op": Op.POPULATION_GTE, "int_value": 12},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
				"add_weight": 15,
				"reason": "码头上有活，船来得勤",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.05},
				"add_weight": 0,
				"multiplier_q16": MUL_115,
				"reason": "商船多，引水的价也高",
			},
			{
				"condition": {"op": Op.COHORT_SATISFACTION_LTE, "float_value": 0.40},
				"add_weight": 10,
				"reason": "船户吃紧，等不起半个月的绕路",
			},
		],
		"options": [
			Shared.option(
				"teach_the_apprentice", "国库资助本土授徒",
				"水文绝学薪火相传",
				"港务官署拨发津贴设立引航学徒制，资深领航员倾囊相授并将数十年浅滩水文绘成官图。虽见效较缓，却为本港筑牢了自主航运根基。",
				[
					Shared.cash_out(3, 540, "国库拨付本地人数最多的{primary_profession}，占国库现金 3%（徒弟的口粮从库里出）"),
					Shared.knowledge(12, 720),
					Shared.trade_capacity(6, 540),
				]),
			Shared.option(
				"hire_the_foreigner", "高薪礼聘外邦引水员",
				"外籍引航提速通商",
				"外邦引水员驻港后商船进出大为提速，连带港口作坊周转兴旺。唯其随行人员与往来船队日众，令港城主食供给压力有所加重。",
				[
					Shared.staple(10, 540),
					Shared.trade_capacity(10, 720),
					Shared.manufacturing(8, 540),
				]),
			Shared.option(
				"set_the_marker_posts", "浅滩立桩，标定水道",
				"白灰标桩指引通航",
				"官署抽调船坞人手在浅滩两侧竖起刷白标桩，短期内拖慢了港口制造。然航道轮廓自此一目了然，即便外邦商船亦可依桩自主进港。",
				[
					Shared.manufacturing(-8, 360),
					Shared.knowledge(10, 720),
					Shared.trade_capacity(8, 720),
				]),
		],
	}))
