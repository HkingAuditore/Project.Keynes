class_name NarrativeEventCatalogAtom
extends RefCounted

## 原子包：era 8–10 的七条孤立事件。
##
## 这一包不写技术，写国家能力落下来时人站在哪一格：
##   反应堆要水，水是从下游稻田里挪的；废料要地方，地方是别人家的滩；
##   天上的东西看得见车辙，也看得见谁家夜里还亮着灯；电视只有一个台，播什么由谁定；
##   全城的账并进一张网，先没位置的是抄账的人；行踪都查得到，查到哪一层是个政治问题；
##   产线不要人了，剩下的人还得吃饭。
##
## 代价一律落在具体的人身上：值夜的、抄账的、被调岗的、搬走的人家。
## 三条选项的代价货币互不相同：掉产出 / 摊派现金 / 抬风险 / 涨开销。

const Ids = preload("res://scripts/narrative/narrative_event_ids.gd")
const Shared = preload("res://scripts/narrative/narrative_event_shared.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")

const PACK_ID := &"atom"
const PREFIX := "evt.atom."

const CAST := [
	"能源委员会", "反应堆", "冷却水", "核废料", "遥感卫星", "广播电台",
	"数据网络", "安全部门", "自动化产线", "地方议会", "工业部", "财政部",
]

const MUL_110 := 72090
const MUL_115 := 75366
const MUL_120 := 78643
const MUL_125 := 81920


static func meta() -> Dictionary:
	return {
		"id": PACK_ID,
		"title": "原子",
		"theme": "国家能力落下来时，人站在哪一格",
		"era_band": "8-10",
		"prefix": PREFIX,
		"scale": "3 宏观 + 3 中观 + 1 微观，全部孤立",
		"cast": CAST,
		"node_ids": [
			String(Ids.EVT_ATOM_REACTOR),
			String(Ids.EVT_ATOM_WASTE),
			String(Ids.EVT_ATOM_SATELLITE),
			String(Ids.EVT_ATOM_CHANNEL),
			String(Ids.EVT_ATOM_NETWORK),
			String(Ids.EVT_ATOM_PRIVACY),
			String(Ids.EVT_ATOM_AUTOMATION),
		],
	}


static func append(catalog) -> void:
	if catalog == null:
		return
	var Op = NarrativeConditionScript.Op
	var Ch = NarrativeEventDefinitionScript.TriggerChannel

	# ═══ 核站 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_ATOM_REACTOR),
		"title": "{settlement_name}·核站",
		"body_text": "{settlement_name}的新建核电反应堆工程在冷却方案上陷入僵局。能源委员会提交的直流取水方案成本最低、投产最快，但抽调河道冷却水将大幅削减下游灌区的枯水期流量，引发当地农业团体通过地方议会强烈抗议；若改建闭式冷却塔，则工期延后且需追加大笔地方财政摊派。工业部正急等电力并网，最终方案待你拍板。",
		"image_key": "map.construction",
		"ai_visual_prompt": "A reactor foundation at the edge of a river town, an irrigation ditch being dug uphill, engineers and farmers arguing over a water gauge",
		"tags": ["atom", "unrest", "era"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 98,
		"cooldown_days": 900,
		"min_era_index": 8,
		"max_era_index": 10,
		"required_technologies": ["tech.nuclear_energy"],
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 5},
			{"op": Op.POPULATION_GTE, "int_value": 20},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 7},
				"add_weight": 15,
				"reason": "厂多了，才用得上这么多电",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "industrial_worker", "float_value": 0.05},
				"add_weight": 20,
				"multiplier_q16": MUL_115,
				"reason": "厂里的人多，先喊缺电的是他们",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 9},
				"add_weight": 15,
				"reason": "老电站撑不住了",
			},
		],
		"options": [
			Shared.option(
				"draw_from_the_river", "批准直流取水方案",
				"工业供电优先落地",
				"引水泵站按期竣工，充沛的电力迅速推动工业区扩张。下游农田因枯水期减流而连季歉收，农业团体的怨气随之积聚。",
				[
					Shared.energy(20, 540),
					Shared.manufacturing(10, 540),
					Shared.agriculture(-12, 540),
				]),
			Shared.option(
				"build_cooling_towers", "追加预算兴建冷却塔",
				"闭式循环工程竣工",
				"高耸的冷却塔投入运转，兼顾了核电出力与下游灌溉。但为弥补工程超支而开征的地方附加税，令本地市民背负了沉重压力。",
				[
					Shared.energy(15, 540),
					Shared.knowledge(10, 540),
					Shared.cash_in(4, 360),
					Shared.build_cost(8, 540),
				]),
			Shared.gamble(
				"run_it_low", "先期低功率试运行",
				Shared.branch(42598, "试运平稳达标", # 65%
					"反应堆在低功率区间平稳运行，不仅缓解了部分用电缺口，还为国家电网积累了宝贵的核能工程经验。",
					[
						Shared.energy(18, 540),
						Shared.knowledge(15, 540),
						Shared.research_signal("breakthrough.electrification", "电气化"),
					]),
				Shared.branch(22938, "冷却回路过热事故", # 35%
					"试运行期间堆芯温度异常攀升，机组被迫紧急停堆并疏散外围人员。事故震动全城，能源部门公信力遭受重创。",
					[
						Shared.energy(-18, 540),
						Shared.population_rate(-6),
						Shared.bias(Ids.TAG_UNREST, 1.30, 540),
					])),
		],
	}))

	# ═══ 废料 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_ATOM_WASTE),
		"title": "{settlement_name}·废料",
		"body_text": "{settlement_name}首批高放核废料已完成铅罐封装，永久处置选址却在地方议会引发激烈争执。安全部门提议就地深埋于近郊岩层，但地质学家警告邻近含水层存在渗漏隐患。若转运至北方废弃矿区，则须向地方征收高额转运专项费；若暂存地表露天堆场，则需长期派驻安保并面临舆论反弹。",
		"image_key": "economy.resource",
		"ai_visual_prompt": "Lead-lined boxes sealed with paper strips stacked beside a freshly dug pit, a straw watch hut and an oil lamp at night",
		"tags": ["atom", "unrest", "land"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 92,
		"cooldown_days": 780,
		"min_era_index": 8,
		"max_era_index": 10,
		"required_technologies": ["tech.nuclear_energy"],
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 5},
			{"op": Op.POPULATION_GTE, "int_value": 18},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 6},
				"add_weight": 15,
				"reason": "机器多的城，废料也多",
			},
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 24},
				"add_weight": 10,
				"reason": "人多，坑就离院子近",
			},
			{
				"condition": {"op": Op.MOISTURE_GTE, "float_value": 0.45},
				"add_weight": 15,
				"multiplier_q16": MUL_120,
				"reason": "地下潮，埋了也怕渗",
			},
		],
		"options": [
			Shared.option(
				"bury_in_the_stone", "封存近郊岩层深埋",
				"近郊矿区划为禁区",
				"近郊石场随即关停并改建为深层封存库，本地采掘产能因此受限。严格的隔离措施暂时平息了市民的恐慌情绪。",
				[
					Shared.extraction(-10, 540),
					Shared.knowledge(8, 540),
					Shared.bias(Ids.TAG_UNREST, 0.90, 360),
				]),
			Shared.option(
				"haul_it_north", "征收专款，跨区外运",
				"专列转运北方矿区",
				"特种专列连夜将废料运往北方深矿封存，本地工业与科研未受干扰。但分摊到各行业的高额转运税引发了商界不满。",
				[
					Shared.cash_in(5, 360),
					Shared.manufacturing(8, 540),
					Shared.knowledge(10, 540),
				]),
			Shared.option(
				"leave_it_open", "拨款暂存，强化监测",
				"临时堆场引发抗议",
				"政府拨款设立全天候监测站与隔离区，暂缓永久处置。长期暴露的风险令周边社区人心惶惶，抗议活动此起彼伏。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
					Shared.cash_out(4, 540),
					Shared.knowledge(8, 540),
				]),
		],
	}))

	# ═══ 卫星 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_ATOM_SATELLITE),
		"title": "{settlement_name}·卫星",
		"body_text": "{settlement_name}的遥感卫星地面接收站正式投入运转，高空影像足以清晰辨识气象演变与地面物流动向。科学界呼吁向全社会开放数据以服务气象预报与学术研究，安全部门则要求将其列为国家机密，专供军政与仓储监管。财政部与工业部另提折中方案，主张向商业机构有偿出租部分观测频段。",
		"image_key": "map.construction",
		"ai_visual_prompt": "A tall lattice antenna on a rocky ridge above a river town, a small screen showing a field with burning stubble",
		"tags": ["atom", "era"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 840,
		"min_era_index": 9,
		"max_era_index": 10,
		"required_technologies": ["tech.satellite_observation"],
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 6},
			{"op": Op.POPULATION_GTE, "int_value": 20},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 9},
				"add_weight": 20,
				"reason": "这年头才够得着天上",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 7},
				"add_weight": 15,
				"reason": "配得起机房和电",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "scholar", "float_value": 0.02},
				"add_weight": 15,
				"reason": "有人会读那些图",
			},
		],
		"options": [
			Shared.option(
				"open_the_scope", "全面开放公共数据",
				"民用科研获益匪浅",
				"接收站向全国高校与民间机构敞开大门，全国科研活力显著提升。但蜂拥而至的申请令本地站点的日常调度一度陷入混乱。",
				[
					Shared.knowledge(-10, 540),
					Shared.bias(Ids.TAG_UNREST, 0.90, 540),
					Shared.country_sector("knowledge", 10, 540),
				]),
			Shared.option(
				"seal_it_for_the_state", "划归国家机密专用",
				"军政情报能力大增",
				"安全部门全面接管接收站，高空影像成为中央统筹战略资源的利器。但全天候监控的传闻迅速在民间蔓延，引发对权力的猜忌。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.25, 540),
					Shared.knowledge(12, 540),
					Shared.country_sector("knowledge", 12, 540),
				]),
			Shared.option(
				"rent_half_of_it", "开放商业频段有偿租赁",
				"卫星数据实现创收",
				"农垦企业与物流巨头竞相购买遥感测绘服务，国库进账颇丰，工业与科研部门也借由商业化运作同步升级了分析设备。",
				[
					Shared.cash_in(4, 360),
					Shared.manufacturing(8, 540),
					Shared.knowledge(8, 540),
				]),
		],
	}))

	# ═══ 电视 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_ATOM_CHANNEL),
		"title": "{settlement_name}·电视",
		"body_text": "{settlement_name}首座区域广播电台与电视转播塔落成，但受限于夜间电力配额，黄金时段仅够维持单一公共频道。能源委员会主张只播送政令公告与气象预警以节约电力。地方议会与文化团体要求增加文艺演出与体育转播以舒缓民意，各区代表也趁机争取自主制作节目的配额。",
		"image_key": "country.economy",
		"ai_visual_prompt": "A single broadcast tower above a town, a room of neighbours watching one small screen at night, a bird emblem painted on the wall",
		"tags": ["atom", "people", "era"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 88,
		"cooldown_days": 720,
		"min_era_index": 8,
		"max_era_index": 10,
		"required_technologies": ["tech.radio", "tech.electric_grid"],
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
			{"op": Op.POPULATION_GTE, "int_value": 20},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 24},
				"add_weight": 15,
				"reason": "人挤在一处，一台机器就够全城看",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 5},
				"add_weight": 10,
				"reason": "有厂房，才凑得出那台机器",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 9},
				"add_weight": 10,
				"multiplier_q16": MUL_110,
				"reason": "夜里也供电了",
			},
		],
		"options": [
			Shared.option(
				"notices_only", "限定播送政令与气象",
				"频道沦为官方通告",
				"枯燥的政令播报省下了可观的工业电力，政令传达效率大增，但文化生活陷入沉闷，市民对公共广播几乎失去兴趣。",
				[
					Shared.knowledge(-10, 540),
					Shared.manufacturing(8, 540),
					Shared.bias(Ids.TAG_UNREST, 0.95, 540),
				]),
			Shared.option(
				"plays_and_ballgames", "开征视听费，增设文体",
				"公共娱乐凝聚民心",
				"精彩的文艺演出与赛事转播迅速风靡全城，社会氛围显著缓和。按户征收的广播视听费也为国库补齐了运营开支。",
				[
					Shared.cash_in(3, 360),
					Shared.knowledge(10, 540),
					Shared.bias(Ids.TAG_UNREST, 0.85, 540),
				]),
			Shared.option(
				"let_the_villages_send", "放开各区轮流制作节目",
				"多元舆论激荡全城",
				"各社区与民间团体纷纷借电台发声，本土文化与公共讨论空前活跃，但立场交锋与地域争执也随之频频登上荧屏。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
					Shared.knowledge(12, 540),
					Shared.birth(8, 540),
				]),
		],
	}))

	# ═══ 网络 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_ATOM_NETWORK),
		"title": "{settlement_name}·网络",
		"body_text": "财政部与工业部联合推进{settlement_name}的政务数据网络工程，计划将全市仓储、商号与交通枢纽的账目全面并入中央主机。技术人员指出，全网打通后可实时掌握物资流向并杜绝偷漏税。但各大商会强烈抵制，认为此举等同于剥夺商业机密，迄今绝大多数私营企业仍拒绝接入。",
		"image_key": "country.economy",
		"ai_visual_prompt": "A switchboard installed in an old grain warehouse, cables hanging like drying noodles, clerks copying ledgers by lamplight",
		"tags": ["atom", "market", "labor"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 94,
		"cooldown_days": 840,
		"min_era_index": 9,
		"max_era_index": 10,
		"required_technologies": ["tech.networked_computing"],
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 6},
			{"op": Op.POPULATION_GTE, "int_value": 25},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 8},
				"add_weight": 20,
				"reason": "摊子大了，纸账记不过来",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.02},
				"add_weight": 15,
				"reason": "商号多，账才并得起来",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 9},
				"add_weight": 10,
				"reason": "机房和线路都齐了",
			},
		],
		"options": [
			Shared.option(
				"merge_everything", "强制全行业限期并网",
				"数字统筹体系成型",
				"政府以行政令强推全面并网并向商界分摊线路费。国家对全国产业链的调度能力跃上新台阶，催生了全新的工业组织形态。",
				[
					Shared.cash_in(5, 360),
					Shared.knowledge(15, 540),
					Shared.country_sector("manufacturing", 8, 540),
					Shared.research_signal("breakthrough.industrial_organization", "工业组织"),
				]),
			Shared.option(
				"state_granaries_only", "仅限国营仓储与税册",
				"公私账目分轨运行",
				"财政部退让一步，仅将公营资产纳入数据网络。商界抵触情绪得以缓和，但半吊子的信息化改造限制了整体数据效能。",
				[
					Shared.knowledge(-10, 540),
					Shared.manufacturing(8, 540),
					Shared.bias(Ids.TAG_UNREST, 0.90, 540),
				]),
			Shared.option(
				"half_and_half", "推行电子与纸质双轨制",
				"双轨对账漏洞百出",
				"部分并网导致电子台账与民间纸账频频冲突，月末核销屡现巨额差额。官商互相推诿，行政效率与市场秩序双双受损。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.25, 540),
					Shared.knowledge(8, 540),
					Shared.manufacturing(-8, 540),
				]),
		],
	}))

	# ═══ 隐私 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_ATOM_PRIVACY),
		"title": "{settlement_name}·隐私",
		"body_text": "依托新建的城区数据网络，安全部门在{settlement_name}各交通要道部署了全天候身份核验与行程登记系统。警方声称这套严密档案已显著遏制盗窃与走私，但地方议会收到大量市民联名投诉，抗议行政权力无孔不入地窥探个人行踪。如何在治安效能与公民隐私边界之间划线，已成为舆论焦点。",
		"image_key": "family.house",
		"ai_visual_prompt": "A gate lantern at night, a watchman's ledger opened to a half-filled page, an old woman standing at the gate",
		"tags": ["atom", "unrest", "people"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 90,
		"cooldown_days": 780,
		"min_era_index": 9,
		"max_era_index": 10,
		"required_technologies": ["tech.networked_computing"],
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 5},
			{"op": Op.POPULATION_GTE, "int_value": 20},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.POPULATION_GTE, "int_value": 24},
				"add_weight": 15,
				"reason": "人多，门口就难认",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 6},
				"add_weight": 10,
				"reason": "仓库多，进出的事也多",
			},
			{
				"condition": {"op": Op.COHORT_SATISFACTION_LTE, "float_value": 0.45},
				"add_weight": 15,
				"multiplier_q16": MUL_125,
				"reason": "人心里有火，官面上更想盯人",
			},
		],
		"options": [
			Shared.option(
				"to_each_household", "维持全员全域留底",
				"严密监控压抑社会",
				"全域档案系统全面铺开，治安管理与行政效率明显提升，但无处不在的监视感令市民怨声载道，暗流在民间滋长。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
					Shared.knowledge(10, 540),
					Shared.manufacturing(8, 540),
				]),
			Shared.option(
				"to_the_gate_only", "收窄至要道卡口核验",
				"治安与隐私暂得平衡",
				"安全部门撤除了社区级监控，改为在交通干道增配巡逻器械。此举虽增加了运维耗材开支，却有效安抚了公众的不安情绪。",
				[
					Shared.tools(10, 540),
					Shared.bias(Ids.TAG_UNREST, 0.90, 540),
					Shared.manufacturing(8, 540),
				]),
			Shared.option(
				"names_without_hours", "立法脱敏，禁录行踪时间",
				"隐私法案获得通过",
				"地方议会通过数据脱敏条款，只保留基础身份核验并向商界征收合规审计费。情报颗粒度虽有下降，社会信任却得以维系。",
				[
					Shared.cash_in(3, 360),
					Shared.knowledge(-8, 540),
					Shared.bias(Ids.TAG_UNREST, 0.95, 540),
				]),
		],
	}))

	# ═══ 自动化 ═══════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_ATOM_AUTOMATION),
		"title": "{settlement_name}·自动化",
		"body_text": "{settlement_name}工业区率先引入全流程自动化产线，从投料加工到封装出库仅需寥寥数名值守技师。工业部报告称，全面推广将令全国制造效率实现跨越，但首批被裁撤的大批熟练工人已聚集在工厂外抗议生计无着。地方议会呼吁放缓替代节奏或由国家统筹转岗，资本与劳工的矛盾一触即发。",
		"image_key": "map.construction",
		"ai_visual_prompt": "A machine line running without workers, one man walking past a row of warm metal housings, idle men waiting outside the gate",
		"tags": ["atom", "labor", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 96,
		"cooldown_days": 900,
		"min_era_index": 9,
		"max_era_index": 10,
		"required_technologies": ["tech.robotic_control"],
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 6},
			{"op": Op.POPULATION_GTE, "int_value": 25},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 8},
				"add_weight": 20,
				"reason": "厂子成片，才腾得出一条整线",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "industrial_worker", "float_value": 0.08},
				"add_weight": 20,
				"multiplier_q16": MUL_120,
				"reason": "看机床的人多，换起来才省得多",
			},
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 9},
				"add_weight": 10,
				"reason": "机器自己能咬牙做了",
			},
		],
		"options": [
			Shared.option(
				"run_the_line", "全面推行全自动生产",
				"产能激增伴随裁员潮",
				"自动化产线全速运转，制造业产出大幅飙升并催生了新的技术突破。但骤增的失业人群令工会与地方治安陷入高度紧张。",
				[
					Shared.bias(Ids.TAG_UNREST, 1.35, 540),
					Shared.manufacturing(18, 540),
					Shared.country_sector("manufacturing", 10, 540),
					Shared.research_signal("breakthrough.automation", "自动化"),
				]),
			Shared.option(
				"keep_the_hands", "限制替代比例，保就业",
				"人机并存缓和冲击",
				"政府强制要求产线保留核心人工岗位，工人抗议迅速平息，技师也在协作中积累了运维心得，代价则是产能增长显著放缓。",
				[
					Shared.manufacturing(-10, 540),
					Shared.knowledge(8, 540),
					Shared.bias(Ids.TAG_UNREST, 0.85, 540),
				]),
			Shared.option(
				"send_them_to_the_ditch", "征收转岗税，组织兴农",
				"富余劳力转投基建",
				"财政部向高利润工厂征收转岗基金，将失业工人编入农田水利与生态修复工程。社会动荡得以化解，农业基础设施亦获加强。",
				[
					Shared.cash_in(5, 360),
					Shared.agriculture(10, 540),
					Shared.bias(Ids.TAG_UNREST, 0.90, 540),
				]),
		],
	}))
