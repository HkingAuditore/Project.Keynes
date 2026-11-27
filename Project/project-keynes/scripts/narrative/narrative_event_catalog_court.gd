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
	"宗室", "辅政重臣", "外戚", "宗谱", "兵符", "印玺", "武库", "驿传", "旧账", "路引",
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
		"body_text": "先君骤逝而未留嫡嗣，宗室与外戚顷刻间剑拔弩张。辅政重臣搬出宗谱，力主立年幼支脉以维系正统法统；外戚则借拱卫武库之名陈兵殿外，另有朝臣暗中提及流落民间的庶出子嗣。户部与仓司官吏皆按兵不动，静待新君名分落地。大位一日虚悬，朝局与地方军政便多一分倾覆之危，各方正等待最高裁断。",
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
				"cradle_heir", "立幼主，托孤辅政",
				"幼主登基",
				"幼主在礼官簇拥下继位，辅政重臣代掌国印并主持朝政。国库为此拨出丰厚赏赐以安抚百官，但主少国疑的隐忧已在各部悄然蔓延。",
				[
					Shared.cash_out(5, 540),
					Shared.flag(Ids.FLAG_THRONE_DISPUTED, 1825, "标记「主少国疑」"),
					Shared.schedule(Ids.EVT_COURT_REGENT, 25, "掌印的人"),
				]),
			Shared.option(
				"adopted_heir", "过继宗室，昭告祖庙",
				"宗室承统",
				"过继子嗣于祖庙受册，随即下令将外戚亲兵调离京畿。大兴土木重修礼仪仪仗虽耗费不菲，但政权交接的危机总算暂告平息。",
				[
					Shared.build_cost(10, 540),
					Shared.bias(Ids.TAG_UNREST, 0.90, 540),
					Shared.bias(Ids.TAG_COURT, 1.20, 540),
				]),
			Shared.option(
				"hidden_death", "秘不发丧，先控武库",
				"闭城戒严",
				"朝廷封锁死讯并骤然闭城，紧急清点武库军械以防变乱。数日后城门重开，民间流言四起，对权臣密谋的猜忌迅速在地方扩散。",
				[
					Shared.cash_out(4, 360),
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
		"title": "{settlement_name}·掌印之人",
		"body_text": "自新朝确立以来，辅政重臣独揽政务，官吏迁转、河工兴修与地方加赋皆由其一手批复。他表面清廉奉公，实则将行政中枢与财政脉络尽数纳入私党掌控，令君权日渐架空。如今他呈上奏折，名义上请示今年兵符的归属，实则在试探最高权力的底线。若不趁早决断，印玺与军权恐将一并旁落。",
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
				"pay_the_regent", "赐予厚禄，羁縻相权",
				"以禄换稳",
				"朝廷按季拨付丰厚禄赐以示恩宠，辅政重臣心领神会地收敛了锋芒。各方势力暂时维持了微妙的平衡，但财政为此背上了沉重的长期包袱。",
				[
					Shared.cash_out(6, 540),
					Shared.bias(Ids.TAG_UNREST, 0.85, 540),
					Shared.flag(Ids.FLAG_REGENT_PAID, 1825, "标记「相府有例」"),
				]),
			Shared.option(
				"take_the_tally", "收回兵符，削夺军权",
				"兵符归中枢",
				"兵符被强硬收归御前，军队补给调度得以重新集中。然而辅政重臣随即称病罢朝，数日后南方行省便传来旧部另立印玺的警讯。",
				[
					Shared.supply(10, 360),
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
					Shared.schedule(Ids.EVT_COURT_TWO_SEALS, 45, "两方印"),
				]),
			Shared.option(
				"let_him_run_grain", "授其漕运，以利换权",
				"相府专漕",
				"漕运大权归入相府名下，借由其严密的网络，全国商运效率显著提升。代价是各处码头皆由相党把持，地方对中枢专权的怨愤日积月累。",
				[
					Shared.trade_capacity(15, 540),
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
		"body_text": "反对派借宗室名义在南方另立政权，起用旧式印玺并沿用同一国号与纪年。如今两套官署同时向地方颁布政令、征收赋税，往来商队不得不备齐两份路引，稍有疏忽便在关津遭到扣押。双头政局令基层官吏无所适从，国家法统正面临彻底撕裂的险境。是划疆妥协、武力平叛，还是寻求第三方仲裁，必须即刻定夺。",
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
				"draw_the_border", "划界分治，暂止干戈",
				"南北分治",
				"双方以河谷为界达成默契，勉强避免了全面内战。但一国两制的混乱重创了文教与行政协同，分裂的隐患长期悬于头顶。",
				[
					Shared.knowledge(-12, 540),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
					Shared.flag(Ids.FLAG_TWO_COURTS, 1825, "标记「两印并立」"),
				]),
			Shared.option(
				"march_south", "发兵南征，武力清君侧",
				"兵戈既起",
				"大军渡河展开讨伐，战事迅速吞噬了国库积蓄。为了维持庞大军费，地方铸币成色开始恶化，战火波及之处的祠堂与村落亦陷入破败。",
				[
					Shared.cash_out(10, 540),
					Shared.bias(Ids.TAG_UNREST, 1.50, 540),
					Shared.schedule(Ids.EVT_FISCAL_DEBASED_COIN, 40, "小钱"),
					Shared.schedule(Ids.EVT_LAND_RUINED_SHRINE, 90, "废祠"),
				]),
			Shared.option(
				"ask_for_mediation", "请宗法长老出面调停",
				"共署国政",
				"经由宗教与地方望族多方斡旋，名义上的统一得以保全。代价是此后一切重大政令皆须两派会签，行政效率与营建成本均受拖累。",
				[
					Shared.knowledge(-12, 360),
					Shared.build_cost(8, 540),
					Shared.bias(Ids.TAG_UNREST, 0.95, 540),
					Shared.bias(Ids.TAG_FAITH, 1.20, 540),
				]),
		],
	}))

	# ═══ 孤立 · 过路的官 ═══════════════════════════════════════════════════
	# 微观事件：一个被贬的官路过，要不要留下他。他记得旧账，也带着霉气。
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_COURT_EXILED),
		"title": "{settlement_name}·谪官过境",
		"body_text": "一名因在奏折中触怒权贵而被贬谪的前任高官滞留于本地驿传，随行家眷资费已尽。他早年曾主持河工与漕粮调度，通晓地方积年的旧账与官场实情，如今愿留任本地兴办书院或协助清理案牍。本地乡绅忌惮其政治污点，力主将其逐出境；但主理政务的幕僚认为，他脑中的旧账正是整顿吏治的利器。",
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
				"keep_him_teaching", "延聘讲学，充实地方文教",
				"设馆授徒",
				"朝廷拨付薄俸将其安置于学馆，各地士子闻风前来求学。本地学术风气大振，但其在讲学中对时政的针砭也引来保守派的侧目。",
				[
					Shared.cash_out(4, 360),
					Shared.knowledge(15, 540),
					Shared.bias(Ids.TAG_UNREST, 1.10, 360),
				]),
			Shared.option(
				"pay_him_to_leave", "赐予盘缠，礼送出境",
				"婉拒留任",
				"一笔遣散费体面地化解了潜在的政治风波，谪官携家眷黯然离去。本地虽保住了表面安宁，却也错失了一位谙熟政务的干才。",
				[
					Shared.cash_out(3, 180),
					Shared.knowledge(-8, 240),
					Shared.bias(Ids.TAG_UNREST, 0.95, 240),
				]),
			Shared.gamble(
				"ask_for_the_old_ledger", "起用其清查历年旧账",
				Shared.branch(42598, "旧账水落石出", # 65%
					"历时两月，历年亏空与贪墨脉络被悉数厘清并登记在案。这份铁证不仅震慑了朝中权贵，也让数家涉嫌勾结的地方豪强连夜出逃。",
					[
						Shared.knowledge(18, 540),
						Shared.flag(Ids.FLAG_OLD_LEDGER, 1825, "标记「旧账在案」"),
						Shared.bias(Ids.TAG_UNREST, 1.15, 540),
					]),
				Shared.branch(22938, "清查半途而废", # 35%
					"查账刚触及核心利益便遭遇暗中阻挠，谪官在威胁之下连夜失踪。不仅拨付的经费付诸东流，未竟的案牍反令地方谣言四起。",
					[
						Shared.knowledge(-10, 240),
						Shared.cash_out(5, 360),
						Shared.bias(Ids.TAG_UNREST, 1.30, 360),
					])),
		],
	}))
