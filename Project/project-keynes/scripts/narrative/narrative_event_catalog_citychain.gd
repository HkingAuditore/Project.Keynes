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
	"长老会", "城垣", "氏族", "守城武士", "公粮仓", "城邦议事", "祭司", "河谷聚落",
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
		"title": "{settlement_name}·初筑城垣",
		"body_text": "雨季过后，{settlement_name}这座日益兴旺的河谷聚落开始面临游牧劫掠者的频繁窥伺。长老会中主张固守的派系提议征发各氏族青壮，自河滩搬运巨石、夯土筑起一座真正的城垣。但农耕派系强烈警告，大兴土木势必抽空田间劳力，令秋收陷入危机；温和派则建议仅立木栅以省民力。一道墙的取舍，将决定聚落是否就此迈向城邦时代。",
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
				"raise_the_wall", "征发民夫，夯筑城垣",
				"城垣初成格局已变",
				"经过整整一秋的繁重劳役，巍峨城垣终于在坡口合拢，聚落的营造与手工业技艺大进。尽管误了农时致使口粮吃紧，但一座真正的城邦已具雏形。",
				[
					Shared.manufacturing(10, 540),
					Shared.staple(12, 360),
					Shared.schedule(Ids.EVT_CHAIN_CITY_KING, 120, "城里的主"),
				]),
			Shared.option(
				"build_a_fence", "仅立木栅，略作屏障",
				"木栅速成难抵大敌",
				"削尖的木栅在数日内便围绕坡口立起，省下了大量存粮消耗。然而单薄的栅栏难令部众安心，围绕城防与权责的争论很快便在聚落内部发酵。",
				[
					Shared.agriculture(-8, 360),
					Shared.staple(-10, 180),
					Shared.schedule(Ids.EVT_CHAIN_CITY_KING, 90, "城里的主"),
				]),
			Shared.option(
				"plant_first", "暂缓筑城，专力耕作",
				"丰收背后隐患丛生",
				"聚落全力投入秋耕，仓廪一时充盈。但无城可守的弱点很快招致西面游骑袭掠，牲畜被劫令各氏族人人自危，要求推举强力领袖的呼声日高。",
				[
					Shared.agriculture(15, 540),
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
					Shared.schedule(Ids.EVT_CHAIN_CITY_KING, 180, "城里的主"),
				]),
		],
	}))

	# ═══ 第 2 幕 · 城里的主 ═══════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_CHAIN_CITY_KING),
		"title": "{settlement_name}·城邦之主",
		"body_text": "城垣既成，{settlement_name}已不再是散漫的村落，而是一座需要统一号令的早期城邦。在决定最高权属的城邦议事上，三股势力僵持不下：长老会倚重资历与传统，主张推举德高望重者共治；掌管记事与礼仪的祭司强调法统与传承；手握兵权的守城武士则冷眼旁观，直言乱世之中唯有能提刀御敌者方配坐拥城主之位。城邦的政体归属，此刻系于一念。",
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
				"choose_an_elder", "推举长老，依礼共治",
				"长老执政礼法渐兴",
				"德高望重的长老坐上高位，重划地界、广兴教化，城邦人口与知识稳步增长。但议事迟缓耗费了不少公粮储备，面对外部强敌时恐显优柔。",
				[
					Shared.birth(10, 540),
					Shared.knowledge(10, 540),
					Shared.staple(10, 360),
					Shared.schedule(Ids.EVT_CHAIN_CITY_SIEGE, 240, "围城"),
				]),
			Shared.option(
				"make_it_hereditary", "确立世袭，定鼎王统",
				"世袭王权初立城邦",
				"强权氏族确立了世袭统治，开始大兴营造并垄断工坊管理，城邦制造力随之跃升。然而世袭特权引发工匠阶层不满，营建成本亦水涨船高。",
				[
					Shared.manufacturing(12, 540),
					Shared.build_cost(8, 540),
					Shared.bias(Ids.TAG_LABOR, 1.10, 540),
					Shared.schedule(Ids.EVT_CHAIN_CITY_SIEGE, 240, "围城"),
				]),
			Shared.option(
				"let_the_soldier_rule", "授权武士，军政合一",
				"军事管制笼罩全城",
				"守城武士接管城门与粮仓，全城转入严苛的战时戒严，军需补给效率大幅提升。但严密盘查与军粮优先征调，也让城中平民怨气日积。",
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
		"title": "{settlement_name}·城下之围",
		"body_text": "一支未打旗号的西来劲旅突然兵临{settlement_name}城下，在河滩扎营合围，并于三日内截断了上游水源。城中水井日渐浑浊，公粮仓的存粮已紧急调拨至城垣之下优先供给守军。守城武士请战，主张趁敌军立足未稳夜袭敌营；长老会则力谏切忌孤注一掷，一旦出击失利城邦必亡。围城之势如铁桶合拢，城邦迎来了存亡绝续的终极考验。",
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
				"hold_the_wall", "紧闭城门，坚壁死守",
				"苦守解围元气大伤",
				"全城实行严苛配给苦撑四十日，敌军终因粮尽拔营撤离。城邦得以保全，但城外良田尽毁、人丁折损，劫后余生的惊悸与怨怼久久未散。",
				[
					Shared.staple(-12, 540),
					Shared.agriculture(-10, 540),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
			Shared.option(
				"open_and_bargain", "遣使议和，纳贡通商",
				"城下之盟换取生机",
				"城门开启，双方达成城下之盟，城邦以缴纳岁贡为代价换取免遭屠戮，并由此打通了通往西方的商路。虽损及尊严，却暂时稳住了城内民心。",
				[
					Shared.cash_in(4, 360),
					Shared.trade_capacity(10, 540),
					Shared.bias(Ids.TAG_UNREST, 0.95, 540),
				]),
			Shared.gamble(
				"strike_at_night", "挑选锐卒，夜袭敌营",
				Shared.branch(39322, "夜袭奏凯敌军溃退", # 60%
					"守城武士借暗夜潜出城垣，火焚敌军粮草大营，西来之敌仓皇溃逃。此战不仅缴获物资振奋了农工生产，更确立了城邦在河谷的赫赫威名。",
					[
						Shared.agriculture(10, 540),
						Shared.manufacturing(12, 540),
						Shared.staple(10, 360),
						Shared.bias(Ids.TAG_UNREST, 0.90, 540),
					]),
				Shared.branch(26214, "劫营败绩城垣失守", # 40%
					"夜袭行动半途败露，出城精锐遭敌反包围损失惨重。失去骨干守军的城垣被迫洞开，城邦制造业与人口惨遭重创，动荡阴影笼罩全城。",
					[
						Shared.manufacturing(-15, 360),
						Shared.population_rate(-8),
						Shared.bias(Ids.TAG_UNREST, 1.35, 540),
					])),
		],
	}))
