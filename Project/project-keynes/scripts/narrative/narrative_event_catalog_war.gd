class_name NarrativeEventCatalogWar
extends RefCounted

## 战争包：六条事实驱动 + 六条战时脉冲。
##
## 事实驱动（GameplayEventBus，narrative_event_service 的类型号）：
##   40 宣战 / 41 战事结束 / 42 会战 / 43 城池易手 / 44 部队被歼 / 45 国家被吞并
## 战时脉冲（读军事快照）：
##   征兵、欠饷、伤兵、难民、军市、战后清算
##
## 门槛只用三个新算子：AT_WAR(45)、SOLDIERS_TOTAL_GTE(46)、WAR_GOING_BADLY(47)。
## 效果仍用通用杠杆（现金、主食、出生、部门产出、军粮、动荡权重），不新增写接口。

const Ids = preload("res://scripts/narrative/narrative_event_ids.gd")
const Shared = preload("res://scripts/narrative/narrative_event_shared.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")
const NarrativeEffectSpecScript = preload("res://scripts/narrative/narrative_effect_spec.gd")

const PACK_ID := &"war"
const PREFIX := "evt.war."

const CAST := [
	"军需部", "总参谋部", "前线", "后勤", "地方官署", "军饷",
	"动员令", "守军", "野战医院", "国库", "名族", "祠庙",
]

const MUL_090 := 58982
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


static func meta() -> Dictionary:
	return {
		"id": PACK_ID,
		"title": "战争",
		"theme": "战事落到城里",
		"era_band": "2-10",
		"prefix": PREFIX,
		"scale": "6 条事实驱动 + 6 条中观/微观脉冲 + 3 节家族从军链",
		"cast": CAST,
		"node_ids": [
			String(Ids.EVT_WAR_DECLARATION),
			String(Ids.EVT_WAR_VICTORY),
			String(Ids.EVT_WAR_BATTLE),
			String(Ids.EVT_WAR_CITY_TAKEN),
			String(Ids.EVT_WAR_ARMY_LOST),
			String(Ids.EVT_WAR_ANNEXED),
			String(Ids.EVT_WAR_CONSCRIPTION),
			String(Ids.EVT_WAR_ARREARS),
			String(Ids.EVT_WAR_WOUNDED),
			String(Ids.EVT_WAR_REFUGEES),
			String(Ids.EVT_WAR_ARMY_MARKET),
			String(Ids.EVT_WAR_AFTERMATH),
			String(Ids.EVT_WAR_KINDRED_LEVY),
			String(Ids.EVT_WAR_KINDRED_WAIT),
			String(Ids.EVT_WAR_KINDRED_SHRINE),
		],
	}


static func append(catalog) -> void:
	if catalog == null:
		return
	var Op = NarrativeConditionScript.Op
	var Ch = NarrativeEventDefinitionScript.TriggerChannel

	# ═══ 事实 · 宣战（40）═════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_WAR_DECLARATION),
		"title": "{settlement_name}·宣战",
		"body_text": "战端既开，国家动员令迅速传抵{settlement_name}。军需部急催地方官署立刻加征特别军费与后勤物资以保障前线开拔，而市井间的囤积与恐慌情绪已悄然抬头。若强行加码征收恐动摇后方秩序，若由国库先行垫付又将加重财政压力，战时动员的基调亟待定夺。",
		"image_key": "country.military",
		"ai_visual_prompt": "A war proclamation pasted on a city gate, a grain cart rolling over it, people leaving on the road beyond",
		"tags": ["war", "unrest"],
		"trigger_channel": Ch.FACT_DRIVEN,
		"fact_event_type": 40,
		"base_weight": 120,
		"cooldown_days": 30,
		"min_era_index": 2,
		"max_era_index": 10,
		"conditions": [
			{"op": Op.AT_WAR, "bool_value": true},
			{"op": Op.POPULATION_GTE, "int_value": 8},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 15},
				"add_weight": 20,
				"reason": "城越大，动静越大",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
				"add_weight": 10,
				"reason": "有仓有场，才征得动",
			},
		],
		"options": [
			Shared.option(
				"levy_grain", "颁布战时特别征调令",
				"军需物资连夜启运",
				"地方官署强制执行战时摊派，大宗军需如期发往前线。民众虽未公开抗命，但后方怨声渐起。",
				[
					Shared.cash_in(4, 360),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
			Shared.option(
				"open_the_granary", "动用国库储备平抑后方",
				"后方民生暂得安稳",
				"国库拨款先行垫付军需并补贴口粮供应，战时恐慌迅速平息，代价是财政储备明显缩水。",
				[
					Shared.cash_out(5, 360),
					Shared.staple(-10, 360),
				]),
			Shared.option(
				"wait_and_see", "暂缓加征，维持常规供应",
				"前线补给陷入紧张",
				"地方动员迟迟未能铺开，前线催调文书接踵而至。政令迟滞令工商业界观望不前，民间不安情绪持续扩散。",
				[
					Shared.manufacturing(-8, 360),
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
				]),
		],
	}))

	# ═══ 事实 · 战事结束（41）═════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_WAR_VICTORY),
		"title": "{settlement_name}·捷报",
		"body_text": "前线战事终告平息，捷报与漫长的阵亡将士名录几乎同时送抵{settlement_name}地方官署。全城一面沉浸在胜利的欢呼中，一面却被沉重的伤亡阴影笼罩。军方期盼大办凯旋以振国威，民间则呼唤优先发放抚恤，国库资金有限，战后善后的轻重缓急必须由你裁断。",
		"image_key": "country.military",
		"ai_visual_prompt": "A victory dispatch arriving at night, firecrackers and paper offerings in the same lane, a casualty list pasted at the yamen",
		"tags": ["war", "unrest"],
		"trigger_channel": Ch.FACT_DRIVEN,
		"fact_event_type": 41,
		"base_weight": 120,
		"cooldown_days": 30,
		"min_era_index": 2,
		"max_era_index": 10,
		"conditions": [
			{"op": Op.AT_WAR, "bool_value": false},
			{"op": Op.POPULATION_GTE, "int_value": 8},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 15},
				"add_weight": 20,
				"reason": "城越大，名单越长",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
				"add_weight": 10,
				"reason": "有衙门才办得成抚恤",
			},
		],
		"options": [
			Shared.option(
				"parade_the_victory", "拨款举行盛大凯旋仪式",
				"举国欢庆重振士气",
				"盛大的凯旋庆典极大提振了国家凝聚力与民众对未来的信心，国库虽耗资不菲，但政权威望显著攀升。",
				[
					Shared.cash_out(5, 360),
					Shared.birth(10, 540),
					Shared.bias(Ids.TAG_COURT, 1.15, 540),
				]),
			Shared.option(
				"pay_the_families", "削减庆典，优先发放抚恤",
				"阵亡遗属获妥善安置",
				"政府取消铺张仪式，将国库专款全数用于抚恤阵亡遗属与保障口粮。低调务实的举措赢得了基层深厚民心。",
				[
					Shared.cash_out(6, 360),
					Shared.staple(-10, 360),
				]),
			Shared.option(
				"reward_the_officers", "仅赏将领，课税充库",
				"厚此薄彼引民怨沸腾",
				"朝廷重赏前线有功将领却向地方征收战后附加税，底层遗属的抚恤被一再拖延，民间不满迅速发酵。",
				[
					Shared.cash_in(3, 360),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
		],
	}))

	# ═══ 事实 · 会战（42）═════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_WAR_BATTLE),
		"title": "{settlement_name}·战报",
		"body_text": "前线主力会战惨烈胶着，大批伤员正源源不断地转运至{settlement_name}后方。本地野战医院与地方官署的接诊能力已彻底超载，药品与医护人员严重匮乏。军需部门呈报三套方案：由国库紧急拨款扩建救治、就地遣返原籍休养，或任其在本地自行安置。",
		"image_key": "country.military",
		"ai_visual_prompt": "A cart of wounded soldiers unloaded at a city god temple, a clerk counting them, a soldier's hand clutching a stale pancake",
		"tags": ["war", "unrest"],
		"trigger_channel": Ch.FACT_DRIVEN,
		"fact_event_type": 42,
		"base_weight": 120,
		"cooldown_days": 20,
		"min_era_index": 2,
		"max_era_index": 10,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 8},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.SOLDIERS_TOTAL_GTE, "int_value": 100},
				"add_weight": 25,
				"reason": "兵多，伤亡也多",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 2},
				"add_weight": 10,
				"reason": "有庙有仓，才安置得下",
			},
		],
		"options": [
			Shared.option(
				"send_to_the_physician", "拨款扩建野战医疗站",
				"大批伤员重获生机",
				"国库紧急增调医护与药械，临时病房挽救了大批前线将士的性命，军心与社会安定度随之回升。",
				[
					Shared.cash_out(4, 360),
					Shared.birth(8, 540),
				]),
			Shared.option(
				"send_them_home", "发给路费，遣返原籍",
				"伤员分批疏散返乡",
				"地方官署雇佣车队将伤员分批送返故里，减轻了本地医疗负担，但沿途凄凉的景象仍动摇了后方士气。",
				[
					Shared.cash_out(3, 360),
					Shared.bias(Ids.TAG_UNREST, 1.10, 540),
				]),
			Shared.option(
				"leave_them_there", "停止拨款，令其就地安置",
				"伤兵滞留拖累城防",
				"未获妥善救治的伤员被迫滞留本地谋生，不仅增加了城区人口负担，更令工商业秩序与治安持续恶化。",
				[
					# 留在庙里的活人从此算本地人口；「不问了」是不管，不是不存在。
					Shared.population_rate(3, "本地人口 +3%（伤兵留居本地）"),
					Shared.manufacturing(-8, 360),
					Shared.bias(Ids.TAG_UNREST, 1.25, 540),
				]),
		],
	}))

	# ═══ 事实 · 城池易手（43）═════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_WAR_CITY_TAKEN),
		"title": "{settlement_name}·易手",
		"body_text": "{settlement_name}在战火中刚刚易手，旧有行政体系已然瓦解，仓库账册散佚不全。新进驻的守军与接管官署正面临棘手局面，城中商铺紧闭、流言四起。军需部提议纵容部队就地筹饷以省开支，民政官员则力主立刻开仓安民、重建秩序，战后接管的方针亟待定夺。",
		"image_key": "country.military",
		"ai_visual_prompt": "A captured city with an open granary, second-hand clothes sold in the street, a new notice pasted over an old one",
		"tags": ["war", "market", "unrest"],
		"trigger_channel": Ch.FACT_DRIVEN,
		"fact_event_type": 43,
		"base_weight": 120,
		"cooldown_days": 30,
		"min_era_index": 2,
		"max_era_index": 10,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 8},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 15},
				"add_weight": 20,
				"reason": "城大，接手的人多",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
				"add_weight": 10,
				"reason": "有仓有街，才接手得下来",
			},
		],
		"options": [
			Shared.option(
				"pacify_and_open", "严明军纪，开仓安民",
				"新政迅速站稳脚跟",
				"接管当局拨款赈济并严格约束守军，全城商市很快恢复运转，新政权赢得了初步的民心认同。",
				[
					Shared.staple(-10, 360),
					Shared.cash_out(4, 360),
				]),
			Shared.option(
				"let_the_troops_loot", "默许守军就地搜刮筹饷",
				"全城凋敝仇恨深种",
				"强征与劫掠在短时间内为国库聚敛了大笔财物，但商业街区元气大伤，反抗情绪在暗处疯狂滋长。",
				[
					Shared.cash_in(5, 360),
					Shared.bias(Ids.TAG_UNREST, 1.40, 720),
				]),
			Shared.option(
				"seal_everything", "全面封仓，实行军管",
				"军管之下百业停滞",
				"守军查封全部仓储并实施严密戒严，物资虽未外流，但长期停摆的生产与紧绷的管制令民怨不断累积。",
				[
					Shared.manufacturing(-8, 360),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
		],
	}))

	# ═══ 事实 · 部队被歼（44）═════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_WAR_ARMY_LOST),
		"title": "{settlement_name}·败信",
		"body_text": "前线传来噩耗：我军一支主力部队在会战中惨遭合围覆没，建制荡然无存。总参谋部尚未厘清战败责任，大批衣衫褴褛的残兵已陆续溃退至{settlement_name}外围请求收容。城中守军人心浮动，究竟是开门整编、严惩主将以正军法，还是闭门拒纳以防溃兵乱城，全在一念之间。",
		"image_key": "country.military",
		"ai_visual_prompt": "An unsigned defeat letter on a desk, the city gate opened for a few survivors waiting outside",
		"tags": ["war", "unrest"],
		"trigger_channel": Ch.FACT_DRIVEN,
		"fact_event_type": 44,
		"base_weight": 120,
		"cooldown_days": 30,
		"min_era_index": 2,
		"max_era_index": 10,
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 8},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.SOLDIERS_TOTAL_GTE, "int_value": 100},
				"add_weight": 20,
				"reason": "兵多，败起来也大",
			},
			{
				"condition": {"op": Op.COHORT_SATISFACTION_LTE, "float_value": 0.50},
				"add_weight": 15,
				"reason": "人心本来就不稳",
			},
		],
		"options": [
			Shared.option(
				"take_the_survivors_in", "拨款收容并就地安置",
				"残部幸存者并入城区",
				"地方官署拨款供给衣食并将幸存溃兵就地编入民籍，虽然加重了短期财政与供给压力，却保住了宝贵的人口。",
				[
					# 「先给口热的」之后活下来的人留在城里；birth(2) 说的是往后十年多生，
					# 跟这些当下就要吃饭的人不是一件事。
					Shared.population_rate(25, "本地人口 +25%（溃兵收容）"),
					Shared.cash_out(4, 360),
				]),
			Shared.option(
				"blame_the_general", "军法严办主将，整肃纲纪",
				"问责风暴震荡军政",
				"总参谋部革除败军主将职务并展开严厉审查，军界与官僚体系人人自危，内部互信与推演效率明显受挫。",
				[
					Shared.knowledge(-8, 360),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
			Shared.option(
				"call_them_deserters", "视同逃兵，严禁入城",
				"冷酷处置激起公愤",
				"守军紧闭城防驱离溃兵，大批幸存者流离失所。此举令前线将士寒心，后方生产与治安亦随之恶化。",
				[
					Shared.manufacturing(-8, 360),
					Shared.bias(Ids.TAG_UNREST, 1.35, 720),
				]),
		],
	}))

	# ═══ 事实 · 国家被吞并（45）═══════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_WAR_ANNEXED),
		"title": "{settlement_name}·旧印",
		"body_text": "邻国政权覆灭并入我方版图，其旧印与档案已由总参谋部移交接收。然而在{settlement_name}，大批新附商人与市民手中仍持有巨额旧政权货币，市场交易因币制未定而陷入停摆。地方官署与国库官员正急待中央定夺：如何处置这批旧币，将直接决定新领土的经济融合速度。",
		"image_key": "country.military",
		"ai_visual_prompt": "A conquered country's seal in a wooden box with wet lacquer, merchants asking about old coins at a street exchange",
		"tags": ["war", "market", "unrest"],
		"trigger_channel": Ch.FACT_DRIVEN,
		"fact_event_type": 45,
		"base_weight": 120,
		"cooldown_days": 60,
		"min_era_index": 3,
		"max_era_index": 10,
		"required_technologies": ["tech.currency"],
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 8},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.03},
				"add_weight": 20,
				"reason": "商人最关心旧钱",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 3},
				"add_weight": 10,
				"reason": "城大，换牌子的人多",
			},
		],
		"options": [
			Shared.gamble(
				"keep_the_old_coin", "允许旧币按折价平稳过渡",
				Shared.branch(39322, "商贸迅速恢复流通", # 60%
					"新旧货币平稳衔接，新附地区的商业网络很快融入我国贸易体系，尽管初期仍伴随些许投机风波。",
					[
						Shared.trade_capacity(12, 540),
						Shared.bias(Ids.TAG_UNREST, 1.20, 540),
					]),
				Shared.branch(26214, "旧币信用崩盘挤兑", # 40%
					"投机者疯狂抛售旧币引发挤兑风潮，国库被迫出资兜底，本地工商业在混乱中遭受重创。",
					[
						Shared.manufacturing(-10, 540),
						Shared.cash_out(4, 360),
						Shared.bias(Ids.TAG_UNREST, 1.30, 540),
					])),
			Shared.option(
				"devalue_the_old_coin", "强制大幅折价回收旧币",
				"国库获利而商界受损",
				"财政部门以极低折算率强行收兑旧币，为国库带来一笔可观铸币差额，但新附商民财富缩水、怨气颇深。",
				[
					Shared.cash_in(4, 360),
					Shared.bias(Ids.TAG_UNREST, 1.25, 540),
				]),
			Shared.option(
				"void_the_old_coin", "宣布旧政权货币一律作废",
				"金融震荡引发倒退",
				"旧币一夜沦为废品，本地商业瞬间退回以物易物的原始状态，制造业停滞且动荡风险大幅攀升。",
				[
					Shared.manufacturing(-10, 540),
					Shared.bias(Ids.TAG_UNREST, 1.30, 720),
				]),
		],
	}))

	preload("res://scripts/narrative/narrative_event_catalog_war_pulse.gd").append(catalog)
