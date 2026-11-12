class_name NarrativeEventCatalogLand
extends RefCounted

## 地块包：一块地的前途，和地上的人（4 条，全部孤立）。
##
##   淤了的港（沿海+河，era 2–8）· 老矿（有矿产，era 2–8）
##   林边（森林，era 1–8）· 废祠（era 1–9；也会被宫廷「两方印·发兵」排程）
##
## 连线：废祠的两个结果（旧祠重立 / 墙还塌着）会改写教门「抬神出城」的权重；
## 老矿塌过一回、封过坑，都会在下一回被自己的标记挡住或抬高。
##
## 数值：地块事件的代价落在部门产出与市场实物上；没有"负向全国贸易容量"这种键，
## 所以港口衰败写成本地制造 `.cut` + 主食开销上升，不写全国贸易负数。

const Ids = preload("res://scripts/narrative/narrative_event_ids.gd")
const Shared = preload("res://scripts/narrative/narrative_event_shared.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")
const VegetationTypeScript = preload("res://scripts/geography/vegetation_type.gd")

const PACK_ID := &"land"
const PREFIX := "evt.land."

const CAST := [
	"温有庆", "沙尾港", "沙尾河", "鲍阿四", "邵九", "黑石岭", "冯四", "石满仓", "白榆林", "罗二",
	"屈阿公", "杜衡", "三圣祠", "温四娘", "木桩", "条石",
]

const MUL_110 := 72090
const MUL_115 := 75366
const MUL_120 := 78643
const MUL_125 := 81920
const MUL_130 := 85197
const MUL_135 := 88474
const MUL_140 := 91750


static func meta() -> Dictionary:
	return {
		"id": PACK_ID,
		"title": "地块",
		"theme": "港、矿、林、废祠",
		"era_band": "1-9",
		"prefix": PREFIX,
		"scale": "2 中观 + 2 微观，全部孤立",
		"cast": CAST,
		"node_ids": [
			String(Ids.EVT_LAND_SILTED_HARBOR),
			String(Ids.EVT_LAND_OLD_MINE),
			String(Ids.EVT_LAND_FOREST_EDGE),
			String(Ids.EVT_LAND_RUINED_SHRINE),
		],
	}


static func append(catalog) -> void:
	if catalog == null:
		return
	var Op = NarrativeConditionScript.Op
	var Ch = NarrativeEventDefinitionScript.TriggerChannel

	# ═══ 淤了的港 ═════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_LAND_SILTED_HARBOR),
		"title": "{settlement_name}·淤了的港",
		"body_text": "沙尾港的栈桥底下，泥一年比一年高。温有庆的大船停在口外三里，货用小驳船一趟趟倒进来，一袋盐过三遍手。他蹲在码头看水，木桩上刻的旧水位，今年露出泥面两指。县里的耙泥船雇一天，要管二十个人的饭；下游的滩地空着，可是得重新打桩。挑夫鲍阿四把绳子往肩上一搭，说不挖，他就没货可扛了。散的时候，温有庆把那根刻着水位的木桩拔了，扛回船上。",
		"image_key": "hydrology.water",
		"ai_visual_prompt": "A silted river harbour with a rotting pier, a merchant measuring water depth against a notched stake, porters waiting",
		"tags": ["land", "market", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 720,
		"min_era_index": 2,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.IS_COASTAL, "bool_value": true},
			{"op": Op.HAS_RIVER, "bool_value": true},
			{"op": Op.POPULATION_GTE, "int_value": 8},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.01},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
				"add_weight": 25,
				"multiplier_q16": MUL_115,
				"reason": "码头上还有活",
			},
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 20},
				"add_weight": 20,
				"reason": "船一停，货就压在岸上",
			},
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "salt", "float_value": 1.10},
				"add_weight": 20,
				"reason": "盐要过三遍手，价就上去了",
			},
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_SILT_WAITING)},
				"add_weight": 25,
				"multiplier_q16": MUL_120,
				"reason": "泥封了一年，船更进不来",
			},
		],
		"options": [
			Shared.option(
				"dredge_the_bar", "雇耙泥船，挖开",
				"泥从河口挖到码头",
				"耙泥船在河口挖了四十天，泥堆到下游的滩上。第一艘大船靠岸那天，温有庆在船头放了一挂鞭，炮仗皮顺水漂了半里。",
				[
					Shared.manufacturing(5, 360),
					Shared.trade_capacity(6, 360),
					Shared.cash_in(1.0, 360, "向本地人数最多的{primary_profession}征收其现金的 1%（疏浚摊派，按货抽一份）"),
				]),
			Shared.option(
				"move_downstream", "搬到下游滩地",
				"新桩打在空滩上",
				"新码头打了半年桩，木料从上游放排下来。老港的栈桥没人修，涨潮时先塌了一截，塌下来的木头被人捡走当柴。",
				[
					Shared.manufacturing(6, 540),
					Shared.agriculture(-3, 540),
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
				]),
			Shared.gamble(
				"wait_for_the_flood", "赌汛期自己冲",
				Shared.branch(39322, "一场水把泥带走了", # 60%
					"夏天河水涨了七天，退下去的时候，河口自己开出一道槽。温有庆量了水深，比去年还多一尺，当天就卸了货。鲍阿四在岸上看着，没去扛。",
					[
						Shared.trade_capacity(4, 360),
						Shared.manufacturing(3, 360),
						Shared.bias(Ids.TAG_UNREST, 1.15, 360),
					]),
				Shared.branch(26214, "水没来，泥更高", # 40%
					"那年河没涨起来。到冬天，驳船也进不了河口，货卸在口外，靠人背过滩。温有庆把船租给了别人，自己去县里问耙泥船的价。",
					[
						Shared.manufacturing(-4, 540),
						Shared.staple(5, 540),
						Shared.flag(Ids.FLAG_SILT_WAITING, 900, "标记「泥封港口」"),
					])),
		],
	}))

	# ═══ 老矿 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_LAND_OLD_MINE),
		"title": "{settlement_name}·老矿",
		"body_text": "黑石岭的矿车一天拉两趟，去年是五趟。邵九蹲在井口削木撑，削下来的木屑是湿的。掌秤的冯四把秤砣往后挪了半寸，说石头越来越轻。往下再打十丈，要换抽水的斗，也要加新撑架；封坑省事，井口那排屋子还能拆出三车上好的梁木。矿上三十几户人家的灶，都在这两趟车上。邵九把削好的木撑立在井边，又拿起来比了比，嫌短。",
		"image_key": "economy.resource",
		"ai_visual_prompt": "A tired mine head with two carts of ore, a miner whittling a wet wooden prop, a weigher shifting the scale weight",
		"tags": ["land", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 720,
		"min_era_index": 2,
		"max_era_index": 8,
		"blocked_story_flags": [String(Ids.FLAG_MINE_SEALED)],
		"conditions": [
			{"op": Op.HAS_NATURAL_RESOURCE, "int_value": 1},
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
				"add_weight": 25,
				"reason": "还开着井",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 6},
				"add_weight": 15,
				"reason": "矿上买得起抽水机",
			},
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_MINE_COLLAPSE)},
				"add_weight": 0,
				"multiplier_q16": MUL_125,
				"reason": "塌过一回，井口更急着重开",
			},
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 20},
				"add_weight": 15,
				"reason": "靠这两趟车吃饭的人多",
			},
		],
		"options": [
			Shared.option(
				"dig_ten_more_fathoms", "再往下打十丈",
				"水抽上来了",
				"新斗装上去，井下的水一天抽三遍。矿车回到四趟，只是拉上来的石头要过两遍手，才挑得出够分的。",
				[
					Shared.extraction(6, 540),
					Shared.cash_in(1.0, 540, "向本地人数最多的{primary_profession}征收其现金的 1%（换斗与撑架的摊派）"),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
			Shared.gamble(
				"follow_the_vein", "赌它拐个弯",
				Shared.branch(36045, "斜巷接到了厚脉", # 55%
					"斜巷掘到第九天，冯四把秤砣推回原位。石头变了颜色，敲开是亮的。他把那块石头放在窗台上，谁进来都看一眼。",
					[
						Shared.extraction(8, 540),
						Shared.country_sector("extractive", 4, 360),
						Shared.research_signal("resource.iron_ore", "铁帽石"),
						Shared.bias(Ids.TAG_UNREST, 1.10, 360),
					]),
				Shared.branch(29491, "斜巷塌了半截", # 45%
					"斜巷没撑住，塌下来的石头压坏两架车，一个人没能出来。井口停了九天，邵九把烧剩的撑木一根根码在墙边，没再说话。",
					[
						Shared.extraction(-4, 540),
						Shared.bias(Ids.TAG_UNREST, 1.35, 540),
						Shared.flag(Ids.FLAG_MINE_COLLAPSE, 900, "标记「井下塌方」"),
					])),
			Shared.option(
				"seal_the_pit", "封坑，卖梁木",
				"井口盖上了石板",
				"井口盖了石板，撑木拆下来装了六车，往城里的工地去了。冯四留下来掌秤，秤挂在空屋的梁上，风一吹就响。",
				[
					Shared.extraction(-6, 540),
					Shared.build_cost(4, 540),
					Shared.bias(Ids.TAG_UNREST, 1.40, 540),
					Shared.flag(Ids.FLAG_MINE_SEALED, 1825, "标记「井口封死」"),
				]),
		],
	}))

	# ═══ 林边 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_LAND_FOREST_EDGE),
		"title": "{settlement_name}·林边",
		"body_text": "白榆林的边已经退到坡上。罗二的炭窑一年烧八窑，砍的都是林子最外一圈的榆树，炭上打着他家的印。屈阿公在林子里下套，说从前走半天见不到天，现在一抬头就是天。石满仓要再开两亩地，就在林子边，犁头已经磨好。里正说上头要报一个数，报多了要交，报少了要挨。三个人站在那棵被雷劈过的老榆下面，谁都不先走。",
		"image_key": "economy.resource",
		"ai_visual_prompt": "A forest edge retreating up a slope, a charcoal kiln, a hunter with snares, a farmer with a polished ploughshare",
		"tags": ["land", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 600,
		"min_era_index": 1,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.VEGETATION_IN, "int_list": [
				VegetationTypeScript.VEG.TAIGA,
				VegetationTypeScript.VEG.TEMPERATE_DECIDUOUS,
				VegetationTypeScript.VEG.TEMPERATE_CONIFER,
				VegetationTypeScript.VEG.SUBTROPICAL_FOREST,
				VegetationTypeScript.VEG.TROPICAL_RAINFOREST,
				VegetationTypeScript.VEG.TROPICAL_DRY_FOREST,
				VegetationTypeScript.VEG.MANGROVE,
				VegetationTypeScript.VEG.CLOUD_FOREST,
				VegetationTypeScript.VEG.MONSOON_FOREST]},
			{"op": Op.POPULATION_GTE, "int_value": 6},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
				"add_weight": 20,
				"reason": "窑还烧着",
			},
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 10},
				"add_weight": 15,
				"reason": "人多了，就要地",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "forestry_worker", "float_value": 0.05},
				"add_weight": 20,
				"multiplier_q16": MUL_120,
				"reason": "靠林子吃饭的人就在村里",
			},
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_FOREST_CLOSED)},
				"add_weight": 20,
				"multiplier_q16": MUL_115,
				"reason": "封过一回，边上的人还盯着那条线",
			},
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_FOREST_PENDING)},
				"add_weight": 20,
				"multiplier_q16": MUL_115,
				"reason": "林界没定，明年还得议",
			},
		],
		"options": [
			Shared.option(
				"close_the_slope", "坡上那一圈封了",
				"界石埋在坡腰",
				"界石埋在坡腰，罗二被指到更远的沟里去砍，来回多走一个时辰。那年秋天，石满仓的犁挂在屋檐下，锈了一层。",
				[
					Shared.agriculture(5, 540),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
					Shared.flag(Ids.FLAG_FOREST_CLOSED, 900, "标记「坡上封林」"),
				]),
			Shared.option(
				"cut_and_mark_the_line", "照砍，划个界碑",
				"八窑烧成了十二窑",
				"那一年罗二多烧了四窑，炭车从坡上下来，压出一条新路。第二年春汛，坡下的田里盖了一层黑泥，石满仓蹲在地头，把泥捧起来又撒回去。",
				[
					Shared.manufacturing(4, 540),
					Shared.agriculture(-4, 540),
					Shared.staple(6, 540),
				]),
			Shared.option(
				"report_and_wait", "报个数，明年再说",
				"册子上多了一行",
				"册子上添了一笔，用的是去年的数。罗二照旧烧，石满仓照旧开，屈阿公把套子往更深的地方挪了一里。那棵老榆第二年没再发芽。",
				[
					Shared.flag(Ids.FLAG_FOREST_PENDING, 900, "标记「林界未定」"),
					Shared.bias(Ids.TAG_LAND, 1.20, 540),
					Shared.agriculture(-3, 540),
				]),
		],
	}))

	# ═══ 废祠 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_LAND_RUINED_SHRINE),
		"title": "{settlement_name}·废祠",
		"body_text": "三圣祠的后墙塌了半边，压坏两尊泥像。石狮子还在门口，嘴里塞着草。门槛被踩塌一角，露出底下垫的碎瓦。石匠杜衡用指节敲了敲条石，说这是好料，起新仓的墙够用，他按方算钱。守祠的温四娘每年清明还来上香，香插在台阶的裂缝里。县里说塌了就该拆干净，省得再塌一次压着人。杜衡的锤子已经放在石头上，还没落下去。",
		"image_key": "family.house",
		"ai_visual_prompt": "A half-collapsed shrine with a stone lion, broken clay figures, a mason testing a carved stone block with his knuckles",
		"tags": ["land", "unrest", "society"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 85,
		"cooldown_days": 720,
		"min_era_index": 1,
		"max_era_index": 9,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 6},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 12},
				"add_weight": 15,
				"reason": "人多，路过的也多",
			},
			{
				"condition": {"op": Op.SATISFACTION_LTE, "float_value": 0.50},
				"add_weight": 20,
				"reason": "塌了的东西更容易被看见",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
				"add_weight": 10,
				"reason": "有工地，条石就有人要",
			},
		],
		"options": [
			Shared.option(
				"take_the_stone", "拆石头，起新仓",
				"条石进了仓墙",
				"条石拆下来，砌进新仓的墙，缝对得很齐。温四娘来看过一次，站在原来的门口，低头找了半天，才找到自己插香的那道缝。",
				[
					Shared.staple(-6, 540),
					Shared.manufacturing(3, 360),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
			Shared.option(
				"rebuild_it", "照原样修起来",
				"后墙又立起来了",
				"墙照原样砌，新灰配旧石，颜色差一截。上梁那天来了不少人，温四娘把香插回原来的缝里，插了三根，只点着两根。",
				[
					Shared.cash_out(2.0, 540),
					Shared.bias(Ids.TAG_UNREST, 0.85, 540),
					Shared.flag(Ids.FLAG_SHRINE_KEPT, 900, "标记「旧祠重立」"),
				]),
			Shared.option(
				"fence_it_off", "围起来，先不动",
				"篱笆围了一圈",
				"篱笆围了一圈，挂块木牌，写着不许靠近。入冬下了几场雨，另外半边墙也塌了。杜衡从那儿路过，看了一眼，没停。",
				[
					Shared.flag(Ids.FLAG_SHRINE_WAITING, 900, "标记「墙还塌着」"),
					Shared.bias(Ids.TAG_LAND, 1.20, 540),
					Shared.bias(Ids.TAG_UNREST, 1.10, 540),
				]),
		],
	}))
