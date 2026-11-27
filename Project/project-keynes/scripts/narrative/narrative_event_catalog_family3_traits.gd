extends RefCounted

## Family events prompted by traits a clan already has.

const Ids = preload("res://scripts/narrative/narrative_event_ids.gd")
const Shared = preload("res://scripts/narrative/narrative_event_shared.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")
const TraitChanges = preload("res://scripts/narrative/narrative_event_family_trait_changes.gd")


static func append(catalog, mul_115: int, mul_120: int) -> void:
	var Op = NarrativeConditionScript.Op
	var Ch = NarrativeEventDefinitionScript.TriggerChannel

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
		"required_technologies": ["tech.commercial_estates"],
		"conditions": [
			{"op": Op.HAS_FAMILY_TRAIT, "target_key": "i001_agrarian", "bool_value": true},
			{"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 2},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 3},
				"add_weight": 20,
				"multiplier_q16": mul_120,
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
					TraitChanges.remove("i001_agrarian", "重农"),
					Shared.agriculture(15, 540),
					Shared.bias(Ids.TAG_UNREST, 1.35, 540),
				]),
			Shared.option(
				"trade_land", "国库贴补，异地置换",
				"易地拓荒双赢收场",
				"国库拨款补偿并为该族在河对岸划拨水利更佳的新垦区。大族顺势转型为锐意进取的拓荒力量，新旧产业各得其所，本地农业产出稳步增长。",
				[
					Shared.cash_out(5, 360),
					Shared.agriculture(8, 540),
					TraitChanges.grant("i025_pioneer", "拓荒者"),
				]),
			Shared.option(
				"drop_it", "叫停圈地，保全农田",
				"农田得保工商受阻",
				"地方官署撤销了圈地许可，传统农田安然无恙，城郊紧张气氛随之缓和。但牧场与下游毛纺原料供应计划被迫搁浅，本地制造业扩张步伐明显放缓。",
				[
					Shared.manufacturing(-10, 360),
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
				"multiplier_q16": mul_120,
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
						TraitChanges.grant("i026_magnate", "家大业大"),
						Shared.trade_capacity(15, 540),
						Shared.cash_in(3, 360),
					]),
				Shared.branch(26214, "同行控告特许暂扣", # 40%
					"其余商帮联名状告官商勾结，朝廷被迫介入暂扣特许状彻查。官府虽没收了部分保证金，但混乱的调查过程令本地制造与商贸双双受挫，怨声四起。",
					[
						Shared.cash_in(3, 360),
						Shared.manufacturing(-10, 360),
						Shared.bias(Ids.TAG_UNREST, 1.25, 540),
					])),
			Shared.option(
				"open_bidding", "公开招标，价高者得",
				"公开竞标国库大赚",
				"度支司主持了激烈竞标，商路由出价更高的外来商帮夺得，国库收获丰厚标金。失标的本地大族被迫改走水路，对官府的怨怼却已悄然结下。",
				[
					Shared.cash_in(5, 360),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
			Shared.option(
				"turn_it_down", "驳回特许，暂不开禁",
				"商路冷清众商失望",
				"地方官署退回了特许呈文，北方商路继续处于无序分散状态。缺乏大商帮统筹致使北来原料与货流缩减，本地手工业随之降温，商界颇多怨言。",
				[
					Shared.manufacturing(-10, 360),
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
				"multiplier_q16": mul_120,
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
					TraitChanges.grant("i003_manufacturing", "制造世家"),
					Shared.manufacturing(12, 540),
					Shared.tools(15, 540),
				]),
			Shared.option(
				"back_the_guild", "维护行会，削减名额",
				"行会胜出产能回落",
				"官署裁定严格执行行会名额限制，多余匠人被迫转行离去，大族从此失去工匠世家根基。传统行业秩序与街面稳定得以维持，但本地制造产能显著萎缩。",
				[
					TraitChanges.remove("j004_craft", "工匠世家"),
					Shared.manufacturing(-12, 360),
					Shared.bias(Ids.TAG_UNREST, 0.90, 360),
				]),
			Shared.option(
				"mediate", "出资斡旋，折中妥协",
				"勉强调停暗流未息",
				"国库拨款补贴了部分学徒安置费用，换取行会放宽名额、大族上调工价。表面上的僵局虽暂告化解，但新旧生产体制间的深层矛盾并未根除。",
				[
					Shared.cash_out(4, 360),
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
		"required_technologies": ["tech.writing"],
		"conditions": [
			{"op": Op.HAS_FAMILY_TRAIT, "target_key": "j009_letters", "bool_value": true},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "scholar", "float_value": 0.01},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 3},
				"add_weight": 20,
				"multiplier_q16": mul_115,
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
					TraitChanges.grant("i005_knowledge", "学术赞助"),
					Shared.knowledge(15, 540),
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
				]),
			Shared.option(
				"hand_it_over", "依法收缴，封存禁书",
				"禁书收缴清议消声",
				"违禁典籍被装匣封存带走，大族书香门第的荣耀随之凋零。城中异议声音迅速沉寂，社会秩序趋于安定，但本地学术研究与思想活力也蒙受重创。",
				[
					TraitChanges.remove("j009_letters", "书香门第"),
					Shared.knowledge(-12, 360),
					Shared.bias(Ids.TAG_UNREST, 0.90, 360),
				]),
			Shared.option(
				"burn_half", "择要销毁，留存残卷",
				"半数焚毁折中结案",
				"官署拨付安抚款项并采取折中处置，仅当众销毁敏感卷帙，默许大族保留其余学术注疏。风波得以体面平息，但典籍残缺仍令本地知识积累略有倒退。",
				[
					Shared.knowledge(-8, 360),
					Shared.cash_out(3, 360),
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
				"multiplier_q16": mul_120,
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
					Shared.cash_in(6, 360),
					Shared.bias(Ids.TAG_UNREST, 1.35, 540),
				]),
			Shared.option(
				"negotiate", "私下磋商，酌情减让",
				"妥协减税商路更畅",
				"官署与大族达成闭门协议，略微减让税率换取商帮全面复市。国库仍获得稳健税收，大族则借此进一步拓展商路人脉，带动了全国贸易运力。",
				[
					Shared.cash_in(3, 360),
					Shared.trade_capacity(8, 540),
					TraitChanges.grant("i019_trade", "商路人脉"),
				]),
			Shared.option(
				"exempt_them", "暂缓新税，豁免本季",
				"豁免新税权威受损",
				"加税告示被悄然撤回，商铺全面复业并带动本地工商业小幅回暖。然而豪强以罢市逼退政令的先例迅速传开，各方势力皆在蠢蠢欲动。",
				[
					Shared.manufacturing(8, 360),
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
		"required_technologies": ["tech.steam_power"],
		"conditions": [
			{"op": Op.HAS_FAMILY_TRAIT, "target_key": "i029_coastal", "bool_value": true},
			{"op": Op.ERA_GTE, "int_value": 6},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 3},
				"add_weight": 20,
				"multiplier_q16": mul_120,
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
					TraitChanges.grant("i003_manufacturing", "制造世家"),
					Shared.manufacturing(15, 540),
					Shared.cash_out(5, 360),
				]),
			Shared.option(
				"keep_the_fleet", "扶持航运，维持船队",
				"坚守海运错失工业",
				"官署顺应守旧派诉求，协助修缮扩充商船队，全国海运贸易容量得以稳固。但错失工业化转型的窗口，也令本地制造业发展略显滞后。",
				[
					Shared.trade_capacity(10, 540),
					Shared.manufacturing(-8, 360),
				]),
			Shared.option(
				"hedge_both", "两头兼顾，分资并进",
				"分散投资难成气候",
				"官府出资协调大族同时保留半数船队与小规模厂房。资本分散致使两边皆难成规模，既耗费了财政补贴，也让族内新旧两派的路线争执久拖不决。",
				[
					Shared.cash_out(5, 360),
					Shared.bias(Ids.TAG_UNREST, 1.10, 540),
				]),
		],
	}))
