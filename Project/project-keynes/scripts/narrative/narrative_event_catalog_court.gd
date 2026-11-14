class_name NarrativeEventCatalogCourt
extends RefCounted

## 宫廷包：继承与合法性（4 条）。
##
## 链（三幕）：
##   空座（脉冲，era 2–5）→ 掌印的人（脉冲 + 需完成空座；也被空座排程）→ 两方印（定时，由掌印的人排程）
## 孤立（微观）：
##   过路的官（脉冲，era 2–7）
##
## 数值：全部走 narrative_event_shared.gd 的构造器，标签自动生成；
## 城修正是 ADD 1.0 族，负向自动切 `.cut`；标记/偏置 ≤1825 日，所以长程因果一律用
## `required_events_completed`（引擎对所有已结算事件都会永久记账）。
##
## 文本：现代白话，短句，具名的人与物；引语只留给"过路的官"一条。

const Ids = preload("res://scripts/narrative/narrative_event_ids.gd")
const Shared = preload("res://scripts/narrative/narrative_event_shared.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")

const PACK_ID := &"court"
const PREFIX := "evt.court."

const CAST := [
	"韩宿", "周览", "裴让", "韩霁", "老王", "宗谱", "兵符", "武库", "驿馆", "界桩", "旧账", "路引",
]

const MUL_115 := 75366
const MUL_120 := 78643
const MUL_125 := 81920
const MUL_130 := 85197


static func meta() -> Dictionary:
	return {
		"id": PACK_ID,
		"title": "宫廷",
		"theme": "继承与合法性",
		"era_band": "2-7",
		"prefix": PREFIX,
		"scale": "3 宏观链 + 1 微观孤立",
		"cast": CAST,
		"node_ids": [
			String(Ids.EVT_COURT_EMPTY_SEAT),
			String(Ids.EVT_COURT_REGENT),
			String(Ids.EVT_COURT_TWO_SEALS),
			String(Ids.EVT_COURT_EXILED),
		],
	}


static func append(catalog) -> void:
	if catalog == null:
		return
	var Op = NarrativeConditionScript.Op
	var Ch = NarrativeEventDefinitionScript.TriggerChannel

	# ═══ 第 1 幕 · 空座 ═══════════════════════════════════════════════════
	# 触发：人口够多、城里有像样的衙门、人心不定。继承危机不挑地形，挑"有没有一个能被争的东西"。
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_COURT_EMPTY_SEAT),
		"title": "{settlement_name}·空座",
		"body_text": "老王死在秋天，药碗还在案上，已经凉了。他没有亲生儿子。掌印的老臣韩宿把宗谱摊在膝上，指着一个六岁的名字；国舅周览不看他，只看门口那排甲士。管仓的站在最后，手里捏着一枚旧封条，封条上还沾着去年的印泥。有人提到先王当年在外面留下的那个孩子，屋子里就静了。你听见廊下有人在磨刀，也可能是风。",
		"image_key": "family.house",
		"ai_visual_prompt": "Ancient court hall after a king's death, a chancellor holding a genealogy scroll, guards at the door",
		"tags": ["court", "society", "chain"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 105,
		"cooldown_days": 900,
		"one_shot": true,
		"min_era_index": 2,
		"max_era_index": 5,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 10},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
				"add_weight": 30,
				"multiplier_q16": MUL_120,
				"reason": "城里有像样的衙门，争的人更多",
			},
			{
				"condition": {"op": Op.SATISFACTION_LTE, "float_value": 0.50},
				"add_weight": 25,
				"multiplier_q16": MUL_115,
				"reason": "人心不定，谁都想提前站队",
			},
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 25},
				"add_weight": 20,
				"reason": "人多口杂，消息压不住",
			},
		],
		"options": [
			Shared.option(
				"cradle_heir", "立幼子，托孤给他",
				"孩子被抱上座",
				"孩子被抱上座，脚够不着地。韩宿替他接了印，说等他长大再还。没有人问要等多久。",
				[
					Shared.cash_out(2.0, 540),
					Shared.flag(Ids.FLAG_THRONE_DISPUTED, 1825, "标记「主少国疑」"),
					Shared.schedule(Ids.EVT_COURT_REGENT, 25, "掌印的人"),
				]),
			Shared.option(
				"adopted_heir", "立养子，先告祖庙",
				"养子跪了一夜",
				"养子在祖庙跪了一夜。第二天他搬进正殿，第一件事是把周览的兵调到城外。",
				[
					Shared.build_cost(4, 540),
					Shared.bias(Ids.TAG_UNREST, 0.90, 540),
					Shared.bias(Ids.TAG_COURT, 1.20, 540),
				]),
			Shared.option(
				"hidden_death", "不发丧，先点武库",
				"城门先关了",
				"丧没发，城门先关了。三天后开城，武库的册子上多了两页，谁也没说是给谁准备的。",
				[
					Shared.cash_out(1.5, 360),
					Shared.bias(Ids.TAG_UNREST, 1.35, 540),
					Shared.schedule(Ids.EVT_COURT_REGENT, 60, "掌印的人"),
				]),
		],
	}))

	# ═══ 第 2 幕 · 掌印的人 ═══════════════════════════════════════════════
	# 入口有两条：空座的两个分支会排程它；脉冲通道再用"已完成空座"把它兜住，
	# 所以任何一条继承路线都不会把这一幕走丢。
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_COURT_REGENT),
		"title": "{settlement_name}·掌印的人",
		"body_text": "韩宿每天卯时到，把一摞文书写完，再回自己的院子。文书里有一半是你没见过的：谁家的儿子补了缺，哪条河的堤要加高，哪个县的粮可以再征一成。他不贪，至少看起来不贪。他只是把每一件事都捏在自己手里。今天他递上来一张单子，上面只有一行字：今年的兵符，该谁收着。",
		"image_key": "family.house",
		"ai_visual_prompt": "A chancellor's desk covered with scrolls, a tally of military authority set apart from the rest",
		"tags": ["court", "society", "chain"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 150,
		"cooldown_days": 900,
		"one_shot": true,
		"min_era_index": 2,
		"max_era_index": 6,
		"required_events_completed": [String(Ids.EVT_COURT_EMPTY_SEAT)],
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 10},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_THRONE_DISPUTED)},
				"add_weight": 40,
				"multiplier_q16": MUL_130,
				"reason": "主少国疑，相府的门槛更挤",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 5},
				"add_weight": 20,
				"reason": "衙门越多，他捏住的越多",
			},
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_OLD_LEDGER)},
				"add_weight": 0,
				"multiplier_q16": 91750,
				"reason": "旧账在案，相府收敛了些",
			},
		],
		"options": [
			Shared.option(
				"pay_the_regent", "每年给他一笔钱",
				"钱按季送到",
				"钱是按季送的，装在普通的木匣里。韩宿收了，什么也没说，第二天照常卯时到。",
				[
					Shared.cash_out(2.5, 540),
					Shared.bias(Ids.TAG_UNREST, 0.85, 540),
					Shared.flag(Ids.FLAG_REGENT_PAID, 1825, "标记「相府有例」"),
				]),
			Shared.option(
				"take_the_tally", "把兵符收回来",
				"兵符进了匣子",
				"兵符收回来了，放在你案头的匣子里。韩宿当天没来。第三天，南边传来消息，说有人立了新的印。",
				[
					Shared.supply(10, 360),
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
					Shared.schedule(Ids.EVT_COURT_TWO_SEALS, 45, "两方印"),
				]),
			Shared.option(
				"let_him_run_grain", "让他兼管漕运",
				"漕船换了旗号",
				"漕船换了旗号。韩宿的人开始在码头上点名，点到谁，谁就得把货卸下来一半。",
				[
					Shared.trade_capacity(6, 540),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
					Shared.flag(Ids.FLAG_REGENT_ENTRENCHED, 1825, "标记「相府掌漕」"),
				]),
		],
	}))

	# ═══ 第 3 幕 · 两方印 ═════════════════════════════════════════════════
	# 只有"收兵符"会走到这里。这一幕是结账：分裂、内战、或请人调停，三条路都要付长期账。
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_COURT_TWO_SEALS),
		"title": "{settlement_name}·两方印",
		"body_text": "另一个印也立起来了。印是旧的，人是新的，掌印的据说原是宗室里的韩霁，也有人说只是个幌子。两边的文书都盖着同样的印，写同样的年号，收同一年的税。路上的商队开始带两份路引，走错一个渡口就要多交一遍钱。你派去的人回来说，那边每天也在这个时候看同样的折子，看到生气处，摔的是同一批杯子。",
		"image_key": "family.house",
		"ai_visual_prompt": "Two identical seals on two desks in two rival courts, merchants carrying two travel permits",
		"tags": ["court", "unrest", "chain"],
		"trigger_channel": Ch.SCHEDULED_ONLY,
		"base_weight": 180,
		"cooldown_days": 600,
		"one_shot": true,
		"min_era_index": 3,
		"max_era_index": 7,
		"options": [
			Shared.option(
				"draw_the_border", "各管一半，划界",
				"界桩埋在河滩上",
				"界桩埋在两县之间的河滩上。第一年两边都来收税，第二年只有一边来，另一边的人在河滩上种了麦。",
				[
					Shared.knowledge(-4, 540),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
					Shared.flag(Ids.FLAG_TWO_COURTS, 1825, "标记「两印并立」"),
				]),
			Shared.option(
				"march_south", "发兵去打",
				"兵过了河",
				"兵过了河。四十天后，铸钱的地方开始掺铅；秋天，南边一座祠塌了，没有人去修。",
				[
					Shared.cash_out(4.0, 540),
					Shared.bias(Ids.TAG_UNREST, 1.50, 540),
					Shared.schedule(Ids.EVT_FISCAL_DEBASED_COIN, 40, "小钱"),
					Shared.schedule(Ids.EVT_LAND_RUINED_SHRINE, 90, "废祠"),
				]),
			Shared.option(
				"ask_for_mediation", "请人调停",
				"每一道旨都要盖两次",
				"调停的人在两个院子之间走了七天。印还是一个，只是从此每一道旨都要盖两次。",
				[
					Shared.knowledge(-4, 360),
					Shared.build_cost(3, 540),
					Shared.bias(Ids.TAG_UNREST, 0.95, 540),
					Shared.bias(Ids.TAG_FAITH, 1.20, 540),
				]),
		],
	}))

	# ═══ 孤立 · 过路的官 ═══════════════════════════════════════════════════
	# 微观事件：一个被贬的官路过，要不要留下他。他记得旧账，也带着霉气。
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_COURT_EXILED),
		"title": "{settlement_name}·过路的官",
		"body_text": "一个官带着家眷在城南的驿馆住了十一天。驿丞说他付不出房钱，也没说要走。他叫裴让，从前管过河工，也管过粮，后来在一道折子上写错了一个字。他托人带话，说愿意在这里教书，或者替人理账，只要一间不漏雨的屋子。城里的老户不想要他，说他身上带着霉气；也有人说，他记得很多年前的那笔账。",
		"image_key": "family.house",
		"ai_visual_prompt": "A demoted official with his family waiting in a shabby inn, inkstone and worn account books on the table",
		"tags": ["court", "society", "letter"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 2,
		"max_era_index": 7,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 8},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "scholar", "float_value": 0.01},
				"add_weight": 30,
				"multiplier_q16": MUL_125,
				"reason": "本地有读书人，识得他的来历",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
				"add_weight": 25,
				"reason": "有空屋子，也有一堆没人理的旧账",
			},
			{
				"condition": {"op": Op.SATISFACTION_GTE, "float_value": 0.60},
				"add_weight": 15,
				"reason": "日子还过得去，容得下多一张嘴",
			},
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_REGENT_PAID)},
				"add_weight": 0,
				"multiplier_q16": 58982,
				"reason": "相府有例，读书人不愿沾这个城",
			},
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_REGENT_ENTRENCHED)},
				"add_weight": 20,
				"multiplier_q16": 75366,
				"reason": "漕运被把持，失意的人更多",
			},
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_TWO_COURTS)},
				"add_weight": 0,
				"multiplier_q16": 52429,
				"reason": "两个主子，谁都不敢用他",
			},
		],
		"options": [
			Shared.option(
				"keep_him_teaching", "留他教书",
				"六张矮桌",
				"他把驿馆的东厢腾出来，摆了六张矮桌。第一天来了三个孩子，第三天来了十一个；第九天，城里的老户开始送束脩。",
				[
					Shared.cash_out(1.5, 360),
					Shared.knowledge(5, 540),
					Shared.bias(Ids.TAG_UNREST, 1.10, 360),
				]),
			Shared.option(
				"pay_him_to_leave", "给他盘缠，送走",
				"枕头底下的一张纸",
				"他收了钱，第二天一早就走了。驿丞收拾屋子，从枕头底下扫出一张纸，上面写满了字，没写完。",
				[
					Shared.cash_out(1.0, 180),
					Shared.knowledge(-2, 240),
					Shared.bias(Ids.TAG_UNREST, 0.95, 240),
				]),
			Shared.gamble(
				"ask_for_the_old_ledger", "留他，先写旧账",
				Shared.branch(42598, "旧账写完了", # 65%
					"他把旧账写完，用了两个月。写到最后，他把几个名字圈起来，又在旁边各写了一个数目。册子交上来那天，城里有人连夜搬了家。",
					[
						Shared.knowledge(6, 540),
						Shared.flag(Ids.FLAG_OLD_LEDGER, 1825, "标记「旧账在案」"),
						Shared.bias(Ids.TAG_UNREST, 1.15, 540),
					]),
				Shared.branch(22938, "三页就停笔", # 35%
					"他写了三页就不肯再写。第二天，驿馆的窗纸被人捅破，桌上只剩一盏冷茶。他走了，账没留下。",
					[
						Shared.knowledge(-3, 240),
						Shared.cash_out(2.0, 360),
						Shared.bias(Ids.TAG_UNREST, 1.30, 360),
					])),
		],
	}))
