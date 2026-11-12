class_name NarrativeEventCatalogLaw
extends RefCounted

## 律法包：规矩怎么落到人身上（7 条，全部孤立）。
##
##   法典（era 2–7）· 审判（era 2–8，含一条博弈）· 债狱（era 3–8）
##   地契（era 2–8）· 伪证（era 2–9）· 赦免（era 3–9）· 公证（era 4–9）
##
## 这一包不写抽象法理，只写"条文/判决/契纸"卡住的具体那个人：
## 名字写不写进去、判给谁都要得罪人、还不上钱是关还是做工、四至含糊的地、
## 改了口的人、赦书上的名单、保人抽几成。
##
## 数值：代价一律落在可核算的几种货币上——城修正负值、`cash_in`（人群现金入库）、
## 正数 `staple`（主食变贵）与 `bias` 倍率抬升；同一事件的三个选项各用不同一种。
## 器物：竹简、契纸、朱印、铜锁、木枷、证人名册、界石、赦书。

const Ids = preload("res://scripts/narrative/narrative_event_ids.gd")
const Shared = preload("res://scripts/narrative/narrative_event_shared.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")

const PACK_ID := &"law"
const PREFIX := "evt.law."

const CAST := [
	"郭原", "薛敬", "商九", "岑万", "卫仲", "屈寮", "甘丙", "邓四娘", "罗阿石", "雍平",
	"竹简", "契纸", "朱印", "木枷", "铜锁", "证人名册", "界石", "赦书",
]

const MUL_115 := 75366
const MUL_120 := 78643
const MUL_125 := 81920


static func meta() -> Dictionary:
	return {
		"id": PACK_ID,
		"title": "律法",
		"theme": "规矩落到人身上，谁被写进去，谁被漏掉",
		"era_band": "2-9",
		"prefix": PREFIX,
		"scale": "7 条微观孤立",
		"cast": CAST,
		"node_ids": [
			String(Ids.EVT_LAW_CODE),
			String(Ids.EVT_LAW_ASSIZE),
			String(Ids.EVT_LAW_DEBT),
			String(Ids.EVT_LAW_DEED),
			String(Ids.EVT_LAW_WITNESS),
			String(Ids.EVT_LAW_PARDON),
			String(Ids.EVT_LAW_NOTARY),
		],
	}


static func append(catalog) -> void:
	if catalog == null:
		return
	var Op = NarrativeConditionScript.Op
	var Ch = NarrativeEventDefinitionScript.TriggerChannel

	# ═══ 法典 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_LAW_CODE),
		"title": "{settlement_name}·法典",
		"body_text": "郭原在西廊下抄了九天，竹简摊了一地，墨没干就被袖子蹭花。里正屈寮要把分水的旧例写进条文，还要在条下添一句立例的是谁。邓四娘抱着她男人的旧斗站在门口，说拾穗那一节不能少，她家三代靠秋后捡的穗子过冬。郭原翻到那一卷，字被虫蛀了一半，只剩一个人名，姓还认得，名看不清。薛敬从仓里回来，把朱印放在案角，说条文是要拿去逐乡念的，念的人只认名，不认理。风从廊下穿过，把最上面一卷吹开，露出底下密密麻麻的手印。",
		"image_key": "family.house",
		"ai_visual_prompt": "A county office corridor with bamboo slips spread on the floor, a clerk copying old customs, a woman holding a worn grain measure, a seal set down on the desk",
		"tags": ["law", "court"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 720,
		"min_era_index": 2,
		"max_era_index": 7,
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
			{"op": Op.POPULATION_GTE, "int_value": 12},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 5},
				"add_weight": 20,
				"reason": "衙署和仓房都在城里，条文才有人念",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "scholar", "float_value": 0.01},
				"add_weight": 0,
				"multiplier_q16": MUL_115,
				"reason": "识字的人多，条文才写得细",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 4},
				"add_weight": 15,
				"reason": "旧例摞旧例，互相打架",
			},
		],
		"options": [
			Shared.option(
				"leave_the_names_out", "照旧例写，不署人名",
				"条文上没有名字",
				"十四条抄完，发到各乡去念，念的人照着念，没有一个问这是谁立的。屈寮把原本收进匣里，匣底压着那卷被虫蛀过的老简。",
				[
					Shared.knowledge(4, 540),
					Shared.agriculture(2, 360),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
			Shared.option(
				"carve_the_elders_names", "把立例人的名字写进去",
				"条下多了一行小字",
				"每一条后面都添了一行小字，写的是当年立这条的人。邓四娘那一节也写了，写的是她公公的名字，她伸手摸了一遍，指头上沾了墨。",
				[
					Shared.knowledge(3, 540),
					Shared.cash_in(1.0, 540, "向本地人数最多的{primary_profession}征收其现金的 1%（抄条与刻工的摊派）"),
					Shared.bias(Ids.TAG_UNREST, 0.90, 540),
				]),
			Shared.option(
				"write_only_the_penalty", "只写罚，不写谁分水",
				"条文只剩罚则",
				"分水那几行划掉了，只剩罚几斗谷子。那年春天水不够，两家人在地头站了一夜，谁也没动手，谁也没让水过去。",
				[
					Shared.knowledge(5, 540),
					Shared.agriculture(-3, 540),
				]),
		],
	}))

	# ═══ 审判 ═════════════════════════════════════════════════════════════
	# 一条说不清的案子：判给谁都要得罪人，第三个选项把牛放开，让它自己走。
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_LAW_ASSIZE),
		"title": "{settlement_name}·审判",
		"body_text": "那头黄牛在商九的圈里站了半个月，右角上有一道浅刻痕，是罗阿石家孩子小的时候刻的。商九说牛是在牛市上买的，钱当众给了，契没写；罗阿石说丢牛那天，有人看见商九的伙计牵着牛往西坡走。薛敬把证人名册摊开，两个证人的话对不上，一个说牛是黄的，一个说牛背上有一块黑。廊下摆着一副木枷，是给赖账的人备的，今天还没用上。商九的人在外头台阶上数钱，声音不小；罗阿石的媳妇抱着门框，一句话不说。薛敬把朱印拿起来又放下，说这案子再问也问不出新的了。",
		"image_key": "family.house",
		"ai_visual_prompt": "A county magistrate's bench with a witness roll and seal, an ox standing in a pen outside, two families waiting in the yard, a yoke leaning against the wall",
		"tags": ["law", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 105,
		"cooldown_days": 720,
		"min_era_index": 2,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
			{"op": Op.POPULATION_GTE, "int_value": 12},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 5},
				"add_weight": 20,
				"reason": "有衙门，案子才递得上来",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.02},
				"add_weight": 0,
				"multiplier_q16": MUL_115,
				"reason": "买卖做得大，争的东西值钱",
			},
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 25},
				"add_weight": 15,
				"reason": "人多，认得两边的人也多",
			},
		],
		"options": [
			Shared.option(
				"return_the_ox", "牛判给罗阿石，牛价按户摊还",
				"牛回到了西坡",
				"牛牵回西坡那天，罗阿石的孩子骑在牛背上。商九的买价按户摊还，屈寮拿着名册一户一户收，收到最后一家，天已经黑了。",
				[
					Shared.agriculture(3, 540),
					Shared.cash_in(1.0, 540, "向本地人数最多的{primary_profession}征收其现金的 1%（摊还商九的牛价）"),
					Shared.knowledge(2, 360),
				]),
			Shared.option(
				"award_to_the_buyer", "牛判给商九，市面照旧",
				"牛被牵去了牛市",
				"牛当天就被牵到牛市上转手，卖给了过路的人。罗阿石在西坡坐到天黑，回家把那根拴牛的桩拔了，扔进灶膛。",
				[
					Shared.agriculture(-3, 540),
					Shared.manufacturing(2, 360),
					Shared.bias(Ids.TAG_MARKET, 0.90, 540),
				]),
			Shared.gamble(
				"let_the_ox_walk", "放开牛，走到谁家算谁的",
				Shared.branch(36045, "牛自己走回了西坡", # 55%
					"牛出了圈，在岔口停了一停，径直往西坡走。罗阿石蹲在自家门口，看见牛过来，没有起身。",
					[
						Shared.agriculture(3, 540),
						Shared.staple(3, 540),
						Shared.bias(Ids.TAG_UNREST, 0.90, 540),
					]),
				Shared.branch(29491, "牛跟着伙计走了", # 45%
					"牛在岔口停了很久，最后跟着商九的伙计走了。围在县门口的人散了，散了以后谁也没有再提这头牛。",
					[
						Shared.staple(6, 540),
						Shared.knowledge(2, 360),
					])),
		],
	}))

	# ═══ 债狱 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_LAW_DEBT),
		"title": "{settlement_name}·债狱",
		"body_text": "甘丙欠岑万的钱，是去年春天借的，那年他下了两遍种，第二遍全烂在土里。契纸上按着他的手印，利钱一行添一行。今年开春，他把家里两口锅都卖了，还差一半。岑万在门口支了张凳坐着，说不关人，钱就再也收不回来。县里的牢只有三间，铜锁锈住，锁前要浇一勺油才转得动。郭原翻着旧簿子，说关一天要管一天的饭，做一天工能抵三天的利。甘丙的媳妇把契纸折了又折，塞进袖子，站在阶下等一句话。",
		"image_key": "country.economy",
		"ai_visual_prompt": "A debtor's yard with a moneylender seated on a stool at the gate, a worn contract in a woman's sleeve, a rusted lock on a small jail door",
		"tags": ["law", "market", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 3,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.02},
			{"op": Op.POPULATION_GTE, "int_value": 12},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.03},
				"add_weight": 0,
				"multiplier_q16": MUL_125,
				"reason": "放贷的人多，欠条也多",
			},
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 20},
				"add_weight": 15,
				"reason": "人多，还不上的人也挤在一处",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
				"add_weight": 15,
				"reason": "有牢、有窑，才谈得上关人还是做工",
			},
		],
		"options": [
			Shared.option(
				"lock_him_up", "关进牢里，等家里凑钱",
				"牢门上了锁",
				"牢门锁上的时候，甘丙的媳妇把契纸从袖子里抽出来，摊在膝上又看了一遍。第三天她回了娘家，第七天带回来半袋谷子。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
					Shared.manufacturing(2, 360),
				]),
			Shared.option(
				"work_off_the_debt", "放出来，到窑上做工抵债",
				"窑上多了一个人",
				"甘丙第二天就上了窑，工钱一半记在岑万的账上，一半记在自己名下。他每天收工都要去看一眼那本账，账上的数比他想的小。",
				[
					Shared.manufacturing(3, 540),
					Shared.agriculture(-3, 540),
				]),
			Shared.option(
				"the_village_guarantees", "乡里先垫，从他工钱里扣",
				"名册上多了一行保",
				"屈寮让各户按人头凑了钱，先还岑万，甘丙做工还乡里。名册上新添的一行写着他的名，后面跟着一串按了手印的户主。",
				[
					Shared.cash_in(1.0, 540, "向本地人数最多的{primary_profession}征收其现金的 1%（先垫甘丙的债，再从工钱里扣）"),
					Shared.manufacturing(2, 540),
					Shared.bias(Ids.TAG_UNREST, 0.85, 540),
				]),
		],
	}))

	# ═══ 地契 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_LAW_DEED),
		"title": "{settlement_name}·地契",
		"body_text": "那张地契是三十年前写的，纸边被虫蛀成锯齿，四至只写了东到沟、西到柳。邓四娘说沟早就改了道，柳树前年也被风刮倒，如今凭这几个字，谁也说不清坡上那半亩归谁。卫仲还记得自己的笔。他说契是照坡上那块卧石写的，卧石埋在哪儿他也记得。罗阿石把它从土里刨出来，石上的刻痕磨平了，只剩一道浅坑。里正屈寮把契纸和石头并排放在案上，看了很久。天快黑的时候他才说，照契还是照石，今天得挑一个，挑完了就别再来找他。",
		"image_key": "map.construction",
		"ai_visual_prompt": "An old land deed with worm-eaten edges beside a worn boundary stone on a clerk's desk, a farmer and a woman standing apart, dusk light",
		"tags": ["law", "land"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 2,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "agricultural_worker", "float_value": 0.30},
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "agricultural_worker", "float_value": 0.35},
				"add_weight": 0,
				"multiplier_q16": MUL_115,
				"reason": "种地的人多，地界年年要吵",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
				"add_weight": 15,
				"reason": "盖房要地，旧契才被翻出来",
			},
			{
				"condition": {"op": Op.SATISFACTION_LTE, "float_value": 0.50},
				"add_weight": 15,
				"reason": "日子紧，半亩地也要争",
			},
		],
		"options": [
			Shared.option(
				"follow_the_deed", "照契纸，沟以东归她",
				"沟东那半亩归了她",
				"丈量的人沿着旧沟走了一趟，把沟东那半亩划给了邓四娘。罗阿石把那块卧石抱回家，垫在猪圈的墙根下。",
				[
					Shared.cash_in(1.0, 540, "向本地人数最多的{primary_profession}征收其现金的 1%（丈量与写新契的摊派）"),
					Shared.agriculture(2, 360),
					Shared.knowledge(2, 360),
				]),
			Shared.option(
				"follow_the_stone", "照界石，坡上归村里公用",
				"石头被重新埋了回去",
				"那块卧石照原样埋回去，四周夯实，坡上那半亩划作村里的公用。那一年没人去种，草长到膝盖高，秋天被人放了一把火。",
				[
					Shared.agriculture(-3, 540),
					Shared.bias(Ids.TAG_LAND, 0.85, 540),
					Shared.knowledge(2, 360),
				]),
			Shared.option(
				"wait_a_year", "封起来，明年重写契",
				"木桩围了一圈",
				"木桩围了一圈，绳子拉了三道。第二年春天雨多，木桩倒了一半，绳子被人解去做担绳，那块地还是荒着。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.25, 540),
					Shared.knowledge(2, 360),
					Shared.bias(Ids.TAG_LAND, 0.90, 540),
				]),
		],
	}))

	# ═══ 伪证 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_LAW_WITNESS),
		"title": "{settlement_name}·伪证",
		"body_text": "证人名册上有七个手印，第三个是甘丙的。头一回问，他说那天夜里看见有人从仓后墙翻进来；第二回问，他说记错了，只看见一条狗。卫仲把两次的口供并排放在案上，字都是他自己写的，笔画一个样，只有日子差了两天。郭原问他这两天见过谁，甘丙低头看鞋，鞋帮上沾着新泥，是窑场那边的土。有人在他耳边提过一句，说岑万账上还记着他一笔，这笔不作数，别的事也就好说。卫仲把名册合上，说这一页要重抄，抄完了就再不能改。",
		"image_key": "family.house",
		"ai_visual_prompt": "Two conflicting written statements side by side on a clerk's desk, a witness looking down at muddy shoes, a witness roll with fingerprint marks",
		"tags": ["law", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 2,
		"max_era_index": 9,
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
			{"op": Op.POPULATION_GTE, "int_value": 12},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
				"add_weight": 20,
				"reason": "仓多墙多，翻墙的事才有得说",
			},
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 20},
				"add_weight": 15,
				"reason": "人多，证人也多，话容易变",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 5},
				"add_weight": 10,
				"reason": "案子都要入册，改口就是改册",
			},
		],
		"options": [
			Shared.option(
				"take_the_second_story", "照第二回的口供结案",
				"案子当天就结了",
				"案子当天就结了，卷宗压在柜子最底层。甘丙领了该领的钱，第二天就搬出窑场，走的时候没跟人打招呼。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.25, 540),
					Shared.manufacturing(2, 360),
				]),
			Shared.option(
				"lock_the_witness", "把改口的人关起来",
				"他在牢里改回了原话",
				"甘丙在牢里关了九天，第九天把原话一字不差地说了一遍。出来的时候卫仲问他往后还敢不敢改口，他没答。",
				[
					Shared.cash_in(1.0, 540, "向本地人数最多的{primary_profession}征收其现金的 1%（牢饭与差役的摊派）"),
					Shared.knowledge(3, 540),
				]),
			Shared.option(
				"copy_the_roll_again", "重抄名册，从头再问",
				"七个手印要重新按",
				"名册重抄了一遍，七个人一个一个叫来问，问到第三个，天已经亮了。市面上的货压在仓里不敢动，等消息等了半个月。",
				[
					Shared.manufacturing(-3, 540),
					Shared.knowledge(5, 540),
					Shared.bias(Ids.TAG_UNREST, 0.85, 540),
				]),
		],
	}))

	# ═══ 赦免 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_LAW_PARDON),
		"title": "{settlement_name}·赦免",
		"body_text": "新君登基的赦书是秋后到的，写在黄麻纸上，边上盖着朱印，一路被雨打湿了一角。雍平说这回要大赦，狱里关着的人一并放出去，好让天下看见新朝的宽。薛敬把狱簿摊开，指着头几行。甘丙欠岑万的钱，放出去，债主明天就堵在县门口。另几个伤了人，放了，苦主家还在等一个说法。卫仲在旁边磨墨，磨到一半停下，说先君登基那年也赦过，赦完第二年狱里又满了。木枷挂在墙上，锁孔里塞着陈年的灰。雍平把赦书推过来，笔搁在砚上，等一个人先开口。",
		"image_key": "family.house",
		"ai_visual_prompt": "A pardon edict on coarse paper with a red seal, a jail ledger open on the desk, a yoke hanging on the wall, an envoy waiting with a brush",
		"tags": ["law", "court"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 900,
		"min_era_index": 3,
		"max_era_index": 9,
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
			{"op": Op.POPULATION_GTE, "int_value": 12},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 5},
				"add_weight": 0,
				"multiplier_q16": MUL_115,
				"reason": "城里有牢有衙署，赦起来才像件事",
			},
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 25},
				"add_weight": 15,
				"reason": "人多，狱里关的也多",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 6},
				"add_weight": 10,
				"reason": "新朝要收人心",
			},
		],
		"options": [
			Shared.option(
				"pardon_everyone", "全赦，连欠债的一并放",
				"狱门开了一整天",
				"狱门开了一整天，放出去的人站在县门口，眯着眼看太阳。当天夜里就有人在城外抢了一车布，第二天苦主来敲门，门房里的人说人已经走了。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
					Shared.manufacturing(2, 360),
				]),
			Shared.option(
				"pardon_only_debtors", "只放欠债的，伤人的照旧",
				"债囚回了家",
				"欠债的放了出来，当天就有人回家扛起锄头。伤人的那几个还关在里头，苦主家送来一篮鸡蛋，卫仲没敢收。",
				[
					Shared.manufacturing(-3, 540),
					Shared.bias(Ids.TAG_UNREST, 0.85, 540),
					Shared.agriculture(2, 360),
				]),
			Shared.option(
				"commute_not_pardon", "一个不赦，只减刑",
				"狱里还是满的",
				"一个也没放，只把几个人的役期减了半年。牢粮又添了一笔，郭原在簿子上记下这一笔，写完把笔搁在砚边。",
				[
					Shared.cash_in(1.0, 540, "向本地人数最多的{primary_profession}征收其现金的 1%（狱粮与修牢的摊派）"),
					Shared.knowledge(3, 540),
				]),
		],
	}))

	# ═══ 公证 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_LAW_NOTARY),
		"title": "{settlement_name}·公证",
		"body_text": "岑万要往南边发一批铁器，货值不小，买主是外乡来的行商，人还没见过。契纸上写好了货、价、日子，只缺一个作保的人。卫仲的字在县里认，他肯保，但要抽三厘；商九替外乡行商说话，说三厘太重，宁可少发一半货。郭原把契纸摊在案上，保人那一行空着，空处比别处白。卫仲说保了就要赔，去年他替人保过一回，赔掉半年的工钱。廊下的朱印在太阳里发亮，谁按下去，名字就要跟着这张纸走十年。",
		"image_key": "country.economy",
		"ai_visual_prompt": "A contract on a desk with a blank guarantor line, a red seal in sunlight, iron goods loaded on a cart outside, a guarantor hesitating",
		"tags": ["law", "market"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 720,
		"min_era_index": 4,
		"max_era_index": 9,
		"conditions": [
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.03},
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.05},
				"add_weight": 0,
				"multiplier_q16": MUL_120,
				"reason": "生意往外走，契要有人保",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
				"add_weight": 15,
				"reason": "仓和铺子多了，赊账也多",
			},
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "wrought_iron", "float_value": 1.10},
				"add_weight": 20,
				"reason": "铁价一涨，发出去的货就更要保",
			},
		],
		"options": [
			Shared.option(
				"pay_the_guarantor", "请卫仲作保，抽三厘",
				"保人押了字",
				"卫仲在保人那一行按下手印，三厘的保钱当场点清。货发出去那天，他在县门口站到车看不见了才回去。",
				[
					Shared.trade_capacity(4, 360),
					Shared.manufacturing(2, 360),
					Shared.cash_in(1.0, 540, "向本地人数最多的{primary_profession}征收其现金的 1%（保钱与写契的摊派）"),
				]),
			Shared.option(
				"ship_half", "不找保人，少发一半货",
				"车队短了一半",
				"车队短了一半，剩下的货压在仓里。岑万每天去仓里转一圈，把最上面那几捆铁件翻过来看看有没有生锈。",
				[
					Shared.manufacturing(-3, 540),
					Shared.bias(Ids.TAG_MARKET, 0.85, 540),
				]),
			Shared.option(
				"let_the_county_stand", "官府作保，不收保钱",
				"朱印盖在保人那一行",
				"朱印盖在保人的空处，车队照原样发出去。到了秋天，外乡那批货出了事，行商跑了，赔钱的话递到县里，递话的人一天来一趟。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
					Shared.trade_capacity(6, 360),
					Shared.manufacturing(2, 360),
				]),
		],
	}))
