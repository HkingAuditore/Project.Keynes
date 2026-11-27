class_name NarrativeEventCatalogFamily3
extends RefCounted

## 家族桥第二批：十二条。
##
## A 层（6 条，现有桥）：乳母、祠堂、牌坊、包税、族丁、义庄——族与官府的交易。
## B 层（6 条，读既有特质）：重农族、商帮、工匠族、书香门第、家大业大、沿海资本——
##   “这个族本来是什么，所以这件事只能这样办”。
##
## 约束：一条只改一个特质；三个选项代价货币不同；门槛至少一个家族维度 + 一个非家族维度；
## 撤特质只用于“这个族不再是原来的族”，不做惩罚性撤销。

const Ids = preload("res://scripts/narrative/narrative_event_ids.gd")
const Shared = preload("res://scripts/narrative/narrative_event_shared.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")
const NarrativeEffectSpecScript = preload("res://scripts/narrative/narrative_effect_spec.gd")

const TraitEvents = preload("res://scripts/narrative/narrative_event_catalog_family3_traits.gd")
const TraitChanges = preload("res://scripts/narrative/narrative_event_family_trait_changes.gd")

const PACK_ID := &"family3"
const PREFIX := "evt.family3."

const CAST := [
	"本地大族", "宗族长老", "地方官署", "宗祠", "行会", "度支司", "商帮", "族丁", "义庄", "族学", "商船队", "藏书楼",
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
		"title": "家族桥（二）",
		"theme": "族本来是什么，事情就只能怎么办",
		"era_band": "1-9",
		"prefix": PREFIX,
		"scale": "12 条中观/微观孤立",
		"cast": CAST,
		"node_ids": [
			String(Ids.EVT_FAMILY3_WET_NURSE),
			String(Ids.EVT_FAMILY3_ANCESTRAL_HALL),
			String(Ids.EVT_FAMILY3_SCHOLAR_BOARD),
			String(Ids.EVT_FAMILY3_TAX_FARM),
			String(Ids.EVT_FAMILY3_PRIVATE_ARM),
			String(Ids.EVT_FAMILY3_CHARITY_ESTATE),
			String(Ids.EVT_FAMILY3_ENCLOSURE_RESIST),
			String(Ids.EVT_FAMILY3_CHARTER_GUILD),
			String(Ids.EVT_FAMILY3_CRAFT_SPLIT),
			String(Ids.EVT_FAMILY3_LETTERS_RAID),
			String(Ids.EVT_FAMILY3_MAGNATE_TAX),
			String(Ids.EVT_FAMILY3_COASTAL_SHIFT),
		],
	}


static func append(catalog) -> void:
	if catalog == null:
		return
	var Op = NarrativeConditionScript.Op
	var Ch = NarrativeEventDefinitionScript.TriggerChannel

	# ═══ 乳母（A）════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY3_WET_NURSE),
		"title": "{settlement_name}·门第恩义",
		"body_text": "{settlement_name}本地大族的嫡系幼孙由一名河工遗孀哺育成人，如今大族准备将幼孙接回宗祠正院培养，遗孀遂登门请求确立干亲恩义以保晚年所依。宗族长老以严守门第礼法为由坚决拒斥，唯恐寒门攀附动摇族产继承；然而该遗孀之夫系殉职于官办河工，坊间舆论普遍对其抱以深切同情。地方官署受邀居中调停，须在维护世族体统与安抚寒门人心之间作出表态。",
		"image_key": "family.house",
		"ai_visual_prompt": "A wet nurse at a clan hall door holding a cloth bundle of tiny tiger-head shoes, an elder hesitating inside",
		"tags": ["family", "people"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 85,
		"cooldown_days": 900,
		"min_era_index": 1,
		"max_era_index": 6,
		"conditions": [
			{"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 1},
			{"op": Op.POPULATION_GTE, "int_value": 10},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 2},
				"add_weight": 20,
				"multiplier_q16": MUL_115,
				"reason": "族里有脸面，才怕人说",
			},
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 18},
				"add_weight": 15,
				"reason": "城大了，闲话传得快",
			},
		],
		"options": [
			Shared.option(
				"acknowledge_her", "准立恩亲，厚予赡养",
				"重情重义赢得民望",
				"大族在官署劝谕下正式承认这门恩亲并置产赡养，此举在全城传为美谈。本地大族由此赢得忠厚声望，民间婚育氛围向好，官府政声亦随之提升。",
				[
					TraitChanges.grant("j017_loyal", "老实"),
					Shared.birth(10, 540),
					Shared.bias(Ids.TAG_COURT, 1.15, 540),
				]),
			Shared.option(
				"pay_her_off", "官族合资，重金遣散",
				"银钱了断各不相欠",
				"国库协同大族拨付一笔丰厚遣散银两，换取遗孀不再主张名分。风波虽以金钱平稳了结，但冷峻的交易方式并未赢得坊间多少好感。",
				[
					Shared.cash_out(3, 360),
				]),
			Shared.option(
				"refuse_her", "恪守门第，断然拒斥",
				"薄情寡义舆论哗然",
				"宗祠大门紧闭，遗孀被拒之门外。大族冷酷无情的举动迅速引发全城清议挞伐，本地文教声誉受损，底层寒门对豪强与官府的怨怼暗中滋长。",
				[
					Shared.knowledge(-8, 360),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
		],
	}))

	# ═══ 祠堂（A）════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY3_ANCESTRAL_HALL),
		"title": "{settlement_name}·宗祠越界",
		"body_text": "{settlement_name}的本地大族近期大兴土木扩建宗祠，其划定的新地基竟公然越界压占了城区主干官道。宗族长老声称工程全由族中自筹，无需官府多加置喙；但过往商旅车马被迫绕行，怨声已传至地方官署。若纵容豪强侵吞公共路权，市政法度将形同虚设；若强令停工拆除，又恐与本地头号望族彻底交恶。",
		"image_key": "family.house",
		"ai_visual_prompt": "A clan hall expansion line running from the threshold into a busy street, carts detouring, masons waiting",
		"tags": ["family", "court", "law"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 85,
		"cooldown_days": 720,
		"min_era_index": 2,
		"max_era_index": 7,
		"conditions": [
			{"op": Op.FAMILY_OWNS_BUILDINGS_GTE, "int_value": 1},
			{"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 2},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.FAMILY_OWNS_BUILDINGS_GTE, "int_value": 2},
				"add_weight": 20,
				"multiplier_q16": MUL_115,
				"reason": "族里的屋子已经连成片",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
				"add_weight": 15,
				"reason": "街面挤，扩一寸都扎眼",
			},
		],
		"options": [
			Shared.option(
				"let_him_expand", "特批越界，准予扩建",
				"官道退让豪强坐大",
				"地方官署签发特许批文，官道被迫向豪强退让。大族借此彰显了显赫的士绅门第，但特权开先例后推高了本地营造规费，商民对此颇多微词。",
				[
					TraitChanges.grant("j020_gentry", "士绅门第"),
					Shared.build_cost(8, 540),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
			Shared.option(
				"half_the_size", "勒令退线，罚没占地款",
				"退线缩建折中了结",
				"官署强令宗祠地基后退半幅并缴纳占地罚金，保住了主干官道畅通。大族虽勉强妥协，但停工改图与怨气短暂拖累了本地营造与制造进度。",
				[
					Shared.manufacturing(-8, 360),
					Shared.cash_in(3, 360),
				]),
			Shared.option(
				"forbid_it", "严禁动土，维护官道",
				"强硬叫停官族交恶",
				"官署断然驳回扩建图样，责令即刻撤线停工。公共路权得以严格维护，但大族颜面扫地，不仅缩减了对本地文教的资助，更令地方暗流涌动。",
				[
					Shared.knowledge(-8, 360),
					Shared.bias(Ids.TAG_UNREST, 1.25, 540),
				]),
		],
	}))

	# ═══ 牌坊（A）════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY3_SCHOLAR_BOARD),
		"title": "{settlement_name}·科第牌坊",
		"body_text": "{settlement_name}本地大族经族学多年耕耘，终有子弟在科考中名列前茅。宗族长老兴师动众运来大批石料，执意在全城最繁华的三岔要冲树立高大功名牌坊，以昭示门第荣耀。地方官署提醒此类大型石构须经朝廷核准且不得阻塞交通，但大族已将石料堆满路口，催促官府即刻放行。是顺势旌表文风、折现充公，还是严守审批程序？",
		"image_key": "family.house",
		"ai_visual_prompt": "Cut stone blocks piled at a crossroads for a memorial arch, children climbing them, an official with a report",
		"tags": ["family", "school", "court"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 85,
		"cooldown_days": 720,
		"min_era_index": 3,
		"max_era_index": 8,
		"required_technologies": ["tech.writing"],
		"conditions": [
			{"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 3},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "scholar", "float_value": 0.01},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 4},
				"add_weight": 20,
				"multiplier_q16": MUL_115,
				"reason": "族里等这块牌子等了几代",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "scholar", "float_value": 0.02},
				"add_weight": 15,
				"reason": "城里读书人多，牌子才有人看",
			},
		],
		"options": [
			Shared.option(
				"raise_the_arch", "拨款助建，旌表书香",
				"牌坊落成文风大振",
				"官府拨款补贴营建，巍峨石牌坊矗立于要冲之上。本地大族正式确立书香门第的尊荣，极大激励了全城士子向学之风，本地知识产出随之攀升。",
				[
					TraitChanges.grant("j009_letters", "书香门第"),
					Shared.knowledge(10, 540),
					Shared.cash_out(3, 360),
				]),
			Shared.option(
				"turn_it_into_money", "劝令节俭，折银入公",
				"石料变现充实公库",
				"官署劝说大族放弃奢华牌坊，将石料变现并按例抽成入库。国库借此获得一笔进项，但缺乏显赫旌表令本地读书人的进取热情略有降温。",
				[
					Shared.cash_in(4, 360),
					Shared.knowledge(-5, 360),
				]),
			Shared.option(
				"wait", "严守旧制，暂缓批复",
				"审批拖延士族寒心",
				"呈文在繁琐的官僚程序中一再搁置，成堆石料在路口日晒雨淋。本地大族与士绅阶层倍感冷落，文教氛围随之低迷，对官府的积怨悄然滋长。",
				[
					Shared.knowledge(-8, 360),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
		],
	}))

	# ═══ 包税（A）════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY3_TAX_FARM),
		"title": "{settlement_name}·地方包税",
		"body_text": "{settlement_name}的常规税赋征收连年拖欠，度支司人手捉襟见肘。财势显赫的本地大族趁机向地方官署递交方案，愿以自有账房、仓廪与车马承包全城税政，并承诺先行垫付定额税款。宗族长老极力标榜包税之高效，但熟悉史鉴的幕僚发出警告：一旦将国家征税权外包予地方豪强，其势必借机加派盘剥，令朝廷失去对基层的直接掌控。",
		"image_key": "country.economy",
		"ai_visual_prompt": "A clan elder at an abacus considering a tax-farming contract, taxpayers queuing in the rain outside a yamen",
		"tags": ["family", "fiscal", "market"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 720,
		"min_era_index": 3,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 4},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.02},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 5},
				"add_weight": 20,
				"multiplier_q16": MUL_120,
				"reason": "只有这种族垫得起",
			},
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "wheat_grain", "float_value": 1.15},
				"add_weight": 15,
				"reason": "粮价一高，税就难收",
			},
		],
		"options": [
			Shared.option(
				"take_the_farm", "核准包税，外包豪强",
				"包税增收民怨骤起",
				"税册移交大族账房，国库迅速收足了丰厚的承包税款，该族亦借税网拓展了商路人脉。然而豪强征税手段严苛，坊间怨声载道，动荡风险剧增。",
				[
					TraitChanges.grant("i019_trade", "商路人脉"),
					Shared.cash_in(5, 360),
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
				]),
			Shared.option(
				"keep_it_official", "增派税吏，官府直征",
				"坚持直征保住税权",
				"度支司拒绝交出征税权，改以增派差役的方式继续直接征管。税款虽仍稳步入库，但冗长的查验程序牵制了部分工商业效率，收缴进度略显迟缓。",
				[
					Shared.cash_in(3, 360),
					Shared.manufacturing(-8, 360),
				]),
			Shared.option(
				"decline", "驳回包税，维持现状",
				"税政僵局依旧难解",
				"官署既未外包税权，也未增派人手，税政积弊照旧延续。征税队伍每日大排长龙，行政低效引发的民间焦躁情绪在城中缓缓发酵。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.10, 540),
				]),
		],
	}))

	# ═══ 族丁（A）════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY3_PRIVATE_ARM),
		"title": "{settlement_name}·宗族私兵",
		"body_text": "{settlement_name}的本地大族近来在宗祠后院频繁操练族丁，如今更呈报要求将武装护院扩编至数十人之众，名册中半数皆为该族佃户子弟。宗族长老宣称此举仅为护卫仓廪与商货免遭盗匪劫掠，但地方官署对此深感警觉。国家律法严禁民间私蓄重兵，若听任豪强坐拥成建制武装，一旦时局有变，地方将彻底尾大不掉。",
		"image_key": "map.construction",
		"ai_visual_prompt": "Clan retainers drilling behind an ancestral hall, a register open at a newly added page, an official watching",
		"tags": ["family", "frontier", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 85,
		"cooldown_days": 720,
		"min_era_index": 3,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 4},
			{"op": Op.FAMILY_OWNS_BUILDINGS_GTE, "int_value": 2},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 5},
				"add_weight": 20,
				"multiplier_q16": MUL_120,
				"reason": "族里养得起这么多人",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 4},
				"add_weight": 10,
				"reason": "兵戈的年代，护院才有用",
			},
		],
		"options": [
			Shared.option(
				"let_him_drill", "默许扩编，借以护境",
				"私兵成军隐患深植",
				"官府默许大族扩编族丁，武装护卫确实分担了部分军需转运与防务压力。然而这支只听命于宗祠的武装令豪强气焰大涨，地方割据与动荡的阴影骤然加重。",
				[
					TraitChanges.grant("j016_shrewd", "精明"),
					Shared.supply(8, 360),
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
				]),
			Shared.option(
				"disband_them", "拨款赎兵，勒令遣散",
				"私兵解散回归法度",
				"国库拨付一笔安抚补偿，责令大族即刻缴械遣散族丁。国家对武装的垄断权得以重申，该族亦在官府威严下收敛锋芒，展现出顺从守法的姿态。",
				[
					Shared.cash_out(4, 360),
					TraitChanges.grant("j017_loyal", "老实"),
				]),
			Shared.option(
				"absorb_them", "收编官册，改充乡勇",
				"族丁改籍亦官亦私",
				"地方官署将族丁编入官方乡勇名册并要求大族分摊军费，显著提升了战时补给与协防能力。但双重效忠的模糊体制仍令民间对豪强借官势欺人充满戒备。",
				[
					Shared.supply(8, 360),
					Shared.cash_in(3, 360),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
		],
	}))

	# ═══ 义庄（A）════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY3_CHARITY_ESTATE),
		"title": "{settlement_name}·宗族义庄",
		"body_text": "面对日益凸显的贫富分化，{settlement_name}的本地大族提议划拨大片公田设立义庄，以田租收益长年赡养孤寡贫户。宗族长老请求地方官署核发正式名分并减免田契手续。官署幕僚就此展开激辩：允许大族操办义庄可极大减轻官府救济压力，但也会让底层民众对宗族的依附超越对国家的效忠。",
		"image_key": "family.house",
		"ai_visual_prompt": "A charity estate house with a blank wooden plaque, a list of names pasted on the wall, sacks of grain inside",
		"tags": ["family", "people", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 85,
		"cooldown_days": 720,
		"min_era_index": 2,
		"max_era_index": 9,
		"conditions": [
			{"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 2},
			{"op": Op.POPULATION_GTE, "int_value": 15},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 3},
				"add_weight": 15,
				"multiplier_q16": MUL_115,
				"reason": "族里有田，才设得起义庄",
			},
			{
				"condition": {"op": Op.COHORT_SATISFACTION_LTE, "float_value": 0.50},
				"add_weight": 20,
				"reason": "日子难过，孤寡先撑不住",
			},
		],
		"options": [
			Shared.option(
				"let_him_found_it", "核准设庄，依律过契",
				"义庄开张惠及贫户",
				"地方官署依律征收过户规费后核准设庄，义庄迅速开始按册发放救济粮。全城底层口粮压力明显缓解，大族亦借此举树立了忠厚仁善的地方声望。",
				[
					TraitChanges.grant("j017_loyal", "老实"),
					Shared.staple(-12, 360),
					Shared.cash_in(3, 360),
				]),
			Shared.option(
				"match_half", "官族合办，各出其半",
				"官民共济建立新制",
				"国库拨款与大族公田共同组建公私合营义庄，救济覆盖面大幅扩大。此举既稳住了主食保障，也确保了国家在地方福利体系中的主导权与治理经验。",
				[
					Shared.cash_out(5, 360),
					Shared.staple(-10, 360),
					Shared.knowledge(8, 360),
				]),
			Shared.option(
				"refuse", "驳回请愿，禁设义庄",
				"义庄流产民生愈艰",
				"官署出于防范豪强收买人心的考量断然否决设庄计划。孤寡贫户失去指望，本地基本口粮负担愈发沉重，社会底层的不满情绪在寒冬中迅速积聚。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
					Shared.staple(10, 360),
				]),
		],
	}))

	TraitEvents.append(catalog, MUL_115, MUL_120)
