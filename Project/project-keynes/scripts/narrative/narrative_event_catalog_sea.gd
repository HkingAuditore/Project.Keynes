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
	"闻九", "盛德昌", "霍三娘", "祁阿满", "阮六",
	"白螺口", "黑鲨礁", "远字号", "铜罗盘", "铅锤",
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
		"body_text": "外邦的船在口外下了锚，船主搭小艇进来，怀里抱着一卷羊皮，说要换三袋盐。闻九把图摊在码头的石板上，拿铅锤压住四个角。图上黑鲨礁画得比本地人记的靠西半里，那条水道窄得只够一条船过。盛德昌蹲下去，手指顺着线走，说照这么走能省两天。霍三娘从缆桩那边过来，用指甲刮了刮图边，说羊皮是新的，墨是旧的，画的人没走过这段水。祁阿满没说话，把铜罗盘翻过来看底下的刻痕。潮水退了一尺，图角翘起来，闻九伸手按住，问要不要抄一份。",
		"image_key": "map.expedition",
		"ai_visual_prompt": "A foreign chart unrolled on a stone quay, a sounding lead on each corner, sailors and a shipwright leaning over it, a chart corner lifting in the wind",
		"tags": ["sea", "market"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 4,
		"max_era_index": 6,
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
				"buy_the_chart", "买下这张图",
				"图钉在仓房的墙上",
				"羊皮图用四枚铜钉钉在仓房的墙上，谁都能看。头一船照着走，绕开了黑鲨礁，比往年早到四天。",
				[
					Shared.cash_out(1.5, 540, "国库拨付本地人数最多的{primary_profession}，占国库现金 1.5%（图钱从库里出）"),
					Shared.trade_capacity(4, 720),
					Shared.knowledge(3, 540),
				]),
			Shared.option(
				"copy_it_first", "抄一份，先拿小船试",
				"小船去试那半里",
				"闻九带了两个人，趁平潮划进去，铅锤一路往下放。水深比图上多两尺，礁石的位置差着一桨。抄本拿回来改了七处，边上全是墨点，码头的活也停了几日。",
				[
					Shared.manufacturing(-3, 540),
					Shared.knowledge(5, 720),
					Shared.trade_capacity(2, 540),
				]),
			Shared.option(
				"send_it_back", "退回去，还走老路",
				"船还是走老路",
				"图退回去了，外邦船第二天起锚往北。老路多绕两天，碰上逆风还要多，运粮的船一趟少一趟，米价跟着往上走。盛德昌把这笔账记在账本背面，写成一行小字。",
				[
					Shared.staple(4, 540),
					Shared.bias(Ids.TAG_UNREST, 1.20, 720),
				]),
		],
	}))

	# ═══ 季风 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_SEA_MONSOON),
		"title": "{settlement_name}·季风",
		"body_text": "季风该到的时候没到。白螺口的桅杆一根根立着，帆卷在桁上，缆绳绷起来又松下去。祁阿满每天清早爬上望楼看旗，旗角贴着杆子，一动不动。盛德昌的香料压在仓里，麻袋外层返了潮，他说再等下去要发霉。闻九说风没到就出海，船会横在洋面上，桨摇不回来。霍三娘蹲在码头上补帆，针脚一针一针走过去，眼睛不抬。第九天早上旗动了半寸，码头上的人全站起来，祁阿满把手按在栏杆上。",
		"image_key": "hydrology.current",
		"ai_visual_prompt": "Masts with furled sails along a harbour wall, a lookout on a watchtower staring at a limp flag, a woman stitching a sail on the quay",
		"tags": ["sea", "market"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 720,
		"min_era_index": 4,
		"max_era_index": 6,
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
				"wait_for_the_wind", "等风走稳再出海",
				"船队在口内又等了十一天",
				"风是渐渐实的，先是旗角抖，后来整面旗都响。索具铺和腌鱼棚歇了半个月，霍三娘的帆补到第三张。这一趟出海走了二十天，一条船没丢，闻九把每年的风期记成一册。",
				[
					Shared.manufacturing(-3, 540),
					Shared.trade_capacity(4, 720),
					Shared.knowledge(2, 360),
				]),
			Shared.gamble(
				"catch_the_first_breath", "抢着头一阵风走",
				Shared.branch(39322, "船队赶到风前头", # 60%
					"三条船趁头一阵风出去，海面还平。到了外海才起浪，船贴着浪跑，比往年早到半个月。舱里的香料一点没潮。",
					[
						Shared.trade_capacity(6, 720),
						Shared.manufacturing(3, 540),
						Shared.staple(-3, 720),
					]),
				Shared.branch(26214, "有两条船没回来", # 40%
					"风走到半路歇了三天，船停在原地打转。回程遇上逆风，两条船漂到外洋去，只有一条捎了信回来。祁阿满在望楼上站了一夜。",
					[
						Shared.birth(-4, 540),
						Shared.staple(4, 540),
						Shared.bias(Ids.TAG_UNREST, 1.20, 540),
					])),
			Shared.option(
				"split_the_fleet", "大船等，小船先走",
				"小船先出港",
				"四条小船装了轻货先走，大船留在口内。小船回来时货换了钱，钱补了大船等风的亏空。霍三娘给小船的帆都加了双层边。",
				[
					Shared.cash_out(1.5, 540, "国库拨付本地人数最多的{primary_profession}，占国库现金 1.5%（雇小船的钱先垫）"),
					Shared.trade_capacity(3, 540),
					Shared.manufacturing(2, 540),
				]),
		],
	}))

	# ═══ 海盗 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_SEA_PIRATE),
		"title": "{settlement_name}·海盗",
		"body_text": "黑鲨礁那边来了三条划桨船，横在口外，不进也不退。船上的人喊话，说每船一成货，或者一袋盐，交了就让路。盛德昌算过账，一袋盐比一成货便宜，可给了这回想给下回。祁阿满把船帮的人叫到码头上，说凑钱打，水上的人熟水性，礁在哪块心里有数。闻九蹲在缆桩边上，说他听出对面领头的口音，是南边逃过来的，招过来能当引水的。霍三娘抱着胳膊看潮水，说潮一退他们的船就搁在礁上。日头偏西，海面上起了一道白线。",
		"image_key": "country.military",
		"ai_visual_prompt": "Three rowing boats waiting outside a reef, a harbour crowd arguing on the quay, a woman watching the tide, a white line of surf at dusk",
		"tags": ["sea", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 720,
		"min_era_index": 4,
		"max_era_index": 6,
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
				"pay_the_toll", "凑钱交买路钱",
				"陶罐送到划桨船上",
				"钱按船摊，两天凑齐，装在一只陶罐里用小艇送过去。船队出港那天，划桨船让开一条水道。第二年开春他们又来了，这回开口要两成。",
				[
					Shared.cash_in(2.0, 540, "向本地人数最多的{primary_profession}征收其现金的 2%（按船摊买路钱）"),
					Shared.manufacturing(2, 540),
					Shared.bias(Ids.TAG_UNREST, 1.15, 720),
				]),
			Shared.gamble(
				"clear_them_out", "趁潮退动手清剿",
				Shared.branch(36045, "他们的船搁在礁上", # 55%
					"潮退下去，三条划桨船全搁在礁盘上，抬不起桨。船帮的人从礁石后头上去，货夺回来大半，绳子捆了一串人押回码头。",
					[
						Shared.manufacturing(4, 540),
						Shared.staple(-4, 540),
						Shared.bias(Ids.TAG_UNREST, 0.90, 720),
					]),
				Shared.branch(29491, "打了半日，货还是丢了", # 45%
					"对面先看出潮要退，把船拖到深水里。打了半日，船帮伤了人，两条货船被拖走。祁阿满把断了的桨扛回码头，一句话没说。",
					[
						Shared.birth(-4, 540),
						Shared.manufacturing(-5, 720),
						Shared.bias(Ids.TAG_UNREST, 1.20, 540),
					])),
			Shared.gamble(
				"offer_them_work", "招他们来引水",
				Shared.branch(42598, "领头的换了身干衣裳", # 65%
					"领头的换了身干衣裳，站在船头指水道。他知道哪块礁底下有暗流，船进港省了半个潮。剩下几个人分到缆绳和沥青的活，一日两顿在码头上吃。",
					[
						Shared.knowledge(3, 540),
						Shared.trade_capacity(4, 720),
						Shared.staple(3, 540),
					]),
				Shared.branch(22938, "他们把水道摸熟了", # 35%
					"招是招了，人心没留住。半年后他们带着一张画好的水道图走了，走的时候顺走两条小船。盛德昌在账上把这一笔划了。",
					[
						Shared.staple(6, 540),
						Shared.bias(Ids.TAG_UNREST, 1.30, 720),
					])),
		],
	}))

	# ═══ 港口特许 ═════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_SEA_CHARTER),
		"title": "{settlement_name}·港口特许",
		"body_text": "港税一直是官面上派人来收，收多少、怎么收，全看那支笔。盛德昌带着远字号的账房来了三趟，说把三年的港税一次包给他们，先付一半现钱。他算得清楚，一船一船收，比官面上按月抽省事。霍三娘在码头听见这话，把手里的缆绳往地上一摔，说商号的秤比官秤硬。闻九站在跳板上，说包出去以后，小船的停泊钱要涨。祁阿满没表态，只问了一句，出了事谁担。潮水漫上石阶，账房的算盘在袖子里响了一声。",
		"image_key": "country.economy",
		"ai_visual_prompt": "A merchant accountant with an abacus on a harbour stair, a woman throwing down a coil of rope, a crowd of boatmen listening",
		"tags": ["sea", "market", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 4,
		"max_era_index": 6,
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
				"farm_the_tax", "包给远字号",
				"字据立在衙门口",
				"字据立在衙门口，一半现钱当天入库。开春起停泊钱涨了两成，挑夫把担子停在石阶下面，不肯往上走。盛德昌的账房把秤换了新的。",
				[
					Shared.cash_in(2.0, 540),
					Shared.staple(3, 540),
					Shared.bias(Ids.TAG_UNREST, 1.15, 720),
				]),
			Shared.option(
				"collect_it_ourselves", "官面上自己收",
				"两个税吏从邻县调来",
				"两个税吏先学了一个月的规矩，算盘打得比账房慢。钱收得一笔一笔都有账，船户在石阶上等着盖章。年底盘账，比包出去少收三成。",
				[
					Shared.cash_out(1.0, 540, "国库拨付本地人数最多的{primary_profession}，占国库现金 1%（两个税吏的工食）"),
					Shared.trade_capacity(3, 720),
					Shared.manufacturing(2, 540),
				]),
			Shared.option(
				"split_among_three", "拆给三家小号分包",
				"三家各包一段码头",
				"三家小号各包一段码头，界石挪了两回，谁也不服谁。盛德昌把远字号的账房撤回去，仓里的货改走邻港。停泊钱没涨，收得也少。",
				[
					Shared.manufacturing(-2, 360),
					Shared.cash_in(1.0, 540),
					Shared.bias(Ids.TAG_UNREST, 0.90, 540),
				]),
		],
	}))

	# ═══ 沉船 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_SEA_WRECK),
		"title": "{settlement_name}·沉船",
		"body_text": "夜里起雾，一条三桅船在黑鲨礁外面触了礁，天亮前斜着沉下去，桅杆还露在水面上。早潮一退，岸上的人全跑去看，浪里漂着木箱、缆绳和成捆的香料。船主是南边来的，抱着一块船板上了岸，说舱里还有人。阮六拎着斧头站在滩上，说先砸开舱板，能救一个算一个。盛德昌的伙计已经划着小船去捞箱子，说货泡了水就不值钱。霍三娘把人拦在浪线外头，说潮还要涨。船主跪在沙里，抬头看那截桅杆。",
		"image_key": "hydrology.water",
		"ai_visual_prompt": "A three-masted ship half sunk on a reef at dawn, crates and rope floating in the surf, a shipmaster kneeling on the beach, a carpenter with an axe",
		"tags": ["sea", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 720,
		"min_era_index": 4,
		"max_era_index": 6,
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
				"save_them_first", "先砸舱板救人",
				"舱板砸开，拖出三个活的",
				"阮六带人把舱板一块块砸开，拖出三个活的，还有一个是冷的。抚恤的钱从库里出，一家一份，用红纸包着。霍三娘把那块船板拖上岸，晒在滩上。",
				[
					Shared.cash_out(1.0, 540, "国库拨付本地人数最多的{primary_profession}，占国库现金 1%（抚恤按户发）"),
					Shared.birth(2, 540),
					Shared.bias(Ids.TAG_UNREST, 0.90, 540),
				]),
			Shared.option(
				"salvage_the_cargo", "先捞货，人后说",
				"箱子在晒场上摊开",
				"箱子捞上来大半，香料摊在晒场上翻晒，干的装袋，按半价分给各家。舱里的人到第三天才找到两个，都没气了。阮六把斧头插在沙里。",
				[
					Shared.birth(-3, 540),
					Shared.staple(-3, 540),
					Shared.bias(Ids.TAG_UNREST, 1.10, 540),
				]),
			Shared.option(
				"close_the_beach", "封滩，等官船来验",
				"滩上拉了绳",
				"滩上拉了绳，谁也不许下，连捡木头的都被赶回去，滩上的活停了三日。官船第三天到，货清点了一半，另一半被浪卷走。阮六把斧头扛回去，路上没说话。",
				[
					Shared.manufacturing(-3, 540),
					Shared.knowledge(2, 360),
					Shared.bias(Ids.TAG_UNREST, 1.05, 540),
				]),
		],
	}))

	# ═══ 船坞 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_SEA_DRYDOCK),
		"title": "{settlement_name}·船坞",
		"body_text": "白螺口没有坞，船要修就得趁涨潮拖上滩，再等潮水把它浮起来。阮六在滩上量过三回，说修一座石砌的坞，船能横着拖上去，龙骨晾得干。石料要从上游放排下来，工钱得管两百个人的饭。祁阿满说坞修起来，外邦的船也来修，钱能挣回来。霍三娘把一截烂缆绳扔在他脚边，说船底再烂两年，缆绳也不用买了。盛德昌在旁边算，说这笔钱够买两条新船。潮水正退，滩上露出一道旧船底的印子，像一条压扁的鱼。",
		"image_key": "economy.building.shipyard",
		"ai_visual_prompt": "A tidal beach with a ship careened on its side, men measuring a stone dock line, a coil of rotten rope at their feet, an old keel print in the sand",
		"tags": ["sea", "labor"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 900,
		"min_era_index": 5,
		"max_era_index": 6,
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
				"build_the_stone_dock", "修一座石坞",
				"坞墙砌了一个秋天",
				"石料从上游放排下来，坞墙砌了一个秋天。头一条拖上去的是祁阿满自己的船，龙骨上刮下来的东西装了半车。外邦的船第二年就来问价。",
				[
					Shared.cash_out(2.0, 720),
					Shared.manufacturing(5, 720),
					Shared.trade_capacity(4, 720),
				]),
			Shared.option(
				"dig_an_earth_slip", "挖土坡，加绞盘",
				"坡是人一锹一锹挖的",
				"坡挖了一个月，绞盘用旧桅杆改的，转起来吱吱响。当年修了七条船，大船还是拖不上来，得分两截修。石匠的活转到别处去了。",
				[
					Shared.manufacturing(-3, 540),
					Shared.build_cost(3, 540),
					Shared.trade_capacity(2, 540),
				]),
			Shared.option(
				"rent_a_foreign_dock", "租外邦人的坞",
				"船开到对面的坞里去",
				"船开去对面的坞里修，一来一回半个月。修船的钱按外邦人的价算，一条船比往年多花了一截。霍三娘在岸上等船，把缆绳接了又接。",
				[
					Shared.tools(4, 540),
					Shared.knowledge(2, 360),
					Shared.trade_capacity(2, 360),
				]),
		],
	}))

	# ═══ 引航 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_SEA_PILOT),
		"title": "{settlement_name}·引航",
		"body_text": "闻九在这条水道上引了三十年船，潮怎么涨、礁在哪块，他闭着眼也走得。可他今年手抖，端碗要两只手。码头上商量的是谁来接，他自己带徒弟，还是请外邦的引水员。祁阿满说外邦人认水道，也认钱，钱给够就带你走。霍三娘说外邦人上船，船上的货就要点数。闻九把铜罗盘放在石阶上，让徒弟照着走一遍，徒弟把针看反了。老引航员没骂人，把罗盘翻过来，指给他看底下的刻痕。",
		"image_key": "hydrology.current",
		"ai_visual_prompt": "An old pilot showing a brass compass to a young apprentice on harbour steps, a shipwright and a boat owner watching",
		"tags": ["sea", "labor"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 4,
		"max_era_index": 6,
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
				"teach_the_apprentice", "让闻九带徒弟",
				"徒弟跟船跟了两年",
				"徒弟头一年只看不问，第二年才上手。闻九把三十年记的浅滩画在一张纸上，画完卷起来，压在铜罗盘底下。",
				[
					Shared.cash_out(1.0, 540, "国库拨付本地人数最多的{primary_profession}，占国库现金 1%（徒弟的口粮从库里出）"),
					Shared.knowledge(4, 720),
					Shared.trade_capacity(2, 540),
				]),
			Shared.option(
				"hire_the_foreigner", "请外邦引水员",
				"外邦人住进码头的仓房",
				"外邦人住进码头边的仓房，一日三餐要有肉。船进港快了半天，停泊的船多了，肉和粮也跟着贵。霍三娘数过他的箱子，一共四只。",
				[
					Shared.staple(3, 540),
					Shared.trade_capacity(4, 720),
					Shared.manufacturing(2, 540),
				]),
			Shared.option(
				"set_the_marker_posts", "立标桩，谁都不请",
				"桩头刷了白灰",
				"标桩立在浅滩两侧，桩头刷了白灰。抽了二十个人去立桩，坞里的活停了半个月。入冬前两条外邦船照着标桩自己进来了。",
				[
					Shared.manufacturing(-2, 360),
					Shared.knowledge(3, 720),
					Shared.trade_capacity(3, 720),
				]),
		],
	}))
