class_name NarrativeEventCatalogEra
extends RefCounted

## 高时代包：国家能力、标准、排班、一张安静的书桌（4 条）。
##
## 四条都是孤立事件，但彼此有软边：
##   大工程读劳动包的「十小时制」标记（工时定了，工程才招得到人）；
##   标准之争读「河鼓已响」（工程成功了，标准才有人抢）；
##   排班读「标准未定」（规矩没定，人头先乱）；
##   安静的房间读「两套工价」（工价没统一，院里也在算人头）。
##
## 这一包的代价货币是国家能力：工期、标准、人的时间；知识点降一律写本地 `.cut`，
## 因为全国部门产出没有负向键。

const Ids = preload("res://scripts/narrative/narrative_event_ids.gd")
const Shared = preload("res://scripts/narrative/narrative_event_shared.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")
const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")

const PACK_ID := &"era"
const PREFIX := "evt.era."

const CAST := [
	"国家工程署", "河鼓计划", "财政委员会", "度量衡总局",
	"铁路局", "工业标准", "劳工调度系统", "工会代表",
	"第九设计院", "算力配额", "科学委员会",
]

const MUL_110 := 72090
const MUL_115 := 75366
const MUL_120 := 78643
const MUL_125 := 81920


static func meta() -> Dictionary:
	return {
		"id": PACK_ID,
		"title": "高时代",
		"theme": "国家能力、标准与人的时间",
		"era_band": "8-10",
		"prefix": PREFIX,
		"scale": "2 宏观 + 1 中观 + 1 微观，全部孤立",
		"cast": CAST,
		"node_ids": [
			String(Ids.EVT_ERA_GREAT_WORKS),
			String(Ids.EVT_ERA_STANDARD_WAR),
			String(Ids.EVT_ERA_ALGORITHM_SHIFT),
			String(Ids.EVT_ERA_QUIET_ROOM),
		],
	}


static func append(catalog) -> void:
	if catalog == null:
		return
	var Op = NarrativeConditionScript.Op
	var Ch = NarrativeEventDefinitionScript.TriggerChannel

	# ═══ 大工程 ═══════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_ERA_GREAT_WORKS),
		"title": "{settlement_name}·河鼓大工程",
		"body_text": "国家工程署在{settlement_name}近郊推进的国家级重型试验设施「河鼓计划」已汇聚全国精钢与顶尖工师。然而地质勘测突报基底空洞，需深掘加固，征地红线更直穿多处祖居村落，引发激烈拆迁抵制。财政委员会已发出预算超支预警，但国防与科技部门仍在催促按期试车点火，进退维谷的报告已送至内阁案头。",
		"image_key": "map.construction",
		"ai_visual_prompt": "A huge engineering site on a plain, blueprints pinned by a wrench, survey stakes crossing an old graveyard, steel arriving by rail",
		"tags": ["era", "science", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 95,
		"cooldown_days": 900,
		"one_shot": true,
		"min_era_index": 8,
		"max_era_index": 10,
		"required_technologies": ["tech.industrialization"],
		"required_events_completed": [String(Ids.EVT_LABOR_FACTORY_ACT)],
		"conditions": [
			{"op": Op.POPULATION_GTE, "int_value": 25},
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 5},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.ERA_GTE, "int_value": 9},
				"add_weight": 20,
				"multiplier_q16": MUL_120,
				"reason": "工业底子厚了，才敢想这件事",
			},
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_HOURS_TEN)},
				"add_weight": 20,
				"reason": "工时定了，工程招得到人",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 7},
				"add_weight": 25,
				"multiplier_q16": MUL_115,
				"reason": "配套的厂都在本地",
			},
		],
		"options": [
			Shared.option(
				"fund_to_the_deadline", "追加国库拨款，强令按期完工",
				"三班抢工",
				"追加预算到位后，工地实行三班倒全速推进并强制迁村。设施如期落成并带动全国科研与制造，但强硬征地留下持久民怨。",
				[
					Shared.cash_out(8, 90),
					Shared.manufacturing(15, 540),
					Shared.country_sector("knowledge", 15, 540),
					Shared.bias(Ids.TAG_UNREST, 1.30, 360),
				]),
			Shared.gamble(
				"light_it_early", "不等加固完成，批准提前点火",
				Shared.branch(42598, "河鼓试车成功", # 65%
					"试验装置在剧烈震鸣中稳定运行数秒，核心电气参数全部达标。尽管观测区多处受损，全国科学界仍为这一历史性突破振奋。",
					[
						Shared.knowledge(18, 540),
						Shared.country_sector("knowledge", 15, 540),
						Shared.research_signal("breakthrough.electrification", "电气化"),
						Shared.flag(Ids.FLAG_HEGU_FIRED, 900, "标记「河鼓已响」"),
					]),
				Shared.branch(22938, "管道爆裂事故", # 35%
					"未加固的承压管线在点火瞬间爆裂回火，造成多名技术员与工人死伤。重大安全事故震惊朝野，工程署公信力跌入谷底。",
					[
						Shared.population_rate(-6),
						Shared.knowledge(-15, 360),
						Shared.bias(Ids.TAG_UNREST, 1.30, 720),
					])),
			Shared.option(
				"wait_for_the_steel", "暂缓工程进度，待钢材备齐",
				"停工待料",
				"工地全面停工封存，巨型塔吊在荒原上闲置生锈。高昂的前期投入未能见效，配套工厂与地方民众的不满情绪持续发酵。",
				[
					Shared.knowledge(-12, 540),
					Shared.manufacturing(-10, 540),
					Shared.bias(Ids.TAG_UNREST, 1.10, 540),
				]),
		],
	}))

	# ═══ 标准 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_ERA_STANDARD_WAR),
		"title": "{settlement_name}·轨距标准之争",
		"body_text": "南北两条干线铁路在{settlement_name}城外交汇，却因宽窄轨距不一而被迫全线人工倒装。度量衡总局召集铁路局与重工企业召开工业标准裁定会：北线集团依仗干线里程长、运力大，力主全国并轨北制；南线代表则强调窄轨方可深入矿区腹地。而握有双制扣件专利的零部件财团正静候裁决，随时准备借统一标准垄断全国订单。",
		"image_key": "map.construction",
		"ai_visual_prompt": "Two railway gauges meeting outside a town, a box of measuring tools and a caliper on a conference table",
		"tags": ["era", "market", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 100,
		"cooldown_days": 720,
		"one_shot": true,
		"min_era_index": 9,
		"max_era_index": 10,
		"required_technologies": ["tech.rail_logistics"],
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 5},
			{"op": Op.POPULATION_GTE, "int_value": 25},
			{"op": Op.PROFESSION_SHARE_GTE, "target_key": "merchant", "float_value": 0.001},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_HEGU_FIRED)},
				"add_weight": 20,
				"multiplier_q16": MUL_120,
				"reason": "河鼓响了，厂里只肯认一种模",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "artisan", "float_value": 0.05},
				"add_weight": 20,
				"reason": "做扣件的人已经在城里",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 7},
				"add_weight": 25,
				"reason": "厂多，标准才值钱",
			},
		],
		"options": [
			Shared.option(
				"pick_the_northern_gauge", "钦定北线宽轨为全国标准",
				"强制并轨",
				"全国铁路强制推行北线宽轨，干线贸易运力大增且基建标准趋同。但南线矿区换装积压严重，大批旧车皮报废引发剧烈震荡。",
				[
					Shared.trade_capacity(16, 540),
					Shared.build_cost(12, 900),
					Shared.manufacturing(-15, 540),
					Shared.bias(Ids.TAG_UNREST, 1.30, 360),
				]),
			Shared.option(
				"take_a_cut_per_piece", "收编标准模具，按件抽成",
				"专营扣件",
				"度量衡总局接管双制模具并按件抽成，国库进账可观且全国制造业得以兼容运转。但厂方将税负转嫁压低工薪，激起工人不满。",
				[
					Shared.cash_in(5, 270),
					Shared.stock("wrought_iron", 20),
					Shared.country_sector("manufacturing", 12, 540),
					Shared.bias(Ids.TAG_UNREST, 1.30, 360),
				]),
			Shared.option(
				"add_a_transfer_station", "暂缓统一，增设大型换装站",
				"折中换装",
				"两轨之间建起机械化换装站，本地制造与工具消耗随之攀升。尽管眼下免去改轨剧痛，标准悬而未决的隐患仍被留给未来。",
				[
					Shared.manufacturing(12, 540),
					Shared.tools(24, 540),
					Shared.flag(Ids.FLAG_STD_OPEN, 900, "标记「标准未定」"),
				]),
		],
	}))

	# ═══ 排班 ═════════════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_ERA_ALGORITHM_SHIFT),
		"title": "{settlement_name}·效率排班制",
		"body_text": "{settlement_name}的重型装卸场引入了基于工业标准与动作测时的劳工调度系统，将每项搬运工序精确切分至分秒，并规定未达标者自动调入夜班。管理层宣称此举可令货场吞吐翻倍，适应全国工业提速。工会代表则向市政厅严正抗议，指控这套冷酷的计件排班正透支老工人的体能极限，要求立即叫停。",
		"image_key": "map.construction",
		"ai_visual_prompt": "A shift board covered in name slots at a coal yard, a timekeeper with a stopwatch, workers standing still at the bell",
		"tags": ["era", "labor", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 110,
		"cooldown_days": 540,
		"min_era_index": 9,
		"max_era_index": 10,
		"required_technologies": ["tech.digital_computing"],
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 5},
			{"op": Op.POPULATION_GTE, "int_value": 30},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.UNEMPLOYMENT_GTE, "float_value": 0.10},
				"add_weight": 30,
				"multiplier_q16": MUL_110,
				"reason": "等着上工的人排到门口",
			},
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_STD_OPEN)},
				"add_weight": 0,
				"multiplier_q16": MUL_115,
				"reason": "规矩没定，人头先乱",
			},
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "industrial_worker", "float_value": 0.10},
				"add_weight": 20,
				"reason": "场里全是吃工时饭的人",
			},
		],
		"options": [
			Shared.option(
				"follow_the_board", "全线推行标准排班，末位淘汰",
				"铁腕提效",
				"严格计时的排班制覆盖各大厂区，本地与全国制造产能显著跃升。但高强度轮班导致工伤与过劳频发，生育率下滑且动荡风险飙升。",
				[
					Shared.manufacturing(18, 540),
					Shared.country_sector("manufacturing", 12, 540),
					Shared.birth(-18, 540),
					Shared.bias(Ids.TAG_UNREST, 1.30, 540),
				]),
			Shared.option(
				"pilot_one_yard", "仅在新设货场试点双轨工价",
				"双轨并行",
				"新场实行标准排班，老场沿用旧制，产能略有起色。然而同工不同酬的两套工价迅速激化内部矛盾，管理摩擦日渐增多。",
				[
					Shared.manufacturing(12, 540),
					Shared.flag(Ids.FLAG_SHIFT_PENDING, 720, "标记「两套工价」"),
					Shared.bias(Ids.TAG_UNREST, 1.20, 540),
				]),
			Shared.gamble(
				"let_workers_fill_it", "下放排班权，由班组自主协商",
				Shared.branch(39322, "班组自治见效", # 60%
					"经过短暂磨合，老工人自发优化了轮换节奏，货场效率反超测时表。劳工健康与家庭生活得以保全，只是厂方仍对放权心存芥蒂。",
					[
						Shared.manufacturing(18, 720),
						Shared.birth(15, 540),
						Shared.bias(Ids.TAG_UNREST, 1.20, 540),
					]),
				Shared.branch(26214, "班组争抢失序", # 40%
					"不同班组为抢占白班与大型吊机爆发激烈冲突，大批物资滞压货场。混乱令工业产出重挫，生活物资供应随之紧张。",
					[
						Shared.manufacturing(-18, 540),
						Shared.staple(25, 360),
						Shared.bias(Ids.TAG_UNREST, 1.30, 540),
					])),
		],
	}))

	# ═══ 安静的房间 ═══════════════════════════════════════════════════════
	catalog.register_event(NarrativeEventDefinitionScript.from_dict({
		"event_id": String(Ids.EVT_ERA_QUIET_ROOM),
		"title": "{settlement_name}·科研算力之争",
		"body_text": "设于{settlement_name}的第九设计院正陷入基础研究与商业订单的资源拉锯。科学委员会旗下的一支核心理论团队卡在关键推演的最后关头，请求全楼停机三日并独占算力配额以排除震动干扰。然而院务处指出，当前机时早已被矿业通风、铁路调度与水利测算的商业合同排满，贸然停机将面临巨额违约赔偿。",
		"image_key": "map.construction",
		"ai_visual_prompt": "A shaking third-floor office above machinery, a researcher's worn draft, a caretaker trying keys from a drawer",
		"tags": ["era", "scholar", "unrest"],
		"trigger_channel": Ch.PULSE_SAMPLED,
		"base_weight": 120,
		"cooldown_days": 480,
		"min_era_index": 8,
		"max_era_index": 10,
		"required_technologies": ["tech.national_laboratories"],
		"conditions": [
			{"op": Op.BUILDING_COUNT_GTE, "int_value": 4},
			{"op": Op.POPULATION_GTE, "int_value": 12},
		],
		"weight_rules": [
			{
				"condition": {"op": Op.PROFESSION_SHARE_GTE, "target_key": "scholar", "float_value": 0.03},
				"add_weight": 25,
				"multiplier_q16": MUL_120,
				"reason": "院里有算得动这一步的人",
			},
			{
				"condition": {"op": Op.BUILDING_COUNT_GTE, "int_value": 6},
				"add_weight": 20,
				"reason": "机器越多，屋子越吵",
			},
			{
				"condition": {"op": Op.HAS_STORY_FLAG, "target_key": String(Ids.FLAG_SHIFT_PENDING)},
				"add_weight": 0,
				"multiplier_q16": MUL_110,
				"reason": "两套工价没合成一套，院里也在算人头",
			},
		],
		"options": [
			Shared.option(
				"stop_the_floor", "财政兜底违约，全楼停机三日",
				"理论告破",
				"国库代付违约金后整层静默三日，核心理论如期告破，全国科研水平为之一振。但延误的矿业测算令本地采掘进度短暂受阻。",
				[
					Shared.cash_out(5, 90),
					Shared.knowledge(18, 540),
					Shared.extraction(-12, 540),
					Shared.country_sector("knowledge", 15, 720),
				]),
			Shared.option(
				"felt_the_walls", "加装隔振设施，商业机时照旧",
				"折中修缮",
				"设计院拨款为实验室加装隔振层，商业与矿业测算得以照常推进。但隔振效果有限且经费分配不均，科研人员怨声渐起。",
				[
					Shared.cash_out(5, 180),
					Shared.knowledge(8, 540),
					Shared.extraction(10, 540),
					Shared.bias(Ids.TAG_UNREST, 1.20, 360),
				]),
			Shared.option(
				"queue_for_next_month", "严守合同契约，排期延至下月",
				"错失先机",
				"理论团队被迫让出算力配额，次月却传出他国同行抢先发表同等成果的消息。学术界士气受挫，指责当局短视的舆论四起。",
				[
					Shared.knowledge(-12, 540),
					Shared.bias(Ids.TAG_UNREST, 1.10, 540),
				]),
		],
	}))
