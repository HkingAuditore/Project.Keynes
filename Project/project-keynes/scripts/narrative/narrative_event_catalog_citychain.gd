class_name NarrativeEventCatalogCityChain
extends RefCounted

## 筑城链（三幕，era 0–2）：一道墙如何长成一座城。
##
##   筑城（脉冲，one_shot）→ 城里的主（脉冲，需完成筑城）→ 围城（定时，由第二幕排程）
##
## 这是补 era 0–2 的链：此前所有链都挤在 era 2–8。
## 三条分支都通向第二幕，但排程档期不同（90/120/180 日），第三幕由第二幕的三个选项分别排程。

const Ids = preload("res://scripts/narrative/narrative_event_ids.gd")
const Shared = preload("res://scripts/narrative/narrative_event_shared.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")

const PACK_ID := &"citychain"
const PREFIX := "evt.citychain."

const CAST := [
	"阿夯", "老堆", "郜父", "屈石", "坡口", "土墙", "界桩", "城门", "河滩",
]

const MUL_090 := 58982
const MUL_115 := 75366
const MUL_120 := 78643
const MUL_130 := 85197
const MUL_135 := 88474


static func meta() -> Dictionary:
	return {
		"id": PACK_ID,
		"title": "筑城链",
		"theme": "墙、主与围城",
		"era_band": "0-2",
		"prefix": PREFIX,
		"scale": "3 幕宏观链",
		"cast": CAST,
		"node_ids": [
			String(Ids.EVT_CHAIN_CITY_WALL),
			String(Ids.EVT_CHAIN_CITY_KING),
			String(Ids.EVT_CHAIN_CITY_SIEGE),
		],
	}


static func append(catalog) -> void:
	if catalog == null:
		return
	var Op = NarrativeConditionScript.Op
	var Ch = NarrativeEventDefinitionScript.TriggerChannel

	# ═══ 第 1 幕 · 筑城 ═══════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_CHAIN_CITY_WALL),
		"title": "{settlement_name}·筑城",
		"body_text": "雨季一过，阿夯把村里的人叫到坡上，说要在坡口垒一道墙。石头从河滩背，一天背三趟；土从沟里挖，夯一层撒一层水。老堆不同意，说垒墙的时候地里的草比人高，秋天吃什么。郜父蹲在坡口数了数，说这墙要垒到人胸口，得垒到入秋。阿夯没接话，把第一块石头摆在地上，石头底下垫了三把土。",
		"image_key": "map.construction",
		"ai_visual_prompt": "Villagers carrying river stones and ramming earth into a low wall at the mouth of a slope",
		"tags": ["dawn", "chain", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 900,
		"one_shot": true,
		"min_era_index": 0,
		"max_era_index": 2,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 8},
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 1},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 16},
				"add_weight": 20,
				"multiplier_q16": MUL_120,
				"reason": "人多了，才守得住一道墙",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "agricultural_worker", "float_value": 0.30},
				"add_weight": 15,
				"reason": "种地的人多，怕被抢",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
				"add_weight": 15,
				"reason": "有了仓和窑，才值得圈起来",
			},
		],
		"options": [
			Shared.option(
				"raise_the_wall", "垒墙，征民夫",
				"墙垒到胸口高",
				"墙垒到胸口高那天，孩子在墙根下钻来钻去。石头是从河滩一块一块搬来的，搬了整整一秋。老堆的麦子晚收了十天，穗子掉了一地。",
				[
					Shared.manufacturing(3, 540),
					Shared.staple(4, 360),
					Shared.schedule(Ids.EVT_CHAIN_CITY_KING, 120, "城里的主"),
				]),
			Shared.option(
				"build_a_fence", "只修一道栅栏",
				"栅栏立在坡口",
				"栅栏用的是削尖的木头，三天就立起来了。风一吹，木头缝里呜呜响。老堆说这挡不住人，阿夯说挡得住羊也行。",
				[
					Shared.agriculture(-2, 360),
					Shared.staple(-3, 180),
					Shared.schedule(Ids.EVT_CHAIN_CITY_KING, 90, "城里的主"),
				]),
			Shared.option(
				"plant_first", "不修，先把地种上",
				"坡口空了一年",
				"那年秋天收成不错，坡口的草长到人腰高。入冬后有人从西边来，牵走了七只羊，没有进村。阿夯站在坡口看了一夜，第二天把草割了。",
				[
					Shared.agriculture(5, 540),
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
					Shared.schedule(Ids.EVT_CHAIN_CITY_KING, 180, "城里的主"),
				]),
		],
	}))

	# ═══ 第 2 幕 · 城里的主 ═══════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_CHAIN_CITY_KING),
		"title": "{settlement_name}·城里的主",
		"body_text": "墙垒好第二年，坡口成了城。城里的事谁说了算，还没有定。老堆说自己辈分高，郜父说自己认得字，带过人的屈石不说话，只把刀横在膝上。三个人在墙根下坐了一下午，日头从墙头落到墙脚。墙根的土被踩实了，脚印一层压一层。阿夯蹲在旁边听，听到最后问了一句：出了事，谁去顶。没人答他。",
		"image_key": "family.house",
		"ai_visual_prompt": "Three elders sitting at the base of an earthen wall at sunset, a knife resting across one man's knees",
		"tags": ["dawn", "chain", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 160,
		"cooldown_days": 900,
		"one_shot": true,
		"min_era_index": 1,
		"max_era_index": 2,
		"required_events_completed": [String(Ids.EVT_CHAIN_CITY_WALL)],
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 10},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 18},
				"add_weight": 20,
				"reason": "人多了，事就多",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
				"add_weight": 15,
				"reason": "有了仓和窑，就有东西可争",
			},
		],
		"options": [
			Shared.option(
				"choose_an_elder", "推举辈分最高的",
				"老堆坐了上位",
				"老堆坐上墙根那块最高的石头，第一件事是让人把界碑重新埋一遍。他说话慢，一件事要问三遍，问到第三遍，别人已经干完了。",
				[
					Shared.birth(3, 540),
					Shared.knowledge(3, 540),
					Shared.staple(3, 360),
					Shared.schedule(Ids.EVT_CHAIN_CITY_SIEGE, 240, "围城"),
				]),
			Shared.option(
				"make_it_hereditary", "让他家世世代代管",
				"屈石把刀收了",
				"屈石把刀收进鞘里，说那就这么定。他家的人开始学着认字，字写得歪，架势很足。城里的工匠不服，把新刻的界碑又磨平了一次。",
				[
					Shared.manufacturing(4, 540),
					Shared.build_cost(3, 540),
					Shared.bias(Ids.TAG_LABOR, 1.10, 540),
					Shared.schedule(Ids.EVT_CHAIN_CITY_SIEGE, 240, "围城"),
				]),
			Shared.option(
				"let_the_soldier_rule", "让带兵的人管",
				"城门归屈石的人守",
				"城门归屈石的人守，进出要报名字。夜里墙上有火把，一直亮到天亮。城里的粮先紧着守墙的人，老堆的仓空了一半。",
				[
					Shared.supply(8, 360),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
					Shared.schedule(Ids.EVT_CHAIN_CITY_SIEGE, 180, "围城"),
				]),
		],
	}))

	# ═══ 第 3 幕 · 围城 ═══════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_CHAIN_CITY_SIEGE),
		"title": "{settlement_name}·围城",
		"body_text": "围城的是西边来的人，没有打旗，先在河滩上扎了营。第三天，他们把上游的水断了。城里的井一天比一天浑，老堆把最后一袋谷子搬到墙根下，说先给守墙的人吃。屈石站在墙头看，说对面的人也不多，夜里可以出去打一下。郜父拉住他，说打输了，城就没了。墙下的孩子开始哭，哭声从墙根传到墙头。",
		"image_key": "map.construction",
		"ai_visual_prompt": "A mud-walled town under siege at dawn, an enemy camp on the river flat, defenders on the wall",
		"tags": ["dawn", "chain", "unrest"],
		"trigger_channel": Ch.SCHEDULED_ONLY,
		"base_weight": 200,
		"cooldown_days": 600,
		"one_shot": true,
		"min_era_index": 1,
		"max_era_index": 3,
		"options": [
			Shared.option(
				"hold_the_wall", "闭门守，等他们退",
				"围了四十天",
				"围了四十天，墙根的粮吃完了，开始杀羊。第四十一天早上，河滩上的营地空了，锅还架在火上。城门开的时候，老堆数了数人，少了十七个。",
				[
					Shared.staple(-4, 540),
					Shared.agriculture(-3, 540),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
			Shared.option(
				"open_and_bargain", "开城门，跟他们谈",
				"城里多了一面旗",
				"城门开了一条缝，郜父出去谈了半天。回来时身后跟着两个人，城里多了一面旗，粮仓的钥匙交出去一把。那年的税，西边的人先来收。",
				[
					Shared.cash_in(1.5, 360),
					Shared.trade_capacity(4, 540),
					Shared.bias(Ids.TAG_UNREST, 0.95, 540),
				]),
			Shared.gamble(
				"strike_at_night", "夜里出城打一下",
				Shared.branch(39322, "营地烧了", # 60%
					"屈石带人从水沟摸出去，先点的粮车，后烧的帐篷。天亮时河滩上只剩黑架子，对面的人退到坡后。城里的男人回来了大半，少了几个。",
					[
						Shared.agriculture(3, 540),
						Shared.manufacturing(4, 540),
						Shared.staple(3, 360),
						Shared.bias(Ids.TAG_UNREST, 0.90, 540),
					]),
				Shared.branch(26214, "回来的没几个", # 40%
					"出去的人走到半路就被发现了。火把从河滩那头压过来，屈石最后一个退回来，肩上中了一箭。第二天，墙头上换了西边的人站。",
					[
						Shared.manufacturing(-5, 360),
						Shared.birth(-4, 540),
						Shared.bias(Ids.TAG_UNREST, 1.35, 540),
					])),
		],
	}))
