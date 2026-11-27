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
	"法典", "官署", "契纸", "朱印", "卷宗", "证人名册", "地契", "赦书", "保人", "债狱",
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
		"body_text": "官署正着手将历代沿袭的乡规旧例编纂为统一法典，以便盖上朱印颁行各地。地方豪强力主在分水条文中写明历代立例宗族的名号，借此确立世袭特权；而底层佃农与平民代表则要求保留秋后拾穗等传统生计条款。主理修律的法吏指出，旧档残缺且相互抵牾，若兼顾各方必将冗杂难行，若一刀切则恐激起强烈反弹。",
		"image_key": "family.house",
		"ai_visual_prompt": "A county office corridor with bamboo slips spread on the floor, a clerk copying old customs, a woman holding a worn grain measure, a seal set down on the desk",
		"tags": ["law", "court"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 720,
		"min_era_index": 2,
		"max_era_index": 7,
		"required_technologies": ["tech.writing"],
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
				"leave_the_names_out", "统一入典，删去立例宗族名号",
				"法不阿贵",
				"统一法典颁行各乡，去除了地方豪强的世袭署名，明确了水利与农事权责。成文法威信大增，但特权被削的乡绅暗中制造了不少阻力。",
				[
					Shared.knowledge(12, 540),
					Shared.agriculture(8, 360),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
			Shared.option(
				"carve_the_elders_names", "保留旧名，兼顾各方传统惯例",
				"兼容旧例",
				"法典逐条附注了历代立例渊源与拾穗旧俗，虽然增印刊刻增加了地方摊派，但各阶层均感诉求受重视，社会秩序得以平稳过渡。",
				[
					Shared.knowledge(10, 540),
					Shared.cash_in(3, 540, "向本地人数最多的{primary_profession}征收其现金的 3%（抄条与刻工的摊派）"),
					Shared.bias(Ids.TAG_UNREST, 0.90, 540),
				]),
			Shared.option(
				"write_only_the_penalty", "精简条文，仅颁布明确罚则",
				"唯留刑罚",
				"复杂的分水细则被全数删去，法典仅保留简明的违约罚则。司法体系虽因此高效统一，但春耕时节的水源争端却令农事蒙受损失。",
				[
					Shared.knowledge(15, 540),
					Shared.agriculture(-10, 540),
				]),
		],
	}))

	# ═══ 审判 ═════════════════════════════════════════════════════════════
	# 一条说不清的案子：判给谁都要得罪人，第三个选项把牛放开，让它自己走。
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_LAW_ASSIZE),
		"title": "{settlement_name}·审判",
		"body_text": "一桩棘手的耕畜权属诉讼呈上官署：本地农户指认商行圈中的耕牛系自家失窃之物，商行则坚称系在公开市场合法购得，唯独未立契纸。调阅证人名册后，两名证人的证词竟自相矛盾，缺乏铁证。庭外商帮成员与周边农户各自聚集施压，此案判决不仅关乎一头耕牛，更将直接影响市场交易安全与小农产权信心，主审官手持朱印迟迟难断。",
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
				"return_the_ox", "判归农户，由地方摊还购牛款",
				"原物归主",
				"耕牛被判归原主，避免了农耕受损，商行的购置损失则由地方摊派补偿。此举维护了基层产权与司法公信，唯独加重了民众短期负担。",
				[
					Shared.agriculture(10, 540),
					Shared.cash_in(3, 540, "向本地人数最多的{primary_profession}征收其现金的 3%（摊还商九的牛价）"),
					Shared.knowledge(8, 360),
				]),
			Shared.option(
				"award_to_the_buyer", "判归商行，维护善意市场交易",
				"保护商易",
				"判决确立了公开市场交易优先的原则，商行与作坊信心大增，市场秩序趋稳。但失牛农户孤立无援，周边农业生产积极性受到打击。",
				[
					Shared.agriculture(-10, 540),
					Shared.manufacturing(8, 360),
					Shared.bias(Ids.TAG_MARKET, 0.90, 540),
				]),
			Shared.gamble(
				"let_the_ox_walk", "当众放牛，以牲畜自择定归属",
				Shared.branch(36045, "耕牛识途", # 55%
					"耕牛出圈后径直返回农户家中，围观民众无不称奇，地方怨气随之消散。虽然缺乏法理依据令民生开销略有波动，但农事得以保全。",
					[
						Shared.agriculture(10, 540),
						Shared.staple(10, 540),
						Shared.bias(Ids.TAG_UNREST, 0.90, 540),
					]),
				Shared.branch(29491, "牛随商去", # 45%
					"耕牛在路口徘徊后跟随商行伙计离去，诉讼就此尘埃落定。这一带有赌博色彩的裁断虽留下了奇闻判例，却令基层生计压力雪上加霜。",
					[
						Shared.staple(18, 540),
						Shared.knowledge(8, 360),
					])),
		],
	}))

	# ═══ 债狱 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_LAW_DEBT),
		"title": "{settlement_name}·债狱",
		"body_text": "连年灾荒令大批农户无力偿还商人的高利借贷，债主手持按有手印的契纸涌向官署，要求将欠债者尽数投入债狱以儆效尤。司法官吏核算后回报，羁押债囚不仅耗费官府口粮，更会让田地彻底荒芜；但若放任违约，借贷信用体系将瞬间崩盘。是严执法度收监、强制劳役抵债，还是由地方公款担保展期，亟待定夺。",
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
				"lock_him_up", "依法收监，责令家属筹款赎人",
				"债囚入狱",
				"欠债者被关入债狱，严厉的履约信号保住了商业借贷信心与作坊资金链。但家属被迫变卖家产筹款，底层民众对严苛债法的怨愤迅速升级。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
					Shared.manufacturing(8, 360),
				]),
			Shared.option(
				"work_off_the_debt", "免于收监，发往官营工坊劳役",
				"以工抵债",
				"欠债者被编入窑场与工坊做工，工钱按比例划归债主。此举为制造业补充了廉价劳力，却因抽走青壮劳动力而导致本地农产下滑。",
				[
					Shared.manufacturing(10, 540),
					Shared.agriculture(-10, 540),
				]),
			Shared.option(
				"the_village_guarantees", "地方垫付，由其日后劳作分期偿还",
				"公保展期",
				"地方按户摊派资金先行清偿商债，再由债务人分期劳作归还公账。此举既安抚了底层情绪又稳住了生产，只是短期内加重了民众现金负担。",
				[
					Shared.cash_in(3, 540, "向本地人数最多的{primary_profession}征收其现金的 3%（先垫甘丙的债，再从工钱里扣）"),
					Shared.manufacturing(8, 540),
					Shared.bias(Ids.TAG_UNREST, 0.85, 540),
				]),
		],
	}))

	# ═══ 地契 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_LAW_DEED),
		"title": "{settlement_name}·地契",
		"body_text": "一份数十年前立下的残破地契引发了激烈的土地权属争端：契纸上的四至仅以早年河沟与古树为记，如今河道改移、树木枯死，根本无从核对。争议双方各执一词，一方主张严格依照旧地契文字划界，另一方则要求以泥土中挖出的古老石标为准。官署若不能给出清晰裁决，不仅这块良田将长期荒废，更会诱发全境的产权纠纷。",
		"image_key": "map.construction",
		"ai_visual_prompt": "An old land deed with worm-eaten edges beside a worn boundary stone on a clerk's desk, a farmer and a woman standing apart, dusk light",
		"tags": ["law", "land"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 720,
		"min_era_index": 2,
		"max_era_index": 8,
		"required_technologies": ["tech.writing"],
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
				"follow_the_deed", "严格依契，重丈田亩核发新证",
				"依契重丈",
				"官署派员重新丈量并核发清晰新契，确立了书面契约的最高效力。虽然丈量与登记费用由地方摊派，但农业生产与产权秩序双双受益。",
				[
					Shared.cash_in(3, 540, "向本地人数最多的{primary_profession}征收其现金的 3%（丈量与写新契的摊派）"),
					Shared.agriculture(8, 360),
					Shared.knowledge(8, 360),
				]),
			Shared.option(
				"follow_the_stone", "采信旧标，争议土地收归公用",
				"收归公地",
				"争议地块被划为地方公用土地，暂时平息了私人间的土地争讼并丰富了判例档案。但缺乏明确经营主体的土地很快荒芜，拖累了农业产出。",
				[
					Shared.agriculture(-10, 540),
					Shared.bias(Ids.TAG_LAND, 0.85, 540),
					Shared.knowledge(8, 360),
				]),
			Shared.option(
				"wait_a_year", "暂行查封，延至来年重新勘定",
				"封地待勘",
				"争议田亩被官署拉绳封存，严禁双方耕种。搁置裁决虽为文吏赢得了核查时间，但无端荒废的农田与漫长的等待激起了民众普遍不满。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.25, 540),
					Shared.knowledge(8, 360),
					Shared.bias(Ids.TAG_LAND, 0.90, 540),
				]),
		],
	}))

	# ═══ 伪证 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_LAW_WITNESS),
		"title": "{settlement_name}·伪证",
		"body_text": "一桩仓储失窃案的审理陷入僵局：证人名册上的关键证人前后证词截然相反，初审时坚称目击窃贼翻墙入仓，复审时却突然改口否认。主审官比对两份卷宗后发现，证人近期曾与涉案债主私下接触，极可能因债务胁迫而作伪证。司法威信已受公然挑衅，究竟是顺水推舟速结此案、严惩伪证者，还是彻底推翻卷宗重新侦讯，亟待裁断。",
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
				"take_the_second_story", "采信翻供，草草结案归档",
				"草率结案",
				"官署顺势采信了改口证词，案卷迅速封存，避免了作坊与商号的停业牵连。但公然姑息伪证重创了司法公信，民间对官商勾结的质疑四起。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.25, 540),
					Shared.manufacturing(8, 360),
				]),
			Shared.option(
				"lock_the_witness", "以伪证罪收监，逼其交代实情",
				"严惩伪证",
				"改口证人被立即投入羁押，数日后便吐露了受胁迫的实情。严厉打击伪证维护了法制尊严与文书严谨，代价是地方分摊了额外的司法开销。",
				[
					Shared.cash_in(3, 540, "向本地人数最多的{primary_profession}征收其现金的 3%（牢饭与差役的摊派）"),
					Shared.knowledge(10, 540),
				]),
			Shared.option(
				"copy_the_roll_again", "推翻旧卷，逐一重审全部证人",
				"全面复审",
				"官署重录证人名册并逐一严密复核，最终还原了案件真相，大幅提升了司法权威与社会安定。然而冗长的复审冻结了涉案货物，令制造业受损。",
				[
					Shared.manufacturing(-10, 540),
					Shared.knowledge(15, 540),
					Shared.bias(Ids.TAG_UNREST, 0.85, 540),
				]),
		],
	}))

	# ═══ 赦免 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_LAW_PARDON),
		"title": "{settlement_name}·赦免",
		"body_text": "最高当局颁下盖有朱印的赦书，意在借政局更新之际推行大赦，向天下彰显宽仁以收拢人心。然而基层官署翻开卷宗后却陷入两难：羁押在册的不仅有因灾欠款的债囚，还包括数名伤人重犯。债权人警告，若将欠债者一并释放，商业信用将荡然无存；受害者家属亦强烈抗议赦免暴力罪犯。如何执行这道赦书，考验着仁政与法治的平衡。",
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
				"pardon_everyone", "全面大赦，释放所有在押人员",
				"全面开释",
				"所有在押人员悉数获释，为本地作坊补充了急需的劳力。但未加甄别的宽纵很快引发治安反弹，商民与受害者对治安恶化的怨愤迅速蔓延。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
					Shared.manufacturing(8, 360),
				]),
			Shared.option(
				"pardon_only_debtors", "区别对待，仅赦债囚严留重犯",
				"分流特赦",
				"欠债者获释返乡重拾农耕，暴力重犯则继续服刑以安抚受害者，社会情绪趋于缓和。但债主收回欠款无望，资金紧缩令本地制造业受挫。",
				[
					Shared.manufacturing(-10, 540),
					Shared.bias(Ids.TAG_UNREST, 0.85, 540),
					Shared.agriculture(8, 360),
				]),
			Shared.option(
				"commute_not_pardon", "不予释放，一律改为酌情减刑",
				"减刑留押",
				"官署顶住压力未放一人，仅按律缩减了部分刑期。严守法度提升了司法公信与行政素养，但维持满员羁押的日常开支仍需由地方承担。",
				[
					Shared.cash_in(3, 540, "向本地人数最多的{primary_profession}征收其现金的 3%（狱粮与修牢的摊派）"),
					Shared.knowledge(10, 540),
				]),
		],
	}))

	# ═══ 公证 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_LAW_NOTARY),
		"title": "{settlement_name}·公证",
		"body_text": "本地大商号拟向外地客商发运一批价值高昂的铁器，契纸上已写明货款与交割期限，却因买卖双方素未谋面而卡在公证担保环节。本地德高望重的专业保人愿意签字作保，但坚持抽取高额佣金以覆盖违约风险；客商代表嫌成本过高，宁可削减半数货量。官署的朱印就在案头，是否由政府直接介入担保以促成大宗贸易，成为摆在眼前的政策抉择。",
		"image_key": "country.economy",
		"ai_visual_prompt": "A contract on a desk with a blank guarantor line, a red seal in sunlight, iron goods loaded on a cart outside, a guarantor hesitating",
		"tags": ["law", "market"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 720,
		"min_era_index": 4,
		"max_era_index": 9,
		"required_technologies": ["tech.iron_smelting"],
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
				"pay_the_guarantor", "遵循商规，聘请专业保人公证",
				"商保成交",
				"专业保人正式签署担保契约，满载铁器的车队顺利启程，带动了本地贸易与制造活力。虽然佣金与契税摊派加重了短期成本，但风险得以隔离。",
				[
					Shared.trade_capacity(10, 360),
					Shared.manufacturing(8, 360),
					Shared.cash_in(3, 540, "向本地人数最多的{primary_profession}征收其现金的 3%（保钱与写契的摊派）"),
				]),
			Shared.option(
				"ship_half", "放弃担保，削减半数发货规模",
				"缩量慎行",
				"商号放弃担保并削减了半数货量，余货积压在库房中。此举虽规避了违约风险并稳住了市场秩序，却让本地冶铁制造业蒙受了订单损失。",
				[
					Shared.manufacturing(-10, 540),
					Shared.bias(Ids.TAG_MARKET, 0.85, 540),
				]),
			Shared.option(
				"let_the_county_stand", "由官署加盖朱印，提供免费公证",
				"官印兜底",
				"官署直接以公信力作保，促成了全额交易并大幅提振了商运与制造。然而入秋后外地客商违约潜逃，追偿纠纷瞬间涌向官署，引发剧烈风波。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
					Shared.trade_capacity(15, 360),
					Shared.manufacturing(8, 360),
				]),
		],
	}))
