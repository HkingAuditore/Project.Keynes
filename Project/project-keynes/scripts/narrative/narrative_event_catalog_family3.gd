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


static func _grant(trait_key: String, display_name: String) -> Dictionary:
	return {
		"kind": NarrativeEffectSpecScript.Kind.GRANT_FAMILY_TRAIT,
		"target_key": trait_key,
		"magnitude_q16": 65536,
		"duration_days": 1,
		"custom_label": "本地最大族「{family_name}」获特质「%s」，永久" % display_name,
	}


static func _remove(trait_key: String, display_name: String) -> Dictionary:
	return {
		"kind": NarrativeEffectSpecScript.Kind.REMOVE_FAMILY_TRAIT,
		"target_key": trait_key,
		"duration_days": 1,
		"custom_label": "本地最大族「{family_name}」失去特质「%s」" % display_name,
	}


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
					_grant("j017_loyal", "老实"),
					Shared.birth(3, 540),
					Shared.bias(Ids.TAG_COURT, 1.15, 540),
				]),
			Shared.option(
				"pay_her_off", "官族合资，重金遣散",
				"银钱了断各不相欠",
				"国库协同大族拨付一笔丰厚遣散银两，换取遗孀不再主张名分。风波虽以金钱平稳了结，但冷峻的交易方式并未赢得坊间多少好感。",
				[
					Shared.cash_out(1.0, 360),
				]),
			Shared.option(
				"refuse_her", "恪守门第，断然拒斥",
				"薄情寡义舆论哗然",
				"宗祠大门紧闭，遗孀被拒之门外。大族冷酷无情的举动迅速引发全城清议挞伐，本地文教声誉受损，底层寒门对豪强与官府的怨怼暗中滋长。",
				[
					Shared.knowledge(-2, 360),
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
					_grant("j020_gentry", "士绅门第"),
					Shared.build_cost(3, 540),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
			Shared.option(
				"half_the_size", "勒令退线，罚没占地款",
				"退线缩建折中了结",
				"官署强令宗祠地基后退半幅并缴纳占地罚金，保住了主干官道畅通。大族虽勉强妥协，但停工改图与怨气短暂拖累了本地营造与制造进度。",
				[
					Shared.manufacturing(-2, 360),
					Shared.cash_in(1.0, 360),
				]),
			Shared.option(
				"forbid_it", "严禁动土，维护官道",
				"强硬叫停官族交恶",
				"官署断然驳回扩建图样，责令即刻撤线停工。公共路权得以严格维护，但大族颜面扫地，不仅缩减了对本地文教的资助，更令地方暗流涌动。",
				[
					Shared.knowledge(-2, 360),
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
					_grant("j009_letters", "书香门第"),
					Shared.knowledge(3, 540),
					Shared.cash_out(1.0, 360),
				]),
			Shared.option(
				"turn_it_into_money", "劝令节俭，折银入公",
				"石料变现充实公库",
				"官署劝说大族放弃奢华牌坊，将石料变现并按例抽成入库。国库借此获得一笔进项，但缺乏显赫旌表令本地读书人的进取热情略有降温。",
				[
					Shared.cash_in(1.5, 360),
					Shared.knowledge(-1, 360),
				]),
			Shared.option(
				"wait", "严守旧制，暂缓批复",
				"审批拖延士族寒心",
				"呈文在繁琐的官僚程序中一再搁置，成堆石料在路口日晒雨淋。本地大族与士绅阶层倍感冷落，文教氛围随之低迷，对官府的积怨悄然滋长。",
				[
					Shared.knowledge(-2, 360),
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
					_grant("i019_trade", "商路人脉"),
					Shared.cash_in(2.0, 360),
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
				]),
			Shared.option(
				"keep_it_official", "增派税吏，官府直征",
				"坚持直征保住税权",
				"度支司拒绝交出征税权，改以增派差役的方式继续直接征管。税款虽仍稳步入库，但冗长的查验程序牵制了部分工商业效率，收缴进度略显迟缓。",
				[
					Shared.cash_in(1.0, 360),
					Shared.manufacturing(-2, 360),
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
					_grant("j016_shrewd", "精明"),
					Shared.supply(8, 360),
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
				]),
			Shared.option(
				"disband_them", "拨款赎兵，勒令遣散",
				"私兵解散回归法度",
				"国库拨付一笔安抚补偿，责令大族即刻缴械遣散族丁。国家对武装的垄断权得以重申，该族亦在官府威严下收敛锋芒，展现出顺从守法的姿态。",
				[
					Shared.cash_out(1.5, 360),
					_grant("j017_loyal", "老实"),
				]),
			Shared.option(
				"absorb_them", "收编官册，改充乡勇",
				"族丁改籍亦官亦私",
				"地方官署将族丁编入官方乡勇名册并要求大族分摊军费，显著提升了战时补给与协防能力。但双重效忠的模糊体制仍令民间对豪强借官势欺人充满戒备。",
				[
					Shared.supply(8, 360),
					Shared.cash_in(1.0, 360),
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
					_grant("j017_loyal", "老实"),
					Shared.staple(-4, 360),
					Shared.cash_in(0.5, 360),
				]),
			Shared.option(
				"match_half", "官族合办，各出其半",
				"官民共济建立新制",
				"国库拨款与大族公田共同组建公私合营义庄，救济覆盖面大幅扩大。此举既稳住了主食保障，也确保了国家在地方福利体系中的主导权与治理经验。",
				[
					Shared.cash_out(2.0, 360),
					Shared.staple(-3, 360),
					Shared.knowledge(2, 360),
				]),
			Shared.option(
				"refuse", "驳回请愿，禁设义庄",
				"义庄流产民生愈艰",
				"官署出于防范豪强收买人心的考量断然否决设庄计划。孤寡贫户失去指望，本地基本口粮负担愈发沉重，社会底层的不满情绪在寒冬中迅速积聚。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
					Shared.staple(3, 360),
				]),
		],
	}))

	# ═══ 重农族（B）══════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY3_ENCLOSURE_RESIST),
		"title": "{settlement_name}·圈地抗争",
		"body_text": "随着近代毛纺与肉食需求激增，商营牧场正向{settlement_name}城郊大举扩张，并获准圈占大片土地，其中恰巧包含世代重农的本地大族核心田产。宗族长老愤然退回地方官署送达的补偿文书，痛斥圈地是断绝农家命脉；牧场投资方则强调集约畜牧的收益远胜传统耕作。在旧农本秩序与新资本浪潮的正面冲撞中，官府必须选边站队。",
		"image_key": "economy.resource",
		"ai_visual_prompt": "A farming clan elder refusing an enclosure document, a polished ploughshare hanging on the wall, pasture stakes outside",
		"tags": ["family", "land", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 900,
		"min_era_index": 6,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.HAS_FAMILY_TRAIT, "target_key": "i001_agrarian", "bool_value": true},
			{"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 2},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 3},
				"add_weight": 20,
				"multiplier_q16": MUL_120,
				"reason": "这一族挡得住圈地",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "agricultural_worker", "float_value": 0.20},
				"add_weight": 15,
				"reason": "种地的人还多",
			},
		],
		"options": [
			Shared.option(
				"force_the_enclosure", "强行圈地，推进牧业",
				"强制圈地激化冲突",
				"官署动用武力完成圈地，重农大族被迫放弃祖传耕作传统。集约化经营显著提升了城郊农业总产出，但强拆与夺地引发的激烈对抗令全城动荡不安。",
				[
					_remove("i001_agrarian", "重农"),
					Shared.agriculture(5, 540),
					Shared.bias(Ids.TAG_UNREST, 1.35, 540),
				]),
			Shared.option(
				"trade_land", "国库贴补，异地置换",
				"易地拓荒双赢收场",
				"国库拨款补偿并为该族在河对岸划拨水利更佳的新垦区。大族顺势转型为锐意进取的拓荒力量，新旧产业各得其所，本地农业产出稳步增长。",
				[
					Shared.cash_out(2.0, 360),
					Shared.agriculture(2, 540),
					_grant("i025_pioneer", "拓荒者"),
				]),
			Shared.option(
				"drop_it", "叫停圈地，保全农田",
				"农田得保工商受阻",
				"地方官署撤销了圈地许可，传统农田安然无恙，城郊紧张气氛随之缓和。但牧场与下游毛纺原料供应计划被迫搁浅，本地制造业扩张步伐明显放缓。",
				[
					Shared.manufacturing(-3, 360),
					Shared.bias(Ids.TAG_UNREST, 0.90, 360),
				]),
		],
	}))

	# ═══ 商帮（B）════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY3_CHARTER_GUILD),
		"title": "{settlement_name}·商路特许",
		"body_text": "{settlement_name}深耕商路的本地大族向地方官署呈上外邦特许状样本，请求独占北方长途商路的经营权，并愿向度支司缴纳高额特许保证金。城内其余商帮闻讯立刻联合抗议，指责私授垄断特许将彻底扼杀公平竞争，要求实行公开招标。官署面临经典的重商主义抉择：是扶持一家超级寡头以迅速打通商路，还是维护公开竞价以保市场平衡？",
		"image_key": "country.economy",
		"ai_visual_prompt": "A merchant clan leader with a sample charter under a bronze seal, rival clerks loitering outside the window",
		"tags": ["family", "market", "trade"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 720,
		"min_era_index": 4,
		"max_era_index": 7,
		"conditions": [
			{"op": Op.HAS_FAMILY_TRAIT, "target_key": "i019_trade", "bool_value": true},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.03},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 4},
				"add_weight": 20,
				"multiplier_q16": MUL_120,
				"reason": "这种族才拿得出保证金",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.05},
				"add_weight": 15,
				"reason": "商号多，盯着这条路的人也多",
			},
		],
		"options": [
			Shared.gamble(
				"grant_the_charter", "授予特许，独占商路",
				Shared.branch(39322, "特许商路财源广进", # 60%
					"特许状落地后，该族车队迅速垄断北方皮货贸易，跻身家大业大的豪商巨贾。全国贸易运力大幅提升，稳定的特许收益亦随之充实国库。",
					[
						_grant("i026_magnate", "家大业大"),
						Shared.trade_capacity(6, 540),
						Shared.cash_in(1.0, 360),
					]),
				Shared.branch(26214, "同行控告特许暂扣", # 40%
					"其余商帮联名状告官商勾结，朝廷被迫介入暂扣特许状彻查。官府虽没收了部分保证金，但混乱的调查过程令本地制造与商贸双双受挫，怨声四起。",
					[
						Shared.cash_in(1.0, 360),
						Shared.manufacturing(-3, 360),
						Shared.bias(Ids.TAG_UNREST, 1.25, 540),
					])),
			Shared.option(
				"open_bidding", "公开招标，价高者得",
				"公开竞标国库大赚",
				"度支司主持了激烈竞标，商路由出价更高的外来商帮夺得，国库收获丰厚标金。失标的本地大族被迫改走水路，对官府的怨怼却已悄然结下。",
				[
					Shared.cash_in(2.0, 360),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
			Shared.option(
				"turn_it_down", "驳回特许，暂不开禁",
				"商路冷清众商失望",
				"地方官署退回了特许呈文，北方商路继续处于无序分散状态。缺乏大商帮统筹致使北来原料与货流缩减，本地手工业随之降温，商界颇多怨言。",
				[
					Shared.manufacturing(-3, 360),
					Shared.bias(Ids.TAG_UNREST, 1.10, 540),
				]),
		],
	}))

	# ═══ 工匠族（B）══════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY3_CRAFT_SPLIT),
		"title": "{settlement_name}·工匠分家",
		"body_text": "{settlement_name}的工匠世家本地大族近年培养了大批熟练匠人，并压低工价广揽订单，彻底触怒了当地传统行会。行会执事援引旧章，仅承认其不到半数的师徒名额，指责该族破坏行业定价体系；大族工场则以全面停工相威胁，要求脱离行会自立门户。大批学徒夹在中间进退维谷，地方官署必须裁定这场关乎生产组织形态的路线之争。",
		"image_key": "map.construction",
		"ai_visual_prompt": "Craftsmen facing a guild steward at a workshop door, apprentices standing between them, a tool chest half closed",
		"tags": ["family", "labor", "market"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 720,
		"min_era_index": 4,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.HAS_FAMILY_TRAIT, "target_key": "j004_craft", "bool_value": true},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "artisan", "float_value": 0.10},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "artisan", "float_value": 0.15},
				"add_weight": 20,
				"multiplier_q16": MUL_120,
				"reason": "匠户成街，行会才压得住",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
				"add_weight": 15,
				"reason": "作坊多，活才抢得起来",
			},
		],
		"options": [
			Shared.option(
				"back_the_clan", "支持大族，打破行会",
				"制造世家自立门户",
				"地方官署批准大族工场脱离行会独立经营，该族迅速转型为高效扩张的制造世家。订单纷至沓来，本地制造业产出与工具供给双双迎来跃升。",
				[
					_grant("i003_manufacturing", "制造世家"),
					Shared.manufacturing(4, 540),
					Shared.tools(5, 540),
				]),
			Shared.option(
				"back_the_guild", "维护行会，削减名额",
				"行会胜出产能回落",
				"官署裁定严格执行行会名额限制，多余匠人被迫转行离去，大族从此失去工匠世家根基。传统行业秩序与街面稳定得以维持，但本地制造产能显著萎缩。",
				[
					_remove("j004_craft", "工匠世家"),
					Shared.manufacturing(-4, 360),
					Shared.bias(Ids.TAG_UNREST, 0.90, 360),
				]),
			Shared.option(
				"mediate", "出资斡旋，折中妥协",
				"勉强调停暗流未息",
				"国库拨款补贴了部分学徒安置费用，换取行会放宽名额、大族上调工价。表面上的僵局虽暂告化解，但新旧生产体制间的深层矛盾并未根除。",
				[
					Shared.cash_out(1.5, 360),
					Shared.bias(Ids.TAG_UNREST, 1.10, 540),
				]),
		],
	}))

	# ═══ 查书（B）════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY3_LETTERS_RAID),
		"title": "{settlement_name}·藏书风波",
		"body_text": "{settlement_name}素负盛名的书香门第近来卷入了一场文禁风波，有人检举其本地大族藏书楼中私藏多部讥议时政的违禁古籍。地方官署已派员封锁院落准备清查，宗族长老则死守书架，力陈这批典籍乃数代先贤批注的心血孤本，毁之无异于断绝本地文脉。是严厉查抄以肃思想，还是网开一面以全学术，决策已呈至御案。",
		"image_key": "family.house",
		"ai_visual_prompt": "A clan library being searched, an elder's hand resting on a book spine, clerks waiting in the courtyard",
		"tags": ["family", "school", "court"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 85,
		"cooldown_days": 900,
		"min_era_index": 3,
		"max_era_index": 8,
		"conditions": [
			{"op": Op.HAS_FAMILY_TRAIT, "target_key": "j009_letters", "bool_value": true},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "scholar", "float_value": 0.01},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 3},
				"add_weight": 20,
				"multiplier_q16": MUL_115,
				"reason": "这种族的书楼才有人惦记",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "scholar", "float_value": 0.02},
				"add_weight": 15,
				"reason": "城里读书人多，书才传得开",
			},
		],
		"options": [
			Shared.option(
				"shield_the_books", "网开一面，保全典籍",
				"藏书得保文脉大盛",
				"朝廷下令撤回查抄人员，藏书楼得以完好保留。本地大族深受感召，倾力资助学术研究，全城知识产出大幅跃升，但宽松的舆论氛围也让激进思潮暗中滋长。",
				[
					_grant("i005_knowledge", "学术赞助"),
					Shared.knowledge(5, 540),
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
				]),
			Shared.option(
				"hand_it_over", "依法收缴，封存禁书",
				"禁书收缴清议消声",
				"违禁典籍被装匣封存带走，大族书香门第的荣耀随之凋零。城中异议声音迅速沉寂，社会秩序趋于安定，但本地学术研究与思想活力也蒙受重创。",
				[
					_remove("j009_letters", "书香门第"),
					Shared.knowledge(-4, 360),
					Shared.bias(Ids.TAG_UNREST, 0.90, 360),
				]),
			Shared.option(
				"burn_half", "择要销毁，留存残卷",
				"半数焚毁折中结案",
				"官署拨付安抚款项并采取折中处置，仅当众销毁敏感卷帙，默许大族保留其余学术注疏。风波得以体面平息，但典籍残缺仍令本地知识积累略有倒退。",
				[
					Shared.knowledge(-2, 360),
					Shared.cash_out(1.0, 360),
				]),
		],
	}))

	# ═══ 抗税（B）════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY3_MAGNATE_TAX),
		"title": "{settlement_name}·豪强抗税",
		"body_text": "朝廷新颁的商税告示刚在{settlement_name}张贴，手握全城商业命脉的本地大族便串联商帮半闭铺门，以变相罢市抵制新政。宗族长老向地方官署施压，声称加税将令全城商贸瘫痪；度支司则严词敦促强硬执法，警告若在豪强抗税面前退缩，全国税法尊严将荡然无存。市面交易正迅速降温，朝廷必须立刻亮明态度。",
		"image_key": "country.economy",
		"ai_visual_prompt": "A shuttered clan shop at the south gate, a tax notice taken down and rolled, a new smaller price board",
		"tags": ["family", "fiscal", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 720,
		"min_era_index": 5,
		"max_era_index": 9,
		"conditions": [
			{"op": Op.HAS_FAMILY_TRAIT, "target_key": "i026_magnate", "bool_value": true},
			{"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 4},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 5},
				"add_weight": 20,
				"multiplier_q16": MUL_120,
				"reason": "这样的族一关铺子，半条街都看得见",
			},
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "wheat_grain", "float_value": 1.20},
				"add_weight": 15,
				"reason": "米价高，税更收不上来",
			},
		],
		"options": [
			Shared.option(
				"collect_it_anyway", "严厉执法，照章强征",
				"铁腕征税商界震动",
				"度支司派员强行核查账簿并照章足额征税，国库进项极为丰厚。但数家老字号商铺随之关停，街市冷清，商民对高压税政的愤怒迅速蔓延。",
				[
					Shared.cash_in(2.5, 360),
					Shared.bias(Ids.TAG_UNREST, 1.35, 540),
				]),
			Shared.option(
				"negotiate", "私下磋商，酌情减让",
				"妥协减税商路更畅",
				"官署与大族达成闭门协议，略微减让税率换取商帮全面复市。国库仍获得稳健税收，大族则借此进一步拓展商路人脉，带动了全国贸易运力。",
				[
					Shared.cash_in(1.0, 360),
					Shared.trade_capacity(3, 540),
					_grant("i019_trade", "商路人脉"),
				]),
			Shared.option(
				"exempt_them", "暂缓新税，豁免本季",
				"豁免新税权威受损",
				"加税告示被悄然撤回，商铺全面复业并带动本地工商业小幅回暖。然而豪强以罢市逼退政令的先例迅速传开，各方势力皆在蠢蠢欲动。",
				[
					Shared.manufacturing(2, 360),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
		],
	}))

	# ═══ 转产（B）════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_FAMILY3_COASTAL_SHIFT),
		"title": "{settlement_name}·资本转型",
		"body_text": "随着蒸汽轮船与现代机器工业兴起，{settlement_name}手握沿海资本的本地大族正站在时代十字路口。港口关税日重、帆船航运利润微薄，族中少壮派力主变卖老旧商船队，将全部资本投入城外新建现代纺织厂；守旧的宗族长老却坚持航运乃祖业根基，不愿孤注一掷。地方官署受邀评估两套产业方案，朝廷的政策倾斜将决定这股地方资本的流向。",
		"image_key": "hydrology.water",
		"ai_visual_prompt": "A clan shipowner weighing two account sheets, harbour and a factory site outside the window, a steamer arriving",
		"tags": ["family", "sea", "market"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 720,
		"min_era_index": 6,
		"max_era_index": 9,
		"conditions": [
			{"op": Op.HAS_FAMILY_TRAIT, "target_key": "i029_coastal", "bool_value": true},
			{"op": Op.ERA_GTE, "int_value": 6},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 3},
				"add_weight": 20,
				"multiplier_q16": MUL_120,
				"reason": "这种族才转得动",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 5},
				"add_weight": 15,
				"reason": "城里有厂，才谈得上转产",
			},
		],
		"options": [
			Shared.option(
				"shift_to_factory", "补贴转型，兴办工厂",
				"海商转型工业巨擘",
				"国库提供产业转型补贴，大族果断卖船建厂，蜕变为雄心勃勃的制造世家。老旧船坞虽归沉寂，但城外彻夜轰鸣的机器将本地工业产能推上新高。",
				[
					_grant("i003_manufacturing", "制造世家"),
					Shared.manufacturing(5, 540),
					Shared.cash_out(2.0, 360),
				]),
			Shared.option(
				"keep_the_fleet", "扶持航运，维持船队",
				"坚守海运错失工业",
				"官署顺应守旧派诉求，协助修缮扩充商船队，全国海运贸易容量得以稳固。但错失工业化转型的窗口，也令本地制造业发展略显滞后。",
				[
					Shared.trade_capacity(4, 540),
					Shared.manufacturing(-2, 360),
				]),
			Shared.option(
				"hedge_both", "两头兼顾，分资并进",
				"分散投资难成气候",
				"官府出资协调大族同时保留半数船队与小规模厂房。资本分散致使两边皆难成规模，既耗费了财政补贴，也让族内新旧两派的路线争执久拖不决。",
				[
					Shared.cash_out(2.0, 360),
					Shared.bias(Ids.TAG_UNREST, 1.10, 540),
				]),
		],
	}))
