extends RefCounted

const NarrativeEffectSpecScript = preload("res://scripts/narrative/narrative_effect_spec.gd")

const Ids = preload("res://scripts/narrative/narrative_event_ids.gd")

const Shared = preload("res://scripts/narrative/narrative_event_shared.gd")

const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")

const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")

const MUL_115 := 75366

const MUL_120 := 78643

const MUL_125 := 81920

static func _grant(trait_key: String, display_name: String) -> Dictionary:
	return {
		"kind": NarrativeEffectSpecScript.Kind.GRANT_FAMILY_TRAIT,
		"target_key": trait_key,
		"magnitude_q16": 65536,
		"duration_days": 1,
		"custom_label": "本地最大族「{family_name}」获特质「%s」，永久" % display_name,
	}


static func append(catalog) -> void:
	var Op = NarrativeConditionScript.Op
	var Ch = NarrativeEventDefinitionScript.TriggerChannel
	# ═══ 脉冲 · 征兵 ══════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_WAR_CONSCRIPTION),
		"title": "{settlement_name}·征丁",
		"body_text": "前线战损持续扩大，总参谋部向{settlement_name}下达了新一轮紧急征兵动员令。地方官署按户籍抽丁却频频遭遇隐匿与逃避，部分富裕阶层暗中托人疏通，要求以缴纳税款折抵兵役。强行按册征发必将激化民间抵触并冲击农业劳力，而放宽免役又会损及兵源公平，如何执行亟待决断。",
		"image_key": "country.military",
		"ai_visual_prompt": "A conscription notice in a narrow lane, a clerk at a door, a man climbing over a wall at the end",
		"tags": ["war", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 110,
		"cooldown_days": 360,
		"min_era_index": 2,
		"max_era_index": 9,
		"conditions": [
			{"op": Op.AT_WAR, "bool_value": true},
			{"op": Op.POPULATION_GTE, "int_value": 10},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.SOLDIERS_TOTAL_GTE, "int_value": 200},
				"add_weight": 25,
				"multiplier_q16": MUL_120,
				"reason": "兵不够，征得就急",
			},
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 20},
				"add_weight": 15,
				"reason": "人多，抽得出来",
			},
		],
		"options": [
			Shared.option(
				"take_them_by_the_roll", "铁腕按册强征入伍",
				"兵源补齐而民怨沸腾",
				"地方官署动用强制手段补足了征兵配额，青壮年大批离乡令人口增长放缓，基层社会暗潮涌动。",
				[
					Shared.birth(-10, 540),
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
				]),
			Shared.option(
				"let_them_buy_out", "准许纳资代役",
				"富户买免充实国库",
				"富商与豪绅纷纷缴纳巨额免役金，国库获益颇丰，但穷人上阵、富人留乡的不公激起了底层愤慨。",
				[
					Shared.cash_in(4, 360),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
			Shared.option(
				"halve_the_levy", "体恤地方，缓征半数",
				"征兵折半拖累军务",
				"政府下令减半执行本期征额以安抚地方，前线催调文书不断，后方工商业也因战局胶着而士气低迷。",
				[
					Shared.manufacturing(-8, 360),
					Shared.bias(Ids.TAG_UNREST, 1.10, 540),
				]),
		],
	}))

	# ═══ 脉冲 · 欠饷 ══════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_WAR_ARREARS),
		"title": "{settlement_name}·欠饷",
		"body_text": "战事拖延令国库捉襟见肘，驻守{settlement_name}的守军已连续两月未能领到足额军饷。大批官兵列队聚集在地方官署外无声施压，营中哗变的流言正在迅速扩散。军需部呈报，眼下要么立刻拨款补发欠饷，要么签发战后兑付的军用欠条，或者趁机裁撤半数编余部队以缩减开支。",
		"image_key": "country.military",
		"ai_visual_prompt": "Soldiers standing silently outside a yamen over unpaid wages, an official speaking from the steps",
		"tags": ["war", "unrest", "fiscal"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 110,
		"cooldown_days": 300,
		"min_era_index": 3,
		"max_era_index": 10,
		"conditions": [
			{"op": Op.AT_WAR, "bool_value": true},
			{"op": Op.SOLDIERS_TOTAL_GTE, "int_value": 100},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.SOLDIERS_TOTAL_GTE, "int_value": 300},
				"add_weight": 25,
				"reason": "兵越多，欠得越多",
			},
			{
				"condition": {"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "wheat_grain", "float_value": 1.10},
				"add_weight": 15,
				"reason": "粮价一高，饷更不够吃",
			},
		],
		"options": [
			Shared.option(
				"pay_in_full", "紧急调拨国库补足欠饷",
				"军心迅速恢复稳定",
				"国库紧急拨付现款结清全部欠饷，哗变危机烟消云散，驻军秩序与地方治安随之回稳。",
				[
					Shared.cash_out(6, 360),
					Shared.bias(Ids.TAG_UNREST, 0.90, 360),
				]),
			Shared.option(
				"issue_promises", "签发官印欠条，战后兑付",
				"白条抵饷引发不满",
				"官兵们对空头支票普遍心怀怨怼，军纪松弛波及地方商市，社会动荡风险显著攀升。",
				[
					Shared.manufacturing(-8, 360),
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
				]),
			Shared.option(
				"discharge_half", "缩编裁撤半数驻军",
				"遣散官兵引发骚动",
				"裁军虽暂时减轻了财政负担并腾出部分地方资金，但大批失意退伍兵滞留街头，令治安形势骤然恶化。",
				[
					Shared.cash_in(3, 360),
					Shared.bias(Ids.TAG_UNREST, 1.40, 720),
				]),
		],
	}))

	# ═══ 脉冲 · 伤兵 ══════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_WAR_WOUNDED),
		"title": "{settlement_name}·伤兵",
		"body_text": "持续不断的拉锯战令{settlement_name}的野战医院人满为患，军医与基础药品双双告急。大量重伤员因缺乏及时救治而面临致残或感染风险，地方官署虽已向民间药商紧急赊购草药，仍是杯水车薪。后勤部门请求中央指示：是拨款增派医护、分批遣送回乡，还是仅集中资源救治轻伤员。",
		"image_key": "country.military",
		"ai_visual_prompt": "Wounded soldiers in a temple, a physician washing wounds with salt water, riderless horses tied outside",
		"tags": ["war", "people"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 300,
		"min_era_index": 2,
		"max_era_index": 10,
		"conditions": [
			{"op": Op.AT_WAR, "bool_value": true},
			{"op": Op.SOLDIERS_TOTAL_GTE, "int_value": 150},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.SOLDIERS_TOTAL_GTE, "int_value": 400},
				"add_weight": 25,
				"reason": "仗打得大，伤兵就多",
			},
			{
				"condition": {"op": Op.COHORT_SATISFACTION_LTE, "float_value": 0.50},
				"add_weight": 15,
				"reason": "家里也等着人",
			},
		],
		"options": [
			Shared.option(
				"more_physicians", "拨款增派医护与药械",
				"伤员救治率显著提高",
				"国库紧急增援医疗队伍与足量药品，大批伤员转危为安，国家对将士的担当极大稳住了后方民心。",
				[
					Shared.cash_out(5, 360),
					Shared.birth(10, 540),
				]),
			Shared.option(
				"send_them_home", "发给抚恤，遣返乡里",
				"伤员分批返乡休养",
				"政府出资雇车将伤员送归原籍，减轻了医院运转压力，但大批伤残者返乡也加重了地方口粮负担。",
				[
					Shared.cash_out(3, 360),
					Shared.staple(10, 540),
				]),
			Shared.option(
				"only_the_savable", "实行残酷分诊，放弃重伤",
				"冷血分诊重创士气",
				"医疗资源全部向轻伤员倾斜，重伤者被无情放弃。消息传出后举城哗然，学术界与民间一致谴责当局冷酷。",
				[
					Shared.knowledge(-8, 360),
					Shared.bias(Ids.TAG_UNREST, 1.25, 540),
				]),
		],
	}))

	# ═══ 脉冲 · 难民 ══════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_WAR_REFUGEES),
		"title": "{settlement_name}·城下的人",
		"body_text": "前线战火不断蔓延，大批逃离战区的难民涌至{settlement_name}外围请求庇护。本地守军紧闭防线待命，地方官署则忧心忡忡，担心放任数以千计的流民入城会彻底冲垮本就紧张的口粮储备与治安。然而若在战时冷酷拒纳本国子民，恐将引发严重的道义危机与动荡。",
		"image_key": "country.military",
		"ai_visual_prompt": "Refugees crowding a city gate, one holding a soaked travel permit, a child on an adult's shoulders seen from the wall",
		"tags": ["war", "unrest", "people"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 110,
		"cooldown_days": 300,
		"min_era_index": 2,
		"max_era_index": 10,
		"conditions": [
			{"op": Op.AT_WAR, "bool_value": true},
			{"op": Op.POPULATION_GTE, "int_value": 12},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.WAR_GOING_BADLY, "bool_value": true},
				"add_weight": 30,
				"multiplier_q16": MUL_125,
				"reason": "仗打得不好，跑的人就多",
			},
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 20},
				"add_weight": 15,
				"reason": "大城才有门楼可站",
			},
		],
		"options": [
			Shared.option(
				"open_the_gate", "开放防线，全面收容入籍",
				"大批难民涌入城区",
				"地方官署敞开城防接纳难民并就地登记落籍，城市人口显著增长，但口粮消耗与治安摩擦也随之骤增。",
				[
					Shared.population_rate(15, "本地人口 +15%（难民入城）"),
					Shared.staple(12, 540),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
			Shared.option(
				"camp_outside", "拨款在城外设立隔离营",
				"城外营地勉强维系",
				"国库拨出专款在城外搭建临时收容营并派发口粮，既保住了城区秩序，也令营地内的苦难与不满持续积聚。",
				[
					Shared.cash_out(4, 360),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
			Shared.option(
				"keep_the_gate_shut", "严守防线，禁止难民入境",
				"驱离难民保全城内",
				"守军坚决驱离城外人群，保住了城内的口粮供应与短期安宁，但见死不救的恶名迅速传遍全国。",
				[
					Shared.staple(-8, 360),
					Shared.bias(Ids.TAG_UNREST, 1.35, 720),
				]),
		],
	}))

	# ═══ 脉冲 · 军市 ══════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_WAR_ARMY_MARKET),
		"title": "{settlement_name}·军市",
		"body_text": "围绕{settlement_name}的守军驻地，一座庞大的自发军市迅速成形，酒肆、修械与黑市交易应有尽有。地方官署派出的税吏前往课税时遭到士兵围攻驱逐，军纪与税政双双受挫。军需部与地方商会趁机各提方案：要么收归官营统一抽税，要么承包给大商号缴纳特许金，或者直接出兵取缔以整肃军纪。",
		"image_key": "country.economy",
		"ai_visual_prompt": "An improvised market outside an army camp, a tax clerk surrounded by soldiers, a broken wine jar in the mud",
		"tags": ["war", "market"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 300,
		"min_era_index": 3,
		"max_era_index": 10,
		"conditions": [
			{"op": Op.AT_WAR, "bool_value": true},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.02},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.SOLDIERS_TOTAL_GTE, "int_value": 200},
				"add_weight": 20,
				"reason": "兵多，市就大",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.05},
				"add_weight": 15,
				"reason": "商人闻着味就来了",
			},
		],
		"options": [
			Shared.option(
				"run_it_officially", "收归官营，设立军市税卡",
				"官营军市充实国库",
				"官署正式接管营外商市并征收固定税费，国库进项增加，但官营体系的克扣引发了驻军与小贩的不满。",
				[
					Shared.cash_in(4, 360),
					Shared.bias(Ids.TAG_UNREST, 1.10, 540),
				]),
			Shared.option(
				"farm_it_out", "招标承包给本地大商号",
				"商号包税获利颇丰",
				"大商号缴足特许押金后垄断了军市经营权，财政大为宽裕，但商号盘剥令底层劳工与士兵摩擦不断。",
				[
					Shared.cash_in(5, 360),
					Shared.bias(Ids.TAG_LABOR, 1.15, 540),
				]),
			Shared.option(
				"shut_it_down", "严令取缔，整肃营地军纪",
				"强制清场反致私贸",
				"军市被强行拆除，商业流通受阻且地下黑市转入暗处，士兵私自越营寻欢的事件反而层出不穷。",
				[
					Shared.manufacturing(-8, 360),
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
				]),
		],
	}))

	# ═══ 脉冲 · 战后 ══════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_WAR_AFTERMATH),
		"title": "{settlement_name}·战后",
		"body_text": "漫长的战火终于平息，{settlement_name}却已千疮百孔。大量青壮年折损于前线，成片农田抛荒，国库与地方仓储双双见底。地方官署将厚重的阵亡名册与欠税账簿一并呈上案头，究竟是优先拨款抚恤遗属、招徕流民垦荒复产，还是铁腕追缴欠税以迅速填补财政窟窿，全看你的战后国策。",
		"image_key": "country.military",
		"ai_visual_prompt": "Two ledgers side by side after a war, one for the dead and one for unpaid taxes, empty fields beyond the window",
		"tags": ["war", "unrest", "fiscal"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 600,
		"min_era_index": 2,
		"max_era_index": 10,
		"conditions": [
			{"op": Op.AT_WAR, "bool_value": false},
			{"op": Op.POPULATION_GTE, "int_value": 12},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.SOLDIERS_TOTAL_GTE, "int_value": 100},
				"add_weight": 20,
				"reason": "兵多，阵亡册就厚",
			},
			{
				"condition": {"op": Op.COHORT_SATISFACTION_LTE, "float_value": 0.50},
				"add_weight": 15,
				"reason": "日子紧，欠税也追不动",
			},
		],
		"options": [
			Shared.option(
				"pay_the_dead", "国库拨款，全面抚恤阵亡",
				"厚恤遗属休养生息",
				"国家不惜重金向阵亡将士遗属发放足额抚恤，战争创伤逐渐抚平，地方人口与生育意愿稳步回升。",
				[
					Shared.cash_out(6, 360),
					Shared.birth(8, 540),
				]),
			Shared.option(
				"settle_the_fields", "颁布垦荒令，招民复耕",
				"回流农户重垦荒田",
				"官署宣布开荒免税并拨付农具补贴，大批外迁人口陆续回流落籍，农业迅速复苏，唯工坊人手一时略显吃紧。",
				[
					# 「从北边回来的」是真的往回填人：荒田得有人种，人才算真回来。
					Shared.population_rate(10, "本地人口 +10%（回流农户落籍垦荒）"),
					Shared.cash_out(4, 360),
					Shared.agriculture(12, 540),
					Shared.manufacturing(-8, 360),
				]),
			Shared.option(
				"collect_the_taxes", "强行清缴战时全部欠税",
				"严苛追税激化怨愤",
				"税吏逐户催缴战时欠赋，国库虽迅速回血，但向阵亡将士家庭逼税的冷酷行径在民间埋下了深重仇恨。",
				[
					Shared.cash_in(5, 360),
					Shared.bias(Ids.TAG_UNREST, 1.25, 540),
				]),
		],
	}))

	# ═══ 链 · 族中子弟从军（1/3）════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_WAR_KINDRED_LEVY),
		"title": "{settlement_name}·族里出人",
		"body_text": "前线兵源吃紧，总参谋部下达特别动员令，要求{settlement_name}的本地名族率先遣送嫡系子弟从军以作表率。族中主战派认为此乃彰显门第担当、换取朝廷恩宠的良机；保守派则极力劝阻，主张出钱买免或改抽普通民户顶替。地方官署不敢擅专，正等待中央示下。",
		"image_key": "family.house",
		"ai_visual_prompt": "A conscription roster in a clan courtyard, a young man changing into new shoes, old shoes left on the threshold",
		"tags": ["war", "family"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 900,
		"min_era_index": 2,
		"max_era_index": 9,
		"conditions": [
			{"op": Op.AT_WAR, "bool_value": true},
			{"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 2},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.FAMILY_PRESTIGE_GTE, "int_value": 3},
				"add_weight": 20,
				"multiplier_q16": MUL_115,
				"reason": "族里有头脸，推不掉",
			},
			{
				"condition": {"op": Op.SOLDIERS_TOTAL_GTE, "int_value": 100},
				"add_weight": 15,
				"reason": "兵不够，才点到族里",
			},
		],
		"options": [
			Shared.option(
				"send_a_son", "征召名族子弟奔赴前线",
				"名门子弟披甲出征",
				"国家赐予治装补助，名族子弟如期入伍并编入主力部队。此举在地方树起表率，全族上下则日夜悬心前线战报。",
				[
					Shared.flag(Ids.FLAG_WAR_KINDRED_SENT, 1825, "族中子弟从军"),
					Shared.schedule(Ids.EVT_WAR_KINDRED_WAIT, 150, "家书", &"war_kindred"),
					Shared.cash_out(3, 360),
				]),
			Shared.option(
				"buy_him_out", "默许其以财物抵免兵役",
				"特权免役暗生非议",
				"大族借关系保住了自家子弟，朝廷为此妥协并承担了额外替补安置费用，政界围绕豪强特权的攻讦随之升温。",
				[
					Shared.cash_out(4, 360),
					Shared.bias(Ids.TAG_COURT, 1.15, 540),
				]),
			Shared.option(
				"take_another", "改抽普通民户顶替名额",
				"偏袒豪强惹怒百姓",
				"地方官署将兵役配额强行转嫁给无权无势的平民家庭，全城民众愤慨不已，对大族与官府的怨恨急剧加深。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.35, 720),
				]),
		],
	}))

	# ═══ 链 · 家书（2/3）══════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_WAR_KINDRED_WAIT),
		"title": "{settlement_name}·家书",
		"body_text": "前线送抵{settlement_name}的军情简报令本地名族陷入恐慌。此前应征入伍的族中子弟在惨烈交锋后下落不明，总参谋部的伤亡名册上仅标注为失踪。地方官署连发数次公函核查仍无定论，族中长老正要求朝廷给出明确说法，以决定是否按阵亡抚恤或继续搜寻。",
		"image_key": "country.military",
		"ai_visual_prompt": "A letter with a cracked wax seal and only half a page, a clan elder sitting alone in an ancestral hall at night",
		"tags": ["war", "family"],
		"trigger_channel": Ch.SCHEDULED_ONLY,
		"required_story_flags": [String(Ids.FLAG_WAR_KINDRED_SENT)],
		"one_shot": true,
		"base_weight": 100,
		"cooldown_days": 0,
		"min_era_index": 2,
		"max_era_index": 9,
		"conditions": [],
		"weight_rules": [],
		"options": [
			Shared.option(
				"no_one_found", "正式宣告阵亡，备办追悼",
				"名族立冢哀悼忠烈",
				"军方最终确认其已殉国，地方名族悲痛地为其设立衣冠冢。沉重的伤亡阴影笼罩全城，厌战情绪悄然抬头。",
				[
					Shared.clear_flag(Ids.FLAG_WAR_KINDRED_SENT, "家书已读"),
					Shared.flag(Ids.FLAG_WAR_KINDRED_DEAD, 1825, "族中子弟阵亡"),
					Shared.schedule(Ids.EVT_WAR_KINDRED_SHRINE, 240, "立祠", &"war_kindred"),
					Shared.bias(Ids.TAG_UNREST, 1.25, 540),
				]),
			Shared.option(
				"he_came_back", "核实生还，拨款接回疗养",
				"负伤归乡重聚族人",
				"失踪者最终在后方医院被寻获，虽负重伤致残，仍获国库拨款妥善安置返乡。劫后余生的消息令地方民心大慰。",
				[
					Shared.clear_flag(Ids.FLAG_WAR_KINDRED_SENT, "家书已读"),
					Shared.birth(8, 540),
					Shared.cash_out(3, 360),
				]),
			Shared.option(
				"no_news", "暂列失踪，搁置善后定论",
				"音讯杳无徒留悬案",
				"军方既不宣告阵亡亦无力继续搜寻，悬而未决的状态消耗了地方耐心，生产士气与社会信任随之受挫。",
				[
					Shared.clear_flag(Ids.FLAG_WAR_KINDRED_SENT, "家书已读"),
					Shared.manufacturing(-8, 360),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
		],
	}))

	# ═══ 链 · 立祠（3/3）══════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_WAR_KINDRED_SHRINE),
		"title": "{settlement_name}·立祠",
		"body_text": "为纪念此前在前线殉国的子弟，{settlement_name}的本地名族向地方官署递交奏请，希望动用公私款项修建忠烈祠庙并刻碑永志。支持者称表彰忠义有助于凝聚士绅门第与国家认同。财政官员则认为战时国库紧张，不宜为单一宗族大兴土木，建议仅录入宗谱或予以驳回。",
		"image_key": "family.house",
		"ai_visual_prompt": "A clan hall with last year's white mourning cloth still on the beam, a stonemason waiting with a chisel, a name written in dust",
		"tags": ["war", "family", "faith"],
		"trigger_channel": Ch.SCHEDULED_ONLY,
		"required_story_flags": [String(Ids.FLAG_WAR_KINDRED_DEAD)],
		"one_shot": true,
		"base_weight": 100,
		"cooldown_days": 0,
		"min_era_index": 2,
		"max_era_index": 9,
		"conditions": [],
		"weight_rules": [],
		"options": [
			Shared.option(
				"carve_the_name", "拨款准建忠烈祠，旌表门第",
				"忠烈祠成，声望大振",
				"朝廷拨款资助建祠立碑并敕封士绅门第，忠义事迹传为佳话，地方文教风气与士气皆受鼓舞。",
				[
					_grant("j020_gentry", "士绅门第"),
					Shared.knowledge(8, 540),
					Shared.cash_out(4, 360),
				]),
			Shared.option(
				"no_shrine", "以财政紧缩为由严辞驳回",
				"寒心之举折损声望",
				"建祠奏请遭到冷漠否决，地方名族与民众深感报国无门，文教士气低落且离心倾向加剧。",
				[
					Shared.knowledge(-8, 360),
					Shared.bias(Ids.TAG_UNREST, 1.15, 540),
				]),
			Shared.option(
				"only_the_genealogy", "准予记入官修史册，不另建祠",
				"折中旌表平稳收场",
				"朝廷批准将其事迹载入地方史志与宗谱而不另费土木。此举既守住了国库预算，也维系了与地方豪强的体面关系。",
				[
					Shared.knowledge(5, 360),
					Shared.bias(Ids.TAG_COURT, 1.15, 540),
				]),
		],
	}))
